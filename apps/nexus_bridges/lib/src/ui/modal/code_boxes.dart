import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../pairing_dialogs.dart' show formatCode;
import '../theme/app_theme.dart';
import '../theme/tokens.dart';
import 'modal_button.dart' show paintInnerEdge;

const Cubic _labEaseOut = Cubic(0.23, 1, 0.32, 1);
const Cubic _labEaseInOut = Cubic(0.65, 0, 0.35, 1);

const int _codeLength = 6;
const double _boxWidth = 45;
const double _boxHeight = 58;
const double _boxRadius = 13;
const double _gap = 7;
const double _dashWidth = 10;
const double _dashHeight = 2;
const double _topSpace = 16;

const Duration _introTotal = Duration(milliseconds: 660);
const Duration _confirmedTotal = Duration(milliseconds: 2600);

const List<double> _introDelays = [0, 40, 80, 120, 160, 200];
const List<double> _confirmDelays = [300, 420, 540, 720, 840, 960];
const List<double> _sheenDelays = [1500, 1560, 1620, 1700, 1760, 1820];

const double _introDuration = 460;
const double _confirmDuration = 700;
const double _sheenDuration = 700;
const double _dashDelay = 660;
const double _dashDuration = 400;

const double _sheenWidthFraction = 0.6;
const double _sheenFrom = -1.2;
const double _sheenTo = 2.2;
const double _sheenAngle = 100 * math.pi / 180;

double _phase(
  double ms, {
  required double delay,
  required double duration,
  Curve curve = Curves.linear,
}) {
  final raw = ((ms - delay) / duration).clamp(0.0, 1.0);
  if (raw <= 0) return 0;
  if (raw >= 1) return 1;
  return curve.transform(raw);
}

class CodeBoxes extends StatefulWidget {
  const CodeBoxes({required this.code, this.confirmed = false, super.key});

  final String code;
  final bool confirmed;

  @override
  State<CodeBoxes> createState() => _CodeBoxesState();
}

class _CodeBoxesState extends State<CodeBoxes>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  bool _started = false;

  Duration get _total => widget.confirmed ? _confirmedTotal : _introTotal;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(vsync: this, duration: _total);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (MediaQuery.disableAnimationsOf(context)) {
      _controller.value = 1;
    } else if (!_started) {
      _started = true;
      _controller.forward(from: 0);
    }
  }

  @override
  void didUpdateWidget(CodeBoxes oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.confirmed == widget.confirmed) return;
    _controller.duration = _total;
    if (MediaQuery.disableAnimationsOf(context)) {
      _controller.value = 1;
    } else {
      _controller.forward(from: 0);
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final code = widget.code;
    if (code.length != _codeLength) return const SizedBox.shrink();
    final colors = NbColors.of(context);
    final confirmed = widget.confirmed;
    return Center(
      child: FittedBox(
        fit: BoxFit.scaleDown,
        child: Padding(
          padding: const EdgeInsets.only(top: _topSpace),
          child: Semantics(
            label: formatCode(code),
            child: AnimatedBuilder(
              animation: _controller,
              builder: (context, _) {
                final ms = _controller.value * _total.inMilliseconds;
                return Row(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    for (var i = 0; i < _codeLength; i++) ...[
                      if (i == 3) ...[
                        const SizedBox(width: _gap),
                        _Dash(colors: colors, ms: ms, confirmed: confirmed),
                        const SizedBox(width: _gap),
                      ] else if (i > 0)
                        const SizedBox(width: _gap),
                      _Key(
                        digit: code[i],
                        index: i,
                        ms: ms,
                        confirmed: confirmed,
                        colors: colors,
                      ),
                    ],
                  ],
                );
              },
            ),
          ),
        ),
      ),
    );
  }
}

class _Dash extends StatelessWidget {
  const _Dash({
    required this.colors,
    required this.ms,
    required this.confirmed,
  });

  final NbColors colors;
  final double ms;
  final bool confirmed;

  @override
  Widget build(BuildContext context) {
    final progress = confirmed
        ? _phase(
            ms,
            delay: _dashDelay,
            duration: _dashDuration,
            curve: Curves.ease,
          )
        : 0.0;
    return Container(
      width: _dashWidth,
      height: _dashHeight,
      decoration: BoxDecoration(
        color: Color.lerp(colors.hint, colors.success, progress),
        borderRadius: BorderRadius.circular(_dashHeight / 2),
      ),
    );
  }
}

class _Key extends StatelessWidget {
  const _Key({
    required this.digit,
    required this.index,
    required this.ms,
    required this.confirmed,
    required this.colors,
  });

  final String digit;
  final int index;
  final double ms;
  final bool confirmed;
  final NbColors colors;

  @override
  Widget build(BuildContext context) {
    var ok = 0.0;
    var opacity = 1.0;
    var lift = 0.0;
    var scale = 1.0;
    var sheen = 0.0;
    if (confirmed) {
      final local = _phase(
        ms,
        delay: _confirmDelays[index],
        duration: _confirmDuration,
      );
      ok = _labEaseOut.transform(local);
      final bump = local < 0.4
          ? _labEaseOut.transform(local / 0.4)
          : 1 - _labEaseOut.transform((local - 0.4) / 0.6);
      lift = -3 * bump;
      scale = 1 + 0.04 * bump;
      sheen = _phase(
        ms,
        delay: _sheenDelays[index],
        duration: _sheenDuration,
        curve: _labEaseInOut,
      );
    } else {
      final enter = _phase(
        ms,
        delay: _introDelays[index],
        duration: _introDuration,
        curve: _labEaseOut,
      );
      opacity = enter;
      lift = 8 * (1 - enter);
      scale = 0.94 + 0.06 * enter;
    }
    final style = NbText.title.copyWith(
      fontSize: 28,
      height: 1,
      color: Color.lerp(colors.text, colors.successInk, ok),
      fontFeatures: const [FontFeature.tabularFigures()],
    );
    Widget box = CustomPaint(
      size: const Size(_boxWidth, _boxHeight),
      painter: _KeyPainter(colors: colors, ok: ok),
      foregroundPainter: _SheenPainter(colors: colors, progress: sheen),
      child: SizedBox(
        width: _boxWidth,
        height: _boxHeight,
        child: Center(
          child: ExcludeSemantics(child: Text(digit, style: style)),
        ),
      ),
    );
    if (lift != 0 || scale != 1) {
      box = Transform(
        alignment: Alignment.center,
        transform:
            Matrix4.translationValues(0, lift, 0) *
            Matrix4.diagonal3Values(scale, scale, 1),
        child: box,
      );
    }
    if (opacity < 1) box = Opacity(opacity: opacity, child: box);
    return box;
  }
}

class _KeyPainter extends CustomPainter {
  const _KeyPainter({required this.colors, required this.ok});

  final NbColors colors;
  final double ok;

  @override
  void paint(Canvas canvas, Size size) {
    final rrect = RRect.fromRectAndRadius(
      Offset.zero & size,
      const Radius.circular(_boxRadius),
    );
    final shadows =
        BoxShadow.lerpList(colors.keyShadow, colors.okShadow, ok) ?? const [];
    final outside = Path.combine(
      PathOperation.difference,
      Path()
        ..addRect(Rect.fromLTWH(-80, -80, size.width + 160, size.height + 160)),
      Path()..addRRect(rrect),
    );
    canvas.save();
    canvas.clipPath(outside);
    for (final shadow in shadows) {
      canvas.drawRRect(
        rrect.shift(shadow.offset).inflate(shadow.spreadRadius),
        shadow.toPaint(),
      );
    }
    canvas.restore();
    canvas.drawRRect(
      rrect,
      Paint()..color = Color.lerp(colors.keyFill, colors.successWeak, ok)!,
    );
    paintInnerEdge(
      canvas,
      rrect,
      dy: -2,
      color: Color.lerp(
        colors.borderWeak,
        colors.borderWeak.withValues(alpha: 0),
        ok,
      )!,
    );
    canvas.drawDRRect(
      rrect,
      rrect.deflate(1),
      Paint()..color = Color.lerp(colors.border, colors.keyOkBorder, ok)!,
    );
  }

  @override
  bool shouldRepaint(_KeyPainter oldDelegate) {
    return oldDelegate.colors != colors || oldDelegate.ok != ok;
  }
}

class _SheenPainter extends CustomPainter {
  const _SheenPainter({required this.colors, required this.progress});

  final NbColors colors;
  final double progress;

  @override
  void paint(Canvas canvas, Size size) {
    if (progress <= 0 || progress >= 1) return;
    final band = size.width * _sheenWidthFraction;
    final left = band * (_sheenFrom + (_sheenTo - _sheenFrom) * progress);
    final rect = Rect.fromLTWH(left, 0, band, size.height);
    final direction = Offset(math.sin(_sheenAngle), -math.cos(_sheenAngle));
    final length =
        (band * math.sin(_sheenAngle)).abs() +
        (size.height * math.cos(_sheenAngle)).abs();
    final center = rect.center;
    final half = direction * (length / 2);
    final clear = colors.sheen.withValues(alpha: 0);
    final paint = Paint()
      ..shader = ui.Gradient.linear(
        center - half,
        center + half,
        [clear, colors.sheen, clear],
        const [0, 0.5, 1],
      );
    canvas.save();
    canvas.clipRRect(
      RRect.fromRectAndRadius(
        Offset.zero & size,
        const Radius.circular(_boxRadius),
      ),
      doAntiAlias: true,
    );
    canvas.drawRect(rect, paint);
    canvas.restore();
  }

  @override
  bool shouldRepaint(_SheenPainter oldDelegate) {
    return oldDelegate.colors != colors || oldDelegate.progress != progress;
  }
}
