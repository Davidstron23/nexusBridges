import '../pairing/pairing.dart' show PeerRelation;
import '../protocol/protocol.dart' show Limits;

enum TransferRoute { offer, wait, cancel, upload, manifest }

enum RateVerdict { allowed, limited, blocked }

final class _Account {
  final List<Duration> hits = [];

  Duration? blockedUntil;
}

final class TransferRateLimiter {
  TransferRateLimiter({
    required this._clock,
    this._window = const Duration(minutes: 1),
    this._block = Limits.routeBlock,
  });

  final Duration Function() _clock;

  final Duration _window;

  final Duration _block;

  final Map<(String, TransferRoute), _Account> _accounts = {};

  final Map<String, Duration> _downgradedAt = {};

  int limitFor(TransferRoute route, PeerRelation relation) {
    if (relation == PeerRelation.mine) {
      return Limits.mineTransferRequestsPerMinute;
    }
    return switch (route) {
      TransferRoute.offer => Limits.transferOffersPerMinute,
      TransferRoute.wait => Limits.transferPollsPerMinute,
      TransferRoute.cancel => Limits.transferCancelsPerMinute,
      TransferRoute.upload => Limits.transferUploadsPerMinute,
      TransferRoute.manifest => Limits.foreignManifestsPerMinute,
    };
  }

  RateVerdict check(
    String fingerprint,
    TransferRoute route,
    PeerRelation relation,
  ) {
    final now = _clock();
    final account = _accounts.putIfAbsent((fingerprint, route), _Account.new);
    if (_stillBlocked(account, now)) return RateVerdict.blocked;
    _slide(account, now);
    if (account.hits.length < limitFor(route, relation)) {
      account.hits.add(now);
      return RateVerdict.allowed;
    }
    if (!_exceedFromDowngrade(fingerprint, now)) {
      account.blockedUntil = now + _block;
    }
    return RateVerdict.limited;
  }

  bool hasRoom(String fingerprint, TransferRoute route, PeerRelation relation) {
    final account = _accounts[(fingerprint, route)];
    if (account == null) return limitFor(route, relation) > 0;
    final now = _clock();
    if (_stillBlocked(account, now)) return false;
    _slide(account, now);
    return account.hits.length < limitFor(route, relation);
  }

  void relationChanged(String fingerprint, PeerRelation from, PeerRelation to) {
    if (from == to) return;
    if (from == PeerRelation.mine) {
      _downgradedAt[fingerprint] = _clock();
    } else {
      _downgradedAt.remove(fingerprint);
    }
  }

  void forget(String fingerprint) {
    _accounts.removeWhere((key, _) => key.$1 == fingerprint);
    _downgradedAt.remove(fingerprint);
  }

  bool _stillBlocked(_Account account, Duration now) {
    final until = account.blockedUntil;
    if (until == null) return false;
    if (now < until) return true;
    account.blockedUntil = null;
    return false;
  }

  void _slide(_Account account, Duration now) {
    account.hits.removeWhere((instant) => now - instant >= _window);
  }

  bool _exceedFromDowngrade(String fingerprint, Duration now) {
    final at = _downgradedAt[fingerprint];
    if (at == null) return false;
    if (now - at < _window) return true;
    _downgradedAt.remove(fingerprint);
    return false;
  }
}
