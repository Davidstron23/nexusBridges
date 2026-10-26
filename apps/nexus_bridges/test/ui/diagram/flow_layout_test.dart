import 'dart:math' as math;
import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:nexus_bridges/src/ui/diagram/flow_layout.dart';

const double _tolerance = 0.001;
const double _hubRadius = 38;
const double _labelMin = 96;
const double _labelGap = 14;
const double _edge = 12;
const double _curveRoom = 48;
const double _discMargin = 8;

final class _Expected {
  _Expected(Size size, int count)
    : peerRadius = count > 6 ? 25 : 28,
      hub = Offset(math.max(118, 0.19 * size.width), size.height / 2 - 12),
      margin = math.max(38, 0.07 * size.height) {
    top = margin + peerRadius;
    bottom = math.max(top, size.height - margin - peerRadius);
    single = math.max(
      math.min(0.62 * size.width, size.width - 240),
      hub.dx + _hubRadius + peerRadius + _curveRoom,
    );
    far = size.width - 215;
    near = math.max(hub.dx + 190, far - 205);
    final viable = far - near >= 2 * peerRadius + _labelGap + _labelMin + 10;
    twoColumns = count > 5 && viable;
    capacity =
        1 +
        ((bottom - top) / (twoColumns ? peerRadius + 8 : 2 * peerRadius + 6))
            .floor();
    final overflowing = count > capacity;
    slotCount = overflowing ? capacity : count;
    hidden = overflowing ? count - (capacity - 1) : 0;
  }

  final double peerRadius;
  final Offset hub;
  final double margin;
  late final double top;
  late final double bottom;
  late final double single;
  late final double far;
  late final double near;
  late final bool twoColumns;
  late final int capacity;
  late final int slotCount;
  late final int hidden;
}

List<FlowSlot> _peers(FlowLayout layout) =>
    layout.slots.where((slot) => !slot.overflow).toList();

List<double> _sweep(double from, double to, double step) {
  final values = <double>[];
  for (var value = from; value < to; value += step) {
    values.add(value);
  }
  values.add(to);
  return values;
}

List<String> _invariantFailures(Size size, int count) {
  final failures = <String>[];
  void note(String text) => failures.add('$size, $count: $text');

  final layout = layoutFlow(size, count);
  final expected = _Expected(size, count);
  final pr = layout.peerRadius;

  if (pr != expected.peerRadius) note('peer radius $pr');
  if (layout.hubRadius != _hubRadius) note('hub radius ${layout.hubRadius}');
  if ((layout.hub - expected.hub).distance > _tolerance) {
    note('hub ${layout.hub}');
  }

  for (final slot in layout.slots) {
    final c = slot.center;
    if (c.dx - pr < _discMargin - _tolerance ||
        c.dx + pr > size.width - _discMargin + _tolerance ||
        c.dy - pr < _discMargin - _tolerance ||
        c.dy + pr > size.height - _discMargin + _tolerance) {
      note('disc out of the area at $c');
    }
    if (slot.labelWidth < _labelMin - _tolerance) {
      note('label ${slot.labelWidth} at $c');
    }
  }

  for (final column in [0, 1]) {
    final centers = [
      for (final slot in layout.slots)
        if (slot.column == column) slot.center,
    ];
    for (var i = 1; i < centers.length; i++) {
      final gap = (centers[i] - centers[i - 1]).distance;
      if (gap < 2 * pr + 6 - _tolerance) {
        note('discs of column $column at $gap');
      }
    }
  }

  final second = layout.secondColumn;
  if (second != null) {
    if (count <= 5) note('two columns with $count');
    if (second - layout.firstColumn <
        2 * pr + _labelGap + _labelMin + 10 - _tolerance) {
      note('columns too close: ${second - layout.firstColumn}');
    }
  }
  if ((second != null) != expected.twoColumns) {
    note('two columns ${second != null}');
  }

  final peers = _peers(layout);
  if (peers.length + layout.hidden != count) {
    note('${peers.length} peers and ${layout.hidden} hidden');
  }
  if (layout.slots.length != expected.slotCount) {
    note('${layout.slots.length} slots');
  }
  if (layout.hidden != expected.hidden) note('hidden ${layout.hidden}');
  final overflows = layout.slots.where((slot) => slot.overflow).length;
  if (overflows != (layout.hidden > 0 ? 1 : 0)) note('$overflows overflows');
  if (overflows == 1 && !layout.slots.last.overflow) {
    note('overflow is not the last slot');
  }

  if (layout.slots.length == 1 &&
      (layout.slots.single.center.dy - layout.hub.dy).abs() > _tolerance) {
    note('single slot off the hub height');
  }
  if (layout.slots.length >= 2) {
    final first = layout.slots.first.center.dy;
    final last = layout.slots.last.center.dy;
    if (((first - pr) - (size.height - last - pr)).abs() > _tolerance) {
      note('margins ${first - pr} and ${size.height - last - pr}');
    }
    final step = (last - first) / (layout.slots.length - 1);
    for (var k = 0; k < layout.slots.length; k++) {
      if ((layout.slots[k].center.dy - (first + k * step)).abs() > _tolerance) {
        note('slot $k not evenly spread');
      }
    }
  }

  for (var k = 0; k < layout.slots.length; k++) {
    final slot = layout.slots[k];
    final column = second != null && k.isOdd ? 1 : 0;
    final x = column == 1 ? second! : layout.firstColumn;
    if (slot.column != column || (slot.center.dx - x).abs() > _tolerance) {
      note('slot $k in column ${slot.column} at ${slot.center.dx}');
    }
  }
  return failures;
}

bool _finiteOffset(Offset offset) => offset.dx.isFinite && offset.dy.isFinite;

bool _finiteRect(Rect rect) =>
    rect.left.isFinite &&
    rect.top.isFinite &&
    rect.right.isFinite &&
    rect.bottom.isFinite;

List<String> _finiteFailures(Size size, int count) {
  final failures = <String>[];
  void note(String text) => failures.add('$size, $count: $text');
  final layout = layoutFlow(size, count);
  if (!layout.size.width.isFinite || !layout.size.height.isFinite) {
    note('size ${layout.size}');
  }
  if (!_finiteOffset(layout.hub)) note('hub ${layout.hub}');
  if (!layout.hubRadius.isFinite || !layout.peerRadius.isFinite) {
    note('radius');
  }
  if (!layout.firstColumn.isFinite) note('first column');
  final second = layout.secondColumn;
  if (second != null && !second.isFinite) note('second column');
  if (layout.hidden < 0) note('hidden ${layout.hidden}');
  for (final slot in layout.slots) {
    if (!_finiteOffset(slot.center)) note('center ${slot.center}');
    if (!slot.labelWidth.isFinite) note('label ${slot.labelWidth}');
    if (!_finiteOffset(curveStart(layout, slot.center))) note('curve start');
    for (final gap in [8.0, 12.0]) {
      if (!_finiteRect(flowCurve(layout, slot, gap: gap).getBounds())) {
        note('curve bounds');
      }
    }
    final popover = placePopover(
      area: layout.size,
      center: slot.center,
      radius: layout.peerRadius,
      popover: const Size(264, 150),
    );
    if (!_finiteOffset(popover)) note('popover $popover');
  }
  return failures;
}

List<Offset> _samples(Path path, {int steps = 4000}) {
  final points = <Offset>[];
  for (final metric in path.computeMetrics()) {
    for (var i = 0; i <= steps; i++) {
      points.add(
        metric.getTangentForOffset(metric.length * i / steps)!.position,
      );
    }
  }
  return points;
}

double _closest(Path path, Offset target) =>
    _samples(path).map((point) => (point - target).distance).reduce(math.min);

Offset _expectedStart(FlowLayout layout, Offset peer) {
  final hub = layout.hub;
  final aim = Offset(hub.dx + 120, hub.dy + (peer.dy - hub.dy) * 0.35);
  final direction = aim - hub;
  return hub + direction / direction.distance * (_hubRadius + 8);
}

void _expectOffset(Offset actual, Offset expected, {double tolerance = 0.01}) {
  expect(actual.dx, closeTo(expected.dx, tolerance), reason: '$actual');
  expect(actual.dy, closeTo(expected.dy, tolerance), reason: '$actual');
}

void main() {
  group('E260: layoutFlow, the figures of the plan', () {
    test('one peer sits at the height of the hub, in every size', () {
      for (final size in const [
        Size(572, 468),
        Size(788, 588),
        Size(1000, 700),
        Size(420, 377),
        Size(432, 416),
      ]) {
        final layout = layoutFlow(size, 1);
        expect(layout.slots, hasLength(1), reason: '$size');
        expect(layout.slots.single.center.dy, closeTo(layout.hub.dy, 1e-9));
        expect(layout.slots.single.overflow, isFalse);
        expect(layout.hidden, 0);
        expect(layout.secondColumn, isNull);
      }
    });

    test('3 at 788x588: one column at min(0.62 W, W - 240) with equal '
        'margins', () {
      final layout = layoutFlow(const Size(788, 588), 3);
      expect(layout.secondColumn, isNull);
      expect(layout.firstColumn, closeTo(0.62 * 788, _tolerance));
      expect(layout.peerRadius, 28);
      expect(layout.hub, const Offset(0.19 * 788, 588 / 2 - 12));
      final ys = [for (final slot in layout.slots) slot.center.dy];
      expect(ys, hasLength(3));
      final margin = 0.07 * 588;
      expect(ys.first, closeTo(margin + 28, _tolerance));
      expect(ys.last, closeTo(588 - margin - 28, _tolerance));
      expect(ys[1], closeTo(588 / 2, _tolerance));
      expect(ys.first - 28, closeTo(588 - ys.last - 28, _tolerance));
      for (final slot in layout.slots) {
        expect(slot.center.dx, closeTo(0.62 * 788, _tolerance));
        expect(slot.column, 0);
        expect(
          slot.labelWidth,
          closeTo(788 - _edge - (0.62 * 788 + 28 + _labelGap), _tolerance),
        );
      }
    });

    test('6 at 788x588: two columns at 368 and 573, even indexes in the '
        'first', () {
      final layout = layoutFlow(const Size(788, 588), 6);
      expect(layout.firstColumn, closeTo(368, _tolerance));
      expect(layout.secondColumn, closeTo(573, _tolerance));
      expect(layout.hidden, 0);
      expect(layout.slots, hasLength(6));
      for (var k = 0; k < 6; k++) {
        final slot = layout.slots[k];
        expect(slot.column, k.isEven ? 0 : 1);
        expect(slot.center.dx, closeTo(k.isEven ? 368 : 573, _tolerance));
        expect(
          slot.labelWidth,
          closeTo(
            k.isEven ? 573 - 28 - 10 - (368 + 28 + 14) : 788 - 12 - (573 + 42),
            _tolerance,
          ),
        );
      }
    });

    test('6 and 7 at 572x468 stay in one column: the 49 px defect is '
        'solved', () {
      for (final count in [6, 7]) {
        final layout = layoutFlow(const Size(572, 468), count);
        expect(layout.secondColumn, isNull, reason: '$count');
        expect(layout.hidden, 0, reason: '$count');
        expect(_peers(layout), hasLength(count));
        expect(layout.firstColumn, closeTo(572 - 240, _tolerance));
        final ys = [for (final slot in layout.slots) slot.center.dy];
        for (var i = 1; i < ys.length; i++) {
          expect(ys[i] - ys[i - 1], greaterThanOrEqualTo(56 - _tolerance));
        }
      }
    });

    test('8 at 572x468: 6 peers and a "+2" disc', () {
      final layout = layoutFlow(const Size(572, 468), 8);
      expect(layout.secondColumn, isNull);
      expect(layout.peerRadius, 25);
      expect(layout.slots, hasLength(7));
      expect(_peers(layout), hasLength(6));
      expect(layout.slots.last.overflow, isTrue);
      expect(layout.hidden, 2);
    });

    test('32 at 788x588: 13 peers and a "+19" disc in two columns', () {
      final layout = layoutFlow(const Size(788, 588), 32);
      expect(layout.secondColumn, isNotNull);
      expect(_peers(layout), hasLength(13));
      expect(layout.slots.last.overflow, isTrue);
      expect(layout.hidden, 19);
    });

    test('5 at 420x377 (point 115): 3 peers and a "+2" disc', () {
      final layout = layoutFlow(const Size(420, 377), 5);
      expect(_peers(layout), hasLength(3));
      expect(layout.slots.last.overflow, isTrue);
      expect(layout.hidden, 2);
    });

    test('point 131, the minimum diagram of 432x416: 5 peers all in one '
        'column', () {
      final layout = layoutFlow(const Size(432, 416), 5);
      expect(layout.secondColumn, isNull);
      expect(layout.slots, hasLength(5));
      expect(layout.slots.any((slot) => slot.overflow), isFalse);
      expect(layout.hidden, 0);
    });

    test('point 131, the minimum diagram of 432x416: 6 peers give one '
        'column with 4 and "+2"', () {
      final layout = layoutFlow(const Size(432, 416), 6);
      expect(layout.secondColumn, isNull);
      expect(_peers(layout), hasLength(4));
      expect(layout.slots.last.overflow, isTrue);
      expect(layout.hidden, 2);
    });

    test('no peers gives no slots and nothing hidden', () {
      for (final size in const [
        Size(572, 468),
        Size(788, 588),
        Size(1000, 700),
        Size(432, 416),
      ]) {
        final layout = layoutFlow(size, 0);
        expect(layout.slots, isEmpty);
        expect(layout.hidden, 0);
        expect(layout.secondColumn, isNull);
      }
    });

    test('five or fewer always use one column, even when two would fit', () {
      for (var count = 0; count <= 5; count++) {
        expect(layoutFlow(const Size(1000, 700), count).secondColumn, isNull);
      }
      expect(layoutFlow(const Size(1000, 700), 6).secondColumn, isNotNull);
    });

    test('the peer radius is 28 up to 6 peers and 25 from 7', () {
      expect(layoutFlow(const Size(788, 588), 6).peerRadius, 28);
      expect(layoutFlow(const Size(788, 588), 7).peerRadius, 25);
      expect(layoutFlow(const Size(788, 588), 32).peerRadius, 25);
    });

    test('a single column never bends back towards the hub in a narrow '
        'diagram', () {
      final layout = layoutFlow(const Size(420, 377), 3);
      expect(
        layout.firstColumn,
        closeTo(118 + _hubRadius + 28 + _curveRoom, _tolerance),
      );
    });

    test('with room for a single slot and more than one peer, only the '
        '"+k" disc', () {
      final layout = layoutFlow(const Size(600, 150), 3);
      expect(layout.slots, hasLength(1));
      expect(layout.slots.single.overflow, isTrue);
      expect(layout.hidden, 3);
      expect(layout.slots.single.center.dy, closeTo(layout.hub.dy, 1e-9));
      final one = layoutFlow(const Size(600, 150), 1);
      expect(one.slots.single.overflow, isFalse);
      expect(one.hidden, 0);
    });

    for (final size in const [
      Size(572, 468),
      Size(788, 588),
      Size(1000, 700),
      Size(420, 377),
      Size(432, 416),
    ]) {
      test('the invariants hold at $size with 0, 1, 3, 5, 6, 7, 8 and 32 '
          'peers', () {
        final failures = [
          for (final count in [0, 1, 3, 5, 6, 7, 8, 32])
            ..._invariantFailures(size, count),
        ];
        expect(failures, isEmpty);
      });
    }

    test('the invariants hold in the sweep from 420x240 to 1600x1000, step '
        '37, with 0 to 32 peers', () {
      final failures = <String>[];
      var layouts = 0;
      for (final width in _sweep(420, 1600, 37)) {
        for (final height in _sweep(240, 1000, 37)) {
          for (var count = 0; count <= 32; count++) {
            failures.addAll(_invariantFailures(Size(width, height), count));
            layouts++;
          }
        }
      }
      expect(layouts, 33 * 33 * 22);
      expect(failures.take(20).toList(), isEmpty);
    });

    test('below the minimum, with zero, negative, infinite or NaN sizes, it '
        'does not throw and every value is finite', () {
      const sizes = [
        Size.zero,
        Size(1, 1),
        Size(100, 100),
        Size(419, 239),
        Size(300, 800),
        Size(900, 60),
        Size(-100, -50),
        Size(-1, 500),
        Size(500, -1),
        Size.infinite,
        Size(double.infinity, 500),
        Size(500, double.infinity),
        Size(double.negativeInfinity, 400),
        Size(double.nan, 300),
        Size(300, double.nan),
      ];
      final failures = <String>[];
      for (final size in sizes) {
        for (var count = -1; count <= 32; count++) {
          failures.addAll(_finiteFailures(size, count));
        }
      }
      expect(failures.take(20).toList(), isEmpty);
    });
  });

  group('E261: curveStart and flowCurve', () {
    test('curveStart is at hr + 8 from the hub towards (hub.x + 120, hub.y + '
        '0.35 (c.y - hub.y))', () {
      final layout = layoutFlow(const Size(788, 588), 3);
      final hub = layout.hub;
      _expectOffset(
        curveStart(layout, Offset(500, hub.dy)),
        Offset(hub.dx + 46, hub.dy),
      );
      for (final peer in [
        const Offset(488, 69),
        const Offset(488, 519),
        Offset(700, hub.dy - 300),
      ]) {
        final start = curveStart(layout, peer);
        expect((start - hub).distance, closeTo(46, 0.01));
        _expectOffset(start, _expectedStart(layout, peer));
      }
      final up = curveStart(layout, Offset(500, hub.dy - 200));
      final down = curveStart(layout, Offset(500, hub.dy + 200));
      expect(up.dy, lessThan(hub.dy));
      expect(down.dy, greaterThan(hub.dy));
      expect(up.dx, closeTo(down.dx, 0.01));
    });

    for (final gap in [8.0, 12.0]) {
      test('one column, gap $gap: starts at hr + 8 from the hub, ends at (c.x '
          '- pr - gap, c.y), horizontal at both ends', () {
        final layout = layoutFlow(const Size(788, 588), 3);
        for (final slot in layout.slots) {
          final path = flowCurve(layout, slot, gap: gap);
          final metrics = path.computeMetrics().toList();
          expect(metrics, isNotEmpty);
          final first = metrics.first.getTangentForOffset(0)!;
          final last = metrics.last.getTangentForOffset(metrics.last.length)!;
          final a = curveStart(layout, slot.center);
          final b = Offset(
            slot.center.dx - layout.peerRadius - gap,
            slot.center.dy,
          );
          _expectOffset(first.position, a);
          expect((first.position - layout.hub).distance, closeTo(46, 0.01));
          _expectOffset(last.position, b);
          expect(first.vector.dy, closeTo(0, 0.01));
          expect(first.vector.dx, greaterThan(0));
          expect(last.vector.dy, closeTo(0, 0.01));
          expect(last.vector.dx, greaterThan(0));
          expect(
            _closest(path, Offset((a.dx + b.dx) / 2, (a.dy + b.dy) / 2)),
            lessThan(0.15),
          );
        }
      });

      test('two columns, gap $gap: the far curve passes through v = (c1 - pr '
          '- 34, c.y) and its last stretch is horizontal', () {
        final layout = layoutFlow(const Size(788, 588), 8);
        expect(layout.secondColumn, isNotNull);
        final far = layout.slots.where((slot) => slot.column == 1).toList();
        expect(far, isNotEmpty);
        for (final slot in far) {
          final path = flowCurve(layout, slot, gap: gap);
          final metrics = path.computeMetrics().toList();
          final metric = metrics.single;
          final pr = layout.peerRadius;
          final a = curveStart(layout, slot.center);
          final v = Offset(layout.firstColumn - pr - 34, slot.center.dy);
          final b = Offset(slot.center.dx - pr - gap, slot.center.dy);
          final start = metric.getTangentForOffset(0)!;
          final end = metric.getTangentForOffset(metric.length)!;
          _expectOffset(start.position, a);
          _expectOffset(end.position, b);
          expect(start.vector.dy, closeTo(0, 0.01));
          expect(end.vector.dy, closeTo(0, 0.01));
          expect(_closest(path, v), lessThan(0.15));
          expect(
            _closest(path, Offset((a.dx + v.dx) / 2, (a.dy + v.dy) / 2)),
            lessThan(0.15),
          );
          final straight = b.dx - v.dx;
          expect(straight, greaterThan(0));
          _expectOffset(
            metric.getTangentForOffset(metric.length - straight)!.position,
            v,
            tolerance: 0.15,
          );
          for (var i = 0; i <= 10; i++) {
            final tangent = metric.getTangentForOffset(
              metric.length - straight * 0.95 * i / 10,
            )!;
            expect(tangent.position.dy, closeTo(slot.center.dy, 0.01));
            expect(tangent.vector.dy, closeTo(0, 0.01));
          }
        }
      });

      test('two columns, gap $gap: the near curves are the one-column '
          'cubic', () {
        final layout = layoutFlow(const Size(788, 588), 8);
        for (final slot in layout.slots.where((slot) => slot.column == 0)) {
          final path = flowCurve(layout, slot, gap: gap);
          final a = curveStart(layout, slot.center);
          final b = Offset(
            slot.center.dx - layout.peerRadius - gap,
            slot.center.dy,
          );
          final metric = path.computeMetrics().single;
          _expectOffset(metric.getTangentForOffset(0)!.position, a);
          _expectOffset(metric.getTangentForOffset(metric.length)!.position, b);
          expect(
            _closest(path, Offset((a.dx + b.dx) / 2, (a.dy + b.dy) / 2)),
            lessThan(0.15),
          );
        }
      });
    }

    test('the far straight stretch passes between two discs of the first '
        'column', () {
      final layout = layoutFlow(const Size(788, 588), 8);
      final pr = layout.peerRadius;
      final near = [
        for (final slot in layout.slots)
          if (slot.column == 0) slot.center,
      ];
      for (final slot in layout.slots.where((slot) => slot.column == 1)) {
        for (final center in near) {
          expect(
            (center.dy - slot.center.dy).abs(),
            greaterThanOrEqualTo(pr + 8 - _tolerance),
          );
        }
      }
    });
  });

  group('E261: placePopover', () {
    const area = Size(788, 588);
    const popover = Size(264, 150);
    const radius = 28.0;
    const d = radius + 14;

    Offset place(Offset center, {Size area = area, Size popover = popover}) =>
        placePopover(
          area: area,
          center: center,
          radius: radius,
          popover: popover,
        );

    test('a peer near the top: below, centred on it', () {
      expect(place(const Offset(500, 80)), const Offset(500 - 132, 80 + d));
    });

    test('a peer near the bottom: above', () {
      expect(
        place(const Offset(500, 500)),
        const Offset(500 - 132, 500 - d - 150),
      );
    });

    test('in the lower half with room above and below: above', () {
      expect(
        place(const Offset(500, 320)),
        const Offset(500 - 132, 320 - d - 150),
      );
    });

    test('in the upper half with room above and below: below', () {
      expect(place(const Offset(500, 250)), const Offset(500 - 132, 250 + d));
    });

    test('next to the right edge it keeps 10 px from the side', () {
      expect(
        place(const Offset(770, 100)),
        const Offset(788 - 10 - 264, 100 + d),
      );
    });

    test('next to the left edge it keeps 10 px from the side', () {
      expect(place(const Offset(20, 100)), const Offset(10, 100 + d));
    });

    test('without vertical room: to the left when it fits', () {
      const short = Size(788, 300);
      const big = Size(264, 200);
      expect(
        place(const Offset(500, 150), area: short, popover: big),
        const Offset(500 - d - 264, 150 - 100),
      );
    });

    test('without vertical room and no room on the left: to the right', () {
      const short = Size(788, 300);
      const big = Size(264, 200);
      expect(
        place(const Offset(100, 150), area: short, popover: big),
        const Offset(100 + d, 50),
      );
    });

    test('to the right, cut to area.width - 10 - w', () {
      const short = Size(400, 300);
      const big = Size(264, 200);
      expect(
        place(const Offset(150, 150), area: short, popover: big),
        const Offset(400 - 10 - 264, 50),
      );
    });

    test('on a side, y is clamped between 8 and area.height - 8 - h', () {
      const short = Size(788, 300);
      const big = Size(264, 250);
      expect(
        place(const Offset(500, 30), area: short, popover: big),
        const Offset(500 - d - 264, 8),
      );
      expect(
        place(const Offset(500, 270), area: short, popover: big),
        const Offset(500 - d - 264, 300 - 8 - 250),
      );
    });

    test('an area smaller than the popover gives (10, 8) and does not '
        'throw', () {
      expect(
        place(const Offset(50, 50), area: const Size(200, 100)),
        const Offset(10, 8),
      );
      expect(
        place(const Offset(50, 50), area: const Size(788, 100)),
        const Offset(10, 8),
      );
      expect(
        place(const Offset(50, 50), area: const Size(200, 588)),
        const Offset(10, 8),
      );
      expect(place(Offset.zero, area: Size.zero), const Offset(10, 8));
    });

    test('an area barely wider or taller than the popover does not throw and '
        'stays finite', () {
      for (final area in const [
        Size(270, 588),
        Size(264, 588),
        Size(788, 155),
        Size(788, 150),
        Size(270, 160),
      ]) {
        for (final center in const [
          Offset(0, 0),
          Offset(135, 80),
          Offset(700, 500),
        ]) {
          final position = place(center, area: area);
          expect(_finiteOffset(position), isTrue, reason: '$area $center');
        }
      }
    });
  });
}
