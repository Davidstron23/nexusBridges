import 'package:nexus_bridges_core/src/pairing_flow/pairing_flow.dart';
import 'package:nexus_bridges_core/src/protocol/protocol.dart';
import 'package:test/test.dart';

final DateTime _start = DateTime.utc(2026, 10, 24, 12);

final String fpA = 'A' * 64;
final String fpB = 'B' * 64;
final String fpC = 'C' * 64;

const String addressA = '192.168.1.30';
const String addressB = '192.168.1.31';
const String addressC = '192.168.1.32';

void main() {
  late DateTime now;
  late PeerCheckScheduler scheduler;

  setUp(() {
    now = _start;
    scheduler = PeerCheckScheduler(now: () => now);
  });

  void at(Duration offset) => now = _start.add(offset);

  Map<String, String> onlyA([String address = addressA]) => {fpA: address};

  void checkA(PeerStatus status) {
    expect(scheduler.due(onlyA()), [fpA]);
    scheduler.finished(fpA, status);
  }

  group('when to check (C38, RF-118)', () {
    test('a paired device that appears is due at once', () {
      expect(scheduler.due(onlyA()), [fpA]);
    });

    test('a check in progress is not handed out twice', () {
      expect(scheduler.due(onlyA()), [fpA]);

      at(const Duration(minutes: 10));
      expect(scheduler.due(onlyA()), isEmpty);
    });

    test('with the same address nothing is due at 4 min and it is due again '
        'at 5 min', () {
      checkA(PeerStatus.paired);

      at(const Duration(minutes: 4));
      expect(scheduler.due(onlyA()), isEmpty);

      at(const Duration(minutes: 4, seconds: 59, milliseconds: 999));
      expect(scheduler.due(onlyA()), isEmpty);

      at(const Duration(minutes: 5));
      expect(scheduler.due(onlyA()), [fpA]);
    });

    test('notPaired is a definitive result: next check after 5 min, not after '
        '30 s', () {
      checkA(PeerStatus.notPaired);

      at(const Duration(seconds: 30));
      expect(scheduler.due(onlyA()), isEmpty);

      at(const Duration(minutes: 5));
      expect(scheduler.due(onlyA()), [fpA]);
    });

    test('the 5 minutes count from the end of the check, not from its '
        'start', () {
      expect(scheduler.due(onlyA()), [fpA]);
      at(const Duration(seconds: 8));
      scheduler.finished(fpA, PeerStatus.paired);

      at(const Duration(minutes: 5, seconds: 7));
      expect(scheduler.due(onlyA()), isEmpty);

      at(const Duration(minutes: 5, seconds: 8));
      expect(scheduler.due(onlyA()), [fpA]);
    });

    test('after a failure it is due again at 30 s', () {
      checkA(PeerStatus.unknown);

      at(const Duration(seconds: 29, milliseconds: 999));
      expect(scheduler.due(onlyA()), isEmpty);

      at(const Duration(seconds: 30));
      expect(scheduler.due(onlyA()), [fpA]);
    });

    test('a failure after a definitive result also retries at 30 s', () {
      checkA(PeerStatus.notPaired);
      at(const Duration(minutes: 5));
      checkA(PeerStatus.unknown);

      at(const Duration(minutes: 5, seconds: 30));
      expect(scheduler.due(onlyA()), [fpA]);
    });

    test('a new address makes it due at once', () {
      checkA(PeerStatus.paired);

      at(const Duration(minutes: 1));
      expect(scheduler.due(onlyA(addressB)), [fpA]);
      scheduler.finished(fpA, PeerStatus.paired);

      at(const Duration(minutes: 2));
      expect(scheduler.due(onlyA(addressB)), isEmpty);
      expect(scheduler.due(onlyA(addressA)), [fpA]);
    });

    test('nothing visible, nothing due', () {
      expect(scheduler.due(const {}), isEmpty);
    });

    test('the defaults are those of Limits: 5 min and 30 s', () {
      final other = PeerCheckScheduler(now: () => now);
      expect(other.due(onlyA()), [fpA]);
      other.finished(fpA, PeerStatus.paired);
      expect(other.due({fpA: addressA, fpB: addressB}), [fpB]);
      other.finished(fpB, PeerStatus.unknown);

      at(const Duration(seconds: 30));
      expect(other.due({fpA: addressA, fpB: addressB}), [fpB]);
      other.finished(fpB, PeerStatus.paired);

      at(const Duration(minutes: 5));
      expect(other.due({fpA: addressA, fpB: addressB}), [fpA]);
    });

    test('custom intervals are respected', () {
      final other = PeerCheckScheduler(
        now: () => now,
        interval: const Duration(seconds: 10),
        retry: const Duration(seconds: 2),
      );
      expect(other.due(onlyA()), [fpA]);
      other.finished(fpA, PeerStatus.paired);

      at(const Duration(seconds: 9));
      expect(other.due(onlyA()), isEmpty);
      at(const Duration(seconds: 10));
      expect(other.due(onlyA()), [fpA]);
      other.finished(fpA, PeerStatus.unknown);

      at(const Duration(seconds: 11));
      expect(other.due(onlyA()), isEmpty);
      at(const Duration(seconds: 12));
      expect(other.due(onlyA()), [fpA]);
    });
  });

  group('at most two in progress (C38)', () {
    test('three at once: only two are handed out', () {
      final due = scheduler.due({fpA: addressA, fpB: addressB, fpC: addressC});

      expect(due, hasLength(2));
      expect(due.toSet(), hasLength(2));
      expect(
        scheduler.due({fpA: addressA, fpB: addressB, fpC: addressC}),
        isEmpty,
      );
    });

    test('the third is handed out when one of the first two finishes', () {
      final all = {fpA: addressA, fpB: addressB, fpC: addressC};
      final first = scheduler.due(all);
      scheduler.finished(first.first, PeerStatus.paired);

      final second = scheduler.due(all);

      expect(second, hasLength(1));
      expect(first, isNot(contains(second.single)));
      expect({...first, ...second}, {fpA, fpB, fpC});
    });

    test('a check in progress of a device that left the view still counts '
        'until it finishes', () {
      expect(scheduler.due({fpA: addressA, fpB: addressB}), hasLength(2));

      expect(scheduler.due({fpB: addressB, fpC: addressC}), isEmpty);

      scheduler.finished(fpA, PeerStatus.unknown);
      expect(scheduler.due({fpB: addressB, fpC: addressC}), [fpC]);
    });

    test('maxInFlight can be lowered', () {
      final other = PeerCheckScheduler(now: () => now, maxInFlight: 1);

      expect(other.due({fpA: addressA, fpB: addressB}), hasLength(1));
      expect(other.due({fpA: addressA, fpB: addressB}), isEmpty);
    });
  });

  group('marks (C38, RF-118, RF-119)', () {
    test('notPaired marks the device', () {
      checkA(PeerStatus.notPaired);

      expect(scheduler.mismatched, {fpA});
    });

    test('a later unknown keeps the mark', () {
      checkA(PeerStatus.notPaired);
      at(const Duration(minutes: 5));
      checkA(PeerStatus.unknown);

      expect(scheduler.mismatched, {fpA});
    });

    test('unknown never creates a mark', () {
      checkA(PeerStatus.unknown);

      expect(scheduler.mismatched, isEmpty);
    });

    test('paired removes the mark', () {
      checkA(PeerStatus.notPaired);
      at(const Duration(minutes: 5));
      checkA(PeerStatus.paired);

      expect(scheduler.mismatched, isEmpty);
    });

    test('a device that disappears loses its schedule but keeps its mark, and '
        'is due as soon as it comes back', () {
      checkA(PeerStatus.notPaired);

      at(const Duration(seconds: 10));
      expect(scheduler.due(const {}), isEmpty);
      expect(scheduler.mismatched, {fpA});

      at(const Duration(seconds: 20));
      expect(scheduler.due(onlyA()), [fpA]);
      expect(scheduler.mismatched, {fpA});
    });

    test('a result that arrives after the device left still sets the mark, '
        'and the device is due when it returns', () {
      expect(scheduler.due(onlyA()), [fpA]);
      expect(scheduler.due(const {}), isEmpty);

      scheduler.finished(fpA, PeerStatus.notPaired);
      expect(scheduler.mismatched, {fpA});

      at(const Duration(seconds: 1));
      expect(scheduler.due(onlyA()), [fpA]);
    });

    test('clear removes the mark and does not schedule a check', () {
      checkA(PeerStatus.notPaired);

      at(const Duration(minutes: 1));
      scheduler.clear(fpA);

      expect(scheduler.mismatched, isEmpty);
      expect(scheduler.due(onlyA()), isEmpty);
    });

    test('clear of an unmarked device does nothing', () {
      checkA(PeerStatus.notPaired);
      scheduler.clear(fpB);

      expect(scheduler.mismatched, {fpA});
    });

    test('marks are per device', () {
      expect(scheduler.due({fpA: addressA, fpB: addressB}), hasLength(2));
      scheduler.finished(fpA, PeerStatus.notPaired);
      scheduler.finished(fpB, PeerStatus.paired);

      expect(scheduler.mismatched, {fpA});
    });

    test('the set handed out cannot change the marks', () {
      checkA(PeerStatus.notPaired);
      final marks = scheduler.mismatched;

      try {
        marks.add(fpB);
        marks.remove(fpA);
      } on UnsupportedError {
        expect(marks, {fpA});
      }

      expect(scheduler.mismatched, {fpA});
    });
  });

  group('waiting after a pairing (deferUntil, peerCheckAfterPairing)', () {
    test('a deferred device is not due before the time and is due at it', () {
      scheduler.deferUntil(fpA, _start.add(const Duration(seconds: 30)));

      expect(scheduler.due(onlyA()), isEmpty);
      at(const Duration(seconds: 29, milliseconds: 999));
      expect(scheduler.due(onlyA()), isEmpty);
      at(const Duration(seconds: 30));
      expect(scheduler.due(onlyA()), [fpA]);
    });

    test('a deferred device is not handed out even if its address changes, '
        'and does not take a slot from the others', () {
      scheduler.deferUntil(fpA, _start.add(const Duration(seconds: 30)));

      expect(scheduler.due({fpA: addressB, fpB: addressB, fpC: addressC}), [
        fpB,
        fpC,
      ]);
      scheduler.finished(fpB, PeerStatus.paired);
      scheduler.finished(fpC, PeerStatus.paired);
      at(const Duration(seconds: 10));
      expect(scheduler.due({fpA: addressC}), isEmpty);
    });

    test('a time in the past only removes the wait: a device checked a '
        'minute ago is still not due; a future time first resets the schedule, '
        'so after a future and a past one the device is due, like a device '
        'never checked (Q-5)', () {
      checkA(PeerStatus.paired);
      expect(scheduler.due({fpC: addressC}), [fpC]);
      scheduler.finished(fpC, PeerStatus.paired);
      at(const Duration(minutes: 1));
      scheduler.deferUntil(fpA, _start.add(const Duration(minutes: 10)));
      scheduler.deferUntil(fpB, _start.add(const Duration(minutes: 10)));

      scheduler.deferUntil(fpA, _start);
      scheduler.deferUntil(fpB, _start.add(const Duration(minutes: 1)));
      scheduler.deferUntil(fpC, _start);

      expect(scheduler.due({fpC: addressC}), isEmpty);
      expect(
        scheduler.due({fpA: addressA, fpB: addressB, fpC: addressC}),
        unorderedEquals([fpA, fpB]),
      );
    });

    test('a past time lifts a longer wait', () {
      checkA(PeerStatus.paired);
      scheduler.deferUntil(fpA, _start.add(const Duration(minutes: 10)));

      at(const Duration(minutes: 5));
      expect(scheduler.due(onlyA()), isEmpty);

      scheduler.deferUntil(fpA, _start);
      expect(scheduler.due(onlyA()), [fpA]);
    });

    test('deferUntil does not touch the marks', () {
      checkA(PeerStatus.notPaired);

      scheduler.deferUntil(fpA, _start.add(const Duration(seconds: 30)));

      expect(scheduler.mismatched, {fpA});
    });
  });

  group('waiting after pairing again (C119, RF-118, Q-5)', () {
    test('a device checked a minute ago and paired again is due 30 s after '
        'the new pairing, not 5 min after its last check', () {
      checkA(PeerStatus.notPaired);
      at(const Duration(minutes: 1));
      scheduler.clear(fpA);
      scheduler.deferUntil(
        fpA,
        _start.add(const Duration(minutes: 1) + Limits.peerCheckAfterPairing),
      );

      at(const Duration(minutes: 1, seconds: 29));
      expect(scheduler.due(onlyA()), isEmpty);
      at(const Duration(minutes: 1, seconds: 31));
      expect(scheduler.due(onlyA()), [fpA]);
      expect(scheduler.mismatched, isEmpty);
    });

    test('a check still in progress when the device is paired again ends '
        'without creating a schedule, and the device is due 30 s after the '
        'new pairing', () {
      expect(scheduler.due(onlyA()), [fpA]);
      at(const Duration(minutes: 1));
      scheduler.clear(fpA);
      scheduler.deferUntil(
        fpA,
        _start.add(const Duration(minutes: 1, seconds: 30)),
      );
      at(const Duration(minutes: 1, seconds: 10));
      scheduler.finished(fpA, PeerStatus.notPaired);

      at(const Duration(minutes: 1, seconds: 29));
      expect(scheduler.due(onlyA()), isEmpty);
      at(const Duration(minutes: 1, seconds: 31));
      expect(scheduler.due(onlyA()), [fpA]);
    });

    test('the other devices keep their schedule', () {
      expect(scheduler.due({fpA: addressA, fpB: addressB}), hasLength(2));
      scheduler.finished(fpA, PeerStatus.paired);
      scheduler.finished(fpB, PeerStatus.paired);
      at(const Duration(minutes: 1));
      scheduler.deferUntil(
        fpA,
        _start.add(const Duration(minutes: 1, seconds: 30)),
      );

      at(const Duration(minutes: 1, seconds: 31));
      expect(scheduler.due({fpA: addressA, fpB: addressB}), [fpA]);
      at(const Duration(minutes: 5));
      expect(scheduler.due({fpA: addressA, fpB: addressB}), [fpB]);
    });
  });

  group('public export', () {
    test('pairing_flow.dart exports PeerCheckScheduler', () {
      expect(PeerCheckScheduler(), isA<PeerCheckScheduler>());
    });
  });
}
