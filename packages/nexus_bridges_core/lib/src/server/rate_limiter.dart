import '../protocol/protocol.dart' show Limits;

const int _pruneThreshold = 1024;

final class RateLimiter {
  RateLimiter({
    required this.maxPerWindow,
    required this.window,
    required this.block,
    required this._now,
    this.maxKeys = Limits.maxTrackedOrigins,
  });

  final int maxPerWindow;

  final Duration window;

  final Duration block;

  final int maxKeys;

  final DateTime Function() _now;

  final Map<String, List<DateTime>> _hits = {};

  final Map<String, DateTime> _blockedUntil = {};

  DateTime? _lastPrune;

  bool allow(String key) {
    final now = _now();
    if (_hits.length > _pruneThreshold && _pruneDue(now)) _prune(now);
    final blockedUntil = _blockedUntil[key];
    if (blockedUntil != null) {
      if (now.isBefore(blockedUntil)) return false;
      _blockedUntil.remove(key);
      _hits.remove(key);
    }
    var hits = _hits.remove(key);
    if (hits == null) {
      if (!_makeRoom(now)) return false;
      hits = <DateTime>[];
    }
    _hits[key] = hits;
    hits.removeWhere((instant) => now.difference(instant) >= window);
    hits.add(now);
    if (hits.length > maxPerWindow) {
      _blockedUntil[key] = now.add(block);
      hits.clear();
      return false;
    }
    return true;
  }

  bool _makeRoom(DateTime now) {
    if (_hits.length < maxKeys) return true;
    _prune(now);
    if (_hits.length < maxKeys) return true;
    for (final key in _hits.keys) {
      if (!_blockedUntil.containsKey(key)) {
        _hits.remove(key);
        return true;
      }
    }
    return false;
  }

  bool _pruneDue(DateTime now) {
    final last = _lastPrune;
    return last == null || now.difference(last) >= window;
  }

  void _prune(DateTime now) {
    _lastPrune = now;
    _blockedUntil.removeWhere((_, until) => !now.isBefore(until));
    _hits.removeWhere(
      (key, hits) =>
          !_blockedUntil.containsKey(key) &&
          hits.every((instant) => now.difference(instant) >= window),
    );
  }
}
