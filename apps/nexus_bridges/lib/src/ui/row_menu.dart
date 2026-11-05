import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'attention.dart';
import 'icons/glyphs.dart';
import 'modal/timeline.dart';
import 'theme/app_theme.dart';
import 'theme/tokens.dart';

final class RowMenuEntry {
  const RowMenuEntry({
    required this.label,
    required this.glyph,
    required this.onSelected,
    this.danger = false,
  });

  final String label;
  final Glyph glyph;
  final VoidCallback onSelected;
  final bool danger;
}

const double rowMenuRadius = 12;
const double rowMenuPadding = 6;
const double rowMenuItemHeight = 36;
const double rowMenuItemRadius = rowMenuRadius - rowMenuPadding;
const double rowMenuMinWidth = 200;
const double _menuMaxWidth = 300;
const double _menuGap = 6;
const double _edgeMargin = 8;
const double _triggerSize = 28;
const double _triggerSlotHeight = 20;
const double rowMenuGlyphSize = 16;
const Duration rowMenuOpenDuration = Duration(milliseconds: 240);
const Duration rowMenuCloseDuration = Duration(milliseconds: 200);
const Duration rowMenuHoverFade = Duration(milliseconds: 200);
const double rowMenuStartScale = 0.96;

class RowMenu extends StatefulWidget {
  const RowMenu({
    required this.tooltip,
    required this.entries,
    this.onOpenChanged,
    super.key,
  });

  final String tooltip;
  final List<RowMenuEntry> entries;
  final ValueChanged<bool>? onOpenChanged;

  @override
  State<RowMenu> createState() => _RowMenuState();
}

class _RowMenuState extends State<RowMenu>
    with SingleTickerProviderStateMixin, CloseOnAttention<RowMenu> {
  final MenuController _menu = MenuController();
  final FocusNode _triggerFocus = FocusNode(debugLabel: 'RowMenu trigger');
  final FocusScopeNode _scope = FocusScopeNode(debugLabel: 'RowMenu');
  late final AnimationController _motion = AnimationController(
    vsync: this,
    duration: rowMenuOpenDuration,
    reverseDuration: rowMenuCloseDuration,
  )..addStatusListener(_onStatus);
  late final Animation<double> _eased = CurvedAnimation(
    parent: _motion,
    curve: labEaseOut,
  );
  late final Animation<double> _scale = Tween<double>(
    begin: rowMenuStartScale,
    end: 1,
  ).animate(_eased);
  bool _byKeyboard = false;
  bool _hovered = false;
  bool _focused = false;

  bool get _open => _motion.status.isForwardOrCompleted;

  @override
  void dispose() {
    _motion.dispose();
    _scope.dispose();
    _triggerFocus.dispose();
    super.dispose();
  }

  void _onStatus(AnimationStatus status) {
    if (mounted) setState(() {});
  }

  @override
  void closeForAttention() {
    if (_open) _menu.close();
  }

  void _toggle({required bool keyboard}) {
    if (_open) {
      _menu.close();
      return;
    }
    _byKeyboard = keyboard;
    Tooltip.dismissAllToolTips();
    _menu.open();
  }

  void _onOpenRequested(Offset? position, VoidCallback showOverlay) {
    showOverlay();
    if (_open) return;
    widget.onOpenChanged?.call(true);
    _motion.forward();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_open) return;
      _scope.requestFocus();
      if (_byKeyboard) _scope.nextFocus();
    });
  }

  void _onCloseRequested(VoidCallback hideOverlay) {
    if (!_open) return;
    widget.onOpenChanged?.call(false);
    if (_scope.hasFocus) {
      if (_byKeyboard) {
        _triggerFocus.requestFocus();
      } else {
        _scope.unfocus();
      }
    }
    _motion.reverse().whenComplete(hideOverlay);
  }

  void _select(RowMenuEntry entry) {
    _menu.close();
    entry.onSelected();
  }

  Widget _buildMenu(BuildContext context, RawMenuOverlayInfo info) {
    final reduceMotion = MediaQuery.disableAnimationsOf(context);
    final height =
        widget.entries.length * rowMenuItemHeight + 2 * rowMenuPadding + 2;
    final anchor = info.anchorRect;
    final overlay = info.overlaySize;
    final fitsBelow =
        anchor.bottom + _menuGap + height <= overlay.height - _edgeMargin;
    final fitsAbove = anchor.top - _menuGap - height >= _edgeMargin;
    final below = fitsBelow || !fitsAbove;
    final top = below
        ? math.max(
            _edgeMargin,
            math.min(
              anchor.bottom + _menuGap,
              overlay.height - _edgeMargin - height,
            ),
          )
        : anchor.top - _menuGap - height;
    final right = math.max(_edgeMargin, overlay.width - anchor.right);
    return Positioned(
      top: top,
      right: right,
      child: TapRegion(
        groupId: info.tapRegionGroupId,
        onTapOutside: (_) => _menu.close(),
        child: ExcludeFocus(
          excluding: !_open,
          child: IgnorePointer(
            ignoring: !_open,
            child: FadeTransition(
              opacity: _eased,
              child: ScaleTransition(
                scale: reduceMotion ? kAlwaysCompleteAnimation : _scale,
                alignment: below ? Alignment.topRight : Alignment.bottomRight,
                child: Shortcuts(
                  shortcuts: const {
                    SingleActivator(LogicalKeyboardKey.escape): DismissIntent(),
                    SingleActivator(LogicalKeyboardKey.arrowDown):
                        NextFocusIntent(),
                    SingleActivator(LogicalKeyboardKey.arrowUp):
                        PreviousFocusIntent(),
                  },
                  child: Actions(
                    actions: {
                      DismissIntent: CallbackAction<DismissIntent>(
                        onInvoke: (_) {
                          _menu.close();
                          return null;
                        },
                      ),
                    },
                    child: FocusScope(
                      node: _scope,
                      child: RowMenuPanel(
                        entries: widget.entries,
                        onSelect: _select,
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildTrigger(
    BuildContext context,
    MenuController controller,
    Widget? child,
  ) {
    final colors = NbColors.of(context);
    final animate = !MediaQuery.disableAnimationsOf(context);
    final lit = _hovered || _open;
    final ink = lit ? colors.text : colors.textWeak;
    return Tooltip(
      message: widget.tooltip,
      child: FocusableActionDetector(
        focusNode: _triggerFocus,
        mouseCursor: SystemMouseCursors.click,
        actions: {
          ActivateIntent: CallbackAction<ActivateIntent>(
            onInvoke: (_) {
              _toggle(keyboard: true);
              return null;
            },
          ),
        },
        onShowFocusHighlight: (value) => setState(() => _focused = value),
        child: MouseRegion(
          onEnter: (_) => setState(() => _hovered = true),
          onExit: (_) => setState(() => _hovered = false),
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () => _toggle(keyboard: false),
            child: SizedBox(
              width: _triggerSize,
              height: _triggerSlotHeight,
              child: OverflowBox(
                minHeight: _triggerSize,
                maxHeight: _triggerSize,
                child: AnimatedContainer(
                  width: _triggerSize,
                  height: _triggerSize,
                  duration: animate ? rowMenuHoverFade : Duration.zero,
                  curve: Curves.ease,
                  decoration: ShapeDecoration(
                    color: lit
                        ? colors.controlHover
                        : colors.controlHover.withValues(alpha: 0),
                    shape: CircleBorder(
                      side: BorderSide(
                        color: _focused
                            ? colors.primary
                            : colors.primary.withValues(alpha: 0),
                        width: 2,
                      ),
                    ),
                  ),
                  child: Center(
                    child: TweenAnimationBuilder<Color?>(
                      tween: ColorTween(end: ink),
                      duration: animate ? rowMenuHoverFade : Duration.zero,
                      curve: Curves.ease,
                      builder: (context, color, _) =>
                          GlyphIcon(Glyphs.more, color: color),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return RawMenuAnchor(
      controller: _menu,
      consumeOutsideTaps: true,
      onOpenRequested: _onOpenRequested,
      onCloseRequested: _onCloseRequested,
      overlayBuilder: _buildMenu,
      builder: _buildTrigger,
    );
  }
}

class RowMenuPanel extends StatelessWidget {
  const RowMenuPanel({
    required this.entries,
    required this.onSelect,
    super.key,
  });

  final List<RowMenuEntry> entries;
  final ValueChanged<RowMenuEntry> onSelect;

  @override
  Widget build(BuildContext context) {
    final colors = NbColors.of(context);
    return Semantics(
      explicitChildNodes: true,
      child: Container(
        key: const ValueKey('row-menu-panel'),
        constraints: const BoxConstraints(
          minWidth: rowMenuMinWidth,
          maxWidth: _menuMaxWidth,
        ),
        padding: const EdgeInsets.all(rowMenuPadding),
        decoration: BoxDecoration(
          color: colors.menuSurface,
          borderRadius: BorderRadius.circular(rowMenuRadius),
          border: Border.all(color: colors.menuBorder),
          boxShadow: colors.menuShadow,
        ),
        child: IntrinsicWidth(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              for (final entry in entries)
                RowMenuItem(entry: entry, onSelect: () => onSelect(entry)),
            ],
          ),
        ),
      ),
    );
  }
}

class RowMenuItem extends StatefulWidget {
  const RowMenuItem({required this.entry, required this.onSelect, super.key});

  final RowMenuEntry entry;
  final VoidCallback onSelect;

  @override
  State<RowMenuItem> createState() => _RowMenuItemState();
}

class _RowMenuItemState extends State<RowMenuItem> {
  bool _hovered = false;
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    final colors = NbColors.of(context);
    final animate = !MediaQuery.disableAnimationsOf(context);
    final entry = widget.entry;
    final lit = _hovered || _focused;
    final fill = entry.danger ? colors.dangerWeak : colors.controlHover;
    final labelInk = entry.danger ? colors.danger : colors.text;
    final glyphInk = entry.danger
        ? colors.danger
        : (lit ? colors.text : colors.textWeak);
    final duration = animate ? rowMenuHoverFade : Duration.zero;
    return Semantics(
      button: true,
      child: FocusableActionDetector(
        mouseCursor: SystemMouseCursors.click,
        actions: {
          ActivateIntent: CallbackAction<ActivateIntent>(
            onInvoke: (_) {
              widget.onSelect();
              return null;
            },
          ),
        },
        onShowFocusHighlight: (value) => setState(() => _focused = value),
        child: MouseRegion(
          onEnter: (_) => setState(() => _hovered = true),
          onExit: (_) => setState(() => _hovered = false),
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: widget.onSelect,
            child: AnimatedContainer(
              height: rowMenuItemHeight,
              duration: duration,
              curve: Curves.ease,
              padding: const EdgeInsets.symmetric(horizontal: 10),
              decoration: BoxDecoration(
                color: lit ? fill : fill.withValues(alpha: 0),
                borderRadius: BorderRadius.circular(rowMenuItemRadius),
              ),
              child: Row(
                children: [
                  TweenAnimationBuilder<Color?>(
                    tween: ColorTween(end: glyphInk),
                    duration: duration,
                    curve: Curves.ease,
                    builder: (context, color, _) => GlyphIcon(
                      entry.glyph,
                      size: rowMenuGlyphSize,
                      color: color,
                      strokeScale: entry.glyph.box / rowMenuGlyphSize,
                    ),
                  ),
                  const SizedBox(width: 10),
                  Flexible(
                    child: Text(
                      entry.label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: NbText.bodySm.copyWith(
                        color: labelInk,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
