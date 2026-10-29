import 'dart:io';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nexus_bridges/src/l10n/app_strings.dart';
import 'package:nexus_bridges/src/ui/icons/glyphs.dart';
import 'package:nexus_bridges/src/ui/modal/modal_button.dart';
import 'package:nexus_bridges/src/ui/modal/modal_frame.dart';
import 'package:nexus_bridges/src/ui/theme/app_theme.dart';
import 'package:nexus_bridges/src/ui/theme/tokens.dart';

import '../fake_app_controller.dart';

const Map<String, Brightness> _themes = {
  'light': Brightness.light,
  'dark': Brightness.dark,
};

NbColors _colorsFor(Brightness brightness) =>
    brightness == Brightness.dark ? NbColors.dark : NbColors.light;

const Duration _settle = Duration(milliseconds: 300);

final GlobalKey _homeKey = GlobalKey();

Future<void> _loadSegoe() async {
  TestWidgetsFlutterBinding.ensureInitialized();
  for (final family in [
    'Segoe UI Variable Text',
    'Segoe UI Variable Display',
    'Segoe UI',
  ]) {
    final loader = FontLoader(family);
    for (final name in ['segoeui.ttf', 'seguisb.ttf', 'segoeuib.ttf']) {
      final file = File('C:\\Windows\\Fonts\\$name');
      loader.addFont(
        Future.value(ByteData.sublistView(file.readAsBytesSync())),
      );
    }
    await loader.load();
  }
}

Future<void> _mount(
  WidgetTester tester,
  Widget child, {
  Brightness brightness = Brightness.light,
  bool reduceMotion = false,
  double textScale = 1,
  double width = 344,
  String code = 'en',
  Size window = const Size(800, 600),
}) async {
  tester.view.physicalSize = window;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MaterialApp(
      locale: Locale(code),
      supportedLocales: const [Locale('en'), Locale('es')],
      localizationsDelegates: const [
        AppStringsDelegate(),
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      theme: buildTheme(Brightness.light),
      darkTheme: buildTheme(Brightness.dark),
      themeMode: brightness == Brightness.dark
          ? ThemeMode.dark
          : ThemeMode.light,
      themeAnimationDuration: Duration.zero,
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context).copyWith(
          disableAnimations: reduceMotion,
          textScaler: TextScaler.linear(textScale),
        ),
        child: child!,
      ),
      home: Scaffold(
        key: _homeKey,
        body: Center(
          child: SizedBox(width: width, child: child),
        ),
      ),
    ),
  );
}

Finder _in(Finder scope, Finder matching) =>
    find.descendant(of: scope, matching: matching);

Finder get _button => find.byType(ModalButton);

Finder get _tile => find.byType(ChoiceTile);

BoxDecoration _box(WidgetTester tester, Finder scope) =>
    tester
            .widget<DecoratedBox>(
              _in(
                scope,
                find.byWidgetPredicate(
                  (widget) =>
                      widget is DecoratedBox &&
                      widget.position == DecorationPosition.background &&
                      widget.decoration is BoxDecoration &&
                      (widget.decoration as BoxDecoration).borderRadius != null,
                ),
              ).first,
            )
            .decoration
        as BoxDecoration;

Border? _border(WidgetTester tester, Finder scope) {
  final found = _in(
    scope,
    find.byWidgetPredicate(
      (widget) =>
          widget is DecoratedBox &&
          widget.position == DecorationPosition.foreground,
    ),
  );
  if (found.evaluate().isEmpty) return null;
  final decoration =
      tester.widget<DecoratedBox>(found.first).decoration as BoxDecoration;
  return decoration.border as Border?;
}

Color? _ink(WidgetTester tester, String label) => tester
    .widget<RichText>(_in(find.text(label), find.byType(RichText)))
    .text
    .style
    ?.color;

Matrix4 _transform(WidgetTester tester, Finder scope) => tester
    .widget<Transform>(_in(scope, find.byType(Transform)).first)
    .transform;

double _opacity(WidgetTester tester, Finder scope) => tester
    .widget<FadeTransition>(_in(scope, find.byType(FadeTransition)).first)
    .opacity
    .value;

Future<TestGesture> _hover(WidgetTester tester, Finder target) async {
  final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
  await mouse.addPointer(location: Offset.zero);
  addTearDown(mouse.removePointer);
  await mouse.moveTo(tester.getCenter(target));
  await tester.pump();
  return mouse;
}

typedef _Look = ({
  Color? fill,
  Color ink,
  List<BoxShadow> shadows,
  Color? edge,
  Color? border,
});

_Look _restOf(NbColors c, ModalButtonKind kind) => switch (kind) {
  ModalButtonKind.primary => (
    fill: c.primaryButton,
    ink: c.onPrimary,
    shadows: c.primaryButtonShadow,
    edge: c.buttonHighlight,
    border: null,
  ),
  ModalButtonKind.neutral => (
    fill: null,
    ink: c.text,
    shadows: const [],
    edge: null,
    border: null,
  ),
  ModalButtonKind.secondary => (
    fill: null,
    ink: c.text,
    shadows: const [],
    edge: null,
    border: c.border,
  ),
  ModalButtonKind.negative => (
    fill: c.dangerWeak,
    ink: c.danger,
    shadows: const [],
    edge: null,
    border: null,
  ),
  ModalButtonKind.negativeQuiet => (
    fill: null,
    ink: c.danger,
    shadows: const [],
    edge: null,
    border: null,
  ),
};

_Look _hoverOf(NbColors c, ModalButtonKind kind) => switch (kind) {
  ModalButtonKind.primary || ModalButtonKind.neutral => (
    fill: c.primaryButtonHover,
    ink: c.onPrimary,
    shadows: c.primaryButtonHoverShadow,
    edge: c.buttonHighlightHover,
    border: null,
  ),
  ModalButtonKind.secondary => (
    fill: c.primaryWeak,
    ink: c.primaryInk,
    shadows: const [],
    edge: null,
    border: c.primary,
  ),
  ModalButtonKind.negative || ModalButtonKind.negativeQuiet => (
    fill: c.dangerFill,
    ink: c.onPrimary,
    shadows: c.dangerButtonHoverShadow,
    edge: c.buttonHighlight,
    border: null,
  ),
};

void _expectLook(
  WidgetTester tester,
  NbColors colors,
  _Look look,
  String label, {
  required String reason,
}) {
  final box = _box(tester, _button);
  if (look.fill == null) {
    expect(box.color?.a ?? 0, 0, reason: '$reason fill');
  } else {
    expect(box.color, look.fill, reason: '$reason fill');
  }
  expect(box.boxShadow ?? const <BoxShadow>[], look.shadows, reason: reason);
  expect(box.borderRadius, BorderRadius.circular(14), reason: reason);
  expect(_ink(tester, label), look.ink, reason: '$reason ink');
  final border = _border(tester, _button);
  if (look.border == null) {
    expect(border, isNull, reason: '$reason border');
  } else {
    expect(border, isNotNull, reason: '$reason border');
    expect(border!.top.color, look.border, reason: '$reason border');
    expect(border.top.width, 1.5, reason: '$reason border');
    expect(border.isUniform, isTrue, reason: '$reason border');
  }
  final edge = look.edge;
  for (final candidate in [
    colors.buttonHighlight,
    colors.buttonHighlightHover,
  ]) {
    if (candidate == edge) {
      expect(_button, _edge(candidate), reason: '$reason edge');
    } else {
      expect(_button, isNot(_edge(candidate)), reason: '$reason edge');
    }
  }
}

bool _sameColor(Color a, Color b) => a.toARGB32() == b.toARGB32();

PaintPattern _edge(Color color) => paints
  ..something(
    (method, arguments) =>
        method == #drawPath && _sameColor((arguments[1] as Paint).color, color),
  );

PaintPattern _ring(NbColors colors, {Size? size}) =>
    paints..something((method, arguments) {
      if (method != #drawRRect) return false;
      final paint = arguments[1] as Paint;
      if (paint.style != PaintingStyle.stroke) return false;
      if (paint.strokeWidth != 2) return false;
      if (!_sameColor(paint.color, colors.primary)) return false;
      if (size == null) return true;
      return arguments[0] ==
          RRect.fromRectAndRadius(
            (Offset.zero & size).inflate(3),
            const Radius.circular(17),
          );
    });

List<SemanticsData> _semanticsUnder(WidgetTester tester, Finder finder) {
  final out = <SemanticsData>[];
  void visit(SemanticsNode node) {
    out.add(node.getSemanticsData());
    node.visitChildren((child) {
      visit(child);
      return true;
    });
  }

  visit(tester.getSemantics(finder));
  return out;
}

Widget _tileWith({
  VoidCallback? onPressed,
  bool neutral = false,
  bool selected = false,
  bool dimmed = false,
  ValueChanged<bool>? onHover,
}) {
  return ChoiceTile(
    title: 'It is mine',
    detail: 'I use it myself',
    glyph: neutral ? Glyphs.someoneElse : Glyphs.mine,
    neutral: neutral,
    onPressed: onPressed,
    selected: selected,
    dimmed: dimmed,
    onHover: onHover,
  );
}

Future<void> _openPair(WidgetTester tester, String first, String second) async {
  final context = _homeKey.currentContext!;
  Navigator.of(context).push(
    NbModalRoute<void>(
      context: context,
      builder: (_) => ModalView(
        title: 'Title',
        pair: [
          ModalButton(
            label: first,
            kind: ModalButtonKind.secondary,
            onPressed: () {},
            inPair: true,
          ),
          ModalButton(
            label: second,
            kind: ModalButtonKind.primary,
            onPressed: () {},
            inPair: true,
          ),
        ],
      ),
    ),
  );
  await tester.pump();
  await tester.pump(modalTransitionDuration);
}

void _expectLabelWhole(WidgetTester tester, String label, {String? reason}) {
  final text = _in(find.text(label), find.byType(RichText));
  final paragraph = tester.renderObject<RenderParagraph>(text);
  expect(paragraph.didExceedMaxLines, isFalse, reason: reason ?? label);
  final button = tester.getRect(
    find.ancestor(of: find.text(label), matching: _button),
  );
  final rect = tester.getRect(text);
  expect(rect.left, greaterThanOrEqualTo(button.left), reason: label);
  expect(rect.right, lessThanOrEqualTo(button.right), reason: label);
  expect(rect.top, greaterThanOrEqualTo(button.top), reason: label);
  expect(rect.bottom, lessThanOrEqualTo(button.bottom), reason: label);
}

void main() {
  setUpAll(_loadSegoe);

  group('E282: paintInnerEdge (point 186)', () {
    test('it paints only the top band of dy px inside the rounded box, in '
        'the given color', () {
      final canvas = TestRecordingCanvas();
      final rrect = RRect.fromRectAndRadius(
        const Rect.fromLTWH(0, 0, 200, 46),
        const Radius.circular(14),
      );
      paintInnerEdge(
        canvas,
        rrect,
        dy: 1,
        color: NbColors.light.buttonHighlight,
      );

      final draws = [
        for (final call in canvas.invocations)
          if (call.invocation.memberName == #drawPath) call.invocation,
      ];
      expect(draws, hasLength(1));
      final path = draws.single.positionalArguments[0] as Path;
      final paint = draws.single.positionalArguments[1] as Paint;
      expect(paint.color, isSameColorAs(NbColors.light.buttonHighlight));
      expect(path.contains(const Offset(100, 0.5)), isTrue);
      expect(path.contains(const Offset(100, 1.5)), isFalse);
      expect(path.contains(const Offset(100, 23)), isFalse);
      expect(path.contains(const Offset(100, 46.5)), isFalse);
    });
  });

  group('E282: the five ModalButtonKind (points 186, 208 and 232)', () {
    for (final MapEntry(key: name, value: brightness) in _themes.entries) {
      final colors = _colorsFor(brightness);
      for (final kind in ModalButtonKind.values) {
        testWidgets('[$name] ${kind.name}: rest and hover with the colors, '
            'shadows and inner edge of the design, lifting 1 px', (
          tester,
        ) async {
          await _mount(
            tester,
            ModalButton(label: 'Label', kind: kind, onPressed: () {}),
            brightness: brightness,
          );
          _expectLook(
            tester,
            colors,
            _restOf(colors, kind),
            'Label',
            reason: 'rest',
          );
          expect(_transform(tester, _button).getTranslation().y, 0);

          await _hover(tester, _button);
          await tester.pump(_settle);
          _expectLook(
            tester,
            colors,
            _hoverOf(colors, kind),
            'Label',
            reason: 'hover',
          );
          expect(_transform(tester, _button).getTranslation().y, -1);
          expect(_transform(tester, _button).storage[0], 1);
        });

        testWidgets('[$name] ${kind.name}: disabled is at 50 %, without '
            'shadow, edge or hover', (tester) async {
          await _mount(
            tester,
            ModalButton(label: 'Label', kind: kind, onPressed: null),
            brightness: brightness,
          );
          await tester.pump(_settle);
          final rest = _restOf(colors, kind);
          final disabled = (
            fill: rest.fill,
            ink: rest.ink,
            shadows: const <BoxShadow>[],
            edge: null,
            border: rest.border,
          );
          expect(_opacity(tester, _button), 0.5);
          _expectLook(tester, colors, disabled, 'Label', reason: 'disabled');

          await _hover(tester, _button);
          await tester.pump(_settle);
          _expectLook(
            tester,
            colors,
            disabled,
            'Label',
            reason: 'disabled hover',
          );
          expect(_transform(tester, _button).getTranslation().y, 0);
          expect(_opacity(tester, _button), 0.5);
        });
      }

      testWidgets('[$name] text and glyph on a fill are onPrimary', (
        tester,
      ) async {
        await _mount(
          tester,
          Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (final kind in ModalButtonKind.values)
                ModalButton(
                  key: ValueKey(kind),
                  label: kind.name,
                  kind: kind,
                  glyph: Glyphs.tick,
                  onPressed: () {},
                ),
            ],
          ),
          brightness: brightness,
        );

        Color? glyphInk(ModalButtonKind kind) => IconTheme.of(
          tester.element(
            _in(find.byKey(ValueKey(kind)), find.byType(GlyphIcon)),
          ),
        ).color;

        expect(_ink(tester, 'primary'), colors.onPrimary);
        expect(glyphInk(ModalButtonKind.primary), colors.onPrimary);
        expect(glyphInk(ModalButtonKind.neutral), colors.text);
        expect(glyphInk(ModalButtonKind.negative), colors.danger);
        expect(
          tester
              .widget<GlyphIcon>(
                _in(
                  find.byKey(const ValueKey(ModalButtonKind.primary)),
                  find.byType(GlyphIcon),
                ),
              )
              .size,
          16,
        );

        final mouse = await _hover(
          tester,
          find.byKey(ValueKey(ModalButtonKind.secondary)),
        );
        for (final kind in [
          ModalButtonKind.neutral,
          ModalButtonKind.negative,
          ModalButtonKind.negativeQuiet,
        ]) {
          await mouse.moveTo(tester.getCenter(find.byKey(ValueKey(kind))));
          await tester.pump();
          await tester.pump(_settle);
          expect(_ink(tester, kind.name), colors.onPrimary, reason: kind.name);
          expect(glyphInk(kind), colors.onPrimary, reason: kind.name);
        }
      });
    }

    testWidgets('a hover changes color and shadow over 200 ms', (tester) async {
      final colors = NbColors.light;
      await _mount(
        tester,
        ModalButton(
          label: 'Label',
          kind: ModalButtonKind.primary,
          onPressed: () {},
        ),
      );

      await _hover(tester, _button);
      await tester.pump(const Duration(milliseconds: 100));
      final middle = _box(tester, _button);
      expect(middle.color, isNot(colors.primaryButton));
      expect(middle.color, isNot(colors.primaryButtonHover));

      await tester.pump(const Duration(milliseconds: 101));
      expect(_box(tester, _button).color, colors.primaryButtonHover);
      expect(_box(tester, _button).boxShadow, colors.primaryButtonHoverShadow);
    });

    for (final kind in ModalButtonKind.values) {
      testWidgets('${kind.name}: pressing scales to 0.97 and wins over the '
          'hover lift', (tester) async {
        await _mount(
          tester,
          ModalButton(label: 'Label', kind: kind, onPressed: () {}),
        );
        final mouse = await _hover(tester, _button);
        await tester.pump(_settle);

        await mouse.down(tester.getCenter(_button));
        await tester.pump();
        await tester.pump(_settle);
        final pressed = _transform(tester, _button);
        expect(pressed.storage[0], closeTo(0.97, 1e-9));
        expect(pressed.storage[5], closeTo(0.97, 1e-9));
        expect(pressed.getTranslation().y, closeTo(0, 1e-9));

        await mouse.up();
        await tester.pump();
        await tester.pump(_settle);
        expect(_transform(tester, _button).storage[0], 1);
      });
    }

    testWidgets('with reduced motion color changes are immediate and there is '
        'no lift and no scale', (tester) async {
      final colors = NbColors.light;
      await _mount(
        tester,
        ModalButton(
          label: 'Label',
          kind: ModalButtonKind.negative,
          onPressed: () {},
        ),
        reduceMotion: true,
      );

      final mouse = await _hover(tester, _button);
      await tester.pump();
      expect(_box(tester, _button).color, colors.dangerFill);
      expect(_box(tester, _button).boxShadow, colors.dangerButtonHoverShadow);
      expect(_transform(tester, _button).getTranslation().y, 0);

      await mouse.down(tester.getCenter(_button));
      await tester.pump(_settle);
      expect(_transform(tester, _button).storage[0], 1);
      await mouse.up();
      await tester.pump();
    });

    for (final MapEntry(key: name, value: brightness) in _themes.entries) {
      testWidgets('[$name] the focus ring of 2 px in primary, 2 px away, '
          'shows only with the keyboard', (tester) async {
        final colors = _colorsFor(brightness);
        for (final kind in ModalButtonKind.values) {
          await _mount(
            tester,
            ModalButton(label: 'Label', kind: kind, onPressed: () {}),
            brightness: brightness,
          );
          await tester.tapAt(const Offset(4, 4));
          await tester.pump();
          FocusScope.of(tester.element(find.byType(TextButton))).nextFocus();
          await tester.pump();
          final focused = FocusManager.instance.primaryFocus;
          expect(
            focused?.context?.findAncestorWidgetOfExactType<ModalButton>(),
            isNotNull,
            reason: kind.name,
          );
          expect(_button, isNot(_ring(colors)), reason: kind.name);

          await tester.sendKeyEvent(LogicalKeyboardKey.shiftLeft);
          await tester.pump();
          expect(FocusManager.instance.primaryFocus, same(focused));
          expect(_button, _ring(colors), reason: kind.name);
          expect(
            _button,
            _ring(colors, size: tester.getSize(_button)),
            reason: kind.name,
          );

          await tester.tapAt(const Offset(4, 4));
          await tester.pump();
          expect(FocusManager.instance.primaryFocus, same(focused));
          expect(_button, isNot(_ring(colors)), reason: kind.name);
        }
      });
    }
  });

  group('E282: wide buttons and inPair (points 186 and 218)', () {
    testWidgets('a wide button is 46 high, padded 18, in one line with an '
        'ellipsis', (tester) async {
      await _mount(
        tester,
        ModalButton(
          label: 'Label',
          kind: ModalButtonKind.primary,
          onPressed: () {},
        ),
      );

      expect(tester.getSize(_button), const Size(344, 46));
      final text = tester.widget<Text>(find.text('Label'));
      expect(text.maxLines, 1);
      expect(text.overflow, TextOverflow.ellipsis);
      final style = tester.widget<TextButton>(find.byType(TextButton)).style!;
      expect(
        style.padding!.resolve({}),
        const EdgeInsets.symmetric(horizontal: 18),
      );
      final textStyle = style.textStyle!.resolve({})!;
      expect(textStyle.fontSize, 14);
      expect(textStyle.fontWeight, FontWeight.w600);
      expect(
        textStyle.fontVariations,
        contains(FontVariation.weight(NbColors.light.headingWeight)),
      );
    });

    testWidgets('a button in a pair is padded 10 and 8 and has up to two '
        'centered lines without ellipsis, growing past 46', (tester) async {
      const label = 'A rather long label for a pair button';
      await _mount(
        tester,
        ModalButton(
          label: label,
          kind: ModalButtonKind.secondary,
          onPressed: () {},
          inPair: true,
        ),
        width: 160,
      );

      final text = tester.widget<Text>(find.text(label));
      expect(text.maxLines, 2);
      expect(text.softWrap, isTrue);
      expect(text.textAlign, TextAlign.center);
      expect(text.overflow, isNot(TextOverflow.ellipsis));
      final style = tester.widget<TextButton>(find.byType(TextButton)).style!;
      expect(
        style.padding!.resolve({}),
        const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      );
      final paragraph = tester.renderObject<RenderParagraph>(
        _in(find.text(label), find.byType(RichText)),
      );
      expect(paragraph.didExceedMaxLines, isFalse);
      expect(tester.getSize(_button).height, greaterThan(46));
    });

    testWidgets('a short label in a pair is still 46 high', (tester) async {
      await _mount(
        tester,
        ModalButton(
          label: 'OK',
          kind: ModalButtonKind.primary,
          onPressed: () {},
          inPair: true,
        ),
        width: 160,
      );
      expect(tester.getSize(_button).height, 46);
    });

    testWidgets('the real Segoe UI is loaded for the next cases', (
      tester,
    ) async {
      double widthOf(String text) {
        final painter = TextPainter(
          text: TextSpan(text: text, style: NbText.body),
          textDirection: TextDirection.ltr,
        )..layout();
        final width = painter.width;
        painter.dispose();
        return width;
      }

      expect(widthOf('iiiiiiiiii'), lessThan(widthOf('WWWWWWWWWW') / 2));
    });

    for (final code in languageCodes) {
      final strings = stringsFor(code);
      final rows = [
        (strings.doesNotMatchButton, strings.matchesButton),
        (strings.no, strings.yes),
        (strings.keepBothButton, strings.replaceButton),
        (strings.cancelButton, strings.unpairButton),
      ];
      for (final (first, second) in rows) {
        testWidgets('[$code] at 130 % in the 400 px frame, "$first" and '
            '"$second" are whole and of the same height (point 223)', (
          tester,
        ) async {
          await _mount(
            tester,
            const SizedBox.expand(),
            code: code,
            textScale: 1.3,
            width: 800,
          );
          await _openPair(tester, first, second);

          expect(tester.takeException(), isNull);
          final context = tester.element(find.text(first));
          expect(
            MediaQuery.textScalerOf(context).scale(14),
            closeTo(18.2, 1e-9),
          );
          expect(
            tester
                .getSize(
                  _in(find.byType(NbModal), find.byType(DecoratedBox)).first,
                )
                .width,
            400,
          );
          _expectLabelWhole(tester, first);
          _expectLabelWhole(tester, second);
          final a = tester.getRect(
            find.ancestor(of: find.text(first), matching: _button),
          );
          final b = tester.getRect(
            find.ancestor(of: find.text(second), matching: _button),
          );
          expect(a.height, b.height);
          expect(a.top, b.top);
          expect(a.height, greaterThanOrEqualTo(46));
        });
      }
    }

    testWidgets('in a pair, a label that takes two lines makes both buttons '
        'grow to the same height', (tester) async {
      await _mount(tester, const SizedBox.expand(), textScale: 1.3, width: 800);
      await _openPair(tester, 'Not on this network today', 'Yes');

      expect(tester.takeException(), isNull);
      _expectLabelWhole(tester, 'Not on this network today');
      final a = tester.getRect(
        find.ancestor(
          of: find.text('Not on this network today'),
          matching: _button,
        ),
      );
      final b = tester.getRect(
        find.ancestor(of: find.text('Yes'), matching: _button),
      );
      expect(a.height, greaterThan(46));
      expect(b.height, a.height);
    });

    testWidgets('the longest wide label, "Close and cancel", fits in one line '
        'at 130 %', (tester) async {
      await _mount(
        tester,
        ModalButton(
          label: 'Close and cancel',
          kind: ModalButtonKind.negativeQuiet,
          onPressed: () {},
        ),
        textScale: 1.3,
      );
      _expectLabelWhole(tester, 'Close and cancel');
    });
  });

  group('E282: ChoiceTile (points 186 and 212)', () {
    for (final MapEntry(key: name, value: brightness) in _themes.entries) {
      testWidgets('[$name] at rest: card, border and small shadow, the icon '
          'box and the texts of the design', (tester) async {
        final colors = _colorsFor(brightness);
        await _mount(
          tester,
          Row(
            children: [
              Expanded(child: _tileWith(onPressed: () {})),
              const SizedBox(width: 10),
              Expanded(
                child: ChoiceTile(
                  title: 'Someone else',
                  detail: 'Not mine',
                  glyph: Glyphs.someoneElse,
                  neutral: true,
                  onPressed: () {},
                ),
              ),
            ],
          ),
          brightness: brightness,
        );
        final mine = find.byType(ChoiceTile).first;
        final other = find.byType(ChoiceTile).last;

        final box = _box(tester, mine);
        expect(box.color, colors.card);
        expect(box.borderRadius, BorderRadius.circular(16));
        expect(box.boxShadow, [
          BoxShadow(
            color: colors.nodeShadow,
            offset: const Offset(0, 1),
            blurRadius: 2,
          ),
        ]);
        expect(_border(tester, mine)!.top.color, colors.border);
        expect(_border(tester, mine)!.top.width, 1.5);
        expect(
          tester
              .widget<TextButton>(_in(mine, find.byType(TextButton)))
              .style!
              .padding!
              .resolve({}),
          const EdgeInsets.fromLTRB(12, 16, 12, 14),
        );

        BoxDecoration iconBox(Finder tile) =>
            tester
                    .widget<DecoratedBox>(
                      _in(
                        tile,
                        find.byWidgetPredicate(
                          (widget) =>
                              widget is DecoratedBox &&
                              widget.decoration is BoxDecoration &&
                              (widget.decoration as BoxDecoration)
                                      .borderRadius ==
                                  BorderRadius.circular(12),
                        ),
                      ),
                    )
                    .decoration
                as BoxDecoration;
        GlyphIcon glyph(Finder tile) =>
            tester.widget<GlyphIcon>(_in(tile, find.byType(GlyphIcon)));

        expect(iconBox(mine).color, colors.primaryWeak);
        expect(iconBox(mine).border, isNull);
        expect(glyph(mine).color, colors.primaryInk);
        expect(glyph(mine).size, 22);
        expect(iconBox(other).color, colors.neutralWeak);
        final otherBorder = iconBox(other).border! as Border;
        expect(otherBorder.top.color, colors.border);
        expect(otherBorder.top.width, 1);
        expect(glyph(other).color, colors.textWeak);
        expect(
          tester.getSize(_in(mine, find.byType(GlyphIcon))),
          const Size(22, 22),
        );

        final title = tester.widget<Text>(find.text('It is mine')).style!;
        expect(title.fontSize, 14);
        expect(title.height, closeTo(18 / 14, 1e-9));
        expect(title.fontWeight, FontWeight.w600);
        expect(title.color, colors.text);
        final detail = tester.widget<Text>(find.text('I use it myself')).style!;
        expect(detail.fontSize, 12);
        expect(detail.height, closeTo(16 / 12, 1e-9));
        expect(detail.color, colors.textWeak);
      });

      testWidgets('[$name] hover lifts 2 px with a primary border and the '
          'long shadow, and tells onHover', (tester) async {
        final colors = _colorsFor(brightness);
        final hovers = <bool>[];
        await _mount(
          tester,
          _tileWith(onPressed: () {}, onHover: hovers.add),
          brightness: brightness,
        );

        final mouse = await _hover(tester, _tile);
        await tester.pump(_settle);
        expect(hovers, [true]);
        expect(_transform(tester, _tile).getTranslation().y, -2);
        expect(_border(tester, _tile)!.top.color, colors.primary);
        expect(_box(tester, _tile).boxShadow, [
          BoxShadow(
            color: colors.nodeShadow,
            offset: const Offset(0, 12),
            blurRadius: 24,
            spreadRadius: -12,
          ),
        ]);

        await mouse.moveTo(Offset.zero);
        await tester.pump();
        await tester.pump(_settle);
        expect(hovers, [true, false]);
        expect(_transform(tester, _tile).getTranslation().y, 0);
        expect(_border(tester, _tile)!.top.color, colors.border);
      });
    }

    testWidgets('pressing scales to 0.97', (tester) async {
      await _mount(tester, _tileWith(onPressed: () {}));
      final mouse = await _hover(tester, _tile);
      await tester.pump(_settle);
      await mouse.down(tester.getCenter(_tile));
      await tester.pump();
      await tester.pump(_settle);
      expect(_transform(tester, _tile).storage[0], closeTo(0.97, 1e-9));
      expect(_transform(tester, _tile).getTranslation().y, closeTo(0, 1e-9));
      await mouse.up();
      await tester.pump(_settle);
    });

    testWidgets('with onPressed null it never calls onHover, is at 50 % and '
        'does not react to the mouse (point 212)', (tester) async {
      final colors = NbColors.light;
      final hovers = <bool>[];
      await _mount(tester, _tileWith(onHover: hovers.add));

      final mouse = await _hover(tester, _tile);
      await tester.pump(_settle);
      expect(hovers, isEmpty);
      expect(_opacity(tester, _tile), 0.5);
      expect(_transform(tester, _tile).getTranslation().y, 0);
      expect(_border(tester, _tile)!.top.color, colors.border);

      await mouse.moveTo(Offset.zero);
      await tester.pump(_settle);
      expect(hovers, isEmpty);
    });

    testWidgets('a tile that is disabled while hovered does not call onHover '
        'when the mouse leaves (point 212)', (tester) async {
      final hovers = <bool>[];
      final enabled = ValueNotifier(true);
      await _mount(
        tester,
        ValueListenableBuilder<bool>(
          valueListenable: enabled,
          builder: (context, on, _) =>
              _tileWith(onPressed: on ? () {} : null, onHover: hovers.add),
        ),
      );

      final mouse = await _hover(tester, _tile);
      await tester.pump(_settle);
      expect(hovers, [true]);

      enabled.value = false;
      await tester.pump(_settle);
      await mouse.moveTo(Offset.zero);
      await tester.pump(_settle);
      expect(hovers, [true]);
    });

    testWidgets('the keyboard focus counts as hover and shows the ring', (
      tester,
    ) async {
      final colors = NbColors.light;
      final hovers = <bool>[];
      await _mount(tester, _tileWith(onPressed: () {}, onHover: hovers.add));

      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pump();
      await tester.pump(_settle);
      expect(hovers, [true]);
      expect(_border(tester, _tile)!.top.color, colors.primary);
      expect(_tile, _ring(colors));
    });

    for (final (neutral, expected) in [
      (false, 'primary'),
      (true, 'textWeak'),
    ]) {
      testWidgets('selected ${neutral ? 'neutral' : 'own'} tile has a '
          '$expected border', (tester) async {
        final colors = NbColors.light;
        await _mount(
          tester,
          _tileWith(onPressed: null, neutral: neutral, selected: true),
        );
        expect(
          _border(tester, _tile)!.top.color,
          neutral ? colors.textWeak : colors.primary,
        );
        expect(_border(tester, _tile)!.top.width, 1.5);
      });
    }

    testWidgets('dimmed fades to 0.35 in 300 ms', (tester) async {
      final dimmed = ValueNotifier(false);
      await _mount(
        tester,
        ValueListenableBuilder<bool>(
          valueListenable: dimmed,
          builder: (context, on, _) => _tileWith(onPressed: null, dimmed: on),
        ),
      );
      await tester.pump(_settle);
      expect(_opacity(tester, _tile), 0.5);

      dimmed.value = true;
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 150));
      expect(_opacity(tester, _tile), lessThan(0.5));
      expect(_opacity(tester, _tile), greaterThan(0.35));

      await tester.pump(const Duration(milliseconds: 151));
      expect(_opacity(tester, _tile), 0.35);
    });

    testWidgets('dimmed with reduced motion is 0.35 at once', (tester) async {
      await _mount(
        tester,
        _tileWith(onPressed: () {}, dimmed: true),
        reduceMotion: true,
      );
      expect(_opacity(tester, _tile), 0.35);
    });

    testWidgets('the screen reader reads it as a button with its title and '
        'detail', (tester) async {
      final handle = tester.ensureSemantics();
      await _mount(tester, _tileWith(onPressed: () {}));

      final nodes = _semanticsUnder(tester, _tile);
      final button = nodes.where(
        (data) =>
            data.flagsCollection.isButton &&
            data.label.contains('It is mine') &&
            data.label.contains('I use it myself'),
      );
      expect(button, isNotEmpty);
      handle.dispose();
    });
  });

  group('E282: colors only from the tokens (point 223)', () {
    test('the two new files write no color literal and no white constant', () {
      for (final path in [
        'lib/src/ui/modal/modal_frame.dart',
        'lib/src/ui/modal/modal_button.dart',
      ]) {
        final source = File(path).readAsStringSync();
        expect(source.contains('Color(0x'), isFalse, reason: path);
        expect(source.contains('Color.fromRGBO('), isFalse, reason: path);
        expect(source.contains('Color.fromARGB('), isFalse, reason: path);
        expect(source.contains('_white'), isFalse, reason: path);
        expect(
          RegExp(r'(?<![A-Za-z])Colors\.(?!transparent\b)').hasMatch(source),
          isFalse,
          reason: path,
        );
      }
    });
  });
}
