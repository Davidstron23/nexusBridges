import 'dart:convert';
import 'dart:io';

import 'package:nexus_bridges_core/src/node/node.dart';
import 'package:test/test.dart';

import 'pairing_nodes_harness.dart';

const Timeout _slow = Timeout(Duration(minutes: 2));

List<String> _savedFingerprints(File file) {
  if (!file.existsSync()) return const [];
  final json = jsonDecode(file.readAsStringSync()) as Map<String, Object?>;
  return [
    for (final d in (json['devices'] as List<Object?>))
      (d as Map<String, Object?>)['fingerprint'] as String,
  ];
}

List<NoticeKind> _kinds(NodeState s) => [for (final n in s.notices) n.kind];

const List<NoticeKind> _attemptKinds = [
  NoticeKind.attemptCancelled,
  NoticeKind.attemptDataMismatch,
  NoticeKind.attemptLost,
];

Future<void> _receiverCancels(PairingNode a, PairingNode b) async {
  expect(await a.node.pair(b.fingerprint), PairRequestResult.started);
  await bothComparing(a, b);
  b.node.answerRequest(ReceiverAnswer.matches);
  await b.until(
    (s) => s.pairing?.phase == PairingPhase.waitingPeer,
    reason: 'B waiting',
  );

  b.node.cancelRequest();

  await b.until((s) => s.pairing == null, reason: 'B closed');
  await a.until(
    (s) => s.pairing?.outcome == PairingOutcome.cancelledByPeer,
    reason: 'A sees the cancel',
  );
}

void main() {
  group('E278 RF-248 RF-89 RF-106b cancelling while waiting, with two '
      'nodes', () {
    test('(a) A answers "matches" and cancels: A closes without a result, B '
        'ends in cancelledByPeer with an attemptCancelled notice for A, and '
        'nothing is saved', () async {
      final (a, b) = await twoPairingNodes();
      expect(await a.node.pair(b.fingerprint), PairRequestResult.started);
      await bothComparing(a, b);
      a.node.answerCode(matches: true);
      await a.until(
        (s) => s.pairing?.phase == PairingPhase.waitingPeer,
        reason: 'A waiting',
      );

      a.node.cancelPairing();

      await a.until((s) => s.pairing == null, reason: 'A closed');
      final ended = await b.until(
        (s) => s.pairing?.phase == PairingPhase.finished,
        reason: 'B finished',
      );
      expect(ended.pairing!.outcome, PairingOutcome.cancelledByPeer);
      await b.until((s) => s.notices.isNotEmpty, reason: 'notice on B');
      final notice = b.state.notices.single;
      expect(notice.kind, NoticeKind.attemptCancelled);
      expect(notice.count, 1);
      expect(notice.deviceName, shortOf(a.fingerprint));
      expect(a.state.pairing, isNull);
      expect(a.state.notices, isEmpty);

      b.node.answerRequest(ReceiverAnswer.matches);
      await Future<void>.delayed(const Duration(milliseconds: 500));
      expect(b.state.pairing?.outcome, PairingOutcome.cancelledByPeer);
      expect(a.hasPaired(b), isFalse);
      expect(b.hasPaired(a), isFalse);
      expect(_savedFingerprints(a.pairedFile), isNot(contains(b.fingerprint)));
      expect(_savedFingerprints(b.pairedFile), isNot(contains(a.fingerprint)));
    }, timeout: _slow);

    test('(b) B answers "matches" and cancels the request: B closes without '
        'a result and without an attempt notice, A ends in cancelledByPeer, '
        'and nothing is saved', () async {
      final (a, b) = await twoPairingNodes();

      await _receiverCancels(a, b);

      expect(a.state.pairing!.phase, PairingPhase.finished);
      expect(a.state.pairing!.peerFingerprint, b.fingerprint);
      await Future<void>.delayed(const Duration(milliseconds: 500));
      expect(b.state.pairing, isNull);
      expect(b.state.notices, isEmpty);
      expect(a.state.notices, isEmpty);
      expect(
        b.states.where((s) => s.pairing?.phase == PairingPhase.finished),
        isEmpty,
      );
      expect(a.hasPaired(b), isFalse);
      expect(b.hasPaired(a), isFalse);
      expect(_savedFingerprints(a.pairedFile), isNot(contains(b.fingerprint)));
      expect(_savedFingerprints(b.pairedFile), isNot(contains(a.fingerprint)));

      a.node.answerCode(matches: true);
      await Future<void>.delayed(const Duration(milliseconds: 300));
      expect(a.state.pairing?.outcome, PairingOutcome.cancelledByPeer);
      expect(a.hasPaired(b), isFalse);
    }, timeout: _slow);

    test('(b) cancelRequest outside the wait changes nothing: while comparing '
        'and with no pairing', () async {
      final (a, b) = await twoPairingNodes();
      b.node.cancelRequest();
      expect(b.state.pairing, isNull);

      expect(await a.node.pair(b.fingerprint), PairRequestResult.started);
      await bothComparing(a, b);
      final comparing = b.state.pairing;
      b.node.cancelRequest();
      a.node.cancelRequest();
      await Future<void>.delayed(const Duration(milliseconds: 500));
      expect(b.state.pairing, comparing);
      expect(a.state.pairing?.phase, PairingPhase.comparing);

      b.node.answerRequest(ReceiverAnswer.matches);
      a.node.answerCode(matches: true);
      await a.until((s) => a.hasPaired(b), reason: 'A paired');
      await b.until((s) => b.hasPaired(a), reason: 'B paired');
    }, timeout: _slow);

    test('(c) three cancels of the receiver: one pairingPaused notice on B and '
        'no attempt notice; A asking again ends in paused', () async {
      final (a, b) = await twoPairingNodes();

      for (var round = 0; round < 3; round++) {
        await _receiverCancels(a, b);
        a.node.dismissPairing();
        await a.until((s) => s.pairing == null, reason: 'A dismissed $round');
        if (round < 2) {
          await Future<void>.delayed(const Duration(milliseconds: 200));
          expect(b.state.notices, isEmpty, reason: 'round $round');
        }
      }

      final paused = await b.until(
        (s) => s.notices.isNotEmpty,
        reason: 'pause notice on B',
      );
      expect(_kinds(paused), [NoticeKind.pairingPaused]);

      expect(await a.node.pair(b.fingerprint), PairRequestResult.started);
      final ended = await a.until(
        (s) => s.pairing?.phase == PairingPhase.finished,
        reason: 'A finished',
      );
      expect(ended.pairing!.outcome, PairingOutcome.paused);
      expect(ended.pairing!.code, isNull);
      await Future<void>.delayed(const Duration(milliseconds: 300));
      expect(_kinds(b.state), [NoticeKind.pairingPaused]);
      expect(
        b.states
            .expand((s) => s.notices)
            .where((n) => _attemptKinds.contains(n.kind)),
        isEmpty,
      );
      expect(b.state.pairing, isNull);
      expect(a.state.notices, isEmpty);
      expect(a.hasPaired(b), isFalse);
      expect(b.hasPaired(a), isFalse);
    }, timeout: _slow);
  });
}
