import 'package:nexus_bridges_core/src/protocol/protocol.dart';
import 'package:nexus_bridges_core/src/transfer/recent_rejections.dart';
import 'package:test/test.dart';

const String peerA = 'A';
const String peerB = 'B';

final class FakeClock {
  Duration now = const Duration(hours: 1);

  Duration call() => now;

  void advance(Duration by) => now += by;
}

void main() {
  group('E11, RF-215: recent rejection (fake clock)', () {
    late FakeClock clock;
    late RecentRejections rejections;

    setUp(() {
      clock = FakeClock();
      rejections = RecentRejections(clock: clock.call);
    });

    test('the default window is one minute', () {
      expect(Limits.transferRecentRejection, const Duration(minutes: 1));
    });

    test(
      'record(A) blocks A at 59.9 s and not at 60 s, and never blocks B',
      () {
        rejections.record(peerA);

        clock.advance(const Duration(milliseconds: 59900));
        expect(rejections.blocks(peerA), isTrue);
        expect(rejections.blocks(peerB), isFalse);

        clock.advance(const Duration(milliseconds: 100));
        expect(rejections.blocks(peerA), isFalse);
        expect(rejections.blocks(peerB), isFalse);
      },
    );

    test('right after recording it blocks', () {
      rejections.record(peerA);
      expect(rejections.blocks(peerA), isTrue);
    });

    test('nothing is blocked before any record', () {
      expect(rejections.blocks(peerA), isFalse);
    });

    test('once it has expired it stays expired', () {
      rejections.record(peerA);
      clock.advance(const Duration(minutes: 1));
      expect(rejections.blocks(peerA), isFalse);
      clock.advance(const Duration(seconds: 1));
      expect(rejections.blocks(peerA), isFalse);
    });

    test('a new record restarts the minute', () {
      rejections.record(peerA);
      clock.advance(const Duration(seconds: 50));
      rejections.record(peerA);
      clock.advance(const Duration(seconds: 50));
      expect(rejections.blocks(peerA), isTrue);
      clock.advance(const Duration(seconds: 10));
      expect(rejections.blocks(peerA), isFalse);
    });

    test('each fingerprint has its own minute', () {
      rejections.record(peerA);
      clock.advance(const Duration(seconds: 30));
      rejections.record(peerB);
      clock.advance(const Duration(seconds: 30));
      expect(rejections.blocks(peerA), isFalse);
      expect(rejections.blocks(peerB), isTrue);
    });

    test('an injected window is used', () {
      final short = RecentRejections(
        clock: clock.call,
        window: const Duration(seconds: 5),
      );
      short.record(peerA);
      clock.advance(const Duration(milliseconds: 4999));
      expect(short.blocks(peerA), isTrue);
      clock.advance(const Duration(milliseconds: 1));
      expect(short.blocks(peerA), isFalse);
    });

    test('it keeps at most 256 fingerprints and the oldest goes out', () {
      for (var i = 0; i < 257; i++) {
        rejections.record('peer-$i');
        clock.advance(const Duration(milliseconds: 1));
      }

      expect(rejections.blocks('peer-0'), isFalse);
      expect(rejections.blocks('peer-1'), isTrue);
      expect(rejections.blocks('peer-256'), isTrue);
    });

    test('recording again moves a fingerprint to the newest place', () {
      for (var i = 0; i < 256; i++) {
        rejections.record('peer-$i');
        clock.advance(const Duration(milliseconds: 1));
      }
      rejections.record('peer-0');
      rejections.record('peer-new');

      expect(rejections.blocks('peer-0'), isTrue);
      expect(rejections.blocks('peer-1'), isFalse);
      expect(rejections.blocks('peer-new'), isTrue);
    });
  });
}
