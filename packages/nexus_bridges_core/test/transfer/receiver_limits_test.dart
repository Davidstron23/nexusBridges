@TestOn('windows')
library;

import 'dart:async';
import 'dart:io';

import 'package:nexus_bridges_core/src/identity/identity.dart';
import 'package:nexus_bridges_core/src/pairing/pairing.dart';
import 'package:nexus_bridges_core/src/protocol/protocol.dart';
import 'package:nexus_bridges_core/src/server/server.dart';
import 'package:nexus_bridges_core/src/storage/storage.dart';
import 'package:nexus_bridges_core/src/transfer/folders.dart';
import 'package:nexus_bridges_core/src/transfer/messages.dart'
    show offerOutcome;
import 'package:nexus_bridges_core/src/transfer/platform.dart';
import 'package:nexus_bridges_core/src/transfer/transfer.dart';
import 'package:test/test.dart';

import '../server/api_server_harness.dart' show loopback, loopbackInterface;
import 'folders_fakes.dart' show hexA, hexB, hexC, ownTemp, treeOf, namesIn;
import 'receiver_harness.dart';

const int _size = 1536;

const int _margin = Limits.transferSpaceMargin;

final String _name31 = '${'n' * 27}.txt';

final String _name30 = '${'n' * 26}.txt';

final class Gate {
  Gate(this.method, this.matches);

  final String method;
  final bool Function(String path) matches;
  final Completer<void> _released = Completer<void>();
  int reached = 0;

  Future<void> call(String called, String path) async {
    if (called != method || !matches(path)) return;
    reached++;
    await _released.future;
  }

  void release() {
    if (!_released.isCompleted) _released.complete();
  }
}

void holdWith(ReceiverStack s, List<Gate> gates) {
  s.platform.hold = (method, path) async {
    for (final gate in gates) {
      await gate(method, path);
    }
  };
  addTearDown(() {
    for (final gate in gates) {
      gate.release();
    }
  });
}

Gate gateOn(String method, String path) =>
    Gate(method, (called) => samePath(called, path));

void expectError(RawReply? reply, int status, String code) {
  expect(reply, isNotNull, reason: 'no reply, expected $status $code');
  expect(reply!.status, status, reason: reply.text);
  expect(reply.json, {'error': code});
}

void expectWaiting(RawReply? reply) {
  expect(reply, isNotNull);
  expect(reply!.status, 202, reason: reply.text);
  expect(reply.json, {'state': 'waiting', 'picker': false});
}

String expectAccepted(RawReply? reply) {
  expect(reply, isNotNull);
  expect(reply!.status, 200, reason: reply.text);
  expect(reply.state, 'accepted', reason: reply.text);
  final permit = reply.json['permit'] as String;
  expect(permit, matches(hex32));
  return permit;
}

void expectRejected(RawReply? reply, String reason) {
  expect(reply, isNotNull);
  expect(reply!.status, 200, reason: reply.text);
  expect(reply.json, {'state': 'rejected', 'reason': reason});
}

String deepFolder(String base, int length) {
  expect(length, greaterThan(base.length + 1));
  var path = base;
  while (path.length < length) {
    final left = length - path.length - 1;
    final take = left > 150 ? 100 : left;
    path = '$path\\${'d' * take}';
  }
  Directory(path).createSync(recursive: true);
  expect(path.length, length);
  return path;
}

String makeFolder(String path) {
  Directory(path).createSync(recursive: true);
  return path;
}

String tempSubOf(String folder) => '$folder\\$tempFolderName';

List<String> seedTemps(String folder, List<String> hexes) {
  final sub = makeFolder(tempSubOf(folder));
  return [
    for (final hex in hexes)
      (File('$sub\\${ownTemp(hex)}')..writeAsStringSync('partial $hex')).path,
  ];
}

Future<String> volumeOf(String path) async =>
    (await realFs.volumeFacts(path))!.volumeId;

Future<List<String>> journalOf(ReceiverStack s) async {
  final journal = TempJournal(
    JsonFileStore(File('${s.dataDir}\\cleanup.json')),
  );
  await journal.load();
  return [for (final folder in journal.folders) folder.path];
}

Future<TransferCoordinator> restart(ReceiverStack s) async {
  final journal = TempJournal(
    JsonFileStore(File('${s.dataDir}\\cleanup.json')),
  );
  await journal.load();
  final coordinator = TransferCoordinator(
    identity: s.identity,
    paired: s.paired,
    folders: s.store,
    journal: journal,
    dataDirPath: s.dataDir,
    picker: NoPicker(),
    fileSystem: s.platform,
    clock: s.clock.call,
    tickInterval: const Duration(milliseconds: 10),
    log: s.logs.add,
  );
  addTearDown(coordinator.close);
  coordinator.start();
  return coordinator;
}

final class Pending {
  Pending(Future<RawReply?> future) {
    this.future = future.whenComplete(() => done = true);
  }

  late final Future<RawReply?> future;
  bool done = false;
}

void main() {
  late DeviceIdentity receiver;
  late Peer laptop;
  late Peer desk;
  late Peer portatil;

  setUpAll(() {
    receiver = DeviceIdentity.generate();
    laptop = Peer(DeviceIdentity.generate(), name: 'Laptop');
    desk = Peer(DeviceIdentity.generate(), name: 'Sobremesa');
    portatil = Peer(
      DeviceIdentity.generate(),
      name: 'PORTATIL',
      relation: PeerRelation.foreign,
    );
  });

  Future<ReceiverStack> stack({
    bool remembered = true,
    String Function(String base)? rememberedPath,
    void Function(TransferPlatform platform)? configure,
    FilePicker? picker,
  }) => ReceiverStack.start(
    identity: receiver,
    peers: [laptop, desk, portatil],
    remembered: remembered,
    rememberedPath: rememberedPath,
    pollHold: const Duration(milliseconds: 50),
    configure: configure,
    picker: picker,
  );

  String missingRemembered(String base) => '$base\\missing\\gone';

  Future<String> openQuestion(
    ReceiverStack s,
    Peer peer, {
    String name = 'informe.pdf',
  }) async {
    final id = newTransferId();
    expectWaiting(await s.offer(peer, transfer: id, name: name));
    await eventually(
      () => s.incoming?.stage == IncomingStage.folderQuestion,
      reason: 'folder question shown',
    );
    return id;
  }

  Future<void> choose(ReceiverStack s, HeldPicker picker, String path) async {
    final run = s.coordinator.chooseOtherFolder(s.sid);
    expect(picker.open, isTrue);
    picker.answer(path);
    await run;
  }

  Future<void> ended(ReceiverStack s) => eventually(
    () => s.incoming == null && !s.coordinator.busy,
    reason: 'session ended',
  );

  group('E61 RF-149 no space (D-9)', () {
    test('a remembered folder without room gives 507 with no question and '
        'the last reception says noSpace', () async {
      final s = await stack(
        configure: (p) => p.freeBytesOverride = _size + _margin - 1,
      );
      s.sampleViews();
      final id = newTransferId();
      final reply = await s.offer(laptop, transfer: id, size: _size);
      expectError(reply, 507, 'no_space');
      expect(offerOutcome(reply!.status, reply.json), TransferOutcome.noSpace);
      await settle();
      expect(s.seen, isEmpty);
      expect(s.incoming, isNull);
      expect(s.coordinator.busy, isFalse);
      final last = s.coordinator.lastReceived;
      expect(last?.outcome, TransferOutcome.noSpace);
      expect(last?.direction, TransferDirection.incoming);
      expect(last?.peerFingerprint, laptop.fingerprint);
      expect(last?.fileName, 'informe.pdf');
      expectRejected(await s.wait(laptop, id), 'no_space');
    });

    test('a foreign sender without room gets 507 before any warning', () async {
      final s = await stack(configure: (p) => p.freeBytesOverride = 10);
      s.sampleViews();
      expectError(await s.offer(portatil), 507, 'no_space');
      await settle();
      expect(s.seen, isEmpty);
      expect(s.coordinator.lastReceived?.outcome, TransferOutcome.noSpace);
      expect(s.coordinator.lastReceived?.peerName, 'PORTATIL');
    });

    test('exactly the size plus 1 GiB free is enough', () async {
      final s = await stack(
        configure: (p) => p.freeBytesOverride = _size + _margin,
      );
      expectAccepted(await s.offer(laptop, size: _size));
    });

    test('D-9 a drive that does not report its free space is accepted '
        'without checking', () async {
      final s = await stack(configure: (p) => p.freeBytesUnknown = true);
      expectAccepted(await s.offer(laptop, size: Limits.maxTransferSize));
      s.coordinator.cancelIncoming(s.sid);
      expectWaiting(await s.offer(portatil, size: Limits.maxTransferSize));
      expect(s.incoming?.stage, IncomingStage.warning);
    });

    test('a folder chosen in the question without room ends in noSpace on '
        'both sides', () async {
      final s = await stack(
        remembered: false,
        configure: (p) => p.freeBytesOverride = 10,
      );
      final proposed = '${s.downloadsDir}\\NexusBridges';
      final id = await openQuestion(s, laptop);
      await s.coordinator.useProposedFolder(s.sid);
      await ended(s);
      expect(s.coordinator.lastReceived?.outcome, TransferOutcome.noSpace);
      expectRejected(await s.wait(laptop, id), 'no_space');
      expect(s.store.saved.map((f) => f.path), [proposed]);
    });

    test('a folder created for this time and refused for space is '
        'removed', () async {
      final picker = HeldPicker();
      final s = await stack(
        rememberedPath: missingRemembered,
        picker: picker,
        configure: (p) => p.freeBytesOverride = 10,
      );
      final created = '${s.base}\\nueva';
      final id = await openQuestion(s, laptop);
      expect(s.incoming?.folder?.kind, FolderQuestionKind.thisTime);
      await choose(s, picker, created);
      await ended(s);
      expect(s.coordinator.lastReceived?.outcome, TransferOutcome.noSpace);
      expectRejected(await s.wait(laptop, id), 'no_space');
      await eventually(
        () => !Directory(created).existsSync(),
        reason: 'unused folder removed',
      );
      expect(s.store.saved, isEmpty);
    });
  });

  group('E167 RF-149 repeated no-space notices are throttled (v2 point '
      '25)', () {
    test('two in a minute from the same sender change the last reception '
        'once, and the minute is not renewed by the second', () async {
      final s = await stack(configure: (p) => p.freeBytesOverride = 10);
      final first = newTransferId();
      expectError(
        await s.offer(laptop, transfer: first, name: 'a.txt'),
        507,
        'no_space',
      );
      expect(s.coordinator.lastReceived?.fileName, 'a.txt');
      expect(s.coordinator.lastReceived?.outcome, TransferOutcome.noSpace);
      expectRejected(await s.wait(laptop, first), 'no_space');
      final shown = s.coordinator.lastReceived;
      final changes = s.views.length;

      s.clock.advance(const Duration(seconds: 30));
      final second = newTransferId();
      expectError(
        await s.offer(laptop, transfer: second, name: 'b.txt'),
        507,
        'no_space',
      );
      expect(identical(s.coordinator.lastReceived, shown), isTrue);
      expectRejected(await s.wait(laptop, second), 'no_space');
      expect(s.seen.where((v) => v.fileName == 'b.txt'), isEmpty);

      s.clock.advance(const Duration(seconds: 30));
      expectError(await s.offer(laptop, name: 'c.txt'), 507, 'no_space');
      expect(s.coordinator.lastReceived?.fileName, 'c.txt');
      expect(s.coordinator.lastReceived?.outcome, TransferOutcome.noSpace);
      expect(s.views.length, greaterThan(changes));
    });

    test('the throttle is per sender', () async {
      final s = await stack(configure: (p) => p.freeBytesOverride = 10);
      expectError(await s.offer(laptop, name: 'a.txt'), 507, 'no_space');
      expect(s.coordinator.lastReceived?.fileName, 'a.txt');
      expectError(await s.offer(desk, name: 'd.txt'), 507, 'no_space');
      expect(s.coordinator.lastReceived?.fileName, 'd.txt');
      expect(s.coordinator.lastReceived?.peerName, 'Sobremesa');
      expectError(await s.offer(laptop, name: 'b.txt'), 507, 'no_space');
      expect(s.coordinator.lastReceived?.fileName, 'd.txt');
    });

    test('a folder chosen in the question is throttled the same way', () async {
      final picker = HeldPicker();
      final s = await stack(
        rememberedPath: missingRemembered,
        picker: picker,
        configure: (p) => p.freeBytesOverride = 10,
      );
      final other = makeFolder('${s.base}\\otra');

      final first = await openQuestion(s, laptop, name: 'a.txt');
      await choose(s, picker, other);
      await ended(s);
      expect(s.coordinator.lastReceived?.fileName, 'a.txt');
      expect(s.coordinator.lastReceived?.outcome, TransferOutcome.noSpace);
      expectRejected(await s.wait(laptop, first), 'no_space');

      s.clock.advance(const Duration(seconds: 20));
      final second = await openQuestion(s, laptop, name: 'b.txt');
      await choose(s, picker, other);
      await ended(s);
      expect(s.coordinator.lastReceived?.fileName, 'b.txt');
      expect(s.coordinator.lastReceived?.outcome, TransferOutcome.noSpace);
      expectRejected(await s.wait(laptop, second), 'no_space');
    });
  });

  group('E159 RF-177 final path too long (v2 point 10)', () {
    test('with the remembered folder 259 characters fit and 260 are refused '
        'with 422 and no card', () async {
      final s = await stack(rememberedPath: (base) => deepFolder(base, 228));
      final folder = s.store.folder!.path;
      expect(folder.length + 1 + _name30.length, 259);
      final before = treeOf(folder);
      s.sampleViews();

      final reply = await s.offer(laptop, name: _name31);
      expectError(reply, 422, 'path_too_long');
      expect(
        offerOutcome(reply!.status, reply.json),
        TransferOutcome.pathTooLong,
      );
      expectError(await s.offer(portatil, name: _name31), 422, 'path_too_long');
      await settle();
      expect(s.seen, isEmpty);
      expect(s.coordinator.lastReceived, isNull);
      expect(s.coordinator.busy, isFalse);
      expect(treeOf(folder), before);

      expectAccepted(await s.offer(laptop, name: _name30));
    });

    test('a name of 255 units against the remembered folder is '
        'path_too_long, not invalid_name', () async {
      final s = await stack();
      s.sampleViews();
      final name = '${'a' * 253}\u{1F600}';
      expect(name.length, 255);
      expectError(await s.offer(laptop, name: name), 422, 'path_too_long');
      await settle();
      expect(s.seen, isEmpty);
      expect(s.coordinator.lastReceived, isNull);
    });

    test('a folder chosen in the question that is too long ends in '
        'pathTooLong on both sides', () async {
      final picker = HeldPicker();
      final s = await stack(remembered: false, picker: picker);
      final long = deepFolder(s.base, 229);
      final id = await openQuestion(s, laptop, name: _name30);
      await choose(s, picker, long);
      await ended(s);
      expect(s.coordinator.lastReceived?.outcome, TransferOutcome.pathTooLong);
      expect(s.coordinator.lastReceived?.fileName, _name30);
      expectRejected(await s.wait(laptop, id), 'path_too_long');
      expect(s.store.saved.map((f) => f.path), [long]);
      expect(namesIn(long), isEmpty);
    });

    test('a folder created for this time that is too long is '
        'removed', () async {
      final picker = HeldPicker();
      final s = await stack(rememberedPath: missingRemembered, picker: picker);
      final parent = deepFolder(s.base, 225);
      final created = '$parent\\nueva';
      final id = await openQuestion(s, laptop, name: _name31);
      await choose(s, picker, created);
      await ended(s);
      expect(s.coordinator.lastReceived?.outcome, TransferOutcome.pathTooLong);
      expectRejected(await s.wait(laptop, id), 'path_too_long');
      await eventually(
        () => !Directory(created).existsSync(),
        reason: 'unused folder removed',
      );
      expect(s.store.saved, isEmpty);
    });
  });

  group('E155 RF-142 warning or question out within 2 s (v2 point 3)', () {
    test('with volumeFacts stuck on the remembered folder the offer answers '
        '202 with the "this time" question at 1.5 s of the injected '
        'clock', () async {
      final s = await stack();
      final gate = gateOn('volumeFacts', s.receiveDir);
      holdWith(s, [gate]);
      final before = treeOf(s.receiveDir);
      final pending = Pending(s.offer(laptop));
      await eventually(() => gate.reached == 1, reason: 'inspection held');

      s.clock.advance(const Duration(milliseconds: 1400));
      await settle();
      expect(pending.done, isFalse);

      s.clock.advance(const Duration(milliseconds: 100));
      expectWaiting(await pending.future);
      await eventually(
        () => s.incoming?.stage == IncomingStage.folderQuestion,
        reason: 'question shown',
      );
      expect(
        s.incoming?.folder,
        FolderQuestionView(
          kind: FolderQuestionKind.thisTime,
          proposedPath: s.receiveDir,
          problem: FolderProblem.rememberedUnavailable,
        ),
      );

      gate.release();
      await settle(const Duration(milliseconds: 300));
      expect(treeOf(s.receiveDir), before);
    });

    test('with the startup cleanup held, the offer gets 503 busy at 0.5 s and '
        'frees the slot', () async {
      final s = await stack();
      final old = makeFolder('${s.base}\\old');
      await s.journal.add(
        ReceiveFolder(path: old, volumeId: await volumeOf(old)),
      );
      final gate = gateOn('volumeFacts', old);
      holdWith(s, [gate]);
      final cleanup = s.coordinator.cleanupAtStart();
      await eventually(() => gate.reached == 1, reason: 'cleanup held');
      final callsBefore = s.platform.calls.length;
      s.sampleViews();

      final pending = Pending(s.offer(laptop));
      await eventually(() => s.coordinator.busy, reason: 'offer admitted');
      s.clock.advance(const Duration(milliseconds: 400));
      await settle();
      expect(pending.done, isFalse);

      s.clock.advance(const Duration(milliseconds: 100));
      final reply = await pending.future;
      expectError(reply, 503, 'busy');
      expect(offerOutcome(reply!.status, reply.json), TransferOutcome.busy);
      expect(s.coordinator.busy, isFalse);
      expect(s.incoming, isNull);
      expect(s.seen, isEmpty);
      expect(s.coordinator.lastReceived, isNull);
      expect(
        s.platform.calls
            .skip(callsBefore)
            .where((c) => c.toUpperCase().contains(s.receiveDir.toUpperCase())),
        isEmpty,
      );

      gate.release();
      await cleanup;
      expectAccepted(await s.offer(laptop));
    });

    test('a cleanup that ends within 0.5 s lets the offer go on, and the '
        'question is still out at 1.5 s from the arrival', () async {
      final s = await stack();
      final old = makeFolder('${s.base}\\old');
      await s.journal.add(
        ReceiveFolder(path: old, volumeId: await volumeOf(old)),
      );
      final cleanupGate = gateOn('volumeFacts', old);
      final folderGate = gateOn('volumeFacts', s.receiveDir);
      holdWith(s, [cleanupGate, folderGate]);
      final cleanup = s.coordinator.cleanupAtStart();
      await eventually(() => cleanupGate.reached == 1, reason: 'cleanup held');

      final pending = Pending(s.offer(laptop));
      await eventually(() => s.coordinator.busy, reason: 'offer admitted');
      s.clock.advance(const Duration(milliseconds: 300));
      await settle();
      cleanupGate.release();
      await cleanup;
      await eventually(() => folderGate.reached == 1, reason: 'folder held');

      s.clock.advance(const Duration(milliseconds: 1100));
      await settle();
      expect(pending.done, isFalse);

      s.clock.advance(const Duration(milliseconds: 100));
      expectWaiting(await pending.future);
      await eventually(
        () => s.incoming?.stage == IncomingStage.folderQuestion,
        reason: 'question shown',
      );
      expect(s.incoming?.folder?.problem, FolderProblem.rememberedUnavailable);
    });

    test('with the default tick and the real clock the question is out in '
        'under 2 s', () async {
      late TransferCoordinator real;
      final s = await ReceiverStack.start(
        identity: receiver,
        peers: [laptop],
        routesOverride: (st) {
          real = TransferCoordinator(
            identity: st.identity,
            paired: st.paired,
            folders: st.store,
            journal: TempJournal(
              JsonFileStore(File('${st.dataDir}\\cleanup-real.json')),
            ),
            dataDirPath: st.dataDir,
            picker: NoPicker(),
            fileSystem: st.platform,
            pollHold: const Duration(milliseconds: 50),
            log: st.logs.add,
          );
          addTearDown(real.close);
          real.start();
          return real.routes;
        },
      );
      final gate = gateOn('volumeFacts', s.receiveDir);
      holdWith(s, [gate]);
      final pending = s.offer(laptop);
      await eventually(() => gate.reached == 1, reason: 'inspection held');
      final stopwatch = Stopwatch()..start();
      expectWaiting(await pending);
      stopwatch.stop();
      expect(
        stopwatch.elapsed,
        greaterThan(const Duration(milliseconds: 1300)),
      );
      expect(stopwatch.elapsed, lessThan(const Duration(seconds: 2)));
      await eventually(
        () => real.incoming?.stage == IncomingStage.folderQuestion,
        reason: 'question shown',
      );
    });

    test('without cleanupAtStart being called, offers do not wait for the '
        'journal', () async {
      final s = await stack();
      final old = makeFolder('${s.base}\\old');
      await s.journal.add(
        ReceiveFolder(path: old, volumeId: await volumeOf(old)),
      );
      final gate = gateOn('volumeFacts', old);
      holdWith(s, [gate]);
      expectAccepted(await s.offer(laptop));
      expect(gate.reached, 0);
    });
  });

  group('E166 [SEG] nothing is written after the deadline (v2 point 21)', () {
    test('offer: a remembered folder that does not exist yet is not created '
        'after 1.5 s', () async {
      final s = await stack(rememberedPath: (base) => '$base\\nueva');
      final remembered = '${s.base}\\nueva';
      final gate = gateOn('volumeFacts', s.base);
      holdWith(s, [gate]);
      final before = treeOf(s.base);
      final pending = Pending(s.offer(laptop));
      await eventually(() => gate.reached == 1, reason: 'inspection held');
      s.clock.advance(Limits.transferFolderCheckTimeout);
      expectWaiting(await pending.future);
      expect(Directory(remembered).existsSync(), isFalse);

      gate.release();
      await settle(const Duration(milliseconds: 300));
      expect(Directory(remembered).existsSync(), isFalse);
      expect(treeOf(s.base), before);
    });

    test('offer: a folder and temp subfolder created right before the '
        'deadline are removed and no probe is written', () async {
      final s = await stack(rememberedPath: (base) => '$base\\nueva');
      final remembered = '${s.base}\\nueva';
      final gate = gateOn('realPath', tempSubOf(remembered));
      holdWith(s, [gate]);
      final before = treeOf(s.base);
      final pending = Pending(s.offer(laptop));
      await eventually(() => gate.reached == 1, reason: 'probe held');
      expect(Directory(tempSubOf(remembered)).existsSync(), isTrue);
      s.clock.advance(Limits.transferFolderCheckTimeout);
      expectWaiting(await pending.future);

      gate.release();
      await eventually(
        () => !Directory(remembered).existsSync(),
        reason: 'created folder removed',
      );
      await settle();
      expect(treeOf(s.base), before);
    });

    test('offer: once the deadline passed, the folder is not swept even if '
        'the inspection ends well', () async {
      final s = await stack();
      final temps = seedTemps(s.receiveDir, [hexA, hexB]);
      final gate = gateOn('freeBytes', s.receiveDir);
      holdWith(s, [gate]);
      final pending = Pending(s.offer(laptop));
      await eventually(() => gate.reached == 1, reason: 'free space held');
      s.clock.advance(Limits.transferFolderCheckTimeout);
      expectWaiting(await pending.future);

      gate.release();
      await settle(const Duration(milliseconds: 300));
      for (final temp in temps) {
        expect(File(temp).existsSync(), isTrue, reason: temp);
      }
    });

    test('use this folder: the proposed folder is not created after '
        '10 s', () async {
      final s = await stack(remembered: false);
      final proposed = '${s.downloadsDir}\\NexusBridges';
      await openQuestion(s, laptop);
      final gate = gateOn('volumeFacts', s.downloadsDir);
      holdWith(s, [gate]);
      final run = s.coordinator.useProposedFolder(s.sid);
      await eventually(() => gate.reached == 1, reason: 'probe held');
      s.clock.advance(Limits.transferFolderChoiceTimeout);
      await run;
      expect(s.incoming?.folder?.problem, FolderProblem.cannotUse);
      expect(s.incoming?.folder?.inspecting, isFalse);

      gate.release();
      await settle(const Duration(milliseconds: 300));
      expect(Directory(proposed).existsSync(), isFalse);
      expect(treeOf(s.downloadsDir), isEmpty);
      expect(s.store.saved, isEmpty);
    });

    test('after the end: a folder chosen once the transfer ended is not '
        'created after 10 s', () async {
      final picker = HeldPicker();
      final s = await stack(remembered: false, picker: picker);
      final afterwards = '${s.base}\\tarde';
      final id = await openQuestion(s, laptop);
      final run = s.coordinator.chooseOtherFolder(s.sid);
      expect(picker.open, isTrue);
      expect((await s.cancel(laptop, id))?.status, 200);
      await eventually(
        () => s.incoming?.stage == IncomingStage.ended,
        reason: 'ended panel',
      );
      final gate = gateOn('volumeFacts', s.base);
      holdWith(s, [gate]);
      picker.answer(afterwards);
      await eventually(() => gate.reached == 1, reason: 'inspection held');
      s.clock.advance(Limits.transferFolderChoiceTimeout);
      await run;
      expect(s.incoming?.folder?.afterEnd, AfterEndResult.notUsable);

      gate.release();
      await settle(const Duration(milliseconds: 300));
      expect(Directory(afterwards).existsSync(), isFalse);
      expect(s.store.saved, isEmpty);
    });
  });

  group('RF-187 RF-234 startup cleanup with the real coordinator (A22, '
      'E27)', () {
    test('[SEG] only own temps inside the temp subfolder go; the rest stays '
        'and so does the journal entry', () async {
      final s = await stack();
      final folder = makeFolder('${s.base}\\Recibidos');
      final sub = makeFolder(tempSubOf(folder));
      final temps = seedTemps(folder, [hexA, hexB]);
      final userFile = File('$sub\\~nexusbridges-foo.partial')
        ..writeAsStringSync('del usuario');
      final folderWithTempName = makeFolder('$sub\\${ownTemp(hexC)}');
      final outside = File('$folder\\${ownTemp(hexA)}')
        ..writeAsStringSync('fuera');
      await s.journal.add(
        ReceiveFolder(path: folder, volumeId: await volumeOf(folder)),
      );

      await s.coordinator.cleanupAtStart();

      for (final temp in temps) {
        expect(File(temp).existsSync(), isFalse, reason: temp);
      }
      expect(
        namesIn(sub),
        unorderedEquals(['~nexusbridges-foo.partial', ownTemp(hexC)]),
      );
      expect(userFile.readAsStringSync(), 'del usuario');
      expect(Directory(folderWithTempName).existsSync(), isTrue);
      expect(outside.readAsStringSync(), 'fuera');
      expect(await journalOf(s), [folder]);
    });

    test('a journal folder that was renamed stays in the journal, is not '
        'created, and is cleaned at the next start once restored', () async {
      final s = await stack();
      final folder = makeFolder('${s.base}\\Recibidos');
      final temps = seedTemps(folder, [hexA, hexB]);
      await s.journal.add(
        ReceiveFolder(path: folder, volumeId: await volumeOf(folder)),
      );
      final renamed = '${s.base}\\Renombrada';
      Directory(folder).renameSync(renamed);

      await s.coordinator.cleanupAtStart();

      expect(await journalOf(s), [folder]);
      expect(Directory(folder).existsSync(), isFalse);
      expect(namesIn(tempSubOf(renamed)), hasLength(2));

      Directory(renamed).renameSync(folder);
      final next = await restart(s);
      await next.cleanupAtStart();

      expect(await journalOf(s), isEmpty);
      for (final temp in temps) {
        expect(File(temp).existsSync(), isFalse, reason: temp);
      }
      expect(Directory(tempSubOf(folder)).existsSync(), isFalse);
      expect(Directory(folder).existsSync(), isTrue);
    });

    test('a restored journal folder is cleaned when a transfer arrives to '
        'it', () async {
      final s = await stack();
      final temps = seedTemps(s.receiveDir, [hexA, hexB]);
      await s.journal.add(
        ReceiveFolder(
          path: s.receiveDir,
          volumeId: await volumeOf(s.receiveDir),
        ),
      );
      final renamed = '${s.base}\\Renombrada';
      Directory(s.receiveDir).renameSync(renamed);
      await s.coordinator.cleanupAtStart();
      expect(await journalOf(s), [s.receiveDir]);
      Directory(renamed).renameSync(s.receiveDir);

      expectAccepted(await s.offer(laptop));

      for (final temp in temps) {
        expect(File(temp).existsSync(), isFalse, reason: temp);
      }
      expect(Directory(tempSubOf(s.receiveDir)).existsSync(), isFalse);
      await eventually(
        () => s.journal.folders.isEmpty,
        reason: 'journal entry removed',
      );
      expect(await journalOf(s), isEmpty);
    });

    test('a folder chosen in the question is cleaned when it is used, not '
        'while the caution is open', () async {
      final s = await stack(
        remembered: false,
        configure: (p) => p.noMarkSupport = true,
      );
      final proposed = makeFolder('${s.downloadsDir}\\NexusBridges');
      final temps = seedTemps(proposed, [hexA]);
      await s.journal.add(
        ReceiveFolder(path: proposed, volumeId: await volumeOf(proposed)),
      );
      await openQuestion(s, laptop);
      await s.coordinator.useProposedFolder(s.sid);
      expect(s.incoming?.folder?.cautionPath, proposed);
      expect(File(temps.single).existsSync(), isTrue);
      expect(s.journal.folders, hasLength(1));

      s.coordinator.useFolderAnyway(s.sid);
      await eventually(
        () => s.incoming?.stage == IncomingStage.waitingData,
        reason: 'accepted',
      );
      expect(File(temps.single).existsSync(), isFalse);
      expect(s.journal.folders, isEmpty);
    });

    test('[SEG] a journal entry on a forbidden folder or on another volume is '
        'never swept', () async {
      final s = await stack();
      final forbidden = s.platform.system.windows!;
      final forbiddenTemps = seedTemps(forbidden, [hexA]);
      final elsewhere = makeFolder('${s.base}\\otra-unidad');
      final elsewhereTemps = seedTemps(elsewhere, [hexB]);
      await s.journal.add(
        ReceiveFolder(path: forbidden, volumeId: await volumeOf(forbidden)),
      );
      await s.journal.add(
        ReceiveFolder(path: elsewhere, volumeId: 'NTFS-0badf00d'),
      );

      await s.coordinator.cleanupAtStart();

      for (final temp in [...forbiddenTemps, ...elsewhereTemps]) {
        expect(File(temp).existsSync(), isTrue, reason: temp);
      }
      expect(await journalOf(s), [forbidden, elsewhere]);
    });

    test('each journal folder has 4 s: a stuck one stays and is never swept, '
        'and the next one is still cleaned', () async {
      final s = await stack();
      final stuck = makeFolder('${s.base}\\lenta');
      final stuckTemps = seedTemps(stuck, [hexA]);
      final fine = makeFolder('${s.base}\\buena');
      final fineTemps = seedTemps(fine, [hexB]);
      await s.journal.add(
        ReceiveFolder(path: stuck, volumeId: await volumeOf(stuck)),
      );
      await s.journal.add(
        ReceiveFolder(path: fine, volumeId: await volumeOf(fine)),
      );
      final gate = gateOn('freeBytes', stuck);
      holdWith(s, [gate]);
      final cleanup = s.coordinator.cleanupAtStart();
      await eventually(() => gate.reached == 1, reason: 'cleanup held');
      s.clock.advance(const Duration(milliseconds: 3900));
      await settle();
      expect(File(fineTemps.single).existsSync(), isTrue);

      s.clock.advance(const Duration(milliseconds: 100));
      await cleanup;
      expect(File(fineTemps.single).existsSync(), isFalse);
      expect(await journalOf(s), [stuck]);

      gate.release();
      await settle(const Duration(milliseconds: 300));
      expect(File(stuckTemps.single).existsSync(), isTrue);
      expect(await journalOf(s), [stuck]);
    });

    test('cleanupAtStart is idempotent', () async {
      final s = await stack();
      final folder = makeFolder('${s.base}\\Recibidos');
      seedTemps(folder, [hexA]);
      await s.journal.add(
        ReceiveFolder(path: folder, volumeId: await volumeOf(folder)),
      );
      int inspections() =>
          s.platform.calls.where((c) => c == 'volumeFacts $folder').length;

      final first = s.coordinator.cleanupAtStart();
      final second = s.coordinator.cleanupAtStart();
      expect(identical(first, second), isTrue);
      await first;
      expect(inspections(), 1);
      await s.coordinator.cleanupAtStart();
      expect(inspections(), 1);
      expect(await journalOf(s), isEmpty);
    });

    test('an inspection that throws does not stop the cleanup, which still '
        'completes and lets offers in', () async {
      final s = await stack();
      final broken = makeFolder('${s.base}\\rota');
      final brokenTemps = seedTemps(broken, [hexA]);
      final fine = makeFolder('${s.base}\\buena');
      final fineTemps = seedTemps(fine, [hexB]);
      await s.journal.add(
        ReceiveFolder(path: broken, volumeId: await volumeOf(broken)),
      );
      await s.journal.add(
        ReceiveFolder(path: fine, volumeId: await volumeOf(fine)),
      );
      s.platform.hold = (method, path) async {
        if (method == 'volumeFacts' && samePath(path, broken)) {
          throw StateError('volume');
        }
      };

      await s.coordinator.cleanupAtStart().timeout(const Duration(seconds: 5));

      expect(File(brokenTemps.single).existsSync(), isTrue);
      expect(File(fineTemps.single).existsSync(), isFalse);
      expect(await journalOf(s), [broken]);
      expectAccepted(await s.offer(laptop));
    });

    test('close does not hang on a stuck cleanup, its future completes and '
        'nothing is swept afterwards', () async {
      final s = await stack();
      final folder = makeFolder('${s.base}\\Recibidos');
      final temps = seedTemps(folder, [hexA]);
      await s.journal.add(
        ReceiveFolder(path: folder, volumeId: await volumeOf(folder)),
      );
      final gate = gateOn('freeBytes', folder);
      holdWith(s, [gate]);
      final cleanup = s.coordinator.cleanupAtStart();
      await eventually(() => gate.reached == 1, reason: 'cleanup held');

      await s.coordinator.close().timeout(const Duration(seconds: 5));
      await cleanup.timeout(const Duration(seconds: 1));
      await s.coordinator.cleanupAtStart().timeout(const Duration(seconds: 1));

      gate.release();
      await settle(const Duration(milliseconds: 300));
      expect(File(temps.single).existsSync(), isTrue);
      expect(gate.reached, 1);
    });

    test('cleanupAtStart after close does nothing', () async {
      final s = await stack();
      final folder = makeFolder('${s.base}\\Recibidos');
      final temps = seedTemps(folder, [hexA]);
      await s.journal.add(
        ReceiveFolder(path: folder, volumeId: await volumeOf(folder)),
      );
      await s.coordinator.close();
      await s.coordinator.cleanupAtStart().timeout(const Duration(seconds: 1));
      expect(File(temps.single).existsSync(), isTrue);
      expect(s.platform.calls.where((c) => c.contains('Recibidos')), isEmpty);
    });
  });

  group('E172 system folders retried with the real coordinator (v2 point '
      '13)', () {
    SystemFolders withoutStartup(SystemFolders all) => SystemFolders(
      downloads: all.downloads,
      startMenu: all.startMenu,
      windows: all.windows,
      programFiles: all.programFiles,
      systemDriveRoot: all.systemDriveRoot,
    );

    test('start reads the system folders once and later inspections reuse '
        'them', () async {
      final s = await stack();
      await eventually(() => s.platform.systemCalls == 1, reason: 'read');
      expectAccepted(await s.offer(laptop));
      s.coordinator.cancelIncoming(s.sid);
      expectAccepted(await s.offer(laptop));
      expect(s.platform.systemCalls, 1);
    });

    test('an incomplete read at start is retried by the next inspection, '
        'which works', () async {
      late SystemFolders complete;
      final s = await stack(
        configure: (p) {
          complete = p.system;
          p.system = withoutStartup(complete);
        },
      );
      await eventually(() => s.platform.systemCalls == 1, reason: 'read');
      await settle();
      s.platform.system = complete;

      expectAccepted(await s.offer(laptop));
      expect(s.platform.systemCalls, 2);
      s.coordinator.cancelIncoming(s.sid);
      expectAccepted(await s.offer(laptop));
      expect(s.platform.systemCalls, 2);
    });

    test('while the read stays incomplete every inspection retries and '
        'refuses, and it works once the read is complete', () async {
      late SystemFolders complete;
      final s = await stack(
        configure: (p) {
          complete = p.system;
          p.system = withoutStartup(complete);
        },
      );
      await eventually(() => s.platform.systemCalls == 1, reason: 'read');
      await settle();

      await openQuestion(s, laptop);
      expect(s.incoming?.folder?.problem, FolderProblem.rememberedUnavailable);
      expect(s.platform.systemCalls, 2);

      await s.coordinator.useProposedFolder(s.sid);
      expect(s.incoming?.folder?.problem, FolderProblem.stillUnavailable);
      expect(s.platform.systemCalls, 3);

      s.platform.system = complete;
      await s.coordinator.useProposedFolder(s.sid);
      await eventually(
        () => s.incoming?.stage == IncomingStage.waitingData,
        reason: 'accepted',
      );
      expect(s.platform.systemCalls, 4);
    });

    test('after the retry the data folder of the test is forbidden', () async {
      late SystemFolders complete;
      final picker = HeldPicker();
      final s = await stack(
        rememberedPath: (base) => '$base\\data',
        picker: picker,
        configure: (p) {
          complete = p.system;
          p.system = withoutStartup(complete);
        },
      );
      await eventually(() => s.platform.systemCalls == 1, reason: 'read');
      await settle();
      s.platform.system = complete;
      final dataBefore = namesIn(s.dataDir);

      await openQuestion(s, laptop);
      expect(s.incoming?.folder?.problem, FolderProblem.rememberedUnavailable);
      expect(s.platform.systemCalls, 2);

      await choose(s, picker, s.dataDir);
      expect(s.incoming?.folder?.problem, FolderProblem.forbidden);
      expect(s.incoming?.folder?.problemPath, s.dataDir);

      await choose(s, picker, '${s.dataDir}\\identity');
      expect(s.incoming?.folder?.problem, FolderProblem.forbidden);
      expect(namesIn(s.dataDir), dataBefore);
      expect(s.platform.systemCalls, 2);
    });
  });

  Completer<void> heldGate() {
    final gate = Completer<void>();
    addTearDown(() {
      if (!gate.isCompleted) gate.complete();
    });
    return gate;
  }

  Future<ReceiverStack> heldStack({
    bool remembered = true,
    String Function(String base)? rememberedPath,
    Completer<void>? holdLoad,
    Completer<void>? holdSystem,
    FilePicker? picker,
  }) => ReceiverStack.start(
    identity: receiver,
    peers: [laptop, desk, portatil],
    remembered: remembered,
    rememberedPath: rememberedPath,
    pollHold: const Duration(milliseconds: 50),
    holdLoad: holdLoad,
    picker: picker,
    configure: (p) => p.systemGate = holdSystem,
  );

  Iterable<String> callsOn(ReceiverStack s, String path, {int skip = 0}) => s
      .platform
      .calls
      .skip(skip)
      .where((c) => c.toUpperCase().contains(path.toUpperCase()));

  group('E204 Q-1 the load of the remembered folder races the 1.5 s', () {
    test('with the load held the offer gets 202 at 1.5 s with the "this time" '
        'question, nothing is created, and once loaded the next offer uses '
        'the folder', () async {
      final load = heldGate();
      final s = await heldStack(
        rememberedPath: (base) => '$base\\nueva',
        holdLoad: load,
      );
      final remembered = '${s.base}\\nueva';
      s.sampleViews();
      final before = treeOf(s.base);
      final pending = Pending(s.offer(laptop));
      await eventually(() => s.coordinator.busy, reason: 'offer admitted');
      expect(s.store.loads, 1);

      s.clock.advance(const Duration(milliseconds: 1400));
      await settle();
      expect(pending.done, isFalse);
      expect(s.incoming, isNull);

      s.clock.advance(const Duration(milliseconds: 100));
      expectWaiting(await pending.future);
      await eventually(
        () => s.incoming?.stage == IncomingStage.folderQuestion,
        reason: 'question shown',
      );
      final view = s.incoming!;
      expect(view.folder?.kind, FolderQuestionKind.thisTime);
      expect(view.folder?.problem, FolderProblem.rememberedUnavailable);
      expect(Directory(remembered).existsSync(), isFalse);
      expect(callsOn(s, remembered), isEmpty);
      expect(treeOf(s.base), before);

      load.complete();
      await settle(const Duration(milliseconds: 300));
      expect(s.incoming, view);
      expect(Directory(remembered).existsSync(), isFalse);
      expect(callsOn(s, remembered), isEmpty);
      expect(s.store.saved, isEmpty);

      s.coordinator.cancelFolderQuestion(view.sessionId);
      await ended(s);
      expectAccepted(await s.offer(laptop));
      expect(Directory(remembered).existsSync(), isTrue);
      expect(s.store.loads, 1);
      expect(s.store.saved, isEmpty);
      await settle();
      expect(
        s.seen.where((v) => v.folder?.kind == FolderQuestionKind.firstTime),
        isEmpty,
      );
    });

    test('a foreign sender with the load held gets the warning first and '
        'then the "this time" question', () async {
      final load = heldGate();
      final s = await heldStack(holdLoad: load);
      final pending = Pending(s.offer(portatil));
      await eventually(() => s.coordinator.busy, reason: 'offer admitted');
      s.clock.advance(Limits.transferFolderCheckTimeout);
      expectWaiting(await pending.future);
      await eventually(
        () => s.incoming?.stage == IncomingStage.warning,
        reason: 'warning shown',
      );
      s.coordinator.answerWarning(s.sid, accept: true);
      expect(s.incoming?.folder?.kind, FolderQuestionKind.thisTime);
      expect(s.incoming?.folder?.problem, FolderProblem.rememberedUnavailable);
    });
  });

  group('E205 Q-1 the Downloads proposal races the same 1.5 s', () {
    test('without a remembered folder and with the system folders held, the '
        'first time question has no proposal and says cannot use', () async {
      final system = heldGate();
      final picker = HeldPicker();
      final s = await heldStack(
        remembered: false,
        holdSystem: system,
        picker: picker,
      );
      final pending = Pending(s.offer(laptop));
      await eventually(() => s.coordinator.busy, reason: 'offer admitted');
      s.clock.advance(const Duration(milliseconds: 1400));
      await settle();
      expect(pending.done, isFalse);

      s.clock.advance(const Duration(milliseconds: 100));
      expectWaiting(await pending.future);
      await eventually(
        () => s.incoming?.stage == IncomingStage.folderQuestion,
        reason: 'question shown',
      );
      expect(
        s.incoming?.folder,
        const FolderQuestionView(
          kind: FolderQuestionKind.firstTime,
          proposedPath: '',
          problem: FolderProblem.cannotUse,
        ),
      );
      expect(namesIn(s.downloadsDir), isEmpty);

      system.complete();
      await settle(const Duration(milliseconds: 300));
      expect(s.incoming?.folder?.proposedPath, '');
      expect(namesIn(s.downloadsDir), isEmpty);

      final chosen = makeFolder('${s.base}\\elegida');
      await choose(s, picker, chosen);
      expect(picker.startIns, [null]);
      await eventually(
        () => s.incoming?.stage == IncomingStage.waitingData,
        reason: 'accepted',
      );
      expect(s.store.saved.single.path, chosen);
    });

    test('with the load and the proposal held, the question is "this time" '
        'with cannot use, out at 1.5 s within one tick', () async {
      final load = heldGate();
      final system = heldGate();
      final s = await heldStack(holdLoad: load, holdSystem: system);
      final pending = Pending(s.offer(laptop));
      await eventually(() => s.coordinator.busy, reason: 'offer admitted');
      s.clock.advance(const Duration(milliseconds: 1400));
      await settle();
      expect(pending.done, isFalse);

      s.clock.advance(const Duration(milliseconds: 100));
      final stopwatch = Stopwatch()..start();
      expectWaiting(await pending.future);
      expect(stopwatch.elapsed, lessThan(const Duration(seconds: 1)));
      expect(
        s.incoming?.folder,
        const FolderQuestionView(
          kind: FolderQuestionKind.thisTime,
          proposedPath: '',
          problem: FolderProblem.cannotUse,
        ),
      );
      expect(callsOn(s, s.receiveDir), isEmpty);
    });
  });

  group('E206 Q-1 safety net of 10 s', () {
    test('a session still checking when the clock jumps 10 s ends in silence '
        'and its held offer gets 410', () async {
      final load = heldGate();
      final s = await heldStack(holdLoad: load);
      s.sampleViews();
      final id = newTransferId();
      final pending = Pending(s.offer(portatil, transfer: id));
      await eventually(() => s.coordinator.busy, reason: 'offer admitted');

      s.clock.advance(Limits.transferMessageTimeout);
      expectError(await pending.future, 410, 'cancelled');
      expect(s.coordinator.busy, isFalse);
      await settle();
      expect(s.incoming, isNull);
      expect(s.seen, isEmpty);
      expect(s.views, isEmpty);
      expect(s.events, isEmpty);
      expect(s.coordinator.lastReceived, isNull);
      expect((await s.wait(portatil, id))?.json, {'state': 'cancelled'});

      load.complete();
      await settle();
      expect(s.incoming, isNull);
      expectWaiting(await s.offer(portatil));
    });

    test('a decided session never shown ends 10 s after the decision, not '
        'after the arrival', () async {
      final load = heldGate();
      final s = await heldStack(holdLoad: load);
      s.sampleViews();
      final offerRoute = s.coordinator.routes.firstWhere(
        (r) => r.path == ApiPaths.transferOffer,
      );
      final id = newTransferId();
      final decided = offerRoute.handle(
        ApiCall(
          path: ApiPaths.transferOffer,
          clientFingerprint: laptop.fingerprint,
          remoteAddress: loopback,
          via: loopbackInterface(),
          json: s.offerBody(transfer: id),
        ),
      );
      await eventually(() => s.coordinator.busy, reason: 'offer admitted');
      s.clock.advance(Limits.transferFolderCheckTimeout);
      final reply = await decided;
      expect(reply.status, 202);
      expect(s.incoming, isNull);

      s.clock.advance(const Duration(seconds: 8, milliseconds: 600));
      await settle();
      expect(s.coordinator.busy, isTrue);
      s.clock.advance(const Duration(seconds: 1, milliseconds: 300));
      await settle();
      expect(s.coordinator.busy, isTrue);

      s.clock.advance(const Duration(milliseconds: 100));
      await eventually(() => !s.coordinator.busy, reason: 'safety net');
      await reply.afterResponse!();
      await settle();
      expect(s.incoming, isNull);
      expect(s.seen, isEmpty);
      expect(s.events, isEmpty);
      expect(s.coordinator.lastReceived, isNull);
      expect((await s.wait(laptop, id))?.json, {'state': 'cancelled'});
    });
  });

  group('E207 Q-2 nothing is written after close', () {
    test('close while the load is held: the remembered folder is not created, '
        'nothing is touched and the offer gets 410', () async {
      final load = heldGate();
      final s = await heldStack(
        rememberedPath: (base) => '$base\\nueva',
        holdLoad: load,
      );
      final remembered = '${s.base}\\nueva';
      final before = treeOf(s.base);
      final pending = Pending(s.offer(laptop));
      await eventually(() => s.coordinator.busy, reason: 'offer admitted');
      final calls = s.platform.calls.length;

      await s.coordinator.close();
      load.complete();
      expectError(await pending.future, 410, 'cancelled');
      await settle(const Duration(milliseconds: 300));
      expect(Directory(remembered).existsSync(), isFalse);
      expect(s.platform.calls.skip(calls), isEmpty);
      expect(treeOf(s.base), before);
      expect(s.coordinator.lastReceived, isNull);
      expect(s.coordinator.busy, isFalse);
    });

    test('the load released in the same turn as close changes nothing '
        'either', () async {
      final load = heldGate();
      final s = await heldStack(
        rememberedPath: (base) => '$base\\nueva',
        holdLoad: load,
      );
      final remembered = '${s.base}\\nueva';
      final before = treeOf(s.base);
      final pending = Pending(s.offer(laptop));
      await eventually(() => s.coordinator.busy, reason: 'offer admitted');
      final calls = s.platform.calls.length;

      load.complete();
      final closing = s.coordinator.close();
      expectError(await pending.future, 410, 'cancelled');
      await closing;
      await settle(const Duration(milliseconds: 300));
      expect(Directory(remembered).existsSync(), isFalse);
      expect(callsOn(s, remembered, skip: calls), isEmpty);
      expect(treeOf(s.base), before);
    });

    test('close while the offer waits for the startup cleanup: nothing is '
        'created or swept and the offer gets 410', () async {
      final s = await stack(rememberedPath: (base) => '$base\\nueva');
      final remembered = '${s.base}\\nueva';
      final old = makeFolder('${s.base}\\old');
      final oldTemps = seedTemps(old, [hexA]);
      await s.journal.add(
        ReceiveFolder(path: old, volumeId: await volumeOf(old)),
      );
      final gate = gateOn('volumeFacts', old);
      holdWith(s, [gate]);
      final cleanup = s.coordinator.cleanupAtStart();
      await eventually(() => gate.reached == 1, reason: 'cleanup held');
      final before = treeOf(s.base);
      final pending = Pending(s.offer(laptop));
      await eventually(() => s.coordinator.busy, reason: 'offer admitted');
      s.clock.advance(const Duration(milliseconds: 300));
      await settle();
      expect(pending.done, isFalse);
      final calls = s.platform.calls.length;

      await s.coordinator.close();
      expectError(await pending.future, 410, 'cancelled');
      gate.release();
      await cleanup.timeout(const Duration(seconds: 5));
      await settle(const Duration(milliseconds: 300));
      expect(Directory(remembered).existsSync(), isFalse);
      expect(callsOn(s, remembered, skip: calls), isEmpty);
      expect(File(oldTemps.single).existsSync(), isTrue);
      expect(treeOf(s.base), before);
      expect(s.coordinator.lastReceived, isNull);
    });
  });

  group('E212 one read of the system folders in flight (plan point 76)', () {
    Future<void> askAndDrop(ReceiverStack s, Peer peer) async {
      final pending = Pending(s.offer(peer));
      await eventually(() => s.coordinator.busy, reason: 'offer admitted');
      s.clock.advance(Limits.transferFolderCheckTimeout);
      expectWaiting(await pending.future);
      if (peer.relation == PeerRelation.foreign) {
        await eventually(
          () => s.incoming?.stage == IncomingStage.warning,
          reason: 'warning shown',
        );
        s.coordinator.answerWarning(s.sid, accept: true);
      }
      await eventually(
        () => s.incoming?.stage == IncomingStage.folderQuestion,
        reason: 'question shown',
      );
      expect(s.incoming?.folder?.proposedPath, '', reason: peer.name);
      expect(s.incoming?.folder?.problem, FolderProblem.cannotUse);
      s.coordinator.cancelFolderQuestion(s.sid);
      await ended(s);
    }

    test('offers from several devices with the read held share one call and '
        'all later ones use its result', () async {
      final system = heldGate();
      final s = await heldStack(remembered: false, holdSystem: system);
      await eventually(() => s.platform.systemCalls == 1, reason: 'start');
      for (final peer in [laptop, desk, portatil, laptop]) {
        await askAndDrop(s, peer);
        expect(s.platform.systemCalls, 1, reason: peer.name);
      }

      system.complete();
      await settle();
      expectWaiting(await s.offer(desk));
      await eventually(
        () => s.incoming?.stage == IncomingStage.folderQuestion,
        reason: 'question shown',
      );
      expect(
        s.incoming?.folder,
        FolderQuestionView(
          kind: FolderQuestionKind.firstTime,
          proposedPath: '${s.downloadsDir}\\NexusBridges',
        ),
      );
      expect(s.platform.systemCalls, 1);
    });

    test('a read that fails is not cached: the next offer reads again and '
        'gets the folders', () async {
      final system = heldGate();
      final s = await heldStack(remembered: false, holdSystem: system);
      s.platform.systemError = StateError('system folders');
      await eventually(() => s.platform.systemCalls == 1, reason: 'start');
      await askAndDrop(s, laptop);
      await askAndDrop(s, desk);
      expect(s.platform.systemCalls, 1);

      system.complete();
      await settle();
      s.platform.systemError = null;
      expectWaiting(await s.offer(laptop));
      await eventually(
        () => s.incoming?.stage == IncomingStage.folderQuestion,
        reason: 'question shown',
      );
      expect(
        s.incoming?.folder?.proposedPath,
        '${s.downloadsDir}\\NexusBridges',
      );
      expect(s.platform.systemCalls, 2);
      expect(s.logs.join('\n'), contains('StateError'));
    });
  });

  group('E209 Q-4 no space after a card was seen is always recorded', () {
    test('with the throttle on, a folder without room chosen in the question '
        'becomes the last reception and the minute is not renewed', () async {
      final picker = HeldPicker();
      final s = await stack(
        rememberedPath: missingRemembered,
        picker: picker,
        configure: (p) => p.freeBytesOverride = 10,
      );
      final other = makeFolder('${s.base}\\otra');

      await openQuestion(s, laptop, name: 'a.txt');
      await choose(s, picker, other);
      await ended(s);
      expect(s.coordinator.lastReceived?.fileName, 'a.txt');

      s.clock.advance(const Duration(seconds: 20));
      final second = await openQuestion(s, laptop, name: 'b.txt');
      await choose(s, picker, other);
      await ended(s);
      final last = s.coordinator.lastReceived;
      expect(last?.fileName, 'b.txt');
      expect(last?.outcome, TransferOutcome.noSpace);
      expect(last?.peerFingerprint, laptop.fingerprint);
      expect(last?.direction, TransferDirection.incoming);
      expectRejected(await s.wait(laptop, second), 'no_space');

      makeFolder(missingRemembered(s.base));
      s.sampleViews();
      s.clock.advance(const Duration(seconds: 39, milliseconds: 900));
      expectError(await s.offer(laptop, name: 'c.txt'), 507, 'no_space');
      expect(identical(s.coordinator.lastReceived, last), isTrue);
      await settle();
      expect(s.seen.where((v) => v.fileName == 'c.txt'), isEmpty);

      s.clock.advance(const Duration(milliseconds: 100));
      expectError(await s.offer(laptop, name: 'd.txt'), 507, 'no_space');
      expect(s.coordinator.lastReceived?.fileName, 'd.txt');
      expect(s.coordinator.lastReceived?.outcome, TransferOutcome.noSpace);
    });
  });
}
