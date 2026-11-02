import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';
import 'package:nexus_bridges_core/nexus_bridges_core.dart';

import 'smoothed_progress.dart';

enum ProgressTrack { outgoing, incoming }

typedef ProgressClock = Duration Function();

Duration frameClock() => SchedulerBinding.instance.currentSystemFrameTimeStamp;

bool _isIncomingActive(IncomingStage stage) =>
    stage == IncomingStage.waitingData ||
    stage == IncomingStage.receiving ||
    stage == IncomingStage.verifying;

final class ProgressTracker extends ChangeNotifier {
  ProgressTracker({ProgressClock? clock, SmoothedProgress Function()? create})
    : _clock = clock ?? frameClock,
      _outgoing = (create ?? SmoothedProgress.new)(),
      _incoming = (create ?? SmoothedProgress.new)();

  final ProgressClock _clock;
  final SmoothedProgress _outgoing;
  final SmoothedProgress _incoming;
  String? _session;
  int _sessionIndex = 0;

  bool reduceMotion = false;

  bool get atRest => reduceMotion || (_outgoing.atRest && _incoming.atRest);

  SmoothedProgress _track(ProgressTrack track) =>
      track == ProgressTrack.outgoing ? _outgoing : _incoming;

  double valueOf(ProgressTrack track) {
    final progress = _track(track);
    return reduceMotion ? progress.steady : progress.value;
  }

  bool glidingOf(ProgressTrack track) => !reduceMotion && _track(track).gliding;

  void update(NodeState? state) {
    if (state == null) return;
    final at = _clock();
    final selection = state.selectionProgress;
    if (selection != null) {
      _outgoing.observe(
        selectionId: selection.selectionId,
        doneBytes: selection.doneBytes,
        totalBytes: selection.totalBytes,
        finished: selection.finished,
        at: at,
      );
    }
    final incoming = state.incoming;
    if (incoming != null && _isIncomingActive(incoming.stage)) {
      if (incoming.sessionId != _session) {
        _session = incoming.sessionId;
        _sessionIndex++;
      }
      _incoming.observe(
        selectionId: _sessionIndex,
        doneBytes: incoming.receivedBytes,
        totalBytes: incoming.size,
        finished: false,
        at: at,
      );
    }
  }

  void tick() {
    final now = _clock();
    _outgoing.advance(now);
    _incoming.advance(now);
    notifyListeners();
  }
}

class SelectionProgressScope extends StatefulWidget {
  const SelectionProgressScope({
    required this.state,
    required this.child,
    this.clock,
    super.key,
  });

  final NodeState? state;
  final Widget child;
  final ProgressClock? clock;

  static ProgressTracker? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<_TrackerHolder>()?.tracker;

  @override
  State<SelectionProgressScope> createState() => _SelectionProgressScopeState();
}

class _SelectionProgressScopeState extends State<SelectionProgressScope>
    with SingleTickerProviderStateMixin {
  late final ProgressTracker _tracker;
  late final Ticker _ticker;

  @override
  void initState() {
    super.initState();
    _tracker = ProgressTracker(clock: widget.clock);
    _ticker = createTicker(_onTick);
    _tracker.update(widget.state);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _tracker.reduceMotion =
        MediaQuery.maybeOf(context)?.disableAnimations ?? false;
    _sync();
  }

  @override
  void didUpdateWidget(SelectionProgressScope oldWidget) {
    super.didUpdateWidget(oldWidget);
    _tracker.update(widget.state);
    _sync();
  }

  @override
  void dispose() {
    _ticker.dispose();
    _tracker.dispose();
    super.dispose();
  }

  void _onTick(Duration elapsed) {
    _tracker.tick();
    if (_tracker.atRest) _ticker.stop();
  }

  void _sync() {
    if (_tracker.atRest) {
      if (_ticker.isActive) _ticker.stop();
    } else if (!_ticker.isActive) {
      _ticker.start();
    }
  }

  @override
  Widget build(BuildContext context) {
    return _TrackerHolder(tracker: _tracker, child: widget.child);
  }
}

class _TrackerHolder extends InheritedWidget {
  const _TrackerHolder({required this.tracker, required super.child});

  final ProgressTracker tracker;

  @override
  bool updateShouldNotify(_TrackerHolder oldWidget) =>
      !identical(oldWidget.tracker, tracker);
}

class SelectionProgressBuilder extends StatelessWidget {
  const SelectionProgressBuilder({
    required this.track,
    required this.fallback,
    required this.builder,
    this.enabled = true,
    super.key,
  });

  final ProgressTrack track;
  final double fallback;
  final bool enabled;
  final Widget Function(BuildContext context, double value, bool gliding)
  builder;

  @override
  Widget build(BuildContext context) {
    final tracker = SelectionProgressScope.maybeOf(context);
    if (tracker == null || !enabled) return builder(context, fallback, false);
    return ListenableBuilder(
      listenable: tracker,
      builder: (context, _) =>
          builder(context, tracker.valueOf(track), tracker.glidingOf(track)),
    );
  }
}
