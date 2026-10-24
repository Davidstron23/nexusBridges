import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:nexus_bridges_core/src/identity/identity.dart';
import 'package:nexus_bridges_core/src/pairing/pairing.dart';
import 'package:nexus_bridges_core/src/pairing_flow/crypto.dart';
import 'package:nexus_bridges_core/src/pairing_flow/messages.dart';
import 'package:nexus_bridges_core/src/pairing_flow/pairing_flow.dart';
import 'package:nexus_bridges_core/src/protocol/protocol.dart';
import 'package:nexus_bridges_core/src/server/server.dart';
import 'package:nexus_bridges_core/src/storage/storage.dart';
import 'package:test/test.dart';

import '../server/api_server_harness.dart';
import 'receiver_harness.dart';

final Uint8List rejectedBody = utf8.encode('{"error":"rejected"}');
final Uint8List notFoundBody = utf8.encode('{"error":"not_found"}');
final Uint8List busyBody = utf8.encode('{"error":"busy"}');
final Uint8List pausedBody = utf8.encode('{"error":"paused"}');

void main() {
  late DeviceIdentity r;
  late DeviceIdentity otherReceiver;
  late DeviceIdentity a;
  late DeviceIdentity b;
  late DeviceIdentity c;
  late DeviceIdentity d;

  setUpAll(() {
    r = DeviceIdentity.generate();
    otherReceiver = DeviceIdentity.generate();
    a = DeviceIdentity.generate();
    b = DeviceIdentity.generate();
    c = DeviceIdentity.generate();
    d = DeviceIdentity.generate();
  });

  Future<ReceiverFixture> receiver({
    Iterable<DeviceIdentity> pairedWith = const [],
    Duration pollHold = const Duration(milliseconds: 200),
    Duration saveTimeout = Limits.pairingMessageTimeout,
    bool twoInterfaces = false,
    bool ticking = true,
    Directory? dataDir,
  }) => ReceiverFixture.start(
    identity: r,
    pairedWith: pairedWith,
    pollHold: pollHold,
    saveTimeout: saveTimeout,
    twoInterfaces: twoInterfaces,
    ticking: ticking,
    dataDir: dataDir,
  );

  void expectRejected(RawReply? reply, {String reason = ''}) {
    expect(reply, isNotNull, reason: reason);
    expect(reply!.status, 403, reason: reason);
    expect(reply.body, rejectedBody, reason: reason);
  }

  void expectPaused(RawReply? reply, {String reason = ''}) {
    expect(reply, isNotNull, reason: reason);
    expect(reply!.status, 429, reason: reason);
    expect(reply.body, pausedBody, reason: reason);
  }

  void expectNotFound(RawReply? reply, {String reason = ''}) {
    expect(reply, isNotNull, reason: reason);
    expect(reply!.status, 404, reason: reason);
    expect(reply.body, notFoundBody, reason: reason);
  }

  void expectState(RawReply? reply, String state, {String reason = ''}) {
    expect(reply, isNotNull, reason: reason);
    expect(reply!.status, 200, reason: reason);
    expect(reply.json, {'state': state}, reason: reason);
  }

  Future<void> finishWithMismatch(
    ReceiverFixture fixture,
    DeviceIdentity identity, {
    InternetAddress? from,
  }) async {
    await fixture.initiator(identity, from: from).begin();
    fixture.coordinator.answerAsReceiver(ReceiverAnswer.mismatch);
    expect(fixture.coordinator.busy, isFalse);
  }

  Future<void> finishWithPeerCancel(
    ReceiverFixture fixture,
    DeviceIdentity identity, {
    InternetAddress? from,
  }) async {
    final initiator = fixture.initiator(identity, from: from);
    await initiator.begin();
    expectState(await initiator.cancel(CancelReason.cancelled), 'cancelled');
  }

  Future<void> completePairing(
    ReceiverFixture fixture,
    DeviceIdentity identity, {
    InternetAddress? from,
  }) async {
    final initiator = fixture.initiator(identity, from: from);
    await initiator.begin();
    fixture.coordinator.answerAsReceiver(ReceiverAnswer.matches);
    expectState(await initiator.confirm(), 'paired');
  }

  group('pair/start accepted (RF-74, RF-78, A7)', () {
    test('a valid presentation gets 200 with only session and commitment, '
        'reserves the slot and shows nothing yet', () async {
      final fixture = await receiver();

      final reply = await fixture.initiator(a).start();

      expect(reply!.status, 200);
      expect(reply.json.keys.toSet(), {'session', 'commitment'});
      expect(reply.json['session'], matches(RegExp(r'^[0-9a-f]{32}$')));
      expect(reply.json['commitment'], matches(RegExp(r'^[0-9a-f]{64}$')));
      expect(fixture.coordinator.busy, isTrue);
      expect(fixture.view, isNull);
      await eventually(() => fixture.busyStates.isNotEmpty);
      expect(fixture.views.last, isNull);
      expect(fixture.busyStates.last, isTrue);
      expect(fixture.events, isEmpty);
    });

    test('the receiver commitment opens with the nonce revealed later, bound '
        'to the receiver role and fingerprint (RF-77)', () async {
      final fixture = await receiver();
      final initiator = fixture.initiator(a);

      await initiator.begin();

      expect(
        commitmentMatches(
          initiator.cr!,
          role: PairingRole.receiver,
          fingerprint: r.fingerprint,
          nonce: initiator.nr!,
        ),
        isTrue,
      );
      expect(
        commitmentMatches(
          initiator.cr!,
          role: PairingRole.initiator,
          fingerprint: r.fingerprint,
          nonce: initiator.nr!,
        ),
        isFalse,
      );
    });
  });

  group('pair/start rejections are identical (RF-74, RF-75, C42)', () {
    late List<DeviceIdentity> crowd;

    setUpAll(() {
      crowd = [for (var i = 0; i < 32; i++) DeviceIdentity.generate()];
    });

    Future<void> expectSilentRejection(
      ReceiverFixture fixture,
      Future<RawReply?> Function() attempt, {
      required String reason,
    }) async {
      final changesBefore = fixture.views.length;
      final handledBefore = fixture.handledOn(ApiPaths.pairStart);
      final stopwatch = Stopwatch()..start();
      final reply = await attempt();
      stopwatch.stop();
      expectRejected(reply, reason: reason);
      expect(stopwatch.elapsed, lessThan(const Duration(seconds: 1)));
      expect(
        fixture.handledOn(ApiPaths.pairStart),
        handledBefore + 1,
        reason: '$reason reaches the pairing logic',
      );
      await settle();
      expect(fixture.view, isNull, reason: reason);
      expect(fixture.coordinator.busy, isFalse, reason: reason);
      expect(fixture.views.length, changesBefore, reason: reason);
      expect(fixture.events, isEmpty, reason: reason);
    }

    test(
      'the sixth presentation from an origin in 10 minutes (RF-103)',
      () async {
        final fixture = await receiver();
        for (var i = 0; i < 5; i++) {
          final initiator = fixture.initiator(a);
          expect((await initiator.start())!.status, 200);
          expectState(
            await initiator.cancel(CancelReason.cancelled),
            'cancelled',
          );
        }

        await expectSilentRejection(
          fixture,
          () => fixture.initiator(a).start(),
          reason: 'origin over its limit',
        );
      },
    );

    test('an origin blocked after 3 mismatches (RF-104), spread so that the '
        'global pause is not active', () async {
      final fixture = await receiver();
      for (var i = 0; i < 3; i++) {
        if (i > 0) fixture.advance(const Duration(minutes: 5));
        await finishWithMismatch(fixture, a);
      }
      await settle();
      fixture.views.clear();

      await expectSilentRejection(
        fixture,
        () => fixture.initiator(b).start(),
        reason: 'blocked origin',
      );
    });

    test('an ignored initiator (RF-108)', () async {
      final fixture = await receiver();
      await fixture.ignored.ignore(a.fingerprint, name: 'Laptop');

      await expectSilentRejection(
        fixture,
        () => fixture.initiator(a).start(),
        reason: 'ignored',
      );
    });

    test('32 paired and the initiator is new (RF-74)', () async {
      final fixture = await receiver(pairedWith: crowd);
      expect(fixture.paired.devices, hasLength(32));

      await expectSilentRejection(
        fixture,
        () => fixture.initiator(a).start(),
        reason: 'list full',
      );
      expect((await fixture.initiator(crowd.first).start())!.status, 200);
    });

    test('the receiver own fingerprint', () async {
      final fixture = await receiver();

      await expectSilentRejection(
        fixture,
        () => fixture.initiator(r).start(),
        reason: 'own fingerprint',
      );
    });

    test('a subject that clashes with a paired device of another '
        'fingerprint (RF-93)', () async {
      final fixture = await receiver(pairedWith: [b]);
      final twin = HandMadeCertificate(b.certificate.commonName);
      expect(twin.fingerprint, isNot(b.fingerprint));
      expect(twin.identity, isNull);

      await expectSilentRejection(
        fixture,
        () => fixture
            .initiator(a)
            .start(
              certificatePem: twin.pem,
              signerFingerprint: twin.fingerprint,
              sign: twin.sign,
            ),
        reason: 'subject clash',
      );
      expect(fixture.paired.devices.single.fingerprint, b.fingerprint);
      expect(fixture.paired.devices.single.relation, PeerRelation.mine);
    });

    test('valid JSON with one extra key', () async {
      final fixture = await receiver();

      await expectSilentRejection(
        fixture,
        () => fixture.initiator(a).start(edit: (body) => {...body, 'x': 1}),
        reason: 'extra key',
      );
    });

    test('valid JSON with protocol 2.0', () async {
      final fixture = await receiver();

      await expectSilentRejection(
        fixture,
        () => fixture
            .initiator(a)
            .start(edit: (body) => {...body, 'protocol': '2.0'}),
        reason: 'protocol 2.0',
      );
    });

    test('a name of 257 UTF-16 units', () async {
      final fixture = await receiver();

      await expectSilentRejection(
        fixture,
        () => fixture.initiator(a).start(name: 'n' * 257),
        reason: 'long name',
      );
    });

    test('a certificate whose common name is not valid, signed by its own '
        'key', () async {
      final fixture = await receiver();
      for (final commonName in [
        'NexusBridges-api-alice',
        'NEXUSBRIDGES-0123456789ABCDEF',
        'NexusBridges-0123456789abcde',
      ]) {
        final forged = HandMadeCertificate(commonName);
        await expectSilentRejection(
          fixture,
          () => fixture
              .initiator(a)
              .start(
                certificatePem: forged.pem,
                signerFingerprint: forged.fingerprint,
                sign: forged.sign,
              ),
          reason: 'common name $commonName',
        );
      }
    });

    test('every reason gives the same bytes as every other one', () async {
      final fixture = await receiver();
      final replies = <RawReply?>[
        await fixture.initiator(r).start(),
        await fixture.initiator(a).start(edit: (body) => {...body, 'x': 1}),
        await fixture.initiator(a).start(sign: b.sign),
      ];
      final bodies = {for (final reply in replies) utf8.decode(reply!.body)};
      final statuses = {for (final reply in replies) reply!.status};

      expect(bodies, {'{"error":"rejected"}'});
      expect(statuses, {403});
    });
  });

  group('signatures (RF-80, RF-81, SEC-14, C41)', () {
    test('a proof made by another key over the right transcript', () async {
      final fixture = await receiver();

      expectRejected(await fixture.initiator(a).start(sign: b.sign));
      expect(fixture.coordinator.busy, isFalse);
      expect(fixture.view, isNull);
    });

    test('the certificate of A with a proof signed by B', () async {
      final fixture = await receiver();

      expectRejected(
        await fixture
            .initiator(b)
            .start(
              certificatePem: a.certificatePem,
              signerFingerprint: a.fingerprint,
            ),
      );
      expect(fixture.coordinator.busy, isFalse);
    });

    test('a proof by the right key over another transcript', () async {
      final fixture = await receiver();
      final initiator = fixture.initiator(a);

      expectRejected(
        await initiator.start(
          edit: (body) => {
            ...body,
            'proof': toHex(
              a.sign(
                startTranscript(
                  initiatorFingerprint: a.fingerprint,
                  receiverFingerprint: r.fingerprint,
                  name: 'Another name',
                  deviceType: DeviceType.desktop,
                  initiatorCommitment: initiator.ci,
                ),
              ),
            ),
          },
        ),
      );
      expectRejected(
        await fixture
            .initiator(a)
            .start(edit: (body) => {...body, 'deviceType': 'mobile'}),
      );
      expect(fixture.coordinator.busy, isFalse);
    });

    test('a presentation of I addressed to R1 and sent to R2 (C93)', () async {
      final fixture = await receiver();

      expectRejected(
        await fixture
            .initiator(a)
            .start(receiverFingerprint: otherReceiver.fingerprint),
      );
      expect(fixture.coordinator.busy, isFalse);
      expect(fixture.view, isNull);
    });

    test('a reveal with an invalid signature is rejected, deletes the session, '
        'shows nothing and does not count as a mismatch', () async {
      final fixture = await receiver();
      for (var i = 0; i < 3; i++) {
        final initiator = fixture.initiator(a);
        expect((await initiator.start())!.status, 200);
        final forged = i == 0
            ? b.sign(initiator.startT!)
            : i == 1
            ? randomBytes(signatureLength)
            : Uint8List(signatureLength);
        expectRejected(await initiator.reveal(signature: forged));
        expect(fixture.coordinator.busy, isFalse);
        expect(fixture.view, isNull);
        expectNotFound(await initiator.wait());
      }

      expect((await fixture.initiator(a).start())!.status, 200);
      await settle();
      expect(fixture.events, isEmpty);
    });

    test(
      'a reveal signed over the transcript of another session (C93)',
      () async {
        final fixture = await receiver();
        final first = fixture.initiator(a);
        expect((await first.start())!.status, 200);
        final firstSession = first.session!;
        expectState(await first.cancel(CancelReason.cancelled), 'cancelled');
        final second = fixture.initiator(a);
        expect((await second.start())!.status, 200);

        expectRejected(
          await second.reveal(
            signature: second.revealSignature(sessionId: firstSession),
          ),
        );
        expect(fixture.coordinator.busy, isFalse);
        expect(fixture.view, isNull);
      },
    );

    test(
      'a reveal signed with the start transcript of another session',
      () async {
        final fixture = await receiver();
        final first = fixture.initiator(a);
        expect((await first.start(name: 'First'))!.status, 200);
        final firstTranscript = first.startT!;
        expectState(await first.cancel(CancelReason.cancelled), 'cancelled');
        final second = fixture.initiator(a);
        expect((await second.start(name: 'Second'))!.status, 200);

        final signature = a.sign(
          revealTranscript(
            startTranscript: firstTranscript,
            sessionId: second.session!,
            receiverCommitment: second.cr!,
            initiatorNonce: second.ni,
          ),
        );
        expectRejected(await second.reveal(signature: signature));
        expect(fixture.view, isNull);
      },
    );
  });

  group('commitment that does not match (RF-79, RF-105, SEC-13, C40)', () {
    test('403 identical to the other rejections, no view, the event with only '
        'the fingerprint and the session is gone (V5)', () async {
      final fixture = await receiver();
      final initiator = fixture.initiator(a);
      expect((await initiator.start(name: 'PC-DAVID'))!.status, 200);

      final reply = await initiator.reveal(nonce: randomBytes(nonceLength));

      expectRejected(reply);
      expect(fixture.view, isNull);
      expect(fixture.coordinator.busy, isFalse);
      await eventually(() => fixture.events.isNotEmpty);
      final event = fixture.events.single as PairingAttemptRejected;
      expect(event.fingerprint, a.fingerprint);
      expect(event.cause, AttemptCause.commitmentMismatch);
      expect(() => (event as dynamic).name, throwsNoSuchMethodError);
      expect(fixture.views.where((v) => v != null), isEmpty);
      expectNotFound(await initiator.wait());
      expectNotFound(await initiator.reveal());
      expect((await fixture.initiator(a).start())!.status, 200);
    });

    test('3 in a row in the same instant block the origin and start the '
        'global pause for 10 minutes: the paused reply covers the block, '
        'and the pause is announced once, after the third note', () async {
      final fixture = await receiver();
      final first = fixture.now;
      for (var i = 0; i < 3; i++) {
        final initiator = fixture.initiator(a);
        expect((await initiator.start())!.status, 200);
        expectRejected(await initiator.reveal(nonce: randomBytes(nonceLength)));
      }
      await eventually(() => fixture.events.length == 4);
      expect(
        fixture.events.take(3),
        everyElement(
          isA<PairingAttemptRejected>().having(
            (e) => e.cause,
            'cause',
            AttemptCause.commitmentMismatch,
          ),
        ),
      );
      expect(
        fixture.events.last,
        isA<PairingPaused>().having(
          (e) => e.until,
          'until',
          first.add(Limits.pairingGlobalWindow),
        ),
      );

      expectPaused(await fixture.initiator(b).start());
      fixture.advance(const Duration(minutes: 9, seconds: 59));
      expectPaused(await fixture.initiator(b).start());
      fixture.advance(const Duration(seconds: 1));
      expect((await fixture.initiator(b).start())!.status, 200);
    });

    test('the block is per origin and outlasts the global cap: three spread '
        'over 12 minutes block that origin until 10 minutes after the third, '
        'while another origin passes (RF-104, RF-105, RF-106b)', () async {
      final fixture = await receiver();
      final first = fixture.now;
      for (final minute in [0, 6, 12]) {
        fixture.now = first.add(Duration(minutes: minute));
        final initiator = fixture.initiator(a, from: thirdLoopback);
        expect((await initiator.start())!.status, 200, reason: 'min $minute');
        expectRejected(await initiator.reveal(nonce: randomBytes(nonceLength)));
      }
      await eventually(() => fixture.events.length == 3);
      expect(fixture.events.whereType<PairingAttemptRejected>(), hasLength(3));

      expectRejected(await fixture.initiator(a, from: thirdLoopback).start());
      final other = fixture.initiator(b);
      expect((await other.start())!.status, 200);
      expectState(await other.cancel(CancelReason.cancelled), 'cancelled');

      fixture.now = first.add(const Duration(minutes: 21, seconds: 59));
      expectRejected(await fixture.initiator(a, from: thirdLoopback).start());
      fixture.now = first.add(const Duration(minutes: 22));
      expect(
        (await fixture.initiator(a, from: thirdLoopback).start())!.status,
        200,
      );
    });

    test('three from three origins in the same window also pause a fresh '
        'origin, until the oldest leaves the window (RF-106b)', () async {
      final fixture = await receiver();
      for (final origin in [thirdLoopback, otherLoopback, loopback]) {
        final initiator = fixture.initiator(a, from: origin);
        expect((await initiator.start())!.status, 200);
        expectRejected(await initiator.reveal(nonce: randomBytes(nonceLength)));
      }

      final fresh = InternetAddress('127.0.0.9');
      expectPaused(await fixture.initiator(b, from: fresh).start());
      fixture.advance(const Duration(minutes: 9, seconds: 59));
      expectPaused(await fixture.initiator(b, from: fresh).start());
      fixture.advance(const Duration(seconds: 1));
      expect((await fixture.initiator(b, from: fresh).start())!.status, 200);
    });
  });

  group('the notice (RF-78, RF-83, RF-84, RF-85, C44)', () {
    test('the view is comparing before the nonce leaves the receiver, with the '
        'sanitized name, the fingerprint and the same code', () async {
      final fixture = await receiver();
      PairingView? viewAtReply;
      fixture.wrappers[ApiPaths.pairReveal] = (call, inner) async {
        final reply = await inner(call);
        viewAtReply = fixture.view;
        return reply;
      };
      const raw = 'Port\u00E1til \u202Eodivad\u200B';
      final initiator = fixture.initiator(a);

      await initiator.begin(name: raw);

      expect(viewAtReply, isNotNull);
      expect(viewAtReply!.phase, PairingPhase.comparing);
      final view = fixture.view!;
      expect(view, viewAtReply);
      expect(view.role, PairingRole.receiver);
      expect(view.phase, PairingPhase.comparing);
      expect(view.peerName, sanitizeDisplayName(raw));
      expect(view.peerName, isNot(contains('\u202E')));
      expect(view.peerName, isNot(contains('\u200B')));
      expect(view.peerFingerprint, a.fingerprint);
      expect(
        view.peerFingerprint.substring(0, 8),
        a.fingerprint.substring(0, 8),
      );
      expect(view.code, initiator.code);
      expect(view.code, matches(RegExp(r'^\d{6}$')));
      expect(view.alreadyPaired, isFalse);
      expect(view.outcome, isNull);
      await eventually(() => fixture.views.isNotEmpty);
      expect(fixture.views.last, view);
    });

    test('a presentation without a name shows no name', () async {
      final fixture = await receiver();

      await fixture.initiator(a).begin(name: null);

      expect(fixture.view!.peerName, isNull);
    });

    test('a name made only of invisible characters shows no name', () async {
      final fixture = await receiver();

      await fixture.initiator(a).begin(name: '\u202E\u200B ');

      expect(fixture.view!.peerName, isNull);
    });

    test('an initiator already paired is flagged and keeps its relation and '
        'date when it completes (RF-85)', () async {
      final fixture = await receiver(pairedWith: [a]);
      final before = fixture.paired.deviceOf(a.fingerprint)!;
      final initiator = fixture.initiator(a);

      await initiator.begin(name: 'Renamed');

      expect(fixture.view!.alreadyPaired, isTrue);
      fixture.coordinator.answerAsReceiver(ReceiverAnswer.matches);
      expectState(await initiator.confirm(), 'paired');
      final after = fixture.paired.deviceOf(a.fingerprint)!;
      expect(after.relation, PeerRelation.mine);
      expect(after.pairedAt, before.pairedAt);
      expect(after.name, before.name);
      expect(fixture.paired.devices, hasLength(1));
      await eventually(() => fixture.events.isNotEmpty);
      final event = fixture.events.single as PairingCompleted;
      expect(event.fingerprint, a.fingerprint);
      expect(event.isNew, isFalse);
      expect(fixture.view!.phase, PairingPhase.finished);
      expect(fixture.view!.outcome, PairingOutcome.paired);
      expect(fixture.coordinator.busy, isFalse);
      fixture.coordinator.dismissOutcome();
      expect(fixture.view, isNull);
    });

    test('"ignore" has no effect on an initiator already paired (RF-84, '
        'C96)', () async {
      final fixture = await receiver(pairedWith: [a]);
      final initiator = fixture.initiator(a);
      await initiator.begin();
      final shown = fixture.view;

      fixture.coordinator.answerAsReceiver(ReceiverAnswer.ignore);
      await settle();

      expect(fixture.view, shown);
      expect(fixture.coordinator.busy, isTrue);
      expect(fixture.ignored.isIgnored(a.fingerprint), isFalse);
      expect(fixture.ignored.devices, isEmpty);
      expect(fixture.ignoredFile.existsSync(), isFalse);
      expectState(await initiator.wait(), 'pending');
      fixture.coordinator.answerAsReceiver(ReceiverAnswer.matches);
      expectState(await initiator.confirm(), 'paired');
    });

    test('a finished view still open is replaced by the new notice only when '
        'a reveal is valid (C99)', () async {
      final fixture = await receiver();
      await finishWithPeerCancel(fixture, a);
      expect(fixture.view!.outcome, PairingOutcome.cancelledByPeer);
      final finished = fixture.view;
      final next = fixture.initiator(b);

      expect((await next.start())!.status, 200);
      expect(fixture.view, finished);
      expectRejected(
        await next.reveal(signature: randomBytes(signatureLength)),
      );
      expect(fixture.view, finished);

      final again = fixture.initiator(b);
      await again.begin(name: 'B');
      expect(fixture.view!.phase, PairingPhase.comparing);
      expect(fixture.view!.peerFingerprint, b.fingerprint);
      expect(fixture.view!.code, again.code);
    });
  });

  group('busy (RF-76, C43)', () {
    test('only a presentation that passes everything else gets 409, and it '
        'counts for the window', () async {
      final fixture = await receiver();
      await fixture.initiator(a).begin();
      await fixture.ignored.ignore(c.fingerprint, name: 'C');

      final busy = await fixture.initiator(b, from: otherLoopback).start();
      expect(busy!.status, 409);
      expect(busy.body, busyBody);

      expectRejected(await fixture.initiator(c, from: otherLoopback).start());
      for (var i = 0; i < 3; i++) {
        expect(
          (await fixture.initiator(b, from: otherLoopback).start())!.status,
          409,
        );
      }
      expectRejected(await fixture.initiator(b, from: otherLoopback).start());
      expect(fixture.view!.peerFingerprint, a.fingerprint);
      expect(fixture.view!.phase, PairingPhase.comparing);
    });

    test(
      'a failing presentation never learns that the receiver is busy',
      () async {
        final fixture = await receiver(pairedWith: [d]);
        await fixture.initiator(a).begin();
        final twin = HandMadeCertificate(d.certificate.commonName);

        expectRejected(
          await fixture.initiator(b, from: thirdLoopback).start(sign: c.sign),
        );
        expectRejected(await fixture.initiator(r, from: thirdLoopback).start());
        expectRejected(
          await fixture
              .initiator(b, from: thirdLoopback)
              .start(edit: (body) => {...body, 'x': 1}),
        );
        expectRejected(
          await fixture
              .initiator(b, from: thirdLoopback)
              .start(
                certificatePem: twin.pem,
                signerFingerprint: twin.fingerprint,
                sign: twin.sign,
              ),
        );
        expectRejected(
          await fixture
              .initiator(b, from: thirdLoopback)
              .start(receiverFingerprint: otherReceiver.fingerprint),
        );
      },
    );

    test(
      'a session waiting for its reveal also makes the receiver busy',
      () async {
        final fixture = await receiver();
        expect((await fixture.initiator(a).start())!.status, 200);

        final reply = await fixture.initiator(b, from: otherLoopback).start();

        expect(reply!.status, 409);
        expect(reply.body, busyBody);
      },
    );
  });

  group('limit per origin (RF-103, RF-107, C37)', () {
    test('5 presentations in 10 minutes, then rejected until one leaves the '
        'window; other origins are not affected', () async {
      final fixture = await receiver();
      for (var i = 0; i < 5; i++) {
        final initiator = fixture.initiator(a);
        expect((await initiator.start())!.status, 200);
        expectState(
          await initiator.cancel(CancelReason.cancelled),
          'cancelled',
        );
        fixture.advance(const Duration(minutes: 1));
      }

      expectRejected(await fixture.initiator(a).start());
      final other = fixture.initiator(a, from: otherLoopback);
      expect((await other.start())!.status, 200);
      expectState(await other.cancel(CancelReason.cancelled), 'cancelled');
      fixture.advance(const Duration(minutes: 6, milliseconds: 1));
      expect((await fixture.initiator(a).start())!.status, 200);
    });

    test(
      'a new coordinator starts with no limit and no block (RF-107)',
      () async {
        final dir = await temporaryDirectory();
        final first = await receiver(dataDir: dir);
        for (var i = 0; i < 3; i++) {
          await finishWithMismatch(first, a);
        }
        expectPaused(await first.initiator(a).start());
        await first.close();

        final second = await receiver(dataDir: dir);
        RawReply? reply;
        for (var attempt = 0; attempt < 3 && reply == null; attempt++) {
          reply = await second.initiator(a).start();
        }

        expect(reply?.status, 200);
      },
    );
  });

  group('malformed messages do not count as requests (C103, SEC-07)', () {
    test('broken JSON gets 400 and 9000 bytes get 413 before the pairing '
        'logic, and neither counts for the limit', () async {
      final fixture = await receiver();
      for (var i = 0; i < 6; i++) {
        final broken = await sendOrCut(
          fixture.port,
          httpRequest(
            'POST',
            ApiPaths.pairStart,
            body: utf8.encode('{"protocol":'),
            headers: {'content-type': jsonContentType},
          ),
          serverFingerprint: r.fingerprint,
        );
        expect(broken!.status, 400);
        expect(broken.json, {'error': 'bad_request'});
        final large = await sendOrCut(
          fixture.port,
          httpRequest(
            'POST',
            ApiPaths.pairStart,
            body: jsonBody({'pad': 'x' * 8990}),
            headers: {'content-type': jsonContentType},
          ),
          serverFingerprint: r.fingerprint,
        );
        expect(large!.status, 413);
        expect(large.json, {'error': 'payload_too_large'});
      }

      expect(fixture.handledOn(ApiPaths.pairStart), 0);
      expect(fixture.view, isNull);
      expect(fixture.coordinator.busy, isFalse);
      expect((await fixture.initiator(a).start())!.status, 200);
    });
  });

  group('session misuse (C93, principle 1)', () {
    test('reveal, wait, confirm and cancel from another origin or through '
        'another interface get 404 and change nothing', () async {
      final fixture = await receiver(twoInterfaces: true);
      final initiator = fixture.initiator(a);
      expect((await initiator.start())!.status, 200);
      final probes = <(String, InternetAddress, InternetAddress)>[
        ('other origin', thirdLoopback, loopback),
        ('other interface', loopback, otherLoopback),
      ];

      for (final (label, from, to) in probes) {
        expectNotFound(
          await initiator.reveal(from: from, to: to),
          reason: label,
        );
        expectNotFound(
          await initiator.wait(from: from, to: to),
          reason: label,
        );
        expectNotFound(
          await initiator.confirm(from: from, to: to),
          reason: label,
        );
        expectNotFound(
          await initiator.cancel(CancelReason.cancelled, from: from, to: to),
          reason: label,
        );
      }
      expect(fixture.coordinator.busy, isTrue);
      expect(fixture.view, isNull);

      expect((await initiator.reveal())!.status, 200);
      final shown = fixture.view;
      expect(shown!.phase, PairingPhase.comparing);

      for (final (label, from, to) in probes) {
        expectNotFound(
          await initiator.wait(from: from, to: to),
          reason: label,
        );
        expectNotFound(
          await initiator.confirm(from: from, to: to),
          reason: label,
        );
        expectNotFound(
          await initiator.cancel(CancelReason.cancelled, from: from, to: to),
          reason: label,
        );
        expectNotFound(
          await initiator.cancel(CancelReason.expired, from: from, to: to),
          reason: label,
        );
      }
      expect(fixture.view, shown);
      expect(fixture.coordinator.busy, isTrue);

      fixture.coordinator.answerAsReceiver(ReceiverAnswer.matches);
      expect(fixture.view!.phase, PairingPhase.waitingPeer);
      expect(fixture.paired.isPaired(a.fingerprint), isFalse);
      expectState(await initiator.wait(), 'pending');
      expectState(await initiator.confirm(), 'paired');
      expect(fixture.paired.isPaired(a.fingerprint), isTrue);
    });

    test('a second reveal gets 404 and the notice keeps its code', () async {
      final fixture = await receiver();
      final initiator = fixture.initiator(a);
      await initiator.begin();
      final shown = fixture.view;

      expectNotFound(await initiator.reveal());
      expectNotFound(await initiator.reveal(nonce: randomBytes(nonceLength)));

      expect(fixture.view, shown);
      expect(fixture.events, isEmpty);
    });

    test('wait and confirm before the reveal get 404', () async {
      final fixture = await receiver();
      final initiator = fixture.initiator(a);
      expect((await initiator.start())!.status, 200);

      expectNotFound(await initiator.wait());
      expectNotFound(await initiator.confirm());

      expect((await initiator.reveal())!.status, 200);
      fixture.coordinator.answerAsReceiver(ReceiverAnswer.matches);
      expect(fixture.view!.phase, PairingPhase.waitingPeer);
      expect(fixture.paired.isPaired(a.fingerprint), isFalse);
    });

    test('an unknown session or a malformed body gets 404', () async {
      final fixture = await receiver();
      final initiator = fixture.initiator(a);
      await initiator.begin();
      final unknown = toHex(randomBytes(sessionIdLength));
      final session = toHex(initiator.session!);

      for (final (path, body) in <(String, Object?)>[
        (ApiPaths.pairWait, {'session': unknown}),
        (ApiPaths.pairConfirm, {'session': unknown}),
        (ApiPaths.pairCancel, {'session': unknown, 'reason': 'cancelled'}),
        (
          ApiPaths.pairReveal,
          {
            'session': unknown,
            'nonce': toHex(initiator.ni),
            'signature': toHex(randomBytes(signatureLength)),
          },
        ),
        (ApiPaths.pairWait, {'session': session.toUpperCase()}),
        (ApiPaths.pairWait, {'session': session, 'x': 1}),
        (ApiPaths.pairConfirm, {'session': session.substring(2)}),
        (ApiPaths.pairCancel, {'session': session}),
        (ApiPaths.pairCancel, {'session': session, 'reason': 'later'}),
        (ApiPaths.pairWait, null),
        (ApiPaths.pairConfirm, [session]),
      ]) {
        expectNotFound(await initiator.post(path, body), reason: '$path $body');
      }
      expect(fixture.view!.phase, PairingPhase.comparing);
      expect(fixture.coordinator.busy, isTrue);
    });
  });

  group('confirmations (RF-87, RF-88, RF-97)', () {
    test('the receiver confirms first: nothing is saved until pair/confirm, '
        'then it is saved as foreign', () async {
      final fixture = await receiver();
      final initiator = fixture.initiator(a);
      await initiator.begin(name: 'Laptop \u202Ex');

      fixture.coordinator.answerAsReceiver(ReceiverAnswer.matches);
      expect(fixture.view!.phase, PairingPhase.waitingPeer);
      expect(fixture.view!.code, initiator.code);
      expectState(await initiator.wait(), 'pending');
      expect(fixture.paired.isPaired(a.fingerprint), isFalse);

      expectState(await initiator.confirm(), 'paired');

      final saved = fixture.paired.deviceOf(a.fingerprint)!;
      expect(saved.relation, PeerRelation.foreign);
      expect(saved.name, sanitizeDisplayName('Laptop \u202Ex'));
      expect(saved.certificatePem, a.certificate.pem);
      expect(saved.pairedAt, fixture.now);
      expect(fixture.pairedFile.readAsStringSync(), contains(a.fingerprint));
      expect(fixture.view, isNull);
      expect(fixture.coordinator.busy, isFalse);
      await eventually(() => fixture.events.isNotEmpty);
      final event = fixture.events.single as PairingCompleted;
      expect(event.fingerprint, a.fingerprint);
      expect(event.name, saved.name);
      expect(event.isNew, isTrue);
      expectState(await initiator.wait(), 'paired');
    });

    test('the initiator confirms first: pending and nothing saved until the '
        'receiver user confirms', () async {
      final fixture = await receiver();
      final initiator = fixture.initiator(a);
      await initiator.begin();

      expectState(await initiator.confirm(), 'pending');
      expect(fixture.view!.phase, PairingPhase.comparing);
      expect(fixture.paired.isPaired(a.fingerprint), isFalse);
      expect(fixture.pairedFile.existsSync(), isFalse);

      fixture.coordinator.answerAsReceiver(ReceiverAnswer.matches);
      await eventually(() => fixture.paired.isPaired(a.fingerprint));

      expectState(await initiator.wait(), 'paired');
      expect(fixture.view, isNull);
      expect(fixture.coordinator.busy, isFalse);
      await eventually(() => fixture.events.isNotEmpty);
      expect((fixture.events.single as PairingCompleted).isNew, isTrue);
    });

    test('pair/confirm is idempotent and the record answers repeated '
        'messages', () async {
      final fixture = await receiver();
      final initiator = fixture.initiator(a);
      await initiator.begin();

      expectState(await initiator.confirm(), 'pending');
      expectState(await initiator.confirm(), 'pending');
      fixture.coordinator.answerAsReceiver(ReceiverAnswer.matches);
      await eventually(() => fixture.paired.isPaired(a.fingerprint));

      expectState(await initiator.confirm(), 'paired');
      expectState(await initiator.confirm(), 'paired');
      expectState(await initiator.cancel(CancelReason.cancelled), 'paired');
      expectState(await initiator.wait(), 'paired');
      expect(fixture.paired.devices, hasLength(1));
      await settle();
      expect(fixture.events.whereType<PairingCompleted>(), hasLength(1));
    });

    test('a confirmation that arrives while saving waits for the result and '
        'both get the same final state', () async {
      final fixture = await receiver();
      final initiator = fixture.initiator(a);
      await initiator.begin();
      lockFile(fixture.pairedFile);
      fixture.coordinator.answerAsReceiver(ReceiverAnswer.matches);

      final first = initiator.confirm();
      await eventually(() => fixture.handledOn(ApiPaths.pairConfirm) == 1);
      final second = initiator.confirm();
      final replies = await Future.wait([first, second]);

      expectState(replies[0], 'cancelled');
      expectState(replies[1], 'cancelled');
      expect(fixture.view!.outcome, PairingOutcome.notSaved);
    });

    test('a second "matches" or a "mismatch" after "matches" change nothing '
        '(D3)', () async {
      final fixture = await receiver();
      final initiator = fixture.initiator(a);
      await initiator.begin();
      fixture.coordinator.answerAsReceiver(ReceiverAnswer.matches);
      final waiting = fixture.view;

      fixture.coordinator.answerAsReceiver(ReceiverAnswer.matches);
      fixture.coordinator.answerAsReceiver(ReceiverAnswer.mismatch);
      fixture.coordinator.answerAsReceiver(ReceiverAnswer.ignore);

      expect(fixture.view, waiting);
      expect(fixture.ignored.isIgnored(a.fingerprint), isFalse);
      expectState(await initiator.confirm(), 'paired');
    });

    test('answers without a notice on screen change nothing', () async {
      final fixture = await receiver();
      for (final answer in ReceiverAnswer.values) {
        fixture.coordinator.answerAsReceiver(answer);
      }
      final initiator = fixture.initiator(a);
      expect((await initiator.start())!.status, 200);
      for (final answer in ReceiverAnswer.values) {
        fixture.coordinator.answerAsReceiver(answer);
      }
      await settle();
      expect(fixture.coordinator.busy, isTrue);
      expect(fixture.view, isNull);
      expect(fixture.ignored.isIgnored(a.fingerprint), isFalse);

      expect((await initiator.reveal())!.status, 200);
      expect(fixture.view!.phase, PairingPhase.comparing);
      expectState(await initiator.confirm(), 'pending');
      expect(fixture.paired.isPaired(a.fingerprint), isFalse);
    });
  });

  group('mismatch, ignore and cancel (RF-89, RF-104, RF-106, RF-108)', () {
    test('"mismatch" cancels without saving, closes the notice with no '
        'message and the initiator sees cancelled', () async {
      final fixture = await receiver();
      final initiator = fixture.initiator(a);
      await initiator.begin();

      fixture.coordinator.answerAsReceiver(ReceiverAnswer.mismatch);

      expect(fixture.view, isNull);
      expect(fixture.coordinator.busy, isFalse);
      expectState(await initiator.wait(), 'cancelled');
      expectState(await initiator.confirm(), 'cancelled');
      expect(fixture.paired.devices, isEmpty);
      expect(fixture.events, isEmpty);
    });

    test('3 "mismatch" in a row block the origin for 10 minutes after the '
        'third, with the generic 403 once the global pause is over', () async {
      final fixture = await receiver();
      final first = fixture.now;
      for (final minute in [0, 5, 10]) {
        fixture.now = first.add(Duration(minutes: minute));
        await finishWithMismatch(fixture, a);
      }

      expectRejected(await fixture.initiator(a).start());
      fixture.now = first.add(const Duration(minutes: 19, seconds: 59));
      expectRejected(await fixture.initiator(a).start());
      fixture.now = first.add(const Duration(minutes: 20));
      expect((await fixture.initiator(a).start())!.status, 200);
    });

    test('3 "mismatch" in the same instant also start the global pause: the '
        'next pair/start gets the paused reply and the receiver announces the '
        'pause once (C110)', () async {
      final fixture = await receiver();
      for (var i = 0; i < 3; i++) {
        await finishWithMismatch(fixture, a);
      }

      expectPaused(await fixture.initiator(a).start());
      await eventually(() => fixture.events.isNotEmpty);
      await settle();
      expect(
        fixture.events.single,
        isA<PairingPaused>().having(
          (e) => e.until,
          'until',
          fixture.now.add(Limits.pairingGlobalWindow),
        ),
      );
      fixture.advance(const Duration(minutes: 10));
      expect((await fixture.initiator(a).start())!.status, 200);
    });

    test('a cancel from the initiator after the reveal counts as a mismatch: '
        'two mismatches and that cancel block the origin (RF-106)', () async {
      final fixture = await receiver();
      final first = fixture.now;
      await finishWithMismatch(fixture, a);
      fixture.now = first.add(const Duration(minutes: 5));
      await finishWithMismatch(fixture, a);
      fixture.now = first.add(const Duration(minutes: 10));
      await finishWithPeerCancel(fixture, a);

      expectRejected(await fixture.initiator(a).start());
      await eventually(() => fixture.events.isNotEmpty);
      await settle();
      expect(
        fixture.events.single,
        isA<PairingAttemptRejected>()
            .having((e) => e.fingerprint, 'fingerprint', a.fingerprint)
            .having((e) => e.cause, 'cause', AttemptCause.cancelledAfterReveal),
      );
    });

    test('C122: cancels before the reveal and genuine expiries (50 s or more '
        'after the presentation) neither count nor reset the streak '
        '(RF-106)', () async {
      final fixture = await receiver(ticking: false);
      final first = fixture.now;
      await finishWithMismatch(fixture, a);
      await finishWithMismatch(fixture, a);
      final early = fixture.initiator(a);
      expect((await early.start())!.status, 200);
      expectState(await early.cancel(CancelReason.cancelled), 'cancelled');
      final expired = fixture.initiator(a);
      await expired.begin();
      fixture.advance(Limits.pairingPeerExpiryAfter);
      expectState(await expired.cancel(CancelReason.expired), 'expired');

      fixture.now = first.add(const Duration(minutes: 6));
      await finishWithMismatch(fixture, a);

      fixture.now = first.add(const Duration(minutes: 11));
      expectRejected(await fixture.initiator(a).start());
      final other = fixture.initiator(b, from: otherLoopback);
      expect((await other.start())!.status, 200);
      expectState(await other.cancel(CancelReason.cancelled), 'cancelled');
      fixture.now = first.add(const Duration(minutes: 16));
      expect((await fixture.initiator(a).start())!.status, 200);
      await settle();
      expect(fixture.events, hasLength(1));
      expect(
        fixture.events.single,
        isA<PairingPaused>().having(
          (e) => e.until,
          'until',
          first.add(Limits.pairingGlobalWindow),
        ),
      );
    });

    test('a completed pairing resets the streak (RF-106)', () async {
      final fixture = await receiver();
      await finishWithMismatch(fixture, b);
      await finishWithMismatch(fixture, b);
      await completePairing(fixture, a);
      fixture.advance(const Duration(minutes: 10));
      await finishWithMismatch(fixture, b);
      await finishWithMismatch(fixture, b);

      expect((await fixture.initiator(b).start())!.status, 200);
    });

    test('"ignore" cancels, closes the notice, persists the fingerprint and '
        'later presentations are rejected like any other', () async {
      final fixture = await receiver();
      final initiator = fixture.initiator(a);
      await initiator.begin(name: 'Laptop');

      fixture.coordinator.answerAsReceiver(ReceiverAnswer.ignore);

      expect(fixture.view, isNull);
      expect(fixture.coordinator.busy, isFalse);
      expect(fixture.ignored.isIgnored(a.fingerprint), isTrue);
      expectState(await initiator.wait(), 'cancelled');
      await eventually(() => fixture.ignoredFile.existsSync());
      final reloaded = IgnoredDevicesStore(
        JsonFileStore(fixture.ignoredFile),
        isPaired: (_) => false,
      );
      await reloaded.load();
      expect(reloaded.isIgnored(a.fingerprint), isTrue);
      expect(reloaded.devices.single.name, 'Laptop');
      fixture.views.clear();

      expectRejected(await fixture.initiator(a, from: otherLoopback).start());
      await settle();
      expect(fixture.view, isNull);
      expect(fixture.views, isEmpty);
      expect(fixture.paired.devices, isEmpty);
      expect(fixture.events, isEmpty);
    });

    test('"ignore" that cannot be saved emits IgnoreNotSaved and still ignores '
        'for the session (RF-121)', () async {
      final fixture = await receiver();
      lockFile(fixture.ignoredFile);
      await fixture.initiator(a).begin(name: 'Laptop');

      fixture.coordinator.answerAsReceiver(ReceiverAnswer.ignore);

      await eventually(
        () => fixture.events.isNotEmpty,
        limit: const Duration(seconds: 10),
      );
      final event = fixture.events.single as IgnoreNotSaved;
      expect(event.fingerprint, a.fingerprint);
      expect(event.name, 'Laptop');
      expect(fixture.ignored.isIgnored(a.fingerprint), isTrue);
      expectRejected(await fixture.initiator(a, from: otherLoopback).start());
    });

    test('pair/cancel with reason cancelled ends in cancelledByPeer and the '
        'message stays until it is dismissed', () async {
      final fixture = await receiver();
      final initiator = fixture.initiator(a);
      await initiator.begin(name: 'Laptop');

      expectState(await initiator.cancel(CancelReason.cancelled), 'cancelled');

      expect(fixture.view!.phase, PairingPhase.finished);
      expect(fixture.view!.outcome, PairingOutcome.cancelledByPeer);
      expect(fixture.view!.peerName, 'Laptop');
      expect(fixture.view!.peerFingerprint, a.fingerprint);
      expect(fixture.coordinator.busy, isFalse);
      expect(fixture.paired.devices, isEmpty);
      expectState(await initiator.wait(), 'cancelled');
      final changes = fixture.views.length;
      fixture.coordinator.dismissOutcome();
      expect(fixture.view, isNull);
      await eventually(() => fixture.views.length == changes + 1);
      expect(fixture.views.last, isNull);
      fixture.coordinator.dismissOutcome();
      await settle();
      expect(fixture.views.length, changes + 1);
    });

    test('pair/cancel with reason expired, sent between 50 and 60 s after the '
        'presentation, ends in expired (RF-90)', () async {
      final fixture = await receiver();
      final initiator = fixture.initiator(a);
      await initiator.begin();
      for (var i = 0; i < 5; i++) {
        fixture.advance(const Duration(seconds: 9));
        expectState(await initiator.wait(), 'pending');
      }
      fixture.advance(const Duration(seconds: 7));
      expect(fixture.view!.phase, PairingPhase.comparing);

      expectState(await initiator.cancel(CancelReason.expired), 'expired');

      expect(fixture.view!.outcome, PairingOutcome.expired);
      expectState(await initiator.wait(), 'expired');
      await settle();
      expect(fixture.events, isEmpty);
    });

    group('C122: the 50 s threshold of a declared expiry (RF-106, RF-90, '
        'N1)', () {
      Future<void> twoMismatchesTenMinutesApart(ReceiverFixture fixture) async {
        fixture.advance(Limits.pairingGlobalWindow);
        await finishWithMismatch(fixture, a);
        fixture.advance(Limits.pairingGlobalWindow);
        await finishWithMismatch(fixture, a);
      }

      Future<RawInitiator> revealedAt(
        ReceiverFixture fixture,
        Duration age,
      ) async {
        final initiator = fixture.initiator(a);
        await initiator.begin(name: 'Laptop');
        fixture.advance(age);
        return initiator;
      }

      test('at 49.999 s it counts as a cancel after the reveal: event, '
          'cancelledByPeer on screen and the streak goes up', () async {
        final fixture = await receiver(ticking: false);
        final initiator = await revealedAt(
          fixture,
          Limits.pairingPeerExpiryAfter - const Duration(milliseconds: 1),
        );

        expectState(await initiator.cancel(CancelReason.expired), 'cancelled');

        expect(fixture.view!.phase, PairingPhase.finished);
        expect(fixture.view!.outcome, PairingOutcome.cancelledByPeer);
        await eventually(() => fixture.events.isNotEmpty);
        expect(
          fixture.events.single,
          isA<PairingAttemptRejected>()
              .having((e) => e.fingerprint, 'fingerprint', a.fingerprint)
              .having(
                (e) => e.cause,
                'cause',
                AttemptCause.cancelledAfterReveal,
              ),
        );
        await twoMismatchesTenMinutesApart(fixture);
        expectRejected(await fixture.initiator(a).start());
      });

      for (final age in [
        Limits.pairingPeerExpiryAfter,
        const Duration(seconds: 55),
      ]) {
        test('at ${age.inMilliseconds} ms it is a genuine expiry: expired, '
            'no event and no count', () async {
          final fixture = await receiver(ticking: false);
          final initiator = await revealedAt(fixture, age);

          expectState(await initiator.cancel(CancelReason.expired), 'expired');

          expect(fixture.view!.outcome, PairingOutcome.expired);
          await settle();
          expect(fixture.events, isEmpty);
          await twoMismatchesTenMinutesApart(fixture);
          expect((await fixture.initiator(a).start())!.status, 200);
        });
      }

      test('before the reveal, an expired cancel at 1 s ends in '
          'cancelledByPeer without a view, an event or a count', () async {
        final fixture = await receiver(ticking: false);
        final initiator = fixture.initiator(a);
        expect((await initiator.start())!.status, 200);
        fixture.advance(const Duration(seconds: 1));

        expectState(await initiator.cancel(CancelReason.expired), 'cancelled');

        expect(fixture.coordinator.busy, isFalse);
        expect(fixture.view, isNull);
        await settle();
        expect(fixture.events, isEmpty);
        await twoMismatchesTenMinutesApart(fixture);
        expect((await fixture.initiator(a).start())!.status, 200);
      });

      test(
        'a clock that goes back between start and cancel counts it',
        () async {
          final fixture = await receiver(ticking: false);
          final initiator = await revealedAt(
            fixture,
            const Duration(seconds: -5),
          );

          expectState(
            await initiator.cancel(CancelReason.expired),
            'cancelled',
          );

          await eventually(() => fixture.events.isNotEmpty);
          expect(
            (fixture.events.single as PairingAttemptRejected).cause,
            AttemptCause.cancelledAfterReveal,
          );
        },
      );
    });

    test('pair/cancel before the reveal frees the receiver and shows '
        'nothing', () async {
      final fixture = await receiver();
      final initiator = fixture.initiator(a);
      expect((await initiator.start())!.status, 200);

      expectState(await initiator.cancel(CancelReason.cancelled), 'cancelled');

      expect(fixture.coordinator.busy, isFalse);
      expect(fixture.view, isNull);
      expect(fixture.views.where((v) => v != null), isEmpty);
    });

    test('pair/cancel while saving does not cancel the save', () async {
      final fixture = await receiver();
      final initiator = fixture.initiator(a);
      await initiator.begin();
      lockFile(fixture.pairedFile);
      fixture.coordinator.answerAsReceiver(ReceiverAnswer.matches);
      final confirming = initiator.confirm();
      await eventually(() => fixture.handledOn(ApiPaths.pairConfirm) == 1);

      expectState(await initiator.cancel(CancelReason.cancelled), 'pending');
      expectState(await confirming, 'cancelled');

      expect(fixture.view!.outcome, PairingOutcome.notSaved);
    });
  });

  group('saving (RF-93, RF-94, C94)', () {
    test('a save that cannot write ends in notSaved, frees the receiver and '
        'gives no access', () async {
      final fixture = await receiver();
      final initiator = fixture.initiator(a);
      await initiator.begin();
      lockFile(fixture.pairedFile);

      fixture.coordinator.answerAsReceiver(ReceiverAnswer.matches);
      expectState(await initiator.confirm(), 'cancelled');

      expect(fixture.view!.outcome, PairingOutcome.notSaved);
      expect(fixture.coordinator.busy, isFalse);
      expect(fixture.paired.isPaired(a.fingerprint), isFalse);
      await eventually(() => fixture.events.isNotEmpty);
      expect(
        (fixture.events.single as PairingNotSaved).fingerprint,
        a.fingerprint,
      );
      expectState(await initiator.wait(), 'cancelled');
    });

    test('a save that does not finish in time ends in notSaved and the late '
        'write is corrected (C94)', () async {
      final fixture = await receiver(saveTimeout: Duration.zero);
      final initiator = fixture.initiator(a);
      await initiator.begin();
      expect(fixture.pairedFile.existsSync(), isFalse);

      expectState(await initiator.confirm(), 'pending');
      fixture.coordinator.answerAsReceiver(ReceiverAnswer.matches);

      await eventually(() => !fixture.coordinator.busy);
      expect(fixture.view!.outcome, PairingOutcome.notSaved);
      expectState(await initiator.wait(), 'cancelled');
      await eventually(
        () => fileLacks(fixture.pairedFile, a.fingerprint),
        reason: 'corrective write',
      );
      expect(fixture.paired.isPaired(a.fingerprint), isFalse);
      expect(
        (fixture.events.single as PairingNotSaved).fingerprint,
        a.fingerprint,
      );
    });

    test('a device with the same subject cannot be paired during the '
        'pairing: the store refuses it and the save goes on (RF-93)', () async {
      final fixture = await receiver();
      final initiator = fixture.initiator(a);
      await initiator.begin();
      final twin = HandMadeCertificate(a.certificate.commonName);

      await expectLater(
        fixture.paired.replaceAll([
          PairedDevice(
            fingerprint: twin.fingerprint,
            name: 'twin',
            certificatePem: twin.pem,
            relation: PeerRelation.mine,
            pairedAt: DateTime.utc(2026, 10, 21),
          ),
        ]),
        throwsArgumentError,
      );

      fixture.coordinator.answerAsReceiver(ReceiverAnswer.matches);
      expectState(await initiator.confirm(), 'paired');

      expect(fixture.paired.isPaired(a.fingerprint), isTrue);
      expect(fixture.paired.isPaired(twin.fingerprint), isFalse);
    });

    test(
      'an initiator ignored during the pairing makes the save fail',
      () async {
        final fixture = await receiver();
        final initiator = fixture.initiator(a);
        await initiator.begin();
        await fixture.ignored.ignore(a.fingerprint, name: 'x');

        fixture.coordinator.answerAsReceiver(ReceiverAnswer.matches);
        expectState(await initiator.confirm(), 'cancelled');

        expect(fixture.view!.outcome, PairingOutcome.failed);
        expect(fixture.paired.isPaired(a.fingerprint), isFalse);
        await eventually(() => fixture.events.isNotEmpty);
        expect(
          (fixture.events.single as PairingFailed).fingerprint,
          a.fingerprint,
        );
      },
    );

    test('unpairing the device during its re-pairing ends in failed, keeps '
        'nothing and does not turn it into a new pairing (Q-8)', () async {
      final fixture = await receiver(pairedWith: [a]);
      expect(
        fixture.paired.deviceOf(a.fingerprint)!.relation,
        PeerRelation.mine,
      );
      final initiator = fixture.initiator(a);
      await initiator.begin();
      expect(fixture.view!.alreadyPaired, isTrue);
      expect(await fixture.paired.remove(a.fingerprint), isTrue);
      expect(fixture.paired.isPaired(a.fingerprint), isFalse);

      fixture.coordinator.answerAsReceiver(ReceiverAnswer.matches);
      expectState(await initiator.confirm(), 'cancelled');

      expect(fixture.view!.phase, PairingPhase.finished);
      expect(fixture.view!.outcome, PairingOutcome.failed);
      expect(fixture.coordinator.busy, isFalse);
      expect(fixture.paired.isPaired(a.fingerprint), isFalse);
      expect(fixture.paired.devices, isEmpty);
      await eventually(() => fixture.events.isNotEmpty);
      expect(fixture.events.whereType<PairingCompleted>(), isEmpty);
      expect(
        (fixture.events.single as PairingFailed).fingerprint,
        a.fingerprint,
      );
      expectState(await initiator.wait(), 'cancelled');
    });

    test('control: a re-pairing that stays paired ends in paired with '
        'isNew false and keeps the relation (Q-8)', () async {
      final fixture = await receiver(pairedWith: [a]);
      final initiator = fixture.initiator(a);
      await initiator.begin();

      fixture.coordinator.answerAsReceiver(ReceiverAnswer.matches);
      expectState(await initiator.confirm(), 'paired');

      expect(
        fixture.paired.deviceOf(a.fingerprint)!.relation,
        PeerRelation.mine,
      );
      await eventually(() => fixture.events.isNotEmpty);
      expect((fixture.events.single as PairingCompleted).isNew, isFalse);
    });

    test('a not saved result survives a new notice: the view is replaced but '
        'the event stays (Q-9)', () async {
      final fixture = await receiver();
      final first = fixture.initiator(a);
      await first.begin();
      final lock = lockFile(fixture.pairedFile);
      fixture.coordinator.answerAsReceiver(ReceiverAnswer.matches);
      expectState(await first.confirm(), 'cancelled');
      expect(fixture.view!.outcome, PairingOutcome.notSaved);
      lock.release();

      await fixture.initiator(b, from: otherLoopback).begin();

      expect(fixture.view!.phase, PairingPhase.comparing);
      expect(fixture.view!.peerFingerprint, b.fingerprint);
      expect(fixture.events, hasLength(1));
      expect(
        (fixture.events.single as PairingNotSaved).fingerprint,
        a.fingerprint,
      );
    });

    test('a list that fills during the pairing makes the save fail', () async {
      final crowd = [for (var i = 0; i < 32; i++) DeviceIdentity.generate()];
      final fixture = await receiver(pairedWith: crowd.take(31));
      final initiator = fixture.initiator(a);
      await initiator.begin();
      await fixture.pairWith([crowd.last]);

      fixture.coordinator.answerAsReceiver(ReceiverAnswer.matches);
      expectState(await initiator.confirm(), 'cancelled');

      expect(fixture.view!.outcome, PairingOutcome.failed);
      expect(fixture.paired.devices, hasLength(32));
      expect(fixture.paired.isPaired(a.fingerprint), isFalse);
      await eventually(() => fixture.events.isNotEmpty);
      expect(
        (fixture.events.single as PairingFailed).fingerprint,
        a.fingerprint,
      );
    });

    test('saving is not cancelled by the network (C102)', () async {
      final fixture = await receiver();
      final initiator = fixture.initiator(a);
      await initiator.begin();
      expectState(await initiator.confirm(), 'pending');

      fixture.coordinator.answerAsReceiver(ReceiverAnswer.matches);
      fixture.coordinator.interfacesChanged(const {});

      await eventually(() => fixture.paired.isPaired(a.fingerprint));
      expectState(await initiator.wait(), 'paired');
      await eventually(() => fixture.events.isNotEmpty);
      expect((fixture.events.single as PairingCompleted).isNew, isTrue);
      expect(fixture.view, isNull);
    });
  });

  group('same subject as a paired device (RF-93, C50)', () {
    test('the same common name in UTF8String or in capitals with another key '
        'is rejected and the paired device stays intact', () async {
      final paired = DeviceIdentity.generate();
      final sharedName = paired.certificate.commonName;
      final fixture = await receiver(pairedWith: [paired]);
      final utf8Twin = HandMadeCertificate(sharedName, utf8CommonName: true);
      final upper = HandMadeCertificate(sharedName.toUpperCase());
      expect(utf8Twin.fingerprint, isNot(paired.fingerprint));

      expectRejected(
        await fixture
            .initiator(a)
            .start(
              certificatePem: utf8Twin.pem,
              signerFingerprint: utf8Twin.fingerprint,
              sign: utf8Twin.sign,
            ),
      );
      expectRejected(
        await fixture
            .initiator(a)
            .start(
              certificatePem: upper.pem,
              signerFingerprint: upper.fingerprint,
              sign: upper.sign,
            ),
      );

      expect(fixture.view, isNull);
      expect(fixture.paired.devices.single.fingerprint, paired.fingerprint);
      expect(fixture.paired.devices.single.relation, PeerRelation.mine);
      expect((await fixture.initiator(paired).start())!.status, 200);
    });
  });

  group('timeouts with the injected clock (RF-90, RF-91, C48)', () {
    test('expires 60 s after the presentation and not before', () async {
      final fixture = await receiver();
      final initiator = fixture.initiator(a);
      await initiator.begin();
      for (var i = 0; i < 6; i++) {
        fixture.advance(const Duration(seconds: 9));
        expectState(await initiator.wait(), 'pending');
      }
      fixture.advance(const Duration(seconds: 5, milliseconds: 900));
      await settle();
      expect(fixture.view!.phase, PairingPhase.comparing);

      fixture.advance(const Duration(milliseconds: 100));

      await eventually(() => fixture.view?.phase == PairingPhase.finished);
      expect(fixture.view!.outcome, PairingOutcome.expired);
      expect(fixture.coordinator.busy, isFalse);
      expectState(await initiator.wait(), 'expired');
      expectState(await initiator.confirm(), 'expired');
      expect(fixture.paired.devices, isEmpty);
    });

    test('also expires after the receiver confirmed', () async {
      final fixture = await receiver();
      final initiator = fixture.initiator(a);
      await initiator.begin();
      fixture.coordinator.answerAsReceiver(ReceiverAnswer.matches);

      fixture.advance(Limits.pairingTimeout);

      await eventually(() => fixture.view?.phase == PairingPhase.finished);
      expect(fixture.view!.outcome, PairingOutcome.expired);
      expectState(await initiator.confirm(), 'expired');
      expect(fixture.paired.devices, isEmpty);
    });

    test('lost after more than 10 s without contact', () async {
      final fixture = await receiver();
      final initiator = fixture.initiator(a);
      await initiator.begin();

      fixture.advance(Limits.pairingMessageTimeout);
      await settle();
      expect(fixture.view!.phase, PairingPhase.comparing);
      fixture.advance(const Duration(milliseconds: 1));

      await eventually(() => fixture.view?.phase == PairingPhase.finished);
      expect(fixture.view!.outcome, PairingOutcome.lost);
      expect(fixture.coordinator.busy, isFalse);
      expectState(await initiator.wait(), 'cancelled');
      await eventually(() => fixture.events.isNotEmpty);
      expect(
        fixture.events.single,
        isA<PairingAttemptRejected>()
            .having((e) => e.fingerprint, 'fingerprint', a.fingerprint)
            .having((e) => e.cause, 'cause', AttemptCause.lostAfterReveal),
      );
    });

    test('a session lost before its reveal disappears silently', () async {
      final fixture = await receiver();
      final initiator = fixture.initiator(a);
      expect((await initiator.start())!.status, 200);

      fixture.advance(const Duration(seconds: 10, milliseconds: 1));

      await eventually(() => !fixture.coordinator.busy);
      expect(fixture.view, isNull);
      expect(fixture.views.where((v) => v != null), isEmpty);
      expectNotFound(await initiator.reveal());
      await settle();
      expect(fixture.events, isEmpty);
    });

    group('C123: silence after the reveal counts (RF-106, RF-91, N1)', () {
      test('a raw client that reveals and stops polling ends in lost at '
          '10.001 s, with lostAfterReveal and one more failure for its '
          'origin', () async {
        final fixture = await receiver();
        final first = fixture.now;
        await finishWithMismatch(fixture, a);
        fixture.now = first.add(Limits.pairingGlobalWindow);
        await finishWithMismatch(fixture, a);
        fixture.now = first.add(Limits.pairingGlobalWindow * 2);
        final silent = fixture.initiator(a);
        await silent.begin();

        fixture.advance(const Duration(seconds: 10, milliseconds: 1));

        await eventually(() => fixture.view?.outcome == PairingOutcome.lost);
        await eventually(() => fixture.events.isNotEmpty);
        expect(fixture.events.map((e) => e.runtimeType), [
          PairingAttemptRejected,
        ]);
        final event = fixture.events.single as PairingAttemptRejected;
        expect(event.fingerprint, a.fingerprint);
        expect(event.cause, AttemptCause.lostAfterReveal);
        expect(fixture.coordinator.busy, isFalse);
        expectRejected(await fixture.initiator(a).start());
        expect(
          (await fixture.initiator(b, from: otherLoopback).start())!.status,
          200,
        );
      });

      test('a raw client that stops before revealing ends silently and its '
          'origin keeps its streak as it was', () async {
        final fixture = await receiver();
        final first = fixture.now;
        await finishWithMismatch(fixture, a);
        fixture.now = first.add(Limits.pairingGlobalWindow);
        await finishWithMismatch(fixture, a);
        fixture.now = first.add(Limits.pairingGlobalWindow * 2);
        final silent = fixture.initiator(a);
        expect((await silent.start())!.status, 200);

        fixture.advance(const Duration(seconds: 10, milliseconds: 1));

        await eventually(() => !fixture.coordinator.busy);
        await settle();
        expect(fixture.events, isEmpty);
        expect(fixture.view, isNull);
        final again = fixture.initiator(a);
        expect((await again.start())!.status, 200);
        expectState(await again.cancel(CancelReason.cancelled), 'cancelled');
      });
    });

    test('a held wait keeps the session alive and its answer refreshes the '
        'last contact', () async {
      final fixture = await receiver(pollHold: const Duration(seconds: 2));
      final initiator = fixture.initiator(a);
      await initiator.begin();
      final held = initiator.wait();
      await eventually(() => fixture.handledOn(ApiPaths.pairWait) == 1);

      fixture.advance(const Duration(seconds: 15));
      await settle(const Duration(milliseconds: 300));
      expect(fixture.view!.phase, PairingPhase.comparing);
      expectState(await held, 'pending');
      await settle();
      expect(fixture.view!.phase, PairingPhase.comparing);

      fixture.advance(const Duration(seconds: 10, milliseconds: 1));
      await eventually(() => fixture.view?.phase == PairingPhase.finished);
      expect(fixture.view!.outcome, PairingOutcome.lost);
    });

    test('the final record answers for 30 s and is then pruned', () async {
      final fixture = await receiver();
      final initiator = fixture.initiator(a);
      await initiator.begin();
      expectState(await initiator.cancel(CancelReason.cancelled), 'cancelled');

      fixture.advance(const Duration(seconds: 29));
      await settle();
      expectState(await initiator.wait(), 'cancelled');
      fixture.advance(const Duration(seconds: 1));
      await settle();

      expectNotFound(await initiator.wait());
      expectNotFound(await initiator.confirm());
    });

    test('at most 16 final records are kept, dropping the oldest', () async {
      final fixture = await receiver(ticking: false);
      final finished = <RawInitiator>[];
      for (var i = 0; i < 17; i++) {
        if (i > 0 && i % 5 == 0) {
          fixture.advance(Limits.pairingRequestWindow);
        }
        fixture.advance(const Duration(seconds: 1));
        final initiator = fixture.initiator(a);
        expect((await initiator.start())!.status, 200, reason: 'start $i');
        expectState(
          await initiator.cancel(CancelReason.cancelled),
          'cancelled',
        );
        finished.add(initiator);
      }

      expectNotFound(await finished.first.wait());
      expectState(await finished[1].wait(), 'cancelled');
      expectState(await finished.last.wait(), 'cancelled');
    });
  });

  group('pair/wait (A8)', () {
    test('a pending wait is held for pollHold and answers pending', () async {
      final fixture = await receiver(
        pollHold: const Duration(milliseconds: 400),
      );
      final initiator = fixture.initiator(a);
      await initiator.begin();

      final stopwatch = Stopwatch()..start();
      final reply = await initiator.wait();

      expectState(reply, 'pending');
      expect(
        stopwatch.elapsed,
        greaterThanOrEqualTo(const Duration(milliseconds: 350)),
      );
      expect(stopwatch.elapsed, lessThan(const Duration(seconds: 3)));
    });

    test('a held wait wakes up at once when the session changes', () async {
      final fixture = await receiver(pollHold: const Duration(seconds: 8));
      final initiator = fixture.initiator(a);
      await initiator.begin();
      final stopwatch = Stopwatch()..start();
      final held = initiator.wait();
      await eventually(() => fixture.handledOn(ApiPaths.pairWait) == 1);

      fixture.coordinator.answerAsReceiver(ReceiverAnswer.mismatch);

      expectState(await held, 'cancelled');
      expect(stopwatch.elapsed, lessThan(const Duration(seconds: 3)));
    });

    test(
      'a held wait wakes up with the pair/cancel of the initiator',
      () async {
        final fixture = await receiver(pollHold: const Duration(seconds: 8));
        final initiator = fixture.initiator(a);
        await initiator.begin();
        final stopwatch = Stopwatch()..start();
        final held = initiator.wait();
        await eventually(() => fixture.handledOn(ApiPaths.pairWait) == 1);

        expectState(
          await initiator.cancel(CancelReason.cancelled),
          'cancelled',
        );

        expectState(await held, 'cancelled');
        expect(stopwatch.elapsed, lessThan(const Duration(seconds: 3)));
      },
    );

    test('a held wait wakes up with paired once the save ends', () async {
      final fixture = await receiver(pollHold: const Duration(seconds: 8));
      final initiator = fixture.initiator(a);
      await initiator.begin();
      fixture.coordinator.answerAsReceiver(ReceiverAnswer.matches);
      final stopwatch = Stopwatch()..start();
      final held = initiator.wait();
      await eventually(() => fixture.handledOn(ApiPaths.pairWait) == 1);

      expectState(await initiator.confirm(), 'paired');

      expectState(await held, 'paired');
      expect(stopwatch.elapsed, lessThan(const Duration(seconds: 3)));
    });

    test('a wait on a final session answers at once', () async {
      final fixture = await receiver(pollHold: const Duration(seconds: 8));
      final initiator = fixture.initiator(a);
      await initiator.begin();
      fixture.coordinator.answerAsReceiver(ReceiverAnswer.mismatch);

      final stopwatch = Stopwatch()..start();
      expectState(await initiator.wait(), 'cancelled');
      expect(stopwatch.elapsed, lessThan(const Duration(seconds: 2)));
    });
  });

  group('interfaces (RF-92, C49)', () {
    test(
      'the interface of the session stops being active: networkChanged',
      () async {
        final fixture = await receiver(twoInterfaces: true);
        final initiator = fixture.initiator(a);
        await initiator.begin();

        fixture.coordinator.interfacesChanged({
          fixture.primary.id,
          fixture.secondary!.id,
        });
        expect(fixture.view!.phase, PairingPhase.comparing);
        fixture.coordinator.interfacesChanged({fixture.secondary!.id});

        expect(fixture.view!.phase, PairingPhase.finished);
        expect(fixture.view!.outcome, PairingOutcome.networkChanged);
        expect(fixture.coordinator.busy, isFalse);
        expectState(await initiator.wait(), 'cancelled');
      },
    );

    test('a session through the second interface follows that one', () async {
      final fixture = await receiver(twoInterfaces: true);
      final initiator = fixture.initiator(a, to: otherLoopback);
      await initiator.begin();

      fixture.coordinator.interfacesChanged({fixture.secondary!.id});
      expect(fixture.view!.phase, PairingPhase.comparing);
      fixture.coordinator.interfacesChanged({fixture.primary.id});

      expect(fixture.view!.outcome, PairingOutcome.networkChanged);
    });

    test('before the reveal it ends silently', () async {
      final fixture = await receiver();
      expect((await fixture.initiator(a).start())!.status, 200);

      fixture.coordinator.interfacesChanged(const {});

      expect(fixture.coordinator.busy, isFalse);
      expect(fixture.view, isNull);
    });

    test('with no session nothing changes', () async {
      final fixture = await receiver();

      fixture.coordinator.interfacesChanged(const {});
      await settle();

      expect(fixture.views, isEmpty);
      expect(fixture.view, isNull);
    });
  });

  group('pair/status (RF-118, RF-119, A9, C60)', () {
    Map<String, Object?> statusBody(
      DeviceIdentity caller, {
      String? serverFingerprint,
      Uint8List? signedChallenge,
      Uint8List? sentChallenge,
      Uint8List Function(List<int> data)? sign,
      String? certificatePem,
    }) {
      final challenge = signedChallenge ?? randomBytes(challengeLength);
      final proof = (sign ?? caller.sign)(
        statusTranscript(
          callerFingerprint: caller.fingerprint,
          serverFingerprint: serverFingerprint ?? r.fingerprint,
          challenge: challenge,
        ),
      );
      return StatusRequest(
        certificate: certificatePem ?? caller.certificatePem,
        challenge: sentChallenge ?? challenge,
        proof: proof,
      ).toJson();
    }

    test('answers whether the caller is paired, only to the holder of its '
        'key, and changes nothing', () async {
      final fixture = await receiver(pairedWith: [b]);

      final notPaired = await rawPost(
        fixture,
        ApiPaths.pairStatus,
        statusBody(a),
      );
      final isPaired = await rawPost(
        fixture,
        ApiPaths.pairStatus,
        statusBody(b),
      );

      expect(notPaired!.status, 200);
      expect(notPaired.json, {'paired': false});
      expect(isPaired!.status, 200);
      expect(isPaired.json, {'paired': true});
      await settle();
      expect(fixture.coordinator.busy, isFalse);
      expect(fixture.view, isNull);
      expect(fixture.views, isEmpty);
      expect(fixture.events, isEmpty);
      expect(fixture.paired.devices.single.fingerprint, b.fingerprint);
    });

    test('an invalid proof, a proof for another server, another challenge, '
        'another certificate or a malformed body get the same 403', () async {
      final fixture = await receiver(pairedWith: [b]);
      final cases = <String, Object?>{
        'proof by another key': statusBody(b, sign: a.sign),
        'proof for another server': statusBody(
          b,
          serverFingerprint: otherReceiver.fingerprint,
        ),
        'another challenge': statusBody(
          b,
          sentChallenge: randomBytes(challengeLength),
        ),
        'certificate of b, proof of a': statusBody(
          a,
          certificatePem: b.certificatePem,
        ),
        'invalid certificate': {
          ...statusBody(b),
          'certificate': HandMadeCertificate('NexusBridges-api-bob').pem,
        },
        'extra key': {...statusBody(b), 'x': 1},
      };

      for (final entry in cases.entries) {
        expectRejected(
          await rawPost(fixture, ApiPaths.pairStatus, entry.value),
          reason: entry.key,
        );
      }
      expect(fixture.views, isEmpty);
    });
  });

  group('unpair (RF-116, RF-119, A10, C58, C97)', () {
    Future<RawReply?> unpairAs(
      ReceiverFixture fixture,
      DeviceIdentity caller, {
      bool presentCertificate = true,
    }) => rawPost(
      fixture,
      ApiPaths.unpair,
      const <String, Object?>{},
      context: caller.clientContext(presentCertificate: presentCertificate),
    );

    test('a paired device that unpairs is removed and UnpairedByPeer is '
        'emitted; nobody else is touched', () async {
      final fixture = await receiver(pairedWith: [a, d]);

      final reply = await unpairAs(fixture, a);

      expect(reply!.status, 200);
      expect(reply.json, isEmpty);
      await eventually(() => fixture.events.isNotEmpty);
      final event = fixture.events.single as UnpairedByPeer;
      expect(event.fingerprint, a.fingerprint);
      expect(event.name, 'peer');
      expect(event.saved, isTrue);
      expect(fixture.paired.isPaired(a.fingerprint), isFalse);
      expect(fixture.paired.isPaired(d.fingerprint), isTrue);
      final file = fixture.pairedFile.readAsStringSync();
      expect(file, isNot(contains(a.fingerprint)));
      expect(file, contains(d.fingerprint));
      expect(fixture.handledOn(ApiPaths.unpair), 1);
    });

    test('another paired device removes only itself', () async {
      final fixture = await receiver(pairedWith: [a, d]);

      expect((await unpairAs(fixture, d))!.status, 200);

      await eventually(() => fixture.events.isNotEmpty);
      expect(
        (fixture.events.single as UnpairedByPeer).fingerprint,
        d.fingerprint,
      );
      expect(fixture.paired.devices.single.fingerprint, a.fingerprint);
    });

    test('a device that is not paired never reaches the handler', () async {
      final fixture = await receiver(pairedWith: [a]);

      final reply = await unpairAs(fixture, c);

      expect(reply, isNull);
      expect(fixture.handledOn(ApiPaths.unpair), 0);
      await settle();
      expect(fixture.paired.isPaired(a.fingerprint), isTrue);
      expect(fixture.events, isEmpty);
    });

    test('without a certificate: 401 and the handler is not reached', () async {
      final fixture = await receiver(pairedWith: [a]);

      final reply = await unpairAs(fixture, a, presentCertificate: false);

      expect(reply!.status, 401);
      expect(reply.json, {'error': 'unauthorized'});
      expect(fixture.handledOn(ApiPaths.unpair), 0);
      expect(fixture.paired.isPaired(a.fingerprint), isTrue);
    });

    test('a device removed between the route decision and the handler gets '
        '401 (C97)', () async {
      final fixture = await receiver(pairedWith: [a]);
      fixture.wrappers[ApiPaths.unpair] = (call, inner) async {
        await fixture.paired.remove(call.clientFingerprint!);
        return inner(call);
      };

      final reply = await unpairAs(fixture, a);

      expect(reply!.status, 401);
      expect(reply.json, {'error': 'unauthorized'});
      await settle();
      expect(fixture.events, isEmpty);
    });

    test('an unpair that cannot be saved still removes it for the session '
        'and says so', () async {
      final fixture = await receiver(pairedWith: [a]);
      lockFile(fixture.pairedFile);

      expect((await unpairAs(fixture, a))!.status, 200);

      await eventually(
        () => fixture.events.isNotEmpty,
        limit: const Duration(seconds: 10),
      );
      expect((fixture.events.single as UnpairedByPeer).saved, isFalse);
      expect(fixture.paired.isPaired(a.fingerprint), isFalse);
      expect(fixture.paired.hasUnsavedChanges, isTrue);
    });

    test('a GET to unpair or to a pairing route is not allowed', () async {
      final fixture = await receiver(pairedWith: [a]);

      final reply = await sendOrCut(
        fixture.port,
        httpRequest('GET', ApiPaths.pairStart),
        serverFingerprint: r.fingerprint,
      );

      expect(reply!.status, 405);
      expect(fixture.handledOn(ApiPaths.pairStart), 0);
    });
  });

  group('routes (T8 step 3)', () {
    test('seven routes, all with the pairing body limit, anonymous except '
        'unpair, with the limits of the plan', () async {
      final fixture = await receiver();
      final routes = {
        for (final route in fixture.coordinator.routes) route.path: route,
      };

      expect(routes.keys.toSet(), {
        ApiPaths.pairStart,
        ApiPaths.pairReveal,
        ApiPaths.pairWait,
        ApiPaths.pairConfirm,
        ApiPaths.pairCancel,
        ApiPaths.pairStatus,
        ApiPaths.unpair,
      });
      for (final route in routes.values) {
        expect(
          route.maxBodyBytes,
          Limits.maxPairingBodyBytes,
          reason: route.path,
        );
      }
      expect(routes[ApiPaths.unpair]!.access, RouteAccess.paired);
      for (final path in routes.keys.where((p) => p != ApiPaths.unpair)) {
        expect(routes[path]!.access, RouteAccess.anonymous, reason: path);
      }
      expect(routes[ApiPaths.pairStart]!.limit, isNull);
      for (final path in [
        ApiPaths.pairReveal,
        ApiPaths.pairWait,
        ApiPaths.pairConfirm,
        ApiPaths.pairCancel,
      ]) {
        final limit = routes[path]!.limit!;
        expect(limit.maxPerWindow, Limits.pairSessionRequestsPerMinute);
        expect(limit.window, const Duration(minutes: 1));
        expect(limit.block, Limits.routeBlock);
      }
      expect(
        routes[ApiPaths.pairStatus]!.limit!.maxPerWindow,
        Limits.pairStatusPerMinute,
      );
      expect(
        routes[ApiPaths.unpair]!.limit!.maxPerWindow,
        Limits.unpairPerMinute,
      );
    });
  });

  group('close (T8 done criteria)', () {
    test('wakes held requests, frees the session, closes the streams, leaves '
        'no timer and is idempotent', () async {
      final tracker = TimerTracker();
      await runZoned(() async {
        final fixture = await receiver(pollHold: const Duration(seconds: 8));
        final initiator = fixture.initiator(a);
        await initiator.begin();
        final held = initiator.wait();
        await eventually(() => fixture.handledOn(ApiPaths.pairWait) == 1);
        expect(tracker.activeBy('src/pairing_flow/'), greaterThanOrEqualTo(2));
        final stopwatch = Stopwatch()..start();

        await fixture.coordinator.close();

        expectState(await held, 'cancelled');
        expect(stopwatch.elapsed, lessThan(const Duration(seconds: 2)));
        expect(fixture.view, isNull);
        expect(fixture.coordinator.busy, isFalse);
        await eventually(() => fixture.changesClosed && fixture.eventsClosed);
        expect(tracker.createdBy('src/pairing_flow/'), greaterThanOrEqualTo(2));
        expect(tracker.activeBy('src/pairing_flow/'), 0);
        await fixture.coordinator.close();
        expectRejected(await fixture.initiator(b).start());
        expectState(await initiator.wait(), 'cancelled');
        fixture.coordinator.answerAsReceiver(ReceiverAnswer.matches);
        fixture.coordinator.interfacesChanged(const {});
        fixture.coordinator.dismissOutcome();
        fixture.coordinator.start();
        await settle();
        expect(tracker.activeBy('src/pairing_flow/'), 0);
        expect(fixture.events, isEmpty);
        expect(fixture.paired.devices, isEmpty);
      }, zoneSpecification: tracker.specification);
    });

    test('a save that ends after close emits nothing', () async {
      final fixture = await receiver();
      final initiator = fixture.initiator(a);
      await initiator.begin();
      final held = lockFile(fixture.pairedFile);
      fixture.coordinator.answerAsReceiver(ReceiverAnswer.matches);
      final confirming = initiator.confirm();
      await eventually(() => fixture.handledOn(ApiPaths.pairConfirm) == 1);
      await settle(const Duration(milliseconds: 30));

      await fixture.coordinator.close();
      held.release();
      await confirming;

      await settle(const Duration(milliseconds: 800));
      expect(fixture.events, isEmpty);
      expect(fixture.view, isNull);
    });

    test('a coordinator that is never started still closes cleanly', () async {
      final fixture = await receiver(ticking: false);

      await fixture.coordinator.close();

      await eventually(() => fixture.changesClosed && fixture.eventsClosed);
      expectRejected(await fixture.initiator(a).start());
    });
  });

  group('ApiServer serves the coordinator routes over real TLS', () {
    test('the initiator never presents a certificate on the anonymous '
        'routes', () async {
      final fixture = await receiver();
      final calls = <ApiCall>[];
      fixture.wrappers[ApiPaths.pairStart] = (call, inner) {
        calls.add(call);
        return inner(call);
      };

      expect((await fixture.initiator(a).start())!.status, 200);

      expect(calls.single.clientFingerprint, isNull);
      expect(calls.single.remoteAddress.address, '127.0.0.1');
      expect(calls.single.via.id, fixture.primary.id);
    });
  });
}
