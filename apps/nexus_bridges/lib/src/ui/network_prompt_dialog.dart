import 'dart:async';

import 'package:flutter/material.dart';
import 'package:nexus_bridges_core/nexus_bridges_core.dart';

import '../app_controller.dart';
import '../l10n/app_strings.dart';

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
  Route<Object?>? route;
  bool closedByHost = false;
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
      if (!prompts.any((prompt) => prompt.networkId == open.prompt.networkId)) {
        _closeWithoutAnswer(open);
      }
      return;
    }
    final next = prompts
        .where((prompt) => !_answered.contains(prompt.networkId))
        .firstOrNull;
    if (next != null) _show(next);
  }

  void _show(NetworkPrompt prompt) {
    final navigator = Navigator.of(context);
    final route = DialogRoute<NetworkDecision>(
      context: context,
      barrierDismissible: true,
      builder: (_) => _NetworkPromptDialog(prompt),
    );
    final open = _OpenDialog(prompt)..route = route;
    _open = open;
    navigator.push(route).then((decision) => _answer(open, decision));
  }

  void _answer(_OpenDialog open, NetworkDecision? decision) {
    if (open.closedByHost || !identical(_open, open) || !mounted) return;
    _open = null;
    final networkId = open.prompt.networkId;
    _answered.add(networkId);
    if (decision == null) {
      widget.controller.dismissPrompt(networkId);
    } else {
      unawaited(widget.controller.decideNetwork(networkId, decision));
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

class _NetworkPromptDialog extends StatelessWidget {
  const _NetworkPromptDialog(this.prompt);

  final NetworkPrompt prompt;

  @override
  Widget build(BuildContext context) {
    final strings = AppStringsDelegate.of(context);
    return AlertDialog(
      scrollable: true,
      title: Text(strings.networkPromptTitle),
      content: Text(strings.networkPromptBody(prompt.networkName)),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(NetworkDecision.untrusted),
          child: Text(strings.no),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(NetworkDecision.trusted),
          child: Text(strings.yes),
        ),
      ],
    );
  }
}
