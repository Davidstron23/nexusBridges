import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

bool _sameColor(Color a, Color b) =>
    (a.r - b.r).abs() < 1e-3 &&
    (a.g - b.g).abs() < 1e-3 &&
    (a.b - b.b).abs() < 1e-3 &&
    (a.a - b.a).abs() < 1e-3;

Finder _scrollbarPaintOf(Finder zone) {
  final scrollbar = find
      .ancestor(of: zone, matching: find.byType(RawScrollbar))
      .first;
  return find
      .descendant(
        of: scrollbar,
        matching: find.byWidgetPredicate(
          (widget) =>
              widget is CustomPaint &&
              widget.foregroundPainter is ScrollbarPainter,
        ),
      )
      .first;
}

List<Rect> thumbsOf(WidgetTester tester, Finder zone, Color color) {
  final paint = _scrollbarPaintOf(zone);
  final painter = tester.widget<CustomPaint>(paint).foregroundPainter!;
  final box = tester.renderObject<RenderBox>(paint);
  final canvas = TestRecordingCanvas();
  painter.paint(canvas, box.size);
  final origin = box.localToGlobal(Offset.zero);
  final thumbs = <Rect>[];
  for (final call in canvas.invocations) {
    final invocation = call.invocation;
    final name = invocation.memberName;
    if (name != #drawRRect && name != #drawRect) continue;
    final args = invocation.positionalArguments;
    if (!_sameColor((args[1] as Paint).color, color)) continue;
    final rect = args[0] is RRect
        ? (args[0] as RRect).outerRect
        : args[0] as Rect;
    thumbs.add(rect.shift(origin));
  }
  return thumbs;
}

const Duration barFadeIn = Duration(milliseconds: 400);

ScrollPosition zonePosition(WidgetTester tester, Finder zone) => tester
    .state<ScrollableState>(
      find.descendant(of: zone, matching: find.byType(Scrollable)).first,
    )
    .position;

void expectWholeInside(Rect inner, Rect outer, String reason) {
  expect(inner.left, greaterThanOrEqualTo(outer.left - 0.5), reason: reason);
  expect(inner.right, lessThanOrEqualTo(outer.right + 0.5), reason: reason);
  expect(inner.top, greaterThanOrEqualTo(outer.top - 0.5), reason: reason);
  expect(inner.bottom, lessThanOrEqualTo(outer.bottom + 0.5), reason: reason);
}

bool isWholeInside(Rect inner, Rect outer) =>
    inner.left >= outer.left - 0.5 &&
    inner.right <= outer.right + 0.5 &&
    inner.top >= outer.top - 0.5 &&
    inner.bottom <= outer.bottom + 0.5;
