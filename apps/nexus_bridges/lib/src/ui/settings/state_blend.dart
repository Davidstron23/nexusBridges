import 'package:flutter/material.dart';

class StateBlend extends StatelessWidget {
  const StateBlend({
    required this.on,
    required this.duration,
    required this.curve,
    required this.builder,
    super.key,
  });

  final bool on;
  final Duration duration;
  final Curve curve;
  final Widget Function(BuildContext context, double t) builder;

  @override
  Widget build(BuildContext context) {
    return TweenAnimationBuilder<double>(
      tween: Tween<double>(end: on ? 1 : 0),
      duration: duration,
      curve: curve,
      builder: (context, t, _) => builder(context, t),
    );
  }
}
