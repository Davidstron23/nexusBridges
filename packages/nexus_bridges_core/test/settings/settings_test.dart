import 'dart:io';

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
}
