import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nexus_bridges/src/l10n/app_strings.dart';
import 'package:nexus_bridges/src/ui/activity_cards.dart';
import 'package:nexus_bridges/src/ui/configure/configure_panel.dart';
import 'package:nexus_bridges/src/ui/configure/configure_sections.dart';
import 'package:nexus_bridges/src/ui/configure/share_rows.dart';
import 'package:nexus_bridges/src/ui/destination/folder_navigator.dart';
import 'package:nexus_bridges/src/ui/queue_card.dart';
import 'package:nexus_bridges/src/ui/theme/tokens.dart';
import 'package:nexus_bridges_core/nexus_bridges_core.dart';

import '../destination/destination_fixtures.dart';
import '../fake_app_controller.dart';
import '../segoe_font.dart';

final Finder _panel = find.byType(ConfigurePanel);

Finder _inPanel(Finder finder) => find.descendant(of: _panel, matching: finder);

const ShareView _shareDocs = ShareView(
  rootId: 'share-docs',
  label: 'Trabajo',
  home: false,
  path: r'D:\datos\Trabajo',
  drive: DriveKind.fixed,
  available: true,
);
const ShareView _shareUsb = ShareView(
  rootId: 'share-usb',
  label: 'Pendrive',
  home: false,
  path: r'E:\copia',
  drive: DriveKind.removable,
  available: false,
);
const ShareView _shareHome = ShareView(
  rootId: 'share-home',
  label: 'david',
  home: true,
  path: r'C:\Users\david',
  drive: DriveKind.fixed,
  available: true,
);

HistoryEntryView _history(
  int i, {
  HistoryDirection direction = HistoryDirection.sent,
  String? name,
  int itemCount = 1,
  int delivered = 1,
  DestinationLabel? destination,
  TransferOutcome outcome = TransferOutcome.saved,
}) => HistoryEntryView(
  at: DateTime(2026, 11, 5, 10, 0).subtract(Duration(hours: 5 * i)),
  direction: direction,
  name: name ?? 'archivo-$i.txt',
  isFolder: false,
  fileCount: 1,
  itemCount: itemCount,
  delivered: delivered,
  size: 2048,
  destination: destination,
  outcome: outcome,
);

NodeState _state({
  bool mine = true,
  bool visible = true,
  String? alias,
  List<ShareView> shares = const [],
  List<SavedDestination> favorites = const [],
  List<HistoryEntryView> history = const [],
  List<Notice> notices = const [],
  bool sharesUnsaved = false,
}) {
  return NodeState(
    entries: [
      DeviceEntry(
        fingerprint: mineFp,
        displayName: alias ?? mineName,
        realName: mineName,
        alias: alias,
        deviceType: visible ? DeviceType.desktop : null,
        visible: visible,
        paired: true,
        mine: mine,
        ignored: false,
        mismatch: false,
        possiblyReplaces: null,
      ),
    ],
    peers: {
      mineFp: PeerSettingsView(
        fingerprint: mineFp,
        realName: mineName,
        alias: alias,
        mine: mine,
        visible: visible,
        shares: shares,
        sharesUnsaved: sharesUnsaved,
        favorites: favorites,
        history: history,
      ),
    },
    notices: notices,
  );
}

Future<void> _openFromRow(WidgetTester tester, AppStrings strings) async {
  await tester.tap(
    find.descendant(
      of: find.byKey(ValueKey(mineFp)),
      matching: find.byTooltip(strings.moreOptions),
    ),
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 500));
  await tester.tap(find.text(strings.configureEllipsis).last);
  await _settle(tester);
}

Future<void> _settle(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 600));
  await tester.pump(const Duration(milliseconds: 700));
  await tester.pump();
}

Future<void> _scrollTo(WidgetTester tester, Finder finder) async {
  final state = tester.state<ScrollableState>(
    _inPanel(find.byType(Scrollable)).first,
  );
  for (var i = 0; i < 12 && finder.evaluate().isEmpty; i++) {
    state.position.jumpTo(
      (state.position.pixels + 300).clamp(0, state.position.maxScrollExtent),
    );
    await tester.pump();
  }
  await tester.pump();
  await Scrollable.ensureVisible(finder.evaluate().first);
  await tester.pump();
}

void main() {
  setUpAll(loadSegoe);

  for (final code in languageCodes) {
    final strings = stringsFor(code);
    final short = mineFp.substring(0, 8);

    Future<DelegatingController> pump(
      WidgetTester tester,
      NodeState state, {
      Size size = const Size(1200, 900),
      double textScale = 1,
    }) async {
      final (controller, _) = await pumpDestinationHome(
        tester,
        code,
        state,
        size: size,
        textScale: textScale,
      );
      return controller;
    }

    group('[$code] E770 Configure opens with its sections (RF-427)', () {
      testWidgets('it opens in the real tree of the app', (tester) async {
        await pump(tester, _state());

        await _openFromRow(tester, strings);

        expect(tester.takeException(), isNull);
        expect(_panel, findsOneWidget);
      });

      testWidgets('from the row menu, sections in order, name and short '
          'fingerprint in the header', (tester) async {
        await pump(tester, _state());

        await _openFromRow(tester, strings);

        expect(_panel, findsOneWidget);
        expect(_inPanel(find.text(mineName)), findsWidgets);
        expect(
          _inPanel(find.text(strings.fingerprintLine(short))),
          findsOneWidget,
        );
        expect(_inPanel(find.text(strings.visibleLabel)), findsOneWidget);
        final tops = [
          for (final title in [
            strings.thisDeviceIs,
            strings.sharesTitle,
            strings.favoritesTitle,
          ])
            tester.getTopLeft(_inPanel(find.text(title))).dy,
        ];
        expect(tops, orderedEquals([...tops]..sort()));
      });

      testWidgets('alias, history and unpair come after, in that order', (
        tester,
      ) async {
        await pump(tester, _state());
        await _openFromRow(tester, strings);
        final alias = _inPanel(find.text(strings.aliasTitle));
        final history = _inPanel(find.text(strings.historyTitle(mineName)));
        final unpair = _inPanel(find.text(strings.unpairSectionTitle));

        await _scrollTo(tester, unpair);
        await tester.pump();

        expect(unpair, findsWidgets);
        final bottom = tester.getTopLeft(unpair.first).dy;
        if (history.evaluate().isNotEmpty) {
          expect(tester.getTopLeft(history).dy, lessThan(bottom));
        }
        if (alias.evaluate().isNotEmpty && history.evaluate().isNotEmpty) {
          expect(
            tester.getTopLeft(alias).dy,
            lessThan(tester.getTopLeft(history).dy),
          );
        }
      });

      testWidgets('from the diagram popover', (tester) async {
        await pump(tester, _state());

        await tester.tap(find.byKey(ValueKey('flow-peer-$mineFp')));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));
        await tester.tap(find.text(strings.configureEllipsis).last);
        await _settle(tester);

        expect(_panel, findsOneWidget);
      });

      testWidgets('Esc closes it', (tester) async {
        await pump(tester, _state());

        await _openFromRow(tester, strings);
        await tester.sendKeyEvent(LogicalKeyboardKey.escape);
        await _settle(tester);

        expect(_panel, findsNothing);
      });

      testWidgets('the X and a click outside close it', (tester) async {
        await pump(tester, _state());

        await _openFromRow(tester, strings);
        await tester.tap(_inPanel(find.byTooltip(strings.closeButton)));
        await _settle(tester);
        expect(_panel, findsNothing);

        await _openFromRow(tester, strings);
        await tester.tapAt(const Offset(40, 400));
        await _settle(tester);
        expect(_panel, findsNothing);
      });

      testWidgets('the Mine and Someone else cards change it', (tester) async {
        final controller = await pump(tester, _state());
        await _openFromRow(tester, strings);

        await tester.tap(_inPanel(find.text(strings.foreignCard)));
        await tester.pump();

        expect(controller.calls, contains('setMine $mineFp false'));
      });

      testWidgets('with an alias the header keeps the real name', (
        tester,
      ) async {
        await pump(tester, _state(alias: 'Curro'));

        await _openFromRow(tester, strings);

        expect(_inPanel(find.text('Curro')), findsWidgets);
        expect(
          _inPanel(
            find.text('$mineName \u{00B7} ${strings.fingerprintLine(short)}'),
          ),
          findsOneWidget,
        );
      });

      testWidgets('unpairing asks with the 003 modal', (tester) async {
        final controller = await pump(tester, _state());
        await _openFromRow(tester, strings);
        final button = _inPanel(find.text(strings.unpairButton));

        await _scrollTo(tester, button);
        await tester.pump(const Duration(milliseconds: 200));
        await tester.tap(button.last);
        await _settle(tester);

        expect(find.text(strings.unpairTitle(mineName)), findsOneWidget);
        expect(controller.calls.where((c) => c.startsWith('unpair')), isEmpty);
      });

      testWidgets('the unpair button is soft red at rest and its fill, text '
          'and icon light up together', (tester) async {
        await pump(tester, _state());
        await _openFromRow(tester, strings);
        final label = _inPanel(find.text(strings.unpairButton));
        await _scrollTo(tester, label);
        await tester.pump(const Duration(milliseconds: 200));

        final button = find.ancestor(
          of: label.last,
          matching: find.bySubtype<FilledButton>(),
        );
        final colors = NbColors.of(tester.element(button));
        ButtonStyle style() => tester.widget<FilledButton>(button).style!;
        Color fill() => style().backgroundColor!.resolve({})!;
        Color ink() => style().foregroundColor!.resolve({})!;
        expect(fill(), colors.dangerWeak);
        expect(ink(), colors.danger);
        expect(style().animationDuration, Duration.zero);

        final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
        await mouse.addPointer(location: Offset.zero);
        addTearDown(mouse.removePointer);
        await mouse.moveTo(tester.getCenter(button));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 60));
        expect(fill(), isNot(colors.dangerWeak));
        expect(fill(), isNot(colors.dangerFill));
        expect(ink(), isNot(colors.danger));
        expect(ink(), isNot(colors.onPrimary));

        await tester.pump(const Duration(milliseconds: 400));
        expect(fill(), colors.dangerFill);
        expect(ink(), colors.onPrimary);

        await mouse.moveTo(Offset.zero);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 400));
        expect(fill(), colors.dangerWeak);
      });

      testWidgets('the unpair button keeps its place and its size', (
        tester,
      ) async {
        await pump(tester, _state());
        await _openFromRow(tester, strings);
        final label = _inPanel(find.text(strings.unpairButton));
        await _scrollTo(tester, label);
        await tester.pump(const Duration(milliseconds: 200));

        final zone = tester.getRect(_inPanel(find.byType(ConfigureDangerZone)));
        final button = tester.getRect(
          find.ancestor(
            of: label.last,
            matching: find.bySubtype<FilledButton>(),
          ),
        );
        expect(button.left, closeTo(zone.left + 14, 0.01));
        expect(button.width, lessThan(zone.width / 2));
        expect(button.height, lessThan(46));
      });

      testWidgets('the section titles are not cut when they fit', (
        tester,
      ) async {
        await pump(tester, _state());
        await _openFromRow(tester, strings);

        final title = _inPanel(find.text(strings.sharesTitle));
        final paragraph = tester.renderObject<RenderParagraph>(title.last);
        expect(paragraph.didExceedMaxLines, isFalse);
      });

      testWidgets('at 200 % text the unpair button does not overflow', (
        tester,
      ) async {
        await pump(tester, _state(), textScale: 2);
        await _openFromRow(tester, strings);
        final label = _inPanel(find.text(strings.unpairButton));
        await _scrollTo(tester, label);
        await tester.pump(const Duration(milliseconds: 200));

        expect(tester.takeException(), isNull);
        final panel = tester.getRect(_panel);
        expect(tester.getRect(label.last).right, lessThan(panel.right));
      });
    });

    group(
      '[$code] E771 folders it can use (RF-400, RF-402, RF-403, RF-405)',
      () {
        testWidgets('each one with its full path, and the X removes it', (
          tester,
        ) async {
          final controller = await pump(
            tester,
            _state(shares: const [_shareDocs, _shareUsb]),
          );
          await _openFromRow(tester, strings);

          expect(_inPanel(find.text('Trabajo')), findsOneWidget);
          expect(_inPanel(find.text(r'D:\datos\Trabajo')), findsOneWidget);
          expect(_inPanel(find.text('D:')), findsOneWidget);
          expect(_inPanel(find.text(strings.chipRemovable)), findsOneWidget);
          expect(
            _inPanel(find.byTooltip(strings.shareUnavailable)),
            findsOneWidget,
          );
          expect(_inPanel(find.text(strings.ofMax(2, 16))), findsOneWidget);

          await tester.tap(
            _inPanel(find.byTooltip(strings.shareRemoveTooltip)).first,
          );
          await tester.pump();

          expect(controller.calls, contains('removeShare $mineFp share-docs'));
        });

        testWidgets('adding one goes through the selector', (tester) async {
          final controller = await pump(tester, _state());
          await _openFromRow(tester, strings);

          await tester.tap(_inPanel(find.text(strings.sharesAdd)));
          await tester.pump();

          expect(controller.calls, contains('addShare $mineFp'));
        });

        final refusals = <ShareRefusal, String>{
          ShareRefusal.networkDrive: strings.shareRefusedNetwork,
          ShareRefusal.adminShare: strings.shareRefusedAdminShare,
          ShareRefusal.unknownDrive: strings.shareRefusedUnknownDrive,
          ShareRefusal.forbidden: strings.shareRefusedForbidden,
          ShareRefusal.appData: strings.shareRefusedAppData,
          ShareRefusal.tempFolder: strings.shareRefusedTemp,
          ShareRefusal.tooLong: strings.shareRefusedTooLong,
          ShareRefusal.missing: strings.shareRefusedMissing,
          ShareRefusal.alreadyAdded: strings.shareRefusedAlready,
          ShareRefusal.full: strings.shareRefusedFull,
        };
        for (final MapEntry(key: reason, value: text) in refusals.entries) {
          testWidgets('${reason.name} shows its reason', (tester) async {
            final controller = await pump(tester, _state());
            controller.shareResult = ShareRefused(reason);
            await _openFromRow(tester, strings);

            await tester.tap(_inPanel(find.text(strings.sharesAdd)));
            await _settle(tester);

            expect(_inPanel(find.text(text)), findsOneWidget);
          });
        }

        for (final (name, cloud, mark, text) in [
          ('cloud', true, false, strings.shareCloudConfirm),
          ('no web mark', false, true, strings.shareNoMarkConfirm),
        ]) {
          testWidgets('$name asks in line, and confirming adds it', (
            tester,
          ) async {
            final controller = await pump(tester, _state());
            controller.shareResult = ShareNeedsConfirmation(
              pendingId: 'p1',
              path: r'C:\Users\david\OneDrive\Fotos',
              cloud: cloud,
              withoutMark: mark,
            );
            await _openFromRow(tester, strings);

            await tester.tap(_inPanel(find.text(strings.sharesAdd)));
            await _settle(tester);

            expect(_inPanel(find.textContaining(text)), findsOneWidget);
            await tester.tap(_inPanel(find.text(strings.shareAddAnyway)));
            await _settle(tester);

            expect(controller.calls, contains('confirmShare $mineFp p1'));
          });
        }

        testWidgets('Cancel drops the pending folder', (tester) async {
          final controller = await pump(tester, _state());
          controller.shareResult = const ShareNeedsConfirmation(
            pendingId: 'p1',
            path: r'C:\nube',
            cloud: true,
            withoutMark: false,
          );
          await _openFromRow(tester, strings);
          await tester.tap(_inPanel(find.text(strings.sharesAdd)));
          await _settle(tester);

          await tester.tap(_inPanel(find.text(strings.cancelButton)).first);
          await _settle(tester);

          expect(controller.calls, contains('cancelPendingShare p1'));
          expect(
            controller.calls.where((c) => c.startsWith('confirmShare')),
            isEmpty,
          );
        });

        testWidgets('someone else: paused, with the explanation, keeps them', (
          tester,
        ) async {
          await pump(tester, _state(mine: false, shares: const [_shareDocs]));
          await _openFromRow(tester, strings);

          expect(_inPanel(find.text(strings.sharesPaused)), findsOneWidget);
          expect(_inPanel(find.text('Trabajo')), findsOneWidget);
        });

        testWidgets('someone else: the explanation that only own devices '
            'can share, and Tab never reaches the paused folders (B4)', (
          tester,
        ) async {
          await pump(tester, _state(mine: false, shares: const [_shareDocs]));
          await _openFromRow(tester, strings);

          expect(
            _inPanel(find.text(strings.sharesForeignOnly)),
            findsOneWidget,
          );
          final body = _inPanel(find.byType(SharesBody));
          expect(body, findsOneWidget);
          for (var i = 0; i < 40; i++) {
            await tester.sendKeyEvent(LogicalKeyboardKey.tab);
            await tester.pump();
            final focused = FocusManager.instance.primaryFocus?.context;
            if (focused == null) continue;
            final inside = find
                .descendant(of: body, matching: find.byWidget(focused.widget))
                .evaluate()
                .isNotEmpty;
            expect(inside, isFalse, reason: 'Tab number ${i + 1}');
          }
        });

        testWidgets('mine: Tab does reach its folders', (tester) async {
          await pump(tester, _state(shares: const [_shareDocs]));
          await _openFromRow(tester, strings);

          final body = _inPanel(find.byType(SharesBody));
          var reached = false;
          for (var i = 0; i < 40 && !reached; i++) {
            await tester.sendKeyEvent(LogicalKeyboardKey.tab);
            await tester.pump();
            final focused = FocusManager.instance.primaryFocus?.context;
            if (focused == null) continue;
            reached = find
                .descendant(of: body, matching: find.byWidget(focused.widget))
                .evaluate()
                .isNotEmpty;
          }
          expect(reached, isTrue);
          expect(_inPanel(find.text(strings.sharesForeignOnly)), findsNothing);
        });

        testWidgets('the full path can be read in a tooltip (B5)', (
          tester,
        ) async {
          const long = ShareView(
            rootId: 'share-long',
            label: 'Proyecto',
            home: false,
            path:
                r'D:\una\ruta\muy\larga\que\no\cabe\en\la\fila\de\configurar'
                r'\porque\sigue\y\sigue\Proyecto',
            drive: DriveKind.fixed,
            available: true,
          );
          await pump(tester, _state(shares: const [long]));
          await _openFromRow(tester, strings);

          expect(_inPanel(find.byTooltip(long.path)), findsOneWidget);
        });

        testWidgets('opening Configure of a device of mine checks its '
            'folders, and one that went away reads as not available (M4)', (
          tester,
        ) async {
          final controller = await pump(
            tester,
            _state(shares: const [_shareDocs]),
          );
          await _openFromRow(tester, strings);

          expect(
            controller.calls.where((c) => c == 'refreshShares $mineFp'),
            hasLength(1),
          );
          expect(
            _inPanel(find.byTooltip(strings.shareUnavailable)),
            findsNothing,
          );

          controller.emit(
            _state(
              shares: const [
                ShareView(
                  rootId: 'share-docs',
                  label: 'Trabajo',
                  home: false,
                  path: r'D:\datos\Trabajo',
                  drive: DriveKind.fixed,
                  available: false,
                ),
              ],
            ),
          );
          await tester.pump();

          expect(
            _inPanel(find.byTooltip(strings.shareUnavailable)),
            findsOneWidget,
          );
          expect(
            controller.calls.where((c) => c == 'refreshShares $mineFp'),
            hasLength(1),
          );
        });

        testWidgets('someone else is not checked until it is marked as mine '
            '(M4)', (tester) async {
          final controller = await pump(tester, _state(mine: false));
          await _openFromRow(tester, strings);

          expect(
            controller.calls.where((c) => c.startsWith('refreshShares')),
            isEmpty,
          );

          controller.emit(_state());
          await tester.pump();

          expect(controller.calls, contains('refreshShares $mineFp'));
        });

        testWidgets('someone else: the add button does not react', (
          tester,
        ) async {
          final controller = await pump(tester, _state(mine: false));
          await _openFromRow(tester, strings);

          await tester.tap(
            _inPanel(find.text(strings.sharesAdd)),
            warnIfMissed: false,
          );
          await tester.pump();

          expect(
            controller.calls.where((c) => c.startsWith('addShare')),
            isEmpty,
          );
        });
      },
    );

    group('[$code] E772 what could not be saved (RF-406)', () {
      testWidgets('sharesNotSaved offers a retry; the others do not', (
        tester,
      ) async {
        final controller = await pump(
          tester,
          _state(
            notices: const [
              Notice(id: 1, kind: NoticeKind.sharesNotSaved),
              Notice(id: 2, kind: NoticeKind.shareAddNotSaved),
              Notice(id: 3, kind: NoticeKind.peerNotesNotSaved),
            ],
          ),
        );

        expect(find.text(strings.noticeSharesNotSaved), findsOneWidget);
        expect(find.text(strings.noticeShareAddNotSaved), findsOneWidget);
        expect(find.text(strings.noticePeerNotesNotSaved), findsOneWidget);
        expect(find.text(strings.retryButton), findsOneWidget);

        await tester.tap(find.text(strings.retryButton));
        await tester.pump();

        expect(controller.calls, contains('retrySave'));
      });
    });

    group('[$code] E773 favourites (RF-428)', () {
      testWidgets('Add opens the browser and saves the open folder', (
        tester,
      ) async {
        final controller = await pump(tester, _state());
        controller
          ..rootsResult = ((_) async => const RemoteRoots([rootDocs]))
          ..foldersResult = (_, _, _) async =>
              const RemoteFolders(['fotos'], more: false, partial: false);
        await _openFromRow(tester, strings);

        await tester.tap(_inPanel(find.text(strings.favoritesAdd)));
        await _settle(tester);
        expect(find.byType(FolderNavigator), findsOneWidget);
        expect(find.text(strings.navNewFolder), findsNothing);

        await tester.tap(find.text('Documentos'));
        await _settle(tester);
        await tester.tap(find.text(strings.navSaveFavorite));
        await _settle(tester);

        expect(controller.calls, contains('addFavorite $mineFp root-docs'));
        expect(find.byType(FolderNavigator), findsNothing);
      });

      testWidgets('it lists them and the X removes one', (tester) async {
        final controller = await pump(tester, _state(favorites: [favPhotos]));
        await _openFromRow(tester, strings);

        final row = _inPanel(find.textContaining('fotos'));
        await _scrollTo(tester, row);
        await tester.tap(
          _inPanel(find.byTooltip(strings.favoriteRemoveTooltip)),
        );
        await tester.pump();

        expect(controller.calls, contains('removeFavorite $mineFp 0'));
      });

      testWidgets('out of sight, Add is disabled with the explanation', (
        tester,
      ) async {
        final controller = await pump(tester, _state(visible: false));
        await _openFromRow(tester, strings);

        expect(
          _inPanel(find.text(strings.favoritesNeedVisible)),
          findsOneWidget,
        );
        await tester.tap(
          _inPanel(find.text(strings.favoritesAdd)),
          warnIfMissed: false,
        );
        await tester.pump();

        expect(controller.rootRequests, 0);
      });

      testWidgets('without folders it explains and opens no browser', (
        tester,
      ) async {
        final controller = await pump(tester, _state());
        controller.rootsResult = (_) async => const RemoteRoots([]);
        await _openFromRow(tester, strings);

        await tester.tap(_inPanel(find.text(strings.favoritesAdd)));
        await _settle(tester);

        expect(find.byType(FolderNavigator), findsNothing);
        expect(
          _inPanel(find.text(strings.destNoChoice(mineName))),
          findsOneWidget,
        );
      });
    });

    group('[$code] E774 the nickname (RF-429)', () {
      testWidgets('typing saves 400 ms after the last key, emptying removes '
          'it', (tester) async {
        final controller = await pump(tester, _state(alias: 'Curro'));
        await _openFromRow(tester, strings);
        final field = _inPanel(find.byType(TextField));
        await _scrollTo(tester, field);

        await tester.enterText(field, '  Nuevo  ');
        await tester.pump(const Duration(milliseconds: 350));
        expect(
          controller.calls.where((c) => c.startsWith('setAlias')),
          isEmpty,
        );
        await tester.pump(const Duration(milliseconds: 60));
        expect(controller.calls, contains('setAlias $mineFp Nuevo'));

        await tester.enterText(field, '');
        await tester.pump(const Duration(milliseconds: 410));
        expect(controller.calls, contains('setAlias $mineFp '));
      });

      testWidgets('it replaces the name in the list and the diagram', (
        tester,
      ) async {
        await pump(tester, _state(alias: 'Curro'));

        expect(
          find.descendant(
            of: find.byKey(ValueKey(mineFp)),
            matching: find.text('Curro'),
          ),
          findsOneWidget,
        );
        expect(
          find.descendant(
            of: find.byKey(ValueKey(mineFp)),
            matching: find.text(mineName),
          ),
          findsNothing,
        );
      });

      testWidgets('the field takes at most 64 characters', (tester) async {
        await pump(tester, _state());
        await _openFromRow(tester, strings);
        final field = _inPanel(find.byType(TextField));
        await _scrollTo(tester, field);

        await tester.enterText(field, 'x' * 70);
        await tester.pump();

        expect(
          tester.widget<TextField>(field).controller!.text.length,
          lessThanOrEqualTo(64),
        );
      });

      testWidgets('the help names the real name', (tester) async {
        await pump(tester, _state(alias: 'Curro'));
        await _openFromRow(tester, strings);
        final help = _inPanel(find.text(strings.aliasHelp(mineName)));

        await _scrollTo(tester, help);

        expect(help, findsOneWidget);
      });
    });

    group('[$code] E775 the history (RF-430)', () {
      List<HistoryEntryView> many() => [
        _history(0),
        _history(
          1,
          name: 'lote.txt',
          itemCount: 4,
          delivered: 3,
          destination: const DestinationLabel(
            rootName: 'Documentos',
            home: false,
            path: ['obra'],
          ),
        ),
        for (var i = 2; i < 23; i++)
          _history(i, direction: HistoryDirection.received),
      ];

      testWidgets('three entries and See all (23), that keeps the rest', (
        tester,
      ) async {
        await pump(tester, _state(history: many()));
        await _openFromRow(tester, strings);
        final seeAll = _inPanel(find.text(strings.historySeeAll(23)));

        await _scrollTo(tester, seeAll);

        expect(seeAll, findsOneWidget);
        expect(_inPanel(find.text('archivo-0.txt')), findsOneWidget);
        expect(_inPanel(find.text('archivo-2.txt')), findsOneWidget);
        expect(_inPanel(find.text('archivo-3.txt')), findsNothing);
      });

      testWidgets('See all shows them; the arrow goes back', (tester) async {
        await pump(tester, _state(history: many()));
        await _openFromRow(tester, strings);
        final seeAll = _inPanel(find.text(strings.historySeeAll(23)));
        await _scrollTo(tester, seeAll);

        await tester.tap(seeAll);
        await _settle(tester);

        expect(find.byTooltip(strings.historyBack), findsOneWidget);
        expect(
          find.textContaining(strings.historyFirstAndMore('lote.txt', 3)),
          findsWidgets,
        );
        expect(
          find.textContaining(strings.historyDelivered(3, 4)),
          findsWidgets,
        );

        await tester.tap(find.byTooltip(strings.historyBack));
        await _settle(tester);

        expect(_panel, findsOneWidget);
        expect(find.byTooltip(strings.historyBack), findsNothing);
        expect(_inPanel(find.text(strings.historySeeAll(23))), findsOneWidget);
      });

      testWidgets('Esc goes back to Configure instead of closing it', (
        tester,
      ) async {
        await pump(tester, _state(history: many()));
        await _openFromRow(tester, strings);
        final seeAll = _inPanel(find.text(strings.historySeeAll(23)));
        await _scrollTo(tester, seeAll);
        await tester.tap(seeAll);
        await _settle(tester);

        await tester.sendKeyEvent(LogicalKeyboardKey.escape);
        await _settle(tester);

        expect(_panel, findsOneWidget);
        expect(find.byTooltip(strings.historyBack), findsNothing);
      });

      testWidgets('with no history it says so', (tester) async {
        await pump(tester, _state());
        await _openFromRow(tester, strings);
        final empty = _inPanel(find.text(strings.historyEmpty));

        await _scrollTo(tester, empty);

        expect(empty, findsOneWidget);
      });
    });

    group('[$code] E774 the nickname on cards and notices (RF-429)', () {
      Finder shownName(Finder scope, String name) => find.descendant(
        of: scope,
        matching: find.byWidgetPredicate(
          (widget) =>
              widget is Text &&
              (widget.data ?? widget.textSpan?.toPlainText() ?? '')
                  .replaceAll('\u200B', '')
                  .replaceAll('\u2060', '')
                  .contains(name),
          description: 'text with "$name"',
        ),
      );

      testWidgets('the queue card and the result card show the nickname '
          'with the real name, never twice the nickname', (tester) async {
        final base = _state(alias: 'Curro');
        await pump(
          tester,
          NodeState(
            entries: base.entries,
            peers: base.peers,
            queues: SendQueuesView(
              selectionId: 1,
              peerFingerprint: mineFp,
              peerName: mineName,
              loose: const [
                QueueItemView(
                  id: 'q1',
                  name: 'acta.pdf',
                  isFolder: false,
                  isArchive: false,
                  state: QueueItemState.inProgress,
                ),
                QueueItemView(
                  id: 'q2',
                  name: 'zeta.txt',
                  isFolder: false,
                  isArchive: false,
                  state: QueueItemState.pending,
                ),
              ],
              bundles: const [],
              finished: false,
              delivered: 0,
              total: 2,
              completedBytes: 0,
              pendingKnownBytes: 0,
              currentProbeSize: null,
            ),
            lastReceived: TransferResultView(
              direction: TransferDirection.incoming,
              peerFingerprint: mineFp,
              peerName: mineName,
              fileName: 'foto.jpg',
              isProgram: false,
              outcome: TransferOutcome.saved,
              canReveal: false,
            ),
            transferInProgress: true,
          ),
        );

        final both = strings.nameWithReal('Curro', mineName);
        final queue = find.byType(QueueCard);
        final result = find.byType(ResultCard);
        expect(queue, findsOneWidget);
        expect(result, findsOneWidget);
        expect(shownName(queue, both), findsWidgets);
        expect(shownName(result, both), findsWidgets);
        expect(shownName(queue, 'Curro (Curro)'), findsNothing);
        expect(shownName(result, 'Curro (Curro)'), findsNothing);
      });

      testWidgets('a result of what was not sent shows the nickname with '
          'the real name', (tester) async {
        final base = _state(alias: 'Curro');
        await pump(
          tester,
          NodeState(
            entries: base.entries,
            peers: base.peers,
            lastSent: TransferResultView(
              direction: TransferDirection.outgoing,
              peerFingerprint: mineFp,
              peerName: mineName,
              fileName: 'zeta.txt',
              isProgram: false,
              outcome: TransferOutcome.noContact,
              canReveal: false,
            ),
          ),
        );

        final result = find.byType(ResultCard);
        expect(result, findsOneWidget);
        expect(
          shownName(result, strings.nameWithReal('Curro', mineName)),
          findsWidgets,
        );
        expect(shownName(result, 'Curro (Curro)'), findsNothing);
      });
    });

    group('[$code] E791 the home folder in Configure (point 8)', () {
      testWidgets('its own share and a favourite read as the home folder', (
        tester,
      ) async {
        await pump(
          tester,
          _state(
            shares: const [_shareHome],
            favorites: const [
              SavedDestination(
                rootId: 'r',
                rootName: 'david',
                home: true,
                path: [],
              ),
            ],
          ),
        );
        await _openFromRow(tester, strings);

        expect(_inPanel(find.text(strings.homeFolder)), findsWidgets);
        expect(_inPanel(find.text('david')), findsNothing);
      });
    });

    group('[$code] the app never shows paths of the other device', () {
      testWidgets('favourites and history show labels only', (tester) async {
        await pump(
          tester,
          _state(
            favorites: [favPhotos],
            history: [
              _history(
                0,
                destination: const DestinationLabel(
                  rootName: 'Documentos',
                  home: false,
                  path: ['obra'],
                ),
              ),
            ],
          ),
        );
        await _openFromRow(tester, strings);

        expect(
          visibleTexts(tester)
              .where((text) => RegExp(r'^[A-Za-z]:\\').hasMatch(text)),
          isEmpty,
        );
      });
    });

    group('[$code] layout (E775, 760x520 and text at 200%)', () {
      testWidgets('760x520: everything scrolls without overflowing', (
        tester,
      ) async {
        await pump(
          tester,
          _state(
            shares: const [_shareDocs, _shareUsb],
            favorites: [favPhotos],
            history: [for (var i = 0; i < 5; i++) _history(i)],
          ),
          size: const Size(760, 520),
        );
        await tester.tap(find.text(strings.devicesTab));
        await _settle(tester);
        await _openFromRow(tester, strings);

        expect(tester.takeException(), isNull);
        await _scrollTo(
          tester,
          _inPanel(find.text(strings.unpairSectionTitle)),
        );
        expect(tester.takeException(), isNull);
      });

      testWidgets('text at 200%: no overflow', (tester) async {
        await pump(
          tester,
          _state(
            shares: const [_shareDocs, _shareUsb],
            favorites: [favPhotos],
            history: [for (var i = 0; i < 5; i++) _history(i)],
          ),
          textScale: 2,
        );
        await _openFromRow(tester, strings);

        expect(tester.takeException(), isNull);
        await _scrollTo(
          tester,
          _inPanel(find.text(strings.unpairSectionTitle)),
        );
        expect(tester.takeException(), isNull);
      });
    });
  }
}
