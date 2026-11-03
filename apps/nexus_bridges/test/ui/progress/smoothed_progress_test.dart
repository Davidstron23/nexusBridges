import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:nexus_bridges/src/ui/progress/smoothed_progress.dart';

const Duration _frame = Duration(milliseconds: 16);
const double _frameSeconds = 0.016;

final class _Rig {
  _Rig([SmoothedProgress? progress])
    : progress = progress ?? SmoothedProgress();

  final SmoothedProgress progress;
  Duration now = Duration.zero;
  final List<double> values = [];

  void observe(
    int done,
    int total, {
    bool finished = false,
    int selection = 1,
  }) {
    progress.observe(
      selectionId: selection,
      doneBytes: done,
      totalBytes: total,
      finished: finished,
      at: now,
    );
  }

  double frame([Duration by = _frame]) {
    now += by;
    final value = progress.advance(now);
    values.add(value);
    return value;
  }

  void frames(Duration span) {
    var elapsed = Duration.zero;
    while (elapsed < span) {
      frame();
      elapsed += _frame;
    }
  }

  void run(
    Duration span, {
    required int Function(Duration elapsed) done,
    required int total,
    Duration every = const Duration(milliseconds: 250),
  }) {
    var elapsed = Duration.zero;
    var nextObservation = Duration.zero;
    while (elapsed < span) {
      if (elapsed >= nextObservation) {
        observe(done(elapsed), total);
        nextObservation += every;
      }
      frame();
      elapsed += _frame;
    }
  }
}

void _expectMonotone(List<double> values) {
  for (var i = 1; i < values.length; i++) {
    expect(
      values[i],
      greaterThanOrEqualTo(values[i - 1]),
      reason: 'frame $i went back from ${values[i - 1]} to ${values[i]}',
    );
  }
}

void main() {
  group('E570: SmoothedProgress never goes back', () {
    test('with noisy real observations', () {
      final rig = _Rig();
      final random = math.Random(570);
      var done = 0;
      var nextObservation = Duration.zero;
      for (var step = 0; step < 900; step++) {
        if (rig.now >= nextObservation) {
          if (random.nextInt(4) != 0) done += random.nextInt(900000);
          rig.observe(math.min(done, 50000000), 50000000);
          nextObservation =
              rig.now + Duration(milliseconds: 150 + random.nextInt(250));
        }
        rig.frame();
      }
      _expectMonotone(rig.values);
      expect(rig.values.last, greaterThan(0.2));
    });

    test('with doneBytes that repeat the same value', () {
      final rig = _Rig();
      rig.run(
        const Duration(seconds: 6),
        done: (elapsed) => (elapsed.inMilliseconds ~/ 1500) * 1000000,
        total: 10000000,
      );
      _expectMonotone(rig.values);
    });

    test('with a totalBytes that grows halfway', () {
      final rig = _Rig();
      for (var i = 0; i < 300; i++) {
        final total = i < 150 ? 10000000 : 40000000;
        if (i % 15 == 0) rig.observe(i * 20000, total);
        rig.frame();
      }
      _expectMonotone(rig.values);
    });

    test('the value stays under 0.999 until it is finished', () {
      final rig = _Rig();
      rig.observe(100, 100);
      rig.frames(const Duration(seconds: 14));
      expect(rig.progress.value, lessThanOrEqualTo(0.999));
      expect(rig.progress.value, greaterThan(0.99));
    });
  });

  group('E571: no step is bigger than maxSpeed * dt', () {
    test('a jump of the real value from 0 to 90 %', () {
      final rig = _Rig();
      rig.observe(0, 1000);
      rig.frame();
      rig.observe(900, 1000);
      var before = rig.progress.value;
      for (var i = 0; i < 200; i++) {
        final value = rig.frame();
        expect(value - before, lessThanOrEqualTo(0.5 * _frameSeconds + 1e-12));
        before = value;
      }
    });

    test('a frame of 2 s counts as 100 ms', () {
      final rig = _Rig();
      rig.observe(0, 1000);
      rig.frame();
      rig.observe(900, 1000);
      final before = rig.progress.value;
      final value = rig.frame(const Duration(seconds: 2));
      expect(value - before, lessThanOrEqualTo(0.5 * 0.1 + 1e-12));
      expect(value - before, greaterThan(0));
    });

    test('a frame that goes back in time does not move the value', () {
      final rig = _Rig();
      rig.observe(500, 1000);
      rig.frame();
      final before = rig.progress.value;
      final earlier = rig.now - const Duration(seconds: 1);
      expect(rig.progress.advance(earlier), before);
    });
  });

  group('E572: behind the real value, it catches up', () {
    test('from 0.2 to a fixed 0.6, close after 3.5 s and never past it by '
        'more than aheadMargin', () {
      final rig = _Rig();
      rig.observe(200, 1000);
      rig.frames(const Duration(seconds: 12));
      expect(rig.progress.value, closeTo(0.2, 0.01));
      final start = rig.progress.value;
      for (var i = 0; i < 400; i++) {
        if (i % 15 == 0) rig.observe(600, 1000);
        rig.frame();
        expect(rig.progress.value, lessThanOrEqualTo(0.6 + 0.02));
        if (i == 219) {
          expect(0.6 - rig.progress.value, lessThan(0.05));
        }
      }
      expect(rig.progress.value, greaterThan(start));
      expect(0.6 - rig.progress.value, lessThan(0.01));
    });

    test('with a real speed it goes faster than catching up alone', () {
      final slow = _Rig();
      slow.observe(200, 1000);
      slow.frames(const Duration(seconds: 3));
      final fast = _Rig();
      fast.run(
        const Duration(seconds: 3),
        done: (elapsed) => 200 + elapsed.inMilliseconds ~/ 10,
        total: 1000,
      );
      expect(fast.progress.value, greaterThan(slow.progress.value));
    });
  });

  group('E573: ahead of the real value, it brakes', () {
    test('the speed goes down on every frame and never drops to 0 at once', () {
      final rig = _Rig();
      rig.run(
        const Duration(seconds: 4),
        done: (elapsed) => elapsed.inMilliseconds * 100,
        total: 2000000,
      );
      rig.observe(400000, 4000000);
      final steps = <double>[];
      var before = rig.progress.value;
      for (var i = 0; i < 40; i++) {
        final value = rig.frame();
        steps.add(value - before);
        before = value;
      }
      expect(steps.first, greaterThan(0));
      for (var i = 1; i < steps.length; i++) {
        expect(steps[i], lessThanOrEqualTo(steps[i - 1] + 1e-12));
      }
      expect(steps.first - steps.last, greaterThan(0));
      for (var i = 1; i < steps.length; i++) {
        if (steps[i - 1] > 1e-6) {
          expect(steps[i], greaterThan(steps[i - 1] * 0.5));
        }
      }
    });

    test('the shown value stays when the total grows', () {
      final rig = _Rig();
      rig.run(
        const Duration(seconds: 3),
        done: (elapsed) => elapsed.inMilliseconds * 100,
        total: 1000000,
      );
      final high = rig.progress.value;
      rig.observe(300000, 100000000);
      rig.frames(const Duration(seconds: 2));
      expect(rig.progress.value, greaterThanOrEqualTo(high));
      _expectMonotone(rig.values);
    });
  });

  group('E574: when the real value stops, it brakes softly', () {
    test('the speed decays smoothly until it is at rest and restarts '
        'without a jump', () {
      final rig = _Rig();
      rig.run(
        const Duration(seconds: 3),
        done: (elapsed) => elapsed.inMilliseconds * 100,
        total: 1000000,
      );
      final stoppedAt = rig.progress.value;
      final steps = <double>[];
      var before = rig.progress.value;
      var nextObservation = rig.now;
      for (var i = 0; i < 500; i++) {
        if (rig.now >= nextObservation) {
          rig.observe(300000, 1000000);
          nextObservation = rig.now + const Duration(milliseconds: 250);
        }
        final value = rig.frame();
        steps.add(value - before);
        before = value;
      }
      expect(rig.progress.atRest, isTrue);
      expect(rig.progress.value, greaterThanOrEqualTo(stoppedAt));
      expect(rig.progress.value, lessThan(0.4));
      for (var i = 1; i < steps.length; i++) {
        if (steps[i - 1] > 1e-4) {
          expect(steps[i], greaterThan(steps[i - 1] * 0.8), reason: 'frame $i');
        }
      }
      final resting = rig.progress.value;
      rig.observe(310000, 1000000);
      rig.frame();
      expect(rig.progress.atRest, isFalse);
      expect(rig.progress.value - resting, lessThan(0.01));
      rig.observe(330000, 1000000);
      final jump = rig.frame() - resting;
      expect(jump, lessThan(0.5 * _frameSeconds * 2));
    });

    test('atRest is true before any observation and false after one', () {
      final progress = SmoothedProgress();
      expect(progress.atRest, isTrue);
      expect(progress.value, 0);
      expect(progress.advance(const Duration(seconds: 1)), 0);
      final rig = _Rig(progress);
      rig.observe(0, 100);
      expect(progress.atRest, isFalse);
      rig.frame();
      expect(progress.atRest, isTrue);
    });
  });

  group('E575: at the end it glides to 1.0 in 400 ms', () {
    test('only finished starts the glide: a real 100 % does not', () {
      final rig = _Rig();
      rig.observe(100, 100);
      rig.frames(const Duration(seconds: 14));
      expect(rig.progress.value, lessThanOrEqualTo(0.999));
      expect(rig.progress.gliding, isFalse);
      expect(rig.progress.atRest, isTrue);
    });

    test('finished reaches 1.0 in 400 ms, plus or minus a frame, braking', () {
      final rig = _Rig();
      rig.run(
        const Duration(seconds: 2),
        done: (elapsed) => elapsed.inMilliseconds * 100,
        total: 1000000,
      );
      expect(rig.progress.value, lessThan(0.9));
      rig.observe(1000000, 1000000, finished: true);
      expect(rig.progress.gliding, isTrue);
      final start = rig.now;
      final steps = <double>[];
      var before = rig.progress.value;
      Duration? arrived;
      for (var i = 0; i < 60; i++) {
        final value = rig.frame();
        steps.add(value - before);
        before = value;
        if (value >= 1 && arrived == null) arrived = rig.now - start;
      }
      expect(arrived, isNotNull);
      expect(arrived!.inMilliseconds, inInclusiveRange(400 - 16, 400 + 16));
      for (var i = 1; i < steps.length; i++) {
        if (steps[i] > 0) {
          expect(steps[i], lessThanOrEqualTo(steps[i - 1] + 1e-9));
        }
      }
      expect(rig.progress.value, 1);
      expect(rig.progress.atRest, isTrue);
      expect(rig.progress.gliding, isFalse);
      _expectMonotone(rig.values);
    });

    test('a zero-byte selection that finishes is complete', () {
      final rig = _Rig();
      rig.observe(0, 0, finished: true);
      rig.frames(const Duration(milliseconds: 500));
      expect(rig.progress.value, 1);
    });

    test('the steady value is 1 only when finished', () {
      final rig = _Rig();
      rig.observe(100, 100);
      expect(rig.progress.steady, 0.999);
      rig.observe(100, 100, finished: true);
      expect(rig.progress.steady, 1);
    });
  });

  group('E576: no restart between the items of a selection', () {
    test('the bytes of the first item pass to the completed ones and the '
        'second starts at 0 without a drop or a jump', () {
      final rig = _Rig();
      const total = 1000;
      var done = 0;
      for (var i = 0; i < 400; i++) {
        if (i % 15 == 0) {
          if (i < 200) {
            done = math.min(done + 45, 450);
          } else if (i == 210) {
            done = 450;
          } else {
            done = math.min(done + 45, 900);
          }
          rig.observe(done, total);
        }
        rig.frame();
      }
      _expectMonotone(rig.values);
      for (var i = 1; i < rig.values.length; i++) {
        final step = rig.values[i] - rig.values[i - 1];
        expect(step, lessThan(0.5 * _frameSeconds + 1e-9));
      }
      expect(rig.progress.value, greaterThan(0.6));
    });

    test('a new selectionId goes back to 0 at once and the same one never '
        'does', () {
      final rig = _Rig();
      rig.run(
        const Duration(seconds: 3),
        done: (elapsed) => elapsed.inMilliseconds * 100,
        total: 1000000,
      );
      final before = rig.progress.value;
      expect(before, greaterThan(0.2));
      rig.observe(0, 1000000);
      expect(rig.progress.value, before);
      rig.observe(0, 5000, selection: 2);
      expect(rig.progress.value, 0);
      expect(rig.progress.steady, 0);
      expect(rig.progress.gliding, isFalse);
      rig.frame();
      expect(rig.progress.value, 0);
    });
  });

  group('E588: two small files and a big folder', () {
    test('it does not glide before the end, stays monotone and the total '
        'goes from the 64 MiB marker to the measured one without going '
        'back', () {
      final rig = _Rig();
      const mebibyte = 1024 * 1024;
      const files = 20 * mebibyte;
      var total = files + 64 * mebibyte;
      var done = 0;
      for (var i = 0; i < 600; i++) {
        if (i % 15 == 0) {
          if (done < files) done = math.min(done + 2 * mebibyte, files);
          if (i == 300) total = files + 5 * 1024 * mebibyte;
          if (i >= 400) done += 40 * mebibyte;
          rig.observe(math.min(done, total), total);
        }
        rig.frame();
        expect(rig.progress.gliding, isFalse);
      }
      _expectMonotone(rig.values);
      expect(rig.progress.value, lessThanOrEqualTo(0.999));
      expect(rig.progress.value, lessThan(0.5));
      rig.observe(total, total, finished: true);
      rig.frames(const Duration(milliseconds: 500));
      expect(rig.progress.value, 1);
      _expectMonotone(rig.values);
    });

    test('the steady value (reduced motion) is monotone as well', () {
      final progress = SmoothedProgress();
      var before = 0.0;
      const steps = [(10, 100), (30, 100), (30, 1000), (60, 1000), (300, 1000)];
      for (final (done, total) in steps) {
        progress.observe(
          selectionId: 1,
          doneBytes: done,
          totalBytes: total,
          finished: false,
          at: Duration.zero,
        );
        expect(progress.steady, greaterThanOrEqualTo(before));
        before = progress.steady;
      }
      expect(before, closeTo(0.3, 1e-9));
    });
  });
}
