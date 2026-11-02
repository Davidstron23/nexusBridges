@TestOn('windows')
library;

import 'dart:async';
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:nexus_bridges_core/src/node/node.dart';
import 'package:nexus_bridges_core/src/pairing/pairing.dart' show PeerRelation;
import 'package:test/test.dart';
import 'package:win32/win32.dart';

import '../support/infra.dart' show scaled;
import 'transfer_nodes_harness.dart';

const int _big = 4 * 1024 * 1024;

const Duration _queueWait = Duration(seconds: 60);

const Duration _lateEnd = Duration(seconds: 45);

List<int> _bytes(int length, [int seed = 0]) =>
    List<int>.generate(length, (i) => (i + seed) % 251);

Future<String> _folder(
  TransferNode node,
  String name,
  Map<String, List<int>> files,
) async {
  final root = '${node.sourceDir}\\$name';
  Directory(root).createSync(recursive: true);
  for (final MapEntry(:key, :value) in files.entries) {
    final file = File('$root\\$key');
    file.parent.createSync(recursive: true);
    await file.writeAsBytes(value, flush: true);
  }
  return root;
}

void _holdWithoutSharing(String path) {
  final handle = using((arena) {
    final Win32Result(value: handle) = CreateFile(
      arena.pcwstr(path),
      0x80000000,
      FILE_SHARE_MODE(0),
      null,
      OPEN_EXISTING,
      FILE_FLAGS_AND_ATTRIBUTES(0x80),
      null,
    );
    return handle;
  });
  expect(handle.isValid, isTrue, reason: 'could not hold $path');
  addTearDown(() {
    if (handle.isValid) handle.close();
  });
}

Future<NodeState> _idle(TransferNode node, {Duration? limit}) => node.until(
  (s) => s.sendingTo == null && s.outgoing == null && !s.transferInProgress,
  limit: limit ?? scaled(_queueWait),
  reason: '${node.name} idle',
);

Future<SendQueuesView> _finished(TransferNode node, {Duration? limit}) async {
  final s = await node.until(
    (s) =>
        s.queues != null &&
        s.queues!.finished &&
        s.sendingTo == null &&
        s.outgoing == null,
    limit: limit ?? scaled(_queueWait),
    reason: '${node.name} queues finished',
  );
  return s.queues!;
}

Future<IncomingTransferView> _receivingFile(
  TransferNode node,
  String name,
) async {
  final s = await node.until(
    (s) =>
        s.incoming?.fileName == name &&
        s.incoming?.stage == IncomingStage.receiving,
    reason: '${node.name} receiving $name',
  );
  return s.incoming!;
}

List<String> _names(List<QueueItemView> items) => [
  for (final item in items) item.name,
];

List<TransferOutcome?> _outcomes(List<QueueItemView> items) => [
  for (final item in items) item.outcome,
];

List<QueueItemState> _states(List<QueueItemView> items) => [
  for (final item in items) item.state,
];

final class _Sessions {
  _Sessions(this.node) : _from = node.states.length;

  final TransferNode node;
  final int _from;

  List<String> get events {
    final seen = <String>{};
    final out = <String>[];
    TransferResultView? last;
    for (final s in node.states.skip(_from)) {
      final ended = s.lastReceived;
      if (ended != null && ended != last) {
        last = ended;
        out.add('end ${ended.fileName}');
      }
      final incoming = s.incoming;
      if (incoming != null && seen.add(incoming.sessionId)) {
        out.add('start ${incoming.fileName}');
      }
    }
    return out;
  }

  List<String> get ended => [
    for (final event in events)
      if (event.startsWith('end ')) event.substring(4),
  ];

  List<String> get started => [
    for (final event in events)
      if (event.startsWith('start ')) event.substring(6),
  ];

  bool get overlapped {
    String? previous;
    for (final event in events) {
      if (event.startsWith('start ') &&
          (previous?.startsWith('start ') ?? false)) {
        return true;
      }
      previous = event;
    }
    return false;
  }

  List<TransferResultView> get results {
    final out = <TransferResultView>[];
    for (final s in node.states.skip(_from)) {
      final ended = s.lastReceived;
      if (ended != null && (out.isEmpty || out.last != ended)) out.add(ended);
    }
    return out;
  }
}

List<SelectionProgress> _progressOf(TransferNode node, int from, int id) => [
  for (final s in node.states.skip(from))
    if (s.selectionProgress?.selectionId == id) s.selectionProgress!,
];

void _expectMonotonic(List<SelectionProgress> progress) {
  expect(progress, isNotEmpty);
  for (var i = 1; i < progress.length; i++) {
    expect(
      progress[i].doneBytes,
      greaterThanOrEqualTo(progress[i - 1].doneBytes),
      reason: 'doneBytes went down at $i',
    );
  }
  for (final p in progress) {
    expect(p.doneBytes, lessThanOrEqualTo(p.totalBytes));
  }
}

Set<String> _treeOf(String root) => {
  for (final entity in Directory(
    root,
  ).listSync(recursive: true, followLinks: false))
    entity.path.substring(root.length + 1),
};

List<String> _problemLogs(TransferNode node) => [
  for (final line in node.logs)
    if (line.startsWith('queues') ||
        line.startsWith('tray') ||
        line.startsWith('transfers close') ||
        line.startsWith('send paths') ||
        line.startsWith('send picked') ||
        line.startsWith('add to tray'))
      if (line.contains('failed')) line,
];

void main() {
  group('E518, RF-251: closing the picker without choosing', () {
    test('sendFiles and sendFolders give nothingChosen and no request reaches '
        'the receiver', () async {
      final (a, b) = await transferNodes();
      final from = b.states.length;
      a.picker
        ..nextFiles = const []
        ..nextFolders = const [];

      expect(await a.node.sendFiles(b.fingerprint), SendResult.nothingChosen);
      expect(await a.node.sendFolders(b.fingerprint), SendResult.nothingChosen);

      expect(a.picker.fileCalls, 1);
      expect(a.picker.multiFolderCalls, 1);
      await _idle(a);
      expect(a.state.queues, isNull);
      expect(a.state.lastSent, isNull);
      expect(a.state.selectionProgress, isNull);
      await Future<void>.delayed(const Duration(milliseconds: 300));
      expect(b.states.skip(from).where((s) => s.incoming != null), isEmpty);
      expect(b.state.lastReceived, isNull);
    }, timeout: transferTimeout);
  });

  group('E521, E526, E577, RF-288, RF-293: a mixed selection with real '
      'nodes', () {
    test('3 files, a .zip and 2 folders: the receiver sees them one by one, '
        'loose files first and each queue in case-insensitive order, all '
        'saved as one selection with a progress that never goes back and '
        'ends with done == total', () async {
      final (a, b) = await transferNodes();
      final sessions = _Sessions(b);
      final aFrom = a.states.length;
      final paths = [
        await _folder(a, 'src', {
          'main.dart': _bytes(300),
          'lib\\util.dart': _bytes(200, 1),
        }),
        await a.sourceFile('c.txt', _bytes(30, 2)),
        await a.sourceFile('Photos.zip', _bytes(5000, 3)),
        await a.sourceFile('a.txt', _bytes(10, 4)),
        await _folder(a, 'docs', {'readme.md': _bytes(40, 5)}),
        await a.sourceFile('B.txt', _bytes(20, 6)),
      ];
      const expectedTotal = 300 + 200 + 30 + 5000 + 10 + 40 + 20;

      expect(await a.node.sendPaths(b.fingerprint, paths), SendResult.started);

      final view = await _finished(a);
      expect(_names(view.loose), ['a.txt', 'B.txt', 'c.txt']);
      expect(_names(view.bundles), ['docs', 'Photos.zip', 'src']);
      expect(view.bundles.map((i) => i.isFolder), [true, false, true]);
      expect(view.bundles[1].isArchive, isTrue);
      expect(
        _outcomes([...view.loose, ...view.bundles]),
        everyElement(TransferOutcome.saved),
      );
      expect(view.delivered, 6);
      expect(view.total, 6);
      expect(view.peerFingerprint, b.fingerprint);

      await b.until(
        (s) => s.lastReceived?.fileName == 'src',
        reason: 'last element at B',
      );
      expect(sessions.ended, [
        'a.txt',
        'B.txt',
        'c.txt',
        'docs',
        'Photos.zip',
        'src',
      ]);
      expect(sessions.overlapped, isFalse, reason: '${sessions.events}');
      expect(
        sessions.results.map((r) => r.outcome),
        everyElement(TransferOutcome.saved),
      );
      expect(
        File('${b.recvDir}\\src\\lib\\util.dart').readAsBytesSync(),
        _bytes(200, 1),
      );
      expect(File('${b.recvDir}\\docs\\readme.md').existsSync(), isTrue);
      expect(File('${b.recvDir}\\Photos.zip').lengthSync(), 5000);

      final selectionIds = {
        for (final s in a.states.skip(aFrom))
          if (s.selectionProgress != null) s.selectionProgress!.selectionId,
      };
      expect(selectionIds, hasLength(1));
      final progress = _progressOf(a, aFrom, selectionIds.single);
      _expectMonotonic(progress);
      final last = a.state.selectionProgress!;
      expect(last.finished, isTrue);
      expect(last.doneBytes, last.totalBytes);
      expect(last.totalBytes, expectedTotal);
      expect(
        progress.where((p) => p.currentIsFolder).map((p) => p.currentName),
        containsAll(['docs', 'src']),
      );
    }, timeout: transferTimeout);

    test('a single file is a selection too: no queues, its own selectionId, '
        'and the next selection gets a new one', () async {
      final (a, b) = await transferNodes();
      final from = a.states.length;
      final one = await a.sourceFile('one.bin', _bytes(1000));

      expect(await a.node.sendPaths(b.fingerprint, [one]), SendResult.started);
      expect((await a.sentResult()).outcome, TransferOutcome.saved);
      await _idle(a);
      expect(a.state.queues, isNull);
      final first = a.state.selectionProgress!;
      expect(first.finished, isTrue);
      expect(first.doneBytes, 1000);
      expect(first.totalBytes, 1000);
      _expectMonotonic(_progressOf(a, from, first.selectionId));

      final two = await a.sourceFile('two.bin', _bytes(10));
      final three = await a.sourceFile('three.bin', _bytes(20));
      expect(
        await a.node.sendPaths(b.fingerprint, [two, three]),
        SendResult.started,
      );
      await _finished(a);
      final second = a.state.selectionProgress!;
      expect(second.selectionId, greaterThan(first.selectionId));
      expect(second.finished, isTrue);
      expect(second.doneBytes, 30);
      expect(second.totalBytes, 30);
    }, timeout: transferTimeout);

    test('sendFolders with two folders picked goes as one selection in the '
        'folders queue', () async {
      final (a, b) = await transferNodes();
      a.picker.nextFolders = [
        await _folder(a, 'zeta', {'z.txt': _bytes(5)}),
        await _folder(a, 'Alpha', {'a.txt': _bytes(6)}),
      ];

      expect(await a.node.sendFolders(b.fingerprint), SendResult.started);

      final view = await _finished(a);
      expect(view.loose, isEmpty);
      expect(_names(view.bundles), ['Alpha', 'zeta']);
      expect(_outcomes(view.bundles), everyElement(TransferOutcome.saved));
      expect(File('${b.recvDir}\\zeta\\z.txt').existsSync(), isTrue);
      expect(File('${b.recvDir}\\Alpha\\a.txt').existsSync(), isTrue);
    }, timeout: transferTimeout);
  });

  group('E520, E528, RF-290, RF-312: adding to running queues, another '
      'target and the tray', () {
    test('a second selection to B joins the running queues in order; C is '
        'off and gets otherTargetBusy; the tray does not change for C and '
        'empties when sent to B', () async {
      final (a, b, c) = await transferTrio();
      final sessions = _Sessions(b);
      final cFrom = c.states.length;
      expect(a.state.canSendTo(b.fingerprint), isTrue);
      expect(a.state.canSendTo(c.fingerprint), isTrue);
      b.writes.hold();
      addTearDown(b.writes.release);
      final first = [
        await a.sourceFile('a.bin', _bytes(_big)),
        await a.sourceFile('b.txt', _bytes(10)),
        await _folder(a, 'f', {'inside.txt': _bytes(7)}),
      ];

      expect(await a.node.sendPaths(b.fingerprint, first), SendResult.started);
      await _receivingFile(b, 'a.bin');
      expect(a.state.sendingTo, b.fingerprint);
      expect(a.state.transferInProgress, isTrue);

      final more = [
        await a.sourceFile('z.zip', _bytes(64)),
        await a.sourceFile('c.txt', _bytes(12)),
      ];
      expect(await a.node.sendPaths(b.fingerprint, more), SendResult.queued);
      final running = (await a.until(
        (s) => s.queues?.total == 5,
        reason: 'second selection in the queues',
      )).queues!;
      expect(_names(running.loose), ['a.bin', 'b.txt', 'c.txt']);
      expect(_names(running.bundles), ['f', 'z.zip']);
      expect(running.loose.first.state, QueueItemState.inProgress);

      expect(a.state.canSendTo(b.fingerprint), isTrue);
      expect(a.state.canSendTo(c.fingerprint), isFalse);
      final other = await a.sourceFile('other.txt', _bytes(3));
      expect(
        await a.node.sendPaths(c.fingerprint, [other]),
        SendResult.otherTargetBusy,
      );
      expect(
        await a.node.addToTray([await a.sourceFile('t.txt', _bytes(9))]),
        TrayResult.added,
      );
      final trayBefore = (await a.until(
        (s) => s.tray.isNotEmpty,
        reason: 'tray filled',
      )).tray;
      expect(trayBefore, hasLength(1));
      expect(await a.node.sendTray(c.fingerprint), SendResult.otherTargetBusy);
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(a.state.tray, trayBefore);

      b.writes.release();
      final view = await _finished(a);
      expect(
        _outcomes([...view.loose, ...view.bundles]),
        everyElement(TransferOutcome.saved),
      );
      await b.until(
        (s) => s.lastReceived?.fileName == 'z.zip',
        reason: 'z.zip at B',
      );
      expect(sessions.ended, ['a.bin', 'b.txt', 'c.txt', 'f', 'z.zip']);
      expect(sessions.overlapped, isFalse, reason: '${sessions.events}');
      expect(c.states.skip(cFrom).where((s) => s.incoming != null), isEmpty);
      expect(a.state.canSendTo(c.fingerprint), isTrue);

      expect(await a.node.sendTray(b.fingerprint), SendResult.started);
      await a.until((s) => s.tray.isEmpty, reason: 'tray emptied');
      await b.until(
        (s) => s.lastReceived?.fileName == 't.txt',
        reason: 't.txt at B',
      );
      expect(b.state.lastReceived!.outcome, TransferOutcome.saved);
    }, timeout: transferTimeout);

    test('with a single file in progress to B, another selection to B '
        'creates the queues with the first one in progress', () async {
      final (a, b) = await transferNodes();
      b.writes.hold();
      addTearDown(b.writes.release);
      final big = await a.sourceFile('big.bin', _bytes(_big));

      expect(await a.node.sendPaths(b.fingerprint, [big]), SendResult.started);
      await _receivingFile(b, 'big.bin');
      expect(a.state.queues, isNull);
      expect(a.state.sendingTo, b.fingerprint);
      final id = a.state.selectionProgress!.selectionId;

      final next = await a.sourceFile('next.txt', _bytes(4));
      expect(await a.node.sendPaths(b.fingerprint, [next]), SendResult.queued);
      final view = (await a.until(
        (s) => s.queues != null,
        reason: 'queues created',
      )).queues!;
      expect(_names(view.loose), ['big.bin', 'next.txt']);
      expect(_states(view.loose), [
        QueueItemState.inProgress,
        QueueItemState.pending,
      ]);
      expect(view.selectionId, id);

      b.writes.release();
      final done = await _finished(a);
      expect(_outcomes(done.loose), [
        TransferOutcome.saved,
        TransferOutcome.saved,
      ]);
      expect(a.state.selectionProgress!.selectionId, id);
      expect(b.filesIn(b.recvDir), ['big.bin', 'next.txt']);
    }, timeout: transferTimeout);
  });

  group('E522, RF-298: element problems and receiver problems', () {
    test('an unreadable file in the middle ends unreadable and the queue goes '
        'on', () async {
      final (a, b) = await transferNodes();
      final paths = [
        await a.sourceFile('a.txt', _bytes(10)),
        await a.sourceFile('b.txt', _bytes(11)),
        await a.sourceFile('c.txt', _bytes(12)),
      ];
      _holdWithoutSharing(paths[1]);

      expect(await a.node.sendPaths(b.fingerprint, paths), SendResult.started);

      final view = await _finished(a);
      expect(_outcomes(view.loose), [
        TransferOutcome.saved,
        TransferOutcome.unreadable,
        TransferOutcome.saved,
      ]);
      expect(view.delivered, 2);
      expect(b.filesIn(b.recvDir), ['a.txt', 'c.txt']);
    }, timeout: transferTimeout);

    test('a third node keeps the receiver busy: an unreadable element goes '
        'on, the next one ends busy and the rest are not sent and never '
        'asked for', () async {
      final (a, b, c) = await transferTrio();
      final fromC = await c.sourceFile('from-c.txt', _bytes(5));
      expect(
        await c.node.sendPaths(b.fingerprint, [fromC]),
        SendResult.started,
      );
      await b.incomingAt(IncomingStage.warning);
      final sessions = _Sessions(b);
      final paths = [
        await a.sourceFile('a.txt', _bytes(10)),
        await a.sourceFile('b.txt', _bytes(11)),
        await a.sourceFile('c.txt', _bytes(12)),
        await a.sourceFile('d.txt', _bytes(13)),
      ];
      _holdWithoutSharing(paths[0]);

      expect(await a.node.sendPaths(b.fingerprint, paths), SendResult.started);

      final view = await _finished(a);
      expect(_outcomes(view.loose), [
        TransferOutcome.unreadable,
        TransferOutcome.busy,
        TransferOutcome.busy,
        TransferOutcome.busy,
      ]);
      expect(_states(view.loose), [
        QueueItemState.done,
        QueueItemState.done,
        QueueItemState.notSent,
        QueueItemState.notSent,
      ]);
      expect(view.delivered, 0);
      await Future<void>.delayed(const Duration(milliseconds: 300));
      expect(sessions.started, isEmpty);
      expect(b.state.incoming?.peerFingerprint, c.fingerprint);
      expect(b.filesIn(b.recvDir), isEmpty);
    }, timeout: transferTimeout);
  });

  group('E523, RF-299: closing the sender with queues and a tray', () {
    test('transferInProgress stays true between elements; shutting the sender '
        'mid queue cuts the current element at the receiver, never asks for '
        'the pending ones and leaves no stray errors', () async {
      final (a, b) = await transferNodes();
      b.writes.delay = const Duration(milliseconds: 300);
      final from = a.states.length;
      final sessions = _Sessions(b);
      final paths = [
        await a.sourceFile('a1.txt', _bytes(10)),
        await a.sourceFile('a2.bin', _bytes(_big)),
        await a.sourceFile('a3.txt', _bytes(12)),
        await a.sourceFile('a4.txt', _bytes(13)),
      ];
      expect(
        await a.node.addToTray([await a.sourceFile('t.txt', _bytes(1))]),
        TrayResult.added,
      );

      expect(await a.node.sendPaths(b.fingerprint, paths), SendResult.started);
      await _receivingFile(b, 'a2.bin');

      final between = [
        for (final s in a.states.skip(from))
          if (s.queues != null &&
              !s.queues!.finished &&
              s.outgoing == null &&
              s.queues!.loose.first.state == QueueItemState.done)
            s,
      ];
      expect(between, isNotEmpty);
      for (final s in a.states.skip(from)) {
        if (s.queues != null && !s.queues!.finished) {
          expect(s.transferInProgress, isTrue);
          expect(s.sendingTo, b.fingerprint);
        }
      }

      await a.stop();

      final received = await b.until(
        (s) =>
            s.lastReceived?.fileName == 'a2.bin' &&
            (s.incoming == null || s.incoming!.stage == IncomingStage.ended),
        limit: scaled(_lateEnd),
        reason: 'a2.bin cut at B',
      );
      expect(
        received.lastReceived!.outcome,
        anyOf(TransferOutcome.cancelledByPeer, TransferOutcome.connectionLost),
      );
      await eventually(
        () => !b.tempLeftIn(b.recvDir),
        reason: 'temp deleted in B',
      );
      await Future<void>.delayed(const Duration(milliseconds: 500));
      expect(sessions.started, ['a1.txt', 'a2.bin']);
      expect(b.filesIn(b.recvDir), ['a1.txt']);
      expect(_problemLogs(a), isEmpty);

      expect(
        await a.node.sendPaths(b.fingerprint, [paths[2]]),
        SendResult.unavailable,
      );
      expect(await a.node.sendTray(b.fingerprint), SendResult.unavailable);
      expect(await a.node.addToTray([paths[3]]), TrayResult.unavailable);
      expect(await a.node.sendFiles(b.fingerprint), SendResult.unavailable);
      a.node
        ..cancelQueueItem('q1')
        ..removeQueueItem('q2')
        ..cancelAllQueued()
        ..removeFromTray('t1')
        ..clearTray();
    }, timeout: transferTimeout);
  });

  group('E524, RF-300: unpairing from the receiver mid queue', () {
    test('B unpairs A during the second of five: the second is cut with '
        'nothing saved at B and the other three are never asked for', () async {
      final (a, b) = await transferNodes();
      b.writes.delay = const Duration(milliseconds: 300);
      a.clock.followRealTime();
      final sessions = _Sessions(b);
      final paths = [
        await a.sourceFile('a1.txt', _bytes(10)),
        await a.sourceFile('a2.bin', _bytes(_big)),
        await a.sourceFile('a3.txt', _bytes(12)),
        await a.sourceFile('a4.txt', _bytes(13)),
        await a.sourceFile('a5.txt', _bytes(14)),
      ];

      expect(await a.node.sendPaths(b.fingerprint, paths), SendResult.started);
      await _receivingFile(b, 'a2.bin');
      await b.node.unpair(a.fingerprint);

      final view = await _finished(a, limit: scaled(_lateEnd));
      expect(view.loose[0].outcome, TransferOutcome.saved);
      expect(view.loose[1].state, QueueItemState.done);
      expect(view.loose[1].outcome, isNot(TransferOutcome.saved));
      expect(_states(view.loose.sublist(2)), [
        QueueItemState.notSent,
        QueueItemState.notSent,
        QueueItemState.notSent,
      ]);
      expect(
        view.loose.sublist(2).map((i) => i.outcome),
        everyElement(
          anyOf(
            TransferOutcome.unpaired,
            TransferOutcome.cancelledByPeer,
            TransferOutcome.connectionLost,
            TransferOutcome.noContact,
          ),
        ),
      );
      await eventually(
        () => !b.tempLeftIn(b.recvDir),
        reason: 'temp deleted in B',
      );
      await Future<void>.delayed(const Duration(milliseconds: 500));
      expect(sessions.started, ['a1.txt', 'a2.bin']);
      expect(b.filesIn(b.recvDir), ['a1.txt']);
    }, timeout: transferTimeout);

    test('A unpairs B mid queue: the pending ones end not sent as '
        'unpaired', () async {
      final (a, b) = await transferNodes();
      b.writes.delay = const Duration(milliseconds: 300);
      final paths = [
        await a.sourceFile('a1.bin', _bytes(_big)),
        await a.sourceFile('a2.txt', _bytes(12)),
        await a.sourceFile('a3.txt', _bytes(13)),
      ];

      expect(await a.node.sendPaths(b.fingerprint, paths), SendResult.started);
      await _receivingFile(b, 'a1.bin');
      await a.node.unpair(b.fingerprint);

      final s = await a.until(
        (s) => s.queues != null && s.queues!.finished && s.sendingTo == null,
        limit: scaled(_lateEnd),
        reason: 'queues stopped in A',
      );
      final view = s.queues!;
      expect(view.loose[0].outcome, TransferOutcome.unpaired);
      expect(_states(view.loose.sublist(1)), [
        QueueItemState.notSent,
        QueueItemState.notSent,
      ]);
      expect(
        _outcomes(view.loose.sublist(1)),
        everyElement(TransferOutcome.unpaired),
      );
      expect(b.filesIn(b.recvDir), isEmpty);
    }, timeout: transferTimeout);
  });

  group('E525, E528, RF-312, RF-313: sending the tray', () {
    test('a tray with a file and a folder; the file is deleted on disk; '
        'sendTray: the file ends notFound, the folder is saved and the tray '
        'is empty', () async {
      final (a, b) = await transferNodes();
      final file = await a.sourceFile('gone.txt', _bytes(9));
      final folder = await _folder(a, 'kept', {'k.txt': _bytes(8)});

      expect(await a.node.addToTray([file, folder]), TrayResult.added);
      await a.until((s) => s.tray.length == 2, reason: 'tray filled');
      expect(a.state.tray.map((t) => (t.name, t.isFolder)), [
        ('gone.txt', false),
        ('kept', true),
      ]);
      File(file).deleteSync();

      expect(await a.node.sendTray(b.fingerprint), SendResult.started);
      await a.until((s) => s.tray.isEmpty, reason: 'tray emptied');

      final view = await _finished(a);
      expect(_names(view.loose), ['gone.txt']);
      expect(view.loose.single.outcome, TransferOutcome.notFound);
      expect(_names(view.bundles), ['kept']);
      expect(view.bundles.single.outcome, TransferOutcome.saved);
      expect(view.delivered, 1);
      expect(File('${b.recvDir}\\kept\\k.txt').readAsBytesSync(), _bytes(8));
      expect(File('${b.recvDir}\\gone.txt').existsSync(), isFalse);
    }, timeout: transferTimeout);

    test('a double sendTray sends each element once and the second call finds '
        'the tray empty', () async {
      final (a, b) = await transferNodes();
      final one = await a.sourceFile('one.txt', _bytes(10));
      final two = await a.sourceFile('two.txt', _bytes(11));
      expect(await a.node.addToTray([one, two]), TrayResult.added);
      await a.until((s) => s.tray.length == 2, reason: 'tray filled');

      final results = await Future.wait([
        a.node.sendTray(b.fingerprint),
        a.node.sendTray(b.fingerprint),
      ]);

      expect(results.where((r) => r == SendResult.started), hasLength(1));
      expect(results.where((r) => r == SendResult.nothingChosen), hasLength(1));
      final view = await _finished(a);
      expect(view.total, 2);
      expect(view.delivered, 2);
      expect(a.state.tray, isEmpty);
      await Future<void>.delayed(const Duration(milliseconds: 300));
      expect(b.filesIn(b.recvDir), ['one.txt', 'two.txt']);
    }, timeout: transferTimeout);

    test('sendTray to a device that cannot take it leaves the tray as it '
        'was', () async {
      final (a, b) = await transferNodes();
      final file = await a.sourceFile('x.txt', _bytes(3));
      expect(await a.node.addToTray([file]), TrayResult.added);
      final before = (await a.until(
        (s) => s.tray.isNotEmpty,
        reason: 'tray filled',
      )).tray;

      expect(await a.node.sendTray('F' * 64), SendResult.unavailable);
      await loseSight(a, b);
      expect(await a.node.sendTray(b.fingerprint), SendResult.unavailable);

      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(a.state.tray, before);
      expect(a.state.queues, isNull);
    }, timeout: transferTimeout);
  });

  group('E526, E512, RF-289, RF-313, RF-315: the tray keeps paths only', () {
    test('addToTray sends nothing, skips repeated paths, honours the limit '
        'and the total count, and never writes to the data folder; after a '
        'restart the tray is empty', () async {
      final (a, b) = await transferNodes();
      final from = b.states.length;
      final dataBefore = _treeOf(a.dataPath);
      final file = await a.sourceFile('t.txt', _bytes(3));
      final folder = await _folder(a, 'dir', {'d.txt': _bytes(2)});

      expect(await a.node.addToTray([file, folder]), TrayResult.added);
      expect(
        await a.node.addToTray([file.toUpperCase()]),
        TrayResult.nothingNew,
      );
      expect(
        await a.node.addToTray([file], totalCount: 1001),
        TrayResult.tooMany,
      );
      expect(
        await a.node.addToTray([
          for (var i = 0; i < 999; i++) '${a.sourceDir}\\missing-$i.txt',
        ]),
        TrayResult.tooMany,
      );
      await a.until((s) => s.tray.length == 2, reason: 'tray filled');
      expect(a.state.tray.map((t) => t.isFolder), [false, true]);

      a.node.removeFromTray(a.state.tray.first.id);
      await a.until((s) => s.tray.length == 1, reason: 'one left');
      a.node.clearTray();
      await a.until((s) => s.tray.isEmpty, reason: 'tray cleared');
      expect(await a.node.addToTray([file, folder]), TrayResult.added);

      await Future<void>.delayed(const Duration(milliseconds: 300));
      expect(a.state.outgoing, isNull);
      expect(a.state.queues, isNull);
      expect(a.state.sendingTo, isNull);
      expect(a.state.transferInProgress, isFalse);
      expect(b.states.skip(from).where((s) => s.incoming != null), isEmpty);
      expect(_treeOf(a.dataPath).difference(dataBefore), isEmpty);

      await a.restart();
      expect(a.state.tray, isEmpty);
    }, timeout: transferTimeout);
  });

  group('E590: opening the picker does not stop a running queue', () {
    test('with the picker held open, the next element starts and ends; the '
        'files picked then join the queue', () async {
      final (a, b) = await transferNodes();
      final sessions = _Sessions(b);
      b.writes.hold();
      addTearDown(b.writes.release);
      final paths = [
        await a.sourceFile('a.bin', _bytes(_big)),
        await a.sourceFile('b.txt', _bytes(10)),
        await a.sourceFile('c.bin', _bytes(_big, 1)),
      ];
      expect(await a.node.sendPaths(b.fingerprint, paths), SendResult.started);
      await _receivingFile(b, 'a.bin');

      final picked = await a.sourceFile('d.txt', _bytes(5));
      a.picker
        ..nextFiles = [picked]
        ..hold();
      addTearDown(a.picker.release);
      final picking = a.node.sendFiles(b.fingerprint);
      await a.until((s) => s.pickerOpen, reason: 'picker open in A');
      expect(a.state.canSendTo(b.fingerprint), isFalse);

      b.writes
        ..delay = const Duration(milliseconds: 300)
        ..release();
      await b.until(
        (s) => s.lastReceived?.fileName == 'b.txt',
        reason: 'b.txt saved at B with the picker open',
      );
      expect(a.state.pickerOpen, isTrue);
      expect(sessions.started, containsAllInOrder(['a.bin', 'b.txt']));

      a.picker.release();
      expect(await picking, SendResult.queued);
      final view = await _finished(a);
      expect(_names(view.loose), ['a.bin', 'b.txt', 'c.bin', 'd.txt']);
      expect(_outcomes(view.loose), everyElement(TransferOutcome.saved));
      expect(sessions.overlapped, isFalse, reason: '${sessions.events}');
    }, timeout: transferTimeout);
  });

  group('E591, RF-296: cancelling elements goes on with the queue, except a foreign warning already shown', () {
    test(
      'cancelling one element with the folder question open at the '
      'receiver and the next one as soon as it starts: both end '
      'cancelledHere, the third is never answered busy and is saved',
      () async {
        final (a, b) = await transferNodes(rememberB: false);
        final answered = <String>{};
        final answer = b.node.states.listen((s) {
          final incoming = s.incoming;
          if (incoming != null &&
              incoming.stage == IncomingStage.folderQuestion &&
              incoming.fileName == 'c.txt' &&
              answered.add(incoming.sessionId)) {
            unawaited(b.node.useProposedFolder(incoming.sessionId));
          }
        });
        addTearDown(answer.cancel);
        OutgoingPhase? secondPhase;
        final cancelSecond = a.node.states.listen((s) {
          final outgoing = s.outgoing;
          final queues = s.queues;
          if (secondPhase != null || outgoing == null || queues == null) return;
          if (outgoing.fileName == 'b.txt' &&
              (outgoing.phase == OutgoingPhase.requesting ||
                  outgoing.phase == OutgoingPhase.waiting)) {
            secondPhase = outgoing.phase;
            a.node.cancelQueueItem(queues.loose[1].id);
          }
        });
        addTearDown(cancelSecond.cancel);
        final paths = [
          await a.sourceFile('a.txt', _bytes(10)),
          await a.sourceFile('b.txt', _bytes(11)),
          await a.sourceFile('c.txt', _bytes(12)),
        ];

        expect(
          await a.node.sendPaths(b.fingerprint, paths),
          SendResult.started,
        );
        final question = await b.incomingAt(IncomingStage.folderQuestion);
        expect(question.fileName, 'a.txt');
        final waiting = await a.until(
          (s) => s.outgoing?.phase == OutgoingPhase.waiting,
          reason: 'A waiting on the folder question',
        );
        a.node.cancelQueueItem(waiting.queues!.loose.first.id);

        final view = await _finished(a);
        expect(
          secondPhase,
          anyOf(OutgoingPhase.requesting, OutgoingPhase.waiting),
        );
        expect(_outcomes(view.loose), [
          TransferOutcome.cancelledHere,
          TransferOutcome.cancelledHere,
          TransferOutcome.saved,
        ]);
        expect(view.delivered, 1);
        expect(answered, hasLength(1));
        expect(b.filesIn(b.proposedDir), ['c.txt']);
      },
      timeout: transferTimeout,
    );

    test('cancelling an element as soon as the queues show it in progress, '
        'before its request starts, ends it cancelledHere and the queue goes '
        'on', () async {
      final (a, b) = await transferNodes();
      var cancelled = false;
      final cancelFirst = a.node.states.listen((s) {
        final queues = s.queues;
        if (cancelled || queues == null) return;
        final first = queues.loose.first;
        if (first.state == QueueItemState.inProgress) {
          cancelled = true;
          a.node.cancelQueueItem(first.id);
        }
      });
      addTearDown(cancelFirst.cancel);
      final paths = [
        await a.sourceFile('a.txt', _bytes(10)),
        await a.sourceFile('b.txt', _bytes(11)),
      ];

      expect(await a.node.sendPaths(b.fingerprint, paths), SendResult.started);

      final view = await _finished(a);
      expect(cancelled, isTrue);
      expect(_outcomes(view.loose), [
        TransferOutcome.cancelledHere,
        TransferOutcome.saved,
      ]);
      expect(b.filesIn(b.recvDir), ['b.txt']);
    }, timeout: transferTimeout);

    test('cancelling the element whose warning a foreign receiver already '
        'shows stops the queue: the rest is not sent, cancelled here, and '
        'nothing more is requested', () async {
      final (a, b) = await transferNodes(
        aAtB: PeerRelation.foreign,
        bAtA: PeerRelation.foreign,
      );
      final paths = [
        await a.sourceFile('a.txt', _bytes(10)),
        await a.sourceFile('b.txt', _bytes(11)),
        await a.sourceFile('c.txt', _bytes(12)),
      ];
      final sessions = _Sessions(b);

      expect(await a.node.sendPaths(b.fingerprint, paths), SendResult.started);
      final warning = await b.incomingAt(IncomingStage.warning);
      expect(warning.fileName, 'a.txt');
      final waiting = await a.until(
        (s) => s.outgoing?.phase == OutgoingPhase.waiting,
        reason: 'A waiting on the warning',
      );
      a.node.cancelQueueItem(waiting.queues!.loose.first.id);

      final view = await _finished(a);
      expect(_outcomes(view.loose), [
        TransferOutcome.cancelledHere,
        TransferOutcome.cancelledHere,
        TransferOutcome.cancelledHere,
      ]);
      expect(_states(view.loose), [
        QueueItemState.done,
        QueueItemState.notSent,
        QueueItemState.notSent,
      ]);
      expect(view.delivered, 0);
      await Future<void>.delayed(const Duration(milliseconds: 400));
      expect(sessions.started, ['a.txt']);
      expect(b.filesIn(b.recvDir), isEmpty);
    }, timeout: transferTimeout);

    test('cancelling a warning of a receiver that is foreign only at the '
        'other end: the sender cannot know, so the next element is declined '
        'by the minute of RF-215 and the queue stops there', () async {
      final (a, b) = await transferNodes(aAtB: PeerRelation.foreign);
      final paths = [
        await a.sourceFile('a.txt', _bytes(10)),
        await a.sourceFile('b.txt', _bytes(11)),
        await a.sourceFile('c.txt', _bytes(12)),
      ];

      expect(await a.node.sendPaths(b.fingerprint, paths), SendResult.started);
      final warning = await b.incomingAt(IncomingStage.warning);
      expect(warning.fileName, 'a.txt');
      final waiting = await a.until(
        (s) => s.outgoing?.phase == OutgoingPhase.waiting,
        reason: 'A waiting on the warning',
      );
      a.node.cancelQueueItem(waiting.queues!.loose.first.id);

      final view = await _finished(a);
      expect(_outcomes(view.loose), [
        TransferOutcome.cancelledHere,
        TransferOutcome.declined,
        TransferOutcome.declined,
      ]);
      expect(_states(view.loose), [
        QueueItemState.done,
        QueueItemState.done,
        QueueItemState.notSent,
      ]);
      expect(b.filesIn(b.recvDir), isEmpty);
    }, timeout: transferTimeout);

    test('cancelling the element in upload from a "mine" sender goes on with '
        'the next one', () async {
      final (a, b) = await transferNodes();
      b.writes.delay = const Duration(milliseconds: 300);
      final paths = [
        await a.sourceFile('a.bin', _bytes(_big)),
        await a.sourceFile('b.txt', _bytes(11)),
      ];

      expect(await a.node.sendPaths(b.fingerprint, paths), SendResult.started);
      await _receivingFile(b, 'a.bin');
      a.node.cancelQueueItem(a.state.queues!.loose.first.id);

      final view = await _finished(a);
      expect(_outcomes(view.loose), [
        TransferOutcome.cancelledHere,
        TransferOutcome.saved,
      ]);
      await eventually(
        () => !b.tempLeftIn(b.recvDir),
        reason: 'temp deleted in B',
      );
      expect(b.filesIn(b.recvDir), ['b.txt']);
    }, timeout: transferTimeout);

    test('removing a pending element and cancelling all', () async {
      final (a, b) = await transferNodes();
      b.writes.hold();
      addTearDown(b.writes.release);
      final paths = [
        await a.sourceFile('a.bin', _bytes(_big)),
        await a.sourceFile('b.txt', _bytes(11)),
        await a.sourceFile('c.txt', _bytes(12)),
        await a.sourceFile('d.txt', _bytes(13)),
      ];

      expect(await a.node.sendPaths(b.fingerprint, paths), SendResult.started);
      await _receivingFile(b, 'a.bin');
      final b2 = a.state.queues!.loose[1].id;
      a.node.removeQueueItem(b2);
      await a.until(
        (s) => s.queues!.loose.every((i) => i.id != b2),
        reason: 'b.txt removed',
      );
      expect(_names(a.state.queues!.loose), ['a.bin', 'c.txt', 'd.txt']);

      a.node.cancelAllQueued();
      b.writes.release();
      final view = await _finished(a);
      expect(_names(view.loose), ['a.bin']);
      expect(view.loose.single.outcome, TransferOutcome.cancelledHere);
      await eventually(
        () => !b.tempLeftIn(b.recvDir),
        reason: 'temp deleted in B',
      );
      expect(b.filesIn(b.recvDir), isEmpty);
    }, timeout: transferTimeout);
  });

  group('E587, R120: limits by relation on a queue', () {
    test('15 loose files from a foreign sender with every warning accepted: '
        'the first 12 are saved, the 13th ends busy and the rest are not '
        'sent', () async {
      final (a, b) = await transferNodes(aAtB: PeerRelation.foreign);
      final answered = <String>{};
      final accept = b.node.states.listen((s) {
        final incoming = s.incoming;
        if (incoming != null &&
            incoming.stage == IncomingStage.warning &&
            answered.add(incoming.sessionId)) {
          b.node.answerIncoming(incoming.sessionId, accept: true);
        }
      });
      addTearDown(accept.cancel);
      final paths = [
        for (var i = 1; i <= 15; i++)
          await a.sourceFile('f${'$i'.padLeft(2, '0')}.txt', _bytes(i)),
      ];

      expect(await a.node.sendPaths(b.fingerprint, paths), SendResult.started);

      final view = await _finished(a, limit: scaled(_queueWait * 2));
      expect(
        _outcomes(view.loose.sublist(0, 12)),
        everyElement(TransferOutcome.saved),
      );
      expect(view.loose[12].outcome, TransferOutcome.busy);
      expect(view.loose[12].state, QueueItemState.done);
      expect(_states(view.loose.sublist(13)), [
        QueueItemState.notSent,
        QueueItemState.notSent,
      ]);
      expect(
        _outcomes(view.loose.sublist(13)),
        everyElement(TransferOutcome.busy),
      );
      expect(answered, hasLength(12));
      expect(b.filesIn(b.recvDir), hasLength(12));
    }, timeout: const Timeout(Duration(minutes: 4)));

    test('the same 15 files from a "mine" sender all arrive', () async {
      final (a, b) = await transferNodes();
      final paths = [
        for (var i = 1; i <= 15; i++)
          await a.sourceFile('f${'$i'.padLeft(2, '0')}.txt', _bytes(i)),
      ];

      expect(await a.node.sendPaths(b.fingerprint, paths), SendResult.started);

      final view = await _finished(a, limit: scaled(_queueWait * 2));
      expect(_outcomes(view.loose), everyElement(TransferOutcome.saved));
      expect(view.delivered, 15);
      expect(b.filesIn(b.recvDir), hasLength(15));
    }, timeout: const Timeout(Duration(minutes: 4)));
  });

  group('sendPaths limits (RF-309 through the node)', () {
    test('an empty list gives nothingChosen and more than 1000 paths give '
        'tooMany, with nothing sent', () async {
      final (a, b) = await transferNodes();

      expect(
        await a.node.sendPaths(b.fingerprint, const []),
        SendResult.nothingChosen,
      );
      expect(
        await a.node.sendPaths(b.fingerprint, [
          for (var i = 0; i < 1001; i++) '${a.sourceDir}\\n$i.txt',
        ]),
        SendResult.tooMany,
      );
      expect(a.state.queues, isNull);
      expect(a.state.sendingTo, isNull);
      expect(b.state.incoming, isNull);
    }, timeout: transferTimeout);
  });
}
