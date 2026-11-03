@TestOn('windows')
library;

import 'dart:io';

import 'package:nexus_bridges_core/src/node/node.dart';
import 'package:nexus_bridges_core/src/transfer/transfer.dart'
    show visibleFileName;
import 'package:test/test.dart';

import '../support/infra.dart' show scaled;
import 'transfer_nodes_harness.dart';

const int _big = 4 * 1024 * 1024;

const Duration _queueWait = Duration(seconds: 60);

const String _longPrefix = r'\\?\';

const List<String> _bidiControls = [
  '\u202A',
  '\u202B',
  '\u202C',
  '\u202D',
  '\u202E',
  '\u2066',
  '\u2067',
  '\u2068',
  '\u2069',
];

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

Future<NodeState> _idle(TransferNode node) => node.until(
  (s) =>
      s.sendingTo == null &&
      s.outgoing == null &&
      !s.transferInProgress &&
      (s.queues == null || s.queues!.finished),
  limit: scaled(_queueWait),
  reason: '${node.name} idle',
);

Future<SendQueuesView> _finished(TransferNode node, {int? selection}) async {
  final s = await node.until(
    (s) =>
        s.queues != null &&
        s.queues!.finished &&
        (selection == null || s.queues!.selectionId == selection) &&
        s.sendingTo == null &&
        s.outgoing == null,
    limit: scaled(_queueWait),
    reason: '${node.name} queues finished',
  );
  return s.queues!;
}

QueueItemView _item(SendQueuesView view, String name) =>
    [...view.loose, ...view.bundles].firstWhere((item) => item.name == name);

String _pathOfLength(String base, int length, String fileName) {
  var need = length - base.length - 2 - fileName.length;
  expect(need, greaterThan(0), reason: 'the base path is already too long');
  final dirs = StringBuffer();
  while (need > 101) {
    dirs.write('${'d' * 100}\\');
    need -= 101;
  }
  dirs.write('e' * need);
  final path = '$base\\$dirs\\$fileName';
  expect(path.length, length);
  return path;
}

void _createLong(String base, String path, List<int> bytes) {
  final relative = path.substring(base.length + 1).split(r'\');
  var current = base;
  for (final dir in relative.take(relative.length - 1)) {
    current = '$current\\$dir';
    final long = Directory('$_longPrefix$current');
    if (!long.existsSync()) long.createSync();
  }
  File('$_longPrefix$path').writeAsBytesSync(bytes, flush: true);
}

void _deleteLongLater(String folder) {
  addTearDown(() {
    final long = Directory('$_longPrefix$folder');
    if (long.existsSync()) long.deleteSync(recursive: true);
  });
}

void _expectNoBidi(String? text, String reason) {
  expect(text, isNotNull, reason: reason);
  for (final control in _bidiControls) {
    expect(text!.contains(control), isFalse, reason: '$reason: $control');
  }
}

void main() {
  group('Q-1, RF-285: the received result carries the total size', () {
    test('Q-1 a folder sent by a real node arrives with its total size, and '
        'the loose file after it with its own', () async {
      final (a, b) = await transferNodes();
      final fotos = await _folder(a, 'fotos', {
        'x.bin': _bytes(3000),
        'sub\\y.bin': _bytes(5000, 1),
      });

      expect(
        await a.node.sendPaths(b.fingerprint, [fotos]),
        SendResult.started,
      );

      final sentFolder = await a.sentResult();
      final gotFolder = await b.receivedResult();
      expect(gotFolder.outcome, TransferOutcome.saved);
      expect(gotFolder.isFolder, isTrue);
      expect(gotFolder.fileCount, 2);
      expect(gotFolder.size, 8000);
      expect(sentFolder.size, 8000);
      expect(File('${b.recvDir}\\fotos\\sub\\y.bin').lengthSync(), 5000);
      await _idle(a);

      final one = await a.sourceFile('one.bin', _bytes(1234, 2));
      expect(await a.node.sendPaths(b.fingerprint, [one]), SendResult.started);

      final gotFile = await b.receivedResult(after: gotFolder);
      expect(gotFile.outcome, TransferOutcome.saved);
      expect(gotFile.isFolder, isFalse);
      expect(gotFile.size, 1234);
    }, timeout: transferTimeout);
  });

  group('Q-5, RF-285, RF-296: Cancel all counts what was not sent', () {
    test('Q-5 after one delivered, Remove takes a pending one out of the '
        'total and Cancel all keeps the rest as not sent (cancelled); '
        'delivered does not change and the progress never goes back', () async {
      final (a, b) = await transferNodes();
      final from = a.states.length;
      final paths = [
        await a.sourceFile('a.txt', _bytes(10)),
        await a.sourceFile('big.bin', _bytes(_big, 1)),
        await a.sourceFile('c.txt', _bytes(30, 2)),
        await a.sourceFile('d.txt', _bytes(40, 3)),
        await _folder(a, 'e', {'inside.txt': _bytes(50, 4)}),
      ];

      expect(await a.node.sendPaths(b.fingerprint, paths), SendResult.started);
      await a.until(
        (s) => s.queues != null && s.queues!.delivered == 1,
        reason: 'a.txt delivered',
      );
      b.writes.hold();
      addTearDown(b.writes.release);
      await b.until(
        (s) =>
            s.incoming?.fileName == 'big.bin' &&
            s.incoming?.stage == IncomingStage.receiving,
        reason: 'big.bin in course',
      );
      final running = a.state.queues!;
      expect(running.total, 5);
      expect(running.delivered, 1);
      final selection = running.selectionId;

      a.node.removeQueueItem(_item(running, 'c.txt').id);
      final removed = await a.until(
        (s) => s.queues!.total == 4,
        reason: 'c.txt removed',
      );
      expect(removed.queues!.delivered, 1);
      expect(
        [
          ...removed.queues!.loose,
          ...removed.queues!.bundles,
        ].map((item) => item.name),
        isNot(contains('c.txt')),
      );
      final beforeCancel = a.state.selectionProgress!;

      a.node.cancelAllQueued();
      final cancelled = await a.until(
        (s) =>
            s.queues!.loose.any((item) => item.state == QueueItemState.notSent),
        reason: 'pending marked as not sent',
      );
      expect(cancelled.queues!.total, 4);
      expect(cancelled.queues!.delivered, 1);
      b.writes.release();

      final view = await _finished(a, selection: selection);
      expect(view.total, 4);
      expect(view.delivered, 1);
      expect(_item(view, 'a.txt').outcome, TransferOutcome.saved);
      expect(_item(view, 'big.bin').state, QueueItemState.done);
      expect(_item(view, 'big.bin').outcome, TransferOutcome.cancelledHere);
      for (final name in ['d.txt', 'e']) {
        expect(_item(view, name).state, QueueItemState.notSent, reason: name);
        expect(
          _item(view, name).outcome,
          TransferOutcome.cancelledHere,
          reason: name,
        );
      }

      final progress = [
        for (final s in a.states.skip(from))
          if (s.selectionProgress?.selectionId == selection)
            s.selectionProgress!,
      ];
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
      final last = a.state.selectionProgress!;
      expect(last.doneBytes, greaterThanOrEqualTo(beforeCancel.doneBytes));
      expect(last.finished, isTrue);
      expect(last.doneBytes, last.totalBytes);
      await eventually(
        () => !b.tempLeftIn(b.recvDir),
        reason: 'temp deleted in B',
      );
      expect(b.filesIn(b.recvDir), ['a.txt']);
    }, timeout: transferTimeout);
  });

  group('Q-8, RF-285: Last sent keeps the summary of the previous queues', () {
    test(
      'Q-8 lastQueues is the previous queues while a new selection runs, '
      'also a single send without queues, and goes away when it ends',
      () async {
        final (a, b) = await transferNodes();
        expect(a.state.lastQueues, isNull);

        final first = [
          await a.sourceFile('p.txt', _bytes(10)),
          await a.sourceFile('q.txt', _bytes(20, 1)),
        ];
        expect(
          await a.node.sendPaths(b.fingerprint, first),
          SendResult.started,
        );
        final one = await _finished(a);
        expect(one.delivered, 2);
        expect(a.state.lastQueues, isNull);

        b.writes.hold();
        addTearDown(b.writes.release);
        final second = [
          await a.sourceFile('r.bin', _bytes(_big, 2)),
          await a.sourceFile('s.txt', _bytes(30, 3)),
        ];
        expect(
          await a.node.sendPaths(b.fingerprint, second),
          SendResult.started,
        );
        final duringQueues = await a.until(
          (s) =>
              s.queues != null &&
              s.queues!.selectionId != one.selectionId &&
              s.queues!.loose.any(
                (item) => item.state == QueueItemState.inProgress,
              ),
          reason: 'second selection in course',
        );
        final previous = duringQueues.lastQueues;
        expect(previous, isNotNull);
        expect(previous!.selectionId, one.selectionId);
        expect(previous.finished, isTrue);
        expect(previous.delivered, 2);
        expect(previous.total, 2);
        expect(previous.loose.map((item) => item.name), ['p.txt', 'q.txt']);

        b.writes.release();
        final two = await _finished(
          a,
          selection: duringQueues.queues!.selectionId,
        );
        expect(two.delivered, 2);
        expect(a.state.lastQueues, isNull);

        b.writes.hold();
        final single = await a.sourceFile('t.bin', _bytes(_big, 4));
        expect(
          await a.node.sendPaths(b.fingerprint, [single]),
          SendResult.started,
        );
        final duringSingle = await a.until(
          (s) => s.outgoing?.fileName == 't.bin',
          reason: 'single send in course',
        );
        expect(duringSingle.queues, isNull);
        expect(duringSingle.lastQueues, isNotNull);
        expect(duringSingle.lastQueues!.selectionId, two.selectionId);
        expect(duringSingle.lastQueues!.delivered, 2);
        expect(duringSingle.lastQueues!.total, 2);
        expect(duringSingle.lastSent?.fileName, 's.txt');

        b.writes.release();
        final sent = await a.sentResult(after: duringSingle.lastSent);
        expect(sent.fileName, 't.bin');
        expect(sent.outcome, TransferOutcome.saved);
        final after = await _idle(a);
        expect(after.queues, isNull);
        expect(after.lastQueues, isNull);
      },
      timeout: transferTimeout,
    );
  });

  group('Q-9, RF-270: a source path longer than 259 characters', () {
    test('Q-9 a real file at 260 characters ends pathTooLong and nothing '
        'reaches the receiver; one at 259 is saved', () async {
      final (a, b) = await transferNodes();
      final base = '${a.sourceDir}\\long';
      Directory(base).createSync();
      _deleteLongLater(base);
      final tooLong = _pathOfLength(base, 260, 'f.txt');
      _createLong(base, tooLong, _bytes(70));
      expect(File('$_longPrefix$tooLong').existsSync(), isTrue);
      final from = b.states.length;

      expect(
        await a.node.sendPaths(b.fingerprint, [tooLong]),
        SendResult.started,
      );
      final refused = await a.sentResult();
      expect(refused.outcome, TransferOutcome.pathTooLong);
      await _idle(a);
      await Future<void>.delayed(const Duration(milliseconds: 300));
      expect(b.states.skip(from).where((s) => s.incoming != null), isEmpty);
      expect(b.state.lastReceived, isNull);
      expect(b.filesIn(b.recvDir), isEmpty);

      final fits = _pathOfLength(base, 259, 'g.txt');
      _createLong(base, fits, _bytes(80, 1));
      expect(await a.node.sendPaths(b.fingerprint, [fits]), SendResult.started);
      final saved = await a.sentResult(after: refused);
      expect(saved.outcome, TransferOutcome.saved);
      expect(File('${b.recvDir}\\g.txt').readAsBytesSync(), _bytes(80, 1));
    }, timeout: transferTimeout);

    test('Q-9 inside a queue the long one ends pathTooLong and the queue goes '
        'on with the next', () async {
      final (a, b) = await transferNodes();
      final base = '${a.sourceDir}\\long';
      Directory(base).createSync();
      _deleteLongLater(base);
      final tooLong = _pathOfLength(base, 300, 'a.txt');
      _createLong(base, tooLong, _bytes(70));
      final short = await a.sourceFile('b.txt', _bytes(90, 2));

      expect(
        await a.node.sendPaths(b.fingerprint, [tooLong, short]),
        SendResult.started,
      );

      final view = await _finished(a);
      expect(_item(view, 'a.txt').outcome, TransferOutcome.pathTooLong);
      expect(_item(view, 'b.txt').outcome, TransferOutcome.saved);
      expect(view.delivered, 1);
      expect(view.total, 2);
      expect(b.filesIn(b.recvDir), ['b.txt']);
    }, timeout: transferTimeout);
  });

  group('B-3: the problem path of the sender is shown clean', () {
    test('B-3 a folder with a name holding U+202E ends invalidName and its '
        'problem path reaches lastSent and the queue view without bidi '
        'controls', () async {
      final (a, b) = await transferNodes();
      final raw = 'a\u202Etxt.exe';
      final proj = await _folder(a, 'proj', {
        'ok.txt': _bytes(10),
        'sub\\$raw': _bytes(20, 1),
      });

      expect(await a.node.sendPaths(b.fingerprint, [proj]), SendResult.started);
      final single = await a.sentResult();
      expect(single.outcome, TransferOutcome.invalidName);
      _expectNoBidi(single.problemPath, 'lastSent');
      expect(single.problemPath, endsWith(visibleFileName(raw)));
      await _idle(a);

      final other = await a.sourceFile('z.txt', _bytes(30, 2));
      expect(
        await a.node.sendPaths(b.fingerprint, [proj, other]),
        SendResult.started,
      );
      final view = await _finished(a);
      final item = _item(view, 'proj');
      expect(item.outcome, TransferOutcome.invalidName);
      _expectNoBidi(item.problemPath, 'queue item');
      expect(item.problemPath, endsWith(visibleFileName(raw)));
      expect(_item(view, 'z.txt').outcome, TransferOutcome.saved);
      expect(Directory('${b.recvDir}\\proj').existsSync(), isFalse);
    }, timeout: transferTimeout);
  });
}
