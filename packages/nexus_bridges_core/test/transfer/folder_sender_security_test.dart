@TestOn('windows')
library;

import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:nexus_bridges_core/src/protocol/protocol.dart';
import 'package:nexus_bridges_core/src/transfer/folder_plan.dart';
import 'package:nexus_bridges_core/src/transfer/loose_file.dart';
import 'package:nexus_bridges_core/src/transfer/transfer.dart';
import 'package:nexus_bridges_core/src/transfer/windows_folder_io.dart';
import 'package:test/test.dart';
import 'package:win32/win32.dart';

import 'folder_sender_test.dart'
    show
        anyFileContains,
        freeDriveLetter,
        hardLink,
        holdWithoutSharing,
        junction,
        keyContent,
        long,
        refusedHere,
        sendOne,
        stacks,
        startSend,
        treeOf,
        write;
import 'folder_writer_support.dart' show content;
import 'transfer_stacks_harness.dart';

const int kib = 1024;

String adminUnc(String local, {String host = 'localhost'}) =>
    r'\\' + host + r'\' + local[0] + r'$' + local.substring(2);

String deviceUnc(String local) =>
    r'\\?\UNC\localhost\' + local[0] + r'$' + local.substring(2);

bool adminShareReachable(String local) {
  try {
    return FileSystemEntity.typeSync(adminUnc(local)) !=
        FileSystemEntityType.notFound;
  } catch (_) {
    return false;
  }
}

bool skippedWithoutAdminShare(String local) {
  if (adminShareReachable(local)) return false;
  markTestSkipped(
    'the administrative share ${local[0]}\$ is not reachable: it needs an '
    'administrator account and the Server service',
  );
  return true;
}

(int, int) identityOf(String path) => using((Arena arena) {
  final Win32Result(value: handle) = CreateFile(
    arena.pcwstr(path),
    0x80,
    FILE_SHARE_MODE(7),
    null,
    OPEN_EXISTING,
    FILE_FLAG_BACKUP_SEMANTICS | FILE_FLAG_OPEN_REPARSE_POINT,
    null,
  );
  expect(handle.isValid, isTrue, reason: 'identity of $path');
  try {
    final info = arena<BY_HANDLE_FILE_INFORMATION>();
    final Win32Result(value: informed) = GetFileInformationByHandle(
      handle,
      info,
    );
    expect(informed, isTrue, reason: 'identity of $path');
    return (
      info.ref.dwVolumeSerialNumber,
      (info.ref.nFileIndexHigh << 32) | info.ref.nFileIndexLow,
    );
  } finally {
    handle.close();
  }
});

String? shortPathOf(String path) => using((Arena arena) {
  final buffer = arena.pwstrBuffer(1024);
  final Win32Result(value: length) = GetShortPathName(
    arena.pcwstr(path),
    buffer,
    1024,
  );
  if (length == 0 || length >= 1024) return null;
  return buffer.toDartString(length: length);
});

String currentAccount() {
  final env = Platform.environment;
  final user = env['USERNAME']!;
  final domain = env['USERDOMAIN'];
  return domain == null || domain.isEmpty ? user : '$domain\\$user';
}

bool skippedUnlessDenied(String folder) {
  final account = currentAccount();
  final made = Process.runSync('icacls', [folder, '/deny', '$account:(RD)']);
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
    'icacls could not deny the listing, or the account bypasses it',
  );
  return true;
}

Future<String> scratch(String prefix) async =>
    (await realFs.realPath((await transferFolder(prefix)).path))!;

Future<PlanResult> planAt(String root, {required String dataDir}) {
  final job = FolderPlanJob.start(
    rootRealPath: root,
    name: root.substring(root.lastIndexOf('\\') + 1),
    exclusions: defaultExclusions,
    dataDirPath: dataDir,
    dataDirRealPath: dataDir,
    onProgress: (entries, hashed) {},
  );
  return job.result.timeout(const Duration(seconds: 60));
}

Future<FolderPlan> readyPlanAt(String root, {required String dataDir}) async {
  final result = await planAt(root, dataDir: dataDir);
  expect(result, isA<PlanReady>());
  return (result as PlanReady).plan;
}

Set<String> entriesOf(FolderPlan plan) => {
  for (var i = 1; i <= plan.manifest.length; i++) plan.manifest.relativePath(i),
};

String keyOf(TransferStack a) => '${a.dataDir}\\identity\\private-key.dpapi';

String writeKey(TransferStack a) {
  final key = keyOf(a);
  write(key, keyContent);
  return key;
}

void expectNoKeyAt(TransferStack b) {
  expect(anyFileContains(b.base, utf8.encode(keyContent)), isFalse);
}

Future<void> refusedAs(
  TransferStack a,
  TransferStack b,
  List<String> paths,
  TransferOutcome outcome,
) async {
  TransferResultView? last;
  for (final path in paths) {
    final result = await refusedHere(a, b, path, after: last);
    expect(result?.outcome, outcome, reason: path);
    last = result;
  }
}

Gate<void> holdOffers(TransferStack b) {
  final gate = Gate<void>(null);
  b.wrappers[ApiPaths.transferOffer] = (call, inner) async {
    await gate.wait();
    return inner(call);
  };
  return gate;
}

Future<FileHashResult> hashLoose(String path, String dataDir) =>
    hashLooseFile(path: path, dataPath: dataDir, abort: AbortSignal());

void main() {
  group('M-1, E423 [SEG], RF-257: the data folder through an administrative '
      'share as a loose element', () {
    test('the key, the identity folder and the data folder by '
        '\\\\localhost, \\\\127.0.0.1 and \\\\?\\UNC are protectedData, with '
        'no offer and no key bytes at the receiver', () async {
      final (a, b) = await stacks();
      if (skippedWithoutAdminShare(a.base)) return;
      final key = writeKey(a);

      await refusedAs(a, b, [
        adminUnc(key),
        adminUnc(key, host: '127.0.0.1'),
        deviceUnc(key),
        adminUnc('${a.dataDir}\\identity'),
        adminUnc(a.dataDir),
        adminUnc(a.dataDir, host: '127.0.0.1'),
        deviceUnc(a.dataDir),
      ], TransferOutcome.protectedData);

      expect(b.handledTotal, 0);
      expectNoKeyAt(b);
    }, timeout: long);

    test('a drive mapped to the administrative share: the key and the data '
        'folder are protectedData and its root is wholeDrive', () async {
      final (a, b) = await stacks();
      if (skippedWithoutAdminShare(a.base)) return;
      final key = writeKey(a);
      final letter = freeDriveLetter();
      if (letter == null) {
        markTestSkipped('no free drive letter for net use');
        return;
      }
      final share = r'\\localhost\' + a.base[0] + r'$';
      final made = Process.runSync('net', [
        'use',
        '$letter:',
        share,
        '/persistent:no',
      ]);
      if (made.exitCode != 0) {
        markTestSkipped('net use could not map $share: ${made.stderr}');
        return;
      }
      addTearDown(
        () => Process.runSync('net', ['use', '$letter:', '/delete', '/y']),
      );

      await refusedAs(a, b, [
        '$letter:${key.substring(2)}',
        '$letter:${a.dataDir.substring(2)}',
        '$letter:${a.base.substring(2)}',
      ], TransferOutcome.protectedData);
      await refusedAs(a, b, ['$letter:\\'], TransferOutcome.wholeDrive);

      expectNoKeyAt(b);
    }, timeout: long);
  });

  group('M-1, E607 [SEG], RF-257: a folder that holds the data folder, '
      'through an administrative share', () {
    test('chosen by \\\\localhost, \\\\127.0.0.1 or \\\\?\\UNC it is '
        'protectedData and nothing reaches the receiver', () async {
      final (a, b) = await stacks();
      if (skippedWithoutAdminShare(a.base)) return;
      writeKey(a);
      write('${a.sourceDir}\\keep.txt', 'keep');

      await refusedAs(a, b, [
        adminUnc(a.base),
        adminUnc(a.base, host: '127.0.0.1'),
        deviceUnc(a.base),
      ], TransferOutcome.protectedData);

      expect(b.handledTotal, 0);
      expectNoKeyAt(b);
    }, timeout: long);
  });

  group('M-1, F1 and F2 [SEG], RF-257: the plan leaves the data folder out by '
      'identity, not by text', () {
    test('a root reached by \\\\localhost\\C\$ that holds the data folder '
        'leaves it out as protected and keeps the rest', () async {
      final base = await scratch('nexus_m1_plan_');
      if (skippedWithoutAdminShare(base)) return;
      final root = '$base\\root';
      final data = '$root\\data';
      write('$data\\identity\\private-key.dpapi', keyContent);
      write('$data\\paired.json', '{"version":1}');
      write('$root\\keep.txt', 'keep');
      write('$root\\sub\\note.txt', 'note');

      final plan = await readyPlanAt(adminUnc(root), dataDir: data);

      expect(entriesOf(plan), {'keep.txt', 'sub', 'sub\\note.txt'});
      expect(plan.summary.protectedOmitted, 1);
      expect(plan.summary.files, 2);
    }, timeout: long);

    test('a root reached by \\\\localhost\\C\$ inside the data folder drops '
        'every file by identity, also those with a single link', () async {
      final base = await scratch('nexus_m1_plan_');
      if (skippedWithoutAdminShare(base)) return;
      final data = '$base\\data';
      write('$data\\identity\\private-key.dpapi', keyContent);
      write('$data\\identity\\certificate.pem', 'certificate');

      final plan = await readyPlanAt(
        adminUnc('$data\\identity'),
        dataDir: data,
      );

      expect(entriesOf(plan), isEmpty);
      expect(plan.summary.protectedOmitted, 2);
      expect(plan.summary.files, 0);
    }, timeout: long);

    test('without any share: the data folder named by its 8.3 short path is '
        'still left out of a folder that holds it, and its files are '
        'dropped by identity', () async {
      final base = await scratch('nexus_m1_short_');
      final root = '$base\\root';
      final data = '$root\\NexusBridgesData';
      write('$data\\identity\\private-key.dpapi', keyContent);
      write('$root\\keep.txt', 'keep');
      final short = shortPathOf(data);
      if (short == null || short.toUpperCase() == data.toUpperCase()) {
        markTestSkipped('8.3 short names are disabled on this volume');
        return;
      }

      final outer = await readyPlanAt(root, dataDir: short);
      expect(entriesOf(outer), {'keep.txt'});
      expect(outer.summary.protectedOmitted, 1);

      final inner = await readyPlanAt('$data\\identity', dataDir: short);
      expect(entriesOf(inner), isEmpty);
      expect(inner.summary.protectedOmitted, 1);
    }, timeout: long);
  });

  group('Q-4, SEC-12: administrative shares are protectedData and a hidden '
      'share of the user is not', () {
    test('\\\\localhost\\ADMIN\$ and a file inside it end as protectedData '
        'without asking anything', () async {
      final (a, b) = await stacks();
      if (FileSystemEntity.typeSync('\\\\localhost\\ADMIN\$\\win.ini') ==
          FileSystemEntityType.notFound) {
        markTestSkipped(
          'the administrative share ADMIN\$ is not reachable: it needs an '
          'administrator account and the Server service',
        );
        return;
      }

      await refusedAs(a, b, [
        '\\\\localhost\\ADMIN\$',
        '\\\\localhost\\admin\$\\win.ini',
        '\\\\?\\UNC\\localhost\\ADMIN\$\\win.ini',
      ], TransferOutcome.protectedData);
    }, timeout: long);

    test('a folder inside a hidden share of the user is sent', () async {
      final (a, b) = await stacks();
      final base = await scratch('nexus_q4_share_');
      final shared = '$base\\shared';
      write('$shared\\proj\\a.txt', 'a');
      write('$shared\\proj\\sub\\b.txt', 'b');
      final made = Process.runSync('net', [
        'share',
        'nexusq4\$=$shared',
        '/grant:Everyone,READ',
      ]);
      if (made.exitCode != 0) {
        markTestSkipped('net share could not create a share: needs an admin');
        return;
      }
      addTearDown(
        () => Process.runSync('net', ['share', 'nexusq4\$', '/delete', '/y']),
      );

      final result = await startSend(
        a,
        b,
        '\\\\localhost\\nexusq4\$\\proj',
      ).timeout(const Duration(seconds: 40));

      expect(result?.outcome, TransferOutcome.saved);
      expect(treeOf('${b.receiveDir}\\proj'), {
        'a.txt': 'a',
        'sub': null,
        'sub\\b.txt': 'b',
      });
    }, timeout: long);
  });

  group('B-2, E419, RF-306: the root of an administrative share is a whole '
      'drive', () {
    test(
      '\\\\localhost\\C\$, \\\\127.0.0.1\\C\$ and \\\\?\\UNC\\localhost\\C\$ '
      'end as wholeDrive without asking anything',
      () async {
        final (a, b) = await stacks();
        final drive = a.base[0];
        await refusedAs(a, b, [
          '\\\\localhost\\$drive\$',
          '\\\\localhost\\$drive\$\\',
          '\\\\127.0.0.1\\$drive\$',
          '\\\\?\\UNC\\localhost\\$drive\$\\',
          '\\\\.\\UNC\\localhost\\$drive\$',
        ], TransferOutcome.wholeDrive);
      },
      timeout: long,
    );
  });

  group('B-5, M-1: fileIdsUnder', () {
    test('without includeFolders it gives the files only; with it, also every '
        'folder and the folder itself', () async {
      final base = await scratch('nexus_b5_ids_');
      final data = '$base\\data';
      write('$data\\identity\\private-key.dpapi', keyContent);
      write('$data\\paired.json', '{}');
      write('$data\\sub\\deeper\\x.bin', 'x');
      final files = {
        identityOf('$data\\identity\\private-key.dpapi'),
        identityOf('$data\\paired.json'),
        identityOf('$data\\sub\\deeper\\x.bin'),
      };
      final folders = {
        identityOf(data),
        identityOf('$data\\identity'),
        identityOf('$data\\sub'),
        identityOf('$data\\sub\\deeper'),
      };

      expect(fileIdsUnder(data), files);
      expect(fileIdsUnder(data, includeFolders: true), {...files, ...folders});
    });

    test('a junction inside is neither followed nor counted', () async {
      final base = await scratch('nexus_b5_ids_');
      final data = '$base\\data';
      write('$data\\paired.json', '{}');
      write('$base\\outside\\loose.txt', 'loose');
      junction('$data\\door', '$base\\outside');

      final ids = fileIdsUnder(data, includeFolders: true)!;

      expect(ids, {identityOf(data), identityOf('$data\\paired.json')});
      expect(ids, isNot(contains(identityOf('$base\\outside'))));
      expect(ids, isNot(contains(identityOf('$base\\outside\\loose.txt'))));
    });

    test('a folder that does not exist gives an empty set, not null', () async {
      final base = await scratch('nexus_b5_ids_');

      expect(fileIdsUnder('$base\\missing'), isEmpty);
      expect(fileIdsUnder('$base\\missing', includeFolders: true), isEmpty);
      expect(fileIdsUnder('$base\\missing', includeFolders: true), isNotNull);
    });

    test('a subfolder that cannot be listed makes the whole walk null, with '
        'and without includeFolders', () async {
      final base = await scratch('nexus_b5_ids_');
      final data = '$base\\data';
      write('$data\\paired.json', '{}');
      write('$data\\locked\\inside.bin', 'inside');
      if (skippedUnlessDenied('$data\\locked')) return;

      expect(fileIdsUnder(data), isNull);
      expect(fileIdsUnder(data, includeFolders: true), isNull);
    });

    test('the walk also matches through \\\\localhost\\C\$', () async {
      final base = await scratch('nexus_b5_ids_');
      if (skippedWithoutAdminShare(base)) return;
      final data = '$base\\data';
      write('$data\\identity\\private-key.dpapi', keyContent);

      expect(
        fileIdsUnder(adminUnc(data), includeFolders: true),
        fileIdsUnder(data, includeFolders: true),
      );
    });
  });

  group('B-5, M-1: checkAgainstData', () {
    test('a file and a folder outside the data folder are clear', () async {
      final base = await scratch('nexus_b5_check_');
      final data = '$base\\data';
      write('$data\\identity\\private-key.dpapi', keyContent);
      write('$base\\other\\note.txt', 'note');

      expect(checkAgainstData('$base\\other\\note.txt', data), DataCheck.clear);
      expect(checkAgainstData('$base\\other', data), DataCheck.clear);
      expect(checkAgainstData(base, data), DataCheck.clear);
    });

    test('the key, the data folder, a folder inside and a hard link to the '
        'key outside are inData', () async {
      final base = await scratch('nexus_b5_check_');
      final data = '$base\\data';
      final key = '$data\\identity\\private-key.dpapi';
      write(key, keyContent);
      hardLink('$base\\twin.bin', key);

      for (final path in [key, data, '$data\\identity', '$base\\twin.bin']) {
        expect(checkAgainstData(path, data), DataCheck.inData, reason: path);
      }
    });

    test('the key and the data folder by \\\\localhost\\C\$ and '
        '\\\\?\\UNC are inData', () async {
      final base = await scratch('nexus_b5_check_');
      if (skippedWithoutAdminShare(base)) return;
      final data = '$base\\data';
      final key = '$data\\identity\\private-key.dpapi';
      write(key, keyContent);

      for (final path in [
        adminUnc(key),
        adminUnc(key, host: '127.0.0.1'),
        deviceUnc(key),
        adminUnc(data),
        adminUnc('$data\\identity'),
      ]) {
        expect(checkAgainstData(path, data), DataCheck.inData, reason: path);
      }
      expect(
        checkAgainstData(adminUnc('$base\\other'), data),
        isNot(DataCheck.clear),
      );
    });

    test(
      'a data folder that cannot be walked makes any element inData',
      () async {
        final base = await scratch('nexus_b5_check_');
        final data = '$base\\data';
        write('$data\\locked\\inside.bin', 'inside');
        write('$base\\other\\note.txt', 'note');
        if (skippedUnlessDenied('$data\\locked')) return;

        expect(
          checkAgainstData('$base\\other\\note.txt', data),
          DataCheck.inData,
        );
      },
    );

    test('a file whose identity cannot be read for a sharing violation is '
        'unreadable, not inData', () async {
      final base = await scratch('nexus_b5_check_');
      final data = '$base\\data';
      write('$data\\paired.json', '{}');
      String? busy;
      for (final drive in 'CDEFGH'.split('')) {
        for (final name in ['pagefile.sys', 'swapfile.sys']) {
          final candidate = '$drive:\\$name';
          if (checkAgainstData(candidate, data) == DataCheck.unreadable) {
            busy = candidate;
            break;
          }
        }
        if (busy != null) break;
      }
      if (busy == null) {
        markTestSkipped('no paging file held by the system on C: to H:');
        return;
      }
      expect(checkAgainstData(busy, data), DataCheck.unreadable);
    });

    test(
      'a file held without sharing by another handle is never inData',
      () async {
        final base = await scratch('nexus_b5_check_');
        final data = '$base\\data';
        write('$data\\paired.json', '{}');
        write('$base\\held.txt', 'held');
        holdWithoutSharing('$base\\held.txt');

        expect(
          checkAgainstData('$base\\held.txt', data),
          isNot(DataCheck.inData),
        );
      },
    );
  });

  group('B-5, F2 and F9 [SEG], RF-257: a data folder that cannot be walked '
      'fails closed', () {
    test('the plan stops as protectedData', () async {
      final base = await scratch('nexus_b5_plan_');
      final data = '$base\\data';
      write('$data\\locked\\inside.bin', 'inside');
      write('$base\\root\\keep.txt', 'keep');
      if (skippedUnlessDenied('$data\\locked')) return;

      final result = await planAt('$base\\root', dataDir: data);

      expect(result, isA<PlanStopped>());
      expect((result as PlanStopped).outcome, TransferOutcome.protectedData);
    }, timeout: long);

    test('a loose file and a folder are protectedData with no offer, and once '
        'the data folder can be walked again the same file is sent', () async {
      final (a, b) = await stacks();
      write('${a.dataDir}\\locked\\inside.bin', 'inside');
      final file = '${a.sourceDir}\\note.txt';
      write(file, 'note');
      write('${a.sourceDir}\\proj\\keep.txt', 'keep');
      final account = currentAccount();
      if (skippedUnlessDenied('${a.dataDir}\\locked')) return;

      await refusedAs(a, b, [
        file,
        '${a.sourceDir}\\proj',
      ], TransferOutcome.protectedData);

      final undone = Process.runSync('icacls', [
        '${a.dataDir}\\locked',
        '/remove:d',
        account,
      ]);
      expect(undone.exitCode, 0);
      final (_, sent, received) = await sendOne(a, b, file);
      expect(sent.outcome, TransferOutcome.saved);
      expect(received.outcome, TransferOutcome.saved);
    }, timeout: long);

    test(
      'the loose hash treats an unwalkable data folder as protected',
      () async {
        final base = await scratch('nexus_b5_hash_');
        final data = '$base\\data';
        write('$data\\locked\\inside.bin', 'inside');
        write('$base\\note.txt', 'note');
        if (skippedUnlessDenied('$data\\locked')) return;

        expect(
          await hashLoose('$base\\note.txt', data),
          isA<FileHashSkipped>(),
        );
      },
    );
  });

  group('M-1, B-3 [SEG], RF-257: the loose file is checked by identity when '
      'hashed', () {
    test('the key, a hard link to it and the key by UNC are skipped; an '
        'ordinary file is hashed', () async {
      final base = await scratch('nexus_b3_hash_');
      final data = '$base\\data';
      final key = '$data\\identity\\private-key.dpapi';
      write(key, keyContent);
      hardLink('$base\\twin.bin', key);
      write('$base\\note.txt', 'note');

      expect(await hashLoose(key, data), isA<FileHashSkipped>());
      expect(await hashLoose('$base\\twin.bin', data), isA<FileHashSkipped>());
      if (adminShareReachable(base)) {
        expect(await hashLoose(adminUnc(key), data), isA<FileHashSkipped>());
      }
      final note = await hashLoose('$base\\note.txt', data);
      expect(note, isA<FileHashed>());
      expect((note as FileHashed).size, 4);
      expect(await hashLoose('$base\\note.txt', ''), isA<FileHashed>());
    });

    test('the file picker with the key or a hard link to it ends as '
        'protectedData without an offer', () async {
      final (a, b) = await stacks();
      final key = writeKey(a);
      hardLink('${a.sourceDir}\\copia.bin', key);
      final target = a.targetOf(b);
      final paths = [
        key,
        '${a.sourceDir}\\copia.bin',
        if (adminShareReachable(a.base)) adminUnc(key),
        if (adminShareReachable(a.base)) deviceUnc(key),
      ];

      TransferResultView? last;
      for (final path in paths) {
        a.picker.next = path;
        expect(
          await a.coordinator.sendFile(target, refresh: () => target),
          SendStart.started,
        );
        final sent = await a.sentResult(after: last);
        expect(sent.outcome, TransferOutcome.protectedData, reason: path);
        last = sent;
      }

      expect(b.offersReceived, 0);
      expectNoKeyAt(b);
    }, timeout: long);
  });

  group('B-3 [SEG], RF-257: the key swapped in after the checks', () {
    test('a hard link to the key put in place of the file between the offer '
        'and the upload: no key byte leaves and the sender sees '
        'unreadable', () async {
      final (a, b) = await stacks();
      final key = writeKey(a);
      final file = '${a.sourceDir}\\informe.bin';
      write(file, 'D' * keyContent.length);
      final gate = holdOffers(b);

      final returned = startSend(a, b, file);
      await gate.reached.future.timeout(const Duration(seconds: 30));
      File(file).deleteSync();
      hardLink(file, key);
      expect(File(file).readAsStringSync(), keyContent);
      gate.open(null);

      final result = await returned.timeout(const Duration(seconds: 40));
      final sent = await a.sentResult();
      expect(result, sent);
      expect(sent.outcome, TransferOutcome.unreadable);
      final received = await b.receivedResult();
      expect(received.outcome, isNot(TransferOutcome.saved));
      await settle(const Duration(milliseconds: 300));
      expectNoKeyAt(b);
      expect(File('${b.receiveDir}\\informe.bin').existsSync(), isFalse);
    }, timeout: long);

    test(
      'a symbolic link to the key put in place of the file: the same',
      () async {
        final (a, b) = await stacks();
        final key = writeKey(a);
        final file = '${a.sourceDir}\\informe.bin';
        write(file, 'D' * keyContent.length);
        try {
          Link('${a.sourceDir}\\probe').createSync(key);
          Link('${a.sourceDir}\\probe').deleteSync();
        } on FileSystemException {
          markTestSkipped('symbolic links need a privilege or developer mode');
          return;
        }
        final gate = holdOffers(b);

        final returned = startSend(a, b, file);
        await gate.reached.future.timeout(const Duration(seconds: 30));
        File(file).deleteSync();
        Link(file).createSync(key);
        addTearDown(() {
          try {
            Link(file).deleteSync();
          } on FileSystemException {
            return;
          }
        });
        gate.open(null);

        await returned.timeout(const Duration(seconds: 40));
        final sent = await a.sentResult();
        expect(sent.outcome, TransferOutcome.unreadable);
        await settle(const Duration(milliseconds: 300));
        expectNoKeyAt(b);
      },
      timeout: long,
    );
  });

  group('B-3, E149 [SEG], RF-165, RF-169, RF-171: the loose file keeps the '
      'behaviour of the 004', () {
    Future<(TransferResultView, TransferResultView)> changedBeforeUpload(
      TransferStack a,
      TransferStack b,
      String file,
      void Function() change,
    ) async {
      final gate = holdOffers(b);
      final returned = startSend(a, b, file);
      await gate.reached.future.timeout(const Duration(seconds: 30));
      change();
      gate.open(null);
      final result = await returned.timeout(const Duration(seconds: 40));
      final sent = await a.sentResult();
      expect(result, sent);
      return (sent, await b.receivedResult());
    }

    test('rewritten in place with the same size: damaged on both and nothing '
        'saved', () async {
      final (a, b) = await stacks();
      final original = content(31, 256 * kib);
      final file = '${a.sourceDir}\\informe.bin';
      write(file, original);
      final identity = identityOf(file);

      final (sent, received) = await changedBeforeUpload(a, b, file, () {
        File(file).writeAsBytesSync(content(32, 256 * kib), flush: true);
        expect(identityOf(file), identity);
      });

      expect(sent.outcome, TransferOutcome.damaged);
      expect(received.outcome, TransferOutcome.damaged);
      expect(File('${b.receiveDir}\\informe.bin').existsSync(), isFalse);
    }, timeout: long);

    test('grown after the offer: only the announced bytes leave and both see '
        'saved', () async {
      final (a, b) = await stacks();
      final original = content(33, 256 * kib);
      final file = '${a.sourceDir}\\informe.bin';
      write(file, original);

      final (sent, received) = await changedBeforeUpload(a, b, file, () {
        File(file).writeAsBytesSync(
          content(34, 300 * kib),
          mode: FileMode.append,
          flush: true,
        );
      });

      expect(sent.outcome, TransferOutcome.saved);
      expect(received.outcome, TransferOutcome.saved);
      expect(File('${b.receiveDir}\\informe.bin').readAsBytesSync(), original);
    }, timeout: long);

    test('cut short after the offer: unreadable at the sender and nothing '
        'saved at the receiver', () async {
      final (a, b) = await stacks();
      final original = content(35, 256 * kib);
      final file = '${a.sourceDir}\\informe.bin';
      write(file, original);

      final (sent, received) = await changedBeforeUpload(a, b, file, () {
        File(file)
            .writeAsBytesSync(original.sublist(0, 100 * kib), flush: true);
      });

      expect(sent.outcome, TransferOutcome.unreadable);
      expect(received.outcome, isNot(TransferOutcome.saved));
      expect(received.outcome.kind, TransferResultKind.failed);
      expect(b.bodiesOn(ApiPaths.transferCancel).first['reason'], 'unreadable');
      await eventually(
        () => !File('${b.receiveDir}\\informe.bin').existsSync(),
        reason: 'nothing saved',
      );
    }, timeout: long);

    test('a file held without sharing or locked is unreadable, not '
        'protectedData', () async {
      final (a, b) = await stacks();
      final held = '${a.sourceDir}\\held.txt';
      final locked = '${a.sourceDir}\\locked.txt';
      write(held, 'held');
      write(locked, 'locked');
      holdWithoutSharing(held);
      await lockExclusively(locked);

      TransferResultView? last;
      for (final path in [held, locked]) {
        final returned = await startSend(
          a,
          b,
          path,
        ).timeout(const Duration(seconds: 40));
        final sent = await a.sentResult(after: last);
        expect(returned, sent, reason: path);
        expect(sent.outcome, TransferOutcome.unreadable, reason: path);
        last = sent;
      }
      expect(b.offersReceived, 0);
    }, timeout: long);
  });
}
