import 'dart:io';
import 'dart:math' as math;
import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:nexus_bridges/src/ui/brand/brand_mark.dart';
import 'package:nexus_bridges/src/ui/icons/glyphs.dart';
import 'package:nexus_bridges/src/ui/icons/svg_path.dart';

const double _tolerance = 0.01;

Rect _tightBounds(Path path) {
  var left = double.infinity;
  var top = double.infinity;
  var right = double.negativeInfinity;
  var bottom = double.negativeInfinity;
  for (final metric in path.computeMetrics()) {
    final steps = math.max(720, (metric.length * 400).ceil());
    for (var i = 0; i <= steps; i++) {
      final point = metric
          .getTangentForOffset(metric.length * i / steps)!
          .position;
      if (point.dx < left) left = point.dx;
      if (point.dy < top) top = point.dy;
      if (point.dx > right) right = point.dx;
      if (point.dy > bottom) bottom = point.dy;
    }
  }
  return Rect.fromLTRB(left, top, right, bottom);
}

void _expectRect(Rect actual, Rect expected) {
  expect(actual.left, closeTo(expected.left, _tolerance), reason: 'left');
  expect(actual.top, closeTo(expected.top, _tolerance), reason: 'top');
  expect(actual.right, closeTo(expected.right, _tolerance), reason: 'right');
  expect(actual.bottom, closeTo(expected.bottom, _tolerance), reason: 'bottom');
}

void _expectOffset(Offset actual, Offset expected) {
  expect(actual.dx, closeTo(expected.dx, _tolerance), reason: 'dx');
  expect(actual.dy, closeTo(expected.dy, _tolerance), reason: 'dy');
}

List<PathMetric> _metrics(Path path) => path.computeMetrics().toList();

Offset _startOf(PathMetric metric) => metric.getTangentForOffset(0)!.position;

Offset _endOf(PathMetric metric) =>
    metric.getTangentForOffset(metric.length)!.position;

double _lengthOf(Path path) =>
    _metrics(path).fold<double>(0, (sum, metric) => sum + metric.length);

Matcher _formatErrorAt(int offset) =>
    isA<FormatException>().having((error) => error.offset, 'offset', offset);

final RegExp _pathCall = RegExp(
  r"""(?:SvgShape|parseSvgPath)\(\s*((?:'[^']*'\s*)+)""",
);
final RegExp _pathConstant = RegExp(
  r"""const String \w+Path =\s*((?:'[^']*'\s*)+);""",
);
final RegExp _literal = RegExp(r"'([^']*)'");

const List<String> _modalGlyphPaths = [
  'M4.5 4.5l7 7M11.5 4.5l-7 7',
  'M3.5 8.4l3 2.9 6-6.6',
  'M3 5.5h9.5M10 3l2.5 2.5L10 8M13 10.5H3.5M6 8l-2.5 2.5L6 13',
  'M7.3 4.6l1-1a2.6 2.6 0 0 1 3.7 3.7l-1 1M8.7 11.4l-1 1A2.6 2.6 0 0 1 4 '
      '8.7l1-1M3 3l1.5 1.5M13 13l-1.5-1.5',
  'M8 3.5v9M4.5 9L8 12.5 11.5 9',
  'M4 10.6L12 4l8 6.6V19a1.5 1.5 0 0 1-1.5 1.5h-13A1.5 1.5 0 0 1 4 19z',
  'M9 14.6l2.2 2.1 4-4.3',
  'M3.5 19.5c.6-3.3 2.8-5.2 5.5-5.2c2.7 0 4.9 1.9 5.5 5.2',
  'M15.5 6.2a3 3 0 0 1 0 5.6M17.5 14.6c1.6.6 2.6 2.2 3 4.9',
  'M12 1.8l8.4 3.1v6.3c0 5.3-3.4 9.1-8.4 11.1-5-2-8.4-5.8-8.4-11.1V4.9z',
  'M7.2 10.2a6.8 6.8 0 0 1 9.6 0M9.1 12.4a4 4 0 0 1 5.8 0',
];

Map<String, List<String>> _programPaths() {
  final found = <String, List<String>>{};
  final directory = Directory(
    'lib${Platform.pathSeparator}src${Platform.pathSeparator}ui',
  );
  for (final entity in directory.listSync(recursive: true)) {
    if (entity is! File || !entity.path.endsWith('.dart')) continue;
    final source = entity.readAsStringSync();
    final name = entity.uri.pathSegments.last;
    for (final pattern in [_pathCall, _pathConstant]) {
      for (final match in pattern.allMatches(source)) {
        final data = _literal
            .allMatches(match.group(1)!)
            .map((literal) => literal.group(1)!)
            .join();
        found.putIfAbsent(name, () => []).add(data);
      }
    }
  }
  return found;
}

void main() {
  group('E257: absolute and relative commands', () {
    test('M and L draw a straight line between absolute points', () {
      final path = parseSvgPath('M10 20L30 40');
      final metrics = _metrics(path);
      expect(metrics, hasLength(1));
      _expectOffset(_startOf(metrics.single), const Offset(10, 20));
      _expectOffset(_endOf(metrics.single), const Offset(30, 40));
      _expectRect(_tightBounds(path), const Rect.fromLTRB(10, 20, 30, 40));
    });

    test('pairs after m are relative line-tos and z closes the subpath', () {
      final path = parseSvgPath('m10 10 20 0 0 20z');
      final metrics = _metrics(path);
      expect(metrics, hasLength(1));
      expect(metrics.single.isClosed, isTrue);
      _expectOffset(_startOf(metrics.single), const Offset(10, 10));
      expect(metrics.single.length, closeTo(40 + 20 * 1.4142135, 0.01));
      _expectRect(_tightBounds(path), const Rect.fromLTRB(10, 10, 30, 30));
    });

    test('pairs after M are absolute line-tos', () {
      final path = parseSvgPath('M10 10 20 10 20 30');
      final metric = _metrics(path).single;
      _expectOffset(_endOf(metric), const Offset(20, 30));
      expect(metric.length, closeTo(30, _tolerance));
    });

    test('H, V, h and v move along one axis from the current point', () {
      final path = parseSvgPath('M0 0H10V5h-4v.5');
      final metric = _metrics(path).single;
      _expectOffset(_endOf(metric), const Offset(6, 5.5));
      expect(metric.length, closeTo(19.5, _tolerance));
      _expectRect(_tightBounds(path), const Rect.fromLTRB(0, 0, 10, 5.5));
    });

    test('L, l, H and V repeat implicitly with more numbers', () {
      final lines = parseSvgPath('M0 0L10 0 10 10l-10 0 0-10');
      expect(_lengthOf(lines), closeTo(40, _tolerance));
      _expectOffset(_endOf(_metrics(lines).single), Offset.zero);

      final horizontal = parseSvgPath('M0 0H5 10V3 7');
      _expectOffset(_endOf(_metrics(horizontal).single), const Offset(10, 7));
      expect(_lengthOf(horizontal), closeTo(17, _tolerance));
    });

    test('a second relative m starts from the current point', () {
      final path = parseSvgPath('M10 10L20 10m5 5l1 0');
      final metrics = _metrics(path);
      expect(metrics, hasLength(2));
      _expectOffset(_startOf(metrics.last), const Offset(25, 15));
      _expectOffset(_endOf(metrics.last), const Offset(26, 15));
    });

    test('after z, a relative l starts again from the subpath start', () {
      final path = parseSvgPath('M0 0l10 0z l0 10');
      final metrics = _metrics(path);
      expect(metrics, hasLength(2));
      _expectOffset(_startOf(metrics.last), Offset.zero);
      _expectOffset(_endOf(metrics.last), const Offset(0, 10));
      _expectRect(_tightBounds(path), const Rect.fromLTRB(0, 0, 10, 10));
    });

    test('after Z away from the origin, relative l and m use its start', () {
      final line = _metrics(parseSvgPath('M5 5l10 0Zl0 10')).last;
      _expectOffset(_startOf(line), const Offset(5, 5));
      _expectOffset(_endOf(line), const Offset(5, 15));

      final moved = _metrics(parseSvgPath('M5 5h10zm1 1h2')).last;
      _expectOffset(_startOf(moved), const Offset(6, 6));
      _expectOffset(_endOf(moved), const Offset(8, 6));
    });
  });

  group('E257: numbers and separators', () {
    test('the sign separates two numbers', () {
      final metric = _metrics(parseSvgPath('M1.5-3.6l1.5-3.6')).single;
      _expectOffset(_startOf(metric), const Offset(1.5, -3.6));
      _expectOffset(_endOf(metric), const Offset(3, -7.2));
    });

    test('.5.5 are two numbers without leading zeros', () {
      final metric = _metrics(parseSvgPath('M.5.5L1 1')).single;
      _expectOffset(_startOf(metric), const Offset(0.5, 0.5));
      final chained = _metrics(parseSvgPath('M1.5.5L0 0')).single;
      _expectOffset(_startOf(chained), const Offset(1.5, 0.5));
    });

    test('exponents are read with either case and an optional sign', () {
      _expectOffset(
        _startOf(_metrics(parseSvgPath('M1e1 0L0 0')).single),
        const Offset(10, 0),
      );
      _expectOffset(
        _startOf(_metrics(parseSvgPath('M1E+1 2e-1L0 0')).single),
        const Offset(10, 0.2),
      );
      _expectOffset(
        _startOf(_metrics(parseSvgPath('M-.5e1+3L0 0')).single),
        const Offset(-5, 3),
      );
    });

    test('spaces, commas, tabs and line breaks are separators', () {
      final path = parseSvgPath(' M0,0\tL10\n10\r\nL 20 , 0 ');
      final metric = _metrics(path).single;
      _expectOffset(_endOf(metric), const Offset(20, 0));
      _expectRect(_tightBounds(path), const Rect.fromLTRB(0, 0, 20, 10));
    });

    test('an empty string or only separators give an empty path', () {
      for (final data in ['', '   ', ' ,\t\n\r ']) {
        final path = parseSvgPath(data);
        expect(_metrics(path), isEmpty, reason: '"$data"');
        expect(path.getBounds(), Rect.zero, reason: '"$data"');
      }
    });

    test('a lone move-to parses without drawing anything', () {
      expect(_metrics(parseSvgPath('M1.5-3.6')), isEmpty);
      expect(_metrics(parseSvgPath('M.5.5')), isEmpty);
    });
  });

  group('E257: cubic curves', () {
    test('C reaches y = 7.5 at its middle', () {
      final path = parseSvgPath('M0 0C0 10 10 10 10 0');
      _expectRect(_tightBounds(path), const Rect.fromLTRB(0, 0, 10, 7.5));
      _expectOffset(_endOf(_metrics(path).single), const Offset(10, 0));
    });

    test('c repeats implicitly relative to the end of the previous curve', () {
      final path = parseSvgPath('M0 0c0 10 10 10 10 0 0 10 10 10 10 0');
      _expectRect(_tightBounds(path), const Rect.fromLTRB(0, 0, 20, 7.5));
      _expectOffset(_endOf(_metrics(path).single), const Offset(20, 0));
      final halfway = _metrics(path).single
          .getTangentForOffset(_metrics(path).single.length / 2)!;
      _expectOffset(halfway.position, const Offset(10, 0));
    });

    test('C repeats implicitly with absolute points', () {
      final path = parseSvgPath('M0 0C0 10 10 10 10 0 10 -10 20 -10 20 0');
      _expectRect(_tightBounds(path), const Rect.fromLTRB(0, -7.5, 20, 7.5));
    });
  });

  group('E257: arcs', () {
    test('with sweep 1 the half circle goes up to y = -5', () {
      final path = parseSvgPath('M0 0A5 5 0 0 1 10 0');
      _expectRect(_tightBounds(path), const Rect.fromLTRB(0, -5, 10, 0));
      _expectOffset(_endOf(_metrics(path).single), const Offset(10, 0));
    });

    test('with sweep 0 the half circle goes down to y = 5', () {
      final path = parseSvgPath('M0 0A5 5 0 0 0 10 0');
      _expectRect(_tightBounds(path), const Rect.fromLTRB(0, 0, 10, 5));
    });

    test('the large-arc flag picks the long way round', () {
      final small = parseSvgPath('M5 0A5 5 0 0 1 0 5');
      _expectRect(_tightBounds(small), const Rect.fromLTRB(0, 0, 5, 5));

      final large = parseSvgPath('M5 0A5 5 0 1 1 0 5');
      _expectRect(_tightBounds(large), const Rect.fromLTRB(0, 0, 10, 10));
    });

    test('the arc lengths are a quarter and three quarters of a turn', () {
      final small = parseSvgPath('M500 0A500 500 0 0 1 0 500');
      expect(_lengthOf(small), closeTo(3.14159265 * 500 / 2, 0.5));
      final large = parseSvgPath('M500 0A500 500 0 1 1 0 500');
      expect(_lengthOf(large), closeTo(3.14159265 * 500 * 3 / 2, 1.5));
    });

    test('the compact flags read like the long form', () {
      final compact = _tightBounds(parseSvgPath('M0 0a5 5 0 0110 0'));
      final long = _tightBounds(parseSvgPath('M0 0a5 5 0 0 1 10 0'));
      _expectRect(compact, long);
      _expectRect(compact, const Rect.fromLTRB(0, -5, 10, 0));
      final glued = _tightBounds(parseSvgPath('M0 0A5,5,0,0,1,10,0'));
      _expectRect(glued, const Rect.fromLTRB(0, -5, 10, 0));
    });

    test('a relative arc ends relative to the current point', () {
      final path = parseSvgPath('M10 10a5 5 0 0 1 10 0');
      _expectRect(_tightBounds(path), const Rect.fromLTRB(10, 5, 20, 10));
      _expectOffset(_endOf(_metrics(path).single), const Offset(20, 10));
    });

    test('negative radii use their absolute value', () {
      final path = parseSvgPath('M0 0A-5 -5 0 0 1 10 0');
      _expectRect(_tightBounds(path), const Rect.fromLTRB(0, -5, 10, 0));
    });

    test('a zero radius draws a straight line', () {
      for (final data in [
        'M0 0A0 5 0 0 1 10 0',
        'M0 0A5 0 0 0 1 10 0',
        'M0 0a0 0 0 1 1 10 0',
      ]) {
        final path = parseSvgPath(data);
        expect(_lengthOf(path), closeTo(10, _tolerance), reason: data);
        _expectRect(_tightBounds(path), const Rect.fromLTRB(0, 0, 10, 0));
      }
    });

    test('a line after an arc starts where the arc ended', () {
      final path = parseSvgPath('M0 0a5 5 0 0 1 10 0l0 10');
      _expectOffset(_endOf(_metrics(path).single), const Offset(10, 10));
    });
  });

  group('E257: errors', () {
    test('Q, S, T and other letters throw with their position', () {
      expect(() => parseSvgPath('M0 0Q1 1 2 2'), throwsA(_formatErrorAt(4)));
      expect(() => parseSvgPath('M0 0S1 1 2 2'), throwsA(_formatErrorAt(4)));
      expect(() => parseSvgPath('M0 0T1 1'), throwsA(_formatErrorAt(4)));
      expect(() => parseSvgPath('M0 0 X1 1'), throwsA(_formatErrorAt(5)));
      expect(() => parseSvgPath('M1 x'), throwsA(_formatErrorAt(3)));
    });

    test('a path that does not start with M or m throws', () {
      expect(() => parseSvgPath('L1 1'), throwsA(_formatErrorAt(0)));
      expect(() => parseSvgPath('  l1 1'), throwsA(_formatErrorAt(2)));
      expect(() => parseSvgPath('z'), throwsA(_formatErrorAt(0)));
      expect(() => parseSvgPath('1 2'), throwsA(_formatErrorAt(0)));
    });

    test('a missing number throws', () {
      expect(() => parseSvgPath('M0'), throwsFormatException);
      expect(() => parseSvgPath('M0 0L1'), throwsFormatException);
      expect(() => parseSvgPath('M0 0C1 1 2 2 3'), throwsFormatException);
      expect(() => parseSvgPath('M0 0A5 5 0 0 1 10'), throwsFormatException);
      expect(() => parseSvgPath('M0 0H'), throwsFormatException);
    });

    test('malformed numbers throw', () {
      expect(() => parseSvgPath('M- 1'), throwsFormatException);
      expect(() => parseSvgPath('M. 1'), throwsFormatException);
      expect(() => parseSvgPath('M1e 2'), throwsFormatException);
      expect(() => parseSvgPath('M1e+ 2'), throwsFormatException);
      expect(() => parseSvgPath('M0 0\u00e9'), throwsFormatException);
    });

    test('an arc flag other than 0 or 1 throws at the flag', () {
      expect(
        () => parseSvgPath('M0 0A5 5 0 2 1 10 0'),
        throwsA(_formatErrorAt(11)),
      );
      expect(
        () => parseSvgPath('M0 0a5 5 0 0 x 10 0'),
        throwsA(_formatErrorAt(13)),
      );
      expect(() => parseSvgPath('M0 0A5 5 0 0'), throwsFormatException);
    });

    test('a number right after a close command throws', () {
      expect(() => parseSvgPath('M0 0L1 1Z 5 5'), throwsFormatException);
    });
  });

  group('E257: every path of the program parses', () {
    test('the glyphs and both brand marks parse into drawable paths', () {
      final glyphs = [
        Glyphs.refresh,
        Glyphs.send,
        Glyphs.link,
        Glyphs.check,
        Glyphs.ban,
        Glyphs.folder,
        Glyphs.warn,
        Glyphs.pc,
        Glyphs.phone,
        Glyphs.shield,
        Glyphs.more,
        Glyphs.cross,
        Glyphs.tick,
        Glyphs.swap,
        Glyphs.unlink,
        Glyphs.arrowDown,
        Glyphs.mine,
        Glyphs.someoneElse,
        Glyphs.networkShield,
      ];
      for (final glyph in glyphs) {
        for (final part in glyph.parts) {
          final shape = part.shape;
          if (shape is SvgShape) {
            expect(_metrics(parseSvgPath(shape.data)), isNotEmpty);
          }
        }
      }
      expect(_metrics(parseSvgPath(brandMarkPath)), hasLength(2));
      expect(_metrics(parseSvgPath(brandMarkFullPath)), hasLength(6));
    });

    test('the eight glyphs of the modals parse into the expected shapes '
        '(E281)', () {
      _expectRect(
        _tightBounds(parseSvgPath(_modalGlyphPaths[0])),
        const Rect.fromLTRB(4.5, 4.5, 11.5, 11.5),
      );
      expect(_metrics(parseSvgPath(_modalGlyphPaths[0])), hasLength(2));
      _expectRect(
        _tightBounds(parseSvgPath(_modalGlyphPaths[2])),
        const Rect.fromLTRB(3, 3, 13, 13),
      );
      expect(_metrics(parseSvgPath(_modalGlyphPaths[2])), hasLength(4));
      expect(_metrics(parseSvgPath(_modalGlyphPaths[3])), hasLength(4));
      _expectRect(
        _tightBounds(parseSvgPath(_modalGlyphPaths[4])),
        const Rect.fromLTRB(4.5, 3.5, 11.5, 12.5),
      );
      final house = _metrics(parseSvgPath(_modalGlyphPaths[5])).single;
      expect(house.isClosed, isTrue);
      final body = parseSvgPath(_modalGlyphPaths[7]);
      expect(_metrics(body), hasLength(1));
      _expectOffset(_startOf(_metrics(body).single), const Offset(3.5, 19.5));
      _expectOffset(_endOf(_metrics(body).single), const Offset(14.5, 19.5));
      final shield = _metrics(parseSvgPath(_modalGlyphPaths[9])).single;
      expect(shield.isClosed, isTrue);
      expect(_metrics(parseSvgPath(_modalGlyphPaths[10])), hasLength(2));
    });

    test('every path literal in lib/src/ui parses without throwing', () {
      final found = _programPaths();
      expect(
        found.keys,
        containsAll(['glyphs.dart', 'file_icon.dart', 'brand_mark.dart']),
      );
      expect(found['file_icon.dart'], hasLength(greaterThanOrEqualTo(6)));
      expect(found['brand_mark.dart'], hasLength(2));
      expect(found['glyphs.dart'], containsAll(_modalGlyphPaths));
      final all = found.values.expand((paths) => paths).toList();
      expect(all.length, greaterThanOrEqualTo(37));
      for (final data in all) {
        expect(data.trim(), isNotEmpty);
        expect(() => parseSvgPath(data), returnsNormally, reason: data);
        expect(_metrics(parseSvgPath(data)), isNotEmpty, reason: data);
      }
    });
  });
}
