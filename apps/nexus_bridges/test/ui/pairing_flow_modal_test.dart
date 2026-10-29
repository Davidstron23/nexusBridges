import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nexus_bridges/src/l10n/app_strings.dart';
import 'package:nexus_bridges/src/ui/icons/device_disc.dart';
import 'package:nexus_bridges/src/ui/icons/glyphs.dart';
import 'package:nexus_bridges/src/ui/modal/code_boxes.dart';
import 'package:nexus_bridges/src/ui/modal/modal_button.dart';
import 'package:nexus_bridges/src/ui/modal/modal_frame.dart';
import 'package:nexus_bridges/src/ui/modal/stage.dart';
import 'package:nexus_bridges/src/ui/modal/stage_kit.dart';
import 'package:nexus_bridges/src/ui/pairing_dialogs.dart';
import 'package:nexus_bridges/src/ui/pairing_questions.dart';
import 'package:nexus_bridges/src/ui/theme/app_theme.dart';
import 'package:nexus_bridges_core/nexus_bridges_core.dart';

import 'fake_app_controller.dart';
import 'pairing_fixtures.dart';

const String _otherName = 'Torre';
final String _otherFingerprint = fingerprintOf('7777BBBB');
const String _oldShort = '9999AAAA';
final String _oldFingerprint = fingerprintOf(_oldShort);
const String _oldName = 'Port\u00E1til de Ana \u00B7 9999AAAA';

final MineQuestion _mine = MineQuestion(
  fingerprint: peerFingerprint,
  deviceName: peerName,
);

final MineQuestion _otherMine = MineQuestion(
  fingerprint: _otherFingerprint,
  deviceName: _otherName,
);

final ReplaceQuestion _replace = ReplaceQuestion(
  fingerprint: peerFingerprint,
  deviceName: peerName,
  oldFingerprint: _oldFingerprint,
  oldName: _oldName,
);

final class _FlowController extends FakeAppController {
  _FlowController(NodeState state) : super(state: state);

  NodeState? afterDismiss;
  NodeState? afterReplace;
  NodeState? afterMine;

  @override
  void dismissPairing() {
    super.dismissPairing();
    final next = afterDismiss;
    if (next != null) emit(next);
  }

  @override
  Future<void> answerReplace(String fingerprint, {required bool replace}) {
    final done = super.answerReplace(fingerprint, replace: replace);
    final next = afterReplace;
    if (next != null) emit(next);
    return done;
  }

  @override
  Future<void> answerMine(String fingerprint, {required bool mine}) {
    final done = super.answerMine(fingerprint, mine: mine);
    final next = afterMine;
    if (next != null) emit(next);
    return done;
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

Future<_FlowController> _mount(
  WidgetTester tester,
  String code,
  NodeState state, {
  bool reduceMotion = false,
  double textScale = 1,
  Size window = const Size(800, 600),
  ValueNotifier<bool>? showHost,
}) async {
  tester.view.physicalSize = window;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final controller = _FlowController(state);
  final visible = showHost ?? ValueNotifier<bool>(true);
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
      themeMode: ThemeMode.dark,
      themeAnimationDuration: Duration.zero,
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context).copyWith(
          disableAnimations: reduceMotion,
          textScaler: TextScaler.linear(textScale),
        ),
        child: child!,
      ),
      home: ValueListenableBuilder<bool>(
        valueListenable: visible,
        builder: (context, show, _) => show
            ? PairingHost(
                controller: controller,
                child: const Scaffold(body: SizedBox.expand()),
              )
            : const Scaffold(body: SizedBox.expand()),
      ),
    ),
  );
  await tester.pump();
  return controller;
}

Future<void> _ms(WidgetTester tester, int milliseconds) =>
    tester.pump(Duration(milliseconds: milliseconds));

Future<void> _openArmed(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(dialogActivationDelay);
}

Finder get _modal => find.byType(NbModal);

bool _isLeaving(Element element) {
  var leaving = false;
  element.visitAncestorElements((ancestor) {
    final widget = ancestor.widget;
    if (widget is ModalViewSwitcher) return false;
    if (widget is IgnorePointer && widget.ignoring) {
      leaving = true;
      return false;
    }
    return true;
  });
  return leaving;
}

List<Element> _live(Finder finder) =>
    finder.evaluate().where((element) => !_isLeaving(element)).toList();

List<Element> _leavingOf(Finder finder) =>
    finder.evaluate().where(_isLeaving).toList();

Finder _inModal(Finder matching) =>
    find.descendant(of: _modal, matching: matching);

Finder _element(Element element) =>
    find.byElementPredicate((candidate) => candidate == element);

T _liveOne<T extends Widget>() {
  final elements = _live(_inModal(find.byType(T)));
  expect(elements, hasLength(1), reason: 'live $T');
  return elements.single.widget as T;
}

ModalView _view() => _liveOne<ModalView>();

ModalStage _stage() => _liveOne<ModalStage>();

List<(String, ModalButtonKind, Glyph?, bool)> _specs(List<Widget> buttons) => [
  for (final button in buttons.cast<ModalButton>())
    (button.label, button.kind, button.glyph, button.inPair),
];

List<ModalButton> _liveButtons() => [
  for (final element in _live(_inModal(find.byType(ModalButton))))
    element.widget as ModalButton,
];

List<ChoiceTile> _liveTiles() => [
  for (final element in _live(_inModal(find.byType(ChoiceTile))))
    element.widget as ChoiceTile,
];

List<bool> _liveEnabled() => [
  for (final button in _liveButtons()) button.onPressed != null,
  for (final tile in _liveTiles()) tile.onPressed != null,
];

Future<void> _tapLive(WidgetTester tester, String label) async {
  final elements = _live(_inModal(find.text(label)));
  expect(elements, hasLength(1), reason: 'live "$label"');
  await tester.tapAt(tester.getCenter(_element(elements.single)));
  await tester.pump();
}

Future<void> _escape(WidgetTester tester) async {
  await tester.sendKeyEvent(LogicalKeyboardKey.escape);
  await tester.pump();
}

Future<void> _tapOutside(WidgetTester tester) async {
  await tester.tapAt(const Offset(5, 5));
  await tester.pump();
}

ModalRoute<dynamic> _routeOf(WidgetTester tester) =>
    ModalRoute.of(tester.element(_modal.last))!;

String _outcomeText(AppStrings s, PairingOutcome? outcome, String name) {
  return switch (outcome) {
    PairingOutcome.paired => s.outcomePaired(name),
    PairingOutcome.rejected => s.outcomeRejected(name),
    PairingOutcome.busy => s.outcomeBusy(name),
    PairingOutcome.paused => s.outcomePaused(name),
    PairingOutcome.cancelledByPeer => s.outcomeCancelledByPeer(name),
    PairingOutcome.expired => s.outcomeExpired,
    PairingOutcome.lost => s.outcomeLost(name),
    PairingOutcome.networkChanged => s.outcomeNetworkChanged,
    PairingOutcome.failed || null => s.outcomeFailed(name),
    PairingOutcome.notSaved => s.outcomeNotSaved,
  };
}

EyebrowTone _expectedTone(PairingOutcome? outcome) {
  return switch (outcome) {
    PairingOutcome.paired => EyebrowTone.ok,
    PairingOutcome.rejected ||
    PairingOutcome.cancelledByPeer ||
    PairingOutcome.failed ||
    PairingOutcome.notSaved ||
    null => EyebrowTone.bad,
    PairingOutcome.expired || PairingOutcome.lost => EyebrowTone.warn,
    PairingOutcome.paused => EyebrowTone.ice,
    PairingOutcome.busy || PairingOutcome.networkChanged => EyebrowTone.neutral,
  };
}

String? _focusedLabel() {
  final context = FocusManager.instance.primaryFocus?.context;
  if (context == null) return null;
  String? label;
  context.visitAncestorElements((ancestor) {
    final widget = ancestor.widget;
    if (widget is ModalButton) {
      label = widget.label;
      return false;
    }
    if (widget is ChoiceTile) {
      label = widget.title;
      return false;
    }
    return true;
  });
  return label;
}

Future<void> _tabTo(WidgetTester tester, String label) async {
  for (var i = 0; i < 8 && _focusedLabel() != label; i++) {
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pump();
  }
  expect(_focusedLabel(), label);
}

Rect _frameRect(WidgetTester tester) =>
    tester.getRect(_inModal(find.byType(DecoratedBox)).first);

void _expectWhole(WidgetTester tester, Element text, String reason) {
  final paragraph = tester.renderObject<RenderParagraph>(
    find.descendant(of: _element(text), matching: find.byType(RichText)),
  );
  expect(paragraph.didExceedMaxLines, isFalse, reason: reason);
}

void main() {
  setUpAll(_loadSegoe);

  for (final code in languageCodes) {
    final strings = stringsFor(code);
    final receiverComparing = view(
      role: PairingRole.receiver,
      phase: PairingPhase.comparing,
    );

    group('[$code] E287 views of each phase (RF-72, RF-73, RF-83, RF-84, '
        'RF-86, RF-90, RF-248)', () {
      testWidgets('connecting: scene, title, lead and a single neutral '
          'Cancel that calls cancelPairing', (tester) async {
        final controller = await _mount(
          tester,
          code,
          pairingState(
            pairing: view(
              role: PairingRole.initiator,
              phase: PairingPhase.connecting,
            ),
          ),
        );
        await _openArmed(tester);

        expect(_modal, findsOneWidget);
        final modalView = _view();
        expect(modalView.layout, ModalViewLayout.standard);
        expect(modalView.title, strings.pairingWithTitle(peerName));
        expect(modalView.eyebrow, isNull);
        expect(_stage().scene, StageScene.connecting);
        expect(
          [for (final lead in modalView.body.whereType<ModalLead>()) lead.text],
          [strings.connectingTo(peerName)],
        );
        expect(modalView.pair, isEmpty);
        expect(_specs(modalView.actions), [
          (strings.cancelButton, ModalButtonKind.neutral, null, false),
        ]);
        expect(_inModal(find.byType(CodeBoxes)), findsNothing);

        await _tapLive(tester, strings.cancelButton);
        expect(controller.calls, ['cancelPairing']);
      });

      testWidgets('comparing as initiator: centered, code, the pair and a '
          'neutral Cancel, each with its call', (tester) async {
        final controller = await _mount(
          tester,
          code,
          pairingState(
            pairing: view(
              role: PairingRole.initiator,
              phase: PairingPhase.comparing,
            ),
          ),
        );
        await _openArmed(tester);

        final modalView = _view();
        expect(modalView.layout, ModalViewLayout.centered);
        expect(modalView.title, strings.pairingWithTitle(peerName));
        expect(_stage().scene, StageScene.comparing);
        expect(find.text(strings.fingerprintLine(peerShort)), findsNothing);
        expect(
          [for (final lead in modalView.body.whereType<ModalLead>()) lead.text],
          [strings.compareCode(peerName)],
        );
        final boxes = _liveOne<CodeBoxes>();
        expect((boxes.code, boxes.confirmed), (rawCode, false));
        expect(codeIn(tester, _modal), formattedCode);
        expect(_specs(modalView.pair), [
          (
            strings.doesNotMatchButton,
            ModalButtonKind.negative,
            Glyphs.cross,
            true,
          ),
          (strings.matchesButton, ModalButtonKind.primary, Glyphs.tick, true),
        ]);
        expect(_specs(modalView.actions), [
          (strings.cancelButton, ModalButtonKind.neutral, null, false),
        ]);

        await _tapLive(tester, strings.doesNotMatchButton);
        await _tapLive(tester, strings.matchesButton);
        await _tapLive(tester, strings.cancelButton);
        expect(controller.calls, [
          'answerCode false',
          'answerCode true',
          'cancelPairing',
        ]);
      });

      for (final alreadyPaired in [false, true]) {
        testWidgets(
          'comparing as receiver${alreadyPaired ? ' already '
                    'paired' : ''}: fingerprint line with the short fingerprint '
          'in bold, code, the pair and '
          '${alreadyPaired ? 'the note and nothing else' : 'Ignore'}',
          (tester) async {
            final controller = await _mount(
              tester,
              code,
              pairingState(
                pairing: view(
                  role: PairingRole.receiver,
                  phase: PairingPhase.comparing,
                  alreadyPaired: alreadyPaired,
                ),
              ),
            );
            await _openArmed(tester);

            final modalView = _view();
            expect(modalView.layout, ModalViewLayout.centered);
            expect(modalView.title, strings.pairingRequestTitle(peerName));
            expect(_stage().scene, StageScene.comparing);
            final line = tester.widget<Text>(
              find.text(strings.fingerprintLine(peerShort)),
            );
            final bold = <String>[];
            line.textSpan!.visitChildren((span) {
              if (span is TextSpan &&
                  span.style?.fontWeight == FontWeight.w600 &&
                  span.text != null) {
                bold.add(span.text!);
              }
              return true;
            });
            expect(bold, [peerShort]);
            expect(find.textContaining(peerFingerprint), findsNothing);
            expect(codeIn(tester, _modal), formattedCode);
            expect(
              _inModal(find.byType(ModalNote)),
              alreadyPaired ? findsOneWidget : findsNothing,
            );
            if (alreadyPaired) {
              expect(_liveOne<ModalNote>().text, strings.alreadyPairedNote);
            }
            expect(_specs(modalView.pair), [
              (
                strings.doesNotMatchButton,
                ModalButtonKind.negative,
                Glyphs.cross,
                true,
              ),
              (
                strings.matchesButton,
                ModalButtonKind.primary,
                Glyphs.tick,
                true,
              ),
            ]);
            expect(
              _specs(modalView.actions),
              alreadyPaired
                  ? isEmpty
                  : [
                      (
                        strings.ignoreDeviceButton,
                        ModalButtonKind.negative,
                        null,
                        false,
                      ),
                    ],
            );
            expect(find.text(strings.cancelButton), findsNothing);

            await _tapLive(tester, strings.doesNotMatchButton);
            await _tapLive(tester, strings.matchesButton);
            if (!alreadyPaired) {
              await _tapLive(tester, strings.ignoreDeviceButton);
            }
            expect(controller.calls, [
              'answerRequest mismatch',
              'answerRequest matches',
              if (!alreadyPaired) 'answerRequest ignore',
            ]);
          },
        );
      }

      for (final (role, call) in [
        (PairingRole.initiator, 'cancelPairing'),
        (PairingRole.receiver, 'cancelRequest'),
      ]) {
        testWidgets('waitingPeer as ${role.name}: confirmed code, the wait '
            'text and a single neutral Cancel that calls $call', (
          tester,
        ) async {
          final controller = await _mount(
            tester,
            code,
            pairingState(
              pairing: view(role: role, phase: PairingPhase.waitingPeer),
            ),
          );
          await _openArmed(tester);

          final modalView = _view();
          expect(modalView.layout, ModalViewLayout.standard);
          expect(
            modalView.title,
            role == PairingRole.initiator
                ? strings.pairingWithTitle(peerName)
                : strings.pairingRequestTitle(peerName),
          );
          expect(_stage().scene, StageScene.waiting);
          final boxes = _liveOne<CodeBoxes>();
          expect((boxes.code, boxes.confirmed), (rawCode, true));
          expect(codeIn(tester, _modal), formattedCode);
          expect(_liveOne<ModalLead>().text, switch (role) {
            PairingRole.initiator => strings.waitingForPeer(peerName),
            PairingRole.receiver => strings.receiverWaiting(peerName),
          });
          expect(modalView.pair, isEmpty);
          expect(_specs(modalView.actions), [
            (strings.cancelButton, ModalButtonKind.neutral, null, false),
          ]);
          for (final absent in [
            strings.matchesButton,
            strings.doesNotMatchButton,
            strings.ignoreDeviceButton,
          ]) {
            expect(find.text(absent), findsNothing);
          }

          await _escape(tester);
          await _tapOutside(tester);
          await _ms(tester, 400);
          expect(_modal, findsOneWidget);
          expect(controller.calls, isEmpty);

          await _tapLive(tester, strings.cancelButton);
          expect(controller.calls, [call]);
        });
      }

      for (final role in PairingRole.values) {
        for (final outcome in [...PairingOutcome.values, null]) {
          testWidgets('finished ${role.name} ${outcome?.name ?? 'no outcome'}: '
              'eyebrow with its tone, scene, outcome title and a primary '
              'Close', (tester) async {
            final controller = await _mount(
              tester,
              code,
              pairingState(
                pairing: view(
                  role: role,
                  phase: PairingPhase.finished,
                  outcome: outcome,
                ),
              ),
              reduceMotion: true,
            );
            await _openArmed(tester);

            final modalView = _view();
            expect(modalView.layout, ModalViewLayout.result);
            expect(modalView.title, _outcomeText(strings, outcome, peerName));
            expect(find.text(strings.pairingResultTitle), findsNothing);
            final eyebrow = modalView.eyebrow!;
            expect(eyebrow.text, strings.pairingEyebrow(outcome));
            expect(eyebrow.tone, _expectedTone(outcome));
            expect(
              find.text(strings.pairingEyebrow(outcome).toUpperCase()),
              findsOneWidget,
            );
            expect(_stage().scene, stageForOutcome(outcome));
            expect(modalView.body, isEmpty);
            expect(modalView.pair, isEmpty);
            expect(_specs(modalView.actions), [
              (strings.closeButton, ModalButtonKind.primary, null, false),
            ]);
            expect(_inModal(find.byType(CodeBoxes)), findsNothing);

            await _escape(tester);
            await _tapOutside(tester);
            expect(controller.calls, isEmpty);

            await _tapLive(tester, strings.closeButton);
            expect(controller.calls, ['dismissPairing']);
          });
        }
      }

      for (final phase in [PairingPhase.comparing, PairingPhase.waitingPeer]) {
        for (final role in PairingRole.values) {
          testWidgets('the namesake alert shows in ${role.name} '
              '${phase.name}', (tester) async {
            await _mount(
              tester,
              code,
              pairingState(
                pairing: view(role: role, phase: phase),
                namesake: namesakeName,
              ),
              reduceMotion: true,
            );
            await _openArmed(tester);
            expect(
              _liveOne<ModalAlert>().text,
              strings.namesakeWarning(namesakeName),
            );
          });
        }
      }

      for (final pairing in [
        view(role: PairingRole.initiator, phase: PairingPhase.connecting),
        view(
          role: PairingRole.receiver,
          phase: PairingPhase.finished,
          outcome: PairingOutcome.paired,
        ),
      ]) {
        testWidgets('no namesake alert in ${pairing.role.name} '
            '${pairing.phase.name}', (tester) async {
          await _mount(
            tester,
            code,
            pairingState(pairing: pairing, namesake: namesakeName),
            reduceMotion: true,
          );
          await _openArmed(tester);
          expect(_inModal(find.byType(ModalAlert)), findsNothing);
          expect(
            find.text(strings.namesakeWarning(namesakeName)),
            findsNothing,
          );
        });
      }
    });

    group('[$code] E287 the peer glyph comes from its DeviceEntry', () {
      final views = {
        'connecting': view(
          role: PairingRole.initiator,
          phase: PairingPhase.connecting,
        ),
        'comparing': receiverComparing,
        'waiting': view(
          role: PairingRole.receiver,
          phase: PairingPhase.waitingPeer,
        ),
        'result': view(
          role: PairingRole.initiator,
          phase: PairingPhase.finished,
          outcome: PairingOutcome.paired,
        ),
      };
      final entries = {
        'a visible mobile': (
          [
            entry(
              fingerprint: peerFingerprint,
              name: peerName,
              type: DeviceType.mobile,
            ),
          ],
          DeviceGlyph.phone,
        ),
        'a known paired mobile': (
          [
            entry(
              fingerprint: peerFingerprint,
              name: peerName,
              type: DeviceType.mobile,
              paired: true,
              mine: true,
            ),
          ],
          DeviceGlyph.phone,
        ),
        'a visible desktop': (
          [entry(fingerprint: peerFingerprint, name: peerName)],
          DeviceGlyph.pc,
        ),
        'an unknown peer': (
          [
            entry(
              fingerprint: _otherFingerprint,
              name: _otherName,
              type: DeviceType.mobile,
            ),
          ],
          DeviceGlyph.pc,
        ),
        'no entries': (const <DeviceEntry>[], DeviceGlyph.pc),
      };
      for (final MapEntry(key: phase, value: pairing) in views.entries) {
        for (final MapEntry(key: name, value: (list, glyph))
            in entries.entries) {
          testWidgets('$phase with $name paints ${glyph.name}', (tester) async {
            await _mount(
              tester,
              code,
              NodeState(pairing: pairing, entries: list),
              reduceMotion: true,
            );
            await _openArmed(tester);
            expect(_stage().input.peer, glyph);
          });
        }
      }
    });

    group('[$code] E287 one window for the whole pairing (RF-98, R86)', () {
      testWidgets('connecting, comparing, waiting, paired, replace? and is it '
          'yours? share one NbModal and one route; none at the end', (
        tester,
      ) async {
        final controller = await _mount(
          tester,
          code,
          pairingState(
            pairing: view(
              role: PairingRole.initiator,
              phase: PairingPhase.connecting,
            ),
          ),
        );
        await _openArmed(tester);
        final route = _routeOf(tester);

        Future<void> step(int milliseconds) async {
          for (var t = 0; t < milliseconds; t += 40) {
            await _ms(tester, 40);
            expect(_modal, findsOneWidget);
            expect(identical(_routeOf(tester), route), isTrue);
          }
        }

        for (final phase in [
          PairingPhase.comparing,
          PairingPhase.waitingPeer,
        ]) {
          controller.emit(
            pairingState(
              pairing: view(role: PairingRole.initiator, phase: phase),
            ),
          );
          await step(600);
        }
        controller.emit(
          pairingState(
            pairing: view(
              role: PairingRole.initiator,
              phase: PairingPhase.finished,
              outcome: PairingOutcome.paired,
            ),
            questions: [_replace, _mine],
          ),
        );
        await step(600);
        expect(_view().title, strings.outcomePaired(peerName));
        expect(find.text(strings.replaceTitle(_oldName)), findsNothing);

        controller.afterDismiss = pairingState(questions: [_replace, _mine]);
        await _tapLive(tester, strings.closeButton);
        await step(600);
        expect(_view().title, strings.replaceTitle(_oldName));
        expect(_live(_inModal(find.byType(PairingQuestionView))), hasLength(1));

        controller.afterReplace = pairingState(questions: [_mine]);
        await _tapLive(tester, strings.keepBothButton);
        await step(600);
        expect(_view().title, strings.mineTitle(peerName));

        controller.afterMine = pairingState();
        await _tapLive(tester, strings.mineYesButton);
        await step(1720);
        expect(_view().title, strings.mineTitle(peerName));

        await _ms(tester, 60);
        await _ms(tester, modalTransitionDuration.inMilliseconds);
        await _ms(tester, 40);
        expect(_modal, findsNothing);
        expect(controller.calls, [
          'dismissPairing',
          'answerReplace $peerFingerprint false',
          'answerMine $peerFingerprint true',
        ]);
        expect(tester.takeException(), isNull);
      });

      testWidgets('the same journey with reduced motion changes view in the '
          'same frame and closes in the same frame as the answer', (
        tester,
      ) async {
        final controller = await _mount(
          tester,
          code,
          pairingState(
            pairing: view(
              role: PairingRole.receiver,
              phase: PairingPhase.finished,
              outcome: PairingOutcome.paired,
            ),
            questions: [_replace, _mine],
          ),
          reduceMotion: true,
        );
        await _openArmed(tester);
        final route = _routeOf(tester);

        controller.afterDismiss = pairingState(questions: [_replace, _mine]);
        await _tapLive(tester, strings.closeButton);
        expect(_view().title, strings.replaceTitle(_oldName));
        expect(_inModal(find.byType(ModalView)), findsOneWidget);
        expect(identical(_routeOf(tester), route), isTrue);

        await _ms(tester, 500);
        controller.afterReplace = pairingState(questions: [_mine]);
        await _tapLive(tester, strings.replaceButton);
        expect(_view().title, strings.mineTitle(peerName));
        expect(identical(_routeOf(tester), route), isTrue);

        await _ms(tester, 500);
        controller.afterMine = pairingState();
        await _tapLive(tester, strings.mineNoButton);
        await tester.pump();
        expect(_modal, findsNothing);
        expect(controller.calls, [
          'dismissPairing',
          'answerReplace $peerFingerprint true',
          'answerMine $peerFingerprint false',
        ]);
      });
    });

    group('[$code] E287 arming in motion (RF-83, points 159 and 164)', () {
      for (final role in PairingRole.values) {
        testWidgets('every change of phase of the ${role.name} gives a new '
            'view that is off until 500 ms and ignores taps before', (
          tester,
        ) async {
          final initiator = role == PairingRole.initiator;
          final first = initiator
              ? view(role: role, phase: PairingPhase.connecting)
              : view(role: role, phase: PairingPhase.comparing);
          final controller = await _mount(
            tester,
            code,
            pairingState(pairing: first),
          );
          await tester.pump();
          expect(_liveEnabled(), everyElement(isFalse));
          await _ms(tester, 499);
          expect(_liveEnabled(), everyElement(isFalse));
          await _ms(tester, 1);
          expect(_liveEnabled(), everyElement(isTrue));

          final steps = [
            if (initiator)
              (
                view(role: role, phase: PairingPhase.comparing),
                strings.matchesButton,
              ),
            (
              view(role: role, phase: PairingPhase.waitingPeer),
              strings.cancelButton,
            ),
            (
              view(
                role: role,
                phase: PairingPhase.finished,
                outcome: PairingOutcome.cancelledByPeer,
              ),
              strings.closeButton,
            ),
          ];
          for (final (next, label) in steps) {
            controller.emit(pairingState(pairing: next));
            await tester.pump();
            expect(_liveEnabled(), isNotEmpty);
            expect(_liveEnabled(), everyElement(isFalse));
            await _ms(tester, 250);
            await _tapLive(tester, label);
            await _ms(tester, 249);
            expect(_liveEnabled(), everyElement(isFalse));
            await _tapLive(tester, label);
            expect(controller.calls, isEmpty);
            await _ms(tester, 1);
            expect(_liveEnabled(), everyElement(isTrue));
          }
          expect(_modal, findsOneWidget);
        });
      }

      for (final (role, answer, call) in [
        (PairingRole.initiator, 'answerCode true', 'cancelPairing'),
        (PairingRole.receiver, 'answerRequest matches', 'cancelRequest'),
      ]) {
        testWidgets('a double click on It matches of the ${role.name} does not '
            'land on Cancel nor on the leaving It matches', (tester) async {
          final controller = await _mount(
            tester,
            code,
            pairingState(
              pairing: view(role: role, phase: PairingPhase.comparing),
            ),
          );
          await _openArmed(tester);
          final spot = tester.getCenter(
            _element(_live(_inModal(find.text(strings.matchesButton))).single),
          );

          await tester.tapAt(spot);
          await tester.pump();
          expect(controller.calls, [answer]);
          controller.emit(
            pairingState(
              pairing: view(role: role, phase: PairingPhase.waitingPeer),
            ),
          );
          await tester.pump();
          await tester.tapAt(spot);
          await tester.pump();
          await _ms(tester, 60);
          await tester.tapAt(spot);
          await tester.pump();
          final cancel = tester.getCenter(
            _element(_live(_inModal(find.text(strings.cancelButton))).single),
          );
          await tester.tapAt(cancel);
          await tester.pump();
          await _ms(tester, 300);
          await tester.tapAt(spot);
          await tester.tapAt(cancel);
          await tester.pump();
          expect(controller.calls, [answer]);

          await _ms(tester, 200);
          await tester.tapAt(cancel);
          await tester.pump();
          expect(controller.calls, [answer, call]);
        });
      }
    });

    group('[$code] E287 (h) the leaving view paints what was seen', () {
      testWidgets('from comparing to waitingPeer the leaving view keeps It '
          'matches and the unconfirmed code for 180 ms and takes no taps', (
        tester,
      ) async {
        final controller = await _mount(
          tester,
          code,
          pairingState(pairing: receiverComparing),
        );
        await _openArmed(tester);
        final matches = tester.getCenter(find.text(strings.matchesButton));
        final mismatch = tester.getCenter(
          find.text(strings.doesNotMatchButton),
        );

        controller.emit(
          pairingState(
            pairing: view(
              role: PairingRole.receiver,
              phase: PairingPhase.waitingPeer,
            ),
          ),
        );
        await tester.pump();
        await _ms(tester, 60);

        expect(_modal, findsOneWidget);
        expect(_leavingOf(_inModal(find.byType(ModalView))), hasLength(1));
        expect(
          _leavingOf(_inModal(find.text(strings.matchesButton))),
          hasLength(1),
        );
        expect(_live(_inModal(find.text(strings.matchesButton))), isEmpty);
        final leavingBoxes = _leavingOf(_inModal(find.byType(CodeBoxes)));
        expect(leavingBoxes, hasLength(1));
        expect((leavingBoxes.single.widget as CodeBoxes).confirmed, isFalse);
        expect(_liveOne<CodeBoxes>().confirmed, isTrue);
        final leavingStages = _leavingOf(_inModal(find.byType(ModalStage)));
        expect(
          (leavingStages.single.widget as ModalStage).scene,
          StageScene.comparing,
        );
        expect(_stage().scene, StageScene.waiting);

        await tester.tapAt(matches);
        await tester.tapAt(mismatch);
        await tester.pump();
        await _ms(tester, 60);
        await tester.tapAt(matches);
        await tester.pump();
        expect(controller.calls, isEmpty);

        await _ms(tester, 120);
        expect(_leavingOf(_inModal(find.byType(ModalView))), isEmpty);
        expect(find.text(strings.matchesButton), findsNothing);
      });

      testWidgets('a press on It matches that is held while the view changes '
          'to another request is not delivered on release', (tester) async {
        final controller = await _mount(
          tester,
          code,
          pairingState(pairing: receiverComparing),
        );
        await _openArmed(tester);

        final gesture = await tester.startGesture(
          tester.getCenter(find.text(strings.matchesButton)),
        );
        await tester.pump();
        controller.emit(
          pairingState(
            pairing: view(
              role: PairingRole.receiver,
              phase: PairingPhase.comparing,
              fingerprint: _otherFingerprint,
              name: _otherName,
            ),
          ),
        );
        await tester.pump();
        await _ms(tester, 60);
        await gesture.up();
        await tester.pump();
        await _ms(tester, 600);

        expect(_view().title, strings.pairingRequestTitle(_otherName));
        expect(controller.calls, isEmpty);
      });

      testWidgets('closing a result with no questions keeps painting the '
          'result while the route leaves', (tester) async {
        final controller = await _mount(
          tester,
          code,
          pairingState(
            pairing: view(
              role: PairingRole.initiator,
              phase: PairingPhase.finished,
              outcome: PairingOutcome.paired,
            ),
          ),
        );
        await _ms(tester, 1000);

        controller.emit(pairingState());
        await tester.pump();
        await _ms(tester, 100);

        expect(_modal, findsOneWidget);
        expect(find.text(strings.outcomePaired(peerName)), findsOneWidget);
        expect(
          find.text(
            strings.pairingEyebrow(PairingOutcome.paired).toUpperCase(),
          ),
          findsOneWidget,
        );
        expect(_stage().scene, StageScene.paired);

        await _ms(tester, 300);
        expect(_modal, findsNothing);
      });
    });

    group(
      '[$code] E287 (i) a question that arrives while the route leaves',
      () {
        testWidgets(
          'opens a second route on top; the end of the first does not '
          'close it and It is mine answers once',
          (tester) async {
            final controller = await _mount(
              tester,
              code,
              pairingState(
                pairing: view(
                  role: PairingRole.initiator,
                  phase: PairingPhase.finished,
                  outcome: PairingOutcome.paired,
                ),
              ),
            );
            await _openArmed(tester);

            controller.emit(pairingState());
            await tester.pump();
            await _ms(tester, 100);
            expect(_modal, findsOneWidget);

            controller.emit(pairingState(questions: [_mine]));
            await tester.pump();
            expect(_modal, findsNWidgets(2));
            await _ms(tester, 100);
            expect(_modal, findsNWidgets(2));

            await _ms(tester, 150);
            expect(_modal, findsOneWidget);
            expect(find.text(strings.mineTitle(peerName)), findsOneWidget);
            expect(find.text(strings.outcomePaired(peerName)), findsNothing);

            await _ms(tester, 300);
            controller.afterMine = pairingState();
            await _tapLive(tester, strings.mineYesButton);
            await _tapLive(tester, strings.mineYesButton);
            await _tapLive(tester, strings.mineNoButton);
            expect(controller.calls, ['answerMine $peerFingerprint true']);
            expect(_modal, findsOneWidget);

            await _ms(tester, 1750);
            await _ms(tester, modalTransitionDuration.inMilliseconds + 40);
            expect(_modal, findsNothing);
            expect(controller.calls, ['answerMine $peerFingerprint true']);
          },
        );
      },
    );

    group('[$code] E287 single answers and the guards of point 241', () {
      testWidgets('answerMine that changes the state at once does not cut the '
          'farewell nor open another route; the next question comes after', (
        tester,
      ) async {
        final controller = await _mount(
          tester,
          code,
          pairingState(questions: [_mine, _otherMine]),
        );
        await _openArmed(tester);
        final route = _routeOf(tester);

        controller.afterMine = pairingState(questions: [_otherMine]);
        await _tapLive(tester, strings.mineYesButton);
        expect(controller.calls, ['answerMine $peerFingerprint true']);

        for (var t = 0; t < 1700; t += 50) {
          await _ms(tester, 50);
          expect(_modal, findsOneWidget);
          expect(identical(_routeOf(tester), route), isTrue);
          expect(_view().title, strings.mineTitle(peerName));
          expect(find.text(strings.mineTitle(_otherName)), findsNothing);
        }
        await _escape(tester);
        await _tapOutside(tester);
        expect(controller.calls, ['answerMine $peerFingerprint true']);

        await _ms(tester, 60);
        await _ms(tester, 400);
        expect(_view().title, strings.mineTitle(_otherName));
        expect(identical(_routeOf(tester), route), isTrue);

        controller.afterMine = pairingState();
        await _escape(tester);
        expect(controller.calls, [
          'answerMine $peerFingerprint true',
          'answerMine $_otherFingerprint false',
        ]);
        await _ms(tester, 400);
        expect(_modal, findsNothing);
      });

      testWidgets('answerMine that empties the questions at once keeps the '
          'farewell for 1.75 s before closing', (tester) async {
        final controller = await _mount(
          tester,
          code,
          pairingState(questions: [_mine]),
        );
        await _openArmed(tester);
        controller.afterMine = pairingState();

        await _tapLive(tester, strings.mineNoButton);
        await _ms(tester, 1700);
        expect(_modal, findsOneWidget);
        expect(_view().title, strings.mineTitle(peerName));
        final tiles = _liveTiles();
        expect([for (final tile in tiles) tile.onPressed], [null, null]);
        expect([for (final tile in tiles) tile.selected], [false, true]);
        expect([for (final tile in tiles) tile.dimmed], [true, false]);

        await _ms(tester, 60);
        await _ms(tester, 400);
        expect(_modal, findsNothing);
        expect(controller.calls, ['answerMine $peerFingerprint false']);
      });

      testWidgets('during the farewell, more taps, Esc and a tap outside '
          'give no second answer', (tester) async {
        final controller = await _mount(
          tester,
          code,
          pairingState(questions: [_mine]),
        );
        await _openArmed(tester);

        await _tapLive(tester, strings.mineYesButton);
        await _ms(tester, 100);
        await _tapLive(tester, strings.mineYesButton);
        await _tapLive(tester, strings.mineNoButton);
        await _escape(tester);
        await _tapOutside(tester);
        await _ms(tester, 1000);
        await _escape(tester);
        expect(controller.calls, ['answerMine $peerFingerprint true']);
        expect(_modal, findsOneWidget);

        controller.emit(pairingState());
        await tester.pump();
        await _ms(tester, 500);
        expect(_modal, findsOneWidget);
        await _ms(tester, 200);
        await _ms(tester, 400);
        expect(_modal, findsNothing);
        expect(controller.calls, ['answerMine $peerFingerprint true']);
      });

      for (final (question, label, answer) in [
        (
          _replace,
          strings.replaceButton,
          'answerReplace $peerFingerprint true',
        ),
        (_mine, strings.mineYesButton, 'answerMine $peerFingerprint true'),
      ]) {
        testWidgets('${question.runtimeType}: Esc and a tap outside right '
            'after the answer, while the route leaves, answer nothing more', (
          tester,
        ) async {
          final controller = await _mount(
            tester,
            code,
            pairingState(questions: [question]),
            reduceMotion: question is MineQuestion,
          );
          await _openArmed(tester);
          controller.afterReplace = pairingState();
          controller.afterMine = pairingState();

          final spot = tester.getCenter(find.text(label));
          await tester.tapAt(spot);
          await tester.sendKeyEvent(LogicalKeyboardKey.escape);
          await tester.tapAt(const Offset(5, 5));
          await tester.pump();
          await tester.sendKeyEvent(LogicalKeyboardKey.escape);
          await tester.tapAt(const Offset(5, 5));
          await tester.pump();
          await _ms(tester, 100);
          await tester.sendKeyEvent(LogicalKeyboardKey.escape);
          await tester.tapAt(const Offset(5, 5));
          await tester.pump();

          expect(controller.calls, [answer]);
          await _ms(tester, 400);
          expect(_modal, findsNothing);
          expect(controller.calls, [answer]);
        });
      }

      for (final question in [_mine, _replace]) {
        testWidgets('${question.runtimeType} withdrawn by the core: Esc and a '
            'tap outside on the leaving route give no answer', (tester) async {
          final controller = await _mount(
            tester,
            code,
            pairingState(questions: [question]),
          );
          await _openArmed(tester);

          controller.emit(pairingState());
          await tester.pump();
          await _ms(tester, 50);
          expect(_modal, findsOneWidget);
          await tester.sendKeyEvent(LogicalKeyboardKey.escape);
          await tester.pump();
          await tester.tapAt(const Offset(5, 5));
          await tester.pump();
          await _ms(tester, 100);
          await tester.sendKeyEvent(LogicalKeyboardKey.escape);
          await tester.tapAt(const Offset(5, 5));
          await tester.pump();

          expect(controller.calls, isEmpty);
          await _ms(tester, 400);
          expect(_modal, findsNothing);
          expect(controller.calls, isEmpty);
        });
      }

      testWidgets('Esc twice on replace? answers answerReplace once', (
        tester,
      ) async {
        final controller = await _mount(
          tester,
          code,
          pairingState(questions: [_replace]),
        );
        await _openArmed(tester);

        await tester.sendKeyEvent(LogicalKeyboardKey.escape);
        await tester.sendKeyEvent(LogicalKeyboardKey.escape);
        await tester.pump();
        await _escape(tester);
        expect(controller.calls, ['answerReplace $peerFingerprint false']);
        await _ms(tester, 400);
        expect(_modal, findsNothing);
      });

      testWidgets('Replace then Esc on is it yours? in the same window gives '
          'one answer to each', (tester) async {
        final controller = await _mount(
          tester,
          code,
          pairingState(questions: [_replace, _mine]),
        );
        await _openArmed(tester);
        controller.afterReplace = pairingState(questions: [_mine]);

        await _tapLive(tester, strings.replaceButton);
        await _escape(tester);
        await _escape(tester);
        await _ms(tester, 400);

        expect(controller.calls, [
          'answerReplace $peerFingerprint true',
          'answerMine $peerFingerprint false',
        ]);
        expect(_modal, findsNothing);
      });
    });

    group('[$code] E287 a new pairing during the farewell', () {
      testWidgets('replaces the farewell in the same route, keeps the single '
          'answer and the question is not asked again', (tester) async {
        final controller = await _mount(
          tester,
          code,
          pairingState(questions: [_mine]),
        );
        await _openArmed(tester);
        final route = _routeOf(tester);

        await _tapLive(tester, strings.mineYesButton);
        await _ms(tester, 500);
        controller.emit(
          pairingState(
            pairing: view(
              role: PairingRole.receiver,
              phase: PairingPhase.comparing,
              fingerprint: _otherFingerprint,
              name: _otherName,
            ),
            questions: [_mine],
          ),
        );
        await tester.pump();
        await _ms(tester, 450);
        expect(_view().title, strings.pairingRequestTitle(_otherName));
        expect(identical(_routeOf(tester), route), isTrue);

        await _ms(tester, 2000);
        expect(_view().title, strings.pairingRequestTitle(_otherName));
        await _escape(tester);
        await _tapOutside(tester);
        expect(_modal, findsOneWidget);
        expect(controller.calls, ['answerMine $peerFingerprint true']);

        controller.emit(pairingState(questions: [_mine]));
        await tester.pump();
        await _ms(tester, 400);
        expect(_modal, findsNothing);
        expect(controller.calls, ['answerMine $peerFingerprint true']);
        expect(tester.takeException(), isNull);
      });
    });

    group('[$code] E287 keyboard and focus (points 229 and 241)', () {
      testWidgets('Tab to Close, Enter, and Esc on replace? keeps both once', (
        tester,
      ) async {
        final controller = await _mount(
          tester,
          code,
          pairingState(
            pairing: view(
              role: PairingRole.receiver,
              phase: PairingPhase.finished,
              outcome: PairingOutcome.paired,
            ),
            questions: [_replace],
          ),
        );
        await _openArmed(tester);
        controller.afterDismiss = pairingState(questions: [_replace]);

        await _tabTo(tester, strings.closeButton);
        await tester.sendKeyEvent(LogicalKeyboardKey.enter);
        await tester.pump();
        await _ms(tester, 450);
        expect(_view().title, strings.replaceTitle(_oldName));

        await _escape(tester);
        await _escape(tester);
        expect(controller.calls, [
          'dismissPairing',
          'answerReplace $peerFingerprint false',
        ]);
        await _ms(tester, 400);
        expect(_modal, findsNothing);
      });

      testWidgets('with the focus on It is mine, a new pairing gives the '
          'focus back to the frame and Esc does nothing', (tester) async {
        final controller = await _mount(
          tester,
          code,
          pairingState(questions: [_mine]),
        );
        await _openArmed(tester);
        await _tabTo(tester, strings.mineYesButton);

        controller.emit(
          pairingState(pairing: receiverComparing, questions: [_mine]),
        );
        await tester.pump();
        await tester.pump();
        expect(FocusManager.instance.primaryFocus?.debugLabel, 'NbModalFrame');
        await _ms(tester, 450);
        await _escape(tester);
        expect(_modal, findsOneWidget);
        expect(controller.calls, isEmpty);
      });
    });

    group('[$code] E287 unmounting the host with the route open', () {
      for (final (name, state) in [
        ('a pairing', pairingState(pairing: receiverComparing)),
        ('a question', pairingState(questions: [_mine])),
      ]) {
        testWidgets('with $name, the route goes away without answering and '
            'no route comes back', (tester) async {
          final showHost = ValueNotifier<bool>(true);
          addTearDown(showHost.dispose);
          final controller = await _mount(
            tester,
            code,
            state,
            showHost: showHost,
          );
          await _openArmed(tester);
          expect(_modal, findsOneWidget);

          showHost.value = false;
          await tester.pump();
          await tester.pump();
          await _ms(tester, 400);
          expect(_modal, findsNothing);
          expect(tester.takeException(), isNull);

          controller.emit(
            pairingState(pairing: receiverComparing, questions: [_mine]),
          );
          await tester.pump();
          await _ms(tester, 400);
          expect(_modal, findsNothing);
          expect(controller.calls, isEmpty);
          expect(tester.takeException(), isNull);
        });
      }
    });

    group('[$code] E287 small windows and large text with Segoe UI '
        '(points 198 and 240)', () {
      const longName = 'Port\u00E1til del estudio de Ana en casa';
      final scenarios = <String, NodeState>{
        'connecting': pairingState(
          pairing: view(
            role: PairingRole.initiator,
            phase: PairingPhase.connecting,
            name: longName,
          ),
        ),
        'initiator comparing with a namesake': pairingState(
          pairing: view(
            role: PairingRole.initiator,
            phase: PairingPhase.comparing,
            name: longName,
          ),
          namesake: longName,
        ),
        'receiver comparing with a namesake': pairingState(
          pairing: view(
            role: PairingRole.receiver,
            phase: PairingPhase.comparing,
            name: longName,
          ),
          namesake: longName,
        ),
        'receiver already paired': pairingState(
          pairing: view(
            role: PairingRole.receiver,
            phase: PairingPhase.comparing,
            name: longName,
            alreadyPaired: true,
          ),
        ),
        'receiver waiting with a namesake': pairingState(
          pairing: view(
            role: PairingRole.receiver,
            phase: PairingPhase.waitingPeer,
            name: longName,
          ),
          namesake: longName,
        ),
        'cancelled by the peer': pairingState(
          pairing: view(
            role: PairingRole.initiator,
            phase: PairingPhase.finished,
            outcome: PairingOutcome.cancelledByPeer,
            name: longName,
          ),
        ),
        'paused': pairingState(
          pairing: view(
            role: PairingRole.initiator,
            phase: PairingPhase.finished,
            outcome: PairingOutcome.paused,
            name: longName,
          ),
        ),
        'replace?': pairingState(
          questions: [
            ReplaceQuestion(
              fingerprint: peerFingerprint,
              deviceName: longName,
              oldFingerprint: _oldFingerprint,
              oldName: '$longName \u00B7 $_oldShort',
            ),
          ],
        ),
        'is it yours?': pairingState(
          questions: [
            MineQuestion(fingerprint: peerFingerprint, deviceName: longName),
          ],
        ),
      };
      for (final window in [const Size(760, 520), const Size(800, 600)]) {
        for (final MapEntry(key: name, value: state) in scenarios.entries) {
          testWidgets('$name at ${window.width.toInt()}x'
              '${window.height.toInt()} and 130 %: no overflow, the frame '
              'fits and every button is whole inside it', (tester) async {
            await _mount(
              tester,
              code,
              state,
              reduceMotion: true,
              textScale: 1.3,
              window: window,
            );
            await _openArmed(tester);

            expect(tester.takeException(), isNull);
            final frame = _frameRect(tester);
            expect(frame.width, lessThanOrEqualTo(400));
            expect(frame.height, lessThanOrEqualTo(488));
            expect(frame.left, greaterThanOrEqualTo(16));
            expect(frame.top, greaterThanOrEqualTo(16));
            expect(frame.right, lessThanOrEqualTo(window.width - 16));
            expect(frame.bottom, lessThanOrEqualTo(window.height - 16));

            final buttons = [
              ..._live(_inModal(find.byType(ModalButton))),
              ..._live(_inModal(find.byType(ChoiceTile))),
            ];
            expect(buttons, isNotEmpty);
            for (final button in buttons) {
              final rect = tester.getRect(_element(button));
              expect(rect.left, greaterThanOrEqualTo(frame.left - 0.5));
              expect(rect.right, lessThanOrEqualTo(frame.right + 0.5));
              expect(rect.top, greaterThanOrEqualTo(frame.top - 0.5));
              expect(rect.bottom, lessThanOrEqualTo(frame.bottom + 0.5));
            }
            for (final button in _live(_inModal(find.byType(ModalButton)))) {
              final label = (button.widget as ModalButton).label;
              final text = find
                  .descendant(of: _element(button), matching: find.text(label))
                  .evaluate()
                  .single;
              _expectWhole(tester, text, label);
            }
            final pair = _view().pair;
            if (pair.length == 2) {
              final heights = [
                for (final widget in pair)
                  tester.getSize(find.byWidget(widget)).height,
              ];
              expect(heights.first, heights.last);
              expect(heights.first, greaterThanOrEqualTo(46));
            }
            final title = _live(_inModal(find.text(_view().title)));
            expect(title, hasLength(1));
            final titleParagraph = tester.renderObject<RenderParagraph>(
              find.descendant(
                of: _element(title.single),
                matching: find.byType(RichText),
              ),
            );
            expect(titleParagraph.maxLines, 2);
          });
        }
      }
    });
  }
}
