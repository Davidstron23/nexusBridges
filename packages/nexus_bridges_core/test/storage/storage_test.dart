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

  group('defaultDataDir (plan v2.7 point 9)', () {
    final sep = Platform.pathSeparator;
    final notSet = isA<StateError>().having(
      (e) => e.message,
      'message',
      'LOCALAPPDATA is not set',
    );

    test('ends in NexusBridges under LOCALAPPDATA', () {
      final dir = defaultDataDir(environment: {'LOCALAPPDATA': r'C:\x'});

      expect(dir.path, 'C:\\x${sep}NexusBridges');
      expect(
        dir.uri.pathSegments.where((s) => s.isNotEmpty).last,
        'NexusBridges',
      );
    });

    test('uses only LOCALAPPDATA and ignores other variables', () {
      final dir = defaultDataDir(
        environment: {
          'APPDATA': r'C:\roaming',
          'LOCALAPPDATA': temp.path,
          'USERPROFILE': r'C:\home',
        },
      );

      expect(dir.path, '${temp.path}${sep}NexusBridges');
    });

    test('does not create the folder', () async {
      final dir = defaultDataDir(environment: {'LOCALAPPDATA': temp.path});

      expect(await dir.exists(), isFalse);
      expect(await namesIn(temp), isEmpty);
    });

    test('throws StateError without LOCALAPPDATA', () {
      expect(() => defaultDataDir(environment: {}), throwsA(notSet));
      expect(
        () => defaultDataDir(environment: {'APPDATA': r'C:\roaming'}),
        throwsA(notSet),
      );
    });

    test('throws StateError with an empty LOCALAPPDATA', () {
      expect(
        () => defaultDataDir(environment: {'LOCALAPPDATA': ''}),
        throwsA(notSet),
      );
    });

    test('reads the process environment when none is given', () {
      final localAppData = Platform.environment['LOCALAPPDATA'];
      if (localAppData == null || localAppData.isEmpty) {
        expect(defaultDataDir, throwsA(notSet));
        return;
      }

      expect(defaultDataDir().path, '$localAppData${sep}NexusBridges');
    });
  });

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

  group('writeFileAtomic serializes per file (plan v2.6, point 9)', () {
    final tempName = RegExp(r'^data\.json\.\d+\.\d+\.tmp$');

    test(
      '50 concurrent writes to one file: no failure, last one wins',
      () async {
        final file = fileIn('data.json');

        final results = await Future.wait([
          for (var i = 0; i < 50; i++)
            writeFileAtomic(
              file,
              utf8.encode('{"write": $i, "padding": "${'x' * (i * 97)}"}'),
            ).then<Object?>((_) => null, onError: (Object e) => e),
        ]);

        expect(results.whereType<Object>(), isEmpty);
        expect(
          await file.readAsString(),
          '{"write": 49, "padding": "${'x' * (49 * 97)}"}',
        );
        expect(await namesIn(temp), ['data.json']);
      },
    );

    test('concurrent writes complete in the order they were asked', () async {
      final file = fileIn('data.json');
      final completed = <int>[];

      await Future.wait([
        for (var i = 0; i < 20; i++)
          writeFileAtomic(
            file,
            utf8.encode('$i'),
          ).then((_) => completed.add(i)),
      ]);

      expect(completed, [for (var i = 0; i < 20; i++) i]);
      expect(await file.readAsString(), '19');
    });

    test(
      'the same file through another spelling of its path is serialized',
      () async {
        final file = fileIn('data.json');
        final other = File(
          Platform.isWindows ? file.path.toUpperCase() : file.path,
        );

        final results = await Future.wait([
          for (var i = 0; i < 20; i++)
            writeFileAtomic(
              i.isEven ? file : other,
              utf8.encode('$i'),
            ).then<Object?>((_) => null, onError: (Object e) => e),
        ]);

        expect(results.whereType<Object>(), isEmpty);
        expect(await file.readAsString(), '19');
        expect(await namesIn(temp), hasLength(1));
      },
    );

    test('writes to different files run in parallel and all land', () async {
      final files = [for (var i = 0; i < 20; i++) fileIn('file-$i.json')];

      await Future.wait([
        for (var round = 0; round < 3; round++)
          for (var i = 0; i < files.length; i++)
            writeFileAtomic(files[i], utf8.encode('$i-$round')),
      ]);

      for (var i = 0; i < files.length; i++) {
        expect(await files[i].readAsString(), '$i-2');
      }
      expect(
        await namesIn(temp),
        [for (final f in files) f.uri.pathSegments.last]..sort(),
      );
    });

    test('a failure reaches its caller and the next write works', () async {
      final blocker = fileIn('blocker');
      await blocker.writeAsString('i am a file');
      final file = fileIn('blocker${Platform.pathSeparator}data.json');

      await expectLater(
        writeFileAtomic(file, utf8.encode('first')),
        throwsA(isA<FileSystemException>()),
      );
      await blocker.delete();

      await writeFileAtomic(file, utf8.encode('second'));

      expect(await file.readAsString(), 'second');
      expect(await namesIn(file.parent), ['data.json']);
    });

    test(
      'each queued caller gets its own failure, then the queue goes on',
      () async {
        final blocker = fileIn('blocker');
        await blocker.writeAsString('i am a file');
        final file = fileIn('blocker${Platform.pathSeparator}data.json');

        final outcomes = await Future.wait([
          for (var i = 0; i < 5; i++)
            writeFileAtomic(
              file,
              utf8.encode('$i'),
            ).then<Object?>((_) => null, onError: (Object e) => e),
        ]);

        expect(outcomes, everyElement(isA<FileSystemException>()));
        await blocker.delete();
        await writeFileAtomic(file, utf8.encode('after'));
        expect(await file.readAsString(), 'after');
      },
    );

    test('a leftover <file>.tmp folder does not block the write', () async {
      final file = fileIn('data.json');
      final leftover = Directory('${file.path}.tmp');
      await leftover.create();
      await File('${leftover.path}${Platform.pathSeparator}keep')
          .writeAsString('k');

      await writeFileAtomic(file, utf8.encode('content'));

      expect(await file.readAsString(), 'content');
      expect(await namesIn(temp), ['data.json', 'data.json.tmp']);
      expect(await namesIn(leftover), ['keep']);
    });

    test('the temporary file has a unique name while it is written', () async {
      final file = fileIn('data.json');
      final payload = List<int>.filled(64 * 1024 * 1024, 7);
      final seen = <String>{};
      var done = false;

      final write = writeFileAtomic(
        file,
        payload,
      ).whenComplete(() => done = true);
      while (!done) {
        for (final name in await namesIn(temp)) {
          if (name.endsWith('.tmp')) seen.add(name);
        }
        await Future<void>.delayed(Duration.zero);
      }
      await write;

      if (seen.isEmpty) {
        markTestSkipped('the write was too fast to see its temporary file');
        return;
      }
      expect(seen, everyElement(matches(tempName)));
      expect(seen, isNot(contains('data.json.tmp')));
      expect(await namesIn(temp), ['data.json']);
      expect(await file.length(), payload.length);
    });

    test(
      'a failed rename removes the temporary file and keeps the error',
      () async {
        final file = fileIn('data.json');
        final target = Directory(file.path);
        await target.create();
        await File('${target.path}${Platform.pathSeparator}inside')
            .writeAsString('i');

        Object? caught;
        try {
          await writeFileAtomic(file, utf8.encode('content'));
        } catch (e) {
          caught = e;
        }

        expect(caught, isA<FileSystemException>());
        final error = caught! as FileSystemException;
        expect(error.message.toLowerCase(), contains('rename'));
        expect(error.path, isNotNull);
        expect(error.path!, matches(RegExp(r'data\.json\.\d+\.\d+\.tmp$')));
        expect(await namesIn(temp), ['data.json']);
        expect(await target.exists(), isTrue);
        expect(await namesIn(target), ['inside']);
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

  group('JsonFileStore.readVersioned (C9)', () {
    final unsupported = isA<FormatException>().having(
      (e) => e.message,
      'message',
      'unsupported version',
    );

    Future<Map<String, Object?>?> readAs(int version, String content) async {
      final file = fileIn('data.json');
      await file.writeAsString(content);
      return JsonFileStore(file).readVersioned(version);
    }

    test('returns the map when the version is the one asked', () async {
      expect(await readAs(1, '{"version": 1, "language": "es"}'), {
        'version': 1,
        'language': 'es',
      });
      expect(await readAs(2, '{"version": 2, "devices": []}'), {
        'version': 2,
        'devices': <Object?>[],
      });
    });

    test('returns null when the file does not exist', () async {
      expect(
        await JsonFileStore(fileIn('missing.json')).readVersioned(1),
        isNull,
      );
      expect(await namesIn(temp), isEmpty);
    });

    final wrong = <String, (int, String)>{
      'version 2 read as 1': (1, '{"version": 2}'),
      'version 1 read as 2': (2, '{"version": 1, "devices": []}'),
      'no version': (1, '{"language": "es"}'),
      'a null version': (1, '{"version": null}'),
      'the version as text': (1, '{"version": "1"}'),
      'the version as 1.0': (1, '{"version": 1.0}'),
      'the version as 1.5': (1, '{"version": 1.5}'),
      'a negative version': (1, '{"version": -1}'),
      'the version inside a list': (1, '{"version": [1]}'),
      'an empty object': (1, '{}'),
    };

    for (final MapEntry(key: label, value: (version, content))
        in wrong.entries) {
      test('$label throws FormatException and leaves the file', () async {
        await expectLater(readAs(version, content), throwsA(unsupported));
        expect(await fileIn('data.json').readAsString(), content);
      });
    }

    test(
      'a file that is not a JSON object still throws FormatException',
      () async {
        await expectLater(readAs(1, '[1]'), throwsA(isA<FormatException>()));
        await expectLater(
          readAs(1, '{ broken'),
          throwsA(isA<FormatException>()),
        );
      },
    );
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

    test('uses the reason in the name when one is given', () async {
      final file = fileIn('paired.json');
      await file.writeAsString('{"version": 2}');

      final moved = await JsonFileStore(file)
          .quarantine(now, reason: 'previous-identity');

      expect(moved.path, '${file.path}.previous-identity-$stamp');
      expect(await file.exists(), isFalse);
      expect(await moved.readAsString(), '{"version": 2}');
      expect(await namesIn(temp), ['paired.json.previous-identity-$stamp']);
    });

    test('appends -2 to a reason that is already taken, without touching '
        'the broken copy', () async {
      final file = fileIn('paired.json');
      await File('${file.path}.broken-$stamp').writeAsString('broken');
      await File('${file.path}.previous-identity-$stamp')
          .writeAsString('first');
      await file.writeAsString('second');

      final moved = await JsonFileStore(file)
          .quarantine(now, reason: 'previous-identity');

      expect(moved.path, '${file.path}.previous-identity-$stamp-2');
      expect(await moved.readAsString(), 'second');
      expect(
        await File('${file.path}.previous-identity-$stamp').readAsString(),
        'first',
      );
      expect(await File('${file.path}.broken-$stamp').readAsString(), 'broken');
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
