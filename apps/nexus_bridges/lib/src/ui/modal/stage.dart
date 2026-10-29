import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import '../theme/tokens.dart';
import 'bridge.dart';
import 'stage_choices.dart';
import 'stage_kit.dart';
import 'stage_outcomes.dart';
import 'stage_waiting.dart';

const double _viewWidth = 300;

StageSceneFn _painterOf(StageScene scene) => switch (scene) {
  StageScene.connecting => paintConnecting,
  StageScene.comparing => paintComparing,
  StageScene.waiting => paintWaiting,
  StageScene.paired => paintPaired,
  StageScene.rejected => paintRejected,
  StageScene.busy => paintBusy,
  StageScene.paused => paintPaused,
  StageScene.cancelledByPeer => paintCancelledByPeer,
  StageScene.expired => paintExpired,
  StageScene.lost => paintLost,
  StageScene.networkChanged => paintNetworkChanged,
  StageScene.failed => paintFailed,
  StageScene.notSaved => paintNotSaved,
  StageScene.mine => paintMineSwitch,
  StageScene.unpairLoop => paintUnpairLoop,
  StageScene.unpairBreak => paintUnpairBreak,
  StageScene.network => paintNetwork,
  StageScene.exit => paintExit,
};

Color _toneOf(StageScene scene, StageInput input, NbColors colors) =>
    switch (scene) {
      StageScene.connecting ||
      StageScene.waiting ||
      StageScene.mine ||
      StageScene.unpairLoop ||
      StageScene.exit => colors.primary,
      StageScene.comparing || StageScene.expired => colors.warningRing,
      StageScene.paired => colors.success,
      StageScene.rejected ||
      StageScene.cancelledByPeer ||
      StageScene.failed ||
      StageScene.notSaved ||
      StageScene.unpairBreak => colors.danger,
      StageScene.busy || StageScene.networkChanged => colors.textWeak,
      StageScene.paused => colors.ice,
      StageScene.lost => colors.warning,
      StageScene.network => input.trusted ? colors.success : colors.textWeak,
    };

class StagePainter extends CustomPainter {
  StagePainter({
    required this.scene,
    required this.input,
    required this.colors,
    required this.still,
    required this.changes,
    this.size,
    required ValueListenable<double> elapsed,
  }) : _elapsed = elapsed,
       super(repaint: elapsed);

  final StageScene scene;
  final StageInput input;
  final NbColors colors;
  final bool still;
  final StageChanges changes;
  final StageSize? size;
  final ValueListenable<double> _elapsed;

  @override
  void paint(Canvas canvas, Size canvasSize) {
    final spec = stageSpecOf(scene, input);
    final time = _elapsed.value;
    final frame = StageFrame(
      t: time.isNaN ? 0 : time,
      still: still,
      colors: colors,
      input: input,
      changes: changes,
    );
    canvas.save();
    canvas.scale(canvasSize.width / _viewWidth);
    final viewTop = (size ?? spec.size).viewTop;
    if (viewTop != 0) canvas.translate(0, -viewTop);
    paintHalo(canvas, frame, _toneOf(scene, input, colors));
    _painterOf(scene)(canvas, frame);
    canvas.restore();
  }

  @override
  bool shouldRepaint(StagePainter oldDelegate) =>
      oldDelegate.scene != scene ||
      oldDelegate.input != input ||
      !identical(oldDelegate.colors, colors) ||
      oldDelegate.still != still ||
      oldDelegate.changes != changes ||
      oldDelegate.size != size;
}

class ModalStage extends StatefulWidget {
  const ModalStage({
    required this.scene,
    this.input = const StageInput(),
    this.size,
    super.key,
  });

  final StageScene scene;
  final StageInput input;
  final StageSize? size;

  @override
  State<ModalStage> createState() => _ModalStageState();
}

class _ModalStageState extends State<ModalStage>
    with SingleTickerProviderStateMixin {
  final ValueNotifier<double> _elapsed = ValueNotifier<double>(0);
  late final Ticker _ticker;
  late NbColors _colors;
  double _base = 0;
  bool _reduceMotion = false;
  StageChanges _changes = const StageChanges();
  Own? _hovered;

  StageInput get _input => StageInput(
    peer: widget.input.peer,
    hovered: _hovered,
    picked: widget.input.picked,
    trusted: widget.input.trusted,
    transfer: widget.input.transfer,
  );

  @override
  void initState() {
    super.initState();
    _hovered = widget.input.hovered;
    _ticker = createTicker(_onTick);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _colors = NbColors.of(context);
    _reduceMotion = MediaQuery.disableAnimationsOf(context);
    _syncTicker();
  }

  @override
  void didUpdateWidget(ModalStage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.scene != widget.scene) {
      _hovered = widget.input.hovered;
      _changes = const StageChanges();
      _base = 0;
      _elapsed.value = 0;
      _ticker.stop();
      _syncTicker();
      return;
    }
    _recordChanges(oldWidget.input);
    _syncTicker();
  }

  @override
  void dispose() {
    _ticker.dispose();
    _elapsed.dispose();
    super.dispose();
  }

  void _recordChanges(StageInput old) {
    final next = widget.input;
    final hoverChanged = next.picked == null && next.hovered != _hovered;
    final pickChanged = next.picked != old.picked;
    final trustChanged = next.trusted != old.trusted;
    if (_reduceMotion) {
      if (hoverChanged) _hovered = next.hovered;
      return;
    }

    final now = _elapsed.value;
    final before = _changes;
    var knobFrom = before.knobFrom;
    if (widget.scene == StageScene.mine && (hoverChanged || pickChanged)) {
      knobFrom = mineKnobX(
        StageFrame(
          t: now,
          still: false,
          colors: _colors,
          input: StageInput(
            peer: old.peer,
            hovered: _hovered,
            picked: old.picked,
            trusted: old.trusted,
            transfer: old.transfer,
          ),
          changes: before,
        ),
      );
    }
    _changes = StageChanges(
      hoveredAt: hoverChanged ? now : before.hoveredAt,
      hoveredFrom: hoverChanged ? _hovered : before.hoveredFrom,
      pickedAt: pickChanged ? now : before.pickedAt,
      pickedFrom: pickChanged ? old.picked : before.pickedFrom,
      trustedAt: trustChanged ? now : before.trustedAt,
      trustedFrom: trustChanged ? old.trusted : before.trustedFrom,
      knobFrom: knobFrom,
    );
    if (hoverChanged) _hovered = next.hovered;
  }

  bool _isDone(double t) {
    final spec = stageSpecOf(widget.scene, _input);
    return !spec.loops &&
        t >= spec.introEnd &&
        t >= _changes.lastAt + spec.changeEnd;
  }

  void _syncTicker() {
    if (_reduceMotion) {
      if (_ticker.isActive) _ticker.stop();
      return;
    }
    if (_ticker.isActive || _isDone(_elapsed.value)) return;
    _base = _elapsed.value;
    _ticker.start();
  }

  void _onTick(Duration elapsed) {
    final t = _base + elapsed.inMicroseconds / Duration.microsecondsPerSecond;
    _elapsed.value = t;
    if (_isDone(t)) _ticker.stop();
  }

  @override
  Widget build(BuildContext context) {
    final input = _input;
    final size = widget.size ?? stageSpecOf(widget.scene, input).size;
    return ExcludeSemantics(
      child: RepaintBoundary(
        child: SizedBox(
          width: size.width,
          height: size.height + size.margin,
          child: Align(
            alignment: Alignment.topCenter,
            child: CustomPaint(
              size: Size(size.width, size.height),
              painter: StagePainter(
                scene: widget.scene,
                input: input,
                colors: NbColors.of(context),
                still: _reduceMotion,
                changes: _changes,
                size: size,
                elapsed: _elapsed,
              ),
            ),
          ),
        ),
      ),
    );
  }
}
