import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nexus_bridges/src/l10n/app_strings.dart';
import 'package:nexus_bridges/src/ui/settings/settings_field.dart';
import 'package:nexus_bridges_core/nexus_bridges_core.dart';

import '../fake_app_controller.dart';
import '../pairing_fixtures.dart' show buttonLabelsIn;
import '../segoe_font.dart';
import 'settings_fixtures.dart';

Finder _field(AppStrings s) => textField(s.sectionExclusions);

Finder _add(AppStrings s) => sectionButton(s.sectionExclusions, s.addButton);

Finder _restoreLink(AppStrings s) => inSection(
  s.sectionExclusions,
  find.ancestor(
    of: find.text(s.restoreDefaults),
    matching: find.byWidgetPredicate((widget) => widget is ButtonStyleButton),
  ),
);

Finder _remove(String label) => find.byWidgetPredicate(
  (widget) => widget is RoundIconButton && widget.label == label,
);

Finder _noticeCard(String message) =>
    find.ancestor(of: find.text(message), matching: find.byType(Card)).first;

void main() {
  setUpAll(loadSegoe);

  for (final code in languageCodes) {
    final strings = stringsFor(code);

    group('[$code] E862 excluded folders (RF-517 to RF-520)', () {
      testWidgets('"3 of 64", the description, the chips and the information '
          'with the mouse and the keyboard', (tester) async {
        await pumpSettings(tester, code);
        expect(
          inSection(strings.sectionExclusions, find.text(strings.ofMax(3, 64))),
          findsOneWidget,
        );
        expect(
          inSection(
            strings.sectionExclusions,
            find.text(strings.exclusionsDesc),
          ),
          findsOneWidget,
        );
        for (final name in defaultNames) {
          expect(
            inSection(strings.sectionExclusions, find.text(name)),
            findsOneWidget,
          );
        }
        await tooltipCases(
          tester,
          strings.sectionExclusions,
          strings.exclusionsInfo,
        );
      });

      testWidgets('adding "dist" with Enter and with Add calls addExclusion '
          'and clears the field', (tester) async {
        final (controller, _) = await pumpSettings(tester, code);
        await typeIn(tester, _field(strings), 'dist');
        await submit(tester);
        expect(controller.calls, ['addExclusion dist']);
        expect(tester.widget<TextField>(_field(strings)).controller!.text, '');

        await typeIn(tester, _field(strings), 'out');
        await tester.tap(_add(strings));
        await tester.pumpAndSettle();
        expect(controller.calls, ['addExclusion dist', 'addExclusion out']);
      });

      for (final (problem, text) in [
        (ExclusionProblem.empty, strings.exclusionEmpty),
        (ExclusionProblem.invalid, strings.exclusionInvalid),
        (ExclusionProblem.duplicate, strings.exclusionDuplicate),
        (ExclusionProblem.full, strings.exclusionFull),
      ]) {
        testWidgets('${problem.name} from the node shows its message and keeps '
            'the text; typing again hides it', (tester) async {
          final (controller, _) = await pumpSettings(tester, code);
          controller.exclusionResult = (_) async =>
              ExclusionOutcome(problem: problem, saved: false);
          await typeIn(tester, _field(strings), 'a:b');
          await submit(tester);
          expect(find.text(text), findsOneWidget);
          expect(
            tester.widget<TextField>(_field(strings)).controller!.text,
            'a:b',
          );
          await typeIn(tester, _field(strings), 'ab');
          await tester.pumpAndSettle();
          expect(find.text(text), findsNothing);
        });
      }

      testWidgets('the x of a chip calls removeExclusion with its name, and '
          'the list shown follows the state', (tester) async {
        final (controller, _) = await pumpSettings(
          tester,
          code,
          state: settingsState(exclusions: const ['node_modules', 'dist']),
        );
        await tester.tap(_remove(strings.removeExclusion('dist')));
        await tester.pumpAndSettle();
        expect(controller.calls, ['removeExclusion dist']);

        controller.emit(settingsState(exclusions: const ['node_modules']));
        await tester.pumpAndSettle();
        expect(
          inSection(strings.sectionExclusions, find.text('dist')),
          findsNothing,
        );
        expect(
          inSection(strings.sectionExclusions, find.text(strings.ofMax(1, 64))),
          findsOneWidget,
        );

        controller.emit(
          settingsState(exclusions: const ['node_modules', 'out']),
        );
        await tester.pumpAndSettle();
        expect(
          inSection(strings.sectionExclusions, find.text('out')),
          findsOneWidget,
        );
      });

      testWidgets('Restore opens the inline confirmation; Cancel does '
          'nothing; Restore calls restoreExclusions', (tester) async {
        final (controller, _) = await pumpSettings(
          tester,
          code,
          state: settingsState(exclusions: const ['dist']),
        );
        expect(buttonEnabled(tester, _restoreLink(strings)), isTrue);
        await tester.tap(_restoreLink(strings));
        await tester.pumpAndSettle();
        expect(confirmOpen(tester, strings.sectionExclusions), isTrue);
        expect(
          find.textContaining('node_modules', findRichText: true),
          findsWidgets,
        );

        await tester.tap(
          confirmButton(strings.sectionExclusions, strings.cancelButton),
        );
        await tester.pumpAndSettle();
        expect(confirmOpen(tester, strings.sectionExclusions), isFalse);
        expect(controller.calls, isEmpty);

        await tester.tap(_restoreLink(strings));
        await tester.pumpAndSettle();
        await tester.tap(
          confirmButton(strings.sectionExclusions, strings.restoreButton),
        );
        await tester.pumpAndSettle();
        expect(controller.calls, ['restoreExclusions']);
        expect(confirmOpen(tester, strings.sectionExclusions), isFalse);
      });

      testWidgets('with the default list the Restore link is off', (
        tester,
      ) async {
        await pumpSettings(tester, code);
        expect(buttonEnabled(tester, _restoreLink(strings)), isFalse);
      });

      testWidgets('the default list in another case or order is still the '
          'default one', (tester) async {
        await pumpSettings(
          tester,
          code,
          state: settingsState(
            exclusions: const ['BUILD', '.dart_tool', 'Node_Modules'],
          ),
        );
        expect(
          buttonEnabled(tester, _restoreLink(strings)),
          !isDefaultExclusionList(const [
            'BUILD',
            '.dart_tool',
            'Node_Modules',
          ]),
        );
      });

      testWidgets('an empty list says "None: everything is sent." and "0 of '
          '64"', (tester) async {
        await pumpSettings(
          tester,
          code,
          state: settingsState(exclusions: const []),
        );
        expect(
          inSection(
            strings.sectionExclusions,
            find.text(strings.exclusionsEmpty),
          ),
          findsOneWidget,
        );
        expect(
          inSection(strings.sectionExclusions, find.text(strings.ofMax(0, 64))),
          findsOneWidget,
        );
        expect(buttonEnabled(tester, _restoreLink(strings)), isTrue);
      });

      testWidgets('with less motion a removed chip goes at once', (
        tester,
      ) async {
        final (controller, _) = await pumpSettings(
          tester,
          code,
          reduceMotion: true,
          state: settingsState(exclusions: const ['node_modules', 'dist']),
        );
        controller.emit(settingsState(exclusions: const ['node_modules']));
        await tester.pump();
        expect(
          inSection(strings.sectionExclusions, find.text('dist')),
          findsNothing,
        );
      });
    });

    group('[$code] E863 the setting that could not be saved (RF-503)', () {
      testWidgets('settingNotSaved shows its text, without Retry', (
        tester,
      ) async {
        await pumpSettings(
          tester,
          code,
          open: false,
          size: const Size(1200, 800),
          state: settingsState(
            notices: const [Notice(id: 7, kind: NoticeKind.settingNotSaved)],
          ),
        );
        expect(find.text(strings.noticeSettingNotSaved), findsOneWidget);
        expect(
          buttonLabelsIn(tester, _noticeCard(strings.noticeSettingNotSaved)),
          isNot(contains(strings.retryButton)),
        );
        expect(
          strings.noticeSettingNotSaved,
          isNot(strings.noticeChangeNotSaved),
        );
      });
    });
  }
}
