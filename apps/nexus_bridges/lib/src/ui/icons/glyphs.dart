import 'package:flutter/material.dart';

import '../theme/tokens.dart';
import 'svg_path.dart';

sealed class GlyphShape {
  const GlyphShape();
}

final class SvgShape extends GlyphShape {
  const SvgShape(this.data);

  final String data;
}

final class RectShape extends GlyphShape {
  const RectShape(this.rect, this.radius);

  final Rect rect;
  final double radius;
}

final class CircleShape extends GlyphShape {
  const CircleShape(this.center, this.radius);

  final Offset center;
  final double radius;
}

final class GlyphPart {
  const GlyphPart(
    this.shape, {
    this.stroke = true,
    this.strokeWidth,
    this.tint = false,
    this.solid = false,
    this.cut = false,
    this.opacity = 1,
  });

  final GlyphShape shape;
  final bool stroke;
  final double? strokeWidth;
  final bool tint;
  final bool solid;
  final bool cut;
  final double opacity;
}

final class Glyph {
  const Glyph({
    required this.box,
    required this.strokeWidth,
    required this.parts,
  });

  final double box;
  final double strokeWidth;
  final List<GlyphPart> parts;
}

abstract final class Glyphs {
  static const Glyph refresh = Glyph(
    box: 16,
    strokeWidth: 1.5,
    parts: [
      GlyphPart(SvgShape('M13 8a5 5 0 1 1-1.5-3.6')),
      GlyphPart(SvgShape('M13 2.5v2.8h-2.8')),
    ],
  );

  static const Glyph send = Glyph(
    box: 16,
    strokeWidth: 1.5,
    parts: [
      GlyphPart(SvgShape('M8 12.5V3.5M4.5 7L8 3.5 11.5 7')),
      GlyphPart(SvgShape('M3 13.5h10')),
    ],
  );

  static const Glyph link = Glyph(
    box: 16,
    strokeWidth: 1.5,
    parts: [
      GlyphPart(SvgShape('M6.6 9.4l2.8-2.8')),
      GlyphPart(
        SvgShape(
          'M7.3 4.6l1-1a2.6 2.6 0 0 1 3.7 3.7l-1 1'
          'M8.7 11.4l-1 1A2.6 2.6 0 0 1 4 8.7l1-1',
        ),
      ),
    ],
  );

  static const Glyph check = Glyph(
    box: 12,
    strokeWidth: 1.6,
    parts: [GlyphPart(SvgShape('M2.5 6.3l2.3 2.2 4.7-5'))],
  );

  static const Glyph ban = Glyph(
    box: 12,
    strokeWidth: 1.5,
    parts: [
      GlyphPart(CircleShape(Offset(6, 6), 4)),
      GlyphPart(SvgShape('M3.3 8.7l5.4-5.4')),
    ],
  );

  static const Glyph folder = Glyph(
    box: 16,
    strokeWidth: 1.4,
    parts: [
      GlyphPart(
        SvgShape(
          'M2 4.5a1 1 0 0 1 1-1h3.2l1.5 1.6H13a1 1 0 0 1 1 1V12a1 1 0 0 1-1 1'
          'H3a1 1 0 0 1-1-1z',
        ),
      ),
    ],
  );

  static const Glyph warn = Glyph(
    box: 20,
    strokeWidth: 1.6,
    parts: [
      GlyphPart(SvgShape('M10 3.2l7.2 12.6H2.8z')),
      GlyphPart(SvgShape('M10 8.2v3.4M10 13.9v.1')),
    ],
  );

  static const Glyph pc = Glyph(
    box: 24,
    strokeWidth: 1.6,
    parts: [
      GlyphPart(RectShape(Rect.fromLTWH(2.5, 3.5, 19, 13), 2.2), tint: true),
      GlyphPart(SvgShape('M5.5 13.5h13'), opacity: 0.5),
      GlyphPart(SvgShape('M9.5 20.5h5M12 16.5v4')),
    ],
  );

  static const Glyph phone = Glyph(
    box: 24,
    strokeWidth: 1.6,
    parts: [
      GlyphPart(RectShape(Rect.fromLTWH(6.5, 2.5, 11, 19), 2.6), tint: true),
      GlyphPart(SvgShape('M10.5 5.2h3'), opacity: 0.6),
      GlyphPart(SvgShape('M11 18.5h2')),
    ],
  );

  static const Glyph shield = Glyph(
    box: 24,
    strokeWidth: 1.8,
    parts: [
      GlyphPart(
        SvgShape(
          'M12 1.8l8.4 3.1v6.3c0 5.3-3.4 9.1-8.4 11.1-5-2-8.4-5.8-8.4-11.1V4.9z',
        ),
        stroke: false,
        solid: true,
      ),
      GlyphPart(SvgShape('M7.2 10.2a6.8 6.8 0 0 1 9.6 0'), cut: true),
      GlyphPart(SvgShape('M9.1 12.4a4 4 0 0 1 5.8 0'), cut: true),
      GlyphPart(
        CircleShape(Offset(12, 15), 1.4),
        stroke: false,
        solid: true,
        cut: true,
      ),
    ],
  );

  static const Glyph more = Glyph(
    box: 16,
    strokeWidth: 1.5,
    parts: [
      GlyphPart(CircleShape(Offset(8, 3.5), 1.25), stroke: false, solid: true),
      GlyphPart(CircleShape(Offset(8, 8), 1.25), stroke: false, solid: true),
      GlyphPart(CircleShape(Offset(8, 12.5), 1.25), stroke: false, solid: true),
    ],
  );
}

final Map<String, Path> _svgPaths = {};

Path _pathOf(GlyphShape shape) {
  switch (shape) {
    case SvgShape(:final data):
      return _svgPaths.putIfAbsent(data, () => parseSvgPath(data));
    case RectShape(:final rect, :final radius):
      return Path()
        ..addRRect(RRect.fromRectAndRadius(rect, Radius.circular(radius)));
    case CircleShape(:final center, :final radius):
      return Path()..addOval(Rect.fromCircle(center: center, radius: radius));
  }
}

void paintGlyph(
  Canvas canvas,
  Glyph glyph,
  Rect rect,
  Color color, {
  double strokeScale = 1,
}) {
  final scale = rect.width / glyph.box;
  final hasCut = glyph.parts.any((part) => part.cut);
  if (hasCut) {
    canvas.saveLayer(rect.inflate(glyph.strokeWidth * scale), Paint());
  } else {
    canvas.save();
  }
  canvas.translate(rect.left, rect.top);
  canvas.scale(scale);

  final opaque = color.withValues(alpha: 1);
  for (final part in glyph.parts) {
    final path = _pathOf(part.shape);
    final blend = part.cut ? BlendMode.dstOut : BlendMode.srcOver;
    final ink = part.cut ? opaque : color;

    if (part.tint) {
      canvas.drawPath(
        path,
        Paint()
          ..style = PaintingStyle.fill
          ..blendMode = blend
          ..color = ink.withValues(alpha: ink.a * 0.16),
      );
    }
    if (part.solid) {
      canvas.drawPath(
        path,
        Paint()
          ..style = PaintingStyle.fill
          ..blendMode = blend
          ..color = ink,
      );
    }
    if (part.stroke) {
      canvas.drawPath(
        path,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeCap = StrokeCap.round
          ..strokeJoin = StrokeJoin.round
          ..strokeWidth = (part.strokeWidth ?? glyph.strokeWidth) * strokeScale
          ..blendMode = blend
          ..color = ink.withValues(alpha: ink.a * part.opacity),
      );
    }
  }
  canvas.restore();
}

class GlyphIcon extends StatelessWidget {
  const GlyphIcon(this.glyph, {this.size = 16, this.color, super.key});

  final Glyph glyph;
  final double size;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final ink =
        color ?? IconTheme.of(context).color ?? NbColors.of(context).text;
    return ExcludeSemantics(
      child: CustomPaint(
        size: Size.square(size),
        painter: _GlyphPainter(glyph: glyph, color: ink),
      ),
    );
  }
}

class _GlyphPainter extends CustomPainter {
  const _GlyphPainter({required this.glyph, required this.color});

  final Glyph glyph;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    paintGlyph(canvas, glyph, Offset.zero & size, color);
  }

  @override
  bool shouldRepaint(_GlyphPainter oldDelegate) =>
      oldDelegate.glyph != glyph || oldDelegate.color != color;
}
