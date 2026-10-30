import 'dart:async';

import 'package:flutter/material.dart';
import 'package:nexus_bridges_core/nexus_bridges_core.dart';

import '../app_controller.dart';
import '../l10n/app_strings.dart';
import 'armed.dart';
import 'icons/device_disc.dart';
import 'icons/glyphs.dart';
import 'modal/code_boxes.dart';
import 'modal/modal_button.dart';
import 'modal/modal_frame.dart';
import 'modal/stage.dart';
import 'modal/stage_kit.dart';
import 'pairing_questions.dart';
import 'theme/app_theme.dart';
import 'theme/tokens.dart';

export 'armed.dart' show dialogActivationDelay;

const int _shortFingerprintLength = 8;

const Duration pairedStillHold = Duration(milliseconds: 1500);

const Duration pairedSceneHold = Duration(milliseconds: 1200);

String formatCode(String code) {
  return '${code.substring(0, 3)} ${code.substring(3)}';
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

DeviceGlyph _peerGlyph(NodeState? state, String fingerprint) {
  for (final entry in state?.entries ?? const <DeviceEntry>[]) {
    if (entry.fingerprint == fingerprint) {
      return deviceGlyphOf(entry.deviceType);
    }
  }
  return DeviceGlyph.pc;
}

sealed class _FlowItem {
  const _FlowItem();

  Object get viewKey;
}

final class _PairingItem extends _FlowItem {
  const _PairingItem(
    this.view,
    this.namesake,
    this.peer,
    this.questionsPending,
  );

  final PairingView view;
  final String? namesake;
  final DeviceGlyph peer;
  final bool questionsPending;

  @override
  Object get viewKey =>
      ('pairing', view.role, view.phase, view.outcome, view.peerFingerprint);

  @override
  bool operator ==(Object other) =>
      other is _PairingItem &&
      other.view == view &&
      other.namesake == namesake &&
      other.peer == peer &&
      other.questionsPending == questionsPending;

  @override
  int get hashCode => Object.hash(view, namesake, peer, questionsPending);
}

final class _QuestionItem extends _FlowItem {
  const _QuestionItem(this.question);

  final PairingQuestion question;

  @override
  Object get viewKey => ('question', question);

  @override
  bool operator ==(Object other) =>
      other is _QuestionItem && other.question == question;

  @override
  int get hashCode => question.hashCode;
}

final class _FlowRoute {
  _FlowRoute(_FlowItem first) : item = ValueNotifier<_FlowItem>(first);

  final ValueNotifier<_FlowItem> item;
  late final NbModalRoute<void> route;
  bool closedByHost = false;
}

class PairingHost extends StatefulWidget {
  const PairingHost({required this.controller, required this.child, super.key});

  final AppController controller;
  final Widget child;

  @override
  State<PairingHost> createState() => _PairingHostState();
}

class _PairingHostState extends State<PairingHost> {
  _FlowRoute? _open;
  final Set<PairingQuestion> _answered = {};
  MineQuestion? _leaving;

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
    final open = _open;
    _open = null;
    if (open != null) {
      open.closedByHost = true;
      final route = open.route;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (route.isActive) route.navigator?.removeRoute(route);
      });
    }
    super.dispose();
  }

  _FlowItem? _currentItem() {
    final state = widget.controller.state;
    final view = state?.pairing;
    final next = (state?.questions ?? const <PairingQuestion>[])
        .where((question) => !_answered.contains(question))
        .firstOrNull;
    if (view != null) {
      _leaving = null;
      return _PairingItem(
        view,
        state?.pairingNamesake,
        _peerGlyph(state, view.peerFingerprint),
        next != null,
      );
    }
    final leaving = _leaving;
    if (leaving != null) return _QuestionItem(leaving);
    return next == null ? null : _QuestionItem(next);
  }

  void _sync() {
    if (!mounted) return;
    _answered.retainAll(
      widget.controller.state?.questions ?? const <PairingQuestion>[],
    );
    final item = _currentItem();
    final open = _open;
    if (item == null) {
      if (open != null) _close(open);
      return;
    }
    if (open != null) {
      open.item.value = item;
      return;
    }
    _show(item);
  }

  void _show(_FlowItem first) {
    final navigator = Navigator.of(context);
    final open = _FlowRoute(first);
    open.route = NbModalRoute<void>(
      context: context,
      builder: (_) => PopScope(
        canPop: false,
        child: ValueListenableBuilder<_FlowItem>(
          valueListenable: open.item,
          builder: (context, item, _) =>
              ModalViewSwitcher(viewKey: item.viewKey, child: _viewOf(item)),
        ),
      ),
      onDismiss: () {
        if (open.closedByHost) return null;
        return switch (open.item.value) {
          _QuestionItem(:final question) when question != _leaving =>
            () => _answer(question, false),
          _ => null,
        };
      },
    );
    _open = open;
    navigator.push(open.route).then((_) => _routeEnded(open));
  }

  Widget _viewOf(_FlowItem item) {
    return switch (item) {
      _PairingItem() => _PairingView(
        controller: widget.controller,
        view: item.view,
        namesake: item.namesake,
        peer: item.peer,
        questionsPending: item.questionsPending,
      ),
      _QuestionItem() => PairingQuestionView(
        controller: widget.controller,
        question: item.question,
        onAnswer: (value, {farewell = false}) =>
            _answer(item.question, value, farewell: farewell),
        onFarewellDone: _onFarewellDone,
      ),
    };
  }

  void _routeEnded(_FlowRoute open) {
    open.item.dispose();
    if (open.closedByHost || !identical(_open, open) || !mounted) return;
    _open = null;
    _sync();
  }

  void _close(_FlowRoute open) {
    open.closedByHost = true;
    _open = null;
    final route = open.route;
    final navigator = route.navigator;
    if (navigator == null || !route.isActive) return;
    if (route.isCurrent) {
      navigator.pop();
    } else {
      navigator.removeRoute(route);
    }
  }

  void _answer(PairingQuestion question, bool value, {bool farewell = false}) {
    if (!mounted || _answered.contains(question) || question == _leaving) {
      return;
    }
    _answered.add(question);
    _leaving = farewell && question is MineQuestion ? question : null;
    switch (question) {
      case ReplaceQuestion():
        unawaited(
          widget.controller.answerReplace(question.fingerprint, replace: value),
        );
      case MineQuestion():
        unawaited(
          widget.controller.answerMine(question.fingerprint, mine: value),
        );
    }
    _sync();
  }

  void _onFarewellDone() {
    if (!mounted) return;
    _leaving = null;
    _sync();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

class _PairingView extends StatefulWidget {
  const _PairingView({
    required this.controller,
    required this.view,
    required this.namesake,
    required this.peer,
    required this.questionsPending,
  });

  final AppController controller;
  final PairingView view;
  final String? namesake;
  final DeviceGlyph peer;
  final bool questionsPending;

  @override
  State<_PairingView> createState() => _PairingViewState();
}

class _PairingViewState extends State<_PairingView>
    with ArmingState<_PairingView> {
  Object? _contentKey;
  Timer? _sceneTimer;
  bool _sceneStarted = false;
  bool _sceneDone = false;
  bool _advanced = false;

  AppController get controller => widget.controller;

  bool get _showsPaired =>
      widget.view.phase == PairingPhase.finished &&
      widget.view.outcome == PairingOutcome.paired;

  bool get _advancesAlone =>
      _showsPaired && (widget.view.isNew || widget.questionsPending);

  Duration _sceneLength() {
    if (MediaQuery.disableAnimationsOf(context)) return pairedStillHold;
    final spec = stageSpecOf(
      stageForOutcome(PairingOutcome.paired),
      StageInput(peer: widget.peer),
    );
    return Duration(
          microseconds: (spec.introEnd * Duration.microsecondsPerSecond)
              .round(),
        ) +
        pairedSceneHold;
  }

  void _onSceneDone() {
    _sceneTimer = null;
    if (!mounted) return;
    _sceneDone = true;
    _advance();
  }

  void _advance() {
    if (!mounted || !_sceneDone || _advanced || !_advancesAlone) return;
    final activity = context.getInheritedWidgetOfExactType<ModalViewActivity>();
    if (activity?.leaving ?? false) return;
    if (controller.state?.pairing != widget.view) return;
    _advanced = true;
    controller.dismissPairing();
  }

  Object _currentKey() {
    final view = widget.view;
    return (
      view.role,
      view.phase,
      view.peerFingerprint,
      view.outcome,
      view.code,
      view.alreadyPaired,
      widget.namesake,
      controller.state?.pickerOpen,
    );
  }

  @override
  void initState() {
    super.initState();
    _contentKey = _currentKey();
    controller.addListener(_onControllerChanged);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_sceneStarted || !_showsPaired) return;
    _sceneStarted = true;
    _sceneTimer = Timer(_sceneLength(), _onSceneDone);
  }

  @override
  void didUpdateWidget(_PairingView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller.removeListener(_onControllerChanged);
      widget.controller.addListener(_onControllerChanged);
    }
    final next = _currentKey();
    if (next != _contentKey) {
      _contentKey = next;
      rearm();
    }
    if (_sceneDone && !_advanced) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _advance());
    }
  }

  @override
  void dispose() {
    _sceneTimer?.cancel();
    controller.removeListener(_onControllerChanged);
    super.dispose();
  }

  void _onControllerChanged() {
    if (!mounted) return;
    final next = _currentKey();
    if (next == _contentKey) return;
    setState(() {
      _contentKey = next;
      rearm();
    });
  }

  VoidCallback? _whenArmed(VoidCallback action) =>
      armed && controller.state?.pickerOpen != true ? action : null;

  @override
  Widget build(BuildContext context) {
    final strings = AppStringsDelegate.of(context);
    final view = widget.view;
    final name = _peerLabel(view);
    final isInitiator = view.role == PairingRole.initiator;
    return switch (view.phase) {
      PairingPhase.finished => _finishedView(strings, view, name),
      PairingPhase.connecting when isInitiator => _connectingView(
        strings,
        name,
      ),
      PairingPhase.comparing => _comparingView(
        strings,
        view,
        name,
        isInitiator,
      ),
      _ => _waitingView(strings, view, name, isInitiator),
    };
  }

  String _titleOf(AppStrings strings, String name, bool isInitiator) =>
      isInitiator
      ? strings.pairingWithTitle(name)
      : strings.pairingRequestTitle(name);

  Widget _connectingView(AppStrings strings, String name) {
    return ModalView(
      stage: ModalStage(
        scene: StageScene.connecting,
        input: StageInput(peer: widget.peer),
      ),
      title: strings.pairingWithTitle(name),
      body: [ModalLead(text: strings.connectingTo(name))],
      actions: [
        ModalButton(
          label: strings.cancelButton,
          kind: ModalButtonKind.neutral,
          onPressed: _whenArmed(controller.cancelPairing),
        ),
      ],
    );
  }

  Widget _comparingView(
    AppStrings strings,
    PairingView view,
    String name,
    bool isInitiator,
  ) {
    final namesake = widget.namesake;
    final code = view.code;
    return ModalView(
      layout: ModalViewLayout.centered,
      stage: ModalStage.fill(
        scene: StageScene.comparing,
        input: StageInput(peer: widget.peer),
      ),
      stageFill: StageFit.range,
      title: _titleOf(strings, name, isInitiator),
      body: [
        if (code != null) CodeBoxes(code: code),
        if (!isInitiator)
          _FingerprintLine(
            strings: strings,
            short: _shortFingerprint(view.peerFingerprint),
          ),
        if (namesake != null)
          ModalAlert(text: strings.namesakeWarning(namesake)),
        ModalLead(text: strings.compareCode(name)),
        if (!isInitiator && view.alreadyPaired)
          ModalNote(text: strings.alreadyPairedNote),
      ],
      pair: [
        ModalButton(
          label: strings.doesNotMatchButton,
          kind: ModalButtonKind.negative,
          glyph: Glyphs.cross,
          inPair: true,
          onPressed: _whenArmed(
            () => isInitiator
                ? controller.answerCode(matches: false)
                : controller.answerRequest(ReceiverAnswer.mismatch),
          ),
        ),
        ModalButton(
          label: strings.matchesButton,
          kind: ModalButtonKind.primary,
          glyph: Glyphs.tick,
          inPair: true,
          onPressed: _whenArmed(
            () => isInitiator
                ? controller.answerCode(matches: true)
                : controller.answerRequest(ReceiverAnswer.matches),
          ),
        ),
      ],
      actions: [
        if (isInitiator)
          ModalButton(
            label: strings.cancelButton,
            kind: ModalButtonKind.neutral,
            onPressed: _whenArmed(controller.cancelPairing),
          )
        else if (!view.alreadyPaired)
          ModalButton(
            label: strings.ignoreDeviceButton,
            kind: ModalButtonKind.negative,
            onPressed: _whenArmed(
              () => controller.answerRequest(ReceiverAnswer.ignore),
            ),
          ),
      ],
    );
  }

  Widget _waitingView(
    AppStrings strings,
    PairingView view,
    String name,
    bool isInitiator,
  ) {
    final namesake = widget.namesake;
    final code = view.code;
    return ModalView(
      stage: ModalStage.fill(
        scene: StageScene.waiting,
        input: StageInput(peer: widget.peer),
      ),
      stageFill: StageFit.range,
      title: _titleOf(strings, name, isInitiator),
      body: [
        if (code != null) CodeBoxes(code: code, confirmed: true),
        if (namesake != null)
          ModalAlert(text: strings.namesakeWarning(namesake)),
        Padding(
          padding: const EdgeInsets.only(top: 6),
          child: ModalLead(
            text: isInitiator
                ? strings.waitingForPeer(name)
                : strings.receiverWaiting(name),
          ),
        ),
      ],
      actions: [
        if (view.phase == PairingPhase.waitingPeer)
          ModalButton(
            label: strings.cancelButton,
            kind: ModalButtonKind.neutral,
            onPressed: _whenArmed(
              isInitiator ? controller.cancelPairing : controller.cancelRequest,
            ),
          ),
      ],
    );
  }

  Widget _finishedView(AppStrings strings, PairingView view, String name) {
    final outcome = view.outcome;
    return ModalView(
      layout: ModalViewLayout.result,
      eyebrow: ModalEyebrow(
        text: strings.pairingEyebrow(outcome),
        tone: _toneOf(outcome),
      ),
      stage: ModalStage(
        scene: stageForOutcome(outcome),
        input: StageInput(peer: widget.peer),
      ),
      title: _outcomeText(strings, outcome, name),
      actions: [
        if (!_advancesAlone)
          ModalButton(
            label: strings.closeButton,
            kind: ModalButtonKind.primary,
            onPressed: _whenArmed(controller.dismissPairing),
          ),
      ],
    );
  }

  EyebrowTone _toneOf(PairingOutcome? outcome) {
    return switch (outcome) {
      PairingOutcome.paired => EyebrowTone.ok,
      PairingOutcome.rejected ||
      PairingOutcome.cancelledByPeer ||
      PairingOutcome.failed ||
      PairingOutcome.notSaved ||
      null => EyebrowTone.bad,
      PairingOutcome.expired || PairingOutcome.lost => EyebrowTone.warn,
      PairingOutcome.paused => EyebrowTone.ice,
      PairingOutcome.busy ||
      PairingOutcome.networkChanged => EyebrowTone.neutral,
    };
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

class _FingerprintLine extends StatelessWidget {
  const _FingerprintLine({required this.strings, required this.short});

  final AppStrings strings;
  final String short;

  @override
  Widget build(BuildContext context) {
    final colors = NbColors.of(context);
    final base = NbText.body.copyWith(
      fontSize: 12,
      height: 16 / 12,
      color: colors.textWeak,
      fontFeatures: const [FontFeature.tabularFigures()],
    );
    return Padding(
      padding: const EdgeInsets.only(top: 6),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 320),
        child: Text.rich(
          emphasized(
            strings.fingerprintLine,
            short,
            base: base,
            strong: base.copyWith(
              color: colors.text,
              fontWeight: FontWeight.w600,
              letterSpacing: 12 * 0.06,
            ),
          ),
          textAlign: TextAlign.center,
        ),
      ),
    );
  }
}
