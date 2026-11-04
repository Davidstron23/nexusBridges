import 'package:flutter/material.dart';
import 'package:nexus_bridges_core/nexus_bridges_core.dart';

import '../../app_controller.dart';
import '../../l10n/app_strings.dart';
import '../format.dart';
import '../icons/folder_icon.dart';
import '../icons/glyphs.dart';
import '../theme/app_theme.dart';
import 'inline_confirm.dart';
import 'settings_field.dart';
import 'settings_section.dart';

String folderLeafOf(String path) {
  final parts = path.split(RegExp(r'[\\/]')).where((part) => part.isNotEmpty);
  return parts.isEmpty ? path : parts.last;
}

class ReceiveSection extends StatefulWidget {
  const ReceiveSection({required this.controller, super.key});

  final AppController controller;

  @override
  State<ReceiveSection> createState() => _ReceiveSectionState();
}

class _ReceiveSectionState extends State<ReceiveSection>
    with ConfirmCancelMixin<ReceiveSection> {
  FolderChangeNeedsConfirmation? _pending;
  FolderChangeRefused? _refused;
  bool _waiting = false;
  bool _blocked = false;

  void _forgetPending() {
    final pending = _pending;
    if (pending == null) return;
    _pending = null;
    unregisterConfirm();
    widget.controller.cancelReceiveFolderChange(pending.changeId);
  }

  @override
  void dispose() {
    final pending = _pending;
    if (pending != null) {
      widget.controller.cancelReceiveFolderChange(pending.changeId);
    }
    super.dispose();
  }

  Future<void> _change() async {
    if (_waiting) return;
    _forgetPending();
    setState(() {
      _waiting = true;
      _refused = null;
      _blocked = false;
    });
    final result = await widget.controller.changeReceiveFolder();
    if (!mounted) {
      if (result is FolderChangeNeedsConfirmation) {
        widget.controller.cancelReceiveFolderChange(result.changeId);
      }
      return;
    }
    setState(() {
      _waiting = false;
      switch (result) {
        case final FolderChangeRefused value:
          _refused = value;
        case FolderChangeBlocked():
          _blocked = true;
        case final FolderChangeNeedsConfirmation value:
          _pending = value;
        case FolderChanged() || FolderUnchanged():
          break;
      }
    });
    if (result is FolderChangeNeedsConfirmation) {
      registerConfirm(_cancelPending);
    }
  }

  void _cancelPending() {
    if (!mounted) return;
    setState(_forgetPending);
  }

  Future<void> _chooseOther() async {
    setState(_forgetPending);
    await _change();
  }

  Future<void> _confirm() async {
    final pending = _pending;
    if (pending == null) return;
    unregisterConfirm();
    setState(() {
      _pending = null;
      _waiting = true;
    });
    final result = await widget.controller.confirmReceiveFolder(
      pending.changeId,
    );
    if (!mounted) return;
    setState(() {
      _waiting = false;
      _blocked = result is FolderChangeBlocked;
    });
  }

  String _problemText(AppStrings strings, FolderChangeRefused refused) {
    final path = breakablePath(refused.path);
    return switch (refused.problem) {
      FolderProblem.forbidden => strings.folderForbidden(path),
      FolderProblem.adminShare => strings.folderAdminShare(path),
      FolderProblem.unknownVolume => strings.folderUnknownVolume(path),
      FolderProblem.cannotUse ||
      FolderProblem.rememberedUnavailable ||
      FolderProblem.stillUnavailable => strings.folderCannotUse(path),
    };
  }

  @override
  Widget build(BuildContext context) {
    final strings = AppStringsDelegate.of(context);
    return SettingsSection(
      icon: Glyphs.inbox,
      title: strings.sectionReceive,
      description: strings.receiveDesc,
      info: strings.receiveInfo,
      child: ListenableBuilder(
        listenable: widget.controller,
        builder: (context, _) {
          final state = widget.controller.state;
          final path = state?.settings.receiveFolder;
          final locked = state?.settings.receiveFolderLocked ?? false;
          final refused = _refused;
          final pending = _pending;
          String? message;
          var error = false;
          if (_waiting) {
            message = (state?.pickerOpen ?? false)
                ? strings.pickerOpenNote
                : strings.checkingFolder;
          } else if (refused != null) {
            message = _problemText(strings, refused);
            error = true;
          } else if (locked || _blocked) {
            message = strings.changeFolderLocked;
          }
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              SettingsWell(
                child: SettingsRow(
                  leading: const FolderIcon(height: 24),
                  title: path == null
                      ? strings.receiveNotSet
                      : folderLeafOf(path),
                  subtitle: path,
                  trailing: OutlinedButton(
                    onPressed: locked || _waiting ? null : _change,
                    style: smallButton,
                    child: Text(strings.changeFolderButton),
                  ),
                ),
              ),
              SettingsMessage(
                text: message,
                tone: error
                    ? SettingsMessageTone.error
                    : SettingsMessageTone.neutral,
              ),
              InlineConfirm(
                open: pending != null,
                message: pending == null
                    ? const SizedBox.shrink()
                    : Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          if (pending.noMark)
                            Text(
                              strings.cautionNoMark(
                                breakablePath(pending.path),
                              ),
                            ),
                          if (pending.noMark && pending.remote)
                            const SizedBox(height: 6),
                          if (pending.remote)
                            Text(
                              strings.cautionRemote(
                                breakablePath(pending.path),
                              ),
                            ),
                        ],
                      ),
                confirmLabel: strings.useAnywayButton,
                cancelLabel: strings.chooseOtherFolderButton,
                onConfirm: _confirm,
                onCancel: _chooseOther,
              ),
            ],
          );
        },
      ),
    );
  }
}
