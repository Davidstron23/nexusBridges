import 'dart:async';
import 'dart:ui' show AppExitResponse;

import 'package:flutter/material.dart';

import '../app_controller.dart';
import '../l10n/app_strings.dart';

Future<bool> confirmCloseDuringTransfer(BuildContext context) async {
  final result = await showDialog<bool>(
    context: context,
    builder: (dialogContext) {
      final strings = AppStringsDelegate.of(dialogContext);
      return AlertDialog(
        scrollable: true,
        title: Text(strings.closeDuringTransferTitle),
        content: Text(strings.closeDuringTransferBody),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: Text(strings.keepOpenButton),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: Text(strings.closeAndCancelButton),
          ),
        ],
      );
    },
  );
  return result ?? false;
}

Future<AppExitResponse> handleExitRequest(
  AppController controller, {
  required BuildContext? Function() context,
  Duration shutdownBudget = const Duration(seconds: 5),
}) async {
  if (controller.state?.pickerOpen == true) {
    final closed = Completer<void>();
    void onChange() {
      if (controller.state?.pickerOpen != true && !closed.isCompleted) {
        closed.complete();
      }
    }

    controller.addListener(onChange);
    try {
      await closed.future;
    } finally {
      controller.removeListener(onChange);
    }
  }
  if (controller.state?.transferInProgress == true) {
    final ctx = context();
    if (ctx != null && ctx.mounted) {
      final confirmed = await confirmCloseDuringTransfer(ctx);
      if (!confirmed) return AppExitResponse.cancel;
    }
  }
  try {
    await controller.shutdown().timeout(shutdownBudget);
  } catch (_) {}
  return AppExitResponse.exit;
}
