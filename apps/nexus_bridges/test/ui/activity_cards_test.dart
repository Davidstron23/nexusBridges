import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nexus_bridges/src/l10n/app_strings.dart';
import 'package:nexus_bridges/src/ui/activity_cards.dart';
import 'package:nexus_bridges/src/ui/armed.dart';
import 'package:nexus_bridges/src/ui/format.dart';
import 'package:nexus_bridges/src/ui/icons/glyphs.dart';
import 'package:nexus_bridges/src/ui/theme/components.dart';
import 'package:nexus_bridges_core/nexus_bridges_core.dart';

import 'fake_app_controller.dart';
import 'transfer_fixtures.dart';

const ValueKey<String> _outgoingKey = ValueKey('activity-outgoing');
const ValueKey<String> _incomingKey = ValueKey('activity-incoming');
const ValueKey<String> _sentKey = ValueKey('activity-last-sent');
const ValueKey<String> _receivedKey = ValueKey('activity-last-received');

Finder get _outgoing => find.byKey(_outgoingKey);
Finder get _incoming => find.byKey(_incomingKey);
Finder get _sent => find.byKey(_sentKey);
Finder get _received => find.byKey(_receivedKey);

const TextStyle _style = TextStyle(fontSize: 14);

bool _fits(
  String text,
  double width, {
  TextScaler scaler = TextScaler.noScaling,
}) {
  final painter = TextPainter(
    text: TextSpan(text: text, style: _style),
    maxLines: 1,
    textScaler: scaler,
    textDirection: TextDirection.ltr,
  )..layout(maxWidth: width);
  final exceeded = painter.didExceedMaxLines;
  painter.dispose();
  return !exceeded;
}

String _fit(
  String name,
  double width, {
  TextScaler scaler = TextScaler.noScaling,
}) => fitFileName(
  name,
  style: _style,
  maxWidth: width,
  textScaler: scaler,
  textDirection: TextDirection.ltr,
);

int _runes(String text) => text.runes.length;

Future<FakeAppController> _pumpPanel(
  WidgetTester tester,
  String code,
  NodeState state,
) => pumpColumn(
  tester,
  code,
  state,
  (controller, current) =>
      ActivityPanel(controller: controller, state: current),
);

String _expectedOutgoingChip(AppStrings strings, OutgoingPhase phase) =>
    switch (phase) {
      OutgoingPhase.preparing => strings.chipPreparing,
      OutgoingPhase.requesting => strings.chipWaiting,
      OutgoingPhase.waiting => strings.chipWaiting,
      OutgoingPhase.uploading => strings.chipInProgress,
      OutgoingPhase.verifying => strings.chipChecking,
    };

ChipTone _expectedOutgoingTone(OutgoingPhase phase) => switch (phase) {
  OutgoingPhase.preparing => ChipTone.wait,
  OutgoingPhase.requesting => ChipTone.wait,
  OutgoingPhase.waiting => ChipTone.wait,
  OutgoingPhase.uploading => ChipTone.run,
  OutgoingPhase.verifying => ChipTone.run,
};

String _expectedIncomingChip(AppStrings strings, IncomingStage stage) =>
    switch (stage) {
      IncomingStage.receiving => strings.chipInProgress,
      IncomingStage.verifying => strings.chipChecking,
      IncomingStage.waitingData => strings.chipWaiting,
      IncomingStage.warning => strings.chipWaiting,
      IncomingStage.folderQuestion => strings.chipWaiting,
      IncomingStage.ended => strings.chipWaiting,
    };

ChipTone _expectedIncomingTone(IncomingStage stage) => switch (stage) {
  IncomingStage.receiving => ChipTone.run,
  IncomingStage.verifying => ChipTone.run,
  IncomingStage.waitingData => ChipTone.wait,
  IncomingStage.warning => ChipTone.wait,
  IncomingStage.folderQuestion => ChipTone.wait,
  IncomingStage.ended => ChipTone.wait,
};

ChipTone _expectedResultTone(TransferResultKind kind) => switch (kind) {
  TransferResultKind.saved => ChipTone.ok,
  TransferResultKind.rejected => ChipTone.fail,
  TransferResultKind.failed => ChipTone.fail,
  TransferResultKind.cancelled => ChipTone.wait,
  TransferResultKind.unconfirmed => ChipTone.wait,
};

String _expectedResultChip(
  AppStrings strings,
  TransferDirection direction,
  TransferResultKind kind,
) => switch (kind) {
  TransferResultKind.saved =>
    direction == TransferDirection.outgoing
        ? strings.chipDelivered
        : strings.chipSaved,
  TransferResultKind.rejected => strings.chipRejected,
  TransferResultKind.cancelled => strings.chipCancelled,
  TransferResultKind.failed => strings.chipFailed,
  TransferResultKind.unconfirmed => strings.chipUnconfirmed,
};

const Map<String, String> _declinedSent = {
  'en': "The other device didn't accept it. You can try again in a minute.",
  'es':
      'El otro equipo no lo ha aceptado. Puedes volver a intentarlo dentro de '
      'un minuto.',
};

const Map<String, String> _damagedSent = {
  'en':
      'It arrived damaged, so it was deleted. If the file changed while it '
      'was being sent, send it again.',
  'es':
      'Ha llegado da\u00F1ado, as\u00ED que se ha borrado. Si el archivo '
      'cambi\u00F3 mientras se enviaba, vuelve a enviarlo.',
};

const Map<String, String> _folderOnlyText = {
  'en':
      "The folder was opened, but the file couldn't be selected. It may have "
      'been moved, renamed or deleted.',
  'es':
      'Se ha abierto la carpeta, pero no se ha podido seleccionar el archivo. '
      'Puede que se haya movido, cambiado de nombre o borrado.',
};

void _expectBar(WidgetTester tester, Finder card, double? value) {
  final bar = inside(card, find.byType(NbProgressBar));
  if (value == null) {
    expect(bar, findsNothing);
  } else {
    expect(bar, findsOneWidget);
    expect(tester.widget<NbProgressBar>(bar).value, closeTo(value, 1e-9));
  }
}

void main() {
  group('E269 tones and chip texts', () {
    test('outgoingTone follows the table of point 119', () {
      for (final phase in OutgoingPhase.values) {
        expect(
          outgoingTone(phase),
          _expectedOutgoingTone(phase),
          reason: '$phase',
        );
      }
    });

    test('incomingTone follows the table of point 119', () {
      for (final stage in IncomingStage.values) {
        expect(
          incomingTone(stage),
          _expectedIncomingTone(stage),
          reason: '$stage',
        );
      }
    });

    test('resultTone follows the table of point 119', () {
      for (final kind in TransferResultKind.values) {
        expect(resultTone(kind), _expectedResultTone(kind), reason: '$kind');
      }
    });

    for (final code in languageCodes) {
      final strings = stringsFor(code);

      test('[$code] outgoingChipText for each phase', () {
        for (final phase in OutgoingPhase.values) {
          expect(
            outgoingChipText(strings, phase),
            _expectedOutgoingChip(strings, phase),
            reason: '$phase',
          );
        }
      });

      test('[$code] incomingChipText for each stage', () {
        for (final stage in IncomingStage.values) {
          expect(
            incomingChipText(strings, stage),
            _expectedIncomingChip(strings, stage),
            reason: '$stage',
          );
        }
      });

      test('[$code] resultChipText for each outcome in both directions', () {
        for (final direction in TransferDirection.values) {
          for (final outcome in TransferOutcome.values) {
            expect(
              resultChipText(
                strings,
                resultView(direction: direction, outcome: outcome),
              ),
              _expectedResultChip(strings, direction, outcome.kind),
              reason: '$direction $outcome',
            );
          }
        }
      });
    }

    test('the chip texts differ between languages', () {
      final es = stringsFor('es');
      final en = stringsFor('en');
      for (final phase in OutgoingPhase.values) {
        expect(outgoingChipText(es, phase), isNot(outgoingChipText(en, phase)));
      }
    });
  });

  group('E269 fitFileName', () {
    testWidgets('a name with room is returned as it is', (tester) async {
      expect(_fit('informe.pdf', 1000), 'informe.pdf');
      final painter = TextPainter(
        text: const TextSpan(text: 'informe.pdf', style: _style),
        textDirection: TextDirection.ltr,
      )..layout();
      final exact = painter.width;
      painter.dispose();
      expect(_fit('informe.pdf', exact), 'informe.pdf');
      expect(_fit(longName('.pdf'), 100000), longName('.pdf'));
    });

    testWidgets('decreasing widths never give a longer name and always keep '
        'the extension', (tester) async {
      for (final tail in ['.pdf', '.pdf.exe', '.tar.gz']) {
        final name = longName(tail);
        final extension = tail.substring(tail.lastIndexOf('.'));
        var previous = _runes(name) + 1;
        for (var width = 5000.0; width >= 1; width -= 37) {
          final shown = _fit(name, width);
          expect(_runes(shown), lessThanOrEqualTo(previous), reason: '$width');
          expect(shown, endsWith(extension), reason: '$width');
          if (shown != name) expect(shown, contains('\u2026'));
          previous = _runes(shown);
        }
      }
    });

    testWidgets('the result is the longest shortened name that fits', (
      tester,
    ) async {
      final name = longName('.pdf');
      for (final width in [120.0, 200.0, 280.0, 333.0, 1000.0]) {
        final shown = _fit(name, width);
        expect(_fits(shown, width), isTrue, reason: '$width');
        final longer = shortenFileName(name, maxRunes: _runes(shown) + 1);
        expect(_fits(longer, width), isFalse, reason: '$width');
        expect(shown, shortenFileName(name, maxRunes: _runes(shown)));
      }
    });

    testWidgets('a .pdf.exe name ends in .exe once cut', (tester) async {
      final shown = _fit(longName('.pdf.exe'), 280);
      expect(shown, endsWith('.exe'));
      expect(shown, isNot(endsWith('.pdf')));
      expect(shown, contains('\u2026'));
      expect(_fits(shown, 280), isTrue);
    });

    testWidgets('an impossible width gives the extension and two runes', (
      tester,
    ) async {
      expect(_fit('${'x' * 50}.pdf', 1), 'x\u2026.pdf');
      expect(_fit('x' * 50, 1), 'x\u2026');
      expect(_fit('${'x' * 50}.${'y' * 20}', 1), 'x\u2026');
      final sixteen = '.${'z' * 15}';
      expect(_fit('${'x' * 50}$sixteen', 1), 'x\u2026$sixteen');
    });

    testWidgets('a bigger text scale gives a shorter name that still fits', (
      tester,
    ) async {
      final name = longName('.docx');
      const double width = 400;
      const scaler = TextScaler.linear(2);
      final normal = _fit(name, width);
      final big = _fit(name, width, scaler: scaler);
      expect(_runes(big), lessThan(_runes(normal)));
      expect(big, endsWith('.docx'));
      expect(_fits(big, width, scaler: scaler), isTrue);
    });
  });

  group('Armed', () {
    Widget host(Object key, List<bool> seen) => Directionality(
      textDirection: TextDirection.ltr,
      child: Armed(
        armKey: key,
        builder: (context, armed) {
          seen.add(armed);
          return Text(armed ? 'on' : 'off');
        },
      ),
    );

    testWidgets('starts disarmed and arms after dialogActivationDelay', (
      tester,
    ) async {
      final seen = <bool>[];
      await tester.pumpWidget(host('a', seen));
      expect(find.text('off'), findsOneWidget);
      await tester.pump(justBeforeArmed);
      expect(find.text('off'), findsOneWidget);
      await tester.pump(lastMillisecond);
      expect(find.text('on'), findsOneWidget);
      expect(seen.first, isFalse);
      expect(dialogActivationDelay, const Duration(milliseconds: 500));
    });

    testWidgets('the same key by value keeps it armed', (tester) async {
      final seen = <bool>[];
      await tester.pumpWidget(host(('s1', IncomingStage.warning), seen));
      await arm(tester);
      expect(find.text('on'), findsOneWidget);
      await tester.pumpWidget(host(('s1', IncomingStage.warning), seen));
      expect(find.text('on'), findsOneWidget);
    });

    testWidgets('a new key disarms it for another 0.5 s', (tester) async {
      final seen = <bool>[];
      await tester.pumpWidget(host('a', seen));
      await arm(tester);
      await tester.pumpWidget(host('b', seen));
      expect(find.text('off'), findsOneWidget);
      await tester.pump(justBeforeArmed);
      expect(find.text('off'), findsOneWidget);
      await tester.pump(lastMillisecond);
      expect(find.text('on'), findsOneWidget);
    });

    testWidgets('a key that changes again restarts the wait', (tester) async {
      final seen = <bool>[];
      await tester.pumpWidget(host('a', seen));
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pumpWidget(host('b', seen));
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('off'), findsOneWidget);
      await tester.pump(const Duration(milliseconds: 200));
      expect(find.text('on'), findsOneWidget);
    });

    testWidgets('removing it before the delay leaves no timer behind', (
      tester,
    ) async {
      final seen = <bool>[];
      await tester.pumpWidget(host('a', seen));
      await tester.pump(const Duration(milliseconds: 100));
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(seconds: 1));
      expect(seen, everyElement(isFalse));
    });
  });

  for (final code in languageCodes) {
    final strings = stringsFor(code);

    String size(int bytes) => formatSize(bytes, code);

    group('[$code] E138 outgoing card', () {
      for (final phase in OutgoingPhase.values) {
        testWidgets('in ${phase.name} shows its title, chip, detail, bar and '
            'note', (tester) async {
          const total = 4096;
          const sent = 1024;
          await _pumpPanel(
            tester,
            code,
            NodeState(
              outgoing: outgoingView(phase: phase, size: total, sent: sent),
            ),
          );

          expect(_outgoing, findsOneWidget);
          expect(
            textIn(_outgoing, strings.sendingToTitle(senderName)),
            findsOneWidget,
          );
          final chip = chipIn(tester, _outgoing);
          expect(chip.label, _expectedOutgoingChip(strings, phase));
          expect(chip.tone, _expectedOutgoingTone(phase));
          expect(shownFileName(tester, _outgoing), 'informe.pdf');

          final progress = strings.progressLine(
            percentOf(sent, total),
            size(sent),
            size(total),
          );
          switch (phase) {
            case OutgoingPhase.preparing:
              expect(
                textIn(_outgoing, strings.preparingFile('informe.pdf')),
                findsOneWidget,
              );
              expect(textIn(_outgoing, size(total)), findsNothing);
              expect(textIn(_outgoing, progress), findsNothing);
              _expectBar(tester, _outgoing, null);
            case OutgoingPhase.requesting || OutgoingPhase.waiting:
              expect(textIn(_outgoing, size(total)), findsOneWidget);
              expect(textIn(_outgoing, progress), findsNothing);
              _expectBar(tester, _outgoing, null);
            case OutgoingPhase.uploading:
              expect(textIn(_outgoing, progress), findsOneWidget);
              _expectBar(tester, _outgoing, 0.25);
            case OutgoingPhase.verifying:
              expect(textIn(_outgoing, progress), findsOneWidget);
              _expectBar(tester, _outgoing, 1);
          }

          final notes = {
            OutgoingPhase.requesting: strings.contactingPeer(senderName),
            OutgoingPhase.waiting: strings.waitingAcceptance(senderName),
            OutgoingPhase.verifying: strings.peerCheckingFile(senderName),
          };
          for (final MapEntry(key: notePhase, value: note) in notes.entries) {
            expect(
              textIn(_outgoing, note),
              notePhase == phase ? findsOneWidget : findsNothing,
              reason: '$notePhase',
            );
          }
          expect(buttonLabels(tester, _outgoing), [strings.cancelButton]);
          expect(textIn(_outgoing, strings.cancellingTransfer), findsNothing);
          expect(textIn(_outgoing, strings.programLabel), findsNothing);
          expect(tester.takeException(), isNull);
        });

        testWidgets('in ${phase.name} Cancel calls cancelSending once armed', (
          tester,
        ) async {
          final controller = await _pumpPanel(
            tester,
            code,
            NodeState(outgoing: outgoingView(phase: phase)),
          );
          final cancel = buttonIn(_outgoing, strings.cancelButton);
          expect(tester.widget(cancel), isA<OutlinedButton>());
          expect(isEnabled(tester, cancel), isFalse);
          await tester.tap(cancel, warnIfMissed: false);
          expect(controller.calls, isEmpty);

          await arm(tester);
          expect(isEnabled(tester, cancel), isTrue);
          await tester.tap(cancel);
          await tester.pump();
          expect(controller.calls, ['cancelSending']);
        });

        testWidgets('in ${phase.name} with cancelling shows cancellingTransfer '
            'and no button', (tester) async {
          await _pumpPanel(
            tester,
            code,
            NodeState(outgoing: outgoingView(phase: phase, cancelling: true)),
          );
          await arm(tester);
          expect(textIn(_outgoing, strings.cancellingTransfer), findsOneWidget);
          expect(buttonLabels(tester, _outgoing), isEmpty);
          expect(tester.takeException(), isNull);
        });
      }

      testWidgets('a file of 0 bytes is complete as soon as it uploads', (
        tester,
      ) async {
        await _pumpPanel(
          tester,
          code,
          NodeState(outgoing: outgoingView(size: 0, sent: 0)),
        );
        expect(
          textIn(_outgoing, strings.progressLine(100, size(0), size(0))),
          findsOneWidget,
        );
        _expectBar(tester, _outgoing, 1);
      });

      testWidgets('the progress line follows the bytes sent', (tester) async {
        final controller = await _pumpPanel(
          tester,
          code,
          NodeState(outgoing: outgoingView(size: 1000, sent: 0)),
        );
        for (final sent in [0, 1, 333, 999, 1000]) {
          controller.emit(
            NodeState(outgoing: outgoingView(size: 1000, sent: sent)),
          );
          await tester.pump();
          expect(
            textIn(
              _outgoing,
              strings.progressLine(sent * 100 ~/ 1000, size(sent), size(1000)),
            ),
            findsOneWidget,
            reason: '$sent',
          );
          _expectBar(tester, _outgoing, (sent * 100 ~/ 1000) / 100);
        }
      });

      testWidgets('a big file keeps the progress in range', (tester) async {
        const total = 6 * 1024 * 1024 * 1024;
        await _pumpPanel(
          tester,
          code,
          NodeState(
            outgoing: outgoingView(size: total, sent: total ~/ 3),
          ),
        );
        expect(
          textIn(
            _outgoing,
            strings.progressLine(33, size(total ~/ 3), size(total)),
          ),
          findsOneWidget,
        );
        _expectBar(tester, _outgoing, 0.33);
        expect(tester.takeException(), isNull);
      });

      testWidgets('a program shows programLabel, also while preparing', (
        tester,
      ) async {
        for (final phase in [OutgoingPhase.preparing, OutgoingPhase.waiting]) {
          await _pumpPanel(
            tester,
            code,
            NodeState(
              outgoing: outgoingView(
                phase: phase,
                fileName: 'setup.exe',
                isProgram: true,
              ),
            ),
          );
          expect(textIn(_outgoing, strings.programLabel), findsOneWidget);
          expect(shownFileName(tester, _outgoing), 'setup.exe');
        }
      });

      testWidgets('without a name the title uses the first 8 characters of '
          'the fingerprint', (tester) async {
        for (final name in [null, '']) {
          await _pumpPanel(
            tester,
            code,
            NodeState(
              outgoing: outgoingView(phase: OutgoingPhase.waiting, name: name),
            ),
          );
          expect(
            textIn(_outgoing, strings.sendingToTitle(senderShort)),
            findsOneWidget,
          );
          expect(
            textIn(_outgoing, strings.waitingAcceptance(senderShort)),
            findsOneWidget,
          );
        }
      });

      testWidgets('a long name keeps its extension in the 280 px column', (
        tester,
      ) async {
        await _pumpPanel(
          tester,
          code,
          NodeState(
            outgoing: outgoingView(
              fileName: longName('.pdf.exe'),
              isProgram: true,
            ),
          ),
        );
        final shown = shownFileName(tester, _outgoing);
        expect(shown, endsWith('.exe'));
        expect(shown, contains('\u2026'));
        expectNameFits(tester, _outgoing);
        expect(tester.getSize(_outgoing).width, columnWidth);
        expect(tester.takeException(), isNull);
      });
    });

    group('[$code] E269 incoming in progress', () {
      const total = 2000;
      const received = 500;

      testWidgets('waitingData shows the size, waitingForData and Cancel', (
        tester,
      ) async {
        final controller = await _pumpPanel(
          tester,
          code,
          NodeState(
            incoming: incomingView(
              id: 'rx-7',
              stage: IncomingStage.waitingData,
              size: total,
            ),
          ),
        );
        expect(_incoming, findsOneWidget);
        expect(
          textIn(_incoming, strings.receivingFromTitle(senderName)),
          findsOneWidget,
        );
        final chip = chipIn(tester, _incoming);
        expect(chip.label, strings.chipWaiting);
        expect(chip.tone, ChipTone.wait);
        expect(textIn(_incoming, size(total)), findsOneWidget);
        expect(textIn(_incoming, strings.waitingForData), findsOneWidget);
        expect(textIn(_incoming, strings.checkingFile), findsNothing);
        _expectBar(tester, _incoming, null);

        final cancel = buttonIn(_incoming, strings.cancelButton);
        expect(isEnabled(tester, cancel), isFalse);
        await arm(tester);
        await tester.tap(cancel);
        await tester.pump();
        expect(controller.calls, ['cancelReceiving rx-7']);
      });

      testWidgets('receiving shows the progress, the bar and Cancel', (
        tester,
      ) async {
        final controller = await _pumpPanel(
          tester,
          code,
          NodeState(
            incoming: incomingView(
              stage: IncomingStage.receiving,
              size: total,
              received: received,
            ),
          ),
        );
        final chip = chipIn(tester, _incoming);
        expect(chip.label, strings.chipInProgress);
        expect(chip.tone, ChipTone.run);
        expect(
          textIn(
            _incoming,
            strings.progressLine(25, size(received), size(total)),
          ),
          findsOneWidget,
        );
        _expectBar(tester, _incoming, 0.25);
        expect(textIn(_incoming, strings.waitingForData), findsNothing);
        expect(textIn(_incoming, strings.checkingFile), findsNothing);

        await arm(tester);
        await tester.tap(buttonIn(_incoming, strings.cancelButton));
        await tester.pump();
        expect(controller.calls, ['cancelReceiving s1']);
      });

      testWidgets('receiving 0 bytes is complete', (tester) async {
        await _pumpPanel(
          tester,
          code,
          NodeState(
            incoming: incomingView(stage: IncomingStage.receiving, size: 0),
          ),
        );
        expect(
          textIn(_incoming, strings.progressLine(100, size(0), size(0))),
          findsOneWidget,
        );
        _expectBar(tester, _incoming, 1);
      });

      testWidgets('verifying shows a full bar, checkingFile and no Cancel', (
        tester,
      ) async {
        await _pumpPanel(
          tester,
          code,
          NodeState(
            incoming: incomingView(
              stage: IncomingStage.verifying,
              size: total,
              received: total,
            ),
          ),
        );
        await arm(tester);
        final chip = chipIn(tester, _incoming);
        expect(chip.label, strings.chipChecking);
        expect(chip.tone, ChipTone.run);
        expect(
          textIn(
            _incoming,
            strings.progressLine(100, size(total), size(total)),
          ),
          findsOneWidget,
        );
        _expectBar(tester, _incoming, 1);
        expect(textIn(_incoming, strings.checkingFile), findsOneWidget);
        expect(buttonLabels(tester, _incoming), isEmpty);
      });

      for (final stage in [
        IncomingStage.warning,
        IncomingStage.folderQuestion,
        IncomingStage.ended,
      ]) {
        testWidgets('${stage.name} has no card in Activity', (tester) async {
          await _pumpPanel(
            tester,
            code,
            NodeState(
              incoming: incomingView(
                stage: stage,
                folder: const FolderQuestionView(
                  kind: FolderQuestionKind.firstTime,
                  proposedPath: downloadsPath,
                ),
              ),
            ),
          );
          expect(_incoming, findsNothing);
          expect(find.text(strings.activityEmpty), findsOneWidget);
          expect(find.text(strings.incomingExpiresNote), findsNothing);
        });
      }

      testWidgets('without a name the title uses the fingerprint', (
        tester,
      ) async {
        await _pumpPanel(
          tester,
          code,
          NodeState(
            incoming: incomingView(stage: IncomingStage.receiving, name: null),
          ),
        );
        expect(
          textIn(_incoming, strings.receivingFromTitle(senderShort)),
          findsOneWidget,
        );
      });

      testWidgets('the namesake warning is not shown while receiving', (
        tester,
      ) async {
        await _pumpPanel(
          tester,
          code,
          NodeState(
            incoming: incomingView(stage: IncomingStage.receiving),
            incomingNamesake: 'PC',
          ),
        );
        expect(find.text(strings.namesakeWarning('PC')), findsNothing);
      });
    });

    group('[$code] Activity panel', () {
      testWidgets('without anything shows only activityEmpty', (tester) async {
        await _pumpPanel(tester, code, const NodeState());
        expect(find.text(strings.activityEmpty), findsOneWidget);
        for (final card in [_outgoing, _incoming, _sent, _received]) {
          expect(card, findsNothing);
        }
      });

      testWidgets('orders outgoing, incoming, last sent and last received, '
          '12 px apart', (tester) async {
        await _pumpPanel(
          tester,
          code,
          NodeState(
            outgoing: outgoingView(),
            incoming: incomingView(stage: IncomingStage.receiving),
            lastSent: resultView(direction: TransferDirection.outgoing),
            lastReceived: resultView(),
          ),
        );
        expect(find.text(strings.activityEmpty), findsNothing);
        final cards = [_outgoing, _incoming, _sent, _received];
        for (var i = 1; i < cards.length; i++) {
          expect(
            tester.getTopLeft(cards[i]).dy,
            closeTo(tester.getBottomLeft(cards[i - 1]).dy + 12, 0.01),
            reason: 'card $i',
          );
        }
        expect(textIn(_sent, strings.lastSentTitle), findsOneWidget);
        expect(textIn(_received, strings.lastReceivedTitle), findsOneWidget);
        expect(tester.takeException(), isNull);
      });

      testWidgets('any one card replaces activityEmpty', (tester) async {
        for (final state in [
          NodeState(outgoing: outgoingView()),
          NodeState(incoming: incomingView(stage: IncomingStage.waitingData)),
          NodeState(
            lastSent: resultView(direction: TransferDirection.outgoing),
          ),
          NodeState(lastReceived: resultView()),
        ]) {
          await _pumpPanel(tester, code, state);
          expect(find.text(strings.activityEmpty), findsNothing);
        }
      });
    });

    group('[$code] E142 results', () {
      for (final direction in TransferDirection.values) {
        final outgoing = direction == TransferDirection.outgoing;
        final card = outgoing ? _sent : _received;

        testWidgets(
          'every outcome of the last ${outgoing ? 'send' : 'receive'} '
          'shows its chip, the peer and the reason',
          (tester) async {
            for (final outcome in TransferOutcome.values) {
              final result = resultView(direction: direction, outcome: outcome);
              await _pumpPanel(
                tester,
                code,
                outgoing
                    ? NodeState(lastSent: result)
                    : NodeState(lastReceived: result),
              );
              final reason = '$outcome';
              expect(card, findsOneWidget, reason: reason);
              expect(
                textIn(
                  card,
                  outgoing ? strings.lastSentTitle : strings.lastReceivedTitle,
                ),
                findsOneWidget,
                reason: reason,
              );
              final chip = chipIn(tester, card);
              expect(
                chip.label,
                _expectedResultChip(strings, direction, outcome.kind),
                reason: reason,
              );
              final tone = _expectedResultTone(outcome.kind);
              expect(chip.tone, tone, reason: reason);
              final icon = chip.icon;
              switch (tone) {
                case ChipTone.ok:
                  expect(
                    (icon as GlyphIcon).glyph,
                    Glyphs.check,
                    reason: reason,
                  );
                case ChipTone.fail:
                  expect((icon as GlyphIcon).glyph, Glyphs.ban, reason: reason);
                default:
                  expect(icon, isNull, reason: reason);
              }
              expect(shownFileName(tester, card), 'foto.jpg', reason: reason);
              expect(
                textIn(
                  card,
                  outgoing
                      ? strings.toPeer(senderName)
                      : strings.fromPeer(senderName),
                ),
                findsOneWidget,
                reason: reason,
              );
              expect(
                textIn(
                  card,
                  outgoing
                      ? strings.sentOutcome(outcome)
                      : strings.receivedOutcome(outcome),
                ),
                findsOneWidget,
                reason: reason,
              );
              expect(buttonLabels(tester, card), isEmpty, reason: reason);
              expect(tester.takeException(), isNull, reason: reason);
            }
          },
        );
      }

      testWidgets('declined and damaged of the sender use the texts of points '
          '96 and 98', (tester) async {
        for (final (outcome, texts) in [
          (TransferOutcome.declined, _declinedSent),
          (TransferOutcome.damaged, _damagedSent),
        ]) {
          await _pumpPanel(
            tester,
            code,
            NodeState(
              lastSent: resultView(
                direction: TransferDirection.outgoing,
                outcome: outcome,
              ),
            ),
          );
          expect(textIn(_sent, texts[code]!), findsOneWidget);
        }
      });

      testWidgets('saved without the mark says so in both directions', (
        tester,
      ) async {
        await _pumpPanel(
          tester,
          code,
          NodeState(
            lastSent: resultView(
              direction: TransferDirection.outgoing,
              outcome: TransferOutcome.savedWithoutMark,
            ),
            lastReceived: resultView(outcome: TransferOutcome.savedWithoutMark),
          ),
        );
        expect(
          strings.sentOutcome(TransferOutcome.savedWithoutMark),
          isNot(strings.sentOutcome(TransferOutcome.saved)),
        );
        expect(
          strings.receivedOutcome(TransferOutcome.savedWithoutMark),
          isNot(strings.receivedOutcome(TransferOutcome.saved)),
        );
        expect(
          textIn(_sent, strings.sentOutcome(TransferOutcome.savedWithoutMark)),
          findsOneWidget,
        );
        expect(
          textIn(
            _received,
            strings.receivedOutcome(TransferOutcome.savedWithoutMark),
          ),
          findsOneWidget,
        );
        expect(chipIn(tester, _sent).label, strings.chipDelivered);
        expect(chipIn(tester, _received).label, strings.chipSaved);
      });

      testWidgets('without a name the peer is the first 8 characters of the '
          'fingerprint', (tester) async {
        await _pumpPanel(
          tester,
          code,
          NodeState(
            lastSent: resultView(
              direction: TransferDirection.outgoing,
              name: null,
            ),
            lastReceived: resultView(name: ''),
          ),
        );
        expect(textIn(_sent, strings.toPeer(senderShort)), findsOneWidget);
        expect(
          textIn(_received, strings.fromPeer(senderShort)),
          findsOneWidget,
        );
      });

      testWidgets('a program shows programLabel and its full name in both '
          'results in the widest column', (tester) async {
        await pumpColumn(
          tester,
          code,
          NodeState(
            lastSent: resultView(
              direction: TransferDirection.outgoing,
              fileName: 'factura.pdf.exe',
              isProgram: true,
            ),
            lastReceived: resultView(
              fileName: 'factura.pdf.exe',
              isProgram: true,
            ),
          ),
          (controller, state) =>
              ActivityPanel(controller: controller, state: state),
          width: 350,
        );
        for (final card in [_sent, _received]) {
          expect(textIn(card, strings.programLabel), findsOneWidget);
          expect(shownFileName(tester, card), 'factura.pdf.exe');
        }
      });

      for (final (tail, extension) in [
        ('.pdf.exe', '.exe'),
        ('.pdf', '.pdf'),
      ]) {
        testWidgets('a name of 300 characters ending in $tail ends in '
            '$extension in the 280 px column', (tester) async {
          final name = longName(tail);
          expect(name.length, 300);
          await _pumpPanel(
            tester,
            code,
            NodeState(
              lastSent: resultView(
                direction: TransferDirection.outgoing,
                fileName: name,
                isProgram: tail == '.pdf.exe',
              ),
              lastReceived: resultView(
                fileName: name,
                isProgram: tail == '.pdf.exe',
                canReveal: true,
              ),
            ),
          );
          for (final card in [_sent, _received]) {
            expect(tester.getSize(card).width, columnWidth);
            final shown = shownFileName(tester, card);
            expect(shown, endsWith(extension));
            expect(shown, contains('\u2026'));
            if (tail == '.pdf.exe') {
              expect(shown, isNot(contains('.pdf')));
              expect(textIn(card, strings.programLabel), findsOneWidget);
            }
            expectNameFits(tester, card);
            final text = tester.widget<Text>(fileNameIn(card));
            expect(text.maxLines, 1);
            expect(text.softWrap, isFalse);
            expect(text.overflow, TextOverflow.clip);
          }
          expect(tester.takeException(), isNull);
        });
      }

      testWidgets('Show in folder only when the result can be revealed', (
        tester,
      ) async {
        await _pumpPanel(
          tester,
          code,
          NodeState(
            lastSent: resultView(
              direction: TransferDirection.outgoing,
              canReveal: false,
            ),
            lastReceived: resultView(canReveal: false),
          ),
        );
        expect(find.text(strings.showInFolderButton), findsNothing);

        await _pumpPanel(
          tester,
          code,
          NodeState(lastReceived: resultView(canReveal: true)),
        );
        final reveal = buttonIn(_received, strings.showInFolderButton);
        expect(reveal, findsOneWidget);
        expect(tester.widget(reveal), isA<TextButton>());
        expect(
          inside(
            reveal,
            find.byWidgetPredicate(
              (widget) => widget is GlyphIcon && widget.glyph == Glyphs.folder,
            ),
          ),
          findsOneWidget,
        );
      });

      for (final (result, message) in [
        (RevealResult.shown, null),
        (RevealResult.folderOnly, _folderOnlyText[code]),
        (RevealResult.unavailable, strings.folderUnavailable),
      ]) {
        testWidgets('Show in folder with ${result.name} works from the first '
            'frame and ${message == null ? 'shows no SnackBar' : 'shows its '
                      'SnackBar'}', (tester) async {
          final controller = await _pumpPanel(
            tester,
            code,
            NodeState(lastReceived: resultView(canReveal: true)),
          );
          controller.revealResult = result;
          final reveal = buttonIn(_received, strings.showInFolderButton);
          expect(isEnabled(tester, reveal), isTrue);

          await tester.tap(reveal);
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 750));
          expect(controller.calls, ['revealLastReceived']);
          if (message == null) {
            expect(find.byType(SnackBar), findsNothing);
          } else {
            expect(
              find.descendant(
                of: find.byType(SnackBar),
                matching: find.text(message),
              ),
              findsOneWidget,
            );
          }
          for (final other in [
            strings.revealFolderOnly,
            strings.folderUnavailable,
          ]) {
            if (other != message) expect(find.text(other), findsNothing);
          }
        });
      }

      testWidgets('revealFolderOnly is the text of point 97', (tester) async {
        expect(strings.revealFolderOnly, _folderOnlyText[code]);
      });
    });

    group('[$code] E247 arming in Activity', () {
      testWidgets('the outgoing Cancel is off at 0 and 499 ms and on at '
          '500 ms', (tester) async {
        await _pumpPanel(tester, code, NodeState(outgoing: outgoingView()));
        final cancel = buttonIn(_outgoing, strings.cancelButton);
        expect(isEnabled(tester, cancel), isFalse);
        await tester.pump(justBeforeArmed);
        expect(isEnabled(tester, cancel), isFalse);
        await tester.pump(lastMillisecond);
        expect(isEnabled(tester, cancel), isTrue);
      });

      testWidgets('a new phase or more bytes of the same send keep Cancel on', (
        tester,
      ) async {
        final controller = await _pumpPanel(
          tester,
          code,
          NodeState(outgoing: outgoingView(phase: OutgoingPhase.preparing)),
        );
        await arm(tester);
        for (final view in [
          outgoingView(phase: OutgoingPhase.requesting),
          outgoingView(phase: OutgoingPhase.waiting),
          outgoingView(sent: 10),
          outgoingView(sent: 2000),
          outgoingView(phase: OutgoingPhase.verifying, sent: 2048),
        ]) {
          controller.emit(NodeState(outgoing: view));
          await tester.pump();
          expect(
            isEnabled(tester, buttonIn(_outgoing, strings.cancelButton)),
            isTrue,
            reason: '${view.phase} ${view.sentBytes}',
          );
        }
      });

      testWidgets('a new outgoing card disarms Cancel for 0.5 s', (
        tester,
      ) async {
        final controller = await _pumpPanel(
          tester,
          code,
          NodeState(outgoing: outgoingView()),
        );
        await arm(tester);
        for (final view in [
          outgoingView(fileName: 'otro.pdf'),
          outgoingView(fileName: 'otro.pdf', fingerprint: fingerprintOf('FF')),
        ]) {
          controller.emit(NodeState(outgoing: view));
          await tester.pump();
          final cancel = buttonIn(_outgoing, strings.cancelButton);
          expect(isEnabled(tester, cancel), isFalse);
          await tester.tap(cancel, warnIfMissed: false);
          await tester.pump(justBeforeArmed);
          expect(isEnabled(tester, cancel), isFalse);
          await tester.pump(lastMillisecond);
          expect(isEnabled(tester, cancel), isTrue);
        }
        expect(controller.calls, isEmpty);
      });

      testWidgets('receivedBytes that grow keep the incoming Cancel on', (
        tester,
      ) async {
        final controller = await _pumpPanel(
          tester,
          code,
          NodeState(
            incoming: incomingView(stage: IncomingStage.receiving, size: 1000),
          ),
        );
        await arm(tester);
        for (final received in [100, 500, 999]) {
          controller.emit(
            NodeState(
              incoming: incomingView(
                stage: IncomingStage.receiving,
                size: 1000,
                received: received,
              ),
            ),
          );
          await tester.pump();
          expect(
            isEnabled(tester, buttonIn(_incoming, strings.cancelButton)),
            isTrue,
          );
        }
      });

      testWidgets('a new stage or a new session disarms the incoming Cancel', (
        tester,
      ) async {
        final controller = await _pumpPanel(
          tester,
          code,
          NodeState(incoming: incomingView(stage: IncomingStage.waitingData)),
        );
        await arm(tester);
        for (final view in [
          incomingView(stage: IncomingStage.receiving),
          incomingView(id: 's2', stage: IncomingStage.receiving),
        ]) {
          controller.emit(NodeState(incoming: view));
          await tester.pump();
          final cancel = buttonIn(_incoming, strings.cancelButton);
          expect(isEnabled(tester, cancel), isFalse);
          await tester.pump(justBeforeArmed);
          expect(isEnabled(tester, cancel), isFalse);
          await tester.pump(lastMillisecond);
          expect(isEnabled(tester, cancel), isTrue);
          await tester.tap(cancel);
          await tester.pump();
        }
        expect(controller.calls, ['cancelReceiving s1', 'cancelReceiving s2']);
      });

      testWidgets('Show in folder is on from the very first frame', (
        tester,
      ) async {
        final controller = FakeAppController(
          state: NodeState(lastReceived: resultView(canReveal: true)),
        );
        setWindow(tester, const Size(800, 600));
        await tester.pumpWidget(
          columnApp(
            controller,
            code,
            (state) => ActivityPanel(controller: controller, state: state),
          ),
        );
        expect(
          isEnabled(tester, buttonIn(_received, strings.showInFolderButton)),
          isTrue,
        );
      });
    });

    group('[$code] Activity in the home screen', () {
      for (final brightness in Brightness.values) {
        testWidgets('every card with long names fits at 800x600 in '
            '${brightness.name}', (tester) async {
          setWindow(tester, const Size(800, 600));
          if (brightness == Brightness.dark) {
            tester.platformDispatcher.platformBrightnessTestValue =
                Brightness.dark;
            addTearDown(
              tester.platformDispatcher.clearPlatformBrightnessTestValue,
            );
          }
          final controller = FakeAppController(
            state: NodeState(
              outgoing: outgoingView(
                fileName: longName('.pdf.exe'),
                isProgram: true,
                name: 'Equipo con un nombre bastante largo de verdad',
              ),
              incoming: incomingView(
                stage: IncomingStage.receiving,
                fileName: longName('.docx'),
                received: 700,
              ),
              lastSent: resultView(
                direction: TransferDirection.outgoing,
                outcome: TransferOutcome.damaged,
                fileName: longName('.zip'),
              ),
              lastReceived: resultView(
                outcome: TransferOutcome.savedWithoutMark,
                fileName: longName('.pdf'),
                canReveal: true,
              ),
            ),
          );
          await pumpHome(tester, controller, code, settle: false);
          await tester.pump(dialogActivationDelay);

          expect(tester.takeException(), isNull);
          expect(find.byType(ActivityPanel), findsOneWidget);
          for (final card in [_outgoing, _incoming, _sent, _received]) {
            expect(card, findsOneWidget);
            expect(tester.getSize(card).width, columnWidth);
            expectNameFits(tester, card);
          }
          expect(
            tester.getTopLeft(_outgoing).dy,
            greaterThan(
              tester.getBottomLeft(find.text(strings.activityTab)).dy,
            ),
          );
        });
      }

      testWidgets('the cards in every phase and stage fit at 800x600', (
        tester,
      ) async {
        setWindow(tester, const Size(800, 600));
        final controller = FakeAppController(
          state: NodeState(outgoing: outgoingView()),
        );
        await pumpHome(tester, controller, code, settle: false);
        for (final phase in OutgoingPhase.values) {
          for (final cancelling in [false, true]) {
            controller.emit(
              NodeState(
                outgoing: outgoingView(
                  phase: phase,
                  cancelling: cancelling,
                  isProgram: true,
                  fileName: longName('.exe'),
                ),
              ),
            );
            await tester.pump(dialogActivationDelay);
            expect(tester.takeException(), isNull, reason: '$phase');
          }
        }
        for (final stage in [
          IncomingStage.waitingData,
          IncomingStage.receiving,
          IncomingStage.verifying,
        ]) {
          controller.emit(
            NodeState(
              incoming: incomingView(stage: stage, fileName: longName('.mp4')),
            ),
          );
          await tester.pump(dialogActivationDelay);
          expect(tester.takeException(), isNull, reason: '$stage');
        }
      }, timeout: const Timeout(Duration(seconds: 60)));
    });
  }
}
