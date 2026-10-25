import 'dart:async';
import 'dart:io';

import 'package:nexus_bridges_core/src/node/node.dart';
import 'package:nexus_bridges_core/src/pairing/pairing.dart' show PeerRelation;
import 'package:nexus_bridges_core/src/settings/settings.dart';
import 'package:nexus_bridges_core/src/storage/storage.dart';
import 'package:nexus_bridges_core/src/transfer/windows_shell.dart'
    show revealPlanFor;
import 'package:test/test.dart';

import 'transfer_nodes_harness.dart';

DeviceEntry _entry({
  required bool visible,
  required bool paired,
  bool mismatch = false,
}) => DeviceEntry(
  fingerprint: 'A' * 64,
  displayName: 'Laptop',
  deviceType: DeviceType.desktop,
  visible: visible,
  paired: paired,
  mine: false,
  ignored: false,
  mismatch: mismatch,
  possiblyReplaces: null,
);

Future<IncomingTransferView> _warning(TransferNode b) =>
    b.incomingAt(IncomingStage.warning);

void main() {
  group('canSendFile (E121, RF-130, RF-131, RF-210)', () {
    test('paired and visible: true; not visible: false; with a mismatch: '
        'false; not paired: false', () {
      expect(_entry(visible: true, paired: true).canSendFile, isTrue);
      expect(_entry(visible: false, paired: true).canSendFile, isFalse);
      expect(
        _entry(visible: true, paired: true, mismatch: true).canSendFile,
        isFalse,
      );
      expect(_entry(visible: true, paired: false).canSendFile, isFalse);
    });

    test('two real nodes paired and in sight offer the send to each other, '
        'and once B is out of sight its row in A does not', () async {
      final (a, b) = await transferNodes();

      expect(a.entryOf(b.fingerprint)?.canSendFile, isTrue);
      expect(b.entryOf(a.fingerprint)?.canSendFile, isTrue);

      await loseSight(a, b);
      final row = a.state.entries.singleWhere(
        (e) => e.fingerprint == b.fingerprint,
      );
      expect(row.paired, isTrue);
      expect(row.canSendFile, isFalse);
    }, timeout: transferTimeout);
  });

  group('sendFile and the file picker (E122, RF-132)', () {
    test('available: the fake picker is called once and the result is '
        'started', () async {
      final (a, b) = await transferNodes();
      final path = await a.sourceFile('a.txt', [7]);

      expect(await a.send(b, path), SendFileResult.started);

      expect(a.picker.fileCalls, 1);
      expect((await a.sentResult()).outcome, TransferOutcome.saved);
    }, timeout: transferTimeout);

    test('not available: an unknown fingerprint and a paired device out of '
        'sight give unavailable without opening the picker', () async {
      final (a, b) = await transferNodes();
      final path = await a.sourceFile('a.txt', [7]);
      a.picker.nextFile = path;

      expect(await a.node.sendFile('F' * 64), SendFileResult.unavailable);

      await loseSight(a, b);
      expect(await a.node.sendFile(b.fingerprint), SendFileResult.unavailable);

      expect(a.picker.fileCalls, 0);
      expect(a.state.lastSent, isNull);
      expect(a.state.outgoing, isNull);
      expect(a.state.transferInProgress, isFalse);
    }, timeout: transferTimeout);

    test('closing the picker without a file gives nothingChosen and leaves '
        'no last send nor a send in progress', () async {
      final (a, b) = await transferNodes();
      a.picker.nextFile = null;

      expect(
        await a.node.sendFile(b.fingerprint),
        SendFileResult.nothingChosen,
      );

      expect(a.picker.fileCalls, 1);
      expect(a.state.lastSent, isNull);
      expect(a.state.outgoing, isNull);
      await a.until(
        (s) => !s.transferInProgress && !s.pickerOpen,
        reason: 'A idle',
      );
      expect(b.state.incoming, isNull);
    }, timeout: transferTimeout);

    test('with the picker open: pickerOpen is true, a second sendFile gives '
        'alreadySending without opening it again, and the node queue still '
        'answers other calls; after choosing, the send ends saved', () async {
      final (a, b) = await transferNodes();
      final path = await a.sourceFile('held.txt', [1, 2]);
      a.picker
        ..nextFile = path
        ..hold();

      final first = a.node.sendFile(b.fingerprint);
      await a.until((s) => s.pickerOpen, reason: 'picker open in A');
      expect(a.state.transferInProgress, isTrue);

      expect(
        await a.node.sendFile(b.fingerprint),
        SendFileResult.alreadySending,
      );
      expect(a.picker.fileCalls, 1);
      await a.node
          .answerMine(b.fingerprint, mine: true)
          .timeout(const Duration(seconds: 2));

      a.picker.release();
      expect(await first, SendFileResult.started);
      await a.until((s) => !s.pickerOpen, reason: 'picker closed in A');
      expect((await a.sentResult()).outcome, TransferOutcome.saved);
      expect(a.picker.fileCalls, 1);
    }, timeout: transferTimeout);
  });

  group('end to end with a "mine" sender (E123, RF-150, RF-175, RF-199, '
      'RF-203)', () {
    test(
      'the first send asks for the folder and saves; the same file again '
      'is saved as "name (1)" without asking and the first stays the same; '
      'after restarting the receiver a third is saved without asking',
      () async {
        final (a, b) = await transferNodes(rememberB: false);
        final path = await a.sourceFile('notes.txt', [1, 2, 3]);

        expect(await a.send(b, path), SendFileResult.started);
        final question = await b.incomingAt(IncomingStage.folderQuestion);
        expect(question.folder?.kind, FolderQuestionKind.firstTime);
        expect(question.folder?.proposedPath, b.proposedDir);
        await b.node.useProposedFolder(question.sessionId);

        final first = await a.sentResult();
        expect(first.outcome, TransferOutcome.saved);
        expect((await b.receivedResult()).fileName, 'notes.txt');
        final saved = await SettingsStore(JsonFileStore(b.settingsFile))
            .readReceiveFolder();
        expect(saved?.path, b.proposedDir);

        final mark = b.states.length;
        final firstReceived = b.state.lastReceived;
        expect(await a.send(b, path), SendFileResult.started);
        final second = await a.sentResult(after: first);
        expect(second.outcome, TransferOutcome.saved);
        final secondReceived = await b.receivedResult(after: firstReceived);
        expect(secondReceived.fileName, 'notes (1).txt');
        expect(
          b.states.skip(mark).where((s) => s.incoming?.folder != null),
          isEmpty,
        );
        expect(File('${b.proposedDir}\\notes.txt').readAsBytesSync(), [
          1,
          2,
          3,
        ]);
        expect(b.filesIn(b.proposedDir), ['notes (1).txt', 'notes.txt']);

        await b.restart();
        await meet(a, b);
        final restartMark = b.states.length;
        expect(await a.send(b, path), SendFileResult.started);
        expect(
          (await a.sentResult(after: second)).outcome,
          TransferOutcome.saved,
        );
        expect((await b.receivedResult()).fileName, 'notes (2).txt');
        expect(
          b.states.skip(restartMark).where((s) => s.incoming?.folder != null),
          isEmpty,
        );
        expect(b.filesIn(b.proposedDir), [
          'notes (1).txt',
          'notes (2).txt',
          'notes.txt',
        ]);
      },
      timeout: transferTimeout,
    );
  });

  group('end to end with a foreign sender (E124, RF-154, RF-155, RF-215)', () {
    test('decline gives declined; asking again within the minute gives '
        'declined with no warning; a minute later the warning expires as '
        'unanswered; asking again and accepting saves it', () async {
      final (a, b) = await transferNodes(aAtB: PeerRelation.foreign);
      final path = await a.sourceFile('invoice.pdf', [9, 9, 9]);

      expect(await a.send(b, path), SendFileResult.started);
      final warning = await _warning(b);
      expect(warning.peerName, 'Desk PC');
      expect(warning.fileName, 'invoice.pdf');
      b.node.answerIncoming(warning.sessionId, accept: false);
      final declined = await a.sentResult();
      expect(declined.outcome, TransferOutcome.declined);
      final shownDecline = await b.receivedResult();
      expect(shownDecline.outcome, TransferOutcome.declined);

      final mark = b.states.length;
      expect(await a.send(b, path), SendFileResult.started);
      final again = await a.sentResult(after: declined);
      expect(again.outcome, TransferOutcome.declined);
      await Future<void>.delayed(const Duration(milliseconds: 200));
      final quiet = b.states.skip(mark).toList();
      expect(quiet.where((s) => s.incoming != null), isEmpty);
      expect(quiet.where((s) => s.transferInProgress), isEmpty);
      expect(b.state.lastReceived, shownDecline);

      b.clock.advance(const Duration(seconds: 61));
      expect(await a.send(b, path), SendFileResult.started);
      await _warning(b);
      b.clock.advance(const Duration(seconds: 61));
      final unanswered = await a.sentResult(after: again);
      expect(unanswered.outcome, TransferOutcome.unanswered);
      expect(
        (await b.receivedResult(after: shownDecline)).outcome,
        TransferOutcome.unanswered,
      );

      expect(await a.send(b, path), SendFileResult.started);
      final last = await _warning(b);
      b.node.answerIncoming(last.sessionId, accept: true);
      expect(
        (await a.sentResult(after: unanswered)).outcome,
        TransferOutcome.saved,
      );
      expect((await b.receivedResult()).outcome, TransferOutcome.saved);
      expect(File('${b.recvDir}\\invoice.pdf').readAsBytesSync(), [9, 9, 9]);
    }, timeout: transferTimeout);

    test('a goodbye of B while A waits on the warning does not stop the send: '
        'it is saved after B accepts (E113, RF-213)', () async {
      final (a, b) = await transferNodes(aAtB: PeerRelation.foreign);
      final path = await a.sourceFile('plan.txt', [4, 5]);

      expect(await a.send(b, path), SendFileResult.started);
      final warning = await _warning(b);
      await a.until(
        (s) => s.outgoing?.phase == OutgoingPhase.waiting,
        reason: 'A waiting',
      );

      await sayBye(b, a);
      await Future<void>.delayed(const Duration(seconds: 1));
      expect(a.state.outgoing?.phase, OutgoingPhase.waiting);
      await loseSight(a, b);
      await Future<void>.delayed(const Duration(milliseconds: 400));
      expect(a.state.outgoing?.phase, OutgoingPhase.waiting);
      expect(a.state.lastSent, isNull);

      b.node.answerIncoming(warning.sessionId, accept: true);
      expect((await a.sentResult()).outcome, TransferOutcome.saved);
      expect((await b.receivedResult()).outcome, TransferOutcome.saved);
      expect(File('${b.recvDir}\\plan.txt').readAsBytesSync(), [4, 5]);
    }, timeout: transferTimeout);
  });

  group('last results of the session (E127, RF-178, RF-195, RF-240)', () {
    test('after a saved send, lastSent and lastReceived carry the names and '
        'the outcome, nothing stays in progress, and after restarting both '
        'are empty', () async {
      final (a, b) = await transferNodes();
      final path = await a.sourceFile('report.pdf', [3, 1, 4, 1, 5]);

      expect(await a.send(b, path), SendFileResult.started);
      final sent = await a.sentResult();
      final received = await b.receivedResult();

      expect(sent.direction, TransferDirection.outgoing);
      expect(sent.peerFingerprint, b.fingerprint);
      expect(sent.peerName, 'Laptop');
      expect(sent.fileName, 'report.pdf');
      expect(sent.outcome, TransferOutcome.saved);
      expect(sent.outcome.kind, TransferResultKind.saved);
      expect(received.direction, TransferDirection.incoming);
      expect(received.peerFingerprint, a.fingerprint);
      expect(received.peerName, 'Desk PC');
      expect(received.fileName, 'report.pdf');
      expect(received.outcome, TransferOutcome.saved);
      expect(received.canReveal, isTrue);
      await a.until((s) => !s.transferInProgress, reason: 'A idle');
      await b.until((s) => !s.transferInProgress, reason: 'B idle');
      expect(a.states.last.lastSent, sent);
      expect(b.states.last.lastReceived, received);

      await a.restart();
      await b.restart();
      expect(a.state.lastSent, isNull);
      expect(a.state.lastReceived, isNull);
      expect(b.state.lastSent, isNull);
      expect(b.state.lastReceived, isNull);
      expect(a.state.transferInProgress, isFalse);
      expect(b.state.transferInProgress, isFalse);
    }, timeout: transferTimeout);
  });

  group('show in folder (E128, RF-182, RF-208, RF-228, RF-229)', () {
    test('revealLastReceived calls the revealer with the final path and '
        'returns its answer; with nothing received or a declined one it gives '
        'unavailable without calling it', () async {
      final (a, b) = await transferNodes(aAtB: PeerRelation.foreign);
      expect(await b.node.revealLastReceived(), RevealResult.unavailable);

      final path = await a.sourceFile('photo.png', [8, 8]);
      expect(await a.send(b, path), SendFileResult.started);
      b.node.answerIncoming((await _warning(b)).sessionId, accept: false);
      final declined = await b.receivedResult();
      final declinedSent = await a.sentResult();
      expect(declined.canReveal, isFalse);
      expect(await b.node.revealLastReceived(), RevealResult.unavailable);
      expect(b.revealer.paths, isEmpty);

      b.clock.advance(const Duration(seconds: 61));
      expect(await a.send(b, path), SendFileResult.started);
      b.node.answerIncoming((await _warning(b)).sessionId, accept: true);
      await a.sentResult(after: declinedSent);
      final saved = await b.receivedResult(after: declined);
      expect(saved.canReveal, isTrue);

      b.revealer.answer = RevealResult.folderOnly;
      expect(await b.node.revealLastReceived(), RevealResult.folderOnly);
      b.revealer.answer = RevealResult.shown;
      expect(await b.node.revealLastReceived(), RevealResult.shown);
      expect(b.revealer.paths, [
        '${b.recvDir}\\photo.png',
        '${b.recvDir}\\photo.png',
      ]);
      expect(a.revealer.paths, isEmpty);
    }, timeout: transferTimeout);

    test('revealPlanFor: file, only the folder, nothing', () {
      expect(revealPlanFor(true, true), RevealResult.shown);
      expect(revealPlanFor(false, true), RevealResult.folderOnly);
      expect(revealPlanFor(false, false), RevealResult.unavailable);
    });
  });

  group('two nodes at once (E129, RF-191)', () {
    test('A and B send to each other at the same time and both files are '
        'saved', () async {
      final (a, b) = await transferNodes();
      final fromA = await a.sourceFile('from-a.bin', List.filled(70000, 1));
      final fromB = await b.sourceFile('from-b.bin', List.filled(90000, 2));
      a.picker.nextFile = fromA;
      b.picker.nextFile = fromB;

      final starts = await Future.wait([
        a.node.sendFile(b.fingerprint),
        b.node.sendFile(a.fingerprint),
      ]);
      expect(starts, [SendFileResult.started, SendFileResult.started]);

      expect((await a.sentResult()).outcome, TransferOutcome.saved);
      expect((await b.sentResult()).outcome, TransferOutcome.saved);
      expect((await a.receivedResult()).fileName, 'from-b.bin');
      expect((await b.receivedResult()).fileName, 'from-a.bin');
      expect(File('${b.recvDir}\\from-a.bin').lengthSync(), 70000);
      expect(File('${a.recvDir}\\from-b.bin').lengthSync(), 90000);
      await a.until((s) => !s.transferInProgress, reason: 'A idle');
      await b.until((s) => !s.transferInProgress, reason: 'B idle');
    }, timeout: transferTimeout);
  });

  group('folder not saved (RF-203, notice receiveFolderNotSaved)', () {
    test('when settings.json cannot be written, the first-time folder is '
        'still used for this send and the node shows receiveFolderNotSaved '
        'with the path', () async {
      final (a, b) = await transferNodes(
        rememberB: false,
        before: (a, b) async {
          b.settingsFile.parent.createSync(recursive: true);
          Directory(b.settingsFile.path).createSync();
        },
      );
      final path = await a.sourceFile('notes.txt', [5]);

      expect(await a.send(b, path), SendFileResult.started);
      final question = await b.incomingAt(IncomingStage.folderQuestion);
      await b.node.useProposedFolder(question.sessionId);

      expect((await a.sentResult()).outcome, TransferOutcome.saved);
      final s = await b.until(
        (s) => s.notices.any((n) => n.kind == NoticeKind.receiveFolderNotSaved),
        reason: 'receiveFolderNotSaved in B',
      );
      final notice = s.notices.singleWhere(
        (n) => n.kind == NoticeKind.receiveFolderNotSaved,
      );
      expect(notice.detail, b.proposedDir);
      expect(File('${b.proposedDir}\\notes.txt').existsSync(), isTrue);
    }, timeout: transferTimeout);
  });
}
