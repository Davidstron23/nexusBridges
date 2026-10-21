import 'dart:convert';
import 'dart:io';

import 'package:nexus_bridges_core/src/storage/storage.dart';
import 'package:test/test.dart';

void main() {
  late Directory temp;

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('nexus_storage_test_');
    addTearDown(() => temp.delete(recursive: true));
  });

  File fileIn(String relative) =>
      File('${temp.path}${Platform.pathSeparator}$relative');

  Future<List<String>> namesIn(Directory dir) async {
    final names = await dir
        .list()
        .map((e) => e.uri.pathSegments.lastWhere((s) => s.isNotEmpty))
        .toList();
    return names..sort();
  }

  group('writeFileAtomic', () {
    test('creates missing parent folders and writes the exact bytes', () async {
      final file = fileIn(
        'a${Platform.pathSeparator}b${Platform.pathSeparator}'
        'data.bin',
      );
      final bytes = [0, 1, 2, 250, 255, 10, 13];

      await writeFileAtomic(file, bytes);

      expect(await file.readAsBytes(), bytes);
      expect(await namesIn(file.parent), ['data.bin']);
    });

    test('replaces an existing file and leaves no .tmp behind', () async {
      final file = fileIn('data.json');
      await file.writeAsString('old content that is longer than the new one');

      await writeFileAtomic(file, utf8.encode('new'));

      expect(await file.readAsString(), 'new');
      expect(await File('${file.path}.tmp').exists(), isFalse);
      expect(await namesIn(temp), ['data.json']);
    });

    test(
      'propagates FileSystemException when the parent cannot be created',
      () async {
        final blocker = fileIn('blocker');
        await blocker.writeAsString('i am a file, not a folder');
        final file = fileIn('blocker${Platform.pathSeparator}data.json');

        await expectLater(
          writeFileAtomic(file, [1, 2, 3]),
          throwsA(isA<FileSystemException>()),
        );
      },
    );
  });

  group('JsonFileStore.read', () {
    test('returns null when the file does not exist', () async {
      final store = JsonFileStore(fileIn('missing.json'));

      expect(await store.read(), isNull);
    });

    test('returns the map when the file holds a JSON object', () async {
      final file = fileIn('settings.json');
      await file.writeAsString(
        '{"version": 1, "language": "es", "nested": {"a": [1, 2]}}',
      );

      expect(await JsonFileStore(file).read(), {
        'version': 1,
        'language': 'es',
        'nested': {
          'a': [1, 2],
        },
      });
    });

    test('throws FormatException when the JSON is an array', () async {
      final file = fileIn('array.json');
      await file.writeAsString('[]');

      await expectLater(
        JsonFileStore(file).read(),
        throwsA(isA<FormatException>()),
      );
    });

    test('throws FormatException when the JSON is a scalar', () async {
      final file = fileIn('scalar.json');
      await file.writeAsString('42');

      await expectLater(
        JsonFileStore(file).read(),
        throwsA(isA<FormatException>()),
      );
    });

    test('throws FormatException when the text is not JSON', () async {
      final file = fileIn('garbage.json');
      await file.writeAsString('this is { not json');

      await expectLater(
        JsonFileStore(file).read(),
        throwsA(isA<FormatException>()),
      );
    });
  });

  group('JsonFileStore.write', () {
    test('round-trips through read', () async {
      final store = JsonFileStore(
        fileIn(
          'nested${Platform.pathSeparator}'
          'paired.json',
        ),
      );
      final json = <String, Object?>{
        'version': 1,
        'devices': [
          {'name': 'Portátil de David', 'trusted': true},
        ],
        'empty': null,
      };

      await store.write(json);

      expect(await store.read(), json);
    });

    test('writes indented UTF-8 without BOM', () async {
      final file = fileIn('settings.json');

      await JsonFileStore(file).write({'version': 1, 'name': 'Portátil'});

      final bytes = await file.readAsBytes();
      expect(bytes.take(3), isNot([0xEF, 0xBB, 0xBF]));
      expect(bytes, utf8.encode('{\n  "version": 1,\n  "name": "Portátil"\n}'));
      expect(await File('${file.path}.tmp').exists(), isFalse);
    });
  });

  group('JsonFileStore.quarantine', () {
    final now = DateTime(2026, 3, 4, 5, 6, 7);
    const stamp = '20260304-050607';

    test('renames the file to <path>.broken-yyyyMMdd-HHmmss', () async {
      final file = fileIn('networks.json');
      await file.writeAsString('{ broken');

      final moved = await JsonFileStore(file).quarantine(now);

      expect(moved.path, '${file.path}.broken-$stamp');
      expect(await file.exists(), isFalse);
      expect(await moved.readAsString(), '{ broken');
    });

    test('appends -2 when the quarantine name already exists', () async {
      final file = fileIn('networks.json');
      await file.writeAsString('second');
      final first = File('${file.path}.broken-$stamp');
      await first.writeAsString('first');

      final moved = await JsonFileStore(file).quarantine(now);

      expect(moved.path, '${file.path}.broken-$stamp-2');
      expect(await file.exists(), isFalse);
      expect(await moved.readAsString(), 'second');
      expect(await first.readAsString(), 'first');
    });

    test('appends -3 when both the base name and -2 exist', () async {
      final file = fileIn('networks.json');
      await file.writeAsString('third');
      await File('${file.path}.broken-$stamp').writeAsString('first');
      await File('${file.path}.broken-$stamp-2').writeAsString('second');

      final moved = await JsonFileStore(file).quarantine(now);

      expect(moved.path, '${file.path}.broken-$stamp-3');
      expect(await file.exists(), isFalse);
      expect(await moved.readAsString(), 'third');
      expect(await File('${file.path}.broken-$stamp').readAsString(), 'first');
      expect(
        await File('${file.path}.broken-$stamp-2').readAsString(),
        'second',
      );
    });
  });
}
