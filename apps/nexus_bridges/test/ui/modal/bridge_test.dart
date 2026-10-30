import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nexus_bridges/src/ui/icons/device_disc.dart';
import 'package:nexus_bridges/src/ui/icons/glyphs.dart';
import 'package:nexus_bridges/src/ui/modal/bridge.dart';
import 'package:nexus_bridges/src/ui/modal/stage_kit.dart';
import 'package:nexus_bridges/src/ui/modal/stage_outcomes.dart';
import 'package:nexus_bridges/src/ui/modal/timeline.dart';
import 'package:nexus_bridges/src/ui/theme/tokens.dart';

const double _deg = math.pi / 180;
const double _cycle = 4.4;
const Offset _leftDisc = Offset(62, 85);
const Offset _rightDisc = Offset(238, 85);
const Offset _joint = Offset(150, 93);
const Offset _badge = Offset(262, 109);
const Offset _leftDeckPivot = Offset(96, 93);
const Offset _rightDeckPivot = Offset(204, 93);
const Offset _leftCablePivot = Offset(104, 55);
const Offset _rightCablePivot = Offset(196, 55);
const Offset _deckEnd = Offset(150, 93);
const Offset _cableEnd = Offset(150, 86);
const List<double> _particleRadii = [1.6, 2.1, 2.6, 1.6, 2.1];

const List<(double, double, double)> _hangerTops = [
  (116, 69.1, 3.02),
  (184, 69.1, 3.02),
  (128, 78.9, 3.09),
  (172, 78.9, 3.09),
];

final double _cableLength = _measure(
  Path()
    ..moveTo(104, 55)
    ..quadraticBezierTo(127, 86, 150, 86),
);

double _measure(Path path) =>
    path.computeMetrics().fold<double>(0, (sum, metric) => sum + metric.length);

const List<double> _wild = [
  -5,
  0,
  0.1,
  0.5,
  1.0,
  1.32,
  1.45,
  1.6,
  1.75,
  1.9,
  2.2,
  2.55,
  3.1,
  3.3,
  3.6,
  3.9,
  4.4,
  60,
  1e9,
  1e300,
  double.infinity,
  double.negativeInfinity,
  double.nan,
];

const List<(String, NbColors)> _themes = [
  ('light', NbColors.light),
  ('dark', NbColors.dark),
];

const Map<BridgeMode, StageScene> _scenes = {
  BridgeMode.paired: StageScene.paired,
  BridgeMode.rejected: StageScene.rejected,
  BridgeMode.loop: StageScene.unpairLoop,
  BridgeMode.breaking: StageScene.unpairBreak,
};

const Map<BridgeMode, StageSceneFn> _painters = {
  BridgeMode.paired: paintPaired,
  BridgeMode.rejected: paintRejected,
  BridgeMode.loop: paintUnpairLoop,
  BridgeMode.breaking: paintUnpairBreak,
};

const Set<Symbol> _allowedCalls = {
  #save,
  #saveLayer,
  #restore,
  #translate,
  #scale,
  #rotate,
  #clipPath,
  #drawCircle,
  #drawPath,
  #drawRect,
  #drawRRect,
  #drawLine,
};

typedef _Frames = List<(double, double, Curve)>;

const _Frames _fallDeck = [
  (0.0, 0.0, labEaseIn),
  (0.55, -56.0, labEaseOut),
  (0.75, -44.0, Curves.ease),
  (1.0, -50.0, Curves.ease),
];

const _Frames _fallCable = [
  (0.0, 0.0, labEaseIn),
  (0.55, -44.0, labEaseOut),
  (0.75, -34.0, Curves.ease),
  (1.0, -38.0, Curves.ease),
];

const _Frames _shake = [
  (0.0, 0.0, labShake),
  (0.2, -4.0, labShake),
  (0.4, 4.0, labShake),
  (0.6, -3.0, labShake),
  (0.8, 2.0, labShake),
  (1.0, 0.0, labShake),
];

_Frames _swing(double peak, double hold) => [
  (0.0, 0.0, labEaseIn),
  (0.42, 0.0, labEaseIn),
  (0.54, peak, labEaseOut),
  (0.6, hold, labEaseInOut),
  (0.8, hold, labEaseInOut),
  (0.96, 0.0, Curves.ease),
  (1.0, 0.0, Curves.ease),
];

const _Frames _loopRed = [
  (0.0, 0.0, Curves.ease),
  (0.4, 0.0, Curves.ease),
  (0.48, 1.0, Curves.ease),
  (0.86, 1.0, Curves.ease),
  (0.96, 0.0, Curves.ease),
  (1.0, 0.0, Curves.ease),
];

const _Frames _hangerLoop = [
  (0.0, 1.0, Curves.ease),
  (0.42, 1.0, Curves.ease),
  (0.52, 0.0, Curves.ease),
  (0.88, 0.0, Curves.ease),
  (0.97, 1.0, Curves.ease),
  (1.0, 1.0, Curves.ease),
];

const _Frames _crackOpacity = [
  (0.0, 0.0, Curves.ease),
  (0.45, 0.0, Curves.ease),
  (0.49, 1.0, Curves.ease),
  (0.6, 0.0, Curves.ease),
  (1.0, 0.0, Curves.ease),
];

const _Frames _crackScale = [
  (0.0, 0.6, Curves.ease),
  (0.45, 0.6, Curves.ease),
  (0.6, 1.35, Curves.ease),
  (1.0, 1.35, Curves.ease),
];

const _Frames _lanesLoop = [
  (0.0, 1.0, Curves.ease),
  (0.38, 1.0, Curves.ease),
  (0.44, 0.0, Curves.ease),
  (0.94, 0.0, Curves.ease),
  (1.0, 1.0, Curves.ease),
];

const _Frames _popScale = [
  (0.0, 0.4, labEaseOut),
  (0.6, 1.12, labEaseOut),
  (1.0, 1.0, labEaseOut),
];

double _clock(double t, double delay, double duration) =>
    ((t - delay) / duration).clamp(0.0, 1.0);

double _ph(
  double t,
  double delay,
  double duration, [
  Curve curve = Curves.linear,
]) {
  final p = _clock(t, delay, duration);
  if (p <= 0) return 0;
  if (p >= 1) return 1;
  return curve.transform(p);
}

double? _fly(double t, double delay, double duration) {
  final raw = (t - delay) / duration;
  if (!(raw > 0 && raw < 1)) return null;
  return labEaseOut.transform(raw);
}

double _kf(double p, _Frames frames) {
  if (p <= frames.first.$1) return frames.first.$2;
  for (var i = 0; i < frames.length - 1; i++) {
    final (from, fromValue, curve) = frames[i];
    final (to, toValue, _) = frames[i + 1];
    if (p < to) {
      return fromValue +
          (toValue - fromValue) * curve.transform((p - from) / (to - from));
    }
  }
  return frames.last.$2;
}

double _cycleOf(double t) => (t % _cycle) / _cycle;

double _drawn(double eased) => (1 - 1.02 * (1 - eased)).clamp(0.0, 1.0);

({double scale, double opacity}) _pop(double t, double delay) {
  final p = _clock(t, delay, 0.45);
  return (scale: _kf(p, _popScale), opacity: labEaseOut.transform(p));
}

double _dotOpacity(double phase) {
  if (phase < 0.15) return phase / 0.15;
  if (phase > 0.85) return (1 - phase) / 0.15;
  return 1;
}

typedef _Dot = ({Offset at, double alpha, bool light});

List<_Dot> _labDots(double t, double shown) => [
  for (final delay in const [0.0, -1.0])
    (
      at: Offset(104 + 92 * (((t - delay) % 2) / 2), 93),
      alpha: _dotOpacity(((t - delay) % 2) / 2) * shown,
      light: false,
    ),
  for (final delay in const [-0.5, -1.5])
    (
      at: Offset(196 - 92 * (((t - delay) % 2) / 2), 93),
      alpha: 0.9 * _dotOpacity(((t - delay) % 2) / 2) * shown,
      light: true,
    ),
];

List<Offset> _labParticles(Offset at, double spread, double progress) => [
  for (var i = 0; i < 5; i++)
    at +
        Offset(
              math.cos(i / 5 * 2 * math.pi + 0.4) * spread,
              math.sin(i / 5 * 2 * math.pi + 0.4) * spread * 0.7 + 7,
            ) *
            progress,
];

Offset _turn(Offset point, Offset pivot, double degrees) {
  final a = degrees * _deg;
  final d = point - pivot;
  return pivot +
      Offset(
        d.dx * math.cos(a) - d.dy * math.sin(a),
        d.dx * math.sin(a) + d.dy * math.cos(a),
      );
}

Offset _scaled(Offset point, Offset pivot, double scale) =>
    pivot + (point - pivot) * scale;

final class _Draw {
  _Draw(this.name, this.args, this.matrix, this.alpha, this.clips, this.layers);

  final Symbol name;
  final List<dynamic> args;
  final Matrix4 matrix;
  final double alpha;
  final int clips;
  final List<Rect> layers;

  Paint get paint => args.last as Paint;

  bool get stroked => paint.style == PaintingStyle.stroke;

  Offset map(Offset point) => MatrixUtils.transformPoint(matrix, point);

  double get scale => math.sqrt(
    math.pow(matrix.entry(0, 0), 2) + math.pow(matrix.entry(1, 0), 2),
  );

  double get angle => math.atan2(matrix.entry(1, 0), matrix.entry(0, 0));

  double get visibleAlpha => paint.color.a * alpha;

  Path get path => args[0] as Path;

  List<ui.PathMetric> get metrics => path.computeMetrics().toList();

  double get localLength =>
      metrics.fold<double>(0, (sum, metric) => sum + metric.length);

  Offset get localStart => metrics.first.getTangentForOffset(0)!.position;

  Offset get start => map(localStart);

  Offset get end {
    final last = metrics.last;
    return map(last.getTangentForOffset(last.length)!.position);
  }

  Offset get localCenter => args[0] as Offset;

  Offset get center => map(localCenter);

  double get baseRadius => args[1] as double;

  double get radius => baseRadius * scale;

  Offset get from => map(args[0] as Offset);

  Offset get to => map(args[1] as Offset);

  Rect get localBounds {
    if (name == #drawCircle) {
      return Rect.fromCircle(center: localCenter, radius: baseRadius);
    }
    if (name == #drawPath) return path.getBounds();
    if (name == #drawRect) return args[0] as Rect;
    if (name == #drawRRect) return (args[0] as RRect).outerRect;
    if (name == #drawLine) {
      return Rect.fromPoints(args[0] as Offset, args[1] as Offset);
    }
    return Rect.zero;
  }

  Rect get stageBounds => _mapRect(
    matrix,
    localBounds.inflate(stroked ? paint.strokeWidth / 2 : 0),
  );
}

Rect _mapRect(Matrix4 matrix, Rect rect) {
  final corners = [
    MatrixUtils.transformPoint(matrix, rect.topLeft),
    MatrixUtils.transformPoint(matrix, rect.topRight),
    MatrixUtils.transformPoint(matrix, rect.bottomLeft),
    MatrixUtils.transformPoint(matrix, rect.bottomRight),
  ];
  return Rect.fromLTRB(
    corners.map((c) => c.dx).reduce(math.min),
    corners.map((c) => c.dy).reduce(math.min),
    corners.map((c) => c.dx).reduce(math.max),
    corners.map((c) => c.dy).reduce(math.max),
  );
}

double _alphaOfLayer(Paint paint) {
  final filter = paint.colorFilter;
  if (filter == null) return paint.color.a;
  final match = RegExp(r'\[([^\]]*)\]').firstMatch(filter.toString());
  if (match == null) return paint.color.a;
  final values = match
      .group(1)!
      .split(',')
      .map((value) => double.parse(value.trim()))
      .toList();
  return values[18] * paint.color.a;
}

final class _StageCanvas extends TestRecordingCanvas {
  final List<Matrix4> _matrices = [Matrix4.identity()];
  final List<double> _alphas = [1];
  final List<int> _clips = [0];
  final List<List<Rect>> _layers = [[]];
  final List<_Draw> draws = [];
  int clipsOutsideSave = 0;

  Matrix4 get _top => _matrices.last;

  void _push({double alpha = 1, Rect? layer}) {
    _matrices.add(_top.clone());
    _alphas.add(_alphas.last * alpha);
    _clips.add(_clips.last);
    _layers.add([..._layers.last, ?layer]);
  }

  @override
  void save() {
    super.save();
    _push();
  }

  @override
  void saveLayer(Rect? bounds, Paint paint) {
    super.saveLayer(bounds, paint);
    final layer = bounds == null ? null : _mapRect(_top, bounds);
    _push(alpha: _alphaOfLayer(paint), layer: layer);
  }

  @override
  void restore() {
    super.restore();
    _matrices.removeLast();
    _alphas.removeLast();
    _clips.removeLast();
    _layers.removeLast();
  }

  @override
  void translate(double dx, double dy) {
    super.noSuchMethod(Invocation.method(#translate, [dx, dy]));
    _top.multiply(Matrix4.translationValues(dx, dy, 0));
  }

  @override
  void scale(double sx, [double? sy]) {
    super.noSuchMethod(Invocation.method(#scale, [sx, sy]));
    _top.multiply(Matrix4.diagonal3Values(sx, sy ?? sx, 1));
  }

  @override
  void rotate(double radians) {
    super.noSuchMethod(Invocation.method(#rotate, [radians]));
    _top.multiply(Matrix4.rotationZ(radians));
  }

  @override
  void clipPath(Path path, {bool doAntiAlias = true}) {
    super.noSuchMethod(
      Invocation.method(#clipPath, [path], {#doAntiAlias: doAntiAlias}),
    );
    if (getSaveCount() == 0) clipsOutsideSave++;
    _clips[_clips.length - 1] = _clips.last + 1;
  }

  void _add(Symbol name, List<dynamic> args) => draws.add(
    _Draw(
      name,
      args,
      _top.clone(),
      _alphas.last,
      _clips.last,
      List.of(_layers.last),
    ),
  );

  @override
  void drawCircle(Offset c, double radius, Paint paint) {
    super.drawCircle(c, radius, paint);
    _add(#drawCircle, [c, radius, Paint.from(paint)]);
  }

  @override
  void drawPath(Path path, Paint paint) {
    super.noSuchMethod(Invocation.method(#drawPath, [path, paint]));
    _add(#drawPath, [path, Paint.from(paint)]);
  }

  @override
  void drawRect(Rect rect, Paint paint) {
    super.drawRect(rect, paint);
    _add(#drawRect, [rect, Paint.from(paint)]);
  }

  @override
  void drawRRect(RRect rrect, Paint paint) {
    super.drawRRect(rrect, paint);
    _add(#drawRRect, [rrect, Paint.from(paint)]);
  }

  @override
  void drawLine(Offset p1, Offset p2, Paint paint) {
    super.drawLine(p1, p2, paint);
    _add(#drawLine, [p1, p2, Paint.from(paint)]);
  }

  List<Symbol> get calls => [
    for (final call in invocations) call.invocation.memberName,
  ];

  List<_Draw> get paths => [
    for (final draw in draws)
      if (draw.name == #drawPath) draw,
  ];
}

StageFrame _frame(
  NbColors colors, {
  double t = 0,
  bool still = false,
  DeviceGlyph peer = DeviceGlyph.phone,
}) => StageFrame(
  t: t,
  still: still,
  colors: colors,
  input: StageInput(peer: peer),
);

_StageCanvas _run(
  StageSceneFn scene,
  NbColors colors,
  double t, {
  bool still = false,
  DeviceGlyph peer = DeviceGlyph.phone,
}) {
  final canvas = _StageCanvas();
  scene(canvas, _frame(colors, t: t, still: still, peer: peer));
  return canvas;
}

_StageCanvas _scene(
  BridgeMode mode,
  NbColors colors,
  double t, {
  bool still = false,
  DeviceGlyph peer = DeviceGlyph.phone,
}) {
  final canvas = _StageCanvas();
  paintBridgeScene(
    canvas,
    _frame(colors, t: t, still: still, peer: peer),
    mode,
  );
  return canvas;
}

_StageCanvas _record(void Function(Canvas canvas) paint) {
  final canvas = _StageCanvas();
  paint(canvas);
  return canvas;
}

bool _sameRgb(Color a, Color b) =>
    (a.r - b.r).abs() < 1e-3 &&
    (a.g - b.g).abs() < 1e-3 &&
    (a.b - b.b).abs() < 1e-3;

bool _same(Color a, Color b) => _sameRgb(a, b) && (a.a - b.a).abs() < 1e-3;

Color _alpha(Color color, double factor) =>
    color.withValues(alpha: color.a * factor);

Color _mix(Color from, Color to, double k) => Color.from(
  alpha: from.a + (to.a - from.a) * k,
  red: from.r + (to.r - from.r) * k,
  green: from.g + (to.g - from.g) * k,
  blue: from.b + (to.b - from.b) * k,
);

bool _near(Offset a, Offset b, [double tolerance = 1e-6]) =>
    (a - b).distance < tolerance;

Matcher _point(Offset expected, [double tolerance = 1e-6]) => isA<Offset>()
    .having((o) => o.dx, 'dx', closeTo(expected.dx, tolerance))
    .having((o) => o.dy, 'dy', closeTo(expected.dy, tolerance));

Matcher _rect(Rect expected, [double tolerance = 1e-6]) => isA<Rect>()
    .having((r) => r.left, 'left', closeTo(expected.left, tolerance))
    .having((r) => r.top, 'top', closeTo(expected.top, tolerance))
    .having((r) => r.right, 'right', closeTo(expected.right, tolerance))
    .having((r) => r.bottom, 'bottom', closeTo(expected.bottom, tolerance));

void _expectAngle(double actual, double degrees, {String? reason}) {
  final expected = degrees * _deg;
  expect(math.cos(actual), closeTo(math.cos(expected), 1e-6), reason: reason);
  expect(math.sin(actual), closeTo(math.sin(expected), 1e-6), reason: reason);
}

bool _visible(_Draw draw) {
  if (!(draw.visibleAlpha > 0)) return false;
  if (draw.name == #drawPath && draw.stroked && !(draw.localLength > 0)) {
    return false;
  }
  return true;
}

_Draw _one(List<_Draw> found, [String reason = '']) {
  expect(found, hasLength(1), reason: reason);
  return found.single;
}

List<_Draw> _discFills(_StageCanvas canvas, Offset local) => [
  for (final draw in canvas.draws)
    if (draw.name == #drawCircle &&
        !draw.stroked &&
        (draw.baseRadius - 32).abs() < 1e-9 &&
        _near(draw.localCenter, local) &&
        _visible(draw))
      draw,
];

List<_Draw> _discRims(_StageCanvas canvas, Offset local) => [
  for (final draw in canvas.draws)
    if (draw.name == #drawCircle &&
        draw.stroked &&
        (draw.baseRadius - 32).abs() < 1e-9 &&
        _near(draw.localCenter, local) &&
        _visible(draw))
      draw,
];

List<_Draw> _pylons(_StageCanvas canvas, {required bool stroked}) => [
  for (final draw in canvas.draws)
    if (draw.name == #drawRRect && draw.stroked == stroked && _visible(draw))
      draw,
];

List<_Draw> _strokes(_StageCanvas canvas, double width) => [
  for (final draw in canvas.paths)
    if (draw.stroked &&
        (draw.paint.strokeWidth - width).abs() < 1e-6 &&
        _visible(draw))
      draw,
];

List<_Draw> _decks(_StageCanvas canvas) => [
  for (final draw in _strokes(canvas, 3))
    if ((draw.path.getBounds().top - 93).abs() < 1e-6 &&
        (draw.path.getBounds().bottom - 93).abs() < 1e-6)
      draw,
];

List<_Draw> _cables(_StageCanvas canvas) => [
  for (final draw in _strokes(canvas, 2.2))
    if ((draw.path.getBounds().top - 55).abs() < 1e-6) draw,
];

List<_Draw> _cracks(_StageCanvas canvas) => [
  for (final draw in _strokes(canvas, 2.2))
    if (draw.path.getBounds().top > 70) draw,
];

_Draw _side(List<_Draw> found, double startX) => _one([
  for (final draw in found)
    if ((draw.localStart.dx - startX).abs() < 1e-6) draw,
], 'span from x $startX');

List<_Draw> _hangers(_StageCanvas canvas) => [
  for (final draw in canvas.draws)
    if (draw.name == #drawLine && _visible(draw)) draw,
];

List<_Draw> _hangersAt(_StageCanvas canvas, double x) => [
  for (final draw in _hangers(canvas))
    if (((draw.args[0] as Offset).dx - x).abs() < 1e-9) draw,
];

List<_Draw> _lanes(_StageCanvas canvas) => [
  for (final draw in canvas.draws)
    if (draw.name == #drawCircle &&
        !draw.stroked &&
        (draw.baseRadius - 2.3).abs() < 1e-9 &&
        _visible(draw))
      draw,
];

List<_Draw> _particles(_StageCanvas canvas) => [
  for (final draw in canvas.draws)
    if (draw.name == #drawCircle &&
        !draw.stroked &&
        _particleRadii.any((r) => (draw.baseRadius - r).abs() < 1e-9) &&
        _visible(draw))
      draw,
];

List<_Draw> _flashes(_StageCanvas canvas) => [
  for (final draw in canvas.draws)
    if (draw.name == #drawCircle &&
        draw.stroked &&
        (draw.baseRadius - 12).abs() < 1e-9 &&
        (draw.paint.strokeWidth - 2.2).abs() < 1e-6 &&
        _visible(draw))
      draw,
];

List<_Draw> _badges(_StageCanvas canvas) => [
  for (final draw in canvas.draws)
    if (draw.name == #drawCircle &&
        !draw.stroked &&
        (draw.baseRadius - 12).abs() < 1e-9 &&
        _visible(draw))
      draw,
];

List<_Draw> _badgeMarks(_StageCanvas canvas) => [
  for (final draw in canvas.paths)
    if (_visible(draw) &&
        (_mapRect(draw.matrix, draw.path.getBounds()).center - _badge)
                .distance <
            8)
      draw,
];

bool _isLane(_Draw draw) =>
    draw.name == #drawCircle && (draw.baseRadius - 2.3).abs() < 1e-9;

int _indexOf(_StageCanvas canvas, _Draw draw) => canvas.draws.indexOf(draw);

void _expectOrder(_StageCanvas canvas, List<List<_Draw>> layers) {
  var last = -1;
  for (final layer in layers) {
    expect(layer, isNotEmpty);
    final indices = [for (final draw in layer) _indexOf(canvas, draw)];
    final low = indices.reduce(math.min);
    final high = indices.reduce(math.max);
    expect(low, greaterThan(last), reason: 'layer $indices after $last');
    last = high;
  }
}

List<_Draw> _discDraws(_StageCanvas canvas) => [
  for (final draw in canvas.draws)
    if (_visible(draw) &&
        [_leftDisc, _rightDisc].any(
          (disc) =>
              (draw.stageBounds.center - disc).distance < 25 &&
              draw.stageBounds.width < 70,
        ))
      draw,
];

typedef _GlyphStroke = ({Rect bounds, Color color, double width, bool fill});

List<_GlyphStroke> _glyphStrokes(Iterable<_Draw> paths) => [
  for (final path in paths)
    (
      bounds: _mapRect(path.matrix, path.path.getBounds()),
      color: path.paint.color,
      width: path.paint.strokeWidth,
      fill: path.paint.style == PaintingStyle.fill,
    ),
];

List<_Draw> _glyphPathsNear(_StageCanvas canvas, Offset center) => [
  for (final path in canvas.paths)
    if (_visible(path) &&
        (_mapRect(path.matrix, path.path.getBounds()).center - center)
                .distance <
            25 &&
        _mapRect(path.matrix, path.path.getBounds()).width < 45)
      path,
];

List<_GlyphStroke> _referenceGlyph(Glyph glyph, Offset center, Color ink) {
  const side = 24 * 32 / 22;
  final canvas = _record(
    (canvas) => paintGlyph(
      canvas,
      glyph,
      Rect.fromCenter(center: center, width: side, height: side),
      ink,
      strokeScale: 1.5 / 1.6,
    ),
  );
  return _glyphStrokes(canvas.paths);
}

void _expectSameGlyph(List<_GlyphStroke> actual, List<_GlyphStroke> expected) {
  expect(actual, hasLength(expected.length));
  for (var i = 0; i < expected.length; i++) {
    expect(actual[i].fill, expected[i].fill);
    expect(_same(actual[i].color, expected[i].color), isTrue);
    expect(actual[i].width, closeTo(expected[i].width, 1e-6));
    expect(actual[i].bounds, _rect(expected[i].bounds));
  }
}

void _expectOnly(
  _StageCanvas canvas,
  List<Color> palette, {
  String reason = '',
}) {
  for (final draw in canvas.draws) {
    final paint = draw.paint;
    if (paint.shader != null) {
      expect(draw.name, #drawCircle, reason: reason);
      expect(draw.stroked, isFalse, reason: reason);
      expect(draw.baseRadius, closeTo(32, 1e-9), reason: reason);
      continue;
    }
    expect(
      palette.any((color) => _sameRgb(color, paint.color)),
      isTrue,
      reason: '$reason ${draw.name} ${paint.color}',
    );
  }
}

void _expectDots(
  _StageCanvas canvas,
  double t,
  double shown,
  Color color,
  Color light, {
  String reason = '',
}) {
  final expected = [
    for (final dot in _labDots(t, shown))
      if (dot.alpha > 0) dot,
  ];
  final drawn = _lanes(canvas);
  expect(drawn, hasLength(expected.length), reason: reason);
  for (final dot in expected) {
    final match = [
      for (final draw in drawn)
        if (_near(draw.center, dot.at, 1e-6)) draw,
    ];
    final found = _one(match, '$reason ${dot.at}');
    final base = dot.light ? light : color;
    expect(
      _sameRgb(found.paint.color, base),
      isTrue,
      reason: '$reason ${dot.at} ${found.paint.color}',
    );
    expect(
      found.visibleAlpha,
      closeTo(base.a * dot.alpha, 1e-6),
      reason: '$reason ${dot.at}',
    );
    expect(found.radius, closeTo(2.3, 1e-9));
  }
}

void _expectParticles(
  _StageCanvas canvas,
  Offset at,
  double spread,
  double progress,
  double alpha,
  Color color, {
  double tolerance = 1e-6,
  String reason = '',
}) {
  final found = _particles(canvas);
  expect(found, hasLength(5), reason: reason);
  final expected = _labParticles(at, spread, progress);
  for (var i = 0; i < 5; i++) {
    expect(found[i].center, _point(expected[i], tolerance), reason: reason);
    expect(found[i].radius, closeTo(_particleRadii[i], 1e-9), reason: reason);
    expect(_sameRgb(found[i].paint.color, color), isTrue, reason: reason);
    expect(
      found[i].visibleAlpha,
      closeTo(color.a * alpha, 1e-5),
      reason: reason,
    );
  }
}

bool _finiteRect(Rect rect) =>
    rect.left.isFinite &&
    rect.top.isFinite &&
    rect.right.isFinite &&
    rect.bottom.isFinite;

bool _inside(Rect outer, Rect inner, [double tolerance = 0.5]) =>
    inner.left >= outer.left - tolerance &&
    inner.top >= outer.top - tolerance &&
    inner.right <= outer.right + tolerance &&
    inner.bottom <= outer.bottom + tolerance;

void _expectSound(_StageCanvas canvas, {String reason = ''}) {
  expect(canvas.getSaveCount(), 0, reason: reason);
  expect(canvas.clipsOutsideSave, 0, reason: reason);
  final calls = canvas.calls;
  for (final call in calls) {
    expect(_allowedCalls.contains(call), isTrue, reason: '$reason $call');
  }
  expect(
    calls.where((call) => call == #save || call == #saveLayer).length,
    calls.where((call) => call == #restore).length,
    reason: reason,
  );
  for (final draw in canvas.draws) {
    final why = '$reason ${draw.name}';
    for (final value in draw.matrix.storage) {
      expect(value.isFinite, isTrue, reason: why);
    }
    expect(draw.alpha.isFinite, isTrue, reason: why);
    expect(draw.alpha, inInclusiveRange(0, 1), reason: why);
    expect(draw.paint.color.a.isFinite, isTrue, reason: why);
    expect(draw.paint.strokeWidth.isFinite, isTrue, reason: why);
    for (final arg in draw.args) {
      if (arg is double) expect(arg.isFinite, isTrue, reason: why);
      if (arg is Offset) expect(arg.isFinite, isTrue, reason: why);
      if (arg is Rect) expect(_finiteRect(arg), isTrue, reason: why);
      if (arg is RRect) expect(_finiteRect(arg.outerRect), isTrue);
      if (arg is Path) expect(_finiteRect(arg.getBounds()), isTrue);
    }
    for (final layer in draw.layers) {
      expect(_finiteRect(layer), isTrue, reason: why);
      if (_visible(draw)) {
        expect(
          _inside(layer, draw.stageBounds),
          isTrue,
          reason: '$why ${draw.stageBounds} outside $layer',
        );
      }
    }
  }
}

String _f(double value) {
  final rounded = (value * 1000).roundToDouble() / 1000;
  return (rounded == 0 ? 0.0 : rounded).toStringAsFixed(3);
}

String _geometry(_Draw draw) {
  if (draw.name == #drawCircle) {
    final c = draw.localCenter;
    return '${_f(c.dx)},${_f(c.dy)},${_f(draw.baseRadius)}';
  }
  if (draw.name == #drawPath) {
    final b = draw.path.getBounds();
    return '${_f(b.left)},${_f(b.top)},${_f(b.right)},${_f(b.bottom)},'
        '${_f(draw.localLength)},${draw.metrics.length}';
  }
  if (draw.name == #drawLine) {
    final a = draw.args[0] as Offset;
    final b = draw.args[1] as Offset;
    return '${_f(a.dx)},${_f(a.dy)},${_f(b.dx)},${_f(b.dy)}';
  }
  if (draw.name == #drawRRect) {
    final r = draw.args[0] as RRect;
    return '${_f(r.left)},${_f(r.top)},${_f(r.right)},${_f(r.bottom)},'
        '${_f(r.tlRadiusX)}';
  }
  final r = draw.localBounds;
  return '${_f(r.left)},${_f(r.top)},${_f(r.right)},${_f(r.bottom)}';
}

String _signature(_Draw draw) {
  final paint = draw.paint;
  return [
    draw.name,
    _geometry(draw),
    draw.matrix.storage.map(_f).join(','),
    _f(draw.visibleAlpha),
    _f(paint.color.r),
    _f(paint.color.g),
    _f(paint.color.b),
    paint.style,
    _f(paint.strokeWidth),
    paint.strokeCap,
    paint.strokeJoin,
    paint.shader != null,
    draw.clips,
  ].join('|');
}

List<String> _picture(
  _StageCanvas canvas, {
  bool Function(_Draw draw)? where,
}) => [
  for (final draw in canvas.draws)
    if (_visible(draw) && (where == null || where(draw))) _signature(draw),
];

String _withoutStrings(String source) => source
    .replaceAll(RegExp(r"'''[\s\S]*?'''"), "''")
    .replaceAll(RegExp(r'"""[\s\S]*?"""'), '""')
    .replaceAll(RegExp(r"'(?:\\.|[^'\\\n])*'"), "''")
    .replaceAll(RegExp(r'"(?:\\.|[^"\\\n])*"'), '""');

void _expectNear(double? actual, double? expected, String field) {
  if (expected == null) {
    expect(actual, isNull, reason: field);
    return;
  }
  expect(actual, isNotNull, reason: field);
  expect(actual, closeTo(expected, 1e-6), reason: field);
}

void _expectPoseNear(
  BridgePose actual,
  BridgePose expected, {
  bool loops = true,
}) {
  expect(actual.ring, expected.ring, reason: 'ring');
  _expectNear(actual.discSlide, expected.discSlide, 'discSlide');
  _expectNear(actual.discsDim, expected.discsDim, 'discsDim');
  _expectNear(actual.peerRed, expected.peerRed, 'peerRed');
  _expectNear(actual.peerShake, expected.peerShake, 'peerShake');
  _expectNear(actual.pylons, expected.pylons, 'pylons');
  _expectNear(actual.deckDrawn, expected.deckDrawn, 'deckDrawn');
  _expectNear(actual.cableDrawn, expected.cableDrawn, 'cableDrawn');
  _expectNear(actual.hangers.first, expected.hangers.first, 'hangers.first');
  _expectNear(actual.hangers.second, expected.hangers.second, 'hangers.2');
  _expectNear(actual.hangersFade.left, expected.hangersFade.left, 'fadeL');
  _expectNear(actual.hangersFade.right, expected.hangersFade.right, 'fadeR');
  _expectNear(
    actual.hangersShrink.left,
    expected.hangersShrink.left,
    'shrinkL',
  );
  _expectNear(
    actual.hangersShrink.right,
    expected.hangersShrink.right,
    'shrinkR',
  );
  _expectNear(actual.deckAngle.left, expected.deckAngle.left, 'deckL');
  _expectNear(actual.deckAngle.right, expected.deckAngle.right, 'deckR');
  _expectNear(actual.cableAngle.left, expected.cableAngle.left, 'cableL');
  _expectNear(actual.cableAngle.right, expected.cableAngle.right, 'cableR');
  _expectNear(actual.spanOpacity, expected.spanOpacity, 'spanOpacity');
  _expectNear(actual.red, expected.red, 'red');
  _expectNear(actual.hangersRed, expected.hangersRed, 'hangersRed');
  _expectNear(actual.flash, expected.flash, 'flash');
  _expectNear(actual.burst, expected.burst, 'burst');
  _expectNear(actual.burstRamp, expected.burstRamp, 'burstRamp');
  _expectNear(actual.crack.opacity, expected.crack.opacity, 'crack.opacity');
  _expectNear(actual.badge.scale, expected.badge.scale, 'badge.scale');
  _expectNear(actual.badge.opacity, expected.badge.opacity, 'badge.opacity');
  if (loops) {
    _expectNear(actual.crack.scale, expected.crack.scale, 'crack.scale');
    _expectNear(actual.lanes, expected.lanes, 'lanes');
    _expectNear(actual.lanesPhase, expected.lanesPhase, 'lanesPhase');
  }
}

void _expectBounded(BridgePose pose, String why) {
  final fractions = <String, double>{
    'discSlide': pose.discSlide,
    'discsDim': pose.discsDim,
    'peerRed': pose.peerRed,
    'pylons': pose.pylons,
    'deckDrawn': pose.deckDrawn,
    'cableDrawn': pose.cableDrawn,
    'hangers.first': pose.hangers.first,
    'hangers.second': pose.hangers.second,
    'hangersFade.left': pose.hangersFade.left,
    'hangersFade.right': pose.hangersFade.right,
    'hangersShrink.left': pose.hangersShrink.left,
    'hangersShrink.right': pose.hangersShrink.right,
    'spanOpacity': pose.spanOpacity,
    'red': pose.red,
    'hangersRed': pose.hangersRed,
    'burstRamp': pose.burstRamp,
    'crack.opacity': pose.crack.opacity,
    'badge.opacity': pose.badge.opacity,
    'lanes': pose.lanes,
    'lanesPhase': pose.lanesPhase,
    'flash': ?pose.flash,
    'burst': ?pose.burst,
  };
  for (final entry in fractions.entries) {
    final reason = '$why ${entry.key} ${entry.value}';
    expect(entry.value.isFinite, isTrue, reason: reason);
    expect(entry.value, inInclusiveRange(0, 1), reason: reason);
  }
  expect(pose.lanesPhase, lessThan(1), reason: why);
  final bounded = <String, (double, double, double)>{
    'peerShake': (pose.peerShake, -4, 4),
    'deckAngle.left': (pose.deckAngle.left, -56, 56),
    'deckAngle.right': (pose.deckAngle.right, -56, 56),
    'cableAngle.left': (pose.cableAngle.left, -44, 44),
    'cableAngle.right': (pose.cableAngle.right, -44, 44),
    'crack.scale': (pose.crack.scale, 0.6, 1.35),
    'badge.scale': (pose.badge.scale, 0.4, 1.12),
  };
  for (final entry in bounded.entries) {
    final (value, low, high) = entry.value;
    final reason = '$why ${entry.key} $value';
    expect(value.isFinite, isTrue, reason: reason);
    expect(value, inInclusiveRange(low, high), reason: reason);
  }
}

void main() {
  group('E286 bridgePose paired', () {
    BridgePose at(double t) => bridgePose(BridgeMode.paired, t, still: false);

    test('before 1.75 s nothing of the bridge is there yet', () {
      for (final t in [-5.0, 0.0, 1.0, 1.75]) {
        final pose = at(t);
        expect(pose.discSlide, 0, reason: '$t');
        expect(pose.pylons, 0, reason: '$t');
        expect(pose.deckDrawn, 0, reason: '$t');
        expect(pose.cableDrawn, 0, reason: '$t');
        expect(pose.hangers, (first: 0.0, second: 0.0), reason: '$t');
        expect(pose.badge.opacity, 0, reason: '$t');
        expect(pose.lanes, 0, reason: '$t');
        expect(pose.flash, isNull, reason: '$t');
      }
    });

    test('the ring group runs until 1.95 s', () {
      expect(at(0).ring, isTrue);
      expect(at(1.94).ring, isTrue);
      expect(at(1.95).ring, isFalse);
      expect(at(3.9).ring, isFalse);
    });

    test('the discs slide in 0.55 s from 1.75 s with labEaseOut', () {
      expect(at(1.75).discSlide, 0);
      for (final t in [1.8, 2.0, 2.2, 2.3]) {
        expect(
          at(t).discSlide,
          closeTo(_ph(t, 1.75, 0.55, labEaseOut), 1e-12),
          reason: '$t',
        );
      }
      expect(at(2.3).discSlide, closeTo(1, 1e-6));
      expect(at(3).discSlide, 1);
    });

    test('the pylons rise in 0.45 s from 2.2 s with labEaseOut', () {
      expect(at(2.2).pylons, 0);
      for (final t in [2.25, 2.4, 2.6]) {
        expect(
          at(t).pylons,
          closeTo(_ph(t, 2.2, 0.45, labEaseOut), 1e-12),
          reason: '$t',
        );
      }
      expect(at(2.7).pylons, 1);
    });

    test(
      'no deck at 2.5 s, whole decks at 3.2 s and whole cables at 3.3 s',
      () {
        expect(at(2.5).deckDrawn, 0);
        expect(at(2.5).cableDrawn, 0);
        expect(at(3.2).deckDrawn, 1);
        expect(at(3.2).cableDrawn, lessThan(1));
        expect(at(3.3).cableDrawn, 1);
        for (final p in [0.1, 0.3, 0.5, 0.8]) {
          final deckT = 2.55 + 0.6 * p;
          final cableT = 2.6 + 0.65 * p;
          expect(
            at(deckT).deckDrawn,
            closeTo(_drawn(_ph(deckT, 2.55, 0.6, labEaseInOut)), 1e-12),
            reason: '$p',
          );
          expect(
            at(cableT).cableDrawn,
            closeTo(_drawn(_ph(cableT, 2.6, 0.65, labEaseInOut)), 1e-12),
            reason: '$p',
          );
        }
      },
    );

    test('a span shows nothing until its dash passes the 1.02 offset', () {
      expect(labEaseInOut.transform(0.1), lessThan(1 - 1 / 1.02));
      expect(at(2.55 + 0.6 * 0.1).deckDrawn, 0);
      expect(at(2.6 + 0.65 * 0.1).cableDrawn, 0);
      expect(at(2.55 + 0.6 * 0.3).deckDrawn, greaterThan(0));
    });

    test('the hangers grow in 0.35 s from 3.02 and 3.09 s', () {
      expect(at(3.02).hangers, (first: 0.0, second: 0.0));
      for (final t in [3.05, 3.09, 3.2, 3.4]) {
        final pose = at(t);
        expect(
          pose.hangers.first,
          closeTo(_ph(t, 3.02, 0.35, labEaseOut), 1e-12),
          reason: '$t',
        );
        expect(
          pose.hangers.second,
          closeTo(_ph(t, 3.09, 0.35, labEaseOut), 1e-12),
          reason: '$t',
        );
      }
      expect(at(3.09).hangers.second, 0);
      expect(at(3.5).hangers, (first: 1.0, second: 1.0));
    });

    test('the flash runs 0.55 s from 3.3 s, not from 2.78 s', () {
      for (final t in [2.78, 2.9, 3.2, 3.3, 3.86, 3.9, 10.0]) {
        expect(at(t).flash, isNull, reason: '$t');
      }
      for (final p in [0.1, 0.5, 0.9]) {
        final t = 3.3 + 0.55 * p;
        expect(at(t).flash, closeTo(_fly(t, 3.3, 0.55)!, 1e-12));
      }
    });

    test('the check badge pops at 3.4 s', () {
      for (final t in [1.0, 3.0, 3.4]) {
        expect(at(t).badge.opacity, 0, reason: '$t');
      }
      for (final t in [3.5, 3.67, 3.8]) {
        final pop = _pop(t, 3.4);
        expect(at(t).badge.scale, closeTo(pop.scale, 1e-12), reason: '$t');
        expect(at(t).badge.opacity, closeTo(pop.opacity, 1e-12));
      }
      expect(at(3.67).badge.scale, closeTo(1.12, 1e-2));
      expect(at(3.86).badge, (scale: 1.0, opacity: 1.0));
    });

    test('the lanes fade in 0.45 s from 3.45 s and are whole at 3.9 s', () {
      expect(at(3.45).lanes, 0);
      for (final t in [3.5, 3.6, 3.8]) {
        expect(
          at(t).lanes,
          closeTo(_ph(t, 3.45, 0.45, Curves.ease), 1e-12),
          reason: '$t',
        );
      }
      expect(at(3.9).lanes, closeTo(1, 1e-6));
      expect(at(4.5).lanes, 1);
    });

    test('the lane clock is a 2 s loop from t 0', () {
      for (final t in [0.0, 0.5, 1.5, 2.25, 3.9, 61.3]) {
        expect(at(t).lanesPhase, closeTo((t % 2) / 2, 1e-12), reason: '$t');
      }
    });

    test('nothing turns, dims, shakes, breaks or reddens', () {
      for (final t in [0.0, 1.0, 2.5, 3.3, 3.6, 10.0]) {
        final pose = at(t);
        expect(pose.discsDim, 1);
        expect(pose.peerRed, 0);
        expect(pose.peerShake, 0);
        expect(pose.deckAngle, (left: 0.0, right: 0.0));
        expect(pose.cableAngle, (left: 0.0, right: 0.0));
        expect(pose.hangersFade, (left: 1.0, right: 1.0));
        expect(pose.hangersShrink, (left: 0.0, right: 0.0));
        expect(pose.spanOpacity, 1);
        expect(pose.red, 0);
        expect(pose.hangersRed, 0);
        expect(pose.burst, isNull);
        expect(pose.crack.opacity, 0);
      }
    });
  });

  group('E286 bridgePose rejected', () {
    BridgePose at(double t) => bridgePose(BridgeMode.rejected, t, still: false);

    test('the bridge builds from 0.1 s: decks 0.45 s, cables 0.5 s', () {
      for (final t in [0.0, 0.1, 0.3, 0.5, 0.7, 0.9, 1.0, 1.1, 1.2, 1.3]) {
        final pose = at(t);
        expect(
          pose.pylons,
          closeTo(_ph(t, 0.1, 0.45, labEaseOut), 1e-12),
          reason: '$t',
        );
        expect(
          pose.deckDrawn,
          closeTo(_drawn(_ph(t, 0.45, 0.6, labEaseInOut)), 1e-12),
          reason: '$t',
        );
        expect(
          pose.cableDrawn,
          closeTo(_drawn(_ph(t, 0.5, 0.65, labEaseInOut)), 1e-12),
          reason: '$t',
        );
        expect(
          pose.hangers.first,
          closeTo(_ph(t, 0.95, 0.3, labEaseOut), 1e-12),
          reason: '$t',
        );
        expect(
          pose.hangers.second,
          closeTo(_ph(t, 1.02, 0.3, labEaseOut), 1e-12),
          reason: '$t',
        );
      }
      expect(at(0.1).pylons, 0);
      expect(at(0.45).deckDrawn, 0);
      expect(at(1.1).deckDrawn, 1);
      expect(at(1.2).cableDrawn, 1);
      expect(at(1.4).hangers, (first: 1.0, second: 1.0));
    });

    test('the bridge turns danger from 1.3 s and the peer rim from 1.35 s', () {
      for (final t in [0.0, 1.3, 1.4, 1.45, 1.5, 1.6, 1.7, 2.5]) {
        final pose = at(t);
        final red = _ph(t, 1.3, 0.3, Curves.ease);
        expect(pose.red, closeTo(red, 1e-12), reason: '$t');
        expect(pose.hangersRed, closeTo(red, 1e-12), reason: '$t');
        expect(
          pose.peerRed,
          closeTo(_ph(t, 1.35, 0.3, Curves.ease), 1e-12),
          reason: '$t',
        );
      }
      expect(at(1.3).red, 0);
      expect(at(1.35).peerRed, 0);
      expect(at(1.61).red, 1);
      expect(at(1.66).peerRed, 1);
    });

    test('the peer shakes 0.42 s from 1.42 s: -4, 4, -3 and 2 px', () {
      expect(at(1.42).peerShake, 0);
      expect(at(1.672).peerShake, -3);
      const marks = [-4.0, 4.0, -3.0, 2.0];
      for (var i = 0; i < 4; i++) {
        final t = 1.42 + 0.42 * (i + 1) * 0.2;
        final reference = _kf(_clock(t, 1.42, 0.42), _shake);
        expect(at(t).peerShake, closeTo(reference, 1e-12), reason: '$t');
        expect(reference, closeTo(marks[i], 1e-2), reason: '$t');
      }
      for (final t in [1.45, 1.55, 1.7]) {
        expect(
          at(t).peerShake,
          closeTo(_kf(_clock(t, 1.42, 0.42), _shake), 1e-12),
          reason: '$t',
        );
      }
      expect(at(1.85).peerShake, 0);
      expect(at(3).peerShake, 0);
    });

    test('the right deck falls to -56, -44 and -50 deg in 1 s from 1.32 s', () {
      expect(at(1.32).deckAngle.right, 0);
      expect(at(1.87).deckAngle.right, -56);
      for (final t in [1.4, 1.6, 1.87, 1.95, 2.07, 2.2, 2.3]) {
        expect(
          at(t).deckAngle.right,
          closeTo(_kf(_clock(t, 1.32, 1), _fallDeck), 1e-12),
          reason: '$t',
        );
      }
      expect(at(2.07).deckAngle.right, closeTo(-44, 1e-3));
      expect(at(2.5).deckAngle.right, -50);
    });

    test('the right cable falls to -44, -34 and -38 deg', () {
      expect(at(1.32).cableAngle.right, 0);
      expect(at(1.87).cableAngle.right, -44);
      for (final t in [1.4, 1.6, 1.95, 2.07, 2.2, 2.3]) {
        expect(
          at(t).cableAngle.right,
          closeTo(_kf(_clock(t, 1.32, 1), _fallCable), 1e-12),
          reason: '$t',
        );
      }
      expect(at(2.07).cableAngle.right, closeTo(-34, 1e-3));
      expect(at(2.5).cableAngle.right, -38);
    });

    test('the left deck sags 7 deg in 0.6 s from 1.45 s, its cable stays', () {
      expect(at(1.45).deckAngle.left, 0);
      for (final t in [1.5, 1.7, 1.9]) {
        expect(
          at(t).deckAngle.left,
          closeTo(7 * _ph(t, 1.45, 0.6, labEaseOut), 1e-12),
          reason: '$t',
        );
      }
      expect(at(2.1).deckAngle.left, 7);
      for (final t in [0.0, 1.5, 2.0, 3.0]) {
        expect(at(t).cableAngle.left, 0, reason: '$t');
      }
    });

    test('the right hangers go in 0.3 s from 1.32 s, the left ones stay', () {
      for (final t in [0.0, 1.32, 1.4, 1.5, 1.62, 2.0]) {
        final gone = _ph(t, 1.32, 0.3, Curves.ease);
        final pose = at(t);
        expect(pose.hangersFade.right, closeTo(1 - gone, 1e-12));
        expect(pose.hangersShrink.right, closeTo(gone, 1e-12));
        expect(pose.hangersFade.left, 1);
        expect(pose.hangersShrink.left, 0);
      }
      expect(at(1.7).hangersFade.right, 0);
    });

    test('the particles fly 0.9 s from 1.38 s', () {
      for (final t in [0.0, 1.38, 2.29, 2.3, 3.0]) {
        expect(at(t).burst, isNull, reason: '$t');
      }
      for (final t in [1.4, 1.6, 2.0, 2.25]) {
        expect(at(t).burst, closeTo(_fly(t, 1.38, 0.9)!, 1e-12));
      }
    });

    test('the X badge pops at 1.6 s, not at 1.3 or 1.5 s', () {
      for (final t in [1.3, 1.5, 1.6]) {
        expect(at(t).badge.opacity, 0, reason: '$t');
      }
      for (final t in [1.7, 1.87, 2.0]) {
        final pop = _pop(t, 1.6);
        expect(at(t).badge.scale, closeTo(pop.scale, 1e-12));
        expect(at(t).badge.opacity, closeTo(pop.opacity, 1e-12));
      }
      expect(at(2.06).badge, (scale: 1.0, opacity: 1.0));
    });

    test('no slide, no ring, no lanes, no flash, no crack and no dimming', () {
      for (final t in [0.0, 0.5, 1.4, 1.8, 2.5]) {
        final pose = at(t);
        expect(pose.discSlide, 1);
        expect(pose.discsDim, 1);
        expect(pose.ring, isFalse);
        expect(pose.lanes, 0);
        expect(pose.flash, isNull);
        expect(pose.crack.opacity, 0);
        expect(pose.spanOpacity, 1);
      }
    });

    test('at the end: right deck at -50, left at 7 and everything danger', () {
      for (final t in [2.4, 3.0, 60.0]) {
        final pose = at(t);
        expect(pose.deckAngle, (left: 7.0, right: -50.0));
        expect(pose.cableAngle, (left: 0.0, right: -38.0));
        expect(pose.red, 1);
        expect(pose.hangersRed, 1);
        expect(pose.peerRed, 1);
        expect(pose.peerShake, 0);
        expect(pose.hangersFade.right, 0);
        expect(pose.burst, isNull);
        expect(pose.badge, (scale: 1.0, opacity: 1.0));
      }
    });
  });

  group('E286 bridgePose loop', () {
    BridgePose at(double f) =>
        bridgePose(BridgeMode.loop, f * _cycle, still: false);

    test('rests at the start of each cycle with the lanes on', () {
      for (final f in [0.0, 0.2, 0.38]) {
        final pose = at(f);
        expect(pose.deckAngle, (left: 0.0, right: 0.0), reason: '$f');
        expect(pose.cableAngle, (left: 0.0, right: 0.0), reason: '$f');
        expect(pose.red, 0, reason: '$f');
        expect(pose.hangersFade, (left: 1.0, right: 1.0), reason: '$f');
        expect(pose.crack.opacity, 0, reason: '$f');
        expect(pose.burst, isNull, reason: '$f');
        expect(pose.lanes, 1, reason: '$f');
      }
    });

    test('the decks swing to 18 deg at 54 % and hold 15 from 60 to 80 %', () {
      expect(at(0.42).deckAngle, (left: 0.0, right: 0.0));
      expect(at(0.54).deckAngle, (left: 18.0, right: -18.0));
      for (final f in [0.6, 0.7, 0.8]) {
        expect(at(f).deckAngle, (left: 15.0, right: -15.0), reason: '$f');
      }
      for (final f in [0.96, 0.98]) {
        expect(at(f).deckAngle, (left: 0.0, right: 0.0), reason: '$f');
      }
    });

    test('the cables swing to 12 deg at 54 % and hold 10', () {
      expect(at(0.54).cableAngle, (left: 12.0, right: -12.0));
      for (final f in [0.6, 0.7, 0.8]) {
        expect(at(f).cableAngle, (left: 10.0, right: -10.0), reason: '$f');
      }
      expect(at(0.96).cableAngle, (left: 0.0, right: 0.0));
    });

    test('between keyframes the swing follows the lab curves', () {
      for (final f in [0.45, 0.5, 0.57, 0.65, 0.85, 0.9]) {
        final t = f * _cycle;
        final pose = bridgePose(BridgeMode.loop, t, still: false);
        final deck = _kf(_cycleOf(t), _swing(18, 15));
        final cable = _kf(_cycleOf(t), _swing(12, 10));
        expect(pose.deckAngle.left, closeTo(deck, 1e-12), reason: '$f');
        expect(pose.deckAngle.right, closeTo(-deck, 1e-12), reason: '$f');
        expect(pose.cableAngle.left, closeTo(cable, 1e-12), reason: '$f');
        expect(pose.cableAngle.right, closeTo(-cable, 1e-12), reason: '$f');
      }
    });

    test('the bridge and its hangers are danger from 48 to 86 %', () {
      for (final f in [0.48, 0.6, 0.86]) {
        expect(at(f).red, 1, reason: '$f');
        expect(at(f).hangersRed, 1, reason: '$f');
      }
      for (final f in [0.0, 0.4, 0.96]) {
        expect(at(f).red, 0, reason: '$f');
      }
      for (final f in [0.44, 0.9]) {
        final t = f * _cycle;
        final pose = bridgePose(BridgeMode.loop, t, still: false);
        expect(pose.red, closeTo(_kf(_cycleOf(t), _loopRed), 1e-12));
        expect(pose.hangersRed, closeTo(_kf(_cycleOf(t), _loopRed), 1e-12));
      }
    });

    test('the hangers fade out at 42-52 % and come back at 88-97 %', () {
      expect(at(0.42).hangersFade, (left: 1.0, right: 1.0));
      expect(at(0.52).hangersFade, (left: 0.0, right: 0.0));
      expect(at(0.88).hangersFade, (left: 0.0, right: 0.0));
      expect(at(0.98).hangersFade, (left: 1.0, right: 1.0));
      for (final f in [0.47, 0.92]) {
        final t = f * _cycle;
        final pose = bridgePose(BridgeMode.loop, t, still: false);
        final fade = _kf(_cycleOf(t), _hangerLoop);
        expect(pose.hangersFade, (left: fade, right: fade), reason: '$f');
      }
      for (final f in [0.0, 0.5, 0.7, 0.95]) {
        expect(at(f).hangersShrink, (left: 0.0, right: 0.0), reason: '$f');
      }
    });

    test('the crack flashes at 49 % and grows from 0.6 to 1.35', () {
      expect(at(0.3).crack, (opacity: 0.0, scale: 0.6));
      expect(at(0.45).crack, (opacity: 0.0, scale: 0.6));
      expect(at(0.49).crack.opacity, 1);
      expect(at(0.6).crack, (opacity: 0.0, scale: 1.35));
      expect(at(0.8).crack, (opacity: 0.0, scale: 1.35));
      for (final f in [0.47, 0.49, 0.55]) {
        final t = f * _cycle;
        final pose = bridgePose(BridgeMode.loop, t, still: false);
        expect(
          pose.crack.opacity,
          closeTo(_kf(_cycleOf(t), _crackOpacity), 1e-12),
          reason: '$f',
        );
        expect(
          pose.crack.scale,
          closeTo(_kf(_cycleOf(t), _crackScale), 1e-12),
          reason: '$f',
        );
      }
    });

    test('the particles fade in at 46-49 % and fly out until 70 %', () {
      for (final f in [0.0, 0.3, 0.45, 0.72, 0.9]) {
        expect(at(f).burst, isNull, reason: '$f');
        expect(at(f).burstRamp, 1, reason: '$f');
      }
      for (final f in [0.465, 0.475, 0.485]) {
        final t = f * _cycle;
        final pose = bridgePose(BridgeMode.loop, t, still: false);
        expect(pose.burst, 0, reason: '$f');
        expect(
          pose.burstRamp,
          closeTo(Curves.ease.transform((_cycleOf(t) - 0.46) / 0.03), 1e-9),
          reason: '$f',
        );
      }
      expect(at(0.49).burst, 0);
      expect(at(0.49).burstRamp, 1);
      for (final f in [0.55, 0.65]) {
        final t = f * _cycle;
        final pose = bridgePose(BridgeMode.loop, t, still: false);
        expect(
          pose.burst,
          closeTo(Curves.ease.transform((_cycleOf(t) - 0.49) / 0.21), 1e-9),
          reason: '$f',
        );
        expect(pose.burstRamp, 1, reason: '$f');
      }
    });

    test('the lanes show at 0-38 % and again at 100 %, on a 2 s clock', () {
      for (final f in [0.0, 0.2, 0.38]) {
        expect(at(f).lanes, 1, reason: '$f');
      }
      for (final f in [0.44, 0.6, 0.94]) {
        expect(at(f).lanes, 0, reason: '$f');
      }
      for (final f in [0.41, 0.97]) {
        final t = f * _cycle;
        expect(
          bridgePose(BridgeMode.loop, t, still: false).lanes,
          closeTo(_kf(_cycleOf(t), _lanesLoop), 1e-12),
          reason: '$f',
        );
      }
      for (final t in [0.0, 0.7, 1.3, 2.9, 5.1, 30.3]) {
        expect(
          bridgePose(BridgeMode.loop, t, still: false).lanesPhase,
          closeTo((t % 2) / 2, 1e-12),
          reason: '$t',
        );
      }
    });

    test('repeats every 4.4 s', () {
      for (final t in [0.3, 1.1, 2.0, 2.2, 2.6, 3.3, 4.0]) {
        _expectPoseNear(
          bridgePose(BridgeMode.loop, t + 3 * _cycle, still: false),
          bridgePose(BridgeMode.loop, t, still: false),
          loops: false,
        );
      }
    });

    test('builds nothing: discs, pylons and spans whole, no badge', () {
      for (final f in [0.0, 0.3, 0.5, 0.7, 0.9]) {
        final pose = at(f);
        expect(pose.discSlide, 1);
        expect(pose.discsDim, 1);
        expect(pose.pylons, 1);
        expect(pose.deckDrawn, 1);
        expect(pose.cableDrawn, 1);
        expect(pose.hangers, (first: 1.0, second: 1.0));
        expect(pose.spanOpacity, 1);
        expect(pose.badge.opacity, 0);
        expect(pose.flash, isNull);
        expect(pose.ring, isFalse);
        expect(pose.peerRed, 0);
        expect(pose.peerShake, 0);
      }
    });
  });

  group('E286 bridgePose breaking', () {
    BridgePose at(double t) => bridgePose(BridgeMode.breaking, t, still: false);

    test('decks open to 48 deg and cables to 34 in 0.8 s from 0.05 s', () {
      expect(at(0.05).deckAngle, (left: 0.0, right: 0.0));
      for (final t in [0.1, 0.3, 0.5, 0.8]) {
        final swing = _ph(t, 0.05, 0.8, labEaseOutSoft);
        final pose = at(t);
        expect(pose.deckAngle.left, closeTo(48 * swing, 1e-12));
        expect(pose.deckAngle.right, closeTo(-48 * swing, 1e-12));
        expect(pose.cableAngle.left, closeTo(34 * swing, 1e-12));
        expect(pose.cableAngle.right, closeTo(-34 * swing, 1e-12));
        expect(pose.spanOpacity, closeTo(1 - 0.25 * swing, 1e-12));
      }
      for (final t in [0.9, 1.0, 5.0]) {
        final pose = at(t);
        expect(pose.deckAngle, (left: 48.0, right: -48.0));
        expect(pose.cableAngle, (left: 34.0, right: -34.0));
        expect(pose.spanOpacity, 0.75);
      }
    });

    test('the hangers go in 0.25 s and everything turns danger in 0.2 s', () {
      for (final t in [0.0, 0.05, 0.1, 0.15, 0.2, 0.25, 0.5]) {
        final gone = _ph(t, 0, 0.25, Curves.ease);
        final pose = at(t);
        expect(pose.hangersFade, (left: 1 - gone, right: 1 - gone));
        expect(pose.hangersShrink, (left: gone, right: gone));
        expect(pose.red, closeTo(_ph(t, 0, 0.2, Curves.ease), 1e-12));
        expect(pose.hangersRed, 0);
      }
      expect(at(0.3).hangersFade, (left: 0.0, right: 0.0));
      expect(at(0.3).red, 1);
    });

    test('both discs dim to 40 % in 0.5 s from 0.5 s', () {
      expect(at(0.5).discsDim, 1);
      for (final t in [0.6, 0.75, 0.9]) {
        expect(
          at(t).discsDim,
          closeTo(1 - 0.6 * _ph(t, 0.5, 0.5, Curves.ease), 1e-12),
        );
      }
      expect(at(1.0).discsDim, closeTo(0.4, 1e-12));
    });

    test('the particles fly 0.8 s from 0.2 s', () {
      for (final t in [0.0, 0.2, 1.0, 1.2]) {
        expect(at(t).burst, isNull, reason: '$t');
      }
      for (final t in [0.3, 0.6, 0.95]) {
        expect(at(t).burst, closeTo(_fly(t, 0.2, 0.8)!, 1e-12));
      }
    });

    test('nothing builds, shakes or pops and there are no lanes', () {
      for (final t in [0.0, 0.3, 0.7, 1.0]) {
        final pose = at(t);
        expect(pose.discSlide, 1);
        expect(pose.pylons, 1);
        expect(pose.deckDrawn, 1);
        expect(pose.cableDrawn, 1);
        expect(pose.hangers, (first: 1.0, second: 1.0));
        expect(pose.peerRed, 0);
        expect(pose.peerShake, 0);
        expect(pose.badge.opacity, 0);
        expect(pose.flash, isNull);
        expect(pose.crack.opacity, 0);
        expect(pose.lanes, 0);
        expect(pose.ring, isFalse);
      }
    });
  });

  group('E286 bridgePose still (point 235)', () {
    const pairedStill = BridgePose(badge: (scale: 1, opacity: 1));
    const rejectedStill = BridgePose(
      peerRed: 1,
      hangersFade: (left: 1, right: 0),
      hangersShrink: (left: 0, right: 1),
      deckAngle: (left: 7, right: -50),
      cableAngle: (left: 0, right: -38),
      red: 1,
      hangersRed: 1,
      badge: (scale: 1, opacity: 1),
    );
    const breakingStill = BridgePose(
      discsDim: 0.4,
      hangersFade: (left: 0, right: 0),
      hangersShrink: (left: 1, right: 1),
      deckAngle: (left: 48, right: -48),
      cableAngle: (left: 34, right: -34),
      spanOpacity: 0.75,
      red: 1,
    );
    const expected = {
      BridgeMode.paired: pairedStill,
      BridgeMode.rejected: rejectedStill,
      BridgeMode.loop: BridgePose(),
      BridgeMode.breaking: breakingStill,
    };

    for (final entry in expected.entries) {
      test('${entry.key.name} still is its end state at any time', () {
        for (final t in _wild) {
          expect(
            bridgePose(entry.key, t, still: true),
            entry.value,
            reason: '$t',
          );
        }
      });
    }

    test('paired still: whole bridge and badge, no flash, lanes or ring', () {
      final pose = bridgePose(BridgeMode.paired, 3.6, still: true);
      expect(pose.flash, isNull);
      expect(pose.lanes, 0);
      expect(pose.ring, isFalse);
      expect(pose.hangers, (first: 1.0, second: 1.0));
    });

    test('loop still: whole primary bridge, no lanes, crack or particles', () {
      final pose = bridgePose(BridgeMode.loop, 0.49 * _cycle, still: true);
      expect(pose.red, 0);
      expect(pose.hangersRed, 0);
      expect(pose.deckAngle, (left: 0.0, right: 0.0));
      expect(pose.hangersFade, (left: 1.0, right: 1.0));
      expect(pose.lanes, 0);
      expect(pose.crack.opacity, 0);
      expect(pose.burst, isNull);
    });

    test('rejected and breaking still have no particles', () {
      expect(bridgePose(BridgeMode.rejected, 1.6, still: true).burst, isNull);
      expect(bridgePose(BridgeMode.breaking, 0.5, still: true).burst, isNull);
    });

    test('at introEnd the pose is the still one, but for what loops', () {
      for (final mode in [
        BridgeMode.paired,
        BridgeMode.rejected,
        BridgeMode.breaking,
      ]) {
        final end = stageSpecOf(_scenes[mode]!, const StageInput()).introEnd;
        _expectPoseNear(
          bridgePose(mode, end, still: false),
          bridgePose(mode, end, still: true),
          loops: mode != BridgeMode.paired,
        );
      }
      final loopEnd = stageSpecOf(
        StageScene.unpairLoop,
        const StageInput(),
      ).introEnd;
      _expectPoseNear(
        bridgePose(BridgeMode.loop, loopEnd, still: false),
        bridgePose(BridgeMode.loop, loopEnd, still: true),
        loops: false,
      );
    });
  });

  group('E286 BridgePose equality', () {
    final variants = <String, BridgePose Function(double v)>{
      'ring': (v) => BridgePose(ring: v > 0),
      'discSlide': (v) => BridgePose(discSlide: v),
      'discsDim': (v) => BridgePose(discsDim: v - 0.1),
      'peerRed': (v) => BridgePose(peerRed: v),
      'peerShake': (v) => BridgePose(peerShake: -8 * v),
      'pylons': (v) => BridgePose(pylons: v),
      'deckDrawn': (v) => BridgePose(deckDrawn: v),
      'cableDrawn': (v) => BridgePose(cableDrawn: v),
      'hangers': (v) => BridgePose(hangers: (first: 1, second: v)),
      'hangersFade': (v) => BridgePose(hangersFade: (left: 1, right: v)),
      'hangersShrink': (v) => BridgePose(hangersShrink: (left: v, right: 0)),
      'deckAngle': (v) => BridgePose(deckAngle: (left: 0, right: -2 * v)),
      'cableAngle': (v) => BridgePose(cableAngle: (left: 2 * v, right: 0)),
      'spanOpacity': (v) => BridgePose(spanOpacity: v + 0.25),
      'red': (v) => BridgePose(red: 2 * v),
      'hangersRed': (v) => BridgePose(hangersRed: 2 * v),
      'flash': (v) => BridgePose(flash: v - 0.5),
      'burst': (v) => BridgePose(burst: v),
      'burstRamp': (v) => BridgePose(burstRamp: v),
      'crack': (v) => BridgePose(crack: (opacity: 0, scale: v + 0.1)),
      'badge': (v) => BridgePose(badge: (scale: 1, opacity: 2 * v)),
      'lanes': (v) => BridgePose(lanes: 2 * v),
      'lanesPhase': (v) => BridgePose(lanesPhase: v / 2),
    };

    test('equal values are equal and share the hash code', () {
      BridgePose plain(double v) => BridgePose(red: v - 0.5);
      expect(plain(0.5), const BridgePose());
      expect(plain(0.5).hashCode, const BridgePose().hashCode);
      for (final entry in variants.entries) {
        final first = entry.value(0.5);
        final second = entry.value(0.5);
        expect(identical(first, second), isFalse, reason: entry.key);
        expect(first == second, isTrue, reason: entry.key);
        expect(first.hashCode, second.hashCode, reason: entry.key);
      }
    });

    test('each field on its own makes two poses different', () {
      expect(variants, hasLength(23));
      for (final entry in variants.entries) {
        final pose = entry.value(0.5);
        expect(pose == const BridgePose(), isFalse, reason: entry.key);
        expect(const BridgePose() == pose, isFalse, reason: entry.key);
      }
      final keys = variants.keys.toList();
      for (var i = 0; i < keys.length; i++) {
        for (var j = i + 1; j < keys.length; j++) {
          expect(
            variants[keys[i]]!(0.5) == variants[keys[j]]!(0.5),
            isFalse,
            reason: '${keys[i]} ${keys[j]}',
          );
        }
      }
    });

    test('is not equal to other objects', () {
      expect(const BridgePose() == Object(), isFalse);
    });

    test('the same mode and time give equal poses', () {
      for (final mode in BridgeMode.values) {
        for (final t in [0.0, 1.4, 2.2, 3.6]) {
          final a = bridgePose(mode, t, still: false);
          final b = bridgePose(mode, t, still: false);
          expect(a, b, reason: '${mode.name} $t');
          expect(a.hashCode, b.hashCode, reason: '${mode.name} $t');
        }
      }
    });
  });

  group('E286 bridgePose stays finite and bounded', () {
    for (final mode in BridgeMode.values) {
      test('${mode.name} at odd and extreme times, running and still', () {
        for (final t in _wild) {
          for (final still in [false, true]) {
            _expectBounded(
              bridgePose(mode, t, still: still),
              '${mode.name} $t $still',
            );
          }
        }
        for (var i = 0; i <= 400; i++) {
          final t = -1 + i * 0.0137;
          _expectBounded(bridgePose(mode, t, still: false), '${mode.name} $t');
        }
      });
    }
  });

  for (final (theme, colors) in _themes) {
    group('E286 paired drawing ($theme)', () {
      _StageCanvas at(double t, {bool still = false}) =>
          _scene(BridgeMode.paired, colors, t, still: still);

      test('the discs come out of x 150 to x 62 and x 238 (point 227)', () {
        expect(_discFills(at(1.75), _leftDisc), isEmpty);
        expect(_discFills(at(1.75), _rightDisc), isEmpty);
        for (final t in [1.75 + 0.55e-4, 1.8, 1.95, 2.1, 2.3, 3.9]) {
          final e = _ph(t, 1.75, 0.55, labEaseOut);
          final canvas = at(t);
          final left = _discFills(canvas, _leftDisc).first;
          final right = _discFills(canvas, _rightDisc).first;
          expect(left.center, _point(Offset(62 + 88 * (1 - e), 85)));
          expect(right.center, _point(Offset(238 - 88 * (1 - e), 85)));
          for (final body in [left, right]) {
            expect(body.radius, closeTo(32 * (0.7 + 0.3 * e), 1e-6));
            expect(body.alpha, closeTo(e, 1e-6), reason: '$t');
          }
        }
        final first = at(1.75 + 0.55e-4);
        final left = _discFills(first, _leftDisc).first;
        final right = _discFills(first, _rightDisc).first;
        expect(left.center.dx, closeTo(150, 0.5));
        expect(right.center.dx, closeTo(150, 0.5));
        expect(left.scale, closeTo(0.7, 5e-3));
        final landed = at(2.3);
        expect(
          _discFills(landed, _leftDisc).first.center,
          _point(_leftDisc, 1e-4),
        );
        expect(
          _discFills(landed, _rightDisc).first.center,
          _point(_rightDisc, 1e-4),
        );
        expect(_discFills(landed, _leftDisc).first.scale, closeTo(1, 1e-6));
      });

      test('the discs are successWeak, success rim of 2, successInk glyph', () {
        final canvas = at(2.5);
        for (final (local, glyph) in [
          (_leftDisc, Glyphs.pc),
          (_rightDisc, Glyphs.phone),
        ]) {
          final fill = _one(_discFills(canvas, local));
          expect(_same(fill.paint.color, colors.successWeak), isTrue);
          expect(fill.paint.shader, isNull);
          final rim = _one(_discRims(canvas, local));
          expect(_same(rim.paint.color, colors.success), isTrue);
          expect(rim.paint.strokeWidth, closeTo(2, 1e-6));
          _expectSameGlyph(
            _glyphStrokes(_glyphPathsNear(canvas, local)),
            _referenceGlyph(glyph, local, colors.successInk),
          );
        }
      });

      test('the pylons rise from their foot in 0.45 s from 2.2 s', () {
        expect(_pylons(at(2.2), stroked: false), isEmpty);
        for (final t in [2.3, 2.42, 2.6, 3.0]) {
          final e = _ph(t, 2.2, 0.45, labEaseOut);
          final canvas = at(t);
          final bodies = _pylons(canvas, stroked: false);
          final rims = _pylons(canvas, stroked: true);
          expect(bodies, hasLength(2));
          expect(rims, hasLength(2));
          for (var i = 0; i < 2; i++) {
            final x = [104.0, 196.0][i];
            final expected = Rect.fromLTRB(
              x - 3,
              105 - 50 * (0.3 + 0.7 * e),
              x + 3,
              105,
            );
            for (final draw in [bodies[i], rims[i]]) {
              expect(_mapRect(draw.matrix, draw.localBounds), _rect(expected));
              expect(draw.alpha, closeTo(e, 1e-6), reason: '$t');
              final rrect = draw.args[0] as RRect;
              expect(rrect.outerRect, _rect(Rect.fromLTWH(x - 3, 55, 6, 50)));
              expect(rrect.tlRadiusX, closeTo(2, 1e-9));
              expect(rrect.brRadiusY, closeTo(2, 1e-9));
            }
            expect(
              _same(bodies[i].paint.color, _alpha(colors.success, 0.22)),
              isTrue,
            );
            expect(_same(rims[i].paint.color, colors.success), isTrue);
            expect(rims[i].paint.strokeWidth, closeTo(1.6, 1e-6));
          }
        }
      });

      test('no deck at 2.5 s, whole decks at 3.2 s, whole cables at 3.3 s', () {
        final early = at(2.5);
        expect(_decks(early), isEmpty);
        expect(_cables(early), isEmpty);
        final decks = at(3.2);
        for (final (startX, pivot) in [
          (96.0, _leftDeckPivot),
          (204.0, _rightDeckPivot),
        ]) {
          final deck = _side(_decks(decks), startX);
          expect(deck.localLength, closeTo(54, 1e-3));
          expect(deck.start, _point(pivot));
          expect(deck.end, _point(_deckEnd, 1e-3));
          expect(_same(deck.paint.color, colors.success), isTrue);
          expect(deck.paint.strokeCap, StrokeCap.round);
          _expectAngle(deck.angle, 0);
        }
        expect(
          _side(_cables(decks), 104).localLength,
          lessThan(_cableLength - 0.1),
        );
        final cables = at(3.3);
        for (final (startX, pivot) in [
          (104.0, _leftCablePivot),
          (196.0, _rightCablePivot),
        ]) {
          final cable = _side(_cables(cables), startX);
          expect(cable.localLength, closeTo(_cableLength, 1e-3));
          expect(cable.start, _point(pivot));
          expect(cable.end, _point(_cableEnd, 1e-3));
          expect(_same(cable.paint.color, colors.success), isTrue);
          expect(cable.paint.strokeCap, StrokeCap.round);
          _expectAngle(cable.angle, 0);
        }
      });

      test('the spans draw themselves like the lab dash from 1.02', () {
        for (final p in [0.1, 0.3, 0.6, 0.9]) {
          final deckT = 2.55 + 0.6 * p;
          final deckShare = _drawn(_ph(deckT, 2.55, 0.6, labEaseInOut));
          final decks = _decks(at(deckT));
          if (deckShare == 0) {
            expect(decks, isEmpty, reason: '$p');
          } else {
            expect(decks, hasLength(2), reason: '$p');
            for (final deck in decks) {
              expect(deck.localLength, closeTo(54 * deckShare, 1e-3));
            }
          }
          final cableT = 2.6 + 0.65 * p;
          final cableShare = _drawn(_ph(cableT, 2.6, 0.65, labEaseInOut));
          final cables = _cables(at(cableT));
          if (cableShare == 0) {
            expect(cables, isEmpty, reason: '$p');
          } else {
            expect(cables, hasLength(2), reason: '$p');
            final labCable = Path()
              ..moveTo(104, 55)
              ..quadraticBezierTo(127, 86, 150, 86);
            final metric = labCable.computeMetrics().single;
            final piece = metric.extractPath(0, cableShare * metric.length);
            final left = _side(cables, 104);
            expect(left.localLength, closeTo(_measure(piece), 1e-3));
            expect(
              left.end,
              _point(
                metric
                    .getTangentForOffset(cableShare * metric.length)!
                    .position,
                1e-3,
              ),
            );
            expect(
              _side(cables, 196).localLength,
              closeTo(left.localLength, 1e-3),
            );
          }
        }
      });

      test('four hangers grow from their tops from 3.02 and 3.09 s', () {
        expect(_hangers(at(3.02)), isEmpty);
        for (final t in [3.1, 3.2, 3.3, 3.6]) {
          final canvas = at(t);
          for (final (x, top, delay) in _hangerTops) {
            final g = _ph(t, delay, 0.35, labEaseOut);
            final found = _hangersAt(canvas, x);
            if (g == 0) {
              expect(found, isEmpty, reason: '$t $x');
              continue;
            }
            final line = _one(found, '$t $x');
            expect(line.from, _point(Offset(x, top)));
            expect(
              line.to,
              _point(Offset(x, top + (93 - top) * (0.2 + 0.8 * g))),
            );
            expect(_sameRgb(line.paint.color, colors.success), isTrue);
            expect(
              line.visibleAlpha,
              closeTo(colors.success.a * 0.8 * g, 1e-6),
              reason: '$t $x',
            );
            expect(line.paint.strokeWidth, closeTo(1.5, 1e-6));
            expect(line.paint.strokeCap, StrokeCap.round);
          }
        }
        expect(_hangers(at(3.6)), hasLength(4));
      });

      test('the flash at (150, 93) grows 0.6 to 1.9 and fades from 3.3 s', () {
        for (final t in [2.9, 3.2, 3.3, 3.86, 3.9]) {
          expect(_flashes(at(t)), isEmpty, reason: '$t');
        }
        for (final p in [0.2, 0.5, 0.8]) {
          final t = 3.3 + 0.55 * p;
          final e = labEaseOut.transform((t - 3.3) / 0.55);
          final flash = _one(_flashes(at(t)));
          expect(flash.center, _point(_joint));
          expect(flash.radius, closeTo(12 * (0.6 + 1.3 * e), 1e-6));
          expect(_sameRgb(flash.paint.color, colors.success), isTrue);
          expect(
            flash.visibleAlpha,
            closeTo(colors.success.a * 0.9 * (1 - e), 1e-6),
          );
        }
      });

      test('the lanes: success dots and onPrimary dots at 90 %', () {
        expect(_lanes(at(3.45)), isEmpty);
        for (final t in [3.6, 3.9, 4.73, 7.1, 60.3]) {
          _expectDots(
            at(t),
            t,
            _ph(t, 3.45, 0.45, Curves.ease),
            colors.success,
            colors.onPrimary,
            reason: '$t',
          );
        }
      });

      test('the light dots run 0.5 s ahead of the coloured ones', () {
        for (final t in [3.9, 4.3, 5.05]) {
          final canvas = at(t);
          final dots = _lanes(canvas);
          final light = [
            for (final dot in dots)
              if (_sameRgb(dot.paint.color, colors.onPrimary)) dot.center.dx,
          ]..sort();
          final coloured = [
            for (final dot in dots)
              if (_sameRgb(dot.paint.color, colors.success)) dot.center.dx,
          ]..sort();
          final expectedLight = [
            for (final lead in const [0.5, 1.5])
              196 - 92 * (((t + lead) % 2) / 2),
          ]..sort();
          final expectedColoured = [
            for (final lead in const [0.0, 1.0])
              104 + 92 * (((t + lead) % 2) / 2),
          ]..sort();
          expect(light, hasLength(2));
          expect(coloured, hasLength(2));
          for (var i = 0; i < 2; i++) {
            expect(light[i], closeTo(expectedLight[i], 1e-6));
            expect(coloured[i], closeTo(expectedColoured[i], 1e-6));
          }
        }
      });

      test('the check badge pops at (262, 109) at 3.4 s', () {
        expect(_badges(at(3.4)), isEmpty);
        for (final t in [3.5, 3.67, 3.86]) {
          final pop = _pop(t, 3.4);
          final canvas = at(t);
          final badge = _one(_badges(canvas));
          expect(badge.center, _point(_badge));
          expect(badge.radius, closeTo(12 * pop.scale, 1e-6));
          expect(badge.alpha, closeTo(pop.opacity, 1e-6));
          expect(_same(badge.paint.color, colors.success), isTrue);
          final marks = _badgeMarks(canvas);
          expect(marks, isNotEmpty);
          for (final mark in marks) {
            expect(_sameRgb(mark.paint.color, colors.onSuccessDisc), isTrue);
          }
        }
      });

      test('the layers follow the lab order', () {
        final canvas = at(3.6);
        _expectOrder(canvas, [
          _discDraws(canvas),
          _pylons(canvas, stroked: false),
          _decks(canvas),
          _cables(canvas),
          _hangers(canvas),
          _lanes(canvas),
          _flashes(canvas),
          _badges(canvas),
        ]);
      });

      test('still: whole bridge, hangers at 80 %, badge, nothing else', () {
        final reference = _picture(at(0, still: true));
        for (final t in _wild) {
          expect(_picture(at(t, still: true)), reference, reason: '$t');
        }
        final canvas = at(0, still: true);
        expect(_discFills(canvas, _leftDisc).single.center, _point(_leftDisc));
        expect(
          _discFills(canvas, _rightDisc).single.center,
          _point(_rightDisc),
        );
        expect(_pylons(canvas, stroked: false), hasLength(2));
        for (final deck in _decks(canvas)) {
          expect(deck.localLength, closeTo(54, 1e-3));
        }
        for (final cable in _cables(canvas)) {
          expect(cable.localLength, closeTo(_cableLength, 1e-3));
        }
        final hangers = _hangers(canvas);
        expect(hangers, hasLength(4));
        for (final hanger in hangers) {
          expect(hanger.visibleAlpha, closeTo(colors.success.a * 0.8, 1e-6));
          expect(hanger.to.dy, closeTo(93, 1e-6));
        }
        final badge = _one(_badges(canvas));
        expect(badge.radius, closeTo(12, 1e-9));
        expect(badge.alpha, 1);
        expect(_flashes(canvas), isEmpty);
        expect(_lanes(canvas), isEmpty);
        expect(_particles(canvas), isEmpty);
        expect(_picture(_run(paintPaired, colors, 0, still: true)), reference);
      });

      test('at introEnd all but the lanes looks as it does still', () {
        final end = stageSpecOf(StageScene.paired, const StageInput()).introEnd;
        expect(
          _picture(at(end), where: (draw) => !_isLane(draw)),
          _picture(at(end, still: true)),
        );
        expect(_lanes(at(end)), isNotEmpty);
        expect(
          _picture(
            _run(paintPaired, colors, end),
            where: (draw) => !_isLane(draw),
          ),
          _picture(_run(paintPaired, colors, end, still: true)),
        );
      });

      test('uses only colours of NbColors', () {
        for (final t in [1.8, 2.3, 2.9, 3.2, 3.5, 3.6, 3.9, 6.0]) {
          _expectOnly(at(t), [
            colors.successWeak,
            colors.success,
            colors.successInk,
            colors.onPrimary,
            colors.card,
            colors.onSuccessDisc,
          ], reason: '$t');
          _expectOnly(_run(paintPaired, colors, t), [
            colors.stageTrack,
            colors.successWeak,
            colors.success,
            colors.successInk,
            colors.onPrimary,
            colors.card,
            colors.onSuccessDisc,
          ], reason: '$t');
        }
        _expectOnly(at(0, still: true), [
          colors.successWeak,
          colors.success,
          colors.successInk,
          colors.card,
          colors.onSuccessDisc,
        ]);
      });
    });

    group('E286 rejected drawing ($theme)', () {
      _StageCanvas at(double t, {bool still = false}) =>
          _scene(BridgeMode.rejected, colors, t, still: still);

      test('this disc: primary rim, its tint, primaryInk; the peer plain', () {
        final canvas = at(1.0);
        final own = _discFills(canvas, _leftDisc);
        expect(own.first.paint.shader, isNotNull);
        expect(own.first.center, _point(_leftDisc));
        final tints = own.skip(1).toList();
        if (colors.discTint > 0) {
          final tint = _one(tints);
          expect(
            _same(tint.paint.color, _alpha(colors.primary, colors.discTint)),
            isTrue,
          );
        } else {
          expect(tints, isEmpty);
        }
        final ownRim = _one(_discRims(canvas, _leftDisc));
        expect(_same(ownRim.paint.color, colors.primary), isTrue);
        expect(ownRim.paint.strokeWidth, closeTo(1.6, 1e-6));
        _expectSameGlyph(
          _glyphStrokes(_glyphPathsNear(canvas, _leftDisc)),
          _referenceGlyph(Glyphs.pc, _leftDisc, colors.primaryInk),
        );
        final peer = _one(_discFills(canvas, _rightDisc));
        expect(peer.paint.shader, isNotNull);
        expect(peer.center, _point(_rightDisc));
        final peerRim = _one(_discRims(canvas, _rightDisc));
        expect(_same(peerRim.paint.color, colors.stageBorder), isTrue);
        expect(peerRim.paint.strokeWidth, closeTo(1.6, 1e-6));
        _expectSameGlyph(
          _glyphStrokes(_glyphPathsNear(canvas, _rightDisc)),
          _referenceGlyph(Glyphs.phone, _rightDisc, colors.text),
        );
      });

      test('the peer rim turns danger in 0.3 s from 1.35 s', () {
        expect(_discRims(at(1.35), _rightDisc), hasLength(1));
        for (final t in [1.45, 1.55, 2.0, 3.0]) {
          final rims = _discRims(at(t), _rightDisc);
          expect(rims, hasLength(2), reason: '$t');
          expect(_same(rims.first.paint.color, colors.stageBorder), isTrue);
          final red = rims.last;
          expect(_sameRgb(red.paint.color, colors.danger), isTrue);
          expect(
            red.visibleAlpha,
            closeTo(colors.danger.a * _ph(t, 1.35, 0.3, Curves.ease), 1e-6),
            reason: '$t',
          );
          expect(red.paint.strokeWidth, closeTo(1.6, 1e-6));
          final shift = _kf(_clock(t, 1.42, 0.42), _shake);
          expect(red.center, _point(Offset(238 + shift, 85)), reason: '$t');
        }
      });

      test('the peer shakes -4, 4, -3 and 2 px from 1.42 s, this disc not', () {
        for (final t in [1.42, 1.504, 1.588, 1.672, 1.756, 1.5, 1.84, 2.0]) {
          final shift = _kf(_clock(t, 1.42, 0.42), _shake);
          final canvas = at(t);
          final peer = _one(_discFills(canvas, _rightDisc));
          expect(peer.center, _point(Offset(238 + shift, 85)), reason: '$t');
          for (final rim in _discRims(canvas, _rightDisc)) {
            expect(rim.center, _point(Offset(238 + shift, 85)));
          }
          _expectSameGlyph(
            _glyphStrokes(_glyphPathsNear(canvas, Offset(238 + shift, 85))),
            _referenceGlyph(Glyphs.phone, Offset(238 + shift, 85), colors.text),
          );
          expect(_discFills(canvas, _leftDisc).first.center, _point(_leftDisc));
        }
        expect(
          _one(_discFills(at(1.672), _rightDisc)).center,
          _point(const Offset(235, 85)),
        );
      });

      test('the bridge builds in primary from 0.1 s', () {
        expect(_pylons(at(0.1), stroked: false), isEmpty);
        final rising = at(0.3);
        for (final body in _pylons(rising, stroked: false)) {
          expect(body.alpha, closeTo(_ph(0.3, 0.1, 0.45, labEaseOut), 1e-6));
        }
        expect(_decks(at(0.45)), isEmpty);
        final built = at(1.25);
        for (final deck in _decks(built)) {
          expect(deck.localLength, closeTo(54, 1e-3));
          expect(_same(deck.paint.color, colors.primary), isTrue);
        }
        for (final cable in _cables(built)) {
          expect(cable.localLength, closeTo(_cableLength, 1e-3));
          expect(_same(cable.paint.color, colors.primary), isTrue);
        }
        expect(_decks(built), hasLength(2));
        expect(_cables(built), hasLength(2));
        expect(_hangers(at(0.95)), isEmpty);
        for (final t in [1.0, 1.1, 1.2, 1.3]) {
          final canvas = at(t);
          for (final (x, top, _) in _hangerTops) {
            final delay = top < 70 ? 0.95 : 1.02;
            final g = _ph(t, delay, 0.3, labEaseOut);
            final found = _hangersAt(canvas, x);
            if (g == 0) {
              expect(found, isEmpty, reason: '$t $x');
              continue;
            }
            final line = _one(found, '$t $x');
            expect(line.from, _point(Offset(x, top)));
            expect(
              line.to,
              _point(Offset(x, top + (93 - top) * (0.2 + 0.8 * g))),
            );
            expect(_sameRgb(line.paint.color, colors.primary), isTrue);
            expect(
              line.visibleAlpha,
              closeTo(colors.primary.a * 0.8 * g, 1e-6),
              reason: '$t $x',
            );
          }
        }
        expect(_hangers(at(1.3)), hasLength(4));
      });

      test('the bridge mixes from primary to danger between 1.3 and 1.6 s', () {
        for (final t in [1.3, 1.4, 1.45, 1.55, 1.6, 2.4]) {
          final k = _ph(t, 1.3, 0.3, Curves.ease);
          final tone = _mix(colors.primary, colors.danger, k);
          final canvas = at(t);
          for (final rim in _pylons(canvas, stroked: true)) {
            expect(_sameRgb(rim.paint.color, tone), isTrue, reason: '$t');
          }
          for (final body in _pylons(canvas, stroked: false)) {
            expect(_sameRgb(body.paint.color, tone), isTrue, reason: '$t');
            expect(body.paint.color.a, closeTo(tone.a * 0.22, 1e-3));
          }
          for (final span in [..._decks(canvas), ..._cables(canvas)]) {
            expect(_sameRgb(span.paint.color, tone), isTrue, reason: '$t');
          }
          for (final (x, _, _) in _hangerTops.where((h) => h.$1 < 150)) {
            final hanger = _one(_hangersAt(canvas, x));
            expect(_sameRgb(hanger.paint.color, tone), isTrue, reason: '$t');
          }
        }
      });

      test('the right deck falls around (204, 93), the left sags 7 deg', () {
        final end = at(3);
        final right = _side(_decks(end), 204);
        _expectAngle(right.angle, -50);
        expect(right.start, _point(_rightDeckPivot));
        expect(right.end, _point(_turn(_deckEnd, _rightDeckPivot, -50), 1e-3));
        final left = _side(_decks(end), 96);
        _expectAngle(left.angle, 7);
        expect(left.start, _point(_leftDeckPivot));
        expect(left.end, _point(_turn(_deckEnd, _leftDeckPivot, 7), 1e-3));
        _expectAngle(_side(_decks(at(1.87)), 204).angle, -56);
        _expectAngle(
          _side(_decks(at(1.87)), 96).angle,
          7 * _ph(1.87, 1.45, 0.6, labEaseOut),
        );
        for (final t in [1.5, 1.95, 2.1]) {
          _expectAngle(
            _side(_decks(at(t)), 204).angle,
            _kf(_clock(t, 1.32, 1), _fallDeck),
            reason: '$t',
          );
        }
      });

      test('the right cable falls around (196, 55), the left one stays', () {
        final end = at(3);
        final right = _side(_cables(end), 196);
        _expectAngle(right.angle, -38);
        expect(right.start, _point(_rightCablePivot));
        expect(
          right.end,
          _point(_turn(_cableEnd, _rightCablePivot, -38), 1e-3),
        );
        final left = _side(_cables(end), 104);
        _expectAngle(left.angle, 0);
        expect(left.end, _point(_cableEnd, 1e-3));
        _expectAngle(_side(_cables(at(1.87)), 196).angle, -44);
      });

      test('the right hangers fade and shrink towards (0, 0) from 1.32 s', () {
        for (final t in [1.4, 1.47, 1.55]) {
          final k = _ph(t, 1.32, 0.3, Curves.ease);
          final s = 1 - 0.4 * k;
          final tone = _mix(
            colors.primary,
            colors.danger,
            _ph(t, 1.3, 0.3, Curves.ease),
          );
          final canvas = at(t);
          for (final (x, top, _) in _hangerTops.where((h) => h.$1 > 150)) {
            final line = _one(_hangersAt(canvas, x), '$t $x');
            expect(line.from, _point(Offset(x * s, top * s)), reason: '$t');
            expect(line.to, _point(Offset(x * s, 93 * s)), reason: '$t');
            expect(
              line.paint.color.a,
              closeTo(tone.a * 0.8 * (1 - k), 1e-6),
              reason: '$t',
            );
          }
          for (final (x, top, _) in _hangerTops.where((h) => h.$1 < 150)) {
            final line = _one(_hangersAt(canvas, x), '$t $x');
            expect(line.from, _point(Offset(x, top)));
            expect(line.to, _point(Offset(x, 93)));
          }
        }
        for (final t in [1.7, 3.0]) {
          final canvas = at(t);
          expect(_hangersAt(canvas, 184), isEmpty);
          expect(_hangersAt(canvas, 172), isEmpty);
          expect(_hangers(canvas), hasLength(2));
        }
      });

      test('five danger particles fly 18 px from (176, 93) from 1.38 s', () {
        for (final t in [1.38, 2.29, 3.0]) {
          expect(_particles(at(t)), isEmpty, reason: '$t');
        }
        for (final t in [1.45, 1.7, 2.1]) {
          final e = _fly(t, 1.38, 0.9)!;
          _expectParticles(
            at(t),
            const Offset(176, 93),
            18,
            e,
            1 - e,
            colors.danger,
            reason: '$t',
          );
        }
      });

      test('the X badge pops at (262, 109) at 1.6 s', () {
        expect(_badges(at(1.6)), isEmpty);
        for (final t in [1.7, 1.87, 2.1]) {
          final pop = _pop(t, 1.6);
          final canvas = at(t);
          final badge = _one(_badges(canvas));
          expect(badge.center, _point(_badge));
          expect(badge.radius, closeTo(12 * pop.scale, 1e-6));
          expect(badge.alpha, closeTo(pop.opacity, 1e-6));
          expect(_same(badge.paint.color, colors.dangerFill), isTrue);
          final marks = _badgeMarks(canvas);
          expect(marks, isNotEmpty);
          for (final mark in marks) {
            expect(_same(mark.paint.color, colors.onPrimary), isTrue);
          }
        }
      });

      test('no lanes, flash or crack at any time', () {
        for (final t in [0.0, 0.5, 1.4, 1.8, 2.5, 3.6]) {
          final canvas = at(t);
          expect(_lanes(canvas), isEmpty);
          expect(_flashes(canvas), isEmpty);
          expect(_cracks(canvas), isEmpty);
        }
      });

      test('the layers follow the lab order', () {
        final canvas = at(1.7);
        _expectOrder(canvas, [
          _discDraws(canvas),
          _pylons(canvas, stroked: false),
          _decks(canvas),
          _cables(canvas),
          _hangers(canvas),
          _particles(canvas),
          _badges(canvas),
        ]);
      });

      test('still: the fallen bridge in danger at any time', () {
        final reference = _picture(at(0, still: true));
        for (final t in _wild) {
          expect(_picture(at(t, still: true)), reference, reason: '$t');
        }
        final canvas = at(0, still: true);
        _expectAngle(_side(_decks(canvas), 204).angle, -50);
        _expectAngle(_side(_decks(canvas), 96).angle, 7);
        _expectAngle(_side(_cables(canvas), 196).angle, -38);
        _expectAngle(_side(_cables(canvas), 104).angle, 0);
        final hangers = _hangers(canvas);
        expect(hangers, hasLength(2));
        for (final hanger in hangers) {
          expect(_sameRgb(hanger.paint.color, colors.danger), isTrue);
          expect(hanger.visibleAlpha, closeTo(colors.danger.a * 0.8, 1e-6));
        }
        for (final span in [..._decks(canvas), ..._cables(canvas)]) {
          expect(_same(span.paint.color, colors.danger), isTrue);
        }
        final rims = _discRims(canvas, _rightDisc);
        expect(_same(rims.last.paint.color, colors.danger), isTrue);
        expect(rims.last.center, _point(_rightDisc));
        expect(_one(_badges(canvas)).alpha, 1);
        expect(_particles(canvas), isEmpty);
      });

      test('at introEnd the drawing is the still one', () {
        final end = stageSpecOf(
          StageScene.rejected,
          const StageInput(),
        ).introEnd;
        expect(_picture(at(end)), _picture(at(end, still: true)));
      });

      test('uses only colours of NbColors', () {
        final palette = [
          colors.primary,
          colors.primaryInk,
          colors.stageBorder,
          colors.text,
          colors.danger,
          colors.dangerFill,
          colors.card,
          colors.onPrimary,
        ];
        for (final t in [0.3, 0.8, 1.0, 1.25, 1.7, 2.0, 2.32, 3.0]) {
          _expectOnly(at(t), palette, reason: '$t');
        }
        _expectOnly(at(0, still: true), palette);
      });
    });

    group('E286 unpair loop drawing ($theme)', () {
      _StageCanvas at(double f, {bool still = false}) =>
          _scene(BridgeMode.loop, colors, f * _cycle, still: still);

      test(
        'at rest: plain discs, the whole primary bridge and its hangers',
        () {
          for (final f in [0.0, 0.2]) {
            final canvas = at(f);
            final ownRim = _one(_discRims(canvas, _leftDisc));
            expect(_same(ownRim.paint.color, colors.primary), isTrue);
            _expectSameGlyph(
              _glyphStrokes(_glyphPathsNear(canvas, _leftDisc)),
              _referenceGlyph(Glyphs.pc, _leftDisc, colors.primaryInk),
            );
            final peerRim = _one(_discRims(canvas, _rightDisc));
            expect(_same(peerRim.paint.color, colors.stageBorder), isTrue);
            _expectSameGlyph(
              _glyphStrokes(_glyphPathsNear(canvas, _rightDisc)),
              _referenceGlyph(Glyphs.phone, _rightDisc, colors.text),
            );
            expect(_pylons(canvas, stroked: true), hasLength(2));
            for (final span in [..._decks(canvas), ..._cables(canvas)]) {
              expect(_same(span.paint.color, colors.primary), isTrue);
              _expectAngle(span.angle, 0);
            }
            expect(_decks(canvas), hasLength(2));
            expect(_cables(canvas), hasLength(2));
            final hangers = _hangers(canvas);
            expect(hangers, hasLength(4));
            for (final hanger in hangers) {
              expect(_sameRgb(hanger.paint.color, colors.primary), isTrue);
              expect(
                hanger.visibleAlpha,
                closeTo(colors.primary.a * 0.8, 1e-6),
              );
            }
            expect(_cracks(canvas), isEmpty);
            expect(_particles(canvas), isEmpty);
            expect(_badges(canvas), isEmpty);
            expect(_flashes(canvas), isEmpty);
          }
        },
      );

      test('the decks swing around their ends: 18 deg, then 15 deg', () {
        for (final (f, degrees) in [
          (0.54, 18.0),
          (0.6, 15.0),
          (0.7, 15.0),
          (0.8, 15.0),
        ]) {
          final canvas = at(f);
          final left = _side(_decks(canvas), 96);
          final right = _side(_decks(canvas), 204);
          _expectAngle(left.angle, degrees, reason: '$f');
          _expectAngle(right.angle, -degrees, reason: '$f');
          expect(left.start, _point(_leftDeckPivot));
          expect(right.start, _point(_rightDeckPivot));
          expect(
            left.end,
            _point(_turn(_deckEnd, _leftDeckPivot, degrees), 1e-3),
          );
          expect(
            right.end,
            _point(_turn(_deckEnd, _rightDeckPivot, -degrees), 1e-3),
          );
        }
      });

      test('the cables swing around their pylons: 12 deg, then 10 deg', () {
        for (final (f, degrees) in [(0.54, 12.0), (0.7, 10.0)]) {
          final canvas = at(f);
          final left = _side(_cables(canvas), 104);
          final right = _side(_cables(canvas), 196);
          _expectAngle(left.angle, degrees, reason: '$f');
          _expectAngle(right.angle, -degrees, reason: '$f');
          expect(left.start, _point(_leftCablePivot));
          expect(right.start, _point(_rightCablePivot));
        }
      });

      test('the hangers fade at 42-52 % and come back at 88-97 %', () {
        for (final f in [0.47, 0.92]) {
          final t = f * _cycle;
          final fade = _kf(_cycleOf(t), _hangerLoop);
          final tone = _mix(
            colors.primary,
            colors.danger,
            _kf(_cycleOf(t), _loopRed),
          );
          final hangers = _hangers(at(f));
          expect(hangers, hasLength(4), reason: '$f');
          for (final hanger in hangers) {
            expect(
              hanger.paint.color.a,
              closeTo(tone.a * 0.8 * fade, 1e-6),
              reason: '$f',
            );
            expect(
              hanger.from.dy,
              anyOf(closeTo(69.1, 1e-6), closeTo(78.9, 1e-6)),
            );
          }
        }
        for (final f in [0.52, 0.7, 0.88]) {
          expect(_hangers(at(f)), isEmpty, reason: '$f');
        }
      });

      test('the bridge mixes to danger at 40-48 % and back at 86-96 %', () {
        for (final f in [0.44, 0.5, 0.7, 0.9, 0.98]) {
          final t = f * _cycle;
          final tone = _mix(
            colors.primary,
            colors.danger,
            _kf(_cycleOf(t), _loopRed),
          );
          final canvas = at(f);
          for (final rim in _pylons(canvas, stroked: true)) {
            expect(_sameRgb(rim.paint.color, tone), isTrue, reason: '$f');
          }
          for (final span in [..._decks(canvas), ..._cables(canvas)]) {
            expect(_sameRgb(span.paint.color, tone), isTrue, reason: '$f');
          }
        }
        for (final span in _decks(at(0.6))) {
          expect(_same(span.paint.color, colors.danger), isTrue);
        }
      });

      test('the crack: three danger strokes of 2.2 scaled at (150, 93)', () {
        for (final f in [0.3, 0.45, 0.6, 0.8]) {
          expect(_cracks(at(f)), isEmpty, reason: '$f');
        }
        for (final f in [0.47, 0.49, 0.55]) {
          final t = f * _cycle;
          final opacity = _kf(_cycleOf(t), _crackOpacity);
          final scale = _kf(_cycleOf(t), _crackScale);
          final crack = _one(_cracks(at(f)), '$f');
          expect(_sameRgb(crack.paint.color, colors.danger), isTrue);
          expect(
            crack.visibleAlpha,
            closeTo(colors.danger.a * opacity, 1e-6),
            reason: '$f',
          );
          expect(crack.paint.strokeCap, StrokeCap.round);
          final pieces = crack.metrics;
          expect(pieces, hasLength(3));
          const strokes = [
            (Offset(150, 83), Offset(150, 76)),
            (Offset(159, 86), Offset(164, 81)),
            (Offset(141, 86), Offset(136, 81)),
          ];
          for (var i = 0; i < 3; i++) {
            final (from, to) = strokes[i];
            final piece = pieces[i];
            expect(
              crack.map(piece.getTangentForOffset(0)!.position),
              _point(_scaled(from, _joint, scale), 1e-4),
            );
            expect(
              crack.map(piece.getTangentForOffset(piece.length)!.position),
              _point(_scaled(to, _joint, scale), 1e-4),
            );
          }
        }
      });

      test('the particles appear at the joint and fly 16 px', () {
        for (final f in [0.3, 0.45, 0.72]) {
          expect(_particles(at(f)), isEmpty, reason: '$f');
        }
        for (final f in [0.465, 0.475, 0.485]) {
          final t = f * _cycle;
          final ramp = Curves.ease.transform((_cycleOf(t) - 0.46) / 0.03);
          _expectParticles(
            at(f),
            _joint,
            16,
            0,
            ramp,
            colors.danger,
            tolerance: 1e-4,
            reason: '$f',
          );
        }
        for (final f in [0.55, 0.65]) {
          final t = f * _cycle;
          final e = Curves.ease.transform((_cycleOf(t) - 0.49) / 0.21);
          _expectParticles(
            at(f),
            _joint,
            16,
            e,
            1 - e,
            colors.danger,
            reason: '$f',
          );
        }
      });

      test('the lanes: primary dots and onPrimary dots at 90 %', () {
        for (final f in [0.0, 0.1, 0.25, 0.38, 0.97]) {
          final t = f * _cycle;
          _expectDots(
            at(f),
            t,
            _kf(_cycleOf(t), _lanesLoop),
            colors.primary,
            colors.onPrimary,
            reason: '$f',
          );
        }
        for (final f in [0.44, 0.6, 0.9]) {
          expect(_lanes(at(f)), isEmpty, reason: '$f');
        }
      });

      test('the lane dots keep primary while the bridge turns red', () {
        for (final f in [0.41, 0.42, 0.43]) {
          final t = f * _cycle;
          final pose = bridgePose(BridgeMode.loop, t, still: false);
          expect(pose.red, greaterThan(0), reason: '$f');
          expect(pose.lanes, greaterThan(0), reason: '$f');
          _expectDots(
            at(f),
            t,
            _kf(_cycleOf(t), _lanesLoop),
            colors.primary,
            colors.onPrimary,
            reason: '$f',
          );
        }
      });

      test('repeats every 22 s, the shared period of swing and lanes', () {
        for (final f in [0.1, 0.47, 0.55, 0.72, 0.92]) {
          final t = f * _cycle;
          expect(
            _picture(_scene(BridgeMode.loop, colors, t + 22)),
            _picture(_scene(BridgeMode.loop, colors, t)),
            reason: '$f',
          );
        }
      });

      test('the layers follow the lab order', () {
        final canvas = at(0.47);
        _expectOrder(canvas, [
          _discDraws(canvas),
          _pylons(canvas, stroked: false),
          _decks(canvas),
          _cables(canvas),
          _hangers(canvas),
          _cracks(canvas),
          _particles(canvas),
        ]);
        final lanes = at(0.3);
        _expectOrder(lanes, [_hangers(lanes), _lanes(lanes)]);
      });

      test('still: the bridge at rest, no lanes, crack or particles', () {
        final reference = _picture(at(0, still: true));
        for (final t in _wild) {
          expect(
            _picture(_scene(BridgeMode.loop, colors, t, still: true)),
            reference,
            reason: '$t',
          );
        }
        final canvas = at(0.49, still: true);
        expect(_lanes(canvas), isEmpty);
        expect(_cracks(canvas), isEmpty);
        expect(_particles(canvas), isEmpty);
        expect(_hangers(canvas), hasLength(4));
        for (final span in [..._decks(canvas), ..._cables(canvas)]) {
          expect(_same(span.paint.color, colors.primary), isTrue);
          _expectAngle(span.angle, 0);
        }
        for (final rim in _pylons(canvas, stroked: true)) {
          expect(_same(rim.paint.color, colors.primary), isTrue);
        }
      });

      test('at introEnd all but the lanes looks as it does still', () {
        final end = stageSpecOf(
          StageScene.unpairLoop,
          const StageInput(),
        ).introEnd;
        expect(
          _picture(
            _scene(BridgeMode.loop, colors, end),
            where: (draw) => !_isLane(draw),
          ),
          _picture(_scene(BridgeMode.loop, colors, end, still: true)),
        );
      });

      test('uses only colours of NbColors', () {
        final palette = [
          colors.primary,
          colors.primaryInk,
          colors.stageBorder,
          colors.text,
          colors.danger,
          colors.onPrimary,
        ];
        for (final f in [0.0, 0.2, 0.3, 0.5, 0.55, 0.7]) {
          _expectOnly(at(f), palette, reason: '$f');
        }
        _expectOnly(at(0, still: true), palette);
      });
    });

    group('E286 unpair break drawing ($theme)', () {
      _StageCanvas at(double t, {bool still = false}) =>
          _scene(BridgeMode.breaking, colors, t, still: still);

      test('both discs dim to 40 % in 0.5 s from 0.5 s', () {
        for (final t in [0.0, 0.5, 0.6, 0.75, 0.9, 1.0]) {
          final dim = 1 - 0.6 * _ph(t, 0.5, 0.5, Curves.ease);
          final canvas = at(t);
          for (final local in [_leftDisc, _rightDisc]) {
            for (final fill in _discFills(canvas, local)) {
              expect(fill.alpha, closeTo(dim, 1e-6), reason: '$t');
            }
            for (final rim in _discRims(canvas, local)) {
              expect(rim.alpha, closeTo(dim, 1e-6), reason: '$t');
            }
          }
          expect(
            _same(
              _one(_discRims(canvas, _leftDisc)).paint.color,
              colors.primary,
            ),
            isTrue,
          );
          expect(
            _same(
              _one(_discRims(canvas, _rightDisc)).paint.color,
              colors.stageBorder,
            ),
            isTrue,
          );
        }
      });

      test('decks open to 48 deg, cables to 34, at 75 % and in danger', () {
        final canvas = at(1);
        for (final (startX, pivot, degrees) in [
          (96.0, _leftDeckPivot, 48.0),
          (204.0, _rightDeckPivot, -48.0),
        ]) {
          final deck = _side(_decks(canvas), startX);
          _expectAngle(deck.angle, degrees);
          expect(deck.start, _point(pivot));
          expect(deck.end, _point(_turn(_deckEnd, pivot, degrees), 1e-3));
          expect(deck.alpha, closeTo(0.75, 1e-6));
          expect(_same(deck.paint.color, colors.danger), isTrue);
        }
        for (final (startX, pivot, degrees) in [
          (104.0, _leftCablePivot, 34.0),
          (196.0, _rightCablePivot, -34.0),
        ]) {
          final cable = _side(_cables(canvas), startX);
          _expectAngle(cable.angle, degrees);
          expect(cable.start, _point(pivot));
          expect(cable.end, _point(_turn(_cableEnd, pivot, degrees), 1e-3));
          expect(cable.alpha, closeTo(0.75, 1e-6));
          expect(_same(cable.paint.color, colors.danger), isTrue);
        }
        for (final rim in _pylons(canvas, stroked: true)) {
          expect(_same(rim.paint.color, colors.danger), isTrue);
        }
        expect(_hangers(canvas), isEmpty);
      });

      test('the swing eases out softly from 0.05 s', () {
        for (final t in [0.1, 0.3, 0.5, 0.7]) {
          final swing = _ph(t, 0.05, 0.8, labEaseOutSoft);
          final canvas = at(t);
          _expectAngle(_side(_decks(canvas), 96).angle, 48 * swing);
          _expectAngle(_side(_decks(canvas), 204).angle, -48 * swing);
          _expectAngle(_side(_cables(canvas), 104).angle, 34 * swing);
          _expectAngle(_side(_cables(canvas), 196).angle, -34 * swing);
          for (final span in [..._decks(canvas), ..._cables(canvas)]) {
            expect(span.alpha, closeTo(1 - 0.25 * swing, 1e-6), reason: '$t');
          }
        }
      });

      test('the hangers fade and shrink towards (0, 0) in 0.25 s', () {
        for (final t in [0.05, 0.125, 0.2]) {
          final k = _ph(t, 0, 0.25, Curves.ease);
          final s = 1 - 0.4 * k;
          final canvas = at(t);
          for (final (x, top, _) in _hangerTops) {
            final line = _one(_hangersAt(canvas, x), '$t $x');
            expect(line.from, _point(Offset(x * s, top * s)));
            expect(line.to, _point(Offset(x * s, 93 * s)));
            expect(_sameRgb(line.paint.color, colors.primary), isTrue);
            expect(
              line.paint.color.a,
              closeTo(colors.primary.a * 0.8 * (1 - k), 1e-6),
            );
          }
        }
        for (final t in [0.25, 0.5, 1.0]) {
          expect(_hangers(at(t)), isEmpty, reason: '$t');
        }
      });

      test('the bridge turns danger in 0.2 s', () {
        for (final t in [0.0, 0.05, 0.1, 0.15, 0.2, 0.6]) {
          final tone = _mix(
            colors.primary,
            colors.danger,
            _ph(t, 0, 0.2, Curves.ease),
          );
          final canvas = at(t);
          for (final rim in _pylons(canvas, stroked: true)) {
            expect(_sameRgb(rim.paint.color, tone), isTrue, reason: '$t');
          }
          for (final span in [..._decks(canvas), ..._cables(canvas)]) {
            expect(_sameRgb(span.paint.color, tone), isTrue, reason: '$t');
          }
        }
      });

      test('five danger particles fly 18 px from (150, 93) from 0.2 s', () {
        for (final t in [0.0, 0.2, 1.0, 2.0]) {
          expect(_particles(at(t)), isEmpty, reason: '$t');
        }
        for (final t in [0.3, 0.6, 0.95]) {
          final e = _fly(t, 0.2, 0.8)!;
          _expectParticles(
            at(t),
            _joint,
            18,
            e,
            1 - e,
            colors.danger,
            reason: '$t',
          );
        }
      });

      test('no lanes, flash, crack or badge', () {
        for (final t in [0.0, 0.3, 0.7, 1.0, 3.0]) {
          final canvas = at(t);
          expect(_lanes(canvas), isEmpty);
          expect(_flashes(canvas), isEmpty);
          expect(_cracks(canvas), isEmpty);
          expect(_badges(canvas), isEmpty);
        }
      });

      test('the layers follow the lab order', () {
        final early = at(0.12);
        _expectOrder(early, [
          _discDraws(early),
          _pylons(early, stroked: false),
          _decks(early),
          _cables(early),
          _hangers(early),
        ]);
        final later = at(0.5);
        _expectOrder(later, [
          _discDraws(later),
          _pylons(later, stroked: false),
          _decks(later),
          _cables(later),
          _particles(later),
        ]);
      });

      test('still: the broken bridge at any time', () {
        final reference = _picture(at(0, still: true));
        for (final t in _wild) {
          expect(_picture(at(t, still: true)), reference, reason: '$t');
        }
        final canvas = at(0, still: true);
        _expectAngle(_side(_decks(canvas), 96).angle, 48);
        _expectAngle(_side(_cables(canvas), 196).angle, -34);
        expect(_hangers(canvas), isEmpty);
        expect(_particles(canvas), isEmpty);
        for (final fill in _discFills(canvas, _leftDisc)) {
          expect(fill.alpha, closeTo(0.4, 1e-6));
        }
      });

      test('at introEnd the drawing is the still one', () {
        final end = stageSpecOf(
          StageScene.unpairBreak,
          const StageInput(),
        ).introEnd;
        expect(_picture(at(end)), _picture(at(end, still: true)));
      });

      test('uses only colours of NbColors', () {
        final palette = [
          colors.primary,
          colors.primaryInk,
          colors.stageBorder,
          colors.text,
          colors.danger,
        ];
        for (final t in [0.0, 0.25, 0.5, 0.8, 1.0, 2.0]) {
          _expectOnly(at(t), palette, reason: '$t');
        }
        _expectOnly(at(0, still: true), palette);
      });
    });

    group('E286 painters ($theme)', () {
      test('each painter paints its own mode', () {
        for (final mode in [
          BridgeMode.rejected,
          BridgeMode.loop,
          BridgeMode.breaking,
        ]) {
          for (final t in [0.0, 0.3, 1.5, 2.2, 3.6]) {
            for (final still in [false, true]) {
              expect(
                _picture(_run(_painters[mode]!, colors, t, still: still)),
                _picture(_scene(mode, colors, t, still: still)),
                reason: '${mode.name} $t $still',
              );
            }
          }
        }
      });

      test('paintPaired paints paintPairedRing first, then the bridge', () {
        for (final t in [0.3, 1.0, 1.8, 1.9, 2.4, 3.6, 3.9]) {
          final paired = _picture(_run(paintPaired, colors, t));
          final ring = _picture(_run(paintPairedRing, colors, t));
          final bridge = _picture(_scene(BridgeMode.paired, colors, t));
          expect(paired, [...ring, ...bridge], reason: '$t');
          if (t < 1.95) expect(ring, isNotEmpty, reason: '$t');
        }
        expect(
          _picture(_run(paintPaired, colors, 1.9)).length,
          greaterThan(_picture(_scene(BridgeMode.paired, colors, 1.9)).length),
        );
      });

      test('the peer glyph follows the input', () {
        for (final mode in BridgeMode.values) {
          for (final peer in DeviceGlyph.values) {
            final canvas = _scene(mode, colors, 3, peer: peer);
            final ink = mode == BridgeMode.paired
                ? colors.successInk
                : colors.text;
            final center = mode == BridgeMode.rejected
                ? _discFills(canvas, _rightDisc).first.center
                : _rightDisc;
            _expectSameGlyph(
              _glyphStrokes(_glyphPathsNear(canvas, center)),
              _referenceGlyph(
                peer == DeviceGlyph.phone ? Glyphs.phone : Glyphs.pc,
                center,
                ink,
              ),
            );
          }
        }
      });

      test('every painter is sound and finite at any time', () {
        for (final entry in _painters.entries) {
          for (final t in _wild) {
            for (final still in [false, true]) {
              final reason = '${entry.key.name} $t $still';
              _expectSound(
                _run(entry.value, colors, t, still: still),
                reason: reason,
              );
              _expectSound(
                _scene(entry.key, colors, t, still: still),
                reason: reason,
              );
            }
          }
          for (var i = 0; i <= 300; i++) {
            final t = -0.5 + i * 0.0173;
            _expectSound(
              _run(entry.value, colors, t),
              reason: '${entry.key.name} $t',
            );
          }
        }
      });

      test('the bridge never clips', () {
        for (final mode in BridgeMode.values) {
          for (final t in [0.0, 0.3, 1.0, 1.5, 2.0, 2.4, 3.0, 3.6, 4.0]) {
            for (final still in [false, true]) {
              final canvas = _scene(mode, colors, t, still: still);
              expect(canvas.calls, isNot(contains(#clipPath)));
            }
          }
        }
      });
    });
  }

  group('E286 sources', () {
    const bridge = 'lib/src/ui/modal/bridge.dart';

    test('the comment check catches comments and ignores strings', () {
      bool hasComment(String source) {
        final code = _withoutStrings(source);
        return code.contains('//') || code.contains('/*');
      }

      expect(hasComment('final a = 1; // note'), isTrue);
      expect(hasComment('/// doc\nclass A {}'), isTrue);
      expect(hasComment('/* block */ final a = 1;'), isTrue);
      expect(hasComment("final url = 'https://example.com';"), isFalse);
      expect(hasComment('final a = 4 / 2;'), isFalse);
    });

    test('bridge.dart has no colour literal, Colors. or comment', () {
      final code = _withoutStrings(File(bridge).readAsStringSync());
      expect(RegExp(r'\bColor\s*\(').hasMatch(code), isFalse);
      expect(RegExp(r'\bColor\.from').hasMatch(code), isFalse);
      expect(RegExp(r'0x[0-9A-Fa-f]{6,8}').hasMatch(code), isFalse);
      expect(RegExp(r'\bColors\.(?!transparent\b)').hasMatch(code), isFalse);
      expect(RegExp(r'\b_white\b').hasMatch(code), isFalse);
      expect(code.contains('//'), isFalse);
      expect(code.contains('/*'), isFalse);
    });

    test('this test file has no comment', () {
      final code = _withoutStrings(
        File('test/ui/modal/bridge_test.dart').readAsStringSync(),
      );
      expect(code.contains('/*'), isFalse);
      final lines = code
          .split('\n')
          .where((line) => line.contains('//'))
          .toList();
      expect(lines, isEmpty);
    });

    test('only bridge.dart declares the bridge painters (point 219)', () {
      final declaration = RegExp(
        r'\bvoid\s+(paintBridgeScene|paintPaired|paintRejected|'
        r'paintUnpairLoop|paintUnpairBreak|paintUnpair)\s*\(',
      );
      final files = Directory('lib')
          .listSync(recursive: true)
          .whereType<File>()
          .where((file) => file.path.endsWith('.dart'));
      final owners = [
        for (final file in files)
          if (declaration.hasMatch(file.readAsStringSync()))
            file.path.replaceAll(r'\', '/'),
      ];
      expect(owners, [bridge]);
    });
  });
}
