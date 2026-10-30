import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nexus_bridges/src/ui/icons/device_disc.dart';
import 'package:nexus_bridges/src/ui/icons/file_icon.dart';
import 'package:nexus_bridges/src/ui/icons/glyphs.dart';
import 'package:nexus_bridges/src/ui/modal/bridge.dart';
import 'package:nexus_bridges/src/ui/modal/stage.dart';
import 'package:nexus_bridges/src/ui/modal/stage_choices.dart';
import 'package:nexus_bridges/src/ui/modal/stage_kit.dart';
import 'package:nexus_bridges/src/ui/modal/stage_outcomes.dart';
import 'package:nexus_bridges/src/ui/modal/stage_waiting.dart';
import 'package:nexus_bridges/src/ui/theme/app_theme.dart';
import 'package:nexus_bridges/src/ui/theme/tokens.dart';

const Offset _center = Offset(150, 85);
const double _tau = 2 * math.pi;
const Cubic _cssEase = Cubic(0.25, 0.1, 0.25, 1);
const Cubic _cssEaseInOut = Cubic(0.42, 0, 0.58, 1);
const Cubic _labOut = Cubic(0.23, 1, 0.32, 1);
const Cubic _labInOut = Cubic(0.65, 0, 0.35, 1);

const List<double> _wild = [
  -5,
  0,
  0.1,
  0.42,
  0.85,
  1.3,
  2.0,
  2.6,
  3.65,
  5.07,
  60,
  1e9,
  double.infinity,
  double.negativeInfinity,
  double.nan,
];

const List<(String, NbColors, Brightness)> _themes = [
  ('light', NbColors.light, Brightness.light),
  ('dark', NbColors.dark, Brightness.dark),
];

const Map<StageScene, StageSceneFn> _scenePainters = {
  StageScene.connecting: paintConnecting,
  StageScene.comparing: paintComparing,
  StageScene.waiting: paintWaiting,
  StageScene.paired: paintPaired,
  StageScene.rejected: paintRejected,
  StageScene.busy: paintBusy,
  StageScene.paused: paintPaused,
  StageScene.cancelledByPeer: paintCancelledByPeer,
  StageScene.expired: paintExpired,
  StageScene.lost: paintLost,
  StageScene.networkChanged: paintNetworkChanged,
  StageScene.failed: paintFailed,
  StageScene.notSaved: paintNotSaved,
  StageScene.mine: paintMineSwitch,
  StageScene.unpairLoop: paintUnpairLoop,
  StageScene.unpairBreak: paintUnpairBreak,
  StageScene.network: paintNetwork,
  StageScene.exit: paintExit,
};

const Set<StageScene> _looping = {
  StageScene.connecting,
  StageScene.comparing,
  StageScene.waiting,
  StageScene.paired,
  StageScene.busy,
  StageScene.paused,
  StageScene.lost,
  StageScene.mine,
  StageScene.unpairLoop,
  StageScene.exit,
};

const ExitTransfer _toOther = ExitTransfer(
  peer: DeviceGlyph.phone,
  kind: FileKind.sheet,
  towardsHub: false,
);

const ExitTransfer _toHub = ExitTransfer(
  peer: DeviceGlyph.pc,
  kind: FileKind.image,
  towardsHub: true,
);

({double width, double height, double margin, double top}) _boxOf(
  StageScene scene,
) => switch (scene) {
  StageScene.connecting => (width: 300, height: 170, margin: 14, top: 0),
  StageScene.comparing ||
  StageScene.waiting => (width: 247, height: 140, margin: 10, top: 0),
  StageScene.exit => (width: 344, height: 110, margin: 8, top: 37),
  _ => (width: 344, height: 195, margin: 16, top: 0),
};

Color _toneOf(StageScene scene, NbColors c, {bool trusted = false}) =>
    switch (scene) {
      StageScene.connecting ||
      StageScene.waiting ||
      StageScene.mine ||
      StageScene.unpairLoop ||
      StageScene.exit => c.primary,
      StageScene.comparing || StageScene.expired => c.warningRing,
      StageScene.paired => c.success,
      StageScene.rejected ||
      StageScene.cancelledByPeer ||
      StageScene.failed ||
      StageScene.notSaved ||
      StageScene.unpairBreak => c.danger,
      StageScene.busy || StageScene.networkChanged => c.textWeak,
      StageScene.paused => c.ice,
      StageScene.lost => c.warning,
      StageScene.network => trusted ? c.success : c.textWeak,
    };

final class _Case {
  const _Case(
    this.scene, {
    this.input = const StageInput(),
    this.changes = const StageChanges(),
    this.label = '',
  });

  final StageScene scene;
  final StageInput input;
  final StageChanges changes;
  final String label;

  String get name => '${scene.name}$label';
}

List<_Case> _cases() => [
  for (final scene in StageScene.values)
    if (scene != StageScene.mine &&
        scene != StageScene.network &&
        scene != StageScene.exit)
      _Case(scene, input: const StageInput(peer: DeviceGlyph.phone)),
  const _Case(
    StageScene.mine,
    input: StageInput(hovered: Own.other),
    label: ' hovered',
  ),
  const _Case(
    StageScene.mine,
    input: StageInput(hovered: Own.mine, picked: Own.mine),
    changes: StageChanges(hoveredAt: 0.4, pickedAt: 0.9, knobFrom: -20),
    label: ' picked',
  ),
  const _Case(StageScene.network, label: ' untrusted'),
  const _Case(
    StageScene.network,
    input: StageInput(trusted: true),
    changes: StageChanges(trustedAt: 0.5),
    label: ' trusted',
  ),
  const _Case(StageScene.exit, label: ' without a transfer'),
  const _Case(
    StageScene.exit,
    input: StageInput(transfer: _toOther),
    label: ' to the other',
  ),
  const _Case(
    StageScene.exit,
    input: StageInput(transfer: _toHub),
    label: ' towards this device',
  ),
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
  #drawParagraph,
  #drawArc,
  #drawLine,
};

final class _Draw {
  _Draw(
    this.name,
    this.args,
    this.matrix,
    this.alpha,
    this.layers,
    this.filters,
  );

  final Symbol name;
  final List<dynamic> args;
  final Matrix4 matrix;
  final double alpha;
  final List<Rect> layers;
  final List<String> filters;

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
  final List<List<Rect>> _layers = [[]];
  final List<List<String>> _filters = [[]];
  final List<_Draw> draws = [];

  Matrix4 get _top => _matrices.last;

  void _push({double alpha = 1, Rect? layer, String? filter}) {
    _matrices.add(_top.clone());
    _alphas.add(_alphas.last * alpha);
    _layers.add([..._layers.last, ?layer]);
    _filters.add([..._filters.last, ?filter]);
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
    _push(
      alpha: _alphaOfLayer(paint),
      layer: layer,
      filter: paint.imageFilter?.toString(),
    );
  }

  @override
  void restore() {
    super.restore();
    _matrices.removeLast();
    _alphas.removeLast();
    _layers.removeLast();
    _filters.removeLast();
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

  void _add(Symbol name, List<dynamic> args) => draws.add(
    _Draw(
      name,
      args,
      _top.clone(),
      _alphas.last,
      List.of(_layers.last),
      List.of(_filters.last),
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
}

StageFrame _frame(
  NbColors colors, {
  double t = 0,
  bool still = false,
  StageInput input = const StageInput(),
  StageChanges changes = const StageChanges(),
}) => StageFrame(
  t: t,
  still: still,
  colors: colors,
  input: input,
  changes: changes,
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

({double scale, double opacity}) _pop(double t, double delay) {
  final p = ((t - delay) / 0.45).clamp(0.0, 1.0);
  return (
    scale: _kf(p, const [(0, 0.4), (0.6, 1.12), (1, 1)], _labOut),
    opacity: _labOut.transform(p),
  );
}

double _sway(double t) {
  final p = (t % 3.4) / 3.4;
  return p < 0.5
      ? -5 + 10 * _cssEaseInOut.transform(2 * p)
      : 5 - 10 * _cssEaseInOut.transform(2 * p - 1);
}

double _toward(double from, double to, double t, double at, double duration) =>
    from + (to - from) * _ph(t, at, duration, _labInOut);

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

_Draw _single(List<_Draw> found, [String reason = '']) {
  expect(found, hasLength(1), reason: reason);
  return found.single;
}

void _expectOrder(_StageCanvas canvas, List<_Draw> draws) {
  final order = [for (final draw in draws) canvas.draws.indexOf(draw)];
  expect(order, [...order]..sort());
  expect(order.toSet(), hasLength(order.length));
}

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

List<_GlyphStroke> _glyphRef(
  Glyph glyph,
  Offset center,
  double side,
  Color ink,
  double width,
) {
  final canvas = _record(
    (canvas) => paintGlyph(
      canvas,
      glyph,
      Rect.fromCenter(center: center, width: side, height: side),
      ink,
      strokeScale: width / glyph.strokeWidth,
    ),
  );
  return _glyphStrokes([
    for (final draw in canvas.draws)
      if (draw.name == #drawPath) draw,
  ]);
}

void _expectSameGlyph(
  List<_GlyphStroke> actual,
  List<_GlyphStroke> expected, {
  double tolerance = 1e-4,
  String reason = '',
}) {
  expect(actual, hasLength(expected.length), reason: reason);
  for (var i = 0; i < expected.length; i++) {
    expect(actual[i].fill, expected[i].fill, reason: reason);
    expect(
      _same(actual[i].color, expected[i].color),
      isTrue,
      reason: '$reason ${actual[i].color} ${expected[i].color}',
    );
    expect(actual[i].width, closeTo(expected[i].width, 1e-6), reason: reason);
    expect(actual[i].bounds, _rect(expected[i].bounds, tolerance));
  }
}

List<_Draw> _glyphPathsNear(
  Iterable<_Draw> draws,
  Offset center, {
  double maxWidth = 45,
}) => [
  for (final draw in draws)
    if (draw.name == #drawPath &&
        _visible(draw) &&
        (_mapRect(draw.matrix, draw.path.getBounds()).center - center)
                .distance <
            25 &&
        _mapRect(draw.matrix, draw.path.getBounds()).width < maxWidth)
      draw,
];

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

String _signature(_Draw draw, {bool alpha = true}) {
  final paint = draw.paint;
  return [
    draw.name,
    _geometry(draw),
    draw.matrix.storage.map(_f).join(','),
    if (alpha) _f(draw.visibleAlpha),
    _f(paint.color.r),
    _f(paint.color.g),
    _f(paint.color.b),
    paint.style,
    _f(paint.strokeWidth),
    paint.strokeCap,
    paint.strokeJoin,
    paint.shader != null,
  ].join('|');
}

List<String> _picture(_StageCanvas canvas, {bool alpha = true}) => [
  for (final draw in canvas.draws)
    if (_visible(draw)) _signature(draw, alpha: alpha),
];

Future<List<int>> _pixels(
  WidgetTester tester,
  void Function(Canvas canvas) paint,
) async {
  final result = await tester.runAsync(() async {
    final recorder = ui.PictureRecorder();
    paint(Canvas(recorder));
    final image = await recorder.endRecording().toImage(300, 170);
    final data = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
    image.dispose();
    return data!.buffer.asUint8List().toList();
  });
  return result!;
}

int _differences(List<int> a, List<int> b) {
  expect(a.length, b.length);
  var count = 0;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) count++;
  }
  return count;
}

void Function(Canvas canvas) _reference(
  StageScene scene,
  StageFrame frame,
  Color tone,
) => (canvas) {
  canvas.save();
  final top = _boxOf(scene).top;
  if (top != 0) canvas.translate(0, -top);
  paintHalo(canvas, frame, tone);
  _scenePainters[scene]!(canvas, frame);
  canvas.restore();
};

String _withoutStrings(String source) => source
    .replaceAll(RegExp(r"'''[\s\S]*?'''"), "''")
    .replaceAll(RegExp(r'"""[\s\S]*?"""'), '""')
    .replaceAll(RegExp(r"'(?:\\.|[^'\\\n])*'"), "''")
    .replaceAll(RegExp(r'"(?:\\.|[^"\\\n])*"'), '""');

double? _blurOf(_Draw draw) {
  for (final filter in draw.filters.reversed) {
    final match = RegExp(r'blur\(\s*([-0-9.eE+]+)\s*,\s*([-0-9.eE+]+)')
        .firstMatch(filter);
    if (match != null) return double.parse(match.group(1)!);
  }
  return null;
}

typedef _Comet = ({Path path, double begin, double end, bool hub});

final List<_Comet> _comets = [
  (
    path: Path()
      ..moveTo(92, 82)
      ..cubicTo(124, 39, 176, 39, 208, 82),
    begin: 0,
    end: 1.4,
    hub: false,
  ),
  (
    path: Path()
      ..moveTo(92, 88)
      ..cubicTo(124, 131, 176, 131, 208, 88),
    begin: 1.7,
    end: 3.1,
    hub: true,
  ),
  (
    path: Path()
      ..moveTo(92, 83)
      ..cubicTo(116, 51, 134, 51, 150, 85)
      ..cubicTo(166, 119, 184, 119, 208, 87),
    begin: 3.4,
    end: 4.8,
    hub: false,
  ),
  (
    path: Path()
      ..moveTo(92, 87)
      ..cubicTo(116, 119, 134, 119, 150, 85)
      ..cubicTo(166, 51, 184, 51, 208, 83),
    begin: 3.4,
    end: 4.8,
    hub: true,
  ),
];

double _cometGroup(double t, _Comet comet) {
  final c = (t % 5) / 5;
  final a = comet.begin / 5;
  final b = comet.end / 5;
  final times = [0.0, a, a + 0.03, b - 0.04, b, 1.0];
  const values = [0.0, 0.0, 1.0, 1.0, 0.0, 0.0];
  for (var i = 0; i < times.length - 1; i++) {
    if (c >= times[i] && c <= times[i + 1]) {
      final span = times[i + 1] - times[i];
      if (span <= 0) return values[i + 1];
      return values[i] + (values[i + 1] - values[i]) * (c - times[i]) / span;
    }
  }
  return 0;
}

Offset _along(Path path, double progress) {
  final metric = path.computeMetrics().first;
  return metric.getTangentForOffset(metric.length * progress)!.position;
}

typedef _Dot = ({Offset at, double radius, Color color, double alpha});

List<_Dot> _expectedDots(double t, NbColors colors, {required bool hub}) {
  const radii = [2.6, 2.0, 1.5];
  const opacities = [1.0, 0.5, 0.25];
  return [
    for (final comet in _comets)
      if (_cometGroup(t, comet) > 0)
        for (var k = 0; k < 3; k++)
          (
            at: _along(comet.path, () {
              final c = ((t - 0.07 * k) % 5) / 5;
              final a = comet.begin / 5;
              final b = comet.end / 5;
              final p = ((c - a) / (b - a)).clamp(0.0, 1.0);
              return hub ? 1 - p : p;
            }()),
            radius: radii[k],
            color: comet.hub ? colors.hubTop : colors.primary,
            alpha:
                (comet.hub ? colors.hubTop : colors.primary).a *
                opacities[k] *
                _cometGroup(t, comet),
          ),
  ];
}

List<_Draw> _cometDraws(_StageCanvas canvas) => [
  for (final draw in canvas.draws)
    if (draw.name == #drawCircle &&
        !draw.stroked &&
        _visible(draw) &&
        const [2.6, 2.0, 1.5].any((r) => (draw.baseRadius - r).abs() < 1e-9))
      draw,
];

void _expectDots(List<_Draw> actual, List<_Dot> expected, String reason) {
  expect(actual, hasLength(expected.length), reason: reason);
  final left = [...actual];
  for (final dot in expected) {
    final match = left.indexWhere(
      (draw) =>
          _near(draw.center, dot.at, 1e-3) &&
          (draw.baseRadius - dot.radius).abs() < 1e-9 &&
          _sameRgb(draw.paint.color, dot.color) &&
          (draw.visibleAlpha - dot.alpha).abs() < 1e-6,
    );
    expect(match, isNot(-1), reason: '$reason missing $dot');
    if (match >= 0) left.removeAt(match);
  }
}

void _expectDashes(_Draw line, double shift, String reason) {
  final spans = [
    for (final metric in line.metrics)
      (
        line.map(metric.getTangentForOffset(0)!.position).dx,
        line.map(metric.getTangentForOffset(metric.length)!.position).dx,
      ),
  ];
  for (final metric in line.metrics) {
    expect(
      line.map(metric.getTangentForOffset(0)!.position).dy,
      closeTo(85, 1e-6),
    );
  }
  for (var x = 94.25; x < 206; x += 0.5) {
    final local = (x - 94 - shift) % 9;
    if (local < 0.05 || (local - 3).abs() < 0.05 || 9 - local < 0.05) {
      continue;
    }
    final covered = spans.any(
      (span) => x >= span.$1 - 1e-6 && x <= span.$2 + 1e-6,
    );
    expect(covered, local < 3, reason: '$reason x $x');
  }
  expect(spans.first.$1, greaterThanOrEqualTo(94 - 1e-6), reason: reason);
  expect(spans.last.$2, lessThanOrEqualTo(206 + 1e-6), reason: reason);
}

Widget _stage(
  StageScene scene, {
  StageInput input = const StageInput(),
  Brightness brightness = Brightness.light,
  bool reduceMotion = false,
  StageSize? size,
}) => Directionality(
  textDirection: TextDirection.ltr,
  child: MediaQuery(
    data: MediaQueryData(disableAnimations: reduceMotion),
    child: Theme(
      data: buildTheme(brightness),
      child: Center(
        child: ModalStage(scene: scene, input: input, size: size),
      ),
    ),
  ),
);

Future<void> _advance(WidgetTester tester, double seconds) =>
    tester.pump(Duration(microseconds: (seconds * 1e6).round()));

int _live(WidgetTester tester) => tester.binding.transientCallbackCount;

Finder _customPaint() => find.descendant(
  of: find.byType(ModalStage),
  matching: find.byType(CustomPaint),
);

StagePainter _painter(WidgetTester tester) =>
    tester.widget<CustomPaint>(_customPaint()).painter! as StagePainter;

_StageCanvas _paintNow(WidgetTester tester) {
  final canvas = _StageCanvas();
  _painter(tester).paint(canvas, const Size(300, 170));
  return canvas;
}

double _ringSeconds(WidgetTester tester, NbColors colors) {
  final ring = _single(_paths(_paintNow(tester), 2.2, colors.stageHint));
  return (ring.angle % _tau) / _tau * 10;
}

double _knobAt(WidgetTester tester) {
  final disc = _single([
    for (final draw in _paintNow(tester).draws)
      if (draw.name == #drawCircle &&
          !draw.stroked &&
          (draw.baseRadius - 36).abs() < 1e-9 &&
          draw.paint.shader != null)
        draw,
  ]);
  return disc.center.dx - 150;
}

void main() {
  group('E290 mineKnobX', () {
    double knob({
      required double t,
      bool still = false,
      Own? hovered,
      Own? picked,
      StageChanges changes = const StageChanges(),
      NbColors colors = NbColors.light,
    }) => mineKnobX(
      StageFrame(
        t: t,
        still: still,
        colors: colors,
        input: StageInput(hovered: hovered, picked: picked),
        changes: changes,
      ),
    );

    test('sways between -5 and 5 px on a 3.4 s ease-in-out loop', () {
      for (final t in [
        0.0,
        0.3,
        0.85,
        1.2,
        1.7,
        2.1,
        2.55,
        3.0,
        3.4,
        4.25,
        5.1,
        9.9,
      ]) {
        expect(knob(t: t), closeTo(_sway(t), 0.03), reason: '$t');
      }
      expect(knob(t: 0), closeTo(-5, 1e-9));
      expect(knob(t: 0.85), closeTo(0, 0.03));
      expect(knob(t: 1.7), closeTo(5, 0.03));
      expect(knob(t: 3.4), closeTo(-5, 0.03));
    });

    test('still with neither hover nor pick, the knob is centred', () {
      for (final t in _wild) {
        expect(knob(t: t, still: true), 0, reason: '$t');
      }
    });

    test('a hover without its t puts the knob at -26 or +26, also still', () {
      for (final still in [false, true]) {
        for (final t in [0.0, 1.3, 7.0]) {
          expect(knob(t: t, still: still, hovered: Own.mine), -26);
          expect(knob(t: t, still: still, hovered: Own.other), 26);
        }
      }
    });

    test('a pick without its t puts the knob at -82 or +82 and beats the '
        'hover, also still', () {
      for (final still in [false, true]) {
        for (final t in [0.0, 1.3, 7.0]) {
          expect(knob(t: t, still: still, picked: Own.mine), -82);
          expect(knob(t: t, still: still, picked: Own.other), 82);
          expect(
            knob(t: t, still: still, hovered: Own.other, picked: Own.mine),
            -82,
          );
          expect(
            knob(t: t, still: still, hovered: Own.mine, picked: Own.other),
            82,
          );
        }
      }
    });

    test('a hover goes from knobFrom to its side in 0.62 s with '
        'labEaseInOut', () {
      const changes = StageChanges(hoveredAt: 1, knobFrom: 3);
      for (final t in [1.0, 1.1, 1.31, 1.5, 1.62, 2.0, 9.0]) {
        expect(
          knob(t: t, hovered: Own.mine, changes: changes),
          closeTo(_toward(3, -26, t, 1, 0.62), 1e-9),
          reason: '$t',
        );
        expect(
          knob(t: t, hovered: Own.other, changes: changes),
          closeTo(_toward(3, 26, t, 1, 0.62), 1e-9),
          reason: '$t',
        );
      }
      expect(
        knob(t: 1.31, hovered: Own.mine, changes: changes),
        closeTo(3 - 29 * _labInOut.transform(0.5), 1e-9),
      );
      expect(knob(t: 1.62, hovered: Own.mine, changes: changes), -26);
    });

    test('when the hover ends the knob goes back to the sway of the scene '
        't', () {
      const changes = StageChanges(
        hoveredAt: 2,
        hoveredFrom: Own.other,
        knobFrom: 26,
      );
      expect(knob(t: 2, changes: changes), closeTo(26, 1e-9));
      for (final t in [2.1, 2.31, 2.5]) {
        expect(
          knob(t: t, changes: changes),
          closeTo(26 + (_sway(t) - 26) * _ph(t, 2, 0.62, _labInOut), 0.03),
          reason: '$t',
        );
      }
      for (final t in [2.62, 3.0, 4.4, 8.8]) {
        expect(
          knob(t: t, changes: changes),
          closeTo(_sway(t), 0.03),
          reason: '$t',
        );
      }
    });

    test('a pick goes from knobFrom to its side in 0.85 s with labEaseInOut, '
        'timed from pickedAt and not from the hover', () {
      const changes = StageChanges(
        hoveredAt: 1,
        hoveredFrom: Own.mine,
        pickedAt: 3,
        knobFrom: -26,
      );
      for (final t in [3.0, 3.2, 3.425, 3.7, 3.85, 6.0]) {
        expect(
          knob(t: t, hovered: Own.other, picked: Own.other, changes: changes),
          closeTo(_toward(-26, 82, t, 3, 0.85), 1e-9),
          reason: '$t',
        );
      }
      expect(
        knob(t: 3.425, hovered: Own.other, picked: Own.other, changes: changes),
        closeTo(-26 + 108 * _labInOut.transform(0.5), 1e-9),
      );
      const later = StageChanges(hoveredAt: 3.2, pickedAt: 3, knobFrom: 10);
      expect(
        knob(t: 3.425, hovered: Own.other, picked: Own.mine, changes: later),
        closeTo(_toward(10, -82, 3.425, 3, 0.85), 1e-9),
      );
    });

    test('still ignores the changes and gives the destination', () {
      const changes = StageChanges(hoveredAt: 1, pickedAt: 1.2, knobFrom: 40);
      for (final t in _wild) {
        expect(knob(t: t, still: true, changes: changes), 0);
        expect(
          knob(t: t, still: true, hovered: Own.mine, changes: changes),
          -26,
        );
        expect(
          knob(t: t, still: true, picked: Own.other, changes: changes),
          82,
        );
      }
    });

    test('is pure: the same frame gives the same x, in either theme', () {
      const changes = StageChanges(hoveredAt: 0.5, knobFrom: 2);
      for (final t in [0.6, 0.9, 1.4]) {
        final light = knob(t: t, hovered: Own.mine, changes: changes);
        expect(knob(t: t, hovered: Own.mine, changes: changes), light);
        expect(
          knob(
            t: t,
            hovered: Own.mine,
            changes: changes,
            colors: NbColors.dark,
          ),
          light,
        );
      }
    });

    test('is finite at any t and with any recorded change', () {
      for (final t in _wild) {
        for (final still in [false, true]) {
          for (final hovered in [null, ...Own.values]) {
            for (final picked in [null, ...Own.values]) {
              for (final changes in [
                const StageChanges(),
                const StageChanges(hoveredAt: 0, knobFrom: -5),
                const StageChanges(hoveredAt: 2, pickedAt: 3, knobFrom: 26),
                const StageChanges(hoveredAt: 1e9, pickedAt: 1e9, knobFrom: 0),
              ]) {
                final x = knob(
                  t: t,
                  still: still,
                  hovered: hovered,
                  picked: picked,
                  changes: changes,
                );
                expect(x.isFinite, isTrue, reason: '$t $hovered $picked');
                expect(x.abs(), lessThanOrEqualTo(82), reason: '$t');
              }
            }
          }
        }
      }
    });
  });

  for (final (theme, colors, _) in _themes) {
    group('E290 paintMineSwitch ($theme)', () {
      const leftLane = Rect.fromLTRB(34, 53, 150, 117);
      const rightLane = Rect.fromLTRB(150, 53, 266, 117);
      const mineSpot = Offset(68, 85);
      const otherSpot = Offset(232, 85);
      const deviceSide = 24 * 36 / 22;

      _StageCanvas at(
        double t, {
        bool still = false,
        Own? hovered,
        Own? picked,
        DeviceGlyph peer = DeviceGlyph.pc,
        StageChanges changes = const StageChanges(),
      }) => _paint(
        paintMineSwitch,
        _frame(
          colors,
          t: t,
          still: still,
          input: StageInput(peer: peer, hovered: hovered, picked: picked),
          changes: changes,
        ),
      );

      int shadowIndex(_StageCanvas c) => c.draws.indexWhere(
        (d) =>
            d.name == #drawCircle &&
            !d.stroked &&
            (d.baseRadius - 38).abs() < 1e-9,
      );

      _Draw disc(_StageCanvas c) => _single([
        for (final d in c.draws)
          if (d.name == #drawCircle &&
              !d.stroked &&
              (d.baseRadius - 36).abs() < 1e-9 &&
              d.paint.shader != null)
            d,
      ]);

      double knobX(_StageCanvas c) => disc(c).center.dx - 150;

      double laneAlpha(_StageCanvas c, Rect bounds) {
        final found = [
          for (final d in c.draws)
            if (d.name == #drawPath &&
                !d.stroked &&
                (_mapRect(d.matrix, d.path.getBounds()).left - bounds.left)
                        .abs() <
                    1e-6 &&
                (_mapRect(d.matrix, d.path.getBounds()).right - bounds.right)
                        .abs() <
                    1e-6 &&
                (_mapRect(d.matrix, d.path.getBounds()).top - bounds.top)
                        .abs() <
                    1e-6 &&
                (_mapRect(d.matrix, d.path.getBounds()).bottom - bounds.bottom)
                        .abs() <
                    1e-6)
              d,
        ];
        expect(found.length, lessThanOrEqualTo(1));
        return found.isEmpty ? 0 : found.single.visibleAlpha;
      }

      Color laneColor(_StageCanvas c, Rect bounds) => c.draws
          .firstWhere(
            (d) =>
                d.name == #drawPath &&
                !d.stroked &&
                (_mapRect(d.matrix, d.path.getBounds()).left - bounds.left)
                        .abs() <
                    1e-6 &&
                (_mapRect(d.matrix, d.path.getBounds()).right - bounds.right)
                        .abs() <
                    1e-6,
          )
          .paint
          .color;

      List<_Draw> side(_StageCanvas c, Offset spot) =>
          _glyphPathsNear(c.draws.sublist(0, shadowIndex(c)), spot);

      List<_Draw> knobGlyphs(_StageCanvas c) => _glyphPathsNear(
        c.draws.sublist(shadowIndex(c)),
        Offset(150 + knobX(c), 85),
      );

      List<_Draw> burst(_StageCanvas c) => [
        for (final d in c.draws)
          if (d.name == #drawCircle &&
              d.stroked &&
              (d.baseRadius - 38).abs() < 1e-9 &&
              _visible(d))
            d,
      ];

      List<_Draw> overlay(_StageCanvas c) => [
        for (final d in c.draws)
          if (d.name == #drawCircle &&
              !d.stroked &&
              (d.baseRadius - 36).abs() < 1e-9 &&
              d.paint.shader == null &&
              _visible(d))
            d,
      ];

      _Draw ring(_StageCanvas c) => _single(_circles(c, 36, stroked: true));

      List<_Draw> badge(_StageCanvas c) => _circles(c, 10, stroked: false);

      int deviceCount(DeviceGlyph peer) => _glyphRef(
        peer == DeviceGlyph.phone ? Glyphs.phone : Glyphs.pc,
        _center,
        deviceSide,
        colors.text,
        1.5,
      ).length;

      Color toneOf(Own own) =>
          own == Own.mine ? colors.primary : colors.textWeak;

      StageChanges picking(Own own) => StageChanges(
        hoveredAt: 1,
        pickedAt: 2,
        knobFrom: own == Own.mine ? -26 : 26,
      );

      _StageCanvas pickAt(double t, Own own) =>
          at(t, hovered: own, picked: own, changes: picking(own));

      test('the rail is 232 x 64 at (34, 53) with radius 32: stageWeak and a '
          '1.6 stageBorder rim', () {
        final c = at(1);
        final rects = [
          for (final d in c.draws)
            if (d.name == #drawRRect) d,
        ];
        expect(rects, hasLength(2));
        for (final d in rects) {
          final rrect = d.args[0] as RRect;
          expect(
            _mapRect(d.matrix, rrect.outerRect),
            _rect(const Rect.fromLTWH(34, 53, 232, 64)),
          );
          expect(rrect.tlRadiusX, closeTo(32, 1e-9));
          expect(rrect.brRadiusY, closeTo(32, 1e-9));
        }
        final fill = rects.firstWhere((d) => !d.stroked);
        final rim = rects.firstWhere((d) => d.stroked);
        expect(_same(fill.paint.color, colors.stageWeak), isTrue);
        expect(_same(rim.paint.color, colors.stageBorder), isTrue);
        expect(rim.paint.strokeWidth, closeTo(1.6, 1e-6));
        expect(c.draws.indexOf(fill), lessThan(c.draws.indexOf(rim)));
      });

      test('both lanes are hidden without hover; the hovered one fades in '
          'over 0.45 s with ease', () {
        for (final t in [0.0, 1.0, 4.0]) {
          expect(laneAlpha(at(t), leftLane), 0);
          expect(laneAlpha(at(t), rightLane), 0);
        }
        const changes = StageChanges(hoveredAt: 1);
        for (final t in [1.0, 1.1, 1.225, 1.4, 1.45, 3.0]) {
          final mine = at(t, hovered: Own.mine, changes: changes);
          expect(
            laneAlpha(mine, leftLane),
            closeTo(colors.primaryWeak.a * _ph(t, 1, 0.45, _cssEase), 1e-6),
            reason: '$t',
          );
          expect(laneAlpha(mine, rightLane), closeTo(0, 1e-9));
          final other = at(t, hovered: Own.other, changes: changes);
          expect(
            laneAlpha(other, rightLane),
            closeTo(colors.stageTrack.a * _ph(t, 1, 0.45, _cssEase), 1e-6),
            reason: '$t',
          );
          expect(laneAlpha(other, leftLane), closeTo(0, 1e-9));
        }
        final lit = at(3, hovered: Own.mine, changes: changes);
        expect(_sameRgb(laneColor(lit, leftLane), colors.primaryWeak), isTrue);
        final litOther = at(3, hovered: Own.other, changes: changes);
        expect(
          _sameRgb(laneColor(litOther, rightLane), colors.stageTrack),
          isTrue,
        );
      });

      test('a hover that changes side crosses the lanes from the change', () {
        const changes = StageChanges(hoveredAt: 2, hoveredFrom: Own.mine);
        for (final t in [2.0, 2.1, 2.225, 2.45, 5.0]) {
          final c = at(t, hovered: Own.other, changes: changes);
          final e = _ph(t, 2, 0.45, _cssEase);
          expect(
            laneAlpha(c, leftLane),
            closeTo(colors.primaryWeak.a * (1 - e), 1e-6),
            reason: '$t',
          );
          expect(
            laneAlpha(c, rightLane),
            closeTo(colors.stageTrack.a * e, 1e-6),
            reason: '$t',
          );
        }
      });

      test('the side glyphs: mine at (68, 85) in primaryInk and someoneElse '
          'at (232, 85) in textWeak, scale 1.25 and stroke 1.6, at 75 %', () {
        for (final t in [0.0, 1.0, 6.0]) {
          final c = at(t);
          final mine = side(c, mineSpot);
          final other = side(c, otherSpot);
          _expectSameGlyph(
            _glyphStrokes(mine),
            _glyphRef(Glyphs.mine, mineSpot, 30, colors.primaryInk, 1.6),
          );
          _expectSameGlyph(
            _glyphStrokes(other),
            _glyphRef(Glyphs.someoneElse, otherSpot, 30, colors.textWeak, 1.6),
          );
          for (final d in [...mine, ...other]) {
            expect(d.alpha, closeTo(0.75, 1e-6), reason: '$t');
          }
        }
      });

      test('with hover the side glyphs go to 100 % and 35 % in 0.45 s with '
          'ease', () {
        const changes = StageChanges(hoveredAt: 1);
        for (final t in [1.0, 1.225, 1.45, 4.0]) {
          final e = _ph(t, 1, 0.45, _cssEase);
          final c = at(t, hovered: Own.mine, changes: changes);
          for (final d in side(c, mineSpot)) {
            expect(d.alpha, closeTo(0.75 + 0.25 * e, 1e-6), reason: '$t');
          }
          for (final d in side(c, otherSpot)) {
            expect(d.alpha, closeTo(0.75 - 0.4 * e, 1e-6), reason: '$t');
          }
        }
        final still = at(0, still: true, hovered: Own.other);
        for (final d in side(still, mineSpot)) {
          expect(d.alpha, closeTo(0.35, 1e-6));
        }
        for (final d in side(still, otherSpot)) {
          expect(d.alpha, closeTo(1, 1e-6));
        }
        expect(laneAlpha(still, rightLane), closeTo(colors.stageTrack.a, 1e-6));
      });

      test('the knob: a 38 nodeShadow shadow at 50 % 3 px down, a 36 disc '
          'with the node gradient and a 2 px success rim, all at '
          'mineKnobX', () {
        for (final t in [0.0, 0.6, 1.3, 2.9]) {
          final frame = _frame(colors, t: t);
          final c = _paint(paintMineSwitch, frame);
          final x = mineKnobX(frame);
          expect(x, closeTo(_sway(t), 0.03), reason: '$t');
          expect(knobX(c), closeTo(x, 1e-9), reason: '$t');
          final shadow = c.draws[shadowIndex(c)];
          expect(shadow.center, _at(Offset(150 + x, 88)));
          expect(shadow.radius, closeTo(38, 1e-9));
          expect(_sameRgb(shadow.paint.color, colors.nodeShadow), isTrue);
          expect(shadow.visibleAlpha, closeTo(colors.nodeShadow.a * 0.5, 1e-6));
          final body = disc(c);
          expect(body.center, _at(Offset(150 + x, 85)));
          expect(body.radius, closeTo(36, 1e-9));
          final rim = ring(c);
          expect(rim.center, _at(Offset(150 + x, 85)));
          expect(rim.paint.strokeWidth, closeTo(2, 1e-6));
          expect(_same(rim.paint.color, colors.success), isTrue);
          expect(overlay(c), isEmpty);
          expect(burst(c), isEmpty);
        }
      });

      test('the device in the knob is the peer glyph at 36/22 in text with '
          'stroke 1.5', () {
        for (final peer in DeviceGlyph.values) {
          final c = at(1.2, peer: peer);
          final x = knobX(c);
          _expectSameGlyph(
            _glyphStrokes(knobGlyphs(c)),
            _glyphRef(
              peer == DeviceGlyph.phone ? Glyphs.phone : Glyphs.pc,
              Offset(150 + x, 85),
              deviceSide,
              colors.text,
              1.5,
            ),
            reason: peer.name,
          );
        }
      });

      test('the check badge of 10 at (176, 111) pops in at 0.1 s and moves '
          'with the knob', () {
        expect(badge(at(0)), isEmpty);
        expect(badge(at(0.1)), isEmpty);
        for (final local in [0.25, 0.5, 0.8, 1.0, 3.0]) {
          final t = 0.1 + 0.45 * local;
          final c = at(t);
          final pop = _pop(t, 0.1);
          final found = _single(badge(c), '$local');
          expect(found.center, _at(Offset(176 + knobX(c), 111), 1e-6));
          expect(found.radius, closeTo(10 * pop.scale, 1e-6));
          expect(
            found.visibleAlpha,
            closeTo(colors.success.a * pop.opacity, 1e-6),
          );
          expect(_sameRgb(found.paint.color, colors.success), isTrue);
          final rim = _single(_circles(c, 10, stroked: true));
          expect(_same(rim.paint.color, colors.card), isTrue);
          expect(rim.paint.strokeWidth, closeTo(3.5, 1e-6));
        }
      });

      for (final own in Own.values) {
        final target = own == Own.mine ? -82.0 : 82.0;
        final from = own == Own.mine ? -26.0 : 26.0;

        test('picking ${own.name}: the knob travels from knobFrom to '
            '$target in 0.85 s', () {
          for (final t in [2.0, 2.2, 2.425, 2.7, 2.85, 5.0]) {
            expect(
              knobX(pickAt(t, own)),
              closeTo(_toward(from, target, t, 2, 0.85), 1e-9),
              reason: '$t',
            );
          }
        });

        test('picking ${own.name}: the burst ring is at 70 % from the pick '
            'and opens from 0.85 to 1.65 s', () {
          final tone = toneOf(own);
          expect(burst(at(1.5, hovered: own)), isEmpty);
          for (final t in [2.0, 2.4, 2.85]) {
            final c = pickAt(t, own);
            final ring = _single(burst(c), '$t');
            expect(ring.center, _at(Offset(150 + knobX(c), 85)));
            expect(ring.radius, closeTo(38, 1e-9));
            expect(ring.paint.strokeWidth, closeTo(2, 1e-6));
            expect(_sameRgb(ring.paint.color, tone), isTrue);
            expect(ring.visibleAlpha, closeTo(tone.a * 0.7, 1e-6));
          }
          for (final local in [0.25, 0.5, 0.9]) {
            final t = 2 + 0.85 + 0.8 * local;
            final c = pickAt(t, own);
            final s = _ph(t, 2 + 0.85, 0.8, _labOut);
            final ring = _single(burst(c), '$local');
            expect(ring.radius, closeTo(38 * (1 + 0.55 * s), 1e-6));
            expect(ring.center, _at(Offset(150 + knobX(c), 85), 1e-6));
            expect(ring.visibleAlpha, closeTo(tone.a * 0.7 * (1 - s), 1e-6));
          }
          for (final t in [3.65, 4.0, 9.0]) {
            expect(burst(pickAt(t, own)), isEmpty, reason: '$t');
          }
        });

        test('picking ${own.name}: the disc fills with the tone 0.5 s after '
            '0.35 s with ease', () {
          final tone = toneOf(own);
          for (final t in [2.0, 2.2, 2.35]) {
            expect(overlay(pickAt(t, own)), isEmpty, reason: '$t');
          }
          for (final local in [0.2, 0.5, 0.8]) {
            final t = 2.35 + 0.5 * local;
            final c = pickAt(t, own);
            final e = _ph(t, 2 + 0.35, 0.5, _cssEase);
            final fill = _single(overlay(c), '$local');
            expect(_sameRgb(fill.paint.color, tone), isTrue);
            expect(fill.visibleAlpha, closeTo(tone.a * e, 1e-6));
            expect(fill.center, _at(Offset(150 + knobX(c), 85)));
          }
          for (final t in [2.85, 4.0]) {
            final fill = _single(overlay(pickAt(t, own)));
            expect(fill.visibleAlpha, closeTo(tone.a, 1e-6));
          }
        });

        test('picking ${own.name}: the rim leaves success at the pick and '
            'reaches the tone in 0.45 s with ease', () {
          final tone = toneOf(own);
          expect(
            _same(ring(pickAt(2, own)).paint.color, colors.success),
            isTrue,
          );
          for (final local in [0.1, 0.25, 0.5, 0.75]) {
            final t = 2 + 0.45 * local;
            final e = _ph(t, 2, 0.45, _cssEase);
            expect(
              _same(
                ring(pickAt(t, own)).paint.color,
                Color.lerp(colors.success, tone, e)!,
              ),
              isTrue,
              reason: '$local',
            );
          }
          for (final t in [2.45, 2.85, 3.75, 9.0]) {
            expect(
              _same(ring(pickAt(t, own)).paint.color, tone),
              isTrue,
              reason: '$t',
            );
          }
        });

        test('picking ${own.name}: every frame of the farewell moves the rim '
            'only toward the tone and never back to success', () {
          final tone = toneOf(own);
          double toTone(Color c) =>
              (c.r - tone.r).abs() +
              (c.g - tone.g).abs() +
              (c.b - tone.b).abs();
          double toSuccess(Color c) =>
              (c.r - colors.success.r).abs() +
              (c.g - colors.success.g).abs() +
              (c.b - colors.success.b).abs();
          var last = toTone(colors.success);
          for (var ms = 16; ms <= 1750; ms += 16) {
            final t = 2 + ms / 1000;
            final color = ring(pickAt(t, own)).paint.color;
            final now = toTone(color);
            expect(now, lessThanOrEqualTo(last + 1e-9), reason: '$ms ms');
            expect(toSuccess(color), greaterThan(0), reason: '$ms ms');
            if (ms >= 200) {
              expect(now, lessThan(toSuccess(color)), reason: '$ms ms');
            }
            if (ms >= 450) expect(_same(color, tone), isTrue, reason: '$ms ms');
            last = now;
          }
        });

        test('picking ${own.name} with reduced motion: the rim is the tone '
            'at once', () {
          final c = at(0, still: true, hovered: own, picked: own);
          expect(_same(ring(c).paint.color, toneOf(own)), isTrue);
          expect(
            _same(
              ring(at(0, still: true, hovered: own)).paint.color,
              colors.success,
            ),
            isTrue,
          );
        });

        test('picking ${own.name}: the device fades with a 3 px blur in '
            '0.35 s after 0.3 s', () {
          final count = deviceCount(DeviceGlyph.pc);
          for (final t in [2.0, 2.2, 2.3]) {
            final glyph = knobGlyphs(pickAt(t, own));
            expect(glyph, hasLength(count), reason: '$t');
            for (final d in glyph) {
              expect(d.alpha, closeTo(1, 1e-9));
              expect(_blurOf(d), isNull);
            }
          }
          for (final local in [0.25, 0.5, 0.75]) {
            final t = 2.3 + 0.35 * local;
            final e = _ph(t, 2 + 0.3, 0.35, _cssEase);
            final glyph = knobGlyphs(pickAt(t, own)).take(count).toList();
            expect(glyph, hasLength(count));
            for (final d in glyph) {
              expect(_sameRgb(d.paint.color, colors.text), isTrue);
              expect(d.alpha, closeTo(1 - e, 1e-6), reason: '$local');
              expect(_blurOf(d), closeTo(3 * e, 1e-6), reason: '$local');
            }
          }
          final markCount = _glyphRef(
            own == Own.mine ? Glyphs.mine : Glyphs.someoneElse,
            _center,
            24,
            colors.card,
            1.5,
          ).length;
          for (final t in [2.66, 3.0, 6.0]) {
            final glyphs = knobGlyphs(pickAt(t, own));
            expect(glyphs, hasLength(markCount), reason: '$t');
            expect(
              glyphs.where((d) => d.filters.isNotEmpty),
              isEmpty,
              reason: '$t',
            );
          }
        });

        test('picking ${own.name}: k${own == Own.mine ? 'M' : 'O'} fades in '
            '0.4 s and grows from 0.7 in 0.5 s, both after 0.42 s', () {
          final glyph = own == Own.mine ? Glyphs.mine : Glyphs.someoneElse;
          final ink = own == Own.mine ? colors.onPrimary : colors.card;
          final count = deviceCount(DeviceGlyph.pc);
          for (final t in [2.0, 2.3, 2.42]) {
            expect(knobGlyphs(pickAt(t, own)), hasLength(count), reason: '$t');
          }
          for (final t in [2.52, 2.62, 2.72, 2.82, 2.92, 4.0]) {
            final c = pickAt(t, own);
            final fade = _ph(t, 2 + 0.42, 0.4, _cssEase);
            final grow = 0.7 + 0.3 * _ph(t, 2 + 0.42, 0.5, _labOut);
            final all = knobGlyphs(c);
            final device = t < 2.65 ? count : 0;
            final mark = all.sublist(device);
            _expectSameGlyph(
              _glyphStrokes(mark),
              _glyphRef(
                glyph,
                Offset(150 + knobX(c), 85),
                24 * 1.55 * grow,
                ink,
                1.5,
              ),
              reason: '$t',
            );
            for (final d in mark) {
              expect(d.alpha, closeTo(fade, 1e-6), reason: '$t');
            }
          }
          final half = knobGlyphs(pickAt(2.42 + 0.4, own)).last;
          expect(half.alpha, closeTo(1, 1e-6));
          expect(
            _mapRect(half.matrix, half.path.getBounds()).width,
            lessThan(
              _mapRect(
                knobGlyphs(pickAt(4, own)).last.matrix,
                knobGlyphs(pickAt(4, own)).last.path.getBounds(),
              ).width,
            ),
          );
          final done = knobGlyphs(pickAt(2.42 + 0.5, own));
          _expectSameGlyph(
            _glyphStrokes(done),
            _glyphRef(
              glyph,
              Offset(150 + knobX(pickAt(2.92, own)), 85),
              24 * 1.55,
              ink,
              1.5,
            ),
          );
        });

        test('picking ${own.name}: the badge leaves in 0.25 s and the picked '
            'side glyph in 0.45 s', () {
          final spot = own == Own.mine ? mineSpot : otherSpot;
          final rest = own == Own.mine ? otherSpot : mineSpot;
          for (final t in [2.0, 2.06, 2.125, 2.2]) {
            final c = pickAt(t, own);
            final e = _ph(t, 2, 0.25, _cssEase);
            final found = _single(badge(c), '$t');
            expect(found.radius, closeTo(10 * (1 - 0.2 * e), 1e-6));
            expect(
              found.visibleAlpha,
              closeTo(colors.success.a * (1 - e), 1e-6),
              reason: '$t',
            );
            expect(found.center, _at(Offset(176 + knobX(c), 111)));
          }
          for (final t in [2.25, 3.0]) {
            expect(badge(pickAt(t, own)), isEmpty, reason: '$t');
          }
          for (final t in [2.0, 2.225, 2.4]) {
            final e = _ph(t, 2, 0.45, _cssEase);
            for (final d in side(pickAt(t, own), spot)) {
              expect(d.alpha, closeTo(1 - e, 1e-6), reason: '$t');
            }
          }
          for (final t in [2.45, 3.0, 8.0]) {
            final c = pickAt(t, own);
            expect(side(c, spot), isEmpty, reason: '$t');
            for (final d in side(c, rest)) {
              expect(d.alpha, closeTo(0.35, 1e-6));
            }
          }
        });

        test('still with ${own.name} picked: the end of the pick at any t', () {
          final tone = toneOf(own);
          final glyph = own == Own.mine ? Glyphs.mine : Glyphs.someoneElse;
          final ink = own == Own.mine ? colors.onPrimary : colors.card;
          final reference = _picture(
            at(0, still: true, hovered: own, picked: own),
          );
          for (final t in _wild) {
            for (final changes in [const StageChanges(), picking(own)]) {
              final c = at(
                t,
                still: true,
                hovered: own,
                picked: own,
                changes: changes,
              );
              expect(_picture(c), reference, reason: '$t');
              expect(knobX(c), target);
              expect(burst(c), isEmpty);
              expect(badge(c), isEmpty);
              expect(_single(overlay(c)).visibleAlpha, closeTo(tone.a, 1e-6));
              expect(_same(ring(c).paint.color, tone), isTrue);
              _expectSameGlyph(
                _glyphStrokes(knobGlyphs(c)),
                _glyphRef(glyph, Offset(150 + target, 85), 24 * 1.55, ink, 1.5),
              );
              for (final d in knobGlyphs(c)) {
                expect(d.alpha, closeTo(1, 1e-9));
              }
              expect(side(c, own == Own.mine ? mineSpot : otherSpot), isEmpty);
            }
          }
        });
      }

      test('still without a pick: centred knob, the whole badge and the '
          'device, no burst, at any t', () {
        final reference = _picture(at(0, still: true));
        for (final t in _wild) {
          final c = at(t, still: true);
          expect(_picture(c), reference, reason: '$t');
          expect(knobX(c), 0);
          final found = _single(badge(c));
          expect(found.radius, closeTo(10, 1e-9));
          expect(found.visibleAlpha, closeTo(colors.success.a, 1e-9));
          expect(knobGlyphs(c), hasLength(deviceCount(DeviceGlyph.pc)));
          expect(burst(c), isEmpty);
          expect(overlay(c), isEmpty);
          expect(laneAlpha(c, leftLane), 0);
          expect(laneAlpha(c, rightLane), 0);
          for (final d in [...side(c, mineSpot), ...side(c, otherSpot)]) {
            expect(d.alpha, closeTo(0.75, 1e-6));
          }
        }
      });

      test('the layers follow the lab order', () {
        final idle = at(1.2);
        _expectOrder(idle, [
          idle.draws.firstWhere((d) => d.name == #drawRRect),
          side(idle, mineSpot).first,
          side(idle, otherSpot).first,
          idle.draws[shadowIndex(idle)],
          disc(idle),
          ring(idle),
          knobGlyphs(idle).first,
          _single(badge(idle)),
        ]);
        final picked = pickAt(2.6, Own.mine);
        final glyphs = knobGlyphs(picked);
        _expectOrder(picked, [
          side(picked, otherSpot).first,
          _single(burst(picked)),
          picked.draws[shadowIndex(picked)],
          disc(picked),
          _single(overlay(picked)),
          ring(picked),
          glyphs.first,
          glyphs.last,
        ]);
        expect(
          glyphs.first.filters,
          isNotEmpty,
          reason: 'the device goes before the mark',
        );
      });

      test('uses only colours of NbColors', () {
        final palette = [
          colors.stageWeak,
          colors.stageBorder,
          colors.primaryWeak,
          colors.stageTrack,
          colors.primaryInk,
          colors.textWeak,
          colors.nodeShadow,
          colors.success,
          colors.primary,
          colors.text,
          colors.card,
          colors.onSuccessDisc,
          colors.onPrimary,
        ];
        for (final c in [
          at(0.3),
          at(1.6, hovered: Own.mine, changes: const StageChanges(hoveredAt: 1)),
          pickAt(2.5, Own.mine),
          pickAt(5, Own.mine),
          pickAt(5, Own.other),
          at(0, still: true),
          at(0, still: true, hovered: Own.other, picked: Own.other),
        ]) {
          _expectOnly(c, palette, discs: {36});
        }
      });
    });

    group('E290 paintNetwork ($theme)', () {
      _StageCanvas at(
        double t, {
        bool trusted = false,
        bool still = false,
        double? trustedAt,
      }) => _paint(
        paintNetwork,
        _frame(
          colors,
          t: t,
          still: still,
          input: StageInput(trusted: trusted),
          changes: StageChanges(trustedAt: trustedAt),
        ),
      );

      List<_Draw> dashed(_StageCanvas c) => _paths(c, 2.2, colors.stageHint);

      List<_Draw> glyph(_StageCanvas c) =>
          _glyphPathsNear(c.draws, _center, maxWidth: 60);

      _Draw successDisc(_StageCanvas c) => _single([
        for (final d in _circles(c, 44, stroked: false))
          if (d.paint.shader == null) d,
      ]);

      test('untrusted: a stageHint ring of 56, 2.2 wide, with round 4 8 '
          'dashes, turning once every 10 s', () {
        for (final t in [0.0, 2.5, 7.5, 12.5, 26.0]) {
          final ring = _single(dashed(at(t)), '$t');
          expect(ring.paint.strokeCap, StrokeCap.round);
          expect(_same(ring.paint.color, colors.stageHint), isTrue);
          _expectAngle(ring.angle, _tau * ((t % 10) / 10), reason: '$t');
          final lengths = [for (final m in ring.metrics) m.length];
          expect(
            lengths.where((l) => (l - 4).abs() < 0.1).length,
            greaterThanOrEqualTo(lengths.length - 1),
          );
          expect(ring.localLength, closeTo(_tau * 56 * 4 / 12, 4.01));
          for (final m in ring.metrics) {
            expect(
              (ring.map(m.getTangentForOffset(0)!.position) - _center).distance,
              closeTo(56, 1e-3),
            );
          }
        }
      });

      test('untrusted: an empty disc of 44 with the node gradient and a '
          'stageBorder rim, and the networkShield at 2.1 in textWeak', () {
        final c = at(1.4);
        final body = _single(_circles(c, 44, stroked: false));
        expect(body.paint.shader, isNotNull);
        expect(body.center, _at(_center));
        final rim = _single(_circles(c, 44, stroked: true));
        expect(_same(rim.paint.color, colors.stageBorder), isTrue);
        expect(rim.paint.strokeWidth, closeTo(1.6, 1e-6));
        _expectSameGlyph(
          _glyphStrokes(glyph(c)),
          _glyphRef(
            Glyphs.networkShield,
            _center,
            24 * 2.1,
            colors.textWeak,
            1.5,
          ),
        );
        expect(_circles(c, 56, stroked: true), isEmpty);
      });

      test('untrusted and still: the ring at rest at any t', () {
        final reference = _picture(at(0, still: true));
        for (final t in _wild) {
          final c = at(t, still: true);
          expect(_picture(c), reference, reason: '$t');
          _expectAngle(_single(dashed(c)).angle, 0, reason: '$t');
        }
      });

      test('trusted: a solid success ring of 56, 2.2 wide, that does not '
          'turn', () {
        for (final t in [0.0, 0.3, 2.5, 7.5]) {
          for (final trustedAt in [null, 0.2]) {
            final c = at(t, trusted: true, trustedAt: trustedAt);
            expect(dashed(c), isEmpty);
            final ring = _single(_circles(c, 56, stroked: true));
            expect(_same(ring.paint.color, colors.success), isTrue);
            expect(ring.paint.strokeWidth, closeTo(2.2, 1e-6));
            expect(ring.center, _at(_center));
            expect(ring.radius, closeTo(56, 1e-9));
            _expectAngle(ring.angle, 0);
          }
        }
      });

      test('trusted: the success disc enters with fadeUp, 0.9 to 1 in '
          '0.45 s, and the glyph pops in onSuccessDisc 0.1 s later, timed '
          'from trustedAt', () {
        for (final trustedAt in [null, 3.0]) {
          final start = trustedAt ?? 0;
          for (final since in [0.05, 0.225, 0.325, 0.45, 0.55, 2.0]) {
            final t = start + since;
            final c = at(t, trusted: true, trustedAt: trustedAt);
            final enter = _ph(t - start, 0, 0.45, _labOut);
            final disc = successDisc(c);
            expect(disc.center, _at(_center));
            expect(
              disc.radius,
              closeTo(44 * (0.9 + 0.1 * enter), 1e-6),
              reason: '$since',
            );
            expect(
              disc.visibleAlpha,
              closeTo(colors.success.a * enter, 1e-6),
              reason: '$since',
            );
            final pop = _pop(t - start, 0.1);
            final found = glyph(c);
            if (!(pop.opacity > 0)) {
              expect(found, isEmpty, reason: '$since');
              continue;
            }
            _expectSameGlyph(
              _glyphStrokes(found),
              _glyphRef(
                Glyphs.networkShield,
                _center,
                24 * 2.1 * pop.scale,
                colors.onSuccessDisc,
                1.5,
              ),
              reason: '$since',
            );
            for (final d in found) {
              expect(d.alpha, closeTo(pop.opacity, 1e-6), reason: '$since');
            }
          }
        }
      });

      test(
        'trusted: the entry does not replay from the start of the scene',
        () {
          final before = at(2.9, trusted: true, trustedAt: 3);
          expect(_circles(before, 44, stroked: false), isEmpty);
          expect(glyph(before), isEmpty);
          final atChange = at(3, trusted: true, trustedAt: 3);
          expect(_circles(atChange, 44, stroked: false), isEmpty);
          expect(
            successDisc(at(3.225, trusted: true, trustedAt: 3)).visibleAlpha,
            closeTo(colors.success.a * _labOut.transform(0.5), 1e-6),
          );
          final settled = at(3.6, trusted: true, trustedAt: 3);
          expect(successDisc(settled).radius, closeTo(44, 1e-9));
          expect(
            successDisc(settled).visibleAlpha,
            closeTo(colors.success.a, 1e-9),
          );
        },
      );

      test('trusted and still: the whole disc and glyph at any t', () {
        final reference = _picture(at(0, trusted: true, still: true));
        for (final t in _wild) {
          for (final trustedAt in [null, 5.0, 1e9]) {
            final c = at(t, trusted: true, still: true, trustedAt: trustedAt);
            expect(_picture(c), reference, reason: '$t $trustedAt');
          }
        }
        final c = at(0, trusted: true, still: true);
        expect(successDisc(c).radius, closeTo(44, 1e-9));
        expect(successDisc(c).visibleAlpha, closeTo(colors.success.a, 1e-9));
        for (final d in glyph(c)) {
          expect(d.alpha, closeTo(1, 1e-9));
        }
      });

      test('the layers follow the lab order', () {
        final open = at(1);
        _expectOrder(open, [
          _single(dashed(open)),
          _single(_circles(open, 44, stroked: false)),
          _single(_circles(open, 44, stroked: true)),
          glyph(open).first,
        ]);
        final shut = at(2, trusted: true);
        _expectOrder(shut, [
          _single(_circles(shut, 56, stroked: true)),
          successDisc(shut),
          glyph(shut).first,
        ]);
      });

      test('uses only colours of NbColors', () {
        final palette = [
          colors.stageHint,
          colors.stageBorder,
          colors.textWeak,
          colors.success,
          colors.onSuccessDisc,
        ];
        for (final c in [
          at(0.4),
          at(3, still: true),
          at(0.2, trusted: true),
          at(4, trusted: true, trustedAt: 3.8),
          at(0, trusted: true, still: true),
        ]) {
          _expectOnly(c, palette, discs: {44});
        }
      });
    });

    group('E290 paintExit ($theme)', () {
      _StageCanvas at(double t, {ExitTransfer? transfer, bool still = false}) =>
          _paint(
            paintExit,
            _frame(
              colors,
              t: t,
              still: still,
              input: StageInput(transfer: transfer),
            ),
          );

      List<_Draw> base(_StageCanvas c) => _paths(c, 2, colors.stageBorder);

      List<_Draw> flow(_StageCanvas c) => _paths(c, 2.4, colors.primary);

      List<_Draw> outline(_StageCanvas c) => _paths(c, 2.4, colors.card);

      List<_Draw> fileDraws(_StageCanvas c) {
        final found = outline(c);
        if (found.isEmpty) return const [];
        return c.draws.sublist(c.draws.indexOf(found.single) + 1);
      }

      double fileX(_StageCanvas c) =>
          _single(outline(c)).matrix.entry(0, 3) - 137;

      test('without a transfer: the two discs and the still stageBorder '
          'line, nothing else, at any t', () {
        final reference = _picture(at(0));
        for (final t in _wild) {
          for (final still in [false, true]) {
            final c = at(t, still: still);
            expect(_picture(c), reference, reason: '$t $still');
            expect(flow(c), isEmpty);
            expect(_cometDraws(c), isEmpty);
            expect(outline(c), isEmpty);
            expect(c.calls.contains(#drawParagraph), isFalse);
            _expectDashes(_single(base(c)), 0, '$t');
          }
        }
        final c = at(1);
        _expectSameGlyph(
          _glyphStrokes(_glyphPathsNear(c.draws, const Offset(242, 85))),
          _glyphRef(
            Glyphs.pc,
            const Offset(242, 85),
            24 * 30 / 22,
            colors.text,
            1.5,
          ),
        );
      });

      test('this device: a pc disc of 30 at (58, 85) with a primary rim and '
          'a primaryInk glyph', () {
        for (final transfer in [null, _toOther, _toHub]) {
          final c = at(1, transfer: transfer);
          const spot = Offset(58, 85);
          final fills = _circles(c, 30, stroked: false, at: spot);
          final body = _single([
            for (final d in fills)
              if (d.paint.shader != null) d,
          ]);
          final tint = [
            for (final d in fills)
              if (d.paint.shader == null) d,
          ];
          if (colors.discTint > 0) {
            final layer = _single(tint);
            expect(_sameRgb(layer.paint.color, colors.primary), isTrue);
            expect(
              layer.visibleAlpha,
              closeTo(colors.primary.a * colors.discTint, 1e-6),
            );
            expect(c.draws.indexOf(layer), greaterThan(c.draws.indexOf(body)));
          } else {
            expect(tint, isEmpty);
          }
          final rim = _single(_circles(c, 30, stroked: true, at: spot));
          expect(_same(rim.paint.color, colors.primary), isTrue);
          expect(rim.paint.strokeWidth, closeTo(1.6, 1e-6));
          _expectSameGlyph(
            _glyphStrokes(_glyphPathsNear(c.draws, spot)),
            _glyphRef(Glyphs.pc, spot, 24 * 30 / 22, colors.primaryInk, 1.5),
          );
        }
      });

      test('the other device: a disc of 30 at (242, 85) with a stageBorder '
          'rim and the peer glyph in text', () {
        for (final (transfer, glyph) in [
          (null, Glyphs.pc),
          (_toOther, Glyphs.phone),
          (_toHub, Glyphs.pc),
        ]) {
          final c = at(1, transfer: transfer);
          const spot = Offset(242, 85);
          final body = _single(_circles(c, 30, stroked: false, at: spot));
          expect(body.paint.shader, isNotNull);
          final rim = _single(_circles(c, 30, stroked: true, at: spot));
          expect(_same(rim.paint.color, colors.stageBorder), isTrue);
          expect(rim.paint.strokeWidth, closeTo(1.6, 1e-6));
          _expectSameGlyph(
            _glyphStrokes(_glyphPathsNear(c.draws, spot)),
            _glyphRef(glyph, spot, 24 * 30 / 22, colors.text, 1.5),
          );
        }
      });

      test('the base line: stageBorder, 2 wide, round 3 6 dashes from '
          '(94, 85) to (206, 85), never moving', () {
        for (final t in [0.0, 0.1, 0.37, 2.2]) {
          final line = _single(base(at(t, transfer: _toOther)));
          expect(line.paint.strokeCap, StrokeCap.round);
          _expectDashes(line, 0, '$t');
          expect(line.metrics.first.length, closeTo(3, 1e-6));
        }
      });

      test('the flow line: primary, 2.4 wide, round 3 6 dashes moving 18 px '
          'per second towards the other device', () {
        for (final t in [0.0, 0.1, 0.37, 1.23, 4.9]) {
          final line = _single(flow(at(t, transfer: _toOther)), '$t');
          expect(line.paint.strokeCap, StrokeCap.round);
          _expectDashes(line, 18 * t, 'forward $t');
        }
      });

      test('towardsHub: the flow line moves towards this device', () {
        for (final t in [0.1, 0.37, 1.23, 4.9]) {
          _expectDashes(
            _single(flow(at(t, transfer: _toHub))),
            -18 * t,
            'backward $t',
          );
        }
      });

      test('four comets on a 5 s cycle along the lab curves, three dots of '
          '2.6, 2 and 1.5 at 100, 50 and 25 % lagging 0.07 s', () {
        for (final t in [0.7, 1.3, 1.55, 2.4, 3.25, 4.1, 4.75, 5.075, 7.4]) {
          _expectDots(
            _cometDraws(at(t, transfer: _toOther)),
            _expectedDots(t, colors, hub: false),
            '$t',
          );
        }
        final top = _cometDraws(at(0.7, transfer: _toOther));
        expect(
          top.any((d) => _near(d.center, const Offset(150, 49.75), 1e-3)),
          isTrue,
        );
        expect(_cometDraws(at(1.55, transfer: _toOther)), isEmpty);
        expect(_cometDraws(at(4.1, transfer: _toOther)), hasLength(6));
      });

      test('comets fade in over 3 % and out over 4 % of the cycle', () {
        final fadingIn = _cometDraws(at(5.075, transfer: _toOther));
        final lead = fadingIn.firstWhere((d) => d.baseRadius == 2.6);
        expect(lead.visibleAlpha, closeTo(colors.primary.a * 0.5, 1e-6));
        final fadingOut = _cometDraws(at(1.3, transfer: _toOther));
        final last = fadingOut.firstWhere((d) => d.baseRadius == 2.6);
        expect(last.visibleAlpha, closeTo(colors.primary.a * 0.5, 1e-6));
      });

      test('towardsHub: the comets run the curves backwards', () {
        for (final t in [0.35, 1.05, 2.4, 3.9, 6.05]) {
          _expectDots(
            _cometDraws(at(t, transfer: _toHub)),
            _expectedDots(t, colors, hub: true),
            '$t',
          );
        }
        final forward = _cometDraws(at(0.35, transfer: _toOther));
        final backward = _cometDraws(at(0.35, transfer: _toHub));
        expect(
          forward.firstWhere((d) => d.baseRadius == 2.6).center.dx,
          lessThan(150),
        );
        expect(
          backward.firstWhere((d) => d.baseRadius == 2.6).center.dx,
          greaterThan(150),
        );
      });

      test('the lagging dots are already on their previous cycle at the '
          'start of the scene, as with the negative begin of the lab', () {
        for (final t in [0.05, 0.1]) {
          _expectDots(
            _cometDraws(at(t, transfer: _toOther)),
            _expectedDots(t, colors, hub: false),
            '$t',
          );
        }
      });

      test('the file crosses from -62 to 62 px in 2.6 s with labEaseInOut '
          'and fades in by 12 % and out from 88 %', () {
        for (final hub in [false, true]) {
          for (final t in [
            0.0,
            0.13,
            0.26,
            0.9,
            1.3,
            2.0,
            2.288,
            2.47,
            2.59,
            3.9,
          ]) {
            final p = (t % 2.6) / 2.6;
            final eased = _labInOut.transform(p);
            final x = (hub ? -1 : 1) * (-62 + 124 * eased);
            final opacity = p < 0.12
                ? _labInOut.transform(p / 0.12)
                : p < 0.88
                ? 1.0
                : 1 - _labInOut.transform((p - 0.88) / 0.12);
            final c = at(t, transfer: hub ? _toHub : _toOther);
            if (!(opacity > 0)) {
              expect(outline(c), isEmpty, reason: '$hub $t');
              continue;
            }
            final drawn = _single(outline(c), '$hub $t');
            expect(fileX(c), closeTo(x, 1e-6), reason: '$hub $t');
            expect(drawn.matrix.entry(1, 3), closeTo(69, 1e-9));
            expect(drawn.scale, closeTo(0.85, 1e-9));
            expect(drawn.alpha, closeTo(opacity, 1e-6), reason: '$hub $t');
            for (final d in fileDraws(c)) {
              expect(d.alpha, closeTo(opacity, 1e-6));
            }
          }
        }
        expect(fileX(at(0.65, transfer: _toOther)), lessThan(0));
        expect(fileX(at(0.65, transfer: _toHub)), greaterThan(0));
      });

      test('the file is paintFileIcon of the kind at 0.85 with a 2.4 card '
          'outline drawn first', () {
        for (final transfer in [_toOther, _toHub]) {
          final c = at(1.3, transfer: transfer);
          final drawn = _single(outline(c));
          expect(drawn.path.getBounds(), _rect(fileSheetPath.getBounds()));
          expect(drawn.paint.strokeWidth, closeTo(2.4, 1e-6));
          expect(_same(drawn.paint.color, colors.card), isTrue);
          final x = fileX(c);
          final reference = _record(
            (canvas) => paintFileIcon(
              canvas,
              Rect.fromLTWH(137 + x, 69, 32 * 0.85, 38 * 0.85),
              transfer.kind,
            ),
          );
          expect(
            [for (final d in fileDraws(c)) _signature(d, alpha: false)],
            [for (final d in reference.draws) _signature(d, alpha: false)],
          );
          expect(fileDraws(c), isNotEmpty);
        }
      });

      test('still: the flow line at rest, the file in the centre, no comets, '
          'at any t', () {
        for (final transfer in [_toOther, _toHub]) {
          final reference = _picture(at(0, transfer: transfer, still: true));
          for (final t in _wild) {
            final c = at(t, transfer: transfer, still: true);
            expect(_picture(c), reference, reason: '$t');
            expect(_cometDraws(c), isEmpty);
            expect(fileX(c), closeTo(0, 1e-9));
            expect(_single(outline(c)).alpha, closeTo(1, 1e-9));
            _expectDashes(_single(flow(c)), 0, 'still $t');
          }
        }
      });

      test('the layers follow the lab order', () {
        final c = at(0.7, transfer: _toOther);
        _expectOrder(c, [
          _single(_circles(c, 30, stroked: true, at: const Offset(58, 85))),
          _single(_circles(c, 30, stroked: true, at: const Offset(242, 85))),
          _single(base(c)),
          _single(flow(c)),
          _cometDraws(c).first,
          _single(outline(c)),
          fileDraws(c).first,
        ]);
      });

      test('uses only colours of NbColors and of the file icon', () {
        for (final transfer in [null, _toOther, _toHub]) {
          final fileColors = transfer == null
              ? const <Color>[]
              : [
                  for (final d in _record(
                    (canvas) => paintFileIcon(
                      canvas,
                      const Rect.fromLTWH(0, 0, 32, 38),
                      transfer.kind,
                    ),
                  ).draws)
                    d.paint.color,
                ];
          final palette = [
            colors.primary,
            colors.primaryInk,
            colors.stageBorder,
            colors.text,
            colors.hubTop,
            colors.card,
            ...fileColors,
          ];
          for (final c in [
            at(0.7, transfer: transfer),
            at(2.4, transfer: transfer),
            at(4.1, transfer: transfer),
            at(0, transfer: transfer, still: true),
          ]) {
            _expectOnly(c, palette, discs: {30});
          }
        }
      });
    });

    group('E290 StagePainter ($theme)', () {
      StagePainter painterOf(_Case item, double t, {bool still = false}) =>
          StagePainter(
            scene: item.scene,
            input: item.input,
            colors: colors,
            still: still,
            changes: item.changes,
            elapsed: ValueNotifier<double>(t),
          );

      test('the 18 scenes each have their painter', () {
        expect(_scenePainters.keys.toSet(), StageScene.values.toSet());
        final pictures = {
          for (final scene in StageScene.values)
            _picture(
              _record(
                (canvas) => StagePainter(
                  scene: scene,
                  input: const StageInput(),
                  colors: colors,
                  still: false,
                  changes: const StageChanges(),
                  elapsed: ValueNotifier<double>(1.7),
                ).paint(canvas, const Size(300, 170)),
              ),
            ).join('\n'),
        };
        expect(pictures, hasLength(StageScene.values.length));
      });

      test('each scene paints the halo and then its own painter', () {
        for (final item in _cases()) {
          for (final t in [0.3, 1.7, 4.2]) {
            for (final still in [false, true]) {
              final frame = _frame(
                colors,
                t: t,
                still: still,
                input: item.input,
                changes: item.changes,
              );
              final actual = _StageCanvas();
              painterOf(
                item,
                t,
                still: still,
              ).paint(actual, const Size(300, 170));
              final expected = _record(
                _reference(item.scene, frame, colors.primary),
              );
              expect(
                _picture(actual),
                _picture(expected),
                reason: '${item.name} $t $still',
              );
              _expectSound(actual, reason: item.name);
            }
          }
        }
      });

      test('the halo goes first and the viewBox is scaled to the stage width, '
          'moved 37 px up in wide', () {
        for (final item in _cases()) {
          final box = _boxOf(item.scene);
          final canvas = _StageCanvas();
          painterOf(item, 1.1).paint(canvas, Size(box.width, box.height));
          final halo = canvas.draws.first;
          expect(halo.name, #drawCircle, reason: item.name);
          expect(halo.baseRadius, closeTo(140, 1e-9));
          expect(halo.paint.shader, isNotNull);
          final s = box.width / 300;
          expect(halo.matrix.entry(0, 0), closeTo(s, 1e-9));
          expect(halo.matrix.entry(1, 1), closeTo(s * 84 / 140, 1e-9));
          expect(halo.matrix.entry(0, 3), closeTo(150 * s, 1e-9));
          expect(
            halo.matrix.entry(1, 3),
            closeTo((85 - box.top) * s, 1e-9),
            reason: item.name,
          );
          final frame = _frame(
            colors,
            t: 1.1,
            input: item.input,
            changes: item.changes,
          );
          final expected = _record((canvas) {
            canvas.save();
            canvas.scale(s);
            _reference(item.scene, frame, colors.primary)(canvas);
            canvas.restore();
          });
          expect(_picture(canvas), _picture(expected), reason: item.name);
        }
      });

      testWidgets('the halo has the tone of its scene', (tester) async {
        for (final item in _cases()) {
          const t = 1.2;
          final frame = _frame(
            colors,
            t: t,
            input: item.input,
            changes: item.changes,
          );
          final actual = await _pixels(
            tester,
            (canvas) => painterOf(item, t).paint(canvas, const Size(300, 170)),
          );
          final tone = _toneOf(item.scene, colors, trusted: item.input.trusted);
          final expected = await _pixels(
            tester,
            _reference(item.scene, frame, tone),
          );
          expect(_differences(actual, expected), 0, reason: item.name);
          final wrong = _sameRgb(tone, colors.danger)
              ? colors.primary
              : colors.danger;
          final other = await _pixels(
            tester,
            _reference(item.scene, frame, wrong),
          );
          expect(
            _differences(actual, other),
            greaterThan(0),
            reason: item.name,
          );
        }
      });

      test('repaints when elapsed changes', () {
        final elapsed = ValueNotifier<double>(0);
        final painter = StagePainter(
          scene: StageScene.network,
          input: const StageInput(),
          colors: colors,
          still: false,
          changes: const StageChanges(),
          elapsed: elapsed,
        );
        var calls = 0;
        painter.addListener(() => calls++);
        elapsed.value = 0.5;
        elapsed.value = 0.75;
        expect(calls, 2);
      });

      test('shouldRepaint compares scene, input, colours, still and changes '
          'by value', () {
        final elapsed = ValueNotifier<double>(0);
        StagePainter make({
          StageScene scene = StageScene.mine,
          StageInput input = const StageInput(hovered: Own.mine),
          NbColors? palette,
          bool still = false,
          StageChanges changes = const StageChanges(hoveredAt: 1),
        }) => StagePainter(
          scene: scene,
          input: input,
          colors: palette ?? colors,
          still: still,
          changes: changes,
          elapsed: elapsed,
        );

        final base = make();
        expect(make().shouldRepaint(base), isFalse);
        expect(
          make(
            input: StageInput(hovered: Own.values.first),
            changes: StageChanges(hoveredAt: [1.0].single),
          ).shouldRepaint(base),
          isFalse,
        );
        expect(make(scene: StageScene.network).shouldRepaint(base), isTrue);
        expect(
          make(input: const StageInput(hovered: Own.other)).shouldRepaint(base),
          isTrue,
        );
        expect(
          make(
            palette: identical(colors, NbColors.light)
                ? NbColors.dark
                : NbColors.light,
          ).shouldRepaint(base),
          isTrue,
        );
        expect(make(still: true).shouldRepaint(base), isTrue);
        expect(
          make(changes: const StageChanges(hoveredAt: 2)).shouldRepaint(base),
          isTrue,
        );
      });
    });
  }

  for (final (theme, colors, brightness) in _themes) {
    group('E290 the small stage of the code first (point 244, $theme)', () {
      const small = StageSize.small;
      final s = small.width / 300;
      const box = Rect.fromLTWH(0, 0, 144, 60);
      const input = StageInput(peer: DeviceGlyph.phone);

      StagePainter painterOf(
        StageScene scene,
        double t, {
        bool still = false,
        StageSize? size = small,
      }) => StagePainter(
        scene: scene,
        input: input,
        colors: colors,
        still: still,
        changes: const StageChanges(),
        size: size,
        elapsed: ValueNotifier<double>(t),
      );

      testWidgets('a given size wins over the size of the scene, with its '
          'margin below, in every scene', (tester) async {
        for (final scene in StageScene.values) {
          await tester.pumpWidget(
            _stage(scene, brightness: brightness, size: small),
          );
          expect(
            tester.getSize(find.byType(ModalStage)),
            Size(small.width, small.height + small.margin),
            reason: scene.name,
          );
          expect(
            tester.getSize(_customPaint()),
            Size(small.width, small.height),
          );
          expect(
            tester.getTopLeft(_customPaint()),
            tester.getTopLeft(find.byType(ModalStage)),
          );
          expect(_painter(tester).size, small, reason: scene.name);
          expect(tester.takeException(), isNull);
        }
      });

      testWidgets('without a size each scene keeps its own', (tester) async {
        for (final scene in StageScene.values) {
          await tester.pumpWidget(_stage(scene, brightness: brightness));
          final own = _boxOf(scene);
          expect(
            tester.getSize(find.byType(ModalStage)),
            Size(own.width, own.height + own.margin),
            reason: scene.name,
          );
        }
      });

      for (final scene in [StageScene.comparing, StageScene.waiting]) {
        test('${scene.name}: the viewBox is scaled to 144 px and its centre '
            'is the centre of the box', () {
          for (final t in [0.0, 1.7, 4.2]) {
            for (final still in [false, true]) {
              final canvas = _StageCanvas();
              painterOf(
                scene,
                t,
                still: still,
              ).paint(canvas, Size(small.width, small.height));
              final halo = canvas.draws.first;
              expect(halo.name, #drawCircle);
              expect(halo.baseRadius, closeTo(140, 1e-9));
              expect(halo.matrix.entry(0, 0), closeTo(s, 1e-9));
              expect(halo.matrix.entry(0, 3), closeTo(box.center.dx, 1e-9));
              expect(halo.matrix.entry(1, 3), closeTo(box.center.dy, 1e-9));
              final frame = _frame(colors, t: t, still: still, input: input);
              final expected = _record((canvas) {
                canvas.save();
                canvas.scale(s);
                canvas.translate(0, -small.viewTop);
                paintHalo(canvas, frame, _toneOf(scene, colors));
                _scenePainters[scene]!(canvas, frame);
                canvas.restore();
              });
              expect(_picture(canvas), _picture(expected), reason: '$t $still');
              _expectSound(canvas, reason: '${scene.name} $t $still');
            }
          }
        });

        test('${scene.name}: the ring is whole inside the box and about '
            '56 px wide', () {
          for (final t in [0.0, 1.7, 4.2]) {
            for (final still in [false, true]) {
              final canvas = _StageCanvas();
              painterOf(
                scene,
                t,
                still: still,
              ).paint(canvas, Size(small.width, small.height));
              final rings = [
                for (final draw in canvas.draws)
                  if (draw.stroked &&
                      (draw.localBounds.width - 112).abs() < 1 &&
                      (draw.localBounds.center - _center).distance < 0.5)
                    draw,
              ];
              expect(rings, isNotEmpty, reason: '$t $still');
              for (final ring in rings) {
                final bounds = ring.name == #drawPath
                    ? ring.path
                          .transform(ring.matrix.storage)
                          .getBounds()
                          .inflate(ring.paint.strokeWidth / 2 * ring.scale)
                    : ring.stageBounds;
                expect(bounds.width, inInclusiveRange(52, 60));
                expect(bounds.center.dx, closeTo(box.center.dx, 0.3));
                expect(bounds.center.dy, closeTo(box.center.dy, 0.3));
                expect(bounds.left, greaterThanOrEqualTo(box.left));
                expect(bounds.right, lessThanOrEqualTo(box.right));
                expect(bounds.top, greaterThanOrEqualTo(box.top));
                expect(bounds.bottom, lessThanOrEqualTo(box.bottom));
              }
            }
          }
        });
      }

      test('without a size the painter keeps the viewBox of the scene', () {
        for (final scene in StageScene.values) {
          final own = _boxOf(scene);
          final canvas = _StageCanvas();
          painterOf(
            scene,
            1.1,
            size: null,
          ).paint(canvas, Size(own.width, own.height));
          final halo = canvas.draws.first;
          final scale = own.width / 300;
          expect(halo.matrix.entry(0, 0), closeTo(scale, 1e-9));
          expect(
            halo.matrix.entry(1, 3),
            closeTo((85 - own.top) * scale, 1e-9),
            reason: scene.name,
          );
        }
      });

      test('shouldRepaint also compares the size', () {
        final elapsed = ValueNotifier<double>(0);
        StagePainter make(StageSize? size) => StagePainter(
          scene: StageScene.comparing,
          input: const StageInput(),
          colors: colors,
          still: false,
          changes: const StageChanges(),
          size: size,
          elapsed: elapsed,
        );
        expect(make(small).shouldRepaint(make(small)), isFalse);
        expect(make(null).shouldRepaint(make(null)), isFalse);
        expect(make(small).shouldRepaint(make(StageSize.mid)), isTrue);
        expect(make(small).shouldRepaint(make(null)), isTrue);
      });
    });
  }

  group('E290 the stage that fills the code view (point 247)', () {
    test('the range goes from the small stage to the big one', () {
      final range = StageFit.range;
      expect(range.min, StageSize.small.height + StageSize.small.margin);
      expect(range.max, StageSize.big.height + StageSize.big.margin);
    });

    test('at both ends the fit is the small and the big stage', () {
      final low = StageFit.of(StageFit.range.min);
      expect(low.width, StageSize.small.width);
      expect(low.height, StageSize.small.height);
      expect(low.margin, StageSize.small.margin);
      expect(low.viewTop, closeTo(StageSize.small.viewTop, 1e-9));
      final high = StageFit.of(StageFit.range.max);
      expect(high.width, StageSize.big.width);
      expect(high.height, StageSize.big.height);
      expect(high.margin, StageSize.big.margin);
      expect(high.viewTop, closeTo(StageSize.big.viewTop, 0.05));
      expect(StageFit.of(10).extent, StageFit.range.min);
      expect(StageFit.of(900).extent, StageFit.range.max);
    });

    test('in between it grows without jumps and keeps the centre of the '
        'viewBox in the centre of the box', () {
      var previous = StageFit.of(StageFit.range.min);
      for (
        var extent = StageFit.range.min + 1;
        extent <= StageFit.range.max;
        extent += 1
      ) {
        final fit = StageFit.of(extent);
        expect(fit.extent, closeTo(extent, 1e-9));
        expect(fit.width, greaterThan(previous.width));
        expect(fit.height, greaterThan(previous.height));
        expect(fit.width, lessThanOrEqualTo(StageSize.big.width));
        expect(
          (_center.dy - fit.viewTop) * fit.width / 300,
          closeTo(fit.height / 2, 1e-9),
        );
        expect(fit.height * 300 / fit.width, lessThanOrEqualTo(170 + 0.1));
        previous = fit;
      }
    });

    for (final (theme, colors, brightness) in _themes) {
      for (final scene in [StageScene.comparing, StageScene.waiting]) {
        testWidgets('${scene.name} ($theme): the box takes the given height '
            'and the drawing is scaled to it, centred and whole', (
          tester,
        ) async {
          for (final extent in [68.0, 110.0, 157.0, 186.0, 211.0, 400.0]) {
            await tester.pumpWidget(
              Directionality(
                textDirection: TextDirection.ltr,
                child: MediaQuery(
                  data: const MediaQueryData(disableAnimations: true),
                  child: Theme(
                    data: buildTheme(brightness),
                    child: Center(
                      child: SizedBox(
                        height: extent,
                        child: Align(
                          alignment: Alignment.topCenter,
                          child: ModalStage.fill(scene: scene),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            );
            final fit = StageFit.of(extent);
            final box = tester.getSize(find.byType(ModalStage));
            expect(box.width, closeTo(fit.width, 1e-6), reason: '$extent');
            expect(box.height, closeTo(fit.extent, 1e-6), reason: '$extent');
            final paint = tester.getSize(_customPaint());
            expect(paint.width, closeTo(fit.width, 1e-6));
            expect(paint.height, closeTo(fit.height, 1e-6));
            final painter = _painter(tester);
            expect(painter.viewTop, fit.viewTop);
            expect(painter.size, isNull);

            for (final t in [0.0, 1.7, 4.2]) {
              final canvas = _StageCanvas();
              StagePainter(
                scene: scene,
                input: const StageInput(),
                colors: colors,
                still: false,
                changes: const StageChanges(),
                viewTop: fit.viewTop,
                elapsed: ValueNotifier<double>(t),
              ).paint(canvas, Size(fit.width, fit.height));
              final halo = canvas.draws.first;
              expect(halo.name, #drawCircle);
              expect(halo.matrix.entry(0, 0), closeTo(fit.width / 300, 1e-9));
              expect(halo.matrix.entry(0, 3), closeTo(fit.width / 2, 1e-9));
              expect(halo.matrix.entry(1, 3), closeTo(fit.height / 2, 1e-9));
              final rings = [
                for (final draw in canvas.draws)
                  if (draw.stroked &&
                      (draw.localBounds.width - 112).abs() < 1 &&
                      (draw.localBounds.center - _center).distance < 0.5)
                    draw,
              ];
              expect(rings, isNotEmpty, reason: '$extent $t');
              final box = Rect.fromLTWH(0, 0, fit.width, fit.height);
              for (final ring in rings) {
                final bounds = ring.name == #drawPath
                    ? ring.path
                          .transform(ring.matrix.storage)
                          .getBounds()
                          .inflate(ring.paint.strokeWidth / 2 * ring.scale)
                    : ring.stageBounds;
                expect(bounds.center.dx, closeTo(box.center.dx, 0.3));
                expect(bounds.center.dy, closeTo(box.center.dy, 0.3));
                expect(bounds.left, greaterThanOrEqualTo(box.left));
                expect(bounds.right, lessThanOrEqualTo(box.right));
                expect(bounds.top, greaterThanOrEqualTo(box.top));
                expect(bounds.bottom, lessThanOrEqualTo(box.bottom));
              }
              _expectSound(canvas, reason: '${scene.name} $extent $t');
            }
          }
          expect(tester.takeException(), isNull);
        });
      }

      test('shouldRepaint also compares the viewTop ($theme)', () {
        final elapsed = ValueNotifier<double>(0);
        StagePainter make(double? viewTop) => StagePainter(
          scene: StageScene.waiting,
          input: const StageInput(),
          colors: colors,
          still: false,
          changes: const StageChanges(),
          viewTop: viewTop,
          elapsed: elapsed,
        );
        expect(make(10).shouldRepaint(make(10)), isFalse);
        expect(make(10).shouldRepaint(make(12)), isTrue);
        expect(make(10).shouldRepaint(make(null)), isTrue);
      });
    }
  });

  group('E290 sound painting at any t', () {
    for (final (theme, colors, _) in _themes) {
      test('StagePainter of every scene never throws and stays sound '
          '($theme)', () {
        for (final item in _cases()) {
          for (final t in _wild) {
            for (final still in [false, true]) {
              final canvas = _StageCanvas();
              StagePainter(
                scene: item.scene,
                input: item.input,
                colors: colors,
                still: still,
                changes: item.changes,
                elapsed: ValueNotifier<double>(t),
              ).paint(canvas, Size(_boxOf(item.scene).width, 195));
              _expectSound(canvas, reason: '${item.name} $t $still');
            }
          }
        }
      });

      test('the three choice painters stay sound with any change ($theme)', () {
        const changes = [
          StageChanges(),
          StageChanges(hoveredAt: 0.4, hoveredFrom: Own.other, knobFrom: 26),
          StageChanges(pickedAt: 2, knobFrom: -26, trustedAt: 2),
          StageChanges(hoveredAt: 1e9, pickedAt: 1e9, trustedAt: 1e9),
        ];
        for (final t in _wild) {
          for (final still in [false, true]) {
            for (final change in changes) {
              for (final input in [
                const StageInput(),
                const StageInput(peer: DeviceGlyph.phone, hovered: Own.mine),
                const StageInput(hovered: Own.other, picked: Own.other),
                const StageInput(picked: Own.mine, trusted: true),
                const StageInput(transfer: _toOther),
                const StageInput(transfer: _toHub, trusted: true),
              ]) {
                final frame = _frame(
                  colors,
                  t: t,
                  still: still,
                  input: input,
                  changes: change,
                );
                for (final painter in [
                  paintMineSwitch,
                  paintNetwork,
                  paintExit,
                ]) {
                  _expectSound(
                    _paint(painter, frame),
                    reason: '$t $still $input',
                  );
                }
              }
            }
          }
        }
      });
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

    test('the blur reader reads the sigma of an ImageFilter.blur', () {
      final canvas = _record((canvas) {
        canvas.saveLayer(
          null,
          Paint()
            ..imageFilter = ui.ImageFilter.blur(sigmaX: 1.25, sigmaY: 1.25),
        );
        canvas.drawCircle(const Offset(1, 1), 1, Paint());
        canvas.restore();
      });
      expect(_blurOf(canvas.draws.single), closeTo(1.25, 1e-9));
    });
  });

  for (final (theme, colors, brightness) in _themes) {
    group('E290 ModalStage ($theme)', () {
      testWidgets('each scene takes its size, with its margin below, inside '
          'ExcludeSemantics and a RepaintBoundary', (tester) async {
        for (final scene in StageScene.values) {
          await tester.pumpWidget(_stage(scene, brightness: brightness));
          final box = _boxOf(scene);
          final stage = find.byType(ModalStage);
          expect(
            tester.getSize(stage),
            Size(box.width, box.height + box.margin),
            reason: scene.name,
          );
          expect(tester.getSize(_customPaint()), Size(box.width, box.height));
          expect(tester.getTopLeft(_customPaint()), tester.getTopLeft(stage));
          final exclude = find.descendant(
            of: stage,
            matching: find.byType(ExcludeSemantics),
          );
          expect(exclude, findsOneWidget);
          expect(tester.widget<ExcludeSemantics>(exclude).excluding, isTrue);
          final boundary = find.descendant(
            of: exclude,
            matching: find.byType(RepaintBoundary),
          );
          expect(boundary, findsOneWidget);
          expect(
            find.descendant(of: boundary, matching: find.byType(CustomPaint)),
            findsOneWidget,
          );
          expect(tester.takeException(), isNull);
        }
      });

      testWidgets('the painter gets the scene, the input, the theme colours '
          'and still', (tester) async {
        const input = StageInput(peer: DeviceGlyph.phone, transfer: _toOther);
        await tester.pumpWidget(
          _stage(StageScene.exit, input: input, brightness: brightness),
        );
        final painter = _painter(tester);
        expect(painter.scene, StageScene.exit);
        expect(painter.input, input);
        expect(identical(painter.colors, colors), isTrue);
        expect(painter.still, isFalse);
        expect(painter.changes, const StageChanges());
      });

      testWidgets('one Ticker, made once: it survives scene and input changes '
          'and dies with the stage', (tester) async {
        await tester.pumpWidget(
          _stage(StageScene.network, brightness: brightness),
        );
        expect(_live(tester), 1);
        await tester.pump();
        await _advance(tester, 1);
        await tester.pumpWidget(
          _stage(
            StageScene.network,
            input: const StageInput(trusted: true),
            brightness: brightness,
          ),
        );
        expect(tester.takeException(), isNull);
        expect(_live(tester), lessThanOrEqualTo(1));
        await tester.pumpWidget(
          _stage(StageScene.busy, brightness: brightness),
        );
        expect(tester.takeException(), isNull);
        expect(_live(tester), 1);
        await _advance(tester, 0.4);
        await tester.pumpWidget(
          _stage(
            StageScene.mine,
            input: const StageInput(hovered: Own.mine),
            brightness: brightness,
          ),
        );
        await tester.pumpWidget(
          _stage(
            StageScene.mine,
            input: const StageInput(picked: Own.mine),
            brightness: brightness,
          ),
        );
        expect(tester.takeException(), isNull);
        expect(_live(tester), 1);
        await tester.pumpWidget(const SizedBox());
        expect(tester.takeException(), isNull);
        expect(_live(tester), 0);
        await _advance(tester, 1);
        expect(_live(tester), 0);
      });

      testWidgets('t starts at 0 with the first frame and follows the clock', (
        tester,
      ) async {
        await tester.pumpWidget(
          _stage(StageScene.network, brightness: brightness),
        );
        await tester.pump();
        expect(_ringSeconds(tester, colors), closeTo(0, 1e-6));
        await _advance(tester, 2.5);
        expect(_ringSeconds(tester, colors), closeTo(2.5, 1e-6));
        await _advance(tester, 1.25);
        expect(_ringSeconds(tester, colors), closeTo(3.75, 1e-6));
      });

      testWidgets('a scene change puts t back to 0 and clears the changes', (
        tester,
      ) async {
        await tester.pumpWidget(
          _stage(StageScene.network, brightness: brightness),
        );
        await tester.pump();
        await _advance(tester, 3);
        await tester.pumpWidget(
          _stage(
            StageScene.network,
            input: const StageInput(trusted: true),
            brightness: brightness,
          ),
        );
        expect(_painter(tester).changes.trustedAt, closeTo(3, 1e-9));
        await tester.pumpWidget(
          _stage(StageScene.busy, brightness: brightness),
        );
        expect(_painter(tester).scene, StageScene.busy);
        expect(_painter(tester).changes, const StageChanges());
        expect(_live(tester), 1);
        await tester.pump();
        expect(_ringSeconds(tester, colors), closeTo(0, 1e-6));
        await _advance(tester, 1.5);
        expect(_ringSeconds(tester, colors), closeTo(1.5, 1e-6));
      });

      testWidgets('a scene change takes the hover of the new input', (
        tester,
      ) async {
        await tester.pumpWidget(
          _stage(
            StageScene.network,
            input: const StageInput(hovered: Own.mine),
            brightness: brightness,
          ),
        );
        await tester.pump();
        await _advance(tester, 1);
        await tester.pumpWidget(
          _stage(
            StageScene.mine,
            input: const StageInput(hovered: Own.other),
            brightness: brightness,
          ),
        );
        expect(_painter(tester).input.hovered, Own.other);
        expect(_painter(tester).changes, const StageChanges());
        await tester.pump();
        expect(_knobAt(tester), 26);
      });

      testWidgets('a scene without loops stops at introEnd', (tester) async {
        final cases = [
          for (final scene in StageScene.values)
            if (!_looping.contains(scene) && scene != StageScene.network)
              (scene, const StageInput()),
          (StageScene.network, const StageInput(trusted: true)),
        ];
        expect(cases, hasLength(8));
        for (final (scene, input) in cases) {
          await tester.pumpWidget(const SizedBox());
          await tester.pumpWidget(
            _stage(scene, input: input, brightness: brightness),
          );
          final end = stageSpecOf(scene, input).introEnd;
          expect(_live(tester), 1, reason: scene.name);
          await tester.pump();
          await _advance(tester, end - 0.05);
          expect(_live(tester), 1, reason: scene.name);
          await _advance(tester, 0.1);
          expect(_live(tester), 0, reason: scene.name);
          await _advance(tester, 5);
          expect(_live(tester), 0, reason: scene.name);
        }
        expect(tester.takeException(), isNull);
      });

      testWidgets('scenes with loops never stop', (tester) async {
        final cases = [
          for (final scene in _looping) (scene, const StageInput()),
          (StageScene.network, const StageInput()),
          (StageScene.mine, const StageInput(picked: Own.mine)),
        ];
        for (final (scene, input) in cases) {
          await tester.pumpWidget(const SizedBox());
          await tester.pumpWidget(
            _stage(scene, input: input, brightness: brightness),
          );
          await tester.pump();
          await _advance(tester, 40);
          expect(_live(tester), 1, reason: scene.name);
          await _advance(tester, 0.5);
          expect(_live(tester), 1, reason: scene.name);
        }
        expect(tester.takeException(), isNull);
      });

      testWidgets('changeEnd counts from the last change: network stops '
          '0.55 s after trusted', (tester) async {
        await tester.pumpWidget(
          _stage(StageScene.network, brightness: brightness),
        );
        await tester.pump();
        await _advance(tester, 2);
        await tester.pumpWidget(
          _stage(
            StageScene.network,
            input: const StageInput(trusted: true),
            brightness: brightness,
          ),
        );
        final changes = _painter(tester).changes;
        expect(changes.trustedAt, closeTo(2, 1e-9));
        expect(changes.trustedFrom, isFalse);
        await _advance(tester, 0.5);
        expect(_live(tester), 1);
        await _advance(tester, 0.1);
        expect(_live(tester), 0);
      });

      testWidgets('a change while stopped restarts the Ticker without '
          'replaying the entry', (tester) async {
        await tester.pumpWidget(
          _stage(
            StageScene.network,
            input: const StageInput(trusted: true),
            brightness: brightness,
          ),
        );
        await tester.pump();
        await _advance(tester, 0.3);
        await _advance(tester, 0.3);
        expect(_live(tester), 0);
        await _advance(tester, 2);
        await tester.pumpWidget(
          _stage(
            StageScene.network,
            input: const StageInput(trusted: true, hovered: Own.mine),
            brightness: brightness,
          ),
        );
        expect(_live(tester), 1);
        expect(_painter(tester).changes.hoveredAt, closeTo(0.6, 1e-9));
        await tester.pump();
        final disc = _single([
          for (final d in _circles(_paintNow(tester), 44, stroked: false))
            if (d.paint.shader == null) d,
        ]);
        expect(disc.radius, closeTo(44, 1e-9));
        expect(disc.visibleAlpha, closeTo(colors.success.a, 1e-9));
        await _advance(tester, 0.5);
        expect(_live(tester), 1);
        await _advance(tester, 0.1);
        expect(_live(tester), 0);
      });

      testWidgets('t does not go back when the Ticker resumes', (tester) async {
        await tester.pumpWidget(
          _stage(
            StageScene.network,
            input: const StageInput(trusted: true),
            brightness: brightness,
          ),
        );
        await tester.pump();
        await _advance(tester, 0.3);
        await _advance(tester, 0.3);
        expect(_live(tester), 0);
        await _advance(tester, 3);
        await tester.pumpWidget(
          _stage(StageScene.network, brightness: brightness),
        );
        final changes = _painter(tester).changes;
        expect(changes.trustedAt, closeTo(0.6, 1e-9));
        expect(changes.trustedFrom, isTrue);
        expect(_live(tester), 1);
        await tester.pump();
        expect(_ringSeconds(tester, colors), closeTo(0.6, 1e-6));
        await _advance(tester, 1);
        expect(_ringSeconds(tester, colors), closeTo(1.6, 1e-6));
      });

      testWidgets('only hovered, picked and trusted are recorded as changes', (
        tester,
      ) async {
        await tester.pumpWidget(
          _stage(StageScene.exit, brightness: brightness),
        );
        await tester.pump();
        await _advance(tester, 1);
        for (final input in [
          const StageInput(transfer: _toOther),
          const StageInput(transfer: _toHub, peer: DeviceGlyph.phone),
        ]) {
          await tester.pumpWidget(
            _stage(StageScene.exit, input: input, brightness: brightness),
          );
          expect(_painter(tester).input, input);
          expect(_painter(tester).changes, const StageChanges());
        }
        await tester.pumpWidget(
          _stage(StageScene.mine, brightness: brightness),
        );
        await tester.pump();
        await _advance(tester, 0.7);
        await tester.pumpWidget(
          _stage(
            StageScene.mine,
            input: const StageInput(peer: DeviceGlyph.phone),
            brightness: brightness,
          ),
        );
        expect(_painter(tester).changes, const StageChanges());
        expect(_painter(tester).input.peer, DeviceGlyph.phone);
      });

      testWidgets('mine: a hover records its t, the side it left and the knob '
          'x of that instant, without replaying the entry', (tester) async {
        await tester.pumpWidget(
          _stage(StageScene.mine, brightness: brightness),
        );
        await tester.pump();
        await _advance(tester, 1);
        await tester.pumpWidget(
          _stage(
            StageScene.mine,
            input: const StageInput(hovered: Own.mine),
            brightness: brightness,
          ),
        );
        final first = _painter(tester).changes;
        expect(first.hoveredAt, closeTo(1, 1e-9));
        expect(first.hoveredFrom, isNull);
        expect(first.pickedAt, isNull);
        expect(first.trustedAt, isNull);
        expect(first.knobFrom, closeTo(_sway(1), 0.03));
        expect(_painter(tester).input.hovered, Own.mine);
        await tester.pump();
        final badge = _single(_circles(_paintNow(tester), 10, stroked: false));
        expect(badge.radius, closeTo(10, 1e-9));
        expect(badge.visibleAlpha, closeTo(colors.success.a, 1e-9));
        await _advance(tester, 0.31);
        expect(
          _knobAt(tester),
          closeTo(_toward(first.knobFrom!, -26, 1.31, 1, 0.62), 1e-9),
        );
        await _advance(tester, 1);
        expect(_knobAt(tester), closeTo(-26, 1e-9));
      });

      testWidgets('mine: a hover that changes side half-way starts from the '
          'knob x of that instant', (tester) async {
        await tester.pumpWidget(
          _stage(StageScene.mine, brightness: brightness),
        );
        await tester.pump();
        await _advance(tester, 1);
        await tester.pumpWidget(
          _stage(
            StageScene.mine,
            input: const StageInput(hovered: Own.mine),
            brightness: brightness,
          ),
        );
        final first = _painter(tester).changes.knobFrom!;
        await _advance(tester, 0.31);
        final halfway = _toward(first, -26, 1.31, 1, 0.62);
        await tester.pumpWidget(
          _stage(
            StageScene.mine,
            input: const StageInput(hovered: Own.other),
            brightness: brightness,
          ),
        );
        final second = _painter(tester).changes;
        expect(second.hoveredAt, closeTo(1.31, 1e-9));
        expect(second.hoveredFrom, Own.mine);
        expect(second.knobFrom, closeTo(halfway, 1e-9));
        await _advance(tester, 0.31);
        expect(
          _knobAt(tester),
          closeTo(_toward(halfway, 26, 1.62, 1.31, 0.62), 1e-9),
        );
        await _advance(tester, 1);
        expect(_knobAt(tester), closeTo(26, 1e-9));
      });

      testWidgets('mine: the hover freezes after the pick', (tester) async {
        await tester.pumpWidget(
          _stage(
            StageScene.mine,
            input: const StageInput(hovered: Own.other),
            brightness: brightness,
          ),
        );
        await tester.pump();
        await _advance(tester, 2);
        await tester.pumpWidget(
          _stage(
            StageScene.mine,
            input: const StageInput(picked: Own.other),
            brightness: brightness,
          ),
        );
        final picked = _painter(tester).changes;
        expect(picked.pickedAt, closeTo(2, 1e-9));
        expect(picked.pickedFrom, isNull);
        expect(picked.hoveredAt, isNull);
        expect(picked.knobFrom, closeTo(26, 1e-9));
        expect(_painter(tester).input.hovered, Own.other);
        expect(_painter(tester).input.picked, Own.other);
        await _advance(tester, 0.2);
        for (final hovered in [Own.mine, null, Own.other, Own.mine]) {
          await tester.pumpWidget(
            _stage(
              StageScene.mine,
              input: StageInput(hovered: hovered, picked: Own.other),
              brightness: brightness,
            ),
          );
          expect(_painter(tester).changes, picked);
          expect(_painter(tester).input.hovered, Own.other);
        }
        await _advance(tester, 0.225);
        expect(_knobAt(tester), closeTo(_toward(26, 82, 2.425, 2, 0.85), 1e-9));
        await _advance(tester, 1);
        expect(_knobAt(tester), closeTo(82, 1e-9));
      });

      for (final own in Own.values) {
        testWidgets('mine: after picking ${own.name}, every frame of the '
            'farewell takes the knob rim only toward the tone', (tester) async {
          final tone = own == Own.mine ? colors.primary : colors.textWeak;
          Color rim() =>
              _single(_circles(_paintNow(tester), 36, stroked: true))
                  .paint
                  .color;
          double gap(Color a, Color b) =>
              (a.r - b.r).abs() + (a.g - b.g).abs() + (a.b - b.b).abs();

          await tester.pumpWidget(
            _stage(
              StageScene.mine,
              input: StageInput(hovered: own),
              brightness: brightness,
            ),
          );
          await tester.pump();
          await _advance(tester, 2);
          expect(_same(rim(), colors.success), isTrue);
          await tester.pumpWidget(
            _stage(
              StageScene.mine,
              input: StageInput(hovered: own, picked: own),
              brightness: brightness,
            ),
          );
          var last = gap(rim(), tone);
          for (var ms = 16; ms <= 1760; ms += 16) {
            await tester.pump(const Duration(milliseconds: 16));
            final color = rim();
            final now = gap(color, tone);
            expect(now, lessThanOrEqualTo(last + 1e-9), reason: '$ms ms');
            expect(
              gap(color, colors.success),
              greaterThan(0),
              reason: '$ms ms',
            );
            if (ms >= 200) {
              expect(
                now,
                lessThan(gap(color, colors.success)),
                reason: '$ms ms',
              );
            }
            if (ms >= 464) expect(_same(color, tone), isTrue, reason: '$ms ms');
            last = now;
          }
        });

        testWidgets('mine with reduced motion: picking ${own.name} paints the '
            'knob rim in the tone at once and keeps it', (tester) async {
          final tone = own == Own.mine ? colors.primary : colors.textWeak;
          Color rim() =>
              _single(_circles(_paintNow(tester), 36, stroked: true))
                  .paint
                  .color;

          await tester.pumpWidget(
            _stage(
              StageScene.mine,
              input: StageInput(hovered: own),
              brightness: brightness,
              reduceMotion: true,
            ),
          );
          expect(_same(rim(), colors.success), isTrue);
          await tester.pumpWidget(
            _stage(
              StageScene.mine,
              input: StageInput(hovered: own, picked: own),
              brightness: brightness,
              reduceMotion: true,
            ),
          );
          for (var ms = 0; ms <= 1750; ms += 250) {
            expect(_same(rim(), tone), isTrue, reason: '$ms ms');
            await tester.pump(const Duration(milliseconds: 250));
          }
        });
      }

      testWidgets('reduced motion: no Ticker, a still painter and the changes '
          'straight to their end', (tester) async {
        Future<void> show(StageScene scene, StageInput input) =>
            tester.pumpWidget(
              _stage(
                scene,
                input: input,
                brightness: brightness,
                reduceMotion: true,
              ),
            );

        await show(StageScene.mine, const StageInput());
        expect(_live(tester), 0);
        expect(_painter(tester).still, isTrue);
        await _advance(tester, 2);
        expect(_live(tester), 0);
        await show(StageScene.mine, const StageInput(hovered: Own.mine));
        expect(_live(tester), 0);
        expect(_painter(tester).input.hovered, Own.mine);
        expect(_painter(tester).changes, const StageChanges());
        expect(_knobAt(tester), -26);
        await show(StageScene.mine, const StageInput(picked: Own.mine));
        expect(_live(tester), 0);
        expect(_painter(tester).input.hovered, Own.mine);
        expect(_painter(tester).input.picked, Own.mine);
        expect(_painter(tester).changes, const StageChanges());
        expect(_knobAt(tester), -82);
        await show(
          StageScene.mine,
          const StageInput(hovered: Own.other, picked: Own.mine),
        );
        expect(_painter(tester).input.hovered, Own.mine);
        await show(StageScene.network, const StageInput());
        expect(_live(tester), 0);
        await show(StageScene.network, const StageInput(trusted: true));
        expect(_live(tester), 0);
        expect(_painter(tester).changes, const StageChanges());
        for (final scene in StageScene.values) {
          await show(scene, const StageInput());
          await _advance(tester, 0.5);
          expect(_live(tester), 0, reason: scene.name);
          expect(_painter(tester).still, isTrue);
        }
        expect(tester.takeException(), isNull);
      });

      testWidgets('reduced motion switched on stops the Ticker and switched '
          'off resumes it without going back', (tester) async {
        await tester.pumpWidget(
          _stage(StageScene.network, brightness: brightness),
        );
        await tester.pump();
        await _advance(tester, 1);
        await tester.pumpWidget(
          _stage(
            StageScene.network,
            brightness: brightness,
            reduceMotion: true,
          ),
        );
        expect(_live(tester), 0);
        expect(_painter(tester).still, isTrue);
        await _advance(tester, 5);
        await tester.pumpWidget(
          _stage(StageScene.network, brightness: brightness),
        );
        expect(_live(tester), 1);
        expect(_painter(tester).still, isFalse);
        await tester.pump();
        await _advance(tester, 0.5);
        expect(_ringSeconds(tester, colors), closeTo(1.5, 1e-6));
      });

      testWidgets('every scene paints without exceptions, moving and still', (
        tester,
      ) async {
        for (final reduceMotion in [false, true]) {
          for (final item in _cases()) {
            await tester.pumpWidget(const SizedBox());
            await tester.pumpWidget(
              _stage(
                item.scene,
                input: item.input,
                brightness: brightness,
                reduceMotion: reduceMotion,
              ),
            );
            for (final step in [0.0, 0.35, 0.8, 1.6, 4.0]) {
              await _advance(tester, step);
            }
            expect(tester.takeException(), isNull, reason: item.name);
          }
        }
        await tester.pumpWidget(const SizedBox());
      });
    });
  }

  group('E290 sources', () {
    const files = [
      'lib/src/ui/modal/stage.dart',
      'lib/src/ui/modal/stage_choices.dart',
    ];

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

    for (final path in files) {
      test('$path has no colour literal, Colors. other than transparent, or '
          'comment', () {
        final code = _withoutStrings(File(path).readAsStringSync());
        expect(RegExp(r'\bColor\s*\(').hasMatch(code), isFalse);
        expect(RegExp(r'\bColor\.from').hasMatch(code), isFalse);
        expect(RegExp(r'0x[0-9A-Fa-f]{6,8}').hasMatch(code), isFalse);
        expect(RegExp(r'\bColors\.(?!transparent\b)').hasMatch(code), isFalse);
        expect(code.contains('//'), isFalse);
        expect(code.contains('/*'), isFalse);
      });
    }

    test('the scene switches of stage.dart have no default branch', () {
      final code = _withoutStrings(
        File('lib/src/ui/modal/stage.dart').readAsStringSync(),
      );
      expect(RegExp(r'\bdefault\b').hasMatch(code), isFalse);
      expect(RegExp(r'(^|[\s|,])_\s*=>').hasMatch(code), isFalse);
      for (final scene in StageScene.values) {
        expect(
          RegExp('StageScene\\.${scene.name}\\b').allMatches(code).length,
          greaterThanOrEqualTo(2),
          reason: scene.name,
        );
      }
    });

    test('stage_choices.dart has the four choice functions and no unpair '
        'painter', () {
      final source = File('lib/src/ui/modal/stage_choices.dart')
          .readAsStringSync();
      for (final signature in [
        r'void paintMineSwitch\(Canvas canvas, StageFrame frame\)',
        r'double mineKnobX\(StageFrame frame\)',
        r'void paintNetwork\(Canvas canvas, StageFrame frame\)',
        r'void paintExit\(Canvas canvas, StageFrame frame\)',
      ]) {
        expect(RegExp(signature).hasMatch(source), isTrue, reason: signature);
      }
      expect(source.contains('paintUnpair'), isFalse);
    });
  });
}
