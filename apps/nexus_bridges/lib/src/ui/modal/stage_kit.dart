import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:nexus_bridges_core/nexus_bridges_core.dart' show PairingOutcome;

import '../diagram/flow_painter.dart' show dashPath;
import '../icons/device_disc.dart' show DeviceGlyph;
import '../icons/file_icon.dart' show FileKind;
import '../icons/glyphs.dart';
import '../theme/tokens.dart';
import 'timeline.dart';

const Offset stageCenter = Offset(150, 85);

const double _haloRadius = 140;
const double _haloHeight = 84;
const double _haloSolidStop = 0.35;
const double _discGlyphBox = 24;
const double _discGlyphRadius = 22;
const double _discGlyphStroke = 1.5 / 1.6;
const double _dashedDiscWidth = 1.5;
const List<double> _dashedDiscPattern = [3.5, 3.5];
const double _badgeRing = 3.5;
const double _popDuration = 0.45;
const double _burstSkew = 0.4;
const double _burstDrop = 7;
const double _burstFlatten = 0.7;
const double _stillTime = 1000;

enum StageScene {
  connecting,
  comparing,
  waiting,
  paired,
  rejected,
  busy,
  paused,
  cancelledByPeer,
  expired,
  lost,
  networkChanged,
  failed,
  notSaved,
  mine,
  unpairLoop,
  unpairBreak,
  network,
  exit,
}

enum StageSize {
  normal(width: 300, height: 170, margin: 14, viewTop: 0),
  mid(width: 247, height: 140, margin: 10, viewTop: 0),
  big(width: 344, height: 195, margin: 16, viewTop: 0),
  wide(width: 344, height: 110, margin: 8, viewTop: 37);

  const StageSize({
    required this.width,
    required this.height,
    required this.margin,
    required this.viewTop,
  });

  final double width;
  final double height;
  final double margin;
  final double viewTop;
}

enum Own { mine, other }

final class ExitTransfer {
  const ExitTransfer({
    required this.peer,
    required this.kind,
    required this.towardsHub,
  });

  final DeviceGlyph peer;
  final FileKind kind;
  final bool towardsHub;

  @override
  bool operator ==(Object other) =>
      other is ExitTransfer &&
      other.peer == peer &&
      other.kind == kind &&
      other.towardsHub == towardsHub;

  @override
  int get hashCode => Object.hash(peer, kind, towardsHub);
}

final class StageInput {
  const StageInput({
    this.peer = DeviceGlyph.pc,
    this.hovered,
    this.picked,
    this.trusted = false,
    this.transfer,
  });

  final DeviceGlyph peer;
  final Own? hovered;
  final Own? picked;
  final bool trusted;
  final ExitTransfer? transfer;

  @override
  bool operator ==(Object other) =>
      other is StageInput &&
      other.peer == peer &&
      other.hovered == hovered &&
      other.picked == picked &&
      other.trusted == trusted &&
      other.transfer == transfer;

  @override
  int get hashCode => Object.hash(peer, hovered, picked, trusted, transfer);
}

final class StageSpec {
  const StageSpec({
    required this.size,
    required this.loops,
    required this.introEnd,
    this.changeEnd = 0,
  });

  final StageSize size;
  final bool loops;
  final double introEnd;
  final double changeEnd;
}

StageSpec stageSpecOf(StageScene scene, StageInput input) => switch (scene) {
  StageScene.connecting => const StageSpec(
    size: StageSize.normal,
    loops: true,
    introEnd: 0,
  ),
  StageScene.comparing => const StageSpec(
    size: StageSize.mid,
    loops: true,
    introEnd: 0,
  ),
  StageScene.waiting => const StageSpec(
    size: StageSize.mid,
    loops: true,
    introEnd: 1.9,
  ),
  StageScene.paired => const StageSpec(
    size: StageSize.big,
    loops: true,
    introEnd: 3.9,
  ),
  StageScene.rejected => const StageSpec(
    size: StageSize.big,
    loops: false,
    introEnd: 2.32,
  ),
  StageScene.busy => const StageSpec(
    size: StageSize.big,
    loops: true,
    introEnd: 0,
  ),
  StageScene.paused => const StageSpec(
    size: StageSize.big,
    loops: true,
    introEnd: 2.25,
  ),
  StageScene.cancelledByPeer => const StageSpec(
    size: StageSize.big,
    loops: false,
    introEnd: 1.23,
  ),
  StageScene.expired => const StageSpec(
    size: StageSize.big,
    loops: false,
    introEnd: 1.55,
  ),
  StageScene.lost => const StageSpec(
    size: StageSize.big,
    loops: true,
    introEnd: 2.65,
  ),
  StageScene.networkChanged => const StageSpec(
    size: StageSize.big,
    loops: false,
    introEnd: 1.75,
  ),
  StageScene.failed => const StageSpec(
    size: StageSize.big,
    loops: false,
    introEnd: 1.3,
  ),
  StageScene.notSaved => const StageSpec(
    size: StageSize.big,
    loops: false,
    introEnd: 1.17,
  ),
  StageScene.mine => const StageSpec(
    size: StageSize.big,
    loops: true,
    introEnd: 0.55,
    changeEnd: 1.65,
  ),
  StageScene.unpairLoop => const StageSpec(
    size: StageSize.big,
    loops: true,
    introEnd: 0,
  ),
  StageScene.unpairBreak => const StageSpec(
    size: StageSize.big,
    loops: false,
    introEnd: 1,
  ),
  StageScene.network => StageSpec(
    size: StageSize.big,
    loops: !input.trusted,
    introEnd: input.trusted ? 0.55 : 0,
    changeEnd: 0.55,
  ),
  StageScene.exit => const StageSpec(
    size: StageSize.wide,
    loops: true,
    introEnd: 0,
  ),
};

StageScene stageForOutcome(PairingOutcome? outcome) => switch (outcome) {
  PairingOutcome.paired => StageScene.paired,
  PairingOutcome.rejected => StageScene.rejected,
  PairingOutcome.busy => StageScene.busy,
  PairingOutcome.paused => StageScene.paused,
  PairingOutcome.cancelledByPeer => StageScene.cancelledByPeer,
  PairingOutcome.expired => StageScene.expired,
  PairingOutcome.lost => StageScene.lost,
  PairingOutcome.networkChanged => StageScene.networkChanged,
  PairingOutcome.failed || null => StageScene.failed,
  PairingOutcome.notSaved => StageScene.notSaved,
};

final class StageChanges {
  const StageChanges({
    this.hoveredAt,
    this.hoveredFrom,
    this.pickedAt,
    this.pickedFrom,
    this.trustedAt,
    this.trustedFrom = false,
    this.knobFrom,
  });

  final double? hoveredAt;
  final Own? hoveredFrom;
  final double? pickedAt;
  final Own? pickedFrom;
  final double? trustedAt;
  final bool trustedFrom;
  final double? knobFrom;

  double get lastAt =>
      math.max(hoveredAt ?? 0, math.max(pickedAt ?? 0, trustedAt ?? 0));

  @override
  bool operator ==(Object other) =>
      other is StageChanges &&
      other.hoveredAt == hoveredAt &&
      other.hoveredFrom == hoveredFrom &&
      other.pickedAt == pickedAt &&
      other.pickedFrom == pickedFrom &&
      other.trustedAt == trustedAt &&
      other.trustedFrom == trustedFrom &&
      other.knobFrom == knobFrom;

  @override
  int get hashCode => Object.hash(
    hoveredAt,
    hoveredFrom,
    pickedAt,
    pickedFrom,
    trustedAt,
    trustedFrom,
    knobFrom,
  );
}

final class StageFrame {
  const StageFrame({
    required this.t,
    required this.still,
    required this.colors,
    this.input = const StageInput(),
    this.changes = const StageChanges(),
  });

  final double t;
  final bool still;
  final NbColors colors;
  final StageInput input;
  final StageChanges changes;

  double get settledT => still ? _stillTime : t;
}

typedef StageSceneFn = void Function(Canvas canvas, StageFrame frame);

Color fadeColor(Color color, double opacity) =>
    color.withValues(alpha: color.a * opacity.clamp(0.0, 1.0));

double _roundTenth(double value) => (value * 10).roundToDouble() / 10;

List<double> _alphaMatrix(double alpha) => List<double>.generate(
  20,
  (i) => i == 18 ? alpha : (i == 0 || i == 6 || i == 12 ? 1.0 : 0.0),
);

void paintGroup(
  Canvas canvas, {
  required VoidCallback paint,
  Offset pivot = Offset.zero,
  double scale = 1,
  double rotation = 0,
  Offset shift = Offset.zero,
  double opacity = 1,
  Rect? bounds,
}) {
  if (!(opacity > 0)) return;
  if (opacity < 1) {
    canvas.saveLayer(
      bounds,
      Paint()..colorFilter = ColorFilter.matrix(_alphaMatrix(opacity)),
    );
  } else {
    canvas.save();
  }
  canvas.translate(pivot.dx + shift.dx, pivot.dy + shift.dy);
  if (rotation != 0) canvas.rotate(rotation);
  if (scale != 1) canvas.scale(scale);
  canvas.translate(-pivot.dx, -pivot.dy);
  paint();
  canvas.restore();
}

({double scale, double opacity}) popAt(
  double t, {
  required double delay,
  double duration = _popDuration,
}) {
  final scale = keyframes(
    t,
    delay: delay,
    duration: duration,
    frames: const [Kf(0, 0.4), Kf(0.6, 1.12), Kf(1, 1)],
    curve: labEaseOut,
  );
  final opacity = keyframes(
    t,
    delay: delay,
    duration: duration,
    frames: const [Kf(0, 0), Kf(1, 1)],
    curve: labEaseOut,
  );
  return (scale: scale, opacity: opacity);
}

void paintHalo(Canvas canvas, StageFrame frame, Color tone) {
  final colors = frame.colors;
  canvas.save();
  canvas.translate(stageCenter.dx, stageCenter.dy);
  canvas.scale(1, _haloHeight / _haloRadius);
  canvas.drawCircle(
    Offset.zero,
    _haloRadius,
    Paint()
      ..shader = RadialGradient(
        colors: [
          fadeColor(tone, colors.haloOpacity),
          tone.withValues(alpha: 0),
        ],
        stops: const [_haloSolidStop, 1],
      ).createShader(Rect.fromCircle(center: Offset.zero, radius: _haloRadius)),
  );
  canvas.restore();
}

Glyph glyphOfDevice(DeviceGlyph glyph) =>
    glyph == DeviceGlyph.phone ? Glyphs.phone : Glyphs.pc;

void paintDisc(
  Canvas canvas,
  StageFrame frame, {
  required Offset center,
  required double radius,
  DeviceGlyph? glyph,
  Color? stroke,
  double strokeWidth = 1.6,
  Color? fill,
  Color? ink,
  bool dashed = false,
  double? glyphScale,
}) {
  final colors = frame.colors;
  final bounds = Rect.fromCircle(center: center, radius: radius);

  if (dashed) {
    canvas.drawCircle(center, radius, Paint()..color = colors.card);
    canvas.drawPath(
      dashPath(Path()..addOval(bounds), _dashedDiscPattern),
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = _dashedDiscWidth
        ..color = colors.stageHint,
    );
  } else {
    final body = Paint();
    if (fill != null) {
      body.color = fill;
    } else {
      body.shader = LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: [colors.nodeTop, colors.nodeBottom],
      ).createShader(bounds);
    }
    canvas.drawCircle(center, radius, body);
    canvas.drawCircle(
      center,
      radius,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = strokeWidth
        ..color = stroke ?? colors.stageBorder,
    );
    if (fill == null && stroke != null && colors.discTint > 0) {
      canvas.drawCircle(
        center,
        radius,
        Paint()..color = fadeColor(stroke, colors.discTint),
      );
    }
  }

  if (glyph == null) return;
  final side = _discGlyphBox * (glyphScale ?? radius / _discGlyphRadius);
  paintGlyph(
    canvas,
    glyphOfDevice(glyph),
    Rect.fromCenter(center: center, width: side, height: side),
    ink ?? colors.text,
    strokeScale: _discGlyphStroke,
  );
}

void paintDashedRing(
  Canvas canvas,
  StageFrame frame, {
  required double radius,
  required Color color,
  required double width,
  required List<double> pattern,
  Offset center = stageCenter,
  bool round = false,
  double? period,
}) {
  final turn = period == null || frame.still
      ? 0.0
      : 2 * math.pi * loopPhase(frame.t, period: period);
  final ring = dashPath(
    Path()..addOval(Rect.fromCircle(center: center, radius: radius)),
    pattern,
  );
  paintGroup(
    canvas,
    pivot: center,
    rotation: turn,
    paint: () => canvas.drawPath(
      ring,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = width
        ..strokeCap = round ? StrokeCap.round : StrokeCap.butt
        ..color = color,
    ),
  );
}

void paintCheckBadge(
  Canvas canvas,
  StageFrame frame, {
  required Offset center,
  required double radius,
}) {
  final colors = frame.colors;
  canvas.drawCircle(center, radius, Paint()..color = colors.success);
  canvas.drawCircle(
    center,
    radius,
    Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = _badgeRing
      ..color = colors.card,
  );
  final start = center + Offset(-radius * 0.42, radius * 0.02);
  final middle = start + Offset(radius * 0.3, radius * 0.3);
  final end = middle + Offset(radius * 0.56, -radius * 0.6);
  canvas.drawPath(
    Path()
      ..moveTo(start.dx, start.dy)
      ..lineTo(middle.dx, middle.dy)
      ..lineTo(end.dx, end.dy),
    Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = _roundTenth(radius * 0.22)
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round
      ..color = colors.onSuccessDisc,
  );
}

void paintCrossBadge(
  Canvas canvas,
  StageFrame frame, {
  required Offset center,
  required double radius,
}) {
  final colors = frame.colors;
  canvas.drawCircle(center, radius, Paint()..color = colors.dangerFill);
  canvas.drawCircle(
    center,
    radius,
    Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = _badgeRing
      ..color = colors.card,
  );
  final near = radius * 0.32;
  canvas.drawPath(
    Path()
      ..moveTo(center.dx - near, center.dy - near)
      ..relativeLineTo(radius * 0.64, radius * 0.64)
      ..moveTo(center.dx + near, center.dy - near)
      ..relativeLineTo(-radius * 0.64, radius * 0.64),
    Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = _roundTenth(radius * 0.2)
      ..strokeCap = StrokeCap.round
      ..color = colors.onPrimary,
  );
}

void paintBurst(
  Canvas canvas, {
  required Offset at,
  required Color color,
  required int count,
  required double spread,
  required double progress,
}) {
  if (count <= 0 || !(progress > 0) || progress >= 1) return;
  final paint = Paint()..color = fadeColor(color, 1 - progress);
  for (var i = 0; i < count; i++) {
    final angle = i / count * 2 * math.pi + _burstSkew;
    final target = Offset(
      math.cos(angle) * spread,
      math.sin(angle) * spread * _burstFlatten + _burstDrop,
    );
    canvas.drawCircle(at + target * progress, 1.6 + (i % 3) * 0.5, paint);
  }
}
