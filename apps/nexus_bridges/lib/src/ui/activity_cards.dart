import 'package:flutter/material.dart';
import 'package:nexus_bridges_core/nexus_bridges_core.dart';

import '../app_controller.dart';
import '../l10n/app_strings.dart';
import 'armed.dart';
import 'format.dart';
import 'icons/file_icon.dart';
import 'icons/glyphs.dart';
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

String _peerLabel(String? name, String fingerprint) {
  if (name != null && name.isNotEmpty) return name;
  return fingerprint.length > _shortFingerprintLength
      ? fingerprint.substring(0, _shortFingerprintLength)
      : fingerprint;
}

bool _isActive(IncomingStage stage) =>
    stage == IncomingStage.waitingData ||
    stage == IncomingStage.receiving ||
    stage == IncomingStage.verifying;

class FileRow extends StatelessWidget {
  const FileRow({
    required this.fileName,
    required this.isProgram,
    required this.detail,
    super.key,
  });

  final String fileName;
  final bool isProgram;
  final String detail;

  @override
  Widget build(BuildContext context) {
    final colors = NbColors.of(context);
    final strings = AppStringsDelegate.of(context);
    final nameStyle = NbText.bodyStrong.copyWith(color: colors.text);
    final textScaler = MediaQuery.textScalerOf(context);
    final textDirection = Directionality.of(context);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        FileIcon(fileName: fileName, isProgram: isProgram),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              LayoutBuilder(
                builder: (context, constraints) {
                  final shown = fitFileName(
                    fileName,
                    style: nameStyle,
                    maxWidth: constraints.maxWidth,
                    textScaler: textScaler,
                    textDirection: textDirection,
                  );
                  return Text(
                    shown,
                    style: nameStyle,
                    maxLines: 1,
                    softWrap: false,
                    overflow: TextOverflow.clip,
                  );
                },
              ),
              Text(
                detail,
                style: NbText.caption.copyWith(color: colors.textWeak),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
              if (isProgram)
                Text(
                  strings.programLabel,
                  style: NbText.label.copyWith(color: colors.text),
                ),
            ],
          ),
        ),
      ],
    );
  }
}

class _CardHeader extends StatelessWidget {
  const _CardHeader({required this.title, required this.chip});

  final String title;
  final Widget chip;

  @override
  Widget build(BuildContext context) {
    final colors = NbColors.of(context);
    return ConstrainedBox(
      constraints: const BoxConstraints(minHeight: 24),
      child: Row(
        children: [
          Flexible(
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

class _CardFooter extends StatelessWidget {
  const _CardFooter({this.note, this.action});

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

Widget _buttonBar(List<Widget> children) {
  return OverflowBar(
    spacing: 8,
    overflowSpacing: 8,
    alignment: MainAxisAlignment.end,
    children: children,
  );
}

Widget _inlineButtonBar(List<Widget> children) {
  return IntrinsicWidth(child: _buttonBar(children));
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
    final cards = <Widget>[
      if (outgoing != null)
        _OutgoingCard(
          key: const ValueKey('activity-outgoing'),
          controller: controller,
          view: outgoing,
        ),
      if (incoming != null && _isActive(incoming.stage))
        _IncomingCard(
          key: const ValueKey('activity-incoming'),
          controller: controller,
          view: incoming,
        ),
      if (sent != null)
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
    super.key,
  });

  final AppController controller;
  final OutgoingTransferView view;

  @override
  Widget build(BuildContext context) {
    final colors = NbColors.of(context);
    final strings = AppStringsDelegate.of(context);
    final language = Localizations.localeOf(context).languageCode;
    final name = _peerLabel(view.peerName, view.peerFingerprint);
    final phase = view.phase;
    final transferring =
        phase == OutgoingPhase.uploading || phase == OutgoingPhase.verifying;
    final detail = switch (phase) {
      OutgoingPhase.preparing => strings.preparingFile(
        shortenFileName(view.fileName),
      ),
      OutgoingPhase.requesting ||
      OutgoingPhase.waiting => formatSize(view.size, language),
      OutgoingPhase.uploading ||
      OutgoingPhase.verifying => strings.progressLine(
        percentOf(view.sentBytes, view.size),
        formatSize(view.sentBytes, language),
        formatSize(view.size, language),
      ),
    };
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
              _CardHeader(
                title: strings.sendingToTitle(name),
                chip: StatusChip(
                  label: outgoingChipText(strings, phase),
                  tone: outgoingTone(phase),
                ),
              ),
              const SizedBox(height: 10),
              FileRow(
                fileName: view.fileName,
                isProgram: view.isProgram,
                detail: detail,
              ),
              if (transferring) ...[
                const SizedBox(height: 12),
                NbProgressBar(
                  value: phase == OutgoingPhase.verifying
                      ? 1
                      : percentOf(view.sentBytes, view.size) / 100,
                ),
              ],
              _CardFooter(
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
                    : _inlineButtonBar([
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
    final name = _peerLabel(view.peerName, view.peerFingerprint);
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
              _CardHeader(
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
                detail: detail,
              ),
              if (transferring) ...[
                const SizedBox(height: 12),
                NbProgressBar(
                  value: stage == IncomingStage.verifying
                      ? 1
                      : percentOf(view.receivedBytes, view.size) / 100,
                ),
              ],
              _CardFooter(
                note: note,
                action: stage == IncomingStage.verifying
                    ? null
                    : _inlineButtonBar([
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
    final name = _peerLabel(result.peerName, result.peerFingerprint);
    final tone = resultTone(result.outcome.kind);
    final Widget? icon = switch (tone) {
      ChipTone.ok => const GlyphIcon(Glyphs.check, size: 12),
      ChipTone.fail => const GlyphIcon(Glyphs.ban, size: 12),
      _ => null,
    };
    return NbCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _CardHeader(
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
            detail: outgoing ? strings.toPeer(name) : strings.fromPeer(name),
          ),
          const SizedBox(height: 10),
          Text(
            outgoing
                ? strings.sentOutcome(result.outcome)
                : strings.receivedOutcome(result.outcome),
            style: NbText.bodySm.copyWith(color: colors.textWeak),
          ),
          if (result.canReveal) ...[
            const SizedBox(height: 8),
            _buttonBar([
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
