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
