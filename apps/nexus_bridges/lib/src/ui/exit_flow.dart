import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' show AppExitResponse;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:nexus_bridges_core/nexus_bridges_core.dart';

import '../app_controller.dart';
import '../l10n/app_strings.dart';
import 'armed.dart';
import 'diagram/flow_scene.dart';
import 'format.dart';
import 'icons/device_disc.dart';
import 'icons/file_icon.dart';
import 'modal/modal_button.dart';
import 'modal/modal_frame.dart';
import 'modal/stage.dart';
import 'modal/stage_kit.dart';
import 'theme/app_theme.dart';
import 'theme/tokens.dart';

const double _barWidth = 264;
const double _barHeight = 34;
const double _barRadius = 11;
const double _fillInset = 4;
const double _fillRadius = 7;
const double _solidTail = 56;
const double _insideMinimum = 44;
const double _numberPadding = 11;
const double _numberGap = 8;
const double _revealDelay = 0.15;
const double _revealSeconds = 0.9;
const double _sheenDelay = 1.2;
const double _sheenPeriod = 2.8;
const double _sheenTravel = 0.55;
const double _sheenWidth = 0.45;
const double _sheenFrom = -1;
const double _sheenTo = 2.4;
const double _sheenAlpha = 0.24;
const double _innerEdgeAlpha = 0.28;
const double _percentEpsilon = 1e-6;
const Duration _progressDuration = Duration(milliseconds: 900);
const Cubic _labEaseOut = Cubic(0.23, 1, 0.32, 1);

final class _ExitData {
  const _ExitData({required this.transfer, required this.progress});

  final ExitTransfer transfer;
  final double progress;
}

_ExitData? _exitDataOf(NodeState? state) {
  if (state == null) return null;
  final outgoing = state.outgoing;
  final incoming = state.incoming;
  final String fingerprint;
  final String fileName;
  final bool isProgram;
  if (outgoing != null) {
    fingerprint = outgoing.peerFingerprint;
    fileName = outgoing.fileName;
    isProgram = outgoing.isProgram;
  } else if (incoming != null) {
    fingerprint = incoming.peerFingerprint;
    fileName = incoming.fileName;
    isProgram = incoming.isProgram;
  } else {
    return null;
  }
  final link = linkFor(state, fingerprint);
  final entry = state.entries
      .where((entry) => entry.fingerprint == fingerprint)
      .firstOrNull;
  return _ExitData(
    transfer: ExitTransfer(
      peer: deviceGlyphOf(entry?.deviceType),
      kind: fileKindOf(fileName, isProgram: isProgram),
      towardsHub: outgoing == null,
    ),
    progress: link.progress,
  );
}

int _percentOf(double progress) =>
    (progress * 100 + _percentEpsilon).floor().clamp(0, 100);

Future<bool> confirmCloseDuringTransfer(
  BuildContext context,
  AppController controller,
) async {
  final navigator = Navigator.of(context);
  late final NbModalRoute<bool> route;
  route = NbModalRoute<bool>(
    context: context,
    builder: (_) => _ExitView(controller: controller),
    onDismiss: () => () {
      if (route.isCurrent) navigator.pop(false);
    },
  );
  final result = await navigator.push<bool>(route);
  return result ?? false;
}

class _ExitView extends StatefulWidget {
  const _ExitView({required this.controller});

  final AppController controller;

  @override
  State<_ExitView> createState() => _ExitViewState();
}

class _ExitViewState extends State<_ExitView> with ArmingState<_ExitView> {
  _ExitData? _data;

  @override
  bool get coverOnly => true;

  @override
  void initState() {
    super.initState();
    _data = _exitDataOf(widget.controller.state);
    widget.controller.addListener(_onController);
  }

  @override
  void didUpdateWidget(_ExitView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller.removeListener(_onController);
      widget.controller.addListener(_onController);
      _onController();
    }
  }

  @override
  void dispose() {
    widget.controller.removeListener(_onController);
    super.dispose();
  }

  void _onController() {
    final next = _exitDataOf(widget.controller.state);
    if (next == null || !mounted) return;
    setState(() => _data = next);
  }

  @override
  Widget build(BuildContext context) {
    final strings = AppStringsDelegate.of(context);
    final data = _data;
    return ModalView(
      stage: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          ModalStage(
            scene: StageScene.exit,
            input: StageInput(transfer: data?.transfer),
          ),
          if (data != null)
            Padding(
              padding: const EdgeInsets.only(top: 4, bottom: 16),
              child: _ExitBar(progress: data.progress),
            ),
        ],
      ),
      title: strings.closeDuringTransferTitle,
      body: [ModalLead(text: strings.closeDuringTransferBody)],
      actions: [
        ModalButton(
          label: strings.keepOpenButton,
          kind: ModalButtonKind.primary,
          onPressed: armed ? () => closeOwnRoute(context, false) : null,
        ),
        ModalButton(
          label: strings.closeAndCancelButton,
          kind: ModalButtonKind.negativeQuiet,
          onPressed: armed ? () => closeOwnRoute(context, true) : null,
        ),
      ],
    );
  }
}

class _ExitBar extends StatefulWidget {
  const _ExitBar({required this.progress});

  final double progress;

  @override
  State<_ExitBar> createState() => _ExitBarState();
}

class _ExitBarState extends State<_ExitBar>
    with SingleTickerProviderStateMixin {
  final ValueNotifier<double> _elapsed = ValueNotifier<double>(0);
  late final Ticker _ticker;
  bool _still = false;

  @override
  void initState() {
    super.initState();
    _ticker = createTicker(
      (elapsed) => _elapsed.value =
          elapsed.inMicroseconds / Duration.microsecondsPerSecond,
    );
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _still = MediaQuery.disableAnimationsOf(context);
    if (_still) {
      _ticker.stop();
    } else if (!_ticker.isActive) {
      _ticker.start();
    }
  }

  @override
  void dispose() {
    _ticker.dispose();
    _elapsed.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = NbColors.of(context);
    final language = Localizations.localeOf(context).languageCode;
    return Semantics(
      container: true,
      value: formatPercent(_percentOf(widget.progress), language),
      child: ExcludeSemantics(
        child: SizedBox(
          width: _barWidth,
          height: _barHeight,
          child: TweenAnimationBuilder<double>(
            tween: Tween<double>(end: widget.progress.clamp(0.0, 1.0)),
            duration: _still ? Duration.zero : _progressDuration,
            curve: _labEaseOut,
            builder: (context, progress, _) => ValueListenableBuilder<double>(
              valueListenable: _elapsed,
              builder: (context, time, _) => _barOf(
                colors: colors,
                language: language,
                progress: progress,
                time: time,
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _barOf({
    required NbColors colors,
    required String language,
    required double progress,
    required double time,
  }) {
    final fill = math.max(0.0, progress * _barWidth - _fillInset);
    final entry = ((time - _revealDelay) / _revealSeconds).clamp(0.0, 1.0);
    final reveal = _still ? 1.0 : _labEaseOut.transform(entry);
    final count = _still ? 1.0 : Curves.easeOutCubic.transform(entry);
    final shown = (_percentOf(progress) * count).round();
    final inside = fill >= _insideMinimum;
    final style = NbText.label.copyWith(
      fontSize: 13,
      fontWeight: FontWeight.w700,
      height: 1,
      letterSpacing: 0.13,
      color: inside ? colors.onPrimary : colors.textWeak,
      fontFeatures: const [FontFeature.tabularFigures()],
    );
    final number = Text(
      formatPercent(shown, language),
      maxLines: 1,
      softWrap: false,
      style: style,
    );
    final fillEnd = _fillInset + fill;
    return Stack(
      children: [
        Positioned.fill(
          child: CustomPaint(
            painter: _ExitBarPainter(
              colors: colors,
              fill: fill,
              reveal: reveal,
              time: time,
              still: _still,
            ),
          ),
        ),
        if (inside)
          Positioned.fill(
            child: ClipRect(
              clipper: _RevealClipper(_fillInset + fill * reveal),
              child: Stack(
                children: [
                  Positioned(
                    right: _barWidth - fillEnd + _numberPadding,
                    top: 0,
                    bottom: 0,
                    child: Center(child: number),
                  ),
                ],
              ),
            ),
          )
        else
          Positioned(
            left: fillEnd + _numberGap,
            top: 0,
            bottom: 0,
            child: Opacity(
              opacity: reveal,
              child: Center(child: number),
            ),
          ),
      ],
    );
  }
}

class _RevealClipper extends CustomClipper<Rect> {
  const _RevealClipper(this.width);

  final double width;

  @override
  Rect getClip(Size size) => Rect.fromLTWH(0, 0, width, size.height);

  @override
  bool shouldReclip(_RevealClipper oldClipper) => oldClipper.width != width;
}

class _ExitBarPainter extends CustomPainter {
  const _ExitBarPainter({
    required this.colors,
    required this.fill,
    required this.reveal,
    required this.time,
    required this.still,
  });

  final NbColors colors;
  final double fill;
  final double reveal;
  final double time;
  final bool still;

  @override
  void paint(Canvas canvas, Size size) {
    final track = RRect.fromRectAndRadius(
      Offset.zero & size,
      const Radius.circular(_barRadius),
    );
    canvas.drawRRect(track, Paint()..color = colors.surfaceWeak);
    canvas.drawRRect(
      track.deflate(0.5),
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1
        ..color = colors.border,
    );
    if (!(fill > 0) || !(reveal > 0)) return;

    final top = _fillInset;
    final bottom = size.height - _fillInset;
    final fillRect = Rect.fromLTRB(_fillInset, top, _fillInset + fill, bottom);
    final fillShape = RRect.fromRectAndRadius(
      fillRect,
      const Radius.circular(_fillRadius),
    );
    canvas.save();
    canvas.clipRRect(
      RRect.fromRectAndRadius(
        Rect.fromLTRB(_fillInset, top, _fillInset + fill * reveal, bottom),
        const Radius.circular(_fillRadius),
      ),
    );
    final solidFrom = math.max(0.0, (fill - _solidTail) / fill);
    canvas.drawRRect(
      fillShape,
      Paint()
        ..shader = LinearGradient(
          colors: [colors.hubTop, colors.primaryButton, colors.primaryButton],
          stops: [0, solidFrom, 1],
        ).createShader(fillRect),
    );
    paintInnerEdge(
      canvas,
      fillShape,
      dy: 1,
      color: colors.onPrimary.withValues(alpha: _innerEdgeAlpha),
    );
    if (!still) _paintSheen(canvas, fillRect);
    canvas.restore();
  }

  void _paintSheen(Canvas canvas, Rect fillRect) {
    final sheenEnd = fillRect.left + fill - _solidTail;
    if (!(sheenEnd > fillRect.left)) return;
    final cycle = time - _sheenDelay;
    if (cycle < 0) return;
    final phase = (cycle % _sheenPeriod) / _sheenPeriod;
    final travel = (phase / _sheenTravel).clamp(0.0, 1.0);
    final width = fill * _sheenWidth;
    final left =
        fillRect.left + width * (_sheenFrom + (_sheenTo - _sheenFrom) * travel);
    final strip = Rect.fromLTWH(left, fillRect.top, width, fillRect.height);
    final clear = colors.onPrimary.withValues(alpha: 0);
    canvas.save();
    canvas.clipRRect(
      RRect.fromLTRBAndCorners(
        fillRect.left,
        fillRect.top,
        sheenEnd,
        fillRect.bottom,
        topLeft: const Radius.circular(_fillRadius),
        bottomLeft: const Radius.circular(_fillRadius),
      ),
    );
    canvas.drawRect(
      strip,
      Paint()
        ..shader = LinearGradient(
          colors: [
            clear,
            colors.onPrimary.withValues(alpha: _sheenAlpha),
            clear,
          ],
        ).createShader(strip),
    );
    canvas.restore();
  }

  @override
  bool shouldRepaint(_ExitBarPainter oldDelegate) =>
      oldDelegate.fill != fill ||
      oldDelegate.reveal != reveal ||
      oldDelegate.time != time ||
      oldDelegate.still != still ||
      !identical(oldDelegate.colors, colors);
}

Future<AppExitResponse> handleExitRequest(
  AppController controller, {
  required BuildContext? Function() context,
  Duration shutdownBudget = const Duration(seconds: 5),
}) async {
  if (controller.state?.pickerOpen == true) {
    final closed = Completer<void>();
    void onChange() {
      if (controller.state?.pickerOpen != true && !closed.isCompleted) {
        closed.complete();
      }
    }

    controller.addListener(onChange);
    try {
      await closed.future;
    } finally {
      controller.removeListener(onChange);
    }
  }
  if (controller.state?.transferInProgress == true) {
    final ctx = context();
    if (ctx != null && ctx.mounted) {
      final confirmed = await confirmCloseDuringTransfer(ctx, controller);
      if (!confirmed) return AppExitResponse.cancel;
    }
  }
  try {
    await controller.shutdown().timeout(shutdownBudget);
  } catch (_) {}
  return AppExitResponse.exit;
}
