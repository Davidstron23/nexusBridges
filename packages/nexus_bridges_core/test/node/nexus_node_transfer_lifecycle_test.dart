import 'dart:async';
import 'dart:io';

import 'package:nexus_bridges_core/src/identity/identity.dart';
import 'package:nexus_bridges_core/src/node/node.dart';
import 'package:nexus_bridges_core/src/pairing/pairing.dart' show PeerRelation;
import 'package:nexus_bridges_core/src/protocol/protocol.dart'
    show ApiPaths, Limits;
import 'package:nexus_bridges_core/src/storage/storage.dart';
import 'package:nexus_bridges_core/src/transfer/folders.dart'
    show tempFolderName;
import 'package:nexus_bridges_core/src/transfer/transfer.dart'
    show ReceiveFolder, TempJournal;
import 'package:nexus_bridges_core/src/transport/transport.dart';
import 'package:test/test.dart';

import '../support/infra.dart';
import 'transfer_nodes_harness.dart';

const String _ownTemp =
    '~nexusbridges-0123456789abcdef0123456789abcdef.partial';

const String _ownWitness = '~nexusbridges-0123456789abcdef.hold';

const String _transferCode = 'src/transfer/';

const Duration _lateEnd = Duration(seconds: 45);

List<int> _bytes(int length) => List<int>.generate(length, (i) => i % 251);

Future<String> _bigFile(TransferNode node, String name) =>
    node.sourceFile(name, _bytes(4 * 1024 * 1024));

Future<IncomingTransferView> _receiving(TransferNode b) async {
  final s = await b.until(
    (s) =>
        s.incoming?.stage == IncomingStage.receiving &&
        s.incoming!.receivedBytes > 0,
    reason: '${b.name} receiving bytes',
  );
  return s.incoming!;
}

Future<Duration> _timed(Future<void> Function() action) async {
  final watch = Stopwatch()..start();
  await action();
  return watch.elapsed;
}

void _expectNothingLeft(TransferNode node) {
  expect(
    node.timers.activeBy(_transferCode),
    isEmpty,
    reason: 'transfer timers still active in ${node.name}',
  );
  expect(
    node.logs.where((line) => line.startsWith('transfers close failed')),
    isEmpty,
    reason: 'transfers close of ${node.name} went past its budget',
  );
}

Future<void> _expectPortFree(TransferNode node) async {
  expect(
    await tcpPortFree(node.address, node.port),
    isTrue,
    reason: 'the listener of ${node.name} is still open',
  );
}

Future<int?> _rawUnpair(
  DeviceIdentity caller, {
  required InternetAddress from,
  required TransferNode target,
}) async {
  final reply = await postJson(
    address: target.address,
    port: target.port,
    path: ApiPaths.unpair,
    json: const <String, Object?>{},
    context: caller.clientContext(presentCertificate: true),
    acceptServer: (certificate) {
      try {
        return fingerprintOfCertificate(certificate.der) == target.fingerprint;
      } on FormatException {
        return false;
      }
    },
    sourceAddress: from,
  );
  return reply?.status;
}

Future<String> _journalFolder(TransferNode node, String child) async {
  final folder = '${node.base}\\$child';
  Directory('$folder\\$tempFolderName').createSync(recursive: true);
  final facts = await realFs.volumeFacts(folder);
  expect(facts, isNotNull);
  await TempJournal(JsonFileStore(node.cleanupFile))
      .add(ReceiveFolder(path: folder, volumeId: facts!.volumeId));
  return folder;
}

Future<List<String>> _journalPaths(TransferNode node) async {
  final journal = TempJournal(JsonFileStore(node.cleanupFile));
  await journal.load();
  return [for (final folder in journal.folders) folder.path];
}

void main() {
  group('start of the node (plan "node", point 70, RF-187)', () {
    test('the transfer coordinator ticks before any listener opens, and the '
        'node serves offers and uploads on its own ApiServer', () async {
      final (a, b) = await transferNodes();

      for (final node in [a, b]) {
        final tick = node.logs.indexOf('timer: transfer tick');
        final listening = node.logs.indexWhere(
          (line) => line.startsWith('listening on '),
        );
        expect(tick, isNonNegative, reason: '${node.name} tick timer');
        expect(listening, isNonNegative, reason: '${node.name} listener');
        expect(tick, lessThan(listening), reason: node.name);
        expect(node.timers.createdBy('src/transfer/transfer.dart'), 1);
      }

      final path = await a.sourceFile('first.txt', [1]);
      expect(await a.send(b, path), SendResult.started);
      expect((await a.sentResult()).outcome, TransferOutcome.saved);
      expect(File('${b.recvDir}\\first.txt').readAsBytesSync(), [1]);
    }, timeout: transferTimeout);

    test('cleanupAtStart runs in the background: with it held, the node '
        'starts, an offer gets busy and nothing is saved; once released, the '
        'stale temp is gone and the next send is saved (E165)', () async {
      final gate = Completer<void>();
      addTearDown(() {
        if (!gate.isCompleted) gate.complete();
      });
      late String old;
      final (a, b) = await transferNodes(
        before: (a, b) async {
          old = await _journalFolder(b, 'old');
          File('$old\\$tempFolderName\\$_ownTemp').writeAsBytesSync([1, 2]);
          b.platform.hold = (method, path) async {
            if (path.startsWith(old)) await gate.future;
          };
          b.clock.followRealTime();
        },
      );
      final path = await a.sourceFile('later.txt', [6, 6]);

      expect(await a.send(b, path), SendResult.started);
      final busy = await a.sentResult();
      expect(busy.outcome, TransferOutcome.busy);
      expect(b.state.incoming, isNull);
      expect(b.filesIn(b.recvDir), isEmpty);
      expect(File('$old\\$tempFolderName\\$_ownTemp').existsSync(), isTrue);

      gate.complete();
      await eventually(
        () => !Directory('$old\\$tempFolderName').existsSync(),
        reason: 'stale temp folder swept',
      );
      expect(await a.send(b, path), SendResult.started);
      expect((await a.sentResult(after: busy)).outcome, TransferOutcome.saved);
      expect(File('${b.recvDir}\\later.txt').readAsBytesSync(), [6, 6]);
    }, timeout: transferTimeout);
  });

  group('start after a crash (E126, RF-187)', () {
    test('an own temp and its journal entry made by hand are gone after '
        'start', () async {
      late String old;
      final (_, b) = await transferNodes(
        before: (a, b) async {
          old = await _journalFolder(b, 'old');
          File('$old\\$tempFolderName\\$_ownTemp').writeAsBytesSync([1, 2, 3]);
          expect(await _journalPaths(b), [old]);
        },
      );

      await eventually(
        () => !Directory('$old\\$tempFolderName').existsSync(),
        reason: 'temp folder removed',
      );
      await eventually(
        () async => (await _journalPaths(b)).isEmpty,
        reason: 'journal entry removed',
      );
      expect(Directory(old).existsSync(), isTrue);
    }, timeout: transferTimeout);

    test('a file that is not an own temp is never deleted', () async {
      late String old;
      await transferNodes(
        before: (a, b) async {
          old = await _journalFolder(b, 'old');
          File('$old\\$tempFolderName\\$_ownTemp').writeAsBytesSync([1]);
          File('$old\\$tempFolderName\\keep.txt').writeAsBytesSync([2]);
        },
      );

      await eventually(
        () => !File('$old\\$tempFolderName\\$_ownTemp').existsSync(),
        reason: 'own temp removed',
      );
      expect(File('$old\\$tempFolderName\\keep.txt').readAsBytesSync(), [2]);
    }, timeout: transferTimeout);
  });

  group('start after a crash with shared folders (T6 review) [SEG]', () {
    test('B-1 a journal entry whose path became a junction is neither probed '
        'nor swept, and the entry stays', () async {
      late String link;
      late String target;
      final (a, b) = await transferNodes(
        before: (a, b) async {
          target = '${b.base}\\target';
          Directory('$target\\$tempFolderName').createSync(recursive: true);
          File('$target\\$tempFolderName\\$_ownTemp').writeAsBytesSync([1]);
          Directory('${b.base}\\other').createSync();
          link = '${b.base}\\link';
          final made = Process.runSync('cmd', [
            '/c',
            'mklink',
            '/J',
            link,
            target,
          ]);
          expect(made.exitCode, 0, reason: '${made.stdout}${made.stderr}');
          final facts = await realFs.volumeFacts(target);
          expect(facts, isNotNull);
          await TempJournal(JsonFileStore(b.cleanupFile))
              .add(ReceiveFolder(path: link, volumeId: facts!.volumeId));
        },
      );
      final path = await a.sourceFile('later.txt', [6, 6]);
      expect(await a.send(b, path), SendResult.started);
      expect((await a.sentResult()).outcome, TransferOutcome.saved);

      expect(File('$target\\$tempFolderName\\$_ownTemp').existsSync(), isTrue);
      expect(await _journalPaths(b), [link]);
    }, timeout: transferTimeout);

    test('B-2 an own witness left by a power cut is swept with its temps: '
        'the temp folder and the journal entry go', () async {
      late String old;
      await transferNodes(
        before: (a, b) async {
          old = await _journalFolder(b, 'old');
          File('$old\\$tempFolderName\\$_ownWitness').writeAsBytesSync([]);
          File('$old\\$tempFolderName\\$_ownTemp').writeAsBytesSync([1]);
          File('$old\\$tempFolderName\\keep.txt').writeAsBytesSync([2]);
        },
      );

      await eventually(
        () =>
            !File('$old\\$tempFolderName\\$_ownWitness').existsSync() &&
            !File('$old\\$tempFolderName\\$_ownTemp').existsSync(),
        reason: 'witness and temp removed',
      );
      expect(File('$old\\$tempFolderName\\keep.txt').readAsBytesSync(), [2]);
    }, timeout: transferTimeout);

    test('B-2 with only the witness left, the temp folder and the journal '
        'entry disappear', () async {
      late String old;
      final (_, b) = await transferNodes(
        before: (a, b) async {
          old = await _journalFolder(b, 'old');
          File('$old\\$tempFolderName\\$_ownWitness').writeAsBytesSync([]);
        },
      );

      await eventually(
        () => !Directory('$old\\$tempFolderName').existsSync(),
        reason: 'temp folder removed',
      );
      await eventually(
        () async => (await _journalPaths(b)).isEmpty,
        reason: 'journal entry removed',
      );
    }, timeout: transferTimeout);
  });

  group('closing with a send in progress (E125, RF-185, RF-186)', () {
    test('transferInProgress is true in both during the upload; shutting the '
        'receiver down mid upload deletes its temp, the sender sees the cut, '
        'and neither leaves transfer timers, temps nor listeners', () async {
      final (a, b) = await transferNodes();
      b.writes.delay = const Duration(milliseconds: 40);
      final path = await _bigFile(a, 'big.bin');

      expect(a.state.transferInProgress, isFalse);
      expect(b.state.transferInProgress, isFalse);
      expect(await a.send(b, path), SendResult.started);
      await _receiving(b);
      expect(a.state.transferInProgress, isTrue);
      expect(b.state.transferInProgress, isTrue);
      expect(a.state.outgoing?.phase, OutgoingPhase.uploading);

      final took = await _timed(b.stop);
      expect(took, lessThan(Limits.transferCloseBudget));
      expect(b.tempLeftIn(b.recvDir), isFalse);
      expect(b.filesIn(b.recvDir), isEmpty);

      final sent = await a.sentResult();
      expect(
        sent.outcome,
        anyOf(TransferOutcome.cancelledByPeer, TransferOutcome.connectionLost),
      );
      await a.until((s) => !s.transferInProgress, reason: 'A idle');
      await a.stop();

      _expectNothingLeft(a);
      _expectNothingLeft(b);
      await _expectPortFree(a);
      await _expectPortFree(b);
    }, timeout: transferTimeout);

    test('shutting the sender down mid upload: the receiver ends with no '
        'temp and the sender leaves nothing running', () async {
      final (a, b) = await transferNodes();
      b.writes.delay = const Duration(milliseconds: 40);
      final path = await _bigFile(a, 'big.bin');

      expect(await a.send(b, path), SendResult.started);
      await _receiving(b);

      final took = await _timed(a.stop);
      expect(took, lessThan(Limits.transferCloseBudget));
      final received = await b.receivedResult();
      expect(
        received.outcome,
        anyOf(TransferOutcome.cancelledByPeer, TransferOutcome.connectionLost),
      );
      await eventually(
        () => !b.tempLeftIn(b.recvDir),
        reason: 'temp deleted in B',
      );
      expect(b.filesIn(b.recvDir), isEmpty);
      _expectNothingLeft(a);
      await _expectPortFree(a);
    }, timeout: transferTimeout);

    test('shutting the receiver down with the warning open: the sender sees '
        'declined', () async {
      final (a, b) = await transferNodes(
        aAtB: PeerRelation.foreign,
        before: (a, b) async {
          b.transferPollHold = const Duration(seconds: 3);
          a.clock.followRealTime();
        },
      );
      final path = await a.sourceFile('doc.txt', [1, 2]);

      expect(await a.send(b, path), SendResult.started);
      await b.incomingAt(IncomingStage.warning);
      expect(b.state.transferInProgress, isTrue);
      await Future<void>.delayed(const Duration(milliseconds: 1500));

      await b.stop();

      expect((await a.sentResult()).outcome, TransferOutcome.declined);
      expect(b.filesIn(b.recvDir), isEmpty);
      _expectNothingLeft(b);
    }, timeout: transferTimeout);

    test('shutting the receiver down while it verifies (mark held 1 s) and '
        'with a wait held: the transfers close finishes within its 4 s, the '
        'file is saved whole with no temp and the sender sees saved', () async {
      final marking = Completer<void>();
      final (a, b) = await transferNodes(
        before: (a, b) async {
          b.transferPollHold = const Duration(seconds: 3);
          b.platform.mark = (filePath) async {
            if (!marking.isCompleted) marking.complete();
            await Future<void>.delayed(const Duration(seconds: 1));
            return realFs.markFromInternet(filePath);
          };
        },
      );
      final path = await a.sourceFile('slow.txt', _bytes(5000));

      expect(await a.send(b, path), SendResult.started);
      await marking.future.timeout(scaled(transferWait));
      await a.until(
        (s) => s.outgoing?.phase == OutgoingPhase.verifying,
        reason: 'A verifying',
      );

      final took = await _timed(b.stop);

      expect(took, lessThan(Limits.transferCloseBudget));
      expect(b.tempLeftIn(b.recvDir), isFalse);
      expect(b.filesIn(b.recvDir), ['slow.txt']);
      expect(File('${b.recvDir}\\slow.txt').readAsBytesSync(), _bytes(5000));
      _expectNothingLeft(b);
      await _expectPortFree(b);
      expect((await a.sentResult()).outcome, TransferOutcome.saved);
    }, timeout: transferTimeout);

    test('shutting the receiver down while the mark takes 3.5 s, longer than '
        'the 2 s close waits for finishing (R69): the close keeps its budget, '
        'the sender ends unconfirmed and never saved, and the verified file '
        'lands whole in the approved folder afterwards with no temp', () async {
      final marking = Completer<void>();
      final (a, b) = await transferNodes(
        before: (a, b) async {
          a.clock.followRealTime();
          b.platform.mark = (filePath) async {
            if (!marking.isCompleted) marking.complete();
            await Future<void>.delayed(const Duration(milliseconds: 3500));
            return realFs.markFromInternet(filePath);
          };
        },
      );
      final path = await a.sourceFile('slow.txt', _bytes(5000));

      expect(await a.send(b, path), SendResult.started);
      await marking.future.timeout(scaled(transferWait));

      final took = await _timed(b.stop);

      expect(took, lessThan(Limits.transferCloseBudget));
      await _expectPortFree(b);
      final sent = await a.sentResult(limit: const Duration(seconds: 60));
      expect(sent.outcome, TransferOutcome.unconfirmed);
      expect(
        a.states.any((s) => s.lastSent?.outcome == TransferOutcome.saved),
        isFalse,
      );
      await eventually(
        () => b.filesIn(b.recvDir).contains('slow.txt'),
        limit: scaled(transferWait),
        reason: 'the verified file saved after the close',
      );
      await eventually(
        () => !b.tempLeftIn(b.recvDir),
        limit: scaled(transferWait),
        reason: 'temp gone after the late save',
      );
      expect(b.filesIn(b.recvDir), ['slow.txt']);
      expect(File('${b.recvDir}\\slow.txt').readAsBytesSync(), _bytes(5000));
    }, timeout: transferTimeout);
  });

  group('short notice when the sender cancels (E177, RF-156, RF-233, '
      'RF-240)', () {
    Future<(TransferNode, TransferNode, TransferResultView, TransferResultView)>
    withEarlierReception() async {
      final (a, b) = await transferNodes(aAtB: PeerRelation.foreign);
      final path = await a.sourceFile('earlier.txt', [1]);
      expect(await a.send(b, path), SendResult.started);
      b.node.answerIncoming(
        (await b.incomingAt(IncomingStage.warning)).sessionId,
        accept: true,
      );
      final sent = await a.sentResult();
      final received = await b.receivedResult();
      expect(received.outcome, TransferOutcome.saved);
      return (a, b, sent, received);
    }

    test('A cancels with the warning open: the card goes away, B shows '
        'peerCancelledTransfer with the name of A and keeps the earlier '
        'reception', () async {
      final (a, b, earlierSent, earlier) = await withEarlierReception();
      final path = await a.sourceFile('second.txt', [2]);

      expect(await a.send(b, path), SendResult.started);
      await b.incomingAt(IncomingStage.warning);
      a.node.cancelSending();

      expect(
        (await a.sentResult(after: earlierSent)).outcome,
        TransferOutcome.cancelledHere,
      );
      final s = await b.until(
        (s) =>
            s.incoming == null &&
            s.notices.any((n) => n.kind == NoticeKind.peerCancelledTransfer),
        reason: 'card withdrawn in B',
      );
      final notice = s.notices.singleWhere(
        (n) => n.kind == NoticeKind.peerCancelledTransfer,
      );
      expect(notice.detail, 'Desk PC · ${shortFingerprint(a.fingerprint)}');
      expect(s.lastReceived, earlier);
      await b.until((s) => !s.transferInProgress, reason: 'B idle');
    }, timeout: transferTimeout);

    test('A shuts down with the warning open in B: same short notice and '
        'the earlier reception stays', () async {
      final (a, b, _, earlier) = await withEarlierReception();
      final path = await a.sourceFile('second.txt', [2]);

      expect(await a.send(b, path), SendResult.started);
      await b.incomingAt(IncomingStage.warning);
      await a.stop();

      final s = await b.until(
        (s) =>
            s.incoming == null &&
            s.notices.any((n) => n.kind == NoticeKind.peerCancelledTransfer),
        reason: 'card withdrawn in B',
      );
      expect(
        s.notices
            .singleWhere((n) => n.kind == NoticeKind.peerCancelledTransfer)
            .detail,
        'Desk PC · ${shortFingerprint(a.fingerprint)}',
      );
      expect(s.lastReceived, earlier);
      _expectNothingLeft(a);
    }, timeout: transferTimeout);

    test('A cancels before B shows anything: nothing at all in B', () async {
      final (a, b, earlierSent, earlier) = await withEarlierReception();
      final gate = Completer<void>();
      addTearDown(() {
        if (!gate.isCompleted) gate.complete();
      });
      final calls = b.platform.volumeCalls;
      b.platform.volumeGate = gate;
      final notices = b.state.notices;
      final mark = b.states.length;
      final path = await a.sourceFile('second.txt', [2]);

      expect(await a.send(b, path), SendResult.started);
      await eventually(
        () => b.platform.volumeCalls > calls,
        reason: 'B checking the offer',
      );
      a.node.cancelSending();
      expect(
        (await a.sentResult(after: earlierSent)).outcome,
        TransferOutcome.cancelledHere,
      );
      gate.complete();
      await Future<void>.delayed(const Duration(milliseconds: 500));

      expect(b.states.skip(mark).where((s) => s.incoming != null), isEmpty);
      expect(b.state.notices, notices);
      expect(b.state.lastReceived, earlier);
      await b.until((s) => !s.transferInProgress, reason: 'B idle');
    }, timeout: transferTimeout);
  });

  group('unpairing during a send (E120, E170, RF-189, RF-236, RF-237)', () {
    test('A unpairs B with the warning open in B: B gets the cancel before '
        'the unpair notice and A sees unpaired (E120)', () async {
      final (a, b) = await transferNodes(aAtB: PeerRelation.foreign);
      final path = await a.sourceFile('x.txt', [1]);

      expect(await a.send(b, path), SendResult.started);
      await b.incomingAt(IncomingStage.warning);
      await a.node.unpair(b.fingerprint);

      expect((await a.sentResult()).outcome, TransferOutcome.unpaired);
      final s = await b.until(
        (s) =>
            s.notices.any((n) => n.kind == NoticeKind.unpairedByPeer) &&
            s.incoming == null,
        reason: 'unpair notice in B',
      );
      final cancelled = s.notices.where(
        (n) => n.kind == NoticeKind.peerCancelledTransfer,
      );
      final unpaired = s.notices.singleWhere(
        (n) => n.kind == NoticeKind.unpairedByPeer,
      );
      expect(cancelled, hasLength(1));
      expect(cancelled.single.id, lessThan(unpaired.id));
      expect(s.lastReceived, isNull);
    }, timeout: transferTimeout);

    test('A unpairs B mid upload: A sees unpaired, B ends with no temp and '
        'nothing saved (E170)', () async {
      final (a, b) = await transferNodes();
      b.writes.delay = const Duration(milliseconds: 40);
      final path = await _bigFile(a, 'big.bin');

      expect(await a.send(b, path), SendResult.started);
      await _receiving(b);
      await a.node.unpair(b.fingerprint);

      expect((await a.sentResult()).outcome, TransferOutcome.unpaired);
      final received = await b.receivedResult();
      expect(
        received.outcome,
        anyOf(TransferOutcome.cancelledByPeer, TransferOutcome.unpaired),
      );
      await eventually(
        () => !b.tempLeftIn(b.recvDir),
        reason: 'temp deleted in B',
      );
      expect(b.filesIn(b.recvDir), isEmpty);
      await b.until(
        (s) => s.notices.any((n) => n.kind == NoticeKind.unpairedByPeer),
        reason: 'unpair notice in B',
      );
    }, timeout: transferTimeout);

    test('an unpair notice of the 003 reaching B mid upload, with no cancel '
        'before it: B ends unpaired with no temp and A does not save '
        '(E170)', () async {
      final (a, b) = await transferNodes();
      b.writes.delay = const Duration(milliseconds: 40);
      final path = await _bigFile(a, 'big.bin');
      final identityA = await a.loadIdentity();
      a.clock.followRealTime();

      expect(await a.send(b, path), SendResult.started);
      await _receiving(b);
      expect(await _rawUnpair(identityA, from: a.address, target: b), 200);

      expect((await b.receivedResult()).outcome, TransferOutcome.unpaired);
      await eventually(
        () => !b.tempLeftIn(b.recvDir),
        reason: 'temp deleted in B',
      );
      expect(b.filesIn(b.recvDir), isEmpty);
      final sent = await a.sentResult(limit: _lateEnd);
      expect(sent.outcome.kind, isNot(TransferResultKind.saved));
    }, timeout: transferTimeout);

    test('B unpairs A mid upload: B ends unpaired with no temp and A does '
        'not save (E170, RF-189)', () async {
      final (a, b) = await transferNodes();
      b.writes.delay = const Duration(milliseconds: 40);
      final path = await _bigFile(a, 'big.bin');

      expect(await a.send(b, path), SendResult.started);
      await _receiving(b);
      a.clock.followRealTime();
      await b.node.unpair(a.fingerprint);

      expect((await b.receivedResult()).outcome, TransferOutcome.unpaired);
      await eventually(
        () => !b.tempLeftIn(b.recvDir),
        reason: 'temp deleted in B',
      );
      expect(b.filesIn(b.recvDir), isEmpty);
      final sent = await a.sentResult(limit: _lateEnd);
      expect(sent.outcome.kind, isNot(TransferResultKind.saved));
    }, timeout: transferTimeout);
  });

  group('interfaces reach the transfers (plan "node", _syncAllLocked)', () {
    test('the network of the sender goes away mid upload: A ends with '
        'interfaceDown and B keeps no temp', () async {
      final (a, b) = await transferNodes(
        before: (a, b) async {
          a.pollInterval = const Duration(milliseconds: 50);
        },
      );
      b.writes.delay = const Duration(milliseconds: 40);
      final path = await _bigFile(a, 'big.bin');

      expect(await a.send(b, path), SendResult.started);
      await _receiving(b);
      a.adapters = [];

      expect((await a.sentResult()).outcome, TransferOutcome.interfaceDown);
      await b.receivedResult();
      await eventually(
        () => !b.tempLeftIn(b.recvDir),
        reason: 'temp deleted in B',
      );
      expect(b.filesIn(b.recvDir), isEmpty);
    }, timeout: transferTimeout);

    test('the network of the receiver goes away mid upload: B ends with '
        'interfaceDown and no temp', () async {
      final (a, b) = await transferNodes(
        before: (a, b) async {
          b.pollInterval = const Duration(milliseconds: 50);
        },
      );
      b.writes.delay = const Duration(milliseconds: 40);
      final path = await _bigFile(a, 'big.bin');

      expect(await a.send(b, path), SendResult.started);
      await _receiving(b);
      a.clock.followRealTime();
      b.adapters = [];

      expect((await b.receivedResult()).outcome, TransferOutcome.interfaceDown);
      await eventually(
        () => !b.tempLeftIn(b.recvDir),
        reason: 'temp deleted in B',
      );
      expect(b.filesIn(b.recvDir), isEmpty);
      final sent = await a.sentResult(limit: _lateEnd);
      expect(sent.outcome.kind, isNot(TransferResultKind.saved));
    }, timeout: transferTimeout);
  });
}
