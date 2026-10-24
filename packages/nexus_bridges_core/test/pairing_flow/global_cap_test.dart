import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:nexus_bridges_core/src/identity/identity.dart';
import 'package:nexus_bridges_core/src/pairing_flow/crypto.dart';
import 'package:nexus_bridges_core/src/pairing_flow/messages.dart';
import 'package:nexus_bridges_core/src/pairing_flow/pairing_flow.dart';
import 'package:nexus_bridges_core/src/protocol/protocol.dart';
import 'package:test/test.dart';

import 'receiver_harness.dart';

final Uint8List rejectedBody = utf8.encode('{"error":"rejected"}');
final Uint8List busyBody = utf8.encode('{"error":"busy"}');
final Uint8List pausedBody = utf8.encode('{"error":"paused"}');

InternetAddress origin(int n) =>
    InternetAddress('127.0.${10 + n ~/ 250}.${1 + n % 250}');

String summary(PairingEvent event) => switch (event) {
  PairingAttemptRejected(:final cause) => 'rejected ${cause.name}',
  PairingPaused(:final until) => 'paused $until',
  _ => '${event.runtimeType}',
};

void main() {
  const long = Timeout(Duration(minutes: 3));

  late DeviceIdentity r;
  late List<DeviceIdentity> peers;

  setUpAll(() {
    r = DeviceIdentity.generate();
    peers = [for (var i = 0; i < 4; i++) DeviceIdentity.generate()];
  });

  DeviceIdentity peer(int n) => peers[n % peers.length];

  Future<ReceiverFixture> receiver() => ReceiverFixture.start(identity: r);

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

  void expectState(RawReply? reply, String state, {String reason = ''}) {
    expect(reply, isNotNull, reason: reason);
    expect(reply!.status, 200, reason: reason);
    expect(reply.json, {'state': state}, reason: reason);
  }

  Future<void> failWithMismatch(ReceiverFixture fixture, int n) async {
    await fixture.initiator(peer(n), from: origin(n)).begin();
    fixture.coordinator.answerAsReceiver(ReceiverAnswer.mismatch);
    expect(fixture.coordinator.busy, isFalse);
  }

  Future<void> failWithPeerCancel(ReceiverFixture fixture, int n) async {
    final initiator = fixture.initiator(peer(n), from: origin(n));
    await initiator.begin();
    expectState(await initiator.cancel(CancelReason.cancelled), 'cancelled');
  }

  Future<void> failWithCommitment(ReceiverFixture fixture, int n) async {
    final initiator = fixture.initiator(peer(n), from: origin(n));
    expect((await initiator.start())!.status, 200);
    expectRejected(await initiator.reveal(nonce: randomBytes(nonceLength)));
  }

  Future<RawReply?> freshStart(ReceiverFixture fixture, int n) =>
      fixture.initiator(peer(n), from: origin(n)).start();

  Future<void> startAndLeave(ReceiverFixture fixture, int n) async {
    final initiator = fixture.initiator(peer(n), from: origin(n));
    expect((await initiator.start())!.status, 200, reason: 'origin $n');
    expectState(await initiator.cancel(CancelReason.cancelled), 'cancelled');
  }

  group('global cap on failures after the reveal (RF-106b, Q-1)', () {
    test('a mismatch, a cancel after the reveal and a commitment that does '
        'not match, from three origins, answer the next pair/start of every '
        'origin, a new one included, with the paused bytes', () async {
      final fixture = await receiver();
      await failWithMismatch(fixture, 0);
      await failWithPeerCancel(fixture, 1);
      await failWithCommitment(fixture, 2);
      await eventually(
        () => fixture.events.whereType<PairingAttemptRejected>().length == 2,
      );
      final viewsBefore = fixture.views.length;
      final handledBefore = fixture.handledOn(ApiPaths.pairStart);

      final replies = <String, RawReply?>{
        'new origin': await freshStart(fixture, 3),
        'origin of the mismatch': await freshStart(fixture, 0),
        'origin of the cancel': await freshStart(fixture, 1),
        'origin of the commitment': await freshStart(fixture, 2),
        'another new origin and key': await fixture
            .initiator(DeviceIdentity.generate(), from: origin(40))
            .start(),
      };

      for (final MapEntry(key: label, value: reply) in replies.entries) {
        expectPaused(reply, reason: label);
      }
      expect(fixture.handledOn(ApiPaths.pairStart), handledBefore + 5);
      await settle();
      expect(fixture.coordinator.busy, isFalse);
      expect(fixture.views.length, viewsBefore);
      expect(fixture.view?.phase, isNot(PairingPhase.comparing));
    });

    test('two failures do not reject anybody', () async {
      final fixture = await receiver();
      await failWithMismatch(fixture, 0);
      await failWithPeerCancel(fixture, 1);

      await startAndLeave(fixture, 2);
      await startAndLeave(fixture, 0);
    });

    test('the window slides: each failure leaves it exactly 10 minutes after '
        'it happened', () async {
      final fixture = await receiver();
      final first = fixture.now;
      await failWithMismatch(fixture, 0);
      fixture.now = first.add(const Duration(minutes: 2));
      await failWithPeerCancel(fixture, 1);
      fixture.now = first.add(const Duration(minutes: 4));
      await failWithCommitment(fixture, 2);

      fixture.now = first.add(
        const Duration(minutes: 9, seconds: 59, milliseconds: 999),
      );
      expectPaused(await freshStart(fixture, 3));

      fixture.now = first.add(const Duration(minutes: 10));
      await startAndLeave(fixture, 4);
      await failWithMismatch(fixture, 5);
      expectPaused(await freshStart(fixture, 6));

      fixture.now = first.add(
        const Duration(minutes: 11, seconds: 59, milliseconds: 999),
      );
      expectPaused(await freshStart(fixture, 6));
      fixture.now = first.add(const Duration(minutes: 12));
      await startAndLeave(fixture, 7);
    });

    test('requests rejected by the global cap do not use the quota of their '
        'origin', () async {
      final fixture = await receiver();
      final first = fixture.now;
      await failWithMismatch(fixture, 0);
      await failWithMismatch(fixture, 1);
      await failWithMismatch(fixture, 2);

      fixture.now = first.add(const Duration(minutes: 5));
      for (var i = 0; i < 6; i++) {
        expectPaused(await freshStart(fixture, 9), reason: 'attempt $i');
      }

      fixture.now = first.add(const Duration(minutes: 10));
      for (var i = 0; i < Limits.pairingRequestsPerOrigin; i++) {
        await startAndLeave(fixture, 9);
      }
      expectRejected(await freshStart(fixture, 9));
    });

    test('cancels with reason expired after the reveal do not count', () async {
      final fixture = await receiver();
      for (var n = 0; n < 4; n++) {
        final initiator = fixture.initiator(peer(n), from: origin(n));
        await initiator.begin();
        expectState(await initiator.cancel(CancelReason.expired), 'expired');
      }

      await startAndLeave(fixture, 4);
      await settle();
      expect(fixture.events, isEmpty);
    });

    test('cancels before the reveal do not count', () async {
      final fixture = await receiver();
      for (var n = 0; n < 4; n++) {
        await startAndLeave(fixture, n);
      }

      await startAndLeave(fixture, 4);
      await settle();
      expect(fixture.events, isEmpty);
    });

    test('a reveal with an invalid signature does not count', () async {
      final fixture = await receiver();
      for (var n = 0; n < 4; n++) {
        final initiator = fixture.initiator(peer(n), from: origin(n));
        expect((await initiator.start())!.status, 200);
        expectRejected(
          await initiator.reveal(signature: randomBytes(signatureLength)),
        );
      }

      await startAndLeave(fixture, 4);
    });

    test(
      'a completed pairing does not take a failure out of the window',
      () async {
        final fixture = await receiver();
        await failWithMismatch(fixture, 0);
        await failWithMismatch(fixture, 1);
        final initiator = fixture.initiator(peer(2), from: origin(2));
        await initiator.begin();
        fixture.coordinator.answerAsReceiver(ReceiverAnswer.matches);
        expectState(await initiator.confirm(), 'paired');
        await failWithMismatch(fixture, 3);

        expectPaused(await freshStart(fixture, 4));
      },
    );

    test('Q-1: many origins that cancel right after seeing the code reach the '
        'code at most 3 times every 10 minutes, and each one leaves a '
        'notice', () async {
      final fixture = await receiver();
      const perRound = 15;
      final prompts = <int>[];
      final refused = <int>[];
      final codes = <String>{};
      for (var round = 0; round < 2; round++) {
        var reached = 0;
        var rejected = 0;
        for (var k = 0; k < perRound; k++) {
          final n = round * perRound + k;
          final attacker = fixture.initiator(peer(n), from: origin(n));
          final started = await attacker.start(name: 'PC-DAVID');
          if (started?.status != 200) {
            expectPaused(started, reason: 'origin $n');
            rejected++;
            continue;
          }
          final revealed = await attacker.reveal();
          if (revealed?.status == 200) {
            reached++;
            codes.add(attacker.code);
          }
          expectState(
            await attacker.cancel(CancelReason.cancelled),
            'cancelled',
          );
        }
        prompts.add(reached);
        refused.add(rejected);
        expectPaused(
          await fixture
              .initiator(DeviceIdentity.generate(), from: origin(200 + round))
              .start(),
          reason: 'a legitimate device in round $round',
        );
        fixture.advance(Limits.pairingGlobalWindow);
      }

      expect(prompts, [3, 3]);
      expect(refused, [perRound - 3, perRound - 3]);
      expect(codes.length, lessThanOrEqualTo(6));
      await eventually(() => fixture.events.length == 8);
      final first = fixture.now.subtract(Limits.pairingGlobalWindow * 2);
      expect(fixture.events.map(summary), [
        'rejected cancelledAfterReveal',
        'rejected cancelledAfterReveal',
        'rejected cancelledAfterReveal',
        'paused ${first.add(Limits.pairingGlobalWindow)}',
        'rejected cancelledAfterReveal',
        'rejected cancelledAfterReveal',
        'rejected cancelledAfterReveal',
        'paused ${first.add(Limits.pairingGlobalWindow * 2)}',
      ]);
    }, timeout: long);
  });

  group('PairingAttemptRejected after a cancel that follows the reveal '
      '(RF-106, RF-106b)', () {
    test('a cancel while comparing emits it with only the fingerprint and '
        'leaves cancelledByPeer on screen', () async {
      final fixture = await receiver();
      final initiator = fixture.initiator(peers[0], from: origin(0));
      await initiator.begin(name: 'Laptop');

      expectState(await initiator.cancel(CancelReason.cancelled), 'cancelled');

      await eventually(() => fixture.events.isNotEmpty);
      final event = fixture.events.single as PairingAttemptRejected;
      expect(event.fingerprint, peers[0].fingerprint);
      expect(event.cause, AttemptCause.cancelledAfterReveal);
      expect(() => (event as dynamic).name, throwsNoSuchMethodError);
      expect(fixture.view!.phase, PairingPhase.finished);
      expect(fixture.view!.outcome, PairingOutcome.cancelledByPeer);
    });

    test('a cancel while waiting for the peer, after the receiver said '
        '"matches", also emits it and counts', () async {
      final fixture = await receiver();
      for (var n = 0; n < 3; n++) {
        final initiator = fixture.initiator(peer(n), from: origin(n));
        await initiator.begin();
        fixture.coordinator.answerAsReceiver(ReceiverAnswer.matches);
        expect(fixture.view!.phase, PairingPhase.waitingPeer);
        expectState(
          await initiator.cancel(CancelReason.cancelled),
          'cancelled',
        );
      }

      await eventually(() => fixture.events.length == 4);
      expect(
        fixture.events.whereType<PairingAttemptRejected>().map(
          (e) => (e.fingerprint, e.cause),
        ),
        [
          for (var n = 0; n < 3; n++)
            (peer(n).fingerprint, AttemptCause.cancelledAfterReveal),
        ],
      );
      expect(fixture.events.last, isA<PairingPaused>());
      expect(
        (fixture.events.last as PairingPaused).until,
        fixture.now.add(Limits.pairingGlobalWindow),
      );
      expect(fixture.paired.devices, isEmpty);
      expectPaused(await freshStart(fixture, 3));
    });

    test('a repeated cancel on the finished session emits nothing more and '
        'does not count again', () async {
      final fixture = await receiver();
      final initiator = fixture.initiator(peers[0], from: origin(0));
      await initiator.begin();
      expectState(await initiator.cancel(CancelReason.cancelled), 'cancelled');
      expectState(await initiator.cancel(CancelReason.cancelled), 'cancelled');
      expectState(await initiator.cancel(CancelReason.cancelled), 'cancelled');

      await settle();
      expect(fixture.events, hasLength(1));
      await failWithMismatch(fixture, 1);
      await startAndLeave(fixture, 2);
    });

    test('a cancel with reason expired or before the reveal emits '
        'nothing', () async {
      final fixture = await receiver();
      final expired = fixture.initiator(peers[0], from: origin(0));
      await expired.begin();
      expectState(await expired.cancel(CancelReason.expired), 'expired');
      final early = fixture.initiator(peers[1], from: origin(1));
      expect((await early.start())!.status, 200);
      expectState(await early.cancel(CancelReason.cancelled), 'cancelled');

      await settle();
      expect(fixture.events, isEmpty);
    });
  });

  group('the paused reply (C109, RF-106b, RF-75)', () {
    test('during the pause every pair/start gets the same 429 bytes, without '
        'a session, a view or an event, and without using the quota of its '
        'origin', () async {
      final fixture = await receiver();
      final first = fixture.now;
      final blocked = origin(0);
      await fixture.ignored.ignore(peers[3].fingerprint, name: 'Old');
      for (var i = 0; i < 3; i++) {
        fixture.now = first.add(Duration(minutes: i));
        await fixture.initiator(peer(i), from: blocked).begin();
        fixture.coordinator.answerAsReceiver(ReceiverAnswer.mismatch);
      }
      await eventually(() => fixture.events.isNotEmpty);
      expect(fixture.events.map(summary), [
        'paused ${first.add(Limits.pairingGlobalWindow)}',
      ]);

      fixture.now = first.add(const Duration(minutes: 5));
      final viewsBefore = fixture.views.length;
      final handledBefore = fixture.handledOn(ApiPaths.pairStart);
      final replies = <String, RawReply?>{
        'valid from the blocked origin': await fixture
            .initiator(peer(1), from: blocked)
            .start(),
        'new identity from a new origin': await fixture
            .initiator(DeviceIdentity.generate(), from: origin(1))
            .start(),
        'ignored fingerprint from another origin': await fixture
            .initiator(peers[3], from: origin(2))
            .start(),
        'well formed with one key too many': await fixture
            .initiator(peer(1), from: origin(3))
            .start(edit: (body) => {...body, 'x': 1}),
      };
      for (var i = 0; i < 5; i++) {
        expectPaused(await freshStart(fixture, 1), reason: 'again $i');
      }

      for (final MapEntry(key: label, value: reply) in replies.entries) {
        expectPaused(reply, reason: label);
      }
      expect(
        {for (final reply in replies.values) reply!.text},
        {'{"error":"paused"}'},
      );
      expect(fixture.handledOn(ApiPaths.pairStart), handledBefore + 9);
      await settle();
      expect(fixture.coordinator.busy, isFalse);
      expect(fixture.view?.phase, isNot(PairingPhase.comparing));
      expect(fixture.views.length, viewsBefore);
      expect(fixture.events, hasLength(1));

      fixture.now = first.add(
        const Duration(minutes: 9, seconds: 59, milliseconds: 999),
      );
      expectPaused(await freshStart(fixture, 4));
      fixture.now = first.add(Limits.pairingGlobalWindow);
      await startAndLeave(fixture, 4);

      for (var i = 0; i < Limits.pairingRequestsPerOrigin; i++) {
        await startAndLeave(fixture, 1);
      }
      expectRejected(await freshStart(fixture, 1));

      expectRejected(await fixture.initiator(peer(1), from: blocked).start());
      fixture.now = first.add(const Duration(minutes: 12));
      for (var i = 0; i < Limits.pairingRequestsPerOrigin - 1; i++) {
        final initiator = fixture.initiator(peer(i % 3), from: blocked);
        expect((await initiator.start())!.status, 200, reason: 'start $i');
        expectState(
          await initiator.cancel(CancelReason.cancelled),
          'cancelled',
        );
      }
      expectRejected(await fixture.initiator(peer(1), from: blocked).start());
    }, timeout: long);
  });

  group('one PairingPaused per pause (C110, RF-106b)', () {
    final scenarios =
        <(String, Future<void> Function(ReceiverFixture), List<String>)>[
          ('a local mismatch', (fixture) => failWithMismatch(fixture, 2), []),
          (
            'a cancel after the reveal',
            (fixture) => failWithPeerCancel(fixture, 2),
            ['rejected cancelledAfterReveal'],
          ),
          (
            'a commitment that does not match',
            (fixture) => failWithCommitment(fixture, 2),
            ['rejected commitmentMismatch'],
          ),
        ];

    for (final (label, third, before) in scenarios) {
      test('the third failure is $label: one event when the pause starts, '
          'none for the rejected requests and a new one when three are '
          'reached again', () async {
        final fixture = await receiver();
        final first = fixture.now;
        final expected = [
          ...before,
          'paused ${first.add(Limits.pairingGlobalWindow)}',
        ];
        await failWithMismatch(fixture, 0);
        fixture.now = first.add(const Duration(minutes: 1));
        await failWithMismatch(fixture, 1);
        fixture.now = first.add(const Duration(minutes: 2));
        await third(fixture);
        await eventually(
          () => fixture.events.whereType<PairingPaused>().isNotEmpty,
        );
        await settle();
        expect(fixture.events.map(summary), expected);

        expectPaused(await freshStart(fixture, 3));
        expectPaused(await freshStart(fixture, 4));
        await settle();
        expect(fixture.events.map(summary), expected);

        fixture.now = first.add(Limits.pairingGlobalWindow);
        await failWithMismatch(fixture, 5);
        await eventually(() => fixture.events.length == expected.length + 1);
        await settle();
        expect(fixture.events.map(summary), [
          ...expected,
          'paused ${first.add(const Duration(minutes: 11))}',
        ]);
      });
    }
  });

  group('signature budget on the anonymous routes (Q-7)', () {
    Map<String, Object?> statusBody(DeviceIdentity caller) {
      final challenge = randomBytes(challengeLength);
      return StatusRequest(
        certificate: caller.certificatePem,
        challenge: challenge,
        proof: caller.sign(
          statusTranscript(
            callerFingerprint: caller.fingerprint,
            serverFingerprint: r.fingerprint,
            challenge: challenge,
          ),
        ),
      ).toJson();
    }

    Future<RawReply?> status(ReceiverFixture fixture, int n) => rawPost(
      fixture,
      ApiPaths.pairStatus,
      statusBody(peer(n)),
      from: origin(n),
    );

    void timeHandler(
      ReceiverFixture fixture,
      String path,
      List<(int, Duration)> into,
    ) {
      fixture.wrappers[path] = (call, inner) async {
        final stopwatch = Stopwatch()..start();
        final reply = await inner(call);
        stopwatch.stop();
        into.add((reply.status, stopwatch.elapsed));
        return reply;
      };
    }

    test('20 checks per second summed over origins and both routes: the 21st '
        'valid request in the same second is rejected with the generic bytes '
        'and without checking, and the next second checks again', () async {
      final fixture = await receiver();
      final starts = <(int, Duration)>[];
      final statuses = <(int, Duration)>[];
      timeHandler(fixture, ApiPaths.pairStart, starts);
      timeHandler(fixture, ApiPaths.pairStatus, statuses);

      final opened = fixture.initiator(peer(0), from: origin(0));
      expect((await opened.start())!.status, 200);
      for (var n = 1; n < 10; n++) {
        final reply = await freshStart(fixture, n);
        expect(reply!.status, 409, reason: 'start $n');
        expect(reply.body, busyBody);
      }
      for (var n = 10; n < 20; n++) {
        final reply = await status(fixture, n);
        expect(reply!.status, 200, reason: 'status $n');
        expect(reply.json, {'paired': false});
      }

      for (var n = 20; n < 25; n++) {
        expectRejected(await freshStart(fixture, n), reason: 'start $n');
        expectRejected(await status(fixture, n + 10), reason: 'status $n');
      }
      expect(fixture.view, isNull);
      expect(fixture.coordinator.busy, isTrue);

      fixture.advance(const Duration(milliseconds: 999));
      expectRejected(await freshStart(fixture, 40));
      fixture.advance(const Duration(milliseconds: 1));
      final again = await freshStart(fixture, 41);
      expect(again!.status, 409);
      expect((await status(fixture, 42))!.status, 200);

      final verified = [
        for (final (code, elapsed) in [...starts, ...statuses])
          if (code != 403) elapsed,
      ];
      final skipped = [
        for (final (code, elapsed) in [...starts, ...statuses])
          if (code == 403) elapsed,
      ];
      expect(verified, hasLength(22));
      expect(skipped, hasLength(11));
      Duration fastest(List<Duration> all) =>
          all.reduce((a, b) => a < b ? a : b);
      expect(
        fastest(skipped) * 5,
        lessThan(fastest(verified)),
        reason: 'skipped ${fastest(skipped)} vs verified ${fastest(verified)}',
      );
      expectState(await opened.cancel(CancelReason.cancelled), 'cancelled');
    }, timeout: long);

    test('the budget is shared: 20 status checks also exhaust pair/start, '
        'from an origin that never sent anything', () async {
      final fixture = await receiver();
      for (var n = 0; n < Limits.signatureChecksPerSecond; n++) {
        expect((await status(fixture, n))!.status, 200, reason: 'status $n');
      }

      expectRejected(await freshStart(fixture, 100));
      expect(fixture.coordinator.busy, isFalse);
      fixture.advance(const Duration(seconds: 1));
      await startAndLeave(fixture, 101);
    }, timeout: long);

    test('a request rejected before the signature does not use the '
        'budget', () async {
      final fixture = await receiver();
      for (var n = 0; n < 25; n++) {
        expectRejected(
          await fixture
              .initiator(peer(n), from: origin(n))
              .start(edit: (body) => {...body, 'x': 1}),
          reason: 'malformed $n',
        );
      }

      await startAndLeave(fixture, 30);
    }, timeout: long);
  });

  group('the name bound to the key on the wire (V1)', () {
    test(
      'a certificate with a valid looking name that is not the one of its '
      'key gets the generic rejection on pair/start and pair/status',
      () async {
        final fixture = await receiver();
        final unbound = HandMadeCertificate(
          'NexusBridges-${r.fingerprint.substring(0, 16).toLowerCase()}',
        );
        final legacyLike = HandMadeCertificate(randomCommonName());

        for (final forged in [unbound, legacyLike]) {
          expectRejected(
            await fixture
                .initiator(peers[0], from: origin(0))
                .start(
                  certificatePem: forged.pem,
                  signerFingerprint: forged.fingerprint,
                  sign: forged.sign,
                ),
          );
          final challenge = randomBytes(challengeLength);
          expectRejected(
            await rawPost(
              fixture,
              ApiPaths.pairStatus,
              StatusRequest(
                certificate: forged.pem,
                challenge: challenge,
                proof: forged.sign(
                  statusTranscript(
                    callerFingerprint: forged.fingerprint,
                    serverFingerprint: r.fingerprint,
                    challenge: challenge,
                  ),
                ),
              ).toJson(),
              from: origin(1),
            ),
          );
        }
        expect(fixture.coordinator.busy, isFalse);
        expect(fixture.view, isNull);
      },
    );
  });
}
