import 'dart:async';
import 'dart:ui' show AppExitResponse;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nexus_bridges/main.dart';
import 'package:nexus_bridges/src/l10n/app_strings.dart';
import 'package:nexus_bridges/src/ui/attention.dart';
import 'package:nexus_bridges/src/ui/modal/modal_frame.dart';
import 'package:nexus_bridges/src/ui/settings/system_tray_section.dart';
import 'package:nexus_bridges/src/window/window_coordinator.dart';
import 'package:nexus_bridges/src/window/window_host.dart';
import 'package:nexus_bridges_core/nexus_bridges_core.dart';

import '../ui/fake_app_controller.dart';
import '../ui/fake_window_host.dart';
import '../ui/settings/settings_fixtures.dart'
    show openSettings, settingsState, tallWindow;
import '../ui/transfer_fixtures.dart'
    show incomingView, outgoingView, setWindow;

NodeState _sending() =>
    NodeState(transferInProgress: true, outgoing: outgoingView());

NodeState _receiving() => NodeState(
  transferInProgress: true,
  incoming: incomingView(stage: IncomingStage.receiving),
);

const NodeState _idle = NodeState();
const NodeState _pickerOpen = NodeState(pickerOpen: true);

Future<(FakeAppController, FakeWindowHost)> _mount(
  WidgetTester tester, {
  NodeState state = _idle,
  String code = 'es',
  bool closeToTray = true,
  bool trayHintShown = false,
  FakeWindowHost? host,
  Size size = const Size(1200, 800),
}) async {
  setWindow(tester, size);
  final controller = FakeAppController(
    state: state,
    languageCode: code,
    closeToTray: closeToTray,
    trayHintShown: trayHintShown,
  );
  final window = host ?? FakeWindowHost();
  await tester.pumpWidget(NexusBridgesApp(controller, windowHost: window));
  await tester.pump();
  await tester.pump(const Duration(seconds: 1));
  return (controller, window);
}

Future<void> _send(
  WidgetTester tester,
  FakeWindowHost host,
  WindowEvent event,
) async {
  host.emit(event);
  await tester.pump();
  await tester.pump();
}

Future<void> _close(WidgetTester tester, FakeWindowHost host) =>
    _send(tester, host, const CloseRequested());

Future<void> _exit(WidgetTester tester, FakeWindowHost host) =>
    _send(tester, host, const ExitRequested());

Future<void> _armConfirmation(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(seconds: 1));
}

Finder _confirmation() => find.byType(NbModal);

Future<void> _tapText(WidgetTester tester, String text) async {
  await tester.tap(find.text(text));
  await tester.pump();
  await tester.pump(const Duration(seconds: 1));
}

Future<Map<String, Object?>> _requestAppExit(WidgetTester tester) {
  final reply = Completer<Map<String, Object?>>();
  unawaited(
    tester.binding.defaultBinaryMessenger.handlePlatformMessage(
      SystemChannels.platform.name,
      SystemChannels.platform.codec.encodeMethodCall(
        const MethodCall('System.requestAppExit'),
      ),
      (data) {
        final decoded = SystemChannels.platform.codec.decodeEnvelope(data!);
        reply.complete(Map<String, Object?>.from(decoded as Map));
      },
    ),
  );
  return reply.future;
}

final class _Harness {
  _Harness({
    required this.controller,
    required this.host,
    Duration shutdownBudget = const Duration(seconds: 5),
  }) : attention = AttentionWatcher(controller),
       neutral = FocusNode() {
    coordinator = WindowCoordinator(
      host: host,
      controller: controller,
      attention: attention,
      context: () => null,
      neutralFocus: neutral,
      shutdownBudget: shutdownBudget,
    );
  }

  final FakeAppController controller;
  final FakeWindowHost host;
  final AttentionWatcher attention;
  final FocusNode neutral;
  late final WindowCoordinator coordinator;

  void dispose() {
    coordinator.dispose();
    attention.dispose();
    neutral.dispose();
    controller.dispose();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('start: the window is attached and the tray set up (RF-521)', () {
    testWidgets('it attaches, then sets the tray with the language texts', (
      tester,
    ) async {
      final (_, host) = await _mount(tester);
      expect(host.calls, [
        'attach',
        'setTray true NexusBridges|Abrir NexusBridges|Salir',
      ]);
    });

    testWidgets('with the tray off it sets it disabled', (tester) async {
      final (_, host) = await _mount(tester, closeToTray: false);
      expect(host.calls, [
        'attach',
        'setTray false NexusBridges|Abrir NexusBridges|Salir',
      ]);
    });

    testWidgets('an attach that fails leaves the app working', (tester) async {
      final failing = FakeWindowHost()..attachError = StateError('no window');
      await _mount(tester, host: failing);
      expect(tester.takeException(), isNull);
      expect(failing.calls.first, 'attach');
    });

    testWidgets('a setTray that fails leaves the app working', (tester) async {
      final failing = FakeWindowHost()..trayError = StateError('no shell');
      await _mount(tester, host: failing);
      expect(tester.takeException(), isNull);
    });
  });

  group('E880 the X hides the window (RF-522)', () {
    testWidgets('with the tray on and nothing going on: it hides', (
      tester,
    ) async {
      final (controller, host) = await _mount(tester);
      await _close(tester, host);
      expect(host.countOf('hide'), 1);
      expect(host.calls, isNot(contains('quit')));
      expect(host.calls, isNot(contains('minimize')));
      expect(controller.calls, isNot(contains('shutdown')));
    });

    testWidgets('sending: it hides without asking and keeps the transfer', (
      tester,
    ) async {
      final (controller, host) = await _mount(tester, state: _sending());
      await _close(tester, host);
      await _armConfirmation(tester);
      expect(host.countOf('hide'), 1);
      expect(_confirmation(), findsNothing);
      expect(controller.calls, isNot(contains('shutdown')));
      expect(controller.calls, isNot(contains('cancelSending')));
      expect(host.calls, isNot(contains('quit')));
    });

    testWidgets('receiving: it hides without asking and keeps the transfer', (
      tester,
    ) async {
      final (controller, host) = await _mount(tester, state: _receiving());
      await _close(tester, host);
      await _armConfirmation(tester);
      expect(host.countOf('hide'), 1);
      expect(_confirmation(), findsNothing);
      expect(controller.calls, isNot(contains('shutdown')));
      expect(
        controller.calls.where((call) => call.startsWith('cancelReceiving')),
        isEmpty,
      );
    });

    testWidgets('with a picker open it hides only when the picker closes', (
      tester,
    ) async {
      final (controller, host) = await _mount(tester, state: _pickerOpen);
      await _close(tester, host);
      await tester.pump(const Duration(seconds: 2));
      expect(host.calls, isNot(contains('hide')));
      controller.emit(_idle);
      await tester.pump();
      await tester.pump();
      expect(host.countOf('hide'), 1);
    });

    testWidgets('two X in a row while one waits count as one', (tester) async {
      final (controller, host) = await _mount(tester, state: _pickerOpen);
      await _close(tester, host);
      await _close(tester, host);
      controller.emit(_idle);
      await tester.pump();
      await tester.pump();
      expect(host.countOf('hide'), 1);
    });

    testWidgets('after hiding, the X works again', (tester) async {
      final (_, host) = await _mount(tester, trayHintShown: true);
      await _close(tester, host);
      await _close(tester, host);
      expect(host.countOf('hide'), 2);
    });

    testWidgets('the exit request of the platform also hides, and cancels', (
      tester,
    ) async {
      final (_, host) = await _mount(tester);
      final reply = _requestAppExit(tester);
      await tester.pump();
      await tester.pump();
      expect(host.countOf('hide'), 1);
      expect((await reply)['response'], AppExitResponse.cancel.name);
    });

    testWidgets('without the native side the close follows the flow of 005', (
      tester,
    ) async {
      final unattached = FakeWindowHost()..attached = false;
      final (controller, host) = await _mount(tester, host: unattached);
      final reply = _requestAppExit(tester);
      await tester.pump();
      await tester.pump();
      expect((await reply)['response'], AppExitResponse.exit.name);
      expect(controller.calls, contains('shutdown'));
      expect(host.calls, isNot(contains('hide')));
      expect(host.calls, isNot(contains('quit')));
    });

    testWidgets('without the native side a transfer still asks for '
        'confirmation', (tester) async {
      final unattached = FakeWindowHost()..attached = false;
      final (controller, _) = await _mount(
        tester,
        state: _sending(),
        host: unattached,
      );
      final reply = _requestAppExit(tester);
      await _armConfirmation(tester);
      expect(_confirmation(), findsOneWidget);
      await _tapText(tester, stringsFor('es').keepOpenButton);
      expect((await reply)['response'], AppExitResponse.cancel.name);
      expect(controller.calls, isNot(contains('shutdown')));
    });
  });

  group('E881 the Windows notice shows once (RF-523)', () {
    testWidgets('the first X shows it, with the texts of the language', (
      tester,
    ) async {
      for (final code in const ['es', 'en']) {
        final strings = stringsFor(code);
        final (controller, host) = await _mount(tester, code: code);
        await _close(tester, host);
        expect(host.hints, [
          (
            title: strings.systemTrayHintTitle,
            body: strings.systemTrayHintBody,
          ),
        ]);
        expect(controller.calls, contains('markTrayHintShown'));
        await tester.pumpWidget(const SizedBox.shrink());
      }
    });

    testWidgets('it is shown after hiding', (tester) async {
      final (_, host) = await _mount(tester);
      await _close(tester, host);
      expect(
        host.calls.indexOf('showTrayHint'),
        greaterThan(host.calls.indexOf('hide')),
      );
    });

    testWidgets('the second X does not show it again', (tester) async {
      final (controller, host) = await _mount(tester);
      await _close(tester, host);
      await _close(tester, host);
      expect(host.countOf('hide'), 2);
      expect(host.countOf('showTrayHint'), 1);
      expect(
        controller.calls.where((call) => call == 'markTrayHintShown'),
        hasLength(1),
      );
    });

    testWidgets('already shown at start: never', (tester) async {
      final (controller, host) = await _mount(tester, trayHintShown: true);
      await _close(tester, host);
      await _close(tester, host);
      expect(host.calls, isNot(contains('showTrayHint')));
      expect(controller.calls, isNot(contains('markTrayHintShown')));
    });

    testWidgets('a notice that fails is ignored and counts as shown', (
      tester,
    ) async {
      final failing = FakeWindowHost()..hintError = StateError('silenced');
      final (controller, host) = await _mount(tester, host: failing);
      await _close(tester, host);
      expect(tester.takeException(), isNull);
      expect(host.countOf('hide'), 1);
      expect(controller.calls, contains('markTrayHintShown'));
    });

    testWidgets('mine or stranger sends never show it: it needs an X', (
      tester,
    ) async {
      final (controller, host) = await _mount(tester);
      controller.emit(_sending());
      await tester.pump();
      expect(host.calls, isNot(contains('showTrayHint')));
    });
  });

  group('E882 Quit from the menu (RF-526)', () {
    testWidgets('with nothing going on: goodbye and quit, no window', (
      tester,
    ) async {
      final (controller, host) = await _mount(tester);
      await _exit(tester, host);
      expect(host.calls, isNot(contains('show')));
      expect(controller.calls, contains('shutdown'));
      expect(host.countOf('quit'), 1);
      expect(_confirmation(), findsNothing);
    });

    testWidgets('with a send: the window, then the confirmation', (
      tester,
    ) async {
      final (controller, host) = await _mount(tester, state: _sending());
      await _exit(tester, host);
      await _armConfirmation(tester);
      expect(host.countOf('show'), 1);
      expect(_confirmation(), findsOneWidget);
      expect(controller.calls, isNot(contains('shutdown')));
      expect(host.calls, isNot(contains('quit')));
    });

    testWidgets('"Keep open": neither shutdown nor quit, and the window stays '
        'visible', (tester) async {
      final (controller, host) = await _mount(tester, state: _sending());
      await _exit(tester, host);
      await _armConfirmation(tester);
      await _tapText(tester, stringsFor('es').keepOpenButton);
      expect(controller.calls, isNot(contains('shutdown')));
      expect(host.calls, isNot(contains('quit')));
      expect(host.calls, isNot(contains('hide')));
      expect(_confirmation(), findsNothing);
    });

    testWidgets('confirming: shutdown and then quit', (tester) async {
      final (controller, host) = await _mount(tester, state: _sending());
      await _exit(tester, host);
      await _armConfirmation(tester);
      await _tapText(tester, stringsFor('es').closeAndCancelButton);
      expect(controller.calls, contains('shutdown'));
      expect(host.countOf('quit'), 1);
    });

    testWidgets('quit never goes before the shutdown has finished', (
      tester,
    ) async {
      final done = Completer<void>();
      final (controller, host) = await _mount(tester);
      controller.shutdownResult = () => done.future;
      await _exit(tester, host);
      expect(controller.calls, contains('shutdown'));
      expect(host.calls, isNot(contains('quit')));
      done.complete();
      await tester.pump();
      await tester.pump();
      expect(host.countOf('quit'), 1);
    });

    testWidgets('a shutdown that never ends: quit after 5 s, not before', (
      tester,
    ) async {
      final (controller, host) = await _mount(tester);
      controller.shutdownResult = () => Completer<void>().future;
      await _exit(tester, host);
      await tester.pump(const Duration(milliseconds: 4900));
      expect(host.calls, isNot(contains('quit')));
      await tester.pump(const Duration(milliseconds: 200));
      await tester.pump();
      expect(host.countOf('quit'), 1);
    });

    testWidgets('a shutdown that fails still quits', (tester) async {
      final (controller, host) = await _mount(tester);
      controller.shutdownResult = () async => throw StateError('stuck');
      await _exit(tester, host);
      await tester.pump();
      expect(host.countOf('quit'), 1);
      expect(tester.takeException(), isNull);
    });

    testWidgets('with a picker open it waits for it', (tester) async {
      final (controller, host) = await _mount(tester, state: _pickerOpen);
      await _exit(tester, host);
      await tester.pump(const Duration(seconds: 2));
      expect(host.calls, isNot(contains('quit')));
      controller.emit(_idle);
      await tester.pump();
      await tester.pump();
      expect(host.countOf('quit'), 1);
    });

    testWidgets('two Quit in a row ask for one confirmation', (tester) async {
      final (_, host) = await _mount(tester, state: _sending());
      await _exit(tester, host);
      await _exit(tester, host);
      await _armConfirmation(tester);
      expect(_confirmation(), findsOneWidget);
      expect(host.countOf('show'), 1);
    });

    testWidgets('Quit while an X waits for a picker still quits', (
      tester,
    ) async {
      final (controller, host) = await _mount(tester, state: _pickerOpen);
      await _close(tester, host);
      await _exit(tester, host);
      controller.emit(_idle);
      await tester.pump();
      await tester.pump();
      await tester.pump();
      expect(host.countOf('quit'), 1);
    });
  });

  group('E883 the tray switch (RF-528)', () {
    testWidgets('off: setTray disabled and the X closes the app', (
      tester,
    ) async {
      final (controller, host) = await _mount(tester);
      await controller.setCloseToTray(false);
      await tester.pump();
      expect(host.calls.last, startsWith('setTray false'));
      await _close(tester, host);
      expect(host.calls, isNot(contains('hide')));
      expect(controller.calls, contains('shutdown'));
      expect(host.countOf('quit'), 1);
    });

    testWidgets('off with a send: the X asks for the confirmation', (
      tester,
    ) async {
      final (controller, host) = await _mount(
        tester,
        state: _sending(),
        closeToTray: false,
      );
      await _close(tester, host);
      await _armConfirmation(tester);
      expect(_confirmation(), findsOneWidget);
      expect(host.calls, isNot(contains('hide')));
      await _tapText(tester, stringsFor('es').keepOpenButton);
      expect(controller.calls, isNot(contains('shutdown')));
      expect(host.calls, isNot(contains('quit')));
    });

    testWidgets('off with a send and confirming: shutdown and quit', (
      tester,
    ) async {
      final (controller, host) = await _mount(
        tester,
        state: _sending(),
        closeToTray: false,
      );
      await _close(tester, host);
      await _armConfirmation(tester);
      await _tapText(tester, stringsFor('es').closeAndCancelButton);
      expect(controller.calls, contains('shutdown'));
      expect(host.countOf('quit'), 1);
    });

    testWidgets('on again: setTray enabled and the X hides again', (
      tester,
    ) async {
      final (controller, host) = await _mount(tester, closeToTray: false);
      await controller.setCloseToTray(true);
      await tester.pump();
      expect(host.calls.last, startsWith('setTray true'));
      await _close(tester, host);
      expect(host.countOf('hide'), 1);
    });

    testWidgets('the switch of Settings has the effect', (tester) async {
      final es = stringsFor('es');
      final (controller, host) = await _mount(
        tester,
        state: settingsState(),
        size: tallWindow,
      );
      await openSettings(tester, es);
      final toggle = find.byType(SettingsSwitch);
      await tester.ensureVisible(toggle);
      await tester.pumpAndSettle();
      await tester.tap(toggle);
      await tester.pump();
      await tester.pump();
      expect(controller.calls, contains('setCloseToTray false'));
      expect(host.calls.last, startsWith('setTray false'));
    });
  });

  group('E884 the texts of the tray follow the language (RF-510, RF-521)', () {
    testWidgets('Spanish to English', (tester) async {
      final (controller, host) = await _mount(tester);
      await controller.setLanguage('en');
      await tester.pump();
      expect(
        host.calls.last,
        'setTray true NexusBridges|Open NexusBridges|Quit',
      );
    });

    testWidgets('English to Spanish', (tester) async {
      final (controller, host) = await _mount(tester, code: 'en');
      expect(
        host.calls.last,
        'setTray true NexusBridges|Open NexusBridges|Quit',
      );
      await controller.setLanguage('es');
      await tester.pump();
      expect(
        host.calls.last,
        'setTray true NexusBridges|Abrir NexusBridges|Salir',
      );
    });

    testWidgets('with the tray off the texts still follow, disabled', (
      tester,
    ) async {
      final (controller, host) = await _mount(tester, closeToTray: false);
      await controller.setLanguage('en');
      await tester.pump();
      expect(
        host.calls.last,
        'setTray false NexusBridges|Open NexusBridges|Quit',
      );
    });

    testWidgets('other changes of the controller do not call setTray', (
      tester,
    ) async {
      final (controller, host) = await _mount(tester);
      final before = host.calls.length;
      controller.emit(_sending());
      await tester.pump();
      expect(host.calls.length, before);
    });
  });

  group('E887 the icon that does not show (RF-522)', () {
    testWidgets('setTray says hidden: the X minimizes, with no notice', (
      tester,
    ) async {
      final down = FakeWindowHost()..trayVisible = false;
      final (controller, host) = await _mount(tester, host: down);
      await _close(tester, host);
      expect(host.countOf('minimize'), 1);
      expect(host.calls, isNot(contains('hide')));
      expect(host.calls, isNot(contains('showTrayHint')));
      expect(host.calls, isNot(contains('quit')));
      expect(controller.calls, isNot(contains('markTrayHintShown')));
      expect(controller.calls, isNot(contains('shutdown')));
    });

    testWidgets('with a send and the icon down: minimizes without asking', (
      tester,
    ) async {
      final down = FakeWindowHost()..trayVisible = false;
      final (controller, host) = await _mount(
        tester,
        state: _sending(),
        host: down,
      );
      await _close(tester, host);
      await _armConfirmation(tester);
      expect(host.countOf('minimize'), 1);
      expect(_confirmation(), findsNothing);
      expect(controller.calls, isNot(contains('shutdown')));
    });

    testWidgets('the icon comes back by the event: the X hides, with the '
        'notice', (tester) async {
      final down = FakeWindowHost()..trayVisible = false;
      final (_, host) = await _mount(tester, host: down);
      await _send(tester, host, const TrayVisibilityChanged(true));
      await _close(tester, host);
      expect(host.calls, isNot(contains('minimize')));
      expect(host.countOf('hide'), 1);
      expect(host.countOf('showTrayHint'), 1);
    });

    testWidgets('the icon goes away by the event: the X minimizes', (
      tester,
    ) async {
      final (_, host) = await _mount(tester);
      await _send(tester, host, const TrayVisibilityChanged(false));
      await _close(tester, host);
      expect(host.countOf('minimize'), 1);
      expect(host.calls, isNot(contains('hide')));
    });

    testWidgets('a setTray that fails counts as hidden: the X minimizes', (
      tester,
    ) async {
      final failing = FakeWindowHost()..trayError = StateError('no shell');
      final (_, host) = await _mount(tester, host: failing);
      await _close(tester, host);
      expect(host.countOf('minimize'), 1);
      expect(host.calls, isNot(contains('hide')));
    });

    testWidgets('the hint is not spent by a minimize', (tester) async {
      final down = FakeWindowHost()..trayVisible = false;
      final (_, host) = await _mount(tester, host: down);
      await _close(tester, host);
      await _send(tester, host, const TrayVisibilityChanged(true));
      await _close(tester, host);
      expect(host.countOf('showTrayHint'), 1);
    });
  });

  group('the close handler never throws (T8a)', () {
    test('a hide that fails answers cancel', () async {
      final harness = _Harness(
        controller: FakeAppController(state: _idle),
        host: FakeWindowHost()..hideError = StateError('gone'),
      );
      addTearDown(harness.dispose);
      await harness.coordinator.start();
      await expectLater(
        harness.coordinator.handleClose(),
        completion(AppExitResponse.cancel),
      );
    });

    test('a minimize that fails answers cancel', () async {
      final harness = _Harness(
        controller: FakeAppController(state: _idle),
        host: FakeWindowHost()
          ..trayVisible = false
          ..minimizeError = StateError('gone'),
      );
      addTearDown(harness.dispose);
      await harness.coordinator.start();
      await expectLater(
        harness.coordinator.handleClose(),
        completion(AppExitResponse.cancel),
      );
    });

    test('a quit that fails answers cancel', () async {
      final harness = _Harness(
        controller: FakeAppController(state: _idle, closeToTray: false),
        host: FakeWindowHost()..quitError = StateError('gone'),
      );
      addTearDown(harness.dispose);
      await harness.coordinator.start();
      await expectLater(
        harness.coordinator.handleClose(),
        completion(AppExitResponse.cancel),
      );
    });

    test('a handleExit whose quit fails completes', () async {
      final harness = _Harness(
        controller: FakeAppController(state: _idle),
        host: FakeWindowHost()..quitError = StateError('gone'),
      );
      addTearDown(harness.dispose);
      await harness.coordinator.start();
      await expectLater(harness.coordinator.handleExit(), completes);
    });

    test('a close before start follows the flow of 005', () async {
      final harness = _Harness(
        controller: FakeAppController(state: _idle),
        host: FakeWindowHost(),
      );
      addTearDown(harness.dispose);
      await expectLater(
        harness.coordinator.handleClose(),
        completion(AppExitResponse.exit),
      );
      expect(harness.host.calls, isEmpty);
    });

    test('after dispose the events do nothing', () async {
      final harness = _Harness(
        controller: FakeAppController(state: _idle),
        host: FakeWindowHost(),
      );
      await harness.coordinator.start();
      harness.coordinator.dispose();
      harness.host.emit(const CloseRequested());
      await Future<void>.delayed(Duration.zero);
      expect(harness.host.calls, isNot(contains('hide')));
      harness.dispose();
    });

    test('the budget applies to a stuck shutdown', () async {
      final controller = FakeAppController(state: _idle)
        ..shutdownResult = () => Completer<void>().future;
      final harness = _Harness(
        controller: controller,
        host: FakeWindowHost(),
        shutdownBudget: const Duration(milliseconds: 20),
      );
      addTearDown(harness.dispose);
      await harness.coordinator.start();
      await harness.coordinator.handleExit();
      expect(harness.host.calls.last, 'quit');
    });
  });
}
