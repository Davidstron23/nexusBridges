import 'dart:ui' show lerpDouble;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import '../theme/tokens.dart';
import 'bridge.dart';
import 'modal_frame.dart' show StageFill;
import 'stage_choices.dart';
import 'stage_kit.dart';
import 'stage_outcomes.dart';
import 'stage_waiting.dart';

const double _viewWidth = 300;
const StageSize _fillMin = StageSize.small;
const StageSize _fillMax = StageSize.big;

double _extentOf(StageSize size) => size.height + size.margin;

final class StageFit {
  const StageFit._({
    required this.width,
    required this.height,
    required this.margin,
    required this.viewTop,
  });

  factory StageFit.of(double extent) {
    final low = _extentOf(_fillMin);
    final high = _extentOf(_fillMax);
    final t = ((extent - low) / (high - low)).clamp(0.0, 1.0);
    final width = lerpDouble(_fillMin.width, _fillMax.width, t)!;
    final height = lerpDouble(_fillMin.height, _fillMax.height, t)!;
    return StageFit._(
      width: width,
      height: height,
      margin: lerpDouble(_fillMin.margin, _fillMax.margin, t)!,
      viewTop: stageCenter.dy - height * _viewWidth / width / 2,
    );
  }

  static StageFill get range =>
      StageFill(min: _extentOf(_fillMin), max: _extentOf(_fillMax));

  final double width;
  final double height;
  final double margin;
  final double viewTop;

  double get extent => height + margin;
}

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
    this.viewTop,
    required ValueListenable<double> elapsed,
  }) : _elapsed = elapsed,
       super(repaint: elapsed);

  final StageScene scene;
  final StageInput input;
  final NbColors colors;
  final bool still;
  final StageChanges changes;
  final StageSize? size;
  final double? viewTop;
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
    final viewTop = this.viewTop ?? (size ?? spec.size).viewTop;
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
      oldDelegate.size != size ||
      oldDelegate.viewTop != viewTop;
}

class ModalStage extends StatefulWidget {
  const ModalStage({
    required this.scene,
    this.input = const StageInput(),
    this.size,
    super.key,
  }) : fills = false;

  const ModalStage.fill({
    required this.scene,
    this.input = const StageInput(),
    super.key,
  }) : size = null,
       fills = true;

  final StageScene scene;
  final StageInput input;
  final StageSize? size;
  final bool fills;

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

  StagePainter _painter(StageInput input, StageSize? size, double? viewTop) =>
      StagePainter(
        scene: widget.scene,
        input: input,
        colors: NbColors.of(context),
        still: _reduceMotion,
        changes: _changes,
        size: size,
        viewTop: viewTop,
        elapsed: _elapsed,
      );

  Widget _box(
    double width,
    double height,
    double extent,
    StagePainter painter,
  ) {
    return ExcludeSemantics(
      child: RepaintBoundary(
        child: SizedBox(
          width: width,
          height: extent,
          child: Align(
            alignment: Alignment.topCenter,
            child: CustomPaint(size: Size(width, height), painter: painter),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final input = _input;
    if (widget.fills) {
      return LayoutBuilder(
        builder: (context, constraints) {
          final range = StageFit.range;
          final extent = constraints.maxHeight.isFinite
              ? constraints.maxHeight.clamp(range.min, range.max)
              : range.max;
          final fit = StageFit.of(extent);
          return _box(
            fit.width,
            fit.height,
            fit.extent,
            _painter(input, null, fit.viewTop),
          );
        },
      );
    }
    final size = widget.size ?? stageSpecOf(widget.scene, input).size;
    return _box(
      size.width,
      size.height,
      size.height + size.margin,
      _painter(input, size, null),
    );
  }
}
