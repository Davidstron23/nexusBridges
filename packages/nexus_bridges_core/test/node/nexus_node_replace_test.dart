import 'dart:convert';

import 'package:nexus_bridges_core/src/identity/identity.dart';
import 'package:nexus_bridges_core/src/node/node.dart';
import 'package:nexus_bridges_core/src/pairing/pairing.dart';
import 'package:nexus_bridges_core/src/protocol/protocol.dart' show Limits;
import 'package:test/test.dart';

import 'pairing_nodes_harness.dart';

const Timeout _slow = Timeout(Duration(minutes: 2));
const Duration _tick = Duration(milliseconds: 1500);
const Duration _fastPoll = Duration(milliseconds: 100);
const String _oldName = 'node b';

final class _Trio {
  _Trio(this.a, this.b, this.p, this.oldIdentity, this.start);

  final PairingNode a;
  final PairingNode b;
  final PairingNode p;
  final DeviceIdentity oldIdentity;
  final DateTime start;

  String get old => oldIdentity.fingerprint;

  String get oldLabel => labelOf(_oldName, old);

  String get newLabel => labelOf('Node B', b.fingerprint);

  String? get warning => a.entryOf(b.fingerprint)?.possiblyReplaces;

  ReplaceQuestion get replaceQuestion => ReplaceQuestion(
    fingerprint: b.fingerprint,
    deviceName: newLabel,
    oldFingerprint: old,
    oldName: oldLabel,
  );

  MineQuestion get mineQuestion =>
      MineQuestion(fingerprint: b.fingerprint, deviceName: newLabel);

  List<Notice> get withdrawn => [
    for (final notice in a.state.notices)
      if (notice.kind == NoticeKind.replaceWithdrawn) notice,
  ];

  List<String> savedFingerprints() {
    final json =
        jsonDecode(a.pairedFile.readAsStringSync()) as Map<String, Object?>;
    return [
      for (final device in json['devices'] as List<Object?>)
        (device as Map<String, Object?>)['fingerprint'] as String,
    ];
  }
}

Future<_Trio> _trio({Duration pollA = const Duration(minutes: 1)}) async {
  final port = await freeTcpPort(
    hosts: const ['127.0.0.1', '127.0.0.2', '127.0.0.3'],
  );
  final a = await PairingNode.create('Node A', '127.0.0.1', port: port);
  final b = await PairingNode.create('Node B', '127.0.0.2', port: port);
  final p = await PairingNode.create(_oldName, '127.0.0.3', port: port);
  for (final node in [a, b, p]) {
    node.prefixLength = 29;
  }
  final own = await a.loadIdentity();
  final old = await p.loadIdentity();
  await a.writePaired(own.fingerprint, [
    pairedEntryFor(
      old,
      name: _oldName,
      relation: PeerRelation.mine,
      pairedAt: DateTime.utc(2026, 9, 1),
    ),
  ]);
  final start = a.clock;
  await startTogether(
    [a, b],
    start: (node) =>
        identical(node, a) ? node.start(pollInterval: pollA) : node.start(),
    later: [p],
  );
  await meet(a, b);
  return _Trio(a, b, p, old, start);
}

Future<void> _warned(_Trio t) => t.a.until(
  (s) => t.warning == t.oldLabel,
  reason: 'possible reinstall warning on the row of B',
);

Future<void> _askedToReplace(_Trio t) async {
  t.a.clock = t.start.add(Limits.replaceAfterAbsence);
  await _warned(t);
  await pairUp(t.a, t.b);
  await t.a.until(
    (s) => s.questions.length == 2,
    reason: 'replace and mine questions',
  );
  expect(t.a.state.questions, [t.replaceQuestion, t.mineQuestion]);
}

Future<void> _seeP(_Trio t) async {
  await t.p.start();
  await meet(t.a, t.p);
}

Future<void> _pLeaves(_Trio t) async {
  await t.p.node.shutdown();
  await sayByeAs(t.p, t.a, fingerprint: t.old);
  await t.a.until(
    (s) => t.a.entryOf(t.old)?.visible == false,
    limit: const Duration(seconds: 10),
    reason: 'P out of sight after its goodbye',
  );
}

Future<void> _pauseAndResume(PairingNode node) async {
  node.adapters = const [];
  await node.until((s) => s.paused, reason: '${node.name} paused');
  node.adapters = [wifiAdapter()];
  await node.until((s) => !s.paused, reason: '${node.name} listening again');
}

void main() {
  group('C126, RF-124, RF-125: two minutes out of sight (N2)', () {
    test('(a) the row of B has no warning at 1:59 after discovery started '
        'and gets it at 2:00 with the next tick, without any change in the '
        'list', () async {
      final t = await _trio();
      expect(t.warning, isNull);

      t.a.clock = t.start.add(
        Limits.replaceAfterAbsence - const Duration(seconds: 1),
      );
      await Future<void>.delayed(_tick);
      expect(t.warning, isNull);
      final devices = t.a.state.devices.length;

      t.a.clock = t.start.add(Limits.replaceAfterAbsence);
      await _warned(t);

      expect(t.a.state.devices, hasLength(devices));
      final stale = t.a.entryOf(t.old)!;
      expect(stale.visible, isFalse);
      expect(stale.paired, isTrue);
      expect(t.a.entryOf(t.b.fingerprint)!.paired, isFalse);
    }, timeout: _slow);

    test('(b) pairing B one minute after discovery started asks only "is it '
        'yours?"', () async {
      final t = await _trio();
      t.a.clock = t.start.add(const Duration(minutes: 1));

      await pairUp(t.a, t.b);
      await t.a.until((s) => s.questions.isNotEmpty);
      await Future<void>.delayed(const Duration(milliseconds: 300));

      expect(t.a.state.questions, [t.mineQuestion]);
      expect(t.a.entryOf(t.old)!.paired, isTrue);
    }, timeout: _slow);

    test('(c) pairing B two minutes after discovery started asks "replace?" '
        'before "is it yours?"', () async {
      final t = await _trio();

      await _askedToReplace(t);

      expect(t.a.entryOf(t.old)!.paired, isTrue);
    }, timeout: _slow);

    test('(d) after A loses its interface and gets it back, the warning '
        'goes away and only comes back 2 minutes later', () async {
      final t = await _trio(pollA: _fastPoll);
      t.a.clock = t.start.add(Limits.replaceAfterAbsence);
      await _warned(t);

      await _pauseAndResume(t.a);
      final back = t.a.clock;
      await meet(t.a, t.b);
      await Future<void>.delayed(_tick);
      expect(t.warning, isNull);

      t.a.clock = back.add(
        Limits.replaceAfterAbsence - const Duration(seconds: 1),
      );
      await Future<void>.delayed(_tick);
      expect(t.warning, isNull);
      t.a.clock = back.add(Limits.replaceAfterAbsence);
      await _warned(t);
    }, timeout: _slow);
  });

  group('C127, RF-125, RF-126: the old device shows up again (N2, R57)', () {
    test('(a) P is seen again while the question is open: the question is '
        'withdrawn with a notice, P stays paired and "is it yours?" for B '
        'stays', () async {
      final t = await _trio();
      await _askedToReplace(t);

      await _seeP(t);

      await t.a.until(
        (s) => s.questions.length == 1,
        reason: 'replace question withdrawn',
      );
      expect(t.a.state.questions, [t.mineQuestion]);
      expect(t.withdrawn, hasLength(1));
      expect(t.withdrawn.single.deviceName, t.oldLabel);
      expect(t.withdrawn.single.canRetry, isFalse);
      expect(t.a.entryOf(t.old)!.paired, isTrue);
      expect(t.a.entryOf(t.old)!.visible, isTrue);
      expect(t.savedFingerprints(), containsAll([t.old, t.b.fingerprint]));

      await t.a.node.answerReplace(t.b.fingerprint, replace: true);
      expect(t.a.entryOf(t.old)!.paired, isTrue);
      expect(t.withdrawn, hasLength(1));
    }, timeout: _slow);

    test('(b) P is seen and leaves before the answer: answering "replace" '
        'afterwards keeps P paired with a single notice', () async {
      final t = await _trio();
      await _askedToReplace(t);
      await _seeP(t);
      await t.a.until((s) => s.questions.length == 1);

      await _pLeaves(t);
      await t.a.node.answerReplace(t.b.fingerprint, replace: true);

      expect(t.a.entryOf(t.old)!.paired, isTrue);
      expect(t.savedFingerprints(), contains(t.old));
      expect(t.withdrawn, hasLength(1));
      expect(t.a.state.questions, [t.mineQuestion]);
    }, timeout: _slow);

    test('(b) the answer is checked again: P seen less than 2 minutes before '
        'the answer is not unpaired, even though the question is still '
        'open', () async {
      final t = await _trio();
      await _seeP(t);
      expect(t.a.entryOf(t.old)!.visible, isTrue);
      await _pLeaves(t);
      await _askedToReplace(t);

      t.a.clock = t.start.add(const Duration(minutes: 1));
      await t.a.node.answerReplace(t.b.fingerprint, replace: true);

      expect(t.a.entryOf(t.old)!.paired, isTrue);
      expect(t.savedFingerprints(), contains(t.old));
      expect(t.withdrawn.single.deviceName, t.oldLabel);
      expect(t.a.state.questions, [t.mineQuestion]);
    }, timeout: _slow);

    test('(c) P is still out of sight and A answers "replace": P is unpaired '
        'in memory and in the file, as before', () async {
      final t = await _trio();
      await _askedToReplace(t);

      await t.a.node.answerReplace(t.b.fingerprint, replace: true);

      expect(t.a.entryOf(t.old), isNull);
      expect(t.savedFingerprints(), isNot(contains(t.old)));
      expect(t.savedFingerprints(), contains(t.b.fingerprint));
      expect(t.withdrawn, isEmpty);
      expect(t.a.state.questions, [t.mineQuestion]);
    }, timeout: _slow);

    test('(d) a network pause of A without seeing P withdraws nothing, and '
        'answering "replace" afterwards unpairs P', () async {
      final t = await _trio(pollA: _fastPoll);
      await _askedToReplace(t);

      await _pauseAndResume(t.a);
      await Future<void>.delayed(_tick);
      expect(t.a.state.questions, [t.replaceQuestion, t.mineQuestion]);
      expect(t.withdrawn, isEmpty);

      await t.a.node.answerReplace(t.b.fingerprint, replace: true);

      expect(t.a.entryOf(t.old), isNull);
      expect(t.savedFingerprints(), isNot(contains(t.old)));
      expect(t.withdrawn, isEmpty);
    }, timeout: _slow);
  });
}
