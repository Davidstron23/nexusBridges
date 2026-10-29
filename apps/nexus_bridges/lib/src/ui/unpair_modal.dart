import 'dart:async';

import 'package:flutter/material.dart';
import 'package:nexus_bridges_core/nexus_bridges_core.dart';

import '../l10n/app_strings.dart';
import 'icons/device_disc.dart';
import 'icons/glyphs.dart';
import 'modal/modal_button.dart';
import 'modal/modal_frame.dart';
import 'modal/stage.dart';
import 'modal/stage_kit.dart';

const Duration _breakDuration = Duration(milliseconds: 1500);

final class _Confirmation {
  bool confirmed = false;
}

Future<bool> confirmUnpairDevice(
  BuildContext context, {
  required String name,
  required DeviceType? type,
  required Future<void> Function() onConfirm,
}) async {
  final navigator = Navigator.of(context);
  final confirmation = _Confirmation();
  late final NbModalRoute<bool> route;
  route = NbModalRoute<bool>(
    context: context,
    builder: (_) => _UnpairView(
      name: name,
      type: type,
      confirmation: confirmation,
      onConfirm: onConfirm,
    ),
    onDismiss: () {
      if (confirmation.confirmed) return null;
      return () {
        if (route.isCurrent) navigator.pop(false);
      };
    },
  );
  final result = await navigator.push<bool>(route);
  return result ?? false;
}

class _UnpairView extends StatefulWidget {
  const _UnpairView({
    required this.name,
    required this.type,
    required this.confirmation,
    required this.onConfirm,
  });

  final String name;
  final DeviceType? type;
  final _Confirmation confirmation;
  final Future<void> Function() onConfirm;

  @override
  State<_UnpairView> createState() => _UnpairViewState();
}

class _UnpairViewState extends State<_UnpairView> {
  Timer? _closeTimer;
  bool _breaking = false;

  @override
  void dispose() {
    _closeTimer?.cancel();
    super.dispose();
  }

  void _cancel() {
    if (_breaking) return;
    Navigator.of(context).pop(false);
  }

  void _confirm() {
    if (_breaking) return;
    widget.confirmation.confirmed = true;
    unawaited(widget.onConfirm());
    if (MediaQuery.disableAnimationsOf(context)) {
      _breaking = true;
      Navigator.of(context).pop(true);
      return;
    }
    setState(() => _breaking = true);
    _closeTimer = Timer(_breakDuration, () {
      if (mounted) Navigator.of(context).pop(true);
    });
  }

  @override
  Widget build(BuildContext context) {
    final strings = AppStringsDelegate.of(context);
    final breaking = _breaking;
    final scene = breaking ? StageScene.unpairBreak : StageScene.unpairLoop;
    return ModalViewSwitcher(
      viewKey: scene,
      child: ModalView(
        stage: ModalStage(
          scene: scene,
          input: StageInput(peer: deviceGlyphOf(widget.type)),
        ),
        title: strings.unpairTitle(widget.name),
        body: [ModalLead(text: strings.unpairBody(widget.name))],
        pair: [
          ModalButton(
            label: strings.cancelButton,
            kind: ModalButtonKind.neutral,
            inPair: true,
            onPressed: breaking ? null : _cancel,
          ),
          ModalButton(
            label: strings.unpairButton,
            kind: ModalButtonKind.negative,
            glyph: Glyphs.unlink,
            inPair: true,
            onPressed: breaking ? null : _confirm,
          ),
        ],
      ),
    );
  }
}
