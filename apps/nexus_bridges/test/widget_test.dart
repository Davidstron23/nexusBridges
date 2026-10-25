import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' show AppExitResponse;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nexus_bridges/main.dart';
import 'package:nexus_bridges/src/app_controller.dart';
import 'package:nexus_bridges/src/l10n/app_strings.dart';
import 'package:nexus_bridges/src/l10n/app_strings_en.dart';
import 'package:nexus_bridges/src/l10n/app_strings_es.dart';
import 'package:nexus_bridges/src/ui/home_screen.dart';
import 'package:nexus_bridges_core/nexus_bridges_core.dart';

class TestAppController extends AppController {
  TestAppController({
    String languageCode = 'en',
    NodeState? state = const NodeState(),
    this._onShutdown,
  }) : _testLanguageCode = languageCode,
       _testState = state,
       super(
         startNode: () async => throw StateError('not used by app tests'),
         loadLanguage: () async => languageCode,
       );

  final String _testLanguageCode;
  final NodeState? _testState;
  final Future<void> Function()? _onShutdown;
  int shutdownCalls = 0;

  @override
  NodeState? get state => _testState;

  @override
  String get languageCode => _testLanguageCode;

  @override
  Future<void> shutdown() async {
    shutdownCalls++;
    await _onShutdown?.call();
  }
}

const Map<String, ({String devicesTitle, String noDevicesYet})>
expectedTexts = {
  'es': (devicesTitle: 'Equipos cerca', noDevicesYet: 'Todavía no hay equipos'),
  'en': (devicesTitle: 'Devices nearby', noDevicesYet: 'No devices found yet'),
};

String otherLanguage(String code) => code == 'es' ? 'en' : 'es';

Future<void> pumpApp(WidgetTester tester, AppController controller) async {
  await tester.pumpWidget(NexusBridgesApp(controller));
  await tester.pumpAndSettle();
}

BuildContext homeContext(WidgetTester tester) {
  return tester.element(find.byType(HomeScreen));
}

Future<Map<String, Object?>> sendPlatformExitRequest(
  WidgetTester tester,
) async {
  final reply = Completer<Map<String, Object?>>();
  await tester.binding.defaultBinaryMessenger.handlePlatformMessage(
    SystemChannels.platform.name,
    SystemChannels.platform.codec.encodeMethodCall(
      const MethodCall('System.requestAppExit'),
    ),
    (data) {
      final decoded = SystemChannels.platform.codec.decodeEnvelope(data!);
      reply.complete(Map<String, Object?>.from(decoded as Map));
    },
  );
  return reply.future;
}

void main() {
  testWidgets('the app starts with a test controller and shows devicesTitle', (
    tester,
  ) async {
    await pumpApp(tester, TestAppController());

    expect(find.text('Devices nearby'), findsOneWidget);
    expect(find.byType(HomeScreen), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  group('language (RF-62, RF-63, RF-64)', () {
    for (final code in expectedTexts.keys) {
      testWidgets('with languageCode "$code" the app speaks $code', (
        tester,
      ) async {
        await pumpApp(tester, TestAppController(languageCode: code));

        final expected = expectedTexts[code]!;
        final other = expectedTexts[otherLanguage(code)]!;
        expect(find.text(expected.devicesTitle), findsOneWidget);
        expect(find.text(expected.noDevicesYet), findsOneWidget);
        expect(find.text(other.devicesTitle), findsNothing);
        expect(find.text(other.noDevicesYet), findsNothing);
      });

      testWidgets('with languageCode "$code" the title comes from AppStrings', (
        tester,
      ) async {
        await pumpApp(tester, TestAppController(languageCode: code));

        final title = tester.widget<Title>(find.byType(Title));
        expect(title.title, 'NexusBridges');
        expect(title.title, stringsFor(code).appTitle);
      });

      testWidgets(
        'with languageCode "$code" the locale and the loaded strings match',
        (tester) async {
          await pumpApp(tester, TestAppController(languageCode: code));

          final context = homeContext(tester);
          expect(Localizations.localeOf(context), Locale(code));
          expect(
            AppStringsDelegate.of(context),
            code == 'es' ? isA<AppStringsEs>() : isA<AppStringsEn>(),
          );
        },
      );
    }

    testWidgets('Material widgets follow the language too', (tester) async {
      await pumpApp(tester, TestAppController(languageCode: 'es'));
      final spanish = MaterialLocalizations.of(homeContext(tester))
          .closeButtonLabel;

      await tester.pumpWidget(const SizedBox());
      await pumpApp(tester, TestAppController(languageCode: 'en'));
      final english = MaterialLocalizations.of(homeContext(tester))
          .closeButtonLabel;

      expect(spanish, isNotEmpty);
      expect(english, isNotEmpty);
      expect(spanish, isNot(english));
    });

    for (final code in ['fr', 'pt']) {
      testWidgets('an unsupported languageCode "$code" falls back to English', (
        tester,
      ) async {
        await pumpApp(tester, TestAppController(languageCode: code));

        expect(find.text('Devices nearby'), findsOneWidget);
        expect(find.text('Equipos cerca'), findsNothing);
        expect(Localizations.localeOf(homeContext(tester)), const Locale('en'));
        expect(tester.takeException(), isNull);
      });
    }

    testWidgets('a real AppController with a saved "es" shows Spanish', (
      tester,
    ) async {
      final controller = AppController(
        startNode: () async => throw StateError('no node in this test'),
        loadLanguage: () async => 'es',
      );
      await controller.init();
      await pumpApp(tester, controller);

      expect(controller.languageCode, 'es');
      expect(find.text('Equipos cerca'), findsOneWidget);
      expect(find.text(AppStringsEs().identityFailed), findsOneWidget);
      expect(find.text('Devices nearby'), findsNothing);

      await controller.shutdown();
    });

    testWidgets('a real AppController whose loadLanguage fails shows English', (
      tester,
    ) async {
      final controller = AppController(
        startNode: () async => throw StateError('no node in this test'),
        loadLanguage: () async => throw const FileSystemException('broken'),
      );
      await controller.init();
      await pumpApp(tester, controller);

      expect(find.text('Devices nearby'), findsOneWidget);
      expect(find.text('Equipos cerca'), findsNothing);

      await controller.shutdown();
    });
  });

  group('language chosen by loadLanguage at start (RF-63, RF-64)', () {
    final cases = [
      (saved: null, windows: 'es', shown: 'Equipos cerca'),
      (saved: null, windows: 'fr', shown: 'Devices nearby'),
      (saved: null, windows: 'en', shown: 'Devices nearby'),
      (saved: 'en', windows: 'es', shown: 'Devices nearby'),
      (saved: 'es', windows: 'en', shown: 'Equipos cerca'),
      (saved: 'es', windows: 'fr', shown: 'Equipos cerca'),
    ];

    for (final c in cases) {
      testWidgets(
        'saved ${c.saved ?? 'nothing'} and Windows in ${c.windows} shows '
        '"${c.shown}"',
        (tester) async {
          final controller = await tester.runAsync(() async {
            final dir = await Directory.systemTemp.createTemp('nb_t11_');
            addTearDown(() => dir.delete(recursive: true));
            if (c.saved != null) {
              await File(
                '${dir.path}${Platform.pathSeparator}settings.json',
              ).writeAsString(jsonEncode({'version': 1, 'language': c.saved}));
            }
            final controller = AppController(
              startNode: () async => throw StateError('no node in this test'),
              loadLanguage: () =>
                  loadLanguage(platformLanguageCode: c.windows, dataDir: dir),
            );
            await controller.init();
            return controller;
          });
          await pumpApp(tester, controller!);

          expect(find.text(c.shown), findsOneWidget);
          final hidden = c.shown == 'Equipos cerca'
              ? 'Devices nearby'
              : 'Equipos cerca';
          expect(find.text(hidden), findsNothing);

          await controller.shutdown();
        },
      );
    }
  });

  group('closing the window (RF-51)', () {
    testWidgets('an exit request calls shutdown once and answers exit', (
      tester,
    ) async {
      final controller = TestAppController();
      await pumpApp(tester, controller);
      expect(controller.shutdownCalls, 0);

      final response = await tester.binding.handleRequestAppExit();

      expect(controller.shutdownCalls, 1);
      expect(response, AppExitResponse.exit);
    });

    testWidgets('the answer waits until shutdown has finished', (tester) async {
      final release = Completer<void>();
      final controller = TestAppController(onShutdown: () => release.future);
      await pumpApp(tester, controller);

      AppExitResponse? response;
      final pending = tester.binding.handleRequestAppExit().then(
        (value) => response = value,
      );
      await tester.pump();

      expect(controller.shutdownCalls, 1);
      expect(response, isNull);

      release.complete();
      await pending;

      expect(response, AppExitResponse.exit);
    });

    testWidgets(
      'the platform message System.requestAppExit is answered with exit',
      (tester) async {
        final controller = TestAppController();
        await pumpApp(tester, controller);

        final reply = await sendPlatformExitRequest(tester);

        expect(reply, {'response': 'exit'});
        expect(controller.shutdownCalls, 1);
      },
    );

    testWidgets('each exit request asks the controller to shut down', (
      tester,
    ) async {
      final controller = TestAppController();
      await pumpApp(tester, controller);

      final first = await tester.binding.handleRequestAppExit();
      final second = await tester.binding.handleRequestAppExit();

      expect(first, AppExitResponse.exit);
      expect(second, AppExitResponse.exit);
      expect(controller.shutdownCalls, 2);
    });

    testWidgets('a real AppController whose node never started still exits', (
      tester,
    ) async {
      final controller = AppController(
        startNode: () async => throw StateError('no node in this test'),
        loadLanguage: () async => 'en',
      );
      await controller.init();
      await pumpApp(tester, controller);

      final first = await tester.binding.handleRequestAppExit();
      final second = await tester.binding.handleRequestAppExit();

      expect(first, AppExitResponse.exit);
      expect(second, AppExitResponse.exit);
      expect(tester.takeException(), isNull);
    });

    testWidgets('the exit request uses the current controller', (tester) async {
      final previous = TestAppController();
      final current = TestAppController(languageCode: 'es');
      await pumpApp(tester, previous);
      await pumpApp(tester, current);

      final response = await tester.binding.handleRequestAppExit();

      expect(response, AppExitResponse.exit);
      expect(previous.shutdownCalls, 0);
      expect(current.shutdownCalls, 1);
      expect(find.text('Equipos cerca'), findsOneWidget);
    });

    testWidgets('after unmounting, an exit request no longer calls shutdown', (
      tester,
    ) async {
      final controller = TestAppController();
      await pumpApp(tester, controller);
      await tester.pumpWidget(const SizedBox());

      final response = await tester.binding.handleRequestAppExit();

      expect(controller.shutdownCalls, 0);
      expect(response, AppExitResponse.exit);
      expect(tester.takeException(), isNull);
    });

    testWidgets('a remounted app listens again, only once', (tester) async {
      final first = TestAppController();
      final second = TestAppController();
      await pumpApp(tester, first);
      await tester.pumpWidget(const SizedBox());
      await pumpApp(tester, second);

      await tester.binding.handleRequestAppExit();

      expect(first.shutdownCalls, 0);
      expect(second.shutdownCalls, 1);
    });
  });

  group('closing the window with a stuck or failing shutdown (B2)', () {
    testWidgets('a shutdown that never ends is answered with exit after 5 s', (
      tester,
    ) async {
      final controller = TestAppController(
        onShutdown: () => Completer<void>().future,
      );
      await pumpApp(tester, controller);

      AppExitResponse? response;
      final pending = tester.binding.handleRequestAppExit().then(
        (value) => response = value,
      );
      await tester.pump();
      expect(controller.shutdownCalls, 1);
      expect(response, isNull);

      await tester.pump(const Duration(milliseconds: 4990));
      expect(response, isNull);

      await tester.pump(const Duration(milliseconds: 20));
      expect(response, AppExitResponse.exit);
      await pending;
      expect(controller.shutdownCalls, 1);
      expect(tester.takeException(), isNull);
    });

    testWidgets('a stuck shutdown is still waited for after the old 3 s', (
      tester,
    ) async {
      final controller = TestAppController(
        onShutdown: () => Completer<void>().future,
      );
      await pumpApp(tester, controller);

      AppExitResponse? response;
      final pending = tester.binding.handleRequestAppExit().then(
        (value) => response = value,
      );
      await tester.pump(const Duration(milliseconds: 3010));
      expect(response, isNull);

      await tester.pump(const Duration(seconds: 2));
      expect(response, AppExitResponse.exit);
      await pending;
    });

    testWidgets('a shutdown that never ends answers the platform message', (
      tester,
    ) async {
      final controller = TestAppController(
        onShutdown: () => Completer<void>().future,
      );
      await pumpApp(tester, controller);

      Map<String, Object?>? reply;
      final pending = sendPlatformExitRequest(tester)
          .then((value) => reply = value);
      await tester.pump(const Duration(milliseconds: 4990));
      expect(reply, isNull);

      await tester.pump(const Duration(milliseconds: 20));
      expect(reply, {'response': 'exit'});
      await pending;
      expect(controller.shutdownCalls, 1);
    });

    testWidgets('a shutdown slower than 5 s is not waited for to the end', (
      tester,
    ) async {
      var finished = false;
      final controller = TestAppController(
        onShutdown: () async {
          await Future<void>.delayed(const Duration(seconds: 8));
          finished = true;
        },
      );
      await pumpApp(tester, controller);

      AppExitResponse? response;
      final pending = tester.binding.handleRequestAppExit().then(
        (value) => response = value,
      );
      await tester.pump(const Duration(milliseconds: 5010));
      expect(response, AppExitResponse.exit);
      await pending;
      expect(finished, isFalse);

      await tester.pump(const Duration(seconds: 3));
      expect(finished, isTrue);
      expect(tester.takeException(), isNull);
    });

    testWidgets('a shutdown that ends in 1 s is answered without waiting 5 s', (
      tester,
    ) async {
      final controller = TestAppController(
        onShutdown: () => Future<void>.delayed(const Duration(seconds: 1)),
      );
      await pumpApp(tester, controller);

      AppExitResponse? response;
      final pending = tester.binding.handleRequestAppExit().then(
        (value) => response = value,
      );
      await tester.pump(const Duration(milliseconds: 990));
      expect(response, isNull);

      await tester.pump(const Duration(milliseconds: 20));
      expect(response, AppExitResponse.exit);
      await pending;
    });

    testWidgets('a shutdown that throws is answered with exit', (tester) async {
      final controller = TestAppController(
        onShutdown: () async => throw StateError('shutdown failed'),
      );
      await pumpApp(tester, controller);

      AppExitResponse? response;
      final pending = tester.binding.handleRequestAppExit().then(
        (value) => response = value,
      );
      await tester.pump();
      expect(response, AppExitResponse.exit);
      await pending;
      expect(controller.shutdownCalls, 1);
      expect(tester.takeException(), isNull);
    });

    testWidgets('a shutdown that throws synchronously is answered with exit', (
      tester,
    ) async {
      final controller = TestAppController(
        onShutdown: () => throw const FileSystemException('broken'),
      );
      await pumpApp(tester, controller);

      AppExitResponse? response;
      final pending = tester.binding.handleRequestAppExit().then(
        (value) => response = value,
      );
      await tester.pump();
      expect(response, AppExitResponse.exit);
      await pending;
      expect(controller.shutdownCalls, 1);
      expect(tester.takeException(), isNull);
    });

    testWidgets('a shutdown that throws after a while is answered with exit', (
      tester,
    ) async {
      final controller = TestAppController(
        onShutdown: () async {
          await Future<void>.delayed(const Duration(milliseconds: 500));
          throw StateError('late failure');
        },
      );
      await pumpApp(tester, controller);

      AppExitResponse? response;
      final pending = tester.binding.handleRequestAppExit().then(
        (value) => response = value,
      );
      await tester.pump(const Duration(milliseconds: 490));
      expect(response, isNull);

      await tester.pump(const Duration(milliseconds: 20));
      expect(response, AppExitResponse.exit);
      await pending;
      expect(tester.takeException(), isNull);
    });

    testWidgets('a second request during a stuck shutdown joins the first', (
      tester,
    ) async {
      final controller = TestAppController(
        onShutdown: () => Completer<void>().future,
      );
      await pumpApp(tester, controller);

      final responses = <AppExitResponse>[];
      final first = tester.binding.handleRequestAppExit().then(responses.add);
      await tester.pump(const Duration(seconds: 1));
      final second = tester.binding.handleRequestAppExit().then(responses.add);
      await tester.pump(const Duration(milliseconds: 3990));
      expect(responses, isEmpty);
      expect(controller.shutdownCalls, 1);

      await tester.pump(const Duration(milliseconds: 20));
      expect(responses, [AppExitResponse.exit, AppExitResponse.exit]);
      await first;
      await second;
      expect(controller.shutdownCalls, 1);
    });

    testWidgets('after a stuck shutdown gives up, a new request starts again', (
      tester,
    ) async {
      final controller = TestAppController(
        onShutdown: () => Completer<void>().future,
      );
      await pumpApp(tester, controller);

      final responses = <AppExitResponse>[];
      final first = tester.binding.handleRequestAppExit().then(responses.add);
      await tester.pump(const Duration(milliseconds: 5010));
      expect(responses, [AppExitResponse.exit]);
      await first;

      final second = tester.binding.handleRequestAppExit().then(responses.add);
      await tester.pump();
      expect(controller.shutdownCalls, 2);
      expect(responses, [AppExitResponse.exit]);

      await tester.pump(const Duration(milliseconds: 5010));
      expect(responses, [AppExitResponse.exit, AppExitResponse.exit]);
      await second;
      expect(tester.takeException(), isNull);
    });
  });
}
