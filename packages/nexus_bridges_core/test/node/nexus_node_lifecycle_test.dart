import 'dart:io';

import 'package:nexus_bridges_core/src/node/node.dart';
import 'package:nexus_bridges_core/src/pairing_flow/pairing_flow.dart'
    show PairStart;
import 'package:nexus_bridges_core/src/protocol/protocol.dart' show ApiPaths;
import 'package:test/test.dart';

import 'two_nodes_harness.dart';

const Duration _settle = Duration(milliseconds: 500);

bool _finishedWith(NodeState s, PairingOutcome outcome) =>
    s.pairing?.phase == PairingPhase.finished && s.pairing?.outcome == outcome;

Future<void> _expectNothingSaved(TestNode a, TestNode b) async {
  expect(a.hasPaired(b), isFalse);
  expect(b.hasPaired(a), isFalse);
  expect(await a.savedPairedFingerprints(), isEmpty);
  expect(await b.savedPairedFingerprints(), isEmpty);
}

Future<void> _expectNoLiveTimers(TestNode node) async {
  await pause(_settle);
  expect(node.timers.created, greaterThan(0));
  expect(node.timers.active, isEmpty, reason: node.timers.active.join('\n'));
}

void main() {
  group('network change during a pairing at node level (C95, RF-92)', () {
    Future<(TestNode, TestNode)> receiverMoves() async {
      final (a, b) = await twoNodes(pollB: fastPoll);
      await b.inZone(
        () => b.node.decideNetwork(otherNetwork, NetworkDecision.trusted),
      );
      await meet(a, b);
      await bothComparing(a, b);
      return (a, b);
    }

    test('(a) the adapter of the receiver B moves to another trusted network '
        'with the same IP: B ends in networkChanged even though its '
        'interface reopens in the same reconciliation, A stops too and '
        'nothing is saved', () async {
      final (a, b) = await receiverMoves();
      final before = b.logs.length;

      b.adapters = [adapterOn(otherNetwork)];

      await b.until(
        (s) => _finishedWith(s, PairingOutcome.networkChanged),
        reason: 'B networkChanged',
      );
      await a.until(
        (s) => s.pairing?.phase == PairingPhase.finished,
        reason: 'A finished',
      );
      await eventually(
        () => b.logs.skip(before).contains('listening on ${b.ifaceId}'),
        reason: 'B listening again',
      );
      expect(b.state.paused, isFalse);
      a.zone.run(() => a.node.answerCode(matches: true));
      b.zone.run(() => b.node.answerRequest(ReceiverAnswer.matches));
      await pause(_settle);
      expect(b.state.pairing?.outcome, PairingOutcome.networkChanged);
      expect(a.state.pairing?.phase, PairingPhase.finished);
      await _expectNothingSaved(a, b);
    }, timeout: twoNodesTimeout);

    test('(a) plan detail: A learns it from its next poll and ends in '
        'cancelledByPeer', () async {
      final (a, b) = await receiverMoves();

      b.adapters = [adapterOn(otherNetwork)];

      await b.until((s) => _finishedWith(s, PairingOutcome.networkChanged));
      await a.until(
        (s) => s.pairing?.phase == PairingPhase.finished,
        reason: 'A finished',
      );
      expect(a.state.pairing!.outcome, PairingOutcome.cancelledByPeer);
    }, timeout: twoNodesTimeout);

    test('(b) the adapter of the initiator A moves: A ends in networkChanged '
        'and stops, and B ends without saving (cancelledByPeer by the best '
        'effort cancel of the v5 correction)', () async {
      final (a, b) = await twoNodes(pollA: fastPoll);
      await a.inZone(
        () => a.node.decideNetwork(otherNetwork, NetworkDecision.trusted),
      );
      await meet(a, b);
      await bothComparing(a, b);

      a.adapters = [adapterOn(otherNetwork)];

      await a.until(
        (s) => _finishedWith(s, PairingOutcome.networkChanged),
        reason: 'A networkChanged',
      );
      await b.until(
        (s) => _finishedWith(s, PairingOutcome.cancelledByPeer),
        reason: 'B cancelledByPeer',
      );
      await b.until((s) => s.notices.isNotEmpty, reason: 'B notice');
      await pause(_settle);
      expect(b.state.notices.single.kind, NoticeKind.attemptCancelled);
      expect(b.state.notices.single.count, 1);
      expect(b.noticesOf(NoticeKind.attemptLost), isEmpty);
      expect(a.state.pairing?.outcome, PairingOutcome.networkChanged);
      a.zone.run(() => a.node.answerCode(matches: true));
      b.zone.run(() => b.node.answerRequest(ReceiverAnswer.matches));
      await pause(_settle);
      await _expectNothingSaved(a, b);
    }, timeout: twoNodesTimeout);
  });

  group('retry after a failed identity (C104, correction 25)', () {
    test(
      'retry leaves exactly one pairing coordinator, a presentation '
      'reaches it, and after shutdown no timer of the node is alive',
      () async {
        final port = await freePort();
        final a = await TestNode.create('Desk PC', hostA);
        a.port = port;
        final blocked = File('${a.root.path}${sep}blocked');
        await blocked.writeAsString('x');
        a.dataDirOverride = Directory(blocked.path);
        await a.boot();
        expect(a.state.identityStatus, IdentityStatus.failed);
        expect(a.timers.activeBy('pairing_flow.dart'), 0);

        await a.inZone(() => a.node.retry());
        expect(a.state.identityStatus, IdentityStatus.failed);
        expect(a.timers.activeBy('pairing_flow.dart'), 0);

        await blocked.delete();
        final before = a.logs.length;
        await a.inZone(() => a.node.retry());
        expect(a.state.identityStatus, IdentityStatus.ok);
        expect(await a.listenSince(before), isTrue);
        expect(a.timers.activeBy('pairing_flow.dart'), 1);

        await a.inZone(() => a.node.retry());
        expect(a.timers.activeBy('pairing_flow.dart'), 1);

        final b = await TestNode.create('Laptop', hostB);
        b.port = port;
        expect(await b.launch(), isTrue);
        await meet(a, b);
        await bothComparing(b, a);
        expect(a.state.pairing!.role, PairingRole.receiver);
        b.zone.run(() => b.node.cancelPairing());
        await a.until(
          (s) => _finishedWith(s, PairingOutcome.cancelledByPeer),
          reason: 'A cancelledByPeer',
        );

        await a.node.shutdown();
        await b.node.shutdown();

        await _expectNoLiveTimers(a);
        await _expectNoLiveTimers(b);
      },
      timeout: twoNodesTimeout,
    );
  });

  group('ordered shutdown: coordinator before server (plan, "Apagado")', () {
    test('the initiator A shuts down while comparing: B is told and ends '
        'in cancelledByPeer, and no timer of A is left', () async {
      final (a, b) = await twoNodes();
      await meet(a, b);
      await bothComparing(a, b);

      final watch = Stopwatch()..start();
      await a.node.shutdown();
      expect(watch.elapsed, lessThan(const Duration(seconds: 2)));

      await b.until(
        (s) => _finishedWith(s, PairingOutcome.cancelledByPeer),
        limit: const Duration(seconds: 2),
        reason: 'B cancelledByPeer',
      );
      expect(b.hasPaired(a), isFalse);
      await _expectNoLiveTimers(a);
    }, timeout: twoNodesTimeout);

    test('the receiver B shuts down while A polls: the held poll is '
        'answered before the server closes, so A ends in cancelledByPeer '
        'and not in lost, and no timer of B is left', () async {
      final (a, b) = await twoNodes(holdB: const Duration(seconds: 5));
      await meet(a, b);
      await bothComparing(a, b);
      await pause(_settle);

      final watch = Stopwatch()..start();
      await b.node.shutdown();
      expect(watch.elapsed, lessThan(const Duration(seconds: 2)));

      await a.until(
        (s) => s.pairing?.phase == PairingPhase.finished,
        limit: const Duration(seconds: 12),
        reason: 'A finished',
      );
      expect(a.state.pairing!.outcome, PairingOutcome.cancelledByPeer);
      expect(a.hasPaired(b), isFalse);
      await _expectNoLiveTimers(b);
    }, timeout: twoNodesTimeout);
  });

  group('requests only when the user asks (C54 at node level, RF-69, '
      'SEC-15)', () {
    test('a node that sees a peer for more than 15 s through interface '
        'changes, paired changes, checks and ticks never sends a pairing '
        'request on its own', () async {
      late TestNode a;
      CountingPeer? peer;
      for (var attempt = 0; attempt < 5 && peer == null; attempt++) {
        final port = await freePort();
        a = await TestNode.create('Desk PC', hostA);
        a
          ..port = port
          ..pollInterval = fastPoll;
        if (!await a.launch()) {
          await a.node.shutdown();
          continue;
        }
        peer = await CountingPeer.start(address: hostB, port: port);
        if (peer == null) await a.node.shutdown();
      }
      final counting = peer!;
      await a.inZone(
        () => a.node.decideNetwork(otherNetwork, NetworkDecision.trusted),
      );
      bool seesPeer() => a.state.devices.any(
        (d) => d.info.fingerprint == counting.fingerprint,
      );
      Future<void> findPeer() async {
        for (var i = 0; i < 5 && !seesPeer(); i++) {
          await a.inZone(() => a.node.rescan());
          await pause(const Duration(milliseconds: 100));
        }
        await eventually(seesPeer, reason: 'A sees the peer');
      }

      await findPeer();
      final watch = Stopwatch()..start();

      expect(
        counting.coordinator.tryPair(counting.targetOf(a)),
        PairStart.started,
      );
      await a.until((s) => s.pairing?.phase == PairingPhase.comparing);
      await eventually(
        () => counting.coordinator.view?.phase == PairingPhase.comparing,
        reason: 'peer comparing',
      );
      counting.coordinator.answerAsInitiator(matches: true);
      a.zone.run(() => a.node.answerRequest(ReceiverAnswer.matches));
      await a.until(
        (s) => s.entries.any(
          (e) => e.fingerprint == counting.fingerprint && e.paired,
        ),
        reason: 'A paired with the peer',
      );
      await counting.trustSettled();
      await a.inZone(() => a.node.answerMine(counting.fingerprint, mine: true));
      await eventually(
        () => counting.handledOn(ApiPaths.pairStatus) >= 1,
        reason: 'first status check',
      );

      a.adapters = [adapterOn(otherNetwork)];
      await eventually(() => !seesPeer(), reason: 'peer dropped by the move');
      a.adapters = [adapterOn(homeNetwork)];
      await pause();
      await findPeer();

      await a.inZone(() => a.node.setMine(counting.fingerprint, mine: false));
      final checks = counting.handledOn(ApiPaths.pairStatus);
      a.advance(const Duration(minutes: 6));
      await eventually(() => !seesPeer(), reason: 'peer expired');
      await findPeer();
      await eventually(
        () => counting.handledOn(ApiPaths.pairStatus) > checks,
        reason: 'status check after five minutes',
      );

      await a.inZone(() => a.node.unpair(counting.fingerprint));
      await eventually(
        () => counting.handledOn(ApiPaths.unpair) == 1,
        reason: 'unpair notice',
      );
      final remaining = const Duration(seconds: 15) - watch.elapsed;
      if (remaining > Duration.zero) {
        await pause(remaining + const Duration(milliseconds: 100));
      }
      expect(watch.elapsed, greaterThanOrEqualTo(const Duration(seconds: 15)));

      for (final path in [
        ApiPaths.pairStart,
        ApiPaths.pairReveal,
        ApiPaths.pairWait,
        ApiPaths.pairConfirm,
        ApiPaths.pairCancel,
      ]) {
        expect(counting.handledOn(path), 0, reason: path);
      }
      expect(counting.handledOn(ApiPaths.unpair), 1);
    }, timeout: twoNodesTimeout);
  });
}
