import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:nexus_bridges_core/nexus_bridges_core.dart';

import '../l10n/app_strings.dart';
import 'icons/glyphs.dart';
import 'modal/timeline.dart';
import 'row_menu.dart';
import 'soft_button.dart';

const double _menuGap = 6;
const double _edgeMargin = 8;
const int _shortFingerprintLength = 8;

String deviceNameIn(NodeState state, String fingerprint) {
  for (final entry in state.entries) {
    if (entry.fingerprint == fingerprint) return entry.displayName;
  }
  return fingerprint.length > _shortFingerprintLength
      ? fingerprint.substring(0, _shortFingerprintLength)
      : fingerprint;
}

String? sendExplanation(
  AppStrings strings,
  NodeState state,
  DeviceEntry entry,
) {
  if (!entry.paired) return null;
  if (!entry.canSendFile) {
    return entry.mismatch
        ? strings.sendNeedsPairAgain
        : strings.sendNeedsVisible;
  }
  final target = state.sendingTo;
  if (target != null && target != entry.fingerprint) {
    return strings.waitForQueues(deviceNameIn(state, target));
  }
  return null;
}

class SendMenuButton extends StatefulWidget {
  const SendMenuButton({
    required this.enabled,
    required this.onFiles,
    required this.onFolders,
    this.height = 28,
    this.onOpenChanged,
    super.key,
  });

  final bool enabled;
  final VoidCallback onFiles;
  final VoidCallback onFolders;
  final double height;
  final ValueChanged<bool>? onOpenChanged;

  @override
  State<SendMenuButton> createState() => _SendMenuButtonState();
}

class _SendMenuButtonState extends State<SendMenuButton>
    with SingleTickerProviderStateMixin {
  final MenuController _menu = MenuController();
  final FocusScopeNode _scope = FocusScopeNode(debugLabel: 'SendMenu');
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
  FocusNode? _returnFocus;
  bool _byKeyboard = false;

  bool get _open => _motion.status.isForwardOrCompleted;

  @override
  void didUpdateWidget(SendMenuButton oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.enabled && !widget.enabled && _open) _menu.close();
  }

  @override
  void dispose() {
    _motion.dispose();
    _scope.dispose();
    super.dispose();
  }

  void _onStatus(AnimationStatus status) {
    if (mounted) setState(() {});
  }

  void _toggle() {
    if (_open) {
      _menu.close();
      return;
    }
    final pressed = HardwareKeyboard.instance.logicalKeysPressed;
    _byKeyboard =
        pressed.contains(LogicalKeyboardKey.enter) ||
        pressed.contains(LogicalKeyboardKey.numpadEnter) ||
        pressed.contains(LogicalKeyboardKey.space);
    _returnFocus = FocusManager.instance.primaryFocus;
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
      final back = _returnFocus;
      if (_byKeyboard && back != null && back.canRequestFocus) {
        back.requestFocus();
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
    final strings = AppStringsDelegate.of(context);
    final reduceMotion = MediaQuery.disableAnimationsOf(context);
    final entries = [
      RowMenuEntry(
        label: strings.sendFilesOption,
        glyph: Glyphs.files,
        onSelected: widget.onFiles,
      ),
      RowMenuEntry(
        label: strings.sendFoldersOption,
        glyph: Glyphs.folder,
        onSelected: widget.onFolders,
      ),
    ];
    final height = entries.length * rowMenuItemHeight + 2 * rowMenuPadding + 2;
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
    final left = math.max(_edgeMargin, anchor.left);
    return Positioned(
      top: top,
      left: left,
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
                alignment: below ? Alignment.topLeft : Alignment.bottomLeft,
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
                        key: const ValueKey('send-menu-panel'),
                        entries: entries,
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

  @override
  Widget build(BuildContext context) {
    final strings = AppStringsDelegate.of(context);
    return RawMenuAnchor(
      controller: _menu,
      consumeOutsideTaps: true,
      onOpenRequested: _onOpenRequested,
      onCloseRequested: _onCloseRequested,
      overlayBuilder: _buildMenu,
      child: Semantics(
        expanded: _open,
        child: SoftButton(
          glyph: Glyphs.send,
          label: strings.sendEllipsis,
          height: widget.height,
          onPressed: widget.enabled ? _toggle : null,
        ),
      ),
    );
  }
}
