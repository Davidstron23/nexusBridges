import 'package:flutter/material.dart';
import 'package:nexus_bridges_core/nexus_bridges_core.dart';

import '../app_controller.dart';
import '../drop/drop_controller.dart';
import '../l10n/app_strings.dart';
import 'destination/destination_controller.dart' show MenuOrigin;
import 'destination/destination_menu.dart';
import 'send_menu.dart';

Future<void> startSendFiles(
  BuildContext context,
  AppController controller,
  String fingerprint,
) async {
  final open = DestinationScope.maybeOpen(context);
  if (open != null && isMineEntry(controller, fingerprint)) {
    final paths = await controller.pickFilesFor(fingerprint);
    if (paths.isEmpty || !context.mounted) return;
    open(fingerprint, paths, MenuOrigin.picker);
    return;
  }
  if (!context.mounted) return;
  return _report(context, controller, controller.sendFiles(fingerprint));
}

Future<void> startSendFolders(
  BuildContext context,
  AppController controller,
  String fingerprint,
) async {
  final open = DestinationScope.maybeOpen(context);
  if (open != null && isMineEntry(controller, fingerprint)) {
    final paths = await controller.pickFoldersFor(fingerprint);
    if (paths.isEmpty || !context.mounted) return;
    open(fingerprint, paths, MenuOrigin.picker);
    return;
  }
  if (!context.mounted) return;
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

Future<void> startSendTray(
  BuildContext context,
  AppController controller,
  String fingerprint,
) async {
  final open = DestinationScope.maybeOpen(context);
  if (open != null && isMineEntry(controller, fingerprint)) {
    open(fingerprint, const [], MenuOrigin.tray);
    return;
  }
  return _report(context, controller, controller.sendTray(fingerprint));
}

Future<void> applyDropOutcome(
  BuildContext context,
  AppController controller,
  DropOutcome outcome, {
  Offset? anchor,
}) async {
  switch (outcome) {
    case DropSend(:final fingerprint, :final paths):
      if (isMineEntry(controller, fingerprint)) {
        final open = DestinationScope.maybeOpen(context);
        if (open == null) {
          _announce(context, AppStringsDelegate.of(context).sendUnavailable);
          return;
        }
        open(fingerprint, paths, MenuOrigin.drop, anchor: anchor);
        return;
      }
      await startSendPaths(context, controller, fingerprint, paths);
    case DropSendTo(:final fingerprint, :final paths, :final destination):
      await _report(
        context,
        controller,
        controller.sendPaths(fingerprint, paths, destination: destination),
      );
    case DropTooMany():
      _announce(context, AppStringsDelegate.of(context).tooManySelected);
    case DropToTray(:final paths, :final count, :final blockedFingerprint):
      final result = await controller.addToTray(paths, totalCount: count);
      if (!context.mounted) return;
      final strings = AppStringsDelegate.of(context);
      final state = controller.state;
      String? why;
      if (state != null && blockedFingerprint != null) {
        for (final entry in state.entries) {
          if (entry.fingerprint == blockedFingerprint) {
            why = sendExplanation(strings, state, entry);
          }
        }
      }
      final message = switch (result) {
        TrayResult.tooMany =>
          count > maxDropItems ? strings.tooManySelected : strings.trayFull,
        TrayResult.unavailable => strings.sendUnavailable,
        TrayResult.nothingNew => why ?? strings.trayNothingNew,
        TrayResult.added => why,
      };
      if (message != null) _announce(context, message);
  }
}

void _announce(BuildContext context, String message) {
  ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(content: Text(message)));
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
  _announce(context, message);
}
