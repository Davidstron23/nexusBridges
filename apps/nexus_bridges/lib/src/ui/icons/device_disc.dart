import 'package:flutter/material.dart';
import 'package:nexus_bridges_core/nexus_bridges_core.dart';

import '../../l10n/app_strings.dart';
import '../diagram/flow_painter.dart';
import '../theme/tokens.dart';
import 'glyphs.dart';

enum DeviceGlyph { pc, phone }

DeviceGlyph deviceGlyphOf(DeviceType? type) =>
    type == DeviceType.mobile ? DeviceGlyph.phone : DeviceGlyph.pc;

enum DiscTone { idle, sending, asking, notVisible }

class DeviceDisc extends StatelessWidget {
  const DeviceDisc({
    required this.type,
    this.size = 38,
    this.tone = DiscTone.idle,
    super.key,
  });

  final DeviceType? type;
  final double size;
  final DiscTone tone;

  DeviceGlyph get glyph => deviceGlyphOf(type);

  @override
  Widget build(BuildContext context) {
    final strings = AppStringsDelegate.of(context);
    final colors = NbColors.of(context);
    return Semantics(
      label: glyph == DeviceGlyph.phone
          ? strings.deviceTypeMobile
          : strings.deviceTypeDesktop,
      image: true,
      child: ExcludeSemantics(
        child: CustomPaint(
          size: Size.square(size),
          painter: _DiscPainter(glyph: glyph, tone: tone, colors: colors),
        ),
      ),
    );
  }
}

class _DiscPainter extends CustomPainter {
  const _DiscPainter({
    required this.glyph,
    required this.tone,
    required this.colors,
  });

  final DeviceGlyph glyph;
  final DiscTone tone;
  final NbColors colors;

  @override
  void paint(Canvas canvas, Size size) {
    final center = size.center(Offset.zero);
    final radius = size.width / 2;

    if (tone == DiscTone.notVisible) {
      const width = 1.2;
      final outline = Path()
        ..addOval(Rect.fromCircle(center: center, radius: radius - width / 2));
      canvas.drawPath(
        dashPath(outline, const [3, 3]),
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = width
          ..color = colors.hint,
      );
    } else {
      canvas.drawCircle(
        center,
        radius,
        Paint()
          ..shader = LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [colors.nodeTop, colors.nodeBottom],
          ).createShader(Offset.zero & size),
      );
      final (double width, Color ring) = switch (tone) {
        DiscTone.sending => (2.0, colors.primary),
        DiscTone.asking => (2.0, colors.warningRing),
        _ => (1.0, colors.border),
      };
      canvas.drawCircle(
        center,
        radius - width / 2,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = width
          ..color = ring,
      );
    }

    final ink = switch (tone) {
      DiscTone.idle => colors.text,
      DiscTone.sending => colors.primaryInk,
      DiscTone.asking => colors.warning,
      DiscTone.notVisible => colors.hint,
    };
    final iconSize = size.width * 22 / 38;
    paintGlyph(
      canvas,
      glyph == DeviceGlyph.phone ? Glyphs.phone : Glyphs.pc,
      Rect.fromCenter(center: center, width: iconSize, height: iconSize),
      ink,
    );
  }

  @override
  bool shouldRepaint(_DiscPainter oldDelegate) =>
      oldDelegate.glyph != glyph ||
      oldDelegate.tone != tone ||
      oldDelegate.colors != colors;
}

class NetworkDisc extends StatelessWidget {
  const NetworkDisc({
    required this.trusted,
    this.size = 36,
    this.glyphSize = 22,
    super.key,
  });

  final bool trusted;
  final double size;
  final double glyphSize;

  @override
  Widget build(BuildContext context) {
    final colors = NbColors.of(context);
    return ExcludeSemantics(
      child: Container(
        width: size,
        height: size,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: trusted ? null : colors.surfaceWeak,
          gradient: trusted
              ? LinearGradient(
                  begin: const Alignment(-0.906, -1.079),
                  end: const Alignment(0.906, 1.079),
                  colors: [colors.netDiscTop, colors.netDiscBottom],
                )
              : null,
          boxShadow: trusted ? colors.discShadow : null,
        ),
        child: GlyphIcon(
          Glyphs.shield,
          size: glyphSize,
          color: trusted ? colors.onSuccessDisc : colors.textWeak,
        ),
      ),
    );
  }
}
