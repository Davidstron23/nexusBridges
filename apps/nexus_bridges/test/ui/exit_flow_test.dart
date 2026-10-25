import 'dart:async';
import 'dart:ui' show AppExitResponse;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nexus_bridges/main.dart';
import 'package:nexus_bridges/src/l10n/app_strings.dart';
import 'package:nexus_bridges/src/ui/exit_flow.dart';
import 'package:nexus_bridges_core/nexus_bridges_core.dart';

import 'fake_app_controller.dart';

class _ListenerCountingController extends FakeAppController {
  _ListenerCountingController({super.state});

  int listeners = 0;

  @override
  void addListener(VoidCallback listener) {
    listeners++;
    super.addListener(listener);
  }

  @override
  void removeListener(VoidCallback listener) {
    listeners--;
    super.removeListener(listener);
  }
}

class _Pending<T> {
  _Pending(Future<T> future) {
    done = future.then((value) {
      result = value;
      finished = true;
    });
  }

  T? result;
  bool finished = false;
  late final Future<void> done;
}

const NodeState _idle = NodeState();
const NodeState _sending = NodeState(transferInProgress: true);
const NodeState _picking = NodeState(pickerOpen: true);
const NodeState _pickingWhileSending = NodeState(
  pickerOpen: true,
  transferInProgress: true,
);

Future<GlobalKey<NavigatorState>> _pumpHost(
  WidgetTester tester, {
  String languageCode = 'en',
}) async {
  final navigatorKey = GlobalKey<NavigatorState>();
  await tester.pumpWidget(
    MaterialApp(
      navigatorKey: navigatorKey,
      locale: Locale(languageCode),
      supportedLocales: const [Locale('en'), Locale('es')],
      localizationsDelegates: const [
        AppStringsDelegate(),
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      home: const Scaffold(),
    ),
  );
  await tester.pumpAndSettle();
  return navigatorKey;
}

_Pending<AppExitResponse> _exit(
  FakeAppController controller,
  GlobalKey<NavigatorState> navigatorKey, {
  Duration? budget,
}) {
  final future = budget == null
      ? handleExitRequest(
          controller,
          context: () => navigatorKey.currentContext,
        )
      : handleExitRequest(
          controller,
          context: () => navigatorKey.currentContext,
          shutdownBudget: budget,
        );
  return _Pending(future);
}

int _shutdowns(FakeAppController controller) =>
    controller.calls.where((call) => call == 'shutdown').length;

Future<void> _tapAndSettle(WidgetTester tester, String text) async {
  await tester.tap(find.text(text));
  await tester.pumpAndSettle();
}

void main() {
  group('E144: confirmCloseDuringTransfer (RF-185)', () {
    for (final code in languageCodes) {
      final strings = stringsFor(code);

      testWidgets('in $code it shows the title, the body and both buttons', (
        tester,
      ) async {
        final key = await _pumpHost(tester, languageCode: code);

        final answer = _Pending(
          confirmCloseDuringTransfer(key.currentContext!),
        );
        await tester.pumpAndSettle();

        expect(find.byType(AlertDialog), findsOneWidget);
        expect(find.text(strings.closeDuringTransferTitle), findsOneWidget);
        expect(find.text(strings.closeDuringTransferBody), findsOneWidget);
        expect(find.text(strings.keepOpenButton), findsOneWidget);
        expect(find.text(strings.closeAndCancelButton), findsOneWidget);
        expect(answer.finished, isFalse);

        await _tapAndSettle(tester, strings.keepOpenButton);
        expect(answer.finished, isTrue);
        await answer.done;
      });

      testWidgets('in $code "${strings.keepOpenButton}" answers false', (
        tester,
      ) async {
        final key = await _pumpHost(tester, languageCode: code);

        final answer = _Pending(
          confirmCloseDuringTransfer(key.currentContext!),
        );
        await tester.pumpAndSettle();
        await _tapAndSettle(tester, strings.keepOpenButton);

        expect(answer.finished, isTrue);
        expect(answer.result, isFalse);
        expect(find.byType(AlertDialog), findsNothing);
        await answer.done;
      });

      testWidgets('in $code "${strings.closeAndCancelButton}" answers true', (
        tester,
      ) async {
        final key = await _pumpHost(tester, languageCode: code);

        final answer = _Pending(
          confirmCloseDuringTransfer(key.currentContext!),
        );
        await tester.pumpAndSettle();
        await _tapAndSettle(tester, strings.closeAndCancelButton);

        expect(answer.finished, isTrue);
        expect(answer.result, isTrue);
        expect(find.byType(AlertDialog), findsNothing);
        await answer.done;
      });

      testWidgets('in $code tapping outside the dialog answers false', (
        tester,
      ) async {
        final key = await _pumpHost(tester, languageCode: code);

        final answer = _Pending(
          confirmCloseDuringTransfer(key.currentContext!),
        );
        await tester.pumpAndSettle();
        await tester.tapAt(const Offset(4, 4));
        await tester.pumpAndSettle();

        expect(find.byType(AlertDialog), findsNothing);
        expect(answer.finished, isTrue);
        expect(answer.result, isFalse);
        await answer.done;
      });
    }

    testWidgets('Escape closes the dialog and answers false', (tester) async {
      final key = await _pumpHost(tester);

      final answer = _Pending(confirmCloseDuringTransfer(key.currentContext!));
      await tester.pumpAndSettle();
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();

      expect(find.byType(AlertDialog), findsNothing);
      expect(answer.finished, isTrue);
      expect(answer.result, isFalse);
      await answer.done;
    });

    testWidgets('the buttons work right away, without the 0.5 s delay', (
      tester,
    ) async {
      final key = await _pumpHost(tester);
      final strings = stringsFor('en');

      final answer = _Pending(confirmCloseDuringTransfer(key.currentContext!));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));

      final keep = tester.widget<TextButton>(
        find.ancestor(
          of: find.text(strings.keepOpenButton),
          matching: find.byType(TextButton),
        ),
      );
      final close = tester.widget<FilledButton>(
        find.ancestor(
          of: find.text(strings.closeAndCancelButton),
          matching: find.byType(FilledButton),
        ),
      );
      expect(keep.onPressed, isNotNull);
      expect(close.onPressed, isNotNull);

      await tester.tap(find.text(strings.closeAndCancelButton));
      await tester.pumpAndSettle();
      expect(answer.result, isTrue);
      await answer.done;
    });
  });

  group('E251: handleExitRequest (RF-185, D-10)', () {
    testWidgets('with no send in progress it shuts down and exits silently', (
      tester,
    ) async {
      final key = await _pumpHost(tester);
      final controller = FakeAppController(state: _idle);

      final request = _exit(controller, key);
      await tester.pump();

      expect(request.result, AppExitResponse.exit);
      expect(controller.calls, ['shutdown']);
      expect(find.byType(AlertDialog), findsNothing);
      await request.done;
    });

    testWidgets('with no node state it shuts down and exits silently', (
      tester,
    ) async {
      final key = await _pumpHost(tester);
      final controller = FakeAppController();

      final request = _exit(controller, key);
      await tester.pump();

      expect(request.result, AppExitResponse.exit);
      expect(controller.calls, ['shutdown']);
      expect(find.byType(AlertDialog), findsNothing);
      await request.done;
    });

    for (final code in languageCodes) {
      final strings = stringsFor(code);

      testWidgets('in $code a send in progress asks before shutting down', (
        tester,
      ) async {
        final key = await _pumpHost(tester, languageCode: code);
        final controller = FakeAppController(state: _sending);

        final request = _exit(controller, key);
        await tester.pumpAndSettle();

        expect(find.text(strings.closeDuringTransferTitle), findsOneWidget);
        expect(request.finished, isFalse);
        expect(controller.calls, isEmpty);

        await _tapAndSettle(tester, strings.keepOpenButton);
        await request.done;
      });

      testWidgets('in $code "${strings.keepOpenButton}" answers cancel and '
          'does not shut down', (tester) async {
        final key = await _pumpHost(tester, languageCode: code);
        final controller = FakeAppController(state: _sending);

        final request = _exit(controller, key);
        await tester.pumpAndSettle();
        await _tapAndSettle(tester, strings.keepOpenButton);

        expect(request.result, AppExitResponse.cancel);
        expect(controller.calls, isNot(contains('shutdown')));
        expect(find.byType(AlertDialog), findsNothing);
        await request.done;
      });

      testWidgets('in $code "${strings.closeAndCancelButton}" shuts down and '
          'answers exit', (tester) async {
        final key = await _pumpHost(tester, languageCode: code);
        final controller = FakeAppController(state: _sending);

        final request = _exit(controller, key);
        await tester.pumpAndSettle();
        await _tapAndSettle(tester, strings.closeAndCancelButton);

        expect(request.result, AppExitResponse.exit);
        expect(controller.calls, ['shutdown']);
        expect(find.byType(AlertDialog), findsNothing);
        await request.done;
      });
    }

    testWidgets('closing the dialog by tapping outside counts as keep open', (
      tester,
    ) async {
      final key = await _pumpHost(tester);
      final controller = FakeAppController(state: _sending);

      final request = _exit(controller, key);
      await tester.pumpAndSettle();
      await tester.tapAt(const Offset(4, 4));
      await tester.pumpAndSettle();

      expect(request.result, AppExitResponse.cancel);
      expect(controller.calls, isEmpty);
      await request.done;
    });

    testWidgets('closing the dialog with Escape counts as keep open', (
      tester,
    ) async {
      final key = await _pumpHost(tester);
      final controller = FakeAppController(state: _sending);

      final request = _exit(controller, key);
      await tester.pumpAndSettle();
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();

      expect(request.result, AppExitResponse.cancel);
      expect(controller.calls, isEmpty);
      await request.done;
    });

    testWidgets('without a context it does not ask and exits', (tester) async {
      await _pumpHost(tester);
      final controller = FakeAppController(state: _sending);

      final request = _Pending(
        handleExitRequest(controller, context: () => null),
      );
      await tester.pump();

      expect(find.byType(AlertDialog), findsNothing);
      expect(request.result, AppExitResponse.exit);
      expect(controller.calls, ['shutdown']);
      await request.done;
    });

    testWidgets('with an unmounted context it does not ask and exits', (
      tester,
    ) async {
      final key = await _pumpHost(tester);
      final stale = key.currentContext!;
      await tester.pumpWidget(const SizedBox());
      expect(stale.mounted, isFalse);
      final controller = FakeAppController(state: _sending);

      final request = _Pending(
        handleExitRequest(controller, context: () => stale),
      );
      await tester.pump();

      expect(find.byType(AlertDialog), findsNothing);
      expect(request.result, AppExitResponse.exit);
      expect(controller.calls, ['shutdown']);
      await request.done;
    });

    testWidgets('while a picker is open it waits with no time limit', (
      tester,
    ) async {
      final key = await _pumpHost(tester);
      final controller = FakeAppController(state: _picking);

      final request = _exit(controller, key);
      await tester.pump();
      await tester.pump(const Duration(minutes: 10));

      expect(request.finished, isFalse);
      expect(controller.calls, isEmpty);
      expect(find.byType(AlertDialog), findsNothing);

      controller.emit(_idle);
      await tester.pump();

      expect(request.result, AppExitResponse.exit);
      expect(controller.calls, ['shutdown']);
      await request.done;
    });

    testWidgets('changes that keep the picker open keep it waiting', (
      tester,
    ) async {
      final key = await _pumpHost(tester);
      final controller = FakeAppController(state: _picking);

      final request = _exit(controller, key);
      await tester.pump();
      controller.emit(const NodeState(pickerOpen: true, scanning: true));
      await tester.pump();
      controller.emit(_pickingWhileSending);
      await tester.pump();

      expect(request.finished, isFalse);
      expect(controller.calls, isEmpty);
      expect(find.byType(AlertDialog), findsNothing);

      controller.emit(_idle);
      await tester.pump();
      expect(request.result, AppExitResponse.exit);
      await request.done;
    });

    testWidgets('a state that becomes null counts as the picker closed', (
      tester,
    ) async {
      final key = await _pumpHost(tester);
      final controller = FakeAppController(state: _picking);

      final request = _exit(controller, key);
      await tester.pump();
      expect(request.finished, isFalse);

      controller.emit(null);
      await tester.pump();

      expect(request.result, AppExitResponse.exit);
      expect(controller.calls, ['shutdown']);
      await request.done;
    });

    testWidgets('with a picker open and a send in progress, it asks only '
        'after the picker closes', (tester) async {
      final key = await _pumpHost(tester);
      final strings = stringsFor('en');
      final controller = FakeAppController(state: _pickingWhileSending);

      final request = _exit(controller, key);
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsNothing);
      expect(request.finished, isFalse);

      controller.emit(_sending);
      await tester.pumpAndSettle();
      expect(find.text(strings.closeDuringTransferTitle), findsOneWidget);
      expect(controller.calls, isEmpty);

      await _tapAndSettle(tester, strings.keepOpenButton);
      expect(request.result, AppExitResponse.cancel);
      expect(controller.calls, isEmpty);
      await request.done;
    });

    testWidgets('if the send ends while the picker is open, it does not ask', (
      tester,
    ) async {
      final key = await _pumpHost(tester);
      final controller = FakeAppController(state: _pickingWhileSending);

      final request = _exit(controller, key);
      await tester.pump();
      controller.emit(_idle);
      await tester.pumpAndSettle();

      expect(find.byType(AlertDialog), findsNothing);
      expect(request.result, AppExitResponse.exit);
      expect(controller.calls, ['shutdown']);
      await request.done;
    });

    testWidgets('the picker listener is removed once the picker closes', (
      tester,
    ) async {
      final key = await _pumpHost(tester);
      final controller = _ListenerCountingController(state: _picking);

      final request = _exit(controller, key);
      await tester.pump();
      expect(controller.listeners, 1);

      controller.emit(_idle);
      await tester.pump();
      expect(request.result, AppExitResponse.exit);
      expect(controller.listeners, 0);
      await request.done;
    });

    testWidgets('with no picker open it adds no listener', (tester) async {
      final key = await _pumpHost(tester);
      final controller = _ListenerCountingController(state: _idle);

      final request = _exit(controller, key);
      await tester.pump();

      expect(request.result, AppExitResponse.exit);
      expect(controller.listeners, 0);
      await request.done;
    });

    testWidgets('a shutdown that never ends is given up on at 5 s', (
      tester,
    ) async {
      final key = await _pumpHost(tester);
      final controller = FakeAppController(state: _idle)
        ..shutdownResult = () => Completer<void>().future;

      final request = _exit(controller, key);
      await tester.pump();
      expect(controller.calls, ['shutdown']);

      await tester.pump(const Duration(milliseconds: 4990));
      expect(request.finished, isFalse);

      await tester.pump(const Duration(milliseconds: 20));
      expect(request.result, AppExitResponse.exit);
      await request.done;
    });

    testWidgets('a shorter shutdownBudget is honoured', (tester) async {
      final key = await _pumpHost(tester);
      final controller = FakeAppController(state: _idle)
        ..shutdownResult = () => Completer<void>().future;

      final request = _exit(
        controller,
        key,
        budget: const Duration(milliseconds: 200),
      );
      await tester.pump(const Duration(milliseconds: 190));
      expect(request.finished, isFalse);

      await tester.pump(const Duration(milliseconds: 20));
      expect(request.result, AppExitResponse.exit);
      await request.done;
    });

    testWidgets('a shutdown that ends before 5 s is answered at once', (
      tester,
    ) async {
      final key = await _pumpHost(tester);
      final controller = FakeAppController(state: _idle)
        ..shutdownResult = () =>
            Future<void>.delayed(const Duration(milliseconds: 300));

      final request = _exit(controller, key);
      await tester.pump(const Duration(milliseconds: 290));
      expect(request.finished, isFalse);

      await tester.pump(const Duration(milliseconds: 20));
      expect(request.result, AppExitResponse.exit);
      await request.done;
    });

    testWidgets('the 5 s start after confirming, not when the close began', (
      tester,
    ) async {
      final key = await _pumpHost(tester);
      final strings = stringsFor('en');
      final controller = FakeAppController(state: _sending)
        ..shutdownResult = () => Completer<void>().future;

      final request = _exit(controller, key);
      await tester.pumpAndSettle();
      await tester.pump(const Duration(seconds: 30));
      expect(request.finished, isFalse);

      await tester.tap(find.text(strings.closeAndCancelButton));
      await tester.pump();
      expect(controller.calls, ['shutdown']);

      await tester.pump(const Duration(milliseconds: 4900));
      expect(request.finished, isFalse);

      await tester.pump(const Duration(milliseconds: 200));
      expect(request.result, AppExitResponse.exit);
      await tester.pumpAndSettle();
      await request.done;
    });

    testWidgets('the time waiting for the picker does not eat the budget', (
      tester,
    ) async {
      final key = await _pumpHost(tester);
      final controller = FakeAppController(state: _picking)
        ..shutdownResult = () => Completer<void>().future;

      final request = _exit(controller, key);
      await tester.pump(const Duration(seconds: 10));
      controller.emit(_idle);
      await tester.pump();
      expect(controller.calls, ['shutdown']);

      await tester.pump(const Duration(milliseconds: 4990));
      expect(request.finished, isFalse);

      await tester.pump(const Duration(milliseconds: 20));
      expect(request.result, AppExitResponse.exit);
      await request.done;
    });

    testWidgets('a shutdown that throws synchronously still exits', (
      tester,
    ) async {
      final key = await _pumpHost(tester);
      final controller = FakeAppController(state: _idle)
        ..shutdownResult = () => throw StateError('shutdown failed');

      final request = _exit(controller, key);
      await tester.pump();

      expect(request.result, AppExitResponse.exit);
      expect(controller.calls, ['shutdown']);
      expect(tester.takeException(), isNull);
      await request.done;
    });

    testWidgets('a shutdown that fails later still exits', (tester) async {
      final key = await _pumpHost(tester);
      final controller = FakeAppController(state: _idle)
        ..shutdownResult = () async {
          await Future<void>.delayed(const Duration(milliseconds: 100));
          throw StateError('late failure');
        };

      final request = _exit(controller, key);
      await tester.pump(const Duration(milliseconds: 110));

      expect(request.result, AppExitResponse.exit);
      expect(tester.takeException(), isNull);
      await request.done;
    });
  });

  group('E251: one close at a time from the app (main.dart)', () {
    final strings = stringsFor('en');

    Future<void> pumpApp(WidgetTester tester, FakeAppController controller) {
      return tester
          .pumpWidget(NexusBridgesApp(controller))
          .then((_) => tester.pumpAndSettle());
    }

    testWidgets('two exit requests open a single dialog and share its answer', (
      tester,
    ) async {
      final controller = FakeAppController(state: _sending);
      await pumpApp(tester, controller);

      final first = _Pending(tester.binding.handleRequestAppExit());
      await tester.pump();
      final second = _Pending(tester.binding.handleRequestAppExit());
      await tester.pumpAndSettle();

      expect(find.byType(AlertDialog), findsOneWidget);
      expect(find.text(strings.closeDuringTransferTitle), findsOneWidget);

      await _tapAndSettle(tester, strings.closeAndCancelButton);

      expect(first.result, AppExitResponse.exit);
      expect(second.result, AppExitResponse.exit);
      expect(_shutdowns(controller), 1);
      expect(find.byType(AlertDialog), findsNothing);
      await first.done;
      await second.done;
    });

    testWidgets('two requests answered with keep open both cancel', (
      tester,
    ) async {
      final controller = FakeAppController(state: _sending);
      await pumpApp(tester, controller);

      final first = _Pending(tester.binding.handleRequestAppExit());
      final second = _Pending(tester.binding.handleRequestAppExit());
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsOneWidget);

      await _tapAndSettle(tester, strings.keepOpenButton);

      expect(first.result, AppExitResponse.cancel);
      expect(second.result, AppExitResponse.cancel);
      expect(_shutdowns(controller), 0);
      await first.done;
      await second.done;
    });

    testWidgets('after keeping it open, the next request asks again', (
      tester,
    ) async {
      final controller = FakeAppController(state: _sending);
      await pumpApp(tester, controller);

      final first = _Pending(tester.binding.handleRequestAppExit());
      await tester.pumpAndSettle();
      await _tapAndSettle(tester, strings.keepOpenButton);
      expect(first.result, AppExitResponse.cancel);
      await first.done;

      final second = _Pending(tester.binding.handleRequestAppExit());
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsOneWidget);

      await _tapAndSettle(tester, strings.closeAndCancelButton);
      expect(second.result, AppExitResponse.exit);
      expect(_shutdowns(controller), 1);
      await second.done;
    });

    testWidgets('with a picker open, the app waits and then asks', (
      tester,
    ) async {
      final controller = FakeAppController(state: _pickingWhileSending);
      await pumpApp(tester, controller);

      final request = _Pending(tester.binding.handleRequestAppExit());
      await tester.pumpAndSettle();
      await tester.pump(const Duration(minutes: 1));
      expect(find.byType(AlertDialog), findsNothing);
      expect(request.finished, isFalse);

      controller.emit(_sending);
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsOneWidget);

      await _tapAndSettle(tester, strings.closeAndCancelButton);
      expect(request.result, AppExitResponse.exit);
      expect(_shutdowns(controller), 1);
      await request.done;
    });

    testWidgets('a stuck shutdown answers the app at 5 s', (tester) async {
      final controller = FakeAppController(state: _idle)
        ..shutdownResult = () => Completer<void>().future;
      await pumpApp(tester, controller);

      final request = _Pending(tester.binding.handleRequestAppExit());
      await tester.pump(const Duration(milliseconds: 4990));
      expect(request.finished, isFalse);

      await tester.pump(const Duration(milliseconds: 20));
      expect(request.result, AppExitResponse.exit);
      expect(_shutdowns(controller), 1);
      await request.done;
    });
  });
}
