@TestOn('windows')
library;

import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:ffi/ffi.dart';
import 'package:nexus_bridges_core/src/transfer/hashing.dart';
import 'package:nexus_bridges_core/src/transfer/windows_sha256.dart';
import 'package:nexus_bridges_core/src/transport/transport.dart'
    show AbortSignal;
import 'package:test/test.dart';
import 'package:win32/win32.dart';

const String emptySha256 =
    'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855';

Future<Directory> tempFolder() async {
  final dir = await Directory.systemTemp.createTemp('nexus_t4_hash_');
  addTearDown(() async {
    if (await dir.exists()) await dir.delete(recursive: true);
  });
  return dir;
}

Future<File> writeFile(Directory dir, String name, List<int> bytes) async {
  final file = File('${dir.path}\\$name');
  await file.writeAsBytes(bytes, flush: true);
  return file;
}

Uint8List randomBytes(int length, int seed) {
  final random = Random(seed);
  final bytes = Uint8List(length);
  for (var i = 0; i < length; i++) {
    bytes[i] = random.nextInt(256);
  }
  return bytes;
}

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

const int mib = 1048576;

String? digestInChunks(Sha256Stream digest, Uint8List bytes, int chunk) {
  for (var offset = 0; offset < bytes.length; offset += chunk) {
    final end = min(offset + chunk, bytes.length);
    digest.add(Uint8List.sublistView(bytes, offset, end));
  }
  return digest.close();
}

Sha256Stream windowsDigest() {
  final digest = startWindowsSha256();
  expect(digest, isNotNull, reason: 'CNG must be available on Windows');
  return digest!;
}

final class CountingDigest implements Sha256Stream {
  CountingDigest(this.inner, {this.failOnClose = false});

  final Sha256Stream inner;
  final bool failOnClose;
  int added = 0;
  int closes = 0;
  int disposes = 0;

  @override
  void add(List<int> bytes) {
    added += bytes.length;
    inner.add(bytes);
  }

  @override
  String? close() {
    closes++;
    final hex = inner.close();
    return failOnClose ? null : hex;
  }

  @override
  void dispose() {
    disposes++;
    inner.dispose();
  }
}

void main() {
  group('E29 hashFile', () {
    test('an empty file gives size 0 and the SHA-256 of nothing', () async {
      final dir = await tempFolder();
      final file = await writeFile(dir, 'empty.bin', const []);

      final digest = await hashFile(file.path, abort: AbortSignal());

      expect(digest, isNotNull);
      expect(digest!.size, 0);
      expect(digest.sha256, emptySha256);
    });

    test('a one byte file gives the digest of that byte', () async {
      final dir = await tempFolder();
      final file = await writeFile(dir, 'one.bin', const [0x41]);

      final digest = await hashFile(file.path, abort: AbortSignal());

      expect(digest!.size, 1);
      expect(digest.sha256, sha256.convert(const [0x41]).toString());
      expect(digest.sha256, matches(RegExp(r'^[0-9a-f]{64}$')));
    });

    test('3 MiB of random bytes match sha256.convert', () async {
      final dir = await tempFolder();
      final bytes = randomBytes(3 * 1048576, 29);
      final file = await writeFile(dir, 'big.bin', bytes);

      final digest = await hashFile(file.path, abort: AbortSignal());

      expect(digest!.size, bytes.length);
      expect(digest.sha256, sha256.convert(bytes).toString());
    });

    test('chunks that do not divide the size give the same digest', () async {
      final dir = await tempFolder();
      final bytes = randomBytes(100003, 7);
      final file = await writeFile(dir, 'odd.bin', bytes);
      final expected = sha256.convert(bytes).toString();

      for (final chunk in [1000, 4096, 100003, 200000]) {
        final digest = await hashFile(
          file.path,
          abort: AbortSignal(),
          chunkBytes: chunk,
        );
        expect(digest!.size, bytes.length, reason: '$chunk');
        expect(digest.sha256, expected, reason: '$chunk');
      }
    });

    test('the file is left unchanged and can be deleted afterwards', () async {
      final dir = await tempFolder();
      final bytes = randomBytes(5000, 3);
      final file = await writeFile(dir, 'same.bin', bytes);

      await hashFile(file.path, abort: AbortSignal());

      expect(await file.readAsBytes(), bytes);
      await file.delete();
      expect(await file.exists(), isFalse);
    });

    test('a signal aborted before starting gives null', () async {
      final dir = await tempFolder();
      final file = await writeFile(dir, 'a.bin', randomBytes(10, 1));
      final abort = AbortSignal()..abort();

      expect(await hashFile(file.path, abort: abort), isNull);

      await file.delete();
      expect(await file.exists(), isFalse);
    });

    test('aborting halfway gives null and closes the file', () async {
      final dir = await tempFolder();
      final file = await writeFile(dir, 'slow.bin', randomBytes(65536, 5));
      final abort = AbortSignal();

      final pending = hashFile(file.path, abort: abort, chunkBytes: 1);
      await Future<void>.delayed(const Duration(milliseconds: 30));
      abort.abort();
      final digest = await pending;

      expect(digest, isNull);
      await file.delete();
      expect(await file.exists(), isFalse);
    });

    test('a file locked exclusively throws FileSystemException', () async {
      final dir = await tempFolder();
      final file = await writeFile(dir, 'locked.bin', randomBytes(10, 2));
      final handle = openExclusively(file.path);
      addTearDown(handle.close);

      await expectLater(
        hashFile(file.path, abort: AbortSignal()),
        throwsA(isA<FileSystemException>()),
      );
    });

    test('a file that does not exist throws FileSystemException', () async {
      final dir = await tempFolder();

      await expectLater(
        hashFile('${dir.path}\\missing.bin', abort: AbortSignal()),
        throwsA(isA<FileSystemException>()),
      );
    });
  });

  group('E193, RF-135, RF-170: SHA-256 with CNG and the Dart backup', () {
    final lengths = [0, 1, 63, 64, 65, mib + 1];
    final chunks = [1, 7, 4096, mib];

    for (final length in lengths) {
      test('$length bytes give the same digest with CNG, with Dart and with '
          'sha256.convert, in every chunk size', () {
        final bytes = randomBytes(length, 193 + length);
        final expected = sha256.convert(bytes).toString();

        for (final chunk in chunks) {
          final windows = digestInChunks(windowsDigest(), bytes, chunk);
          final dart = digestInChunks(startDartSha256(), bytes, chunk);
          expect(windows, expected, reason: 'CNG, chunk $chunk');
          expect(dart, expected, reason: 'Dart, chunk $chunk');
        }
      });
    }

    test('a single add bigger than the 1 MiB native buffer is hashed '
        'whole', () {
      final bytes = randomBytes(3 * mib + 5, 1931);
      final digest = windowsDigest()..add(bytes);

      expect(digest.close(), sha256.convert(bytes).toString());
    });

    test('startSha256 gives a lower case hexadecimal digest of 64 '
        'characters', () {
      final digest = startSha256()..add(const [0x61, 0x62, 0x63]);

      final hex = digest.close();

      expect(hex, matches(RegExp(r'^[0-9a-f]{64}$')));
      expect(hex, sha256.convert(const [0x61, 0x62, 0x63]).toString());
    });

    test('CNG gives the digest of nothing when nothing is added', () {
      expect(windowsDigest().close(), emptySha256);
      expect(startDartSha256().close(), emptySha256);
    });

    for (final MapEntry(key: label, value: start)
        in <String, Sha256Stream Function()>{
          'CNG': windowsDigest,
          'Dart': startDartSha256,
        }.entries) {
      test('$label: the second close gives null without an exception', () {
        final digest = start()..add(const [1, 2, 3]);

        expect(digest.close(), sha256.convert(const [1, 2, 3]).toString());
        expect(digest.close(), isNull);
      });

      test('$label: add after close does nothing and dispose can be called '
          'twice', () {
        final digest = start()..add(const [1]);
        digest.close();
        digest.add(const [2]);
        digest.dispose();
        digest.dispose();

        expect(digest.close(), isNull);
      });

      test('$label: close after dispose gives null', () {
        final digest = start()..add(const [1]);
        digest.dispose();

        expect(digest.close(), isNull);
      });
    }

    test('many CNG digests at once stay independent', () {
      final digests = [for (var i = 0; i < 50; i++) windowsDigest()];
      for (var i = 0; i < digests.length; i++) {
        digests[i].add([i]);
      }
      for (var i = 0; i < digests.length; i++) {
        expect(digests[i].close(), sha256.convert([i]).toString());
      }
    });

    test('hashFile with the Dart backup gives the same digest as the '
        'default', () async {
      final dir = await tempFolder();
      final bytes = randomBytes(2 * mib + 3, 1932);
      final file = await writeFile(dir, 'same.bin', bytes);

      final byDefault = await hashFile(file.path, abort: AbortSignal());
      final byDart = await hashFile(
        file.path,
        abort: AbortSignal(),
        startDigest: startDartSha256,
      );

      expect(byDefault!.sha256, sha256.convert(bytes).toString());
      expect(byDart!.sha256, byDefault.sha256);
      expect(byDart.size, byDefault.size);
    });

    test('hashFile uses the given digest and disposes it', () async {
      final dir = await tempFolder();
      final bytes = randomBytes(5000, 1933);
      final file = await writeFile(dir, 'counted.bin', bytes);
      final counting = CountingDigest(startDartSha256());

      final digest = await hashFile(
        file.path,
        abort: AbortSignal(),
        chunkBytes: 1000,
        startDigest: () => counting,
      );

      expect(digest!.sha256, sha256.convert(bytes).toString());
      expect(counting.added, 5000);
      expect(counting.closes, 1);
      expect(counting.disposes, 1);
    });

    test('hashFile throws a FileSystemException without the path when the '
        'digest fails', () async {
      final dir = await tempFolder();
      final file = await writeFile(dir, 'failing.bin', randomBytes(10, 4));
      final counting = CountingDigest(startDartSha256(), failOnClose: true);

      Object? error;
      try {
        await hashFile(
          file.path,
          abort: AbortSignal(),
          startDigest: () => counting,
        );
      } catch (e) {
        error = e;
      }

      expect(error, isA<FileSystemException>());
      expect((error as FileSystemException).path, anyOf(isNull, isEmpty));
      expect(error.toString(), isNot(contains(dir.path)));
      expect(error.toString(), isNot(contains('failing')));
      expect(counting.disposes, 1);
      await file.delete();
      expect(await file.exists(), isFalse);
    });

    test('hashFile disposes the digest when aborted and when the file is '
        'missing', () async {
      final dir = await tempFolder();
      final file = await writeFile(dir, 'a.bin', randomBytes(10, 5));
      final aborted = CountingDigest(startDartSha256());
      final missing = CountingDigest(startDartSha256());

      expect(
        await hashFile(
          file.path,
          abort: AbortSignal()..abort(),
          startDigest: () => aborted,
        ),
        isNull,
      );
      await expectLater(
        hashFile(
          '${dir.path}\\missing.bin',
          abort: AbortSignal(),
          startDigest: () => missing,
        ),
        throwsA(isA<FileSystemException>()),
      );

      expect(aborted.disposes, 1);
      expect(missing.disposes, 1);
    });
  });
}
