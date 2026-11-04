import 'dart:async';

import 'package:flutter/material.dart';
import 'package:nexus_bridges_core/nexus_bridges_core.dart';

import '../../app_controller.dart';
import '../../l10n/app_strings.dart';
import '../format.dart';
import '../icons/device_disc.dart';
import '../icons/glyphs.dart';
import '../theme/app_theme.dart';
import 'settings_rows.dart';
import 'settings_section.dart';

class IgnoredSection extends StatelessWidget {
  const IgnoredSection({required this.controller, super.key});

  final AppController controller;

  Widget _row(BuildContext context, IgnoredDeviceView device, int index) {
    final strings = AppStringsDelegate.of(context);
    final date = formatShortDate(
      device.ignoredAt,
      controller.languageCode,
      strings,
    );
    return SettingsRow(
      key: ValueKey('ignored-${device.fingerprint}'),
      divider: index > 0,
      leading: const DeviceDisc(
        type: null,
        size: 32,
        tone: DiscTone.notVisible,
      ),
      title: device.name.isEmpty ? device.shortFingerprint : device.name,
      subtitle:
          '${strings.fingerprintLine(device.shortFingerprint)} · '
          '${strings.ignoredOn(date)}',
      trailing: OutlinedButton(
        onPressed: () => unawaited(controller.unignore(device.fingerprint)),
        style: smallButton,
        child: Text(strings.unignoreButton),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final strings = AppStringsDelegate.of(context);
    return SettingsSection(
      icon: Glyphs.eyeOff,
      title: strings.sectionIgnored,
      description: strings.ignoredInfo,
      child: ListenableBuilder(
        listenable: controller,
        builder: (context, _) => SettingsRowList<IgnoredDeviceView>(
          items: controller.state?.ignoredDevices ?? const [],
          idOf: (device) => device.fingerprint,
          rowBuilder: _row,
          emptyText: strings.ignoredEmpty,
        ),
      ),
    );
  }
}
