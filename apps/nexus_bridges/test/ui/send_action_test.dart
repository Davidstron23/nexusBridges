import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nexus_bridges/src/app_controller.dart';
import 'package:nexus_bridges/src/l10n/app_strings.dart';
import 'package:nexus_bridges/src/ui/diagram/flow_diagram.dart';
import 'package:nexus_bridges/src/ui/send_action.dart';
import 'package:nexus_bridges_core/nexus_bridges_core.dart';

import 'fake_app_controller.dart';
import 'pairing_fixtures.dart';

final String _fp = fingerprintOf('AAAA1111');
final String _otherFp = fingerprintOf('BBBB2222');
const String _name = 'PC principal';

const Duration _popoverIn = Duration(milliseconds: 240);

class _PendingController extends FakeAppController {
  _PendingController() : super(state: const NodeState());

  final Completer<SendResult> pending = Completer<SendResult>();

  @override
  Future<SendResult> sendFile(String fingerprint) {
    calls.add('sendFile $fingerprint');
    return pending.future;
  }
}

String? _messageFor(AppStrings strings, SendResult result) => switch (result) {
  SendResult.otherTargetBusy => strings.alreadySending,
  SendResult.unavailable || SendResult.tooMany => strings.sendUnavailable,
  SendResult.started || SendResult.queued || SendResult.nothingChosen => null,
};

Future<FakeAppController> _pumpTwoPaired(
  WidgetTester tester,
  String code,
  SendResult result,
) async {
  tester.view.physicalSize = const Size(800, 600);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final controller = FakeAppController(
    state: NodeState(
      entries: [
        entry(fingerprint: _fp, name: _name, paired: true, mine: true),
        entry(fingerprint: _otherFp, name: 'Torre', paired: true),
      ],
    ),
  )..sendFileResult = result;
  await pumpHome(tester, controller, code);
  return controller;
}

Finder _rowSend(AppStrings strings) => find.descendant(
  of: find.byKey(ValueKey(_fp)),
  matching: find.text(strings.sendFileButton),
);

Finder _popoverSend(AppStrings strings) => find.descendant(
  of: find.byType(FlowDiagram),
  matching: find.text(strings.sendFileButton),
);

void _expectSnackBar(AppStrings strings, String? message) {
  if (message == null) {
    expect(find.byType(SnackBar), findsNothing);
  } else {
    expect(find.byType(SnackBar), findsOneWidget);
    expect(
      find.descendant(of: find.byType(SnackBar), matching: find.text(message)),
      findsOneWidget,
    );
  }
  for (final other in [strings.alreadySending, strings.sendUnavailable]) {
    if (other != message) expect(find.text(other), findsNothing);
  }
}

Widget _bareApp({
  required String code,
  required ValueNotifier<bool> showButton,
  required AppController controller,
}) {
  return MaterialApp(
    locale: Locale(code),
    supportedLocales: const [Locale('en'), Locale('es')],
    localizationsDelegates: const [
      AppStringsDelegate(),
      GlobalMaterialLocalizations.delegate,
      GlobalWidgetsLocalizations.delegate,
      GlobalCupertinoLocalizations.delegate,
    ],
    home: Scaffold(
      body: ValueListenableBuilder<bool>(
        valueListenable: showButton,
        builder: (context, show, _) => show
            ? Builder(
                builder: (context) => TextButton(
                  onPressed: () => startSend(context, controller, _fp),
                  child: const SizedBox(width: 40, height: 40),
                ),
              )
            : const SizedBox(),
      ),
    ),
  );
}

void main() {
  for (final code in languageCodes) {
    final strings = stringsFor(code);

    group('[$code] E137 Send file from a row (RF-132, RF-133, RF-141)', () {
      for (final result in SendResult.values) {
        final message = _messageFor(strings, result);
        testWidgets('${result.name} calls sendFile for that device and '
            '${message == null ? 'shows no SnackBar' : 'shows its SnackBar'}', (
          tester,
        ) async {
          final controller = await _pumpTwoPaired(tester, code, result);

          await tester.tap(_rowSend(strings));
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 750));

          expect(controller.calls, ['sendFile $_fp']);
          _expectSnackBar(strings, message);
        });
      }
    });

    group('[$code] E137 and E268 Send file from the diagram popover', () {
      for (final result in SendResult.values) {
        final message = _messageFor(strings, result);
        testWidgets(
          '${result.name} closes the popover, calls sendFile and '
          '${message == null ? 'shows no SnackBar' : 'shows the same SnackBar as the row'}',
          (tester) async {
            final controller = await _pumpTwoPaired(tester, code, result);

            await tester.tap(find.byKey(ValueKey('flow-peer-$_fp')));
            await tester.pump();
            await tester.pump(_popoverIn);
            expect(_popoverSend(strings), findsOneWidget);

            await tester.tap(_popoverSend(strings));
            await tester.pump();
            await tester.pump(const Duration(milliseconds: 750));

            expect(controller.calls, ['sendFile $_fp']);
            expect(_popoverSend(strings), findsNothing);
            _expectSnackBar(strings, message);
          },
        );
      }
    });

    group('[$code] startSend', () {
      testWidgets('with the caller still there, alreadySending shows one '
          'SnackBar with its text', (tester) async {
        final controller = _PendingController();
        final show = ValueNotifier<bool>(true);
        addTearDown(show.dispose);
        await tester.pumpWidget(
          _bareApp(code: code, showButton: show, controller: controller),
        );

        await tester.tap(find.byType(TextButton));
        await tester.pump();
        expect(controller.calls, ['sendFile $_fp']);
        expect(find.byType(SnackBar), findsNothing);

        controller.pending.complete(SendResult.otherTargetBusy);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 750));
        _expectSnackBar(strings, strings.alreadySending);
      });

      for (final result in [
        SendResult.otherTargetBusy,
        SendResult.unavailable,
      ]) {
        testWidgets('${result.name} after the caller is gone shows nothing and '
            'does not throw', (tester) async {
          final controller = _PendingController();
          final show = ValueNotifier<bool>(true);
          addTearDown(show.dispose);
          await tester.pumpWidget(
            _bareApp(code: code, showButton: show, controller: controller),
          );

          await tester.tap(find.byType(TextButton));
          await tester.pump();
          show.value = false;
          await tester.pump();
          expect(find.byType(TextButton), findsNothing);

          controller.pending.complete(result);
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 750));

          expect(tester.takeException(), isNull);
          expect(controller.calls, ['sendFile $_fp']);
          expect(find.byType(SnackBar), findsNothing);
        });
      }
    });
  }
}
