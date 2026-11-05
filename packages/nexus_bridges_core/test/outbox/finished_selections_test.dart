import 'dart:async';

import 'package:nexus_bridges_core/src/outbox/outbox.dart';
import 'package:nexus_bridges_core/src/transfer/transfer.dart'
    show
        ReceiveFolderDestination,
        SendDestination,
        SharedFolderDestination,
        TransferOutcome;
import 'package:test/test.dart';

import 'queues_harness.dart';

const String inA = r'C:\in\a.txt';
const String inB = r'C:\in\b.txt';
const String inC = r'C:\in\c.txt';
const String inD = r'C:\in\d.txt';
const String inE = r'C:\in\e.txt';

final SharedFolderDestination docs = SharedFolderDestination(
  rootId: '1' * 32,
  rootName: 'docs',
  path: const ['sub'],
);

final class Bench {
  Bench(Map<String, ElementProbe> probes) : h = Harness(probes: probes) {
    subscription = h.queues.finishedSelections.listen(events.add);
  }

  final Harness h;
  final List<SelectionFinished> events = [];
  late final StreamSubscription<SelectionFinished> subscription;

  Future<SelectionResult> submit(
    List<String> paths, {
    SendDestination destination = const ReceiveFolderDestination(),
  }) => h.queues.submit(
    peerB,
    paths,
    refresh: h.refreshFor(peerB),
    peerName: 'B',
    destination: destination,
  );

  Future<void> finishNext(TransferOutcome outcome, {int size = 0}) async {
    await until(() => h.sender.busy, reason: 'a send should be running');
    h.sender.finish(outcome, size: size);
  }

  Future<void> drained() async {
    await until(() => !h.queues.active, reason: 'the queue should end');
    await settle();
  }

  Future<void> dispose() async {
    await subscription.cancel();
    await h.dispose();
  }
}

void main() {
  late Bench bench;

  tearDown(() => bench.dispose());

  group('SendQueues.finishedSelections (points 16 and 24)', () {
    test('three saved files give one event with three results', () async {
      bench = Bench({inA: file(1), inB: file(2), inC: file(3)});

      await bench.submit([inA, inB, inC], destination: docs);
      await bench.finishNext(TransferOutcome.saved, size: 1);
      await bench.finishNext(TransferOutcome.saved, size: 2);
      await settle();
      expect(bench.events, isEmpty);
      await bench.finishNext(TransferOutcome.saved, size: 3);
      await bench.drained();

      final event = bench.events.single;
      expect(event.fingerprint, peerB);
      expect(event.itemCount, 3);
      expect(event.delivered, 3);
      expect(event.bytes, 6);
      expect(event.results, hasLength(3));
      expect(event.destination, same(docs));
    });

    test('a single element is a selection of one', () async {
      bench = Bench({inA: file(9)});

      await bench.submit([inA]);
      await bench.finishNext(TransferOutcome.saved, size: 9);
      await bench.drained();

      final event = bench.events.single;
      expect(event.itemCount, 1);
      expect(event.delivered, 1);
      expect(event.destination, isA<ReceiveFolderDestination>());
    });

    test('savedWithoutMark counts as delivered', () async {
      bench = Bench({inA: file(1), inB: file(1)});

      await bench.submit([inA, inB]);
      await bench.finishNext(TransferOutcome.savedWithoutMark);
      await bench.finishNext(TransferOutcome.saved);
      await bench.drained();

      expect(bench.events.single.delivered, 2);
    });

    test('an element that fails and lets the queue go on counts as not '
        'delivered and keeps its result in order', () async {
      bench = Bench({inA: file(1), inB: file(2), inC: file(3)});

      await bench.submit([inA, inB, inC]);
      await bench.finishNext(TransferOutcome.saved, size: 1);
      await bench.finishNext(TransferOutcome.blockedType, size: 0);
      await bench.finishNext(TransferOutcome.saved, size: 3);
      await bench.drained();

      final event = bench.events.single;
      expect(event.delivered, 2);
      expect(event.itemCount, 3);
      expect(event.results.map((r) => r.outcome), [
        TransferOutcome.saved,
        TransferOutcome.blockedType,
        TransferOutcome.saved,
      ]);
    });

    test('an outcome that stops the queue sends one event with the rest not '
        'sent', () async {
      bench = Bench({inA: file(1), inB: file(2), inC: file(3)});

      await bench.submit([inA, inB, inC], destination: docs);
      await bench.finishNext(TransferOutcome.destinationLost);
      await bench.drained();

      final event = bench.events.single;
      expect(event.itemCount, 3);
      expect(event.delivered, 0);
      expect(event.results, hasLength(3));
      expect(event.results.first.outcome, TransferOutcome.destinationLost);
      expect(
        event.results.skip(1).map((r) => r.outcome),
        everyElement(isNot(TransferOutcome.saved)),
      );
    });

    test('a send that gives no result still ends the selection', () async {
      bench = Bench({inA: file(1)});

      await bench.submit([inA]);
      await until(() => bench.h.sender.busy);
      bench.h.sender.finishWithNull();
      await bench.drained();

      final event = bench.events.single;
      expect(event.delivered, 0);
      expect(event.itemCount, 1);
      expect(event.results.single.peerFingerprint, peerB);
    });

    test('a send that throws still ends the selection', () async {
      bench = Bench({inA: file(1), inB: file(1)});

      await bench.submit([inA, inB]);
      await until(() => bench.h.sender.busy);
      bench.h.sender.finishWithError();
      await bench.drained();

      expect(bench.events, hasLength(1));
      expect(bench.events.single.delivered, 0);
      expect(bench.events.single.itemCount, 2);
    });

    test('each submit is followed apart even when it joins running queues '
        '(D-13)', () async {
      bench = Bench({inA: file(1), inB: file(2), inC: file(4), inD: file(8)});

      await bench.submit([inA, inB]);
      await until(() => bench.h.sender.busy);
      expect(
        await bench.submit([inC, inD], destination: docs),
        SelectionResult.queued,
      );
      await bench.finishNext(TransferOutcome.saved, size: 1);
      await bench.finishNext(TransferOutcome.saved, size: 2);
      await until(() => bench.events.length == 1, reason: 'first selection');
      await bench.finishNext(TransferOutcome.saved, size: 4);
      await bench.finishNext(TransferOutcome.saved, size: 8);
      await bench.drained();

      expect(bench.events, hasLength(2));
      expect(bench.events[0].itemCount, 2);
      expect(bench.events[0].bytes, 3);
      expect(bench.events[0].destination, isA<ReceiveFolderDestination>());
      expect(bench.events[1].itemCount, 2);
      expect(bench.events[1].bytes, 12);
      expect(bench.events[1].destination, same(docs));
    });

    test(
      'removing a pending element lowers the total of its selection',
      () async {
        bench = Bench({inA: file(1), inB: file(2), inC: file(4)});

        await bench.submit([inA, inB, inC]);
        await until(() => bench.h.sender.busy);
        bench.h.queues.removeItem(bench.h.item('c.txt').id);
        await bench.finishNext(TransferOutcome.saved, size: 1);
        await bench.finishNext(TransferOutcome.saved, size: 2);
        await bench.drained();

        final event = bench.events.single;
        expect(event.itemCount, 2);
        expect(event.delivered, 2);
        expect(event.bytes, 3);
      },
    );

    test('removing the last pending element while the others are done ends '
        'the selection', () async {
      bench = Bench({inA: file(1), inB: file(2)});

      await bench.submit([inA, inB]);
      await bench.finishNext(TransferOutcome.saved, size: 1);
      await until(() => bench.h.sender.paths.length == 2);
      await bench.finishNext(TransferOutcome.saved, size: 2);
      await bench.drained();

      expect(bench.events, hasLength(1));
    });

    test('never emits twice for one selection', () async {
      bench = Bench({inA: file(1), inB: file(1)});

      await bench.submit([inA, inB]);
      await bench.finishNext(TransferOutcome.saved);
      await bench.finishNext(TransferOutcome.saved);
      await bench.drained();
      await settle();

      expect(bench.events, hasLength(1));
    });

    test('a repeated path counts once', () async {
      bench = Bench({inA: file(5)});

      await bench.submit([inA, inA]);
      await bench.finishNext(TransferOutcome.saved, size: 5);
      await bench.drained();

      expect(bench.events.single.itemCount, 1);
    });

    test('selections of 200 elements end in one single event', () async {
      final paths = [for (var i = 0; i < 200; i++) 'C:\\in\\n$i.txt'];
      bench = Bench({for (final path in paths) path: file(1)});

      await bench.submit(paths, destination: docs);
      for (var i = 0; i < 200; i++) {
        await bench.finishNext(TransferOutcome.saved, size: 1);
        await until(
          () => !bench.h.sender.busy || bench.h.sender.paths.length > i + 1,
        );
      }
      await bench.drained();

      expect(bench.events, hasLength(1));
      expect(bench.events.single.itemCount, 200);
      expect(bench.events.single.delivered, 200);
      expect(bench.events.single.bytes, 200);
    });

    test(
      'a second selection after the first ended has its own event',
      () async {
        bench = Bench({inA: file(1), inE: file(2)});

        await bench.submit([inA]);
        await bench.finishNext(TransferOutcome.saved, size: 1);
        await bench.drained();
        await bench.submit([inE]);
        await bench.finishNext(TransferOutcome.declined);
        await bench.drained();

        expect(bench.events, hasLength(2));
        expect(bench.events[1].delivered, 0);
        expect(bench.events[1].selectionId, isNot(bench.events[0].selectionId));
      },
    );

    test('closing the queues with pending elements does not throw', () async {
      bench = Bench({inA: file(1), inB: file(1)});

      await bench.submit([inA, inB]);
      await until(() => bench.h.sender.busy);
      final closing = bench.h.queues.close();
      bench.h.sender.finish(TransferOutcome.cancelledHere);

      await expectLater(closing, completes);
    });
  });
}
