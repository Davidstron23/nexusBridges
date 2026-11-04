import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nexus_bridges/src/l10n/app_strings.dart';
import 'package:nexus_bridges/src/ui/activity_cards.dart';
import 'package:nexus_bridges/src/ui/format.dart';
import 'package:nexus_bridges/src/ui/progress/selection_progress_painter.dart';
import 'package:nexus_bridges/src/ui/progress/time_left.dart';
import 'package:nexus_bridges/src/ui/progress/time_left_scope.dart';
import 'package:nexus_bridges_core/nexus_bridges_core.dart';

import '../fake_app_controller.dart';
import '../transfer_fixtures.dart';

const Duration _second = Duration(seconds: 1);
const Duration _half = Duration(milliseconds: 500);
const int _size = 3000000;
const int _rate = 10000;

NodeState _sending(int sent, {bool cancelling = false, int size = _size}) =>
    NodeState(
      outgoing: outgoingView(sent: sent, size: size, cancelling: cancelling),
    );

NodeState _receiving(
  int received, {
  IncomingStage stage = IncomingStage.receiving,
  int size = _size,
}) => NodeState(
  incoming: incomingView(stage: stage, received: received, size: size),
);

NodeState _both(int sent, int received, {int incomingSize = _size}) =>
    NodeState(
      outgoing: outgoingView(sent: sent, size: _size),
      incoming: incomingView(
        stage: IncomingStage.receiving,
        received: received,
        size: incomingSize,
      ),
    );

TimeLeftClock _clockOf(WidgetTester tester) {
  final start = tester.binding.clock.now();
  return () => tester.binding.clock.now().difference(start);
}

Future<int> _flow(
  WidgetTester tester,
  TimeLeftTracker tracker, {
  int from = _rate,
  int seconds = 6,
}) async {
  var bytes = from;
  tracker.update(_sending(bytes));
  for (var step = 0; step < seconds; step++) {
    await tester.pump(_half);
    bytes += _rate;
    tracker.update(_sending(bytes));
    await tester.pump(_half);
  }
  return bytes;
}

final class _Timers {
  final List<Timer> all = [];

  int get alive => all.where((timer) => timer.isActive).length;

  T run<T>(T Function() body) => runZoned(
    body,
    zoneSpecification: ZoneSpecification(
      createPeriodicTimer: (self, parent, zone, period, callback) {
        final timer = parent.createPeriodicTimer(zone, period, callback);
        all.add(timer);
        return timer;
      },
    ),
  );
}

Widget _scoped(
  FakeAppController controller,
  NodeState state,
  TimeLeftClock clock,
) {
  return SelectionProgressScope(
    state: state,
    child: TimeLeftScope(
      state: state,
      clock: clock,
      child: ActivityPanel(controller: controller, state: state),
    ),
  );
}

Future<FakeAppController> _pumpScoped(
  WidgetTester tester,
  String code,
  NodeState state,
) {
  final clock = _clockOf(tester);
  return pumpColumn(
    tester,
    code,
    state,
    (controller, current) => _scoped(controller, current, clock),
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

Future<int> _flowCard(
  WidgetTester tester,
  FakeAppController controller, {
  int seconds = 6,
}) async {
  var bytes = _rate;
  for (var step = 0; step < seconds; step++) {
    bytes += _rate;
    await _emitBetweenTicks(tester, controller, _sending(bytes));
  }
  return bytes;
}

class _Parent extends StatefulWidget {
  const _Parent({required this.initial, required this.clock, super.key});

  final NodeState initial;
  final TimeLeftClock clock;

  @override
  State<_Parent> createState() => _ParentState();
}

class _ParentState extends State<_Parent> {
  late NodeState _state = widget.initial;

  void show(NodeState state) => setState(() => _state = state);

  @override
  Widget build(BuildContext context) {
    return Directionality(
      textDirection: TextDirection.ltr,
      child: TimeLeftScope(
        state: _state,
        clock: widget.clock,
        child: Builder(
          builder: (context) {
            final tracker = TimeLeftScope.maybeOf(context)!;
            return ListenableBuilder(
              listenable: tracker,
              builder: (context, _) =>
                  Text(switch (tracker.readingOf(ProgressTrack.outgoing)) {
                    TimeLeftHidden() => 'hidden',
                    TimeLeftCalculating() => 'calculating',
                    TimeLeftRemaining() => 'remaining',
                  }),
            );
          },
        ),
      ),
    );
  }
}

void main() {
  testWidgets('Q-2 new bytes reach the time with no rebuild of the scope', (
    tester,
  ) async {
    final clock = _clockOf(tester);
    final source = ValueNotifier<NodeState?>(_sending(_rate));
    addTearDown(source.dispose);
    await tester.pumpWidget(
      TimeLeftScope(
        state: _sending(_rate),
        clock: clock,
        source: source,
        read: () => source.value,
        child: Builder(
          builder: (context) {
            final tracker = TimeLeftScope.maybeOf(context)!;
            return Directionality(
              textDirection: TextDirection.ltr,
              child: ListenableBuilder(
                listenable: tracker,
                builder: (context, _) => Text(
                  tracker
                      .readingOf(ProgressTrack.outgoing)
                      .runtimeType
                      .toString(),
                ),
              ),
            );
          },
        ),
      ),
    );
    var bytes = _rate;
    for (var step = 0; step < 8; step++) {
      await tester.binding.delayed(_second);
      bytes += _rate;
      source.value = _sending(bytes);
    }
    await tester.pump();
    expect(find.text('TimeLeftCalculating'), findsNothing);
    expect(find.text('TimeLeftRemaining'), findsOneWidget);
  });

  group('E908 a stall without new states', () {
    testWidgets('the tracker reaches calculating at 3 s on its own', (
      tester,
    ) async {
      final tracker = TimeLeftTracker(clock: _clockOf(tester));
      await _flow(tester, tracker);
      expect(
        tracker.readingOf(ProgressTrack.outgoing),
        isA<TimeLeftRemaining>(),
      );
      await tester.pump(_second);
      await tester.pump(_second);
      expect(
        tracker.readingOf(ProgressTrack.outgoing),
        isA<TimeLeftRemaining>(),
      );
      await tester.pump(_second);
      expect(tracker.readingOf(ProgressTrack.outgoing), TimeLeft.calculating);
      tracker.dispose();
    });

    testWidgets('the watch is never later than 4 s, wherever the state fell', (
      tester,
    ) async {
      final tracker = TimeLeftTracker(clock: _clockOf(tester));
      await _flow(tester, tracker);
      await tester.pump(const Duration(milliseconds: 300));
      tracker.update(_sending(80000));
      await tester.pump(const Duration(seconds: 3));
      expect(
        tracker.readingOf(ProgressTrack.outgoing),
        isA<TimeLeftRemaining>(),
      );
      await tester.pump(_second);
      expect(tracker.readingOf(ProgressTrack.outgoing), TimeLeft.calculating);
      tracker.dispose();
    });

    testWidgets('the incoming side also stalls on its own', (tester) async {
      final tracker = TimeLeftTracker(clock: _clockOf(tester));
      var bytes = _rate;
      tracker.update(_receiving(bytes));
      for (var step = 0; step < 6; step++) {
        await tester.pump(_half);
        bytes += _rate;
        tracker.update(_receiving(bytes));
        await tester.pump(_half);
      }
      expect(
        tracker.readingOf(ProgressTrack.incoming),
        isA<TimeLeftRemaining>(),
      );
      await tester.pump(const Duration(seconds: 3));
      expect(tracker.readingOf(ProgressTrack.incoming), TimeLeft.calculating);
      tracker.dispose();
    });

    for (final code in ['es', 'en']) {
      testWidgets('$code the card says it without a new state', (tester) async {
        final strings = stringsFor(code);
        final controller = await _pumpScoped(tester, code, _sending(_rate));
        await _flowCard(tester, controller);
        expect(find.text(strings.arrivesIn('5 min')), findsOneWidget);
        await tester.pump(_second);
        await tester.pump(_second);
        expect(find.textContaining(strings.arrivesIn('')), findsOneWidget);
        expect(find.text(strings.calculatingTime), findsNothing);
        await tester.pump(_second);
        expect(find.text(strings.calculatingTime), findsOneWidget);
        expect(find.textContaining(strings.arrivesIn('')), findsNothing);
      });

      testWidgets('$code the card comes back after 2 s of new samples', (
        tester,
      ) async {
        final strings = stringsFor(code);
        final controller = await _pumpScoped(tester, code, _sending(_rate));
        var bytes = await _flowCard(tester, controller);
        await tester.pump(const Duration(seconds: 4));
        expect(find.text(strings.calculatingTime), findsOneWidget);
        bytes += _rate;
        await _emitBetweenTicks(tester, controller, _sending(bytes));
        expect(find.text(strings.calculatingTime), findsOneWidget);
        bytes += _rate;
        await _emitBetweenTicks(tester, controller, _sending(bytes));
        expect(find.text(strings.calculatingTime), findsOneWidget);
        for (var step = 0; step < 2; step++) {
          bytes += _rate;
          await _emitBetweenTicks(tester, controller, _sending(bytes));
        }
        expect(find.text(strings.calculatingTime), findsNothing);
        expect(find.textContaining(strings.arrivesIn('')), findsOneWidget);
      });
    }

    test(
      'the real 1 s timer and the real clock do it without states',
      () async {
        final tracker = TimeLeftTracker();
        var notified = 0;
        tracker.addListener(() => notified++);
        addTearDown(tracker.dispose);
        final elapsed = Stopwatch()..start();
        var bytes = _rate;
        tracker.update(_sending(bytes));
        while (tracker.readingOf(ProgressTrack.outgoing)
            is! TimeLeftRemaining) {
          await Future<void>.delayed(const Duration(milliseconds: 100));
          bytes += _rate ~/ 10;
          tracker.update(_sending(bytes));
          expect(elapsed.elapsed, lessThan(const Duration(seconds: 15)));
        }
        expect(
          elapsed.elapsed,
          greaterThanOrEqualTo(const Duration(seconds: 5)),
        );
        final seen = notified;
        final stalled = Stopwatch()..start();
        while (tracker.readingOf(ProgressTrack.outgoing) !=
            TimeLeft.calculating) {
          await Future<void>.delayed(const Duration(milliseconds: 50));
          expect(stalled.elapsed, lessThan(const Duration(seconds: 8)));
        }
        expect(
          stalled.elapsed,
          greaterThanOrEqualTo(const Duration(seconds: 2)),
        );
        expect(notified, greaterThan(seen));
      },
      timeout: const Timeout(Duration(seconds: 40)),
    );
  });

  group('E909 the timer lives only while something is active', () {
    testWidgets('nothing active means no timer', (tester) async {
      final tracker = TimeLeftTracker(clock: _clockOf(tester));
      expect(tracker.watching, isFalse);
      tracker.update(null);
      expect(tracker.watching, isFalse);
      tracker.update(const NodeState());
      expect(tracker.watching, isFalse);
      tracker.update(
        NodeState(outgoing: outgoingView(phase: OutgoingPhase.waiting)),
      );
      expect(tracker.watching, isFalse);
      tracker.update(
        NodeState(incoming: incomingView(stage: IncomingStage.waitingData)),
      );
      expect(tracker.watching, isFalse);
      tracker.dispose();
    });

    final ends = <String, NodeState?>{
      'null state': null,
      'an empty state': const NodeState(),
      'cancelling': _sending(5000, cancelling: true),
      'the last byte': _sending(_size),
      'verifying': NodeState(
        outgoing: outgoingView(
          phase: OutgoingPhase.verifying,
          size: _size,
          sent: _size,
        ),
      ),
    };
    for (final MapEntry(key: name, value: end) in ends.entries) {
      testWidgets('it stops with $name', (tester) async {
        final tracker = TimeLeftTracker(clock: _clockOf(tester));
        tracker.update(_sending(5000));
        expect(tracker.watching, isTrue);
        tracker.update(end);
        expect(tracker.watching, isFalse);
        tracker.dispose();
      });
    }

    testWidgets('it stops when the incoming side reaches verifying', (
      tester,
    ) async {
      final tracker = TimeLeftTracker(clock: _clockOf(tester));
      tracker.update(_receiving(5000));
      expect(tracker.watching, isTrue);
      tracker.update(_receiving(_size, stage: IncomingStage.verifying));
      expect(tracker.watching, isFalse);
      tracker.dispose();
    });

    testWidgets('it stays while one side is still active', (tester) async {
      final tracker = TimeLeftTracker(clock: _clockOf(tester));
      tracker.update(_both(5000, 5000));
      expect(tracker.watching, isTrue);
      tracker.update(_receiving(6000));
      expect(tracker.watching, isTrue);
      tracker.update(null);
      expect(tracker.watching, isFalse);
      tracker.dispose();
    });

    testWidgets('dispose stops it and a late update does not revive it', (
      tester,
    ) async {
      final tracker = TimeLeftTracker(clock: _clockOf(tester));
      tracker.update(_sending(5000));
      expect(tracker.watching, isTrue);
      tracker.dispose();
      expect(tracker.watching, isFalse);
      tracker.update(_sending(6000));
      expect(tracker.watching, isFalse);
    });

    test('a single real timer of 1 s and none alive after finishing', () {
      final timers = _Timers();
      timers.run(() {
        final tracker = TimeLeftTracker();
        tracker.update(_sending(1000));
        tracker.update(_sending(2000));
        tracker.update(_both(3000, 1000));
        expect(timers.all, hasLength(1));
        expect(timers.alive, 1);
        tracker.update(null);
        expect(timers.alive, 0);
        tracker.update(_sending(1000));
        expect(timers.all, hasLength(2));
        expect(timers.alive, 1);
        tracker.update(_sending(_size));
        expect(timers.alive, 0);
        tracker.dispose();
      });
      expect(timers.alive, 0);
    });

    test('dispose in the middle of a transfer leaves no real timer', () {
      final timers = _Timers();
      timers.run(() {
        final tracker = TimeLeftTracker();
        tracker.update(_both(1000, 1000));
        expect(timers.alive, 1);
        tracker.dispose();
        expect(timers.alive, 0);
        tracker.update(_sending(2000));
      });
      expect(timers.all, hasLength(1));
      expect(timers.alive, 0);
    });

    testWidgets('the scope stops the tracker when it is unmounted', (
      tester,
    ) async {
      late TimeLeftTracker tracker;
      await tester.pumpWidget(
        TimeLeftScope(
          state: _sending(5000),
          clock: _clockOf(tester),
          child: Builder(
            builder: (context) {
              tracker = TimeLeftScope.maybeOf(context)!;
              return const SizedBox.shrink();
            },
          ),
        ),
      );
      expect(tracker.watching, isTrue);
      await tester.pumpWidget(const SizedBox.shrink());
      expect(tracker.watching, isFalse);
    });
  });

  group('E910 outgoing and incoming are independent', () {
    testWidgets('each side reads its own speed', (tester) async {
      final tracker = TimeLeftTracker(clock: _clockOf(tester));
      var sent = _rate;
      var received = _rate;
      tracker.update(_both(sent, received));
      for (var step = 0; step < 7; step++) {
        await tester.pump(_half);
        sent += _rate;
        received += _rate ~/ 2;
        tracker.update(_both(sent, received));
        await tester.pump(_half);
      }
      final outgoing =
          tracker.readingOf(ProgressTrack.outgoing) as TimeLeftRemaining;
      final incoming =
          tracker.readingOf(ProgressTrack.incoming) as TimeLeftRemaining;
      expect(
        incoming.value.inSeconds / outgoing.value.inSeconds,
        closeTo(2, 0.2),
      );
      tracker.dispose();
    });

    testWidgets('a stall on one side leaves the other side running', (
      tester,
    ) async {
      final tracker = TimeLeftTracker(clock: _clockOf(tester));
      var sent = _rate;
      var received = _rate;
      tracker.update(_both(sent, received));
      for (var step = 0; step < 6; step++) {
        await tester.pump(_half);
        sent += _rate;
        received += _rate;
        tracker.update(_both(sent, received));
        await tester.pump(_half);
      }
      for (var step = 0; step < 4; step++) {
        await tester.pump(_half);
        received += _rate;
        tracker.update(_both(sent, received));
        await tester.pump(_half);
      }
      expect(tracker.readingOf(ProgressTrack.outgoing), TimeLeft.calculating);
      expect(
        tracker.readingOf(ProgressTrack.incoming),
        isA<TimeLeftRemaining>(),
      );
      tracker.dispose();
    });

    testWidgets('ending one side leaves the other side reading', (
      tester,
    ) async {
      final tracker = TimeLeftTracker(clock: _clockOf(tester));
      var sent = _rate;
      var received = _rate;
      tracker.update(_both(sent, received));
      for (var step = 0; step < 6; step++) {
        await tester.pump(_half);
        sent += _rate;
        received += _rate;
        tracker.update(_both(sent, received));
        await tester.pump(_half);
      }
      tracker.update(_receiving(received));
      expect(tracker.readingOf(ProgressTrack.outgoing), TimeLeft.hidden);
      expect(
        tracker.readingOf(ProgressTrack.incoming),
        isA<TimeLeftRemaining>(),
      );
      tracker.update(_sending(sent));
      expect(tracker.readingOf(ProgressTrack.incoming), TimeLeft.hidden);
      tracker.dispose();
    });

    testWidgets('a new incoming session starts from nothing', (tester) async {
      final tracker = TimeLeftTracker(clock: _clockOf(tester));
      var bytes = _rate;
      tracker.update(_receiving(bytes));
      for (var step = 0; step < 6; step++) {
        await tester.pump(_half);
        bytes += _rate;
        tracker.update(_receiving(bytes));
        await tester.pump(_half);
      }
      expect(
        tracker.readingOf(ProgressTrack.incoming),
        isA<TimeLeftRemaining>(),
      );
      tracker.update(
        NodeState(
          incoming: incomingView(
            id: 's2',
            stage: IncomingStage.receiving,
            received: bytes + _rate,
            size: _size,
          ),
        ),
      );
      expect(tracker.readingOf(ProgressTrack.incoming), TimeLeft.hidden);
      tracker.dispose();
    });
  });

  group('E911 it only notifies when what is painted changes', () {
    testWidgets('states that paint the same do not notify', (tester) async {
      final tracker = TimeLeftTracker(clock: _clockOf(tester));
      tracker.update(null);
      var notified = 0;
      tracker.addListener(() => notified++);
      tracker.update(null);
      tracker.update(_sending(0));
      tracker.update(_sending(0));
      expect(notified, 0);
      tracker.dispose();
    });

    testWidgets('bytes before the 5 s do not notify', (tester) async {
      final tracker = TimeLeftTracker(clock: _clockOf(tester));
      tracker.update(null);
      var notified = 0;
      tracker.addListener(() => notified++);
      var bytes = _rate;
      tracker.update(_sending(bytes));
      for (var step = 0; step < 4; step++) {
        await tester.pump(_half);
        bytes += _rate;
        tracker.update(_sending(bytes));
        await tester.pump(_half);
      }
      expect(notified, 0);
      tracker.dispose();
    });

    testWidgets('a time that reads the same does not notify again', (
      tester,
    ) async {
      final tracker = TimeLeftTracker(clock: _clockOf(tester));
      tracker.update(null);
      var notified = 0;
      tracker.addListener(() => notified++);
      const size = 300000000;
      var bytes = _rate;
      tracker.update(
        NodeState(
          outgoing: outgoingView(sent: bytes, size: size),
        ),
      );
      for (var step = 0; step < 20; step++) {
        await tester.pump(_half);
        bytes += _rate;
        tracker.update(
          NodeState(
            outgoing: outgoingView(sent: bytes, size: size),
          ),
        );
        await tester.pump(_half);
      }
      expect(
        tracker.readingOf(ProgressTrack.outgoing),
        isA<TimeLeftRemaining>(),
      );
      expect(notified, 1);
      tracker.dispose();
    });

    testWidgets('the timer does not notify while nothing changes', (
      tester,
    ) async {
      final tracker = TimeLeftTracker(clock: _clockOf(tester));
      await _flow(tester, tracker);
      await tester.pump(const Duration(seconds: 3));
      expect(tracker.readingOf(ProgressTrack.outgoing), TimeLeft.calculating);
      var notified = 0;
      tracker.addListener(() => notified++);
      await tester.pump(const Duration(seconds: 30));
      expect(notified, 0);
      tracker.dispose();
    });

    testWidgets('every real change notifies once', (tester) async {
      final tracker = TimeLeftTracker(clock: _clockOf(tester));
      await _flow(tester, tracker, seconds: 4);
      final painted = <String>[];
      tracker.addListener(
        () => painted.add(switch (tracker.readingOf(ProgressTrack.outgoing)) {
          TimeLeftHidden() => 'hidden',
          TimeLeftCalculating() => 'calculating',
          TimeLeftRemaining(:final value) => '${formatTimeLeft(value)}',
        }),
      );
      await _flow(tester, tracker, from: 50000, seconds: 2);
      await tester.pump(const Duration(seconds: 4));
      tracker.update(null);
      expect(painted.first, endsWith('min'));
      expect(painted.sublist(painted.length - 2), ['calculating', 'hidden']);
      for (var index = 1; index < painted.length; index++) {
        expect(painted[index], isNot(painted[index - 1]));
      }
      tracker.dispose();
    });
  });

  group('update during didUpdateWidget', () {
    testWidgets('a parent with setState never hits setState during build', (
      tester,
    ) async {
      final key = GlobalKey<_ParentState>();
      await tester.pumpWidget(
        _Parent(key: key, initial: _sending(_rate), clock: _clockOf(tester)),
      );
      expect(find.text('hidden'), findsOneWidget);
      var bytes = _rate;
      for (var step = 0; step < 6; step++) {
        await tester.pump(_half);
        await tester.pump(_half);
        bytes += _rate;
        key.currentState!.show(_sending(bytes));
        await tester.pump();
        expect(tester.takeException(), isNull);
      }
      expect(find.text('remaining'), findsOneWidget);
      key.currentState!.show(_sending(bytes, cancelling: true));
      await tester.pump();
      expect(tester.takeException(), isNull);
      expect(find.text('hidden'), findsOneWidget);
    });

    testWidgets('the shape of HomeScreen never hits setState during build', (
      tester,
    ) async {
      final strings = stringsFor('en');
      final controller = FakeAppController(state: _sending(_rate));
      final clock = _clockOf(tester);
      setWindow(tester, const Size(800, 600));
      await tester.pumpWidget(
        columnApp(
          controller,
          'en',
          (_) => ListenableBuilder(
            listenable: controller,
            builder: (context, child) => SelectionProgressScope(
              state: controller.state,
              child: TimeLeftScope(
                state: controller.state,
                clock: clock,
                child: child!,
              ),
            ),
            child: ListenableBuilder(
              listenable: controller,
              builder: (context, _) => ActivityPanel(
                controller: controller,
                state: controller.state ?? const NodeState(),
              ),
            ),
          ),
        ),
      );
      var bytes = _rate;
      for (var step = 0; step < 6; step++) {
        await tester.pump(_half);
        bytes += _rate;
        controller.emit(_sending(bytes));
        await tester.pump();
        expect(tester.takeException(), isNull);
        await tester.pump(_half);
      }
      expect(find.text(strings.arrivesIn('5 min')), findsOneWidget);
      controller.emit(_sending(bytes, cancelling: true));
      await tester.pump();
      expect(tester.takeException(), isNull);
      expect(find.text(strings.arrivesIn('5 min')), findsNothing);
    });
  });
}
