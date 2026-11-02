import 'package:flutter/material.dart';
import 'package:nexus_bridges_core/nexus_bridges_core.dart';

import '../app_controller.dart';
import '../l10n/app_strings.dart';
import 'send_menu.dart';

Future<void> startSendFiles(
  BuildContext context,
  AppController controller,
  String fingerprint,
) {
  return _report(context, controller, controller.sendFiles(fingerprint));
}

Future<void> startSendFolders(
  BuildContext context,
  AppController controller,
  String fingerprint,
) {
  return _report(context, controller, controller.sendFolders(fingerprint));
}

Future<void> startSendPaths(
  BuildContext context,
  AppController controller,
  String fingerprint,
  List<String> paths,
) {
  return _report(context, controller, controller.sendPaths(fingerprint, paths));
}

String? sendResultMessage(
  AppStrings strings,
  SendResult result, {
  String? busyWith,
}) {
  return switch (result) {
    SendResult.otherTargetBusy =>
      busyWith == null
          ? strings.alreadySending
          : strings.waitForQueues(busyWith),
    SendResult.tooMany => strings.tooManySelected,
    SendResult.unavailable => strings.sendUnavailable,
    SendResult.started || SendResult.queued || SendResult.nothingChosen => null,
  };
}

Future<void> _report(
  BuildContext context,
  AppController controller,
  Future<SendResult> pending,
) async {
  final result = await pending;
  if (!context.mounted) return;
  final strings = AppStringsDelegate.of(context);
  final state = controller.state;
  final target = state?.sendingTo;
  final message = sendResultMessage(
    strings,
    result,
    busyWith: state == null || target == null
        ? null
        : deviceNameIn(state, target),
  );
  if (message == null) return;
  ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
}
