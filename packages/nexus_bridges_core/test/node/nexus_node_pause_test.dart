import 'package:nexus_bridges_core/src/node/node.dart';
import 'package:test/test.dart';

import 'pairing_nodes_harness.dart';

const Timeout _slow = Timeout(Duration(minutes: 2));

List<NoticeKind> _kinds(NodeState s) => [for (final n in s.notices) n.kind];

void main() {
  group('C112, RF-106b, RF-104: three "does not match" of the user pause the '
      'receiver and the initiator is told', () {
    test(
      'B answers "does not match" three times: one pause notice on B and '
      'no attempt notice; A ends twice in paused while B keeps the same '
      'notice; the notice goes when the pause ends and B accepts again',
      () async {
        final (a, b) = await twoPairingNodes();

        for (var round = 0; round < 3; round++) {
          expect(await a.node.pair(b.fingerprint), PairRequestResult.started);
          await bothComparing(a, b);
          b.node.answerRequest(ReceiverAnswer.mismatch);
          await a.until(
            (s) => s.pairing?.outcome == PairingOutcome.cancelledByPeer,
            reason: 'A sees the refusal $round',
          );
          a.node.dismissPairing();
          await a.until((s) => s.pairing == null);
          await b.until((s) => s.pairing == null);
          if (round < 2) {
            expect(b.state.notices, isEmpty, reason: 'round $round');
          }
        }

        final paused = await b.until(
          (s) => s.notices.isNotEmpty,
          reason: 'pause notice on B',
        );
        expect(_kinds(paused), [NoticeKind.pairingPaused]);
        final notice = paused.notices.single;
        expect(notice.canRetry, isFalse);
        expect(notice.deviceName, isNull);

        final statesBefore = b.states.length;
        for (var attempt = 0; attempt < 2; attempt++) {
          expect(await a.node.pair(b.fingerprint), PairRequestResult.started);
          final ended = await a.until(
            (s) => s.pairing?.phase == PairingPhase.finished,
            reason: 'A finished $attempt',
          );
          expect(ended.pairing!.outcome, PairingOutcome.paused);
          expect(ended.pairing!.code, isNull);
          expect(b.state.pairing, isNull);
          a.node.dismissPairing();
          await a.until((s) => s.pairing == null);
        }
        await Future<void>.delayed(const Duration(milliseconds: 300));
        expect(b.state.notices, [notice]);
        expect(
          b.states.skip(statesBefore).where((s) => s.pairing != null),
          isEmpty,
        );
        expect(a.state.notices, isEmpty);

        b.clock = b.clock.add(const Duration(minutes: 10));
        await b.until(
          (s) => s.notices.isEmpty,
          limit: const Duration(seconds: 5),
          reason: 'pause notice gone after the tick',
        );

        expect(await a.node.pair(b.fingerprint), PairRequestResult.started);
        await bothComparing(a, b);
        expect(b.state.notices, isEmpty);
        a.node.cancelPairing();
        await a.until((s) => s.pairing == null);
      },
      timeout: _slow,
    );

    test('one minute before the end the notice is still there', () async {
      final (a, b) = await twoPairingNodes();
      for (var round = 0; round < 3; round++) {
        expect(await a.node.pair(b.fingerprint), PairRequestResult.started);
        await bothComparing(a, b);
        b.node.answerRequest(ReceiverAnswer.mismatch);
        await a.until(
          (s) => s.pairing?.outcome == PairingOutcome.cancelledByPeer,
        );
        a.node.dismissPairing();
        await a.until((s) => s.pairing == null);
      }
      final notice = (await b.until((s) => s.notices.isNotEmpty))
          .notices
          .single;

      b.clock = b.clock.add(const Duration(minutes: 9));
      await Future<void>.delayed(const Duration(milliseconds: 1500));
      expect(b.state.notices, [notice]);

      b.node.dismissNotice(notice.id);
      await b.until((s) => s.notices.isEmpty);
      expect(await a.node.pair(b.fingerprint), PairRequestResult.started);
      final ended = await a.until(
        (s) => s.pairing?.phase == PairingPhase.finished,
      );
      expect(ended.pairing!.outcome, PairingOutcome.paused);
      await Future<void>.delayed(const Duration(milliseconds: 300));
      expect(b.state.notices, isEmpty);
    }, timeout: _slow);
  });
}
