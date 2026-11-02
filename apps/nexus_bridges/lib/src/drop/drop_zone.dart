import 'package:flutter/material.dart';

import '../l10n/app_strings.dart';
import '../ui/diagram/flow_painter.dart' show dashPath;
import '../ui/icons/glyphs.dart';
import '../ui/modal/timeline.dart';
import '../ui/theme/app_theme.dart';
import '../ui/theme/tokens.dart';
import 'drop_controller.dart';

const Duration dropFadeDuration = Duration(milliseconds: 450);
const Duration _hotDuration = Duration(milliseconds: 380);
const double _dimmedOpacity = 0.32;
const double _ringInset = 5;
const double _ringRadius = 10;
const double _ringWidth = 1.5;
const double _ringOpacity = 0.55;
const double _pillHeight = 32;
const double _pillShift = 10;
const double _tipMaxWidth = 290;
const double _tipNarrow = 600;
const double _tipShift = 8;

class DropScope extends InheritedNotifier<DropController> {
  const DropScope({
    required DropController controller,
    required super.child,
    super.key,
  }) : super(notifier: controller);

  static DropController? maybeOf(BuildContext context, {bool listen = true}) {
    if (listen) {
      return context.dependOnInheritedWidgetOfExactType<DropScope>()?.notifier;
    }
    return context.getInheritedWidgetOfExactType<DropScope>()?.notifier;
  }
}

class DropZone extends StatefulWidget {
  const DropZone({
    required this.fingerprint,
    required this.lit,
    required this.child,
    this.decorate = true,
    super.key,
  });

  final String fingerprint;
  final bool lit;
  final bool decorate;
  final Widget child;

  @override
  State<DropZone> createState() => _DropZoneState();
}

class _DropZoneState extends State<DropZone> {
  final GlobalKey _key = GlobalKey();
  DropController? _controller;
  String? _registered;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final controller = DropScope.maybeOf(context);
    if (!identical(controller, _controller)) {
      _controller?.unregister(_key);
      _registered = null;
      _controller = controller;
    }
    _register();
  }

  @override
  void didUpdateWidget(DropZone oldWidget) {
    super.didUpdateWidget(oldWidget);
    _register();
  }

  void _register() {
    if (_registered == widget.fingerprint) return;
    _controller?.register(widget.fingerprint, _key);
    _registered = widget.fingerprint;
  }

  @override
  void dispose() {
    _controller?.unregister(_key);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final controller = _controller;
    var content = widget.child;
    if (widget.decorate && controller != null) {
      final dragging = controller.dragging;
      final lit = dragging && widget.lit;
      final hot = lit && controller.hovered == widget.fingerprint;
      final animate = !MediaQuery.disableAnimationsOf(context);
      final duration = animate ? dropFadeDuration : Duration.zero;
      content = Stack(
        fit: StackFit.passthrough,
        children: [
          AnimatedOpacity(
            opacity: dragging && !widget.lit ? _dimmedOpacity : 1,
            duration: duration,
            curve: labEaseOut,
            child: content,
          ),
          Positioned.fill(
            child: IgnorePointer(
              child: _DropRing(lit: lit, hot: hot, animate: animate),
            ),
          ),
        ],
      );
    }
    return MetaData(
      key: _key,
      behavior: HitTestBehavior.translucent,
      metaData: widget.fingerprint,
      child: content,
    );
  }
}

class _DropRing extends StatelessWidget {
  const _DropRing({
    required this.lit,
    required this.hot,
    required this.animate,
  });

  final bool lit;
  final bool hot;
  final bool animate;

  @override
  Widget build(BuildContext context) {
    final colors = NbColors.of(context);
    return TweenAnimationBuilder<double>(
      tween: Tween<double>(end: hot ? 1 : 0),
      duration: animate ? _hotDuration : Duration.zero,
      curve: labEaseOut,
      builder: (context, hotness, _) => AnimatedOpacity(
        opacity: lit ? 1 : 0,
        duration: animate ? dropFadeDuration : Duration.zero,
        curve: labEaseOut,
        child: CustomPaint(
          painter: _RingPainter(
            hotness: hotness,
            line: colors.primary,
            fill: colors.primaryWeak,
          ),
        ),
      ),
    );
  }
}

class _RingPainter extends CustomPainter {
  const _RingPainter({
    required this.hotness,
    required this.line,
    required this.fill,
  });

  final double hotness;
  final Color line;
  final Color fill;

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    final box = RRect.fromRectAndRadius(
      rect.deflate(_ringInset),
      const Radius.circular(_ringRadius),
    );
    if (hotness > 0) {
      canvas.drawRRect(
        box,
        Paint()..color = fill.withValues(alpha: fill.a * hotness),
      );
    }
    final alpha = _ringOpacity + (1 - _ringOpacity) * hotness;
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = _ringWidth
      ..color = line.withValues(alpha: line.a * alpha);
    final outline = Path()..addRRect(box);
    if (hotness >= 1) {
      canvas.drawPath(outline, paint);
    } else {
      canvas.drawPath(dashPath(outline, const [4, 4]), paint);
      if (hotness > 0) {
        canvas.drawPath(
          outline,
          paint..color = line.withValues(alpha: line.a * alpha * hotness),
        );
      }
    }
  }

  @override
  bool shouldRepaint(_RingPainter oldDelegate) =>
      oldDelegate.hotness != hotness ||
      oldDelegate.line != line ||
      oldDelegate.fill != fill;
}

class DragPill extends StatefulWidget {
  const DragPill({required this.visible, super.key});

  final bool visible;

  @override
  State<DragPill> createState() => _DragPillState();
}

class _DragPillState extends State<DragPill>
    with SingleTickerProviderStateMixin {
  late final AnimationController _motion = AnimationController(
    vsync: this,
    duration: dropFadeDuration,
  )..addStatusListener(_onStatus);
  late final CurvedAnimation _eased = CurvedAnimation(
    parent: _motion,
    curve: labEaseOut,
  );
  late final Animation<Offset> _slide = Tween<Offset>(
    begin: const Offset(0, -_pillShift / _pillHeight),
    end: Offset.zero,
  ).animate(_eased);
  bool _reduceMotion = false;

  @override
  void initState() {
    super.initState();
    if (widget.visible) _motion.forward();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _reduceMotion = MediaQuery.disableAnimationsOf(context);
    if (_reduceMotion) _motion.value = widget.visible ? 1 : 0;
  }

  @override
  void didUpdateWidget(DragPill oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.visible == oldWidget.visible) return;
    if (_reduceMotion) {
      _motion.value = widget.visible ? 1 : 0;
    } else if (widget.visible) {
      _motion.forward();
    } else {
      _motion.reverse();
    }
  }

  void _onStatus(AnimationStatus status) {
    if (status == AnimationStatus.dismissed && mounted) setState(() {});
  }

  @override
  void dispose() {
    _eased.dispose();
    _motion.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.visible && _motion.isDismissed) return const SizedBox.shrink();
    final strings = AppStringsDelegate.of(context);
    final colors = NbColors.of(context);
    return IgnorePointer(
      child: SlideTransition(
        position: _slide,
        child: FadeTransition(
          opacity: _eased,
          child: Semantics(
            liveRegion: true,
            label: strings.dragHint,
            excludeSemantics: true,
            child: Container(
              height: _pillHeight,
              padding: const EdgeInsets.symmetric(horizontal: 14),
              decoration: BoxDecoration(
                color: colors.primaryButton,
                borderRadius: BorderRadius.circular(_pillHeight / 2),
                boxShadow: colors.primaryButtonShadow,
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  GlyphIcon(Glyphs.hand, size: 15, color: colors.onPrimary),
                  const SizedBox(width: 8),
                  Flexible(
                    child: Text(
                      strings.dragHint,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: NbText.button.copyWith(color: colors.onPrimary),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class DragTip extends StatelessWidget {
  const DragTip({required this.hidden, required this.width, super.key});

  final bool hidden;
  final double width;

  @override
  Widget build(BuildContext context) {
    final strings = AppStringsDelegate.of(context);
    final colors = NbColors.of(context);
    final animate = !MediaQuery.disableAnimationsOf(context);
    final narrow = width < _tipNarrow;
    return IgnorePointer(
      child: TweenAnimationBuilder<double>(
        tween: Tween<double>(end: hidden ? 0 : 1),
        duration: animate ? dropFadeDuration : Duration.zero,
        curve: labEaseOut,
        builder: (context, shown, child) => Opacity(
          opacity: shown,
          child: Transform.translate(
            offset: Offset(0, (1 - shown) * _tipShift),
            child: child,
          ),
        ),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: _tipMaxWidth),
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: colors.card,
              borderRadius: BorderRadius.circular(10),
            ),
            position: DecorationPosition.background,
            child: CustomPaint(
              foregroundPainter: _TipRimPainter(colors.borderWeak),
              child: Padding(
                padding: narrow
                    ? const EdgeInsets.all(8)
                    : const EdgeInsets.fromLTRB(10, 8, 12, 8),
                child: Semantics(
                  label: '${strings.dragTipTitle}. ${strings.dragTipBody}',
                  excludeSemantics: true,
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      GlyphIcon(
                        Glyphs.drop,
                        size: 20,
                        color: colors.primaryInk,
                      ),
                      if (!narrow) ...[
                        const SizedBox(width: 10),
                        Flexible(
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                strings.dragTipTitle,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: NbText.bodyStrong.copyWith(
                                  fontSize: 13,
                                  color: colors.text,
                                ),
                              ),
                              Text(
                                strings.dragTipBody,
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                                style: NbText.caption.copyWith(
                                  color: colors.textWeak,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _TipRimPainter extends CustomPainter {
  const _TipRimPainter(this.color);

  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        (Offset.zero & size).deflate(0.5),
        const Radius.circular(10),
      ),
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1
        ..color = color,
    );
  }

  @override
  bool shouldRepaint(_TipRimPainter oldDelegate) => oldDelegate.color != color;
}
