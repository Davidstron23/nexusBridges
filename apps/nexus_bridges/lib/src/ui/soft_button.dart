import 'dart:ui' show lerpDouble;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import 'icons/glyphs.dart';
import 'modal/modal_button.dart' show paintInnerEdge;
import 'modal/timeline.dart';
import 'theme/app_theme.dart';
import 'theme/tokens.dart';

const double softButtonRadius = 8;
const Duration softButtonDuration = Duration(milliseconds: 300);
const double softButtonPressedScale = 0.96;

@immutable
final class SoftButtonLook {
  const SoftButtonLook({
    required this.fill,
    required this.ink,
    required this.edge,
    required this.ring,
    required this.shadows,
    required this.lift,
    required this.scale,
  });

  final Color fill;
  final Color ink;
  final Color edge;
  final Color ring;
  final List<BoxShadow> shadows;
  final double lift;
  final double scale;

  static SoftButtonLook lerp(SoftButtonLook a, SoftButtonLook b, double t) {
    return SoftButtonLook(
      fill: Color.lerp(a.fill, b.fill, t)!,
      ink: Color.lerp(a.ink, b.ink, t)!,
      edge: Color.lerp(a.edge, b.edge, t)!,
      ring: Color.lerp(a.ring, b.ring, t)!,
      shadows: [
        for (var i = 0; i < b.shadows.length; i++)
          i < a.shadows.length
              ? BoxShadow.lerp(a.shadows[i], b.shadows[i], t)!
              : b.shadows[i],
      ],
      lift: lerpDouble(a.lift, b.lift, t)!,
      scale: lerpDouble(a.scale, b.scale, t)!,
    );
  }
}

class _LookTween extends Tween<SoftButtonLook> {
  _LookTween({super.end});

  @override
  SoftButtonLook lerp(double t) => SoftButtonLook.lerp(begin!, end!, t);
}

List<BoxShadow> _faded(List<BoxShadow> shadows, double factor) => [
  for (final shadow in shadows)
    shadow.copyWith(
      color: shadow.color.withValues(alpha: shadow.color.a * factor),
    ),
];

SoftButtonLook softButtonLookOf(
  NbColors colors, {
  required bool enabled,
  required bool hovered,
  required bool pressed,
  required bool focused,
  required bool animate,
}) {
  final glow = colors.softButtonHoverShadow;
  final hiddenEdge = colors.buttonHighlightHover.withValues(alpha: 0);
  final ring = enabled && focused
      ? colors.primary
      : colors.primary.withValues(alpha: 0);
  if (!enabled) {
    return SoftButtonLook(
      fill: colors.surfaceWeak,
      ink: colors.hint,
      edge: hiddenEdge,
      ring: ring,
      shadows: _faded(glow, 0),
      lift: 0,
      scale: 1,
    );
  }
  if (pressed) {
    return SoftButtonLook(
      fill: colors.primaryButton,
      ink: colors.onPrimary,
      edge: colors.buttonHighlight,
      ring: ring,
      shadows: _faded(glow, 0.5),
      lift: 0,
      scale: animate ? softButtonPressedScale : 1,
    );
  }
  if (hovered || focused) {
    return SoftButtonLook(
      fill: colors.primaryButtonHover,
      ink: colors.onPrimary,
      edge: colors.buttonHighlightHover,
      ring: ring,
      shadows: glow,
      lift: animate ? -1 : 0,
      scale: 1,
    );
  }
  return SoftButtonLook(
    fill: colors.primaryWeak,
    ink: colors.primaryInk,
    edge: hiddenEdge,
    ring: ring,
    shadows: _faded(glow, 0),
    lift: 0,
    scale: 1,
  );
}

class SoftButton extends StatefulWidget {
  const SoftButton({
    required this.label,
    required this.onPressed,
    this.glyph,
    this.height = 28,
    super.key,
  });

  final String label;
  final VoidCallback? onPressed;
  final Glyph? glyph;
  final double height;

  @override
  State<SoftButton> createState() => _SoftButtonState();
}

class _SoftButtonState extends State<SoftButton> {
  final WidgetStatesController _states = WidgetStatesController();
  bool _hovered = false;
  bool _pressed = false;
  bool _focused = false;
  bool _traditional = true;

  @override
  void initState() {
    super.initState();
    _traditional =
        FocusManager.instance.highlightMode == FocusHighlightMode.traditional;
    _states.addListener(_onStates);
    FocusManager.instance.addHighlightModeListener(_onHighlightMode);
  }

  @override
  void dispose() {
    FocusManager.instance.removeHighlightModeListener(_onHighlightMode);
    _states.removeListener(_onStates);
    _states.dispose();
    super.dispose();
  }

  void _onStates() {
    final states = _states.value;
    final hovered = states.contains(WidgetState.hovered);
    final pressed = states.contains(WidgetState.pressed);
    final focused = states.contains(WidgetState.focused);
    if (hovered == _hovered && pressed == _pressed && focused == _focused) {
      return;
    }
    _hovered = hovered;
    _pressed = pressed;
    _focused = focused;
    _refresh();
  }

  void _onHighlightMode(FocusHighlightMode mode) {
    final traditional = mode == FocusHighlightMode.traditional;
    if (traditional == _traditional) return;
    _traditional = traditional;
    _refresh();
  }

  void _refresh() {
    if (!mounted) return;
    if (SchedulerBinding.instance.schedulerPhase ==
        SchedulerPhase.persistentCallbacks) {
      SchedulerBinding.instance.addPostFrameCallback((_) {
        if (mounted) setState(() {});
      });
    } else {
      setState(() {});
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = NbColors.of(context);
    final animate = !MediaQuery.disableAnimationsOf(context);
    final enabled = widget.onPressed != null;
    final look = softButtonLookOf(
      colors,
      enabled: enabled,
      hovered: _hovered,
      pressed: _pressed,
      focused: _focused && _traditional,
      animate: animate,
    );
    final glyph = widget.glyph;
    return TweenAnimationBuilder<SoftButtonLook>(
      tween: _LookTween(end: look),
      duration: animate ? softButtonDuration : Duration.zero,
      curve: labEaseOut,
      builder: (context, current, child) => Transform(
        alignment: Alignment.center,
        transform:
            Matrix4.translationValues(0, current.lift, 0) *
            Matrix4.diagonal3Values(current.scale, current.scale, 1),
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: current.fill,
            borderRadius: BorderRadius.circular(softButtonRadius),
            boxShadow: current.shadows,
          ),
          child: CustomPaint(
            foregroundPainter: _EdgePainter(
              edge: current.edge,
              ring: current.ring,
            ),
            child: TextButton(
              statesController: _states,
              onPressed: widget.onPressed,
              style: ButtonStyle(
                backgroundColor: const WidgetStatePropertyAll(
                  Colors.transparent,
                ),
                foregroundColor: WidgetStatePropertyAll(current.ink),
                overlayColor: const WidgetStatePropertyAll(Colors.transparent),
                shadowColor: const WidgetStatePropertyAll(Colors.transparent),
                surfaceTintColor: const WidgetStatePropertyAll(
                  Colors.transparent,
                ),
                elevation: const WidgetStatePropertyAll(0),
                side: const WidgetStatePropertyAll(BorderSide.none),
                shape: WidgetStatePropertyAll(
                  RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(softButtonRadius),
                  ),
                ),
                minimumSize: WidgetStatePropertyAll(Size(0, widget.height)),
                padding: const WidgetStatePropertyAll(
                  EdgeInsets.symmetric(horizontal: 10),
                ),
                textStyle: const WidgetStatePropertyAll(NbText.button),
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                splashFactory: NoSplash.splashFactory,
                animationDuration: Duration.zero,
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  if (glyph != null) ...[
                    GlyphIcon(glyph, size: 14, color: current.ink),
                    const SizedBox(width: 6),
                  ],
                  Flexible(
                    child: Text(
                      widget.label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _EdgePainter extends CustomPainter {
  const _EdgePainter({required this.edge, required this.ring});

  final Color edge;
  final Color ring;

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    if (edge.a > 0) {
      paintInnerEdge(
        canvas,
        RRect.fromRectAndRadius(rect, const Radius.circular(softButtonRadius)),
        dy: 1,
        color: edge,
      );
    }
    if (ring.a > 0) {
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          rect.inflate(3),
          const Radius.circular(softButtonRadius + 3),
        ),
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2
          ..color = ring,
      );
    }
  }

  @override
  bool shouldRepaint(_EdgePainter oldDelegate) =>
      oldDelegate.edge != edge || oldDelegate.ring != ring;
}
