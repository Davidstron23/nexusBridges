import 'dart:ui';

import 'package:flutter/animation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nexus_bridges/src/ui/modal/timeline.dart';

const double _eps = 1e-9;

const List<double> _rawInputs = [
  double.nan,
  double.infinity,
  double.negativeInfinity,
  -1e12,
  -1,
  0,
  1e-12,
  0.5,
  1,
  1e6,
  1e12,
  double.maxFinite,
];

double _length(Path path) =>
    path.computeMetrics().fold<double>(0, (sum, m) => sum + m.length);

List<double> _lengths(Path path) => [
  for (final metric in path.computeMetrics()) metric.length,
];

const List<Kf> _p1FallD = [
  Kf(0, 0, labEaseIn),
  Kf(0.55, -56, labEaseOut),
  Kf(0.75, -44),
  Kf(1, -50),
];

double _fallAt(double t) => keyframes(
  t,
  delay: 1.32,
  duration: 1,
  frames: _p1FallD,
  curve: Curves.ease,
);

void main() {
  group('E284 lab curves', () {
    void expectCubic(Cubic curve, double a, double b, double c, double d) {
      expect(curve.a, a);
      expect(curve.b, b);
      expect(curve.c, c);
      expect(curve.d, d);
    }

    test('every named curve has the control points of the lab', () {
      expectCubic(labEaseOut, 0.23, 1, 0.32, 1);
      expectCubic(labEaseInOut, 0.65, 0, 0.35, 1);
      expectCubic(labEaseIn, 0.55, 0, 1, 0.45);
      expectCubic(labEaseOutSoft, 0.33, 1, 0.68, 1);
      expectCubic(labSwing, 0.77, 0, 0.175, 1);
      expectCubic(labOrbit, 0.45, 0.05, 0.55, 0.95);
      expectCubic(labShake, 0.36, 0.07, 0.19, 0.97);
      expectCubic(labFall, 0.55, 0, 0.75, 0.2);
    });

    test('the hourglass curve is the swing curve', () {
      expectCubic(labHourglass, 0.77, 0, 0.175, 1);
      expect(identical(labHourglass, labSwing), isTrue);
    });

    test('every curve goes from 0 to 1', () {
      for (final curve in [
        labEaseOut,
        labEaseInOut,
        labEaseIn,
        labEaseOutSoft,
        labSwing,
        labOrbit,
        labShake,
        labFall,
        labHourglass,
      ]) {
        expect(curve.transform(0), closeTo(0, _eps));
        expect(curve.transform(1), closeTo(1, _eps));
      }
    });

    test('the symmetric curves are at one half in the middle', () {
      expect(labEaseInOut.transform(0.5), closeTo(0.5, 1e-6));
      expect(labOrbit.transform(0.5), closeTo(0.5, 1e-6));
    });
  });

  group('E284 phase', () {
    test('is 0 before the delay and 1 after the end', () {
      expect(phase(0, delay: 0.5, duration: 0.45), 0);
      expect(phase(0.5, delay: 0.5, duration: 0.45), 0);
      expect(phase(0.95, delay: 0.5, duration: 0.45), closeTo(1, _eps));
      expect(phase(0.96, delay: 0.5, duration: 0.45), 1);
      expect(phase(3, delay: 0.5, duration: 0.45), 1);
      expect(phase(1e9, delay: 0.5, duration: 0.45), 1);
    });

    test('is linear by default in the middle', () {
      expect(phase(1.5, delay: 1, duration: 2), closeTo(0.25, _eps));
      expect(phase(2, delay: 1, duration: 2), closeTo(0.5, _eps));
      expect(phase(2.5, delay: 1, duration: 2), closeTo(0.75, _eps));
    });

    test('applies the curve in the middle', () {
      expect(
        phase(0.725, delay: 0.5, duration: 0.45, curve: labEaseInOut),
        closeTo(0.5, 1e-6),
      );
      expect(
        phase(1.5, delay: 1, duration: 2, curve: labEaseOut),
        closeTo(labEaseOut.transform(0.25), _eps),
      );
      expect(
        phase(1.5, delay: 1, duration: 2, curve: labEaseOut),
        greaterThan(0.25),
      );
      expect(
        phase(2.5, delay: 1, duration: 2, curve: labEaseIn),
        closeTo(labEaseIn.transform(0.75), _eps),
      );
    });

    test('without delay starts at t 0', () {
      expect(phase(0, delay: 0, duration: 0.7), 0);
      expect(phase(0.35, delay: 0, duration: 0.7), closeTo(0.5, _eps));
      expect(phase(0.7, delay: 0, duration: 0.7), 1);
    });

    test('with duration 0 is a step at the delay', () {
      expect(phase(0.99, delay: 1, duration: 0), 0);
      expect(phase(1, delay: 1, duration: 0), 1);
      expect(phase(2, delay: 1, duration: 0), 1);
      expect(phase(2, delay: 1, duration: -3), 1);
      expect(phase(0, delay: 1, duration: -3), 0);
    });

    test('with odd inputs is always finite and between 0 and 1', () {
      for (final t in _rawInputs) {
        for (final delay in _rawInputs) {
          for (final duration in _rawInputs) {
            final value = phase(t, delay: delay, duration: duration);
            expect(value.isFinite, isTrue, reason: '$t $delay $duration');
            expect(value, inInclusiveRange(0, 1));
            final curved = phase(
              t,
              delay: delay,
              duration: duration,
              curve: labSwing,
            );
            expect(curved.isFinite, isTrue, reason: '$t $delay $duration');
            expect(curved, inInclusiveRange(0, 1));
          }
        }
      }
    });

    test('NaN as time gives 0 and infinity gives 1', () {
      expect(phase(double.nan, delay: 0, duration: 1), 0);
      expect(phase(double.infinity, delay: 0, duration: 1), 1);
      expect(phase(double.negativeInfinity, delay: 0, duration: 1), 0);
    });
  });

  group('E284 keyframes', () {
    test('p1FallD at 1.87 s gives -56', () {
      expect(_fallAt(1.87), closeTo(-56, 1e-6));
    });

    test('p1FallD keeps the first frame before the delay', () {
      expect(_fallAt(0), 0);
      expect(_fallAt(1.32), 0);
    });

    test('p1FallD keeps the last frame after the end', () {
      expect(_fallAt(2.32), closeTo(-50, 1e-5));
      expect(_fallAt(2.33), closeTo(-50, _eps));
      expect(_fallAt(10), closeTo(-50, _eps));
      expect(_fallAt(1e9), closeTo(-50, _eps));
    });

    test('each span uses the curve of the frame where it starts', () {
      expect(
        _fallAt(1.32 + 0.275),
        closeTo(-56 * labEaseIn.transform(0.5), 1e-6),
      );
      expect(
        _fallAt(1.32 + 0.65),
        closeTo(-56 + 12 * labEaseOut.transform(0.5), 1e-6),
      );
    });

    test('a frame without its own curve uses the curve of the animation', () {
      expect(
        _fallAt(1.32 + 0.875),
        closeTo(-44 - 6 * Curves.ease.transform(0.5), 1e-6),
      );
      expect(
        keyframes(1.32 + 0.875, delay: 1.32, duration: 1, frames: _p1FallD),
        closeTo(-47, 1e-6),
      );
    });

    test('ping2 fades out by 70 % and stays there', () {
      const frames = [Kf(0, 0.45), Kf(0.7, 0), Kf(1, 0)];
      double at(double t) => keyframes(
        t,
        delay: 0,
        duration: 2.6,
        frames: frames,
        curve: labEaseOut,
      );
      expect(at(0), closeTo(0.45, _eps));
      expect(at(0.91), closeTo(0.45 * (1 - labEaseOut.transform(0.5)), 1e-6));
      expect(at(1.82), closeTo(0, 1e-6));
      expect(at(2.2), 0);
      expect(at(2.6), 0);
    });

    test('a frame repeated at two stops holds its value between them', () {
      const frames = [Kf(0, 1), Kf(0.8, 1), Kf(1, 0)];
      double at(double t) =>
          keyframes(t, delay: 0, duration: 1.95, frames: frames);
      expect(at(0), 1);
      expect(at(0.78), 1);
      expect(at(1.56), closeTo(1, _eps));
      expect(at(1.755), closeTo(0.5, 1e-6));
      expect(at(1.95), 0);
    });

    test('two frames at the same stop jump without dividing by zero', () {
      const frames = [Kf(0, 0), Kf(0.5, 0), Kf(0.5, 10), Kf(1, 10)];
      double at(double t) =>
          keyframes(t, delay: 0, duration: 1, frames: frames);
      expect(at(0.25), 0);
      expect(at(0.75), 10);
      for (final t in [0.0, 0.4999, 0.5, 0.5001, 1.0]) {
        expect(at(t).isFinite, isTrue);
      }
    });

    test('a single frame is a constant', () {
      for (final t in [0.0, 0.5, 1.0, 100.0]) {
        expect(
          keyframes(t, delay: 0, duration: 1, frames: const [Kf(0.4, 7)]),
          7,
        );
      }
    });

    test('with no frames is 0', () {
      expect(keyframes(0.5, delay: 0, duration: 1, frames: const []), 0);
    });

    test('with duration 0 is the first frame before and the last after', () {
      expect(_keyframesZero(0.5), 0);
      expect(_keyframesZero(1), closeTo(-50, _eps));
      expect(_keyframesZero(3), closeTo(-50, _eps));
    });

    test('with odd inputs is finite and inside the range of the frames', () {
      for (final t in _rawInputs) {
        for (final delay in _rawInputs) {
          for (final duration in _rawInputs) {
            final value = keyframes(
              t,
              delay: delay,
              duration: duration,
              frames: _p1FallD,
              curve: Curves.ease,
            );
            expect(value.isFinite, isTrue, reason: '$t $delay $duration');
            expect(value, inInclusiveRange(-56.5, 0));
          }
        }
      }
    });
  });

  group('E284 loopPhase', () {
    test('is the fraction of the current cycle', () {
      expect(loopPhase(0, period: 1.8), 0);
      expect(loopPhase(0.9, period: 1.8), closeTo(0.5, _eps));
      expect(loopPhase(1.35, period: 1.8), closeTo(0.75, _eps));
      expect(loopPhase(2.7, period: 1.8), closeTo(0.5, 1e-9));
      expect(loopPhase(2.5, period: 10), closeTo(0.25, _eps));
      expect(loopPhase(12.5, period: 10), closeTo(0.25, 1e-9));
    });

    test('is 0 before the delay and counts the cycle from it', () {
      expect(loopPhase(0, period: 2.6, delay: 1.6), 0);
      expect(loopPhase(1.59, period: 2.6, delay: 1.6), 0);
      expect(loopPhase(1.6, period: 2.6, delay: 1.6), 0);
      expect(loopPhase(2.9, period: 2.6, delay: 1.6), closeTo(0.5, 1e-9));
      expect(
        loopPhase(1.6 + 2.6 * 3 + 1.3, period: 2.6, delay: 1.6),
        closeTo(0.5, 1e-9),
      );
    });

    test('always stays in [0, 1) for large times', () {
      for (final t in [59.99, 1e3, 123456.789, 1e6, 1e9, 1e12, 1e15]) {
        final value = loopPhase(t, period: 1.8, delay: 0.3);
        expect(value.isFinite, isTrue, reason: '$t');
        expect(value, greaterThanOrEqualTo(0));
        expect(value, lessThan(1));
      }
    });

    test('with odd inputs is finite and in [0, 1)', () {
      for (final t in _rawInputs) {
        for (final period in _rawInputs) {
          for (final delay in _rawInputs) {
            final value = loopPhase(t, period: period, delay: delay);
            expect(value.isFinite, isTrue, reason: '$t $period $delay');
            expect(value, greaterThanOrEqualTo(0));
            expect(value, lessThan(1), reason: '$t $period $delay');
          }
        }
      }
    });

    test('a delay of minus infinity still gives a finite phase', () {
      final value = loopPhase(1, period: 1.8, delay: double.negativeInfinity);
      expect(value.isFinite, isTrue);
      expect(value, inInclusiveRange(0, 1));
    });

    test('a period of 0 or less, NaN or infinite times give 0', () {
      expect(loopPhase(1, period: 0), 0);
      expect(loopPhase(1, period: -2), 0);
      expect(loopPhase(1, period: double.nan), 0);
      expect(loopPhase(double.nan, period: 1.8), 0);
      expect(loopPhase(double.infinity, period: 1.8), 0);
    });
  });

  group('E284 dashWindow', () {
    test('a stroke that draws itself in grows from the start', () {
      expect(dashWindow(1), (0.0, 0.0));
      expect(dashWindow(0.7).$1, 0);
      expect(dashWindow(0.7).$2, closeTo(0.3, _eps));
      expect(dashWindow(0.5), (0.0, 0.5));
      expect(dashWindow(0), (0.0, 1.0));
    });

    test('a negative offset hides the start', () {
      expect(dashWindow(-0.25), (0.25, 1.0));
      expect(dashWindow(-0.6).$1, closeTo(0.6, _eps));
      expect(dashWindow(-0.6).$2, 1);
    });

    test('a window past the ends is empty', () {
      final ahead = dashWindow(2);
      expect(ahead.$2 <= ahead.$1, isTrue);
      final behind = dashWindow(-1);
      expect(behind.$2 <= behind.$1, isTrue);
      final far = dashWindow(-3);
      expect(far.$2 <= far.$1, isTrue);
    });

    test('an offset of minus infinity gives a finite window', () {
      final (from, to) = dashWindow(double.negativeInfinity);
      expect(from.isFinite, isTrue);
      expect(to.isFinite, isTrue);
    });

    test('with odd offsets is finite and never ends past 1', () {
      for (final offset in _rawInputs) {
        final (from, to) = dashWindow(offset);
        expect(from.isFinite, isTrue, reason: '$offset');
        expect(to.isFinite, isTrue, reason: '$offset');
        expect(from, greaterThanOrEqualTo(0), reason: '$offset');
        expect(to, inInclusiveRange(0, 1), reason: '$offset');
      }
    });
  });

  group('E284 partialPath', () {
    final line = Path()
      ..moveTo(0, 0)
      ..lineTo(100, 0);
    final twoLines = Path()
      ..moveTo(0, 0)
      ..lineTo(100, 0)
      ..moveTo(0, 10)
      ..lineTo(300, 10);

    test('cuts a fraction of a single line', () {
      final middle = partialPath(line, 0.25, 0.75);
      expect(_length(middle), closeTo(50, 1e-6));
      final bounds = middle.getBounds();
      expect(bounds.left, closeTo(25, 1e-6));
      expect(bounds.right, closeTo(75, 1e-6));
    });

    test('the whole range keeps the whole path', () {
      expect(_length(partialPath(line, 0, 1)), closeTo(100, 1e-6));
      expect(_length(partialPath(twoLines, 0, 1)), closeTo(400, 1e-6));
      expect(_lengths(partialPath(twoLines, 0, 1)), hasLength(2));
    });

    test('measures fractions over the total length of every contour', () {
      final start = partialPath(twoLines, 0, 0.25);
      expect(_lengths(start), [closeTo(100, 1e-6)]);
      expect(start.getBounds().top, closeTo(0, 1e-6));

      final across = partialPath(twoLines, 0.125, 0.5);
      final pieces = _lengths(across);
      expect(pieces, hasLength(2));
      expect(pieces[0], closeTo(50, 1e-6));
      expect(pieces[1], closeTo(100, 1e-6));
      expect(
        across.getBounds(),
        _rectClose(const Rect.fromLTRB(0, 0, 100, 10)),
      );
      final first = across.computeMetrics().first.extractPath(0, 1e-3);
      expect(first.getBounds().left, closeTo(50, 1e-3));

      final end = partialPath(twoLines, 0.5, 1);
      expect(_lengths(end), [closeTo(200, 1e-6)]);
      expect(
        end.getBounds(),
        _rectClose(const Rect.fromLTRB(100, 10, 300, 10)),
      );
    });

    test('half a circle of radius 56 is half its circumference', () {
      final circle = Path()
        ..addOval(Rect.fromCircle(center: const Offset(150, 85), radius: 56));
      expect(
        _length(partialPath(circle, 0, 0.5)),
        closeTo(_length(circle) / 2, 1e-3),
      );
      expect(_length(circle), closeTo(351.86, 1));
    });

    test('an empty or reversed range gives an empty path', () {
      expect(_length(partialPath(line, 0.5, 0.5)), 0);
      expect(_length(partialPath(line, 0.8, 0.2)), 0);
      expect(_length(partialPath(line, 1, 1)), 0);
      expect(_length(partialPath(line, 0, 0)), 0);
    });

    test('fractions out of range are clamped', () {
      expect(_length(partialPath(line, -1, 0.5)), closeTo(50, 1e-6));
      expect(_length(partialPath(line, 0.5, 4)), closeTo(50, 1e-6));
      expect(_length(partialPath(line, -5, 5)), closeTo(100, 1e-6));
      expect(_length(partialPath(line, 2, 3)), 0);
    });

    test('an empty source gives an empty path', () {
      expect(_length(partialPath(Path(), 0, 1)), 0);
    });

    test('with odd fractions never throws and stays finite', () {
      for (final from in _rawInputs) {
        for (final to in _rawInputs) {
          final cut = partialPath(twoLines, from, to);
          final length = _length(cut);
          expect(length.isFinite, isTrue, reason: '$from $to');
          expect(length, inInclusiveRange(0, 400 + 1e-6));
        }
      }
    });

    test('does not change the source path', () {
      partialPath(twoLines, 0.2, 0.6);
      expect(_length(twoLines), closeTo(400, 1e-6));
    });
  });
}

double _keyframesZero(double t) =>
    keyframes(t, delay: 1, duration: 0, frames: _p1FallD, curve: Curves.ease);

Matcher _rectClose(Rect expected) => isA<Rect>()
    .having((r) => r.left, 'left', closeTo(expected.left, 1e-6))
    .having((r) => r.top, 'top', closeTo(expected.top, 1e-6))
    .having((r) => r.right, 'right', closeTo(expected.right, 1e-6))
    .having((r) => r.bottom, 'bottom', closeTo(expected.bottom, 1e-6));
