import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nexus_bridges/src/l10n/app_strings.dart';
import 'package:nexus_bridges/src/ui/theme/components.dart';
import 'package:nexus_bridges_core/nexus_bridges_core.dart';

import 'fake_app_controller.dart';
import 'pairing_fixtures.dart';
import 'segoe_font.dart';

const Size _column280 = Size(800, 600);
const String _longName =
    'Portatil del salon con un nombre tan largo que no cabe en la columna';

final String _fp = fingerprintOf('AAAA1111');

final Map<String, DeviceEntry Function(String name)> _rows = {
  'mine': (name) =>
      entry(fingerprint: _fp, name: name, paired: true, mine: true),
  'foreign': (name) => entry(fingerprint: _fp, name: name, paired: true),
  'not visible': (name) =>
      entry(fingerprint: _fp, name: name, paired: true, visible: false),
  'not paired': (name) => entry(fingerprint: _fp, name: name),
  'ignored': (name) => entry(fingerprint: _fp, name: name, ignored: true),
};

Future<void> _pump(
  WidgetTester tester,
  String code,
  DeviceEntry row, {
  Size size = const Size(800, 3000),
  double textScale = 1,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  if (textScale != 1) {
    tester.platformDispatcher.textScaleFactorTestValue = textScale;
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
  }
  await pumpHome(
    tester,
    FakeAppController(state: NodeState(entries: [row])),
    code,
  );
}

Finder _inRow(Finder matching) =>
    find.descendant(of: find.byKey(ValueKey(_fp)), matching: matching);

Finder get _chip => _inRow(find.byType(StatusChip));

Finder get _dot => _inRow(
  find.byWidgetPredicate(
    (widget) =>
        widget is Container &&
        widget.decoration is BoxDecoration &&
        (widget.decoration! as BoxDecoration).shape == BoxShape.circle,
  ),
);

RenderParagraph _paragraph(WidgetTester tester, String text) =>
    tester.renderObject<RenderParagraph>(
      find.descendant(
        of: _inRow(find.text(text)),
        matching: find.byType(RichText),
      ),
    );

String _chipLabel(WidgetTester tester) =>
    tester.widget<StatusChip>(_chip).label;

void main() {
  setUpAll(loadSegoe);

  for (final code in languageCodes) {
    final strings = stringsFor(code);

    group('[$code] the first line is the name with its chip', () {
      for (final MapEntry(key: label, value: build) in _rows.entries) {
        testWidgets('$label: the chip sits 10 px after the name and the '
            'visibility goes under the name', (tester) async {
          final row = build('Torre');
          await _pump(tester, code, row);

          final name = tester.getRect(_inRow(find.text(row.displayName)));
          final chip = tester.getRect(_chip);
          final dot = tester.getRect(_dot);
          final visibility = tester.getRect(
            _inRow(
              find.text(
                row.visible ? strings.visibleLabel : strings.notVisibleLabel,
              ),
            ),
          );

          expect(chip.left - name.right, closeTo(10, 0.01));
          expect(chip.center.dy, closeTo(name.center.dy, 0.51));
          expect(dot.left, closeTo(name.left, 0.01));
          expect(dot.top, greaterThanOrEqualTo(name.bottom));
          expect(dot.top, greaterThanOrEqualTo(chip.bottom));
          expect(dot.center.dy, closeTo(visibility.center.dy, 0.51));
          expect(visibility.left, closeTo(dot.right + 4, 0.01));
        });

        testWidgets('$label: a long name is cut and the chip stays whole', (
          tester,
        ) async {
          final row = build(_longName);
          await _pump(tester, code, row, size: _column280);

          expect(tester.takeException(), isNull);
          final name = find.text(_longName);
          final text = tester.widget<Text>(_inRow(name));
          expect(text.maxLines, 1);
          expect(text.overflow, TextOverflow.ellipsis);
          expect(_paragraph(tester, _longName).didExceedMaxLines, isTrue);
          final chipLabel = _chipLabel(tester);
          expect(_paragraph(tester, chipLabel).didExceedMaxLines, isFalse);
          expect(
            tester.getRect(_chip).left - tester.getRect(_inRow(name)).right,
            closeTo(10, 0.01),
          );
          expect(
            tester.getRect(_chip).right,
            lessThanOrEqualTo(tester.getRect(find.byKey(ValueKey(_fp))).right),
          );
        });

        testWidgets('$label: at 200 % text nothing overflows', (tester) async {
          await _pump(
            tester,
            code,
            build(_longName),
            size: _column280,
            textScale: 2,
          );

          expect(tester.takeException(), isNull);
          final row = tester.getRect(find.byKey(ValueKey(_fp)));
          expect(tester.getRect(_chip).right, lessThanOrEqualTo(row.right));
          expect(tester.getRect(_chip).top, lessThan(tester.getRect(_dot).top));
        });
      }

      testWidgets('at 200 % a short chip keeps showing whole next to a long '
          'name', (tester) async {
        await _pump(
          tester,
          code,
          _rows['mine']!(_longName),
          size: _column280,
          textScale: 2,
        );

        expect(tester.takeException(), isNull);
        expect(_chipLabel(tester), strings.chipMine);
        expect(_paragraph(tester, strings.chipMine).didExceedMaxLines, isFalse);
      });

      testWidgets('the menu stays on the right, away from a short name', (
        tester,
      ) async {
        await _pump(tester, code, _rows['mine']!('PC'), size: _column280);

        final menu = tester.getRect(
          _inRow(find.byTooltip(strings.moreOptions)),
        );
        final row = tester.getRect(find.byKey(ValueKey(_fp)));
        expect(menu.left - tester.getRect(_chip).right, greaterThan(40));
        expect(row.right - menu.right, lessThanOrEqualTo(12));
      });

      testWidgets('with a long name the menu keeps its place after the chip', (
        tester,
      ) async {
        await _pump(
          tester,
          code,
          _rows['foreign']!(_longName),
          size: _column280,
        );

        final menu = tester.getRect(
          _inRow(find.byTooltip(strings.moreOptions)),
        );
        expect(tester.getRect(_chip).right, lessThanOrEqualTo(menu.left));
      });
    });
  }
}
