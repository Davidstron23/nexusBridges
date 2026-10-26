import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nexus_bridges/src/ui/brand/brand_mark.dart';
import 'package:nexus_bridges/src/ui/icons/svg_path.dart';
import 'package:nexus_bridges/src/ui/theme/app_theme.dart';
import 'package:nexus_bridges/src/ui/theme/tokens.dart';

const Offset _solid = Offset(72, 100);
const Offset _gap = Offset(128, 121.8);
const Offset _tip = Offset(119.3, 84.5);
const Color _custom = Color(0xFF00AA55);

Path _parsedEvenOdd(String data) =>
    parseSvgPath(data)..fillType = PathFillType.evenOdd;

void _expectBounds(Rect bounds) {
  expect(bounds.left, closeTo(54, 0.5));
  expect(bounds.top, closeTo(48, 0.5));
  expect(bounds.right, closeTo(202, 0.5));
  expect(bounds.bottom, closeTo(208, 0.5));
}

Future<void> _pump(
  WidgetTester tester,
  Widget child, {
  Brightness brightness = Brightness.light,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      theme: buildTheme(brightness),
      themeAnimationDuration: Duration.zero,
      home: Scaffold(body: Center(child: child)),
    ),
  );
  await tester.pump();
}

RenderObject _painterOf(WidgetTester tester) => tester.renderObject(
  find
      .descendant(
        of: find.byType(BrandMark),
        matching: find.byType(CustomPaint),
      )
      .first,
);

void main() {
  group('E259: brandMarkPath (mark-small.svg)', () {
    test('measures from (54, 48) to (202, 208)', () {
      _expectBounds(_parsedEvenOdd(brandMarkPath).getBounds());
    });

    test('with evenOdd the tower is filled and the gap is empty', () {
      final mark = _parsedEvenOdd(brandMarkPath);
      expect(mark.contains(_solid), isTrue);
      expect(mark.contains(_gap), isFalse);
      expect(mark.contains(_tip), isTrue);
    });

    test('has two subpaths: the outline and the gap', () {
      expect(parseSvgPath(brandMarkPath).computeMetrics().length, 2);
    });
  });

  group('brandMarkFullPath (mark.svg)', () {
    test('measures the same as the small mark', () {
      _expectBounds(_parsedEvenOdd(brandMarkFullPath).getBounds());
    });

    test('keeps the gap and cuts the tips out of the solid', () {
      final mark = _parsedEvenOdd(brandMarkFullPath);
      expect(mark.contains(_solid), isTrue);
      expect(mark.contains(_gap), isFalse);
      expect(mark.contains(_tip), isFalse);
    });

    test('has the outline, the gap and four tips', () {
      expect(parseSvgPath(brandMarkFullPath).computeMetrics().length, 6);
    });
  });

  group('BrandMark', () {
    for (final size in [16.0, 36.0, 64.0]) {
      testWidgets('at $size px draws the small mark', (tester) async {
        await _pump(tester, BrandMark(size: size));
        expect(tester.takeException(), isNull);
        expect(tester.getSize(find.byType(BrandMark)), Size.square(size));
        expect(
          _painterOf(tester),
          paints
            ..scale(x: size / 256, y: size / 256)
            ..path(
              includes: [_solid, _tip],
              excludes: [_gap],
              style: PaintingStyle.fill,
            ),
        );
      });
    }

    for (final size in [64.5, 65.0, 128.0, 256.0]) {
      testWidgets('at $size px draws the full mark', (tester) async {
        await _pump(tester, BrandMark(size: size));
        expect(tester.takeException(), isNull);
        expect(tester.getSize(find.byType(BrandMark)), Size.square(size));
        expect(
          _painterOf(tester),
          paints
            ..scale(x: size / 256, y: size / 256)
            ..path(
              includes: [_solid],
              excludes: [_gap, _tip],
              style: PaintingStyle.fill,
            ),
        );
      });
    }

    testWidgets('the default size is 36', (tester) async {
      await _pump(tester, const BrandMark());
      expect(tester.getSize(find.byType(BrandMark)), const Size.square(36));
    });

    testWidgets('a single primary color by default: #6D4AFF in light', (
      tester,
    ) async {
      await _pump(tester, const BrandMark());
      expect(NbColors.light.primary, const Color(0xFF6D4AFF));
      expect(_painterOf(tester), paints..path(color: NbColors.light.primary));
      expect(_painterOf(tester), paintsExactlyCountTimes(#drawPath, 1));
    });

    testWidgets('a single primary color by default: #8A6EFF in dark', (
      tester,
    ) async {
      await _pump(tester, const BrandMark(), brightness: Brightness.dark);
      expect(NbColors.dark.primary, const Color(0xFF8A6EFF));
      expect(_painterOf(tester), paints..path(color: NbColors.dark.primary));
      expect(_painterOf(tester), paintsExactlyCountTimes(#drawPath, 1));
    });

    for (final brightness in Brightness.values) {
      testWidgets('an explicit color wins in ${brightness.name}', (
        tester,
      ) async {
        await _pump(
          tester,
          const BrandMark(size: 128, color: _custom),
          brightness: brightness,
        );
        expect(_painterOf(tester), paints..path(color: _custom));
        expect(_painterOf(tester), paintsExactlyCountTimes(#drawPath, 1));
      });
    }

    testWidgets('the mark adds nothing to the semantics tree', (tester) async {
      final handle = tester.ensureSemantics();
      await _pump(
        tester,
        Semantics(container: true, label: 'host', child: const BrandMark()),
      );
      final node = tester.getSemantics(find.byType(BrandMark));
      expect(node.label, 'host');
      expect(node.childrenCount, 0);
      handle.dispose();
    });
  });
}
