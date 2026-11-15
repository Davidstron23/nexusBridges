import 'package:flutter/widgets.dart';

import '../modal/timeline.dart' show labEaseOut;

const Duration paneInMotion = Duration(milliseconds: 700);
const Duration paneOutMotion = Duration(milliseconds: 600);
const double _inShift = 0.36;
const double _outShift = 0.30;

class PaneLeaving extends InheritedWidget {
  const PaneLeaving({required super.child, super.key});

  static bool of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<PaneLeaving>() != null;

  @override
  bool updateShouldNotify(PaneLeaving oldWidget) => false;
}

class PaneSwitcher extends StatefulWidget {
  const PaneSwitcher({
    required this.paneKey,
    required this.forward,
    required this.child,
    this.fill = false,
    super.key,
  });

  final Object paneKey;
  final bool forward;
  final Widget child;
  final bool fill;

  @override
  State<PaneSwitcher> createState() => _PaneSwitcherState();
}

class _PaneSwitcherState extends State<PaneSwitcher>
    with SingleTickerProviderStateMixin {
  late final AnimationController _motion = AnimationController(
    vsync: this,
    duration: paneInMotion,
    value: 1,
  )..addStatusListener(_onStatus);
  Widget? _previous;
  Object? _previousKey;
  bool _forward = true;

  @override
  void didUpdateWidget(PaneSwitcher oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.paneKey == widget.paneKey) return;
    _forward = widget.forward;
    if (MediaQuery.disableAnimationsOf(context)) {
      _previous = null;
      _previousKey = null;
      _motion.value = 1;
      return;
    }
    _previous = oldWidget.child;
    _previousKey = oldWidget.paneKey;
    _motion.forward(from: 0);
  }

  void _onStatus(AnimationStatus status) {
    if (status != AnimationStatus.completed || _previous == null) return;
    setState(() {
      _previous = null;
      _previousKey = null;
    });
  }

  @override
  void dispose() {
    _motion.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _motion,
      builder: (context, _) {
        final t = _motion.value;
        final enter = labEaseOut.transform(t);
        final ratio =
            paneInMotion.inMicroseconds / paneOutMotion.inMicroseconds;
        final leave = labEaseOut.transform((t * ratio).clamp(0.0, 1.0));
        final direction = _forward ? 1.0 : -1.0;
        final previous = _previous;
        final current = KeyedSubtree(
          key: ValueKey<Object>(('in', widget.paneKey)),
          child: Opacity(
            opacity: previous == null ? 1 : enter,
            child: FractionalTranslation(
              translation: Offset(
                previous == null ? 0 : direction * _inShift * (1 - enter),
                0,
              ),
              child: widget.child,
            ),
          ),
        );
        Widget? outgoing;
        if (previous != null) {
          final faded = IgnorePointer(
            child: ExcludeFocus(
              child: PaneLeaving(
                child: Opacity(
                  opacity: 1 - leave,
                  child: FractionalTranslation(
                    translation: Offset(-direction * _outShift * leave, 0),
                    child: previous,
                  ),
                ),
              ),
            ),
          );
          outgoing = KeyedSubtree(
            key: ValueKey<Object>(('out', _previousKey!)),
            child: widget.fill
                ? Positioned.fill(child: faded)
                : Positioned(left: 0, right: 0, top: 0, child: faded),
          );
        }
        return Stack(
          clipBehavior: Clip.hardEdge,
          fit: widget.fill ? StackFit.expand : StackFit.loose,
          children: [?outgoing, current],
        );
      },
    );
  }
}
