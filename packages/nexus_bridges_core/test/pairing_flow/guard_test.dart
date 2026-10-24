import 'package:nexus_bridges_core/src/pairing_flow/guard.dart';
import 'package:nexus_bridges_core/src/protocol/protocol.dart';
import 'package:test/test.dart';

final DateTime _start = DateTime.utc(2026, 10, 24, 12);

const String origin = '192.168.1.20';

void main() {
  late DateTime now;
  late PairingGuard guard;

  setUp(() {
    now = _start;
    guard = PairingGuard(now: () => now);
  });

  void at(Duration offset) => now = _start.add(offset);

  Duration minutes(int m, [int s = 0, int ms = 0]) =>
      Duration(minutes: m, seconds: s, milliseconds: ms);

  void block(String key) {
    for (var i = 0; i < 3; i++) {
      guard.countMismatch(key);
    }
  }

  group('sliding window (C34, RF-103, SEC-15)', () {
    test('the instants of the plan: 0 to 4 min pass, 5:00 and 10:30 are '
        'rejected, 12:00.001 passes', () {
      for (var m = 0; m < 5; m++) {
        at(minutes(m));
        expect(guard.admit(origin), isTrue, reason: 'minute $m');
      }

      at(minutes(5));
      expect(guard.admit(origin), isFalse);

      at(minutes(10, 30));
      expect(guard.admit(origin), isFalse);

      at(minutes(12, 0, 1));
      expect(guard.admit(origin), isTrue);
    });

    test('a request exactly 10 minutes old no longer counts', () {
      for (var i = 0; i < 5; i++) {
        expect(guard.admit(origin), isTrue);
      }

      at(minutes(9, 59, 999));
      expect(guard.admit(origin), isFalse);

      at(minutes(10));
      expect(guard.admit(origin), isTrue);
    });

    test('five in the same instant pass and the sixth is rejected', () {
      expect(
        [for (var i = 0; i < 5; i++) guard.admit(origin)],
        [true, true, true, true, true],
      );
      expect(guard.admit(origin), isFalse);
    });

    test('rejected requests also count: who keeps insisting stays rejected '
        'until 10 minutes pass without five in the window (R22)', () {
      for (var i = 0; i < 5; i++) {
        guard.admit(origin);
      }
      for (var m = 1; m <= 9; m++) {
        at(minutes(m));
        expect(guard.admit(origin), isFalse, reason: 'minute $m');
      }

      at(minutes(10));
      expect(guard.admit(origin), isFalse);

      at(minutes(15, 59, 999));
      expect(guard.admit(origin), isFalse);

      at(minutes(17));
      expect(guard.admit(origin), isTrue);
    });

    test('origins do not affect each other', () {
      for (var i = 0; i < 6; i++) {
        guard.admit(origin);
      }

      expect(guard.admit('192.168.1.21'), isTrue);
      expect(guard.admit(origin), isFalse);
    });

    test('admit does not change the mismatch streak nor block', () {
      for (var i = 0; i < 20; i++) {
        guard.admit(origin);
      }

      expect(guard.isBlocked(origin), isFalse);
      guard.countMismatch(origin);
      guard.countMismatch(origin);
      expect(guard.isBlocked(origin), isFalse);
    });

    test('the defaults are those of Limits: five per ten minutes', () {
      final other = PairingGuard(now: () => now);
      for (var i = 0; i < 5; i++) {
        expect(other.admit(origin), isTrue);
      }
      expect(other.admit(origin), isFalse);
    });
  });

  group('block after three mismatches (C35, RF-104, RF-105)', () {
    test('three mismatches block: admit at 9:59 is rejected and at 10:00 '
        'passes', () {
      block(origin);

      expect(guard.isBlocked(origin), isTrue);

      at(minutes(9, 59));
      expect(guard.admit(origin), isFalse);
      expect(guard.isBlocked(origin), isTrue);

      at(minutes(10));
      expect(guard.isBlocked(origin), isFalse);
      expect(guard.admit(origin), isTrue);
    });

    test('the block lasts until exactly 10 minutes after the third '
        'mismatch', () {
      guard.countMismatch(origin);
      at(minutes(1));
      guard.countMismatch(origin);
      at(minutes(5));
      guard.countMismatch(origin);

      at(minutes(14, 59, 999));
      expect(guard.isBlocked(origin), isTrue);
      expect(guard.admit(origin), isFalse);

      at(minutes(15));
      expect(guard.isBlocked(origin), isFalse);
      expect(guard.admit(origin), isTrue);
    });

    test('two mismatches do not block', () {
      guard.countMismatch(origin);
      guard.countMismatch(origin);

      expect(guard.isBlocked(origin), isFalse);
      expect(guard.admit(origin), isTrue);
    });

    test('the block works on an origin that never sent a request', () {
      block('10.0.0.9');

      expect(guard.isBlocked('10.0.0.9'), isTrue);
      expect(guard.admit('10.0.0.9'), isFalse);
    });

    test('the block is per origin', () {
      block(origin);

      expect(guard.isBlocked('192.168.1.21'), isFalse);
      expect(guard.admit('192.168.1.21'), isTrue);
    });

    test('after a block the streak starts again: three new mismatches are '
        'needed', () {
      block(origin);
      at(minutes(10));

      guard.countMismatch(origin);
      guard.countMismatch(origin);
      expect(guard.isBlocked(origin), isFalse);

      guard.countMismatch(origin);
      expect(guard.isBlocked(origin), isTrue);

      at(minutes(19, 59, 999));
      expect(guard.isBlocked(origin), isTrue);
      at(minutes(20));
      expect(guard.isBlocked(origin), isFalse);
    });

    test('requests rejected during the block count for the window', () {
      block(origin);
      for (var m = 1; m <= 5; m++) {
        at(minutes(m));
        expect(guard.admit(origin), isFalse, reason: 'minute $m');
      }

      at(minutes(10));
      expect(guard.isBlocked(origin), isFalse);
      expect(guard.admit(origin), isFalse);

      at(minutes(12));
      expect(guard.admit(origin), isTrue);
    });

    test('an unknown origin is not blocked', () {
      expect(guard.isBlocked('172.16.0.1'), isFalse);
    });
  });

  group('reset (C36, RF-106)', () {
    test('mismatch, mismatch, reset, mismatch does not block', () {
      guard.countMismatch(origin);
      guard.countMismatch(origin);
      guard.reset(origin);
      guard.countMismatch(origin);

      expect(guard.isBlocked(origin), isFalse);
      expect(guard.admit(origin), isTrue);
    });

    test('after reset the streak needs three again', () {
      guard.countMismatch(origin);
      guard.countMismatch(origin);
      guard.reset(origin);
      guard.countMismatch(origin);
      guard.countMismatch(origin);
      expect(guard.isBlocked(origin), isFalse);

      guard.countMismatch(origin);
      expect(guard.isBlocked(origin), isTrue);
    });

    test('reset does not lift an active block', () {
      block(origin);
      guard.reset(origin);

      expect(guard.isBlocked(origin), isTrue);
      at(minutes(9, 59));
      expect(guard.admit(origin), isFalse);
    });

    test('reset does not empty the window', () {
      for (var i = 0; i < 5; i++) {
        guard.admit(origin);
      }
      guard.reset(origin);

      expect(guard.admit(origin), isFalse);
    });

    test('reset of an unknown origin does nothing and does not throw', () {
      guard.reset('172.16.0.1');

      expect(guard.isBlocked('172.16.0.1'), isFalse);
      expect(guard.admit('172.16.0.1'), isTrue);
    });

    test('reset only touches its origin', () {
      guard.countMismatch(origin);
      guard.countMismatch(origin);
      guard.countMismatch('192.168.1.21');
      guard.countMismatch('192.168.1.21');
      guard.reset('192.168.1.21');

      guard.countMismatch(origin);
      guard.countMismatch('192.168.1.21');

      expect(guard.isBlocked(origin), isTrue);
      expect(guard.isBlocked('192.168.1.21'), isFalse);
    });
  });

  group('in memory (RF-107)', () {
    test('a new guard starts clean after a block and a full window', () {
      for (var i = 0; i < 6; i++) {
        guard.admit(origin);
      }
      block(origin);

      final fresh = PairingGuard(now: () => now);
      expect(fresh.isBlocked(origin), isFalse);
      expect(fresh.admit(origin), isTrue);
    });
  });

  group('many origins', () {
    List<String> manyOrigins(int count) => [
      for (var i = 0; i < count; i++)
        '10.${i >> 16}.${(i >> 8) & 255}.${i & 255}',
    ];

    test('with more than 1024 origins a blocked one stays blocked until its '
        'block ends', () {
      for (final key in manyOrigins(1100)) {
        expect(guard.admit(key), isTrue, reason: key);
      }
      at(minutes(5));
      block(origin);

      at(minutes(10));
      for (final key in manyOrigins(1100)) {
        guard.admit('late-$key');
      }

      at(minutes(14, 59, 999));
      expect(guard.isBlocked(origin), isTrue);
      expect(guard.admit(origin), isFalse);
      at(minutes(15));
      expect(guard.isBlocked(origin), isFalse);
    });

    test('with more than 1024 origins a full window keeps counting after the '
        'others expire', () {
      for (final key in manyOrigins(1100)) {
        guard.admit(key);
      }
      at(minutes(5));
      for (var i = 0; i < 5; i++) {
        guard.admit(origin);
      }

      at(minutes(14));
      for (final key in manyOrigins(1100)) {
        guard.admit('late-$key');
      }
      expect(guard.admit(origin), isFalse);
    });

    test('a streak of two survives the pruning', () {
      guard.countMismatch(origin);
      guard.countMismatch(origin);
      for (final key in manyOrigins(1100)) {
        guard.admit(key);
      }

      at(minutes(11));
      for (final key in manyOrigins(1100)) {
        guard.admit('late-$key');
      }
      guard.countMismatch(origin);
      expect(guard.isBlocked(origin), isTrue);
    });
  });

  group('global cap on failures after the reveal (RF-106b)', () {
    test('two failures do not block and the third does, whatever the '
        'origin', () {
      guard.countGlobalFailure(now);
      guard.countGlobalFailure(now);
      expect(guard.globalBlocked(now), isFalse);

      guard.countGlobalFailure(now);
      expect(guard.globalBlocked(now), isTrue);
    });

    test('each failure leaves the window exactly 10 minutes after it '
        'happened', () {
      guard.countGlobalFailure(_start);
      guard.countGlobalFailure(_start.add(minutes(3)));
      guard.countGlobalFailure(_start.add(minutes(6)));

      expect(guard.globalBlocked(_start.add(minutes(9, 59, 999))), isTrue);
      expect(guard.globalBlocked(_start.add(minutes(10))), isFalse);

      guard.countGlobalFailure(_start.add(minutes(10)));
      expect(guard.globalBlocked(_start.add(minutes(10))), isTrue);
      expect(guard.globalBlocked(_start.add(minutes(12, 59, 999))), isTrue);
      expect(guard.globalBlocked(_start.add(minutes(13))), isFalse);
    });

    test('a long run of failures keeps it blocked until the third most recent '
        'leaves the window', () {
      for (var m = 0; m < 30; m++) {
        guard.countGlobalFailure(_start.add(minutes(m)));
      }

      expect(guard.globalBlocked(_start.add(minutes(36, 59, 999))), isTrue);
      expect(guard.globalBlocked(_start.add(minutes(37))), isFalse);
    });

    test('is independent of the limit per origin and of the mismatch '
        'streak', () {
      for (var i = 0; i < 3; i++) {
        guard.countGlobalFailure(now);
      }

      expect(guard.admit(origin), isTrue);
      expect(guard.isBlocked(origin), isFalse);
      guard.countMismatch(origin);
      guard.countMismatch(origin);
      guard.countMismatch(origin);
      final other = PairingGuard(now: () => now);
      for (var i = 0; i < 3; i++) {
        other.countMismatch('10.0.0.$i');
      }
      expect(other.globalBlocked(now), isFalse);
    });

    test('the defaults are those of Limits and the constructor takes others '
        'for tests', () {
      expect(Limits.pairingGlobalFailures, 3);
      expect(Limits.pairingGlobalWindow, const Duration(minutes: 10));

      final strict = PairingGuard(
        now: () => now,
        globalLimit: 1,
        globalWindow: const Duration(seconds: 30),
      );
      strict.countGlobalFailure(_start);
      expect(strict.globalBlocked(_start), isTrue);
      expect(
        strict.globalBlocked(_start.add(const Duration(seconds: 30))),
        isFalse,
      );
    });

    test('a new guard starts without failures (RF-107)', () {
      for (var i = 0; i < 3; i++) {
        guard.countGlobalFailure(now);
      }

      expect(PairingGuard(now: () => now).globalBlocked(now), isFalse);
    });
  });

  group('start of the pause (C108, RF-106b)', () {
    test('the failure that completes three returns when the pause ends, and '
        'that is when the cap lifts', () {
      expect(guard.countGlobalFailure(_start), isNull);
      expect(guard.countGlobalFailure(_start.add(minutes(1))), isNull);
      expect(
        guard.countGlobalFailure(_start.add(minutes(2))),
        _start.add(minutes(10)),
      );

      expect(guard.globalBlocked(_start.add(minutes(9, 59, 999))), isTrue);
      expect(guard.globalBlocked(_start.add(minutes(10))), isFalse);
    });

    test('a failure after the oldest left the window starts a new pause that '
        'ends 10 minutes after the new oldest one', () {
      guard.countGlobalFailure(_start);
      guard.countGlobalFailure(_start.add(minutes(1)));
      guard.countGlobalFailure(_start.add(minutes(2)));

      expect(
        guard.countGlobalFailure(_start.add(minutes(10, 30))),
        _start.add(minutes(11)),
      );
      expect(guard.globalBlocked(_start.add(minutes(10, 59, 999))), isTrue);
      expect(guard.globalBlocked(_start.add(minutes(11))), isFalse);
    });

    test(
      'a failure counted while the pause is already active returns null',
      () {
        final other = PairingGuard(now: () => now);

        expect(
          [for (var i = 0; i < 4; i++) other.countGlobalFailure(_start)],
          [null, null, _start.add(minutes(10)), null],
        );
        expect(other.globalBlocked(_start.add(minutes(9, 59, 999))), isTrue);
        expect(other.globalBlocked(_start.add(minutes(10))), isFalse);
      },
    );

    test('with an injected limit and window the end follows them', () {
      final strict = PairingGuard(
        now: () => now,
        globalLimit: 1,
        globalWindow: const Duration(seconds: 30),
      );

      expect(
        strict.countGlobalFailure(_start),
        _start.add(const Duration(seconds: 30)),
      );
      expect(strict.countGlobalFailure(_start), isNull);
    });
  });

  group('signature budget (Q-7)', () {
    test('20 checks in the same second pass and the 21st does not', () {
      expect(Limits.signatureChecksPerSecond, 20);
      expect([
        for (var i = 0; i < 20; i++) guard.allowSignatureCheck(_start),
      ], everyElement(isTrue));

      expect(guard.allowSignatureCheck(_start), isFalse);
      expect(
        guard.allowSignatureCheck(
          _start.add(const Duration(milliseconds: 999)),
        ),
        isFalse,
      );
    });

    test('the window slides by the instant of each check', () {
      for (var i = 0; i < 10; i++) {
        expect(guard.allowSignatureCheck(_start), isTrue);
      }
      final half = _start.add(const Duration(milliseconds: 500));
      for (var i = 0; i < 10; i++) {
        expect(guard.allowSignatureCheck(half), isTrue);
      }
      expect(guard.allowSignatureCheck(half), isFalse);

      final second = _start.add(const Duration(seconds: 1));
      for (var i = 0; i < 10; i++) {
        expect(guard.allowSignatureCheck(second), isTrue, reason: '$i');
      }
      expect(guard.allowSignatureCheck(second), isFalse);
      expect(
        guard.allowSignatureCheck(half.add(const Duration(seconds: 1))),
        isTrue,
      );
    });

    test('refused checks do not use the budget', () {
      for (var i = 0; i < 20; i++) {
        guard.allowSignatureCheck(_start);
      }
      for (var i = 0; i < 100; i++) {
        guard.allowSignatureCheck(
          _start.add(Duration(microseconds: 900000 + i)),
        );
      }

      final next = _start.add(const Duration(seconds: 1));
      expect([
        for (var i = 0; i < 20; i++) guard.allowSignatureCheck(next),
      ], everyElement(isTrue));
      expect(guard.allowSignatureCheck(next), isFalse);
    });

    test('the budget is injectable for tests', () {
      final small = PairingGuard(now: () => now, signatureBudget: 2);

      expect(small.allowSignatureCheck(_start), isTrue);
      expect(small.allowSignatureCheck(_start), isTrue);
      expect(small.allowSignatureCheck(_start), isFalse);
    });

    test('is independent of origins, blocks and the global cap', () {
      block(origin);
      for (var i = 0; i < 3; i++) {
        guard.countGlobalFailure(now);
      }

      expect(guard.allowSignatureCheck(now), isTrue);
    });
  });

  group('hard cap on tracked origins (V8)', () {
    late PairingGuard small;

    setUp(() {
      small = PairingGuard(now: () => now, maxOrigins: 4);
    });

    void fill(PairingGuard target, int times, String key) {
      for (var i = 0; i < times; i++) {
        target.admit(key);
      }
    }

    test('the default cap is Limits.maxTrackedOrigins, 4096', () {
      expect(Limits.maxTrackedOrigins, 4096);
      final full = PairingGuard(now: () => now);
      for (var i = 0; i < 4096; i++) {
        full.countMismatch('10.0.${i >> 8}.${i & 255}');
        full.countMismatch('10.0.${i >> 8}.${i & 255}');
        full.countMismatch('10.0.${i >> 8}.${i & 255}');
      }
      expect(full.isBlocked('10.0.15.255'), isTrue);

      expect(full.admit('10.1.0.0'), isFalse);
      expect(full.isBlocked('10.0.0.0'), isTrue);
    });

    test('a new origin over the cap evicts the one least recently seen, '
        'which then starts clean', () {
      fill(small, 5, 'o0');
      fill(small, 5, 'o1');
      fill(small, 1, 'o2');
      fill(small, 1, 'o3');
      expect(small.admit('o0'), isFalse);

      expect(small.admit('o4'), isTrue);

      expect(small.admit('o0'), isFalse);
      expect(small.admit('o1'), isTrue);
    });

    test('a blocked origin is never evicted: it stays blocked while new '
        'origins come and go', () {
      for (var i = 0; i < 3; i++) {
        small.countMismatch('o0');
      }
      expect(small.isBlocked('o0'), isTrue);

      for (var i = 1; i <= 20; i++) {
        expect(small.admit('n$i'), isTrue, reason: 'n$i');
      }

      expect(small.isBlocked('o0'), isTrue);
      expect(small.admit('o0'), isFalse);
      at(minutes(10));
      expect(small.isBlocked('o0'), isFalse);
    });

    test('with every slot blocked a new origin is refused (fails closed) and '
        'its mismatches are not tracked', () {
      for (final key in ['o0', 'o1', 'o2', 'o3']) {
        for (var i = 0; i < 3; i++) {
          small.countMismatch(key);
        }
      }

      expect(small.admit('o4'), isFalse);
      expect(small.admit('o4'), isFalse);
      for (var i = 0; i < 3; i++) {
        small.countMismatch('o4');
      }
      expect(small.isBlocked('o4'), isFalse);
      for (final key in ['o0', 'o1', 'o2', 'o3']) {
        expect(small.isBlocked(key), isTrue, reason: key);
      }

      at(minutes(10));
      expect(small.admit('o4'), isTrue);
    });

    test('expired origins are pruned before evicting a live one: a streak of '
        'two on the oldest origin survives', () {
      small.countMismatch('o0');
      small.countMismatch('o0');
      fill(small, 1, 'o1');
      fill(small, 1, 'o2');
      fill(small, 1, 'o3');

      at(minutes(11));
      expect(small.admit('o4'), isTrue);
      expect(small.admit('o5'), isTrue);
      expect(small.admit('o6'), isTrue);
      small.countMismatch('o0');

      expect(small.isBlocked('o0'), isTrue);
    });

    test('control: without expired origins the same oldest streak is the '
        'one evicted', () {
      small.countMismatch('o0');
      small.countMismatch('o0');
      fill(small, 1, 'o1');
      fill(small, 1, 'o2');
      fill(small, 1, 'o3');

      expect(small.admit('o4'), isTrue);
      small.countMismatch('o0');

      expect(small.isBlocked('o0'), isFalse);
    });
  });
}
