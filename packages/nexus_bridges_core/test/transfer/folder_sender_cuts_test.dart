@TestOn('windows')
library;

import 'dart:async';
import 'dart:io';

import 'package:nexus_bridges_core/src/protocol/protocol.dart';
import 'package:nexus_bridges_core/src/transfer/folder_plan.dart';
import 'package:nexus_bridges_core/src/transfer/folder_walk.dart';
import 'package:nexus_bridges_core/src/transfer/transfer.dart';
import 'package:nexus_bridges_core/src/transfer/windows_folder_io.dart'
    show DataCheck, checkAgainstData;
import 'package:test/test.dart';

import 'folder_sender_test.dart'
    show
        EntryHook,
        kib,
        long,
        manifestOf,
        namesIn,
        receiverUntouched,
        stacks,
        startSend,
        write;
import 'folder_walk_test.dart' show FakeLister, dir, file;
import 'folder_writer_support.dart' show content;
import 'transfer_stacks_harness.dart';

Future<String> scratch(String prefix) async =>
    (await realFs.realPath((await transferFolder(prefix)).path))!;

String currentAccount() {
  final env = Platform.environment;
  final user = env['USERNAME']!;
  final domain = env['USERDOMAIN'];
  return domain == null || domain.isEmpty ? user : '$domain\\$user';
}

bool skippedUnlessLocked(String folder) {
  final account = currentAccount();
  final made = Process.runSync('icacls', [
    folder,
    '/deny',
    '$account:(OI)(CI)F',
  ]);
  if (made.exitCode == 0) {
    addTearDown(
      () => Process.runSync('icacls', [folder, '/remove:d', account]),
    );
    try {
      Directory(folder).listSync();
    } on FileSystemException {
      return false;
    }
  }
  markTestSkipped(
    'icacls could not deny the folder, or the account bypasses it',
  );
  return true;
}

final class HeldUpload {
  HeldUpload(this.a, this.b, this.hook, this.gate, this.returned);

  final TransferStack a;
  final TransferStack b;
  final EntryHook hook;
  final Completer<void> gate;
  final Future<TransferResultView?> returned;
}

Future<HeldUpload> uploadingHeldAtSecondFile() async {
  final gate = Completer<void>();
  final hook = EntryHook();
  final (a, b) = await stacks(hook: hook);
  a.followRealTime();
  b.followRealTime();
  final root = '${a.sourceDir}\\held';
  write('$root\\a.bin', content(1, 2 * 1024 * kib));
  write('$root\\b.bin', content(2, 2 * 1024 * kib));
  hook.manifest = await manifestOf(root);
  hook.action = (path) async {
    if (path == 'b.bin') await gate.future;
  };
  addTearDown(() {
    if (!gate.isCompleted) gate.complete();
  });
  final returned = startSend(a, b, root);
  await a.phase(OutgoingPhase.uploading);
  await eventually(() => hook.seen.contains('b.bin'), reason: 'held at b.bin');
  await settle(const Duration(milliseconds: 300));
  return HeldUpload(a, b, hook, gate, returned);
}

void main() {
  group('Q-6, E419 [SEG]: cancelling a folder send in every phase', () {
    test(
      'preparing: cancelledHere, no offer and nothing at the receiver',
      () async {
        final (a, b) = await stacks();
        final root = '${a.sourceDir}\\big';
        for (var i = 0; i < 6; i++) {
          write('$root\\f$i.bin', content(i, 64 * 1024 * kib));
        }

        final returned = startSend(a, b, root);
        await a.reached(OutgoingPhase.preparing);
        await settle(const Duration(milliseconds: 150));
        a.coordinator.cancelOutgoing();
        final result = await returned.timeout(const Duration(seconds: 10));

        expect(result?.outcome, TransferOutcome.cancelledHere);
        expect(result?.isFolder, isTrue);
        await settle(const Duration(milliseconds: 300));
        expect(b.offersReceived, 0);
        expect(a.outgoing, isNull);
        await receiverUntouched(b);
      },
      timeout: long,
    );

    test('requesting with the offer held: cancelledHere and nothing at the '
        'receiver', () async {
      final (a, b) = await stacks();
      final root = '${a.sourceDir}\\req';
      write('$root\\a.txt', 'a');
      final hold = Completer<void>();
      addTearDown(() {
        if (!hold.isCompleted) hold.complete();
      });
      b.wrappers[ApiPaths.transferOffer] = (call, inner) async {
        await hold.future;
        return inner(call);
      };

      final returned = startSend(a, b, root);
      await a.reached(OutgoingPhase.requesting);
      await settle(const Duration(milliseconds: 200));
      a.coordinator.cancelOutgoing();
      hold.complete();
      final result = await returned.timeout(const Duration(seconds: 10));

      expect(result?.outcome, TransferOutcome.cancelledHere);
      expect(a.outgoing, isNull);
      await receiverUntouched(b);
    }, timeout: long);

    test('uploading, cancelled by the sender: cancelledHere here and '
        'cancelledByPeer there', () async {
      final held = await uploadingHeldAtSecondFile();
      final HeldUpload(:a, :b, :gate, :returned) = held;

      a.coordinator.cancelOutgoing();
      await settle(const Duration(milliseconds: 100));
      gate.complete();
      final result = await returned.timeout(const Duration(seconds: 15));
      final received = await b.receivedResult();

      expect(result?.outcome, TransferOutcome.cancelledHere);
      expect(received.outcome, TransferOutcome.cancelledByPeer);
      await receiverUntouched(b);
    }, timeout: long);

    test('uploading, cancelled by the receiver: cancelledByPeer here and '
        'cancelledHere there', () async {
      final held = await uploadingHeldAtSecondFile();
      final HeldUpload(:a, :b, :gate, :returned) = held;

      b.coordinator.cancelIncoming(b.incoming!.sessionId);
      await settle(const Duration(milliseconds: 100));
      gate.complete();
      final result = await returned.timeout(const Duration(seconds: 15));
      final received = await b.receivedResult();

      expect(result?.outcome, TransferOutcome.cancelledByPeer);
      expect(received.outcome, TransferOutcome.cancelledHere);
      await receiverUntouched(b);
    }, timeout: long);
  });

  group('Q-6, E419 [SEG]: closing a node or losing the network halfway '
      'through the upload', () {
    test('closing the sender: cancelledHere here and cancelledByPeer '
        'there', () async {
      final held = await uploadingHeldAtSecondFile();
      final HeldUpload(:a, :b, :gate, :returned) = held;

      final closing = a.close();
      await settle(const Duration(milliseconds: 100));
      gate.complete();
      final result = await returned.timeout(const Duration(seconds: 40));
      await closing.timeout(const Duration(seconds: 40));
      final received = await b.receivedResult();

      expect(result?.outcome, TransferOutcome.cancelledHere);
      expect(received.outcome, TransferOutcome.cancelledByPeer);
      await receiverUntouched(b);
    }, timeout: long);

    test('closing the receiver: the sender ends and nothing is kept', () async {
      final held = await uploadingHeldAtSecondFile();
      final HeldUpload(:a, :b, :gate, :returned) = held;

      final closing = b.close();
      await settle(const Duration(milliseconds: 100));
      gate.complete();
      final result = await returned.timeout(const Duration(seconds: 40));
      await closing.timeout(const Duration(seconds: 40));

      expect(
        result?.outcome,
        isIn([TransferOutcome.connectionLost, TransferOutcome.cancelledHere]),
      );
      expect(a.outgoing, isNull);
      expect(Directory(b.tempSub).existsSync(), isFalse);
      expect(namesIn(b.receiveDir), isEmpty);
    }, timeout: long);

    test('the interface going down: interfaceDown here and nothing kept '
        'there', () async {
      final held = await uploadingHeldAtSecondFile();
      final HeldUpload(:a, :b, :gate, :returned) = held;

      a.coordinator.interfacesChanged(<String>{});
      await settle(const Duration(milliseconds: 100));
      gate.complete();
      final result = await returned.timeout(const Duration(seconds: 40));

      expect(result?.outcome, TransferOutcome.interfaceDown);
      expect(a.outgoing, isNull);
      await eventually(
        () => !Directory(b.tempSub).existsSync() && b.incoming == null,
        reason: 'the receiver left as it was',
      );
      expect(namesIn(b.receiveDir), isEmpty);
    }, timeout: long);
  });

  group('Q-2, RF-262 and DP-8: a folder that cannot be identified', () {
    test('the walk stops as unreadable with the relative path', () {
      const root = r'C:\work\proj';
      final tree = <String, List<ListedEntry>>{
        root: [dir('open'), dir('locked')],
        '$root\\open': [file('a.txt')],
        '$root\\locked': [file('b.txt')],
      };

      final result = walkFolder(
        lister: FakeLister(tree),
        rootPath: root,
        exclusions: const {},
        dataDirRealPath: '',
        classifyFolder: (path) => path.endsWith('locked')
            ? DataFolderKind.unknown
            : DataFolderKind.outside,
      );

      expect(result.stopped, TransferOutcome.unreadable);
      expect(result.problemPath, 'locked');
      expect(result.protectedOmitted, 0);
    });

    test('the walk still counts as protected a folder known to be inside '
        'the data folder', () {
      const root = r'C:\work\proj';
      final tree = <String, List<ListedEntry>>{
        root: [dir('open'), dir('twin')],
        '$root\\open': [file('a.txt')],
        '$root\\twin': [file('b.txt')],
      };

      final result = walkFolder(
        lister: FakeLister(tree),
        rootPath: root,
        exclusions: const {},
        dataDirRealPath: '',
        classifyFolder: (path) => path.endsWith('twin')
            ? DataFolderKind.inside
            : DataFolderKind.outside,
      );

      expect(result.stopped, isNull);
      expect(result.protectedOmitted, 1);
    });

    test('an element that does not exist is unreadable, not inData', () async {
      final base = await scratch('nexus_q2_check_');
      final data = '$base\\data';
      write('$data\\paired.json', '{}');

      expect(checkAgainstData('$base\\missing', data), DataCheck.unreadable);
    });

    test('a subfolder without permission stops the plan as unreadable even '
        'with a data folder', () async {
      final base = await scratch('nexus_q2_plan_');
      final root = '$base\\proj';
      final data = '$base\\data';
      write('$data\\paired.json', '{}');
      write('$root\\ok.txt', 'ok');
      write('$root\\locked\\in.txt', 'hidden');
      if (skippedUnlessLocked('$root\\locked')) return;

      final job = FolderPlanJob.start(
        rootRealPath: root,
        name: 'proj',
        exclusions: const [],
        dataDirPath: data,
        dataDirRealPath: data,
        onProgress: (_, _) {},
      );
      final result = await job.result.timeout(const Duration(seconds: 30));

      expect(result, isA<PlanStopped>());
      expect((result as PlanStopped).outcome, TransferOutcome.unreadable);
      expect(result.problemPath, 'locked');
    }, timeout: long);

    test('a subfolder without permission ends the send as unreadable and no '
        'offer leaves', () async {
      final (a, b) = await stacks();
      final root = '${a.sourceDir}\\acl';
      write('$root\\ok.txt', 'ok');
      write('$root\\locked\\in.txt', 'hidden');
      if (skippedUnlessLocked('$root\\locked')) return;

      final result = await startSend(
        a,
        b,
        root,
      ).timeout(const Duration(seconds: 40));

      expect(result?.outcome, TransferOutcome.unreadable);
      expect(result?.problemPath, 'locked');
      expect(result?.isFolder, isTrue);
      expect(b.offersReceived, 0);
      await receiverUntouched(b);
    }, timeout: long);
  });

  group('Q-3, RF-189 and RF-236 of the 004: unpairing while the element is '
      'being checked', () {
    test('ends as unpaired and no offer leaves', () async {
      final (a, b) = await stacks();
      final root = '${a.sourceDir}\\proj';
      write('$root\\a.txt', 'a');
      final reached = Completer<void>();
      final gate = Completer<void>();
      addTearDown(() {
        if (!gate.isCompleted) gate.complete();
      });
      a.platform.hold = (method, path) async {
        if (method == 'realPath' && path == a.dataDir) {
          if (!reached.isCompleted) reached.complete();
          await gate.future;
        }
      };

      final returned = startSend(a, b, root);
      await reached.future.timeout(const Duration(seconds: 10));
      await a.forget(b.fingerprint);
      a.coordinator.pairedChanged();
      await a.coordinator.peerUnpaired(b.fingerprint);
      gate.complete();
      final result = await returned.timeout(const Duration(seconds: 40));

      expect(result?.outcome, TransferOutcome.unpaired);
      expect(b.offersReceived, 0);
      expect(a.outgoingSeen, isEmpty);
      await receiverUntouched(b);
    }, timeout: long);
  });
}
