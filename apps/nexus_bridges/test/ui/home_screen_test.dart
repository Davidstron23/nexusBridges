import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nexus_bridges/src/l10n/app_strings.dart';
import 'package:nexus_bridges/src/ui/brand/brand_mark.dart';
import 'package:nexus_bridges/src/ui/device_list.dart';
import 'package:nexus_bridges/src/ui/icons/device_disc.dart';
import 'package:nexus_bridges/src/ui/modal/modal_frame.dart';
import 'package:nexus_bridges_core/nexus_bridges_core.dart';

import 'fake_app_controller.dart';

const _home = NetworkPrompt('net-home', 'Casa');
const _office = NetworkPrompt('net-office', 'Oficina');

Finder _rowOf(String name) =>
    find.ancestor(of: find.text(name), matching: find.byType(DeviceRow));

List<String> _tileTexts(WidgetTester tester, String name) {
  final row = _rowOf(name);
  expect(row, findsOneWidget);
  return [
    for (final text in tester.widgetList<Text>(
      find.descendant(of: row, matching: find.byType(Text)),
    ))
      text.data ?? '',
  ];
}

Finder _discIn(String name) =>
    find.descendant(of: _rowOf(name), matching: find.byType(DeviceDisc));

DeviceEntry _entryWith({
  required String fingerprint,
  required String name,
  DeviceType type = DeviceType.desktop,
  bool paired = false,
  bool mine = false,
}) {
  return DeviceEntry(
    fingerprint: fingerprint,
    displayName: name,
    deviceType: type,
    visible: true,
    paired: paired,
    mine: mine,
    ignored: false,
    mismatch: false,
    possiblyReplaces: null,
  );
}

Set<String> _allowedTexts(
  AppStrings strings, {
  List<String> networks = const [],
  List<int> ports = const [],
}) {
  return {
    strings.activityTab,
    strings.devicesTab,
    strings.trustedNetworkLabel,
    strings.onlyPairedCanSend,
    strings.devicesTitle,
    strings.noDevicesYet,
    strings.rescanHint,
    strings.rescanButton,
    strings.pausedBanner,
    strings.sectionUnpaired,
    strings.chipMine,
    strings.visibleLabel,
    strings.sendFilesOrFolders,
    for (final network in networks) strings.trustNetworkButton(network),
    strings.networkPromptTitle,
    for (final network in networks) strings.networkPromptBody(network),
    strings.yes,
    strings.no,
    strings.pairedMineLabel,
    strings.notPairedLabel,
    strings.pairButton,
    strings.deviceTypeDesktop,
    strings.deviceTypeMobile,
    strings.identityResetWarning,
    strings.identityFailed,
    for (final port in ports) strings.portInUse(port),
    strings.retryButton,
    strings.decisionNotSaved,
    strings.closeButton,
  };
}

void main() {
  for (final code in languageCodes) {
    final strings = stringsFor(code);

    group('[$code] title (point 153)', () {
      testWidgets('no screen paints the mark nor appTitle, which the native '
          'title bar already shows', (tester) async {
        final controller = FakeAppController();
        await pumpHome(tester, controller, code);
        expect(find.text(strings.identityFailed), findsOneWidget);
        expect(find.text(strings.appTitle), findsNothing);
        expect(find.byType(BrandMark), findsNothing);

        controller.emit(const NodeState(portInUse: 53530));
        await tester.pumpAndSettle();
        expect(find.text(strings.portInUse(53530)), findsOneWidget);
        expect(find.text(strings.appTitle), findsNothing);
        expect(find.byType(BrandMark), findsNothing);

        controller.emit(const NodeState());
        await tester.pumpAndSettle();
        expect(find.text(strings.noDevicesYet), findsOneWidget);
        expect(find.text(strings.appTitle), findsNothing);
        expect(find.byType(BrandMark), findsNothing);
      });
    });

    group('[$code] RF-8 identity failure', () {
      testWidgets('a null state shows identityFailed and retryButton', (
        tester,
      ) async {
        final controller = FakeAppController();
        await pumpHome(tester, controller, code);

        expect(find.text(strings.identityFailed), findsOneWidget);
        expect(find.text(strings.retryButton), findsOneWidget);
        expect(find.text(strings.noDevicesYet), findsNothing);
        expect(find.byType(ListView), findsNothing);
      });

      testWidgets(
        'identityStatus failed shows identityFailed and retryButton',
        (tester) async {
          final controller = FakeAppController(
            state: const NodeState(identityStatus: IdentityStatus.failed),
          );
          await pumpHome(tester, controller, code);

          expect(find.text(strings.identityFailed), findsOneWidget);
          expect(find.text(strings.retryButton), findsOneWidget);
          expect(find.text(strings.noDevicesYet), findsNothing);
        },
      );

      testWidgets('startFailed shows identityFailed even with a state', (
        tester,
      ) async {
        final controller = FakeAppController(
          state: const NodeState(),
          startFailed: true,
        );
        await pumpHome(tester, controller, code);

        expect(find.text(strings.identityFailed), findsOneWidget);
        expect(find.text(strings.retryButton), findsOneWidget);
        expect(find.text(strings.noDevicesYet), findsNothing);
      });

      testWidgets('retryButton calls retry once', (tester) async {
        final controller = FakeAppController(
          state: const NodeState(identityStatus: IdentityStatus.failed),
        );
        await pumpHome(tester, controller, code);

        await tester.tap(find.text(strings.retryButton));
        await tester.pumpAndSettle();

        expect(controller.calls, ['retry']);
      });

      testWidgets('the failure screen hides everything else', (tester) async {
        final controller = FakeAppController(
          state: NodeState(
            identityStatus: IdentityStatus.failed,
            portInUse: 53530,
            paused: true,
            pausedNetworks: const [_home],
            decisionNotSaved: true,
            suggestRescan: true,
            entries: [_entryWith(fingerprint: fingerprintOf('A1'), name: 'PC')],
          ),
        );
        await pumpHome(tester, controller, code);

        expect(find.text(strings.identityFailed), findsOneWidget);
        expect(find.text(strings.portInUse(53530)), findsNothing);
        expect(find.text(strings.pausedBanner), findsNothing);
        expect(find.text(strings.decisionNotSaved), findsNothing);
        expect(find.text(strings.rescanHint), findsNothing);
        expect(find.text('PC'), findsNothing);
      });

      testWidgets('a later healthy state replaces the failure screen', (
        tester,
      ) async {
        final controller = FakeAppController();
        await pumpHome(tester, controller, code);
        expect(find.text(strings.identityFailed), findsOneWidget);

        controller.emit(const NodeState());
        await tester.pumpAndSettle();

        expect(find.text(strings.identityFailed), findsNothing);
        expect(find.text(strings.noDevicesYet), findsOneWidget);
      });
    });

    group('[$code] RF-38 port in use', () {
      testWidgets('shows the port number and retryButton', (tester) async {
        final controller = FakeAppController(
          state: const NodeState(portInUse: 53530),
        );
        await pumpHome(tester, controller, code);

        expect(find.text(strings.portInUse(53530)), findsOneWidget);
        expect(find.textContaining('53530'), findsOneWidget);
        expect(find.text(strings.retryButton), findsOneWidget);
        expect(find.text(strings.identityFailed), findsNothing);
      });

      testWidgets('retryButton calls retry', (tester) async {
        final controller = FakeAppController(
          state: const NodeState(portInUse: 53530),
        );
        await pumpHome(tester, controller, code);

        await tester.tap(find.text(strings.retryButton));
        await tester.pumpAndSettle();

        expect(controller.calls, ['retry']);
      });

      testWidgets('the port screen hides banners and the list', (tester) async {
        final controller = FakeAppController(
          state: NodeState(
            portInUse: 53530,
            paused: true,
            pausedNetworks: const [_home],
            decisionNotSaved: true,
            identityStatus: IdentityStatus.reset,
            entries: [_entryWith(fingerprint: fingerprintOf('A1'), name: 'PC')],
          ),
        );
        await pumpHome(tester, controller, code);

        expect(find.text(strings.portInUse(53530)), findsOneWidget);
        expect(find.text(strings.pausedBanner), findsNothing);
        expect(find.text(strings.decisionNotSaved), findsNothing);
        expect(find.text(strings.identityResetWarning), findsNothing);
        expect(find.text('PC'), findsNothing);
      });

      testWidgets('the screen goes back to the list when the port is free', (
        tester,
      ) async {
        final controller = FakeAppController(
          state: const NodeState(portInUse: 53530),
        );
        await pumpHome(tester, controller, code);

        controller.emit(const NodeState());
        await tester.pumpAndSettle();

        expect(find.text(strings.portInUse(53530)), findsNothing);
        expect(find.text(strings.retryButton), findsNothing);
        expect(find.text(strings.noDevicesYet), findsOneWidget);
      });
    });

    group('[$code] RF-7 new identity', () {
      testWidgets('reset shows the warning with closeButton', (tester) async {
        final controller = FakeAppController(
          state: const NodeState(identityStatus: IdentityStatus.reset),
        );
        await pumpHome(tester, controller, code);

        expect(find.text(strings.identityResetWarning), findsOneWidget);
        expect(find.text(strings.closeButton), findsOneWidget);
      });

      testWidgets('closeButton dismisses the warning for the session', (
        tester,
      ) async {
        final controller = FakeAppController(
          state: const NodeState(identityStatus: IdentityStatus.reset),
        );
        await pumpHome(tester, controller, code);

        await tester.tap(find.text(strings.closeButton));
        await tester.pumpAndSettle();

        expect(controller.calls, ['dismissIdentityWarning']);
        expect(controller.identityWarningDismissed, isTrue);
        expect(find.text(strings.identityResetWarning), findsNothing);
        expect(find.text(strings.closeButton), findsNothing);

        controller.emit(const NodeState(identityStatus: IdentityStatus.reset));
        await tester.pumpAndSettle();
        expect(find.text(strings.identityResetWarning), findsNothing);
      });

      testWidgets('identityStatus ok shows no warning', (tester) async {
        final controller = FakeAppController(state: const NodeState());
        await pumpHome(tester, controller, code);

        expect(find.text(strings.identityResetWarning), findsNothing);
        expect(find.text(strings.closeButton), findsNothing);
      });
    });

    group('[$code] RF-14 decision not saved', () {
      testWidgets('decisionNotSaved shows the warning', (tester) async {
        final controller = FakeAppController(
          state: const NodeState(decisionNotSaved: true),
        );
        await pumpHome(tester, controller, code);

        expect(find.text(strings.decisionNotSaved), findsOneWidget);
      });

      testWidgets('the warning goes away when the flag clears', (tester) async {
        final controller = FakeAppController(
          state: const NodeState(decisionNotSaved: true),
        );
        await pumpHome(tester, controller, code);

        controller.emit(const NodeState());
        await tester.pumpAndSettle();

        expect(find.text(strings.decisionNotSaved), findsNothing);
      });
    });

    group('[$code] RF-19 paused', () {
      testWidgets('two paused networks show the banner and two buttons', (
        tester,
      ) async {
        final controller = FakeAppController(
          state: const NodeState(
            paused: true,
            pausedNetworks: [_home, _office],
          ),
        );
        await pumpHome(tester, controller, code);

        expect(find.text(strings.pausedBanner), findsOneWidget);
        expect(find.text(strings.trustNetworkButton('Casa')), findsOneWidget);
        expect(
          find.text(strings.trustNetworkButton('Oficina')),
          findsOneWidget,
        );
        expect(find.byType(TextButton), findsNWidgets(2));
      });

      testWidgets('each button asks again for its own network only', (
        tester,
      ) async {
        final controller = FakeAppController(
          state: const NodeState(
            paused: true,
            pausedNetworks: [_home, _office],
          ),
        );
        await pumpHome(tester, controller, code);

        await tester.tap(find.text(strings.trustNetworkButton('Oficina')));
        await tester.pumpAndSettle();
        expect(controller.calls, ['askAgain net-office']);

        await tester.tap(find.text(strings.trustNetworkButton('Casa')));
        await tester.pumpAndSettle();
        expect(controller.calls, ['askAgain net-office', 'askAgain net-home']);
        expect(
          controller.calls.where((call) => call.startsWith('decideNetwork')),
          isEmpty,
        );
        expect(find.byType(NbModal), findsNothing);
      });

      testWidgets('not paused shows no banner', (tester) async {
        final controller = FakeAppController(state: const NodeState());
        await pumpHome(tester, controller, code);

        expect(find.text(strings.pausedBanner), findsNothing);
      });

      testWidgets('paused, unsaved choice and new identity stack together', (
        tester,
      ) async {
        final controller = FakeAppController(
          state: const NodeState(
            paused: true,
            pausedNetworks: [_home],
            decisionNotSaved: true,
            identityStatus: IdentityStatus.reset,
          ),
        );
        await pumpHome(tester, controller, code);

        expect(find.text(strings.pausedBanner), findsOneWidget);
        expect(find.text(strings.decisionNotSaved), findsOneWidget);
        expect(find.text(strings.identityResetWarning), findsOneWidget);
        expect(find.text(strings.noDevicesYet), findsOneWidget);
        final banner = tester.getTopLeft(find.text(strings.pausedBanner)).dy;
        final notSaved = tester
            .getTopLeft(find.text(strings.decisionNotSaved))
            .dy;
        final reset = tester
            .getTopLeft(find.text(strings.identityResetWarning))
            .dy;
        final empty = tester.getTopLeft(find.text(strings.noDevicesYet)).dy;
        expect(banner, lessThan(notSaved));
        expect(notSaved, lessThan(reset));
        expect(reset, lessThan(empty));
      });
    });

    group('[$code] RF-49 and RF-50 device list', () {
      testWidgets('a paired desktop and an unpaired mobile show their data', (
        tester,
      ) async {
        final desktop = fingerprintOf('A1B2');
        final mobile = fingerprintOf('C3D4');
        final controller = FakeAppController(
          state: NodeState(
            entries: [
              _entryWith(
                fingerprint: desktop,
                name: 'PC principal',
                paired: true,
                mine: true,
              ),
              _entryWith(
                fingerprint: mobile,
                name: 'Movil',
                type: DeviceType.mobile,
              ),
            ],
          ),
        );
        await pumpHome(tester, controller, code);

        expect(
          _tileTexts(tester, 'PC principal'),
          unorderedEquals([
            'PC principal',
            strings.chipMine,
            strings.visibleLabel,
            strings.sendFilesOrFolders,
          ]),
        );
        expect(
          _tileTexts(tester, 'Movil'),
          unorderedEquals([
            'Movil',
            strings.notPairedLabel,
            strings.visibleLabel,
            strings.pairButton,
          ]),
        );
        expect(
          tester.widget<DeviceDisc>(_discIn('PC principal')).glyph,
          DeviceGlyph.pc,
        );
        expect(
          tester.widget<DeviceDisc>(_discIn('Movil')).glyph,
          DeviceGlyph.phone,
        );
        final semantics = tester.ensureSemantics();
        expect(
          tester.getSemantics(_discIn('PC principal')).label,
          strings.deviceTypeDesktop,
        );
        expect(
          tester.getSemantics(_discIn('Movil')).label,
          strings.deviceTypeMobile,
        );
        semantics.dispose();
        expect(find.text(strings.noDevicesYet), findsNothing);
        expect(find.text(strings.rescanHint), findsNothing);
      });

      testWidgets(
        'repeated names show the short fingerprint from displayNames',
        (tester) async {
          final first = fingerprintOf('A1B2C3D4');
          final second = fingerprintOf('9F8E7D6C');
          final controller = FakeAppController(
            state: NodeState(
              entries: [
                _entryWith(fingerprint: first, name: 'Laptop \u00B7 A1B2C3D4'),
                _entryWith(
                  fingerprint: second,
                  name: 'Laptop \u00B7 9F8E7D6C',
                  paired: true,
                  mine: true,
                ),
              ],
            ),
          );
          await pumpHome(tester, controller, code);

          expect(find.text('Laptop'), findsNothing);
          expect(
            _tileTexts(tester, 'Laptop \u00B7 A1B2C3D4'),
            contains(strings.notPairedLabel),
          );
          expect(
            _tileTexts(tester, 'Laptop \u00B7 9F8E7D6C'),
            contains(strings.chipMine),
          );
        },
      );

      testWidgets('an entry named by its short fingerprint shows that name', (
        tester,
      ) async {
        final fingerprint = fingerprintOf('0A1B2C3D4E');
        final controller = FakeAppController(
          state: NodeState(
            entries: [_entryWith(fingerprint: fingerprint, name: '0A1B2C3D')],
          ),
        );
        await pumpHome(tester, controller, code);

        expect(find.text('0A1B2C3D'), findsOneWidget);
      });

      testWidgets('the list follows new states', (tester) async {
        final fingerprint = fingerprintOf('A1');
        final controller = FakeAppController(state: const NodeState());
        await pumpHome(tester, controller, code);
        expect(find.text(strings.noDevicesYet), findsOneWidget);

        controller.emit(
          NodeState(
            entries: [_entryWith(fingerprint: fingerprint, name: 'PC')],
          ),
        );
        await tester.pumpAndSettle();
        expect(find.text('PC'), findsOneWidget);
        expect(find.text(strings.noDevicesYet), findsNothing);

        controller.emit(const NodeState());
        await tester.pumpAndSettle();
        expect(find.text('PC'), findsNothing);
        expect(find.text(strings.noDevicesYet), findsOneWidget);
      });
    });

    group('[$code] RF-55 empty list', () {
      testWidgets('suggestRescan shows the hint and the button', (
        tester,
      ) async {
        final controller = FakeAppController(
          state: const NodeState(suggestRescan: true),
        );
        await pumpHome(tester, controller, code);

        expect(find.text(strings.rescanHint), findsOneWidget);
        expect(find.text(strings.rescanButton), findsNWidgets(2));
        expect(find.text(strings.noDevicesYet), findsNothing);
      });

      testWidgets('rescanButton calls rescan', (tester) async {
        final controller = FakeAppController(
          state: const NodeState(suggestRescan: true),
        );
        await pumpHome(tester, controller, code);

        await tester.tap(find.text(strings.rescanButton).last);
        await tester.pumpAndSettle();

        expect(controller.calls, ['rescan']);
      });

      testWidgets('without the hint shows noDevicesYet only', (tester) async {
        final controller = FakeAppController(state: const NodeState());
        await pumpHome(tester, controller, code);

        expect(find.text(strings.noDevicesYet), findsOneWidget);
        expect(find.text(strings.rescanHint), findsNothing);
        expect(find.text(strings.rescanButton), findsOneWidget);
      });

      testWidgets('a non-empty list never shows the hint', (tester) async {
        final fingerprint = fingerprintOf('A1');
        final controller = FakeAppController(
          state: NodeState(
            suggestRescan: true,
            entries: [_entryWith(fingerprint: fingerprint, name: 'PC')],
          ),
        );
        await pumpHome(tester, controller, code);

        expect(find.text('PC'), findsOneWidget);
        expect(find.text(strings.rescanHint), findsNothing);
        expect(find.text(strings.rescanButton), findsOneWidget);
        expect(find.text(strings.noDevicesYet), findsNothing);
      });
    });
  }

  group('RF-62 rendered texts', () {
    final fingerprint = fingerprintOf('A1');
    final scenarios = <String, (NodeState?, bool)>{
      'no state': (null, false),
      'start failed': (const NodeState(), true),
      'identity failed': (
        const NodeState(identityStatus: IdentityStatus.failed),
        false,
      ),
      'port in use': (const NodeState(portInUse: 53530), false),
      'every notice and the hint': (
        const NodeState(
          paused: true,
          pausedNetworks: [_home, _office],
          decisionNotSaved: true,
          identityStatus: IdentityStatus.reset,
          suggestRescan: true,
        ),
        false,
      ),
      'empty list': (const NodeState(), false),
      'devices': (
        NodeState(
          entries: [
            _entryWith(
              fingerprint: fingerprint,
              name: 'PC',
              paired: true,
              mine: true,
            ),
            _entryWith(
              fingerprint: fingerprintOf('B2'),
              name: 'Movil',
              type: DeviceType.mobile,
            ),
          ],
        ),
        false,
      ),
    };
    const userTexts = {'PC', 'Movil'};

    for (final MapEntry(key: name, value: (state, startFailed))
        in scenarios.entries) {
      testWidgets('$name: every text comes from AppStrings and differs', (
        tester,
      ) async {
        final rendered = <String, List<String>>{};
        for (final code in languageCodes) {
          final controller = FakeAppController(
            state: state,
            startFailed: startFailed,
          );
          await pumpHome(tester, controller, code);
          final texts = visibleTexts(tester);
          expect(texts, isNotEmpty);
          expect(texts.where((text) => text.trim().isEmpty), isEmpty);
          final allowed = _allowedTexts(
            stringsFor(code),
            networks: const ['Casa', 'Oficina'],
            ports: const [53530],
          );
          expect(
            texts.where(
              (text) => !allowed.contains(text) && !userTexts.contains(text),
            ),
            isEmpty,
            reason: 'texts not taken from AppStrings in $code',
          );
          rendered[code] = texts
              .where((text) => !userTexts.contains(text))
              .toList();
          await tester.pumpWidget(const SizedBox());
        }
        expect(rendered['es']!.length, rendered['en']!.length);
        expect(
          rendered['es']!.toSet().intersection(rendered['en']!.toSet()),
          isEmpty,
        );
      });
    }
  });
}
