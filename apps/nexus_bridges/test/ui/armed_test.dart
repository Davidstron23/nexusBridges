import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nexus_bridges/src/l10n/app_strings.dart';
import 'package:nexus_bridges/src/ui/activity_cards.dart';
import 'package:nexus_bridges/src/ui/armed.dart';
import 'package:nexus_bridges/src/ui/incoming_cards.dart';
import 'package:nexus_bridges/src/ui/pairing_dialogs.dart' as dialogs;
import 'package:nexus_bridges_core/nexus_bridges_core.dart';

import 'fake_app_controller.dart';
import 'lifecycle_fixtures.dart';
import 'transfer_fixtures.dart';

const String _label = 'go';

Widget _armedApp(Object armKey, List<String> taps) {
  return MaterialApp(
    home: Scaffold(
      body: Armed(
        armKey: armKey,
        builder: (context, armed) => TextButton(
          onPressed: armed ? () => taps.add('tap $armKey') : null,
          child: const Text(_label),
        ),
      ),
    ),
  );
}

Finder get _button => find.widgetWithText(TextButton, _label);

bool _on(WidgetTester tester) =>
    tester.widget<TextButton>(_button).onPressed != null;

Future<void> _tapIfAny(WidgetTester tester) async {
  await tester.tap(_button, warnIfMissed: false);
  await tester.pump();
}

Future<void> _expectArmsIn500(
  WidgetTester tester,
  List<String> taps,
  String expected,
) async {
  final before = List<String>.of(taps);
  expect(_on(tester), isFalse);
  await tester.pump(justBeforeArmed);
  expect(_on(tester), isFalse);
  await _tapIfAny(tester);
  expect(taps, before);
  await tester.pump(lastMillisecond);
  expect(_on(tester), isTrue);
  await _tapIfAny(tester);
  expect(taps, [...before, expected]);
}

class _Probe extends StatefulWidget {
  const _Probe(this.taps);

  final List<String> taps;

  @override
  State<_Probe> createState() => _ProbeState();
}

class _ProbeState extends State<_Probe> with ArmingState<_Probe> {
  @override
  Widget build(BuildContext context) {
    return TextButton(
      onPressed: armed
          ? () {
              widget.taps.add('tap probe');
              setState(rearm);
            }
          : null,
      child: const Text(_label),
    );
  }
}

void main() {
  test('dialogActivationDelay is 500 ms and pairing_dialogs.dart still '
      'exports the same constant', () {
    expect(dialogActivationDelay, const Duration(milliseconds: 500));
    expect(dialogs.dialogActivationDelay, dialogActivationDelay);
    expect(
      identical(dialogs.dialogActivationDelay, dialogActivationDelay),
      isTrue,
    );
  });

  group('E274 Armed and the app lifecycle (RF-151, RF-164)', () {
    testWidgets('a null lifecycle state counts as foreground and arms at '
        '500 ms', (tester) async {
      expect(tester.binding.lifecycleState, isNull);
      final taps = <String>[];
      await tester.pumpWidget(_armedApp(1, taps));
      await _expectArmsIn500(tester, taps, 'tap 1');
    });

    testWidgets('resumed from the start arms at 500 ms', (tester) async {
      resumeOnTearDown(tester);
      await stepLifecycle(tester, AppLifecycleState.resumed);
      final taps = <String>[];
      await tester.pumpWidget(_armedApp(1, taps));
      await _expectArmsIn500(tester, taps, 'tap 1');
    });

    for (final target in [
      AppLifecycleState.inactive,
      AppLifecycleState.hidden,
      AppLifecycleState.paused,
    ]) {
      testWidgets('going to ${target.name} disarms at once and every step '
          'back stays off until 500 ms after resumed', (tester) async {
        resumeOnTearDown(tester);
        await stepLifecycle(tester, AppLifecycleState.resumed);
        final taps = <String>[];
        await tester.pumpWidget(_armedApp(1, taps));
        await tester.pump(dialogActivationDelay);
        expect(_on(tester), isTrue);

        for (final state in lifecyclePath(AppLifecycleState.resumed, target)) {
          await stepLifecycle(tester, state);
          expect(_on(tester), isFalse, reason: state.name);
        }
        await tester.pump(const Duration(seconds: 2));
        expect(_on(tester), isFalse);
        await _tapIfAny(tester);

        for (final state in lifecyclePath(target, AppLifecycleState.inactive)) {
          await stepLifecycle(tester, state);
          await tester.pump(const Duration(seconds: 1));
          expect(_on(tester), isFalse, reason: state.name);
        }
        expect(taps, isEmpty);

        await stepLifecycle(tester, AppLifecycleState.resumed);
        await _expectArmsIn500(tester, taps, 'tap 1');
      });
    }

    testWidgets('inactive, hidden, inactive and resumed count 500 ms from '
        'the last resumed', (tester) async {
      resumeOnTearDown(tester);
      await stepLifecycle(tester, AppLifecycleState.resumed);
      final taps = <String>[];
      await tester.pumpWidget(_armedApp(1, taps));
      await tester.pump(dialogActivationDelay);

      await stepLifecycle(tester, AppLifecycleState.inactive);
      await stepLifecycle(tester, AppLifecycleState.hidden);
      await stepLifecycle(tester, AppLifecycleState.inactive);
      expect(_on(tester), isFalse);
      await stepLifecycle(tester, AppLifecycleState.resumed);
      await tester.pump(const Duration(milliseconds: 300));
      expect(_on(tester), isFalse);
      await stepLifecycle(tester, AppLifecycleState.inactive);
      await tester.pump(const Duration(milliseconds: 400));
      expect(_on(tester), isFalse);
      await _tapIfAny(tester);
      expect(taps, isEmpty);

      await stepLifecycle(tester, AppLifecycleState.resumed);
      await _expectArmsIn500(tester, taps, 'tap 1');
    });

    testWidgets('a widget that appears with the app inactive does not arm '
        'until 500 ms after resumed', (tester) async {
      resumeOnTearDown(tester);
      await goToLifecycle(tester, AppLifecycleState.inactive);
      final taps = <String>[];
      await tester.pumpWidget(_armedApp(1, taps));
      await tester.pump(const Duration(seconds: 2));
      expect(_on(tester), isFalse);
      await _tapIfAny(tester);
      expect(taps, isEmpty);

      await stepLifecycle(tester, AppLifecycleState.resumed);
      await _expectArmsIn500(tester, taps, 'tap 1');
    });

    testWidgets('a key change with the app inactive does not arm', (
      tester,
    ) async {
      resumeOnTearDown(tester);
      await stepLifecycle(tester, AppLifecycleState.resumed);
      final taps = <String>[];
      await tester.pumpWidget(_armedApp(1, taps));
      await tester.pump(dialogActivationDelay);
      expect(_on(tester), isTrue);

      await stepLifecycle(tester, AppLifecycleState.inactive);
      await tester.pumpWidget(_armedApp(2, taps));
      await tester.pump(const Duration(seconds: 2));
      expect(_on(tester), isFalse);
      await _tapIfAny(tester);
      expect(taps, isEmpty);

      await stepLifecycle(tester, AppLifecycleState.resumed);
      await _expectArmsIn500(tester, taps, 'tap 2');
    });

    testWidgets('a key change while resumed still rearms for 500 ms', (
      tester,
    ) async {
      resumeOnTearDown(tester);
      await stepLifecycle(tester, AppLifecycleState.resumed);
      final taps = <String>[];
      await tester.pumpWidget(_armedApp(1, taps));
      await tester.pump(dialogActivationDelay);
      await tester.pumpWidget(_armedApp(2, taps));
      await _expectArmsIn500(tester, taps, 'tap 2');
    });

    testWidgets('a widget removed while counting leaves no timer and ignores '
        'later lifecycle changes', (tester) async {
      resumeOnTearDown(tester);
      await stepLifecycle(tester, AppLifecycleState.resumed);
      await tester.pumpWidget(_armedApp(1, <String>[]));
      await tester.pump(const Duration(milliseconds: 100));
      await tester.pumpWidget(const SizedBox());
      await stepLifecycle(tester, AppLifecycleState.inactive);
      await stepLifecycle(tester, AppLifecycleState.resumed);
      expect(tester.takeException(), isNull);
    });

    testWidgets('ArmingState: rearm inside setState disarms for 500 ms', (
      tester,
    ) async {
      final taps = <String>[];
      await tester.pumpWidget(MaterialApp(home: Scaffold(body: _Probe(taps))));
      expect(_on(tester), isFalse);
      await tester.pump(dialogActivationDelay);
      await _tapIfAny(tester);
      expect(taps, ['tap probe']);
      await _expectArmsIn500(tester, taps, 'tap probe');
    });

    for (final code in languageCodes) {
      final strings = stringsFor(code);

      testWidgets('[$code] the warning card disarms with the lifecycle and '
          'rearms 500 ms after resumed', (tester) async {
        resumeOnTearDown(tester);
        await stepLifecycle(tester, AppLifecycleState.resumed);
        final controller = await pumpColumn(
          tester,
          code,
          NodeState(incoming: incomingView()),
          (controller, state) =>
              IncomingCards(controller: controller, state: state),
        );
        final cards = find.byType(IncomingCards);
        await arm(tester);
        expect(buttonStates(tester, cards), [true, true]);

        await stepLifecycle(tester, AppLifecycleState.inactive);
        expect(buttonStates(tester, cards), [false, false]);
        await tester.pump(const Duration(seconds: 1));
        await tester.tap(
          buttonIn(cards, strings.acceptButton),
          warnIfMissed: false,
        );
        await tester.pump();
        expect(controller.calls, isEmpty);

        await stepLifecycle(tester, AppLifecycleState.resumed);
        await tester.pump(justBeforeArmed);
        expect(buttonStates(tester, cards), [false, false]);
        await tester.pump(lastMillisecond);
        expect(buttonStates(tester, cards), [true, true]);
        await tester.tap(buttonIn(cards, strings.acceptButton));
        await tester.pump();
        expect(controller.calls, ['answerIncoming s1 true']);
      });

      testWidgets('[$code] a warning that appears in the background does not '
          'arm until 500 ms after resumed', (tester) async {
        resumeOnTearDown(tester);
        await goToLifecycle(tester, AppLifecycleState.inactive);
        final controller = await pumpColumn(
          tester,
          code,
          const NodeState(),
          (controller, state) =>
              IncomingCards(controller: controller, state: state),
        );
        final cards = find.byType(IncomingCards);
        controller.emit(NodeState(incoming: incomingView()));
        await tester.pump();
        await tester.pump(const Duration(seconds: 2));
        expect(buttonStates(tester, cards), [false, false]);

        await stepLifecycle(tester, AppLifecycleState.resumed);
        await tester.pump(justBeforeArmed);
        expect(buttonStates(tester, cards), [false, false]);
        await tester.pump(lastMillisecond);
        expect(buttonStates(tester, cards), [true, true]);
      });

      testWidgets('[$code] Cancel of the outgoing card also disarms '
          '(RF-164)', (tester) async {
        resumeOnTearDown(tester);
        await stepLifecycle(tester, AppLifecycleState.resumed);
        final controller = await pumpColumn(
          tester,
          code,
          NodeState(outgoing: outgoingView()),
          (controller, state) =>
              ActivityPanel(controller: controller, state: state),
        );
        final card = find.byKey(const ValueKey('activity-outgoing'));
        final cancel = buttonIn(card, strings.cancelButton);
        await arm(tester);
        expect(isEnabled(tester, cancel), isTrue);

        await stepLifecycle(tester, AppLifecycleState.inactive);
        expect(isEnabled(tester, cancel), isFalse);
        await stepLifecycle(tester, AppLifecycleState.hidden);
        await tester.pump(const Duration(seconds: 1));
        expect(isEnabled(tester, cancel), isFalse);
        await tester.tap(cancel, warnIfMissed: false);
        await tester.pump();
        expect(controller.calls, isEmpty);

        await stepLifecycle(tester, AppLifecycleState.inactive);
        await stepLifecycle(tester, AppLifecycleState.resumed);
        await tester.pump(justBeforeArmed);
        expect(isEnabled(tester, cancel), isFalse);
        await tester.pump(lastMillisecond);
        expect(isEnabled(tester, cancel), isTrue);
        await tester.tap(cancel);
        await tester.pump();
        expect(controller.calls, ['cancelSending']);
      });
    }
  });
}
