import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nexus_bridges/src/ui/icons/device_disc.dart';
import 'package:nexus_bridges/src/ui/icons/file_icon.dart';
import 'package:nexus_bridges/src/ui/icons/glyphs.dart';
import 'package:nexus_bridges/src/ui/modal/stage_kit.dart';
import 'package:nexus_bridges/src/ui/modal/stage_waiting.dart';
import 'package:nexus_bridges/src/ui/modal/timeline.dart';
import 'package:nexus_bridges/src/ui/theme/tokens.dart';
import 'package:nexus_bridges_core/nexus_bridges_core.dart' show PairingOutcome;

const Offset _center = Offset(150, 85);
const Offset _badge = Offset(179, 114);
const double _tau = 2 * math.pi;
const List<double> _times = [0, 0.5, 1.6, 3, 60, 1e6, 1e9];

const List<(String, NbColors)> _themes = [
  ('light', NbColors.light),
  ('dark', NbColors.dark),
];

final class _Draw {
  _Draw(this.name, this.args, this.matrix, this.alpha);

  final Symbol name;
  final List<dynamic> args;
  final Matrix4 matrix;
  final double alpha;

  Paint get paint => args.last as Paint;

  Offset map(Offset point) => MatrixUtils.transformPoint(matrix, point);

  double get scale => math.sqrt(
    math.pow(matrix.entry(0, 0), 2) + math.pow(matrix.entry(1, 0), 2),
  );

  double get angle => math.atan2(matrix.entry(1, 0), matrix.entry(0, 0));

  double get visibleAlpha => paint.color.a * alpha;
}

final class _Circle {
  _Circle(this.draw)
    : center = draw.map(draw.args[0] as Offset),
      baseRadius = draw.args[1] as double,
      radius = (draw.args[1] as double) * draw.scale;

  final _Draw draw;
  final Offset center;
  final double baseRadius;
  final double radius;

  Paint get paint => draw.paint;
  bool get stroked => paint.style == PaintingStyle.stroke;
  double get alpha => draw.visibleAlpha;
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
  final List<_Draw> draws = [];

  Matrix4 get _top => _matrices.last;

  @override
  void save() {
    super.save();
    _matrices.add(_top.clone());
    _alphas.add(_alphas.last);
  }

  @override
  void saveLayer(Rect? bounds, Paint paint) {
    super.saveLayer(bounds, paint);
    _matrices.add(_top.clone());
    _alphas.add(_alphas.last * _alphaOfLayer(paint));
  }

  @override
  void restore() {
    super.restore();
    _matrices.removeLast();
    _alphas.removeLast();
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

  void _add(Symbol name, List<dynamic> args) =>
      draws.add(_Draw(name, args, _top.clone(), _alphas.last));

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
  void drawArc(
    Rect rect,
    double startAngle,
    double sweepAngle,
    bool useCenter,
    Paint paint,
  ) {
    super.noSuchMethod(
      Invocation.method(#drawArc, [
        rect,
        startAngle,
        sweepAngle,
        useCenter,
        paint,
      ]),
    );
    _add(#drawArc, [
      rect,
      startAngle,
      sweepAngle,
      useCenter,
      Paint.from(paint),
    ]);
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
  void drawOval(Rect rect, Paint paint) {
    super.noSuchMethod(Invocation.method(#drawOval, [rect, paint]));
    _add(#drawOval, [rect, Paint.from(paint)]);
  }

  List<_Circle> get circles => [
    for (final draw in draws)
      if (draw.name == #drawCircle) _Circle(draw),
  ];

  List<_Draw> get paths => [
    for (final draw in draws)
      if (draw.name == #drawPath) draw,
  ];

  List<_Draw> get arcs => [
    for (final draw in draws)
      if (draw.name == #drawArc) draw,
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

bool _near(Offset a, Offset b, [double tolerance = 1e-6]) =>
    (a - b).distance < tolerance;

Matcher _offsetNear(Offset expected, [double tolerance = 1e-6]) => isA<Offset>()
    .having((o) => o.dx, 'dx', closeTo(expected.dx, tolerance))
    .having((o) => o.dy, 'dy', closeTo(expected.dy, tolerance));

void _expectAngle(double actual, double expected, {String? reason}) {
  expect(math.cos(actual), closeTo(math.cos(expected), 1e-6), reason: reason);
  expect(math.sin(actual), closeTo(math.sin(expected), 1e-6), reason: reason);
}

double _dashStartAngle(_Draw ring) {
  final path = ring.args[0] as Path;
  final start = path.computeMetrics().first.getTangentForOffset(0)!.position;
  final mapped = ring.map(start) - _center;
  return math.atan2(mapped.dy, mapped.dx);
}

List<_Draw> _strokedPaths(_StageCanvas canvas, Color color) => [
  for (final path in canvas.paths)
    if (path.paint.style == PaintingStyle.stroke &&
        _same(path.paint.color, color))
      path,
];

_Draw _ringOf(_StageCanvas canvas, Color color, double width) {
  final found = [
    for (final path in _strokedPaths(canvas, color))
      if ((path.paint.strokeWidth - width).abs() < 1e-6 &&
          _ringRadius(path) > 50)
        path,
  ];
  expect(found, hasLength(1));
  return found.single;
}

double _ringRadius(_Draw path) {
  final bounds = (path.args[0] as Path).getBounds();
  final corner = path.map(bounds.topLeft);
  final opposite = path.map(bounds.bottomRight);
  return (opposite - corner).distance / (2 * math.sqrt2);
}

List<double> _dashLengths(Path path) => [
  for (final metric in path.computeMetrics()) metric.length,
];

_Circle _discBody(_StageCanvas canvas, double radius) {
  final found = [
    for (final circle in canvas.circles)
      if (!circle.stroked &&
          _near(circle.center, _center) &&
          (circle.radius - radius).abs() < 1e-6 &&
          circle.paint.shader != null)
        circle,
  ];
  expect(found, hasLength(1));
  return found.single;
}

_Circle _discRim(_StageCanvas canvas, double radius, Color color) {
  final found = [
    for (final circle in canvas.circles)
      if (circle.stroked &&
          _near(circle.center, _center) &&
          (circle.radius - radius).abs() < 1e-6 &&
          _same(circle.paint.color, color))
        circle,
  ];
  expect(found, hasLength(1));
  return found.single;
}

List<_Circle> _tints(_StageCanvas canvas, double radius, Color stroke) => [
  for (final circle in canvas.circles)
    if (!circle.stroked &&
        circle.paint.shader == null &&
        _near(circle.center, _center) &&
        (circle.radius - radius).abs() < 1e-6 &&
        _sameRgb(circle.paint.color, stroke) &&
        circle.paint.color.a < stroke.a)
      circle,
];

List<_Circle> _pings(_StageCanvas canvas, double baseRadius, NbColors colors) =>
    [
      for (final circle in canvas.circles)
        if (circle.stroked &&
            circle.baseRadius == baseRadius &&
            _sameRgb(circle.paint.color, colors.primary) &&
            (circle.paint.strokeWidth - 1.6).abs() < 1e-6 &&
            circle.alpha > 0)
          circle,
    ];

_Circle? _badgeDisc(_StageCanvas canvas, NbColors colors) {
  final found = [
    for (final circle in canvas.circles)
      if (!circle.stroked &&
          _same(circle.paint.color, colors.success) &&
          _near(circle.center, _badge, 1e-6))
        circle,
  ];
  expect(found.length, lessThanOrEqualTo(1));
  return found.isEmpty ? null : found.single;
}

typedef _GlyphStroke = ({Rect bounds, Color color, double width, bool fill});

Rect _mappedBounds(_Draw path) {
  final bounds = (path.args[0] as Path).getBounds();
  final corners = [
    path.map(bounds.topLeft),
    path.map(bounds.topRight),
    path.map(bounds.bottomLeft),
    path.map(bounds.bottomRight),
  ];
  return Rect.fromLTRB(
    corners.map((c) => c.dx).reduce(math.min),
    corners.map((c) => c.dy).reduce(math.min),
    corners.map((c) => c.dx).reduce(math.max),
    corners.map((c) => c.dy).reduce(math.max),
  );
}

List<_GlyphStroke> _glyphStrokes(Iterable<_Draw> paths) => [
  for (final path in paths)
    (
      bounds: _mappedBounds(path),
      color: path.paint.color,
      width: path.paint.strokeWidth,
      fill: path.paint.style == PaintingStyle.fill,
    ),
];

List<_Draw> _glyphPathsNear(_StageCanvas canvas, Offset center) => [
  for (final path in canvas.paths)
    if (_glyphLike(path, center)) path,
];

bool _glyphLike(_Draw path, Offset center) {
  final bounds = _mappedBounds(path);
  return (bounds.center - center).distance < 25 && bounds.width < 45;
}

List<_GlyphStroke> _referenceGlyph(Glyph glyph, double radius, Color ink) {
  final side = 24 * radius / 22;
  final canvas = _record(
    (canvas) => paintGlyph(
      canvas,
      glyph,
      Rect.fromCenter(center: _center, width: side, height: side),
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
    expect(actual[i].bounds.left, closeTo(expected[i].bounds.left, 1e-6));
    expect(actual[i].bounds.top, closeTo(expected[i].bounds.top, 1e-6));
    expect(actual[i].bounds.right, closeTo(expected[i].bounds.right, 1e-6));
    expect(actual[i].bounds.bottom, closeTo(expected[i].bounds.bottom, 1e-6));
  }
}

List<Color> _waitingPalette(NbColors c) => [
  c.primary,
  c.primaryInk,
  c.stageDashedRing,
  c.stageBorder,
  c.stageTrack,
  c.warningRing,
  c.warningWeak,
  c.warning,
  c.success,
  c.onSuccessDisc,
  c.card,
  c.text,
];

void _expectPaletteOnly(_StageCanvas canvas, NbColors colors) {
  final palette = _waitingPalette(colors);
  for (final draw in canvas.draws) {
    final paint = draw.paint;
    if (paint.shader != null) continue;
    expect(
      palette.any((color) => _sameRgb(color, paint.color)),
      isTrue,
      reason: '${draw.name} ${paint.color}',
    );
  }
}

void _expectFinite(_StageCanvas canvas) {
  expect(canvas.getSaveCount(), 0);
  for (final draw in canvas.draws) {
    for (final value in draw.matrix.storage) {
      expect(value.isFinite, isTrue, reason: '${draw.name}');
    }
    expect(draw.alpha.isFinite, isTrue);
    expect(draw.paint.color.a.isFinite, isTrue);
    expect(draw.paint.strokeWidth.isFinite, isTrue);
    for (final arg in draw.args) {
      if (arg is double) expect(arg.isFinite, isTrue, reason: '${draw.name}');
      if (arg is Offset) expect(arg.isFinite, isTrue, reason: '${draw.name}');
      if (arg is Rect) expect(arg.isFinite, isTrue, reason: '${draw.name}');
    }
  }
}

int _indexOf(_StageCanvas canvas, _Draw draw) => canvas.draws.indexOf(draw);

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

int _channel(double value) => (value * 255).round();

String _withoutStrings(String source) => source
    .replaceAll(RegExp(r"'''[\s\S]*?'''"), "''")
    .replaceAll(RegExp(r'"""[\s\S]*?"""'), '""')
    .replaceAll(RegExp(r"'(?:\\.|[^'\\\n])*'"), "''")
    .replaceAll(RegExp(r'"(?:\\.|[^"\\\n])*"'), '""');

const Map<StageScene, (StageSize, bool, double, double)> _specs = {
  StageScene.connecting: (StageSize.normal, true, 0, 0),
  StageScene.comparing: (StageSize.mid, true, 0, 0),
  StageScene.waiting: (StageSize.mid, true, 1.9, 0),
  StageScene.paired: (StageSize.big, true, 3.9, 0),
  StageScene.rejected: (StageSize.big, false, 2.32, 0),
  StageScene.busy: (StageSize.big, true, 0, 0),
  StageScene.paused: (StageSize.big, true, 2.25, 0),
  StageScene.cancelledByPeer: (StageSize.big, false, 1.23, 0),
  StageScene.expired: (StageSize.big, false, 1.55, 0),
  StageScene.lost: (StageSize.big, true, 2.65, 0),
  StageScene.networkChanged: (StageSize.big, false, 1.75, 0),
  StageScene.failed: (StageSize.big, false, 1.3, 0),
  StageScene.notSaved: (StageSize.big, false, 1.17, 0),
  StageScene.mine: (StageSize.big, true, 0.55, 1.65),
  StageScene.unpairLoop: (StageSize.big, true, 0, 0),
  StageScene.unpairBreak: (StageSize.big, false, 1, 0),
  StageScene.network: (StageSize.big, true, 0, 0.55),
  StageScene.exit: (StageSize.wide, true, 0, 0),
};

const List<StageInput> _inputs = [
  StageInput(),
  StageInput(peer: DeviceGlyph.phone),
  StageInput(hovered: Own.mine),
  StageInput(picked: Own.other),
  StageInput(trusted: true),
  StageInput(
    transfer: ExitTransfer(
      peer: DeviceGlyph.phone,
      kind: FileKind.pdf,
      towardsHub: true,
    ),
  ),
];

void main() {
  group('E284 stage sizes and specs', () {
    test('the five sizes match the lab and point 244', () {
      expect(StageSize.values, hasLength(5));
      expect(
        [
          StageSize.normal.width,
          StageSize.normal.height,
          StageSize.normal.margin,
        ],
        [300, 170, 14],
      );
      expect(
        [StageSize.mid.width, StageSize.mid.height, StageSize.mid.margin],
        [247, 140, 10],
      );
      expect(
        [StageSize.big.width, StageSize.big.height, StageSize.big.margin],
        [344, 195, 16],
      );
      expect(
        [StageSize.wide.width, StageSize.wide.height, StageSize.wide.margin],
        [344, 110, 8],
      );
      expect(
        [StageSize.small.width, StageSize.small.height, StageSize.small.margin],
        [144, 60, 8],
      );
      expect(StageSize.wide.viewTop, 37);
      expect(StageSize.small.viewTop, 22.5);
      for (final size in [StageSize.normal, StageSize.mid, StageSize.big]) {
        expect(size.viewTop, 0);
      }
    });

    test('small frames the centre of the viewBox and a ring of about 56 px '
        '(point 244)', () {
      const size = StageSize.small;
      final scale = size.width / 300;
      expect(_center.dx * scale, closeTo(size.width / 2, 1e-9));
      expect(
        (_center.dy - size.viewTop) * scale,
        closeTo(size.height / 2, 1e-9),
      );
      const outer = 56 + 5 / 2;
      final diameter = 2 * outer * scale;
      expect(diameter, inInclusiveRange(52, 60));
      expect(diameter, lessThanOrEqualTo(size.height));
      expect(diameter, lessThan(2 * outer * StageSize.mid.width / 300));
    });

    test('the table covers the 18 scenes', () {
      expect(StageScene.values, hasLength(18));
      expect(_specs.keys.toSet(), StageScene.values.toSet());
    });

    for (final entry in _specs.entries) {
      test('${entry.key.name} has its size, loops, introEnd and changeEnd', () {
        final (size, loops, introEnd, changeEnd) = entry.value;
        final spec = stageSpecOf(entry.key, const StageInput());
        expect(spec.size, size);
        expect(spec.loops, loops);
        expect(spec.introEnd, closeTo(introEnd, 1e-9));
        expect(spec.changeEnd, closeTo(changeEnd, 1e-9));
      });
    }

    test('network with trust stops looping and has an intro of 0.55 s', () {
      final spec = stageSpecOf(
        StageScene.network,
        const StageInput(trusted: true),
      );
      expect(spec.size, StageSize.big);
      expect(spec.loops, isFalse);
      expect(spec.introEnd, closeTo(0.55, 1e-9));
      expect(spec.changeEnd, closeTo(0.55, 1e-9));
    });

    test('only network depends on the input', () {
      for (final scene in StageScene.values) {
        if (scene == StageScene.network) continue;
        final base = stageSpecOf(scene, const StageInput());
        for (final input in _inputs) {
          final spec = stageSpecOf(scene, input);
          expect(spec.size, base.size, reason: scene.name);
          expect(spec.loops, base.loops, reason: scene.name);
          expect(spec.introEnd, base.introEnd, reason: scene.name);
          expect(spec.changeEnd, base.changeEnd, reason: scene.name);
        }
      }
    });

    test('every spec is finite and not negative', () {
      for (final scene in StageScene.values) {
        for (final input in _inputs) {
          final spec = stageSpecOf(scene, input);
          expect(spec.introEnd.isFinite, isTrue);
          expect(spec.introEnd, greaterThanOrEqualTo(0));
          expect(spec.changeEnd.isFinite, isTrue);
          expect(spec.changeEnd, greaterThanOrEqualTo(0));
        }
      }
    });

    test('the waiting intro ends when the sent badge finishes its pop', () {
      final end = stageSpecOf(StageScene.waiting, const StageInput()).introEnd;
      expect(end, closeTo(1.45 + 0.45, 1e-9));
      final pop = popAt(end, delay: 1.45);
      expect(pop.scale, closeTo(1, 1e-9));
      expect(pop.opacity, closeTo(1, 1e-9));
    });
  });

  group('E284 stageForOutcome', () {
    test('each outcome has the scene with its name', () {
      const expected = {
        PairingOutcome.paired: StageScene.paired,
        PairingOutcome.rejected: StageScene.rejected,
        PairingOutcome.busy: StageScene.busy,
        PairingOutcome.paused: StageScene.paused,
        PairingOutcome.cancelledByPeer: StageScene.cancelledByPeer,
        PairingOutcome.expired: StageScene.expired,
        PairingOutcome.lost: StageScene.lost,
        PairingOutcome.networkChanged: StageScene.networkChanged,
        PairingOutcome.failed: StageScene.failed,
        PairingOutcome.notSaved: StageScene.notSaved,
      };
      expect(expected.keys.toSet(), PairingOutcome.values.toSet());
      for (final outcome in PairingOutcome.values) {
        expect(stageForOutcome(outcome), expected[outcome], reason: '$outcome');
      }
    });

    test('null is failed', () {
      expect(stageForOutcome(null), StageScene.failed);
    });

    test('every outcome scene is a big stage', () {
      for (final outcome in [...PairingOutcome.values, null]) {
        expect(
          stageSpecOf(stageForOutcome(outcome), const StageInput()).size,
          StageSize.big,
        );
      }
    });
  });

  group('E284 StageInput, ExitTransfer and StageChanges', () {
    test(
      'StageInput defaults to a pc without hover, pick, trust or transfer',
      () {
        const input = StageInput();
        expect(input.peer, DeviceGlyph.pc);
        expect(input.hovered, isNull);
        expect(input.picked, isNull);
        expect(input.trusted, isFalse);
        expect(input.transfer, isNull);
      },
    );

    test('StageInput compares by value', () {
      expect(const StageInput(), StageInput(peer: DeviceGlyph.values.first));
      expect(
        StageInput(hovered: Own.values.first).hashCode,
        const StageInput(hovered: Own.mine).hashCode,
      );
      for (var i = 0; i < _inputs.length; i++) {
        for (var j = 0; j < _inputs.length; j++) {
          expect(_inputs[i] == _inputs[j], i == j, reason: '$i $j');
        }
      }
      expect(
        const StageInput(hovered: Own.mine) ==
            const StageInput(hovered: Own.other),
        isFalse,
      );
      expect(
        const StageInput(picked: Own.mine) ==
            const StageInput(picked: Own.other),
        isFalse,
      );
    });

    test('ExitTransfer compares by value', () {
      ExitTransfer make({
        DeviceGlyph peer = DeviceGlyph.pc,
        FileKind kind = FileKind.pdf,
        bool towardsHub = false,
      }) => ExitTransfer(peer: peer, kind: kind, towardsHub: towardsHub);
      expect(make(), make());
      expect(make().hashCode, make().hashCode);
      expect(make() == make(peer: DeviceGlyph.phone), isFalse);
      expect(make() == make(kind: FileKind.sheet), isFalse);
      expect(make() == make(towardsHub: true), isFalse);
      expect(
        StageInput(transfer: make()) == StageInput(transfer: make()),
        isTrue,
      );
      expect(
        StageInput(transfer: make()) ==
            StageInput(transfer: make(towardsHub: true)),
        isFalse,
      );
    });

    test('StageChanges compares by value in each of its fields', () {
      const base = StageChanges(
        hoveredAt: 1,
        hoveredFrom: Own.mine,
        pickedAt: 2,
        pickedFrom: Own.other,
        trustedAt: 3,
        trustedFrom: true,
        knobFrom: 120,
      );
      const same = StageChanges(
        hoveredAt: 1,
        hoveredFrom: Own.mine,
        pickedAt: 2,
        pickedFrom: Own.other,
        trustedAt: 3,
        trustedFrom: true,
        knobFrom: 120,
      );
      expect(base, same);
      expect(base.hashCode, same.hashCode);
      expect(const StageChanges(), const StageChanges());
      const variants = [
        StageChanges(
          hoveredAt: 1.5,
          hoveredFrom: Own.mine,
          pickedAt: 2,
          pickedFrom: Own.other,
          trustedAt: 3,
          trustedFrom: true,
          knobFrom: 120,
        ),
        StageChanges(
          hoveredAt: 1,
          hoveredFrom: Own.other,
          pickedAt: 2,
          pickedFrom: Own.other,
          trustedAt: 3,
          trustedFrom: true,
          knobFrom: 120,
        ),
        StageChanges(
          hoveredAt: 1,
          hoveredFrom: Own.mine,
          pickedAt: 2.5,
          pickedFrom: Own.other,
          trustedAt: 3,
          trustedFrom: true,
          knobFrom: 120,
        ),
        StageChanges(
          hoveredAt: 1,
          hoveredFrom: Own.mine,
          pickedAt: 2,
          pickedFrom: Own.mine,
          trustedAt: 3,
          trustedFrom: true,
          knobFrom: 120,
        ),
        StageChanges(
          hoveredAt: 1,
          hoveredFrom: Own.mine,
          pickedAt: 2,
          pickedFrom: Own.other,
          trustedAt: 3.5,
          trustedFrom: true,
          knobFrom: 120,
        ),
        StageChanges(
          hoveredAt: 1,
          hoveredFrom: Own.mine,
          pickedAt: 2,
          pickedFrom: Own.other,
          trustedAt: 3,
          trustedFrom: false,
          knobFrom: 120,
        ),
        StageChanges(
          hoveredAt: 1,
          hoveredFrom: Own.mine,
          pickedAt: 2,
          pickedFrom: Own.other,
          trustedAt: 3,
          trustedFrom: true,
          knobFrom: 121,
        ),
      ];
      for (final variant in variants) {
        expect(variant == base, isFalse);
      }
      expect(const StageChanges() == base, isFalse);
    });

    test('lastAt is the latest change and 0 without changes', () {
      expect(const StageChanges().lastAt, 0);
      expect(const StageChanges(hoveredAt: 1.2).lastAt, closeTo(1.2, 1e-12));
      expect(const StageChanges(pickedAt: 0.7).lastAt, closeTo(0.7, 1e-12));
      expect(const StageChanges(trustedAt: 4).lastAt, closeTo(4, 1e-12));
      expect(
        const StageChanges(hoveredAt: 1.2, pickedAt: 3.4, trustedAt: 2).lastAt,
        closeTo(3.4, 1e-12),
      );
      expect(
        const StageChanges(hoveredAt: 5, pickedAt: 3.4).lastAt,
        closeTo(5, 1e-12),
      );
    });

    test('lastAt does not count the knob position', () {
      expect(const StageChanges(knobFrom: 238).lastAt, 0);
      expect(
        const StageChanges(hoveredAt: 1, knobFrom: 238).lastAt,
        closeTo(1, 1e-12),
      );
    });

    test('a frame defaults to the default input and no changes', () {
      const frame = StageFrame(t: 0, still: false, colors: NbColors.light);
      expect(frame.input, const StageInput());
      expect(frame.changes, const StageChanges());
    });
  });

  group('E284 common helpers', () {
    test('fadeColor multiplies the alpha and clamps the factor', () {
      final ring = NbColors.light.stageDashedRing;
      expect(fadeColor(ring, 0.5).a, closeTo(ring.a * 0.5, 1e-6));
      expect(_sameRgb(fadeColor(ring, 0.5), ring), isTrue);
      expect(fadeColor(ring, 2).a, closeTo(ring.a, 1e-6));
      expect(fadeColor(ring, -1).a, 0);
      expect(fadeColor(NbColors.dark.primary, 0.18).a, closeTo(0.18, 1e-6));
    });

    test('popAt follows the pop keyframes with both fill', () {
      final before = popAt(1, delay: 1.45);
      expect(before.scale, closeTo(0.4, 1e-9));
      expect(before.opacity, 0);
      final peak = popAt(1.45 + 0.45 * 0.6, delay: 1.45);
      expect(peak.scale, closeTo(1.12, 1e-6));
      expect(peak.opacity, closeTo(labEaseOut.transform(0.6), 1e-6));
      final early = popAt(1.45 + 0.45 * 0.3, delay: 1.45);
      expect(
        early.scale,
        closeTo(0.4 + 0.72 * labEaseOut.transform(0.5), 1e-6),
      );
      final end = popAt(1.9, delay: 1.45);
      expect(end.scale, closeTo(1, 1e-9));
      expect(end.opacity, closeTo(1, 1e-9));
      final later = popAt(1e9, delay: 1.45);
      expect(later.scale, 1);
      expect(later.opacity, 1);
    });

    test('popAt takes a custom duration', () {
      final mid = popAt(0.1 + 0.42 * 0.6, delay: 0.1, duration: 0.42);
      expect(mid.scale, closeTo(1.12, 1e-6));
    });

    test('paintGroup turns and scales around the pivot and shifts', () {
      final canvas = _record(
        (canvas) => paintGroup(
          canvas,
          pivot: _center,
          rotation: math.pi / 2,
          paint: () => canvas.drawCircle(_center.translate(10, 0), 1, Paint()),
        ),
      );
      final matrix = canvas.draws.single.matrix;
      expect(canvas.circles.single.center, _offsetNear(const Offset(150, 95)));
      expect(MatrixUtils.transformPoint(matrix, _center), _offsetNear(_center));
      expect(canvas.getSaveCount(), 0);

      final scaled = _record(
        (canvas) => paintGroup(
          canvas,
          pivot: _center,
          scale: 2,
          shift: const Offset(5, -3),
          paint: () => canvas.drawCircle(_center.translate(10, 0), 1, Paint()),
        ),
      );
      expect(scaled.circles.single.center, _offsetNear(const Offset(175, 82)));
      expect(scaled.circles.single.radius, closeTo(2, 1e-9));
    });

    test('paintGroup fades in a layer and draws nothing visible at 0', () {
      final half = _record(
        (canvas) => paintGroup(
          canvas,
          opacity: 0.5,
          paint: () => canvas.drawCircle(_center, 4, Paint()),
        ),
      );
      expect(
        half.invocations.where(
          (call) => call.invocation.memberName == #saveLayer,
        ),
        hasLength(1),
      );
      expect(half.circles.single.alpha, closeTo(0.5, 1e-6));
      expect(half.getSaveCount(), 0);

      final full = _record(
        (canvas) => paintGroup(
          canvas,
          paint: () => canvas.drawCircle(_center, 4, Paint()),
        ),
      );
      expect(
        full.invocations.where(
          (call) => call.invocation.memberName == #saveLayer,
        ),
        isEmpty,
      );
      expect(full.circles.single.alpha, 1);

      final none = _record(
        (canvas) => paintGroup(
          canvas,
          opacity: 0,
          paint: () => canvas.drawCircle(_center, 4, Paint()),
        ),
      );
      expect(none.circles.where((circle) => circle.alpha > 0), isEmpty);
      expect(none.getSaveCount(), 0);
    });

    for (final (theme, colors) in _themes) {
      test(
        'paintDashedRing turns once per period from 3 o\'clock ($theme)',
        () {
          StageFrame at(double t, {bool still = false}) =>
              _frame(colors, t: t, still: still);
          for (final (t, expected) in [
            (0.0, 0.0),
            (2.5, math.pi / 2),
            (5.0, math.pi),
            (12.5, math.pi / 2),
          ]) {
            final canvas = _record(
              (canvas) => paintDashedRing(
                canvas,
                at(t),
                radius: 56,
                color: colors.stageDashedRing,
                width: 1.6,
                pattern: const [2, 8],
                period: 10,
              ),
            );
            final ring = canvas.paths.single;
            _expectAngle(_dashStartAngle(ring), expected, reason: '$t');
            expect(_ringRadius(ring), closeTo(56, 0.5));
            expect(canvas.getSaveCount(), 0);
          }
          final still = _record(
            (canvas) => paintDashedRing(
              canvas,
              at(2.5, still: true),
              radius: 56,
              color: colors.warningRing,
              width: 2.2,
              pattern: const [3, 7],
              round: true,
              period: 10,
            ),
          );
          final ring = still.paths.single;
          _expectAngle(_dashStartAngle(ring), 0);
          expect(ring.paint.strokeCap, StrokeCap.round);
          expect(ring.paint.strokeWidth, closeTo(2.2, 1e-6));
          expect(_same(ring.paint.color, colors.warningRing), isTrue);
          final fixed = _record(
            (canvas) => paintDashedRing(
              canvas,
              at(7),
              radius: 60,
              color: colors.stageHint,
              width: 2.2,
              pattern: const [4, 8],
            ),
          );
          _expectAngle(_dashStartAngle(fixed.paths.single), 0);
          expect(fixed.paths.single.paint.strokeCap, StrokeCap.butt);
        },
      );
    }

    test('paintBurst sends each particle on its angle and fades it', () {
      final color = NbColors.light.success;
      final canvas = _record(
        (canvas) => paintBurst(
          canvas,
          at: _center,
          color: color,
          count: 8,
          spread: 20,
          progress: 0.5,
        ),
      );
      final particles = canvas.circles;
      expect(particles, hasLength(8));
      for (var i = 0; i < 8; i++) {
        final angle = i / 8 * _tau + 0.4;
        final target = Offset(
          math.cos(angle) * 20,
          math.sin(angle) * 20 * 0.7 + 7,
        );
        expect(particles[i].center, _offsetNear(_center + target * 0.5));
        expect(particles[i].radius, closeTo(1.6 + (i % 3) * 0.5, 1e-9));
        expect(particles[i].alpha, closeTo(0.5, 1e-6));
        expect(_sameRgb(particles[i].paint.color, color), isTrue);
      }
    });

    test('paintBurst shows nothing once it has faded out', () {
      for (final progress in [1.0, 1.5, 1e9]) {
        final canvas = _record(
          (canvas) => paintBurst(
            canvas,
            at: _center,
            color: NbColors.dark.success,
            count: 8,
            spread: 20,
            progress: progress,
          ),
        );
        expect(canvas.circles.where((circle) => circle.alpha > 0), isEmpty);
      }
    });

    test('paintBurst never throws with odd inputs', () {
      for (final progress in [double.nan, -1.0, 0.0, 1e-9, 0.999]) {
        for (final count in [0, 1, 8, -3]) {
          final canvas = _record(
            (canvas) => paintBurst(
              canvas,
              at: _center,
              color: NbColors.light.danger,
              count: count,
              spread: 20,
              progress: progress,
            ),
          );
          _expectFinite(canvas);
          if (count <= 0) expect(canvas.circles, isEmpty);
        }
      }
    });
  });

  group('E284 halo (point 227)', () {
    for (final (theme, colors) in _themes) {
      test('is a circle of 140 squashed to 84 around the centre ($theme)', () {
        final canvas = _record(
          (canvas) => paintHalo(canvas, _frame(colors), colors.primary),
        );
        final halo = canvas.circles.single;
        expect(halo.center, _offsetNear(_center));
        expect(halo.baseRadius, 140);
        expect(halo.draw.matrix.entry(0, 0), closeTo(1, 1e-9));
        expect(halo.draw.matrix.entry(1, 1), closeTo(84 / 140, 1e-9));
        expect(halo.draw.matrix.entry(0, 1), closeTo(0, 1e-9));
        expect(halo.draw.matrix.entry(1, 0), closeTo(0, 1e-9));
        expect(halo.paint.shader, isNotNull);
        expect(halo.stroked, isFalse);
        expect(canvas.getSaveCount(), 0);
      });

      testWidgets(
        'fades the tone from 35 % to the edge of the ellipse ($theme)',
        (tester) async {
          final tone = theme == 'light' ? colors.primary : colors.success;
          void paint(Canvas canvas) => paintHalo(canvas, _frame(colors), tone);
          final solid = _channel(colors.haloOpacity);

          final middle = await _pixel(tester, paint, const Offset(150, 85));
          expect((middle.a * 255).round(), closeTo(solid, 3));
          expect((middle.r * 255).round(), closeTo(_channel(tone.r), 12));
          expect((middle.g * 255).round(), closeTo(_channel(tone.g), 12));
          expect((middle.b * 255).round(), closeTo(_channel(tone.b), 12));

          final insideSolid = await _pixel(
            tester,
            paint,
            const Offset(150, 108),
          );
          expect((insideSolid.a * 255).round(), closeTo(solid, 3));

          final halfway = await _pixel(tester, paint, const Offset(150, 141));
          expect((halfway.a * 255).round(), closeTo(solid * 0.5, 3));

          final wideEdge = await _pixel(tester, paint, const Offset(233, 85));
          expect((wideEdge.a * 255).round(), closeTo(solid * 0.626, 3));

          final tallEdge = await _pixel(tester, paint, const Offset(150, 168));
          expect((tallEdge.a * 255).round(), lessThanOrEqualTo(2));

          final outside = await _pixel(tester, paint, const Offset(296, 85));
          expect((outside.a * 255).round(), 0);
        },
      );
    }
  });

  group('E284 discs and badges', () {
    for (final (theme, colors) in _themes) {
      test(
        'the dashed disc is card with a 1.5 stageHint dashed rim ($theme)',
        () {
          final canvas = _record(
            (canvas) => paintDisc(
              canvas,
              _frame(colors),
              center: _center,
              radius: 40,
              dashed: true,
            ),
          );
          final body = canvas.circles.single;
          expect(body.stroked, isFalse);
          expect(body.radius, 40);
          expect(body.paint.shader, isNull);
          expect(_same(body.paint.color, colors.card), isTrue);

          final rim = canvas.paths.single;
          expect(rim.paint.style, PaintingStyle.stroke);
          expect(rim.paint.strokeWidth, closeTo(1.5, 1e-6));
          expect(_same(rim.paint.color, colors.stageHint), isTrue);
          expect(_ringRadius(rim), closeTo(40, 0.5));
          final dashes = _dashLengths(rim.args[0] as Path);
          final circumference = _tau * 40;
          expect(dashes.length, closeTo(circumference / 7, 1.5));
          for (final dash in dashes) {
            expect(dash, lessThanOrEqualTo(3.5 * 1.03));
          }
          expect(
            dashes.fold<double>(0, (sum, d) => sum + d),
            closeTo(circumference / 2, 4),
          );
          expect(_indexOf(canvas, body.draw), lessThan(_indexOf(canvas, rim)));
        },
      );

      test(
        'a plain disc has the node gradient and a stageBorder rim ($theme)',
        () {
          final canvas = _record(
            (canvas) =>
                paintDisc(canvas, _frame(colors), center: _center, radius: 40),
          );
          _discBody(canvas, 40);
          final rim = _discRim(canvas, 40, colors.stageBorder);
          expect(rim.paint.strokeWidth, closeTo(1.6, 1e-6));
          expect(canvas.paths, isEmpty);
          expect(_tints(canvas, 40, colors.stageBorder), isEmpty);
        },
      );

      testWidgets(
        'the node gradient goes from nodeTop to nodeBottom ($theme)',
        (tester) async {
          void paint(Canvas canvas) =>
              paintDisc(canvas, _frame(colors), center: _center, radius: 40);
          final top = await _pixel(tester, paint, const Offset(150, 48));
          final bottom = await _pixel(tester, paint, const Offset(150, 122));
          for (final (pixel, expected) in [
            (top, colors.nodeTop),
            (bottom, colors.nodeBottom),
          ]) {
            expect((pixel.r * 255).round(), closeTo(_channel(expected.r), 4));
            expect((pixel.g * 255).round(), closeTo(_channel(expected.g), 4));
            expect((pixel.b * 255).round(), closeTo(_channel(expected.b), 4));
          }
        },
      );

      test(
        'a coloured rim adds the tonal fill only where discTint > 0 ($theme)',
        () {
          final canvas = _record(
            (canvas) => paintDisc(
              canvas,
              _frame(colors),
              center: _center,
              radius: 40,
              stroke: colors.primary,
            ),
          );
          _discRim(canvas, 40, colors.primary);
          final tints = _tints(canvas, 40, colors.primary);
          if (colors.discTint > 0) {
            expect(tints, hasLength(1));
            expect(
              tints.single.paint.color.a,
              closeTo(colors.primary.a * colors.discTint, 1e-3),
            );
          } else {
            expect(tints, isEmpty);
          }
        },
      );

      test('a filled disc has no gradient and no tonal fill ($theme)', () {
        final canvas = _record(
          (canvas) => paintDisc(
            canvas,
            _frame(colors),
            center: _center,
            radius: 42,
            fill: colors.dangerWeak,
            stroke: colors.danger,
            strokeWidth: 2,
          ),
        );
        final fills = [
          for (final circle in canvas.circles)
            if (!circle.stroked) circle,
        ];
        expect(fills, hasLength(1));
        expect(fills.single.paint.shader, isNull);
        expect(_same(fills.single.paint.color, colors.dangerWeak), isTrue);
        expect(
          _discRim(canvas, 42, colors.danger).paint.strokeWidth,
          closeTo(2, 1e-6),
        );
      });

      test('the glyph is centred at 24 r / 22 with a 1.5 stroke ($theme)', () {
        for (final (glyph, reference) in [
          (DeviceGlyph.pc, Glyphs.pc),
          (DeviceGlyph.phone, Glyphs.phone),
        ]) {
          final canvas = _record(
            (canvas) => paintDisc(
              canvas,
              _frame(colors),
              center: _center,
              radius: 40,
              glyph: glyph,
            ),
          );
          final strokes = _glyphStrokes(canvas.paths);
          _expectSameGlyph(
            strokes,
            _referenceGlyph(reference, 40, colors.text),
          );
          for (final path in canvas.paths) {
            if (path.paint.style == PaintingStyle.stroke) {
              expect(path.paint.strokeWidth, closeTo(1.5, 1e-6));
            }
          }
        }
        final inked = _record(
          (canvas) => paintDisc(
            canvas,
            _frame(colors),
            center: _center,
            radius: 40,
            glyph: DeviceGlyph.phone,
            ink: colors.warning,
            glyphScale: 1,
          ),
        );
        const side = 24.0;
        final reference = _record(
          (canvas) => paintGlyph(
            canvas,
            Glyphs.phone,
            Rect.fromCenter(center: _center, width: side, height: side),
            colors.warning,
            strokeScale: 1.5 / 1.6,
          ),
        );
        _expectSameGlyph(
          _glyphStrokes(inked.paths),
          _glyphStrokes(reference.paths),
        );
      });

      test(
        'the check badge is success with a card ring and a check ($theme)',
        () {
          final canvas = _record(
            (canvas) => paintCheckBadge(
              canvas,
              _frame(colors),
              center: _badge,
              radius: 11,
            ),
          );
          final fill = canvas.circles.firstWhere((c) => !c.stroked);
          expect(fill.center, _offsetNear(_badge));
          expect(fill.radius, 11);
          expect(_same(fill.paint.color, colors.success), isTrue);
          final ring = canvas.circles.firstWhere((c) => c.stroked);
          expect(ring.radius, 11);
          expect(ring.paint.strokeWidth, closeTo(3.5, 1e-6));
          expect(_same(ring.paint.color, colors.card), isTrue);
          final check = canvas.paths.single;
          expect(_same(check.paint.color, colors.onSuccessDisc), isTrue);
          expect(check.paint.strokeWidth, closeTo(2.4, 1e-6));
          expect(check.paint.strokeCap, StrokeCap.round);
          expect(check.paint.strokeJoin, StrokeJoin.round);
          final bounds = (check.args[0] as Path).getBounds();
          expect(bounds.left, closeTo(179 - 11 * 0.42, 1e-3));
          expect(bounds.right, closeTo(179 + 11 * 0.44, 1e-3));
          expect(bounds.top, closeTo(114 - 11 * 0.28, 1e-3));
          expect(bounds.bottom, closeTo(114 + 11 * 0.32, 1e-3));
        },
      );

      test(
        'the cross badge is dangerFill with a card ring and an X ($theme)',
        () {
          final canvas = _record(
            (canvas) => paintCrossBadge(
              canvas,
              _frame(colors),
              center: _badge,
              radius: 11,
            ),
          );
          final fill = canvas.circles.firstWhere((c) => !c.stroked);
          expect(_same(fill.paint.color, colors.dangerFill), isTrue);
          final ring = canvas.circles.firstWhere((c) => c.stroked);
          expect(ring.paint.strokeWidth, closeTo(3.5, 1e-6));
          expect(_same(ring.paint.color, colors.card), isTrue);
          final cross = canvas.paths.single;
          expect(_same(cross.paint.color, colors.onPrimary), isTrue);
          expect(cross.paint.strokeWidth, closeTo(2.2, 1e-6));
          expect(cross.paint.strokeCap, StrokeCap.round);
          final bounds = (cross.args[0] as Path).getBounds();
          expect(bounds.left, closeTo(179 - 11 * 0.32, 1e-3));
          expect(bounds.right, closeTo(179 + 11 * 0.32, 1e-3));
          expect(bounds.top, closeTo(114 - 11 * 0.32, 1e-3));
          expect(bounds.bottom, closeTo(114 + 11 * 0.32, 1e-3));
        },
      );
    }

    test('the badge strokes round to one decimal like the lab', () {
      final check = _record(
        (canvas) => paintCheckBadge(
          canvas,
          _frame(NbColors.light),
          center: _badge,
          radius: 10,
        ),
      );
      expect(check.paths.single.paint.strokeWidth, closeTo(2.2, 1e-6));
      final cross = _record(
        (canvas) => paintCrossBadge(
          canvas,
          _frame(NbColors.light),
          center: _badge,
          radius: 13,
        ),
      );
      expect(cross.paths.single.paint.strokeWidth, closeTo(2.6, 1e-6));
    });
  });

  for (final (theme, colors) in _themes) {
    group('E284 paintConnecting ($theme)', () {
      _Draw ring(_StageCanvas canvas) =>
          _ringOf(canvas, colors.stageDashedRing, 1.6);

      _Circle dot(_StageCanvas canvas) => canvas.circles.singleWhere(
        (c) =>
            !c.stroked &&
            c.baseRadius == 6 &&
            _same(c.paint.color, colors.primary),
      );

      _Circle dotHalo(_StageCanvas canvas) => canvas.circles.singleWhere(
        (c) =>
            !c.stroked &&
            c.baseRadius == 11 &&
            _sameRgb(c.paint.color, colors.primary),
      );

      test('the dashed ring is stageDashedRing, 2 8 and turns in 10 s', () {
        for (final t in [0.0, 2.5, 7.5, 13.75]) {
          final canvas = _paint(paintConnecting, _frame(colors, t: t));
          final found = ring(canvas);
          _expectAngle(_dashStartAngle(found), _tau * (t % 10) / 10);
          expect(_ringRadius(found), closeTo(56, 0.5));
          final dashes = _dashLengths(found.args[0] as Path);
          expect(dashes.length, closeTo(351.86 / 10, 1.5));
          for (final dash in dashes) {
            expect(dash, lessThanOrEqualTo(2 * 1.03));
          }
        }
      });

      test('the ping grows from 1 to 1.55 and fades from 0.45 in 1.8 s', () {
        for (final t in [0.0, 0.45, 0.9, 2.7, 3.15]) {
          final canvas = _paint(paintConnecting, _frame(colors, t: t));
          final eased = labEaseOut.transform((t % 1.8) / 1.8);
          final pings = _pings(canvas, 40, colors);
          expect(pings, hasLength(1), reason: '$t');
          final ping = pings.single;
          expect(ping.center, _offsetNear(_center));
          expect(ping.radius, closeTo(40 * (1 + 0.55 * eased), 1e-6));
          expect(ping.alpha, closeTo(0.45 * (1 - eased), 1e-3));
        }
      });

      test('the orbit dot turns once every 1.8 s with labOrbit', () {
        for (final t in [0.0, 0.3, 0.9, 1.5, 2.7]) {
          final canvas = _paint(paintConnecting, _frame(colors, t: t));
          final angle = _tau * labOrbit.transform((t % 1.8) / 1.8);
          final expected = Offset(
            150 + 56 * math.sin(angle),
            85 - 56 * math.cos(angle),
          );
          expect(dot(canvas).center, _offsetNear(expected, 1e-6));
          expect(dot(canvas).radius, closeTo(6, 1e-9));
          expect(dotHalo(canvas).center, _offsetNear(expected, 1e-6));
          expect(dotHalo(canvas).paint.color.a, closeTo(0.18, 1e-3));
        }
        final half = _paint(paintConnecting, _frame(colors, t: 0.9));
        expect(dot(half).center, _offsetNear(const Offset(150, 141), 1e-3));
      });

      test('the disc has radius 40, the node gradient and the peer glyph', () {
        for (final peer in DeviceGlyph.values) {
          final canvas = _paint(
            paintConnecting,
            _frame(colors, t: 0.7, peer: peer),
          );
          final body = _discBody(canvas, 40);
          final rim = _discRim(canvas, 40, colors.stageBorder);
          expect(rim.paint.strokeWidth, closeTo(1.6, 1e-6));
          expect(_tints(canvas, 40, colors.stageBorder), isEmpty);
          _expectSameGlyph(
            _glyphStrokes(_glyphPathsNear(canvas, _center)),
            _referenceGlyph(
              peer == DeviceGlyph.phone ? Glyphs.phone : Glyphs.pc,
              40,
              colors.text,
            ),
          );
          final order = [
            _indexOf(canvas, ring(canvas)),
            _indexOf(canvas, _pings(canvas, 40, colors).single.draw),
            _indexOf(canvas, dot(canvas).draw),
            _indexOf(canvas, body.draw),
          ];
          expect(order, [...order]..sort());
        }
      });

      test('still: ring and dot at rest and no ping, at any time', () {
        for (final t in [0.0, 0.9, 4.2, 1e6]) {
          final canvas = _paint(
            paintConnecting,
            _frame(colors, t: t, still: true),
          );
          _expectAngle(_dashStartAngle(ring(canvas)), 0);
          expect(_pings(canvas, 40, colors), isEmpty);
          expect(dot(canvas).center, _offsetNear(const Offset(150, 29)));
          _discBody(canvas, 40);
        }
      });

      test('uses only colours of NbColors', () {
        for (final still in [false, true]) {
          _expectPaletteOnly(
            _paint(paintConnecting, _frame(colors, t: 1.1, still: still)),
            colors,
          );
        }
      });

      test('never throws and stays finite from t 0 to very large', () {
        for (final t in _times) {
          for (final still in [false, true]) {
            _expectFinite(
              _paint(paintConnecting, _frame(colors, t: t, still: still)),
            );
          }
        }
      });
    });

    group('E284 paintComparing ($theme)', () {
      _Draw ring(_StageCanvas canvas) =>
          _ringOf(canvas, colors.warningRing, 2.2);

      test('the warning ring is 3 7 with round caps and turns in 10 s', () {
        for (final t in [0.0, 2.5, 5.0, 17.5]) {
          final canvas = _paint(paintComparing, _frame(colors, t: t));
          final found = ring(canvas);
          expect(found.paint.strokeCap, StrokeCap.round);
          _expectAngle(_dashStartAngle(found), _tau * (t % 10) / 10);
          expect(_ringRadius(found), closeTo(56, 0.5));
          final dashes = _dashLengths(found.args[0] as Path);
          expect(dashes.length, closeTo(351.86 / 10, 1.5));
          for (final dash in dashes) {
            expect(dash, lessThanOrEqualTo(3 * 1.03));
          }
        }
      });

      test('a warningWeak circle of 48 sits under the disc', () {
        final canvas = _paint(paintComparing, _frame(colors, t: 1));
        final weak = canvas.circles.singleWhere(
          (c) => !c.stroked && c.baseRadius == 48,
        );
        expect(weak.center, _offsetNear(_center));
        expect(_same(weak.paint.color, colors.warningWeak), isTrue);
        final body = _discBody(canvas, 40);
        expect(
          _indexOf(canvas, ring(canvas)),
          lessThan(_indexOf(canvas, weak.draw)),
        );
        expect(
          _indexOf(canvas, weak.draw),
          lessThan(_indexOf(canvas, body.draw)),
        );
      });

      test(
        'the disc has a 2.2 warningRing rim, its tint and a warning glyph',
        () {
          for (final peer in DeviceGlyph.values) {
            final canvas = _paint(
              paintComparing,
              _frame(colors, t: 1, peer: peer),
            );
            _discBody(canvas, 40);
            final rim = _discRim(canvas, 40, colors.warningRing);
            expect(rim.paint.strokeWidth, closeTo(2.2, 1e-6));
            expect(
              _tints(canvas, 40, colors.warningRing),
              hasLength(colors.discTint > 0 ? 1 : 0),
            );
            _expectSameGlyph(
              _glyphStrokes(_glyphPathsNear(canvas, _center)),
              _referenceGlyph(
                peer == DeviceGlyph.phone ? Glyphs.phone : Glyphs.pc,
                40,
                colors.warning,
              ),
            );
          }
        },
      );

      test('still: the ring is at rest at any time', () {
        for (final t in [0.0, 2.5, 1e6]) {
          final canvas = _paint(
            paintComparing,
            _frame(colors, t: t, still: true),
          );
          _expectAngle(_dashStartAngle(ring(canvas)), 0);
        }
      });

      test('uses only colours of NbColors', () {
        for (final still in [false, true]) {
          _expectPaletteOnly(
            _paint(paintComparing, _frame(colors, t: 3, still: still)),
            colors,
          );
        }
      });

      test('never throws and stays finite from t 0 to very large', () {
        for (final t in _times) {
          for (final still in [false, true]) {
            _expectFinite(
              _paint(paintComparing, _frame(colors, t: t, still: still)),
            );
          }
        }
      });
    });

    group('E284 paintWaiting ($theme)', () {
      _Circle track(_StageCanvas canvas) => canvas.circles.singleWhere(
        (c) =>
            c.stroked &&
            c.baseRadius == 56 &&
            _same(c.paint.color, colors.stageTrack),
      );

      _Draw arc(_StageCanvas canvas) => canvas.arcs.single;

      double arcStart(_Draw arc) => (arc.args[1] as double) + arc.angle;

      test('the track is a stageTrack ring of 56 and width 5', () {
        final canvas = _paint(paintWaiting, _frame(colors, t: 0.4));
        final found = track(canvas);
        expect(found.center, _offsetNear(_center));
        expect(found.radius, closeTo(56, 1e-9));
        expect(found.paint.strokeWidth, closeTo(5, 1e-6));
      });

      test('the primary arc is 86 of 352 and turns linearly in 1.8 s', () {
        for (final t in [0.0, 0.45, 0.9, 1.35, 2.25, 10.0]) {
          final canvas = _paint(paintWaiting, _frame(colors, t: t));
          final found = arc(canvas);
          final rect = found.args[0] as Rect;
          expect(found.map(rect.center), _offsetNear(_center));
          expect(rect.width * found.scale, closeTo(112, 1e-6));
          expect(found.args[2] as double, closeTo(86 / 56, 1e-9));
          expect(found.args[3], isFalse);
          expect(found.paint.style, PaintingStyle.stroke);
          expect(found.paint.strokeWidth, closeTo(5, 1e-6));
          expect(found.paint.strokeCap, StrokeCap.round);
          expect(_same(found.paint.color, colors.primary), isTrue);
          _expectAngle(arcStart(found), _tau * (t % 1.8) / 1.8, reason: '$t');
        }
      });

      test('ping2 waits 1.6 s, then grows to 1.5 and fades out by 70 %', () {
        for (final t in [0.0, 0.5, 1.0, 1.59]) {
          final canvas = _paint(paintWaiting, _frame(colors, t: t));
          expect(_pings(canvas, 42, colors), isEmpty, reason: '$t');
        }
        for (final local in [0.02, 0.1, 0.35, 0.6]) {
          for (final cycle in [0, 2]) {
            final t = 1.6 + 2.6 * (cycle + local);
            final canvas = _paint(paintWaiting, _frame(colors, t: t));
            final eased = labEaseOut.transform(local / 0.7);
            final pings = _pings(canvas, 42, colors);
            expect(pings, hasLength(1), reason: '$t');
            expect(pings.single.center, _offsetNear(_center));
            expect(
              pings.single.radius,
              closeTo(42 * (1 + 0.5 * eased), 1e-3),
              reason: '$t',
            );
            expect(
              pings.single.alpha,
              closeTo(0.45 * (1 - eased), 2e-3),
              reason: '$t',
            );
          }
        }
        for (final local in [0.7, 0.8, 0.99]) {
          final t = 1.6 + 2.6 * (1 + local);
          final canvas = _paint(paintWaiting, _frame(colors, t: t));
          expect(_pings(canvas, 42, colors), isEmpty, reason: '$t');
        }
      });

      test('the disc has a primary rim, its tint and a primaryInk glyph', () {
        for (final peer in DeviceGlyph.values) {
          final canvas = _paint(
            paintWaiting,
            _frame(colors, t: 0.8, peer: peer),
          );
          _discBody(canvas, 40);
          final rim = _discRim(canvas, 40, colors.primary);
          expect(rim.paint.strokeWidth, closeTo(1.6, 1e-6));
          expect(
            _tints(canvas, 40, colors.primary),
            hasLength(colors.discTint > 0 ? 1 : 0),
          );
          _expectSameGlyph(
            _glyphStrokes(_glyphPathsNear(canvas, _center)),
            _referenceGlyph(
              peer == DeviceGlyph.phone ? Glyphs.phone : Glyphs.pc,
              40,
              colors.primaryInk,
            ),
          );
        }
      });

      test('the sent badge at (179, 114) pops in at 1.45 s', () {
        for (final t in [0.0, 1.0, 1.44]) {
          final canvas = _paint(paintWaiting, _frame(colors, t: t));
          final badge = _badgeDisc(canvas, colors);
          expect(badge == null || badge.alpha == 0, isTrue, reason: '$t');
        }
        final peak = _badgeDisc(
          _paint(paintWaiting, _frame(colors, t: 1.45 + 0.45 * 0.6)),
          colors,
        )!;
        expect(peak.radius, closeTo(11 * 1.12, 1e-3));
        expect(peak.alpha, closeTo(labEaseOut.transform(0.6), 2e-3));
        for (final t in [1.9, 2.5, 60.0]) {
          final badge = _badgeDisc(
            _paint(paintWaiting, _frame(colors, t: t)),
            colors,
          )!;
          expect(badge.radius, closeTo(11, 1e-6));
          expect(badge.alpha, closeTo(1, 1e-6));
        }
      });

      test('the layers follow the lab order', () {
        final canvas = _paint(paintWaiting, _frame(colors, t: 2.5));
        final order = [
          _indexOf(canvas, _pings(canvas, 42, colors).single.draw),
          _indexOf(canvas, track(canvas).draw),
          _indexOf(canvas, arc(canvas)),
          _indexOf(canvas, _discBody(canvas, 40).draw),
          _indexOf(canvas, _badgeDisc(canvas, colors)!.draw),
        ];
        expect(order, [...order]..sort());
      });

      test('still: no ping2, arc at rest and the badge whole, even at t 0', () {
        for (final t in [0.0, 0.5, 1.6, 2.9, 1e6]) {
          final canvas = _paint(
            paintWaiting,
            _frame(colors, t: t, still: true),
          );
          expect(_pings(canvas, 42, colors), isEmpty);
          _expectAngle(arcStart(arc(canvas)), 0);
          final badge = _badgeDisc(canvas, colors)!;
          expect(badge.radius, closeTo(11, 1e-6));
          expect(badge.alpha, closeTo(1, 1e-6));
        }
      });

      test('at introEnd the badge looks as it does still', () {
        final end = stageSpecOf(
          StageScene.waiting,
          const StageInput(),
        ).introEnd;
        final moving = _badgeDisc(
          _paint(paintWaiting, _frame(colors, t: end)),
          colors,
        )!;
        final still = _badgeDisc(
          _paint(paintWaiting, _frame(colors, t: end, still: true)),
          colors,
        )!;
        expect(moving.radius, closeTo(still.radius, 1e-6));
        expect(moving.alpha, closeTo(still.alpha, 1e-6));
        expect(moving.center, _offsetNear(still.center));
      });

      test('uses only colours of NbColors', () {
        for (final still in [false, true]) {
          _expectPaletteOnly(
            _paint(paintWaiting, _frame(colors, t: 2.4, still: still)),
            colors,
          );
        }
      });

      test('never throws and stays finite from t 0 to very large', () {
        for (final t in _times) {
          for (final still in [false, true]) {
            _expectFinite(
              _paint(paintWaiting, _frame(colors, t: t, still: still)),
            );
          }
        }
      });
    });
  }

  group('E284 sources', () {
    const files = [
      'lib/src/ui/modal/timeline.dart',
      'lib/src/ui/modal/stage_kit.dart',
      'lib/src/ui/modal/stage_waiting.dart',
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
    }

    test('timeline.dart does not import widgets', () {
      final source = File(files.first).readAsStringSync();
      expect(source.contains('package:flutter/widgets.dart'), isFalse);
      expect(source.contains('package:flutter/material.dart'), isFalse);
    });
  });
}
