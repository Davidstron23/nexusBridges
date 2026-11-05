import 'package:flutter/material.dart';
import 'package:nexus_bridges_core/nexus_bridges_core.dart';

import '../../l10n/app_strings.dart';
import '../format.dart';
import '../icons/file_icon.dart';
import '../icons/folder_icon.dart';
import '../icons/glyphs.dart';
import '../settings/settings_section.dart';
import '../theme/app_theme.dart';
import '../theme/tokens.dart';
import '../destination/folder_navigator.dart';

String _two(int value) => value.toString().padLeft(2, '0');

String historyClock(DateTime at) {
  final local = at.toLocal();
  return '${_two(local.hour)}:${_two(local.minute)}';
}

bool _sameDay(DateTime a, DateTime b) =>
    a.year == b.year && a.month == b.month && a.day == b.day;

String historyDayLabel(
  DateTime at,
  DateTime now,
  AppStrings strings,
  String languageCode,
) {
  final local = at.toLocal();
  final today = now.toLocal();
  if (_sameDay(local, today)) return strings.historyToday;
  if (_sameDay(local, today.subtract(const Duration(days: 1)))) {
    return strings.historyYesterday;
  }
  return formatShortDate(at, languageCode, strings);
}

String historyWhen(
  DateTime at,
  DateTime now,
  AppStrings strings,
  String languageCode,
) {
  return '${historyDayLabel(at, now, strings, languageCode)}, '
      '${historyClock(at)}';
}

String historyName(AppStrings strings, HistoryEntryView entry) {
  if (entry.itemCount > 1) {
    return strings.historyFirstAndMore(entry.name, entry.itemCount - 1);
  }
  return entry.name;
}

String historyMeta(
  AppStrings strings,
  HistoryEntryView entry,
  String languageCode,
) {
  final parts = <String>[];
  if (entry.itemCount > 1) {
    parts.add(strings.historyItems(entry.itemCount));
    if (entry.delivered < entry.itemCount) {
      parts.add(strings.historyDelivered(entry.delivered, entry.itemCount));
    }
  } else if (entry.isFolder) {
    parts.add(strings.filesCount(entry.fileCount));
  }
  parts.add(formatSize(entry.size, languageCode));
  final destination = entry.destination;
  parts.add(
    destination == null
        ? strings.historyDefaultFolder
        : destination.display(homeName: strings.homeFolder),
  );
  return parts.join(' · ');
}

class HistoryRow extends StatelessWidget {
  const HistoryRow({
    required this.entry,
    required this.divider,
    required this.timeOnly,
    required this.now,
    super.key,
  });

  final HistoryEntryView entry;
  final bool divider;
  final bool timeOnly;
  final DateTime now;

  @override
  Widget build(BuildContext context) {
    final strings = AppStringsDelegate.of(context);
    final colors = NbColors.of(context);
    final languageCode = Localizations.localeOf(context).languageCode;
    final sent = entry.direction == HistoryDirection.sent;
    final kind = entry.outcome.kind;
    final meta = historyMeta(strings, entry, languageCode);
    final destination = entry.destination;
    final destinationText = destination == null
        ? strings.historyDefaultFolder
        : destination.display(homeName: strings.homeFolder);
    final metaOnly = meta.endsWith(destinationText)
        ? meta.substring(0, meta.length - destinationText.length)
        : meta;
    final reason = sent
        ? strings.sentOutcome(entry.outcome)
        : strings.receivedOutcome(entry.outcome);
    return DecoratedBox(
      decoration: BoxDecoration(
        border: divider
            ? Border(top: BorderSide(color: colors.borderWeak))
            : null,
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 10, 14, 10),
        child: Row(
          children: [
            Semantics(
              image: true,
              label: sent
                  ? strings.historySentLabel
                  : strings.historyReceivedLabel,
              child: GlyphIcon(
                sent ? Glyphs.arrowUp : Glyphs.arrowDown,
                size: 27,
                color: sent ? colors.primaryInk : colors.textWeak,
                strokeScale: sent ? 0.7 : 0.52,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Row(
                    children: [
                      entry.isFolder && entry.itemCount == 1
                          ? const FolderIcon(height: 16)
                          : FileIcon(fileName: entry.name, height: 16),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          historyName(strings, entry),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: NbText.bodySm.copyWith(
                            color: colors.text,
                            fontSize: 13.5,
                            height: 18 / 13.5,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Text(
                        timeOnly
                            ? historyClock(entry.at)
                            : historyWhen(entry.at, now, strings, languageCode),
                        style: NbText.caption.copyWith(
                          color: colors.textWeak,
                          height: 18 / 12,
                          fontFeatures: const [FontFeature.tabularFigures()],
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 2),
                  Padding(
                    padding: const EdgeInsets.only(left: 21),
                    child: Row(
                      children: [
                        Expanded(
                          child: Text.rich(
                            TextSpan(
                              children: [
                                TextSpan(text: metaOnly),
                                TextSpan(
                                  text: destinationText,
                                  style: TextStyle(color: colors.hint),
                                ),
                              ],
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: NbText.caption.copyWith(
                              color: colors.textWeak,
                              height: 16 / 12,
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        _Status(
                          kind: kind,
                          outcome: entry.outcome,
                          sent: sent,
                          reason: reason,
                        ),
                      ],
                    ),
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

class _Status extends StatelessWidget {
  const _Status({
    required this.kind,
    required this.outcome,
    required this.sent,
    required this.reason,
  });

  final TransferResultKind kind;
  final TransferOutcome outcome;
  final bool sent;
  final String reason;

  @override
  Widget build(BuildContext context) {
    final strings = AppStringsDelegate.of(context);
    final colors = NbColors.of(context);
    if (kind == TransferResultKind.saved) {
      final label = sent
          ? strings.historyDeliveredTip
          : strings.historySavedTip;
      return Tooltip(
        message: label,
        child: Semantics(
          image: true,
          label: label,
          child: GlyphIcon(Glyphs.tick, size: 14, color: colors.successInk),
        ),
      );
    }
    final cancelled =
        outcome == TransferOutcome.cancelledHere ||
        outcome == TransferOutcome.cancelledByPeer ||
        outcome == TransferOutcome.shareRemoved ||
        outcome == TransferOutcome.peerMarkedForeign ||
        outcome == TransferOutcome.unpaired;
    final color = cancelled ? colors.warning : colors.danger;
    final label = cancelled ? strings.historyCancelled : strings.historyFailed;
    return Tooltip(
      message: reason,
      child: Semantics(
        label: '$label: $reason',
        excludeSemantics: true,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            GlyphIcon(
              cancelled ? Glyphs.ban : Glyphs.close,
              size: 12,
              color: color,
            ),
            const SizedBox(width: 4),
            Text(label, style: NbText.label.copyWith(color: color)),
          ],
        ),
      ),
    );
  }
}

class HistoryView extends StatelessWidget {
  const HistoryView({
    required this.name,
    required this.entries,
    required this.onBack,
    required this.onClose,
    required this.now,
    super.key,
  });

  final String name;
  final List<HistoryEntryView> entries;
  final VoidCallback onBack;
  final VoidCallback onClose;
  final DateTime now;

  @override
  Widget build(BuildContext context) {
    final strings = AppStringsDelegate.of(context);
    final colors = NbColors.of(context);
    final languageCode = Localizations.localeOf(context).languageCode;
    final groups = <(String, List<HistoryEntryView>)>[];
    for (final entry in entries) {
      final label = historyDayLabel(entry.at, now, strings, languageCode);
      if (groups.isEmpty || groups.last.$1 != label) {
        groups.add((label, <HistoryEntryView>[]));
      }
      groups.last.$2.add(entry);
    }
    final sentCount = entries
        .where((entry) => entry.direction == HistoryDirection.sent)
        .length;
    return Column(
      children: [
        DecoratedBox(
          decoration: BoxDecoration(
            border: Border(bottom: BorderSide(color: colors.borderWeak)),
          ),
          child: SizedBox(
            height: 68,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(10, 0, 14, 0),
              child: Row(
                children: [
                  NavIconButton(
                    glyph: Glyphs.back,
                    tooltip: strings.historyBack,
                    onPressed: onBack,
                    glyphSize: 18,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          strings.historyTitle(name),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: NbText.title.copyWith(
                            color: colors.text,
                            fontSize: 17,
                            height: 22 / 17,
                          ),
                        ),
                        Text(
                          strings.historySummary(
                            sentCount,
                            entries.length - sentCount,
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
                  NavIconButton(
                    glyph: Glyphs.close,
                    tooltip: strings.closeButton,
                    onPressed: onClose,
                  ),
                ],
              ),
            ),
          ),
        ),
        Expanded(
          child: ListView(
            padding: const EdgeInsets.fromLTRB(20, 8, 20, 28),
            children: [
              for (final group in groups) ...[
                Padding(
                  padding: const EdgeInsets.fromLTRB(2, 16, 2, 8),
                  child: Text(
                    group.$1,
                    style: NbText.label.copyWith(
                      color: colors.text,
                      fontSize: 12.5,
                      height: 18 / 12.5,
                    ),
                  ),
                ),
                SettingsWell(
                  child: Column(
                    children: [
                      for (var i = 0; i < group.$2.length; i++)
                        HistoryRow(
                          entry: group.$2[i],
                          divider: i > 0,
                          timeOnly: true,
                          now: now,
                        ),
                    ],
                  ),
                ),
              ],
            ],
          ),
        ),
      ],
    );
  }
}
