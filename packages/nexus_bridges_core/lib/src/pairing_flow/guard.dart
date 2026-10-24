import '../protocol/protocol.dart' show Limits;

const int _pruneThreshold = 1024;

const Duration _signatureWindow = Duration(seconds: 1);

final class _Origin {
  final List<DateTime> hits = [];

  int mismatches = 0;

  DateTime? blockedUntil;
}

final class PairingGuard {
  PairingGuard({
    this._now = DateTime.now,
    this._maxRequests = Limits.pairingRequestsPerOrigin,
    this._window = Limits.pairingRequestWindow,
    this._mismatchLimit = Limits.pairingMismatchLimit,
    this._block = Limits.pairingBlock,
    this._maxOrigins = Limits.maxTrackedOrigins,
    this._globalLimit = Limits.pairingGlobalFailures,
    this._globalWindow = Limits.pairingGlobalWindow,
    this._signatureBudget = Limits.signatureChecksPerSecond,
  });

  final DateTime Function() _now;

  final int _maxRequests;

  final Duration _window;

  final int _mismatchLimit;

  final Duration _block;

  final int _maxOrigins;

  final int _globalLimit;

  final Duration _globalWindow;

  final int _signatureBudget;

  final Map<String, _Origin> _origins = {};

  final List<DateTime> _globalFailures = [];

  final List<DateTime> _signatureChecks = [];

  DateTime? _lastPrune;

  bool admit(String origin) {
    final now = _now();
    if (_origins.length > _pruneThreshold && _pruneDue(now)) _prune(now);
    var state = _origins.remove(origin);
    if (state == null) {
      if (!_makeRoom(now)) return false;
      state = _Origin();
    }
    _origins[origin] = state;
    final blocked = _isBlocked(state, now);
    final inWindow = state.hits
        .where((instant) => now.difference(instant) < _window)
        .length;
    state.hits.add(now);
    if (state.hits.length > _maxRequests) {
      state.hits.removeRange(0, state.hits.length - _maxRequests);
    }
    return !blocked && inWindow < _maxRequests;
  }

  void countMismatch(String origin) {
    final now = _now();
    var state = _origins[origin];
    if (state == null) {
      if (!_makeRoom(now)) return;
      state = _origins[origin] = _Origin();
    }
    state.mismatches++;
    if (state.mismatches >= _mismatchLimit) {
      state.blockedUntil = now.add(_block);
      state.mismatches = 0;
    }
  }

  void reset(String origin) {
    _origins[origin]?.mismatches = 0;
  }

  DateTime? countGlobalFailure(DateTime now) {
    _trimGlobalFailures(now);
    final wasBlocked = _globalFailures.length >= _globalLimit;
    _globalFailures.add(now);
    _trimGlobalFailures(now);
    if (!wasBlocked && _globalFailures.length >= _globalLimit) {
      return _globalFailures.first.add(_globalWindow);
    }
    return null;
  }

  bool globalBlocked(DateTime now) {
    _trimGlobalFailures(now);
    return _globalFailures.length >= _globalLimit;
  }

  bool allowSignatureCheck(DateTime now) {
    _signatureChecks.removeWhere(
      (instant) => now.difference(instant) >= _signatureWindow,
    );
    if (_signatureChecks.length >= _signatureBudget) return false;
    _signatureChecks.add(now);
    return true;
  }

  bool isBlocked(String origin) {
    final state = _origins[origin];
    return state != null && _isBlocked(state, _now());
  }

  void _trimGlobalFailures(DateTime now) {
    _globalFailures.removeWhere(
      (instant) => now.difference(instant) >= _globalWindow,
    );
    if (_globalFailures.length > _globalLimit) {
      _globalFailures.removeRange(0, _globalFailures.length - _globalLimit);
    }
  }

  bool _isBlocked(_Origin state, DateTime now) {
    final until = state.blockedUntil;
    if (until == null) return false;
    if (now.isBefore(until)) return true;
    state.blockedUntil = null;
    return false;
  }

  bool _makeRoom(DateTime now) {
    if (_origins.length < _maxOrigins) return true;
    _prune(now);
    if (_origins.length < _maxOrigins) return true;
    for (final entry in _origins.entries) {
      if (!_isBlocked(entry.value, now)) {
        _origins.remove(entry.key);
        return true;
      }
    }
    return false;
  }

  bool _pruneDue(DateTime now) {
    final last = _lastPrune;
    return last == null || now.difference(last) >= _window;
  }

  void _prune(DateTime now) {
    _lastPrune = now;
    _origins.removeWhere(
      (_, state) =>
          !_isBlocked(state, now) &&
          state.mismatches == 0 &&
          state.hits.every((instant) => now.difference(instant) >= _window),
    );
  }
}
