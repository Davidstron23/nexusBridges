import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nexus_bridges/src/l10n/app_strings.dart';
import 'package:nexus_bridges/src/ui/diagram/flow_diagram.dart';
import 'package:nexus_bridges/src/ui/send_menu.dart';
import 'package:nexus_bridges_core/nexus_bridges_core.dart';

import 'fake_app_controller.dart';
import 'pairing_fixtures.dart';

final String _fpA = fingerprintOf('AAAA1111');
final String _fpB = fingerprintOf('BBBB2222');
final String _fpC = fingerprintOf('CCCC3333');

const Duration _menuIn = Duration(milliseconds: 240);

NodeState _state({
  String? sendingTo,
  bool pickerOpen = false,
  bool hiddenC = false,
  bool mismatchC = false,
}) {
  return NodeState(
    entries: [
      entry(fingerprint: _fpA, name: 'PC principal', paired: true),
      entry(fingerprint: _fpB, name: 'Torre', paired: true),
      entry(
        fingerprint: _fpC,
        name: 'Portatil',
        paired: true,
        visible: !hiddenC,
        mismatch: mismatchC,
      ),
      entry(fingerprint: fingerprintOf('DDDD4444'), name: 'Movil'),
    ],
    sendingTo: sendingTo,
    pickerOpen: pickerOpen,
  );
}

Future<FakeAppController> _pump(
  WidgetTester tester,
  String code,
  NodeState state,
) async {
  tester.view.physicalSize = const Size(800, 900);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final controller = FakeAppController(state: state);
  await pumpHome(tester, controller, code);
  return controller;
}

Finder _row(String fingerprint) => find.byKey(ValueKey(fingerprint));

Finder _send(AppStrings strings, String fingerprint) => find.ancestor(
  of: find.descendant(
    of: _row(fingerprint),
    matching: find.text(strings.sendEllipsis),
  ),
  matching: find.byWidgetPredicate((widget) => widget is ButtonStyleButton),
);

bool _enabled(WidgetTester tester, Finder button) =>
    tester.widget<ButtonStyleButton>(button).enabled;

final Finder _panel = find.byKey(const ValueKey('send-menu-panel'));

void main() {
  for (final code in languageCodes) {
    final strings = stringsFor(code);

    group('[$code] E540 "Send…" in the row (RF-249, RF-290)', () {
      testWidgets('active for a device that can receive and nobody else is '
          'being sent to', (tester) async {
        await _pump(tester, code, _state());

        expect(_enabled(tester, _send(strings, _fpA)), isTrue);
        expect(_enabled(tester, _send(strings, _fpB)), isTrue);
        expect(find.text(strings.waitForQueues('PC principal')), findsNothing);
      });

      testWidgets('an unpaired device has no Send…', (tester) async {
        await _pump(tester, code, _state());

        expect(find.text(strings.sendEllipsis), findsNWidgets(3));
        expect(
          find.descendant(
            of: _row(fingerprintOf('DDDD4444')),
            matching: find.text(strings.sendEllipsis),
          ),
          findsNothing,
        );
      });

      testWidgets('with queues to A: active for A, off for the others with '
          '"wait for the sends to A"', (tester) async {
        await _pump(tester, code, _state(sendingTo: _fpA));

        expect(_enabled(tester, _send(strings, _fpA)), isTrue);
        expect(_enabled(tester, _send(strings, _fpB)), isFalse);
        expect(_enabled(tester, _send(strings, _fpC)), isFalse);
        expect(
          find.descendant(
            of: _row(_fpB),
            matching: find.text(strings.waitForQueues('PC principal')),
          ),
          findsOneWidget,
        );
        expect(
          find.descendant(
            of: _row(_fpA),
            matching: find.text(strings.waitForQueues('PC principal')),
          ),
          findsNothing,
        );
      });

      testWidgets('not visible and mismatch keep the explanations of '
          'always, and win over the queue one', (tester) async {
        await _pump(tester, code, _state(sendingTo: _fpA, hiddenC: true));
        expect(_enabled(tester, _send(strings, _fpC)), isFalse);
        expect(
          find.descendant(
            of: _row(_fpC),
            matching: find.text(strings.sendNeedsVisible),
          ),
          findsOneWidget,
        );

        await _pump(tester, code, _state(mismatchC: true));
        expect(_enabled(tester, _send(strings, _fpC)), isFalse);
        expect(
          find.descendant(
            of: _row(_fpC),
            matching: find.text(strings.sendNeedsPairAgain),
          ),
          findsOneWidget,
        );
      });

      testWidgets('with a Windows picker open every Send… waits, with no '
          'explanation', (tester) async {
        await _pump(tester, code, _state(pickerOpen: true));

        for (final fp in [_fpA, _fpB, _fpC]) {
          expect(_enabled(tester, _send(strings, fp)), isFalse);
        }
        for (final name in ['PC principal', 'Torre', 'Portatil']) {
          expect(find.text(strings.waitForQueues(name)), findsNothing);
        }
      });
    });

    group('[$code] E541 the two ways of "Send…" (RF-250)', () {
      testWidgets('the menu offers Files… and Folders… and sends nothing '
          'until one is chosen', (tester) async {
        final controller = await _pump(tester, code, _state());

        await tester.tap(_send(strings, _fpA));
        await tester.pump();
        await tester.pump(_menuIn);

        expect(_panel, findsOneWidget);
        expect(
          find.descendant(
            of: _panel,
            matching: find.text(strings.sendFilesOption),
          ),
          findsOneWidget,
        );
        expect(
          find.descendant(
            of: _panel,
            matching: find.text(strings.sendFoldersOption),
          ),
          findsOneWidget,
        );
        expect(controller.calls, isEmpty);

        await tester.tap(find.text(strings.sendFoldersOption));
        await tester.pumpAndSettle();
        expect(controller.calls, ['sendFolders $_fpA']);
        expect(_panel, findsNothing);
      });

      testWidgets('Files… asks for files for that device', (tester) async {
        final controller = await _pump(tester, code, _state());

        await tester.tap(_send(strings, _fpB));
        await tester.pump(_menuIn);
        await tester.tap(find.text(strings.sendFilesOption));
        await tester.pumpAndSettle();

        expect(controller.calls, ['sendFiles $_fpB']);
      });

      testWidgets('Esc and a tap outside close it without sending', (
        tester,
      ) async {
        final controller = await _pump(tester, code, _state());

        await tester.tap(_send(strings, _fpA));
        await tester.pump(_menuIn);
        expect(_panel, findsOneWidget);
        await tester.sendKeyEvent(LogicalKeyboardKey.escape);
        await tester.pumpAndSettle();
        expect(_panel, findsNothing);

        await tester.tap(_send(strings, _fpA));
        await tester.pump(_menuIn);
        expect(_panel, findsOneWidget);
        await tester.tapAt(const Offset(400, 880));
        await tester.pumpAndSettle();
        expect(_panel, findsNothing);
        expect(controller.calls, isEmpty);
      });

      testWidgets('the keyboard reaches both options: Enter opens on the '
          'first one and the arrow moves to the second', (tester) async {
        final controller = await _pump(tester, code, _state());

        final button = _send(strings, _fpA);
        Focus.of(
          tester.element(
            find.descendant(
              of: button,
              matching: find.text(strings.sendEllipsis),
            ),
          ),
        ).requestFocus();
        await tester.pump();
        await tester.sendKeyEvent(LogicalKeyboardKey.enter);
        await tester.pump(_menuIn);
        expect(_panel, findsOneWidget);

        await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
        await tester.pump();
        await tester.sendKeyEvent(LogicalKeyboardKey.enter);
        await tester.pumpAndSettle();

        expect(controller.calls, ['sendFolders $_fpA']);
      });

      testWidgets('the menu closes by itself if the device can no longer '
          'receive', (tester) async {
        final controller = await _pump(tester, code, _state());

        await tester.tap(_send(strings, _fpA));
        await tester.pump(_menuIn);
        expect(_panel, findsOneWidget);

        controller.emit(_state(sendingTo: _fpB));
        await tester.pumpAndSettle();

        expect(_panel, findsNothing);
        expect(_enabled(tester, _send(strings, _fpA)), isFalse);
      });
    });

    group('[$code] E540 and E541 in the popover of the diagram', () {
      Finder popoverSend() => find.descendant(
        of: find.byType(FlowDiagram),
        matching: find.text(strings.sendEllipsis),
      );

      testWidgets('with queues to another device it is off and says to wait', (
        tester,
      ) async {
        await _pump(tester, code, _state(sendingTo: _fpA));

        await tester.tap(find.byKey(ValueKey('flow-peer-$_fpB')));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 240));

        final button = find.ancestor(
          of: popoverSend(),
          matching: find.byWidgetPredicate((w) => w is ButtonStyleButton),
        );
        expect(_enabled(tester, button), isFalse);
        expect(
          find.descendant(
            of: find.byType(FlowDiagram),
            matching: find.text(strings.waitForQueues('PC principal')),
          ),
          findsOneWidget,
        );
      });

      testWidgets('with queues to that very device it stays active and its '
          'menu works', (tester) async {
        final controller = await _pump(tester, code, _state(sendingTo: _fpA));

        await tester.tap(find.byKey(ValueKey('flow-peer-$_fpA')));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 240));
        await tester.tap(popoverSend());
        await tester.pump(_menuIn);
        await tester.tap(find.text(strings.sendFilesOption));
        await tester.pumpAndSettle();

        expect(controller.calls, ['sendFiles $_fpA']);
      });
    });

    test('[$code] deviceNameIn falls back to the short fingerprint', () {
      expect(deviceNameIn(_state(), _fpA), 'PC principal');
      expect(deviceNameIn(_state(), fingerprintOf('ZZZZ9999')), 'ZZZZ9999');
    });
  }
}
