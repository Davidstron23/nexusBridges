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
