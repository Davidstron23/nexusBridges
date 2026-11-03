import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nexus_bridges/src/l10n/app_strings.dart';
import 'package:nexus_bridges/src/ui/activity_cards.dart';
import 'package:nexus_bridges/src/ui/device_list.dart';
import 'package:nexus_bridges/src/ui/format.dart';
import 'package:nexus_bridges/src/ui/icons/glyphs.dart';
import 'package:nexus_bridges/src/ui/incoming_cards.dart';
import 'package:nexus_bridges/src/ui/modal/modal_button.dart';
import 'package:nexus_bridges/src/ui/modal/modal_frame.dart';
import 'package:nexus_bridges/src/ui/theme/components.dart';
import 'package:nexus_bridges/src/ui/theme/tokens.dart';
import 'package:nexus_bridges_core/nexus_bridges_core.dart';

import 'fake_app_controller.dart';
import 'pairing_fixtures.dart' show entry, namesakeName;
import 'segoe_font.dart';
import 'transfer_fixtures.dart';

final NbColors _colors = NbColors.light;

Finder get _cards => find.byType(IncomingCards);

Finder get _card =>
    find.descendant(of: _cards, matching: find.byType(NbCard)).first;

Future<FakeAppController> _pumpCards(
  WidgetTester tester,
  String code,
  NodeState state, {
  double width = columnWidth,
}) => pumpColumn(
  tester,
  code,
  state,
  (controller, current) =>
      IncomingCards(controller: controller, state: current),
  width: width,
);

NodeState _warning({
  String id = 's1',
  String? name = senderName,
  String fileName = 'factura.pdf',
  int size = 1536,
  bool isProgram = false,
  bool withoutMark = false,
  String? namesake,
  bool pickerOpen = false,
}) => NodeState(
  incoming: incomingView(
    id: id,
    name: name,
    fileName: fileName,
    size: size,
    isProgram: isProgram,
    withoutMark: withoutMark,
  ),
  incomingNamesake: namesake,
  pickerOpen: pickerOpen,
);

NodeState _question(
  FolderQuestionView folder, {
  String id = 's1',
  String? namesake,
  bool pickerOpen = false,
}) => NodeState(
  incoming: incomingView(
    id: id,
    stage: IncomingStage.folderQuestion,
    folder: folder,
  ),
  incomingNamesake: namesake,
  pickerOpen: pickerOpen,
);

NodeState _ended(
  FolderQuestionView? folder, {
  String id = 's1',
  String? namesake,
  bool pickerOpen = false,
}) => NodeState(
  incoming: incomingView(id: id, stage: IncomingStage.ended, folder: folder),
  incomingNamesake: namesake,
  pickerOpen: pickerOpen,
);

const FolderQuestionView _firstTime = FolderQuestionView(
  kind: FolderQuestionKind.firstTime,
  proposedPath: downloadsPath,
);

const FolderQuestionView _caution = FolderQuestionView(
  kind: FolderQuestionKind.firstTime,
  proposedPath: downloadsPath,
  cautionPath: cautionPath,
  cautionNoMark: true,
);

Finder _glyph(Glyph glyph) => find.byWidgetPredicate(
  (widget) => widget is GlyphIcon && widget.glyph == glyph,
);

Color? _textColor(WidgetTester tester, Finder finder) =>
    tester.widget<Text>(finder).style?.color;

Future<void> _tap(WidgetTester tester, String label) async {
  final button = buttonIn(_cards, label);
  await tester.ensureVisible(button);
  await tester.pump();
  await tester.tap(button);
  await tester.pump();
}

Future<void> _tapOff(WidgetTester tester, String label) async {
  final button = buttonIn(_cards, label);
  await tester.ensureVisible(button);
  await tester.pump();
  await tester.tap(button, warnIfMissed: false);
}

void _expectButtonsInsideCard(WidgetTester tester) {
  final card = tester.getRect(_card);
  for (final element in inside(
    _cards,
    find.byWidgetPredicate((widget) => widget is ButtonStyleButton),
  ).evaluate()) {
    final box = element.renderObject! as RenderBox;
    final rect = box.localToGlobal(Offset.zero) & box.size;
    expect(rect.left, greaterThanOrEqualTo(card.left - 0.01));
    expect(rect.right, lessThanOrEqualTo(card.right + 0.01));
  }
  expect(
    inside(
      find.byType(OverflowBar),
      find.byWidgetPredicate((widget) => widget is ButtonStyleButton),
    ).evaluate().length,
    inside(
      _cards,
      find.byWidgetPredicate((widget) => widget is ButtonStyleButton),
    ).evaluate().length,
  );
}

void main() {
  for (final code in languageCodes) {
    final strings = stringsFor(code);

    group('[$code] E139 warning card', () {
      testWidgets('shows the sender, the fingerprint note, the file, the '
          'expiry note and the two answers', (tester) async {
        await _pumpCards(tester, code, _warning());

        expect(
          textIn(_cards, strings.incomingRequestTitle(senderName)),
          findsOneWidget,
        );
        expect(
          textIn(_cards, strings.foreignSenderNote(senderShort)),
          findsOneWidget,
        );
        expect(strings.foreignSenderNote(senderShort), contains(senderShort));
        expect(
          textIn(_cards, strings.fingerprintLine(senderShort)),
          findsNothing,
        );
        expect(shownFileName(tester, _cards), 'factura.pdf');
        expect(textIn(_cards, formatSize(1536, code)), findsOneWidget);
        expect(formatSize(1536, code), code == 'es' ? '1,5 KB' : '1.5 KB');
        expect(textIn(_cards, strings.incomingExpiresNote), findsOneWidget);
        expect(textIn(_cards, strings.programLabel), findsNothing);
        expect(textIn(_cards, strings.withoutMarkNote), findsNothing);
        expect(buttonLabels(tester, _cards), [
          strings.rejectButton,
          strings.acceptButton,
        ]);
        expect(
          tester.widget(buttonIn(_cards, strings.rejectButton)),
          isA<OutlinedButton>(),
        );
        expect(
          tester.widget(buttonIn(_cards, strings.acceptButton)),
          isA<FilledButton>(),
        );
        expect(tester.takeException(), isNull);
      });

      testWidgets('a program without the mark shows programLabel and '
          'withoutMarkNote', (tester) async {
        await _pumpCards(
          tester,
          code,
          _warning(
            fileName: 'factura.pdf.exe',
            isProgram: true,
            withoutMark: true,
          ),
          width: 350,
        );
        expect(shownFileName(tester, _cards), 'factura.pdf.exe');
        expect(textIn(_cards, strings.programLabel), findsOneWidget);
        expect(textIn(_cards, strings.withoutMarkNote), findsOneWidget);
        expect(
          tester.getTopLeft(textIn(_cards, strings.withoutMarkNote)).dy,
          greaterThan(
            tester.getTopLeft(textIn(_cards, strings.programLabel)).dy,
          ),
        );
      });

      testWidgets('the expiry note sits 8 px above the buttons, in textWeak', (
        tester,
      ) async {
        await _pumpCards(tester, code, _warning());
        final note = textIn(_cards, strings.incomingExpiresNote);
        expect(
          tester.getTopLeft(inside(_cards, find.byType(OverflowBar))).dy -
              tester.getBottomLeft(note).dy,
          closeTo(8, 0.01),
        );
        expect(_textColor(tester, note), _colors.textWeak);
      });

      testWidgets('Reject and Accept answer for the painted session once '
          'armed', (tester) async {
        final controller = await _pumpCards(tester, code, _warning(id: 'rx-9'));
        expect(buttonStates(tester, _cards), [false, false]);
        await tester.tap(
          buttonIn(_cards, strings.acceptButton),
          warnIfMissed: false,
        );
        expect(controller.calls, isEmpty);

        await arm(tester);
        expect(buttonStates(tester, _cards), [true, true]);
        await _tap(tester, strings.rejectButton);
        await _tap(tester, strings.acceptButton);
        expect(controller.calls, [
          'answerIncoming rx-9 false',
          'answerIncoming rx-9 true',
        ]);
      });

      testWidgets('without a name the title uses the first 8 characters of '
          'the fingerprint', (tester) async {
        for (final name in [null, '']) {
          await _pumpCards(tester, code, _warning(name: name));
          expect(
            textIn(_cards, strings.incomingRequestTitle(senderShort)),
            findsOneWidget,
          );
        }
      });

      for (final (tail, extension) in [
        ('.pdf.exe', '.exe'),
        ('.pdf', '.pdf'),
      ]) {
        testWidgets('a name of 300 characters ending in $tail ends in '
            '$extension in the 280 px column and the buttons fit', (
          tester,
        ) async {
          await _pumpCards(
            tester,
            code,
            _warning(
              fileName: longName(tail),
              isProgram: tail == '.pdf.exe',
              withoutMark: true,
            ),
          );
          final shown = shownFileName(tester, _cards);
          expect(shown, endsWith(extension));
          expect(shown, contains('\u2026'));
          if (tail == '.pdf.exe') {
            expect(shown, isNot(contains('.pdf')));
            expect(textIn(_cards, strings.programLabel), findsOneWidget);
          }
          expectNameFits(tester, _cards);
          expect(tester.getSize(_card).width, columnWidth);
          _expectButtonsInsideCard(tester);
          expect(tester.takeException(), isNull);
        });
      }

      testWidgets('the warning card has the warning ring and the warn disc', (
        tester,
      ) async {
        await _pumpCards(tester, code, _warning());
        final card = tester.widget<NbCard>(_card);
        expect(card.ring, _colors.warningRing);
        expect(card.padding, const EdgeInsets.fromLTRB(16, 16, 16, 14));
        final disc = inside(_cards, _glyph(Glyphs.warn));
        expect(disc, findsOneWidget);
        expect(tester.widget<GlyphIcon>(disc).color, _colors.warning);
        expect(find.byType(NbModal), findsNothing);
      });
    });

    group('[$code] E249 namesake', () {
      testWidgets('the warning shows namesakeWarning in danger', (
        tester,
      ) async {
        await _pumpCards(tester, code, _warning(namesake: namesakeName));
        final line = textIn(_cards, strings.namesakeWarning(namesakeName));
        expect(line, findsOneWidget);
        expect(_textColor(tester, line), _colors.danger);
        expect(
          tester.getTopLeft(line).dy,
          greaterThan(
            tester
                .getTopLeft(
                  textIn(_cards, strings.foreignSenderNote(senderShort)),
                )
                .dy,
          ),
        );
      });

      testWidgets('the folder question shows it under the title', (
        tester,
      ) async {
        await _pumpCards(
          tester,
          code,
          _question(_firstTime, namesake: namesakeName),
        );
        final line = textIn(_cards, strings.namesakeWarning(namesakeName));
        expect(line, findsOneWidget);
        expect(_textColor(tester, line), _colors.danger);
        expect(
          tester.getTopLeft(line).dy,
          greaterThan(
            tester
                .getTopLeft(
                  textIn(_cards, strings.folderQuestionTitle(senderName)),
                )
                .dy,
          ),
        );
      });

      testWidgets('without a namesake there is no warning line', (
        tester,
      ) async {
        for (final state in [_warning(), _question(_firstTime)]) {
          await _pumpCards(tester, code, state);
          expect(
            find.byWidgetPredicate(
              (widget) =>
                  widget is Text && widget.style?.color == _colors.danger,
            ),
            findsNothing,
          );
          expect(
            find.text(strings.namesakeWarning(namesakeName)),
            findsNothing,
          );
        }
      });

      testWidgets('the ended panel never shows it', (tester) async {
        await _pumpCards(
          tester,
          code,
          _ended(_firstTime, namesake: namesakeName),
        );
        expect(find.text(strings.namesakeWarning(namesakeName)), findsNothing);
      });
    });

    group('[$code] E140 folder question', () {
      testWidgets('first time: body, proposed folder and the three buttons', (
        tester,
      ) async {
        final controller = await _pumpCards(
          tester,
          code,
          _question(_firstTime),
        );
        expect(
          textIn(_cards, strings.folderQuestionTitle(senderName)),
          findsOneWidget,
        );
        expect(textIn(_cards, strings.folderFirstTimeBody), findsOneWidget);
        expect(textIn(_cards, strings.folderThisTimeBody), findsNothing);
        expect(
          textIn(_cards, strings.proposedFolderLine(downloadsPath)),
          findsOneWidget,
        );
        expect(
          tester
              .widget<Text>(
                textIn(_cards, strings.proposedFolderLine(downloadsPath)),
              )
              .data,
          strings.proposedFolderLine(breakablePath(downloadsPath)),
        );
        expect(textIn(_cards, strings.incomingExpiresNote), findsNothing);
        expect(buttonLabels(tester, _cards), [
          strings.cancelButton,
          strings.chooseOtherFolderButton,
          strings.useThisFolderButton,
        ]);
        expect(
          tester.widget(buttonIn(_cards, strings.cancelButton)),
          isA<OutlinedButton>(),
        );
        expect(
          tester.widget(buttonIn(_cards, strings.chooseOtherFolderButton)),
          isA<OutlinedButton>(),
        );
        expect(
          tester.widget(buttonIn(_cards, strings.useThisFolderButton)),
          isA<FilledButton>(),
        );
        expect(buttonStates(tester, _cards), [false, false, false]);

        await arm(tester);
        expect(buttonStates(tester, _cards), [true, true, true]);
        await _tap(tester, strings.useThisFolderButton);
        await _tap(tester, strings.chooseOtherFolderButton);
        await _tap(tester, strings.cancelButton);
        expect(controller.calls, [
          'useProposedFolder s1',
          'chooseOtherFolder s1',
          'cancelFolderQuestion s1',
        ]);
      });

      testWidgets('this time: the body has no path and the proposal is in '
          'its line', (tester) async {
        await _pumpCards(
          tester,
          code,
          _question(
            const FolderQuestionView(
              kind: FolderQuestionKind.thisTime,
              proposedPath: downloadsPath,
              problem: FolderProblem.rememberedUnavailable,
            ),
          ),
        );
        expect(textIn(_cards, strings.folderThisTimeBody), findsOneWidget);
        expect(textIn(_cards, strings.folderFirstTimeBody), findsNothing);
        expect(strings.folderThisTimeBody, isNot(contains(downloadsPath)));
        expect(
          textIn(_cards, strings.proposedFolderLine(downloadsPath)),
          findsOneWidget,
        );
        expect(
          find.byWidgetPredicate(
            (widget) =>
                widget is Text &&
                shownText(textOf(widget)).contains(downloadsPath),
          ),
          findsOneWidget,
        );
        expect(buttonLabels(tester, _cards).length, 3);
      });

      testWidgets('an empty proposal hides its line and Use this', (
        tester,
      ) async {
        for (final kind in FolderQuestionKind.values) {
          final controller = await _pumpCards(
            tester,
            code,
            _question(FolderQuestionView(kind: kind, proposedPath: '')),
          );
          expect(
            find.textContaining(strings.proposedFolderLine('')),
            findsNothing,
          );
          expect(buttonLabels(tester, _cards), [
            strings.cancelButton,
            strings.chooseOtherFolderButton,
          ]);
          await arm(tester);
          await _tap(tester, strings.chooseOtherFolderButton);
          expect(controller.calls, ['chooseOtherFolder s1']);
        }
      });

      final problems = <FolderProblem, String Function(String)?>{
        FolderProblem.forbidden: strings.folderForbidden,
        FolderProblem.cannotUse: strings.folderCannotUse,
        FolderProblem.unknownVolume: strings.folderUnknownVolume,
        FolderProblem.stillUnavailable: strings.folderStillUnavailable,
        FolderProblem.adminShare: strings.folderAdminShare,
        FolderProblem.rememberedUnavailable: null,
      };
      final allLines = [...problems.values.nonNulls];

      for (final MapEntry(key: problem, value: line) in problems.entries) {
        testWidgets('${problem.name} with its path, without it and with no '
            'path at all', (tester) async {
          for (final (proposed, problemPath, shown) in [
            (downloadsPath, otherPath, otherPath),
            (downloadsPath, null, downloadsPath),
            ('', otherPath, otherPath),
            ('', null, null),
          ]) {
            await _pumpCards(
              tester,
              code,
              _question(
                FolderQuestionView(
                  kind: FolderQuestionKind.firstTime,
                  proposedPath: proposed,
                  problem: problem,
                  problemPath: problemPath,
                ),
              ),
            );
            final reason = '$proposed $problemPath';
            for (final other in allLines) {
              for (final path in [downloadsPath, otherPath, '']) {
                final expected = other == line && path == shown && line != null;
                expect(
                  textIn(_cards, other(path)),
                  expected ? findsOneWidget : findsNothing,
                  reason: '$reason ${other(path)}',
                );
                if (expected) {
                  expect(
                    tester.widget<Text>(textIn(_cards, other(path))).data,
                    other(breakablePath(path)),
                    reason: '$reason ${other(path)}',
                  );
                }
              }
            }
            expect(tester.takeException(), isNull, reason: reason);
          }
        });
      }

      testWidgets('unknownVolume uses its exact text', (tester) async {
        await _pumpCards(
          tester,
          code,
          _question(
            const FolderQuestionView(
              kind: FolderQuestionKind.firstTime,
              proposedPath: downloadsPath,
              problem: FolderProblem.unknownVolume,
              problemPath: otherPath,
            ),
          ),
        );
        final expected = code == 'es'
            ? 'Windows no identifica la unidad de $otherPath, as\u00ED que no '
                  'se puede usar para recibir archivos. Elige otra carpeta.'
            : "Windows doesn't identify the drive of $otherPath, so it can't "
                  'be used to receive files. Choose another folder.';
        expect(textIn(_cards, expected), findsOneWidget);
      });

      for (final (noMark, remote) in [
        (true, false),
        (false, true),
        (true, true),
      ]) {
        testWidgets('a caution${noMark ? ' without the mark' : ''}'
            '${remote ? ' on a remote drive' : ''} offers Use anyway and '
            'Choose another, the safe one first', (tester) async {
          final controller = await _pumpCards(
            tester,
            code,
            _question(
              FolderQuestionView(
                kind: FolderQuestionKind.firstTime,
                proposedPath: downloadsPath,
                cautionPath: cautionPath,
                cautionNoMark: noMark,
                cautionRemote: remote,
              ),
            ),
          );
          expect(
            textIn(_cards, strings.cautionNoMark(cautionPath)),
            noMark ? findsOneWidget : findsNothing,
          );
          expect(
            textIn(_cards, strings.cautionRemote(cautionPath)),
            remote ? findsOneWidget : findsNothing,
          );
          for (final (shown, line) in [
            (noMark, strings.cautionNoMark),
            (remote, strings.cautionRemote),
          ]) {
            if (!shown) continue;
            expect(
              tester.widget<Text>(textIn(_cards, line(cautionPath))).data,
              line(breakablePath(cautionPath)),
            );
          }
          expect(buttonLabels(tester, _cards), [
            strings.useAnywayButton,
            strings.chooseOtherFolderButton,
          ]);
          expect(
            tester.widget(buttonIn(_cards, strings.useAnywayButton)),
            isA<OutlinedButton>(),
          );
          expect(
            tester.widget(buttonIn(_cards, strings.chooseOtherFolderButton)),
            isA<FilledButton>(),
          );
          expect(textIn(_cards, strings.useThisFolderButton), findsNothing);
          expect(textIn(_cards, strings.cancelButton), findsNothing);

          await arm(tester);
          await _tap(tester, strings.useAnywayButton);
          await _tap(tester, strings.chooseOtherFolderButton);
          expect(controller.calls, [
            'useFolderAnyway s1',
            'chooseOtherFolder s1',
          ]);
        });
      }

      for (final (label, folder, pickerOpen, note) in [
        (
          'the folder picker open',
          const FolderQuestionView(
            kind: FolderQuestionKind.firstTime,
            proposedPath: downloadsPath,
            pickerOpen: true,
          ),
          false,
          strings.pickerOpenNote,
        ),
        (
          'the folder being checked',
          const FolderQuestionView(
            kind: FolderQuestionKind.firstTime,
            proposedPath: downloadsPath,
            inspecting: true,
          ),
          false,
          strings.checkingFolder,
        ),
        ('the file picker open', _firstTime, true, null),
        (
          'a caution and the folder picker open',
          const FolderQuestionView(
            kind: FolderQuestionKind.firstTime,
            proposedPath: downloadsPath,
            cautionPath: cautionPath,
            cautionNoMark: true,
            pickerOpen: true,
          ),
          false,
          strings.pickerOpenNote,
        ),
      ]) {
        testWidgets('with $label every button stays off', (tester) async {
          final controller = await _pumpCards(
            tester,
            code,
            _question(folder, pickerOpen: pickerOpen),
          );
          await arm(tester);
          await tester.pump(const Duration(seconds: 2));
          final states = buttonStates(tester, _cards);
          expect(states, isNotEmpty);
          expect(states, everyElement(isFalse));
          for (final candidate in [
            strings.pickerOpenNote,
            strings.checkingFolder,
          ]) {
            expect(
              textIn(_cards, candidate),
              candidate == note ? findsOneWidget : findsNothing,
            );
          }
          if (note != null) {
            expect(_textColor(tester, textIn(_cards, note)), _colors.textWeak);
          }
          for (final button in buttonLabels(tester, _cards)) {
            await _tapOff(tester, button);
          }
          await tester.pump();
          expect(controller.calls, isEmpty);
        });
      }

      testWidgets('three buttons fit the 280 px column', (tester) async {
        await _pumpCards(
          tester,
          code,
          _question(
            const FolderQuestionView(
              kind: FolderQuestionKind.thisTime,
              proposedPath: downloadsPath,
              problem: FolderProblem.cannotUse,
              problemPath: otherPath,
            ),
            namesake: namesakeName,
          ),
        );
        await arm(tester);
        expect(buttonLabels(tester, _cards).length, 3);
        expect(tester.getSize(_card).width, columnWidth);
        _expectButtonsInsideCard(tester);
        expect(tester.takeException(), isNull);
      });

      testWidgets('the question has the warning ring and the folder disc', (
        tester,
      ) async {
        await _pumpCards(tester, code, _question(_firstTime));
        expect(tester.widget<NbCard>(_card).ring, _colors.warningRing);
        final disc = inside(_cards, _glyph(Glyphs.folder)).first;
        expect(tester.widget<GlyphIcon>(disc).color, _colors.warning);
        expect(inside(_cards, _glyph(Glyphs.warn)), findsNothing);
      });

      testWidgets('a folder question without its folder paints nothing', (
        tester,
      ) async {
        final state = NodeState(
          incoming: incomingView(stage: IncomingStage.folderQuestion),
        );
        expect(hasIncomingCard(state), isFalse);
        await _pumpCards(tester, code, state);
        expect(find.byType(NbCard), findsNothing);
        expect(find.byType(ButtonStyleButton), findsNothing);
      });
    });

    group('[$code] E141 ended panel', () {
      testWidgets('without afterEnd says the send ended and offers Close', (
        tester,
      ) async {
        final controller = await _pumpCards(tester, code, _ended(_firstTime));
        expect(textIn(_cards, strings.transferAlreadyEnded), findsOneWidget);
        expect(buttonLabels(tester, _cards), [strings.closeButton]);
        expect(
          tester.widget(buttonIn(_cards, strings.closeButton)),
          isA<OutlinedButton>(),
        );
        expect(buttonStates(tester, _cards), [false]);
        await arm(tester);
        await _tap(tester, strings.closeButton);
        expect(controller.calls, ['dismissFolderPanel s1']);
        expect(textIn(_cards, strings.incomingExpiresNote), findsNothing);
      });

      testWidgets('without a folder view still offers Close', (tester) async {
        final controller = await _pumpCards(tester, code, _ended(null));
        expect(textIn(_cards, strings.transferAlreadyEnded), findsOneWidget);
        expect(buttonLabels(tester, _cards), [strings.closeButton]);
        await arm(tester);
        await _tap(tester, strings.closeButton);
        expect(controller.calls, ['dismissFolderPanel s1']);
      });

      testWidgets('needsConfirmation shows the cautions with Do not remember '
          'first and Remember anyway', (tester) async {
        final controller = await _pumpCards(
          tester,
          code,
          _ended(
            const FolderQuestionView(
              kind: FolderQuestionKind.firstTime,
              proposedPath: downloadsPath,
              cautionPath: cautionPath,
              cautionNoMark: true,
              cautionRemote: true,
              afterEnd: AfterEndResult.needsConfirmation,
            ),
          ),
        );
        expect(
          textIn(_cards, strings.cautionNoMark(cautionPath)),
          findsOneWidget,
        );
        expect(
          textIn(_cards, strings.cautionRemote(cautionPath)),
          findsOneWidget,
        );
        expect(buttonLabels(tester, _cards), [
          strings.dontRememberButton,
          strings.rememberAnywayButton,
        ]);
        expect(
          tester.widget(buttonIn(_cards, strings.dontRememberButton)),
          isA<FilledButton>(),
        );
        expect(
          tester.widget(buttonIn(_cards, strings.rememberAnywayButton)),
          isA<OutlinedButton>(),
        );
        expect(textIn(_cards, strings.closeButton), findsNothing);
        expect(buttonStates(tester, _cards), [false, false]);
        await arm(tester);
        await _tap(tester, strings.rememberAnywayButton);
        await _tap(tester, strings.dontRememberButton);
        expect(controller.calls, [
          'rememberFolderAfterEnd s1 true',
          'rememberFolderAfterEnd s1 false',
        ]);
        _expectButtonsInsideCard(tester);
        expect(tester.takeException(), isNull);
      });

      for (final (label, folder, note) in [
        (
          'the folder picker open',
          const FolderQuestionView(
            kind: FolderQuestionKind.firstTime,
            proposedPath: downloadsPath,
            pickerOpen: true,
            afterEnd: AfterEndResult.needsConfirmation,
            cautionPath: cautionPath,
            cautionNoMark: true,
          ),
          strings.pickerOpenNote,
        ),
        (
          'the folder being checked',
          const FolderQuestionView(
            kind: FolderQuestionKind.firstTime,
            proposedPath: downloadsPath,
            inspecting: true,
            afterEnd: AfterEndResult.remembered,
          ),
          strings.checkingFolder,
        ),
      ]) {
        testWidgets('with $label shows only its note and no buttons', (
          tester,
        ) async {
          await _pumpCards(tester, code, _ended(folder));
          await arm(tester);
          expect(textIn(_cards, strings.transferAlreadyEnded), findsOneWidget);
          expect(textIn(_cards, note), findsOneWidget);
          expect(buttonLabels(tester, _cards), isEmpty);
          expect(
            textIn(_cards, strings.folderRememberedNote(downloadsPath)),
            findsNothing,
          );
          expect(
            textIn(_cards, strings.cautionNoMark(cautionPath)),
            findsNothing,
          );
        });
      }

      testWidgets('with the file picker open its buttons stay off', (
        tester,
      ) async {
        for (final folder in [
          _firstTime,
          const FolderQuestionView(
            kind: FolderQuestionKind.firstTime,
            proposedPath: downloadsPath,
            cautionPath: cautionPath,
            cautionNoMark: true,
            afterEnd: AfterEndResult.needsConfirmation,
          ),
        ]) {
          final controller = await _pumpCards(
            tester,
            code,
            _ended(folder, pickerOpen: true),
          );
          await arm(tester);
          final states = buttonStates(tester, _cards);
          expect(states, isNotEmpty);
          expect(states, everyElement(isFalse));
          for (final button in buttonLabels(tester, _cards)) {
            await _tapOff(tester, button);
          }
          expect(controller.calls, isEmpty);
        }
      });

      testWidgets('the ended panel has no ring and a folder disc on '
          'surfaceWeak', (tester) async {
        await _pumpCards(tester, code, _ended(_firstTime));
        expect(tester.widget<NbCard>(_card).ring, isNull);
        final disc = inside(_cards, _glyph(Glyphs.folder));
        expect(disc, findsOneWidget);
        expect(tester.widget<GlyphIcon>(disc).color, _colors.textWeak);
        final fill = find.ancestor(
          of: disc,
          matching: find.byWidgetPredicate(
            (widget) =>
                widget is Container &&
                widget.decoration is BoxDecoration &&
                (widget.decoration! as BoxDecoration).color ==
                    _colors.surfaceWeak,
          ),
        );
        expect(fill, findsOneWidget);
        expect(inside(_cards, _glyph(Glyphs.warn)), findsNothing);
      });
    });

    group('[$code] E272 notes after the end use afterEndPath (RF-209)', () {
      const windowsTemp = r'C:\Windows\Temp';

      List<String> cardTexts(WidgetTester tester) => [
        for (final text in tester.widgetList<Text>(
          inside(_cards, find.byType(Text)),
        ))
          shownText(textOf(text)),
      ];

      void expectNoPathBut(WidgetTester tester, String? shown) {
        for (final path in [
          downloadsPath,
          otherPath,
          cautionPath,
          windowsTemp,
        ]) {
          if (path == shown) continue;
          expect(
            cardTexts(tester).where((text) => text.contains(path)),
            isEmpty,
            reason: path,
          );
        }
      }

      testWidgets('remembered names afterEndPath and never the proposed '
          'folder', (tester) async {
        final controller = await _pumpCards(
          tester,
          code,
          _ended(
            const FolderQuestionView(
              kind: FolderQuestionKind.firstTime,
              proposedPath: downloadsPath,
              afterEnd: AfterEndResult.remembered,
              afterEndPath: otherPath,
            ),
          ),
        );
        expect(textIn(_cards, strings.transferAlreadyEnded), findsOneWidget);
        expect(
          textIn(_cards, strings.folderRememberedNote(otherPath)),
          findsOneWidget,
        );
        expectNoPathBut(tester, otherPath);
        expect(buttonLabels(tester, _cards), [strings.closeButton]);
        await arm(tester);
        await _tap(tester, strings.closeButton);
        expect(controller.calls, ['dismissFolderPanel s1']);
      });

      testWidgets('the view of case g of E271 names the proposal it '
          'remembered', (tester) async {
        await _pumpCards(
          tester,
          code,
          _ended(
            const FolderQuestionView(
              kind: FolderQuestionKind.firstTime,
              proposedPath: downloadsPath,
              afterEnd: AfterEndResult.remembered,
              afterEndPath: downloadsPath,
            ),
          ),
        );
        expect(
          textIn(_cards, strings.folderRememberedNote(downloadsPath)),
          findsOneWidget,
        );
        expect(buttonLabels(tester, _cards), [strings.closeButton]);
      });

      testWidgets('notUsable names afterEndPath and offers Close', (
        tester,
      ) async {
        final controller = await _pumpCards(
          tester,
          code,
          _ended(
            const FolderQuestionView(
              kind: FolderQuestionKind.firstTime,
              proposedPath: downloadsPath,
              afterEnd: AfterEndResult.notUsable,
              afterEndPath: windowsTemp,
            ),
          ),
        );
        expect(
          textIn(_cards, strings.folderNotUsable(windowsTemp)),
          findsOneWidget,
        );
        expect(
          textIn(_cards, strings.folderRememberedNote(windowsTemp)),
          findsNothing,
        );
        expectNoPathBut(tester, windowsTemp);
        expect(buttonLabels(tester, _cards), [strings.closeButton]);
        await arm(tester);
        await _tap(tester, strings.closeButton);
        expect(controller.calls, ['dismissFolderPanel s1']);
      });

      for (final result in [
        AfterEndResult.remembered,
        AfterEndResult.notUsable,
      ]) {
        testWidgets('${result.name} ignores the problem, caution and '
            'proposed paths', (tester) async {
          await _pumpCards(
            tester,
            code,
            _ended(
              FolderQuestionView(
                kind: FolderQuestionKind.firstTime,
                proposedPath: downloadsPath,
                problem: FolderProblem.cannotUse,
                problemPath: otherPath,
                cautionPath: cautionPath,
                cautionNoMark: true,
                afterEnd: result,
                afterEndPath: windowsTemp,
              ),
            ),
          );
          final note = result == AfterEndResult.remembered
              ? strings.folderRememberedNote(windowsTemp)
              : strings.folderNotUsable(windowsTemp);
          expect(textIn(_cards, note), findsOneWidget);
          expectNoPathBut(tester, windowsTemp);
          expect(buttonLabels(tester, _cards), [strings.closeButton]);
        });

        for (final missing in [null, '']) {
          testWidgets('${result.name} with afterEndPath '
              '${missing == null ? 'null' : 'empty'} shows only the end and '
              'Close, with no fallback path', (tester) async {
            await _pumpCards(
              tester,
              code,
              _ended(
                FolderQuestionView(
                  kind: FolderQuestionKind.firstTime,
                  proposedPath: downloadsPath,
                  problemPath: otherPath,
                  afterEnd: result,
                  afterEndPath: missing,
                ),
              ),
            );
            expect(cardTexts(tester), [
              strings.transferAlreadyEnded,
              strings.closeButton,
            ]);
            expect(find.text(strings.folderRememberedNote('')), findsNothing);
            expect(find.text(strings.folderNotUsable('')), findsNothing);
            expectNoPathBut(tester, null);
            expect(buttonLabels(tester, _cards), [strings.closeButton]);
          });
        }
      }

      testWidgets('two views that only differ in afterEndPath: the note '
          'follows and Close is off again for 500 ms', (tester) async {
        FolderQuestionView remembered(String path) => FolderQuestionView(
          kind: FolderQuestionKind.firstTime,
          proposedPath: downloadsPath,
          afterEnd: AfterEndResult.remembered,
          afterEndPath: path,
        );
        final controller = await _pumpCards(
          tester,
          code,
          _ended(remembered(otherPath)),
        );
        await arm(tester);
        expect(buttonStates(tester, _cards), [true]);

        controller.emit(_ended(remembered(cautionPath)));
        await tester.pump();
        expect(
          textIn(_cards, strings.folderRememberedNote(cautionPath)),
          findsOneWidget,
        );
        expect(
          textIn(_cards, strings.folderRememberedNote(otherPath)),
          findsNothing,
        );
        expect(buttonStates(tester, _cards), [false]);
        await tester.pump(justBeforeArmed);
        expect(buttonStates(tester, _cards), [false]);
        await _tapOff(tester, strings.closeButton);
        await tester.pump();
        expect(controller.calls, isEmpty);
        await tester.pump(lastMillisecond);
        expect(buttonStates(tester, _cards), [true]);
        await _tap(tester, strings.closeButton);
        expect(controller.calls, ['dismissFolderPanel s1']);
      });
    });

    group('[$code] E246 session of the painted card', () {
      Future<void> check(
        WidgetTester tester,
        NodeState Function(String id) build,
        Map<String, String> expected,
      ) async {
        final controller = await _pumpCards(tester, code, build('s1'));
        await arm(tester);
        for (final label in expected.keys) {
          await _tap(tester, label);
        }
        controller.emit(build('s2'));
        await tester.pump();
        expect(buttonStates(tester, _cards), everyElement(isFalse));
        await tester.pump(justBeforeArmed);
        expect(buttonStates(tester, _cards), everyElement(isFalse));
        for (final label in expected.keys) {
          await _tapOff(tester, label);
        }
        await tester.pump(lastMillisecond);
        expect(buttonStates(tester, _cards), everyElement(isTrue));
        for (final label in expected.keys) {
          await _tap(tester, label);
        }
        expect(controller.calls, [
          for (final call in expected.values) call.replaceAll('<id>', 's1'),
          for (final call in expected.values) call.replaceAll('<id>', 's2'),
        ]);
      }

      testWidgets('the warning answers with s1 and then with s2', (
        tester,
      ) async {
        await check(tester, (id) => _warning(id: id), {
          strings.acceptButton: 'answerIncoming <id> true',
          strings.rejectButton: 'answerIncoming <id> false',
        });
      });

      testWidgets('the folder question answers with s1 and then with s2', (
        tester,
      ) async {
        await check(tester, (id) => _question(_firstTime, id: id), {
          strings.useThisFolderButton: 'useProposedFolder <id>',
          strings.chooseOtherFolderButton: 'chooseOtherFolder <id>',
          strings.cancelButton: 'cancelFolderQuestion <id>',
        });
      });

      testWidgets('the caution answers with s1 and then with s2', (
        tester,
      ) async {
        await check(tester, (id) => _question(_caution, id: id), {
          strings.useAnywayButton: 'useFolderAnyway <id>',
          strings.chooseOtherFolderButton: 'chooseOtherFolder <id>',
        });
      });

      testWidgets('the ended panel answers with s1 and then with s2', (
        tester,
      ) async {
        await check(
          tester,
          (id) => _ended(
            const FolderQuestionView(
              kind: FolderQuestionKind.firstTime,
              proposedPath: downloadsPath,
              cautionPath: cautionPath,
              cautionNoMark: true,
              afterEnd: AfterEndResult.needsConfirmation,
            ),
            id: id,
          ),
          {
            strings.rememberAnywayButton: 'rememberFolderAfterEnd <id> true',
            strings.dontRememberButton: 'rememberFolderAfterEnd <id> false',
          },
        );
        await check(tester, (id) => _ended(_firstTime, id: id), {
          strings.closeButton: 'dismissFolderPanel <id>',
        });
      });

      testWidgets('the receiving card cancels s1 and then s2', (tester) async {
        final controller = await pumpColumn(
          tester,
          code,
          NodeState(incoming: incomingView(stage: IncomingStage.receiving)),
          (controller, state) =>
              ActivityPanel(controller: controller, state: state),
        );
        final card = find.byKey(const ValueKey('activity-incoming'));
        await arm(tester);
        await tester.tap(buttonIn(card, strings.cancelButton));
        controller.emit(
          NodeState(
            incoming: incomingView(id: 's2', stage: IncomingStage.receiving),
          ),
        );
        await tester.pump();
        expect(
          isEnabled(tester, buttonIn(card, strings.cancelButton)),
          isFalse,
        );
        await arm(tester);
        await tester.tap(buttonIn(card, strings.cancelButton));
        await tester.pump();
        expect(controller.calls, ['cancelReceiving s1', 'cancelReceiving s2']);
      });
    });

    group('[$code] E247 arming of the top cards', () {
      testWidgets('a new warning is off at 0 and 499 ms and on at 500 ms', (
        tester,
      ) async {
        await _pumpCards(tester, code, _warning());
        expect(buttonStates(tester, _cards), [false, false]);
        await tester.pump(justBeforeArmed);
        expect(buttonStates(tester, _cards), [false, false]);
        await tester.pump(lastMillisecond);
        expect(buttonStates(tester, _cards), [true, true]);
      });

      testWidgets('warning to folder question with the same id disarms for '
          '0.5 s', (tester) async {
        final controller = await _pumpCards(tester, code, _warning());
        await arm(tester);
        controller.emit(_question(_firstTime));
        await tester.pump();
        expect(buttonStates(tester, _cards), [false, false, false]);
        await tester.pump(justBeforeArmed);
        expect(buttonStates(tester, _cards), [false, false, false]);
        await tester.pump(lastMillisecond);
        expect(buttonStates(tester, _cards), [true, true, true]);
      });
    });

    group('[$code] E273 pickers and checking disarm the top cards (RF-151, '
        'RF-198, RF-200, RF-202, RF-206, RF-209)', () {
      Future<void> expectRearms(
        WidgetTester tester,
        FakeAppController controller,
        String label,
        String call,
      ) async {
        final labels = buttonLabels(tester, _cards);
        expect(labels, isNotEmpty);
        expect(buttonStates(tester, _cards), everyElement(isFalse));
        await tester.pump(justBeforeArmed);
        expect(buttonStates(tester, _cards), everyElement(isFalse));
        for (final button in labels) {
          await _tapOff(tester, button);
        }
        await tester.pump();
        expect(controller.calls, isEmpty);
        await tester.pump(lastMillisecond);
        expect(buttonStates(tester, _cards), everyElement(isTrue));
        await _tap(tester, label);
        expect(controller.calls, [call]);
      }

      Future<void> expectStaysOff(
        WidgetTester tester,
        FakeAppController controller,
      ) async {
        expect(buttonStates(tester, _cards), everyElement(isFalse));
        await tester.pump(const Duration(seconds: 1));
        expect(buttonStates(tester, _cards), everyElement(isFalse));
        for (final button in buttonLabels(tester, _cards)) {
          await _tapOff(tester, button);
        }
        await tester.pump();
        expect(controller.calls, isEmpty);
      }

      testWidgets('an armed warning goes off when the file picker opens, '
          'stays off after 1 s and rearms 500 ms after it closes', (
        tester,
      ) async {
        final controller = await _pumpCards(tester, code, _warning());
        await arm(tester);
        expect(buttonStates(tester, _cards), [true, true]);

        controller.emit(_warning(pickerOpen: true));
        await tester.pump();
        expect(buttonLabels(tester, _cards), [
          strings.rejectButton,
          strings.acceptButton,
        ]);
        await expectStaysOff(tester, controller);

        controller.emit(_warning());
        await tester.pump();
        await expectRearms(
          tester,
          controller,
          strings.acceptButton,
          'answerIncoming s1 true',
        );
      });

      testWidgets('a warning that arrives with the file picker open stays '
          'off and rearms 500 ms after it closes', (tester) async {
        final controller = await _pumpCards(
          tester,
          code,
          _warning(pickerOpen: true),
        );
        await arm(tester);
        await expectStaysOff(tester, controller);

        controller.emit(_warning());
        await tester.pump();
        await expectRearms(
          tester,
          controller,
          strings.rejectButton,
          'answerIncoming s1 false',
        );
      });

      testWidgets('the folder question goes off with the folder picker and '
          'rearms 500 ms after it closes', (tester) async {
        final controller = await _pumpCards(
          tester,
          code,
          _question(_firstTime),
        );
        await arm(tester);
        expect(buttonStates(tester, _cards), [true, true, true]);

        controller.emit(
          _question(
            const FolderQuestionView(
              kind: FolderQuestionKind.firstTime,
              proposedPath: downloadsPath,
              pickerOpen: true,
            ),
          ),
        );
        await tester.pump();
        await expectStaysOff(tester, controller);

        controller.emit(_question(_firstTime));
        await tester.pump();
        await expectRearms(
          tester,
          controller,
          strings.useThisFolderButton,
          'useProposedFolder s1',
        );
      });

      testWidgets('the folder question goes off while the folder is checked '
          'and rearms 500 ms after the check ends', (tester) async {
        final controller = await _pumpCards(
          tester,
          code,
          _question(_firstTime),
        );
        await arm(tester);

        controller.emit(
          _question(
            const FolderQuestionView(
              kind: FolderQuestionKind.firstTime,
              proposedPath: downloadsPath,
              inspecting: true,
            ),
          ),
        );
        await tester.pump();
        await expectStaysOff(tester, controller);

        controller.emit(_question(_caution));
        await tester.pump();
        await expectRearms(
          tester,
          controller,
          strings.useAnywayButton,
          'useFolderAnyway s1',
        );
      });

      testWidgets('the folder question goes off with the file picker and '
          'rearms 500 ms after it closes', (tester) async {
        final controller = await _pumpCards(
          tester,
          code,
          _question(_firstTime),
        );
        await arm(tester);

        controller.emit(_question(_firstTime, pickerOpen: true));
        await tester.pump();
        await expectStaysOff(tester, controller);

        controller.emit(_question(_firstTime));
        await tester.pump();
        await expectRearms(
          tester,
          controller,
          strings.cancelButton,
          'cancelFolderQuestion s1',
        );
      });

      testWidgets('the ended panel goes off with the file picker and '
          'Close rearms 500 ms after it closes', (tester) async {
        const remembered = FolderQuestionView(
          kind: FolderQuestionKind.firstTime,
          proposedPath: downloadsPath,
          afterEnd: AfterEndResult.remembered,
          afterEndPath: otherPath,
        );
        final controller = await _pumpCards(tester, code, _ended(remembered));
        await arm(tester);
        expect(buttonStates(tester, _cards), [true]);

        controller.emit(_ended(remembered, pickerOpen: true));
        await tester.pump();
        expect(buttonLabels(tester, _cards), [strings.closeButton]);
        await expectStaysOff(tester, controller);

        controller.emit(_ended(remembered));
        await tester.pump();
        await expectRearms(
          tester,
          controller,
          strings.closeButton,
          'dismissFolderPanel s1',
        );
      });

      for (final (label, busy) in [
        (
          'the folder picker',
          const FolderQuestionView(
            kind: FolderQuestionKind.firstTime,
            proposedPath: downloadsPath,
            pickerOpen: true,
          ),
        ),
        (
          'the check',
          const FolderQuestionView(
            kind: FolderQuestionKind.firstTime,
            proposedPath: downloadsPath,
            inspecting: true,
          ),
        ),
      ]) {
        testWidgets('after $label of the ended panel, its buttons wait '
            '500 ms', (tester) async {
          final controller = await _pumpCards(tester, code, _ended(busy));
          await arm(tester);
          expect(buttonLabels(tester, _cards), isEmpty);

          controller.emit(
            _ended(
              const FolderQuestionView(
                kind: FolderQuestionKind.firstTime,
                proposedPath: downloadsPath,
                afterEnd: AfterEndResult.remembered,
                afterEndPath: otherPath,
              ),
            ),
          );
          await tester.pump();
          await expectRearms(
            tester,
            controller,
            strings.closeButton,
            'dismissFolderPanel s1',
          );

          controller.calls.clear();
          controller.emit(_ended(busy));
          await tester.pump();
          await arm(tester);
          controller.emit(
            _ended(
              const FolderQuestionView(
                kind: FolderQuestionKind.firstTime,
                proposedPath: downloadsPath,
                cautionPath: cautionPath,
                cautionNoMark: true,
                afterEnd: AfterEndResult.needsConfirmation,
              ),
            ),
          );
          await tester.pump();
          await expectRearms(
            tester,
            controller,
            strings.rememberAnywayButton,
            'rememberFolderAfterEnd s1 true',
          );
        });
      }

      testWidgets('a new problem, path, caution, afterEnd or afterEndPath '
          'disarms, and so do the picker and the check', (tester) async {
        final controller = await _pumpCards(
          tester,
          code,
          _question(_firstTime),
        );
        await arm(tester);
        for (final folder in [
          const FolderQuestionView(
            kind: FolderQuestionKind.firstTime,
            proposedPath: downloadsPath,
            problem: FolderProblem.cannotUse,
          ),
          const FolderQuestionView(
            kind: FolderQuestionKind.firstTime,
            proposedPath: downloadsPath,
            problem: FolderProblem.cannotUse,
            problemPath: otherPath,
          ),
          _caution,
          const FolderQuestionView(
            kind: FolderQuestionKind.firstTime,
            proposedPath: downloadsPath,
            cautionPath: cautionPath,
            cautionNoMark: true,
            inspecting: true,
          ),
          _caution,
          const FolderQuestionView(
            kind: FolderQuestionKind.firstTime,
            proposedPath: downloadsPath,
            cautionPath: cautionPath,
            cautionNoMark: true,
            pickerOpen: true,
          ),
          _caution,
        ]) {
          controller.emit(_question(folder));
          await tester.pump();
          expect(
            buttonStates(tester, _cards),
            everyElement(isFalse),
            reason: '$folder',
          );
          await arm(tester);
          if (!folder.inspecting && !folder.pickerOpen) {
            expect(buttonStates(tester, _cards), everyElement(isTrue));
          }
        }

        for (final folder in [
          _caution,
          const FolderQuestionView(
            kind: FolderQuestionKind.firstTime,
            proposedPath: downloadsPath,
            cautionPath: cautionPath,
            cautionNoMark: true,
            afterEnd: AfterEndResult.needsConfirmation,
          ),
          const FolderQuestionView(
            kind: FolderQuestionKind.firstTime,
            proposedPath: downloadsPath,
            afterEnd: AfterEndResult.remembered,
            afterEndPath: cautionPath,
          ),
          const FolderQuestionView(
            kind: FolderQuestionKind.firstTime,
            proposedPath: downloadsPath,
            afterEnd: AfterEndResult.remembered,
            afterEndPath: otherPath,
          ),
        ]) {
          controller.emit(_ended(folder));
          await tester.pump();
          expect(
            buttonStates(tester, _cards),
            everyElement(isFalse),
            reason: '$folder',
          );
          await arm(tester);
          expect(buttonStates(tester, _cards), everyElement(isTrue));
        }
        expect(controller.calls, isEmpty);
      });
    });

    group('[$code] E270 top cards in the home screen', () {
      final paired = entry(
        fingerprint: senderFingerprint,
        name: senderName,
        paired: true,
      );

      Future<FakeAppController> mount(
        WidgetTester tester,
        IncomingTransferView incoming,
      ) async {
        setWindow(tester, const Size(800, 600));
        final controller = FakeAppController(
          state: NodeState(
            entries: [paired],
            incoming: incoming,
            lastSent: resultView(direction: TransferDirection.outgoing),
            notices: const [Notice(id: 1, kind: NoticeKind.pairingPaused)],
          ),
        );
        await pumpHome(tester, controller, code, settle: false);
        await tester.pump(const Duration(milliseconds: 600));
        return controller;
      }

      for (final (stage, folder, ring, glyph) in [
        (IncomingStage.warning, null, true, Glyphs.warn),
        (IncomingStage.folderQuestion, _firstTime, true, Glyphs.folder),
        (IncomingStage.ended, _firstTime, false, Glyphs.folder),
      ]) {
        testWidgets('${stage.name}: top card, notices, tabs and content, in '
            'that order, without dialogs or layout errors', (tester) async {
          await mount(tester, incomingView(stage: stage, folder: folder));

          expect(tester.takeException(), isNull);
          expect(_cards, findsOneWidget);
          expect(find.byType(NbModal), findsNothing);
          expect(find.byType(ActivityPanel), findsOneWidget);
          final card = tester.widget<NbCard>(_card);
          expect(card.ring, ring ? _colors.warningRing : isNull);
          expect(inside(_cards, _glyph(glyph)), findsWidgets);
          expect(tester.getSize(_card).width, columnWidth);

          double top(Finder finder) => tester.getTopLeft(finder).dy;
          final order = [
            top(_cards),
            top(find.text(strings.noticePairingPaused)),
            top(find.text(strings.activityTab)),
            top(find.byType(ActivityPanel)),
          ];
          for (var i = 1; i < order.length; i++) {
            expect(order[i], greaterThan(order[i - 1]), reason: 'block $i');
          }
          expect(
            tester.getBottomLeft(_cards).dy,
            lessThan(top(find.text(strings.noticePairingPaused))),
          );
        });
      }

      testWidgets('a receiving session has no top card, only its Activity '
          'card', (tester) async {
        await mount(tester, incomingView(stage: IncomingStage.receiving));
        expect(_cards, findsNothing);
        expect(find.byKey(const ValueKey('activity-incoming')), findsOneWidget);
        expect(tester.takeException(), isNull);
      });

      testWidgets('every top card at 800x600 with long texts has no layout '
          'errors', (tester) async {
        final controller = await mount(
          tester,
          incomingView(
            fileName: longName('.pdf.exe'),
            isProgram: true,
            withoutMark: true,
            name: 'Un equipo con un nombre muy largo de verdad',
          ),
        );
        final views = [
          incomingView(
            stage: IncomingStage.folderQuestion,
            folder: const FolderQuestionView(
              kind: FolderQuestionKind.thisTime,
              proposedPath: r'C:\Users\Ana\Downloads\NexusBridges\una\ruta\muy\larga\de\verdad',
              problem: FolderProblem.adminShare,
            ),
          ),
          incomingView(stage: IncomingStage.folderQuestion, folder: _caution),
          incomingView(
            stage: IncomingStage.ended,
            folder: const FolderQuestionView(
              kind: FolderQuestionKind.firstTime,
              proposedPath: downloadsPath,
              cautionPath: cautionPath,
              cautionNoMark: true,
              cautionRemote: true,
              afterEnd: AfterEndResult.needsConfirmation,
            ),
          ),
        ];
        for (final view in views) {
          controller.emit(
            NodeState(
              entries: [paired],
              incoming: view,
              incomingNamesake: namesakeName,
            ),
          );
          await tester.pump(const Duration(milliseconds: 600));
          expect(tester.takeException(), isNull, reason: '${view.stage}');
        }
      }, timeout: const Timeout(Duration(seconds: 60)));
    });

    group('[$code] RF-217 the list stays usable with a card open', () {
      testWidgets('with the warning open, the row menu unpairs the sender', (
        tester,
      ) async {
        setWindow(tester, const Size(800, 600));
        final controller = FakeAppController(
          state: NodeState(
            entries: [
              entry(
                fingerprint: senderFingerprint,
                name: senderName,
                paired: true,
              ),
            ],
            incoming: incomingView(),
          ),
        );
        await pumpHome(tester, controller, code, settle: false);
        await tester.pump(const Duration(milliseconds: 600));
        expect(_cards, findsOneWidget);
        expect(find.byType(DeviceList), findsOneWidget);

        final row = find.byKey(ValueKey(senderFingerprint));
        await tester.tap(inside(row, find.byTooltip(strings.moreOptions)));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 500));
        await tester.tap(find.text(strings.unpairButton).last);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 500));
        expect(find.text(strings.unpairTitle(senderName)), findsOneWidget);
        await tester.tap(
          find.descendant(
            of: find.byType(NbModal),
            matching: find.widgetWithText(ModalButton, strings.unpairButton),
          ),
        );
        expect(controller.calls, ['unpair $senderFingerprint']);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 500));
        expect(controller.calls, ['unpair $senderFingerprint']);
        expect(_cards, findsOneWidget);

        await tester.pump(const Duration(milliseconds: 1000));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 400));
        await tester.pump();
        expect(find.byType(NbModal), findsNothing);
        expect(controller.calls, ['unpair $senderFingerprint']);
        expect(_cards, findsOneWidget);
      });

      testWidgets('with the folder question open, the tabs still switch and '
          'Send file still works', (tester) async {
        setWindow(tester, const Size(800, 600));
        final other = fingerprintOf('EEEE5555');
        final controller = FakeAppController(
          state: NodeState(
            entries: [
              entry(
                fingerprint: other,
                name: 'Torre',
                paired: true,
                mine: true,
              ),
            ],
            incoming: incomingView(
              stage: IncomingStage.folderQuestion,
              folder: _firstTime,
            ),
          ),
        );
        await pumpHome(tester, controller, code, settle: false);
        await tester.pump(const Duration(milliseconds: 600));

        await tester.tap(find.text(strings.activityTab));
        await tester.pump(const Duration(milliseconds: 400));
        expect(find.byType(ActivityPanel), findsOneWidget);
        await tester.tap(find.text(strings.devicesTab));
        await tester.pump(const Duration(milliseconds: 400));
        expect(find.byType(DeviceList), findsOneWidget);

        final send = inside(
          find.byKey(ValueKey(other)),
          find.text(strings.sendEllipsis),
        );
        await tester.ensureVisible(send);
        await tester.pump();
        await tester.tap(send);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 240));
        await tester.tap(find.text(strings.sendFilesOption));
        await tester.pump();
        expect(controller.calls, ['sendFiles $other']);
        expect(_cards, findsOneWidget);
      });
    });

    group('[$code] E139 card withdrawn by the sender', () {
      testWidgets('the card goes, the notice names the sender and the last '
          'received card stays the same', (tester) async {
        setWindow(tester, const Size(800, 600));
        final previous = resultView(fileName: 'anterior.txt');
        final controller = FakeAppController(
          state: NodeState(incoming: incomingView(), lastReceived: previous),
        );
        await pumpHome(tester, controller, code, settle: false);
        await tester.pump(const Duration(milliseconds: 600));
        final received = find.byKey(const ValueKey('activity-last-received'));
        expect(_cards, findsOneWidget);
        final before = [
          for (final text in tester.widgetList<Text>(
            inside(received, find.byType(Text)),
          ))
            text.data,
        ];

        controller.emit(
          NodeState(
            lastReceived: previous,
            notices: const [
              Notice(
                id: 7,
                kind: NoticeKind.peerCancelledTransfer,
                detail: '$senderName \u00B7 $senderShort',
              ),
            ],
          ),
        );
        await tester.pump(const Duration(milliseconds: 600));
        expect(_cards, findsNothing);
        expect(
          find.text(
            code == 'es'
                ? 'Port\u00E1til de Ana \u00B7 ABCD1234 cancel\u00F3 el env\u00EDo.'
                : 'Port\u00E1til de Ana \u00B7 ABCD1234 cancelled the send.',
          ),
          findsOneWidget,
        );
        expect([
          for (final text in tester.widgetList<Text>(
            inside(received, find.byType(Text)),
          ))
            text.data,
        ], before);
        expect(tester.takeException(), isNull);
      });
    });

    group('[$code] point 151 expiry note only in the warning', () {
      testWidgets('no other card shows incomingExpiresNote', (tester) async {
        for (final state in [
          _question(_firstTime),
          _question(_caution),
          _ended(_firstTime),
          NodeState(incoming: incomingView(stage: IncomingStage.waitingData)),
          NodeState(incoming: incomingView(stage: IncomingStage.receiving)),
          NodeState(incoming: incomingView(stage: IncomingStage.verifying)),
        ]) {
          setWindow(tester, const Size(800, 600));
          final controller = FakeAppController(state: state);
          await pumpHome(tester, controller, code, settle: false);
          await tester.pump(const Duration(milliseconds: 600));
          expect(find.text(strings.incomingExpiresNote), findsNothing);
          await tester.pumpWidget(const SizedBox());
        }
      });
    });
  }

  test('hasIncomingCard is true only for warning, a folder question with its '
      'folder and ended', () {
    for (final stage in IncomingStage.values) {
      final expected = switch (stage) {
        IncomingStage.warning ||
        IncomingStage.folderQuestion ||
        IncomingStage.ended => true,
        _ => false,
      };
      expect(
        hasIncomingCard(
          NodeState(
            incoming: incomingView(stage: stage, folder: _firstTime),
          ),
        ),
        expected,
        reason: '$stage',
      );
    }
    expect(hasIncomingCard(const NodeState()), isFalse);
  });

  testWidgets('every text of the top cards comes from AppStrings and differs '
      'between languages', (tester) async {
    final rendered = <String, Set<String>>{};
    for (final code in languageCodes) {
      final seen = <String>{};
      for (final state in [
        _warning(isProgram: true, withoutMark: true, namesake: namesakeName),
        _question(_caution),
        _ended(_firstTime),
      ]) {
        await _pumpCards(tester, code, state);
        seen.addAll(visibleTexts(tester));
      }
      seen.remove('factura.pdf');
      seen.remove(formatSize(1536, code));
      rendered[code] = seen;
      await tester.pumpWidget(const SizedBox());
    }
    expect(rendered['es']!.intersection(rendered['en']!), isEmpty);
  });

  group('point 245: with Segoe UI the path of the folder question only breaks '
      'after a separator, never after the drive', () {
    setUpAll(loadSegoe);

    const longPath = r'C:\Users\Ana\Documents\Proyectos\NexusBridges\Recibidos';

    final cases = <String, (FolderQuestionView, String Function(AppStrings))>{
      'proposal': (
        const FolderQuestionView(
          kind: FolderQuestionKind.firstTime,
          proposedPath: longPath,
        ),
        (strings) => strings.proposedFolderLine(longPath),
      ),
      'problem': (
        const FolderQuestionView(
          kind: FolderQuestionKind.firstTime,
          proposedPath: downloadsPath,
          problem: FolderProblem.forbidden,
          problemPath: longPath,
        ),
        (strings) => strings.folderForbidden(longPath),
      ),
      'caution': (
        const FolderQuestionView(
          kind: FolderQuestionKind.firstTime,
          proposedPath: downloadsPath,
          cautionPath: longPath,
          cautionNoMark: true,
        ),
        (strings) => strings.cautionNoMark(longPath),
      ),
    };

    List<int> lineStarts(RenderParagraph paragraph) {
      final data = paragraph.text.toPlainText();
      final starts = <int>[];
      double? previousTop;
      for (var i = 0; i < data.length; i++) {
        if (data[i] == zeroWidthSpace) continue;
        final boxes = paragraph.getBoxesForSelection(
          TextSelection(baseOffset: i, extentOffset: i + 1),
        );
        if (boxes.isEmpty) continue;
        final top = boxes.first.top;
        if (previousTop != null && top > previousTop + 1) starts.add(i);
        previousTop = top;
      }
      return starts;
    }

    for (final code in languageCodes) {
      final strings = stringsFor(code);
      for (final MapEntry(key: name, value: (folder, line)) in cases.entries) {
        for (final scale in [1.0, 1.3]) {
          testWidgets('[$code] $name at ${(scale * 100).round()} %: from 280 '
              'to 400 px every break inside the path follows a backslash and '
              'the path is whole', (tester) async {
            tester.platformDispatcher.textScaleFactorTestValue = scale;
            addTearDown(
              tester.platformDispatcher.clearTextScaleFactorTestValue,
            );
            var breaksInPath = 0;
            for (var width = 280.0; width <= 400; width += 1) {
              await _pumpCards(tester, code, _question(folder), width: width);
              expect(tester.takeException(), isNull, reason: '$width');
              final text = textIn(_cards, line(strings));
              expect(text, findsOneWidget, reason: '$width');
              final paragraph = tester.renderObject<RenderParagraph>(
                inside(text, find.byType(RichText)),
              );
              expect(paragraph.didExceedMaxLines, isFalse, reason: '$width');
              final data = paragraph.text.toPlainText();
              expect(shownText(data), line(strings), reason: '$width');
              final start = data.indexOf(breakablePath(longPath));
              expect(start, greaterThanOrEqualTo(0), reason: '$width');
              final end = start + breakablePath(longPath).length;
              for (final lineStart in lineStarts(paragraph)) {
                if (lineStart <= start || lineStart >= end) continue;
                breaksInPath++;
                expect(
                  data.substring(lineStart - 2, lineStart),
                  '\\$zeroWidthSpace',
                  reason: '$width: ${data.substring(start, lineStart)}',
                );
                expect(lineStart, isNot(start + 2), reason: '$width');
              }
            }
            expect(breaksInPath, greaterThan(0));
          });
        }
      }
    }
  });
}
