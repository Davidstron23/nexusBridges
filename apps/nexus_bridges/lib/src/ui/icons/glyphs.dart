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

  static const Glyph cross = Glyph(
    box: 16,
    strokeWidth: 1.8,
    parts: [GlyphPart(SvgShape('M4.5 4.5l7 7M11.5 4.5l-7 7'))],
  );

  static const Glyph tick = Glyph(
    box: 16,
    strokeWidth: 1.8,
    parts: [GlyphPart(SvgShape('M3.5 8.4l3 2.9 6-6.6'))],
  );

  static const Glyph swap = Glyph(
    box: 16,
    strokeWidth: 1.7,
    parts: [
      GlyphPart(
        SvgShape('M3 5.5h9.5M10 3l2.5 2.5L10 8M13 10.5H3.5M6 8l-2.5 2.5L6 13'),
      ),
    ],
  );

  static const Glyph unlink = Glyph(
    box: 16,
    strokeWidth: 1.6,
    parts: [
      GlyphPart(
        SvgShape(
          'M7.3 4.6l1-1a2.6 2.6 0 0 1 3.7 3.7l-1 1'
          'M8.7 11.4l-1 1A2.6 2.6 0 0 1 4 8.7l1-1'
          'M3 3l1.5 1.5M13 13l-1.5-1.5',
        ),
      ),
    ],
  );

  static const Glyph arrowDown = Glyph(
    box: 16,
    strokeWidth: 2,
    parts: [GlyphPart(SvgShape('M8 3.5v9M4.5 9L8 12.5 11.5 9'))],
  );

  static const Glyph mine = Glyph(
    box: 24,
    strokeWidth: 1.6,
    parts: [
      GlyphPart(
        SvgShape(
          'M4 10.6L12 4l8 6.6V19a1.5 1.5 0 0 1-1.5 1.5h-13A1.5 1.5 0 0 1 4 19z',
        ),
        tint: true,
      ),
      GlyphPart(SvgShape('M9 14.6l2.2 2.1 4-4.3')),
    ],
  );

  static const Glyph someoneElse = Glyph(
    box: 24,
    strokeWidth: 1.6,
    parts: [
      GlyphPart(CircleShape(Offset(9, 8.5), 3.2), tint: true),
      GlyphPart(
        SvgShape('M3.5 19.5c.6-3.3 2.8-5.2 5.5-5.2c2.7 0 4.9 1.9 5.5 5.2'),
      ),
      GlyphPart(
        SvgShape('M15.5 6.2a3 3 0 0 1 0 5.6M17.5 14.6c1.6.6 2.6 2.2 3 4.9'),
      ),
    ],
  );

  static const Glyph networkShield = Glyph(
    box: 24,
    strokeWidth: 1.5,
    parts: [
      GlyphPart(
        SvgShape(
          'M12 1.8l8.4 3.1v6.3c0 5.3-3.4 9.1-8.4 11.1-5-2-8.4-5.8-8.4-11.1V4.9z',
        ),
        tint: true,
      ),
      GlyphPart(
        SvgShape('M7.2 10.2a6.8 6.8 0 0 1 9.6 0M9.1 12.4a4 4 0 0 1 5.8 0'),
      ),
      GlyphPart(CircleShape(Offset(12, 15), 0.6), solid: true),
    ],
  );

  static const Glyph files = Glyph(
    box: 16,
    strokeWidth: 1.4,
    parts: [
      GlyphPart(
        SvgShape(
          'M6 2.5h4.2L12.5 5v6.5a1 1 0 0 1-1 1H6a1 1 0 0 1-1-1v-8a1 1 0 0 1 1-1z',
        ),
      ),
      GlyphPart(SvgShape('M10 2.5V5h2.5')),
      GlyphPart(SvgShape('M3.5 5v7.5a1 1 0 0 0 1 1h5')),
    ],
  );

  static const Glyph drop = Glyph(
    box: 24,
    strokeWidth: 1.6,
    parts: [
      GlyphPart(SvgShape('M12 3.5v11M7.5 10l4.5 4.5 4.5-4.5')),
      GlyphPart(SvgShape('M4 15.5v3a2 2 0 0 0 2 2h12a2 2 0 0 0 2-2v-3')),
    ],
  );

  static const Glyph tray = Glyph(
    box: 16,
    strokeWidth: 1.4,
    parts: [
      GlyphPart(SvgShape('M2.5 9.5h3.2l.9 1.6h2.8l.9-1.6h3.2')),
      GlyphPart(
        SvgShape(
          'M2.5 9.5v2.6a1.4 1.4 0 0 0 1.4 1.4h8.2a1.4 1.4 0 0 0 1.4-1.4V9.5'
          'L11.8 4a1.4 1.4 0 0 0-1.3-1H5.5a1.4 1.4 0 0 0-1.3 1z',
        ),
      ),
      GlyphPart(SvgShape('M8 4.8v3M6.6 6.5 8 7.9l1.4-1.4')),
    ],
  );

  static const Glyph hand = Glyph(
    box: 16,
    strokeWidth: 1.3,
    parts: [
      GlyphPart(
        SvgShape(
          'M5.5 8V3.8a1 1 0 0 1 2 0V7.5M7.5 7V2.8a1 1 0 0 1 2 0V7'
          'M9.5 7.2V3.8a1 1 0 0 1 2 0v5.4c0 2.8-1.8 4.8-4.4 4.8'
          '-1.8 0-2.8-.9-3.7-2.4L2.2 9.3a1 1 0 0 1 1.6-1.2L5.5 10',
        ),
      ),
    ],
  );

  static const Glyph chevronDown = Glyph(
    box: 16,
    strokeWidth: 1.5,
    parts: [GlyphPart(SvgShape('M3.5 6L8 10.5 12.5 6'))],
  );

  static const Glyph sliders = Glyph(
    box: 16,
    strokeWidth: 1.4,
    parts: [
      GlyphPart(SvgShape('M2.5 4.5h6M11.5 4.5h2M2.5 11.5h2M7.5 11.5h6')),
      GlyphPart(CircleShape(Offset(10, 4.5), 1.5)),
      GlyphPart(CircleShape(Offset(6, 11.5), 1.5)),
    ],
  );

  static const Glyph moon = Glyph(
    box: 16,
    strokeWidth: 1.4,
    parts: [
      GlyphPart(SvgShape('M13 9.6A5.5 5.5 0 0 1 6.4 3 5.5 5.5 0 1 0 13 9.6z')),
    ],
  );

  static const Glyph sun = Glyph(
    box: 16,
    strokeWidth: 1.4,
    parts: [
      GlyphPart(CircleShape(Offset(8, 8), 2.8)),
      GlyphPart(
        SvgShape(
          'M8 1.8v1.4M8 12.8v1.4M1.8 8h1.4M12.8 8h1.4M3.6 3.6l1 1'
          'M11.4 11.4l1 1M3.6 12.4l1-1M11.4 4.6l1-1',
        ),
      ),
    ],
  );

  static const Glyph auto = Glyph(
    box: 16,
    strokeWidth: 1.4,
    parts: [
      GlyphPart(RectShape(Rect.fromLTWH(2, 3, 12, 8.5), 1.6)),
      GlyphPart(SvgShape('M5.5 14h5M8 11.5V14')),
      GlyphPart(SvgShape('M8 3v8.5')),
      GlyphPart(SvgShape('M8 4.5h4.6v5.5H8z'), stroke: false, tint: true),
    ],
  );

  static const Glyph globe = Glyph(
    box: 16,
    strokeWidth: 1.3,
    parts: [
      GlyphPart(CircleShape(Offset(8, 8), 5.6)),
      GlyphPart(
        SvgShape(
          'M2.6 8h10.8M8 2.4c1.6 1.6 2.3 3.5 2.3 5.6C10.3 10.1 9.6 12 8 13.6'
          'C6.4 12 5.7 10.1 5.7 8C5.7 5.9 6.4 4 8 2.4z',
        ),
      ),
    ],
  );

  static const Glyph back = Glyph(
    box: 16,
    strokeWidth: 1.5,
    parts: [GlyphPart(SvgShape('M13 8H3.5M7.5 4L3.5 8l4 4'))],
  );

  static const Glyph monitor = Glyph(
    box: 16,
    strokeWidth: 1.4,
    parts: [
      GlyphPart(RectShape(Rect.fromLTWH(2, 3, 12, 8.5), 1.6)),
      GlyphPart(SvgShape('M5.5 14h5M8 11.5V14')),
    ],
  );

  static const Glyph inbox = Glyph(
    box: 16,
    strokeWidth: 1.4,
    parts: [
      GlyphPart(
        SvgShape(
          'M2.5 9.5l1.6-5.2a1 1 0 0 1 1-.8h5.8a1 1 0 0 1 1 .8l1.6 5.2V12'
          'a1 1 0 0 1-1 1H3.5a1 1 0 0 1-1-1z',
        ),
      ),
      GlyphPart(SvgShape('M2.5 9.5h3l.8 1.5h3.4l.8-1.5h3')),
    ],
  );

  static const Glyph folderX = Glyph(
    box: 16,
    strokeWidth: 1.4,
    parts: [
      GlyphPart(
        SvgShape(
          'M2 4.5a1 1 0 0 1 1-1h3.2l1.5 1.6H13a1 1 0 0 1 1 1V12a1 1 0 0 1-1 1'
          'H3a1 1 0 0 1-1-1z',
        ),
      ),
      GlyphPart(SvgShape('M6 9h4')),
    ],
  );

  static const Glyph taskbar = Glyph(
    box: 16,
    strokeWidth: 1.4,
    parts: [
      GlyphPart(RectShape(Rect.fromLTWH(2, 3, 12, 10), 2)),
      GlyphPart(SvgShape('M2 10.2h12')),
      GlyphPart(SvgShape('M10.4 11.7h.01M12.1 11.7h.01')),
    ],
  );

  static const Glyph wifi = Glyph(
    box: 16,
    strokeWidth: 1.6,
    parts: [
      GlyphPart(SvgShape('M2.5 6.6a7.8 7.8 0 0 1 11 0')),
      GlyphPart(SvgShape('M4.6 8.9a4.8 4.8 0 0 1 6.8 0')),
      GlyphPart(SvgShape('M8 11.8h.01')),
    ],
  );

  static const Glyph eyeOff = Glyph(
    box: 16,
    strokeWidth: 1.4,
    parts: [
      GlyphPart(
        SvgShape(
          'M2.5 8C2.5 8 4.5 4 8 4C11.5 4 13.5 8 13.5 8C13.5 8 11.5 12 8 12'
          'C4.5 12 2.5 8 2.5 8z',
        ),
      ),
      GlyphPart(CircleShape(Offset(8, 8), 1.8)),
      GlyphPart(SvgShape('M3 13L13 3')),
    ],
  );

  static const Glyph info = Glyph(
    box: 16,
    strokeWidth: 1.4,
    parts: [
      GlyphPart(CircleShape(Offset(8, 8), 5.6)),
      GlyphPart(SvgShape('M8 7.3v3.6M8 5.2h.01')),
    ],
  );

  static const Glyph plus = Glyph(
    box: 16,
    strokeWidth: 1.5,
    parts: [GlyphPart(SvgShape('M8 3.5v9M3.5 8h9'))],
  );

  static const Glyph star = Glyph(
    box: 16,
    strokeWidth: 1.4,
    parts: [
      GlyphPart(
        SvgShape(
          'M8 2.4l1.7 3.5 3.8.5-2.8 2.7.7 3.8L8 11.1l-3.4 1.8.7-3.8L2.5 6.4'
          'l3.8-.5z',
        ),
      ),
    ],
  );

  static const Glyph edit = Glyph(
    box: 16,
    strokeWidth: 1.4,
    parts: [
      GlyphPart(
        SvgShape(
          'M3 13l.6-2.6L10.4 3.6a1.3 1.3 0 0 1 1.9 0l.1.1a1.3 1.3 0 0 1 0 1.9'
          'L5.6 12.4z',
        ),
      ),
      GlyphPart(SvgShape('M9.4 4.6l2 2')),
    ],
  );

  static const Glyph history = Glyph(
    box: 16,
    strokeWidth: 1.4,
    parts: [
      GlyphPart(SvgShape('M2.8 8a5.2 5.2 0 1 0 1.6-3.8')),
      GlyphPart(SvgShape('M2.6 2.8v2.6h2.6')),
      GlyphPart(SvgShape('M8 5.4v2.9l1.9 1.2')),
    ],
  );

  static const Glyph folderPlus = Glyph(
    box: 16,
    strokeWidth: 1.4,
    parts: [
      GlyphPart(
        SvgShape(
          'M2 4.5a1 1 0 0 1 1-1h3.2l1.5 1.6H13a1 1 0 0 1 1 1V12a1 1 0 0 1-1 1'
          'H3a1 1 0 0 1-1-1z',
        ),
      ),
      GlyphPart(SvgShape('M8 7v4M6 9h4')),
    ],
  );

  static const Glyph chevronRight = Glyph(
    box: 16,
    strokeWidth: 1.5,
    parts: [GlyphPart(SvgShape('M6 3.5L10.5 8 6 12.5'))],
  );

  static const Glyph arrowUp = Glyph(
    box: 16,
    strokeWidth: 1.5,
    parts: [GlyphPart(SvgShape('M8 13V3.5M4.5 7L8 3.5 11.5 7'))],
  );

  static const Glyph close = Glyph(
    box: 16,
    strokeWidth: 1.5,
    parts: [GlyphPart(SvgShape('M4 4l8 8M12 4l-8 8'))],
  );

  static const Glyph restore = Glyph(
    box: 16,
    strokeWidth: 1.5,
    parts: [
      GlyphPart(SvgShape('M3 8a5 5 0 1 0 1.5-3.6')),
      GlyphPart(SvgShape('M3 2.5v2.8h2.8')),
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
  const GlyphIcon(
    this.glyph, {
    this.size = 16,
    this.color,
    this.strokeScale = 1,
    super.key,
  });

  final Glyph glyph;
  final double size;
  final Color? color;
  final double strokeScale;

  @override
  Widget build(BuildContext context) {
    final ink =
        color ?? IconTheme.of(context).color ?? NbColors.of(context).text;
    return ExcludeSemantics(
      child: CustomPaint(
        size: Size.square(size),
        painter: _GlyphPainter(
          glyph: glyph,
          color: ink,
          strokeScale: strokeScale,
        ),
      ),
    );
  }
}

class _GlyphPainter extends CustomPainter {
  const _GlyphPainter({
    required this.glyph,
    required this.color,
    required this.strokeScale,
  });

  final Glyph glyph;
  final Color color;
  final double strokeScale;

  @override
  void paint(Canvas canvas, Size size) {
    paintGlyph(
      canvas,
      glyph,
      Offset.zero & size,
      color,
      strokeScale: strokeScale,
    );
  }

  @override
  bool shouldRepaint(_GlyphPainter oldDelegate) =>
      oldDelegate.glyph != glyph ||
      oldDelegate.color != color ||
      oldDelegate.strokeScale != strokeScale;
}
