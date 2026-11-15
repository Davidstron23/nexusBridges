import 'dart:math' as math;
import 'dart:ui' show PathMetric;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nexus_bridges/src/l10n/app_strings.dart';
import 'package:nexus_bridges/src/ui/diagram/flow_layout.dart';
import 'package:nexus_bridges/src/ui/diagram/flow_painter.dart';
import 'package:nexus_bridges/src/ui/diagram/flow_scene.dart';
import 'package:nexus_bridges/src/ui/icons/file_icon.dart';
import 'package:nexus_bridges/src/ui/theme/tokens.dart';
import 'package:nexus_bridges_core/nexus_bridges_core.dart';

const double _tolerance = 0.01;
const double _clockSeconds = 14.4;
const Size _wide = Size(788, 588);
const Size _small = Size(572, 468);
const Timeout _short = Timeout(Duration(seconds: 20));

List<PathMetric> _metrics(Path path) => path.computeMetrics().toList();

double _breath(double seconds) {
  final t = (seconds % 2.4) / 2.4;
  final rise = t < 0.5 ? t * 2 : (1 - t) * 2;
  return 0.3 + (0.85 - 0.3) * const Cubic(0.45, 0, 0.55, 1).transform(rise);
}

double _lengthOf(Path path) =>
    _metrics(path).fold<double>(0, (sum, metric) => sum + metric.length);

List<(double, double)> _dashesAlongX(Path path) => [
  for (final metric in _metrics(path))
    (
      metric.getTangentForOffset(0)!.position.dx,
      metric.getTangentForOffset(metric.length)!.position.dx,
    ),
];

void _expectDashes(Path path, List<(double, double)> expected) {
  final actual = _dashesAlongX(path);
  expect(actual, hasLength(expected.length), reason: '$actual');
  for (var i = 0; i < expected.length; i++) {
    expect(actual[i].$1, closeTo(expected[i].$1, _tolerance), reason: '$i');
    expect(actual[i].$2, closeTo(expected[i].$2, _tolerance), reason: '$i');
  }
}

Path _line(double length) => Path()
  ..moveTo(0, 0)
  ..lineTo(length, 0);

DeviceEntry _entry(
  String fingerprint, {
  bool visible = true,
  bool mine = true,
  DeviceType? type = DeviceType.desktop,
}) => DeviceEntry(
  fingerprint: fingerprint,
  displayName: 'Device $fingerprint',
  deviceType: type,
  visible: visible,
  paired: true,
  mine: mine,
  ignored: false,
  mismatch: false,
  possiblyReplaces: null,
);

OutgoingTransferView _out(
  String fingerprint,
  OutgoingPhase phase, {
  int size = 1000,
  int sent = 0,
  String fileName = 'report.pdf',
  bool isProgram = false,
}) => OutgoingTransferView(
  peerFingerprint: fingerprint,
  peerName: 'Peer',
  fileName: fileName,
  size: size,
  isProgram: isProgram,
  phase: phase,
  sentBytes: sent,
  cancelling: false,
);

IncomingTransferView _in(
  String fingerprint,
  IncomingStage stage, {
  int size = 1000,
  int received = 0,
  String fileName = 'photo.jpg',
}) => IncomingTransferView(
  sessionId: 's1',
  peerFingerprint: fingerprint,
  peerName: 'Peer',
  fileName: fileName,
  size: size,
  isProgram: false,
  stage: stage,
  receivedBytes: received,
);

NodeState _state({
  List<DeviceEntry>? entries,
  OutgoingTransferView? outgoing,
  IncomingTransferView? incoming,
  String deviceName = 'Main PC',
  String fingerprint = 'ABCDEF0123456789',
}) => NodeState(
  entries: entries ?? [_entry('A')],
  outgoing: outgoing,
  incoming: incoming,
  deviceName: deviceName,
  fingerprint: fingerprint,
);

FlowScene _scene(
  NodeState state, {
  String? done,
  String? hovered,
  Size size = _wide,
}) => buildFlowScene(
  state: state,
  strings: stringsFor('en'),
  size: size,
  doneFingerprint: done,
  hovered: hovered,
);

FlowPainter _painter(
  FlowScene scene, {
  double seconds = 0,
  double hover = 0,
  bool reduceMotion = false,
  NbColors colors = NbColors.light,
}) => FlowPainter(
  scene: scene,
  colors: colors,
  clock: AlwaysStoppedAnimation<double>(seconds / _clockSeconds),
  hover: AlwaysStoppedAnimation<double>(hover),
  reduceMotion: reduceMotion,
  textDirection: TextDirection.ltr,
);

final class _Call {
  const _Call(this.index, this.name, this.args);

  final int index;
  final Symbol name;
  final List<dynamic> args;
}

List<_Call> _record(CustomPainter painter, Size size) {
  final canvas = TestRecordingCanvas();
  painter.paint(canvas, size);
  return [
    for (var i = 0; i < canvas.invocations.length; i++)
      _Call(
        i,
        canvas.invocations[i].invocation.memberName,
        canvas.invocations[i].invocation.positionalArguments,
      ),
  ];
}

final class _Circle {
  const _Circle(this.index, this.center, this.radius, this.paint);

  final int index;
  final Offset center;
  final double radius;
  final Paint paint;
}

final class _Stroke {
  const _Stroke(this.index, this.path, this.paint);

  final int index;
  final Path path;
  final Paint paint;
}

List<_Circle> _circles(List<_Call> calls) => [
  for (final call in calls)
    if (call.name == #drawCircle)
      _Circle(
        call.index,
        call.args[0] as Offset,
        call.args[1] as double,
        call.args[2] as Paint,
      ),
];

List<_Stroke> _paths(List<_Call> calls) => [
  for (final call in calls)
    if (call.name == #drawPath)
      _Stroke(call.index, call.args[0] as Path, call.args[1] as Paint),
];

bool _near(Offset a, Offset b, [double tolerance = 0.05]) =>
    (a - b).distance <= tolerance;

bool _sameColor(Color a, Color b, [double tolerance = 0.004]) =>
    (a.r - b.r).abs() <= tolerance &&
    (a.g - b.g).abs() <= tolerance &&
    (a.b - b.b).abs() <= tolerance &&
    (a.a - b.a).abs() <= tolerance;

List<_Circle> _discFills(List<_Call> calls, Offset center, double radius) => [
  for (final circle in _circles(calls))
    if (_near(circle.center, center) &&
        (circle.radius - radius).abs() < _tolerance &&
        circle.paint.style == PaintingStyle.fill &&
        circle.paint.shader != null)
      circle,
];

List<_Circle> _rings(
  List<_Call> calls,
  Offset center,
  double radius,
  double width,
  Color color,
) => [
  for (final circle in _circles(calls))
    if (_near(circle.center, center) &&
        (circle.radius - radius).abs() < _tolerance &&
        circle.paint.style == PaintingStyle.stroke &&
        (circle.paint.strokeWidth - width).abs() < _tolerance &&
        _sameColor(circle.paint.color, color))
      circle,
];

List<_Circle> _fills(
  List<_Call> calls,
  Offset center,
  double radius,
  Color color,
) => [
  for (final circle in _circles(calls))
    if (_near(circle.center, center) &&
        (circle.radius - radius).abs() < _tolerance &&
        circle.paint.style == PaintingStyle.fill &&
        circle.paint.shader == null &&
        _sameColor(circle.paint.color, color))
      circle,
];

List<_Circle> _pulses(List<_Call> calls, Offset center, double pr) => [
  for (final circle in _circles(calls))
    if (_near(circle.center, center) &&
        circle.paint.style == PaintingStyle.stroke &&
        circle.paint.color.a < 0.999 &&
        circle.radius >= pr - _tolerance &&
        circle.radius <= pr + 12 + _tolerance)
      circle,
];

List<_Stroke> _lines(List<_Call> calls, double width, {Color? color}) => [
  for (final stroke in _paths(calls))
    if (stroke.paint.style == PaintingStyle.stroke &&
        (stroke.paint.strokeWidth - width).abs() < _tolerance &&
        (color == null
            ? stroke.paint.shader != null
            : stroke.paint.shader == null &&
                  _sameColor(stroke.paint.color, color)))
      stroke,
];

List<_Circle> _dots(List<_Call> calls, NbColors colors) => [
  for (final circle in _circles(calls))
    if ((circle.radius - 4.5).abs() < _tolerance &&
        circle.paint.style == PaintingStyle.fill &&
        _sameColor(circle.paint.color, colors.primary))
      circle,
];

Offset _end(Path path) {
  final metrics = _metrics(path);
  final last = metrics.last;
  return last.getTangentForOffset(last.length)!.position;
}

Offset _start(Path path) =>
    _metrics(path).first.getTangentForOffset(0)!.position;

int _paragraphs(List<_Call> calls) =>
    calls.where((call) => call.name == #drawParagraph).length;

bool _hasScaleAround(List<_Call> calls, Offset center, double factor) {
  for (var i = 0; i + 2 < calls.length; i++) {
    final a = calls[i];
    final b = calls[i + 1];
    final c = calls[i + 2];
    if (a.name != #translate || b.name != #scale || c.name != #translate) {
      continue;
    }
    final moved = Offset(a.args[0] as double, a.args[1] as double);
    final back = Offset(c.args[0] as double, c.args[1] as double);
    if (_near(moved, center) &&
        _near(back, -center) &&
        ((b.args[0] as double) - factor).abs() < 0.001) {
      return true;
    }
  }
  return false;
}

List<_Call> _fileIconAt(Offset center, FileKind kind) {
  final canvas = TestRecordingCanvas();
  paintFileIcon(
    canvas,
    Rect.fromCenter(center: center, width: 20, height: 24),
    kind,
  );
  return [
    for (var i = 0; i < canvas.invocations.length; i++)
      _Call(
        i,
        canvas.invocations[i].invocation.memberName,
        canvas.invocations[i].invocation.positionalArguments,
      ),
  ];
}

bool _paintsFileIcon(List<_Call> calls, Offset center, FileKind kind) {
  final expected = _fileIconAt(center, kind);
  final move = expected.firstWhere((call) => call.name == #translate);
  final scale = expected.firstWhere((call) => call.name == #scale);
  final sheet = _paths(expected).first.paint.color;
  for (var i = 0; i + 2 < calls.length; i++) {
    final a = calls[i];
    final b = calls[i + 1];
    final c = calls[i + 2];
    if (a.name != #translate || b.name != #scale || c.name != #drawPath) {
      continue;
    }
    if (((a.args[0] as double) - (move.args[0] as double)).abs() < 0.05 &&
        ((a.args[1] as double) - (move.args[1] as double)).abs() < 0.05 &&
        ((b.args[0] as double) - (scale.args[0] as double)).abs() < 0.001 &&
        _sameColor((c.args[1] as Paint).color, sheet)) {
      return true;
    }
  }
  return false;
}

void main() {
  group('dashPath', () {
    test('3 3 cuts a line into dashes and gaps of 3', () {
      _expectDashes(dashPath(_line(30), const [3, 3]), const [
        (0, 3),
        (6, 9),
        (12, 15),
        (18, 21),
        (24, 27),
      ]);
    });

    test('the last dash is cut at the end of the path', () {
      _expectDashes(dashPath(_line(10), const [4, 2]), const [(0, 4), (6, 10)]);
      _expectDashes(dashPath(_line(8), const [3, 3]), const [(0, 3), (6, 8)]);
    });

    test('the phase moves the pattern along the path', () {
      _expectDashes(dashPath(_line(15), const [3, 3], phase: 3), const [
        (3, 6),
        (9, 12),
      ]);
      _expectDashes(dashPath(_line(12), const [3, 3], phase: 1), const [
        (0, 2),
        (5, 8),
        (11, 12),
      ]);
      _expectDashes(dashPath(_line(12), const [3, 3], phase: 7), const [
        (0, 2),
        (5, 8),
        (11, 12),
      ]);
    });

    test('a negative phase moves the pattern the other way', () {
      _expectDashes(dashPath(_line(12), const [3, 3], phase: -1), const [
        (1, 4),
        (7, 10),
      ]);
    });

    test('an odd pattern repeats itself, as in SVG', () {
      _expectDashes(dashPath(_line(20), const [4]), const [
        (0, 4),
        (8, 12),
        (16, 20),
      ]);
      _expectDashes(dashPath(_line(12), const [2, 1, 3]), const [
        (0, 2),
        (3, 6),
        (8, 9),
      ]);
    });

    test('each subpath starts the pattern again', () {
      final source = Path()
        ..moveTo(0, 0)
        ..lineTo(8, 0)
        ..moveTo(0, 10)
        ..lineTo(8, 10);
      final dashed = dashPath(source, const [3, 3]);
      final metrics = _metrics(dashed);
      expect(metrics, hasLength(4));
      expect(metrics[0].length, closeTo(3, _tolerance));
      expect(metrics[1].length, closeTo(2, _tolerance));
      expect(metrics[2].getTangentForOffset(0)!.position, const Offset(0, 10));
      expect(metrics[2].length, closeTo(3, _tolerance));
    });

    test('a large circle dashed 30 30 keeps half of its length', () {
      final circle = Path()
        ..addOval(Rect.fromCircle(center: Offset.zero, radius: 400));
      final dashed = dashPath(circle, const [30, 30]);
      final circumference = 2 * math.pi * 400;
      expect(_lengthOf(dashed), closeTo(circumference / 2, 30));
      expect(_metrics(dashed), hasLength((circumference / 60).ceil()));
      for (final metric in _metrics(dashed)) {
        expect(metric.length, lessThanOrEqualTo(30.1));
      }
    });

    test('the disc outline dashed 3 3 stays on the circle', () {
      final circle = Path()
        ..addOval(Rect.fromCircle(center: const Offset(19, 19), radius: 18.4));
      final dashed = dashPath(circle, const [3, 3]);
      expect(_metrics(dashed).length, inInclusiveRange(18, 21));
      for (final metric in _metrics(dashed)) {
        for (final t in [0.0, 0.5, 1.0]) {
          final point = metric.getTangentForOffset(metric.length * t)!.position;
          expect((point - const Offset(19, 19)).distance, closeTo(18.4, 0.05));
        }
      }
    });

    test('an empty pattern leaves the path solid', () {
      final dashed = dashPath(_line(30), const []);
      _expectDashes(dashed, const [(0, 30)]);
    });

    test('zero, negative or infinite lengths leave the path solid', () {
      for (final pattern in const [
        [3.0, 0.0],
        [0.0],
        [-1.0, 2.0],
        [3.0, -3.0],
        [double.infinity, 2.0],
        [double.nan],
      ]) {
        final dashed = dashPath(_line(30), pattern);
        _expectDashes(dashed, const [(0, 30)]);
      }
    });

    test('a non finite phase leaves the path solid', () {
      for (final phase in [double.nan, double.infinity]) {
        _expectDashes(dashPath(_line(30), const [3, 3], phase: phase), const [
          (0, 30),
        ]);
      }
    });

    test('the solid copy is a new path', () {
      final source = _line(30);
      final copy = dashPath(source, const []);
      expect(identical(copy, source), isFalse);
      copy.lineTo(30, 30);
      expect(_lengthOf(source), closeTo(30, _tolerance));
    });

    test('an empty source gives an empty path', () {
      expect(_metrics(dashPath(Path(), const [3, 3])), isEmpty);
    });

    test('very short dashes on a long path finish', () {
      final dashed = dashPath(_line(1000), const [0.5, 0.5]);
      expect(_metrics(dashed), hasLength(1000));
      expect(_lengthOf(dashed), closeTo(500, 0.1));
    });
  });

  group('dashPath with fractional lengths (T3d, the hang fixed)', () {
    test('a fractional length with a phase just under the period finishes', () {
      for (final phase in [
        9 - 1e-12,
        9 - 1e-15,
        8.999999999999998,
        -(9 - 1e-12),
        -1e-15,
        4 - 1e-15,
        4 + 1e-15,
      ]) {
        final dashed = dashPath(_line(100.1), const [4, 5], phase: phase);
        final metrics = _metrics(dashed);
        expect(metrics.length, inInclusiveRange(10, 13), reason: '$phase');
        expect(
          _lengthOf(dashed),
          closeTo(100.1 * 4 / 9, 4.5),
          reason: '$phase',
        );
        for (final metric in metrics) {
          expect(metric.length, lessThanOrEqualTo(4 + 1e-4), reason: '$phase');
        }
      }
    }, timeout: _short);

    test('patterns whose sums are not exact in floating point finish', () {
      for (final pattern in const [
        [0.1, 0.2],
        [0.7, 0.1, 0.2],
        [1.1, 2.2],
        [1 / 3, 2 / 3],
      ]) {
        final total = pattern.fold<double>(0, (sum, value) => sum + value);
        for (final phase in [0.0, total - 1e-15, total, -total, total * 7.5]) {
          final dashed = dashPath(_line(33.3), pattern, phase: phase);
          expect(
            _metrics(dashed).length,
            lessThanOrEqualTo((33.3 / total).ceil() * 2 + 2),
            reason: '$pattern $phase',
          );
        }
      }
    }, timeout: _short);

    test('a real curve of the diagram with every phase of a whole clock '
        'turn finishes', () {
      final layout = layoutFlow(_wide, 3);
      final curves = [
        for (final slot in layout.slots) flowCurve(layout, slot, gap: 12),
      ];
      for (final curve in curves) {
        final length = _lengthOf(curve);
        expect(length, greaterThan(0));
        for (var frame = 0; frame < 864; frame++) {
          final elapsed = frame / 60;
          final shift = (elapsed * 18) % 9;
          for (final phase in [shift, -shift]) {
            final dashed = dashPath(curve, const [4, 5], phase: phase);
            expect(
              _metrics(dashed).length,
              lessThanOrEqualTo((length / 9).ceil() + 2),
            );
          }
        }
      }
    }, timeout: const Timeout(Duration(seconds: 60)));

    test('fractional circles dashed 3 3 and 2 2 finish', () {
      for (final radius in [18.4, 25.0, 28.0, 10.000000001, 0.3]) {
        final circle = Path()
          ..addOval(Rect.fromCircle(center: Offset.zero, radius: radius));
        for (final pattern in const [
          [3.0, 3.0],
          [2.0, 2.0],
          [2.0, 6.0],
        ]) {
          final dashed = dashPath(circle, pattern);
          final total = pattern[0] + pattern[1];
          expect(
            _metrics(dashed).length,
            lessThanOrEqualTo((2 * math.pi * radius / total).ceil() + 2),
          );
        }
      }
    }, timeout: _short);
  });

  group('FlowBackgroundPainter', () {
    test('paints the halo, four solid half rings at half strength and the '
        'radial mask inside a layer', () {
      final layout = layoutFlow(_wide, 3);
      final calls = _record(
        FlowBackgroundPainter(layout: layout, colors: NbColors.light),
        _wide,
      );
      final names = calls.map((call) => call.name).toList();
      expect(names.first, #drawRect);
      expect((calls.first.args[1] as Paint).shader, isNotNull);
      final layer = names.indexOf(#saveLayer);
      final restore = names.lastIndexOf(#restore);
      expect(layer, greaterThan(0));
      expect(restore, greaterThan(layer));
      final arcs = [
        for (final stroke in _paths(calls))
          if (stroke.index > layer && stroke.index < restore) stroke,
      ];
      expect(arcs, hasLength(4));
      final span = layout.firstColumn - layout.hub.dx;
      for (var i = 0; i < 4; i++) {
        final paint = arcs[i].paint;
        expect(paint.style, PaintingStyle.stroke);
        expect(paint.strokeWidth, 1);
        expect(
          _sameColor(
            paint.color,
            NbColors.light.border.withValues(
              alpha: NbColors.light.border.a * 0.5,
            ),
          ),
          isTrue,
        );
        final pieces = _metrics(arcs[i].path);
        expect(pieces, hasLength(1), reason: 'ring $i');
        final point = pieces.first.getTangentForOffset(0)!.position;
        expect(
          (point - layout.hub).distance,
          closeTo(span * const [0.32, 0.58, 0.84, 1.1][i], 0.05),
        );
      }
      final mask = calls.lastWhere((call) => call.name == #drawRect);
      expect(mask.index, inExclusiveRange(arcs.last.index, restore));
      expect((mask.args[1] as Paint).blendMode, BlendMode.dstIn);
    });

    test('an empty layout paints nothing and does not throw', () {
      final calls = _record(
        FlowBackgroundPainter(
          layout: layoutFlow(Size.zero, 3),
          colors: NbColors.dark,
        ),
        Size.zero,
      );
      expect(calls, isEmpty);
    });

    test('repaints only when the size, the first column or the colors '
        'change', () {
      final layout = layoutFlow(_wide, 3);
      final painter = FlowBackgroundPainter(
        layout: layout,
        colors: NbColors.light,
      );
      expect(
        painter.shouldRepaint(
          FlowBackgroundPainter(
            layout: layoutFlow(_wide, 3),
            colors: NbColors.light,
          ),
        ),
        isFalse,
      );
      expect(
        painter.shouldRepaint(
          FlowBackgroundPainter(layout: layout, colors: NbColors.dark),
        ),
        isTrue,
      );
      expect(
        painter.shouldRepaint(
          FlowBackgroundPainter(
            layout: layoutFlow(_small, 3),
            colors: NbColors.light,
          ),
        ),
        isTrue,
      );
      expect(
        painter.shouldRepaint(
          FlowBackgroundPainter(
            layout: layoutFlow(_wide, 6),
            colors: NbColors.light,
          ),
        ),
        layoutFlow(_wide, 6).firstColumn != layout.firstColumn,
      );
    });
  });

  group('FlowPainter: each line state and its device (E263, DESIGN)', () {
    final colors = NbColors.light;

    test('idle and visible: solid base line ending 8 px before the disc, '
        'node disc with a 1 px border ring and no pulse', () {
      final scene = _scene(_state());
      final slot = scene.layout.slots.single;
      final pr = scene.layout.peerRadius;
      final calls = _record(_painter(scene), _wide);
      final base = _lines(calls, 2, color: colors.border);
      expect(base, hasLength(1));
      expect(_metrics(base.single.path), hasLength(1));
      expect(
        _near(
          _end(base.single.path),
          Offset(slot.center.dx - pr - 8, slot.center.dy),
        ),
        isTrue,
      );
      expect(
        _lines(calls, 2.5, color: colors.primary.withValues(alpha: 0.75)),
        isEmpty,
      );
      expect(_discFills(calls, slot.center, pr), hasLength(1));
      expect(_rings(calls, slot.center, pr, 1, colors.border), hasLength(1));
      expect(_pulses(calls, slot.center, pr), isEmpty);
      expect(_fills(calls, slot.center, pr + 7, colors.primaryWeak), isEmpty);
      expect(
        _circles(calls).any(
          (circle) =>
              _sameColor(circle.paint.color, colors.nodeShadow) &&
              (circle.radius - pr).abs() < _tolerance &&
              (circle.center.dx - slot.center.dx).abs() < _tolerance,
        ),
        isTrue,
      );
    });

    test('idle and not visible: solid base line at 45 % and a card disc with a '
        'solid hint ring, without shadow', () {
      final scene = _scene(_state(entries: [_entry('A', visible: false)]));
      final slot = scene.layout.slots.single;
      final pr = scene.layout.peerRadius;
      final calls = _record(_painter(scene), _wide);
      expect(_lines(calls, 2, color: colors.border), isEmpty);
      final base = _lines(
        calls,
        2,
        color: colors.border.withValues(alpha: colors.border.a * 0.45),
      ).single;
      expect(_metrics(base.path), hasLength(1));
      final curveLength = _lengthOf(flowCurve(scene.layout, slot));
      expect(_lengthOf(base.path), closeTo(curveLength, 2.5));
      expect(_fills(calls, slot.center, pr, colors.card), hasLength(1));
      expect(_discFills(calls, slot.center, pr), isEmpty);
      final ring = _lines(calls, 1.2, color: colors.hint);
      expect(ring, hasLength(1));
      expect(_metrics(ring.single.path), hasLength(1));
      expect(
        _circles(calls).any(
          (circle) =>
              _sameColor(circle.paint.color, colors.nodeShadow) &&
              (circle.center.dx - slot.center.dx).abs() < _tolerance,
        ),
        isFalse,
      );
    });

    test('waiting: solid breathing line in primary, base ending 12 px before '
        'the disc, 1.5 px primary ring and a pulse', () {
      final scene = _scene(
        _state(outgoing: _out('A', OutgoingPhase.requesting)),
      );
      final slot = scene.layout.slots.single;
      final pr = scene.layout.peerRadius;
      final calls = _record(_painter(scene), _wide);
      final base = _lines(calls, 2, color: colors.border).single;
      expect(
        _near(
          _end(base.path),
          Offset(slot.center.dx - pr - 12, slot.center.dy),
        ),
        isTrue,
      );
      final line = _lines(
        calls,
        2.5,
        color: colors.primary.withValues(alpha: _breath(0)),
      );
      expect(line, hasLength(1));
      final curveLength = _lengthOf(flowCurve(scene.layout, slot, gap: 12));
      expect(_metrics(line.single.path), hasLength(1));
      expect(_lengthOf(line.single.path), closeTo(curveLength, 1));
      expect(_rings(calls, slot.center, pr, 1.5, colors.primary), hasLength(1));
      expect(_pulses(calls, slot.center, pr), hasLength(1));
      expect(_fills(calls, slot.center, pr + 7, colors.primaryWeak), isEmpty);
      expect(_dots(calls, colors), isEmpty);
    });

    test(
      'asking: solid breathing warning line, warning halo, 2 px warning ring '
      'and a warning pulse',
      () {
        final scene = _scene(_state(incoming: _in('A', IncomingStage.warning)));
        final slot = scene.layout.slots.single;
        final pr = scene.layout.peerRadius;
        final calls = _record(_painter(scene), _wide);
        final line = _lines(
          calls,
          2.5,
          color: colors.warningRing.withValues(alpha: _breath(0)),
        );
        expect(line, hasLength(1));
        expect(_metrics(line.single.path), hasLength(1));
        expect(
          _fills(calls, slot.center, pr + 7, colors.warningWeak),
          hasLength(1),
        );
        expect(
          _rings(calls, slot.center, pr, 2, colors.warningRing),
          hasLength(1),
        );
        final pulse = _pulses(calls, slot.center, pr).single;
        expect(
          _sameColor(
            pulse.paint.color.withValues(alpha: 1),
            colors.warningRing.withValues(alpha: 1),
          ),
          isTrue,
        );
      },
    );

    test('the folder question is asking too', () {
      final scene = _scene(
        _state(incoming: _in('A', IncomingStage.folderQuestion)),
      );
      final calls = _record(_painter(scene), _wide);
      expect(
        _lines(
          calls,
          2.5,
          color: colors.warningRing.withValues(alpha: _breath(0)),
        ),
        hasLength(1),
      );
    });

    test('active: partial line of 3 px with the gradient up to the progress, '
        'primary halo, 2 px primary ring, the dot and no pulse', () {
      final scene = _scene(
        _state(outgoing: _out('A', OutgoingPhase.uploading, sent: 250)),
      );
      final slot = scene.layout.slots.single;
      final pr = scene.layout.peerRadius;
      final curve = flowCurve(scene.layout, slot, gap: 12);
      final length = _lengthOf(curve);
      final calls = _record(_painter(scene), _wide);
      final partial = _lines(calls, 3);
      expect(partial, hasLength(1));
      expect(_lengthOf(partial.single.path), closeTo(length * 0.25, 0.5));
      expect(_near(_start(partial.single.path), _start(curve), 0.1), isTrue);
      expect(
        _fills(calls, slot.center, pr + 7, colors.primaryWeak),
        hasLength(1),
      );
      expect(_rings(calls, slot.center, pr, 2, colors.primary), hasLength(1));
      expect(_pulses(calls, slot.center, pr), isEmpty);
      expect(_dots(calls, colors), hasLength(1));
    });

    test('verifying is a full active line', () {
      final scene = _scene(
        _state(outgoing: _out('A', OutgoingPhase.verifying)),
      );
      final curve = flowCurve(scene.layout, scene.layout.slots.single, gap: 12);
      final calls = _record(_painter(scene), _wide);
      expect(
        _lengthOf(_lines(calls, 3).single.path),
        closeTo(_lengthOf(curve), 0.5),
      );
    });

    test('receiving: the partial line is drawn from the device end', () {
      final scene = _scene(
        _state(incoming: _in('A', IncomingStage.receiving, received: 250)),
      );
      final slot = scene.layout.slots.single;
      final curve = flowCurve(scene.layout, slot, gap: 12);
      final length = _lengthOf(curve);
      final calls = _record(_painter(scene), _wide);
      final partial = _lines(calls, 3).single.path;
      expect(_lengthOf(partial), closeTo(length * 0.25, 0.5));
      expect(_near(_end(partial), _end(curve), 0.1), isTrue);
      final from = _metrics(curve).single.getTangentForOffset(length * 0.75)!;
      expect(_near(_start(partial), from.position, 0.5), isTrue);
    });

    test('done: solid success line, success halo, 2 px success ring and the '
        'badge with its check', () {
      final scene = _scene(_state(), done: 'A');
      final slot = scene.layout.slots.single;
      final pr = scene.layout.peerRadius;
      final calls = _record(_painter(scene), _wide);
      final line = _lines(calls, 2.5, color: colors.success);
      expect(line, hasLength(1));
      expect(_metrics(line.single.path), hasLength(1));
      expect(
        _lengthOf(line.single.path),
        closeTo(_lengthOf(flowCurve(scene.layout, slot, gap: 12)), 0.5),
      );
      expect(
        _fills(calls, slot.center, pr + 7, colors.successWeak),
        hasLength(1),
      );
      expect(_rings(calls, slot.center, pr, 2, colors.success), hasLength(1));
      final badge = slot.center + Offset(pr, -pr) * 0.72;
      expect(_fills(calls, badge, 9, colors.success), hasLength(1));
      expect(_rings(calls, badge, 9, 2, colors.card), hasLength(1));
      expect(
        _paths(calls).any(
          (stroke) =>
              stroke.paint.style == PaintingStyle.stroke &&
              (stroke.paint.strokeWidth - 1.8).abs() < _tolerance &&
              _sameColor(stroke.paint.color, colors.onSuccessDisc),
        ),
        isTrue,
      );
      expect(_pulses(calls, slot.center, pr), isEmpty);
    });

    test('the device icon takes the ink of each state', () {
      final cases = <(NodeState, String?, Color)>[
        (_state(), null, colors.text),
        (_state(entries: [_entry('A', visible: false)]), null, colors.hint),
        (
          _state(outgoing: _out('A', OutgoingPhase.waiting)),
          null,
          colors.primaryInk,
        ),
        (
          _state(incoming: _in('A', IncomingStage.warning)),
          null,
          colors.warning,
        ),
        (
          _state(outgoing: _out('A', OutgoingPhase.uploading)),
          null,
          colors.primaryInk,
        ),
        (_state(), 'A', colors.success),
      ];
      for (final (state, done, ink) in cases) {
        final calls = _record(_painter(_scene(state, done: done)), _wide);
        expect(
          _paths(calls).any((stroke) => _sameColor(stroke.paint.color, ink)),
          isTrue,
          reason: '$ink',
        );
      }
    });

    test('dark colors paint every state without throwing', () {
      for (final state in [
        _state(),
        _state(outgoing: _out('A', OutgoingPhase.uploading, sent: 500)),
        _state(incoming: _in('A', IncomingStage.warning)),
        _state(incoming: _in('A', IncomingStage.waitingData)),
      ]) {
        final calls = _record(
          _painter(_scene(state), colors: NbColors.dark, seconds: 3.3),
          _wide,
        );
        expect(_discFills(calls, _scene(state).layout.hub, 38), hasLength(1));
      }
    });
  });

  group('FlowPainter: the pulse (coordinator decision)', () {
    final colors = NbColors.light;

    for (final seconds in [0.0, 0.4, 0.8, 1.2, 1.55, 2.0, 14.0]) {
      test('at ${seconds}s it grows from pr to pr + 12 and fades from 0.35 '
          'to 0 with easeOut', () {
        final scene = _scene(
          _state(outgoing: _out('A', OutgoingPhase.preparing)),
        );
        final slot = scene.layout.slots.single;
        final pr = scene.layout.peerRadius;
        final calls = _record(_painter(scene, seconds: seconds), _wide);
        final pulse = _pulses(calls, slot.center, pr).single;
        final t = (seconds % 1.6) / 1.6;
        final phase = Curves.easeOut.transform(t);
        expect(pulse.radius, closeTo(pr + 12 * phase, 0.01));
        expect(pulse.paint.color.a, closeTo(0.35 * (1 - phase), 0.005));
        expect(
          _sameColor(
            pulse.paint.color.withValues(alpha: 1),
            colors.primary.withValues(alpha: 1),
          ),
          isTrue,
        );
        expect(pulse.paint.strokeWidth, 2);
      });
    }

    test('it is painted before the disc', () {
      for (final state in [
        _state(outgoing: _out('A', OutgoingPhase.requesting)),
        _state(incoming: _in('A', IncomingStage.warning)),
      ]) {
        final scene = _scene(state);
        final slot = scene.layout.slots.single;
        final pr = scene.layout.peerRadius;
        final calls = _record(_painter(scene, seconds: 0.5), _wide);
        final pulse = _pulses(calls, slot.center, pr).single;
        final disc = _discFills(calls, slot.center, pr).single;
        expect(pulse.index, lessThan(disc.index));
      }
    });

    test('with reduced motion there is no pulse', () {
      for (final state in [
        _state(outgoing: _out('A', OutgoingPhase.requesting)),
        _state(incoming: _in('A', IncomingStage.warning)),
      ]) {
        final scene = _scene(state);
        final slot = scene.layout.slots.single;
        for (final seconds in [0.0, 0.7]) {
          final calls = _record(
            _painter(scene, seconds: seconds, reduceMotion: true),
            _wide,
          );
          expect(_pulses(calls, slot.center, scene.layout.peerRadius), isEmpty);
        }
      }
    });
  });

  group('FlowPainter: the waiting and asking lines breathe', () {
    final colors = NbColors.light;

    List<_Stroke> breathing(
      NodeState state,
      double seconds,
      Color color, {
      bool reduce = false,
    }) {
      final calls = _record(
        _painter(_scene(state), seconds: seconds, reduceMotion: reduce),
        _wide,
      );
      return [
        for (final stroke in _paths(calls))
          if (stroke.paint.style == PaintingStyle.stroke &&
              (stroke.paint.strokeWidth - 2.5).abs() < _tolerance &&
              stroke.paint.shader == null &&
              (stroke.paint.color.r - color.r).abs() < 0.004 &&
              (stroke.paint.color.g - color.g).abs() < 0.004 &&
              (stroke.paint.color.b - color.b).abs() < 0.004)
            stroke,
      ];
    }

    final cases = <(String, NodeState, Color)>[
      (
        'a send waiting',
        _state(outgoing: _out('A', OutgoingPhase.waiting)),
        colors.primary,
      ),
      (
        'a receive waiting',
        _state(incoming: _in('A', IncomingStage.waitingData)),
        colors.primary,
      ),
      (
        'asking',
        _state(incoming: _in('A', IncomingStage.warning)),
        colors.warningRing,
      ),
    ];

    for (final (name, state, color) in cases) {
      test('$name: one solid line whose opacity goes 0.3, 0.575, 0.85 and '
          'back over 2.4 s', () {
        for (final (seconds, alpha) in [
          (0.0, 0.3),
          (0.6, 0.575),
          (1.2, 0.85),
          (1.8, 0.575),
          (2.4, 0.3),
          (3.6, 0.85),
        ]) {
          final lines = breathing(state, seconds, color);
          expect(lines, hasLength(1), reason: '$seconds');
          expect(_metrics(lines.single.path), hasLength(1), reason: '$seconds');
          expect(lines.single.paint.color.a, closeTo(alpha, 0.005));
        }
      });

      test('$name: with reduced motion it stays at 0.75 whatever the clock '
          'says', () {
        for (final seconds in [0.0, 0.6, 1.2, 5.0]) {
          final lines = breathing(state, seconds, color, reduce: true);
          expect(lines, hasLength(1), reason: '$seconds');
          expect(lines.single.paint.color.a, closeTo(0.75, 0.005));
        }
      });
    }
  });

  group('FlowPainter: the dot and the file that travels', () {
    final colors = NbColors.light;

    test('sending: the dot runs the curve in 1.8 s and the real file icon, '
        '24 px high, goes half a cycle behind', () {
      for (final seconds in [0.45, 1.2, 3.0]) {
        final scene = _scene(
          _state(outgoing: _out('A', OutgoingPhase.uploading, sent: 500)),
        );
        final metric = _metrics(
          flowCurve(scene.layout, scene.layout.slots.single, gap: 12),
        ).single;
        final calls = _record(_painter(scene, seconds: seconds), _wide);
        final dotAt = metric
            .getTangentForOffset(metric.length * ((seconds % 1.8) / 1.8))!
            .position;
        expect(_near(_dots(calls, colors).single.center, dotAt, 0.05), isTrue);
        final iconAt = metric
            .getTangentForOffset(
              metric.length * (((seconds - 0.9) % 1.8) / 1.8),
            )!
            .position;
        expect(_paintsFileIcon(calls, iconAt, FileKind.pdf), isTrue);
        expect(_paintsFileIcon(calls, iconAt, FileKind.video), isFalse);
      }
    });

    test('the icon is the one of the file kind, and a program wins over the '
        'extension', () {
      for (final (name, program, kind) in [
        ('movie.mp4', false, FileKind.video),
        ('setup.pdf', true, FileKind.program),
        ('notes', false, FileKind.other),
      ]) {
        final scene = _scene(
          _state(
            outgoing: _out(
              'A',
              OutgoingPhase.uploading,
              sent: 500,
              fileName: name,
              isProgram: program,
            ),
          ),
        );
        final metric = _metrics(
          flowCurve(scene.layout, scene.layout.slots.single, gap: 12),
        ).single;
        final calls = _record(_painter(scene, seconds: 0.45), _wide);
        final iconAt = metric
            .getTangentForOffset(metric.length * 0.75)!
            .position;
        expect(_paintsFileIcon(calls, iconAt, kind), isTrue, reason: name);
      }
    });

    test('receiving: the dot and the icon go from the device to the hub', () {
      final scene = _scene(
        _state(incoming: _in('A', IncomingStage.receiving, received: 500)),
      );
      final metric = _metrics(
        flowCurve(scene.layout, scene.layout.slots.single, gap: 12),
      ).single;
      const seconds = 0.45;
      final calls = _record(_painter(scene, seconds: seconds), _wide);
      final dotAt = metric
          .getTangentForOffset(metric.length * (1 - 0.25))!
          .position;
      expect(_near(_dots(calls, colors).single.center, dotAt, 0.05), isTrue);
      final iconAt = metric
          .getTangentForOffset(metric.length * (1 - 0.75))!
          .position;
      expect(_paintsFileIcon(calls, iconAt, FileKind.image), isTrue);
    });

    test('with reduced motion neither the dot nor the icon is painted, but '
        'the progress line is', () {
      final scene = _scene(
        _state(outgoing: _out('A', OutgoingPhase.uploading, sent: 500)),
      );
      final metric = _metrics(
        flowCurve(scene.layout, scene.layout.slots.single, gap: 12),
      ).single;
      final calls = _record(
        _painter(scene, seconds: 0.45, reduceMotion: true),
        _wide,
      );
      expect(_dots(calls, colors), isEmpty);
      final iconAt = metric.getTangentForOffset(metric.length * 0.75)!.position;
      expect(_paintsFileIcon(calls, iconAt, FileKind.pdf), isFalse);
      expect(
        _lengthOf(_lines(calls, 3).single.path),
        closeTo(metric.length * 0.5, 0.5),
      );
    });
  });

  group('FlowPainter: hover, "+k", hub and order', () {
    test('the hovered device grows by 1 + 0.14 x hover around its center', () {
      final state = _state(entries: [_entry('A'), _entry('B')]);
      for (final value in [0.5, 1.0]) {
        final scene = _scene(state, hovered: 'B');
        final calls = _record(_painter(scene, hover: value), _wide);
        final b = scene.layout.slots[1].center;
        final a = scene.layout.slots[0].center;
        expect(_hasScaleAround(calls, b, 1 + 0.14 * value), isTrue);
        expect(_hasScaleAround(calls, a, 1 + 0.14 * value), isFalse);
      }
      final calm = _scene(state);
      final calls = _record(_painter(calm, hover: 1), _wide);
      for (final slot in calm.layout.slots) {
        expect(_hasScaleAround(calls, slot.center, 1.14), isFalse);
      }
    });

    test('the "+k" disc has no curve: one base line per shown device', () {
      final entries = [
        for (final id in ['A', 'B', 'C', 'D', 'E', 'F', 'G', 'H']) _entry(id),
      ];
      final scene = _scene(_state(entries: entries), size: _small);
      expect(scene.peers, hasLength(6));
      expect(scene.overflowLabel, isNotNull);
      final overflow = scene.layout.slots.firstWhere((slot) => slot.overflow);
      final pr = scene.layout.peerRadius;
      final calls = _record(_painter(scene), _small);
      final base = _lines(calls, 2, color: NbColors.light.border);
      expect(base, hasLength(6));
      for (final line in base) {
        expect(
          _near(
            _end(line.path),
            Offset(overflow.center.dx - pr - 8, overflow.center.dy),
            1,
          ),
          isFalse,
        );
      }
      expect(_discFills(calls, overflow.center, pr), hasLength(1));
      expect(
        _rings(calls, overflow.center, pr, 1, NbColors.light.border),
        hasLength(1),
      );
    });

    test('the hub: glow, ring at hr + 9 in primary at 22 %, the hub disc and '
        'the white icon', () {
      final scene = _scene(_state());
      final hub = scene.layout.hub;
      final hr = scene.layout.hubRadius;
      final calls = _record(_painter(scene), _wide);
      expect(hr, 38);
      expect(_discFills(calls, hub, hr), hasLength(1));
      expect(
        _rings(
          calls,
          hub,
          hr + 9,
          1,
          NbColors.light.primary.withValues(alpha: 0.22),
        ),
        hasLength(1),
      );
      expect(
        _circles(calls).any(
          (circle) =>
              _near(circle.center, hub) &&
              (circle.radius - (hr + 34)).abs() < _tolerance &&
              circle.paint.shader != null,
        ),
        isTrue,
      );
    });

    test('an empty hub name is not painted (point 140)', () {
      final named = _record(_painter(_scene(_state())), _wide);
      final unnamed = _record(_painter(_scene(_state(deviceName: ''))), _wide);
      expect(_paragraphs(named) - _paragraphs(unnamed), 2);
      final noFingerprint = _record(
        _painter(_scene(_state(fingerprint: ''))),
        _wide,
      );
      expect(_paragraphs(noFingerprint), _paragraphs(named));
    });

    test('NodeState() with no name, no fingerprint and no devices paints '
        'without throwing', () {
      final scene = _scene(const NodeState());
      final calls = _record(_painter(scene), _wide);
      expect(_discFills(calls, scene.layout.hub, 38), hasLength(1));
    });

    test('painting order: base lines, state lines, devices, hub, then the '
        'texts', () {
      final scene = _scene(
        _state(
          entries: [_entry('A'), _entry('B'), _entry('C', visible: false)],
          outgoing: _out(
            'A',
            OutgoingPhase.uploading,
            sent: 300,
            fileName: 'photo.jpg',
          ),
          incoming: _in('B', IncomingStage.warning),
        ),
      );
      final colors = NbColors.light;
      final pr = scene.layout.peerRadius;
      final calls = _record(_painter(scene, seconds: 0.3), _wide);
      final base = [
        ..._lines(calls, 2, color: colors.border),
        ..._lines(
          calls,
          2,
          color: colors.border.withValues(alpha: colors.border.a * 0.45),
        ),
      ];
      final state = [
        ..._lines(calls, 3),
        ..._lines(
          calls,
          2.5,
          color: colors.warningRing.withValues(alpha: _breath(0.3)),
        ),
      ];
      final discs = [
        ..._discFills(calls, scene.layout.slots[0].center, pr),
        ..._discFills(calls, scene.layout.slots[1].center, pr),
        ..._fills(calls, scene.layout.slots[2].center, pr, colors.card),
      ];
      final hub = _discFills(calls, scene.layout.hub, 38).single;
      final firstText = calls.firstWhere((call) => call.name == #drawParagraph);
      expect(base, hasLength(3));
      expect(state, hasLength(2));
      expect(discs, hasLength(3));
      final lastBase = base.map((s) => s.index).reduce(math.max);
      final firstState = state.map((s) => s.index).reduce(math.min);
      final lastState = state.map((s) => s.index).reduce(math.max);
      final firstDisc = discs.map((c) => c.index).reduce(math.min);
      final lastDisc = discs.map((c) => c.index).reduce(math.max);
      expect(lastBase, lessThan(firstState));
      expect(lastState, lessThan(firstDisc));
      expect(lastDisc, lessThan(hub.index));
      expect(hub.index, lessThan(firstText.index));
    });

    test('an empty size paints nothing and does not throw', () {
      final scene = _scene(_state(), size: Size.zero);
      expect(_record(_painter(scene), Size.zero), isEmpty);
    });

    test('repaints when the scene, the colors, reduced motion or the text '
        'direction change, and not otherwise', () {
      final scene = _scene(_state());
      final painter = _painter(scene);
      expect(painter.shouldRepaint(_painter(scene, seconds: 3)), isFalse);
      expect(painter.shouldRepaint(_painter(_scene(_state()))), isTrue);
      expect(
        painter.shouldRepaint(_painter(scene, colors: NbColors.dark)),
        isTrue,
      );
      expect(
        painter.shouldRepaint(_painter(scene, reduceMotion: true)),
        isTrue,
      );
      expect(
        painter.shouldRepaint(
          FlowPainter(
            scene: scene,
            colors: NbColors.light,
            clock: const AlwaysStoppedAnimation<double>(0),
            hover: const AlwaysStoppedAnimation<double>(0),
            reduceMotion: false,
            textDirection: TextDirection.rtl,
          ),
        ),
        isTrue,
      );
    });
  });

  group('FlowPainter: the destination ring (RF-431)', () {
    final colors = NbColors.light;

    List<_Call> ring({
      required String? hot,
      bool armable = true,
      double arm = 0,
      String? open,
      bool reduce = false,
    }) {
      final scene = _scene(_state(entries: [_entry('A'), _entry('B')]));
      return _record(
        FlowPainter(
          scene: scene,
          colors: colors,
          clock: const AlwaysStoppedAnimation<double>(0),
          hover: const AlwaysStoppedAnimation<double>(0),
          reduceMotion: reduce,
          textDirection: TextDirection.ltr,
          dragFade: const AlwaysStoppedAnimation<double>(1),
          dragSpin: const AlwaysStoppedAnimation<double>(0.3),
          lit: const {'A', 'B'},
          hot: hot,
          arm: AlwaysStoppedAnimation<double>(arm),
          armable: armable,
          openRing: ValueNotifier<String?>(open),
        ),
        _wide,
      );
    }

    List<_Stroke> dashed(List<_Call> calls) => [
      for (final stroke in _paths(calls))
        if (stroke.paint.style == PaintingStyle.stroke &&
            stroke.paint.strokeWidth == 2 &&
            stroke.paint.shader == null &&
            (stroke.paint.color.r - colors.primary.r).abs() < 0.004 &&
            (stroke.paint.color.b - colors.primary.b).abs() < 0.004 &&
            _metrics(stroke.path).length > 10)
          stroke,
    ];

    List<_Call> arcs(List<_Call> calls) =>
        calls.where((call) => call.name == #drawArc).toList();

    List<_Call> ovals(List<_Call> calls) =>
        calls.where((call) => call.name == #drawOval).toList();

    test('a device that can receive and is not under the drag has a dashed '
        'ring and nothing else', () {
      final calls = ring(hot: null);

      expect(dashed(calls), hasLength(2));
      expect(arcs(calls), isEmpty);
      expect(ovals(calls), isEmpty);
      expect(
        _sameColor(
          dashed(calls).first.paint.color,
          colors.primary.withValues(alpha: colors.primary.a * 0.85),
        ),
        isTrue,
      );
    });

    test('under the drag at 0 % the dashes are still there and the arc has '
        'not started', () {
      final calls = ring(hot: 'A', arm: 0);

      expect(dashed(calls), hasLength(2));
      expect(arcs(calls), isEmpty);
      expect(ovals(calls), isEmpty);
    });

    test('at half the 0.8 s the dashes are off and the arc covers half of the '
        'circle from the top, with no empty track', () {
      final scene = _scene(_state(entries: [_entry('A'), _entry('B')]));
      final center = scene.layout.slots.first.center;
      final pr = scene.layout.peerRadius;
      final calls = ring(hot: 'A', arm: 0.5);

      expect(dashed(calls), hasLength(1));
      final drawn = arcs(calls);
      expect(drawn, hasLength(2));
      for (final call in drawn) {
        final rect = call.args[0] as Rect;
        expect(_near(rect.center, center), isTrue);
        expect(rect.width / 2, closeTo(pr + 9, _tolerance));
        expect(call.args[1] as double, closeTo(-math.pi / 2, 0.0001));
        expect(call.args[2] as double, closeTo(math.pi, 0.0001));
        expect(call.args[3], isFalse);
        final paint = call.args[4] as Paint;
        expect(paint.strokeWidth, 3);
        expect(paint.strokeCap, StrokeCap.round);
      }
      expect((drawn.first.args[4] as Paint).maskFilter, isNotNull);
      expect((drawn.last.args[4] as Paint).maskFilter, isNull);
      expect(ovals(calls), isEmpty);
    });

    test('the arc sweeps in proportion to the fill', () {
      for (final fill in [0.1, 0.25, 0.9]) {
        final drawn = arcs(ring(hot: 'A', arm: fill));
        expect(drawn, hasLength(2), reason: '$fill');
        expect(
          drawn.last.args[2] as double,
          closeTo(2 * math.pi * fill, 0.0001),
          reason: '$fill',
        );
      }
    });

    for (final reduce in [false, true]) {
      test('at 100 % without the portal open the ring stays whole as two '
          'full arcs from the top${reduce ? ' (reduced motion)' : ''}', () {
        final scene = _scene(_state(entries: [_entry('A'), _entry('B')]));
        final center = scene.layout.slots.first.center;
        final pr = scene.layout.peerRadius;
        final calls = ring(hot: 'A', arm: 1, reduce: reduce);

        final drawn = arcs(calls);
        expect(drawn, hasLength(2));
        for (final call in drawn) {
          final rect = call.args[0] as Rect;
          expect(_near(rect.center, center), isTrue);
          expect(rect.width / 2, closeTo(pr + 9, _tolerance));
          expect(call.args[1] as double, closeTo(-math.pi / 2, 0.0001));
          expect(call.args[2] as double, closeTo(2 * math.pi, 0.0001));
          final paint = call.args[4] as Paint;
          expect(paint.strokeWidth, 3);
          expect(paint.strokeCap, StrokeCap.round);
        }
        expect((drawn.first.args[4] as Paint).maskFilter, isNotNull);
        expect((drawn.last.args[4] as Paint).maskFilter, isNull);
        expect(ovals(calls), isEmpty);
        expect(dashed(calls), hasLength(1));
      });
    }

    test('with the portal open the ring is whole and solid at 3 px, with no '
        'arc and no dashes', () {
      final scene = _scene(_state(entries: [_entry('A'), _entry('B')]));
      final pr = scene.layout.peerRadius;
      final calls = ring(hot: 'A', arm: 1, open: 'A');

      final whole = ovals(calls);
      expect(whole, hasLength(1));
      final paint = whole.single.args[1] as Paint;
      expect(paint.strokeWidth, 3);
      expect(paint.style, PaintingStyle.stroke);
      expect(_sameColor(paint.color, colors.primary), isTrue);
      expect((whole.single.args[0] as Rect).width / 2, closeTo(pr + 9, 0.01));
      expect(arcs(calls), isEmpty);
      expect(dashed(calls), hasLength(1));
    });

    test('over a device that is not mine the ring is whole at once', () {
      final calls = ring(hot: 'A', armable: false, arm: 0);

      expect(ovals(calls), hasLength(1));
      expect((ovals(calls).single.args[1] as Paint).strokeWidth, 3);
      expect(arcs(calls), isEmpty);
      expect(dashed(calls), hasLength(1));
    });

    test('repaints when the arm, the armable flag or the open ring change', () {
      final scene = _scene(_state());
      FlowPainter build({
        Animation<double>? arm,
        bool armable = false,
        ValueNotifier<String?>? open,
      }) => FlowPainter(
        scene: scene,
        colors: colors,
        clock: const AlwaysStoppedAnimation<double>(0),
        hover: const AlwaysStoppedAnimation<double>(0),
        reduceMotion: false,
        textDirection: TextDirection.ltr,
        arm: arm,
        armable: armable,
        openRing: open,
      );
      final arm = AlwaysStoppedAnimation<double>(0.2);
      final open = ValueNotifier<String?>(null);
      final base = build(arm: arm, open: open);

      expect(base.shouldRepaint(build(arm: arm, open: open)), isFalse);
      expect(
        base.shouldRepaint(
          build(arm: const AlwaysStoppedAnimation<double>(0.2), open: open),
        ),
        isTrue,
      );
      expect(
        base.shouldRepaint(build(arm: arm, armable: true, open: open)),
        isTrue,
      );
      expect(
        base.shouldRepaint(build(arm: arm, open: ValueNotifier<String?>(null))),
        isTrue,
      );
    });
  });
}
