import 'package:flutter/material.dart';

import '../../l10n/app_strings.dart';
import '../icons/glyphs.dart';
import '../theme/app_theme.dart';
import '../theme/tokens.dart';

const double settingsCardRadius = 14;
const EdgeInsets settingsCardPadding = EdgeInsets.symmetric(
  horizontal: 24,
  vertical: 22,
);
const double settingsIconSize = 24;
const double _infoSize = 22;
const double _infoGlyph = 16;
const double _tooltipMaxWidth = 320;

class SettingsSection extends StatelessWidget {
  const SettingsSection({
    required this.icon,
    required this.title,
    required this.child,
    this.info,
    this.count,
    this.description,
    super.key,
  });

  final Glyph icon;
  final String title;
  final Widget child;
  final String? info;
  final String? count;
  final String? description;

  @override
  Widget build(BuildContext context) {
    final colors = NbColors.of(context);
    final description = this.description;
    final info = this.info;
    final count = this.count;
    return Semantics(
      container: true,
      explicitChildNodes: true,
      label: title,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: colors.card,
          borderRadius: BorderRadius.circular(settingsCardRadius),
          boxShadow: colors.cardShadow,
        ),
        child: Padding(
          padding: settingsCardPadding,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  GlyphIcon(
                    icon,
                    size: settingsIconSize,
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
                  if (count != null) ...[
                    const SizedBox(width: 12),
                    Text(
                      count,
                      style: NbText.caption.copyWith(
                        color: colors.textWeak,
                        fontSize: 12.5,
                      ),
                    ),
                  ],
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
              const SizedBox(height: 12),
              child,
            ],
          ),
        ),
      ),
    );
  }
}

class InfoButton extends StatefulWidget {
  const InfoButton({required this.text, super.key});

  final String text;

  @override
  State<InfoButton> createState() => _InfoButtonState();
}

class _InfoButtonState extends State<InfoButton> {
  final GlobalKey<TooltipState> _tooltip = GlobalKey<TooltipState>();
  bool _hovered = false;
  bool _focused = false;

  void _show() => _tooltip.currentState?.ensureTooltipVisible();

  @override
  Widget build(BuildContext context) {
    final colors = NbColors.of(context);
    final strings = AppStringsDelegate.of(context);
    final theme = Theme.of(context).tooltipTheme;
    final lit = _hovered || _focused;
    return TooltipTheme(
      data: theme.copyWith(
        constraints: const BoxConstraints(maxWidth: _tooltipMaxWidth),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        waitDuration: const Duration(milliseconds: 200),
        triggerMode: TooltipTriggerMode.manual,
      ),
      child: Tooltip(
        key: _tooltip,
        message: widget.text,
        child: Semantics(
          button: true,
          label: strings.moreInfo(widget.text),
          excludeSemantics: true,
          onTap: _show,
          child: FocusableActionDetector(
            mouseCursor: SystemMouseCursors.help,
            onShowHoverHighlight: (value) => setState(() => _hovered = value),
            onShowFocusHighlight: (value) => setState(() => _focused = value),
            actions: {
              ActivateIntent: CallbackAction<ActivateIntent>(
                onInvoke: (_) {
                  _show();
                  return null;
                },
              ),
            },
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: _show,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: lit ? colors.controlHover : Colors.transparent,
                  border: _focused
                      ? Border.all(color: colors.primary, width: 2)
                      : null,
                ),
                child: SizedBox.square(
                  dimension: _infoSize,
                  child: Center(
                    child: GlyphIcon(
                      Glyphs.info,
                      size: _infoGlyph,
                      color: lit ? colors.text : colors.hint,
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class SettingsWell extends StatelessWidget {
  const SettingsWell({required this.child, super.key});

  final Widget child;

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
      child: ClipRRect(borderRadius: BorderRadius.circular(12), child: child),
    );
  }
}

class SettingsRow extends StatelessWidget {
  const SettingsRow({
    required this.title,
    this.leading,
    this.subtitle,
    this.trailing,
    this.divider = false,
    super.key,
  });

  final Widget? leading;
  final String title;
  final String? subtitle;
  final Widget? trailing;
  final bool divider;

  @override
  Widget build(BuildContext context) {
    final colors = NbColors.of(context);
    final subtitle = this.subtitle;
    final leading = this.leading;
    final trailing = this.trailing;
    return DecoratedBox(
      decoration: BoxDecoration(
        border: divider
            ? Border(top: BorderSide(color: colors.borderWeak))
            : null,
      ),
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: 64),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(18, 14, 16, 14),
          child: SizedBox(
            width: double.infinity,
            child: Wrap(
              alignment: WrapAlignment.spaceBetween,
              runAlignment: WrapAlignment.center,
              crossAxisAlignment: WrapCrossAlignment.center,
              runSpacing: 8,
              spacing: 14,
              children: [
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (leading != null) ...[
                      leading,
                      const SizedBox(width: 14),
                    ],
                    Flexible(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: NbText.bodyStrong.copyWith(
                              color: colors.text,
                              fontSize: 13.5,
                              height: 18 / 13.5,
                              fontVariations: [
                                FontVariation.weight(colors.headingWeight),
                              ],
                            ),
                          ),
                          if (subtitle != null)
                            Padding(
                              padding: const EdgeInsets.only(top: 1),
                              child: Text(
                                subtitle,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: NbText.caption.copyWith(
                                  color: colors.textWeak,
                                ),
                              ),
                            ),
                        ],
                      ),
                    ),
                  ],
                ),
                ?trailing,
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class SettingsEmpty extends StatelessWidget {
  const SettingsEmpty({required this.text, super.key});

  final String text;

  @override
  Widget build(BuildContext context) {
    final colors = NbColors.of(context);
    return SettingsWell(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(18, 16, 16, 16),
        child: Align(
          alignment: Alignment.centerLeft,
          child: Text(
            text,
            style: NbText.caption.copyWith(color: colors.textWeak),
          ),
        ),
      ),
    );
  }
}
