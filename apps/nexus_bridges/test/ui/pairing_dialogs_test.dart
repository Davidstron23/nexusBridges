import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nexus_bridges/main.dart';
import 'package:nexus_bridges/src/l10n/app_strings.dart';
import 'package:nexus_bridges/src/ui/pairing_dialogs.dart';
import 'package:nexus_bridges_core/nexus_bridges_core.dart';

import 'fake_app_controller.dart';
import 'pairing_fixtures.dart';

final String _oldFingerprint = fingerprintOf('9999AAAA');
const String _oldName = 'Portátil de Ana · 9999AAAA';

final MineQuestion _mine = MineQuestion(
  fingerprint: peerFingerprint,
  deviceName: peerName,
);

final ReplaceQuestion _replace = ReplaceQuestion(
  fingerprint: peerFingerprint,
  deviceName: peerName,
  oldFingerprint: _oldFingerprint,
  oldName: _oldName,
);

NodeState _with({
  PairingView? pairing,
  List<PairingQuestion>? questions,
  String? namesake,
}) {
  return pairingState(
    pairing: pairing,
    questions: questions ?? const [],
    namesake: namesake,
  );
}

Future<FakeAppController> _pumpWith(
  WidgetTester tester,
  String code, {
  PairingView? pairing,
  List<PairingQuestion>? questions,
  String? namesake,
}) async {
  final controller = FakeAppController(
    state: _with(pairing: pairing, questions: questions, namesake: namesake),
  );
  await pumpHome(
    tester,
    controller,
    code,
    settle: pairing?.phase != PairingPhase.connecting,
  );
  await tester.pump(dialogActivationDelay);
  return controller;
}

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
    PairingOutcome.failed => s.outcomeFailed(name),
    PairingOutcome.notSaved => s.outcomeNotSaved,
    null => s.outcomeFailed(name),
  };
}

Future<void> _escape(WidgetTester tester, {bool settle = true}) async {
  await tester.sendKeyEvent(LogicalKeyboardKey.escape);
  if (settle) {
    await tester.pumpAndSettle();
  } else {
    await pumpFrames(tester);
  }
}

Future<void> _tapOutside(WidgetTester tester, {bool settle = true}) async {
  await tester.tapAt(const Offset(5, 5));
  if (settle) {
    await tester.pumpAndSettle();
  } else {
    await pumpFrames(tester);
  }
}

Future<FakeAppController> _openLater(
  WidgetTester tester,
  String code,
  NodeState state,
) async {
  final controller = FakeAppController(state: const NodeState());
  await pumpHome(tester, controller, code);
  expect(dialog, findsNothing);
  controller.emit(state);
  await tester.pump();
  expect(dialog, findsOneWidget);
  return controller;
}

Future<void> _wait(WidgetTester tester, int milliseconds) =>
    tester.pump(Duration(milliseconds: milliseconds));

Future<void> _tapNow(WidgetTester tester, String label) async {
  await tapInDialog(tester, label);
  await tester.pump();
}

bool _enabled(WidgetTester tester, String label) {
  final button = tester.widget<ButtonStyleButton>(
    find.ancestor(
      of: find.descendant(of: dialog, matching: find.text(label)),
      matching: find.byWidgetPredicate((widget) => widget is ButtonStyleButton),
    ),
  );
  return button.onPressed != null;
}

Map<String, bool> _buttonStates(WidgetTester tester) => {
  for (final label in dialogButtons(tester)) label: _enabled(tester, label),
};

Color? _colorOf(WidgetTester tester, String text) =>
    tester.widget<Text>(find.text(text)).style?.color;

Color _errorColor(WidgetTester tester, String text) =>
    Theme.of(tester.element(find.text(text))).colorScheme.error;

void main() {
  group('RF-86 formatCode', () {
    test('groups the six digits in two groups of three', () {
      expect(formatCode('482913'), '482 913');
      expect(formatCode('000000'), '000 000');
      expect(formatCode('100001'), '100 001');
    });
  });

  for (final code in languageCodes) {
    final strings = stringsFor(code);

    group('[$code] C82 initiator dialog (RF-72, RF-73, RF-86)', () {
      testWidgets('connecting shows the name, a progress indicator and '
          'Cancel', (tester) async {
        final controller = await _pumpWith(
          tester,
          code,
          pairing: view(
            role: PairingRole.initiator,
            phase: PairingPhase.connecting,
          ),
        );

        expect(dialog, findsOneWidget);
        expect(find.text(strings.pairingWithTitle(peerName)), findsOneWidget);
        expect(find.text(strings.connectingTo(peerName)), findsOneWidget);
        expect(
          find.descendant(
            of: dialog,
            matching: find.byType(CircularProgressIndicator),
          ),
          findsOneWidget,
        );
        expect(dialogButtons(tester), [strings.cancelButton]);
        expect(find.textContaining(RegExp(r'\d{3} \d{3}')), findsNothing);

        await tapInDialog(tester, strings.cancelButton);
        await pumpFrames(tester);

        expect(controller.calls, ['cancelPairing']);
      });

      testWidgets('comparing shows the grouped code and three answers', (
        tester,
      ) async {
        final controller = await _pumpWith(
          tester,
          code,
          pairing: view(
            role: PairingRole.initiator,
            phase: PairingPhase.comparing,
          ),
        );

        expect(find.text(strings.pairingWithTitle(peerName)), findsOneWidget);
        expect(find.text(strings.compareCode(peerName)), findsOneWidget);
        expect(find.text(formattedCode), findsOneWidget);
        expect(find.text(rawCode), findsNothing);
        expect(dialogButtons(tester), [
          strings.cancelButton,
          strings.doesNotMatchButton,
          strings.matchesButton,
        ]);
        expect(find.text(strings.ignoreDeviceButton), findsNothing);
        expect(find.text(strings.fingerprintLine(peerShort)), findsNothing);
        expect(controller.calls, isEmpty);
      });

      testWidgets('each answer of the initiator goes to its method', (
        tester,
      ) async {
        final controller = await _pumpWith(
          tester,
          code,
          pairing: view(
            role: PairingRole.initiator,
            phase: PairingPhase.comparing,
          ),
        );

        await tapInDialog(tester, strings.cancelButton);
        await tester.pumpAndSettle();
        await tapInDialog(tester, strings.doesNotMatchButton);
        await tester.pumpAndSettle();
        await tapInDialog(tester, strings.matchesButton);
        await tester.pumpAndSettle();

        expect(controller.calls, [
          'cancelPairing',
          'answerCode false',
          'answerCode true',
        ]);
      });

      testWidgets('waitingPeer shows the code and the wait text with no '
          'buttons, not even Cancel', (tester) async {
        await _pumpWith(
          tester,
          code,
          pairing: view(
            role: PairingRole.initiator,
            phase: PairingPhase.waitingPeer,
          ),
        );

        expect(find.text(strings.pairingWithTitle(peerName)), findsOneWidget);
        expect(find.text(formattedCode), findsOneWidget);
        expect(find.text(strings.waitingForPeer(peerName)), findsOneWidget);
        expect(find.text(strings.compareCode(peerName)), findsNothing);
        expect(dialogButtons(tester), isEmpty);
      });

      for (final missing in [null, '']) {
        testWidgets(
          'a peer without name (${missing == null ? 'null' : 'empty'}) '
          'is named by its short fingerprint',
          (tester) async {
            await _pumpWith(
              tester,
              code,
              pairing: view(
                role: PairingRole.initiator,
                phase: PairingPhase.comparing,
                name: missing,
              ),
            );

            expect(
              find.text(strings.pairingWithTitle(peerShort)),
              findsOneWidget,
            );
            expect(find.text(strings.compareCode(peerShort)), findsOneWidget);
            expect(find.textContaining(peerFingerprint), findsNothing);
          },
        );
      }

      testWidgets('Esc and a tap outside do not close the dialog', (
        tester,
      ) async {
        final controller = await _pumpWith(
          tester,
          code,
          pairing: view(
            role: PairingRole.initiator,
            phase: PairingPhase.comparing,
          ),
        );

        await _escape(tester);
        await _tapOutside(tester);

        expect(dialog, findsOneWidget);
        expect(find.text(formattedCode), findsOneWidget);
        expect(controller.calls, isEmpty);
      });

      testWidgets('Esc does not close the connecting dialog either', (
        tester,
      ) async {
        final controller = await _pumpWith(
          tester,
          code,
          pairing: view(
            role: PairingRole.initiator,
            phase: PairingPhase.connecting,
          ),
        );

        await _escape(tester, settle: false);
        await _tapOutside(tester, settle: false);

        expect(find.text(strings.connectingTo(peerName)), findsOneWidget);
        expect(controller.calls, isEmpty);
      });

      testWidgets('one dialog follows every phase and closes when the view '
          'goes away', (tester) async {
        final controller = await _pumpWith(tester, code);
        expect(dialog, findsNothing);

        controller.emit(
          _with(
            pairing: view(
              role: PairingRole.initiator,
              phase: PairingPhase.connecting,
            ),
          ),
        );
        await pumpFrames(tester);
        expect(dialog, findsOneWidget);
        expect(find.text(strings.connectingTo(peerName)), findsOneWidget);

        for (final phase in [
          PairingPhase.comparing,
          PairingPhase.waitingPeer,
        ]) {
          controller.emit(
            _with(
              pairing: view(role: PairingRole.initiator, phase: phase),
            ),
          );
          await tester.pumpAndSettle();
          expect(dialog, findsOneWidget);
          expect(find.text(formattedCode), findsOneWidget);
        }
        expect(find.text(strings.waitingForPeer(peerName)), findsOneWidget);

        controller.emit(
          _with(
            pairing: view(
              role: PairingRole.initiator,
              phase: PairingPhase.finished,
              outcome: PairingOutcome.paired,
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(dialog, findsOneWidget);
        expect(find.text(strings.pairingResultTitle), findsOneWidget);

        controller.emit(_with());
        await tester.pumpAndSettle();
        expect(dialog, findsNothing);
        expect(controller.calls, isEmpty);
      });

      testWidgets('repeated states keep a single dialog', (tester) async {
        final pairing = view(
          role: PairingRole.initiator,
          phase: PairingPhase.comparing,
        );
        final controller = await _pumpWith(tester, code, pairing: pairing);

        for (var i = 0; i < 3; i++) {
          controller.emit(_with(pairing: pairing));
          await tester.pumpAndSettle();
        }

        expect(dialog, findsOneWidget);
      });
    });

    group('[$code] C83 receiver notice (RF-83, RF-84, RF-85, RF-86)', () {
      testWidgets('comparing shows name, short fingerprint, code and three '
          'answers', (tester) async {
        await _pumpWith(
          tester,
          code,
          pairing: view(
            role: PairingRole.receiver,
            phase: PairingPhase.comparing,
          ),
        );

        expect(
          find.text(strings.pairingRequestTitle(peerName)),
          findsOneWidget,
        );
        expect(find.text(strings.fingerprintLine(peerShort)), findsOneWidget);
        expect(find.text(strings.compareCode(peerName)), findsOneWidget);
        expect(find.text(formattedCode), findsOneWidget);
        expect(find.text(strings.alreadyPairedNote), findsNothing);
        expect(dialogButtons(tester), [
          strings.ignoreDeviceButton,
          strings.doesNotMatchButton,
          strings.matchesButton,
        ]);
        expect(find.text(strings.cancelButton), findsNothing);
        expect(find.textContaining(peerFingerprint), findsNothing);
      });

      testWidgets('each answer of the receiver goes to answerRequest', (
        tester,
      ) async {
        final controller = await _pumpWith(
          tester,
          code,
          pairing: view(
            role: PairingRole.receiver,
            phase: PairingPhase.comparing,
          ),
        );

        await tapInDialog(tester, strings.ignoreDeviceButton);
        await tester.pumpAndSettle();
        await tapInDialog(tester, strings.doesNotMatchButton);
        await tester.pumpAndSettle();
        await tapInDialog(tester, strings.matchesButton);
        await tester.pumpAndSettle();

        expect(controller.calls, [
          'answerRequest ignore',
          'answerRequest mismatch',
          'answerRequest matches',
        ]);
      });

      testWidgets('an initiator already paired shows the note and only two '
          'answers', (tester) async {
        final controller = await _pumpWith(
          tester,
          code,
          pairing: view(
            role: PairingRole.receiver,
            phase: PairingPhase.comparing,
            alreadyPaired: true,
          ),
        );

        expect(find.text(strings.alreadyPairedNote), findsOneWidget);
        expect(find.text(strings.fingerprintLine(peerShort)), findsOneWidget);
        expect(find.text(formattedCode), findsOneWidget);
        expect(dialogButtons(tester), [
          strings.doesNotMatchButton,
          strings.matchesButton,
        ]);
        expect(find.text(strings.ignoreDeviceButton), findsNothing);

        await tapInDialog(tester, strings.matchesButton);
        await tester.pumpAndSettle();
        expect(controller.calls, ['answerRequest matches']);
      });

      testWidgets('waitingPeer shows the code and receiverWaiting with no '
          'buttons', (tester) async {
        await _pumpWith(
          tester,
          code,
          pairing: view(
            role: PairingRole.receiver,
            phase: PairingPhase.waitingPeer,
          ),
        );

        expect(
          find.text(strings.pairingRequestTitle(peerName)),
          findsOneWidget,
        );
        expect(find.text(formattedCode), findsOneWidget);
        expect(find.text(strings.receiverWaiting(peerName)), findsOneWidget);
        expect(dialogButtons(tester), isEmpty);
      });

      testWidgets('a request without name is titled by its short '
          'fingerprint', (tester) async {
        await _pumpWith(
          tester,
          code,
          pairing: view(
            role: PairingRole.receiver,
            phase: PairingPhase.comparing,
            name: null,
          ),
        );

        expect(
          find.text(strings.pairingRequestTitle(peerShort)),
          findsOneWidget,
        );
        expect(find.text(strings.fingerprintLine(peerShort)), findsOneWidget);
      });

      testWidgets('Esc and a tap outside do not close the notice', (
        tester,
      ) async {
        final controller = await _pumpWith(
          tester,
          code,
          pairing: view(
            role: PairingRole.receiver,
            phase: PairingPhase.comparing,
          ),
        );

        await _escape(tester);
        expect(dialog, findsOneWidget);
        await _tapOutside(tester);
        expect(dialog, findsOneWidget);
        await _escape(tester);

        expect(
          find.text(strings.pairingRequestTitle(peerName)),
          findsOneWidget,
        );
        expect(controller.calls, isEmpty);
      });

      testWidgets('Esc does not close the wait after confirming', (
        tester,
      ) async {
        final controller = await _pumpWith(
          tester,
          code,
          pairing: view(
            role: PairingRole.receiver,
            phase: PairingPhase.waitingPeer,
          ),
        );

        await _escape(tester);
        await _tapOutside(tester);

        expect(find.text(strings.receiverWaiting(peerName)), findsOneWidget);
        expect(controller.calls, isEmpty);
      });
    });

    group('[$code] C84 results (RF-90 and the other outcomes)', () {
      for (final outcome in [...PairingOutcome.values, null]) {
        testWidgets('${outcome?.name ?? 'no outcome'} shows the result title, '
            'its text and Close', (tester) async {
          final controller = await _pumpWith(
            tester,
            code,
            pairing: view(
              role: PairingRole.initiator,
              phase: PairingPhase.finished,
              outcome: outcome,
            ),
          );

          expect(find.text(strings.pairingResultTitle), findsOneWidget);
          expect(
            find.text(_outcomeText(strings, outcome, peerName)),
            findsOneWidget,
          );
          expect(dialogButtons(tester), [strings.closeButton]);
          expect(find.text(formattedCode), findsNothing);

          await tapInDialog(tester, strings.closeButton);
          await tester.pumpAndSettle();
          expect(controller.calls, ['dismissPairing']);

          controller.emit(_with());
          await tester.pumpAndSettle();
          expect(dialog, findsNothing);
        });
      }

      testWidgets('C114: paused says the receiver is not accepting pairings '
          'for a few minutes, not that it refused, and offers only Close', (
        tester,
      ) async {
        final controller = await _pumpWith(
          tester,
          code,
          pairing: view(
            role: PairingRole.initiator,
            phase: PairingPhase.finished,
            outcome: PairingOutcome.paused,
          ),
        );

        expect(find.text(strings.outcomePaused(peerName)), findsOneWidget);
        expect(find.text(strings.outcomeRejected(peerName)), findsNothing);
        expect(find.text(strings.outcomeFailed(peerName)), findsNothing);
        expect(dialogButtons(tester), [strings.closeButton]);
        expect(find.text(strings.retryButton), findsNothing);

        await tapInDialog(tester, strings.closeButton);
        await tester.pumpAndSettle();
        expect(controller.calls, ['dismissPairing']);
      });

      testWidgets('expired in the receiver says it has expired', (
        tester,
      ) async {
        await _pumpWith(
          tester,
          code,
          pairing: view(
            role: PairingRole.receiver,
            phase: PairingPhase.finished,
            outcome: PairingOutcome.expired,
          ),
        );

        expect(find.text(strings.outcomeExpired), findsOneWidget);
        expect(dialogButtons(tester), [strings.closeButton]);
      });

      testWidgets('a result without peer name uses the short fingerprint', (
        tester,
      ) async {
        await _pumpWith(
          tester,
          code,
          pairing: view(
            role: PairingRole.receiver,
            phase: PairingPhase.finished,
            outcome: PairingOutcome.lost,
            name: null,
          ),
        );

        expect(find.text(strings.outcomeLost(peerShort)), findsOneWidget);
      });

      testWidgets('Esc does not dismiss a result', (tester) async {
        final controller = await _pumpWith(
          tester,
          code,
          pairing: view(
            role: PairingRole.initiator,
            phase: PairingPhase.finished,
            outcome: PairingOutcome.rejected,
          ),
        );

        await _escape(tester);
        await _tapOutside(tester);

        expect(find.text(strings.outcomeRejected(peerName)), findsOneWidget);
        expect(controller.calls, isEmpty);
      });
    });

    group('[$code] C85 is it yours? (RF-98, RF-99, RF-100)', () {
      testWidgets('the question shows the name and both answers', (
        tester,
      ) async {
        final controller = await _pumpWith(tester, code, questions: [_mine]);

        expect(find.text(strings.mineTitle(peerName)), findsOneWidget);
        expect(find.text(strings.mineBody), findsOneWidget);
        expect(dialogButtons(tester), [
          strings.mineNoButton,
          strings.mineYesButton,
        ]);
        expect(controller.calls, isEmpty);
      });

      testWidgets('It is mine calls answerMine with true and closes', (
        tester,
      ) async {
        final controller = await _pumpWith(tester, code, questions: [_mine]);

        await tapInDialog(tester, strings.mineYesButton);
        await tester.pumpAndSettle();

        expect(controller.calls, ['answerMine $peerFingerprint true']);
        expect(dialog, findsNothing);
      });

      testWidgets('Someone else calls answerMine with false', (tester) async {
        final controller = await _pumpWith(tester, code, questions: [_mine]);

        await tapInDialog(tester, strings.mineNoButton);
        await tester.pumpAndSettle();

        expect(controller.calls, ['answerMine $peerFingerprint false']);
        expect(dialog, findsNothing);
      });

      testWidgets('Esc leaves it as someone else\'s', (tester) async {
        final controller = await _pumpWith(tester, code, questions: [_mine]);

        await _escape(tester);

        expect(controller.calls, ['answerMine $peerFingerprint false']);
        expect(dialog, findsNothing);
      });

      testWidgets('a tap outside leaves it as someone else\'s', (tester) async {
        final controller = await _pumpWith(tester, code, questions: [_mine]);

        await _tapOutside(tester);

        expect(controller.calls, ['answerMine $peerFingerprint false']);
        expect(dialog, findsNothing);
      });

      testWidgets('an answered question is not asked again by a stale state', (
        tester,
      ) async {
        final controller = await _pumpWith(tester, code, questions: [_mine]);

        await tapInDialog(tester, strings.mineYesButton);
        await tester.pumpAndSettle();
        controller.emit(_with(questions: [_mine]));
        await tester.pumpAndSettle();

        expect(dialog, findsNothing);
        expect(controller.calls, ['answerMine $peerFingerprint true']);
      });

      testWidgets('the question waits until the result is closed', (
        tester,
      ) async {
        final controller = await _pumpWith(
          tester,
          code,
          pairing: view(
            role: PairingRole.receiver,
            phase: PairingPhase.finished,
            outcome: PairingOutcome.paired,
          ),
          questions: [_mine],
        );

        expect(find.text(strings.pairingResultTitle), findsOneWidget);
        expect(find.text(strings.mineTitle(peerName)), findsNothing);

        controller.emit(_with(questions: [_mine]));
        await tester.pumpAndSettle();

        expect(dialog, findsOneWidget);
        expect(find.text(strings.mineTitle(peerName)), findsOneWidget);
        expect(controller.calls, isEmpty);
      });

      testWidgets('a new pairing closes the open question without answering '
          'and it comes back afterwards', (tester) async {
        final controller = await _pumpWith(tester, code, questions: [_mine]);
        expect(find.text(strings.mineTitle(peerName)), findsOneWidget);

        controller.emit(
          _with(
            pairing: view(
              role: PairingRole.receiver,
              phase: PairingPhase.comparing,
              fingerprint: fingerprintOf('5555EEEE'),
              name: 'Otro',
            ),
            questions: [_mine],
          ),
        );
        await tester.pumpAndSettle();

        expect(dialog, findsOneWidget);
        expect(find.text(strings.pairingRequestTitle('Otro')), findsOneWidget);
        expect(find.text(strings.mineTitle(peerName)), findsNothing);
        expect(controller.calls, isEmpty);

        controller.emit(_with(questions: [_mine]));
        await tester.pumpAndSettle();

        expect(dialog, findsOneWidget);
        expect(find.text(strings.mineTitle(peerName)), findsOneWidget);
        expect(controller.calls, isEmpty);
      });
    });

    group('[$code] C86 replace? (RF-125, RF-126, RF-127)', () {
      testWidgets('the question names the new and the old device', (
        tester,
      ) async {
        await _pumpWith(tester, code, questions: [_replace]);

        expect(find.text(strings.replaceTitle(_oldName)), findsOneWidget);
        expect(
          find.text(strings.replaceBody(peerName, _oldName)),
          findsOneWidget,
        );
        expect(dialogButtons(tester), [
          strings.keepBothButton,
          strings.replaceButton,
        ]);
      });

      testWidgets('Replace calls answerReplace with true', (tester) async {
        final controller = await _pumpWith(tester, code, questions: [_replace]);

        await tapInDialog(tester, strings.replaceButton);
        await tester.pumpAndSettle();

        expect(controller.calls, ['answerReplace $peerFingerprint true']);
        expect(dialog, findsNothing);
      });

      testWidgets('Keep both calls answerReplace with false', (tester) async {
        final controller = await _pumpWith(tester, code, questions: [_replace]);

        await tapInDialog(tester, strings.keepBothButton);
        await tester.pumpAndSettle();

        expect(controller.calls, ['answerReplace $peerFingerprint false']);
      });

      testWidgets('Esc and a tap outside keep both', (tester) async {
        final controller = await _pumpWith(tester, code, questions: [_replace]);

        await _escape(tester);
        expect(controller.calls, ['answerReplace $peerFingerprint false']);
        expect(dialog, findsNothing);

        final other = ReplaceQuestion(
          fingerprint: fingerprintOf('7777BBBB'),
          deviceName: 'Torre',
          oldFingerprint: _oldFingerprint,
          oldName: _oldName,
        );
        controller.emit(_with(questions: [other]));
        await tester.pumpAndSettle();
        await _tapOutside(tester);

        expect(controller.calls, [
          'answerReplace $peerFingerprint false',
          'answerReplace ${other.fingerprint} false',
        ]);
      });

      testWidgets('replace comes before is it yours, one after the other', (
        tester,
      ) async {
        final controller = await _pumpWith(
          tester,
          code,
          questions: [_replace, _mine],
        );

        expect(find.text(strings.replaceTitle(_oldName)), findsOneWidget);
        expect(find.text(strings.mineTitle(peerName)), findsNothing);
        expect(dialog, findsOneWidget);

        await tapInDialog(tester, strings.keepBothButton);
        await tester.pumpAndSettle();

        expect(dialog, findsOneWidget);
        expect(find.text(strings.replaceTitle(_oldName)), findsNothing);
        expect(find.text(strings.mineTitle(peerName)), findsOneWidget);

        await tester.pump(dialogActivationDelay);
        await tapInDialog(tester, strings.mineYesButton);
        await tester.pumpAndSettle();

        expect(dialog, findsNothing);
        expect(controller.calls, [
          'answerReplace $peerFingerprint false',
          'answerMine $peerFingerprint true',
        ]);
      });

      testWidgets('Esc on replace then Esc on mine gives keep both and '
          'someone else\'s', (tester) async {
        final controller = await _pumpWith(
          tester,
          code,
          questions: [_replace, _mine],
        );

        await _escape(tester);
        await _escape(tester);

        expect(dialog, findsNothing);
        expect(controller.calls, [
          'answerReplace $peerFingerprint false',
          'answerMine $peerFingerprint false',
        ]);
      });
    });

    group('[$code] the app wires PairingHost (main.dart)', () {
      testWidgets('NexusBridgesApp shows the receiver notice from the state', (
        tester,
      ) async {
        final controller = _LanguageController(
          code,
          _with(
            pairing: view(
              role: PairingRole.receiver,
              phase: PairingPhase.comparing,
            ),
          ),
        );
        await tester.pumpWidget(NexusBridgesApp(controller));
        await tester.pumpAndSettle();

        expect(
          find.text(strings.pairingRequestTitle(peerName)),
          findsOneWidget,
        );
        await tester.pump(dialogActivationDelay);
        await tapInDialog(tester, strings.matchesButton);
        await tester.pumpAndSettle();

        expect(controller.calls, ['answerRequest matches']);
      });
    });

    group('[$code] C133 namesake line (RF-73, RF-83)', () {
      final warning = strings.namesakeWarning(namesakeName);

      testWidgets('the receiver comparing shows it in red right after the '
          'fingerprint line', (tester) async {
        await _pumpWith(
          tester,
          code,
          pairing: view(
            role: PairingRole.receiver,
            phase: PairingPhase.comparing,
          ),
          namesake: namesakeName,
        );

        expect(find.text(warning), findsOneWidget);
        expect(warning, contains(namesakeName));
        final texts = textsIn(tester, dialog);
        expect(texts.sublist(0, 4), [
          strings.pairingRequestTitle(peerName),
          strings.fingerprintLine(peerShort),
          warning,
          strings.compareCode(peerName),
        ]);
        expect(_colorOf(tester, warning), _errorColor(tester, warning));
        expect(dialogButtons(tester), [
          strings.ignoreDeviceButton,
          strings.doesNotMatchButton,
          strings.matchesButton,
        ]);
      });

      testWidgets('the receiver waiting shows it in red as the first line', (
        tester,
      ) async {
        await _pumpWith(
          tester,
          code,
          pairing: view(
            role: PairingRole.receiver,
            phase: PairingPhase.waitingPeer,
          ),
          namesake: namesakeName,
        );

        final texts = textsIn(tester, dialog);
        expect(texts, [
          strings.pairingRequestTitle(peerName),
          warning,
          formattedCode,
          strings.receiverWaiting(peerName),
        ]);
        expect(_colorOf(tester, warning), _errorColor(tester, warning));
      });

      for (final phase in [PairingPhase.comparing, PairingPhase.waitingPeer]) {
        testWidgets('the initiator ${phase.name} shows it in red as the first '
            'line', (tester) async {
          await _pumpWith(
            tester,
            code,
            pairing: view(role: PairingRole.initiator, phase: phase),
            namesake: namesakeName,
          );

          final texts = textsIn(tester, dialog);
          expect(texts.first, strings.pairingWithTitle(peerName));
          expect(texts[1], warning);
          expect(texts.where((text) => text == warning), hasLength(1));
          expect(_colorOf(tester, warning), _errorColor(tester, warning));
          expect(find.text(formattedCode), findsOneWidget);
        });
      }

      testWidgets('connecting does not show it', (tester) async {
        await _pumpWith(
          tester,
          code,
          pairing: view(
            role: PairingRole.initiator,
            phase: PairingPhase.connecting,
          ),
          namesake: namesakeName,
        );

        expect(find.text(strings.connectingTo(peerName)), findsOneWidget);
        expect(find.text(warning), findsNothing);
      });

      for (final role in PairingRole.values) {
        for (final outcome in [
          PairingOutcome.paired,
          PairingOutcome.rejected,
          PairingOutcome.cancelledByPeer,
        ]) {
          testWidgets('the ${role.name} result ${outcome.name} does not show '
              'it', (tester) async {
            await _pumpWith(
              tester,
              code,
              pairing: view(
                role: role,
                phase: PairingPhase.finished,
                outcome: outcome,
              ),
              namesake: namesakeName,
            );

            expect(find.text(strings.pairingResultTitle), findsOneWidget);
            expect(find.text(warning), findsNothing);
          });
        }
      }

      for (final role in PairingRole.values) {
        for (final phase in [
          PairingPhase.comparing,
          PairingPhase.waitingPeer,
        ]) {
          testWidgets('without a namesake the ${role.name} ${phase.name} has '
              'no warning line', (tester) async {
            await _pumpWith(
              tester,
              code,
              pairing: view(role: role, phase: phase),
            );

            expect(find.text(warning), findsNothing);
            final colors = [
              for (final text in tester.widgetList<Text>(
                find.descendant(of: dialog, matching: find.byType(Text)),
              ))
                text.style?.color,
            ];
            expect(colors, isNot(contains(_errorColor(tester, formattedCode))));
          });
        }
      }

      testWidgets('the line follows the state: it appears, follows the name '
          'and goes away with the result', (tester) async {
        final controller = await _pumpWith(
          tester,
          code,
          pairing: view(
            role: PairingRole.receiver,
            phase: PairingPhase.comparing,
          ),
        );
        expect(find.text(warning), findsNothing);

        controller.emit(
          _with(
            pairing: view(
              role: PairingRole.receiver,
              phase: PairingPhase.comparing,
            ),
            namesake: namesakeName,
          ),
        );
        await tester.pump();
        expect(find.text(warning), findsOneWidget);

        controller.emit(
          _with(
            pairing: view(
              role: PairingRole.receiver,
              phase: PairingPhase.comparing,
            ),
            namesake: 'Torre',
          ),
        );
        await tester.pump();
        expect(find.text(warning), findsNothing);
        expect(find.text(strings.namesakeWarning('Torre')), findsOneWidget);

        controller.emit(
          _with(
            pairing: view(
              role: PairingRole.receiver,
              phase: PairingPhase.finished,
              outcome: PairingOutcome.paired,
            ),
            namesake: 'Torre',
          ),
        );
        await tester.pump();
        expect(find.text(strings.namesakeWarning('Torre')), findsNothing);
        expect(find.text(strings.outcomePaired(peerName)), findsOneWidget);
        await tester.pump(dialogActivationDelay);
      });
    });

    group('[$code] C134 activation delay (RF-83, RF-84, RF-98, RF-125)', () {
      final receiverComparing = view(
        role: PairingRole.receiver,
        phase: PairingPhase.comparing,
      );

      testWidgets('the notice ignores It matches at 0 ms and at 499 ms and '
          'takes it at 500 ms', (tester) async {
        final controller = await _openLater(
          tester,
          code,
          _with(pairing: receiverComparing),
        );
        expect(
          find.text(strings.pairingRequestTitle(peerName)),
          findsOneWidget,
        );

        await _tapNow(tester, strings.matchesButton);
        expect(controller.calls, isEmpty);

        await _wait(tester, 499);
        await _tapNow(tester, strings.matchesButton);
        expect(controller.calls, isEmpty);
        expect(dialog, findsOneWidget);

        await _wait(tester, 1);
        await _tapNow(tester, strings.matchesButton);
        expect(controller.calls, ['answerRequest matches']);
      });

      final scenarios = <String, PairingView>{
        'initiator connecting': view(
          role: PairingRole.initiator,
          phase: PairingPhase.connecting,
        ),
        'initiator comparing': view(
          role: PairingRole.initiator,
          phase: PairingPhase.comparing,
        ),
        'receiver comparing': receiverComparing,
        'receiver already paired': view(
          role: PairingRole.receiver,
          phase: PairingPhase.comparing,
          alreadyPaired: true,
        ),
        'result': view(
          role: PairingRole.initiator,
          phase: PairingPhase.finished,
          outcome: PairingOutcome.rejected,
        ),
      };

      for (final MapEntry(key: name, value: pairing) in scenarios.entries) {
        testWidgets('$name: every button is off until 500 ms and none of the '
            'taps before counts', (tester) async {
          final controller = await _openLater(
            tester,
            code,
            _with(pairing: pairing),
          );
          final labels = dialogButtons(tester);
          expect(labels, isNotEmpty);
          expect(_buttonStates(tester).values, everyElement(isFalse));

          for (final label in labels) {
            await _tapNow(tester, label);
          }
          await _wait(tester, 499);
          expect(_buttonStates(tester).values, everyElement(isFalse));
          for (final label in labels) {
            await _tapNow(tester, label);
          }
          expect(controller.calls, isEmpty);

          await _wait(tester, 1);
          expect(_buttonStates(tester).values, everyElement(isTrue));
        });
      }

      testWidgets('a new comparing view that replaces a result rearms: It '
          'does not match at 100 ms does nothing, at 600 ms it counts', (
        tester,
      ) async {
        final controller = await _openLater(
          tester,
          code,
          _with(
            pairing: view(
              role: PairingRole.receiver,
              phase: PairingPhase.finished,
              outcome: PairingOutcome.cancelledByPeer,
            ),
          ),
        );
        await tester.pump(dialogActivationDelay);
        expect(_enabled(tester, strings.closeButton), isTrue);

        controller.emit(
          _with(
            pairing: view(
              role: PairingRole.receiver,
              phase: PairingPhase.comparing,
              fingerprint: fingerprintOf('5555EEEE'),
              name: 'Otro',
            ),
          ),
        );
        await tester.pump();
        expect(find.text(strings.pairingRequestTitle('Otro')), findsOneWidget);
        expect(_buttonStates(tester).values, everyElement(isFalse));

        await _wait(tester, 100);
        await _tapNow(tester, strings.doesNotMatchButton);
        expect(controller.calls, isEmpty);

        await _wait(tester, 500);
        await _tapNow(tester, strings.doesNotMatchButton);
        expect(controller.calls, ['answerRequest mismatch']);
      });

      final sameContent = <String, NodeState>{
        'the same state again': _with(pairing: receiverComparing),
        'an equal new view': _with(
          pairing: view(
            role: PairingRole.receiver,
            phase: PairingPhase.comparing,
          ),
        ),
        'a state with a new notice and the same view': pairingState(
          pairing: receiverComparing,
          notices: const [Notice(id: 1, kind: NoticeKind.pairingPaused)],
        ),
        'a new peer name with the same fingerprint': _with(
          pairing: view(
            role: PairingRole.receiver,
            phase: PairingPhase.comparing,
            name: 'Otro nombre',
          ),
        ),
      };

      for (final MapEntry(key: name, value: next) in sameContent.entries) {
        testWidgets('$name at 400 ms does not restart the delay: a tap at '
            '500 ms counts', (tester) async {
          final controller = await _openLater(
            tester,
            code,
            _with(pairing: receiverComparing),
          );

          await _wait(tester, 400);
          controller.emit(next);
          await tester.pump();
          expect(_buttonStates(tester).values, everyElement(isFalse));

          await _wait(tester, 100);
          expect(_buttonStates(tester).values, everyElement(isTrue));
          await _tapNow(tester, strings.matchesButton);
          expect(controller.calls, ['answerRequest matches']);
        });
      }

      final changes = <String, (NodeState, NodeState, String)>{
        'the phase': (
          _with(
            pairing: view(
              role: PairingRole.initiator,
              phase: PairingPhase.connecting,
            ),
          ),
          _with(
            pairing: view(
              role: PairingRole.initiator,
              phase: PairingPhase.comparing,
            ),
          ),
          strings.cancelButton,
        ),
        'the role': (
          _with(pairing: receiverComparing),
          _with(
            pairing: view(
              role: PairingRole.initiator,
              phase: PairingPhase.comparing,
            ),
          ),
          strings.matchesButton,
        ),
        'the fingerprint': (
          _with(pairing: receiverComparing),
          _with(
            pairing: view(
              role: PairingRole.receiver,
              phase: PairingPhase.comparing,
              fingerprint: fingerprintOf('5555EEEE'),
            ),
          ),
          strings.matchesButton,
        ),
        'the code': (
          _with(pairing: receiverComparing),
          _with(
            pairing: view(
              role: PairingRole.receiver,
              phase: PairingPhase.comparing,
              pairingCode: '111222',
            ),
          ),
          strings.matchesButton,
        ),
        'already paired': (
          _with(pairing: receiverComparing),
          _with(
            pairing: view(
              role: PairingRole.receiver,
              phase: PairingPhase.comparing,
              alreadyPaired: true,
            ),
          ),
          strings.matchesButton,
        ),
        'the outcome': (
          _with(
            pairing: view(
              role: PairingRole.initiator,
              phase: PairingPhase.finished,
              outcome: PairingOutcome.paired,
            ),
          ),
          _with(
            pairing: view(
              role: PairingRole.initiator,
              phase: PairingPhase.finished,
              outcome: PairingOutcome.rejected,
            ),
          ),
          strings.closeButton,
        ),
        'a namesake that appears': (
          _with(pairing: receiverComparing),
          _with(pairing: receiverComparing, namesake: namesakeName),
          strings.matchesButton,
        ),
        'a namesake that goes away': (
          _with(pairing: receiverComparing, namesake: namesakeName),
          _with(pairing: receiverComparing),
          strings.matchesButton,
        ),
        'a namesake that changes': (
          _with(pairing: receiverComparing, namesake: namesakeName),
          _with(pairing: receiverComparing, namesake: 'Torre'),
          strings.matchesButton,
        ),
      };

      for (final MapEntry(key: name, value: (before, after, label))
          in changes.entries) {
        testWidgets('a change of $name rearms the delay for 500 ms', (
          tester,
        ) async {
          final controller = await _openLater(tester, code, before);
          await tester.pump(dialogActivationDelay);
          expect(_buttonStates(tester).values, everyElement(isTrue));

          controller.emit(after);
          await tester.pump();
          expect(_buttonStates(tester).values, everyElement(isFalse));

          await _tapNow(tester, label);
          await _wait(tester, 499);
          expect(_enabled(tester, label), isFalse);
          await _tapNow(tester, label);
          expect(controller.calls, isEmpty);

          await _wait(tester, 1);
          expect(_buttonStates(tester).values, everyElement(isTrue));
          await _tapNow(tester, label);
          expect(controller.calls, hasLength(1));
        });
      }

      testWidgets('two changes in a row count from the last one', (
        tester,
      ) async {
        final controller = await _openLater(
          tester,
          code,
          _with(pairing: receiverComparing),
        );
        await _wait(tester, 300);
        controller.emit(_with(pairing: receiverComparing, namesake: 'Torre'));
        await tester.pump();
        await _wait(tester, 300);
        controller.emit(
          _with(pairing: receiverComparing, namesake: namesakeName),
        );
        await tester.pump();

        await _wait(tester, 499);
        await _tapNow(tester, strings.matchesButton);
        expect(controller.calls, isEmpty);
        await _wait(tester, 1);
        await _tapNow(tester, strings.matchesButton);
        expect(controller.calls, ['answerRequest matches']);
      });

      testWidgets('replace: Replace at 100 ms keeps the question open and at '
          '500 ms answers true', (tester) async {
        final controller = await _openLater(
          tester,
          code,
          _with(questions: [_replace]),
        );
        expect(find.text(strings.replaceTitle(_oldName)), findsOneWidget);
        expect(_buttonStates(tester), {
          strings.keepBothButton: false,
          strings.replaceButton: false,
        });

        await _wait(tester, 100);
        await _tapNow(tester, strings.replaceButton);
        await _tapNow(tester, strings.keepBothButton);
        expect(controller.calls, isEmpty);
        expect(find.text(strings.replaceTitle(_oldName)), findsOneWidget);

        await _wait(tester, 400);
        await _tapNow(tester, strings.replaceButton);
        await tester.pumpAndSettle();
        expect(controller.calls, ['answerReplace $peerFingerprint true']);
        expect(dialog, findsNothing);
      });

      testWidgets('replace: Esc at 0 ms keeps both at once', (tester) async {
        final controller = await _openLater(
          tester,
          code,
          _with(questions: [_replace]),
        );

        await _escape(tester);

        expect(controller.calls, ['answerReplace $peerFingerprint false']);
        expect(dialog, findsNothing);
      });

      testWidgets('replace: a tap outside at 0 ms keeps both at once', (
        tester,
      ) async {
        final controller = await _openLater(
          tester,
          code,
          _with(questions: [_replace]),
        );

        await _tapOutside(tester);

        expect(controller.calls, ['answerReplace $peerFingerprint false']);
        expect(dialog, findsNothing);
      });

      testWidgets('is it yours?: It is mine at 100 ms does nothing and at '
          '500 ms answers true', (tester) async {
        final controller = await _openLater(
          tester,
          code,
          _with(questions: [_mine]),
        );
        expect(_buttonStates(tester).values, everyElement(isFalse));

        await _wait(tester, 100);
        await _tapNow(tester, strings.mineYesButton);
        await _tapNow(tester, strings.mineNoButton);
        expect(controller.calls, isEmpty);
        expect(find.text(strings.mineTitle(peerName)), findsOneWidget);

        await _wait(tester, 400);
        await _tapNow(tester, strings.mineYesButton);
        await tester.pumpAndSettle();
        expect(controller.calls, ['answerMine $peerFingerprint true']);
      });

      testWidgets('is it yours?: Esc at 0 ms leaves it as someone else\'s', (
        tester,
      ) async {
        final controller = await _openLater(
          tester,
          code,
          _with(questions: [_mine]),
        );

        await _escape(tester);

        expect(controller.calls, ['answerMine $peerFingerprint false']);
        expect(dialog, findsNothing);
      });

      testWidgets('the next question gets its own delay', (tester) async {
        final controller = await _openLater(
          tester,
          code,
          _with(questions: [_replace, _mine]),
        );
        await tester.pump(dialogActivationDelay);
        await _tapNow(tester, strings.keepBothButton);
        await _wait(tester, 200);
        expect(dialog, findsOneWidget);
        expect(find.text(strings.mineTitle(peerName)), findsOneWidget);
        expect(_buttonStates(tester), {
          strings.mineNoButton: false,
          strings.mineYesButton: false,
        });

        await _tapNow(tester, strings.mineYesButton);
        expect(controller.calls, ['answerReplace $peerFingerprint false']);

        await tester.pump(dialogActivationDelay);
        await _tapNow(tester, strings.mineYesButton);
        await tester.pumpAndSettle();
        expect(controller.calls, [
          'answerReplace $peerFingerprint false',
          'answerMine $peerFingerprint true',
        ]);
      });

      testWidgets('a pairing dialog closed before 500 ms leaves no timer '
          'behind', (tester) async {
        final controller = await _openLater(
          tester,
          code,
          _with(pairing: receiverComparing),
        );

        await _wait(tester, 100);
        controller.emit(_with());
        await tester.pump();
        await tester.pump();

        expect(dialog, findsNothing);
        expect(tester.takeException(), isNull);
      });

      testWidgets('a question closed before 500 ms leaves no timer behind', (
        tester,
      ) async {
        final controller = await _openLater(
          tester,
          code,
          _with(questions: [_mine]),
        );

        await _wait(tester, 100);
        controller.emit(_with(pairing: receiverComparing, questions: [_mine]));
        await tester.pump();
        await tester.pump();
        expect(find.text(strings.mineTitle(peerName)), findsNothing);
        controller.emit(_with());
        await tester.pump();
        await tester.pump();

        expect(dialog, findsNothing);
        expect(tester.takeException(), isNull);
      });
    });
  }

  group('C91 rendered texts of the dialogs', () {
    const names = [peerName, peerShort, _oldName, namesakeName];
    const userTexts = {peerName, formattedCode, _oldName};
    final scenarios = <String, (PairingView?, List<PairingQuestion>, String?)>{
      'initiator connecting': (
        view(role: PairingRole.initiator, phase: PairingPhase.connecting),
        const [],
        null,
      ),
      'initiator comparing': (
        view(role: PairingRole.initiator, phase: PairingPhase.comparing),
        const [],
        null,
      ),
      'initiator waiting': (
        view(role: PairingRole.initiator, phase: PairingPhase.waitingPeer),
        const [],
        null,
      ),
      'receiver comparing': (
        view(role: PairingRole.receiver, phase: PairingPhase.comparing),
        const [],
        null,
      ),
      'receiver already paired': (
        view(
          role: PairingRole.receiver,
          phase: PairingPhase.comparing,
          alreadyPaired: true,
        ),
        const [],
        null,
      ),
      'receiver waiting': (
        view(role: PairingRole.receiver, phase: PairingPhase.waitingPeer),
        const [],
        null,
      ),
      'initiator comparing with a namesake': (
        view(role: PairingRole.initiator, phase: PairingPhase.comparing),
        const [],
        namesakeName,
      ),
      'initiator waiting with a namesake': (
        view(role: PairingRole.initiator, phase: PairingPhase.waitingPeer),
        const [],
        namesakeName,
      ),
      'receiver comparing with a namesake': (
        view(role: PairingRole.receiver, phase: PairingPhase.comparing),
        const [],
        namesakeName,
      ),
      'receiver waiting with a namesake': (
        view(role: PairingRole.receiver, phase: PairingPhase.waitingPeer),
        const [],
        namesakeName,
      ),
      for (final outcome in PairingOutcome.values)
        'result ${outcome.name}': (
          view(
            role: PairingRole.initiator,
            phase: PairingPhase.finished,
            outcome: outcome,
          ),
          const [],
          null,
        ),
      'replace question': (null, [_replace], null),
      'mine question': (null, [_mine], null),
    };

    for (final MapEntry(key: name, value: (pairing, questions, namesake))
        in scenarios.entries) {
      testWidgets('$name: every text comes from AppStrings and differs', (
        tester,
      ) async {
        final rendered = <String, List<String>>{};
        for (final code in languageCodes) {
          await _pumpWith(
            tester,
            code,
            pairing: pairing,
            questions: questions,
            namesake: namesake,
          );
          if (namesake != null) {
            expect(
              find.text(stringsFor(code).namesakeWarning(namesake)),
              findsOneWidget,
            );
          }
          final texts = textsIn(tester, dialog);
          expect(texts, isNotEmpty);
          expect(texts.where((text) => text.trim().isEmpty), isEmpty);
          final allowed = allowedTexts(stringsFor(code), names: names);
          expect(
            texts.where(
              (text) => !allowed.contains(text) && !userTexts.contains(text),
            ),
            isEmpty,
            reason: 'texts not taken from AppStrings in $code',
          );
          rendered[code] = texts
              .where((text) => !userTexts.contains(text))
              .toList();
          await tester.pumpWidget(const SizedBox());
        }
        expect(rendered['es']!.length, rendered['en']!.length);
        expect(
          rendered['es']!.toSet().intersection(rendered['en']!.toSet()),
          isEmpty,
        );
      });
    }
  });
}

final class _LanguageController extends FakeAppController {
  _LanguageController(this._code, NodeState state) : super(state: state);

  final String _code;

  @override
  String get languageCode => _code;
}
