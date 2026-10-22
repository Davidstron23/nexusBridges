import 'dart:async';

const int _normalMaxActive = 6;
const int _normalMaxPerIp = 1;
const int _normalMaxQueue = 56;

const int _reverseMaxActive = 2;
const int _reverseMaxPerIp = 1;
const int _reverseMaxQueue = 8;
const int _reverseMaxQueuedPerIp = 2;

const int _pruneThreshold = 256;

String _pairKey(String fingerprint, String ip) => '$fingerprint@$ip';

final class _Job {
  _Job(this.fingerprint, this.ip, this.interfaceId, this.run);

  final String fingerprint;

  final String ip;

  final String interfaceId;

  final Future<void> Function() run;

  String get pair => _pairKey(fingerprint, ip);
}

final class _Lane {
  _Lane({
    required this.maxActive,
    required this.maxPerIp,
    required this.maxQueue,
    this.maxQueuedPerIp,
  });

  final int maxActive;

  final int maxPerIp;

  final int maxQueue;

  final int? maxQueuedPerIp;

  final List<_Job> queue = [];

  final Set<String> pairs = {};

  final Map<String, int> activePerIp = {};

  final Map<String, DateTime> failedAt = {};

  int active = 0;
}

final class VerificationGate {
  VerificationGate({
    this._failureCooldown = const Duration(seconds: 9),
    this._now = DateTime.now,
  });

  final Duration _failureCooldown;

  final DateTime Function() _now;

  final _Lane _normal = _Lane(
    maxActive: _normalMaxActive,
    maxPerIp: _normalMaxPerIp,
    maxQueue: _normalMaxQueue,
  );

  final _Lane _reverse = _Lane(
    maxActive: _reverseMaxActive,
    maxPerIp: _reverseMaxPerIp,
    maxQueue: _reverseMaxQueue,
    maxQueuedPerIp: _reverseMaxQueuedPerIp,
  );

  bool _cleared = false;

  int get active => _normal.active + _reverse.active;

  int get queued => _normal.queue.length + _reverse.queue.length;

  bool submit({
    required String fingerprint,
    required String ip,
    required String interfaceId,
    required Future<void> Function() job,
    bool reverse = false,
  }) {
    if (_cleared) return false;
    final lane = reverse ? _reverse : _normal;
    final pair = _pairKey(fingerprint, ip);
    if (lane.pairs.contains(pair)) return false;
    final failedAt = lane.failedAt[pair];
    if (failedAt != null) {
      if (_now().difference(failedAt) < _failureCooldown) return false;
      lane.failedAt.remove(pair);
    }
    if (lane.queue.length >= lane.maxQueue) return false;
    final maxQueuedPerIp = lane.maxQueuedPerIp;
    if (maxQueuedPerIp != null &&
        lane.queue.where((queued) => queued.ip == ip).length >=
            maxQueuedPerIp) {
      return false;
    }
    lane.pairs.add(pair);
    lane.queue.add(_Job(fingerprint, ip, interfaceId, job));
    _pump(lane);
    return true;
  }

  void markFailed(String fingerprint, String ip, {bool reverse = false}) {
    final lane = reverse ? _reverse : _normal;
    final now = _now();
    if (lane.failedAt.length > _pruneThreshold) {
      lane.failedAt.removeWhere(
        (_, failedAt) => now.difference(failedAt) >= _failureCooldown,
      );
    }
    lane.failedAt[_pairKey(fingerprint, ip)] = now;
  }

  void dropInterface(String interfaceId) {
    for (final lane in [_normal, _reverse]) {
      lane.queue.removeWhere((queued) {
        final drop = queued.interfaceId == interfaceId;
        if (drop) lane.pairs.remove(queued.pair);
        return drop;
      });
    }
  }

  void clear() {
    _cleared = true;
    for (final lane in [_normal, _reverse]) {
      for (final queued in lane.queue) {
        lane.pairs.remove(queued.pair);
      }
      lane.queue.clear();
    }
  }

  void _pump(_Lane lane) {
    var index = 0;
    while (!_cleared &&
        lane.active < lane.maxActive &&
        index < lane.queue.length) {
      final next = lane.queue[index];
      if ((lane.activePerIp[next.ip] ?? 0) >= lane.maxPerIp) {
        index++;
        continue;
      }
      lane.queue.removeAt(index);
      lane.active++;
      lane.activePerIp[next.ip] = (lane.activePerIp[next.ip] ?? 0) + 1;
      unawaited(_run(lane, next));
      index = 0;
    }
  }

  Future<void> _run(_Lane lane, _Job job) async {
    try {
      await job.run();
    } catch (_) {
      return;
    } finally {
      lane.active--;
      final perIp = (lane.activePerIp[job.ip] ?? 1) - 1;
      if (perIp <= 0) {
        lane.activePerIp.remove(job.ip);
      } else {
        lane.activePerIp[job.ip] = perIp;
      }
      lane.pairs.remove(job.pair);
      _pump(lane);
    }
  }
}
