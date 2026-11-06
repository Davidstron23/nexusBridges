import 'package:flutter/material.dart';

import '../icons/glyphs.dart';
import '../modal/timeline.dart';
import '../settings/settings_section.dart';
import '../theme/app_theme.dart';
import '../theme/tokens.dart';

const double configureSectionIcon = 22;
const Duration _pauseFade = Duration(milliseconds: 420);
const Duration _dangerGlow = Duration(milliseconds: 320);

class ConfigureStagger extends StatelessWidget {
  const ConfigureStagger({
    required this.animation,
    required this.index,
    required this.child,
    super.key,
  });

  final Animation<double> animation;
  final int index;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final start = ((index * 45 + 140) / 1000).clamp(0.0, 0.8);
    final curved = CurvedAnimation(
      parent: animation,
      curve: Interval(start, 1, curve: labEaseOut),
    );
    return AnimatedBuilder(
      animation: curved,
      child: child,
      builder: (context, child) => Opacity(
        opacity: curved.value,
        child: Transform.translate(
          offset: Offset(0, 12 * (1 - curved.value)),
          child: child,
        ),
      ),
    );
  }
}

class ConfigureSection extends StatelessWidget {
  const ConfigureSection({
    required this.icon,
    required this.title,
    required this.child,
    this.first = false,
    this.info,
    this.count,
    this.description,
    this.action,
    this.paused = false,
    this.pauseNote,
    super.key,
  });

  final Glyph icon;
  final String title;
  final Widget child;
  final bool first;
  final String? info;
  final String? count;
  final String? description;
  final Widget? action;
  final bool paused;
  final String? pauseNote;

  @override
  Widget build(BuildContext context) {
    final colors = NbColors.of(context);
    final animate = !MediaQuery.disableAnimationsOf(context);
    final description = this.description;
    final info = this.info;
    final count = this.count;
    final pauseNote = this.pauseNote;
    return Semantics(
      container: true,
      explicitChildNodes: true,
      label: title,
      child: DecoratedBox(
        decoration: BoxDecoration(
          border: first
              ? null
              : Border(top: BorderSide(color: colors.borderWeak)),
        ),
        child: Padding(
          padding: EdgeInsets.fromLTRB(0, first ? 18 : 32, 0, 4),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  GlyphIcon(
                    icon,
                    size: configureSectionIcon,
                    color: colors.textWeak,
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Row(
                      children: [
                        Flexible(
                          child: Text(
                            title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: NbText.bodyStrong.copyWith(
                              color: colors.text,
                              height: 20 / 14,
                              fontVariations: [
                                FontVariation.weight(colors.headingWeight),
                              ],
                            ),
                          ),
                        ),
                        if (info != null) ...[
                          const SizedBox(width: 6),
                          InfoButton(text: info),
                        ],
                      ],
                    ),
                  ),
                  if (count != null)
                    Text(
                      count,
                      style: NbText.caption.copyWith(
                        color: colors.textWeak,
                        fontFeatures: const [FontFeature.tabularFigures()],
                      ),
                    ),
                  ?action,
                ],
              ),
              if (description != null) ...[
                const SizedBox(height: 8),
                Text(
                  description,
                  style: NbText.caption.copyWith(
                    color: colors.textWeak,
                    fontSize: 12.5,
                    height: 18 / 12.5,
                  ),
                ),
              ],
              if (pauseNote != null) ...[
                const SizedBox(height: 12),
                _GrowNote(open: paused, text: pauseNote),
              ] else
                const SizedBox(height: 12),
              AnimatedOpacity(
                opacity: paused ? 0.42 : 1,
                duration: animate ? _pauseFade : Duration.zero,
                curve: labEaseOut,
                child: IgnorePointer(ignoring: paused, child: child),
              ),
              const SizedBox(height: 14),
            ],
          ),
        ),
      ),
    );
  }
}

class _GrowNote extends StatelessWidget {
  const _GrowNote({required this.open, required this.text});

  final bool open;
  final String text;

  @override
  Widget build(BuildContext context) {
    final colors = NbColors.of(context);
    final animate = !MediaQuery.disableAnimationsOf(context);
    return TweenAnimationBuilder<double>(
      tween: Tween<double>(end: open ? 1 : 0),
      duration: animate ? _pauseFade : Duration.zero,
      curve: labEaseOut,
      builder: (context, t, child) {
        if (t <= 0) return const SizedBox(width: double.infinity);
        return ClipRect(
          child: Align(
            alignment: Alignment.topCenter,
            heightFactor: t,
            child: Opacity(opacity: t, child: child),
          ),
        );
      },
      child: Padding(
        padding: const EdgeInsets.only(bottom: 10),
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: colors.surfaceWeak,
            borderRadius: BorderRadius.circular(10),
          ),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: const EdgeInsets.only(top: 1),
                  child: GlyphIcon(
                    Glyphs.info,
                    size: 16,
                    color: colors.textWeak,
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    text,
                    style: NbText.caption.copyWith(
                      color: colors.textWeak,
                      fontSize: 12.5,
                      height: 18 / 12.5,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class ConfigureOption extends StatefulWidget {
  const ConfigureOption({
    required this.glyph,
    required this.label,
    required this.help,
    required this.selected,
    required this.onTap,
    super.key,
  });

  final Glyph glyph;
  final String label;
  final String help;
  final bool selected;
  final VoidCallback onTap;

  @override
  State<ConfigureOption> createState() => _ConfigureOptionState();
}

class _ConfigureOptionState extends State<ConfigureOption> {
  bool _hovered = false;
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    final colors = NbColors.of(context);
    final animate = !MediaQuery.disableAnimationsOf(context);
    final selected = widget.selected;
    final duration = animate
        ? const Duration(milliseconds: 380)
        : Duration.zero;
    final ringColor = selected
        ? colors.primary
        : (_hovered ? colors.hint : colors.border);
    return Semantics(
      button: true,
      selected: selected,
      label: widget.label,
      hint: widget.help,
      excludeSemantics: true,
      child: FocusableActionDetector(
        mouseCursor: SystemMouseCursors.click,
        onShowHoverHighlight: (value) => setState(() => _hovered = value),
        onShowFocusHighlight: (value) => setState(() => _focused = value),
        actions: {
          ActivateIntent: CallbackAction<ActivateIntent>(
            onInvoke: (_) {
              widget.onTap();
              return null;
            },
          ),
        },
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: widget.onTap,
          child: AnimatedContainer(
            duration: duration,
            curve: labEaseOut,
            padding: const EdgeInsets.fromLTRB(14, 14, 12, 14),
            decoration: BoxDecoration(
              color: selected
                  ? colors.primaryWeak
                  : Color.lerp(colors.card, colors.surfaceWeak, 0.35),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(
                color: _focused ? colors.primary : ringColor,
                width: selected || _focused ? 1.5 : 1,
                strokeAlign: BorderSide.strokeAlignInside,
              ),
            ),
            child: Stack(
              children: [
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Padding(
                      padding: const EdgeInsets.only(right: 22),
                      child: Row(
                        children: [
                          GlyphIcon(
                            widget.glyph,
                            size: 20,
                            color: selected
                                ? colors.primaryInk
                                : colors.textWeak,
                          ),
                          const SizedBox(width: 8),
                          Flexible(
                            child: Text(
                              widget.label,
                              style: NbText.bodySm.copyWith(
                                color: colors.text,
                                fontWeight: FontWeight.w600,
                                fontSize: 13.5,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      widget.help,
                      style: NbText.caption.copyWith(
                        color: colors.textWeak,
                        height: 16 / 12,
                      ),
                    ),
                  ],
                ),
                Positioned(
                  right: 0,
                  top: 0,
                  child: AnimatedScale(
                    scale: selected ? 1 : 0,
                    duration: animate
                        ? const Duration(milliseconds: 420)
                        : Duration.zero,
                    curve: const Cubic(0.2, 0.8, 0.2, 1),
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: colors.primaryButton,
                      ),
                      child: SizedBox.square(
                        dimension: 18,
                        child: Center(
                          child: GlyphIcon(
                            Glyphs.tick,
                            size: 10,
                            color: colors.onPrimary,
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class ConfigureDangerButton extends StatefulWidget {
  const ConfigureDangerButton({
    required this.label,
    required this.onPressed,
    super.key,
  });

  final String label;
  final VoidCallback onPressed;

  @override
  State<ConfigureDangerButton> createState() => _ConfigureDangerButtonState();
}

class _ConfigureDangerButtonState extends State<ConfigureDangerButton> {
  final WidgetStatesController _states = WidgetStatesController();
  bool _lit = false;

  @override
  void initState() {
    super.initState();
    _states.addListener(_onStates);
  }

  @override
  void dispose() {
    _states.removeListener(_onStates);
    _states.dispose();
    super.dispose();
  }

  void _onStates() {
    final states = _states.value;
    final lit =
        states.contains(WidgetState.hovered) ||
        states.contains(WidgetState.pressed) ||
        states.contains(WidgetState.focused);
    if (lit != _lit) setState(() => _lit = lit);
  }

  @override
  Widget build(BuildContext context) {
    final colors = NbColors.of(context);
    final animate = !MediaQuery.disableAnimationsOf(context);
    return RepaintBoundary(
      child: TweenAnimationBuilder<double>(
        tween: Tween(end: _lit ? 1 : 0),
        duration: animate ? _dangerGlow : Duration.zero,
        curve: labEaseOut,
        builder: (context, glow, _) {
          final ink = Color.lerp(colors.danger, colors.onPrimary, glow)!;
          return FilledButton.icon(
            statesController: _states,
            style: FilledButton.styleFrom(
              backgroundColor: Color.lerp(
                colors.dangerWeak,
                colors.dangerFill,
                glow,
              ),
              foregroundColor: ink,
              iconColor: ink,
              animationDuration: Duration.zero,
              overlayColor: Colors.transparent,
              splashFactory: NoSplash.splashFactory,
            ),
            onPressed: widget.onPressed,
            icon: GlyphIcon(Glyphs.unlink, size: 16, color: ink),
            label: Text(
              widget.label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          );
        },
      ),
    );
  }
}

class ConfigureDangerZone extends StatelessWidget {
  const ConfigureDangerZone({
    required this.help,
    required this.button,
    super.key,
  });

  final String help;
  final Widget button;

  @override
  Widget build(BuildContext context) {
    final colors = NbColors.of(context);
    return DecoratedBox(
      decoration: BoxDecoration(
        color: Color.lerp(colors.card, colors.surfaceWeak, 0.35),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: colors.borderWeak,
          strokeAlign: BorderSide.strokeAlignInside,
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              help,
              style: NbText.caption.copyWith(
                color: colors.textWeak,
                fontSize: 12.5,
                height: 18 / 12.5,
              ),
            ),
            const SizedBox(height: 12),
            button,
          ],
        ),
      ),
    );
  }
}
