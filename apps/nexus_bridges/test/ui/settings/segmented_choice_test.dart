import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nexus_bridges/src/ui/settings/segmented_choice.dart';
import 'package:nexus_bridges/src/ui/theme/app_theme.dart';
import 'package:nexus_bridges/src/ui/theme/tokens.dart';

import '../segoe_font.dart';

const double _width = 300;

const Map<String, Brightness> _themes = {
  'light': Brightness.light,
  'dark': Brightness.dark,
};

Widget _app(Brightness brightness, int value) => MaterialApp(
  theme: buildTheme(brightness),
  home: Scaffold(
    body: Center(
      child: SizedBox(
        width: _width,
        child: SegmentedChoice<int>(
          options: const [
            SegmentOption(value: 0, label: 'One'),
            SegmentOption(value: 1, label: 'Two'),
            SegmentOption(value: 2, label: 'Three'),
          ],
          value: value,
          onChanged: (_) {},
        ),
      ),
    ),
  ),
);

Finder _box(Color color) => find.descendant(
  of: find.byType(SegmentedChoice<int>),
  matching: find.byWidgetPredicate(
    (widget) =>
        widget is DecoratedBox &&
        widget.decoration is BoxDecoration &&
        (widget.decoration as BoxDecoration).color == color,
  ),
);

BoxDecoration _decoration(WidgetTester tester, Finder box) =>
    tester.widget<DecoratedBox>(box).decoration as BoxDecoration;

void main() {
  setUpAll(loadSegoe);

  for (final MapEntry(key: theme, value: brightness) in _themes.entries) {
    final colors = brightness == Brightness.dark
        ? NbColors.dark
        : NbColors.light;
    final track = _box(colors.segment);
    final thumb = _box(colors.card);

    group('[$theme] the pill of the segmented choice', () {
      testWidgets('it leaves 4 px on every side and the bar stays 39 px tall', (
        tester,
      ) async {
        await tester.pumpWidget(_app(brightness, 0));

        final outer = tester.getRect(track);
        final pill = tester.getRect(thumb);
        expect(outer.height, 39);
        expect(pill.top - outer.top, 4);
        expect(outer.bottom - pill.bottom, 4);
        expect(pill.left - outer.left, 4);
        expect(pill.width, closeTo((_width - 8) / 3, 0.01));
      });

      testWidgets('its corners are concentric with the bar and its shadow has '
          'no offset', (tester) async {
        await tester.pumpWidget(_app(brightness, 0));

        expect(
          _decoration(tester, track).borderRadius,
          BorderRadius.circular(10),
        );
        final pill = _decoration(tester, thumb);
        expect(pill.borderRadius, BorderRadius.circular(6));
        expect(pill.boxShadow, isNotEmpty);
        for (final shadow in pill.boxShadow!) {
          expect(shadow.offset, Offset.zero);
          expect(shadow.spreadRadius, 0);
        }
      });

      testWidgets('it still reaches the first and the last segment', (
        tester,
      ) async {
        await tester.pumpWidget(_app(brightness, 0));
        await tester.pumpWidget(_app(brightness, 2));
        await tester.pumpAndSettle();

        final outer = tester.getRect(track);
        expect(outer.right - tester.getRect(thumb).right, closeTo(4, 0.01));
        expect(
          tester.getCenter(thumb).dx,
          closeTo(tester.getCenter(find.text('Three')).dx, 0.51),
        );

        await tester.pumpWidget(_app(brightness, 0));
        await tester.pumpAndSettle();
        expect(tester.getRect(thumb).left - outer.left, closeTo(4, 0.01));
        expect(
          tester.getCenter(thumb).dx,
          closeTo(tester.getCenter(find.text('One')).dx, 0.51),
        );
      });

      testWidgets('the label is centred inside the pill', (tester) async {
        await tester.pumpWidget(_app(brightness, 1));

        expect(
          tester.getCenter(thumb).dy,
          closeTo(tester.getCenter(find.text('Two')).dy, 0.51),
        );
        expect(
          tester.getCenter(thumb).dy,
          closeTo(tester.getCenter(track).dy, 0.01),
        );
      });

      testWidgets('at 200 % text it grows without overflowing', (tester) async {
        tester.platformDispatcher.textScaleFactorTestValue = 2;
        addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);

        await tester.pumpWidget(_app(brightness, 0));

        expect(tester.takeException(), isNull);
        final outer = tester.getRect(track);
        final pill = tester.getRect(thumb);
        expect(outer.height, 78);
        expect(pill.top - outer.top, 4);
        expect(outer.bottom - pill.bottom, 4);
      });
    });
  }
}
