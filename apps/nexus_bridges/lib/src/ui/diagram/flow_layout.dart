import 'dart:math' as math;
import 'dart:ui';

const double _hubRadius = 38;
const double _peerRadius = 28;
const double _smallPeerRadius = 25;
const int _manyPeers = 6;
const int _singleColumnMax = 5;
const double _labelMin = 96;
const double _labelGap = 14;
const double _edge = 12;
const double _curveRoom = 48;
const double _farColumnClearance = 10;
const double _farColumnInset = 215;
const double _columnSpread = 205;
const double _hubColumnGap = 190;
const double _hubMinX = 118;
const double _hubFactor = 0.19;
const double _hubLift = 12;
const double _marginMin = 38;
const double _marginFactor = 0.07;
const double _singleFactor = 0.62;
const double _singleRoom = 240;
const double _singleStepGap = 6;
const double _doubleStepGap = 8;
const double _curveStartGap = 8;
const double _curveAim = 120;
const double _curveAimFactor = 0.35;
const double _viaGap = 34;
const double _popoverOffset = 14;
const double _popoverSide = 10;
const double _popoverVertical = 8;

final class FlowSlot {
  const FlowSlot({
    required this.center,
    required this.column,
    required this.labelWidth,
    this.overflow = false,
  });

  final Offset center;
  final int column;
  final double labelWidth;
  final bool overflow;
}

final class FlowLayout {
  const FlowLayout({
    required this.size,
    required this.hub,
    required this.hubRadius,
    required this.peerRadius,
    required this.firstColumn,
    required this.secondColumn,
    required this.slots,
    required this.hidden,
  });

  final Size size;
  final Offset hub;
  final double hubRadius;
  final double peerRadius;
  final double firstColumn;
  final double? secondColumn;
  final List<FlowSlot> slots;
  final int hidden;
}

double _finite(double value) => value.isFinite && value > 0 ? value : 0;

double _clampSafe(double value, double low, double high) {
  if (high < low) return low;
  return math.min(math.max(value, low), high);
}

FlowLayout layoutFlow(Size size, int count) {
  final width = _finite(size.width);
  final height = _finite(size.height);
  final total = count < 0 ? 0 : count;
  final radius = total > _manyPeers ? _smallPeerRadius : _peerRadius;
  final hub = Offset(
    math.max(_hubMinX, _hubFactor * width),
    height / 2 - _hubLift,
  );
  final margin = math.max(_marginMin, _marginFactor * height);
  final top = margin + radius;
  final bottom = math.max(top, height - margin - radius);
  final span = bottom - top;

  final singleColumn = math.max(
    math.min(_singleFactor * width, width - _singleRoom),
    hub.dx + _hubRadius + radius + _curveRoom,
  );
  final farColumn = width - _farColumnInset;
  final nearColumn = math.max(
    hub.dx + _hubColumnGap,
    farColumn - _columnSpread,
  );
  final twoViable =
      farColumn - nearColumn >=
      2 * radius + _labelGap + _labelMin + _farColumnClearance;
  final twoColumns = total > _singleColumnMax && twoViable;

  final firstColumn = twoColumns ? nearColumn : singleColumn;
  final capacity =
      1 +
      (span /
              (twoColumns
                  ? radius + _doubleStepGap
                  : 2 * radius + _singleStepGap))
          .floor();

  final firstLabel = twoColumns
      ? farColumn -
            radius -
            _farColumnClearance -
            (firstColumn + radius + _labelGap)
      : width - _edge - (firstColumn + radius + _labelGap);
  final secondLabel = width - _edge - (farColumn + radius + _labelGap);

  final overflowing = total > capacity;
  final slotCount = overflowing ? capacity : total;
  final slots = <FlowSlot>[
    for (var k = 0; k < slotCount; k++)
      FlowSlot(
        center: Offset(
          twoColumns && k.isOdd ? farColumn : firstColumn,
          slotCount == 1 ? hub.dy : top + k * span / (slotCount - 1),
        ),
        column: twoColumns && k.isOdd ? 1 : 0,
        labelWidth: math.max(
          0,
          twoColumns && k.isOdd ? secondLabel : firstLabel,
        ),
        overflow: overflowing && k == slotCount - 1,
      ),
  ];

  return FlowLayout(
    size: Size(width, height),
    hub: hub,
    hubRadius: _hubRadius,
    peerRadius: radius,
    firstColumn: firstColumn,
    secondColumn: twoColumns ? farColumn : null,
    slots: slots,
    hidden: overflowing ? total - (capacity - 1) : 0,
  );
}

Offset curveStart(FlowLayout layout, Offset peer) {
  final hub = layout.hub;
  final aim = Offset(
    hub.dx + _curveAim,
    hub.dy + (peer.dy - hub.dy) * _curveAimFactor,
  );
  final direction = aim - hub;
  final distance = direction.distance;
  if (distance == 0) return hub;
  return hub + direction / distance * (layout.hubRadius + _curveStartGap);
}

Path flowCurve(FlowLayout layout, FlowSlot slot, {double gap = 8}) {
  final path = Path();
  if (slot.overflow) return path;
  final center = slot.center;
  final start = curveStart(layout, center);
  final end = Offset(center.dx - layout.peerRadius - gap, center.dy);
  path.moveTo(start.dx, start.dy);
  if (slot.column == 0) {
    final reach = (end.dx - start.dx) / 2;
    path.cubicTo(
      start.dx + reach,
      start.dy,
      end.dx - reach,
      end.dy,
      end.dx,
      end.dy,
    );
    return path;
  }
  final via = Offset(
    layout.firstColumn - layout.peerRadius - _viaGap,
    center.dy,
  );
  final reach = (via.dx - start.dx) / 2;
  path.cubicTo(
    start.dx + reach,
    start.dy,
    via.dx - reach,
    via.dy,
    via.dx,
    via.dy,
  );
  path.lineTo(end.dx, end.dy);
  return path;
}

Offset placePopover({
  required Size area,
  required Offset center,
  required double radius,
  required Size popover,
}) {
  final width = popover.width;
  final height = popover.height;
  if (area.width < width || area.height < height) {
    return const Offset(_popoverSide, _popoverVertical);
  }
  final distance = radius + _popoverOffset;
  final fitsBelow =
      center.dy + distance + height <= area.height - _popoverVertical;
  final fitsAbove = center.dy - distance - height >= _popoverVertical;
  final x = _clampSafe(
    center.dx - width / 2,
    _popoverSide,
    area.width - _popoverSide - width,
  );
  if (fitsBelow || fitsAbove) {
    final above = fitsAbove && (center.dy > area.height / 2 || !fitsBelow);
    return Offset(
      x,
      above ? center.dy - distance - height : center.dy + distance,
    );
  }
  final y = _clampSafe(
    center.dy - height / 2,
    _popoverVertical,
    area.height - _popoverVertical - height,
  );
  final left = center.dx - distance - width;
  if (left >= _popoverSide) return Offset(left, y);
  return Offset(
    math.min(center.dx + distance, area.width - _popoverSide - width),
    y,
  );
}
