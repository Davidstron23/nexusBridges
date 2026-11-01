@TestOn('windows')
library;

import 'dart:async';
import 'dart:io';

import 'package:nexus_bridges_core/src/identity/identity.dart';
import 'package:nexus_bridges_core/src/pairing/pairing.dart';
import 'package:nexus_bridges_core/src/protocol/protocol.dart';
import 'package:nexus_bridges_core/src/transfer/folders.dart'
    show tempFolderName;
import 'package:nexus_bridges_core/src/transfer/transfer.dart';
import 'package:nexus_bridges_core/src/transport/transport.dart';
import 'package:test/test.dart';

import 'receiver_folder_support.dart';
import 'receiver_harness.dart';

const Timeout long = Timeout(Duration(seconds: 120));

const String leftoverName = '~nexusbridges-0123456789ab';

void main() {
  late DeviceIdentity receiver;
  late Peer laptop;
  late Peer portatil;

  setUpAll(() {
    receiver = DeviceIdentity.generate();
    laptop = Peer(DeviceIdentity.generate(), name: 'Laptop');
    portatil = Peer(
      DeviceIdentity.generate(),
      name: 'PORTATIL',
      relation: PeerRelation.foreign,
    );
  });

  Future<ReceiverStack> stack({
    void Function(TransferPlatform platform)? configure,
  }) => ReceiverStack.start(
    identity: receiver,
    peers: [laptop, portatil],
    configure: configure,
  );

  String subOf(ReceiverStack s) => '${s.receiveDir}\\$tempFolderName';

  String leaveTree(ReceiverStack s, {required int dirs, required int files}) {
    final left = '${subOf(s)}\\$leftoverName';
    for (var d = 0; d < dirs; d++) {
      final dir = Directory('$left\\d$d')..createSync(recursive: true);
      for (var f = 0; f < files; f++) {
        File('${dir.path}\\f$f.txt').writeAsStringSync('x' * 20);
      }
    }
    return left;
  }

  Future<void> saveFolder(
    ReceiverStack s,
    Peer from,
    String name,
    String file,
  ) async {
    final job = folderJob([(file, smallFile)], name: name);
    final permit = await s.acceptedPermit(from, job);
    final saved = await s.sendFolder(from, job, permit);
    expect(saved.json['state'], 'saved', reason: saved.text);
    await endedQuietly(s);
  }

  group('Q-1: leftover temporary trees are deleted in the background', () {
    test('a leftover tree being deleted does not hold the offer: a "mine" '
        'folder gets its permit, and the tree is deleted once only', () async {
      final gate = Completer<void>();
      final s = await stack(
        configure: (p) => p.deleteTreeHook = (_) => gate.future,
      );
      addTearDown(() {
        if (!gate.isCompleted) gate.complete();
      });
      final left = leaveTree(s, dirs: 3, files: 5);

      await saveFolder(s, laptop, 'one', 'a.txt');
      await saveFolder(s, laptop, 'two', 'b.txt');
      await saveFolder(s, laptop, 'three', 'c.txt');

      expect(s.platform.deletedTrees.map((p) => p.toLowerCase()), [
        left.toLowerCase(),
      ]);
      expect(Directory(left).existsSync(), isTrue);
      expect(File('${s.receiveDir}\\one\\a.txt').existsSync(), isTrue);
      expect(File('${s.receiveDir}\\two\\b.txt').existsSync(), isTrue);
      expect(File('${s.receiveDir}\\three\\c.txt').existsSync(), isTrue);

      gate.complete();
      await eventually(
        () => !Directory(subOf(s)).existsSync() && s.journal.folders.isEmpty,
        limit: const Duration(seconds: 20),
        reason: 'the leftover is gone and the journal is empty',
      );
      expect(s.platform.deletedTrees, hasLength(1));
    }, timeout: long);

    test('a file offer is not held either', () async {
      final gate = Completer<void>();
      final s = await stack(
        configure: (p) => p.deleteTreeHook = (_) => gate.future,
      );
      addTearDown(() {
        if (!gate.isCompleted) gate.complete();
      });
      leaveTree(s, dirs: 2, files: 2);

      final reply = await s.offer(laptop);

      expect(reply?.status, 200, reason: reply?.text);
      expect(reply?.state, 'accepted');
      s.coordinator.cancelIncoming(s.sid);
    }, timeout: long);

    test('6000 leftover files: the remembered folder of a "mine" stays '
        'available (202 with permit, not the folder question) and the rest '
        'is deleted afterwards', () async {
      final s = await stack();
      s.clock.followRealTime();
      final left = leaveTree(s, dirs: 30, files: 200);
      final job = folderJob([('a.txt', smallFile)]);

      final permit = await s.askManifest(laptop, job.declared);
      final reply = await s.sendManifest(laptop, job, permit);

      expect(reply.status, 200, reason: reply.text);
      expect(reply.state, 'accepted', reason: reply.text);
      expect(s.incoming?.stage, IncomingStage.waitingData);
      expect(s.incoming?.folder, isNull);
      final saved = await s.sendFolder(
        laptop,
        job,
        reply.json['permit'] as String,
      );
      expect(saved.json['state'], 'saved', reason: saved.text);
      await eventually(
        () =>
            !Directory(left).existsSync() && !Directory(subOf(s)).existsSync(),
        limit: const Duration(seconds: 90),
        reason: 'the leftover tree is gone',
      );
      await eventually(
        () => s.journal.folders.isEmpty,
        reason: 'the journal is empty',
      );
      expect(File('${s.receiveDir}\\proyecto\\a.txt').existsSync(), isTrue);
    }, timeout: long);
  });

  group('Q-6: a cancel with a problem entry while the folder is checked', () {
    test('unreadable with an entry keeps the path of the file', () async {
      final s = await stack();
      final job = folderJob([
        for (var i = 0; i < 4000; i++)
          ('d${i.toString().padLeft(5, '0')}', null),
        ('z.txt', smallFile),
      ]);
      final permit = await s.acceptedPermit(laptop, job);
      final upload = rawUpload(s, laptop, job, permit);
      await eventually(
        () => s.incoming?.stage == IncomingStage.verifying,
        reason: 'verifying',
      );
      final entry = job.manifest.fileIndexes.single;

      final reply = await s.post(laptop.identity, ApiPaths.transferCancel, {
        'transfer': job.transfer,
        'reason': 'unreadable',
        'entry': entry,
      });
      await upload;

      expect(reply?.status, 200, reason: reply?.text);
      await eventually(
        () => s.coordinator.lastReceived != null,
        reason: 'result',
      );
      expect(s.coordinator.lastReceived?.outcome, TransferOutcome.unreadable);
      expect(s.coordinator.lastReceived?.problemPath, 'z.txt');
      expect(Directory('${s.receiveDir}\\proyecto').existsSync(), isFalse);
    }, timeout: long);
  });

  group('Q-7: a session that ends while the writer starts', () {
    test('the writer is discarded, nothing stays and the receive folder '
        'is as it was', () async {
      final reached = Completer<void>();
      final gate = Completer<void>();
      var armed = false;
      final s = await stack(
        configure: (p) => p.hold = (method, path) async {
          if (armed &&
              method == 'realPath' &&
              path.toLowerCase().endsWith(tempFolderName)) {
            armed = false;
            reached.complete();
            await gate.future;
          }
        },
      );
      addTearDown(() {
        if (!gate.isCompleted) gate.complete();
      });
      File('${s.receiveDir}\\ya.txt').writeAsStringSync('already here');
      final before = <String>{
        for (final e in Directory(s.receiveDir).listSync(recursive: true))
          e.path.toLowerCase(),
      };
      final job = folderJob([('a.txt', smallFile)]);
      final permit = await s.acceptedPermit(laptop, job);
      armed = true;

      final upload = rawUpload(s, laptop, job, permit);
      await reached.future.timeout(const Duration(seconds: 20));
      final cancel = await s.cancel(laptop, job.transfer);
      gate.complete();
      await upload;

      expect(cancel?.status, 200, reason: cancel?.text);
      await eventually(
        () => !s.coordinator.busy && s.journal.folders.isEmpty,
        limit: const Duration(seconds: 20),
        reason: 'nothing left',
      );
      await eventually(
        () => !Directory(subOf(s)).existsSync(),
        limit: const Duration(seconds: 20),
        reason: 'the temporary folder is gone',
      );
      final after = <String>{
        for (final e in Directory(s.receiveDir).listSync(recursive: true))
          e.path.toLowerCase(),
      };
      expect(after, before);
    }, timeout: long);
  });

  group('B-1: the name of the folder itself is not reserved by the app', () {
    for (final name in [
      '~nexusbridges-0123456789ab',
      '~NEXUSBRIDGES-x',
      '~NexusBridges-',
      '.nexusbridges-incoming',
      '.NexusBridges-Incoming',
    ]) {
      test('"$name" gets 422 invalid_name from "mine" and "foreign", with '
          'nothing shown nor created', () async {
        final s = await stack();
        s.sampleViews();
        final before = <String>{
          for (final e in Directory(s.base).listSync(recursive: true))
            e.path.toLowerCase(),
        };

        for (final peer in [laptop, portatil]) {
          final job = folderJob([('a.txt', smallFile)], name: name);
          final reply = await s.offerFolder(peer, job.declared);
          expect(reply?.status, 422, reason: reply?.text);
          expect(reply?.json, {'error': 'invalid_name'});
        }

        expect(s.coordinator.busy, isFalse);
        expect(s.incoming, isNull);
        expect(s.seen, isEmpty);
        expect(s.coordinator.lastReceived, isNull);
        final after = <String>{
          for (final e in Directory(s.base).listSync(recursive: true))
            e.path.toLowerCase(),
        };
        expect(after, before);
      });
    }

    test('look alikes are accepted', () async {
      final s = await stack();
      for (final name in [
        '.nexusbridges-incoming2',
        '~nexusbridges',
        'x~nexusbridges-a',
      ]) {
        final job = folderJob([('a.txt', smallFile)], name: name);
        final reply = await s.offerFolder(laptop, job.declared);
        expect(reply?.status, 202, reason: '$name ${reply?.text}');
        expect(reply?.state, 'manifest');
        s.coordinator.cancelIncoming(s.sid);
        await s.cancel(laptop, job.transfer);
        await endedQuietly(s);
      }
    });

    test('a file with that name is not affected', () async {
      final s = await stack();

      final reply = await s.offer(laptop, name: '~nexusbridges-x.txt');

      expect(reply?.status, 200, reason: reply?.text);
      s.coordinator.cancelIncoming(s.sid);
    });
  });

  group('M-3: a folder with .git from a "foreign" says so', () {
    Future<void> toWarning(ReceiverStack s, FolderJob job, Peer from) async {
      final permit = await s.askManifest(from, job.declared);
      final reply = await s.sendManifest(from, job, permit);
      expect(reply.status, 202, reason: reply.text);
      await eventually(
        () => s.incoming?.stage == IncomingStage.warning,
        reason: 'warning',
      );
    }

    final withGit = [
      ('src', null),
      (r'src\vendor', null),
      (r'src\vendor\.GIT', null),
      (r'src\vendor\.GIT\config', smallFile),
      ('a.txt', smallFile),
    ];

    test(
      'the warning and the result of the "foreign" carry the flag',
      () async {
        final s = await stack();
        final job = folderJob(withGit);
        await toWarning(s, job, portatil);

        expect(s.incoming?.containsGitRepository, isTrue);
        expect(s.incoming?.isProgram, isFalse);

        s.coordinator.answerWarning(s.sid, accept: true);
        await eventually(
          () => s.incoming?.stage == IncomingStage.waitingData,
          reason: 'accepted',
        );
        expect(s.incoming?.containsGitRepository, isTrue);
        final permit = expectPermit(await s.wait(portatil, job.transfer));
        final saved = await s.sendFolder(portatil, job, permit);
        expect(saved.json['state'], 'saved', reason: saved.text);
        await endedQuietly(s);

        expect(s.coordinator.lastReceived?.outcome, TransferOutcome.saved);
        expect(s.coordinator.lastReceived?.containsGitRepository, isTrue);
      },
      timeout: long,
    );

    test('rejecting the warning keeps the flag in the result', () async {
      final s = await stack();
      await toWarning(s, folderJob(withGit), portatil);

      s.coordinator.answerWarning(s.sid, accept: false);
      await endedQuietly(s);

      expect(s.coordinator.lastReceived?.outcome, TransferOutcome.declined);
      expect(s.coordinator.lastReceived?.containsGitRepository, isTrue);
    });

    test('a "foreign" folder without .git does not carry it', () async {
      final s = await stack();
      await toWarning(
        s,
        folderJob([
          ('.github', null),
          ('x.git', smallFile),
          ('.gitignore', smallFile),
        ]),
        portatil,
      );

      expect(s.incoming?.containsGitRepository, isFalse);
      s.coordinator.answerWarning(s.sid, accept: false);
      await endedQuietly(s);
      expect(s.coordinator.lastReceived?.containsGitRepository, isFalse);
    });

    test(
      'a "mine" with .git gets no flag, in the card nor in the result',
      () async {
        final s = await stack();
        final job = folderJob(withGit);
        final permit = await s.acceptedPermit(laptop, job);
        await eventually(
          () => s.incoming?.stage == IncomingStage.waitingData,
          reason: 'accepted',
        );

        expect(s.incoming?.containsGitRepository, isFalse);
        final saved = await s.sendFolder(laptop, job, permit);
        expect(saved.json['state'], 'saved', reason: saved.text);
        await endedQuietly(s);

        expect(s.coordinator.lastReceived?.outcome, TransferOutcome.saved);
        expect(s.coordinator.lastReceived?.containsGitRepository, isFalse);
        expect(
          File('${s.receiveDir}\\proyecto\\src\\vendor\\.GIT\\config')
              .existsSync(),
          isTrue,
        );
      },
    );

    test('a file from a "foreign" never carries the flag', () async {
      final s = await stack();
      await s.offer(portatil);
      await eventually(
        () => s.incoming?.stage == IncomingStage.warning,
        reason: 'warning',
      );

      expect(s.incoming?.containsGitRepository, isFalse);
      s.coordinator.answerWarning(s.sid, accept: false);
    });

    test(
      'a .git file (gitdir) at any level from a "foreign" counts too',
      () async {
        final s = await stack();
        await toWarning(
          s,
          folderJob([
            ('sub', null),
            (r'sub\module', null),
            (r'sub\module\.git', smallFile),
          ]),
          portatil,
        );

        expect(s.incoming?.containsGitRepository, isTrue);
        s.coordinator.answerWarning(s.sid, accept: false);
        await endedQuietly(s);
        expect(s.coordinator.lastReceived?.containsGitRepository, isTrue);
      },
    );

    test('a folder whose own name is .git counts for a "foreign" and not '
        'for a "mine"', () async {
      final s = await stack();
      await toWarning(
        s,
        folderJob([('config', smallFile)], name: '.GIT'),
        portatil,
      );
      expect(s.incoming?.containsGitRepository, isTrue);
      s.coordinator.answerWarning(s.sid, accept: false);
      await endedQuietly(s);
      expect(s.coordinator.lastReceived?.containsGitRepository, isTrue);

      final mine = folderJob([('config', smallFile)], name: '.git');
      final permit = await s.acceptedPermit(laptop, mine);
      expect(s.incoming?.containsGitRepository, isFalse);
      final saved = await s.sendFolder(laptop, mine, permit);
      expect(saved.json['state'], 'saved', reason: saved.text);
      await endedQuietly(s);
      expect(s.coordinator.lastReceived?.containsGitRepository, isFalse);
    });
  });

  group('B-3: direction marks stay valid and are saved, but not displayed', () {
    const hebrew = 'שלום';
    const marked = '$hebrew‏';

    test('a folder and a file named with RLM are saved with their exact '
        'name and shown without the mark', () async {
      final s = await stack();
      final job = folderJob([
        ('$marked.txt', smallFile),
        ('a‎b؜', null),
      ], name: marked);
      final permit = await s.acceptedPermit(laptop, job);
      expect(s.incoming?.fileName, hebrew);
      final saved = await s.sendFolder(laptop, job, permit);
      expect(saved.json, {'state': 'saved', 'marked': true, 'name': marked});
      await endedQuietly(s);

      final names = Directory(s.receiveDir)
          .listSync()
          .map((e) => e.path.substring(e.path.lastIndexOf(r'\') + 1))
          .toList();
      expect(names, contains(marked));
      expect(
        File('${s.receiveDir}\\$marked\\$marked.txt').readAsBytesSync(),
        smallFile,
      );
      expect(Directory('${s.receiveDir}\\$marked\\a‎b؜').existsSync(), isTrue);
      expect(s.coordinator.lastReceived?.fileName, hebrew);
    });

    test('the first level of a "foreign" warning shows the names without '
        'marks', () async {
      final s = await stack();
      final job = folderJob([
        ('$marked.txt', smallFile),
        ('a‎b', null),
        ('c؜d.txt', smallFile),
      ]);
      final permit = await s.askManifest(portatil, job.declared);
      final reply = await s.sendManifest(portatil, job, permit);
      expect(reply.status, 202, reason: reply.text);
      await eventually(
        () => s.incoming?.stage == IncomingStage.warning,
        reason: 'warning',
      );

      expect(s.incoming?.firstLevel.map((item) => item.name).toSet(), {
        '$hebrew.txt',
        'ab',
        'cd.txt',
      });
      s.coordinator.answerWarning(s.sid, accept: false);
    });

    test(
      'a file offer named with RLM is accepted and shown without it',
      () async {
        final s = await stack();

        final reply = await s.offer(laptop, name: '$marked.txt');

        expect(reply?.status, 200, reason: reply?.text);
        expect(s.incoming?.fileName, '$hebrew.txt');
        s.coordinator.cancelIncoming(s.sid);
      },
    );
  });
}

Future<StreamPostResult> rawUpload(
  ReceiverStack s,
  Peer from,
  FolderJob job,
  String permit,
) => s.postUpload(
  from.identity,
  headers: headersFor(job.transfer, permit),
  contentLength: job.stream.length,
  body: chunked(job.stream),
);

String expectPermit(RawReply? reply) {
  expect(reply, isNotNull);
  expect(reply!.status, 200, reason: reply.text);
  expect(reply.state, 'accepted', reason: reply.text);
  return reply.json['permit'] as String;
}
