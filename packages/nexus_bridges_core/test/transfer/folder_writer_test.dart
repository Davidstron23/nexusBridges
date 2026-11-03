@TestOn('windows')
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:nexus_bridges_core/src/protocol/protocol.dart';
import 'package:nexus_bridges_core/src/transfer/folder_stream.dart';
import 'package:nexus_bridges_core/src/transfer/folder_writer.dart';
import 'package:nexus_bridges_core/src/transfer/transfer.dart';
import 'package:nexus_bridges_core/src/transfer/windows_folder_io.dart';
import 'package:nexus_bridges_core/src/winio/winio.dart';
import 'package:test/test.dart';
import 'package:win32/win32.dart';

import 'folder_writer_support.dart';

final RegExp rootName = RegExp(r'^~nexusbridges-[0-9a-f]{12}$');

int attributesOf(String path) => using((arena) {
  final Win32Result(value: attributes) = GetFileAttributes(
    arena.pcwstr(extendedPath(path)),
  );
  return attributes;
});

bool isHidden(String path) => (attributesOf(path) & 0x02) != 0;

String shortNameOf(String path) => using((arena) {
  final buffer = arena.pwstrBuffer(520);
  final Win32Result(value: length) = GetShortPathName(
    arena.pcwstr(path),
    buffer,
    520,
  );
  if (length == 0 || length >= 520) return '';
  final text = buffer.toDartString(length: length);
  return text.substring(text.lastIndexOf(r'\') + 1);
});

Set<String> everything(String root) {
  final dir = Directory(root);
  if (!dir.existsSync()) return {};
  return {
    for (final entry in dir.listSync(recursive: true, followLinks: false))
      entry.path.toUpperCase(),
  };
}

Future<({String base, String incoming, String outside})> layout() async {
  final base = await realTempFolder();
  final incoming = '$base\\incoming';
  final outside = '$base\\outside';
  Directory(incoming).createSync();
  Directory(outside).createSync();
  return (base: base, incoming: incoming, outside: outside);
}

void main() {
  group('F6 and RF-273: the writer builds a whole folder inside tempRoot', () {
    test(
      'a folder of 1 000 files, nested and with empty folders, is written '
      'with every file marked and nothing created outside tempRoot',
      () async {
        final place = await layout();
        File('${place.outside}\\keep.txt').writeAsBytesSync([1]);
        final entries = <TreeEntry>[];
        for (var d = 0; d < 20; d++) {
          entries.add(('d$d', null));
          entries.add(('d$d\\sub', null));
          for (var f = 0; f < 25; f++) {
            entries.add(('d$d\\f$f.bin', content(d * 100 + f, f * 7 + 3)));
          }
          for (var f = 0; f < 25; f++) {
            entries.add(('d$d\\sub\\g$f.bin', content(d * 100 + f + 5, f)));
          }
        }
        entries.add(('empty', null));
        entries.add(('empty\\inner', null));
        final tree = buildTree(entries);
        expect(tree.manifest.files, 1000);
        final before = everything(place.base);

        final run = await startRun(place.incoming, tree);
        final root = run.host.tempRoot;
        expect(
          root.substring(root.lastIndexOf(r'\') + 1),
          matches(rootName),
          reason: root,
        );
        expect(root.startsWith('${place.incoming}\\'), isTrue);
        expect(isHidden(root), isTrue);
        await run.feed(tree.stream);
        final result = await run.host.finish();

        expect(result, isA<FolderWritten>());
        expect(run.failures, isEmpty);
        expect(run.progress.last.$1, 1000);
        expect(run.activity, greaterThan(0));
        expect(isHidden(root), isFalse);
        var files = 0;
        for (final MapEntry(:key, :value) in tree.paths.entries) {
          final path = '$root\\$key';
          if (value == null) {
            expect(Directory(path).existsSync(), isTrue, reason: key);
          } else {
            files++;
            expect(File(path).readAsBytesSync(), value, reason: key);
            expect(readMark(path), zoneText, reason: key);
          }
        }
        expect(files, 1000);
        expect(verifyTree(root, tree.manifest.length), isTrue);
        final created = everything(place.base).difference(before);
        expect(
          created.every(
            (path) =>
                path == root.toUpperCase() ||
                path.startsWith('${root.toUpperCase()}\\'),
          ),
          isTrue,
        );
        expect(namesOf(place.outside), ['keep.txt']);
        run.host.close();
      },
    );

    test('with a volume that cannot hold the mark no file gets one', () async {
      final place = await layout();
      final tree = buildTree([
        ('a', null),
        ('a\\one.txt', content(1, 100)),
        ('two.txt', content(2, 5)),
      ]);

      final run = await startRun(place.incoming, tree, supportsMark: false);
      await run.feed(tree.stream);
      final result = await run.host.finish();
      final root = run.host.tempRoot;

      expect(result, isA<FolderWritten>());
      expect(File('$root\\a\\one.txt').readAsBytesSync(), content(1, 100));
      expect(readMark('$root\\a\\one.txt'), isEmpty);
      expect(readMark('$root\\two.txt'), isEmpty);
      run.host.close();
    });

    test('a folder with no files at all is written as empty folders', () async {
      final place = await layout();
      final tree = buildTree([('x', null), ('x\\y', null), ('z', null)]);

      final run = await startRun(place.incoming, tree);
      final result = await run.host.finish();
      final root = run.host.tempRoot;

      expect(result, isA<FolderWritten>());
      expect(Directory('$root\\x\\y').existsSync(), isTrue);
      expect(Directory('$root\\z').existsSync(), isTrue);
      run.host.close();
    });
  });

  group('Q-3 and B-4: failures of the mark and of the hidden flag', () {
    int indexOfName(WriterTree tree, String name) {
      for (var i = 1; i <= tree.manifest.length; i++) {
        if (tree.manifest.nameOf(i) == name) return i;
      }
      fail('$name is not in the manifest');
    }

    test('a mark that fails on one file is markFailed with that file, and '
        'the discard leaves nothing behind', () async {
      final place = await layout();
      final tree = buildTree([
        ('a', null),
        (r'a\one.txt', content(1, 100)),
        ('two.txt', content(2, 50)),
        ('three.txt', content(3, 10)),
      ]);
      final before = everything(place.base);

      final run = await startRun(place.incoming, tree, markFile: failMarkOfTwo);
      await run.feed(tree.stream);
      await run.waitFor(() => run.failures.isNotEmpty);
      await run.host.discard();

      expect(run.failures.single.outcome, TransferOutcome.markFailed);
      expect(run.failures.single.entry, indexOfName(tree, 'two.txt'));
      expect(Directory(run.host.tempRoot).existsSync(), isFalse);
      expect(everything(place.base), before);
    });

    test('a mark that always fails stops at the first file', () async {
      final place = await layout();
      final tree = buildTree([
        ('one.txt', content(1, 10)),
        ('two.txt', content(2, 10)),
      ]);

      final run = await startRun(place.incoming, tree, markFile: failEveryMark);
      await run.feed(tree.stream);
      await run.waitFor(() => run.failures.isNotEmpty);
      final result = await run.host.finish();
      await run.host.discard();

      expect(run.failures.first.outcome, TransferOutcome.markFailed);
      expect(run.failures.first.entry, indexOfName(tree, 'one.txt'));
      expect(result, isA<FolderWriteFailed>());
      expect(Directory(run.host.tempRoot).existsSync(), isFalse);
    });

    test('with no mark support the injected mark is never called', () async {
      final place = await layout();
      final tree = buildTree([('one.txt', content(1, 10))]);

      final run = await startRun(
        place.incoming,
        tree,
        supportsMark: false,
        markFile: failEveryMark,
      );
      await run.feed(tree.stream);
      final result = await run.host.finish();

      expect(result, isA<FolderWritten>());
      expect(run.failures, isEmpty);
      run.host.close();
    });

    test('B-4: a hidden flag that cannot be cleared is writeFailed and the '
        'discard deletes everything', () async {
      final place = await layout();
      final tree = buildTree([
        ('a', null),
        (r'a\one.txt', content(1, 100)),
        ('two.txt', content(2, 50)),
      ]);
      final before = everything(place.base);

      final run = await startRun(
        place.incoming,
        tree,
        clearHidden: failClearHidden,
      );
      await run.feed(tree.stream);
      final result = await run.host.finish();
      await run.host.discard();

      expect(result, isA<FolderWriteFailed>());
      expect(
        (result as FolderWriteFailed).outcome,
        TransferOutcome.writeFailed,
      );
      expect(Directory(run.host.tempRoot).existsSync(), isFalse);
      expect(everything(place.base), before);
    });

    test('B-4: with the default function the same folder is written and '
        'visible', () async {
      final place = await layout();
      final tree = buildTree([('one.txt', content(1, 10))]);

      final run = await startRun(place.incoming, tree);
      await run.feed(tree.stream);
      final result = await run.host.finish();

      expect(result, isA<FolderWritten>());
      expect(isHidden(run.host.tempRoot), isFalse);
      run.host.close();
    });
  });

  group('E467, RF-277 and point 14: long paths and the mark', () {
    test('a file whose final path has 259 characters is written and marked, '
        'and its mark is read back', () async {
      final place = await layout();
      final rootLength = place.incoming.length + 1 + 26;
      final folders = List.generate(3, (i) => 'f$i'.padRight(40, 'x'));
      var path = '';
      for (final name in folders) {
        path = path.isEmpty ? name : '$path\\$name';
      }
      final prefix = rootLength + 1 + path.length + 1;
      final fileName = 'n'.padRight(259 - prefix, 'y');
      final entries = <TreeEntry>[];
      var walk = '';
      for (final name in folders) {
        walk = walk.isEmpty ? name : '$walk\\$name';
        entries.add((walk, null));
      }
      entries.add(('$path\\$fileName', content(9, 4000)));
      final tree = buildTree(entries);

      final run = await startRun(place.incoming, tree);
      final file = '${run.host.tempRoot}\\$path\\$fileName';
      expect(file.length, 259);
      await run.feed(tree.stream);
      final result = await run.host.finish();

      expect(result, isA<FolderWritten>());
      expect(File(extendedPath(file)).readAsBytesSync(), content(9, 4000));
      expect(readMark(file), zoneText);
      run.host.close();
    });

    test('a tree deeper than the old path limit is written, verified and '
        'deleted whole', () async {
      final place = await layout();
      final names = List.generate(6, (i) => 'deep$i'.padRight(60, 'q'));
      final entries = <TreeEntry>[];
      var walk = '';
      for (final name in names) {
        walk = walk.isEmpty ? name : '$walk\\$name';
        entries.add((walk, null));
      }
      entries.add(('$walk\\leaf.txt', content(4, 50)));
      final tree = buildTree(entries);

      final run = await startRun(place.incoming, tree);
      final root = run.host.tempRoot;
      await run.feed(tree.stream);
      final result = await run.host.finish();

      expect(result, isA<FolderWritten>());
      final leaf = '$root\\$walk\\leaf.txt';
      expect(leaf.length, greaterThan(260));
      expect(File(extendedPath(leaf)).readAsBytesSync(), content(4, 50));
      expect(readMark(leaf), zoneText);
      expect(verifyTree(root, tree.manifest.length), isTrue);

      await run.host.discard();

      expect(Directory(extendedPath(root)).existsSync(), isFalse);
      expect(namesOf(place.incoming), isEmpty);
    });
  });

  group('E463, RF-273: creation is exclusive', () {
    test('a file that exists, also in another case or as a folder, is not '
        'created again', () async {
      final place = await layout();
      final opened = openRootSync(place.incoming);
      expect(opened, isA<NodeCreated>());
      final root = (opened as NodeCreated).handle;
      final rootFinal = finalPathOfHandle(root)!;
      addTearDown(root.close);

      final first = createFileExclusive(root, 'a.txt', rootFinal: rootFinal);
      expect(first, isA<NodeCreated>());
      (first as NodeCreated).handle.close();
      final folder = createFolderExclusive(
        root,
        'dir',
        rootFinal: rootFinal,
        existing: false,
      );
      expect(folder, isA<NodeCreated>());
      (folder as NodeCreated).handle.close();

      expect(
        createFileExclusive(root, 'a.txt', rootFinal: rootFinal),
        isA<NodeFailed>(),
      );
      expect(
        createFileExclusive(root, 'A.TXT', rootFinal: rootFinal),
        isA<NodeFailed>(),
      );
      expect(
        createFileExclusive(root, 'dir', rootFinal: rootFinal),
        isA<NodeFailed>(),
      );
      expect(
        createFolderExclusive(
          root,
          'dir',
          rootFinal: rootFinal,
          existing: false,
        ),
        isA<NodeFailed>(),
      );
      expect(
        createFolderExclusive(
          root,
          'DIR',
          rootFinal: rootFinal,
          existing: false,
        ),
        isA<NodeFailed>(),
      );
      expect(
        createFolderExclusive(
          root,
          'a.txt',
          rootFinal: rootFinal,
          existing: false,
        ),
        isA<NodeFailed>(),
      );
      expect(namesOf(place.incoming), ['a.txt', 'dir']);
    });

    test('the short 8.3 name of an existing file is a collision too', () async {
      final place = await layout();
      final opened = openRootSync(place.incoming);
      final root = (opened as NodeCreated).handle;
      final rootFinal = finalPathOfHandle(root)!;
      addTearDown(root.close);
      final long = 'a long file name.text';
      File('${place.incoming}\\$long').writeAsBytesSync([1, 2, 3]);
      final short = shortNameOf('${place.incoming}\\$long');
      if (short.isEmpty || short.toUpperCase() == long.toUpperCase()) {
        markTestSkipped('this volume does not generate 8.3 names');
        return;
      }

      expect(
        createFileExclusive(root, short, rootFinal: rootFinal),
        isA<NodeFailed>(),
      );
      expect(
        createFolderExclusive(
          root,
          short,
          rootFinal: rootFinal,
          existing: false,
        ),
        isA<NodeFailed>(),
      );
      expect(namesOf(place.incoming), [long]);
      expect(File('${place.incoming}\\$long').readAsBytesSync(), [1, 2, 3]);
    });

    test(
      'opening a folder that does not exist is a failure, not a creation',
      () async {
        final place = await layout();
        final opened = openRootSync(place.incoming);
        final root = (opened as NodeCreated).handle;
        final rootFinal = finalPathOfHandle(root)!;
        addTearDown(root.close);

        expect(
          createFolderExclusive(
            root,
            'ghost',
            rootFinal: rootFinal,
            existing: true,
          ),
          isA<NodeFailed>(),
        );
        expect(namesOf(place.incoming), isEmpty);
      },
    );

    test('the writer stops on a file that appears in tempRoot before its '
        'frame, reports its entry and deletes everything', () async {
      final place = await layout();
      final tree = buildTree([
        ('first', null),
        ('first\\one.txt', content(1, 10)),
        ('two.txt', content(2, 10)),
      ]);
      final run = await startRun(place.incoming, tree);
      File('${run.host.tempRoot}\\two.txt').writeAsBytesSync([9]);

      await run.feed(tree.stream);
      await run.waitFor(() => run.failures.isNotEmpty);
      final result = await run.host.finish();
      await run.host.discard();

      expect(run.failures.single.outcome, TransferOutcome.writeFailed);
      expect(run.failures.single.entry, tree.manifest.fileIndexes[1]);
      expect(result, isA<FolderWriteFailed>());
      expect(namesOf(place.incoming), isEmpty);
    });

    test('the writer stops on a folder that appears in tempRoot before it is '
        'created and deletes everything', () async {
      final place = await layout();
      final tree = buildTree([('d', null), ('d\\one.txt', content(1, 10))]);
      final run = await startRun(place.incoming, tree);
      Directory('${run.host.tempRoot}\\d').createSync();

      await run.feed(tree.stream);
      await run.waitFor(() => run.failures.isNotEmpty);
      await run.host.discard();

      expect(run.failures.single.outcome, TransferOutcome.writeFailed);
      expect(namesOf(place.incoming), isEmpty);
    });

    test('the disk-full status is told apart from any other failure', () {
      expect(isDiskFullError(0xC000007F), isTrue);
      expect(isDiskFullError(0xC0000035), isFalse);
      expect(isDiskFullError(0xC0000001), isFalse);
      expect(isDiskFullError(0), isFalse);
    });
  });

  group('E601, RF-273: an open folder cannot be replaced', () {
    test('while the writer holds a folder open it cannot be renamed or '
        'swapped for a junction, and nothing lands outside', () async {
      final place = await layout();
      final tree = buildTree([
        ('a', null),
        ('a\\g.txt', content(1, 20)),
        ('a\\f.txt', content(2, 40)),
      ]);
      final run = await startRun(place.incoming, tree);
      final root = run.host.tempRoot;
      await run.feed(tree.frames[0]);
      await run.waitFor(
        () => run.progress.isNotEmpty && run.progress.last.$1 >= 1,
      );
      await Future<void>.delayed(const Duration(milliseconds: 100));

      expect(
        () => Directory('$root\\a').renameSync('$root\\moved'),
        throwsA(isA<FileSystemException>()),
      );
      expect(
        () => Link('$root\\a').createSync(place.outside),
        throwsA(isA<FileSystemException>()),
      );
      expect(Directory('$root\\a').existsSync(), isTrue);
      expect(namesOf(place.outside), isEmpty);

      await run.feed(tree.frames[1]);
      final result = await run.host.finish();

      expect(result, isA<FolderWritten>());
      expect(File('$root\\a\\g.txt').readAsBytesSync(), content(1, 20));
      expect(File('$root\\a\\f.txt').readAsBytesSync(), content(2, 40));
      expect(namesOf(place.outside), isEmpty);
      run.host.close();
    });

    test('a folder opened by createFolderExclusive refuses a rename until its '
        'handle is closed', () async {
      final place = await layout();
      final opened = openRootSync(place.incoming);
      final root = (opened as NodeCreated).handle;
      final rootFinal = finalPathOfHandle(root)!;
      addTearDown(root.close);
      final made = createFolderExclusive(
        root,
        'a',
        rootFinal: rootFinal,
        existing: false,
      );
      final folder = (made as NodeCreated).handle;

      expect(
        () =>
            Directory('${place.incoming}\\a')
                .renameSync('${place.incoming}\\b'),
        throwsA(isA<FileSystemException>()),
      );
      final inside = createFileExclusive(
        folder,
        'in.txt',
        rootFinal: rootFinal,
      );
      expect(inside, isA<NodeCreated>());
      (inside as NodeCreated).handle.close();
      folder.close();

      Directory('${place.incoming}\\a').renameSync('${place.incoming}\\b');
      expect(File('${place.incoming}\\b\\in.txt').existsSync(), isTrue);
    });
  });

  group('F6: failures stop the writer and discard cleans up', () {
    test('a file with a changed byte is damaged, tells its entry and leaves '
        'nothing behind once discarded', () async {
      final place = await layout();
      final good = content(1, 300);
      final tree = buildTree([('ok.txt', good), ('bad.txt', content(2, 300))]);
      final bytes = Uint8List.fromList(tree.stream);
      bytes[bytes.length - 5] ^= 1;
      final run = await startRun(place.incoming, tree);

      await run.feed(bytes);
      await run.waitFor(() => run.failures.isNotEmpty);
      final result = await run.host.finish();
      await run.host.discard();

      expect(run.failures.single.outcome, TransferOutcome.damaged);
      expect(run.failures.single.entry, tree.manifest.fileIndexes[1]);
      expect((result as FolderWriteFailed).outcome, TransferOutcome.damaged);
      expect(namesOf(place.incoming), isEmpty);
    });

    test('frames out of order or too long are unexpected data and too many '
        'bytes', () async {
      final place = await layout();
      final tree = buildTree([
        ('a.txt', content(1, 10)),
        ('b.txt', content(2, 10)),
      ]);

      final swapped = await startRun(place.incoming, tree);
      await swapped.feed(Uint8List.fromList([...tree.frames[1]]));
      await swapped.waitFor(() => swapped.failures.isNotEmpty);
      await swapped.host.discard();
      expect(swapped.failures.single.outcome, TransferOutcome.unexpectedData);

      final long = await startRun(place.incoming, tree);
      await long.feed(encodeFrameHeader(tree.manifest.fileIndexes[0], 11));
      await long.waitFor(() => long.failures.isNotEmpty);
      await long.host.discard();
      expect(long.failures.single.outcome, TransferOutcome.tooManyBytes);

      expect(namesOf(place.incoming), isEmpty);
    });

    test('finishing before all files arrived fails and discard removes the '
        'partial folder', () async {
      final place = await layout();
      final tree = buildTree([
        ('a.txt', content(1, 10)),
        ('b.txt', content(2, 10)),
      ]);
      final run = await startRun(place.incoming, tree);
      await run.feed(Uint8List.fromList(tree.frames[0]));

      final result = await run.host.finish();
      await run.host.discard();

      expect(result, isA<FolderWriteFailed>());
      expect(namesOf(place.incoming), isEmpty);
    });

    test('discard in the middle of a file closes it and deletes the whole '
        'tree within the grace period', () async {
      final place = await layout();
      final tree = buildTree([
        ('d', null),
        ('d\\big.bin', content(1, 3000000)),
      ]);
      final run = await startRun(place.incoming, tree);
      final partial = Uint8List.sublistView(tree.stream, 0, 1500000);
      await run.feed(partial);
      await run.waitFor(() => run.progress.isNotEmpty);

      final clock = Stopwatch()..start();
      await run.host.discard();
      clock.stop();

      expect(clock.elapsed, lessThan(Limits.workerStopGrace));
      expect(namesOf(place.incoming), isEmpty);
      Directory(place.incoming).deleteSync();
      expect(Directory(place.incoming).existsSync(), isFalse);
    });

    test('discard twice is the same discard', () async {
      final place = await layout();
      final tree = buildTree([('a.txt', content(1, 10))]);
      final run = await startRun(place.incoming, tree);

      await Future.wait([run.host.discard(), run.host.discard()]);
      await run.host.discard();

      expect(namesOf(place.incoming), isEmpty);
    });

    test('a read-only file and a junction inside tempRoot do not stop the '
        'deletion and the junction target is left alone', () async {
      final place = await layout();
      final tree = buildTree([('a.txt', content(1, 10))]);
      final run = await startRun(place.incoming, tree);
      final root = run.host.tempRoot;
      File('${place.outside}\\precious.txt').writeAsBytesSync([7]);
      File('$root\\locked.txt').writeAsBytesSync([1]);
      Process.runSync('attrib', ['+R', '$root\\locked.txt']);
      Link('$root\\door').createSync(place.outside);

      await run.host.discard();

      expect(namesOf(place.incoming), isEmpty);
      expect(File('${place.outside}\\precious.txt').readAsBytesSync(), [7]);
    });
  });

  group('F6: backpressure and activity', () {
    test('add asks to pause beyond the high-water mark and onDrained resumes '
        'once the writer has caught up', () async {
      final place = await layout();
      final size = Limits.folderWriterHighWater + 1048576;
      final tree = buildTree([('big.bin', content(3, size))]);
      final run = await startRun(place.incoming, tree);
      final stream = tree.stream;

      final first = run.host.add(Uint8List.sublistView(stream, 0, size ~/ 2));
      final second = run.host.add(Uint8List.sublistView(stream, size ~/ 2));
      expect(first || second, isTrue);
      var resumed = false;
      run.host.onDrained(() => resumed = true);
      await run.waitFor(() => resumed);
      final result = await run.host.finish();

      expect(result, isA<FolderWritten>());
      expect(File('${run.host.tempRoot}\\big.bin').lengthSync(), size);
      expect(run.activity, greaterThan(0));
      run.host.close();
    });
  });
}
