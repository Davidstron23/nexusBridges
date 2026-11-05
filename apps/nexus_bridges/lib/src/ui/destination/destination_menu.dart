import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:nexus_bridges_core/nexus_bridges_core.dart';

import '../../app_controller.dart';
import '../../l10n/app_strings.dart';
import '../icons/device_disc.dart';
import '../icons/file_icon.dart';
import '../icons/folder_icon.dart';
import '../icons/glyphs.dart';
import '../modal/timeline.dart';
import '../send_action.dart';
import '../send_menu.dart' show deviceNameIn;
import '../theme/app_theme.dart';
import '../theme/tokens.dart';
import 'destination_controller.dart';
import 'folder_navigator.dart';
import 'navigator_controller.dart';

const double destinationMenuWidth = 328;
const double _menuMaxBody = 360;
const double _menuRadius = 14;
const Duration _openMotion = Duration(milliseconds: 400);
const Duration _resizeMotion = Duration(milliseconds: 460);

typedef OpenDestinationMenu = void Function(
  String fingerprint,
  List<String> paths,
  MenuOrigin origin, {
  Offset? anchor,
  RemoteRoots? cached,
});

class DestinationScope extends InheritedWidget {
  const DestinationScope({required this.open, required super.child, super.key});

  final OpenDestinationMenu open;

  static OpenDestinationMenu? maybeOpen(BuildContext context) {
    return context.getInheritedWidgetOfExactType<DestinationScope>()?.open;
  }

  @override
  bool updateShouldNotify(DestinationScope oldWidget) => false;
}

bool isMineEntry(AppController controller, String fingerprint) {
  final state = controller.state;
  if (state == null) return false;
  for (final entry in state.entries) {
    if (entry.fingerprint == fingerprint) return entry.paired && entry.mine;
  }
  return false;
}

class DestinationLayer extends StatefulWidget {
  const DestinationLayer({
    required this.controller,
    required this.child,
    this.cachedRoots,
    super.key,
  });

  final AppController controller;
  final Widget child;
  final RemoteRoots? Function(String fingerprint)? cachedRoots;

  @override
  State<DestinationLayer> createState() => _DestinationLayerState();
}

class _DestinationLayerState extends State<DestinationLayer> {
  DestinationMenuController? _menu;
  Offset? _anchor;
  int _generation = 0;

  void _open(
    String fingerprint,
    List<String> paths,
    MenuOrigin origin, {
    Offset? anchor,
    RemoteRoots? cached,
  }) {
    final strings = AppStringsDelegate.of(context);
    _close();
    final generation = ++_generation;
    final menu = DestinationMenuController(
      app: widget.controller,
      fingerprint: fingerprint,
      paths: paths,
      origin: origin,
      cached: cached ?? widget.cachedRoots?.call(fingerprint),
      homeName: strings.homeFolder,
      onDone: (result) => _done(generation, result),
    );
    setState(() {
      _menu = menu;
      _anchor = anchor;
    });
  }

  void _done(int generation, SendResult? result) {
    if (!mounted || generation != _generation) return;
    _close();
    if (result == null) return;
    final strings = AppStringsDelegate.of(context);
    final state = widget.controller.state;
    final target = state?.sendingTo;
    final message = sendResultMessage(
      strings,
      result,
      busyWith: state == null || target == null
          ? null
          : deviceNameIn(state, target),
    );
    if (message == null) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  void _close() {
    final menu = _menu;
    if (menu == null) return;
    _generation++;
    setState(() => _menu = null);
    WidgetsBinding.instance.addPostFrameCallback((_) => menu.dispose());
  }

  void _cancel() => _menu?.cancel();

  @override
  void dispose() {
    _menu?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final menu = _menu;
    return DestinationScope(
      open: _open,
      child: Stack(
        children: [
          Positioned.fill(
            child: ExcludeFocus(excluding: menu != null, child: widget.child),
          ),
          if (menu != null)
            Positioned.fill(
              child: Stack(
                children: [
                  Positioned.fill(
                    child: GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onTap: _cancel,
                      child: const SizedBox.expand(),
                    ),
                  ),
                  Positioned.fill(
                    child: CustomSingleChildLayout(
                      delegate: _MenuLayout(_localAnchor(context)),
                      child: DestinationMenu(
                        key: ValueKey(menu),
                        controller: menu,
                        app: widget.controller,
                        onCancel: _cancel,
                      ),
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  Offset? _localAnchor(BuildContext context) {
    final anchor = _anchor;
    if (anchor == null) return null;
    final box = context.findRenderObject();
    if (box is RenderBox && box.hasSize) return box.globalToLocal(anchor);
    return anchor;
  }
}

class _MenuLayout extends SingleChildLayoutDelegate {
  const _MenuLayout(this.anchor);

  final Offset? anchor;

  @override
  BoxConstraints getConstraintsForChild(BoxConstraints constraints) =>
      constraints.loosen();

  @override
  Offset getPositionForChild(Size size, Size childSize) {
    const margin = 10.0;
    final point = anchor ?? Offset(size.width / 2, size.height / 3);
    final left = anchor == null ? point.dx - childSize.width / 2 : point.dx;
    final maxLeft = size.width - childSize.width - margin;
    final maxTop = size.height - childSize.height - margin;
    return Offset(
      left.clamp(margin, maxLeft < margin ? margin : maxLeft),
      point.dy.clamp(margin, maxTop < margin ? margin : maxTop),
    );
  }

  @override
  bool shouldRelayout(_MenuLayout oldDelegate) => oldDelegate.anchor != anchor;
}

class DestinationMenu extends StatefulWidget {
  const DestinationMenu({
    required this.controller,
    required this.app,
    required this.onCancel,
    super.key,
  });

  final DestinationMenuController controller;
  final AppController app;
  final VoidCallback onCancel;

  @override
  State<DestinationMenu> createState() => _DestinationMenuState();
}

class _DestinationMenuState extends State<DestinationMenu> {
  final ScrollController _scroll = ScrollController();
  final FocusNode _focus = FocusNode(debugLabel: 'destination menu');
  final Map<int, GlobalKey> _keys = {};
  FolderNavigatorController? _explorer;
  int _lastFocused = -1;

  DestinationMenuController get _menu => widget.controller;

  @override
  void initState() {
    super.initState();
    _menu.addListener(_onMenu);
  }

  @override
  void dispose() {
    _menu.removeListener(_onMenu);
    _explorer?.dispose();
    _scroll.dispose();
    _focus.dispose();
    super.dispose();
  }

  void _onMenu() {
    if (!mounted) return;
    setState(() {});
    if (_menu.focused != _lastFocused) {
      _lastFocused = _menu.focused;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        final context = _keys[_menu.focused]?.currentContext;
        if (context != null && context.mounted) {
          Scrollable.ensureVisible(
            context,
            duration: const Duration(milliseconds: 120),
          );
        }
      });
    }
  }

  void _openExplorer() {
    if (_menu.status != MenuStatus.ready) return;
    setState(() => _explorer = _menu.openExplorer());
  }

  void _closeExplorer() {
    final explorer = _explorer;
    if (explorer == null) return;
    setState(() => _explorer = null);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      explorer.dispose();
      if (mounted) _focus.requestFocus();
    });
  }

  void _pickExplored() {
    final destination = _explorer?.current;
    if (destination == null) return;
    _menu.sendTo(destination);
  }

  void _choose(MenuItem item) {
    if (item is ExploreItem) {
      _openExplorer();
    } else {
      _menu.choose(item);
    }
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (_explorer != null) return KeyEventResult.ignored;
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    final key = event.logicalKey;
    if (key == LogicalKeyboardKey.arrowDown) {
      _menu.moveFocus(1);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.arrowUp) {
      _menu.moveFocus(-1);
      return KeyEventResult.handled;
    }
    if (event is KeyDownEvent &&
        (key == LogicalKeyboardKey.enter ||
            key == LogicalKeyboardKey.numpadEnter)) {
      final items = _menu.items;
      if (_menu.focused < items.length) _choose(items[_menu.focused]);
      return KeyEventResult.handled;
    }
    if (event is KeyDownEvent && key == LogicalKeyboardKey.escape) {
      widget.onCancel();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    final colors = NbColors.of(context);
    final animate = !MediaQuery.disableAnimationsOf(context);
    final explorer = _explorer;
    final entry = _entryOf(widget.app.state, _menu.fingerprint);
    final name = entry?.displayName ?? '';
    final strings = AppStringsDelegate.of(context);
    final Widget content = explorer != null
        ? CallbackShortcuts(
            bindings: {
              const SingleActivator(LogicalKeyboardKey.escape): _closeExplorer,
            },
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                _Header(
                  entry: entry,
                  name: name,
                  paths: _menu.paths,
                  strings: strings,
                ),
                FolderNavigator(
                  controller: explorer,
                  deviceName: name,
                  onPick: _pickExplored,
                  onExit: _closeExplorer,
                ),
              ],
            ),
          )
        : SizedBox(
            width: destinationMenuWidth,
            child: _body(context, entry, name, strings, colors),
          );
    return TweenAnimationBuilder<double>(
      tween: Tween<double>(begin: animate ? 0 : 1, end: 1),
      duration: animate ? _openMotion : Duration.zero,
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
          borderRadius: BorderRadius.circular(_menuRadius),
          border: Border.all(color: colors.menuBorder),
          boxShadow: colors.menuShadow,
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(_menuRadius),
          child: Focus(
            focusNode: _focus,
            autofocus: true,
            onKeyEvent: _onKey,
            child: animate
                ? AnimatedSize(
                    duration: _resizeMotion,
                    curve: labEaseOut,
                    alignment: Alignment.topLeft,
                    child: content,
                  )
                : Align(
                    alignment: Alignment.topLeft,
                    widthFactor: 1,
                    heightFactor: 1,
                    child: content,
                  ),
          ),
        ),
      ),
    );
  }

  Widget _body(
    BuildContext context,
    DeviceEntry? entry,
    String name,
    AppStrings strings,
    NbColors colors,
  ) {
    final items = _menu.items;
    final rows = <Widget>[];
    var lastGroup = '';
    for (var i = 0; i < items.length; i++) {
      final item = items[i];
      final group = switch (item) {
        FavoriteItem() => 'favorites',
        RootItem() => 'roots',
        RecentItem() => 'recent',
        _ => '',
      };
      if (group != lastGroup && group.isNotEmpty) {
        rows.add(
          _GroupLabel(
            label: switch (group) {
              'favorites' => strings.destFavorites,
              'roots' => strings.destFoldersOf(name),
              _ => strings.destRecent,
            },
            note: group == 'roots' ? strings.destShared : null,
          ),
        );
      }
      lastGroup = group;
      if (item is ExploreItem) rows.add(_status(strings));
      rows.add(
        KeyedSubtree(
          key: _keys.putIfAbsent(i, GlobalKey.new),
          child: _row(strings, colors, item, i),
        ),
      );
    }
    if (items.isEmpty || items.last is! ExploreItem) rows.add(_status(strings));
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _Header(entry: entry, name: name, paths: _menu.paths, strings: strings),
        ConstrainedBox(
          constraints: const BoxConstraints(maxHeight: _menuMaxBody),
          child: SingleChildScrollView(
            controller: _scroll,
            padding: const EdgeInsets.fromLTRB(6, 4, 6, 6),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: rows,
            ),
          ),
        ),
        DecoratedBox(
          decoration: BoxDecoration(
            border: Border(top: BorderSide(color: colors.menuBorder)),
          ),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
            child: Text(
              strings.destKeys,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: NbText.caption.copyWith(
                color: colors.hint,
                fontSize: 11.5,
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _status(AppStrings strings) {
    final name =
        _entryOf(widget.app.state, _menu.fingerprint)?.displayName ?? '';
    final colors = NbColors.of(context);
    switch (_menu.status) {
      case MenuStatus.loading:
        return Padding(
          padding: const EdgeInsets.fromLTRB(10, 6, 10, 6),
          child: Row(
            children: [
              SizedBox.square(
                dimension: 12,
                child: CircularProgressIndicator(
                  strokeWidth: 1.6,
                  color: colors.textWeak,
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  strings.destLoading,
                  style: NbText.caption.copyWith(color: colors.textWeak),
                ),
              ),
            ],
          ),
        );
      case MenuStatus.noChoice:
        return NavNotice(text: strings.destNoChoice(name));
      case MenuStatus.unreadable:
        return NavNotice(text: strings.destUnreadable(name));
      case MenuStatus.ready:
        return const SizedBox.shrink();
    }
  }

  Widget _row(AppStrings strings, NbColors colors, MenuItem item, int index) {
    final enabled = _menu.isEnabled(item);
    final home = strings.homeFolder;
    final (
      Glyph glyph,
      String label,
      Widget? trailing,
      Color? ink,
    ) = switch (item) {
      FavoriteItem(:final destination, :final available) => (
        Glyphs.star,
        _label(destination, home),
        available == false ? _gone(strings, colors) : null,
        null,
      ),
      RecentItem(:final destination, :final available) => (
        Glyphs.history,
        _label(destination, home),
        available == false ? _gone(strings, colors) : null,
        null,
      ),
      DefaultFolderItem() => (
        Glyphs.inbox,
        strings.destDefaultFolder,
        Text(
          strings.destDefaultTag,
          style: NbText.caption.copyWith(color: colors.hint),
        ),
        null,
      ),
      RootItem(:final root) => (
        Glyphs.folder,
        root.displayName(homeName: home),
        root.available ? null : _gone(strings, colors),
        null,
      ),
      ExploreItem() => (
        Glyphs.folder,
        strings.destExplore,
        GlyphIcon(Glyphs.chevronRight, size: 14, color: colors.hint),
        colors.primaryInk,
      ),
    };
    final glyphColor = !enabled
        ? colors.hint
        : (item is FavoriteItem || item is ExploreItem
              ? colors.primaryInk
              : colors.textWeak);
    return MouseRegion(
      onEnter: (_) => _menu.focus(index),
      child: NavRow(
        height: 38,
        label: label,
        focusable: false,
        enabled: enabled,
        focused: _menu.focused == index,
        foreground: ink,
        leading: GlyphIcon(glyph, size: 16, color: glyphColor),
        trailing: trailing,
        onTap: () => _choose(item),
      ),
    );
  }

  Widget _gone(AppStrings strings, NbColors colors) => Tooltip(
    message: strings.destNoLongerAvailable,
    child: Semantics(
      label: strings.destNoLongerAvailable,
      image: true,
      child: GlyphIcon(Glyphs.warn, size: 16, color: colors.warning),
    ),
  );

  String _label(SavedDestination destination, String home) => DestinationLabel(
    rootName: destination.rootName,
    home: destination.home,
    path: destination.path,
  ).display(homeName: home);
}

DeviceEntry? _entryOf(NodeState? state, String fingerprint) {
  if (state == null) return null;
  for (final entry in state.entries) {
    if (entry.fingerprint == fingerprint) return entry;
  }
  return null;
}

class _Header extends StatelessWidget {
  const _Header({
    required this.entry,
    required this.name,
    required this.paths,
    required this.strings,
  });

  final DeviceEntry? entry;
  final String name;
  final List<String> paths;
  final AppStrings strings;

  @override
  Widget build(BuildContext context) {
    final colors = NbColors.of(context);
    final first = paths.isEmpty ? null : paths.first;
    final base = first?.split(RegExp(r'[\\/]')).last;
    final isDirectory =
        first != null && FileSystemEntity.isDirectorySync(first);
    return DecoratedBox(
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: colors.menuBorder)),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 14, 14, 10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                DeviceDisc(type: entry?.deviceType, size: 30),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    strings.destTitle(name),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: NbText.bodyStrong.copyWith(
                      color: colors.text,
                      height: 20 / 14,
                    ),
                  ),
                ),
              ],
            ),
            if (base != null) ...[
              const SizedBox(height: 10),
              Row(
                children: [
                  isDirectory
                      ? const FolderIcon(height: 22)
                      : FileIcon(fileName: base, height: 22),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      paths.length > 1
                          ? strings.historyFirstAndMore(base, paths.length - 1)
                          : base,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: NbText.caption.copyWith(
                        color: colors.text,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ],
              ),
            ],
            const SizedBox(height: 8),
            Text(
              strings.destQuestion,
              style: NbText.caption.copyWith(color: colors.textWeak),
            ),
          ],
        ),
      ),
    );
  }
}

class _GroupLabel extends StatelessWidget {
  const _GroupLabel({required this.label, this.note});

  final String label;
  final String? note;

  @override
  Widget build(BuildContext context) {
    final colors = NbColors.of(context);
    final note = this.note;
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 10, 8, 4),
      child: Row(
        children: [
          Flexible(
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: NbText.label.copyWith(
                color: colors.textWeak,
                fontSize: 11.5,
              ),
            ),
          ),
          if (note != null) ...[
            const Spacer(),
            Text(
              note,
              style: NbText.caption.copyWith(
                color: colors.hint,
                fontSize: 11.5,
              ),
            ),
          ],
        ],
      ),
    );
  }
}
