import 'package:flutter_test/flutter_test.dart';
import 'package:nexus_bridges/src/l10n/app_strings_en.dart';
import 'package:nexus_bridges/src/l10n/app_strings_es.dart';
import 'package:nexus_bridges/src/ui/format.dart';
import 'package:nexus_bridges/src/ui/progress/time_left.dart';

Duration _at(num seconds) =>
    Duration(microseconds: (seconds * Duration.microsecondsPerSecond).round());

double _seconds(TimeLeft reading) {
  expect(reading, isA<TimeLeftRemaining>());
  return (reading as TimeLeftRemaining).value.inMicroseconds /
      Duration.microsecondsPerSecond;
}

void _see(
  TimeLeftEstimator estimator,
  num at,
  int done, {
  int total = 100000,
  bool active = true,
}) {
  estimator.observe(
    active: active,
    doneBytes: done,
    totalBytes: total,
    at: _at(at),
  );
}

void _steady(
  TimeLeftEstimator estimator, {
  required int to,
  required int startBytes,
  required int perSecond,
  int total = 100000,
}) {
  for (var second = 0; second <= to; second++) {
    _see(estimator, second, startBytes + second * perSecond, total: total);
  }
}

int _doneFor(double target, int at, int total) =>
    ((total + target / at) / (1 + target / at)).round();

void main() {
  group('Q-3 a transfer about to end shows no time', () {
    test('with 5 s or less left at the first reading nothing appears', () {
      final estimator = TimeLeftEstimator();
      for (var second = 0; second <= 9; second++) {
        _see(estimator, second, 100 + second * 100, total: 1100);
      }
      expect(estimator.reading, isA<TimeLeftHidden>());
    });

    test('a time already on screen keeps going down to the end', () {
      final estimator = TimeLeftEstimator();
      for (var second = 0; second <= 5; second++) {
        _see(estimator, second, 100 + second * 100, total: 1700);
      }
      expect(estimator.reading, isA<TimeLeftRemaining>());
      for (var second = 6; second <= 13; second++) {
        _see(estimator, second, 100 + second * 100, total: 1700);
      }
      expect(_seconds(estimator.reading), lessThanOrEqualTo(5));
    });
  });

  group('E900 the time appears at 5 s and not before', () {
    test('nothing is shown before 5 s and the time appears at 5 s', () {
      final estimator = TimeLeftEstimator();
      for (var second = 0; second < 5; second++) {
        _see(estimator, second, 100 + second * 100, total: 10000);
        expect(estimator.reading, TimeLeft.hidden);
      }
      _see(estimator, 4.999, 599, total: 10000);
      expect(estimator.reading, TimeLeft.hidden);
      _see(estimator, 5, 600, total: 10000);
      expect(_seconds(estimator.reading), closeTo(94, 0.001));
    });

    test('the 5 s count from the first byte, not from the first call', () {
      final estimator = TimeLeftEstimator();
      for (var second = 0; second <= 9; second++) {
        _see(estimator, second, 0, total: 10000);
        expect(estimator.reading, TimeLeft.hidden);
      }
      _see(estimator, 10, 100, total: 10000);
      _see(estimator, 12, 300, total: 10000);
      _see(estimator, 14.9, 590, total: 10000);
      expect(estimator.reading, TimeLeft.hidden);
      _see(estimator, 15, 600, total: 10000);
      expect(_seconds(estimator.reading), closeTo(94, 0.001));
    });
  });

  group('E901 formats', () {
    const cases = <(num, String?)>[
      (0, null),
      (1, null),
      (5, null),
      (5.001, '10 s'),
      (6, '10 s'),
      (10, '10 s'),
      (21, '25 s'),
      (25, '25 s'),
      (55, '55 s'),
      (55.001, '1 min'),
      (56, '1 min'),
      (59, '1 min'),
      (60, '1 min'),
      (89, '1 min'),
      (90, '2 min'),
      (180, '3 min'),
      (3569, '59 min'),
      (3570, '1 h'),
      (3599, '1 h'),
      (3600, '1 h'),
      (3630, '1 h 1 min'),
      (4800, '1 h 20 min'),
      (7169, '1 h 59 min'),
      (7170, '2 h'),
      (7200, '2 h'),
      (9000, '2 h 30 min'),
    ];
    for (final (seconds, expected) in cases) {
      final label = expected ?? 'the few seconds case';
      test('$seconds s gives $label', () {
        expect(formatTimeLeft(_at(seconds)), expected);
      });
    }

    test('no time ever writes 60 min', () {
      for (var seconds = 0; seconds <= 90000; seconds += 7) {
        final text = formatTimeLeft(_at(seconds));
        expect(text ?? '', isNot(contains('60 min')));
      }
    });
  });

  group('E901 the texts exist in both languages', () {
    final es = AppStringsEs();
    final en = AppStringsEn();

    test('Spanish', () {
      expect(es.arrivesIn('25 s'), 'Llega en 25 s');
      expect(es.arrivesInFewSeconds, 'Llega en unos segundos');
      expect(es.calculatingTime, 'Calculando\u{2026}');
    });

    test('English', () {
      expect(en.arrivesIn('25 s'), 'Arrives in 25 s');
      expect(en.arrivesInFewSeconds, 'Arrives in a few seconds');
      expect(en.calculatingTime, 'Calculating\u{2026}');
    });
  });

  group('E902 tolerance of 15 %', () {
    TimeLeftEstimator shown100ThenSees(int next) {
      final estimator = TimeLeftEstimator();
      final total = 1000 + 105 * (next + 6);
      _see(estimator, 0, 1000, total: total);
      _see(estimator, 5, 1000 + 5 * (next + 6), total: total);
      expect(_seconds(estimator.reading), closeTo(100, 1e-6));
      _see(estimator, 6, 1630, total: total);
      return estimator;
    }

    test('a rise of 10 % keeps the shown time', () {
      expect(_seconds(shown100ThenSees(110).reading), closeTo(100, 1e-6));
    });

    test('a rise of 14 % keeps the shown time', () {
      expect(_seconds(shown100ThenSees(114).reading), closeTo(100, 1e-6));
    });

    test('a rise of exactly 15 % updates the shown time', () {
      expect(_seconds(shown100ThenSees(115).reading), closeTo(115, 1e-6));
    });

    test('a rise of 19 % updates the shown time', () {
      expect(_seconds(shown100ThenSees(119).reading), closeTo(119, 1e-6));
    });

    test('a drop updates the shown time, however small', () {
      expect(_seconds(shown100ThenSees(99).reading), closeTo(99, 1e-6));
    });

    test('the rise is measured against the shown time, not the last one', () {
      const total = 1000000000000;
      final estimator = TimeLeftEstimator();
      _see(estimator, 0, 1, total: total);
      _see(estimator, 5, _doneFor(1000, 5, total), total: total);
      expect(_seconds(estimator.reading), closeTo(1000, 0.01));
      _see(estimator, 6, _doneFor(1100, 6, total), total: total);
      expect(_seconds(estimator.reading), closeTo(1000, 0.01));
      _see(estimator, 7, _doneFor(1200, 7, total), total: total);
      expect(_seconds(estimator.reading), closeTo(1200, 0.01));
    });
  });

  group('E903 at most one recalculation per second', () {
    test('a faster change inside the same second is ignored', () {
      final estimator = TimeLeftEstimator();
      _steady(estimator, to: 5, startBytes: 1000, perSecond: 1000);
      final first = _seconds(estimator.reading);
      _see(estimator, 5.5, 50000);
      expect(_seconds(estimator.reading), first);
      _see(estimator, 5.999, 60000);
      expect(_seconds(estimator.reading), first);
      _see(estimator, 6, 61000);
      expect(_seconds(estimator.reading), lessThan(first));
    });
  });

  group('E904 a stall', () {
    TimeLeftEstimator running() {
      final estimator = TimeLeftEstimator();
      _steady(estimator, to: 10, startBytes: 1000, perSecond: 1000);
      return estimator;
    }

    test('2.9 s without bytes keep the time and 3 s give calculating', () {
      final estimator = running();
      expect(estimator.reading, isA<TimeLeftRemaining>());
      _see(estimator, 12.9, 11000);
      expect(estimator.reading, isA<TimeLeftRemaining>());
      _see(estimator, 13, 11000);
      expect(estimator.reading, TimeLeft.calculating);
    });

    test('calculating stays while the stall lasts', () {
      final estimator = running();
      for (var second = 13; second <= 60; second++) {
        _see(estimator, second, 11000);
        expect(estimator.reading, TimeLeft.calculating);
      }
    });

    test('when bytes return it waits for 2 s of new samples', () {
      final estimator = running();
      _see(estimator, 13, 11000);
      _see(estimator, 20, 12000);
      expect(estimator.reading, TimeLeft.calculating);
      _see(estimator, 21, 13000);
      expect(estimator.reading, TimeLeft.calculating);
      _see(estimator, 21.9, 13900);
      expect(estimator.reading, TimeLeft.calculating);
      _see(estimator, 22, 14000);
      expect(_seconds(estimator.reading), closeTo(86, 0.001));
    });

    test('the time after a long stall is not inflated', () {
      final estimator = running();
      for (var second = 13; second <= 200; second++) {
        _see(estimator, second, 11000);
      }
      for (var second = 0; second <= 12; second++) {
        final done = 12000 + second * 1000;
        _see(estimator, 201 + second, done);
        final reading = estimator.reading;
        if (reading is TimeLeftRemaining) {
          final honest = (100000 - done) / 1000;
          expect(_seconds(reading), lessThanOrEqualTo(honest * 1.01));
        }
      }
      expect(estimator.reading, isA<TimeLeftRemaining>());
    });

    test('the time after repeated stalls is not inflated', () {
      final estimator = running();
      var at = 13;
      var done = 11000;
      _see(estimator, at, done);
      for (var round = 0; round < 3; round++) {
        for (var second = 0; second < 4; second++) {
          at += 1;
          done += 1000;
          _see(estimator, at, done);
          final reading = estimator.reading;
          if (reading is TimeLeftRemaining) {
            final honest = (100000 - done) / 1000;
            expect(_seconds(reading), lessThanOrEqualTo(honest * 1.01));
          }
        }
        for (var second = 0; second < 3; second++) {
          at += 1;
          _see(estimator, at, done);
        }
        expect(estimator.reading, TimeLeft.calculating);
      }
    });

    test('a stall inside the first 5 s shows nothing', () {
      final estimator = TimeLeftEstimator();
      _see(estimator, 0, 100, total: 10000);
      _see(estimator, 1, 200, total: 10000);
      _see(estimator, 4, 200, total: 10000);
      expect(estimator.reading, TimeLeft.hidden);
    });

    test('a stall that reaches the 5 s gives calculating', () {
      final estimator = TimeLeftEstimator();
      _see(estimator, 0, 100, total: 10000);
      _see(estimator, 2, 300, total: 10000);
      _see(estimator, 5, 300, total: 10000);
      expect(estimator.reading, TimeLeft.calculating);
    });

    test('a stall inside the first 5 s also forgets its samples', () {
      final estimator = TimeLeftEstimator();
      _see(estimator, 0, 100, total: 10000);
      _see(estimator, 1, 200, total: 10000);
      _see(estimator, 2, 200, total: 10000);
      _see(estimator, 3, 200, total: 10000);
      _see(estimator, 4, 200, total: 10000);
      _see(estimator, 5, 300, total: 10000);
      expect(estimator.reading, isNot(isA<TimeLeftRemaining>()));
      _see(estimator, 6, 400, total: 10000);
      expect(estimator.reading, isNot(isA<TimeLeftRemaining>()));
      _see(estimator, 7, 500, total: 10000);
      expect(_seconds(estimator.reading), closeTo(95, 0.001));
    });
  });

  group('E905 restart', () {
    test('active false resets the reading', () {
      final estimator = TimeLeftEstimator();
      _steady(estimator, to: 6, startBytes: 100, perSecond: 100);
      expect(estimator.reading, isA<TimeLeftRemaining>());
      _see(estimator, 7, 700, active: false);
      expect(estimator.reading, TimeLeft.hidden);
    });

    test('a calculating reading is also reset', () {
      final estimator = TimeLeftEstimator();
      _steady(estimator, to: 6, startBytes: 100, perSecond: 100);
      _see(estimator, 9, 700);
      expect(estimator.reading, TimeLeft.calculating);
      _see(estimator, 10, 700, active: false);
      expect(estimator.reading, TimeLeft.hidden);
    });

    test('after a reset the 5 s and the samples start again', () {
      final estimator = TimeLeftEstimator();
      _steady(estimator, to: 6, startBytes: 100, perSecond: 100);
      _see(estimator, 7, 700, active: false);
      _see(estimator, 8, 5000, total: 20000);
      _see(estimator, 12, 7000, total: 20000);
      expect(estimator.reading, TimeLeft.hidden);
      _see(estimator, 13, 7500, total: 20000);
      expect(_seconds(estimator.reading), closeTo(25, 0.001));
    });

    test('bytes going back mean another transfer and restart everything', () {
      final estimator = TimeLeftEstimator();
      _steady(estimator, to: 6, startBytes: 1000, perSecond: 1000);
      expect(estimator.reading, isA<TimeLeftRemaining>());
      _see(estimator, 7, 100);
      expect(estimator.reading, TimeLeft.hidden);
    });
  });

  group('E906 nothing divides by zero', () {
    test('a total of 0 stays hidden', () {
      final estimator = TimeLeftEstimator();
      for (var second = 0; second <= 12; second++) {
        _see(estimator, second, 0, total: 0);
        expect(estimator.reading, TimeLeft.hidden);
      }
    });

    test('a negative total stays hidden', () {
      final estimator = TimeLeftEstimator();
      _see(estimator, 0, 100, total: -1);
      _see(estimator, 6, 200, total: -1);
      expect(estimator.reading, TimeLeft.hidden);
    });

    test('a single jump followed by no speed keeps calculating', () {
      final estimator = TimeLeftEstimator();
      _steady(estimator, to: 5, startBytes: 100, perSecond: 100);
      _see(estimator, 8, 600);
      expect(estimator.reading, TimeLeft.calculating);
      _see(estimator, 9, 700);
      _see(estimator, 10, 700);
      _see(estimator, 11, 700);
      expect(estimator.reading, TimeLeft.calculating);
    });

    test('zero seconds of span never give a time', () {
      final estimator = TimeLeftEstimator();
      _see(estimator, 5, 100);
      _see(estimator, 5, 200);
      expect(estimator.reading, TimeLeft.hidden);
    });
  });

  group('E907 the average of the last 12 s', () {
    test('a variable speed follows the window, not the whole transfer', () {
      const total = 1000000;
      final estimator = TimeLeftEstimator();
      var done = 500;
      _see(estimator, 0, done, total: total);
      for (var second = 1; second <= 20; second++) {
        done += 500;
        _see(estimator, second, done, total: total);
      }
      for (var second = 21; second <= 26; second++) {
        done += 1000;
        _see(estimator, second, done, total: total);
      }
      expect(_seconds(estimator.reading), closeTo((total - done) / 750, 0.01));
      for (var second = 27; second <= 32; second++) {
        done += 1000;
        _see(estimator, second, done, total: total);
      }
      expect(_seconds(estimator.reading), closeTo((total - done) / 1000, 0.01));
    });

    test('the bumps inside the window are averaged', () {
      const total = 10000000;
      final estimator = TimeLeftEstimator();
      var done = 1000;
      _see(estimator, 0, done, total: total);
      for (var second = 1; second <= 12; second++) {
        done += second.isEven ? 3000 : 1000;
        _see(estimator, second, done, total: total);
      }
      expect(_seconds(estimator.reading), closeTo((total - done) / 2000, 0.01));
    });
  });
}
