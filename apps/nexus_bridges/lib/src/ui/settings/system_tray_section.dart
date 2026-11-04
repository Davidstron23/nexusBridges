import 'dart:async';

import 'package:flutter/material.dart';

import '../../app_controller.dart';
import '../../l10n/app_strings.dart';
import '../icons/glyphs.dart';
import '../modal/timeline.dart';
import '../theme/app_theme.dart';
import '../theme/tokens.dart';
import 'settings_section.dart';
import 'state_blend.dart';

const Duration _switchSlide = Duration(milliseconds: 420);
const Duration _switchFill = Duration(milliseconds: 380);
const Cubic _pop = Cubic(0.2, 0.8, 0.2, 1);

class SystemTraySection extends StatelessWidget {
  const SystemTraySection({required this.controller, super.key});

  final AppController controller;

  @override
  Widget build(BuildContext context) {
    final strings = AppStringsDelegate.of(context);
    final colors = NbColors.of(context);
    return SettingsSection(
      icon: Glyphs.taskbar,
      title: strings.sectionSystemTray,
      info: strings.systemTrayInfo,
      child: ListenableBuilder(
        listenable: controller,
        builder: (context, _) {
          final on = controller.closeToTray;
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          strings.systemTraySwitch,
                          style: NbText.bodyStrong.copyWith(
                            color: colors.text,
                            fontSize: 13.5,
                            fontVariations: [
                              FontVariation.weight(colors.headingWeight),
                            ],
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          strings.systemTraySwitchHelp,
                          style: NbText.caption.copyWith(
                            color: colors.textWeak,
                            height: 17 / 12,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 24),
                  SettingsSwitch(
                    value: on,
                    label: strings.systemTraySwitch,
                    onChanged: (value) =>
                        unawaited(controller.setCloseToTray(value)),
                  ),
                ],
              ),
              AnimatedSize(
                duration: MediaQuery.disableAnimationsOf(context)
                    ? Duration.zero
                    : const Duration(milliseconds: 420),
                curve: labEaseOut,
                alignment: Alignment.topCenter,
                child: on
                    ? const SizedBox(width: double.infinity)
                    : Padding(
                        padding: const EdgeInsets.only(top: 8),
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Padding(
                              padding: const EdgeInsets.only(top: 1),
                              child: GlyphIcon(
                                Glyphs.info,
                                size: 14,
                                color: colors.textWeak,
                              ),
                            ),
                            const SizedBox(width: 6),
                            Expanded(
                              child: Text(
                                strings.systemTrayOffHelp,
                                style: NbText.caption.copyWith(
                                  color: colors.textWeak,
                                  height: 16 / 12,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
              ),
            ],
          );
        },
      ),
    );
  }
}

class SettingsSwitch extends StatefulWidget {
  const SettingsSwitch({
    required this.value,
    required this.label,
    required this.onChanged,
    super.key,
  });

  final bool value;
  final String label;
  final ValueChanged<bool>? onChanged;

  @override
  State<SettingsSwitch> createState() => _SettingsSwitchState();
}

class _SettingsSwitchState extends State<SettingsSwitch> {
  bool _focused = false;

  void _toggle() => widget.onChanged?.call(!widget.value);

  @override
  Widget build(BuildContext context) {
    final colors = NbColors.of(context);
    final animate = !MediaQuery.disableAnimationsOf(context);
    final value = widget.value;
    final enabled = widget.onChanged != null;
    final thumb = AnimatedAlign(
      duration: animate ? _switchSlide : Duration.zero,
      curve: _pop,
      alignment: value ? Alignment.centerRight : Alignment.centerLeft,
      child: Padding(
        padding: const EdgeInsets.all(3),
        child: DecoratedBox(
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: value ? colors.onPrimary : colors.textWeak,
          ),
          child: const SizedBox.square(dimension: 16),
        ),
      ),
    );
    final track = StateBlend(
      on: value,
      duration: animate ? _switchFill : Duration.zero,
      curve: labEaseOut,
      builder: (context, t) => Container(
        width: 40,
        height: 22,
        decoration: BoxDecoration(
          color: Color.lerp(colors.track, colors.primaryButton, t),
          borderRadius: BorderRadius.circular(11),
          border: t >= 1
              ? null
              : Border.all(color: colors.border, width: 1 - t),
          boxShadow: _focused
              ? [
                  BoxShadow(color: colors.primary, spreadRadius: 4),
                  BoxShadow(color: colors.card, spreadRadius: 2),
                ]
              : const [],
        ),
        child: thumb,
      ),
    );
    return Semantics(
      toggled: value,
      enabled: enabled,
      focusable: enabled,
      focused: _focused,
      label: widget.label,
      excludeSemantics: true,
      onTap: enabled ? _toggle : null,
      child: Opacity(
        opacity: enabled ? 1 : 0.5,
        child: FocusableActionDetector(
          enabled: enabled,
          mouseCursor: enabled
              ? SystemMouseCursors.click
              : SystemMouseCursors.basic,
          onShowFocusHighlight: (value) => setState(() => _focused = value),
          actions: {
            ActivateIntent: CallbackAction<ActivateIntent>(
              onInvoke: (_) {
                _toggle();
                return null;
              },
            ),
          },
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: enabled ? _toggle : null,
            child: track,
          ),
        ),
      ),
    );
  }
}
