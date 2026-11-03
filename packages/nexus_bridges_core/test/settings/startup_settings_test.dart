import 'dart:convert';
import 'dart:io';

import 'package:nexus_bridges_core/src/settings/settings.dart';
import 'package:nexus_bridges_core/src/storage/storage.dart';
import 'package:test/test.dart';

List<Object?> _shape(StartupSettings s) => [
  s.language,
  s.theme,
  s.closeToTray,
  s.trayHintShown,
];

void main() {
  final sep = Platform.pathSeparator;
  late Directory dataDir;
  late File settingsFile;

  setUp(() async {
    dataDir = await Directory.systemTemp.createTemp('nexus_008_startup_');
    addTearDown(() => dataDir.delete(recursive: true));
    settingsFile = File('${dataDir.path}${sep}settings.json');
  });

  SettingsStore store() => SettingsStore(JsonFileStore(settingsFile));

  Future<Map<String, Object?>> saved() async =>
      jsonDecode(await settingsFile.readAsString()) as Map<String, Object?>;

  group('E814: the saved settings come back at start (RF-502, RF-504, '
      'RF-510, RF-511)', () {
    test('language, theme, close to tray and the tray hint written by the '
        'store are what loadStartupSettings gives back', () async {
      final settings = store();
      expect(await settings.writeLanguage('en'), isTrue);
      expect(await settings.writeTheme(ThemeChoice.light), isTrue);
      expect(await settings.writeCloseToTray(false), isTrue);
      expect(await settings.writeTrayHintShown(), isTrue);

      final loaded = await loadStartupSettings(
        platformLanguageCode: 'es',
        dataDir: dataDir,
      );

      expect(_shape(loaded), ['en', ThemeChoice.light, false, true]);
      expect(await saved(), {
        'version': 1,
        'language': 'en',
        'theme': 'light',
        'closeToTray': false,
        'trayHintShown': true,
      });
    });

    test('each theme is written by its name and read back', () async {
      for (final theme in ThemeChoice.values) {
        expect(await store().writeTheme(theme), isTrue);
        expect((await saved())['theme'], theme.name);
        final loaded = await loadStartupSettings(
          platformLanguageCode: 'es',
          dataDir: dataDir,
        );
        expect(loaded.theme, theme);
      }
    });

    test('the four writes launched at once keep every key and the keys of '
        'the other settings', () async {
      await settingsFile.writeAsString(
        jsonEncode({'version': 1, 'deviceName': 'PC David', 'futuro': 1}),
      );
      final settings = store();

      final results = await Future.wait([
        settings.writeLanguage('es'),
        settings.writeTheme(ThemeChoice.system),
        settings.writeCloseToTray(true),
        settings.writeTrayHintShown(),
      ]);

      expect(results, everyElement(isTrue));
      expect(await saved(), {
        'version': 1,
        'deviceName': 'PC David',
        'futuro': 1,
        'language': 'es',
        'theme': 'system',
        'closeToTray': true,
        'trayHintShown': true,
      });
    });

    test('without a file: the platform language, dark, close to tray on and '
        'the hint not shown, and nothing is written', () async {
      final spanish = await loadStartupSettings(
        platformLanguageCode: 'es',
        dataDir: dataDir,
      );
      final other = await loadStartupSettings(
        platformLanguageCode: 'fr',
        dataDir: dataDir,
      );

      expect(_shape(spanish), ['es', ThemeChoice.dark, true, false]);
      expect(_shape(other), ['en', ThemeChoice.dark, true, false]);
      expect(settingsFile.existsSync(), isFalse);
    });

    test('without the data folder: the same defaults, without throwing and '
        'without creating it', () async {
      final missing = Directory('${dataDir.path}${sep}missing');

      final loaded = await loadStartupSettings(
        platformLanguageCode: 'es',
        dataDir: missing,
      );

      expect(_shape(loaded), ['es', ThemeChoice.dark, true, false]);
      expect(missing.existsSync(), isFalse);
    });

    test('a data folder that is a file gives the defaults without '
        'throwing', () async {
      final blocker = File('${dataDir.path}${sep}blocker');
      await blocker.writeAsString('x');

      final loaded = await loadStartupSettings(
        platformLanguageCode: 'en',
        dataDir: Directory(blocker.path),
      );

      expect(_shape(loaded), ['en', ThemeChoice.dark, true, false]);
      expect(await blocker.readAsString(), 'x');
    });

    test(
      'a broken settings.json gives the defaults without throwing',
      () async {
        await settingsFile.writeAsString('{not json');

        final loaded = await loadStartupSettings(
          platformLanguageCode: 'es',
          dataDir: dataDir,
        );

        expect(_shape(loaded), ['es', ThemeChoice.dark, true, false]);
      },
    );

    test('a damaged key falls back alone: closeToTray "yes" is on and the '
        'rest is read', () async {
      await settingsFile.writeAsString(
        jsonEncode({
          'version': 1,
          'language': 'en',
          'theme': 'system',
          'closeToTray': 'yes',
          'trayHintShown': true,
        }),
      );

      final loaded = await loadStartupSettings(
        platformLanguageCode: 'es',
        dataDir: dataDir,
      );

      expect(_shape(loaded), ['en', ThemeChoice.system, true, true]);
    });

    test('with settings.json as a folder the writes give false and do not '
        'throw', () async {
      await Directory(settingsFile.path).create();
      final settings = store();

      expect(await settings.writeLanguage('en'), isFalse);
      expect(await settings.writeTheme(ThemeChoice.light), isFalse);
      expect(await settings.writeCloseToTray(false), isFalse);
      expect(await settings.writeTrayHintShown(), isFalse);
      expect(await settings.writeExclusions(const ['dist']), isFalse);
    });
  });

  group('writeExclusions (RF-518, RF-520)', () {
    test('a list is saved and read back, also an empty one', () async {
      final settings = store();

      expect(await settings.writeExclusions(const ['dist', '.git']), isTrue);
      expect(await settings.readExclusions(), ['dist', '.git']);
      expect(await settings.writeExclusions(const []), isTrue);
      expect(await settings.readExclusions(), isEmpty);
      expect((await saved())['exclusions'], isEmpty);
    });

    test('a list of 65 names is not written', () async {
      final settings = store();
      await settings.writeExclusions(const ['dist']);

      expect(
        await settings.writeExclusions([for (var i = 0; i < 65; i++) 'n$i']),
        isFalse,
      );
      expect(await settings.readExclusions(), ['dist']);
    });
  });
}
