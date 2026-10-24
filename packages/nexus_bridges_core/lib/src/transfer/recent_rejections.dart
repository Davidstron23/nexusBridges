import '../protocol/protocol.dart' show Limits;

const int _maxTrackedFingerprints = 256;

final class RecentRejections {
  RecentRejections({
    required this._clock,
    this._window = Limits.transferRecentRejection,
  });

  final Duration Function() _clock;
  final Duration _window;
  final Map<String, Duration> _recorded = {};

  void record(String fingerprint) {
    final now = _clock();
    _prune(now);
    _recorded
      ..remove(fingerprint)
      ..[fingerprint] = now;
    while (_recorded.length > _maxTrackedFingerprints) {
      _recorded.remove(_recorded.keys.first);
    }
  }

  bool blocks(String fingerprint) {
    final now = _clock();
    _prune(now);
    final recordedAt = _recorded[fingerprint];
    return recordedAt != null && now - recordedAt < _window;
  }

  void _prune(Duration now) {
    _recorded.removeWhere((_, recordedAt) => now - recordedAt >= _window);
  }
}
