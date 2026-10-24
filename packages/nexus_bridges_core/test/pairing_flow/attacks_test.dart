import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:basic_utils/basic_utils.dart';
import 'package:nexus_bridges_core/src/identity/identity.dart';
import 'package:nexus_bridges_core/src/pairing/pairing.dart';
import 'package:nexus_bridges_core/src/pairing_flow/crypto.dart';
import 'package:nexus_bridges_core/src/pairing_flow/messages.dart';
import 'package:nexus_bridges_core/src/pairing_flow/pairing_flow.dart';
import 'package:nexus_bridges_core/src/protocol/protocol.dart';
import 'package:nexus_bridges_core/src/transport/transport.dart';
import 'package:test/test.dart';

import '../server/api_server_harness.dart';
import 'receiver_harness.dart' show HandMadeCertificate;
import 'stacks_harness.dart';

const Answer rejectedAnswer = (403, {'error': 'rejected'});

final class AdaptiveRun {
  ForgedInitiator? towardReceiver;
  HttpsResponse? startReply;
  HttpsResponse? revealReply;
  PairingView? receiverViewAtReveal;
  Uint8List? ci;
  Uint8List? ni;
}

SecurityContext presentingHandMade(HandMadeCertificate certificate) =>
    SecurityContext(withTrustedRoots: false)
      ..minimumTlsProtocolVersion = TlsProtocolVersion.tls1_3
      ..useCertificateChainBytes(utf8.encode(certificate.pem))
      ..usePrivateKeyBytes(
        utf8.encode(
          CryptoUtils.encodeEcPrivateKeyToPem(certificate.privateKey),
        ),
      );

void main() {
  const long = Timeout(Duration(minutes: 3));

  Future<(Stack, Stack, FakeFace)> intermediary() async {
    final i = await Stack.start(name: 'Laptop', address: hostB);
    final r = await Stack.start(name: 'PC', address: hostA);
    final m = await FakeFace.start(address: hostM);
    return (i, r, m);
  }

  PairingTarget spoofed(Stack i, Stack r, FakeFace m) =>
      i.targetAt(hostM, m.port, fingerprint: m.fingerprint, name: r.name);

  void watchReveal(Stack r, AdaptiveRun run) {
    r.wrappers[ApiPaths.pairReveal] = (call, inner) async {
      final reply = await inner(call);
      run.receiverViewAtReveal = r.view;
      return reply;
    };
  }

  AdaptiveRun installAdaptive(
    Stack r,
    FakeFace m, {
    DeviceIdentity? relayIdentity,
  }) {
    final run = AdaptiveRun();
    final m2 = relayIdentity ?? DeviceIdentity.generate();
    watchReveal(r, run);
    m.handlers[ApiPaths.pairStart] = (body) async {
      final ci = hexField(body, 'commitment', commitmentLength);
      run.ci = ci;
      final toward = ForgedInitiator(m2, r)..nonce = chosenAfter([ci]);
      run.towardReceiver = toward;
      run.startReply = await toward.start(name: body['name'] as String?);
      if (run.startReply?.status != 200) return rejectedAnswer;
      run.revealReply = await toward.reveal();
      if (run.revealReply?.status != 200) return rejectedAnswer;
      m.nonce = chosenAfter([toward.cr!, toward.nr!, ci]);
      return (
        200,
        StartReply(session: m.session, commitment: m.commitment).toJson(),
      );
    };
    m.handlers[ApiPaths.pairReveal] = (body) {
      run.ni = hexField(body, 'nonce', nonceLength);
      return (200, RevealReply(nonce: m.nonce).toJson());
    };
    return run;
  }

  Future<void> bothComparing(Stack i, Stack r) => until(
    () =>
        i.view?.phase == PairingPhase.comparing &&
        r.view?.phase == PairingPhase.comparing,
    reason: 'both notices on screen',
  );

  Future<void> bothRefuse(Stack i, Stack r) async {
    r.coordinator.answerAsReceiver(ReceiverAnswer.mismatch);
    i.coordinator.answerAsInitiator(matches: false);
    await until(
      () => i.idle && r.idle && i.view == null && r.view == null,
      reason: 'both cancelled',
    );
  }

  group('C53 an intermediary between I and R (SEC-13, RF-77 to RF-79)', () {
    test(
      'an intermediary that picks its numbers after every commitment it '
      'sees never makes both codes equal, and every attempt is on screen',
      () async {
        final (i, r, m) = await intermediary();
        const attempts = 25;
        final pairs = <(String, String)>[];
        for (var n = 0; n < attempts; n++) {
          final run = installAdaptive(r, m);
          expect(i.coordinator.tryPair(spoofed(i, r, m)), PairStart.started);
          await bothComparing(i, r);
          final toward = run.towardReceiver!;
          expect(bodyOf(run.startReply!).keys.toSet(), {
            'session',
            'commitment',
          });
          expect(run.receiverViewAtReveal?.phase, PairingPhase.comparing);
          expect(run.receiverViewAtReveal?.code, toward.code);
          final shownByI = i.view!.code!;
          final shownByR = r.view!.code!;
          expect(shownByR, toward.code);
          expect(
            shownByI,
            pairingCode(
              initiatorFingerprint: i.fingerprint,
              receiverFingerprint: m.fingerprint,
              initiatorNonce: run.ni!,
              receiverNonce: m.nonce,
            ),
          );
          expect(i.view!.peerFingerprint, m.fingerprint);
          expect(i.view!.peerFingerprint, isNot(r.fingerprint));
          expect(r.view!.peerFingerprint, toward.identity.fingerprint);
          expect(r.view!.peerFingerprint, isNot(i.fingerprint));
          expect(r.view!.peerName, 'Laptop');
          pairs.add((shownByI, shownByR));
          await bothRefuse(i, r);
          await until(() => m.count(ApiPaths.pairCancel) == n + 1);
          r.clock.advance(const Duration(minutes: 11));
        }
        for (final (shownByI, shownByR) in pairs) {
          expect(shownByI, isNot(shownByR));
          expect(shownByI, matches(RegExp(r'^\d{6}$')));
          expect(shownByR, matches(RegExp(r'^\d{6}$')));
          expect(i.shownCodes, contains(shownByI));
          expect(r.shownCodes, contains(shownByR));
        }
        expect(r.handledOn(ApiPaths.pairStart), attempts);
        expect(r.handledOn(ApiPaths.pairReveal), attempts);
        expect(r.paired.devices, isEmpty);
        expect(i.paired.devices, isEmpty);
        expect(r.completions, isEmpty);
        expect(i.completions, isEmpty);
      },
      timeout: long,
    );

    test('the intermediary learns nothing of the code from pair/start, and '
        'R shows its notice before the intermediary gets Nr', () async {
      final (i, r, m) = await intermediary();
      final run = installAdaptive(r, m);
      i.coordinator.tryPair(spoofed(i, r, m));
      await bothComparing(i, r);
      final start = bodyOf(run.startReply!);
      expect(start.keys.toSet(), {'session', 'commitment'});
      expect(start['session'], matches(RegExp(r'^[0-9a-f]{32}$')));
      expect(start['commitment'], matches(RegExp(r'^[0-9a-f]{64}$')));
      expect(run.receiverViewAtReveal, isNotNull);
      expect(run.receiverViewAtReveal!.phase, PairingPhase.comparing);
      expect(run.receiverViewAtReveal!.role, PairingRole.receiver);
      expect(bodyOf(run.revealReply!)['nonce'], toHex(run.towardReceiver!.nr!));
      await bothRefuse(i, r);
    });

    test('revealing to R a number chosen after seeing Ni is refused, leaves a '
        'note on R and counts towards the block of its origin and the global '
        'cap (RF-105, RF-106b)', () async {
      final (i, r, m) = await intermediary();
      final m2 = DeviceIdentity.generate();
      late ForgedInitiator toward;
      HttpsResponse? cheated;
      m.handlers[ApiPaths.pairStart] = (body) async {
        toward = ForgedInitiator(m2, r);
        final started = await toward.start(name: body['name'] as String?);
        if (started?.status != 200) return rejectedAnswer;
        return (
          200,
          StartReply(session: m.session, commitment: m.commitment).toJson(),
        );
      };
      m.handlers[ApiPaths.pairReveal] = (body) async {
        final ni = hexField(body, 'nonce', nonceLength);
        cheated = await toward.reveal(revealed: chosenAfter([ni]));
        return rejectedAnswer;
      };
      i.coordinator.tryPair(spoofed(i, r, m));
      await until(
        () => i.view?.outcome == PairingOutcome.rejected,
        reason: 'I sees the rejection',
      );
      expect(cheated?.status, 403);
      expect(utf8.decode(cheated!.body), '{"error":"rejected"}');
      expect(r.rejectedAttempts, hasLength(1));
      expect(r.rejectedAttempts.single.fingerprint, m2.fingerprint);
      expect(r.rejectedAttempts.single.cause, AttemptCause.commitmentMismatch);
      expect(r.events.single, isA<PairingAttemptRejected>());
      expect(r.shownCodes, isEmpty);
      expect(r.idle, isTrue);
      expect(i.shownCodes, isEmpty);
      for (var n = 0; n < 2; n++) {
        final again = ForgedInitiator(DeviceIdentity.generate(), r);
        expect((await again.start(name: 'Laptop'))?.status, 200);
        expect((await again.reveal())?.status, 200);
        await until(() => r.view?.phase == PairingPhase.comparing);
        r.coordinator.answerAsReceiver(ReceiverAnswer.mismatch);
        await until(() => r.idle && r.view == null);
      }
      final third = r.clock.now;
      Future<HttpsResponse?> freshFrom(InternetAddress origin) =>
          ForgedInitiator(
            DeviceIdentity.generate(),
            r,
            from: origin,
          ).start(name: 'Laptop');
      final fromM = await freshFrom(hostM);
      final fromB = await freshFrom(hostB);
      expect(fromM?.status, 429);
      expect(fromB?.status, 429);
      expect(fromB!.body, fromM!.body);
      expect(utf8.decode(fromB.body), '{"error":"paused"}');
      expect(r.idle, isTrue);
      await until(() => r.events.length == 2);
      expect(
        r.events.last,
        isA<PairingPaused>().having(
          (e) => e.until,
          'until',
          third.add(Limits.pairingGlobalWindow),
        ),
      );
      r.clock.now = third.add(const Duration(minutes: 9, seconds: 59));
      expect((await freshFrom(hostB))?.status, 429);
      r.clock.now = third.add(const Duration(minutes: 10));
      final elsewhere = ForgedInitiator(
        DeviceIdentity.generate(),
        r,
        from: hostB,
      );
      expect((await elsewhere.start(name: 'Laptop'))?.status, 200);
      expect((await elsewhere.cancel(CancelReason.cancelled))?.status, 200);
      expect(r.paired.devices, isEmpty);
    });

    test('an intermediary that cancels after seeing the code leaves '
        'cancelledByPeer on R', () async {
      final r = await Stack.start(name: 'PC', address: hostA);
      final m2 = DeviceIdentity.generate();
      final toward = ForgedInitiator(m2, r);
      expect((await toward.start(name: 'Laptop'))?.status, 200);
      expect((await toward.reveal())?.status, 200);
      expect(r.view?.phase, PairingPhase.comparing);
      expect(r.view?.code, toward.code);
      final cancelled = await toward.cancel(CancelReason.cancelled);
      expect(bodyOf(cancelled!), {'state': 'cancelled'});
      await until(() => r.view?.outcome == PairingOutcome.cancelledByPeer);
      expect(r.view!.phase, PairingPhase.finished);
      expect(r.view!.peerFingerprint, m2.fingerprint);
      expect(r.view!.peerName, 'Laptop');
      expect(r.shownCodes, contains(toward.code));
      expect(r.idle, isTrue);
      expect(r.paired.devices, isEmpty);
    });

    test(
      'three "does not match" from the origin of the intermediary block it '
      'and pause R for 10 minutes, with the paused reply for anybody',
      () async {
        final (i, r, m) = await intermediary();
        for (var n = 0; n < 3; n++) {
          installAdaptive(r, m);
          i.coordinator.tryPair(spoofed(i, r, m));
          await bothComparing(i, r);
          await bothRefuse(i, r);
        }
        final started = r.clock.now;
        Future<int?> freshStart() async => (await ForgedInitiator(
          DeviceIdentity.generate(),
          r,
        ).start(name: 'Laptop'))?.status;
        expect(await freshStart(), 429);
        r.clock.now = started.add(const Duration(minutes: 9, seconds: 59));
        expect(await freshStart(), 429);
        expect(r.events.whereType<PairingPaused>(), hasLength(1));
        installAdaptive(r, m);
        i.coordinator.tryPair(spoofed(i, r, m));
        await until(
          () => i.view?.outcome == PairingOutcome.rejected,
          reason: 'I is refused while M is blocked',
        );
        expect(r.shownCodes, hasLength(3));
        r.clock.now = started.add(const Duration(minutes: 10));
        final after = ForgedInitiator(DeviceIdentity.generate(), r);
        expect((await after.start(name: 'Laptop'))?.status, 200);
        expect((await after.cancel(CancelReason.cancelled))?.status, 200);
        expect(r.paired.devices, isEmpty);
      },
      timeout: long,
    );

    test('an intermediary that gives up before revealing learns only Cr and '
        'R stays silent', () async {
      final r = await Stack.start(name: 'PC', address: hostA);
      final toward = ForgedInitiator(DeviceIdentity.generate(), r);
      final started = await toward.start(name: 'Laptop');
      expect(bodyOf(started!).keys.toSet(), {'session', 'commitment'});
      expect(r.coordinator.busy, isTrue);
      expect(r.view, isNull);
      r.clock.advance(const Duration(seconds: 10, milliseconds: 1));
      await until(() => r.idle, reason: 'R drops the silent session');
      expect(r.view, isNull);
      expect(r.views.every((v) => v == null), isTrue);
      expect(r.events, isEmpty);
      expect((await toward.reveal())?.status, 404);
      expect(r.shownCodes, isEmpty);
    });

    test('a number revealed to I that differs from the commitment of the '
        'intermediary is refused before any code is shown', () async {
      final (i, r, m) = await intermediary();
      final run = installAdaptive(r, m);
      m.handlers[ApiPaths.pairReveal] = (body) {
        final ni = hexField(body, 'nonce', nonceLength);
        run.ni = ni;
        final forged = chosenAfter([
          ni,
          run.towardReceiver!.nr!,
          utf8.encode(run.towardReceiver!.code),
        ]);
        return (200, RevealReply(nonce: forged).toJson());
      };
      i.coordinator.tryPair(spoofed(i, r, m));
      await until(
        () => i.view?.outcome == PairingOutcome.failed,
        reason: 'I refuses the forged number',
      );
      await until(() => m.count(ApiPaths.pairCancel) == 1);
      expect(m.callsTo(ApiPaths.pairCancel).single.body['reason'], 'cancelled');
      expect(i.shownCodes, isEmpty);
      expect(i.views.every((v) => v?.code == null), isTrue);
      expect(m.count(ApiPaths.pairWait), 0);
      expect(r.view?.phase, PairingPhase.comparing);
      r.coordinator.answerAsReceiver(ReceiverAnswer.mismatch);
      await until(() => r.idle);
      expect(i.paired.devices, isEmpty);
      expect(r.paired.devices, isEmpty);
    });

    test('an intermediary that tells I "paired" before its user confirms '
        'gets nothing saved', () async {
      final (i, r, m) = await intermediary();
      installAdaptive(r, m);
      i.coordinator.tryPair(spoofed(i, r, m));
      await bothComparing(i, r);
      m.waitState = 'paired';
      await until(
        () => i.view?.outcome == PairingOutcome.failed,
        reason: 'I refuses an unconfirmed "paired"',
      );
      await until(() => m.count(ApiPaths.pairCancel) == 1);
      expect(m.count(ApiPaths.pairConfirm), 0);
      expect(i.paired.devices, isEmpty);
      expect(await i.reloadPaired(), isEmpty);
      expect(i.completions, isEmpty);
      r.coordinator.answerAsReceiver(ReceiverAnswer.mismatch);
      await until(() => r.idle);
    });

    test('an intermediary that confirms to R without the user of R never '
        'gets paired', () async {
      final r = await Stack.start(name: 'PC', address: hostA);
      r.probeUnpair();
      final m2 = DeviceIdentity.generate();
      final toward = ForgedInitiator(m2, r);
      expect((await toward.start(name: 'Laptop'))?.status, 200);
      expect((await toward.reveal())?.status, 200);
      for (var n = 0; n < 3; n++) {
        expect(bodyOf((await toward.confirm())!), {'state': 'pending'});
      }
      expect(bodyOf((await toward.wait())!), {'state': 'pending'});
      expect(r.view?.phase, PairingPhase.comparing);
      expect(r.paired.devices, isEmpty);
      r.clock.advance(Limits.pairingTimeout);
      await until(() => r.view?.outcome == PairingOutcome.expired);
      expect(bodyOf((await toward.confirm())!), {'state': 'expired'});
      expect(r.paired.devices, isEmpty);
      expect(await r.reloadPaired(), isEmpty);
      expect(r.completions, isEmpty);
      final withCertificate = await postTo(
        r,
        ApiPaths.unpair,
        from: hostM,
        context: m2.clientContext(presentCertificate: true),
      );
      expect(withCertificate, isNull);
      expect(r.handledOn(ApiPaths.unpair), 0);
    });

    test('relaying the presentation of I to R is refused, because it is '
        'signed for the fingerprint of the intermediary', () async {
      final (i, r, m) = await intermediary();
      HttpsResponse? relayed;
      m.handlers[ApiPaths.pairStart] = (body) async {
        relayed = await postTo(r, ApiPaths.pairStart, from: hostM, json: body);
        return (relayed!.status, bodyOf(relayed!));
      };
      i.coordinator.tryPair(spoofed(i, r, m));
      await until(() => i.view?.outcome == PairingOutcome.rejected);
      expect(relayed?.status, 403);
      expect(utf8.decode(relayed!.body), '{"error":"rejected"}');
      expect(r.handledOn(ApiPaths.pairStart), 1);
      expect(r.handledOn(ApiPaths.pairReveal), 0);
      expect(r.idle, isTrue);
      expect(r.views.every((v) => v == null), isTrue);
      expect(r.events, isEmpty);
    });

    test('reflecting the commitment of I to R is caught by R at the '
        'reveal', () async {
      final (i, r, m) = await intermediary();
      final m2 = DeviceIdentity.generate();
      late ForgedInitiator toward;
      HttpsResponse? reflected;
      m.handlers[ApiPaths.pairStart] = (body) async {
        toward = ForgedInitiator(m2, r);
        final started = await toward.start(
          name: body['name'] as String?,
          commitWith: hexField(body, 'commitment', commitmentLength),
        );
        if (started?.status != 200) return rejectedAnswer;
        return (
          200,
          StartReply(session: m.session, commitment: toward.cr!).toJson(),
        );
      };
      m.handlers[ApiPaths.pairReveal] = (body) async {
        final ni = hexField(body, 'nonce', nonceLength);
        reflected = await toward.reveal(revealed: ni);
        return (200, RevealReply(nonce: m.nonce).toJson());
      };
      i.coordinator.tryPair(spoofed(i, r, m));
      await until(() => i.view?.outcome == PairingOutcome.failed);
      expect(reflected?.status, 403);
      expect(r.rejectedAttempts, hasLength(1));
      expect(r.shownCodes, isEmpty);
      expect(i.shownCodes, isEmpty);
      expect(r.paired.devices, isEmpty);
      expect(i.paired.devices, isEmpty);
    });

    test(
      'reflecting the commitment and the number of R to I is caught by I',
      () async {
        final (i, r, m) = await intermediary();
        final m2 = DeviceIdentity.generate();
        late ForgedInitiator toward;
        m.handlers[ApiPaths.pairStart] = (body) async {
          toward = ForgedInitiator(m2, r);
          final started = await toward.start(name: body['name'] as String?);
          if (started?.status != 200) return rejectedAnswer;
          return (
            200,
            StartReply(session: m.session, commitment: toward.cr!).toJson(),
          );
        };
        m.handlers[ApiPaths.pairReveal] = (body) async {
          final revealed = await toward.reveal();
          if (revealed?.status != 200) return rejectedAnswer;
          return (200, RevealReply(nonce: toward.nr!).toJson());
        };
        i.coordinator.tryPair(spoofed(i, r, m));
        await until(() => i.view?.outcome == PairingOutcome.failed);
        expect(i.shownCodes, isEmpty);
        expect(r.view?.phase, PairingPhase.comparing);
        expect(r.view?.code, toward.code);
        r.coordinator.answerAsReceiver(ReceiverAnswer.mismatch);
        await until(() => r.idle);
        expect(r.paired.devices, isEmpty);
        expect(i.paired.devices, isEmpty);
      },
    );
  });

  group('C54 requests are only sent when the user asks (RF-69, SEC-15)', () {
    test('interface changes, paired list changes, ticks and every other call '
        'never send pair/start', () async {
      final a = await Stack.start(name: 'PC', address: hostA);
      final b = await Stack.start(name: 'Laptop', address: hostB);
      await idleFor(const Duration(milliseconds: 300));
      for (final stack in [a, b]) {
        stack.coordinator
          ..interfacesChanged({})
          ..interfacesChanged({stack.iface.id})
          ..answerAsInitiator(matches: true)
          ..answerAsInitiator(matches: false)
          ..cancelAsInitiator()
          ..answerAsReceiver(ReceiverAnswer.matches)
          ..answerAsReceiver(ReceiverAnswer.mismatch)
          ..answerAsReceiver(ReceiverAnswer.ignore)
          ..dismissOutcome();
        stack.clock.advance(const Duration(seconds: 61));
      }
      await idleFor();
      await a.paired.replaceAll([pairedDeviceOf(b.identity)]);
      await b.paired.replaceAll([pairedDeviceOf(a.identity)]);
      await a.trustSettled();
      await b.trustSettled();
      expect(await a.coordinator.checkPeer(a.targetOf(b)), PeerStatus.paired);
      expect(await a.coordinator.notifyUnpaired(a.targetOf(b)), isTrue);
      await until(() => b.paired.devices.isEmpty);
      await a.paired.remove(b.fingerprint);
      await a.trustSettled();
      await b.trustSettled();
      for (final stack in [a, b]) {
        stack.clock.advance(const Duration(minutes: 11));
        stack.coordinator.interfacesChanged({stack.iface.id});
      }
      await idleFor(const Duration(milliseconds: 300));
      expect(b.handledOn(ApiPaths.pairStatus), 1);
      expect(b.handledOn(ApiPaths.unpair), 1);
      for (final stack in [a, b]) {
        for (final path in [
          ApiPaths.pairStart,
          ApiPaths.pairReveal,
          ApiPaths.pairWait,
          ApiPaths.pairConfirm,
          ApiPaths.pairCancel,
        ]) {
          expect(stack.handledOn(path), 0, reason: '${stack.name} $path');
        }
        expect(stack.views.every((v) => v == null), isTrue);
        expect(stack.idle, isTrue);
      }
      expect(a.handledOn(ApiPaths.pairStatus), 0);
      expect(a.handledOn(ApiPaths.unpair), 0);
    }, timeout: long);
  });

  group('two real stacks pair and trust each other (RF-87, RF-95, RF-97)', () {
    test('after the full flow each side accepts the certificate of the other '
        'without a restart, and both keep the other as foreign', () async {
      final a = await Stack.start(name: 'PC', address: hostA);
      final b = await Stack.start(name: 'Laptop', address: hostB);
      a.probeUnpair();
      b.probeUnpair();
      final portA = a.port;
      final portB = b.port;
      final beforeA = await postTo(
        b,
        ApiPaths.unpair,
        from: hostA,
        context: a.identity.clientContext(presentCertificate: true),
      );
      final beforeB = await postTo(
        a,
        ApiPaths.unpair,
        from: hostB,
        context: b.identity.clientContext(presentCertificate: true),
      );
      expect(beforeA, isNull);
      expect(beforeB, isNull);
      expect(a.handledOn(ApiPaths.unpair), 0);
      expect(b.handledOn(ApiPaths.unpair), 0);
      await pairThroughFlow(a, b);
      final fromA = await postTo(
        b,
        ApiPaths.unpair,
        from: hostA,
        context: a.identity.clientContext(presentCertificate: true),
      );
      final fromB = await postTo(
        a,
        ApiPaths.unpair,
        from: hostB,
        context: b.identity.clientContext(presentCertificate: true),
      );
      expect(fromA?.status, 200);
      expect(bodyOf(fromA!), {'probe': true});
      expect(fromB?.status, 200);
      expect(b.handledOn(ApiPaths.unpair), 1);
      expect(a.handledOn(ApiPaths.unpair), 1);
      expect(a.port, portA);
      expect(b.port, portB);
      expect(a.server.openInterfaceIds, {a.iface.id});
      expect(b.server.openInterfaceIds, {b.iface.id});
      expect(a.paired.deviceOf(b.fingerprint)?.relation, PeerRelation.foreign);
      expect(b.paired.deviceOf(a.fingerprint)?.relation, PeerRelation.foreign);
      expect((await a.reloadPaired()).single.relation, PeerRelation.foreign);
      expect((await b.reloadPaired()).single.relation, PeerRelation.foreign);
      expect(a.completions.single.isNew, isTrue);
      expect(b.completions.single.isNew, isTrue);
    }, timeout: long);
  });

  group('C56 both press "Pair" on each other at once', () {
    test(
      'both see busy, nothing is saved, and one of them can retry alone',
      () async {
        final a = await Stack.start(name: 'PC', address: hostA);
        final b = await Stack.start(name: 'Laptop', address: hostB);
        for (var round = 0; round < 3; round++) {
          expect(a.coordinator.tryPair(a.targetOf(b)), PairStart.started);
          expect(b.coordinator.tryPair(b.targetOf(a)), PairStart.started);
          await until(
            () =>
                a.view?.outcome == PairingOutcome.busy &&
                b.view?.outcome == PairingOutcome.busy,
            reason: 'both busy',
          );
          expect(a.handledOn(ApiPaths.pairStart), round + 1);
          expect(b.handledOn(ApiPaths.pairStart), round + 1);
          expect(a.handledOn(ApiPaths.pairReveal), 0);
          expect(b.handledOn(ApiPaths.pairReveal), 0);
          expect(a.shownCodes, isEmpty);
          expect(b.shownCodes, isEmpty);
          expect(a.paired.devices, isEmpty);
          expect(b.paired.devices, isEmpty);
          a.coordinator.dismissOutcome();
          b.coordinator.dismissOutcome();
        }
        expect(a.events, isEmpty);
        expect(b.events, isEmpty);
        expect(await a.reloadPaired(), isEmpty);
        expect(await b.reloadPaired(), isEmpty);
        await pairThroughFlow(a, b);
        expect(a.paired.isPaired(b.fingerprint), isTrue);
        expect(b.paired.isPaired(a.fingerprint), isTrue);
      },
    );
  });

  group('C57 the initiator cancels while the receiver confirms', () {
    Future<(Stack, Stack)> comparing() async {
      final i = await Stack.start(name: 'Laptop', address: hostB);
      final r = await Stack.start(name: 'PC', address: hostA);
      i.coordinator.tryPair(i.targetOf(r));
      await bothComparing(i, r);
      return (i, r);
    }

    Future<void> expectBothCancelled(Stack i, Stack r) async {
      await until(
        () =>
            r.view?.outcome == PairingOutcome.cancelledByPeer &&
            i.idle &&
            r.idle,
        reason: 'both cancelled',
      );
      expect(i.view, isNull);
      expect(r.handledOn(ApiPaths.pairCancel), 1);
      expect(r.handledOn(ApiPaths.pairConfirm), 0);
      expect(i.paired.devices, isEmpty);
      expect(r.paired.devices, isEmpty);
      expect(await i.reloadPaired(), isEmpty);
      expect(await r.reloadPaired(), isEmpty);
      expect(i.completions, isEmpty);
      expect(r.completions, isEmpty);
    }

    test('in the same turn, receiver first', () async {
      final (i, r) = await comparing();
      r.coordinator.answerAsReceiver(ReceiverAnswer.matches);
      i.coordinator.cancelAsInitiator();
      await expectBothCancelled(i, r);
    });

    test('in the same turn, initiator first', () async {
      final (i, r) = await comparing();
      i.coordinator.cancelAsInitiator();
      r.coordinator.answerAsReceiver(ReceiverAnswer.matches);
      await expectBothCancelled(i, r);
    });

    test('the receiver already waits for the initiator', () async {
      final (i, r) = await comparing();
      r.coordinator.answerAsReceiver(ReceiverAnswer.matches);
      await until(() => r.view?.phase == PairingPhase.waitingPeer);
      i.coordinator.answerAsInitiator(matches: false);
      await expectBothCancelled(i, r);
    });
  });

  group('C62 a device named like a paired one with another fingerprint '
      '(RF-123, SEC-17)', () {
    test('its client certificate is cut in the handshake and it can only '
        'try to pair, which is refused', () async {
      final a = await Stack.start(name: 'PC', address: hostA);
      a.probeUnpair();
      final original = DeviceIdentity.generate();
      await a.paired.replaceAll([
        PairedDevice(
          fingerprint: original.fingerprint,
          name: 'Laptop',
          certificatePem: original.certificatePem,
          relation: PeerRelation.mine,
          pairedAt: DateTime.utc(2026, 10, 1),
        ),
      ]);
      await a.trustSettled();
      final control = await postTo(
        a,
        ApiPaths.unpair,
        from: hostB,
        context: original.clientContext(presentCertificate: true),
      );
      expect(control?.status, 200);
      expect(a.handledOn(ApiPaths.unpair), 1);
      final commonName = original.certificate.commonName;
      final twin = HandMadeCertificate(commonName);
      final utf8Twin = HandMadeCertificate(commonName, utf8CommonName: true);
      expect(twin.identity, isNull);
      expect(utf8Twin.identity, isNull);
      final namesake = DeviceIdentity.generate();
      final impostors = <String, SecurityContext>{
        'twin': presentingHandMade(twin),
        'UTF8String twin': presentingHandMade(utf8Twin),
        'namesake': namesake.clientContext(presentCertificate: true),
      };
      expect(twin.fingerprint, isNot(original.fingerprint));
      expect(utf8Twin.fingerprint, isNot(original.fingerprint));
      for (final MapEntry(key: label, value: context) in impostors.entries) {
        final reply = await postTo(
          a,
          ApiPaths.unpair,
          from: hostB,
          context: context,
        );
        expect(reply, isNull, reason: label);
      }
      expect(a.handledOn(ApiPaths.unpair), 1);
      final ci = commitmentOf(
        role: PairingRole.initiator,
        fingerprint: twin.fingerprint,
        nonce: randomBytes(nonceLength),
      );
      final started = await postTo(
        a,
        ApiPaths.pairStart,
        from: hostB,
        json: StartRequest(
          certificate: twin.pem,
          name: 'Laptop',
          deviceType: DeviceType.desktop,
          commitment: ci,
          proof: twin.sign(
            startTranscript(
              initiatorFingerprint: twin.fingerprint,
              receiverFingerprint: a.fingerprint,
              name: 'Laptop',
              deviceType: DeviceType.desktop,
              initiatorCommitment: ci,
            ),
          ),
        ).toJson(),
      );
      expect(started?.status, 403);
      final namesakeStack = await Stack.start(
        name: 'Laptop',
        address: hostM,
        identity: namesake,
      );
      expect(
        await namesakeStack.coordinator.checkPeer(namesakeStack.targetOf(a)),
        PeerStatus.notPaired,
      );
      expect(a.view, isNull);
      expect(a.shownCodes, isEmpty);
      expect(a.paired.devices, hasLength(1));
      expect(a.paired.devices.single.fingerprint, original.fingerprint);
      expect(a.paired.devices.single.relation, PeerRelation.mine);
      expect(a.handledOn(ApiPaths.unpair), 1);
    });
  });

  group('C63 an unpaired device that tries to get back in (SEC-18, '
      'RF-113)', () {
    test('it is cut in the handshake, its open connection is closed, reusing '
        'its old TLS context does not help, and it can pair again', () async {
      final a = await Stack.start(name: 'PC', address: hostA);
      final b = await Stack.start(name: 'Laptop', address: hostB);
      await pairThroughFlow(b, a);
      a.probeUnpair();
      final reused = b.identity.clientContext(presentCertificate: true);
      final before = await postTo(
        a,
        ApiPaths.unpair,
        from: hostB,
        context: reused,
      );
      expect(before?.status, 200);
      expect(a.handledOn(ApiPaths.unpair), 1);
      final open = await TlsClient.connect(
        a.port,
        serverFingerprint: a.fingerprint,
        context: b.identity.clientContext(presentCertificate: true),
        from: hostB,
        to: hostA,
      );
      await idleFor(const Duration(milliseconds: 100));
      expect(open.isClosed, isFalse);
      final removing = Stopwatch()..start();
      await a.paired.remove(b.fingerprint);
      await a.trustSettled();
      await open.closed.timeout(const Duration(seconds: 1));
      expect(removing.elapsed, lessThan(const Duration(seconds: 1)));
      expect(open.received, isEmpty);
      final afterReused = await postTo(
        a,
        ApiPaths.unpair,
        from: hostB,
        context: reused,
      );
      final afterFresh = await postTo(
        a,
        ApiPaths.unpair,
        from: hostB,
        context: b.identity.clientContext(presentCertificate: true),
      );
      final onAnonymousPath = await postTo(
        a,
        ApiPaths.pairStart,
        from: hostB,
        context: b.identity.clientContext(presentCertificate: true),
      );
      expect(afterReused, isNull);
      expect(afterFresh, isNull);
      expect(onAnonymousPath, isNull);
      expect(await b.coordinator.notifyUnpaired(b.targetOf(a)), isFalse);
      expect(a.handledOn(ApiPaths.unpair), 1);
      expect(a.handledOn(ApiPaths.pairStart), 1);
      expect(
        await b.coordinator.checkPeer(b.targetOf(a)),
        PeerStatus.notPaired,
      );
      expect(b.paired.isPaired(a.fingerprint), isTrue);
      await pairThroughFlow(b, a);
      expect(a.paired.isPaired(b.fingerprint), isTrue);
      expect(b.completions.last.isNew, isFalse);
      expect(a.completions.last.isNew, isTrue);
      final back = await postTo(
        a,
        ApiPaths.unpair,
        from: hostB,
        context: reused,
      );
      expect(back?.status, 200);
      expect(a.handledOn(ApiPaths.unpair), 2);
    }, timeout: long);

    test('a request on a connection opened before the removal and before '
        'the trust is rebuilt gets 401 without reaching the route', () async {
      final a = await Stack.start(name: 'PC', address: hostA, autoTrust: false);
      final b = DeviceIdentity.generate();
      await a.paired.replaceAll([pairedDeviceOf(b)]);
      await a.server.rebuildTrust();
      final open = await TlsClient.connect(
        a.port,
        serverFingerprint: a.fingerprint,
        context: b.clientContext(presentCertificate: true),
        from: hostB,
        to: hostA,
      );
      await a.paired.remove(b.fingerprint);
      open.write(httpRequest('POST', ApiPaths.unpair, body: jsonBody({})));
      final reply = await open.reply();
      expect(reply?.status, 401);
      expect(reply?.json, {'error': 'unauthorized'});
      expect(a.handledOn(ApiPaths.unpair), 0);
      expect(a.events, isEmpty);
      await a.server.rebuildTrust();
      final after = await postTo(
        a,
        ApiPaths.unpair,
        from: hostB,
        context: b.clientContext(presentCertificate: true),
      );
      expect(after, isNull);
      expect(a.handledOn(ApiPaths.unpair), 0);
    });
  });
}
