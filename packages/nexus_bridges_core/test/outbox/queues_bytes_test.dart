import 'package:nexus_bridges_core/src/outbox/outbox.dart';
import 'package:nexus_bridges_core/src/protocol/protocol.dart' show Limits;
import 'package:nexus_bridges_core/src/transfer/transfer.dart'
    show TransferOutcome;
import 'package:test/test.dart';

import 'queues_harness.dart';

const int placeholder = 67108864;

const String inA = r'C:\in\a.txt';
const String inB = r'C:\in\b.txt';
const String inC = r'C:\in\c.txt';
const String inF1 = r'C:\in\F1';
const String inF2 = r'C:\in\F2';
const String inZip = r'C:\in\m.zip';

Future<void> finishNext(
  Harness h,
  TransferOutcome outcome, {
  int size = 0,
}) async {
  await until(() => h.sender.busy, reason: 'a send should be running');
  h.sender.finish(outcome, size: size);
}

void main() {
  late Harness h;

  tearDown(() async {
    await h.dispose();
  });

  group('bytes of the selection (DP-25)', () {
    test('completed, pending and current bytes follow each item', () async {
      h = Harness(probes: {inA: file(100), inB: file(200), inF1: folder});
      await h.submit([inF1, inB, inA]);
      await until(() => h.sender.busy);
      expect(h.view.completedBytes, 0);
      expect(h.view.currentProbeSize, 100);
      expect(h.view.pendingKnownBytes, 200 + placeholder);
      await finishNext(h, TransferOutcome.saved, size: 150);
      await until(() => h.sender.paths.length == 2);
      expect(h.view.completedBytes, 150);
      expect(h.view.currentProbeSize, 200);
      expect(h.view.pendingKnownBytes, placeholder);
      await finishNext(h, TransferOutcome.saved);
      await until(() => h.sender.paths.length == 3);
      expect(h.view.completedBytes, 350);
      expect(h.view.pendingKnownBytes, 0);
      await finishNext(h, TransferOutcome.saved, size: 5000);
      await until(() => !h.queues.active);
      expect(h.view.completedBytes, 5350);
      expect(h.view.pendingKnownBytes, 0);
      expect(h.view.currentProbeSize, isNull);
    });

    test('items that end without being sent count as completed', () async {
      h = Harness(probes: {inA: file(100), inB: file(200), inC: file(300)});
      await h.submit([inA, inB, inC]);
      await finishNext(h, TransferOutcome.declined);
      await until(() => !h.queues.active);
      expect(h.view.completedBytes, 600);
      expect(h.view.pendingKnownBytes, 0);
      expect(h.view.currentProbeSize, isNull);
    });

    test(
      'a removed item stops counting and a file without size counts 0',
      () async {
        h = Harness(
          probes: {
            inA: file(100),
            inB: file(200),
            inC: missing,
            inZip: file(7),
          },
        );
        await h.submit([inA, inB, inC, inZip]);
        await until(() => h.sender.busy);
        expect(h.view.pendingKnownBytes, 200 + 7);
        h.queues.removeItem(h.item('b.txt').id);
        expect(h.view.pendingKnownBytes, 7);
        expect(h.view.completedBytes, 0);
      },
    );

    test('the folder placeholder is 64 MiB', () {
      h = Harness();
      expect(Limits.queueFolderPlaceholderBytes, placeholder);
    });
  });

  group('E579: pending folders are measured in the background (clarify 1)', () {
    test('one at a time, 64 MiB until measured and then their size', () async {
      h = Harness(probes: {inA: file(10), inF1: folder, inF2: folder});
      await h.submit([inF2, inA, inF1]);
      await until(() => h.measure.calls.isNotEmpty);
      await settle();
      expect(h.measure.paths, [inF1]);
      expect(h.view.pendingKnownBytes, 2 * placeholder);
      expect(h.view.currentProbeSize, 10);
      final before = h.changes;
      h.measure.calls[0].complete(1000);
      await until(() => h.view.pendingKnownBytes == 1000 + placeholder);
      expect(h.changes, greaterThan(before));
      await until(() => h.measure.calls.length == 2);
      expect(h.measure.paths, [inF1, inF2]);
      h.measure.calls[1].complete(2000);
      await until(() => h.view.pendingKnownBytes == 3000);
      await settle();
      expect(h.measure.calls, hasLength(2));
      expect(h.sender.paths, [inA]);
    });

    test(
      'a measure without result or that fails keeps the placeholder',
      () async {
        h = Harness(probes: {inA: file(10), inF1: folder, inF2: folder});
        await h.submit([inA, inF1, inF2]);
        await until(() => h.measure.calls.isNotEmpty);
        h.measure.calls[0].fail();
        await until(() => h.measure.calls.length == 2);
        h.measure.calls[1].complete(null);
        await settle();
        expect(h.view.pendingKnownBytes, 2 * placeholder);
        expect(h.measure.calls, hasLength(2));
      },
    );

    test('files and archives are never measured', () async {
      h = Harness(probes: {inA: file(10), inZip: file(20), inF1: folder});
      await h.submit([inA, inZip, inF1]);
      await until(() => h.measure.calls.isNotEmpty);
      await settle();
      expect(h.measure.paths, [inF1]);
    });

    test('folders added to running queues are measured too', () async {
      h = Harness(probes: {inA: file(10), inB: file(10), inF1: folder});
      await h.submit([inA, inB]);
      await until(() => h.sender.busy);
      expect(h.measure.calls, isEmpty);
      expect(await h.submit([inF1]), SelectionResult.queued);
      await until(() => h.measure.calls.isNotEmpty);
      expect(h.measure.paths, [inF1]);
      h.measure.calls[0].complete(42);
      await until(() => h.view.pendingKnownBytes == 10 + 42);
    });

    test('removing the pending folder aborts its measure', () async {
      h = Harness(probes: {inA: file(10), inF1: folder, inF2: folder});
      await h.submit([inA, inF1, inF2]);
      await until(() => h.measure.calls.isNotEmpty);
      h.queues.removeItem(h.item('F1').id);
      expect(h.measure.calls[0].abort.aborted, isTrue);
      await until(() => h.measure.calls.length == 2);
      expect(h.measure.calls[1].path, inF2);
      expect(h.view.pendingKnownBytes, placeholder);
    });

    test('cancel all aborts the measure', () async {
      h = Harness(probes: {inA: file(10), inF1: folder, inF2: folder});
      await h.submit([inA, inF1, inF2]);
      await until(() => h.measure.calls.isNotEmpty);
      h.queues.cancelAll();
      expect(h.measure.calls[0].abort.aborted, isTrue);
      await settle();
      expect(h.measure.calls, hasLength(1));
    });

    test('close aborts the measure', () async {
      h = Harness(probes: {inA: file(10), inF1: folder});
      await h.submit([inA, inF1]);
      await until(() => h.measure.calls.isNotEmpty);
      await h.queues.close().timeout(const Duration(seconds: 5));
      expect(h.measure.calls[0].abort.aborted, isTrue);
    });

    test('a stopped queue aborts the measure of its pending folders', () async {
      h = Harness(probes: {inA: file(10), inF1: folder, inF2: folder});
      await h.submit([inA, inF1, inF2]);
      await until(() => h.measure.calls.isNotEmpty);
      await finishNext(h, TransferOutcome.busy);
      await until(() => !h.queues.active);
      expect(h.measure.calls[0].abort.aborted, isTrue);
      await settle();
      expect(h.measure.calls, hasLength(1));
    });
  });
}
