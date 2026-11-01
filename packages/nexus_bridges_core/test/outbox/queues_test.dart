import 'dart:async';

import 'package:nexus_bridges_core/src/outbox/outbox.dart';
import 'package:nexus_bridges_core/src/protocol/protocol.dart' show Limits;
import 'package:nexus_bridges_core/src/transfer/transfer.dart'
    show ReceiveFolderDestination, TransferOutcome;
import 'package:test/test.dart';

import 'queues_harness.dart';

const String inA = r'C:\in\A.TXT';
const String inB = r'C:\in\b.txt';
const String inZip = r'C:\in\z.zip';
const String inFolder = r'C:\in\Carpeta';
const String inLnk = r'C:\in\x.lnk';
const String inMissing = r'C:\in\zz-missing';

Map<String, ElementProbe> mixedProbes() => {
  inA: file(10),
  inB: file(20),
  inZip: file(30),
  inFolder: folder,
  inLnk: file(1),
};

Future<void> finishNext(
  Harness h,
  TransferOutcome outcome, {
  int size = 0,
  String? problemPath,
}) async {
  await until(() => h.sender.busy, reason: 'a send should be running');
  h.sender.finish(outcome, size: size, problemPath: problemPath);
}

void main() {
  late Harness h;

  tearDown(() async {
    await h.dispose();
  });

  group('E500: a selection holds at most 1 000 items (RF-309)', () {
    test('1 001 paths are refused with tooMany and nothing is sent', () async {
      h = Harness();
      final paths = [for (var i = 0; i < 1001; i++) 'C:\\in\\f$i.txt'];
      expect(await h.submit(paths), SelectionResult.tooMany);
      await settle();
      expect(h.sender.paths, isEmpty);
      expect(h.queues.view, isNull);
      expect(h.queues.active, isFalse);
      expect(h.queues.target, isNull);
    });

    test('1 000 paths are accepted as one selection', () async {
      h = Harness();
      final paths = [
        for (var i = 0; i < 1000; i++)
          'C:\\in\\f${i.toString().padLeft(4, '0')}.txt',
      ];
      for (final path in paths) {
        h.probes[path] = file(1);
      }
      expect(Limits.maxSelectionItems, 1000);
      expect(await h.submit(paths), SelectionResult.started);
      expect(h.view.total, 1000);
      await until(() => h.sender.paths.length == 1);
      expect(h.sender.paths.single, paths.first);
    });

    test(
      '1 001 paths are refused also while queues run to the same peer',
      () async {
        h = Harness(probes: {inA: file(1), inB: file(1)});
        await h.submit([inA, inB]);
        final paths = [for (var i = 0; i < 1001; i++) 'C:\\in\\g$i.txt'];
        expect(await h.submit(paths), SelectionResult.tooMany);
        expect(h.view.total, 2);
      },
    );
  });

  test('an empty selection is refused with empty', () async {
    h = Harness();
    expect(await h.submit([]), SelectionResult.empty);
    await settle();
    expect(h.queues.active, isFalse);
    expect(h.sender.paths, isEmpty);
  });

  group('E501: a single item without queues is a plain send (RF-291)', () {
    test('one file is sent without a queues view', () async {
      h = Harness(probes: {inA: file(10)});
      expect(await h.submit([inA]), SelectionResult.started);
      await until(() => h.sender.busy);
      expect(h.sender.paths, [inA]);
      expect(h.queues.view, isNull);
      expect(h.queues.active, isTrue);
      expect(h.queues.target, peerB);
      h.sender.finish(TransferOutcome.saved);
      await until(() => !h.queues.active);
      expect(h.queues.view, isNull);
      expect(h.queues.target, isNull);
    });

    test('one folder is also sent without a queues view', () async {
      h = Harness(probes: {inFolder: folder});
      expect(await h.submit([inFolder]), SelectionResult.started);
      await until(() => h.sender.busy);
      expect(h.sender.paths, [inFolder]);
      expect(h.queues.view, isNull);
    });

    test('a single item clears the finished view of the last queues', () async {
      h = Harness(probes: {inA: file(1), inB: file(1)});
      await h.submit([inA, inB]);
      await finishNext(h, TransferOutcome.saved);
      await finishNext(h, TransferOutcome.saved);
      await until(() => !h.queues.active);
      expect(h.view.finished, isTrue);
      expect(await h.submit([inA]), SelectionResult.started);
      expect(h.queues.view, isNull);
    });
  });

  group('E502: items are split into two queues in name order (RF-292)', () {
    test(
      'the example of the plan lands in the right queues and order',
      () async {
        h = Harness(probes: mixedProbes());
        expect(
          await h.submit([inB, inA, inZip, inFolder, inLnk, inMissing]),
          SelectionResult.started,
        );
        expect(h.looseNames, ['A.TXT', 'b.txt', 'x.lnk', 'zz-missing']);
        expect(h.bundleNames, ['Carpeta', 'z.zip']);
        expect(h.item('Carpeta').isFolder, isTrue);
        expect(h.item('Carpeta').isArchive, isFalse);
        expect(h.item('z.zip').isFolder, isFalse);
        expect(h.item('z.zip').isArchive, isTrue);
        expect(h.item('x.lnk').isFolder, isFalse);
        expect(h.item('zz-missing').isFolder, isFalse);
        expect(h.view.peerFingerprint, peerB);
        expect(h.view.peerName, 'B');
      },
    );

    test('3 files, a zip and 2 folders go out in the RF-293 order', () async {
      final probes = {
        r'C:\w\c.txt': file(3),
        r'C:\w\a.txt': file(1),
        r'C:\w\B.txt': file(2),
        r'C:\w\m.zip': file(4),
        r'C:\w\Zeta': folder,
        r'C:\w\alpha': folder,
      };
      h = Harness(probes: probes);
      await h.submit(probes.keys.toList());
      expect(h.looseNames, ['a.txt', 'B.txt', 'c.txt']);
      expect(h.bundleNames, ['alpha', 'm.zip', 'Zeta']);
      for (var i = 0; i < probes.length; i++) {
        await finishNext(h, TransferOutcome.saved);
      }
      await until(() => !h.queues.active);
      expect(h.sender.paths, [
        r'C:\w\a.txt',
        r'C:\w\B.txt',
        r'C:\w\c.txt',
        r'C:\w\alpha',
        r'C:\w\m.zip',
        r'C:\w\Zeta',
      ]);
      expect(h.sender.maxInFlight, 1);
      expect(h.view.finished, isTrue);
      expect(h.view.delivered, 6);
    });

    test('ties break by exact name and then by path', () async {
      final probes = {
        r'C:\y\a.txt': file(1),
        r'C:\x\a.txt': file(1),
        r'C:\x\A.txt': file(1),
        r'C:\x\b.txt': file(1),
      };
      h = Harness(probes: probes);
      await h.submit(probes.keys.toList());
      for (var i = 0; i < probes.length; i++) {
        await finishNext(h, TransferOutcome.saved);
      }
      await until(() => !h.queues.active);
      expect(h.sender.paths, [
        r'C:\x\A.txt',
        r'C:\x\a.txt',
        r'C:\y\a.txt',
        r'C:\x\b.txt',
      ]);
    });

    test(
      'a drive root goes with the folders and "other" with the files',
      () async {
        h = Harness(
          probes: {r'D:\': folder, r'C:\in\pipe': other, inA: file(1)},
        );
        await h.submit([r'D:\', r'C:\in\pipe', inA]);
        expect(h.view.bundles, hasLength(1));
        expect(h.view.bundles.single.isFolder, isTrue);
        expect(h.looseNames, ['A.TXT', 'pipe']);
      },
    );

    for (final root in [r'D:\', 'D:/', 'D:', r'e:\']) {
      test(
        'the drive root "$root" goes with the folders whatever the probe says',
        () async {
          h = Harness(probes: {root: other, inA: file(1)});
          await h.submit([root, inA]);
          expect(h.looseNames, ['A.TXT']);
          expect(h.view.bundles, hasLength(1));
          expect(h.view.bundles.single.isFolder, isTrue);
        },
      );
    }

    test('a drive root is not measured as a pending folder', () async {
      h = Harness(probes: {r'D:\': folder, inA: file(1), inFolder: folder});
      await h.submit([r'D:\', inA, inFolder]);
      await until(() => h.measure.calls.isNotEmpty);
      for (var round = 0; round < 3; round++) {
        for (final call in h.measure.calls) {
          call.complete(5);
        }
        await settle();
      }
      expect(h.measure.paths, [inFolder]);
    });

    test('a probe that throws leaves the item in the loose queue', () async {
      h = Harness(probes: {inA: file(1)}, throwingProbes: {inB});
      expect(await h.submit([inA, inB]), SelectionResult.started);
      expect(h.looseNames, ['A.TXT', 'b.txt']);
    });

    test(
      'names go through displayName while the sent path stays the same',
      () async {
        h = Harness(
          probes: {inA: file(1), inFolder: folder},
          displayName: (name) => 'visible $name',
        );
        await h.submit([inFolder, inA]);
        expect(h.looseNames, ['visible A.TXT']);
        expect(h.bundleNames, ['visible Carpeta']);
        await until(() => h.sender.busy);
        expect(h.sender.paths, [inA]);
      },
    );

    test('item ids are q1, q2 and so on', () async {
      h = Harness(probes: mixedProbes());
      await h.submit([inA, inB, inFolder]);
      final ids = {
        for (final item in [...h.view.loose, ...h.view.bundles]) item.id,
      };
      expect(ids, {'q1', 'q2', 'q3'});
    });
  });

  group('E503: every item is its own send (RF-294)', () {
    test(
      'each item gets its own send with a fresh target and the receive folder',
      () async {
        h = Harness(probes: {inA: file(1), inB: file(1), inFolder: folder});
        await h.submit([inA, inB, inFolder]);
        await finishNext(h, TransferOutcome.saved);
        h.targets[peerB] = targetFor(peerB, port: 60000);
        await finishNext(h, TransferOutcome.saved);
        await finishNext(h, TransferOutcome.saved);
        await until(() => !h.queues.active);
        expect(h.sender.paths, [inA, inB, inFolder]);
        expect(h.refreshes, 3);
        expect(h.sender.targets.first.port, 53530);
        expect(h.sender.targets.last.port, 60000);
        expect(
          h.sender.destinations,
          everyElement(isA<ReceiveFolderDestination>()),
        );
      },
    );

    test(
      'a declined item leaves the pending ones as not sent with declined',
      () async {
        h = Harness(probes: {inA: file(1), inB: file(1), inFolder: folder});
        await h.submit([inA, inB, inFolder]);
        await finishNext(h, TransferOutcome.declined);
        await until(() => !h.queues.active);
        expect(h.sender.paths, [inA]);
        expect(h.item('A.TXT').state, QueueItemState.done);
        expect(h.item('A.TXT').outcome, TransferOutcome.declined);
        for (final name in ['b.txt', 'Carpeta']) {
          expect(h.item(name).state, QueueItemState.notSent);
          expect(h.item(name).outcome, TransferOutcome.declined);
        }
        expect(h.view.finished, isTrue);
        expect(h.view.delivered, 0);
        expect(h.view.total, 3);
      },
    );
  });

  group('E504: item states and the finished view (RF-295)', () {
    test(
      'pending, in progress, done and the view kept after the end',
      () async {
        h = Harness(probes: {inA: file(1), inB: file(1), inZip: file(1)});
        await h.submit([inA, inB, inZip]);
        await until(() => h.sender.busy);
        expect(h.item('A.TXT').state, QueueItemState.inProgress);
        expect(h.item('b.txt').state, QueueItemState.pending);
        expect(h.item('z.zip').state, QueueItemState.pending);
        expect(h.view.finished, isFalse);
        final firstId = h.view.selectionId;
        await finishNext(h, TransferOutcome.saved);
        await until(() => h.sender.paths.length == 2);
        expect(h.item('A.TXT').state, QueueItemState.done);
        expect(h.item('A.TXT').outcome, TransferOutcome.saved);
        expect(h.item('b.txt').state, QueueItemState.inProgress);
        await finishNext(
          h,
          TransferOutcome.unreadable,
          problemPath: r'sub\locked.txt',
        );
        await finishNext(h, TransferOutcome.savedWithoutMark);
        await until(() => !h.queues.active);
        expect(h.item('b.txt').outcome, TransferOutcome.unreadable);
        expect(h.item('b.txt').problemPath, r'sub\locked.txt');
        expect(h.item('z.zip').outcome, TransferOutcome.savedWithoutMark);
        expect(h.view.finished, isTrue);
        expect(h.view.delivered, 2);
        expect(h.view.total, 3);
        expect(h.queues.target, isNull);
        await settle();
        expect(h.queues.view, isNotNull);
        expect(h.view.selectionId, firstId);
        expect(await h.submit([inA, inB]), SelectionResult.started);
        expect(h.view.selectionId, greaterThan(firstId));
        expect(h.view.total, 2);
        expect(h.view.finished, isFalse);
      },
    );

    test('changes are announced while the queues move', () async {
      h = Harness(probes: {inA: file(1), inB: file(1)});
      await h.submit([inA, inB]);
      await until(() => h.sender.busy);
      final before = h.changes;
      expect(before, greaterThan(0));
      await finishNext(h, TransferOutcome.saved);
      await until(() => h.sender.paths.length == 2);
      expect(h.changes, greaterThan(before));
    });
  });

  group('E505: cancelling the running item goes on with the next (RF-296)', () {
    test('cancelItem calls cancelCurrent and the next item starts', () async {
      h = Harness(probes: {inA: file(1), inB: file(1)});
      await h.submit([inA, inB]);
      await until(() => h.sender.busy);
      h.queues.cancelItem(h.item('A.TXT').id);
      expect(h.sender.cancels, 1);
      h.sender.finish(TransferOutcome.cancelledHere);
      await until(() => h.sender.paths.length == 2);
      expect(h.sender.paths, [inA, inB]);
      expect(h.item('A.TXT').outcome, TransferOutcome.cancelledHere);
      expect(h.item('b.txt').state, QueueItemState.inProgress);
    });

    test('cancelItem on a pending or unknown item does nothing', () async {
      h = Harness(probes: {inA: file(1), inB: file(1)});
      await h.submit([inA, inB]);
      await until(() => h.sender.busy);
      h.queues.cancelItem(h.item('b.txt').id);
      h.queues.cancelItem('q999');
      expect(h.sender.cancels, 0);
      expect(h.item('b.txt').state, QueueItemState.pending);
    });

    test('a cancelCurrent that throws does not escape', () async {
      h = Harness(probes: {inA: file(1), inB: file(1)});
      h.sender.throwOnCancel = true;
      await h.submit([inA, inB]);
      await until(() => h.sender.busy);
      expect(() => h.queues.cancelItem(h.item('A.TXT').id), returnsNormally);
      expect(() => h.queues.cancelAll(), returnsNormally);
    });
  });

  group('E506: a removed pending item is never sent (RF-297)', () {
    test('removeItem takes the item out of its queue', () async {
      h = Harness(probes: {inA: file(1), inB: file(1), inFolder: folder});
      await h.submit([inA, inB, inFolder]);
      await until(() => h.sender.busy);
      h.queues.removeItem(h.item('b.txt').id);
      expect(h.looseNames, ['A.TXT']);
      expect(h.view.total, 2);
      await finishNext(h, TransferOutcome.saved);
      await finishNext(h, TransferOutcome.saved);
      await until(() => !h.queues.active);
      expect(h.sender.paths, [inA, inFolder]);
      expect(h.view.delivered, 2);
    });

    test('removeItem ignores the running and the finished items', () async {
      h = Harness(probes: {inA: file(1), inB: file(1), inZip: file(1)});
      await h.submit([inA, inB, inZip]);
      await finishNext(h, TransferOutcome.saved);
      await until(() => h.sender.paths.length == 2);
      h.queues.removeItem(h.item('A.TXT').id);
      h.queues.removeItem(h.item('b.txt').id);
      expect(h.view.total, 3);
      expect(h.item('b.txt').state, QueueItemState.inProgress);
      expect(h.sender.cancels, 0);
    });
  });

  group('E507: the queue applies continuesAfter to every outcome (RF-298)', () {
    for (final outcome in TransferOutcome.values) {
      test('after ${outcome.name} the queue '
          '${continuesAfter(outcome) ? 'goes on' : 'stops'}', () async {
        h = Harness(probes: {inA: file(1), inB: file(1), inFolder: folder});
        await h.submit([inA, inB, inFolder]);
        await finishNext(h, outcome);
        if (continuesAfter(outcome)) {
          await until(() => h.sender.paths.length == 2);
          expect(h.item('b.txt').state, QueueItemState.inProgress);
          expect(h.item('Carpeta').state, QueueItemState.pending);
        } else {
          await until(() => !h.queues.active);
          expect(h.sender.paths, [inA]);
          for (final name in ['b.txt', 'Carpeta']) {
            expect(h.item(name).state, QueueItemState.notSent);
            expect(h.item(name).outcome, outcome);
          }
          expect(h.view.finished, isTrue);
        }
        expect(h.item('A.TXT').outcome, outcome);
      });
    }
  });

  group('E508: cancel all drops the pending items and cancels the running one '
      '(RF-301)', () {
    test('during queues', () async {
      h = Harness(probes: {inA: file(1), inB: file(1), inFolder: folder});
      await h.submit([inA, inB, inFolder]);
      await until(() => h.sender.busy);
      h.queues.cancelAll();
      expect(h.sender.cancels, 1);
      expect(h.looseNames, ['A.TXT']);
      expect(h.view.bundles, isEmpty);
      h.sender.finish(TransferOutcome.cancelledHere);
      await until(() => !h.queues.active);
      await settle();
      expect(h.sender.paths, [inA]);
      expect(h.view.finished, isTrue);
      expect(h.view.total, 1);
    });

    test('during a single send', () async {
      h = Harness(probes: {inA: file(1)});
      await h.submit([inA]);
      await until(() => h.sender.busy);
      h.queues.cancelAll();
      expect(h.sender.cancels, 1);
    });

    test('with nothing running it does nothing', () async {
      h = Harness();
      h.queues.cancelAll();
      expect(h.sender.cancels, 0);
      expect(h.queues.view, isNull);
    });
  });

  group('E509: selections to the same peer join the running queues (RF-290)', () {
    test(
      'new items go to the end of each queue, sorted among themselves',
      () async {
        final probes = {
          r'C:\in\m.txt': file(1),
          r'C:\in\n.txt': file(1),
          r'C:\in\Folder': folder,
          r'C:\in\b.txt': file(1),
          r'C:\in\a.txt': file(1),
          r'C:\in\z.zip': file(1),
          r'C:\in\A-folder': folder,
        };
        h = Harness(probes: probes);
        await h.submit([r'C:\in\n.txt', r'C:\in\Folder', r'C:\in\m.txt']);
        await until(() => h.sender.busy);
        final id = h.view.selectionId;
        expect(
          await h.submit([
            r'C:\in\z.zip',
            r'C:\in\b.txt',
            r'C:\in\A-folder',
            r'C:\in\a.txt',
          ]),
          SelectionResult.queued,
        );
        expect(h.looseNames, ['m.txt', 'n.txt', 'a.txt', 'b.txt']);
        expect(h.bundleNames, ['Folder', 'A-folder', 'z.zip']);
        expect(h.view.selectionId, id);
        expect(h.view.total, 7);
        for (var i = 0; i < 7; i++) {
          await finishNext(h, TransferOutcome.saved);
        }
        await until(() => !h.queues.active);
        expect(h.sender.paths, [
          r'C:\in\m.txt',
          r'C:\in\n.txt',
          r'C:\in\a.txt',
          r'C:\in\b.txt',
          r'C:\in\Folder',
          r'C:\in\A-folder',
          r'C:\in\z.zip',
        ]);
        expect(h.sender.maxInFlight, 1);
      },
    );

    test(
      'a file added while a folder is sending goes before the pending folders',
      () async {
        final probes = {
          r'C:\in\one.txt': file(1),
          r'C:\in\F1': folder,
          r'C:\in\F2': folder,
          r'C:\in\late.txt': file(1),
        };
        h = Harness(probes: probes);
        await h.submit([r'C:\in\F2', r'C:\in\one.txt', r'C:\in\F1']);
        await finishNext(h, TransferOutcome.saved);
        await until(() => h.sender.paths.length == 2);
        expect(h.sender.paths.last, r'C:\in\F1');
        expect(await h.submit([r'C:\in\late.txt']), SelectionResult.queued);
        await finishNext(h, TransferOutcome.saved);
        await until(() => h.sender.paths.length == 3);
        expect(h.sender.paths.last, r'C:\in\late.txt');
        await finishNext(h, TransferOutcome.saved);
        await until(() => h.sender.paths.length == 4);
        expect(h.sender.paths.last, r'C:\in\F2');
      },
    );

    test(
      'a single send in progress becomes queues with it in progress',
      () async {
        h = Harness(probes: {inA: file(1), inB: file(1), inFolder: folder});
        expect(await h.submit([inFolder]), SelectionResult.started);
        await until(() => h.sender.busy);
        expect(h.queues.view, isNull);
        expect(await h.submit([inB, inA]), SelectionResult.queued);
        expect(h.bundleNames, ['Carpeta']);
        expect(h.item('Carpeta').state, QueueItemState.inProgress);
        expect(h.looseNames, ['A.TXT', 'b.txt']);
        expect(h.item('A.TXT').state, QueueItemState.pending);
        expect(h.view.total, 3);
        for (var i = 0; i < 3; i++) {
          await finishNext(h, TransferOutcome.saved);
        }
        await until(() => !h.queues.active);
        expect(h.sender.paths, [inFolder, inA, inB]);
        expect(h.view.finished, isTrue);
        expect(h.view.delivered, 3);
      },
    );

    test('another peer is refused while a single send runs', () async {
      h = Harness(probes: {inA: file(1), inB: file(1)});
      await h.submit([inA]);
      await until(() => h.sender.busy);
      expect(
        await h.submit([inB], fingerprint: peerC),
        SelectionResult.otherTargetBusy,
      );
      expect(h.queues.target, peerB);
      expect(h.queues.view, isNull);
    });

    test(
      'another peer is refused while queues run and accepted after',
      () async {
        h = Harness(probes: {inA: file(1), inB: file(1), inZip: file(1)});
        await h.submit([inA, inB]);
        await until(() => h.sender.busy);
        expect(
          await h.submit([inZip, inA], fingerprint: peerC),
          SelectionResult.otherTargetBusy,
        );
        expect(h.view.peerFingerprint, peerB);
        expect(h.view.total, 2);
        await finishNext(h, TransferOutcome.saved);
        await finishNext(h, TransferOutcome.saved);
        await until(() => !h.queues.active);
        expect(h.sender.paths, [inA, inB]);
        expect(
          await h.submit([inZip, inA], fingerprint: peerC, peerName: 'C'),
          SelectionResult.started,
        );
        expect(h.view.peerFingerprint, peerC);
        expect(h.view.peerName, 'C');
        expect(h.queues.target, peerC);
      },
    );
  });

  group('noContact when there is no way to reach the peer (RF-298)', () {
    test('a send that returns null ends the item with noContact', () async {
      h = Harness(probes: {inA: file(1), inB: file(1)});
      await h.submit([inA, inB]);
      await until(() => h.sender.busy);
      h.sender.finishWithNull();
      await until(() => !h.queues.active);
      expect(h.item('A.TXT').state, QueueItemState.done);
      expect(h.item('A.TXT').outcome, TransferOutcome.noContact);
      expect(h.item('b.txt').state, QueueItemState.notSent);
      expect(h.item('b.txt').outcome, TransferOutcome.noContact);
      expect(h.sender.paths, [inA]);
    });

    test('a send that fails ends the item with noContact', () async {
      h = Harness(probes: {inA: file(1), inB: file(1)});
      await h.submit([inA, inB]);
      await until(() => h.sender.busy);
      h.sender.finishWithError();
      await until(() => !h.queues.active);
      expect(h.item('A.TXT').outcome, TransferOutcome.noContact);
      expect(h.item('b.txt').outcome, TransferOutcome.noContact);
    });

    test('a send that throws at once ends the item with noContact', () async {
      h = Harness(probes: {inA: file(1), inB: file(1)});
      h.sender.throwSynchronously = true;
      await h.submit([inA, inB]);
      await until(() => !h.queues.active);
      expect(h.item('A.TXT').outcome, TransferOutcome.noContact);
      expect(h.item('b.txt').state, QueueItemState.notSent);
    });

    test('a refresh without a target ends the item without sending', () async {
      h = Harness(probes: {inA: file(1), inB: file(1)});
      h.targets[peerB] = null;
      await h.submit([inA, inB]);
      await until(() => !h.queues.active);
      expect(h.sender.paths, isEmpty);
      expect(h.item('A.TXT').outcome, TransferOutcome.noContact);
      expect(h.item('b.txt').outcome, TransferOutcome.noContact);
      expect(h.item('b.txt').state, QueueItemState.notSent);
    });

    test('a refresh that throws ends the item with noContact', () async {
      h = Harness(probes: {inA: file(1), inB: file(1)});
      h.throwOnRefresh = true;
      await h.submit([inA, inB]);
      await until(() => !h.queues.active);
      expect(h.sender.paths, isEmpty);
      expect(h.item('A.TXT').outcome, TransferOutcome.noContact);
    });

    test(
      'a single send without a target ends and leaves nothing active',
      () async {
        h = Harness(probes: {inA: file(1)});
        h.targets[peerB] = null;
        expect(await h.submit([inA]), SelectionResult.started);
        await until(() => !h.queues.active);
        expect(h.queues.view, isNull);
        expect(h.queues.target, isNull);
      },
    );
  });

  group('stopFor stops the queues to one peer (RF-300)', () {
    test(
      'pending items become not sent with the reason and the queue ends',
      () async {
        h = Harness(probes: {inA: file(1), inB: file(1), inFolder: folder});
        await h.submit([inA, inB, inFolder]);
        await until(() => h.sender.busy);
        h.queues.stopFor(peerB, TransferOutcome.unpaired);
        expect(h.item('b.txt').state, QueueItemState.notSent);
        expect(h.item('b.txt').outcome, TransferOutcome.unpaired);
        expect(h.item('Carpeta').outcome, TransferOutcome.unpaired);
        expect(h.item('A.TXT').state, QueueItemState.inProgress);
        h.sender.finish(TransferOutcome.unpaired);
        await until(() => !h.queues.active);
        await settle();
        expect(h.sender.paths, [inA]);
        expect(h.view.finished, isTrue);
      },
    );

    test('stopFor another peer changes nothing', () async {
      h = Harness(probes: {inA: file(1), inB: file(1)});
      await h.submit([inA, inB]);
      await until(() => h.sender.busy);
      h.queues.stopFor(peerC, TransferOutcome.unpaired);
      expect(h.item('b.txt').state, QueueItemState.pending);
      await finishNext(h, TransferOutcome.saved);
      await until(() => h.sender.paths.length == 2);
    });
  });

  group('the gap between items (F10)', () {
    test('the default gap is 200 ms', () {
      h = Harness();
      expect(Limits.queueElementGap, const Duration(milliseconds: 200));
    });

    test('the next item waits for the gap after a finished one', () async {
      h = Harness(
        probes: {inA: file(1), inB: file(1)},
        gap: const Duration(hours: 1),
      );
      await h.submit([inA, inB]);
      await finishNext(h, TransferOutcome.saved);
      await settle();
      expect(h.sender.paths, [inA]);
      expect(h.item('b.txt').state, QueueItemState.pending);
      expect(h.queues.active, isTrue);
      await h.queues.close().timeout(const Duration(seconds: 5));
      await settle();
      expect(h.sender.paths, [inA]);
    });
  });

  group('close (RF-299)', () {
    test('a closed queue refuses new selections', () async {
      h = Harness(probes: {inA: file(1)});
      await h.queues.close();
      expect(await h.submit([inA]), SelectionResult.closed);
      expect(h.sender.paths, isEmpty);
    });

    test('closing drops the pending items and sends nothing more', () async {
      h = Harness(probes: {inA: file(1), inB: file(1), inFolder: folder});
      await h.submit([inA, inB, inFolder]);
      await until(() => h.sender.busy);
      final done = h.queues.changes.toList();
      await h.queues.close().timeout(const Duration(seconds: 5));
      await done.timeout(const Duration(seconds: 5));
      h.sender.finish(TransferOutcome.saved);
      await settle();
      expect(h.sender.paths, [inA]);
      expect(h.sender.cancels, 0);
      expect(await h.submit([inB]), SelectionResult.closed);
    });

    test('closing twice is harmless', () async {
      h = Harness();
      await h.queues.close();
      await h.queues.close();
    });

    test('closing while a selection is probed answers closed', () async {
      h = Harness(probes: {inA: file(1), inB: file(1)});
      h.probeGate = Completer<void>();
      final pending = h.submit([inA, inB]);
      await until(() => h.probesStarted == 1);
      final closing = h.queues.close();
      h.probeGate!.complete();
      expect(await pending, SelectionResult.closed);
      await closing.timeout(const Duration(seconds: 5));
      await settle();
      expect(h.sender.paths, isEmpty);
    });
  });

  group('selections submitted at the same time (RF-290)', () {
    test('a second selection to the same peer joins the first', () async {
      h = Harness(probes: {inA: file(1), inB: file(1), inZip: file(1)});
      h.probeGate = Completer<void>();
      final first = h.submit([inB, inA]);
      final second = h.submit([inZip]);
      await until(() => h.probesStarted >= 1);
      h.probeGate!.complete();
      expect(await first, SelectionResult.started);
      expect(await second, SelectionResult.queued);
      expect(h.looseNames, ['A.TXT', 'b.txt']);
      expect(h.bundleNames, ['z.zip']);
    });

    test('a second selection to another peer is refused', () async {
      h = Harness(probes: {inA: file(1), inB: file(1), inZip: file(1)});
      h.probeGate = Completer<void>();
      final first = h.submit([inB, inA]);
      final second = h.submit([inZip], fingerprint: peerC);
      await until(() => h.probesStarted >= 1);
      h.probeGate!.complete();
      expect(await first, SelectionResult.started);
      expect(await second, SelectionResult.otherTargetBusy);
      expect(h.view.peerFingerprint, peerB);
      expect(h.view.total, 2);
    });
  });

  test('the log never carries paths or names', () async {
    const secretFile = r'C:\Users\David\private-report.txt';
    const secretFolder = r'C:\Users\David\SecretProject';
    const secretArchive = r'C:\Users\David\tax-2026.zip';
    const brokenProbe = r'C:\Users\David\weird-entry';
    h = Harness(
      probes: {
        secretFile: file(5),
        secretFolder: folder,
        secretArchive: file(9),
      },
      throwingProbes: {brokenProbe},
    );
    await h.submit([secretFile, secretFolder, secretArchive, brokenProbe]);
    await until(() => h.measure.calls.isNotEmpty);
    h.measure.calls.first.fail();
    await finishNext(h, TransferOutcome.saved);
    await until(() => h.sender.paths.length == 2);
    h.sender.finishWithError();
    await until(() => !h.queues.active);
    await h.submit([secretFolder, secretFile]);
    h.queues.cancelAll();
    h.sender.finish(TransferOutcome.cancelledHere);
    await until(() => !h.queues.active);
    h.sender.throwSynchronously = true;
    await h.submit([secretFile, secretArchive]);
    await until(() => !h.queues.active);
    await h.queues.close();
    expect(h.logs, isNotEmpty);
    for (final line in h.logs) {
      for (final fragment in [
        r'C:\',
        'Users',
        'David',
        'private-report',
        'SecretProject',
        'tax-2026',
        'weird-entry',
        'secret',
      ]) {
        expect(line, isNot(contains(fragment)), reason: 'log line: $line');
      }
    }
  });
}
