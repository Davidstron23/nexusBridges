import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:nexus_bridges/src/app_controller.dart';
import 'package:nexus_bridges_core/nexus_bridges_core.dart';

final class _XorProtector implements SecretProtector {
  static Uint8List _xor(Uint8List data) =>
      Uint8List.fromList([for (final b in data) b ^ 0x5A]);

  @override
  Uint8List protect(Uint8List data) => _xor(data);

  @override
  Uint8List? unprotect(Uint8List data) => _xor(data);
}

AppController _withoutNode({Future<StartupSettings> Function()? loadStartup}) =>
    AppController(
      startNode: () async => throw StateError('no node in this test'),
      loadStartup:
          loadStartup ?? () async => const StartupSettings(language: 'es'),
    );

Future<void> _deleteWithRetry(Directory directory) async {
  for (var attempt = 0; attempt < 40; attempt++) {
    try {
      if (directory.existsSync()) await directory.delete(recursive: true);
      return;
    } on FileSystemException {
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
  }
}

void main() {
  group(
    'T5a AppController keeps theme, language and tray (RF-502, RF-504)',
    () {
      test('init takes what loadStartup read', () async {
        final controller = _withoutNode(
          loadStartup: () async => const StartupSettings(
            language: 'es',
            theme: ThemeChoice.light,
            closeToTray: false,
            trayHintShown: true,
          ),
        );
        await controller.init();
        expect(controller.languageCode, 'es');
        expect(controller.theme, ThemeChoice.light);
        expect(controller.closeToTray, isFalse);
        expect(controller.trayHintShown, isTrue);
      });

      test('if loadStartup fails: English, Dark and the tray on', () async {
        final controller = _withoutNode(
          loadStartup: () async => throw const FileSystemException('broken'),
        );
        await controller.init();
        expect(controller.languageCode, 'en');
        expect(controller.theme, ThemeChoice.dark);
        expect(controller.closeToTray, isTrue);
      });

      test('setTheme, setLanguage and setCloseToTray change the value at once '
          'and notify once; the same value does not notify', () async {
        final controller = _withoutNode();
        await controller.init();
        var notified = 0;
        controller.addListener(() => notified++);

        final theme = controller.setTheme(ThemeChoice.system);
        expect(controller.theme, ThemeChoice.system);
        await theme;
        await controller.setTheme(ThemeChoice.system);
        final language = controller.setLanguage('en');
        expect(controller.languageCode, 'en');
        await language;
        await controller.setLanguage('en');
        final tray = controller.setCloseToTray(false);
        expect(controller.closeToTray, isFalse);
        await tray;
        await controller.setCloseToTray(false);
        expect(notified, 3);
      });

      test('without a node every new operation gives its neutral value and '
          'never throws', () async {
        final controller = _withoutNode();
        await controller.init();
        expect(
          await controller.setDeviceName('PC'),
          const DeviceNameResult(saved: false),
        );
        expect(controller.namesakeOf('PC'), isNull);
        expect(
          await controller.addExclusion('dist'),
          const ExclusionOutcome(saved: false),
        );
        await controller.removeExclusion('dist');
        await controller.restoreExclusions();
        expect(
          await controller.changeReceiveFolder(),
          isA<FolderChangeBlocked>(),
        );
        expect(
          await controller.confirmReceiveFolder('c1'),
          isA<FolderChangeBlocked>(),
        );
        controller.cancelReceiveFolderChange('c1');
        await controller.stopUsingNetwork('{N}');
      });
    },
  );

  group('T5a to T7 with a real node: the settings are saved and read back '
      '(RF-502)', () {
    late Directory root;

    setUp(() async {
      root = await Directory.systemTemp.createTemp('nexus_app_settings_ctl_');
    });

    tearDown(() => _deleteWithRetry(root));

    test(
      'theme, language, tray, name and exclusions survive a new start',
      () async {
        final dataDir = Directory('${root.path}${Platform.pathSeparator}data');
        Future<NexusNode> start() => NexusNode.start(
          dataDir: dataDir,
          protector: _XorProtector(),
          readNetworks: () async => const [],
          port: 0,
          deviceName: 'Test PC',
        );
        final controller = AppController(
          startNode: start,
          loadStartup: () =>
              loadStartupSettings(platformLanguageCode: 'es', dataDir: dataDir),
        );
        await controller.init();
        expect(controller.state, isNotNull);

        await controller.setTheme(ThemeChoice.light);
        await controller.setLanguage('en');
        await controller.setCloseToTray(false);
        expect(
          await controller.setDeviceName('PC David'),
          const DeviceNameResult(),
        );
        expect(await controller.addExclusion('dist'), const ExclusionOutcome());
        expect(
          (await controller.addExclusion('DIST')).problem,
          ExclusionProblem.duplicate,
        );
        expect(
          (await controller.setDeviceName('PC\u{202E}x')).problem,
          DeviceNameProblem.invalidCharacters,
        );
        await controller.shutdown();

        final read = await loadStartupSettings(
          platformLanguageCode: 'es',
          dataDir: dataDir,
        );
        expect(read.theme, ThemeChoice.light);
        expect(read.language, 'en');
        expect(read.closeToTray, isFalse);

        final again = AppController(
          startNode: start,
          loadStartup: () async => read,
        );
        await again.init();
        expect(again.theme, ThemeChoice.light);
        expect(again.state!.deviceName, 'PC David');
        expect(again.state!.settings.customName, 'PC David');
        expect(again.state!.settings.exclusions, contains('dist'));
        await again.shutdown();
      },
    );
  });
}
