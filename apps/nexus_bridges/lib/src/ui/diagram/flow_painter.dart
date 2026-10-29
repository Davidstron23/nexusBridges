import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:nexus_bridges_core/nexus_bridges_core.dart' show DeviceType;

import '../icons/file_icon.dart';
import '../icons/glyphs.dart';
import '../theme/app_theme.dart';
import '../theme/components.dart' show ChipTone;
import '../theme/tokens.dart';
import 'flow_layout.dart';
import 'flow_scene.dart';

const double _clockSeconds = 14.4;
const double _dotPeriod = 1.8;
const double _iconLag = 0.9;
const double _pulsePeriod = 1.6;
const double _dashSpeed = 18;
const double _dashPeriod = 9;
const double _dotRadius = 4.5;
const double _travelIconHeight = 24;
const double _travelIconWidth = 20;
const double _hoverGrowth = 0.14;
const double _shadowSigma = 4;
const double _shadowDrop = 3;
const double _haloExtra = 7;
const double _badgeRadius = 9;
const double _badgeOffset = 0.72;
const double _peerIconBox = 26.4;
const double _peerStrokeScale = 1.5 / 1.6;
const double _hubIconBox = 36;
const double _hubStrokeScale = 1.4 / 1.6;
const double _hubGlowExtra = 34;
const double _hubRingExtra = 9;
const double _labelOffset = 14;
const double _chipHeight = 20;
const double _chipPadding = 18;
const double _headerLeft = 20;
const double _headerTop = 14;
const double _headerGap = 8;
const List<double> _ringFactors = [0.32, 0.58, 0.84, 1.1];

Path dashPath(Path source, List<double> pattern, {double phase = 0}) {
  final valid =
      pattern.isNotEmpty &&
      phase.isFinite &&
      pattern.every((length) => length.isFinite && length > 0);
  if (!valid) return Path()..addPath(source, Offset.zero);

  final cycle = pattern.length.isOdd ? [...pattern, ...pattern] : pattern;
  final total = cycle.fold<double>(0, (sum, length) => sum + length);
  var offset = phase % total;
  if (offset < 0) offset += total;
  var startIndex = 0;
  while (offset >= cycle[startIndex]) {
    offset -= cycle[startIndex];
    startIndex = (startIndex + 1) % cycle.length;
  }

  final result = Path();
  for (final metric in source.computeMetrics()) {
    var index = startIndex;
    var segment = cycle[index] - offset;
    var distance = 0.0;
    while (distance < metric.length) {
      final next = distance + segment;
      if (index.isEven) {
        final end = next < metric.length ? next : metric.length;
        result.addPath(metric.extractPath(distance, end), Offset.zero);
      }
      distance = next;
      index = (index + 1) % cycle.length;
      segment = cycle[index];
    }
  }
  return result;
}

class FlowBackgroundPainter extends CustomPainter {
  const FlowBackgroundPainter({required this.layout, required this.colors});

  final FlowLayout layout;
  final NbColors colors;

  @override
  void paint(Canvas canvas, Size size) {
    final bounds = Offset.zero & layout.size;
    if (bounds.isEmpty) return;
    final hub = layout.hub;
    final reach = 0.75 * math.max(bounds.width, bounds.height);

    canvas.drawRect(
      bounds,
      Paint()
        ..shader = RadialGradient(
          colors: [colors.halo, colors.halo.withValues(alpha: 0)],
        ).createShader(Rect.fromCircle(center: hub, radius: 0.6 * reach)),
    );

    final span = layout.firstColumn - hub.dx;
    if (!(span > 0)) return;
    canvas.saveLayer(bounds, Paint());
    final ring = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1
      ..color = colors.border;
    for (var i = 0; i < _ringFactors.length; i++) {
      final arc = Path()
        ..addArc(
          Rect.fromCircle(center: hub, radius: span * _ringFactors[i]),
          -math.pi / 2,
          math.pi,
        );
      canvas.drawPath(i > 1 ? dashPath(arc, const [2, 6]) : arc, ring);
    }
    canvas.drawRect(
      bounds,
      Paint()
        ..blendMode = BlendMode.dstIn
        ..shader = RadialGradient(
          colors: [
            colors.border.withValues(alpha: 0),
            colors.border.withValues(alpha: 0),
            colors.border.withValues(alpha: 0.95),
            colors.border.withValues(alpha: 0.4),
          ],
          stops: const [0, 0.12, 0.5, 1],
        ).createShader(Rect.fromCircle(center: hub, radius: reach)),
    );
    canvas.restore();
  }

  @override
  bool shouldRepaint(FlowBackgroundPainter oldDelegate) =>
      oldDelegate.layout.size != layout.size ||
      oldDelegate.layout.firstColumn != layout.firstColumn ||
      oldDelegate.colors != colors;
}

typedef _TextKey = (String, TextStyle, Color?, double);

class FlowPainter extends CustomPainter {
  FlowPainter({
    required this.scene,
    required this.colors,
    required this.clock,
    required this.hover,
    required this.reduceMotion,
    required this.textDirection,
  }) : super(repaint: Listenable.merge([clock, hover]));

  final FlowScene scene;
  final NbColors colors;
  final Animation<double> clock;
  final Animation<double> hover;
  final bool reduceMotion;
  final TextDirection textDirection;

  final Map<_TextKey, TextPainter> _texts = {};

  late final Paint _outline = Paint()
    ..style = PaintingStyle.stroke
    ..strokeWidth = 5
    ..strokeJoin = StrokeJoin.round
    ..color = colors.card;

  TextPainter _text(
    String text,
    TextStyle style, {
    Color? color,
    double maxWidth = double.infinity,
  }) {
    return _texts.putIfAbsent((text, style, color, maxWidth), () {
      final resolved = color == null
          ? style.copyWith(foreground: _outline)
          : style.copyWith(color: color);
      return TextPainter(
        text: TextSpan(text: text, style: resolved),
        textDirection: textDirection,
        maxLines: 1,
        ellipsis: '…',
      )..layout(maxWidth: maxWidth);
    });
  }

  TextPainter _drawText(
    Canvas canvas,
    String text,
    TextStyle style,
    Color color,
    Offset anchor, {
    double maxWidth = double.infinity,
    bool centered = false,
    bool outline = true,
  }) {
    final fill = _text(text, style, color: color, maxWidth: maxWidth);
    final baseline = fill.computeDistanceToActualBaseline(
      TextBaseline.alphabetic,
    );
    final x = centered ? anchor.dx - fill.width / 2 : anchor.dx;
    final origin = Offset(x, anchor.dy - baseline);
    if (outline) {
      _text(text, style, maxWidth: maxWidth).paint(canvas, origin);
    }
    fill.paint(canvas, origin);
    return fill;
  }

  @override
  void paint(Canvas canvas, Size size) {
    final layout = scene.layout;
    if (layout.size.isEmpty) return;
    final elapsed = clock.value * _clockSeconds;
    final peers = scene.peers;
    final curves = <Path>[
      for (var i = 0; i < peers.length; i++)
        flowCurve(
          layout,
          layout.slots[i],
          gap: peers[i].link.state == LinkState.idle ? 8 : 12,
        ),
    ];

    for (var i = 0; i < peers.length; i++) {
      _paintBaseLine(canvas, peers[i], curves[i]);
    }
    for (var i = 0; i < peers.length; i++) {
      _paintStateLine(canvas, peers[i], curves[i], elapsed);
    }
    for (var i = 0; i < peers.length; i++) {
      _paintPeer(canvas, peers[i], layout.slots[i], elapsed);
    }
    for (final slot in layout.slots) {
      if (slot.overflow) _paintOverflow(canvas, slot);
    }
    _paintHub(canvas, layout);
    _paintHubLabel(canvas, layout);
    for (var i = 0; i < peers.length; i++) {
      _paintPeerLabel(canvas, peers[i], layout.slots[i]);
    }
    _paintHeader(canvas);
  }

  void _paintBaseLine(Canvas canvas, FlowPeer peer, Path curve) {
    canvas.drawPath(
      peer.visible ? curve : dashPath(curve, const [2, 6]),
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2
        ..strokeCap = StrokeCap.round
        ..color = colors.border,
    );
  }

  void _paintStateLine(
    Canvas canvas,
    FlowPeer peer,
    Path curve,
    double elapsed,
  ) {
    final link = peer.link;
    final dashShift = reduceMotion ? 0.0 : (elapsed * _dashSpeed) % _dashPeriod;
    Paint line(double width, Color color) => Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = width
      ..strokeCap = StrokeCap.round
      ..color = color;

    switch (link.state) {
      case LinkState.idle:
        return;
      case LinkState.waiting:
        canvas.drawPath(
          dashPath(curve, const [
            4,
            5,
          ], phase: link.towardsHub ? dashShift : -dashShift),
          line(2.5, colors.primary.withValues(alpha: 0.75)),
        );
      case LinkState.asking:
        canvas.drawPath(
          dashPath(curve, const [4, 5], phase: dashShift),
          line(2.5, colors.warningRing),
        );
      case LinkState.done:
        canvas.drawPath(curve, line(2.5, colors.success));
      case LinkState.active:
        _paintActiveLine(canvas, peer, curve, elapsed, line(3, colors.primary));
    }
  }

  void _paintActiveLine(
    Canvas canvas,
    FlowPeer peer,
    Path curve,
    double elapsed,
    Paint paint,
  ) {
    final metrics = curve.computeMetrics().toList();
    if (metrics.isEmpty) return;
    final metric = metrics.first;
    final link = peer.link;
    final length = metric.length;
    final progress = link.progress.clamp(0.0, 1.0);

    paint.shader = LinearGradient(
      begin: Alignment.topLeft,
      end: Alignment.bottomRight,
      colors: [colors.hubTop, colors.primary],
    ).createShader(curve.getBounds());
    final partial = link.towardsHub
        ? metric.extractPath(length * (1 - progress), length)
        : metric.extractPath(0, length * progress);
    canvas.drawPath(partial, paint);

    if (reduceMotion) return;
    Offset? at(double fraction) {
      final distance = length * (link.towardsHub ? 1 - fraction : fraction);
      return metric.getTangentForOffset(distance)?.position;
    }

    final dot = at((elapsed % _dotPeriod) / _dotPeriod);
    if (dot != null) {
      canvas.drawCircle(dot, _dotRadius, Paint()..color = colors.primary);
      canvas.drawCircle(
        dot,
        _dotRadius,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2
          ..color = colors.card,
      );
    }

    final icon = at(((elapsed - _iconLag) % _dotPeriod) / _dotPeriod);
    if (icon != null) {
      final rect = Rect.fromCenter(
        center: icon,
        width: _travelIconWidth,
        height: _travelIconHeight,
      );
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          rect.shift(const Offset(0, _shadowDrop)),
          const Radius.circular(3),
        ),
        Paint()
          ..color = colors.nodeShadow
          ..maskFilter = const MaskFilter.blur(BlurStyle.normal, _shadowSigma),
      );
      paintFileIcon(
        canvas,
        rect,
        fileKindOf(link.fileName ?? '', isProgram: link.isProgram),
      );
    }
  }

  void _paintNodeDisc(
    Canvas canvas,
    Offset center,
    double radius,
    Color ring,
    double ringWidth,
  ) {
    canvas.drawCircle(
      center.translate(0, _shadowDrop),
      radius,
      Paint()
        ..color = colors.nodeShadow
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, _shadowSigma),
    );
    canvas.drawCircle(
      center,
      radius,
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [colors.nodeTop, colors.nodeBottom],
        ).createShader(Rect.fromCircle(center: center, radius: radius)),
    );
    canvas.drawCircle(
      center,
      radius,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = ringWidth
        ..color = ring,
    );
  }

  void _paintPeerGlyph(Canvas canvas, FlowPeer peer, Offset center, Color ink) {
    paintGlyph(
      canvas,
      peer.deviceType == DeviceType.mobile ? Glyphs.phone : Glyphs.pc,
      Rect.fromCenter(
        center: center,
        width: _peerIconBox,
        height: _peerIconBox,
      ),
      ink,
      strokeScale: _peerStrokeScale,
    );
  }

  void _paintPeer(Canvas canvas, FlowPeer peer, FlowSlot slot, double elapsed) {
    final center = slot.center;
    final radius = scene.layout.peerRadius;
    final state = peer.link.state;

    canvas.save();
    if (peer.fingerprint == scene.hovered) {
      final grow = 1 + _hoverGrowth * hover.value;
      canvas.translate(center.dx, center.dy);
      canvas.scale(grow);
      canvas.translate(-center.dx, -center.dy);
    }

    if (state == LinkState.idle && !peer.visible) {
      canvas.drawCircle(center, radius, Paint()..color = colors.card);
      canvas.drawPath(
        dashPath(
          Path()..addOval(Rect.fromCircle(center: center, radius: radius)),
          const [3, 3],
        ),
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.2
          ..color = colors.hint,
      );
      _paintPeerGlyph(canvas, peer, center, colors.hint);
      canvas.restore();
      return;
    }

    final (
      Color ring,
      double ringWidth,
      Color ink,
      Color? halo,
    ) = switch (state) {
      LinkState.idle => (colors.border, 1.0, colors.text, null),
      LinkState.waiting => (colors.primary, 1.5, colors.primaryInk, null),
      LinkState.asking => (
        colors.warningRing,
        2.0,
        colors.warning,
        colors.warningWeak,
      ),
      LinkState.active => (
        colors.primary,
        2.0,
        colors.primaryInk,
        colors.primaryWeak,
      ),
      LinkState.done => (
        colors.success,
        2.0,
        colors.success,
        colors.successWeak,
      ),
    };

    if (!reduceMotion &&
        (state == LinkState.waiting || state == LinkState.asking)) {
      final phase = Curves.easeOut.transform(
        (elapsed % _pulsePeriod) / _pulsePeriod,
      );
      canvas.drawCircle(
        center,
        radius + 12 * phase,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2
          ..color =
              (state == LinkState.waiting ? colors.primary : colors.warningRing)
                  .withValues(alpha: 0.35 * (1 - phase)),
      );
    }
    if (halo != null) {
      canvas.drawCircle(center, radius + _haloExtra, Paint()..color = halo);
    }
    _paintNodeDisc(canvas, center, radius, ring, ringWidth);
    _paintPeerGlyph(canvas, peer, center, ink);

    if (state == LinkState.done) {
      final badge = center + Offset(radius, -radius) * _badgeOffset;
      canvas.drawCircle(badge, _badgeRadius, Paint()..color = colors.success);
      canvas.drawCircle(
        badge,
        _badgeRadius,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2
          ..color = colors.card,
      );
      canvas.drawPath(
        Path()
          ..moveTo(badge.dx - 3.6, badge.dy + 0.2)
          ..relativeLineTo(2.4, 2.3)
          ..relativeLineTo(4.6, -4.8),
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.8
          ..strokeCap = StrokeCap.round
          ..strokeJoin = StrokeJoin.round
          ..color = colors.onSuccessDisc,
      );
    }
    canvas.restore();
  }

  void _paintOverflow(Canvas canvas, FlowSlot slot) {
    final label = scene.overflowLabel;
    final radius = scene.layout.peerRadius;
    _paintNodeDisc(canvas, slot.center, radius, colors.border, 1);
    if (label == null) return;
    final fill = _text(
      label,
      NbText.bodyStrong,
      color: colors.textWeak,
      maxWidth: 2 * radius - 6,
    );
    fill.paint(canvas, slot.center - Offset(fill.width / 2, fill.height / 2));
  }

  void _paintHub(Canvas canvas, FlowLayout layout) {
    final hub = layout.hub;
    final radius = layout.hubRadius;
    canvas.drawCircle(
      hub,
      radius + _hubGlowExtra,
      Paint()
        ..shader =
            RadialGradient(
              colors: [colors.glow, colors.glow.withValues(alpha: 0)],
            ).createShader(
              Rect.fromCircle(center: hub, radius: radius + _hubGlowExtra),
            ),
    );
    canvas.drawCircle(
      hub,
      radius + _hubRingExtra,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1
        ..color = colors.primary.withValues(alpha: 0.22),
    );
    canvas.drawCircle(
      hub.translate(0, _shadowDrop),
      radius,
      Paint()
        ..color = colors.nodeShadow
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, _shadowSigma),
    );
    canvas.drawCircle(
      hub,
      radius,
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [colors.hubTop, colors.hubBottom],
        ).createShader(Rect.fromCircle(center: hub, radius: radius)),
    );
    canvas.drawCircle(
      hub,
      radius - 1,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1
        ..color = colors.onPrimary.withValues(alpha: 0.22),
    );
    paintGlyph(
      canvas,
      Glyphs.pc,
      Rect.fromCenter(center: hub, width: _hubIconBox, height: _hubIconBox),
      colors.onPrimary,
      strokeScale: _hubStrokeScale,
    );
  }

  void _paintHubLabel(Canvas canvas, FlowLayout layout) {
    final hub = layout.hub;
    final reachLeft = hub.dx - 8;
    final reachRight = layout.firstColumn - layout.peerRadius - 8 - hub.dx;
    final half = math.max(40.0, math.min(reachLeft, reachRight));
    final baseline = hub.dy + layout.hubRadius + 26;
    if (scene.hubName.isNotEmpty) {
      _drawText(
        canvas,
        scene.hubName,
        NbText.title,
        colors.text,
        Offset(hub.dx, baseline),
        maxWidth: 2 * half,
        centered: true,
      );
    }
    if (scene.hubCaption.isNotEmpty) {
      _drawText(
        canvas,
        scene.hubCaption,
        NbText.caption,
        colors.textWeak,
        Offset(hub.dx, baseline + 18),
        maxWidth: 2 * half,
        centered: true,
      );
    }
  }

  void _paintPeerLabel(Canvas canvas, FlowPeer peer, FlowSlot slot) {
    final room = slot.labelWidth;
    if (room <= 0) return;
    final left = slot.center.dx + scene.layout.peerRadius + _labelOffset;
    _drawText(
      canvas,
      peer.name,
      NbText.bodyStrong,
      colors.text,
      Offset(left, slot.center.dy - 5),
      maxWidth: room,
    );
    _paintChip(
      canvas,
      Offset(left, slot.center.dy + 3),
      peer.chipText,
      peer.chipTone,
      room,
    );
  }

  void _paintChip(
    Canvas canvas,
    Offset origin,
    String text,
    ChipTone tone,
    double maxWidth,
  ) {
    final (Color? fill, Color ink, Color? edge, bool dashed) = switch (tone) {
      ChipTone.run => (colors.primaryWeak, colors.primaryInk, null, false),
      ChipTone.ok => (colors.successWeak, colors.successInk, null, false),
      ChipTone.fail => (colors.dangerWeak, colors.danger, null, false),
      ChipTone.wait => (colors.surfaceWeak, colors.textWeak, null, false),
      ChipTone.foreign => (
        colors.surfaceWeak,
        colors.textWeak,
        colors.border,
        false,
      ),
      ChipTone.notVisible => (null, colors.textWeak, colors.hint, true),
    };
    final label = _text(
      text,
      NbText.label,
      color: ink,
      maxWidth: math.max(0, maxWidth - _chipPadding),
    );
    final width = label.width + _chipPadding;
    final shape = RRect.fromRectAndRadius(
      Rect.fromLTWH(origin.dx, origin.dy, width, _chipHeight),
      const Radius.circular(_chipHeight / 2),
    );
    if (fill != null) canvas.drawRRect(shape, Paint()..color = fill);
    if (edge != null) {
      final outline = Path()..addRRect(shape);
      canvas.drawPath(
        dashed ? dashPath(outline, const [2, 2]) : outline,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1
          ..color = edge,
      );
    }
    _drawText(
      canvas,
      text,
      NbText.label,
      ink,
      Offset(origin.dx + width / 2, origin.dy + 14),
      maxWidth: math.max(0, maxWidth - _chipPadding),
      centered: true,
      outline: fill == null,
    );
  }

  void _paintHeader(Canvas canvas) {
    final titleStyle = NbText.title.copyWith(
      fontVariations: [FontVariation.weight(colors.headingWeight)],
    );
    final title = _text(scene.title, titleStyle, color: colors.text);
    final baseline =
        _headerTop +
        title.computeDistanceToActualBaseline(TextBaseline.alphabetic);
    _drawText(
      canvas,
      scene.title,
      titleStyle,
      colors.text,
      Offset(_headerLeft, baseline),
    );
    final left = _headerLeft + title.width + _headerGap;
    final room = scene.layout.size.width - left - _headerLeft;
    if (room <= 0) return;
    _drawText(
      canvas,
      scene.count,
      NbText.caption,
      colors.textWeak,
      Offset(left, baseline),
      maxWidth: room,
    );
  }

  @override
  bool shouldRepaint(FlowPainter oldDelegate) =>
      !identical(oldDelegate.scene, scene) ||
      oldDelegate.colors != colors ||
      oldDelegate.reduceMotion != reduceMotion ||
      oldDelegate.textDirection != textDirection;
}
