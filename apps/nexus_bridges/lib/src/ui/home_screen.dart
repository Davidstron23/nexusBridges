import 'package:flutter/material.dart';
import 'package:nexus_bridges_core/nexus_bridges_core.dart';

import '../app_controller.dart';
import '../l10n/app_strings.dart';
import 'activity_cards.dart';
import 'diagram/flow_diagram.dart';
import 'home_layout.dart';
import 'device_list.dart';
import 'incoming_cards.dart';
import 'modal/timeline.dart';
import 'network_strip.dart';
import 'send_action.dart';
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
  const _Header({required this.controller, required this.state});

  final AppController controller;
  final NodeState? state;

  @override
  Widget build(BuildContext context) {
    final state = this.state;
    if (state == null) return const SizedBox.shrink();
    return LayoutBuilder(
      builder: (context, constraints) {
        return Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
          child: NetworkStrip(
            state: state,
            onRescan: controller.rescan,
            onTrust: controller.askAgain,
            compact: constraints.maxWidth < _narrowHeader,
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
            hovered: hovered,
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
                    onSend: (fingerprint) =>
                        startSend(context, controller, fingerprint),
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
    required this.hovered,
    required this.noticeText,
  });

  final AppStrings strings;
  final AppController controller;
  final NodeState state;
  final ValueNotifier<ColumnTab> tab;
  final ValueNotifier<String?> hovered;
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

  @override
  Widget build(BuildContext context) {
    final pairedCount = state.entries.where((entry) => entry.paired).length;
    return ValueListenableBuilder<ColumnTab>(
      valueListenable: tab,
      builder: (context, current, _) {
        final blocks = <Widget>[
          if (hasIncomingCard(state))
            IncomingCards(controller: controller, state: state),
          ..._notices(),
          _ColumnTabs(
            strings: strings,
            current: current,
            pairedCount: pairedCount,
            onSelect: (value) => tab.value = value,
          ),
          if (current == ColumnTab.activity)
            ActivityPanel(controller: controller, state: state)
          else
            DeviceList(controller: controller, state: state, hovered: hovered),
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
        color: colors.segment,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Padding(
        padding: const EdgeInsets.all(3),
        child: SizedBox(
          height: _tabHeight,
          child: Stack(
            fit: StackFit.expand,
            children: [
              _TabThumb(activity: current == ColumnTab.activity),
              Row(
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
            ],
          ),
        ),
      ),
    );
  }
}

const double _tabHeight = 32;

const Duration _thumbSlide = Duration(milliseconds: 220);

class _TabThumb extends StatelessWidget {
  const _TabThumb({required this.activity});

  final bool activity;

  @override
  Widget build(BuildContext context) {
    final colors = NbColors.of(context);
    return AnimatedAlign(
      alignment: activity ? Alignment.centerLeft : Alignment.centerRight,
      duration: MediaQuery.disableAnimationsOf(context)
          ? Duration.zero
          : _thumbSlide,
      curve: labEaseOut,
      child: FractionallySizedBox(
        widthFactor: 0.5,
        heightFactor: 1,
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: colors.card,
            borderRadius: BorderRadius.circular(8),
            boxShadow: [
              BoxShadow(
                color: colors.nodeShadow,
                offset: const Offset(0, 1),
                blurRadius: 2,
              ),
            ],
          ),
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
      child: SizedBox(
        height: _tabHeight,
        child: Material(
          type: MaterialType.transparency,
          child: InkWell(
            borderRadius: BorderRadius.circular(8),
            mouseCursor: active
                ? SystemMouseCursors.basic
                : SystemMouseCursors.click,
            hoverColor: Colors.transparent,
            highlightColor: Colors.transparent,
            splashFactory: NoSplash.splashFactory,
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
                        fontVariations: [
                          FontVariation.weight(colors.headingWeight),
                        ],
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
