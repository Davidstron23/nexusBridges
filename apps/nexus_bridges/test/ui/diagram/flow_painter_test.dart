import 'dart:math' as math;
import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:nexus_bridges/src/ui/diagram/flow_painter.dart';

const double _tolerance = 0.01;

List<PathMetric> _metrics(Path path) => path.computeMetrics().toList();

double _lengthOf(Path path) =>
    _metrics(path).fold<double>(0, (sum, metric) => sum + metric.length);

List<(double, double)> _dashesAlongX(Path path) => [
  for (final metric in _metrics(path))
    (
      metric.getTangentForOffset(0)!.position.dx,
      metric.getTangentForOffset(metric.length)!.position.dx,
    ),
];

void _expectDashes(Path path, List<(double, double)> expected) {
  final actual = _dashesAlongX(path);
  expect(actual, hasLength(expected.length), reason: '$actual');
  for (var i = 0; i < expected.length; i++) {
    expect(actual[i].$1, closeTo(expected[i].$1, _tolerance), reason: '$i');
    expect(actual[i].$2, closeTo(expected[i].$2, _tolerance), reason: '$i');
  }
}

Path _line(double length) => Path()
  ..moveTo(0, 0)
  ..lineTo(length, 0);

void main() {
  group('dashPath', () {
    test('3 3 cuts a line into dashes and gaps of 3', () {
      _expectDashes(dashPath(_line(30), const [3, 3]), const [
        (0, 3),
        (6, 9),
        (12, 15),
        (18, 21),
        (24, 27),
      ]);
    });

    test('the last dash is cut at the end of the path', () {
      _expectDashes(dashPath(_line(10), const [4, 2]), const [(0, 4), (6, 10)]);
      _expectDashes(dashPath(_line(8), const [3, 3]), const [(0, 3), (6, 8)]);
    });

    test('the phase moves the pattern along the path', () {
      _expectDashes(dashPath(_line(15), const [3, 3], phase: 3), const [
        (3, 6),
        (9, 12),
      ]);
      _expectDashes(dashPath(_line(12), const [3, 3], phase: 1), const [
        (0, 2),
        (5, 8),
        (11, 12),
      ]);
      _expectDashes(dashPath(_line(12), const [3, 3], phase: 7), const [
        (0, 2),
        (5, 8),
        (11, 12),
      ]);
    });

    test('a negative phase moves the pattern the other way', () {
      _expectDashes(dashPath(_line(12), const [3, 3], phase: -1), const [
        (1, 4),
        (7, 10),
      ]);
    });

    test('an odd pattern repeats itself, as in SVG', () {
      _expectDashes(dashPath(_line(20), const [4]), const [
        (0, 4),
        (8, 12),
        (16, 20),
      ]);
      _expectDashes(dashPath(_line(12), const [2, 1, 3]), const [
        (0, 2),
        (3, 6),
        (8, 9),
      ]);
    });

    test('each subpath starts the pattern again', () {
      final source = Path()
        ..moveTo(0, 0)
        ..lineTo(8, 0)
        ..moveTo(0, 10)
        ..lineTo(8, 10);
      final dashed = dashPath(source, const [3, 3]);
      final metrics = _metrics(dashed);
      expect(metrics, hasLength(4));
      expect(metrics[0].length, closeTo(3, _tolerance));
      expect(metrics[1].length, closeTo(2, _tolerance));
      expect(metrics[2].getTangentForOffset(0)!.position, const Offset(0, 10));
      expect(metrics[2].length, closeTo(3, _tolerance));
    });

    test('a large circle dashed 30 30 keeps half of its length', () {
      final circle = Path()
        ..addOval(Rect.fromCircle(center: Offset.zero, radius: 400));
      final dashed = dashPath(circle, const [30, 30]);
      final circumference = 2 * math.pi * 400;
      expect(_lengthOf(dashed), closeTo(circumference / 2, 30));
      expect(_metrics(dashed), hasLength((circumference / 60).ceil()));
      for (final metric in _metrics(dashed)) {
        expect(metric.length, lessThanOrEqualTo(30.1));
      }
    });

    test('the disc outline dashed 3 3 stays on the circle', () {
      final circle = Path()
        ..addOval(Rect.fromCircle(center: const Offset(19, 19), radius: 18.4));
      final dashed = dashPath(circle, const [3, 3]);
      expect(_metrics(dashed).length, inInclusiveRange(18, 21));
      for (final metric in _metrics(dashed)) {
        for (final t in [0.0, 0.5, 1.0]) {
          final point = metric.getTangentForOffset(metric.length * t)!.position;
          expect((point - const Offset(19, 19)).distance, closeTo(18.4, 0.05));
        }
      }
    });

    test('an empty pattern leaves the path solid', () {
      final dashed = dashPath(_line(30), const []);
      _expectDashes(dashed, const [(0, 30)]);
    });

    test('zero, negative or infinite lengths leave the path solid', () {
      for (final pattern in const [
        [3.0, 0.0],
        [0.0],
        [-1.0, 2.0],
        [3.0, -3.0],
        [double.infinity, 2.0],
        [double.nan],
      ]) {
        final dashed = dashPath(_line(30), pattern);
        _expectDashes(dashed, const [(0, 30)]);
      }
    });

    test('a non finite phase leaves the path solid', () {
      for (final phase in [double.nan, double.infinity]) {
        _expectDashes(dashPath(_line(30), const [3, 3], phase: phase), const [
          (0, 30),
        ]);
      }
    });

    test('the solid copy is a new path', () {
      final source = _line(30);
      final copy = dashPath(source, const []);
      expect(identical(copy, source), isFalse);
      copy.lineTo(30, 30);
      expect(_lengthOf(source), closeTo(30, _tolerance));
    });

    test('an empty source gives an empty path', () {
      expect(_metrics(dashPath(Path(), const [3, 3])), isEmpty);
    });

    test('very short dashes on a long path finish', () {
      final dashed = dashPath(_line(1000), const [0.5, 0.5]);
      expect(_metrics(dashed), hasLength(1000));
      expect(_lengthOf(dashed), closeTo(500, 0.1));
    });
  });
}
