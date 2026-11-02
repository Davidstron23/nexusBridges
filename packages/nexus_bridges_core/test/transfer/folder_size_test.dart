@TestOn('windows')
library;

import 'dart:io';

import 'package:nexus_bridges_core/src/transfer/folder_size.dart';
import 'package:nexus_bridges_core/src/transfer/transfer.dart'
    show AbortSignal, defaultExclusions;
import 'package:test/test.dart';

import 'receiver_harness.dart' show realFs;

Future<String> tempRoot() async {
  final dir = await Directory.systemTemp.createTemp('nexus_size_');
  final root = (await realFs.realPath(dir.path))!;
  addTearDown(() async {
    try {
      await Directory(root).delete(recursive: true);
    } catch (_) {}
  });
  return root;
}

void put(String path, int length) {
  final file = File(path);
  file.parent.createSync(recursive: true);
  file.writeAsBytesSync(List<int>.filled(length, 1));
}

Future<void> junction(String link, String target) async {
  final result = await Process.run('cmd', ['/c', 'mklink', '/J', link, target]);
  expect(result.exitCode, 0, reason: 'mklink failed');
  addTearDown(() {
    try {
      Link(link).deleteSync();
    } catch (_) {}
  });
}

Future<int?> measure(
  String path, {
  List<String>? exclusions,
  AbortSignal? abort,
}) => measureFolderSize(
  path,
  exclusions: exclusions,
  abort: abort ?? AbortSignal(),
);

void main() {
  group('Q-4: measureFolderSize adds up the bytes of the files inside', () {
    test('it adds the files of every level', () async {
      final root = await tempRoot();
      put('$root\\a.bin', 1000);
      put('$root\\sub\\b.bin', 500);
      put('$root\\sub\\deep\\c.bin', 250);

      expect(await measure(root), 1750);
    });

    test(
      'an empty folder is 0 and a folder with only empty folders too',
      () async {
        final root = await tempRoot();
        Directory('$root\\one\\two').createSync(recursive: true);

        expect(await measure(root), 0);
      },
    );

    test('a folder that does not exist gives null', () async {
      final root = await tempRoot();

      expect(await measure('$root\\nope'), isNull);
    });

    test('a drive root gives null', () async {
      expect(await measure(r'C:\'), isNull);
    });
  });

  group('Q-4: exclusions', () {
    test('the default ones are skipped at any level without caring about '
        'letter case, and the reserved folder of the app too', () async {
      final root = await tempRoot();
      put('$root\\a.bin', 1000);
      put('$root\\Node_Modules\\x.bin', 7000);
      put('$root\\sub\\build\\y.bin', 3000);
      put('$root\\sub\\.dart_tool\\z.bin', 2000);
      put('$root\\.nexusbridges-incoming\\w.bin', 9000);
      put('$root\\sub\\keep.bin', 500);

      expect(await measure(root), 1500);
      expect(defaultExclusions, containsAll(['node_modules', 'build']));
    });

    test('a list of its own replaces the default one', () async {
      final root = await tempRoot();
      put('$root\\a.bin', 1000);
      put('$root\\sub\\b.bin', 500);
      put('$root\\node_modules\\x.bin', 7000);

      expect(await measure(root, exclusions: ['sub']), 8000);
    });

    test('an empty list excludes nothing but the reserved folder', () async {
      final root = await tempRoot();
      put('$root\\a.bin', 1000);
      put('$root\\node_modules\\x.bin', 7000);
      put('$root\\.nexusbridges-incoming\\w.bin', 9000);

      expect(await measure(root, exclusions: const []), 8000);
    });

    test('a list that is not valid falls back to the default one', () async {
      final root = await tempRoot();
      put('$root\\a.bin', 1000);
      put('$root\\node_modules\\x.bin', 7000);

      expect(await measure(root, exclusions: ['bad/name']), 1000);
      expect(
        await measure(root, exclusions: [for (var i = 0; i < 65; i++) 'n$i']),
        1000,
      );
    });

    test(
      'only folders are excluded, a file with that name is counted',
      () async {
        final root = await tempRoot();
        put('$root\\build', 123);

        expect(await measure(root), 123);
      },
    );
  });

  group('Q-4: links', () {
    test('a junction inside the folder is not followed', () async {
      final root = await tempRoot();
      final outside = await tempRoot();
      put('$root\\a.bin', 1000);
      put('$outside\\z.bin', 11000);
      await junction('$root\\jn', outside);

      expect(await measure(root), 1000);
    });

    test('E406: a chosen folder that is a junction is measured at its '
        'target, like the sender sends it', () async {
      final root = await tempRoot();
      final target = await tempRoot();
      put('$target\\z.bin', 11000);
      put('$target\\sub\\y.bin', 500);
      await junction('$root\\jn', target);

      expect(await measure('$root\\jn'), 11500);
    });

    test('a junction to a drive root gives null', () async {
      final root = await tempRoot();
      await junction('$root\\drive', r'C:\');

      expect(await measure('$root\\drive'), isNull);
    });
  });

  group('Q-4: stopping early', () {
    test(
      'an abort already raised gives null without looking at the disk',
      () async {
        final root = await tempRoot();
        put('$root\\a.bin', 1000);
        final abort = AbortSignal()..abort();

        expect(await measure(root, abort: abort), isNull);
      },
    );

    test('an abort during the walk gives null soon', () async {
      final root = await tempRoot();
      for (var d = 0; d < 200; d++) {
        for (var f = 0; f < 50; f++) {
          put('$root\\d$d\\f$f', 2);
        }
      }
      final full = Stopwatch()..start();
      expect(await measure(root), 20000);
      final fullTime = full.elapsed;

      final early = AbortSignal();
      final pendingEarly = measure(root, abort: early);
      early.abort();
      expect(await pendingEarly, isNull);

      final abort = AbortSignal();
      final watch = Stopwatch()..start();
      final pending = measure(root, abort: abort);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      abort.abort();
      final value = await pending;

      expect(value, anyOf(isNull, 20000));
      expect(
        watch.elapsed,
        lessThan(fullTime + const Duration(milliseconds: 500)),
      );
    });

    test('measuring again after an abort works', () async {
      final root = await tempRoot();
      put('$root\\a.bin', 1000);
      final abort = AbortSignal();
      final pending = measure(root, abort: abort);
      abort.abort();
      await pending;

      expect(await measure(root), 1000);
    });
  });
}
