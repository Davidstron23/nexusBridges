import 'dart:math' as math;
import 'dart:ui' show ImageFilter, PathMetric;

import 'package:flutter/material.dart';

import '../diagram/flow_painter.dart' show dashPath;
import '../icons/device_disc.dart' show DeviceGlyph;
import '../icons/file_icon.dart' show fileSheetPath, paintFileIcon;
import '../icons/glyphs.dart';
import '../icons/svg_path.dart' show parseSvgPath;
import 'stage_kit.dart';
import 'timeline.dart';

const double _railWidth = 232;
const double _railHeight = 64;
const double _railStroke = 1.6;
const double _glyphBox = 24;
const double _laneFade = 0.45;
const double _idleIconOpacity = 0.75;
const double _dimIconOpacity = 0.35;
const double _iconFade = 0.45;
const double _swayPeriod = 3.4;
const double _swayReach = 5;
const double _hoverReach = 26;
const double _pickReach = 82;
const double _hoverTravel = 0.62;
const double _pickTravel = 0.85;
const double _knobRadius = 36;
const double _knobShadowRadius = 38;
const double _knobShadowDrop = 3;
const double _knobShadowOpacity = 0.5;
const double _knobRingWidth = 2;
const double _fillDelay = 0.35;
const double _fillDuration = 0.5;
const double _deviceDelay = 0.3;
const double _deviceDuration = 0.35;
const double _deviceBlur = 3;
const double _markDelay = 0.42;
const double _markFade = 0.4;
const double _markGrow = 0.5;
const double _markFrom = 0.7;
const double _markScale = 1.55;
const double _markStroke = 1.5;
const double _badgeDelay = 0.1;
const double _badgeRadius = 10;
const double _badgeOut = 0.25;
const double _badgeOutScale = 0.8;
const double _burstDelay = 0.85;
const double _burstDuration = 0.8;
const double _burstOpacity = 0.7;
const double _burstGrowth = 0.55;
const double _burstWidth = 2;
const double _sideIconScale = 1.25;
const double _sideIconStroke = 1.6;
const double _deviceStroke = 1.5;

const double _networkRing = 56;
const double _networkRingWidth = 2.2;
const double _networkTurn = 10;
const double _networkDisc = 44;
const double _networkGlyphScale = 2.1;
const double _networkGlyphStroke = 1.5;
const double _networkEnter = 0.45;
const double _networkEnterFrom = 0.9;
const double _networkGlyphDelay = 0.1;

const double _exitDiscRadius = 30;
const double _exitLineWidth = 2;
const double _exitFlowWidth = 2.4;
const double _exitFlowSpeed = 18;
const double _exitCycle = 5;
const double _exitLag = 0.07;
const double _fileCycle = 2.6;
const double _fileReach = 62;
const double _fileFadeIn = 0.12;
const double _fileFadeOut = 0.88;
const double _fileScale = 0.85;
const double _fileOutline = 2.4;
const double _fileBoxWidth = 32;
const double _fileBoxHeight = 38;
const double _cometFadeIn = 0.03;
const double _cometFadeOut = 0.04;

const Offset _leftDisc = Offset(58, 85);
const Offset _rightDisc = Offset(242, 85);
const Offset _mineGlyph = Offset(68, 85);
const Offset _otherGlyph = Offset(232, 85);
const Offset _knobBadge = Offset(176, 111);
const List<double> _exitPattern = [3, 6];
const List<double> _cometRadii = [2.6, 2, 1.5];
const List<double> _cometOpacities = [1, 0.5, 0.25];

final Path _swayLeft = parseSvgPath('M66 53H150V117H66a32 32 0 0 1 0-64z');
final Path _swayRight = parseSvgPath('M150 53H234a32 32 0 0 1 0 64H150z');
final Path _exitLine = parseSvgPath('M94 85H206');

final class _Comet {
  _Comet({
    required String path,
    required this.begin,
    required this.end,
    this.hub = false,
  }) : _metric = parseSvgPath(path).computeMetrics().first;

  final double begin;
  final double end;
  final bool hub;
  final PathMetric _metric;

  double progress(double cycle) {
    final from = begin / _exitCycle;
    final to = end / _exitCycle;
    if (cycle <= from) return 0;
    if (cycle >= to) return 1;
    return (cycle - from) / (to - from);
  }

  double opacity(double cycle) {
    final from = begin / _exitCycle;
    final to = end / _exitCycle;
    if (cycle < from || cycle >= to) return 0;
    if (cycle < from + _cometFadeIn) return (cycle - from) / _cometFadeIn;
    if (cycle < to - _cometFadeOut) return 1;
    return (to - cycle) / _cometFadeOut;
  }

  Offset at(double progress) {
    final tangent = _metric.getTangentForOffset(
      _metric.length * progress.clamp(0.0, 1.0),
    );
    return tangent?.position ?? Offset.zero;
  }
}

final List<_Comet> _topComets = [
  _Comet(path: 'M92 82C124 39 176 39 208 82', begin: 0, end: 1.4),
  _Comet(
    path: 'M92 88C124 131 176 131 208 88',
    begin: 1.7,
    end: 3.1,
    hub: true,
  ),
  _Comet(
    path: 'M92 83C116 51 134 51 150 85C166 119 184 119 208 87',
    begin: 3.4,
    end: 4.8,
  ),
  _Comet(
    path: 'M92 87C116 119 134 119 150 85C166 51 184 51 208 83',
    begin: 3.4,
    end: 4.8,
    hub: true,
  ),
];

double _mix(double from, double to, double progress) =>
    from + (to - from) * progress;

double _side(Own own) => own == Own.mine ? -1 : 1;

void _paintGlyphAt(
  Canvas canvas,
  Glyph glyph,
  Offset center,
  Color color, {
  required double scale,
  required double width,
}) {
  final side = _glyphBox * scale;
  paintGlyph(
    canvas,
    glyph,
    Rect.fromCenter(center: center, width: side, height: side),
    color,
    strokeScale: width / glyph.strokeWidth,
  );
}

double _hoverValue(
  StageFrame frame,
  double at,
  double Function(Own? hovered) valueOf,
) {
  final to = valueOf(frame.input.hovered);
  final changedAt = frame.changes.hoveredAt;
  if (changedAt == null) return to;
  final from = valueOf(frame.changes.hoveredFrom);
  return _mix(
    from,
    to,
    phase(at, delay: changedAt, duration: _laneFade, curve: Curves.ease),
  );
}

double _sincePick(
  StageFrame frame, {
  required double delay,
  required double duration,
  Curve curve = Curves.linear,
}) {
  if (frame.input.picked == null) return 0;
  final at = frame.changes.pickedAt;
  if (at == null) return 1;
  return phase(
    frame.settledT,
    delay: at + delay,
    duration: duration,
    curve: curve,
  );
}

double _sway(double t) {
  final cycle = loopPhase(t, period: _swayPeriod);
  final half = cycle < 0.5 ? cycle * 2 : (1 - cycle) * 2;
  return -_swayReach + 2 * _swayReach * Curves.easeInOut.transform(half);
}

double mineKnobX(StageFrame frame) {
  final picked = frame.input.picked;
  final hovered = frame.input.hovered;
  final target = picked != null
      ? _side(picked) * _pickReach
      : hovered != null
      ? _side(hovered) * _hoverReach
      : (frame.still ? 0.0 : _sway(frame.t));
  if (frame.still) return target;
  final at = picked != null ? frame.changes.pickedAt : frame.changes.hoveredAt;
  final from = frame.changes.knobFrom;
  if (at == null || from == null) return target;
  return _mix(
    from,
    target,
    phase(
      frame.t,
      delay: at,
      duration: picked != null ? _pickTravel : _hoverTravel,
      curve: labEaseInOut,
    ),
  );
}

double _iconOpacity(StageFrame frame, Own side) {
  double hoverBased(double at) => _hoverValue(
    frame,
    at,
    (hovered) => hovered == null
        ? _idleIconOpacity
        : (hovered == side ? 1.0 : _dimIconOpacity),
  );

  final now = frame.settledT;
  if (frame.input.picked != side) return hoverBased(now);
  final pickedAt = frame.changes.pickedAt;
  if (pickedAt == null) return 0;
  return _mix(
    hoverBased(pickedAt),
    0,
    phase(now, delay: pickedAt, duration: _iconFade, curve: Curves.ease),
  );
}

void _paintDeviceInKnob(Canvas canvas, StageFrame frame) {
  final colors = frame.colors;
  final fade = _sincePick(
    frame,
    delay: _deviceDelay,
    duration: _deviceDuration,
    curve: Curves.ease,
  );
  if (!(fade < 1)) return;
  final side = _glyphBox * _knobRadius / 22;
  void paint() => paintGlyph(
    canvas,
    glyphOfDevice(frame.input.peer),
    Rect.fromCenter(center: stageCenter, width: side, height: side),
    colors.text,
    strokeScale: _deviceStroke / 1.6,
  );

  if (!(fade > 0)) {
    paint();
    return;
  }
  final blur = _deviceBlur * fade;
  canvas.saveLayer(
    Rect.fromCircle(center: stageCenter, radius: _knobRadius + 2 * _deviceBlur),
    Paint()
      ..color = colors.text.withValues(alpha: 1 - fade)
      ..imageFilter = ImageFilter.blur(sigmaX: blur, sigmaY: blur),
  );
  paint();
  canvas.restore();
}

void paintMineSwitch(Canvas canvas, StageFrame frame) {
  final colors = frame.colors;
  final picked = frame.input.picked;
  final now = frame.settledT;

  final rail = RRect.fromRectAndRadius(
    Rect.fromLTWH(
      stageCenter.dx - _railWidth / 2,
      stageCenter.dy - _railHeight / 2,
      _railWidth,
      _railHeight,
    ),
    const Radius.circular(_railHeight / 2),
  );
  canvas.drawRRect(rail, Paint()..color = colors.stageWeak);
  canvas.drawRRect(
    rail,
    Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = _railStroke
      ..color = colors.stageBorder,
  );

  final mineLane = _hoverValue(
    frame,
    now,
    (hovered) => hovered == Own.mine ? 1.0 : 0.0,
  );
  final otherLane = _hoverValue(
    frame,
    now,
    (hovered) => hovered == Own.other ? 1.0 : 0.0,
  );
  canvas.drawPath(
    _swayLeft,
    Paint()..color = fadeColor(colors.primaryWeak, mineLane),
  );
  canvas.drawPath(
    _swayRight,
    Paint()..color = fadeColor(colors.stageTrack, otherLane),
  );

  paintGroup(
    canvas,
    opacity: _iconOpacity(frame, Own.mine),
    paint: () => _paintGlyphAt(
      canvas,
      Glyphs.mine,
      _mineGlyph,
      colors.primaryInk,
      scale: _sideIconScale,
      width: _sideIconStroke,
    ),
  );
  paintGroup(
    canvas,
    opacity: _iconOpacity(frame, Own.other),
    paint: () => _paintGlyphAt(
      canvas,
      Glyphs.someoneElse,
      _otherGlyph,
      colors.textWeak,
      scale: _sideIconScale,
      width: _sideIconStroke,
    ),
  );

  final tone = picked == Own.other ? colors.textWeak : colors.primary;
  canvas.save();
  canvas.translate(mineKnobX(frame), 0);

  final pickedAt = frame.changes.pickedAt;
  if (picked != null && !frame.still && pickedAt != null) {
    final spread = phase(
      now,
      delay: pickedAt + _burstDelay,
      duration: _burstDuration,
      curve: labEaseOut,
    );
    final opacity = _burstOpacity * (1 - spread);
    if (opacity > 0) {
      paintGroup(
        canvas,
        pivot: stageCenter,
        scale: 1 + _burstGrowth * spread,
        paint: () => canvas.drawCircle(
          stageCenter,
          _knobShadowRadius,
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = _burstWidth
            ..color = fadeColor(tone, opacity),
        ),
      );
    }
  }

  canvas.drawCircle(
    stageCenter.translate(0, _knobShadowDrop),
    _knobShadowRadius,
    Paint()..color = fadeColor(colors.nodeShadow, _knobShadowOpacity),
  );

  final bounds = Rect.fromCircle(center: stageCenter, radius: _knobRadius);
  canvas.drawCircle(
    stageCenter,
    _knobRadius,
    Paint()
      ..shader = LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: [colors.nodeTop, colors.nodeBottom],
      ).createShader(bounds),
  );
  final fill = _sincePick(
    frame,
    delay: _fillDelay,
    duration: _fillDuration,
    curve: Curves.ease,
  );
  if (fill > 0) {
    canvas.drawCircle(
      stageCenter,
      _knobRadius,
      Paint()..color = fadeColor(tone, fill),
    );
  }
  canvas.drawCircle(
    stageCenter,
    _knobRadius,
    Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = _knobRingWidth
      ..color = Color.lerp(colors.success, tone, fill)!,
  );

  _paintDeviceInKnob(canvas, frame);

  if (picked != null) {
    final fade = _sincePick(
      frame,
      delay: _markDelay,
      duration: _markFade,
      curve: Curves.ease,
    );
    final grow = _sincePick(
      frame,
      delay: _markDelay,
      duration: _markGrow,
      curve: labEaseOut,
    );
    paintGroup(
      canvas,
      pivot: stageCenter,
      scale: _mix(_markFrom, 1, grow),
      opacity: fade,
      paint: () => _paintGlyphAt(
        canvas,
        picked == Own.mine ? Glyphs.mine : Glyphs.someoneElse,
        stageCenter,
        picked == Own.mine ? colors.onPrimary : colors.card,
        scale: _markScale,
        width: _markStroke,
      ),
    );
  }

  final pop = popAt(now, delay: _badgeDelay);
  final out = _sincePick(
    frame,
    delay: 0,
    duration: _badgeOut,
    curve: Curves.ease,
  );
  paintGroup(
    canvas,
    pivot: _knobBadge,
    scale: _mix(pop.scale, _badgeOutScale, out),
    opacity: _mix(pop.opacity, 0, out),
    bounds: Rect.fromCircle(center: _knobBadge, radius: _badgeRadius + 8),
    paint: () => paintCheckBadge(
      canvas,
      frame,
      center: _knobBadge,
      radius: _badgeRadius,
    ),
  );

  canvas.restore();
}

void paintNetwork(Canvas canvas, StageFrame frame) {
  final colors = frame.colors;

  if (!frame.input.trusted) {
    paintDashedRing(
      canvas,
      frame,
      radius: _networkRing,
      color: colors.stageHint,
      width: _networkRingWidth,
      pattern: const [4, 8],
      round: true,
      period: _networkTurn,
    );
    paintDisc(canvas, frame, center: stageCenter, radius: _networkDisc);
    _paintGlyphAt(
      canvas,
      Glyphs.networkShield,
      stageCenter,
      colors.textWeak,
      scale: _networkGlyphScale,
      width: _networkGlyphStroke,
    );
    return;
  }

  final since = frame.still
      ? frame.settledT
      : frame.t - (frame.changes.trustedAt ?? 0);

  canvas.drawCircle(
    stageCenter,
    _networkRing,
    Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = _networkRingWidth
      ..color = colors.success,
  );

  final enter = phase(
    since,
    delay: 0,
    duration: _networkEnter,
    curve: labEaseOut,
  );
  paintGroup(
    canvas,
    pivot: stageCenter,
    scale: _mix(_networkEnterFrom, 1, enter),
    opacity: enter,
    bounds: Rect.fromCircle(center: stageCenter, radius: _networkDisc + 4),
    paint: () => canvas.drawCircle(
      stageCenter,
      _networkDisc,
      Paint()..color = colors.success,
    ),
  );

  final pop = popAt(since, delay: _networkGlyphDelay);
  paintGroup(
    canvas,
    pivot: stageCenter,
    scale: pop.scale,
    opacity: pop.opacity,
    bounds: Rect.fromCircle(center: stageCenter, radius: _networkDisc),
    paint: () => _paintGlyphAt(
      canvas,
      Glyphs.networkShield,
      stageCenter,
      colors.onSuccessDisc,
      scale: _networkGlyphScale,
      width: _networkGlyphStroke,
    ),
  );
}

void _paintTravelFile(
  Canvas canvas,
  StageFrame frame,
  ExitTransfer transfer, {
  required double x,
  required double opacity,
}) {
  final origin = stageCenter.translate(-13, -16);
  paintGroup(
    canvas,
    shift: Offset(x, 0),
    opacity: opacity,
    bounds: Rect.fromLTRB(
      origin.dx - _fileReach - 8,
      origin.dy - 8,
      origin.dx + _fileBoxWidth + _fileReach + 8,
      origin.dy + _fileBoxHeight + 8,
    ),
    paint: () {
      canvas.save();
      canvas.translate(origin.dx, origin.dy);
      canvas.scale(_fileScale);
      canvas.drawPath(
        fileSheetPath,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = _fileOutline
          ..color = frame.colors.card,
      );
      canvas.restore();
      paintFileIcon(
        canvas,
        Rect.fromLTWH(
          origin.dx,
          origin.dy,
          _fileBoxWidth * _fileScale,
          _fileBoxHeight * _fileScale,
        ),
        transfer.kind,
      );
    },
  );
}

void paintExit(Canvas canvas, StageFrame frame) {
  final colors = frame.colors;
  final transfer = frame.input.transfer;

  paintDisc(
    canvas,
    frame,
    center: _leftDisc,
    radius: _exitDiscRadius,
    glyph: DeviceGlyph.pc,
    stroke: colors.primary,
    ink: colors.primaryInk,
  );
  paintDisc(
    canvas,
    frame,
    center: _rightDisc,
    radius: _exitDiscRadius,
    glyph: transfer?.peer ?? DeviceGlyph.pc,
  );

  canvas.drawPath(
    dashPath(_exitLine, _exitPattern),
    Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = _exitLineWidth
      ..strokeCap = StrokeCap.round
      ..color = colors.stageBorder,
  );
  if (transfer == null) return;

  final direction = transfer.towardsHub ? -1.0 : 1.0;
  final shift = frame.still ? 0.0 : -_exitFlowSpeed * frame.t * direction;
  canvas.drawPath(
    dashPath(_exitLine, _exitPattern, phase: shift),
    Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = _exitFlowWidth
      ..strokeCap = StrokeCap.round
      ..color = colors.primary,
  );

  if (frame.still) {
    _paintTravelFile(canvas, frame, transfer, x: 0, opacity: 1);
    return;
  }

  final cycle = loopPhase(frame.t, period: _exitCycle);
  for (final comet in _topComets) {
    final visible = comet.opacity(cycle);
    if (!(visible > 0)) continue;
    final color = comet.hub ? colors.hubTop : colors.primary;
    for (var i = 0; i < _cometRadii.length; i++) {
      final lagged = loopPhase(
        frame.t + _exitCycle - i * _exitLag,
        period: _exitCycle,
      );
      var progress = comet.progress(lagged);
      if (transfer.towardsHub) progress = 1 - progress;
      canvas.drawCircle(
        comet.at(progress),
        _cometRadii[i],
        Paint()..color = fadeColor(color, _cometOpacities[i] * visible),
      );
    }
  }

  final travel = loopPhase(frame.t, period: _fileCycle);
  final eased = labEaseInOut.transform(travel);
  final fade = travel < _fileFadeIn
      ? labEaseInOut.transform(travel / _fileFadeIn)
      : travel < _fileFadeOut
      ? 1.0
      : 1 -
            labEaseInOut.transform(
              (travel - _fileFadeOut) / (1 - _fileFadeOut),
            );
  _paintTravelFile(
    canvas,
    frame,
    transfer,
    x: direction * math.max(-_fileReach, -_fileReach + 2 * _fileReach * eased),
    opacity: fade,
  );
}
