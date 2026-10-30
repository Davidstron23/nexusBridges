import 'package:nexus_bridges_core/src/node/node.dart';
import 'package:test/test.dart';

import 'two_nodes_harness.dart';

const Duration _noticeGivenUp = Duration(seconds: 6);

Future<(TestNode, TestNode)> _mismatched() async {
  final (a, b) = await twoNodes();
  await meet(a, b);
  await pairNodes(a, b);
  await b.inZone(() => b.node.answerMine(a.fingerprint, mine: true));
  await a.inZone(() => a.node.answerMine(b.fingerprint, mine: false));
  await b.node.shutdown();
  await a.inZone(() => a.node.unpair(b.fingerprint));
  expect(a.hasPaired(b), isFalse);
  await pause(_noticeGivenUp);
  await b.restart();
  expect(await b.savedPairedFingerprints(), contains(a.fingerprint));
  return (a, b);
}

bool _anyMark(TestNode node) =>
    node.states.any((s) => s.entries.any((e) => e.mismatch)) ||
    node.state.entries.any((e) => e.mismatch);

Future<void> _bothForget(TestNode a, TestNode b, Duration span) async {
  a.advance(span);
  b.advance(span);
  await eventually(() => !a.sees(b) && !b.sees(a), reason: 'both expired');
}

void main() {
  group('no false mismatch right after pairing (peerCheckAfterPairing)', () {
    test('after a good pairing neither side shows a mark through two '
        'checks of each scheduler', () async {
      final (a, b) = await twoNodes();
      await meet(a, b);
      await pairNodes(a, b);
      final startA = a.checksStarted;
      final startB = b.checksStarted;

      for (final span in [
        const Duration(seconds: 31),
        const Duration(minutes: 5, seconds: 1),
      ]) {
        final beforeA = a.checksStarted;
        final beforeB = b.checksStarted;
        await _bothForget(a, b, span);
        await meet(a, b);
        await eventually(
          () => a.checksStarted > beforeA && b.checksStarted > beforeB,
          reason: 'a check on each side',
        );
        await pause(const Duration(seconds: 1));
      }

      expect(a.checksStarted - startA, greaterThanOrEqualTo(2));
      expect(b.checksStarted - startB, greaterThanOrEqualTo(2));
      expect(_anyMark(a), isFalse);
      expect(_anyMark(b), isFalse);
      expect(a.hasPaired(b), isTrue);
      expect(b.hasPaired(a), isTrue);
    }, timeout: twoNodesTimeout);

    test('a real mismatch that appears within the 30 s after pairing is '
        'still marked once they are over', () async {
      final (a, b) = await twoNodes();
      await meet(a, b);
      await pairNodes(a, b);
      await a.node.shutdown();
      await a.pairedFile.delete();
      await a.restart();
      await meet(a, b);
      expect(a.hasPaired(b), isFalse);

      b.advance(const Duration(seconds: 20));
      await meet(a, b);
      await pause(const Duration(seconds: 1));
      expect(b.entryOf(a.fingerprint)?.mismatch, isFalse);

      b.advance(const Duration(seconds: 31));
      await eventually(() => !b.sees(a), reason: 'B forgets A');
      await meet(a, b);
      await b.until(
        (s) => b.entryOf(a.fingerprint)?.mismatch == true,
        limit: const Duration(seconds: 5),
        reason: 'mismatch in B after the wait',
      );
      expect(b.hasPaired(a), isTrue);
    }, timeout: twoNodesTimeout);
  });

  group('mismatch after being unpaired while off (C81, RF-118, RF-119)', () {
    test('B marks A with mismatch at most 5 s after seeing it, keeps A in '
        'memory and in the file, and offers to pair again', () async {
      final (a, b) = await _mismatched();

      await meet(a, b);
      await b.until(
        (s) => b.entryOf(a.fingerprint)?.mismatch == true,
        limit: const Duration(seconds: 5),
        reason: 'mismatch in B',
      );

      final entry = b.entryOf(a.fingerprint)!;
      expect(entry.paired, isTrue);
      expect(entry.visible, isTrue);
      expect(entry.mine, isTrue);
      expect(entry.canPair, isTrue);
      await pause(const Duration(seconds: 1));
      expect(b.hasPaired(a), isTrue);
      expect(await b.savedPairedFingerprints(), contains(a.fingerprint));
      expect(b.state.notices, isEmpty);
      expect(a.entryOf(b.fingerprint)?.mismatch, isFalse);
      expect(a.entryOf(b.fingerprint)?.paired, isFalse);
    }, timeout: twoNodesTimeout);

    test(
      'B pairs again from the mark: B asks nothing and the mark goes '
      'away keeping "mine", A pairs B as new and asks "is it yours?"',
      () async {
        final (a, b) = await _mismatched();
        await meet(a, b);
        await b.until((s) => b.entryOf(a.fingerprint)?.mismatch == true);
        final questionsBefore = b.state.questions;

        expect(
          await b.inZone(() => b.node.pair(a.fingerprint)),
          PairRequestResult.started,
        );
        final shown = await a.until(
          (s) => s.pairing?.phase == PairingPhase.comparing,
        );
        expect(shown.pairing!.alreadyPaired, isFalse);
        expect(shown.pairing!.role, PairingRole.receiver);
        await b.until((s) => s.pairing?.phase == PairingPhase.comparing);
        expect(b.state.pairing!.code, a.state.pairing!.code);
        b.zone.run(() => b.node.answerCode(matches: true));
        a.zone.run(() => a.node.answerRequest(ReceiverAnswer.matches));

        await a.until(
          (s) =>
              a.hasPaired(b) &&
              s.pairing?.outcome == PairingOutcome.paired &&
              s.pairing!.isNew,
          reason: 'A paired again and shows it as new',
        );
        await b.until(
          (s) => b.entryOf(a.fingerprint)?.mismatch == false,
          reason: 'mark cleared in B',
        );
        expect(b.state.pairing?.outcome, PairingOutcome.paired);
        expect(b.state.pairing!.isNew, isFalse);
        expect(b.state.questions, questionsBefore);
        expect(
          b.state.questions.whereType<MineQuestion>().where(
            (q) => q.fingerprint == a.fingerprint,
          ),
          isEmpty,
        );
        expect(b.entryOf(a.fingerprint)!.mine, isTrue);
        expect(b.entryOf(a.fingerprint)!.paired, isTrue);
        expect(
          a.state.questions.whereType<MineQuestion>().map((q) => q.fingerprint),
          contains(b.fingerprint),
        );
        expect(a.entryOf(b.fingerprint)!.mine, isFalse);
        expect(await a.savedPairedFingerprints(), contains(b.fingerprint));
      },
      timeout: twoNodesTimeout,
    );

    test('B removes A from the mark: A leaves the list and the file of B, '
        'the mark is gone and no failure notice appears', () async {
      final (a, b) = await _mismatched();
      await meet(a, b);
      await b.until((s) => b.entryOf(a.fingerprint)?.mismatch == true);

      await b.inZone(() => b.node.unpair(a.fingerprint));

      final entry = b.entryOf(a.fingerprint)!;
      expect(entry.paired, isFalse);
      expect(entry.mismatch, isFalse);
      expect(entry.canPair, isTrue);
      expect(await b.savedPairedFingerprints(), isNot(contains(a.fingerprint)));
      expect(b.state.notices, isEmpty);
      await pause();
      expect(a.state.notices, isEmpty);
    }, timeout: twoNodesTimeout);

    test('control: two nodes that still have each other show no mark after '
        'the check', () async {
      final (a, b) = await twoNodes();
      await meet(a, b);
      await pairNodes(a, b);
      await b.node.shutdown();
      await b.restart();
      await meet(a, b);
      await pause(const Duration(seconds: 2));

      expect(b.entryOf(a.fingerprint)?.mismatch, isFalse);
      expect(a.entryOf(b.fingerprint)?.mismatch, isFalse);
      expect(b.hasPaired(a), isTrue);
      expect(a.hasPaired(b), isTrue);
    }, timeout: twoNodesTimeout);
  });
}
