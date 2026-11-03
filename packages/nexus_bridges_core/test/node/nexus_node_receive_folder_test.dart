@TestOn('windows')
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:nexus_bridges_core/src/node/node.dart';
import 'package:test/test.dart';

import 'transfer_nodes_harness.dart';

const int _big = 4 * 1024 * 1024;

List<int> _bytes(int length, [int seed = 0]) =>
    List<int>.generate(length, (i) => (i + seed) % 251);

String _newFolder(TransferNode node, String name) {
  final path = '${node.base}\\$name';
  Directory(path).createSync(recursive: true);
  return path;
}

Map<String, Object?>? _savedFolder(TransferNode node) {
  if (!node.settingsFile.existsSync()) return null;
  final json =
      jsonDecode(node.settingsFile.readAsStringSync()) as Map<String, Object?>;
  return (json['receiveFolder'] as Map?)?.cast<String, Object?>();
}

void main() {
  group('E824: a transfer already accepted ends in the folder where it '
      'started (RF-515)', () {
    test(
      'B sends a large file to A; while it uploads A changes the folder: '
      'the file is saved in the old one and the next file in the new one',
      () async {
        final (a, b) = await transferNodes();
        final old = a.recvDir;
        final next = _newFolder(a, 'nueva');
        final big = await b.sourceFile('grande.bin', _bytes(_big));
        a.writes.hold();

        expect(await b.send(a, big), SendResult.started);
        await a.until(
          (s) =>
              s.incoming?.stage == IncomingStage.receiving &&
              s.incoming?.fileName == 'grande.bin',
          reason: 'A receiving',
        );

        a.picker.nextFolder = next;
        final result = await a.node.changeReceiveFolder();
        expect(result, isA<FolderChanged>());
        expect((result as FolderChanged).path, next);
        await a.until(
          (s) => s.settings.receiveFolder == next,
          reason: 'the state shows the new folder',
        );
        expect(a.state.incoming?.stage, IncomingStage.receiving);

        a.writes.release();
        final first = await a.receivedResult();
        expect(first.outcome, TransferOutcome.saved);
        expect(File('$old\\grande.bin').lengthSync(), _big);
        expect(File('$next\\grande.bin').existsSync(), isFalse);
        await b.sentResult();

        final small = await b.sourceFile('pequeno.txt', _bytes(100, 3));
        final before = a.state.lastReceived;
        expect(await b.send(a, small), SendResult.started);
        final second = await a.receivedResult(after: before);
        expect(second.outcome, TransferOutcome.saved);
        expect(File('$next\\pequeno.txt').readAsBytesSync(), _bytes(100, 3));
        expect(File('$old\\pequeno.txt').existsSync(), isFalse);
        expect(_savedFolder(a)?['path'], next);
      },
      timeout: transferTimeout,
    );
  });

  group('T3 through the node: state and picker (RF-512, RF-513, E823)', () {
    test('the state shows the remembered folder at start, the picker starts '
        'there and the change is reflected and survives a restart', () async {
      final (a, _) = await transferNodes();
      await a.until(
        (s) => s.settings.receiveFolder == a.recvDir,
        reason: 'the remembered folder in the state',
      );
      expect(a.state.settings.receiveFolderLocked, isFalse);
      final next = _newFolder(a, 'otra');
      a.picker.nextFolder = next;

      expect(await a.node.changeReceiveFolder(), isA<FolderChanged>());

      expect(a.picker.folderStartIns.last, a.recvDir);
      await a.until(
        (s) => s.settings.receiveFolder == next,
        reason: 'the new folder in the state',
      );
      await a.restart();
      await a.until(
        (s) => s.settings.receiveFolder == next,
        reason: 'the new folder after a restart',
      );
    }, timeout: transferTimeout);

    test('with the settings picker open: pickerOpen is true, nothing is being '
        'sent or received and the folder is not locked; a second change is '
        'blocked', () async {
      final (a, _) = await transferNodes();
      final gate = Completer<void>();
      a.picker
        ..folderGate = gate
        ..nextFolder = null;

      final run = a.node.changeReceiveFolder();
      final open = await a.until((s) => s.pickerOpen, reason: 'picker open');

      expect(open.transferInProgress, isFalse);
      expect(open.sendingTo, isNull);
      expect(open.incoming, isNull);
      expect(open.outgoing, isNull);
      expect(open.settings.receiveFolderLocked, isFalse);
      expect(await a.node.changeReceiveFolder(), isA<FolderChangeBlocked>());
      expect(a.picker.folderCalls, 1);

      gate.complete();
      expect(await run, isA<FolderUnchanged>());
      await a.until((s) => !s.pickerOpen, reason: 'picker closed');
      expect(a.state.settings.receiveFolder, a.recvDir);
    }, timeout: transferTimeout);

    test('a confirmation through the node: needs confirmation, then confirm '
        'changes the folder and cancel leaves it', () async {
      final (a, _) = await transferNodes();
      a.platform.noMarkSupport = true;
      final first = _newFolder(a, 'sinmarca');
      a.picker.nextFolder = first;

      final ask = await a.node.changeReceiveFolder();
      expect(ask, isA<FolderChangeNeedsConfirmation>());
      a.node.cancelReceiveFolderChange(
        (ask as FolderChangeNeedsConfirmation).changeId,
      );
      await Future<void>.delayed(const Duration(milliseconds: 300));
      expect(a.state.settings.receiveFolder, a.recvDir);

      final again = await a.node.changeReceiveFolder();
      final confirmed = await a.node.confirmReceiveFolder(
        (again as FolderChangeNeedsConfirmation).changeId,
      );
      expect(confirmed, isA<FolderChanged>());
      await a.until(
        (s) => s.settings.receiveFolder == first,
        reason: 'the confirmed folder in the state',
      );
    }, timeout: transferTimeout);

    test('with the folder question of an incoming file exposed the state is '
        'locked and the change is blocked', () async {
      final (a, b) = await transferNodes(rememberA: false);
      final file = await b.sourceFile('doc.txt', _bytes(50));

      expect(await b.send(a, file), SendResult.started);
      await a.incomingAt(IncomingStage.folderQuestion);
      await a.until(
        (s) => s.settings.receiveFolderLocked,
        reason: 'locked in the state',
      );

      expect(await a.node.changeReceiveFolder(), isA<FolderChangeBlocked>());
      expect(a.picker.folderCalls, 0);
    }, timeout: transferTimeout);
  });
}
