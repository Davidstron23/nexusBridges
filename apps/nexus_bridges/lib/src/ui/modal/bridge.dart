import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../icons/device_disc.dart' show DeviceGlyph;
import '../theme/tokens.dart';
import 'stage_kit.dart';
import 'stage_outcomes.dart' show paintPairedRing;
import 'timeline.dart';

const double _degree = math.pi / 180;
const double _settledTime = 1000;
const double _dashRest = 1.02;

const double _deckY = 93;
const double _towerY = 55;
const double _cableY = 86;
const double _pylonBase = 105;
const double _leftPylonX = 104;
const double _rightPylonX = 196;
const double _pylonHalfWidth = 3;
const double _pylonHeight = 50;
const double _pylonRadius = 2;
const double _pylonRise = 0.3;
const double _pylonFill = 0.22;
const double _pylonStroke = 1.6;
const double _deckWidth = 3;
const double _cableWidth = 2.2;
const double _hangerWidth = 1.5;
const double _hangerOpacity = 0.8;
const double _hangerRise = 0.2;
const double _hangerShrinkBy = 0.4;
const double _hangerTop = 69.1;
const double _hangerBottom = 78.9;

const double _discRadius = 32;
const double _discSlide = 88;
const double _discSlideScale = 0.7;
const double _discDimLow = 0.4;
const double _rimWidth = 1.6;
const double _badgeRadius = 12;

const double _laneStart = 104;
const double _laneEnd = 196;
const double _laneRadius = 2.3;
const double _lanePeriod = 2;
const double _laneFadeIn = 0.15;
const double _laneLightAlpha = 0.9;

const double _flashRadius = 12;
const double _flashWidth = 2.2;
const double _flashFrom = 0.6;
const double _flashTo = 1.9;
const double _flashOpacity = 0.9;
const double _flashDelay = 3.3;
const double _flashDuration = 0.55;

const double _crackWidth = 2.2;
const double _loopPeriod = 4.4;
const double _burstSeed = 1e-6;
const int _burstCount = 5;

const double _spanFadeLow = 0.25;
const double _breakDeck = 48;
const double _breakCable = 34;

const Offset _leftDisc = Offset(62, 85);
const Offset _rightDisc = Offset(238, 85);
const Offset _joint = Offset(150, _deckY);
const Offset _badgeCenter = Offset(262, 109);
const Offset _leftDeckPivot = Offset(96, _deckY);
const Offset _rightDeckPivot = Offset(204, _deckY);
const Offset _leftCablePivot = Offset(104, _towerY);
const Offset _rightCablePivot = Offset(196, _towerY);
const Rect _layerBounds = Rect.fromLTWH(0, 0, 300, 170);

const List<Offset> _leftHangers = [
  Offset(116, _hangerTop),
  Offset(128, _hangerBottom),
];
const List<Offset> _rightHangers = [
  Offset(184, _hangerTop),
  Offset(172, _hangerBottom),
];

final Path _leftDeck = Path()
  ..moveTo(96, _deckY)
  ..lineTo(150, _deckY);
final Path _rightDeck = Path()
  ..moveTo(204, _deckY)
  ..lineTo(150, _deckY);
final Path _leftCable = Path()
  ..moveTo(104, _towerY)
  ..quadraticBezierTo(127, _cableY, 150, _cableY);
final Path _rightCable = Path()
  ..moveTo(196, _towerY)
  ..quadraticBezierTo(173, _cableY, 150, _cableY);
final Path _crack = Path()
  ..moveTo(150, _deckY - 10)
  ..relativeLineTo(0, -7)
  ..moveTo(159, _deckY - 7)
  ..relativeLineTo(5, -5)
  ..moveTo(141, _deckY - 7)
  ..relativeLineTo(-5, -5);

enum BridgeMode { paired, rejected, loop, breaking }

typedef BridgeSides = ({double left, double right});
typedef BridgeHangers = ({double first, double second});
typedef BridgeBadge = ({double scale, double opacity});
typedef BridgeCrack = ({double opacity, double scale});

final class BridgePose {
  const BridgePose({
    this.ring = false,
    this.discSlide = 1,
    this.discsDim = 1,
    this.peerRed = 0,
    this.peerShake = 0,
    this.pylons = 1,
    this.deckDrawn = 1,
    this.cableDrawn = 1,
    this.hangers = (first: 1, second: 1),
    this.hangersFade = (left: 1, right: 1),
    this.hangersShrink = (left: 0, right: 0),
    this.deckAngle = (left: 0, right: 0),
    this.cableAngle = (left: 0, right: 0),
    this.spanOpacity = 1,
    this.red = 0,
    this.hangersRed = 0,
    this.flash,
    this.burst,
    this.burstRamp = 1,
    this.crack = (opacity: 0, scale: 1),
    this.badge = (scale: 1, opacity: 0),
    this.lanes = 0,
    this.lanesPhase = 0,
  });

  final bool ring;
  final double discSlide;
  final double discsDim;
  final double peerRed;
  final double peerShake;
  final double pylons;
  final double deckDrawn;
  final double cableDrawn;
  final BridgeHangers hangers;
  final BridgeSides hangersFade;
  final BridgeSides hangersShrink;
  final BridgeSides deckAngle;
  final BridgeSides cableAngle;
  final double spanOpacity;
  final double red;
  final double hangersRed;
  final double? flash;
  final double? burst;
  final double burstRamp;
  final BridgeCrack crack;
  final BridgeBadge badge;
  final double lanes;
  final double lanesPhase;

  @override
  bool operator ==(Object other) =>
      other is BridgePose &&
      other.ring == ring &&
      other.discSlide == discSlide &&
      other.discsDim == discsDim &&
      other.peerRed == peerRed &&
      other.peerShake == peerShake &&
      other.pylons == pylons &&
      other.deckDrawn == deckDrawn &&
      other.cableDrawn == cableDrawn &&
      other.hangers == hangers &&
      other.hangersFade == hangersFade &&
      other.hangersShrink == hangersShrink &&
      other.deckAngle == deckAngle &&
      other.cableAngle == cableAngle &&
      other.spanOpacity == spanOpacity &&
      other.red == red &&
      other.hangersRed == hangersRed &&
      other.flash == flash &&
      other.burst == burst &&
      other.burstRamp == burstRamp &&
      other.crack == crack &&
      other.badge == badge &&
      other.lanes == lanes &&
      other.lanesPhase == lanesPhase;

  @override
  int get hashCode => Object.hashAll([
    ring,
    discSlide,
    discsDim,
    peerRed,
    peerShake,
    pylons,
    deckDrawn,
    cableDrawn,
    hangers,
    hangersFade,
    hangersShrink,
    deckAngle,
    cableAngle,
    spanOpacity,
    red,
    hangersRed,
    flash,
    burst,
    burstRamp,
    crack,
    badge,
    lanes,
    lanesPhase,
  ]);
}

double _drawn(double progress) => dashWindow(_dashRest * (1 - progress)).$2;

double? _flyProgress(
  double t, {
  required double delay,
  required double duration,
}) {
  final raw = (t - delay) / duration;
  if (!(raw > 0 && raw < 1)) return null;
  return labEaseOut.transform(raw);
}

BridgeSides _mirrored(double angle) => (left: angle, right: -angle);

double _loopAngle(double f, double peak, double hold) => keyframes(
  f,
  delay: 0,
  duration: 1,
  frames: [
    const Kf(0, 0),
    const Kf(0.42, 0, labEaseIn),
    Kf(0.54, peak, labEaseOut),
    Kf(0.6, hold, labEaseInOut),
    Kf(0.8, hold, labEaseInOut),
    const Kf(0.96, 0),
    const Kf(1, 0),
  ],
);

double _fall(double t, double deep, double back, double settle) => keyframes(
  t,
  delay: 1.32,
  duration: 1,
  frames: [
    const Kf(0, 0, labEaseIn),
    Kf(0.55, deep, labEaseOut),
    Kf(0.75, back),
    Kf(1, settle),
  ],
  curve: Curves.ease,
);

BridgePose _pairedPose(double t, bool still) => BridgePose(
  ring: !still && t < 1.95,
  discSlide: phase(t, delay: 1.75, duration: 0.55, curve: labEaseOut),
  pylons: phase(t, delay: 2.2, duration: 0.45, curve: labEaseOut),
  deckDrawn: _drawn(phase(t, delay: 2.55, duration: 0.6, curve: labEaseInOut)),
  cableDrawn: _drawn(phase(t, delay: 2.6, duration: 0.65, curve: labEaseInOut)),
  hangers: (
    first: phase(t, delay: 3.02, duration: 0.35, curve: labEaseOut),
    second: phase(t, delay: 3.09, duration: 0.35, curve: labEaseOut),
  ),
  flash: still
      ? null
      : _flyProgress(t, delay: _flashDelay, duration: _flashDuration),
  badge: popAt(t, delay: 3.4),
  lanes: still ? 0 : phase(t, delay: 3.45, duration: 0.45, curve: Curves.ease),
  lanesPhase: still ? 0 : loopPhase(t, period: _lanePeriod),
);

BridgePose _rejectedPose(double t) {
  final red = phase(t, delay: 1.3, duration: 0.3, curve: Curves.ease);
  final gone = phase(t, delay: 1.32, duration: 0.3, curve: Curves.ease);
  return BridgePose(
    peerRed: phase(t, delay: 1.35, duration: 0.3, curve: Curves.ease),
    peerShake: keyframes(
      t,
      delay: 1.42,
      duration: 0.42,
      frames: const [
        Kf(0, 0),
        Kf(0.2, -4),
        Kf(0.4, 4),
        Kf(0.6, -3),
        Kf(0.8, 2),
        Kf(1, 0),
      ],
      curve: labShake,
    ),
    pylons: phase(t, delay: 0.1, duration: 0.45, curve: labEaseOut),
    deckDrawn: _drawn(
      phase(t, delay: 0.45, duration: 0.6, curve: labEaseInOut),
    ),
    cableDrawn: _drawn(
      phase(t, delay: 0.5, duration: 0.65, curve: labEaseInOut),
    ),
    hangers: (
      first: phase(t, delay: 0.95, duration: 0.3, curve: labEaseOut),
      second: phase(t, delay: 1.02, duration: 0.3, curve: labEaseOut),
    ),
    hangersFade: (left: 1, right: 1 - gone),
    hangersShrink: (left: 0, right: gone),
    deckAngle: (
      left: 7 * phase(t, delay: 1.45, duration: 0.6, curve: labEaseOut),
      right: _fall(t, -56, -44, -50),
    ),
    cableAngle: (left: 0, right: _fall(t, -44, -34, -38)),
    red: red,
    hangersRed: red,
    burst: _flyProgress(t, delay: 1.38, duration: 0.9),
    badge: popAt(t, delay: 1.6),
  );
}

BridgePose _loopPose(double t) {
  final f = loopPhase(t, period: _loopPeriod);
  final deck = _loopAngle(f, 18, 15);
  final cable = _loopAngle(f, 12, 10);
  final red = keyframes(
    f,
    delay: 0,
    duration: 1,
    frames: const [
      Kf(0, 0),
      Kf(0.4, 0),
      Kf(0.48, 1),
      Kf(0.86, 1),
      Kf(0.96, 0),
      Kf(1, 0),
    ],
    curve: Curves.ease,
  );
  final fade = keyframes(
    f,
    delay: 0,
    duration: 1,
    frames: const [
      Kf(0, 1),
      Kf(0.42, 1),
      Kf(0.52, 0),
      Kf(0.88, 0),
      Kf(0.97, 1),
      Kf(1, 1),
    ],
    curve: Curves.ease,
  );
  final travel = f >= 0.49 && f < 0.7
      ? Curves.ease.transform((f - 0.49) / 0.21)
      : null;
  final ramp = f >= 0.46 && f < 0.49
      ? Curves.ease.transform((f - 0.46) / 0.03)
      : null;
  return BridgePose(
    deckAngle: _mirrored(deck),
    cableAngle: _mirrored(cable),
    hangersFade: (left: fade, right: fade),
    red: red,
    hangersRed: red,
    burst: travel ?? (ramp == null ? null : 0),
    burstRamp: ramp ?? 1,
    crack: (
      opacity: keyframes(
        f,
        delay: 0,
        duration: 1,
        frames: const [
          Kf(0, 0),
          Kf(0.45, 0),
          Kf(0.49, 1),
          Kf(0.6, 0),
          Kf(1, 0),
        ],
        curve: Curves.ease,
      ),
      scale: keyframes(
        f,
        delay: 0,
        duration: 1,
        frames: const [Kf(0, 0.6), Kf(0.45, 0.6), Kf(0.6, 1.35), Kf(1, 1.35)],
        curve: Curves.ease,
      ),
    ),
    lanes: keyframes(
      f,
      delay: 0,
      duration: 1,
      frames: const [Kf(0, 1), Kf(0.38, 1), Kf(0.44, 0), Kf(0.94, 0), Kf(1, 1)],
      curve: Curves.ease,
    ),
    lanesPhase: loopPhase(t, period: _lanePeriod),
  );
}

BridgePose _breakingPose(double t) {
  final swing = phase(t, delay: 0.05, duration: 0.8, curve: labEaseOutSoft);
  final gone = phase(t, delay: 0, duration: 0.25, curve: Curves.ease);
  return BridgePose(
    discsDim:
        1 -
        (1 - _discDimLow) *
            phase(t, delay: 0.5, duration: 0.5, curve: Curves.ease),
    hangersFade: (left: 1 - gone, right: 1 - gone),
    hangersShrink: (left: gone, right: gone),
    deckAngle: _mirrored(_breakDeck * swing),
    cableAngle: _mirrored(_breakCable * swing),
    spanOpacity: 1 - _spanFadeLow * swing,
    red: phase(t, delay: 0, duration: 0.2, curve: Curves.ease),
    burst: _flyProgress(t, delay: 0.2, duration: 0.8),
  );
}

BridgePose bridgePose(BridgeMode mode, double t, {required bool still}) {
  final time = still ? _settledTime : t;
  return switch (mode) {
    BridgeMode.paired => _pairedPose(time, still),
    BridgeMode.rejected => _rejectedPose(time),
    BridgeMode.loop => still ? const BridgePose() : _loopPose(time),
    BridgeMode.breaking => _breakingPose(time),
  };
}

enum _DiscStyle { success, own, plain }

void _paintDisc(
  Canvas canvas,
  StageFrame frame,
  Offset center,
  DeviceGlyph glyph,
  _DiscStyle style,
) {
  final colors = frame.colors;
  switch (style) {
    case _DiscStyle.success:
      paintDisc(
        canvas,
        frame,
        center: center,
        radius: _discRadius,
        glyph: glyph,
        fill: colors.successWeak,
        stroke: colors.success,
        strokeWidth: 2,
        ink: colors.successInk,
      );
    case _DiscStyle.own:
      paintDisc(
        canvas,
        frame,
        center: center,
        radius: _discRadius,
        glyph: glyph,
        stroke: colors.primary,
        ink: colors.primaryInk,
      );
    case _DiscStyle.plain:
      paintDisc(
        canvas,
        frame,
        center: center,
        radius: _discRadius,
        glyph: glyph,
      );
  }
}

void _paintSlidingDisc(
  Canvas canvas,
  StageFrame frame,
  Offset center,
  DeviceGlyph glyph,
  BridgePose pose,
  double direction,
) {
  paintGroup(
    canvas,
    pivot: center,
    shift: Offset(direction * _discSlide * (1 - pose.discSlide), 0),
    scale: _discSlideScale + (1 - _discSlideScale) * pose.discSlide,
    opacity: pose.discSlide,
    bounds: _layerBounds,
    paint: () => _paintDisc(canvas, frame, center, glyph, _DiscStyle.success),
  );
}

void _paintDiscs(
  Canvas canvas,
  StageFrame frame,
  BridgeMode mode,
  BridgePose pose,
) {
  final colors = frame.colors;
  final peer = frame.input.peer;
  switch (mode) {
    case BridgeMode.paired:
      _paintSlidingDisc(canvas, frame, _leftDisc, DeviceGlyph.pc, pose, 1);
      _paintSlidingDisc(canvas, frame, _rightDisc, peer, pose, -1);
    case BridgeMode.rejected:
      _paintDisc(canvas, frame, _leftDisc, DeviceGlyph.pc, _DiscStyle.own);
      paintGroup(
        canvas,
        shift: Offset(pose.peerShake, 0),
        paint: () {
          _paintDisc(canvas, frame, _rightDisc, peer, _DiscStyle.plain);
          if (pose.peerRed > 0) {
            canvas.drawCircle(
              _rightDisc,
              _discRadius,
              Paint()
                ..style = PaintingStyle.stroke
                ..strokeWidth = _rimWidth
                ..color = fadeColor(colors.danger, pose.peerRed),
            );
          }
        },
      );
    case BridgeMode.loop:
      _paintDisc(canvas, frame, _leftDisc, DeviceGlyph.pc, _DiscStyle.own);
      _paintDisc(canvas, frame, _rightDisc, peer, _DiscStyle.plain);
    case BridgeMode.breaking:
      paintGroup(
        canvas,
        opacity: pose.discsDim,
        bounds: _layerBounds,
        paint: () => _paintDisc(
          canvas,
          frame,
          _leftDisc,
          DeviceGlyph.pc,
          _DiscStyle.own,
        ),
      );
      paintGroup(
        canvas,
        opacity: pose.discsDim,
        bounds: _layerBounds,
        paint: () =>
            _paintDisc(canvas, frame, _rightDisc, peer, _DiscStyle.plain),
      );
  }
}

Paint _line(Color color, double width) => Paint()
  ..style = PaintingStyle.stroke
  ..strokeWidth = width
  ..strokeCap = StrokeCap.round
  ..color = color;

void _paintPylon(Canvas canvas, double x, double progress, Color tone) {
  if (!(progress > 0)) return;
  paintGroup(
    canvas,
    opacity: progress,
    bounds: _layerBounds,
    paint: () {
      canvas.save();
      canvas.translate(x, _pylonBase);
      canvas.scale(1, _pylonRise + (1 - _pylonRise) * progress);
      canvas.translate(-x, -_pylonBase);
      final body = RRect.fromRectAndRadius(
        Rect.fromLTWH(
          x - _pylonHalfWidth,
          _towerY,
          2 * _pylonHalfWidth,
          _pylonHeight,
        ),
        const Radius.circular(_pylonRadius),
      );
      canvas.drawRRect(body, Paint()..color = fadeColor(tone, _pylonFill));
      canvas.drawRRect(
        body,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = _pylonStroke
          ..color = tone,
      );
      canvas.restore();
    },
  );
}

void _paintSpan(
  Canvas canvas, {
  required Path path,
  required double drawn,
  required Offset pivot,
  required double angle,
  required double opacity,
  required Color tone,
  required double width,
}) {
  if (!(drawn > 0)) return;
  paintGroup(
    canvas,
    pivot: pivot,
    rotation: angle * _degree,
    opacity: opacity,
    bounds: _layerBounds,
    paint: () =>
        canvas.drawPath(partialPath(path, 0, drawn), _line(tone, width)),
  );
}

void _paintHangers(
  Canvas canvas,
  List<Offset> tops,
  BridgeHangers growth,
  double fade,
  double shrink,
  Color tone,
) {
  if (!(fade > 0)) return;
  paintGroup(
    canvas,
    scale: 1 - _hangerShrinkBy * shrink,
    paint: () {
      final grown = [growth.first, growth.second];
      for (var i = 0; i < tops.length; i++) {
        final g = grown[i];
        if (!(g > 0)) continue;
        final top = tops[i];
        canvas.save();
        canvas.translate(top.dx, top.dy);
        canvas.scale(1, _hangerRise + (1 - _hangerRise) * g);
        canvas.translate(-top.dx, -top.dy);
        canvas.drawLine(
          top,
          Offset(top.dx, _deckY),
          _line(fadeColor(tone, _hangerOpacity * g * fade), _hangerWidth),
        );
        canvas.restore();
      }
    },
  );
}

double _laneOpacity(double phase) {
  if (phase < _laneFadeIn) return phase / _laneFadeIn;
  if (phase > 1 - _laneFadeIn) return (1 - phase) / _laneFadeIn;
  return 1;
}

void _paintLanes(Canvas canvas, BridgePose pose, NbColors colors, Color tone) {
  if (!(pose.lanes > 0)) return;
  for (final offset in const [0.0, 0.5]) {
    final ph = (pose.lanesPhase + offset) % 1;
    canvas.drawCircle(
      Offset(_laneStart + (_laneEnd - _laneStart) * ph, _deckY),
      _laneRadius,
      Paint()..color = fadeColor(tone, _laneOpacity(ph) * pose.lanes),
    );
  }
  for (final offset in const [0.25, 0.75]) {
    final ph = (pose.lanesPhase + offset) % 1;
    canvas.drawCircle(
      Offset(_laneEnd - (_laneEnd - _laneStart) * ph, _deckY),
      _laneRadius,
      Paint()
        ..color = fadeColor(
          colors.onPrimary,
          _laneLightAlpha * _laneOpacity(ph) * pose.lanes,
        ),
    );
  }
}

void _paintBurst(
  Canvas canvas,
  BridgeMode mode,
  BridgePose pose,
  NbColors colors,
) {
  final progress = pose.burst;
  if (progress == null) return;
  final (at, spread) = switch (mode) {
    BridgeMode.rejected => (const Offset(176, _deckY), 18.0),
    BridgeMode.loop => (_joint, 16.0),
    BridgeMode.breaking => (_joint, 18.0),
    BridgeMode.paired => (_joint, 0.0),
  };
  if (!(spread > 0)) return;
  paintGroup(
    canvas,
    opacity: pose.burstRamp,
    bounds: _layerBounds,
    paint: () => paintBurst(
      canvas,
      at: at,
      color: colors.danger,
      count: _burstCount,
      spread: spread,
      progress: math.max(progress, _burstSeed),
    ),
  );
}

void paintBridgeScene(Canvas canvas, StageFrame frame, BridgeMode mode) {
  final colors = frame.colors;
  final pose = bridgePose(mode, frame.t, still: frame.still);
  final base = mode == BridgeMode.paired ? colors.success : colors.primary;
  final tone = Color.lerp(base, colors.danger, pose.red)!;
  final hangerTone = Color.lerp(base, colors.danger, pose.hangersRed)!;

  _paintDiscs(canvas, frame, mode, pose);

  _paintPylon(canvas, _leftPylonX, pose.pylons, tone);
  _paintPylon(canvas, _rightPylonX, pose.pylons, tone);

  _paintSpan(
    canvas,
    path: _leftDeck,
    drawn: pose.deckDrawn,
    pivot: _leftDeckPivot,
    angle: pose.deckAngle.left,
    opacity: pose.spanOpacity,
    tone: tone,
    width: _deckWidth,
  );
  _paintSpan(
    canvas,
    path: _rightDeck,
    drawn: pose.deckDrawn,
    pivot: _rightDeckPivot,
    angle: pose.deckAngle.right,
    opacity: pose.spanOpacity,
    tone: tone,
    width: _deckWidth,
  );
  _paintSpan(
    canvas,
    path: _leftCable,
    drawn: pose.cableDrawn,
    pivot: _leftCablePivot,
    angle: pose.cableAngle.left,
    opacity: pose.spanOpacity,
    tone: tone,
    width: _cableWidth,
  );
  _paintSpan(
    canvas,
    path: _rightCable,
    drawn: pose.cableDrawn,
    pivot: _rightCablePivot,
    angle: pose.cableAngle.right,
    opacity: pose.spanOpacity,
    tone: tone,
    width: _cableWidth,
  );

  _paintHangers(
    canvas,
    _leftHangers,
    pose.hangers,
    pose.hangersFade.left,
    pose.hangersShrink.left,
    hangerTone,
  );
  _paintHangers(
    canvas,
    _rightHangers,
    pose.hangers,
    pose.hangersFade.right,
    pose.hangersShrink.right,
    hangerTone,
  );

  _paintLanes(canvas, pose, colors, tone);

  final flash = pose.flash;
  if (flash != null) {
    paintGroup(
      canvas,
      pivot: _joint,
      scale: _flashFrom + (_flashTo - _flashFrom) * flash,
      paint: () => canvas.drawCircle(
        _joint,
        _flashRadius,
        _line(fadeColor(tone, _flashOpacity * (1 - flash)), _flashWidth),
      ),
    );
  }

  if (pose.crack.opacity > 0) {
    paintGroup(
      canvas,
      pivot: _joint,
      scale: pose.crack.scale,
      paint: () => canvas.drawPath(
        _crack,
        _line(fadeColor(colors.danger, pose.crack.opacity), _crackWidth),
      ),
    );
  }

  _paintBurst(canvas, mode, pose, colors);

  if (pose.badge.opacity > 0) {
    paintGroup(
      canvas,
      pivot: _badgeCenter,
      scale: pose.badge.scale,
      opacity: pose.badge.opacity,
      bounds: _layerBounds,
      paint: () => mode == BridgeMode.paired
          ? paintCheckBadge(
              canvas,
              frame,
              center: _badgeCenter,
              radius: _badgeRadius,
            )
          : paintCrossBadge(
              canvas,
              frame,
              center: _badgeCenter,
              radius: _badgeRadius,
            ),
    );
  }
}

void paintPaired(Canvas canvas, StageFrame frame) {
  paintPairedRing(canvas, frame);
  paintBridgeScene(canvas, frame, BridgeMode.paired);
}

void paintRejected(Canvas canvas, StageFrame frame) =>
    paintBridgeScene(canvas, frame, BridgeMode.rejected);

void paintUnpairLoop(Canvas canvas, StageFrame frame) =>
    paintBridgeScene(canvas, frame, BridgeMode.loop);

void paintUnpairBreak(Canvas canvas, StageFrame frame) =>
    paintBridgeScene(canvas, frame, BridgeMode.breaking);
