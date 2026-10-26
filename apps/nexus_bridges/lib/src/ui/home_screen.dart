import 'package:flutter/material.dart';
import 'package:nexus_bridges_core/nexus_bridges_core.dart';

import '../app_controller.dart';
import '../l10n/app_strings.dart';
import 'brand/brand_mark.dart';
import 'diagram/flow_diagram.dart';
import 'home_layout.dart';
import 'network_strip.dart';
import 'pairing_dialogs.dart';
import 'theme/app_theme.dart';
import 'theme/components.dart';
import 'theme/tokens.dart';

const double _narrowHeader = 600;

class HomeScreen extends StatefulWidget {
  const HomeScreen(this.controller, {super.key});

  final AppController controller;

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  final ValueNotifier<ColumnTab> _tab = ValueNotifier(ColumnTab.devices);
  final ValueNotifier<String?> _hovered = ValueNotifier(null);
  NodeState? _previous;
  bool _tabSet = false;

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_syncTab);
    _syncTab();
  }

  @override
  void didUpdateWidget(HomeScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller.removeListener(_syncTab);
      widget.controller.addListener(_syncTab);
    }
  }

  @override
  void dispose() {
    widget.controller.removeListener(_syncTab);
    _tab.dispose();
    _hovered.dispose();
    super.dispose();
  }

  void _syncTab() {
    final state = widget.controller.state;
    if (state == null) return;
    if (!_tabSet) {
      _tab.value = hasActivity(state) ? ColumnTab.activity : ColumnTab.devices;
      _tabSet = true;
    } else if (shouldShowActivity(_previous, state)) {
      _tab.value = ColumnTab.activity;
    }
    _previous = state;
  }

  @override
  Widget build(BuildContext context) {
    final controller = widget.controller;
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        final strings = AppStringsDelegate.of(context);
        final state = controller.state;
        final failure = _failureMessage(strings);
        return Scaffold(
          body: Column(
            children: [
              _Header(
                strings: strings,
                controller: controller,
                state: failure == null ? state : null,
              ),
              Expanded(
                child: failure != null
                    ? _MessageWithRetry(
                        message: failure,
                        retryLabel: strings.retryButton,
                        onRetry: controller.retry,
                      )
                    : _Body(
                        strings: strings,
                        controller: controller,
                        state: state!,
                        tab: _tab,
                        hovered: _hovered,
                        noticeText: (notice) => _noticeText(strings, notice),
                      ),
              ),
            ],
          ),
        );
      },
    );
  }

  String? _failureMessage(AppStrings strings) {
    final controller = widget.controller;
    final state = controller.state;
    if (state == null ||
        controller.startFailed ||
        state.identityStatus == IdentityStatus.failed) {
      return strings.identityFailed;
    }
    final port = state.portInUse;
    if (port != null) return strings.portInUse(port);
    return null;
  }

  String _noticeText(AppStrings strings, Notice notice) {
    final name = notice.deviceName ?? '';
    return switch (notice.kind) {
      NoticeKind.attemptDataMismatch => strings.noticeAttemptCancelled(name),
      NoticeKind.attemptCancelled =>
        notice.count == 1
            ? strings.noticeAttemptPeerCancelled(name)
            : strings.noticeAttemptsCancelled(notice.count),
      NoticeKind.attemptLost => strings.noticeAttemptLost(name),
      NoticeKind.replaceWithdrawn => strings.noticeReplaceWithdrawn(name),
      NoticeKind.unpairedByPeer => strings.noticeUnpairedByPeer(name),
      NoticeKind.unpairNotSaved => strings.noticeUnpairNotSaved(name),
      NoticeKind.changeNotSaved => strings.noticeChangeNotSaved,
      NoticeKind.ignoreNotSaved => strings.noticeIgnoreNotSaved(name),
      NoticeKind.pairingNotSaved => strings.noticePairingNotSaved(name),
      NoticeKind.pairingFailed => strings.noticePairingFailed(name),
      NoticeKind.pairingPaused => strings.noticePairingPaused,
      NoticeKind.receiveFolderNotSaved => strings.noticeReceiveFolderNotSaved(
        notice.detail ?? '',
      ),
      NoticeKind.peerCancelledTransfer => strings.noticePeerCancelledTransfer(
        notice.detail ?? '',
      ),
    };
  }
}

class _Header extends StatelessWidget {
  const _Header({
    required this.strings,
    required this.controller,
    required this.state,
  });

  final AppStrings strings;
  final AppController controller;
  final NodeState? state;

  @override
  Widget build(BuildContext context) {
    final colors = NbColors.of(context);
    final state = this.state;
    final brand = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        const BrandMark(size: 36),
        const SizedBox(width: 8),
        Flexible(
          child: Text(
            strings.appTitle,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: NbText.title.copyWith(color: colors.text),
          ),
        ),
      ],
    );
    return LayoutBuilder(
      builder: (context, constraints) {
        final narrow = constraints.maxWidth < _narrowHeader;
        final strip = state == null
            ? null
            : NetworkStrip(
                state: state,
                onRescan: controller.rescan,
                onTrust: controller.askAgain,
                compact: narrow,
              );
        return Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
          child: strip != null && narrow
              ? Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Align(alignment: Alignment.centerLeft, child: brand),
                    const SizedBox(height: 8),
                    strip,
                  ],
                )
              : ConstrainedBox(
                  constraints: const BoxConstraints(minHeight: 60),
                  child: Row(
                    children: [
                      brand,
                      if (strip != null) ...[
                        const SizedBox(width: 16),
                        Expanded(child: strip),
                      ],
                    ],
                  ),
                ),
        );
      },
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
    final colors = NbColors.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              message,
              textAlign: TextAlign.center,
              style: NbText.title.copyWith(color: colors.text),
            ),
            const SizedBox(height: 16),
            FilledButton(onPressed: onRetry, child: Text(retryLabel)),
          ],
        ),
      ),
    );
  }
}

class _Body extends StatelessWidget {
  const _Body({
    required this.strings,
    required this.controller,
    required this.state,
    required this.tab,
    required this.hovered,
    required this.noticeText,
  });

  final AppStrings strings;
  final AppController controller;
  final NodeState state;
  final ValueNotifier<ColumnTab> tab;
  final ValueNotifier<String?> hovered;
  final String Function(Notice notice) noticeText;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(16),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final width = constraints.maxWidth;
          final column = _SideColumn(
            strings: strings,
            controller: controller,
            state: state,
            tab: tab,
            noticeText: noticeText,
          );
          if (!showsDiagram(width)) return column;
          return Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(
                child: NbCard(
                  padding: EdgeInsets.zero,
                  child: FlowDiagram(
                    state: state,
                    hovered: hovered,
                    onSend: (fingerprint) => controller.sendFile(fingerprint),
                    onShowDevices: () => tab.value = ColumnTab.devices,
                  ),
                ),
              ),
              const SizedBox(width: 16),
              SizedBox(width: columnWidthFor(width), child: column),
            ],
          );
        },
      ),
    );
  }
}

class _SideColumn extends StatelessWidget {
  const _SideColumn({
    required this.strings,
    required this.controller,
    required this.state,
    required this.tab,
    required this.noticeText,
  });

  final AppStrings strings;
  final AppController controller;
  final NodeState state;
  final ValueNotifier<ColumnTab> tab;
  final String Function(Notice notice) noticeText;

  List<Widget> _notices() {
    return [
      if (state.decisionNotSaved) NoticeCard(message: strings.decisionNotSaved),
      if (state.identityStatus == IdentityStatus.reset &&
          !controller.identityWarningDismissed)
        NoticeCard(
          message: strings.identityResetWarning,
          actions: [
            TextButton(
              onPressed: controller.dismissIdentityWarning,
              child: Text(strings.closeButton),
            ),
          ],
        ),
      for (final notice in state.notices)
        NoticeCard(
          key: ValueKey('notice-${notice.id}'),
          message: noticeText(notice),
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
        NoticeCard(
          message: strings.noticeChangeNotSaved,
          actions: [
            TextButton(
              onPressed: controller.retrySave,
              child: Text(strings.retryButton),
            ),
          ],
        ),
    ];
  }

  Widget _devices() {
    if (state.entries.isEmpty) {
      return _EmptyDevices(
        strings: strings,
        suggestRescan: state.suggestRescan,
        scanning: state.scanning,
        onRescan: controller.rescan,
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
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

  @override
  Widget build(BuildContext context) {
    final colors = NbColors.of(context);
    final pairedCount = state.entries.where((entry) => entry.paired).length;
    return ValueListenableBuilder<ColumnTab>(
      valueListenable: tab,
      builder: (context, current, _) {
        final blocks = <Widget>[
          ..._notices(),
          _ColumnTabs(
            strings: strings,
            current: current,
            pairedCount: pairedCount,
            onSelect: (value) => tab.value = value,
          ),
          if (current == ColumnTab.activity)
            Text(
              strings.activityEmpty,
              style: NbText.bodySm.copyWith(color: colors.textWeak),
            )
          else
            _devices(),
        ];
        return SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              for (var i = 0; i < blocks.length; i++) ...[
                if (i > 0) const SizedBox(height: 12),
                blocks[i],
              ],
            ],
          ),
        );
      },
    );
  }
}

class _ColumnTabs extends StatelessWidget {
  const _ColumnTabs({
    required this.strings,
    required this.current,
    required this.pairedCount,
    required this.onSelect,
  });

  final AppStrings strings;
  final ColumnTab current;
  final int pairedCount;
  final ValueChanged<ColumnTab> onSelect;

  @override
  Widget build(BuildContext context) {
    final colors = NbColors.of(context);
    return DecoratedBox(
      decoration: BoxDecoration(
        color: colors.surfaceWeak,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Padding(
        padding: const EdgeInsets.all(3),
        child: Row(
          children: [
            Expanded(
              child: _TabZone(
                label: strings.activityTab,
                active: current == ColumnTab.activity,
                onTap: () => onSelect(ColumnTab.activity),
              ),
            ),
            Expanded(
              child: _TabZone(
                label: strings.devicesTab,
                active: current == ColumnTab.devices,
                badge: pairedCount > 0 ? pairedCount : null,
                onTap: () => onSelect(ColumnTab.devices),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _TabZone extends StatelessWidget {
  const _TabZone({
    required this.label,
    required this.active,
    required this.onTap,
    this.badge,
  });

  final String label;
  final bool active;
  final VoidCallback onTap;
  final int? badge;

  @override
  Widget build(BuildContext context) {
    final colors = NbColors.of(context);
    final badge = this.badge;
    return Semantics(
      button: true,
      selected: active,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        height: 32,
        decoration: BoxDecoration(
          color: active ? colors.card : Colors.transparent,
          borderRadius: BorderRadius.circular(8),
          boxShadow: active
              ? [
                  BoxShadow(
                    color: colors.nodeShadow,
                    offset: const Offset(0, 1),
                    blurRadius: 2,
                  ),
                ]
              : null,
        ),
        child: Material(
          type: MaterialType.transparency,
          child: InkWell(
            borderRadius: BorderRadius.circular(8),
            onTap: onTap,
            child: Center(
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Flexible(
                    child: Text(
                      label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: NbText.button.copyWith(
                        color: active ? colors.text : colors.textWeak,
                      ),
                    ),
                  ),
                  if (badge != null) ...[
                    const SizedBox(width: 6),
                    Container(
                      height: 18,
                      constraints: const BoxConstraints(minWidth: 18),
                      padding: const EdgeInsets.symmetric(horizontal: 5),
                      alignment: Alignment.center,
                      decoration: BoxDecoration(
                        color: colors.primaryWeak,
                        borderRadius: BorderRadius.circular(9),
                      ),
                      child: Text(
                        badge.toString(),
                        style: NbText.badge.copyWith(color: colors.primaryInk),
                      ),
                    ),
                  ],
                ],
              ),
            ),
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
    required this.scanning,
    required this.onRescan,
  });

  final AppStrings strings;
  final bool suggestRescan;
  final bool scanning;
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
              onPressed: scanning ? null : onRescan,
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
