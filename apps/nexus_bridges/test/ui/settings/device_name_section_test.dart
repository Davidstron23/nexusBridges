import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nexus_bridges/src/l10n/app_strings.dart';
import 'package:nexus_bridges_core/nexus_bridges_core.dart';

import '../fake_app_controller.dart';
import '../pairing_fixtures.dart' show entry;
import '../segoe_font.dart';
import '../transfer_fixtures.dart' show incomingView;
import 'settings_fixtures.dart';

const String _rlo = '\u{202E}';
const String _heart = '\u{2764}\u{FE0F}';
const String _family = '\u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467}';

Finder _field(AppStrings s) => textField(s.sectionDevice);

Finder _save(AppStrings s) => sectionButton(s.sectionDevice, s.saveButton);

String _message(WidgetTester tester, AppStrings s, String text) =>
    tester.widget<Text>(inSection(s.sectionDevice, find.text(text))).data!;

void main() {
  setUpAll(loadSegoe);

  for (final code in languageCodes) {
    final strings = stringsFor(code);

    group('[$code] E860 the device name (RF-506 to RF-508)', () {
      testWidgets('the explanation is visible and the information opens with '
          'a click, the mouse over it and the keyboard', (tester) async {
        await pumpSettings(tester, code);
        expect(
          inSection(strings.sectionDevice, find.text(strings.deviceNameDesc)),
          findsOneWidget,
        );
        await tooltipCases(
          tester,
          strings.sectionDevice,
          strings.deviceNameInfo,
        );
      });

      testWidgets('the field shows the effective name and Save is off until '
          'the trimmed text changes', (tester) async {
        final (controller, _) = await pumpSettings(tester, code);
        expect(
          tester.widget<TextField>(_field(strings)).controller!.text,
          ownName,
        );
        expect(buttonEnabled(tester, _save(strings)), isFalse);

        await typeIn(tester, _field(strings), '  $ownName  ');
        expect(buttonEnabled(tester, _save(strings)), isFalse);
        await submit(tester);
        expect(controller.calls, isEmpty);

        await typeIn(tester, _field(strings), 'PC David');
        expect(buttonEnabled(tester, _save(strings)), isTrue);
      });

      testWidgets('65 characters: tooLong, Save off and Enter does not call '
          'the node', (tester) async {
        final (controller, _) = await pumpSettings(tester, code);
        await typeIn(tester, _field(strings), 'a' * 65);
        expect(
          _message(tester, strings, strings.nameTooLong),
          strings.nameTooLong,
        );
        expect(buttonEnabled(tester, _save(strings)), isFalse);
        await submit(tester);
        expect(controller.calls, isEmpty);

        await typeIn(tester, _field(strings), 'a' * 64);
        expect(find.text(strings.nameTooLong), findsNothing);
        expect(buttonEnabled(tester, _save(strings)), isTrue);
      });

      testWidgets('only spaces: empty, and Enter does not call the node', (
        tester,
      ) async {
        final (controller, _) = await pumpSettings(tester, code);
        await typeIn(tester, _field(strings), '     ');
        expect(find.text(strings.nameEmpty), findsOneWidget);
        await submit(tester);
        expect(controller.calls, isEmpty);
      });

      for (final (label, pasted) in [
        ('U+202E', 'PC${_rlo}divaD'),
        ('a heart emoji with its variation selector', 'PC $_heart'),
        ('a family emoji joined with ZWJ', 'PC $_family'),
      ]) {
        testWidgets('a pasted name with $label: invalid, with the D-c text, '
            'and no call', (tester) async {
          final (controller, _) = await pumpSettings(tester, code);
          await typeIn(tester, _field(strings), pasted);
          expect(find.text(strings.nameInvalid), findsOneWidget);
          expect(buttonEnabled(tester, _save(strings)), isFalse);
          await submit(tester);
          await tester.tap(_save(strings), warnIfMissed: false);
          await tester.pumpAndSettle();
          expect(controller.calls, isEmpty);
        });
      }

      testWidgets('a heart without the variation selector is a valid name', (
        tester,
      ) async {
        final (controller, _) = await pumpSettings(tester, code);
        await typeIn(tester, _field(strings), 'PC \u{2764}');
        expect(find.text(strings.nameInvalid), findsNothing);
        await submit(tester);
        expect(controller.calls, ['setDeviceName PC \u{2764}']);
      });

      testWidgets('"PC David" with Enter and then with Save calls '
          'setDeviceName with the trimmed text', (tester) async {
        final (controller, _) = await pumpSettings(tester, code);
        await typeIn(tester, _field(strings), '  PC David ');
        await submit(tester);
        expect(controller.calls, ['setDeviceName PC David']);
        expect(
          tester.widget<TextField>(_field(strings)).controller!.text,
          'PC David',
        );

        await typeIn(tester, _field(strings), 'Torre de David');
        await tester.tap(_save(strings));
        await tester.pumpAndSettle();
        expect(controller.calls, [
          'setDeviceName PC David',
          'setDeviceName Torre de David',
        ]);
      });

      testWidgets('after saving, the state brings the new name: the subtitle '
          'changes and Save turns off', (tester) async {
        final (controller, _) = await pumpSettings(tester, code);
        await typeIn(tester, _field(strings), 'PC David');
        await submit(tester);
        controller.emit(
          settingsState(deviceName: 'PC David', customName: 'PC David'),
        );
        await tester.pumpAndSettle();
        expect(find.text(strings.settingsSubtitle('PC David')), findsOneWidget);
        expect(buttonEnabled(tester, _save(strings)), isFalse);
        expect(
          tester.widget<TextField>(_field(strings)).controller!.text,
          'PC David',
        );
      });

      testWidgets('a problem in the node answer shows its message and keeps '
          'the text', (tester) async {
        final (controller, _) = await pumpSettings(tester, code);
        controller.deviceNameResult = (_) async => const DeviceNameResult(
          problem: DeviceNameProblem.invalidCharacters,
          saved: false,
        );
        await typeIn(tester, _field(strings), 'PC David');
        await submit(tester);
        expect(find.text(strings.nameInvalid), findsOneWidget);
        expect(
          tester.widget<TextField>(_field(strings)).controller!.text,
          'PC David',
        );
        await typeIn(tester, _field(strings), 'PC Davi');
        expect(find.text(strings.nameInvalid), findsNothing);
      });

      testWidgets('while the node answers, Save and Enter do not call it '
          'twice', (tester) async {
        final (controller, _) = await pumpSettings(tester, code);
        final answer = Completer<DeviceNameResult>();
        controller.deviceNameResult = (_) => answer.future;
        await typeIn(tester, _field(strings), 'PC David');
        await tester.testTextInput.receiveAction(TextInputAction.done);
        await tester.pump();
        expect(buttonEnabled(tester, _save(strings)), isFalse);
        await tester.testTextInput.receiveAction(TextInputAction.done);
        await tester.pump();
        answer.complete(const DeviceNameResult());
        await tester.pumpAndSettle();
        expect(controller.calls, ['setDeviceName PC David']);
      });

      testWidgets('the field takes 256 characters at most (DA-28)', (
        tester,
      ) async {
        await pumpSettings(tester, code);
        await tester.showKeyboard(_field(strings));
        tester.testTextInput.updateEditingValue(
          TextEditingValue(
            text: 'b' * 300,
            selection: const TextSelection.collapsed(offset: 300),
          ),
        );
        await tester.pump();
        expect(
          tester.widget<TextField>(_field(strings)).controller!.text.length,
          256,
        );
        expect(find.text(strings.nameTooLong), findsOneWidget);
      });

      testWidgets('"Use the Windows name · X" calls setDeviceName(null) and '
          'puts the Windows name in the field', (tester) async {
        final (controller, _) = await pumpSettings(tester, code);
        final link = find.text(strings.useWindowsName(windowsName));
        expect(link, findsOneWidget);
        await typeIn(tester, _field(strings), 'algo a medias');
        await tester.tap(link);
        await tester.pumpAndSettle();
        expect(controller.calls, ['setDeviceName null']);
        expect(
          tester.widget<TextField>(_field(strings)).controller!.text,
          windowsName,
        );
      });

      testWidgets('without a name of its own the link is not shown', (
        tester,
      ) async {
        await pumpSettings(
          tester,
          code,
          state: settingsState(deviceName: windowsName, customName: null),
        );
        expect(find.text(strings.useWindowsName(windowsName)), findsNothing);
      });
    });

    group('[$code] E861 a name that another device has (RF-509)', () {
      testWidgets('typing it shows the neutral namesake notice, Save stays on '
          'and saving calls the node', (tester) async {
        final (controller, _) = await pumpSettings(
          tester,
          code,
          state: settingsState(
            entries: [entry(fingerprint: 'F' * 64, name: 'Torre')],
          ),
        );
        controller.namesakes['Torre'] = 'F' * 64;

        await typeIn(tester, _field(strings), 'Torre');
        expect(find.text(strings.nameNamesake), findsOneWidget);
        expect(buttonEnabled(tester, _save(strings)), isTrue);
        await tester.tap(_save(strings));
        await tester.pumpAndSettle();
        expect(controller.calls, ['setDeviceName Torre']);

        await typeIn(tester, _field(strings), 'Torre 2');
        expect(find.text(strings.nameNamesake), findsNothing);
      });
    });

    group('[$code] E866 something that needs an answer with a name half '
        'typed and Restore open (RF-505)', () {
      testWidgets('Settings closes, nothing is saved or restored and the '
          'draft is gone when it opens again', (tester) async {
        final (controller, settings) = await pumpSettings(
          tester,
          code,
          state: settingsState(exclusions: const ['dist']),
        );
        await typeIn(tester, _field(strings), 'medio nom');
        await tester.tap(
          inSection(
            strings.sectionExclusions,
            find.text(strings.restoreDefaults),
          ),
        );
        await tester.pumpAndSettle();
        expect(confirmOpen(tester, strings.sectionExclusions), isTrue);

        controller.emit(
          settingsState(exclusions: const ['dist'], incoming: incomingView()),
        );
        await tester.pumpAndSettle();
        expect(settings.isOpen, isFalse);
        expect(controller.calls, isEmpty);

        await openSettings(tester, strings);
        expect(
          tester.widget<TextField>(_field(strings)).controller!.text,
          ownName,
        );
        expect(confirmOpen(tester, strings.sectionExclusions), isFalse);
        expect(controller.calls, isEmpty);
      });
    });
  }
}
