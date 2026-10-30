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
  'primaryButtonHover': c.primaryButtonHover,
  'dangerFill': c.dangerFill,
  'ice': c.ice,
  'iceWeak': c.iceWeak,
  'scrim': c.scrim,
  'segment': c.segment,
  'keyFill': c.keyFill,
  'keyOkBorder': c.keyOkBorder,
  'sheen': c.sheen,
  'neutralWeak': c.neutralWeak,
  'stageBorder': c.stageBorder,
  'stageTrack': c.stageTrack,
  'stageWeak': c.stageWeak,
  'stageHint': c.stageHint,
  'stageDashedRing': c.stageDashedRing,
  'buttonHighlight': c.buttonHighlight,
  'buttonHighlightHover': c.buttonHighlightHover,
};

Map<String, double> _numbersOf(NbColors c) => {
  'discTint': c.discTint,
  'haloOpacity': c.haloOpacity,
  'headingWeight': c.headingWeight,
};

Map<String, List<BoxShadow>> _shadowsOf(NbColors c) => {
  'cardShadow': c.cardShadow,
  'popoverShadow': c.popoverShadow,
  'discShadow': c.discShadow,
  'keyShadow': c.keyShadow,
  'okShadow': c.okShadow,
  'primaryButtonShadow': c.primaryButtonShadow,
  'primaryButtonHoverShadow': c.primaryButtonHoverShadow,
  'dangerButtonHoverShadow': c.dangerButtonHoverShadow,
};

Map<String, Object> _fieldsOf(NbColors c) => {
  ..._colorsOf(c),
  ..._numbersOf(c),
  ..._shadowsOf(c),
};

const Set<String> _newFields = {
  'primaryButtonHover',
  'dangerFill',
  'ice',
  'iceWeak',
  'scrim',
  'segment',
  'keyFill',
  'keyShadow',
  'keyOkBorder',
  'okShadow',
  'sheen',
  'neutralWeak',
  'stageBorder',
  'stageTrack',
  'stageWeak',
  'stageHint',
  'stageDashedRing',
  'discTint',
  'haloOpacity',
  'primaryButtonShadow',
  'primaryButtonHoverShadow',
  'dangerButtonHoverShadow',
  'buttonHighlight',
  'buttonHighlightHover',
  'headingWeight',
};

Color _white(double alpha) => _hex(0xFFFFFF).withValues(alpha: alpha);

final Map<String, (Color, Color)> _designColors = {
  'primary': (_hex(0x6D4AFF), _hex(0x8A6EFF)),
  'primaryHover': (_hex(0x5B3AEB), _hex(0x9D85FF)),
  'primaryWeak': (_hex(0xE0DBFF), const Color.fromRGBO(138, 110, 255, 0.18)),
  'primaryInk': (_hex(0x6336E1), _hex(0xA891FF)),
  'onPrimary': (_hex(0xFFFFFF), _hex(0xFFFFFF)),
  'hubTop': (_hex(0x7E5FFF), _hex(0x9479FF)),
  'hubBottom': (_hex(0x622FF3), _hex(0x6D4AFF)),
  'glow': (
    const Color.fromRGBO(109, 74, 255, 0.13),
    const Color.fromRGBO(138, 110, 255, 0.24),
  ),
  'halo': (
    const Color.fromRGBO(109, 74, 255, 0.06),
    const Color.fromRGBO(138, 110, 255, 0.06),
  ),
  'success': (_hex(0x008B68), _hex(0x3DD6A9)),
  'successWeak': (_hex(0xB0F3D8), const Color.fromRGBO(30, 168, 133, 0.16)),
  'onSuccessDisc': (_hex(0xFFFFFF), _hex(0x1F1D27)),
  'netSurface': (_hex(0xD4F1E9), const Color.fromRGBO(30, 168, 133, 0.16)),
  'netDiscTop': (_hex(0x2BB18B), _hex(0x5AE8BF)),
  'netDiscBottom': (_hex(0x007A5B), _hex(0x1EA885)),
  'warning': (_hex(0x8C5700), _hex(0xFFB547)),
  'warningRing': (_hex(0xD48300), _hex(0xFF9900)),
  'warningWeak': (_hex(0xFFE0AE), const Color.fromRGBO(255, 153, 0, 0.14)),
  'danger': (_hex(0xB72649), _hex(0xFF6B82)),
  'dangerWeak': (_hex(0xFFD6DB), const Color.fromRGBO(220, 50, 81, 0.18)),
  'ground': (_hex(0xF3F1FB), _hex(0x16141C)),
  'card': (_hex(0xFEFDFF), _hex(0x1F1D27)),
  'surfaceWeak': (_hex(0xF1EFFA), _hex(0x292633)),
  'track': (_hex(0xDDDAEB), _hex(0x33303F)),
  'nodeTop': (_hex(0xFEFEFF), _hex(0x2F2C3B)),
  'nodeBottom': (_hex(0xEEEBFB), _hex(0x262330)),
  'border': (_hex(0xD0CCE2), _hex(0x3A3648)),
  'borderWeak': (_hex(0xE0DDED), _hex(0x2E2B39)),
  'text': (_hex(0x161420), _hex(0xFFFFFF)),
  'textWeak': (_hex(0x5B586A), _hex(0xB4B0C4)),
  'hint': (_hex(0x878493), _hex(0x8E8A9E)),
  'tooltip': (_hex(0x0C0C14), _hex(0x0C0C14)),
  'successInk': (_hex(0x007455), _hex(0x3DD6A9)),
  'primaryButton': (_hex(0x6D4AFF), _hex(0x6D4AFF)),
  'nodeShadow': (
    const Color.fromRGBO(35, 28, 56, 0.16),
    const Color.fromRGBO(0, 0, 0, 0.5),
  ),
  'primaryButtonHover': (_hex(0x7958FF), _hex(0x7958FF)),
  'dangerFill': (_hex(0xB72649), _hex(0xC9324B)),
  'ice': (_hex(0x4378AD), _hex(0x8EC5FF)),
  'iceWeak': (_hex(0xE2F2FF), const Color.fromRGBO(142, 197, 255, 0.16)),
  'scrim': (
    const Color.fromRGBO(35, 28, 56, 0.32),
    const Color.fromRGBO(0, 0, 0, 0.56),
  ),
  'segment': (_hex(0xE4E2F0), _hex(0x292633)),
  'keyFill': (_hex(0xFEFDFF), _hex(0x292633)),
  'keyOkBorder': (
    _hex(0x008B68).withValues(alpha: 0.6),
    _hex(0x3DD6A9).withValues(alpha: 0.45),
  ),
  'sheen': (_white(0.85), _white(0.22)),
  'neutralWeak': (_hex(0xE3E1EF), _hex(0x292633)),
  'stageBorder': (_hex(0xBBB7CF), _hex(0x3A3648)),
  'stageTrack': (_hex(0xD6D3E7), _hex(0x33303F)),
  'stageWeak': (_hex(0xEAE7F6), _hex(0x292633)),
  'stageHint': (_hex(0x817D91), _hex(0x8E8A9E)),
  'stageDashedRing': (const Color.fromRGBO(129, 125, 145, 0.8), _hex(0x3A3648)),
  'buttonHighlight': (_white(0.2), _white(0.22)),
  'buttonHighlightHover': (_white(0.24), _white(0.26)),
};

const Map<String, (double, double)> _designNumbers = {
  'discTint': (0.1, 0),
  'haloOpacity': (0.12, 0.13),
  'headingWeight': (650, 600),
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

List<(String, Color, Color)> _modalPairs(NbColors c) => [
  ('onPrimary on primaryButtonHover', c.onPrimary, c.primaryButtonHover),
  ('onPrimary on dangerFill', c.onPrimary, c.dangerFill),
  ('successInk on card', c.successInk, c.card),
  ('danger on card', c.danger, c.card),
  ('warning on card', c.warning, c.card),
  ('ice on card', c.ice, c.card),
  ('textWeak on card for the eyebrow', c.textWeak, c.card),
  (
    'successInk on successWeak over card for the confirmed keys',
    c.successInk,
    Color.alphaBlend(c.successWeak, c.card),
  ),
  ('text on keyFill over card', c.text, Color.alphaBlend(c.keyFill, c.card)),
  (
    'danger on dangerWeak over card for the homonym alert',
    c.danger,
    Color.alphaBlend(c.dangerWeak, c.card),
  ),
  (
    'primaryInk on primaryWeak over card for the chip and the tile',
    c.primaryInk,
    Color.alphaBlend(c.primaryWeak, c.card),
  ),
];

String _functionBody(String source, String signature) {
  final start = source.indexOf(signature);
  expect(start, isNonNegative, reason: 'missing "$signature"');
  final open = source.indexOf('{', start);
  var depth = 0;
  for (var i = open; i < source.length; i++) {
    if (source[i] == '{') depth++;
    if (source[i] == '}') depth--;
    if (depth == 0) return source.substring(open + 1, i);
  }
  fail('unbalanced braces after "$signature"');
}

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
  group('E253 and E280: tokens follow the design', () {
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

      test('every number of ${entry.key} has the value of point 183', () {
        final actual = _numbersOf(entry.value);
        expect(actual.keys.toSet(), _designNumbers.keys.toSet());
        for (final name in _designNumbers.keys) {
          final (light, dark) = _designNumbers[name]!;
          expect(
            actual[name],
            entry.key == 'dark' ? dark : light,
            reason: name,
          );
        }
      });
    }

    test('the dark values that point 183 ties to another token match it', () {
      final c = NbColors.dark;
      expect(c.segment, c.surfaceWeak);
      expect(c.keyFill, c.surfaceWeak);
      expect(c.neutralWeak, c.surfaceWeak);
      expect(c.stageWeak, c.surfaceWeak);
      expect(c.stageBorder, c.border);
      expect(c.stageDashedRing, c.border);
      expect(c.stageTrack, c.track);
      expect(c.stageHint, c.hint);
      expect(c.keyShadow, isEmpty);
      expect(c.okShadow, isEmpty);
    });

    test('keyOkBorder is success at 60 % in light and 45 % in dark', () {
      expect(
        NbColors.light.keyOkBorder,
        NbColors.light.success.withValues(alpha: 0.6),
      );
      expect(
        NbColors.dark.keyOkBorder,
        NbColors.dark.success.withValues(alpha: 0.45),
      );
    });

    test('the light values that stay are the same as before point 183', () {
      final c = NbColors.light;
      expect(c.primary, _hex(0x6D4AFF));
      expect(c.primaryButton, _hex(0x6D4AFF));
      expect(c.primaryHover, _hex(0x5B3AEB));
      expect(c.onPrimary, _hex(0xFFFFFF));
      expect(c.onSuccessDisc, _hex(0xFFFFFF));
      expect(c.tooltip, _hex(0x0C0C14));
    });

    test('the shadows follow the shadow vocabulary in light', () {
      expect(NbColors.light.cardShadow, const [
        BoxShadow(color: Color.fromRGBO(35, 28, 56, 0.05), spreadRadius: 1),
        BoxShadow(
          color: Color.fromRGBO(35, 28, 56, 0.06),
          offset: Offset(0, 1),
          blurRadius: 2,
        ),
        BoxShadow(
          color: Color.fromRGBO(35, 28, 56, 0.07),
          offset: Offset(0, 6),
          blurRadius: 18,
        ),
      ]);
      expect(NbColors.light.popoverShadow, const [
        BoxShadow(color: Color.fromRGBO(35, 28, 56, 0.11), spreadRadius: 1),
        BoxShadow(
          color: Color.fromRGBO(35, 28, 56, 0.06),
          offset: Offset(0, 2),
          blurRadius: 6,
        ),
        BoxShadow(
          color: Color.fromRGBO(35, 28, 56, 0.18),
          offset: Offset(0, 18),
          blurRadius: 40,
        ),
      ]);
      expect(NbColors.light.discShadow, const [
        BoxShadow(
          color: Color.fromRGBO(0, 109, 76, 0.28),
          offset: Offset(0, 4),
          blurRadius: 10,
        ),
      ]);
    });

    test('the new shadows of point 183 in light', () {
      final c = NbColors.light;
      expect(c.keyShadow, const [
        BoxShadow(
          color: Color.fromRGBO(35, 28, 56, 0.08),
          offset: Offset(0, 1),
          blurRadius: 2,
        ),
      ]);
      expect(c.okShadow, const [
        BoxShadow(
          color: Color.fromRGBO(0, 139, 104, 0.5),
          offset: Offset(0, 6),
          blurRadius: 14,
          spreadRadius: -6,
        ),
      ]);
      expect(c.primaryButtonShadow, const [
        BoxShadow(
          color: Color.fromRGBO(35, 28, 56, 0.2),
          offset: Offset(0, 1),
          blurRadius: 2,
        ),
        BoxShadow(
          color: Color.fromRGBO(109, 74, 255, 0.55),
          offset: Offset(0, 8),
          blurRadius: 18,
          spreadRadius: -8,
        ),
      ]);
      expect(c.primaryButtonHoverShadow, const [
        BoxShadow(
          color: Color.fromRGBO(35, 28, 56, 0.18),
          offset: Offset(0, 2),
          blurRadius: 4,
        ),
        BoxShadow(
          color: Color.fromRGBO(109, 74, 255, 0.6),
          offset: Offset(0, 12),
          blurRadius: 24,
          spreadRadius: -10,
        ),
      ]);
      expect(c.dangerButtonHoverShadow, const [
        BoxShadow(
          color: Color.fromRGBO(35, 28, 56, 0.18),
          offset: Offset(0, 2),
          blurRadius: 4,
        ),
        BoxShadow(
          color: Color.fromRGBO(192, 47, 80, 0.5),
          offset: Offset(0, 12),
          blurRadius: 24,
          spreadRadius: -10,
        ),
      ]);
    });

    test('the new shadows of point 183 in dark', () {
      final c = NbColors.dark;
      expect(c.keyShadow, const <BoxShadow>[]);
      expect(c.okShadow, const <BoxShadow>[]);
      expect(c.primaryButtonShadow, const [
        BoxShadow(
          color: Color.fromRGBO(40, 18, 140, 0.35),
          offset: Offset(0, 1),
          blurRadius: 2,
        ),
        BoxShadow(
          color: Color.fromRGBO(109, 74, 255, 0.7),
          offset: Offset(0, 10),
          blurRadius: 22,
          spreadRadius: -8,
        ),
      ]);
      expect(c.primaryButtonHoverShadow, const [
        BoxShadow(
          color: Color.fromRGBO(40, 18, 140, 0.3),
          offset: Offset(0, 2),
          blurRadius: 4,
        ),
        BoxShadow(
          color: Color.fromRGBO(109, 74, 255, 0.8),
          offset: Offset(0, 16),
          blurRadius: 30,
          spreadRadius: -10,
        ),
      ]);
      expect(c.dangerButtonHoverShadow, const [
        BoxShadow(
          color: Color.fromRGBO(120, 10, 30, 0.3),
          offset: Offset(0, 2),
          blurRadius: 4,
        ),
        BoxShadow(
          color: Color.fromRGBO(194, 39, 63, 0.75),
          offset: Offset(0, 16),
          blurRadius: 30,
          spreadRadius: -10,
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

    test('copyWith without arguments keeps every field', () {
      expect(_fieldsOf(NbColors.light.copyWith()), _fieldsOf(NbColors.light));
      expect(_fieldsOf(NbColors.dark.copyWith()), _fieldsOf(NbColors.dark));
    });

    test('copyWith carries every new field of point 183 and keeps the '
        'rest', () {
      final d = NbColors.dark;
      final copy = NbColors.light.copyWith(
        primaryButtonHover: d.primaryButtonHover,
        dangerFill: d.dangerFill,
        ice: d.ice,
        iceWeak: d.iceWeak,
        scrim: d.scrim,
        segment: d.segment,
        keyFill: d.keyFill,
        keyShadow: d.keyShadow,
        keyOkBorder: d.keyOkBorder,
        okShadow: d.okShadow,
        sheen: d.sheen,
        neutralWeak: d.neutralWeak,
        stageBorder: d.stageBorder,
        stageTrack: d.stageTrack,
        stageWeak: d.stageWeak,
        stageHint: d.stageHint,
        stageDashedRing: d.stageDashedRing,
        discTint: d.discTint,
        haloOpacity: d.haloOpacity,
        primaryButtonShadow: d.primaryButtonShadow,
        primaryButtonHoverShadow: d.primaryButtonHoverShadow,
        dangerButtonHoverShadow: d.dangerButtonHoverShadow,
        buttonHighlight: d.buttonHighlight,
        buttonHighlightHover: d.buttonHighlightHover,
        headingWeight: d.headingWeight,
      );
      final actual = _fieldsOf(copy);
      final light = _fieldsOf(NbColors.light);
      final dark = _fieldsOf(d);
      expect(_newFields.difference(actual.keys.toSet()), isEmpty);
      for (final name in actual.keys) {
        expect(
          actual[name],
          _newFields.contains(name) ? dark[name] : light[name],
          reason: name,
        );
      }
    });

    for (final name in _newFields) {
      test('copyWith changes only $name when it is the only argument', () {
        final d = NbColors.dark;
        final copy = switch (name) {
          'primaryButtonHover' => NbColors.light.copyWith(
            primaryButtonHover: _hex(0x123456),
          ),
          'dangerFill' => NbColors.light.copyWith(dangerFill: _hex(0x123456)),
          'ice' => NbColors.light.copyWith(ice: _hex(0x123456)),
          'iceWeak' => NbColors.light.copyWith(iceWeak: _hex(0x123456)),
          'scrim' => NbColors.light.copyWith(scrim: _hex(0x123456)),
          'segment' => NbColors.light.copyWith(segment: _hex(0x123456)),
          'keyFill' => NbColors.light.copyWith(keyFill: _hex(0x123456)),
          'keyShadow' => NbColors.light.copyWith(
            keyShadow: d.primaryButtonShadow,
          ),
          'keyOkBorder' => NbColors.light.copyWith(keyOkBorder: _hex(0x123456)),
          'okShadow' => NbColors.light.copyWith(
            okShadow: d.primaryButtonShadow,
          ),
          'sheen' => NbColors.light.copyWith(sheen: _hex(0x123456)),
          'neutralWeak' => NbColors.light.copyWith(neutralWeak: _hex(0x123456)),
          'stageBorder' => NbColors.light.copyWith(stageBorder: _hex(0x123456)),
          'stageTrack' => NbColors.light.copyWith(stageTrack: _hex(0x123456)),
          'stageWeak' => NbColors.light.copyWith(stageWeak: _hex(0x123456)),
          'stageHint' => NbColors.light.copyWith(stageHint: _hex(0x123456)),
          'stageDashedRing' => NbColors.light.copyWith(
            stageDashedRing: _hex(0x123456),
          ),
          'discTint' => NbColors.light.copyWith(discTint: 0.37),
          'haloOpacity' => NbColors.light.copyWith(haloOpacity: 0.37),
          'primaryButtonShadow' => NbColors.light.copyWith(
            primaryButtonShadow: d.dangerButtonHoverShadow,
          ),
          'primaryButtonHoverShadow' => NbColors.light.copyWith(
            primaryButtonHoverShadow: d.dangerButtonHoverShadow,
          ),
          'dangerButtonHoverShadow' => NbColors.light.copyWith(
            dangerButtonHoverShadow: d.primaryButtonShadow,
          ),
          'buttonHighlight' => NbColors.light.copyWith(
            buttonHighlight: _hex(0x123456),
          ),
          'buttonHighlightHover' => NbColors.light.copyWith(
            buttonHighlightHover: _hex(0x123456),
          ),
          'headingWeight' => NbColors.light.copyWith(headingWeight: 700),
          _ => fail('no copyWith case for $name'),
        };
        final before = _fieldsOf(NbColors.light);
        final after = _fieldsOf(copy);
        expect(after[name], isNot(before[name]), reason: name);
        expect(after..remove(name), before..remove(name));
      });
    }
  });

  group('E253 and E280: every text pair reaches 4.5:1', () {
    for (final entry in _themes.entries) {
      for (final (name, foreground, background) in [
        ..._textPairs(entry.value),
        ..._modalPairs(entry.value),
      ]) {
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

  group('E280: the app is dark by default, whatever the Windows theme', () {
    for (final code in languageCodes) {
      testWidgets('NexusBridgesApp uses ThemeMode.dark and keeps the light '
          'theme ready, without animation ($code)', (tester) async {
        addTearDown(tester.platformDispatcher.clearPlatformBrightnessTestValue);
        tester.platformDispatcher.platformBrightnessTestValue =
            Brightness.light;
        await tester.pumpWidget(NexusBridgesApp(_LanguageController(code)));
        await tester.pumpAndSettle();

        final app = tester.widget<MaterialApp>(find.byType(MaterialApp));
        expect(app.themeMode, ThemeMode.dark);
        expect(app.themeAnimationDuration, Duration.zero);
        expect(app.theme!.extension<NbColors>(), same(NbColors.light));
        expect(app.theme!.brightness, Brightness.light);
        expect(app.darkTheme!.extension<NbColors>(), same(NbColors.dark));
        expect(app.darkTheme!.brightness, Brightness.dark);
        expect(
          AppStringsDelegate.of(tester.element(find.byType(HomeScreen)))
              .runtimeType,
          stringsFor(code).runtimeType,
        );
      });

      testWidgets('NexusBridgesApp stays dark with the platform in light, in '
          'dark and back in light ($code)', (tester) async {
        addTearDown(tester.platformDispatcher.clearPlatformBrightnessTestValue);
        tester.platformDispatcher.platformBrightnessTestValue =
            Brightness.light;
        await tester.pumpWidget(NexusBridgesApp(_LanguageController(code)));
        await tester.pumpAndSettle();

        BuildContext home() => tester.element(find.byType(HomeScreen));
        void expectDark() {
          expect(NbColors.of(home()), same(NbColors.dark));
          expect(Theme.of(home()).brightness, Brightness.dark);
          expect(
            Theme.of(home()).scaffoldBackgroundColor,
            NbColors.dark.ground,
          );
        }

        expectDark();
        tester.platformDispatcher.platformBrightnessTestValue = Brightness.dark;
        await tester.pump();
        expectDark();
        tester.platformDispatcher.platformBrightnessTestValue =
            Brightness.light;
        await tester.pump();
        expectDark();
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

  group('E280: the tabs and the diagram header use the new tokens', () {
    for (final entry in _themes.entries) {
      for (final code in languageCodes) {
        testWidgets('the tab rail is segment and both tab labels weigh '
            '${entry.value.headingWeight.toInt()} over w600 '
            '(${entry.key}, $code)', (tester) async {
          final strings = stringsFor(code);
          final c = entry.value;
          addTearDown(
            tester.platformDispatcher.clearPlatformBrightnessTestValue,
          );
          tester.platformDispatcher.platformBrightnessTestValue = _brightnessOf(
            entry.key,
          );
          await pumpHome(
            tester,
            FakeAppController(state: const NodeState()),
            code,
          );
          expect(NbColors.of(tester.element(find.byType(HomeScreen))), same(c));

          final expectedWeight = entry.key == 'dark' ? 600.0 : 650.0;
          for (final label in [strings.devicesTab, strings.activityTab]) {
            final style = tester.widget<Text>(find.text(label)).style!;
            expect(style.fontWeight, FontWeight.w600, reason: label);
            expect(style.fontVariations, [
              FontVariation.weight(expectedWeight),
            ], reason: label);
          }

          final rails = find.ancestor(
            of: find.text(strings.devicesTab),
            matching: find.byWidgetPredicate(
              (widget) =>
                  widget is DecoratedBox &&
                  widget.decoration is BoxDecoration &&
                  (widget.decoration as BoxDecoration).color == c.segment,
            ),
          );
          expect(rails, findsOneWidget);
          expect(
            find.descendant(
              of: rails,
              matching: find.text(strings.activityTab),
            ),
            findsOneWidget,
          );
          if (entry.key == 'light') {
            expect(c.segment, isNot(c.surfaceWeak));
            expect(
              find.ancestor(
                of: find.text(strings.devicesTab),
                matching: find.byWidgetPredicate(
                  (widget) =>
                      widget is DecoratedBox &&
                      widget.decoration is BoxDecoration &&
                      (widget.decoration as BoxDecoration).color ==
                          c.surfaceWeak,
                ),
              ),
              findsNothing,
            );
          }
          expect(tester.takeException(), isNull);
        });
      }
    }

    test('FlowPainter paints the "My network" header with headingWeight over '
        'NbText.title', () {
      final source = File(
        'lib${Platform.pathSeparator}src${Platform.pathSeparator}ui'
        '${Platform.pathSeparator}diagram${Platform.pathSeparator}'
        'flow_painter.dart',
      ).readAsStringSync();
      final header = _functionBody(source, 'void _paintHeader(');
      final compact = header.replaceAll(RegExp(r'\s+'), '');
      expect(
        compact.contains(
          RegExp(
            r'NbText\.title\.copyWith\(fontVariations:\['
            r'FontVariation\.weight\(colors\.headingWeight\)\],?\)',
          ),
        ),
        isTrue,
      );
      expect(compact.contains('NbText.title,'), isFalse);
      expect(compact.contains('NbText.title)'), isFalse);
      expect(NbText.title.fontWeight, FontWeight.w600);
    });
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
