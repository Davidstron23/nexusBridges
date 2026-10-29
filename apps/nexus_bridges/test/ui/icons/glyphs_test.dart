import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nexus_bridges/src/l10n/app_strings.dart';
import 'package:nexus_bridges/src/ui/icons/device_disc.dart';
import 'package:nexus_bridges/src/ui/icons/glyphs.dart';
import 'package:nexus_bridges/src/ui/icons/svg_path.dart';
import 'package:nexus_bridges/src/ui/theme/app_theme.dart';
import 'package:nexus_bridges/src/ui/theme/tokens.dart';
import 'package:nexus_bridges_core/nexus_bridges_core.dart';

const Map<String, Glyph> _glyphs = {
  'refresh': Glyphs.refresh,
  'send': Glyphs.send,
  'link': Glyphs.link,
  'check': Glyphs.check,
  'ban': Glyphs.ban,
  'folder': Glyphs.folder,
  'warn': Glyphs.warn,
  'pc': Glyphs.pc,
  'phone': Glyphs.phone,
  'shield': Glyphs.shield,
  'more': Glyphs.more,
  'cross': Glyphs.cross,
  'tick': Glyphs.tick,
  'swap': Glyphs.swap,
  'unlink': Glyphs.unlink,
  'arrowDown': Glyphs.arrowDown,
  'mine': Glyphs.mine,
  'someoneElse': Glyphs.someoneElse,
  'networkShield': Glyphs.networkShield,
};

const Set<String> _modalGlyphs = {
  'cross',
  'tick',
  'swap',
  'unlink',
  'arrowDown',
  'mine',
  'someoneElse',
  'networkShield',
};

const Map<String, (double, double, List<String>)> _fromDesign = {
  'refresh': (
    16,
    1.5,
    ['M13 8a5 5 0 1 1-1.5-3.6 | stroke 1.5', 'M13 2.5v2.8h-2.8 | stroke 1.5'],
  ),
  'send': (
    16,
    1.5,
    ['M8 12.5V3.5M4.5 7L8 3.5 11.5 7 | stroke 1.5', 'M3 13.5h10 | stroke 1.5'],
  ),
  'link': (
    16,
    1.5,
    [
      'M6.6 9.4l2.8-2.8 | stroke 1.5',
      'M7.3 4.6l1-1a2.6 2.6 0 0 1 3.7 3.7l-1 1M8.7 11.4l-1 1A2.6 2.6 0 0 1 '
          '4 8.7l1-1 | stroke 1.5',
    ],
  ),
  'check': (12, 1.6, ['M2.5 6.3l2.3 2.2 4.7-5 | stroke 1.6']),
  'ban': (
    12,
    1.5,
    ['circle (6, 6) r4 | stroke 1.5', 'M3.3 8.7l5.4-5.4 | stroke 1.5'],
  ),
  'folder': (
    16,
    1.4,
    [
      'M2 4.5a1 1 0 0 1 1-1h3.2l1.5 1.6H13a1 1 0 0 1 1 1V12a1 1 0 0 1-1 1H3a1 '
          '1 0 0 1-1-1z | stroke 1.4',
    ],
  ),
  'warn': (
    20,
    1.6,
    [
      'M10 3.2l7.2 12.6H2.8z | stroke 1.6',
      'M10 8.2v3.4M10 13.9v.1 | stroke 1.6',
    ],
  ),
  'pc': (
    24,
    1.6,
    [
      'rect 2.5,3.5 19x13 r2.2 | stroke 1.6 | tint',
      'M5.5 13.5h13 | stroke 1.6 | op 0.5',
      'M9.5 20.5h5M12 16.5v4 | stroke 1.6',
    ],
  ),
  'phone': (
    24,
    1.6,
    [
      'rect 6.5,2.5 11x19 r2.6 | stroke 1.6 | tint',
      'M10.5 5.2h3 | stroke 1.6 | op 0.6',
      'M11 18.5h2 | stroke 1.6',
    ],
  ),
  'shield': (
    24,
    1.8,
    [
      'M12 1.8l8.4 3.1v6.3c0 5.3-3.4 9.1-8.4 11.1-5-2-8.4-5.8-8.4-11.1V4.9z '
          '| solid',
      'M7.2 10.2a6.8 6.8 0 0 1 9.6 0 | stroke 1.8 | cut',
      'M9.1 12.4a4 4 0 0 1 5.8 0 | stroke 1.8 | cut',
      'circle (12, 15) r1.4 | solid | cut',
    ],
  ),
  'more': (
    16,
    1.5,
    [
      'circle (8, 3.5) r1.25 | solid',
      'circle (8, 8) r1.25 | solid',
      'circle (8, 12.5) r1.25 | solid',
    ],
  ),
  'cross': (16, 1.8, ['M4.5 4.5l7 7M11.5 4.5l-7 7 | stroke 1.8']),
  'tick': (16, 1.8, ['M3.5 8.4l3 2.9 6-6.6 | stroke 1.8']),
  'swap': (
    16,
    1.7,
    [
      'M3 5.5h9.5M10 3l2.5 2.5L10 8M13 10.5H3.5M6 8l-2.5 2.5L6 13 '
          '| stroke 1.7',
    ],
  ),
  'unlink': (
    16,
    1.6,
    [
      'M7.3 4.6l1-1a2.6 2.6 0 0 1 3.7 3.7l-1 1M8.7 11.4l-1 1A2.6 2.6 0 0 1 '
          '4 8.7l1-1M3 3l1.5 1.5M13 13l-1.5-1.5 | stroke 1.6',
    ],
  ),
  'arrowDown': (16, 2, ['M8 3.5v9M4.5 9L8 12.5 11.5 9 | stroke 2']),
  'mine': (
    24,
    1.6,
    [
      'M4 10.6L12 4l8 6.6V19a1.5 1.5 0 0 1-1.5 1.5h-13A1.5 1.5 0 0 1 4 19z '
          '| stroke 1.6 | tint',
      'M9 14.6l2.2 2.1 4-4.3 | stroke 1.6',
    ],
  ),
  'someoneElse': (
    24,
    1.6,
    [
      'circle (9, 8.5) r3.2 | stroke 1.6 | tint',
      'M3.5 19.5c.6-3.3 2.8-5.2 5.5-5.2c2.7 0 4.9 1.9 5.5 5.2 | stroke 1.6',
      'M15.5 6.2a3 3 0 0 1 0 5.6M17.5 14.6c1.6.6 2.6 2.2 3 4.9 | stroke 1.6',
    ],
  ),
  'networkShield': (
    24,
    1.5,
    [
      'M12 1.8l8.4 3.1v6.3c0 5.3-3.4 9.1-8.4 11.1-5-2-8.4-5.8-8.4-11.1V4.9z '
          '| stroke 1.5 | tint',
      'M7.2 10.2a6.8 6.8 0 0 1 9.6 0M9.1 12.4a4 4 0 0 1 5.8 0 | stroke 1.5',
      'circle (12, 15) r0.6 | stroke 1.5 | solid',
    ],
  ),
};

String _n(double value) => value == value.roundToDouble()
    ? value.toInt().toString()
    : value.toString();

String _describe(Glyph glyph, GlyphPart part) {
  final shape = switch (part.shape) {
    SvgShape(:final data) => data,
    RectShape(:final rect, :final radius) =>
      'rect ${_n(rect.left)},${_n(rect.top)} '
          '${_n(rect.width)}x${_n(rect.height)} r${_n(radius)}',
    CircleShape(:final center, :final radius) =>
      'circle (${_n(center.dx)}, ${_n(center.dy)}) r${_n(radius)}',
  };
  return [
    shape,
    if (part.stroke) 'stroke ${_n(part.strokeWidth ?? glyph.strokeWidth)}',
    if (part.tint) 'tint',
    if (part.solid) 'solid',
    if (part.cut) 'cut',
    if (part.opacity != 1) 'op ${_n(part.opacity)}',
  ].join(' | ');
}

Rect _tightBounds(Path path) {
  var left = double.infinity;
  var top = double.infinity;
  var right = double.negativeInfinity;
  var bottom = double.negativeInfinity;
  for (final metric in path.computeMetrics()) {
    const steps = 360;
    for (var i = 0; i <= steps; i++) {
      final point = metric
          .getTangentForOffset(metric.length * i / steps)!
          .position;
      left = math.min(left, point.dx);
      top = math.min(top, point.dy);
      right = math.max(right, point.dx);
      bottom = math.max(bottom, point.dy);
    }
  }
  return Rect.fromLTRB(left, top, right, bottom);
}

final class _Drawn {
  const _Drawn(this.path, this.paint, this.origin, this.scale);

  final Path path;
  final Paint paint;
  final Offset origin;
  final double scale;

  Rect get inkBounds {
    final local = _tightBounds(path);
    final grown = paint.style == PaintingStyle.stroke
        ? local.inflate(paint.strokeWidth / 2)
        : local;
    return Rect.fromLTRB(
      origin.dx + grown.left * scale,
      origin.dy + grown.top * scale,
      origin.dx + grown.right * scale,
      origin.dy + grown.bottom * scale,
    );
  }
}

final class _Recording {
  const _Recording(this.calls, this.drawn);

  final List<Symbol> calls;
  final List<_Drawn> drawn;
}

_Recording _record(void Function(Canvas canvas) paint) {
  final canvas = TestRecordingCanvas();
  paint(canvas);
  expect(canvas.getSaveCount(), 0);
  var dx = 0.0;
  var dy = 0.0;
  var scale = 1.0;
  final drawn = <_Drawn>[];
  for (final call in canvas.invocations) {
    final arguments = call.invocation.positionalArguments;
    switch (call.invocation.memberName) {
      case #translate:
        dx += scale * (arguments[0] as double);
        dy += scale * (arguments[1] as double);
      case #scale:
        scale *= arguments[0] as double;
      case #drawPath:
        drawn.add(
          _Drawn(
            arguments[0] as Path,
            arguments[1] as Paint,
            Offset(dx, dy),
            scale,
          ),
        );
    }
  }
  return _Recording([
    for (final call in canvas.invocations) call.invocation.memberName,
  ], drawn);
}

Future<void> _pump(
  WidgetTester tester,
  Widget child, {
  Brightness brightness = Brightness.light,
  String languageCode = 'en',
}) async {
  await tester.pumpWidget(
    MaterialApp(
      locale: Locale(languageCode),
      supportedLocales: const [Locale('en'), Locale('es')],
      localizationsDelegates: const [
        AppStringsDelegate(),
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      theme: buildTheme(brightness),
      themeAnimationDuration: Duration.zero,
      home: Scaffold(body: Center(child: child)),
    ),
  );
  await tester.pump();
}

RenderObject _painterOf(WidgetTester tester, Finder owner) =>
    tester.renderObject(
      find.descendant(of: owner, matching: find.byType(CustomPaint)).first,
    );

NbColors _colorsFor(Brightness brightness) =>
    brightness == Brightness.dark ? NbColors.dark : NbColors.light;

double _f32(double value) => (Float32List(1)..[0] = value)[0];

const Color _red = Color(0xFFAA1020);
const Color _blue = Color(0xFF1040AA);

void main() {
  group('E258: glyph data copied from DESIGN.md', () {
    test('Glyphs holds the nineteen glyphs of the 005: the eleven of '
        'DESIGN.md and the eight of the modals (E281)', () {
      expect(_glyphs, hasLength(19));
      expect(_glyphs.keys.toSet(), _fromDesign.keys.toSet());
      expect(_glyphs.keys.toSet().containsAll(_modalGlyphs), isTrue);
    });

    for (final entry in _fromDesign.entries) {
      test('${entry.key} has the box, stroke and parts of DESIGN.md', () {
        final glyph = _glyphs[entry.key]!;
        final (box, stroke, parts) = entry.value;
        expect(glyph.box, box);
        expect(glyph.strokeWidth, stroke);
        expect([for (final part in glyph.parts) _describe(glyph, part)], parts);
      });
    }
  });

  group('E258: paintGlyph', () {
    for (final entry in _glyphs.entries) {
      for (final size in [14.0, 16.0, 24.0, 38.0, 40.0]) {
        test('${entry.key} at $size px paints inside its rect', () {
          final rect = Rect.fromLTWH(10, 20, size, size);
          final recording = _record(
            (canvas) => paintGlyph(canvas, entry.value, rect, _red),
          );
          expect(recording.drawn, isNotEmpty);
          for (final drawn in recording.drawn) {
            expect(drawn.scale, closeTo(size / entry.value.box, 1e-9));
            final ink = drawn.inkBounds;
            expect(
              rect.inflate(0.01).contains(ink.topLeft) &&
                  rect.inflate(0.01).contains(ink.bottomRight),
              isTrue,
              reason: '${entry.key}: $ink outside $rect',
            );
          }
        });
      }
    }

    test('strokes are round and follow the part order and opacity', () {
      final recording = _record(
        (canvas) => paintGlyph(
          canvas,
          Glyphs.pc,
          const Rect.fromLTWH(0, 0, 24, 24),
          _red,
        ),
      );
      final paints = [for (final drawn in recording.drawn) drawn.paint];
      expect(paints, hasLength(4));
      expect(paints[0].style, PaintingStyle.fill);
      expect(paints[0].color.a, closeTo(0.16, 1e-6));
      for (final paint in paints.skip(1)) {
        expect(paint.style, PaintingStyle.stroke);
        expect(paint.strokeCap, StrokeCap.round);
        expect(paint.strokeJoin, StrokeJoin.round);
        expect(paint.strokeWidth, closeTo(1.6, 1e-6));
        expect(paint.blendMode, BlendMode.srcOver);
      }
      expect(paints[1].color.a, closeTo(1, 1e-6));
      expect(paints[2].color.a, closeTo(0.5, 1e-6));
      expect(paints[3].color.a, closeTo(1, 1e-6));
      expect(paints[1].color.r, closeTo(_red.r, 1e-6));
      expect(recording.calls, isNot(contains(#saveLayer)));
    });

    test('strokeScale multiplies every stroke width', () {
      final thin = _record(
        (canvas) => paintGlyph(
          canvas,
          Glyphs.phone,
          const Rect.fromLTWH(0, 0, 24, 24),
          _red,
          strokeScale: 1.5 / 1.6,
        ),
      );
      for (final drawn in thin.drawn) {
        if (drawn.paint.style == PaintingStyle.stroke) {
          expect(drawn.paint.strokeWidth, closeTo(1.5, 1e-6));
        }
      }
      final hub = _record(
        (canvas) => paintGlyph(
          canvas,
          Glyphs.check,
          const Rect.fromLTWH(0, 0, 12, 12),
          _red,
          strokeScale: 2,
        ),
      );
      expect(hub.drawn.single.paint.strokeWidth, closeTo(3.2, 1e-6));
    });

    test('the shield is a solid shape with the arcs and dot cut out', () {
      final recording = _record(
        (canvas) => paintGlyph(
          canvas,
          Glyphs.shield,
          const Rect.fromLTWH(0, 0, 24, 24),
          _red.withValues(alpha: 0.5),
        ),
      );
      expect(recording.calls.first, #saveLayer);
      expect(recording.calls.last, #restore);
      final paints = [for (final drawn in recording.drawn) drawn.paint];
      expect(paints, hasLength(4));
      expect(paints[0].style, PaintingStyle.fill);
      expect(paints[0].blendMode, BlendMode.srcOver);
      expect(paints[0].color.a, closeTo(0.5, 1e-6));
      for (final arc in paints.sublist(1, 3)) {
        expect(arc.style, PaintingStyle.stroke);
        expect(arc.strokeWidth, closeTo(1.8, 1e-6));
        expect(arc.strokeCap, StrokeCap.round);
        expect(arc.blendMode, BlendMode.dstOut);
        expect(arc.color.a, closeTo(1, 1e-6));
      }
      expect(paints[3].style, PaintingStyle.fill);
      expect(paints[3].blendMode, BlendMode.dstOut);
      final dot = recording.drawn[3].path;
      expect(dot.contains(const Offset(12, 15)), isTrue);
      expect(dot.contains(const Offset(12, 16.6)), isFalse);
    });

    test('more paints three filled dots and no stroke', () {
      final recording = _record(
        (canvas) => paintGlyph(
          canvas,
          Glyphs.more,
          const Rect.fromLTWH(0, 0, 16, 16),
          _red,
        ),
      );
      expect(recording.drawn, hasLength(3));
      final centers = [
        const Offset(8, 3.5),
        const Offset(8, 8),
        const Offset(8, 12.5),
      ];
      for (var i = 0; i < 3; i++) {
        final drawn = recording.drawn[i];
        expect(drawn.paint.style, PaintingStyle.fill);
        expect(drawn.path.contains(centers[i]), isTrue);
        expect(drawn.path.contains(centers[i] + const Offset(1.4, 0)), isFalse);
      }
    });

    test('every svg part of a glyph matches the reader output', () {
      for (final entry in _glyphs.entries) {
        final recording = _record(
          (canvas) => paintGlyph(
            canvas,
            entry.value,
            Rect.fromLTWH(0, 0, entry.value.box, entry.value.box),
            _red,
          ),
        );
        final svgParts = [
          for (final part in entry.value.parts)
            if (part.shape case SvgShape(:final data)) data,
        ];
        final drawnBounds = {
          for (final drawn in recording.drawn) _tightBounds(drawn.path),
        };
        for (final data in svgParts) {
          final expected = _tightBounds(parseSvgPath(data));
          expect(
            drawnBounds.any(
              (bounds) =>
                  (bounds.left - expected.left).abs() < 1e-6 &&
                  (bounds.top - expected.top).abs() < 1e-6 &&
                  (bounds.right - expected.right).abs() < 1e-6 &&
                  (bounds.bottom - expected.bottom).abs() < 1e-6,
            ),
            isTrue,
            reason: '${entry.key}: $data',
          );
        }
      }
    });
  });

  group('E281: glyphs of the modals', () {
    test('no glyph path uses a command the reader does not support', () {
      final unsupported = RegExp('[sSqQtT]');
      for (final entry in _glyphs.entries) {
        for (final part in entry.value.parts) {
          if (part.shape case SvgShape(:final data)) {
            expect(unsupported.hasMatch(data), isFalse, reason: entry.key);
            expect(() => parseSvgPath(data), returnsNormally);
          }
        }
      }
    });

    test('someoneElse rewrites the smooth curve of the design as the '
        'equivalent cubic', () {
      final body = Glyphs.someoneElse.parts
          .map((part) => part.shape)
          .whereType<SvgShape>()
          .first
          .data;
      expect(body, isNot(contains('s')));
      final parsed = parseSvgPath(body);
      final smooth = Path()
        ..moveTo(3.5, 19.5)
        ..cubicTo(4.1, 16.2, 6.3, 14.3, 9, 14.3)
        ..cubicTo(9 + (9 - 6.3), 14.3, 13.9, 16.2, 14.5, 19.5);
      final got = parsed.computeMetrics().single;
      final want = smooth.computeMetrics().single;
      expect(got.length, closeTo(want.length, 1e-3));
      for (var i = 0; i <= 40; i++) {
        final a = got.getTangentForOffset(got.length * i / 40)!.position;
        final b = want.getTangentForOffset(want.length * i / 40)!.position;
        expect((a - b).distance, lessThan(1e-3), reason: 'sample $i');
      }
    });

    test('the tinted parts fill at 16 % under their stroke and none of the '
        'eight cuts', () {
      final counts = {
        'cross': 1,
        'tick': 1,
        'swap': 1,
        'unlink': 1,
        'arrowDown': 1,
        'mine': 3,
        'someoneElse': 4,
        'networkShield': 5,
      };
      expect(counts.keys.toSet(), _modalGlyphs);
      for (final name in _modalGlyphs) {
        final glyph = _glyphs[name]!;
        final recording = _record(
          (canvas) => paintGlyph(
            canvas,
            glyph,
            Rect.fromLTWH(0, 0, glyph.box, glyph.box),
            _red,
          ),
        );
        expect(recording.calls, isNot(contains(#saveLayer)), reason: name);
        expect(recording.drawn, hasLength(counts[name]), reason: name);
        for (final drawn in recording.drawn) {
          expect(drawn.paint.blendMode, BlendMode.srcOver, reason: name);
          if (drawn.paint.style == PaintingStyle.stroke) {
            expect(
              drawn.paint.strokeWidth,
              closeTo(glyph.strokeWidth, 1e-6),
              reason: name,
            );
            expect(drawn.paint.strokeCap, StrokeCap.round, reason: name);
            expect(drawn.paint.strokeJoin, StrokeJoin.round, reason: name);
            expect(drawn.paint.color.a, closeTo(1, 1e-6), reason: name);
          }
        }
      }
    });

    test('mine is a tinted house with a check', () {
      final recording = _record(
        (canvas) => paintGlyph(
          canvas,
          Glyphs.mine,
          const Rect.fromLTWH(0, 0, 24, 24),
          _red,
        ),
      );
      final paints = [for (final drawn in recording.drawn) drawn.paint];
      expect(paints[0].style, PaintingStyle.fill);
      expect(paints[0].color.a, closeTo(0.16, 1e-6));
      expect(recording.drawn[0].path.contains(const Offset(12, 15)), isTrue);
      expect(paints[1].style, PaintingStyle.stroke);
      expect(paints[2].style, PaintingStyle.stroke);
    });

    test('someoneElse has a tinted head', () {
      final recording = _record(
        (canvas) => paintGlyph(
          canvas,
          Glyphs.someoneElse,
          const Rect.fromLTWH(0, 0, 24, 24),
          _red,
        ),
      );
      final head = recording.drawn[0];
      expect(head.paint.style, PaintingStyle.fill);
      expect(head.paint.color.a, closeTo(0.16, 1e-6));
      expect(head.path.contains(const Offset(9, 8.5)), isTrue);
      expect(head.path.contains(const Offset(9, 12)), isFalse);
      expect(recording.drawn[1].paint.style, PaintingStyle.stroke);
    });

    test('networkShield is a tinted, stroked shield with two arcs and a '
        'solid dot', () {
      final recording = _record(
        (canvas) => paintGlyph(
          canvas,
          Glyphs.networkShield,
          const Rect.fromLTWH(0, 0, 24, 24),
          _red,
        ),
      );
      final paints = [for (final drawn in recording.drawn) drawn.paint];
      expect(paints[0].style, PaintingStyle.fill);
      expect(paints[0].color.a, closeTo(0.16, 1e-6));
      expect(paints[1].style, PaintingStyle.stroke);
      expect(paints[2].style, PaintingStyle.stroke);
      expect(recording.drawn[2].path.computeMetrics().toList(), hasLength(2));
      expect(paints[3].style, PaintingStyle.fill);
      expect(paints[3].color.a, closeTo(1, 1e-6));
      final dot = recording.drawn[3].path;
      expect(dot.contains(const Offset(12, 15)), isTrue);
      expect(dot.contains(const Offset(12, 15.8)), isFalse);
      expect(paints[4].style, PaintingStyle.stroke);
    });
  });

  group('E258: GlyphIcon', () {
    for (final brightness in Brightness.values) {
      testWidgets('every glyph at 14, 16, 24, 38 and 40 px in '
          '${brightness.name}', (tester) async {
        await _pump(
          tester,
          Wrap(
            children: [
              for (final entry in _glyphs.entries)
                for (final size in [14.0, 16.0, 24.0, 38.0, 40.0])
                  GlyphIcon(
                    entry.value,
                    size: size,
                    key: ValueKey('${entry.key}-$size'),
                  ),
            ],
          ),
          brightness: brightness,
        );
        expect(tester.takeException(), isNull);
        for (final entry in _glyphs.entries) {
          for (final size in [14.0, 16.0, 24.0, 38.0, 40.0]) {
            expect(
              tester.getSize(find.byKey(ValueKey('${entry.key}-$size'))),
              Size.square(size),
            );
          }
        }
      });
    }

    testWidgets('the default size is 16', (tester) async {
      await _pump(tester, const GlyphIcon(Glyphs.send));
      expect(tester.getSize(find.byType(GlyphIcon)), const Size.square(16));
    });

    testWidgets('without a color it takes the IconTheme color', (tester) async {
      await _pump(
        tester,
        const IconTheme(
          data: IconThemeData(color: _red),
          child: GlyphIcon(Glyphs.check),
        ),
      );
      expect(
        _painterOf(tester, find.byType(GlyphIcon)),
        paints..path(color: _red, style: PaintingStyle.stroke),
      );
    });

    testWidgets('an explicit color wins over the IconTheme', (tester) async {
      await _pump(
        tester,
        const IconTheme(
          data: IconThemeData(color: _red),
          child: GlyphIcon(Glyphs.check, color: _blue),
        ),
      );
      expect(
        _painterOf(tester, find.byType(GlyphIcon)),
        paints..path(color: _blue, style: PaintingStyle.stroke),
      );
    });

    testWidgets('it follows the disabled color of an icon button', (
      tester,
    ) async {
      await _pump(
        tester,
        FilledButton.icon(
          onPressed: null,
          icon: const GlyphIcon(Glyphs.send, size: 14),
          label: const SizedBox(width: 10),
        ),
      );
      final disabled = IconTheme.of(tester.element(find.byType(GlyphIcon)))
          .color;
      expect(disabled, isNotNull);
      expect(
        _painterOf(tester, find.byType(GlyphIcon)),
        paints..path(color: disabled, style: PaintingStyle.stroke),
      );
    });

    testWidgets('it adds nothing to the semantics tree', (tester) async {
      final handle = tester.ensureSemantics();
      await _pump(
        tester,
        Semantics(
          container: true,
          label: 'host',
          child: const GlyphIcon(Glyphs.warn),
        ),
      );
      final node = tester.getSemantics(find.byType(GlyphIcon));
      expect(node.label, 'host');
      expect(node.childrenCount, 0);
      handle.dispose();
    });
  });

  group('E258: deviceGlyphOf', () {
    test('mobile is a phone, desktop and unknown are a computer', () {
      expect(deviceGlyphOf(DeviceType.mobile), DeviceGlyph.phone);
      expect(deviceGlyphOf(DeviceType.desktop), DeviceGlyph.pc);
      expect(deviceGlyphOf(null), DeviceGlyph.pc);
    });

    test('DeviceDisc.glyph follows deviceGlyphOf', () {
      expect(
        const DeviceDisc(type: DeviceType.mobile).glyph,
        DeviceGlyph.phone,
      );
      expect(const DeviceDisc(type: DeviceType.desktop).glyph, DeviceGlyph.pc);
      expect(const DeviceDisc(type: null).glyph, DeviceGlyph.pc);
    });
  });

  group('E258: DeviceDisc', () {
    const types = <DeviceType?>[DeviceType.desktop, DeviceType.mobile, null];

    for (final brightness in Brightness.values) {
      testWidgets('every type and tone paints without errors in '
          '${brightness.name}', (tester) async {
        await _pump(
          tester,
          Wrap(
            children: [
              for (final type in types)
                for (final tone in DiscTone.values)
                  DeviceDisc(type: type, tone: tone),
            ],
          ),
          brightness: brightness,
        );
        expect(tester.takeException(), isNull);
        final discs = find.byType(DeviceDisc);
        expect(discs, findsNWidgets(12));
        for (var i = 0; i < 12; i++) {
          expect(tester.getSize(discs.at(i)), const Size.square(38));
        }
      });

      for (final type in types) {
        final glyph = deviceGlyphOf(type);
        final inside = glyph == DeviceGlyph.phone
            ? const Offset(12, 19)
            : const Offset(4, 12);
        final outside = glyph == DeviceGlyph.phone
            ? const Offset(4, 12)
            : const Offset(12, 19);

        testWidgets('idle ${type?.name ?? 'unknown'} in ${brightness.name}: '
            'gradient disc, 1 px border ring, text icon', (tester) async {
          final colors = _colorsFor(brightness);
          await _pump(tester, DeviceDisc(type: type), brightness: brightness);
          expect(
            _painterOf(tester, find.byType(DeviceDisc)),
            paints
              ..circle(x: 19, y: 19, radius: 19, style: PaintingStyle.fill)
              ..circle(
                x: 19,
                y: 19,
                radius: 18.5,
                strokeWidth: 1,
                color: colors.border,
                style: PaintingStyle.stroke,
              )
              ..translate(x: 8, y: 8)
              ..path(
                includes: [inside],
                excludes: [outside],
                style: PaintingStyle.fill,
              )
              ..path(
                color: colors.text,
                strokeWidth: _f32(1.6),
                style: PaintingStyle.stroke,
              ),
          );
        });
      }

      testWidgets('sending in ${brightness.name}: 2 px primary ring and '
          'primaryInk icon', (tester) async {
        final colors = _colorsFor(brightness);
        await _pump(
          tester,
          const DeviceDisc(type: DeviceType.desktop, tone: DiscTone.sending),
          brightness: brightness,
        );
        expect(
          _painterOf(tester, find.byType(DeviceDisc)),
          paints
            ..circle(radius: 19, style: PaintingStyle.fill)
            ..circle(
              radius: 18,
              strokeWidth: 2,
              color: colors.primary,
              style: PaintingStyle.stroke,
            )
            ..path(style: PaintingStyle.fill)
            ..path(color: colors.primaryInk, style: PaintingStyle.stroke),
        );
      });

      testWidgets('asking in ${brightness.name}: 2 px warningRing ring and '
          'warning icon', (tester) async {
        final colors = _colorsFor(brightness);
        await _pump(
          tester,
          const DeviceDisc(type: DeviceType.mobile, tone: DiscTone.asking),
          brightness: brightness,
        );
        expect(
          _painterOf(tester, find.byType(DeviceDisc)),
          paints
            ..circle(radius: 19, style: PaintingStyle.fill)
            ..circle(
              radius: 18,
              strokeWidth: 2,
              color: colors.warningRing,
              style: PaintingStyle.stroke,
            )
            ..path(style: PaintingStyle.fill)
            ..path(color: colors.warning, style: PaintingStyle.stroke),
        );
      });

      testWidgets('not visible in ${brightness.name}: no fill, dashed hint '
          'outline and hint icon', (tester) async {
        final colors = _colorsFor(brightness);
        await _pump(
          tester,
          const DeviceDisc(type: null, tone: DiscTone.notVisible),
          brightness: brightness,
        );
        final painter = _painterOf(tester, find.byType(DeviceDisc));
        expect(painter, paintsExactlyCountTimes(#drawCircle, 0));
        expect(
          painter,
          paints
            ..path(
              color: colors.hint,
              strokeWidth: _f32(1.2),
              style: PaintingStyle.stroke,
            )
            ..path(style: PaintingStyle.fill)
            ..path(color: colors.hint, style: PaintingStyle.stroke),
        );
        expect(
          painter,
          paints..something((method, arguments) {
            if (method != #drawPath) return false;
            final paint = arguments[1] as Paint;
            if ((paint.strokeWidth - 1.2).abs() > 1e-6) return false;
            final metrics = (arguments[0] as Path).computeMetrics().toList();
            final drawn = metrics.fold<double>(
              0,
              (sum, metric) => sum + metric.length,
            );
            final circumference = 2 * math.pi * (19 - 0.6);
            final bounds = _tightBounds(arguments[0] as Path);
            return metrics.length > 10 &&
                (drawn - circumference / 2).abs() < 3 &&
                bounds.left >= 0 &&
                bounds.top >= 0 &&
                bounds.right <= 38 &&
                bounds.bottom <= 38;
          }),
        );
      });
    }

    testWidgets('the icon measures size x 22/38 and is centred', (
      tester,
    ) async {
      await _pump(tester, const DeviceDisc(type: DeviceType.desktop, size: 76));
      expect(tester.getSize(find.byType(DeviceDisc)), const Size.square(76));
      expect(
        _painterOf(tester, find.byType(DeviceDisc)),
        paints
          ..circle(x: 38, y: 38, radius: 38)
          ..translate(x: 16, y: 16)
          ..path(includes: [const Offset(4, 12)], style: PaintingStyle.fill),
      );
      await _pump(tester, const DeviceDisc(type: DeviceType.desktop, size: 38));
      expect(
        _painterOf(tester, find.byType(DeviceDisc)),
        paints
          ..circle(x: 19, y: 19, radius: 19)
          ..translate(x: 8, y: 8),
      );
    });

    for (final code in ['es', 'en']) {
      testWidgets('semantics in $code: device type label as an image', (
        tester,
      ) async {
        final strings = stringsFor(code);
        final handle = tester.ensureSemantics();
        await _pump(
          tester,
          const Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              DeviceDisc(type: DeviceType.mobile),
              DeviceDisc(type: DeviceType.desktop),
              DeviceDisc(type: null, tone: DiscTone.notVisible),
            ],
          ),
          languageCode: code,
        );
        expect(find.bySemanticsLabel(strings.deviceTypeMobile), findsOneWidget);
        expect(
          find.bySemanticsLabel(strings.deviceTypeDesktop),
          findsNWidgets(2),
        );
        final discs = find.byType(DeviceDisc);
        expect(
          tester.getSemantics(discs.at(0)),
          isSemantics(label: strings.deviceTypeMobile, isImage: true),
        );
        expect(
          tester.getSemantics(discs.at(1)),
          isSemantics(label: strings.deviceTypeDesktop, isImage: true),
        );
        handle.dispose();
      });
    }

    test('the device type labels differ by language', () {
      expect(stringsFor('es').deviceTypeMobile, 'Tel\u00e9fono');
      expect(stringsFor('es').deviceTypeDesktop, 'Ordenador');
      expect(stringsFor('en').deviceTypeMobile, 'Phone');
      expect(stringsFor('en').deviceTypeDesktop, 'Computer');
    });
  });

  group('E258: NetworkDisc', () {
    BoxDecoration decorationOf(WidgetTester tester) =>
        tester
                .widget<Container>(
                  find.descendant(
                    of: find.byType(NetworkDisc),
                    matching: find.byType(Container),
                  ),
                )
                .decoration!
            as BoxDecoration;

    GlyphIcon shieldOf(WidgetTester tester) => tester.widget<GlyphIcon>(
      find.descendant(
        of: find.byType(NetworkDisc),
        matching: find.byType(GlyphIcon),
      ),
    );

    for (final brightness in Brightness.values) {
      testWidgets('trusted in ${brightness.name}: 140 degree gradient, '
          'disc shadow and onSuccessDisc shield', (tester) async {
        final colors = _colorsFor(brightness);
        await _pump(
          tester,
          const NetworkDisc(trusted: true),
          brightness: brightness,
        );
        expect(tester.takeException(), isNull);
        expect(tester.getSize(find.byType(NetworkDisc)), const Size.square(36));
        final decoration = decorationOf(tester);
        expect(decoration.shape, BoxShape.circle);
        final gradient = decoration.gradient! as LinearGradient;
        expect(gradient.colors, [colors.netDiscTop, colors.netDiscBottom]);
        final begin = gradient.begin as Alignment;
        final end = gradient.end as Alignment;
        final direction = Offset(end.x - begin.x, end.y - begin.y);
        final radians = 140 * math.pi / 180;
        expect(
          direction.dx / direction.distance,
          closeTo(math.sin(radians), 0.01),
        );
        expect(
          direction.dy / direction.distance,
          closeTo(-math.cos(radians), 0.01),
        );
        expect(decoration.boxShadow, colors.discShadow);
        final shield = shieldOf(tester);
        expect(shield.glyph, same(Glyphs.shield));
        expect(shield.size, 22);
        expect(shield.color, colors.onSuccessDisc);
      });

      testWidgets('paused in ${brightness.name}: surfaceWeak, no shadow and '
          'textWeak shield', (tester) async {
        final colors = _colorsFor(brightness);
        await _pump(
          tester,
          const NetworkDisc(trusted: false),
          brightness: brightness,
        );
        expect(tester.takeException(), isNull);
        final decoration = decorationOf(tester);
        expect(decoration.color, colors.surfaceWeak);
        expect(decoration.gradient, isNull);
        expect(decoration.boxShadow ?? const <BoxShadow>[], isEmpty);
        final shield = shieldOf(tester);
        expect(shield.glyph, same(Glyphs.shield));
        expect(shield.color, colors.textWeak);
      });
    }

    testWidgets('size and glyph size are configurable', (tester) async {
      await _pump(
        tester,
        const NetworkDisc(trusted: true, size: 48, glyphSize: 30),
      );
      expect(tester.getSize(find.byType(NetworkDisc)), const Size.square(48));
      expect(tester.getSize(find.byType(GlyphIcon)), const Size.square(30));
    });
  });
}
