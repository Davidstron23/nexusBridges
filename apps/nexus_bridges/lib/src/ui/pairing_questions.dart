import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:nexus_bridges_core/nexus_bridges_core.dart';

import '../app_controller.dart';
import '../l10n/app_strings.dart';
import 'armed.dart';
import 'icons/device_disc.dart';
import 'icons/glyphs.dart';
import 'modal/modal_button.dart';
import 'modal/modal_frame.dart';
import 'modal/stage.dart';
import 'modal/stage_kit.dart';
import 'modal/timeline.dart';
import 'theme/app_theme.dart';
import 'theme/components.dart';
import 'theme/tokens.dart';

const int _shortFingerprintLength = 8;
const Duration _farewellDuration = Duration(milliseconds: 1750);
const double _rowRadius = 16;
const double _arrowSize = 30;
const double _arrowOverlap = 7;
const double _arrowRingWidth = 5;
const double _arrowPulse = 9;
const double _arrowLoop = 1.8;
const double _arrowLoopDelay = 1;
const double _arrowDrop = 3;
const double _oldDelay = 0.1;
const double _oldDuration = 0.4;
const double _oldFromScale = 0.9;
const double _dimDelay = 0.7;
const double _dimDuration = 0.5;
const double _dimTo = 0.55;
const double _arrowDelay = 0.4;
const double _newDelay = 0.55;
const double _newDuration = 0.5;
const double _newDrop = 10;
const double _columnTop = 28;

String _shortFingerprint(String fingerprint) {
  return fingerprint.length > _shortFingerprintLength
      ? fingerprint.substring(0, _shortFingerprintLength)
      : fingerprint;
}

class PairingQuestionView extends StatefulWidget {
  const PairingQuestionView({
    required this.controller,
    required this.question,
    required this.onAnswer,
    required this.onFarewellDone,
    super.key,
  });

  final AppController controller;
  final PairingQuestion question;
  final void Function(bool value, {bool farewell}) onAnswer;
  final VoidCallback onFarewellDone;

  @override
  State<PairingQuestionView> createState() => _PairingQuestionViewState();
}

class _PairingQuestionViewState extends State<PairingQuestionView>
    with ArmingState<PairingQuestionView> {
  final ValueNotifier<Own?> _hovered = ValueNotifier<Own?>(null);
  Own? _picked;
  Timer? _farewell;

  @override
  void dispose() {
    _farewell?.cancel();
    _hovered.dispose();
    super.dispose();
  }

  DeviceEntry? _entryOf(String fingerprint) {
    for (final entry in widget.controller.state?.entries ?? const []) {
      if (entry.fingerprint == fingerprint) return entry;
    }
    return null;
  }

  VoidCallback? _answer(bool value) =>
      armed ? () => widget.onAnswer(value) : null;

  VoidCallback? _choose(Own own) =>
      armed && _picked == null ? () => _pick(own) : null;

  void _hover(Own own, bool hovering) {
    if (!armed || _picked != null) return;
    if (hovering) {
      _hovered.value = own;
    } else if (_hovered.value == own) {
      _hovered.value = null;
    }
  }

  void _pick(Own own) {
    if (_picked != null || !armed) return;
    final reduceMotion = MediaQuery.disableAnimationsOf(context);
    setState(() => _picked = own);
    widget.onAnswer(own == Own.mine, farewell: true);
    if (reduceMotion) {
      widget.onFarewellDone();
    } else {
      _farewell = Timer(_farewellDuration, () {
        if (mounted) widget.onFarewellDone();
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: widget.controller,
      builder: (context, _) {
        final strings = AppStringsDelegate.of(context);
        return switch (widget.question) {
          final ReplaceQuestion question => _replaceView(strings, question),
          final MineQuestion question => _mineView(strings, question),
        };
      },
    );
  }

  Widget _replaceView(AppStrings strings, ReplaceQuestion question) {
    final oldEntry = _entryOf(question.oldFingerprint);
    final newEntry = _entryOf(question.fingerprint);
    return ModalView(
      layout: ModalViewLayout.titleFirst,
      title: strings.replaceTitle(question.oldName),
      body: [
        ModalLead(
          text: strings.replaceShortBody(question.deviceName),
          tight: true,
        ),
      ],
      stage: _ReplaceColumn(
        previous: _RowData(
          name: question.oldName,
          fingerprint: question.oldFingerprint,
          type: oldEntry?.deviceType,
          mine: oldEntry?.mine ?? false,
          visible: oldEntry?.visible ?? false,
        ),
        next: _RowData(
          name: question.deviceName,
          fingerprint: question.fingerprint,
          type: newEntry?.deviceType,
          mine: newEntry?.mine ?? false,
          visible: newEntry?.visible ?? true,
        ),
      ),
      pair: [
        ModalButton(
          label: strings.keepBothButton,
          kind: ModalButtonKind.secondary,
          inPair: true,
          onPressed: _answer(false),
        ),
        ModalButton(
          label: strings.replaceButton,
          kind: ModalButtonKind.primary,
          glyph: Glyphs.swap,
          inPair: true,
          onPressed: _answer(true),
        ),
      ],
    );
  }

  Widget _mineView(AppStrings strings, MineQuestion question) {
    final peer = deviceGlyphOf(_entryOf(question.fingerprint)?.deviceType);
    final picked = _picked;
    return ModalView(
      title: strings.mineTitle(question.deviceName),
      stage: ValueListenableBuilder<Own?>(
        valueListenable: _hovered,
        builder: (context, hovered, _) => ModalStage(
          scene: StageScene.mine,
          input: StageInput(peer: peer, hovered: hovered, picked: picked),
        ),
      ),
      body: [ModalLead(text: strings.mineQuestion)],
      pair: [
        ChoiceTile(
          title: strings.mineYesButton,
          detail: strings.mineYesDetail,
          glyph: Glyphs.mine,
          neutral: false,
          selected: picked == Own.mine,
          dimmed: picked == Own.other,
          onPressed: _choose(Own.mine),
          onHover: (hovering) => _hover(Own.mine, hovering),
        ),
        ChoiceTile(
          title: strings.mineNoButton,
          detail: strings.mineNoDetail,
          glyph: Glyphs.someoneElse,
          neutral: true,
          selected: picked == Own.other,
          dimmed: picked == Own.mine,
          onPressed: _choose(Own.other),
          onHover: (hovering) => _hover(Own.other, hovering),
        ),
      ],
    );
  }
}

final class _RowData {
  const _RowData({
    required this.name,
    required this.fingerprint,
    required this.type,
    required this.mine,
    required this.visible,
  });

  final String name;
  final String fingerprint;
  final DeviceType? type;
  final bool mine;
  final bool visible;
}

class _ReplaceColumn extends StatefulWidget {
  const _ReplaceColumn({required this.previous, required this.next});

  final _RowData previous;
  final _RowData next;

  @override
  State<_ReplaceColumn> createState() => _ReplaceColumnState();
}

class _ReplaceColumnState extends State<_ReplaceColumn>
    with SingleTickerProviderStateMixin {
  final ValueNotifier<double> _time = ValueNotifier<double>(0);
  late final Ticker _ticker = createTicker(
    (elapsed) =>
        _time.value = elapsed.inMicroseconds / Duration.microsecondsPerSecond,
  );
  bool _still = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _still = MediaQuery.disableAnimationsOf(context);
    if (_still) {
      if (_ticker.isActive) _ticker.stop();
    } else if (!_ticker.isActive) {
      _ticker.start();
    }
  }

  @override
  void dispose() {
    _ticker.dispose();
    _time.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final previous = widget.previous;
    final next = widget.next;
    return Padding(
      padding: const EdgeInsets.only(top: _columnTop),
      child: SizedBox(
        width: double.infinity,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            ValueListenableBuilder<double>(
              valueListenable: _time,
              child: _DeviceRow(
                data: previous,
                isNew: false,
                disc: ValueListenableBuilder<double>(
                  valueListenable: _time,
                  child: DeviceDisc(
                    type: previous.type,
                    size: 48,
                    tone: DiscTone.notVisible,
                  ),
                  builder: (context, t, child) {
                    final dim = _still
                        ? 1.0
                        : phase(
                            t,
                            delay: _dimDelay,
                            duration: _dimDuration,
                            curve: Curves.ease,
                          );
                    return Opacity(
                      opacity: 1 - (1 - _dimTo) * dim,
                      child: child,
                    );
                  },
                ),
              ),
              builder: (context, t, child) {
                final progress = _still
                    ? 1.0
                    : phase(
                        t,
                        delay: _oldDelay,
                        duration: _oldDuration,
                        curve: labEaseOut,
                      );
                return Opacity(
                  opacity: progress,
                  child: Transform.scale(
                    scale: _oldFromScale + (1 - _oldFromScale) * progress,
                    child: child,
                  ),
                );
              },
            ),
            const SizedBox(height: _arrowSize - 2 * _arrowOverlap),
            Stack(
              clipBehavior: Clip.none,
              children: [
                ValueListenableBuilder<double>(
                  valueListenable: _time,
                  child: _DeviceRow(
                    data: next,
                    isNew: true,
                    disc: DeviceDisc(
                      type: next.type,
                      size: 48,
                      tone: DiscTone.sending,
                    ),
                  ),
                  builder: (context, t, child) {
                    final progress = _still
                        ? 1.0
                        : phase(
                            t,
                            delay: _newDelay,
                            duration: _newDuration,
                            curve: labEaseOut,
                          );
                    return Opacity(
                      opacity: progress,
                      child: Transform.translate(
                        offset: Offset(0, -_newDrop * (1 - progress)),
                        child: child,
                      ),
                    );
                  },
                ),
                Positioned(
                  top: -(_arrowSize - _arrowOverlap),
                  left: 0,
                  right: 0,
                  child: Center(
                    child: ExcludeSemantics(
                      child: ValueListenableBuilder<double>(
                        valueListenable: _time,
                        builder: (context, t, _) =>
                            _ArrowBadge(time: t, still: _still),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _ArrowBadge extends StatelessWidget {
  const _ArrowBadge({required this.time, required this.still});

  final double time;
  final bool still;

  @override
  Widget build(BuildContext context) {
    final colors = NbColors.of(context);
    final pop = still
        ? (scale: 1.0, opacity: 1.0)
        : popAt(time, delay: _arrowDelay);
    final loop = still || time < _arrowLoopDelay
        ? 0.0
        : loopPhase(time, period: _arrowLoop, delay: _arrowLoopDelay);
    final drop = keyframes(
      loop,
      delay: 0,
      duration: 1,
      frames: const [Kf(0, 0), Kf(0.28, _arrowDrop), Kf(0.55, 0), Kf(1, 0)],
      curve: labEaseInOut,
    );
    final pulse = still || time < _arrowLoopDelay
        ? 0.0
        : keyframes(
            loop,
            delay: 0,
            duration: 1,
            frames: const [Kf(0, 0), Kf(0.7, _arrowPulse), Kf(1, _arrowPulse)],
            curve: Curves.easeOut,
          );
    final pulseOpacity = still || time < _arrowLoopDelay
        ? 0.0
        : keyframes(
            loop,
            delay: 0,
            duration: 1,
            frames: const [Kf(0, 0.5), Kf(0.7, 0), Kf(1, 0)],
            curve: Curves.easeOut,
          );
    return Opacity(
      opacity: pop.opacity.clamp(0.0, 1.0),
      child: Transform.scale(
        scale: pop.scale,
        child: CustomPaint(
          size: const Size.square(_arrowSize),
          painter: _ArrowPainter(
            ring: colors.card,
            fill: colors.primary,
            pulse: pulse,
            pulseColor: colors.primary.withValues(alpha: pulseOpacity),
          ),
          child: SizedBox.square(
            dimension: _arrowSize,
            child: Center(
              child: Transform.translate(
                offset: Offset(0, drop),
                child: GlyphIcon(
                  Glyphs.arrowDown,
                  size: 16,
                  color: colors.onPrimary,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _ArrowPainter extends CustomPainter {
  const _ArrowPainter({
    required this.ring,
    required this.fill,
    required this.pulse,
    required this.pulseColor,
  });

  final Color ring;
  final Color fill;
  final double pulse;
  final Color pulseColor;

  @override
  void paint(Canvas canvas, Size size) {
    final center = size.center(Offset.zero);
    final radius = size.width / 2;
    canvas.drawCircle(center, radius + _arrowRingWidth, Paint()..color = ring);
    canvas.drawCircle(center, radius, Paint()..color = fill);
    if (pulse > 0 && pulseColor.a > 0) {
      canvas.drawCircle(
        center,
        radius + pulse / 2,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = pulse
          ..color = pulseColor,
      );
    }
  }

  @override
  bool shouldRepaint(_ArrowPainter oldDelegate) =>
      oldDelegate.ring != ring ||
      oldDelegate.fill != fill ||
      oldDelegate.pulse != pulse ||
      oldDelegate.pulseColor != pulseColor;
}

class _DeviceRow extends StatelessWidget {
  const _DeviceRow({
    required this.data,
    required this.isNew,
    required this.disc,
  });

  final _RowData data;
  final bool isNew;
  final Widget disc;

  @override
  Widget build(BuildContext context) {
    final colors = NbColors.of(context);
    final strings = AppStringsDelegate.of(context);
    final radius = BorderRadius.circular(_rowRadius);
    return Container(
      decoration: BoxDecoration(
        color: colors.surfaceWeak,
        borderRadius: radius,
      ),
      foregroundDecoration: isNew
          ? BoxDecoration(
              borderRadius: radius,
              border: Border.all(color: colors.primary, width: 1.5),
            )
          : null,
      child: DecoratedBox(
        decoration: BoxDecoration(
          borderRadius: radius,
          gradient: isNew
              ? LinearGradient(
                  colors: [
                    colors.primaryWeak,
                    colors.primaryWeak.withValues(alpha: 0),
                  ],
                  stops: const [0, 0.85],
                )
              : null,
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          child: Row(
            children: [
              disc,
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Flexible(
                          child: Text(
                            data.name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: NbText.bodyStrong.copyWith(
                              fontSize: 15,
                              height: 20 / 15,
                              color: colors.text,
                            ),
                          ),
                        ),
                        if (data.mine) ...[
                          const SizedBox(width: 8),
                          StatusChip(
                            label: strings.chipMine,
                            tone: ChipTone.run,
                            height: 20,
                          ),
                        ],
                      ],
                    ),
                    const SizedBox(height: 3),
                    Text(
                      _shortFingerprint(data.fingerprint),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: NbText.caption.copyWith(
                        letterSpacing: 0.72,
                        color: colors.textWeak,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 12),
              _VisibilityPill(visible: data.visible),
            ],
          ),
        ),
      ),
    );
  }
}

class _VisibilityPill extends StatelessWidget {
  const _VisibilityPill({required this.visible});

  final bool visible;

  @override
  Widget build(BuildContext context) {
    final colors = NbColors.of(context);
    final strings = AppStringsDelegate.of(context);
    final fill = visible ? colors.successWeak : colors.dangerWeak;
    final ink = visible ? colors.successInk : colors.danger;
    return Container(
      height: 22,
      padding: const EdgeInsets.symmetric(horizontal: 9),
      decoration: ShapeDecoration(color: fill, shape: const StadiumBorder()),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          DecoratedBox(
            decoration: BoxDecoration(color: ink, shape: BoxShape.circle),
            child: const SizedBox.square(dimension: 6),
          ),
          const SizedBox(width: 6),
          Text(
            visible ? strings.visibleLabel : strings.notVisibleLabel,
            maxLines: 1,
            style: NbText.label.copyWith(height: 1, color: ink),
          ),
        ],
      ),
    );
  }
}
