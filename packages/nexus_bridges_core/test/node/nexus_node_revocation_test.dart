@TestOn('windows')
library;

import 'dart:async';
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:nexus_bridges_core/src/node/node.dart';
import 'package:nexus_bridges_core/src/transfer/transfer.dart'
    show tempFolderName;
import 'package:test/test.dart';
import 'package:win32/win32.dart';

import '../support/infra.dart' show scaled;
import 'guard_nodes_support.dart';
import 'transfer_nodes_harness.dart';

const int big = 4 * 1024 * 1024;

enum Cut {
  removed(TransferOutcome.shareRemoved),
  foreign(TransferOutcome.peerMarkedForeign),
  unpaired(TransferOutcome.unpaired);

  const Cut(this.seen);

  final TransferOutcome seen;
}

Future<void> applyCut(Guarded g, Cut cut) => switch (cut) {
  Cut.removed => g.b.node.removeShare(g.a.fingerprint, g.rootId),
  Cut.foreign => g.b.node.setMine(g.a.fingerprint, mine: false),
  Cut.unpaired => g.b.node.unpair(g.a.fingerprint),
};

void Function() holdWithoutSharing(String path) {
  final handle = using((arena) {
    final Win32Result(value: handle) = CreateFile(
      arena.pcwstr(path),
      0x80000000,
      FILE_SHARE_MODE(1),
      null,
      OPEN_EXISTING,
      FILE_FLAGS_AND_ATTRIBUTES(0x80),
      null,
    );
    return handle;
  });
  expect(handle.isValid, isTrue, reason: 'could not hold $path');
  var closed = false;
  void close() {
    if (closed) return;
    closed = true;
    handle.close();
  }

  addTearDown(close);
  return close;
}

Future<TransferOutcome> cutAndMeasure(Guarded g, Cut cut) async {
  final watch = Stopwatch()..start();
  await applyCut(g, cut);
  final seen = await g.b.until(
    (s) =>
        s.lastReceived != null && s.incoming?.stage != IncomingStage.receiving,
    reason: 'receiver saw the cut',
  );
  watch.stop();
  expect(watch.elapsed, lessThanOrEqualTo(scaled(const Duration(seconds: 2))));
  return seen.lastReceived!.outcome;
}

void expectLost(TransferResultView sent, Cut cut) {
  expect(
    sent.outcome,
    cut == Cut.unpaired
        ? anyOf(TransferOutcome.destinationLost, TransferOutcome.unpaired)
        : TransferOutcome.destinationLost,
  );
}

Future<void> expectEmptyPlace(Guarded g) async {
  final sub = '${g.docs}\\sub';
  await g.settled();
  expect(namesIn(sub), ['deep'], reason: 'nothing new in docs\\sub');
  expect(namesIn(g.docs), ['otra', 'sub'], reason: 'nothing new in docs');
  g.expectNothingLocked(['$sub\\deep', sub, g.docs]);
}

bool readsAs(File file, bool Function(String text) check) {
  try {
    return check(file.readAsStringSync());
  } on FileSystemException {
    return false;
  }
}

bool lists(File file, String fingerprint) =>
    readsAs(file, (text) => text.contains(fingerprint));

bool leavesOut(File file, String fingerprint) =>
    readsAs(file, (text) => !text.contains(fingerprint));

Future<void> rePair(TransferNode initiator, TransferNode receiver) async {
  await eventually(
    () async {
      await initiator.node.rescan();
      final entry = initiator.entryOf(receiver.fingerprint);
      return entry != null && entry.visible && !entry.paired;
    },
    limit: scaled(transferWait),
    reason: '${receiver.name} visible and unpaired',
  );
  expect(
    await initiator.node.pair(receiver.fingerprint),
    PairRequestResult.started,
  );
  await receiver.until(
    (s) => s.pairing?.phase == PairingPhase.comparing,
    reason: '${receiver.name} comparing',
  );
  await initiator.until(
    (s) => s.pairing?.phase == PairingPhase.comparing,
    reason: '${initiator.name} comparing',
  );
  initiator.node.answerCode(matches: true);
  receiver.node.answerRequest(ReceiverAnswer.matches);
  await eventually(
    () =>
        lists(initiator.pairedFile, receiver.fingerprint) &&
        lists(receiver.pairedFile, initiator.fingerprint),
    limit: scaled(transferWait),
    reason: 'both saved',
  );
}

Future<void> makeMine(TransferNode a, TransferNode b) async {
  await a.until(
    (s) => s.entries.any((e) => e.fingerprint == b.fingerprint && e.paired),
    reason: 'paired at ${a.name}',
  );
  await b.until(
    (s) => s.entries.any((e) => e.fingerprint == a.fingerprint && e.paired),
    reason: 'paired at ${b.name}',
  );
  await a.node.setMine(b.fingerprint, mine: true);
  await b.node.setMine(a.fingerprint, mine: true);
  await a.until(
    (s) => s.peers[b.fingerprint]?.mine == true,
    reason: 'mine at ${a.name}',
  );
  await b.until(
    (s) => s.peers[a.fingerprint]?.mine == true,
    reason: 'mine at ${b.name}',
  );
}

void main() {
  group('E750 a foreign peer keeps its roots paused (RF-405) [SEG]', () {
    test('E750 explore and send give 403 and defaultFolderOnly with no disk, '
        'the default folder warns, the roots stay and come back', () async {
      final g = await guardedNodes();
      await g.b.node.setMine(g.a.fingerprint, mine: false);
      await g.b.until(
        (s) => s.peers[g.a.fingerprint]?.mine == false,
        reason: 'A foreign at B',
      );
      g.fs.reset();

      await expectBrowse(g.a, g.b, rootsAsk(), 403, forbiddenBody);
      await expectBrowse(
        g.a,
        g.b,
        foldersAsk(g.rootId, const []),
        403,
        forbiddenBody,
      );
      final refused = await g.sendFile('a.txt', [1], g.to(const ['sub']));
      expect(refused.outcome, TransferOutcome.defaultFolderOnly);
      expect(g.fs.touches, 0);
      expect(g.b.state.lastReceived, isNull);
      expect(g.b.states.where((s) => s.incoming != null), isEmpty);
      expect(g.b.state.peers[g.a.fingerprint]!.shares.single.path, g.docs);

      final before = g.a.state.lastSent;
      final path = await g.a.sourceFile('porDefecto.txt', [2]);
      expect(
        await g.a.node.sendPaths(g.b.fingerprint, [path]),
        anyOf(SendResult.started, SendResult.queued),
      );
      final warning = await g.b.incomingAt(IncomingStage.warning);
      g.b.node.answerIncoming(warning.sessionId, accept: true);
      final saved = await g.a.sentResult(after: before);
      expect(saved.outcome, TransferOutcome.saved);
      expect(File('${g.b.recvDir}\\porDefecto.txt').readAsBytesSync(), [2]);

      await g.b.node.setMine(g.a.fingerprint, mine: true);
      await g.b.until(
        (s) => s.peers[g.a.fingerprint]?.mine == true,
        reason: 'A mine again',
      );
      final listed = await g.a.node.listRemoteFolders(
        g.b.fingerprint,
        g.rootId,
        const [],
      );
      expect((listed as RemoteFolders).names, ['otra', 'sub']);
      final back = await g.sendFile('b.txt', [3], g.to(const ['sub']));
      expect(back.outcome, TransferOutcome.saved);
    }, timeout: transferTimeout);
  });

  group('E751 a removed root stops at the next request (RF-417) [SEG]', () {
    test('E751 the next listing, level zero and offer see nothing', () async {
      final g = await guardedNodes();
      expect(
        await g.a.node.listRemoteFolders(g.b.fingerprint, g.rootId, const []),
        isA<RemoteFolders>(),
      );
      await g.b.node.removeShare(g.a.fingerprint, g.rootId);
      g.fs.reset();
      await expectBrowse(
        g.a,
        g.b,
        foldersAsk(g.rootId, const []),
        403,
        forbiddenBody,
      );
      final zero = await g.a.node.listRemoteRoots(g.b.fingerprint);
      expect((zero as RemoteRoots).roots, isEmpty);
      final sent = await g.sendFile('a.txt', [1], g.to(const ['sub']));
      expect(sent.outcome, TransferOutcome.destinationUnavailable);
      expect(g.fs.touches, 0);
      expect(namesIn('${g.docs}\\sub'), ['deep']);
    }, timeout: transferTimeout);
  });

  group('E752 cuts during a file upload (RF-417) [SEG]', () {
    for (final cut in Cut.values) {
      for (final fresh in [false, true]) {
        final where = fresh ? 'to a new folder' : 'to docs\\sub\\deep';
        test('E752 ${cut.name} cuts a file upload $where in at most 2 s and '
            'leaves nothing, not even a lock', () async {
          final g = await guardedNodes();
          g.b.writes.hold();
          addTearDown(g.b.writes.release);
          final before = g.a.state.lastSent;
          await g.start(
            await g.a.sourceFile('grande.bin', List.filled(big, 5)),
            g.to(
              fresh ? const ['otra'] : const ['sub', 'deep'],
              newFolder: fresh ? 'nueva' : null,
            ),
          );
          await g.b.incomingAt(IncomingStage.receiving);
          if (fresh) expect(exists('${g.docs}\\otra\\nueva'), isTrue);

          expect(await cutAndMeasure(g, cut), cut.seen);
          final sent = await g.a.sentResult(after: before);
          expectLost(sent, cut);
          g.b.writes.release();

          await g.settled();
          expect(namesIn('${g.docs}\\otra'), isEmpty);
          await expectEmptyPlace(g);
          expect(g.fs.lastSaved, isFalse);
          expectCleanLogs(
            [g.a, g.b],
            [g.docs, g.rootId],
            words: const ['sub', 'deep', 'nueva', 'otra'],
          );
        }, timeout: transferTimeout);
      }
    }
  });

  group('E752 cuts during a folder upload (RF-417) [SEG]', () {
    for (final cut in Cut.values) {
      test('E752 ${cut.name} cuts a folder upload in at most 2 s and leaves '
          'no temp folder, no new folder and no lock', () async {
        final g = await guardedNodes();
        final before = g.a.state.lastSent;
        await g.start(
          await bigFolder(g.a, 'Proyecto'),
          g.to(const ['sub'], newFolder: 'nueva'),
        );
        await receivingBytes(g.b);
        expect(await cutAndMeasure(g, cut), cut.seen);
        final sent = await g.a.sentResult(after: before);
        expectLost(sent, cut);
        await eventually(
          () => !exists('${g.docs}\\sub\\nueva'),
          limit: scaled(transferWait),
          reason: 'new folder removed',
        );
        await expectEmptyPlace(g);
        expect(g.fs.lastSaved, isFalse);
        expectCleanLogs(
          [g.a, g.b],
          [g.docs, g.rootId],
          words: const ['sub', 'deep', 'nueva', 'Proyecto'],
        );
      }, timeout: transferTimeout);
    }
  });

  group('E752 what a cut must not touch (RF-417, RF-190)', () {
    test('E752 marking foreign cuts although the node queue is busy (punto '
        '7)', () async {
      final g = await guardedNodes();
      g.b.writes.hold();
      addTearDown(g.b.writes.release);
      final before = g.a.state.lastSent;
      await g.start(
        await g.a.sourceFile('grande.bin', List.filled(big, 5)),
        g.to(const ['sub']),
      );
      await g.b.incomingAt(IncomingStage.receiving);

      final close = holdWithoutSharing(g.b.settingsFile.path);
      final marking = g.b.node.setMine(g.a.fingerprint, mine: false);
      var drained = false;
      final busy = Future.wait([
        for (var i = 0; i < 4; i++) g.b.node.setDeviceName('Ocupado $i'),
      ]).whenComplete(() => drained = true);

      await marking;
      await g.b.until(
        (s) => s.lastReceived?.outcome == TransferOutcome.peerMarkedForeign,
        limit: const Duration(milliseconds: 500),
        reason: 'cut with the queue busy',
      );
      expect(drained, isFalse);
      final sent = await g.a.sentResult(after: before);
      expect(sent.outcome, TransferOutcome.destinationLost);
      g.b.writes.release();
      close();
      await busy;
      await expectEmptyPlace(g);
    }, timeout: transferTimeout);

    test('RF-190 a send without destination of a peer that turns foreign '
        'goes on and is saved in the default folder', () async {
      final g = await guardedNodes();
      g.b.writes.delay = const Duration(milliseconds: 40);
      final before = g.a.state.lastSent;
      final path = await g.a.sourceFile('porDefecto.bin', List.filled(big, 6));
      expect(
        await g.a.node.sendPaths(g.b.fingerprint, [path]),
        anyOf(SendResult.started, SendResult.queued),
      );
      await g.b.incomingAt(IncomingStage.receiving);
      await g.b.node.setMine(g.a.fingerprint, mine: false);
      final sent = await g.a.sentResult(after: before);
      expect(sent.outcome, TransferOutcome.saved);
      expect(File('${g.b.recvDir}\\porDefecto.bin').lengthSync(), big);
      expect(namesIn('${g.docs}\\sub'), ['deep']);
    }, timeout: transferTimeout);

    test(
      'RF-417 removing another root does not cut a send to this one',
      () async {
        final g = await guardedNodes();
        final other = '${g.b.base}\\tercera';
        Directory(other).createSync();
        final extra = await addRoot(g.b, g.a, other);
        g.b.writes.hold();
        addTearDown(g.b.writes.release);
        final before = g.a.state.lastSent;
        await g.start(
          await g.a.sourceFile('grande.bin', List.filled(big, 5)),
          g.to(const ['sub']),
        );
        await g.b.incomingAt(IncomingStage.receiving);
        await g.b.node.removeShare(g.a.fingerprint, extra);
        g.b.writes.release();
        final sent = await g.a.sentResult(after: before);
        expect(sent.outcome, TransferOutcome.saved);
        await g.settled();
        expect(File('${g.docs}\\sub\\grande.bin').lengthSync(), big);
      },
      timeout: transferTimeout,
    );

    test('RF-417 what was saved before a cut stays', () async {
      final g = await guardedNodes();
      final saved = await g.sendFile('viejo.txt', [1], g.to(const ['sub']));
      expect(saved.outcome, TransferOutcome.saved);
      await g.settled();
      await g.b.node.removeShare(g.a.fingerprint, g.rootId);
      expect(File('${g.docs}\\sub\\viejo.txt').readAsBytesSync(), [1]);
    }, timeout: transferTimeout);
  });

  group('G11 every way out without saving leaves the place as it was', () {
    test('G11 removing the root during prepare answers '
        'destination_unavailable and the new folder goes', () async {
      final g = await guardedNodes();
      final entered = Completer<void>();
      final gate = Completer<void>();
      addTearDown(() {
        if (!gate.isCompleted) gate.complete();
      });
      g.fs.beforePrepare = () async {
        entered.complete();
        await gate.future;
      };
      final before = g.a.state.lastSent;
      await g.start(
        await g.a.sourceFile('a.txt', [1]),
        g.to(const ['sub'], newFolder: 'nueva'),
      );
      await entered.future.timeout(scaled(transferWait));
      await g.b.node.removeShare(g.a.fingerprint, g.rootId);
      gate.complete();
      final sent = await g.a.sentResult(after: before);
      expect(sent.outcome, TransferOutcome.destinationUnavailable);
      await expectEmptyPlace(g);
      expect(g.b.state.lastReceived, isNull);
    }, timeout: transferTimeout);

    for (final folder in [false, true]) {
      for (final newFolder in [false, true]) {
        test('Q-3 unpairing during prepare shows the sender the same reason '
            'as during the upload (${folder ? 'folder' : 'file'}, '
            '${newFolder ? 'new folder' : 'existing folder'})', () async {
          final g = await guardedNodes();
          final entered = Completer<void>();
          final gate = Completer<void>();
          addTearDown(() {
            if (!gate.isCompleted) gate.complete();
          });
          g.fs.beforePrepare = () async {
            if (!entered.isCompleted) entered.complete();
            await gate.future;
          };
          final before = g.a.state.lastSent;
          await g.start(
            folder
                ? await smallFolder(g.a, 'Proyecto')
                : await g.a.sourceFile('a.txt', [1]),
            g.to(const ['sub'], newFolder: newFolder ? 'nueva' : null),
          );
          await entered.future.timeout(scaled(transferWait));
          await g.b.node.unpair(g.a.fingerprint);
          gate.complete();
          final sent = await g.a.sentResult(after: before);
          expect(
            sent.outcome,
            anyOf(TransferOutcome.destinationLost, TransferOutcome.unpaired),
          );
          await expectEmptyPlace(g);
        }, timeout: transferTimeout);
      }
    }

    for (final folder in [false, true]) {
      test('B-3 a cut while the ${folder ? 'folder' : 'file'} writer opens '
          'waits for it: the chain is released after and the new folder '
          'does not stay', () async {
        final g = await guardedNodes();
        final entered = Completer<void>();
        final gate = Completer<void>();
        addTearDown(() {
          if (!gate.isCompleted) gate.complete();
        });
        g.b.platform.hold = (method, path) async {
          if (method == 'realPath' &&
              path.endsWith(tempFolderName) &&
              !gate.isCompleted) {
            if (!entered.isCompleted) entered.complete();
            await gate.future;
          }
        };
        final before = g.a.state.lastSent;
        await g.start(
          folder
              ? await smallFolder(g.a, 'Proyecto')
              : await g.a.sourceFile('a.txt', [1, 2, 3]),
          g.to(const ['sub'], newFolder: 'nueva'),
        );
        await entered.future.timeout(scaled(transferWait));
        await g.b.node.removeShare(g.a.fingerprint, g.rootId);
        await Future<void>.delayed(const Duration(milliseconds: 400));
        expect(g.fs.releases, 0, reason: 'the opening writer still needs it');
        gate.complete();
        final sent = await g.a.sentResult(after: before);
        expect(sent.outcome, isNot(TransferOutcome.saved));
        await expectEmptyPlace(g);
      }, timeout: transferTimeout);
    }

    test('G11 the sender going away mid upload leaves no temp, no new folder '
        'and no lock', () async {
      final g = await guardedNodes();
      g.b.writes.hold();
      addTearDown(g.b.writes.release);
      await g.start(
        await g.a.sourceFile('grande.bin', List.filled(big, 5)),
        g.to(const ['sub'], newFolder: 'nueva'),
      );
      await g.b.incomingAt(IncomingStage.receiving);
      await g.a.stop();
      await g.b.until(
        (s) => s.lastReceived != null,
        limit: scaled(const Duration(seconds: 40)),
        reason: 'B saw the end',
      );
      expect(g.b.state.lastReceived!.outcome, isNot(TransferOutcome.saved));
      g.b.writes.release();
      await eventually(
        () => !exists('${g.docs}\\sub\\nueva'),
        limit: scaled(transferWait),
        reason: 'new folder removed',
      );
      await expectEmptyPlace(g);
    }, timeout: transferTimeout);

    test('G11 the receiver closing mid upload leaves no temp, no new folder '
        'and no lock', () async {
      final g = await guardedNodes();
      g.b.writes.hold();
      addTearDown(g.b.writes.release);
      await g.start(
        await g.a.sourceFile('grande.bin', List.filled(big, 5)),
        g.to(const ['sub'], newFolder: 'nueva'),
      );
      await g.b.incomingAt(IncomingStage.receiving);
      final stopping = g.b.stop();
      g.b.writes.release();
      await stopping;
      await g.settled();
      expect(namesIn('${g.docs}\\sub'), ['deep']);
      g.expectNothingLocked(['${g.docs}\\sub', g.docs]);
    }, timeout: transferTimeout);

    test('T5 a queue of ten files to a new folder lands whole: the temp folder '
        'going away between elements never refuses the next one', () async {
      final g = await guardedNodes();
      final paths = [
        for (var i = 0; i < 10; i++) await g.a.sourceFile('f$i.txt', [i]),
      ];
      expect(
        await g.a.node.sendPaths(
          g.b.fingerprint,
          paths,
          destination: g.to(const ['sub'], newFolder: 'nueva'),
        ),
        SendResult.started,
      );
      final done = await g.a.until(
        (s) =>
            s.queues != null &&
            s.queues!.finished &&
            s.sendingTo == null &&
            s.outgoing == null,
        limit: scaled(const Duration(seconds: 40)),
        reason: 'queue finished',
      );
      expect([
        for (final item in done.queues!.loose) item.outcome,
      ], everyElement(TransferOutcome.saved));
      await g.settled();
      expect(namesIn('${g.docs}\\sub\\nueva'), [
        for (var i = 0; i < 10; i++) 'f$i.txt',
      ]);
    }, timeout: transferTimeout);
  });

  group('E753 a queue stops with the reason (RF-417)', () {
    test('E753 five files to docs: three stay, the fourth is cut, the fifth '
        'is not sent and says why', () async {
      final g = await guardedNodes();
      final paths = [
        await g.a.sourceFile('a1.txt', [1]),
        await g.a.sourceFile('a2.txt', [2]),
        await g.a.sourceFile('a3.txt', [3]),
        await g.a.sourceFile('a4.bin', List.filled(big, 4)),
        await g.a.sourceFile('a5.txt', [5]),
      ];
      g.b.writes.delay = const Duration(milliseconds: 60);
      final result = await g.a.node.sendPaths(
        g.b.fingerprint,
        paths,
        destination: g.to(const ['sub']),
      );
      expect(result, SendResult.started);
      await g.b.until(
        (s) =>
            s.incoming?.fileName == 'a4.bin' &&
            s.incoming?.stage == IncomingStage.receiving,
        limit: scaled(const Duration(seconds: 30)),
        reason: 'the fourth uploading',
      );
      await g.b.node.removeShare(g.a.fingerprint, g.rootId);
      final done = await g.a.until(
        (s) =>
            s.queues != null &&
            s.queues!.finished &&
            s.sendingTo == null &&
            s.outgoing == null,
        limit: scaled(const Duration(seconds: 30)),
        reason: 'queue finished',
      );
      final items = {for (final item in done.queues!.loose) item.name: item};
      for (final name in ['a1.txt', 'a2.txt', 'a3.txt']) {
        expect(items[name]!.outcome, TransferOutcome.saved, reason: name);
      }
      expect(items['a4.bin']!.state, QueueItemState.done);
      expect(items['a4.bin']!.outcome, TransferOutcome.destinationLost);
      expect(items['a5.txt']!.state, QueueItemState.notSent);
      expect(
        items['a5.txt']!.outcome,
        anyOf(
          TransferOutcome.destinationUnavailable,
          TransferOutcome.destinationLost,
        ),
      );
      expect(
        items['a1.txt']!.destination?.display(homeName: 'Home'),
        r'docs\sub',
      );
      await g.settled();
      expect(namesIn('${g.docs}\\sub'), ['a1.txt', 'a2.txt', 'a3.txt', 'deep']);
      g.expectNothingLocked(['${g.docs}\\sub', g.docs]);
    }, timeout: transferTimeout);
  });

  group('E754 a cut while finishing (RF-417)', () {
    test(
      'E754 with a slow mark, removing docs cuts a file before the move',
      () async {
        final g = await guardedNodes();
        final entered = Completer<void>();
        final gate = Completer<void>();
        addTearDown(() {
          if (!gate.isCompleted) gate.complete();
        });
        g.b.platform.mark = (path) async {
          if (!entered.isCompleted) entered.complete();
          await gate.future;
          return realFs.markFromInternet(path);
        };
        final before = g.a.state.lastSent;
        await g.start(
          await g.a.sourceFile('a.txt', [1, 2, 3]),
          g.to(const ['sub']),
        );
        await entered.future.timeout(scaled(transferWait));
        await g.b.node.removeShare(g.a.fingerprint, g.rootId);
        await g.b.until(
          (s) => s.lastReceived?.outcome == TransferOutcome.shareRemoved,
          reason: 'cut while finishing',
        );
        gate.complete();
        final sent = await g.a.sentResult(after: before);
        expect(sent.outcome, TransferOutcome.destinationLost);
        await expectEmptyPlace(g);
        expect(g.fs.rechecks, 0);
      },
      timeout: transferTimeout,
    );

    test('E754 with the move under way a file is saved whole', () async {
      final g = await guardedNodes();
      final entered = Completer<void>();
      final gate = Completer<void>();
      addTearDown(() {
        if (!gate.isCompleted) gate.complete();
      });
      g.fs.beforeMove = () async {
        entered.complete();
        await gate.future;
      };
      final before = g.a.state.lastSent;
      await g.start(
        await g.a.sourceFile('a.txt', [1, 2, 3]),
        g.to(const ['sub']),
      );
      await entered.future.timeout(scaled(transferWait));
      await g.b.node.removeShare(g.a.fingerprint, g.rootId);
      await Future<void>.delayed(const Duration(milliseconds: 150));
      gate.complete();
      final sent = await g.a.sentResult(after: before);
      expect(sent.outcome, TransferOutcome.saved);
      await g.settled();
      expect(File('${g.docs}\\sub\\a.txt').readAsBytesSync(), [1, 2, 3]);
      expect(g.fs.lastSaved, isTrue);
    }, timeout: transferTimeout);

    test('E754 with the move under way a folder is saved whole', () async {
      final g = await guardedNodes();
      final entered = Completer<void>();
      final gate = Completer<void>();
      addTearDown(() {
        if (!gate.isCompleted) gate.complete();
      });
      g.fs.beforeMove = () async {
        entered.complete();
        await gate.future;
      };
      final before = g.a.state.lastSent;
      await g.start(await smallFolder(g.a, 'Proyecto'), g.to(const ['sub']));
      await entered.future.timeout(scaled(transferWait));
      await g.b.node.removeShare(g.a.fingerprint, g.rootId);
      await Future<void>.delayed(const Duration(milliseconds: 150));
      gate.complete();
      final sent = await g.a.sentResult(after: before);
      expect(sent.outcome, TransferOutcome.saved);
      await g.settled();
      expect(namesIn('${g.docs}\\sub'), ['Proyecto', 'deep']);
    }, timeout: transferTimeout);
  });

  group('E755 pairing again starts empty (RF-418) [SEG]', () {
    test('E755 this device unpairs and pairs again: no roots', () async {
      final g = await guardedNodes();
      await g.b.node.unpair(g.a.fingerprint);
      await g.b.until(
        (s) => !s.peers.containsKey(g.a.fingerprint),
        reason: 'A gone at B',
      );
      await eventually(
        () {
          try {
            return !File('${g.b.dataPath}\\shares.json')
                .readAsStringSync()
                .contains(g.a.fingerprint);
          } on FileSystemException {
            return false;
          }
        },
        limit: scaled(transferWait),
        reason: 'shares.json without A',
      );
      await rePair(g.b, g.a);
      await makeMine(g.a, g.b);
      expect(g.b.state.peers[g.a.fingerprint]!.shares, isEmpty);
      final zero = await g.a.node.listRemoteRoots(g.b.fingerprint);
      expect((zero as RemoteRoots).roots, isEmpty);
      await expectBrowse(
        g.a,
        g.b,
        foldersAsk(g.rootId, const []),
        403,
        forbiddenBody,
      );
    }, timeout: transferTimeout);

    test('E755 the other device unpairs and pairs again: no roots', () async {
      final g = await guardedNodes();
      await g.a.node.unpair(g.b.fingerprint);
      await eventually(
        () =>
            leavesOut(g.b.pairedFile, g.a.fingerprint) &&
            !g.b.state.peers.containsKey(g.a.fingerprint),
        limit: scaled(transferWait),
        reason: 'A gone at B',
      );
      await rePair(g.a, g.b);
      await makeMine(g.a, g.b);
      expect(g.b.state.peers[g.a.fingerprint]!.shares, isEmpty);
      final zero = await g.a.node.listRemoteRoots(g.b.fingerprint);
      expect((zero as RemoteRoots).roots, isEmpty);
    }, timeout: transferTimeout);

    test('E755 extra: the same fingerprint pairs again before the queued '
        'paired change runs: the old roots must not survive', () async {
      final g = await guardedNodes();
      final close = holdWithoutSharing(g.b.settingsFile.path);
      var drained = false;
      final busy = Future.wait([
        for (var i = 0; i < 14; i++) g.b.node.setDeviceName('Ocupado $i'),
      ]).whenComplete(() => drained = true);
      await g.a.node.unpair(g.b.fingerprint);
      await eventually(
        () => leavesOut(g.b.pairedFile, g.a.fingerprint),
        limit: scaled(transferWait),
        reason: 'A out of paired.json at B',
      );
      await rePair(g.a, g.b);
      expect(
        drained,
        isFalse,
        reason: 'the paired change must still be queued',
      );
      close();
      await busy;
      await makeMine(g.a, g.b);
      final zero = await g.a.node.listRemoteRoots(g.b.fingerprint);
      expect([
        for (final share in g.b.state.peers[g.a.fingerprint]!.shares)
          'kept at B: ${share.label}',
        for (final root in (zero as RemoteRoots).roots)
          'seen by A: ${root.name}',
      ], isEmpty);
    }, timeout: transferTimeout);

    test('E755 extra: a confirmation pending at unpair does not survive a '
        'new pairing', () async {
      final (a, b) = await transferNodes();
      final folder = '${b.base}\\fat';
      Directory(folder).createSync();
      b.platform.noMarkSupport = true;
      b.picker.nextFolder = folder;
      final pending =
          await b.node.addShare(a.fingerprint) as ShareNeedsConfirmation;
      await b.node.unpair(a.fingerprint);
      await b.until(
        (s) => !s.peers.containsKey(a.fingerprint),
        reason: 'A gone at B',
      );
      await rePair(b, a);
      await makeMine(a, b);
      expect(
        await b.node.confirmShare(a.fingerprint, pending.pendingId),
        isA<ShareRefused>(),
      );
      expect(b.state.peers[a.fingerprint]!.shares, isEmpty);
    }, timeout: transferTimeout);

    test('E755 after losing the identity no root is left and the old '
        'fingerprint is gone from shares.json', () async {
      final g = await guardedNodes();
      await g.b.stop();
      final identityDir = Directory('${g.b.dataPath}\\identity');
      identityDir.deleteSync(recursive: true);
      await g.b.start();
      expect(g.b.state.peers, isEmpty);
      final file = File('${g.b.dataPath}\\shares.json');
      if (file.existsSync()) {
        expect(file.readAsStringSync(), isNot(contains(g.a.fingerprint)));
      }
    }, timeout: transferTimeout);
  });
}
