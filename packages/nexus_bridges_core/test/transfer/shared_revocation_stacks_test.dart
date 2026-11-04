@TestOn('windows')
library;

import 'dart:async';
import 'dart:io';

import 'package:nexus_bridges_core/src/browse/browse.dart';
import 'package:nexus_bridges_core/src/pairing/pairing.dart';
import 'package:nexus_bridges_core/src/protocol/protocol.dart';
import 'package:nexus_bridges_core/src/storage/storage.dart';
import 'package:nexus_bridges_core/src/transfer/folder_writer.dart'
    show ClearHidden;
import 'package:nexus_bridges_core/src/transfer/transfer.dart';
import 'package:test/test.dart';
import 'package:win32/win32.dart' show HANDLE;

import '../browse/share_fs_fakes.dart';
import 'transfer_stacks_harness.dart';

const Timeout long = Timeout(Duration(seconds: 60));

bool slowClearHidden(HANDLE handle) {
  sleep(const Duration(milliseconds: 900));
  return true;
}

final class FrozenShared implements SharedFolders {
  FrozenShared(this.real);

  final SharedFolders real;
  bool revoked = false;

  @override
  Stream<void> get changes => const Stream<void>.empty();

  @override
  SharedRootGrant? grantFor(String fingerprint, String rootId) =>
      revoked ? null : real.grantFor(fingerprint, rootId);

  @override
  Future<SharedResolution> resolve(
    String fingerprint,
    DestinationRequest destination, {
    required Duration timeout,
  }) => real.resolve(fingerprint, destination, timeout: timeout);
}

final class Bench {
  Bench(this.a, this.b, this.service, this.fs, this.frozen, this.rootId);

  final TransferStack a;
  final TransferStack b;
  final ShareService service;
  final CountingShareFileSystem fs;
  final FrozenShared? frozen;
  final String rootId;

  String get docs => '${b.base}\\docs';

  SharedFolderDestination to(List<String> path, {String? newFolder}) =>
      SharedFolderDestination(
        rootId: rootId,
        rootName: 'docs',
        path: path,
        newFolder: newFolder,
      );

  Future<TransferResultView?> send(
    String path,
    SharedFolderDestination destination,
  ) => a.coordinator.sendElement(
    a.targetOf(b),
    path,
    refresh: () => a.targetOf(b),
    destination: destination,
  );

  Future<void> settled() => eventually(
    () => fs.unreleased == 0,
    limit: const Duration(seconds: 10),
    reason: 'chains released',
  );

  List<String> inSub() => [
    for (final entity in Directory('$docs\\sub').listSync())
      entity.path.split(r'\').last,
  ]..sort();
}

Future<Bench> bench({bool freeze = false, ClearHidden? clearHidden}) async {
  late ShareService service;
  late CountingShareFileSystem fs;
  FrozenShared? frozen;
  final a = await TransferStack.start(name: 'A', address: hostA);
  final b = await TransferStack.start(
    name: 'B',
    address: hostB,
    clearHidden: clearHidden,
    sharedFolders: (paired, platform, dataDir) {
      fs = CountingShareFileSystem(
        WindowsShareFileSystem(platform: platform, dataDirs: [dataDir]),
      );
      service = ShareService(
        store: SharesStore(
          JsonFileStore(File('$dataDir\\shares.json')),
          ownerFingerprint: 'B' * 64,
        ),
        paired: paired,
        fileSystem: fs,
        dataDirPath: dataDir,
      );
      addTearDown(service.close);
      if (!freeze) return service;
      return frozen = FrozenShared(service);
    },
  );
  await link(a, b);
  final docs = '${b.base}\\docs';
  Directory('$docs\\sub').createSync(recursive: true);
  await service.load();
  expect(await service.addPath(a.fingerprint, docs), isA<ShareAdded>());
  final rootId = service.viewsFor(a.fingerprint).single.rootId;
  fs.reset();
  return Bench(a, b, service, fs, frozen, rootId);
}

Future<String> folderOf(TransferStack a) async {
  final root = '${a.sourceDir}\\Proyecto';
  File('$root\\uno.txt')
    ..createSync(recursive: true)
    ..writeAsStringSync('uno');
  File('$root\\dos\\dos.txt')
    ..createSync(recursive: true)
    ..writeAsStringSync('dos');
  return root;
}

Future<String> fileOf(TransferStack a, [String name = 'a.txt']) async {
  final path = '${a.sourceDir}\\$name';
  await File(path).writeAsBytes([1, 2, 3], flush: true);
  return path;
}

void main() {
  group('E754 a folder cut while finishing (RF-417)', () {
    test('E754 with a slow finish, removing docs cuts before the move and '
        'nothing stays', () async {
      final t = await bench(clearHidden: slowClearHidden);
      final sending = t.send(await folderOf(t.a), t.to(const ['sub']));
      await eventually(
        () => t.b.incoming?.stage == IncomingStage.verifying,
        reason: 'B verifying',
      );
      await t.service.remove(t.a.fingerprint, t.rootId);
      final sent = await sending;
      expect(sent?.outcome, TransferOutcome.destinationLost);
      final received = await t.b.receivedResult();
      expect(received.outcome, TransferOutcome.shareRemoved);
      await t.settled();
      expect(t.fs.rechecks, 0);
      expect(t.fs.lastSaved, isFalse);
      expect(t.inSub(), isEmpty);
    }, timeout: long);

    test(
      'E754 marking the peer foreign in the store cuts with no call to '
      'pairedChanged, so it does not need the node queue (punto 7)',
      () async {
        final t = await bench(clearHidden: slowClearHidden);
        final sending = t.send(await folderOf(t.a), t.to(const ['sub']));
        await eventually(
          () => t.b.incoming?.stage == IncomingStage.verifying,
          reason: 'B verifying',
        );
        await t.b.paired.setRelation(t.a.fingerprint, PeerRelation.foreign);
        final sent = await sending;
        expect(sent?.outcome, TransferOutcome.destinationLost);
        final received = await t.b.receivedResult();
        expect(received.outcome, TransferOutcome.peerMarkedForeign);
        await t.settled();
        expect(t.fs.rechecks, 0);
        expect(t.inSub(), isEmpty);
      },
      timeout: long,
    );
  });

  group('E756 the grant is read in the same turn (RF-416, RF-417) [SEG]', () {
    test('E756 a file: the grant falls right after the last step of finish '
        'and no event came, nothing moves and the temp goes', () async {
      final t = await bench(freeze: true);
      t.b.platform.mark = (path) async {
        final marked = await realFs.markFromInternet(path);
        t.frozen!.revoked = true;
        return marked;
      };
      final sent = await t.send(await fileOf(t.a), t.to(const ['sub']));
      expect(sent?.outcome, TransferOutcome.destinationLost);
      final received = await t.b.receivedResult();
      expect(received.outcome, TransferOutcome.shareRemoved);
      await t.settled();
      expect(t.fs.rechecks, 0);
      expect(t.fs.lastSaved, isFalse);
      expect(t.inSub(), isEmpty);
    }, timeout: long);

    test(
      'E756 a folder: same with the grant fallen during the finish',
      () async {
        final t = await bench(freeze: true, clearHidden: slowClearHidden);
        final sending = t.send(await folderOf(t.a), t.to(const ['sub']));
        await eventually(
          () => t.b.incoming?.stage == IncomingStage.verifying,
          reason: 'B verifying',
        );
        t.frozen!.revoked = true;
        final sent = await sending;
        expect(sent?.outcome, TransferOutcome.destinationLost);
        final received = await t.b.receivedResult();
        expect(received.outcome, TransferOutcome.shareRemoved);
        await t.settled();
        expect(t.fs.rechecks, 0);
        expect(t.inSub(), isEmpty);
      },
      timeout: long,
    );

    test('E756 a file: the grant falls right after prepare and the offer '
        'answers 403 destination_unavailable', () async {
      final t = await bench(freeze: true);
      t.fs.afterPrepare = () async {
        t.frozen!.revoked = true;
      };
      final sent = await t.send(await fileOf(t.a), t.to(const ['sub']));
      expect(sent?.outcome, TransferOutcome.destinationUnavailable);
      expect(t.b.offersReceived, 1);
      expect(t.b.handledOn(ApiPaths.transferUpload), 0);
      await t.settled();
      expect(t.inSub(), isEmpty);
    }, timeout: long);

    test('E756 a folder: the grant falls right after prepare and the '
        'manifest answers destination_unavailable', () async {
      final t = await bench(freeze: true);
      t.fs.afterPrepare = () async {
        t.frozen!.revoked = true;
      };
      final sent = await t.send(await folderOf(t.a), t.to(const ['sub']));
      expect(sent?.outcome, TransferOutcome.destinationUnavailable);
      await t.settled();
      expect(t.fs.rechecks, 0);
      expect(t.inSub(), isEmpty);
    }, timeout: long);

    test('G11 a root removed while the manifest travels ends silently with '
        'destination_unavailable and no temp folder', () async {
      final t = await bench();
      final hold = Completer<void>();
      addTearDown(() {
        if (!hold.isCompleted) hold.complete();
      });
      var reached = false;
      t.b.uploadWrapper = (upload, inner) async {
        reached = true;
        await hold.future;
        return inner(upload);
      };
      final sending = t.send(await folderOf(t.a), t.to(const ['sub']));
      await eventually(() => reached, reason: 'manifest arrived');
      await t.service.remove(t.a.fingerprint, t.rootId);
      await Future<void>.delayed(const Duration(milliseconds: 100));
      hold.complete();
      final sent = await sending;
      expect(sent?.outcome, TransferOutcome.destinationUnavailable);
      await t.settled();
      expect(t.fs.prepared, 0);
      expect(t.inSub(), isEmpty);
      expect(t.b.lastReceived, isNull);
    }, timeout: long);

    test('RF-417 a folder upload held between entries is cut by a removal '
        'and the temp folder and the chain go', () async {
      final hold = Completer<void>();
      addTearDown(() {
        if (!hold.isCompleted) hold.complete();
      });
      final entered = Completer<void>();
      var entries = 0;
      late ShareService service;
      late CountingShareFileSystem fs;
      final a = await TransferStack.start(
        name: 'A',
        address: hostA,
        beforeStreamEntry: (entry) async {
          if (++entries == 2) {
            if (!entered.isCompleted) entered.complete();
            await hold.future;
          }
        },
      );
      final b = await TransferStack.start(
        name: 'B',
        address: hostB,
        sharedFolders: (paired, platform, dataDir) {
          fs = CountingShareFileSystem(
            WindowsShareFileSystem(platform: platform, dataDirs: [dataDir]),
          );
          service = ShareService(
            store: SharesStore(
              JsonFileStore(File('$dataDir\\shares.json')),
              ownerFingerprint: 'B' * 64,
            ),
            paired: paired,
            fileSystem: fs,
            dataDirPath: dataDir,
          );
          addTearDown(service.close);
          return service;
        },
      );
      await link(a, b);
      final docs = '${b.base}\\docs';
      Directory('$docs\\sub').createSync(recursive: true);
      await service.load();
      expect(await service.addPath(a.fingerprint, docs), isA<ShareAdded>());
      final rootId = service.viewsFor(a.fingerprint).single.rootId;
      final sending = a.coordinator.sendElement(
        a.targetOf(b),
        await folderOf(a),
        refresh: () => a.targetOf(b),
        destination: SharedFolderDestination(
          rootId: rootId,
          rootName: 'docs',
          path: const ['sub'],
          newFolder: 'nueva',
        ),
      );
      await entered.future.timeout(const Duration(seconds: 10));
      await eventually(
        () => b.incoming?.stage == IncomingStage.receiving,
        reason: 'B receiving',
      );
      final facts = Directory('$docs\\sub\\nueva').existsSync();
      expect(facts, isTrue);
      final watch = Stopwatch()..start();
      await service.remove(a.fingerprint, rootId);
      await eventually(
        () => b.lastReceived?.outcome == TransferOutcome.shareRemoved,
        reason: 'cut',
      );
      expect(watch.elapsed, lessThan(const Duration(seconds: 2)));
      hold.complete();
      final sent = await sending;
      expect(sent?.outcome, TransferOutcome.destinationLost);
      await eventually(
        () => fs.unreleased == 0,
        limit: const Duration(seconds: 10),
        reason: 'chain released',
      );
      await eventually(
        () => Directory('$docs\\sub').listSync().isEmpty,
        limit: const Duration(seconds: 10),
        reason: 'sub is empty',
      );
    }, timeout: long);
  });
}
