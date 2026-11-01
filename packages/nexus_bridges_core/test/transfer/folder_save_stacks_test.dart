@TestOn('windows')
library;

import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:nexus_bridges_core/src/protocol/protocol.dart';
import 'package:nexus_bridges_core/src/transfer/folder_writer.dart'
    show ClearHidden, MarkFile;
import 'package:nexus_bridges_core/src/transfer/transfer.dart';
import 'package:nexus_bridges_core/src/transfer/windows_shell.dart'
    show revealPlanFor;
import 'package:test/test.dart';
import 'package:win32/win32.dart';

import 'folder_writer_support.dart'
    show content, failClearHidden, failMarkOfTwo, readMark;
import 'transfer_stacks_harness.dart';

const Timeout long = Timeout(Duration(seconds: 90));

const int kib = 1024;

final blocked =
    FILE_ATTRIBUTE_READONLY | FILE_ATTRIBUTE_HIDDEN | FILE_ATTRIBUTE_SYSTEM;

int attributesOf(String path) => using((arena) {
  final Win32Result(:value) = GetFileAttributes(arena.pcwstr(path));
  return value;
});

final class RecordingRevealer implements FolderRevealer {
  final List<String> paths = [];

  @override
  Future<RevealResult> reveal(String filePath) async {
    paths.add(filePath);
    return RevealResult.shown;
  }
}

Map<String, String> snapshotOf(String root) {
  final result = <String, String>{};
  for (final entity in Directory(
    root,
  ).listSync(recursive: true, followLinks: false)) {
    final stat = entity.statSync();
    final relative = entity.path.substring(root.length + 1).toLowerCase();
    result[relative] =
        '${stat.type}|${stat.size}|${stat.modified.millisecondsSinceEpoch}';
  }
  return result;
}

Future<String> twoBigFiles(TransferStack a, String name) async {
  final root = '${a.sourceDir}\\$name';
  Directory(root).createSync(recursive: true);
  File('$root\\f1.bin').writeAsBytesSync(content(1, 100 * kib));
  File('$root\\f2.bin').writeAsBytesSync(content(2, 100 * kib));
  return root;
}

Future<void> cleanFolder(TransferStack b) async {
  await eventually(
    () => !Directory(b.tempSub).existsSync() && b.journal.folders.isEmpty,
    reason: '${b.name} temporary folder gone',
  );
  expect(b.incoming, isNull);
}

typedef Pair = (TransferStack, TransferStack, Gate<void>);

Future<Pair> gatedStacks({RecordingRevealer? revealer, int gateOn = 2}) async {
  final gate = Gate<void>(null);
  final a = await TransferStack.start(
    name: 'A',
    address: hostA,
    beforeStreamEntry: (entry) async {
      if (entry == gateOn) await gate.wait();
    },
  );
  final b = await TransferStack.start(
    name: 'B',
    address: hostB,
    revealer: revealer,
  );
  await link(a, b, senderName: 'PORTATIL', receiverName: 'SOBREMESA');
  return (a, b, gate);
}

Future<(TransferStack, TransferStack)> plainStacks({
  RecordingRevealer? revealer,
}) async {
  final a = await TransferStack.start(name: 'A', address: hostA);
  final b = await TransferStack.start(
    name: 'B',
    address: hostB,
    revealer: revealer,
  );
  await link(a, b, senderName: 'PORTATIL', receiverName: 'SOBREMESA');
  return (a, b);
}

Future<TransferResultView?> startSend(
  TransferStack a,
  TransferStack b,
  String path,
) => a.coordinator.sendElement(
  a.targetOf(b),
  path,
  refresh: () => a.targetOf(b),
);

Future<void> midUpload(TransferStack b, Gate<void> gate) async {
  await gate.reached.future.timeout(const Duration(seconds: 30));
  await eventually(
    () => b.incoming?.receivedBytes == 100 * kib,
    reason: 'the first file written at the receiver',
  );
}

bool isNonDecreasing(Iterable<int> values) {
  var last = 0;
  for (final value in values) {
    if (value < last) return false;
    last = value;
  }
  return true;
}

void main() {
  group('E468, RF-278: the sender sees the final name once the folder is '
      'there', () {
    test('until the last file the final name does not exist; then both '
        'sides report saved with it', () async {
      final (a, b, gate) = await gatedStacks();
      final source = await twoBigFiles(a, 'proy');

      final returned = startSend(a, b, source);
      await midUpload(b, gate);
      expect(Directory('${b.receiveDir}\\proy').existsSync(), isFalse);
      expect(b.incoming?.stage, IncomingStage.receiving);
      expect(a.outgoing?.phase, OutgoingPhase.uploading);
      gate.open(null);
      final result = await returned.timeout(const Duration(seconds: 40));

      expect(result?.outcome, TransferOutcome.saved);
      expect(result?.fileName, 'proy');
      final received = await b.receivedResult();
      expect(received.outcome, TransferOutcome.saved);
      expect(received.fileName, 'proy');
      expect(
        File('${b.receiveDir}\\proy\\f2.bin').readAsBytesSync(),
        content(2, 100 * kib),
      );
      await cleanFolder(b);
    }, timeout: long);
  });

  group('E470 [SEG], RF-280: every way out of a folder leaves the receive '
      'folder as it was', () {
    test('the sender cancels halfway: cancelledHere and cancelledByPeer, '
        'nothing stays', () async {
      final (a, b, gate) = await gatedStacks();
      File('${b.receiveDir}\\ya.txt').writeAsStringSync('already here');
      final before = snapshotOf(b.receiveDir);
      final source = await twoBigFiles(a, 'proy');

      final returned = startSend(a, b, source);
      await midUpload(b, gate);
      a.coordinator.cancelOutgoing();
      gate.open(null);
      final result = await returned.timeout(const Duration(seconds: 40));

      expect(result?.outcome, TransferOutcome.cancelledHere);
      final received = await b.receivedResult();
      expect(received.outcome, TransferOutcome.cancelledByPeer);
      await cleanFolder(b);
      expect(snapshotOf(b.receiveDir), before);
    }, timeout: long);

    test('the receiver cancels halfway: cancelledHere there, the sender '
        'stops, nothing stays', () async {
      final (a, b, gate) = await gatedStacks();
      File('${b.receiveDir}\\ya.txt').writeAsStringSync('already here');
      final before = snapshotOf(b.receiveDir);
      final source = await twoBigFiles(a, 'proy');

      final returned = startSend(a, b, source);
      await midUpload(b, gate);
      b.coordinator.cancelIncoming(b.incoming!.sessionId);
      gate.open(null);
      final result = await returned.timeout(const Duration(seconds: 40));

      expect(result?.outcome, TransferOutcome.cancelledByPeer);
      expect((await b.receivedResult()).outcome, TransferOutcome.cancelledHere);
      await cleanFolder(b);
      expect(snapshotOf(b.receiveDir), before);
    }, timeout: long);
  });

  group('E467 [SEG], RF-277 and B-4: the mark and the visibility at the end '
      'of a folder', () {
    Future<Pair> stacksWith({
      MarkFile? markFile,
      ClearHidden? clearHidden,
    }) async {
      final a = await TransferStack.start(name: 'A', address: hostA);
      final b = await TransferStack.start(
        name: 'B',
        address: hostB,
        markFile: markFile,
        clearHidden: clearHidden,
      );
      await link(a, b, senderName: 'PORTATIL', receiverName: 'SOBREMESA');
      return (a, b, Gate<void>(null));
    }

    Future<String> threeFiles(TransferStack a) async {
      final root = '${a.sourceDir}\\proy';
      Directory('$root\\sub').createSync(recursive: true);
      File('$root\\sub\\one.txt').writeAsBytesSync(content(1, 300));
      File('$root\\two.txt').writeAsBytesSync(content(2, 200));
      File('$root\\three.txt').writeAsBytesSync(content(3, 100));
      return root;
    }

    test('a drive that cannot hold the mark: savedWithoutMark on both '
        'sides and no file has a stream', () async {
      final (a, b, _) = await stacksWith();
      b.platform.noMarkSupport = true;
      final root = await threeFiles(a);

      final result = await startSend(
        a,
        b,
        root,
      ).timeout(const Duration(seconds: 40));

      expect(result?.outcome, TransferOutcome.savedWithoutMark);
      expect(result?.outcome.kind, TransferResultKind.saved);
      final received = await b.receivedResult();
      expect(received.outcome, TransferOutcome.savedWithoutMark);
      final saved = '${b.receiveDir}\\proy';
      for (final name in [r'sub\one.txt', 'two.txt', 'three.txt']) {
        expect(File('$saved\\$name').existsSync(), isTrue, reason: name);
        expect(readMark('$saved\\$name'), isEmpty, reason: name);
      }
      await cleanFolder(b);
    }, timeout: long);

    test('a mark that fails on one file: markFailed with that file, '
        'nothing is saved and nothing stays', () async {
      final (a, b, _) = await stacksWith(markFile: failMarkOfTwo);
      File('${b.receiveDir}\\ya.txt').writeAsStringSync('already here');
      final before = snapshotOf(b.receiveDir);
      final root = await threeFiles(a);

      final result = await startSend(
        a,
        b,
        root,
      ).timeout(const Duration(seconds: 40));

      expect(result?.outcome, TransferOutcome.markFailed);
      expect(result?.outcome.kind, TransferResultKind.failed);
      final received = await b.receivedResult();
      expect(received.outcome, TransferOutcome.markFailed);
      expect(received.problemPath, 'two.txt');
      expect(received.canReveal, isFalse);
      await cleanFolder(b);
      expect(snapshotOf(b.receiveDir), before);
      expect(Directory('${b.receiveDir}\\proy').existsSync(), isFalse);
    }, timeout: long);

    test('B-4: a hidden flag that cannot be cleared is writeFailed on both '
        'sides, never a hidden saved folder', () async {
      final (a, b, _) = await stacksWith(clearHidden: failClearHidden);
      final before = snapshotOf(b.receiveDir);
      final root = await threeFiles(a);

      final result = await startSend(
        a,
        b,
        root,
      ).timeout(const Duration(seconds: 40));

      expect(result?.outcome, TransferOutcome.writeFailed);
      final received = await b.receivedResult();
      expect(received.outcome, TransferOutcome.writeFailed);
      expect(received.canReveal, isFalse);
      await cleanFolder(b);
      expect(snapshotOf(b.receiveDir), before);
      expect(Directory('${b.receiveDir}\\proy').existsSync(), isFalse);
    }, timeout: long);
  });

  group('E472, RF-282: attributes, streams and dates do not travel', () {
    test('read-only, hidden and system files, a hidden folder and an '
        'alternate stream arrive as plain files with the date of the '
        'arrival', () async {
      final (a, b) = await plainStacks();
      final root = '${a.sourceDir}\\atrib';
      Directory('$root\\oculta').createSync(recursive: true);
      final plain = File('$root\\plano.txt')..writeAsStringSync('plain');
      final readonly = File('$root\\solo-lectura.txt')..writeAsStringSync('ro');
      final hidden = File('$root\\oculto.txt')..writeAsStringSync('hid');
      final inside = File('$root\\oculta\\dentro.txt')
        ..writeAsStringSync('inside');
      File('${plain.path}:extra').writeAsStringSync('side data');
      final old = DateTime.utc(2001, 2, 3, 4, 5, 6);
      for (final file in [plain, readonly, hidden, inside]) {
        file.setLastModifiedSync(old);
      }
      await Process.run('attrib', ['+r', readonly.path]);
      await Process.run('attrib', ['+h', '+s', hidden.path]);
      await Process.run('attrib', ['+h', '/d', '$root\\oculta']);
      expect(attributesOf(readonly.path) & FILE_ATTRIBUTE_READONLY, isNot(0));
      expect(attributesOf(hidden.path) & FILE_ATTRIBUTE_HIDDEN, isNot(0));
      final began = DateTime.now().subtract(const Duration(seconds: 5));

      final result = await startSend(
        a,
        b,
        root,
      ).timeout(const Duration(seconds: 40));

      expect(result?.outcome, TransferOutcome.saved);
      final saved = '${b.receiveDir}\\atrib';
      for (final name in [
        'plano.txt',
        'solo-lectura.txt',
        'oculto.txt',
        'oculta\\dentro.txt',
      ]) {
        final path = '$saved\\$name';
        expect(File(path).existsSync(), isTrue, reason: name);
        expect(attributesOf(path) & blocked, 0, reason: name);
        expect(
          File(path).lastModifiedSync().isAfter(began),
          isTrue,
          reason: '$name carries the date of the arrival',
        );
      }
      expect(attributesOf('$saved\\oculta') & blocked, 0);
      expect(File('$saved\\plano.txt').readAsStringSync(), 'plain');
      expect(File('$saved\\oculto.txt').readAsStringSync(), 'hid');
      expect(
        () => File('$saved\\plano.txt:extra').readAsStringSync(),
        throwsA(isA<FileSystemException>()),
      );
      expect(
        File('$saved\\plano.txt:Zone.Identifier').readAsStringSync(),
        '[ZoneTransfer]\r\nZoneId=3\r\n',
      );
    }, timeout: long);
  });

  group('E473, RF-283: reveal the saved folder', () {
    test('lastReceived of a folder can be revealed and the revealer gets '
        'the path of the saved folder', () async {
      final revealer = RecordingRevealer();
      final (a, b) = await plainStacks(revealer: revealer);
      final root = '${a.sourceDir}\\nexo';
      Directory(root).createSync();
      File('$root\\a.txt').writeAsStringSync('a');
      Directory('${b.receiveDir}\\nexo').createSync();

      final result = await startSend(
        a,
        b,
        root,
      ).timeout(const Duration(seconds: 40));

      expect(result?.outcome, TransferOutcome.saved);
      final received = await b.receivedResult();
      expect(received.canReveal, isTrue);
      expect(received.isFolder, isTrue);
      expect(received.fileName, 'nexo (1)');
      expect(await b.coordinator.revealLastReceived(), RevealResult.shown);
      expect(revealer.paths, ['${b.receiveDir}\\nexo (1)']);
    }, timeout: long);

    test('a folder that exists is an item for the plan, whatever it is', () {
      final folder = Directory.systemTemp.path;
      expect(
        revealPlanFor(
          Directory(folder).existsSync(),
          Directory(Directory(folder).parent.path).existsSync(),
        ),
        RevealResult.shown,
      );
      expect(revealPlanFor(false, true), RevealResult.folderOnly);
      expect(revealPlanFor(false, false), RevealResult.unavailable);
    });
  });

  group('E474, RF-284: progress seen on both sides', () {
    test('the sender counts files and bytes, the receiver does too, and '
        'both finish complete', () async {
      final (a, b) = await plainStacks();
      final root = '${a.sourceDir}\\prog';
      Directory(root).createSync();
      for (var i = 0; i < 4; i++) {
        File('$root\\f$i.bin').writeAsBytesSync(content(i, 150 * kib));
      }

      final result = await startSend(
        a,
        b,
        root,
      ).timeout(const Duration(seconds: 40));

      expect(result?.outcome, TransferOutcome.saved);
      int most(Iterable<int> values) => values.reduce((x, y) => x > y ? x : y);
      final outgoing = a.outgoingSeen.where((v) => v.isFolder).toList();
      expect(outgoing, isNotEmpty);
      expect(most(outgoing.map((v) => v.fileCount)), 4);
      expect(most(outgoing.map((v) => v.size)), 600 * kib);
      expect(
        most(outgoing.map((v) => v.sentBytes)),
        inInclusiveRange(1, 600 * kib),
      );
      expect(most(outgoing.map((v) => v.sentFiles)), inInclusiveRange(1, 4));
      expect(isNonDecreasing(outgoing.map((v) => v.sentBytes)), isTrue);
      final incoming = b.incomingSeen.where((v) => v.isFolder).toList();
      expect(incoming, isNotEmpty);
      expect(most(incoming.map((v) => v.fileCount)), 4);
      expect(most(incoming.map((v) => v.size)), 600 * kib);
      expect(
        most(incoming.map((v) => v.receivedBytes)),
        inInclusiveRange(1, 600 * kib),
      );
      expect(
        most(incoming.map((v) => v.receivedFiles)),
        inInclusiveRange(1, 4),
      );
      expect(isNonDecreasing(incoming.map((v) => v.receivedBytes)), isTrue);
    }, timeout: long);
  });

  group('E475, RF-285: the results, in both computers', () {
    test('the final name, the number of files, the other computer and the '
        'reason are in both results', () async {
      final (a, b) = await plainStacks();
      final root = '${a.sourceDir}\\nexo';
      Directory('$root\\sub').createSync(recursive: true);
      File('$root\\a.txt').writeAsStringSync('a');
      File('$root\\sub\\b.txt').writeAsStringSync('b');
      File('$root\\c.txt').writeAsStringSync('c');
      Directory('${b.receiveDir}\\nexo').createSync();

      final result = await startSend(
        a,
        b,
        root,
      ).timeout(const Duration(seconds: 40));

      final sent = await a.sentResult();
      expect(result, sent);
      expect(sent.outcome, TransferOutcome.saved);
      expect(sent.fileName, 'nexo (1)');
      expect(sent.isFolder, isTrue);
      expect(sent.fileCount, 3);
      expect(sent.peerName, 'SOBREMESA');
      expect(sent.direction, TransferDirection.outgoing);
      final received = await b.receivedResult();
      expect(received.outcome, TransferOutcome.saved);
      expect(received.fileName, 'nexo (1)');
      expect(received.isFolder, isTrue);
      expect(received.fileCount, 3);
      expect(received.peerName, 'PORTATIL');
      expect(received.direction, TransferDirection.incoming);
    }, timeout: long);

    test(
      'the last reception is the last one received, file or folder',
      () async {
        final (a, b) = await plainStacks();
        final root = '${a.sourceDir}\\nexo';
        Directory(root).createSync();
        File('$root\\a.txt').writeAsStringSync('a');
        final file = await a.sourceFile('nota.txt', 'note'.codeUnits);

        await startSend(a, b, root).timeout(const Duration(seconds: 40));
        final first = await b.receivedResult();
        expect(first.fileName, 'nexo');
        expect(first.isFolder, isTrue);
        await startSend(a, b, file).timeout(const Duration(seconds: 40));
        final second = await b.receivedResult(after: first);
        expect(second.fileName, 'nota.txt');
        expect(second.isFolder, isFalse);
        await startSend(a, b, root).timeout(const Duration(seconds: 40));
        final third = await b.receivedResult(after: second);

        expect(third.fileName, 'nexo (1)');
        expect(third.isFolder, isTrue);
        expect(b.lastReceived, third);
      },
      timeout: long,
    );
  });

  group('E476 [SEG], RF-280 and RF-300: pairing and interface cuts during '
      'a folder', () {
    test('the sender loses its interface: both end, nothing stays', () async {
      final (a, b, gate) = await gatedStacks();
      File('${b.receiveDir}\\ya.txt').writeAsStringSync('already here');
      final before = snapshotOf(b.receiveDir);
      final source = await twoBigFiles(a, 'proy');

      final returned = startSend(a, b, source);
      await midUpload(b, gate);
      a.coordinator.interfacesChanged(const {});
      gate.open(null);
      final result = await returned.timeout(const Duration(seconds: 40));

      expect(result?.outcome, TransferOutcome.interfaceDown);
      expect((await b.receivedResult()).outcome, isNot(TransferOutcome.saved));
      await cleanFolder(b);
      expect(snapshotOf(b.receiveDir), before);
    }, timeout: long);

    test('the sender unpairs the receiver: both end, nothing stays', () async {
      final (a, b, gate) = await gatedStacks();
      File('${b.receiveDir}\\ya.txt').writeAsStringSync('already here');
      final before = snapshotOf(b.receiveDir);
      final source = await twoBigFiles(a, 'proy');

      final returned = startSend(a, b, source);
      await midUpload(b, gate);
      final unpaired = a.coordinator.peerUnpaired(b.fingerprint);
      gate.open(null);
      await unpaired;
      final result = await returned.timeout(const Duration(seconds: 40));

      expect(result?.outcome, TransferOutcome.unpaired);
      expect((await b.receivedResult()).outcome, isNot(TransferOutcome.saved));
      await cleanFolder(b);
      expect(snapshotOf(b.receiveDir), before);
    }, timeout: long);

    test('the receiver unpairs the sender: unpaired there, the sender sees '
        'the cut, nothing stays', () async {
      final (a, b, gate) = await gatedStacks();
      File('${b.receiveDir}\\ya.txt').writeAsStringSync('already here');
      final before = snapshotOf(b.receiveDir);
      final source = await twoBigFiles(a, 'proy');

      final returned = startSend(a, b, source);
      await midUpload(b, gate);
      await b.forget(a.fingerprint);
      await b.coordinator.peerUnpaired(a.fingerprint);
      gate.open(null);

      expect((await b.receivedResult()).outcome, TransferOutcome.unpaired);
      await settle(const Duration(milliseconds: 500));
      a.clock.advance(Limits.transferConfirmTimeout);
      final result = await returned.timeout(const Duration(seconds: 40));
      expect(result?.outcome, isNot(TransferOutcome.saved));
      await cleanFolder(b);
      expect(snapshotOf(b.receiveDir), before);
    }, timeout: long);

    test('the receiver loses its interface: interfaceDown there, the sender '
        'ends and nothing stays', () async {
      final (a, b, gate) = await gatedStacks();
      File('${b.receiveDir}\\ya.txt').writeAsStringSync('already here');
      final before = snapshotOf(b.receiveDir);
      final source = await twoBigFiles(a, 'proy');

      final returned = startSend(a, b, source);
      await midUpload(b, gate);
      b.coordinator.interfacesChanged(const {});
      gate.open(null);

      expect((await b.receivedResult()).outcome, TransferOutcome.interfaceDown);
      await settle(const Duration(milliseconds: 500));
      a.clock.advance(Limits.transferConfirmTimeout);
      final result = await returned.timeout(const Duration(seconds: 40));
      expect(result?.outcome, isNot(TransferOutcome.saved));
      await cleanFolder(b);
      expect(snapshotOf(b.receiveDir), before);
    }, timeout: long);
  });
}
