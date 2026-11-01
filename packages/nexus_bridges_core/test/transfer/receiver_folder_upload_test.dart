@TestOn('windows')
library;

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:nexus_bridges_core/src/identity/identity.dart';
import 'package:nexus_bridges_core/src/protocol/protocol.dart';
import 'package:nexus_bridges_core/src/transfer/folder_stream.dart';
import 'package:nexus_bridges_core/src/transfer/folders.dart'
    show tempFolderName;
import 'package:nexus_bridges_core/src/transfer/platform.dart';
import 'package:nexus_bridges_core/src/transfer/transfer.dart';
import 'package:nexus_bridges_core/src/transport/transport.dart';
import 'package:test/test.dart';

import 'folder_writer_support.dart' show content;
import 'receiver_folder_support.dart';
import 'receiver_harness.dart';

const Timeout long = Timeout(Duration(seconds: 90));

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

String? tempRootOf(ReceiverStack s) {
  final sub = Directory('${s.receiveDir}\\$tempFolderName');
  if (!sub.existsSync()) return null;
  for (final entity in sub.listSync(followLinks: false)) {
    final name = entity.path.substring(entity.path.lastIndexOf(r'\') + 1);
    if (entity is Directory && name.startsWith('~nexusbridges-')) {
      return entity.path;
    }
  }
  return null;
}

Uint8List withIndex(Uint8List frame, int index) {
  final copy = Uint8List.fromList(frame);
  ByteData.sublistView(copy).setUint32(0, index);
  return copy;
}

Uint8List withLength(Uint8List frame, int length) {
  final copy = Uint8List.fromList(frame);
  ByteData.sublistView(copy).setUint64(4, length);
  return copy;
}

Uint8List joined(Iterable<List<int>> parts) {
  final builder = BytesBuilder(copy: false);
  for (final part in parts) {
    builder.add(part);
  }
  return builder.takeBytes();
}

Future<void> runCmd(List<String> arguments) async {
  final result = await Process.run('cmd', ['/c', ...arguments]);
  if (result.exitCode != 0) {
    fail('${arguments.join(' ')} failed: ${result.stderr}${result.stdout}');
  }
}

Future<void> renameWithRetry(String from, String to) async {
  final stopwatch = Stopwatch()..start();
  while (true) {
    try {
      Directory(from).renameSync(to);
      return;
    } on FileSystemException {
      if (stopwatch.elapsed > const Duration(seconds: 5)) rethrow;
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
  }
}

void expectState(RawReply? reply, Map<String, Object?> json) {
  expect(reply, isNotNull);
  expect(reply!.status, 200, reason: reply.text);
  expect(reply.json, json);
}

void main() {
  late DeviceIdentity receiver;
  late Peer laptop;
  late Peer desk;

  setUpAll(() {
    receiver = DeviceIdentity.generate();
    laptop = Peer(DeviceIdentity.generate(), name: 'Laptop');
    desk = Peer(DeviceIdentity.generate(), name: 'Sobremesa');
  });

  Future<ReceiverStack> stack({
    void Function(TransferPlatform platform)? configure,
    Duration idleTimeout = Limits.transferIdleTimeout,
  }) => ReceiverStack.start(
    identity: receiver,
    peers: [laptop, desk],
    configure: configure,
    idleTimeout: idleTimeout,
  );

  void seedReceiveFolder(ReceiverStack s) {
    File('${s.receiveDir}\\ya.txt').writeAsStringSync('already here');
    Directory('${s.receiveDir}\\vieja').createSync();
    File('${s.receiveDir}\\vieja\\dato.txt').writeAsStringSync('old data');
  }

  Future<({FolderJob job, String permit})> accepted(
    ReceiverStack s,
    List<TreeEntry> entries, {
    String name = 'proyecto',
    Peer? from,
  }) async {
    final job = folderJob(entries, name: name);
    final permit = await s.acceptedPermit(from ?? laptop, job);
    await eventually(
      () => s.incoming?.stage == IncomingStage.waitingData,
      reason: 'accepted card',
    );
    return (job: job, permit: permit);
  }

  ({HeldBody held, Future<StreamPostResult> result}) startUpload(
    ReceiverStack s,
    FolderJob job,
    String permit, {
    Peer? from,
    int? length,
  }) {
    final held = HeldBody();
    final result = s.postUpload(
      (from ?? laptop).identity,
      headers: headersFor(job.transfer, permit),
      contentLength: length ?? job.stream.length,
      body: held.stream,
    );
    return (held: held, result: result);
  }

  Future<StreamPostResult> upload(
    ReceiverStack s,
    FolderJob job,
    String permit,
    Uint8List stream, {
    Peer? from,
    int? length,
  }) => s.postUpload(
    (from ?? laptop).identity,
    headers: headersFor(job.transfer, permit),
    contentLength: length ?? stream.length,
    body: chunked(stream),
  );

  Future<void> expectUntouched(
    ReceiverStack s,
    Map<String, String> before,
  ) async {
    await eventually(
      () =>
          !s.coordinator.busy &&
          !Directory('${s.receiveDir}\\$tempFolderName').existsSync() &&
          s.journal.folders.isEmpty,
      reason: 'temporary folder gone and journal empty',
    );
    expect(snapshotOf(s.receiveDir), before);
    expect(s.incoming, isNull);
  }

  void expectCleanLogs(ReceiverStack s, Iterable<String> secrets) {
    final base = s.base.toLowerCase();
    for (final line in s.logs) {
      final lower = line.toLowerCase();
      expect(lower, isNot(contains(base)), reason: line);
      for (final secret in secrets) {
        expect(lower, isNot(contains(secret)), reason: 'secret in a log');
      }
    }
  }

  Future<void> expectEndedAs(
    ReceiverStack s,
    Peer peer,
    FolderJob job,
    TransferOutcome outcome,
    Map<String, Object?> remote,
  ) async {
    await eventually(
      () => s.coordinator.lastReceived?.outcome == outcome,
      reason: 'ended as ${outcome.name}',
    );
    final reply = await s.wait(peer, job.transfer);
    expect(reply?.status, 200, reason: reply?.text);
    expect(reply?.json, remote);
  }

  Map<String, Object?> failedWith(String reason) => {
    'state': 'failed',
    'reason': reason,
  };

  group('E462 [SEG], RF-273: nothing lands outside the temporary folder', () {
    test('a closed branch swapped for a junction before the end: nothing is '
        'written outside, the folder fails and the receive folder is as it '
        'was', () async {
      final s = await stack();
      seedReceiveFolder(s);
      final before = snapshotOf(s.receiveDir);
      final outside = '${s.base}\\outside';
      Directory(outside).createSync();
      File('$outside\\keep.txt').writeAsStringSync('mine');
      final outsideBefore = snapshotOf(outside);
      final (:job, :permit) = await accepted(s, [
        ('a', null),
        (r'a\g.txt', content(1, 70 * kib)),
        ('b', null),
        (r'b\h.txt', content(2, 70 * kib)),
      ]);
      final frames = job.tree.frames;
      final run = startUpload(s, job, permit);
      run.held.send(frames[0]);
      run.held.send(Uint8List.sublistView(frames[1], 0, frames[1].length - 1));
      await eventually(
        () => s.incoming?.receivedBytes == 140 * kib,
        reason: 'both files written but the last closing byte',
      );
      final root = tempRootOf(s)!;
      expect(snapshotOf(outside), outsideBefore);

      await renameWithRetry('$root\\a', '$root\\a_moved');
      await runCmd(['mklink', '/J', '$root\\a', outside]);
      expect(snapshotOf(outside), outsideBefore);

      run.held.send(Uint8List.fromList([0]));
      run.held.finish();
      final result = await run.result.timeout(const Duration(seconds: 20));

      if (result is StreamPostAnswered) {
        expect(
          RawReply(result.response.status, result.response.body).json,
          failedWith('write_failed'),
        );
      }
      await expectEndedAs(
        s,
        laptop,
        job,
        TransferOutcome.writeFailed,
        failedWith('write_failed'),
      );
      expect(snapshotOf(outside), outsideBefore);
      expect(File('$outside\\keep.txt').readAsStringSync(), 'mine');
      await expectUntouched(s, before);
      expectCleanLogs(s, [permit]);
    }, timeout: long);

    test('a folder the writer holds open cannot be renamed or swapped: the '
        'folder arrives intact and outside stays empty', () async {
      final s = await stack();
      final outside = '${s.base}\\outside';
      Directory(outside).createSync();
      final (:job, :permit) = await accepted(s, [
        ('a', null),
        (r'a\g.txt', content(3, 70 * kib)),
        (r'a\f.txt', content(4, 70 * kib)),
      ]);
      final frames = job.tree.frames;
      final run = startUpload(s, job, permit);
      run.held.send(frames[0]);
      run.held.send(Uint8List.sublistView(frames[1], 0, frameHeaderBytes));
      await eventually(
        () => s.incoming?.receivedBytes == 70 * kib,
        reason: 'first file written',
      );
      final root = tempRootOf(s)!;

      expect(
        () => Directory('$root\\a').renameSync('$root\\moved'),
        throwsA(isA<FileSystemException>()),
      );
      final made = await Process.run('cmd', [
        '/c',
        'mklink',
        '/J',
        '$root\\a',
        outside,
      ]);
      expect(made.exitCode, isNot(0));
      expect(Directory(outside).listSync(), isEmpty);

      run.held.send(Uint8List.sublistView(frames[1], frameHeaderBytes));
      run.held.finish();
      final result = await run.result;

      final reply = answered(result);
      expect(reply.json, {
        'state': 'saved',
        'marked': true,
        'name': 'proyecto',
      });
      expect(
        File('${s.receiveDir}\\proyecto\\a\\f.txt').readAsBytesSync(),
        content(4, 70 * kib),
      );
      expect(
        File('${s.receiveDir}\\proyecto\\a\\g.txt').readAsBytesSync(),
        content(3, 70 * kib),
      );
      expect(Directory(outside).listSync(), isEmpty);
    }, timeout: long);
  });

  group('E464 [SEG], RF-274: frames and permits that are not the session', () {
    final entries = <TreeEntry>[
      ('uno.txt', content(10, 3000)),
      ('dos.txt', content(11, 3000)),
      ('tres.txt', content(12, 3000)),
    ];

    Future<void> expectCutAsUnexpected(
      ReceiverStack s,
      Map<String, String> before,
      FolderJob job,
      String permit,
      Future<StreamPostResult> result,
    ) async {
      final done = await result.timeout(const Duration(seconds: 20));
      if (done is StreamPostAnswered) {
        expect(
          RawReply(done.response.status, done.response.body).json,
          failedWith('unexpected_data'),
        );
      }
      await expectEndedAs(
        s,
        laptop,
        job,
        TransferOutcome.unexpectedData,
        failedWith('unexpected_data'),
      );
      await expectUntouched(s, before);
      expectCleanLogs(s, [permit]);
    }

    test('a frame of an entry that is not in the manifest', () async {
      final s = await stack();
      seedReceiveFolder(s);
      final before = snapshotOf(s.receiveDir);
      final (:job, :permit) = await accepted(s, entries);
      final frames = job.tree.frames;
      final stream = joined([withIndex(frames[0], 99), frames[1], frames[2]]);

      final result = upload(s, job, permit, stream);

      await expectCutAsUnexpected(s, before, job, permit, result);
    });

    test('a frame of an entry that already arrived', () async {
      final s = await stack();
      seedReceiveFolder(s);
      final before = snapshotOf(s.receiveDir);
      final (:job, :permit) = await accepted(s, entries);
      final frames = job.tree.frames;
      final stream = joined([frames[0], withIndex(frames[1], 1), frames[2]]);

      final result = upload(s, job, permit, stream);

      await expectCutAsUnexpected(s, before, job, permit, result);
    });

    test('a frame out of order', () async {
      final s = await stack();
      seedReceiveFolder(s);
      final before = snapshotOf(s.receiveDir);
      final (:job, :permit) = await accepted(s, entries);
      final frames = job.tree.frames;
      final stream = joined([frames[0], frames[2], frames[1]]);

      final result = upload(s, job, permit, stream);

      await expectCutAsUnexpected(s, before, job, permit, result);
    });

    test('the upload with the permit of another paired device: 403, nothing '
        'written, and the real sender can still upload', () async {
      final s = await stack();
      final (:job, :permit) = await accepted(s, entries);

      final intruder = answered(
        await upload(s, job, permit, job.stream, from: desk),
      );

      expect(intruder.status, 403, reason: intruder.text);
      expect(intruder.json, {'error': 'forbidden'});
      expect(tempRootOf(s), isNull);
      expect(s.incoming?.stage, IncomingStage.waitingData);
      expect(Directory(s.receiveDir).listSync(), isEmpty);

      final saved = answered(await upload(s, job, permit, job.stream));
      expect(saved.json['state'], 'saved');
    });

    test('the permit of the manifest does not open the upload and a permit '
        'already used does not either', () async {
      final s = await stack();
      final job = folderJob(entries);
      final manifestPermit = await s.askManifest(laptop, job.declared);
      final reply = await s.sendManifest(laptop, job, manifestPermit);
      final uploadPermit = reply.json['permit'] as String;
      await eventually(
        () => s.incoming?.stage == IncomingStage.waitingData,
        reason: 'accepted card',
      );

      final wrong = answered(await upload(s, job, manifestPermit, job.stream));
      expect(wrong.status, 403, reason: wrong.text);
      expect(wrong.json, {'error': 'forbidden'});
      expect(Directory(s.receiveDir).listSync(), isEmpty);

      final saved = answered(await upload(s, job, uploadPermit, job.stream));
      expect(saved.json['state'], 'saved');
      await eventually(() => !s.coordinator.busy, reason: 'session ended');
      final names = everythingUnder(s.receiveDir);

      final again = answered(await upload(s, job, uploadPermit, job.stream));
      expect(again.status, 403, reason: again.text);
      expect(again.json, {'error': 'forbidden'});
      expect(everythingUnder(s.receiveDir), names);
    });
  });

  group('E465 [SEG], RF-275: more bytes than the manifest says', () {
    final entries = <TreeEntry>[
      ('uno.txt', content(20, 3000)),
      ('dos.txt', content(21, 3000)),
    ];

    test('a header with a longer length for the second file ends in '
        'too_many_bytes and nothing stays', () async {
      final s = await stack();
      seedReceiveFolder(s);
      final before = snapshotOf(s.receiveDir);
      final (:job, :permit) = await accepted(s, entries);
      final frames = job.tree.frames;
      final stream = joined([frames[0], withLength(frames[1], 3003)]);

      final result = await upload(
        s,
        job,
        permit,
        stream,
      ).timeout(const Duration(seconds: 20));

      if (result is StreamPostAnswered) {
        expect(
          RawReply(result.response.status, result.response.body).json,
          failedWith('too_many_bytes'),
        );
      }
      await expectEndedAs(
        s,
        laptop,
        job,
        TransferOutcome.tooManyBytes,
        failedWith('too_many_bytes'),
      );
      await expectUntouched(s, before);
    });

    test('an extra byte where the closing byte goes ends in '
        'unexpected_data', () async {
      final s = await stack();
      seedReceiveFolder(s);
      final before = snapshotOf(s.receiveDir);
      final (:job, :permit) = await accepted(s, entries);
      final frames = job.tree.frames;
      final second = Uint8List.fromList(frames[1])..last = 0x41;
      final stream = joined([frames[0], second]);

      final result = await upload(
        s,
        job,
        permit,
        stream,
      ).timeout(const Duration(seconds: 20));

      if (result is StreamPostAnswered) {
        expect(
          RawReply(result.response.status, result.response.body).json,
          failedWith('unexpected_data'),
        );
      }
      await expectEndedAs(
        s,
        laptop,
        job,
        TransferOutcome.unexpectedData,
        failedWith('unexpected_data'),
      );
      await expectUntouched(s, before);
    });

    test('a Content-Length over the expected one fails before anything is '
        'created and the receive folder is not touched', () async {
      final s = await stack();
      seedReceiveFolder(s);
      final before = snapshotOf(s.receiveDir);
      final (:job, :permit) = await accepted(s, entries);
      final calls = s.platform.calls.length;
      final longer = joined([
        job.stream,
        Uint8List.fromList([0]),
      ]);

      final result = await upload(
        s,
        job,
        permit,
        longer,
      ).timeout(const Duration(seconds: 20));

      if (result is StreamPostAnswered) {
        expect(
          RawReply(result.response.status, result.response.body).json,
          failedWith('too_many_bytes'),
        );
      }
      await expectEndedAs(
        s,
        laptop,
        job,
        TransferOutcome.tooManyBytes,
        failedWith('too_many_bytes'),
      );
      expect(s.platform.calls.skip(calls), isEmpty);
      await expectUntouched(s, before);
    });

    test('a Content-Length under the expected one fails as connection_lost '
        'and nothing is created', () async {
      final s = await stack();
      seedReceiveFolder(s);
      final before = snapshotOf(s.receiveDir);
      final (:job, :permit) = await accepted(s, entries);
      final shorter = Uint8List.sublistView(
        job.stream,
        0,
        job.stream.length - 1,
      );

      final result = await upload(s, job, permit, shorter);

      expect(answered(result).json, failedWith('connection_lost'));
      await expectEndedAs(
        s,
        laptop,
        job,
        TransferOutcome.connectionLost,
        failedWith('connection_lost'),
      );
      await expectUntouched(s, before);
    });
  });

  group('E466 [SEG], RF-276: a file that does not match its hash', () {
    test('the last file of a folder of 100 arrives with one byte changed: '
        'damaged and not even the 99 good ones stay', () async {
      final s = await stack();
      seedReceiveFolder(s);
      final before = snapshotOf(s.receiveDir);
      final entries = <TreeEntry>[
        for (var i = 0; i < 100; i++)
          ('f${i.toString().padLeft(3, '0')}.txt', content(100 + i, 400)),
      ];
      final (:job, :permit) = await accepted(s, entries);
      final frames = [...job.tree.frames];
      final last = Uint8List.fromList(frames.last);
      last[frameHeaderBytes + 7] ^= 0x01;
      frames[frames.length - 1] = last;

      final result = await upload(s, job, permit, joined(frames));

      expect(answered(result).json, failedWith('damaged'));
      await expectEndedAs(
        s,
        laptop,
        job,
        TransferOutcome.damaged,
        failedWith('damaged'),
      );
      expect(s.coordinator.lastReceived?.isFolder, isTrue);
      await expectUntouched(s, before);
      expectCleanLogs(s, [permit]);
    }, timeout: long);
  });

  group('E468, RF-278: the folder appears once, whole', () {
    test('until the last file the final name does not exist; then it is '
        'there, whole, visible and marked, and the answer carries the '
        'name', () async {
      final s = await stack();
      final (:job, :permit) = await accepted(s, [
        ('src', null),
        (r'src\a.txt', content(30, 70 * kib)),
        (r'src\b.txt', content(31, 70 * kib)),
        ('vacia', null),
      ]);
      final frames = job.tree.frames;
      final run = startUpload(s, job, permit);
      run.held.send(frames[0]);
      await eventually(
        () => s.incoming?.receivedFiles == 1,
        reason: 'first file closed',
      );
      expect(Directory('${s.receiveDir}\\proyecto').existsSync(), isFalse);
      final root = tempRootOf(s);
      expect(root, isNotNull);
      expect(
        File('$root\\src\\a.txt').readAsBytesSync(),
        content(30, 70 * kib),
      );

      run.held.send(frames[1]);
      run.held.finish();
      final reply = answered(await run.result);

      expect(reply.json, {
        'state': 'saved',
        'marked': true,
        'name': 'proyecto',
      });
      final saved = '${s.receiveDir}\\proyecto';
      expect(
        File('$saved\\src\\a.txt').readAsBytesSync(),
        content(30, 70 * kib),
      );
      expect(
        File('$saved\\src\\b.txt').readAsBytesSync(),
        content(31, 70 * kib),
      );
      expect(Directory('$saved\\vacia').listSync(), isEmpty);
      final attrs = await Process.run('cmd', ['/c', 'attrib', '/d', saved]);
      final flags = (attrs.stdout as String).split(saved).first;
      expect(flags, isNot(contains('H')));
      expect(flags, isNot(contains('S')));
      expect(
        File('$saved\\src\\a.txt:Zone.Identifier').readAsStringSync(),
        '[ZoneTransfer]\r\nZoneId=3\r\n',
      );
      await eventually(
        () => !Directory('${s.receiveDir}\\$tempFolderName').existsSync(),
        reason: 'temporary subfolder gone',
      );
      expect(s.journal.folders, isEmpty);
      expect(s.coordinator.lastReceived?.outcome, TransferOutcome.saved);
      expect(s.coordinator.lastReceived?.fileName, 'proyecto');
    }, timeout: long);
  });

  group('E469 [SEG], RF-279: a free name, never a merge', () {
    final entries = <TreeEntry>[
      (r'dentro.txt', content(40, 2000)),
      ('hueca', null),
    ];

    test('with Proyecto in the folder it arrives as "Proyecto (1)" and the '
        'old one is the same in content and dates', () async {
      final s = await stack();
      final old = '${s.receiveDir}\\Proyecto';
      Directory('$old\\sub').createSync(recursive: true);
      File('$old\\viejo.txt').writeAsStringSync('old');
      File('$old\\sub\\mas.txt').writeAsStringSync('more');
      final oldBefore = snapshotOf(old);
      final oldStat = Directory(old).statSync();
      final (:job, :permit) = await accepted(s, entries, name: 'Proyecto');

      final reply = answered(await upload(s, job, permit, job.stream));

      expect(reply.json, {
        'state': 'saved',
        'marked': true,
        'name': 'Proyecto (1)',
      });
      expect(snapshotOf(old), oldBefore);
      expect(Directory(old).statSync().modified, oldStat.modified);
      expect(
        File('${s.receiveDir}\\Proyecto (1)\\dentro.txt').readAsBytesSync(),
        content(40, 2000),
      );
      expect(s.coordinator.lastReceived?.fileName, 'Proyecto (1)');
    });

    test('with a file named PROYECTO, case does not matter and the file is '
        'untouched', () async {
      final s = await stack();
      final file = File('${s.receiveDir}\\PROYECTO')
        ..writeAsStringSync('a file');
      final stat = file.statSync();
      final (:job, :permit) = await accepted(s, entries);

      final reply = answered(await upload(s, job, permit, job.stream));

      expect(reply.json['name'], 'proyecto (1)');
      expect(file.readAsStringSync(), 'a file');
      expect(file.statSync().modified, stat.modified);
    });

    test('Proyecto to Proyecto (9999) all taken: noFreeName and nothing '
        'else is saved', () async {
      final s = await stack();
      Directory('${s.receiveDir}\\Proyecto').createSync();
      for (var n = 1; n <= 9999; n++) {
        Directory('${s.receiveDir}\\Proyecto ($n)').createSync();
      }
      final (:job, :permit) = await accepted(s, entries, name: 'Proyecto');

      final reply = answered(await upload(s, job, permit, job.stream));

      expect(reply.json, failedWith('no_free_name'));
      await eventually(
        () =>
            s.coordinator.lastReceived?.outcome == TransferOutcome.noFreeName &&
            !Directory('${s.receiveDir}\\$tempFolderName').existsSync(),
        reason: 'ended without a name and cleaned',
      );
      expect(Directory(s.receiveDir).listSync(), hasLength(10000));
      expect(s.journal.folders, isEmpty);
    }, timeout: long);

    test('a platform that creates "Proyecto (1)" just before the move: the '
        'folder takes "Proyecto (2)" and the one created stays', () async {
      final s = await stack(
        configure: (platform) {
          platform.moveFolder = (from, folder, name, maxNameUnits) async {
            Directory('$folder\\Proyecto (1)').createSync();
            File('$folder\\Proyecto (1)\\suyo.txt').writeAsStringSync('theirs');
            return realFs.moveFolderToFreeName(
              from,
              folder,
              name,
              maxNameUnits: maxNameUnits,
            );
          };
        },
      );
      Directory('${s.receiveDir}\\Proyecto').createSync();
      final (:job, :permit) = await accepted(s, entries, name: 'Proyecto');

      final reply = answered(await upload(s, job, permit, job.stream));

      expect(reply.json['name'], 'Proyecto (2)');
      expect(
        File('${s.receiveDir}\\Proyecto (1)\\suyo.txt').readAsStringSync(),
        'theirs',
      );
      expect(
        File('${s.receiveDir}\\Proyecto (2)\\dentro.txt').readAsBytesSync(),
        content(40, 2000),
      );
    });
  });

  group('E470 [SEG], RF-280: every way out leaves the folder as it was', () {
    final entries = <TreeEntry>[
      (r'a\uno.txt', content(50, 90 * kib)),
      (r'a\dos.txt', content(51, 90 * kib)),
      ('tres.txt', content(52, 90 * kib)),
    ];
    final withParent = <TreeEntry>[('a', null), ...entries];

    Future<
      ({
        ReceiverStack s,
        FolderJob job,
        String permit,
        ({HeldBody held, Future<StreamPostResult> result}) run,
        Map<String, String> before,
      })
    >
    midway() async {
      final s = await stack();
      seedReceiveFolder(s);
      final before = snapshotOf(s.receiveDir);
      final (:job, :permit) = await accepted(s, withParent);
      final run = startUpload(s, job, permit);
      run.held.send(job.tree.frames[0]);
      run.held.send(job.tree.frames[1]);
      await eventually(
        () => s.incoming?.receivedBytes == 180 * kib,
        reason: 'two files written',
      );
      expect(tempRootOf(s), isNotNull);
      return (s: s, job: job, permit: permit, run: run, before: before);
    }

    test('the connection is cut halfway', () async {
      final m = await midway();
      m.run.held.breakOff();

      await m.run.result.timeout(const Duration(seconds: 20));

      await expectEndedAs(
        m.s,
        laptop,
        m.job,
        TransferOutcome.connectionLost,
        failedWith('connection_lost'),
      );
      await expectUntouched(m.s, m.before);
      expectCleanLogs(m.s, [m.permit]);
    });

    test('the sender cancels', () async {
      final m = await midway();

      final reply = await m.s.cancel(laptop, m.job.transfer);

      expect(reply?.status, 200, reason: reply?.text);
      expect(reply?.json, {'state': 'cancelled'});
      expect(
        await m.run.result.timeout(const Duration(seconds: 20)),
        isA<StreamPostFailed>(),
      );
      await eventually(
        () =>
            m.s.coordinator.lastReceived?.outcome ==
            TransferOutcome.cancelledByPeer,
        reason: 'cancelled by the peer',
      );
      await expectUntouched(m.s, m.before);
    });

    test('the receiver cancels', () async {
      final m = await midway();

      m.s.coordinator.cancelIncoming(m.s.sid);

      expect(
        await m.run.result.timeout(const Duration(seconds: 20)),
        isA<StreamPostFailed>(),
      );
      await eventually(
        () =>
            m.s.coordinator.lastReceived?.outcome ==
            TransferOutcome.cancelledHere,
        reason: 'cancelled here',
      );
      expectState(await m.s.wait(laptop, m.job.transfer), {
        'state': 'cancelled',
      });
      await expectUntouched(m.s, m.before);
    });

    test(
      'no data for the idle time ends in idle and cuts the upload',
      () async {
        final s = await stack(idleTimeout: const Duration(milliseconds: 400));
        s.clock.followRealTime();
        seedReceiveFolder(s);
        final before = snapshotOf(s.receiveDir);
        final (:job, :permit) = await accepted(s, withParent);
        final run = startUpload(s, job, permit);
        run.held.send(job.tree.frames[0]);
        await eventually(
          () => s.incoming?.receivedBytes == 90 * kib,
          reason: 'first file written',
        );

        expect(
          await run.result.timeout(const Duration(seconds: 20)),
          isA<StreamPostFailed>(),
        );

        await eventually(
          () => s.coordinator.lastReceived?.outcome == TransferOutcome.idle,
          reason: 'idle',
        );
        await expectUntouched(s, before);
      },
    );

    test('the move fails: move_failed in the answer and the receive folder '
        'is as it was', () async {
      final s = await stack(
        configure: (platform) {
          platform.moveFolder = (_, _, _, _) async => const MoveFailed();
        },
      );
      seedReceiveFolder(s);
      final before = snapshotOf(s.receiveDir);
      final (:job, :permit) = await accepted(s, withParent);

      final reply = answered(await upload(s, job, permit, job.stream));

      expect(reply.json, failedWith('move_failed'));
      await expectEndedAs(
        s,
        laptop,
        job,
        TransferOutcome.moveFailed,
        failedWith('move_failed'),
      );
      await expectUntouched(s, before);
    });
  });

  group('RF-281: the cleanup never touches the folder being received', () {
    test('a cleanup at start in the middle of an upload removes an orphan '
        'temporary folder but keeps the active one, which is then '
        'saved', () async {
      final s = await stack();
      final (:job, :permit) = await accepted(s, [
        ('a.bin', content(95, 90 * kib)),
        ('b.bin', content(96, 90 * kib)),
      ]);
      final run = startUpload(s, job, permit);
      run.held.send(job.tree.frames[0]);
      await eventually(
        () => s.incoming?.receivedBytes == 90 * kib,
        reason: 'first file written',
      );
      final active = tempRootOf(s)!;
      final orphan =
          '${s.receiveDir}\\$tempFolderName\\~nexusbridges-aaaaaaaaaaaa';
      Directory(orphan).createSync();
      File('$orphan\\resto.txt').writeAsStringSync('left over');

      await s.coordinator.cleanupAtStart();

      await eventually(
        () => !Directory(orphan).existsSync(),
        reason: 'orphan temporary folder removed',
      );
      expect(Directory(active).existsSync(), isTrue);
      expect(File('$active\\a.bin').readAsBytesSync(), content(95, 90 * kib));
      run.held.send(job.tree.frames[1]);
      run.held.finish();
      expect(answered(await run.result).json['state'], 'saved');
      expect(
        File('${s.receiveDir}\\proyecto\\b.bin').readAsBytesSync(),
        content(96, 90 * kib),
      );
    }, timeout: long);
  });

  group('E596, RF-279 and punto 18: a name that no longer fits after the '
      'move', () {
    test('NameTooLong ends in pathTooLong, rejected with path_too_long, and '
        'nothing stays', () async {
      final s = await stack(
        configure: (platform) {
          platform.moveFolder = (_, _, _, _) async => const NameTooLong();
        },
      );
      seedReceiveFolder(s);
      final before = snapshotOf(s.receiveDir);
      final (:job, :permit) = await accepted(s, [('x.txt', content(60, 500))]);

      final reply = answered(await upload(s, job, permit, job.stream));

      expect(reply.status, 200);
      expect(reply.json, {'state': 'rejected', 'reason': 'path_too_long'});
      await expectEndedAs(s, laptop, job, TransferOutcome.pathTooLong, {
        'state': 'rejected',
        'reason': 'path_too_long',
      });
      expect(TransferOutcome.pathTooLong.kind, TransferResultKind.rejected);
      await expectUntouched(s, before);
    });

    test('the maximum name length handed to the move is the one left by the '
        'longest path', () async {
      var seen = -1;
      final s = await stack(
        configure: (platform) {
          platform.moveFolder = (from, folder, name, maxNameUnits) async {
            seen = maxNameUnits;
            return realFs.moveFolderToFreeName(
              from,
              folder,
              name,
              maxNameUnits: maxNameUnits,
            );
          };
        },
      );
      final (:job, :permit) = await accepted(s, [
        ('uno', null),
        (r'uno\dos.txt', content(61, 500)),
      ]);

      final reply = answered(await upload(s, job, permit, job.stream));

      expect(reply.json['state'], 'saved');
      expect(seen, 259 - s.receiveDir.length - 2 - job.declared.longest);
    });
  });

  group('E474, RF-284: progress while the folder arrives', () {
    test('bytes and files grow, the card changes at least once a second and '
        'a folder without bytes is complete from the start', () async {
      final s = await stack();
      s.clock.followRealTime();
      final entries = <TreeEntry>[
        for (var i = 0; i < 6; i++) ('f$i.bin', content(70 + i, 70 * kib)),
      ];
      final (:job, :permit) = await accepted(s, entries);
      final view = s.incoming!;
      expect(view.isFolder, isTrue);
      expect(view.fileCount, 6);
      expect(view.size, 6 * 70 * kib);
      expect(view.receivedFiles, 0);
      expect(view.receivedBytes, 0);
      final changes = <(Duration, int, int)>[];
      final stopwatch = Stopwatch()..start();
      final subscription = s.coordinator.changes.listen((_) {
        final now = s.incoming;
        if (now != null) {
          changes.add((
            stopwatch.elapsed,
            now.receivedBytes,
            now.receivedFiles,
          ));
        }
      });
      addTearDown(subscription.cancel);

      final run = startUpload(s, job, permit);
      for (final frame in job.tree.frames) {
        run.held.send(frame);
        await Future<void>.delayed(const Duration(milliseconds: 400));
      }
      run.held.finish();
      answered(await run.result);

      final grown = changes.where((c) => c.$2 > 0).toList();
      expect(grown, isNotEmpty);
      var lastBytes = -1;
      var lastAt = grown.first.$1;
      for (final (at, bytes, _) in grown) {
        if (bytes != lastBytes) {
          expect(
            at - lastAt,
            lessThan(const Duration(seconds: 1)),
            reason: 'a change at least once a second',
          );
          lastBytes = bytes;
          lastAt = at;
        }
      }
      expect(grown.map((c) => c.$2).toSet().length, greaterThan(2));
      expect(grown.map((c) => c.$3).reduce((a, b) => a > b ? a : b), 5);
      expect(s.coordinator.lastReceived?.outcome, TransferOutcome.saved);
      expect(s.coordinator.lastReceived?.fileCount, 6);
    }, timeout: long);

    test('a folder with no bytes shows size 0 and is saved at once', () async {
      final s = await stack();
      final (:job, :permit) = await accepted(s, [('solo', null)]);
      expect(s.incoming?.size, 0);
      expect(s.incoming?.fileCount, 0);

      final reply = answered(await upload(s, job, permit, job.stream));

      expect(reply.json['state'], 'saved');
      expect(Directory('${s.receiveDir}\\proyecto\\solo').existsSync(), isTrue);
    });
  });

  group('E476 [SEG], RF-280 and RF-300: the pairing or the interface goes '
      'during the folder', () {
    Future<
      ({
        ReceiverStack s,
        FolderJob job,
        String permit,
        ({HeldBody held, Future<StreamPostResult> result}) run,
        Map<String, String> before,
      })
    >
    midway() async {
      final s = await stack();
      seedReceiveFolder(s);
      final before = snapshotOf(s.receiveDir);
      final (:job, :permit) = await accepted(s, [
        ('a.bin', content(80, 90 * kib)),
        ('b.bin', content(81, 90 * kib)),
      ]);
      final run = startUpload(s, job, permit);
      run.held.send(job.tree.frames[0]);
      await eventually(
        () => s.incoming?.receivedBytes == 90 * kib,
        reason: 'first file written',
      );
      return (s: s, job: job, permit: permit, run: run, before: before);
    }

    test('peerUnpaired during the upload cuts it', () async {
      final m = await midway();

      m.s.coordinator.peerUnpaired(laptop.fingerprint);

      expect(
        await m.run.result.timeout(const Duration(seconds: 20)),
        isA<StreamPostFailed>(),
      );
      await eventually(
        () => m.s.coordinator.lastReceived?.outcome == TransferOutcome.unpaired,
        reason: 'unpaired',
      );
      await expectUntouched(m.s, m.before);
      expectCleanLogs(m.s, [m.permit]);
    });

    test('the sender removed from the paired list cuts it', () async {
      final m = await midway();

      await m.s.paired.remove(laptop.fingerprint);
      m.s.coordinator.pairedChanged();

      expect(
        await m.run.result.timeout(const Duration(seconds: 20)),
        isA<StreamPostFailed>(),
      );
      await eventually(
        () => m.s.coordinator.lastReceived?.outcome == TransferOutcome.unpaired,
        reason: 'unpaired',
      );
      await expectUntouched(m.s, m.before);
    });

    test('the interface of the session going down cuts it', () async {
      final m = await midway();

      m.s.coordinator.interfacesChanged(const {});

      expect(
        await m.run.result.timeout(const Duration(seconds: 20)),
        isA<StreamPostFailed>(),
      );
      await eventually(
        () =>
            m.s.coordinator.lastReceived?.outcome ==
            TransferOutcome.interfaceDown,
        reason: 'interface down',
      );
      await expectUntouched(m.s, m.before);
    });

    test('unpairing another device changes nothing', () async {
      final m = await midway();

      m.s.coordinator.peerUnpaired(desk.fingerprint);
      await settle();

      expect(m.s.incoming?.stage, IncomingStage.receiving);
      m.run.held.send(m.job.tree.frames[1]);
      m.run.held.finish();
      expect(answered(await m.run.result).json['state'], 'saved');
    });
  });

  group('E592 and Q-10: cancelling or unpairing while the folder is '
      'checked', () {
    Future<
      ({
        ReceiverStack s,
        FolderJob job,
        Future<StreamPostResult> result,
        Map<String, String> before,
      })
    >
    checking({
      void Function(TransferPlatform platform)? configure,
      int folders = 4000,
    }) async {
      final s = await stack(configure: configure);
      seedReceiveFolder(s);
      final before = snapshotOf(s.receiveDir);
      final job = flatFolders(folders);
      final permit = await s.acceptedPermit(laptop, job);
      await eventually(
        () => s.incoming?.stage == IncomingStage.waitingData,
        reason: 'accepted card',
      );
      final result = upload(s, job, permit, job.stream);
      await eventually(
        () => s.incoming?.stage == IncomingStage.verifying,
        reason: 'verifying',
      );
      return (s: s, job: job, result: result, before: before);
    }

    test('the view offers cancel while the tree is checked', () async {
      final c = await checking();

      expect(c.s.incoming?.canCancel, isTrue);
      c.s.coordinator.cancelIncoming(c.s.sid);
      await c.result.timeout(const Duration(seconds: 20));
    }, timeout: long);

    test('the receiver cancels before the move: cancelledHere, the sender '
        'is told, and the receive folder is as it was', () async {
      final c = await checking();

      c.s.coordinator.cancelIncoming(c.s.sid);

      final done = await c.result.timeout(const Duration(seconds: 20));
      if (done is StreamPostAnswered) {
        expect(RawReply(done.response.status, done.response.body).json, {
          'state': 'cancelled',
        });
      }
      await eventually(
        () =>
            c.s.coordinator.lastReceived?.outcome ==
            TransferOutcome.cancelledHere,
        reason: 'cancelled here',
      );
      expectState(await c.s.wait(laptop, c.job.transfer), {
        'state': 'cancelled',
      });
      await expectUntouched(c.s, c.before);
    }, timeout: long);

    test('the sender cancels before the move: cancelledByPeer in both and '
        'the receive folder is as it was', () async {
      final c = await checking();

      final reply = await c.s.cancel(laptop, c.job.transfer);

      expect(reply?.status, 200, reason: reply?.text);
      expect(reply?.json, {'state': 'cancelled'});
      await c.result.timeout(const Duration(seconds: 20));
      await eventually(
        () =>
            c.s.coordinator.lastReceived?.outcome ==
            TransferOutcome.cancelledByPeer,
        reason: 'cancelled by the peer',
      );
      await expectUntouched(c.s, c.before);
    }, timeout: long);

    test('Q-10: unpairing the sender before the move cuts the folder, '
        'nothing is saved', () async {
      final c = await checking();

      await c.s.paired.remove(laptop.fingerprint);
      c.s.coordinator.pairedChanged();

      await c.result
          .timeout(const Duration(seconds: 20))
          .then<void>((_) {}, onError: (Object _) {});
      await eventually(
        () => c.s.coordinator.lastReceived?.outcome == TransferOutcome.unpaired,
        reason: 'unpaired',
      );
      await expectUntouched(c.s, c.before);
    }, timeout: long);

    test('Q-10: peerUnpaired before the move cuts the folder too', () async {
      final c = await checking();

      c.s.coordinator.peerUnpaired(laptop.fingerprint);

      await c.result
          .timeout(const Duration(seconds: 20))
          .then<void>((_) {}, onError: (Object _) {});
      await eventually(
        () => c.s.coordinator.lastReceived?.outcome == TransferOutcome.unpaired,
        reason: 'unpaired',
      );
      await expectUntouched(c.s, c.before);
    }, timeout: long);

    test('the interface going down before the move cuts the folder', () async {
      final c = await checking();

      c.s.coordinator.interfacesChanged(const {});

      await c.result
          .timeout(const Duration(seconds: 20))
          .then<void>((_) {}, onError: (Object _) {});
      await eventually(
        () =>
            c.s.coordinator.lastReceived?.outcome ==
            TransferOutcome.interfaceDown,
        reason: 'interface down',
      );
      await expectUntouched(c.s, c.before);
    }, timeout: long);

    test('closing the receiver before the move cuts the folder and leaves '
        'nothing', () async {
      final c = await checking();

      await c.s.coordinator.close();

      await c.result
          .timeout(const Duration(seconds: 20))
          .then<void>((_) {}, onError: (Object _) {});
      expect(
        c.s.coordinator.lastReceived?.outcome,
        TransferOutcome.cancelledHere,
      );
      expect(snapshotOf(c.s.receiveDir), c.before);
    }, timeout: long);

    group('once the move has started', () {
      Future<
        ({
          ReceiverStack s,
          FolderJob job,
          String permit,
          Future<StreamPostResult> result,
          Completer<void> gate,
        })
      >
      moving() async {
        final gate = Completer<void>();
        final reached = Completer<void>();
        final s = await stack(
          configure: (platform) {
            platform.moveFolder = (from, folder, name, maxNameUnits) async {
              if (!reached.isCompleted) reached.complete();
              await gate.future;
              return realFs.moveFolderToFreeName(
                from,
                folder,
                name,
                maxNameUnits: maxNameUnits,
              );
            };
          },
        );
        addTearDown(() {
          if (!gate.isCompleted) gate.complete();
        });
        final (:job, :permit) = await accepted(s, [
          ('x', null),
          (r'x\y.txt', content(90, 4000)),
        ]);
        final result = upload(s, job, permit, job.stream);
        await reached.future.timeout(const Duration(seconds: 20));
        return (s: s, job: job, permit: permit, result: result, gate: gate);
      }

      test('the view no longer offers cancel and the receiver cancel does '
          'nothing', () async {
        final m = await moving();

        expect(m.s.incoming?.stage, IncomingStage.verifying);
        expect(m.s.incoming?.canCancel, isFalse);
        m.s.coordinator.cancelIncoming(m.s.sid);
        await settle();
        expect(m.s.coordinator.busy, isTrue);
        m.gate.complete();

        final reply = answered(await m.result);
        expect(reply.json, {
          'state': 'saved',
          'marked': true,
          'name': 'proyecto',
        });
        expect(
          File('${m.s.receiveDir}\\proyecto\\x\\y.txt').readAsBytesSync(),
          content(90, 4000),
        );
      }, timeout: long);

      test('a cancel from the sender waits for the end and answers saved, '
          'the folder stays', () async {
        final m = await moving();

        final pending = m.s.cancel(laptop, m.job.transfer);
        await settle();
        m.gate.complete();
        final reply = await pending;

        expect(reply?.status, 200, reason: reply?.text);
        expect(reply?.json, {
          'state': 'saved',
          'marked': true,
          'name': 'proyecto',
        });
        expect(
          File('${m.s.receiveDir}\\proyecto\\x\\y.txt').existsSync(),
          isTrue,
        );
        expect(m.s.coordinator.lastReceived?.outcome, TransferOutcome.saved);
      }, timeout: long);

      test('unpairing or a falling interface during the move changes '
          'nothing: the folder is saved', () async {
        final m = await moving();

        m.s.coordinator.peerUnpaired(laptop.fingerprint);
        m.s.coordinator.interfacesChanged(const {});
        await settle();
        expect(m.s.coordinator.busy, isTrue);
        m.gate.complete();

        await m.result
            .timeout(const Duration(seconds: 20))
            .then<void>((_) {}, onError: (Object _) {});
        await eventually(
          () => m.s.coordinator.lastReceived != null,
          reason: 'result',
        );
        expect(m.s.coordinator.lastReceived?.outcome, TransferOutcome.saved);
        expect(
          File('${m.s.receiveDir}\\proyecto\\x\\y.txt').existsSync(),
          isTrue,
        );
      }, timeout: long);
    });
  });
}
