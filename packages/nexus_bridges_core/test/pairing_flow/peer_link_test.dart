import 'dart:async';

import 'package:nexus_bridges_core/src/identity/identity.dart';
import 'package:nexus_bridges_core/src/pairing_flow/crypto.dart';
import 'package:nexus_bridges_core/src/pairing_flow/pairing_flow.dart';
import 'package:nexus_bridges_core/src/pairing_flow/peer_link.dart';
import 'package:nexus_bridges_core/src/protocol/protocol.dart';
import 'package:nexus_bridges_core/src/transport/transport.dart';
import 'package:test/test.dart';

import '../server/api_server_harness.dart';
import 'initiator_harness.dart';

void main() {
  late DeviceIdentity ia;
  late DeviceIdentity ib;
  late DeviceIdentity ix;

  setUpAll(() {
    ia = DeviceIdentity.generate();
    ib = DeviceIdentity.generate();
    ix = DeviceIdentity.generate();
  });

  Future<PairingStack> stackA() =>
      PairingStack.start(identity: ia, address: loopback, name: 'Stack A');

  Future<PairingStack> stackB() =>
      PairingStack.start(identity: ib, address: otherLoopback, name: 'Stack B');

  PairingTarget targetTo(FakeReceiver fake, {String? fingerprint}) =>
      PairingTarget(
        fingerprint: fingerprint ?? fake.fingerprint,
        name: 'Remote',
        address: fake.address,
        port: fake.port,
        interfaceId: 'loopback#127.0.0.1',
        localAddress: loopback,
      );

  PeerLink linkTo(
    FakeReceiver fake, {
    String? fingerprint,
    AbortSignal? abort,
  }) => PeerLink(
    identity: ia,
    target: targetTo(fake, fingerprint: fingerprint),
    abort: abort ?? AbortSignal(),
  );

  group('PeerLink (RF-82, RF-122)', () {
    test(
      'posts JSON, returns status and object, and keeps the server certificate',
      () async {
        final fake = await FakeReceiver.of(ib);
        fake.handlers['$apiPrefix/pair/wait'] = (call) =>
            FakeAnswer(202, {'echo': call.body['hello']});
        final link = linkTo(fake);
        expect(link.serverCertificate, isNull);
        final reply = await link.post(ApiPaths.pairWait, {'hello': 'world'});
        expect(reply, isNotNull);
        expect(reply!.$1, 202);
        expect(reply.$2, {'echo': 'world'});
        expect(link.serverCertificate, isNotNull);
        expect(link.serverCertificate!.fingerprint, ib.fingerprint);
        expect(link.serverCertificate!.pem, ib.certificate.pem);
        expect(
          fake.callsTo(ApiPaths.pairWait).single.clientFingerprint,
          isNull,
        );
      },
    );

    test('error statuses still come back with their body', () async {
      final fake = await FakeReceiver.of(ib);
      fake.handlers[ApiPaths.pairStart] = (_) =>
          const FakeAnswer(409, {'error': 'busy'});
      final reply = await linkTo(fake).post(ApiPaths.pairStart, const {});
      expect(reply!.$1, 409);
      expect(reply.$2, {'error': 'busy'});
    });

    test('a body that is not JSON, or not an object, gives null', () async {
      final fake = await FakeReceiver.of(ib);
      fake.handlers[ApiPaths.pairWait] = (_) =>
          const FakeAnswer.raw(200, 'nope');
      fake.handlers[ApiPaths.pairConfirm] = (_) =>
          const FakeAnswer.raw(200, '[1,2]');
      fake.handlers[ApiPaths.pairCancel] = (_) =>
          const FakeAnswer.raw(200, '"text"');
      final link = linkTo(fake);
      expect(await link.post(ApiPaths.pairWait, const {}), isNull);
      expect(await link.post(ApiPaths.pairConfirm, const {}), isNull);
      expect(await link.post(ApiPaths.pairCancel, const {}), isNull);
    });

    test('a dropped connection gives null', () async {
      final fake = await FakeReceiver.of(ib);
      fake.handlers[ApiPaths.pairWait] = (_) => const FakeAnswer.drop();
      expect(await linkTo(fake).post(ApiPaths.pairWait, const {}), isNull);
    });

    test('another fingerprint: null, no certificate kept and nothing reaches the server', () async {
      final fake = await FakeReceiver.of(ib);
      final link = linkTo(fake, fingerprint: ix.fingerprint);
      expect(await link.post(ApiPaths.pairStart, const {'a': 1}), isNull);
      expect(link.serverCertificate, isNull);
      await pause();
      expect(fake.calls, isEmpty);
    });

    test('right fingerprint but a certificate the parser rejects: null, nothing sent', () async {
      final oversized = OversizedCertificate();
      final fake = await FakeReceiver.start(
        fingerprint: oversized.fingerprint,
        context: oversized.serverContext,
      );
      final link = linkTo(fake);
      expect(await link.post(ApiPaths.pairStart, const {}), isNull);
      expect(link.serverCertificate, isNull);
      await pause();
      expect(fake.calls, isEmpty);
    });

    test('control: the oversized certificate is valid for TLS and only its '
        'PEM length is refused', () async {
      final oversized = OversizedCertificate();
      expect(oversized.pem.length, greaterThan(4096));
      expect(fingerprintOfCertificate(oversized.der), oversized.fingerprint);
      expect(PeerCertificate.fromDer(oversized.der), isNull);
      final fake = await FakeReceiver.start(
        fingerprint: oversized.fingerprint,
        context: oversized.serverContext,
      );
      final reply = await postJson(
        address: fake.address,
        port: fake.port,
        path: ApiPaths.pairStart,
        json: const {},
        context: anonymousContext,
        acceptServer: (certificate) =>
            fingerprintOfCertificate(certificate.der) == oversized.fingerprint,
        sourceAddress: loopback,
        timeout: const Duration(seconds: 5),
        maxResponseBytes: Limits.maxPairingBodyBytes,
      );
      expect(reply?.status, 200);
      expect(fake.count(ApiPaths.pairStart), 1);
    });

    test('the timeout parameter is honoured', () async {
      final silent = await SilentListener.start(otherLoopback);
      final link = PeerLink(
        identity: ia,
        target: PairingTarget(
          fingerprint: ib.fingerprint,
          name: null,
          address: otherLoopback,
          port: silent.port,
          interfaceId: 'loopback#127.0.0.1',
          localAddress: loopback,
        ),
        abort: AbortSignal(),
      );
      final stopwatch = Stopwatch()..start();
      final reply = await link.post(
        ApiPaths.pairWait,
        const {},
        timeout: const Duration(milliseconds: 500),
      );
      expect(reply, isNull);
      expect(stopwatch.elapsed, greaterThan(const Duration(milliseconds: 400)));
      expect(stopwatch.elapsed, lessThan(const Duration(milliseconds: 2500)));
    });

    test('aborting the link signal cuts a request in flight', () async {
      final fake = await FakeReceiver.of(ib);
      fake.handlers[ApiPaths.pairWait] = (_) => const FakeAnswer.hold();
      final signal = AbortSignal();
      final link = linkTo(fake, abort: signal);
      final stopwatch = Stopwatch()..start();
      final pending = link.post(ApiPaths.pairWait, const {});
      await waitUntil(() => fake.heldOpened == 1);
      signal.abort();
      expect(await pending, isNull);
      expect(stopwatch.elapsed, lessThan(const Duration(seconds: 3)));
      await waitUntil(() => fake.heldClosed == 1);
    });

    test('an own signal is independent from the link signal', () async {
      final fake = await FakeReceiver.of(ib);
      final linkSignal = AbortSignal()..abort();
      final link = linkTo(fake, abort: linkSignal);
      expect(await link.post(ApiPaths.pairCancel, const {}), isNull);
      final reply = await link.post(ApiPaths.pairCancel, const {
        'reason': 'cancelled',
      }, abort: AbortSignal());
      expect(reply!.$1, 200);
      expect(fake.count(ApiPaths.pairCancel), 1);
    });

    test('presentCertificate sends the identity certificate', () async {
      final fake = await FakeReceiver.start(
        fingerprint: ib.fingerprint,
        context: ib.serverContext(trustedCertificatesPem: [ia.certificatePem]),
        requestClientCertificate: true,
      );
      final link = linkTo(fake);
      await link.post(ApiPaths.unpair, const {}, presentCertificate: true);
      await link.post(ApiPaths.pairWait, const {});
      expect(
        fake.callsTo(ApiPaths.unpair).single.clientFingerprint,
        ia.fingerprint,
      );
      expect(fake.callsTo(ApiPaths.pairWait).single.clientFingerprint, isNull);
    });
  });

  group('checkPeer (C60, C61, RF-118, RF-122)', () {
    test('B without A: notPaired; B with A: paired', () async {
      final a = await stackA();
      final b = await stackB();
      expect(
        await a.coordinator.checkPeer(a.targetOf(b)),
        PeerStatus.notPaired,
      );
      await b.pairWith([ia]);
      expect(await a.coordinator.checkPeer(a.targetOf(b)), PeerStatus.paired);
      expect(b.handledOn(ApiPaths.pairStatus), 2);
      expect(a.view, isNull);
      expect(a.coordinator.busy, isFalse);
    });

    test('checkPeer does not block or change a pairing in course', () async {
      final a = await stackA();
      final b = await stackB();
      a.coordinator.tryPair(a.targetOf(b));
      expect(
        await a.coordinator.checkPeer(a.targetOf(b)),
        PeerStatus.notPaired,
      );
      await waitUntil(() => a.view?.phase == PairingPhase.comparing);
    });

    test(
      'another identity at that address: unknown and nothing reaches it',
      () async {
        final a = await stackA();
        final b = await stackB();
        expect(
          await a.coordinator.checkPeer(
            a.targetOf(b, fingerprint: ix.fingerprint),
          ),
          PeerStatus.unknown,
        );
        await pause();
        expect(b.handledTotal, 0);
      },
    );

    test('nobody listening: unknown', () async {
      final a = await stackA();
      final port = await freePort(address: otherLoopback);
      final stopwatch = Stopwatch()..start();
      expect(
        await a.coordinator.checkPeer(
          a.targetAt(otherLoopback, port, fingerprint: ib.fingerprint),
        ),
        PeerStatus.unknown,
      );
      expect(stopwatch.elapsed, lessThan(const Duration(seconds: 5)));
    });

    Future<void> unknownFor(FakeAnswer answer) async {
      final a = await stackA();
      final fake = await FakeReceiver.of(ib);
      fake.handlers[ApiPaths.pairStatus] = (_) => answer;
      expect(
        await a.coordinator.checkPeer(
          a.targetAt(fake.address, fake.port, fingerprint: ib.fingerprint),
        ),
        PeerStatus.unknown,
      );
      expect(fake.count(ApiPaths.pairStatus), 1);
    }

    test('a 403 gives unknown', () async {
      await unknownFor(const FakeAnswer(403, {'error': 'rejected'}));
    });

    test('a 500 gives unknown', () async {
      await unknownFor(const FakeAnswer(500, {'error': 'internal'}));
    });

    test('an unreadable answer gives unknown', () async {
      await unknownFor(const FakeAnswer(200, {'paired': 'yes'}));
    });

    test('no answer gives unknown', () async {
      await unknownFor(const FakeAnswer.drop());
    });

    test('the request carries a fresh challenge and a proof bound to both fingerprints', () async {
      final a = await stackA();
      final fake = await FakeReceiver.of(ib);
      fake.handlers[ApiPaths.pairStatus] = (_) =>
          const FakeAnswer(200, {'paired': false});
      final target = a.targetAt(
        fake.address,
        fake.port,
        fingerprint: ib.fingerprint,
      );
      expect(await a.coordinator.checkPeer(target), PeerStatus.notPaired);
      expect(await a.coordinator.checkPeer(target), PeerStatus.notPaired);
      final bodies = [
        for (final c in fake.callsTo(ApiPaths.pairStatus)) c.body,
      ];
      expect(bodies, hasLength(2));
      for (final body in bodies) {
        expect(body.keys.toSet(), {'certificate', 'challenge', 'proof'});
        expect(body['certificate'], ia.certificate.pem);
        final challenge = fromHex(
          body['challenge']! as String,
          challengeLength,
        )!;
        final proof = fromHex(body['proof']! as String, signatureLength)!;
        expect(
          ia.certificate.verify(
            statusTranscript(
              callerFingerprint: ia.fingerprint,
              serverFingerprint: ib.fingerprint,
              challenge: challenge,
            ),
            proof,
          ),
          isTrue,
        );
        expect(
          ia.certificate.verify(
            statusTranscript(
              callerFingerprint: ia.fingerprint,
              serverFingerprint: ix.fingerprint,
              challenge: challenge,
            ),
            proof,
          ),
          isFalse,
        );
      }
      expect(bodies[0]['challenge'], isNot(bodies[1]['challenge']));
      expect(fake.callsTo(ApiPaths.pairStatus).first.clientFingerprint, isNull);
    });
  });

  group('notifyUnpaired (C58 client side, C59, C61, RF-115, RF-117)', () {
    test(
      'delivered: true, and the other side removes us and says so',
      () async {
        final a = await stackA();
        final b = await stackB();
        await b.pairWith([ia]);
        expect(await a.coordinator.notifyUnpaired(a.targetOf(b)), isTrue);
        await waitUntil(() => !b.paired.isPaired(ia.fingerprint));
        await waitUntil(() => b.events.whereType<UnpairedByPeer>().isNotEmpty);
        final event = b.events.whereType<UnpairedByPeer>().single;
        expect(event.fingerprint, ia.fingerprint);
        expect(event.saved, isTrue);
        expect(b.handledOn(ApiPaths.unpair), 1);
        final stored = await b.reloadPaired();
        expect(stored, isEmpty);
      },
    );

    test(
      'the other side does not have us: false and its handler gets nothing',
      () async {
        final a = await stackA();
        final b = await stackB();
        expect(await a.coordinator.notifyUnpaired(a.targetOf(b)), isFalse);
        await pause();
        expect(b.handledOn(ApiPaths.unpair), 0);
      },
    );

    test(
      'another fingerprint at that address: false and nothing reaches it',
      () async {
        final a = await stackA();
        final b = await stackB();
        await b.pairWith([ia]);
        expect(
          await a.coordinator.notifyUnpaired(
            a.targetOf(b, fingerprint: ix.fingerprint),
          ),
          isFalse,
        );
        await pause();
        expect(b.handledTotal, 0);
        expect(b.paired.isPaired(ia.fingerprint), isTrue);
      },
    );

    test('a port that accepts TCP and never talks: false within 5.5 s, one attempt', () async {
      final a = await stackA();
      final silent = await SilentListener.start(otherLoopback);
      final stopwatch = Stopwatch()..start();
      final delivered = await a.coordinator.notifyUnpaired(
        a.targetAt(otherLoopback, silent.port, fingerprint: ib.fingerprint),
      );
      expect(delivered, isFalse);
      expect(
        stopwatch.elapsed,
        greaterThan(const Duration(milliseconds: 4500)),
      );
      expect(stopwatch.elapsed, lessThan(const Duration(milliseconds: 5500)));
      await pause(const Duration(seconds: 1));
      expect(silent.accepted, hasLength(1));
    }, timeout: const Timeout(Duration(seconds: 30)));

    test('nobody listening: false, no retry', () async {
      final a = await stackA();
      final port = await freePort(address: otherLoopback);
      expect(
        await a.coordinator.notifyUnpaired(
          a.targetAt(otherLoopback, port, fingerprint: ib.fingerprint),
        ),
        isFalse,
      );
    });

    test(
      'presents the certificate, sends an empty body and accepts only 200',
      () async {
        final a = await stackA();
        final fake = await FakeReceiver.start(
          fingerprint: ib.fingerprint,
          context: ib.serverContext(
            trustedCertificatesPem: [ia.certificatePem],
          ),
          requestClientCertificate: true,
        );
        final target = a.targetAt(
          fake.address,
          fake.port,
          fingerprint: ib.fingerprint,
        );
        expect(await a.coordinator.notifyUnpaired(target), isTrue);
        final call = fake.callsTo(ApiPaths.unpair).single;
        expect(call.clientFingerprint, ia.fingerprint);
        expect(call.json, <String, Object?>{});
        fake.handlers[ApiPaths.unpair] = (_) =>
            const FakeAnswer(401, {'error': 'unauthorized'});
        expect(await a.coordinator.notifyUnpaired(target), isFalse);
        fake.handlers[ApiPaths.unpair] = (_) => const FakeAnswer(204, {});
        expect(await a.coordinator.notifyUnpaired(target), isFalse);
        expect(fake.count(ApiPaths.unpair), 3);
      },
    );
  });
}
