import 'dart:async';

import 'package:flutter/material.dart';
import 'package:nexus_bridges_core/nexus_bridges_core.dart';

import '../app_controller.dart';
import '../l10n/app_strings.dart';

const int _shortFingerprintLength = 8;

const Duration dialogActivationDelay = Duration(milliseconds: 500);

String formatCode(String code) {
  return '${code.substring(0, 3)} ${code.substring(3)}';
}

Future<bool> confirmUnpair(BuildContext context, String name) async {
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (dialogContext) {
      final strings = AppStringsDelegate.of(dialogContext);
      return AlertDialog(
        scrollable: true,
        title: Text(strings.unpairTitle(name)),
        content: Text(strings.unpairBody(name)),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: Text(strings.cancelButton),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: Text(strings.unpairButton),
          ),
        ],
      );
    },
  );
  return confirmed ?? false;
}

String _shortFingerprint(String fingerprint) {
  return fingerprint.length > _shortFingerprintLength
      ? fingerprint.substring(0, _shortFingerprintLength)
      : fingerprint;
}

String _peerLabel(PairingView view) {
  final name = view.peerName;
  if (name == null || name.isEmpty) {
    return _shortFingerprint(view.peerFingerprint);
  }
  return name;
}

class PairingHost extends StatefulWidget {
  const PairingHost({required this.controller, required this.child, super.key});

  final AppController controller;
  final Widget child;

  @override
  State<PairingHost> createState() => _PairingHostState();
}

class _OpenDialog {
  _OpenDialog.pairing() : question = null;

  _OpenDialog.question(PairingQuestion this.question);

  final PairingQuestion? question;
  Route<Object?>? route;
  bool closedByHost = false;
}

class _PairingHostState extends State<PairingHost> {
  _OpenDialog? _open;
  final Set<PairingQuestion> _answered = {};

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_sync);
    WidgetsBinding.instance.addPostFrameCallback((_) => _sync());
  }

  @override
  void didUpdateWidget(PairingHost oldWidget) {
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
    final state = widget.controller.state;
    final pairing = state?.pairing;
    final questions = state?.questions ?? const <PairingQuestion>[];
    _answered.retainAll(questions);
    final open = _open;
    if (open != null) {
      final question = open.question;
      final stillWanted = question == null
          ? pairing != null
          : pairing == null && questions.contains(question);
      if (!stillWanted) _closeWithoutAnswer(open);
      return;
    }
    if (pairing != null) {
      _showPairing();
      return;
    }
    final next = questions
        .where((question) => !_answered.contains(question))
        .firstOrNull;
    if (next != null) _showQuestion(next);
  }

  void _showPairing() {
    final navigator = Navigator.of(context);
    final route = DialogRoute<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => _PairingDialog(widget.controller),
    );
    final open = _OpenDialog.pairing()..route = route;
    _open = open;
    navigator.push(route).then((_) => _routeEnded(open));
  }

  void _showQuestion(PairingQuestion question) {
    final navigator = Navigator.of(context);
    final route = DialogRoute<bool>(
      context: context,
      barrierDismissible: true,
      builder: (_) => _QuestionDialog(question),
    );
    final open = _OpenDialog.question(question)..route = route;
    _open = open;
    navigator.push(route).then((answer) => _answerQuestion(open, answer));
  }

  void _routeEnded(_OpenDialog open) {
    if (open.closedByHost || !identical(_open, open) || !mounted) return;
    _open = null;
    _sync();
  }

  void _answerQuestion(_OpenDialog open, bool? answer) {
    final question = open.question;
    if (question == null ||
        open.closedByHost ||
        !identical(_open, open) ||
        !mounted) {
      return;
    }
    _open = null;
    _answered.add(question);
    final yes = answer ?? false;
    switch (question) {
      case ReplaceQuestion():
        unawaited(
          widget.controller.answerReplace(question.fingerprint, replace: yes),
        );
      case MineQuestion():
        unawaited(
          widget.controller.answerMine(question.fingerprint, mine: yes),
        );
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

class _PairingDialog extends StatefulWidget {
  const _PairingDialog(this.controller);

  final AppController controller;

  @override
  State<_PairingDialog> createState() => _PairingDialogState();
}

class _PairingDialogState extends State<_PairingDialog> {
  Object? _contentKey;
  bool _armed = false;
  Timer? _timer;

  AppController get controller => widget.controller;

  Object _currentKey() {
    final state = controller.state;
    final view = state?.pairing;
    return (
      view?.role,
      view?.phase,
      view?.peerFingerprint,
      view?.outcome,
      view?.code,
      view?.alreadyPaired,
      state?.pairingNamesake,
    );
  }

  @override
  void initState() {
    super.initState();
    _contentKey = _currentKey();
    _arm();
    controller.addListener(_onControllerChanged);
  }

  @override
  void dispose() {
    _timer?.cancel();
    controller.removeListener(_onControllerChanged);
    super.dispose();
  }

  void _arm() {
    _timer?.cancel();
    _timer = Timer(dialogActivationDelay, () {
      if (mounted) setState(() => _armed = true);
    });
  }

  void _onControllerChanged() {
    if (!mounted) return;
    final next = _currentKey();
    if (next == _contentKey) return;
    setState(() {
      _contentKey = next;
      _armed = false;
    });
    _arm();
  }

  VoidCallback? _whenArmed(VoidCallback action) => _armed ? action : null;

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      child: ListenableBuilder(
        listenable: controller,
        builder: (context, _) {
          final view = controller.state?.pairing;
          if (view == null) return const SizedBox.shrink();
          return _dialogFor(context, view);
        },
      ),
    );
  }

  Widget _dialogFor(BuildContext context, PairingView view) {
    final strings = AppStringsDelegate.of(context);
    final name = _peerLabel(view);
    if (view.phase == PairingPhase.finished) {
      return AlertDialog(
        scrollable: true,
        title: Text(strings.pairingResultTitle),
        content: Text(_outcomeText(strings, view.outcome, name)),
        actions: [
          FilledButton(
            onPressed: _whenArmed(controller.dismissPairing),
            child: Text(strings.closeButton),
          ),
        ],
      );
    }
    final isInitiator = view.role == PairingRole.initiator;
    if (isInitiator && view.phase == PairingPhase.connecting) {
      return AlertDialog(
        scrollable: true,
        title: Text(strings.pairingWithTitle(name)),
        content: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(
              width: 24,
              height: 24,
              child: CircularProgressIndicator(strokeWidth: 3),
            ),
            const SizedBox(width: 16),
            Flexible(child: Text(strings.connectingTo(name))),
          ],
        ),
        actions: [
          TextButton(
            onPressed: _whenArmed(controller.cancelPairing),
            child: Text(strings.cancelButton),
          ),
        ],
      );
    }
    final comparing = view.phase == PairingPhase.comparing;
    final code = view.code;
    final namesake = controller.state?.pairingNamesake;
    final showNamesake =
        namesake != null &&
        (comparing || view.phase == PairingPhase.waitingPeer);
    return AlertDialog(
      scrollable: true,
      title: Text(
        isInitiator
            ? strings.pairingWithTitle(name)
            : strings.pairingRequestTitle(name),
      ),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (!isInitiator && comparing)
            Text(
              strings.fingerprintLine(_shortFingerprint(view.peerFingerprint)),
            ),
          if (showNamesake)
            Text(
              strings.namesakeWarning(namesake),
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          if (comparing) Text(strings.compareCode(name)),
          if (code != null && code.length > 3)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 16),
              child: Center(
                child: Text(
                  formatCode(code),
                  style: Theme.of(context).textTheme.displaySmall,
                ),
              ),
            ),
          if (!isInitiator && comparing && view.alreadyPaired)
            Text(strings.alreadyPairedNote),
          if (!comparing)
            Text(
              isInitiator
                  ? strings.waitingForPeer(name)
                  : strings.receiverWaiting(name),
            ),
        ],
      ),
      actions: [
        if (comparing && isInitiator)
          TextButton(
            onPressed: _whenArmed(controller.cancelPairing),
            child: Text(strings.cancelButton),
          ),
        if (comparing && !isInitiator && !view.alreadyPaired)
          TextButton(
            onPressed: _whenArmed(
              () => controller.answerRequest(ReceiverAnswer.ignore),
            ),
            child: Text(strings.ignoreDeviceButton),
          ),
        if (comparing)
          TextButton(
            onPressed: _whenArmed(
              () => isInitiator
                  ? controller.answerCode(matches: false)
                  : controller.answerRequest(ReceiverAnswer.mismatch),
            ),
            child: Text(strings.doesNotMatchButton),
          ),
        if (comparing)
          FilledButton(
            onPressed: _whenArmed(
              () => isInitiator
                  ? controller.answerCode(matches: true)
                  : controller.answerRequest(ReceiverAnswer.matches),
            ),
            child: Text(strings.matchesButton),
          ),
      ],
    );
  }

  String _outcomeText(
    AppStrings strings,
    PairingOutcome? outcome,
    String name,
  ) {
    return switch (outcome) {
      PairingOutcome.paired => strings.outcomePaired(name),
      PairingOutcome.rejected => strings.outcomeRejected(name),
      PairingOutcome.busy => strings.outcomeBusy(name),
      PairingOutcome.paused => strings.outcomePaused(name),
      PairingOutcome.cancelledByPeer => strings.outcomeCancelledByPeer(name),
      PairingOutcome.expired => strings.outcomeExpired,
      PairingOutcome.lost => strings.outcomeLost(name),
      PairingOutcome.networkChanged => strings.outcomeNetworkChanged,
      PairingOutcome.failed || null => strings.outcomeFailed(name),
      PairingOutcome.notSaved => strings.outcomeNotSaved,
    };
  }
}

class _QuestionDialog extends StatefulWidget {
  const _QuestionDialog(this.question);

  final PairingQuestion question;

  @override
  State<_QuestionDialog> createState() => _QuestionDialogState();
}

class _QuestionDialogState extends State<_QuestionDialog> {
  bool _armed = false;
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _timer = Timer(dialogActivationDelay, () {
      if (mounted) setState(() => _armed = true);
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  VoidCallback? _answer(bool value) =>
      _armed ? () => Navigator.of(context).pop(value) : null;

  @override
  Widget build(BuildContext context) {
    final strings = AppStringsDelegate.of(context);
    final question = widget.question;
    return switch (question) {
      ReplaceQuestion() => AlertDialog(
        scrollable: true,
        title: Text(strings.replaceTitle(question.oldName)),
        content: Text(
          strings.replaceBody(question.deviceName, question.oldName),
        ),
        actions: [
          TextButton(
            onPressed: _answer(false),
            child: Text(strings.keepBothButton),
          ),
          FilledButton(
            onPressed: _answer(true),
            child: Text(strings.replaceButton),
          ),
        ],
      ),
      MineQuestion() => AlertDialog(
        scrollable: true,
        title: Text(strings.mineTitle(question.deviceName)),
        content: Text(strings.mineBody),
        actions: [
          TextButton(
            onPressed: _answer(false),
            child: Text(strings.mineNoButton),
          ),
          FilledButton(
            onPressed: _answer(true),
            child: Text(strings.mineYesButton),
          ),
        ],
      ),
    };
  }
}
