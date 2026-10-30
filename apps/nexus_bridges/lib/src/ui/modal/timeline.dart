import 'dart:math' as math;
import 'dart:ui' show Offset, Path;

import 'package:flutter/animation.dart';

const Cubic labEaseOut = Cubic(0.23, 1, 0.32, 1);
const Cubic labEaseInOut = Cubic(0.65, 0, 0.35, 1);
const Cubic labEaseIn = Cubic(0.55, 0, 1, 0.45);
const Cubic labEaseOutSoft = Cubic(0.33, 1, 0.68, 1);
const Cubic labSwing = Cubic(0.77, 0, 0.175, 1);
const Cubic labOrbit = Cubic(0.45, 0.05, 0.55, 0.95);
const Cubic labShake = Cubic(0.36, 0.07, 0.19, 0.97);
const Cubic labFall = Cubic(0.55, 0, 0.75, 0.2);
const Cubic labHourglass = labSwing;

double _progress(double t, double delay, double duration) {
  if (t.isNaN || delay.isNaN) return 0;
  if (!(duration > 0)) return t >= delay ? 1 : 0;
  return ((t - delay) / duration).clamp(0.0, 1.0);
}

double phase(
  double t, {
  required double delay,
  required double duration,
  Curve curve = Curves.linear,
}) {
  final raw = _progress(t, delay, duration);
  if (raw <= 0) return 0;
  if (raw >= 1) return 1;
  return curve.transform(raw);
}

final class Kf {
  const Kf(this.at, this.value, [this.curve]);

  final double at;
  final double value;
  final Curve? curve;
}

double keyframes(
  double t, {
  required double delay,
  required double duration,
  required List<Kf> frames,
  Curve curve = Curves.linear,
}) {
  if (frames.isEmpty) return 0;
  final raw = _progress(t, delay, duration);
  if (raw <= frames.first.at) return frames.first.value;
  for (var i = 0; i < frames.length - 1; i++) {
    final from = frames[i];
    final to = frames[i + 1];
    if (raw >= to.at) continue;
    final span = to.at - from.at;
    if (!(span > 0)) continue;
    final local = ((raw - from.at) / span).clamp(0.0, 1.0);
    final eased = (from.curve ?? curve).transform(local);
    return from.value + (to.value - from.value) * eased;
  }
  return frames.last.value;
}

double loopPhase(double t, {required double period, double delay = 0}) {
  if (!(period > 0) || !t.isFinite || delay.isNaN || t < delay) return 0;
  final elapsed = t - delay;
  if (!elapsed.isFinite) return 0;
  return (elapsed % period) / period;
}

(double, double) dashWindow(double offset) {
  if (!offset.isFinite) return (0, 0);
  return (math.max(0.0, -offset), (1 - offset).clamp(0.0, 1.0));
}

Path partialPath(Path source, double from, double to) {
  final result = Path();
  if (from.isNaN || to.isNaN) return result;
  final start = from.clamp(0.0, 1.0);
  final end = to.clamp(0.0, 1.0);
  if (!(end > start)) return result;

  final metrics = source.computeMetrics().toList();
  final total = metrics.fold<double>(0, (sum, metric) => sum + metric.length);
  if (!(total > 0)) return result;

  final first = start * total;
  final last = end * total;
  var consumed = 0.0;
  for (final metric in metrics) {
    final lo = math.max(first, consumed) - consumed;
    final hi = math.min(last, consumed + metric.length) - consumed;
    if (hi > lo) result.addPath(metric.extractPath(lo, hi), Offset.zero);
    consumed += metric.length;
  }
  return result;
}
