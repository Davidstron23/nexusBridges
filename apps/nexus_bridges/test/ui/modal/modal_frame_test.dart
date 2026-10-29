import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nexus_bridges/src/l10n/app_strings.dart';
import 'package:nexus_bridges/src/ui/armed.dart';
import 'package:nexus_bridges/src/ui/home_screen.dart';
import 'package:nexus_bridges/src/ui/icons/glyphs.dart';
import 'package:nexus_bridges/src/ui/modal/modal_button.dart';
import 'package:nexus_bridges/src/ui/modal/modal_frame.dart';
import 'package:nexus_bridges/src/ui/theme/app_theme.dart';
import 'package:nexus_bridges/src/ui/theme/tokens.dart';

import '../fake_app_controller.dart';
import '../zone_scrollbar.dart';

const Cubic _labEaseOut = Cubic(0.23, 1, 0.32, 1);

const Map<String, Brightness> _themes = {
  'light': Brightness.light,
  'dark': Brightness.dark,
};

NbColors _colorsFor(Brightness brightness) =>
    brightness == Brightness.dark ? NbColors.dark : NbColors.light;

final GlobalKey _homeKey = GlobalKey();

const Key _stageKey = ValueKey('stage');
const Key _bodyKey = ValueKey('body');
const Key _leftKey = ValueKey('pair-left');
const Key _rightKey = ValueKey('pair-right');
const Key _firstKey = ValueKey('action-first');
const Key _secondKey = ValueKey('action-second');

Future<void> _mount(
  WidgetTester tester, {
  Size window = const Size(800, 600),
  String code = 'en',
  Brightness brightness = Brightness.light,
  bool reduceMotion = false,
  double textScale = 1,
  Widget? body,
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
        body: Center(child: body ?? const SizedBox.expand()),
      ),
    ),
  );
}

final class _Opened {
  _Opened(this.route, this.result);

  final NbModalRoute<String> route;
  final Future<String?> result;
}

Future<_Opened> _open(
  WidgetTester tester,
  WidgetBuilder builder, {
  VoidCallback? Function()? onDismiss,
  bool finish = true,
}) async {
  final context = _homeKey.currentContext!;
  final route = NbModalRoute<String>(
    context: context,
    builder: builder,
    onDismiss: onDismiss,
  );
  final result = Navigator.of(context).push(route);
  await tester.pump();
  if (finish) await tester.pump(modalTransitionDuration);
  return _Opened(route, result);
}

Finder _in(Finder scope, Finder matching) =>
    find.descendant(of: scope, matching: matching);

Finder get _frame => _in(find.byType(NbModal), find.byType(DecoratedBox)).first;

Finder get _zone =>
    _in(find.byType(ModalView), find.byType(SingleChildScrollView));

Widget _fullView(
  ModalViewLayout layout, {
  String title = 'Title',
  List<Widget> body = const [ModalLead(key: _bodyKey, text: 'Body')],
  ModalEyebrow? eyebrow = const ModalEyebrow(
    text: 'Paired',
    tone: EyebrowTone.ok,
  ),
}) {
  return ModalView(
    layout: layout,
    stage: const SizedBox(key: _stageKey, width: 120, height: 60),
    eyebrow: eyebrow,
    title: title,
    body: body,
    pair: [
      ModalButton(
        key: _leftKey,
        label: 'Left',
        kind: ModalButtonKind.secondary,
        onPressed: () {},
        inPair: true,
      ),
      ModalButton(
        key: _rightKey,
        label: 'Right',
        kind: ModalButtonKind.primary,
        onPressed: () {},
        inPair: true,
      ),
    ],
    actions: [
      ModalButton(
        key: _firstKey,
        label: 'First',
        kind: ModalButtonKind.neutral,
        onPressed: () {},
      ),
      ModalButton(
        key: _secondKey,
        label: 'Second',
        kind: ModalButtonKind.negativeQuiet,
        onPressed: () {},
      ),
    ],
  );
}

double _fade(WidgetTester tester, Finder target) => tester
    .widget<FadeTransition>(
      find.ancestor(of: target, matching: find.byType(FadeTransition)).first,
    )
    .opacity
    .value;

double _scale(WidgetTester tester, Finder target) => tester
    .widget<ScaleTransition>(
      find.ancestor(of: target, matching: find.byType(ScaleTransition)).first,
    )
    .scale
    .value;

double _shift(WidgetTester tester, Finder target) => tester
    .widget<Transform>(
      find.ancestor(of: target, matching: find.byType(Transform)).first,
    )
    .transform
    .getTranslation()
    .y;

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

final class _Log {
  final List<String> born = [];
  final List<String> disposed = [];
  final List<String> taps = [];
}

class _ProbeView extends StatefulWidget {
  const _ProbeView({required this.log, required this.name, this.title});

  final _Log log;
  final String name;
  final String? title;

  @override
  State<_ProbeView> createState() => _ProbeViewState();
}

class _ProbeViewState extends State<_ProbeView> with ArmingState<_ProbeView> {
  @override
  void initState() {
    super.initState();
    widget.log.born.add(widget.name);
  }

  @override
  void dispose() {
    widget.log.disposed.add(widget.name);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ModalView(
      title: widget.title ?? 'Title ${widget.name}',
      actions: [
        ModalButton(
          label: 'Go ${widget.name}',
          kind: ModalButtonKind.primary,
          onPressed: armed ? () => widget.log.taps.add(widget.name) : null,
        ),
      ],
    );
  }
}

final class _Switcher {
  _Switcher(this.log)
    : step = ValueNotifier<(Object, Widget)>((
        'A',
        _ProbeView(log: log, name: 'A'),
      ));

  final _Log log;
  final ValueNotifier<(Object, Widget)> step;

  void go(String name, {String? title}) {
    step.value = (name, _ProbeView(log: log, name: name, title: title));
  }
}

Future<_Switcher> _openSwitcher(
  WidgetTester tester, {
  VoidCallback? Function()? onDismiss,
}) async {
  final switcher = _Switcher(_Log());
  await _open(
    tester,
    (_) => ValueListenableBuilder<(Object, Widget)>(
      valueListenable: switcher.step,
      builder: (context, value, _) =>
          ModalViewSwitcher(viewKey: value.$1, child: value.$2),
    ),
    onDismiss: onDismiss,
  );
  return switcher;
}

Finder _viewOf(String name) => find.byKey(ValueKey<Object>(name));

bool _ignoring(WidgetTester tester, String name) => tester
    .widget<IgnorePointer>(_in(_viewOf(name), find.byType(IgnorePointer)).first)
    .ignoring;

bool _focusExcluded(WidgetTester tester, String name) => tester
    .widget<ExcludeFocus>(_in(_viewOf(name), find.byType(ExcludeFocus)).first)
    .excluding;

bool _semanticsExcluded(WidgetTester tester, String name) => tester
    .widget<ExcludeSemantics>(
      _in(_viewOf(name), find.byType(ExcludeSemantics)).first,
    )
    .excluding;

double _viewOpacity(WidgetTester tester, String name) => tester
    .widget<Opacity>(_in(_viewOf(name), find.byType(Opacity)).first)
    .opacity;

double _viewShift(WidgetTester tester, String name) => tester
    .widget<Transform>(_in(_viewOf(name), find.byType(Transform)).first)
    .transform
    .getTranslation()
    .y;

bool _viewBlurred(WidgetTester tester, String name) => tester
    .widget<ImageFiltered>(_in(_viewOf(name), find.byType(ImageFiltered)).first)
    .enabled;

VoidCallback? _buttonOf(WidgetTester tester, String name) => tester
    .widget<ModalButton>(find.widgetWithText(ModalButton, 'Go $name'))
    .onPressed;

void main() {
  group('E282: measures and times of the frame (point 185)', () {
    test('the public constants have the values of the plan', () {
      expect(modalSize, const Size(400, 488));
      expect(modalRadius, 20);
      expect(modalPadding, const EdgeInsets.fromLTRB(28, 28, 28, 34));
      expect(modalScrimPadding, 16);
      expect(modalTransitionDuration, const Duration(milliseconds: 320));
      expect(modalViewInDuration, const Duration(milliseconds: 360));
      expect(modalViewInDelay, const Duration(milliseconds: 50));
      expect(modalViewOutDuration, const Duration(milliseconds: 180));
    });

    for (final (window, expected) in const [
      (Size(800, 600), Size(400, 488)),
      (Size(760, 520), Size(400, 488)),
      (Size(320, 800), Size(288, 488)),
    ]) {
      testWidgets('in a ${window.width.toInt()}x${window.height.toInt()} '
          'window the frame measures ${expected.width.toInt()}x'
          '${expected.height.toInt()} and is centered', (tester) async {
        await _mount(tester, window: window);
        await _open(tester, (_) => _fullView(ModalViewLayout.standard));

        final rect = tester.getRect(_frame);
        expect(rect.size, expected);
        expect(rect.center, Offset(window.width / 2, window.height / 2));
        expect(tester.takeException(), isNull);
      });
    }

    for (final MapEntry(key: name, value: brightness) in _themes.entries) {
      testWidgets('[$name] the frame is a card with radius 20 and the '
          'popover shadow over the scrim, and the route is not barrier '
          'dismissible', (tester) async {
        final colors = _colorsFor(brightness);
        await _mount(tester, brightness: brightness);
        final opened = await _open(
          tester,
          (_) => const ModalView(title: 'Title'),
        );

        final box = tester.widget<DecoratedBox>(_frame).decoration;
        expect(box, isA<BoxDecoration>());
        box as BoxDecoration;
        expect(box.color, colors.card);
        expect(box.borderRadius, BorderRadius.circular(modalRadius));
        expect(box.boxShadow, colors.popoverShadow);
        final clip = tester.widget<ClipRRect>(
          _in(find.byType(NbModal), find.byType(ClipRRect)).first,
        );
        expect(clip.borderRadius, BorderRadius.circular(modalRadius));
        expect(opened.route.barrierColor, colors.scrim);
        expect(opened.route.barrierDismissible, isFalse);
      });
    }
  });

  group('E282: Esc and a click outside follow onDismiss (point 185)', () {
    testWidgets('each Esc and each click outside calls the callback that '
        'onDismiss gives at that moment', (tester) async {
      await _mount(tester);
      final log = <String>[];
      var asked = 0;
      VoidCallback? handler = () => log.add('first');
      await _open(
        tester,
        (_) => _fullView(ModalViewLayout.standard),
        onDismiss: () {
          asked++;
          return handler;
        },
      );

      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pump();
      expect(log, ['first']);

      handler = () => log.add('second');
      await tester.tapAt(const Offset(8, 8));
      await tester.pump();
      expect(log, ['first', 'second']);

      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pump();
      expect(log, ['first', 'second', 'second']);
      expect(asked, 3);
    });

    testWidgets('when onDismiss gives null, Esc and a click outside do '
        'nothing and the frame stays', (tester) async {
      await _mount(tester);
      var asked = 0;
      await _open(
        tester,
        (_) => _fullView(ModalViewLayout.standard),
        onDismiss: () {
          asked++;
          return null;
        },
      );

      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.tapAt(const Offset(8, 8));
      await tester.pump(modalTransitionDuration);

      expect(asked, 2);
      expect(find.byType(NbModal), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('without onDismiss, Esc and a click outside do nothing and '
        'the frame stays', (tester) async {
      await _mount(tester);
      await _open(tester, (_) => _fullView(ModalViewLayout.standard));

      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.tapAt(const Offset(8, 8));
      await tester.pump(modalTransitionDuration);

      expect(find.byType(NbModal), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('a callback that pops closes the route with its value', (
      tester,
    ) async {
      await _mount(tester);
      final opened = await _open(
        tester,
        (_) => const ModalView(title: 'Title'),
        onDismiss: () =>
            () => Navigator.of(_homeKey.currentContext!).pop('dismissed'),
      );
      String? value;
      opened.result.then((result) => value = result);

      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pump();
      await tester.pump(
        modalTransitionDuration + const Duration(milliseconds: 1),
      );

      expect(value, 'dismissed');
      expect(find.byType(NbModal), findsNothing);
    });

    testWidgets('a click on the title, on the stage, in the gap between the '
        'buttons or in the padding of the frame does not dismiss; one '
        'outside does (point 229)', (tester) async {
      await _mount(tester, reduceMotion: true);
      final log = <String>[];
      await _open(
        tester,
        (_) => _fullView(ModalViewLayout.standard),
        onDismiss: () =>
            () => log.add('dismiss'),
      );

      final frame = tester.getRect(_frame);
      final left = tester.getRect(find.byKey(_leftKey));
      final right = tester.getRect(find.byKey(_rightKey));
      final spots = [
        tester.getCenter(find.text('Title')),
        tester.getCenter(find.byKey(_stageKey)),
        Offset((left.right + right.left) / 2, left.center.dy),
        frame.topLeft + const Offset(6, 6),
        frame.bottomRight - const Offset(6, 6),
      ];
      for (final spot in spots) {
        await tester.tapAt(spot);
        await tester.pump();
        expect(log, isEmpty, reason: '$spot');
      }

      await tester.tapAt(frame.topLeft - const Offset(6, 6));
      await tester.pump();
      expect(log, ['dismiss']);
    });
  });

  group('E282: the route transition (point 185)', () {
    testWidgets('the frame enters in 320 ms with labEaseOut: fade, scale '
        'from 0.96 and 10 px up, and leaves the same way back', (tester) async {
      await _mount(tester);
      final opened = await _open(
        tester,
        (_) => const ModalView(title: 'Title'),
        finish: false,
      );
      final modal = find.byType(NbModal);

      expect(opened.route.transitionDuration, modalTransitionDuration);
      expect(opened.route.reverseTransitionDuration, modalTransitionDuration);
      expect(_fade(tester, modal), 0);
      expect(_scale(tester, modal), closeTo(0.96, 1e-9));
      expect(_shift(tester, modal), closeTo(10, 1e-9));

      await tester.pump(const Duration(milliseconds: 160));
      final eased = _labEaseOut.transform(0.5);
      expect(_fade(tester, modal), closeTo(eased, 1e-6));
      expect(_scale(tester, modal), closeTo(0.96 + 0.04 * eased, 1e-6));
      expect(_shift(tester, modal), closeTo(10 * (1 - eased), 1e-6));

      await tester.pump(const Duration(milliseconds: 160));
      expect(_fade(tester, modal), 1);
      expect(_scale(tester, modal), 1);
      expect(_shift(tester, modal), 0);

      Navigator.of(_homeKey.currentContext!).pop();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 160));
      expect(modal, findsOneWidget);
      expect(_fade(tester, modal), closeTo(eased, 1e-6));

      await tester.pump(const Duration(milliseconds: 161));
      expect(modal, findsNothing);
    });

    testWidgets('with reduced motion the route has no transition: it is '
        'whole in the first frame and gone in the frame after closing', (
      tester,
    ) async {
      await _mount(tester, reduceMotion: true);
      final opened = await _open(
        tester,
        (_) => const ModalView(title: 'Title'),
        finish: false,
      );
      final modal = find.byType(NbModal);

      expect(opened.route.transitionDuration, Duration.zero);
      expect(opened.route.reverseTransitionDuration, Duration.zero);
      expect(_fade(tester, modal), 1);
      expect(_scale(tester, modal), 1);
      expect(_shift(tester, modal), 0);

      Navigator.of(_homeKey.currentContext!).pop();
      await tester.pump();
      expect(modal, findsNothing);
    });

    testWidgets('homeApp with reduceMotion turns off the animations and '
        'without it leaves them on (point 200)', (tester) async {
      for (final reduce in [false, true]) {
        await tester.pumpWidget(
          homeApp(FakeAppController(), 'en', reduceMotion: reduce),
        );
        await tester.pump();
        final context = tester.element(find.byType(HomeScreen));
        expect(MediaQuery.disableAnimationsOf(context), reduce);
      }
    });
  });

  group('E282: focus of the frame (points 198 and 229)', () {
    testWidgets('the frame takes the focus when it opens and publishes its '
        'node; outside a modal there is none', (tester) async {
      await _mount(tester);
      await _open(tester, (_) => const ModalView(title: 'Title'));

      final frame = ModalViewSwitcher.frameFocusOf(
        tester.element(find.byType(ModalView)),
      );
      expect(frame, isNotNull);
      expect(FocusManager.instance.primaryFocus, same(frame));
      expect(ModalViewSwitcher.frameFocusOf(_homeKey.currentContext!), isNull);
    });
  });

  group('E282: composition of ModalView (points 185 and 232)', () {
    const gaps = {
      ModalViewLayout.standard: 16.0,
      ModalViewLayout.centered: 20.0,
      ModalViewLayout.result: 16.0,
      ModalViewLayout.titleFirst: 28.0,
    };

    for (final layout in ModalViewLayout.values) {
      testWidgets('${layout.name}: buttons at the bottom with the pair '
          'first, the eyebrow at 36 px and ${gaps[layout]!.toInt()} px '
          'between the top zone and the buttons', (tester) async {
        await _mount(tester, reduceMotion: true);
        await _open(tester, (_) => _fullView(layout));

        final frame = tester.getRect(_frame);
        final zone = tester.getRect(_zone);
        final left = tester.getRect(find.byKey(_leftKey));
        final right = tester.getRect(find.byKey(_rightKey));
        final first = tester.getRect(find.byKey(_firstKey));
        final second = tester.getRect(find.byKey(_secondKey));
        final eyebrow = tester.getRect(find.byType(ModalEyebrow));

        expect(eyebrow.top - frame.top, 36);
        expect(eyebrow.left, frame.left);
        expect(eyebrow.width, frame.width);

        expect(zone.left, frame.left + 28);
        expect(zone.width, frame.width - 56);

        expect(left.left, frame.left + 28);
        expect(right.right, frame.right - 28);
        expect(left.width, right.width);
        expect(right.left - left.right, 10);
        expect(left.top, right.top);
        expect(left.height, right.height);

        expect(first.top - left.bottom, 10);
        expect(second.top - first.bottom, 10);
        for (final action in [first, second]) {
          expect(action.left, frame.left + 28);
          expect(action.width, frame.width - 56);
          expect(action.height, 46);
        }

        expect(left.top - zone.bottom, gaps[layout]);

        if (layout == ModalViewLayout.centered) {
          final above = zone.top - (frame.top + 28);
          final below = (frame.bottom - 34) - second.bottom;
          expect(above, greaterThan(0));
          expect(above, closeTo(below, 0.5));
        } else {
          expect(zone.top, frame.top + 28);
          expect(second.bottom, frame.bottom - 34);
        }
        expect(tester.takeException(), isNull);
      });

      testWidgets('${layout.name}: order of stage, title and body', (
        tester,
      ) async {
        await _mount(tester, reduceMotion: true);
        await _open(tester, (_) => _fullView(layout, eyebrow: null));

        final zone = tester.getRect(_zone);
        final stage = tester.getRect(find.byKey(_stageKey));
        final title = tester.getRect(find.text('Title'));
        final body = tester.getRect(find.byKey(_bodyKey));

        if (layout == ModalViewLayout.titleFirst) {
          expect(title.top, zone.top + 16);
          expect(title.bottom, lessThanOrEqualTo(body.top));
          expect(body.bottom, lessThanOrEqualTo(stage.top));
        } else {
          expect(stage.bottom, lessThanOrEqualTo(title.top));
          expect(title.bottom, lessThanOrEqualTo(body.top));
          if (layout != ModalViewLayout.centered) {
            expect(stage.top - zone.top, closeTo(zone.bottom - body.bottom, 1));
          }
        }
        expect(stage.center.dx, closeTo(zone.center.dx, 0.01));
        expect(title.center.dx, closeTo(zone.center.dx, 0.01));
      });
    }

    const titles = {
      ModalViewLayout.standard: (19.0, 25.0, 330.0),
      ModalViewLayout.centered: (19.0, 25.0, 330.0),
      ModalViewLayout.result: (21.0, 28.0, 320.0),
      ModalViewLayout.titleFirst: (22.0, 28.0, 330.0),
    };

    for (final MapEntry(key: name, value: brightness) in _themes.entries) {
      for (final layout in ModalViewLayout.values) {
        final (size, line, maxWidth) = titles[layout]!;
        testWidgets('[$name] ${layout.name}: the title is $size/$line, '
            'centered, in text with headingWeight, at most ${maxWidth.toInt()} '
            'px wide and two lines, and is a header', (tester) async {
          final colors = _colorsFor(brightness);
          final longTitle = List.filled(30, 'Wide').join(' ');
          await _mount(tester, brightness: brightness, reduceMotion: true);
          await _open(
            tester,
            (_) => _fullView(layout, title: longTitle, eyebrow: null),
          );

          final text = tester.widget<Text>(find.text(longTitle));
          final style = text.style!;
          expect(style.fontSize, size);
          expect(style.height, closeTo(line / size, 1e-9));
          expect(style.letterSpacing, closeTo(-0.012 * size, 1e-9));
          expect(style.color, colors.text);
          expect(
            style.fontVariations,
            contains(FontVariation.weight(colors.headingWeight)),
          );
          expect(text.textAlign, TextAlign.center);
          expect(text.maxLines, 2);
          expect(text.overflow, TextOverflow.ellipsis);
          expect(
            tester.getSize(find.text(longTitle)).width,
            lessThanOrEqualTo(maxWidth),
          );
          final paragraph = tester.renderObject<RenderParagraph>(
            _in(find.text(longTitle), find.byType(RichText)),
          );
          expect(paragraph.didExceedMaxLines, isTrue);
          expect(
            find.ancestor(
              of: find.text(longTitle),
              matching: find.byWidgetPredicate(
                (widget) =>
                    widget is Semantics && widget.properties.header == true,
              ),
            ),
            findsOneWidget,
          );
        });
      }
    }

    testWidgets('the view names the route with its title (point 225)', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      await _mount(tester, reduceMotion: true);
      await _open(tester, (_) => _fullView(ModalViewLayout.standard));

      final naming = _semanticsUnder(
        tester,
        find.byType(NbModal),
      ).where((data) => data.flagsCollection.namesRoute).toList();
      expect(naming, hasLength(1));
      expect(naming.single.label, 'Title');
      final header = _semanticsUnder(
        tester,
        find.byType(NbModal),
      ).where((data) => data.flagsCollection.isHeader).toList();
      expect(header.map((data) => data.label), ['Title']);
      handle.dispose();
    });

    testWidgets('with large text the top zone scrolls and the buttons do not '
        'move', (tester) async {
      await _mount(
        tester,
        window: const Size(760, 520),
        reduceMotion: true,
        textScale: 1.3,
      );
      await _open(
        tester,
        (_) => _fullView(
          ModalViewLayout.standard,
          body: [
            for (var i = 0; i < 12; i++)
              ModalLead(text: 'A long line of the body number $i'),
          ],
        ),
      );

      final frame = tester.getRect(_frame);
      expect(tester.getRect(find.byKey(_secondKey)).bottom, frame.bottom - 34);
      final scrollable = tester.state<ScrollableState>(
        _in(_zone, find.byType(Scrollable)),
      );
      expect(scrollable.position.maxScrollExtent, greaterThan(0));
      expect(tester.takeException(), isNull);
    });

    for (final code in languageCodes) {
      for (final (window, scale) in const [
        (Size(320, 800), 1.0),
        (Size(320, 800), 1.3),
        (Size(760, 520), 1.3),
      ]) {
        testWidgets('[$code] nothing overflows in any layout in a '
            '${window.width.toInt()}x${window.height.toInt()} window with '
            'text at ${(scale * 100).toInt()} %', (tester) async {
          final strings = stringsFor(code);
          for (final layout in ModalViewLayout.values) {
            await _mount(
              tester,
              window: window,
              code: code,
              reduceMotion: true,
              textScale: scale,
            );
            await _open(
              tester,
              (_) => ModalView(
                layout: layout,
                stage: const SizedBox(width: 300, height: 170),
                eyebrow: ModalEyebrow(
                  text: strings.pairingEyebrow(null),
                  tone: EyebrowTone.bad,
                ),
                title: strings.networkPromptTitle,
                body: [
                  ModalLead.rich(
                    build: strings.networkPromptBody,
                    strong: 'Wi-Fi de casa',
                  ),
                  ModalAlert(text: strings.networkPromptTitle),
                  ModalNote(text: strings.trustedNetworkLabel),
                ],
                pair: [
                  ModalButton(
                    label: strings.no,
                    kind: ModalButtonKind.secondary,
                    onPressed: () {},
                    inPair: true,
                  ),
                  ModalButton(
                    label: strings.yes,
                    kind: ModalButtonKind.primary,
                    onPressed: () {},
                    inPair: true,
                  ),
                ],
                actions: [
                  ModalButton(
                    label: strings.cancelButton,
                    kind: ModalButtonKind.neutral,
                    glyph: Glyphs.cross,
                    onPressed: () {},
                  ),
                ],
              ),
            );
            expect(tester.takeException(), isNull, reason: layout.name);
          }
        });
      }
    }
  });

  group('E282: the bar of the top zone (point 244)', () {
    List<Widget> longBody() => [
      for (var i = 0; i < 12; i++)
        ModalLead(text: 'A long line of the body number $i'),
    ];

    for (final layout in ModalViewLayout.values) {
      for (final MapEntry(key: name, value: brightness) in _themes.entries) {
        testWidgets('[$name] ${layout.name}: with more content than room a '
            'bar of 4 px in hint sits on the right edge of the zone after '
            'opening, without hover or scroll, and follows the scroll', (
          tester,
        ) async {
          await _mount(
            tester,
            window: const Size(760, 520),
            brightness: brightness,
            reduceMotion: true,
            textScale: 1.3,
          );
          await _open(tester, (_) => _fullView(layout, body: longBody()));
          await tester.pump(barFadeIn);

          final hint = _colorsFor(brightness).hint;
          final zone = tester.getRect(_zone);
          final position = zonePosition(tester, _zone);
          expect(position.maxScrollExtent, greaterThan(0));
          expect(position.pixels, 0);

          final thumbs = thumbsOf(tester, _zone, hint);
          expect(thumbs, hasLength(1));
          final thumb = thumbs.single;
          expect(thumb.width, closeTo(4, 1e-6));
          expect(thumb.height, greaterThan(4));
          expect(thumb.height, lessThan(zone.height));
          expect(thumb.right, closeTo(zone.right, 0.5));
          expect(thumb.top, closeTo(zone.top, 0.5));
          expectWholeInside(thumb, zone, 'thumb');
          expectWholeInside(thumb, tester.getRect(_frame), 'thumb');

          await tester.drag(_zone, const Offset(0, -2000));
          await tester.pump();
          await tester.pump(const Duration(seconds: 1));
          expect(position.pixels, position.maxScrollExtent);
          final moved = thumbsOf(tester, _zone, hint);
          expect(moved, hasLength(1));
          expect(moved.single.bottom, closeTo(zone.bottom, 0.5));
          expect(moved.single.top, greaterThan(thumb.top));
          expect(tester.takeException(), isNull);
        });
      }

      testWidgets('${layout.name}: when everything fits there is no bar and '
          'the centred content does not move', (tester) async {
        await _mount(tester, reduceMotion: true);
        await _open(tester, (_) => _fullView(layout));
        await tester.pump(barFadeIn);

        final frame = tester.getRect(_frame);
        final zone = tester.getRect(_zone);
        final position = zonePosition(tester, _zone);
        expect(position.maxScrollExtent, 0);
        expect(
          thumbsOf(tester, _zone, _colorsFor(Brightness.light).hint),
          isEmpty,
        );
        expect(zone.left, frame.left + modalPadding.left);
        expect(zone.width, frame.width - modalPadding.horizontal);
        for (final finder in [
          find.text('Title'),
          find.byKey(_bodyKey),
          find.byKey(_stageKey),
        ]) {
          expect(
            tester.getCenter(finder).dx,
            closeTo(frame.center.dx, 0.5),
            reason: '$finder',
          );
        }
        expect(tester.takeException(), isNull);
      });
    }

    testWidgets('the same zone shows the bar once the text grows and hides '
        'it when it shrinks again', (tester) async {
      final lines = ValueNotifier<int>(1);
      addTearDown(lines.dispose);
      await _mount(tester, reduceMotion: true);
      await _open(
        tester,
        (_) => ValueListenableBuilder<int>(
          valueListenable: lines,
          builder: (context, count, _) => _fullView(
            ModalViewLayout.standard,
            body: [
              for (var i = 0; i < count; i++)
                ModalLead(text: 'A long line of the body number $i'),
            ],
          ),
        ),
      );
      await tester.pump(barFadeIn);
      final hint = _colorsFor(Brightness.light).hint;
      expect(thumbsOf(tester, _zone, hint), isEmpty);

      lines.value = 14;
      await tester.pump();
      await tester.pump(barFadeIn);
      expect(zonePosition(tester, _zone).maxScrollExtent, greaterThan(0));
      expect(thumbsOf(tester, _zone, hint), hasLength(1));

      lines.value = 1;
      await tester.pump();
      await tester.pump(barFadeIn);
      expect(zonePosition(tester, _zone).maxScrollExtent, 0);
      expect(thumbsOf(tester, _zone, hint), isEmpty);
      expect(tester.takeException(), isNull);
    });
  });

  group('E282: ModalEyebrow (points 185 and 232)', () {
    for (final MapEntry(key: name, value: brightness) in _themes.entries) {
      testWidgets('[$name] each tone paints its ink in capitals at 700, '
          '11.5/16, spacing 1.725 and centered', (tester) async {
        final colors = _colorsFor(brightness);
        final inks = {
          EyebrowTone.ok: colors.successInk,
          EyebrowTone.bad: colors.danger,
          EyebrowTone.warn: colors.warning,
          EyebrowTone.ice: colors.ice,
          EyebrowTone.neutral: colors.textWeak,
        };
        await _mount(
          tester,
          brightness: brightness,
          reduceMotion: true,
          body: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (final tone in EyebrowTone.values)
                ModalEyebrow(text: 'Tone ${tone.name}', tone: tone),
            ],
          ),
        );

        for (final tone in EyebrowTone.values) {
          final text = tester.widget<Text>(
            find.text('Tone ${tone.name}'.toUpperCase()),
          );
          final style = text.style!;
          expect(style.color, inks[tone], reason: tone.name);
          expect(style.fontWeight, FontWeight.w700);
          expect(style.fontSize, 11.5);
          expect(style.height, closeTo(16 / 11.5, 1e-9));
          expect(style.letterSpacing, 1.725);
          expect(text.textAlign, TextAlign.center);
        }
      });
    }

    testWidgets('the screen reader reads the normal text, not the capitals', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      await _mount(
        tester,
        reduceMotion: true,
        body: const ModalEyebrow(text: 'Not paired', tone: EyebrowTone.bad),
      );

      expect(find.bySemanticsLabel('Not paired'), findsOneWidget);
      expect(find.bySemanticsLabel('NOT PAIRED'), findsNothing);
      handle.dispose();
    });

    for (final (tone, delay) in const [
      (EyebrowTone.bad, 250),
      (EyebrowTone.warn, 250),
      (EyebrowTone.ice, 250),
      (EyebrowTone.neutral, 250),
      (EyebrowTone.ok, 900),
    ]) {
      testWidgets('${tone.name} with no delay waits $delay ms and then fades '
          'and grows from 0.9 in 400 ms', (tester) async {
        await _mount(
          tester,
          body: ModalEyebrow(text: 'Line', tone: tone),
        );
        final line = find.text('LINE');

        expect(_fade(tester, line), 0);
        await tester.pump(Duration(milliseconds: delay - 1));
        expect(_fade(tester, line), 0);
        expect(_scale(tester, line), closeTo(0.9, 1e-9));

        await tester.pump(const Duration(milliseconds: 201));
        final eased = _labEaseOut.transform(0.5);
        expect(_fade(tester, line), closeTo(eased, 1e-6));
        expect(_scale(tester, line), closeTo(0.9 + 0.1 * eased, 1e-6));

        await tester.pump(const Duration(milliseconds: 200));
        expect(_fade(tester, line), 1);
        expect(_scale(tester, line), 1);
      });
    }

    testWidgets('a given delay wins over the one of the tone', (tester) async {
      await _mount(
        tester,
        body: const ModalEyebrow(
          text: 'Line',
          tone: EyebrowTone.ok,
          delay: Duration(milliseconds: 100),
        ),
      );
      final line = find.text('LINE');

      await tester.pump(const Duration(milliseconds: 99));
      expect(_fade(tester, line), 0);
      await tester.pump(const Duration(milliseconds: 201));
      expect(_fade(tester, line), closeTo(_labEaseOut.transform(0.5), 1e-6));
      await tester.pump(const Duration(milliseconds: 200));
      expect(_fade(tester, line), 1);
    });

    testWidgets('with reduced motion it is still and visible from the first '
        'frame', (tester) async {
      await _mount(
        tester,
        reduceMotion: true,
        body: const ModalEyebrow(text: 'Line', tone: EyebrowTone.ok),
      );
      final line = find.text('LINE');

      expect(_fade(tester, line), 1);
      expect(_scale(tester, line), 1);
    });
  });

  group('E282: ModalLead and emphasized (points 215 and 228)', () {
    for (final MapEntry(key: name, value: brightness) in _themes.entries) {
      for (final tight in [false, true]) {
        final (size, line) = tight ? (13.0, 18.0) : (14.0, 20.0);
        testWidgets('[$name] ${tight ? 'tight' : 'normal'}: $size/$line in '
            'textWeak, centered, 8 px above and at most 320 px wide', (
          tester,
        ) async {
          final colors = _colorsFor(brightness);
          final long = List.filled(40, 'word').join(' ');
          await _mount(
            tester,
            brightness: brightness,
            body: SizedBox(
              width: 400,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [ModalLead(text: long, tight: tight)],
              ),
            ),
          );

          final text = tester.widget<Text>(find.text(long));
          expect(text.style!.fontSize, size);
          expect(text.style!.height, closeTo(line / size, 1e-9));
          expect(text.style!.color, colors.textWeak);
          expect(text.textAlign, TextAlign.center);
          expect(
            tester.getTopLeft(find.text(long)).dy -
                tester.getTopLeft(find.byType(ModalLead)).dy,
            8,
          );
          expect(tester.getSize(find.text(long)).width, lessThanOrEqualTo(320));
        });
      }
    }

    for (final code in languageCodes) {
      final strings = stringsFor(code);
      for (final network in ['equipo', 'equipos', 'casa', 'home']) {
        testWidgets('[$code] a network called "$network" is the only bold '
            'part, in the slot of the text, and the text is whole', (
          tester,
        ) async {
          final colors = NbColors.light;
          await _mount(
            tester,
            code: code,
            body: ModalLead.rich(
              build: strings.networkPromptBody,
              strong: network,
            ),
          );

          final rich = tester.widget<RichText>(
            _in(find.byType(ModalLead), find.byType(RichText)),
          );
          final full = strings.networkPromptBody(network);
          expect(rich.text.toPlainText(), full);
          expect(rich.textAlign, TextAlign.center);

          final leaves = <TextSpan>[];
          rich.text.visitChildren((span) {
            if (span is TextSpan && span.text != null) leaves.add(span);
            return true;
          });
          final bold = [
            for (final leaf in leaves)
              if (leaf.style?.fontWeight == FontWeight.w600) leaf,
          ];
          expect(bold, hasLength(1));
          expect(bold.single.text, network);
          expect(bold.single.style!.color, colors.text);

          final before = leaves
              .takeWhile((leaf) => !identical(leaf, bold.single))
              .map((leaf) => leaf.text)
              .join();
          expect(before, full.substring(0, full.indexOf('"') + 1));
          for (final leaf in leaves) {
            if (identical(leaf, bold.single)) continue;
            expect(leaf.style?.fontWeight, isNot(FontWeight.w600));
            expect(leaf.style?.color, isNot(colors.text));
          }
        });
      }
    }

    test('emphasized gives three spans split at the slot of the template', () {
      const base = TextStyle(fontSize: 14);
      const strong = TextStyle(fontSize: 14, fontWeight: FontWeight.w600);
      final span = emphasized(
        (part) => 'The $part and the end',
        'net',
        base: base,
        strong: strong,
      );

      expect(span.style, base);
      expect(span.children, hasLength(3));
      final [first, middle, last] = span.children!.cast<TextSpan>();
      expect(first.text, 'The ');
      expect(first.style, isNull);
      expect(middle.text, 'net');
      expect(middle.style, strong);
      expect(last.text, ' and the end');
      expect(last.style, isNull);
      expect(span.toPlainText(), 'The net and the end');
    });

    test('a name that also appears in the template is not looked for: the '
        'bold part is only the slot', () {
      const base = TextStyle(fontSize: 14);
      const strong = TextStyle(fontWeight: FontWeight.w600);
      final span = emphasized(
        (part) => 'home is where "$part" lives, home',
        'home',
        base: base,
        strong: strong,
      );

      final [first, middle, last] = span.children!.cast<TextSpan>();
      expect(first.text, 'home is where "');
      expect(middle.text, 'home');
      expect(middle.style, strong);
      expect(last.text, '" lives, home');
    });

    test('a template without the part, or with it twice, gives one span '
        'with the whole text', () {
      const base = TextStyle(fontSize: 14);
      const strong = TextStyle(fontWeight: FontWeight.w600);
      final none = emphasized(
        (part) => 'No part here',
        'net',
        base: base,
        strong: strong,
      );
      expect(none.children, isNull);
      expect(none.text, 'No part here');
      expect(none.style, base);

      final twice = emphasized(
        (part) => '$part and $part',
        'net',
        base: base,
        strong: strong,
      );
      expect(twice.children, isNull);
      expect(twice.text, 'net and net');
      expect(twice.style, base);
    });
  });

  group('E282: ModalAlert and ModalNote (point 185)', () {
    for (final MapEntry(key: name, value: brightness) in _themes.entries) {
      testWidgets('[$name] the alert is a full width dangerWeak box with '
          'the warning glyph and the note a centered check in successInk', (
        tester,
      ) async {
        final colors = _colorsFor(brightness);
        await _mount(
          tester,
          brightness: brightness,
          body: const SizedBox(
            width: 344,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                ModalAlert(text: 'Alert'),
                ModalNote(text: 'Note'),
              ],
            ),
          ),
        );

        final alertBox =
            tester
                    .widget<DecoratedBox>(
                      _in(find.byType(ModalAlert), find.byType(DecoratedBox)),
                    )
                    .decoration
                as BoxDecoration;
        expect(alertBox.color, colors.dangerWeak);
        expect(alertBox.borderRadius, BorderRadius.circular(12));
        expect(tester.getSize(find.byType(ModalAlert)).width, 344);
        final alertGlyph = tester.widget<GlyphIcon>(
          _in(find.byType(ModalAlert), find.byType(GlyphIcon)),
        );
        expect(alertGlyph.glyph, same(Glyphs.warn));
        expect(alertGlyph.size, 16);
        expect(alertGlyph.color, colors.danger);
        final alertText = tester.widget<Text>(find.text('Alert'));
        expect(alertText.style!.fontSize, 12.5);
        expect(alertText.style!.height, closeTo(17 / 12.5, 1e-9));
        expect(alertText.style!.fontWeight, FontWeight.w600);
        expect(alertText.style!.color, colors.danger);
        expect(alertText.textAlign, TextAlign.start);
        expect(
          tester
                  .getTopLeft(
                    _in(find.byType(ModalAlert), find.byType(DecoratedBox)),
                  )
                  .dy -
              tester.getTopLeft(find.byType(ModalAlert)).dy,
          12,
        );

        final noteGlyph = tester.widget<GlyphIcon>(
          _in(find.byType(ModalNote), find.byType(GlyphIcon)),
        );
        expect(noteGlyph.glyph, same(Glyphs.check));
        expect(noteGlyph.size, 13);
        expect(noteGlyph.color, colors.successInk);
        final noteText = tester.widget<Text>(find.text('Note'));
        expect(noteText.style!.fontSize, 12);
        expect(noteText.style!.height, closeTo(16 / 12, 1e-9));
        expect(noteText.style!.color, colors.textWeak);
        final note = tester.getRect(find.byType(ModalNote));
        final row = tester.getRect(
          _in(find.byType(ModalNote), find.byType(Row)),
        );
        expect(row.center.dx, closeTo(note.center.dx, 0.01));
      });
    }
  });

  group('E282: ModalViewSwitcher (points 185, 199, 225, 229 and 230)', () {
    testWidgets('with the same key the child changes at once and keeps its '
        'State', (tester) async {
      await _mount(tester);
      final switcher = await _openSwitcher(tester);
      await tester.pump(dialogActivationDelay);
      expect(_buttonOf(tester, 'A'), isNotNull);

      switcher.go('A', title: 'Title A2');
      await tester.pump();

      expect(switcher.log.born, ['A']);
      expect(switcher.log.disposed, isEmpty);
      expect(find.text('Title A2'), findsOneWidget);
      expect(find.text('Title A'), findsNothing);
      expect(_buttonOf(tester, 'A'), isNotNull);
      expect(_viewOpacity(tester, 'A'), 1);
      expect(_viewShift(tester, 'A'), 0);
      expect(_viewBlurred(tester, 'A'), isFalse);
      expect(_ignoring(tester, 'A'), isFalse);
    });

    testWidgets('with another key the old view leaves in 180 ms and the new '
        'one enters in 360 ms after 50 ms, both with labEaseOut', (
      tester,
    ) async {
      await _mount(tester);
      final switcher = await _openSwitcher(tester);

      switcher.go('B');
      await tester.pump();
      expect(_viewOpacity(tester, 'A'), 1);
      expect(_viewOpacity(tester, 'B'), 0);
      expect(_viewShift(tester, 'B'), 10);
      expect(_viewBlurred(tester, 'B'), isTrue);

      await tester.pump(const Duration(milliseconds: 49));
      expect(_viewOpacity(tester, 'B'), 0);
      expect(_viewShift(tester, 'B'), 10);

      await tester.pump(const Duration(milliseconds: 1));
      final out = _labEaseOut.transform(50 / 180);
      expect(_viewOpacity(tester, 'A'), closeTo(1 - out, 1e-6));
      expect(_viewShift(tester, 'A'), closeTo(-6 * out, 1e-6));

      await tester.pump(const Duration(milliseconds: 40));
      final half = _labEaseOut.transform(0.5);
      expect(_viewOpacity(tester, 'A'), closeTo(1 - half, 1e-6));
      expect(_viewShift(tester, 'A'), closeTo(-6 * half, 1e-6));
      expect(_viewBlurred(tester, 'A'), isTrue);

      await tester.pump(const Duration(milliseconds: 91));
      expect(find.text('Title A'), findsNothing);
      expect(switcher.log.disposed, ['A']);

      await tester.pump(const Duration(milliseconds: 49));
      expect(_viewOpacity(tester, 'B'), closeTo(half, 1e-6));
      expect(_viewShift(tester, 'B'), closeTo(10 * (1 - half), 1e-6));

      await tester.pump(const Duration(milliseconds: 180));
      expect(_viewOpacity(tester, 'B'), 1);
      expect(_viewShift(tester, 'B'), 0);
      expect(_viewBlurred(tester, 'B'), isFalse);
      expect(tester.takeException(), isNull);
    });

    testWidgets('the leaving view is under IgnorePointer, ExcludeFocus and '
        'ExcludeSemantics, and the entering one is not', (tester) async {
      await _mount(tester);
      final switcher = await _openSwitcher(tester);

      expect(_ignoring(tester, 'A'), isFalse);
      expect(_focusExcluded(tester, 'A'), isFalse);
      expect(_semanticsExcluded(tester, 'A'), isFalse);

      switcher.go('B');
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      expect(_ignoring(tester, 'A'), isTrue);
      expect(_focusExcluded(tester, 'A'), isTrue);
      expect(_semanticsExcluded(tester, 'A'), isTrue);
      expect(_ignoring(tester, 'B'), isFalse);
      expect(_focusExcluded(tester, 'B'), isFalse);
      expect(_semanticsExcluded(tester, 'B'), isFalse);
    });

    testWidgets('a click on the old button at 100 ms reaches nobody, and the '
        'new button takes it once armed', (tester) async {
      await _mount(tester);
      final dismissed = <String>[];
      final switcher = await _openSwitcher(
        tester,
        onDismiss: () =>
            () => dismissed.add('dismiss'),
      );
      await tester.pump(dialogActivationDelay);
      expect(_buttonOf(tester, 'A'), isNotNull);
      final spot = tester.getCenter(find.text('Go A'));

      switcher.go('B');
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.text('Go A'), findsOneWidget);
      await tester.tapAt(spot);
      await tester.pump();

      expect(switcher.log.taps, isEmpty);
      expect(dismissed, isEmpty);
      expect(_buttonOf(tester, 'B'), isNull);

      await tester.pump(
        dialogActivationDelay - const Duration(milliseconds: 100),
      );
      expect(_buttonOf(tester, 'B'), isNotNull);
      await tester.tapAt(spot);
      await tester.pump();
      expect(switcher.log.taps, ['B']);
      expect(dismissed, isEmpty);
    });

    testWidgets('with reduced motion the change is immediate and the old '
        'view is gone in the same frame', (tester) async {
      await _mount(tester, reduceMotion: true);
      final switcher = await _openSwitcher(tester);

      switcher.go('B');
      await tester.pump();

      expect(find.text('Title A'), findsNothing);
      expect(switcher.log.disposed, ['A']);
      expect(_viewOpacity(tester, 'B'), 1);
      expect(_viewShift(tester, 'B'), 0);
      expect(_viewBlurred(tester, 'B'), isFalse);
    });

    testWidgets('A, B and A again with 60 ms between changes: one copy of A '
        'with a new State, B leaving, A disarmed for 500 ms and only A after '
        '400 ms (point 230)', (tester) async {
      await _mount(tester);
      final switcher = await _openSwitcher(tester);
      await tester.pump(dialogActivationDelay);

      switcher.go('B');
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 60));
      switcher.go('A');
      await tester.pump();

      expect(tester.takeException(), isNull);
      expect(_viewOf('A'), findsOneWidget);
      expect(find.text('Title A'), findsOneWidget);
      expect(_ignoring(tester, 'A'), isFalse);
      expect(find.text('Title B'), findsOneWidget);
      expect(_ignoring(tester, 'B'), isTrue);
      expect(_focusExcluded(tester, 'B'), isTrue);
      expect(_semanticsExcluded(tester, 'B'), isTrue);
      expect(switcher.log.born, ['A', 'B', 'A']);
      expect(switcher.log.disposed, ['A']);
      expect(_buttonOf(tester, 'A'), isNull);

      await tester.pump(const Duration(milliseconds: 400));
      expect(find.text('Title B'), findsNothing);
      expect(_viewOf('B'), findsNothing);
      expect(_viewOf('A'), findsOneWidget);
      expect(_buttonOf(tester, 'A'), isNull);

      await tester.pump(const Duration(milliseconds: 99));
      expect(_buttonOf(tester, 'A'), isNull);
      await tester.pump(const Duration(milliseconds: 1));
      expect(_buttonOf(tester, 'A'), isNotNull);
      expect(tester.takeException(), isNull);
    });

    for (final reduce in [false, true]) {
      testWidgets('${reduce ? 'with reduced motion, ' : ''}when the focused '
          'button leaves, the focus goes back to the frame and Esc still '
          'works (point 229)', (tester) async {
        await _mount(tester, reduceMotion: reduce);
        final dismissed = <String>[];
        final switcher = await _openSwitcher(
          tester,
          onDismiss: () =>
              () => dismissed.add('esc'),
        );
        await tester.pump(dialogActivationDelay);

        await tester.sendKeyEvent(LogicalKeyboardKey.tab);
        await tester.pump();
        expect(
          FocusManager.instance.primaryFocus?.context
              ?.findAncestorWidgetOfExactType<ModalButton>()
              ?.label,
          'Go A',
        );

        switcher.go('B');
        await tester.pump();
        await tester.pump();

        final frame = ModalViewSwitcher.frameFocusOf(
          tester.element(find.text('Title B')),
        );
        expect(frame, isNotNull);
        expect(FocusManager.instance.primaryFocus, same(frame));

        await tester.sendKeyEvent(LogicalKeyboardKey.escape);
        await tester.pump();
        expect(dismissed, ['esc']);
        await tester.pump(const Duration(milliseconds: 500));
      });
    }

    testWidgets('during the change only the new view names the route and '
        'nothing of the old one is read (point 225)', (tester) async {
      final handle = tester.ensureSemantics();
      await _mount(tester);
      final switcher = await _openSwitcher(tester);

      List<String> naming() => [
        for (final data in _semanticsUnder(tester, find.byType(NbModal)))
          if (data.flagsCollection.namesRoute) data.label,
      ];
      expect(naming(), ['Title A']);

      switcher.go('B');
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.text('Title A'), findsOneWidget);

      expect(naming(), ['Title B']);
      final labels = [
        for (final data in _semanticsUnder(tester, find.byType(NbModal)))
          data.label,
      ];
      expect(labels.where((label) => label.contains('A')), isEmpty);
      expect(labels, contains('Title B'));
      handle.dispose();
    });

    testWidgets('removing the modal in the middle of a change leaves no '
        'controller alive and no error', (tester) async {
      await _mount(tester);
      final switcher = await _openSwitcher(tester);

      switcher.go('B');
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      Navigator.of(_homeKey.currentContext!).pop();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      switcher.go('C');
      await tester.pump(const Duration(milliseconds: 600));

      expect(find.byType(NbModal), findsNothing);
      expect(tester.takeException(), isNull);
      expect(switcher.log.disposed, containsAll(['A', 'B']));
    });
  });
}
