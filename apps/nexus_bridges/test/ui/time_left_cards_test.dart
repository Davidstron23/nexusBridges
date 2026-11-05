import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nexus_bridges/src/l10n/app_strings.dart';
import 'package:nexus_bridges/src/ui/activity_cards.dart';
import 'package:nexus_bridges/src/ui/progress/selection_progress_painter.dart';
import 'package:nexus_bridges/src/ui/progress/time_left_scope.dart';
import 'package:nexus_bridges/src/ui/queue_card.dart';
import 'package:nexus_bridges/src/ui/theme/components.dart';
import 'package:nexus_bridges/src/ui/theme/tokens.dart';
import 'package:nexus_bridges_core/nexus_bridges_core.dart';

import 'fake_app_controller.dart';
import 'segoe_font.dart';
import 'transfer_fixtures.dart';

const Duration _half = Duration(milliseconds: 500);
const int _size = 3000000;
const int _rate = 10000;
const List<String> _codes = ['es', 'en'];

Finder get _outgoing => find.byKey(const ValueKey('activity-outgoing'));
Finder get _incoming => find.byKey(const ValueKey('activity-incoming'));
Finder get _queueCard => find.byKey(const ValueKey('activity-queues'));
Finder _queueRow(String id) => find.byKey(ValueKey('queue-row-$id'));

Finder _bar(Finder scope) => inside(scope, find.byType(NbProgressBar));
Finder _footer(Finder scope) => inside(scope, find.byType(ActivityCardFooter));
Finder _fileRow(Finder scope) => inside(scope, find.byType(FileRow));
Finder _time(Finder scope, AppStrings strings) => inside(
  scope,
  find.textContaining(strings.arrivesIn('5 min').replaceAll('5 min', '')),
);

NodeState _sending(
  int sent, {
  OutgoingPhase phase = OutgoingPhase.uploading,
  bool cancelling = false,
  int size = _size,
}) => NodeState(
  outgoing: outgoingView(
    phase: phase,
    sent: sent,
    size: size,
    cancelling: cancelling,
  ),
);

NodeState _receiving(
  int received, {
  IncomingStage stage = IncomingStage.receiving,
  bool? canCancel,
}) => NodeState(
  incoming: incomingView(
    stage: stage,
    received: received,
    size: _size,
    canCancel: canCancel,
  ),
);

QueueItemView _item(
  String id,
  String name, {
  QueueItemState state = QueueItemState.pending,
  TransferOutcome? outcome,
}) {
  return QueueItemView(
    id: id,
    name: name,
    isFolder: false,
    isArchive: false,
    state: state,
    outcome: outcome,
  );
}

SendQueuesView _queues(List<QueueItemView> loose) => SendQueuesView(
  selectionId: 1,
  peerFingerprint: senderFingerprint,
  peerName: senderName,
  loose: loose,
  bundles: const [],
  finished: false,
  delivered: loose.where((item) => item.state == QueueItemState.done).length,
  total: loose.length,
  completedBytes: 0,
  pendingKnownBytes: 0,
  currentProbeSize: null,
);

NodeState _queueing({
  required int sent,
  String running = 'l1',
  OutgoingPhase phase = OutgoingPhase.uploading,
  bool cancelling = false,
  int size = _size,
}) {
  final first = running == 'l1';
  return NodeState(
    queues: _queues([
      first
          ? _item('l1', 'uno.pdf', state: QueueItemState.inProgress)
          : _item(
              'l1',
              'uno.pdf',
              state: QueueItemState.done,
              outcome: TransferOutcome.saved,
            ),
      _item(
        'l2',
        'dos.pdf',
        state: first ? QueueItemState.pending : QueueItemState.inProgress,
      ),
      _item('l3', 'tres.pdf'),
    ]),
    outgoing: outgoingView(
      fileName: first ? 'uno.pdf' : 'dos.pdf',
      phase: phase,
      sent: sent,
      size: size,
      cancelling: cancelling,
    ),
    selectionProgress: SelectionProgress(
      selectionId: 1,
      doneBytes: sent,
      totalBytes: 3000000000,
      currentName: first ? 'uno.pdf' : 'dos.pdf',
      currentIsFolder: false,
      finished: false,
    ),
  );
}

TimeLeftClock _clockOf(WidgetTester tester) {
  final start = tester.binding.clock.now();
  return () => tester.binding.clock.now().difference(start);
}

Future<FakeAppController> _pump(
  WidgetTester tester,
  String code,
  NodeState state, {
  double width = columnWidth,
}) {
  final clock = _clockOf(tester);
  return pumpColumn(
    tester,
    code,
    state,
    (controller, current) => SelectionProgressScope(
      state: current,
      child: TimeLeftScope(
        state: current,
        clock: clock,
        child: ActivityPanel(controller: controller, state: current),
      ),
    ),
    width: width,
  );
}

Future<void> _emitBetweenTicks(
  WidgetTester tester,
  FakeAppController controller,
  NodeState state,
) async {
  await tester.pump(_half);
  controller.emit(state);
  await tester.pump();
  await tester.pump(_half);
}

Future<int> _run(
  WidgetTester tester,
  FakeAppController controller,
  NodeState Function(int bytes) stateOf, {
  int from = _rate,
  int seconds = 6,
}) async {
  var bytes = from;
  for (var step = 0; step < seconds; step++) {
    bytes += _rate;
    await _emitBetweenTicks(tester, controller, stateOf(bytes));
  }
  return bytes;
}

void _expectFinalBar(WidgetTester tester, Finder scope) {
  final bar = tester.getRect(_bar(scope));
  final footer = tester.getRect(_footer(scope));
  expect(bar.height, 8);
  expect(bar.top - footer.bottom, 10);
  expect(bar.width, tester.getRect(_fileRow(scope)).width);
  final column = find
      .ancestor(of: _bar(scope), matching: find.byType(Column))
      .first;
  expect(tester.getRect(column).bottom, bar.bottom);
  for (final text in tester.elementList(inside(scope, find.byType(Text)))) {
    final box = text.renderObject! as RenderBox;
    expect(box.localToGlobal(Offset.zero).dy, lessThan(bar.top));
  }
}

void main() {
  setUpAll(loadSegoe);

  for (final code in _codes) {
    group('$code E912 footer and bar order', () {
      final strings = stringsFor(code);

      testWidgets('outgoing: file row, footer, bar of 8 px as last element', (
        tester,
      ) async {
        await _pump(tester, code, _sending(_rate));
        expect(_bar(_outgoing), findsOneWidget);
        final file = tester.getRect(_fileRow(_outgoing));
        final footer = tester.getRect(_footer(_outgoing));
        expect(file.bottom, lessThanOrEqualTo(footer.top));
        _expectFinalBar(tester, _outgoing);
      });

      testWidgets('incoming: file row, footer, bar of 8 px as last element', (
        tester,
      ) async {
        await _pump(tester, code, _receiving(_rate));
        expect(_bar(_incoming), findsOneWidget);
        final file = tester.getRect(_fileRow(_incoming));
        final footer = tester.getRect(_footer(_incoming));
        expect(file.bottom, lessThanOrEqualTo(footer.top));
        _expectFinalBar(tester, _incoming);
      });

      testWidgets('the bar has radius 4 and stays last with the time shown', (
        tester,
      ) async {
        final controller = await _pump(tester, code, _sending(_rate));
        await _run(tester, controller, _sending);
        expect(_time(_outgoing, strings), findsOneWidget);
        _expectFinalBar(tester, _outgoing);
        final track = tester
            .widgetList<Container>(
              inside(_bar(_outgoing), find.byType(Container)),
            )
            .first;
        final decoration = track.decoration! as BoxDecoration;
        expect(decoration.borderRadius, BorderRadius.circular(4));
      });

      testWidgets('a folder keeps the same order under its summary', (
        tester,
      ) async {
        await _pump(
          tester,
          code,
          NodeState(
            outgoing: OutgoingTransferView(
              peerFingerprint: senderFingerprint,
              peerName: senderName,
              fileName: 'proyecto',
              size: _size,
              isProgram: false,
              phase: OutgoingPhase.uploading,
              sentBytes: _rate,
              cancelling: false,
              isFolder: true,
              fileCount: 12,
              sentFiles: 3,
            ),
          ),
        );
        _expectFinalBar(tester, _outgoing);
      });
    });

    group('$code E913 the time on the left of Cancel', () {
      final strings = stringsFor(code);

      testWidgets('outgoing', (tester) async {
        final controller = await _pump(tester, code, _sending(_rate));
        await _run(tester, controller, _sending);
        final time = tester.getRect(_time(_outgoing, strings));
        final cancel = tester.getRect(
          buttonIn(_outgoing, strings.cancelButton),
        );
        expect(textOf(_timeText(tester, _outgoing, strings)), contains('min'));
        expect(time.left, tester.getRect(_fileRow(_outgoing)).left);
        expect(time.right, lessThanOrEqualTo(cancel.left));
        expect(cancel.right, tester.getRect(_footer(_outgoing)).right);
      });

      testWidgets('incoming', (tester) async {
        final controller = await _pump(tester, code, _receiving(_rate));
        await _run(tester, controller, _receiving);
        final time = tester.getRect(_time(_incoming, strings));
        final cancel = tester.getRect(
          buttonIn(_incoming, strings.cancelButton),
        );
        expect(time.left, tester.getRect(_fileRow(_incoming)).left);
        expect(time.right, lessThanOrEqualTo(cancel.left));
        expect(cancel.right, tester.getRect(_footer(_incoming)).right);
      });

      testWidgets('nothing takes its place before the 5 s', (tester) async {
        final controller = await _pump(tester, code, _sending(_rate));
        await _run(tester, controller, _sending, seconds: 4);
        expect(_time(_outgoing, strings), findsNothing);
        expect(find.text(strings.calculatingTime), findsNothing);
        expect(
          inside(
            _footer(_outgoing),
            find.byWidgetPredicate(
              (widget) =>
                  widget is Text && textOf(widget) != strings.cancelButton,
            ),
          ),
          findsNothing,
        );
      });

      testWidgets('the few seconds text uses the language', (tester) async {
        final controller = await _pump(
          tester,
          code,
          _sending(_rate, size: 130000),
        );
        await _run(
          tester,
          controller,
          (bytes) => _sending(bytes, size: 130000),
          seconds: 11,
        );
        expect(find.text(strings.arrivesInFewSeconds), findsOneWidget);
      });

      testWidgets('the text is 13 px, semibold and with tabular figures', (
        tester,
      ) async {
        final controller = await _pump(tester, code, _sending(_rate));
        await _run(tester, controller, _sending);
        final style = _timeText(tester, _outgoing, strings).style!;
        final context = tester.element(_outgoing);
        expect(style.fontSize, 13);
        expect(style.fontWeight, FontWeight.w600);
        expect(style.color, NbColors.of(context).text);
        expect(
          style.fontFeatures,
          contains(const FontFeature.tabularFigures()),
        );
      });

      testWidgets('the 3 px: below Cancel and 7 px above the bar', (
        tester,
      ) async {
        final controller = await _pump(tester, code, _sending(_rate));
        await _run(tester, controller, _sending);
        final time = tester.getRect(_time(_outgoing, strings));
        final cancel = tester.getRect(
          buttonIn(_outgoing, strings.cancelButton),
        );
        final bar = tester.getRect(_bar(_outgoing));
        final footer = tester.getRect(_footer(_outgoing));
        expect(cancel.bottom, footer.bottom);
        expect(time.bottom - cancel.bottom, 3);
        expect(bar.top - time.bottom, 7);
        expect(bar.top - cancel.bottom, 10);
      });

      testWidgets('the 3 px apply to calculating too', (tester) async {
        final controller = await _pump(tester, code, _sending(_rate));
        await _run(tester, controller, _sending);
        await tester.pump(const Duration(seconds: 4));
        final text = tester.getRect(find.text(strings.calculatingTime));
        final cancel = tester.getRect(
          buttonIn(_outgoing, strings.cancelButton),
        );
        expect(text.bottom - cancel.bottom, 3);
      });

      testWidgets('the 3 px apply to the incoming time', (tester) async {
        final controller = await _pump(tester, code, _receiving(_rate));
        await _run(tester, controller, _receiving);
        final time = tester.getRect(_time(_incoming, strings));
        final cancel = tester.getRect(
          buttonIn(_incoming, strings.cancelButton),
        );
        expect(time.bottom - cancel.bottom, 3);
      });
    });

    group('$code E914 while checking', () {
      final strings = stringsFor(code);

      testWidgets('outgoing shows the old text and a full bar', (tester) async {
        final controller = await _pump(tester, code, _sending(_rate));
        await _run(tester, controller, _sending);
        expect(_time(_outgoing, strings), findsOneWidget);
        controller.emit(_sending(_size, phase: OutgoingPhase.verifying));
        await tester.pump();
        expect(_time(_outgoing, strings), findsNothing);
        expect(find.text(strings.peerCheckingFile(senderName)), findsOneWidget);
        expect(tester.widget<NbProgressBar>(_bar(_outgoing)).value, 1);
        _expectFinalBar(tester, _outgoing);
      });

      testWidgets('incoming shows the old text and a full bar', (tester) async {
        final controller = await _pump(tester, code, _receiving(_rate));
        await _run(tester, controller, _receiving);
        expect(_time(_incoming, strings), findsOneWidget);
        controller.emit(_receiving(_size, stage: IncomingStage.verifying));
        await tester.pump();
        expect(_time(_incoming, strings), findsNothing);
        expect(find.text(strings.checkingFile), findsOneWidget);
        for (var frame = 0; frame < 240; frame++) {
          await tester.pump(const Duration(milliseconds: 16));
        }
        expect(tester.widget<NbProgressBar>(_bar(_incoming)).value, 1);
        _expectFinalBar(tester, _incoming);
      });

      testWidgets('the last byte hides the time before the phase changes', (
        tester,
      ) async {
        final controller = await _pump(tester, code, _sending(_rate));
        await _run(tester, controller, _sending);
        controller.emit(_sending(_size));
        await tester.pump();
        expect(_time(_outgoing, strings), findsNothing);
        expect(find.text(strings.calculatingTime), findsNothing);
        expect(tester.widget<NbProgressBar>(_bar(_outgoing)).value, 1);
        await tester.pump(const Duration(seconds: 6));
        expect(find.text(strings.calculatingTime), findsNothing);
      });

      testWidgets('the checking text does not come back to calculating', (
        tester,
      ) async {
        final controller = await _pump(tester, code, _receiving(_rate));
        await _run(tester, controller, _receiving);
        controller.emit(_receiving(_size, stage: IncomingStage.verifying));
        await tester.pump(const Duration(seconds: 10));
        expect(find.text(strings.calculatingTime), findsNothing);
        expect(find.text(strings.checkingFile), findsOneWidget);
      });
    });

    group('$code E915 while cancelling', () {
      final strings = stringsFor(code);

      testWidgets('the time leaves and Cancel becomes the cancelling text', (
        tester,
      ) async {
        final controller = await _pump(tester, code, _sending(_rate));
        final bytes = await _run(tester, controller, _sending);
        expect(_time(_outgoing, strings), findsOneWidget);
        controller.emit(_sending(bytes, cancelling: true));
        await tester.pump();
        expect(_time(_outgoing, strings), findsNothing);
        expect(find.text(strings.cancellingTransfer), findsOneWidget);
        expect(buttonIn(_outgoing, strings.cancelButton), findsNothing);
      });

      testWidgets('calculating leaves as well and does not come back', (
        tester,
      ) async {
        final controller = await _pump(tester, code, _sending(_rate));
        final bytes = await _run(tester, controller, _sending);
        await tester.pump(const Duration(seconds: 4));
        expect(find.text(strings.calculatingTime), findsOneWidget);
        controller.emit(_sending(bytes, cancelling: true));
        await tester.pump();
        expect(find.text(strings.calculatingTime), findsNothing);
        await tester.pump(const Duration(seconds: 10));
        expect(find.text(strings.calculatingTime), findsNothing);
        expect(_time(_outgoing, strings), findsNothing);
      });
    });

    group('$code E916 reception without Cancel', () {
      final strings = stringsFor(code);

      testWidgets('the time is shown on the left and there is no button', (
        tester,
      ) async {
        NodeState stateOf(int bytes) => _receiving(bytes, canCancel: false);
        final controller = await _pump(tester, code, stateOf(_rate));
        await _run(tester, controller, stateOf);
        expect(buttonIn(_incoming, strings.cancelButton), findsNothing);
        final time = tester.getRect(_time(_incoming, strings));
        expect(time.left, tester.getRect(_fileRow(_incoming)).left);
        _expectFinalBar(tester, _incoming);
      });

      testWidgets('without the time the bar keeps its place', (tester) async {
        await _pump(tester, code, _receiving(_rate, canCancel: false));
        expect(_footer(_incoming), findsOneWidget);
        _expectFinalBar(tester, _incoming);
      });

      testWidgets('a reception that can be cancelled has its button', (
        tester,
      ) async {
        await _pump(tester, code, _receiving(_rate, canCancel: true));
        expect(buttonIn(_incoming, strings.cancelButton), findsOneWidget);
      });
    });

    group('$code E917 760x520 with text at 200 %', () {
      final strings = stringsFor(code);

      void useDoubleText(WidgetTester tester) {
        tester.platformDispatcher.textScaleFactorTestValue = 2;
        addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      }

      void expectNoTruncation(WidgetTester tester, Finder text) {
        final paragraph = tester.renderObject<RenderParagraph>(
          inside(text, find.byType(RichText)),
        );
        expect(paragraph.didExceedMaxLines, isFalse);
      }

      NodeState twoCards(int bytes) => NodeState(
        outgoing: outgoingView(sent: bytes, size: _size),
        incoming: incomingView(
          stage: IncomingStage.receiving,
          received: bytes,
          size: _size,
        ),
      );

      testWidgets('the real HomeScreen with its real clock has no overflow', (
        tester,
      ) async {
        useDoubleText(tester);
        setWindow(tester, const Size(760, 520));
        final controller = FakeAppController(state: twoCards(_rate));
        await pumpHome(tester, controller, code, settle: false);
        var bytes = _rate;
        for (var step = 0; step < 4; step++) {
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 1800)),
          );
          bytes += _rate * 2;
          controller.emit(twoCards(bytes));
          await tester.pump();
          expect(tester.takeException(), isNull);
        }
        expect(_time(_outgoing, strings), findsOneWidget);
        expect(_time(_incoming, strings), findsOneWidget);
        expectNoTruncation(tester, _time(_outgoing, strings));
        expectNoTruncation(tester, _time(_incoming, strings));
        _expectFinalBar(tester, _outgoing);
        _expectFinalBar(tester, _incoming);
        final time = tester.getRect(_time(_outgoing, strings));
        final cancel = tester.getRect(
          buttonIn(_outgoing, strings.cancelButton),
        );
        expect(time.right, lessThanOrEqualTo(cancel.left));
      });

      testWidgets('the longest time fits in the narrowest column', (
        tester,
      ) async {
        useDoubleText(tester);
        const size = 3000000 * 3;
        NodeState stateOf(int bytes) =>
            _sending(bytes, size: size * 1000 ~/ 32);
        final controller = await _pump(tester, code, stateOf(_rate));
        await _run(tester, controller, stateOf);
        expect(tester.takeException(), isNull);
        final text = _timeText(tester, _outgoing, strings).data!;
        expect(text, contains(' h '));
        expectNoTruncation(tester, _time(_outgoing, strings));
        _expectFinalBar(tester, _outgoing);
      });

      testWidgets('the few seconds text fits too', (tester) async {
        useDoubleText(tester);
        NodeState stateOf(int bytes) => _sending(bytes, size: 130000);
        final controller = await _pump(tester, code, stateOf(_rate));
        await _run(tester, controller, stateOf, seconds: 11);
        expect(tester.takeException(), isNull);
        expectNoTruncation(tester, find.text(strings.arrivesInFewSeconds));
      });

      testWidgets('calculating fits too', (tester) async {
        useDoubleText(tester);
        final controller = await _pump(tester, code, _sending(_rate));
        await _run(tester, controller, _sending);
        await tester.pump(const Duration(seconds: 4));
        expect(tester.takeException(), isNull);
        expectNoTruncation(tester, find.text(strings.calculatingTime));
      });

      testWidgets('the queue row fits too', (tester) async {
        useDoubleText(tester);
        NodeState stateOf(int bytes) => _queueing(sent: bytes);
        final controller = await _pump(tester, code, stateOf(_rate));
        await _run(tester, controller, stateOf);
        expect(tester.takeException(), isNull);
        final row = _queueRow('l1');
        final time = _time(row, strings);
        expect(time, findsOneWidget);
        expectNoTruncation(tester, time);
        expect(
          tester.getRect(time).right,
          lessThanOrEqualTo(
            tester.getRect(buttonIn(row, strings.cancelButton)).left,
          ),
        );
      });
    });

    group('$code E918 cards without a bar do not change', () {
      final strings = stringsFor(code);

      void expectCentered(WidgetTester tester, Finder scope, Finder note) {
        final row = tester.widget<Row>(
          inside(_footer(scope), find.byType(Row)).first,
        );
        expect(row.crossAxisAlignment, CrossAxisAlignment.center);
        final cancel = tester.getRect(buttonIn(scope, strings.cancelButton));
        expect(tester.getCenter(note).dy, closeTo(cancel.center.dy, 0.5));
        expect(_bar(scope), findsNothing);
        expect(inside(scope, find.byType(TimeLeftLabel)), findsNothing);
      }

      testWidgets('outgoing requesting', (tester) async {
        await _pump(tester, code, _sending(0, phase: OutgoingPhase.requesting));
        expectCentered(
          tester,
          _outgoing,
          find.text(strings.contactingPeer(senderName)),
        );
      });

      testWidgets('outgoing waiting', (tester) async {
        await _pump(tester, code, _sending(0, phase: OutgoingPhase.waiting));
        expectCentered(
          tester,
          _outgoing,
          find.text(strings.waitingAcceptance(senderName)),
        );
      });

      testWidgets('outgoing preparing', (tester) async {
        await _pump(tester, code, _sending(0, phase: OutgoingPhase.preparing));
        expect(_bar(_outgoing), findsNothing);
        expect(inside(_outgoing, find.byType(TimeLeftLabel)), findsNothing);
        expect(buttonIn(_outgoing, strings.cancelButton), findsOneWidget);
      });

      testWidgets('incoming waiting for data', (tester) async {
        await _pump(
          tester,
          code,
          _receiving(0, stage: IncomingStage.waitingData),
        );
        expectCentered(tester, _incoming, find.text(strings.waitingForData));
      });
    });

    group('$code E919 the queue row', () {
      final strings = stringsFor(code);

      testWidgets('the time is on the left of the row Cancel', (tester) async {
        NodeState stateOf(int bytes) => _queueing(sent: bytes);
        final controller = await _pump(tester, code, stateOf(_rate));
        await _run(tester, controller, stateOf);
        final row = _queueRow('l1');
        final time = _time(row, strings);
        expect(time, findsOneWidget);
        expect(_time(_queueCard, strings), findsOneWidget);
        final cancel = tester.getRect(buttonIn(row, strings.cancelButton));
        expect(tester.getRect(time).right, lessThanOrEqualTo(cancel.left));
        expect(tester.getCenter(time).dy, closeTo(cancel.center.dy, 0.5));
      });

      testWidgets('the time is of the item, not of the whole queue', (
        tester,
      ) async {
        NodeState stateOf(int bytes) => _queueing(sent: bytes);
        final controller = await _pump(tester, code, stateOf(_rate));
        await _run(tester, controller, stateOf);
        expect(find.text(strings.arrivesIn('5 min')), findsOneWidget);
      });

      testWidgets('pending rows have no time', (tester) async {
        NodeState stateOf(int bytes) => _queueing(sent: bytes);
        final controller = await _pump(tester, code, stateOf(_rate));
        await _run(tester, controller, stateOf);
        expect(_time(_queueRow('l2'), strings), findsNothing);
        expect(_time(_queueRow('l3'), strings), findsNothing);
      });

      testWidgets('verifying and cancelling items have no time', (
        tester,
      ) async {
        NodeState stateOf(int bytes) => _queueing(sent: bytes);
        final controller = await _pump(tester, code, stateOf(_rate));
        final bytes = await _run(tester, controller, stateOf);
        controller.emit(_queueing(sent: bytes, cancelling: true));
        await tester.pump();
        expect(_time(_queueCard, strings), findsNothing);
        expect(find.text(strings.cancellingTransfer), findsOneWidget);
        controller.emit(_queueing(sent: _size, phase: OutgoingPhase.verifying));
        await tester.pump();
        expect(_time(_queueCard, strings), findsNothing);
      });

      testWidgets('without a time the row Cancel stays at the right', (
        tester,
      ) async {
        await _pump(tester, code, _queueing(sent: _rate));
        final row = _queueRow('l1');
        expect(_time(row, strings), findsNothing);
        final cancel = tester.getRect(buttonIn(row, strings.cancelButton));
        final name = tester.getRect(find.text('uno.pdf'));
        expect(cancel.right, greaterThan(name.right));
      });
    });

    group('$code E920 the other bars stay at 6 px', () {
      final strings = stringsFor(code);

      testWidgets('the selection bar and the row bar', (tester) async {
        NodeState stateOf(int bytes) => _queueing(sent: bytes);
        final controller = await _pump(tester, code, stateOf(_rate));
        await _run(tester, controller, stateOf);
        final selection = _bar(find.byType(SelectionBar));
        final item = _bar(_queueRow('l1'));
        expect(selection, findsOneWidget);
        expect(item, findsOneWidget);
        expect(tester.getSize(selection).height, 6);
        expect(tester.getSize(item).height, 6);
        for (final bar in [selection, item]) {
          final track = tester
              .widgetList<Container>(inside(bar, find.byType(Container)))
              .first;
          final decoration = track.decoration! as BoxDecoration;
          expect(decoration.borderRadius, BorderRadius.circular(3));
        }
      });

      testWidgets('they keep their place above the row footer', (tester) async {
        await _pump(tester, code, _queueing(sent: _rate));
        final row = _queueRow('l1');
        final selection = tester.getRect(_bar(find.byType(SelectionBar)));
        final item = tester.getRect(_bar(row));
        final cancel = tester.getRect(buttonIn(row, strings.cancelButton));
        expect(selection.bottom, lessThanOrEqualTo(tester.getRect(row).top));
        expect(item.bottom, lessThanOrEqualTo(cancel.top));
      });
    });

    group('$code E921 moving to the next item', () {
      final strings = stringsFor(code);

      testWidgets('the name changes: the estimator starts again', (
        tester,
      ) async {
        NodeState first(int bytes) => _queueing(sent: bytes);
        NodeState second(int bytes) => _queueing(sent: bytes, running: 'l2');
        final controller = await _pump(tester, code, first(_rate));
        final bytes = await _run(tester, controller, first);
        expect(_time(_queueCard, strings), findsOneWidget);
        controller.emit(second(bytes + _rate));
        await tester.pump();
        expect(_time(_queueCard, strings), findsNothing);
        expect(find.text(strings.calculatingTime), findsNothing);
        await _run(tester, controller, second, from: bytes + _rate, seconds: 4);
        expect(_time(_queueCard, strings), findsNothing);
        await _run(
          tester,
          controller,
          second,
          from: bytes + 5 * _rate,
          seconds: 2,
        );
        expect(_time(_queueRow('l2'), strings), findsOneWidget);
      });

      testWidgets('the bytes go back: the estimator starts again', (
        tester,
      ) async {
        NodeState first(int bytes) => _queueing(sent: bytes);
        NodeState second(int bytes) => _queueing(sent: bytes, running: 'l2');
        final controller = await _pump(tester, code, first(_rate));
        await _run(tester, controller, first);
        controller.emit(second(_rate));
        await tester.pump();
        expect(_time(_queueCard, strings), findsNothing);
        await _run(tester, controller, second, seconds: 4);
        expect(_time(_queueCard, strings), findsNothing);
      });

      testWidgets('a pass through preparing starts it again as well', (
        tester,
      ) async {
        NodeState first(int bytes) => _queueing(sent: bytes);
        NodeState second(int bytes) => _queueing(sent: bytes, running: 'l2');
        final controller = await _pump(tester, code, first(_rate));
        final bytes = await _run(tester, controller, first);
        controller.emit(
          _queueing(sent: 0, running: 'l2', phase: OutgoingPhase.preparing),
        );
        await tester.pump();
        expect(_time(_queueCard, strings), findsNothing);
        controller.emit(second(bytes));
        await tester.pump();
        expect(_time(_queueCard, strings), findsNothing);
      });

      testWidgets('the second item reads its own size', (tester) async {
        NodeState first(int bytes) => _queueing(sent: bytes, size: 300000);
        NodeState second(int bytes) => _queueing(sent: bytes, running: 'l2');
        final controller = await _pump(tester, code, first(_rate));
        await _run(tester, controller, first);
        expect(_time(_queueCard, strings), findsOneWidget);
        expect(find.text(strings.arrivesIn('5 min')), findsNothing);
        controller.emit(second(_rate));
        await tester.pump();
        await _run(tester, controller, second);
        expect(find.text(strings.arrivesIn('5 min')), findsOneWidget);
      });
    });
  }
}

Text _timeText(WidgetTester tester, Finder scope, AppStrings strings) =>
    tester.widget<Text>(_time(scope, strings));
