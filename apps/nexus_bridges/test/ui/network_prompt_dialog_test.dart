import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nexus_bridges/src/l10n/app_strings.dart';
import 'package:nexus_bridges_core/nexus_bridges_core.dart';

import 'fake_app_controller.dart';

const _home = NetworkPrompt('net-home', 'Casa');
const _office = NetworkPrompt('net-office', 'Oficina');

NodeState _asking(List<NetworkPrompt> prompts) {
  return NodeState(paused: true, pausedNetworks: prompts, prompts: prompts);
}

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
        await pumpHome(tester, controller, code);

        expect(find.byType(AlertDialog), findsOneWidget);
        expect(find.text(strings.networkPromptTitle), findsOneWidget);
        expect(bodyOf('Casa'), findsOneWidget);
        expect(find.text(strings.yes), findsOneWidget);
        expect(find.text(strings.no), findsOneWidget);
        expect(controller.calls, isEmpty);
      });

      testWidgets('no pending network opens no dialog', (tester) async {
        final controller = FakeAppController(state: const NodeState());
        await pumpHome(tester, controller, code);

        expect(find.byType(AlertDialog), findsNothing);
      });

      testWidgets('a network that arrives later opens the dialog', (
        tester,
      ) async {
        final controller = FakeAppController(state: const NodeState());
        await pumpHome(tester, controller, code);

        controller.emit(_asking(const [_home]));
        await tester.pumpAndSettle();

        expect(bodyOf('Casa'), findsOneWidget);
      });

      testWidgets('repeated states while open keep a single dialog', (
        tester,
      ) async {
        final controller = FakeAppController(state: _asking(const [_home]));
        await pumpHome(tester, controller, code);

        controller.emit(_asking(const [_home]));
        await tester.pumpAndSettle();
        controller.emit(_asking(const [_home, _office]));
        await tester.pumpAndSettle();

        expect(find.byType(AlertDialog), findsOneWidget);
        expect(bodyOf('Casa'), findsOneWidget);
        expect(bodyOf('Oficina'), findsNothing);
      });

      testWidgets('yes trusts the network and closes the dialog', (
        tester,
      ) async {
        final controller = FakeAppController(state: _asking(const [_home]));
        await pumpHome(tester, controller, code);

        await tester.tap(find.text(strings.yes));
        await tester.pumpAndSettle();

        expect(controller.calls, ['decideNetwork net-home trusted']);
        expect(find.byType(AlertDialog), findsNothing);
      });

      testWidgets('no marks the network untrusted and closes the dialog', (
        tester,
      ) async {
        final controller = FakeAppController(state: _asking(const [_home]));
        await pumpHome(tester, controller, code);

        await tester.tap(find.text(strings.no));
        await tester.pumpAndSettle();

        expect(controller.calls, ['decideNetwork net-home untrusted']);
        expect(find.byType(AlertDialog), findsNothing);
      });
    });

    group('[$code] RF-13 closing without an answer', () {
      testWidgets('Esc dismisses the prompt without deciding', (tester) async {
        final controller = FakeAppController(state: _asking(const [_home]));
        await pumpHome(tester, controller, code);

        await tester.sendKeyEvent(LogicalKeyboardKey.escape);
        await tester.pumpAndSettle();

        expect(controller.calls, ['dismissPrompt net-home']);
        expect(find.byType(AlertDialog), findsNothing);
      });

      testWidgets('a tap outside dismisses the prompt without deciding', (
        tester,
      ) async {
        final controller = FakeAppController(state: _asking(const [_home]));
        await pumpHome(tester, controller, code);

        await tester.tapAt(const Offset(5, 5));
        await tester.pumpAndSettle();

        expect(controller.calls, ['dismissPrompt net-home']);
        expect(find.byType(AlertDialog), findsNothing);
      });

      testWidgets('a stale state after Esc does not ask again', (tester) async {
        final controller = FakeAppController(state: _asking(const [_home]));
        await pumpHome(tester, controller, code);

        await tester.sendKeyEvent(LogicalKeyboardKey.escape);
        await tester.pumpAndSettle();
        controller.emit(_asking(const [_home]));
        await tester.pumpAndSettle();

        expect(find.byType(AlertDialog), findsNothing);
        expect(controller.calls, ['dismissPrompt net-home']);
      });

      testWidgets('the paused banner brings the question back via askAgain', (
        tester,
      ) async {
        final controller = FakeAppController(state: _asking(const [_home]));
        await pumpHome(tester, controller, code);

        await tester.sendKeyEvent(LogicalKeyboardKey.escape);
        await tester.pumpAndSettle();
        controller.emit(const NodeState(paused: true, pausedNetworks: [_home]));
        await tester.pumpAndSettle();
        expect(find.byType(AlertDialog), findsNothing);

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
        await pumpHome(tester, controller, code);

        controller.emit(const NodeState());
        await tester.pumpAndSettle();

        expect(find.byType(AlertDialog), findsNothing);
        expect(controller.calls, isEmpty);
      });

      testWidgets('the next pending network opens in its place', (
        tester,
      ) async {
        final controller = FakeAppController(
          state: _asking(const [_home, _office]),
        );
        await pumpHome(tester, controller, code);
        expect(bodyOf('Casa'), findsOneWidget);

        controller.emit(_asking(const [_office]));
        await tester.pumpAndSettle();

        expect(find.byType(AlertDialog), findsOneWidget);
        expect(bodyOf('Casa'), findsNothing);
        expect(bodyOf('Oficina'), findsOneWidget);
        expect(controller.calls, isEmpty);
      });

      testWidgets('the network can come back and is asked again', (
        tester,
      ) async {
        final controller = FakeAppController(state: _asking(const [_home]));
        await pumpHome(tester, controller, code);

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
        await pumpHome(tester, controller, code);

        await tester.tap(find.text(strings.yes));
        await tester.pumpAndSettle();
        controller.emit(_asking(const [_home]));
        await tester.pumpAndSettle();
        controller.emit(_asking(const [_home]));
        await tester.pumpAndSettle();

        expect(find.byType(AlertDialog), findsNothing);
        expect(controller.calls, ['decideNetwork net-home trusted']);
      });

      testWidgets('askAgain after leaving prompts asks once more', (
        tester,
      ) async {
        final controller = FakeAppController(state: _asking(const [_home]));
        await pumpHome(tester, controller, code);

        await tester.tap(find.text(strings.yes));
        await tester.pumpAndSettle();
        controller.emit(_asking(const [_home]));
        await tester.pumpAndSettle();
        expect(find.byType(AlertDialog), findsNothing);

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
        await pumpHome(tester, controller, code);

        expect(find.byType(AlertDialog), findsOneWidget);
        expect(bodyOf('Casa'), findsOneWidget);

        await tester.tap(find.text(strings.yes));
        await tester.pumpAndSettle();

        expect(find.byType(AlertDialog), findsOneWidget);
        expect(bodyOf('Oficina'), findsOneWidget);

        await tester.sendKeyEvent(LogicalKeyboardKey.escape);
        await tester.pumpAndSettle();

        expect(find.byType(AlertDialog), findsNothing);
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

    Finder dialogs() => find.byType(AlertDialog, skipOffstage: false);
    Finder bodyOf(String network) =>
        find.text(strings.networkPromptBody(network), skipOffstage: false);

    testWidgets('[A] then [] in the same frame leaves no dialog', (
      tester,
    ) async {
      final controller = FakeAppController(state: const NodeState());
      await pumpHome(tester, controller, 'es');

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
      await pumpHome(tester, controller, 'es');

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
      await pumpHome(tester, controller, 'es');

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
      await pumpHome(tester, controller, 'es');

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
      await pumpHome(tester, controller, 'es');
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
      await pumpHome(tester, controller, 'es');

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
        await pumpHome(tester, controller, 'es');

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
      await pumpHome(tester, controller, 'es');

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
      await pumpHome(tester, controller, 'es');

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
          await pumpHome(tester, controller, code);

          expect(tester.takeException(), isNull);
          expect(find.byType(AlertDialog), findsOneWidget);
          final context = tester.element(find.text(strings.yes));
          expect(MediaQuery.textScalerOf(context).scale(14), 28);
          expect(
            tester.getSize(find.byType(AlertDialog)).height,
            lessThanOrEqualTo(330),
          );
        });

        testWidgets('[$code] $label name: yes is reachable at 2x text', (
          tester,
        ) async {
          smallWindowWithLargeText(tester);
          final controller = FakeAppController(state: _asking([prompt]));
          await pumpHome(tester, controller, code);

          await tapReachable(tester, find.text(strings.yes));

          expect(controller.calls, [
            'decideNetwork ${prompt.networkId} trusted',
          ]);
          expect(find.byType(AlertDialog), findsNothing);
          expect(tester.takeException(), isNull);
        });

        testWidgets('[$code] $label name: no is reachable at 2x text', (
          tester,
        ) async {
          smallWindowWithLargeText(tester);
          final controller = FakeAppController(state: _asking([prompt]));
          await pumpHome(tester, controller, code);

          await tapReachable(tester, find.text(strings.no));

          expect(controller.calls, [
            'decideNetwork ${prompt.networkId} untrusted',
          ]);
          expect(find.byType(AlertDialog), findsNothing);
          expect(tester.takeException(), isNull);
        });
      }

      testWidgets('[$code] the whole question can be scrolled into view', (
        tester,
      ) async {
        smallWindowWithLargeText(tester);
        final controller = FakeAppController(state: _asking(const [longName]));
        await pumpHome(tester, controller, code);

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
        await pumpHome(tester, controller, code);
        final dialog = find.byType(AlertDialog);
        expect(dialog, findsOneWidget);
        final texts = [
          for (final text in tester.widgetList<Text>(
            find.descendant(of: dialog, matching: find.byType(Text)),
          ))
            text.data ?? '',
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
}
