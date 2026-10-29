import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import '../icons/glyphs.dart';
import '../theme/app_theme.dart';
import '../theme/tokens.dart';

enum ModalButtonKind { primary, neutral, secondary, negative, negativeQuiet }

const Cubic _labEaseOut = Cubic(0.23, 1, 0.32, 1);
const double _buttonRadius = 14;
const double _tileRadius = 16;
const double _borderWidth = 1.5;
const Duration _boxDuration = Duration(milliseconds: 200);
const Duration _liftDuration = Duration(milliseconds: 160);
const Duration _dimDuration = Duration(milliseconds: 300);

void paintInnerEdge(
  Canvas canvas,
  RRect rrect, {
  required double dy,
  required Color color,
}) {
  final edge = Path.combine(
    PathOperation.difference,
    Path()..addRRect(rrect),
    Path()..addRRect(rrect.shift(Offset(0, dy))),
  );
  canvas.drawPath(edge, Paint()..color = color);
}

mixin _PressStates<T extends StatefulWidget> on State<T> {
  final WidgetStatesController statesController = WidgetStatesController();
  bool _hovered = false;
  bool _pressed = false;
  bool _focused = false;
  bool _traditional = true;

  bool get hovered => _hovered;
  bool get pressed => _pressed;
  bool get keyboardFocused => _focused && _traditional;

  void statesChanged() {}

  @override
  void initState() {
    super.initState();
    _traditional =
        FocusManager.instance.highlightMode == FocusHighlightMode.traditional;
    statesController.addListener(_onStates);
    FocusManager.instance.addHighlightModeListener(_onHighlightMode);
  }

  @override
  void dispose() {
    FocusManager.instance.removeHighlightModeListener(_onHighlightMode);
    statesController.removeListener(_onStates);
    statesController.dispose();
    super.dispose();
  }

  void _onStates() {
    final states = statesController.value;
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
      SchedulerBinding.instance.addPostFrameCallback((_) => _apply());
    } else {
      _apply();
    }
  }

  void _apply() {
    if (!mounted) return;
    setState(() {});
    statesChanged();
  }
}

class _Look {
  const _Look({
    required this.fill,
    required this.ink,
    required this.shadows,
    required this.edge,
    this.border,
  });

  final Color fill;
  final Color ink;
  final List<BoxShadow> shadows;
  final Color edge;
  final Color? border;
}

_Look _lookOf(
  NbColors colors,
  ModalButtonKind kind, {
  required bool hover,
  required bool enabled,
}) {
  final hidden = colors.buttonHighlight.withValues(alpha: 0);
  final active = hover && enabled;
  switch (kind) {
    case ModalButtonKind.primary:
      return _Look(
        fill: active ? colors.primaryButtonHover : colors.primaryButton,
        ink: colors.onPrimary,
        shadows: !enabled
            ? const []
            : (active
                  ? colors.primaryButtonHoverShadow
                  : colors.primaryButtonShadow),
        edge: !enabled
            ? hidden
            : (active ? colors.buttonHighlightHover : colors.buttonHighlight),
      );
    case ModalButtonKind.neutral:
      return _Look(
        fill: active
            ? colors.primaryButtonHover
            : colors.primaryButtonHover.withValues(alpha: 0),
        ink: active ? colors.onPrimary : colors.text,
        shadows: active ? colors.primaryButtonHoverShadow : const [],
        edge: active ? colors.buttonHighlightHover : hidden,
      );
    case ModalButtonKind.secondary:
      return _Look(
        fill: active
            ? colors.primaryWeak
            : colors.primaryWeak.withValues(alpha: 0),
        ink: active ? colors.primaryInk : colors.text,
        shadows: const [],
        edge: hidden,
        border: active ? colors.primary : colors.border,
      );
    case ModalButtonKind.negative:
      return _Look(
        fill: active ? colors.dangerFill : colors.dangerWeak,
        ink: active ? colors.onPrimary : colors.danger,
        shadows: active ? colors.dangerButtonHoverShadow : const [],
        edge: active ? colors.buttonHighlight : hidden,
      );
    case ModalButtonKind.negativeQuiet:
      return _Look(
        fill: active
            ? colors.dangerFill
            : colors.dangerFill.withValues(alpha: 0),
        ink: active ? colors.onPrimary : colors.danger,
        shadows: active ? colors.dangerButtonHoverShadow : const [],
        edge: active ? colors.buttonHighlight : hidden,
      );
  }
}

class _BoxPainter extends CustomPainter {
  const _BoxPainter({
    required this.radius,
    required this.edge,
    required this.ring,
  });

  final double radius;
  final Color edge;
  final Color? ring;

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    if (edge.a > 0) {
      paintInnerEdge(
        canvas,
        RRect.fromRectAndRadius(rect, Radius.circular(radius)),
        dy: 1,
        color: edge,
      );
    }
    final ring = this.ring;
    if (ring != null) {
      canvas.drawRRect(
        RRect.fromRectAndRadius(rect.inflate(3), Radius.circular(radius + 3)),
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2
          ..color = ring,
      );
    }
  }

  @override
  bool shouldRepaint(_BoxPainter oldDelegate) =>
      oldDelegate.radius != radius ||
      oldDelegate.edge != edge ||
      oldDelegate.ring != ring;
}

class _ButtonBox extends StatelessWidget {
  const _ButtonBox({
    required this.radius,
    required this.fill,
    required this.shadows,
    required this.edge,
    required this.border,
    required this.ring,
    required this.lift,
    required this.scale,
    required this.opacity,
    required this.opacityDuration,
    required this.animate,
    required this.child,
  });

  final double radius;
  final Color fill;
  final List<BoxShadow> shadows;
  final Color edge;
  final Color? border;
  final Color? ring;
  final double lift;
  final double scale;
  final double opacity;
  final Duration opacityDuration;
  final bool animate;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final borderRadius = BorderRadius.circular(radius);
    final border = this.border;
    return AnimatedOpacity(
      opacity: opacity,
      duration: animate ? opacityDuration : Duration.zero,
      curve: Curves.ease,
      child: AnimatedContainer(
        duration: animate ? _liftDuration : Duration.zero,
        curve: _labEaseOut,
        transformAlignment: Alignment.center,
        transform:
            Matrix4.translationValues(0, lift, 0) *
            Matrix4.diagonal3Values(scale, scale, 1),
        child: AnimatedContainer(
          duration: animate ? _boxDuration : Duration.zero,
          curve: _labEaseOut,
          decoration: BoxDecoration(
            color: fill,
            borderRadius: borderRadius,
            boxShadow: shadows,
          ),
          foregroundDecoration: border == null
              ? null
              : BoxDecoration(
                  borderRadius: borderRadius,
                  border: Border.all(color: border, width: _borderWidth),
                ),
          child: CustomPaint(
            painter: _BoxPainter(radius: radius, edge: edge, ring: ring),
            child: child,
          ),
        ),
      ),
    );
  }
}

class ModalButton extends StatefulWidget {
  const ModalButton({
    required this.label,
    required this.kind,
    required this.onPressed,
    this.glyph,
    this.inPair = false,
    super.key,
  });

  final String label;
  final ModalButtonKind kind;
  final VoidCallback? onPressed;
  final Glyph? glyph;
  final bool inPair;

  @override
  State<ModalButton> createState() => _ModalButtonState();
}

class _ModalButtonState extends State<ModalButton> with _PressStates {
  @override
  Widget build(BuildContext context) {
    final colors = NbColors.of(context);
    final animate = !MediaQuery.disableAnimationsOf(context);
    final enabled = widget.onPressed != null;
    final look = _lookOf(colors, widget.kind, hover: hovered, enabled: enabled);
    final inPair = widget.inPair;
    final lifted = enabled && hovered && !pressed && animate;
    final squeezed = enabled && pressed && animate;
    final style = NbText.button.copyWith(
      fontSize: 14,
      height: inPair ? 1.15 : 1,
      fontVariations: [FontVariation.weight(colors.headingWeight)],
    );
    final glyph = widget.glyph;
    return _ButtonBox(
      radius: _buttonRadius,
      fill: look.fill,
      shadows: look.shadows,
      edge: look.edge,
      border: look.border,
      ring: keyboardFocused && enabled ? colors.primary : null,
      lift: lifted ? -1 : 0,
      scale: squeezed ? 0.97 : 1,
      opacity: enabled ? 1 : 0.5,
      opacityDuration: _boxDuration,
      animate: animate,
      child: TextButton(
        statesController: statesController,
        onPressed: widget.onPressed,
        style: ButtonStyle(
          backgroundColor: const WidgetStatePropertyAll(Colors.transparent),
          foregroundColor: WidgetStatePropertyAll(look.ink),
          overlayColor: const WidgetStatePropertyAll(Colors.transparent),
          shadowColor: const WidgetStatePropertyAll(Colors.transparent),
          surfaceTintColor: const WidgetStatePropertyAll(Colors.transparent),
          elevation: const WidgetStatePropertyAll(0),
          side: const WidgetStatePropertyAll(BorderSide.none),
          shape: WidgetStatePropertyAll(
            RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(_buttonRadius),
            ),
          ),
          minimumSize: const WidgetStatePropertyAll(Size.fromHeight(46)),
          padding: WidgetStatePropertyAll(
            inPair
                ? const EdgeInsets.symmetric(horizontal: 10, vertical: 8)
                : const EdgeInsets.symmetric(horizontal: 18),
          ),
          textStyle: WidgetStatePropertyAll(style),
          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
          splashFactory: NoSplash.splashFactory,
          animationDuration: animate ? _boxDuration : Duration.zero,
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            if (glyph != null) ...[
              GlyphIcon(glyph, size: 16),
              const SizedBox(width: 8),
            ],
            Flexible(
              child: Text(
                widget.label,
                textAlign: TextAlign.center,
                maxLines: inPair ? 2 : 1,
                softWrap: inPair,
                overflow: inPair ? TextOverflow.clip : TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class ChoiceTile extends StatefulWidget {
  const ChoiceTile({
    required this.title,
    required this.detail,
    required this.glyph,
    required this.neutral,
    required this.onPressed,
    this.selected = false,
    this.dimmed = false,
    this.onHover,
    super.key,
  });

  final String title;
  final String detail;
  final Glyph glyph;
  final bool neutral;
  final VoidCallback? onPressed;
  final bool selected;
  final bool dimmed;
  final ValueChanged<bool>? onHover;

  @override
  State<ChoiceTile> createState() => _ChoiceTileState();
}

class _ChoiceTileState extends State<ChoiceTile> with _PressStates {
  bool _notifiedHover = false;

  bool get _enabled => widget.onPressed != null;
  bool get _effectiveHover => _enabled && (hovered || keyboardFocused);

  @override
  void statesChanged() {
    final hover = _effectiveHover;
    if (hover == _notifiedHover) return;
    _notifiedHover = hover;
    if (_enabled) widget.onHover?.call(hover);
  }

  @override
  Widget build(BuildContext context) {
    final colors = NbColors.of(context);
    final animate = !MediaQuery.disableAnimationsOf(context);
    final enabled = _enabled;
    final hover = _effectiveHover;
    final border = widget.selected
        ? (widget.neutral ? colors.textWeak : colors.primary)
        : (hover ? colors.primary : colors.border);
    final shadows = [
      hover
          ? BoxShadow(
              color: colors.nodeShadow,
              offset: const Offset(0, 12),
              blurRadius: 24,
              spreadRadius: -12,
            )
          : BoxShadow(
              color: colors.nodeShadow,
              offset: const Offset(0, 1),
              blurRadius: 2,
            ),
    ];
    final lifted = enabled && hover && !pressed && animate;
    final squeezed = enabled && pressed && animate;
    final iconInk = widget.neutral ? colors.textWeak : colors.primaryInk;
    final titleStyle = NbText.bodyStrong.copyWith(
      height: 18 / 14,
      color: colors.text,
    );
    final detailStyle = NbText.caption.copyWith(color: colors.textWeak);
    return _ButtonBox(
      radius: _tileRadius,
      fill: colors.card,
      shadows: shadows,
      edge: colors.buttonHighlight.withValues(alpha: 0),
      border: border,
      ring: keyboardFocused && enabled ? colors.primary : null,
      lift: lifted ? -2 : 0,
      scale: squeezed ? 0.97 : 1,
      opacity: widget.dimmed ? 0.35 : (enabled ? 1 : 0.5),
      opacityDuration: widget.dimmed ? _dimDuration : _boxDuration,
      animate: animate,
      child: TextButton(
        statesController: statesController,
        onPressed: widget.onPressed,
        style: ButtonStyle(
          backgroundColor: const WidgetStatePropertyAll(Colors.transparent),
          foregroundColor: WidgetStatePropertyAll(colors.text),
          overlayColor: const WidgetStatePropertyAll(Colors.transparent),
          shadowColor: const WidgetStatePropertyAll(Colors.transparent),
          surfaceTintColor: const WidgetStatePropertyAll(Colors.transparent),
          elevation: const WidgetStatePropertyAll(0),
          side: const WidgetStatePropertyAll(BorderSide.none),
          shape: WidgetStatePropertyAll(
            RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(_tileRadius),
            ),
          ),
          minimumSize: const WidgetStatePropertyAll(Size.fromHeight(0)),
          padding: const WidgetStatePropertyAll(
            EdgeInsets.fromLTRB(12, 16, 12, 14),
          ),
          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
          splashFactory: NoSplash.splashFactory,
          animationDuration: animate ? _boxDuration : Duration.zero,
        ),
        child: Semantics(
          button: true,
          label: '${widget.title}\n${widget.detail}',
          excludeSemantics: true,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              DecoratedBox(
                decoration: BoxDecoration(
                  color: widget.neutral
                      ? colors.neutralWeak
                      : colors.primaryWeak,
                  borderRadius: BorderRadius.circular(12),
                  border: widget.neutral
                      ? Border.all(color: colors.border)
                      : null,
                ),
                child: SizedBox.square(
                  dimension: 40,
                  child: Center(
                    child: GlyphIcon(widget.glyph, size: 22, color: iconInk),
                  ),
                ),
              ),
              const SizedBox(height: 6),
              Text(
                widget.title,
                textAlign: TextAlign.center,
                style: titleStyle,
              ),
              const SizedBox(height: 6),
              Text(
                widget.detail,
                textAlign: TextAlign.center,
                style: detailStyle,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
