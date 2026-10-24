import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:nexus_bridges_core/src/identity/identity.dart';
import 'package:nexus_bridges_core/src/node/node.dart';
import 'package:nexus_bridges_core/src/pairing/pairing.dart';
import 'package:nexus_bridges_core/src/pairing_flow/crypto.dart';
import 'package:nexus_bridges_core/src/pairing_flow/messages.dart';
import 'package:nexus_bridges_core/src/protocol/protocol.dart'
    show ApiPaths, DeviceType, Limits;
import 'package:nexus_bridges_core/src/transport/transport.dart';
import 'package:test/test.dart';

import '../server/api_server_harness.dart' show anonymousContext;
import 'pairing_nodes_harness.dart';

const Timeout _slow = Timeout(Duration(minutes: 2));
const Duration _failedWrite = Duration(seconds: 10);

Map<String, Object?> _savedDevice(File file, String fingerprint) {
  final json = jsonDecode(file.readAsStringSync()) as Map<String, Object?>;
  final devices = (json['devices'] as List<Object?>)
      .cast<Map<String, Object?>>();
  return devices.singleWhere((d) => d['fingerprint'] == fingerprint);
}

List<String> _savedFingerprints(File file) {
  if (!file.existsSync()) return const [];
  final json = jsonDecode(file.readAsStringSync()) as Map<String, Object?>;
  return [
    for (final d in (json['devices'] as List<Object?>))
      (d as Map<String, Object?>)['fingerprint'] as String,
  ];
}

List<NoticeKind> _kinds(NodeState s) => [for (final n in s.notices) n.kind];

final class _RawInitiator {
  _RawInitiator(this.target);

  final PairingNode target;
  final DeviceIdentity identity = DeviceIdentity.generate();
  final Uint8List nonce = randomBytes(nonceLength);
  Uint8List? _startTranscript;
  Uint8List? _session;
  Uint8List? _receiverCommitment;

  Future<int?> start() async {
    final commitment = commitmentOf(
      role: PairingRole.initiator,
      fingerprint: identity.fingerprint,
      nonce: nonce,
    );
    final transcript = startTranscript(
      initiatorFingerprint: identity.fingerprint,
      receiverFingerprint: target.fingerprint,
      name: 'Laptop',
      deviceType: DeviceType.desktop,
      initiatorCommitment: commitment,
    );
    _startTranscript = transcript;
    final reply = await _post(
      ApiPaths.pairStart,
      StartRequest(
        certificate: identity.certificatePem,
        name: 'Laptop',
        deviceType: DeviceType.desktop,
        commitment: commitment,
        proof: identity.sign(transcript),
      ).toJson(),
    );
    if (reply != null && reply.status == 200) {
      final parsed = StartReply.tryParse(
        jsonDecode(utf8.decode(reply.body)) as Map<String, Object?>,
      );
      _session = parsed?.session;
      _receiverCommitment = parsed?.commitment;
    }
    return reply?.status;
  }

  Future<int?> revealAnotherNumber() async {
    final other = randomBytes(nonceLength);
    final reply = await _post(
      ApiPaths.pairReveal,
      RevealRequest(
        session: _session!,
        nonce: other,
        signature: identity.sign(
          revealTranscript(
            startTranscript: _startTranscript!,
            sessionId: _session!,
            receiverCommitment: _receiverCommitment!,
            initiatorNonce: other,
          ),
        ),
      ).toJson(),
    );
    return reply?.status;
  }

  Future<HttpsResponse?> _post(String path, Object? json) => postJson(
    address: target.internetAddress,
    port: target.port,
    path: path,
    json: json,
    context: anonymousContext,
    acceptServer: (certificate) {
      try {
        return fingerprintOfCertificate(certificate.der) == target.fingerprint;
      } on FormatException {
        return false;
      }
    },
    sourceAddress: InternetAddress('127.0.0.1'),
    maxResponseBytes: Limits.maxPairingBodyBytes,
  );
}

Future<(PairingNode, DeviceIdentity)> _nodeWithSpare() async {
  final port = await freeTcpPort();
  final a = await PairingNode.create('Node A', '127.0.0.1', port: port);
  final own = await a.loadIdentity();
  final spare = DeviceIdentity.generate();
  await a.writePaired(own.fingerprint, [
    pairedEntryFor(spare, name: 'Spare PC'),
  ]);
  await a.start();
  return (a, spare);
}

void main() {
  group('C79, RF-68, RF-72, RF-73, RF-83, RF-87, RF-88, RF-97, RF-98: end to '
      'end through the facade', () {
    test('A pairs with B: B compares within 2 s with the same code, nothing is '
        'saved until both confirm, then both are paired as foreign and both '
        'get the "is it yours?" question', () async {
      final (a, b) = await twoPairingNodes();
      final row = a.entryOf(b.fingerprint)!;
      expect(row.canPair, isTrue);
      expect(row.paired, isFalse);
      expect(a.state.pairing, isNull);
      expect(b.state.pairing, isNull);

      final watch = Stopwatch()..start();
      expect(await a.node.pair(b.fingerprint), PairRequestResult.started);
      await b.until(
        (s) => s.pairing?.phase == PairingPhase.comparing,
        limit: const Duration(seconds: 2),
        reason: 'B comparing within 2 s',
      );
      watch.stop();
      await a.until((s) => s.pairing?.phase == PairingPhase.comparing);

      expect(watch.elapsed, lessThan(const Duration(seconds: 2)));
      final initiator = a.state.pairing!;
      final receiver = b.state.pairing!;
      expect(initiator.role, PairingRole.initiator);
      expect(initiator.peerFingerprint, b.fingerprint);
      expect(initiator.peerName, 'Node B');
      expect(receiver.role, PairingRole.receiver);
      expect(receiver.peerFingerprint, a.fingerprint);
      expect(receiver.peerName, 'Node A');
      expect(receiver.alreadyPaired, isFalse);
      expect(initiator.code, matches(RegExp(r'^\d{6}$')));
      expect(receiver.code, initiator.code);

      a.node.answerCode(matches: true);
      await a.until((s) => s.pairing?.phase == PairingPhase.waitingPeer);
      await Future<void>.delayed(const Duration(milliseconds: 300));

      expect(a.hasPaired(b), isFalse);
      expect(b.hasPaired(a), isFalse);
      expect(_savedFingerprints(a.pairedFile), isEmpty);
      expect(_savedFingerprints(b.pairedFile), isEmpty);
      expect(b.state.pairing?.phase, PairingPhase.comparing);

      b.node.answerRequest(ReceiverAnswer.matches);
      await eventually(() => a.hasPaired(b) && b.hasPaired(a));
      await eventually(
        () => a.state.pairing == null && b.state.pairing == null,
      );

      final rowInA = a.entryOf(b.fingerprint)!;
      expect(rowInA.paired, isTrue);
      expect(rowInA.mine, isFalse);
      expect(rowInA.visible, isTrue);
      expect(b.entryOf(a.fingerprint)!.mine, isFalse);
      expect(_savedDevice(a.pairedFile, b.fingerprint)['relation'], 'foreign');
      expect(_savedDevice(b.pairedFile, a.fingerprint)['relation'], 'foreign');
      await a.until((s) => s.questions.isNotEmpty);
      await b.until((s) => s.questions.isNotEmpty);
      expect(a.state.questions, [
        MineQuestion(
          fingerprint: b.fingerprint,
          deviceName: labelOf('Node B', b.fingerprint),
        ),
      ]);
      expect(b.state.questions, [
        MineQuestion(
          fingerprint: a.fingerprint,
          deviceName: labelOf('Node A', a.fingerprint),
        ),
      ]);
      expect(a.state.notices, isEmpty);
      expect(b.state.notices, isEmpty);
    }, timeout: _slow);

    test('the receiver may confirm first: the initiator still decides when '
        'it confirms', () async {
      final (a, b) = await twoPairingNodes();
      expect(await a.node.pair(b.fingerprint), PairRequestResult.started);
      await bothComparing(a, b);

      b.node.answerRequest(ReceiverAnswer.matches);
      await b.until((s) => s.pairing?.phase == PairingPhase.waitingPeer);
      await Future<void>.delayed(const Duration(milliseconds: 300));

      expect(a.state.pairing?.phase, PairingPhase.comparing);
      expect(a.hasPaired(b), isFalse);
      expect(b.hasPaired(a), isFalse);

      a.node.answerCode(matches: true);
      await eventually(() => a.hasPaired(b) && b.hasPaired(a));
    }, timeout: _slow);
  });

  group('C73, RF-99, RF-100, RF-85: the "is it yours?" answers', () {
    test('answerMine(true) saves mine and shows it; answerMine(false) keeps '
        'foreign; both remove only their own question', () async {
      final (a, b) = await twoPairingNodes();
      await pairUp(a, b);
      await a.until((s) => s.questions.isNotEmpty);
      await b.until((s) => s.questions.isNotEmpty);

      await a.node.answerMine(b.fingerprint, mine: true);

      expect(a.state.questions, isEmpty);
      expect(a.entryOf(b.fingerprint)!.mine, isTrue);
      expect(_savedDevice(a.pairedFile, b.fingerprint)['relation'], 'mine');
      expect(a.state.notices, isEmpty);

      await b.node.answerMine(a.fingerprint, mine: false);

      expect(b.state.questions, isEmpty);
      expect(b.entryOf(a.fingerprint)!.mine, isFalse);
      expect(_savedDevice(b.pairedFile, a.fingerprint)['relation'], 'foreign');
    }, timeout: _slow);

    test('answering about a device that is not asked about and not paired '
        'changes nothing', () async {
      final (a, b) = await twoPairingNodes();

      await a.node.answerMine(b.fingerprint, mine: true);
      await a.node.answerMine('F' * 64, mine: true);

      expect(a.state.questions, isEmpty);
      expect(a.entryOf(b.fingerprint)!.paired, isFalse);
      expect(a.entryOf(b.fingerprint)!.mine, isFalse);
      expect(a.state.notices, isEmpty);
      expect(a.pairedFile.existsSync(), isFalse);
    }, timeout: _slow);

    test(
      'pairing again with a device that is already paired asks nothing on '
      'that side, keeps its relation and leaves a finished view that '
      'dismissPairing closes; the side that forgot gets the question',
      () async {
        final (a, b) = await twoPairingNodes();
        await pairUp(a, b);
        await a.node.answerMine(b.fingerprint, mine: true);
        await b.node.answerMine(a.fingerprint, mine: false);

        await b.node.shutdown();
        await b.pairedFile.delete();
        await b.start();
        await meet(a, b);
        expect(b.entryOf(a.fingerprint)!.paired, isFalse);
        expect(a.entryOf(b.fingerprint)!.paired, isTrue);

        expect(await b.node.pair(a.fingerprint), PairRequestResult.started);
        await bothComparing(b, a);
        expect(a.state.pairing!.alreadyPaired, isTrue);
        expect(a.state.pairing!.role, PairingRole.receiver);

        a.node.answerRequest(ReceiverAnswer.matches);
        b.node.answerCode(matches: true);
        await eventually(() => b.hasPaired(a));
        final finished = await a.until(
          (s) => s.pairing?.phase == PairingPhase.finished,
        );

        expect(finished.pairing!.outcome, PairingOutcome.paired);
        await b.until((s) => s.questions.isNotEmpty);
        expect(b.state.questions, [
          MineQuestion(
            fingerprint: a.fingerprint,
            deviceName: labelOf('Node A', a.fingerprint),
          ),
        ]);
        await Future<void>.delayed(const Duration(milliseconds: 300));
        expect(a.state.questions, isEmpty);
        expect(a.entryOf(b.fingerprint)!.mine, isTrue);
        expect(_savedFingerprints(a.pairedFile), [b.fingerprint]);

        a.node.dismissPairing();
        await a.until((s) => s.pairing == null);
      },
      timeout: _slow,
    );
  });

  group('C74 (questions), RF-124, RF-125: a newcomer with the name of a '
      'paired device out of sight', () {
    test('the row warns before pairing, and after pairing the replace '
        'question comes before the "is it yours?" question', () async {
      late DeviceIdentity old;
      final (a, b) = await twoPairingNodes(
        before: (a, b) async {
          final own = await a.loadIdentity();
          old = DeviceIdentity.generate();
          await a.writePaired(own.fingerprint, [
            pairedEntryFor(
              old,
              name: 'node b',
              relation: PeerRelation.mine,
              pairedAt: DateTime.utc(2026, 9, 1),
            ),
          ]);
        },
      );

      final oldLabel = labelOf('node b', old.fingerprint);
      final newcomer = a.entryOf(b.fingerprint)!;
      expect(newcomer.possiblyReplaces, oldLabel);
      expect(newcomer.displayName, labelOf('Node B', b.fingerprint));
      expect(newcomer.paired, isFalse);
      final stale = a.entryOf(old.fingerprint)!;
      expect(stale.visible, isFalse);
      expect(stale.paired, isTrue);
      expect(stale.mine, isTrue);
      expect(stale.displayName, oldLabel);

      await pairUp(a, b);
      await a.until((s) => s.questions.length == 2);

      final label = labelOf('Node B', b.fingerprint);
      expect(a.state.questions, [
        ReplaceQuestion(
          fingerprint: b.fingerprint,
          deviceName: label,
          oldFingerprint: old.fingerprint,
          oldName: oldLabel,
        ),
        MineQuestion(fingerprint: b.fingerprint, deviceName: label),
      ]);
      await b.until((s) => s.questions.isNotEmpty);
      expect(b.state.questions.single, isA<MineQuestion>());
      expect(a.entryOf(old.fingerprint)!.paired, isTrue);

      await a.node.answerMine(b.fingerprint, mine: false);

      expect(a.state.questions, [
        ReplaceQuestion(
          fingerprint: b.fingerprint,
          deviceName: label,
          oldFingerprint: old.fingerprint,
          oldName: oldLabel,
        ),
      ]);
    }, timeout: _slow);
  });

  group('RF-67, RF-70, RF-71, C55, C72: what pair answers', () {
    test('a second pair while one is running gives alreadyInProgress, also '
        'from the receiver side, and the view does not change', () async {
      final (a, b) = await twoPairingNodes();

      expect(await a.node.pair(b.fingerprint), PairRequestResult.started);
      expect(
        await a.node.pair(b.fingerprint),
        PairRequestResult.alreadyInProgress,
      );
      await bothComparing(a, b);
      final viewOfA = a.state.pairing;
      final viewOfB = b.state.pairing;

      expect(
        await a.node.pair(b.fingerprint),
        PairRequestResult.alreadyInProgress,
      );
      expect(
        await b.node.pair(a.fingerprint),
        PairRequestResult.alreadyInProgress,
      );
      expect(a.state.pairing, viewOfA);
      expect(b.state.pairing, viewOfB);
    }, timeout: _slow);

    test(
      'an unknown fingerprint, its own fingerprint and an already paired '
      'device without a mismatch give unavailable and start nothing',
      () async {
        final (a, b) = await twoPairingNodes();

        expect(await a.node.pair('F' * 64), PairRequestResult.unavailable);
        expect(await a.node.pair(a.fingerprint), PairRequestResult.unavailable);
        expect(a.state.pairing, isNull);

        await pairUp(a, b);
        expect(a.entryOf(b.fingerprint)!.mismatch, isFalse);

        expect(await a.node.pair(b.fingerprint), PairRequestResult.unavailable);
        await Future<void>.delayed(const Duration(milliseconds: 200));
        expect(a.state.pairing, isNull);
        expect(b.state.pairing, isNull);
      },
      timeout: _slow,
    );

    test(
      'with 32 paired devices, pairing a new one gives tooManyPaired and '
      'nothing reaches the other device; the rows show all of them',
      () async {
        final fakes = [
          for (var i = 0; i < PairedDevicesStore.maxDevices; i++)
            DeviceIdentity.generate(),
        ];
        final (a, b) = await twoPairingNodes(
          before: (a, b) async {
            final own = await a.loadIdentity();
            await a.writePaired(own.fingerprint, [
              for (var i = 0; i < fakes.length; i++)
                pairedEntryFor(fakes[i], name: 'Spare $i'),
            ]);
          },
        );

        expect(a.state.entries, hasLength(33));
        expect(
          await a.node.pair(b.fingerprint),
          PairRequestResult.tooManyPaired,
        );
        await Future<void>.delayed(const Duration(milliseconds: 300));
        expect(a.state.pairing, isNull);
        expect(b.state.pairing, isNull);
        expect(b.state.notices, isEmpty);
      },
      timeout: _slow,
    );

    test('with 32 paired devices where the other one is among them: '
        'unavailable while it has no mismatch mark, started once it is marked '
        '(the other side does not have us)', () async {
      final fakes = [
        for (var i = 0; i < PairedDevicesStore.maxDevices - 1; i++)
          DeviceIdentity.generate(),
      ];
      final (a, b) = await twoPairingNodes(
        before: (a, b) async {
          final own = await a.loadIdentity();
          final other = await b.loadIdentity();
          await a.writePaired(own.fingerprint, [
            for (var i = 0; i < fakes.length; i++)
              pairedEntryFor(fakes[i], name: 'Spare $i'),
            pairedEntryFor(other, name: 'Node B'),
          ]);
        },
      );

      final row = a.entryOf(b.fingerprint)!;
      expect(row.paired, isTrue);
      if (!row.mismatch) {
        expect(await a.node.pair(b.fingerprint), PairRequestResult.unavailable);
      }

      await a.until((s) => a.entryOf(b.fingerprint)?.mismatch == true);

      expect(a.entryOf(b.fingerprint)!.canPair, isTrue);
      expect(await a.node.pair(b.fingerprint), PairRequestResult.started);
      await b.until((s) => s.pairing?.phase == PairingPhase.comparing);
      a.node.cancelPairing();
      await a.until((s) => s.pairing == null);
    }, timeout: _slow);
  });

  group('RF-79 (v6): cancelling after the code was shown', () {
    test('the initiator says "no match": its view closes, the receiver ends '
        'in cancelledByPeer with an attemptCancelled notice that only shows '
        'the 8 characters, and dismissPairing closes its view', () async {
      final (a, b) = await twoPairingNodes();
      expect(await a.node.pair(b.fingerprint), PairRequestResult.started);
      await bothComparing(a, b);

      a.node.answerCode(matches: false);

      await a.until((s) => s.pairing == null);
      final ended = await b.until(
        (s) => s.pairing?.phase == PairingPhase.finished,
      );
      expect(ended.pairing!.outcome, PairingOutcome.cancelledByPeer);
      await b.until((s) => s.notices.isNotEmpty);
      expect(b.state.notices.single.kind, NoticeKind.attemptCancelled);
      expect(b.state.notices.single.count, 1);
      expect(b.state.notices.single.deviceName, shortOf(a.fingerprint));
      expect(b.state.notices.single.canRetry, isFalse);
      expect(a.state.notices, isEmpty);
      expect(a.hasPaired(b), isFalse);
      expect(b.hasPaired(a), isFalse);

      b.node.dismissPairing();
      await b.until((s) => s.pairing == null);
      expect(b.state.notices, hasLength(1));
    }, timeout: _slow);

    test('cancelPairing in comparing does the same', () async {
      final (a, b) = await twoPairingNodes();
      expect(await a.node.pair(b.fingerprint), PairRequestResult.started);
      await bothComparing(a, b);

      a.node.cancelPairing();

      await a.until((s) => s.pairing == null);
      await b.until((s) => s.notices.isNotEmpty);
      expect(b.state.notices.single.kind, NoticeKind.attemptCancelled);
      expect(b.state.notices.single.count, 1);
      expect(b.state.notices.single.deviceName, shortOf(a.fingerprint));
      expect(b.state.pairing?.outcome, PairingOutcome.cancelledByPeer);
    }, timeout: _slow);
  });

  group('C113, RF-79, RF-106b: notices by cause', () {
    test('(b) a presentation from a fresh identity whose revealed number does '
        'not match its commitment leaves one attemptDataMismatch notice with '
        'count 1 and only the 8 characters, and no view', () async {
      final (a, b) = await twoPairingNodes();
      final raw = _RawInitiator(b);

      expect(await raw.start(), 200);
      expect(await raw.revealAnotherNumber(), 403);

      await b.until((s) => s.notices.isNotEmpty);
      final notice = b.state.notices.single;
      expect(notice.kind, NoticeKind.attemptDataMismatch);
      expect(notice.count, 1);
      expect(notice.deviceName, shortOf(raw.identity.fingerprint));
      expect(notice.deviceName, isNot(contains('Laptop')));
      expect(notice.canRetry, isFalse);
      expect(b.state.pairing, isNull);
      expect(a.state.notices, isEmpty);
    }, timeout: _slow);

    test('(c) a data mismatch and then a cancel after the reveal within 10 '
        'minutes make one attemptCancelled notice with count 2 and the id '
        'of the first', () async {
      final (a, b) = await twoPairingNodes();
      final raw = _RawInitiator(b);
      expect(await raw.start(), 200);
      expect(await raw.revealAnotherNumber(), 403);
      final first = (await b.until((s) => s.notices.isNotEmpty)).notices.single;
      expect(first.kind, NoticeKind.attemptDataMismatch);

      b.clock = b.clock.add(const Duration(minutes: 9, seconds: 59));
      expect(await a.node.pair(b.fingerprint), PairRequestResult.started);
      await bothComparing(a, b);
      a.node.cancelPairing();

      await b.until((s) => s.notices.single.count == 2);
      final merged = b.state.notices.single;
      expect(merged.id, first.id);
      expect(merged.kind, NoticeKind.attemptCancelled);
      expect(merged.deviceName, shortOf(a.fingerprint));
      b.node.dismissPairing();
    }, timeout: _slow);
  });

  group('C116, RF-106b: the accumulated notice expires 10 minutes after the '
      'last attempt', () {
    test('cancels after the reveal at t0, t0+10:00 and t0+19:59', () async {
      final (a, b) = await twoPairingNodes();
      final t0 = b.clock;

      Future<Notice> cancelAfterReveal(bool Function(Notice n) ready) async {
        expect(await a.node.pair(b.fingerprint), PairRequestResult.started);
        await bothComparing(a, b);
        a.node.cancelPairing();
        await a.until((s) => s.pairing == null);
        await b.until(
          (s) =>
              s.pairing?.outcome == PairingOutcome.cancelledByPeer &&
              s.notices.length == 1 &&
              ready(s.notices.single),
          reason: 'B notice after the cancel',
        );
        b.node.dismissPairing();
        await b.until((s) => s.pairing == null);
        return b.state.notices.single;
      }

      final first = await cancelAfterReveal((_) => true);
      expect(first.kind, NoticeKind.attemptCancelled);
      expect(first.count, 1);

      b.clock = t0.add(const Duration(minutes: 10));
      final second = await cancelAfterReveal((n) => n.id != first.id);
      expect(second.kind, NoticeKind.attemptCancelled);
      expect(second.count, 1);
      expect(b.state.notices.where((n) => n.id == first.id), isEmpty);

      b.clock = t0.add(const Duration(minutes: 19, seconds: 59));
      final third = await cancelAfterReveal((n) => n.count == 2);
      expect(third.kind, NoticeKind.attemptCancelled);
      expect(third.count, 2);
      expect(third.id, second.id);
      expect(third.deviceName, shortOf(a.fingerprint));
    }, timeout: _slow);
  });

  group('RF-108, RF-109, RF-121, C69, C78: ignoring and unignoring', () {
    test(
      '"ignore" marks the initiator as ignored in the receiver rows, it '
      'cannot be paired from there, and unignore brings the button back',
      () async {
        final (a, b) = await twoPairingNodes();
        expect(await a.node.pair(b.fingerprint), PairRequestResult.started);
        await bothComparing(a, b);

        b.node.answerRequest(ReceiverAnswer.ignore);

        final ignored = await b.until(
          (s) =>
              s.entries.any((e) => e.fingerprint == a.fingerprint && e.ignored),
        );
        expect(ignored.pairing, isNull);
        final row = b.entryOf(a.fingerprint)!;
        expect(row.canPair, isFalse);
        expect(row.paired, isFalse);
        final initiatorEnd = await a.until(
          (s) => s.pairing?.phase == PairingPhase.finished,
        );
        expect(initiatorEnd.pairing!.outcome, PairingOutcome.cancelledByPeer);
        expect(await b.node.pair(a.fingerprint), PairRequestResult.unavailable);
        await eventually(() => b.ignoredFile.existsSync());
        expect(b.ignoredFile.readAsStringSync(), contains(a.fingerprint));
        expect(b.state.notices, isEmpty);

        await b.node.unignore(a.fingerprint);

        expect(b.entryOf(a.fingerprint)!.ignored, isFalse);
        expect(b.entryOf(a.fingerprint)!.canPair, isTrue);
        expect(
          b.ignoredFile.readAsStringSync(),
          isNot(contains(a.fingerprint)),
        );
        expect(b.state.notices, isEmpty);
        expect(b.state.unsavedChanges, isFalse);
      },
      timeout: _slow,
    );

    test(
      'with ignored.json not writable: ignored for the session, an '
      'ignoreNotSaved notice with the formatted name and unsaved changes; '
      'retrySave once it is writable clears the retryable notices only',
      () async {
        final (a, b) = await twoPairingNodes();
        breakFile(b.ignoredFile);
        expect(await a.node.pair(b.fingerprint), PairRequestResult.started);
        await bothComparing(a, b);

        b.node.answerRequest(ReceiverAnswer.ignore);

        await b.until((s) => s.notices.isNotEmpty, limit: _failedWrite);
        expect(b.state.notices.single.kind, NoticeKind.ignoreNotSaved);
        expect(
          b.state.notices.single.deviceName,
          labelOf('Node A', a.fingerprint),
        );
        expect(b.state.notices.single.canRetry, isFalse);
        expect(b.entryOf(a.fingerprint)!.ignored, isTrue);
        await b.until((s) => s.unsavedChanges);
        await eventually(() => b.states.any((s) => s.unsavedChanges));

        await b.node.unignore(a.fingerprint);

        expect(b.entryOf(a.fingerprint)!.ignored, isFalse);
        expect(_kinds(b.state), [
          NoticeKind.ignoreNotSaved,
          NoticeKind.changeNotSaved,
        ]);
        expect(b.state.notices.last.canRetry, isTrue);
        expect(b.state.unsavedChanges, isTrue);

        await b.node.retrySave();

        expect(_kinds(b.state), [
          NoticeKind.ignoreNotSaved,
          NoticeKind.changeNotSaved,
        ]);
        expect(b.state.unsavedChanges, isTrue);

        repairFile(b.ignoredFile);
        await b.node.retrySave();

        expect(_kinds(b.state), [NoticeKind.ignoreNotSaved]);
        expect(b.state.unsavedChanges, isFalse);
        expect(
          b.ignoredFile.readAsStringSync(),
          isNot(contains(a.fingerprint)),
        );
      },
      timeout: _slow,
    );
  });

  group('v5 Q-9, v6 point 3: a result of the user that is not lost', () {
    test('the initiator cannot save: notice pairingNotSaved with the '
        'formatted name; the receiver did save (R23)', () async {
      final (a, b) = await twoPairingNodes();
      breakFile(a.pairedFile);
      expect(await a.node.pair(b.fingerprint), PairRequestResult.started);
      await bothComparing(a, b);

      a.node.answerCode(matches: true);
      b.node.answerRequest(ReceiverAnswer.matches);

      final ended = await a.until(
        (s) => s.pairing?.phase == PairingPhase.finished,
        limit: _failedWrite,
      );
      expect(ended.pairing!.outcome, PairingOutcome.notSaved);
      await a.until((s) => s.notices.isNotEmpty);
      expect(a.state.notices.single.kind, NoticeKind.pairingNotSaved);
      expect(
        a.state.notices.single.deviceName,
        labelOf('Node B', b.fingerprint),
      );
      expect(a.hasPaired(b), isFalse);
      expect(a.state.questions, isEmpty);
      await eventually(() => b.hasPaired(a));
    }, timeout: _slow);

    test('the receiver cannot save: notice pairingNotSaved in the receiver '
        'and the initiator saves nothing', () async {
      final (a, b) = await twoPairingNodes();
      breakFile(b.pairedFile);
      expect(await a.node.pair(b.fingerprint), PairRequestResult.started);
      await bothComparing(a, b);

      a.node.answerCode(matches: true);
      b.node.answerRequest(ReceiverAnswer.matches);

      await b.until((s) => s.notices.isNotEmpty, limit: _failedWrite);
      expect(b.state.notices.single.kind, NoticeKind.pairingNotSaved);
      expect(
        b.state.notices.single.deviceName,
        labelOf('Node A', a.fingerprint),
      );
      final initiatorEnd = await a.until(
        (s) => s.pairing?.phase == PairingPhase.finished,
      );
      expect(initiatorEnd.pairing!.outcome, PairingOutcome.cancelledByPeer);
      expect(a.hasPaired(b), isFalse);
      expect(b.hasPaired(a), isFalse);
      expect(a.state.notices, isEmpty);
    }, timeout: _slow);

    test('the other device unpairs us while we re-confirm it (Q-8): notice '
        'unpairedByPeer, then pairingFailed with the formatted name, and '
        'nothing saved on either side', () async {
      final (a, b) = await twoPairingNodes();
      await pairUp(a, b);
      final identityOfB = await b.loadIdentity();
      await b.node.shutdown();
      await b.pairedFile.delete();
      await b.start();
      await meet(a, b);
      expect(await b.node.pair(a.fingerprint), PairRequestResult.started);
      await bothComparing(b, a);
      expect(a.state.pairing!.alreadyPaired, isTrue);

      final status = await unpairAs(
        identityOfB,
        from: b.internetAddress,
        target: a,
      );

      expect(status, 200);
      await a.until((s) => !a.hasPaired(b) && s.notices.isNotEmpty);
      expect(a.state.notices.single.kind, NoticeKind.unpairedByPeer);
      expect(
        a.state.notices.single.deviceName,
        labelOf('Node B', b.fingerprint),
      );

      a.node.answerRequest(ReceiverAnswer.matches);
      b.node.answerCode(matches: true);

      final ended = await a.until(
        (s) => s.pairing?.phase == PairingPhase.finished,
      );
      expect(ended.pairing!.outcome, PairingOutcome.failed);
      await a.until((s) => s.notices.length == 2);
      expect(_kinds(a.state), [
        NoticeKind.unpairedByPeer,
        NoticeKind.pairingFailed,
      ]);
      expect(a.state.notices.last.deviceName, labelOf('Node B', b.fingerprint));
      await b.until((s) => s.pairing?.phase == PairingPhase.finished);
      expect(a.hasPaired(b), isFalse);
      expect(b.hasPaired(a), isFalse);
      expect(a.state.questions, isEmpty);
    }, timeout: _slow);
  });

  group('RF-111, RF-129: paired devices out of sight', () {
    test('right after start, a saved paired device that nobody sees is '
        'already listed, with its saved name, not visible, foreign', () async {
      final (a, spare) = await _nodeWithSpare();

      final row = await a.until(
        (s) => s.entries.any((e) => e.fingerprint == spare.fingerprint),
        reason: 'the saved paired device listed after start',
      );
      final entry = row.entries.single;
      expect(entry.displayName, 'Spare PC');
      expect(entry.visible, isFalse);
      expect(entry.paired, isTrue);
      expect(entry.mine, isFalse);
      expect(entry.deviceType, isNull);
      expect(entry.canPair, isFalse);
    }, timeout: _slow);

    test('a paired device that says bye keeps its row, not visible, with the '
        'last saved name and no type', () async {
      final (a, b) = await twoPairingNodes();
      await pairUp(a, b);

      await sayBye(b, a);

      final state = await a.until(
        (s) =>
            s.entries.any((e) => e.fingerprint == b.fingerprint && !e.visible),
      );
      final row = state.entries.single;
      expect(row.paired, isTrue);
      expect(row.displayName, 'Node B');
      expect(row.deviceType, isNull);
      expect(row.canPair, isFalse);
      expect(state.devices, isEmpty);
    }, timeout: _slow);
  });

  group('C75, RF-102, RF-120: setMine, notices, retrySave and '
      'dismissNotice', () {
    test('setMine to true and to false is saved and shown at each step; on '
        'an unknown fingerprint it does nothing', () async {
      final (a, spare) = await _nodeWithSpare();

      await a.node.setMine(spare.fingerprint, mine: true);

      expect(a.entryOf(spare.fingerprint)!.mine, isTrue);
      expect(_savedDevice(a.pairedFile, spare.fingerprint)['relation'], 'mine');

      await a.node.setMine(spare.fingerprint, mine: false);

      expect(a.entryOf(spare.fingerprint)!.mine, isFalse);
      expect(
        _savedDevice(a.pairedFile, spare.fingerprint)['relation'],
        'foreign',
      );

      await a.node.setMine('F' * 64, mine: true);

      expect(a.state.notices, isEmpty);
      expect(a.state.entries, hasLength(1));
      expect(_savedFingerprints(a.pairedFile), [spare.fingerprint]);
    }, timeout: _slow);

    test('setMine without disk: changed in memory, a retryable notice and '
        'unsaved changes; retrySave while broken keeps them; once fixed it '
        'clears them and the file has the change', () async {
      final (a, spare) = await _nodeWithSpare();
      breakFile(a.pairedFile);

      await a.node.setMine(spare.fingerprint, mine: true);

      expect(a.entryOf(spare.fingerprint)!.mine, isTrue);
      expect(a.state.notices, hasLength(1));
      final notice = a.state.notices.single;
      expect(notice.kind, NoticeKind.changeNotSaved);
      expect(notice.canRetry, isTrue);
      expect(a.state.unsavedChanges, isTrue);
      await eventually(() => a.states.last.unsavedChanges);

      await a.node.retrySave();

      expect(a.state.notices, [notice]);
      expect(a.state.unsavedChanges, isTrue);

      repairFile(a.pairedFile);
      await a.node.retrySave();

      expect(a.state.notices, isEmpty);
      expect(a.state.unsavedChanges, isFalse);
      await eventually(() => !a.states.last.unsavedChanges);
      expect(_savedDevice(a.pairedFile, spare.fingerprint)['relation'], 'mine');
    }, timeout: _slow);

    test('at most 8 notices: the oldest goes, ids keep growing, '
        'dismissNotice removes only the one asked for', () async {
      final (a, spare) = await _nodeWithSpare();
      breakFile(a.pairedFile);

      for (var i = 0; i < 10; i++) {
        await a.node.setMine(spare.fingerprint, mine: i.isEven);
      }

      final ids = [for (final n in a.state.notices) n.id];
      expect(ids, hasLength(8));
      for (var i = 1; i < ids.length; i++) {
        expect(ids[i], ids[i - 1] + 1);
      }
      expect(
        a.state.notices.every((n) => n.kind == NoticeKind.changeNotSaved),
        isTrue,
      );

      final removed = ids[3];
      a.node.dismissNotice(removed);
      await a.until((s) => s.notices.length == 7);

      expect(
        [for (final n in a.state.notices) n.id],
        [
          for (final id in ids)
            if (id != removed) id,
        ],
      );

      a.node.dismissNotice(99999);
      await Future<void>.delayed(const Duration(milliseconds: 200));
      expect(a.state.notices, hasLength(7));

      await a.node.setMine(spare.fingerprint, mine: false);
      expect(a.state.notices, hasLength(8));
      expect(a.state.notices.last.id, greaterThan(ids.last));

      repairFile(a.pairedFile);
      await a.node.retrySave();
      expect(a.state.notices, isEmpty);
    }, timeout: _slow);
  });

  group('C12, RF-66: a lost identity', () {
    test(
      'a new identity with a saved paired list: identityStatus reset, the '
      'list is empty, the old one kept aside; the next start is ok',
      () async {
        final (a, spare) = await _nodeWithSpare();
        final firstFingerprint = a.fingerprint;
        expect(a.state.identityStatus, IdentityStatus.ok);
        await a.node.setMine(spare.fingerprint, mine: false);
        expect(a.entryOf(spare.fingerprint)!.paired, isTrue);

        await a.node.shutdown();
        await a.identityDir.delete(recursive: true);
        await a.start();

        expect(a.state.identityStatus, IdentityStatus.reset);
        expect(a.state.fingerprint, isNot(firstFingerprint));
        await a.node.setMine(spare.fingerprint, mine: true);
        expect(a.state.entries, isEmpty);
        expect(a.state.notices, isEmpty);
        expect(_savedFingerprints(a.pairedFile), isEmpty);
        final aside = [
          for (final entity in a.dataDir.listSync())
            if (entity.path.contains('paired.json.previous-identity-')) entity,
        ];
        expect(aside, hasLength(1));
        expect(
          File(aside.single.path).readAsStringSync(),
          contains(spare.fingerprint),
        );

        await a.restart();

        expect(a.state.identityStatus, IdentityStatus.ok);
        await a.node.setMine(spare.fingerprint, mine: true);
        expect(a.state.entries, isEmpty);
      },
      timeout: _slow,
    );
  });

  group('shutdown with a pairing in progress (v3 point 11, v5 point 14)', () {
    test(
      'the receiver shuts down in comparing within 2 s, its held wait is '
      'answered before the server closes, so the initiator ends at once in '
      'cancelledByPeer without saving; no timer of the core is left',
      () async {
        final timers = CoreTimers();
        await runZoned(() async {
          final (a, b) = await twoPairingNodes(
            pollHoldB: const Duration(seconds: 7),
          );
          expect(await a.node.pair(b.fingerprint), PairRequestResult.started);
          await bothComparing(a, b);
          await Future<void>.delayed(const Duration(milliseconds: 500));

          final watch = Stopwatch()..start();
          await b.node.shutdown();
          watch.stop();

          expect(watch.elapsed, lessThan(const Duration(seconds: 2)));
          final ended = await a.until(
            (s) => s.pairing?.phase == PairingPhase.finished,
            limit: const Duration(seconds: 2),
          );
          expect(a.hasPaired(b), isFalse);

          await a.node.shutdown();

          expect(timers.createdBy('src/pairing_flow/'), greaterThan(0));
          expect(timers.activeBy('nexus_bridges_core/src/'), isEmpty);
          expect(
            await a.node.pair(b.fingerprint),
            PairRequestResult.unavailable,
          );
          expect(ended.pairing!.outcome, PairingOutcome.cancelledByPeer);
        }, zoneSpecification: timers.specification);
      },
      timeout: _slow,
    );

    test('the initiator shuts down in comparing within 2 s and the receiver '
        'ends in cancelledByPeer; afterwards no timer of the core is '
        'left', () async {
      final timers = CoreTimers();
      await runZoned(() async {
        final (a, b) = await twoPairingNodes(
          pollHoldB: const Duration(seconds: 7),
        );
        expect(await a.node.pair(b.fingerprint), PairRequestResult.started);
        await bothComparing(a, b);
        await Future<void>.delayed(const Duration(milliseconds: 500));

        final watch = Stopwatch()..start();
        await a.node.shutdown();
        watch.stop();

        expect(watch.elapsed, lessThan(const Duration(seconds: 2)));
        final ended = await b.until(
          (s) => s.pairing?.phase == PairingPhase.finished,
          limit: const Duration(seconds: 2),
        );
        expect(ended.pairing!.outcome, PairingOutcome.cancelledByPeer);

        await b.node.shutdown();

        expect(timers.activeBy('nexus_bridges_core/src/'), isEmpty);
      }, zoneSpecification: timers.specification);
    }, timeout: _slow);

    test('after shutdown every new method does nothing and raises '
        'nothing', () async {
      final (a, b) = await twoPairingNodes();
      final fingerprintOfB = b.fingerprint;
      await a.node.shutdown();
      final uncaught = <Object>[];

      await runZonedGuarded(() async {
        expect(
          await a.node.pair(fingerprintOfB),
          PairRequestResult.unavailable,
        );
        a.node.answerCode(matches: true);
        a.node.cancelPairing();
        a.node.answerRequest(ReceiverAnswer.matches);
        a.node.dismissPairing();
        a.node.dismissNotice(1);
        await a.node.answerMine(fingerprintOfB, mine: true);
        await a.node.setMine(fingerprintOfB, mine: true);
        await a.node.unignore(fingerprintOfB);
        await a.node.retrySave();
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }, (error, _) => uncaught.add(error));

      expect(uncaught, isEmpty);
    }, timeout: _slow);
  });
}
