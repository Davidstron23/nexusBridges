import 'package:flutter/material.dart';

import '../icons/glyphs.dart';
import '../modal/timeline.dart' show labEaseOut;
import '../theme/app_theme.dart';
import '../theme/tokens.dart';
import 'keyboard_navigation.dart';

enum LabButtonKind { primary, quiet, ghost }

const Duration _labButtonMotion = Duration(milliseconds: 250);
const double _labButtonHeight = 28;
const double _labButtonRadius = 8;

class LabButton extends StatefulWidget {
  const LabButton({
    required this.label,
    required this.kind,
    required this.onPressed,
    this.glyph,
    this.glyphSize = 14,
    this.padding = const EdgeInsets.symmetric(horizontal: 10),
    this.gap = 6,
    this.expand = false,
    super.key,
  });

  final String label;
  final LabButtonKind kind;
  final VoidCallback? onPressed;
  final Glyph? glyph;
  final double glyphSize;
  final EdgeInsets padding;
  final double gap;
  final bool expand;

  @override
  State<LabButton> createState() => _LabButtonState();
}

class _LabButtonState extends State<LabButton> {
  bool _hovered = false;
  bool _focused = false;

  @override
  void initState() {
    super.initState();
    ensureKeyboardNavigation();
  }

  @override
  Widget build(BuildContext context) {
    final colors = NbColors.of(context);
    final animate = !MediaQuery.disableAnimationsOf(context);
    final enabled = widget.onPressed != null;
    final primary = widget.kind == LabButtonKind.primary;
    final duration = animate ? _labButtonMotion : Duration.zero;
    return ValueListenableBuilder<bool>(
      valueListenable: keyboardNavigation,
      builder: (context, keyboard, _) {
        final lit = enabled && (_hovered || (_focused && keyboard));
        final ghost = widget.kind == LabButtonKind.ghost;
        final idle = ghost ? colors.primaryWeak : colors.controlHover;
        final fill = primary
            ? (lit ? colors.primaryButtonHover : colors.primaryButton)
            : (lit ? idle : idle.withValues(alpha: 0));
        final ink = primary
            ? colors.onPrimary
            : ghost
            ? colors.primaryInk
            : (lit ? colors.text : colors.textWeak);
        final glyph = widget.glyph;
        return Semantics(
          button: true,
          enabled: enabled,
          label: widget.label,
          excludeSemantics: true,
          child: FocusableActionDetector(
            enabled: enabled,
            mouseCursor: enabled
                ? SystemMouseCursors.click
                : SystemMouseCursors.basic,
            onShowHoverHighlight: (value) => setState(() => _hovered = value),
            onFocusChange: (value) => setState(() => _focused = value),
            actions: {
              ActivateIntent: CallbackAction<ActivateIntent>(
                onInvoke: (_) {
                  widget.onPressed?.call();
                  return null;
                },
              ),
            },
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: widget.onPressed,
              child: AnimatedOpacity(
                opacity: enabled ? 1 : 0.5,
                duration: duration,
                child: AnimatedSlide(
                  offset: Offset(
                    0,
                    primary && lit && animate ? -1 / _labButtonHeight : 0,
                  ),
                  duration: duration,
                  curve: labEaseOut,
                  child: AnimatedContainer(
                    height: _labButtonHeight,
                    duration: duration,
                    curve: labEaseOut,
                    padding: widget.padding,
                    decoration: BoxDecoration(
                      color: fill,
                      borderRadius: BorderRadius.circular(_labButtonRadius),
                      border: _focused && keyboard
                          ? Border.all(color: colors.primary, width: 2)
                          : null,
                      boxShadow: primary
                          ? (lit ? labButtonHoverShadow : labButtonRestShadow)
                          : labButtonNoShadow,
                    ),
                    child: Row(
                      mainAxisSize: widget.expand
                          ? MainAxisSize.max
                          : MainAxisSize.min,
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        if (glyph != null) ...[
                          GlyphIcon(glyph, size: widget.glyphSize, color: ink),
                          SizedBox(width: widget.gap),
                        ],
                        Text(
                          widget.label,
                          maxLines: 1,
                          style: NbText.button.copyWith(color: ink),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}
