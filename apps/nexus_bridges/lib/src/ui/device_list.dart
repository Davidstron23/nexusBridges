import 'package:flutter/material.dart';
import 'package:nexus_bridges_core/nexus_bridges_core.dart';

import '../app_controller.dart';
import '../l10n/app_strings.dart';
import 'icons/device_disc.dart';
import 'icons/glyphs.dart';
import 'send_action.dart';
import 'theme/app_theme.dart';
import 'theme/components.dart';
import 'theme/tokens.dart';
import 'unpair_modal.dart';

DiscTone discToneFor(NodeState state, DeviceEntry entry) {
  final incoming = state.incoming;
  if (incoming != null &&
      incoming.peerFingerprint == entry.fingerprint &&
      (incoming.stage == IncomingStage.warning ||
          incoming.stage == IncomingStage.folderQuestion)) {
    return DiscTone.asking;
  }
  if (state.outgoing?.peerFingerprint == entry.fingerprint) {
    return DiscTone.sending;
  }
  if (!entry.visible) return DiscTone.notVisible;
  return DiscTone.idle;
}

class DeviceList extends StatelessWidget {
  const DeviceList({
    required this.controller,
    required this.state,
    required this.hovered,
    super.key,
  });

  final AppController controller;
  final NodeState state;
  final ValueNotifier<String?> hovered;

  @override
  Widget build(BuildContext context) {
    final strings = AppStringsDelegate.of(context);
    final colors = NbColors.of(context);
    if (state.entries.isEmpty) {
      return _EmptyDevices(
        strings: strings,
        suggestRescan: state.suggestRescan,
        scanning: state.scanning,
        onRescan: controller.rescan,
      );
    }
    final paired = state.entries.where((entry) => entry.paired).toList();
    final unpaired = state.entries.where((entry) => !entry.paired).toList();
    Widget rowOf(DeviceEntry entry) => DeviceRow(
      key: ValueKey(entry.fingerprint),
      controller: controller,
      entry: entry,
      tone: discToneFor(state, entry),
      hovered: hovered,
    );
    final divider = SizedBox(
      height: 1,
      child: ColoredBox(color: colors.borderWeak),
    );
    final children = <Widget>[
      for (var i = 0; i < paired.length; i++) ...[
        if (i > 0) divider,
        rowOf(paired[i]),
      ],
      if (unpaired.isNotEmpty) ...[
        Container(
          padding: const EdgeInsets.fromLTRB(14, 12, 14, 4),
          decoration: paired.isEmpty
              ? null
              : BoxDecoration(
                  border: Border(top: BorderSide(color: colors.borderWeak)),
                ),
          child: Text(
            strings.sectionUnpaired,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: NbText.label.copyWith(color: colors.textWeak),
          ),
        ),
        for (var i = 0; i < unpaired.length; i++) ...[
          if (i > 0) divider,
          rowOf(unpaired[i]),
        ],
      ],
    ];
    return NbCard(
      padding: EdgeInsets.zero,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: children,
      ),
    );
  }
}

enum _RowAction { toggleMine, unpair }

class DeviceRow extends StatelessWidget {
  const DeviceRow({
    required this.controller,
    required this.entry,
    required this.tone,
    required this.hovered,
    super.key,
  });

  final AppController controller;
  final DeviceEntry entry;
  final DiscTone tone;
  final ValueNotifier<String?> hovered;

  Future<void> _pair(BuildContext context) async {
    final result = await controller.pair(entry.fingerprint);
    if (!context.mounted) return;
    final strings = AppStringsDelegate.of(context);
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
    await confirmUnpairDevice(
      context,
      name: entry.displayName,
      type: entry.deviceType,
      onConfirm: () => controller.unpair(entry.fingerprint),
    );
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
    final strings = AppStringsDelegate.of(context);
    final colors = NbColors.of(context);
    final caption = NbText.caption.copyWith(color: colors.textWeak);
    final bodySm = NbText.bodySm.copyWith(color: colors.text);
    final possiblyReplaces = entry.possiblyReplaces;
    final explanation = !entry.paired || entry.canSendFile
        ? null
        : entry.mismatch
        ? strings.sendNeedsPairAgain
        : strings.sendNeedsVisible;
    final (String chipLabel, ChipTone chipTone) = entry.paired
        ? (
            entry.mine ? strings.chipMine : strings.chipForeign,
            entry.mine ? ChipTone.run : ChipTone.foreign,
          )
        : (
            entry.ignored ? strings.ignoredLabel : strings.notPairedLabel,
            ChipTone.wait,
          );
    final actions = <Widget>[
      if (entry.paired)
        FilledButton.tonalIcon(
          style: smallButton,
          icon: const GlyphIcon(Glyphs.send, size: 14),
          label: Text(strings.sendFileButton),
          onPressed: entry.canSendFile
              ? () => startSend(context, controller, entry.fingerprint)
              : null,
        ),
      if (entry.paired && entry.mismatch) ...[
        OutlinedButton(
          style: smallButton,
          onPressed: () => _unpair(context),
          child: Text(strings.removeButton),
        ),
        FilledButton.tonal(
          style: smallButton,
          onPressed: () => _pair(context),
          child: Text(strings.pairAgainButton),
        ),
      ] else if (entry.canPair)
        OutlinedButton.icon(
          style: smallButton,
          icon: const GlyphIcon(Glyphs.link, size: 14),
          label: Text(strings.pairButton),
          onPressed: () => _pair(context),
        ),
      if (entry.ignored)
        TextButton(
          style: smallButton,
          onPressed: () => controller.unignore(entry.fingerprint),
          child: Text(strings.unignoreButton),
        ),
    ];
    return MouseRegion(
      onEnter: (_) => hovered.value = entry.fingerprint,
      onExit: (_) {
        if (hovered.value == entry.fingerprint) hovered.value = null;
      },
      child: ValueListenableBuilder<String?>(
        valueListenable: hovered,
        builder: (context, current, child) => ColoredBox(
          color: current == entry.fingerprint
              ? colors.surfaceWeak
              : Colors.transparent,
          child: child,
        ),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(14, 10, 12, 10),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              DeviceDisc(type: entry.deviceType, tone: tone),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            entry.displayName,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: NbText.bodyStrong.copyWith(
                              fontSize: 13,
                              color: colors.text,
                            ),
                          ),
                        ),
                        if (entry.paired)
                          SizedBox(
                            width: 28,
                            height: 20,
                            child: PopupMenuButton<_RowAction>(
                              tooltip: strings.moreOptions,
                              padding: EdgeInsets.zero,
                              icon: const GlyphIcon(Glyphs.more),
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
                          ),
                      ],
                    ),
                    const SizedBox(height: 3),
                    Row(
                      children: [
                        Flexible(
                          child: StatusChip(
                            height: 20,
                            label: chipLabel,
                            tone: chipTone,
                          ),
                        ),
                        const SizedBox(width: 8),
                        Container(
                          width: 6,
                          height: 6,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: entry.visible
                                ? colors.successInk
                                : colors.hint,
                          ),
                        ),
                        const SizedBox(width: 4),
                        Flexible(
                          child: Text(
                            entry.visible
                                ? strings.visibleLabel
                                : strings.notVisibleLabel,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: caption,
                          ),
                        ),
                      ],
                    ),
                    if (explanation != null) ...[
                      const SizedBox(height: 4),
                      Text(explanation, style: caption),
                    ],
                    if (entry.paired && entry.mismatch) ...[
                      const SizedBox(height: 4),
                      Text(strings.mismatchWarning, style: bodySm),
                    ],
                    if (possiblyReplaces != null) ...[
                      const SizedBox(height: 4),
                      Text(
                        strings.possibleReinstall(possiblyReplaces),
                        style: bodySm,
                      ),
                    ],
                    if (actions.isNotEmpty) ...[
                      const SizedBox(height: 8),
                      Wrap(spacing: 8, runSpacing: 4, children: actions),
                    ],
                  ],
                ),
              ),
            ],
          ),
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
