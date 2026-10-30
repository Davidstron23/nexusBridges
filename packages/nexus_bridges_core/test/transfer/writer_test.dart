@TestOn('windows')
library;

import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:ffi/ffi.dart';
import 'package:nexus_bridges_core/src/protocol/protocol.dart' show Limits;
import 'package:nexus_bridges_core/src/transfer/folders.dart'
    show ReceiveTarget, tempFolderName;
import 'package:nexus_bridges_core/src/transfer/hashing.dart'
    show Sha256Stream, startDartSha256;
import 'package:nexus_bridges_core/src/transfer/names.dart' show candidateName;
import 'package:nexus_bridges_core/src/transfer/platform.dart';
import 'package:nexus_bridges_core/src/transfer/transfer.dart'
    show TransferOutcome;
import 'package:nexus_bridges_core/src/transfer/windows_file_system.dart';
import 'package:nexus_bridges_core/src/transfer/writer.dart';
import 'package:test/test.dart';
import 'package:win32/win32.dart';

const WindowsFileSystemPlatform windowsFs = WindowsFileSystemPlatform();

const int mib = 1048576;

const String emptySha256 =
    'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855';

const String zoneIdentifierText = '[ZoneTransfer]\r\nZoneId=3\r\n';

final RegExp tempNameFormat = RegExp(r'^~nexusbridges-[0-9a-f]{32}\.partial$');

String join(String folder, String name) =>
    folder.endsWith(r'\') ? '$folder$name' : '$folder\\$name';

String longPath(String path) => '\\\\?\\$path';

String subOf(String folder) => join(folder, tempFolderName);

Future<String> tempFolder() async {
  final dir = await Directory.systemTemp.createTemp('nexus_t4_w_');
  addTearDown(() async {
    if (await dir.exists()) await dir.delete(recursive: true);
  });
  final real = await windowsFs.realPath(dir.path);
  expect(real, isNotNull);
  return real!;
}

Future<String> folderOfLength(String base, int length) async {
  final missing = length - base.length - 1;
  if (missing < 1 || missing > 200) {
    throw StateError('the temp folder path does not allow length $length');
  }
  final dir = await Directory(join(base, 'd' * missing)).create();
  return dir.path;
}

String nameForTotal(String folder, int total) {
  const extension = '.txt';
  return 'n' * (total - folder.length - 1 - extension.length) + extension;
}

List<String> namesIn(String folder) =>
    Directory(folder)
        .listSync(followLinks: false)
        .map((e) => e.path.substring(e.path.lastIndexOf(r'\') + 1))
        .toList()
      ..sort();

Uint8List randomBytes(int length, int seed) {
  final random = Random(seed);
  final bytes = Uint8List(length);
  for (var i = 0; i < length; i++) {
    bytes[i] = random.nextInt(256);
  }
  return bytes;
}

String digestOf(List<int> bytes) => sha256.convert(bytes).toString();

int attributesOf(String path) => using((arena) {
  final Win32Result(:value) = GetFileAttributes(arena.pcwstr(path));
  return value;
});

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

ReceiveTarget targetFor(String folder, {bool supportsMark = false}) =>
    ReceiveTarget(
      path: folder,
      volumeId: 'NTFS-00000000',
      supportsMark: supportsMark,
      remote: false,
      cloud: false,
      freeBytes: null,
    );

FileSystemException osFailure(int code) =>
    FileSystemException('Write failed', null, OSError('failure', code));

Future<void> waitFor(bool Function() condition) async {
  for (var i = 0; i < 500 && !condition(); i++) {
    await Future<void>.delayed(const Duration(milliseconds: 2));
  }
  expect(condition(), isTrue);
}

final class FactsPlatform implements FileSystemPlatform {
  FactsPlatform({
    this.realPathFact,
    this.setHiddenFact,
    this.markFact,
    this.moveFact,
  });

  final Future<String?> Function(String path)? realPathFact;
  final Future<bool> Function(String path)? setHiddenFact;
  final Future<bool> Function(String filePath)? markFact;
  final Future<FreeNameMove> Function(String from, String folder, String name)?
  moveFact;
  final List<String> markCalls = [];
  final List<String> moveCalls = [];
  final List<String> hiddenCalls = [];

  @override
  Future<String?> realPath(String path) {
    final fact = realPathFact;
    return fact == null ? windowsFs.realPath(path) : fact(path);
  }

  @override
  Future<VolumeFacts?> volumeFacts(String path) => windowsFs.volumeFacts(path);

  @override
  Future<int?> freeBytes(String path) => windowsFs.freeBytes(path);

  @override
  Future<bool> isCloudSynced(String path) => windowsFs.isCloudSynced(path);

  @override
  Future<SystemFolders> systemFolders() => windowsFs.systemFolders();

  @override
  Future<bool> setHidden(String path) {
    hiddenCalls.add(path);
    final fact = setHiddenFact;
    return fact == null ? windowsFs.setHidden(path) : fact(path);
  }

  @override
  Future<MoveOutcome> moveNoReplace(String from, String to) =>
      windowsFs.moveNoReplace(from, to);

  @override
  Future<FreeNameMove> moveToFreeName(String from, String folder, String name) {
    moveCalls.add(name);
    final fact = moveFact;
    return fact == null
        ? windowsFs.moveToFreeName(from, folder, name)
        : fact(from, folder, name);
  }

  @override
  Future<FreeNameMove> moveFolderToFreeName(
    String from,
    String folder,
    String name, {
    required int maxNameUnits,
  }) => windowsFs.moveFolderToFreeName(
    from,
    folder,
    name,
    maxNameUnits: maxNameUnits,
  );

  @override
  Future<bool> markFromInternet(String filePath) {
    markCalls.add(filePath);
    final fact = markFact;
    return fact == null ? windowsFs.markFromInternet(filePath) : fact(filePath);
  }

  @override
  Future<bool> deleteTree(String path) => windowsFs.deleteTree(path);

  @override
  Future<bool> isDangerousType(String extension) =>
      windowsFs.isDangerousType(extension);
}

final class WriteProbe {
  WriteProbe({this.failWhenTotalAbove, this.failure});

  final int? failWhenTotalAbove;
  final Object? failure;
  final List<int> sizes = [];
  Completer<void>? hold;
  int active = 0;
  int maxActive = 0;
  int total = 0;

  Future<void> call(RandomAccessFile file, List<int> bytes) async {
    active++;
    maxActive = max(maxActive, active);
    sizes.add(bytes.length);
    try {
      final held = hold;
      if (held != null) await held.future;
      final limit = failWhenTotalAbove;
      if (limit != null && total + bytes.length > limit) throw failure!;
      await file.writeFrom(bytes);
      total += bytes.length;
    } finally {
      active--;
    }
  }
}

Future<void> addInChunks(
  IncomingFileWriter writer,
  Uint8List bytes,
  int chunk,
) async {
  for (var offset = 0; offset < bytes.length; offset += chunk) {
    final end = min(offset + chunk, bytes.length);
    await writer.add(Uint8List.sublistView(bytes, offset, end));
  }
}

void main() {
  group('E30 temporary file in its place', () {
    test('the temp lives in the hidden subfolder with a random name', () async {
      final folder = await tempFolder();
      final writer = await IncomingFileWriter.open(
        target: targetFor(folder),
        size: 2 * mib,
        fs: windowsFs,
      );
      addTearDown(writer.discard);

      await writer.add(randomBytes(mib + 10, 30));

      final sub = subOf(folder);
      final tempName = writer.tempPath.substring(
        writer.tempPath.lastIndexOf(r'\') + 1,
      );
      expect(writer.tempPath, join(sub, tempName));
      expect(tempNameFormat.hasMatch(tempName), isTrue, reason: tempName);
      expect(attributesOf(sub) & FILE_ATTRIBUTE_HIDDEN, isNot(0));
      expect(attributesOf(sub) & FILE_ATTRIBUTE_DIRECTORY, isNot(0));
      expect(namesIn(folder), [tempFolderName]);
      expect(namesIn(sub), [tempName]);
      expect(await File(writer.tempPath).length(), greaterThanOrEqualTo(mib));
      expect(writer.written, mib + 10);
    });

    test('two writers in the same folder get different temps', () async {
      final folder = await tempFolder();
      final first = await IncomingFileWriter.open(
        target: targetFor(folder),
        size: 1,
        fs: windowsFs,
      );
      addTearDown(first.discard);
      final second = await IncomingFileWriter.open(
        target: targetFor(folder),
        size: 1,
        fs: windowsFs,
      );
      addTearDown(second.discard);

      expect(first.tempPath, isNot(second.tempPath));
      expect(namesIn(subOf(folder)).length, 2);
    });

    test('an existing subfolder is reused and its files are kept', () async {
      final folder = await tempFolder();
      final sub = subOf(folder);
      await Directory(sub).create();
      final other = File(join(sub, '~nexusbridges-${'a' * 32}.partial'));
      await other.writeAsBytes(const [1, 2, 3], flush: true);

      final writer = await IncomingFileWriter.open(
        target: targetFor(folder),
        size: 4,
        fs: windowsFs,
      );
      await writer.add(Uint8List.fromList(const [9, 9, 9, 9]));
      await writer.discard();

      expect(await other.readAsBytes(), const [1, 2, 3]);
      expect(namesIn(sub), ['~nexusbridges-${'a' * 32}.partial']);
      expect(namesIn(folder), [tempFolderName]);
    });

    test('a file in place of the subfolder makes open throw', () async {
      final folder = await tempFolder();
      final blocker = File(subOf(folder));
      await blocker.writeAsBytes(const [5], flush: true);

      Object? error;
      try {
        await IncomingFileWriter.open(
          target: targetFor(folder),
          size: 1,
          fs: windowsFs,
        );
      } catch (e) {
        error = e;
      }

      expect(error, isA<FileSystemException>());
      expect((error as FileSystemException).path, anyOf(isNull, isEmpty));
      expect(error.toString(), isNot(contains(folder)));
      expect(await blocker.readAsBytes(), const [5]);
      expect(namesIn(folder), [tempFolderName]);
    });

    test(
      'a junction in place of the subfolder writes nothing through it',
      () async {
        final folder = await tempFolder();
        final elsewhere = await tempFolder();
        await Link(subOf(folder)).create(elsewhere);

        Object? error;
        try {
          await IncomingFileWriter.open(
            target: targetFor(folder),
            size: 1,
            fs: windowsFs,
          );
        } catch (e) {
          error = e;
        }

        expect(error, isA<FileSystemException>());
        expect((error as FileSystemException).path, anyOf(isNull, isEmpty));
        expect(error.toString(), isNot(contains(folder)));
        expect(namesIn(elsewhere), isEmpty);
        await Link(subOf(folder)).delete();
      },
    );

    test('a subfolder whose real path is elsewhere makes open throw and '
        'removes what it created', () async {
      final folder = await tempFolder();
      final elsewhere = await tempFolder();
      final fs = FactsPlatform(
        realPathFact: (path) async => join(elsewhere, tempFolderName),
      );

      Object? error;
      try {
        await IncomingFileWriter.open(
          target: targetFor(folder),
          size: 1,
          fs: fs,
        );
      } catch (e) {
        error = e;
      }

      expect(error, isA<FileSystemException>());
      expect((error as FileSystemException).path, anyOf(isNull, isEmpty));
      expect(error.toString(), isNot(contains(folder)));
      expect(namesIn(folder), isEmpty);
      expect(namesIn(elsewhere), isEmpty);
    });

    test('a real path Windows cannot give makes open throw', () async {
      final folder = await tempFolder();
      final fs = FactsPlatform(realPathFact: (path) async => null);

      await expectLater(
        IncomingFileWriter.open(target: targetFor(folder), size: 1, fs: fs),
        throwsA(isA<FileSystemException>()),
      );
      expect(namesIn(folder), isEmpty);
    });

    test('a real path that differs only in case is accepted', () async {
      final folder = await tempFolder();
      final fs = FactsPlatform(
        realPathFact: (path) async =>
            (await windowsFs.realPath(path))?.toUpperCase(),
      );

      final writer = await IncomingFileWriter.open(
        target: targetFor(folder),
        size: 1,
        fs: fs,
      );
      addTearDown(writer.discard);

      expect(await File(writer.tempPath).exists(), isTrue);
    });

    test('setHidden that fails or throws is ignored', () async {
      for (final fact in <Future<bool> Function(String)>[
        (path) async => false,
        (path) async => throw const FileSystemException('hidden'),
      ]) {
        final folder = await tempFolder();
        final fs = FactsPlatform(setHiddenFact: fact);

        final writer = await IncomingFileWriter.open(
          target: targetFor(folder),
          size: 2,
          fs: fs,
        );
        await writer.add(Uint8List.fromList(const [1, 2]));
        final result = await writer.finish(
          name: 'h.bin',
          expectedSha256: digestOf(const [1, 2]),
        );

        expect(fs.hiddenCalls, [subOf(folder)]);
        expect(result, isA<WriteSaved>());
        expect(namesIn(folder), ['h.bin']);
      }
    });
  });

  group('E31 saved', () {
    test(
      'the right digest saves the file with its name and no leftovers',
      () async {
        final folder = await tempFolder();
        final bytes = randomBytes(2 * mib + 12345, 31);
        final probe = WriteProbe();
        final writer = await IncomingFileWriter.open(
          target: targetFor(folder),
          size: bytes.length,
          fs: windowsFs,
          writeBytes: probe.call,
        );

        await addInChunks(writer, bytes, 50000);
        final result = await writer.finish(
          name: 'informe.pdf',
          expectedSha256: digestOf(bytes),
        );

        expect(result, isA<WriteSaved>());
        final saved = result as WriteSaved;
        expect(saved.finalName, 'informe.pdf');
        expect(saved.finalPath, join(folder, 'informe.pdf'));
        expect(saved.marked, isFalse);
        expect(await File(saved.finalPath).readAsBytes(), bytes);
        expect(namesIn(folder), ['informe.pdf']);
        expect(await File(writer.tempPath).exists(), isFalse);
        expect(probe.total, bytes.length);
        for (final size in probe.sizes.take(probe.sizes.length - 1)) {
          expect(size, greaterThanOrEqualTo(mib));
        }
        expect(probe.maxActive, 1);
      },
    );

    test('the subfolder stays when it holds another temp', () async {
      final folder = await tempFolder();
      final sub = subOf(folder);
      await Directory(sub).create();
      final other = File(join(sub, '~nexusbridges-${'b' * 32}.partial'));
      await other.writeAsBytes(const [7], flush: true);
      final writer = await IncomingFileWriter.open(
        target: targetFor(folder),
        size: 1,
        fs: windowsFs,
      );

      await writer.add(Uint8List.fromList(const [3]));
      final result = await writer.finish(
        name: 'x.txt',
        expectedSha256: digestOf(const [3]),
      );

      expect(result, isA<WriteSaved>());
      expect(namesIn(folder), [tempFolderName, 'x.txt']);
      expect(await other.readAsBytes(), const [7]);
    });

    test('discard after saving leaves the saved file alone', () async {
      final folder = await tempFolder();
      final writer = await IncomingFileWriter.open(
        target: targetFor(folder),
        size: 3,
        fs: windowsFs,
      );
      await writer.add(Uint8List.fromList(const [1, 2, 3]));
      final result = await writer.finish(
        name: 'keep.bin',
        expectedSha256: digestOf(const [1, 2, 3]),
      );

      await writer.discard();
      await writer.discard();

      expect(result, isA<WriteSaved>());
      expect(await File(join(folder, 'keep.bin')).readAsBytes(), const [
        1,
        2,
        3,
      ]);
      expect(namesIn(folder), ['keep.bin']);
    });

    test(
      'a second finish gives writeFailed and keeps the saved file',
      () async {
        final folder = await tempFolder();
        final writer = await IncomingFileWriter.open(
          target: targetFor(folder),
          size: 1,
          fs: windowsFs,
        );
        await writer.add(Uint8List.fromList(const [8]));
        await writer.finish(name: 'once.bin', expectedSha256: digestOf([8]));

        final again = await writer.finish(
          name: 'once.bin',
          expectedSha256: digestOf([8]),
        );

        expect(again, isA<WriteFailed>());
        expect((again as WriteFailed).outcome, TransferOutcome.writeFailed);
        expect(await File(join(folder, 'once.bin')).readAsBytes(), const [8]);
        expect(namesIn(folder), ['once.bin']);
      },
    );
  });

  group('E32 damaged', () {
    test('a digest that does not match deletes everything', () async {
      final folder = await tempFolder();
      final bytes = randomBytes(mib + 500, 32);
      final fs = FactsPlatform();
      final writer = await IncomingFileWriter.open(
        target: targetFor(folder, supportsMark: true),
        size: bytes.length,
        fs: fs,
      );

      await addInChunks(writer, bytes, 65536);
      final result = await writer.finish(
        name: 'informe.pdf',
        expectedSha256: digestOf([...bytes.take(10)]),
      );

      expect(result, isA<WriteFailed>());
      expect((result as WriteFailed).outcome, TransferOutcome.damaged);
      expect(namesIn(folder), isEmpty);
      expect(await File(writer.tempPath).exists(), isFalse);
      expect(fs.markCalls, isEmpty);
      expect(fs.moveCalls, isEmpty);
    });

    test('a single changed byte is caught', () async {
      final folder = await tempFolder();
      final bytes = randomBytes(1000, 33);
      final changed = Uint8List.fromList(bytes)..[500] ^= 1;
      final writer = await IncomingFileWriter.open(
        target: targetFor(folder),
        size: bytes.length,
        fs: windowsFs,
      );

      await writer.add(changed);
      final result = await writer.finish(
        name: 'a.bin',
        expectedSha256: digestOf(bytes),
      );

      expect((result as WriteFailed).outcome, TransferOutcome.damaged);
      expect(namesIn(folder), isEmpty);
    });
  });

  group('E33 more bytes than announced', () {
    test('the chunk that passes the size is not written', () async {
      final folder = await tempFolder();
      final probe = WriteProbe();
      final writer = await IncomingFileWriter.open(
        target: targetFor(folder),
        size: mib,
        fs: windowsFs,
        writeBytes: probe.call,
      );
      final first = randomBytes(mib - 1, 34);

      await writer.add(first);
      await expectLater(
        writer.add(Uint8List.fromList(const [1, 2])),
        throwsA(isA<TooManyBytesException>()),
      );

      expect(writer.written, mib - 1);
      expect(probe.sizes, isEmpty);
      await writer.discard();
      expect(namesIn(folder), isEmpty);
    });

    test('the rejected chunk is left out of the file and the digest', () async {
      final folder = await tempFolder();
      final writer = await IncomingFileWriter.open(
        target: targetFor(folder),
        size: 10,
        fs: windowsFs,
      );
      final first = Uint8List.fromList(List<int>.generate(6, (i) => i));

      await writer.add(first);
      await expectLater(
        writer.add(Uint8List.fromList(List<int>.filled(5, 0xEE))),
        throwsA(isA<TooManyBytesException>()),
      );
      await writer.add(Uint8List.fromList(const [6, 7, 8, 9]));
      final result = await writer.finish(
        name: 'ten.bin',
        expectedSha256: digestOf(List<int>.generate(10, (i) => i)),
      );

      expect(result, isA<WriteSaved>());
      expect(
        await File(join(folder, 'ten.bin')).readAsBytes(),
        List<int>.generate(10, (i) => i),
      );
    });

    test('exactly the announced size is accepted', () async {
      final folder = await tempFolder();
      final writer = await IncomingFileWriter.open(
        target: targetFor(folder),
        size: 3,
        fs: windowsFs,
      );
      addTearDown(writer.discard);

      await writer.add(Uint8List.fromList(const [1, 2, 3]));
      await writer.add(Uint8List(0));

      expect(writer.written, 3);
      await expectLater(
        writer.add(Uint8List.fromList(const [4])),
        throwsA(isA<TooManyBytesException>()),
      );
    });

    test('discard after too many bytes deletes the temp', () async {
      final folder = await tempFolder();
      final writer = await IncomingFileWriter.open(
        target: targetFor(folder),
        size: 2 * mib,
        fs: windowsFs,
      );

      await writer.add(randomBytes(mib + 1, 35));
      await expectLater(
        writer.add(randomBytes(mib, 36)),
        throwsA(isA<TooManyBytesException>()),
      );
      await writer.discard();

      expect(await File(writer.tempPath).exists(), isFalse);
      expect(namesIn(folder), isEmpty);
    });
  });

  group('E34 write errors and full disk', () {
    test(
      'a write error past 1 MiB leaves add as FileSystemException',
      () async {
        final folder = await tempFolder();
        final probe = WriteProbe(
          failWhenTotalAbove: mib,
          failure: osFailure(5),
        );
        final writer = await IncomingFileWriter.open(
          target: targetFor(folder),
          size: 3 * mib,
          fs: windowsFs,
          writeBytes: probe.call,
        );

        await writer.add(randomBytes(mib, 40));
        Object? error;
        try {
          await writer.add(randomBytes(mib, 41));
        } catch (e) {
          error = e;
        }

        expect(error, isA<FileSystemException>());
        expect(error, isNot(isA<DiskFullException>()));
        await writer.discard();
        expect(await File(writer.tempPath).exists(), isFalse);
        expect(namesIn(folder), isEmpty);
      },
    );

    for (final code in [112, 39]) {
      test('error $code leaves add as DiskFullException', () async {
        final folder = await tempFolder();
        final probe = WriteProbe(
          failWhenTotalAbove: mib,
          failure: osFailure(code),
        );
        final writer = await IncomingFileWriter.open(
          target: targetFor(folder),
          size: 3 * mib,
          fs: windowsFs,
          writeBytes: probe.call,
        );

        await writer.add(randomBytes(mib, 42));
        await expectLater(
          writer.add(randomBytes(mib, 43)),
          throwsA(isA<DiskFullException>()),
        );

        await writer.discard();
        expect(await File(writer.tempPath).exists(), isFalse);
        expect(namesIn(folder), isEmpty);
      });
    }

    test(
      'a full disk while finishing gives diskFull without throwing',
      () async {
        final folder = await tempFolder();
        final probe = WriteProbe(
          failWhenTotalAbove: 0,
          failure: osFailure(112),
        );
        final writer = await IncomingFileWriter.open(
          target: targetFor(folder),
          size: 100,
          fs: windowsFs,
          writeBytes: probe.call,
        );
        final bytes = randomBytes(100, 44);

        await writer.add(bytes);
        final result = await writer.finish(
          name: 'f.bin',
          expectedSha256: digestOf(bytes),
        );

        expect((result as WriteFailed).outcome, TransferOutcome.diskFull);
        expect(namesIn(folder), isEmpty);
      },
    );

    test('a write error while finishing gives writeFailed', () async {
      for (final failure in <Object>[osFailure(5), StateError('broken')]) {
        final folder = await tempFolder();
        final probe = WriteProbe(failWhenTotalAbove: 0, failure: failure);
        final writer = await IncomingFileWriter.open(
          target: targetFor(folder),
          size: 100,
          fs: windowsFs,
          writeBytes: probe.call,
        );
        final bytes = randomBytes(100, 45);

        await writer.add(bytes);
        final result = await writer.finish(
          name: 'f.bin',
          expectedSha256: digestOf(bytes),
        );

        expect((result as WriteFailed).outcome, TransferOutcome.writeFailed);
        expect(namesIn(folder), isEmpty);
      }
    });

    test('a flush or close that fails gives writeFailed', () async {
      final folder = await tempFolder();
      final writer = await IncomingFileWriter.open(
        target: targetFor(folder),
        size: 10,
        fs: windowsFs,
        writeBytes: (file, bytes) async {
          await file.writeFrom(bytes);
          await file.close();
        },
      );
      final bytes = randomBytes(10, 46);

      await writer.add(bytes);
      final result = await writer.finish(
        name: 'f.bin',
        expectedSha256: digestOf(bytes),
      );

      expect((result as WriteFailed).outcome, TransferOutcome.writeFailed);
      expect(namesIn(folder), isEmpty);
    });
  });

  group('E35 mark of the web', () {
    test(
      'a drive with streams gets the Zone.Identifier on the final file',
      () async {
        final folder = await tempFolder();
        final bytes = randomBytes(300, 50);
        final writer = await IncomingFileWriter.open(
          target: targetFor(folder, supportsMark: true),
          size: bytes.length,
          fs: windowsFs,
        );

        await writer.add(bytes);
        final result = await writer.finish(
          name: 'web.zip',
          expectedSha256: digestOf(bytes),
        );

        expect(result, isA<WriteSaved>());
        expect((result as WriteSaved).marked, isTrue);
        expect(
          await File('${result.finalPath}:Zone.Identifier').readAsString(),
          zoneIdentifierText,
        );
        expect(await File(result.finalPath).readAsBytes(), bytes);
        expect(namesIn(folder), ['web.zip']);
      },
    );

    test(
      'a mark that cannot be set gives markFailed and leaves nothing',
      () async {
        for (final fact in <Future<bool> Function(String)>[
          (path) async => false,
          (path) async => throw const FileSystemException('mark'),
        ]) {
          final folder = await tempFolder();
          final fs = FactsPlatform(markFact: fact);
          final writer = await IncomingFileWriter.open(
            target: targetFor(folder, supportsMark: true),
            size: 4,
            fs: fs,
          );

          await writer.add(Uint8List.fromList(const [1, 2, 3, 4]));
          final result = await writer.finish(
            name: 'web.zip',
            expectedSha256: digestOf(const [1, 2, 3, 4]),
          );

          expect((result as WriteFailed).outcome, TransferOutcome.markFailed);
          expect(fs.markCalls, [writer.tempPath]);
          expect(fs.moveCalls, isEmpty);
          expect(namesIn(folder), isEmpty);
        }
      },
    );

    test('a drive without streams saves without marking', () async {
      final folder = await tempFolder();
      final fs = FactsPlatform();
      final writer = await IncomingFileWriter.open(
        target: targetFor(folder),
        size: 2,
        fs: fs,
      );

      await writer.add(Uint8List.fromList(const [5, 6]));
      final result = await writer.finish(
        name: 'plain.txt',
        expectedSha256: digestOf(const [5, 6]),
      );

      expect((result as WriteSaved).marked, isFalse);
      expect(fs.markCalls, isEmpty);
      expect(
        await File('${result.finalPath}:Zone.Identifier').exists(),
        isFalse,
      );
    });
  });

  group('E36 name conflicts', () {
    Future<WriteResult> receive(
      String folder,
      String name,
      List<int> bytes, {
      FileSystemPlatform fs = windowsFs,
    }) async {
      final writer = await IncomingFileWriter.open(
        target: targetFor(folder),
        size: bytes.length,
        fs: fs,
      );
      await writer.add(Uint8List.fromList(bytes));
      final result = await writer.finish(
        name: name,
        expectedSha256: digestOf(bytes),
      );
      expect(await File(writer.tempPath).exists(), isFalse);
      return result;
    }

    test(
      'informe.pdf taken gives informe (1).pdf and the old one stays',
      () async {
        final folder = await tempFolder();
        final existing = File(join(folder, 'informe.pdf'));
        await existing.writeAsBytes(const [9], flush: true);

        final result = await receive(folder, 'informe.pdf', const [1]);

        expect((result as WriteSaved).finalName, 'informe (1).pdf');
        expect(result.finalPath, join(folder, 'informe (1).pdf'));
        expect(await existing.readAsBytes(), const [9]);
        expect(await File(result.finalPath).readAsBytes(), const [1]);
        expect(namesIn(folder), ['informe (1).pdf', 'informe.pdf']);
      },
    );

    test('INFORME.PDF taken also counts for informe.pdf', () async {
      final folder = await tempFolder();
      final existing = File(join(folder, 'INFORME.PDF'));
      await existing.writeAsBytes(const [9], flush: true);

      final result = await receive(folder, 'informe.pdf', const [1]);

      expect((result as WriteSaved).finalName, 'informe (1).pdf');
      expect(await existing.readAsBytes(), const [9]);
      expect(namesIn(folder), ['INFORME.PDF', 'informe (1).pdf']);
    });

    test('the 8.3 short name of informe-largo.pdf counts as taken', () async {
      final folder = await tempFolder();
      final existing = File(join(folder, 'informe-largo.pdf'));
      await existing.writeAsBytes(const [4], flush: true);
      final alias = eightDotThreeAliasOf(existing.path);
      if (alias == null) {
        markTestSkipped('the temp volume does not create 8.3 short names');
        return;
      }
      final dot = alias.lastIndexOf('.');

      final result = await receive(folder, alias, const [1]);

      expect(
        (result as WriteSaved).finalName,
        '${alias.substring(0, dot)} (1)${alias.substring(dot)}',
      );
      expect(await existing.readAsBytes(), const [4]);
    });

    test('no free name gives noFreeName and leaves no temp', () async {
      final folder = await tempFolder();
      final fs = FactsPlatform(
        moveFact: (from, folder, name) async => const NoFreeName(),
      );

      final result = await receive(folder, 'x.txt', const [1], fs: fs);

      expect((result as WriteFailed).outcome, TransferOutcome.noFreeName);
      expect(namesIn(folder), isEmpty);
    });

    test('a taken name of 254 units is trimmed to 255 with (1)', () async {
      final folder = await tempFolder();
      final name = '${'a' * 250}.pdf';
      final existing = File(longPath(join(folder, name)));
      await existing.writeAsBytes(const [9], flush: true);
      final expectedName = '${'a' * 247} (1).pdf';
      addTearDown(() async {
        for (final path in [name, expectedName]) {
          final file = File(longPath(join(folder, path)));
          if (await file.exists()) await file.delete();
        }
      });
      final fs = FactsPlatform(
        moveFact: (from, folder, name) async {
          final candidate = candidateName(name, 1)!;
          await File(from).rename(longPath(join(folder, candidate)));
          return MovedTo(candidate);
        },
      );

      final result = await receive(folder, name, const [1], fs: fs);

      expect((result as WriteSaved).finalName, expectedName);
      expect(result.finalName.length, 255);
      expect(result.finalPath, join(folder, expectedName));
      expect(await File(longPath(result.finalPath)).readAsBytes(), const [1]);
      expect(await existing.readAsBytes(), const [9]);
      expect(fs.moveCalls, [name]);
    });

    test(
      'a folder where (1) pushes the path past 259 gives moveFailed',
      () async {
        final base = await tempFolder();
        final folder = await folderOfLength(base, 120);
        final name = nameForTotal(folder, Limits.maxFinalPathChars);
        final existing = File(join(folder, name));
        await existing.writeAsBytes(const [9], flush: true);

        final result = await receive(folder, name, const [1]);

        expect((result as WriteFailed).outcome, TransferOutcome.moveFailed);
        expect(await existing.readAsBytes(), const [9]);
        expect(namesIn(folder), [name]);
      },
    );

    test('a final path of 260 characters gives moveFailed', () async {
      final base = await tempFolder();
      final folder = await folderOfLength(base, 120);
      final name = nameForTotal(folder, Limits.maxFinalPathChars + 1);

      final result = await receive(folder, name, const [1]);

      expect((result as WriteFailed).outcome, TransferOutcome.moveFailed);
      expect(namesIn(folder), isEmpty);
    });
  });

  group('E37 cannot move', () {
    test(
      'MoveFailed or a throwing move gives moveFailed and no temp',
      () async {
        for (final fact
            in <Future<FreeNameMove> Function(String, String, String)>[
              (from, folder, name) async => const MoveFailed(),
              (from, folder, name) async => throw StateError('move'),
            ]) {
          final folder = await tempFolder();
          final fs = FactsPlatform(moveFact: fact);
          final writer = await IncomingFileWriter.open(
            target: targetFor(folder),
            size: 2,
            fs: fs,
          );

          await writer.add(Uint8List.fromList(const [1, 2]));
          final result = await writer.finish(
            name: 'm.bin',
            expectedSha256: digestOf(const [1, 2]),
          );

          expect((result as WriteFailed).outcome, TransferOutcome.moveFailed);
          expect(await File(writer.tempPath).exists(), isFalse);
          expect(namesIn(folder), isEmpty);
        }
      },
    );
  });

  group('E39 zero bytes', () {
    test('an empty file is saved and marked', () async {
      final folder = await tempFolder();
      final probe = WriteProbe();
      final writer = await IncomingFileWriter.open(
        target: targetFor(folder, supportsMark: true),
        size: 0,
        fs: windowsFs,
        writeBytes: probe.call,
      );

      final result = await writer.finish(
        name: 'vacio.txt',
        expectedSha256: emptySha256,
      );

      expect(result, isA<WriteSaved>());
      final saved = result as WriteSaved;
      expect(saved.finalName, 'vacio.txt');
      expect(saved.marked, isTrue);
      expect(await File(saved.finalPath).length(), 0);
      expect(
        await File('${saved.finalPath}:Zone.Identifier').readAsString(),
        zoneIdentifierText,
      );
      expect(namesIn(folder), ['vacio.txt']);
      expect(probe.total, 0);
    });

    test('one byte for a size of 0 is too many', () async {
      final folder = await tempFolder();
      final writer = await IncomingFileWriter.open(
        target: targetFor(folder),
        size: 0,
        fs: windowsFs,
      );

      await writer.add(Uint8List(0));
      await expectLater(
        writer.add(Uint8List.fromList(const [0])),
        throwsA(isA<TooManyBytesException>()),
      );
      await writer.discard();

      expect(namesIn(folder), isEmpty);
    });
  });

  group('E169 write and discard at the same time', () {
    test(
      'discard twice during a held write waits and leaves nothing',
      () async {
        final folder = await tempFolder();
        final probe = WriteProbe()..hold = Completer<void>();
        final writer = await IncomingFileWriter.open(
          target: targetFor(folder),
          size: 3 * mib,
          fs: windowsFs,
          writeBytes: probe.call,
        );

        final adding = writer
            .add(randomBytes(mib, 69))
            .then<Object?>((_) => null, onError: (Object e) => e);
        await waitFor(() => probe.active == 1);
        var firstDone = false;
        var secondDone = false;
        final first = writer.discard().then((_) => firstDone = true);
        final second = writer.discard().then((_) => secondDone = true);
        await Future<void>.delayed(const Duration(milliseconds: 50));

        expect(firstDone, isFalse);
        expect(secondDone, isFalse);
        expect(await File(writer.tempPath).exists(), isTrue);

        probe.hold!.complete();
        await first;
        await second;
        await adding;

        expect(probe.maxActive, 1);
        expect(await File(writer.tempPath).exists(), isFalse);
        expect(namesIn(folder), isEmpty);
      },
    );

    test('a held write that then fails still lets discard finish', () async {
      final folder = await tempFolder();
      final probe = WriteProbe()..hold = Completer<void>();
      final writer = await IncomingFileWriter.open(
        target: targetFor(folder),
        size: 3 * mib,
        fs: windowsFs,
        writeBytes: probe.call,
      );

      final adding = writer
          .add(randomBytes(mib, 70))
          .then<Object?>((_) => null, onError: (Object e) => e);
      await waitFor(() => probe.active == 1);
      final discarding = writer.discard();
      probe.hold!.completeError(osFailure(112));

      await discarding;
      expect(await adding, isA<DiskFullException>());
      expect(probe.maxActive, 1);
      expect(namesIn(folder), isEmpty);
    });

    test('two adds without waiting never write at the same time', () async {
      final folder = await tempFolder();
      final probe = WriteProbe()..hold = Completer<void>();
      final bytes = randomBytes(2 * mib, 71);
      final writer = await IncomingFileWriter.open(
        target: targetFor(folder),
        size: bytes.length,
        fs: windowsFs,
        writeBytes: probe.call,
      );

      final firstAdd = writer.add(Uint8List.sublistView(bytes, 0, mib));
      final secondAdd = writer.add(Uint8List.sublistView(bytes, mib));
      await waitFor(() => probe.active == 1);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(probe.sizes.length, 1);

      probe.hold!.complete();
      await firstAdd;
      await secondAdd;
      final result = await writer.finish(
        name: 'two.bin',
        expectedSha256: digestOf(bytes),
      );

      expect(probe.maxActive, 1);
      expect(probe.sizes, [mib, mib]);
      expect(await File((result as WriteSaved).finalPath).readAsBytes(), bytes);
    });

    test('discard during a held finish waits and leaves nothing', () async {
      final folder = await tempFolder();
      final probe = WriteProbe()..hold = Completer<void>();
      final bytes = randomBytes(1000, 72);
      final writer = await IncomingFileWriter.open(
        target: targetFor(folder),
        size: bytes.length,
        fs: windowsFs,
        writeBytes: probe.call,
      );

      await writer.add(bytes);
      final finishing = writer.finish(
        name: 'late.bin',
        expectedSha256: digestOf(bytes),
      );
      await waitFor(() => probe.active == 1);
      final discarding = writer.discard();
      probe.hold!.complete();

      await discarding;
      final result = await finishing;

      expect(probe.maxActive, 1);
      expect(result, isA<WriteFailed>());
      expect(await File(writer.tempPath).exists(), isFalse);
      expect(namesIn(folder), isEmpty);
    });
  });

  group('closed writer', () {
    test(
      'add after discard throws FileSystemException without a path',
      () async {
        final folder = await tempFolder();
        final writer = await IncomingFileWriter.open(
          target: targetFor(folder),
          size: 10,
          fs: windowsFs,
        );
        await writer.discard();

        Object? error;
        try {
          await writer.add(Uint8List.fromList(const [0x53, 0x45, 0x43]));
        } catch (e) {
          error = e;
        }

        expect(error, isA<FileSystemException>());
        expect((error as FileSystemException).path, anyOf(isNull, isEmpty));
        expect(error.toString(), isNot(contains(folder)));
        expect(error.toString(), isNot(contains('SEC')));
        expect(namesIn(folder), isEmpty);
      },
    );

    test('add after finish throws FileSystemException', () async {
      final folder = await tempFolder();
      final writer = await IncomingFileWriter.open(
        target: targetFor(folder),
        size: 1,
        fs: windowsFs,
      );
      await writer.add(Uint8List.fromList(const [1]));
      await writer.finish(name: 'a.bin', expectedSha256: digestOf(const [1]));

      await expectLater(
        writer.add(Uint8List.fromList(const [2])),
        throwsA(isA<FileSystemException>()),
      );
      expect(await File(join(folder, 'a.bin')).readAsBytes(), const [1]);
    });

    test('finish after discard gives writeFailed and saves nothing', () async {
      final folder = await tempFolder();
      final fs = FactsPlatform();
      final writer = await IncomingFileWriter.open(
        target: targetFor(folder, supportsMark: true),
        size: 1,
        fs: fs,
      );
      await writer.add(Uint8List.fromList(const [1]));
      await writer.discard();

      final result = await writer.finish(
        name: 'a.bin',
        expectedSha256: digestOf(const [1]),
      );

      expect((result as WriteFailed).outcome, TransferOutcome.writeFailed);
      expect(fs.markCalls, isEmpty);
      expect(fs.moveCalls, isEmpty);
      expect(namesIn(folder), isEmpty);
    });

    test('the error types carry no path and no content', () async {
      final folder = await tempFolder();
      for (final error in <Object>[
        const TooManyBytesException(),
        const DiskFullException(),
      ]) {
        expect(error.toString(), isNot(contains(folder)));
        expect(error.toString(), isNot(contains(r':\')));
      }
    });
  });

  group('E182, RF-170: discard while finish saves [SEG]', () {
    test('(a) discard during a held mark waits for finish, which fails and '
        'leaves nothing', () async {
      final folder = await tempFolder();
      final hold = Completer<void>();
      var markStarted = false;
      final fs = FactsPlatform(
        markFact: (path) async {
          markStarted = true;
          await hold.future;
          return windowsFs.markFromInternet(path);
        },
      );
      final bytes = randomBytes(5000, 182);
      final writer = await IncomingFileWriter.open(
        target: targetFor(folder, supportsMark: true),
        size: bytes.length,
        fs: fs,
      );
      await writer.add(bytes);
      final order = <String>[];

      final finishing = writer
          .finish(name: 'a.bin', expectedSha256: digestOf(bytes))
          .then((result) {
            order.add('finish');
            return result;
          });
      await waitFor(() => markStarted);
      final discarding = writer.discard().then((_) => order.add('discard'));
      final again = writer.discard().then((_) => order.add('again'));
      await Future<void>.delayed(const Duration(milliseconds: 50));

      expect(order, isEmpty);
      expect(await File(writer.tempPath).exists(), isTrue);

      hold.complete();
      final result = await finishing;
      await discarding;
      await again;

      expect(order.first, 'finish');
      expect(order, containsAll(['discard', 'again']));
      expect((result as WriteFailed).outcome, TransferOutcome.writeFailed);
      expect(fs.moveCalls, isEmpty);
      expect(await File(writer.tempPath).exists(), isFalse);
      expect(namesIn(folder), isEmpty);
    });

    test('(b) a mark that deletes the temp and leaves it empty gives damaged '
        'and saves nothing', () async {
      final folder = await tempFolder();
      final sub = subOf(folder);
      await Directory(sub).create();
      final orphanName = '~nexusbridges-${'b' * 32}.partial';
      final orphan = File(join(sub, orphanName));
      await orphan.writeAsBytes(const [4, 5, 6], flush: true);
      final fs = FactsPlatform(
        markFact: (path) async {
          await File(path).delete();
          await File('$path:Zone.Identifier').writeAsString(zoneIdentifierText);
          return true;
        },
      );
      final bytes = randomBytes(4096, 1822);
      final writer = await IncomingFileWriter.open(
        target: targetFor(folder, supportsMark: true),
        size: bytes.length,
        fs: fs,
      );
      await writer.add(bytes);

      final result = await writer.finish(
        name: 'b.bin',
        expectedSha256: digestOf(bytes),
      );

      expect((result as WriteFailed).outcome, TransferOutcome.damaged);
      expect(fs.moveCalls, isEmpty);
      expect(namesIn(folder), [tempFolderName]);
      expect(namesIn(sub), [orphanName]);
      expect(await orphan.readAsBytes(), const [4, 5, 6]);
      await writer.discard();
      expect(namesIn(sub), [orphanName]);
    });

    test('(c) discard during a held move waits and the saved file '
        'stays', () async {
      final folder = await tempFolder();
      final hold = Completer<void>();
      var moveStarted = false;
      final fs = FactsPlatform(
        moveFact: (from, to, name) async {
          moveStarted = true;
          await hold.future;
          return windowsFs.moveToFreeName(from, to, name);
        },
      );
      final bytes = randomBytes(mib + 77, 1823);
      final writer = await IncomingFileWriter.open(
        target: targetFor(folder, supportsMark: true),
        size: bytes.length,
        fs: fs,
      );
      await addInChunks(writer, bytes, 65536);
      final order = <String>[];

      final finishing = writer
          .finish(name: 'c.bin', expectedSha256: digestOf(bytes))
          .then((result) {
            order.add('finish');
            return result;
          });
      await waitFor(() => moveStarted);
      final discarding = writer.discard().then((_) => order.add('discard'));
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(order, isEmpty);

      hold.complete();
      final result = await finishing;
      await discarding;
      await writer.discard();

      expect(order, ['finish', 'discard']);
      final saved = result as WriteSaved;
      expect(saved.finalName, 'c.bin');
      expect(saved.marked, isTrue);
      final content = await File(saved.finalPath).readAsBytes();
      expect(content, bytes);
      expect(digestOf(content), digestOf(bytes));
      expect(namesIn(folder), ['c.bin']);
    });

    test('(d) a discard requested before finish starts leaves finish with '
        'writeFailed and nothing saved', () async {
      final folder = await tempFolder();
      final fs = FactsPlatform();
      final writer = await IncomingFileWriter.open(
        target: targetFor(folder, supportsMark: true),
        size: 3,
        fs: fs,
      );
      await writer.add(Uint8List.fromList(const [1, 2, 3]));

      final discarding = writer.discard();
      final result = await writer.finish(
        name: 'd.bin',
        expectedSha256: digestOf(const [1, 2, 3]),
      );
      await discarding;

      expect((result as WriteFailed).outcome, TransferOutcome.writeFailed);
      expect(fs.markCalls, isEmpty);
      expect(fs.moveCalls, isEmpty);
      expect(namesIn(folder), isEmpty);
    });

    test('in every case the receive folder never holds a file of another '
        'length or digest', () async {
      final bytes = randomBytes(3000, 1824);
      final expected = digestOf(bytes);
      for (final fact in <Future<bool> Function(String)>[
        (path) async {
          await File(path).writeAsBytes(const [0], mode: FileMode.append);
          return true;
        },
        (path) async {
          await File(path).writeAsBytes(const [9, 9, 9]);
          return true;
        },
        (path) async {
          await File(path).delete();
          return true;
        },
      ]) {
        final folder = await tempFolder();
        final writer = await IncomingFileWriter.open(
          target: targetFor(folder, supportsMark: true),
          size: bytes.length,
          fs: FactsPlatform(markFact: fact),
        );
        await writer.add(bytes);

        final result = await writer.finish(
          name: 'e.bin',
          expectedSha256: expected,
        );

        expect((result as WriteFailed).outcome, TransferOutcome.damaged);
        for (final name in namesIn(folder)) {
          if (name == tempFolderName) continue;
          final content = await File(join(folder, name)).readAsBytes();
          expect(content.length, bytes.length, reason: name);
          expect(digestOf(content), expected, reason: name);
        }
        expect(namesIn(folder), isEmpty);
      }
    });
  });

  group('E183, RF-166, RF-170: all the bytes before saving [SEG]', () {
    final cases = <String, (int, List<int>)>{
      'size 1 GiB and 4 bytes': (1024 * mib, const [1, 2, 3, 4]),
      'size 10 and no bytes': (10, const []),
      'size 10 and the 5 bytes of hello': (10, 'hello'.codeUnits),
    };

    for (final MapEntry(key: label, value: (size, bytes)) in cases.entries) {
      test('$label gives connectionLost and leaves nothing', () async {
        final folder = await tempFolder();
        final fs = FactsPlatform();
        final writer = await IncomingFileWriter.open(
          target: targetFor(folder, supportsMark: true),
          size: size,
          fs: fs,
        );
        if (bytes.isNotEmpty) await writer.add(Uint8List.fromList(bytes));

        final result = await writer.finish(
          name: 'short.bin',
          expectedSha256: digestOf(bytes),
        );

        expect((result as WriteFailed).outcome, TransferOutcome.connectionLost);
        expect(fs.markCalls, isEmpty);
        expect(fs.moveCalls, isEmpty);
        expect(await File(writer.tempPath).exists(), isFalse);
        expect(namesIn(folder), isEmpty);
      });
    }

    test('size 0 and no bytes is saved empty', () async {
      final folder = await tempFolder();
      final writer = await IncomingFileWriter.open(
        target: targetFor(folder),
        size: 0,
        fs: windowsFs,
      );

      final result = await writer.finish(
        name: 'vacio.bin',
        expectedSha256: emptySha256,
      );

      final saved = result as WriteSaved;
      expect(await File(saved.finalPath).length(), 0);
      expect(namesIn(folder), ['vacio.bin']);
    });

    test('one byte less than announced gives connectionLost', () async {
      final folder = await tempFolder();
      final bytes = randomBytes(mib + 1, 1831);
      final writer = await IncomingFileWriter.open(
        target: targetFor(folder),
        size: bytes.length,
        fs: windowsFs,
      );
      await writer.add(Uint8List.sublistView(bytes, 0, bytes.length - 1));

      final result = await writer.finish(
        name: 'almost.bin',
        expectedSha256: digestOf(bytes.sublist(0, bytes.length - 1)),
      );

      expect((result as WriteFailed).outcome, TransferOutcome.connectionLost);
      expect(namesIn(folder), isEmpty);
    });
  });

  group('E192, RF-145, RF-214: finish checks the name again [SEG]', () {
    final cases = <String, TransferOutcome>{
      r'sub\inner.txt': TransferOutcome.invalidName,
      'CON.txt': TransferOutcome.invalidName,
      'trail.': TransferOutcome.invalidName,
      'x.pif': TransferOutcome.blockedType,
    };

    for (final MapEntry(key: name, value: outcome) in cases.entries) {
      test('"$name" gives ${outcome.name} and leaves nothing', () async {
        final folder = await tempFolder();
        final fs = FactsPlatform();
        final bytes = randomBytes(100, 192);
        final writer = await IncomingFileWriter.open(
          target: targetFor(folder, supportsMark: true),
          size: bytes.length,
          fs: fs,
        );
        await writer.add(bytes);

        final result = await writer.finish(
          name: name,
          expectedSha256: digestOf(bytes),
        );

        expect((result as WriteFailed).outcome, outcome);
        expect(fs.markCalls, isEmpty);
        expect(fs.moveCalls, isEmpty);
        expect(await File(writer.tempPath).exists(), isFalse);
        expect(await Directory(join(folder, 'sub')).exists(), isFalse);
        expect(namesIn(folder), isEmpty);
      });
    }
  });

  group('E193, RF-170: the writer with the Dart digest', () {
    test('a writer with startDartSha256 saves the same file', () async {
      final folder = await tempFolder();
      final bytes = randomBytes(2 * mib + 9, 1934);
      final writer = await IncomingFileWriter.open(
        target: targetFor(folder),
        size: bytes.length,
        fs: windowsFs,
        startDigest: startDartSha256,
      );
      await addInChunks(writer, bytes, 100000);

      final result = await writer.finish(
        name: 'dart.bin',
        expectedSha256: digestOf(bytes),
      );

      expect(await File((result as WriteSaved).finalPath).readAsBytes(), bytes);
    });

    test('a digest whose close fails gives writeFailed, saves nothing and '
        'is disposed', () async {
      final folder = await tempFolder();
      final digest = FailingDigest();
      final writer = await IncomingFileWriter.open(
        target: targetFor(folder),
        size: 3,
        fs: windowsFs,
        startDigest: () => digest,
      );
      await writer.add(Uint8List.fromList(const [1, 2, 3]));

      final result = await writer.finish(
        name: 'f.bin',
        expectedSha256: digestOf(const [1, 2, 3]),
      );

      expect((result as WriteFailed).outcome, TransferOutcome.writeFailed);
      expect(digest.disposes, greaterThanOrEqualTo(1));
      expect(namesIn(folder), isEmpty);
    });

    test('discard disposes the digest', () async {
      final folder = await tempFolder();
      final digest = FailingDigest();
      final writer = await IncomingFileWriter.open(
        target: targetFor(folder),
        size: 3,
        fs: windowsFs,
        startDigest: () => digest,
      );

      await writer.discard();

      expect(digest.disposes, 1);
      expect(namesIn(folder), isEmpty);
    });
  });
}

final class FailingDigest implements Sha256Stream {
  final Sha256Stream inner = startDartSha256();
  int disposes = 0;

  @override
  void add(List<int> bytes) => inner.add(bytes);

  @override
  String? close() {
    inner.close();
    return null;
  }

  @override
  void dispose() {
    disposes++;
    inner.dispose();
  }
}
