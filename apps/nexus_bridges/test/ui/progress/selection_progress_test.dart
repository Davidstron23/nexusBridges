import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nexus_bridges/src/l10n/app_strings.dart';
import 'package:nexus_bridges/src/ui/activity_cards.dart';
import 'package:nexus_bridges/src/ui/diagram/flow_diagram.dart';
import 'package:nexus_bridges/src/ui/diagram/flow_painter.dart';
import 'package:nexus_bridges/src/ui/diagram/flow_scene.dart';
import 'package:nexus_bridges/src/ui/format.dart';
import 'package:nexus_bridges/src/ui/icons/file_icon.dart';
import 'package:nexus_bridges/src/ui/progress/selection_progress_painter.dart';
import 'package:nexus_bridges/src/ui/queue_card.dart';
import 'package:nexus_bridges/src/ui/theme/app_theme.dart';
import 'package:nexus_bridges/src/ui/theme/components.dart';
import 'package:nexus_bridges/src/ui/theme/tokens.dart';
import 'package:nexus_bridges_core/nexus_bridges_core.dart';

import '../fake_app_controller.dart';
import '../transfer_fixtures.dart';

const Duration _frame = Duration(milliseconds: 16);
const Size _window = Size(1000, 720);

final DeviceEntry _peer = DeviceEntry(
  fingerprint: senderFingerprint,
  displayName: senderName,
  deviceType: DeviceType.desktop,
  visible: true,
  paired: true,
  mine: true,
  ignored: false,
  mismatch: false,
  possiblyReplaces: null,
);

QueueItemView _item(
  String id,
  String name, {
  QueueItemState state = QueueItemState.pending,
  bool folder = false,
  TransferOutcome? outcome,
}) {
  return QueueItemView(
    id: id,
    name: name,
    isFolder: folder,
    isArchive: name.endsWith('.zip'),
    state: state,
    outcome: outcome,
  );
}

SendQueuesView _queues({
  bool finished = false,
  int selectionId = 1,
  List<QueueItemView>? loose,
}) {
  final items =
      loose ??
      [
        _item(
          'l1',
          'acta.pdf',
          state: QueueItemState.done,
          outcome: TransferOutcome.saved,
        ),
        _item('l2', 'informe.xlsx', state: QueueItemState.inProgress),
      ];
  return SendQueuesView(
    selectionId: selectionId,
    peerFingerprint: senderFingerprint,
    peerName: senderName,
    loose: items,
    bundles: [_item('b1', 'proyecto', folder: true)],
    finished: finished,
    delivered: finished ? items.length + 1 : 1,
    total: items.length + 1,
    completedBytes: 0,
    pendingKnownBytes: 0,
    currentProbeSize: null,
  );
}

SelectionProgress _selection(
  int done,
  int total, {
  int id = 1,
  bool finished = false,
  String? name = 'informe.xlsx',
  bool folder = false,
}) {
  return SelectionProgress(
    selectionId: id,
    doneBytes: done,
    totalBytes: total,
    currentName: name,
    currentIsFolder: folder,
    finished: finished,
  );
}

NodeState _state({
  SendQueuesView? queues,
  OutgoingTransferView? outgoing,
  IncomingTransferView? incoming,
  SelectionProgress? selection,
}) {
  return NodeState(
    entries: [_peer],
    queues: queues,
    outgoing: outgoing,
    incoming: incoming,
    selectionProgress: selection,
    transferInProgress: queues != null && !queues.finished || outgoing != null,
    deviceName: 'Main PC',
    fingerprint: 'ABCDEF0123456789',
  );
}

OutgoingTransferView _uploading({
  String fileName = 'informe.xlsx',
  bool folder = false,
  OutgoingPhase phase = OutgoingPhase.uploading,
  int sent = 512,
}) {
  return OutgoingTransferView(
    peerFingerprint: senderFingerprint,
    peerName: senderName,
    fileName: fileName,
    size: 2048,
    isProgram: false,
    phase: phase,
    sentBytes: sent,
    cancelling: false,
    isFolder: folder,
  );
}

final class _Host {
  _Host(NodeState state) : state = ValueNotifier<NodeState>(state);

  final ValueNotifier<NodeState> state;
  final ValueNotifier<String?> hovered = ValueNotifier<String?>(null);
  final FakeAppController controller = FakeAppController();
}

Widget _app(_Host host, {String code = 'en', bool reduceMotion = false}) {
  return MaterialApp(
    debugShowCheckedModeBanner: false,
    locale: Locale(code),
    supportedLocales: const [Locale('en'), Locale('es')],
    localizationsDelegates: const [
      AppStringsDelegate(),
      GlobalMaterialLocalizations.delegate,
      GlobalWidgetsLocalizations.delegate,
      GlobalCupertinoLocalizations.delegate,
    ],
    theme: buildTheme(Brightness.light),
    themeAnimationDuration: Duration.zero,
    builder: (context, child) => MediaQuery(
      data: MediaQuery.of(context).copyWith(disableAnimations: reduceMotion),
      child: child!,
    ),
    home: Scaffold(
      body: ValueListenableBuilder<NodeState>(
        valueListenable: host.state,
        builder: (context, state, _) => SelectionProgressScope(
          state: state,
          child: Row(
            children: [
              SizedBox(
                width: 540,
                height: 480,
                child: FlowDiagram(
                  state: state,
                  hovered: host.hovered,
                  onSendFiles: (_) {},
                  onSendFolders: (_) {},
                  onShowDevices: () {},
                ),
              ),
              SizedBox(
                width: 420,
                child: SingleChildScrollView(
                  child: ActivityPanel(
                    controller: host.controller,
                    state: state,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    ),
  );
}

Future<_Host> _mount(
  WidgetTester tester,
  NodeState state, {
  String code = 'en',
  bool reduceMotion = false,
}) async {
  setWindow(tester, _window);
  final host = _Host(state);
  addTearDown(host.state.dispose);
  addTearDown(host.hovered.dispose);
  await tester.pumpWidget(_app(host, code: code, reduceMotion: reduceMotion));
  await tester.pump();
  return host;
}

Future<void> _frames(WidgetTester tester, int count) async {
  for (var i = 0; i < count; i++) {
    await tester.pump(_frame);
  }
}

FlowPainter _painter(WidgetTester tester) => tester
    .widgetList<CustomPaint>(
      find.descendant(
        of: find.byType(FlowDiagram),
        matching: find.byType(CustomPaint),
      ),
    )
    .map((paint) => paint.foregroundPainter)
    .whereType<FlowPainter>()
    .single;

double _line(WidgetTester tester) {
  final painter = _painter(tester);
  return painter.progressOf(painter.scene.peers.single.link);
}

Finder _barOf(Finder scope) =>
    find.descendant(of: scope, matching: find.byType(NbProgressBar));

double _bar(WidgetTester tester, Finder scope) =>
    tester.widget<NbProgressBar>(_barOf(scope).first).value;

final Finder _selectionBar = find.byType(SelectionBar);
final Finder _queueCard = find.byType(QueueCard);

String _percentShown(WidgetTester tester) {
  final texts = find.descendant(of: _selectionBar, matching: find.byType(Text));
  return tester.widget<Text>(texts.first).data ?? '';
}

void _expectMonotone(List<double> values) {
  for (var i = 1; i < values.length; i++) {
    expect(values[i], greaterThanOrEqualTo(values[i - 1]), reason: 'step $i');
  }
}

void main() {
  for (final code in languageCodes) {
    final strings = stringsFor(code);

    group('[$code] E578 the line and the bar show the same value', () {
      testWidgets('a queue: the line of the diagram and the bar of the card '
          'give the value of the estimator, step by step', (tester) async {
        await _mount(
          tester,
          _state(
            queues: _queues(),
            outgoing: _uploading(sent: 100),
            selection: _selection(2000, 4000),
          ),
          code: code,
        );

        final values = <double>[];
        for (var i = 0; i < 70; i++) {
          await tester.pump(_frame);
          final bar = _bar(tester, _selectionBar);
          expect(_line(tester), bar, reason: 'frame $i');
          values.add(bar);
        }
        _expectMonotone(values);
        expect(values.last, greaterThan(0.2));
        expect(values.last, lessThanOrEqualTo(0.52));
        expect(values.last, isNot(closeTo(100 / 2048, 0.05)));
        final percent = formatPercent((values.last * 100).floor(), code);
        expect(_percentShown(tester), percent);
      });

      testWidgets('the total changes while a folder is measured: the value '
          'and the line never go back', (tester) async {
        final host = await _mount(
          tester,
          _state(
            queues: _queues(),
            outgoing: _uploading(),
            selection: _selection(2000, 4000),
          ),
          code: code,
        );
        final values = <double>[];
        final lines = <double>[];
        void record() {
          values.add(_bar(tester, _selectionBar));
          lines.add(_line(tester));
        }

        for (var i = 0; i < 40; i++) {
          await tester.pump(_frame);
          record();
        }
        host.state.value = _state(
          queues: _queues(),
          outgoing: _uploading(),
          selection: _selection(2600, 400000),
        );
        for (var i = 0; i < 60; i++) {
          await tester.pump(_frame);
          record();
        }
        host.state.value = _state(
          queues: _queues(),
          outgoing: _uploading(),
          selection: _selection(2800, 3000),
        );
        for (var i = 0; i < 60; i++) {
          await tester.pump(_frame);
          record();
        }
        _expectMonotone(values);
        _expectMonotone(lines);
        expect(values, lines);
      });

      testWidgets('a single file (no queues) also uses the estimator in the '
          'card and in the line', (tester) async {
        await _mount(
          tester,
          _state(
            outgoing: _uploading(),
            selection: _selection(1500, 3000, id: 4),
          ),
          code: code,
        );
        final card = find.byKey(const ValueKey('activity-outgoing'));
        final values = <double>[];
        for (var i = 0; i < 50; i++) {
          await tester.pump(_frame);
          final bar = _bar(tester, card);
          expect(_line(tester), bar);
          values.add(bar);
        }
        _expectMonotone(values);
        expect(values.last, greaterThan(0.1));
        expect(values.last, lessThanOrEqualTo(0.52));
      });

      testWidgets('a reception: the card and the line use the estimator on '
          'receivedBytes and size', (tester) async {
        await _mount(
          tester,
          _state(
            incoming: incomingView(
              stage: IncomingStage.receiving,
              size: 1000,
              received: 400,
            ),
          ),
          code: code,
        );
        final card = find.byKey(const ValueKey('activity-incoming'));
        final values = <double>[];
        for (var i = 0; i < 50; i++) {
          await tester.pump(_frame);
          final bar = _bar(tester, card);
          expect(_line(tester), bar);
          values.add(bar);
        }
        _expectMonotone(values);
        expect(values.last, greaterThan(0.1));
        expect(values.last, lessThanOrEqualTo(0.42));
        expect(_painter(tester).scene.peers.single.link.towardsHub, isTrue);
      });

      testWidgets('the line stays on between the items of a queue, with the '
          'same value as the bar', (tester) async {
        final host = await _mount(
          tester,
          _state(
            queues: _queues(),
            outgoing: _uploading(),
            selection: _selection(1000, 4000),
          ),
          code: code,
        );
        await _frames(tester, 30);
        host.state.value = _state(
          queues: _queues(),
          selection: _selection(1500, 4000),
        );
        await _frames(tester, 5);
        final link = _painter(tester).scene.peers.single.link;
        expect(link.state, LinkState.active);
        expect(link.tracked, isTrue);
        expect(_line(tester), _bar(tester, _selectionBar));
        expect(_bar(tester, _selectionBar), greaterThan(0));
      });
    });

    group('[$code] E578 reduced motion paints the raw value', () {
      testWidgets('without animation, and it never goes back when the total '
          'grows', (tester) async {
        final host = await _mount(
          tester,
          _state(
            queues: _queues(),
            outgoing: _uploading(),
            selection: _selection(500, 1000),
          ),
          code: code,
          reduceMotion: true,
        );
        expect(_bar(tester, _selectionBar), 0.5);
        expect(_line(tester), 0.5);
        expect(tester.binding.transientCallbackCount, 0);
        await tester.pump(const Duration(seconds: 1));
        expect(_bar(tester, _selectionBar), 0.5);

        host.state.value = _state(
          queues: _queues(),
          outgoing: _uploading(),
          selection: _selection(500, 5000),
        );
        await tester.pump();
        expect(_bar(tester, _selectionBar), 0.5);
        expect(_line(tester), 0.5);

        host.state.value = _state(
          queues: _queues(),
          outgoing: _uploading(),
          selection: _selection(2600, 5000),
        );
        await tester.pump();
        expect(_bar(tester, _selectionBar), closeTo(0.52, 1e-9));
        expect(_line(tester), closeTo(0.52, 1e-9));
        await tester.pump(const Duration(seconds: 2));
        expect(tester.binding.transientCallbackCount, 0);

        host.state.value = _state(
          queues: _queues(finished: true),
          selection: _selection(5000, 5000, finished: true),
        );
        await tester.pump();
        expect(_selectionBar, findsNothing);
        expect(textIn(_queueCard, strings.toPeer(senderName)), findsOneWidget);
      });

      testWidgets('a new selection starts again from the beginning', (
        tester,
      ) async {
        final host = await _mount(
          tester,
          _state(
            queues: _queues(),
            outgoing: _uploading(),
            selection: _selection(800, 1000),
          ),
          code: code,
          reduceMotion: true,
        );
        expect(_bar(tester, _selectionBar), 0.8);
        host.state.value = _state(
          queues: _queues(selectionId: 2),
          outgoing: _uploading(),
          selection: _selection(100, 1000, id: 2),
        );
        await tester.pump();
        expect(_bar(tester, _selectionBar), 0.1);
      });
    });

    group('[$code] E575 the glide at the end of a queue', () {
      testWidgets('the bar stays while it glides to 100 % and then gives way '
          'to the summary', (tester) async {
        final host = await _mount(
          tester,
          _state(
            queues: _queues(),
            outgoing: _uploading(),
            selection: _selection(2000, 4000),
          ),
          code: code,
        );
        await _frames(tester, 40);
        final before = _bar(tester, _selectionBar);
        expect(before, greaterThan(0.1));

        host.state.value = _state(
          queues: _queues(finished: true),
          selection: _selection(4000, 4000, finished: true),
        );
        await tester.pump();
        expect(_selectionBar, findsOneWidget);
        expect(textIn(_queueCard, strings.toPeer(senderName)), findsNothing);

        final values = <double>[before];
        for (var i = 0; i < 30; i++) {
          await tester.pump(_frame);
          if (_selectionBar.evaluate().isEmpty) break;
          values.add(_bar(tester, _selectionBar));
        }
        _expectMonotone(values);
        expect(values.last, greaterThan(0.97));
        await _frames(tester, 10);
        expect(_selectionBar, findsNothing);
        expect(textIn(_queueCard, strings.toPeer(senderName)), findsOneWidget);
        expect(tester.binding.transientCallbackCount, 0);
      });
    });

    group('[$code] E578 the travelling icon fades when the type changes', () {
      testWidgets('from a file to a folder it fades for 400 ms without '
          'moving', (tester) async {
        final host = await _mount(
          tester,
          _state(
            queues: _queues(),
            outgoing: _uploading(fileName: 'informe.pdf'),
            selection: _selection(1000, 4000, name: 'informe.pdf'),
          ),
          code: code,
        );
        await _frames(tester, 5);
        expect(_painter(tester).iconFrom, isEmpty);

        host.state.value = _state(
          queues: _queues(),
          outgoing: _uploading(fileName: 'proyecto', folder: true),
          selection: _selection(1100, 4000, name: 'proyecto', folder: true),
        );
        await tester.pump();
        var painter = _painter(tester);
        expect(painter.iconFrom, {
          senderFingerprint: const TravelIcon.file(FileKind.pdf),
        });
        expect(
          painter.scene.peers.single.link.travelIcon,
          const TravelIcon.folder(),
        );
        expect(painter.iconFade!.value, lessThan(0.1));

        await tester.pump(const Duration(milliseconds: 200));
        painter = _painter(tester);
        expect(painter.iconFade!.value, closeTo(0.5, 0.1));

        await tester.pump(const Duration(milliseconds: 300));
        expect(_painter(tester).iconFade!.value, 1);
      });

      testWidgets('a change between two PDFs does not fade', (tester) async {
        final host = await _mount(
          tester,
          _state(
            queues: _queues(),
            outgoing: _uploading(fileName: 'a.pdf'),
            selection: _selection(1000, 4000, name: 'a.pdf'),
          ),
          code: code,
        );
        host.state.value = _state(
          queues: _queues(),
          outgoing: _uploading(fileName: 'b.pdf'),
          selection: _selection(1100, 4000, name: 'b.pdf'),
        );
        await tester.pump();
        expect(_painter(tester).iconFrom, isEmpty);
      });

      testWidgets('with reduced motion there is no fade left to run', (
        tester,
      ) async {
        final host = await _mount(
          tester,
          _state(
            queues: _queues(),
            outgoing: _uploading(fileName: 'informe.pdf'),
            selection: _selection(1000, 4000, name: 'informe.pdf'),
          ),
          code: code,
          reduceMotion: true,
        );
        host.state.value = _state(
          queues: _queues(),
          outgoing: _uploading(fileName: 'proyecto', folder: true),
          selection: _selection(1100, 4000, name: 'proyecto', folder: true),
        );
        await tester.pump();
        expect(_painter(tester).iconFade!.value, 1);
        expect(tester.binding.transientCallbackCount, 0);
      });
    });
  }

  group('E578 the painter draws both icons while it fades', () {
    FlowPainter painterFor(
      NodeState state, {
      required double fade,
      required Map<String, TravelIcon> from,
    }) {
      final scene = buildFlowScene(
        state: state,
        strings: stringsFor('en'),
        size: const Size(540, 480),
      );
      return FlowPainter(
        scene: scene,
        colors: NbColors.light,
        clock: const AlwaysStoppedAnimation<double>(0.2),
        hover: const AlwaysStoppedAnimation<double>(0),
        reduceMotion: false,
        textDirection: TextDirection.ltr,
        iconFade: AlwaysStoppedAnimation<double>(fade),
        iconFrom: from,
      );
    }

    int layers(FlowPainter painter) {
      final canvas = TestRecordingCanvas();
      painter.paint(canvas, const Size(540, 480));
      return canvas.invocations
          .where((call) => call.invocation.memberName == #saveLayer)
          .length;
    }

    final state = _state(
      queues: _queues(),
      outgoing: _uploading(fileName: 'proyecto', folder: true),
      selection: _selection(1000, 4000, name: 'proyecto', folder: true),
    );

    test('two layers in the middle of the fade, none before or after', () {
      final from = {senderFingerprint: const TravelIcon.file(FileKind.pdf)};
      expect(layers(painterFor(state, fade: 0.5, from: from)), 2);
      expect(layers(painterFor(state, fade: 1, from: from)), 0);
      expect(layers(painterFor(state, fade: 0.5, from: const {})), 0);
      expect(
        layers(
          painterFor(
            state,
            fade: 0.5,
            from: {senderFingerprint: const TravelIcon.folder()},
          ),
        ),
        0,
      );
    });
  });

  group('E578 linkFor keeps the selection between the items', () {
    LinkView link(NodeState state) => linkFor(state, senderFingerprint);

    test('between two items, with bytes done, the line stays active', () {
      final view = link(
        _state(queues: _queues(), selection: _selection(1000, 4000)),
      );
      expect(view.state, LinkState.active);
      expect(view.tracked, isTrue);
      expect(view.progress, 0.25);
      expect(view.fileName, 'informe.xlsx');
    });

    test('the type of the current item comes from the selection', () {
      final view = link(
        _state(
          queues: _queues(),
          selection: _selection(1000, 4000, name: 'proyecto', folder: true),
        ),
      );
      expect(view.isFolder, isTrue);
      expect(view.travelIcon, const TravelIcon.folder());
    });

    test('with nothing done yet, nothing is drawn between items', () {
      final view = link(
        _state(queues: _queues(), selection: _selection(0, 4000)),
      );
      expect(view.state, LinkState.idle);
    });

    test('the next item preparing or waiting keeps the progress line', () {
      for (final phase in [
        OutgoingPhase.preparing,
        OutgoingPhase.requesting,
        OutgoingPhase.waiting,
      ]) {
        final view = link(
          _state(
            queues: _queues(),
            outgoing: _uploading(phase: phase),
            selection: _selection(1000, 4000),
          ),
        );
        expect(view.state, LinkState.active, reason: '$phase');
        expect(view.tracked, isTrue);
        expect(view.progress, 0.25);
      }
    });

    test('the first item waiting for the answer still shows the dashes', () {
      final view = link(
        _state(
          queues: _queues(),
          outgoing: _uploading(phase: OutgoingPhase.waiting),
          selection: _selection(0, 4000),
        ),
      );
      expect(view.state, LinkState.waiting);
    });

    test('a finished queue or another selection is not carried', () {
      expect(
        link(
          _state(
            queues: _queues(finished: true),
            selection: _selection(4000, 4000, finished: true),
          ),
        ).state,
        LinkState.idle,
      );
      expect(
        link(
          _state(
            queues: _queues(selectionId: 2),
            selection: _selection(1000, 4000),
          ),
        ).state,
        LinkState.idle,
      );
    });

    test('uploading with a selection is tracked and follows the selection '
        'fraction', () {
      final view = link(
        _state(
          queues: _queues(),
          outgoing: _uploading(),
          selection: _selection(1000, 4000),
        ),
      );
      expect(view.tracked, isTrue);
      expect(view.progress, 0.25);
      final raw = link(_state(outgoing: _uploading()));
      expect(raw.tracked, isFalse);
      expect(raw.progress, 0.25);
    });

    test('verifying an item does not jump to 100 % when a selection '
        'exists', () {
      final view = link(
        _state(
          queues: _queues(),
          outgoing: _uploading(phase: OutgoingPhase.verifying),
          selection: _selection(1000, 4000),
        ),
      );
      expect(view.progress, 0.25);
      final raw = link(
        _state(outgoing: _uploading(phase: OutgoingPhase.verifying)),
      );
      expect(raw.progress, 1);
    });

    test('a folder arriving has the folder icon', () {
      final view = link(
        _state(
          incoming: IncomingTransferView(
            sessionId: 's1',
            peerFingerprint: senderFingerprint,
            peerName: senderName,
            fileName: 'proyecto',
            size: 1000,
            isProgram: false,
            stage: IncomingStage.receiving,
            isFolder: true,
          ),
        ),
      );
      expect(view.isFolder, isTrue);
      expect(view.tracked, isTrue);
    });
  });

  group('ProgressTracker with an injected clock', () {
    Duration now = Duration.zero;
    ProgressTracker create() {
      now = Duration.zero;
      return ProgressTracker(clock: () => now);
    }

    void step(ProgressTracker tracker, [Duration by = _frame]) {
      now += by;
      tracker.tick();
    }

    test('the outgoing value rises with ticks and rests at the target', () {
      final tracker = create();
      expect(tracker.atRest, isTrue);
      tracker.update(_state(queues: _queues(), selection: _selection(0, 100)));
      step(tracker);
      tracker.update(_state(queues: _queues(), selection: _selection(50, 100)));
      expect(tracker.atRest, isFalse);
      var before = 0.0;
      for (var i = 0; i < 800; i++) {
        step(tracker);
        final value = tracker.valueOf(ProgressTrack.outgoing);
        expect(value, greaterThanOrEqualTo(before));
        before = value;
      }
      expect(before, closeTo(0.5, 0.02));
      expect(tracker.atRest, isTrue);
      expect(tracker.glidingOf(ProgressTrack.outgoing), isFalse);
    });

    test('ticks notify the listeners, updates do not', () {
      final tracker = create();
      var notified = 0;
      tracker.addListener(() => notified++);
      tracker.update(_state(queues: _queues(), selection: _selection(10, 100)));
      expect(notified, 0);
      step(tracker);
      expect(notified, 1);
    });

    test('with reduced motion it gives the steady value and never moves', () {
      final tracker = create()..reduceMotion = true;
      tracker.update(
        _state(queues: _queues(), selection: _selection(500, 1000)),
      );
      expect(tracker.atRest, isTrue);
      expect(tracker.valueOf(ProgressTrack.outgoing), 0.5);
      tracker.update(
        _state(queues: _queues(), selection: _selection(500, 9000)),
      );
      expect(tracker.valueOf(ProgressTrack.outgoing), 0.5);
      tracker.update(
        _state(
          queues: _queues(finished: true),
          selection: _selection(9000, 9000, finished: true),
        ),
      );
      expect(tracker.valueOf(ProgressTrack.outgoing), 1);
      expect(tracker.glidingOf(ProgressTrack.outgoing), isFalse);
    });

    test('a finished selection glides to 1 and then rests', () {
      final tracker = create();
      tracker.update(_state(queues: _queues(), selection: _selection(10, 100)));
      for (var i = 0; i < 30; i++) {
        step(tracker);
      }
      tracker.update(
        _state(
          queues: _queues(finished: true),
          selection: _selection(100, 100, finished: true),
        ),
      );
      expect(tracker.glidingOf(ProgressTrack.outgoing), isTrue);
      var before = tracker.valueOf(ProgressTrack.outgoing);
      for (var i = 0; i < 40; i++) {
        step(tracker);
        final value = tracker.valueOf(ProgressTrack.outgoing);
        expect(value, greaterThanOrEqualTo(before));
        before = value;
      }
      expect(before, 1);
      expect(tracker.atRest, isTrue);
    });

    test('the incoming track follows each session apart and restarts with '
        'a new one', () {
      final tracker = create();
      tracker.update(
        _state(
          incoming: incomingView(
            id: 'a',
            stage: IncomingStage.receiving,
            size: 1000,
            received: 900,
          ),
        ),
      );
      for (var i = 0; i < 100; i++) {
        step(tracker);
      }
      expect(tracker.valueOf(ProgressTrack.incoming), greaterThan(0.5));
      expect(tracker.valueOf(ProgressTrack.outgoing), 0);
      tracker.update(
        _state(
          incoming: incomingView(
            id: 'b',
            stage: IncomingStage.receiving,
            size: 1000,
            received: 10,
          ),
        ),
      );
      expect(tracker.valueOf(ProgressTrack.incoming), 0);
    });

    test('an update without state, or with a warning, changes nothing', () {
      final tracker = create();
      tracker.update(null);
      tracker.update(_state(incoming: incomingView()));
      expect(tracker.atRest, isTrue);
      expect(tracker.valueOf(ProgressTrack.incoming), 0);
    });
  });

  group('SelectionProgressScope and SelectionProgressBuilder', () {
    testWidgets('the ticker runs while the value moves and stops at rest', (
      tester,
    ) async {
      final host = await _mount(
        tester,
        _state(
          queues: _queues(),
          outgoing: _uploading(),
          selection: _selection(1000, 4000),
        ),
      );
      expect(tester.binding.transientCallbackCount, greaterThan(0));
      await tester.pump(const Duration(seconds: 1));
      host.state.value = _state(
        queues: _queues(finished: true),
        selection: _selection(4000, 4000, finished: true),
      );
      await tester.pump(const Duration(seconds: 1));
      await tester.pump(const Duration(seconds: 1));
      expect(tester.binding.transientCallbackCount, 0);
    });

    testWidgets('without a scope the builder gives the fallback and does '
        'not listen', (tester) async {
      double? shown;
      bool? gliding;
      await tester.pumpWidget(
        Directionality(
          textDirection: TextDirection.ltr,
          child: SelectionProgressBuilder(
            track: ProgressTrack.outgoing,
            fallback: 0.37,
            builder: (context, value, glide) {
              shown = value;
              gliding = glide;
              return const SizedBox();
            },
          ),
        ),
      );
      expect(shown, 0.37);
      expect(gliding, isFalse);
      expect(
        SelectionProgressScope.maybeOf(tester.element(find.byType(SizedBox))),
        isNull,
      );
    });

    testWidgets('disabled, the builder gives the fallback even inside a '
        'scope', (tester) async {
      double? shown;
      await tester.pumpWidget(
        Directionality(
          textDirection: TextDirection.ltr,
          child: SelectionProgressScope(
            state: _state(queues: _queues(), selection: _selection(500, 1000)),
            child: SelectionProgressBuilder(
              track: ProgressTrack.outgoing,
              fallback: 0.9,
              enabled: false,
              builder: (context, value, glide) {
                shown = value;
                return const SizedBox();
              },
            ),
          ),
        ),
      );
      expect(shown, 0.9);
    });

    testWidgets('the default clock is the frame time of the scheduler', (
      tester,
    ) async {
      expect(frameClock(), tester.binding.currentSystemFrameTimeStamp);
    });
  });
}
