import 'package:nexus_bridges_core/src/node/node.dart';
import 'package:test/test.dart';

import 'two_nodes_harness.dart';

Future<(TestNode, TestNode)> _pairedNodes() async {
  final (a, b) = await twoNodes();
  await meet(a, b);
  await pairNodes(a, b);
  return (a, b);
}

bool _hasMineQuestionAbout(NodeState s, TestNode other) => s.questions.any(
  (q) => q is MineQuestion && q.fingerprint == other.fingerprint,
);

void main() {
  group('unpair with both nodes on (C80, RF-113, RF-115, RF-116)', () {
    test('A unpairs B: B leaves the list and paired.json of A at once, B '
        'removes A on its own side and shows unpairedByPeer with the name '
        'and the short fingerprint of A', () async {
      final (a, b) = await _pairedNodes();

      await a.inZone(() => a.node.unpair(b.fingerprint));

      expect(a.entryOf(b.fingerprint)?.paired, isFalse);
      expect(a.entryOf(b.fingerprint)?.visible, isTrue);
      expect(await a.savedPairedFingerprints(), isNot(contains(b.fingerprint)));
      expect(a.state.notices, isEmpty);
      expect(a.state.unsavedChanges, isFalse);
      final seen = await b.until(
        (s) => s.notices.any((n) => n.kind == NoticeKind.unpairedByPeer),
        reason: 'unpairedByPeer in B',
      );
      expect(b.entryOf(a.fingerprint)?.paired, isFalse);
      expect(seen.notices.single.deviceName, a.label);
      expect(seen.notices.single.canRetry, isFalse);
      await eventually(
        () async =>
            !(await b.savedPairedFingerprints()).contains(a.fingerprint),
        reason: 'paired.json of B without A',
      );
      expect(b.state.unsavedChanges, isFalse);
    }, timeout: twoNodesTimeout);

    test('unpair drops the pending questions about that device on both '
        'sides', () async {
      final (a, b) = await _pairedNodes();
      expect(_hasMineQuestionAbout(a.state, b), isTrue);
      expect(_hasMineQuestionAbout(b.state, a), isTrue);

      await a.inZone(() => a.node.unpair(b.fingerprint));

      expect(_hasMineQuestionAbout(a.state, b), isFalse);
      await b.until(
        (s) => s.notices.any((n) => n.kind == NoticeKind.unpairedByPeer),
      );
      expect(_hasMineQuestionAbout(b.state, a), isFalse);
    }, timeout: twoNodesTimeout);

    test('an open TLS connection of B is cut and a new one with its '
        'certificate is refused, while a connection without certificate '
        'still works (RF-113, SEC-18)', () async {
      final (a, b) = await _pairedNodes();
      final bIdentity = await b.loadIdentity();
      expect(
        await registerWith(
          bIdentity,
          a,
          from: hostB,
          callerName: b.deviceName,
          callerPort: b.port,
        ),
        200,
      );
      final open = await openTlsConnection(bIdentity, a, from: hostB);
      var cut = false;
      open.closed.then((_) => cut = true).ignore();
      await pause();
      expect(cut, isFalse);

      final watch = Stopwatch()..start();
      await a.inZone(() => a.node.unpair(b.fingerprint));
      await open.closed.timeout(const Duration(seconds: 1));
      watch.stop();

      expect(watch.elapsed, lessThan(const Duration(seconds: 1)));
      expect(
        await registerWith(
          bIdentity,
          a,
          from: hostB,
          callerName: b.deviceName,
          callerPort: b.port,
        ),
        isNull,
      );
      expect(
        await registerWith(
          bIdentity,
          a,
          from: hostB,
          callerName: b.deviceName,
          callerPort: b.port,
          presentCertificate: false,
        ),
        200,
      );
    }, timeout: twoNodesTimeout);

    test('unpairing a fingerprint that is not paired does nothing and '
        'emits nothing', () async {
      final (a, b) = await _pairedNodes();
      await pause();
      final emitted = a.states.length;
      final notices = a.state.notices;

      await a.inZone(() => a.node.unpair('F' * 64));
      await pause();

      expect(a.states, hasLength(emitted));
      expect(a.state.notices, notices);
      expect(a.hasPaired(b), isTrue);
      expect(await a.savedPairedFingerprints(), contains(b.fingerprint));
    }, timeout: twoNodesTimeout);
  });

  group('unpair that cannot be saved (C76, RF-113, RF-114)', () {
    test('with paired.json of A locked: B is out of the list at once, its '
        'open connection is cut while the file still lists it, the notice '
        'unpairNotSaved can be retried, B is told anyway, and retrySave '
        'after unlocking clears the notice and the file', () async {
      final (a, b) = await _pairedNodes();
      final bIdentity = await b.loadIdentity();
      final open = await openTlsConnection(bIdentity, a, from: hostB);
      await pause();
      final lock = HeldLock.on(a.pairedFile);

      final unpairing = a.inZone(() => a.node.unpair(b.fingerprint));
      await open.closed.timeout(const Duration(seconds: 5));
      expect(lock.read(), contains(b.fingerprint));
      expect(a.entryOf(b.fingerprint)?.paired, isFalse);
      await unpairing;

      final notice = a.noticesOf(NoticeKind.unpairNotSaved).single;
      expect(notice.deviceName, b.label);
      expect(notice.canRetry, isTrue);
      expect(a.state.unsavedChanges, isTrue);
      expect(a.entryOf(b.fingerprint)?.paired, isFalse);
      expect(lock.read(), contains(b.fingerprint));
      await b.until(
        (s) => s.notices.any((n) => n.kind == NoticeKind.unpairedByPeer),
        reason: 'B told even if A could not save',
      );

      await a.inZone(() => a.node.retrySave());
      expect(a.noticesOf(NoticeKind.unpairNotSaved), hasLength(1));
      expect(a.state.unsavedChanges, isTrue);

      lock.release();
      await a.inZone(() => a.node.retrySave());

      expect(a.noticesOf(NoticeKind.unpairNotSaved), isEmpty);
      expect(a.state.unsavedChanges, isFalse);
      expect(await a.savedPairedFingerprints(), isNot(contains(b.fingerprint)));
      expect(a.entryOf(b.fingerprint)?.paired, isFalse);
    }, timeout: twoNodesTimeout);
  });

  group('the other device is off or silent (RF-117)', () {
    test('B shut down: unpair finishes well under the 5 s of the notice, '
        'B is out of memory and of the file, with no notice', () async {
      final (a, b) = await _pairedNodes();
      await b.node.shutdown();

      final watch = Stopwatch()..start();
      await a.inZone(() => a.node.unpair(b.fingerprint));
      watch.stop();

      expect(watch.elapsed, lessThan(const Duration(seconds: 1)));
      expect(a.entryOf(b.fingerprint)?.paired, isFalse);
      expect(await a.savedPairedFingerprints(), isNot(contains(b.fingerprint)));
      expect(a.state.notices, isEmpty);
    }, timeout: twoNodesTimeout);

    test('B replaced by a listener that accepts TCP and never answers: '
        'unpair finishes at once, the single notice attempt is dropped '
        'after about 5 s and is not retried', () async {
      final (a, b) = await _pairedNodes();
      await b.node.shutdown();
      final silent = await SilentListener.bind(hostB, b.port);

      final watch = Stopwatch()..start();
      await a.inZone(() => a.node.unpair(b.fingerprint));
      expect(watch.elapsed, lessThan(const Duration(seconds: 1)));
      expect(a.entryOf(b.fingerprint)?.paired, isFalse);
      expect(await a.savedPairedFingerprints(), isNot(contains(b.fingerprint)));

      await eventually(
        () => silent.closedByClient >= 1,
        limit: const Duration(seconds: 8),
        reason: 'notice attempt given up',
      );
      expect(silent.accepted, 1);
      expect(
        silent.openFor.single.elapsed,
        greaterThan(const Duration(milliseconds: 4500)),
      );
      expect(
        silent.openFor.single.elapsed,
        lessThan(const Duration(milliseconds: 6000)),
      );
      await pause(const Duration(milliseconds: 1500));
      expect(silent.accepted, 1);
      expect(a.state.notices, isEmpty);
    }, timeout: twoNodesTimeout);
  });

  group('the other device unpairs this one (C77, RF-116, RF-119, RF-120)', () {
    test('with paired.json of B locked: B still removes A for the session '
        'and shows unpairedByPeer and changeNotSaved; retrySave after '
        'unlocking clears only the retryable notice', () async {
      final (a, b) = await _pairedNodes();
      final lock = HeldLock.on(b.pairedFile);

      await a.inZone(() => a.node.unpair(b.fingerprint));

      final seen = await b.until(
        (s) =>
            s.notices.any((n) => n.kind == NoticeKind.unpairedByPeer) &&
            s.notices.any((n) => n.kind == NoticeKind.changeNotSaved),
        reason: 'both notices in B',
      );
      expect(seen.notices.map((n) => n.kind), [
        NoticeKind.unpairedByPeer,
        NoticeKind.changeNotSaved,
      ]);
      expect(b.entryOf(a.fingerprint)?.paired, isFalse);
      await b.until((s) => s.unsavedChanges, reason: 'unsavedChanges in B');

      lock.release();
      await b.inZone(() => b.node.retrySave());

      expect(b.state.notices.map((n) => n.kind), [NoticeKind.unpairedByPeer]);
      expect(b.state.unsavedChanges, isFalse);
      expect(await b.savedPairedFingerprints(), isNot(contains(a.fingerprint)));
    }, timeout: twoNodesTimeout);
  });
}
