import 'dart:convert';
import 'dart:io';

import 'package:nexus_bridges_core/src/settings/settings.dart';
import 'package:nexus_bridges_core/src/storage/storage.dart';
import 'package:test/test.dart';

const String _folderPath = r'C:\Users\david\Downloads\NexusBridges';
const String _volume = 'NTFS-1a2b3c4d';
final DateTime _clock = DateTime(2026, 11, 3, 9, 8, 7);

Map<String, Object?> _complete() => {
  'version': 1,
  'language': 'es',
  'deviceName': 'PC David',
  'theme': 'light',
  'receiveFolder': {'path': _folderPath, 'volume': _volume},
  'exclusions': ['node_modules', '.git'],
  'closeToTray': false,
  'trayHintShown': true,
};

Map<String, Object?> _shape(SettingsSnapshot s) => {
  'language': s.language,
  'deviceName': s.deviceName,
  'theme': s.theme,
  'receiveFolder': s.receiveFolder == null
      ? null
      : [s.receiveFolder!.path, s.receiveFolder!.volumeId],
  'exclusions': s.exclusions,
  'closeToTray': s.closeToTray,
  'trayHintShown': s.trayHintShown,
};

final Map<String, Object?> _completeShape = {
  'language': 'es',
  'deviceName': 'PC David',
  'theme': ThemeChoice.light,
  'receiveFolder': [_folderPath, _volume],
  'exclusions': ['node_modules', '.git'],
  'closeToTray': false,
  'trayHintShown': true,
};

final Map<String, Object?> _defaultShape = {
  'language': null,
  'deviceName': null,
  'theme': ThemeChoice.dark,
  'receiveFolder': null,
  'exclusions': null,
  'closeToTray': true,
  'trayHintShown': false,
};

void main() {
  late Directory dataDir;
  late File settingsFile;

  setUp(() async {
    dataDir = await Directory.systemTemp.createTemp('nexus_008_settings_');
    addTearDown(() => dataDir.delete(recursive: true));
    settingsFile = File(
      '${dataDir.path}${Platform.pathSeparator}settings.json',
    );
  });

  SettingsStore store() =>
      SettingsStore(JsonFileStore(settingsFile), now: () => _clock);

  List<String> namesInData() =>
      dataDir
          .listSync()
          .map((e) => e.path.substring(e.path.lastIndexOf(r'\') + 1))
          .toList()
        ..sort();

  Future<Map<String, Object?>> fileJson() async =>
      jsonDecode(await settingsFile.readAsString()) as Map<String, Object?>;

  Future<void> writeJson(Map<String, Object?> json) =>
      settingsFile.writeAsString(jsonEncode(json));

  group('E801: SettingsStore.load key by key (RF-504, S3)', () {
    test('a complete file gives every value', () async {
      await writeJson(_complete());

      expect(_shape(await store().load()), _completeShape);
      expect(namesInData(), ['settings.json']);
    });

    final damaged = <String, Object?>{
      'deviceName': 'x' * 300,
      'theme': 'blue',
      'closeToTray': 'yes',
      'language': 'fr',
      'exclusions': [for (var i = 0; i < 65; i++) 'name$i'],
      'trayHintShown': 1,
      'receiveFolder': {'path': 'Downloads', 'volume': _volume},
    };
    for (final MapEntry(:key, :value) in damaged.entries) {
      test('a damaged $key falls back to its default and the other keys stay '
          'as they were', () async {
        await writeJson({..._complete(), key: value});
        final before = await settingsFile.readAsString();

        final shape = _shape(await store().load());

        expect(shape, {..._completeShape, key: _defaultShape[key]});
        expect(await settingsFile.readAsString(), before);
        expect(namesInData(), ['settings.json']);
      });
    }

    test('a missing key falls back to its default too', () async {
      for (final key in _completeShape.keys) {
        await writeJson(_complete()..remove(key));

        expect(_shape(await store().load()), {
          ..._completeShape,
          key: _defaultShape[key],
        }, reason: key);
      }
    });

    test('deviceName is kept from 1 to 256 units and dropped when empty, '
        'longer or not a string (the fine rule is the node\'s)', () async {
      final cases = <Object?, String?>{
        'a': 'a',
        'x' * 256: 'x' * 256,
        'x' * 257: null,
        '': null,
        5: null,
        null: null,
        ['PC']: null,
        'PC\u202EDavid': 'PC\u202EDavid',
      };
      for (final MapEntry(:key, :value) in cases.entries) {
        await writeJson({..._complete(), 'deviceName': key});

        expect((await store().load()).deviceName, value, reason: '$key');
      }
    });

    test('each theme name is read and anything else is dark', () async {
      for (final MapEntry(:key, :value) in {
        'dark': ThemeChoice.dark,
        'light': ThemeChoice.light,
        'system': ThemeChoice.system,
        'Light': ThemeChoice.dark,
        3: ThemeChoice.dark,
      }.entries) {
        await writeJson({..._complete(), 'theme': key});

        expect((await store().load()).theme, value, reason: '$key');
      }
    });

    test(
      'without a file everything is the default and nothing is created',
      () async {
        expect(_shape(await store().load()), _defaultShape);
        expect(namesInData(), isEmpty);
      },
    );

    for (final MapEntry(key: label, value: content) in {
      'broken JSON': '{"version":1,"deviceName":"PC David"',
      'a JSON array': '["PC David"]',
      'plain text': 'PC David',
      'an empty object': '{}',
      'version "1" as text': '{"version":"1","deviceName":"PC David"}',
      'version 0': '{"version":0,"deviceName":"PC David"}',
      'version -3': '{"version":-3,"deviceName":"PC David"}',
      'version 1.0': '{"version":1.0,"deviceName":"PC David"}',
      'version null': '{"version":null,"deviceName":"PC David"}',
    }.entries) {
      test('$label is quarantined with the injected time, everything is the '
          'default and the next write works (clarify point 9)', () async {
        await settingsFile.writeAsString(content);
        final settings = store();

        expect(_shape(await settings.load()), _defaultShape);

        expect(namesInData(), ['settings.json.broken-20261103-090807']);
        expect(
          await File(
            '${dataDir.path}${Platform.pathSeparator}'
            'settings.json.broken-20261103-090807',
          ).readAsString(),
          content,
        );
        expect(await settings.writeDeviceName('PC Nuevo'), isTrue);
        expect(await fileJson(), {'version': 1, 'deviceName': 'PC Nuevo'});
      });
    }

    for (final version in [2, 7]) {
      test('version $version gives the defaults and leaves the store read '
          'only: writes give false and the file stays byte for byte', () async {
        final content = utf8.encode(
          jsonEncode({..._complete(), 'version': version, 'futuro': 1}),
        );
        await settingsFile.writeAsBytes(content);
        final settings = store();

        expect(_shape(await settings.load()), _defaultShape);
        expect(await settings.writeDeviceName('PC Nuevo'), isFalse);
        expect(await settings.writeDeviceName(null), isFalse);
        expect(
          await settings.writeReceiveFolder(
            const SavedReceiveFolder(path: _folderPath, volumeId: _volume),
          ),
          isFalse,
        );

        expect(await settingsFile.readAsBytes(), content);
        expect(namesInData(), ['settings.json']);
      });
    }

    test('after loading a version 2 the store stays read only even if the '
        'file is replaced by a version 1', () async {
      await writeJson({..._complete(), 'version': 2});
      final settings = store();
      await settings.load();
      const replaced = '{"version":1,"language":"en"}';
      await settingsFile.writeAsString(replaced);

      expect(await settings.writeDeviceName('PC Nuevo'), isFalse);
      expect(await settingsFile.readAsString(), replaced);
    });

    test('a version 2 found while writing, without a load, gives false and '
        'leaves the file as it was', () async {
      const content = '{"version":2,"deviceName":"Futuro"}';
      await settingsFile.writeAsString(content);
      final settings = store();

      expect(await settings.writeDeviceName('PC Nuevo'), isFalse);
      expect(await settingsFile.readAsString(), content);
      expect(namesInData(), ['settings.json']);
    });

    test('a folder named settings.json gives the defaults without throwing '
        'and writes give false', () async {
      await Directory(settingsFile.path).create();
      final settings = store();

      expect(_shape(await settings.load()), _defaultShape);
      expect(await settings.writeDeviceName('PC Nuevo'), isFalse);
      expect(await Directory(settingsFile.path).exists(), isTrue);
    });

    test(
      'bytes that are not UTF-8 are quarantined and give the defaults',
      () async {
        await settingsFile.writeAsBytes([0x7B, 0xFF, 0xFE, 0x7D]);

        expect(_shape(await store().load()), _defaultShape);
        expect(namesInData(), ['settings.json.broken-20261103-090807']);
      },
    );
  });

  group('E802: queued writes keep every key (RF-502, S3, DA-6)', () {
    test(
      '20 writes of the name and the folder launched at once all end up '
      'in the file, the last of each wins and the unknown keys stay',
      () async {
        await writeJson({'version': 1, 'futuro': 1, 'language': 'en'});
        final settings = store();

        final writes = <Future<bool>>[
          for (var i = 0; i < 20; i++)
            i.isEven
                ? settings.writeDeviceName('PC $i')
                : settings.writeReceiveFolder(
                    SavedReceiveFolder(
                      path: '$_folderPath$i',
                      volumeId: _volume,
                    ),
                  ),
        ];

        expect(await Future.wait(writes), everyElement(isTrue));
        expect(await fileJson(), {
          'version': 1,
          'futuro': 1,
          'language': 'en',
          'deviceName': 'PC 18',
          'receiveFolder': {'path': '${_folderPath}19', 'volume': _volume},
        });
        expect(namesInData(), ['settings.json']);
      },
    );

    test('two stores over the same file do not lose each other\'s key when '
        'they write one after the other', () async {
      await writeJson({
        'version': 1,
        'futuro': {'a': 1},
      });

      expect(await store().writeDeviceName('PC David'), isTrue);
      expect(
        await store().writeReceiveFolder(
          const SavedReceiveFolder(path: _folderPath, volumeId: _volume),
        ),
        isTrue,
      );

      expect(await fileJson(), {
        'version': 1,
        'futuro': {'a': 1},
        'deviceName': 'PC David',
        'receiveFolder': {'path': _folderPath, 'volume': _volume},
      });
    });

    test('writeDeviceName(null) removes the key and keeps the rest', () async {
      await writeJson({..._complete(), 'futuro': 1});

      expect(await store().writeDeviceName(null), isTrue);

      expect(await fileJson(), {
        ..._complete()..remove('deviceName'),
        'futuro': 1,
      });
      expect((await store().load()).deviceName, isNull);
    });

    test(
      'writeDeviceName(null) without a file writes only the version',
      () async {
        expect(await store().writeDeviceName(null), isTrue);

        expect(await fileJson(), {'version': 1});
      },
    );

    test('writeDeviceName without a file writes version 1 and the name, and '
        'load gives it back', () async {
      expect(await store().writeDeviceName('PC David'), isTrue);

      expect(await fileJson(), {'version': 1, 'deviceName': 'PC David'});
      expect((await store().load()).deviceName, 'PC David');
    });

    test(
      'a write that fails does not block the ones queued behind it',
      () async {
        await Directory(settingsFile.path).create();
        final settings = store();

        final failed = settings.writeDeviceName('PC Uno');
        final after = failed.then((_) async {
          await Directory(settingsFile.path).delete();
          return settings.writeDeviceName('PC Dos');
        });

        expect(await failed, isFalse);
        expect(await after, isTrue);
        expect(await fileJson(), {'version': 1, 'deviceName': 'PC Dos'});
      },
    );

    test('an invalid receive folder gives false without touching the file '
        'nor the queue', () async {
      await writeJson({'version': 1, 'deviceName': 'PC David'});
      final settings = store();

      final bad = settings.writeReceiveFolder(
        const SavedReceiveFolder(path: 'relative', volumeId: _volume),
      );
      final good = settings.writeDeviceName('PC Dos');

      expect(await bad, isFalse);
      expect(await good, isTrue);
      expect(await fileJson(), {'version': 1, 'deviceName': 'PC Dos'});
    });
  });
}
