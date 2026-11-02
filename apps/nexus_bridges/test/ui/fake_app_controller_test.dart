import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:nexus_bridges_core/nexus_bridges_core.dart';

import 'fake_app_controller.dart';

void main() {
  group('FakeAppController for the transfer (point 92)', () {
    test('the eleven methods note one line each, in order, with the id '
        'they got', () async {
      final fake = FakeAppController();

      await fake.sendFile('FP1');
      fake.cancelSending();
      fake.cancelReceiving('s1');
      fake.answerIncoming('s1', accept: true);
      fake.answerIncoming('s2', accept: false);
      await fake.useProposedFolder('s1');
      await fake.chooseOtherFolder('s1');
      fake.useFolderAnyway('s1');
      fake.cancelFolderQuestion('s1');
      await fake.rememberFolderAfterEnd('s1', remember: true);
      await fake.rememberFolderAfterEnd('s2', remember: false);
      fake.dismissFolderPanel('s1');
      await fake.revealLastReceived();

      expect(fake.calls, [
        'sendFile FP1',
        'cancelSending',
        'cancelReceiving s1',
        'answerIncoming s1 true',
        'answerIncoming s2 false',
        'useProposedFolder s1',
        'chooseOtherFolder s1',
        'useFolderAnyway s1',
        'cancelFolderQuestion s1',
        'rememberFolderAfterEnd s1 true',
        'rememberFolderAfterEnd s2 false',
        'dismissFolderPanel s1',
        'revealLastReceived',
      ]);
    });

    test('the 006 methods note one line each, in order, with what they '
        'got', () async {
      final fake = FakeAppController();

      await fake.sendFiles('FP1');
      await fake.sendFolders('FP1');
      await fake.sendPaths('FP1', ['a', 'b']);
      fake.cancelQueueItem('i1');
      fake.removeQueueItem('i2');
      fake.cancelAllQueued();
      await fake.addToTray(['c'], totalCount: 5);
      await fake.addToTray(['d', 'e']);
      fake.removeFromTray('t1');
      fake.clearTray();
      await fake.sendTray('FP2');
      await fake.requestPortal('FP2');

      expect(fake.calls, [
        'sendFiles FP1',
        'sendFolders FP1',
        'sendPaths FP1 a|b',
        'cancelQueueItem i1',
        'removeQueueItem i2',
        'cancelAllQueued',
        'addToTray c 5',
        'addToTray d|e null',
        'removeFromTray t1',
        'clearTray',
        'sendTray FP2',
        'requestPortal FP2',
      ]);
      expect(fake.sendPathsCalls, [
        ['a', 'b'],
      ]);
      expect(fake.addToTrayCalls, [
        ['c'],
        ['d', 'e'],
      ]);
      expect(fake.addToTrayTotals, [5, null]);
    });

    test('the 006 methods give started and added by default and then '
        'whatever the test sets', () async {
      final fake = FakeAppController();
      expect(await fake.sendFiles('FP'), SendResult.started);
      expect(await fake.sendFolders('FP'), SendResult.started);
      expect(await fake.sendPaths('FP', ['a']), SendResult.started);
      expect(await fake.sendTray('FP'), SendResult.started);
      expect(await fake.addToTray(['a']), TrayResult.added);

      for (final result in SendResult.values) {
        fake.sendFilesResult = result;
        fake.sendFoldersResult = result;
        fake.sendPathsResult = result;
        fake.sendTrayResult = result;
        expect(await fake.sendFiles('FP'), result);
        expect(await fake.sendFolders('FP'), result);
        expect(await fake.sendPaths('FP', ['a']), result);
        expect(await fake.sendTray('FP'), result);
      }
      for (final result in TrayResult.values) {
        fake.addToTrayResult = result;
        expect(await fake.addToTray(['a']), result);
      }
    });

    test('sendFile gives started by default and then whatever the test '
        'sets', () async {
      final fake = FakeAppController();
      expect(await fake.sendFile('FP'), SendResult.started);

      for (final result in SendResult.values) {
        fake.sendFileResult = result;
        expect(await fake.sendFile('FP'), result);
      }
    });

    test('revealLastReceived gives shown by default and then whatever the '
        'test sets', () async {
      final fake = FakeAppController();
      expect(await fake.revealLastReceived(), RevealResult.shown);

      for (final result in RevealResult.values) {
        fake.revealResult = result;
        expect(await fake.revealLastReceived(), result);
      }
    });

    test('shutdown notes "shutdown", ends at once by default and can be held '
        'with shutdownResult', () async {
      final fake = FakeAppController();
      await fake.shutdown().timeout(const Duration(seconds: 1));
      expect(fake.calls, ['shutdown']);

      final gate = Completer<void>();
      fake.shutdownResult = () => gate.future;
      var done = false;
      final pending = fake.shutdown().then((_) => done = true);
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(done, isFalse);
      expect(fake.calls, ['shutdown', 'shutdown']);

      gate.complete();
      await pending;
      expect(done, isTrue);
    });
  });
}
