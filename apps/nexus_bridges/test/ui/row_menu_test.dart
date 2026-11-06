import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nexus_bridges/src/l10n/app_strings.dart';
import 'package:nexus_bridges/src/ui/device_list.dart';
import 'package:nexus_bridges/src/ui/icons/glyphs.dart';
import 'package:nexus_bridges/src/ui/modal/modal_frame.dart';
import 'package:nexus_bridges/src/ui/row_menu.dart';
import 'package:nexus_bridges/src/ui/soft_button.dart';
import 'package:nexus_bridges/src/ui/theme/tokens.dart';
import 'package:nexus_bridges_core/nexus_bridges_core.dart';

import 'fake_app_controller.dart';
import 'pairing_fixtures.dart';

final String _mineFp = fingerprintOf('A1');
final String _hiddenFp = fingerprintOf('C3');

Future<FakeAppController> _pump(
  WidgetTester tester,
  String code,
  Brightness brightness, {
  bool reduceMotion = false,
}) async {
  tester.view.physicalSize = const Size(1180, 720);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  tester.platformDispatcher.platformBrightnessTestValue = brightness;
  addTearDown(tester.platformDispatcher.clearPlatformBrightnessTestValue);
  final controller = FakeAppController(
    state: NodeState(
      entries: [
        entry(
          fingerprint: _mineFp,
          name: 'PC principal',
          paired: true,
          mine: true,
        ),
        entry(
          fingerprint: _hiddenFp,
          name: 'Tablet',
          paired: true,
          mine: true,
          visible: false,
        ),
      ],
    ),
  );
  await pumpHome(tester, controller, code, reduceMotion: reduceMotion);
  return controller;
}

Finder _row(String fingerprint) => find.byKey(ValueKey(fingerprint));

Finder _inRow(String fingerprint, Finder finder) =>
    find.descendant(of: _row(fingerprint), matching: finder);

Finder _trigger(AppStrings strings) =>
    _inRow(_mineFp, find.byTooltip(strings.moreOptions));

Finder get _panel => find.byKey(const ValueKey('row-menu-panel'));

BoxDecoration _panelDecoration(WidgetTester tester) =>
    tester.widget<Container>(_panel).decoration! as BoxDecoration;

Decoration _paintedDecoration(WidgetTester tester, Finder animated) => tester
    .widget<DecoratedBox>(
      find.descendant(of: animated, matching: find.byType(DecoratedBox)).first,
    )
    .decoration;

Color? _itemFill(WidgetTester tester, String label) {
  final decoration = _paintedDecoration(
    tester,
    find.ancestor(
      of: find.text(label),
      matching: find.byType(AnimatedContainer),
    ),
  );
  return (decoration as BoxDecoration).color;
}

Color? _triggerFill(WidgetTester tester, AppStrings strings) {
  final decoration = _paintedDecoration(
    tester,
    find.descendant(
      of: _trigger(strings),
      matching: find.byType(AnimatedContainer),
    ),
  );
  return (decoration as ShapeDecoration).color;
}

double _opacity(WidgetTester tester) => tester
    .widget<FadeTransition>(
      find.ancestor(of: _panel, matching: find.byType(FadeTransition)).first,
    )
    .opacity
    .value;

double _scale(WidgetTester tester) => tester
    .widget<ScaleTransition>(
      find.ancestor(of: _panel, matching: find.byType(ScaleTransition)).first,
    )
    .scale
    .value;

Color? _rowFill(WidgetTester tester, String fingerprint) => tester
    .widget<ColoredBox>(_inRow(fingerprint, find.byType(ColoredBox)).first)
    .color;

Finder _sendBox(String fingerprint) => find
    .descendant(
      of: _inRow(fingerprint, find.byType(SoftButton)),
      matching: find.byType(DecoratedBox),
    )
    .first;

BoxDecoration _sendDecoration(WidgetTester tester, String fingerprint) =>
    tester.widget<DecoratedBox>(_sendBox(fingerprint)).decoration
        as BoxDecoration;

double _sendScale(WidgetTester tester, String fingerprint) => tester
    .widget<Transform>(
      find
          .descendant(
            of: _inRow(fingerprint, find.byType(SoftButton)),
            matching: find.byType(Transform),
          )
          .first,
    )
    .transform
    .entry(0, 0);

Future<TestGesture> _mouse(WidgetTester tester) async {
  final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
  addTearDown(mouse.removePointer);
  await mouse.addPointer(location: const Offset(1, 719));
  await tester.pump();
  return mouse;
}

void main() {
  for (final code in languageCodes) {
    final strings = stringsFor(code);
    for (final brightness in Brightness.values) {
      final colors = brightness == Brightness.dark
          ? NbColors.dark
          : NbColors.light;
      final tag = '[$code] ${brightness.name}';

      group('$tag row menu (point 247)', () {
        testWidgets('opens over the card on its own elevated surface with '
            'both actions, their glyphs and Unpair in the danger tone', (
          tester,
        ) async {
          await _pump(tester, code, brightness);
          await tester.tap(_trigger(strings));
          await tester.pumpAndSettle();

          final decoration = _panelDecoration(tester);
          expect(decoration.color, colors.menuSurface);
          expect(decoration.color, isNot(colors.card));
          expect(decoration.color, isNot(colors.surfaceWeak));
          expect(decoration.border, Border.all(color: colors.menuBorder));
          expect(decoration.boxShadow, colors.menuShadow);
          expect(decoration.borderRadius, BorderRadius.circular(rowMenuRadius));
          expect(tester.getSize(_panel).width, greaterThanOrEqualTo(200));

          final panelRect = tester.getRect(_panel);
          final triggerRect = tester.getRect(_trigger(strings));
          expect(panelRect.top, greaterThan(triggerRect.bottom));
          expect(panelRect.right, moreOrLessEquals(triggerRect.right));
          expect(panelRect.overlaps(tester.getRect(_row(_mineFp))), isTrue);

          for (final (label, glyph) in [
            (strings.configureEllipsis, Glyphs.sliders),
            (strings.markAsForeign, Glyphs.someoneElse),
            (strings.unpairButton, Glyphs.unlink),
          ]) {
            final item = find.ancestor(
              of: find.text(label),
              matching: find.byType(RowMenuItem),
            );
            expect(item, findsOneWidget);
            expect(
              find.descendant(
                of: item,
                matching: find.byWidgetPredicate(
                  (widget) => widget is GlyphIcon && widget.glyph == glyph,
                ),
              ),
              findsOneWidget,
              reason: label,
            );
            expect(tester.getSize(item).height, rowMenuItemHeight);
          }
          expect(
            tester.widget<Text>(find.text(strings.unpairButton)).style?.color,
            colors.danger,
          );
          expect(
            tester.widget<Text>(find.text(strings.markAsForeign)).style?.color,
            colors.text,
          );
          expect(_rowFill(tester, _mineFp), colors.surfaceWeak);
        });

        testWidgets('a device of someone else offers mark as mine with the '
            'home glyph', (tester) async {
          tester.view.physicalSize = const Size(1180, 720);
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.reset);
          tester.platformDispatcher.platformBrightnessTestValue = brightness;
          addTearDown(
            tester.platformDispatcher.clearPlatformBrightnessTestValue,
          );
          await pumpHome(
            tester,
            FakeAppController(
              state: NodeState(
                entries: [
                  entry(
                    fingerprint: _mineFp,
                    name: 'PC principal',
                    paired: true,
                  ),
                ],
              ),
            ),
            code,
          );
          await tester.tap(_trigger(strings));
          await tester.pumpAndSettle();

          expect(
            find.descendant(
              of: find.ancestor(
                of: find.text(strings.markAsMine),
                matching: find.byType(RowMenuItem),
              ),
              matching: find.byWidgetPredicate(
                (widget) => widget is GlyphIcon && widget.glyph == Glyphs.mine,
              ),
            ),
            findsOneWidget,
          );
        });

        testWidgets('opens with a fade and a scale from 0.96 anchored to the '
            'trigger, and closes with a fade', (tester) async {
          await _pump(tester, code, brightness);
          await tester.tap(_trigger(strings));
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 40));

          final opacity = _opacity(tester);
          final scale = _scale(tester);
          expect(opacity, greaterThan(0));
          expect(opacity, lessThan(1));
          expect(scale, greaterThan(rowMenuStartScale));
          expect(scale, lessThan(1));
          expect(
            tester
                .widget<ScaleTransition>(
                  find
                      .ancestor(
                        of: _panel,
                        matching: find.byType(ScaleTransition),
                      )
                      .first,
                )
                .alignment,
            Alignment.topRight,
          );

          await tester.pump(rowMenuOpenDuration);
          expect(_opacity(tester), 1);
          expect(_scale(tester), 1);

          await tester.sendKeyEvent(LogicalKeyboardKey.escape);
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 60));
          expect(_panel, findsOneWidget);
          expect(_opacity(tester), lessThan(1));
          expect(_opacity(tester), greaterThan(0));
          await tester.pump(rowMenuCloseDuration);
          await tester.pump();
          expect(_panel, findsNothing);
        });

        testWidgets('with reduced motion it fades without scaling', (
          tester,
        ) async {
          await _pump(tester, code, brightness, reduceMotion: true);
          await tester.tap(_trigger(strings));
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 40));

          expect(_scale(tester), 1);
          await tester.pumpAndSettle();
          expect(_opacity(tester), 1);
        });

        testWidgets('each item lights up on hover with its own fade, the '
            'normal one in controlHover and Unpair in dangerWeak', (
          tester,
        ) async {
          await _pump(tester, code, brightness);
          await tester.tap(_trigger(strings));
          await tester.pumpAndSettle();
          final mouse = await _mouse(tester);

          expect(_itemFill(tester, strings.markAsForeign)?.a, 0);
          expect(_itemFill(tester, strings.unpairButton)?.a, 0);

          await mouse.moveTo(
            tester.getCenter(find.text(strings.markAsForeign)),
          );
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 60));
          final halfway = _itemFill(tester, strings.markAsForeign)!;
          expect(halfway.a, greaterThan(0));
          expect(halfway.a, lessThan(colors.controlHover.a));
          await tester.pump(rowMenuHoverFade);
          expect(_itemFill(tester, strings.markAsForeign), colors.controlHover);
          expect(_itemFill(tester, strings.unpairButton)?.a, 0);

          await mouse.moveTo(tester.getCenter(find.text(strings.unpairButton)));
          await tester.pump();
          await tester.pump(rowMenuHoverFade);
          await tester.pump();
          expect(_itemFill(tester, strings.unpairButton), colors.dangerWeak);
          expect(_itemFill(tester, strings.markAsForeign)?.a, 0);
        });

        testWidgets('the trigger gets a round hover and stays lit while the '
            'menu is open', (tester) async {
          await _pump(tester, code, brightness);
          final mouse = await _mouse(tester);
          expect(_triggerFill(tester, strings)?.a, 0);

          await mouse.moveTo(tester.getCenter(_trigger(strings)));
          await tester.pump();
          await tester.pump(rowMenuHoverFade);
          expect(_triggerFill(tester, strings), colors.controlHover);

          await tester.tap(_trigger(strings));
          await tester.pumpAndSettle();
          await mouse.moveTo(
            tester.getCenter(find.text(strings.markAsForeign)),
          );
          await tester.pumpAndSettle();
          expect(_triggerFill(tester, strings), colors.controlHover);

          await tester.sendKeyEvent(LogicalKeyboardKey.escape);
          await tester.pumpAndSettle();
          expect(_triggerFill(tester, strings)?.a, 0);
        });

        testWidgets('the actions still reach the controller and a tap '
            'outside closes without acting', (tester) async {
          final controller = await _pump(tester, code, brightness);

          await tester.tap(_trigger(strings));
          await tester.pumpAndSettle();
          await tester.tapAt(const Offset(5, 715));
          await tester.pumpAndSettle();
          expect(_panel, findsNothing);
          expect(controller.calls, isEmpty);

          await tester.tap(_trigger(strings));
          await tester.pumpAndSettle();
          await tester.tap(find.text(strings.markAsForeign));
          await tester.pumpAndSettle();
          expect(controller.calls, ['setMine $_mineFp false']);
          expect(_panel, findsNothing);

          await tester.tap(_trigger(strings));
          await tester.pumpAndSettle();
          await tester.tap(find.text(strings.unpairButton));
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 600));
          expect(find.byType(NbModal), findsOneWidget);
          expect(_panel, findsNothing);
          expect(controller.calls, ['setMine $_mineFp false']);
        });

        testWidgets('the keyboard opens it on the first item, moves with the '
            'arrows and picks with Enter', (tester) async {
          final controller = await _pump(tester, code, brightness);
          final detector = tester.widget<FocusableActionDetector>(
            find
                .descendant(
                  of: _inRow(_mineFp, find.byType(RowMenu)),
                  matching: find.byType(FocusableActionDetector),
                )
                .first,
          );
          detector.focusNode!.requestFocus();
          await tester.pump();

          await tester.sendKeyEvent(LogicalKeyboardKey.enter);
          await tester.pumpAndSettle();
          expect(_panel, findsOneWidget);
          expect(
            _itemFill(tester, strings.configureEllipsis),
            colors.controlHover,
          );
          expect(_itemFill(tester, strings.markAsForeign)?.a, 0);

          await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
          await tester.pumpAndSettle();
          expect(_itemFill(tester, strings.markAsForeign), colors.controlHover);

          await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
          await tester.pumpAndSettle();
          expect(_itemFill(tester, strings.markAsForeign)?.a, 0);
          expect(_itemFill(tester, strings.unpairButton), colors.dangerWeak);

          await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
          await tester.pumpAndSettle();
          await tester.sendKeyEvent(LogicalKeyboardKey.enter);
          await tester.pumpAndSettle();
          expect(controller.calls, ['setMine $_mineFp false']);
          expect(_panel, findsNothing);
          expect(detector.focusNode!.hasFocus, isTrue);
        });
      });

      group('$tag card hover and Send file (point 247)', () {
        testWidgets('the card fades to surfaceWeak in 250 ms', (tester) async {
          await _pump(tester, code, brightness);
          final mouse = await _mouse(tester);
          final row = tester.getRect(_row(_mineFp));

          await mouse.moveTo(row.centerLeft + const Offset(40, 0));
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 80));
          final halfway = _rowFill(tester, _mineFp)!;
          expect(halfway.a, greaterThan(0));
          expect(halfway.a, lessThan(colors.surfaceWeak.a));
          await tester.pump(rowHoverFade);
          expect(_rowFill(tester, _mineFp), colors.surfaceWeak);
          expect(_sendDecoration(tester, _mineFp).color, colors.primaryWeak);
        });

        testWidgets('hovering Send file lights it up like the modal buttons, '
            'with its own fill, glow and inner highlight, over 300 ms', (
          tester,
        ) async {
          await _pump(tester, code, brightness);
          final mouse = await _mouse(tester);
          final rest = _sendDecoration(tester, _mineFp);
          expect(rest.color, colors.primaryWeak);
          expect(
            rest.boxShadow,
            hasLength(colors.softButtonHoverShadow.length),
          );
          expect(
            rest.boxShadow!.every((shadow) => shadow.color.a == 0),
            isTrue,
          );

          final send = _inRow(_mineFp, find.text(strings.sendFilesOrFolders));
          await mouse.moveTo(tester.getCenter(send));
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 60));
          final halfway = _sendDecoration(tester, _mineFp);
          expect(halfway.color, isNot(colors.primaryWeak));
          expect(halfway.color, isNot(colors.primaryButtonHover));
          expect(
            halfway.boxShadow,
            hasLength(colors.softButtonHoverShadow.length),
          );

          await tester.pump(softButtonDuration);
          final lit = _sendDecoration(tester, _mineFp);
          expect(lit.color, colors.primaryButtonHover);
          expect(lit.boxShadow, colors.softButtonHoverShadow);
          expect(lit.color, isNot(_rowFill(tester, _mineFp)));
          expect(_rowFill(tester, _mineFp), colors.surfaceWeak);
          expect(
            tester.widget<Text>(send).style?.color ??
                DefaultTextStyle.of(tester.element(send)).style.color,
            colors.onPrimary,
          );

          await mouse.down(tester.getCenter(send));
          await tester.pump();
          await tester.pump(softButtonDuration);
          expect(_sendScale(tester, _mineFp), softButtonPressedScale);
          expect(_sendDecoration(tester, _mineFp).color, colors.primaryButton);
          await mouse.moveTo(const Offset(1, 719));
          await mouse.up();
          await tester.pump();
          await tester.pump(softButtonDuration);
          expect(_sendDecoration(tester, _mineFp).color, colors.primaryWeak);
          expect(_sendScale(tester, _mineFp), 1);
        });

        testWidgets('with reduced motion the button changes at once and does '
            'not move', (tester) async {
          await _pump(tester, code, brightness, reduceMotion: true);
          final mouse = await _mouse(tester);
          final send = _inRow(_mineFp, find.text(strings.sendFilesOrFolders));
          await mouse.moveTo(tester.getCenter(send));
          await tester.pump();
          await tester.pump();
          expect(
            _sendDecoration(tester, _mineFp).color,
            colors.primaryButtonHover,
          );
          await mouse.down(tester.getCenter(send));
          await tester.pump();
          await tester.pump();
          expect(_sendScale(tester, _mineFp), 1);
          await mouse.moveTo(const Offset(1, 719));
          await mouse.up();
        });

        testWidgets('a disabled Send file stays flat on hover', (tester) async {
          await _pump(tester, code, brightness);
          final mouse = await _mouse(tester);
          final send = _inRow(_hiddenFp, find.text(strings.sendFilesOrFolders));
          await mouse.moveTo(tester.getCenter(send));
          await tester.pump();
          await tester.pump(softButtonDuration);
          final decoration = _sendDecoration(tester, _hiddenFp);
          expect(decoration.color, colors.surfaceWeak);
          expect(
            decoration.boxShadow!.every((shadow) => shadow.color.a == 0),
            isTrue,
          );
        });
      });
    }
  }
}
