import 'dart:async';
import 'dart:ui' show AppExitResponse;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nexus_bridges/main.dart';
import 'package:nexus_bridges/src/l10n/app_strings.dart';
import 'package:nexus_bridges/src/ui/exit_flow.dart';
import 'package:nexus_bridges/src/ui/format.dart';
import 'package:nexus_bridges/src/ui/icons/device_disc.dart';
import 'package:nexus_bridges/src/ui/icons/file_icon.dart';
import 'package:nexus_bridges/src/ui/modal/modal_button.dart';
import 'package:nexus_bridges/src/ui/modal/modal_frame.dart';
import 'package:nexus_bridges/src/ui/modal/stage.dart';
import 'package:nexus_bridges/src/ui/modal/stage_kit.dart';
import 'package:nexus_bridges/src/ui/theme/tokens.dart';
import 'package:nexus_bridges/src/ui/unpair_modal.dart';
import 'package:nexus_bridges_core/nexus_bridges_core.dart';

import 'cover_fixtures.dart';
import 'fake_app_controller.dart';
import 'lifecycle_fixtures.dart';
import 'pairing_fixtures.dart' show entry;
import 'segoe_font.dart';
import 'transfer_fixtures.dart'
    show incomingView, outgoingView, senderFingerprint, senderName;

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
  bool reduceMotion = true,
  Size window = const Size(800, 600),
  double textScale = 1,
}) async {
  tester.view.physicalSize = window;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final navigatorKey = GlobalKey<NavigatorState>();
  await tester.pumpWidget(
    MaterialApp(
      navigatorKey: navigatorKey,
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context).copyWith(
          disableAnimations: reduceMotion,
          textScaler: TextScaler.linear(textScale),
        ),
        child: child!,
      ),
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
  if (reduceMotion) {
    await tester.pumpAndSettle();
  } else {
    await tester.pump();
  }
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
          confirmCloseDuringTransfer(
            key.currentContext!,
            FakeAppController(state: _sending),
          ),
        );
        await tester.pumpAndSettle();

        expect(find.byType(NbModal), findsOneWidget);
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
          confirmCloseDuringTransfer(
            key.currentContext!,
            FakeAppController(state: _sending),
          ),
        );
        await tester.pumpAndSettle();
        await _tapAndSettle(tester, strings.keepOpenButton);

        expect(answer.finished, isTrue);
        expect(answer.result, isFalse);
        expect(find.byType(NbModal), findsNothing);
        await answer.done;
      });

      testWidgets('in $code "${strings.closeAndCancelButton}" answers true', (
        tester,
      ) async {
        final key = await _pumpHost(tester, languageCode: code);

        final answer = _Pending(
          confirmCloseDuringTransfer(
            key.currentContext!,
            FakeAppController(state: _sending),
          ),
        );
        await tester.pumpAndSettle();
        await _tapAndSettle(tester, strings.closeAndCancelButton);

        expect(answer.finished, isTrue);
        expect(answer.result, isTrue);
        expect(find.byType(NbModal), findsNothing);
        await answer.done;
      });

      testWidgets('in $code tapping outside the dialog answers false', (
        tester,
      ) async {
        final key = await _pumpHost(tester, languageCode: code);

        final answer = _Pending(
          confirmCloseDuringTransfer(
            key.currentContext!,
            FakeAppController(state: _sending),
          ),
        );
        await tester.pumpAndSettle();
        await tester.tapAt(const Offset(4, 4));
        await tester.pumpAndSettle();

        expect(find.byType(NbModal), findsNothing);
        expect(answer.finished, isTrue);
        expect(answer.result, isFalse);
        await answer.done;
      });
    }

    testWidgets('Escape closes the dialog and answers false', (tester) async {
      final key = await _pumpHost(tester);

      final answer = _Pending(
        confirmCloseDuringTransfer(
          key.currentContext!,
          FakeAppController(state: _sending),
        ),
      );
      await tester.pumpAndSettle();
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();

      expect(find.byType(NbModal), findsNothing);
      expect(answer.finished, isTrue);
      expect(answer.result, isFalse);
      await answer.done;
    });

    testWidgets('the buttons work right away, without the 0.5 s delay', (
      tester,
    ) async {
      final key = await _pumpHost(tester);
      final strings = stringsFor('en');

      final answer = _Pending(
        confirmCloseDuringTransfer(
          key.currentContext!,
          FakeAppController(state: _sending),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));

      final keep = tester.widget<ModalButton>(
        find.widgetWithText(ModalButton, strings.keepOpenButton),
      );
      final close = tester.widget<ModalButton>(
        find.widgetWithText(ModalButton, strings.closeAndCancelButton),
      );
      expect(keep.kind, ModalButtonKind.primary);
      expect(close.kind, ModalButtonKind.negativeQuiet);
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
      expect(find.byType(NbModal), findsNothing);
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
      expect(find.byType(NbModal), findsNothing);
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
        expect(find.byType(NbModal), findsNothing);
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
        expect(find.byType(NbModal), findsNothing);
        await request.done;
      });
    }

    for (final code in languageCodes) {
      final strings = stringsFor(code);

      testWidgets('in $code E554 queues between two items still ask before '
          'closing (RF-299)', (tester) async {
        final key = await _pumpHost(tester, languageCode: code);
        final controller = FakeAppController(
          state: NodeState(
            transferInProgress: true,
            queues: SendQueuesView(
              selectionId: 1,
              peerFingerprint: senderFingerprint,
              peerName: senderName,
              loose: const [
                QueueItemView(
                  id: 'l1',
                  name: 'a.pdf',
                  isFolder: false,
                  isArchive: false,
                  state: QueueItemState.done,
                  outcome: TransferOutcome.saved,
                ),
                QueueItemView(
                  id: 'l2',
                  name: 'b.pdf',
                  isFolder: false,
                  isArchive: false,
                  state: QueueItemState.pending,
                ),
              ],
              bundles: const [],
              finished: false,
              delivered: 1,
              total: 2,
              completedBytes: 10,
              pendingKnownBytes: 10,
              currentProbeSize: null,
            ),
          ),
        );

        final request = _exit(controller, key);
        await tester.pumpAndSettle();

        expect(find.text(strings.closeDuringTransferTitle), findsOneWidget);
        expect(controller.calls, isEmpty);

        await _tapAndSettle(tester, strings.closeAndCancelButton);
        expect(request.result, AppExitResponse.exit);
        expect(controller.calls, ['shutdown']);
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

      expect(find.byType(NbModal), findsNothing);
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

      expect(find.byType(NbModal), findsNothing);
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
      expect(find.byType(NbModal), findsNothing);

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
      expect(find.byType(NbModal), findsNothing);

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
      expect(find.byType(NbModal), findsNothing);
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

      expect(find.byType(NbModal), findsNothing);
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
      tester.platformDispatcher.accessibilityFeaturesTestValue =
          const FakeAccessibilityFeatures(disableAnimations: true);
      addTearDown(
        tester.platformDispatcher.clearAccessibilityFeaturesTestValue,
      );
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

      expect(find.byType(NbModal), findsOneWidget);
      expect(find.text(strings.closeDuringTransferTitle), findsOneWidget);

      await _tapAndSettle(tester, strings.closeAndCancelButton);

      expect(first.result, AppExitResponse.exit);
      expect(second.result, AppExitResponse.exit);
      expect(_shutdowns(controller), 1);
      expect(find.byType(NbModal), findsNothing);
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
      expect(find.byType(NbModal), findsOneWidget);

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
      expect(find.byType(NbModal), findsOneWidget);

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
      expect(find.byType(NbModal), findsNothing);
      expect(request.finished, isFalse);

      controller.emit(_sending);
      await tester.pumpAndSettle();
      expect(find.byType(NbModal), findsOneWidget);

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

  group('E289 the close with a send shows the file and its percentage '
      '(RF-185, RF-186)', () {
    final peer = entry(
      fingerprint: senderFingerprint,
      name: senderName,
      paired: true,
      type: DeviceType.mobile,
    );

    NodeState uploading({int size = 100, int sent = 61}) => NodeState(
      transferInProgress: true,
      entries: [peer],
      outgoing: outgoingView(size: size, sent: sent),
    );

    NodeState receiving({int size = 1000, int received = 250}) => NodeState(
      transferInProgress: true,
      entries: [peer],
      incoming: incomingView(
        stage: IncomingStage.receiving,
        size: size,
        received: received,
      ),
    );

    Future<(FakeAppController, _Pending<bool>)> open(
      WidgetTester tester,
      NodeState state, {
      String code = 'en',
      bool reduceMotion = true,
      Size window = const Size(800, 600),
      double textScale = 1,
    }) async {
      final key = await _pumpHost(
        tester,
        languageCode: code,
        reduceMotion: reduceMotion,
        window: window,
        textScale: textScale,
      );
      final controller = FakeAppController(state: state);
      final answer = _Pending(
        confirmCloseDuringTransfer(key.currentContext!, controller),
      );
      await tester.pump();
      await tester.pump(modalTransitionDuration);
      return (controller, answer);
    }

    Future<void> finish(WidgetTester tester, _Pending<bool> answer) async {
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pump();
      expect(answer.result, isFalse);
      await answer.done;
    }

    Finder bar() => find.byWidgetPredicate(
      (widget) =>
          widget is SizedBox && widget.width == 264 && widget.height == 34,
    );

    Finder number() => find.descendant(of: bar(), matching: find.byType(Text));

    String shown(WidgetTester tester) => tester.widget<Text>(number()).data!;

    ExitTransfer? transferOf(WidgetTester tester) =>
        tester.widget<ModalStage>(find.byType(ModalStage)).input.transfer;

    String? semanticValue(WidgetTester tester) {
      final handle = tester.ensureSemantics();
      final value = tester.getSemantics(bar()).value;
      handle.dispose();
      return value;
    }

    for (final code in languageCodes) {
      final strings = stringsFor(code);
      final sixtyOne = formatPercent(61, code);

      testWidgets('[$code] an upload at 61 % shows the stage towards the '
          'other device, the file kind, the bar and "$sixtyOne"', (
        tester,
      ) async {
        final (_, answer) = await open(tester, uploading(), code: code);

        expect(find.byType(NbModal), findsOneWidget);
        expect(
          tester.widget<ModalStage>(find.byType(ModalStage)).scene,
          StageScene.exit,
        );
        expect(
          transferOf(tester),
          const ExitTransfer(
            peer: DeviceGlyph.phone,
            kind: FileKind.pdf,
            towardsHub: false,
          ),
        );
        expect(bar(), findsOneWidget);
        expect(tester.getSize(bar()), const Size(264, 34));
        final frame = tester.getRect(
          find
              .descendant(
                of: find.byType(NbModal),
                matching: find.byType(DecoratedBox),
              )
              .first,
        );
        expect(tester.getCenter(bar()).dx, closeTo(frame.center.dx, 0.5));
        expect(shown(tester), sixtyOne);
        expect(semanticValue(tester), sixtyOne);
        expect(find.text(strings.closeDuringTransferTitle), findsOneWidget);
        expect(find.text(strings.closeDuringTransferBody), findsOneWidget);
        await finish(tester, answer);
      });

      testWidgets('[$code] a reception shows the file towards this device and '
          'its own percentage', (tester) async {
        final (_, answer) = await open(tester, receiving(), code: code);

        expect(
          transferOf(tester),
          const ExitTransfer(
            peer: DeviceGlyph.phone,
            kind: FileKind.pdf,
            towardsHub: true,
          ),
        );
        expect(shown(tester), formatPercent(25, code));
        expect(semanticValue(tester), formatPercent(25, code));
        await finish(tester, answer);
      });

      testWidgets('[$code] the buttons: keep open first and filled, close and '
          'cancel quiet, both wide', (tester) async {
        final (_, answer) = await open(tester, uploading(), code: code);

        final view = tester.widget<ModalView>(find.byType(ModalView));
        expect(view.pair, isEmpty);
        final actions = view.actions.cast<ModalButton>();
        expect(
          [for (final b in actions) b.label],
          [strings.keepOpenButton, strings.closeAndCancelButton],
        );
        expect(
          [for (final b in actions) b.kind],
          [ModalButtonKind.primary, ModalButtonKind.negativeQuiet],
        );
        expect(actions.every((b) => !b.inPair && b.onPressed != null), isTrue);
        await finish(tester, answer);
      });

      for (final (label, expected) in const [
        ('keep open', false),
        ('close and cancel', true),
      ]) {
        testWidgets('[$code] with a send, $label answers $expected', (
          tester,
        ) async {
          final button = expected
              ? strings.closeAndCancelButton
              : strings.keepOpenButton;
          final (_, answer) = await open(tester, uploading(), code: code);
          await tester.tap(find.widgetWithText(ModalButton, button));
          await tester.pump();
          expect(answer.result, expected);
          await tester.pumpAndSettle();
          expect(find.byType(NbModal), findsNothing);
          await answer.done;
        });
      }

      testWidgets('[$code] with a send, Esc and a tap outside answer false', (
        tester,
      ) async {
        final (_, answer) = await open(tester, uploading(), code: code);
        await finish(tester, answer);
        expect(find.byType(NbModal), findsNothing);

        final (_, second) = await open(tester, uploading(), code: code);
        await tester.tapAt(const Offset(4, 4));
        await tester.pump();
        expect(second.result, isFalse);
        await tester.pumpAndSettle();
        expect(find.byType(NbModal), findsNothing);
        await second.done;
      });

      for (final reduceMotion in const [false, true]) {
        for (final withSend in const [true, false]) {
          testWidgets('[$code] at 320 px and 130 % nothing overflows, '
              '${withSend ? 'with' : 'without'} a send '
              '(reduceMotion: $reduceMotion)', (tester) async {
            final (_, answer) = await open(
              tester,
              withSend
                  ? uploading()
                  : const NodeState(transferInProgress: true),
              code: code,
              reduceMotion: reduceMotion,
              window: const Size(320, 640),
              textScale: 1.3,
            );
            await tester.pump(const Duration(milliseconds: 1200));
            expect(tester.takeException(), isNull);
            await finish(tester, answer);
            expect(tester.takeException(), isNull);
          });
        }
      }
    }

    testWidgets('the peer glyph is the computer when the device is not in '
        'the list, and a program shows its own kind', (tester) async {
      final (_, answer) = await open(
        tester,
        NodeState(
          transferInProgress: true,
          outgoing: outgoingView(fileName: 'setup.exe', isProgram: true),
        ),
      );

      expect(
        transferOf(tester),
        const ExitTransfer(
          peer: DeviceGlyph.pc,
          kind: FileKind.program,
          towardsHub: false,
        ),
      );
      await finish(tester, answer);
    });

    testWidgets('with an upload and a reception at once, the upload is the '
        'one shown', (tester) async {
      final both = NodeState(
        transferInProgress: true,
        entries: [peer],
        outgoing: outgoingView(size: 100, sent: 61),
        incoming: incomingView(
          stage: IncomingStage.receiving,
          size: 1000,
          received: 250,
        ),
      );
      final (_, answer) = await open(tester, both);

      expect(transferOf(tester)!.towardsHub, isFalse);
      expect(shown(tester), formatPercent(61, 'en'));
      await finish(tester, answer);
    });

    testWidgets('inside the fill, the figure goes 11 px from its end, over '
        'the solid last 56 px, in onPrimary', (tester) async {
      final (_, answer) = await open(tester, uploading());

      final box = tester.getRect(bar());
      final figure = tester.getRect(number());
      const fillEnd = 0.61 * 264;
      expect(figure.right - box.left, closeTo(fillEnd - 11, 0.5));
      expect(figure.left - box.left, greaterThanOrEqualTo(fillEnd - 56));
      final colors = NbColors.of(tester.element(bar()));
      expect(tester.widget<Text>(number()).style!.color, colors.onPrimary);
      await finish(tester, answer);
    });

    for (final (sent, inside) in const [(47, false), (48, true)]) {
      testWidgets('with a fill of ${sent - 4} px the figure goes '
          '${inside ? 'inside' : 'outside'} the fill', (tester) async {
        final (_, answer) = await open(
          tester,
          uploading(size: 264, sent: sent),
        );

        final box = tester.getRect(bar());
        final figure = tester.getRect(number());
        final colors = NbColors.of(tester.element(bar()));
        final style = tester.widget<Text>(number()).style!;
        final fillEnd = sent.toDouble();
        if (inside) {
          expect(figure.right - box.left, closeTo(fillEnd - 11, 0.5));
          expect(style.color, colors.onPrimary);
        } else {
          expect(figure.left - box.left, closeTo(fillEnd + 8, 0.5));
          expect(style.color, colors.textWeak);
        }
        expect(style.fontSize, 13);
        expect(style.fontWeight, FontWeight.w700);
        expect(
          style.fontFeatures,
          contains(const FontFeature.tabularFigures()),
        );
        await finish(tester, answer);
      });
    }

    testWidgets('in motion the sheen stops 56 px before the end of the fill, '
        'so it never runs under the figure', (tester) async {
      final (_, answer) = await open(tester, uploading(), reduceMotion: false);
      await tester.pump(const Duration(milliseconds: 1700));

      final painter = tester
          .widget<CustomPaint>(
            find
                .descendant(of: bar(), matching: find.byType(CustomPaint))
                .first,
          )
          .painter!;
      final canvas = TestRecordingCanvas();
      painter.paint(canvas, const Size(264, 34));
      final clips = [
        for (final call in canvas.invocations)
          if (call.invocation.memberName == #clipRRect)
            call.invocation.positionalArguments.first as RRect,
      ];
      const fill = 0.61 * 264 - 4;
      const sheenEnd = 4 + fill - 56;
      expect(
        clips.map((clip) => clip.right),
        contains(closeTo(sheenEnd, 0.01)),
      );
      expect(
        canvas.invocations.where(
          (call) => call.invocation.memberName == #drawRect,
        ),
        isNotEmpty,
      );
      final figure = tester.getRect(number());
      final box = tester.getRect(bar());
      expect(figure.left - box.left, greaterThan(sheenEnd));
      await finish(tester, answer);
    });

    testWidgets('in motion the figure counts up from 0 and reaches the value '
        'by 1.05 s', (tester) async {
      final (_, answer) = await open(tester, uploading(), reduceMotion: false);

      final early = int.parse(shown(tester).replaceAll(RegExp(r'\D'), ''));
      expect(early, lessThan(61));
      expect(semanticValue(tester), formatPercent(61, 'en'));

      await tester.pump(const Duration(milliseconds: 800));
      expect(shown(tester), formatPercent(61, 'en'));
      await finish(tester, answer);
    });

    testWidgets('with reduced motion everything is in its final state at '
        'once and nothing keeps animating', (tester) async {
      final (controller, answer) = await open(tester, uploading());

      expect(shown(tester), formatPercent(61, 'en'));
      await tester.pumpAndSettle();
      expect(tester.binding.transientCallbackCount, 0);

      controller.emit(uploading(sent: 70));
      await tester.pump();
      expect(shown(tester), formatPercent(70, 'en'));
      expect(semanticValue(tester), formatPercent(70, 'en'));
      await tester.pumpAndSettle();
      await finish(tester, answer);
    });

    testWidgets('the percentage follows the send while the window is open', (
      tester,
    ) async {
      final (controller, answer) = await open(tester, uploading(sent: 10));
      expect(semanticValue(tester), formatPercent(10, 'en'));

      controller.emit(uploading(sent: 99));
      await tester.pump();
      expect(semanticValue(tester), formatPercent(99, 'en'));
      expect(shown(tester), formatPercent(99, 'en'));

      controller.emit(uploading(size: 3, sent: 1));
      await tester.pump();
      expect(semanticValue(tester), formatPercent(33, 'en'));
      await finish(tester, answer);
    });

    testWidgets('if the send goes away while open, the last values stay', (
      tester,
    ) async {
      final (controller, answer) = await open(tester, uploading());
      final before = transferOf(tester);

      controller.emit(const NodeState(transferInProgress: true));
      await tester.pump();
      expect(find.byType(NbModal), findsOneWidget);
      expect(transferOf(tester), before);
      expect(shown(tester), formatPercent(61, 'en'));
      expect(semanticValue(tester), formatPercent(61, 'en'));

      controller.emit(null);
      await tester.pump();
      expect(transferOf(tester), before);
      expect(shown(tester), formatPercent(61, 'en'));
      await finish(tester, answer);
    });

    testWidgets('with no send to show at first, there are the two discs '
        'and no bar; the bar comes with the first send', (tester) async {
      final (controller, answer) = await open(
        tester,
        const NodeState(transferInProgress: true),
      );

      expect(
        tester.widget<ModalStage>(find.byType(ModalStage)).scene,
        StageScene.exit,
      );
      expect(transferOf(tester), isNull);
      expect(bar(), findsNothing);
      expect(find.textContaining('%'), findsNothing);
      expect(
        find.byWidgetPredicate(
          (widget) => widget is Semantics && widget.properties.value != null,
        ),
        findsNothing,
      );
      final strings = stringsFor('en');
      expect(find.text(strings.closeDuringTransferTitle), findsOneWidget);
      expect(find.text(strings.keepOpenButton), findsOneWidget);
      expect(find.text(strings.closeAndCancelButton), findsOneWidget);

      controller.emit(uploading(sent: 30));
      await tester.pump();
      expect(bar(), findsOneWidget);
      expect(shown(tester), formatPercent(30, 'en'));
      expect(semanticValue(tester), formatPercent(30, 'en'));
      expect(transferOf(tester), isNotNull);
      await finish(tester, answer);
    });

    testWidgets('the window stops listening to the controller once closed', (
      tester,
    ) async {
      final key = await _pumpHost(tester);
      final controller = _ListenerCountingController(state: uploading());
      final answer = _Pending(
        confirmCloseDuringTransfer(key.currentContext!, controller),
      );
      await tester.pumpAndSettle();
      expect(controller.listeners, 1);

      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(answer.result, isFalse);
      expect(controller.listeners, 0);
      await answer.done;
    });

    testWidgets('handleExitRequest passes its controller, so the window '
        'shows the send of the app', (tester) async {
      final key = await _pumpHost(tester);
      final controller = FakeAppController(state: uploading());

      final request = _exit(controller, key);
      await tester.pumpAndSettle();
      expect(transferOf(tester)!.kind, FileKind.pdf);
      expect(shown(tester), formatPercent(61, 'en'));

      await _tapAndSettle(tester, stringsFor('en').keepOpenButton);
      expect(request.result, AppExitResponse.cancel);
      await request.done;
    });
  });

  group('E289 with the Windows font, the wide buttons of the close are read '
      'whole at 130 % (point 218)', () {
    setUpAll(loadSegoe);

    for (final code in languageCodes) {
      for (final window in const [Size(760, 520), Size(800, 600)]) {
        testWidgets('[$code] in a ${window.width.toInt()}x'
            '${window.height.toInt()} window', (tester) async {
          final key = await _pumpHost(
            tester,
            languageCode: code,
            window: window,
            textScale: 1.3,
          );
          final answer = _Pending(
            confirmCloseDuringTransfer(
              key.currentContext!,
              FakeAppController(
                state: NodeState(
                  transferInProgress: true,
                  outgoing: outgoingView(size: 100, sent: 61),
                ),
              ),
            ),
          );
          await tester.pumpAndSettle();

          final paragraphs = tester.renderObjectList<RenderParagraph>(
            find.descendant(
              of: find.byType(ModalButton),
              matching: find.byType(RichText),
            ),
          );
          expect(paragraphs, hasLength(2));
          expect(paragraphs.where((p) => p.didExceedMaxLines), isEmpty);
          expect(tester.takeException(), isNull);

          await tester.sendKeyEvent(LogicalKeyboardKey.escape);
          await tester.pumpAndSettle();
          expect(answer.result, isFalse);
          await answer.done;
        });
      }
    }
  });

  group('H1 the close with a send is never answered by another modal '
      '(RF-185 of the 005, RF-186 of the 004)', () {
    for (final code in languageCodes) {
      final strings = stringsFor(code);
      final closeTitle = strings.closeDuringTransferTitle;
      const unpairName = 'Portátil de Ana';

      testWidgets('[$code] unpair confirmed and the window X 300 ms later: at '
          '2 s the close question is still open, nothing is shut down and '
          'the unpair has answered true once', (tester) async {
        final key = await _pumpHost(
          tester,
          languageCode: code,
          reduceMotion: false,
        );
        var confirms = 0;
        final unpair = _Pending(
          confirmUnpairDevice(
            key.currentContext!,
            name: unpairName,
            type: DeviceType.mobile,
            onConfirm: () async {
              confirms++;
            },
          ),
        );
        await tester.pump();
        await tester.pump(modalTransitionDuration);
        await tester.tap(
          modalButtonIn(
            modalWith(strings.unpairTitle(unpairName)),
            strings.unpairButton,
          ),
        );
        expect(confirms, 1);
        await tester.pump(const Duration(milliseconds: 300));

        final controller = FakeAppController(state: _sending);
        final request = _exit(controller, key);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 1700));

        expect(request.finished, isFalse);
        expect(controller.calls, isEmpty);
        expect(find.text(closeTitle), findsOneWidget);
        expect(routeOf(tester, modalWith(closeTitle)).isCurrent, isTrue);
        expect(unpair.result, isTrue);
        expect(confirms, 1);
        expect(find.text(strings.unpairTitle(unpairName)), findsNothing);

        await tester.tap(
          modalButtonIn(modalWith(closeTitle), strings.keepOpenButton),
        );
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 400));
        await request.done;
        expect(request.result, AppExitResponse.cancel);
        expect(controller.calls, isEmpty);
        await unpair.done;
      });

      for (final reduceMotion in const [true, false]) {
        for (final (label, expected) in [
          (strings.keepOpenButton, false),
          (strings.closeAndCancelButton, true),
        ]) {
          testWidgets('[$code] "$label" landing in the same frame a route is '
              'pushed on top answers $expected and leaves that route open '
              '(reduceMotion: $reduceMotion)', (tester) async {
            final key = await _pumpHost(
              tester,
              languageCode: code,
              reduceMotion: reduceMotion,
            );
            final answer = _Pending(
              confirmCloseDuringTransfer(
                key.currentContext!,
                FakeAppController(state: _sending),
              ),
            );
            await tester.pump();
            await tester.pump(modalTransitionDuration);
            await tester.pump(const Duration(milliseconds: 100));
            final closeRoute = routeOf(tester, modalWith(closeTitle));
            final action = modalButtonAction(
              tester,
              modalWith(closeTitle),
              label,
            );

            final cover = pushCover(key.currentContext!);
            action();
            await tester.pump();
            expect(closeRoute.isActive, isFalse);
            expect(answer.result, expected);
            await tester.pump(modalTransitionDuration);
            await tester.pump(const Duration(milliseconds: 400));

            expect(cover.finished, isFalse);
            expect(cover.taps, 0);
            expect(cover.route.isCurrent, isTrue);
            expect(find.text(closeTitle), findsNothing);
            expect(find.byType(NbModal), findsOneWidget);
            await answer.done;
          });
        }
      }
    }
  });

  group('H2 the close with a send is off while covered and for 500 ms after '
      '(RF-185 of the 005, point 243)', () {
    for (final code in languageCodes) {
      final strings = stringsFor(code);
      final closeTitle = strings.closeDuringTransferTitle;
      final labels = [strings.keepOpenButton, strings.closeAndCancelButton];

      List<bool> states(WidgetTester tester) =>
          modalButtonStates(tester, modalWith(closeTitle), labels);

      for (final reduceMotion in const [false, true]) {
        for (final gap in const [Duration.zero, Duration(milliseconds: 120)]) {
          testWidgets('[$code] a double click on the cover over "Close and '
              'cancel" does not answer; both buttons stay off until 500 ms '
              'after the cover leaves (reduceMotion: $reduceMotion, gap: '
              '${gap.inMilliseconds} ms)', (tester) async {
            final key = await _pumpHost(
              tester,
              languageCode: code,
              reduceMotion: reduceMotion,
            );
            final answer = _Pending(
              confirmCloseDuringTransfer(
                key.currentContext!,
                FakeAppController(state: _sending),
              ),
            );
            await tester.pump();
            await tester.pump(modalTransitionDuration);
            expect(states(tester), [true, true]);

            final cover = pushCover(key.currentContext!);
            await tester.pump();
            expect(states(tester), [false, false]);
            await tester.pump(modalTransitionDuration);
            await tester.pump(const Duration(seconds: 2));
            expect(states(tester), [false, false]);

            final point = overlapCenter(
              tester,
              modalButtonIn(
                modalWith(closeTitle),
                strings.closeAndCancelButton,
              ),
              coverButton,
            );
            await tester.tapAt(point);
            await tester.pump();
            expect(cover.result, coverResult);
            if (gap > Duration.zero) await tester.pump(gap);
            await tester.tapAt(point);
            await tester.pump();

            expect(cover.taps, 1);
            expect(answer.finished, isFalse);
            expect(states(tester), [false, false]);

            await tester.pump(const Duration(milliseconds: 480) - gap);
            expect(states(tester), [false, false]);
            await tester.tapAt(point);
            await tester.pump();
            expect(answer.finished, isFalse);

            await tester.pump(const Duration(milliseconds: 40));
            expect(states(tester), [true, true]);
            await tester.tapAt(point);
            await tester.pump();
            expect(answer.result, isTrue);
            await tester.pump(const Duration(milliseconds: 400));
            await tester.pump();
            expect(find.byType(NbModal), findsNothing);
            await answer.done;
          });
        }
      }
    }
  });

  group('coverOnly: the close with a send has no delay and ignores the '
      'lifecycle (points 159 and 243)', () {
    final strings = stringsFor('en');
    final closeTitle = strings.closeDuringTransferTitle;
    final labels = [strings.keepOpenButton, strings.closeAndCancelButton];

    List<bool> states(WidgetTester tester) =>
        modalButtonStates(tester, modalWith(closeTitle), labels);

    for (final reduceMotion in const [false, true]) {
      testWidgets('both buttons are on in the very first frame '
          '(reduceMotion: $reduceMotion)', (tester) async {
        final key = await _pumpHost(tester, reduceMotion: reduceMotion);
        final answer = _Pending(
          confirmCloseDuringTransfer(
            key.currentContext!,
            FakeAppController(state: _sending),
          ),
        );
        await tester.pump();

        expect(states(tester), [true, true]);
        await tester.pump(modalTransitionDuration);
        await tester.tap(
          modalButtonIn(modalWith(closeTitle), strings.closeAndCancelButton),
        );
        await tester.pump();
        expect(answer.result, isTrue);
        await tester.pump(const Duration(milliseconds: 400));
        await answer.done;
      });
    }

    for (final target in const [
      AppLifecycleState.inactive,
      AppLifecycleState.hidden,
      AppLifecycleState.paused,
    ]) {
      testWidgets('going to ${target.name} and back keeps both buttons on', (
        tester,
      ) async {
        resumeOnTearDown(tester);
        await stepLifecycle(tester, AppLifecycleState.resumed);
        final key = await _pumpHost(tester);
        final answer = _Pending(
          confirmCloseDuringTransfer(
            key.currentContext!,
            FakeAppController(state: _sending),
          ),
        );
        await tester.pumpAndSettle();

        for (final state in lifecyclePath(AppLifecycleState.resumed, target)) {
          await stepLifecycle(tester, state);
          expect(states(tester), [true, true], reason: state.name);
        }
        await tester.pump(const Duration(seconds: 1));
        expect(states(tester), [true, true]);
        for (final state in lifecyclePath(target, AppLifecycleState.resumed)) {
          await stepLifecycle(tester, state);
          expect(states(tester), [true, true], reason: state.name);
        }
        await _tapAndSettle(tester, strings.keepOpenButton);
        expect(answer.result, isFalse);
        await answer.done;
      });
    }

    testWidgets('asked with the app inactive, both buttons are on in the '
        'first frame', (tester) async {
      resumeOnTearDown(tester);
      final key = await _pumpHost(tester);
      await goToLifecycle(tester, AppLifecycleState.inactive);
      final answer = _Pending(
        confirmCloseDuringTransfer(
          key.currentContext!,
          FakeAppController(state: _sending),
        ),
      );
      await tester.pump();

      expect(states(tester), [true, true]);
      await _tapAndSettle(tester, strings.keepOpenButton);
      expect(answer.result, isFalse);
      await answer.done;
    });
  });
}
