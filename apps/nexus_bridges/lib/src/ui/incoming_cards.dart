import 'package:flutter/material.dart';
import 'package:nexus_bridges_core/nexus_bridges_core.dart';

import '../app_controller.dart';
import '../l10n/app_strings.dart';
import 'armed.dart';
import 'activity_cards.dart';
import 'format.dart';
import 'shown_name.dart';
import 'icons/glyphs.dart';
import 'theme/app_theme.dart';
import 'theme/components.dart';
import 'theme/tokens.dart';

const int _shortFingerprintLength = 8;

const double _discSize = 32;

bool hasIncomingCard(NodeState state) {
  final view = state.incoming;
  if (view == null) return false;
  return switch (view.stage) {
    IncomingStage.warning => true,
    IncomingStage.folderQuestion => view.folder != null,
    IncomingStage.ended => true,
    IncomingStage.waitingData ||
    IncomingStage.receiving ||
    IncomingStage.verifying => false,
  };
}

class IncomingCards extends StatelessWidget {
  const IncomingCards({
    required this.controller,
    required this.state,
    super.key,
  });

  final AppController controller;
  final NodeState state;

  @override
  Widget build(BuildContext context) {
    final view = state.incoming;
    if (view == null || !hasIncomingCard(state)) return const SizedBox.shrink();
    final folder = view.folder;
    final armKey = (
      view.sessionId,
      view.stage,
      folder?.kind,
      folder?.problem,
      folder?.problemPath,
      folder?.cautionPath,
      folder?.afterEnd,
      folder?.afterEndPath,
      folder?.pickerOpen,
      folder?.inspecting,
      state.pickerOpen,
    );
    return Armed(
      armKey: armKey,
      builder: (context, armed) => switch (view.stage) {
        IncomingStage.warning => _WarningCard(
          controller: controller,
          view: view,
          namesake: state.incomingNamesake,
          pickerOpen: state.pickerOpen,
          armed: armed,
        ),
        IncomingStage.folderQuestion => _FolderQuestionCard(
          controller: controller,
          view: view,
          folder: folder!,
          namesake: state.incomingNamesake,
          pickerOpen: state.pickerOpen,
          armed: armed,
        ),
        _ => _EndedCard(
          controller: controller,
          view: view,
          pickerOpen: state.pickerOpen,
          armed: armed,
        ),
      },
    );
  }
}

String _senderName(
  IncomingTransferView view,
  AppStrings strings,
  NodeState? state,
) {
  final name = view.peerName;
  if (name == null || name.isEmpty) return _shortFingerprint(view);
  return shownPeerName(strings, state, view.peerFingerprint, name);
}

String _shortFingerprint(IncomingTransferView view) {
  final fingerprint = view.peerFingerprint;
  return fingerprint.length > _shortFingerprintLength
      ? fingerprint.substring(0, _shortFingerprintLength)
      : fingerprint;
}

class _Disc extends StatelessWidget {
  const _Disc({required this.glyph, required this.fill, required this.ink});

  final Glyph glyph;
  final Color fill;
  final Color ink;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: _discSize,
      height: _discSize,
      decoration: BoxDecoration(color: fill, shape: BoxShape.circle),
      alignment: Alignment.center,
      child: GlyphIcon(glyph, size: 18, color: ink),
    );
  }
}

class _CardHeader extends StatelessWidget {
  const _CardHeader({required this.disc, required this.children});

  final Widget disc;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        disc,
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: children,
          ),
        ),
      ],
    );
  }
}

class _Buttons extends StatelessWidget {
  const _Buttons({required this.children, this.order});

  final List<Widget> children;
  final List<int>? order;

  @override
  Widget build(BuildContext context) {
    return FocusTraversalGroup(
      policy: OrderedTraversalPolicy(),
      child: OverflowBar(
        spacing: 8,
        overflowSpacing: 8,
        alignment: MainAxisAlignment.end,
        overflowAlignment: OverflowBarAlignment.end,
        children: [
          for (var i = 0; i < children.length; i++)
            FocusTraversalOrder(
              order: NumericFocusOrder((order?[i] ?? i + 1).toDouble()),
              child: children[i],
            ),
        ],
      ),
    );
  }
}

class _Namesake extends StatelessWidget {
  const _Namesake({required this.name});

  final String name;

  @override
  Widget build(BuildContext context) {
    final colors = NbColors.of(context);
    final strings = AppStringsDelegate.of(context);
    return Padding(
      padding: const EdgeInsets.only(top: 4),
      child: Text(
        strings.namesakeWarning(name),
        style: NbText.bodySm.copyWith(color: colors.danger),
      ),
    );
  }
}

class _Note extends StatelessWidget {
  const _Note({required this.text, this.strong = false});

  final String text;
  final bool strong;

  @override
  Widget build(BuildContext context) {
    final colors = NbColors.of(context);
    return Text(
      text,
      style: strong
          ? NbText.bodySm.copyWith(color: colors.text)
          : NbText.caption.copyWith(color: colors.textWeak),
    );
  }
}

class _FirstLevelList extends StatelessWidget {
  const _FirstLevelList({required this.items, required this.more});

  final List<FirstLevelItem> items;
  final int more;

  @override
  Widget build(BuildContext context) {
    final colors = NbColors.of(context);
    final strings = AppStringsDelegate.of(context);
    final nameStyle = NbText.bodySm.copyWith(color: colors.text);
    return Column(
      key: const ValueKey('first-level-list'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final item in items)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 2),
            child: Row(
              children: [
                GlyphIcon(
                  item.isFolder ? Glyphs.folder : Glyphs.files,
                  size: 14,
                  color: colors.textWeak,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: FittedName(name: item.name, style: nameStyle),
                ),
              ],
            ),
          ),
        if (more > 0)
          Padding(
            padding: const EdgeInsets.only(top: 2, left: 22),
            child: Text(
              strings.firstLevelMore(more),
              style: NbText.caption.copyWith(color: colors.textWeak),
            ),
          ),
      ],
    );
  }
}

class _WarningCard extends StatelessWidget {
  const _WarningCard({
    required this.controller,
    required this.view,
    required this.namesake,
    required this.pickerOpen,
    required this.armed,
  });

  final AppController controller;
  final IncomingTransferView view;
  final String? namesake;
  final bool pickerOpen;
  final bool armed;

  @override
  Widget build(BuildContext context) {
    final id = view.sessionId;
    final colors = NbColors.of(context);
    final strings = AppStringsDelegate.of(context);
    final language = Localizations.localeOf(context).languageCode;
    final namesake = this.namesake;
    final enabled = armed && !pickerOpen;
    return NbCard(
      ring: colors.warningRing,
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          _CardHeader(
            disc: _Disc(
              glyph: Glyphs.warn,
              fill: colors.warningWeak,
              ink: colors.warning,
            ),
            children: [
              Text(
                view.isFolder
                    ? strings.incomingFolderRequestTitle(
                        _senderName(view, strings, controller.state),
                      )
                    : strings.incomingRequestTitle(
                        _senderName(view, strings, controller.state),
                      ),
                style: NbText.title.copyWith(color: colors.text),
              ),
              const SizedBox(height: 3),
              Text(
                strings.foreignSenderNote(_shortFingerprint(view)),
                style: NbText.caption.copyWith(
                  color: colors.textWeak,
                  height: 17 / 12,
                ),
              ),
              if (namesake != null) _Namesake(name: namesake),
            ],
          ),
          const SizedBox(height: 12),
          DecoratedBox(
            decoration: BoxDecoration(
              color: colors.surfaceWeak,
              borderRadius: BorderRadius.circular(10),
            ),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                mainAxisSize: MainAxisSize.min,
                children: [
                  FileRow(
                    fileName: view.fileName,
                    isProgram: view.isProgram,
                    isFolder: view.isFolder,
                    containsGit: view.containsGitRepository,
                    detail: view.isFolder
                        ? strings.folderSummary(
                            view.fileCount,
                            formatSize(view.size, language),
                          )
                        : formatSize(view.size, language),
                  ),
                  if (view.isFolder && view.firstLevel.isNotEmpty) ...[
                    const SizedBox(height: 8),
                    _FirstLevelList(
                      items: view.firstLevel,
                      more: view.moreFirstLevel,
                    ),
                  ],
                  if (view.withoutMark) ...[
                    const SizedBox(height: 8),
                    _Note(text: strings.withoutMarkNote),
                  ],
                ],
              ),
            ),
          ),
          const SizedBox(height: 12),
          _Note(text: strings.incomingExpiresNote),
          const SizedBox(height: 8),
          _Buttons(
            children: [
              OutlinedButton(
                onPressed: enabled
                    ? () => controller.answerIncoming(id, accept: false)
                    : null,
                child: Text(strings.rejectButton),
              ),
              FilledButton(
                onPressed: enabled
                    ? () => controller.answerIncoming(id, accept: true)
                    : null,
                child: Text(strings.acceptButton),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

String? _problemLine(AppStrings strings, FolderQuestionView folder) {
  final path = breakablePath(folder.problemPath ?? folder.proposedPath);
  if (path.isEmpty) return null;
  return switch (folder.problem) {
    FolderProblem.forbidden => strings.folderForbidden(path),
    FolderProblem.cannotUse => strings.folderCannotUse(path),
    FolderProblem.unknownVolume => strings.folderUnknownVolume(path),
    FolderProblem.stillUnavailable => strings.folderStillUnavailable(path),
    FolderProblem.adminShare => strings.folderAdminShare(path),
    FolderProblem.rememberedUnavailable || null => null,
  };
}

List<String> _cautionLines(AppStrings strings, FolderQuestionView folder) {
  final cautionPath = folder.cautionPath;
  if (cautionPath == null) return const [];
  final path = breakablePath(cautionPath);
  return [
    if (folder.cautionNoMark) strings.cautionNoMark(path),
    if (folder.cautionRemote) strings.cautionRemote(path),
  ];
}

class _FolderQuestionCard extends StatelessWidget {
  const _FolderQuestionCard({
    required this.controller,
    required this.view,
    required this.folder,
    required this.namesake,
    required this.pickerOpen,
    required this.armed,
  });

  final AppController controller;
  final IncomingTransferView view;
  final FolderQuestionView folder;
  final String? namesake;
  final bool pickerOpen;
  final bool armed;

  @override
  Widget build(BuildContext context) {
    final id = view.sessionId;
    final colors = NbColors.of(context);
    final strings = AppStringsDelegate.of(context);
    final namesake = this.namesake;
    final enabled =
        armed && !(folder.pickerOpen || folder.inspecting) && !pickerOpen;
    final problem = _problemLine(strings, folder);
    final cautions = _cautionLines(strings, folder);
    final hasProposal = folder.proposedPath.isNotEmpty;
    final withCaution = folder.cautionPath != null;
    return NbCard(
      ring: colors.warningRing,
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          _CardHeader(
            disc: _Disc(
              glyph: Glyphs.folder,
              fill: colors.warningWeak,
              ink: colors.warning,
            ),
            children: [
              Text(
                strings.folderQuestionTitle(
                  _senderName(view, strings, controller.state),
                ),
                style: NbText.title.copyWith(color: colors.text),
              ),
              if (namesake != null) _Namesake(name: namesake),
            ],
          ),
          const SizedBox(height: 12),
          _Note(
            text: folder.kind == FolderQuestionKind.firstTime
                ? strings.folderFirstTimeBody
                : strings.folderThisTimeBody,
            strong: true,
          ),
          if (hasProposal) ...[
            const SizedBox(height: 8),
            DecoratedBox(
              decoration: BoxDecoration(
                color: colors.surfaceWeak,
                borderRadius: BorderRadius.circular(10),
              ),
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 10,
                ),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Padding(
                      padding: const EdgeInsets.only(top: 2),
                      child: GlyphIcon(
                        Glyphs.folder,
                        size: 14,
                        color: colors.textWeak,
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: _Note(
                        text: strings.proposedFolderLine(
                          breakablePath(folder.proposedPath),
                        ),
                        strong: true,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
          if (problem != null) ...[
            const SizedBox(height: 8),
            _Note(text: problem, strong: true),
          ],
          for (final line in cautions) ...[
            const SizedBox(height: 8),
            _Note(text: line, strong: true),
          ],
          if (folder.pickerOpen) ...[
            const SizedBox(height: 8),
            _Note(text: strings.pickerOpenNote),
          ],
          if (folder.inspecting) ...[
            const SizedBox(height: 8),
            _Note(text: strings.checkingFolder),
          ],
          const SizedBox(height: 12),
          _Buttons(
            order: withCaution ? const [2, 1] : null,
            children: withCaution
                ? [
                    OutlinedButton(
                      onPressed: enabled
                          ? () => controller.useFolderAnyway(id)
                          : null,
                      child: Text(strings.useAnywayButton),
                    ),
                    FilledButton(
                      onPressed: enabled
                          ? () => controller.chooseOtherFolder(id)
                          : null,
                      child: Text(strings.chooseOtherFolderButton),
                    ),
                  ]
                : [
                    OutlinedButton(
                      onPressed: enabled
                          ? () => controller.cancelFolderQuestion(id)
                          : null,
                      child: Text(strings.cancelButton),
                    ),
                    OutlinedButton(
                      onPressed: enabled
                          ? () => controller.chooseOtherFolder(id)
                          : null,
                      child: Text(strings.chooseOtherFolderButton),
                    ),
                    if (hasProposal)
                      FilledButton(
                        onPressed: enabled
                            ? () => controller.useProposedFolder(id)
                            : null,
                        child: Text(strings.useThisFolderButton),
                      ),
                  ],
          ),
        ],
      ),
    );
  }
}

class _EndedCard extends StatelessWidget {
  const _EndedCard({
    required this.controller,
    required this.view,
    required this.pickerOpen,
    required this.armed,
  });

  final AppController controller;
  final IncomingTransferView view;
  final bool pickerOpen;
  final bool armed;

  @override
  Widget build(BuildContext context) {
    final id = view.sessionId;
    final colors = NbColors.of(context);
    final strings = AppStringsDelegate.of(context);
    final folder = view.folder;
    final busyPicker = folder?.pickerOpen ?? false;
    final inspecting = folder?.inspecting ?? false;
    final afterEnd = folder?.afterEnd;
    final path = folder?.afterEndPath;
    final enabled = armed && !pickerOpen;
    final notes = <String>[];
    var asksToConfirm = false;
    if (!busyPicker && !inspecting && folder != null) {
      switch (afterEnd) {
        case AfterEndResult.remembered:
          if (path != null && path.isNotEmpty) {
            notes.add(strings.folderRememberedNote(path));
          }
        case AfterEndResult.notUsable:
          if (path != null && path.isNotEmpty) {
            notes.add(strings.folderNotUsable(path));
          }
        case AfterEndResult.needsConfirmation:
          asksToConfirm = true;
          notes.addAll(_cautionLines(strings, folder));
        case null:
          break;
      }
    }
    return NbCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          _CardHeader(
            disc: _Disc(
              glyph: Glyphs.folder,
              fill: colors.surfaceWeak,
              ink: colors.textWeak,
            ),
            children: [
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Text(
                  strings.transferAlreadyEnded,
                  style: NbText.bodyStrong.copyWith(color: colors.text),
                ),
              ),
              for (final note in notes) ...[
                const SizedBox(height: 4),
                _Note(text: note, strong: true),
              ],
              if (busyPicker) ...[
                const SizedBox(height: 4),
                _Note(text: strings.pickerOpenNote),
              ],
              if (inspecting) ...[
                const SizedBox(height: 4),
                _Note(text: strings.checkingFolder),
              ],
            ],
          ),
          if (!busyPicker && !inspecting) ...[
            const SizedBox(height: 12),
            _Buttons(
              children: asksToConfirm
                  ? [
                      FilledButton(
                        onPressed: enabled
                            ? () => controller.rememberFolderAfterEnd(
                                id,
                                remember: false,
                              )
                            : null,
                        child: Text(strings.dontRememberButton),
                      ),
                      OutlinedButton(
                        onPressed: enabled
                            ? () => controller.rememberFolderAfterEnd(
                                id,
                                remember: true,
                              )
                            : null,
                        child: Text(strings.rememberAnywayButton),
                      ),
                    ]
                  : [
                      OutlinedButton(
                        onPressed: enabled
                            ? () => controller.dismissFolderPanel(id)
                            : null,
                        child: Text(strings.closeButton),
                      ),
                    ],
            ),
          ],
        ],
      ),
    );
  }
}
