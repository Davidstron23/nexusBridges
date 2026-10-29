import 'dart:async';

import 'package:flutter/material.dart';
import 'package:nexus_bridges_core/nexus_bridges_core.dart';

import '../app_controller.dart';
import '../l10n/app_strings.dart';
import 'modal/modal_button.dart';
import 'modal/modal_frame.dart';
import 'modal/stage.dart';
import 'modal/stage_kit.dart';

class NetworkPromptHost extends StatefulWidget {
  const NetworkPromptHost({
    required this.controller,
    required this.child,
    super.key,
  });

  final AppController controller;
  final Widget child;

  @override
  State<NetworkPromptHost> createState() => _NetworkPromptHostState();
}

class _OpenDialog {
  _OpenDialog(this.prompt);

  final NetworkPrompt prompt;
  Route<void>? route;
  bool closedByHost = false;
  bool answered = false;
}

class _NetworkPromptHostState extends State<NetworkPromptHost> {
  _OpenDialog? _open;
  final Set<String> _answered = {};

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_sync);
    WidgetsBinding.instance.addPostFrameCallback((_) => _sync());
  }

  @override
  void didUpdateWidget(NetworkPromptHost oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller.removeListener(_sync);
      widget.controller.addListener(_sync);
    }
  }

  @override
  void dispose() {
    widget.controller.removeListener(_sync);
    super.dispose();
  }

  void _sync() {
    if (!mounted) return;
    final prompts = widget.controller.state?.prompts ?? const <NetworkPrompt>[];
    _answered.retainAll(prompts.map((prompt) => prompt.networkId));
    final open = _open;
    if (open != null) {
      final gone = !prompts.any(
        (prompt) => prompt.networkId == open.prompt.networkId,
      );
      if (gone && !open.answered) _closeWithoutAnswer(open);
      return;
    }
    final next = prompts
        .where((prompt) => !_answered.contains(prompt.networkId))
        .firstOrNull;
    if (next != null) _show(next);
  }

  void _show(NetworkPrompt prompt) {
    final navigator = Navigator.of(context);
    final open = _OpenDialog(prompt);
    final route = NbModalRoute<void>(
      context: context,
      builder: (_) => _NetworkPromptView(
        prompt: prompt,
        onDecide: (decision) => _decide(open, decision),
      ),
      onDismiss: () {
        if (open.answered) return null;
        return () {
          if (open.route?.isCurrent ?? false) navigator.pop();
        };
      },
    );
    open.route = route;
    _open = open;
    navigator.push(route).then((_) => _routeClosed(open));
  }

  void _decide(_OpenDialog open, NetworkDecision decision) {
    if (open.answered ||
        open.closedByHost ||
        !identical(_open, open) ||
        !mounted) {
      return;
    }
    open.answered = true;
    final networkId = open.prompt.networkId;
    _answered.add(networkId);
    unawaited(widget.controller.decideNetwork(networkId, decision));
  }

  void _routeClosed(_OpenDialog open) {
    if (open.closedByHost || !identical(_open, open) || !mounted) return;
    _open = null;
    if (!open.answered) {
      final networkId = open.prompt.networkId;
      _answered.add(networkId);
      widget.controller.dismissPrompt(networkId);
    }
    _sync();
  }

  void _closeWithoutAnswer(_OpenDialog open) {
    open.closedByHost = true;
    _open = null;
    final route = open.route;
    if (route != null && route.isActive) {
      route.navigator?.removeRoute(route);
    }
    _sync();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

class _NetworkPromptView extends StatefulWidget {
  const _NetworkPromptView({required this.prompt, required this.onDecide});

  final NetworkPrompt prompt;
  final void Function(NetworkDecision decision) onDecide;

  @override
  State<_NetworkPromptView> createState() => _NetworkPromptViewState();
}

class _NetworkPromptViewState extends State<_NetworkPromptView> {
  static const Duration _greenDuration = Duration(milliseconds: 900);

  Timer? _closeTimer;
  bool _decided = false;
  bool _trusted = false;

  @override
  void dispose() {
    _closeTimer?.cancel();
    super.dispose();
  }

  void _useNot() {
    if (_decided) return;
    _decided = true;
    widget.onDecide(NetworkDecision.untrusted);
    Navigator.of(context).pop();
  }

  void _useHere() {
    if (_decided) return;
    _decided = true;
    widget.onDecide(NetworkDecision.trusted);
    if (MediaQuery.disableAnimationsOf(context)) {
      Navigator.of(context).pop();
      return;
    }
    setState(() => _trusted = true);
    _closeTimer = Timer(_greenDuration, () {
      if (mounted) Navigator.of(context).pop();
    });
  }

  @override
  Widget build(BuildContext context) {
    final strings = AppStringsDelegate.of(context);
    return ModalView(
      stage: ModalStage(
        scene: StageScene.network,
        input: StageInput(trusted: _trusted),
      ),
      title: strings.networkPromptTitle,
      body: [
        ModalLead.rich(
          build: strings.networkPromptBody,
          strong: widget.prompt.networkName,
        ),
      ],
      pair: [
        ModalButton(
          label: strings.no,
          kind: ModalButtonKind.negative,
          inPair: true,
          onPressed: _decided ? null : _useNot,
        ),
        ModalButton(
          label: strings.yes,
          kind: ModalButtonKind.primary,
          inPair: true,
          onPressed: _decided ? null : _useHere,
        ),
      ],
    );
  }
}
