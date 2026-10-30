@TestOn('windows')
library;

import 'dart:io';

import 'package:nexus_bridges_core/src/transfer/folder_walk.dart';
import 'package:nexus_bridges_core/src/transfer/windows_folder_io.dart';
import 'package:test/test.dart';

Future<Directory> scratch() async {
  final dir = await Directory.systemTemp.createTemp('nexus_list_');
  addTearDown(() async {
    for (var attempt = 0; attempt < 20; attempt++) {
      try {
        if (dir.existsSync()) await dir.delete(recursive: true);
        return;
      } on FileSystemException {
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
    }
  });
  return dir;
}

List<String> namesOf(List<RawEntry> entries) =>
    [for (final entry in entries) entry.name]..sort();

void main() {
  group('listDirectorySync on NtQueryDirectoryFile', () {
    test('an empty folder gives an empty list without dots', () async {
      final dir = await scratch();

      expect(listDirectorySync(dir.path), isEmpty);
    });

    test('files and folders come with exact names, kind and size', () async {
      final dir = await scratch();
      File('${dir.path}\\a b.txt').writeAsBytesSync(List.filled(123, 7));
      File('${dir.path}\\café ñ.bin').writeAsBytesSync([1]);
      Directory('${dir.path}\\sub').createSync();

      final entries = listDirectorySync(dir.path);

      expect(namesOf(entries), ['a b.txt', 'café ñ.bin', 'sub']);
      final byName = {for (final entry in entries) entry.name: entry};
      expect(byName['a b.txt']!.size, 123);
      expect(byName['a b.txt']!.isDirectory, isFalse);
      expect(byName['a b.txt']!.reparseTag, isNull);
      expect(byName['sub']!.isDirectory, isTrue);
    });

    test('more entries than fit in one buffer are all returned', () async {
      final dir = await scratch();
      final expected = <String>[];
      for (var i = 0; i < 2500; i++) {
        final name = 'entry-with-a-fairly-long-name-to-fill-buffers-$i.dat';
        File('${dir.path}\\$name').writeAsBytesSync(const []);
        expected.add(name);
      }

      final entries = listDirectorySync(dir.path);

      expect(entries.length, 2500);
      expect(namesOf(entries), (expected..sort()));
    }, timeout: const Timeout(Duration(seconds: 120)));

    test('only the direct children of a nested folder are listed', () async {
      final dir = await scratch();
      Directory('${dir.path}\\a\\b\\c').createSync(recursive: true);
      File('${dir.path}\\a\\b\\deep.txt').writeAsStringSync('x');
      File('${dir.path}\\a\\top.txt').writeAsStringSync('y');

      expect(namesOf(listDirectorySync(dir.path)), ['a']);
      expect(namesOf(listDirectorySync('${dir.path}\\a')), ['b', 'top.txt']);
      expect(namesOf(listDirectorySync('${dir.path}\\a\\b')), [
        'c',
        'deep.txt',
      ]);
    });

    test('a folder that does not exist fails with a typed error', () async {
      final dir = await scratch();

      expect(
        () => listDirectorySync('${dir.path}\\missing'),
        throwsA(isA<FileSystemException>()),
      );
    });

    test('a junction is listed with its reparse tag and the walk skips it '
        'without following it', () async {
      final dir = await scratch();
      final outside = await scratch();
      File('${outside.path}\\secret.txt').writeAsStringSync('outside');
      final root = '${dir.path}\\root';
      Directory(root).createSync();
      File('$root\\own.txt').writeAsStringSync('inside');
      final made = Process.runSync('cmd', [
        '/c',
        'mklink',
        '/J',
        '$root\\link',
        outside.path,
      ]);
      expect(made.exitCode, 0, reason: '${made.stdout}${made.stderr}');

      final entries = {
        for (final entry in listDirectorySync(root)) entry.name: entry,
      };

      expect(entries.keys.toSet(), {'own.txt', 'link'});
      expect(entries['link']!.reparseTag, 0xA0000003);
      expect(entries['own.txt']!.reparseTag, isNull);

      final walk = walkFolder(
        lister: const WindowsFolderLister(),
        rootPath: root,
        exclusions: const {},
        dataDirRealPath: '${dir.path}\\data',
      );
      expect(walk.stopped, isNull);
      expect(walk.linksOmitted, 1);
      final manifest = walk.builder.build();
      expect(manifest.length, 1);
      expect(manifest.nameOf(1), 'own.txt');
    });

    test('the deletion of a tree removes a junction without touching what it '
        'points to', () async {
      final dir = await scratch();
      final outside = await scratch();
      File('${outside.path}\\secret.txt').writeAsStringSync('outside');
      final root = '${dir.path}\\victim';
      Directory('$root\\sub').createSync(recursive: true);
      File('$root\\sub\\f.txt').writeAsStringSync('x');
      final made = Process.runSync('cmd', [
        '/c',
        'mklink',
        '/J',
        '$root\\link',
        outside.path,
      ]);
      expect(made.exitCode, 0);

      expect(deleteTreeNoFollowSync(root), isTrue);

      expect(Directory(root).existsSync(), isFalse);
      expect(File('${outside.path}\\secret.txt').readAsStringSync(), 'outside');
    });

    test('verifyTree counts every entry and rejects a reparse point', () async {
      final dir = await scratch();
      final outside = await scratch();
      Directory('${dir.path}\\a\\b').createSync(recursive: true);
      File('${dir.path}\\a\\b\\f.txt').writeAsStringSync('x');

      expect(verifyTree(dir.path, 3), isTrue);
      expect(verifyTree(dir.path, 2), isFalse);

      final made = Process.runSync('cmd', [
        '/c',
        'mklink',
        '/J',
        '${dir.path}\\link',
        outside.path,
      ]);
      expect(made.exitCode, 0);
      expect(verifyTree(dir.path, 4), isFalse);
    });
  });
}
