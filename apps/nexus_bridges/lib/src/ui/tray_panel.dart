import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:nexus_bridges_core/nexus_bridges_core.dart';

import '../app_controller.dart';
import '../l10n/app_strings.dart';
import 'activity_cards.dart' show FittedName;
import 'icons/file_icon.dart';
import 'icons/folder_icon.dart';
import 'icons/glyphs.dart';
import 'modal/timeline.dart';
import 'queue_card.dart' show RemoveButton;
import 'send_action.dart';
import 'send_menu.dart';
import 'soft_button.dart';
import 'theme/app_theme.dart';
import 'theme/components.dart';
import 'theme/tokens.dart';

const Duration _openDuration = Duration(milliseconds: 500);
const double _targetSize = 44;
const double _iconHeight = 28;
const int _visibleRows = 4;
const double _peekRow = 22;
const double _gap = 12;

class TrayHost extends StatefulWidget {
  const TrayHost({required this.controller, required this.state, super.key});

  final AppController controller;
  final NodeState state;

  @override
  State<TrayHost> createState() => _TrayHostState();
}

class _TrayHostState extends State<TrayHost>
    with SingleTickerProviderStateMixin {
  late final AnimationController _motion = AnimationController(
    vsync: this,
    duration: _openDuration,
  )..addStatusListener(_onStatus);
  late final CurvedAnimation _eased = CurvedAnimation(
    parent: _motion,
    curve: labEaseOut,
  );
  List<TrayItemView> _shown = const [];
  bool _reduceMotion = false;

  @override
  void initState() {
    super.initState();
    _shown = widget.state.tray;
    if (_shown.isNotEmpty) _motion.value = 1;
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _reduceMotion = MediaQuery.disableAnimationsOf(context);
  }

  @override
  void didUpdateWidget(TrayHost oldWidget) {
    super.didUpdateWidget(oldWidget);
    final items = widget.state.tray;
    if (items.isNotEmpty) {
      _shown = items;
      if (!_motion.isForwardOrCompleted) {
        if (_reduceMotion) {
          _motion.value = 1;
        } else {
          _motion.forward();
        }
      }
    } else if (_motion.isForwardOrCompleted) {
      if (_reduceMotion) {
        _motion.value = 0;
      } else {
        _motion.reverse();
      }
    }
  }

  void _onStatus(AnimationStatus status) {
    if (status == AnimationStatus.dismissed && mounted) {
      setState(() => _shown = const []);
    }
  }

  @override
  void dispose() {
    _eased.dispose();
    _motion.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_shown.isEmpty && _motion.isDismissed) return const SizedBox.shrink();
    return SizeTransition(
      sizeFactor: _eased,
      alignment: Alignment.topCenter,
      child: FadeTransition(
        opacity: _eased,
        child: Padding(
          padding: const EdgeInsets.only(bottom: _gap),
          child: TrayPanel(
            controller: widget.controller,
            state: widget.state,
            items: _shown,
          ),
        ),
      ),
    );
  }
}

class TrayPanel extends StatelessWidget {
  const TrayPanel({
    required this.controller,
    required this.state,
    required this.items,
    super.key,
  });

  final AppController controller;
  final NodeState state;
  final List<TrayItemView> items;

  @override
  Widget build(BuildContext context) {
    final strings = AppStringsDelegate.of(context);
    final colors = NbColors.of(context);
    final peers = [
      for (final entry in state.entries)
        if (entry.paired) entry,
    ];
    final rows = math.min(items.length, _visibleRows);
    final listHeight =
        rows * _targetSize + (items.length > _visibleRows ? _peekRow : 0);
    return Semantics(
      container: true,
      label: strings.trayTitle(items.length),
      child: NbCard(
        ring: colors.primary,
        padding: const EdgeInsets.fromLTRB(16, 8, 12, 14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Container(
                  width: 26,
                  height: 26,
                  decoration: BoxDecoration(
                    color: colors.primaryWeak,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  alignment: Alignment.center,
                  child: GlyphIcon(
                    Glyphs.tray,
                    size: 15,
                    color: colors.primaryInk,
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    strings.trayTitle(items.length),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: NbText.bodyStrong.copyWith(color: colors.text),
                  ),
                ),
                Tooltip(
                  message: strings.trayRemoveAll,
                  child: TextButton(
                    key: const ValueKey('tray-remove-all'),
                    style: TextButton.styleFrom(
                      minimumSize: const Size(0, _targetSize),
                      padding: const EdgeInsets.symmetric(horizontal: 10),
                      foregroundColor: colors.primaryInk,
                      textStyle: NbText.button,
                      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    ),
                    onPressed: controller.clearTray,
                    child: Text(strings.trayRemoveAll),
                  ),
                ),
              ],
            ),
            SizedBox(
              height: listHeight,
              child: ListView.builder(
                itemCount: items.length,
                itemExtent: _targetSize,
                padding: EdgeInsets.zero,
                itemBuilder: (context, index) => _TrayRow(
                  key: ValueKey('tray-item-${items[index].id}'),
                  item: items[index],
                  controller: controller,
                ),
              ),
            ),
            for (final entry in peers)
              _SendToRow(
                key: ValueKey('tray-send-${entry.fingerprint}'),
                controller: controller,
                state: state,
                entry: entry,
              ),
          ],
        ),
      ),
    );
  }
}

class _TrayRow extends StatelessWidget {
  const _TrayRow({required this.item, required this.controller, super.key});

  final TrayItemView item;
  final AppController controller;

  @override
  Widget build(BuildContext context) {
    final strings = AppStringsDelegate.of(context);
    final colors = NbColors.of(context);
    return Row(
      children: [
        if (item.isFolder)
          const FolderIcon(height: _iconHeight)
        else
          FileIcon(fileName: item.name, height: _iconHeight),
        const SizedBox(width: 10),
        Expanded(
          child: FittedName(
            name: item.name,
            style: NbText.bodyStrong.copyWith(fontSize: 13, color: colors.text),
          ),
        ),
        RemoveButton(
          label: '${strings.queueRemove}: ${item.name}',
          tooltip: strings.queueRemove,
          onPressed: () => controller.removeFromTray(item.id),
        ),
      ],
    );
  }
}

class _SendToRow extends StatelessWidget {
  const _SendToRow({
    required this.controller,
    required this.state,
    required this.entry,
    super.key,
  });

  final AppController controller;
  final NodeState state;
  final DeviceEntry entry;

  @override
  Widget build(BuildContext context) {
    final strings = AppStringsDelegate.of(context);
    final colors = NbColors.of(context);
    final explanation = sendExplanation(strings, state, entry);
    return Padding(
      padding: const EdgeInsets.only(top: 8, right: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SoftButton(
            glyph: Glyphs.send,
            label: strings.traySendTo(entry.displayName),
            height: _targetSize,
            onPressed: state.canSendTo(entry.fingerprint)
                ? () => startSendTray(context, controller, entry.fingerprint)
                : null,
          ),
          if (explanation != null)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(
                explanation,
                style: NbText.caption.copyWith(color: colors.textWeak),
              ),
            ),
        ],
      ),
    );
  }
}
