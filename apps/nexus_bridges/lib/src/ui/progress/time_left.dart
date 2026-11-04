sealed class TimeLeft {
  const TimeLeft();

  const factory TimeLeft.remaining(Duration value) = TimeLeftRemaining;

  static const TimeLeft hidden = TimeLeftHidden();

  static const TimeLeft calculating = TimeLeftCalculating();
}

final class TimeLeftHidden extends TimeLeft {
  const TimeLeftHidden();
}

final class TimeLeftCalculating extends TimeLeft {
  const TimeLeftCalculating();
}

final class TimeLeftRemaining extends TimeLeft {
  const TimeLeftRemaining(this.value);

  final Duration value;

  @override
  bool operator ==(Object other) =>
      other is TimeLeftRemaining && other.value == value;

  @override
  int get hashCode => value.hashCode;
}

class _Sample {
  const _Sample(this.at, this.doneBytes);

  final Duration at;
  final int doneBytes;
}

final class TimeLeftEstimator {
  static const Duration window = Duration(seconds: 12);
  static const Duration showAfter = Duration(seconds: 5);
  static const Duration stall = Duration(seconds: 3);
  static const Duration minimumSpan = Duration(seconds: 2);
  static const Duration refresh = Duration(seconds: 1);
  static const double tolerance = 0.15;

  final List<_Sample> _samples = [];
  Duration? _startedAt;
  Duration _lastMove = Duration.zero;
  int _lastDone = 0;
  Duration _nextRefresh = Duration.zero;
  double? _shownSeconds;
  TimeLeft _reading = TimeLeft.hidden;

  static const double tooLateToShow = 5;

  TimeLeft get reading => _reading;

  void observe({
    required bool active,
    required int doneBytes,
    required int totalBytes,
    required Duration at,
  }) {
    if (!active || totalBytes <= 0) {
      _reset();
      return;
    }
    if (doneBytes < _lastDone) _reset();
    final startedAt = _startedAt;
    if (startedAt == null) {
      if (doneBytes <= 0) return;
      _startedAt = at;
      _lastMove = at;
      _lastDone = doneBytes;
    } else if (doneBytes > _lastDone) {
      _lastMove = at;
      _lastDone = doneBytes;
    }
    _samples.add(_Sample(at, doneBytes));
    while (_samples.isNotEmpty && at - _samples.first.at > window) {
      _samples.removeAt(0);
    }
    _update(at, doneBytes, totalBytes);
  }

  void _update(Duration at, int doneBytes, int totalBytes) {
    final startedAt = _startedAt!;
    final visible = at - startedAt >= showAfter;
    if (at - _lastMove >= stall) {
      if (visible) _reading = TimeLeft.calculating;
      _shownSeconds = null;
      _samples.clear();
      return;
    }
    if (!visible) return;
    if (at < _nextRefresh) return;
    _nextRefresh = at + refresh;
    if (_samples.isEmpty) return;
    final first = _samples.first;
    final last = _samples.last;
    final span = last.at - first.at;
    if (span < minimumSpan) return;
    final speed =
        (last.doneBytes - first.doneBytes) /
        (span.inMicroseconds / Duration.microsecondsPerSecond);
    if (speed <= 0) return;
    final seconds = (totalBytes - doneBytes) / speed;
    if (_reading is TimeLeftHidden && seconds <= tooLateToShow) return;
    final shown = _shownSeconds;
    if (shown != null && seconds > shown && seconds < shown * (1 + tolerance)) {
      return;
    }
    _shownSeconds = seconds;
    _reading = TimeLeft.remaining(
      Duration(
        microseconds: (seconds * Duration.microsecondsPerSecond).round(),
      ),
    );
  }

  void _reset() {
    _samples.clear();
    _startedAt = null;
    _lastMove = Duration.zero;
    _lastDone = 0;
    _nextRefresh = Duration.zero;
    _shownSeconds = null;
    _reading = TimeLeft.hidden;
  }
}
