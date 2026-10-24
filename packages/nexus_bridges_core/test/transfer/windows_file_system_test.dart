@TestOn('windows')
library;

import 'dart:convert';
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:nexus_bridges_core/src/protocol/protocol.dart' show Limits;
import 'package:nexus_bridges_core/src/transfer/platform.dart';
import 'package:nexus_bridges_core/src/transfer/windows_file_system.dart';
import 'package:test/test.dart';
import 'package:win32/win32.dart';

const WindowsFileSystemPlatform fs = WindowsFileSystemPlatform();

const String zoneIdentifierText = '[ZoneTransfer]\r\nZoneId=3\r\n';

const String longFileName = 'documento_largo_original.txt';

final RegExp volumeIdFormat = RegExp(r'^[A-Za-z0-9]{1,16}-[0-9a-f]{8}$');

Future<Directory> tempFolder() async {
  final dir = await Directory.systemTemp.createTemp('nexus_t2_');
  addTearDown(() async {
    if (await dir.exists()) await dir.delete(recursive: true);
  });
  return dir;
}

String join(String folder, String name) => '$folder\\$name';

Future<File> writeFile(String path, List<int> bytes) async {
  final file = File(path);
  await file.writeAsBytes(bytes, flush: true);
  return file;
}

List<String> namesIn(Directory dir) =>
    dir
        .listSync(followLinks: false)
        .map((e) => e.path.substring(e.path.lastIndexOf(r'\') + 1))
        .toList()
      ..sort();

String? shortNameOf(String path) => using((arena) {
  final buffer = arena.pwstrBuffer(1024);
  final Win32Result(:value) = GetShortPathName(
    arena.pcwstr(path),
    buffer,
    1024,
  );
  if (value == 0 || value >= 1024) return null;
  final shortPath = buffer.toDartString(length: value);
  return shortPath.substring(shortPath.lastIndexOf(r'\') + 1);
});

String? eightDotThreeAliasOf(String path) {
  final short = shortNameOf(path);
  final long = path.substring(path.lastIndexOf(r'\') + 1);
  if (short == null || short.toUpperCase() == long.toUpperCase()) return null;
  return short;
}

int attributesOf(String path) => using((arena) {
  final Win32Result(:value) = GetFileAttributes(arena.pcwstr(path));
  return value;
});

HANDLE openExclusively(String path) => using((arena) {
  final Win32Result(:value) = CreateFile(
    arena.pcwstr(path),
    GENERIC_READ,
    const FILE_SHARE_MODE(0),
    null,
    OPEN_EXISTING,
    FILE_ATTRIBUTE_NORMAL,
    null,
  );
  if (!value.isValid) throw StateError('could not lock the test file');
  return value;
});

Future<String?> volumeSerialFromVol(String path) async {
  final result = await Process.run('cmd', ['/c', 'vol', path.substring(0, 2)]);
  final match = RegExp(r'([0-9A-F]{4})-([0-9A-F]{4})')
      .firstMatch(result.stdout as String);
  if (match == null) return null;
  return '${match.group(1)}${match.group(2)}'.toLowerCase();
}

Future<int?> zoneStreamLength(String path) async {
  final result = await Process.run('powershell', [
    '-NoProfile',
    '-NonInteractive',
    '-Command',
    "(Get-Item -LiteralPath '$path' -Stream Zone.Identifier).Length",
  ]);
  return int.tryParse((result.stdout as String).trim());
}

Future<bool> enableCaseSensitivity(String path) async {
  try {
    final result = await Process.run('fsutil', [
      'file',
      'setCaseSensitiveInfo',
      path,
      'enable',
    ]);
    return result.exitCode == 0;
  } on ProcessException {
    return false;
  }
}

Future<Directory> folderOfLength(Directory base, int length) async {
  final missing = length - base.path.length - 1;
  if (missing < 1 || missing > 200) {
    throw StateError('the temp folder path does not allow length $length');
  }
  return Directory(join(base.path, 'd' * missing)).create();
}

String nameForTotal(String folder, int total) {
  const extension = '.txt';
  return 'n' * (total - folder.length - 1 - extension.length) + extension;
}

void main() {
  group('E14 volumeFacts', () {
    test(
      'a temp folder is NTFS with named streams and a stable volumeId',
      () async {
        final dir = await tempFolder();
        final file = await writeFile(join(dir.path, 'a.txt'), [1]);

        final first = await fs.volumeFacts(dir.path);
        final second = await fs.volumeFacts(dir.path);
        final ofFile = await fs.volumeFacts(file.path);

        expect(first, isNotNull);
        expect(volumeIdFormat.hasMatch(first!.volumeId), isTrue);
        expect(first.volumeId, startsWith('NTFS-'));
        expect(first.supportsNamedStreams, isTrue);
        expect(first.isRemote, isFalse);
        expect(second!.volumeId, first.volumeId);
        expect(ofFile!.volumeId, first.volumeId);
      },
    );

    test('the volumeId carries the serial number Windows reports', () async {
      final dir = await tempFolder();
      final serial = await volumeSerialFromVol(dir.path);
      if (serial == null) {
        markTestSkipped('vol did not print a serial number');
        return;
      }

      final facts = await fs.volumeFacts(dir.path);

      expect(facts!.volumeId, endsWith('-$serial'));
    });

    test('a path that does not exist gives null', () async {
      final dir = await tempFolder();

      expect(await fs.volumeFacts(join(dir.path, 'missing')), isNull);
      expect(await fs.volumeFacts(join(dir.path, r'missing\deeper')), isNull);
    });
  });

  group('E15 realPath', () {
    test(
      'a junction resolves to its target without the \\\\?\\ prefix',
      () async {
        final dir = await tempFolder();
        final target = await Directory(join(dir.path, 'target')).create();
        await writeFile(join(target.path, 'f.txt'), [1]);
        final junction = join(dir.path, 'junction');
        await Link(junction).create(target.path);
        final expected = target.resolveSymbolicLinksSync();

        final viaJunction = await fs.realPath(junction);
        final fileViaJunction = await fs.realPath(join(junction, 'f.txt'));

        expect(viaJunction, isNotNull);
        expect(viaJunction!.startsWith(r'\\?\'), isFalse);
        expect(viaJunction.toLowerCase(), expected.toLowerCase());
        expect(viaJunction, await fs.realPath(target.path));
        expect(
          fileViaJunction!.toLowerCase(),
          join(expected, 'f.txt').toLowerCase(),
        );
      },
    );

    test('a plain folder resolves to itself', () async {
      final dir = await tempFolder();
      final expected = dir.resolveSymbolicLinksSync();

      final real = await fs.realPath(dir.path);

      expect(real!.startsWith(r'\\?\'), isFalse);
      expect(real.toLowerCase(), expected.toLowerCase());
    });

    test('a path that does not exist gives null', () async {
      final dir = await tempFolder();

      expect(await fs.realPath(join(dir.path, 'missing')), isNull);
    });
  });

  group('E16 markFromInternet', () {
    test(
      'writes exactly the zone stream and leaves the content intact',
      () async {
        final dir = await tempFolder();
        final file = await writeFile(join(dir.path, 'r.bin'), [7, 8, 9]);

        final marked = await fs.markFromInternet(file.path);

        expect(marked, isTrue);
        expect(
          await File('${file.path}:Zone.Identifier').readAsBytes(),
          utf8.encode(zoneIdentifierText),
        );
        expect(
          await zoneStreamLength(file.path),
          utf8.encode(zoneIdentifierText).length,
        );
        expect(await file.readAsBytes(), [7, 8, 9]);
        expect(namesIn(dir), ['r.bin']);
      },
    );

    test('marking twice keeps the exact same stream', () async {
      final dir = await tempFolder();
      final file = await writeFile(join(dir.path, 'r.bin'), [1]);

      expect(await fs.markFromInternet(file.path), isTrue);
      expect(await fs.markFromInternet(file.path), isTrue);

      expect(
        await File('${file.path}:Zone.Identifier').readAsString(),
        zoneIdentifierText,
      );
    });

    test(
      'a file that does not exist gives false and creates nothing',
      () async {
        final dir = await tempFolder();
        final missing = join(dir.path, 'missing.bin');

        expect(await fs.markFromInternet(missing), isFalse);

        expect(await File(missing).exists(), isFalse);
        expect(namesIn(dir), isEmpty);
      },
    );
  });

  group('E17 moveNoReplace', () {
    test('to a free name it moves', () async {
      final dir = await tempFolder();
      final from = await writeFile(join(dir.path, 'src.bin'), [1, 2, 3]);
      final to = join(dir.path, 'free.bin');

      expect(await fs.moveNoReplace(from.path, to), MoveOutcome.moved);

      expect(await from.exists(), isFalse);
      expect(await File(to).readAsBytes(), [1, 2, 3]);
    });

    test(
      'onto an existing file it gives nameTaken and both stay intact',
      () async {
        final dir = await tempFolder();
        final from = await writeFile(join(dir.path, 'src.bin'), [1, 2, 3]);
        final existing = await writeFile(join(dir.path, 'same.bin'), [9, 9]);

        expect(
          await fs.moveNoReplace(from.path, existing.path),
          MoveOutcome.nameTaken,
        );

        expect(await existing.readAsBytes(), [9, 9]);
        expect(await from.readAsBytes(), [1, 2, 3]);
      },
    );

    test('onto the same name with other case it gives nameTaken', () async {
      final dir = await tempFolder();
      final from = await writeFile(join(dir.path, 'src.bin'), [1]);
      final existing = await writeFile(join(dir.path, 'Informe.txt'), [5]);

      expect(
        await fs.moveNoReplace(from.path, join(dir.path, 'INFORME.TXT')),
        MoveOutcome.nameTaken,
      );

      expect(await existing.readAsBytes(), [5]);
      expect(namesIn(dir), ['Informe.txt', 'src.bin']);
    });

    test(
      'onto the 8.3 short name of another file it gives nameTaken',
      () async {
        final dir = await tempFolder();
        final existing = await writeFile(join(dir.path, longFileName), [4, 4]);
        final alias = eightDotThreeAliasOf(existing.path);
        if (alias == null) {
          markTestSkipped('the temp volume does not create 8.3 short names');
          return;
        }
        final from = await writeFile(join(dir.path, 'src.bin'), [1]);

        expect(
          await fs.moveNoReplace(from.path, join(dir.path, alias)),
          MoveOutcome.nameTaken,
        );

        expect(await existing.readAsBytes(), [4, 4]);
        expect(await from.exists(), isTrue);
      },
    );

    test('onto a folder with that name it gives nameTaken', () async {
      final dir = await tempFolder();
      final folder = await Directory(join(dir.path, 'taken')).create();
      final from = await writeFile(join(dir.path, 'src.bin'), [1]);

      expect(
        await fs.moveNoReplace(from.path, folder.path),
        MoveOutcome.nameTaken,
      );

      expect(await folder.list().isEmpty, isTrue);
      expect(await from.exists(), isTrue);
    });

    test('from a source that does not exist it gives failed', () async {
      final dir = await tempFolder();

      expect(
        await fs.moveNoReplace(
          join(dir.path, 'missing.bin'),
          join(dir.path, 'to.bin'),
        ),
        MoveOutcome.failed,
      );
      expect(namesIn(dir), isEmpty);
    });

    test('a source locked for the whole retry window gives failed', () async {
      final dir = await tempFolder();
      final from = await writeFile(join(dir.path, 'src.bin'), [1]);
      final to = join(dir.path, 'to.bin');
      final handle = openExclusively(from.path);
      addTearDown(handle.close);
      final watch = Stopwatch()..start();

      final outcome = await fs.moveNoReplace(from.path, to);

      watch.stop();
      expect(outcome, MoveOutcome.failed);
      expect(
        watch.elapsed,
        greaterThanOrEqualTo(const Duration(milliseconds: 600)),
      );
      expect(await File(to).exists(), isFalse);
    });

    test('a source unlocked during the retries is moved', () async {
      final dir = await tempFolder();
      final from = await writeFile(join(dir.path, 'src.bin'), [6]);
      final to = join(dir.path, 'to.bin');
      final handle = openExclusively(from.path);
      var closed = false;
      addTearDown(() {
        if (!closed) handle.close();
      });

      final move = fs.moveNoReplace(from.path, to);
      await Future<void>.delayed(const Duration(milliseconds: 60));
      handle.close();
      closed = true;

      expect(await move, MoveOutcome.moved);
      expect(await File(to).readAsBytes(), [6]);
    });
  });

  group('E17 moveToFreeName', () {
    test('in an empty folder it keeps the name', () async {
      final dir = await tempFolder();
      final source = await tempFolder();
      final from = await writeFile(join(source.path, 'tmp.part'), [1, 2]);

      final result = await fs.moveToFreeName(
        from.path,
        dir.path,
        'informe.pdf',
      );

      expect(result, isA<MovedTo>());
      expect((result as MovedTo).finalName, 'informe.pdf');
      expect(await File(join(dir.path, 'informe.pdf')).readAsBytes(), [1, 2]);
      expect(await from.exists(), isFalse);
    });

    test('with the name taken it uses (1) and leaves the old file', () async {
      final dir = await tempFolder();
      final source = await tempFolder();
      final existing = await writeFile(join(dir.path, 'informe.pdf'), [9]);
      final from = await writeFile(join(source.path, 'tmp.part'), [1]);

      final result = await fs.moveToFreeName(
        from.path,
        dir.path,
        'informe.pdf',
      );

      expect((result as MovedTo).finalName, 'informe (1).pdf');
      expect(await existing.readAsBytes(), [9]);
      expect(await File(join(dir.path, 'informe (1).pdf')).readAsBytes(), [1]);
    });

    test('with (0) and (1) taken it uses (2)', () async {
      final dir = await tempFolder();
      final source = await tempFolder();
      await writeFile(join(dir.path, 'informe.pdf'), [9]);
      await writeFile(join(dir.path, 'informe (1).pdf'), [8]);
      final from = await writeFile(join(source.path, 'tmp.part'), [1]);

      final result = await fs.moveToFreeName(
        from.path,
        dir.path,
        'informe.pdf',
      );

      expect((result as MovedTo).finalName, 'informe (2).pdf');
      expect(namesIn(dir), [
        'informe (1).pdf',
        'informe (2).pdf',
        'informe.pdf',
      ]);
    });

    test('A.TXT with a.txt present becomes A (1).TXT', () async {
      final dir = await tempFolder();
      final source = await tempFolder();
      final existing = await writeFile(join(dir.path, 'a.txt'), [3]);
      final from = await writeFile(join(source.path, 'tmp.part'), [1]);

      final result = await fs.moveToFreeName(from.path, dir.path, 'A.TXT');

      expect((result as MovedTo).finalName, 'A (1).TXT');
      expect(await existing.readAsBytes(), [3]);
    });

    test('a folder with the name counts as taken', () async {
      final dir = await tempFolder();
      final source = await tempFolder();
      await Directory(join(dir.path, 'informe.pdf')).create();
      final from = await writeFile(join(source.path, 'tmp.part'), [1]);

      final result = await fs.moveToFreeName(
        from.path,
        dir.path,
        'informe.pdf',
      );

      expect((result as MovedTo).finalName, 'informe (1).pdf');
    });

    test('the 8.3 short name of another file counts as taken', () async {
      final dir = await tempFolder();
      final source = await tempFolder();
      final existing = await writeFile(join(dir.path, longFileName), [4]);
      final alias = eightDotThreeAliasOf(existing.path);
      if (alias == null) {
        markTestSkipped('the temp volume does not create 8.3 short names');
        return;
      }
      final from = await writeFile(join(source.path, 'tmp.part'), [1]);
      final dot = alias.lastIndexOf('.');
      final expected = dot > 0
          ? '${alias.substring(0, dot)} (1)${alias.substring(dot)}'
          : '$alias (1)';

      final result = await fs.moveToFreeName(from.path, dir.path, alias);

      expect((result as MovedTo).finalName, expected);
      expect(await existing.readAsBytes(), [4]);
    });

    test('a final path of exactly 259 characters is moved', () async {
      final base = await tempFolder();
      final source = await tempFolder();
      final dir = await folderOfLength(base, 120);
      final name = nameForTotal(dir.path, Limits.maxFinalPathChars);
      final from = await writeFile(join(source.path, 'tmp.part'), [1]);

      final result = await fs.moveToFreeName(from.path, dir.path, name);

      expect((result as MovedTo).finalName, name);
      expect(join(dir.path, name).length, Limits.maxFinalPathChars);
      expect(await File(join(dir.path, name)).readAsBytes(), [1]);
    });

    test('a final path of 260 characters gives MoveFailed', () async {
      final base = await tempFolder();
      final source = await tempFolder();
      final dir = await folderOfLength(base, 120);
      final name = nameForTotal(dir.path, Limits.maxFinalPathChars + 1);
      final from = await writeFile(join(source.path, 'tmp.part'), [1]);

      final result = await fs.moveToFreeName(from.path, dir.path, name);

      expect(result, isA<MoveFailed>());
      expect(await from.readAsBytes(), [1]);
      expect(namesIn(dir), isEmpty);
    });

    test('when " (1)" pushes the path past 259 it gives MoveFailed', () async {
      final base = await tempFolder();
      final source = await tempFolder();
      final dir = await folderOfLength(base, 120);
      final name = nameForTotal(dir.path, Limits.maxFinalPathChars);
      final existing = await writeFile(join(dir.path, name), [9]);
      final from = await writeFile(join(source.path, 'tmp.part'), [1]);

      final result = await fs.moveToFreeName(from.path, dir.path, name);

      expect(result, isA<MoveFailed>());
      expect(await existing.readAsBytes(), [9]);
      expect(await from.readAsBytes(), [1]);
      expect(namesIn(dir), [name]);
    });

    test('a source that does not exist gives MoveFailed', () async {
      final dir = await tempFolder();

      final result = await fs.moveToFreeName(
        join(dir.path, 'missing.part'),
        dir.path,
        'informe.pdf',
      );

      expect(result, isA<MoveFailed>());
      expect(namesIn(dir), isEmpty);
    });

    test('a folder that does not exist gives MoveFailed', () async {
      final dir = await tempFolder();
      final from = await writeFile(join(dir.path, 'tmp.part'), [1]);

      final result = await fs.moveToFreeName(
        from.path,
        join(dir.path, 'missing'),
        'informe.pdf',
      );

      expect(result, isA<MoveFailed>());
      expect(await from.readAsBytes(), [1]);
    });

    test(
      'with every name up to (9999) taken it gives NoFreeName',
      () async {
        final dir = await tempFolder();
        final source = await tempFolder();
        for (var n = 0; n <= 9999; n++) {
          final name = n == 0 ? 'x.txt' : 'x ($n).txt';
          File(join(dir.path, name)).createSync();
        }
        final from = await writeFile(join(source.path, 'tmp.part'), [1]);

        final result = await fs.moveToFreeName(from.path, dir.path, 'x.txt');

        expect(result, isA<NoFreeName>());
        expect(await from.readAsBytes(), [1]);
        expect(dir.listSync().length, 10000);
      },
      tags: 'slow',
      timeout: const Timeout(Duration(minutes: 5)),
    );
  });

  group('E156 case sensitive folder', () {
    test(
      'INFORME.PDF next to informe.pdf is saved as INFORME (1).PDF',
      () async {
        final base = await tempFolder();
        final source = await tempFolder();
        final dir = await Directory(join(base.path, 'cs')).create();
        if (!await enableCaseSensitivity(dir.path)) {
          markTestSkipped(
            'case sensitivity could not be enabled on the folder',
          );
          return;
        }
        final existing = await writeFile(join(dir.path, 'informe.pdf'), [9]);
        final from = await writeFile(join(source.path, 'tmp.part'), [1]);

        final result = await fs.moveToFreeName(
          from.path,
          dir.path,
          'INFORME.PDF',
        );

        expect((result as MovedTo).finalName, 'INFORME (1).PDF');
        expect(await existing.readAsBytes(), [9]);
        expect(namesIn(dir), ['INFORME (1).PDF', 'informe.pdf']);
      },
    );
  });

  group('E18 cloud and system folders', () {
    test('a temp folder is not cloud synced', () async {
      final dir = await tempFolder();

      expect(await fs.isCloudSynced(dir.path), isFalse);
      expect(await fs.isCloudSynced(join(dir.path, 'missing')), isFalse);
    });

    test('systemFolders gives existing Windows folders', () async {
      final folders = await fs.systemFolders();

      for (final path in [
        folders.windows,
        folders.programFiles,
        folders.startup,
        folders.downloads,
      ]) {
        expect(path, isNotNull);
        expect(Directory(path!).existsSync(), isTrue, reason: path);
      }
      expect(folders.systemDriveRoot, folders.windows!.substring(0, 3));
    });
  });

  group('E19 setHidden', () {
    test('a folder gets the hidden attribute and keeps the others', () async {
      final base = await tempFolder();
      final dir = await Directory(join(base.path, 'h')).create();
      final file = await writeFile(join(base.path, 'f.bin'), [1]);
      final fileBefore = attributesOf(file.path);

      expect(await fs.setHidden(dir.path), isTrue);
      expect(await fs.setHidden(file.path), isTrue);

      expect(attributesOf(dir.path) & FILE_ATTRIBUTE_HIDDEN, isNot(0));
      expect(attributesOf(dir.path) & FILE_ATTRIBUTE_DIRECTORY, isNot(0));
      expect(attributesOf(file.path), fileBefore | FILE_ATTRIBUTE_HIDDEN);
    });

    test('a path that does not exist gives false', () async {
      final dir = await tempFolder();

      expect(await fs.setHidden(join(dir.path, 'missing')), isFalse);
    });
  });

  group('E20 freeBytes', () {
    test('a temp folder has more than zero free bytes', () async {
      final dir = await tempFolder();

      final free = await fs.freeBytes(dir.path);

      expect(free, isNotNull);
      expect(free!, greaterThan(0));
    });

    test('a path that does not exist gives null', () async {
      final dir = await tempFolder();

      expect(await fs.freeBytes(join(dir.path, r'missing\deeper')), isNull);
    });
  });

  group('no method throws', () {
    test('odd paths give the failure values', () async {
      const odd = ['', ' ', '\u0000', r'\\?\', 'C:\\<>|?*'];
      for (final path in odd) {
        expect(await fs.realPath(path), isNull, reason: path);
        expect(await fs.volumeFacts(path), isNull, reason: path);
        expect(await fs.freeBytes(path), isNull, reason: path);
        expect(await fs.isCloudSynced(path), isFalse, reason: path);
        expect(await fs.setHidden(path), isFalse, reason: path);
        expect(await fs.markFromInternet(path), isFalse, reason: path);
        expect(
          await fs.moveNoReplace(path, path),
          MoveOutcome.failed,
          reason: path,
        );
      }
    });

    test('moveToFreeName with odd paths gives MoveFailed', () async {
      final dir = await tempFolder();

      expect(await fs.moveToFreeName('', dir.path, 'x.txt'), isA<MoveFailed>());
      expect(
        await fs.moveToFreeName(join(dir.path, 'missing'), '\u0000', 'x.txt'),
        isA<MoveFailed>(),
      );
      expect(namesIn(dir), isEmpty);
    });
  });

  group('E180, RF-232: AssocIsDangerous of the real Windows', () {
    for (final extension in ['.exe', '.EXE', '.pif', '.hta', '.chm']) {
      test('"$extension" is dangerous', () async {
        expect(await fs.isDangerousType(extension), isTrue);
      });
    }

    for (final extension in ['.txt', '.pdf', '.png']) {
      test('"$extension" is not dangerous', () async {
        expect(await fs.isDangerousType(extension), isFalse);
      });
    }

    test('an extension of 250 characters gives false without an '
        'exception', () async {
      final extension = '.${'x' * 249}';
      expect(extension.length, 250);

      expect(await fs.isDangerousType(extension), isFalse);
    });

    test('odd extensions answer without an exception', () async {
      for (final extension in ['', '.', '.${'y' * 40000}']) {
        expect(
          await fs.isDangerousType(extension),
          isA<bool>(),
          reason: extension.length.toString(),
        );
      }
      expect(await fs.isDangerousType('.${'y' * 40000}'), isFalse);
    });

    test('isProgramHere with the real platform: "x.chm" is a program and '
        '"x.txt" is not', () async {
      expect(await isProgramHere('x.chm', fs), isTrue);
      expect(await isProgramHere('x.txt', fs), isFalse);
    });
  });

  group('E192, RF-145, RF-214: moveToFreeName checks the name again', () {
    for (final name in [r'sub\inner.txt', 'CON.txt', 'trail.', 'x.pif']) {
      test('"$name" gives MoveFailed and creates nothing', () async {
        final dir = await tempFolder();
        final source = await tempFolder();
        final from = await writeFile(join(source.path, 'tmp.part'), [7, 8, 9]);

        final result = await fs.moveToFreeName(from.path, dir.path, name);

        expect(result, isA<MoveFailed>());
        expect(await from.readAsBytes(), [7, 8, 9]);
        expect(namesIn(source), ['tmp.part']);
        expect(namesIn(dir), isEmpty);
        expect(await Directory(join(dir.path, 'sub')).exists(), isFalse);
      });
    }

    test('a valid name next to them is still moved', () async {
      final dir = await tempFolder();
      final source = await tempFolder();
      final from = await writeFile(join(source.path, 'tmp.part'), [1]);

      final result = await fs.moveToFreeName(from.path, dir.path, 'inner.txt');

      expect((result as MovedTo).finalName, 'inner.txt');
      expect(namesIn(dir), ['inner.txt']);
    });
  });
}
