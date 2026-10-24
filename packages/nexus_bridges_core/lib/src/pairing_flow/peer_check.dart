import '../protocol/protocol.dart' show Limits;
import 'pairing_flow.dart' show PeerStatus;

final class _Schedule {
  _Schedule(this.address);

  final String address;

  DateTime? finishedAt;

  bool failed = false;
}

final class PeerCheckScheduler {
  PeerCheckScheduler({
    this._now = DateTime.now,
    this._interval = Limits.peerCheckInterval,
    this._retry = Limits.peerCheckRetry,
    this._maxInFlight = 2,
  });

  final DateTime Function() _now;

  final Duration _interval;

  final Duration _retry;

  final int _maxInFlight;

  final Map<String, _Schedule> _schedules = {};

  final Set<String> _inFlight = {};

  final Set<String> _mismatched = {};

  final Map<String, DateTime> _deferred = {};

  Set<String> get mismatched => Set.unmodifiable(_mismatched);

  List<String> due(Map<String, String> visiblePairedAddresses) {
    final now = _now();
    _deferred.removeWhere((_, until) => !until.isAfter(now));
    _schedules.removeWhere(
      (fingerprint, _) => !visiblePairedAddresses.containsKey(fingerprint),
    );
    final result = <String>[];
    for (final MapEntry(key: fingerprint, value: address)
        in visiblePairedAddresses.entries) {
      if (_inFlight.length >= _maxInFlight) break;
      if (_inFlight.contains(fingerprint)) continue;
      if (_deferred.containsKey(fingerprint)) continue;
      final schedule = _schedules[fingerprint];
      if (schedule != null && !_isDue(schedule, address, now)) continue;
      _schedules[fingerprint] = _Schedule(address);
      _inFlight.add(fingerprint);
      result.add(fingerprint);
    }
    return result;
  }

  void finished(String fingerprint, PeerStatus status) {
    _inFlight.remove(fingerprint);
    switch (status) {
      case PeerStatus.notPaired:
        _mismatched.add(fingerprint);
      case PeerStatus.paired:
        _mismatched.remove(fingerprint);
      case PeerStatus.unknown:
        break;
    }
    final schedule = _schedules[fingerprint];
    if (schedule == null) return;
    schedule.finishedAt = _now();
    schedule.failed = status == PeerStatus.unknown;
  }

  void deferUntil(String fingerprint, DateTime time) {
    if (!time.isAfter(_now())) {
      _deferred.remove(fingerprint);
      return;
    }
    _deferred[fingerprint] = time;
  }

  void clear(String fingerprint) {
    _mismatched.remove(fingerprint);
  }

  bool _isDue(_Schedule schedule, String address, DateTime now) {
    if (schedule.address != address) return true;
    final finishedAt = schedule.finishedAt;
    if (finishedAt == null) return false;
    return now.difference(finishedAt) >= (schedule.failed ? _retry : _interval);
  }
}
