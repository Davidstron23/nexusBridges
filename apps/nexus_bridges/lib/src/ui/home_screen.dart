import 'package:flutter/material.dart';
import 'package:nexus_bridges_core/nexus_bridges_core.dart';

import '../app_controller.dart';
import '../l10n/app_strings.dart';
import 'pairing_dialogs.dart';

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
        for (final notice in state.notices)
          _Notice(
            key: ValueKey('notice-${notice.id}'),
            message: _noticeText(strings, notice),
            actions: [
              if (notice.canRetry)
                TextButton(
                  onPressed: controller.retrySave,
                  child: Text(strings.retryButton),
                ),
              TextButton(
                onPressed: () => controller.dismissNotice(notice.id),
                child: Text(strings.closeButton),
              ),
            ],
          ),
        if (state.unsavedChanges && !state.notices.any((n) => n.canRetry))
          _Notice(
            message: strings.noticeChangeNotSaved,
            actions: [
              TextButton(
                onPressed: controller.retrySave,
                child: Text(strings.retryButton),
              ),
            ],
          ),
        if (state.entries.isEmpty)
          _EmptyDevices(
            strings: strings,
            suggestRescan: state.suggestRescan,
            onRescan: controller.rescan,
          )
        else
          for (final entry in state.entries)
            _DeviceTile(
              key: ValueKey(entry.fingerprint),
              strings: strings,
              controller: controller,
              entry: entry,
            ),
      ],
    );
  }

  String _noticeText(AppStrings strings, Notice notice) {
    final name = notice.deviceName ?? '';
    return switch (notice.kind) {
      NoticeKind.attemptDataMismatch => strings.noticeAttemptCancelled(name),
      NoticeKind.attemptCancelled =>
        notice.count == 1
            ? strings.noticeAttemptPeerCancelled(name)
            : strings.noticeAttemptsCancelled(notice.count),
      NoticeKind.unpairedByPeer => strings.noticeUnpairedByPeer(name),
      NoticeKind.unpairNotSaved => strings.noticeUnpairNotSaved(name),
      NoticeKind.changeNotSaved => strings.noticeChangeNotSaved,
      NoticeKind.ignoreNotSaved => strings.noticeIgnoreNotSaved(name),
      NoticeKind.pairingNotSaved => strings.noticePairingNotSaved(name),
      NoticeKind.pairingFailed => strings.noticePairingFailed(name),
      NoticeKind.pairingPaused => strings.noticePairingPaused,
    };
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
  const _Notice({required this.message, this.actions = const [], super.key});

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

enum _RowAction { toggleMine, unpair }

class _DeviceTile extends StatelessWidget {
  const _DeviceTile({
    required this.strings,
    required this.controller,
    required this.entry,
    super.key,
  });

  final AppStrings strings;
  final AppController controller;
  final DeviceEntry entry;

  String get _label {
    if (entry.paired) {
      return entry.mine ? strings.pairedMineLabel : strings.pairedForeignLabel;
    }
    return entry.ignored ? strings.ignoredLabel : strings.notPairedLabel;
  }

  String get _subtitle {
    if (!entry.visible) return strings.notVisibleLabel;
    return entry.deviceType == DeviceType.mobile
        ? strings.deviceTypeMobile
        : strings.deviceTypeDesktop;
  }

  Future<void> _pair(BuildContext context) async {
    final result = await controller.pair(entry.fingerprint);
    if (!context.mounted) return;
    final message = switch (result) {
      PairRequestResult.started => null,
      PairRequestResult.alreadyInProgress => strings.pairingAlreadyInProgress,
      PairRequestResult.tooManyPaired => strings.tooManyPaired,
      PairRequestResult.unavailable => strings.pairUnavailable,
    };
    if (message == null) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _unpair(BuildContext context) async {
    final confirmed = await confirmUnpair(context, entry.displayName);
    if (!confirmed) return;
    await controller.unpair(entry.fingerprint);
  }

  void _onMenu(BuildContext context, _RowAction action) {
    switch (action) {
      case _RowAction.toggleMine:
        controller.setMine(entry.fingerprint, mine: !entry.mine);
      case _RowAction.unpair:
        _unpair(context);
    }
  }

  @override
  Widget build(BuildContext context) {
    final bodyStyle = Theme.of(context).textTheme.bodyMedium;
    final possiblyReplaces = entry.possiblyReplaces;
    final actions = <Widget>[
      if (entry.paired && entry.mismatch) ...[
        TextButton(
          onPressed: () => _unpair(context),
          child: Text(strings.removeButton),
        ),
        FilledButton.tonal(
          onPressed: () => _pair(context),
          child: Text(strings.pairAgainButton),
        ),
      ] else if (entry.canPair)
        FilledButton.tonal(
          onPressed: () => _pair(context),
          child: Text(strings.pairButton),
        ),
      if (entry.ignored)
        TextButton(
          onPressed: () => controller.unignore(entry.fingerprint),
          child: Text(strings.unignoreButton),
        ),
    ];
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Card.outlined(
        margin: EdgeInsets.zero,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            LayoutBuilder(
              builder: (context, constraints) => ListTile(
                leading: Icon(
                  entry.deviceType == DeviceType.mobile
                      ? Icons.smartphone
                      : Icons.computer,
                ),
                title: Text(entry.displayName),
                subtitle: Text(_subtitle),
                trailing: ConstrainedBox(
                  constraints: BoxConstraints(
                    maxWidth: constraints.maxWidth * 0.4,
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Flexible(
                        child: Text(
                          _label,
                          maxLines: 1,
                          softWrap: false,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      if (entry.paired)
                        PopupMenuButton<_RowAction>(
                          tooltip: strings.moreOptions,
                          onSelected: (action) => _onMenu(context, action),
                          itemBuilder: (_) => [
                            PopupMenuItem(
                              value: _RowAction.toggleMine,
                              child: Text(
                                entry.mine
                                    ? strings.markAsForeign
                                    : strings.markAsMine,
                              ),
                            ),
                            PopupMenuItem(
                              value: _RowAction.unpair,
                              child: Text(strings.unpairButton),
                            ),
                          ],
                        ),
                    ],
                  ),
                ),
              ),
            ),
            if (entry.paired && entry.mismatch)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                child: Text(strings.mismatchWarning, style: bodyStyle),
              ),
            if (possiblyReplaces != null)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                child: Text(
                  strings.possibleReinstall(possiblyReplaces),
                  style: bodyStyle,
                ),
              ),
            if (actions.isNotEmpty)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                child: Wrap(spacing: 8, runSpacing: 4, children: actions),
              ),
          ],
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
