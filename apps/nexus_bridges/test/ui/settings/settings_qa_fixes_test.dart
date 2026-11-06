import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nexus_bridges/src/l10n/app_strings.dart';
import 'package:nexus_bridges/src/ui/icons/device_disc.dart';
import 'package:nexus_bridges/src/ui/settings/settings_field.dart';
import 'package:nexus_bridges/src/ui/settings/system_tray_section.dart';
import 'package:nexus_bridges/src/ui/theme/app_theme.dart';
import 'package:nexus_bridges/src/ui/theme/tokens.dart';

import '../fake_app_controller.dart';
import '../segoe_font.dart';
import '../transfer_fixtures.dart' show incomingView;
import 'settings_fixtures.dart';

const Size _short = Size(1100, 640);
const Size _minimum = Size(760, 520);
const String _office = '{NETWORK-OFFICE-QA}';

Finder _navItem(String title) => find
    .descendant(
      of: settingsScreen,
      matching: find.byWidgetPredicate(
        (widget) =>
            widget is Semantics &&
            widget.properties.label == title &&
            widget.properties.selected != null,
      ),
    )
    .first;

Finder _scrollView() => find
    .descendant(of: settingsScreen, matching: find.byType(Scrollable))
    .first;

Finder _stopButton(String section, AppStrings strings, String id) =>
    find.descendant(
      of: find.byKey(ValueKey('network-$id')),
      matching: find.ancestor(
        of: find.text(strings.stopUsingButton),
        matching: find.byWidgetPredicate(
          (widget) => widget is ButtonStyleButton,
        ),
      ),
    );

Future<void> _tabUntil(
  WidgetTester tester,
  bool Function(FocusNode node) found,
) async {
  for (var step = 0; step < 80; step++) {
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pump();
    final node = FocusManager.instance.primaryFocus;
    if (node != null && found(node)) return;
  }
  fail('the focus never reached the target');
}

void main() {
  setUpAll(loadSegoe);

  for (final code in languageCodes) {
    final strings = stringsFor(code);

    group('[$code] Q-1 Esc with confirmations closed out of order', () {
      testWidgets(
        'Q-1 Esc still closes Settings after two confirmations closed in a '
        'different order',
        (tester) async {
          final (controller, settings) = await pumpSettings(
            tester,
            code,
            state: settingsState(exclusions: const ['dist']),
          );
          await tester.tap(
            inSection(
              strings.sectionExclusions,
              find.text(strings.restoreDefaults),
            ),
          );
          await tester.pumpAndSettle();
          await tester.tap(
            _stopButton(strings.sectionNetworks, strings, homeNetwork),
          );
          await tester.pumpAndSettle();
          expect(confirmOpen(tester, strings.sectionExclusions), isTrue);
          expect(confirmOpen(tester, strings.sectionNetworks), isTrue);

          await tester.tap(
            confirmButton(strings.sectionExclusions, strings.cancelButton),
          );
          await tester.pumpAndSettle();
          expect(confirmOpen(tester, strings.sectionExclusions), isFalse);
          expect(confirmOpen(tester, strings.sectionNetworks), isTrue);

          await pressEscape(tester);
          expect(confirmOpen(tester, strings.sectionNetworks), isFalse);
          expect(settings.isOpen, isTrue);
          expect(confirmScopeOf(tester).value, isNull);

          await pressEscape(tester);
          expect(settings.isOpen, isFalse);
          expect(controller.calls, isEmpty);
        },
      );

      testWidgets(
        'Q-1 Esc cancels the last confirmation opened first, then the '
        'other, then closes Settings',
        (tester) async {
          final (controller, settings) = await pumpSettings(
            tester,
            code,
            state: settingsState(exclusions: const ['dist']),
          );
          await tester.tap(
            inSection(
              strings.sectionExclusions,
              find.text(strings.restoreDefaults),
            ),
          );
          await tester.pumpAndSettle();
          await tester.tap(
            _stopButton(strings.sectionNetworks, strings, homeNetwork),
          );
          await tester.pumpAndSettle();

          await pressEscape(tester);
          expect(confirmOpen(tester, strings.sectionNetworks), isFalse);
          expect(confirmOpen(tester, strings.sectionExclusions), isTrue);
          await pressEscape(tester);
          expect(confirmOpen(tester, strings.sectionExclusions), isFalse);
          expect(settings.isOpen, isTrue);
          await pressEscape(tester);
          expect(settings.isOpen, isFalse);
          expect(controller.calls, isEmpty);
        },
      );
    });

    group('[$code] Q-2 the index reaches the last section the first time', () {
      testWidgets(
        'Q-2 the first jump to the last section arrives and the index keeps '
        'it after a small scroll',
        (tester) async {
          await pumpSettings(tester, code, size: _short);
          final viewportTop = tester.getTopLeft(_scrollView()).dy;

          await tester.tap(_navItem(strings.sectionIgnored));
          await tester.pumpAndSettle();
          expect(navSelected(tester, strings.sectionIgnored), isTrue);
          final top = tester.getTopLeft(sectionOf(strings.sectionIgnored)).dy;
          expect(top - viewportTop, lessThanOrEqualTo(110));

          await tester.drag(_scrollView(), const Offset(0, -1));
          await tester.pumpAndSettle();
          expect(navSelected(tester, strings.sectionIgnored), isTrue);
          expect(navSelected(tester, strings.sectionNetworks), isFalse);
        },
      );
    });

    group('[$code] Q-3 the tray switch with the keyboard', () {
      testWidgets('Q-3 Tab reaches the switch and Space and Enter change it', (
        tester,
      ) async {
        final handle = tester.ensureSemantics();
        final (controller, _) = await pumpSettings(tester, code);
        expect(controller.closeToTray, isTrue);

        await _tabUntil(
          tester,
          (node) =>
              node.context?.findAncestorWidgetOfExactType<SettingsSwitch>() !=
              null,
        );
        expect(
          tester.getSemantics(find.byType(SettingsSwitch)),
          isSemantics(
            label: strings.systemTraySwitch,
            hasToggledState: true,
            isToggled: true,
            isFocusable: true,
            isFocused: true,
            hasEnabledState: true,
            isEnabled: true,
            hasTapAction: true,
          ),
        );

        await tester.sendKeyEvent(LogicalKeyboardKey.space);
        await tester.pumpAndSettle();
        expect(controller.closeToTray, isFalse);

        await tester.sendKeyEvent(LogicalKeyboardKey.enter);
        await tester.pumpAndSettle();
        expect(controller.closeToTray, isTrue);
        expect(controller.calls, [
          'setCloseToTray false',
          'setCloseToTray true',
        ]);
        handle.dispose();
      });

      testWidgets(
        'Q-3 the focused switch draws a ring and the idle one does not',
        (tester) async {
          await pumpSettings(tester, code);
          BoxDecoration track() =>
              tester
                      .widget<Container>(
                        find.descendant(
                          of: find.byType(SettingsSwitch),
                          matching: find.byType(Container),
                        ),
                      )
                      .decoration!
                  as BoxDecoration;
          expect(track().boxShadow ?? const [], isEmpty);

          await _tabUntil(
            tester,
            (node) =>
                node.context?.findAncestorWidgetOfExactType<SettingsSwitch>() !=
                null,
          );
          await tester.pumpAndSettle();
          expect(track().boxShadow, isNotEmpty);
        },
      );
    });

    group('[$code] Q-4 large text in the smallest window', () {
      void scale(WidgetTester tester, double factor) {
        tester.platformDispatcher.textScaleFactorTestValue = factor;
        addTearDown(tester.platformDispatcher.clearAllTestValues);
      }

      testWidgets(
        'Q-4 at 150 % the connected network keeps its name, date and button '
        'inside the card',
        (tester) async {
          scale(tester, 1.5);
          await pumpSettings(
            tester,
            code,
            size: _minimum,
            state: settingsState(
              networks: [
                networkView(name: 'Casa de la playa'),
                networkView(
                  id: _office,
                  name: 'Cafeteria Plaza Mayor',
                  connected: false,
                  trustedAt: officeTrusted,
                ),
              ],
            ),
          );
          await tester.drag(_scrollView(), const Offset(0, -5000));
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull);

          final card = tester.getRect(sectionOf(strings.sectionNetworks));
          final row = find.byKey(const ValueKey('network-$homeNetwork'));
          expect(
            inSection(strings.sectionNetworks, find.text('Casa de la playa')),
            findsOneWidget,
          );
          final button = tester.getRect(
            _stopButton(strings.sectionNetworks, strings, homeNetwork),
          );
          expect(button.left, greaterThanOrEqualTo(card.left));
          expect(button.right, lessThanOrEqualTo(card.right));
          final rowRect = tester.getRect(row);
          expect(rowRect.right, lessThanOrEqualTo(card.right));
          final name = tester.renderObject<RenderParagraph>(
            find.descendant(of: row, matching: find.text('Casa de la playa')),
          );
          expect(name.didExceedMaxLines, isFalse);
        },
      );

      testWidgets('Q-4 a row that fits keeps its action at the right edge', (
        tester,
      ) async {
        final short = 'ab' * 32;
        final long = 'cd' * 32;
        await pumpSettings(
          tester,
          code,
          size: _short,
          state: settingsState(
            ignored: [
              ignoredView(
                fingerprint: short,
                name: 'Movil',
                at: DateTime.utc(2026, 10, 1, 12),
              ),
              ignoredView(
                fingerprint: long,
                name: 'DESKTOP-7Q2M9XK con un nombre larguisimo que no cabe',
                at: DateTime.utc(2026, 9, 1, 12),
              ),
            ],
          ),
        );
        await tester.drag(_scrollView(), const Offset(0, -5000));
        await tester.pumpAndSettle();
        Finder row(String fingerprint) =>
            find.byKey(ValueKey('ignored-$fingerprint'));
        final shortRow = tester.getRect(row(short));
        final button = tester.getRect(
          find.descendant(
            of: row(short),
            matching: find.byWidgetPredicate(
              (widget) => widget is ButtonStyleButton,
            ),
          ),
        );
        expect(shortRow.right - button.right, closeTo(16, 1));
        final shortDisc = tester.getTopLeft(
          find.descendant(of: row(short), matching: find.byType(DeviceDisc)),
        );
        final longDisc = tester.getTopLeft(
          find.descendant(of: row(long), matching: find.byType(DeviceDisc)),
        );
        expect(shortDisc.dx, longDisc.dx);
      });

      testWidgets('Q-4 at 200 % the index does not overflow', (tester) async {
        scale(tester, 2);
        await pumpSettings(tester, code, size: _minimum);
        expect(tester.takeException(), isNull);
        expect(settingsScreen, findsOneWidget);
        expect(navSelected(tester, strings.sectionDevice), isTrue);
      });
    });

    group('[$code] Q-5 the Tab order', () {
      testWidgets('Q-5 Tab goes through the whole index before the content', (
        tester,
      ) async {
        await pumpSettings(tester, code);
        final navRight = tester.getTopRight(_navItem(strings.sectionDevice)).dx;
        final seen = <bool>[];
        for (var step = 0; step < 40; step++) {
          await tester.sendKeyEvent(LogicalKeyboardKey.tab);
          await tester.pump();
          final node = FocusManager.instance.primaryFocus;
          if (node == null || node is FocusScopeNode) continue;
          if (node.rect.top < 66) continue;
          final inNav = node.rect.right <= navRight + 1;
          if (inNav && seen.contains(false)) break;
          seen.add(inNav);
        }
        final firstContent = seen.indexOf(false);
        expect(firstContent, 8);
        expect(seen.sublist(0, firstContent).every((nav) => nav), isTrue);
        expect(seen.sublist(firstContent).any((nav) => nav), isFalse);
      });
    });

    group('[$code] Q-6 the network list keeps its order while open', () {
      testWidgets(
        'Q-6 a network that disconnects stays in its place and loses only '
        'its mark',
        (tester) async {
          final (controller, _) = await pumpSettings(
            tester,
            code,
            state: settingsState(
              networks: [
                networkView(),
                networkView(
                  id: _office,
                  name: 'Oficina',
                  connected: false,
                  trustedAt: officeTrusted,
                ),
              ],
            ),
          );
          double top(String id) =>
              tester.getTopLeft(find.byKey(ValueKey('network-$id'))).dy;
          expect(top(homeNetwork), lessThan(top(_office)));

          controller.emit(
            settingsState(
              networks: [
                networkView(
                  id: _office,
                  name: 'Oficina',
                  connected: true,
                  trustedAt: officeTrusted,
                ),
                networkView(connected: false),
              ],
            ),
          );
          await tester.pumpAndSettle();
          expect(top(homeNetwork), lessThan(top(_office)));
          expect(
            find.descendant(
              of: find.byKey(const ValueKey('network-$homeNetwork')),
              matching: find.text(strings.connectedNow),
            ),
            findsNothing,
          );
          expect(
            find.descendant(
              of: find.byKey(const ValueKey('network-$_office')),
              matching: find.text(strings.connectedNow),
            ),
            findsOneWidget,
          );
        },
      );

      testWidgets('Q-6 reopening Settings sorts the list again', (
        tester,
      ) async {
        final (controller, settings) = await pumpSettings(
          tester,
          code,
          state: settingsState(
            networks: [
              networkView(),
              networkView(
                id: _office,
                name: 'Oficina',
                connected: false,
                trustedAt: officeTrusted,
              ),
            ],
          ),
        );
        controller.emit(
          settingsState(
            networks: [
              networkView(
                id: _office,
                name: 'Oficina',
                connected: true,
                trustedAt: officeTrusted,
              ),
              networkView(connected: false),
            ],
          ),
        );
        await tester.pumpAndSettle();
        await pressEscape(tester);
        settings.open();
        await tester.pumpAndSettle();
        double top(String id) =>
            tester.getTopLeft(find.byKey(ValueKey('network-$id'))).dy;
        expect(top(_office), lessThan(top(homeNetwork)));
      });
    });

    group('[$code] Q-7 the count and the titles', () {
      testWidgets('Q-7 the count sits at the right edge of the card', (
        tester,
      ) async {
        await pumpSettings(
          tester,
          code,
          state: settingsState(exclusions: const ['dist', 'out']),
        );
        final card = tester.getRect(sectionOf(strings.sectionExclusions));
        final count = tester.getRect(
          inSection(strings.sectionExclusions, find.text(strings.ofMax(2, 64))),
        );
        expect(card.right - count.right, closeTo(24, 1));
      });

      testWidgets('Q-7 at 150 % a title that fits is not cut', (tester) async {
        tester.platformDispatcher.textScaleFactorTestValue = 1.5;
        addTearDown(tester.platformDispatcher.clearAllTestValues);
        await pumpSettings(tester, code, size: _minimum);
        final title = tester.renderObject<RenderParagraph>(
          find.descendant(
            of: sectionOf(strings.sectionExclusions),
            matching: find.text(strings.sectionExclusions),
          ),
        );
        expect(title.didExceedMaxLines, isFalse);
      });
    });

    group('[$code] Q-8 controls follow the theme during the fade', () {
      testWidgets(
        'Q-8 the name field and the switch track keep pace with the theme '
        'in the middle of the fade',
        (tester) async {
          final mode = ValueNotifier<ThemeMode>(ThemeMode.dark);
          addTearDown(mode.dispose);
          final controller = TextEditingController();
          addTearDown(controller.dispose);
          late BuildContext inner;
          await tester.pumpWidget(
            ValueListenableBuilder<ThemeMode>(
              valueListenable: mode,
              builder: (context, themeMode, _) => MaterialApp(
                theme: buildTheme(Brightness.light),
                darkTheme: buildTheme(Brightness.dark),
                themeMode: themeMode,
                themeAnimationDuration: const Duration(milliseconds: 500),
                themeAnimationCurve: Curves.linear,
                home: Scaffold(
                  body: Builder(
                    builder: (context) {
                      inner = context;
                      return Column(
                        children: [
                          SettingsTextField(
                            controller: controller,
                            label: 'name',
                          ),
                          SettingsSwitch(
                            value: false,
                            label: 'tray',
                            onChanged: (_) {},
                          ),
                        ],
                      );
                    },
                  ),
                ),
              ),
            ),
          );
          await tester.pumpAndSettle();

          Color fieldBorder() {
            final box = tester.widget<DecoratedBox>(
              find
                  .descendant(
                    of: find.byType(SettingsTextField),
                    matching: find.byType(DecoratedBox),
                  )
                  .first,
            );
            return ((box.decoration as BoxDecoration).border! as Border)
                .top
                .color;
          }

          Color trackColor() {
            final box = tester.widget<Container>(
              find.descendant(
                of: find.byType(SettingsSwitch),
                matching: find.byType(Container),
              ),
            );
            return (box.decoration! as BoxDecoration).color!;
          }

          mode.value = ThemeMode.light;
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 250));
          final colors = NbColors.of(inner);
          expect(colors.border, isNot(NbColors.dark.border));
          expect(colors.border, isNot(NbColors.light.border));
          expect(fieldBorder(), colors.border);
          expect(trackColor(), colors.track);
        },
      );
    });

    group('[$code] Q-9 the focus goes back to the Settings button', () {
      bool isSettingsButton(FocusNode node) {
        final button = node.context
            ?.findAncestorWidgetOfExactType<IconButton>();
        return button != null && button.tooltip == strings.settingsButton;
      }

      testWidgets(
        'Q-9 after Esc the focus is on the button that opened Settings',
        (tester) async {
          final (_, settings) = await pumpSettings(tester, code, open: false);
          await _tabUntil(tester, isSettingsButton);
          final node = FocusManager.instance.primaryFocus!;

          await tester.sendKeyEvent(LogicalKeyboardKey.enter);
          await tester.pumpAndSettle();
          expect(settings.isOpen, isTrue);
          expect(FocusManager.instance.primaryFocus, isNot(node));

          await pressEscape(tester);
          expect(settings.isOpen, isFalse);
          expect(FocusManager.instance.primaryFocus, node);
        },
      );

      testWidgets(
        'Q-9 a close caused by a warning does not put the focus on a button',
        (tester) async {
          final (controller, settings) = await pumpSettings(
            tester,
            code,
            open: false,
            size: const Size(1200, 800),
          );
          await _tabUntil(tester, isSettingsButton);
          final node = FocusManager.instance.primaryFocus!;
          settings.open();
          await tester.pumpAndSettle();

          controller.emit(settingsState(incoming: incomingView()));
          await tester.pumpAndSettle();
          expect(settings.isOpen, isFalse);
          expect(FocusManager.instance.primaryFocus, isNot(node));
        },
      );
    });

    group('[$code] Q-11 the content fades in under the header', () {
      testWidgets('Q-11 a band of the ground colour fades the top of the '
          'scrolling area without a shader mask', (tester) async {
        await pumpSettings(tester, code, size: _short);
        final ground = NbColors.of(tester.element(settingsScreen)).ground;
        final fade = find.descendant(
          of: settingsScreen,
          matching: find.byWidgetPredicate(
            (widget) =>
                widget is DecoratedBox &&
                widget.decoration is BoxDecoration &&
                (widget.decoration as BoxDecoration).gradient is LinearGradient,
          ),
        );
        expect(fade, findsOneWidget);
        final gradient =
            (tester.widget<DecoratedBox>(fade).decoration as BoxDecoration)
                    .gradient!
                as LinearGradient;
        expect(gradient.colors, [ground, ground.withValues(alpha: 0)]);
        expect(gradient.begin, Alignment.topCenter);
        expect(gradient.end, Alignment.bottomCenter);
        final band = tester.getRect(fade);
        final scroll = tester.getRect(_scrollView());
        expect(band.top, scroll.top);
        expect(band.left, scroll.left);
        expect(band.width, scroll.width);
        expect(band.height, 14);
        expect(
          tester
              .widget<IgnorePointer>(
                find
                    .ancestor(of: fade, matching: find.byType(IgnorePointer))
                    .first,
              )
              .ignoring,
          isTrue,
        );
        expect(
          find.descendant(
            of: settingsScreen,
            matching: find.byType(ShaderMask),
          ),
          findsNothing,
        );
      });
    });
  }
}
