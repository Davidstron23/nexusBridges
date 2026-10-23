import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:nexus_bridges_core/src/settings/settings.dart';
import 'package:nexus_bridges_core/src/storage/storage.dart';
import 'package:test/test.dart';

void main() {
  late Directory dataDir;
  late File settingsFile;

  setUp(() async {
    dataDir = await Directory.systemTemp.createTemp('nexus_settings_test_');
    addTearDown(() => dataDir.delete(recursive: true));
    settingsFile = File(
      '${dataDir.path}${Platform.pathSeparator}settings.json',
    );
  });

  Future<String?> languageIn(String? content) async {
    if (content != null) await settingsFile.writeAsString(content);
    return SettingsStore(JsonFileStore(settingsFile)).readLanguage();
  }

  Future<List<String>> namesIn(Directory dir) async {
    final names = await dir
        .list()
        .map((e) => e.uri.pathSegments.lastWhere((s) => s.isNotEmpty))
        .toList();
    return names..sort();
  }

  group('SettingsStore.readLanguage', () {
    test('reads es', () async {
      expect(await languageIn('{"version": 1, "language": "es"}'), 'es');
    });

    test('reads en', () async {
      expect(await languageIn('{"version": 1, "language": "en"}'), 'en');
    });

    test('gives null without a file and creates nothing', () async {
      expect(await languageIn(null), isNull);
      expect(await namesIn(dataDir), isEmpty);
    });

    final invalid = <String, String>{
      'an unknown language': '{"version": 1, "language": "fr"}',
      'an upper-case language': '{"version": 1, "language": "ES"}',
      'no language key': '{"version": 1}',
      'a number as language': '{"version": 1, "language": 5}',
      'a list as language': '{"version": 1, "language": ["es"]}',
      'a null language': '{"version": 1, "language": null}',
    };

    for (final MapEntry(key: label, value: content) in invalid.entries) {
      test('gives null with $label', () async {
        expect(await languageIn(content), isNull);
        expect(await settingsFile.readAsString(), content);
      });
    }

    final corrupt = <String, String>{
      'broken JSON': '{"version": 1, "language": "es"',
      'a JSON array': '["es"]',
      'plain text': 'es',
      'an empty file': '',
    };

    for (final MapEntry(key: label, value: content) in corrupt.entries) {
      test('$label gives null and is left in place', () async {
        expect(await languageIn(content), isNull);
        expect(await namesIn(dataDir), ['settings.json']);
        expect(await settingsFile.readAsString(), content);
      });
    }

    final versions = <String, String>{
      'version 2': '{"version": 2, "language": "es"}',
      'no version': '{"language": "es"}',
      'version "1" as text': '{"version": "1", "language": "es"}',
      'version 1.0': '{"version": 1.0, "language": "es"}',
      'a null version': '{"version": null, "language": "en"}',
    };

    for (final MapEntry(key: label, value: content) in versions.entries) {
      test('$label gives null and the file stays as it was (C10)', () async {
        expect(await languageIn(content), isNull);
        expect(await namesIn(dataDir), ['settings.json']);
        expect(await settingsFile.readAsString(), content);
      });
    }

    test('a saved language with version 2 falls back to the Windows '
        'language (C10)', () async {
      await settingsFile.writeAsString('{"version": 2, "language": "en"}');

      expect(
        await loadLanguage(platformLanguageCode: 'es', dataDir: dataDir),
        'es',
      );
    });

    test('bytes that are not UTF-8 give null and stay in place', () async {
      await settingsFile.writeAsBytes(const [0xFF, 0xFE, 0x00, 0xC3]);

      expect(await languageIn(null), isNull);
      expect(await namesIn(dataDir), ['settings.json']);
    });
  });

  group('resolveLanguage (RF-63 and RF-64 of spec 002)', () {
    final cases = <(String?, String, String)>[
      (null, 'es', 'es'),
      (null, 'fr', 'en'),
      (null, 'en', 'en'),
      (null, '', 'en'),
      (null, 'ES', 'en'),
      ('en', 'es', 'en'),
      ('es', 'fr', 'es'),
      ('es', 'en', 'es'),
      ('en', 'en', 'en'),
      ('fr', 'es', 'es'),
      ('fr', 'de', 'en'),
      ('', 'es', 'es'),
    ];

    for (final (saved, platform, expected) in cases) {
      test('saved $saved and platform "$platform" give $expected', () {
        expect(
          resolveLanguage(saved: saved, platformLanguageCode: platform),
          expected,
        );
      });
    }
  });

  group('loadLanguage (RF-63 and RF-64 of spec 002)', () {
    Future<String> load(String platform) =>
        loadLanguage(platformLanguageCode: platform, dataDir: dataDir);

    test('a saved en wins over a Spanish Windows (RF-64)', () async {
      await settingsFile.writeAsString('{"version":1,"language":"en"}');

      expect(await load('es'), 'en');
    });

    test('a saved es wins over an English or French Windows (RF-64)', () async {
      await settingsFile.writeAsString('{"version":1,"language":"es"}');

      expect(await load('en'), 'es');
      expect(await load('fr'), 'es');
    });

    test('without a file a Spanish Windows gives es (RF-63)', () async {
      expect(await load('es'), 'es');
    });

    test('without a file a French Windows gives en (RF-63)', () async {
      expect(await load('fr'), 'en');
    });

    test('without a file an English Windows gives en (RF-63)', () async {
      expect(await load('en'), 'en');
      expect(await load(''), 'en');
    });

    test('reads and writes nothing else in the folder', () async {
      await settingsFile.writeAsString('{"version":1,"language":"en"}');

      await load('es');

      expect(await namesIn(dataDir), ['settings.json']);
      expect(
        await settingsFile.readAsString(),
        '{"version":1,"language":"en"}',
      );
    });

    test('without a file it creates nothing', () async {
      await load('es');

      expect(await namesIn(dataDir), isEmpty);
    });

    final unusable = <String, String>{
      'broken JSON': '{"version": 1, "language": "en"',
      'a JSON array': '["en"]',
      'plain text': 'en',
      'an empty file': '',
      'an unknown language': '{"version": 1, "language": "fr"}',
      'a null language': '{"version": 1, "language": null}',
      'an upper-case language': '{"version": 1, "language": "EN"}',
    };

    for (final MapEntry(key: label, value: content) in unusable.entries) {
      test('$label falls back to the Windows language', () async {
        await settingsFile.writeAsString(content);

        expect(await load('es'), 'es');
        expect(await load('fr'), 'en');
        expect(await namesIn(dataDir), ['settings.json']);
        expect(await settingsFile.readAsString(), content);
      });
    }

    test(
      'bytes that are not UTF-8 fall back to the Windows language',
      () async {
        await settingsFile.writeAsBytes(const [0xFF, 0xFE, 0x00, 0xC3]);

        expect(await load('es'), 'es');
        expect(await load('de'), 'en');
      },
    );

    test('a folder named settings.json falls back without throwing', () async {
      await Directory(settingsFile.path).create();

      expect(await load('es'), 'es');
      expect(await load('fr'), 'en');
    });

    test('a data folder that does not exist falls back and is not '
        'created', () async {
      final missing = Directory(
        '${dataDir.path}${Platform.pathSeparator}missing',
      );

      expect(
        await loadLanguage(platformLanguageCode: 'es', dataDir: missing),
        'es',
      );
      expect(
        await loadLanguage(platformLanguageCode: 'fr', dataDir: missing),
        'en',
      );
      expect(await missing.exists(), isFalse);
    });

    test('with no dataDir it uses the real environment and does not '
        'throw', () async {
      final language = await loadLanguage(platformLanguageCode: 'es');

      expect(language, isIn(['es', 'en']));
    });

    test('with no dataDir and no LOCALAPPDATA it falls back to the Windows '
        'language', () async {
      final packageConfig = await Isolate.packageConfig;
      expect(packageConfig, isNotNull);
      final script = File(
        '${dataDir.path}${Platform.pathSeparator}load_language.dart',
      );
      await script.writeAsString('''
import 'package:nexus_bridges_core/src/settings/settings.dart';

Future<void> main(List<String> args) async {
  for (final code in args) {
    print(await loadLanguage(platformLanguageCode: code));
  }
}
''');
      final environment = Map.of(Platform.environment)
        ..removeWhere((key, _) => key.toUpperCase() == 'LOCALAPPDATA');

      final result = await Process.run(
        Platform.resolvedExecutable,
        [
          '--packages=${packageConfig!.toFilePath()}',
          script.path,
          'es',
          'fr',
          'en',
        ],
        environment: environment,
        includeParentEnvironment: false,
      );

      expect(result.exitCode, 0, reason: '${result.stderr}');
      expect(const LineSplitter().convert('${result.stdout}'), [
        'es',
        'en',
        'en',
      ]);
    }, timeout: const Timeout(Duration(minutes: 2)));
  });
}
