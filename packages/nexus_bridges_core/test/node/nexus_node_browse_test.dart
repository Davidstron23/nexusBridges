@TestOn('windows')
library;

import 'dart:async';
import 'dart:io';

import 'package:nexus_bridges_core/src/browse/browse.dart';
import 'package:nexus_bridges_core/src/node/node.dart';
import 'package:nexus_bridges_core/src/pairing/pairing.dart' show PeerRelation;
import 'package:nexus_bridges_core/src/transfer/platform.dart'
    show FreeNameMove;
import 'package:nexus_bridges_core/src/transfer/transfer.dart'
    show
        ForbiddenFolders,
        SharedFolderDestination,
        TransferOutcome,
        tempFolderName;
import 'package:test/test.dart';

import '../support/infra.dart';
import 'transfer_nodes_harness.dart';

final class HangingPrepareShareFileSystem implements ShareWriteFileSystem {
  HangingPrepareShareFileSystem(this.real);

  final ShareWriteFileSystem real;
  Completer<void>? prepareGate;
  final Completer<void> prepareStarted = Completer<void>();
  int prepared = 0;
  int released = 0;

  @override
  Future<ForbiddenFolders?> forbiddenFolders() => real.forbiddenFolders();

  @override
  Future<String?> profilePath() => real.profilePath();

  @override
  Future<LevelZeroFacts> levelZero(
    List<ShareRecord> roots,
    List<(ShareRecord, List<String>)> checks, {
    required Duration budget,
  }) => real.levelZero(roots, checks, budget: budget);

  @override
  Future<FolderListing> listFolders(
    ShareRecord root,
    List<String> path, {
    required Duration cap,
    required int max,
  }) => real.listFolders(root, path, cap: cap, max: max);

  @override
  Future<bool> exists(String path) => real.exists(path);

  @override
  Future<ShareProbe?> probe(String path) => real.probe(path);

  @override
  Future<ChainResult> openChain(
    ShareRecord root,
    List<String> path, {
    String? newFolder,
  }) => real.openChain(root, path, newFolder: newFolder);

  @override
  Future<bool> prepareChain(ChainHandles chain) async {
    if (!prepareStarted.isCompleted) prepareStarted.complete();
    final gate = prepareGate;
    if (gate != null) await gate.future;
    prepared++;
    return real.prepareChain(chain);
  }

  @override
  Future<FreeNameMove> recheckAndMove(
    ChainHandles chain, {
    required String tempName,
    required bool isFolder,
    required String name,
    int? maxNameUnits,
  }) => real.recheckAndMove(
    chain,
    tempName: tempName,
    isFolder: isFolder,
    name: name,
    maxNameUnits: maxNameUnits,
  );

  @override
  Future<void> releaseChain(ChainHandles chain, {required bool saved}) async {
    released++;
    await real.releaseChain(chain, saved: saved);
  }
}

const String zoneMark = '[ZoneTransfer]\r\nZoneId=3\r\n';

final RegExp hex32 = RegExp(r'^[0-9a-f]{32}$');

void junction(String link, String target) {
  final made = Process.runSync('cmd', [
    '/c',
    'mklink',
    '/J',
    link,
    target,
  ], workingDirectory: Directory.systemTemp.path);
  expect(made.exitCode, 0, reason: '${made.stdout}${made.stderr}');
}

void hide(String path) {
  final made = Process.runSync('attrib', [
    '+h',
    path,
  ], workingDirectory: Directory.systemTemp.path);
  expect(made.exitCode, 0, reason: '${made.stdout}${made.stderr}');
}

String docsOf(TransferNode node) => '${node.base}\\docs';

void makeDocs(TransferNode receiver) {
  final docs = docsOf(receiver);
  Directory('$docs\\sub').createSync(recursive: true);
  Directory('$docs\\otra').createSync();
  Directory('$docs\\oculta').createSync();
  hide('$docs\\oculta');
  File('$docs\\suelto.txt').writeAsStringSync('suelto');
  Directory('${receiver.base}\\fuera\\centinela').createSync(recursive: true);
  junction('$docs\\union', '${receiver.base}\\fuera');
}

Future<String> shareDocs(TransferNode receiver, TransferNode sender) async {
  makeDocs(receiver);
  receiver.picker.nextFolder = docsOf(receiver);
  final added = await receiver.node.addShare(sender.fingerprint);
  expect(added, isA<ShareAdded>());
  expect((added as ShareAdded).saved, isTrue);
  final zero = await sender.node.listRemoteRoots(receiver.fingerprint);
  expect(zero, isA<RemoteRoots>());
  final root = (zero as RemoteRoots).roots.single;
  return root.id;
}

Future<TransferResultView> sendTo(
  TransferNode sender,
  TransferNode receiver,
  String fileName,
  List<int> bytes,
  SharedFolderDestination destination,
) async {
  final before = sender.state.lastSent;
  final path = await sender.sourceFile(fileName, bytes);
  final result = await sender.node.sendPaths(receiver.fingerprint, [
    path,
  ], destination: destination);
  expect(result, anyOf(SendResult.started, SendResult.queued));
  return sender.sentResult(after: before);
}

bool exists(String path) =>
    FileSystemEntity.typeSync(path, followLinks: false) !=
    FileSystemEntityType.notFound;

void expectCleanLogs(List<TransferNode> nodes, List<String> hidden) {
  final words = [
    for (final word in ['sub', 'otra', 'nueva', 'oculta'])
      RegExp('\\b$word\\b'),
  ];
  for (final node in nodes) {
    final text = node.logs.join('\n');
    for (final item in hidden) {
      expect(
        text.toUpperCase(),
        isNot(contains(item.toUpperCase())),
        reason: '${node.name} logged $item',
      );
    }
    for (final word in words) {
      expect(text, isNot(matches(word)), reason: '${node.name} logged $word');
    }
  }
}

void main() {
  group('E720 walking skeleton with two real nodes (T1a and T1b)', () {
    test('E720 the sender sees the granted root and only the allowed folders, '
        'sends to docs\\sub and to a new folder with the mark, no question, '
        'no temp folder left and clean logs', () async {
      final (a, b) = await transferNodes();
      final docs = docsOf(b);
      final rootId = await shareDocs(b, a);
      expect(rootId, matches(hex32));

      final zero = await a.node.listRemoteRoots(b.fingerprint);
      final root = (zero as RemoteRoots).roots.single;
      expect(root.name, 'docs');
      expect(root.home, isFalse);
      expect(root.available, isTrue);
      expect(zero.checks, isEmpty);

      final listed = await a.node.listRemoteFolders(
        b.fingerprint,
        rootId,
        const [],
      );
      expect(listed, isA<RemoteFolders>());
      expect((listed as RemoteFolders).names, ['otra', 'sub']);
      expect(listed.more, isFalse);
      expect(listed.partial, isFalse);
      final inside = await a.node.listRemoteFolders(b.fingerprint, rootId, [
        'sub',
      ]);
      expect((inside as RemoteFolders).names, isEmpty);

      for (final trap in [
        ['union'],
        ['oculta'],
        ['suelto.txt'],
        ['..'],
        ['falta'],
      ]) {
        final refused = await a.node.listRemoteFolders(
          b.fingerprint,
          rootId,
          trap,
        );
        expect(
          refused,
          isA<RemoteListingFailed>().having(
            (f) => f.reason,
            'reason',
            BrowseFailure.unavailable,
          ),
          reason: '$trap',
        );
      }
      final invented = await a.node.listRemoteFolders(
        b.fingerprint,
        'f' * 32,
        const [],
      );
      expect(
        (invented as RemoteListingFailed).reason,
        BrowseFailure.notAllowed,
      );

      final receivedBefore = b.state.lastReceived;
      final sent = await sendTo(
        a,
        b,
        'informe.txt',
        [1, 2, 3, 4, 5],
        SharedFolderDestination(
          rootId: rootId,
          rootName: root.name,
          path: const ['sub'],
        ),
      );
      final received = await b.receivedResult(after: receivedBefore);
      expect(sent.outcome, TransferOutcome.saved);
      expect(received.outcome, TransferOutcome.saved);
      expect(sent.destination?.display(homeName: 'Home'), r'docs\sub');
      expect(received.destination?.display(homeName: 'Home'), r'docs\sub');
      expect(File('$docs\\sub\\informe.txt').readAsBytesSync(), [
        1,
        2,
        3,
        4,
        5,
      ]);
      expect(
        File('$docs\\sub\\informe.txt:Zone.Identifier').readAsStringSync(),
        zoneMark,
      );
      expect(File('${b.recvDir}\\informe.txt').existsSync(), isFalse);
      await eventually(
        () => !exists('$docs\\sub\\$tempFolderName'),
        limit: scaled(transferWait),
        reason: 'temp folder in docs\\sub removed',
      );

      final receivedAgain = b.state.lastReceived;
      final intoNew = await sendTo(
        a,
        b,
        'nuevo.txt',
        [9, 8, 7],
        SharedFolderDestination(
          rootId: rootId,
          rootName: root.name,
          path: const ['sub'],
          newFolder: 'nueva',
        ),
      );
      final receivedNew = await b.receivedResult(after: receivedAgain);
      expect(intoNew.outcome, TransferOutcome.saved);
      expect(receivedNew.outcome, TransferOutcome.saved);
      expect(
        receivedNew.destination?.display(homeName: 'Home'),
        r'docs\sub\nueva',
      );
      expect(File('$docs\\sub\\nueva\\nuevo.txt').readAsBytesSync(), [9, 8, 7]);
      expect(
        File('$docs\\sub\\nueva\\nuevo.txt:Zone.Identifier').readAsStringSync(),
        zoneMark,
      );
      await eventually(
        () => !exists('$docs\\sub\\nueva\\$tempFolderName'),
        limit: scaled(transferWait),
        reason: 'temp folder in the new folder removed',
      );

      for (final state in b.states) {
        expect(state.incoming?.stage, isNot(IncomingStage.warning));
        expect(state.incoming?.stage, isNot(IncomingStage.folderQuestion));
      }
      expect(b.state.prompts, isEmpty);
      expect(
        Directory('${b.base}\\fuera')
            .listSync()
            .map((e) => e.path.split(r'\').last),
        ['centinela'],
      );
      expect(Directory('$docs\\sub').listSync(), hasLength(2));
      expectCleanLogs([a, b], [docs, rootId]);
    }, timeout: transferTimeout);

    test('G9 offer step 1: an invented root, a missing folder and a junction '
        'are refused with nothing written in docs', () async {
      final (a, b) = await transferNodes();
      final docs = docsOf(b);
      final rootId = await shareDocs(b, a);
      final cases = <(SharedFolderDestination, TransferOutcome)>[
        (
          const SharedFolderDestination(
            rootId: 'ffffffffffffffffffffffffffffffff',
            rootName: 'docs',
            path: [],
          ),
          TransferOutcome.destinationUnavailable,
        ),
        (
          SharedFolderDestination(
            rootId: rootId,
            rootName: 'docs',
            path: const ['falta'],
          ),
          TransferOutcome.destinationMissing,
        ),
        (
          SharedFolderDestination(
            rootId: rootId,
            rootName: 'docs',
            path: const ['falta'],
            newFolder: 'nueva',
          ),
          TransferOutcome.destinationMissing,
        ),
        (
          SharedFolderDestination(
            rootId: rootId,
            rootName: 'docs',
            path: const ['union'],
          ),
          TransferOutcome.destinationUnavailable,
        ),
        (
          SharedFolderDestination(
            rootId: rootId,
            rootName: 'docs',
            path: const ['oculta'],
          ),
          TransferOutcome.destinationUnavailable,
        ),
        (
          SharedFolderDestination(
            rootId: rootId,
            rootName: 'docs',
            path: const ['..'],
          ),
          TransferOutcome.destinationUnavailable,
        ),
        (
          SharedFolderDestination(
            rootId: rootId,
            rootName: 'docs',
            path: const [],
            newFolder: 'CON',
          ),
          TransferOutcome.destinationUnavailable,
        ),
      ];
      var n = 0;
      for (final (destination, outcome) in cases) {
        final sent = await sendTo(a, b, 'trampa$n.txt', [n], destination);
        expect(sent.outcome, outcome, reason: '${destination.path}');
        n++;
      }
      final names = [
        for (final entity in Directory(
          docs,
        ).listSync(recursive: true, followLinks: false))
          entity.path.substring(docs.length + 1),
      ]..sort();
      expect(names, ['oculta', 'otra', 'sub', 'suelto.txt', 'union']);
      expect(
        Directory('${b.base}\\fuera')
            .listSync()
            .map((e) => e.path.split(r'\').last),
        ['centinela'],
      );
      expect(b.state.lastReceived, isNull);
      expectCleanLogs([a, b], [docs, rootId]);
    }, timeout: transferTimeout);

    test(
      'G9 a sender that is foreign here gets default_only and may not browse',
      () async {
        final (a, b) = await transferNodes(aAtB: PeerRelation.foreign);
        makeDocs(b);
        b.picker.nextFolder = docsOf(b);
        expect(await b.node.addShare(a.fingerprint), isA<ShareRefused>());
        final zero = await a.node.listRemoteRoots(b.fingerprint);
        expect((zero as RemoteListingFailed).reason, BrowseFailure.notAllowed);
        final sent = await sendTo(
          a,
          b,
          'ajeno.txt',
          [1],
          const SharedFolderDestination(
            rootId: 'ffffffffffffffffffffffffffffffff',
            rootName: 'docs',
            path: ['sub'],
          ),
        );
        expect(sent.outcome, TransferOutcome.defaultFolderOnly);
        expect(b.state.incoming, isNull);
        expect(exists('${docsOf(b)}\\sub\\ajeno.txt'), isFalse);
        expect(File('${b.recvDir}\\ajeno.txt').existsSync(), isFalse);
      },
      timeout: transferTimeout,
    );
  });

  group('Security review fixes of the PR 1 (B-2 and B-5)', () {
    test('B-2 a file in path answers like a missing folder and a new folder '
        'named like a file is still refused', () async {
      final (a, b) = await transferNodes();
      final docs = docsOf(b);
      final rootId = await shareDocs(b, a);
      final cases = <(SharedFolderDestination, TransferOutcome)>[
        (
          SharedFolderDestination(
            rootId: rootId,
            rootName: 'docs',
            path: const ['falta'],
          ),
          TransferOutcome.destinationMissing,
        ),
        (
          SharedFolderDestination(
            rootId: rootId,
            rootName: 'docs',
            path: const ['suelto.txt'],
          ),
          TransferOutcome.destinationMissing,
        ),
        (
          SharedFolderDestination(
            rootId: rootId,
            rootName: 'docs',
            path: const ['suelto.txt', 'dentro'],
          ),
          TransferOutcome.destinationMissing,
        ),
        (
          SharedFolderDestination(
            rootId: rootId,
            rootName: 'docs',
            path: const [],
            newFolder: 'suelto.txt',
          ),
          TransferOutcome.destinationUnavailable,
        ),
        (
          SharedFolderDestination(
            rootId: rootId,
            rootName: 'docs',
            path: const ['oculta'],
          ),
          TransferOutcome.destinationUnavailable,
        ),
      ];
      var n = 0;
      for (final (destination, outcome) in cases) {
        final sent = await sendTo(a, b, 'archivo$n.txt', [n], destination);
        expect(sent.outcome, outcome, reason: '${destination.path}');
        n++;
      }
      expect(File('$docs\\suelto.txt').readAsStringSync(), 'suelto');
      expect(b.state.lastReceived, isNull);
      expectCleanLogs([a, b], [docs, rootId]);
    }, timeout: transferTimeout);

    test('B-5 a prepare that never comes back gives up at 1.5 s, the sender '
        'is told, the receiver is free for the next send and the late chain '
        'is closed', () async {
      late HangingPrepareShareFileSystem hanging;
      final (a, b) = await transferNodes(
        before: (a, b) async {
          hanging = HangingPrepareShareFileSystem(
            WindowsShareFileSystem(
              platform: b.platform,
              dataDirs: [b.dataPath],
            ),
          );
          b.shareFileSystem = hanging;
        },
      );
      final docs = docsOf(b);
      final rootId = await shareDocs(b, a);
      final gate = hanging.prepareGate = Completer<void>();
      final before = a.state.lastSent;
      final path = await a.sourceFile('cuelga.txt', [1, 2, 3]);
      final started = await a.node.sendPaths(
        b.fingerprint,
        [path],
        destination: SharedFolderDestination(
          rootId: rootId,
          rootName: 'docs',
          path: const ['sub'],
        ),
      );
      expect(started, anyOf(SendResult.started, SendResult.queued));
      await hanging.prepareStarted.future.timeout(scaled(transferWait));
      b.clock.advance(const Duration(seconds: 2));
      final sent = await a.sentResult(after: before);
      expect(sent.outcome, TransferOutcome.destinationUnavailable);
      expect(b.state.incoming, isNull);
      expect(hanging.prepared, 0);

      final next = a.state.lastSent;
      final other = await a.sourceFile('libre.txt', [9, 9]);
      final again = await a.node.sendPaths(b.fingerprint, [other]);
      expect(again, anyOf(SendResult.started, SendResult.queued));
      final done = await a.sentResult(after: next);
      expect(done.outcome, TransferOutcome.saved);
      expect(File('${b.recvDir}\\libre.txt').readAsBytesSync(), [9, 9]);

      gate.complete();
      await eventually(
        () => hanging.released == 1,
        limit: scaled(transferWait),
        reason: 'late chain released',
      );
      await eventually(
        () => !exists('$docs\\sub\\$tempFolderName'),
        limit: scaled(transferWait),
        reason: 'temp folder removed by the late release',
      );
      Directory('$docs\\sub').renameSync('$docs\\sub2');
      Directory('$docs\\sub2').renameSync('$docs\\sub');
      expect(File('$docs\\sub\\cuelga.txt').existsSync(), isFalse);
    }, timeout: transferTimeout);
  });
}
