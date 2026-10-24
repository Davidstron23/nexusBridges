import 'package:nexus_bridges_core/src/protocol/protocol.dart';
import 'package:nexus_bridges_core/src/server/rate_limiter.dart';
import 'package:test/test.dart';

final DateTime _start = DateTime.utc(2026, 10, 21, 12);

void main() {
  late DateTime now;
  late RateLimiter limiter;

  setUp(() {
    now = _start;
    limiter = RateLimiter(
      maxPerWindow: Limits.registerPerMinute,
      window: const Duration(minutes: 1),
      block: Limits.registerBlock,
      now: () => now,
    );
  });

  void at(Duration offset) => now = _start.add(offset);

  List<bool> calls(String key, int count) => [
    for (var i = 0; i < count; i++) limiter.allow(key),
  ];

  group('limit (RF-36)', () {
    test('allows 30 calls in the same instant and rejects the 31st', () {
      expect(calls('10.0.0.5', 30), everyElement(isTrue));

      expect(limiter.allow('10.0.0.5'), isFalse);
    });

    test('30 calls spread inside the minute, the 31st is rejected', () {
      for (var i = 0; i < 30; i++) {
        at(Duration(seconds: i * 2));
        expect(limiter.allow('10.0.0.5'), isTrue, reason: 'call ${i + 1}');
      }

      at(const Duration(seconds: 59, milliseconds: 500));
      expect(limiter.allow('10.0.0.5'), isFalse);
    });

    test('the block still holds 59 s after it started', () {
      calls('10.0.0.5', 31);

      at(const Duration(seconds: 59));
      expect(limiter.allow('10.0.0.5'), isFalse);
    });

    test('the block is over 61 s after it started', () {
      calls('10.0.0.5', 31);

      at(const Duration(seconds: 61));
      expect(limiter.allow('10.0.0.5'), isTrue);
    });

    test('the block lasts exactly one minute', () {
      calls('10.0.0.5', 31);

      at(const Duration(seconds: 59, milliseconds: 999));
      expect(limiter.allow('10.0.0.5'), isFalse);
      at(const Duration(minutes: 1));
      expect(limiter.allow('10.0.0.5'), isTrue);
    });

    test('rejected calls during the block do not extend it', () {
      calls('10.0.0.5', 31);
      for (final second in [10, 30, 50, 59]) {
        at(Duration(seconds: second));
        expect(calls('10.0.0.5', 5), everyElement(isFalse));
      }

      at(const Duration(seconds: 61));
      expect(limiter.allow('10.0.0.5'), isTrue);
    });

    test('after the block expires the key starts clean with 30 calls', () {
      calls('10.0.0.5', 31);

      at(const Duration(seconds: 61));
      expect(calls('10.0.0.5', 30), everyElement(isTrue));
      expect(limiter.allow('10.0.0.5'), isFalse);
    });
  });

  group('sliding window per key (RF-36)', () {
    test('different keys do not affect each other', () {
      calls('10.0.0.5', 31);

      expect(limiter.allow('10.0.0.5'), isFalse);
      expect(calls('10.0.0.6', 30), everyElement(isTrue));
      expect(limiter.allow('10.0.0.6'), isFalse);
    });

    test('a key near the limit does not block another key', () {
      calls('10.0.0.5', 30);

      expect(limiter.allow('10.0.0.6'), isTrue);
      expect(limiter.allow('10.0.0.5'), isFalse);
    });

    test('calls older than the window no longer count', () {
      calls('10.0.0.5', 30);

      at(const Duration(seconds: 61));
      expect(calls('10.0.0.5', 30), everyElement(isTrue));
      expect(limiter.allow('10.0.0.5'), isFalse);
    });

    test('the window slides instead of resetting at fixed minutes', () {
      expect(calls('10.0.0.5', 15), everyElement(isTrue));
      at(const Duration(seconds: 30));
      expect(calls('10.0.0.5', 15), everyElement(isTrue));

      at(const Duration(seconds: 61));
      expect(calls('10.0.0.5', 15), everyElement(isTrue));
      expect(limiter.allow('10.0.0.5'), isFalse);
    });

    test('calls still inside the window keep counting', () {
      expect(calls('10.0.0.5', 29), everyElement(isTrue));

      at(const Duration(seconds: 59));
      expect(limiter.allow('10.0.0.5'), isTrue);
      expect(limiter.allow('10.0.0.5'), isFalse);
    });
  });

  group('many keys (B3)', () {
    List<String> manyKeys(int count) => [
      for (var i = 0; i < count; i++)
        '10.${i >> 16}.${(i >> 8) & 255}.${i & 255}',
    ];

    test('with more than 1024 keys a blocked key stays blocked until its '
        'block expires and then starts clean', () {
      calls('192.168.1.66', 31);
      for (final key in manyKeys(1100)) {
        expect(limiter.allow(key), isTrue, reason: key);
      }

      at(const Duration(seconds: 30));
      expect(limiter.allow('192.168.1.66'), isFalse);
      at(const Duration(seconds: 59, milliseconds: 999));
      expect(limiter.allow('192.168.1.66'), isFalse);

      at(const Duration(seconds: 61));
      expect(calls('192.168.1.66', 30), everyElement(isTrue));
      expect(limiter.allow('192.168.1.66'), isFalse);
    });

    test('with more than 1024 keys a key with calls still inside the window '
        'keeps counting them', () {
      for (final key in manyKeys(1100)) {
        limiter.allow(key);
      }
      at(const Duration(seconds: 30));
      expect(calls('192.168.1.77', 30), everyElement(isTrue));

      at(const Duration(seconds: 61));
      expect(limiter.allow('192.168.1.77'), isFalse);
    });

    test('a key blocked later than the others is not released when the old '
        'keys expire', () {
      for (final key in manyKeys(1100)) {
        limiter.allow(key);
      }
      at(const Duration(seconds: 50));
      calls('192.168.1.88', 31);

      at(const Duration(seconds: 70));
      expect(limiter.allow('192.168.1.88'), isFalse);
      at(const Duration(seconds: 109, milliseconds: 999));
      expect(limiter.allow('192.168.1.88'), isFalse);
      at(const Duration(seconds: 110));
      expect(limiter.allow('192.168.1.88'), isTrue);
    });

    test('expired keys behave as new after the pruning: each one gets its '
        '30 calls again and the 31st is rejected', () {
      final keys = manyKeys(1100);
      for (final key in keys) {
        expect(calls(key, 30), everyElement(isTrue), reason: key);
      }

      at(const Duration(seconds: 61));
      for (final key in keys) {
        expect(calls(key, 30), everyElement(isTrue), reason: key);
        expect(limiter.allow(key), isFalse, reason: key);
      }
    });

    test('10000 different keys over several minutes keep the same answers '
        'as a fresh limiter', () {
      for (var minute = 0; minute < 5; minute++) {
        at(Duration(minutes: minute * 2));
        for (final key in manyKeys(2000)) {
          if (!limiter.allow('$minute-$key')) fail('$minute-$key rejected');
        }
        expect(calls('192.168.1.99', 30), everyElement(isTrue));
        expect(limiter.allow('192.168.1.99'), isFalse);
      }
    });
  });

  group('hard cap on tracked keys (V8)', () {
    RateLimiter small({int maxPerWindow = 3}) => RateLimiter(
      maxPerWindow: maxPerWindow,
      window: const Duration(minutes: 1),
      block: const Duration(minutes: 1),
      now: () => now,
      maxKeys: 4,
    );

    List<String> manyKeys(int count) => [
      for (var i = 0; i < count; i++)
        '10.${i >> 16}.${(i >> 8) & 255}.${i & 255}',
    ];

    test('the default cap is Limits.maxTrackedOrigins', () {
      expect(limiter.maxKeys, Limits.maxTrackedOrigins);
      expect(Limits.maxTrackedOrigins, 4096);
    });

    test('with 4096 blocked keys a new key is refused (fails closed) and the '
        'blocked ones stay blocked', () {
      final full = RateLimiter(
        maxPerWindow: 1,
        window: const Duration(minutes: 1),
        block: const Duration(minutes: 1),
        now: () => now,
      );
      for (final key in manyKeys(4096)) {
        full.allow(key);
        expect(full.allow(key), isFalse, reason: key);
      }

      expect(full.allow('192.168.1.99'), isFalse);
      expect(full.allow(manyKeys(1).single), isFalse);
      at(const Duration(minutes: 1));
      expect(full.allow('192.168.1.99'), isTrue);
    });

    test('a new key over the cap evicts the least recently seen one, which '
        'then starts clean', () {
      final limited = small();
      for (final key in ['k0', 'k1']) {
        expect([
          for (var i = 0; i < 3; i++) limited.allow(key),
        ], everyElement(isTrue));
      }
      limited.allow('k2');
      limited.allow('k3');
      expect(limited.allow('k0'), isFalse);

      expect(limited.allow('k4'), isTrue);

      expect(limited.allow('k1'), isTrue);
    });

    test('a blocked key is never evicted while new keys come and go', () {
      final limited = small();
      for (var i = 0; i < 4; i++) {
        limited.allow('k0');
      }

      for (var i = 1; i <= 20; i++) {
        expect(limited.allow('n$i'), isTrue, reason: 'n$i');
      }

      at(const Duration(seconds: 59));
      expect(limited.allow('k0'), isFalse);
    });

    test('with every slot blocked a new key is refused until a block ends', () {
      final limited = small();
      for (final key in ['k0', 'k1', 'k2', 'k3']) {
        for (var i = 0; i < 4; i++) {
          limited.allow(key);
        }
      }

      expect(limited.allow('k4'), isFalse);
      at(const Duration(seconds: 59, milliseconds: 999));
      expect(limited.allow('k4'), isFalse);
      at(const Duration(minutes: 1));
      expect(limited.allow('k4'), isTrue);
      for (final key in ['k0', 'k1', 'k2', 'k3']) {
        expect(limited.allow(key), isTrue, reason: key);
      }
    });
  });
}
