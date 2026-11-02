import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nexus_bridges/src/l10n/app_strings.dart';
import 'package:nexus_bridges/src/ui/activity_cards.dart';
import 'package:nexus_bridges/src/ui/brand/brand_mark.dart';
import 'package:nexus_bridges/src/ui/device_list.dart';
import 'package:nexus_bridges/src/ui/diagram/flow_diagram.dart';
import 'package:nexus_bridges/src/ui/home_layout.dart';
import 'package:nexus_bridges/src/ui/network_strip.dart';
import 'package:nexus_bridges/src/ui/theme/components.dart';
import 'package:nexus_bridges/src/ui/theme/tokens.dart';
import 'package:nexus_bridges_core/nexus_bridges_core.dart';

import 'fake_app_controller.dart';

const NetworkPrompt _home = NetworkPrompt('net-home', 'Casa');
const NetworkPrompt _office = NetworkPrompt('net-office', 'Oficina');

final String _fpA = fingerprintOf('A1');
final String _fpB = fingerprintOf('B2');
final String _fpC = fingerprintOf('C3');

DeviceEntry _entry(
  String fingerprint,
  String name, {
  bool paired = false,
  bool visible = true,
}) => DeviceEntry(
  fingerprint: fingerprint,
  displayName: name,
  deviceType: visible ? DeviceType.desktop : null,
  visible: visible,
  paired: paired,
  mine: true,
  ignored: false,
  mismatch: false,
  possiblyReplaces: null,
);

final List<DeviceEntry> _threeEntries = [
  _entry(_fpA, 'PC principal', paired: true),
  _entry(_fpB, 'Portatil', paired: true),
  _entry(_fpC, 'Movil'),
];

OutgoingTransferView _out(
  String fingerprint, {
  String fileName = 'report.pdf',
  int sent = 0,
}) => OutgoingTransferView(
  peerFingerprint: fingerprint,
  peerName: 'PC principal',
  fileName: fileName,
  size: 1000,
  isProgram: false,
  phase: OutgoingPhase.uploading,
  sentBytes: sent,
  cancelling: false,
);

const TransferResultView _sent = TransferResultView(
  direction: TransferDirection.outgoing,
  peerFingerprint: 'peer',
  peerName: 'PC principal',
  fileName: 'report.pdf',
  isProgram: false,
  outcome: TransferOutcome.saved,
  canReveal: false,
);

void _window(WidgetTester tester, Size size) {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
}

void _dark(WidgetTester tester) {
  tester.platformDispatcher.platformBrightnessTestValue = Brightness.dark;
  addTearDown(tester.platformDispatcher.clearPlatformBrightnessTestValue);
}

Finder get _strip => find.byType(NetworkStrip);

Finder _inStrip(Finder finder) => find.descendant(of: _strip, matching: finder);

Finder get _stripOutlined =>
    _inStrip(find.byWidgetPredicate((widget) => widget is OutlinedButton));

Finder get _column => find.byType(SingleChildScrollView);

Finder _tab(String label) =>
    find.ancestor(of: find.text(label), matching: find.byType(InkWell));

Finder get _thumb => find.ancestor(
  of: find.byType(FractionallySizedBox),
  matching: find.byType(AnimatedAlign),
);

bool _selected(WidgetTester tester, String label) => tester
    .widget<Semantics>(
      find
          .ancestor(
            of: find.text(label),
            matching: find.byWidgetPredicate(
              (widget) =>
                  widget is Semantics && widget.properties.selected != null,
            ),
          )
          .first,
    )
    .properties
    .selected!;

bool _showsDevices(WidgetTester tester, AppStrings strings) {
  final devices = _selected(tester, strings.devicesTab);
  expect(_selected(tester, strings.activityTab), !devices);
  expect(find.byType(ActivityPanel), devices ? findsNothing : findsOneWidget);
  expect(find.byType(DeviceList), devices ? findsOneWidget : findsNothing);
  return devices;
}

Future<void> _settle(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
}

void main() {
  for (final code in languageCodes) {
    final strings = stringsFor(code);

    group('[$code] E264 body', () {
      final windows = <(Size, bool)>[
        (const Size(1180, 720), true),
        (const Size(800, 600), true),
        (const Size(760, 520), true),
        (const Size(748, 520), true),
        (const Size(747, 520), false),
        (const Size(700, 600), false),
        (const Size(320, 800), false),
      ];
      for (final (size, diagram) in windows) {
        testWidgets('a window of ${size.width.toInt()}x${size.height.toInt()} '
            '${diagram ? 'shows the diagram and the column' : 'shows only '
                      'the column'}', (tester) async {
          _window(tester, size);
          final controller = FakeAppController(
            state: NodeState(entries: _threeEntries),
          );
          await pumpHome(tester, controller, code);

          expect(tester.takeException(), isNull);
          expect(find.byType(AppBar), findsNothing);
          expect(find.text(strings.devicesTab), findsOneWidget);
          final body = size.width - 32;
          expect(showsDiagram(body), diagram);
          if (diagram) {
            expect(find.byType(FlowDiagram), findsOneWidget);
            expect(
              tester.getSize(_column).width,
              closeTo(columnWidthFor(body), 0.01),
            );
            expect(
              tester.getSize(find.byType(FlowDiagram)).width,
              closeTo(body - 16 - columnWidthFor(body), 0.01),
            );
            expect(
              tester.getRect(find.byType(FlowDiagram)).right + 16,
              closeTo(tester.getRect(_column).left, 0.01),
            );
          } else {
            expect(find.byType(FlowDiagram), findsNothing);
            expect(tester.getSize(_column).width, closeTo(body, 0.01));
          }
        });
      }

      testWidgets('the minimum window of 760x520 keeps a diagram of 432x416', (
        tester,
      ) async {
        _window(tester, const Size(760, 520));
        final controller = FakeAppController(
          state: NodeState(
            entries: _threeEntries,
            activeNetworks: const [_home],
          ),
        );
        await pumpHome(tester, controller, code);

        expect(tester.takeException(), isNull);
        expect(tester.getSize(find.byType(FlowDiagram)), const Size(432, 416));
        final card = find.ancestor(
          of: find.byType(FlowDiagram),
          matching: find.byType(NbCard),
        );
        expect(card, findsOneWidget);
        expect(tester.widget<NbCard>(card).padding, EdgeInsets.zero);
        expect(tester.getSize(_column).width, 280);
      });

      testWidgets('the diagram gets the state and its +k disc opens Devices', (
        tester,
      ) async {
        _window(tester, const Size(800, 600));
        final controller = FakeAppController(
          state: NodeState(
            entries: [
              for (var i = 0; i < 32; i++)
                _entry(fingerprintOf('D$i'), 'Equipo $i', paired: true),
            ],
          ),
        );
        await pumpHome(tester, controller, code);

        final diagram = tester.widget<FlowDiagram>(find.byType(FlowDiagram));
        expect(diagram.state, same(controller.state));

        await tester.tap(find.text(strings.activityTab));
        await tester.pumpAndSettle();
        expect(_showsDevices(tester, strings), isFalse);

        await tester.tap(find.byKey(const ValueKey('flow-more')));
        await tester.pumpAndSettle();
        expect(_showsDevices(tester, strings), isTrue);
      });

      testWidgets('Send file in the diagram popover, not the one of a row, '
          'calls sendFolders for that device through its menu', (tester) async {
        _window(tester, const Size(800, 600));
        final controller = FakeAppController(
          state: NodeState(entries: _threeEntries),
        );
        await pumpHome(tester, controller, code);

        await tester.tap(find.byKey(ValueKey('flow-peer-$_fpB')));
        await tester.pumpAndSettle();
        final popoverSend = find.descendant(
          of: find.byType(FlowDiagram),
          matching: find.text(strings.sendEllipsis),
        );
        expect(popoverSend, findsOneWidget);
        expect(find.text(strings.sendEllipsis), findsNWidgets(3));
        await tester.tap(popoverSend);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 240));
        await tester.tap(find.text(strings.sendFoldersOption));
        await tester.pump();

        expect(controller.calls, ['sendFolders $_fpB']);
        await tester.pumpAndSettle();
        expect(popoverSend, findsNothing);
        expect(find.byType(SnackBar), findsNothing);
      });
    });

    group('[$code] E264 header without the mark (point 153)', () {
      final screens = <String, (NodeState?, bool, bool)>{
        'normal': (const NodeState(), false, true),
        'no state': (null, false, false),
        'start failed': (const NodeState(), true, false),
        'identity failed': (
          const NodeState(identityStatus: IdentityStatus.failed),
          false,
          false,
        ),
        'port in use': (const NodeState(portInUse: 53530), false, false),
      };
      for (final width in [1180.0, 800.0, 320.0]) {
        for (final MapEntry(key: name, value: (state, failed, normal))
            in screens.entries) {
          testWidgets(
            '$name at $width px paints neither the mark nor appTitle'
            '${normal ? ', and the strip fills the header' : ', nor the strip'}',
            (tester) async {
              _window(tester, Size(width, 800));
              final controller = FakeAppController(
                state: state,
                startFailed: failed,
              );
              await pumpHome(tester, controller, code);

              expect(tester.takeException(), isNull);
              expect(find.byType(BrandMark), findsNothing);
              expect(find.text(strings.appTitle), findsNothing);
              expect(find.byType(AppBar), findsNothing);
              expect(_strip, normal ? findsOneWidget : findsNothing);
              if (normal) {
                final strip = tester.getRect(_strip);
                expect(strip.left, closeTo(16, 0.01));
                expect(strip.right, closeTo(width - 16, 0.01));
                expect(strip.top, closeTo(12, 0.01));
                expect(
                  tester.widget<NetworkStrip>(_strip).compact,
                  width < 600,
                );
              } else {
                expect(find.byType(FlowDiagram), findsNothing);
                expect(find.text(strings.devicesTab), findsNothing);
                expect(find.text(strings.retryButton), findsOneWidget);
              }
            },
          );
        }
      }

      testWidgets('at 800x600 the strip alone fills the header, 60 px high, '
          'with the text button', (tester) async {
        _window(tester, const Size(800, 600));
        final controller = FakeAppController(
          state: NodeState(
            activeNetworks: const [_home],
            entries: _threeEntries,
          ),
        );
        await pumpHome(tester, controller, code);

        expect(tester.takeException(), isNull);
        expect(tester.widget<NetworkStrip>(_strip).compact, isFalse);
        expect(tester.getRect(_strip), const Rect.fromLTRB(16, 12, 784, 72));
        expect(_stripOutlined, findsOneWidget);
        expect(_inStrip(find.byType(IconButton)), findsNothing);
        expect(find.text(strings.rescanButton), findsOneWidget);
        expect(
          tester.getRect(_strip).bottom,
          lessThan(tester.getRect(find.byType(FlowDiagram)).top),
        );
      });

      testWidgets('at 320x800 the strip stays on the first row, compact, with '
          'an icon button and its tooltip', (tester) async {
        _window(tester, const Size(320, 800));
        final controller = FakeAppController(
          state: NodeState(
            activeNetworks: const [_home],
            entries: _threeEntries,
          ),
        );
        await pumpHome(tester, controller, code);

        expect(tester.takeException(), isNull);
        expect(tester.widget<NetworkStrip>(_strip).compact, isTrue);
        final strip = tester.getRect(_strip);
        expect(strip.top, closeTo(12, 0.01));
        expect(strip.left, closeTo(16, 0.01));
        expect(strip.width, closeTo(320 - 32, 0.01));
        expect(find.byType(BrandMark), findsNothing);
        expect(find.text(strings.appTitle), findsNothing);
        expect(_inStrip(find.byType(IconButton)), findsOneWidget);
        expect(_stripOutlined, findsNothing);
        expect(find.text(strings.rescanButton), findsNothing);
        expect(find.byTooltip(strings.rescanButton), findsOneWidget);
        expect(
          tester
              .widget<IconButton>(_inStrip(find.byType(IconButton)))
              .onPressed,
          isNotNull,
        );
        expect(
          strip.bottom,
          lessThan(tester.getTopLeft(_tab(strings.devicesTab)).dy),
        );

        await tester.tap(_inStrip(find.byType(IconButton)));
        await tester.pumpAndSettle();
        expect(controller.calls, ['rescan']);
      });

      testWidgets('at 320x800 scanning disables the icon button', (
        tester,
      ) async {
        _window(tester, const Size(320, 800));
        final controller = FakeAppController(
          state: NodeState(
            activeNetworks: const [_home, _office],
            entries: _threeEntries,
            scanning: true,
          ),
        );
        await pumpHome(tester, controller, code, settle: false);

        expect(tester.takeException(), isNull);
        expect(
          tester
              .widget<IconButton>(_inStrip(find.byType(IconButton)))
              .onPressed,
          isNull,
        );
        expect(_inStrip(find.text(strings.searchingDevices)), findsOneWidget);
        await tester.tap(
          _inStrip(find.byType(IconButton)),
          warnIfMissed: false,
        );
        await tester.pump(const Duration(milliseconds: 100));
        expect(controller.calls, isEmpty);
      }, timeout: const Timeout(Duration(seconds: 30)));

      testWidgets('at 320x800 the paused strip with two networks fits', (
        tester,
      ) async {
        _window(tester, const Size(320, 800));
        final controller = FakeAppController(
          state: const NodeState(
            paused: true,
            pausedNetworks: [_home, _office],
          ),
        );
        await pumpHome(tester, controller, code);

        expect(tester.takeException(), isNull);
        expect(find.text(strings.pausedBanner), findsOneWidget);
        expect(find.byType(TextButton), findsNWidgets(2));
      });

      for (final (width, compact) in [
        (599.0, true),
        (600.0, false),
        (610.0, false),
      ]) {
        testWidgets('a header of $width px ${compact ? 'is' : 'is not'} '
            'compact and the strip stays on the first row at full width', (
          tester,
        ) async {
          _window(tester, Size(width, 700));
          final controller = FakeAppController(
            state: const NodeState(activeNetworks: [_home]),
          );
          await pumpHome(tester, controller, code);

          expect(tester.takeException(), isNull);
          expect(tester.widget<NetworkStrip>(_strip).compact, compact);
          final strip = tester.getRect(_strip);
          expect(strip.top, closeTo(12, 0.01));
          expect(strip.left, closeTo(16, 0.01));
          expect(strip.right, closeTo(width - 16, 0.01));
          expect(
            _inStrip(find.byType(IconButton)),
            compact ? findsOneWidget : findsNothing,
          );
          expect(_stripOutlined, compact ? findsNothing : findsOneWidget);
          expect(find.byType(BrandMark), findsNothing);
        });
      }
    });

    group('[$code] E265 strip in the screen', () {
      testWidgets('shows the name of the network in use, measures the whole '
          'header and shows the note only from 700 px', (tester) async {
        _window(tester, const Size(700, 600));
        final controller = FakeAppController(
          state: const NodeState(activeNetworks: [_home]),
        );
        await pumpHome(tester, controller, code);

        expect(_inStrip(find.text('Casa')), findsOneWidget);
        expect(
          _inStrip(find.text(strings.trustedNetworkLabel)),
          findsOneWidget,
        );
        expect(tester.getSize(_strip).width, closeTo(700 - 32, 0.01));
        expect(find.text(strings.onlyPairedCanSend), findsNothing);

        _window(tester, const Size(800, 600));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        expect(tester.getSize(_strip).width, closeTo(800 - 32, 0.01));
        expect(find.text(strings.onlyPairedCanSend), findsOneWidget);

        _window(tester, const Size(1180, 720));
        await tester.pumpAndSettle();
        expect(tester.getSize(_strip).width, closeTo(1180 - 32, 0.01));
        expect(find.text(strings.onlyPairedCanSend), findsOneWidget);
      });

      testWidgets('two networks in use are joined in the title', (
        tester,
      ) async {
        _window(tester, const Size(800, 600));
        final controller = FakeAppController(
          state: const NodeState(activeNetworks: [_home, _office]),
        );
        await pumpHome(tester, controller, code);

        expect(_inStrip(find.text('Casa \u00B7 Oficina')), findsOneWidget);
      });

      testWidgets('the strip follows new states', (tester) async {
        _window(tester, const Size(800, 600));
        final controller = FakeAppController(
          state: const NodeState(activeNetworks: [_home]),
        );
        await pumpHome(tester, controller, code);

        controller.emit(
          const NodeState(paused: true, pausedNetworks: [_office]),
        );
        await tester.pumpAndSettle();
        expect(find.text('Casa'), findsNothing);
        expect(find.text(strings.pausedBanner), findsOneWidget);

        controller.emit(const NodeState(activeNetworks: [_office]));
        await tester.pumpAndSettle();
        expect(find.text(strings.pausedBanner), findsNothing);
        expect(_inStrip(find.text('Oficina')), findsOneWidget);
      });

      testWidgets('the paused strip with two networks at 800x600 has no '
          'layout exceptions and keeps searchingDevices', (tester) async {
        _window(tester, const Size(800, 600));
        final controller = FakeAppController(
          state: NodeState(
            paused: true,
            pausedNetworks: const [_home, _office],
            scanning: true,
            decisionNotSaved: true,
            identityStatus: IdentityStatus.reset,
            entries: _threeEntries,
          ),
        );
        await pumpHome(tester, controller, code, settle: false);

        expect(tester.takeException(), isNull);
        expect(_inStrip(find.text(strings.pausedBanner)), findsOneWidget);
        expect(_inStrip(find.text(strings.searchingDevices)), findsOneWidget);
        expect(_inStrip(find.byType(TextButton)), findsNWidgets(2));
        expect(_stripOutlined, findsOneWidget);
        expect(
          tester.getRect(_strip).bottom,
          lessThan(tester.getRect(find.byType(FlowDiagram)).top),
        );

        await tester.tap(find.text(strings.trustNetworkButton('Oficina')));
        await tester.pump(const Duration(milliseconds: 100));
        expect(controller.calls, ['askAgain net-office']);
      }, timeout: const Timeout(Duration(seconds: 30)));

      final lists = <String, List<DeviceEntry>>{
        'an empty list': const [],
        'a paired device that is not visible': [
          _entry(_fpA, 'PC principal', paired: true, visible: false),
        ],
        'a visible device': [_entry(_fpB, 'Portatil')],
      };
      for (final MapEntry(key: name, value: entries) in lists.entries) {
        testWidgets('with $name the rescan button is there and calls rescan', (
          tester,
        ) async {
          _window(tester, const Size(800, 600));
          final controller = FakeAppController(
            state: NodeState(entries: entries),
          );
          await pumpHome(tester, controller, code);

          expect(_stripOutlined, findsOneWidget);
          await tester.tap(_stripOutlined);
          await tester.pumpAndSettle();
          expect(controller.calls, ['rescan']);
        });
      }
    });

    group('[$code] E143 rescan while scanning', () {
      testWidgets('scanning disables the strip and empty-state buttons and '
          'shows searchingDevices', (tester) async {
        _window(tester, const Size(800, 600));
        final controller = FakeAppController(
          state: const NodeState(suggestRescan: true, scanning: true),
        );
        await pumpHome(tester, controller, code, settle: false);

        expect(find.text(strings.rescanHint), findsOneWidget);
        final buttons = find.ancestor(
          of: find.text(strings.rescanButton),
          matching: find.byWidgetPredicate((w) => w is ButtonStyleButton),
        );
        expect(buttons, findsNWidgets(2));
        for (final button in tester.widgetList<ButtonStyleButton>(buttons)) {
          expect(button.onPressed, isNull);
        }
        expect(_inStrip(find.text(strings.searchingDevices)), findsOneWidget);

        await tester.tap(find.text(strings.rescanButton).last);
        await tester.tap(find.text(strings.rescanButton).first);
        await tester.pump(const Duration(milliseconds: 100));
        expect(controller.calls, isEmpty);
      }, timeout: const Timeout(Duration(seconds: 30)));

      testWidgets('without scanning both buttons work and there is no '
          'searchingDevices', (tester) async {
        _window(tester, const Size(800, 600));
        final controller = FakeAppController(
          state: const NodeState(suggestRescan: true),
        );
        await pumpHome(tester, controller, code);

        final buttons = find.ancestor(
          of: find.text(strings.rescanButton),
          matching: find.byWidgetPredicate((w) => w is ButtonStyleButton),
        );
        expect(buttons, findsNWidgets(2));
        for (final button in tester.widgetList<ButtonStyleButton>(buttons)) {
          expect(button.onPressed, isNotNull);
        }
        expect(find.text(strings.searchingDevices), findsNothing);

        await tester.tap(find.text(strings.rescanButton).first);
        await tester.tap(find.text(strings.rescanButton).last);
        await tester.pumpAndSettle();
        expect(controller.calls, ['rescan', 'rescan']);
      });

      testWidgets('the buttons come back when scanning ends', (tester) async {
        _window(tester, const Size(800, 600));
        final controller = FakeAppController(
          state: const NodeState(suggestRescan: true, scanning: true),
        );
        await pumpHome(tester, controller, code, settle: false);

        controller.emit(const NodeState(suggestRescan: true));
        await tester.pumpAndSettle();

        final buttons = find.ancestor(
          of: find.text(strings.rescanButton),
          matching: find.byWidgetPredicate((w) => w is ButtonStyleButton),
        );
        for (final button in tester.widgetList<ButtonStyleButton>(buttons)) {
          expect(button.onPressed, isNotNull);
        }
        expect(find.text(strings.searchingDevices), findsNothing);
      }, timeout: const Timeout(Duration(seconds: 30)));
    });

    group('[$code] E266 tabs', () {
      testWidgets('without activity the column starts in Devices', (
        tester,
      ) async {
        _window(tester, const Size(800, 600));
        final controller = FakeAppController(
          state: NodeState(entries: _threeEntries),
        );
        await pumpHome(tester, controller, code);

        expect(_showsDevices(tester, strings), isTrue);
        expect(find.text('Movil'), findsOneWidget);
      });

      testWidgets('with lastSent at start, the first frame is in Activity', (
        tester,
      ) async {
        _window(tester, const Size(800, 600));
        final controller = FakeAppController(
          state: NodeState(entries: _threeEntries, lastSent: _sent),
        );
        await tester.pumpWidget(homeApp(controller, code));

        expect(_showsDevices(tester, strings), isFalse);
        expect(find.text('Movil'), findsNothing);
        await tester.pumpAndSettle();
        expect(_showsDevices(tester, strings), isFalse);
      });

      testWidgets('a state that arrives later picks the tab by its activity', (
        tester,
      ) async {
        _window(tester, const Size(800, 600));
        final controller = FakeAppController();
        await pumpHome(tester, controller, code);

        controller.emit(NodeState(entries: _threeEntries, lastSent: _sent));
        await tester.pumpAndSettle();
        expect(_showsDevices(tester, strings), isFalse);

        final quiet = FakeAppController();
        await tester.pumpWidget(const SizedBox());
        await pumpHome(tester, quiet, code);
        quiet.emit(NodeState(entries: _threeEntries));
        await tester.pumpAndSettle();
        expect(_showsDevices(tester, strings), isTrue);
      });

      testWidgets('tapping the tabs switches the content', (tester) async {
        _window(tester, const Size(800, 600));
        final controller = FakeAppController(
          state: NodeState(entries: _threeEntries),
        );
        await pumpHome(tester, controller, code);

        await tester.tap(find.text(strings.activityTab));
        await tester.pumpAndSettle();
        expect(_showsDevices(tester, strings), isFalse);
        expect(find.text('Movil'), findsNothing);

        await tester.tap(find.text(strings.devicesTab));
        await tester.pumpAndSettle();
        expect(_showsDevices(tester, strings), isTrue);
        expect(find.text('Movil'), findsOneWidget);
        expect(controller.calls, isEmpty);
      });

      testWidgets('a tapped tab stays while nothing new starts', (
        tester,
      ) async {
        _window(tester, const Size(800, 600));
        final controller = FakeAppController(
          state: NodeState(entries: _threeEntries, lastSent: _sent),
        );
        await pumpHome(tester, controller, code);
        expect(_showsDevices(tester, strings), isFalse);

        await tester.tap(find.text(strings.devicesTab));
        await tester.pumpAndSettle();
        controller.emit(
          NodeState(entries: _threeEntries, lastSent: _sent, scanning: true),
        );
        await _settle(tester);
        expect(_showsDevices(tester, strings), isTrue);
      }, timeout: const Timeout(Duration(seconds: 30)));

      testWidgets('a new outgoing moves Devices to Activity, and its progress '
          'does not move the user back', (tester) async {
        _window(tester, const Size(800, 600));
        final controller = FakeAppController(
          state: NodeState(entries: _threeEntries),
        );
        await pumpHome(tester, controller, code);
        expect(_showsDevices(tester, strings), isTrue);

        controller.emit(
          NodeState(entries: _threeEntries, outgoing: _out(_fpA)),
        );
        await _settle(tester);
        expect(_showsDevices(tester, strings), isFalse);

        await tester.tap(find.text(strings.devicesTab));
        await _settle(tester);
        controller.emit(
          NodeState(entries: _threeEntries, outgoing: _out(_fpA, sent: 600)),
        );
        await _settle(tester);
        expect(_showsDevices(tester, strings), isTrue);

        controller.emit(
          NodeState(entries: _threeEntries, outgoing: _out(_fpB)),
        );
        await _settle(tester);
        expect(_showsDevices(tester, strings), isFalse);
      }, timeout: const Timeout(Duration(seconds: 30)));

      testWidgets('an incoming that starts receiving moves to Activity', (
        tester,
      ) async {
        _window(tester, const Size(800, 600));
        final controller = FakeAppController(
          state: NodeState(entries: _threeEntries),
        );
        await pumpHome(tester, controller, code);

        IncomingTransferView incoming(IncomingStage stage) =>
            IncomingTransferView(
              sessionId: 's1',
              peerFingerprint: _fpA,
              peerName: 'PC principal',
              fileName: 'photo.jpg',
              size: 1000,
              isProgram: false,
              stage: stage,
            );

        controller.emit(
          NodeState(
            entries: _threeEntries,
            incoming: incoming(IncomingStage.warning),
          ),
        );
        await _settle(tester);
        expect(_showsDevices(tester, strings), isTrue);

        controller.emit(
          NodeState(
            entries: _threeEntries,
            incoming: incoming(IncomingStage.receiving),
          ),
        );
        await _settle(tester);
        expect(_showsDevices(tester, strings), isFalse);
      }, timeout: const Timeout(Duration(seconds: 30)));

      testWidgets('the Devices tab shows the number of paired devices', (
        tester,
      ) async {
        _window(tester, const Size(800, 600));
        final controller = FakeAppController(
          state: NodeState(entries: _threeEntries),
        );
        await pumpHome(tester, controller, code);

        final badge = find.descendant(
          of: _tab(strings.devicesTab),
          matching: find.text('2'),
        );
        expect(badge, findsOneWidget);
        expect(
          find.descendant(
            of: _tab(strings.activityTab),
            matching: find.text('2'),
          ),
          findsNothing,
        );
        expect(tester.getSize(badge.first).height, lessThanOrEqualTo(18));

        controller.emit(NodeState(entries: [_entry(_fpC, 'Movil')]));
        await tester.pumpAndSettle();
        expect(
          find.descendant(
            of: _tab(strings.devicesTab),
            matching: find.byType(Text),
          ),
          findsOneWidget,
        );
      });

      testWidgets('Activity without any activity shows activityEmpty', (
        tester,
      ) async {
        _window(tester, const Size(800, 600));
        final controller = FakeAppController(
          state: NodeState(entries: _threeEntries),
        );
        await pumpHome(tester, controller, code);

        await tester.tap(find.text(strings.activityTab));
        await tester.pumpAndSettle();

        expect(find.text(strings.activityEmpty), findsOneWidget);
        expect(
          tester.getTopLeft(find.text(strings.activityEmpty)).dy,
          greaterThan(tester.getBottomLeft(_tab(strings.activityTab)).dy),
        );
      });

      testWidgets('the column is notices, tabs and content, in that order', (
        tester,
      ) async {
        _window(tester, const Size(800, 1200));
        final controller = FakeAppController(
          state: NodeState(
            decisionNotSaved: true,
            identityStatus: IdentityStatus.reset,
            notices: const [Notice(id: 1, kind: NoticeKind.pairingPaused)],
            unsavedChanges: true,
            entries: _threeEntries,
          ),
        );
        await pumpHome(tester, controller, code);

        double top(Finder finder) => tester.getTopLeft(finder).dy;
        final order = [
          top(find.text(strings.decisionNotSaved)),
          top(find.text(strings.identityResetWarning)),
          top(find.text(strings.noticePairingPaused)),
          top(find.text(strings.noticeChangeNotSaved)),
          top(_tab(strings.devicesTab)),
          top(find.text('PC principal').last),
        ];
        for (var i = 1; i < order.length; i++) {
          expect(order[i], greaterThan(order[i - 1]), reason: 'block $i');
        }
        for (final text in [
          strings.decisionNotSaved,
          strings.identityResetWarning,
          strings.noticePairingPaused,
          strings.noticeChangeNotSaved,
        ]) {
          expect(
            find.ancestor(
              of: find.text(text),
              matching: find.byType(NoticeCard),
            ),
            findsOneWidget,
          );
          expect(
            find.descendant(of: _column, matching: find.text(text)),
            findsOneWidget,
          );
        }
      });

      testWidgets('the whole column is built and scrolls', (tester) async {
        _window(tester, const Size(800, 600));
        final controller = FakeAppController(
          state: NodeState(
            entries: [
              for (var i = 0; i < 40; i++)
                _entry(fingerprintOf('E$i'), 'Equipo $i'),
            ],
          ),
        );
        await pumpHome(tester, controller, code);

        final last = find.descendant(
          of: _column,
          matching: find.text('Equipo 39'),
        );
        expect(last, findsOneWidget);
        final before = tester.getTopLeft(last).dy;
        expect(before, greaterThan(600));
        await tester.drag(_column, const Offset(0, -400));
        await tester.pumpAndSettle();
        expect(tester.getTopLeft(last).dy, lessThan(before));
        expect(tester.getTopLeft(_strip).dy, lessThan(100));
      });
    });

    for (final brightness in Brightness.values) {
      group('[$code] ${brightness.name} tab colors', () {
        final colors = brightness == Brightness.dark
            ? NbColors.dark
            : NbColors.light;

        Future<void> mount(WidgetTester tester) async {
          _window(tester, const Size(800, 600));
          if (brightness == Brightness.dark) _dark(tester);
          await pumpHome(
            tester,
            FakeAppController(state: NodeState(entries: _threeEntries)),
            code,
          );
        }

        Color? textColor(WidgetTester tester, String label) =>
            tester.widget<Text>(find.text(label)).style?.color;

        Color? thumbColor(WidgetTester tester) =>
            (tester
                        .widget<DecoratedBox>(
                          find.descendant(
                            of: _thumb,
                            matching: find.byType(DecoratedBox),
                          ),
                        )
                        .decoration
                    as BoxDecoration)
                .color;

        Rect thumbRect(WidgetTester tester) => tester.getRect(
          find.descendant(of: _thumb, matching: find.byType(DecoratedBox)),
        );

        testWidgets('the card thumb sits under the active tab, whose text is '
            'text, and the other text is textWeak', (tester) async {
          await mount(tester);

          expect(thumbColor(tester), colors.card);
          expect(thumbRect(tester), tester.getRect(_tab(strings.devicesTab)));
          expect(textColor(tester, strings.devicesTab), colors.text);
          expect(textColor(tester, strings.activityTab), colors.textWeak);

          await tester.tap(find.text(strings.activityTab));
          await tester.pumpAndSettle();
          expect(thumbColor(tester), colors.card);
          expect(thumbRect(tester), tester.getRect(_tab(strings.activityTab)));
          expect(textColor(tester, strings.activityTab), colors.text);
          expect(textColor(tester, strings.devicesTab), colors.textWeak);
        });

        testWidgets('the thumb slides from one tab to the other in 380 ms', (
          tester,
        ) async {
          await mount(tester);
          final from = thumbRect(tester);
          final to = tester.getRect(_tab(strings.activityTab));

          await tester.tap(find.text(strings.activityTab));
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 60));
          final early = thumbRect(tester);
          expect(early.left, lessThan(from.left));
          expect(early.left, greaterThan(to.left));
          expect(early.width, from.width);

          await tester.pump(const Duration(milliseconds: 160));
          final middle = thumbRect(tester);
          expect(middle.left, lessThan(early.left));
          expect(middle.left, greaterThan(to.left));
          expect(
            textColor(tester, strings.activityTab),
            isNot(colors.textWeak),
          );

          await tester.pump(const Duration(milliseconds: 160));
          expect(thumbRect(tester), to);
          expect(textColor(tester, strings.activityTab), colors.text);
          expect(textColor(tester, strings.devicesTab), colors.textWeak);
        });

        testWidgets('the track leaves 4 px of air around the thumb, with '
            'concentric corners of 12 and 8', (tester) async {
          await mount(tester);

          final track = find.ancestor(
            of: _tab(strings.devicesTab),
            matching: find.byWidgetPredicate(
              (widget) =>
                  widget is DecoratedBox &&
                  widget.decoration is BoxDecoration &&
                  (widget.decoration as BoxDecoration).color == colors.segment,
            ),
          );
          final trackBox = tester.widget<DecoratedBox>(track);
          expect(
            (trackBox.decoration as BoxDecoration).borderRadius,
            BorderRadius.circular(12),
          );
          final thumbBox = tester.widget<DecoratedBox>(
            find.descendant(of: _thumb, matching: find.byType(DecoratedBox)),
          );
          expect(
            (thumbBox.decoration as BoxDecoration).borderRadius,
            BorderRadius.circular(8),
          );
          final outer = tester.getRect(track);
          final thumb = thumbRect(tester);
          expect(thumb.top - outer.top, 4);
          expect(outer.bottom - thumb.bottom, 4);
          expect(outer.right - thumb.right, 4);
          expect(thumb.height, 32);

          await tester.tap(find.text(strings.activityTab));
          await tester.pumpAndSettle();
          expect(thumbRect(tester).left - outer.left, 4);
        });

        testWidgets('with reduced motion the thumb jumps without sliding', (
          tester,
        ) async {
          tester.platformDispatcher.accessibilityFeaturesTestValue =
              const FakeAccessibilityFeatures(disableAnimations: true);
          addTearDown(
            tester.platformDispatcher.clearAccessibilityFeaturesTestValue,
          );
          await mount(tester);

          await tester.tap(find.text(strings.activityTab));
          await tester.pump();
          await tester.pump();
          expect(thumbRect(tester), tester.getRect(_tab(strings.activityTab)));
        });

        testWidgets('the tabs sit on segment and the badge uses '
            'primaryInk on primaryWeak', (tester) async {
          await mount(tester);

          final track = find.ancestor(
            of: _tab(strings.devicesTab),
            matching: find.byWidgetPredicate(
              (widget) =>
                  widget is DecoratedBox &&
                  widget.decoration is BoxDecoration &&
                  (widget.decoration as BoxDecoration).color == colors.segment,
            ),
          );
          expect(track, findsOneWidget);
          expect(
            find.descendant(of: track, matching: _tab(strings.activityTab)),
            findsOneWidget,
          );
          expect(textColor(tester, '2'), colors.primaryInk);
          final badge = tester.widget<Container>(
            find
                .ancestor(of: find.text('2'), matching: find.byType(Container))
                .first,
          );
          expect((badge.decoration as BoxDecoration).color, colors.primaryWeak);
          expect(find.text(strings.activityEmpty), findsNothing);
        });

        testWidgets('hovering the inactive tab keeps its colors and paints no '
            'highlight', (tester) async {
          await mount(tester);
          final before = thumbRect(tester);

          final mouse = await tester.createGesture(
            kind: PointerDeviceKind.mouse,
          );
          addTearDown(mouse.removePointer);
          await mouse.addPointer(location: Offset.zero);
          await mouse.moveTo(tester.getCenter(find.text(strings.activityTab)));
          await tester.pumpAndSettle();

          expect(textColor(tester, strings.activityTab), colors.textWeak);
          expect(thumbRect(tester), before);
          final zone = tester.widget<InkWell>(_tab(strings.activityTab));
          expect(zone.hoverColor, Colors.transparent);
          expect(zone.highlightColor, Colors.transparent);
          expect(zone.splashFactory, NoSplash.splashFactory);
        });

        testWidgets('the inactive tab shows the click cursor and the active '
            'one the basic cursor', (tester) async {
          await mount(tester);

          expect(
            tester.widget<InkWell>(_tab(strings.activityTab)).mouseCursor,
            SystemMouseCursors.click,
          );
          expect(
            tester.widget<InkWell>(_tab(strings.devicesTab)).mouseCursor,
            SystemMouseCursors.basic,
          );
        });
      });
    }
  }

  testWidgets('every tab text comes from AppStrings and differs between '
      'languages', (tester) async {
    final rendered = <String, Set<String>>{};
    for (final code in languageCodes) {
      final controller = FakeAppController(
        state: NodeState(entries: _threeEntries, activeNetworks: const [_home]),
      );
      _window(tester, const Size(1180, 720));
      await pumpHome(tester, controller, code);
      final strings = stringsFor(code);
      final texts = visibleTexts(tester).toSet();
      expect(
        texts,
        containsAll([
          strings.devicesTab,
          strings.activityTab,
          strings.trustedNetworkLabel,
          strings.onlyPairedCanSend,
          strings.rescanButton,
        ]),
      );
      expect(texts, isNot(contains(brandName)));
      expect(texts, isNot(contains('2')));
      rendered[code] = {
        strings.devicesTab,
        strings.activityTab,
        strings.trustedNetworkLabel,
        strings.onlyPairedCanSend,
        strings.activityEmpty,
      };
      await tester.pumpWidget(const SizedBox());
    }
    expect(rendered['es']!.intersection(rendered['en']!), isEmpty);
  });
}
