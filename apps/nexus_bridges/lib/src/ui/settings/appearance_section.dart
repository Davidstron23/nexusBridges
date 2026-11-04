import 'package:flutter/material.dart';
import 'package:nexus_bridges_core/nexus_bridges_core.dart' show ThemeChoice;

import '../../app_controller.dart';
import '../../l10n/app_strings.dart';
import '../icons/glyphs.dart';
import 'segmented_choice.dart';
import 'settings_section.dart';

class AppearanceSection extends StatelessWidget {
  const AppearanceSection({required this.controller, super.key});

  final AppController controller;

  @override
  Widget build(BuildContext context) {
    final strings = AppStringsDelegate.of(context);
    return SettingsSection(
      icon: Glyphs.moon,
      title: strings.sectionAppearance,
      info: strings.appearanceInfo,
      child: ListenableBuilder(
        listenable: controller,
        builder: (context, _) => Padding(
          padding: const EdgeInsets.symmetric(horizontal: 15),
          child: SegmentedChoice<ThemeChoice>(
            value: controller.theme,
            onChanged: controller.setTheme,
            options: [
              SegmentOption(
                value: ThemeChoice.dark,
                label: strings.themeDark,
                icon: Glyphs.moon,
              ),
              SegmentOption(
                value: ThemeChoice.light,
                label: strings.themeLight,
                icon: Glyphs.sun,
              ),
              SegmentOption(
                value: ThemeChoice.system,
                label: strings.themeWindows,
                icon: Glyphs.auto,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
