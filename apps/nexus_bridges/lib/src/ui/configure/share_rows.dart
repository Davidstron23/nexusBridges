import 'package:flutter/material.dart';
import 'package:nexus_bridges_core/nexus_bridges_core.dart';

import '../../l10n/app_strings.dart';
import '../icons/folder_icon.dart';
import '../icons/glyphs.dart';
import '../settings/inline_confirm.dart';
import '../settings/settings_rows.dart';
import '../theme/app_theme.dart';
import '../theme/tokens.dart';
import '../../app_controller.dart';

String shareDisplayLabel(AppStrings strings, ShareView share) =>
    share.home ? strings.homeFolder : share.label;

String? driveLetterOf(String path) {
  if (path.length < 2 || path[1] != ':') return null;
  final letter = path.substring(0, 2).toUpperCase();
  return letter == 'C:' ? null : letter;
}

String shareRefusalText(AppStrings strings, ShareRefusal reason) =>
    switch (reason) {
      ShareRefusal.networkDrive => strings.shareRefusedNetwork,
      ShareRefusal.adminShare => strings.shareRefusedAdminShare,
      ShareRefusal.unknownDrive => strings.shareRefusedUnknownDrive,
      ShareRefusal.forbidden => strings.shareRefusedForbidden,
      ShareRefusal.appData => strings.shareRefusedAppData,
      ShareRefusal.tempFolder => strings.shareRefusedTemp,
      ShareRefusal.tooLong => strings.shareRefusedTooLong,
      ShareRefusal.missing => strings.shareRefusedMissing,
      ShareRefusal.alreadyAdded => strings.shareRefusedAlready,
      ShareRefusal.full => strings.shareRefusedFull,
    };

class RowRemoveButton extends StatefulWidget {
  const RowRemoveButton({
    required this.tooltip,
    required this.onPressed,
    super.key,
  });

  final String tooltip;
  final VoidCallback onPressed;

  @override
  State<RowRemoveButton> createState() => _RowRemoveButtonState();
}

class _RowRemoveButtonState extends State<RowRemoveButton> {
  bool _hovered = false;
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    final colors = NbColors.of(context);
    final animate = !MediaQuery.disableAnimationsOf(context);
    return Tooltip(
      message: widget.tooltip,
      child: Semantics(
        button: true,
        label: widget.tooltip,
        excludeSemantics: true,
        child: FocusableActionDetector(
          mouseCursor: SystemMouseCursors.click,
          onShowHoverHighlight: (value) => setState(() => _hovered = value),
          onShowFocusHighlight: (value) => setState(() => _focused = value),
          actions: {
            ActivateIntent: CallbackAction<ActivateIntent>(
              onInvoke: (_) {
                widget.onPressed();
                return null;
              },
            ),
          },
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: widget.onPressed,
            child: AnimatedContainer(
              width: 28,
              height: 28,
              duration: animate
                  ? const Duration(milliseconds: 200)
                  : Duration.zero,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: _hovered
                    ? colors.controlHover
                    : colors.controlHover.withValues(alpha: 0),
                border: _focused
                    ? Border.all(color: colors.primary, width: 2)
                    : null,
              ),
              child: Center(
                child: GlyphIcon(
                  Glyphs.close,
                  size: 14,
                  color: _hovered ? colors.text : colors.textWeak,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class RevealOnHover extends StatefulWidget {
  const RevealOnHover({required this.builder, super.key});

  final Widget Function(BuildContext context, double visible) builder;

  @override
  State<RevealOnHover> createState() => _RevealOnHoverState();
}

class _RevealOnHoverState extends State<RevealOnHover> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final animate = !MediaQuery.disableAnimationsOf(context);
    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: Focus(
        canRequestFocus: false,
        skipTraversal: true,
        onFocusChange: (focused) {
          if (focused != _hovered) setState(() => _hovered = focused);
        },
        child: TweenAnimationBuilder<double>(
          tween: Tween<double>(end: _hovered ? 1 : 0),
          duration: animate ? const Duration(milliseconds: 200) : Duration.zero,
          builder: (context, value, _) => widget.builder(context, value),
        ),
      ),
    );
  }
}

class ShareRow extends StatelessWidget {
  const ShareRow({
    required this.share,
    required this.divider,
    required this.onRemove,
    super.key,
  });

  final ShareView share;
  final bool divider;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    final strings = AppStringsDelegate.of(context);
    final colors = NbColors.of(context);
    final letter = driveLetterOf(share.path);
    final removable = share.drive == DriveKind.removable;
    final unavailable = share.available == false;
    final chip = removable ? strings.chipRemovable : letter;
    return RevealOnHover(
      builder: (context, visible) => DecoratedBox(
        decoration: BoxDecoration(
          border: divider
              ? Border(top: BorderSide(color: colors.borderWeak))
              : null,
        ),
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 64),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(14, 13, 12, 13),
            child: Row(
              children: [
                const Padding(
                  padding: EdgeInsets.symmetric(horizontal: 2),
                  child: FolderIcon(height: 24),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        shareDisplayLabel(strings, share),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: NbText.bodySm.copyWith(
                          color: unavailable ? colors.textWeak : colors.text,
                          fontSize: 13.5,
                          height: 18 / 13.5,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      Padding(
                        padding: const EdgeInsets.only(top: 1),
                        child: Text(
                          share.path,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: NbText.caption.copyWith(
                            color: colors.textWeak,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                if (unavailable) ...[
                  const SizedBox(width: 8),
                  Tooltip(
                    message: strings.shareUnavailable,
                    child: Semantics(
                      label: strings.shareUnavailable,
                      image: true,
                      child: GlyphIcon(
                        Glyphs.warn,
                        size: 16,
                        color: colors.warning,
                      ),
                    ),
                  ),
                ],
                if (chip != null) ...[
                  const SizedBox(width: 8),
                  _NeutralChip(label: chip),
                ],
                const SizedBox(width: 4),
                Opacity(
                  opacity: visible,
                  child: RowRemoveButton(
                    tooltip: strings.shareRemoveTooltip,
                    onPressed: onRemove,
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

class _NeutralChip extends StatelessWidget {
  const _NeutralChip({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    final colors = NbColors.of(context);
    return DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: colors.border),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
        child: Text(
          label,
          maxLines: 1,
          style: NbText.badge.copyWith(color: colors.textWeak),
        ),
      ),
    );
  }
}

class FavoriteRow extends StatelessWidget {
  const FavoriteRow({
    required this.destination,
    required this.divider,
    required this.onRemove,
    super.key,
  });

  final SavedDestination destination;
  final bool divider;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    final strings = AppStringsDelegate.of(context);
    final colors = NbColors.of(context);
    final label = DestinationLabel(
      rootName: destination.rootName,
      home: destination.home,
      path: destination.path,
    );
    final root = label.display(homeName: strings.homeFolder);
    final parts = root.split(r'\');
    final title = parts.last;
    return RevealOnHover(
      builder: (context, visible) => DecoratedBox(
        decoration: BoxDecoration(
          border: divider
              ? Border(top: BorderSide(color: colors.borderWeak))
              : null,
        ),
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 64),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(14, 13, 12, 13),
            child: Row(
              children: [
                DecoratedBox(
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(9),
                    color: colors.card,
                    border: Border.all(color: colors.primaryWeak),
                    boxShadow: colors.cardShadow,
                  ),
                  child: SizedBox.square(
                    dimension: 32,
                    child: Center(
                      child: GlyphIcon(
                        Glyphs.star,
                        size: 16,
                        color: colors.primaryInk,
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: NbText.bodySm.copyWith(
                          color: colors.text,
                          fontSize: 13.5,
                          height: 18 / 13.5,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      Padding(
                        padding: const EdgeInsets.only(top: 1),
                        child: Text(
                          parts.join(' › '),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: NbText.caption.copyWith(
                            color: colors.textWeak,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 4),
                Opacity(
                  opacity: visible,
                  child: RowRemoveButton(
                    tooltip: strings.favoriteRemoveTooltip,
                    onPressed: onRemove,
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

class SharesBody extends StatefulWidget {
  const SharesBody({
    required this.controller,
    required this.fingerprint,
    required this.shares,
    super.key,
  });

  final AppController controller;
  final String fingerprint;
  final List<ShareView> shares;

  @override
  State<SharesBody> createState() => _SharesBodyState();
}

class _SharesBodyState extends State<SharesBody> {
  ShareNeedsConfirmation? _pending;
  ShareRefusal? _refusal;
  bool _failed = false;
  bool _busy = false;
  bool _disposed = false;

  @override
  void dispose() {
    _disposed = true;
    final pending = _pending;
    if (pending != null) {
      widget.controller.cancelPendingShare(pending.pendingId);
    }
    super.dispose();
  }

  Future<void> _add() async {
    if (_busy) return;
    _dropPending();
    setState(() {
      _busy = true;
      _refusal = null;
      _failed = false;
    });
    final outcome = await widget.controller.addShare(widget.fingerprint);
    if (_disposed) {
      if (outcome is ShareNeedsConfirmation) {
        widget.controller.cancelPendingShare(outcome.pendingId);
      }
      return;
    }
    _apply(outcome);
  }

  void _apply(ShareAddOutcome outcome) {
    setState(() {
      _busy = false;
      switch (outcome) {
        case ShareAdded():
        case SharePickCancelled():
          _pending = null;
        case ShareRefused(:final reason):
          _pending = null;
          _refusal = reason;
        case ShareNeedsConfirmation():
          _pending = outcome;
      }
    });
  }

  void _dropPending() {
    final pending = _pending;
    if (pending == null) return;
    widget.controller.cancelPendingShare(pending.pendingId);
    _pending = null;
  }

  Future<void> _confirm() async {
    final pending = _pending;
    if (pending == null || _busy) return;
    setState(() => _busy = true);
    final outcome = await widget.controller.confirmShare(
      widget.fingerprint,
      pending.pendingId,
    );
    if (_disposed) return;
    setState(() {
      _busy = false;
      _pending = null;
      if (outcome is ShareRefused) {
        _refusal = outcome.reason;
      } else if (outcome is! ShareAdded) {
        _failed = true;
      }
    });
  }

  void _cancel() {
    setState(_dropPending);
  }

  @override
  Widget build(BuildContext context) {
    final strings = AppStringsDelegate.of(context);
    final colors = NbColors.of(context);
    final pending = _pending;
    final refusal = _refusal;
    final full = widget.shares.length >= 16;
    final message = refusal != null
        ? shareRefusalText(strings, refusal)
        : (_failed ? strings.shareFailed : null);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SettingsRowList<ShareView>(
          items: widget.shares,
          idOf: (share) => share.rootId,
          emptyText: strings.sharesEmpty,
          rowBuilder: (context, share, index) => ShareRow(
            share: share,
            divider: index > 0,
            onRemove: () =>
                widget.controller.removeShare(widget.fingerprint, share.rootId),
          ),
        ),
        const SizedBox(height: 10),
        Align(
          alignment: Alignment.centerLeft,
          child: OutlinedButton.icon(
            style: smallButton,
            onPressed: _busy || full ? null : _add,
            icon: const GlyphIcon(Glyphs.folderPlus, size: 14),
            label: Text(strings.sharesAdd),
          ),
        ),
        InlineConfirm(
          open: pending != null,
          ice: true,
          message: Text(
            pending == null
                ? ''
                : (pending.cloud
                      ? strings.shareCloudConfirm
                      : strings.shareNoMarkConfirm),
          ),
          confirmLabel: strings.shareAddAnyway,
          cancelLabel: strings.cancelButton,
          onConfirm: _confirm,
          onCancel: _cancel,
        ),
        if (message != null)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text(
              message,
              style: NbText.caption.copyWith(
                color: colors.danger,
                fontSize: 12.5,
                height: 18 / 12.5,
              ),
            ),
          ),
        if (full && message == null)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text(
              strings.shareRefusedFull,
              style: NbText.caption.copyWith(color: colors.textWeak),
            ),
          ),
      ],
    );
  }
}
