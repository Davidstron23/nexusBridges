import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nexus_bridges/src/l10n/app_strings.dart';
import 'package:nexus_bridges/src/ui/home_screen.dart';
import 'package:nexus_bridges/src/ui/modal/modal_button.dart';
import 'package:nexus_bridges/src/ui/modal/modal_frame.dart';
import 'package:nexus_bridges/src/ui/modal/stage.dart';
import 'package:nexus_bridges/src/ui/modal/stage_kit.dart';
import 'package:nexus_bridges_core/nexus_bridges_core.dart';

import 'cover_fixtures.dart';
import 'fake_app_controller.dart';
import 'lifecycle_fixtures.dart';
import 'pairing_fixtures.dart' show peerName, view;
import 'segoe_font.dart';

const _home = NetworkPrompt('net-home', 'Casa');
const _office = NetworkPrompt('net-office', 'Oficina');

NodeState _asking(List<NetworkPrompt> prompts) {
  return NodeState(paused: true, pausedNetworks: prompts, prompts: prompts);
}

class _ClosingController extends FakeAppController {
  _ClosingController({super.state});

  @override
  void dismissPairing() {
    super.dismissPairing();
    final current = state!;
    emit(
      NodeState(
        paused: current.paused,
        pausedNetworks: current.pausedNetworks,
        prompts: current.prompts,
      ),
    );
  }
}

Future<void> _pumpStill(
  WidgetTester tester,
  FakeAppController controller,
  String code,
) => pumpHome(tester, controller, code, reduceMotion: true);

Finder get _modal => find.byType(NbModal);

Finder get _frame =>
    find.descendant(of: _modal, matching: find.byType(DecoratedBox)).first;

void main() {
  for (final code in languageCodes) {
    final strings = stringsFor(code);

    Finder bodyOf(String network) =>
        find.text(strings.networkPromptBody(network));

    group('[$code] RF-11 the question', () {
      testWidgets('a pending network opens the dialog with its name', (
        tester,
      ) async {
        final controller = FakeAppController(state: _asking(const [_home]));
        await _pumpStill(tester, controller, code);

        expect(_modal, findsOneWidget);
        expect(find.text(strings.networkPromptTitle), findsOneWidget);
        expect(bodyOf('Casa'), findsOneWidget);
        expect(find.text(strings.yes), findsOneWidget);
        expect(find.text(strings.no), findsOneWidget);
        expect(controller.calls, isEmpty);
      });

      testWidgets('no pending network opens no dialog', (tester) async {
        final controller = FakeAppController(state: const NodeState());
        await _pumpStill(tester, controller, code);

        expect(_modal, findsNothing);
      });

      testWidgets('a network that arrives later opens the dialog', (
        tester,
      ) async {
        final controller = FakeAppController(state: const NodeState());
        await _pumpStill(tester, controller, code);

        controller.emit(_asking(const [_home]));
        await tester.pumpAndSettle();

        expect(bodyOf('Casa'), findsOneWidget);
      });

      testWidgets('repeated states while open keep a single dialog', (
        tester,
      ) async {
        final controller = FakeAppController(state: _asking(const [_home]));
        await _pumpStill(tester, controller, code);

        controller.emit(_asking(const [_home]));
        await tester.pumpAndSettle();
        controller.emit(_asking(const [_home, _office]));
        await tester.pumpAndSettle();

        expect(_modal, findsOneWidget);
        expect(bodyOf('Casa'), findsOneWidget);
        expect(bodyOf('Oficina'), findsNothing);
      });

      testWidgets('yes trusts the network and closes the dialog', (
        tester,
      ) async {
        final controller = FakeAppController(state: _asking(const [_home]));
        await _pumpStill(tester, controller, code);

        await tester.tap(find.text(strings.yes));
        await tester.pumpAndSettle();

        expect(controller.calls, ['decideNetwork net-home trusted']);
        expect(_modal, findsNothing);
      });

      testWidgets('no marks the network untrusted and closes the dialog', (
        tester,
      ) async {
        final controller = FakeAppController(state: _asking(const [_home]));
        await _pumpStill(tester, controller, code);

        await tester.tap(find.text(strings.no));
        await tester.pumpAndSettle();

        expect(controller.calls, ['decideNetwork net-home untrusted']);
        expect(_modal, findsNothing);
      });
    });

    group('[$code] RF-13 closing without an answer', () {
      testWidgets('Esc dismisses the prompt without deciding', (tester) async {
        final controller = FakeAppController(state: _asking(const [_home]));
        await _pumpStill(tester, controller, code);

        await tester.sendKeyEvent(LogicalKeyboardKey.escape);
        await tester.pumpAndSettle();

        expect(controller.calls, ['dismissPrompt net-home']);
        expect(_modal, findsNothing);
      });

      testWidgets('a tap outside dismisses the prompt without deciding', (
        tester,
      ) async {
        final controller = FakeAppController(state: _asking(const [_home]));
        await _pumpStill(tester, controller, code);

        await tester.tapAt(const Offset(5, 5));
        await tester.pumpAndSettle();

        expect(controller.calls, ['dismissPrompt net-home']);
        expect(_modal, findsNothing);
      });

      testWidgets('a stale state after Esc does not ask again', (tester) async {
        final controller = FakeAppController(state: _asking(const [_home]));
        await _pumpStill(tester, controller, code);

        await tester.sendKeyEvent(LogicalKeyboardKey.escape);
        await tester.pumpAndSettle();
        controller.emit(_asking(const [_home]));
        await tester.pumpAndSettle();

        expect(_modal, findsNothing);
        expect(controller.calls, ['dismissPrompt net-home']);
      });

      testWidgets('the paused banner brings the question back via askAgain', (
        tester,
      ) async {
        final controller = FakeAppController(state: _asking(const [_home]));
        await _pumpStill(tester, controller, code);

        await tester.sendKeyEvent(LogicalKeyboardKey.escape);
        await tester.pumpAndSettle();
        controller.emit(const NodeState(paused: true, pausedNetworks: [_home]));
        await tester.pumpAndSettle();
        expect(_modal, findsNothing);

        await tester.tap(find.text(strings.trustNetworkButton('Casa')));
        await tester.pumpAndSettle();
        expect(controller.calls, [
          'dismissPrompt net-home',
          'askAgain net-home',
        ]);

        controller.emit(_asking(const [_home]));
        await tester.pumpAndSettle();
        expect(bodyOf('Casa'), findsOneWidget);
      });
    });

    group('[$code] v2.8 point 11 the network leaves prompts', () {
      testWidgets('the dialog closes without calling anything', (tester) async {
        final controller = FakeAppController(state: _asking(const [_home]));
        await _pumpStill(tester, controller, code);

        controller.emit(const NodeState());
        await tester.pumpAndSettle();

        expect(_modal, findsNothing);
        expect(controller.calls, isEmpty);
      });

      testWidgets('the next pending network opens in its place', (
        tester,
      ) async {
        final controller = FakeAppController(
          state: _asking(const [_home, _office]),
        );
        await _pumpStill(tester, controller, code);
        expect(bodyOf('Casa'), findsOneWidget);

        controller.emit(_asking(const [_office]));
        await tester.pumpAndSettle();

        expect(_modal, findsOneWidget);
        expect(bodyOf('Casa'), findsNothing);
        expect(bodyOf('Oficina'), findsOneWidget);
        expect(controller.calls, isEmpty);
      });

      testWidgets('the network can come back and is asked again', (
        tester,
      ) async {
        final controller = FakeAppController(state: _asking(const [_home]));
        await _pumpStill(tester, controller, code);

        controller.emit(const NodeState());
        await tester.pumpAndSettle();
        controller.emit(_asking(const [_home]));
        await tester.pumpAndSettle();

        expect(bodyOf('Casa'), findsOneWidget);
        expect(controller.calls, isEmpty);
      });
    });

    group('[$code] answered networks and the queue', () {
      testWidgets('after yes a stale state with the network does not reopen', (
        tester,
      ) async {
        final controller = FakeAppController(state: _asking(const [_home]));
        await _pumpStill(tester, controller, code);

        await tester.tap(find.text(strings.yes));
        await tester.pumpAndSettle();
        controller.emit(_asking(const [_home]));
        await tester.pumpAndSettle();
        controller.emit(_asking(const [_home]));
        await tester.pumpAndSettle();

        expect(_modal, findsNothing);
        expect(controller.calls, ['decideNetwork net-home trusted']);
      });

      testWidgets('askAgain after leaving prompts asks once more', (
        tester,
      ) async {
        final controller = FakeAppController(state: _asking(const [_home]));
        await _pumpStill(tester, controller, code);

        await tester.tap(find.text(strings.yes));
        await tester.pumpAndSettle();
        controller.emit(_asking(const [_home]));
        await tester.pumpAndSettle();
        expect(_modal, findsNothing);

        controller.emit(const NodeState());
        await tester.pumpAndSettle();
        controller.emit(_asking(const [_home]));
        await tester.pumpAndSettle();

        expect(bodyOf('Casa'), findsOneWidget);

        await tester.tap(find.text(strings.no));
        await tester.pumpAndSettle();
        expect(controller.calls, [
          'decideNetwork net-home trusted',
          'decideNetwork net-home untrusted',
        ]);
      });

      testWidgets('two pending networks are asked one after the other', (
        tester,
      ) async {
        final controller = FakeAppController(
          state: _asking(const [_home, _office]),
        );
        await _pumpStill(tester, controller, code);

        expect(_modal, findsOneWidget);
        expect(bodyOf('Casa'), findsOneWidget);

        await tester.tap(find.text(strings.yes));
        await tester.pumpAndSettle();

        expect(_modal, findsOneWidget);
        expect(bodyOf('Oficina'), findsOneWidget);

        await tester.sendKeyEvent(LogicalKeyboardKey.escape);
        await tester.pumpAndSettle();

        expect(_modal, findsNothing);
        expect(controller.calls, [
          'decideNetwork net-home trusted',
          'dismissPrompt net-office',
        ]);
      });
    });
  }

  group('M1 prompts that change faster than a frame', () {
    const a = NetworkPrompt('net-a', 'Alfa');
    const b = NetworkPrompt('net-b', 'Beta');
    final strings = stringsFor('es');

    Finder dialogs() => find.byType(NbModal, skipOffstage: false);
    Finder bodyOf(String network) =>
        find.text(strings.networkPromptBody(network), skipOffstage: false);

    testWidgets('[A] then [] in the same frame leaves no dialog', (
      tester,
    ) async {
      final controller = FakeAppController(state: const NodeState());
      await _pumpStill(tester, controller, 'es');

      controller.emit(_asking(const [a]));
      controller.emit(const NodeState());
      await tester.pumpAndSettle();

      expect(dialogs(), findsNothing);
      expect(controller.calls, isEmpty);
      expect(tester.takeException(), isNull);
    });

    testWidgets('when A comes back there is exactly one dialog', (
      tester,
    ) async {
      final controller = FakeAppController(state: const NodeState());
      await _pumpStill(tester, controller, 'es');

      controller.emit(_asking(const [a]));
      controller.emit(const NodeState());
      await tester.pumpAndSettle();
      controller.emit(_asking(const [a]));
      await tester.pumpAndSettle();

      expect(dialogs(), findsOneWidget);
      expect(bodyOf('Alfa'), findsOneWidget);
      expect(find.text(strings.yes, skipOffstage: false), findsOneWidget);
    });

    testWidgets('yes after A comes back decides once and leaves no orphan', (
      tester,
    ) async {
      final controller = FakeAppController(state: const NodeState());
      await _pumpStill(tester, controller, 'es');

      controller.emit(_asking(const [a]));
      controller.emit(const NodeState());
      await tester.pumpAndSettle();
      controller.emit(_asking(const [a]));
      await tester.pumpAndSettle();

      await tester.tap(find.text(strings.yes));
      await tester.pumpAndSettle();

      expect(controller.calls, ['decideNetwork net-a trusted']);
      expect(dialogs(), findsNothing);
      expect(find.text(strings.yes, skipOffstage: false), findsNothing);
    });

    testWidgets('[A], [] and [A] in the same frame keep a single dialog', (
      tester,
    ) async {
      final controller = FakeAppController(state: const NodeState());
      await _pumpStill(tester, controller, 'es');

      controller.emit(_asking(const [a]));
      controller.emit(const NodeState());
      controller.emit(_asking(const [a]));
      await tester.pumpAndSettle();

      expect(dialogs(), findsOneWidget);

      await tester.tap(find.text(strings.yes));
      await tester.pumpAndSettle();

      expect(controller.calls, ['decideNetwork net-a trusted']);
      expect(dialogs(), findsNothing);
    });

    testWidgets('answering A while B leaves at once leaves no dialog of B', (
      tester,
    ) async {
      final controller = FakeAppController(state: _asking(const [a, b]));
      await _pumpStill(tester, controller, 'es');
      expect(bodyOf('Alfa'), findsOneWidget);

      await tester.tap(find.text(strings.yes));
      controller.emit(_asking(const [a]));
      await tester.pumpAndSettle();

      expect(dialogs(), findsNothing);
      expect(bodyOf('Beta'), findsNothing);
      expect(controller.calls, ['decideNetwork net-a trusted']);
      expect(tester.takeException(), isNull);
    });

    testWidgets('B leaving one frame after answering A closes its dialog', (
      tester,
    ) async {
      final controller = FakeAppController(state: _asking(const [a, b]));
      await _pumpStill(tester, controller, 'es');

      await tester.tap(find.text(strings.yes));
      await tester.pump();
      controller.emit(_asking(const [a]));
      await tester.pumpAndSettle();

      expect(dialogs(), findsNothing);
      expect(bodyOf('Beta'), findsNothing);
      expect(controller.calls, ['decideNetwork net-a trusted']);
    });

    testWidgets(
      'B that leaves and comes back after answering A is asked once',
      (tester) async {
        final controller = FakeAppController(state: _asking(const [a, b]));
        await _pumpStill(tester, controller, 'es');

        await tester.tap(find.text(strings.yes));
        controller.emit(_asking(const [a]));
        await tester.pumpAndSettle();
        controller.emit(_asking(const [a, b]));
        await tester.pumpAndSettle();

        expect(dialogs(), findsOneWidget);
        expect(bodyOf('Beta'), findsOneWidget);
        expect(bodyOf('Alfa'), findsNothing);

        await tester.tap(find.text(strings.no));
        await tester.pumpAndSettle();

        expect(dialogs(), findsNothing);
        expect(controller.calls, [
          'decideNetwork net-a trusted',
          'decideNetwork net-b untrusted',
        ]);
      },
    );

    testWidgets('a burst of 20 changes never leaves more than one dialog', (
      tester,
    ) async {
      final controller = FakeAppController(state: const NodeState());
      await _pumpStill(tester, controller, 'es');

      final states = <List<NetworkPrompt>>[
        const [a],
        const [],
        const [a, b],
        const [a],
        const [],
        const [a, b],
        const [a, b],
        const [],
        const [a],
        const [a, b],
      ];
      var maxDialogs = 0;
      for (var i = 0; i < 20; i++) {
        controller.emit(_asking(states[i % states.length]));
        if (i.isEven) {
          controller.emit(_asking(states[(i + 1) % states.length]));
        }
        await tester.pump(Duration(milliseconds: i % 3 == 0 ? 0 : 16));
        final count = dialogs().evaluate().length;
        if (count > maxDialogs) maxDialogs = count;
        expect(count, lessThanOrEqualTo(1), reason: 'step $i');
      }
      await tester.pumpAndSettle();

      expect(maxDialogs, 1);
      expect(controller.calls, isEmpty);
      expect(tester.takeException(), isNull);

      controller.emit(_asking(const [a, b]));
      await tester.pumpAndSettle();
      expect(dialogs(), findsOneWidget);
      expect(bodyOf('Alfa'), findsOneWidget);

      await tester.tap(find.text(strings.yes));
      await tester.pumpAndSettle();
      expect(dialogs(), findsOneWidget);
      expect(bodyOf('Beta'), findsOneWidget);

      await tester.tap(find.text(strings.no));
      await tester.pumpAndSettle();
      expect(dialogs(), findsNothing);
      expect(controller.calls, [
        'decideNetwork net-a trusted',
        'decideNetwork net-b untrusted',
      ]);
    });

    testWidgets('a burst of 20 changes ending in [] leaves no dialog', (
      tester,
    ) async {
      final controller = FakeAppController(state: _asking(const [a]));
      await _pumpStill(tester, controller, 'es');

      final states = <List<NetworkPrompt>>[
        const [],
        const [a, b],
        const [a],
      ];
      for (var i = 0; i < 20; i++) {
        controller.emit(_asking(states[i % states.length]));
        await tester.pump();
        expect(dialogs().evaluate().length, lessThanOrEqualTo(1));
      }
      controller.emit(const NodeState());
      await tester.pumpAndSettle();

      expect(dialogs(), findsNothing);
      expect(controller.calls, isEmpty);
    });
  });

  group('B1 large text in a small window', () {
    const longName = NetworkPrompt(
      'net-long',
      'WWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWW',
    );

    void smallWindowWithLargeText(WidgetTester tester) {
      tester.view.physicalSize = const Size(360, 330);
      tester.view.devicePixelRatio = 1;
      tester.platformDispatcher.textScaleFactorTestValue = 2;
      addTearDown(tester.view.reset);
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    }

    Future<void> tapReachable(WidgetTester tester, Finder button) async {
      await tester.ensureVisible(button);
      await tester.pumpAndSettle();
      final rect = tester.getRect(button);
      expect(
        const Rect.fromLTWH(0, 0, 360, 330).contains(rect.center),
        isTrue,
        reason: 'button center $rect must be inside the window',
      );
      await tester.tap(button);
      await tester.pumpAndSettle();
    }

    for (final code in languageCodes) {
      final strings = stringsFor(code);

      for (final prompt in const [_home, longName]) {
        final label = prompt == _home ? 'a short' : 'a 64 character';

        testWidgets('[$code] $label name does not overflow at 2x text', (
          tester,
        ) async {
          smallWindowWithLargeText(tester);
          final controller = FakeAppController(state: _asking([prompt]));
          await _pumpStill(tester, controller, code);

          expect(tester.takeException(), isNull);
          expect(_modal, findsOneWidget);
          final context = tester.element(find.text(strings.yes));
          expect(MediaQuery.textScalerOf(context).scale(14), 28);
          final frame = tester.getSize(_frame);
          expect(frame.height, lessThanOrEqualTo(330 - 2 * modalScrimPadding));
          expect(frame.height, lessThanOrEqualTo(modalSize.height));
          expect(frame.width, lessThanOrEqualTo(360 - 2 * modalScrimPadding));
        });

        testWidgets('[$code] $label name: yes is reachable at 2x text', (
          tester,
        ) async {
          smallWindowWithLargeText(tester);
          final controller = FakeAppController(state: _asking([prompt]));
          await _pumpStill(tester, controller, code);

          await tapReachable(tester, find.text(strings.yes));

          expect(controller.calls, [
            'decideNetwork ${prompt.networkId} trusted',
          ]);
          expect(_modal, findsNothing);
          expect(tester.takeException(), isNull);
        });

        testWidgets('[$code] $label name: no is reachable at 2x text', (
          tester,
        ) async {
          smallWindowWithLargeText(tester);
          final controller = FakeAppController(state: _asking([prompt]));
          await _pumpStill(tester, controller, code);

          await tapReachable(tester, find.text(strings.no));

          expect(controller.calls, [
            'decideNetwork ${prompt.networkId} untrusted',
          ]);
          expect(_modal, findsNothing);
          expect(tester.takeException(), isNull);
        });
      }

      testWidgets('[$code] the whole question can be scrolled into view', (
        tester,
      ) async {
        smallWindowWithLargeText(tester);
        final controller = FakeAppController(state: _asking(const [longName]));
        await _pumpStill(tester, controller, code);

        final title = find.text(strings.networkPromptTitle);
        final body = find.text(strings.networkPromptBody(longName.networkName));
        final window = const Rect.fromLTWH(0, 0, 360, 330);

        await tester.ensureVisible(body);
        await tester.pumpAndSettle();
        expect(window.overlaps(tester.getRect(body)), isTrue);

        await tester.ensureVisible(title);
        await tester.pumpAndSettle();
        expect(window.overlaps(tester.getRect(title)), isTrue);
        expect(tester.takeException(), isNull);
      });
    }
  });

  group('RF-62 dialog texts', () {
    testWidgets('the dialog texts are not empty and differ by language', (
      tester,
    ) async {
      final rendered = <String, List<String>>{};
      for (final code in languageCodes) {
        final controller = FakeAppController(
          state: const NodeState(prompts: [_home]),
        );
        await _pumpStill(tester, controller, code);
        final dialog = _modal;
        expect(dialog, findsOneWidget);
        final texts = [
          for (final text in tester.widgetList<Text>(
            find.descendant(of: dialog, matching: find.byType(Text)),
          ))
            text.data ?? text.textSpan?.toPlainText() ?? '',
        ];
        final strings = stringsFor(code);
        expect(
          texts,
          unorderedEquals([
            strings.networkPromptTitle,
            strings.networkPromptBody('Casa'),
            strings.yes,
            strings.no,
          ]),
        );
        expect(texts.where((text) => text.trim().isEmpty), isEmpty);
        rendered[code] = texts;
        await tester.pumpWidget(const SizedBox());
      }
      expect(
        rendered['es']!.toSet().intersection(rendered['en']!.toSet()),
        isEmpty,
      );
    });
  });

  group('E289 the network question in its new window (RF-11, RF-13, RF-14 '
      'of the 002)', () {
    const greenTime = Duration(milliseconds: 900);
    const routeGone = Duration(milliseconds: 400);

    Future<void> pumpMoving(
      WidgetTester tester,
      FakeAppController controller,
      String code,
    ) async {
      await pumpHome(tester, controller, code, settle: false);
      await tester.pump();
      await tester.pump(modalTransitionDuration);
    }

    AnimationStatus routeStatus(WidgetTester tester) =>
        ModalRoute.of(tester.element(_modal))!.animation!.status;

    Finder button(String label) => find.widgetWithText(ModalButton, label);

    ModalStage stage(WidgetTester tester) =>
        tester.widget<ModalStage>(find.byType(ModalStage));

    Future<void> leave(WidgetTester tester) async {
      await tester.pump();
      await tester.pump(routeGone);
      await tester.pump();
    }

    for (final code in languageCodes) {
      final strings = stringsFor(code);

      Finder bodyOf(String network) =>
          find.text(strings.networkPromptBody(network));

      testWidgets('[$code] the window: network stage not yet trusted, title, '
          'body, and "${strings.no}" and "${strings.yes}" side by side', (
        tester,
      ) async {
        final controller = FakeAppController(state: _asking(const [_home]));
        await _pumpStill(tester, controller, code);

        expect(stage(tester).scene, StageScene.network);
        expect(stage(tester).input.trusted, isFalse);
        expect(find.text(strings.networkPromptTitle), findsOneWidget);
        expect(bodyOf('Casa'), findsOneWidget);
        final view = tester.widget<ModalView>(find.byType(ModalView));
        expect(view.actions, isEmpty);
        final pair = view.pair.cast<ModalButton>();
        expect([for (final b in pair) b.label], [strings.no, strings.yes]);
        expect(
          [for (final b in pair) b.kind],
          [ModalButtonKind.negative, ModalButtonKind.primary],
        );
        expect(pair.every((b) => b.inPair && b.onPressed != null), isTrue);
      });

      testWidgets('[$code] "${strings.yes}" decides at the click, turns the '
          'stage green, disables both buttons and closes at 0.9 s', (
        tester,
      ) async {
        final controller = FakeAppController(state: _asking(const [_home]));
        await pumpMoving(tester, controller, code);
        expect(
          tester.widget<ModalButton>(button(strings.yes)).onPressed,
          isNotNull,
        );

        await tester.tap(button(strings.yes));
        expect(controller.calls, ['decideNetwork net-home trusted']);
        await tester.pump();
        expect(stage(tester).input.trusted, isTrue);
        expect(tester.widget<ModalButton>(button(strings.yes)).onPressed, null);
        expect(tester.widget<ModalButton>(button(strings.no)).onPressed, null);

        await tester.tap(button(strings.no), warnIfMissed: false);
        await tester.tap(button(strings.yes), warnIfMissed: false);
        await tester.pump(greenTime - const Duration(milliseconds: 2));
        expect(routeStatus(tester), AnimationStatus.completed);
        expect(bodyOf('Casa'), findsOneWidget);

        await tester.pump(const Duration(milliseconds: 2));
        expect(routeStatus(tester), AnimationStatus.reverse);
        await leave(tester);
        expect(_modal, findsNothing);
        expect(controller.calls, ['decideNetwork net-home trusted']);
      });

      testWidgets('[$code] the network leaving prompts during the 0.9 s does '
          'not cut the window', (tester) async {
        final controller = FakeAppController(state: _asking(const [_home]));
        await pumpMoving(tester, controller, code);

        await tester.tap(button(strings.yes));
        await tester.pump(const Duration(milliseconds: 100));
        controller.emit(const NodeState());
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 500));

        expect(_modal, findsOneWidget);
        expect(routeStatus(tester), AnimationStatus.completed);
        expect(stage(tester).input.trusted, isTrue);

        await tester.pump(const Duration(milliseconds: 300));
        expect(routeStatus(tester), AnimationStatus.reverse);
        await leave(tester);
        expect(_modal, findsNothing);
        expect(controller.calls, ['decideNetwork net-home trusted']);
        expect(tester.takeException(), isNull);
      });

      testWidgets('[$code] the next network waits for the green window to '
          'close, and "${strings.no}" closes at once', (tester) async {
        final controller = FakeAppController(
          state: _asking(const [_home, _office]),
        );
        await pumpMoving(tester, controller, code);

        await tester.tap(button(strings.yes));
        await tester.pump(const Duration(milliseconds: 100));
        controller.emit(_asking(const [_office]));
        await tester.pump(const Duration(milliseconds: 400));
        expect(_modal, findsOneWidget);
        expect(bodyOf('Casa'), findsOneWidget);
        expect(bodyOf('Oficina'), findsNothing);

        await tester.pump(const Duration(milliseconds: 400));
        await leave(tester);
        await tester.pump(modalTransitionDuration);
        expect(_modal, findsOneWidget);
        expect(bodyOf('Oficina'), findsOneWidget);
        expect(stage(tester).input.trusted, isFalse);

        await tester.tap(button(strings.no));
        expect(controller.calls, [
          'decideNetwork net-home trusted',
          'decideNetwork net-office untrusted',
        ]);
        await tester.pump();
        expect(routeStatus(tester), AnimationStatus.reverse);
        await leave(tester);
        expect(_modal, findsNothing);
      });

      testWidgets('[$code] after "${strings.yes}", Esc and a tap outside do '
          'not dismiss the prompt', (tester) async {
        final controller = FakeAppController(state: _asking(const [_home]));
        await pumpMoving(tester, controller, code);

        await tester.tap(button(strings.yes));
        await tester.pump(const Duration(milliseconds: 100));
        await tester.sendKeyEvent(LogicalKeyboardKey.escape);
        await tester.pump();
        await tester.tapAt(const Offset(5, 5));
        await tester.pump(const Duration(milliseconds: 100));

        expect(routeStatus(tester), AnimationStatus.completed);
        expect(controller.calls, ['decideNetwork net-home trusted']);
        await tester.pump(greenTime);
        await leave(tester);
        expect(_modal, findsNothing);
        expect(controller.calls, ['decideNetwork net-home trusted']);
      });

      for (final (how, dismiss)
          in <(String, Future<void> Function(WidgetTester))>[
            ('Esc', (tester) => tester.sendKeyEvent(LogicalKeyboardKey.escape)),
            ('a tap outside', (tester) => tester.tapAt(const Offset(5, 5))),
          ]) {
        testWidgets('[$code] in motion, $how dismisses the prompt at once', (
          tester,
        ) async {
          final controller = FakeAppController(state: _asking(const [_home]));
          await pumpMoving(tester, controller, code);

          await dismiss(tester);
          await tester.pump();
          expect(routeStatus(tester), AnimationStatus.reverse);
          await leave(tester);
          expect(_modal, findsNothing);
          expect(controller.calls, ['dismissPrompt net-home']);
        });
      }

      testWidgets('[$code] a tap inside the window does not dismiss it', (
        tester,
      ) async {
        final controller = FakeAppController(state: _asking(const [_home]));
        await pumpMoving(tester, controller, code);

        await tester.tap(find.text(strings.networkPromptTitle));
        await tester.tap(find.byType(ModalStage));
        await tester.pump(const Duration(milliseconds: 100));

        expect(routeStatus(tester), AnimationStatus.completed);
        expect(controller.calls, isEmpty);
      });

      testWidgets('[$code] with reduced motion "${strings.yes}" closes in the '
          'same frame', (tester) async {
        final controller = FakeAppController(state: _asking(const [_home]));
        await _pumpStill(tester, controller, code);

        await tester.tap(button(strings.yes));
        expect(controller.calls, ['decideNetwork net-home trusted']);
        await tester.pump();
        await tester.pump();
        expect(_modal, findsNothing);
        expect(controller.calls, ['decideNetwork net-home trusted']);
      });

      for (final name in const ['equipos', 'equipo', 'casa', 'home', 'Casa']) {
        testWidgets('[$code] a network called "$name" is bold right where '
            'the name goes, and nowhere else', (tester) async {
          final controller = FakeAppController(
            state: _asking([NetworkPrompt('net-$name', name)]),
          );
          await _pumpStill(tester, controller, code);

          final text = tester.widget<Text>(
            find.descendant(
              of: find.byType(ModalLead),
              matching: find.byType(Text),
            ),
          );
          final root = text.textSpan!;
          expect(root.toPlainText(), strings.networkPromptBody(name));
          final spans = <TextSpan>[];
          root.visitChildren((span) {
            if (span is TextSpan && span.text != null) spans.add(span);
            return true;
          });
          final bold = [
            for (var i = 0; i < spans.length; i++)
              if (spans[i].style?.fontWeight == FontWeight.w600) i,
          ];
          expect(bold, hasLength(1));
          final at = bold.single;
          expect(spans[at].text, name);
          expect(at, greaterThan(0));
          expect(at, lessThan(spans.length - 1));
          expect(spans[at - 1].text, endsWith('"'));
          expect(spans[at + 1].text, startsWith('"'));
          final base = root.style!;
          expect(spans[at].style!.color, isNot(base.color));
        });
      }

      for (final reduceMotion in const [false, true]) {
        testWidgets('[$code] at 320 px and 130 % nothing overflows '
            '(reduceMotion: $reduceMotion)', (tester) async {
          tester.view.physicalSize = const Size(320, 640);
          tester.view.devicePixelRatio = 1;
          tester.platformDispatcher.textScaleFactorTestValue = 1.3;
          addTearDown(tester.view.reset);
          addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
          final controller = FakeAppController(state: _asking(const [_home]));
          if (reduceMotion) {
            await _pumpStill(tester, controller, code);
          } else {
            await pumpMoving(tester, controller, code);
            await tester.pump(const Duration(milliseconds: 600));
          }

          expect(_modal, findsOneWidget);
          expect(tester.takeException(), isNull);
          expect(
            tester.getSize(button(strings.yes)).height,
            tester.getSize(button(strings.no)).height,
          );
        });
      }
    }
  });

  group('E289 with the Windows font, the labels of the network question are '
      'read whole at 130 % (point 218)', () {
    setUpAll(loadSegoe);

    for (final code in languageCodes) {
      final strings = stringsFor(code);
      for (final window in const [Size(760, 520), Size(800, 600)]) {
        testWidgets('[$code] in a ${window.width.toInt()}x'
            '${window.height.toInt()} window "${strings.no}" and '
            '"${strings.yes}" are whole and as tall', (tester) async {
          tester.view.physicalSize = window;
          tester.view.devicePixelRatio = 1;
          tester.platformDispatcher.textScaleFactorTestValue = 1.3;
          addTearDown(tester.view.reset);
          addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
          final controller = FakeAppController(state: _asking(const [_home]));
          await _pumpStill(tester, controller, code);

          final paragraphs = tester.renderObjectList<RenderParagraph>(
            find.descendant(
              of: find.byType(ModalButton),
              matching: find.byType(RichText),
            ),
          );
          expect(paragraphs, hasLength(2));
          expect(paragraphs.where((p) => p.didExceedMaxLines), isEmpty);
          expect(
            tester.getSize(find.widgetWithText(ModalButton, strings.no)).height,
            tester
                .getSize(find.widgetWithText(ModalButton, strings.yes))
                .height,
          );
          expect(tester.takeException(), isNull);
        });
      }
    }
  });

  group('H1 "Use here" closes its own route, never the one on top (RF-11 and '
      'RF-13 of the 002)', () {
    const greenTime = Duration(milliseconds: 900);
    const routeGone = Duration(milliseconds: 400);

    Future<void> pumpMoving(
      WidgetTester tester,
      FakeAppController controller,
      String code, {
      bool reduceMotion = false,
    }) async {
      await pumpHome(
        tester,
        controller,
        code,
        settle: false,
        reduceMotion: reduceMotion,
      );
      await tester.pump();
      await tester.pump(modalTransitionDuration);
    }

    BuildContext homeContext(WidgetTester tester) =>
        tester.element(find.byType(HomeScreen));

    for (final code in languageCodes) {
      final strings = stringsFor(code);
      final question = modalWith(strings.networkPromptTitle);

      testWidgets('[$code] a modal route pushed on top during the 0.9 s stays '
          'open and untouched; the question leaves from under it, decided '
          'once and never dismissed', (tester) async {
        final controller = FakeAppController(state: _asking(const [_home]));
        await pumpMoving(tester, controller, code);

        await tester.tap(modalButtonIn(question, strings.yes));
        await tester.pump(const Duration(milliseconds: 300));
        final cover = pushCover(homeContext(tester));
        await tester.pump();
        await tester.pump(greenTime);
        await tester.pump(routeGone);
        await tester.pump(const Duration(milliseconds: 400));

        expect(cover.finished, isFalse);
        expect(cover.taps, 0);
        expect(cover.route.isCurrent, isTrue);
        expect(cover.route.animation!.status, AnimationStatus.completed);
        expect(find.text(strings.networkPromptTitle), findsNothing);
        expect(_modal, findsOneWidget);
        expect(controller.calls, ['decideNetwork net-home trusted']);
        expect(tester.takeException(), isNull);

        await tester.tap(coverButton);
        await tester.pump();
        await tester.pump(routeGone);
        await tester.pump();
        expect(cover.result, coverResult);
        expect(_modal, findsNothing);
        expect(controller.calls, ['decideNetwork net-home trusted']);
      });

      testWidgets('[$code] a pairing that PairingHost opens on top during the '
          '0.9 s keeps its route; the question leaves from under it, decided '
          'once and never dismissed', (tester) async {
        final controller = FakeAppController(state: _asking(const [_home]));
        await pumpMoving(tester, controller, code);

        await tester.tap(modalButtonIn(question, strings.yes));
        await tester.pump(const Duration(milliseconds: 300));
        controller.emit(
          NodeState(
            paused: true,
            pausedNetworks: const [_home],
            prompts: const [_home],
            pairing: view(
              role: PairingRole.receiver,
              phase: PairingPhase.comparing,
            ),
          ),
        );
        await tester.pump();
        final pairingRoute = routeOf(tester, _modal.last);
        expect(pairingRoute.isCurrent, isTrue);
        await tester.pump(const Duration(milliseconds: 1700));

        expect(find.text(strings.networkPromptTitle), findsNothing);
        expect(_modal, findsOneWidget);
        expect(identical(routeOf(tester, _modal), pairingRoute), isTrue);
        expect(pairingRoute.isActive, isTrue);
        expect(pairingRoute.isCurrent, isTrue);
        expect(pairingRoute.animation!.status, AnimationStatus.completed);
        expect(controller.calls, ['decideNetwork net-home trusted']);
        final pairingButtons = tester
            .widgetList<ModalButton>(
              find.descendant(of: _modal, matching: find.byType(ModalButton)),
            )
            .toList();
        expect(pairingButtons, isNotEmpty);
        expect(pairingButtons.every((b) => b.onPressed != null), isTrue);
        expect(tester.takeException(), isNull);
      });

      for (final reduceMotion in const [false, true]) {
        for (final (label, decision) in [
          (strings.no, 'untrusted'),
          (strings.yes, 'trusted'),
        ]) {
          testWidgets('[$code] "$label" landing in the same frame a route is '
              'pushed on top decides $decision once, never dismisses, and '
              'leaves that route open (reduceMotion: $reduceMotion)', (
            tester,
          ) async {
            final controller = FakeAppController(state: _asking(const [_home]));
            await pumpMoving(
              tester,
              controller,
              code,
              reduceMotion: reduceMotion,
            );
            final questionRoute = routeOf(tester, question);
            final action = modalButtonAction(tester, question, label);

            final cover = pushCover(homeContext(tester));
            action();
            expect(controller.calls, ['decideNetwork net-home $decision']);
            await tester.pump();
            await tester.pump(greenTime);
            await tester.pump(routeGone);
            await tester.pump(const Duration(milliseconds: 400));

            expect(questionRoute.isActive, isFalse);
            expect(cover.finished, isFalse);
            expect(cover.taps, 0);
            expect(cover.route.isCurrent, isTrue);
            expect(find.text(strings.networkPromptTitle), findsNothing);
            expect(_modal, findsOneWidget);
            expect(controller.calls, ['decideNetwork net-home $decision']);
          });
        }
      }
    }
  });

  group('H2 the network question is off while covered by a pairing and for '
      '500 ms after (RF-11 of the 002, point 243)', () {
    for (final code in languageCodes) {
      final strings = stringsFor(code);
      final question = modalWith(strings.networkPromptTitle);
      final labels = [strings.no, strings.yes];

      List<bool> states(WidgetTester tester) =>
          modalButtonStates(tester, question, labels);

      for (final reduceMotion in const [false, true]) {
        for (final gap in const [Duration.zero, Duration(milliseconds: 120)]) {
          testWidgets('[$code] a double click on the pairing "Close" over '
              '"${strings.yes}" does not trust the network; both buttons stay '
              'off until 500 ms after the pairing leaves (reduceMotion: '
              '$reduceMotion, gap: ${gap.inMilliseconds} ms)', (tester) async {
            final controller = _ClosingController(
              state: _asking(const [_home]),
            );
            await pumpHome(
              tester,
              controller,
              code,
              settle: false,
              reduceMotion: reduceMotion,
            );
            await tester.pump();
            await tester.pump(modalTransitionDuration);
            expect(states(tester), [true, true]);

            controller.emit(
              NodeState(
                paused: true,
                pausedNetworks: const [_home],
                prompts: const [_home],
                pairing: view(
                  role: PairingRole.initiator,
                  phase: PairingPhase.finished,
                  outcome: PairingOutcome.paired,
                ),
              ),
            );
            await tester.pump();
            expect(states(tester), [false, false]);
            await tester.pump(modalTransitionDuration);
            await tester.pump(const Duration(seconds: 2));
            expect(states(tester), [false, false]);

            final close = modalButtonIn(
              modalWith(strings.outcomePaired(peerName)),
              strings.closeButton,
            );
            expect(tester.widget<ModalButton>(close).onPressed, isNotNull);
            final point = overlapCenter(
              tester,
              modalButtonIn(question, strings.yes),
              close,
            );
            await tester.tapAt(point);
            await tester.pump();
            expect(controller.calls, ['dismissPairing']);
            if (gap > Duration.zero) await tester.pump(gap);
            await tester.tapAt(point);
            await tester.pump();

            expect(controller.calls, ['dismissPairing']);
            expect(states(tester), [false, false]);

            await tester.pump(const Duration(milliseconds: 480) - gap);
            expect(states(tester), [false, false]);
            await tester.tapAt(point);
            await tester.pump();
            expect(controller.calls, ['dismissPairing']);

            await tester.pump(const Duration(milliseconds: 40));
            expect(states(tester), [true, true]);
            await tester.tapAt(point);
            await tester.pump();
            expect(controller.calls, [
              'dismissPairing',
              'decideNetwork net-home trusted',
            ]);
            await tester.pump(const Duration(milliseconds: 900));
            await tester.pump(const Duration(milliseconds: 400));
            await tester.pump();
            expect(_modal, findsNothing);
          });
        }
      }
    }
  });

  group('coverOnly: the network question has no delay and ignores the '
      'lifecycle (points 159 and 243)', () {
    final strings = stringsFor('en');
    final question = modalWith(strings.networkPromptTitle);
    final labels = [strings.no, strings.yes];

    List<bool> states(WidgetTester tester) =>
        modalButtonStates(tester, question, labels);

    for (final reduceMotion in const [false, true]) {
      testWidgets('a network that arrives has both buttons on in the very '
          'first frame of its question (reduceMotion: $reduceMotion)', (
        tester,
      ) async {
        final controller = FakeAppController(state: const NodeState());
        await pumpHome(
          tester,
          controller,
          'en',
          settle: false,
          reduceMotion: reduceMotion,
        );
        expect(_modal, findsNothing);

        controller.emit(_asking(const [_home]));
        await tester.pump();
        expect(states(tester), [true, true]);

        await tester.tap(modalButtonIn(question, strings.no));
        expect(controller.calls, ['decideNetwork net-home untrusted']);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 400));
      });
    }

    for (final target in const [
      AppLifecycleState.inactive,
      AppLifecycleState.hidden,
      AppLifecycleState.paused,
    ]) {
      testWidgets('going to ${target.name} and back keeps both buttons on', (
        tester,
      ) async {
        resumeOnTearDown(tester);
        await stepLifecycle(tester, AppLifecycleState.resumed);
        final controller = FakeAppController(state: _asking(const [_home]));
        await _pumpStill(tester, controller, 'en');

        for (final state in lifecyclePath(AppLifecycleState.resumed, target)) {
          await stepLifecycle(tester, state);
          expect(states(tester), [true, true], reason: state.name);
        }
        await tester.pump(const Duration(seconds: 1));
        expect(states(tester), [true, true]);
        for (final state in lifecyclePath(target, AppLifecycleState.resumed)) {
          await stepLifecycle(tester, state);
          expect(states(tester), [true, true], reason: state.name);
        }
        await tester.tap(modalButtonIn(question, strings.yes));
        await tester.pumpAndSettle();
        expect(controller.calls, ['decideNetwork net-home trusted']);
      });
    }

    testWidgets('a network that arrives with the app inactive has both '
        'buttons on in the first frame', (tester) async {
      resumeOnTearDown(tester);
      final controller = FakeAppController(state: const NodeState());
      await _pumpStill(tester, controller, 'en');
      await goToLifecycle(tester, AppLifecycleState.inactive);

      controller.emit(_asking(const [_home]));
      await tester.pump();
      expect(states(tester), [true, true]);
      await tester.tap(modalButtonIn(question, strings.no));
      await tester.pumpAndSettle();
      expect(controller.calls, ['decideNetwork net-home untrusted']);
    });
  });
}
