import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nexus_bridges/src/l10n/app_strings.dart';
import 'package:nexus_bridges/src/ui/modal/code_boxes.dart';
import 'package:nexus_bridges/src/ui/pairing_dialogs.dart' show formatCode;
import 'package:nexus_bridges/src/ui/theme/app_theme.dart';
import 'package:nexus_bridges/src/ui/theme/tokens.dart';

const String _code = '482913';

const Map<String, Brightness> _themes = {
  'light': Brightness.light,
  'dark': Brightness.dark,
};

NbColors _colorsFor(Brightness brightness) =>
    brightness == Brightness.dark ? NbColors.dark : NbColors.light;

const Cubic _easeOut = Cubic(0.23, 1, 0.32, 1);
const Cubic _easeInOut = Cubic(0.65, 0, 0.35, 1);

const double _boxW = 45;
const double _boxH = 58;
const double _radius = 13;
const double _gapW = 7;
const double _rowW = 6 * _boxW + 4 * _gapW + 2 * _gapW + 10;

const List<int> _introDelays = [0, 40, 80, 120, 160, 200];
const int _introLength = 460;
const List<int> _okDelays = [300, 420, 540, 720, 840, 960];
const int _okLength = 700;
const List<int> _sheenDelays = [1500, 1560, 1620, 1700, 1760, 1820];
const int _sheenLength = 700;

final RRect _keyRRect = RRect.fromRectAndRadius(
  const Rect.fromLTWH(0, 0, _boxW, _boxH),
  const Radius.circular(_radius),
);

Future<void> _mount(
  WidgetTester tester, {
  String code = _code,
  bool confirmed = false,
  Brightness brightness = Brightness.light,
  bool reduceMotion = false,
  double width = 344,
  double textScale = 1,
  Size window = const Size(800, 600),
}) async {
  tester.view.physicalSize = window;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    _app(
      code: code,
      confirmed: confirmed,
      brightness: brightness,
      reduceMotion: reduceMotion,
      width: width,
      textScale: textScale,
    ),
  );
}

Widget _app({
  String code = _code,
  bool confirmed = false,
  Brightness brightness = Brightness.light,
  bool reduceMotion = false,
  double width = 344,
  double textScale = 1,
}) {
  return MaterialApp(
    locale: const Locale('en'),
    supportedLocales: const [Locale('en'), Locale('es')],
    localizationsDelegates: const [
      AppStringsDelegate(),
      GlobalMaterialLocalizations.delegate,
      GlobalWidgetsLocalizations.delegate,
      GlobalCupertinoLocalizations.delegate,
    ],
    theme: buildTheme(Brightness.light),
    darkTheme: buildTheme(Brightness.dark),
    themeMode: brightness == Brightness.dark ? ThemeMode.dark : ThemeMode.light,
    themeAnimationDuration: Duration.zero,
    builder: (context, child) => MediaQuery(
      data: MediaQuery.of(context).copyWith(
        disableAnimations: reduceMotion,
        textScaler: TextScaler.linear(textScale),
      ),
      child: child!,
    ),
    home: Scaffold(
      body: Center(
        child: SizedBox(
          width: width,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [CodeBoxes(code: code, confirmed: confirmed)],
          ),
        ),
      ),
    ),
  );
}

final class _Clock {
  _Clock(this.tester);

  final WidgetTester tester;
  int _now = 0;

  Future<void> start() => tester.pump();

  Future<void> to(int ms) async {
    expect(ms, greaterThanOrEqualTo(_now));
    await tester.pump(Duration(milliseconds: ms - _now));
    _now = ms;
  }
}

Finder get _boxes => find.byType(CodeBoxes);

Finder _in(Finder matching) => find.descendant(of: _boxes, matching: matching);

Finder _digit(int index) => _in(find.text(_code[index]));

Finder _keyPaint(int index) => find
    .ancestor(of: _digit(index), matching: _in(find.byType(CustomPaint)))
    .first;

Rect _keyRect(WidgetTester tester, int index) =>
    tester.getRect(_keyPaint(index));

double _keyOpacity(WidgetTester tester, int index) {
  var value = 1.0;
  for (final widget in tester.widgetList(
    find.ancestor(
      of: _digit(index),
      matching: _in(
        find.byWidgetPredicate((w) => w is Opacity || w is FadeTransition),
      ),
    ),
  )) {
    value *= switch (widget) {
      Opacity(:final opacity) => opacity,
      FadeTransition(:final opacity) => opacity.value,
      _ => 1.0,
    };
  }
  return value;
}

CustomPaint _keyCustomPaint(WidgetTester tester, int index) => tester
    .widgetList<CustomPaint>(
      find.ancestor(of: _digit(index), matching: _in(find.byType(CustomPaint))),
    )
    .firstWhere((paint) => paint.painter != null);

CustomPainter? _sheenPainter(WidgetTester tester, int index) => tester
    .widgetList<CustomPaint>(
      find.ancestor(of: _digit(index), matching: _in(find.byType(CustomPaint))),
    )
    .map((paint) => paint.foregroundPainter)
    .firstWhere((painter) => painter != null, orElse: () => null);

TextStyle _digitStyle(WidgetTester tester, int index) => tester
    .widget<RichText>(
      find.descendant(of: _digit(index), matching: find.byType(RichText)),
    )
    .text
    .style!;

bool _sameColor(Color a, Color b, [double tolerance = 0.004]) =>
    (a.r - b.r).abs() <= tolerance &&
    (a.g - b.g).abs() <= tolerance &&
    (a.b - b.b).abs() <= tolerance &&
    (a.a - b.a).abs() <= tolerance;

Matcher _color(Color expected, [double tolerance = 0.004]) => predicate<Color>(
  (actual) => _sameColor(actual, expected, tolerance),
  'a color close to $expected',
);

typedef _Shadow = ({Color color, Rect rect, MaskFilter? blur});

typedef _KeyLook = ({
  List<Color> fills,
  List<RRect> fillShapes,
  List<Color> borders,
  List<(RRect, RRect)> borderShapes,
  List<(Path, Color)> edges,
  List<_Shadow> shadows,
});

final class _BlurCanvas extends TestRecordingCanvas {
  final List<MaskFilter?> blurs = [];

  @override
  void drawRRect(RRect rrect, Paint paint) {
    blurs.add(paint.maskFilter);
    super.drawRRect(rrect, paint);
  }
}

_KeyLook _lookOf(WidgetTester tester, int index) {
  final canvas = _BlurCanvas();
  final painter = _keyCustomPaint(tester, index).painter!;
  final shadowsWereOff = debugDisableShadows;
  debugDisableShadows = false;
  try {
    painter.paint(canvas, const Size(_boxW, _boxH));
  } finally {
    debugDisableShadows = shadowsWereOff;
  }
  final fills = <Color>[];
  final fillShapes = <RRect>[];
  final borders = <Color>[];
  final borderShapes = <(RRect, RRect)>[];
  final edges = <(Path, Color)>[];
  final shadows = <_Shadow>[];
  var rrects = 0;
  for (final call in canvas.invocations) {
    final args = call.invocation.positionalArguments;
    switch (call.invocation.memberName) {
      case #drawRRect:
        final paint = args[1] as Paint;
        final rrect = args[0] as RRect;
        final blur = canvas.blurs[rrects++];
        if (blur != null) {
          shadows.add((color: paint.color, rect: rrect.outerRect, blur: blur));
        } else {
          fills.add(paint.color);
          fillShapes.add(rrect);
        }
      case #drawDRRect:
        borders.add((args[2] as Paint).color);
        borderShapes.add((args[0] as RRect, args[1] as RRect));
      case #drawPath:
        edges.add((args[0] as Path, (args[1] as Paint).color));
    }
  }
  return (
    fills: fills,
    fillShapes: fillShapes,
    borders: borders,
    borderShapes: borderShapes,
    edges: edges,
    shadows: shadows,
  );
}

List<Rect> _sheenRects(WidgetTester tester, int index) {
  final painter = _sheenPainter(tester, index);
  if (painter == null) return const [];
  final canvas = TestRecordingCanvas();
  painter.paint(canvas, const Size(_boxW, _boxH));
  return [
    for (final call in canvas.invocations)
      if (call.invocation.memberName == #drawRect)
        call.invocation.positionalArguments[0] as Rect,
  ];
}

bool _sheenVisible(WidgetTester tester, int index) => _sheenRects(
  tester,
  index,
).any((rect) => rect.overlaps(const Rect.fromLTWH(0, 0, _boxW, _boxH)));

void _expectShadows(_KeyLook look, List<BoxShadow> expected, String reason) {
  expect(look.shadows, hasLength(expected.length), reason: '$reason shadows');
  for (var i = 0; i < expected.length; i++) {
    final shadow = expected[i];
    expect(
      look.shadows[i].color,
      _color(shadow.color),
      reason: '$reason shadow $i color',
    );
    final rect = const Rect.fromLTWH(
      0,
      0,
      _boxW,
      _boxH,
    ).shift(shadow.offset).inflate(shadow.spreadRadius);
    expect(look.shadows[i].rect.left, closeTo(rect.left, 1e-6));
    expect(look.shadows[i].rect.top, closeTo(rect.top, 1e-6));
    expect(look.shadows[i].rect.right, closeTo(rect.right, 1e-6));
    expect(look.shadows[i].rect.bottom, closeTo(rect.bottom, 1e-6));
    expect(
      look.shadows[i].blur,
      (Paint()
            ..maskFilter = MaskFilter.blur(shadow.blurStyle, shadow.blurSigma))
          .maskFilter,
      reason: '$reason shadow $i blur',
    );
  }
}

void _expectRest(WidgetTester tester, NbColors colors, String reason) {
  for (var i = 0; i < 6; i++) {
    final look = _lookOf(tester, i);
    final why = '$reason box $i';
    expect(look.fills, hasLength(1), reason: '$why fill');
    expect(look.fills.single, _color(colors.keyFill), reason: '$why fill');
    expect(look.fillShapes.single, _keyRRect, reason: '$why shape');
    expect(look.borders, hasLength(1), reason: '$why border');
    expect(look.borders.single, _color(colors.border), reason: '$why border');
    expect(look.borderShapes.single.$1, _keyRRect, reason: '$why border');
    expect(
      look.borderShapes.single.$2,
      _keyRRect.deflate(1),
      reason: '$why border width',
    );
    final edges = look.edges.where((edge) => edge.$2.a > 0).toList();
    expect(edges, hasLength(1), reason: '$why inner edge');
    expect(edges.single.$2, _color(colors.borderWeak), reason: '$why edge');
    expect(edges.single.$1.contains(const Offset(22.5, 57)), isTrue);
    expect(edges.single.$1.contains(const Offset(22.5, 56.5)), isTrue);
    expect(edges.single.$1.contains(const Offset(22.5, 54.5)), isFalse);
    expect(edges.single.$1.contains(const Offset(22.5, 29)), isFalse);
    _expectShadows(look, colors.keyShadow, why);
    expect(
      _digitStyle(tester, i).color,
      _color(colors.text),
      reason: '$why digit',
    );
    expect(_keyOpacity(tester, i), 1, reason: '$why opacity');
    final rect = _keyRect(tester, i);
    expect(rect.width, closeTo(_boxW, 1e-6), reason: '$why width');
    expect(rect.height, closeTo(_boxH, 1e-6), reason: '$why height');
    expect(_sheenVisible(tester, i), isFalse, reason: '$why sheen');
  }
}

void _expectConfirmed(WidgetTester tester, NbColors colors, String reason) {
  for (var i = 0; i < 6; i++) {
    final look = _lookOf(tester, i);
    final why = '$reason box $i';
    expect(look.fills, hasLength(1), reason: '$why fill');
    expect(look.fills.single, _color(colors.successWeak), reason: '$why fill');
    expect(look.fillShapes.single, _keyRRect, reason: '$why shape');
    expect(look.borders, hasLength(1), reason: '$why border');
    expect(
      look.borders.single,
      _color(colors.keyOkBorder),
      reason: '$why border',
    );
    expect(look.borderShapes.single.$1, _keyRRect, reason: '$why border');
    expect(look.borderShapes.single.$2, _keyRRect.deflate(1));
    expect(
      look.edges.where((edge) => edge.$2.a > 0),
      isEmpty,
      reason: '$why inner edge',
    );
    _expectShadows(look, colors.okShadow, why);
    expect(
      _digitStyle(tester, i).color,
      _color(colors.successInk),
      reason: '$why digit',
    );
    expect(_keyOpacity(tester, i), 1, reason: '$why opacity');
    final rect = _keyRect(tester, i);
    expect(rect.width, closeTo(_boxW, 1e-6), reason: '$why width');
    expect(rect.height, closeTo(_boxH, 1e-6), reason: '$why height');
    expect(_sheenVisible(tester, i), isFalse, reason: '$why sheen');
  }
}

Finder get _dash => _in(
  find.byWidgetPredicate(
    (widget) =>
        widget is DecoratedBox &&
        widget.decoration is BoxDecoration &&
        (widget.decoration as BoxDecoration).color != null,
  ),
);

BoxDecoration _dashDecoration(WidgetTester tester) {
  final found = tester
      .elementList(_dash)
      .where((element) => (element.size ?? Size.zero) == const Size(10, 2))
      .toList();
  expect(found, hasLength(1), reason: 'exactly one 10 x 2 dash');
  return (found.single.widget as DecoratedBox).decoration as BoxDecoration;
}

Rect _dashRect(WidgetTester tester) {
  final found = tester
      .elementList(_dash)
      .where((element) => (element.size ?? Size.zero) == const Size(10, 2))
      .toList();
  expect(found, hasLength(1));
  final box = found.single.renderObject! as RenderBox;
  return box.localToGlobal(Offset.zero) & box.size;
}

Future<Color> _pixel(
  WidgetTester tester,
  CustomPainter painter,
  Offset at,
) async {
  final result = await tester.runAsync(() async {
    final recorder = ui.PictureRecorder();
    painter.paint(Canvas(recorder), const Size(_boxW, _boxH));
    final image = await recorder.endRecording().toImage(
      _boxW.toInt(),
      _boxH.toInt(),
    );
    final data = await image.toByteData(
      format: ui.ImageByteFormat.rawStraightRgba,
    );
    image.dispose();
    final offset = (at.dy.floor() * _boxW.toInt() + at.dx.floor()) * 4;
    return Color.fromARGB(
      data!.getUint8(offset + 3),
      data.getUint8(offset),
      data.getUint8(offset + 1),
      data.getUint8(offset + 2),
    );
  });
  return result!;
}

double _phase(int ms, int delay, int length) =>
    ((ms - delay) / length).clamp(0.0, 1.0);

double _bump(double local) => local < 0.4
    ? _easeOut.transform(local / 0.4)
    : 1 - _easeOut.transform((local - 0.4) / 0.6);

List<String> _labelsWithDigits(WidgetTester tester) {
  final owner = tester.renderObject(_boxes).owner!.semanticsOwner!;
  final labels = <String>[];
  void visit(SemanticsNode node) {
    final data = node.getSemanticsData();
    for (final text in [data.label, data.value, data.hint, data.tooltip]) {
      if (RegExp(r'\d').hasMatch(text)) labels.add(text);
    }
    node.visitChildren((child) {
      visit(child);
      return true;
    });
  }

  visit(owner.rootSemanticsNode!);
  return labels;
}

void main() {
  group('E283: layout', () {
    testWidgets('six 45 x 58 boxes in two groups of three, 7 px apart, with a '
        '10 x 2 dash between them and 16 px above the row', (tester) async {
      await _mount(tester, reduceMotion: true);

      final texts = tester
          .widgetList<Text>(_in(find.byType(Text)))
          .map((text) => text.data)
          .toList();
      expect(texts, hasLength(6));
      final rects = [for (var i = 0; i < 6; i++) _keyRect(tester, i)];
      final ordered = List.of(rects)..sort((a, b) => a.left.compareTo(b.left));
      expect(ordered, rects, reason: 'the digits read 4 8 2 9 1 3 in order');
      for (final rect in rects) {
        expect(rect.size, const Size(_boxW, _boxH));
        expect(rect.top, rects.first.top);
      }
      for (final i in [1, 2, 4, 5]) {
        expect(rects[i].left - rects[i - 1].right, closeTo(_gapW, 1e-6));
      }
      final dash = _dashRect(tester);
      expect(dash.size, const Size(10, 2));
      expect(dash.left - rects[2].right, closeTo(_gapW, 1e-6));
      expect(rects[3].left - dash.right, closeTo(_gapW, 1e-6));
      expect(dash.center.dy, closeTo(rects[0].center.dy, 1e-6));
      expect(rects[5].right - rects[0].left, closeTo(_rowW, 1e-6));
      final whole = tester.getRect(_boxes);
      expect(rects[0].top - whole.top, closeTo(16, 1e-6));
      expect(whole.height, closeTo(16 + _boxH, 1e-6));
      expect(
        (rects[0].left + rects[5].right) / 2,
        closeTo(whole.center.dx, 1e-6),
      );
      final decoration = _dashDecoration(tester);
      expect(decoration.borderRadius, BorderRadius.circular(1));
    });

    testWidgets('each digit is its own text in Segoe UI Variable Display, '
        '28 px, 600, line height 1 and tabular figures', (tester) async {
      await _mount(tester, reduceMotion: true);

      for (var i = 0; i < 6; i++) {
        expect(_digit(i), findsOneWidget);
        final style = _digitStyle(tester, i);
        expect(style.fontFamily, 'Segoe UI Variable Display');
        expect(style.fontSize, 28);
        expect(style.fontWeight, FontWeight.w600);
        expect(style.height, 1);
        expect(
          style.fontFeatures,
          contains(const FontFeature.tabularFigures()),
        );
      }
    });

    for (final code in ['', '48291', '4829130']) {
      for (final confirmed in [false, true]) {
        testWidgets('a code of ${code.length} digits paints nothing '
            '(confirmed: $confirmed)', (tester) async {
          await _mount(tester, code: code, confirmed: confirmed);
          await tester.pump(const Duration(milliseconds: 100));

          expect(_in(find.byType(Text)), findsNothing);
          expect(_in(find.byType(CustomPaint)), findsNothing);
          expect(tester.getSize(_boxes), Size.zero);
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull);
        });
      }
    }
  });

  group('E283: screen reader', () {
    for (final confirmed in [false, true]) {
      testWidgets('the row reads as one entry, formatCode(code), and no digit '
          'is read on its own (confirmed: $confirmed)', (tester) async {
        final handle = tester.ensureSemantics();
        await _mount(tester, confirmed: confirmed, reduceMotion: true);

        expect(formatCode(_code), '482 913');
        expect(find.bySemanticsLabel(formatCode(_code)), findsOneWidget);
        expect(_labelsWithDigits(tester), [formatCode(_code)]);
        handle.dispose();
      });
    }

    testWidgets('the entry is there from the first frame of the entrance', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      await _mount(tester);
      await tester.pump();

      expect(find.bySemanticsLabel('482 913'), findsOneWidget);
      expect(_labelsWithDigits(tester), ['482 913']);
      await tester.pumpAndSettle();
      expect(_labelsWithDigits(tester), ['482 913']);
      handle.dispose();
    });
  });

  group('E283: colors and shadows from NbColors', () {
    for (final MapEntry(key: name, value: brightness) in _themes.entries) {
      final colors = _colorsFor(brightness);

      testWidgets('$name: at rest, keyFill, border, the borderWeak bottom '
          'edge, keyShadow, text digits and a hint dash', (tester) async {
        await _mount(tester, brightness: brightness);
        await tester.pumpAndSettle();

        _expectRest(tester, colors, name);
        expect(_dashDecoration(tester).color, _color(colors.hint));
      });

      testWidgets('$name: confirmed, successWeak, keyOkBorder, okShadow, '
          'successInk digits and a success dash at 2.6 s', (tester) async {
        await _mount(tester, brightness: brightness, confirmed: true);
        final clock = _Clock(tester);
        await clock.start();
        await clock.to(2600);

        _expectConfirmed(tester, colors, name);
        expect(_dashDecoration(tester).color, _color(colors.success));
      });

      testWidgets('$name: the sheen is the sheen token at the middle of its '
          'band and stays inside the rounded box', (tester) async {
        await _mount(tester, brightness: brightness, confirmed: true);
        final clock = _Clock(tester);
        await clock.start();
        await clock.to(_sheenDelays[0] + _sheenLength ~/ 2);

        final rects = _sheenRects(tester, 0);
        expect(rects, hasLength(1));
        final band = rects.single;
        expect(band.width, closeTo(0.6 * _boxW, 1e-6));
        expect(band.height, closeTo(_boxH, 1e-6));
        final painter = _sheenPainter(tester, 0)!;
        final middle = await _pixel(tester, painter, band.center);
        expect(middle, _color(colors.sheen, 0.04));
        final corner = await _pixel(tester, painter, const Offset(0, 0));
        expect(corner.a, 0);
        await clock.to(2600);
      });
    }

    test('code_boxes.dart writes no color literal and no white constant', () {
      const path = 'lib/src/ui/modal/code_boxes.dart';
      final source = File(path).readAsStringSync();
      expect(source.contains('Color(0x'), isFalse);
      expect(source.contains('Color.fromRGBO('), isFalse);
      expect(source.contains('Color.fromARGB('), isFalse);
      expect(source.contains('_white'), isFalse);
      expect(
        RegExp(r'(?<![A-Za-z])Colors\.(?!transparent\b)').hasMatch(source),
        isFalse,
      );
    });
  });

  group('E283: staggered entrance (digIn)', () {
    testWidgets('each box rises 8 px from scale 0.94 and fades in over 460 ms '
        'with labEaseOut, 40 ms after the previous one', (tester) async {
      await _mount(tester);
      final clock = _Clock(tester);
      await clock.start();
      final seen = <int, List<(double, Rect)>>{};
      for (final ms in [0, 20, 100, 160, 230, 300, 420, 500, 600, 660]) {
        await clock.to(ms);
        seen[ms] = [
          for (var i = 0; i < 6; i++)
            (_keyOpacity(tester, i), _keyRect(tester, i)),
        ];
      }
      await tester.pumpAndSettle();
      final rest = [for (var i = 0; i < 6; i++) _keyRect(tester, i)];
      _expectRest(tester, NbColors.light, 'after the entrance');

      for (final MapEntry(key: ms, value: boxes) in seen.entries) {
        for (var i = 0; i < 6; i++) {
          final why = 'box $i at $ms ms';
          final local = _phase(ms, _introDelays[i], _introLength);
          final eased = _easeOut.transform(local);
          final (opacity, rect) = boxes[i];
          expect(opacity, closeTo(eased, 0.01), reason: '$why opacity');
          final scale = 0.94 + 0.06 * eased;
          expect(rect.height, closeTo(_boxH * scale, 0.05), reason: why);
          expect(rect.width, closeTo(_boxW * scale, 0.05), reason: why);
          expect(
            rect.center.dy - rest[i].center.dy,
            closeTo(8 * (1 - eased), 0.05),
            reason: '$why lift',
          );
          expect(
            rect.center.dx,
            closeTo(rest[i].center.dx, 0.05),
            reason: '$why x',
          );
        }
      }
      expect(seen[0]![0].$1, 0);
      expect(seen[100]![5].$1, 0);
      expect(seen[660]!.every((box) => box.$1 == 1), isTrue);
    });

    testWidgets('during the entrance the boxes keep the resting colors', (
      tester,
    ) async {
      await _mount(tester, brightness: Brightness.dark);
      final clock = _Clock(tester);
      await clock.start();
      await clock.to(200);

      for (var i = 0; i < 6; i++) {
        final look = _lookOf(tester, i);
        expect(look.fills.single, _color(NbColors.dark.keyFill));
        expect(look.borders.single, _color(NbColors.dark.border));
        expect(_digitStyle(tester, i).color, _color(NbColors.dark.text));
        expect(_sheenRects(tester, i), isEmpty);
      }
      expect(_dashDecoration(tester).color, _color(NbColors.dark.hint));
      await tester.pumpAndSettle();
    });
  });

  group('E283: confirmation box by box (okSeq, dash and sheen)', () {
    for (final MapEntry(key: name, value: brightness) in _themes.entries) {
      final colors = _colorsFor(brightness);

      testWidgets('$name: each box turns over 700 ms with labEaseOut, with a '
          '-3 px and 1.04 hop at 40 %, after 300, 420, 540, 720, 840 and '
          '960 ms', (tester) async {
        await _mount(tester, brightness: brightness, confirmed: true);
        final clock = _Clock(tester);
        await clock.start();

        _expectRest(tester, colors, '$name at 0 ms');
        final rest = [for (var i = 0; i < 6; i++) _keyRect(tester, i)];

        for (final ms in [
          100,
          300,
          480,
          580,
          650,
          720,
          1000,
          1200,
          1400,
          1660,
          2000,
        ]) {
          await clock.to(ms);
          for (var i = 0; i < 6; i++) {
            final why = '$name box $i at $ms ms';
            final local = _phase(ms, _okDelays[i], _okLength);
            final ok = _easeOut.transform(local);
            final bump = _bump(local);
            final look = _lookOf(tester, i);
            expect(
              look.fills.single,
              _color(Color.lerp(colors.keyFill, colors.successWeak, ok)!),
              reason: '$why fill',
            );
            expect(
              look.borders.single,
              _color(Color.lerp(colors.border, colors.keyOkBorder, ok)!),
              reason: '$why border',
            );
            expect(
              _digitStyle(tester, i).color,
              _color(Color.lerp(colors.text, colors.successInk, ok)!),
              reason: '$why digit',
            );
            expect(_keyOpacity(tester, i), 1, reason: '$why never fades');
            final rect = _keyRect(tester, i);
            expect(
              rect.height,
              closeTo(_boxH * (1 + 0.04 * bump), 0.05),
              reason: '$why scale',
            );
            expect(
              rect.center.dy - rest[i].center.dy,
              closeTo(-3 * bump, 0.05),
              reason: '$why hop',
            );
          }
        }
        await clock.to(2600);
        _expectConfirmed(tester, colors, '$name at 2.6 s');
      });
    }

    testWidgets('the hop peaks exactly at 40 % of each box', (tester) async {
      await _mount(tester, confirmed: true);
      final clock = _Clock(tester);
      await clock.start();
      final rest = [for (var i = 0; i < 6; i++) _keyRect(tester, i)];

      for (var i = 0; i < 6; i++) {
        await clock.to(_okDelays[i] + 280);
        final rect = _keyRect(tester, i);
        expect(rect.height, closeTo(_boxH * 1.04, 0.01), reason: 'box $i');
        expect(rect.width, closeTo(_boxW * 1.04, 0.01), reason: 'box $i');
        expect(
          rect.center.dy - rest[i].center.dy,
          closeTo(-3, 0.01),
          reason: 'box $i',
        );
        if (i < 5) {
          expect(
            _keyRect(tester, i + 1).height,
            lessThan(_boxH * 1.04 - 0.01),
            reason: 'box ${i + 1} is not at its peak yet',
          );
        }
      }
      await clock.to(2600);
    });

    testWidgets('the dash stays hint until 660 ms and turns success over '
        '400 ms with ease', (tester) async {
      await _mount(tester, confirmed: true);
      final clock = _Clock(tester);
      await clock.start();
      const c = NbColors.light;

      for (final ms in [0, 400, 660, 760, 860, 960, 1060, 1500]) {
        await clock.to(ms);
        final t = Curves.ease.transform(_phase(ms, 660, 400));
        expect(
          _dashDecoration(tester).color,
          _color(Color.lerp(c.hint, c.success, t)!),
          reason: 'dash at $ms ms',
        );
      }
      await clock.to(2600);
    });

    testWidgets('a 60 % band crosses each box from -120 % to 220 % over '
        '700 ms with labEaseInOut, after 1500, 1560, 1620, 1700, 1760 and '
        '1820 ms', (tester) async {
      await _mount(tester, confirmed: true);
      final clock = _Clock(tester);
      await clock.start();
      const band = 0.6 * _boxW;

      final samples = <int>{
        for (final delay in _sheenDelays) ...[
          delay - 10,
          delay + 175,
          delay + 350,
          delay + 525,
          delay + 700,
        ],
      }.toList()..sort();
      for (final ms in [1000, ...samples]) {
        await clock.to(ms);
        for (var i = 0; i < 6; i++) {
          final why = 'box $i at $ms ms';
          final local = _phase(ms, _sheenDelays[i], _sheenLength);
          if (local <= 0 || local >= 1) {
            expect(_sheenVisible(tester, i), isFalse, reason: why);
            continue;
          }
          final x = _easeInOut.transform(local);
          final rects = _sheenRects(tester, i);
          expect(rects, hasLength(1), reason: why);
          expect(
            rects.single.left,
            closeTo(band * (-1.2 + 3.4 * x), 0.01),
            reason: '$why band position',
          );
          expect(rects.single.width, closeTo(band, 1e-6), reason: why);
        }
      }
      await clock.to(2600);
      for (var i = 0; i < 6; i++) {
        expect(_sheenVisible(tester, i), isFalse);
      }
    });

    testWidgets('changing to confirmed while shown plays the confirmation '
        'from the resting look', (tester) async {
      await _mount(tester);
      await tester.pumpAndSettle();
      _expectRest(tester, NbColors.light, 'before');

      await tester.pumpWidget(_app(confirmed: true));
      final clock = _Clock(tester);
      await clock.start();
      _expectRest(tester, NbColors.light, 'right after the change');
      await clock.to(_okDelays[0] + 280);
      expect(_keyRect(tester, 0).height, closeTo(_boxH * 1.04, 0.01));
      await clock.to(2600);
      _expectConfirmed(tester, NbColors.light, 'after the change');
      await clock.to(2620);
      expect(tester.hasRunningAnimations, isFalse);
    });
  });

  group('E283: reduced motion', () {
    for (final MapEntry(key: name, value: brightness) in _themes.entries) {
      final colors = _colorsFor(brightness);

      testWidgets('$name: the comparison shows its final look on the first '
          'frame with nothing running', (tester) async {
        await _mount(tester, brightness: brightness, reduceMotion: true);

        expect(tester.hasRunningAnimations, isFalse);
        _expectRest(tester, colors, '$name first frame');
        expect(_dashDecoration(tester).color, _color(colors.hint));
      });

      testWidgets('$name: the confirmation shows its final look on the '
          'first frame with nothing running', (tester) async {
        await _mount(
          tester,
          brightness: brightness,
          confirmed: true,
          reduceMotion: true,
        );

        expect(tester.hasRunningAnimations, isFalse);
        _expectConfirmed(tester, colors, '$name first frame');
        expect(_dashDecoration(tester).color, _color(colors.success));
      });
    }

    testWidgets('turning confirmed on with reduced motion jumps to the final '
        'look in the same frame', (tester) async {
      await _mount(tester, reduceMotion: true);
      await tester.pumpWidget(_app(confirmed: true, reduceMotion: true));

      expect(tester.hasRunningAnimations, isFalse);
      _expectConfirmed(tester, NbColors.light, 'same frame');
    });

    testWidgets('reduced motion turned on during the confirmation jumps to '
        'the final look and stops', (tester) async {
      await _mount(tester, confirmed: true);
      final clock = _Clock(tester);
      await clock.start();
      await clock.to(500);
      expect(tester.hasRunningAnimations, isTrue);

      await tester.pumpWidget(_app(confirmed: true, reduceMotion: true));

      expect(tester.hasRunningAnimations, isFalse);
      _expectConfirmed(tester, NbColors.light, 'after switching');
    });
  });

  group('E283: the animation ends', () {
    testWidgets('the entrance runs 660 ms and stops', (tester) async {
      await _mount(tester);
      final clock = _Clock(tester);
      await clock.start();
      await clock.to(640);
      expect(tester.hasRunningAnimations, isTrue);
      await clock.to(660);
      await clock.to(680);
      expect(tester.hasRunningAnimations, isFalse);
      expect(await tester.pumpAndSettle(), 1);
    });

    testWidgets('the confirmation runs 2.6 s and stops', (tester) async {
      await _mount(tester, confirmed: true);
      final clock = _Clock(tester);
      await clock.start();
      await clock.to(2550);
      expect(tester.hasRunningAnimations, isTrue);
      await clock.to(2600);
      await clock.to(2620);
      expect(tester.hasRunningAnimations, isFalse);
      expect(await tester.pumpAndSettle(), 1);
    });

    for (final confirmed in [false, true]) {
      testWidgets('pumpAndSettle finishes (confirmed: $confirmed)', (
        tester,
      ) async {
        await _mount(tester, confirmed: confirmed);
        await tester.pumpAndSettle();

        expect(tester.hasRunningAnimations, isFalse);
        expect(tester.takeException(), isNull);
      });

      testWidgets('removing it mid-animation leaves no live controller '
          '(confirmed: $confirmed)', (tester) async {
        await _mount(tester, confirmed: confirmed);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));
        expect(tester.hasRunningAnimations, isTrue);

        await tester.pumpWidget(const SizedBox());

        expect(tester.takeException(), isNull);
        expect(tester.hasRunningAnimations, isFalse);
        await tester.pump(const Duration(seconds: 3));
        expect(tester.takeException(), isNull);
      });
    }
  });

  group('E283: narrow windows', () {
    for (final width in [320.0, 288.0, 240.0, 200.0, 120.0]) {
      for (final textScale in [1.0, 1.3]) {
        for (final confirmed in [false, true]) {
          testWidgets('$width px wide, text at ${(textScale * 100).round()} %, '
              'confirmed: $confirmed: no overflow, the row scales down '
              'whole', (tester) async {
            await _mount(
              tester,
              width: width,
              textScale: textScale,
              confirmed: confirmed,
              window: const Size(320, 600),
            );
            final clock = _Clock(tester);
            await clock.start();
            for (final ms in [100, 300, 1000, 2600]) {
              await clock.to(ms);
              expect(tester.takeException(), isNull, reason: '$ms ms');
            }

            final whole = tester.getRect(_boxes);
            expect(whole.width, lessThanOrEqualTo(width + 1e-6));
            final factor = math.min(1.0, width / _rowW);
            final rects = [for (var i = 0; i < 6; i++) _keyRect(tester, i)];
            for (var i = 0; i < 6; i++) {
              final rect = rects[i];
              expect(rect.left, greaterThanOrEqualTo(whole.left - 1e-6));
              expect(rect.right, lessThanOrEqualTo(whole.right + 1e-6));
              expect(rect.top, greaterThanOrEqualTo(whole.top - 1e-6));
              expect(rect.bottom, lessThanOrEqualTo(whole.bottom + 1e-6));
              expect(rect.width, closeTo(_boxW * factor, 0.01));
              expect(rect.height, closeTo(_boxH * factor, 0.01));
              if (i > 0) {
                expect(rect.left, greaterThan(rects[i - 1].right));
              }
            }
            expect(
              rects[5].right - rects[0].left,
              closeTo(_rowW * factor, 0.01),
            );
          });
        }
      }
    }
  });
}
