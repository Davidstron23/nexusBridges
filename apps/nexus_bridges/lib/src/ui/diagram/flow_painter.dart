import 'dart:ui';

Path dashPath(Path source, List<double> pattern, {double phase = 0}) {
  final valid =
      pattern.isNotEmpty &&
      phase.isFinite &&
      pattern.every((length) => length.isFinite && length > 0);
  if (!valid) return Path()..addPath(source, Offset.zero);

  final cycle = pattern.length.isOdd ? [...pattern, ...pattern] : pattern;
  final total = cycle.fold<double>(0, (sum, length) => sum + length);
  var offset = phase % total;
  if (offset < 0) offset += total;
  var startIndex = 0;
  while (offset >= cycle[startIndex]) {
    offset -= cycle[startIndex];
    startIndex = (startIndex + 1) % cycle.length;
  }

  final result = Path();
  for (final metric in source.computeMetrics()) {
    var index = startIndex;
    var remaining = cycle[index] - offset;
    var distance = 0.0;
    while (distance < metric.length) {
      final end = distance + remaining < metric.length
          ? distance + remaining
          : metric.length;
      if (index.isEven) {
        result.addPath(metric.extractPath(distance, end), Offset.zero);
      }
      remaining -= end - distance;
      distance = end;
      if (remaining <= 0) {
        index = (index + 1) % cycle.length;
        remaining = cycle[index];
      }
    }
  }
  return result;
}
