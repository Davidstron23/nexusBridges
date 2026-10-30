import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../diagram/flow_painter.dart' show dashPath;
import '../icons/svg_path.dart' show parseSvgPath;
import 'stage_kit.dart';
import 'timeline.dart';

const double _trackRadius = 56;
const double _trackWidth = 5;
const double _quarterTurn = math.pi / 2;
const double _degree = math.pi / 180;
const double _fullTurn = 2 * math.pi;
const double _slowTurn = 10;
const double _drawDuration = 0.45;
const double _arcDuration = 0.7;
const double _groupRadius = 92;

const double _hourglassScale = 1.3;
const double _sandPeriod = 3.6;
const double _sandCut = 0.76;
const double _sandDrop = 19;
const double _streamStart = 0.03;

const double _freezeDelay = 1;
const double _freezeDuration = 0.6;
const double _shiverDelay = 1;
const double _shiverDuration = 0.45;
const double _glintDelay = 1.45;
const double _glintDuration = 0.8;
const double _glintTravel = 160;
const double _glintAlpha = 0.5;
const double _glintTilt = 22 * _degree;
const double _pausedDiscRadius = 42;
const double _flakeScale = 1.2;
const double _flakeRadius = 16;
const double _flakeDelay = 1.05;
const double _flakeStep = 0.08;
const double _flakeAppear = 0.5;
const double _twinkleDelay = 2;
const double _twinklePeriod = 2.6;
const double _twinkleLow = 0.55;

const double _lostRingRadius = 56;
const double _lostRingDelay = 1.45;
const double _lostRingDuration = 0.6;
const double _lostTurn = 14;
const double _lostDimDelay = 1.35;
const double _lostDimDuration = 0.7;
const double _lostDimLow = 0.3;
const double _lostDiscRadius = 41;
const double _seekDuration = 1.3;
const double _seekStep = 0.12;
const double _questionScale = 1.2;
const double _questionAppear = 0.5;
const double _questionRise = 8;
const double _questionFloat = 3;
const double _questionPeriod = 2.4;

const double _waveDuration = 1.25;
const double _alertDiscRadius = 44;
const double _alertRingOpacity = 0.3;
const double _shakeDelay = 0.75;
const double _shakeDuration = 0.42;

const double _pairedRingEnd = 1.95;
const double _burstInner = 62;
const double _burstOuter = 70;

const Offset _lostCenter = Offset(150, 101);
const Offset _wifiCenter = Offset(179, 72);
const Offset _questionPivot = Offset(0.3, -0.7);
const Offset _failedDot = Offset(150, 96);
const Offset _floppyOrigin = Offset(128, 63);

final Path _hourglassTop = parseSvgPath(
  'M-12-24H12C12-14 2-10 2 0H-2C-2-10-12-14-12-24z',
);
final Path _hourglassBottom = parseSvgPath(
  'M-12 24H12C12 14 2 10 2 0H-2C-2 10-12 14-12 24z',
);
final Path _hourglassOutline = parseSvgPath(
  'M-12-24c0 10 10 14 10 24c0 10-10 14-10 24'
  'M12-24c0 10-10 14-10 24c0 10 10 14 10 24',
);
final Path _hourglassCaps = parseSvgPath('M-15-24h30M-15 24h30');
final Path _snowflake = parseSvgPath(
  'M0-8v16M-6.9-4l13.8 8M-6.9 4l13.8-8'
  'M-2.2-6.6L0-4.4l2.2-2.2M-2.2 6.6L0 4.4l2.2 2.2'
  'M-6.8-1.2l3-.7-.9-3M6.8 1.2l-3 .7.9 3'
  'M-6.8 1.2l3 .7-.9 3M6.8-1.2l-3-.7.9-3',
);
final Path _question = parseSvgPath(
  'M-5.5-6.5a5.8 5.8 0 1 1 8.3 5.2c-1.9 1-2.8 2.2-2.8 4.3',
);
final Path _waveOuter = parseSvgPath('M-24-8a34 34 0 0 1 48 0');
final Path _waveMiddle = parseSvgPath('M-15 1a21 21 0 0 1 30 0');
final Path _waveInner = parseSvgPath('M-7 9.5a9 9 0 0 1 14 0');
final Path _floppyBody = parseSvgPath(
  'M0 4a4 4 0 0 1 4-4h26l10 10v30a4 4 0 0 1-4 4H4a4 4 0 0 1-4-4z',
);
final Path _floppyDetail = parseSvgPath('M9 0v11h18V0M9 44V26h24v18');

Paint _fill(Color color) => Paint()..color = color;

Paint _stroke(
  Color color,
  double width, {
  StrokeCap cap = StrokeCap.butt,
  StrokeJoin join = StrokeJoin.miter,
}) => Paint()
  ..style = PaintingStyle.stroke
  ..strokeWidth = width
  ..strokeCap = cap
  ..strokeJoin = join
  ..color = color;

Path _segment(Offset from, Offset to) => Path()
  ..moveTo(from.dx, from.dy)
  ..lineTo(to.dx, to.dy);

void _paintTrack(Canvas canvas, Color color) =>
    canvas.drawCircle(stageCenter, _trackRadius, _stroke(color, _trackWidth));

void _paintRingWindow(
  Canvas canvas, {
  required double from,
  required double to,
  required Color color,
}) {
  final window = partialPath(
    Path()..addOval(Rect.fromCircle(center: stageCenter, radius: _trackRadius)),
    from,
    to,
  );
  paintGroup(
    canvas,
    pivot: stageCenter,
    rotation: -_quarterTurn,
    paint: () => canvas.drawPath(
      window,
      _stroke(color, _trackWidth, cap: StrokeCap.round),
    ),
  );
}

void _paintRingDrawn(Canvas canvas, double drawn, Color color) {
  final (from, to) = dashWindow(1 - drawn);
  _paintRingWindow(canvas, from: from, to: to, color: color);
}

void _paintRingDepleted(Canvas canvas, double gone, Color color) {
  final (from, to) = dashWindow(-gone);
  _paintRingWindow(canvas, from: from, to: to, color: color);
}

void _paintDrawn(Canvas canvas, Path path, double drawn, Paint paint) {
  final (from, to) = dashWindow(1 - drawn);
  canvas.drawPath(partialPath(path, from, to), paint);
}

void paintBusy(Canvas canvas, StageFrame frame) {
  final colors = frame.colors;

  paintDashedRing(
    canvas,
    frame,
    radius: 60,
    color: colors.stageHint,
    width: 2.2,
    pattern: const [4, 8],
    round: true,
    period: _slowTurn,
  );
  paintDisc(canvas, frame, center: stageCenter, radius: 46);
  _paintHourglass(canvas, frame);
}

void _paintHourglass(Canvas canvas, StageFrame frame) {
  final colors = frame.colors;
  final cycle = frame.still ? 0.0 : loopPhase(frame.t, period: _sandPeriod);
  final turn = frame.still
      ? 0.0
      : keyframes(
              cycle,
              delay: 0,
              duration: 1,
              frames: const [Kf(0, 0), Kf(0.8, 0), Kf(0.94, 180), Kf(1, 180)],
              curve: labHourglass,
            ) *
            _degree;
  final fall = (cycle / _sandCut).clamp(0.0, 1.0);
  final streamOpacity = keyframes(
    cycle,
    delay: 0,
    duration: 1,
    frames: const [
      Kf(0, 0),
      Kf(_streamStart, 0),
      Kf(0.06, 1),
      Kf(0.72, 1),
      Kf(_sandCut, 0),
      Kf(1, 0),
    ],
  );
  final streamShift =
      -30 *
      ((cycle - _streamStart) / (_sandCut - _streamStart)).clamp(0.0, 1.0);

  paintGroup(
    canvas,
    pivot: stageCenter,
    rotation: turn,
    paint: () {
      canvas.save();
      canvas.translate(stageCenter.dx, stageCenter.dy);
      canvas.scale(_hourglassScale);

      canvas.save();
      canvas.clipPath(_hourglassTop);
      canvas.drawRect(
        Rect.fromLTWH(-13, -19 + _sandDrop * fall, 26, 19),
        _fill(colors.primary),
      );
      canvas.restore();

      canvas.save();
      canvas.clipPath(_hourglassBottom);
      canvas.drawRect(
        Rect.fromLTWH(-13, 6 + _sandDrop * (1 - fall), 26, 19),
        _fill(colors.primary),
      );
      canvas.restore();

      if (!frame.still && streamOpacity > 0) {
        canvas.drawPath(
          dashPath(_segment(Offset.zero, const Offset(0, 22)), const [
            2,
            3,
          ], phase: streamShift),
          _stroke(fadeColor(colors.primary, streamOpacity), 1.6),
        );
      }

      canvas.drawPath(
        _hourglassOutline,
        _stroke(colors.textWeak, 2.2, join: StrokeJoin.round),
      );
      canvas.drawPath(
        _hourglassCaps,
        _stroke(colors.textWeak, 3, cap: StrokeCap.round),
      );
      canvas.restore();
    },
  );
}

void paintPaused(Canvas canvas, StageFrame frame) {
  final colors = frame.colors;
  final t = frame.settledT;
  final freeze = phase(
    t,
    delay: _freezeDelay,
    duration: _freezeDuration,
    curve: Curves.ease,
  );

  _paintTrack(canvas, colors.stageTrack);
  _paintRingDrawn(
    canvas,
    phase(t, delay: 0, duration: _arcDuration, curve: labEaseInOut),
    Color.lerp(colors.textWeak, colors.ice, freeze)!,
  );

  final shiver = keyframes(
    t,
    delay: _shiverDelay,
    duration: _shiverDuration,
    frames: const [
      Kf(0, 0),
      Kf(0.2, -2),
      Kf(0.4, 2),
      Kf(0.6, -1.5),
      Kf(0.8, 1),
      Kf(1, 0),
    ],
  );
  paintGroup(
    canvas,
    shift: Offset(shiver, 0),
    paint: () {
      canvas.drawCircle(
        stageCenter,
        _pausedDiscRadius,
        _fill(Color.lerp(colors.stageWeak, colors.iceWeak, freeze)!),
      );
      canvas.drawCircle(
        stageCenter,
        _pausedDiscRadius,
        _stroke(Color.lerp(colors.stageBorder, colors.ice, freeze)!, 1.6),
      );

      for (var i = 0; i < 2; i++) {
        final grow = phase(
          t,
          delay: 0.45 + 0.09 * i,
          duration: 0.4,
          curve: labEaseOut,
        );
        final bar = Rect.fromLTWH(i == 0 ? 136 : 154, 67, 10, 36);
        canvas.save();
        canvas.translate(bar.center.dx, bar.center.dy);
        canvas.scale(1, 0.1 + 0.9 * grow);
        canvas.translate(-bar.center.dx, -bar.center.dy);
        canvas.drawRRect(
          RRect.fromRectAndRadius(bar, const Radius.circular(3.5)),
          _fill(
            fadeColor(Color.lerp(colors.textWeak, colors.ice, freeze)!, grow),
          ),
        );
        canvas.restore();
      }

      final slide = phase(
        t,
        delay: _glintDelay,
        duration: _glintDuration,
        curve: labEaseInOut,
      );
      if (!frame.still && slide > 0 && slide < 1) {
        canvas.save();
        canvas.clipPath(
          Path()..addOval(
            Rect.fromCircle(center: stageCenter, radius: _pausedDiscRadius),
          ),
        );
        canvas.translate(stageCenter.dx, stageCenter.dy);
        canvas.rotate(_glintTilt);
        canvas.translate(-stageCenter.dx, -stageCenter.dy);
        canvas.drawRect(
          Rect.fromLTWH(
            stageCenter.dx - 80 + _glintTravel * slide,
            stageCenter.dy - 70,
            18,
            140,
          ),
          _fill(fadeColor(colors.onPrimary, _glintAlpha)),
        );
        canvas.restore();
      }
    },
  );

  const flakes = [
    (-150.0, 76.0),
    (-90.0, 74.0),
    (-30.0, 76.0),
    (30.0, 76.0),
    (90.0, 74.0),
    (150.0, 76.0),
  ];
  final twinkle = frame.still
      ? 1.0
      : keyframes(
          loopPhase(frame.t, period: _twinklePeriod, delay: _twinkleDelay),
          delay: 0,
          duration: 1,
          frames: const [Kf(0, 1), Kf(0.5, _twinkleLow), Kf(1, 1)],
          curve: Curves.easeInOut,
        );
  for (var i = 0; i < flakes.length; i++) {
    final (angle, distance) = flakes[i];
    final at = Offset(
      stageCenter.dx + distance * math.cos(angle * _degree),
      stageCenter.dy + distance * 0.97 * math.sin(angle * _degree),
    );
    final appear = phase(
      t,
      delay: _flakeDelay + i * _flakeStep,
      duration: _flakeAppear,
      curve: labEaseOut,
    );
    paintGroup(
      canvas,
      pivot: at,
      scale: 0.2 + 0.8 * appear,
      rotation: -60 * _degree * (1 - appear),
      opacity: appear * twinkle,
      bounds: Rect.fromCircle(center: at, radius: _flakeRadius),
      paint: () {
        canvas.save();
        canvas.translate(at.dx, at.dy);
        canvas.scale(_flakeScale);
        canvas.drawPath(
          _snowflake,
          _stroke(
            colors.ice,
            1.7,
            cap: StrokeCap.round,
            join: StrokeJoin.round,
          ),
        );
        canvas.restore();
      },
    );
  }
}

void paintCancelledByPeer(Canvas canvas, StageFrame frame) {
  final colors = frame.colors;
  final t = frame.settledT;

  _paintTrack(canvas, colors.stageTrack);
  _paintRingDrawn(
    canvas,
    phase(t, delay: 0, duration: _arcDuration, curve: labEaseInOut),
    colors.danger,
  );
  canvas.drawCircle(stageCenter, 42, _fill(colors.dangerWeak));

  final pen = _stroke(
    colors.danger,
    6.5,
    cap: StrokeCap.round,
    join: StrokeJoin.round,
  );
  _paintDrawn(
    canvas,
    _segment(stageCenter.translate(-15, -15), stageCenter.translate(15, 15)),
    phase(t, delay: 0.5, duration: _drawDuration, curve: labEaseInOut),
    pen,
  );
  _paintDrawn(
    canvas,
    _segment(stageCenter.translate(15, -15), stageCenter.translate(-15, 15)),
    phase(t, delay: 0.78, duration: _drawDuration, curve: labEaseInOut),
    pen,
  );
}

void paintExpired(Canvas canvas, StageFrame frame) {
  final colors = frame.colors;
  final gone = phase(
    frame.settledT,
    delay: 0.15,
    duration: 1.4,
    curve: labEaseInOut,
  );

  _paintTrack(canvas, colors.stageTrack);
  _paintRingDepleted(canvas, gone, colors.warningRing);
  paintDisc(canvas, frame, center: stageCenter, radius: 42);

  canvas.drawPath(
    Path()
      ..moveTo(stageCenter.dx, stageCenter.dy - 33)
      ..relativeLineTo(0, 5)
      ..moveTo(stageCenter.dx + 33, stageCenter.dy)
      ..relativeLineTo(-5, 0)
      ..moveTo(stageCenter.dx, stageCenter.dy + 33)
      ..relativeLineTo(0, -5)
      ..moveTo(stageCenter.dx - 33, stageCenter.dy)
      ..relativeLineTo(5, 0),
    _stroke(colors.stageHint, 2.4, cap: StrokeCap.round),
  );

  paintGroup(
    canvas,
    pivot: stageCenter,
    rotation: -_fullTurn * (1 - gone),
    paint: () => canvas.drawPath(
      _segment(stageCenter, stageCenter.translate(0, -26)),
      _stroke(colors.text, 4, cap: StrokeCap.round),
    ),
  );
  canvas.drawCircle(stageCenter, 4.5, _fill(colors.text));
}

void paintLost(Canvas canvas, StageFrame frame) {
  final colors = frame.colors;
  final t = frame.settledT;

  paintDashedRing(
    canvas,
    frame,
    center: _lostCenter,
    radius: _lostRingRadius,
    color: colors.stageDashedRing,
    width: 1.6,
    pattern: const [2, 8],
  );

  final ring = phase(
    t,
    delay: _lostRingDelay,
    duration: _lostRingDuration,
    curve: Curves.ease,
  );
  if (ring > 0) {
    paintDashedRing(
      canvas,
      frame,
      center: _lostCenter,
      radius: _lostRingRadius,
      color: fadeColor(colors.warning, ring),
      width: 2.6,
      pattern: const [7, 7],
      round: true,
      period: _lostTurn,
    );
  }

  final dim = phase(
    t,
    delay: _lostDimDelay,
    duration: _lostDimDuration,
    curve: Curves.ease,
  );
  paintGroup(
    canvas,
    opacity: 1 - (1 - _lostDimLow) * dim,
    bounds: Rect.fromCircle(center: _lostCenter, radius: _lostDiscRadius + 6),
    paint: () => paintDisc(
      canvas,
      frame,
      center: _lostCenter,
      radius: _lostDiscRadius,
      glyph: frame.input.peer,
    ),
  );

  if (!frame.still) {
    const radii = [10.0, 19.0, 28.0];
    for (var i = 0; i < radii.length; i++) {
      final opacity = keyframes(
        frame.t,
        delay: _seekStep * i,
        duration: _seekDuration,
        frames: const [
          Kf(0, 0),
          Kf(0.15, 1),
          Kf(0.35, 0.25),
          Kf(0.5, 1),
          Kf(0.7, 0.4),
          Kf(0.85, 1),
          Kf(1, 0),
        ],
        curve: Curves.ease,
      );
      if (opacity <= 0) continue;
      canvas.drawPath(
        Path()..addArc(
          Rect.fromCircle(center: _wifiCenter, radius: radii[i]),
          -88 * _degree,
          86 * _degree,
        ),
        _stroke(
          fadeColor(colors.primary, opacity),
          3,
          cap: StrokeCap.round,
          join: StrokeJoin.round,
        ),
      );
    }
  }

  const questions = [
    (Offset(102, 43), 1.9, 2.4),
    (Offset(198, 43), 2.0, 3.2),
    (Offset(150, 27), 2.15, 2.8),
  ];
  for (final (at, delay, floatDelay) in questions) {
    final appear = phase(
      t,
      delay: delay,
      duration: _questionAppear,
      curve: labEaseOut,
    );
    final floating = !frame.still && frame.t >= floatDelay;
    final lift = floating
        ? _questionFloat *
              keyframes(
                loopPhase(frame.t, period: _questionPeriod, delay: floatDelay),
                delay: 0,
                duration: 1,
                frames: const [Kf(0, 0), Kf(0.5, -1), Kf(1, 0)],
                curve: Curves.easeInOut,
              )
        : _questionRise * (1 - appear);
    paintGroup(
      canvas,
      pivot: at + _questionPivot * _questionScale,
      scale: floating ? 1 : 0.6 + 0.4 * appear,
      shift: Offset(0, lift),
      opacity: floating ? 1 : appear,
      bounds: Rect.fromCenter(center: at, width: 48, height: 64),
      paint: () {
        canvas.save();
        canvas.translate(at.dx, at.dy);
        canvas.scale(_questionScale);
        canvas.drawPath(
          _question,
          _stroke(
            colors.warning,
            3,
            cap: StrokeCap.round,
            join: StrokeJoin.round,
          ),
        );
        canvas.drawCircle(const Offset(0, 9), 1.9, _fill(colors.warning));
        canvas.restore();
      },
    );
  }
}

void paintNetworkChanged(Canvas canvas, StageFrame frame) {
  final colors = frame.colors;
  final t = frame.settledT;

  paintDashedRing(
    canvas,
    frame,
    radius: _trackRadius,
    color: colors.stageDashedRing,
    width: 1.6,
    pattern: const [2, 8],
  );
  paintDisc(canvas, frame, center: stageCenter, radius: _alertDiscRadius);

  canvas.save();
  canvas.translate(stageCenter.dx, stageCenter.dy + 4);
  for (final (wave, delay) in [
    (_waveOuter, 0.35),
    (_waveMiddle, 0.2),
    (_waveInner, 0.05),
  ]) {
    final opacity = keyframes(
      t,
      delay: delay,
      duration: _waveDuration,
      frames: const [
        Kf(0, 0.2),
        Kf(0.3, 1),
        Kf(0.6, 0.35),
        Kf(0.85, 1),
        Kf(1, 1),
      ],
      curve: Curves.ease,
    );
    final settle = keyframes(
      t,
      delay: delay,
      duration: _waveDuration,
      frames: const [Kf(0, 0), Kf(0.85, 0), Kf(1, 1)],
      curve: Curves.ease,
    );
    canvas.drawPath(
      wave,
      _stroke(
        fadeColor(
          Color.lerp(colors.primary, colors.textWeak, settle)!,
          opacity,
        ),
        4.2,
        cap: StrokeCap.round,
      ),
    );
  }
  canvas.restore();

  _paintDrawn(
    canvas,
    _segment(stageCenter.translate(-26, 26), stageCenter.translate(26, -26)),
    phase(t, delay: 1.3, duration: _drawDuration, curve: labEaseInOut),
    _stroke(colors.danger, 4.5, cap: StrokeCap.round),
  );
}

void _paintAlert(Canvas canvas, StageFrame frame, VoidCallback body) {
  final colors = frame.colors;
  canvas.drawCircle(
    stageCenter,
    _trackRadius,
    _stroke(fadeColor(colors.danger, _alertRingOpacity), 2.2),
  );
  final shake = keyframes(
    frame.settledT,
    delay: _shakeDelay,
    duration: _shakeDuration,
    frames: const [
      Kf(0, 0),
      Kf(0.2, -4),
      Kf(0.4, 4),
      Kf(0.6, -3),
      Kf(0.8, 2),
      Kf(1, 0),
    ],
    curve: labShake,
  );
  paintGroup(
    canvas,
    shift: Offset(shake, 0),
    paint: () {
      canvas.drawCircle(
        stageCenter,
        _alertDiscRadius,
        _fill(colors.dangerWeak),
      );
      body();
    },
  );
}

void paintFailed(Canvas canvas, StageFrame frame) {
  final colors = frame.colors;
  final t = frame.settledT;

  _paintAlert(canvas, frame, () {
    _paintDrawn(
      canvas,
      Path()
        ..moveTo(stageCenter.dx, stageCenter.dy - 26)
        ..lineTo(stageCenter.dx + 26, stageCenter.dy + 20)
        ..lineTo(stageCenter.dx - 26, stageCenter.dy + 20)
        ..close(),
      phase(t, delay: 0, duration: _drawDuration, curve: labEaseInOut),
      _stroke(colors.danger, 4.4, join: StrokeJoin.round),
    );
    _paintDrawn(
      canvas,
      _segment(stageCenter.translate(0, -9), stageCenter.translate(0, 3)),
      phase(t, delay: 0.5, duration: _drawDuration, curve: labEaseInOut),
      _stroke(colors.danger, 4.4, cap: StrokeCap.round),
    );
    final pop = popAt(t, delay: 0.85);
    paintGroup(
      canvas,
      pivot: _failedDot,
      scale: pop.scale,
      opacity: pop.opacity,
      bounds: Rect.fromCircle(center: _failedDot, radius: 8),
      paint: () => canvas.drawCircle(_failedDot, 2.8, _fill(colors.danger)),
    );
  });
}

void paintNotSaved(Canvas canvas, StageFrame frame) {
  final colors = frame.colors;

  _paintAlert(canvas, frame, () {
    canvas.save();
    canvas.translate(_floppyOrigin.dx, _floppyOrigin.dy);
    canvas.drawPath(_floppyBody, _stroke(colors.danger, 3.4));
    canvas.drawPath(
      _floppyDetail,
      _stroke(colors.danger, 2.8, join: StrokeJoin.round),
    );
    canvas.restore();

    _paintDrawn(
      canvas,
      _segment(stageCenter.translate(-28, 28), stageCenter.translate(28, -28)),
      phase(
        frame.settledT,
        delay: 0.5,
        duration: _drawDuration,
        curve: labEaseInOut,
      ),
      _stroke(colors.danger, 4.4, cap: StrokeCap.round),
    );
  });
}

void paintPairedRing(Canvas canvas, StageFrame frame) {
  if (frame.still || !(frame.t < _pairedRingEnd)) return;
  final colors = frame.colors;
  final t = frame.t;

  final fade = keyframes(
    t,
    delay: 0,
    duration: _pairedRingEnd,
    frames: const [Kf(0, 1), Kf(0.8, 1), Kf(1, 0)],
    curve: Curves.ease,
  );
  final shrink = keyframes(
    t,
    delay: 0,
    duration: _pairedRingEnd,
    frames: const [Kf(0, 1), Kf(0.8, 1), Kf(1, 0.35)],
    curve: Curves.ease,
  );

  paintGroup(
    canvas,
    pivot: stageCenter,
    scale: shrink,
    opacity: fade,
    bounds: Rect.fromCircle(center: stageCenter, radius: _groupRadius),
    paint: () {
      _paintTrack(canvas, colors.stageTrack);
      _paintRingDrawn(
        canvas,
        phase(t, delay: 0, duration: _arcDuration, curve: labEaseInOut),
        colors.success,
      );

      final rays = Path();
      for (var i = 0; i < 8; i++) {
        final angle = i * math.pi / 4;
        rays
          ..moveTo(
            stageCenter.dx + _burstInner * math.cos(angle),
            stageCenter.dy + _burstInner * math.sin(angle),
          )
          ..lineTo(
            stageCenter.dx + _burstOuter * math.cos(angle),
            stageCenter.dy + _burstOuter * math.sin(angle),
          );
      }
      paintGroup(
        canvas,
        pivot: stageCenter,
        scale: keyframes(
          t,
          delay: 0.85,
          duration: 0.7,
          frames: const [Kf(0, 0.82), Kf(1, 1.22)],
          curve: labEaseOut,
        ),
        opacity: keyframes(
          t,
          delay: 0.85,
          duration: 0.7,
          frames: const [Kf(0, 0), Kf(0.25, 1), Kf(1, 0)],
          curve: labEaseOut,
        ),
        bounds: Rect.fromCircle(center: stageCenter, radius: _groupRadius),
        paint: () => canvas.drawPath(
          rays,
          _stroke(colors.success, 2.6, cap: StrokeCap.round),
        ),
      );

      paintGroup(
        canvas,
        pivot: stageCenter,
        scale: keyframes(
          t,
          delay: 0.55,
          duration: 0.5,
          frames: const [Kf(0, 0.45), Kf(0.6, 1.07), Kf(1, 1)],
          curve: labEaseOut,
        ),
        opacity: keyframes(
          t,
          delay: 0.55,
          duration: 0.5,
          frames: const [Kf(0, 0), Kf(0.6, 1), Kf(1, 1)],
          curve: labEaseOut,
        ),
        bounds: Rect.fromCircle(center: stageCenter, radius: _groupRadius),
        paint: () {
          canvas.drawCircle(stageCenter, 42, _fill(colors.success));
          _paintDrawn(
            canvas,
            Path()
              ..moveTo(stageCenter.dx - 18, stageCenter.dy + 1)
              ..relativeLineTo(12, 11.5)
              ..relativeLineTo(24, -26),
            phase(t, delay: 0.8, duration: 0.34, curve: labEaseOut),
            _stroke(
              colors.onSuccessDisc,
              7,
              cap: StrokeCap.round,
              join: StrokeJoin.round,
            ),
          );
        },
      );
    },
  );
}
