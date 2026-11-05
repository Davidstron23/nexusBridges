import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nexus_bridges/main.dart';
import 'package:nexus_bridges/src/l10n/app_strings.dart';
import 'package:nexus_bridges/src/ui/armed.dart';
import 'package:nexus_bridges/src/ui/diagram/flow_diagram.dart';
import 'package:nexus_bridges/src/ui/foreground_arming.dart';
import 'package:nexus_bridges/src/ui/modal/modal_frame.dart';
import 'package:nexus_bridges_core/nexus_bridges_core.dart';

import 'fake_app_controller.dart';
import 'fake_window_host.dart';
import 'lifecycle_fixtures.dart';
import 'pairing_fixtures.dart';
import 'settings/settings_fixtures.dart' show openSettings, settingsScreen;
import 'transfer_fixtures.dart'
    show buttonIn, incomingView, isEnabled, resultView, senderName, setWindow;

const Duration _beforeArmed = Duration(milliseconds: 400);
const Duration _afterArmed = Duration(milliseconds: 600);
const Duration _early = Duration(milliseconds: 300);
const Duration _lastMs = Duration(milliseconds: 1);
const Size _window = Size(1200, 800);
const Offset _outside = Offset(5, 5);

const FolderQuestionView _firstTime = FolderQuestionView(
  kind: FolderQuestionKind.firstTime,
  proposedPath: r'C:\Users\David\Downloads',
);

const FolderQuestionView _caution = FolderQuestionView(
  kind: FolderQuestionKind.thisTime,
  proposedPath: r'C:\Users\David\Downloads',
  cautionPath: r'C:\Users\David\OneDrive',
);

const NodeState _idle = NodeState();

final TargetPlatformVariant _windows = TargetPlatformVariant.only(
  TargetPlatform.windows,
);

final MineQuestion _mine = MineQuestion(
  fingerprint: fingerprintOf('5555AAAA'),
  deviceName: 'Portatil',
);

NodeState _warning([String id = 's1']) =>
    NodeState(incoming: incomingView(id: id));

NodeState _folderQuestion(String id, FolderQuestionView folder) => NodeState(
  incoming: incomingView(
    id: id,
    stage: IncomingStage.folderQuestion,
    folder: folder,
  ),
);

NodeState _pairingRequest() => pairingState(
  pairing: view(role: PairingRole.receiver, phase: PairingPhase.comparing),
);

Future<(FakeAppController, FakeWindowHost)> _mount(
  WidgetTester tester, {
  NodeState state = _idle,
  String code = 'es',
  FakeWindowHost? host,
  Size size = _window,
}) async {
  FocusManager.instance.listenToApplicationLifecycleChangesIfSupported();
  tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
  resumeOnTearDown(tester);
  setWindow(tester, size);
  final controller = FakeAppController(state: state, languageCode: code);
  final window = host ?? FakeWindowHost();
  await tester.pumpWidget(NexusBridgesApp(controller, windowHost: window));
  await tester.pump();
  await tester.pump(const Duration(seconds: 2));
  window.calls.clear();
  controller.calls.clear();
  return (controller, window);
}

Finder _card(AppStrings strings) => find
    .ancestor(
      of: find.text(strings.incomingRequestTitle(senderName)),
      matching: find.byType(Card),
    )
    .first;

Future<void> _tapButton(
  WidgetTester tester,
  AppStrings strings,
  String label,
) async {
  await tester.tap(buttonIn(_card(strings), label), warnIfMissed: false);
  await tester.pump();
}

String? _focusedLabel() {
  final context = FocusManager.instance.primaryFocus?.context;
  if (context == null) return null;
  String? label;
  void visit(Element element) {
    final widget = element.widget;
    if (label == null && widget is Text) label = widget.data;
    if (label == null) element.visitChildren(visit);
  }

  (context as Element).visitChildren(visit);
  return label;
}

bool _neutralHasFocus() =>
    FocusManager.instance.primaryFocus?.debugLabel == 'neutral';

bool _focusInsideModal(WidgetTester tester) {
  final context = FocusManager.instance.primaryFocus?.context;
  if (context == null) return false;
  final route = ModalRoute.of(context);
  return route is NbModalRoute;
}

Future<void> _bringUp(WidgetTester tester) async {
  await goToLifecycle(tester, AppLifecycleState.inactive);
  await goToLifecycle(tester, AppLifecycleState.resumed);
}

Future<void> _tab(WidgetTester tester) async {
  await tester.sendKeyEvent(LogicalKeyboardKey.tab);
  await tester.pump();
}

Future<void> _escape(WidgetTester tester) async {
  await tester.sendKeyEvent(LogicalKeyboardKey.escape);
  await tester.pump();
}

void main() {
  group('E890 what brings the window (RF-529)', () {
    for (final state in const [
      AppLifecycleState.hidden,
      AppLifecycleState.inactive,
    ]) {
      testWidgets('in ${state.name} a stranger warning calls attention once', (
        tester,
      ) async {
        final (controller, host) = await _mount(tester);
        await goToLifecycle(tester, state);
        controller.emit(_warning());
        await tester.pump();
        expect(host.countOf('attention'), 1);
      });
    }

    testWidgets('in resumed it does not', (tester) async {
      final (controller, host) = await _mount(tester);
      controller.emit(_warning());
      await tester.pump();
      expect(host.calls, isNot(contains('attention')));
    });

    testWidgets('the same warning again does not call it twice', (
      tester,
    ) async {
      final (controller, host) = await _mount(tester);
      await goToLifecycle(tester, AppLifecycleState.hidden);
      controller.emit(_warning());
      await tester.pump();
      controller.emit(_warning());
      await tester.pump();
      expect(host.countOf('attention'), 1);
    });

    testWidgets('hiding with a warning open does not bring it back', (
      tester,
    ) async {
      final (controller, host) = await _mount(tester, state: _warning());
      await goToLifecycle(tester, AppLifecycleState.hidden);
      controller.emit(_warning());
      await tester.pump();
      expect(host.calls, isNot(contains('attention')));
    });

    testWidgets('the folder question after accepting calls it again', (
      tester,
    ) async {
      final (controller, host) = await _mount(tester);
      await goToLifecycle(tester, AppLifecycleState.hidden);
      controller.emit(_warning());
      await tester.pump();
      controller.emit(
        NodeState(incoming: incomingView(stage: IncomingStage.waitingData)),
      );
      await tester.pump();
      controller.emit(_folderQuestion('s1', _firstTime));
      await tester.pump();
      expect(host.countOf('attention'), 2);
    });

    testWidgets('the pairing request as receiver calls it', (tester) async {
      final (controller, host) = await _mount(tester);
      await goToLifecycle(tester, AppLifecycleState.hidden);
      controller.emit(_pairingRequest());
      await tester.pump();
      expect(host.countOf('attention'), 1);
    });

    final quiet = <String, NodeState>{
      'a reception from a device of mine': NodeState(
        incoming: incomingView(stage: IncomingStage.receiving),
      ),
      'a result': NodeState(lastReceived: resultView()),
      'a note': const NodeState(
        notices: [Notice(id: 1, kind: NoticeKind.changeNotSaved)],
      ),
      'the question of a new network': const NodeState(
        prompts: [NetworkPrompt('n1', 'Casa')],
      ),
      'a pairing as initiator': pairingState(
        pairing: view(
          role: PairingRole.initiator,
          phase: PairingPhase.comparing,
        ),
      ),
      'the question "is it yours?"': pairingState(questions: [_mine]),
    };

    for (final MapEntry(key: name, value: state) in quiet.entries) {
      testWidgets('$name does not call it', (tester) async {
        final (controller, host) = await _mount(tester);
        await goToLifecycle(tester, AppLifecycleState.hidden);
        controller.emit(state);
        await tester.pump();
        expect(host.calls, isNot(contains('attention')));
      });
    }

    testWidgets('with a picker open it does not call it', (tester) async {
      final (controller, host) = await _mount(tester);
      await goToLifecycle(tester, AppLifecycleState.inactive);
      controller.emit(NodeState(pickerOpen: true, incoming: incomingView()));
      await tester.pump();
      expect(host.calls, isNot(contains('attention')));
    });

    testWidgets('an attention that fails leaves the app working', (
      tester,
    ) async {
      final failing = FakeWindowHost()..attentionError = StateError('gone');
      final (controller, _) = await _mount(tester, host: failing);
      await goToLifecycle(tester, AppLifecycleState.hidden);
      controller.emit(_warning());
      await tester.pump();
      await tester.pump();
      expect(tester.takeException(), isNull);
      expect(failing.countOf('attention'), 1);
    });
  });

  group('the warning is seen when the window comes back (RF-529)', () {
    testWidgets('on inactive the card is there, disarmed', (tester) async {
      final es = stringsFor('es');
      final (controller, host) = await _mount(tester);
      await goToLifecycle(tester, AppLifecycleState.hidden);
      controller.emit(_warning());
      await tester.pump();
      expect(host.countOf('attention'), 1);
      await goToLifecycle(tester, AppLifecycleState.inactive);
      expect(_card(es), findsOneWidget);
      expect(isEnabled(tester, buttonIn(_card(es), es.acceptButton)), isFalse);
      expect(isEnabled(tester, buttonIn(_card(es), es.rejectButton)), isFalse);
      expect(tester.takeException(), isNull);
    });

    testWidgets('it is seen in a narrow window too', (tester) async {
      final es = stringsFor('es');
      final (controller, _) = await _mount(tester, size: const Size(640, 520));
      await goToLifecycle(tester, AppLifecycleState.hidden);
      controller.emit(_warning());
      await tester.pump();
      await goToLifecycle(tester, AppLifecycleState.inactive);
      expect(_card(es), findsOneWidget);
      expect(tester.getRect(_card(es)).top, lessThan(520));
    });

    testWidgets('the pairing request is on screen when it comes back', (
      tester,
    ) async {
      final (controller, _) = await _mount(tester);
      await goToLifecycle(tester, AppLifecycleState.hidden);
      controller.emit(_pairingRequest());
      await tester.pump();
      await goToLifecycle(tester, AppLifecycleState.inactive);
      await tester.pump(const Duration(milliseconds: 500));
      expect(dialog, findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });

  group('E891 nothing answers by accident (RF-530)', () {
    testWidgets('in inactive, pressing "Accept" does nothing', (tester) async {
      final es = stringsFor('es');
      final (controller, _) = await _mount(tester);
      await goToLifecycle(tester, AppLifecycleState.hidden);
      controller.emit(_warning());
      await tester.pump();
      await goToLifecycle(tester, AppLifecycleState.inactive);
      await tester.pump(const Duration(seconds: 3));
      await _tapButton(tester, es, es.acceptButton);
      expect(controller.calls, isEmpty);
    });

    testWidgets('pressing at t0 + 0.4 s does nothing and at t0 + 0.6 s it '
        'accepts', (tester) async {
      final es = stringsFor('es');
      final (controller, _) = await _mount(tester);
      await goToLifecycle(tester, AppLifecycleState.hidden);
      controller.emit(_warning());
      await tester.pump();
      await _bringUp(tester);
      await tester.pump(_beforeArmed);
      await _tapButton(tester, es, es.acceptButton);
      expect(controller.calls, isEmpty);
      await tester.pump(_afterArmed - _beforeArmed);
      await _tapButton(tester, es, es.acceptButton);
      expect(controller.calls, ['answerIncoming s1 true']);
    });

    testWidgets('no button of the warning has the focus when it shows', (
      tester,
    ) async {
      final es = stringsFor('es');
      final (controller, _) = await _mount(tester);
      await goToLifecycle(tester, AppLifecycleState.hidden);
      controller.emit(_warning());
      await tester.pump();
      await goToLifecycle(tester, AppLifecycleState.inactive);
      expect(_focusedLabel(), isNot(es.acceptButton));
      expect(_focusedLabel(), isNot(es.rejectButton));
    });

    testWidgets('a button focused before hiding does not get the focus back: '
        'the neutral node has it, and Enter and Space answer nothing', (
      tester,
    ) async {
      final es = stringsFor('es');
      final (controller, host) = await _mount(tester, state: _warning('old'));
      Focus.of(tester.element(find.text(es.acceptButton))).requestFocus();
      await tester.pump();
      expect(_focusedLabel(), es.acceptButton);

      await goToLifecycle(tester, AppLifecycleState.hidden);
      controller.emit(_warning('new'));
      await tester.pump();
      expect(host.countOf('attention'), 1);
      await _bringUp(tester);
      expect(_neutralHasFocus(), isTrue);
      expect(_focusedLabel(), isNot(es.acceptButton));

      await tester.pump(_afterArmed);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.sendKeyEvent(LogicalKeyboardKey.space);
      await tester.pump();
      expect(controller.calls, isEmpty);
    }, variant: _windows);

    testWidgets('the same with the window behind others (inactive)', (
      tester,
    ) async {
      final es = stringsFor('es');
      final (controller, host) = await _mount(tester, state: _warning('old'));
      Focus.of(tester.element(find.text(es.acceptButton))).requestFocus();
      await tester.pump();

      await goToLifecycle(tester, AppLifecycleState.inactive);
      controller.emit(_warning('new'));
      await tester.pump();
      expect(host.countOf('attention'), 1);
      await goToLifecycle(tester, AppLifecycleState.resumed);
      expect(_neutralHasFocus(), isTrue);
      await tester.pump(_afterArmed);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.sendKeyEvent(LogicalKeyboardKey.space);
      await tester.pump();
      expect(controller.calls, isEmpty);
    }, variant: _windows);

    testWidgets('with the window in front the focus also leaves the button', (
      tester,
    ) async {
      final es = stringsFor('es');
      final (controller, host) = await _mount(tester, state: _warning('old'));
      Focus.of(tester.element(find.text(es.acceptButton))).requestFocus();
      await tester.pump();
      controller.emit(_warning('new'));
      await tester.pump();
      expect(host.calls, isNot(contains('attention')));
      expect(_neutralHasFocus(), isTrue);
    }, variant: _windows);

    testWidgets('Esc in a question dialog at t0 + 0.3 s does not close it and '
        'at t0 + 0.6 s it does', (tester) async {
      final (controller, _) = await _mount(tester);
      await goToLifecycle(tester, AppLifecycleState.hidden);
      controller.emit(pairingState(questions: [_mine]));
      await tester.pump();
      await _bringUp(tester);
      await tester.pump(_early);
      await _escape(tester);
      expect(controller.calls, isEmpty);
      await tester.pump(_afterArmed - _early);
      await _escape(tester);
      expect(controller.calls.join(), contains('answerMine'));
    }, variant: _windows);

    testWidgets('a dialog open when a warning arrives keeps listening to Esc', (
      tester,
    ) async {
      final (controller, host) = await _mount(
        tester,
        state: pairingState(questions: [_mine]),
      );
      await goToLifecycle(tester, AppLifecycleState.hidden);
      controller.emit(NodeState(questions: [_mine], incoming: incomingView()));
      await tester.pump();
      expect(host.countOf('attention'), 1);
      await _bringUp(tester);
      await tester.pump(_afterArmed);
      expect(_focusInsideModal(tester), isTrue);
      await _escape(tester);
      expect(controller.calls.join(), contains('answerMine'));
    }, variant: _windows);

    testWidgets('a pairing request with the window in front leaves the focus '
        'inside its dialog', (tester) async {
      final (controller, _) = await _mount(tester);
      controller.emit(_pairingRequest());
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));
      expect(_neutralHasFocus(), isFalse);
      expect(_focusInsideModal(tester), isTrue);
    }, variant: _windows);
  });

  group('E894 a warning with Settings open (RF-505, RF-529)', () {
    testWidgets('hidden: Settings closes and attention is called once', (
      tester,
    ) async {
      final (controller, host) = await _mount(tester);
      await openSettings(tester, stringsFor('es'));
      expect(settingsScreen, findsOneWidget);
      await goToLifecycle(tester, AppLifecycleState.hidden);
      controller.emit(_warning());
      await tester.pump();
      expect(host.countOf('attention'), 1);
      await goToLifecycle(tester, AppLifecycleState.inactive);
      await tester.pump(const Duration(seconds: 1));
      expect(settingsScreen, findsNothing);
      expect(_card(stringsFor('es')), findsOneWidget);
    });
  });

  group('E895 inside the card the safe button goes first (RF-530)', () {
    Future<List<String?>> tabThrough(WidgetTester tester, int stops) async {
      final labels = <String?>[];
      for (var i = 0; i < stops; i++) {
        await _tab(tester);
        labels.add(_focusedLabel());
      }
      return labels;
    }

    testWidgets('warning: Reject is reached before Accept', (tester) async {
      final es = stringsFor('es');
      final (controller, _) = await _mount(tester);
      await goToLifecycle(tester, AppLifecycleState.hidden);
      controller.emit(_warning());
      await tester.pump();
      await _bringUp(tester);
      await tester.pump(_afterArmed);
      final labels = await tabThrough(tester, 30);
      final reject = labels.indexOf(es.rejectButton);
      final accept = labels.indexOf(es.acceptButton);
      expect(reject, isNonNegative);
      expect(accept, reject + 1);
    }, variant: _windows);

    testWidgets('folder question: Cancel is reached before the others', (
      tester,
    ) async {
      final es = stringsFor('es');
      final (controller, _) = await _mount(tester);
      await goToLifecycle(tester, AppLifecycleState.hidden);
      controller.emit(_folderQuestion('s1', _firstTime));
      await tester.pump();
      await _bringUp(tester);
      await tester.pump(_afterArmed);
      final labels = await tabThrough(tester, 30);
      final cancel = labels.indexOf(es.cancelButton);
      expect(cancel, isNonNegative);
      expect(labels[cancel + 1], es.chooseOtherFolderButton);
      expect(labels[cancel + 2], es.useThisFolderButton);
    }, variant: _windows);

    testWidgets('folder with a caution: Choose another before Use anyway', (
      tester,
    ) async {
      final es = stringsFor('es');
      final (controller, _) = await _mount(tester);
      await goToLifecycle(tester, AppLifecycleState.hidden);
      controller.emit(_folderQuestion('s1', _caution));
      await tester.pump();
      await _bringUp(tester);
      await tester.pump(_afterArmed);
      final labels = await tabThrough(tester, 30);
      final other = labels.indexOf(es.chooseOtherFolderButton);
      expect(other, isNonNegative);
      expect(labels[other + 1], es.useAnywayButton);
    }, variant: _windows);
  });

  group('E896 the initial state of ForegroundArming (RF-530)', () {
    testWidgets('resumed: it arms at 500 ms', (tester) async {
      final arming = ForegroundArming();
      addTearDown(arming.dispose);
      expect(arming.value, isFalse);
      await tester.pump(dialogActivationDelay - _lastMs);
      expect(arming.value, isFalse);
      await tester.pump(_lastMs);
      expect(arming.value, isTrue);
    });

    for (final state in const [
      AppLifecycleState.inactive,
      AppLifecycleState.hidden,
    ]) {
      testWidgets('${state.name}: it does not arm until 500 ms after resumed', (
        tester,
      ) async {
        resumeOnTearDown(tester);
        await goToLifecycle(tester, state);
        final arming = ForegroundArming();
        addTearDown(arming.dispose);
        await tester.pump(const Duration(seconds: 3));
        expect(arming.value, isFalse);
        await goToLifecycle(tester, AppLifecycleState.resumed);
        await tester.pump(dialogActivationDelay - _lastMs);
        expect(arming.value, isFalse);
        await tester.pump(_lastMs);
        expect(arming.value, isTrue);
      });
    }

    testWidgets('losing the foreground disarms at once', (tester) async {
      resumeOnTearDown(tester);
      final arming = ForegroundArming();
      addTearDown(arming.dispose);
      await tester.pump(const Duration(seconds: 1));
      expect(arming.value, isTrue);
      await goToLifecycle(tester, AppLifecycleState.inactive);
      expect(arming.value, isFalse);
    });

    testWidgets('leaving before the 500 ms starts the count again', (
      tester,
    ) async {
      resumeOnTearDown(tester);
      await goToLifecycle(tester, AppLifecycleState.inactive);
      final arming = ForegroundArming();
      addTearDown(arming.dispose);
      await goToLifecycle(tester, AppLifecycleState.resumed);
      await tester.pump(const Duration(milliseconds: 400));
      await goToLifecycle(tester, AppLifecycleState.inactive);
      await tester.pump(const Duration(seconds: 1));
      expect(arming.value, isFalse);
      await goToLifecycle(tester, AppLifecycleState.resumed);
      await tester.pump(const Duration(milliseconds: 400));
      expect(arming.value, isFalse);
      await tester.pump(const Duration(milliseconds: 101));
      expect(arming.value, isTrue);
    });
  });

  group('E897 other layers close with the tick (RF-529)', () {
    final fingerprint = fingerprintOf('A1');
    final withDevice = NodeState(
      entries: [
        entry(
          fingerprint: fingerprint,
          name: 'PC principal',
          paired: true,
          mine: true,
        ),
      ],
    );

    NodeState withWarning() =>
        NodeState(entries: withDevice.entries, incoming: incomingView());

    testWidgets('an open RowMenu closes without calling any action', (
      tester,
    ) async {
      final es = stringsFor('es');
      final (controller, _) = await _mount(tester, state: withDevice);
      final trigger = find.descendant(
        of: find.byKey(ValueKey(fingerprint)),
        matching: find.byTooltip(es.moreOptions),
      );
      await tester.tap(trigger);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      final panel = find.byKey(const ValueKey('row-menu-panel'));
      expect(panel, findsOneWidget);
      controller.calls.clear();
      controller.emit(withWarning());
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(panel, findsNothing);
      expect(controller.calls, isEmpty);
    });

    testWidgets('an open popover closes without calling any action', (
      tester,
    ) async {
      final (controller, _) = await _mount(tester, state: withDevice);
      final diagram = find.byType(FlowDiagram);
      expect(diagram, findsOneWidget);
      final popover = find.descendant(of: diagram, matching: find.byType(Card));
      final zones = find.descendant(
        of: diagram,
        matching: find.byType(MouseRegion),
      );
      for (final element in zones.evaluate().toList()) {
        if (popover.evaluate().isNotEmpty) break;
        await tester.tapAt(tester.getCenter(find.byWidget(element.widget)));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));
      }
      expect(popover, findsOneWidget);
      controller.calls.clear();
      controller.emit(withWarning());
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(popover, findsNothing);
      expect(controller.calls, isEmpty);
    });
  });

  group('E899 tap on the backdrop waits for the arming (RF-530)', () {
    testWidgets('tap at t0 + 0.3 s does not close it and at t0 + 0.6 s it '
        'does', (tester) async {
      final (controller, _) = await _mount(tester);
      await goToLifecycle(tester, AppLifecycleState.hidden);
      controller.emit(pairingState(questions: [_mine]));
      await tester.pump();
      await _bringUp(tester);
      await tester.pump(_early);
      await tester.tapAt(_outside);
      await tester.pump();
      expect(controller.calls, isEmpty);
      await tester.pump(_afterArmed - _early);
      await tester.tapAt(_outside);
      await tester.pump();
      expect(controller.calls.join(), contains('answerMine'));
    });

    testWidgets('with the window long in front a dialog closes at once', (
      tester,
    ) async {
      final (controller, _) = await _mount(tester);
      controller.emit(pairingState(questions: [_mine]));
      await tester.pump();
      await tester.tapAt(_outside);
      await tester.pump();
      expect(controller.calls.join(), contains('answerMine'));
    });

    testWidgets('Esc with the window long in front closes at once', (
      tester,
    ) async {
      final (controller, _) = await _mount(tester);
      controller.emit(pairingState(questions: [_mine]));
      await tester.pump();
      await tester.pump();
      await _escape(tester);
      expect(controller.calls.join(), contains('answerMine'));
    });

    testWidgets('in inactive neither Esc nor the backdrop close it', (
      tester,
    ) async {
      final (controller, _) = await _mount(
        tester,
        state: pairingState(questions: [_mine]),
      );
      await goToLifecycle(tester, AppLifecycleState.inactive);
      await tester.pump(const Duration(seconds: 2));
      await _escape(tester);
      await tester.tapAt(_outside);
      await tester.pump();
      expect(controller.calls, isEmpty);
    });
  });
}
