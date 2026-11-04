import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../icons/glyphs.dart';
import '../modal/timeline.dart';
import '../theme/app_theme.dart';
import '../theme/tokens.dart';
import 'state_blend.dart';

const double settingsFieldHeight = 36;
const Duration _messageGrow = Duration(milliseconds: 420);
const Duration _messageFade = Duration(milliseconds: 360);
const Duration _fieldFade = Duration(milliseconds: 300);

class SettingsTextField extends StatefulWidget {
  const SettingsTextField({
    required this.controller,
    required this.label,
    this.hint,
    this.invalid = false,
    this.maxLength,
    this.onChanged,
    this.onSubmit,
    this.focusNode,
    super.key,
  });

  final TextEditingController controller;
  final String label;
  final String? hint;
  final bool invalid;
  final int? maxLength;
  final ValueChanged<String>? onChanged;
  final VoidCallback? onSubmit;
  final FocusNode? focusNode;

  @override
  State<SettingsTextField> createState() => _SettingsTextFieldState();
}

class _SettingsTextFieldState extends State<SettingsTextField> {
  FocusNode? _own;

  FocusNode get _focus => widget.focusNode ?? (_own ??= FocusNode());

  @override
  void initState() {
    super.initState();
    _focus.addListener(_onFocus);
  }

  @override
  void didUpdateWidget(SettingsTextField oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.focusNode == widget.focusNode) return;
    (oldWidget.focusNode ?? _own)?.removeListener(_onFocus);
    _focus.addListener(_onFocus);
  }

  @override
  void dispose() {
    _focus.removeListener(_onFocus);
    _own?.dispose();
    super.dispose();
  }

  void _onFocus() => setState(() {});

  @override
  Widget build(BuildContext context) {
    final colors = NbColors.of(context);
    final animate = !MediaQuery.disableAnimationsOf(context);
    final active = widget.invalid || _focus.hasFocus;
    final activeColor = widget.invalid ? colors.danger : colors.primary;
    final ringColor = widget.invalid ? colors.dangerWeak : colors.primaryWeak;
    final maxLength = widget.maxLength;
    final field = Semantics(
      label: widget.label,
      textField: true,
      child: TextField(
        controller: widget.controller,
        focusNode: _focus,
        maxLines: 1,
        style: NbText.body.copyWith(color: colors.text),
        cursorColor: colors.primary,
        textInputAction: TextInputAction.done,
        inputFormatters: [
          if (maxLength != null) LengthLimitingTextInputFormatter(maxLength),
        ],
        decoration: InputDecoration.collapsed(
          hintText: widget.hint,
          hintStyle: NbText.body.copyWith(color: colors.hint),
        ),
        onChanged: widget.onChanged,
        onEditingComplete: widget.onSubmit,
      ),
    );
    return StateBlend(
      on: active,
      duration: animate ? _fieldFade : Duration.zero,
      curve: labEaseOut,
      builder: (context, t) => DecoratedBox(
        decoration: BoxDecoration(
          color: colors.ground,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(
            color: Color.lerp(colors.border, activeColor, t)!,
            strokeAlign: BorderSide.strokeAlignInside,
          ),
          boxShadow: t <= 0
              ? const []
              : [
                  BoxShadow(
                    color: Color.lerp(ringColor.withAlpha(0), ringColor, t)!,
                    spreadRadius: 3,
                  ),
                ],
        ),
        child: SizedBox(
          height: settingsFieldHeight,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Align(alignment: Alignment.centerLeft, child: field),
          ),
        ),
      ),
    );
  }
}

enum SettingsMessageTone { neutral, error }

class SettingsMessage extends StatefulWidget {
  const SettingsMessage({
    required this.text,
    this.tone = SettingsMessageTone.neutral,
    super.key,
  });

  final String? text;
  final SettingsMessageTone tone;

  @override
  State<SettingsMessage> createState() => _SettingsMessageState();
}

class _SettingsMessageState extends State<SettingsMessage> {
  String _last = '';
  SettingsMessageTone _lastTone = SettingsMessageTone.neutral;

  @override
  Widget build(BuildContext context) {
    final colors = NbColors.of(context);
    final animate = !MediaQuery.disableAnimationsOf(context);
    final text = widget.text;
    if (text != null) {
      _last = text;
      _lastTone = widget.tone;
    }
    final open = text != null;
    final error = _lastTone == SettingsMessageTone.error;
    final ink = error ? colors.danger : colors.textWeak;
    final row = Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 1),
            child: GlyphIcon(
              error ? Glyphs.warn : Glyphs.info,
              size: 14,
              color: ink,
            ),
          ),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              _last,
              style: NbText.caption.copyWith(color: ink, height: 16 / 12),
            ),
          ),
        ],
      ),
    );
    return AnimatedSize(
      duration: animate ? _messageGrow : Duration.zero,
      curve: labEaseOut,
      alignment: Alignment.topCenter,
      child: AnimatedOpacity(
        opacity: open ? 1 : 0,
        duration: animate ? _messageFade : Duration.zero,
        curve: labEaseOut,
        child: open
            ? Semantics(liveRegion: true, child: row)
            : const SizedBox(width: double.infinity, height: 0),
      ),
    );
  }
}

class SettingsLink extends StatelessWidget {
  const SettingsLink({
    required this.glyph,
    required this.label,
    required this.onPressed,
    super.key,
  });

  final Glyph glyph;
  final String label;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    final colors = NbColors.of(context);
    final style = smallButton.merge(
      ButtonStyle(
        padding: const WidgetStatePropertyAll(
          EdgeInsets.symmetric(horizontal: 8),
        ),
        textStyle: WidgetStatePropertyAll(
          NbText.button.copyWith(fontSize: 12.5),
        ),
        backgroundColor: WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.disabled)) return Colors.transparent;
          if (states.contains(WidgetState.hovered)) return colors.primaryWeak;
          return Colors.transparent;
        }),
        foregroundColor: WidgetStateProperty.resolveWith(
          (states) => states.contains(WidgetState.disabled)
              ? colors.hint
              : colors.primaryInk,
        ),
      ),
    );
    return Align(
      alignment: Alignment.centerLeft,
      child: Transform.translate(
        offset: const Offset(-8, 0),
        child: TextButton.icon(
          style: style,
          onPressed: onPressed,
          icon: GlyphIcon(glyph, size: 14),
          label: Text(label),
        ),
      ),
    );
  }
}

class RoundIconButton extends StatefulWidget {
  const RoundIconButton({
    required this.glyph,
    required this.label,
    required this.onPressed,
    this.size = 22,
    this.glyphSize = 12,
    super.key,
  });

  final Glyph glyph;
  final String label;
  final VoidCallback onPressed;
  final double size;
  final double glyphSize;

  @override
  State<RoundIconButton> createState() => _RoundIconButtonState();
}

class _RoundIconButtonState extends State<RoundIconButton> {
  bool _hovered = false;
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    final colors = NbColors.of(context);
    final animate = !MediaQuery.disableAnimationsOf(context);
    return Semantics(
      button: true,
      label: widget.label,
      excludeSemantics: true,
      onTap: widget.onPressed,
      child: FocusableActionDetector(
        mouseCursor: SystemMouseCursors.click,
        onShowHoverHighlight: (value) => setState(() => _hovered = value),
        onShowFocusHighlight: (value) => setState(() => _focused = value),
        actions: {
          ActivateIntent: CallbackAction<ActivateIntent>(
            onInvoke: (_) {
              widget.onPressed();
              return null;
            },
          ),
        },
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: widget.onPressed,
          child: AnimatedContainer(
            duration: animate
                ? const Duration(milliseconds: 200)
                : Duration.zero,
            width: widget.size,
            height: widget.size,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: _hovered ? colors.dangerWeak : Colors.transparent,
              border: _focused
                  ? Border.all(color: colors.primary, width: 2)
                  : null,
            ),
            child: Center(
              child: GlyphIcon(
                widget.glyph,
                size: widget.glyphSize,
                color: _hovered ? colors.danger : colors.textWeak,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

List<InlineSpan> leadSentenceBold(String text, TextStyle bold) {
  final cut = text.indexOf('? ');
  if (cut < 0) return [TextSpan(text: text)];
  return [
    TextSpan(text: text.substring(0, cut + 1), style: bold),
    TextSpan(text: text.substring(cut + 1)),
  ];
}
