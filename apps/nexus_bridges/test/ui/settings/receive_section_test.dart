import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:nexus_bridges/src/l10n/app_strings.dart';
import 'package:nexus_bridges/src/ui/format.dart';
import 'package:nexus_bridges_core/nexus_bridges_core.dart';

import '../fake_app_controller.dart';
import '../segoe_font.dart';
import '../transfer_fixtures.dart' show incomingView;
import 'settings_fixtures.dart';

const String _cloud = r'C:\Users\David\OneDrive\Recibidos';
const String _usb = r'E:\Pendrive';

Finder _change(AppStrings s) =>
    sectionButton(s.sectionReceive, s.changeFolderButton);

FolderChangeNeedsConfirmation _needs({
  String id = 'c1',
  String path = _cloud,
  bool noMark = false,
  bool remote = true,
}) => FolderChangeNeedsConfirmation(
  changeId: id,
  path: path,
  noMark: noMark,
  remote: remote,
);

Future<void> _tapChange(WidgetTester tester, AppStrings s) async {
  await tester.tap(_change(s));
  await tester.pumpAndSettle();
}

void main() {
  setUpAll(loadSegoe);

  for (final code in languageCodes) {
    final strings = stringsFor(code);

    group('[$code] E870 the receive folder (RF-512 to RF-516)', () {
      testWidgets('the row shows the last part and the full path, and the '
          'information opens', (tester) async {
        await pumpSettings(tester, code);
        expect(
          inSection(strings.sectionReceive, find.text('Recibidos')),
          findsOneWidget,
        );
        expect(
          inSection(strings.sectionReceive, find.text(receivePath)),
          findsOneWidget,
        );
        expect(
          inSection(strings.sectionReceive, find.text(strings.receiveDesc)),
          findsOneWidget,
        );
        await tooltipCases(tester, strings.sectionReceive, strings.receiveInfo);
      });

      testWidgets('"Change..." calls changeReceiveFolder; a chosen folder or '
          'a closed picker leave no message', (tester) async {
        final (controller, _) = await pumpSettings(tester, code);
        controller.changeFolderResult = () async =>
            const FolderChanged(r'D:\Nueva');
        await _tapChange(tester, strings);
        controller.changeFolderResult = () async => const FolderUnchanged();
        await _tapChange(tester, strings);
        expect(controller.calls, [
          'changeReceiveFolder',
          'changeReceiveFolder',
        ]);
        expect(find.text(strings.checkingFolder), findsNothing);
        expect(find.text(strings.changeFolderLocked), findsNothing);
        expect(confirmOpen(tester, strings.sectionReceive), isFalse);
      });

      for (final problem in FolderProblem.values) {
        testWidgets('refused with ${problem.name}: the text of the folder '
            'question that matches', (tester) async {
          final (controller, _) = await pumpSettings(tester, code);
          const path = r'C:\Windows';
          controller.changeFolderResult = () async =>
              FolderChangeRefused(problem, path);
          await _tapChange(tester, strings);
          final shown = breakablePath(path);
          final expected = switch (problem) {
            FolderProblem.forbidden => strings.folderForbidden(shown),
            FolderProblem.adminShare => strings.folderAdminShare(shown),
            FolderProblem.unknownVolume => strings.folderUnknownVolume(shown),
            FolderProblem.cannotUse ||
            FolderProblem.rememberedUnavailable ||
            FolderProblem.stillUnavailable => strings.folderCannotUse(shown),
          };
          expect(
            inSection(strings.sectionReceive, find.text(expected)),
            findsOneWidget,
          );
          expect(
            inSection(strings.sectionReceive, find.text('Recibidos')),
            findsOneWidget,
          );
          expect(controller.calls, ['changeReceiveFolder']);
        });
      }

      for (final (label, noMark, remote) in [
        ('without the mark', true, false),
        ('in the cloud or remote', false, true),
        ('both', true, true),
      ]) {
        testWidgets('needs confirmation $label: the matching cautions and '
            '"Use anyway" calls confirmReceiveFolder', (tester) async {
          final (controller, _) = await pumpSettings(tester, code);
          controller.changeFolderResult = () async =>
              _needs(path: _usb, noMark: noMark, remote: remote);
          await _tapChange(tester, strings);

          expect(confirmOpen(tester, strings.sectionReceive), isTrue);
          final shown = breakablePath(_usb);
          expect(
            find.text(strings.cautionNoMark(shown)),
            noMark ? findsOneWidget : findsNothing,
          );
          expect(
            find.text(strings.cautionRemote(shown)),
            remote ? findsOneWidget : findsNothing,
          );

          await tester.tap(
            confirmButton(strings.sectionReceive, strings.useAnywayButton),
          );
          await tester.pumpAndSettle();
          expect(controller.calls, [
            'changeReceiveFolder',
            'confirmReceiveFolder c1',
          ]);
          expect(confirmOpen(tester, strings.sectionReceive), isFalse);
        });
      }

      testWidgets('"Choose another" cancels the pending change and opens the '
          'picker again', (tester) async {
        final (controller, _) = await pumpSettings(tester, code);
        var round = 0;
        controller.changeFolderResult = () async {
          round++;
          return round == 1 ? _needs() : const FolderChanged(r'D:\Otra');
        };
        await _tapChange(tester, strings);
        await tester.tap(
          confirmButton(
            strings.sectionReceive,
            strings.chooseOtherFolderButton,
          ),
        );
        await tester.pumpAndSettle();
        expect(controller.calls, [
          'changeReceiveFolder',
          'cancelReceiveFolderChange c1',
          'changeReceiveFolder',
        ]);
        expect(confirmOpen(tester, strings.sectionReceive), isFalse);
      });

      testWidgets('"Change..." again with a confirmation open cancels the old '
          'one first', (tester) async {
        final (controller, _) = await pumpSettings(tester, code);
        controller.changeFolderResult = () async => _needs();
        await _tapChange(tester, strings);
        controller.changeFolderResult = () async => _needs(id: 'c2');
        await _tapChange(tester, strings);
        expect(controller.calls, [
          'changeReceiveFolder',
          'cancelReceiveFolderChange c1',
          'changeReceiveFolder',
        ]);
        expect(confirmOpen(tester, strings.sectionReceive), isTrue);
      });

      testWidgets('while it checks: "checking" and the button off; with the '
          'picker open, the picker note', (tester) async {
        final (controller, _) = await pumpSettings(tester, code);
        final answer = Completer<FolderChangeResult>();
        controller.changeFolderResult = () => answer.future;
        await tester.tap(_change(strings));
        await tester.pump();
        expect(buttonEnabled(tester, _change(strings)), isFalse);
        expect(find.text(strings.checkingFolder), findsOneWidget);

        controller.emit(settingsState(pickerOpen: true));
        await tester.pump();
        expect(find.text(strings.pickerOpenNote), findsOneWidget);

        controller.emit(settingsState());
        answer.complete(const FolderUnchanged());
        await tester.pumpAndSettle();
        expect(buttonEnabled(tester, _change(strings)), isTrue);
        expect(find.text(strings.checkingFolder), findsNothing);
      });

      testWidgets('with the folder question open the button is off and says '
          'why (RF-516)', (tester) async {
        await pumpSettings(tester, code, state: settingsState(locked: true));
        expect(buttonEnabled(tester, _change(strings)), isFalse);
        expect(
          inSection(
            strings.sectionReceive,
            find.text(strings.changeFolderLocked),
          ),
          findsOneWidget,
        );
      });

      testWidgets('a blocked answer (the question opened meanwhile) explains '
          'it, also after confirming', (tester) async {
        final (controller, _) = await pumpSettings(tester, code);
        controller.changeFolderResult = () async => const FolderChangeBlocked();
        await _tapChange(tester, strings);
        expect(find.text(strings.changeFolderLocked), findsOneWidget);

        controller.changeFolderResult = () async => _needs();
        controller.confirmFolderResult = (_) async =>
            const FolderChangeBlocked();
        await _tapChange(tester, strings);
        expect(find.text(strings.changeFolderLocked), findsNothing);
        await tester.tap(
          confirmButton(strings.sectionReceive, strings.useAnywayButton),
        );
        await tester.pumpAndSettle();
        expect(find.text(strings.changeFolderLocked), findsOneWidget);
      });

      testWidgets('Esc with the folder confirmation open cancels it and keeps '
          'Settings open', (tester) async {
        final (controller, settings) = await pumpSettings(tester, code);
        controller.changeFolderResult = () async => _needs();
        await _tapChange(tester, strings);

        await pressEscape(tester);
        expect(settings.isOpen, isTrue);
        expect(confirmOpen(tester, strings.sectionReceive), isFalse);
        expect(controller.calls, [
          'changeReceiveFolder',
          'cancelReceiveFolderChange c1',
        ]);

        await pressEscape(tester);
        expect(settings.isOpen, isFalse);
        expect(controller.calls.length, 2);
      });

      testWidgets('closing Settings with the arrow and a confirmation open '
          'cancels it', (tester) async {
        final (controller, settings) = await pumpSettings(tester, code);
        controller.changeFolderResult = () async => _needs();
        await _tapChange(tester, strings);
        await tester.tap(find.byTooltip(strings.settingsBack));
        await tester.pumpAndSettle();
        expect(settings.isOpen, isFalse);
        expect(controller.calls, [
          'changeReceiveFolder',
          'cancelReceiveFolderChange c1',
        ]);
      });
    });

    group('[$code] E876 the picker answers after Settings closed (DA-13)', () {
      testWidgets('a confirmation that arrives with Settings closed is '
          'cancelled and nothing is left open', (tester) async {
        final (controller, settings) = await pumpSettings(tester, code);
        final answer = Completer<FolderChangeResult>();
        controller.changeFolderResult = () => answer.future;
        await tester.tap(_change(strings));
        await tester.pump();

        await pressEscape(tester);
        expect(settings.isOpen, isFalse);
        answer.complete(_needs(id: 'late'));
        await tester.pumpAndSettle();
        expect(controller.calls, [
          'changeReceiveFolder',
          'cancelReceiveFolderChange late',
        ]);

        await openSettings(tester, strings);
        expect(confirmOpen(tester, strings.sectionReceive), isFalse);
        expect(buttonEnabled(tester, _change(strings)), isTrue);
      });
    });

    group('[$code] E877 something that needs an answer with the folder '
        'confirmation open (RF-505)', () {
      testWidgets('Settings closes and the pending change is cancelled', (
        tester,
      ) async {
        final (controller, settings) = await pumpSettings(tester, code);
        controller.changeFolderResult = () async => _needs();
        await _tapChange(tester, strings);

        controller.emit(settingsState(incoming: incomingView()));
        await tester.pumpAndSettle();
        expect(settings.isOpen, isFalse);
        expect(controller.calls, [
          'changeReceiveFolder',
          'cancelReceiveFolderChange c1',
        ]);
      });
    });
  }
}
