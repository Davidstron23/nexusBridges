import 'package:flutter/material.dart';

import '../../app_controller.dart';
import '../../l10n/app_strings.dart';
import '../icons/glyphs.dart';
import 'segmented_choice.dart';
import 'settings_section.dart';

class LanguageSection extends StatelessWidget {
  const LanguageSection({required this.controller, super.key});

  final AppController controller;

  @override
  Widget build(BuildContext context) {
    final strings = AppStringsDelegate.of(context);
    return SettingsSection(
      icon: Glyphs.globe,
      title: strings.sectionLanguage,
      child: ListenableBuilder(
        listenable: controller,
        builder: (context, _) => Padding(
          padding: const EdgeInsets.symmetric(horizontal: 15),
          child: SegmentedChoice<String>(
            value: controller.languageCode,
            onChanged: controller.setLanguage,
            options: [
              SegmentOption(value: 'es', label: strings.languageSpanish),
              SegmentOption(value: 'en', label: strings.languageEnglish),
            ],
          ),
        ),
      ),
    );
  }
}
