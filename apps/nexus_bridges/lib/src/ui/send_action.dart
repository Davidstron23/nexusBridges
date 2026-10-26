import 'package:flutter/material.dart';
import 'package:nexus_bridges_core/nexus_bridges_core.dart';

import '../app_controller.dart';
import '../l10n/app_strings.dart';

Future<void> startSend(
  BuildContext context,
  AppController controller,
  String fingerprint,
) async {
  final result = await controller.sendFile(fingerprint);
  if (!context.mounted) return;
  final strings = AppStringsDelegate.of(context);
  final message = switch (result) {
    SendFileResult.alreadySending => strings.alreadySending,
    SendFileResult.unavailable => strings.sendUnavailable,
    SendFileResult.started || SendFileResult.nothingChosen => null,
  };
  if (message == null) return;
  ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
}
