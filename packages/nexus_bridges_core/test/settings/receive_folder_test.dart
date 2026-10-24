import 'dart:convert';
import 'dart:io';

import 'package:nexus_bridges_core/src/settings/settings.dart';
import 'package:nexus_bridges_core/src/storage/storage.dart';
import 'package:test/test.dart';

const String folderPath = r'C:\Users\david\Downloads\NexusBridges';
const String volume = 'NTFS-1a2b3c4d';

void main() {
  late Directory dataDir;
  late File settingsFile;

  setUp(() async {
    dataDir = await Directory.systemTemp.createTemp('nexus_t3_settings_');
    addTearDown(() => dataDir.delete(recursive: true));
    settingsFile = File(
      '${dataDir.path}${Platform.pathSeparator}settings.json',
    );
  });

  SettingsStore store() => SettingsStore(JsonFileStore(settingsFile));

  List<String> namesInData() =>
      dataDir
          .listSync()
          .map((e) => e.path.substring(e.path.lastIndexOf(r'\') + 1))
          .toList()
        ..sort();

  Future<Map<String, Object?>> fileJson() async =>
      jsonDecode(await settingsFile.readAsString()) as Map<String, Object?>;

  group('writeReceiveFolder and readReceiveFolder (E26, RF-203, RF-244)', () {
    test('writing keeps language and other keys, and reading gives the '
        'folder back', () async {
      await settingsFile.writeAsString(
        '{"version":1,"language":"es","other":{"a":1}}',
      );

      final saved = await store().writeReceiveFolder(
        const SavedReceiveFolder(path: folderPath, volumeId: volume),
      );

      expect(saved, isTrue);
      expect(await fileJson(), {
        'version': 1,
        'language': 'es',
        'other': {'a': 1},
        'receiveFolder': {'path': folderPath, 'volume': volume},
      });
      final read = await store().readReceiveFolder();
      expect(read?.path, folderPath);
      expect(read?.volumeId, volume);
      expect(await store().readLanguage(), 'es');
    });

    test('without a file it writes version 1 with only the folder', () async {
      final saved = await store().writeReceiveFolder(
        const SavedReceiveFolder(path: r'\\srv\share\in', volumeId: volume),
      );

      expect(saved, isTrue);
      expect(await fileJson(), {
        'version': 1,
        'receiveFolder': {'path': r'\\srv\share\in', 'volume': volume},
      });
      expect((await store().readReceiveFolder())?.path, r'\\srv\share\in');
    });

    test('writing twice replaces the folder', () async {
      await store().writeReceiveFolder(
        const SavedReceiveFolder(path: folderPath, volumeId: volume),
      );
      await store().writeReceiveFolder(
        const SavedReceiveFolder(
          path: r'D:\Recibidos',
          volumeId: 'exFAT-0f00ba11',
        ),
      );

      final read = await store().readReceiveFolder();
      expect(read?.path, r'D:\Recibidos');
      expect(read?.volumeId, 'exFAT-0f00ba11');
    });

    test('a settings.json locked by another handle gives false and is not '
        'changed', () async {
      const content = '{"version":1,"language":"en"}';
      await settingsFile.writeAsString(content);
      final handle = await settingsFile.open(mode: FileMode.append);
      addTearDown(handle.close);
      await handle.lock(FileLock.exclusive);

      final saved = await store().writeReceiveFolder(
        const SavedReceiveFolder(path: folderPath, volumeId: volume),
      );

      await handle.unlock();
      expect(saved, isFalse);
      expect(await settingsFile.readAsString(), content);
      expect(namesInData(), ['settings.json']);
    });

    test('a folder named settings.json gives false without throwing', () async {
      await Directory(settingsFile.path).create();

      final saved = await store().writeReceiveFolder(
        const SavedReceiveFolder(path: folderPath, volumeId: volume),
      );

      expect(saved, isFalse);
      expect(await Directory(settingsFile.path).exists(), isTrue);
    });

    for (final MapEntry(key: label, value: content) in {
      'broken JSON': '{"version":1,"language":"es"',
      'a JSON array': '["es"]',
      'plain text': 'es',
    }.entries) {
      test('$label is quarantined and the folder is written', () async {
        await settingsFile.writeAsString(content);

        final saved = await store().writeReceiveFolder(
          const SavedReceiveFolder(path: folderPath, volumeId: volume),
        );

        expect(saved, isTrue);
        expect(await fileJson(), {
          'version': 1,
          'receiveFolder': {'path': folderPath, 'volume': volume},
        });
        final names = namesInData();
        expect(names.length, 2);
        final quarantined = names.firstWhere(
          (n) => n.startsWith('settings.json.broken-'),
        );
        expect(
          await File('${dataDir.path}${Platform.pathSeparator}$quarantined')
              .readAsString(),
          content,
        );
      });
    }

    for (final MapEntry(key: label, value: content) in {
      'version 2 with language': '{"version":2,"language":"es"}',
      'no version': '{"language":"es"}',
      'version "1" as text': '{"version":"1","language":"es"}',
      'version 1.0': '{"version":1.0,"language":"es"}',
    }.entries) {
      test('$label gives false and the file stays byte for byte', () async {
        await settingsFile.writeAsBytes(utf8.encode(content));

        final saved = await store().writeReceiveFolder(
          const SavedReceiveFolder(path: folderPath, volumeId: volume),
        );

        expect(saved, isFalse);
        expect(await settingsFile.readAsBytes(), utf8.encode(content));
        expect(namesInData(), ['settings.json']);
      });
    }

    test('broken JSON whose quarantine is impossible gives false without '
        'throwing and nothing is written', () async {
      const content = '{"version":1,"language":';
      await settingsFile.writeAsString(content);
      final handle = await settingsFile.open();
      addTearDown(handle.close);

      final saved = await store().writeReceiveFolder(
        const SavedReceiveFolder(path: folderPath, volumeId: volume),
      );

      expect(saved, isFalse);
      expect(await settingsFile.readAsString(), content);
      expect(namesInData(), ['settings.json']);
    });
  });

  group('readReceiveFolder with invalid data (E26, RF-203)', () {
    test('without a file it gives null and creates nothing', () async {
      expect(await store().readReceiveFolder(), isNull);
      expect(namesInData(), isEmpty);
    });

    final invalid = <String, Object?>{
      'no receiveFolder': null,
      'a string': folderPath,
      'a list': [folderPath, volume],
      'an extra key': {'path': folderPath, 'volume': volume, 'x': 1},
      'no volume': {'path': folderPath},
      'an empty path': {'path': '', 'volume': volume},
      'a relative path': {'path': r'Downloads\NexusBridges', 'volume': volume},
      'a path with /': {'path': 'C:/Users/david', 'volume': volume},
      'a path with only the drive': {'path': 'C:', 'volume': volume},
      'a number as path': {'path': 5, 'volume': volume},
      'an upper-case serial': {'path': folderPath, 'volume': 'NTFS-1A2B3C4D'},
      'a short serial': {'path': folderPath, 'volume': 'NTFS-1a2b3c4'},
      'a system name of 17': {
        'path': folderPath,
        'volume': '${'A' * 17}-1a2b3c4d',
      },
      'a system with a symbol': {
        'path': folderPath,
        'volume': 'NT_FS-1a2b3c4d',
      },
      'an empty volume': {'path': folderPath, 'volume': ''},
      'a null volume': {'path': folderPath, 'volume': null},
      'a path longer than 32767': {
        'path': 'C:\\${'a' * 32766}',
        'volume': volume,
      },
    };

    for (final MapEntry(key: label, value: raw) in invalid.entries) {
      test('$label gives null and leaves the file alone', () async {
        final content = jsonEncode({
          'version': 1,
          'language': 'en',
          'receiveFolder': ?raw,
        });
        await settingsFile.writeAsString(content);

        expect(await store().readReceiveFolder(), isNull);
        expect(await settingsFile.readAsString(), content);
        expect(await store().readLanguage(), 'en');
      });
    }

    test('a path of exactly 32767 units is accepted', () async {
      final longPath = 'C:\\${'a' * 32764}';
      expect(longPath.length, 32767);
      await settingsFile.writeAsString(
        jsonEncode({
          'version': 1,
          'receiveFolder': {'path': longPath, 'volume': volume},
        }),
      );

      expect((await store().readReceiveFolder())?.path, longPath);
    });

    for (final MapEntry(key: label, value: content) in {
      'version 2':
          '{"version":2,"receiveFolder":{"path":"C:\\\\R",'
          '"volume":"$volume"}}',
      'broken JSON': '{"version":1,"receiveFolder":',
    }.entries) {
      test('$label gives null and leaves the file alone', () async {
        await settingsFile.writeAsString(content);

        expect(await store().readReceiveFolder(), isNull);
        expect(await settingsFile.readAsString(), content);
        expect(namesInData(), ['settings.json']);
      });
    }
  });

  group('E196, RF-203, RF-244: what is written can be read', () {
    const original = '{\n  "version": 1,\n  "language": "es"\n}';

    final invalid = <String, SavedReceiveFolder>{
      'a volume with an empty system name': const SavedReceiveFolder(
        path: folderPath,
        volumeId: '-1a2b3c4d',
      ),
      'an upper-case serial': const SavedReceiveFolder(
        path: folderPath,
        volumeId: 'NTFS-1A2B3C4D',
      ),
      'a relative path': const SavedReceiveFolder(
        path: r'relativa\x',
        volumeId: volume,
      ),
      'a path of 32768 units': SavedReceiveFolder(
        path: 'C:\\${'a' * 32765}',
        volumeId: volume,
      ),
      'an empty path': const SavedReceiveFolder(path: '', volumeId: volume),
    };

    for (final MapEntry(key: label, value: folder) in invalid.entries) {
      test('$label gives false and leaves settings.json byte for '
          'byte', () async {
        await settingsFile.writeAsString(original);
        final before = await settingsFile.readAsBytes();

        expect(await store().writeReceiveFolder(folder), isFalse);

        expect(await settingsFile.readAsBytes(), before);
        expect(namesInData(), ['settings.json']);
        expect(await store().readReceiveFolder(), isNull);
      });

      test('$label gives false and creates no file', () async {
        expect(await store().writeReceiveFolder(folder), isFalse);

        expect(namesInData(), isEmpty);
      });
    }

    test('the 32768 units case really has 32768 units', () {
      expect(invalid['a path of 32768 units']!.path.length, 32768);
    });

    test('an invalid folder leaves broken JSON alone, without '
        'quarantine', () async {
      const broken = '{"version":1,"receiveFolder":';
      await settingsFile.writeAsString(broken);

      expect(
        await store().writeReceiveFolder(
          const SavedReceiveFolder(path: folderPath, volumeId: '-1a2b3c4d'),
        ),
        isFalse,
      );

      expect(await settingsFile.readAsString(), broken);
      expect(namesInData(), ['settings.json']);
    });

    test('a valid folder is written and read back the same', () async {
      await settingsFile.writeAsString(original);

      expect(
        await store().writeReceiveFolder(
          const SavedReceiveFolder(path: folderPath, volumeId: volume),
        ),
        isTrue,
      );

      final read = await store().readReceiveFolder();
      expect(read?.path, folderPath);
      expect(read?.volumeId, 'NTFS-1a2b3c4d');
      expect(await store().readLanguage(), 'es');
    });

    test('a path of exactly 32767 units and a UNC path are written and read '
        'back', () async {
      for (final path in ['C:\\${'a' * 32764}', r'\\srv\datos\R']) {
        expect(
          await store().writeReceiveFolder(
            SavedReceiveFolder(path: path, volumeId: volume),
          ),
          isTrue,
          reason: path.substring(0, 5),
        );
        expect((await store().readReceiveFolder())?.path, path);
      }
    });
  });
}
