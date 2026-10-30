import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'stage_kit.dart';
import 'timeline.dart';

const double _ringRadius = 56;
const double _discRadius = 40;
const double _slowTurn = 10;
const double _pingPeriod = 1.8;
const double _pingFrom = 0.45;
const double _pingGrowth = 0.55;
const double _pingRadius = 40;
const double _pingWidth = 1.6;
const double _orbitPeriod = 1.8;
const double _orbitDotRadius = 6;
const double _orbitHaloRadius = 11;
const double _orbitHaloOpacity = 0.18;
const double _compareRingWidth = 2.2;
const double _compareFillRadius = 48;
const double _waitPingRadius = 42;
const double _waitPingDelay = 1.6;
const double _waitPingPeriod = 2.6;
const double _waitPingCut = 0.7;
const double _waitPingGrowth = 0.5;
const double _trackWidth = 5;
const double _arcLength = 86;
const double _arcPeriod = 1.8;
const double _badgeRadius = 11;
const double _badgeDelay = 1.45;
const Offset _badgeCenter = Offset(179, 114);

void paintConnecting(Canvas canvas, StageFrame frame) {
  final colors = frame.colors;

  paintDashedRing(
    canvas,
    frame,
    radius: _ringRadius,
    color: colors.stageDashedRing,
    width: 1.6,
    pattern: const [2, 8],
    period: _slowTurn,
  );

  if (!frame.still) {
    final eased = labEaseOut.transform(loopPhase(frame.t, period: _pingPeriod));
    paintGroup(
      canvas,
      pivot: stageCenter,
      scale: 1 + _pingGrowth * eased,
      paint: () => canvas.drawCircle(
        stageCenter,
        _pingRadius,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = _pingWidth
          ..color = fadeColor(colors.primary, _pingFrom * (1 - eased)),
      ),
    );
  }

  final turn = frame.still
      ? 0.0
      : 2 *
            math.pi *
            labOrbit.transform(loopPhase(frame.t, period: _orbitPeriod));
  final dot = stageCenter.translate(0, -_ringRadius);
  paintGroup(
    canvas,
    pivot: stageCenter,
    rotation: turn,
    paint: () {
      canvas.drawCircle(dot, _orbitDotRadius, Paint()..color = colors.primary);
      canvas.drawCircle(
        dot,
        _orbitHaloRadius,
        Paint()..color = fadeColor(colors.primary, _orbitHaloOpacity),
      );
    },
  );

  paintDisc(
    canvas,
    frame,
    center: stageCenter,
    radius: _discRadius,
    glyph: frame.input.peer,
  );
}

void paintComparing(Canvas canvas, StageFrame frame) {
  final colors = frame.colors;

  paintDashedRing(
    canvas,
    frame,
    radius: _ringRadius,
    color: colors.warningRing,
    width: _compareRingWidth,
    pattern: const [3, 7],
    round: true,
    period: _slowTurn,
  );
  canvas.drawCircle(
    stageCenter,
    _compareFillRadius,
    Paint()..color = colors.warningWeak,
  );
  paintDisc(
    canvas,
    frame,
    center: stageCenter,
    radius: _discRadius,
    glyph: frame.input.peer,
    stroke: colors.warningRing,
    strokeWidth: _compareRingWidth,
    ink: colors.warning,
  );
}

void paintWaiting(Canvas canvas, StageFrame frame) {
  final colors = frame.colors;

  if (!frame.still && frame.t >= _waitPingDelay) {
    final cycle = loopPhase(
      frame.t,
      period: _waitPingPeriod,
      delay: _waitPingDelay,
    );
    final eased = labEaseOut.transform((cycle / _waitPingCut).clamp(0.0, 1.0));
    paintGroup(
      canvas,
      pivot: stageCenter,
      scale: 1 + _waitPingGrowth * eased,
      paint: () => canvas.drawCircle(
        stageCenter,
        _waitPingRadius,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = _pingWidth
          ..color = fadeColor(colors.primary, _pingFrom * (1 - eased)),
      ),
    );
  }

  canvas.drawCircle(
    stageCenter,
    _ringRadius,
    Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = _trackWidth
      ..color = colors.stageTrack,
  );

  final start = frame.still
      ? 0.0
      : 2 * math.pi * loopPhase(frame.t, period: _arcPeriod);
  canvas.drawArc(
    Rect.fromCircle(center: stageCenter, radius: _ringRadius),
    start,
    _arcLength / _ringRadius,
    false,
    Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = _trackWidth
      ..strokeCap = StrokeCap.round
      ..color = colors.primary,
  );

  paintDisc(
    canvas,
    frame,
    center: stageCenter,
    radius: _discRadius,
    glyph: frame.input.peer,
    stroke: colors.primary,
    ink: colors.primaryInk,
  );

  final pop = popAt(frame.settledT, delay: _badgeDelay);
  paintGroup(
    canvas,
    pivot: _badgeCenter,
    scale: pop.scale,
    opacity: pop.opacity,
    bounds: Rect.fromCircle(center: _badgeCenter, radius: _badgeRadius + 8),
    paint: () => paintCheckBadge(
      canvas,
      frame,
      center: _badgeCenter,
      radius: _badgeRadius,
    ),
  );
}
