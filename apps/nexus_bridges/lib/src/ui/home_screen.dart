import 'dart:async';

import 'package:flutter/material.dart';
import 'package:nexus_bridges_core/nexus_bridges_core.dart';

import '../app_controller.dart';
import '../drop/drop_controller.dart';
import '../drop/drop_events.dart';
import '../drop/drop_zone.dart';
import '../l10n/app_strings.dart';
import 'activity_cards.dart';
import 'attention.dart';
import 'diagram/flow_diagram.dart';
import 'home_layout.dart';
import 'device_list.dart';
import 'incoming_cards.dart';
import 'modal/timeline.dart';
import 'network_strip.dart';
import 'progress/selection_progress_painter.dart';
import 'progress/time_left_scope.dart';
import 'send_action.dart';
import 'settings/settings_controller.dart';
import 'settings/settings_layer.dart';
import 'theme/app_theme.dart';
import 'theme/components.dart';
import 'theme/tokens.dart';
import 'tray_panel.dart';

const double _narrowHeader = 600;

class HomeScreen extends StatefulWidget {
  const HomeScreen(
    this.controller, {
    this.dropEvents,
    this.settings,
    this.attention,
    this.neutralFocus,
    super.key,
  });

  final AppController controller;
  final DropEvents? dropEvents;
  final SettingsController? settings;
  final AttentionWatcher? attention;
  final FocusNode? neutralFocus;

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  final ValueNotifier<ColumnTab> _tab = ValueNotifier(ColumnTab.devices);
  final ValueNotifier<String?> _hovered = ValueNotifier(null);
  late final DropController _drop = DropController(
    canSendTo: (fingerprint) =>
        widget.controller.state?.canSendTo(fingerprint) ?? false,
    isMine: _isMine,
    isBlocked: () => mounted && ModalRoute.of(context)?.isCurrent == false,
    blocked: () => _settings.isOpen || _settings.closing,
    onPortal: (fingerprint) =>
        unawaited(widget.controller.requestPortal(fingerprint)),
    onOutcome: (outcome) {
      if (!mounted) return;
      unawaited(applyDropOutcome(context, widget.controller, outcome));
    },
  );
  StreamSubscription<DropEvent>? _dropSubscription;
  late final SettingsController _settings =
      widget.settings ?? SettingsController();
  AttentionWatcher? _ownAttention;

  AttentionWatcher get _attention =>
      widget.attention ??
      (_ownAttention ??= AttentionWatcher(widget.controller));
  late final FocusNode _neutral =
      widget.neutralFocus ??
      FocusNode(debugLabel: 'neutral', skipTraversal: true);
  NodeState? _previous;
  bool _tabSet = false;
  bool _dropHovering = false;

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_syncTab);
    _syncTab();
    _drop.addListener(_syncDropHover);
    _dropSubscription = (widget.dropEvents ?? MethodChannelDropEvents()).events
        .listen(_drop.handle);
  }

  bool _isMine(String fingerprint) {
    final state = widget.controller.state;
    if (state == null) return false;
    for (final entry in state.entries) {
      if (entry.fingerprint == fingerprint) return entry.mine;
    }
    return false;
  }

  void _syncDropHover() {
    final hovered = _drop.dragging ? _drop.hovered : null;
    final lit =
        hovered != null &&
        (widget.controller.state?.canSendTo(hovered) ?? false);
    if (lit) {
      _hovered.value = hovered;
      _dropHovering = true;
    } else if (_dropHovering) {
      _hovered.value = null;
      _dropHovering = false;
    }
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
    unawaited(_dropSubscription?.cancel());
    _drop.removeListener(_syncDropHover);
    _drop.dispose();
    widget.controller.removeListener(_syncTab);
    _tab.dispose();
    _hovered.dispose();
    if (widget.settings == null) _settings.dispose();
    _ownAttention?.dispose();
    if (widget.neutralFocus == null) _neutral.dispose();
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
    return Focus(
      focusNode: _neutral,
      skipTraversal: true,
      child: DropScope(
        controller: _drop,
        child: ListenableBuilder(
          listenable: controller,
          builder: (context, child) => SelectionProgressScope(
            state: controller.state,
            child: TimeLeftScope(
              state: controller.state,
              source: controller,
              read: () => controller.state,
              child: child!,
            ),
          ),
          child: SettingsLayer(
            controller: controller,
            settings: _settings,
            attention: _attention,
            child: Scaffold(
              body: Column(
                children: [
                  ListenableBuilder(
                    listenable: controller,
                    builder: (context, _) {
                      final strings = AppStringsDelegate.of(context);
                      return _Header(
                        controller: controller,
                        onSettings: _settings.open,
                        state: _failureMessage(controller, strings) == null
                            ? controller.state
                            : null,
                      );
                    },
                  ),
                  Expanded(
                    child: ListenableBuilder(
                      listenable: controller,
                      builder: (context, body) {
                        final strings = AppStringsDelegate.of(context);
                        final failure = _failureMessage(controller, strings);
                        if (failure == null) return body!;
                        return _MessageWithRetry(
                          message: failure,
                          retryLabel: strings.retryButton,
                          onRetry: controller.retry,
                        );
                      },
                      child: _Body(
                        controller: controller,
                        tab: _tab,
                        hovered: _hovered,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

String? _failureMessage(AppController controller, AppStrings strings) {
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
    NoticeKind.settingNotSaved => strings.noticeSettingNotSaved,
    NoticeKind.networkStopNotSaved => strings.noticeNetworkStopNotSaved(
      notice.detail ?? strings.unnamedNetwork,
    ),
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
    NoticeKind.sharesNotSaved => strings.noticeSharesNotSaved,
    NoticeKind.shareAddNotSaved => strings.noticeShareAddNotSaved,
    NoticeKind.sharesReset => strings.noticeSharesReset,
    NoticeKind.sharesPartlyReset => strings.noticeSharesPartlyReset,
  };
}

class _Header extends StatelessWidget {
  const _Header({
    required this.controller,
    required this.state,
    required this.onSettings,
  });

  final AppController controller;
  final NodeState? state;
  final VoidCallback onSettings;

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
            onSettings: onSettings,
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
    required this.controller,
    required this.tab,
    required this.hovered,
  });

  final AppController controller;
  final ValueNotifier<ColumnTab> tab;
  final ValueNotifier<String?> hovered;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(16),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final width = constraints.maxWidth;
          final column = ListenableBuilder(
            listenable: controller,
            builder: (context, _) {
              final state = controller.state;
              if (state == null) return const SizedBox.shrink();
              return _SideColumn(
                strings: AppStringsDelegate.of(context),
                controller: controller,
                state: state,
                tab: tab,
                hovered: hovered,
              );
            },
          );
          if (!showsDiagram(width)) {
            return Stack(
              children: [
                Positioned.fill(child: column),
                Positioned(
                  top: 0,
                  left: 0,
                  right: 0,
                  child: Center(
                    child: DragPill(
                      visible: DropScope.maybeOf(context)?.dragging ?? false,
                    ),
                  ),
                ),
              ],
            );
          }
          return Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(
                child: NbCard(
                  padding: EdgeInsets.zero,
                  child: ListenableBuilder(
                    listenable: controller,
                    builder: (context, _) {
                      final state = controller.state;
                      if (state == null) return const SizedBox.shrink();
                      return FlowDiagram(
                        state: state,
                        hovered: hovered,
                        onSendFiles: (fingerprint) =>
                            startSendFiles(context, controller, fingerprint),
                        onSendFolders: (fingerprint) =>
                            startSendFolders(context, controller, fingerprint),
                        onShowDevices: () => tab.value = ColumnTab.devices,
                      );
                    },
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
  });

  final AppStrings strings;
  final AppController controller;
  final NodeState state;
  final ValueNotifier<ColumnTab> tab;
  final ValueNotifier<String?> hovered;

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
        final leading = <Widget>[
          if (hasIncomingCard(state))
            IncomingCards(controller: controller, state: state),
          ..._notices(),
        ];
        final blocks = <Widget>[
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
              for (final block in leading) ...[
                block,
                const SizedBox(height: 12),
              ],
              TrayHost(controller: controller, state: state),
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
        borderRadius: BorderRadius.circular(_trackRadius),
      ),
      child: Padding(
        padding: const EdgeInsets.all(_trackPadding),
        child: SizedBox(
          height: _scaledTabHeight(context),
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

double _scaledTabHeight(BuildContext context) =>
    MediaQuery.textScalerOf(context).scale(_tabHeight);

const double _trackPadding = 4;

const double _thumbRadius = 8;

const double _trackRadius = _thumbRadius + _trackPadding;

const Duration _thumbSlide = Duration(milliseconds: 380);

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
            borderRadius: BorderRadius.circular(_thumbRadius),
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
        height: _scaledTabHeight(context),
        child: Material(
          type: MaterialType.transparency,
          child: InkWell(
            borderRadius: BorderRadius.circular(_thumbRadius),
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
                    child: TweenAnimationBuilder<Color?>(
                      tween: ColorTween(
                        end: active ? colors.text : colors.textWeak,
                      ),
                      duration: MediaQuery.disableAnimationsOf(context)
                          ? Duration.zero
                          : _thumbSlide,
                      curve: Curves.ease,
                      builder: (context, ink, _) => Text(
                        label,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: NbText.button.copyWith(
                          color: ink,
                          fontVariations: [
                            FontVariation.weight(colors.headingWeight),
                          ],
                        ),
                      ),
                    ),
                  ),
                  if (badge != null) ...[
                    const SizedBox(width: 6),
                    Container(
                      constraints: const BoxConstraints(
                        minWidth: 18,
                        minHeight: 18,
                      ),
                      padding: const EdgeInsets.symmetric(horizontal: 5),
                      decoration: BoxDecoration(
                        color: colors.primaryWeak,
                        borderRadius: BorderRadius.circular(9),
                      ),
                      child: Align(
                        widthFactor: 1,
                        heightFactor: 1,
                        child: Text(
                          badge.toString(),
                          style: NbText.badge.copyWith(
                            color: colors.primaryInk,
                          ),
                        ),
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
