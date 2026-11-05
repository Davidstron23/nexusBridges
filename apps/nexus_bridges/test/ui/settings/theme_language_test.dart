import 'dart:async';
import 'dart:ui' show AppExitResponse;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nexus_bridges/main.dart';
import 'package:nexus_bridges/src/l10n/app_strings.dart';
import 'package:nexus_bridges/src/ui/home_screen.dart';
import 'package:nexus_bridges/src/ui/modal/modal_frame.dart';
import 'package:nexus_bridges/src/ui/theme/app_theme.dart';
import 'package:nexus_bridges/src/ui/theme/tokens.dart';
import 'package:nexus_bridges/src/window/title_bar_sync.dart';
import 'package:nexus_bridges_core/nexus_bridges_core.dart';

import '../fake_app_controller.dart';
import '../fake_window_host.dart';
import '../pairing_fixtures.dart' show view;
import '../segoe_font.dart';
import '../transfer_fixtures.dart'
    show buttonIn, incomingView, isEnabled, outgoingView, senderName;
import 'settings_fixtures.dart';

Future<(FakeAppController, FakeWindowHost)> _pumpApp(
  WidgetTester tester, {
  String code = 'es',
  ThemeChoice theme = ThemeChoice.dark,
  NodeState? state,
  bool closeToTray = true,
}) async {
  setSize(tester, const Size(1200, 800));
  final controller = FakeAppController(
    state: state ?? settingsState(),
    languageCode: code,
    theme: theme,
    closeToTray: closeToTray,
  );
  final host = FakeWindowHost();
  await tester.pumpWidget(NexusBridgesApp(controller, windowHost: host));
  await tester.pump();
  await tester.pump(const Duration(seconds: 1));
  return (controller, host);
}

NbColors _colors(WidgetTester tester) =>
    NbColors.of(tester.element(find.byType(HomeScreen)));

void _reduceMotion(WidgetTester tester) {
  tester.platformDispatcher.accessibilityFeaturesTestValue =
      const FakeAccessibilityFeatures(disableAnimations: true);
  addTearDown(tester.platformDispatcher.clearAccessibilityFeaturesTestValue);
}

void _platformBrightness(WidgetTester tester, Brightness brightness) {
  tester.platformDispatcher.platformBrightnessTestValue = brightness;
  addTearDown(tester.platformDispatcher.clearPlatformBrightnessTestValue);
}

Future<Map<String, Object?>> _requestExit(WidgetTester tester) {
  final reply = Completer<Map<String, Object?>>();
  unawaited(
    tester.binding.defaultBinaryMessenger.handlePlatformMessage(
      SystemChannels.platform.name,
      SystemChannels.platform.codec.encodeMethodCall(
        const MethodCall('System.requestAppExit'),
      ),
      (data) {
        final decoded = SystemChannels.platform.codec.decodeEnvelope(data!);
        reply.complete(Map<String, Object?>.from(decoded as Map));
      },
    ),
  );
  return reply.future;
}

void main() {
  setUpAll(loadSegoe);

  group('E855 the theme changes with a 500 ms fade (RF-511)', () {
    testWidgets('from Dark to Light: at 250 ms in between, at 500 ms the '
        'light one; the title bar follows at 250 ms', (tester) async {
      final (controller, host) = await _pumpApp(tester);
      expect(_colors(tester).ground, NbColors.dark.ground);
      expect(host.darkTitleBar, isEmpty);

      unawaited(controller.setTheme(ThemeChoice.light));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 249));
      expect(host.darkTitleBar, isEmpty);
      await tester.pump(const Duration(milliseconds: 1));
      final middle = _colors(tester).ground;
      expect(middle, isNot(NbColors.dark.ground));
      expect(middle, isNot(NbColors.light.ground));
      expect(host.darkTitleBar, [false]);

      await tester.pump(const Duration(milliseconds: 260));
      expect(_colors(tester).ground, NbColors.light.ground);
      final app = tester.widget<MaterialApp>(find.byType(MaterialApp));
      expect(app.themeMode, ThemeMode.light);
      expect(app.themeAnimationDuration, themeFade);
      expect(app.themeAnimationCurve, Curves.easeInOut);

      unawaited(controller.setTheme(ThemeChoice.dark));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 250));
      expect(host.darkTitleBar, [false, true]);
      await tester.pump(const Duration(milliseconds: 300));
      expect(_colors(tester).ground, NbColors.dark.ground);
    });

    testWidgets('with less motion the light theme and the bar change at '
        'once', (tester) async {
      _reduceMotion(tester);
      final (controller, host) = await _pumpApp(tester);

      unawaited(controller.setTheme(ThemeChoice.light));
      await tester.pump();
      await tester.pump();
      expect(_colors(tester).ground, NbColors.light.ground);
      expect(host.darkTitleBar, [false]);
      expect(
        tester
            .widget<MaterialApp>(find.byType(MaterialApp))
            .themeAnimationDuration,
        Duration.zero,
      );
    });

    testWidgets('with Windows the theme follows platformBrightness live and '
        'the bar too; switching between two modes that look the same does '
        'not touch the bar', (tester) async {
      _platformBrightness(tester, Brightness.dark);
      final (controller, host) = await _pumpApp(tester);

      unawaited(controller.setTheme(ThemeChoice.system));
      await tester.pump(const Duration(seconds: 1));
      expect(host.darkTitleBar, isEmpty);
      expect(_colors(tester).ground, NbColors.dark.ground);

      tester.platformDispatcher.platformBrightnessTestValue = Brightness.light;
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));
      expect(_colors(tester).ground, NbColors.light.ground);
      expect(host.darkTitleBar, [false]);

      tester.platformDispatcher.platformBrightnessTestValue = Brightness.dark;
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));
      expect(_colors(tester).ground, NbColors.dark.ground);
      expect(host.darkTitleBar, [false, true]);

      unawaited(controller.setTheme(ThemeChoice.light));
      await tester.pump(const Duration(seconds: 1));
      expect(host.darkTitleBar, [false, true, false]);
      tester.platformDispatcher.platformBrightnessTestValue = Brightness.dark;
      await tester.pump(const Duration(seconds: 1));
      expect(host.darkTitleBar, [false, true, false]);
      expect(_colors(tester).ground, NbColors.light.ground);
    });

    test('effectiveDarkOf: Dark and Light ignore Windows; Windows follows '
        'it', () {
      for (final platform in Brightness.values) {
        expect(effectiveDarkOf(ThemeChoice.dark, platform), isTrue);
        expect(effectiveDarkOf(ThemeChoice.light, platform), isFalse);
      }
      expect(effectiveDarkOf(ThemeChoice.system, Brightness.dark), isTrue);
      expect(effectiveDarkOf(ThemeChoice.system, Brightness.light), isFalse);
    });

    test('themeModeOf maps each choice to its ThemeMode', () {
      expect(themeModeOf(ThemeChoice.dark), ThemeMode.dark);
      expect(themeModeOf(ThemeChoice.light), ThemeMode.light);
      expect(themeModeOf(ThemeChoice.system), ThemeMode.system);
    });

    testWidgets('TitleBarSync after dispose no longer calls the host', (
      tester,
    ) async {
      final controller = FakeAppController(state: const NodeState());
      final host = FakeWindowHost();
      final sync = TitleBarSync(host: host, controller: controller)..start();
      sync.dispose();
      await controller.setTheme(ThemeChoice.light);
      await tester.pump(const Duration(seconds: 1));
      expect(host.darkTitleBar, isEmpty);
    });

    testWidgets('two quick changes never send the value that was left behind', (
      tester,
    ) async {
      final controller = FakeAppController(state: const NodeState());
      final host = FakeWindowHost();
      final sync = TitleBarSync(host: host, controller: controller)..start();
      addTearDown(sync.dispose);

      await controller.setTheme(ThemeChoice.light);
      await tester.pump(const Duration(milliseconds: 100));
      await controller.setTheme(ThemeChoice.dark);
      await tester.pump(const Duration(seconds: 1));
      expect(host.darkTitleBar, isNot(contains(false)));
    });
  });

  group('E856 NbColors.lerp also blends the shadows (RF-511, S10)', () {
    test('at 0 and 1 the shadows that can be seen are the ends and at 0.5 '
        'they differ from both', () {
      List<List<BoxShadow>> shadows(NbColors c) => [
        for (final list in _shadowLists(c))
          [
            for (final shadow in list)
              if (shadow.offset != Offset.zero ||
                  shadow.blurRadius != 0 ||
                  shadow.spreadRadius != 0)
                shadow,
          ],
      ];
      List<List<BoxShadow>> raw(NbColors c) => _shadowLists(c);
      expect(raw(NbColors.light.lerp(NbColors.dark, 0)), raw(NbColors.light));
      final light = shadows(NbColors.light);
      final dark = shadows(NbColors.dark);
      expect(shadows(NbColors.light.lerp(NbColors.dark, 0)), light);
      expect(shadows(NbColors.light.lerp(NbColors.dark, 1)), dark);
      final middle = shadows(NbColors.light.lerp(NbColors.dark, 0.5));
      for (var i = 0; i < light.length; i++) {
        if (listEquals(light[i], dark[i])) continue;
        expect(middle[i], isNot(light[i]), reason: 'shadow $i');
        expect(middle[i], isNot(dark[i]), reason: 'shadow $i');
      }
    });
  });

  group('E854 the language changes without closing anything (RF-510)', () {
    testWidgets('with a stranger warning on screen: English from Settings '
        'calls setLanguage once, the card stays, in English and armed', (
      tester,
    ) async {
      final es = stringsFor('es');
      final en = stringsFor('en');
      final (controller, _) = await _pumpApp(
        tester,
        state: settingsState(incoming: incomingView()),
      );
      final card = find.ancestor(
        of: find.text(es.incomingRequestTitle(senderName)),
        matching: find.byType(Card),
      );
      expect(isEnabled(tester, buttonIn(card.first, es.acceptButton)), isTrue);

      await openSettings(tester, es);
      await tester.tap(
        inSection(es.sectionLanguage, find.text(es.languageEnglish)),
      );
      await tester.pumpAndSettle();
      expect(controller.calls, ['setLanguage en']);
      expect(sectionOf(en.sectionLanguage), findsOneWidget);
      expect(find.text(en.settingsTitle), findsOneWidget);

      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 600));
      final english = find.ancestor(
        of: find.text(en.incomingRequestTitle(senderName)),
        matching: find.byType(Card),
      );
      expect(english, findsWidgets);
      expect(find.text(es.incomingRequestTitle(senderName)), findsNothing);
      expect(
        isEnabled(tester, buttonIn(english.first, en.acceptButton)),
        isTrue,
      );
      expect(controller.calls, ['setLanguage en']);
    });

    testWidgets('a pairing dialog stays open, the same route, in English and '
        'without arming again', (tester) async {
      final es = stringsFor('es');
      final en = stringsFor('en');
      final (controller, _) = await _pumpApp(
        tester,
        state: settingsState(
          pairing: view(
            role: PairingRole.receiver,
            phase: PairingPhase.comparing,
          ),
        ),
      );
      expect(find.byType(NbModal), findsOneWidget);
      final route = ModalRoute.of(tester.element(find.byType(NbModal)));
      final before = _modalTexts(tester);
      expect(before, isNotEmpty);
      final armedBefore = _modalButtonsEnabled(tester);

      unawaited(controller.setLanguage('en'));
      await tester.pump();

      expect(find.byType(NbModal), findsOneWidget);
      expect(ModalRoute.of(tester.element(find.byType(NbModal))), same(route));
      expect(_modalTexts(tester), isNot(before));
      expect(_modalButtonsEnabled(tester), armedBefore);
      expect(en.appTitle, es.appTitle);
    });

    testWidgets('the close confirmation during a transfer stays open and '
        'switches to English', (tester) async {
      final es = stringsFor('es');
      final en = stringsFor('en');
      final (controller, _) = await _pumpApp(
        tester,
        closeToTray: false,
        state: NodeState(
          transferInProgress: true,
          outgoing: outgoingView(),
          trustedNetworks: [networkView()],
        ),
      );
      final reply = _requestExit(tester);
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));
      expect(find.text(es.closeDuringTransferTitle), findsOneWidget);

      unawaited(controller.setLanguage('en'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.text(en.closeDuringTransferTitle), findsOneWidget);
      expect(find.text(es.closeDuringTransferTitle), findsNothing);

      await tester.tap(find.text(en.keepOpenButton));
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));
      final answer = await reply;
      expect(answer['response'], AppExitResponse.cancel.name);
      expect(controller.calls, ['setLanguage en']);
    });
  });
}

List<String> _modalTexts(WidgetTester tester) => [
  for (final text in tester.widgetList<Text>(
    find.descendant(of: find.byType(NbModal), matching: find.byType(Text)),
  ))
    text.data ?? text.textSpan?.toPlainText() ?? '',
];

List<bool> _modalButtonsEnabled(WidgetTester tester) => [
  for (final button in tester.widgetList<ButtonStyleButton>(
    find.descendant(
      of: find.byType(NbModal),
      matching: find.byWidgetPredicate((widget) => widget is ButtonStyleButton),
    ),
  ))
    button.onPressed != null,
];

List<List<BoxShadow>> _shadowLists(NbColors c) => [
  c.cardShadow,
  c.popoverShadow,
  c.discShadow,
  c.keyShadow,
  c.okShadow,
  c.primaryButtonShadow,
  c.primaryButtonHoverShadow,
  c.dangerButtonHoverShadow,
  c.menuShadow,
  c.softButtonHoverShadow,
];
