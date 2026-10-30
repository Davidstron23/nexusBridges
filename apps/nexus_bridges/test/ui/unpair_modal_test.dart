import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nexus_bridges/src/l10n/app_strings.dart';
import 'package:nexus_bridges/src/ui/exit_flow.dart';
import 'package:nexus_bridges/src/ui/icons/device_disc.dart';
import 'package:nexus_bridges/src/ui/icons/glyphs.dart';
import 'package:nexus_bridges/src/ui/modal/modal_button.dart';
import 'package:nexus_bridges/src/ui/modal/modal_frame.dart';
import 'package:nexus_bridges/src/ui/modal/stage.dart';
import 'package:nexus_bridges/src/ui/modal/stage_kit.dart';
import 'package:nexus_bridges/src/ui/theme/app_theme.dart';
import 'package:nexus_bridges/src/ui/unpair_modal.dart';
import 'package:nexus_bridges_core/nexus_bridges_core.dart';

import 'cover_fixtures.dart';
import 'fake_app_controller.dart';
import 'lifecycle_fixtures.dart';
import 'pairing_fixtures.dart' show entry, view;
import 'segoe_font.dart';

const String _name = 'Port\u00E1til de Ana';
const NodeState _sending = NodeState(transferInProgress: true);
const Duration _breakTime = Duration(milliseconds: 1500);
const Duration _settled = Duration(milliseconds: 400);
const Offset _outside = Offset(4, 4);
const Duration _routeGone = Duration(milliseconds: 400);

final GlobalKey _homeKey = GlobalKey();

Future<void> _mount(
  WidgetTester tester, {
  String code = 'en',
  bool reduceMotion = false,
  Size window = const Size(800, 600),
  double textScale = 1,
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
      theme: buildTheme(Brightness.dark),
      darkTheme: buildTheme(Brightness.dark),
      themeMode: ThemeMode.dark,
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

final class _Opened {
  int confirms = 0;
  bool? result;
  bool finished = false;
}

Future<_Opened> _open(
  WidgetTester tester, {
  String name = _name,
  DeviceType? type = DeviceType.mobile,
}) async {
  final opened = _Opened();
  unawaited(
    confirmUnpairDevice(
      _homeKey.currentContext!,
      name: name,
      type: type,
      onConfirm: () async {
        opened.confirms++;
      },
    ).then((value) {
      opened.result = value;
      opened.finished = true;
    }),
  );
  await tester.pump();
  await tester.pump(modalTransitionDuration);
  return opened;
}

Finder _buttonFinder(String label) =>
    find.widgetWithText(ModalButton, label, skipOffstage: false);

List<ModalButton> _buttons(WidgetTester tester, String label) =>
    tester.widgetList<ModalButton>(_buttonFinder(label)).toList();

List<StageScene> _scenes(WidgetTester tester) => [
  for (final stage in tester.widgetList<ModalStage>(find.byType(ModalStage)))
    stage.scene,
];

Future<void> _closeOut(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(_routeGone);
  await tester.pump();
}

void main() {
  for (final code in languageCodes) {
    final strings = stringsFor(code);

    group('[$code] E289 unpair: what it shows (RF-112 of the 003)', () {
      testWidgets('the title and the body name the device, the stage is the '
          'swaying bridge with the device glyph, and Cancel and Unpair '
          'go side by side', (tester) async {
        await _mount(tester, code: code);
        final opened = await _open(tester);

        expect(find.byType(NbModal), findsOneWidget);
        expect(find.text(strings.unpairTitle(_name)), findsOneWidget);
        expect(find.text(strings.unpairBody(_name)), findsOneWidget);
        final stage = tester.widget<ModalStage>(find.byType(ModalStage));
        expect(stage.scene, StageScene.unpairLoop);
        expect(stage.input.peer, DeviceGlyph.phone);

        final view = tester.widget<ModalView>(find.byType(ModalView));
        expect(view.actions, isEmpty);
        final pair = view.pair.cast<ModalButton>();
        expect(
          [for (final b in pair) b.label],
          [strings.cancelButton, strings.unpairButton],
        );
        expect(pair[0].kind, ModalButtonKind.neutral);
        expect(pair[1].kind, ModalButtonKind.negative);
        expect(pair[1].glyph, Glyphs.unlink);
        expect(pair.every((b) => b.inPair), isTrue);
        expect(opened.confirms, 0);
        expect(opened.finished, isFalse);
      });

      testWidgets('a desktop or an unknown type shows the computer glyph', (
        tester,
      ) async {
        await _mount(tester, code: code);
        for (final type in const [DeviceType.desktop, null]) {
          final opened = await _open(tester, type: type);
          expect(
            tester.widget<ModalStage>(find.byType(ModalStage)).input.peer,
            DeviceGlyph.pc,
          );
          await tester.tap(_buttonFinder(strings.cancelButton));
          await _closeOut(tester);
          expect(opened.result, isFalse);
        }
      });

      testWidgets('both buttons work from the first frame, with no 500 ms '
          'activation delay', (tester) async {
        await _mount(tester, code: code);
        final opened = _Opened();
        unawaited(
          confirmUnpairDevice(
            _homeKey.currentContext!,
            name: _name,
            type: DeviceType.mobile,
            onConfirm: () async {
              opened.confirms++;
            },
          ).then((value) {
            opened.result = value;
            opened.finished = true;
          }),
        );
        await tester.pump();
        await tester.pump(modalTransitionDuration);

        expect(
          _buttons(tester, strings.cancelButton).single.onPressed,
          isNotNull,
        );
        expect(
          _buttons(tester, strings.unpairButton).single.onPressed,
          isNotNull,
        );
        await tester.tap(_buttonFinder(strings.unpairButton));
        expect(opened.confirms, 1);
        await tester.pump(_breakTime);
        await _closeOut(tester);
        expect(opened.result, isTrue);
      });
    });

    group('[$code] E289 unpair: confirming in motion (RF-112, RF-113)', () {
      testWidgets('Unpair calls onConfirm once at the click, breaks the '
          'bridge, disables both buttons and closes with true at 1.5 s', (
        tester,
      ) async {
        await _mount(tester, code: code);
        final opened = await _open(tester);

        await tester.tap(_buttonFinder(strings.unpairButton));
        expect(opened.confirms, 1);
        await tester.pump();
        expect(_scenes(tester), contains(StageScene.unpairBreak));

        await tester.pump(_settled);
        expect(_scenes(tester), [StageScene.unpairBreak]);
        expect(_buttons(tester, strings.cancelButton).single.onPressed, isNull);
        expect(_buttons(tester, strings.unpairButton).single.onPressed, isNull);
        expect(find.text(strings.unpairTitle(_name)), findsOneWidget);

        await tester.tap(
          _buttonFinder(strings.unpairButton),
          warnIfMissed: false,
        );
        await tester.tap(
          _buttonFinder(strings.cancelButton),
          warnIfMissed: false,
        );
        await tester.pump();
        expect(opened.confirms, 1);
        expect(opened.finished, isFalse);

        await tester.pump(
          _breakTime - _settled - const Duration(milliseconds: 2),
        );
        expect(opened.finished, isFalse);
        expect(find.byType(NbModal), findsOneWidget);

        await tester.pump(const Duration(milliseconds: 2));
        expect(opened.result, isTrue);
        await _closeOut(tester);
        expect(find.byType(NbModal), findsNothing);
        expect(opened.confirms, 1);
      });

      testWidgets('after confirming, Esc and a tap outside do nothing', (
        tester,
      ) async {
        await _mount(tester, code: code);
        final opened = await _open(tester);

        await tester.tap(_buttonFinder(strings.unpairButton));
        await tester.pump(const Duration(milliseconds: 200));
        await tester.sendKeyEvent(LogicalKeyboardKey.escape);
        await tester.pump();
        await tester.tapAt(_outside);
        await tester.pump(const Duration(milliseconds: 300));

        expect(opened.finished, isFalse);
        expect(find.byType(NbModal), findsOneWidget);
        expect(opened.confirms, 1);

        await tester.pump(_breakTime);
        expect(opened.result, isTrue);
        await _closeOut(tester);
      });

      testWidgets('closing the app while the bridge breaks leaves no timer '
          'alive and the unpair already made', (tester) async {
        await _mount(tester, code: code);
        final opened = await _open(tester);

        await tester.tap(_buttonFinder(strings.unpairButton));
        await tester.pump(const Duration(milliseconds: 500));
        await tester.pumpWidget(const SizedBox());
        await tester.pump(_breakTime);

        expect(opened.confirms, 1);
        expect(tester.takeException(), isNull);
      });
    });

    group('[$code] E289 unpair: answering no (RF-112)', () {
      testWidgets('Cancel closes with false at once and does not confirm', (
        tester,
      ) async {
        await _mount(tester, code: code);
        final opened = await _open(tester);

        await tester.tap(_buttonFinder(strings.cancelButton));
        await tester.pump();

        expect(opened.result, isFalse);
        expect(opened.confirms, 0);
        await _closeOut(tester);
        expect(find.byType(NbModal), findsNothing);
      });

      testWidgets('Esc closes with false at once and does not confirm', (
        tester,
      ) async {
        await _mount(tester, code: code);
        final opened = await _open(tester);

        await tester.sendKeyEvent(LogicalKeyboardKey.escape);
        await tester.pump();

        expect(opened.result, isFalse);
        expect(opened.confirms, 0);
        await _closeOut(tester);
        expect(find.byType(NbModal), findsNothing);
      });

      testWidgets('a tap outside closes with false at once and does not '
          'confirm', (tester) async {
        await _mount(tester, code: code);
        final opened = await _open(tester);

        await tester.tapAt(_outside);
        await tester.pump();

        expect(opened.result, isFalse);
        expect(opened.confirms, 0);
        await _closeOut(tester);
        expect(find.byType(NbModal), findsNothing);
      });

      testWidgets('a tap inside the frame does not close it', (tester) async {
        await _mount(tester, code: code);
        final opened = await _open(tester);

        await tester.tap(find.text(strings.unpairTitle(_name)));
        await tester.tap(find.byType(ModalStage));
        await tester.pump(const Duration(milliseconds: 100));

        expect(opened.finished, isFalse);
        expect(find.byType(NbModal), findsOneWidget);
        await tester.tap(_buttonFinder(strings.cancelButton));
        await _closeOut(tester);
      });
    });

    group('[$code] E289 unpair with reduced motion (RF-112)', () {
      testWidgets('Unpair confirms once and closes with true in the same '
          'frame, with a still stage', (tester) async {
        await _mount(tester, code: code, reduceMotion: true);
        final opened = await _open(tester);

        await tester.tap(_buttonFinder(strings.unpairButton));
        expect(opened.confirms, 1);
        await tester.pump();

        expect(opened.result, isTrue);
        await tester.pump();
        expect(find.byType(NbModal), findsNothing);
        expect(opened.confirms, 1);
      });

      testWidgets('Cancel, Esc and a tap outside answer false', (tester) async {
        await _mount(tester, code: code, reduceMotion: true);
        final dismissals = <Future<void> Function()>[
          () => tester.tap(_buttonFinder(strings.cancelButton)),
          () => tester.sendKeyEvent(LogicalKeyboardKey.escape),
          () => tester.tapAt(_outside),
        ];
        for (final dismiss in dismissals) {
          final opened = await _open(tester);
          await dismiss();
          await tester.pump();
          await tester.pump();
          expect(opened.result, isFalse);
          expect(opened.confirms, 0);
          expect(find.byType(NbModal), findsNothing);
        }
      });

      testWidgets('pumpAndSettle ends, so no animation is left running', (
        tester,
      ) async {
        await _mount(tester, code: code, reduceMotion: true);
        final opened = await _open(tester);
        await tester.pumpAndSettle();

        expect(find.byType(NbModal), findsOneWidget);
        await tester.tap(_buttonFinder(strings.cancelButton));
        await tester.pumpAndSettle();
        expect(opened.result, isFalse);
      });
    });

    group('[$code] E289 unpair from the device list (RF-113)', () {
      testWidgets('the row menu unpairs once at the confirmation, while the '
          'bridge is still breaking', (tester) async {
        tester.view.physicalSize = const Size(1200, 1600);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        final fingerprint = fingerprintOf('BBBB2222');
        final controller = FakeAppController(
          state: NodeState(
            entries: [
              entry(
                fingerprint: fingerprint,
                name: _name,
                paired: true,
                type: DeviceType.mobile,
              ),
            ],
          ),
        );
        await pumpHome(tester, controller, code, settle: false);
        await tester.pump(const Duration(milliseconds: 600));

        await tester.tap(find.byTooltip(strings.moreOptions));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 500));
        await tester.tap(find.text(strings.unpairButton).last);
        await tester.pump();
        await tester.pump(modalTransitionDuration);
        expect(find.byType(NbModal), findsOneWidget);
        expect(
          tester.widget<ModalStage>(find.byType(ModalStage)).input.peer,
          DeviceGlyph.phone,
        );
        expect(controller.calls, isEmpty);

        await tester.tap(
          find.descendant(
            of: find.byType(NbModal),
            matching: _buttonFinder(strings.unpairButton),
          ),
        );
        expect(controller.calls, ['unpair $fingerprint']);
        await tester.pump(const Duration(milliseconds: 700));
        expect(find.byType(NbModal), findsOneWidget);
        expect(controller.calls, ['unpair $fingerprint']);

        await tester.pump(const Duration(milliseconds: 800));
        await _closeOut(tester);
        expect(find.byType(NbModal), findsNothing);
        expect(controller.calls, ['unpair $fingerprint']);
      });
    });

    group('[$code] E289 unpair with large text', () {
      for (final reduceMotion in const [false, true]) {
        testWidgets('at 320 px and 130 % nothing overflows and both buttons '
            'are as tall (reduceMotion: $reduceMotion)', (tester) async {
          await _mount(
            tester,
            code: code,
            reduceMotion: reduceMotion,
            window: const Size(320, 640),
            textScale: 1.3,
          );
          final opened = await _open(tester);
          await tester.pump(const Duration(milliseconds: 600));

          expect(tester.takeException(), isNull);
          expect(
            tester.getSize(_buttonFinder(strings.cancelButton)).height,
            tester.getSize(_buttonFinder(strings.unpairButton)).height,
          );

          await tester.tap(_buttonFinder(strings.cancelButton));
          await _closeOut(tester);
          expect(opened.result, isFalse);
          expect(tester.takeException(), isNull);
        });
      }
    });
  }

  group('E289 with the Windows font, Cancel and Unpair are read whole at '
      '130 % (point 218)', () {
    setUpAll(loadSegoe);

    for (final code in languageCodes) {
      final strings = stringsFor(code);
      for (final window in const [
        Size(760, 520),
        Size(800, 600),
        Size(320, 640),
      ]) {
        testWidgets('[$code] in a ${window.width.toInt()}x'
            '${window.height.toInt()} window', (tester) async {
          await _mount(
            tester,
            code: code,
            reduceMotion: true,
            window: window,
            textScale: 1.3,
          );
          await _open(tester);

          final paragraphs = tester.renderObjectList<RenderParagraph>(
            find.descendant(
              of: find.byType(ModalButton),
              matching: find.byType(RichText),
            ),
          );
          expect(paragraphs, hasLength(2));
          expect(paragraphs.where((p) => p.didExceedMaxLines), isEmpty);
          expect(
            tester.getSize(_buttonFinder(strings.cancelButton)).height,
            tester.getSize(_buttonFinder(strings.unpairButton)).height,
          );
          expect(tester.takeException(), isNull);
        });
      }
    }
  });

  for (final code in languageCodes) {
    final strings = stringsFor(code);
    final title = strings.unpairTitle(_name);
    final labels = [strings.cancelButton, strings.unpairButton];

    List<bool> states(WidgetTester tester) =>
        modalButtonStates(tester, modalWith(title), labels);

    _Opened openWithoutPump() {
      final opened = _Opened();
      unawaited(
        confirmUnpairDevice(
          _homeKey.currentContext!,
          name: _name,
          type: DeviceType.mobile,
          onConfirm: () async {
            opened.confirms++;
          },
        ).then((value) {
          opened.result = value;
          opened.finished = true;
        }),
      );
      return opened;
    }

    group('[$code] H1 unpair closes its own route, never the one on top '
        '(RF-112 and RF-113 of the 003, RF-185 of the 005)', () {
      testWidgets('with a send in progress, the close question opened 300 ms '
          'after confirming is still open with no answer at 2 s, while the '
          'unpair has answered true with a single onConfirm', (tester) async {
        await _mount(tester, code: code);
        final opened = await _open(tester);

        await tester.tap(_buttonFinder(strings.unpairButton));
        expect(opened.confirms, 1);
        await tester.pump(const Duration(milliseconds: 300));

        bool? closeAnswer;
        var closeFinished = false;
        unawaited(
          confirmCloseDuringTransfer(
            _homeKey.currentContext!,
            FakeAppController(state: _sending),
          ).then((value) {
            closeAnswer = value;
            closeFinished = true;
          }),
        );
        await tester.pump();
        final closeRoute = routeOf(
          tester,
          modalWith(strings.closeDuringTransferTitle),
        );
        await tester.pump(const Duration(milliseconds: 1700));

        expect(closeFinished, isFalse);
        expect(closeRoute.isActive, isTrue);
        expect(closeRoute.isCurrent, isTrue);
        expect(closeRoute.animation!.status, AnimationStatus.completed);
        expect(find.text(strings.closeDuringTransferTitle), findsOneWidget);
        expect(opened.result, isTrue);
        expect(opened.confirms, 1);
        expect(find.text(title), findsNothing);
        expect(find.byType(NbModal), findsOneWidget);

        final closeModal = modalWith(strings.closeDuringTransferTitle);
        expect(
          modalButtonStates(tester, closeModal, [
            strings.keepOpenButton,
            strings.closeAndCancelButton,
          ]),
          [true, true],
        );
        await tester.tap(modalButtonIn(closeModal, strings.keepOpenButton));
        await tester.pump();
        expect(closeAnswer, isFalse);
        await _closeOut(tester);
        expect(find.byType(NbModal), findsNothing);
        expect(opened.confirms, 1);
      });

      testWidgets('any modal route pushed on top during the 1.5 s stays open '
          'and untouched, and the unpair leaves from under it', (tester) async {
        await _mount(tester, code: code);
        final opened = await _open(tester);

        await tester.tap(_buttonFinder(strings.unpairButton));
        await tester.pump(const Duration(milliseconds: 300));
        final cover = pushCover(_homeKey.currentContext!);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 1700));

        expect(cover.finished, isFalse);
        expect(cover.taps, 0);
        expect(cover.route.isCurrent, isTrue);
        expect(cover.route.animation!.status, AnimationStatus.completed);
        expect(opened.result, isTrue);
        expect(opened.confirms, 1);
        expect(find.text(title), findsNothing);
        expect(find.byType(NbModal), findsOneWidget);
        expect(tester.takeException(), isNull);

        await tester.tap(coverButton);
        await tester.pump();
        expect(cover.result, coverResult);
        await _closeOut(tester);
        expect(find.byType(NbModal), findsNothing);
      });

      testWidgets('a pairing that PairingHost opens on top during the 1.5 s '
          'keeps its route, and the unpair leaves from under it', (
        tester,
      ) async {
        tester.view.physicalSize = const Size(1200, 1600);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        final fingerprint = fingerprintOf('BBBB2222');
        final row = entry(
          fingerprint: fingerprint,
          name: _name,
          paired: true,
          type: DeviceType.mobile,
        );
        final controller = FakeAppController(state: NodeState(entries: [row]));
        await pumpHome(tester, controller, code, settle: false);
        await tester.pump(const Duration(milliseconds: 600));

        await tester.tap(find.byTooltip(strings.moreOptions));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 500));
        await tester.tap(find.text(strings.unpairButton).last);
        await tester.pump();
        await tester.pump(modalTransitionDuration);
        await tester.tap(modalButtonIn(modalWith(title), strings.unpairButton));
        expect(controller.calls, ['unpair $fingerprint']);
        await tester.pump(const Duration(milliseconds: 300));

        controller.emit(
          NodeState(
            entries: [row],
            pairing: view(
              role: PairingRole.receiver,
              phase: PairingPhase.comparing,
            ),
          ),
        );
        await tester.pump();
        final pairingRoute = routeOf(tester, find.byType(NbModal).last);
        expect(pairingRoute.isCurrent, isTrue);
        await tester.pump(const Duration(milliseconds: 1700));

        expect(find.text(title), findsNothing);
        expect(find.byType(NbModal), findsOneWidget);
        expect(
          identical(routeOf(tester, find.byType(NbModal)), pairingRoute),
          isTrue,
        );
        expect(pairingRoute.isActive, isTrue);
        expect(pairingRoute.isCurrent, isTrue);
        expect(pairingRoute.animation!.status, AnimationStatus.completed);
        expect(controller.calls, ['unpair $fingerprint']);
        final pairingButtons = tester
            .widgetList<ModalButton>(
              find.descendant(
                of: find.byType(NbModal),
                matching: find.byType(ModalButton),
              ),
            )
            .toList();
        expect(pairingButtons, isNotEmpty);
        expect(pairingButtons.every((b) => b.onPressed != null), isTrue);
        expect(tester.takeException(), isNull);
      });

      for (final reduceMotion in const [false, true]) {
        testWidgets('a Cancel that lands in the same frame a route is pushed '
            'on top answers false and leaves that route open '
            '(reduceMotion: $reduceMotion)', (tester) async {
          await _mount(tester, code: code, reduceMotion: reduceMotion);
          final opened = await _open(tester);
          final cancel = modalButtonAction(
            tester,
            modalWith(title),
            strings.cancelButton,
          );

          final unpairRoute = routeOf(tester, modalWith(title));
          final cover = pushCover(_homeKey.currentContext!);
          cancel();
          await tester.pump();
          expect(unpairRoute.isActive, isFalse);
          await tester.pump(modalTransitionDuration);
          await tester.pump(_routeGone);

          expect(opened.result, isFalse);
          expect(opened.confirms, 0);
          expect(cover.finished, isFalse);
          expect(cover.route.isCurrent, isTrue);
          expect(find.text(title), findsNothing);
          expect(find.byType(NbModal), findsOneWidget);
        });
      }

      testWidgets('with reduced motion, an Unpair that lands in the same '
          'frame a route is pushed on top answers true at once and leaves '
          'that route open', (tester) async {
        await _mount(tester, code: code, reduceMotion: true);
        final opened = await _open(tester);
        final unpair = modalButtonAction(
          tester,
          modalWith(title),
          strings.unpairButton,
        );

        final unpairRoute = routeOf(tester, modalWith(title));
        final cover = pushCover(_homeKey.currentContext!);
        unpair();
        await tester.pump();
        expect(unpairRoute.isActive, isFalse);

        expect(opened.result, isTrue);
        expect(opened.confirms, 1);
        expect(cover.finished, isFalse);
        expect(cover.route.isCurrent, isTrue);
        expect(find.text(title), findsNothing);
        expect(find.byType(NbModal), findsOneWidget);
      });
    });

    group('[$code] H2 unpair is off while covered and for 500 ms after '
        '(RF-112 of the 003, point 243)', () {
      for (final reduceMotion in const [false, true]) {
        for (final gap in const [Duration.zero, Duration(milliseconds: 120)]) {
          testWidgets('a double click on the cover over Unpair does not '
              'unpair; both buttons stay off until 500 ms after the cover '
              'leaves (reduceMotion: $reduceMotion, gap: '
              '${gap.inMilliseconds} ms)', (tester) async {
            await _mount(tester, code: code, reduceMotion: reduceMotion);
            final opened = await _open(tester);
            expect(states(tester), [true, true]);

            final cover = pushCover(_homeKey.currentContext!);
            await tester.pump();
            expect(states(tester), [false, false]);
            await tester.pump(modalTransitionDuration);
            await tester.pump(const Duration(seconds: 2));
            expect(states(tester), [false, false]);

            final point = overlapCenter(
              tester,
              modalButtonIn(modalWith(title), strings.unpairButton),
              coverButton,
            );
            await tester.tapAt(point);
            await tester.pump();
            expect(cover.result, coverResult);
            if (gap > Duration.zero) await tester.pump(gap);
            await tester.tapAt(point);
            await tester.pump();

            expect(cover.taps, 1);
            expect(opened.confirms, 0);
            expect(opened.finished, isFalse);
            expect(states(tester), [false, false]);

            await tester.pump(const Duration(milliseconds: 480) - gap);
            expect(states(tester), [false, false]);
            await tester.tapAt(point);
            await tester.pump();
            expect(opened.confirms, 0);

            await tester.pump(const Duration(milliseconds: 40));
            expect(states(tester), [true, true]);
            await tester.tapAt(point);
            await tester.pump();
            expect(opened.confirms, 1);
            await tester.pump(_breakTime);
            await _closeOut(tester);
            expect(opened.result, isTrue);
            expect(find.byType(NbModal), findsNothing);
          });
        }
      }

      testWidgets('a cover taken away with removeRoute also counts 500 ms '
          'before the buttons come back', (tester) async {
        await _mount(tester, code: code);
        final opened = await _open(tester);
        final cover = pushCover(_homeKey.currentContext!);
        await tester.pump();
        await tester.pump(modalTransitionDuration);

        cover.route.navigator!.removeRoute(cover.route);
        await tester.pump();
        expect(states(tester), [false, false]);
        await tester.pump(const Duration(milliseconds: 499));
        expect(states(tester), [false, false]);
        await tester.pump(const Duration(milliseconds: 1));
        expect(states(tester), [true, true]);
        await tester.tap(_buttonFinder(strings.cancelButton));
        await _closeOut(tester);
        expect(opened.result, isFalse);
      });
    });

    group('[$code] coverOnly: unpair has no delay and ignores the lifecycle '
        '(points 159 and 243)', () {
      testWidgets('both buttons are on in the very first frame', (
        tester,
      ) async {
        await _mount(tester, code: code);
        final opened = openWithoutPump();
        await tester.pump();

        expect(states(tester), [true, true]);
        await tester.pump(modalTransitionDuration);
        await tester.tap(_buttonFinder(strings.cancelButton));
        await _closeOut(tester);
        expect(opened.result, isFalse);
      });

      for (final target in const [
        AppLifecycleState.inactive,
        AppLifecycleState.hidden,
        AppLifecycleState.paused,
      ]) {
        testWidgets('going to ${target.name} and back keeps both buttons on, '
            'and Unpair works at once', (tester) async {
          resumeOnTearDown(tester);
          await stepLifecycle(tester, AppLifecycleState.resumed);
          await _mount(tester, code: code);
          final opened = await _open(tester);

          for (final state in lifecyclePath(
            AppLifecycleState.resumed,
            target,
          )) {
            await stepLifecycle(tester, state);
            expect(states(tester), [true, true], reason: state.name);
          }
          await tester.pump(const Duration(seconds: 1));
          expect(states(tester), [true, true]);
          for (final state in lifecyclePath(
            target,
            AppLifecycleState.resumed,
          )) {
            await stepLifecycle(tester, state);
            expect(states(tester), [true, true], reason: state.name);
          }
          await tester.tap(_buttonFinder(strings.unpairButton));
          expect(opened.confirms, 1);
          await tester.pump(_breakTime);
          await _closeOut(tester);
          expect(opened.result, isTrue);
        });
      }

      testWidgets('opened with the app inactive, both buttons are on in the '
          'first frame', (tester) async {
        resumeOnTearDown(tester);
        await _mount(tester, code: code);
        await goToLifecycle(tester, AppLifecycleState.inactive);
        final opened = openWithoutPump();
        await tester.pump();

        expect(states(tester), [true, true]);
        await tester.pump(modalTransitionDuration);
        await tester.tap(_buttonFinder(strings.cancelButton));
        await _closeOut(tester);
        expect(opened.result, isFalse);
      });
    });
  }

  group('E289 the touched files: no literal text, no literal color and no '
      'comments', () {
    const files = [
      'unpair_modal.dart',
      'device_list.dart',
      'network_prompt_dialog.dart',
      'exit_flow.dart',
    ];
    final literalColor = RegExp(
      r'Color\(\s*0x|Color\.fromARGB|Color\.fromRGBO|\bColors\.(?!transparent\b)',
    );
    final literalLabel = RegExp(
      r'''(Text\(|label:|title:|text:|semanticsLabel:|tooltip:)\s*['"]''',
    );
    final quoted = RegExp(
      r"'(?:\\.|[^'\\])*'"
      '|'
      r'"(?:\\.|[^"\\])*"',
    );

    String read(String name) => File(
      'lib${Platform.pathSeparator}src${Platform.pathSeparator}ui'
      '${Platform.pathSeparator}$name',
    ).readAsStringSync();

    for (final name in files) {
      test(name, () {
        final source = read(name);
        expect(literalColor.hasMatch(source), isFalse, reason: name);
        expect(literalLabel.hasMatch(source), isFalse, reason: name);
        final commented = [
          for (final line in source.split('\n'))
            if (line.replaceAll(quoted, '').contains('//')) line.trim(),
        ];
        expect(commented, isEmpty, reason: name);
      });
    }

    test('the three modals take their texts from AppStrings', () {
      for (final name in const [
        'unpair_modal.dart',
        'network_prompt_dialog.dart',
        'exit_flow.dart',
      ]) {
        expect(read(name), contains('AppStringsDelegate.of('), reason: name);
      }
    });
  });
}
