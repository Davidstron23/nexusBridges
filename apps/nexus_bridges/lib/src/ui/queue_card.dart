import 'package:flutter/material.dart';
import 'package:nexus_bridges_core/nexus_bridges_core.dart';

import '../app_controller.dart';
import '../l10n/app_strings.dart';
import 'activity_cards.dart';
import 'armed.dart';
import 'format.dart';
import 'icons/file_icon.dart';
import 'icons/folder_icon.dart';
import 'icons/glyphs.dart';
import 'modal/timeline.dart';
import 'progress/selection_progress_painter.dart';
import 'progress/time_left_scope.dart';
import 'theme/app_theme.dart';
import 'theme/components.dart';
import 'theme/tokens.dart';

const Duration _sectionDuration = Duration(milliseconds: 450);
const Duration _chevronDuration = Duration(milliseconds: 380);
const Duration _rowEnterDuration = Duration(milliseconds: 500);
const double _rowEnterShift = 16;
const double _iconHeight = 28;
const double _targetSize = 44;
const double _badgeSize = 20;
const int _foldedAbove = 20;
const int _visibleRows = 4;
const double _rowExtent = 48;
const double _peekRow = 24;
const double _runningSlot = 60;

enum _Section { loose, bundles }

bool _isDelivered(QueueItemView item) =>
    item.state == QueueItemState.done &&
    (item.outcome == TransferOutcome.saved ||
        item.outcome == TransferOutcome.savedWithoutMark);

bool _isPast(QueueItemView item) =>
    item.state == QueueItemState.done || item.state == QueueItemState.notSent;

bool _failed(QueueItemView item) {
  final outcome = item.outcome;
  if (!_isPast(item) || outcome == null || _isDelivered(item)) return false;
  final kind = outcome.kind;
  return kind == TransferResultKind.rejected ||
      kind == TransferResultKind.failed;
}

double selectionValueOf(NodeState state, SendQueuesView queues) {
  if (queues.finished) return 1;
  final progress = state.selectionProgress;
  if (progress == null || progress.selectionId != queues.selectionId) return 0;
  if (progress.totalBytes <= 0) return 0;
  return (progress.doneBytes / progress.totalBytes).clamp(0.0, 0.999);
}

class QueueCard extends StatefulWidget {
  const QueueCard({
    required this.controller,
    required this.state,
    required this.queues,
    super.key,
  });

  final AppController controller;
  final NodeState state;
  final SendQueuesView queues;

  @override
  State<QueueCard> createState() => _QueueCardState();
}

class _QueueCardState extends State<QueueCard> {
  final Map<_Section, bool> _toggled = {};
  final Set<String> _seen = {};
  Set<String> _entering = {};

  List<QueueItemView> get _all => [
    ...widget.queues.loose,
    ...widget.queues.bundles,
  ];

  @override
  void initState() {
    super.initState();
    _seen.addAll(_all.map((item) => item.id));
  }

  @override
  void didUpdateWidget(QueueCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.queues.selectionId != widget.queues.selectionId) {
      _toggled.clear();
      _seen
        ..clear()
        ..addAll(_all.map((item) => item.id));
      _entering = {};
      return;
    }
    final ids = _all.map((item) => item.id).toSet();
    _entering = ids.difference(_seen);
    _seen.addAll(ids);
  }

  bool _isOpen(_Section section, List<QueueItemView> items) {
    final toggled = _toggled[section];
    if (toggled != null) return toggled;
    if (items.length > _foldedAbove) return false;
    return items.any((item) => !_isPast(item) || _failed(item));
  }

  void _toggle(_Section section, List<QueueItemView> items) {
    setState(() => _toggled[section] = !_isOpen(section, items));
  }

  @override
  Widget build(BuildContext context) {
    final strings = AppStringsDelegate.of(context);
    final colors = NbColors.of(context);
    final queues = widget.queues;
    final controller = widget.controller;
    final name = peerLabel(queues.peerName, queues.peerFingerprint);
    final all = _all;
    final pending = all
        .where((item) => item.state == QueueItemState.pending)
        .length;
    final finished = queues.finished;
    final current = widget.state.outgoing;
    final outgoing =
        current != null && current.peerFingerprint == queues.peerFingerprint
        ? current
        : null;
    final failure = all.any(_failed);
    final allDelivered = queues.total > 0 && queues.delivered == queues.total;
    final (String chipLabel, ChipTone chipTone, Widget? chipIcon) = !finished
        ? (strings.chipInProgress, ChipTone.run, null)
        : allDelivered
        ? (
            strings.chipDelivered,
            ChipTone.ok,
            const GlyphIcon(Glyphs.check, size: 12),
          )
        : failure
        ? (
            strings.chipFailed,
            ChipTone.fail,
            const GlyphIcon(Glyphs.ban, size: 12),
          )
        : (strings.chipCancelled, ChipTone.wait, null);
    final sections = <(_Section, String, List<QueueItemView>)>[
      (_Section.loose, strings.looseQueue, queues.loose),
      (_Section.bundles, strings.bundleQueue, queues.bundles),
    ];
    final running = all
        .where((item) => item.state == QueueItemState.inProgress)
        .firstOrNull;
    return NbCard(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          ActivityCardHeader(
            title: finished ? strings.lastSentTitle : strings.queueTitle(name),
            chip: StatusChip(label: chipLabel, tone: chipTone, icon: chipIcon),
          ),
          SelectionProgressBuilder(
            track: ProgressTrack.outgoing,
            enabled:
                widget.state.selectionProgress?.selectionId ==
                queues.selectionId,
            fallback: selectionValueOf(widget.state, queues),
            builder: (context, value, gliding) {
              if (finished && !gliding) {
                return Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Text(
                    strings.toPeer(name),
                    style: NbText.caption.copyWith(color: colors.textWeak),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                );
              }
              return Padding(
                padding: const EdgeInsets.only(top: 10),
                child: SelectionBar(value: value),
              );
            },
          ),
          if (!finished) ...[
            const SizedBox(height: 12),
            ConstrainedBox(
              constraints: const BoxConstraints(minHeight: _runningSlot),
              child: running == null
                  ? null
                  : _RowIn(
                      key: ValueKey('queue-row-${running.id}'),
                      animate: false,
                      child: _ItemRow(
                        item: running,
                        controller: controller,
                        outgoing: outgoing,
                        peerName: name,
                      ),
                    ),
            ),
          ],
          if (!finished)
            ActivityCardFooter(
              note: pending > 0
                  ? strings.queueRemaining(pending)
                  : strings.queueLastItem,
              action: inlineButtonBar([
                OutlinedButton(
                  style: smallButton,
                  onPressed: controller.cancelAllQueued,
                  child: Text(strings.queueCancelAll),
                ),
              ]),
            ),
          for (final (section, title, items) in sections)
            if (items.any((item) => item != running)) ...[
              const SizedBox(height: 12),
              _QueueSection(
                key: ValueKey('queue-section-${section.name}'),
                title: title,
                items: items,
                rows: [
                  for (final item in items)
                    if (item != running) item,
                ],
                open: _isOpen(section, items),
                onToggle: () => _toggle(section, items),
                controller: controller,
                peerName: name,
                entering: _entering,
              ),
            ],
          if (finished)
            _DeliveredStrip(
              delivered: queues.delivered,
              total: queues.total,
              allDelivered: allDelivered,
            ),
        ],
      ),
    );
  }
}

class SelectionBar extends StatelessWidget {
  const SelectionBar({required this.value, super.key});

  final double value;

  @override
  Widget build(BuildContext context) {
    final colors = NbColors.of(context);
    final language = Localizations.localeOf(context).languageCode;
    final percent = (value * 100).floor();
    return Row(
      children: [
        Expanded(child: NbProgressBar(value: value)),
        const SizedBox(width: 12),
        ConstrainedBox(
          constraints: const BoxConstraints(minWidth: 38),
          child: Text(
            formatPercent(percent, language),
            textAlign: TextAlign.end,
            style: NbText.button.copyWith(
              color: colors.primaryInk,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
        ),
      ],
    );
  }
}

class _DeliveredStrip extends StatelessWidget {
  const _DeliveredStrip({
    required this.delivered,
    required this.total,
    required this.allDelivered,
  });

  final int delivered;
  final int total;
  final bool allDelivered;

  @override
  Widget build(BuildContext context) {
    final colors = NbColors.of(context);
    final strings = AppStringsDelegate.of(context);
    final fill = allDelivered ? colors.successWeak : colors.surfaceWeak;
    final ink = allDelivered ? colors.successInk : colors.text;
    return Padding(
      padding: const EdgeInsets.only(top: 12),
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: fill,
          borderRadius: BorderRadius.circular(10),
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          child: Row(
            children: [
              GlyphIcon(
                allDelivered ? Glyphs.check : Glyphs.ban,
                size: 14,
                color: ink,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  strings.deliveredSummary(delivered, total),
                  style: NbText.bodySm.copyWith(
                    color: ink,
                    fontWeight: FontWeight.w600,
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

class _QueueSection extends StatelessWidget {
  const _QueueSection({
    required this.title,
    required this.items,
    required this.rows,
    required this.open,
    required this.onToggle,
    required this.controller,
    required this.peerName,
    required this.entering,
    super.key,
  });

  final String title;
  final List<QueueItemView> items;
  final List<QueueItemView> rows;
  final bool open;
  final VoidCallback onToggle;
  final AppController controller;
  final String peerName;
  final Set<String> entering;

  Widget _row(QueueItemView item, bool animate) {
    return _RowIn(
      key: ValueKey('queue-row-${item.id}'),
      animate: animate && entering.contains(item.id),
      child: _ItemRow(
        item: item,
        controller: controller,
        outgoing: null,
        peerName: peerName,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final colors = NbColors.of(context);
    final strings = AppStringsDelegate.of(context);
    final animate = !MediaQuery.disableAnimationsOf(context);
    final delivered = items.where(_isDelivered).length;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: colors.surfaceWeak,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: colors.borderWeak),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Semantics(
            button: true,
            expanded: open,
            label: title,
            child: InkWell(
              onTap: onToggle,
              borderRadius: BorderRadius.circular(10),
              hoverColor: colors.controlHover,
              splashFactory: NoSplash.splashFactory,
              child: ConstrainedBox(
                constraints: const BoxConstraints(minHeight: _targetSize),
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(12, 0, 10, 0),
                  child: Row(
                    children: [
                      AnimatedRotation(
                        turns: open ? 0 : -0.25,
                        duration: animate ? _chevronDuration : Duration.zero,
                        curve: labEaseOut,
                        child: GlyphIcon(
                          Glyphs.chevronDown,
                          size: 14,
                          color: colors.textWeak,
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Padding(
                          padding: const EdgeInsets.symmetric(vertical: 6),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                title,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: NbText.label.copyWith(
                                  color: colors.text,
                                ),
                              ),
                              Text(
                                strings.deliveredSummary(
                                  delivered,
                                  items.length,
                                ),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: NbText.caption.copyWith(
                                  color: colors.textWeak,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
          _SectionBody(
            animate: animate,
            child: open
                ? Padding(
                    padding: const EdgeInsets.fromLTRB(2, 0, 2, 6),
                    child: rows.length <= _visibleRows
                        ? Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              for (final item in rows) _row(item, animate),
                            ],
                          )
                        : SizedBox(
                            height: _visibleRows * _rowExtent + _peekRow,
                            child: ListView.builder(
                              key: ValueKey('queue-list-$title'),
                              itemCount: rows.length,
                              padding: EdgeInsets.zero,
                              itemBuilder: (context, index) =>
                                  _row(rows[index], animate),
                            ),
                          ),
                  )
                : const SizedBox(width: double.infinity),
          ),
        ],
      ),
    );
  }
}

class _SectionBody extends StatelessWidget {
  const _SectionBody({required this.animate, required this.child});

  final bool animate;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    if (!animate) return child;
    return AnimatedSize(
      duration: _sectionDuration,
      curve: labEaseOut,
      alignment: Alignment.topCenter,
      child: child,
    );
  }
}

class _RowIn extends StatefulWidget {
  const _RowIn({required this.animate, required this.child, super.key});

  final bool animate;
  final Widget child;

  @override
  State<_RowIn> createState() => _RowInState();
}

class _RowInState extends State<_RowIn> with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: _rowEnterDuration,
    value: widget.animate ? 0 : 1,
  );
  late final CurvedAnimation _curve = CurvedAnimation(
    parent: _controller,
    curve: labEaseOut,
  );

  @override
  void initState() {
    super.initState();
    if (widget.animate) _controller.forward();
  }

  @override
  void dispose() {
    _curve.dispose();
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _curve,
      builder: (context, child) => Opacity(
        opacity: _curve.value,
        child: Transform.translate(
          offset: Offset(_rowEnterShift * (1 - _curve.value), 0),
          child: child,
        ),
      ),
      child: widget.child,
    );
  }
}

class _ItemRow extends StatelessWidget {
  const _ItemRow({
    required this.item,
    required this.controller,
    required this.outgoing,
    required this.peerName,
  });

  final QueueItemView item;
  final AppController controller;
  final OutgoingTransferView? outgoing;
  final String peerName;

  @override
  Widget build(BuildContext context) {
    final colors = NbColors.of(context);
    final strings = AppStringsDelegate.of(context);
    final language = Localizations.localeOf(context).languageCode;
    final running = item.state == QueueItemState.inProgress;
    final view = outgoing;
    final nameStyle = NbText.bodyStrong.copyWith(
      fontSize: 13,
      color: colors.text,
    );
    final captionStyle = NbText.caption.copyWith(color: colors.textWeak);

    var detail = '';
    var detailStyle = captionStyle;
    var extra = const <String>[];
    var showBar = false;
    var barValue = 0.0;
    FolderSummaryView? summary;
    Widget? trailing;
    Widget? footer;
    switch (item.state) {
      case QueueItemState.pending:
        detail = strings.queuePending;
        trailing = RemoveButton(
          label: '${strings.queueRemove}: ${item.name}',
          tooltip: strings.queueRemove,
          onPressed: () => controller.removeQueueItem(item.id),
        );
      case QueueItemState.inProgress:
        if (view == null) {
          detail = strings.chipPreparing;
        } else {
          switch (view.phase) {
            case OutgoingPhase.preparing:
              detail = view.isFolder
                  ? strings.preparingItems(view.preparedEntries)
                  : strings.chipPreparing;
            case OutgoingPhase.requesting:
              detail = strings.contactingPeer(peerName);
            case OutgoingPhase.waiting:
              detail = strings.waitingAcceptance(peerName);
            case OutgoingPhase.uploading:
              detail = strings.progressLine(
                percentOf(view.sentBytes, view.size),
                formatSize(view.sentBytes, language),
                formatSize(view.size, language),
              );
              showBar = true;
              barValue = percentOf(view.sentBytes, view.size) / 100;
              if (view.isFolder && view.fileCount > 0) {
                extra = [strings.filesProgress(view.sentFiles, view.fileCount)];
              }
            case OutgoingPhase.verifying:
              detail = strings.peerCheckingFile(peerName);
              showBar = true;
              barValue = 1;
          }
          summary = view.isFolder ? view.summary : null;
        }
        footer = Padding(
          padding: const EdgeInsets.only(top: 6),
          child: view != null && view.cancelling
              ? Align(
                  alignment: AlignmentDirectional.centerEnd,
                  child: Text(
                    strings.cancellingTransfer,
                    style: captionStyle,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                )
              : Row(
                  children: [
                    const Expanded(
                      child: Align(
                        alignment: AlignmentDirectional.centerStart,
                        child: TimeLeftLabel(
                          track: ProgressTrack.outgoing,
                          lowered: false,
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Armed(
                      armKey: item.id,
                      builder: (context, armed) => OutlinedButton(
                        style: smallButton,
                        onPressed: armed
                            ? () => controller.cancelQueueItem(item.id)
                            : null,
                        child: Text(strings.cancelButton),
                      ),
                    ),
                  ],
                ),
        );
      case QueueItemState.done:
      case QueueItemState.notSent:
        final outcome = item.outcome ?? TransferOutcome.noContact;
        if (_isDelivered(item)) {
          detail = outcome == TransferOutcome.saved
              ? strings.chipDelivered
              : strings.sentOutcome(outcome);
          detailStyle = captionStyle.copyWith(color: colors.successInk);
          trailing = const _Badge(_Tone.ok);
        } else {
          final reason = outcomeLine(
            strings,
            outcome,
            outgoing: true,
            isFolder: item.isFolder,
            problemPath: item.problemPath,
          );
          detail = item.state == QueueItemState.notSent
              ? strings.queueNotSent(reason)
              : reason;
          final failedKind = _failed(item);
          detailStyle = captionStyle.copyWith(
            color: failedKind ? colors.danger : colors.textWeak,
          );
          trailing = _Badge(failedKind ? _Tone.fail : _Tone.neutral);
        }
    }

    final content = Row(
      crossAxisAlignment: running
          ? CrossAxisAlignment.start
          : CrossAxisAlignment.center,
      children: [
        if (item.isFolder)
          const FolderIcon(height: _iconHeight)
        else
          FileIcon(fileName: item.name, height: _iconHeight),
        const SizedBox(width: 10),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              FittedName(name: item.name, style: nameStyle),
              Text(
                detail,
                style: detailStyle,
                maxLines: 3,
                overflow: TextOverflow.ellipsis,
              ),
              for (final line in extra)
                Text(
                  line,
                  style: captionStyle,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              if (summary != null)
                FolderSummaryLines(
                  summary: summary,
                  topGap: 4,
                  showTotals:
                      view?.phase == OutgoingPhase.requesting ||
                      view?.phase == OutgoingPhase.waiting,
                ),
              if (showBar) ...[
                const SizedBox(height: 6),
                NbProgressBar(value: barValue),
              ],
            ],
          ),
        ),
        if (trailing != null) ...[const SizedBox(width: 6), trailing],
      ],
    );
    return Container(
      constraints: const BoxConstraints(minHeight: _targetSize),
      margin: const EdgeInsets.symmetric(horizontal: 2),
      padding: const EdgeInsets.fromLTRB(10, 6, 8, 6),
      decoration: running
          ? BoxDecoration(
              color: colors.card,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: colors.borderWeak),
              boxShadow: [
                BoxShadow(
                  color: colors.nodeShadow,
                  offset: const Offset(0, 1),
                  blurRadius: 2,
                ),
              ],
            )
          : null,
      child: footer == null
          ? content
          : Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [content, footer],
            ),
    );
  }
}

enum _Tone { ok, fail, neutral }

class _Badge extends StatelessWidget {
  const _Badge(this.tone);

  final _Tone tone;

  @override
  Widget build(BuildContext context) {
    final colors = NbColors.of(context);
    final (Glyph glyph, Color background, Color color) = switch (tone) {
      _Tone.ok => (Glyphs.check, colors.successWeak, colors.successInk),
      _Tone.fail => (Glyphs.cross, colors.dangerWeak, colors.danger),
      _Tone.neutral => (Glyphs.ban, colors.surfaceWeak, colors.textWeak),
    };
    return Container(
      width: _badgeSize,
      height: _badgeSize,
      decoration: BoxDecoration(color: background, shape: BoxShape.circle),
      alignment: Alignment.center,
      child: GlyphIcon(glyph, size: 11, color: color),
    );
  }
}

class RemoveButton extends StatefulWidget {
  const RemoveButton({
    required this.label,
    required this.tooltip,
    required this.onPressed,
    super.key,
  });

  final String label;
  final String tooltip;
  final VoidCallback onPressed;

  @override
  State<RemoveButton> createState() => _RemoveButtonState();
}

class _RemoveButtonState extends State<RemoveButton> {
  bool _hovered = false;
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    final colors = NbColors.of(context);
    final animate = !MediaQuery.disableAnimationsOf(context);
    final lit = _hovered || _focused;
    return Tooltip(
      message: widget.tooltip,
      child: Semantics(
        button: true,
        label: widget.label,
        excludeSemantics: true,
        onTap: widget.onPressed,
        child: FocusableActionDetector(
          mouseCursor: SystemMouseCursors.click,
          actions: {
            ActivateIntent: CallbackAction<ActivateIntent>(
              onInvoke: (_) {
                widget.onPressed();
                return null;
              },
            ),
          },
          onShowFocusHighlight: (value) => setState(() => _focused = value),
          onShowHoverHighlight: (value) => setState(() => _hovered = value),
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: widget.onPressed,
            child: SizedBox(
              width: _targetSize,
              height: _targetSize,
              child: Center(
                child: AnimatedContainer(
                  width: 28,
                  height: 28,
                  duration: animate
                      ? const Duration(milliseconds: 200)
                      : Duration.zero,
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
                    child: GlyphIcon(
                      Glyphs.cross,
                      size: 14,
                      color: lit ? colors.text : colors.textWeak,
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
}
