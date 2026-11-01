import 'package:nexus_bridges_core/src/pairing/pairing.dart';
import 'package:nexus_bridges_core/src/protocol/protocol.dart';
import 'package:nexus_bridges_core/src/transfer/rate_limits.dart';
import 'package:test/test.dart';

const String peerA = 'aaaa';
const String peerB = 'bbbb';

const PeerRelation mine = PeerRelation.mine;
const PeerRelation foreign = PeerRelation.foreign;

final class FakeClock {
  Duration now = const Duration(hours: 5);

  Duration call() => now;

  void advance(Duration by) => now += by;
}

void main() {
  late FakeClock clock;
  late TransferRateLimiter limiter;

  setUp(() {
    clock = FakeClock();
    limiter = TransferRateLimiter(clock: clock.call);
  });

  int admitted(String peer, TransferRoute route, PeerRelation relation, int n) {
    var count = 0;
    for (var i = 0; i < n; i++) {
      if (limiter.check(peer, route, relation) == RateVerdict.allowed) count++;
    }
    return count;
  }

  group('E580 the limits per route and relation', () {
    test('limitFor gives the numbers of the plan', () {
      for (final route in TransferRoute.values) {
        expect(limiter.limitFor(route, mine), 300, reason: route.name);
      }
      expect(limiter.limitFor(TransferRoute.offer, foreign), 30);
      expect(limiter.limitFor(TransferRoute.wait, foreign), 120);
      expect(limiter.limitFor(TransferRoute.cancel, foreign), 30);
      expect(limiter.limitFor(TransferRoute.upload, foreign), 12);
      expect(limiter.limitFor(TransferRoute.manifest, foreign), 12);
    });

    test('the limits come from Limits, not from literals', () {
      expect(
        limiter.limitFor(TransferRoute.offer, mine),
        Limits.mineTransferRequestsPerMinute,
      );
      expect(
        limiter.limitFor(TransferRoute.manifest, foreign),
        Limits.foreignManifestsPerMinute,
      );
    });

    test('a mine peer gets 300 offers in a minute and the 301st is limited '
        'with a block of one minute', () {
      for (var i = 0; i < 300; i++) {
        expect(
          limiter.check(peerA, TransferRoute.offer, mine),
          RateVerdict.allowed,
          reason: 'request ${i + 1}',
        );
        clock.advance(const Duration(milliseconds: 100));
      }
      expect(
        limiter.check(peerA, TransferRoute.offer, mine),
        RateVerdict.limited,
      );
      expect(
        limiter.check(peerA, TransferRoute.offer, mine),
        RateVerdict.blocked,
      );
      clock.advance(const Duration(seconds: 59));
      expect(
        limiter.check(peerA, TransferRoute.offer, mine),
        RateVerdict.blocked,
      );
      clock.advance(const Duration(seconds: 2));
      expect(
        limiter.check(peerA, TransferRoute.offer, mine),
        RateVerdict.allowed,
      );
    });

    for (final (route, limit) in [
      (TransferRoute.offer, 30),
      (TransferRoute.wait, 120),
      (TransferRoute.cancel, 30),
      (TransferRoute.upload, 12),
      (TransferRoute.manifest, 12),
    ]) {
      test('a foreign peer gets $limit ${route.name} in a minute and the next '
          'is limited with a block', () {
        expect(admitted(peerA, route, foreign, limit), limit);
        expect(limiter.check(peerA, route, foreign), RateVerdict.limited);
        expect(limiter.check(peerA, route, foreign), RateVerdict.blocked);
        clock.advance(const Duration(seconds: 30));
        expect(limiter.check(peerA, route, foreign), RateVerdict.blocked);
        clock.advance(const Duration(seconds: 31));
        expect(limiter.check(peerA, route, foreign), RateVerdict.allowed);
      });
    }

    test('each route has its own account', () {
      expect(admitted(peerA, TransferRoute.upload, foreign, 12), 12);
      expect(
        limiter.check(peerA, TransferRoute.upload, foreign),
        RateVerdict.limited,
      );
      expect(
        limiter.check(peerA, TransferRoute.offer, foreign),
        RateVerdict.allowed,
      );
      expect(
        limiter.check(peerA, TransferRoute.manifest, foreign),
        RateVerdict.allowed,
      );
    });

    test('the limiter never throws, whatever the order of calls', () {
      limiter
        ..forget(peerA)
        ..relationChanged(peerA, mine, foreign)
        ..relationChanged(peerA, foreign, foreign);
      expect(limiter.hasRoom(peerA, TransferRoute.offer, foreign), isTrue);
      expect(
        limiter.check(peerA, TransferRoute.offer, foreign),
        RateVerdict.allowed,
      );
    });
  });

  group('E581 counts are per fingerprint and the window slides', () {
    test('two peers have independent accounts', () {
      expect(admitted(peerA, TransferRoute.upload, foreign, 12), 12);
      expect(
        limiter.check(peerA, TransferRoute.upload, foreign),
        RateVerdict.limited,
      );
      expect(
        limiter.check(peerB, TransferRoute.upload, foreign),
        RateVerdict.allowed,
      );
      expect(limiter.hasRoom(peerB, TransferRoute.upload, foreign), isTrue);
      expect(limiter.hasRoom(peerA, TransferRoute.upload, foreign), isFalse);
    });

    test('60 s after the first request there is room again', () {
      expect(admitted(peerA, TransferRoute.cancel, foreign, 1), 1);
      clock.advance(const Duration(seconds: 20));
      expect(admitted(peerA, TransferRoute.cancel, foreign, 29), 29);
      expect(limiter.hasRoom(peerA, TransferRoute.cancel, foreign), isFalse);
      clock.advance(const Duration(seconds: 39));
      expect(limiter.hasRoom(peerA, TransferRoute.cancel, foreign), isFalse);
      clock.advance(const Duration(seconds: 1));
      expect(limiter.hasRoom(peerA, TransferRoute.cancel, foreign), isTrue);
      expect(
        limiter.check(peerA, TransferRoute.cancel, foreign),
        RateVerdict.allowed,
      );
      expect(
        limiter.check(peerA, TransferRoute.cancel, foreign),
        RateVerdict.limited,
      );
    });

    test('hasRoom neither counts nor blocks', () {
      expect(admitted(peerA, TransferRoute.upload, foreign, 12), 12);
      for (var i = 0; i < 50; i++) {
        expect(limiter.hasRoom(peerA, TransferRoute.upload, foreign), isFalse);
      }
      clock.advance(const Duration(seconds: 61));
      expect(
        limiter.check(peerA, TransferRoute.upload, foreign),
        RateVerdict.allowed,
      );
      expect(admitted(peerB, TransferRoute.upload, foreign, 11), 11);
      expect(limiter.hasRoom(peerB, TransferRoute.upload, foreign), isTrue);
      expect(limiter.hasRoom(peerB, TransferRoute.upload, foreign), isTrue);
      expect(
        limiter.check(peerB, TransferRoute.upload, foreign),
        RateVerdict.allowed,
      );
    });

    test('memory stays bounded by the limit of the account', () {
      for (var i = 0; i < 2000; i++) {
        limiter.check(peerA, TransferRoute.offer, mine);
      }
      expect(
        limiter.check(peerA, TransferRoute.offer, mine),
        RateVerdict.blocked,
      );
      clock.advance(const Duration(minutes: 5));
      expect(admitted(peerA, TransferRoute.offer, mine, 400), 300);
    });
  });

  group('E582 from mine to foreign in the middle of the window', () {
    test('40 offers admitted as mine: the next one as foreign is limited '
        'without a block, and room returns as the marks fall', () {
      for (var i = 0; i < 40; i++) {
        expect(
          limiter.check(peerA, TransferRoute.offer, mine),
          RateVerdict.allowed,
        );
        clock.advance(const Duration(seconds: 1));
      }
      limiter.relationChanged(peerA, mine, foreign);
      expect(
        limiter.check(peerA, TransferRoute.offer, foreign),
        RateVerdict.limited,
      );
      expect(
        limiter.check(peerA, TransferRoute.offer, foreign),
        RateVerdict.limited,
      );
      expect(limiter.hasRoom(peerA, TransferRoute.offer, foreign), isFalse);
      clock.advance(const Duration(seconds: 29));
      expect(limiter.hasRoom(peerA, TransferRoute.offer, foreign), isFalse);
      clock.advance(const Duration(seconds: 1));
      expect(
        limiter.check(peerA, TransferRoute.offer, foreign),
        RateVerdict.allowed,
        reason: 'the marks fell below 30 and no block was started',
      );
    });

    test('an excess after more than a minute as foreign does block', () {
      expect(admitted(peerA, TransferRoute.offer, mine, 40), 40);
      limiter.relationChanged(peerA, mine, foreign);
      expect(
        limiter.check(peerA, TransferRoute.offer, foreign),
        RateVerdict.limited,
      );
      clock.advance(const Duration(seconds: 61));
      expect(admitted(peerA, TransferRoute.offer, foreign, 30), 30);
      expect(
        limiter.check(peerA, TransferRoute.offer, foreign),
        RateVerdict.limited,
      );
      expect(
        limiter.check(peerA, TransferRoute.offer, foreign),
        RateVerdict.blocked,
      );
    });

    test('an excess made only of requests after the change does block', () {
      limiter.relationChanged(peerA, mine, foreign);
      expect(admitted(peerA, TransferRoute.upload, foreign, 12), 12);
      expect(
        limiter.check(peerA, TransferRoute.upload, foreign),
        RateVerdict.limited,
      );
      expect(
        limiter.check(peerA, TransferRoute.upload, foreign),
        RateVerdict.blocked,
      );
    });

    test('Q-4: 30 offers after the change fill the foreign limit by '
        'themselves, so the 31st blocks and the block outlives the minute', () {
      limiter.relationChanged(peerA, mine, foreign);
      for (var i = 0; i < 30; i++) {
        clock.advance(const Duration(seconds: 1));
        expect(
          limiter.check(peerA, TransferRoute.offer, foreign),
          RateVerdict.allowed,
        );
      }
      clock.advance(const Duration(seconds: 1));
      expect(
        limiter.check(peerA, TransferRoute.offer, foreign),
        RateVerdict.limited,
      );
      clock.advance(const Duration(seconds: 30));
      expect(
        limiter.check(peerA, TransferRoute.offer, foreign),
        RateVerdict.blocked,
      );
      clock.advance(const Duration(seconds: 61));
      expect(
        limiter.check(peerA, TransferRoute.offer, foreign),
        RateVerdict.allowed,
      );
    });

    test('Q-4: marks admitted as mine before the change are forgiven while '
        'the foreign ones after it stay under the limit', () {
      expect(admitted(peerA, TransferRoute.offer, mine, 40), 40);
      limiter.relationChanged(peerA, mine, foreign);
      clock.advance(const Duration(seconds: 1));
      for (var i = 0; i < 5; i++) {
        expect(
          limiter.check(peerA, TransferRoute.offer, foreign),
          RateVerdict.limited,
        );
      }
      expect(limiter.hasRoom(peerA, TransferRoute.offer, foreign), isFalse);
      clock.advance(const Duration(seconds: 60));
      expect(
        limiter.check(peerA, TransferRoute.offer, foreign),
        RateVerdict.allowed,
      );
    });

    test('Q-4: foreign marks that fall into the window next to the forgiven '
        'ones still count towards the limit on their own', () {
      expect(admitted(peerA, TransferRoute.offer, mine, 25), 25);
      limiter.relationChanged(peerA, mine, foreign);
      clock.advance(const Duration(seconds: 1));
      expect(admitted(peerA, TransferRoute.offer, foreign, 5), 5);
      expect(
        limiter.check(peerA, TransferRoute.offer, foreign),
        RateVerdict.limited,
      );
      expect(
        limiter.check(peerA, TransferRoute.offer, foreign),
        RateVerdict.limited,
      );
      clock.advance(const Duration(seconds: 59));
      expect(admitted(peerA, TransferRoute.offer, foreign, 25), 25);
      expect(
        limiter.check(peerA, TransferRoute.offer, foreign),
        RateVerdict.limited,
      );
      expect(
        limiter.check(peerA, TransferRoute.offer, foreign),
        RateVerdict.blocked,
      );
    });

    test('a block started as mine survives the change to foreign', () {
      for (var i = 0; i < 301; i++) {
        limiter.check(peerA, TransferRoute.offer, mine);
      }
      limiter.relationChanged(peerA, mine, foreign);
      expect(
        limiter.check(peerA, TransferRoute.offer, foreign),
        RateVerdict.blocked,
      );
    });

    test('the marks of upload, which were reserved as mine, count as foreign '
        'too', () {
      expect(admitted(peerA, TransferRoute.upload, mine, 20), 20);
      limiter.relationChanged(peerA, mine, foreign);
      expect(limiter.hasRoom(peerA, TransferRoute.upload, foreign), isFalse);
      clock.advance(const Duration(seconds: 61));
      expect(limiter.hasRoom(peerA, TransferRoute.upload, foreign), isTrue);
    });
  });

  group('E583 from foreign to mine', () {
    test('a block in progress lasts until it expires, then 300 are valid', () {
      expect(admitted(peerA, TransferRoute.offer, foreign, 30), 30);
      expect(
        limiter.check(peerA, TransferRoute.offer, foreign),
        RateVerdict.limited,
      );
      limiter.relationChanged(peerA, foreign, mine);
      expect(
        limiter.check(peerA, TransferRoute.offer, mine),
        RateVerdict.blocked,
      );
      clock.advance(const Duration(seconds: 59));
      expect(
        limiter.check(peerA, TransferRoute.offer, mine),
        RateVerdict.blocked,
      );
      clock.advance(const Duration(seconds: 2));
      expect(admitted(peerA, TransferRoute.offer, mine, 300), 300);
      expect(
        limiter.check(peerA, TransferRoute.offer, mine),
        RateVerdict.limited,
      );
    });

    test('without a block the limit of 300 is valid on the next request', () {
      expect(admitted(peerA, TransferRoute.offer, foreign, 30), 30);
      limiter.relationChanged(peerA, foreign, mine);
      expect(admitted(peerA, TransferRoute.offer, mine, 270), 270);
      expect(
        limiter.check(peerA, TransferRoute.offer, mine),
        RateVerdict.limited,
      );
    });

    test('going back to mine cancels the no-block mark of the downgrade', () {
      expect(admitted(peerA, TransferRoute.offer, mine, 40), 40);
      limiter
        ..relationChanged(peerA, mine, foreign)
        ..relationChanged(peerA, foreign, mine);
      expect(admitted(peerA, TransferRoute.offer, mine, 260), 260);
      expect(
        limiter.check(peerA, TransferRoute.offer, mine),
        RateVerdict.limited,
      );
      expect(
        limiter.check(peerA, TransferRoute.offer, mine),
        RateVerdict.blocked,
      );
    });
  });

  group('E584 forget on unpairing', () {
    test('forget wipes the counts and the blocks of that fingerprint only', () {
      expect(admitted(peerA, TransferRoute.upload, foreign, 12), 12);
      expect(
        limiter.check(peerA, TransferRoute.upload, foreign),
        RateVerdict.limited,
      );
      expect(admitted(peerB, TransferRoute.upload, foreign, 12), 12);
      limiter.forget(peerA);
      expect(limiter.hasRoom(peerA, TransferRoute.upload, foreign), isTrue);
      expect(admitted(peerA, TransferRoute.upload, foreign, 12), 12);
      expect(limiter.hasRoom(peerB, TransferRoute.upload, foreign), isFalse);
    });

    test('forget also drops the no-block mark of a downgrade', () {
      expect(admitted(peerA, TransferRoute.offer, mine, 40), 40);
      limiter
        ..relationChanged(peerA, mine, foreign)
        ..forget(peerA);
      expect(admitted(peerA, TransferRoute.offer, foreign, 30), 30);
      expect(
        limiter.check(peerA, TransferRoute.offer, foreign),
        RateVerdict.limited,
      );
      expect(
        limiter.check(peerA, TransferRoute.offer, foreign),
        RateVerdict.blocked,
      );
    });
  });
}
