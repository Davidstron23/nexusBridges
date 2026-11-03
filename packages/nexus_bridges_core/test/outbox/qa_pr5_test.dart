import 'package:nexus_bridges_core/src/outbox/outbox.dart';
import 'package:nexus_bridges_core/src/outbox/path_key.dart';
import 'package:nexus_bridges_core/src/transfer/transfer.dart'
    show TransferOutcome;
import 'package:test/test.dart';

import 'queues_harness.dart';

const String _inA = r'C:\in\A.TXT';
const String _inB = r'C:\in\b.txt';
const String _inC = r'C:\in\c.txt';
const String _inD = r'C:\in\d.txt';
const String _inFolder = r'C:\in\Carpeta';

Map<String, ElementProbe> _probes() => {
  _inA: file(10),
  _inB: file(20),
  _inC: file(30),
  _inD: file(40),
  _inFolder: folder,
};

Future<void> _finishNext(
  Harness h,
  TransferOutcome outcome, {
  int size = 0,
}) async {
  await until(() => h.sender.busy, reason: 'a send should be running');
  h.sender.finish(outcome, size: size);
}

Harness? _harness;

Harness get h => _harness!;

set h(Harness value) => _harness = value;

void main() {
  tearDown(() async {
    await _harness?.dispose();
    _harness = null;
  });

  group('Q-5, RF-285, RF-301: what is cancelled stays in the total', () {
    test(
      'Q-5 Cancel all after one delivered: the pending ones end not sent '
      '(cancelled), the total keeps them and delivered does not change',
      () async {
        h = Harness(probes: _probes());
        await h.submit([_inA, _inB, _inC, _inD, _inFolder]);
        await _finishNext(h, TransferOutcome.saved, size: 10);
        await until(() => h.sender.paths.length == 2);
        expect(h.view.delivered, 1);
        expect(h.view.total, 5);

        h.queues.cancelAll();

        expect(h.sender.cancels, 1);
        expect(h.view.total, 5);
        expect(h.view.delivered, 1);
        expect(h.item('b.txt').state, QueueItemState.inProgress);
        for (final name in ['c.txt', 'd.txt', 'Carpeta']) {
          expect(h.item(name).state, QueueItemState.notSent, reason: name);
          expect(
            h.item(name).outcome,
            TransferOutcome.cancelledHere,
            reason: name,
          );
        }

        h.sender.finish(TransferOutcome.cancelledHere);
        await until(() => !h.queues.active);
        await settle();
        expect(h.sender.paths, [_inA, _inB]);
        expect(h.view.finished, isTrue);
        expect(h.view.total, 5);
        expect(h.view.delivered, 1);
        expect(h.item('A.TXT').outcome, TransferOutcome.saved);
        expect(h.item('b.txt').state, QueueItemState.done);
        expect(h.item('b.txt').outcome, TransferOutcome.cancelledHere);
      },
    );

    test('Q-5 Remove takes a pending one out of the total, and Cancel all '
        'after it does not', () async {
      h = Harness(probes: _probes());
      await h.submit([_inA, _inB, _inC]);
      await until(() => h.sender.busy);
      expect(h.view.total, 3);

      h.queues.removeItem(h.item('c.txt').id);
      expect(h.view.total, 2);
      expect(h.looseNames, ['A.TXT', 'b.txt']);

      h.queues.cancelAll();
      expect(h.view.total, 2);
      expect(h.item('b.txt').state, QueueItemState.notSent);
      h.sender.finish(TransferOutcome.cancelledHere);
      await until(() => !h.queues.active);
      await settle();
      expect(h.view.total, 2);
      expect(h.view.delivered, 0);
      expect(h.sender.paths, [_inA]);
    });

    test('Q-5 cancelling the item in course leaves it in the total as '
        'cancelled and the queue goes on', () async {
      h = Harness(probes: _probes());
      await h.submit([_inA, _inB]);
      await until(() => h.sender.busy);

      h.queues.cancelItem(h.item('A.TXT').id);
      h.sender.finish(TransferOutcome.cancelledHere);
      await _finishNext(h, TransferOutcome.saved);
      await until(() => !h.queues.active);
      await settle();

      expect(h.view.total, 2);
      expect(h.view.delivered, 1);
      expect(h.item('A.TXT').state, QueueItemState.done);
      expect(h.item('A.TXT').outcome, TransferOutcome.cancelledHere);
    });

    test('Q-5 the bytes counted as done never go down when Cancel all marks '
        'the pending ones', () async {
      h = Harness(probes: _probes());
      await h.submit([_inA, _inB, _inC, _inD]);
      await _finishNext(h, TransferOutcome.saved, size: 10);
      await until(() => h.sender.paths.length == 2);
      final before = h.view;

      h.queues.cancelAll();
      final after = h.view;

      expect(after.completedBytes, greaterThanOrEqualTo(before.completedBytes));
      expect(
        after.completedBytes + after.pendingKnownBytes,
        greaterThanOrEqualTo(before.completedBytes),
      );
      h.sender.finish(TransferOutcome.cancelledHere);
      await until(() => !h.queues.active);
    });
  });

  group(
    'Q-8, RF-285: the previous queues stay readable while a new one runs',
    () {
      test(
        'Q-8 previous is null at first, the finished view of the last '
        'queues while a new selection runs, and null again when it ends',
        () async {
          h = Harness(probes: _probes());
          expect(h.queues.previous, isNull);
          await h.submit([_inA, _inB]);
          expect(h.queues.previous, isNull);
          await _finishNext(h, TransferOutcome.saved);
          await _finishNext(h, TransferOutcome.saved);
          await until(() => !h.queues.active);
          final first = h.view;
          expect(h.queues.previous, isNull);

          await h.submit([_inC, _inD]);
          await until(() => h.sender.busy);
          final previous = h.queues.previous;
          expect(previous, isNotNull);
          expect(previous!.selectionId, first.selectionId);
          expect(previous.finished, isTrue);
          expect(previous.delivered, 2);
          expect(previous.total, 2);

          await _finishNext(h, TransferOutcome.saved);
          await _finishNext(h, TransferOutcome.saved);
          await until(() => !h.queues.active);
          await settle();
          expect(h.queues.previous, isNull);
        },
      );

      test(
        'Q-8 a single send after queues keeps them as previous, and a single '
        'send before queues leaves nothing',
        () async {
          h = Harness(probes: _probes());
          await h.submit([_inA]);
          await until(() => h.sender.busy);
          expect(h.queues.view, isNull);
          expect(h.queues.previous, isNull);
          h.sender.finish(TransferOutcome.saved);
          await until(() => !h.queues.active);

          await h.submit([_inB, _inC]);
          await until(() => h.sender.busy);
          expect(h.queues.previous, isNull);
          await _finishNext(h, TransferOutcome.saved);
          await _finishNext(h, TransferOutcome.unreadable);
          await until(() => !h.queues.active);
          final queues = h.view;

          await h.submit([_inD]);
          await until(() => h.sender.busy);
          expect(h.queues.view, isNull);
          final previous = h.queues.previous;
          expect(previous, isNotNull);
          expect(previous!.selectionId, queues.selectionId);
          expect(previous.delivered, 1);
          expect(previous.total, 2);

          h.sender.finish(TransferOutcome.saved);
          await until(() => !h.queues.active);
          await settle();
          expect(h.queues.previous, isNull);
        },
      );
    },
  );

  group('Q-10: the comparison key without dot segments', () {
    test('Q-10 a "." segment is dropped', () {
      final key = pathKey(r'C:\ruta\b.md');
      expect(pathKey(r'C:\ruta\.\b.md'), key);
      expect(pathKey(r'C:\.\ruta\.\.\b.md'), key);
      expect(pathKey(r'C:/ruta/./b.md'), key);
      expect(pathKey(r'C:\ruta\b.md\.'), key);
    });

    test('Q-10 a ".." segment takes out the one before it', () {
      final key = pathKey(r'C:\ruta\b.md');
      expect(pathKey(r'C:\ruta\x\..\b.md'), key);
      expect(pathKey(r'C:\ruta\x\y\..\..\b.md'), key);
      expect(pathKey(r'C:\otra\..\ruta\b.md'), key);
      expect(pathKey(r'C:\ruta\x\..\B.MD'), key);
      expect(pathKey(r'C:\ruta\x\..\c.md'), isNot(key));
    });

    test('Q-10 ".." never climbs above the drive root', () {
      expect(pathKey(r'C:\..\ruta\b.md'), pathKey(r'C:\ruta\b.md'));
      expect(pathKey(r'C:\..\..\..\ruta\b.md'), pathKey(r'C:\ruta\b.md'));
      expect(pathKey(r'C:\ruta\..'), pathKey(r'C:\'));
      expect(pathKey(r'C:\ruta\..\..'), pathKey(r'C:\'));
      expect(pathKey(r'D:\..\ruta\b.md'), isNot(pathKey(r'C:\ruta\b.md')));
    });

    test('Q-10 on a UNC path ".." never climbs above the share', () {
      final key = pathKey(r'\\srv\share\ruta\b.md');
      expect(pathKey(r'\\srv\share\ruta\.\b.md'), key);
      expect(pathKey(r'\\srv\share\x\..\ruta\b.md'), key);
      expect(pathKey(r'\\srv\share\..\ruta\b.md'), key);
      expect(pathKey(r'\\srv\share\..\..\ruta\b.md'), key);
      expect(pathKey(r'\\srv\other\ruta\b.md'), isNot(key));
      expect(pathKey(r'\\srv\share\..\other\ruta\b.md'), isNot(key));
    });

    test(r'Q-10 with \\?\ the drive and the UNC share are the root', () {
      final drive = pathKey(r'\\?\C:\ruta\b.md');
      expect(pathKey(r'\\?\C:\ruta\.\b.md'), drive);
      expect(pathKey(r'\\?\C:\x\..\ruta\b.md'), drive);
      expect(pathKey(r'\\?\C:\..\..\ruta\b.md'), drive);
      final unc = pathKey(r'\\?\UNC\srv\share\ruta\b.md');
      expect(pathKey(r'\\?\UNC\srv\share\.\ruta\b.md'), unc);
      expect(pathKey(r'\\?\UNC\srv\share\..\..\ruta\b.md'), unc);
      expect(pathKey(r'\\?\UNC\srv\other\ruta\b.md'), isNot(unc));
    });

    test('Q-10 names that only look like dots stay as they are', () {
      expect(pathKey(r'C:\ruta\..b.md'), isNot(pathKey(r'C:\ruta\b.md')));
      expect(pathKey(r'C:\ruta\...\b.md'), isNot(pathKey(r'C:\ruta\b.md')));
      expect(pathKey(r'C:\ruta\.git'), isNot(pathKey(r'C:\ruta\git')));
    });

    test(
      r'Q-10 ruta\.\b.md and ruta\b.md in one selection are one item',
      () async {
        const plain = r'C:\ruta\b.md';
        const dotted = r'C:\ruta\.\b.md';
        const climbed = r'C:\ruta\x\..\b.md';
        h = Harness(
          probes: {
            plain: file(5),
            dotted: file(5),
            climbed: file(5),
            _inA: file(1),
          },
        );

        expect(
          await h.submit([plain, dotted, climbed, _inA]),
          SelectionResult.started,
        );

        expect(h.view.total, 2);
        expect(h.looseNames, ['A.TXT', 'b.md']);
      },
    );
  });
}
