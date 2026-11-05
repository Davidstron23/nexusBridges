import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../l10n/app_strings.dart';
import '../icons/folder_icon.dart';
import '../icons/glyphs.dart';
import '../modal/timeline.dart';
import '../settings/settings_field.dart';
import '../theme/app_theme.dart';
import '../theme/tokens.dart';
import 'navigator_controller.dart';

const double navigatorWidth = 392;
const double navigatorBodyHeight = 300;
const Duration _paneMotion = Duration(milliseconds: 420);
const Duration _growMotion = Duration(milliseconds: 420);
const Duration _rowFade = Duration(milliseconds: 180);
const double _paneShift = 0.36;
const double _rowHeight = 40;
const double _rowRadius = 8;
const double _crumbHeight = 28;

class NavIconButton extends StatefulWidget {
  const NavIconButton({
    required this.glyph,
    required this.tooltip,
    required this.onPressed,
    this.size = 34,
    this.glyphSize = 16,
    super.key,
  });

  final Glyph glyph;
  final String tooltip;
  final VoidCallback? onPressed;
  final double size;
  final double glyphSize;

  @override
  State<NavIconButton> createState() => _NavIconButtonState();
}

class _NavIconButtonState extends State<NavIconButton> {
  bool _hovered = false;
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    final colors = NbColors.of(context);
    final animate = !MediaQuery.disableAnimationsOf(context);
    final lit = _hovered || _focused;
    final enabled = widget.onPressed != null;
    return Tooltip(
      message: widget.tooltip,
      child: Semantics(
        button: true,
        enabled: enabled,
        label: widget.tooltip,
        excludeSemantics: true,
        child: FocusableActionDetector(
          enabled: enabled,
          mouseCursor: enabled
              ? SystemMouseCursors.click
              : SystemMouseCursors.basic,
          onShowHoverHighlight: (value) => setState(() => _hovered = value),
          onShowFocusHighlight: (value) => setState(() => _focused = value),
          actions: {
            ActivateIntent: CallbackAction<ActivateIntent>(
              onInvoke: (_) {
                widget.onPressed?.call();
                return null;
              },
            ),
          },
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: widget.onPressed,
            child: AnimatedContainer(
              width: widget.size,
              height: widget.size,
              duration: animate ? _rowFade : Duration.zero,
              curve: Curves.ease,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: lit && enabled
                    ? colors.controlHover
                    : colors.controlHover.withValues(alpha: 0),
                border: _focused
                    ? Border.all(color: colors.primary, width: 2)
                    : null,
              ),
              child: Center(
                child: GlyphIcon(
                  widget.glyph,
                  size: widget.glyphSize,
                  color: lit && enabled ? colors.text : colors.textWeak,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class NavRow extends StatefulWidget {
  const NavRow({
    required this.label,
    required this.onTap,
    this.leading,
    this.trailing,
    this.autofocus = false,
    this.height = _rowHeight,
    this.foreground,
    this.enabled = true,
    this.focused = false,
    this.pop = false,
    this.focusable = true,
    super.key,
  });

  final String label;
  final VoidCallback? onTap;
  final Widget? leading;
  final Widget? trailing;
  final bool autofocus;
  final double height;
  final Color? foreground;
  final bool enabled;
  final bool focused;
  final bool pop;
  final bool focusable;

  @override
  State<NavRow> createState() => _NavRowState();
}

class _NavRowState extends State<NavRow> with SingleTickerProviderStateMixin {
  bool _hovered = false;
  bool _focused = false;
  late final AnimationController _in = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 450),
    value: 1,
  );

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (widget.pop &&
        _in.value == 1 &&
        !MediaQuery.disableAnimationsOf(context)) {
      _in.value = 0;
      _in.forward();
    }
  }

  @override
  void dispose() {
    _in.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = NbColors.of(context);
    final animate = !MediaQuery.disableAnimationsOf(context);
    final lit = (_hovered || _focused || widget.focused) && widget.enabled;
    final ink = widget.foreground ?? colors.text;
    final row = Semantics(
      button: true,
      enabled: widget.enabled,
      label: widget.label,
      excludeSemantics: true,
      child: FocusableActionDetector(
        autofocus: widget.autofocus,
        enabled: widget.enabled && widget.focusable,
        mouseCursor: widget.enabled
            ? SystemMouseCursors.click
            : SystemMouseCursors.basic,
        onShowHoverHighlight: (value) => setState(() => _hovered = value),
        onShowFocusHighlight: (value) => setState(() => _focused = value),
        actions: {
          ActivateIntent: CallbackAction<ActivateIntent>(
            onInvoke: (_) {
              widget.onTap?.call();
              return null;
            },
          ),
        },
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: widget.enabled ? widget.onTap : null,
          child: AnimatedContainer(
            height: widget.height,
            duration: animate ? _rowFade : Duration.zero,
            curve: Curves.ease,
            padding: const EdgeInsets.symmetric(horizontal: 10),
            decoration: BoxDecoration(
              color: lit
                  ? colors.controlHover
                  : colors.controlHover.withValues(alpha: 0),
              borderRadius: BorderRadius.circular(_rowRadius),
              border: _focused
                  ? Border.all(color: colors.menuBorder)
                  : Border.all(color: colors.menuBorder.withValues(alpha: 0)),
            ),
            child: Row(
              children: [
                ?widget.leading,
                if (widget.leading != null) const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    widget.label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: NbText.bodySm.copyWith(
                      color: widget.enabled ? ink : colors.hint,
                      fontWeight: FontWeight.w500,
                      height: 18 / 13,
                    ),
                  ),
                ),
                if (widget.trailing != null) ...[
                  const SizedBox(width: 8),
                  widget.trailing!,
                ],
              ],
            ),
          ),
        ),
      ),
    );
    if (!widget.pop) return row;
    return AnimatedBuilder(
      animation: _in,
      child: row,
      builder: (context, child) {
        final t = labEaseOut.transform(_in.value);
        return Opacity(
          opacity: t,
          child: Transform.translate(
            offset: Offset(0, 8 * (1 - t)),
            child: child,
          ),
        );
      },
    );
  }
}

class NavNotice extends StatelessWidget {
  const NavNotice({required this.text, super.key});

  final String text;

  @override
  Widget build(BuildContext context) {
    final colors = NbColors.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(0, 4, 0, 4),
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: colors.surfaceWeak,
          borderRadius: BorderRadius.circular(10),
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.only(top: 1),
                child: GlyphIcon(Glyphs.info, size: 16, color: colors.textWeak),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  text,
                  style: NbText.caption.copyWith(
                    color: colors.textWeak,
                    fontSize: 12.5,
                    height: 18 / 12.5,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class FolderNavigator extends StatefulWidget {
  const FolderNavigator({
    required this.controller,
    required this.deviceName,
    required this.onPick,
    required this.onExit,
    this.exitTooltip,
    super.key,
  });

  final FolderNavigatorController controller;
  final String deviceName;
  final VoidCallback onPick;
  final VoidCallback onExit;
  final String? exitTooltip;

  @override
  State<FolderNavigator> createState() => _FolderNavigatorState();
}

class _FolderNavigatorState extends State<FolderNavigator> {
  final TextEditingController _name = TextEditingController();
  final FocusNode _nameFocus = FocusNode(debugLabel: 'new folder name');
  final FocusScopeNode _scope = FocusScopeNode(debugLabel: 'navigator');
  bool _creating = false;
  NewFolderProblem? _problem;
  int _depth = 1;
  bool _forward = true;

  FolderNavigatorController get _nav => widget.controller;

  @override
  void initState() {
    super.initState();
    _depth = _nav.stack.length;
    _nav.addListener(_onChanged);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && !_scope.hasFocus) _scope.requestFocus();
    });
  }

  @override
  void didUpdateWidget(FolderNavigator oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller.removeListener(_onChanged);
      widget.controller.addListener(_onChanged);
      _depth = _nav.stack.length;
    }
  }

  @override
  void dispose() {
    _nav.removeListener(_onChanged);
    _name.dispose();
    _nameFocus.dispose();
    _scope.dispose();
    super.dispose();
  }

  void _onChanged() {
    final depth = _nav.stack.length;
    if (depth != _depth && _scope.hasFocus && !_nameFocus.hasFocus) {
      FocusManager.instance.primaryFocus?.unfocus();
    }
    setState(() {
      if (depth != _depth) {
        _forward = depth > _depth;
        _creating = false;
        _problem = null;
        _name.clear();
      }
      _depth = depth;
    });
  }

  void _back() {
    if (_nav.atRoots) {
      widget.onExit();
    } else {
      _nav.back();
    }
  }

  void _toggleCreate() {
    setState(() {
      _creating = !_creating;
      _problem = null;
    });
    if (_creating) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _nameFocus.requestFocus();
      });
    }
  }

  void _create() {
    final name = _name.text.trim();
    final problem = _nav.validateNewFolder(name);
    if (problem != null) {
      setState(() => _problem = problem);
      return;
    }
    _nav.createVirtual(name);
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    if (event.logicalKey != LogicalKeyboardKey.backspace) {
      return KeyEventResult.ignored;
    }
    final focused = FocusManager.instance.primaryFocus?.context;
    if (focused?.findAncestorWidgetOfExactType<EditableText>() != null) {
      return KeyEventResult.ignored;
    }
    _back();
    return KeyEventResult.handled;
  }

  @override
  Widget build(BuildContext context) {
    final strings = AppStringsDelegate.of(context);
    final colors = NbColors.of(context);
    final nav = _nav;
    final isSend = nav.mode == NavigatorMode.send;
    final level = nav.stack.last;
    final destination = nav.current;
    final canPick =
        !nav.atRoots &&
        nav.status != NavStatus.loading &&
        (nav.mode != NavigatorMode.favorite || !nav.insideNew);
    final pickLabel = nav.mode == NavigatorMode.favorite
        ? strings.navSaveFavorite
        : strings.navSendHere;
    return Focus(
      onKeyEvent: _onKey,
      skipTraversal: true,
      child: Shortcuts(
        shortcuts: const {
          SingleActivator(LogicalKeyboardKey.arrowDown): NextFocusIntent(),
          SingleActivator(LogicalKeyboardKey.arrowUp): PreviousFocusIntent(),
        },
        child: SizedBox(
          width: navigatorWidth,
          child: FocusScope(
            node: _scope,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _header(strings, colors),
                SizedBox(
                  height: navigatorBodyHeight,
                  child: ClipRect(child: _body(strings, level)),
                ),
                if (isSend) _newFolderRow(strings, colors),
                _footer(
                  strings,
                  colors,
                  canPick,
                  pickLabel,
                  isSend,
                  destination,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _header(AppStrings strings, NbColors colors) {
    final nav = _nav;
    final crumbs = <Widget>[
      _Crumb(
        label: widget.deviceName,
        last: nav.atRoots,
        onTap: nav.atRoots ? null : () => nav.backTo(0),
      ),
      for (var i = 1; i < nav.stack.length; i++) ...[
        GlyphIcon(Glyphs.chevronRight, size: 12, color: colors.hint),
        _Crumb(
          label: nav.stack[i].name ?? '',
          last: i == nav.stack.length - 1,
          onTap: i == nav.stack.length - 1 ? null : () => nav.backTo(i),
        ),
      ],
    ];
    return DecoratedBox(
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: colors.menuBorder)),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(10, 12, 12, 10),
        child: Row(
          children: [
            NavIconButton(
              glyph: Glyphs.back,
              tooltip: strings.navBack,
              onPressed: _back,
              glyphSize: 18,
            ),
            const SizedBox(width: 8),
            Expanded(
              child: ClipRect(
                child: SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  reverse: true,
                  physics: const NeverScrollableScrollPhysics(),
                  child: Row(mainAxisSize: MainAxisSize.min, children: crumbs),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _body(AppStrings strings, NavLevel level) {
    final nav = _nav;
    final animate = !MediaQuery.disableAnimationsOf(context);
    final key = ValueKey<String>(
      '${nav.stack.length}:${level.name}:${level.isNew}',
    );
    return AnimatedSwitcher(
      duration: animate ? _paneMotion : Duration.zero,
      switchInCurve: labEaseOut,
      switchOutCurve: labEaseOut,
      layoutBuilder: (current, previous) =>
          Stack(fit: StackFit.expand, children: [...previous, ?current]),
      transitionBuilder: (child, animation) {
        final incoming = child.key == key;
        final forward = _forward;
        final begin = incoming
            ? (forward ? _paneShift : -_paneShift)
            : (forward ? -_paneShift * 0.83 : _paneShift * 0.83);
        return AnimatedBuilder(
          animation: animation,
          child: child,
          builder: (context, child) {
            final t = animation.value;
            final shift = incoming ? begin * (1 - t) : begin * (1 - t);
            return Opacity(
              opacity: t,
              child: FractionalTranslation(
                translation: Offset(shift, 0),
                child: child,
              ),
            );
          },
        );
      },
      child: KeyedSubtree(key: key, child: _pane(strings, level)),
    );
  }

  Widget _pane(AppStrings strings, NavLevel level) {
    final nav = _nav;
    final colors = NbColors.of(context);
    final rows = <Widget>[];
    final status = nav.status;
    final notice = switch (status) {
      NavStatus.gone => strings.navGone,
      NavStatus.busy => strings.navBusy(widget.deviceName),
      NavStatus.unreadable => strings.navUnreadable(widget.deviceName),
      _ => null,
    };
    if (notice != null) rows.add(NavNotice(text: notice));
    if (level.isNew) {
      return Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(6, 6, 6, 0),
            child: _VirtualRow(
              name: level.name ?? '',
              note: strings.navWillBeCreated,
            ),
          ),
          Expanded(
            child: _EmptyPane(
              glyph: Glyphs.folderPlus,
              title: strings.navNewFolder,
              text: strings.navNewFolderEmpty(widget.deviceName),
            ),
          ),
        ],
      );
    }
    if (level.folders.isEmpty) {
      return Column(
        children: [
          if (notice != null)
            Padding(
              padding: const EdgeInsets.all(6),
              child: NavNotice(text: notice),
            ),
          Expanded(
            child: _EmptyPane(
              glyph: Glyphs.folder,
              title: nav.atRoots ? strings.navChoose : strings.navNoSubfolders,
              text: null,
            ),
          ),
        ],
      );
    }
    for (var i = 0; i < level.folders.length; i++) {
      final name = level.folders[i];
      rows.add(
        NavRow(
          key: ValueKey('nav-row-$i-$name'),
          label: name,
          autofocus: i == 0 && notice == null,
          leading: const FolderIcon(height: 18),
          trailing: GlyphIcon(
            Glyphs.chevronRight,
            size: 14,
            color: colors.hint,
          ),
          onTap: status == NavStatus.loading ? null : () => _nav.enter(name),
        ),
      );
    }
    if (level.more) rows.add(NavNotice(text: strings.navMore));
    if (level.partial) rows.add(NavNotice(text: strings.navPartial));
    return ListView(padding: const EdgeInsets.all(6), children: rows);
  }

  Widget _newFolderRow(AppStrings strings, NbColors colors) {
    final animate = !MediaQuery.disableAnimationsOf(context);
    final problem = _problem;
    final message = switch (problem) {
      NewFolderProblem.invalid => strings.navNameInvalid,
      NewFolderProblem.exists => strings.navNameExists,
      null => null,
    };
    return TweenAnimationBuilder<double>(
      tween: Tween<double>(end: _creating && _nav.canCreateFolder ? 1 : 0),
      duration: animate ? _growMotion : Duration.zero,
      curve: labEaseOut,
      builder: (context, t, child) {
        if (t <= 0) return const SizedBox(width: double.infinity);
        return ClipRect(
          child: Align(
            alignment: Alignment.topCenter,
            heightFactor: t,
            child: Opacity(opacity: t, child: child),
          ),
        );
      },
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 6, 12, 4),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Expanded(
                  child: SettingsTextField(
                    controller: _name,
                    focusNode: _nameFocus,
                    label: strings.navNewFolderPlaceholder,
                    hint: strings.navNewFolderPlaceholder,
                    invalid: problem != null,
                    onChanged: (_) {
                      if (_problem != null) setState(() => _problem = null);
                    },
                    onSubmit: _create,
                  ),
                ),
                const SizedBox(width: 6),
                FilledButton(
                  style: smallButton,
                  onPressed: _create,
                  child: Text(strings.navCreate),
                ),
              ],
            ),
            if (message != null)
              Padding(
                padding: const EdgeInsets.fromLTRB(2, 4, 2, 0),
                child: Text(
                  message,
                  style: NbText.caption.copyWith(color: colors.danger),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _footer(
    AppStrings strings,
    NbColors colors,
    bool canPick,
    String pickLabel,
    bool isSend,
    Object? destination,
  ) {
    final nav = _nav;
    final level = nav.stack.last;
    return DecoratedBox(
      decoration: BoxDecoration(
        border: Border(top: BorderSide(color: colors.menuBorder)),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
        child: Row(
          children: [
            if (isSend) ...[
              TextButton.icon(
                style: smallButton.merge(
                  TextButton.styleFrom(foregroundColor: colors.textWeak),
                ),
                onPressed: nav.canCreateFolder ? _toggleCreate : null,
                icon: const GlyphIcon(Glyphs.folderPlus, size: 14),
                label: Text(strings.navNewFolder),
              ),
              const SizedBox(width: 8),
            ],
            Expanded(
              child: Text(
                nav.atRoots
                    ? strings.navChoose
                    : strings.navIn(level.name ?? ''),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: NbText.caption.copyWith(color: colors.textWeak),
              ),
            ),
            const SizedBox(width: 8),
            FilledButton(
              style: smallButton,
              onPressed: canPick ? widget.onPick : null,
              child: Text(pickLabel),
            ),
          ],
        ),
      ),
    );
  }
}

class _Crumb extends StatefulWidget {
  const _Crumb({required this.label, required this.last, required this.onTap});

  final String label;
  final bool last;
  final VoidCallback? onTap;

  @override
  State<_Crumb> createState() => _CrumbState();
}

class _CrumbState extends State<_Crumb> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final colors = NbColors.of(context);
    final animate = !MediaQuery.disableAnimationsOf(context);
    final enabled = widget.onTap != null;
    final lit = _hovered && enabled;
    return MouseRegion(
      cursor: enabled ? SystemMouseCursors.click : SystemMouseCursors.basic,
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.onTap,
        child: AnimatedContainer(
          height: _crumbHeight,
          duration: animate ? _rowFade : Duration.zero,
          padding: const EdgeInsets.symmetric(horizontal: 7),
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: lit
                ? colors.controlHover
                : colors.controlHover.withValues(alpha: 0),
            borderRadius: BorderRadius.circular(6),
          ),
          child: Text(
            widget.label,
            maxLines: 1,
            style: NbText.button.copyWith(
              color: widget.last || lit ? colors.text : colors.textWeak,
            ),
          ),
        ),
      ),
    );
  }
}

class _VirtualRow extends StatelessWidget {
  const _VirtualRow({required this.name, required this.note});

  final String name;
  final String note;

  @override
  Widget build(BuildContext context) {
    final colors = NbColors.of(context);
    return DecoratedBox(
      decoration: BoxDecoration(
        color: colors.primaryWeak,
        borderRadius: BorderRadius.circular(_rowRadius),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        child: Row(
          children: [
            const FolderIcon(height: 18),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: NbText.bodySm.copyWith(
                      color: colors.text,
                      fontWeight: FontWeight.w500,
                      height: 18 / 13,
                    ),
                  ),
                  Text(
                    note,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: NbText.caption.copyWith(color: colors.textWeak),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _EmptyPane extends StatelessWidget {
  const _EmptyPane({
    required this.glyph,
    required this.title,
    required this.text,
  });

  final Glyph glyph;
  final String title;
  final String? text;

  @override
  Widget build(BuildContext context) {
    final colors = NbColors.of(context);
    final text = this.text;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            GlyphIcon(glyph, size: 28, color: colors.hint),
            const SizedBox(height: 6),
            Text(
              title,
              textAlign: TextAlign.center,
              style: NbText.bodySm.copyWith(
                color: colors.text,
                fontWeight: FontWeight.w600,
              ),
            ),
            if (text != null) ...[
              const SizedBox(height: 6),
              Text(
                text,
                textAlign: TextAlign.center,
                style: NbText.caption.copyWith(color: colors.textWeak),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
