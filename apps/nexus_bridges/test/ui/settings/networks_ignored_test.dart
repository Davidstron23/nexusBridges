import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nexus_bridges/src/l10n/app_strings.dart';
import 'package:nexus_bridges/src/ui/format.dart';
import 'package:nexus_bridges/src/ui/theme/components.dart';
import 'package:nexus_bridges_core/nexus_bridges_core.dart';

import '../fake_app_controller.dart';
import '../pairing_fixtures.dart' show buttonLabelsIn;
import '../segoe_font.dart';
import '../transfer_fixtures.dart' show incomingView;
import 'settings_fixtures.dart';

final String _fpOld = fingerprintOf('CDEF9876');
final String _fpNew = fingerprintOf('1234ABCD');

Finder _row(String id) => find.byKey(ValueKey('network-$id'));

Finder _stop(String id, AppStrings s) => find.descendant(
  of: _row(id),
  matching: find.ancestor(
    of: find.text(s.stopUsingButton),
    matching: find.byWidgetPredicate((widget) => widget is ButtonStyleButton),
  ),
);

Finder _inRow(String id, Finder matching) =>
    find.descendant(of: _row(id), matching: matching);

String _date(DateTime at, String code) =>
    formatShortDate(at, code, stringsFor(code));

Finder _noticeCard(String message) =>
    find.ancestor(of: find.text(message), matching: find.byType(Card)).first;

String _confirmText(WidgetTester tester, String id) => [
  for (final text in tester.widgetList<Text>(_inRow(id, find.byType(Text))))
    text.data ?? text.textSpan?.toPlainText() ?? '',
].join('\n');

void main() {
  setUpAll(loadSegoe);

  for (final code in languageCodes) {
    final strings = stringsFor(code);

    group('[$code] E871 trusted networks (RF-531)', () {
      testWidgets('rows in the order of the state, the "connected now" chip, '
          'the date and "unnamed network"', (tester) async {
        await pumpSettings(
          tester,
          code,
          state: settingsState(
            networks: [
              networkView(),
              networkView(
                id: officeNetwork,
                name: null,
                trustedAt: officeTrusted,
                connected: false,
              ),
            ],
          ),
        );
        expect(
          inSection(strings.sectionNetworks, find.text(strings.networksInfo)),
          findsOneWidget,
        );
        final home = tester.getTopLeft(_row(homeNetwork)).dy;
        final office = tester.getTopLeft(_row(officeNetwork)).dy;
        expect(home, lessThan(office));
        expect(_inRow(homeNetwork, find.text('Casa')), findsOneWidget);
        expect(
          _inRow(homeNetwork, find.text(strings.connectedNow)),
          findsOneWidget,
        );
        expect(_inRow(homeNetwork, find.byType(StatusChip)), findsOneWidget);
        expect(
          _inRow(
            homeNetwork,
            find.text(strings.trustedOn(_date(homeTrusted, code))),
          ),
          findsOneWidget,
        );
        expect(
          _inRow(officeNetwork, find.text(strings.unnamedNetwork)),
          findsOneWidget,
        );
        expect(
          _inRow(officeNetwork, find.text(strings.connectedNow)),
          findsNothing,
        );
        expect(
          _inRow(
            officeNetwork,
            find.text(strings.trustedOn(_date(officeTrusted, code))),
          ),
          findsOneWidget,
        );
      });

      testWidgets('the dates follow the format of the language', (
        tester,
      ) async {
        await pumpSettings(tester, code);
        final expected = code == 'es' ? '30/10/2026' : 'Oct 30, 2026';
        expect(find.text(strings.trustedOn(expected)), findsOneWidget);
      });

      testWidgets('no networks: the empty text', (tester) async {
        await pumpSettings(tester, code, state: settingsState(networks: []));
        expect(
          inSection(strings.sectionNetworks, find.text(strings.networksEmpty)),
          findsOneWidget,
        );
      });

      testWidgets('the list follows the state: a network that leaves goes '
          'away and a new one comes in', (tester) async {
        final (controller, _) = await pumpSettings(tester, code);
        controller.emit(
          settingsState(
            networks: [
              networkView(id: officeNetwork, name: 'Oficina', connected: false),
            ],
          ),
        );
        await tester.pumpAndSettle();
        expect(_row(homeNetwork), findsNothing);
        expect(_inRow(officeNetwork, find.text('Oficina')), findsOneWidget);
      });
    });

    group('[$code] E872 stop using a network (RF-532, RF-533)', () {
      testWidgets('not connected: stopUsingNetwork at once, without '
          'confirmation', (tester) async {
        final (controller, _) = await pumpSettings(
          tester,
          code,
          state: settingsState(networks: [networkView(connected: false)]),
        );
        await tester.tap(_stop(homeNetwork, strings));
        await tester.pumpAndSettle();
        expect(controller.calls, ['stopUsingNetwork $homeNetwork']);
        expect(confirmOpen(tester, strings.sectionNetworks), isFalse);
      });

      for (final (transfers, pairing) in [
        (0, false),
        (1, false),
        (3, false),
        (0, true),
        (3, true),
      ]) {
        testWidgets('connected with $transfers transfers and pairing '
            '$pairing: the danger confirmation with its texts', (tester) async {
          final (controller, _) = await pumpSettings(
            tester,
            code,
            state: settingsState(
              networks: [networkView(transfers: transfers, pairing: pairing)],
            ),
          );
          await tester.tap(_stop(homeNetwork, strings));
          await tester.pumpAndSettle();
          expect(controller.calls, isEmpty);
          expect(confirmOpen(tester, strings.sectionNetworks), isTrue);
          final text = _confirmText(tester, homeNetwork);
          expect(text, contains(strings.stopUsingConfirm('Casa')));
          if (transfers > 0) {
            expect(text, contains(strings.transfersStopped(transfers)));
          } else {
            expect(text, isNot(contains(strings.transfersStopped(1))));
            expect(text, isNot(contains(strings.transfersStopped(3))));
          }
          expect(text.contains(strings.pairingCancelled), pairing);
        });
      }

      testWidgets('the counts follow the state while it is open', (
        tester,
      ) async {
        final (controller, _) = await pumpSettings(tester, code);
        await tester.tap(_stop(homeNetwork, strings));
        await tester.pumpAndSettle();
        expect(
          _confirmText(tester, homeNetwork),
          isNot(contains(strings.pairingCancelled)),
        );

        controller.emit(
          settingsState(networks: [networkView(transfers: 2, pairing: true)]),
        );
        await tester.pumpAndSettle();
        final text = _confirmText(tester, homeNetwork);
        expect(text, contains(strings.transfersStopped(2)));
        expect(text, contains(strings.pairingCancelled));
        expect(confirmOpen(tester, strings.sectionNetworks), isTrue);

        controller.emit(settingsState(networks: [networkView()]));
        await tester.pumpAndSettle();
        expect(
          _confirmText(tester, homeNetwork),
          isNot(contains(strings.pairingCancelled)),
        );
      });

      testWidgets('Cancel does not call; Esc cancels without closing '
          'Settings; confirming calls stopUsingNetwork', (tester) async {
        final (controller, settings) = await pumpSettings(tester, code);
        await tester.tap(_stop(homeNetwork, strings));
        await tester.pumpAndSettle();
        await tester.tap(
          confirmButton(strings.sectionNetworks, strings.cancelButton),
        );
        await tester.pumpAndSettle();
        expect(confirmOpen(tester, strings.sectionNetworks), isFalse);

        await tester.tap(_stop(homeNetwork, strings));
        await tester.pumpAndSettle();
        await pressEscape(tester);
        expect(confirmOpen(tester, strings.sectionNetworks), isFalse);
        expect(settings.isOpen, isTrue);
        expect(controller.calls, isEmpty);

        await tester.tap(_stop(homeNetwork, strings));
        await tester.pumpAndSettle();
        await tester.tap(
          confirmButton(
            strings.sectionNetworks,
            strings.stopUsingConfirmButton,
          ),
        );
        await tester.pumpAndSettle();
        expect(controller.calls, ['stopUsingNetwork $homeNetwork']);
        expect(confirmOpen(tester, strings.sectionNetworks), isFalse);
        expect(settings.isOpen, isTrue);
      });

      testWidgets('pressing the button again with it open closes it without '
          'calling', (tester) async {
        final (controller, _) = await pumpSettings(tester, code);
        await tester.tap(_stop(homeNetwork, strings));
        await tester.pumpAndSettle();
        await tester.tap(_stop(homeNetwork, strings));
        await tester.pumpAndSettle();
        expect(confirmOpen(tester, strings.sectionNetworks), isFalse);
        expect(controller.calls, isEmpty);
      });

      testWidgets('the network stops being connected with it open: it closes '
          'without calling and Esc then closes Settings', (tester) async {
        final (controller, settings) = await pumpSettings(tester, code);
        await tester.tap(_stop(homeNetwork, strings));
        await tester.pumpAndSettle();

        controller.emit(
          settingsState(networks: [networkView(connected: false)]),
        );
        await tester.pumpAndSettle();
        expect(confirmOpen(tester, strings.sectionNetworks), isFalse);
        expect(controller.calls, isEmpty);

        controller.emit(settingsState(networks: [networkView()]));
        await tester.pumpAndSettle();
        expect(confirmOpen(tester, strings.sectionNetworks), isFalse);

        await pressEscape(tester);
        expect(settings.isOpen, isFalse);
        expect(controller.calls, isEmpty);
      });

      testWidgets('the network leaves the list with it open: it closes '
          'without calling', (tester) async {
        final (controller, settings) = await pumpSettings(tester, code);
        await tester.tap(_stop(homeNetwork, strings));
        await tester.pumpAndSettle();
        controller.emit(settingsState(networks: []));
        await tester.pumpAndSettle();
        expect(controller.calls, isEmpty);
        expect(confirmScopeOf(tester).value, isNull);
        await pressEscape(tester);
        expect(settings.isOpen, isFalse);
      });
    });

    group('[$code] E873 stopping could not be saved (RF-535)', () {
      testWidgets('the notice names the network and Retry calls retrySave', (
        tester,
      ) async {
        final (controller, _) = await pumpSettings(
          tester,
          code,
          open: false,
          size: const Size(1200, 800),
          state: settingsState(
            notices: const [
              Notice(
                id: 9,
                kind: NoticeKind.networkStopNotSaved,
                detail: 'Casa',
              ),
            ],
          ),
        );
        final message = strings.noticeNetworkStopNotSaved('Casa');
        expect(find.text(message), findsOneWidget);
        expect(
          buttonLabelsIn(tester, _noticeCard(message)),
          contains(strings.retryButton),
        );
        await tester.tap(
          find.descendant(
            of: _noticeCard(message),
            matching: find.text(strings.retryButton),
          ),
        );
        await tester.pumpAndSettle();
        expect(controller.calls, ['retrySave']);
      });

      testWidgets('without a name the notice says "unnamed network"', (
        tester,
      ) async {
        await pumpSettings(
          tester,
          code,
          open: false,
          size: const Size(1200, 800),
          state: settingsState(
            notices: const [
              Notice(id: 9, kind: NoticeKind.networkStopNotSaved),
            ],
          ),
        );
        expect(
          find.text(strings.noticeNetworkStopNotSaved(strings.unnamedNetwork)),
          findsOneWidget,
        );
      });
    });

    group('[$code] E874 ignored devices (RF-536 to RF-539)', () {
      testWidgets('rows with the name, the fingerprint and the date; Stop '
          'ignoring calls unignore', (tester) async {
        final newer = DateTime.utc(2026, 10, 20, 12);
        final older = DateTime.utc(2026, 3, 5, 12);
        final (controller, _) = await pumpSettings(
          tester,
          code,
          state: settingsState(
            ignored: [
              ignoredView(fingerprint: _fpNew, name: 'Nuevo', at: newer),
              ignoredView(fingerprint: _fpOld, name: 'Viejo', at: older),
            ],
          ),
        );
        expect(
          inSection(strings.sectionIgnored, find.text(strings.ignoredInfo)),
          findsOneWidget,
        );
        final first = find.byKey(ValueKey('ignored-$_fpNew'));
        final second = find.byKey(ValueKey('ignored-$_fpOld'));
        expect(
          tester.getTopLeft(first).dy,
          lessThan(tester.getTopLeft(second).dy),
        );
        expect(
          find.descendant(of: first, matching: find.text('Nuevo')),
          findsOneWidget,
        );
        expect(
          find.descendant(
            of: second,
            matching: find.text(
              '${strings.fingerprintLine('CDEF9876')} · '
              '${strings.ignoredOn(_date(older, code))}',
            ),
          ),
          findsOneWidget,
        );

        await tester.tap(
          find.descendant(
            of: second,
            matching: find.text(strings.unignoreButton),
          ),
        );
        await tester.pumpAndSettle();
        expect(controller.calls, ['unignore $_fpOld']);

        controller.emit(
          settingsState(
            ignored: [
              ignoredView(fingerprint: _fpNew, name: 'Nuevo', at: newer),
            ],
          ),
        );
        await tester.pumpAndSettle();
        expect(find.byKey(ValueKey('ignored-$_fpOld')), findsNothing);
        expect(first, findsOneWidget);
      });

      testWidgets('a device without a name shows its short fingerprint', (
        tester,
      ) async {
        await pumpSettings(
          tester,
          code,
          state: settingsState(
            ignored: [
              ignoredView(
                fingerprint: _fpOld,
                name: '',
                at: DateTime.utc(2026, 1, 2, 12),
              ),
            ],
          ),
        );
        expect(
          inSection(strings.sectionIgnored, find.text('CDEF9876')),
          findsOneWidget,
        );
      });

      testWidgets('no ignored devices: the empty text; an ignored one that '
          'arrives shows up', (tester) async {
        final (controller, _) = await pumpSettings(tester, code);
        expect(
          inSection(strings.sectionIgnored, find.text(strings.ignoredEmpty)),
          findsOneWidget,
        );
        controller.emit(
          settingsState(
            ignored: [
              ignoredView(
                fingerprint: _fpOld,
                name: 'Viejo',
                at: DateTime.utc(2026, 1, 2, 12),
              ),
            ],
          ),
        );
        await tester.pumpAndSettle();
        expect(
          inSection(strings.sectionIgnored, find.text('Viejo')),
          findsOneWidget,
        );
        expect(find.text(strings.ignoredEmpty), findsNothing);
      });

      testWidgets('the 256 rows of the limit fit in the scroll', (
        tester,
      ) async {
        await pumpSettings(
          tester,
          code,
          size: const Size(1100, 800),
          state: settingsState(
            ignored: [
              for (var i = 0; i < 256; i++)
                ignoredView(
                  fingerprint: fingerprintOf(
                    i.toRadixString(16).padLeft(8, '0'),
                  ),
                  name: 'Equipo $i',
                  at: DateTime.utc(2026, 1, 1).add(Duration(hours: i)),
                ),
            ],
          ),
        );
        final scrollable = find
            .descendant(of: settingsScreen, matching: find.byType(Scrollable))
            .first;
        await tester.drag(scrollable, const Offset(0, -40000));
        await tester.pumpAndSettle();
        await tester.drag(scrollable, const Offset(0, -40000));
        await tester.pumpAndSettle();
        expect(find.text('Equipo 255'), findsOneWidget);
        expect(tester.takeException(), isNull);
      });
    });

    group('[$code] E877 something that needs an answer with the network '
        'confirmation open (RF-505)', () {
      testWidgets('Settings closes and stopUsingNetwork is not called', (
        tester,
      ) async {
        final (controller, settings) = await pumpSettings(tester, code);
        await tester.tap(_stop(homeNetwork, strings));
        await tester.pumpAndSettle();

        controller.emit(settingsState(incoming: incomingView()));
        await tester.pumpAndSettle();
        expect(settings.isOpen, isFalse);
        expect(controller.calls, isEmpty);

        await openSettings(tester, strings);
        expect(confirmOpen(tester, strings.sectionNetworks), isFalse);
      });
    });
  }
}
