@TestOn('windows')
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:ffi/ffi.dart';
import 'package:nexus_bridges_core/src/protocol/protocol.dart';
import 'package:nexus_bridges_core/src/transfer/folder_plan.dart';
import 'package:nexus_bridges_core/src/transfer/manifest.dart';
import 'package:nexus_bridges_core/src/transfer/transfer.dart';
import 'package:nexus_bridges_core/src/transfer/windows_folder_io.dart';
import 'package:test/test.dart';
import 'package:win32/win32.dart';

import 'receiver_harness.dart' show realFs;

const String markerContent = 'content that must never leave the data folder';

const Timeout long = Timeout(Duration(seconds: 120));

Future<String> scratchRoot() async {
  final dir = await Directory.systemTemp.createTemp('nexus_plan_');
  addTearDown(() async {
    for (var attempt = 0; attempt < 20; attempt++) {
      if (deleteTreeNoFollowSync(dir.path)) return;
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
  });
  final real = await realFs.realPath(dir.path);
  return real!;
}

void write(String path, [Object content = 'x']) {
  File(path).createSync(recursive: true);
  if (content is List<int>) {
    File(path).writeAsBytesSync(content);
  } else {
    File(path).writeAsStringSync('$content');
  }
}

void writeWithoutNormalizing(String path) {
  final created = using((arena) {
    final Win32Result(value: handle) = CreateFile(
      arena.pcwstr('\\\\?\\$path'),
      0x40000000,
      FILE_SHARE_MODE(0),
      null,
      CREATE_NEW,
      FILE_FLAGS_AND_ATTRIBUTES(0x80),
      null,
    );
    if (!handle.isValid) return false;
    handle.close();
    return true;
  });
  expect(created, isTrue, reason: 'the file $path could not be created');
}

void junction(String link, String target) {
  final made = Process.runSync('cmd', ['/c', 'mklink', '/J', link, target]);
  expect(made.exitCode, 0, reason: '${made.stdout}${made.stderr}');
}

void hardLink(String link, String target) {
  final made = Process.runSync('cmd', ['/c', 'mklink', '/H', link, target]);
  expect(made.exitCode, 0, reason: '${made.stdout}${made.stderr}');
}

bool trySymlink(String link, String target) {
  try {
    Link(link).createSync(target);
    return true;
  } on FileSystemException {
    return false;
  }
}

void setAttributes(String path, String flags) {
  final made = Process.runSync('attrib', [...flags.split(' '), path]);
  expect(made.exitCode, 0, reason: '${made.stdout}${made.stderr}');
}

String sha(String content) => sha256.convert(utf8.encode(content)).toString();

String hexOf(Uint8List bytes) =>
    bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

final class PlanRun {
  PlanRun(this.job, this.result, this.progress);

  final FolderPlanJob job;
  final PlanResult result;
  final List<(int, int)> progress;

  FolderPlan get plan => (result as PlanReady).plan;

  FolderManifest get manifest => plan.manifest;

  List<String> get paths => [
    for (var i = 1; i <= manifest.length; i++) manifest.relativePath(i),
  ];

  Set<String> get files => {
    for (var i = 1; i <= manifest.length; i++)
      if (!manifest.isFolder(i)) manifest.relativePath(i),
  };

  Set<String> get folders => {
    for (var i = 1; i <= manifest.length; i++)
      if (manifest.isFolder(i)) manifest.relativePath(i),
  };
}

FolderPlanJob startPlan(
  String root, {
  List<String> exclusions = const [],
  String dataDir = '',
  String dataDirReal = '',
  void Function(int entries, int hashed)? onProgress,
}) => FolderPlanJob.start(
  rootRealPath: root,
  name: root.substring(root.lastIndexOf('\\') + 1),
  exclusions: exclusions,
  dataDirPath: dataDir,
  dataDirRealPath: dataDirReal.isEmpty ? dataDir : dataDirReal,
  onProgress: onProgress ?? (entries, hashed) {},
);

Future<PlanRun> runPlan(
  String root, {
  List<String> exclusions = const [],
  String dataDir = '',
}) async {
  final progress = <(int, int)>[];
  final job = startPlan(
    root,
    exclusions: exclusions,
    dataDir: dataDir,
    onProgress: (entries, hashed) => progress.add((entries, hashed)),
  );
  final result = await job.result.timeout(const Duration(seconds: 90));
  return PlanRun(job, result, progress);
}

Future<String> dataFolder(String parent) async {
  final data = '$parent\\NexusBridges';
  write('$data\\identity\\private-key.dpapi', markerContent);
  write('$data\\identity\\certificate.pem', 'certificate');
  write('$data\\settings.json', '{"version":1}');
  return (await realFs.realPath(data))!;
}

void main() {
  group('E400, RF-252: hidden, system and read-only files travel', () {
    test('every entry of a repository folder is in the manifest with its '
        'size and SHA-256', () async {
      final root = await scratchRoot();
      write('$root\\.env', 'API_URL=local');
      write('$root\\.git\\HEAD', 'ref: refs/heads/main');
      write('$root\\.git\\objects\\pack\\p.pack', 'pack bytes');
      write('$root\\hidden.txt', 'hidden bytes');
      write('$root\\system.dat', 'system bytes');
      write('$root\\empty.txt', '');
      Directory('$root\\empty folder').createSync();
      setAttributes('$root\\.git\\objects\\pack\\p.pack', '+r');
      setAttributes('$root\\hidden.txt', '+h');
      setAttributes('$root\\system.dat', '+s +h');
      setAttributes('$root\\.git', '+h');

      final run = await runPlan(root);

      expect(run.result, isA<PlanReady>());
      expect(run.files, {
        '.env',
        'hidden.txt',
        'system.dat',
        'empty.txt',
        '.git\\HEAD',
        '.git\\objects\\pack\\p.pack',
      });
      expect(run.folders, {
        '.git',
        'empty folder',
        '.git\\objects',
        '.git\\objects\\pack',
      });
      final byPath = {
        for (var i = 1; i <= run.manifest.length; i++)
          run.manifest.relativePath(i): i,
      };
      final pack = byPath['.git\\objects\\pack\\p.pack']!;
      expect(run.manifest.sizeOf(pack), 'pack bytes'.length);
      expect(hexOf(run.manifest.hashOf(pack)), sha('pack bytes'));
      final empty = byPath['empty.txt']!;
      expect(run.manifest.sizeOf(empty), 0);
      expect(hexOf(run.manifest.hashOf(empty)), sha(''));
      expect(run.plan.summary.files, 6);
      expect(run.plan.summary.folders, 4);
      expect(
        run.plan.summary.totalBytes,
        'API_URL=local'.length +
            'ref: refs/heads/main'.length +
            'pack bytes'.length +
            'hidden bytes'.length +
            'system bytes'.length,
      );
      expect(run.plan.summary.blockedOmitted, 0);
      expect(run.plan.summary.protectedOmitted, 0);
    }, timeout: long);

    test('the plan keeps the identity of each file and a program is '
        'noticed', () async {
      final root = await scratchRoot();
      write('$root\\a.txt', 'alpha');
      write('$root\\b.txt', 'beta');
      write('$root\\tool.exe', 'MZ');
      hardLink('$root\\a-twin.txt', '$root\\a.txt');

      final run = await runPlan(root);

      expect(run.plan.summary.containsPrograms, isTrue);
      expect(run.files, {'a.txt', 'a-twin.txt', 'b.txt', 'tool.exe'});
      expect(run.plan.fileVolumes.length, 4);
      expect(run.plan.fileIndexes.length, 4);
      final order = [
        for (var i = 1; i <= run.manifest.length; i++)
          if (!run.manifest.isFolder(i)) run.manifest.nameOf(i),
      ];
      final ids = {
        for (var n = 0; n < order.length; n++)
          order[n]: (run.plan.fileVolumes[n], run.plan.fileIndexes[n]),
      };
      expect(ids['a.txt'], ids['a-twin.txt']);
      expect(ids['a.txt'], isNot(ids['b.txt']));
      expect(ids['a.txt']!.$2, isNot(0));
    }, timeout: long);

    test('a folder with only text files does not contain programs', () async {
      final root = await scratchRoot();
      write('$root\\notes.txt', 'text');
      write('$root\\sub\\more.md', 'text');

      final run = await runPlan(root);

      expect(run.plan.summary.containsPrograms, isFalse);
    }, timeout: long);
  });

  group('E402, RF-253: exclusions on real folders', () {
    test('excluded folders are left out wherever they are, their size is '
        'measured apart and the rest travels', () async {
      final root = await scratchRoot();
      write('$root\\node_modules\\dep\\index.js', 'a' * 100);
      write('$root\\packages\\app\\Node_Modules\\x.js', 'b' * 40);
      write('$root\\packages\\app\\src.dart', 'src');
      write('$root\\node_modules_old\\old.js', 'old');
      write('$root\\build', 'a file called build');
      write('$root\\.dart_tool\\cache.bin', 'c' * 7);

      final run = await runPlan(
        root,
        exclusions: ['node_modules', 'build', '.dart_tool'],
      );

      expect(run.files, {
        'build',
        'node_modules_old\\old.js',
        'packages\\app\\src.dart',
      });
      expect(run.plan.summary.excludedFolders, 3);
      expect(run.plan.summary.excludedBytes, 0);
      expect(run.plan.summary.excludedBytesPartial, isTrue);
      final measured = await run.job.excluded.timeout(
        const Duration(seconds: 30),
      );
      expect(measured.bytes, 100 + 40 + 7);
      expect(measured.partial, isFalse);
    }, timeout: long);

    test('the chosen folder is sent whole when it is called like an '
        'exclusion', () async {
      final base = await scratchRoot();
      final root = '$base\\build';
      write('$root\\a.txt', 'a');
      write('$root\\sub\\b.txt', 'b');

      final run = await runPlan(root, exclusions: ['build']);

      expect(run.files, {'a.txt', 'sub\\b.txt'});
      expect(run.plan.summary.excludedFolders, 0);
      final measured = await run.job.excluded;
      expect(measured.bytes, 0);
      expect(measured.partial, isFalse);
    }, timeout: long);

    test('without excluded folders the measure is already final', () async {
      final root = await scratchRoot();
      write('$root\\a.txt', 'a');

      final run = await runPlan(root, exclusions: ['node_modules']);

      expect(run.plan.summary.excludedBytesPartial, isFalse);
      expect((await run.job.excluded).partial, isFalse);
    }, timeout: long);
  });

  group('E404, RF-255: no ignore file is read', () {
    test('a .gitignore that lists *.log does not keep the logs out', () async {
      final root = await scratchRoot();
      write('$root\\.gitignore', '*.log\nbuild/\n');
      write('$root\\run.log', 'log line');
      write('$root\\logs\\deep.log', 'log line');
      write('$root\\code.dart', 'code');

      final run = await runPlan(root);

      expect(run.files, {
        '.gitignore',
        'run.log',
        'logs\\deep.log',
        'code.dart',
      });
    }, timeout: long);
  });

  group('E405, RF-256: links are never followed', () {
    test('junctions to outside and to an own subfolder are omitted without '
        'their marker or anything of their targets', () async {
      final base = await scratchRoot();
      final outside = '$base\\outside';
      write('$outside\\marker-outside.txt', 'outside bytes');
      final root = '$base\\root';
      write('$root\\own.txt', 'own');
      write('$root\\sub\\inner.txt', 'inner');
      junction('$root\\to-outside', outside);
      junction('$root\\to-own', '$root\\sub');

      final run = await runPlan(root);

      expect(run.files, {'own.txt', 'sub\\inner.txt'});
      expect(run.plan.summary.linksOmitted, 2);
      expect(run.paths.any((p) => p.contains('marker')), isFalse);
      expect(run.paths.any((p) => p.contains('to-')), isFalse);
    }, timeout: long);

    test('symbolic links to a folder and to a file are omitted too', () async {
      final base = await scratchRoot();
      final outside = '$base\\outside';
      write('$outside\\marker-outside.txt', 'outside bytes');
      final root = '$base\\root';
      write('$root\\own.txt', 'own');
      final folderLinked = trySymlink('$root\\sym-folder', outside);
      final fileLinked = trySymlink(
        '$root\\sym-file.txt',
        '$outside\\marker-outside.txt',
      );
      if (!folderLinked && !fileLinked) {
        markTestSkipped('symbolic links need a privilege or developer mode');
        return;
      }

      final run = await runPlan(root);

      expect(run.files, {'own.txt'});
      expect(
        run.plan.summary.linksOmitted,
        (folderLinked ? 1 : 0) + (fileLinked ? 1 : 0),
      );
    }, timeout: long);

    test('the lister refuses a junction as a folder and a path that goes '
        'through one', () async {
      final base = await scratchRoot();
      write('$base\\outside\\sub\\f.txt', 'f');
      Directory('$base\\root').createSync();
      junction('$base\\root\\jn', '$base\\outside');

      expect(
        () => const WindowsFolderLister().list('$base\\root\\jn'),
        throwsA(isA<FileSystemException>()),
      );
      expect(
        () => const WindowsFolderLister().list('$base\\root\\jn\\sub'),
        throwsA(isA<FileSystemException>()),
      );
      expect(
        const WindowsFolderLister().list('$base\\outside\\sub'),
        hasLength(1),
      );
    }, timeout: long);

    test('a chosen folder that is itself a junction stops the plan as '
        'unreadable, because it must be resolved first', () async {
      final base = await scratchRoot();
      write('$base\\outside\\f.txt', 'f');
      junction('$base\\jn', '$base\\outside');

      final run = await runPlan('$base\\jn');

      expect(run.result, isA<PlanStopped>());
      expect((run.result as PlanStopped).outcome, TransferOutcome.unreadable);
    }, timeout: long);

    test('a file reached through a junction is not hashed', () async {
      final base = await scratchRoot();
      write('$base\\outside\\f.txt', 'outside bytes');
      Directory('$base\\root').createSync();
      junction('$base\\root\\jn', '$base\\outside');
      final buffer = allocateReadBuffer();
      addTearDown(() => freeReadBuffer(buffer));

      final through = hashFileSync(
        '$base\\root\\jn\\f.txt',
        buffer: buffer,
        isCancelled: () => false,
      );
      final direct = hashFileSync(
        '$base\\outside\\f.txt',
        buffer: buffer,
        isCancelled: () => false,
      );

      expect(through, isA<FileHashFailed>());
      expect(direct, isA<FileHashed>());
    }, timeout: long);
  });

  group('E408, RF-257 and DP-7: the data folder never leaves', () {
    test('a folder that contains the data folder leaves it out', () async {
      final base = await scratchRoot();
      final root = '$base\\root';
      write('$root\\keep.txt', 'keep');
      final data = await dataFolder(root);

      final run = await runPlan(root, dataDir: data);

      expect(run.files, {'keep.txt'});
      expect(run.plan.summary.protectedOmitted, 1);
      expect([
        for (var i = 1; i <= run.manifest.length; i++)
          if (!run.manifest.isFolder(i)) hexOf(run.manifest.hashOf(i)),
      ], isNot(contains(sha(markerContent))));
    }, timeout: long);

    test('a junction that leads to the data folder is a link and nothing '
        'of it is read', () async {
      final base = await scratchRoot();
      final data = await dataFolder(base);
      final root = '$base\\root';
      write('$root\\keep.txt', 'keep');
      junction('$root\\door', data);

      final run = await runPlan(root, dataDir: data);

      expect(run.files, {'keep.txt'});
      expect(run.plan.summary.linksOmitted, 1);
    }, timeout: long);

    test('a hard link to a file of the data folder is dropped without being '
        'read, and a hard link to anything else stays', () async {
      final base = await scratchRoot();
      final data = await dataFolder(base);
      final root = '$base\\root';
      write('$root\\keep.txt', 'keep');
      write('$base\\other\\shared.txt', 'shared bytes');
      hardLink('$root\\copy.bin', '$data\\identity\\private-key.dpapi');
      hardLink('$root\\second.bin', '$data\\identity\\certificate.pem');
      hardLink('$root\\shared-link.txt', '$base\\other\\shared.txt');

      final run = await runPlan(root, dataDir: data);

      expect(run.files, {'keep.txt', 'shared-link.txt'});
      expect(run.plan.summary.protectedOmitted, 2);
      expect(run.plan.summary.files, 2);
      expect(run.plan.fileIndexes.length, 2);
      expect([
        for (var i = 1; i <= run.manifest.length; i++)
          if (!run.manifest.isFolder(i)) hexOf(run.manifest.hashOf(i)),
      ], isNot(contains(sha(markerContent))));
      expect(
        utf8.decode(encodeManifest(run.plan.manifest), allowMalformed: true),
        isNot(contains('copy.bin')),
      );
    }, timeout: long);

    test(
      'the identities under a folder cover its files and skip links',
      () async {
        final base = await scratchRoot();
        final data = await dataFolder(base);
        write('$base\\outside\\loose.txt', 'loose');
        junction('$data\\door', '$base\\outside');
        hardLink('$base\\twin.bin', '$data\\identity\\private-key.dpapi');

        final ids = fileIdsUnder(data);

        expect(ids, hasLength(3));
        final buffer = allocateReadBuffer();
        addTearDown(() => freeReadBuffer(buffer));
        final twin = hashFileSync(
          '$base\\twin.bin',
          buffer: buffer,
          isCancelled: () => false,
        ) as FileHashed;
        final loose = hashFileSync(
          '$base\\outside\\loose.txt',
          buffer: buffer,
          isCancelled: () => false,
        ) as FileHashed;
        expect(ids, contains((twin.volume, twin.index)));
        expect(twin.links, 2);
        expect(ids, isNot(contains((loose.volume, loose.index))));
      },
      timeout: long,
    );
  });

  group('E409, RF-257: the app own folders are never sent', () {
    test('a receive folder with a half-written temporary folder inside '
        'leaves out .nexusbridges-incoming and the reserved names', () async {
      final root = await scratchRoot();
      write('$root\\received.txt', 'received');
      write(
        '$root\\.nexusbridges-incoming\\~nexusbridges-0123456789ab\\f',
        'half',
      );
      write(
        '$root\\.nexusbridges-incoming\\~nexusbridges-${'0' * 32}.partial',
        'p',
      );
      write('$root\\~nexusbridges-loose.partial', 'loose');

      final run = await runPlan(root);

      expect(run.files, {'received.txt'});
      expect(run.paths, ['received.txt']);
      expect(run.plan.summary.protectedOmitted, 2);
    }, timeout: long);
  });

  group('E410, E441, RF-303 and P-1: blocked types', () {
    test('desktop.ini and a .LNK are left out and counted, and the rest '
        'travels', () async {
      final root = await scratchRoot();
      write('$root\\desktop.ini', '[.ShellClassInfo]');
      write('$root\\sub\\enlace.LNK', 'link');
      write('$root\\sub\\real.txt', 'real');
      write('$root\\top.txt', 'top');

      final run = await runPlan(root);

      expect(run.files, {'sub\\real.txt', 'top.txt'});
      expect(run.plan.summary.blockedOmitted, 2);
    }, timeout: long);

    test('a folder of a blocked type is left out with all its content '
        'and counted once', () async {
      final root = await scratchRoot();
      write(
        '$root\\x.{645FF040-5081-101B-9F08-00AA002F954E}\\inside\\f.txt',
        'inside',
      );
      write('$root\\algo.LNK\\g.txt', 'g');
      write('$root\\fine\\h.txt', 'h');

      final run = await runPlan(root);

      expect(run.files, {'fine\\h.txt'});
      expect(run.folders, {'fine'});
      expect(run.plan.summary.blockedOmitted, 2);
    }, timeout: long);
  });

  group('RF-260 and RF-261: limits and names on disk', () {
    test('a name that Windows would not accept travels nowhere: the plan '
        'stops before any summary is calculated', () async {
      final root = await scratchRoot();
      write('$root\\aaa.txt', 'a' * 1000);
      write('$root\\sub\\ok.txt', 'ok');
      writeWithoutNormalizing('$root\\sub\\x.');

      final run = await runPlan(root);

      expect(run.result, isA<PlanStopped>());
      final stopped = run.result as PlanStopped;
      expect(stopped.outcome, TransferOutcome.invalidName);
      expect(stopped.problemPath, 'sub\\x.');
      expect(run.progress.where((p) => p.$2 > 0), isEmpty);
    }, timeout: long);

    test('sixty-four levels pass and sixty-five stop with tooDeep', () async {
      final base = await scratchRoot();
      final okRoot = '$base\\ok';
      final deepRoot = '$base\\deep';
      Directory(
        '$okRoot\\${List.filled(Limits.maxFolderDepth, 'd').join('\\')}',
      ).createSync(recursive: true);
      Directory(
        '$deepRoot\\${List.filled(Limits.maxFolderDepth + 1, 'd').join('\\')}',
      ).createSync(recursive: true);

      final ok = await runPlan(okRoot);
      final deep = await runPlan(deepRoot);

      expect(ok.result, isA<PlanReady>());
      expect(ok.manifest.depth, Limits.maxFolderDepth);
      expect(deep.result, isA<PlanStopped>());
      expect((deep.result as PlanStopped).outcome, TransferOutcome.tooDeep);
      expect(
        (deep.result as PlanStopped).problemPath,
        List.filled(Limits.maxFolderDepth + 1, 'd').join('\\'),
      );
    }, timeout: long);
  });

  group('E418, RF-262: a file that cannot be read', () {
    test('a file held in exclusive stops the plan with its path and no '
        'summary of the rest', () async {
      final root = await scratchRoot();
      write('$root\\a.txt', 'a');
      write('$root\\sub\\locked.txt', 'locked');
      write('$root\\z.txt', 'z');

      final held = using((arena) {
        final Win32Result(value: handle) = CreateFile(
          arena.pcwstr('$root\\sub\\locked.txt'),
          0x80000000,
          FILE_SHARE_MODE(0),
          null,
          OPEN_EXISTING,
          FILE_FLAGS_AND_ATTRIBUTES(0x80),
          null,
        );
        return handle;
      });
      expect(held.isValid, isTrue);
      addTearDown(() {
        if (held.isValid) held.close();
      });

      final run = await runPlan(root);

      expect(run.result, isA<PlanStopped>());
      final stopped = run.result as PlanStopped;
      expect(stopped.outcome, TransferOutcome.unreadable);
      expect(stopped.problemPath, 'sub\\locked.txt');
    }, timeout: long);
  });

  group('E412, RF-258: progress and cancellation', () {
    test('a folder of five thousand files reports progress about every '
        '250 ms and ends with the whole manifest', () async {
      final root = await scratchRoot();
      for (var folder = 0; folder < 10; folder++) {
        Directory('$root\\d$folder').createSync();
        for (var i = 0; i < 500; i++) {
          File('$root\\d$folder\\f$i.txt').writeAsStringSync('file $folder $i');
        }
      }
      final stamps = <Duration>[];
      final reports = <(int, int)>[];
      final clock = Stopwatch()..start();
      final job = startPlan(
        root,
        onProgress: (entries, hashed) {
          reports.add((entries, hashed));
          stamps.add(clock.elapsed);
        },
      );
      final result = await job.result.timeout(const Duration(seconds: 90));

      expect(result, isA<PlanReady>());
      expect((result as PlanReady).plan.manifest.files, 5000);
      expect(reports.length, greaterThan(2));
      for (var i = 1; i < reports.length; i++) {
        expect(reports[i].$1, greaterThanOrEqualTo(reports[i - 1].$1));
        expect(reports[i].$2, greaterThanOrEqualTo(reports[i - 1].$2));
      }
      expect(reports.last.$2, greaterThan(0));
      var worst = Duration.zero;
      for (var i = 1; i < stamps.length; i++) {
        final gap = stamps[i] - stamps[i - 1];
        if (gap > worst) worst = gap;
      }
      expect(worst, lessThan(const Duration(milliseconds: 1000)));
    }, timeout: long);

    test('cancel() while files are being hashed ends with PlanCancelled in '
        'under two seconds and leaves nothing open', () async {
      final root = await scratchRoot();
      for (var folder = 0; folder < 10; folder++) {
        Directory('$root\\d$folder').createSync();
        for (var i = 0; i < 500; i++) {
          File('$root\\d$folder\\f$i.txt').writeAsStringSync('file $folder $i');
        }
      }
      final started = Completer<void>();
      final job = startPlan(
        root,
        onProgress: (entries, hashed) {
          if (hashed > 0 && !started.isCompleted) started.complete();
        },
      );
      await started.future.timeout(const Duration(seconds: 60));
      final clock = Stopwatch()..start();

      job.cancel();
      final result = await job.result.timeout(const Duration(seconds: 5));

      expect(result, isA<PlanCancelled>());
      expect(clock.elapsed, lessThan(Limits.workerStopGrace));
      expect(deleteTreeNoFollowSync(root), isTrue);
      expect(Directory(root).existsSync(), isFalse);
    }, timeout: long);

    test('cancel() in the middle of a big file stops the read and frees '
        'the file', () async {
      final root = await scratchRoot();
      final big = File('$root\\big.bin').openSync(mode: FileMode.write)
        ..truncateSync(400 * 1024 * 1024)
        ..closeSync();
      expect(big.path, isNotEmpty);
      final job = startPlan(root);
      await Future<void>.delayed(const Duration(milliseconds: 150));
      final clock = Stopwatch()..start();

      job.cancel();
      final result = await job.result.timeout(const Duration(seconds: 5));

      expect(result, isA<PlanCancelled>());
      expect(clock.elapsed, lessThan(Limits.workerStopGrace));
      expect(File('$root\\big.bin').deleteSync, returnsNormally);
    }, timeout: long);

    test(
      'cancel() before the isolate has started also ends cancelled',
      () async {
        final root = await scratchRoot();
        write('$root\\a.txt', 'a');
        final job = startPlan(root);

        job.cancel();

        expect(
          await job.result.timeout(const Duration(seconds: 5)),
          isA<PlanCancelled>(),
        );
        expect((await job.excluded).partial, isTrue);
      },
      timeout: long,
    );

    test('cancel() while the excluded folders are still being measured '
        'ends the measure as partial', () async {
      final root = await scratchRoot();
      write('$root\\a.txt', 'a');
      for (var folder = 0; folder < 20; folder++) {
        for (var i = 0; i < 200; i++) {
          write('$root\\node_modules\\p$folder\\f$i.js', 'js');
        }
      }
      final job = startPlan(root, exclusions: ['node_modules']);
      final result = await job.result.timeout(const Duration(seconds: 60));
      expect(result, isA<PlanReady>());

      job.cancel();
      final measured = await job.excluded.timeout(const Duration(seconds: 5));

      expect(measured.bytes, lessThanOrEqualTo(20 * 200 * 2));
    }, timeout: long);
  });

  group('RF-259: the totals of a plan', () {
    test('totalBytes and the encoded manifest agree with the disk', () async {
      final root = await scratchRoot();
      final contents = <String, String>{
        'one.txt': 'one',
        'two\\deep.txt': 'two deep bytes',
        'two\\three\\x.bin': 'x' * 5000,
      };
      contents.forEach((path, text) => write('$root\\$path', text));

      final run = await runPlan(root);

      expect(run.plan.summary.totalBytes, 3 + 14 + 5000);
      expect(run.plan.encodedLength, encodeManifest(run.plan.manifest).length);
      expect(run.plan.encodedLength, greaterThan(0));
      expect(run.plan.rootPath, root);
    }, timeout: long);
  });
}
