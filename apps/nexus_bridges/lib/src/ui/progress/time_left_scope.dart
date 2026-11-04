import 'dart:async';

import 'package:flutter/material.dart';
import 'package:nexus_bridges_core/nexus_bridges_core.dart';

import '../../l10n/app_strings.dart';
import '../format.dart';
import '../theme/app_theme.dart';
import '../theme/tokens.dart';
import 'selection_progress_painter.dart';
import 'time_left.dart';

typedef TimeLeftClock = Duration Function();

const Duration _watchInterval = Duration(seconds: 1);

const double timeLeftLowering = 3;

String _paintedKey(TimeLeft reading) => switch (reading) {
  TimeLeftHidden() => 'hidden',
  TimeLeftCalculating() => 'calculating',
  TimeLeftRemaining(:final value) => 'remaining:${formatTimeLeft(value)}',
};

final class _Feed {
  bool active = false;
  int doneBytes = 0;
  int totalBytes = 0;
  Object? identity;
}

final class TimeLeftTracker extends ChangeNotifier {
  TimeLeftTracker({TimeLeftClock? clock}) : _clock = clock ?? _stopwatchClock();

  final TimeLeftClock _clock;
  final TimeLeftEstimator _outgoing = TimeLeftEstimator();
  final TimeLeftEstimator _incoming = TimeLeftEstimator();
  final _Feed _outgoingFeed = _Feed();
  final _Feed _incomingFeed = _Feed();
  Timer? _timer;
  String _painted = '';
  bool _disposed = false;

  static TimeLeftClock _stopwatchClock() {
    final stopwatch = Stopwatch()..start();
    return () => stopwatch.elapsed;
  }

  bool get watching => _timer != null;

  TimeLeft readingOf(ProgressTrack track) =>
      (track == ProgressTrack.outgoing ? _outgoing : _incoming).reading;

  void update(NodeState? state) {
    if (_disposed) return;
    final outgoing = state?.outgoing;
    _feed(
      _outgoingFeed,
      _outgoing,
      active:
          outgoing != null &&
          outgoing.phase == OutgoingPhase.uploading &&
          !outgoing.cancelling &&
          outgoing.sentBytes < outgoing.size,
      doneBytes: outgoing?.sentBytes ?? 0,
      totalBytes: outgoing?.size ?? 0,
      identity: outgoing == null
          ? null
          : (outgoing.peerFingerprint, outgoing.fileName),
    );
    final incoming = state?.incoming;
    _feed(
      _incomingFeed,
      _incoming,
      active:
          incoming != null &&
          incoming.stage == IncomingStage.receiving &&
          incoming.receivedBytes < incoming.size,
      doneBytes: incoming?.receivedBytes ?? 0,
      totalBytes: incoming?.size ?? 0,
      identity: incoming?.sessionId,
    );
    _observe(_clock());
    _syncTimer();
    _notifyIfChanged();
  }

  void _feed(
    _Feed feed,
    TimeLeftEstimator estimator, {
    required bool active,
    required int doneBytes,
    required int totalBytes,
    required Object? identity,
  }) {
    if (feed.identity != identity) {
      estimator.observe(
        active: false,
        doneBytes: 0,
        totalBytes: 0,
        at: _clock(),
      );
    }
    feed
      ..active = active
      ..doneBytes = doneBytes
      ..totalBytes = totalBytes
      ..identity = identity;
  }

  void _observe(Duration at) {
    _outgoing.observe(
      active: _outgoingFeed.active,
      doneBytes: _outgoingFeed.doneBytes,
      totalBytes: _outgoingFeed.totalBytes,
      at: at,
    );
    _incoming.observe(
      active: _incomingFeed.active,
      doneBytes: _incomingFeed.doneBytes,
      totalBytes: _incomingFeed.totalBytes,
      at: at,
    );
  }

  void _syncTimer() {
    final anyActive = _outgoingFeed.active || _incomingFeed.active;
    if (anyActive && _timer == null) {
      _timer = Timer.periodic(_watchInterval, (_) => _watch());
    } else if (!anyActive && _timer != null) {
      _timer!.cancel();
      _timer = null;
    }
  }

  void _watch() {
    _observe(_clock());
    _notifyIfChanged();
  }

  void _notifyIfChanged() {
    final painted =
        '${_paintedKey(_outgoing.reading)}|${_paintedKey(_incoming.reading)}';
    if (painted == _painted) return;
    _painted = painted;
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _timer?.cancel();
    _timer = null;
    super.dispose();
  }
}

class TimeLeftScope extends StatefulWidget {
  const TimeLeftScope({
    required this.state,
    required this.child,
    this.clock,
    this.source,
    this.read,
    super.key,
  });

  final NodeState? state;
  final Widget child;
  final TimeLeftClock? clock;
  final Listenable? source;
  final NodeState? Function()? read;

  static TimeLeftTracker? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<_TimeLeftHolder>()?.tracker;

  @override
  State<TimeLeftScope> createState() => _TimeLeftScopeState();
}

class _TimeLeftScopeState extends State<TimeLeftScope> {
  late final TimeLeftTracker _tracker;

  @override
  void initState() {
    super.initState();
    _tracker = TimeLeftTracker(clock: widget.clock);
    _tracker.update(widget.state);
    widget.source?.addListener(_onSource);
  }

  void _onSource() {
    final read = widget.read;
    if (read != null) _tracker.update(read());
  }

  @override
  void didUpdateWidget(TimeLeftScope oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.source, widget.source)) {
      oldWidget.source?.removeListener(_onSource);
      widget.source?.addListener(_onSource);
    }
    _tracker.update(widget.state);
  }

  @override
  void dispose() {
    widget.source?.removeListener(_onSource);
    _tracker.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return _TimeLeftHolder(tracker: _tracker, child: widget.child);
  }
}

class _TimeLeftHolder extends InheritedWidget {
  const _TimeLeftHolder({required this.tracker, required super.child});

  final TimeLeftTracker tracker;

  @override
  bool updateShouldNotify(_TimeLeftHolder oldWidget) =>
      !identical(oldWidget.tracker, tracker);
}

class TimeLeftLabel extends StatelessWidget {
  const TimeLeftLabel({required this.track, this.lowered = true, super.key});

  final ProgressTrack track;
  final bool lowered;

  @override
  Widget build(BuildContext context) {
    final tracker = TimeLeftScope.maybeOf(context);
    if (tracker == null) return const SizedBox.shrink();
    final colors = NbColors.of(context);
    final strings = AppStringsDelegate.of(context);
    return ListenableBuilder(
      listenable: tracker,
      builder: (context, _) {
        final reading = tracker.readingOf(track);
        final Widget text;
        switch (reading) {
          case TimeLeftHidden():
            return const SizedBox.shrink();
          case TimeLeftCalculating():
            text = Text(
              strings.calculatingTime,
              style: NbText.caption.copyWith(
                fontSize: 13,
                color: colors.textWeak,
              ),
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
            );
          case TimeLeftRemaining(:final value):
            final time = formatTimeLeft(value);
            text = Text(
              time == null
                  ? strings.arrivesInFewSeconds
                  : strings.arrivesIn(time),
              style: NbText.caption.copyWith(
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: colors.text,
              ),
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
            );
        }
        return lowered
            ? Transform.translate(
                offset: const Offset(0, timeLeftLowering),
                child: text,
              )
            : text;
      },
    );
  }
}
