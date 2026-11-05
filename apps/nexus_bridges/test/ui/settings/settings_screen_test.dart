import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nexus_bridges/src/drop/drop_events.dart';
import 'package:nexus_bridges/src/drop/drop_zone.dart';
import 'package:nexus_bridges/src/l10n/app_strings.dart';
import 'package:nexus_bridges/src/ui/diagram/flow_painter.dart';
import 'package:nexus_bridges/src/ui/network_strip.dart';
import 'package:nexus_bridges/src/ui/settings/segmented_choice.dart';
import 'package:nexus_bridges/src/ui/settings/settings_controller.dart';
import 'package:nexus_bridges/src/ui/settings/settings_section.dart';
import 'package:nexus_bridges/src/ui/settings/system_tray_section.dart';
import 'package:nexus_bridges/src/ui/theme/app_theme.dart';
import 'package:nexus_bridges_core/nexus_bridges_core.dart';

import '../../drop/fake_drop_events.dart';
import '../fake_app_controller.dart';
import '../lifecycle_fixtures.dart';
import '../pairing_fixtures.dart';
import '../segoe_font.dart';
import '../transfer_fixtures.dart' show incomingView, senderName;
import 'settings_fixtures.dart';

List<String> _titles(AppStrings s) => [
  s.sectionDevice,
  s.sectionAppearance,
  s.sectionLanguage,
  s.sectionReceive,
  s.sectionExclusions,
  s.sectionSystemTray,
  s.sectionNetworks,
  s.sectionIgnored,
];

final String _fpA = fingerprintOf('AAAA1111');
final String _fpB = fingerprintOf('BBBB2222');
final String _fpOld = fingerprintOf('CDEF9876');

NodeState _withDevices({bool paused = false}) => settingsState(
  paused: paused,
  entries: [
    entry(fingerprint: _fpA, name: 'Torre', paired: true, mine: true),
    entry(fingerprint: _fpB, name: 'Portatil', paired: true),
  ],
);

FlowPainter _flow(WidgetTester tester) {
  for (final paint in tester.widgetList<CustomPaint>(
    find.byType(CustomPaint),
  )) {
    final painter = paint.foregroundPainter;
    if (painter is FlowPainter) return painter;
  }
  throw StateError('no flow painter');
}

T _segmentValue<T>(WidgetTester tester, String section) => tester
    .widget<SegmentedChoice<T>>(
      inSection(section, find.byType(SegmentedChoice<T>)),
    )
    .value;

Future<void> _mouseTap(WidgetTester tester, Offset at) async {
  final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
  await gesture.addPointer(location: at);
  await gesture.down(at);
  await gesture.up();
  await gesture.removePointer();
  await tester.pumpAndSettle();
}

Widget _stripApp(String code, Widget strip) => MaterialApp(
  locale: Locale(code),
  supportedLocales: const [Locale('en'), Locale('es')],
  localizationsDelegates: const [
    AppStringsDelegate(),
    GlobalMaterialLocalizations.delegate,
    GlobalWidgetsLocalizations.delegate,
    GlobalCupertinoLocalizations.delegate,
  ],
  theme: buildTheme(Brightness.dark),
  home: Scaffold(
    body: Align(
      alignment: Alignment.topLeft,
      child: SizedBox(width: 420, child: strip),
    ),
  ),
);

void main() {
  setUpAll(loadSegoe);

  for (final code in languageCodes) {
    final strings = stringsFor(code);

    group('[$code] E850 the settings button on the strip (RF-500)', () {
      for (final (label, paused) in [('normal', false), ('paused', true)]) {
        testWidgets('$label: the button is on the strip with its tooltip and '
            'opens Settings', (tester) async {
          final (_, settings) = await pumpSettings(
            tester,
            code,
            state: _withDevices(paused: paused),
            size: const Size(1200, 800),
            open: false,
          );

          final button = find.descendant(
            of: find.byType(NetworkStrip),
            matching: find.byTooltip(strings.settingsButton),
          );
          expect(button, findsOneWidget);
          expect(settingsScreen, findsNothing);

          await tester.tap(button);
          await tester.pumpAndSettle();

          expect(settings.isOpen, isTrue);
          expect(settingsScreen, findsOneWidget);
          expect(tester.takeException(), isNull);
        });
      }

      for (final paused in [false, true]) {
        testWidgets('compact${paused ? ' and paused' : ''}: the button is '
            'there with its tooltip and calls onSettings', (tester) async {
          setSize(tester, const Size(600, 300));
          var opened = 0;
          await tester.pumpWidget(
            _stripApp(
              code,
              NetworkStrip(
                state: _withDevices(paused: paused),
                onRescan: () {},
                onTrust: (_) {},
                onSettings: () => opened++,
                compact: true,
              ),
            ),
          );
          await tester.pumpAndSettle();

          final button = find.byTooltip(strings.settingsButton);
          expect(button, findsOneWidget);
          await tester.tap(button);
          await tester.pump();
          expect(opened, 1);
        });
      }

      testWidgets('at the minimum window size (760 x 520) Settings opens '
          'without overflowing', (tester) async {
        final (_, settings) = await pumpSettings(
          tester,
          code,
          size: const Size(760, 520),
          state: settingsState(
            networks: [networkView(transfers: 3, pairing: true)],
          ),
        );
        expect(settings.isOpen, isTrue);
        expect(tester.takeException(), isNull);
        final scrollable = find.descendant(
          of: settingsScreen,
          matching: find.byType(Scrollable),
        );
        await tester.drag(scrollable.first, const Offset(0, -5000));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
      });
    });

    group('[$code] E851 the eight sections with their values (RF-501)', () {
      testWidgets('the sections in the lab order, each with its current '
          'value', (tester) async {
        await pumpSettings(
          tester,
          code,
          theme: ThemeChoice.light,
          closeToTray: false,
          state: settingsState(
            exclusions: const ['node_modules', 'dist'],
            ignored: [
              ignoredView(
                fingerprint: _fpOld,
                name: 'Viejo',
                at: DateTime.utc(2026, 10, 1, 12),
              ),
            ],
          ),
        );

        final titles = _titles(strings);
        final tops = [
          for (final title in titles) tester.getTopLeft(sectionOf(title)).dy,
        ];
        for (var i = 1; i < tops.length; i++) {
          expect(tops[i], greaterThan(tops[i - 1]), reason: titles[i]);
        }
        expect(find.byType(SettingsSection), findsNWidgets(8));

        expect(
          tester
              .widget<TextField>(textField(strings.sectionDevice))
              .controller!
              .text,
          ownName,
        );
        expect(
          _segmentValue<ThemeChoice>(tester, strings.sectionAppearance),
          ThemeChoice.light,
        );
        expect(_segmentValue<String>(tester, strings.sectionLanguage), code);
        expect(
          inSection(strings.sectionReceive, find.text('Recibidos')),
          findsOneWidget,
        );
        expect(
          inSection(strings.sectionReceive, find.text(receivePath)),
          findsOneWidget,
        );
        expect(
          inSection(strings.sectionExclusions, find.text('dist')),
          findsOneWidget,
        );
        expect(
          inSection(strings.sectionExclusions, find.text(strings.ofMax(2, 64))),
          findsOneWidget,
        );
        expect(
          tester
              .widget<SettingsSwitch>(
                inSection(
                  strings.sectionSystemTray,
                  find.byType(SettingsSwitch),
                ),
              )
              .value,
          isFalse,
        );
        expect(
          inSection(strings.sectionNetworks, find.text('Casa')),
          findsOneWidget,
        );
        expect(
          inSection(strings.sectionIgnored, find.text('Viejo')),
          findsOneWidget,
        );
        expect(find.text(strings.settingsSubtitle(ownName)), findsOneWidget);
        expect(find.text(strings.settingsNavFoot), findsOneWidget);
      });

      testWidgets('without a receive folder: "you will be asked the first '
          'time"', (tester) async {
        await pumpSettings(
          tester,
          code,
          state: settingsState(receiveFolder: null),
        );

        expect(
          inSection(strings.sectionReceive, find.text(strings.receiveNotSet)),
          findsOneWidget,
        );
      });

      testWidgets('Esc and the arrow close Settings; the tab and the main '
          'view stay as they were', (tester) async {
        final (_, settings) = await pumpSettings(
          tester,
          code,
          state: _withDevices(),
          size: const Size(800, 600),
          open: false,
        );
        await tester.tap(find.text(strings.activityTab));
        await tester.pumpAndSettle();
        expect(find.text(strings.activityTab), findsOneWidget);

        await openSettings(tester, strings);
        await pressEscape(tester);
        expect(settings.isOpen, isFalse);
        expect(settings.closing, isFalse);
        expect(settingsScreen, findsNothing);
        expect(_activitySelected(tester, strings), isTrue);

        await openSettings(tester, strings);
        await tester.tap(find.byTooltip(strings.settingsBack));
        await tester.pumpAndSettle();
        expect(settingsScreen, findsNothing);
        expect(_activitySelected(tester, strings), isTrue);
      });

      testWidgets('the index follows the scroll and a click on it scrolls to '
          'the section', (tester) async {
        await pumpSettings(tester, code, size: const Size(1100, 900));
        final titles = _titles(strings);
        expect(navSelected(tester, titles.first), isTrue);

        final scrollable = find
            .descendant(of: settingsScreen, matching: find.byType(Scrollable))
            .first;
        final viewportTop = tester.getTopLeft(scrollable).dy;
        final receiveTop = tester
            .getTopLeft(sectionOf(strings.sectionReceive))
            .dy;
        await tester.drag(scrollable, Offset(0, -(receiveTop - viewportTop)));
        await tester.pumpAndSettle();
        expect(navSelected(tester, strings.sectionReceive), isTrue);
        expect(navSelected(tester, titles.first), isFalse);

        await tester.drag(scrollable, const Offset(0, 5000));
        await tester.pumpAndSettle();
        expect(navSelected(tester, titles.first), isTrue);

        final nav = find.descendant(
          of: settingsScreen,
          matching: find.byWidgetPredicate(
            (widget) =>
                widget is Semantics &&
                widget.properties.label == strings.sectionIgnored &&
                widget.properties.selected != null,
          ),
        );
        await tester.tap(nav);
        await tester.pumpAndSettle();
        expect(navSelected(tester, strings.sectionIgnored), isTrue);
        final top = tester.getTopLeft(sectionOf(strings.sectionIgnored)).dy;
        expect(top, lessThan(viewportTop + 200));
        expect(top, greaterThanOrEqualTo(viewportTop));
      });

      testWidgets('with less motion it opens and closes at once', (
        tester,
      ) async {
        final (_, settings) = await pumpSettings(
          tester,
          code,
          reduceMotion: true,
          open: false,
        );
        await tester.tap(find.byTooltip(strings.settingsButton));
        await tester.pump();
        expect(settingsScreen, findsOneWidget);
        final shown = tester.widget<Opacity>(
          find
              .ancestor(of: settingsScreen, matching: find.byType(Opacity))
              .first,
        );
        expect(shown.opacity, 1);

        await tester.sendKeyEvent(LogicalKeyboardKey.escape);
        await tester.pump();
        expect(settings.isOpen, isFalse);
        expect(settingsScreen, findsNothing);
      });
    });

    group('[$code] Esc and the focus inside Settings', () {
      testWidgets('with a confirmation open, Esc cancels it first and a second '
          'Esc closes Settings', (tester) async {
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
        expect(confirmOpen(tester, strings.sectionExclusions), isTrue);

        await pressEscape(tester);
        expect(confirmOpen(tester, strings.sectionExclusions), isFalse);
        expect(settings.isOpen, isTrue);
        expect(controller.calls, isEmpty);

        await pressEscape(tester);
        expect(settings.isOpen, isFalse);
        expect(controller.calls, isEmpty);
      });

      testWidgets('after focusing a text field and clicking elsewhere, Esc '
          'still closes Settings', (tester) async {
        final (_, settings) = await pumpSettings(tester, code);
        await tester.tap(textField(strings.sectionDevice));
        await tester.pumpAndSettle();
        expect(
          FocusManager.instance.primaryFocus?.context
              ?.findAncestorWidgetOfExactType<TextField>(),
          isNotNull,
        );

        await _mouseTap(
          tester,
          tester.getCenter(find.text(strings.settingsFooter)),
        );
        await pressEscape(tester);
        expect(settings.isOpen, isFalse);
        expect(settingsScreen, findsNothing);
      }, variant: TargetPlatformVariant.only(TargetPlatform.windows));

      testWidgets('with the focus in a text field, Esc closes Settings', (
        tester,
      ) async {
        final (_, settings) = await pumpSettings(tester, code);
        await tester.tap(textField(strings.sectionExclusions));
        await tester.pumpAndSettle();

        await pressEscape(tester);
        expect(settings.isOpen, isFalse);
      });

      testWidgets('while Settings is open the main view takes neither focus '
          'nor clicks', (tester) async {
        final (controller, _) = await pumpSettings(tester, code);
        for (var i = 0; i < 40; i++) {
          await tester.sendKeyEvent(LogicalKeyboardKey.tab);
          await tester.pump();
          final focused = FocusManager.instance.primaryFocus?.context;
          if (focused == null) continue;
          expect(
            find
                .descendant(
                  of: settingsScreen,
                  matching: find.byElementPredicate((e) => e == focused),
                )
                .evaluate(),
            isNotEmpty,
            reason: 'tab $i',
          );
        }
        await tester.tap(
          find.byTooltip(strings.settingsButton),
          warnIfMissed: false,
        );
        await tester.pumpAndSettle();
        expect(controller.calls, isEmpty);
      });
    });

    group('[$code] E857 settings apply without a save button (RF-502)', () {
      testWidgets('Light, Windows and English apply at once and the footer '
          'says everything is saved at once except the name', (tester) async {
        final (controller, _) = await pumpSettings(tester, code);

        expect(find.text(strings.settingsFooter), findsOneWidget);
        await tester.tap(
          inSection(strings.sectionAppearance, find.text(strings.themeLight)),
        );
        await tester.pumpAndSettle();
        expect(controller.theme, ThemeChoice.light);
        await tester.tap(
          inSection(strings.sectionAppearance, find.text(strings.themeWindows)),
        );
        await tester.pumpAndSettle();
        expect(controller.theme, ThemeChoice.system);
        final other = code == 'es' ? 'en' : 'es';
        await tester.tap(
          inSection(
            strings.sectionLanguage,
            find.text(
              other == 'en' ? strings.languageEnglish : strings.languageSpanish,
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(controller.languageCode, other);
        await tester.tap(
          inSection(strings.sectionSystemTray, find.byType(SettingsSwitch)),
        );
        await tester.pumpAndSettle();
        expect(controller.closeToTray, isFalse);
        expect(
          inSection(
            strings.sectionSystemTray,
            find.text(strings.systemTrayOffHelp),
          ),
          findsOneWidget,
        );
        expect(controller.calls, [
          'setTheme light',
          'setTheme system',
          'setLanguage $other',
          'setCloseToTray false',
        ]);
        expect(find.text(strings.saveButton), findsOneWidget);
      });
    });

    group(
      '[$code] E864 dropping with Settings open does nothing (point 2)',
      () {
        Future<(FakeAppController, SettingsController, FakeDropEvents)> pump(
          WidgetTester tester,
        ) async {
          setSize(tester, const Size(1200, 800));
          final controller = FakeAppController(state: _withDevices());
          final settings = SettingsController();
          final events = FakeDropEvents();
          addTearDown(events.close);
          await pumpHome(
            tester,
            controller,
            code,
            settings: settings,
            dropEvents: events,
          );
          return (controller, settings, events);
        }

        testWidgets('without Settings the drag lights up; with Settings open '
            'nothing lights up and the drop sends nothing', (tester) async {
          final (controller, settings, events) = await pump(tester);
          final row = tester.getCenter(find.byKey(ValueKey(_fpA)));

          events.add(DropEnter(row));
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 460));
          expect(_flow(tester).lit, isNotEmpty);
          expect(
            tester.widget<DragPill>(find.byType(DragPill)).visible,
            isTrue,
          );
          events.add(const DropLeave());
          await tester.pumpAndSettle();

          await openSettings(tester, strings);
          events.add(DropEnter(row));
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 460));
          expect(_flow(tester).dragFade?.value ?? 0, 0);
          expect(_flow(tester).hot, isNull);
          expect(
            tester.widget<DragPill>(find.byType(DragPill)).visible,
            isFalse,
          );
          expect(find.text(strings.dragHint), findsNothing);
          events.add(DropOver(row));
          events.add(DropDone(row, const [r'C:\a.txt'], 1));
          await tester.pumpAndSettle();

          expect(controller.sendPathsCalls, isEmpty);
          expect(controller.addToTrayCalls, isEmpty);
          expect(settings.isOpen, isTrue);
        });

        testWidgets('while Settings is closing the drop is ignored too', (
          tester,
        ) async {
          final (controller, settings, events) = await pump(tester);
          final row = tester.getCenter(find.byKey(ValueKey(_fpB)));
          await openSettings(tester, strings);

          settings.close();
          await tester.pump();
          expect(settings.closing, isTrue);
          events.add(DropEnter(row));
          events.add(DropDone(row, const [r'C:\a.txt'], 1));
          await tester.pump();
          expect(controller.sendPathsCalls, isEmpty);
          expect(controller.addToTrayCalls, isEmpty);
          await tester.pumpAndSettle();
          expect(settings.closing, isFalse);

          events.add(DropEnter(row));
          events.add(DropDone(row, const [r'C:\a.txt'], 1));
          await tester.pumpAndSettle();
          expect(
            controller.sendPathsCalls.length + controller.addToTrayCalls.length,
            1,
          );
        });
      },
    );

    group('[$code] E852 and E898 something that needs an answer closes '
        'Settings (RF-505)', () {
      testWidgets(
        'a stranger warning closes Settings and the card is in view',
        (tester) async {
          final (controller, settings) = await pumpSettings(
            tester,
            code,
            size: const Size(1200, 800),
          );

          controller.emit(settingsState(incoming: incomingView()));
          await tester.pumpAndSettle();

          expect(settings.isOpen, isFalse);
          expect(settingsScreen, findsNothing);
          expect(
            find.text(strings.incomingRequestTitle(senderName)).hitTestable(),
            findsOneWidget,
          );
        },
      );

      testWidgets('E898 with the window visible it closes with the exit '
          'animation', (tester) async {
        final (controller, settings) = await pumpSettings(tester, code);

        controller.emit(settingsState(incoming: incomingView()));
        await tester.pump();
        expect(settings.isOpen, isFalse);
        expect(settings.closing, isTrue);
        await tester.pump(const Duration(milliseconds: 100));
        expect(settingsScreen, findsOneWidget);
        await tester.pumpAndSettle();
        expect(settingsScreen, findsNothing);
      });

      for (final hidden in [
        AppLifecycleState.hidden,
        AppLifecycleState.paused,
      ]) {
        testWidgets('E898 with the window ${hidden.name} it closes without '
            'animation and the first frame after showing it has no Settings', (
          tester,
        ) async {
          resumeOnTearDown(tester);
          final (controller, settings) = await pumpSettings(tester, code);
          await goToLifecycle(tester, hidden);

          controller.emit(settingsState(incoming: incomingView()));
          expect(settings.isOpen, isFalse);
          expect(settings.closing, isFalse);
          expect(settings.instant, isTrue);

          await goToLifecycle(tester, AppLifecycleState.resumed);
          expect(settingsScreen, findsNothing);
        });
      }

      testWidgets('the folder question and the pairing request as receiver '
          'close it too', (tester) async {
        final (controller, settings) = await pumpSettings(tester, code);
        controller.emit(
          settingsState(
            incoming: incomingView(
              stage: IncomingStage.folderQuestion,
              folder: const FolderQuestionView(
                kind: FolderQuestionKind.firstTime,
                proposedPath: r'C:\Users\David\Downloads',
              ),
            ),
          ),
        );
        await _pumpSome(tester);
        expect(settings.isOpen, isFalse);

        controller.emit(settingsState());
        await _pumpSome(tester);
        await tester.tap(find.byTooltip(strings.settingsButton));
        await _pumpSome(tester);
        expect(settings.isOpen, isTrue);
        controller.emit(
          settingsState(
            pairing: view(
              role: PairingRole.receiver,
              phase: PairingPhase.comparing,
            ),
          ),
        );
        await _pumpSome(tester);
        expect(settings.isOpen, isFalse);
      });

      testWidgets('what does not need an answer leaves Settings open', (
        tester,
      ) async {
        final (controller, settings) = await pumpSettings(tester, code);
        controller.emit(
          settingsState(
            notices: const [Notice(id: 1, kind: NoticeKind.settingNotSaved)],
            pairing: view(
              role: PairingRole.initiator,
              phase: PairingPhase.comparing,
            ),
            incoming: incomingView(stage: IncomingStage.receiving),
          ),
        );
        await _pumpSome(tester);
        expect(settings.isOpen, isTrue);
        expect(settingsScreen, findsOneWidget);
      });

      testWidgets('the same warning already there when Settings opens does '
          'not close it again', (tester) async {
        final (controller, settings) = await pumpSettings(
          tester,
          code,
          state: settingsState(incoming: incomingView()),
        );
        expect(settings.isOpen, isTrue);
        controller.emit(settingsState(incoming: incomingView()));
        await tester.pumpAndSettle();
        expect(settings.isOpen, isTrue);
      });
    });
  }
}

Future<void> _pumpSome(WidgetTester tester) async {
  for (var i = 0; i < 8; i++) {
    await tester.pump(const Duration(milliseconds: 150));
  }
}

bool _activitySelected(WidgetTester tester, AppStrings strings) => tester
    .widget<Semantics>(
      find
          .ancestor(
            of: find.text(strings.activityTab),
            matching: find.byWidgetPredicate(
              (widget) =>
                  widget is Semantics && widget.properties.selected != null,
            ),
          )
          .first,
    )
    .properties
    .selected!;
