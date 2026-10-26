import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nexus_bridges/main.dart';
import 'package:nexus_bridges/src/l10n/app_strings.dart';
import 'package:nexus_bridges/src/ui/home_screen.dart';
import 'package:nexus_bridges/src/ui/theme/app_theme.dart';
import 'package:nexus_bridges/src/ui/theme/components.dart';
import 'package:nexus_bridges/src/ui/theme/tokens.dart';
import 'package:nexus_bridges_core/nexus_bridges_core.dart';

import 'fake_app_controller.dart';

class _LanguageController extends FakeAppController {
  _LanguageController(this._code) : super(state: const NodeState());

  final String _code;

  @override
  String get languageCode => _code;
}

double _contrast(Color a, Color b) {
  final la = a.computeLuminance();
  final lb = b.computeLuminance();
  return (math.max(la, lb) + 0.05) / (math.min(la, lb) + 0.05);
}

Color _hex(int rgb) => Color(0xFF000000 | rgb);

Map<String, Color> _colorsOf(NbColors c) => {
  'primary': c.primary,
  'primaryHover': c.primaryHover,
  'primaryWeak': c.primaryWeak,
  'primaryInk': c.primaryInk,
  'onPrimary': c.onPrimary,
  'hubTop': c.hubTop,
  'hubBottom': c.hubBottom,
  'glow': c.glow,
  'halo': c.halo,
  'success': c.success,
  'successWeak': c.successWeak,
  'onSuccessDisc': c.onSuccessDisc,
  'netSurface': c.netSurface,
  'netDiscTop': c.netDiscTop,
  'netDiscBottom': c.netDiscBottom,
  'warning': c.warning,
  'warningRing': c.warningRing,
  'warningWeak': c.warningWeak,
  'danger': c.danger,
  'dangerWeak': c.dangerWeak,
  'ground': c.ground,
  'card': c.card,
  'surfaceWeak': c.surfaceWeak,
  'track': c.track,
  'nodeTop': c.nodeTop,
  'nodeBottom': c.nodeBottom,
  'border': c.border,
  'borderWeak': c.borderWeak,
  'text': c.text,
  'textWeak': c.textWeak,
  'hint': c.hint,
  'tooltip': c.tooltip,
  'successInk': c.successInk,
  'primaryButton': c.primaryButton,
  'nodeShadow': c.nodeShadow,
};

final Map<String, (Color, Color)> _designColors = {
  'primary': (_hex(0x6D4AFF), _hex(0x8A6EFF)),
  'primaryHover': (_hex(0x5B3AEB), _hex(0x9D85FF)),
  'primaryWeak': (_hex(0xEEEBFF), const Color.fromRGBO(138, 110, 255, 0.18)),
  'primaryInk': (_hex(0x5B3AEB), _hex(0xA891FF)),
  'onPrimary': (_hex(0xFFFFFF), _hex(0xFFFFFF)),
  'hubTop': (_hex(0x7B5CFF), _hex(0x9479FF)),
  'hubBottom': (_hex(0x5A35F0), _hex(0x6D4AFF)),
  'glow': (
    const Color.fromRGBO(109, 74, 255, 0.16),
    const Color.fromRGBO(138, 110, 255, 0.24),
  ),
  'halo': (
    const Color.fromRGBO(109, 74, 255, 0.07),
    const Color.fromRGBO(138, 110, 255, 0.06),
  ),
  'success': (_hex(0x178567), _hex(0x3DD6A9)),
  'successWeak': (_hex(0xE2F4EC), const Color.fromRGBO(30, 168, 133, 0.16)),
  'onSuccessDisc': (_hex(0xFFFFFF), _hex(0x1F1D27)),
  'netSurface': (_hex(0xE2F4EB), const Color.fromRGBO(30, 168, 133, 0.16)),
  'netDiscTop': (_hex(0x22B08A), _hex(0x5AE8BF)),
  'netDiscBottom': (_hex(0x127256), _hex(0x1EA885)),
  'warning': (_hex(0xA35F00), _hex(0xFFB547)),
  'warningRing': (_hex(0xFF9900), _hex(0xFF9900)),
  'warningWeak': (_hex(0xFFF2DE), const Color.fromRGBO(255, 153, 0, 0.14)),
  'danger': (_hex(0xC2273F), _hex(0xFF6B82)),
  'dangerWeak': (_hex(0xFCE8EB), const Color.fromRGBO(220, 50, 81, 0.18)),
  'ground': (_hex(0xF3F2F7), _hex(0x16141C)),
  'card': (_hex(0xFFFFFF), _hex(0x1F1D27)),
  'surfaceWeak': (_hex(0xF4F3F8), _hex(0x292633)),
  'track': (_hex(0xE9E7F0), _hex(0x33303F)),
  'nodeTop': (_hex(0xFFFFFF), _hex(0x2F2C3B)),
  'nodeBottom': (_hex(0xF3F1FA), _hex(0x262330)),
  'border': (_hex(0xDEDBE7), _hex(0x3A3648)),
  'borderWeak': (_hex(0xECEAF2), _hex(0x2E2B39)),
  'text': (_hex(0x0C0C14), _hex(0xFFFFFF)),
  'textWeak': (_hex(0x5A5766), _hex(0xB4B0C4)),
  'hint': (_hex(0x8B8898), _hex(0x8E8A9E)),
  'tooltip': (_hex(0x0C0C14), _hex(0x0C0C14)),
  'successInk': (_hex(0x127256), _hex(0x3DD6A9)),
  'primaryButton': (_hex(0x6D4AFF), _hex(0x6D4AFF)),
  'nodeShadow': (
    const Color.fromRGBO(42, 31, 107, 0.16),
    const Color.fromRGBO(0, 0, 0, 0.5),
  ),
};

List<(String, Color, Color)> _textPairs(NbColors c) => [
  ('text on card', c.text, c.card),
  ('textWeak on card', c.textWeak, c.card),
  ('text on surfaceWeak', c.text, c.surfaceWeak),
  ('textWeak on surfaceWeak', c.textWeak, c.surfaceWeak),
  (
    'text on netSurface over ground',
    c.text,
    Color.alphaBlend(c.netSurface, c.ground),
  ),
  (
    'textWeak on netSurface over ground',
    c.textWeak,
    Color.alphaBlend(c.netSurface, c.ground),
  ),
  (
    'primaryInk on primaryWeak over card',
    c.primaryInk,
    Color.alphaBlend(c.primaryWeak, c.card),
  ),
  (
    'successInk on successWeak over card',
    c.successInk,
    Color.alphaBlend(c.successWeak, c.card),
  ),
  (
    'danger on dangerWeak over card',
    c.danger,
    Color.alphaBlend(c.dangerWeak, c.card),
  ),
  ('onPrimary on primaryButton', c.onPrimary, c.primaryButton),
  (
    'onPrimary on primaryButton with the hover layer',
    c.onPrimary,
    Color.alphaBlend(c.onPrimary.withValues(alpha: 0.08), c.primaryButton),
  ),
  ('card on text', c.card, c.text),
];

const Map<String, NbColors> _themes = {
  'light': NbColors.light,
  'dark': NbColors.dark,
};

Brightness _brightnessOf(String name) =>
    name == 'dark' ? Brightness.dark : Brightness.light;

Future<void> _pumpThemed(
  WidgetTester tester,
  ThemeData theme,
  Widget child, {
  String languageCode = 'en',
}) async {
  await tester.pumpWidget(
    MaterialApp(
      locale: Locale(languageCode),
      supportedLocales: const [Locale('en'), Locale('es')],
      localizationsDelegates: const [
        AppStringsDelegate(),
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      theme: theme,
      themeAnimationDuration: Duration.zero,
      home: Scaffold(body: Center(child: child)),
    ),
  );
  await tester.pump();
}

Material _materialOf(WidgetTester tester, Finder button) => tester
    .widgetList<Material>(
      find.descendant(of: button, matching: find.byType(Material)),
    )
    .first;

List<String> _uiSources() => [
  for (final entity in Directory(
    'lib${Platform.pathSeparator}src${Platform.pathSeparator}ui',
  ).listSync(recursive: true))
    if (entity is File && entity.path.endsWith('.dart')) entity.path,
];

bool _mayHoldColors(String path) {
  final normalized = path.replaceAll(r'\', '/');
  return normalized.endsWith('/theme/tokens.dart') ||
      normalized.endsWith('/file_icon.dart');
}

void main() {
  group('E253: tokens follow DESIGN.md', () {
    for (final entry in _themes.entries) {
      test('every color of ${entry.key} has the value of the design', () {
        final actual = _colorsOf(entry.value);
        expect(actual.keys.toSet(), _designColors.keys.toSet());
        for (final name in _designColors.keys) {
          final (light, dark) = _designColors[name]!;
          final expected = entry.key == 'dark' ? dark : light;
          expect(actual[name], expected, reason: name);
        }
      });
    }

    test('the shadows follow the shadow vocabulary in light', () {
      expect(NbColors.light.cardShadow, const [
        BoxShadow(
          color: Color.fromRGBO(20, 14, 60, 0.05),
          offset: Offset(0, 1),
          blurRadius: 2,
        ),
        BoxShadow(
          color: Color.fromRGBO(20, 14, 60, 0.06),
          offset: Offset(0, 6),
          blurRadius: 18,
        ),
      ]);
      expect(NbColors.light.popoverShadow, const [
        BoxShadow(color: Color.fromRGBO(20, 14, 60, 0.08), spreadRadius: 1),
        BoxShadow(
          color: Color.fromRGBO(20, 14, 60, 0.18),
          offset: Offset(0, 18),
          blurRadius: 40,
        ),
      ]);
      expect(NbColors.light.discShadow, const [
        BoxShadow(
          color: Color.fromRGBO(18, 114, 86, 0.3),
          offset: Offset(0, 4),
          blurRadius: 10,
        ),
      ]);
    });

    test('the shadows follow the shadow vocabulary in dark', () {
      expect(NbColors.dark.cardShadow, const [
        BoxShadow(
          color: Color.fromRGBO(0, 0, 0, 0.3),
          offset: Offset(0, 1),
          blurRadius: 2,
        ),
        BoxShadow(
          color: Color.fromRGBO(0, 0, 0, 0.25),
          offset: Offset(0, 6),
          blurRadius: 16,
        ),
      ]);
      expect(NbColors.dark.popoverShadow, [
        BoxShadow(color: _hex(0x3A3648), spreadRadius: 1),
        const BoxShadow(
          color: Color.fromRGBO(0, 0, 0, 0.45),
          offset: Offset(0, 18),
          blurRadius: 40,
        ),
      ]);
      expect(NbColors.dark.discShadow, const [
        BoxShadow(
          color: Color.fromRGBO(0, 0, 0, 0.45),
          offset: Offset(0, 4),
          blurRadius: 12,
        ),
      ]);
    });

    test('lerp does not blend: it keeps this below half and takes the '
        'other from half on', () {
      expect(NbColors.light.lerp(NbColors.dark, 0), same(NbColors.light));
      expect(NbColors.light.lerp(NbColors.dark, 0.49), same(NbColors.light));
      expect(NbColors.light.lerp(NbColors.dark, 0.5), same(NbColors.dark));
      expect(NbColors.light.lerp(NbColors.dark, 1), same(NbColors.dark));
      expect(NbColors.light.lerp(null, 0.7), same(NbColors.light));
    });

    test('copyWith changes only the given fields', () {
      final copy = NbColors.light.copyWith(
        text: NbColors.dark.text,
        cardShadow: NbColors.dark.cardShadow,
      );
      expect(copy.text, NbColors.dark.text);
      expect(copy.cardShadow, NbColors.dark.cardShadow);
      final before = _colorsOf(NbColors.light)..remove('text');
      final after = _colorsOf(copy)..remove('text');
      expect(after, before);
      expect(copy.popoverShadow, NbColors.light.popoverShadow);
      expect(copy.discShadow, NbColors.light.discShadow);
    });
  });

  group('E253: every text pair reaches 4.5:1', () {
    for (final entry in _themes.entries) {
      for (final (name, foreground, background) in _textPairs(entry.value)) {
        test('$name in ${entry.key}', () {
          expect(
            _contrast(foreground, background),
            greaterThanOrEqualTo(4.5),
            reason: _contrast(foreground, background).toStringAsFixed(2),
          );
        });
      }

      test('textWeak on card for the hub caption and the "Not visible" chip '
          'of the diagram in ${entry.key} (point 135)', () {
        final c = entry.value;
        expect(_contrast(c.textWeak, c.card), greaterThanOrEqualTo(4.5));
      });
    }

    test('the hover pair is computed with withValues and alphaBlend, and is '
        'lighter than the button (point 147)', () {
      for (final c in _themes.values) {
        final hover = Color.alphaBlend(
          c.onPrimary.withValues(alpha: 0.08),
          c.primaryButton,
        );
        expect(hover, isNot(c.primaryButton));
        expect(
          hover.computeLuminance(),
          greaterThan(c.primaryButton.computeLuminance()),
        );
      }
    });

    test('the plain success green on its chip is below 4.5 in light, which '
        'is why the chip text uses successInk', () {
      final c = NbColors.light;
      expect(
        _contrast(c.success, Color.alphaBlend(c.successWeak, c.card)),
        lessThan(4.5),
      );
    });
  });

  group('E253: buildTheme', () {
    for (final entry in _themes.entries) {
      final brightness = _brightnessOf(entry.key);
      final c = entry.value;

      test('carries the ${entry.key} colors as its extension', () {
        final theme = buildTheme(brightness);
        expect(theme.useMaterial3, isTrue);
        expect(theme.brightness, brightness);
        expect(theme.extension<NbColors>(), same(c));
        expect(theme.scaffoldBackgroundColor, c.ground);
        expect(theme.visualDensity, VisualDensity.standard);
      });

      test('maps the ${entry.key} color scheme as point 112 says', () {
        final scheme = buildTheme(brightness).colorScheme;
        expect(scheme.brightness, brightness);
        expect(scheme.primary, c.primaryButton);
        expect(scheme.onPrimary, c.onPrimary);
        expect(scheme.secondary, c.primary);
        expect(scheme.onSecondary, c.onPrimary);
        expect(scheme.secondaryContainer, c.primaryWeak);
        expect(scheme.onSecondaryContainer, c.primaryInk);
        expect(scheme.error, c.danger);
        expect(scheme.onError, c.onPrimary);
        expect(scheme.surface, c.card);
        expect(scheme.onSurface, c.text);
        expect(scheme.onSurfaceVariant, c.textWeak);
        expect(scheme.surfaceContainerHighest, c.surfaceWeak);
        expect(scheme.outline, c.border);
        expect(scheme.outlineVariant, c.borderWeak);
      });

      test('the ${entry.key} component themes use the tokens', () {
        final theme = buildTheme(brightness);
        expect(theme.cardTheme.color, c.card);
        expect(theme.cardTheme.elevation, 0);
        expect(theme.cardTheme.margin, EdgeInsets.zero);
        expect(theme.cardTheme.surfaceTintColor, Colors.transparent);
        expect(
          theme.cardTheme.shape,
          RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        );
        expect(theme.dialogTheme.backgroundColor, c.card);
        expect(
          theme.dialogTheme.shape,
          RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        );
        expect(theme.popupMenuTheme.color, c.card);
        expect(
          theme.popupMenuTheme.shape,
          RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        );
        final tooltip = theme.tooltipTheme.decoration! as BoxDecoration;
        expect(tooltip.color, c.tooltip);
        expect(theme.progressIndicatorTheme.color, c.primary);
        expect(theme.progressIndicatorTheme.linearTrackColor, c.track);
        expect(theme.dividerTheme.color, c.borderWeak);
        expect(theme.dividerTheme.thickness, 1);
      });

      test('the ${entry.key} brief notification is floating, in text color '
          'with card text', () {
        final snack = buildTheme(brightness).snackBarTheme;
        expect(snack.behavior, SnackBarBehavior.floating);
        expect(snack.backgroundColor, c.text);
        expect(snack.contentTextStyle!.color, c.card);
        expect(snack.contentTextStyle!.fontSize, 13);
        expect(snack.contentTextStyle!.fontWeight, FontWeight.w600);
        expect(
          snack.shape,
          RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
        );
        expect(snack.insetPadding, const EdgeInsets.fromLTRB(16, 0, 16, 22));
      });

      test('the ${entry.key} text theme uses the type scale', () {
        final text = buildTheme(brightness).textTheme;
        expect(text.titleMedium!.fontSize, NbText.title.fontSize);
        expect(text.titleMedium!.color, c.text);
        expect(text.bodyMedium!.fontSize, NbText.body.fontSize);
        expect(text.bodyMedium!.color, c.text);
        expect(text.bodySmall!.fontSize, NbText.caption.fontSize);
        expect(text.bodySmall!.color, c.textWeak);
        expect(text.labelLarge!.fontSize, NbText.button.fontSize);
        expect(text.labelLarge!.fontWeight, NbText.button.fontWeight);
        expect(text.labelMedium!.fontSize, NbText.label.fontSize);
        expect(text.labelSmall!.fontSize, NbText.badge.fontSize);
        expect(text.bodyMedium!.fontFamily, 'Segoe UI Variable Text');
      });

      test('the ${entry.key} default button: card, text and border; hover '
          'on surfaceWeak with a hint border; disabled without border', () {
        final style = buildTheme(brightness).outlinedButtonTheme.style!;
        const idle = <WidgetState>{};
        const hovered = {WidgetState.hovered};
        const disabled = {WidgetState.disabled};
        expect(style.backgroundColor!.resolve(idle), c.card);
        expect(style.foregroundColor!.resolve(idle), c.text);
        expect(style.side!.resolve(idle)!.color, c.border);
        expect(style.side!.resolve(idle)!.width, 1);
        expect(style.backgroundColor!.resolve(hovered), c.surfaceWeak);
        expect(style.side!.resolve(hovered)!.color, c.hint);
        expect(style.backgroundColor!.resolve(disabled), c.surfaceWeak);
        expect(style.foregroundColor!.resolve(disabled), c.hint);
        expect(style.side!.resolve(disabled), BorderSide.none);
      });

      test('the ${entry.key} ghost button: primaryInk text, primaryWeak on '
          'hover, disabled on surfaceWeak with hint text', () {
        final style = buildTheme(brightness).textButtonTheme.style!;
        expect(style.foregroundColor!.resolve({}), c.primaryInk);
        expect(
          style.backgroundColor!.resolve({WidgetState.hovered}),
          c.primaryWeak,
        );
        expect(
          style.backgroundColor!.resolve({WidgetState.disabled}),
          c.surfaceWeak,
        );
        expect(style.foregroundColor!.resolve({WidgetState.disabled}), c.hint);
      });

      test('the ${entry.key} filled buttons set no idle colors and turn '
          'surfaceWeak with hint text when disabled', () {
        final style = buildTheme(brightness).filledButtonTheme.style!;
        expect(style.backgroundColor?.resolve({}), isNull);
        expect(style.foregroundColor?.resolve({}), isNull);
        expect(
          style.backgroundColor!.resolve({WidgetState.disabled}),
          c.surfaceWeak,
        );
        expect(style.foregroundColor!.resolve({WidgetState.disabled}), c.hint);
      });
    }

    test('smallButton is 28 high with 10 of side padding', () {
      expect(smallButton.minimumSize!.resolve({}), const Size(0, 28));
      expect(
        smallButton.padding!.resolve({}),
        const EdgeInsets.symmetric(horizontal: 10),
      );
    });
  });

  group('E253: NbText follows the type scale of the design', () {
    test('sizes, weights and line heights', () {
      final expected = <String, (TextStyle, double, FontWeight, double)>{
        'title': (NbText.title, 15, FontWeight.w600, 20 / 15),
        'titleNet': (NbText.titleNet, 16, FontWeight.w600, 22 / 16),
        'body': (NbText.body, 14, FontWeight.w400, 20 / 14),
        'bodyStrong': (NbText.bodyStrong, 14, FontWeight.w600, 20 / 14),
        'bodySm': (NbText.bodySm, 13, FontWeight.w400, 18 / 13),
        'button': (NbText.button, 13, FontWeight.w600, 1),
        'label': (NbText.label, 12, FontWeight.w600, 16 / 12),
        'caption': (NbText.caption, 12, FontWeight.w400, 16 / 12),
        'badge': (NbText.badge, 11, FontWeight.w600, 18 / 11),
        'fileExt': (NbText.fileExt, 8.5, FontWeight.w700, 1),
      };
      for (final MapEntry(key: name, value: (style, size, weight, height))
          in expected.entries) {
        expect(style.fontSize, size, reason: name);
        expect(style.fontWeight, weight, reason: name);
        expect(style.height, closeTo(height, 1e-9), reason: name);
        expect(style.color, isNull, reason: name);
        expect(style.fontFamilyFallback, ['Segoe UI'], reason: name);
      }
    });

    test('title and fileExt use the display family, the rest the text '
        'family', () {
      expect(NbText.title.fontFamily, 'Segoe UI Variable Display');
      expect(NbText.fileExt.fontFamily, 'Segoe UI Variable Display');
      for (final style in [
        NbText.titleNet,
        NbText.body,
        NbText.bodyStrong,
        NbText.bodySm,
        NbText.button,
        NbText.label,
        NbText.caption,
        NbText.badge,
      ]) {
        expect(style.fontFamily, 'Segoe UI Variable Text');
      }
    });

    test('the caption uses tabular figures', () {
      expect(
        NbText.caption.fontFeatures,
        contains(const FontFeature.tabularFigures()),
      );
    });
  });

  group('E253: the app follows the Windows theme live', () {
    for (final code in languageCodes) {
      testWidgets('NexusBridgesApp switches from light to dark after one '
          'pump, without animation ($code)', (tester) async {
        addTearDown(tester.platformDispatcher.clearPlatformBrightnessTestValue);
        tester.platformDispatcher.platformBrightnessTestValue =
            Brightness.light;
        await tester.pumpWidget(NexusBridgesApp(_LanguageController(code)));
        await tester.pumpAndSettle();

        final app = tester.widget<MaterialApp>(find.byType(MaterialApp));
        expect(app.themeMode, ThemeMode.system);
        expect(app.themeAnimationDuration, Duration.zero);
        expect(app.theme!.extension<NbColors>(), same(NbColors.light));
        expect(app.darkTheme!.extension<NbColors>(), same(NbColors.dark));

        BuildContext home() => tester.element(find.byType(HomeScreen));
        expect(NbColors.of(home()), same(NbColors.light));
        expect(Theme.of(home()).brightness, Brightness.light);
        expect(
          AppStringsDelegate.of(home()).runtimeType,
          stringsFor(code).runtimeType,
        );

        tester.platformDispatcher.platformBrightnessTestValue = Brightness.dark;
        await tester.pump();
        expect(NbColors.of(home()), same(NbColors.dark));
        expect(Theme.of(home()).brightness, Brightness.dark);
        expect(Theme.of(home()).scaffoldBackgroundColor, NbColors.dark.ground);

        tester.platformDispatcher.platformBrightnessTestValue =
            Brightness.light;
        await tester.pump();
        expect(NbColors.of(home()), same(NbColors.light));
        expect(Theme.of(home()).scaffoldBackgroundColor, NbColors.light.ground);
      });

      testWidgets('pumpHome follows the platform brightness too ($code)', (
        tester,
      ) async {
        addTearDown(tester.platformDispatcher.clearPlatformBrightnessTestValue);
        tester.platformDispatcher.platformBrightnessTestValue = Brightness.dark;
        await pumpHome(
          tester,
          FakeAppController(state: const NodeState()),
          code,
        );
        BuildContext home() => tester.element(find.byType(HomeScreen));
        expect(NbColors.of(home()), same(NbColors.dark));
        tester.platformDispatcher.platformBrightnessTestValue =
            Brightness.light;
        await tester.pump();
        expect(NbColors.of(home()), same(NbColors.light));
      });
    }
  });

  group('E253: NbColors.of without the extension', () {
    for (final entry in _themes.entries) {
      testWidgets('gives the ${entry.key} pair from the brightness', (
        tester,
      ) async {
        late NbColors found;
        await tester.pumpWidget(
          MaterialApp(
            theme: ThemeData(brightness: _brightnessOf(entry.key)),
            home: Builder(
              builder: (context) {
                found = NbColors.of(context);
                return const SizedBox();
              },
            ),
          ),
        );
        expect(found, same(entry.value));
      });
    }
  });

  group('E253: button sizes', () {
    for (final entry in _themes.entries) {
      for (final code in languageCodes) {
        testWidgets('a themed button is 32 high and 28 with smallButton '
            '(${entry.key}, $code)', (tester) async {
          final strings = stringsFor(code);
          await _pumpThemed(
            tester,
            buildTheme(_brightnessOf(entry.key)),
            Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                OutlinedButton(
                  key: const ValueKey('outlined'),
                  onPressed: () {},
                  child: Text(strings.acceptButton),
                ),
                OutlinedButton(
                  key: const ValueKey('outlined-small'),
                  style: smallButton,
                  onPressed: () {},
                  child: Text(strings.acceptButton),
                ),
                FilledButton(
                  key: const ValueKey('filled'),
                  onPressed: () {},
                  child: Text(strings.sendFileButton),
                ),
                FilledButton.tonal(
                  key: const ValueKey('tonal'),
                  onPressed: () {},
                  child: Text(strings.rejectButton),
                ),
                TextButton(
                  key: const ValueKey('ghost'),
                  onPressed: () {},
                  child: Text(strings.rejectButton),
                ),
                TextButton(
                  key: const ValueKey('ghost-small'),
                  style: smallButton,
                  onPressed: () {},
                  child: Text(strings.rejectButton),
                ),
              ],
            ),
            languageCode: code,
          );
          for (final key in ['outlined', 'filled', 'tonal', 'ghost']) {
            expect(
              tester.getSize(find.byKey(ValueKey(key))).height,
              32,
              reason: key,
            );
          }
          for (final key in ['outlined-small', 'ghost-small']) {
            expect(
              tester.getSize(find.byKey(ValueKey(key))).height,
              28,
              reason: key,
            );
          }
          expect(tester.takeException(), isNull);
        });
      }

      testWidgets('the primary, soft and disabled buttons paint the '
          '${entry.key} tokens', (tester) async {
        final c = entry.value;
        final strings = stringsFor('en');
        await _pumpThemed(
          tester,
          buildTheme(_brightnessOf(entry.key)),
          Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              FilledButton(
                key: const ValueKey('primary'),
                onPressed: () {},
                child: Text(strings.sendFileButton),
              ),
              FilledButton.tonal(
                key: const ValueKey('soft'),
                onPressed: () {},
                child: Text(strings.rejectButton),
              ),
              FilledButton(
                key: const ValueKey('off'),
                onPressed: null,
                child: Text(strings.acceptButton),
              ),
            ],
          ),
        );
        final primary = _materialOf(
          tester,
          find.byKey(const ValueKey('primary')),
        );
        expect(primary.color, c.primaryButton);
        expect(primary.textStyle!.color, c.onPrimary);
        final soft = _materialOf(tester, find.byKey(const ValueKey('soft')));
        expect(soft.color, c.primaryWeak);
        expect(soft.textStyle!.color, c.primaryInk);
        final off = _materialOf(tester, find.byKey(const ValueKey('off')));
        expect(off.color, c.surfaceWeak);
        expect(off.textStyle!.color, c.hint);
      });
    }
  });

  group('E253: shared components', () {
    for (final code in languageCodes) {
      testWidgets('NbCard is a Card with the card shadow, its padding and an '
          'optional ring ($code)', (tester) async {
        final strings = stringsFor(code);
        final c = NbColors.light;
        await _pumpThemed(
          tester,
          buildTheme(Brightness.light),
          Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              NbCard(
                key: const ValueKey('plain'),
                child: Text(strings.activityEmpty),
              ),
              NbCard(
                key: const ValueKey('ring'),
                ring: c.warningRing,
                child: Text(strings.incomingExpiresNote),
              ),
            ],
          ),
          languageCode: code,
        );
        for (final key in ['plain', 'ring']) {
          final card = find.byKey(ValueKey(key));
          expect(
            find.descendant(of: card, matching: find.byType(Card)),
            findsOneWidget,
          );
          final shadows = tester
              .widgetList<DecoratedBox>(
                find.descendant(of: card, matching: find.byType(DecoratedBox)),
              )
              .map((box) => box.decoration)
              .whereType<BoxDecoration>()
              .where((d) => d.boxShadow != null);
          expect(shadows.first.boxShadow, c.cardShadow);
          expect(shadows.first.borderRadius, BorderRadius.circular(12));
          final padding = tester.widget<Padding>(
            find
                .ancestor(
                  of: find.descendant(of: card, matching: find.byType(Text)),
                  matching: find.byType(Padding),
                )
                .first,
          );
          expect(padding.padding, const EdgeInsets.fromLTRB(16, 14, 16, 14));
        }
        final ringed = tester.widget<Card>(
          find.descendant(
            of: find.byKey(const ValueKey('ring')),
            matching: find.byType(Card),
          ),
        );
        final shape = ringed.shape! as RoundedRectangleBorder;
        expect(shape.side.color, c.warningRing);
        expect(shape.side.width, 1.5);
        expect(shape.side.strokeAlign, BorderSide.strokeAlignInside);
        expect(shape.borderRadius, BorderRadius.circular(12));
        expect(tester.takeException(), isNull);
      });

      testWidgets('StatusChip paints each tone with its tokens, one line, 22 '
          'high ($code)', (tester) async {
        final strings = stringsFor(code);
        for (final entry in _themes.entries) {
          final c = entry.value;
          final tones = <ChipTone, (Color?, Color, Color?)>{
            ChipTone.ok: (c.successWeak, c.successInk, null),
            ChipTone.fail: (c.dangerWeak, c.danger, null),
            ChipTone.run: (c.primaryWeak, c.primaryInk, null),
            ChipTone.wait: (c.surfaceWeak, c.textWeak, null),
            ChipTone.foreign: (c.surfaceWeak, c.textWeak, c.border),
            ChipTone.notVisible: (null, c.textWeak, c.hint),
          };
          await _pumpThemed(
            tester,
            buildTheme(_brightnessOf(entry.key)),
            Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                for (final tone in tones.keys)
                  StatusChip(
                    key: ValueKey(tone),
                    label: strings.chipUnconfirmed,
                    tone: tone,
                    icon: Icon(Icons.check, key: ValueKey('icon-${tone.name}')),
                  ),
              ],
            ),
            languageCode: code,
          );
          for (final MapEntry(key: tone, value: (fill, ink, ring))
              in tones.entries) {
            final chip = find.byKey(ValueKey(tone));
            expect(tester.getSize(chip).height, 22, reason: '$tone');
            final text = tester.widget<Text>(
              find.descendant(of: chip, matching: find.byType(Text)),
            );
            expect(text.data, strings.chipUnconfirmed);
            expect(text.maxLines, 1);
            expect(text.overflow, TextOverflow.ellipsis);
            expect(text.style!.color, ink, reason: '${entry.key} $tone');
            expect(text.style!.fontSize, NbText.label.fontSize);
            expect(text.style!.fontWeight, NbText.label.fontWeight);
            final icon = find.byKey(ValueKey('icon-${tone.name}'));
            expect(
              IconTheme.of(tester.element(icon)).color,
              ink,
              reason: '${entry.key} $tone icon',
            );
            expect(IconTheme.of(tester.element(icon)).size, 12);
            final decoration = tester
                .widgetList<Container>(
                  find.descendant(of: chip, matching: find.byType(Container)),
                )
                .map((box) => box.decoration)
                .whereType<ShapeDecoration>()
                .first;
            expect(decoration.color, fill, reason: '${entry.key} $tone');
            final border = decoration.shape as StadiumBorder;
            if (ring == null) {
              expect(border.side.style, BorderStyle.none);
            } else {
              expect(border.side.color, ring, reason: '${entry.key} $tone');
              expect(border.side.width, 1);
            }
          }
        }
      });

      testWidgets('StatusChip cuts a long label with an ellipsis in a narrow '
          'space ($code)', (tester) async {
        final strings = stringsFor(code);
        await _pumpThemed(
          tester,
          buildTheme(Brightness.light),
          SizedBox(
            width: 60,
            child: Row(
              children: [
                Flexible(
                  child: StatusChip(
                    label: strings.foreignSenderNote('ABCD1234'),
                    tone: ChipTone.foreign,
                  ),
                ),
              ],
            ),
          ),
          languageCode: code,
        );
        expect(tester.takeException(), isNull);
      });

      testWidgets('NbProgressBar is 6 high and fills its share, clamped to '
          '0..1 ($code)', (tester) async {
        final c = NbColors.dark;
        Finder fill(String key) => find.descendant(
          of: find.byKey(ValueKey(key)),
          matching: find.byWidgetPredicate(
            (w) =>
                w is DecoratedBox &&
                w.decoration is BoxDecoration &&
                (w.decoration as BoxDecoration).gradient != null,
          ),
        );
        await _pumpThemed(
          tester,
          buildTheme(Brightness.dark),
          SizedBox(
            width: 200,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                for (final (key, value) in [
                  ('half', 0.5),
                  ('over', 1.7),
                  ('under', -0.3),
                  ('full', 1.0),
                ])
                  NbProgressBar(key: ValueKey(key), value: value),
              ],
            ),
          ),
          languageCode: code,
        );
        for (final key in ['half', 'over', 'under', 'full']) {
          expect(tester.getSize(find.byKey(ValueKey(key))).height, 6);
          expect(tester.getSize(find.byKey(ValueKey(key))).width, 200);
        }
        expect(tester.getSize(fill('half')).width, 100);
        expect(tester.getSize(fill('over')).width, 200);
        expect(tester.getSize(fill('full')).width, 200);
        expect(tester.getSize(fill('under')).width, 0);
        final gradient =
            (tester.widget<DecoratedBox>(fill('half')).decoration
                    as BoxDecoration)
                .gradient!;
        expect(gradient.colors, [c.hubTop, c.primary]);
        final track = tester
            .widgetList<Container>(
              find.descendant(
                of: find.byKey(const ValueKey('half')),
                matching: find.byType(Container),
              ),
            )
            .map((box) => box.decoration)
            .whereType<BoxDecoration>()
            .first;
        expect(track.color, c.track);
        expect(track.borderRadius, BorderRadius.circular(3));
        expect(tester.takeException(), isNull);
      });

      testWidgets('NoticeCard shows the message in body and its actions as '
          'small ghost buttons ($code)', (tester) async {
        final strings = stringsFor(code);
        final c = NbColors.light;
        var pressed = 0;
        await _pumpThemed(
          tester,
          buildTheme(Brightness.light),
          SizedBox(
            width: 280,
            child: NoticeCard(
              message: strings.activityEmpty,
              actions: [
                TextButton(
                  key: const ValueKey('first'),
                  onPressed: () => pressed++,
                  child: Text(strings.closeButton),
                ),
                TextButton(
                  key: const ValueKey('second'),
                  onPressed: () {},
                  child: Text(strings.retryButton),
                ),
              ],
            ),
          ),
          languageCode: code,
        );
        expect(find.byType(Card), findsOneWidget);
        final message = tester.widget<Text>(find.text(strings.activityEmpty));
        expect(message.style!.fontSize, NbText.body.fontSize);
        expect(message.style!.color, c.text);
        expect(
          find.descendant(
            of: find.byType(NoticeCard),
            matching: find.byType(Wrap),
          ),
          findsOneWidget,
        );
        for (final key in ['first', 'second']) {
          expect(tester.getSize(find.byKey(ValueKey(key))).height, 28);
          final material = _materialOf(tester, find.byKey(ValueKey(key)));
          expect(material.textStyle!.color, c.primaryInk);
        }
        final messageBottom = tester
            .getBottomLeft(find.text(strings.activityEmpty))
            .dy;
        final buttonTop = tester
            .getTopLeft(find.byKey(const ValueKey('first')))
            .dy;
        expect(buttonTop - messageBottom, greaterThanOrEqualTo(8));
        await tester.tap(find.byKey(const ValueKey('first')));
        expect(pressed, 1);
        expect(tester.takeException(), isNull);
      });

      testWidgets('NoticeCard without actions shows only the message '
          '($code)', (tester) async {
        final strings = stringsFor(code);
        await _pumpThemed(
          tester,
          buildTheme(Brightness.dark),
          SizedBox(
            width: 280,
            child: NoticeCard(message: strings.activityEmpty),
          ),
          languageCode: code,
        );
        expect(find.text(strings.activityEmpty), findsOneWidget);
        expect(find.byType(Wrap), findsNothing);
        expect(find.byType(TextButton), findsNothing);
      });
    }
  });

  group('E253: colors come only from the tokens', () {
    test('no file of lib/src/ui writes a color literal outside tokens.dart '
        'and file_icon.dart (point 149)', () {
      final sources = _uiSources();
      expect(sources, isNotEmpty);
      for (final path in sources) {
        if (_mayHoldColors(path)) continue;
        final source = File(path).readAsStringSync();
        expect(source.contains('Color(0x'), isFalse, reason: path);
        expect(source.contains('Color.fromRGBO('), isFalse, reason: path);
        expect(source.contains('Color.fromARGB('), isFalse, reason: path);
      }
    });

    test('no file of lib/src/ui uses Colors. other than transparent', () {
      for (final path in _uiSources()) {
        if (_mayHoldColors(path)) continue;
        final source = File(path).readAsStringSync();
        final uses = RegExp(r'\bColors\.(\w+)').allMatches(source);
        for (final use in uses) {
          expect(use.group(1), 'transparent', reason: path);
        }
      }
    });

    test('main.dart no longer seeds the color scheme', () {
      final main = File('lib${Platform.pathSeparator}main.dart')
          .readAsStringSync();
      expect(main.contains('ColorScheme.fromSeed'), isFalse);
      expect(main.contains('Colors.indigo'), isFalse);
    });
  });
}
