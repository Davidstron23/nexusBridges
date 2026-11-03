import 'dart:math' as math;

const double _displayCap = 0.999;
const Duration _minSpan = Duration(milliseconds: 250);
const double _restStep = 1e-5;

double _seconds(Duration duration) => duration.inMicroseconds / 1e6;

final class SmoothedProgress {
  SmoothedProgress({
    this.window = const Duration(seconds: 3),
    this.catchUpSeconds = 1.5,
    this.aheadMargin = 0.02,
    this.maxSpeed = 0.5,
    this.stallAfter = const Duration(seconds: 1),
    this.stallDecaySeconds = 0.7,
    this.finishGlide = const Duration(milliseconds: 400),
    this.maxFrame = const Duration(milliseconds: 100),
  });

  final Duration window;
  final double catchUpSeconds;
  final double aheadMargin;
  final double maxSpeed;
  final Duration stallAfter;
  final double stallDecaySeconds;
  final Duration finishGlide;
  final Duration maxFrame;

  final List<(Duration, int)> _samples = [];
  int? _selectionId;
  double _shown = 0;
  double _velocity = 0;
  double _real = 0;
  double _steady = 0;
  int _lastDone = 0;
  Duration _lastAdvance = Duration.zero;
  Duration _lastProgressAt = Duration.zero;
  Duration? _glideStart;
  double _glideFrom = 0;
  bool _atRest = true;

  double get value => _shown;

  double get steady => _steady;

  bool get atRest => _atRest;

  bool get gliding => _glideStart != null && _shown < 1;

  void observe({
    required int selectionId,
    required int doneBytes,
    required int totalBytes,
    required bool finished,
    required Duration at,
  }) {
    if (selectionId != _selectionId) {
      _selectionId = selectionId;
      _samples.clear();
      _shown = 0;
      _velocity = 0;
      _real = 0;
      _steady = 0;
      _lastDone = 0;
      _lastAdvance = at;
      _lastProgressAt = at;
      _glideStart = null;
      _glideFrom = 0;
    }
    _samples.add((at, doneBytes));
    while (_samples.isNotEmpty && at - _samples.first.$1 > window) {
      _samples.removeAt(0);
    }
    _real = totalBytes > 0
        ? math.min(doneBytes / totalBytes, 1.0)
        : (finished ? 1.0 : 0.0);
    if (doneBytes > _lastDone) {
      _lastDone = doneBytes;
      _lastProgressAt = at;
    }
    if (_samples.length >= 2 && totalBytes > 0) {
      final first = _samples.first;
      final last = _samples.last;
      final span = last.$1 - first.$1;
      if (span >= _minSpan && last.$2 >= first.$2) {
        _velocity = (last.$2 - first.$2) / _seconds(span) / totalBytes;
      }
    }
    _steady = math.max(_steady, finished ? 1.0 : math.min(_real, _displayCap));
    if (finished && _glideStart == null) {
      _glideFrom = _shown;
      _glideStart = at;
    }
    _atRest = false;
  }

  double advance(Duration now) {
    if (_selectionId == null) return 0;
    var step = now - _lastAdvance;
    if (step.isNegative) step = Duration.zero;
    if (step > maxFrame) step = maxFrame;
    if (now > _lastAdvance) _lastAdvance = now;
    final dt = _seconds(step);

    final glideStart = _glideStart;
    if (glideStart != null) {
      final progress = (_seconds(now - glideStart) / _seconds(finishGlide))
          .clamp(0.0, 1.0);
      final eased = 1 - math.pow(1 - progress, 3);
      _shown = math.max(_shown, _glideFrom + (1 - _glideFrom) * eased);
      if (progress >= 1) {
        _shown = 1;
        _atRest = true;
      } else {
        _atRest = false;
      }
      return _shown;
    }

    if (now - _lastProgressAt > stallAfter) {
      _velocity *= math.exp(-dt / stallDecaySeconds);
    }
    final gap = _real - _shown;
    var speed = gap >= 0
        ? _velocity + gap / catchUpSeconds
        : _velocity * math.exp(gap / aheadMargin);
    speed = math.min(speed, maxSpeed);
    final before = _shown;
    _shown = math.max(_shown, math.min(_shown + speed * dt, _displayCap));
    if (dt > 0) _atRest = _shown - before < _restStep;
    return _shown;
  }
}
