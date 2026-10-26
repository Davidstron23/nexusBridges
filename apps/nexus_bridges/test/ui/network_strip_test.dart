import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nexus_bridges/src/l10n/app_strings.dart';
import 'package:nexus_bridges/src/ui/icons/device_disc.dart';
import 'package:nexus_bridges/src/ui/icons/glyphs.dart';
import 'package:nexus_bridges/src/ui/network_strip.dart';
import 'package:nexus_bridges/src/ui/theme/app_theme.dart';
import 'package:nexus_bridges/src/ui/theme/tokens.dart';
import 'package:nexus_bridges_core/nexus_bridges_core.dart';

import 'fake_app_controller.dart';

const NetworkPrompt _home = NetworkPrompt('net-home', 'Casa');
const NetworkPrompt _office = NetworkPrompt('net-office', 'Oficina');
const NetworkPrompt _unnamed = NetworkPrompt('net-unnamed', '');
const String _dot = '\u00B7';
final String _longName = 'Red-${'x' * 60}';

class _Host {
  _Host(NodeState state) : state = ValueNotifier(state);

  final ValueNotifier<NodeState> state;
  int rescans = 0;
  final List<String> trusted = [];
}

NbColors _colorsFor(Brightness brightness) =>
    brightness == Brightness.dark ? NbColors.dark : NbColors.light;

Future<_Host> _mount(
  WidgetTester tester,
  NodeState state, {
  String code = 'en',
  double width = 900,
  bool compact = false,
  bool reduceMotion = false,
  Brightness brightness = Brightness.light,
  bool settle = true,
}) async {
  tester.view.physicalSize = const Size(1400, 600);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final host = _Host(state);
  await tester.pumpWidget(
    MaterialApp(
      locale: Locale(code),
      supportedLocales: const [Locale('en'), Locale('es')],
      localizationsDelegates: const [
        AppStringsDelegate(),
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      theme: buildTheme(Brightness.light),
      darkTheme: buildTheme(Brightness.dark),
      themeMode: brightness == Brightness.dark
          ? ThemeMode.dark
          : ThemeMode.light,
      themeAnimationDuration: Duration.zero,
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context).copyWith(disableAnimations: reduceMotion),
        child: child!,
      ),
      home: Scaffold(
        body: Align(
          alignment: Alignment.topLeft,
          child: SizedBox(
            width: width,
            child: ValueListenableBuilder<NodeState>(
              valueListenable: host.state,
              builder: (context, state, _) => NetworkStrip(
                state: state,
                onRescan: () => host.rescans++,
                onTrust: host.trusted.add,
                compact: compact,
              ),
            ),
          ),
        ),
      ),
    ),
  );
  if (settle) {
    await tester.pumpAndSettle();
  } else {
    await tester.pump();
  }
  return host;
}

Finder get _strip => find.byType(NetworkStrip);

Finder _inStrip(Finder finder) => find.descendant(of: _strip, matching: finder);

Finder get _outlined =>
    _inStrip(find.byWidgetPredicate((widget) => widget is OutlinedButton));

Finder get _iconButton => _inStrip(find.byType(IconButton));

Finder get _spinner => _inStrip(find.byType(RotationTransition));

VoidCallback? _outlinedAction(WidgetTester tester) =>
    tester.widget<ButtonStyleButton>(_outlined).onPressed;

Text _text(WidgetTester tester, String data) =>
    tester.widget<Text>(_inStrip(find.text(data)));

void main() {
  for (final code in languageCodes) {
    final strings = stringsFor(code);

    group('[$code] E265 trusted strip title and status', () {
      testWidgets('one network shows its name and trustedNetworkLabel', (
        tester,
      ) async {
        await _mount(
          tester,
          const NodeState(activeNetworks: [_home]),
          code: code,
        );

        expect(_inStrip(find.text('Casa')), findsOneWidget);
        expect(
          _inStrip(find.text(strings.trustedNetworkLabel)),
          findsOneWidget,
        );
        expect(find.text(strings.searchingDevices), findsNothing);
        expect(
          tester.getTopLeft(_inStrip(find.text('Casa'))).dx,
          lessThan(
            tester
                .getTopLeft(_inStrip(find.text(strings.trustedNetworkLabel)))
                .dx,
          ),
        );
        expect(tester.takeException(), isNull);
      });

      testWidgets('two networks are joined by " $_dot "', (tester) async {
        await _mount(
          tester,
          const NodeState(activeNetworks: [_home, _office]),
          code: code,
        );

        expect(_inStrip(find.text('Casa $_dot Oficina')), findsOneWidget);
        expect(
          _inStrip(find.text(strings.trustedNetworkLabel)),
          findsOneWidget,
        );
        expect(find.text('Casa'), findsNothing);
        expect(find.text('Oficina'), findsNothing);
      });

      testWidgets('no networks show trustedNetworkLabel once, as the title', (
        tester,
      ) async {
        await _mount(tester, const NodeState(), code: code);

        expect(
          _inStrip(find.text(strings.trustedNetworkLabel)),
          findsOneWidget,
        );
        expect(find.text(strings.searchingDevices), findsNothing);
      });

      testWidgets(
        'networks with empty names fall back to trustedNetworkLabel',
        (tester) async {
          await _mount(
            tester,
            const NodeState(activeNetworks: [_unnamed]),
            code: code,
          );
          expect(
            _inStrip(find.text(strings.trustedNetworkLabel)),
            findsOneWidget,
          );
          expect(_inStrip(find.text('')), findsNothing);

          await _mount(
            tester,
            const NodeState(activeNetworks: [_unnamed, _office]),
            code: code,
          );
          expect(_inStrip(find.text('Oficina')), findsOneWidget);
          expect(
            _inStrip(find.text(strings.trustedNetworkLabel)),
            findsOneWidget,
          );
        },
      );

      testWidgets('scanning swaps the status for searchingDevices', (
        tester,
      ) async {
        await _mount(
          tester,
          const NodeState(activeNetworks: [_home], scanning: true),
          code: code,
          settle: false,
        );

        expect(_inStrip(find.text('Casa')), findsOneWidget);
        expect(_inStrip(find.text(strings.searchingDevices)), findsOneWidget);
        expect(find.text(strings.trustedNetworkLabel), findsNothing);
      });

      testWidgets('scanning with no network names keeps the fallback title', (
        tester,
      ) async {
        await _mount(
          tester,
          const NodeState(scanning: true),
          code: code,
          settle: false,
        );

        expect(
          _inStrip(find.text(strings.trustedNetworkLabel)),
          findsOneWidget,
        );
        expect(_inStrip(find.text(strings.searchingDevices)), findsOneWidget);
      });

      testWidgets('the trusted strip is one line of 60 px with the trusted '
          'disc and no TextButton', (tester) async {
        await _mount(
          tester,
          const NodeState(activeNetworks: [_home, _office]),
          code: code,
        );

        expect(tester.getSize(_strip).height, 60);
        final disc = tester.widget<NetworkDisc>(
          _inStrip(find.byType(NetworkDisc)),
        );
        expect(disc.trusted, isTrue);
        expect(_inStrip(find.byType(TextButton)), findsNothing);
        expect(find.text(strings.pausedBanner), findsNothing);
      });
    });

    group('[$code] E265 note rule of 700 px', () {
      for (final (width, shows) in [
        (1200.0, true),
        (900.0, true),
        (700.0, true),
        (699.0, false),
        (600.0, false),
      ]) {
        testWidgets('a strip of $width ${shows ? 'shows' : 'hides'} '
            'onlyPairedCanSend', (tester) async {
          await _mount(
            tester,
            const NodeState(activeNetworks: [_home]),
            code: code,
            width: width,
          );

          expect(
            _inStrip(find.text(strings.onlyPairedCanSend)),
            shows ? findsOneWidget : findsNothing,
          );
          expect(tester.takeException(), isNull);
        });
      }

      testWidgets('the note is cut on one line with an ellipsis', (
        tester,
      ) async {
        await _mount(
          tester,
          const NodeState(activeNetworks: [_home]),
          code: code,
          width: 700,
        );

        final note = _text(tester, strings.onlyPairedCanSend);
        expect(note.maxLines, 1);
        expect(note.overflow, TextOverflow.ellipsis);
      });

      testWidgets('title, status and note share the width 1:1:2', (
        tester,
      ) async {
        await _mount(
          tester,
          const NodeState(activeNetworks: [_home]),
          code: code,
        );

        int flexOf(String text) => tester
            .widget<Flexible>(
              find
                  .ancestor(
                    of: _inStrip(find.text(text)),
                    matching: find.byType(Flexible),
                  )
                  .first,
            )
            .flex;
        expect(flexOf('Casa'), 1);
        expect(flexOf(strings.trustedNetworkLabel), 1);
        expect(flexOf(strings.onlyPairedCanSend), 2);
      });

      testWidgets('a very long network name does not push the note or the '
          'button out', (tester) async {
        final longTitle = 'N' * 200;
        await _mount(
          tester,
          NodeState(activeNetworks: [NetworkPrompt('net-long', longTitle)]),
          code: code,
        );

        expect(tester.takeException(), isNull);
        final title = _text(tester, longTitle);
        expect(title.maxLines, 1);
        expect(title.overflow, TextOverflow.ellipsis);
        final strip = tester.getRect(_strip);
        expect(tester.getRect(_outlined).right, lessThanOrEqualTo(strip.right));
        expect(
          tester.getSize(_inStrip(find.text(strings.onlyPairedCanSend))).width,
          greaterThan(0),
        );
        expect(
          tester.getSize(_inStrip(find.text(longTitle))).width,
          lessThan(strip.width / 2),
        );
      });
    });

    group('[$code] E265 and RF-194 rescan button', () {
      testWidgets('is an OutlinedButton with rescanButton and the refresh '
          'glyph, and calls onRescan', (tester) async {
        final host = await _mount(
          tester,
          const NodeState(activeNetworks: [_home]),
          code: code,
        );

        expect(_outlined, findsOneWidget);
        expect(
          find.descendant(
            of: _outlined,
            matching: find.text(strings.rescanButton),
          ),
          findsOneWidget,
        );
        final glyph = tester.widget<GlyphIcon>(
          find.descendant(of: _outlined, matching: find.byType(GlyphIcon)),
        );
        expect(glyph.glyph, Glyphs.refresh);
        expect(glyph.size, 14);
        expect(tester.getSize(_outlined).height, 36);
        expect(_outlinedAction(tester), isNotNull);

        await tester.tap(_outlined);
        await tester.pumpAndSettle();
        expect(host.rescans, 1);
      });

      testWidgets('without scanning there is no animation alive', (
        tester,
      ) async {
        await _mount(
          tester,
          const NodeState(activeNetworks: [_home]),
          code: code,
        );

        expect(tester.hasRunningAnimations, isFalse);
        final turns = tester.widget<RotationTransition>(_spinner).turns;
        expect(turns.value, 0);
      });

      testWidgets('scanning disables it and spins its icon', (tester) async {
        final host = await _mount(
          tester,
          const NodeState(activeNetworks: [_home], scanning: true),
          code: code,
          settle: false,
        );

        expect(_outlinedAction(tester), isNull);
        expect(tester.hasRunningAnimations, isTrue);
        final turns = tester.widget<RotationTransition>(_spinner).turns;
        final first = turns.value;
        await tester.pump(const Duration(milliseconds: 300));
        expect(turns.value, isNot(first));

        await tester.tap(_outlined, warnIfMissed: false);
        await tester.pump(const Duration(milliseconds: 100));
        expect(host.rescans, 0);
      }, timeout: const Timeout(Duration(seconds: 30)));

      testWidgets('the spin stops and resets when scanning ends', (
        tester,
      ) async {
        final host = await _mount(
          tester,
          const NodeState(activeNetworks: [_home], scanning: true),
          code: code,
          settle: false,
        );
        await tester.pump(const Duration(milliseconds: 250));

        host.state.value = const NodeState(activeNetworks: [_home]);
        await tester.pump();

        final turns = tester.widget<RotationTransition>(_spinner).turns;
        expect(turns.value, 0);
        expect((turns as AnimationController).isAnimating, isFalse);
        await tester.pump(const Duration(milliseconds: 300));
        expect(turns.value, 0);
        expect(_outlinedAction(tester), isNotNull);
        expect(find.text(strings.searchingDevices), findsNothing);
        await tester.pumpAndSettle();
      }, timeout: const Timeout(Duration(seconds: 30)));

      testWidgets('with reduced motion, scanning disables it without a spin', (
        tester,
      ) async {
        await _mount(
          tester,
          const NodeState(activeNetworks: [_home], scanning: true),
          code: code,
          reduceMotion: true,
        );

        expect(_outlinedAction(tester), isNull);
        expect(tester.hasRunningAnimations, isFalse);
        expect(_inStrip(find.text(strings.searchingDevices)), findsOneWidget);
      });
    });

    group('[$code] E264 compact rescan button', () {
      testWidgets(
        'is an IconButton with the rescanButton tooltip and no text',
        (tester) async {
          final host = await _mount(
            tester,
            const NodeState(activeNetworks: [_home]),
            code: code,
            width: 288,
            compact: true,
          );

          expect(_iconButton, findsOneWidget);
          expect(_outlined, findsNothing);
          expect(find.text(strings.rescanButton), findsNothing);
          expect(find.byTooltip(strings.rescanButton), findsOneWidget);
          final glyph = tester.widget<GlyphIcon>(
            find.descendant(of: _iconButton, matching: find.byType(GlyphIcon)),
          );
          expect(glyph.glyph, Glyphs.refresh);
          expect(glyph.size, 16);
          expect(tester.takeException(), isNull);

          await tester.tap(_iconButton);
          await tester.pumpAndSettle();
          expect(host.rescans, 1);
        },
      );

      testWidgets('scanning disables it and spins it', (tester) async {
        final host = await _mount(
          tester,
          const NodeState(activeNetworks: [_home], scanning: true),
          code: code,
          width: 288,
          compact: true,
          settle: false,
        );

        expect(tester.widget<IconButton>(_iconButton).onPressed, isNull);
        expect(tester.hasRunningAnimations, isTrue);
        await tester.tap(_iconButton, warnIfMissed: false);
        await tester.pump(const Duration(milliseconds: 100));
        expect(host.rescans, 0);
      }, timeout: const Timeout(Duration(seconds: 30)));

      testWidgets('long names at 288 px never cut the button', (tester) async {
        await _mount(
          tester,
          NodeState(
            activeNetworks: [
              NetworkPrompt('net-a', _longName),
              NetworkPrompt('net-b', _longName),
            ],
          ),
          code: code,
          width: 288,
          compact: true,
        );

        expect(tester.takeException(), isNull);
        final strip = tester.getRect(_strip);
        final button = tester.getRect(_iconButton);
        expect(button.right, lessThanOrEqualTo(strip.right));
        expect(button.width, greaterThanOrEqualTo(36));
      });
    });

    group('[$code] E265 and RF-19 paused strip', () {
      testWidgets('two networks show the banner, two network buttons and the '
          'rescan button', (tester) async {
        final host = await _mount(
          tester,
          const NodeState(paused: true, pausedNetworks: [_home, _office]),
          code: code,
        );

        expect(_inStrip(find.text(strings.pausedBanner)), findsOneWidget);
        expect(_inStrip(find.byType(TextButton)), findsNWidgets(2));
        expect(
          _inStrip(find.text(strings.trustNetworkButton('Casa'))),
          findsOneWidget,
        );
        expect(
          _inStrip(find.text(strings.trustNetworkButton('Oficina'))),
          findsOneWidget,
        );
        expect(_outlined, findsOneWidget);
        expect(find.text(strings.trustedNetworkLabel), findsNothing);
        expect(find.text(strings.searchingDevices), findsNothing);
        final disc = tester.widget<NetworkDisc>(
          _inStrip(find.byType(NetworkDisc)),
        );
        expect(disc.trusted, isFalse);

        await tester.tap(find.text(strings.trustNetworkButton('Oficina')));
        await tester.tap(find.text(strings.trustNetworkButton('Casa')));
        await tester.pumpAndSettle();
        expect(host.trusted, ['net-office', 'net-home']);

        await tester.tap(_outlined);
        await tester.pumpAndSettle();
        expect(host.rescans, 1);
      });

      testWidgets('without networks the banner and the rescan button stay', (
        tester,
      ) async {
        await _mount(tester, const NodeState(paused: true), code: code);

        expect(_inStrip(find.text(strings.pausedBanner)), findsOneWidget);
        expect(_inStrip(find.byType(TextButton)), findsNothing);
        expect(_outlined, findsOneWidget);
        expect(tester.getSize(_strip).height, greaterThanOrEqualTo(60));
      });

      testWidgets('scanning shows searchingDevices between the banner and the '
          'network buttons, and disables the rescan button', (tester) async {
        await _mount(
          tester,
          const NodeState(
            paused: true,
            pausedNetworks: [_home, _office],
            scanning: true,
          ),
          code: code,
          settle: false,
        );

        final banner = _inStrip(find.text(strings.pausedBanner));
        final searching = _inStrip(find.text(strings.searchingDevices));
        final network = _inStrip(find.text(strings.trustNetworkButton('Casa')));
        expect(searching, findsOneWidget);
        expect(
          tester.getTopLeft(searching).dy,
          greaterThanOrEqualTo(tester.getBottomLeft(banner).dy),
        );
        expect(
          tester.getBottomLeft(searching).dy,
          lessThanOrEqualTo(tester.getTopLeft(network).dy),
        );
        expect(_outlinedAction(tester), isNull);
        expect(tester.hasRunningAnimations, isTrue);
      }, timeout: const Timeout(Duration(seconds: 30)));

      testWidgets('a long network name stays on one line with an ellipsis', (
        tester,
      ) async {
        await _mount(
          tester,
          NodeState(
            paused: true,
            pausedNetworks: [NetworkPrompt('net-long', _longName), _office],
          ),
          code: code,
          width: 600,
        );

        expect(tester.takeException(), isNull);
        final label = _text(tester, strings.trustNetworkButton(_longName));
        expect(label.maxLines, 1);
        expect(label.overflow, TextOverflow.ellipsis);
        expect(
          tester
              .getRect(
                _inStrip(find.text(strings.trustNetworkButton(_longName))),
              )
              .right,
          lessThanOrEqualTo(tester.getRect(_strip).right),
        );
      });

      testWidgets('the strip grows when the network buttons wrap', (
        tester,
      ) async {
        await _mount(
          tester,
          const NodeState(paused: true, pausedNetworks: [_home, _office]),
          code: code,
          width: 360,
          compact: true,
        );

        expect(tester.takeException(), isNull);
        final casa = tester.getTopLeft(
          find.text(strings.trustNetworkButton('Casa')),
        );
        final oficina = tester.getTopLeft(
          find.text(strings.trustNetworkButton('Oficina')),
        );
        expect(oficina.dy, greaterThan(casa.dy));
        expect(tester.getSize(_strip).height, greaterThan(60));
      });
    });

    for (final brightness in Brightness.values) {
      group('[$code] ${brightness.name} strip colors', () {
        final colors = _colorsFor(brightness);

        testWidgets('the trusted strip uses netSurface, text and textWeak', (
          tester,
        ) async {
          await _mount(
            tester,
            const NodeState(activeNetworks: [_home]),
            code: code,
            brightness: brightness,
          );

          final box = tester.widget<DecoratedBox>(
            _inStrip(find.byType(DecoratedBox)).first,
          );
          final decoration = box.decoration as BoxDecoration;
          expect(decoration.color, colors.netSurface);
          expect(decoration.borderRadius, BorderRadius.circular(14));
          expect(decoration.border, isNull);
          expect(_text(tester, 'Casa').style?.color, colors.text);
          expect(
            _text(tester, strings.trustedNetworkLabel).style?.color,
            colors.textWeak,
          );
          expect(
            _text(tester, strings.onlyPairedCanSend).style?.color,
            colors.textWeak,
          );
        });

        testWidgets('the paused strip uses card with a border ring', (
          tester,
        ) async {
          await _mount(
            tester,
            const NodeState(paused: true, pausedNetworks: [_home]),
            code: code,
            brightness: brightness,
          );

          final box = tester.widget<DecoratedBox>(
            _inStrip(find.byType(DecoratedBox)).first,
          );
          final decoration = box.decoration as ShapeDecoration;
          expect(decoration.color, colors.card);
          final shape = decoration.shape as RoundedRectangleBorder;
          expect(shape.side.color, colors.border);
          expect(shape.borderRadius, BorderRadius.circular(14));
          expect(_text(tester, strings.pausedBanner).style?.color, colors.text);
        });

        testWidgets('searchingDevices is in textWeak while paused', (
          tester,
        ) async {
          await _mount(
            tester,
            const NodeState(paused: true, scanning: true),
            code: code,
            brightness: brightness,
            settle: false,
          );

          expect(
            _text(tester, strings.searchingDevices).style?.color,
            colors.textWeak,
          );
        }, timeout: const Timeout(Duration(seconds: 30)));
      });
    }
  }
}
