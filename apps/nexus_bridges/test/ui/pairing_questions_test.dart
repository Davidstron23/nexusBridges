import 'dart:async';
import 'dart:io';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nexus_bridges/src/l10n/app_strings.dart';
import 'package:nexus_bridges/src/ui/armed.dart';
import 'package:nexus_bridges/src/ui/icons/device_disc.dart';
import 'package:nexus_bridges/src/ui/icons/glyphs.dart';
import 'package:nexus_bridges/src/ui/modal/modal_button.dart';
import 'package:nexus_bridges/src/ui/modal/modal_frame.dart';
import 'package:nexus_bridges/src/ui/modal/stage.dart';
import 'package:nexus_bridges/src/ui/modal/stage_choices.dart';
import 'package:nexus_bridges/src/ui/modal/stage_kit.dart';
import 'package:nexus_bridges/src/ui/pairing_questions.dart';
import 'package:nexus_bridges/src/ui/theme/app_theme.dart';
import 'package:nexus_bridges/src/ui/theme/components.dart';
import 'package:nexus_bridges/src/ui/theme/tokens.dart';
import 'package:nexus_bridges_core/nexus_bridges_core.dart';

import 'fake_app_controller.dart';

const Map<String, Brightness> _themes = {
  'light': Brightness.light,
  'dark': Brightness.dark,
};

NbColors _colorsFor(Brightness brightness) =>
    brightness == Brightness.dark ? NbColors.dark : NbColors.light;

const String _newShort = '9F3A7C21';
const String _oldShort = '5B6E0D48';
final String _newFp = fingerprintOf(_newShort);
final String _oldFp = fingerprintOf(_oldShort);
const String _newName = 'Phone of Ana';
const String _oldName = 'Old phone';
const String _longNew = 'Portable workstation of Ana in the studio';
const String _longOld = 'Former portable workstation of Ana at home';

final ReplaceQuestion _replace = ReplaceQuestion(
  fingerprint: _newFp,
  deviceName: _newName,
  oldFingerprint: _oldFp,
  oldName: _oldName,
);

final MineQuestion _mine = MineQuestion(
  fingerprint: _newFp,
  deviceName: _newName,
);

const Map<String, Map<String, String>> _specTexts = {
  'es': {
    'question': '¿Este equipo es tuyo?',
    'yes': 'Es mío',
    'yesDetail':
        'Lo que envíe entra sin preguntar y puede explorar las carpetas '
        'que compartas.',
    'no': 'Es de otra persona',
    'noDetail': 'Siempre te pedirá permiso antes de enviarte nada.',
    'keepBoth': 'Conservar ambos',
    'replaceBody':
        '$_newName se llama igual que uno vinculado que no está a la '
        'vista. Si es el mismo reinstalado, sustitúyelo.',
  },
  'en': {
    'question': 'Is this device yours?',
    'yes': "It's mine",
    'yesDetail':
        'What it sends comes in without asking and it can browse the folders '
        'you share.',
    'no': "It's someone else's",
    'noDetail':
        'It will always ask for your permission before sending you anything.',
    'keepBoth': 'Keep both',
    'replaceBody':
        '$_newName has the same name as a paired device that is not visible. '
        'If it is the same one reinstalled, replace it.',
  },
};

DeviceEntry _entry({
  required String fingerprint,
  required String name,
  DeviceType? type = DeviceType.desktop,
  bool visible = true,
  bool mine = false,
}) {
  return DeviceEntry(
    fingerprint: fingerprint,
    displayName: name,
    deviceType: type,
    visible: visible,
    paired: true,
    mine: mine,
    ignored: false,
    mismatch: false,
    possiblyReplaces: null,
  );
}

FakeAppController _controllerWith(List<DeviceEntry> entries) =>
    FakeAppController(state: NodeState(entries: entries));

final GlobalKey _homeKey = GlobalKey();

Future<void> _mount(
  WidgetTester tester, {
  String code = 'en',
  Brightness brightness = Brightness.dark,
  bool reduceMotion = false,
  double textScale = 1,
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
      home: Scaffold(key: _homeKey, body: const SizedBox.expand()),
    ),
  );
}

final class _Log {
  final List<String> events = [];

  void answer(bool value, {bool farewell = false}) =>
      events.add('answer $value farewell $farewell');

  void farewellDone() => events.add('farewellDone');

  void dismiss() => events.add('dismiss');

  int count(String event) => events.where((e) => e == event).length;
}

const String _answeredMine = 'answer true farewell true';
const String _answeredOther = 'answer false farewell true';
const String _replaced = 'answer true farewell false';
const String _keptBoth = 'answer false farewell false';

Widget _questionView(
  FakeAppController controller,
  PairingQuestion question,
  _Log log,
) {
  return PairingQuestionView(
    controller: controller,
    question: question,
    onAnswer: log.answer,
    onFarewellDone: log.farewellDone,
  );
}

Future<NbModalRoute<void>> _open(
  WidgetTester tester, {
  required FakeAppController controller,
  required PairingQuestion question,
  required _Log log,
  bool finish = true,
  WidgetBuilder? builder,
}) async {
  final context = _homeKey.currentContext!;
  final route = NbModalRoute<void>(
    context: context,
    builder: builder ?? (context) => _questionView(controller, question, log),
    onDismiss: () => log.dismiss,
  );
  unawaited(Navigator.of(context).push(route));
  await tester.pump();
  if (finish) await tester.pump(modalTransitionDuration);
  return route;
}

Future<void> _arm(WidgetTester tester) => tester.pump(dialogActivationDelay);

AppStrings _strings(WidgetTester tester) =>
    AppStringsDelegate.of(tester.element(find.byType(PairingQuestionView)));

Finder _in(Finder scope, Finder matching) =>
    find.descendant(of: scope, matching: matching);

Finder get _tiles => find.byType(ChoiceTile);

ChoiceTile _tile(WidgetTester tester, int index) =>
    tester.widget<ChoiceTile>(_tiles.at(index));

double _tileOpacity(WidgetTester tester, int index) => tester
    .widget<FadeTransition>(_in(_tiles.at(index), find.byType(FadeTransition)))
    .opacity
    .value;

ModalStage _stage(WidgetTester tester) =>
    tester.widget<ModalStage>(find.byType(ModalStage));

StagePainter _painter(WidgetTester tester) =>
    tester
            .widget<CustomPaint>(
              _in(find.byType(ModalStage), find.byType(CustomPaint)),
            )
            .painter!
        as StagePainter;

Finder _buttonOf(String label) =>
    find.ancestor(of: find.text(label), matching: find.byType(ModalButton));

ModalButton _button(WidgetTester tester, String label) =>
    tester.widget<ModalButton>(_buttonOf(label));

Finder _rowOf(String name) => find
    .ancestor(
      of: find.text(name),
      matching: find.byWidgetPredicate(
        (widget) =>
            widget is Container &&
            widget.decoration is BoxDecoration &&
            (widget.decoration! as BoxDecoration).borderRadius ==
                BorderRadius.circular(16),
      ),
    )
    .first;

Container _rowBox(WidgetTester tester, String name) =>
    tester.widget<Container>(_rowOf(name));

Finder _nearest(Finder of, Type type) =>
    find.ancestor(of: of, matching: find.byType(type)).first;

double _opacityAbove(WidgetTester tester, Finder of) =>
    tester.widget<Opacity>(_nearest(of, Opacity)).opacity;

Matrix4 _transformAbove(WidgetTester tester, Finder of, {int index = 0}) =>
    tester
        .widget<Transform>(
          find.ancestor(of: of, matching: find.byType(Transform)).at(index),
        )
        .transform;

Finder get _arrowGlyph => find.byWidgetPredicate(
  (widget) => widget is GlyphIcon && identical(widget.glyph, Glyphs.arrowDown),
);

Finder get _arrowBadge =>
    find.ancestor(of: _arrowGlyph, matching: find.byType(CustomPaint)).first;

DeviceDisc _disc(WidgetTester tester, String name) =>
    tester.widget<DeviceDisc>(_in(_rowOf(name), find.byType(DeviceDisc)));

Finder _discOf(String name) => _in(_rowOf(name), find.byType(DeviceDisc));

Future<TestGesture> _mouse(WidgetTester tester) async {
  final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
  await mouse.addPointer(location: Offset.zero);
  addTearDown(mouse.removePointer);
  return mouse;
}

Future<void> _moveTo(WidgetTester tester, TestGesture mouse, Finder to) async {
  await mouse.moveTo(tester.getCenter(to));
  await tester.pump();
}

Future<void> _click(WidgetTester tester, TestGesture mouse, Finder on) async {
  await mouse.moveTo(tester.getCenter(on));
  await mouse.down(tester.getCenter(on));
  await mouse.up();
}

bool _focusInside(Finder scope) {
  final focused = FocusManager.instance.primaryFocus?.context;
  if (focused == null) return false;
  return _in(
    scope,
    find.byElementPredicate((element) => element == focused),
  ).evaluate().isNotEmpty;
}

FocusNode _frameFocus(WidgetTester tester) => ModalViewSwitcher.frameFocusOf(
  tester.element(find.byType(ModalViewSwitcher)),
)!;

void _expectNoParagraphCut(WidgetTester tester, Finder scope) {
  for (final element in _in(scope, find.byType(RichText)).evaluate()) {
    final paragraph = element.renderObject! as RenderParagraph;
    expect(
      paragraph.didExceedMaxLines,
      isFalse,
      reason: paragraph.text.toPlainText(),
    );
  }
}

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

double _widthOf(String text, TextStyle style) {
  final painter = TextPainter(
    text: TextSpan(text: text, style: style),
    textDirection: TextDirection.ltr,
  )..layout();
  final width = painter.width;
  painter.dispose();
  return width;
}

void main() {
  group('E288: "Is it yours?" texts and layout (RF-98, point 192)', () {
    for (final code in languageCodes) {
      testWidgets('[$code] the title, the question and the two tiles with the '
          'texts of the spec, "It\'s mine" first', (tester) async {
        final texts = _specTexts[code]!;
        await _mount(tester, code: code, reduceMotion: true);
        final log = _Log();
        await _open(
          tester,
          controller: _controllerWith([
            _entry(fingerprint: _newFp, name: _newName),
          ]),
          question: _mine,
          log: log,
        );
        final strings = _strings(tester);

        expect(find.text(strings.mineTitle(_newName)), findsOneWidget);
        final lead = tester.widget<ModalLead>(find.byType(ModalLead));
        expect(lead.text, texts['question']);
        expect(lead.tight, isFalse);
        expect(find.text(texts['question']!), findsOneWidget);

        expect(_tiles, findsNWidgets(2));
        final yes = _tile(tester, 0);
        final no = _tile(tester, 1);
        expect(yes.title, texts['yes']);
        expect(yes.detail, texts['yesDetail']);
        expect(identical(yes.glyph, Glyphs.mine), isTrue);
        expect(yes.neutral, isFalse);
        expect(no.title, texts['no']);
        expect(no.detail, texts['noDetail']);
        expect(identical(no.glyph, Glyphs.someoneElse), isTrue);
        expect(no.neutral, isTrue);
        expect(
          tester.getCenter(_tiles.at(0)).dx,
          lessThan(tester.getCenter(_tiles.at(1)).dx),
        );
        expect(find.byType(ModalButton), findsNothing);
        expect(log.events, isEmpty);
      });
    }

    testWidgets('the stage is the "mine" scene above the title, with no hover '
        'and no pick', (tester) async {
      await _mount(tester, reduceMotion: true);
      await _open(
        tester,
        controller: _controllerWith(const []),
        question: _mine,
        log: _Log(),
      );
      final strings = _strings(tester);

      expect(_stage(tester).scene, StageScene.mine);
      expect(_stage(tester).input.hovered, isNull);
      expect(_stage(tester).input.picked, isNull);
      expect(
        tester.getRect(find.byType(ModalStage)).bottom,
        lessThanOrEqualTo(
          tester.getRect(find.text(strings.mineTitle(_newName))).top,
        ),
      );
      expect(
        tester.getRect(find.text(strings.mineTitle(_newName))).bottom,
        lessThanOrEqualTo(tester.getRect(find.byType(ModalLead)).top),
      );
    });

    testWidgets('the two tiles sit side by side, 10 px apart, with the same '
        'height and 16 px under the top zone', (tester) async {
      await _mount(tester, reduceMotion: true);
      await _open(
        tester,
        controller: _controllerWith(const []),
        question: _mine,
        log: _Log(),
      );

      final left = tester.getRect(_tiles.at(0));
      final right = tester.getRect(_tiles.at(1));
      expect(left.top, right.top);
      expect(left.height, right.height);
      expect(right.left - left.right, 10);
      final zone = tester.getRect(
        _in(find.byType(ModalView), find.byType(SingleChildScrollView)),
      );
      expect(left.top - zone.bottom, 16);
    });

    for (final (label, type, glyph) in [
      ('no entry', null, DeviceGlyph.pc),
      ('a desktop', DeviceType.desktop, DeviceGlyph.pc),
      ('a phone', DeviceType.mobile, DeviceGlyph.phone),
    ]) {
      testWidgets('with $label for the fingerprint, the knob shows '
          '${glyph.name} (point 213)', (tester) async {
        await _mount(tester, reduceMotion: true);
        await _open(
          tester,
          controller: _controllerWith([
            _entry(
              fingerprint: fingerprintOf('77777777'),
              name: 'Other',
              type: DeviceType.mobile,
            ),
            if (type != null)
              _entry(fingerprint: _newFp, name: _newName, type: type),
          ]),
          question: _mine,
          log: _Log(),
        );
        expect(_stage(tester).input.peer, glyph);
      });
    }

    testWidgets('with no state at all, the knob shows the pc', (tester) async {
      await _mount(tester, reduceMotion: true);
      await _open(
        tester,
        controller: FakeAppController(),
        question: _mine,
        log: _Log(),
      );
      expect(_stage(tester).input.peer, DeviceGlyph.pc);
    });

    testWidgets('it follows the controller: an entry that arrives later '
        'changes the knob', (tester) async {
      await _mount(tester, reduceMotion: true);
      final controller = _controllerWith(const []);
      await _open(tester, controller: controller, question: _mine, log: _Log());
      expect(_stage(tester).input.peer, DeviceGlyph.pc);

      controller.emit(
        NodeState(
          entries: [
            _entry(
              fingerprint: _newFp,
              name: _newName,
              type: DeviceType.mobile,
            ),
          ],
        ),
      );
      await tester.pump();
      expect(_stage(tester).input.peer, DeviceGlyph.phone);
    });
  });

  group('E288: "Is it yours?" arming (RF-83 note)', () {
    for (final reduceMotion in [false, true]) {
      final mode = reduceMotion ? 'reduced motion' : 'in motion';
      for (final (index, expected) in [
        (0, _answeredMine),
        (1, _answeredOther),
      ]) {
        testWidgets('[$mode] tile $index does not answer at 0 or 499 ms and '
            'answers at 500 ms', (tester) async {
          await _mount(tester, reduceMotion: reduceMotion);
          final log = _Log();
          await _open(
            tester,
            controller: _controllerWith(const []),
            question: _mine,
            log: log,
            finish: false,
          );

          expect(_tile(tester, 0).onPressed, isNull);
          expect(_tile(tester, 1).onPressed, isNull);
          await tester.tap(_tiles.at(index), warnIfMissed: false);
          await tester.pump();
          expect(log.events, isEmpty);

          await tester.pump(const Duration(milliseconds: 499));
          expect(_tile(tester, index).onPressed, isNull);
          await tester.tap(_tiles.at(index), warnIfMissed: false);
          await tester.pump();
          expect(log.events, isEmpty);

          await tester.pump(const Duration(milliseconds: 1));
          expect(_tile(tester, 0).onPressed, isNotNull);
          expect(_tile(tester, 1).onPressed, isNotNull);
          await tester.tap(_tiles.at(index));
          expect(log.events.first, expected);
          expect(log.count(expected), 1);
          await tester.pump(const Duration(seconds: 2));
        });
      }
    }
  });

  group('E288: "Is it yours?" picking and farewell (RF-99, RF-100, '
      'points 192 and 237)', () {
    for (final (index, own, expected) in [
      (0, Own.mine, _answeredMine),
      (1, Own.other, _answeredOther),
    ]) {
      testWidgets('in motion, tile $index answers at once with farewell, '
          'disables both tiles and calls onFarewellDone at 1.75 s', (
        tester,
      ) async {
        await _mount(tester);
        final log = _Log();
        await _open(
          tester,
          controller: _controllerWith(const []),
          question: _mine,
          log: log,
        );
        await _arm(tester);

        await tester.tap(_tiles.at(index));
        expect(log.events, [expected]);

        await tester.pump();
        final picked = _tile(tester, index);
        final otherIndex = 1 - index;
        final other = _tile(tester, otherIndex);
        expect(picked.onPressed, isNull);
        expect(other.onPressed, isNull);
        expect(picked.selected, isTrue);
        expect(picked.dimmed, isFalse);
        expect(other.selected, isFalse);
        expect(other.dimmed, isTrue);
        expect(_stage(tester).input.picked, own);

        await tester.pump(const Duration(milliseconds: 400));
        expect(_tileOpacity(tester, index), 1);
        expect(_tileOpacity(tester, otherIndex), 0.35);
        expect(log.events, [expected]);

        await tester.pump(const Duration(milliseconds: 1349));
        expect(log.events, [expected]);
        await tester.pump(const Duration(milliseconds: 1));
        expect(log.events, [expected, 'farewellDone']);

        await tester.pump(const Duration(seconds: 3));
        expect(log.count('farewellDone'), 1);
        expect(log.count(expected), 1);
      });

      testWidgets('with reduced motion, tile $index answers with farewell and '
          'calls onFarewellDone in the same frame', (tester) async {
        await _mount(tester, reduceMotion: true);
        final log = _Log();
        await _open(
          tester,
          controller: _controllerWith(const []),
          question: _mine,
          log: log,
        );
        await _arm(tester);

        await tester.tap(_tiles.at(index));
        expect(log.events, [expected, 'farewellDone']);

        await tester.pump();
        expect(_tile(tester, index).selected, isTrue);
        expect(_tile(tester, 1 - index).dimmed, isTrue);
        expect(_tileOpacity(tester, index), 1);
        expect(_tileOpacity(tester, 1 - index), 0.35);

        await tester.pump(const Duration(seconds: 3));
        expect(log.events, [expected, 'farewellDone']);
      });
    }

    testWidgets('after picking, no click and no key gives a second answer', (
      tester,
    ) async {
      await _mount(tester);
      final log = _Log();
      await _open(
        tester,
        controller: _controllerWith(const []),
        question: _mine,
        log: log,
      );
      await _arm(tester);

      await tester.tap(_tiles.at(0));
      await tester.pump();
      await tester.tap(_tiles.at(1), warnIfMissed: false);
      await tester.tap(_tiles.at(0), warnIfMissed: false);
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.sendKeyEvent(LogicalKeyboardKey.space);
      await tester.pump(const Duration(milliseconds: 600));
      expect(log.events, [_answeredMine]);
      expect(_tile(tester, 0).selected, isTrue);
      expect(_tile(tester, 1).dimmed, isTrue);

      await tester.pump(const Duration(seconds: 2));
      expect(log.events, [_answeredMine, 'farewellDone']);
    });

    testWidgets('a view that goes away during the farewell never calls '
        'onFarewellDone and leaves no timer', (tester) async {
      await _mount(tester);
      final log = _Log();
      final route = await _open(
        tester,
        controller: _controllerWith(const []),
        question: _mine,
        log: log,
      );
      await _arm(tester);
      await tester.tap(_tiles.at(0));
      await tester.pump(const Duration(seconds: 1));

      Navigator.of(_homeKey.currentContext!).removeRoute(route);
      await tester.pump();
      expect(find.byType(PairingQuestionView), findsNothing);
      await tester.pump(const Duration(seconds: 3));
      expect(log.events, [_answeredMine]);
      expect(tester.takeException(), isNull);
    });

    testWidgets('the keyboard reaches "It\'s mine" with Tab and Enter picks '
        'it', (tester) async {
      await _mount(tester);
      final log = _Log();
      await _open(
        tester,
        controller: _controllerWith(const []),
        question: _mine,
        log: log,
      );
      await _arm(tester);

      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pump();
      expect(_focusInside(_tiles.at(0)), isTrue);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pump();
      expect(log.events, [_answeredMine]);
      await tester.pump(const Duration(seconds: 2));
    });

    testWidgets('Esc with the question on screen reaches the frame', (
      tester,
    ) async {
      await _mount(tester);
      final log = _Log();
      await _open(
        tester,
        controller: _controllerWith(const []),
        question: _mine,
        log: log,
        finish: false,
      );
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pump();
      expect(log.events, ['dismiss']);
      await tester.pump(const Duration(seconds: 1));
    });
  });

  group('E288: "Is it yours?" hover (points 212 and 223)', () {
    testWidgets('armed, the hover over each tile moves the knob through '
        'StageInput.hovered', (tester) async {
      await _mount(tester);
      await _open(
        tester,
        controller: _controllerWith(const []),
        question: _mine,
        log: _Log(),
      );
      await _arm(tester);
      final mouse = await _mouse(tester);

      await _moveTo(tester, mouse, _tiles.at(0));
      expect(_stage(tester).input.hovered, Own.mine);
      await _moveTo(tester, mouse, _tiles.at(1));
      expect(_stage(tester).input.hovered, Own.other);
      await mouse.moveTo(Offset.zero);
      await tester.pump();
      expect(_stage(tester).input.hovered, isNull);
      await tester.pump(const Duration(seconds: 1));
    });

    testWidgets('unarmed, the hover over a tile does not change '
        'StageInput.hovered', (tester) async {
      await _mount(tester);
      await _open(
        tester,
        controller: _controllerWith(const []),
        question: _mine,
        log: _Log(),
        finish: false,
      );
      final mouse = await _mouse(tester);

      await _moveTo(tester, mouse, _tiles.at(0));
      expect(_stage(tester).input.hovered, isNull);
      await tester.pump(const Duration(milliseconds: 200));
      await _moveTo(tester, mouse, _tiles.at(1));
      expect(_stage(tester).input.hovered, isNull);
      await tester.pump(const Duration(milliseconds: 200));
      await mouse.moveTo(Offset.zero);
      await tester.pump();
      expect(_stage(tester).input.hovered, isNull);
      await tester.pump(const Duration(milliseconds: 200));
    });

    testWidgets('after picking, the hover is frozen at its last value', (
      tester,
    ) async {
      await _mount(tester);
      await _open(
        tester,
        controller: _controllerWith(const []),
        question: _mine,
        log: _Log(),
      );
      await _arm(tester);
      final mouse = await _mouse(tester);

      await _moveTo(tester, mouse, _tiles.at(0));
      await _click(tester, mouse, _tiles.at(0));
      await tester.pump();
      expect(_stage(tester).input.picked, Own.mine);
      expect(_stage(tester).input.hovered, Own.mine);

      await _moveTo(tester, mouse, _tiles.at(1));
      expect(_stage(tester).input.hovered, Own.mine);
      expect(_painter(tester).input.hovered, Own.mine);
      await mouse.moveTo(Offset.zero);
      await tester.pump();
      expect(_stage(tester).input.hovered, Own.mine);
      expect(_painter(tester).input.hovered, Own.mine);
      await tester.pump(const Duration(seconds: 2));
    });

    testWidgets('a hover that changes side mid-travel starts from the knob '
        'x of that instant (mineKnobX)', (tester) async {
      await _mount(tester);
      await _open(
        tester,
        controller: _controllerWith(const []),
        question: _mine,
        log: _Log(),
      );
      await _arm(tester);
      final mouse = await _mouse(tester);

      await _moveTo(tester, mouse, _tiles.at(0));
      await tester.pump(const Duration(milliseconds: 300));
      final before = _painter(tester);
      expect(before.input.hovered, Own.mine);
      final settledMine = mineKnobX(
        StageFrame(
          t: 100,
          still: false,
          colors: before.colors,
          input: before.input,
          changes: before.changes,
        ),
      );

      await _moveTo(tester, mouse, _tiles.at(1));
      final after = _painter(tester);
      expect(after.input.hovered, Own.other);
      expect(after.changes.hoveredFrom, Own.mine);
      final at = after.changes.hoveredAt!;
      expect(at, greaterThan(before.changes.hoveredAt!));
      final expected = mineKnobX(
        StageFrame(
          t: at,
          still: false,
          colors: before.colors,
          input: before.input,
          changes: before.changes,
        ),
      );
      expect(after.changes.knobFrom, closeTo(expected, 1e-9));
      expect(after.changes.knobFrom, isNot(closeTo(settledMine, 0.5)));
      expect(after.changes.knobFrom!.abs(), lessThan(settledMine.abs()));
      expect(
        mineKnobX(
          StageFrame(
            t: at,
            still: false,
            colors: after.colors,
            input: after.input,
            changes: after.changes,
          ),
        ),
        closeTo(expected, 1e-9),
      );
      await tester.pump(const Duration(seconds: 1));
    });
  });

  group('E288: focus goes back to the frame (point 229)', () {
    testWidgets('with the focus on "It\'s mine" and the view cut by a new '
        'one, the focus goes back to the frame and Esc still reaches it', (
      tester,
    ) async {
      await _mount(tester);
      final log = _Log();
      final controller = _controllerWith(const []);
      final showQuestion = ValueNotifier(true);
      addTearDown(showQuestion.dispose);
      await _open(
        tester,
        controller: controller,
        question: _mine,
        log: log,
        builder: (context) => ValueListenableBuilder<bool>(
          valueListenable: showQuestion,
          builder: (context, on, _) => ModalViewSwitcher(
            viewKey: on ? ('question', _mine) : 'connecting',
            child: on
                ? _questionView(controller, _mine, log)
                : const ModalView(title: 'Connecting'),
          ),
        ),
      );
      await _arm(tester);
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pump();
      expect(_focusInside(_tiles.at(0)), isTrue);

      showQuestion.value = false;
      await tester.pump();
      await tester.pump();
      expect(FocusManager.instance.primaryFocus, _frameFocus(tester));

      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pump();
      expect(log.events, ['dismiss']);
      await tester.pump(const Duration(seconds: 1));
    });

    testWidgets('Tab and Enter on "Close" of the result open "Replace?" and '
        'Esc then reaches the frame once', (tester) async {
      await _mount(tester);
      final log = _Log();
      final controller = _controllerWith(const []);
      final showQuestion = ValueNotifier(false);
      addTearDown(showQuestion.dispose);
      await _open(
        tester,
        controller: controller,
        question: _replace,
        log: log,
        builder: (context) => ValueListenableBuilder<bool>(
          valueListenable: showQuestion,
          builder: (context, on, _) => ModalViewSwitcher(
            viewKey: on ? ('question', _replace) : 'result',
            child: on
                ? _questionView(controller, _replace, log)
                : ModalView(
                    title: 'Paired',
                    actions: [
                      ModalButton(
                        label: 'Close',
                        kind: ModalButtonKind.primary,
                        onPressed: () => showQuestion.value = true,
                      ),
                    ],
                  ),
          ),
        ),
      );
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pump();
      expect(_focusInside(_buttonOf('Close')), isTrue);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pump();
      await tester.pump();
      expect(find.byType(PairingQuestionView), findsOneWidget);
      expect(FocusManager.instance.primaryFocus, _frameFocus(tester));

      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pump();
      expect(log.events, ['dismiss']);
      await tester.pump(const Duration(seconds: 2));
      expect(log.events, ['dismiss']);
    });
  });

  group('E288: "Replace?" texts and buttons (RF-125 to RF-127, point 192)', () {
    for (final code in languageCodes) {
      testWidgets('[$code] the title first, the short body of the spec, '
          '"Keep both" and "Replace"', (tester) async {
        final texts = _specTexts[code]!;
        await _mount(tester, code: code, reduceMotion: true);
        await _open(
          tester,
          controller: _controllerWith(const []),
          question: _replace,
          log: _Log(),
        );
        final strings = _strings(tester);

        final view = tester.widget<ModalView>(find.byType(ModalView));
        expect(view.layout, ModalViewLayout.titleFirst);
        expect(view.title, strings.replaceTitle(_oldName));
        expect(find.text(strings.replaceTitle(_oldName)), findsOneWidget);
        final lead = tester.widget<ModalLead>(find.byType(ModalLead));
        expect(lead.text, texts['replaceBody']);
        expect(lead.text, strings.replaceShortBody(_newName));
        expect(lead.tight, isTrue);
        expect(
          tester.getRect(find.text(strings.replaceTitle(_oldName))).bottom,
          lessThanOrEqualTo(tester.getRect(find.byType(ModalLead)).top),
        );
        expect(
          tester.getRect(find.byType(ModalLead)).bottom,
          lessThan(tester.getRect(_rowOf(_oldName)).top),
        );

        expect(strings.keepBothButton, texts['keepBoth']);
        final keep = _button(tester, strings.keepBothButton);
        final swap = _button(tester, strings.replaceButton);
        expect(keep.kind, ModalButtonKind.secondary);
        expect(keep.inPair, isTrue);
        expect(keep.glyph, isNull);
        expect(swap.kind, ModalButtonKind.primary);
        expect(swap.inPair, isTrue);
        expect(identical(swap.glyph, Glyphs.swap), isTrue);
        expect(
          tester.getCenter(_buttonOf(strings.keepBothButton)).dx,
          lessThan(tester.getCenter(_buttonOf(strings.replaceButton)).dx),
        );
        expect(find.byType(ChoiceTile), findsNothing);
        expect(find.byType(ModalStage), findsNothing);
      });
    }

    testWidgets('the rows start 28 px under the body, the old row above the '
        'new one, and the buttons 28 px under the top zone', (tester) async {
      await _mount(tester, reduceMotion: true);
      await _open(
        tester,
        controller: _controllerWith(const []),
        question: _replace,
        log: _Log(),
      );
      final strings = _strings(tester);

      final lead = tester.getRect(find.byType(ModalLead));
      final old = tester.getRect(_rowOf(_oldName));
      final next = tester.getRect(_rowOf(_newName));
      expect(old.top - lead.bottom, 28);
      expect(old.bottom, lessThan(next.top));
      expect(old.width, next.width);
      final zone = tester.getRect(
        _in(find.byType(ModalView), find.byType(SingleChildScrollView)),
      );
      final keep = tester.getRect(_buttonOf(strings.keepBothButton));
      final swap = tester.getRect(_buttonOf(strings.replaceButton));
      expect(keep.top - zone.bottom, 28);
      expect(keep.top, swap.top);
      expect(keep.height, swap.height);
    });

    for (final reduceMotion in [false, true]) {
      final mode = reduceMotion ? 'reduced motion' : 'in motion';
      testWidgets('[$mode] the buttons do not answer at 0 or 499 ms and do at '
          '500 ms', (tester) async {
        await _mount(tester, reduceMotion: reduceMotion);
        final log = _Log();
        await _open(
          tester,
          controller: _controllerWith(const []),
          question: _replace,
          log: log,
          finish: false,
        );
        final strings = _strings(tester);

        expect(_button(tester, strings.keepBothButton).onPressed, isNull);
        expect(_button(tester, strings.replaceButton).onPressed, isNull);
        await tester.tap(_buttonOf(strings.replaceButton), warnIfMissed: false);
        await tester.pump(const Duration(milliseconds: 499));
        await tester.tap(
          _buttonOf(strings.keepBothButton),
          warnIfMissed: false,
        );
        await tester.tap(_buttonOf(strings.replaceButton), warnIfMissed: false);
        await tester.pump();
        expect(log.events, isEmpty);

        await tester.pump(const Duration(milliseconds: 1));
        expect(_button(tester, strings.keepBothButton).onPressed, isNotNull);
        expect(_button(tester, strings.replaceButton).onPressed, isNotNull);
        await tester.tap(_buttonOf(strings.replaceButton));
        expect(log.events, [_replaced]);
        await tester.pump(const Duration(seconds: 1));
      });
    }

    for (final (label, expected) in [
      ('keepBoth', _keptBoth),
      ('replace', _replaced),
    ]) {
      testWidgets('"$label" answers once with ${expected.split(' ')[1]} and '
          'no farewell', (tester) async {
        await _mount(tester);
        final log = _Log();
        await _open(
          tester,
          controller: _controllerWith(const []),
          question: _replace,
          log: log,
        );
        await _arm(tester);
        final strings = _strings(tester);

        await tester.tap(
          _buttonOf(
            label == 'keepBoth'
                ? strings.keepBothButton
                : strings.replaceButton,
          ),
        );
        expect(log.events, [expected]);
        await tester.pump(const Duration(seconds: 3));
        expect(log.events, [expected]);
      });
    }

    testWidgets('Esc with "Replace?" on screen reaches the frame and answers '
        'nothing by itself', (tester) async {
      await _mount(tester);
      final log = _Log();
      await _open(
        tester,
        controller: _controllerWith(const []),
        question: _replace,
        log: log,
      );
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pump();
      expect(log.events, ['dismiss']);
      await tester.pump(const Duration(seconds: 1));
    });
  });

  group('E288: "Replace?" rows (RF-125, points 192 and 213)', () {
    for (final code in languageCodes) {
      for (final (oldMine, oldVisible) in [
        (true, false),
        (false, false),
        (true, true),
        (false, true),
      ]) {
        final newMine = !oldMine;
        final newVisible = !oldVisible;
        testWidgets('[$code] old ${oldMine ? 'mine' : 'not mine'} and '
            '${oldVisible ? 'visible' : 'not visible'}, new '
            '${newMine ? 'mine' : 'not mine'} and '
            '${newVisible ? 'visible' : 'not visible'}', (tester) async {
          await _mount(tester, code: code, reduceMotion: true);
          await _open(
            tester,
            controller: _controllerWith([
              _entry(
                fingerprint: _oldFp,
                name: _oldName,
                type: DeviceType.mobile,
                visible: oldVisible,
                mine: oldMine,
              ),
              _entry(
                fingerprint: _newFp,
                name: _newName,
                type: DeviceType.desktop,
                visible: newVisible,
                mine: newMine,
              ),
            ]),
            question: _replace,
            log: _Log(),
          );
          final strings = _strings(tester);

          for (final (name, short, otherShort, mine, visible) in [
            (_oldName, _oldShort, _newShort, oldMine, oldVisible),
            (_newName, _newShort, _oldShort, newMine, newVisible),
          ]) {
            final row = _rowOf(name);
            expect(row, findsOneWidget);
            expect(_in(row, find.text(short)), findsOneWidget);
            expect(_in(row, find.text(otherShort)), findsNothing);
            expect(
              _in(row, find.text(strings.chipMine)),
              mine ? findsOneWidget : findsNothing,
            );
            expect(
              _in(row, find.text(strings.visibleLabel)),
              visible ? findsOneWidget : findsNothing,
            );
            expect(
              _in(row, find.text(strings.notVisibleLabel)),
              visible ? findsNothing : findsOneWidget,
            );
          }
          expect(find.text(strings.chipMine), findsOneWidget);
          expect(find.text(_oldFp), findsNothing);
          expect(find.text(_newFp), findsNothing);
          expect(find.textContaining(_oldFp.substring(0, 9)), findsNothing);
          expect(find.textContaining(_newFp.substring(0, 9)), findsNothing);

          expect(_disc(tester, _oldName).type, DeviceType.mobile);
          expect(_disc(tester, _newName).type, DeviceType.desktop);
        });
      }
    }

    testWidgets('the chip is StatusChip "Mine" with tone run and 20 px high, '
        'on the line of the fingerprint and 8 px after it (point 245)', (
      tester,
    ) async {
      await _mount(tester, reduceMotion: true);
      await _open(
        tester,
        controller: _controllerWith([
          _entry(
            fingerprint: _oldFp,
            name: _oldName,
            visible: false,
            mine: true,
          ),
        ]),
        question: _replace,
        log: _Log(),
      );
      final strings = _strings(tester);

      final chip = tester.widget<StatusChip>(
        _in(_rowOf(_oldName), find.byType(StatusChip)),
      );
      expect(chip.label, strings.chipMine);
      expect(chip.tone, ChipTone.run);
      expect(chip.height, 20);
      final name = tester.getRect(find.text(_oldName));
      final short = tester.getRect(_in(_rowOf(_oldName), find.text(_oldShort)));
      final chipRect = tester.getRect(
        _in(_rowOf(_oldName), find.byType(StatusChip)),
      );
      expect(chipRect.left - short.right, 8);
      expect(chipRect.top, greaterThanOrEqualTo(name.bottom));
      expect(chipRect.center.dy, closeTo(short.center.dy, 0.5));
      expect(_in(_rowOf(_newName), find.byType(StatusChip)), findsNothing);
    });

    for (final (label, state) in [
      ('an empty list', const NodeState()),
      ('no state', null),
    ]) {
      testWidgets('with $label, the rows use the defaults of point 213: pc, '
          'not mine, old not visible and new visible', (tester) async {
        await _mount(tester, reduceMotion: true);
        await _open(
          tester,
          controller: FakeAppController(state: state),
          question: _replace,
          log: _Log(),
        );
        final strings = _strings(tester);

        expect(_disc(tester, _oldName).type, isNull);
        expect(_disc(tester, _oldName).glyph, DeviceGlyph.pc);
        expect(_disc(tester, _newName).type, isNull);
        expect(_disc(tester, _newName).glyph, DeviceGlyph.pc);
        expect(find.text(strings.chipMine), findsNothing);
        expect(
          _in(_rowOf(_oldName), find.text(strings.notVisibleLabel)),
          findsOneWidget,
        );
        expect(
          _in(_rowOf(_newName), find.text(strings.visibleLabel)),
          findsOneWidget,
        );
        expect(find.text(_oldShort), findsOneWidget);
        expect(find.text(_newShort), findsOneWidget);
      });
    }

    testWidgets('with only the old entry, the new row uses the defaults and '
        'the old row its entry', (tester) async {
      await _mount(tester, reduceMotion: true);
      await _open(
        tester,
        controller: _controllerWith([
          _entry(
            fingerprint: _oldFp,
            name: _oldName,
            type: DeviceType.mobile,
            visible: true,
            mine: true,
          ),
        ]),
        question: _replace,
        log: _Log(),
      );
      final strings = _strings(tester);

      expect(_disc(tester, _oldName).type, DeviceType.mobile);
      expect(
        _in(_rowOf(_oldName), find.text(strings.visibleLabel)),
        findsOneWidget,
      );
      expect(
        _in(_rowOf(_oldName), find.text(strings.chipMine)),
        findsOneWidget,
      );
      expect(_disc(tester, _newName).type, isNull);
      expect(
        _in(_rowOf(_newName), find.text(strings.visibleLabel)),
        findsOneWidget,
      );
      expect(_in(_rowOf(_newName), find.text(strings.chipMine)), findsNothing);
    });

    testWidgets('the rows follow the controller while the question is open', (
      tester,
    ) async {
      await _mount(tester, reduceMotion: true);
      final controller = _controllerWith([
        _entry(fingerprint: _oldFp, name: _oldName, visible: false),
      ]);
      await _open(
        tester,
        controller: controller,
        question: _replace,
        log: _Log(),
      );
      final strings = _strings(tester);
      expect(
        _in(_rowOf(_oldName), find.text(strings.notVisibleLabel)),
        findsOneWidget,
      );

      controller.emit(
        NodeState(
          entries: [_entry(fingerprint: _oldFp, name: _oldName, mine: true)],
        ),
      );
      await tester.pump();
      expect(
        _in(_rowOf(_oldName), find.text(strings.visibleLabel)),
        findsOneWidget,
      );
      expect(
        _in(_rowOf(_oldName), find.text(strings.chipMine)),
        findsOneWidget,
      );
    });

    for (final MapEntry(key: name, value: brightness) in _themes.entries) {
      testWidgets('[$name] row look: surfaceWeak with radius 16, the new one '
          'with a 1.5 primary edge and the primaryWeak gradient', (
        tester,
      ) async {
        final colors = _colorsFor(brightness);
        await _mount(tester, brightness: brightness, reduceMotion: true);
        await _open(
          tester,
          controller: _controllerWith(const []),
          question: _replace,
          log: _Log(),
        );

        for (final rowName in [_oldName, _newName]) {
          final box = _rowBox(tester, rowName).decoration! as BoxDecoration;
          expect(box.color, colors.surfaceWeak);
          expect(box.borderRadius, BorderRadius.circular(16));
          expect(
            _in(
              _rowOf(rowName),
              find.byWidgetPredicate(
                (widget) =>
                    widget is Padding &&
                    widget.padding ==
                        const EdgeInsets.symmetric(
                          horizontal: 14,
                          vertical: 12,
                        ),
              ),
            ),
            findsOneWidget,
          );
        }
        expect(_rowBox(tester, _oldName).foregroundDecoration, isNull);
        final edge =
            _rowBox(tester, _newName).foregroundDecoration! as BoxDecoration;
        final border = edge.border! as Border;
        expect(border.top.color, colors.primary);
        expect(border.top.width, 1.5);
        expect(edge.borderRadius, BorderRadius.circular(16));

        final gradientBox = tester
            .widgetList<DecoratedBox>(
              _in(_rowOf(_newName), find.byType(DecoratedBox)),
            )
            .map((box) => box.decoration)
            .whereType<BoxDecoration>()
            .firstWhere((box) => box.gradient != null);
        final gradient = gradientBox.gradient! as LinearGradient;
        expect(gradient.colors, [
          colors.primaryWeak,
          colors.primaryWeak.withValues(alpha: 0),
        ]);
        expect(gradient.stops, [0, 0.85]);
        expect(
          tester
              .widgetList<DecoratedBox>(
                _in(_rowOf(_oldName), find.byType(DecoratedBox)),
              )
              .map((box) => box.decoration)
              .whereType<BoxDecoration>()
              .where((box) => box.gradient != null),
          isEmpty,
        );
      });

      testWidgets('[$name] discs of 48, names in 15/20 600, short '
          'fingerprints in 12 px tabular and visibility pills', (tester) async {
        final colors = _colorsFor(brightness);
        await _mount(tester, brightness: brightness, reduceMotion: true);
        await _open(
          tester,
          controller: _controllerWith([
            _entry(fingerprint: _oldFp, name: _oldName, visible: false),
            _entry(fingerprint: _newFp, name: _newName),
          ]),
          question: _replace,
          log: _Log(),
        );
        final strings = _strings(tester);

        expect(_disc(tester, _oldName).size, 48);
        expect(_disc(tester, _oldName).tone, DiscTone.notVisible);
        expect(_disc(tester, _newName).size, 48);
        expect(_disc(tester, _newName).tone, DiscTone.sending);
        expect(tester.getSize(_discOf(_oldName)), const Size(48, 48));

        for (final rowName in [_oldName, _newName]) {
          final style = tester.widget<Text>(find.text(rowName)).style!;
          expect(style.fontSize, 15);
          expect(style.height, closeTo(20 / 15, 1e-9));
          expect(style.fontWeight, FontWeight.w600);
          expect(style.color, colors.text);
          expect(tester.widget<Text>(find.text(rowName)).maxLines, 1);
          expect(
            tester.widget<Text>(find.text(rowName)).overflow,
            TextOverflow.ellipsis,
          );
        }
        for (final short in [_oldShort, _newShort]) {
          final style = tester.widget<Text>(find.text(short)).style!;
          expect(style.fontSize, 12);
          expect(style.letterSpacing, closeTo(0.72, 1e-9));
          expect(style.color, colors.textWeak);
          expect(
            style.fontFeatures,
            contains(const FontFeature.tabularFigures()),
          );
        }

        for (final (label, fill, ink) in [
          (strings.notVisibleLabel, colors.dangerWeak, colors.danger),
          (strings.visibleLabel, colors.successWeak, colors.successInk),
        ]) {
          final text = find.text(label);
          expect(tester.widget<Text>(text).style!.color, ink);
          final pill = tester.widget<Container>(
            find
                .ancestor(
                  of: text,
                  matching: find.byWidgetPredicate(
                    (widget) =>
                        widget is Container &&
                        widget.decoration is ShapeDecoration,
                  ),
                )
                .first,
          );
          expect((pill.decoration! as ShapeDecoration).color, fill);
          expect(
            tester
                .getSize(
                  find
                      .ancestor(
                        of: text,
                        matching: find.byWidgetPredicate(
                          (widget) =>
                              widget is Container &&
                              widget.decoration is ShapeDecoration,
                        ),
                      )
                      .first,
                )
                .height,
            22,
          );
        }
        expect(
          tester.getRect(find.text(strings.notVisibleLabel)).left,
          greaterThan(tester.getRect(find.text(_oldShort)).right),
        );
      });

      testWidgets('[$name] the arrow: a 30 px primary circle with a 5 px card '
          'ring and a 16 px arrowDown in onPrimary, overlapping both rows by '
          '7 px', (tester) async {
        final colors = _colorsFor(brightness);
        await _mount(tester, brightness: brightness, reduceMotion: true);
        await _open(
          tester,
          controller: _controllerWith(const []),
          question: _replace,
          log: _Log(),
        );

        expect(_arrowGlyph, findsOneWidget);
        final glyph = tester.widget<GlyphIcon>(_arrowGlyph);
        expect(glyph.size, 16);
        expect(glyph.color, colors.onPrimary);
        final badge = tester.getRect(_arrowBadge);
        expect(badge.size, const Size(30, 30));
        expect(
          _arrowBadge,
          paints
            ..circle(radius: 20, color: colors.card)
            ..circle(radius: 15, color: colors.primary),
        );
        final old = tester.getRect(_rowOf(_oldName));
        final next = tester.getRect(_rowOf(_newName));
        expect(old.bottom - badge.top, closeTo(7, 1e-6));
        expect(badge.bottom - next.top, closeTo(7, 1e-6));
        expect(badge.center.dx, closeTo(next.center.dx, 1e-6));
        expect(
          find.ancestor(
            of: _arrowGlyph,
            matching: find.byType(ExcludeSemantics),
          ),
          findsWidgets,
        );
      });
    }
  });

  group('E288: "Replace?" entrances and loop (points 192 and 227)', () {
    testWidgets('in motion: the old row fades in from scale 0.9, its disc '
        'drops to 55 %, the arrow pops and the new row comes down 10 px', (
      tester,
    ) async {
      await _mount(tester);
      await _open(
        tester,
        controller: _controllerWith(const []),
        question: _replace,
        log: _Log(),
        finish: false,
      );
      await tester.pump();
      final oldName = find.text(_oldName);
      final newName = find.text(_newName);

      expect(_opacityAbove(tester, oldName), 0);
      expect(_transformAbove(tester, oldName).storage[0], closeTo(0.9, 1e-9));
      expect(_opacityAbove(tester, newName), 0);
      expect(
        _transformAbove(tester, newName).getTranslation().y,
        closeTo(-10, 1e-9),
      );
      expect(_opacityAbove(tester, _arrowGlyph), 0);
      expect(_opacityAbove(tester, _discOf(_oldName)), 1);

      await tester.pump(const Duration(milliseconds: 300));
      final midOpacity = _opacityAbove(tester, oldName);
      expect(midOpacity, greaterThan(0));
      expect(midOpacity, lessThan(1));
      final midScale = _transformAbove(tester, oldName).storage[0];
      expect(midScale, greaterThan(0.9));
      expect(midScale, lessThan(1));

      await tester.pump(const Duration(milliseconds: 200));
      expect(_opacityAbove(tester, oldName), 1);
      expect(_transformAbove(tester, oldName).storage[0], closeTo(1, 1e-9));
      expect(_opacityAbove(tester, newName), 0);

      await tester.pump(const Duration(milliseconds: 200));
      expect(_opacityAbove(tester, _discOf(_oldName)), 1);

      await tester.pump(const Duration(milliseconds: 150));
      expect(_opacityAbove(tester, _arrowGlyph), closeTo(1, 1e-9));
      expect(
        _transformAbove(tester, _arrowGlyph, index: 1).storage[0],
        closeTo(1, 1e-9),
      );

      await tester.pump(const Duration(milliseconds: 200));
      expect(_opacityAbove(tester, newName), closeTo(1, 1e-9));
      expect(
        _transformAbove(tester, newName).getTranslation().y,
        closeTo(0, 1e-9),
      );

      await tester.pump(const Duration(milliseconds: 150));
      expect(_opacityAbove(tester, _discOf(_oldName)), closeTo(0.55, 1e-9));
    });

    testWidgets('in motion: the arrow goes down 3 px in a 1.8 s loop from '
        '1 s', (tester) async {
      await _mount(tester);
      await _open(
        tester,
        controller: _controllerWith(const []),
        question: _replace,
        log: _Log(),
        finish: false,
      );
      await tester.pump();
      double drop() => _transformAbove(tester, _arrowGlyph).getTranslation().y;

      await tester.pump(const Duration(milliseconds: 1000));
      expect(drop(), closeTo(0, 0.01));
      await tester.pump(const Duration(milliseconds: 504));
      expect(drop(), closeTo(3, 0.01));
      await tester.pump(const Duration(milliseconds: 486));
      expect(drop(), closeTo(0, 0.01));
      await tester.pump(const Duration(milliseconds: 810));
      expect(drop(), closeTo(0, 0.01));
      await tester.pump(const Duration(milliseconds: 504));
      expect(drop(), closeTo(3, 0.01));
      expect(tester.binding.transientCallbackCount, greaterThan(0));
    });

    testWidgets('with reduced motion: everything at its final state and '
        'nothing moves', (tester) async {
      await _mount(tester, reduceMotion: true);
      await _open(
        tester,
        controller: _controllerWith(const []),
        question: _replace,
        log: _Log(),
      );
      final oldName = find.text(_oldName);
      final newName = find.text(_newName);

      for (var i = 0; i < 3; i++) {
        expect(_opacityAbove(tester, oldName), 1);
        expect(_transformAbove(tester, oldName).storage[0], 1);
        expect(_opacityAbove(tester, newName), 1);
        expect(_transformAbove(tester, newName).getTranslation().y, 0);
        expect(_opacityAbove(tester, _discOf(_oldName)), closeTo(0.55, 1e-9));
        expect(_opacityAbove(tester, _arrowGlyph), 1);
        expect(_transformAbove(tester, _arrowGlyph, index: 1).storage[0], 1);
        expect(_transformAbove(tester, _arrowGlyph).getTranslation().y, 0);
        await tester.pump(const Duration(milliseconds: 700));
      }
    });
  });

  group('E288: small windows and large text (point 198)', () {
    setUpAll(_loadSegoe);

    testWidgets('the real Segoe UI is loaded for the next cases', (
      tester,
    ) async {
      for (final style in [
        NbText.body,
        NbText.bodyStrong,
        NbText.caption,
        NbText.label,
        NbText.title,
      ]) {
        expect(
          _widthOf('iiiiiiiiii', style),
          lessThan(_widthOf('WWWWWWWWWW', style) / 2),
          reason: style.fontFamily,
        );
      }
    });

    for (final code in languageCodes) {
      for (final (window, scale) in [
        (const Size(320, 800), 1.0),
        (const Size(320, 800), 1.3),
        (const Size(760, 520), 1.3),
      ]) {
        final size = '${window.width.toInt()}x${window.height.toInt()}';
        final percent = '${(scale * 100).round()} %';
        for (final question in <PairingQuestion>[
          ReplaceQuestion(
            fingerprint: _newFp,
            deviceName: _longNew,
            oldFingerprint: _oldFp,
            oldName: _longOld,
          ),
          MineQuestion(fingerprint: _newFp, deviceName: _longNew),
        ]) {
          final kind = question is ReplaceQuestion ? 'Replace?' : 'Mine?';
          testWidgets('[$code] "$kind" in $size at $percent: no overflow and '
              'the tiles and buttons are whole', (tester) async {
            await _mount(
              tester,
              code: code,
              reduceMotion: true,
              textScale: scale,
              window: window,
            );
            await _open(
              tester,
              controller: _controllerWith([
                _entry(
                  fingerprint: _oldFp,
                  name: _longOld,
                  visible: false,
                  mine: true,
                ),
                _entry(fingerprint: _newFp, name: _longNew, mine: true),
              ]),
              question: question,
              log: _Log(),
            );
            await _arm(tester);

            expect(tester.takeException(), isNull);
            _expectNoParagraphCut(tester, find.byType(ChoiceTile));
            _expectNoParagraphCut(tester, find.byType(ModalButton));
            for (final pill in [
              AppStringsDelegate.of(
                tester.element(find.byType(PairingQuestionView)),
              ).visibleLabel,
              AppStringsDelegate.of(
                tester.element(find.byType(PairingQuestionView)),
              ).notVisibleLabel,
            ]) {
              if (find.text(pill).evaluate().isEmpty) continue;
              final paragraph = tester.renderObject<RenderParagraph>(
                _in(find.text(pill), find.byType(RichText)),
              );
              expect(paragraph.didExceedMaxLines, isFalse);
            }
            if (question is ReplaceQuestion) {
              final frame = tester.getRect(find.byType(NbModal));
              for (final rowName in [_longOld, _longNew]) {
                final row = tester.getRect(_rowOf(rowName));
                expect(row.left, greaterThanOrEqualTo(frame.left));
                expect(row.right, lessThanOrEqualTo(frame.right));
              }
              final strings = _strings(tester);
              expect(
                tester.getSize(_buttonOf(strings.keepBothButton)).height,
                tester.getSize(_buttonOf(strings.replaceButton)).height,
              );
            } else {
              expect(
                tester.getSize(_tiles.at(0)).height,
                tester.getSize(_tiles.at(1)).height,
              );
            }
          });
        }
      }
    }

    testWidgets('[es] "Is it yours?" in motion at 320 px and 130 %: no '
        'overflow during the entrance and the farewell', (tester) async {
      await _mount(
        tester,
        code: 'es',
        textScale: 1.3,
        window: const Size(320, 800),
      );
      await _open(
        tester,
        controller: _controllerWith(const []),
        question: MineQuestion(fingerprint: _newFp, deviceName: _longNew),
        log: _Log(),
        finish: false,
      );
      for (var i = 0; i < 6; i++) {
        await tester.pump(const Duration(milliseconds: 100));
        expect(tester.takeException(), isNull);
      }
      await tester.tap(_tiles.at(1));
      for (var i = 0; i < 20; i++) {
        await tester.pump(const Duration(milliseconds: 100));
        expect(tester.takeException(), isNull);
      }
    });

    testWidgets('[en] "Replace?" in motion at 320 px and 130 %: no overflow '
        'during the entrances and the loop', (tester) async {
      await _mount(tester, textScale: 1.3, window: const Size(320, 800));
      await _open(
        tester,
        controller: _controllerWith(const []),
        question: ReplaceQuestion(
          fingerprint: _newFp,
          deviceName: _longNew,
          oldFingerprint: _oldFp,
          oldName: _longOld,
        ),
        log: _Log(),
        finish: false,
      );
      for (var i = 0; i < 30; i++) {
        await tester.pump(const Duration(milliseconds: 100));
        expect(tester.takeException(), isNull);
      }
    });
  });

  group('E288: visual review fixes with Segoe UI (point 245)', () {
    setUpAll(_loadSegoe);

    const baseName = 'Port\u00E1til de Ana';
    const normalNames = [
      'DESKTOP-4F7K2QX',
      'Torre Luis',
      'Port\u00E1til de Ana',
      'Sobremesa de Luc\u00EDa',
    ];

    String visibleText(String text) => text.replaceAll('\u00A0', ' ');

    List<String> textsOf(WidgetTester tester, Finder scope) => [
      for (final text in tester.widgetList<Text>(_in(scope, find.byType(Text))))
        visibleText(text.data ?? text.textSpan?.toPlainText() ?? ''),
    ];

    for (final code in languageCodes) {
      testWidgets('[$code] "Replace?" with namesakes: each row shows the base '
          'name and its short fingerprint once, without repeating it, and '
          'the title keeps the fingerprint glued', (tester) async {
        const oldLabel = '$baseName \u00B7 $_oldShort';
        const newLabel = '$baseName \u00B7 $_newShort';
        await _mount(tester, code: code, reduceMotion: true);
        await _open(
          tester,
          controller: _controllerWith([
            _entry(
              fingerprint: _oldFp,
              name: oldLabel,
              visible: false,
              mine: true,
            ),
            _entry(fingerprint: _newFp, name: newLabel, mine: true),
          ]),
          question: ReplaceQuestion(
            fingerprint: _newFp,
            deviceName: newLabel,
            oldFingerprint: _oldFp,
            oldName: oldLabel,
          ),
          log: _Log(),
        );
        final strings = _strings(tester);

        expect(tester.takeException(), isNull);
        expect(find.text(baseName), findsNWidgets(2));
        expect(find.text(oldLabel), findsNothing);
        expect(find.text(newLabel), findsNothing);
        for (final (short, other) in [
          (_oldShort, _newShort),
          (_newShort, _oldShort),
        ]) {
          final row = _rowOf(short);
          final texts = textsOf(tester, row);
          expect(texts.where((text) => text == baseName), hasLength(1));
          expect(texts.where((text) => text.contains(short)).toList(), [
            short,
          ], reason: short);
          expect(texts.where((text) => text.contains(other)), isEmpty);
          expect(texts.where((text) => text.contains('\u00B7')), isEmpty);
          final name = tester.getRect(_in(row, find.text(baseName)));
          final line = tester.getRect(_in(row, find.text(short)));
          expect(line.top, greaterThanOrEqualTo(name.bottom));
          expect(line.left, closeTo(name.left, 0.5));
        }

        final title = strings.replaceTitle(
          '$baseName\u00A0\u00B7\u00A0$_oldShort',
        );
        expect(find.text(title), findsOneWidget);
        expect(visibleText(title), strings.replaceTitle(oldLabel));
        final paragraph = tester.renderObject<RenderParagraph>(
          _in(find.text(title), find.byType(RichText)),
        );
        expect(paragraph.didExceedMaxLines, isFalse);
        final text = paragraph.text.toPlainText();
        final dot = text.indexOf('\u00B7');
        final glued = [
          for (final i in [dot - 2, dot - 1, dot, dot + 1, dot + 2])
            paragraph
                .getBoxesForSelection(
                  TextSelection(baseOffset: i, extentOffset: i + 1),
                )
                .first
                .top,
        ];
        expect(glued.toSet(), hasLength(1));
      });

      testWidgets('[$code] "Replace?" at 800x600: when the title wraps, the '
          'last word, the dot and the fingerprint stay on the same line', (
        tester,
      ) async {
        var wrapped = 0;
        for (var extra = 0; extra <= 12; extra++) {
          final base = 'Port\u00E1til ${'a' * extra} de Ana';
          final label = '$base \u00B7 $_oldShort';
          await _mount(tester, code: code, reduceMotion: true);
          await _open(
            tester,
            controller: _controllerWith(const []),
            question: ReplaceQuestion(
              fingerprint: _newFp,
              deviceName: _newName,
              oldFingerprint: _oldFp,
              oldName: label,
            ),
            log: _Log(),
          );
          final strings = _strings(tester);
          expect(tester.takeException(), isNull, reason: base);
          final title = strings.replaceTitle(
            '$base\u00A0\u00B7\u00A0$_oldShort',
          );
          expect(find.text(title), findsOneWidget, reason: base);
          final paragraph = tester.renderObject<RenderParagraph>(
            _in(find.text(title), find.byType(RichText)),
          );
          expect(paragraph.didExceedMaxLines, isFalse, reason: base);
          final text = paragraph.text.toPlainText();
          double top(int i) => paragraph
              .getBoxesForSelection(
                TextSelection(baseOffset: i, extentOffset: i + 1),
              )
              .first
              .top;
          final ana = text.indexOf('Ana\u00A0');
          final end = text.indexOf(_oldShort) + _oldShort.length - 1;
          if (top(text.length - 1) > top(0)) wrapped++;
          for (var i = ana; i <= end; i++) {
            expect(top(i), top(ana), reason: '$base: ${text[i]}');
          }
          await tester.pumpWidget(const SizedBox());
        }
        expect(wrapped, greaterThan(0));
      });

      for (final window in const [Size(800, 600), Size(1180, 720)]) {
        testWidgets('[$code] "Replace?" at ${window.width.toInt()}x'
            '${window.height.toInt()} and 100 %: normal names are whole in '
            'their rows, with the chip "Mine" and the pills', (tester) async {
          for (final name in normalNames) {
            await _mount(
              tester,
              code: code,
              reduceMotion: true,
              window: window,
            );
            await _open(
              tester,
              controller: _controllerWith([
                _entry(
                  fingerprint: _oldFp,
                  name: name,
                  visible: false,
                  mine: true,
                ),
                _entry(fingerprint: _newFp, name: name, mine: true),
              ]),
              question: ReplaceQuestion(
                fingerprint: _newFp,
                deviceName: name,
                oldFingerprint: _oldFp,
                oldName: name,
              ),
              log: _Log(),
            );

            expect(tester.takeException(), isNull, reason: name);
            for (final short in [_oldShort, _newShort]) {
              final row = _rowOf(short);
              expect(
                _in(row, find.byType(StatusChip)),
                findsOneWidget,
                reason: name,
              );
              final nameText = _in(row, find.text(name));
              final paragraph = tester.renderObject<RenderParagraph>(
                _in(nameText, find.byType(RichText)),
              );
              final column = tester.getRect(
                find
                    .ancestor(of: nameText, matching: find.byType(Column))
                    .first,
              );
              expect(
                paragraph.constraints.maxWidth,
                closeTo(column.width, 0.01),
                reason: name,
              );
              final chip = tester.getRect(_in(row, find.byType(StatusChip)));
              expect(
                chip.top,
                greaterThanOrEqualTo(tester.getRect(nameText).bottom),
                reason: name,
              );
              expect(paragraph.didExceedMaxLines, isFalse, reason: name);
              expect(
                paragraph.getMaxIntrinsicWidth(double.infinity),
                lessThanOrEqualTo(paragraph.size.width + 0.01),
                reason: name,
              );
            }
            await tester.pumpWidget(const SizedBox());
          }
        });
      }

      for (final window in const [Size(800, 600), Size(760, 520)]) {
        testWidgets('[$code] "Is it yours?" at ${window.width.toInt()}x'
            '${window.height.toInt()} and 100 %: the question is whole in '
            'the zone without scrolling', (tester) async {
          final question = _specTexts[code]!['question']!;
          for (final name in normalNames) {
            await _mount(
              tester,
              code: code,
              reduceMotion: true,
              window: window,
            );
            await _open(
              tester,
              controller: _controllerWith([
                _entry(fingerprint: _newFp, name: name),
              ]),
              question: MineQuestion(fingerprint: _newFp, deviceName: name),
              log: _Log(),
            );

            expect(tester.takeException(), isNull, reason: name);
            final zoneFinder = _in(
              find.byType(ModalView),
              find.byType(SingleChildScrollView),
            );
            final zone = tester.getRect(zoneFinder);
            final position = tester
                .state<ScrollableState>(
                  _in(zoneFinder, find.byType(Scrollable)),
                )
                .position;
            expect(position.pixels, 0, reason: name);
            final lead = tester.getRect(find.text(question));
            expect(lead.top, greaterThanOrEqualTo(zone.top - 0.5));
            expect(lead.bottom, lessThanOrEqualTo(zone.bottom + 0.5));
            expect(lead.left, greaterThanOrEqualTo(zone.left - 0.5));
            expect(lead.right, lessThanOrEqualTo(zone.right + 0.5));
            final stage = tester.widget<ModalStage>(find.byType(ModalStage));
            expect(stage.size, StageSize.mid, reason: name);
            await tester.pumpWidget(const SizedBox());
          }
        });
      }
    }
  });

  group(
    'E288: source of pairing_questions.dart (points 196, 208 and RF-62)',
    () {
      final source = File('lib/src/ui/pairing_questions.dart')
          .readAsStringSync();
      final code = source
          .split('\n')
          .where((line) => !line.trimLeft().startsWith('import '))
          .join('\n');

      test('it writes no literal text: every text comes from AppStrings', () {
        expect(code.contains("'"), isFalse);
        expect(code.contains('"'), isFalse);
        expect(source, contains('AppStringsDelegate.of('));
      });

      test('it writes no color literal and no white constant', () {
        expect(source.contains('Color(0x'), isFalse);
        expect(source.contains('Color.fromRGBO('), isFalse);
        expect(source.contains('Color.fromARGB('), isFalse);
        expect(source.contains('_white'), isFalse);
        expect(
          RegExp(r'(?<![A-Za-z])Colors\.(?!transparent\b)').hasMatch(source),
          isFalse,
        );
      });

      test('it has no comments', () {
        expect(code.contains('//'), isFalse);
        expect(code.contains('/*'), isFalse);
      });

      test('it keeps the public signature of point 213', () {
        expect(
          source,
          contains('class PairingQuestionView extends StatefulWidget'),
        );
        expect(source, contains('final AppController controller;'));
        expect(source, contains('final PairingQuestion question;'));
        expect(
          source,
          contains(
            'final void Function(bool value, {bool farewell}) onAnswer;',
          ),
        );
        expect(source, contains('final VoidCallback onFarewellDone;'));
        expect(source, contains('with ArmingState<PairingQuestionView>'));
      });
    },
  );
}
