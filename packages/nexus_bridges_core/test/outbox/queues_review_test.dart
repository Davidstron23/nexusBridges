import 'package:nexus_bridges_core/src/outbox/outbox.dart';
import 'package:nexus_bridges_core/src/transfer/transfer.dart'
    show TransferOutcome;
import 'package:test/test.dart';

import 'queues_harness.dart';

const String inA = r'C:\in\a.txt';
const String inB = r'C:\in\b.txt';
const String inC = r'C:\in\c.txt';

Future<void> finishNext(Harness h, TransferOutcome outcome) async {
  await until(() => h.sender.busy, reason: 'a send should be running');
  h.sender.finish(outcome);
}

void main() {
  late Harness h;

  tearDown(() async {
    await h.dispose();
  });

  group('Q-5: a selection holds each element once', () {
    test('the same file written four ways is sent once', () async {
      h = Harness(probes: {inA: file(5), inB: file(6)});

      expect(
        await h.submit([
          inA,
          r'C:\IN\A.TXT',
          'C:/in/a.txt',
          r'C:\in\a.txt\',
          inB,
        ]),
        SelectionResult.started,
      );
      await finishNext(h, TransferOutcome.saved);
      await finishNext(h, TransferOutcome.saved);
      await until(() => !h.queues.active);

      expect(h.sender.paths, [inA, inB]);
      expect(h.view.total, 2);
      expect(h.looseNames, ['a.txt', 'b.txt']);
    });

    test('the first spelling is the one that is kept and the repeated ones '
        'are not even probed', () async {
      h = Harness(probes: {r'C:\IN\A.TXT': file(5), inB: file(6)});

      await h.submit([r'C:\IN\A.TXT', inA, inB]);
      await finishNext(h, TransferOutcome.saved);
      await finishNext(h, TransferOutcome.saved);

      expect(h.sender.paths, [r'C:\IN\A.TXT', inB]);
      expect(h.probesStarted, 2);
    });

    test('several spellings of one element make a plain single send', () async {
      h = Harness(probes: {inA: file(5)});

      expect(await h.submit([inA, r'C:\IN\A.TXT']), SelectionResult.started);
      await finishNext(h, TransferOutcome.saved);
      await until(() => !h.queues.active);

      expect(h.sender.paths, [inA]);
      expect(h.queues.view, isNull);
    });

    test('Q-6 the dotless i and the dotted i are two elements', () async {
      h = Harness(
        probes: {
          r'C:\in\ı.txt': file(1),
          r'C:\in\i.txt': file(1),
          r'C:\in\I.TXT': file(1),
        },
      );

      await h.submit([r'C:\in\ı.txt', r'C:\in\i.txt', r'C:\in\I.TXT']);
      await finishNext(h, TransferOutcome.saved);
      await finishNext(h, TransferOutcome.saved);
      await until(() => !h.queues.active);

      expect(h.sender.paths, hasLength(2));
      expect(h.view.total, 2);
    });

    test('Q-6 straße and STRASSE are two elements', () async {
      h = Harness(
        probes: {r'C:\in\straße.txt': file(1), r'C:\in\STRASSE.txt': file(1)},
      );

      await h.submit([r'C:\in\straße.txt', r'C:\in\STRASSE.txt']);
      await finishNext(h, TransferOutcome.saved);
      await finishNext(h, TransferOutcome.saved);

      expect(h.sender.paths, [r'C:\in\STRASSE.txt', r'C:\in\straße.txt']);
    });

    test(
      'adding to the running queues drops what is already pending',
      () async {
        h = Harness(probes: {inA: file(1), inB: file(1), inC: file(1)});
        await h.submit([inA, inB]);
        await until(() => h.sender.busy);

        expect(
          await h.submit([r'C:\IN\B.TXT', 'C:/in/c.txt', inC]),
          SelectionResult.queued,
        );

        expect(h.looseNames, ['a.txt', 'b.txt', 'c.txt']);
        expect(h.view.total, 3);
        for (var i = 0; i < 3; i++) {
          await finishNext(h, TransferOutcome.saved);
        }
        await until(() => !h.queues.active);
        expect(h.sender.paths, [inA, inB, 'C:/in/c.txt']);
      },
    );

    test('adding only what is already pending changes nothing', () async {
      h = Harness(probes: {inA: file(1), inB: file(1)});
      await h.submit([inA, inB]);
      await until(() => h.sender.busy);
      final before = h.view;
      final changesBefore = h.changes;
      final probesBefore = h.probesStarted;

      expect(await h.submit([r'C:\IN\B.TXT']), SelectionResult.queued);
      await settle();

      expect(h.view, before);
      expect(h.changes, changesBefore);
      expect(h.probesStarted, probesBefore + 1);
    });

    test('an element in progress or finished can be added again', () async {
      h = Harness(probes: {inA: file(1), inB: file(1)});
      await h.submit([inA, inB]);
      await until(() => h.sender.busy);
      await finishNext(h, TransferOutcome.saved);
      await until(() => h.sender.paths.length == 2);

      expect(await h.submit([inA, inB]), SelectionResult.queued);

      expect(h.looseNames, ['a.txt', 'b.txt', 'a.txt', 'b.txt']);
      expect(h.view.total, 4);
    });
  });

  group('E591: cancelling can end the queue when the sender says so', () {
    test('a cancel that ends the queue leaves the pending ones not sent, '
        'cancelled here, and sends nothing more', () async {
      h = Harness(probes: {inA: file(1), inB: file(1), inC: file(1)});
      h.sender.cancelEndsQueue = true;
      await h.submit([inA, inB, inC]);
      await until(() => h.sender.busy);

      h.queues.cancelItem(h.item('a.txt').id);
      h.sender.finish(TransferOutcome.cancelledHere);
      await until(() => !h.queues.active);
      await settle();

      expect(h.sender.paths, [inA]);
      expect(h.item('a.txt').state, QueueItemState.done);
      expect(h.item('a.txt').outcome, TransferOutcome.cancelledHere);
      for (final name in ['b.txt', 'c.txt']) {
        expect(h.item(name).state, QueueItemState.notSent);
        expect(h.item(name).outcome, TransferOutcome.cancelledHere);
      }
      expect(h.view.finished, isTrue);
      expect(h.view.delivered, 0);
    });

    test(
      'a cancel the sender says is harmless goes on with the next one',
      () async {
        h = Harness(probes: {inA: file(1), inB: file(1)});
        h.sender.cancelEndsQueue = false;
        await h.submit([inA, inB]);
        await until(() => h.sender.busy);

        h.queues.cancelItem(h.item('a.txt').id);
        h.sender.finish(TransferOutcome.cancelledHere);
        await finishNext(h, TransferOutcome.saved);
        await until(() => !h.queues.active);

        expect(h.sender.paths, [inA, inB]);
        expect(h.item('b.txt').outcome, TransferOutcome.saved);
      },
    );

    test(
      'a cancel that came too late and left the element saved goes on',
      () async {
        h = Harness(probes: {inA: file(1), inB: file(1)});
        h.sender.cancelEndsQueue = true;
        await h.submit([inA, inB]);
        await until(() => h.sender.busy);

        h.queues.cancelItem(h.item('a.txt').id);
        h.sender.finish(TransferOutcome.saved);
        await finishNext(h, TransferOutcome.saved);
        await until(() => !h.queues.active);

        expect(h.sender.paths, [inA, inB]);
        expect(h.view.delivered, 2);
      },
    );

    test('the sender is asked only when an element is cancelled', () async {
      h = Harness(probes: {inA: file(1), inB: file(1)});
      h.sender.cancelEndsQueue = true;
      await h.submit([inA, inB]);
      await finishNext(h, TransferOutcome.saved);
      await finishNext(h, TransferOutcome.saved);
      await until(() => !h.queues.active);

      expect(h.item('b.txt').outcome, TransferOutcome.saved);
      expect(h.view.delivered, 2);
    });

    test('cancel all ends the queue as before', () async {
      h = Harness(probes: {inA: file(1), inB: file(1)});
      h.sender.cancelEndsQueue = true;
      await h.submit([inA, inB]);
      await until(() => h.sender.busy);

      h.queues.cancelAll();
      h.sender.finish(TransferOutcome.cancelledHere);
      await until(() => !h.queues.active);

      expect(h.sender.paths, [inA]);
      expect(h.view.total, 1);
    });
  });
}
