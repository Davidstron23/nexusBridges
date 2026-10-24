import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nexus_bridges/src/l10n/app_strings.dart';
import 'package:nexus_bridges_core/nexus_bridges_core.dart';

import 'fake_app_controller.dart';
import 'pairing_fixtures.dart';

final String _mineFp = fingerprintOf('AAAA1111');
final String _foreignFp = fingerprintOf('BBBB2222');
final String _hiddenFp = fingerprintOf('CCCC3333');
final String _ignoredFp = fingerprintOf('DDDD4444');
final String _newFp = fingerprintOf('EEEE5555');
final String _mismatchFp = fingerprintOf('FFFF6666');
final String _reinstallFp = fingerprintOf('1234ABCD');

const String _mineName = 'PC principal';
const String _foreignName = 'Equipo de Luis';
const String _hiddenName = 'Portátil viejo';
const String _ignoredName = 'Vecino';
const String _newName = 'Movil';
const String _mismatchName = 'Torre';
const String _reinstallName = 'Portátil';
const String _oldName = 'Portátil · 9999AAAA';
const String _longName = 'Portatil del salon con un nombre largo X';

final List<DeviceEntry> _allRows = [
  entry(fingerprint: _mineFp, name: _mineName, paired: true, mine: true),
  entry(fingerprint: _foreignFp, name: _foreignName, paired: true),
  entry(
    fingerprint: _hiddenFp,
    name: _hiddenName,
    visible: false,
    paired: true,
    mine: true,
  ),
  entry(fingerprint: _ignoredFp, name: _ignoredName, ignored: true),
  entry(fingerprint: _newFp, name: _newName, type: DeviceType.mobile),
  entry(
    fingerprint: _mismatchFp,
    name: _mismatchName,
    paired: true,
    mine: true,
    mismatch: true,
  ),
  entry(
    fingerprint: _reinstallFp,
    name: _reinstallName,
    possiblyReplaces: _oldName,
  ),
];

void _useTallWindow(WidgetTester tester) {
  tester.view.physicalSize = const Size(1200, 3000);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
}

List<String> _tileTexts(WidgetTester tester, String name) {
  final tile = find.ancestor(
    of: find.text(name),
    matching: find.byType(ListTile),
  );
  expect(tile, findsOneWidget);
  return textsIn(tester, tile);
}

Finder _inCard(String name, Finder finder) =>
    find.descendant(of: cardOf(name), matching: finder);

Future<FakeAppController> _pumpRows(
  WidgetTester tester,
  String code, {
  List<DeviceEntry>? entries,
  List<Notice> notices = const [],
  bool unsavedChanges = false,
}) async {
  _useTallWindow(tester);
  final controller = FakeAppController(
    state: NodeState(
      entries: entries ?? _allRows,
      notices: notices,
      unsavedChanges: unsavedChanges,
    ),
  );
  await pumpHome(tester, controller, code);
  return controller;
}

Future<void> _openMenu(WidgetTester tester, AppStrings strings, String name) {
  return tester
      .tap(_inCard(name, find.byTooltip(strings.moreOptions)))
      .then((_) => tester.pumpAndSettle());
}

Finder _noticeCard(String message) =>
    find.ancestor(of: find.text(message), matching: find.byType(Card)).first;

void main() {
  for (final code in languageCodes) {
    final strings = stringsFor(code);

    group('[$code] C88 rows (RF-67, RF-101, RF-109, RF-111, RF-118, '
        'RF-124, RF-129)', () {
      testWidgets('a paired device of mine shows its label and only the menu', (
        tester,
      ) async {
        await _pumpRows(tester, code);

        expect(
          _tileTexts(tester, _mineName),
          unorderedEquals([
            _mineName,
            strings.deviceTypeDesktop,
            strings.pairedMineLabel,
          ]),
        );
        expect(rowButtons(tester, _mineName), isEmpty);
        expect(
          _inCard(_mineName, find.byTooltip(strings.moreOptions)),
          findsOneWidget,
        );
        expect(
          _inCard(_mineName, find.text(strings.mismatchWarning)),
          findsNothing,
        );
      });

      testWidgets('the menu of a device of mine offers foreign and unpair', (
        tester,
      ) async {
        final controller = await _pumpRows(tester, code);

        await _openMenu(tester, strings, _mineName);

        expect(find.text(strings.markAsForeign), findsOneWidget);
        expect(find.text(strings.markAsMine), findsNothing);
        expect(find.text(strings.unpairButton), findsOneWidget);

        await tester.tap(find.text(strings.markAsForeign));
        await tester.pumpAndSettle();

        expect(controller.calls, ['setMine $_mineFp false']);
      });

      testWidgets('a paired device of someone else offers mark as mine', (
        tester,
      ) async {
        final controller = await _pumpRows(tester, code);

        expect(
          _tileTexts(tester, _foreignName),
          unorderedEquals([
            _foreignName,
            strings.deviceTypeDesktop,
            strings.pairedForeignLabel,
          ]),
        );
        expect(rowButtons(tester, _foreignName), isEmpty);

        await _openMenu(tester, strings, _foreignName);
        expect(find.text(strings.markAsMine), findsOneWidget);
        expect(find.text(strings.markAsForeign), findsNothing);

        await tester.tap(find.text(strings.markAsMine));
        await tester.pumpAndSettle();

        expect(controller.calls, ['setMine $_foreignFp true']);
      });

      testWidgets('a paired device out of sight shows Not visible, its saved '
          'name and no Pair', (tester) async {
        await _pumpRows(tester, code);

        expect(
          _tileTexts(tester, _hiddenName),
          unorderedEquals([
            _hiddenName,
            strings.notVisibleLabel,
            strings.pairedMineLabel,
          ]),
        );
        expect(rowButtons(tester, _hiddenName), isEmpty);
        expect(
          _inCard(_hiddenName, find.byIcon(Icons.computer)),
          findsOneWidget,
        );
        expect(
          _inCard(_hiddenName, find.byTooltip(strings.moreOptions)),
          findsOneWidget,
        );
      });

      testWidgets('an ignored device shows Ignored and only Stop ignoring', (
        tester,
      ) async {
        final controller = await _pumpRows(tester, code);

        expect(
          _tileTexts(tester, _ignoredName),
          unorderedEquals([
            _ignoredName,
            strings.deviceTypeDesktop,
            strings.ignoredLabel,
          ]),
        );
        expect(rowButtons(tester, _ignoredName), [strings.unignoreButton]);
        expect(
          _inCard(_ignoredName, find.byTooltip(strings.moreOptions)),
          findsNothing,
        );

        await tester.tap(
          _inCard(_ignoredName, find.text(strings.unignoreButton)),
        );
        await tester.pumpAndSettle();

        expect(controller.calls, ['unignore $_ignoredFp']);
      });

      testWidgets('an unpaired phone shows Not paired and Pair', (
        tester,
      ) async {
        final controller = await _pumpRows(tester, code);

        expect(
          _tileTexts(tester, _newName),
          unorderedEquals([
            _newName,
            strings.deviceTypeMobile,
            strings.notPairedLabel,
          ]),
        );
        expect(rowButtons(tester, _newName), [strings.pairButton]);
        expect(
          _inCard(_newName, find.byIcon(Icons.smartphone)),
          findsOneWidget,
        );
        expect(
          _inCard(_newName, find.byTooltip(strings.moreOptions)),
          findsNothing,
        );

        await tester.tap(_inCard(_newName, find.text(strings.pairButton)));
        await tester.pumpAndSettle();

        expect(controller.calls, ['pair $_newFp']);
        expect(find.byType(SnackBar), findsNothing);
      });

      testWidgets('a mismatch shows the warning, Remove and Pair again', (
        tester,
      ) async {
        final controller = await _pumpRows(tester, code);

        expect(
          _inCard(_mismatchName, find.text(strings.mismatchWarning)),
          findsOneWidget,
        );
        expect(rowButtons(tester, _mismatchName), [
          strings.removeButton,
          strings.pairAgainButton,
        ]);
        expect(
          _tileTexts(tester, _mismatchName),
          contains(strings.pairedMineLabel),
        );
        expect(
          _inCard(_mismatchName, find.byTooltip(strings.moreOptions)),
          findsOneWidget,
        );
        expect(find.text(strings.mismatchWarning), findsOneWidget);

        await tester.tap(
          _inCard(_mismatchName, find.text(strings.pairAgainButton)),
        );
        await tester.pumpAndSettle();

        expect(controller.calls, ['pair $_mismatchFp']);
      });

      testWidgets('a possible reinstall shows the warning with the old name '
          'and Pair', (tester) async {
        await _pumpRows(tester, code);

        expect(
          _inCard(
            _reinstallName,
            find.text(strings.possibleReinstall(_oldName)),
          ),
          findsOneWidget,
        );
        expect(
          _tileTexts(tester, _reinstallName),
          contains(strings.notPairedLabel),
        );
        expect(rowButtons(tester, _reinstallName), [strings.pairButton]);
        expect(
          find.textContaining(strings.possibleReinstall(_oldName)),
          findsOneWidget,
        );
      });

      testWidgets('Pair shows only on the rows that can pair', (tester) async {
        await _pumpRows(tester, code);

        expect(find.text(strings.pairButton), findsNWidgets(2));
        expect(
          _inCard(_newName, find.text(strings.pairButton)),
          findsOneWidget,
        );
        expect(
          _inCard(_reinstallName, find.text(strings.pairButton)),
          findsOneWidget,
        );
        expect(find.text(strings.pairAgainButton), findsOneWidget);
        expect(find.text(strings.unignoreButton), findsOneWidget);
        expect(find.byTooltip(strings.moreOptions), findsNWidgets(4));
      });

      testWidgets('a new state with a row changed repaints that row', (
        tester,
      ) async {
        final controller = await _pumpRows(
          tester,
          code,
          entries: [
            entry(fingerprint: _foreignFp, name: _foreignName, paired: true),
          ],
        );
        expect(
          _tileTexts(tester, _foreignName),
          contains(strings.pairedForeignLabel),
        );

        controller.emit(
          NodeState(
            entries: [
              entry(
                fingerprint: _foreignFp,
                name: _foreignName,
                paired: true,
                mine: true,
              ),
            ],
          ),
        );
        await tester.pumpAndSettle();

        expect(
          _tileTexts(tester, _foreignName),
          contains(strings.pairedMineLabel),
        );
        expect(find.text(strings.pairedForeignLabel), findsNothing);
      });
    });

    group('[$code] C87 confirm before unpairing (RF-112)', () {
      testWidgets('Unpair in the menu asks first with the name', (
        tester,
      ) async {
        final controller = await _pumpRows(tester, code);

        await _openMenu(tester, strings, _mineName);
        await tester.tap(find.text(strings.unpairButton));
        await tester.pumpAndSettle();

        expect(dialog, findsOneWidget);
        expect(find.text(strings.unpairTitle(_mineName)), findsOneWidget);
        expect(find.text(strings.unpairBody(_mineName)), findsOneWidget);
        expect(dialogButtons(tester), [
          strings.cancelButton,
          strings.unpairButton,
        ]);
        expect(controller.calls, isEmpty);
      });

      testWidgets('Cancel closes it without unpairing', (tester) async {
        final controller = await _pumpRows(tester, code);

        await _openMenu(tester, strings, _mineName);
        await tester.tap(find.text(strings.unpairButton));
        await tester.pumpAndSettle();
        await tapInDialog(tester, strings.cancelButton);
        await tester.pumpAndSettle();

        expect(dialog, findsNothing);
        expect(controller.calls, isEmpty);
      });

      testWidgets('confirming unpairs that device only', (tester) async {
        final controller = await _pumpRows(tester, code);

        await _openMenu(tester, strings, _foreignName);
        await tester.tap(find.text(strings.unpairButton));
        await tester.pumpAndSettle();
        await tapInDialog(tester, strings.unpairButton);
        await tester.pumpAndSettle();

        expect(dialog, findsNothing);
        expect(controller.calls, ['unpair $_foreignFp']);
      });

      testWidgets('Esc and a tap outside do not unpair', (tester) async {
        final controller = await _pumpRows(tester, code);

        await _openMenu(tester, strings, _mineName);
        await tester.tap(find.text(strings.unpairButton));
        await tester.pumpAndSettle();
        await tester.sendKeyEvent(LogicalKeyboardKey.escape);
        await tester.pumpAndSettle();
        expect(dialog, findsNothing);

        await _openMenu(tester, strings, _mineName);
        await tester.tap(find.text(strings.unpairButton));
        await tester.pumpAndSettle();
        await tester.tapAt(const Offset(5, 5));
        await tester.pumpAndSettle();

        expect(dialog, findsNothing);
        expect(controller.calls, isEmpty);
      });

      testWidgets('Remove on a mismatch asks first too', (tester) async {
        final controller = await _pumpRows(tester, code);

        await tester.tap(
          _inCard(_mismatchName, find.text(strings.removeButton)),
        );
        await tester.pumpAndSettle();
        expect(find.text(strings.unpairTitle(_mismatchName)), findsOneWidget);
        await tapInDialog(tester, strings.cancelButton);
        await tester.pumpAndSettle();
        expect(controller.calls, isEmpty);

        await tester.tap(
          _inCard(_mismatchName, find.text(strings.removeButton)),
        );
        await tester.pumpAndSettle();
        await tapInDialog(tester, strings.unpairButton);
        await tester.pumpAndSettle();

        expect(controller.calls, ['unpair $_mismatchFp']);
      });
    });

    group('[$code] C90 messages when Pair does not start (RF-70, RF-71)', () {
      final cases = {
        PairRequestResult.alreadyInProgress: strings.pairingAlreadyInProgress,
        PairRequestResult.tooManyPaired: strings.tooManyPaired,
        PairRequestResult.unavailable: strings.pairUnavailable,
      };

      for (final MapEntry(key: result, value: message) in cases.entries) {
        testWidgets('${result.name} shows a SnackBar with its text', (
          tester,
        ) async {
          final controller = await _pumpRows(tester, code);
          controller.pairResult = result;

          await tester.tap(_inCard(_newName, find.text(strings.pairButton)));
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 500));

          expect(controller.calls, ['pair $_newFp']);
          expect(find.byType(SnackBar), findsOneWidget);
          expect(
            find.descendant(
              of: find.byType(SnackBar),
              matching: find.text(message),
            ),
            findsOneWidget,
          );
          for (final other in cases.values.where((text) => text != message)) {
            expect(find.text(other), findsNothing);
          }
        });
      }

      testWidgets('started shows no SnackBar', (tester) async {
        final controller = await _pumpRows(tester, code);

        await tester.tap(_inCard(_newName, find.text(strings.pairButton)));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 500));

        expect(controller.calls, ['pair $_newFp']);
        expect(find.byType(SnackBar), findsNothing);
      });

      testWidgets('Pair again also explains a pairing already in progress', (
        tester,
      ) async {
        final controller = await _pumpRows(tester, code);
        controller.pairResult = PairRequestResult.alreadyInProgress;

        await tester.tap(
          _inCard(_mismatchName, find.text(strings.pairAgainButton)),
        );
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 500));

        expect(controller.calls, ['pair $_mismatchFp']);
        expect(find.text(strings.pairingAlreadyInProgress), findsOneWidget);
      });
    });

    group('[$code] C89 notices (RF-79, RF-106b, RF-114, RF-116, RF-120, '
        'RF-121)', () {
      const who = 'Torre · FFFF6666';
      final cases = <(Notice, String, bool)>[
        (
          const Notice(
            id: 1,
            kind: NoticeKind.attemptCancelled,
            deviceName: peerShort,
          ),
          strings.noticeAttemptPeerCancelled(peerShort),
          false,
        ),
        (
          const Notice(
            id: 8,
            kind: NoticeKind.attemptDataMismatch,
            deviceName: peerShort,
          ),
          strings.noticeAttemptCancelled(peerShort),
          false,
        ),
        (
          const Notice(id: 12, kind: NoticeKind.pairingPaused),
          strings.noticePairingPaused,
          false,
        ),
        (
          const Notice(id: 2, kind: NoticeKind.unpairedByPeer, deviceName: who),
          strings.noticeUnpairedByPeer(who),
          false,
        ),
        (
          const Notice(id: 3, kind: NoticeKind.unpairNotSaved, deviceName: who),
          strings.noticeUnpairNotSaved(who),
          true,
        ),
        (
          const Notice(id: 4, kind: NoticeKind.changeNotSaved),
          strings.noticeChangeNotSaved,
          true,
        ),
        (
          const Notice(id: 5, kind: NoticeKind.ignoreNotSaved, deviceName: who),
          strings.noticeIgnoreNotSaved(who),
          false,
        ),
        (
          const Notice(
            id: 6,
            kind: NoticeKind.pairingNotSaved,
            deviceName: who,
          ),
          strings.noticePairingNotSaved(who),
          false,
        ),
        (
          const Notice(id: 7, kind: NoticeKind.pairingFailed, deviceName: who),
          strings.noticePairingFailed(who),
          false,
        ),
        (
          const Notice(
            id: 14,
            kind: NoticeKind.attemptLost,
            deviceName: peerShort,
          ),
          strings.noticeAttemptLost(peerShort),
          false,
        ),
        (
          const Notice(
            id: 15,
            kind: NoticeKind.replaceWithdrawn,
            deviceName: who,
          ),
          strings.noticeReplaceWithdrawn(who),
          false,
        ),
      ];

      for (final (notice, message, canRetry) in cases) {
        testWidgets('${notice.kind.name} shows its text and '
            '${canRetry ? 'Retry and Close' : 'only Close'}', (tester) async {
          final controller = await _pumpRows(
            tester,
            code,
            entries: const [],
            notices: [notice],
          );

          expect(find.text(message), findsOneWidget);
          expect(notice.canRetry, canRetry);
          expect(
            buttonLabelsIn(tester, _noticeCard(message)),
            canRetry
                ? [strings.retryButton, strings.closeButton]
                : [strings.closeButton],
          );

          if (canRetry) {
            await tester.tap(
              find.descendant(
                of: _noticeCard(message),
                matching: find.text(strings.retryButton),
              ),
            );
            await tester.pumpAndSettle();
          }
          await tester.tap(
            find.descendant(
              of: _noticeCard(message),
              matching: find.text(strings.closeButton),
            ),
          );
          await tester.pumpAndSettle();

          expect(controller.calls, [
            if (canRetry) 'retrySave',
            'dismissNotice ${notice.id}',
          ]);
        });
      }

      testWidgets('C114: one cancelled attempt uses the neutral text with the '
          'short fingerprint, not the data mismatch one', (tester) async {
        await _pumpRows(
          tester,
          code,
          entries: const [],
          notices: const [
            Notice(
              id: 9,
              kind: NoticeKind.attemptCancelled,
              deviceName: peerShort,
              count: 1,
            ),
          ],
        );

        final neutral = strings.noticeAttemptPeerCancelled(peerShort);
        expect(find.text(neutral), findsOneWidget);
        expect(neutral, contains(peerShort));
        expect(
          neutral,
          isNot(contains(strings.noticeAttemptCancelled(peerShort))),
        );
        expect(
          find.text(strings.noticeAttemptCancelled(peerShort)),
          findsNothing,
        );
        expect(find.text(strings.noticeAttemptsCancelled(1)), findsNothing);
        expect(find.textContaining(peerShort), findsOneWidget);
      });

      testWidgets('C114: a data mismatch uses the text of RF-79 with the '
          'short fingerprint', (tester) async {
        await _pumpRows(
          tester,
          code,
          entries: const [],
          notices: const [
            Notice(
              id: 9,
              kind: NoticeKind.attemptDataMismatch,
              deviceName: peerShort,
            ),
          ],
        );

        expect(
          find.text(strings.noticeAttemptCancelled(peerShort)),
          findsOneWidget,
        );
        expect(
          find.text(strings.noticeAttemptPeerCancelled(peerShort)),
          findsNothing,
        );
      });

      testWidgets('C114: the pause shows its text with Close and without '
          'Retry', (tester) async {
        final controller = await _pumpRows(
          tester,
          code,
          entries: const [],
          notices: const [Notice(id: 13, kind: NoticeKind.pairingPaused)],
        );

        final card = _noticeCard(strings.noticePairingPaused);
        expect(buttonLabelsIn(tester, card), [strings.closeButton]);
        expect(find.text(strings.retryButton), findsNothing);

        await tester.tap(
          find.descendant(of: card, matching: find.text(strings.closeButton)),
        );
        await tester.pumpAndSettle();
        expect(controller.calls, ['dismissNotice 13']);
      });

      for (final count in [2, 3, 7]) {
        testWidgets('$count cancelled attempts use the alert text with the '
            'count and no fingerprint', (tester) async {
          final controller = await _pumpRows(
            tester,
            code,
            entries: const [],
            notices: [
              Notice(
                id: 10,
                kind: NoticeKind.attemptCancelled,
                deviceName: peerShort,
                count: count,
              ),
            ],
          );

          final message = strings.noticeAttemptsCancelled(count);
          expect(find.text(message), findsOneWidget);
          expect(message, contains('$count'));
          expect(message, isNot(contains(peerShort)));
          expect(
            find.text(strings.noticeAttemptCancelled(peerShort)),
            findsNothing,
          );
          expect(
            find.text(strings.noticeAttemptPeerCancelled(peerShort)),
            findsNothing,
          );
          expect(buttonLabelsIn(tester, _noticeCard(message)), [
            strings.closeButton,
          ]);

          await tester.tap(
            find.descendant(
              of: _noticeCard(message),
              matching: find.text(strings.closeButton),
            ),
          );
          await tester.pumpAndSettle();
          expect(controller.calls, ['dismissNotice 10']);
        });
      }

      testWidgets('C136: a lost attempt names the short fingerprint and is '
          'neither the cancelled nor the data mismatch notice', (tester) async {
        await _pumpRows(
          tester,
          code,
          entries: const [],
          notices: const [
            Notice(id: 16, kind: NoticeKind.attemptLost, deviceName: peerShort),
          ],
        );

        final lost = strings.noticeAttemptLost(peerShort);
        expect(find.text(lost), findsOneWidget);
        expect(lost, contains(peerShort));
        expect(
          find.text(strings.noticeAttemptPeerCancelled(peerShort)),
          findsNothing,
        );
        expect(
          find.text(strings.noticeAttemptCancelled(peerShort)),
          findsNothing,
        );
        expect(find.text(strings.outcomeLost(peerShort)), findsNothing);
        expect(buttonLabelsIn(tester, _noticeCard(lost)), [
          strings.closeButton,
        ]);
        expect(find.text(strings.retryButton), findsNothing);
      });

      testWidgets('C136: a withdrawn replacement names the old device and '
          'offers only Close', (tester) async {
        final controller = await _pumpRows(
          tester,
          code,
          entries: const [],
          notices: const [
            Notice(
              id: 17,
              kind: NoticeKind.replaceWithdrawn,
              deviceName: _oldName,
            ),
          ],
        );

        final withdrawn = strings.noticeReplaceWithdrawn(_oldName);
        expect(find.text(withdrawn), findsOneWidget);
        expect(withdrawn, contains(_oldName));
        expect(find.text(strings.replaceTitle(_oldName)), findsNothing);
        expect(buttonLabelsIn(tester, _noticeCard(withdrawn)), [
          strings.closeButton,
        ]);
        expect(find.text(strings.retryButton), findsNothing);

        await tester.tap(
          find.descendant(
            of: _noticeCard(withdrawn),
            matching: find.text(strings.closeButton),
          ),
        );
        await tester.pumpAndSettle();
        expect(controller.calls, ['dismissNotice 17']);
      });

      testWidgets('a cumulative notice that grows repaints its count', (
        tester,
      ) async {
        final controller = await _pumpRows(
          tester,
          code,
          entries: const [],
          notices: const [
            Notice(
              id: 11,
              kind: NoticeKind.attemptCancelled,
              deviceName: peerShort,
            ),
          ],
        );
        expect(
          find.text(strings.noticeAttemptPeerCancelled(peerShort)),
          findsOneWidget,
        );

        controller.emit(
          const NodeState(
            notices: [
              Notice(
                id: 11,
                kind: NoticeKind.attemptCancelled,
                deviceName: '9F8E7D6C',
                count: 2,
              ),
            ],
          ),
        );
        await tester.pumpAndSettle();

        expect(
          find.text(strings.noticeAttemptPeerCancelled(peerShort)),
          findsNothing,
        );
        expect(find.text(strings.noticeAttemptsCancelled(2)), findsOneWidget);
      });

      testWidgets('notices stack above the list in their order', (
        tester,
      ) async {
        await _pumpRows(
          tester,
          code,
          entries: [entry(fingerprint: _newFp, name: _newName)],
          notices: [cases[1].$1, cases[2].$1],
        );

        final first = tester.getTopLeft(find.text(cases[1].$2)).dy;
        final second = tester.getTopLeft(find.text(cases[2].$2)).dy;
        final row = tester.getTopLeft(find.text(_newName)).dy;
        expect(first, lessThan(second));
        expect(second, lessThan(row));
      });
    });

    group('[$code] C120 rows in a 320 px window (RF-101)', () {
      final narrowRows = <(String, DeviceEntry, String)>[
        (
          'paired and mine',
          entry(
            fingerprint: _mineFp,
            name: _longName,
            paired: true,
            mine: true,
          ),
          strings.pairedMineLabel,
        ),
        (
          'paired, foreign and with a mismatch',
          entry(
            fingerprint: _foreignFp,
            name: _longName,
            paired: true,
            mismatch: true,
          ),
          strings.pairedForeignLabel,
        ),
        (
          'ignored',
          entry(fingerprint: _ignoredFp, name: _longName, ignored: true),
          strings.ignoredLabel,
        ),
        (
          'not paired',
          entry(fingerprint: _newFp, name: _longName, type: DeviceType.mobile),
          strings.notPairedLabel,
        ),
        (
          'paired and not visible',
          entry(
            fingerprint: _hiddenFp,
            name: _longName,
            visible: false,
            paired: true,
            mine: true,
          ),
          strings.pairedMineLabel,
        ),
        (
          'a possible reinstall',
          entry(
            fingerprint: _reinstallFp,
            name: _longName,
            possiblyReplaces: _oldName,
          ),
          strings.notPairedLabel,
        ),
      ];

      testWidgets('every row type paints without exceptions, with the label '
          'on one line cut with an ellipsis inside 40 % of the row, and the '
          'menu opens with its two entries', (tester) async {
        expect(_longName.length, 40);
        tester.view.physicalSize = const Size(320, 800);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);

        for (final (label, row, text) in narrowRows) {
          final controller = FakeAppController(
            state: NodeState(entries: [row]),
          );
          await pumpHome(tester, controller, code);

          expect(tester.takeException(), isNull, reason: label);
          final labelFinder = _inCard(_longName, find.text(text));
          expect(labelFinder, findsOneWidget, reason: label);
          final labelText = tester.widget<Text>(labelFinder);
          expect(labelText.maxLines, 1, reason: label);
          expect(labelText.overflow, TextOverflow.ellipsis, reason: label);
          final tile = find.ancestor(
            of: labelFinder,
            matching: find.byType(ListTile),
          );
          final tileWidth = tester.getSize(tile).width;
          expect(
            tester.getSize(labelFinder).width,
            lessThanOrEqualTo(tileWidth * 0.4),
            reason: label,
          );
          expect(
            tester.getRect(cardOf(_longName)).right,
            lessThanOrEqualTo(320),
            reason: label,
          );
          expect(
            tester.getRect(_inCard(_longName, find.text(_longName))).right,
            lessThanOrEqualTo(tester.getRect(labelFinder).left),
            reason: label,
          );

          if (row.paired) {
            await _openMenu(tester, strings, _longName);
            expect(tester.takeException(), isNull, reason: '$label menu');
            expect(
              find.text(row.mine ? strings.markAsForeign : strings.markAsMine),
              findsOneWidget,
              reason: label,
            );
            expect(find.text(strings.unpairButton), findsOneWidget);
            await tester.sendKeyEvent(LogicalKeyboardKey.escape);
            await tester.pumpAndSettle();
          } else {
            expect(
              _inCard(_longName, find.byTooltip(strings.moreOptions)),
              findsNothing,
              reason: label,
            );
          }
          await tester.pumpWidget(const SizedBox());
        }
      });

      testWidgets('all row types together scroll without exceptions', (
        tester,
      ) async {
        tester.view.physicalSize = const Size(320, 800);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        final controller = FakeAppController(
          state: NodeState(
            entries: [for (final (_, row, _) in narrowRows) row],
            notices: const [
              Notice(id: 1, kind: NoticeKind.pairingPaused),
              Notice(
                id: 2,
                kind: NoticeKind.attemptCancelled,
                deviceName: peerShort,
                count: 3,
              ),
            ],
          ),
        );
        await pumpHome(tester, controller, code);
        expect(tester.takeException(), isNull);

        final scrollable = find.byType(Scrollable).first;
        for (var i = 0; i < 12; i++) {
          await tester.drag(scrollable, const Offset(0, -200));
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull, reason: 'drag $i');
        }
      });
    });

    group('[$code] C106 unsaved changes (RF-94, RF-120)', () {
      testWidgets('unsavedChanges with no retry notice adds a notice with '
          'only Retry', (tester) async {
        final controller = await _pumpRows(
          tester,
          code,
          entries: const [],
          unsavedChanges: true,
        );

        expect(find.text(strings.noticeChangeNotSaved), findsOneWidget);
        expect(
          buttonLabelsIn(tester, _noticeCard(strings.noticeChangeNotSaved)),
          [strings.retryButton],
        );
        expect(find.text(strings.closeButton), findsNothing);

        await tester.tap(find.text(strings.retryButton));
        await tester.pumpAndSettle();
        expect(controller.calls, ['retrySave']);

        controller.emit(const NodeState());
        await tester.pumpAndSettle();
        expect(find.text(strings.noticeChangeNotSaved), findsNothing);
        expect(find.text(strings.retryButton), findsNothing);
      });

      testWidgets('a notice without retry does not hide the extra notice', (
        tester,
      ) async {
        await _pumpRows(
          tester,
          code,
          entries: const [],
          unsavedChanges: true,
          notices: const [
            Notice(
              id: 1,
              kind: NoticeKind.unpairedByPeer,
              deviceName: _mineName,
            ),
          ],
        );

        expect(
          find.text(strings.noticeUnpairedByPeer(_mineName)),
          findsOneWidget,
        );
        expect(find.text(strings.noticeChangeNotSaved), findsOneWidget);
        expect(find.text(strings.retryButton), findsOneWidget);
      });

      testWidgets('a changeNotSaved notice already there is not repeated', (
        tester,
      ) async {
        await _pumpRows(
          tester,
          code,
          entries: const [],
          unsavedChanges: true,
          notices: const [Notice(id: 4, kind: NoticeKind.changeNotSaved)],
        );

        expect(find.text(strings.noticeChangeNotSaved), findsOneWidget);
        expect(
          buttonLabelsIn(tester, _noticeCard(strings.noticeChangeNotSaved)),
          [strings.retryButton, strings.closeButton],
        );
      });

      testWidgets('an unpairNotSaved notice already offers Retry', (
        tester,
      ) async {
        await _pumpRows(
          tester,
          code,
          entries: const [],
          unsavedChanges: true,
          notices: const [
            Notice(
              id: 3,
              kind: NoticeKind.unpairNotSaved,
              deviceName: _mineName,
            ),
          ],
        );

        expect(
          find.text(strings.noticeUnpairNotSaved(_mineName)),
          findsOneWidget,
        );
        expect(find.text(strings.noticeChangeNotSaved), findsNothing);
        expect(find.text(strings.retryButton), findsOneWidget);
      });

      testWidgets('without unsavedChanges there is no extra notice', (
        tester,
      ) async {
        await _pumpRows(tester, code, entries: const []);

        expect(find.text(strings.noticeChangeNotSaved), findsNothing);
        expect(find.text(strings.retryButton), findsNothing);
      });
    });
  }

  group('C91 rendered texts of rows, notices and the confirmation', () {
    const names = [
      _mineName,
      _foreignName,
      _hiddenName,
      _ignoredName,
      _newName,
      _mismatchName,
      _reinstallName,
      _oldName,
      peerShort,
    ];
    const userTexts = {..._userNames};
    final scenarios = <String, Future<void> Function(WidgetTester, String)>{
      'every row type': (tester, code) async {
        await _pumpRows(tester, code);
      },
      'every notice and the extra one': (tester, code) async {
        await _pumpRows(
          tester,
          code,
          entries: const [],
          unsavedChanges: true,
          notices: [
            for (final (index, kind) in NoticeKind.values.indexed)
              Notice(
                id: index,
                kind: kind,
                deviceName:
                    kind == NoticeKind.attemptCancelled ||
                        kind == NoticeKind.attemptDataMismatch ||
                        kind == NoticeKind.attemptLost
                    ? peerShort
                    : _mineName,
                count: kind == NoticeKind.attemptCancelled ? 3 : 1,
              ),
            const Notice(
              id: 99,
              kind: NoticeKind.attemptCancelled,
              deviceName: peerShort,
            ),
          ],
        );
      },
      'the confirmation to unpair': (tester, code) async {
        final strings = stringsFor(code);
        await _pumpRows(tester, code);
        await tester.tap(
          _inCard(_mismatchName, find.text(strings.removeButton)),
        );
        await tester.pumpAndSettle();
      },
      'the open menu': (tester, code) async {
        await _pumpRows(
          tester,
          code,
          entries: [entry(fingerprint: _mineFp, name: _mineName, paired: true)],
        );
        await _openMenu(tester, stringsFor(code), _mineName);
      },
    };

    for (final MapEntry(key: name, value: build) in scenarios.entries) {
      testWidgets('$name: every text comes from AppStrings and differs', (
        tester,
      ) async {
        final rendered = <String, List<String>>{};
        for (final code in languageCodes) {
          await build(tester, code);
          final texts = visibleTexts(tester);
          expect(texts, isNotEmpty);
          expect(texts.where((text) => text.trim().isEmpty), isEmpty);
          final allowed = allowedTexts(
            stringsFor(code),
            names: names,
            counts: const [3],
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

const Set<String> _userNames = {
  _mineName,
  _foreignName,
  _hiddenName,
  _ignoredName,
  _newName,
  _mismatchName,
  _reinstallName,
};
