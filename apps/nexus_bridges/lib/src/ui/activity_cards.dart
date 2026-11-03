import 'package:flutter/material.dart';
import 'package:nexus_bridges_core/nexus_bridges_core.dart';

import '../app_controller.dart';
import '../l10n/app_strings.dart';
import 'armed.dart';
import 'format.dart';
import 'icons/file_icon.dart';
import 'icons/folder_icon.dart';
import 'icons/glyphs.dart';
import 'progress/selection_progress_painter.dart';
import 'queue_card.dart';
import 'theme/app_theme.dart';
import 'theme/components.dart';
import 'theme/tokens.dart';

const int _shortFingerprintLength = 8;

const int _maxExtensionRunes = 16;

const int _dotRune = 0x2E;

const double _cardGap = 12;

ChipTone outgoingTone(OutgoingPhase phase) => switch (phase) {
  OutgoingPhase.preparing ||
  OutgoingPhase.requesting ||
  OutgoingPhase.waiting => ChipTone.wait,
  OutgoingPhase.uploading || OutgoingPhase.verifying => ChipTone.run,
};

String outgoingChipText(AppStrings strings, OutgoingPhase phase) {
  return switch (phase) {
    OutgoingPhase.preparing => strings.chipPreparing,
    OutgoingPhase.requesting || OutgoingPhase.waiting => strings.chipWaiting,
    OutgoingPhase.uploading => strings.chipInProgress,
    OutgoingPhase.verifying => strings.chipChecking,
  };
}

ChipTone incomingTone(IncomingStage stage) => switch (stage) {
  IncomingStage.receiving || IncomingStage.verifying => ChipTone.run,
  _ => ChipTone.wait,
};

String incomingChipText(AppStrings strings, IncomingStage stage) {
  return switch (stage) {
    IncomingStage.receiving => strings.chipInProgress,
    IncomingStage.verifying => strings.chipChecking,
    _ => strings.chipWaiting,
  };
}

ChipTone resultTone(TransferResultKind kind) => switch (kind) {
  TransferResultKind.saved => ChipTone.ok,
  TransferResultKind.rejected || TransferResultKind.failed => ChipTone.fail,
  TransferResultKind.cancelled ||
  TransferResultKind.unconfirmed => ChipTone.wait,
};

String resultChipText(AppStrings strings, TransferResultView result) {
  return switch (result.outcome.kind) {
    TransferResultKind.saved =>
      result.direction == TransferDirection.outgoing
          ? strings.chipDelivered
          : strings.chipSaved,
    TransferResultKind.rejected => strings.chipRejected,
    TransferResultKind.cancelled => strings.chipCancelled,
    TransferResultKind.failed => strings.chipFailed,
    TransferResultKind.unconfirmed => strings.chipUnconfirmed,
  };
}

bool _fits(
  String text,
  TextStyle style,
  double maxWidth,
  TextScaler textScaler,
  TextDirection textDirection,
) {
  final painter = TextPainter(
    text: TextSpan(text: text, style: style),
    maxLines: 1,
    textScaler: textScaler,
    textDirection: textDirection,
  )..layout(maxWidth: maxWidth);
  final exceeded = painter.didExceedMaxLines;
  painter.dispose();
  return !exceeded;
}

String fitFileName(
  String name, {
  required TextStyle style,
  required double maxWidth,
  required TextScaler textScaler,
  required TextDirection textDirection,
}) {
  if (_fits(name, style, maxWidth, textScaler, textDirection)) return name;
  final runes = name.runes.toList();
  final dot = runes.lastIndexOf(_dotRune);
  final extensionLength = dot > 0 ? runes.length - dot : 0;
  final minRunes = dot > 0 && extensionLength <= _maxExtensionRunes
      ? extensionLength + 2
      : 2;
  var low = minRunes;
  var high = runes.length - 1;
  var best = shortenFileName(name, maxRunes: minRunes);
  while (low <= high) {
    final middle = (low + high) ~/ 2;
    final candidate = shortenFileName(name, maxRunes: middle);
    if (_fits(candidate, style, maxWidth, textScaler, textDirection)) {
      best = candidate;
      low = middle + 1;
    } else {
      high = middle - 1;
    }
  }
  return best;
}

String peerLabel(String? name, String fingerprint) {
  if (name != null && name.isNotEmpty) return name;
  return fingerprint.length > _shortFingerprintLength
      ? fingerprint.substring(0, _shortFingerprintLength)
      : fingerprint;
}

bool _isActive(IncomingStage stage) =>
    stage == IncomingStage.waitingData ||
    stage == IncomingStage.receiving ||
    stage == IncomingStage.verifying;

class FittedName extends StatelessWidget {
  const FittedName({required this.name, required this.style, super.key});

  final String name;
  final TextStyle style;

  @override
  Widget build(BuildContext context) {
    final textScaler = MediaQuery.textScalerOf(context);
    final textDirection = Directionality.of(context);
    final measured = DefaultTextStyle.of(context).style.merge(style);
    return LayoutBuilder(
      builder: (context, constraints) {
        final shown = fitFileName(
          name,
          style: measured,
          maxWidth: constraints.maxWidth,
          textScaler: textScaler,
          textDirection: textDirection,
        );
        return Text(
          shown,
          style: measured,
          maxLines: 1,
          softWrap: false,
          overflow: TextOverflow.clip,
        );
      },
    );
  }
}

String outcomeLine(
  AppStrings strings,
  TransferOutcome outcome, {
  required bool outgoing,
  required bool isFolder,
  String? problemPath,
}) {
  final path = problemPath == null || problemPath.isEmpty
      ? null
      : breakablePath(problemPath);
  if (path != null) {
    if (outcome == TransferOutcome.unreadable) {
      return strings.outcomeUnreadableEntry(path);
    }
    if (outgoing && outcome == TransferOutcome.invalidName) {
      return strings.outcomeInvalidNameEntry(path);
    }
  }
  if (outgoing && isFolder && outcome == TransferOutcome.incompatible) {
    return strings.outcomeFolderIncompatible;
  }
  return outgoing
      ? strings.sentOutcome(outcome)
      : strings.receivedOutcome(outcome);
}

class FolderSummaryLines extends StatelessWidget {
  const FolderSummaryLines({
    required this.summary,
    this.showTotals = false,
    this.topGap = 0,
    super.key,
  });

  final FolderSummaryView summary;
  final bool showTotals;
  final double topGap;

  @override
  Widget build(BuildContext context) {
    final colors = NbColors.of(context);
    final strings = AppStringsDelegate.of(context);
    final language = Localizations.localeOf(context).languageCode;
    final style = NbText.caption.copyWith(color: colors.textWeak);
    final lines = <String>[
      if (showTotals)
        strings.folderSummary(
          summary.files,
          formatSize(summary.totalBytes, language),
        ),
      if (summary.excludedFolders > 0)
        strings.foldersLeftOut(
          summary.excludedFolders,
          summary.excludedBytesPartial
              ? null
              : formatSize(summary.excludedBytes, language),
        ),
      if (summary.linksOmitted > 0)
        strings.linksNotFollowed(summary.linksOmitted),
      if (summary.protectedOmitted > 0) strings.appDataLeftOut,
      if (summary.blockedOmitted > 0)
        strings.blockedLeftOut(summary.blockedOmitted),
    ];
    if (lines.isEmpty && !summary.containsPrograms) {
      return const SizedBox.shrink();
    }
    return Padding(
      padding: EdgeInsets.only(top: topGap),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (final line in lines)
            Text(
              line,
              style: style,
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
            ),
          if (summary.containsPrograms)
            Text(
              strings.containsPrograms,
              style: NbText.label.copyWith(color: colors.text),
            ),
        ],
      ),
    );
  }
}

class FileRow extends StatelessWidget {
  const FileRow({
    required this.fileName,
    required this.isProgram,
    required this.detail,
    this.isFolder = false,
    this.containsGit = false,
    this.extraDetails = const [],
    super.key,
  });

  final String fileName;
  final bool isProgram;
  final String detail;
  final bool isFolder;
  final bool containsGit;
  final List<String> extraDetails;

  @override
  Widget build(BuildContext context) {
    final colors = NbColors.of(context);
    final strings = AppStringsDelegate.of(context);
    final nameStyle = NbText.bodyStrong.copyWith(color: colors.text);
    final captionStyle = NbText.caption.copyWith(color: colors.textWeak);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (isFolder)
          const FolderIcon()
        else
          FileIcon(fileName: fileName, isProgram: isProgram),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              FittedName(name: fileName, style: nameStyle),
              Text(
                detail,
                style: captionStyle,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
              for (final extra in extraDetails)
                Text(
                  extra,
                  style: captionStyle,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              if (isProgram)
                Text(
                  isFolder ? strings.containsPrograms : strings.programLabel,
                  style: NbText.label.copyWith(color: colors.text),
                ),
              if (containsGit)
                Text(
                  strings.containsGitRepository,
                  style: NbText.label.copyWith(color: colors.text),
                ),
            ],
          ),
        ),
      ],
    );
  }
}

class ActivityCardHeader extends StatelessWidget {
  const ActivityCardHeader({
    required this.title,
    required this.chip,
    super.key,
  });

  final String title;
  final Widget chip;

  @override
  Widget build(BuildContext context) {
    final colors = NbColors.of(context);
    return ConstrainedBox(
      constraints: const BoxConstraints(minHeight: 24),
      child: Row(
        children: [
          Expanded(
            child: Text(
              title,
              style: NbText.bodyStrong.copyWith(color: colors.text),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          const SizedBox(width: 8),
          chip,
        ],
      ),
    );
  }
}

class ActivityCardFooter extends StatelessWidget {
  const ActivityCardFooter({this.note, this.action, super.key});

  final String? note;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    final colors = NbColors.of(context);
    final note = this.note;
    final action = this.action;
    return Padding(
      padding: const EdgeInsets.only(top: 10),
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: 28),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            if (note != null)
              Flexible(
                child: Text(
                  note,
                  style: NbText.caption.copyWith(color: colors.textWeak),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
              )
            else
              const SizedBox.shrink(),
            if (action != null) ...[const SizedBox(width: 8), action],
          ],
        ),
      ),
    );
  }
}

Widget buttonBar(List<Widget> children) {
  return OverflowBar(
    spacing: 8,
    overflowSpacing: 8,
    alignment: MainAxisAlignment.end,
    children: children,
  );
}

Widget inlineButtonBar(List<Widget> children) {
  return IntrinsicWidth(child: buttonBar(children));
}

class ActivityPanel extends StatelessWidget {
  const ActivityPanel({
    required this.controller,
    required this.state,
    super.key,
  });

  final AppController controller;
  final NodeState state;

  @override
  Widget build(BuildContext context) {
    final colors = NbColors.of(context);
    final strings = AppStringsDelegate.of(context);
    final outgoing = state.outgoing;
    final incoming = state.incoming;
    final sent = state.lastSent;
    final received = state.lastReceived;
    final queues = state.queues;
    final previous = state.lastQueues;
    final cards = <Widget>[
      if (queues != null && !queues.finished)
        QueueCard(
          key: const ValueKey('activity-queues'),
          controller: controller,
          state: state,
          queues: queues,
        )
      else if (queues == null && outgoing != null)
        _OutgoingCard(
          key: const ValueKey('activity-outgoing'),
          controller: controller,
          view: outgoing,
          tracked: state.selectionProgress != null,
        ),
      if (incoming != null && _isActive(incoming.stage))
        _IncomingCard(
          key: const ValueKey('activity-incoming'),
          controller: controller,
          view: incoming,
        ),
      if (queues != null && queues.finished)
        QueueCard(
          key: const ValueKey('activity-queues'),
          controller: controller,
          state: state,
          queues: queues,
        )
      else if (queues == null && previous != null)
        QueueCard(
          key: const ValueKey('activity-last-queues'),
          controller: controller,
          state: state,
          queues: previous,
        )
      else if (sent != null && queues == null)
        ResultCard(
          key: const ValueKey('activity-last-sent'),
          controller: controller,
          result: sent,
        ),
      if (received != null)
        ResultCard(
          key: const ValueKey('activity-last-received'),
          controller: controller,
          result: received,
        ),
    ];
    if (cards.isEmpty) {
      return Text(
        strings.activityEmpty,
        style: NbText.bodySm.copyWith(color: colors.textWeak),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (var i = 0; i < cards.length; i++) ...[
          if (i > 0) const SizedBox(height: _cardGap),
          cards[i],
        ],
      ],
    );
  }
}

class _OutgoingCard extends StatelessWidget {
  const _OutgoingCard({
    required this.controller,
    required this.view,
    required this.tracked,
    super.key,
  });

  final AppController controller;
  final OutgoingTransferView view;
  final bool tracked;

  @override
  Widget build(BuildContext context) {
    final colors = NbColors.of(context);
    final strings = AppStringsDelegate.of(context);
    final language = Localizations.localeOf(context).languageCode;
    final name = peerLabel(view.peerName, view.peerFingerprint);
    final phase = view.phase;
    final transferring =
        phase == OutgoingPhase.uploading || phase == OutgoingPhase.verifying;
    final folder = view.isFolder;
    final summary = view.summary;
    final waitingDetail = summary != null
        ? strings.folderSummary(
            summary.files,
            formatSize(summary.totalBytes, language),
          )
        : folder && view.fileCount > 0
        ? strings.folderSummary(view.fileCount, formatSize(view.size, language))
        : formatSize(view.size, language);
    final detail = switch (phase) {
      OutgoingPhase.preparing =>
        folder
            ? strings.preparingItems(view.preparedEntries)
            : strings.preparingFile(shortenFileName(view.fileName)),
      OutgoingPhase.requesting || OutgoingPhase.waiting => waitingDetail,
      OutgoingPhase.uploading ||
      OutgoingPhase.verifying => strings.progressLine(
        percentOf(view.sentBytes, view.size),
        formatSize(view.sentBytes, language),
        formatSize(view.size, language),
      ),
    };
    final extraDetails = [
      if (folder && transferring && view.fileCount > 0)
        strings.filesProgress(view.sentFiles, view.fileCount),
    ];
    final note = switch (phase) {
      OutgoingPhase.requesting => strings.contactingPeer(name),
      OutgoingPhase.waiting => strings.waitingAcceptance(name),
      OutgoingPhase.verifying => strings.peerCheckingFile(name),
      _ => null,
    };
    return Armed(
      armKey: (view.peerFingerprint, view.fileName),
      builder: (context, armed) {
        return NbCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              ActivityCardHeader(
                title: strings.sendingToTitle(name),
                chip: StatusChip(
                  label: outgoingChipText(strings, phase),
                  tone: outgoingTone(phase),
                ),
              ),
              const SizedBox(height: 10),
              FileRow(
                fileName: view.fileName,
                isProgram: view.isProgram && !folder,
                isFolder: folder,
                detail: detail,
                extraDetails: extraDetails,
              ),
              if (folder && summary != null)
                FolderSummaryLines(summary: summary, topGap: 8),
              if (transferring) ...[
                const SizedBox(height: 12),
                SelectionProgressBuilder(
                  track: ProgressTrack.outgoing,
                  enabled: tracked,
                  fallback: phase == OutgoingPhase.verifying
                      ? 1
                      : percentOf(view.sentBytes, view.size) / 100,
                  builder: (context, value, _) => NbProgressBar(value: value),
                ),
              ],
              ActivityCardFooter(
                note: note,
                action: view.cancelling
                    ? Flexible(
                        child: Text(
                          strings.cancellingTransfer,
                          style: NbText.caption.copyWith(
                            color: colors.textWeak,
                          ),
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                      )
                    : inlineButtonBar([
                        OutlinedButton(
                          style: smallButton,
                          onPressed: armed ? controller.cancelSending : null,
                          child: Text(strings.cancelButton),
                        ),
                      ]),
              ),
            ],
          ),
        );
      },
    );
  }
}

class _IncomingCard extends StatelessWidget {
  const _IncomingCard({
    required this.controller,
    required this.view,
    super.key,
  });

  final AppController controller;
  final IncomingTransferView view;

  @override
  Widget build(BuildContext context) {
    final strings = AppStringsDelegate.of(context);
    final language = Localizations.localeOf(context).languageCode;
    final id = view.sessionId;
    final name = peerLabel(view.peerName, view.peerFingerprint);
    final stage = view.stage;
    final transferring =
        stage == IncomingStage.receiving || stage == IncomingStage.verifying;
    final detail = transferring
        ? strings.progressLine(
            percentOf(view.receivedBytes, view.size),
            formatSize(view.receivedBytes, language),
            formatSize(view.size, language),
          )
        : formatSize(view.size, language);
    final extraDetails = [
      if (view.isFolder && transferring && view.fileCount > 0)
        strings.filesProgress(view.receivedFiles, view.fileCount),
    ];
    final note = switch (stage) {
      IncomingStage.waitingData => strings.waitingForData,
      IncomingStage.verifying => strings.checkingFile,
      _ => null,
    };
    final folder = view.folder;
    return Armed(
      armKey: (
        view.sessionId,
        view.stage,
        folder?.kind,
        folder?.problem,
        folder?.problemPath,
        folder?.cautionPath,
        folder?.afterEnd,
      ),
      builder: (context, armed) {
        return NbCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              ActivityCardHeader(
                title: strings.receivingFromTitle(name),
                chip: StatusChip(
                  label: incomingChipText(strings, stage),
                  tone: incomingTone(stage),
                ),
              ),
              const SizedBox(height: 10),
              FileRow(
                fileName: view.fileName,
                isProgram: view.isProgram,
                isFolder: view.isFolder,
                detail: detail,
                extraDetails: extraDetails,
              ),
              if (transferring) ...[
                const SizedBox(height: 12),
                SelectionProgressBuilder(
                  track: ProgressTrack.incoming,
                  fallback: stage == IncomingStage.verifying
                      ? 1
                      : percentOf(view.receivedBytes, view.size) / 100,
                  builder: (context, value, _) => NbProgressBar(value: value),
                ),
              ],
              ActivityCardFooter(
                note: note,
                action: !view.canCancel
                    ? null
                    : inlineButtonBar([
                        OutlinedButton(
                          style: smallButton,
                          onPressed: armed
                              ? () => controller.cancelReceiving(id)
                              : null,
                          child: Text(strings.cancelButton),
                        ),
                      ]),
              ),
            ],
          ),
        );
      },
    );
  }
}

class ResultCard extends StatelessWidget {
  const ResultCard({required this.controller, required this.result, super.key});

  final AppController controller;
  final TransferResultView result;

  Future<void> _reveal(BuildContext context) async {
    final messenger = ScaffoldMessenger.of(context);
    final strings = AppStringsDelegate.of(context);
    final revealed = await controller.revealLastReceived();
    switch (revealed) {
      case RevealResult.shown:
        break;
      case RevealResult.folderOnly:
        messenger.showSnackBar(
          SnackBar(content: Text(strings.revealFolderOnly)),
        );
      case RevealResult.unavailable:
        messenger.showSnackBar(
          SnackBar(content: Text(strings.folderUnavailable)),
        );
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = NbColors.of(context);
    final strings = AppStringsDelegate.of(context);
    final outgoing = result.direction == TransferDirection.outgoing;
    final name = peerLabel(result.peerName, result.peerFingerprint);
    final language = Localizations.localeOf(context).languageCode;
    final tone = resultTone(result.outcome.kind);
    final folder = result.isFolder;
    final Widget? icon = switch (tone) {
      ChipTone.ok => const GlyphIcon(Glyphs.check, size: 12),
      ChipTone.fail => const GlyphIcon(Glyphs.ban, size: 12),
      _ => null,
    };
    return NbCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          ActivityCardHeader(
            title: outgoing ? strings.lastSentTitle : strings.lastReceivedTitle,
            chip: StatusChip(
              label: resultChipText(strings, result),
              tone: tone,
              icon: icon,
            ),
          ),
          const SizedBox(height: 10),
          FileRow(
            fileName: result.fileName,
            isProgram: result.isProgram,
            isFolder: folder,
            containsGit: result.containsGitRepository,
            detail: outgoing ? strings.toPeer(name) : strings.fromPeer(name),
            extraDetails: [
              if (folder && result.fileCount > 0)
                strings.folderSummary(
                  result.fileCount,
                  formatSize(result.size, language),
                ),
            ],
          ),
          const SizedBox(height: 10),
          Text(
            outcomeLine(
              strings,
              result.outcome,
              outgoing: outgoing,
              isFolder: folder,
              problemPath: result.problemPath,
            ),
            style: NbText.bodySm.copyWith(color: colors.textWeak),
          ),
          if (result.canReveal) ...[
            const SizedBox(height: 8),
            buttonBar([
              TextButton.icon(
                style: smallButton,
                onPressed: () => _reveal(context),
                icon: const GlyphIcon(Glyphs.folder, size: 14),
                label: Text(strings.showInFolderButton),
              ),
            ]),
          ],
        ],
      ),
    );
  }
}
