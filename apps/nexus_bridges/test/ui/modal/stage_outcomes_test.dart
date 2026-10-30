import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nexus_bridges/src/ui/icons/device_disc.dart';
import 'package:nexus_bridges/src/ui/icons/glyphs.dart';
import 'package:nexus_bridges/src/ui/modal/stage_kit.dart';
import 'package:nexus_bridges/src/ui/modal/stage_outcomes.dart';
import 'package:nexus_bridges/src/ui/modal/timeline.dart';
import 'package:nexus_bridges/src/ui/theme/tokens.dart';
import 'package:nexus_bridges_core/nexus_bridges_core.dart' show PairingOutcome;

const Offset _center = Offset(150, 85);
const Offset _lostCenter = Offset(150, 101);
const Offset _wifiCenter = Offset(179, 72);
const double _tau = 2 * math.pi;
const double _deg = math.pi / 180;
const double _ring = _tau * 56;

final double _ringLength = _measure(
  Path()..addOval(Rect.fromCircle(center: _center, radius: 56)),
);

final double _floppyLength = _measure(
  Path()
    ..moveTo(0, 4)
    ..arcToPoint(const Offset(4, 0), radius: const Radius.circular(4))
    ..lineTo(30, 0)
    ..lineTo(40, 10)
    ..lineTo(40, 40)
    ..arcToPoint(const Offset(36, 44), radius: const Radius.circular(4))
    ..lineTo(4, 44)
    ..arcToPoint(const Offset(0, 40), radius: const Radius.circular(4))
    ..close(),
);

double _measure(Path path) =>
    path.computeMetrics().fold<double>(0, (sum, metric) => sum + metric.length);

const List<double> _wild = [
  -5,
  0,
  0.2,
  0.6,
  1.0,
  1.3,
  1.75,
  2.2,
  3.1,
  4.4,
  60,
  1e9,
  double.infinity,
  double.negativeInfinity,
  double.nan,
];

const List<(String, NbColors)> _themes = [
  ('light', NbColors.light),
  ('dark', NbColors.dark),
];

const Map<String, StageSceneFn> _painters = {
  'paintBusy': paintBusy,
  'paintPaused': paintPaused,
  'paintCancelledByPeer': paintCancelledByPeer,
  'paintExpired': paintExpired,
  'paintLost': paintLost,
  'paintNetworkChanged': paintNetworkChanged,
  'paintFailed': paintFailed,
  'paintNotSaved': paintNotSaved,
  'paintPairedRing': paintPairedRing,
};

const Map<StageScene, StageSceneFn> _outcomeScenes = {
  StageScene.busy: paintBusy,
  StageScene.paused: paintPaused,
  StageScene.cancelledByPeer: paintCancelledByPeer,
  StageScene.expired: paintExpired,
  StageScene.lost: paintLost,
  StageScene.networkChanged: paintNetworkChanged,
  StageScene.failed: paintFailed,
  StageScene.notSaved: paintNotSaved,
};

const List<(Offset, double, double)> _marks = [
  (Offset(102, 43), 1.9, 2.4),
  (Offset(198, 43), 2.0, 3.2),
  (Offset(150, 27), 2.15, 2.8),
];

const Offset _markPivot = Offset(0.2999 * 1.2, -0.71675 * 1.2);

const List<(double, double)> _flakes = [
  (-150, 76),
  (-90, 74),
  (-30, 76),
  (30, 76),
  (90, 74),
  (150, 76),
];

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
};

final class _Clip {
  _Clip(this.path, this.matrix);

  final Path path;
  final Matrix4 matrix;
}

final class _Draw {
  _Draw(this.name, this.args, this.matrix, this.alpha, this.clips, this.layers);

  final Symbol name;
  final List<dynamic> args;
  final Matrix4 matrix;
  final double alpha;
  final List<_Clip> clips;
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

  double get length => localLength * scale;

  Offset get start => map(metrics.first.getTangentForOffset(0)!.position);

  Offset get end {
    final last = metrics.last;
    return map(last.getTangentForOffset(last.length)!.position);
  }

  Offset get center => map(args[0] as Offset);

  double get baseRadius => args[1] as double;

  double get radius => baseRadius * scale;

  Rect get localBounds {
    if (name == #drawCircle) {
      return Rect.fromCircle(center: args[0] as Offset, radius: baseRadius);
    }
    if (name == #drawPath) return path.getBounds();
    if (name == #drawRect) return args[0] as Rect;
    if (name == #drawRRect) return (args[0] as RRect).outerRect;
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
  final List<List<_Clip>> _clips = [[]];
  final List<List<Rect>> _layers = [[]];
  final List<_Draw> draws = [];
  int clipsOutsideSave = 0;

  Matrix4 get _top => _matrices.last;

  void _push({double alpha = 1, Rect? layer}) {
    _matrices.add(_top.clone());
    _alphas.add(_alphas.last * alpha);
    _clips.add([..._clips.last]);
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
    _clips[_clips.length - 1] = [..._clips.last, _Clip(path, _top.clone())];
  }

  void _add(Symbol name, List<dynamic> args) => draws.add(
    _Draw(
      name,
      args,
      _top.clone(),
      _alphas.last,
      List.of(_clips.last),
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
  DeviceGlyph peer = DeviceGlyph.pc,
}) => StageFrame(
  t: t,
  still: still,
  colors: colors,
  input: StageInput(peer: peer),
);

_StageCanvas _paint(StageSceneFn scene, StageFrame frame) {
  final canvas = _StageCanvas();
  scene(canvas, frame);
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

bool _near(Offset a, Offset b, [double tolerance = 1e-6]) =>
    (a - b).distance < tolerance;

Matcher _at(Offset expected, [double tolerance = 1e-6]) => isA<Offset>()
    .having((o) => o.dx, 'dx', closeTo(expected.dx, tolerance))
    .having((o) => o.dy, 'dy', closeTo(expected.dy, tolerance));

Matcher _rect(Rect expected, [double tolerance = 1e-6]) => isA<Rect>()
    .having((r) => r.left, 'left', closeTo(expected.left, tolerance))
    .having((r) => r.top, 'top', closeTo(expected.top, tolerance))
    .having((r) => r.right, 'right', closeTo(expected.right, tolerance))
    .having((r) => r.bottom, 'bottom', closeTo(expected.bottom, tolerance));

void _expectAngle(double actual, double expected, {String? reason}) {
  expect(math.cos(actual), closeTo(math.cos(expected), 1e-6), reason: reason);
  expect(math.sin(actual), closeTo(math.sin(expected), 1e-6), reason: reason);
}

void _expectSameMatrix(Matrix4 a, Matrix4 b) {
  for (var i = 0; i < 16; i++) {
    expect(a.storage[i], closeTo(b.storage[i], 1e-9));
  }
}

double _ph(
  double t,
  double delay,
  double duration, [
  Curve curve = Curves.linear,
]) {
  if (t <= delay) return 0;
  if (t >= delay + duration) return 1;
  return curve.transform((t - delay) / duration);
}

double _kf(double p, List<(double, double)> frames, Curve curve) {
  if (p <= frames.first.$1) return frames.first.$2;
  for (var i = 0; i < frames.length - 1; i++) {
    final (from, fromValue) = frames[i];
    final (to, toValue) = frames[i + 1];
    if (p <= to) {
      return fromValue +
          (toValue - fromValue) * curve.transform((p - from) / (to - from));
    }
  }
  return frames.last.$2;
}

double _progress(double t, double delay, double duration) =>
    ((t - delay) / duration).clamp(0.0, 1.0);

double _shake(double t) => _kf(_progress(t, 0.75, 0.42), const [
  (0, 0),
  (0.2, -4),
  (0.4, 4),
  (0.6, -3),
  (0.8, 2),
  (1, 0),
], labShake);

double _shiver(double t) => _kf(_progress(t, 1, 0.45), const [
  (0, 0),
  (0.2, -2),
  (0.4, 2),
  (0.6, -1.5),
  (0.8, 1),
  (1, 0),
], Curves.linear);

double _twinkle(double t) {
  if (t < 2) return 1;
  return _kf(((t - 2) % 2.6) / 2.6, const [
    (0, 1),
    (0.5, 0.55),
    (1, 1),
  ], Curves.easeInOut);
}

double _seek(double t, int i) => _kf(_progress(t, 0.12 * i, 1.3), const [
  (0, 0),
  (0.15, 1),
  (0.35, 0.25),
  (0.5, 1),
  (0.7, 0.4),
  (0.85, 1),
  (1, 0),
], Curves.ease);

double _float(double t, double delay) {
  if (t < delay) return 0;
  return -3 *
      _kf(((t - delay) % 2.4) / 2.4, const [
        (0, 0),
        (0.5, 1),
        (1, 0),
      ], Curves.easeInOut);
}

({double scale, double opacity}) _pop(double t, double delay) {
  final p = _progress(t, delay, 0.45);
  return (
    scale: _kf(p, const [(0, 0.4), (0.6, 1.12), (1, 1)], labEaseOut),
    opacity: labEaseOut.transform(p),
  );
}

bool _visible(_Draw draw) {
  if (!(draw.visibleAlpha > 0)) return false;
  if (draw.name == #drawPath && draw.stroked && !(draw.localLength > 0)) {
    return false;
  }
  return true;
}

List<_Draw> _paths(_StageCanvas canvas, double width, [Color? rgb]) => [
  for (final draw in canvas.draws)
    if (draw.name == #drawPath &&
        draw.stroked &&
        (draw.paint.strokeWidth - width).abs() < 1e-6 &&
        _visible(draw) &&
        (rgb == null || _sameRgb(draw.paint.color, rgb)))
      draw,
];

List<_Draw> _circles(
  _StageCanvas canvas,
  double radius, {
  required bool stroked,
  Offset? at,
  double tolerance = 1e-6,
}) => [
  for (final draw in canvas.draws)
    if (draw.name == #drawCircle &&
        draw.stroked == stroked &&
        (draw.baseRadius - radius).abs() < 1e-6 &&
        _visible(draw) &&
        (at == null || _near(draw.center, at, tolerance)))
      draw,
];

List<_Draw> _rects(_StageCanvas canvas, Symbol name) => [
  for (final draw in canvas.draws)
    if (draw.name == name && _visible(draw)) draw,
];

_Draw _single(List<_Draw> found, [String reason = '']) {
  expect(found, hasLength(1), reason: reason);
  return found.single;
}

int _indexOf(_StageCanvas canvas, _Draw draw) => canvas.draws.indexOf(draw);

void _expectOrder(_StageCanvas canvas, List<_Draw> draws) {
  final order = [for (final draw in draws) _indexOf(canvas, draw)];
  expect(order, [...order]..sort());
  expect(order.toSet(), hasLength(order.length));
}

double _dashStartAngle(_Draw ring, Offset center) {
  final mapped = ring.start - center;
  return math.atan2(mapped.dy, mapped.dx);
}

double _ringRadius(_Draw path) {
  final bounds = path.path.getBounds();
  return (path.map(bounds.bottomRight) - path.map(bounds.topLeft)).distance /
      (2 * math.sqrt2);
}

List<double> _dashLengths(_Draw path) => [
  for (final metric in path.metrics) metric.length,
];

Offset _onCircle(Offset center, double radius, double clockwiseFromTop) =>
    Offset(
      center.dx + radius * math.sin(clockwiseFromTop),
      center.dy - radius * math.cos(clockwiseFromTop),
    );

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
    if ((_mapRect(path.matrix, path.path.getBounds()).center - center)
                .distance <
            25 &&
        _mapRect(path.matrix, path.path.getBounds()).width < 45)
      path,
];

List<_GlyphStroke> _referenceGlyph(
  Glyph glyph,
  Offset center,
  double radius,
  Color ink,
) {
  final side = 24 * radius / 22;
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
  Set<double> discs = const {},
  String reason = '',
}) {
  for (final draw in canvas.draws) {
    final paint = draw.paint;
    if (paint.shader != null) {
      expect(draw.name, #drawCircle, reason: reason);
      expect(draw.stroked, isFalse, reason: reason);
      expect(discs.contains(draw.baseRadius), isTrue, reason: reason);
      continue;
    }
    expect(
      palette.any((color) => _sameRgb(color, paint.color)),
      isTrue,
      reason: '$reason ${draw.name} ${paint.color}',
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
    final c = draw.args[0] as Offset;
    return '${_f(c.dx)},${_f(c.dy)},${_f(draw.baseRadius)}';
  }
  if (draw.name == #drawPath) {
    final b = draw.path.getBounds();
    return '${_f(b.left)},${_f(b.top)},${_f(b.right)},${_f(b.bottom)},'
        '${_f(draw.localLength)},${draw.metrics.length}';
  }
  final r = draw.localBounds;
  return '${_f(r.left)},${_f(r.top)},${_f(r.right)},${_f(r.bottom)}';
}

String _signature(_Draw draw, {bool alpha = true, bool matrix = true}) {
  final paint = draw.paint;
  return [
    draw.name,
    _geometry(draw),
    if (matrix) draw.matrix.storage.map(_f).join(','),
    if (alpha) _f(draw.visibleAlpha),
    _f(paint.color.r),
    _f(paint.color.g),
    _f(paint.color.b),
    paint.style,
    _f(paint.strokeWidth),
    paint.strokeCap,
    paint.strokeJoin,
    paint.shader != null,
    draw.clips.length,
  ].join('|');
}

List<String> _picture(
  _StageCanvas canvas, {
  bool Function(_Draw draw)? where,
  bool alpha = true,
  bool matrix = true,
}) => [
  for (final draw in canvas.draws)
    if (_visible(draw) && (where == null || where(draw)))
      _signature(draw, alpha: alpha, matrix: matrix),
];

Future<Color> _pixel(
  WidgetTester tester,
  void Function(Canvas canvas) paint,
  Offset at,
) async {
  final result = await tester.runAsync(() async {
    final recorder = ui.PictureRecorder();
    paint(Canvas(recorder));
    final image = await recorder.endRecording().toImage(300, 170);
    final data = await image.toByteData(
      format: ui.ImageByteFormat.rawStraightRgba,
    );
    image.dispose();
    final offset = (at.dy.floor() * 300 + at.dx.floor()) * 4;
    return Color.fromARGB(
      data!.getUint8(offset + 3),
      data.getUint8(offset),
      data.getUint8(offset + 1),
      data.getUint8(offset + 2),
    );
  });
  return result!;
}

double _premultipliedSum(Color c) => (c.r + c.g + c.b) * c.a * 255;

double _rgbDistance(Color a, Color b) =>
    ((a.r - b.r).abs() + (a.g - b.g).abs() + (a.b - b.b).abs()) * 255;

String _withoutStrings(String source) => source
    .replaceAll(RegExp(r"'''[\s\S]*?'''"), "''")
    .replaceAll(RegExp(r'"""[\s\S]*?"""'), '""')
    .replaceAll(RegExp(r"'(?:\\.|[^'\\\n])*'"), "''")
    .replaceAll(RegExp(r'"(?:\\.|[^"\\\n])*"'), '""');

void main() {
  for (final (theme, colors) in _themes) {
    group('E285 paintBusy ($theme)', () {
      _Draw ring(_StageCanvas c) => _single(_paths(c, 2.2, colors.stageHint));
      _Draw outline(_StageCanvas c) => _single(_paths(c, 2.2, colors.textWeak));
      _Draw caps(_StageCanvas c) => _single(_paths(c, 3, colors.textWeak));
      List<_Draw> stream(_StageCanvas c) => _paths(c, 1.6, colors.primary);
      List<_Draw> sand(_StageCanvas c) => _rects(c, #drawRect);
      _StageCanvas at(double t, {bool still = false}) =>
          _paint(paintBusy, _frame(colors, t: t, still: still));

      test('the dashed ring is stageHint, 60, 2.2 wide, 4 8 round, 10 s', () {
        for (final t in [0.0, 2.5, 5.0, 12.5, 33.3]) {
          final found = ring(at(t));
          expect(_same(found.paint.color, colors.stageHint), isTrue);
          expect(found.paint.strokeCap, StrokeCap.round);
          _expectAngle(
            _dashStartAngle(found, _center),
            _tau * (t % 10) / 10,
            reason: '$t',
          );
          expect(_ringRadius(found), closeTo(60, 0.5));
          final dashes = _dashLengths(found);
          expect(dashes.length, closeTo(_tau * 60 / 12, 1.5));
          for (final dash in dashes) {
            expect(dash, lessThanOrEqualTo(4 * 1.03));
          }
        }
      });

      test('the empty disc has radius 46, the node gradient and a rim', () {
        final canvas = at(0.7);
        final body = _single(_circles(canvas, 46, stroked: false, at: _center));
        expect(body.paint.shader, isNotNull);
        final rim = _single(_circles(canvas, 46, stroked: true, at: _center));
        expect(_same(rim.paint.color, colors.stageBorder), isTrue);
        expect(rim.paint.strokeWidth, closeTo(1.6, 1e-6));
        final known = {
          ring(canvas),
          outline(canvas),
          caps(canvas),
          ...stream(canvas),
        };
        for (final path in canvas.paths) {
          expect(known.contains(path), isTrue);
        }
      });

      test('the hourglass is scaled 1.3 at the centre and turns with hg2', () {
        for (final (cycle, degrees) in [
          (0.0, 0.0),
          (0.4, 0.0),
          (0.8, 0.0),
          (0.87, 180 * labSwing.transform(0.5)),
          (0.94, 180.0),
          (0.99, 180.0),
        ]) {
          for (final lap in [0, 2]) {
            final canvas = at(3.6 * (lap + cycle));
            final shape = outline(canvas);
            expect(shape.scale, closeTo(1.3, 1e-9));
            expect(shape.map(Offset.zero), _at(_center));
            _expectAngle(shape.angle, degrees * _deg, reason: '$cycle $lap');
            _expectSameMatrix(caps(canvas).matrix, shape.matrix);
            for (final grain in sand(canvas)) {
              _expectSameMatrix(grain.matrix, shape.matrix);
            }
          }
        }
      });

      test('the sand drops from the top bulb to the bottom one by 76 %', () {
        for (final cycle in [0.0, 0.19, 0.38, 0.57, 0.76, 0.9]) {
          final canvas = at(3.6 * cycle);
          final fall = math.min(cycle / 0.76, 1.0);
          final grains = sand(canvas);
          expect(grains, hasLength(2), reason: '$cycle');
          final top = grains.first;
          final bottom = grains.last;
          expect(
            top.args[0] as Rect,
            _rect(Rect.fromLTWH(-13, -19 + 19 * fall, 26, 19), 1e-6),
          );
          expect(
            bottom.args[0] as Rect,
            _rect(Rect.fromLTWH(-13, 6 + 19 * (1 - fall), 26, 19), 1e-6),
          );
          for (final grain in grains) {
            expect(_same(grain.paint.color, colors.primary), isTrue);
            expect(grain.stroked, isFalse);
            expect(grain.clips, hasLength(1));
            _expectSameMatrix(grain.clips.single.matrix, grain.matrix);
          }
          final topClip = top.clips.single.path;
          final bottomClip = bottom.clips.single.path;
          expect(
            topClip.getBounds(),
            _rect(const Rect.fromLTRB(-12, -24, 12, 0)),
          );
          expect(
            bottomClip.getBounds(),
            _rect(const Rect.fromLTRB(-12, 0, 12, 24)),
          );
          expect(topClip.contains(const Offset(0, -12)), isTrue);
          expect(topClip.contains(const Offset(0, -23)), isTrue);
          expect(topClip.contains(const Offset(11, -2)), isFalse);
          expect(topClip.contains(const Offset(0, 12)), isFalse);
          expect(bottomClip.contains(const Offset(0, 12)), isTrue);
          expect(bottomClip.contains(const Offset(0, 23)), isTrue);
          expect(bottomClip.contains(const Offset(11, 2)), isFalse);
          expect(bottomClip.contains(const Offset(0, -12)), isFalse);
        }
      });

      test('only the sand is clipped', () {
        for (final t in [0.0, 1.8, 3.2]) {
          for (final draw in at(t).draws) {
            if (draw.name == #drawRect) continue;
            expect(draw.clips, isEmpty, reason: '${draw.name}');
          }
        }
      });

      test('the stream fades in at 3-6 %, out at 72-76 %, dashes slide', () {
        for (final cycle in [0.0, 0.02, 0.8, 0.95]) {
          expect(stream(at(3.6 * cycle)), isEmpty, reason: '$cycle');
        }
        for (final (cycle, opacity) in [
          (0.045, 0.5),
          (0.3, 1.0),
          (0.5, 1.0),
          (0.74, 0.5),
        ]) {
          final canvas = at(3.6 * cycle);
          final found = _single(stream(canvas), '$cycle');
          expect(found.visibleAlpha, closeTo(opacity, 1e-6), reason: '$cycle');
          expect(found.paint.strokeCap, StrokeCap.butt);
          _expectSameMatrix(found.matrix, outline(canvas).matrix);
          final phase = -30 * (cycle - 0.03) / 0.73;
          final offset = phase % 5;
          final expected = <(double, double)>[];
          for (var pos = -offset; pos < 22; pos += 5) {
            final from = math.max(pos, 0.0);
            final to = math.min(pos + 2, 22.0);
            if (to > from + 1e-9) expected.add((from, to));
          }
          final actual = [
            for (final metric in found.metrics)
              (
                metric.getTangentForOffset(0)!.position,
                metric.getTangentForOffset(metric.length)!.position,
              ),
          ];
          expect(actual, hasLength(expected.length), reason: '$cycle');
          for (var i = 0; i < expected.length; i++) {
            expect(actual[i].$1, _at(Offset(0, expected[i].$1), 1e-3));
            expect(actual[i].$2, _at(Offset(0, expected[i].$2), 1e-3));
          }
        }
      });

      test('the outline is the lab silhouette with s rewritten as c', () {
        final canvas = at(0.5);
        final shape = outline(canvas);
        expect(shape.paint.strokeJoin, StrokeJoin.round);
        expect(_same(shape.paint.color, colors.textWeak), isTrue);
        final expected = Path()
          ..moveTo(-12, -24)
          ..cubicTo(-12, -14, -2, -10, -2, 0)
          ..cubicTo(-2, 10, -12, 14, -12, 24)
          ..moveTo(12, -24)
          ..cubicTo(12, -14, 2, -10, 2, 0)
          ..cubicTo(2, 10, 12, 14, 12, 24);
        final actualMetrics = shape.metrics;
        final expectedMetrics = expected.computeMetrics().toList();
        expect(actualMetrics, hasLength(2));
        for (var i = 0; i < 2; i++) {
          final a = actualMetrics[i];
          final e = expectedMetrics[i];
          expect(a.length, closeTo(e.length, 1e-3));
          for (final k in [0.0, 0.2, 0.4, 0.5, 0.6, 0.8, 1.0]) {
            expect(
              a.getTangentForOffset(a.length * k)!.position,
              _at(e.getTangentForOffset(e.length * k)!.position, 1e-2),
            );
          }
        }
        final top = caps(canvas);
        expect(top.paint.strokeCap, StrokeCap.round);
        expect(_same(top.paint.color, colors.textWeak), isTrue);
        final bars = top.metrics;
        expect(bars, hasLength(2));
        expect(
          bars[0].getTangentForOffset(0)!.position,
          _at(const Offset(-15, -24)),
        );
        expect(bars[0].length, closeTo(30, 1e-6));
        expect(
          bars[1].getTangentForOffset(0)!.position,
          _at(const Offset(-15, 24)),
        );
        expect(bars[1].length, closeTo(30, 1e-6));
      });

      test('the layers follow the lab order', () {
        final canvas = at(1.8);
        final grains = sand(canvas);
        _expectOrder(canvas, [
          ring(canvas),
          _single(_circles(canvas, 46, stroked: false, at: _center)),
          _single(_circles(canvas, 46, stroked: true, at: _center)),
          grains.first,
          grains.last,
          _single(stream(canvas)),
          outline(canvas),
          caps(canvas),
        ]);
      });

      test('still: ring at rest, upright, sand on top, no stream, any t', () {
        for (final t in [0.0, 0.9, 1.44, 2.66, 3.132, 3.5, 1e6]) {
          final canvas = at(t, still: true);
          _expectAngle(_dashStartAngle(ring(canvas), _center), 0);
          _expectAngle(outline(canvas).angle, 0);
          final grains = sand(canvas);
          expect(grains, hasLength(2));
          expect(
            grains.first.args[0] as Rect,
            _rect(const Rect.fromLTWH(-13, -19, 26, 19)),
          );
          expect(
            grains.last.args[0] as Rect,
            _rect(const Rect.fromLTWH(-13, 25, 26, 19)),
          );
          expect(stream(canvas), isEmpty);
        }
      });

      test('at introEnd the drawing is the still one', () {
        final end = stageSpecOf(StageScene.busy, const StageInput()).introEnd;
        expect(_picture(at(end)), _picture(at(end, still: true)));
      });

      test('uses only colours of NbColors', () {
        for (final (t, still) in [(0.3, false), (1.8, false), (3.2, true)]) {
          _expectOnly(
            at(t, still: still),
            [
              colors.stageHint,
              colors.stageBorder,
              colors.primary,
              colors.textWeak,
            ],
            discs: {46},
          );
        }
      });

      testWidgets('the sand only shows inside its silhouette', (tester) async {
        for (final (t, inside, outside) in [
          (0.0, const Offset(150, 72), const Offset(150, 125)),
          (3.6 * 0.38, const Offset(150, 111), const Offset(150, 124)),
        ]) {
          void paint(Canvas canvas) => paintBusy(canvas, _frame(colors, t: t));
          final filled = await _pixel(tester, paint, inside);
          expect(_rgbDistance(filled, colors.primary), lessThan(30));
          final empty = await _pixel(tester, paint, outside);
          expect(_rgbDistance(empty, colors.primary), greaterThan(100));
        }
      });
    });

    group('E285 paintPaused ($theme)', () {
      _StageCanvas at(double t, {bool still = false}) =>
          _paint(paintPaused, _frame(colors, t: t, still: still));
      _Draw track(_StageCanvas c) =>
          _single(_circles(c, 56, stroked: true, at: _center));
      List<_Draw> arc(_StageCanvas c) => _paths(c, 5);
      _Draw discFill(_StageCanvas c) =>
          _single(_circles(c, 42, stroked: false));
      _Draw discRim(_StageCanvas c) => _single(_circles(c, 42, stroked: true));
      List<_Draw> bars(_StageCanvas c) => _rects(c, #drawRRect);
      List<_Draw> glint(_StageCanvas c) => _rects(c, #drawRect);
      List<_Draw> flakes(_StageCanvas c) => _paths(c, 1.7);
      Color freezeColor(Color from, Color to, double t) =>
          Color.lerp(from, to, _ph(t, 1, 0.6, Curves.ease))!;

      test('the track is a stageTrack ring of 56 and width 5', () {
        final found = track(at(0.4));
        expect(_same(found.paint.color, colors.stageTrack), isTrue);
        expect(found.paint.strokeWidth, closeTo(5, 1e-6));
      });

      test('the arc draws itself clockwise from the top in 0.7 s', () {
        expect(arc(at(0)), isEmpty);
        for (final t in [0.175, 0.35, 0.525, 0.7, 3.0]) {
          final found = _single(arc(at(t)), '$t');
          final drawn = _ph(t, 0, 0.7, labEaseInOut);
          expect(found.length, closeTo(drawn * _ringLength, 0.3), reason: '$t');
          expect(found.start, _at(const Offset(150, 29), 1e-3));
          if (drawn < 1) {
            expect(found.end, _at(_onCircle(_center, 56, _tau * drawn), 0.3));
          }
          expect(found.paint.strokeCap, StrokeCap.round);
        }
        final half = _single(arc(at(0.35)));
        final quarter = half.metrics.single.getTangentForOffset(
          _ringLength / 4 / half.scale,
        )!;
        expect(half.map(quarter.position), _at(const Offset(206, 85), 1e-3));
      });

      test('the arc turns from textWeak to ice between 1 and 1.6 s', () {
        for (final t in [0.9, 1.0, 1.3, 1.6, 3.0]) {
          final found = _single(arc(at(t)));
          expect(
            _same(
              found.paint.color,
              freezeColor(colors.textWeak, colors.ice, t),
            ),
            isTrue,
            reason: '$t',
          );
        }
        expect(
          _same(_single(arc(at(0.9))).paint.color, colors.textWeak),
          isTrue,
        );
        expect(_same(_single(arc(at(1.6))).paint.color, colors.ice), isTrue);
      });

      test('the disc turns from stageWeak and stageBorder to the ice pair', () {
        for (final t in [0.5, 1.15, 1.3, 1.45, 2.0]) {
          final canvas = at(t);
          final fill = discFill(canvas);
          final rim = discRim(canvas);
          expect(fill.baseRadius, 42);
          expect(rim.paint.strokeWidth, closeTo(1.6, 1e-6));
          expect(
            _same(
              fill.paint.color,
              freezeColor(colors.stageWeak, colors.iceWeak, t),
            ),
            isTrue,
            reason: '$t',
          );
          expect(
            _same(
              rim.paint.color,
              freezeColor(colors.stageBorder, colors.ice, t),
            ),
            isTrue,
            reason: '$t',
          );
        }
        expect(_same(discFill(at(0.5)).paint.color, colors.stageWeak), isTrue);
        expect(_same(discRim(at(0.5)).paint.color, colors.stageBorder), isTrue);
        expect(_same(discFill(at(2)).paint.color, colors.iceWeak), isTrue);
        expect(_same(discRim(at(2)).paint.color, colors.ice), isTrue);
      });

      test('the disc group shivers 0.45 s from 1 s: -2, 2, -1.5 and 1 px', () {
        for (final (local, dx) in [
          (0.0, 0.0),
          (0.1, -1.0),
          (0.2, -2.0),
          (0.3, 0.0),
          (0.4, 2.0),
          (0.5, 0.25),
          (0.6, -1.5),
          (0.7, -0.25),
          (0.8, 1.0),
          (0.9, 0.5),
          (1.0, 0.0),
        ]) {
          final t = 1 + 0.45 * local;
          final canvas = at(t);
          expect(discFill(canvas).center, _at(Offset(150 + dx, 85), 1e-6));
          expect(discRim(canvas).center, _at(Offset(150 + dx, 85), 1e-6));
          final pair = bars(canvas);
          expect(pair, hasLength(2));
          expect(
            pair.first.map((pair.first.args[0] as RRect).center),
            _at(Offset(141 + dx, 85), 1e-6),
          );
          expect(
            pair.last.map((pair.last.args[0] as RRect).center),
            _at(Offset(159 + dx, 85), 1e-6),
          );
        }
        for (final t in [0.5, 0.99, 1.46, 3.0]) {
          expect(discFill(at(t)).center, _at(_center), reason: '$t');
        }
        expect(_shiver(1.09), closeTo(-2, 1e-9));
      });

      test('the bars grow from 10 % with bar, 90 ms apart, and turn ice', () {
        for (final t in [0.3, 0.45]) {
          expect(bars(at(t)), isEmpty, reason: '$t');
        }
        for (final t in [0.55, 0.65, 0.8, 0.94, 1.0, 1.3, 1.7, 3.0]) {
          final canvas = at(t);
          final pair = bars(canvas);
          expect(pair, hasLength(2), reason: '$t');
          for (var i = 0; i < 2; i++) {
            final bar = pair[i];
            final rrect = bar.args[0] as RRect;
            expect(
              rrect.outerRect,
              _rect(Rect.fromLTWH(i == 0 ? 136 : 154, 67, 10, 36)),
            );
            expect(rrect.tlRadiusX, closeTo(3.5, 1e-9));
            expect(rrect.blRadiusY, closeTo(3.5, 1e-9));
            final grow = _ph(t, 0.45 + 0.09 * i, 0.4, labEaseOut);
            expect(bar.visibleAlpha, closeTo(grow, 1e-6), reason: '$t $i');
            final height =
                bar.map(rrect.outerRect.bottomCenter).dy -
                bar.map(rrect.outerRect.topCenter).dy;
            expect(height, closeTo(36 * (0.1 + 0.9 * grow), 1e-6));
            final width =
                bar.map(rrect.outerRect.centerRight).dx -
                bar.map(rrect.outerRect.centerLeft).dx;
            expect(width, closeTo(10, 1e-6));
            expect(
              _sameRgb(
                bar.paint.color,
                freezeColor(colors.textWeak, colors.ice, t),
              ),
              isTrue,
              reason: '$t',
            );
          }
        }
        expect(bars(at(0.5)), hasLength(1));
      });

      test('the glint crosses once at 1.45 s, tilted 22 deg and clipped', () {
        for (final t in [1.0, 1.44, 1.45, 2.25, 2.5, 60.0]) {
          expect(glint(at(t)), isEmpty, reason: '$t');
        }
        for (final k in [0.25, 0.5, 0.75]) {
          final canvas = at(1.45 + 0.8 * k);
          final found = _single(glint(canvas), '$k');
          final slide = labEaseInOut.transform(k);
          expect(
            found.args[0] as Rect,
            _rect(Rect.fromLTWH(70 + 160 * slide, 15, 18, 140), 1e-6),
          );
          _expectAngle(found.angle, 22 * _deg);
          expect(found.map(_center), _at(_center, 1e-6));
          expect(
            _same(found.paint.color, _alpha(colors.onPrimary, 0.5)),
            isTrue,
          );
          expect(found.clips, hasLength(1));
          final clip = found.clips.single;
          expect(
            _mapRect(clip.matrix, clip.path.getBounds()),
            _rect(Rect.fromCircle(center: _center, radius: 42), 1e-6),
          );
          expect(clip.path.contains(const Offset(150, 85)), isTrue);
          expect(clip.path.contains(const Offset(180, 115)), isFalse);
        }
      });

      test('only the glint is clipped', () {
        for (final t in [0.6, 1.85, 3.0]) {
          for (final draw in at(t).draws) {
            if (draw.name == #drawRect) continue;
            expect(draw.clips, isEmpty, reason: '${draw.name}');
          }
        }
      });

      test('six snowflakes at -150 to 150 deg, scale 1.2, ice 1.7 round', () {
        final found = flakes(at(1.99));
        expect(found, hasLength(6));
        for (var i = 0; i < 6; i++) {
          final (angle, distance) = _flakes[i];
          final expected = Offset(
            150 + distance * math.cos(angle * _deg),
            85 + distance * 0.97 * math.sin(angle * _deg),
          );
          final flake = found[i];
          expect(flake.map(Offset.zero), _at(expected, 1e-6), reason: '$i');
          expect(flake.scale, closeTo(1.2, 1e-6));
          _expectAngle(flake.angle, 0);
          expect(flake.visibleAlpha, closeTo(1, 1e-6));
          expect(_sameRgb(flake.paint.color, colors.ice), isTrue);
          expect(flake.paint.strokeCap, StrokeCap.round);
          expect(
            flake.path.getBounds(),
            _rect(const Rect.fromLTRB(-6.9, -8, 6.9, 8), 1e-6),
          );
          expect(flake.metrics, hasLength(9));
        }
      });

      test('each flake appears with crys from 1.05 s every 80 ms', () {
        expect(flakes(at(1.0)), isEmpty);
        expect(flakes(at(1.05)), isEmpty);
        final canvas = at(1.3);
        final found = flakes(canvas);
        expect(found, hasLength(4));
        for (var i = 0; i < 4; i++) {
          final appear = _ph(1.3, 1.05 + 0.08 * i, 0.5, labEaseOut);
          final (angle, distance) = _flakes[i];
          final expected = Offset(
            150 + distance * math.cos(angle * _deg),
            85 + distance * 0.97 * math.sin(angle * _deg),
          );
          expect(found[i].map(Offset.zero), _at(expected, 1e-6));
          expect(found[i].scale, closeTo(1.2 * (0.2 + 0.8 * appear), 1e-6));
          _expectAngle(found[i].angle, -60 * _deg * (1 - appear));
          expect(found[i].visibleAlpha, closeTo(appear, 1e-6), reason: '$i');
        }
      });

      test('the flakes twinkle from 2 s on a 2.6 s loop down to 0.55', () {
        for (final t in [
          1.96,
          1.99,
          2.0,
          2.65,
          3.3,
          3.95,
          4.6,
          2 + 2.6 * 3 + 1.3,
        ]) {
          final found = flakes(at(t));
          expect(found, hasLength(6), reason: '$t');
          for (final flake in found) {
            expect(
              flake.visibleAlpha,
              closeTo(_twinkle(t), 1e-6),
              reason: '$t',
            );
            expect(flake.scale, closeTo(1.2, 1e-6));
          }
        }
        expect(_twinkle(3.3), closeTo(0.55, 1e-6));
        expect(
          _twinkle(2.65),
          closeTo(1 - 0.45 * Curves.easeInOut.transform(0.5), 1e-9),
        );
      });

      test('the layers follow the lab order', () {
        final canvas = at(1.85);
        final pair = bars(canvas);
        final six = flakes(canvas);
        expect(six, hasLength(6));
        _expectOrder(canvas, [
          track(canvas),
          _single(arc(canvas)),
          discFill(canvas),
          discRim(canvas),
          pair.first,
          pair.last,
          _single(glint(canvas)),
          ...six,
        ]);
      });

      test('still: whole ice arc, frozen disc, full bars, no glint, any t', () {
        for (final t in [0.0, 1.09, 1.85, 3.3, 1e6]) {
          final canvas = at(t, still: true);
          final whole = _single(arc(canvas));
          expect(whole.length, closeTo(_ringLength, 0.3));
          expect(_same(whole.paint.color, colors.ice), isTrue);
          expect(discFill(canvas).center, _at(_center));
          expect(_same(discFill(canvas).paint.color, colors.iceWeak), isTrue);
          expect(_same(discRim(canvas).paint.color, colors.ice), isTrue);
          final pair = bars(canvas);
          expect(pair, hasLength(2));
          for (final bar in pair) {
            expect(bar.visibleAlpha, closeTo(1, 1e-9));
            expect(bar.scale, closeTo(1, 1e-9));
            expect(_same(bar.paint.color, colors.ice), isTrue);
          }
          expect(glint(canvas), isEmpty);
          final six = flakes(canvas);
          expect(six, hasLength(6));
          for (final flake in six) {
            expect(flake.visibleAlpha, closeTo(1, 1e-9));
            expect(flake.scale, closeTo(1.2, 1e-9));
            _expectAngle(flake.angle, 0);
          }
        }
      });

      test('at introEnd all but the twinkle looks as it does still', () {
        final end = stageSpecOf(StageScene.paused, const StageInput()).introEnd;
        bool notFlake(_Draw draw) =>
            !(draw.name == #drawPath &&
                (draw.paint.strokeWidth - 1.7).abs() < 1e-6);
        final moving = at(end);
        final still = at(end, still: true);
        expect(
          _picture(moving, where: notFlake),
          _picture(still, where: notFlake),
        );
        expect(
          _picture(moving, where: (d) => !notFlake(d), alpha: false),
          _picture(still, where: (d) => !notFlake(d), alpha: false),
        );
        for (final flake in flakes(moving)) {
          expect(flake.visibleAlpha, closeTo(_twinkle(end), 1e-6));
        }
      });

      test('uses only colours of NbColors, glint in onPrimary at 50 %', () {
        for (final (t, still) in [
          (0.5, false),
          (1.85, false),
          (3.0, false),
          (0.5, true),
        ]) {
          _expectOnly(at(t, still: still), [
            colors.stageTrack,
            colors.textWeak,
            colors.ice,
            colors.stageWeak,
            colors.iceWeak,
            colors.stageBorder,
            colors.onPrimary,
          ]);
        }
      });

      test('draws no text, on the iceWeak disc or anywhere else', () {
        for (final (t, still) in [
          (0.5, false),
          (1.85, false),
          (3.0, false),
          (0.0, true),
        ]) {
          final calls = at(t, still: still).calls;
          expect(calls, isNot(contains(#drawParagraph)));
          for (final call in calls) {
            expect(_allowedCalls.contains(call), isTrue, reason: '$call');
          }
        }
      });

      testWidgets('the glint shows inside the disc and is cut outside it', (
        tester,
      ) async {
        const inside = Offset(167, 65);
        const outside = Offset(175, 44);
        void during(Canvas canvas) =>
            paintPaused(canvas, _frame(colors, t: 1.85));
        void after(Canvas canvas) => paintPaused(canvas, _frame(colors, t: 3));
        final lit = await _pixel(tester, during, inside);
        final plain = await _pixel(tester, after, inside);
        expect(
          _premultipliedSum(lit),
          greaterThan(_premultipliedSum(plain) + 10),
        );
        expect((await _pixel(tester, during, outside)).a, 0);
        expect((await _pixel(tester, after, outside)).a, 0);
      });
    });

    group('E285 paintCancelledByPeer ($theme)', () {
      _StageCanvas at(double t, {bool still = false}) =>
          _paint(paintCancelledByPeer, _frame(colors, t: t, still: still));
      List<_Draw> strokes(_StageCanvas c) => _paths(c, 6.5, colors.danger);
      const length = 30 * math.sqrt2;

      test('track, danger arc drawn in 0.7 s and a dangerWeak disc', () {
        final canvas = at(0.35);
        final track = _single(_circles(canvas, 56, stroked: true, at: _center));
        expect(_same(track.paint.color, colors.stageTrack), isTrue);
        expect(track.paint.strokeWidth, closeTo(5, 1e-6));
        final arc = _single(_paths(canvas, 5));
        expect(_same(arc.paint.color, colors.danger), isTrue);
        expect(arc.paint.strokeCap, StrokeCap.round);
        expect(arc.length, closeTo(0.5 * _ringLength, 0.3));
        expect(arc.start, _at(const Offset(150, 29), 1e-3));
        expect(arc.end, _at(const Offset(150, 141), 1e-3));
        final disc = _single(_circles(canvas, 42, stroked: false, at: _center));
        expect(_same(disc.paint.color, colors.dangerWeak), isTrue);
        expect(disc.paint.shader, isNull);
        expect(_circles(canvas, 42, stroked: true), isEmpty);
        expect(_single(_paths(at(1.5), 5)).length, closeTo(_ringLength, 0.3));
      });

      test('the X is two 6.5 danger strokes drawn at 0.5 and 0.78 s', () {
        expect(strokes(at(0.4)), isEmpty);
        expect(strokes(at(0.5)), isEmpty);
        final first = _single(strokes(at(0.725)));
        expect(first.length, closeTo(0.5 * length, 1e-3));
        expect(first.start, _at(const Offset(135, 70), 1e-6));
        expect(first.end, _at(_center, 1e-3));
        expect(first.paint.strokeCap, StrokeCap.round);
        final both = strokes(at(1.0));
        expect(both, hasLength(2));
        expect(both.first.start, _at(const Offset(135, 70), 1e-6));
        expect(both.first.end, _at(const Offset(165, 100), 1e-3));
        final k = labEaseInOut.transform((1.0 - 0.78) / 0.45);
        expect(both.last.start, _at(const Offset(165, 70), 1e-6));
        expect(both.last.end, _at(Offset(165 - 30 * k, 70 + 30 * k), 1e-3));
        final done = strokes(at(1.23));
        expect(done, hasLength(2));
        for (final stroke in done) {
          expect(stroke.length, closeTo(length, 1e-3));
        }
        expect(done.last.end, _at(const Offset(135, 100), 1e-3));
      });

      test('the layers follow the lab order', () {
        final canvas = at(1.1);
        final x = strokes(canvas);
        _expectOrder(canvas, [
          _single(_circles(canvas, 56, stroked: true, at: _center)),
          _single(_paths(canvas, 5)),
          _single(_circles(canvas, 42, stroked: false, at: _center)),
          x.first,
          x.last,
        ]);
      });

      test('still: the final drawing at any time', () {
        for (final t in [0.0, 0.6, 1e6]) {
          final canvas = at(t, still: true);
          expect(_single(_paths(canvas, 5)).length, closeTo(_ringLength, 0.3));
          final x = strokes(canvas);
          expect(x, hasLength(2));
          for (final stroke in x) {
            expect(stroke.length, closeTo(length, 1e-3));
          }
        }
      });

      test('uses only colours of NbColors', () {
        for (final (t, still) in [(0.3, false), (0.9, false), (0.0, true)]) {
          _expectOnly(at(t, still: still), [
            colors.stageTrack,
            colors.danger,
            colors.dangerWeak,
          ]);
        }
      });
    });

    group('E285 paintExpired ($theme)', () {
      _StageCanvas at(double t, {bool still = false}) =>
          _paint(paintExpired, _frame(colors, t: t, still: still));
      List<_Draw> ring(_StageCanvas c) => _paths(c, 5, colors.warningRing);
      _Draw needle(_StageCanvas c) => _single(_paths(c, 4, colors.text));
      Offset tip(double angle) =>
          Offset(150 + 26 * math.sin(angle), 85 - 26 * math.cos(angle));

      test('the warningRing ring empties clockwise from the top', () {
        for (final t in [0.0, 0.15]) {
          final whole = _single(ring(at(t)));
          expect(whole.length, closeTo(_ringLength, 0.3));
          expect(whole.start, _at(const Offset(150, 29), 1e-3));
        }
        for (final k in [0.25, 0.5, 0.75]) {
          final found = _single(ring(at(0.15 + 1.4 * k)));
          final gone = labEaseInOut.transform(k);
          expect(
            found.length,
            closeTo((1 - gone) * _ringLength, 0.3),
            reason: '$k',
          );
          expect(found.start, _at(_onCircle(_center, 56, _tau * gone), 0.3));
          expect(found.end, _at(const Offset(150, 29), 1e-3));
          expect(found.paint.strokeCap, StrokeCap.round);
          expect(_same(found.paint.color, colors.warningRing), isTrue);
        }
        expect(
          _single(ring(at(0.85))).start,
          _at(const Offset(150, 141), 1e-3),
        );
        for (final t in [1.55, 3.0]) {
          expect(ring(at(t)), isEmpty, reason: '$t');
        }
        final track = _single(
          _circles(at(0.5), 56, stroked: true, at: _center),
        );
        expect(_same(track.paint.color, colors.stageTrack), isTrue);
        expect(track.paint.strokeWidth, closeTo(5, 1e-6));
      });

      test('the disc of 42 has the node gradient and a stageBorder rim', () {
        final canvas = at(0.5);
        expect(
          _single(_circles(canvas, 42, stroked: false, at: _center))
              .paint
              .shader,
          isNotNull,
        );
        final rim = _single(_circles(canvas, 42, stroked: true, at: _center));
        expect(_same(rim.paint.color, colors.stageBorder), isTrue);
        expect(rim.paint.strokeWidth, closeTo(1.6, 1e-6));
      });

      test('four stageHint marks of 5 px at 33 px from the centre', () {
        final marks = _single(_paths(at(0.5), 2.4));
        expect(_same(marks.paint.color, colors.stageHint), isTrue);
        expect(marks.paint.strokeCap, StrokeCap.round);
        final pieces = marks.metrics;
        expect(pieces, hasLength(4));
        const ends = [
          (Offset(150, 52), Offset(150, 57)),
          (Offset(183, 85), Offset(178, 85)),
          (Offset(150, 118), Offset(150, 113)),
          (Offset(117, 85), Offset(122, 85)),
        ];
        for (var i = 0; i < 4; i++) {
          expect(pieces[i].length, closeTo(5, 1e-6));
          expect(
            marks.map(pieces[i].getTangentForOffset(0)!.position),
            _at(ends[i].$1),
          );
          expect(
            marks.map(pieces[i].getTangentForOffset(5)!.position),
            _at(ends[i].$2, 1e-6),
          );
        }
      });

      test('the needle sweeps from -360 deg to 0 with the ring', () {
        for (final t in [0.0, 0.15, 0.5, 0.85, 1.2, 1.55, 3.0]) {
          final found = needle(at(t));
          final gone = _ph(t, 0.15, 1.4, labEaseInOut);
          final angle = -_tau * (1 - gone);
          _expectAngle(found.angle, angle, reason: '$t');
          expect(found.map(_center), _at(_center, 1e-6));
          expect(found.start, _at(_center, 1e-6));
          expect(found.end, _at(tip(angle), 1e-6));
          expect(found.paint.strokeCap, StrokeCap.round);
          expect(found.length, closeTo(26, 1e-6));
        }
        expect(needle(at(0.85)).end, _at(const Offset(150, 111), 1e-6));
      });

      test('a text dot of 4.5 sits at the centre', () {
        final dot = _single(
          _circles(at(0.5), 4.5, stroked: false, at: _center),
        );
        expect(_same(dot.paint.color, colors.text), isTrue);
      });

      test('the layers follow the lab order', () {
        final canvas = at(0.8);
        _expectOrder(canvas, [
          _single(_circles(canvas, 56, stroked: true, at: _center)),
          _single(ring(canvas)),
          _single(_circles(canvas, 42, stroked: false, at: _center)),
          _single(_circles(canvas, 42, stroked: true, at: _center)),
          _single(_paths(canvas, 2.4)),
          needle(canvas),
          _single(_circles(canvas, 4.5, stroked: false, at: _center)),
        ]);
      });

      test('still: empty ring and the needle at 0 deg, at any time', () {
        for (final t in [0.0, 0.5, 0.85, 1e6]) {
          final canvas = at(t, still: true);
          expect(ring(canvas), isEmpty);
          final found = needle(canvas);
          _expectAngle(found.angle, 0);
          expect(found.end, _at(const Offset(150, 59), 1e-6));
        }
      });

      test('uses only colours of NbColors', () {
        for (final (t, still) in [(0.1, false), (0.9, false), (0.0, true)]) {
          _expectOnly(
            at(t, still: still),
            [
              colors.stageTrack,
              colors.warningRing,
              colors.stageBorder,
              colors.stageHint,
              colors.text,
            ],
            discs: {42},
          );
        }
      });
    });

    group('E285 paintLost ($theme)', () {
      _StageCanvas at(
        double t, {
        bool still = false,
        DeviceGlyph peer = DeviceGlyph.pc,
      }) => _paint(paintLost, _frame(colors, t: t, still: still, peer: peer));
      _Draw base(_StageCanvas c) =>
          _single(_paths(c, 1.6, colors.stageDashedRing));
      List<_Draw> warningRing(_StageCanvas c) => _paths(c, 2.6, colors.warning);
      List<_Draw> wifi(_StageCanvas c) => _paths(c, 3, colors.primary);
      _Draw body(_StageCanvas c) =>
          _single(_circles(c, 41, stroked: false, at: _lostCenter));
      _Draw rim(_StageCanvas c) =>
          _single(_circles(c, 41, stroked: true, at: _lostCenter));

      ({_Draw curve, _Draw dot})? mark(_StageCanvas c, Offset at) {
        final curves = [
          for (final path in _paths(c, 3, colors.warning))
            if ((path.map(Offset.zero) - at).distance < 12) path,
        ];
        final dots = [
          for (final dot in _circles(c, 1.9, stroked: false))
            if (_sameRgb(dot.paint.color, colors.warning) &&
                (dot.center - at).distance < 25)
              dot,
        ];
        expect(curves.length, dots.length);
        expect(curves.length, lessThanOrEqualTo(1));
        return curves.isEmpty ? null : (curve: curves.single, dot: dots.single);
      }

      test('the base ring is stageDashedRing at (150, 101) and stays put', () {
        for (final t in [0.0, 3.0, 7.7]) {
          final found = base(at(t));
          expect(_same(found.paint.color, colors.stageDashedRing), isTrue);
          _expectAngle(_dashStartAngle(found, _lostCenter), 0, reason: '$t');
          expect(_ringRadius(found), closeTo(56, 0.5));
          expect(
            _mapRect(found.matrix, found.path.getBounds()).center,
            _at(_lostCenter, 0.5),
          );
          for (final dash in _dashLengths(found)) {
            expect(dash, lessThanOrEqualTo(2 * 1.03));
          }
        }
      });

      test('the warning ring fades in at 1.45 s and turns in 14 s', () {
        for (final t in [0.0, 1.0, 1.45]) {
          expect(warningRing(at(t)), isEmpty, reason: '$t');
        }
        for (final (t, opacity) in [
          (1.75, Curves.ease.transform(0.5)),
          (2.05, 1.0),
          (3.5, 1.0),
          (7.0, 1.0),
          (17.5, 1.0),
        ]) {
          final found = _single(warningRing(at(t)), '$t');
          expect(found.visibleAlpha, closeTo(colors.warning.a * opacity, 1e-6));
          expect(found.paint.strokeCap, StrokeCap.round);
          _expectAngle(
            _dashStartAngle(found, _lostCenter),
            _tau * (t % 14) / 14,
            reason: '$t',
          );
          expect(_ringRadius(found), closeTo(56, 0.5));
          final dashes = _dashLengths(found);
          expect(dashes.length, closeTo(_ring / 14, 1.5));
          for (final dash in dashes) {
            expect(dash, lessThanOrEqualTo(7 * 1.03));
          }
        }
      });

      test('the peer disc of 41 dims to 30 % from 1.35 s', () {
        for (final (t, opacity) in [
          (0.0, 1.0),
          (1.35, 1.0),
          (1.7, 1 - 0.7 * Curves.ease.transform(0.5)),
          (2.05, 0.3),
          (5.0, 0.3),
        ]) {
          final canvas = at(t);
          expect(body(canvas).paint.shader, isNotNull);
          expect(
            body(canvas).visibleAlpha,
            closeTo(opacity, 1e-6),
            reason: '$t',
          );
          expect(_same(rim(canvas).paint.color, colors.stageBorder), isTrue);
          expect(rim(canvas).paint.strokeWidth, closeTo(1.6, 1e-6));
          expect(rim(canvas).visibleAlpha, closeTo(opacity, 1e-6));
          for (final path in _glyphPathsNear(canvas, _lostCenter)) {
            expect(path.alpha, closeTo(opacity, 1e-6));
          }
        }
        for (final peer in DeviceGlyph.values) {
          final canvas = at(0.5, peer: peer);
          _expectSameGlyph(
            _glyphStrokes(_glyphPathsNear(canvas, _lostCenter)),
            _referenceGlyph(
              peer == DeviceGlyph.phone ? Glyphs.phone : Glyphs.pc,
              _lostCenter,
              41,
              colors.text,
            ),
          );
        }
      });

      test('three primary wifi arcs at (179, 72) seek 0.12 s apart', () {
        expect(wifi(at(0)), isEmpty);
        expect(wifi(at(1.6)), isEmpty);
        expect(wifi(at(3)), isEmpty);
        final arcs = wifi(at(0.5));
        expect(arcs, hasLength(3));
        const radii = [10.0, 19.0, 28.0];
        for (var i = 0; i < 3; i++) {
          final r = radii[i];
          final arc = arcs.singleWhere(
            (a) => ((a.start - _wifiCenter).distance - r).abs() < 0.05,
          );
          expect(
            arc.start,
            _at(
              _wifiCenter +
                  Offset(r * math.cos(-88 * _deg), r * math.sin(-88 * _deg)),
              1e-3,
            ),
          );
          expect(
            arc.end,
            _at(
              _wifiCenter +
                  Offset(r * math.cos(-2 * _deg), r * math.sin(-2 * _deg)),
              1e-3,
            ),
          );
          final middle = arc.map(
            arc.metrics.single
                .getTangentForOffset(arc.localLength / 2)!
                .position,
          );
          expect(
            middle,
            _at(
              _wifiCenter +
                  Offset(r * math.cos(-45 * _deg), r * math.sin(-45 * _deg)),
              1e-2,
            ),
          );
          expect(arc.paint.strokeCap, StrokeCap.round);
        }
        for (var i = 0; i < 3; i++) {
          for (final local in [0.15, 0.25, 0.35, 0.5, 0.6, 0.7, 0.85, 0.95]) {
            final t = 0.12 * i + 1.3 * local;
            final expected = _seek(t, i);
            final found = [
              for (final a in wifi(at(t)))
                if (((a.start - _wifiCenter).distance - radii[i]).abs() < 0.05)
                  a,
            ];
            expect(found, hasLength(1), reason: '$i $local');
            expect(
              found.single.visibleAlpha,
              closeTo(colors.primary.a * expected, 1e-6),
              reason: '$i $local',
            );
          }
        }
        expect(_seek(0.12 + 1.3 * 0.35, 1), closeTo(0.25, 1e-9));
      });

      test('three warning question marks pop in at 1.9, 2.0 and 2.15 s', () {
        for (final t in [0.0, 1.0, 1.85, 1.9]) {
          expect(_paths(at(t), 3, colors.warning), isEmpty, reason: '$t');
        }
        for (final (where, delay, _) in _marks) {
          final t = delay + 0.25;
          final found = mark(at(t), where)!;
          final appear = labEaseOut.transform(0.5);
          final s = 0.6 + 0.4 * appear;
          final lift = 8 * (1 - appear);
          expect(
            found.curve.map(Offset.zero),
            _at(where + _markPivot * (1 - s) + Offset(0, lift), 0.02),
          );
          expect(found.curve.scale, closeTo(1.2 * s, 1e-6));
          expect(found.curve.visibleAlpha, closeTo(appear, 1e-6));
          expect(found.dot.visibleAlpha, closeTo(appear, 1e-6));
          expect(
            found.dot.center,
            _at(found.curve.map(const Offset(0, 9)), 1e-6),
          );
          expect(found.curve.paint.strokeCap, StrokeCap.round);
          expect(
            found.curve.start,
            _at(found.curve.map(const Offset(-5.5, -6.5)), 1e-6),
          );
          expect(
            found.curve.end,
            _at(found.curve.map(const Offset(0, 3)), 1e-3),
          );
        }
      });

      test(
        'the question marks float 3 px on 2.4 s loops from 2.4, 3.2, 2.8',
        () {
          for (final (where, _, floatDelay) in _marks) {
            for (final offset in [0.0, 0.6, 1.2, 1.8, 2.4, 7.8]) {
              final t = floatDelay + offset;
              final found = mark(at(t), where)!;
              expect(
                found.curve.map(Offset.zero),
                _at(where + Offset(0, _float(t, floatDelay)), 1e-6),
                reason: '$where $t',
              );
              expect(found.curve.scale, closeTo(1.2, 1e-6));
              expect(found.curve.visibleAlpha, closeTo(1, 1e-6));
            }
            expect(_float(floatDelay + 1.2, floatDelay), closeTo(-3, 1e-5));
          }
          final early = mark(at(3.0), _marks[1].$1)!;
          expect(early.curve.map(Offset.zero), _at(_marks[1].$1, 1e-6));
          final rest = mark(at(2.7), _marks[2].$1)!;
          expect(rest.curve.map(Offset.zero), _at(_marks[2].$1, 1e-6));
        },
      );

      test('the layers follow the lab order', () {
        final early = at(1.5);
        final arcs = wifi(early);
        expect(arcs, isNotEmpty);
        _expectOrder(early, [
          base(early),
          _single(warningRing(early)),
          body(early),
          rim(early),
          ...arcs,
        ]);
        final late = at(2.3);
        _expectOrder(late, [
          base(late),
          _single(warningRing(late)),
          body(late),
          for (final (where, _, _) in _marks) mark(late, where)!.curve,
        ]);
      });

      test(
        'still: no wifi, ring whole at rest, disc at 30 %, marks at rest',
        () {
          for (final t in [0.0, 0.5, 1.75, 3.6, 1e6]) {
            final canvas = at(t, still: true);
            expect(wifi(canvas), isEmpty, reason: '$t');
            final ring = _single(warningRing(canvas));
            expect(ring.visibleAlpha, closeTo(colors.warning.a, 1e-6));
            _expectAngle(_dashStartAngle(ring, _lostCenter), 0);
            expect(body(canvas).visibleAlpha, closeTo(0.3, 1e-6));
            for (final (where, _, _) in _marks) {
              final found = mark(canvas, where)!;
              expect(found.curve.map(Offset.zero), _at(where, 1e-6));
              expect(found.curve.scale, closeTo(1.2, 1e-6));
              expect(found.curve.visibleAlpha, closeTo(1, 1e-6));
            }
          }
        },
      );

      test('at introEnd all but the turning ring and the floating first mark '
          'looks as it does still', () {
        final end = stageSpecOf(StageScene.lost, const StageInput()).introEnd;
        final moving = at(end);
        final still = at(end, still: true);
        bool turning(_Draw d) =>
            d.name == #drawPath && (d.paint.strokeWidth - 2.6).abs() < 1e-6;
        bool floating(_Draw d) =>
            (d.stageBounds.center - _marks.first.$1).distance < 20;
        bool fixed(_Draw d) => !turning(d) && !floating(d);
        expect(_picture(moving, where: fixed), _picture(still, where: fixed));
        expect(
          _picture(moving, where: turning, matrix: false),
          _picture(still, where: turning, matrix: false),
        );
        expect(_picture(moving, where: fixed), isNotEmpty);
      });

      test('uses only colours of NbColors', () {
        for (final (t, still) in [
          (0.5, false),
          (1.75, false),
          (3.6, false),
          (0.0, true),
        ]) {
          _expectOnly(
            at(t, still: still),
            [
              colors.stageDashedRing,
              colors.warning,
              colors.stageBorder,
              colors.text,
              colors.primary,
            ],
            discs: {41},
          );
        }
      });
    });

    group('E285 paintNetworkChanged ($theme)', () {
      _StageCanvas at(double t, {bool still = false}) =>
          _paint(paintNetworkChanged, _frame(colors, t: t, still: still));
      List<_Draw> waves(_StageCanvas c) => _paths(c, 4.2);
      _Draw slash(_StageCanvas c) => _single(_paths(c, 4.5, colors.danger));
      const shapes = [
        (Offset(126, 81), Offset(174, 81), Offset(150, 71.083), 0.35),
        (Offset(135, 90), Offset(165, 90), Offset(150, 83.697), 0.2),
        (Offset(143, 98.5), Offset(157, 98.5), Offset(150, 95.157), 0.05),
      ];

      _Draw wave(_StageCanvas c, Offset start) =>
          _single(waves(c).where((w) => _near(w.start, start, 1e-3)).toList());

      test('the base ring is stageDashedRing, 56, 2 8, and stays put', () {
        for (final t in [0.0, 2.5, 9.0]) {
          final found = _single(_paths(at(t), 1.6, colors.stageDashedRing));
          expect(_same(found.paint.color, colors.stageDashedRing), isTrue);
          _expectAngle(_dashStartAngle(found, _center), 0);
          expect(_ringRadius(found), closeTo(56, 0.5));
          for (final dash in _dashLengths(found)) {
            expect(dash, lessThanOrEqualTo(2 * 1.03));
          }
        }
      });

      test('the empty disc of 44 has the node gradient and a rim', () {
        final canvas = at(0.5);
        expect(
          _single(_circles(canvas, 44, stroked: false, at: _center))
              .paint
              .shader,
          isNotNull,
        );
        final rim = _single(_circles(canvas, 44, stroked: true, at: _center));
        expect(_same(rim.paint.color, colors.stageBorder), isTrue);
      });

      test('three 4.2 waves at (150, 89) are the lab arcs', () {
        final canvas = at(2);
        expect(waves(canvas), hasLength(3));
        for (final (start, end, middle, _) in shapes) {
          final found = wave(canvas, start);
          expect(found.end, _at(end, 1e-3));
          expect(
            found.map(
              found.metrics.single
                  .getTangentForOffset(found.localLength / 2)!
                  .position,
            ),
            _at(middle, 1e-2),
          );
          expect(found.paint.strokeCap, StrokeCap.round);
        }
      });

      test('each wave goes primary to textWeak with wv, 0.15 s apart', () {
        for (final (start, _, _, delay) in shapes) {
          for (final local in [
            -0.03,
            0.15,
            0.3,
            0.45,
            0.6,
            0.75,
            0.85,
            0.925,
            1.0,
            1.2,
          ]) {
            final t = math.max(0.0, delay + 1.25 * local);
            final p = _progress(t, delay, 1.25);
            final opacity = _kf(p, const [
              (0, 0.2),
              (0.3, 1),
              (0.6, 0.35),
              (0.85, 1),
              (1, 1),
            ], Curves.ease);
            final settle = _kf(p, const [
              (0, 0),
              (0.85, 0),
              (1, 1),
            ], Curves.ease);
            final expected = Color.lerp(
              colors.primary,
              colors.textWeak,
              settle,
            )!;
            final found = wave(at(t), start);
            expect(
              found.visibleAlpha,
              closeTo(opacity * expected.a, 1e-6),
              reason: '$delay $local',
            );
            expect(
              _sameRgb(found.paint.color, expected),
              isTrue,
              reason: '$delay $local',
            );
          }
        }
        final first = wave(at(0), shapes.first.$1);
        expect(first.visibleAlpha, closeTo(0.2, 1e-6));
        expect(_sameRgb(first.paint.color, colors.primary), isTrue);
      });

      test('the danger slash draws itself at 1.3 s up to the right', () {
        expect(_paths(at(1.2), 4.5), isEmpty);
        expect(_paths(at(1.3), 4.5), isEmpty);
        final half = slash(at(1.3 + 0.225));
        expect(half.start, _at(const Offset(124, 111), 1e-6));
        expect(half.end, _at(_center, 1e-3));
        expect(half.paint.strokeCap, StrokeCap.round);
        final whole = slash(at(1.75));
        expect(whole.length, closeTo(52 * math.sqrt2, 1e-3));
        expect(whole.end, _at(const Offset(176, 59), 1e-3));
      });

      test('the layers follow the lab order', () {
        final canvas = at(1.6);
        _expectOrder(canvas, [
          _single(_paths(canvas, 1.6, colors.stageDashedRing)),
          _single(_circles(canvas, 44, stroked: false, at: _center)),
          _single(_circles(canvas, 44, stroked: true, at: _center)),
          for (final (start, _, _, _) in shapes) wave(canvas, start),
          slash(canvas),
        ]);
      });

      test('still: the final drawing at any time', () {
        for (final t in [0.0, 0.6, 1e6]) {
          final canvas = at(t, still: true);
          for (final (start, _, _, _) in shapes) {
            final found = wave(canvas, start);
            expect(_same(found.paint.color, colors.textWeak), isTrue);
          }
          expect(slash(canvas).length, closeTo(52 * math.sqrt2, 1e-3));
        }
      });

      test('uses only colours of NbColors', () {
        for (final (t, still) in [(0.5, false), (1.7, false), (0.0, true)]) {
          _expectOnly(
            at(t, still: still),
            [
              colors.stageDashedRing,
              colors.stageBorder,
              colors.primary,
              colors.textWeak,
              colors.danger,
            ],
            discs: {44},
          );
        }
      });
    });

    group('E285 paintFailed ($theme)', () {
      _StageCanvas at(double t, {bool still = false}) =>
          _paint(paintFailed, _frame(colors, t: t, still: still));
      _Draw disc(_StageCanvas c) => _single(_circles(c, 44, stroked: false));
      List<_Draw> lines(_StageCanvas c) => _paths(c, 4.4, colors.danger);
      _Draw? triangle(_StageCanvas c) {
        final found = [
          for (final l in lines(c))
            if (l.path.getBounds().width > 1e-3) l,
        ];
        expect(found.length, lessThanOrEqualTo(1));
        return found.isEmpty ? null : found.single;
      }

      _Draw? stroke(_StageCanvas c) {
        final found = [
          for (final l in lines(c))
            if (l.path.getBounds().width <= 1e-3) l,
        ];
        expect(found.length, lessThanOrEqualTo(1));
        return found.isEmpty ? null : found.single;
      }

      List<_Draw> dot(_StageCanvas c) => _circles(c, 2.8, stroked: false);
      final perimeter = 2 * math.sqrt(26 * 26 + 46 * 46) + 52;

      test('the danger ring at 30 % of 2.2 stays put', () {
        for (final t in [0.5, 0.834, 0.918, 1.5]) {
          final ring = _single(_circles(at(t), 56, stroked: true, at: _center));
          expect(_same(ring.paint.color, _alpha(colors.danger, 0.3)), isTrue);
          expect(ring.visibleAlpha, closeTo(colors.danger.a * 0.3, 1e-6));
          expect(ring.paint.strokeWidth, closeTo(2.2, 1e-6));
          _expectSameMatrix(ring.matrix, Matrix4.identity());
        }
      });

      test('the group shakes 0.42 s from 0.75 s: -4, 4, -3 and 2 px', () {
        for (final (local, dx) in [
          (0.0, 0.0),
          (0.1, -4 * labShake.transform(0.5)),
          (0.2, -4.0),
          (0.3, -4 + 8 * labShake.transform(0.5)),
          (0.4, 4.0),
          (0.6, -3.0),
          (0.8, 2.0),
          (0.9, 2 - 2 * labShake.transform(0.5)),
          (1.0, 0.0),
        ]) {
          final t = 0.75 + 0.42 * local;
          final canvas = at(t);
          expect(
            disc(canvas).center,
            _at(Offset(150 + _shake(t), 85), 1e-6),
            reason: '$local',
          );
          expect(_shake(t), closeTo(dx, 1e-3));
          expect(
            triangle(canvas)!.start,
            _at(Offset(150 + _shake(t), 59), 1e-6),
          );
        }
        for (final t in [0.5, 1.17, 1.3, 9.0]) {
          expect(disc(at(t)).center, _at(_center, 1e-3), reason: '$t');
        }
        expect(_same(disc(at(1)).paint.color, colors.dangerWeak), isTrue);
      });

      test('the triangle draws in 0.45 s and the stroke at 0.5 s', () {
        expect(triangle(at(0)), isNull);
        final half = triangle(at(0.225))!;
        expect(half.length, closeTo(perimeter / 2, 1e-2));
        expect(half.start, _at(const Offset(150, 59), 1e-6));
        expect(half.end, _at(const Offset(150, 105), 1e-2));
        expect(half.paint.strokeJoin, StrokeJoin.round);
        final whole = triangle(at(0.45))!;
        expect(whole.length, closeTo(perimeter, 1e-2));
        expect(stroke(at(0.4)), isNull);
        expect(stroke(at(0.5)), isNull);
        final mid = stroke(at(0.725))!;
        expect(mid.start, _at(const Offset(150, 76), 1e-6));
        expect(mid.end, _at(const Offset(150, 82), 1e-3));
        expect(mid.paint.strokeCap, StrokeCap.round);
        final full = stroke(at(1.0))!;
        expect(full.end, _at(Offset(150 + _shake(1.0), 88), 1e-3));
        expect(full.length, closeTo(12, 1e-3));
      });

      test('the dot pops in at 0.85 s at (150, 96)', () {
        expect(dot(at(0.8)), isEmpty);
        expect(dot(at(0.85)), isEmpty);
        for (final t in [0.85 + 0.45 * 0.3, 0.85 + 0.45 * 0.6, 1.3, 3.0]) {
          final found = _single(dot(at(t)), '$t');
          final pop = _pop(t, 0.85);
          expect(found.center, _at(Offset(150 + _shake(t), 96), 1e-6));
          expect(found.radius, closeTo(2.8 * pop.scale, 1e-6), reason: '$t');
          expect(found.visibleAlpha, closeTo(pop.opacity, 1e-6), reason: '$t');
          expect(_sameRgb(found.paint.color, colors.danger), isTrue);
        }
      });

      test('the layers follow the lab order', () {
        final canvas = at(1.1);
        _expectOrder(canvas, [
          _single(_circles(canvas, 56, stroked: true, at: _center)),
          disc(canvas),
          triangle(canvas)!,
          stroke(canvas)!,
          _single(dot(canvas)),
        ]);
      });

      test('still: the final drawing at any time', () {
        for (final t in [0.0, 0.834, 1e6]) {
          final canvas = at(t, still: true);
          expect(disc(canvas).center, _at(_center));
          expect(triangle(canvas)!.length, closeTo(perimeter, 1e-2));
          expect(stroke(canvas)!.length, closeTo(12, 1e-3));
          final found = _single(dot(canvas));
          expect(found.radius, closeTo(2.8, 1e-9));
          expect(found.visibleAlpha, closeTo(1, 1e-9));
        }
      });

      test('uses only colours of NbColors', () {
        for (final (t, still) in [(0.3, false), (0.9, false), (0.0, true)]) {
          _expectOnly(at(t, still: still), [colors.danger, colors.dangerWeak]);
        }
      });
    });

    group('E285 paintNotSaved ($theme)', () {
      _StageCanvas at(double t, {bool still = false}) =>
          _paint(paintNotSaved, _frame(colors, t: t, still: still));
      _Draw disc(_StageCanvas c) => _single(_circles(c, 44, stroked: false));
      _Draw body(_StageCanvas c) => _single(_paths(c, 3.4, colors.danger));
      _Draw detail(_StageCanvas c) => _single(_paths(c, 2.8, colors.danger));
      List<_Draw> slash(_StageCanvas c) => _paths(c, 4.4, colors.danger);

      test('the danger ring at 30 % stays put and the group shakes', () {
        for (final local in [0.0, 0.2, 0.4, 0.6, 0.8, 1.0, 0.33]) {
          final t = 0.75 + 0.42 * local;
          final canvas = at(t);
          final ring = _single(
            _circles(canvas, 56, stroked: true, at: _center),
          );
          expect(_same(ring.paint.color, _alpha(colors.danger, 0.3)), isTrue);
          expect(ring.paint.strokeWidth, closeTo(2.2, 1e-6));
          expect(disc(canvas).center, _at(Offset(150 + _shake(t), 85), 1e-6));
          expect(_same(disc(canvas).paint.color, colors.dangerWeak), isTrue);
          expect(
            body(canvas).map(Offset.zero),
            _at(Offset(128 + _shake(t), 63), 1e-6),
          );
        }
      });

      test('the floppy sits at (128, 63): body 3.4, details 2.8 round', () {
        final canvas = at(2);
        final outline = body(canvas);
        expect(
          outline.path.getBounds(),
          _rect(const Rect.fromLTRB(0, 0, 40, 44), 1e-3),
        );
        expect(outline.paint.strokeJoin, StrokeJoin.miter);
        expect(outline.metrics, hasLength(1));
        expect(outline.localLength, closeTo(_floppyLength, 0.05));
        expect(outline.map(Offset.zero), _at(const Offset(128, 63)));
        final inner = detail(canvas);
        expect(
          inner.path.getBounds(),
          _rect(const Rect.fromLTRB(9, 0, 33, 44)),
        );
        expect(inner.paint.strokeJoin, StrokeJoin.round);
        expect(
          [for (final m in inner.metrics) m.length],
          [closeTo(40, 1e-6), closeTo(60, 1e-6)],
        );
        expect(inner.map(Offset.zero), _at(const Offset(128, 63)));
      });

      test('the slash draws itself at 0.5 s from (122, 113) to (178, 57)', () {
        expect(slash(at(0.4)), isEmpty);
        expect(slash(at(0.5)), isEmpty);
        final half = _single(slash(at(0.725)));
        expect(half.start, _at(const Offset(122, 113), 1e-6));
        expect(half.end, _at(_center, 1e-3));
        expect(half.paint.strokeCap, StrokeCap.round);
        final whole = _single(slash(at(1.17)));
        expect(whole.length, closeTo(56 * math.sqrt2, 1e-3));
        expect(whole.end, _at(Offset(178 + _shake(1.17), 57), 1e-3));
      });

      test('the layers follow the lab order', () {
        final canvas = at(1.0);
        _expectOrder(canvas, [
          _single(_circles(canvas, 56, stroked: true, at: _center)),
          disc(canvas),
          body(canvas),
          detail(canvas),
          _single(slash(canvas)),
        ]);
      });

      test('still: the final drawing at any time', () {
        for (final t in [0.0, 0.834, 1e6]) {
          final canvas = at(t, still: true);
          expect(disc(canvas).center, _at(_center));
          expect(_single(slash(canvas)).length, closeTo(56 * math.sqrt2, 1e-3));
        }
      });

      test('uses only colours of NbColors', () {
        for (final (t, still) in [(0.3, false), (0.9, false), (0.0, true)]) {
          _expectOnly(at(t, still: still), [colors.danger, colors.dangerWeak]);
        }
      });
    });

    group('E285 paintPairedRing ($theme)', () {
      _StageCanvas at(double t, {bool still = false}) =>
          _paint(paintPairedRing, _frame(colors, t: t, still: still));
      List<_Draw> track(_StageCanvas c) => _circles(c, 56, stroked: true);
      List<_Draw> arc(_StageCanvas c) => _paths(c, 5, colors.success);
      List<_Draw> rays(_StageCanvas c) => _paths(c, 2.6, colors.success);
      List<_Draw> disc(_StageCanvas c) => _circles(c, 42, stroked: false);
      List<_Draw> check(_StageCanvas c) => _paths(c, 7);
      final checkLength =
          math.sqrt(12 * 12 + 11.5 * 11.5) + math.sqrt(24 * 24 + 26 * 26);

      test('draws nothing still, from 1.95 s on or with t not a number', () {
        for (final t in [0.0, 0.5, 1.0, 1.9, 1e6]) {
          expect(at(t, still: true).draws, isEmpty, reason: '$t');
        }
        for (final t in [1.95, 2.0, 3.9, 1e9, double.infinity, double.nan]) {
          expect(at(t).draws, isEmpty, reason: '$t');
        }
      });

      test('the stageTrack ring and the success arc drawn in 0.7 s', () {
        final canvas = at(0.35);
        final ring = _single(track(canvas));
        expect(_same(ring.paint.color, colors.stageTrack), isTrue);
        expect(ring.paint.strokeWidth, closeTo(5, 1e-6));
        expect(ring.center, _at(_center));
        final drawn = _single(arc(canvas));
        expect(drawn.length, closeTo(0.5 * _ringLength, 0.3));
        expect(drawn.start, _at(const Offset(150, 29), 1e-3));
        expect(drawn.end, _at(const Offset(150, 141), 1e-3));
        expect(drawn.paint.strokeCap, StrokeCap.round);
        expect(_single(arc(at(1))).length, closeTo(_ringLength, 0.3));
      });

      test('eight success rays from 62 to 70 burst at 0.85 s', () {
        for (final t in [0.0, 0.8, 0.85, 1.55, 1.7]) {
          expect(rays(at(t)), isEmpty, reason: '$t');
        }
        for (final local in [0.125, 0.25, 0.625, 0.9]) {
          final t = 0.85 + 0.7 * local;
          final found = _single(rays(at(t)), '$local');
          final opacity = _kf(local, const [
            (0, 0),
            (0.25, 1),
            (1, 0),
          ], labEaseOut);
          final s = 0.82 + 0.4 * labEaseOut.transform(local);
          expect(found.visibleAlpha, closeTo(opacity, 1e-6), reason: '$local');
          expect(found.paint.strokeCap, StrokeCap.round);
          final pieces = found.metrics;
          expect(pieces, hasLength(8));
          for (var k = 0; k < 8; k++) {
            final angle = k * 45 * _deg;
            final direction = Offset(math.cos(angle), math.sin(angle));
            expect(
              found.map(pieces[k].getTangentForOffset(0)!.position),
              _at(_center + direction * (62 * s), 1e-4),
            );
            expect(
              found.map(
                pieces[k].getTangentForOffset(pieces[k].length)!.position,
              ),
              _at(_center + direction * (70 * s), 1e-4),
            );
          }
        }
      });

      test('the success disc springs in at 0.55 s and the check at 0.8 s', () {
        expect(disc(at(0.5)), isEmpty);
        expect(disc(at(0.55)), isEmpty);
        for (final local in [0.3, 0.6, 0.8, 1.0]) {
          final t = 0.55 + 0.5 * local;
          final found = _single(disc(at(t)), '$local');
          final p = _progress(t, 0.55, 0.5);
          final s = _kf(p, const [(0, 0.45), (0.6, 1.07), (1, 1)], labEaseOut);
          final opacity = _kf(p, const [(0, 0), (0.6, 1), (1, 1)], labEaseOut);
          expect(found.center, _at(_center, 1e-6));
          expect(found.radius, closeTo(42 * s, 1e-6), reason: '$local');
          expect(found.visibleAlpha, closeTo(opacity, 1e-6), reason: '$local');
          expect(_same(found.paint.color, colors.success), isTrue);
        }
        expect(check(at(0.8)), isEmpty);
        final half = _single(check(at(0.8 + 0.17)));
        expect(
          half.localLength,
          closeTo(labEaseOut.transform(0.5) * checkLength, 1e-3),
        );
        final whole = _single(check(at(1.2)));
        expect(whole.localLength, closeTo(checkLength, 1e-3));
        expect(whole.start, _at(const Offset(132, 86), 1e-6));
        expect(whole.end, _at(const Offset(168, 71.5), 1e-3));
        final corner = whole.metrics.single.getTangentForOffset(
          math.sqrt(12 * 12 + 11.5 * 11.5),
        )!;
        expect(whole.map(corner.position), _at(const Offset(144, 97.5), 1e-3));
        expect(_same(whole.paint.color, colors.onSuccessDisc), isTrue);
        expect(whole.paint.strokeCap, StrokeCap.round);
        expect(whole.paint.strokeJoin, StrokeJoin.round);
      });

      test(
        'the group holds to 80 % of 1.95 s, then shrinks to 0.35 and fades',
        () {
          for (final t in [0.0, 1.2, 1.56]) {
            final ring = _single(track(at(t)));
            expect(ring.radius, closeTo(56, 1e-6), reason: '$t');
            expect(ring.visibleAlpha, closeTo(1, 1e-6), reason: '$t');
          }
          for (final local in [0.25, 0.5, 0.9]) {
            final t = 1.56 + 0.39 * local;
            final k = Curves.ease.transform(local);
            final ring = _single(track(at(t)), '$local');
            expect(ring.center, _at(_center, 1e-6));
            expect(
              ring.radius,
              closeTo(56 * (1 - 0.65 * k), 1e-6),
              reason: '$local',
            );
            expect(ring.visibleAlpha, closeTo(1 - k, 1e-6), reason: '$local');
          }
        },
      );

      test('the layers follow the lab order', () {
        final canvas = at(1.1);
        _expectOrder(canvas, [
          _single(track(canvas)),
          _single(arc(canvas)),
          _single(rays(canvas)),
          _single(disc(canvas)),
          _single(check(canvas)),
        ]);
      });

      test('at introEnd of paired it draws nothing, as still', () {
        final end = stageSpecOf(StageScene.paired, const StageInput()).introEnd;
        expect(at(end).draws, isEmpty);
        expect(at(end, still: true).draws, isEmpty);
      });

      test('uses only colours of NbColors', () {
        for (final t in [0.3, 0.95, 1.1, 1.8]) {
          _expectOnly(at(t), [
            colors.stageTrack,
            colors.success,
            colors.onSuccessDisc,
          ]);
        }
      });
    });
  }

  group('E285 sound painting', () {
    for (final (theme, colors) in _themes) {
      for (final entry in _painters.entries) {
        test('${entry.key} never throws and stays sound at any t ($theme)', () {
          for (final t in _wild) {
            for (final still in [false, true]) {
              for (final peer in DeviceGlyph.values) {
                final canvas = _paint(
                  entry.value,
                  _frame(colors, t: t, still: still, peer: peer),
                );
                _expectSound(canvas, reason: '${entry.key} $t $still $peer');
              }
            }
          }
        });
      }
    }

    test('the layer check catches content outside its bounds', () {
      final canvas = _record((canvas) {
        canvas.saveLayer(const Rect.fromLTWH(0, 0, 10, 10), Paint());
        canvas.drawCircle(const Offset(20, 20), 2, Paint());
        canvas.restore();
      });
      final draw = canvas.draws.single;
      expect(_inside(draw.layers.single, draw.stageBounds), isFalse);
    });

    test('the clip check catches a clip outside any save', () {
      final canvas = _record((canvas) => canvas.clipPath(Path()));
      expect(canvas.clipsOutsideSave, 1);
    });
  });

  group('E285 scenes of stageForOutcome', () {
    test('every outcome but the two bridge scenes has its painter here', () {
      final scenes = {
        for (final outcome in [...PairingOutcome.values, null])
          stageForOutcome(outcome),
      };
      expect(scenes.difference(_outcomeScenes.keys.toSet()), {
        StageScene.paired,
        StageScene.rejected,
      });
      expect(_outcomeScenes.keys.toSet().difference(scenes), isEmpty);
    });

    for (final (theme, colors) in _themes) {
      for (final outcome in [...PairingOutcome.values, null]) {
        final scene = stageForOutcome(outcome);
        final painter = _outcomeScenes[scene];
        if (painter == null) continue;
        final spec = stageSpecOf(scene, const StageInput());

        List<String> picture(double t, {bool still = false}) =>
            _picture(_paint(painter, _frame(colors, t: t, still: still)));

        test('${outcome?.name ?? 'null'}: only loops live past introEnd + 0.1 '
            's ($theme)', () {
          final settled = spec.introEnd + 0.1;
          if (spec.loops) {
            expect(picture(settled), isNot(picture(settled + 0.37)));
            expect(picture(settled + 5), isNot(picture(settled + 5.61)));
          } else {
            final reference = picture(settled);
            for (final t in [settled + 0.4, settled + 7.3, 1e6]) {
              expect(picture(t), reference, reason: '$t');
            }
            expect(picture(0, still: true), reference);
          }
        });

        test('${outcome?.name ?? 'null'}: busy, paused and lost loop '
            '($theme)', () {
          expect(
            spec.loops,
            {
              StageScene.busy,
              StageScene.paused,
              StageScene.lost,
            }.contains(scene),
          );
        });

        test('${outcome?.name ?? 'null'}: still does not depend on t '
            '($theme)', () {
          final reference = picture(0, still: true);
          expect(reference, isNotEmpty);
          for (final t in [
            -5.0,
            0.7,
            1.3,
            2.4,
            9.0,
            1e9,
            double.infinity,
            double.nan,
          ]) {
            expect(picture(t, still: true), reference, reason: '$t');
          }
        });

        test('${outcome?.name ?? 'null'}: at introEnd the non-looping parts '
            'match still ($theme)', () {
          final moving = picture(spec.introEnd);
          final still = picture(0, still: true);
          if (!spec.loops) expect(moving, still);
          expect(moving.length, still.length);
        });

        if (spec.introEnd > 0) {
          test('${outcome?.name ?? 'null'}: the one-off animation is still '
              'running just before introEnd ($theme)', () {
            expect(
              picture(spec.introEnd - 0.05),
              isNot(picture(spec.introEnd)),
            );
          });
        }
      }
    }
  });

  group('E285 sources', () {
    const path = 'lib/src/ui/modal/stage_outcomes.dart';

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

    test('$path has no colour literal, Colors. or comment', () {
      final source = File(path).readAsStringSync();
      final code = _withoutStrings(source);
      expect(RegExp(r'\bColor\s*\(').hasMatch(code), isFalse);
      expect(RegExp(r'\bColor\.from').hasMatch(code), isFalse);
      expect(RegExp(r'0x[0-9A-Fa-f]{6,8}').hasMatch(code), isFalse);
      expect(RegExp(r'\bColors\.(?!transparent\b)').hasMatch(code), isFalse);
      expect(code.contains('//'), isFalse);
      expect(code.contains('/*'), isFalse);
    });

    test('$path exposes the nine painters with the scene signature', () {
      final source = File(path).readAsStringSync();
      for (final name in _painters.keys) {
        expect(
          RegExp('void $name\\(Canvas canvas, StageFrame frame\\)')
              .hasMatch(source),
          isTrue,
          reason: name,
        );
      }
    });
  });
}
