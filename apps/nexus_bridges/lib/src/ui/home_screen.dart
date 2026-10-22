import 'package:flutter/material.dart';
import 'package:nexus_bridges_core/nexus_bridges_core.dart';

import '../app_controller.dart';
import '../l10n/app_strings.dart';

class HomeScreen extends StatelessWidget {
  const HomeScreen(this.controller, {super.key});

  final AppController controller;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        final strings = AppStringsDelegate.of(context);
        return Scaffold(
          appBar: AppBar(title: Text(strings.devicesTitle)),
          body: Align(
            alignment: Alignment.topCenter,
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 720),
              child: _content(strings),
            ),
          ),
        );
      },
    );
  }

  Widget _content(AppStrings strings) {
    final state = controller.state;
    if (state == null ||
        controller.startFailed ||
        state.identityStatus == IdentityStatus.failed) {
      return _MessageWithRetry(
        message: strings.identityFailed,
        retryLabel: strings.retryButton,
        onRetry: controller.retry,
      );
    }
    final port = state.portInUse;
    if (port != null) {
      return _MessageWithRetry(
        message: strings.portInUse(port),
        retryLabel: strings.retryButton,
        onRetry: controller.retry,
      );
    }
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        if (state.paused)
          _Notice(
            message: strings.pausedBanner,
            actions: [
              for (final network in state.pausedNetworks)
                TextButton(
                  onPressed: () => controller.askAgain(network.networkId),
                  child: Text(strings.trustNetworkButton(network.networkName)),
                ),
            ],
          ),
        if (state.decisionNotSaved) _Notice(message: strings.decisionNotSaved),
        if (state.identityStatus == IdentityStatus.reset &&
            !controller.identityWarningDismissed)
          _Notice(
            message: strings.identityResetWarning,
            actions: [
              TextButton(
                onPressed: controller.dismissIdentityWarning,
                child: Text(strings.closeButton),
              ),
            ],
          ),
        if (state.devices.isEmpty)
          _EmptyDevices(
            strings: strings,
            suggestRescan: state.suggestRescan,
            onRescan: controller.rescan,
          )
        else
          for (final device in state.devices)
            _DeviceTile(
              key: ValueKey(device.info.fingerprint),
              strings: strings,
              device: device,
              name:
                  state.displayNames[device.info.fingerprint] ??
                  device.info.fingerprint.substring(0, 8),
            ),
      ],
    );
  }
}

class _MessageWithRetry extends StatelessWidget {
  const _MessageWithRetry({
    required this.message,
    required this.retryLabel,
    required this.onRetry,
  });

  final String message;
  final String retryLabel;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              message,
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 16),
            FilledButton(onPressed: onRetry, child: Text(retryLabel)),
          ],
        ),
      ),
    );
  }
}

class _Notice extends StatelessWidget {
  const _Notice({required this.message, this.actions = const []});

  final String message;
  final List<Widget> actions;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Card.filled(
        margin: EdgeInsets.zero,
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(message),
              if (actions.isNotEmpty) ...[
                const SizedBox(height: 8),
                Wrap(spacing: 8, runSpacing: 4, children: actions),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _DeviceTile extends StatelessWidget {
  const _DeviceTile({
    required this.strings,
    required this.device,
    required this.name,
    super.key,
  });

  final AppStrings strings;
  final DiscoveredDevice device;
  final String name;

  @override
  Widget build(BuildContext context) {
    final mobile = device.info.deviceType == DeviceType.mobile;
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Card.outlined(
        margin: EdgeInsets.zero,
        child: ListTile(
          leading: Icon(mobile ? Icons.smartphone : Icons.computer),
          title: Text(name),
          subtitle: Text(
            mobile ? strings.deviceTypeMobile : strings.deviceTypeDesktop,
          ),
          trailing: Text(
            device.paired ? strings.pairedLabel : strings.notPairedLabel,
          ),
        ),
      ),
    );
  }
}

class _EmptyDevices extends StatelessWidget {
  const _EmptyDevices({
    required this.strings,
    required this.suggestRescan,
    required this.onRescan,
  });

  final AppStrings strings;
  final bool suggestRescan;
  final VoidCallback onRescan;

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 48),
      child: Column(
        children: [
          if (suggestRescan) ...[
            Text(
              strings.rescanHint,
              textAlign: TextAlign.center,
              style: textTheme.bodyLarge,
            ),
            const SizedBox(height: 16),
            FilledButton.tonal(
              onPressed: onRescan,
              child: Text(strings.rescanButton),
            ),
          ] else
            Text(
              strings.noDevicesYet,
              textAlign: TextAlign.center,
              style: textTheme.bodyLarge,
            ),
        ],
      ),
    );
  }
}
