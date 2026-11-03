const int _maxKeys = 32;

final class SlidingWindowLimiter {
  SlidingWindowLimiter({
    required this._limit,
    required this._window,
    required this._clock,
  });

  final int _limit;
  final Duration _window;
  final Duration Function() _clock;
  final Map<String, List<Duration>> _marks = {};

  bool tryAcquire(String key) {
    final now = _clock();
    _prune(now);
    final marks = _marks.remove(key) ?? <Duration>[];
    if (marks.length >= _limit) {
      _marks[key] = marks;
      return false;
    }
    if (marks.isEmpty && _marks.length >= _maxKeys) {
      _marks.remove(_marks.keys.first);
    }
    marks.add(now);
    _marks[key] = marks;
    return true;
  }

  void forget(String key) => _marks.remove(key);

  void _prune(Duration now) {
    _marks.removeWhere((_, marks) {
      marks.removeWhere((mark) => now - mark >= _window);
      return marks.isEmpty;
    });
  }
}
