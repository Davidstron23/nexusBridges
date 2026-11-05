import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:nexus_bridges_core/nexus_bridges_core.dart';

import '../../app_controller.dart';
import '../../l10n/app_strings.dart';
import '../destination/folder_navigator.dart';
import '../destination/navigator_controller.dart';
import '../icons/device_disc.dart';
import '../icons/glyphs.dart';
import '../modal/timeline.dart';
import '../settings/settings_field.dart';
import '../settings/settings_rows.dart';
import '../settings/settings_section.dart';
import '../theme/app_theme.dart';
import '../theme/tokens.dart';
import '../unpair_modal.dart';
import 'configure_controller.dart';
import 'configure_sections.dart';
import 'history_view.dart';
import 'share_rows.dart';

const double configurePanelWidth = 432;
const Duration _enterDuration = Duration(milliseconds: 500);
const Duration _exitDuration = Duration(milliseconds: 360);
const Duration _subDuration = Duration(milliseconds: 380);
const Duration _aliasDelay = Duration(milliseconds: 400);
const double _panelRadius = 14;
const double _offscreenExtra = 40;
const int _historyShown = 3;
const int _maxShares = 16;
const int _maxFavorites = 8;

PeerSettingsView? _peerOf(NodeState? state, String fingerprint) =>
    state?.peers[fingerprint];

DeviceEntry? _entryOf(NodeState? state, String fingerprint) {
  if (state == null) return null;
  for (final entry in state.entries) {
    if (entry.fingerprint == fingerprint && entry.paired) return entry;
  }
  return null;
}

class ConfigureLayer extends StatefulWidget {
  const ConfigureLayer({
    required this.controller,
    required this.configure,
    required this.child,
    super.key,
  });

  final AppController controller;
  final ConfigureController configure;
  final Widget child;

  @override
  State<ConfigureLayer> createState() => _ConfigureLayerState();
}

class _ConfigureLayerState extends State<ConfigureLayer>
    with TickerProviderStateMixin {
  late final AnimationController _motion = AnimationController(
    vsync: this,
    duration: _enterDuration,
    reverseDuration: _exitDuration,
  )..addStatusListener(_onStatus);
  late final Animation<double> _slide = CurvedAnimation(
    parent: _motion,
    curve: labEaseOut,
    reverseCurve: labEaseIn,
  );
  late final AnimationController _sections = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1000),
  );
  final FocusScopeNode _scope = FocusScopeNode(debugLabel: 'Configure');
  FocusNode? _returnFocus;
  bool _wasOpen = false;
  bool _reduceMotion = false;

  ConfigureController get _configure => widget.configure;

  @override
  void initState() {
    super.initState();
    _configure.addListener(_onConfigure);
    widget.controller.addListener(_onState);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _reduceMotion = MediaQuery.disableAnimationsOf(context);
  }

  @override
  void dispose() {
    _configure.removeListener(_onConfigure);
    widget.controller.removeListener(_onState);
    _motion.dispose();
    _sections.dispose();
    _scope.dispose();
    super.dispose();
  }

  void _onStatus(AnimationStatus status) {
    if (status != AnimationStatus.dismissed) return;
    _configure.exitFinished();
    final node = _returnFocus;
    _returnFocus = null;
    if (node != null && node.context != null && node.canRequestFocus) {
      node.requestFocus();
    }
  }

  void _onState() {
    final fingerprint = _configure.fingerprint;
    if (!_configure.isOpen || fingerprint == null) return;
    if (_entryOf(widget.controller.state, fingerprint) == null) {
      _configure.close();
    }
  }

  void _onConfigure() {
    if (_configure.isOpen && !_wasOpen) {
      _wasOpen = true;
      final focused = FocusManager.instance.primaryFocus;
      _returnFocus = focused is FocusScopeNode ? null : focused;
      if (_reduceMotion) {
        _motion.value = 1;
        _sections.value = 1;
      } else {
        _motion.forward();
        _sections.forward(from: 0);
      }
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _configure.isOpen) _scope.requestFocus();
      });
    } else if (!_configure.isOpen && _wasOpen) {
      _wasOpen = false;
      if (_configure.instant || _reduceMotion) {
        _motion.value = 0;
      } else {
        _motion.reverse();
      }
    }
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final colors = NbColors.of(context);
    final fingerprint = _configure.fingerprint;
    final visible = _configure.isOpen || _configure.closing;
    return Stack(
      children: [
        Positioned.fill(
          child: ExcludeFocus(
            excluding: _configure.isOpen,
            child: widget.child,
          ),
        ),
        if (visible && fingerprint != null)
          Positioned.fill(
            child: AnimatedBuilder(
              animation: _motion,
              builder: (context, _) {
                final scrim = _slide.value.clamp(0.0, 1.0);
                return Stack(
                  children: [
                    Positioned.fill(
                      child: GestureDetector(
                        behavior: HitTestBehavior.opaque,
                        onTap: _configure.isOpen ? _configure.close : null,
                        child: ColoredBox(
                          color: colors.scrim.withValues(
                            alpha: colors.scrim.a * scrim,
                          ),
                        ),
                      ),
                    ),
                    Positioned(
                      top: 0,
                      right: 0,
                      bottom: 0,
                      width: configurePanelWidth,
                      child: LayoutBuilder(
                        builder: (context, constraints) {
                          final width = constraints.maxWidth;
                          final shift =
                              (width + _offscreenExtra) * (1 - _slide.value);
                          return Transform.translate(
                            offset: Offset(shift, 0),
                            child: FocusScope(
                              node: _scope,
                              child: IgnorePointer(
                                ignoring: !_configure.isOpen,
                                child: ConfigurePanel(
                                  key: ValueKey('configure-$fingerprint'),
                                  controller: widget.controller,
                                  fingerprint: fingerprint,
                                  sections: _sections,
                                  onClose: _configure.close,
                                ),
                              ),
                            ),
                          );
                        },
                      ),
                    ),
                  ],
                );
              },
            ),
          ),
      ],
    );
  }
}

class ConfigurePanel extends StatefulWidget {
  const ConfigurePanel({
    required this.controller,
    required this.fingerprint,
    required this.sections,
    required this.onClose,
    super.key,
  });

  final AppController controller;
  final String fingerprint;
  final Animation<double> sections;
  final VoidCallback onClose;

  @override
  State<ConfigurePanel> createState() => _ConfigurePanelState();
}

class _ConfigurePanelState extends State<ConfigurePanel>
    with SingleTickerProviderStateMixin {
  late final AnimationController _sub = AnimationController(
    vsync: this,
    duration: _subDuration,
  );
  late final Animation<double> _subCurve = CurvedAnimation(
    parent: _sub,
    curve: labEaseOut,
    reverseCurve: labEaseOut,
  );
  final TextEditingController _alias = TextEditingController();
  final FocusNode _aliasFocus = FocusNode(debugLabel: 'alias');
  final ScrollController _scroll = ScrollController();
  final FocusNode _panelFocus = FocusNode(debugLabel: 'Configure panel');
  Timer? _aliasTimer;
  bool _historyOpen = false;
  bool _aliasReady = false;
  FolderNavigatorController? _navigator;
  bool _asking = false;
  String? _favoriteMessage;
  double _scrollMemory = 0;

  AppController get _app => widget.controller;

  @override
  void dispose() {
    final pending = _aliasTimer;
    if (pending != null && pending.isActive) {
      pending.cancel();
      _app.setAlias(widget.fingerprint, _alias.text.trim());
    }
    _navigator?.dispose();
    _panelFocus.dispose();
    _sub.dispose();
    _alias.dispose();
    _aliasFocus.dispose();
    _scroll.dispose();
    super.dispose();
  }

  void _onAlias(String text) {
    _aliasTimer?.cancel();
    _aliasTimer = Timer(_aliasDelay, () {
      _app.setAlias(widget.fingerprint, text.trim());
    });
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent ||
        event.logicalKey != LogicalKeyboardKey.escape) {
      return KeyEventResult.ignored;
    }
    if (_historyOpen) {
      _closeHistory();
    } else {
      widget.onClose();
    }
    return KeyEventResult.handled;
  }

  void _openHistory() {
    _historyOpen = true;
    if (_scroll.hasClients) _scrollMemory = _scroll.offset;
    if (MediaQuery.disableAnimationsOf(context)) {
      _sub.value = 1;
    } else {
      _sub.forward();
    }
    setState(() {});
  }

  void _closeHistory() {
    _historyOpen = false;
    if (MediaQuery.disableAnimationsOf(context)) {
      _sub.value = 0;
    } else {
      _sub.reverse();
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scroll.hasClients) _scroll.jumpTo(_scrollMemory);
    });
    setState(() {});
  }

  Future<void> _openFavoriteNavigator(DeviceEntry entry) async {
    if (_asking) return;
    final strings = AppStringsDelegate.of(context);
    setState(() {
      _asking = true;
      _favoriteMessage = null;
    });
    final listing = await _app.listRemoteRoots(widget.fingerprint);
    if (!mounted) return;
    final name = entry.displayName;
    switch (listing) {
      case RemoteRoots(:final roots):
        final available = [
          for (final root in roots)
            if (root.available) root,
        ];
        if (available.isEmpty) {
          setState(() {
            _asking = false;
            _favoriteMessage = strings.destNoChoice(name);
          });
          return;
        }
        final navigator = FolderNavigatorController(
          app: _app,
          fingerprint: widget.fingerprint,
          roots: available,
          mode: NavigatorMode.favorite,
          homeName: strings.homeFolder,
        );
        setState(() {
          _asking = false;
          _navigator = navigator;
        });
      case RemoteFolders():
        setState(() {
          _asking = false;
          _favoriteMessage = strings.destUnreadable(name);
        });
      case RemoteListingFailed(:final reason):
        setState(() {
          _asking = false;
          _favoriteMessage = reason == BrowseFailure.notAllowed
              ? strings.destNoChoice(name)
              : strings.destUnreadable(name);
        });
    }
  }

  void _closeNavigator() {
    final navigator = _navigator;
    if (navigator == null) return;
    setState(() => _navigator = null);
    WidgetsBinding.instance.addPostFrameCallback((_) => navigator.dispose());
  }

  void _saveFavorite() {
    final saved = _navigator?.currentSaved;
    if (saved == null) return;
    final strings = AppStringsDelegate.of(context);
    final result = _app.addFavorite(widget.fingerprint, saved);
    _closeNavigator();
    setState(() {
      _favoriteMessage = result == FavoriteResult.full
          ? strings.favoritesFull
          : null;
    });
  }

  Future<void> _unpair(DeviceEntry entry) async {
    await confirmUnpairDevice(
      context,
      name: entry.displayName,
      type: entry.deviceType,
      onConfirm: () => _app.unpair(entry.fingerprint),
    );
  }

  @override
  Widget build(BuildContext context) {
    final colors = NbColors.of(context);
    return ListenableBuilder(
      listenable: _app,
      builder: (context, _) {
        final state = _app.state;
        final entry = _entryOf(state, widget.fingerprint);
        final peer = _peerOf(state, widget.fingerprint);
        if (entry == null) return const SizedBox.shrink();
        if (!_aliasReady) {
          _aliasReady = true;
          _alias.text = peer?.alias ?? '';
        }
        return Focus(
          focusNode: _panelFocus,
          autofocus: true,
          onKeyEvent: _onKey,
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: colors.card,
              borderRadius: const BorderRadius.only(
                topLeft: Radius.circular(_panelRadius),
              ),
              boxShadow: colors.popoverShadow,
            ),
            child: ClipRRect(
              borderRadius: const BorderRadius.only(
                topLeft: Radius.circular(_panelRadius),
              ),
              child: Stack(
                children: [
                  AnimatedBuilder(
                    animation: _subCurve,
                    builder: (context, child) => IgnorePointer(
                      ignoring: _sub.value > 0.5,
                      child: Opacity(
                        opacity: 1 - _subCurve.value,
                        child: Transform.translate(
                          offset: Offset(
                            -configurePanelWidth * 0.24 * _subCurve.value,
                            0,
                          ),
                          child: child,
                        ),
                      ),
                    ),
                    child: _main(context, entry, peer),
                  ),
                  AnimatedBuilder(
                    animation: _subCurve,
                    builder: (context, child) {
                      if (_sub.value <= 0) return const SizedBox.shrink();
                      return IgnorePointer(
                        ignoring: _sub.value < 0.5,
                        child: Transform.translate(
                          offset: Offset(
                            configurePanelWidth * (1 - _subCurve.value),
                            0,
                          ),
                          child: child,
                        ),
                      );
                    },
                    child: ColoredBox(
                      color: colors.card,
                      child: HistoryView(
                        name: entry.displayName,
                        entries: peer?.history ?? const [],
                        onBack: _closeHistory,
                        onClose: widget.onClose,
                        now: DateTime.now(),
                      ),
                    ),
                  ),
                  if (_navigator != null) _navigatorOverlay(entry),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _navigatorOverlay(DeviceEntry entry) {
    final colors = NbColors.of(context);
    final navigator = _navigator!;
    final animate = !MediaQuery.disableAnimationsOf(context);
    return Positioned.fill(
      child: Stack(
        children: [
          Positioned.fill(
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: _closeNavigator,
              child: const SizedBox.expand(),
            ),
          ),
          Positioned(
            left: (configurePanelWidth - navigatorWidth) / 2,
            top: 90,
            child: CallbackShortcuts(
              bindings: {
                const SingleActivator(LogicalKeyboardKey.escape):
                    _closeNavigator,
              },
              child: TweenAnimationBuilder<double>(
                tween: Tween<double>(begin: animate ? 0 : 1, end: 1),
                duration: animate
                    ? const Duration(milliseconds: 400)
                    : Duration.zero,
                curve: labEaseOut,
                builder: (context, t, child) => Opacity(
                  opacity: t,
                  child: Transform.translate(
                    offset: Offset(0, -6 * (1 - t)),
                    child: Transform.scale(
                      scale: 0.95 + 0.05 * t,
                      alignment: Alignment.topLeft,
                      child: child,
                    ),
                  ),
                ),
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: colors.menuSurface,
                    borderRadius: BorderRadius.circular(14),
                    border: Border.all(color: colors.menuBorder),
                    boxShadow: colors.menuShadow,
                  ),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(14),
                    child: FolderNavigator(
                      controller: navigator,
                      deviceName: entry.displayName,
                      onPick: _saveFavorite,
                      onExit: _closeNavigator,
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _header(BuildContext context, DeviceEntry entry) {
    final strings = AppStringsDelegate.of(context);
    final colors = NbColors.of(context);
    final short = entry.fingerprint.length > 8
        ? entry.fingerprint.substring(0, 8)
        : entry.fingerprint;
    final real = entry.alias == null
        ? null
        : '${entry.realName} · ${strings.fingerprintLine(short)}';
    return DecoratedBox(
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: colors.borderWeak)),
      ),
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: 68),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 6, 14, 6),
          child: Row(
            children: [
              DeviceDisc(
                type: entry.deviceType,
                size: 39,
                tone: entry.visible ? DiscTone.idle : DiscTone.notVisible,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      entry.displayName,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: NbText.title.copyWith(
                        color: colors.text,
                        fontSize: 17,
                        height: 22 / 17,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Row(
                      children: [
                        Flexible(
                          child: Text(
                            real ?? strings.fingerprintLine(short),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: NbText.caption.copyWith(
                              color: colors.textWeak,
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        DecoratedBox(
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: entry.visible
                                ? colors.successInk
                                : colors.hint,
                          ),
                          child: const SizedBox.square(dimension: 6),
                        ),
                        const SizedBox(width: 4),
                        Text(
                          entry.visible
                              ? strings.visibleLabel
                              : strings.notVisibleLabel,
                          maxLines: 1,
                          style: NbText.caption.copyWith(
                            color: colors.textWeak,
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              NavIconButton(
                glyph: Glyphs.close,
                tooltip: strings.closeButton,
                onPressed: widget.onClose,
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _main(
    BuildContext context,
    DeviceEntry entry,
    PeerSettingsView? peer,
  ) {
    final strings = AppStringsDelegate.of(context);
    final colors = NbColors.of(context);
    final name = entry.displayName;
    final mine = entry.mine;
    final shares = peer?.shares ?? const <ShareView>[];
    final favorites = peer?.favorites ?? const <SavedDestination>[];
    final history = peer?.history ?? const <HistoryEntryView>[];
    final now = DateTime.now();
    Widget stagger(int index, Widget child) => ConfigureStagger(
      animation: widget.sections,
      index: index,
      child: child,
    );
    final sections = <Widget>[
      stagger(
        0,
        ConfigureSection(
          first: true,
          icon: Glyphs.someoneElse,
          title: strings.thisDeviceIs,
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: ConfigureOption(
                  glyph: Glyphs.mine,
                  label: strings.mineCard,
                  help: strings.mineCardHelp,
                  selected: mine,
                  onTap: () => _app.setMine(entry.fingerprint, mine: true),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: ConfigureOption(
                  glyph: Glyphs.someoneElse,
                  label: strings.foreignCard,
                  help: strings.foreignCardHelp,
                  selected: !mine,
                  onTap: () => _app.setMine(entry.fingerprint, mine: false),
                ),
              ),
            ],
          ),
        ),
      ),
      stagger(
        1,
        ConfigureSection(
          icon: Glyphs.folder,
          title: strings.sharesTitle,
          count: strings.ofMax(shares.length, _maxShares),
          description: strings.sharesDesc(name),
          info: strings.sharesInfo(name),
          paused: !mine,
          pauseNote: strings.sharesPaused,
          child: SharesBody(
            controller: _app,
            fingerprint: entry.fingerprint,
            shares: shares,
          ),
        ),
      ),
      stagger(
        2,
        ConfigureSection(
          icon: Glyphs.star,
          title: strings.favoritesTitle,
          count: strings.ofMax(favorites.length, _maxFavorites),
          description: strings.favoritesDesc,
          info: strings.favoritesInfo(name),
          paused: !mine,
          pauseNote: strings.favoritesPaused,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              SettingsRowList<SavedDestination>(
                items: favorites,
                idOf: (item) => '${item.rootId}/${item.path.join('/')}',
                emptyText: strings.favoritesEmpty,
                rowBuilder: (context, item, index) => FavoriteRow(
                  destination: item,
                  divider: index > 0,
                  onRemove: () => _app.removeFavorite(
                    entry.fingerprint,
                    favorites.indexOf(item),
                  ),
                ),
              ),
              const SizedBox(height: 10),
              Row(
                children: [
                  OutlinedButton.icon(
                    style: smallButton,
                    onPressed:
                        entry.visible &&
                            !_asking &&
                            favorites.length < _maxFavorites
                        ? () => _openFavoriteNavigator(entry)
                        : null,
                    icon: const GlyphIcon(Glyphs.plus, size: 14),
                    label: Text(strings.favoritesAdd),
                  ),
                  if (!entry.visible) ...[
                    const SizedBox(width: 10),
                    Flexible(
                      child: Text(
                        strings.favoritesNeedVisible,
                        style: NbText.caption.copyWith(color: colors.textWeak),
                      ),
                    ),
                  ],
                ],
              ),
              if (_favoriteMessage != null)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text(
                    _favoriteMessage!,
                    style: NbText.caption.copyWith(
                      color: colors.danger,
                      fontSize: 12.5,
                      height: 18 / 12.5,
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
      stagger(
        3,
        ConfigureSection(
          icon: Glyphs.edit,
          title: strings.aliasTitle,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              SettingsTextField(
                controller: _alias,
                focusNode: _aliasFocus,
                label: strings.aliasTitle,
                hint: strings.aliasPlaceholder,
                maxLength: 64,
                onChanged: _onAlias,
              ),
              const SizedBox(height: 8),
              Text(
                strings.aliasHelp(entry.realName),
                style: NbText.caption.copyWith(
                  color: colors.textWeak,
                  fontSize: 12.5,
                  height: 18 / 12.5,
                ),
              ),
            ],
          ),
        ),
      ),
      stagger(
        4,
        ConfigureSection(
          icon: Glyphs.history,
          title: strings.historyTitle(name),
          info: strings.historyInfo,
          description: history.length > _historyShown
              ? strings.historyLast3
              : strings.historyKept,
          action: history.length > _historyShown
              ? _SeeAll(
                  label: strings.historySeeAll(history.length),
                  onTap: _openHistory,
                )
              : null,
          child: history.isEmpty
              ? SettingsEmpty(text: strings.historyEmpty)
              : SettingsWell(
                  child: Column(
                    children: [
                      for (
                        var i = 0;
                        i < history.length && i < _historyShown;
                        i++
                      )
                        HistoryRow(
                          entry: history[i],
                          divider: i > 0,
                          timeOnly: false,
                          now: now,
                        ),
                    ],
                  ),
                ),
        ),
      ),
      stagger(
        5,
        ConfigureSection(
          icon: Glyphs.unlink,
          title: strings.unpairSectionTitle,
          info: strings.unpairSectionInfo,
          child: ConfigureDangerZone(
            help: strings.unpairSectionHelp,
            button: Align(
              alignment: Alignment.centerLeft,
              child: FilledButton.icon(
                style: FilledButton.styleFrom(
                  backgroundColor: colors.dangerFill,
                  foregroundColor: colors.onPrimary,
                ),
                onPressed: () => _unpair(entry),
                icon: const GlyphIcon(Glyphs.unlink, size: 16),
                label: Text(
                  strings.unpairButton,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ),
          ),
        ),
      ),
    ];
    return Column(
      children: [
        _header(context, entry),
        Expanded(
          child: ListView(
            controller: _scroll,
            padding: const EdgeInsets.fromLTRB(20, 6, 20, 28),
            children: sections,
          ),
        ),
      ],
    );
  }
}

class _SeeAll extends StatefulWidget {
  const _SeeAll({required this.label, required this.onTap});

  final String label;
  final VoidCallback onTap;

  @override
  State<_SeeAll> createState() => _SeeAllState();
}

class _SeeAllState extends State<_SeeAll> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final colors = NbColors.of(context);
    final animate = !MediaQuery.disableAnimationsOf(context);
    return Semantics(
      button: true,
      label: widget.label,
      excludeSemantics: true,
      child: FocusableActionDetector(
        mouseCursor: SystemMouseCursors.click,
        onShowHoverHighlight: (value) => setState(() => _hovered = value),
        actions: {
          ActivateIntent: CallbackAction<ActivateIntent>(
            onInvoke: (_) {
              widget.onTap();
              return null;
            },
          ),
        },
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: widget.onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 4, horizontal: 4),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  widget.label,
                  style: NbText.button.copyWith(color: colors.primaryInk),
                ),
                const SizedBox(width: 4),
                AnimatedSlide(
                  offset: Offset(_hovered ? 0.15 : 0, 0),
                  duration: animate
                      ? const Duration(milliseconds: 300)
                      : Duration.zero,
                  curve: labEaseOut,
                  child: GlyphIcon(
                    Glyphs.chevronRight,
                    size: 13,
                    color: colors.primaryInk,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
