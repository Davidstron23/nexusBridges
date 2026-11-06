import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nexus_bridges/src/l10n/app_strings.dart';
import 'package:nexus_bridges/src/ui/destination/destination_menu.dart';
import 'package:nexus_bridges/src/ui/destination/folder_navigator.dart';
import 'package:nexus_bridges/src/ui/destination/navigator_controller.dart';
import 'package:nexus_bridges/src/ui/icons/file_icon.dart';
import 'package:nexus_bridges/src/ui/icons/folder_icon.dart';
import 'package:nexus_bridges/src/ui/theme/app_theme.dart';
import 'package:nexus_bridges/src/ui/tray_panel.dart';
import 'package:nexus_bridges_core/nexus_bridges_core.dart';

import '../fake_app_controller.dart';
import '../segoe_font.dart';
import 'destination_fixtures.dart';

final Finder _menu = find.byType(DestinationMenu);
final Finder _navigator = find.byType(FolderNavigator);

Finder _inMenu(Finder finder) => find.descendant(of: _menu, matching: finder);

NavRow _row(WidgetTester tester, String label) => tester.widget<NavRow>(
  find.ancestor(of: find.text(label), matching: find.byType(NavRow)).first,
);

Future<void> _openFromRow(
  WidgetTester tester,
  AppStrings strings,
  String option,
) async {
  await tester.tap(
    find.descendant(
      of: find.byKey(ValueKey(mineFp)),
      matching: find.text(strings.sendFilesEllipsis),
    ),
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 240));
  await tester.tap(find.text(option));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 300));
  await settleMenu(tester);
}

Future<void> _open(
  WidgetTester tester,
  AppStrings strings,
  FakeAppController controller,
) async {
  controller.pickedPaths = sentPaths;
  await _openFromRow(tester, strings, strings.sendFilesOption);
}

Future<void> _openExplorer(WidgetTester tester, AppStrings strings) async {
  await tester.pump(const Duration(milliseconds: 400));
  await tester.tap(find.text(strings.destExplore));
  await settleNav(tester);
  expect(_navigator, findsOneWidget);
}

Future<void> _enter(WidgetTester tester, String name) async {
  await tester.tap(find.text(name));
  await settleNav(tester);
}

void main() {
  setUpAll(loadSegoe);

  for (final code in languageCodes) {
    final strings = stringsFor(code);
    final home = strings.homeFolder;

    group('[$code] the header icon is found off the build (B6)', () {
      testWidgets('one check per menu, outside build, and the folder icon '
          'comes when the answer does', (tester) async {
        final original = destinationPathIsDirectory;
        addTearDown(() => destinationPathIsDirectory = original);
        final answer = Completer<bool>();
        final asked = <String>[];
        destinationPathIsDirectory = (path) {
          asked.add(path);
          return answer.future;
        };
        final (controller, events) = await pumpDestinationHome(
          tester,
          code,
          destinationState(),
        );
        controller.rootsResult = (_) async => const RemoteRoots([rootDocs]);

        await dropOn(tester, events, rowOf(tester, mineFp));
        await settleMenu(tester);

        expect(_menu, findsOneWidget);
        expect(asked, [sentPaths.first]);
        expect(_inMenu(find.byType(FileIcon)), findsOneWidget);
        expect(_inMenu(find.byType(FolderIcon)), findsNothing);

        answer.complete(true);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 500));

        expect(_inMenu(find.byType(FileIcon)), findsNothing);
        expect(
          find.descendant(
            of: _inMenu(find.byType(Row)),
            matching: find.byType(FolderIcon),
          ),
          findsWidgets,
        );
        expect(asked, hasLength(1));
      });
    });

    group('[$code] E776 the menu order and how it closes (RF-419)', () {
      for (final (surface, at) in <(String, Offset Function(WidgetTester))>[
        ('row', (tester) => rowOf(tester, mineFp)),
        ('disc', (tester) => discOf(tester, mineFp)),
      ]) {
        testWidgets('a drop on the $surface of a device of mine opens the '
            'menu and sends nothing until a choice', (tester) async {
          final (controller, events) = await pumpDestinationHome(
            tester,
            code,
            destinationState(),
          );
          controller.rootsResult = (_) async => const RemoteRoots([rootDocs]);

          await dropOn(tester, events, at(tester));
          await settleMenu(tester);

          expect(controller.sendPathsCalls, isEmpty);
          expect(_menu, findsOneWidget);

          await tester.tap(_inMenu(find.text('Documentos')));
          await settleMenu(tester);
          expect(controller.sendPathsCalls, [sentPaths]);
          expect(controller.sendDestinations.single!.rootId, rootDocs.id);
        });
      }

      testWidgets('favourites, default folder and roots, recent, Browse', (
        tester,
      ) async {
        final (controller, _) = await pumpDestinationHome(
          tester,
          code,
          destinationState(favorites: [favPhotos], recent: [recentWork]),
        );
        controller.rootsResult = (_) async =>
            const RemoteRoots([rootDocs, rootHome], checks: [true, true]);

        await _open(tester, strings, controller);

        expect(_menu, findsOneWidget);
        expect(controller.sendPathsCalls, isEmpty);
        final tops = [
          topOf(tester, strings.destFavorites),
          topOf(tester, r'Documentos\fotos'),
          topOf(tester, strings.destDefaultFolder),
          topOf(tester, 'Documentos'),
          topOf(tester, home),
          topOf(tester, strings.destRecent),
          topOf(tester, r'Documentos\obra'),
          topOf(tester, strings.destExplore),
        ];
        expect(tops, orderedEquals([...tops]..sort()));
        expect(controller.rootChecks.single, [favPhotos, recentWork]);
      });

      testWidgets('the arrows and Enter send to the focused destination', (
        tester,
      ) async {
        final (controller, _) = await pumpDestinationHome(
          tester,
          code,
          destinationState(favorites: [favPhotos]),
        );
        controller.rootsResult = (_) async =>
            const RemoteRoots([rootDocs], checks: [true]);

        await _open(tester, strings, controller);
        await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
        await tester.pump();
        await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
        await tester.pump();
        await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
        await tester.pump();
        await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
        await tester.pump();
        await tester.sendKeyEvent(LogicalKeyboardKey.enter);
        await settleMenu(tester);

        expect(controller.sendPathsCalls, [sentPaths]);
        final destination = controller.sendDestinations.single!;
        expect(destination.rootId, rootDocs.id);
        expect(destination.path, isEmpty);
        expect(_menu, findsNothing);
      });

      testWidgets('choosing a favourite sends there with the dropped paths', (
        tester,
      ) async {
        final (controller, _) = await pumpDestinationHome(
          tester,
          code,
          destinationState(favorites: [favPhotos]),
        );
        controller.rootsResult = (_) async =>
            const RemoteRoots([rootDocs], checks: [true]);

        await _open(tester, strings, controller);
        await tester.tap(find.text(r'Documentos\fotos'));
        await settleMenu(tester);

        expect(controller.sendPathsCalls, [sentPaths]);
        expect(controller.sendDestinations.single!.path, ['fotos']);
      });

      testWidgets('the default folder is sent without a destination', (
        tester,
      ) async {
        final (controller, _) = await pumpDestinationHome(
          tester,
          code,
          destinationState(),
        );
        controller.rootsResult = (_) async => const RemoteRoots([rootDocs]);

        await _open(tester, strings, controller);
        await tester.tap(find.text(strings.destDefaultFolder));
        await settleMenu(tester);

        expect(controller.sendPathsCalls, [sentPaths]);
        expect(controller.sendDestinations.single, isNull);
      });

      testWidgets('Esc does not send anything', (tester) async {
        final (controller, _) = await pumpDestinationHome(
          tester,
          code,
          destinationState(),
        );
        controller.rootsResult = (_) async => const RemoteRoots([rootDocs]);

        await _open(tester, strings, controller);
        await tester.sendKeyEvent(LogicalKeyboardKey.escape);
        await settleMenu(tester);

        expect(_menu, findsNothing);
        expect(controller.sendPathsCalls, isEmpty);
      });

      testWidgets('a click outside does not send anything', (tester) async {
        final (controller, _) = await pumpDestinationHome(
          tester,
          code,
          destinationState(),
        );
        controller.rootsResult = (_) async => const RemoteRoots([rootDocs]);

        await _open(tester, strings, controller);
        final rect = tester.getRect(_menu);
        await tester.tapAt(
          Offset(rect.right > 1000 ? rect.left - 40 : rect.right + 40, 20),
        );
        await settleMenu(tester);

        expect(_menu, findsNothing);
        expect(controller.sendPathsCalls, isEmpty);
      });

      for (final (label, option, call) in [
        ('Files…', strings.sendFilesOption, 'pickFilesFor'),
        ('Folders…', strings.sendFoldersOption, 'pickFoldersFor'),
      ]) {
        testWidgets('$label picks first and then opens the menu', (
          tester,
        ) async {
          final (controller, _) = await pumpDestinationHome(
            tester,
            code,
            destinationState(),
          );
          controller
            ..pickedPaths = sentPaths
            ..rootsResult = (_) async => const RemoteRoots([rootDocs]);

          await _openFromRow(tester, strings, option);

          expect(controller.calls.first, '$call $mineFp');
          expect(_menu, findsOneWidget);
          expect(controller.sendPathsCalls, isEmpty);

          await tester.tap(_inMenu(find.text('Documentos')));
          await settleMenu(tester);
          expect(controller.sendPathsCalls, [sentPaths]);
          expect(controller.sendDestinations.single!.rootId, rootDocs.id);
        });
      }

      testWidgets('cancelling the picker opens no menu', (tester) async {
        final (controller, _) = await pumpDestinationHome(
          tester,
          code,
          destinationState(),
        );

        await _openFromRow(tester, strings, strings.sendFilesOption);

        expect(_menu, findsNothing);
        expect(controller.sendPathsCalls, isEmpty);
      });

      testWidgets('Send to from the tray opens the menu and sends the tray', (
        tester,
      ) async {
        final (controller, _) = await pumpDestinationHome(
          tester,
          code,
          destinationState(
            tray: const [
              TrayItemView(id: 't1', name: 'informe.pdf', isFolder: false),
            ],
          ),
        );
        controller.rootsResult = (_) async => const RemoteRoots([rootDocs]);

        final button = find.descendant(
          of: find.byType(TrayPanel),
          matching: find.text(strings.traySendTo(mineName)),
        );
        await tester.ensureVisible(button);
        await tester.pump();
        await tester.tap(button);
        await settleMenu(tester);

        expect(_menu, findsOneWidget);
        expect(
          controller.calls.where((c) => c.startsWith('sendTray')),
          isEmpty,
        );

        await tester.tap(_inMenu(find.text('Documentos')));
        await settleMenu(tester);
        expect(controller.calls, contains('sendTray $mineFp'));
        expect(controller.sendDestinations.single!.rootId, rootDocs.id);
      });

      testWidgets('SendResult.tooMany shows its message after choosing', (
        tester,
      ) async {
        final (controller, _) = await pumpDestinationHome(
          tester,
          code,
          destinationState(),
        );
        controller
          ..rootsResult = ((_) async => const RemoteRoots([rootDocs]))
          ..sendPathsResult = SendResult.tooMany;

        await _open(tester, strings, controller);
        await tester.tap(find.text(strings.destDefaultFolder));
        await settleMenu(tester);
        await tester.pump(const Duration(milliseconds: 750));

        expect(find.text(strings.tooManySelected), findsOneWidget);
      });
    });

    group('[$code] E777 someone else sends without a menu (RF-420)', () {
      testWidgets('a drop goes to the default folder and asks for nothing', (
        tester,
      ) async {
        final (controller, events) = await pumpDestinationHome(
          tester,
          code,
          destinationState(),
        );

        await dropOn(tester, events, rowOf(tester, foreignFp));
        await settleMenu(tester);

        expect(_menu, findsNothing);
        expect(controller.sendPathsCalls, [sentPaths]);
        expect(controller.sendDestinations.single, isNull);
        expect(controller.rootRequests, 0);
      });

      testWidgets('Files… sends with the 006 path and opens no menu', (
        tester,
      ) async {
        final (controller, _) = await pumpDestinationHome(
          tester,
          code,
          destinationState(),
        );

        await tester.tap(
          find.descendant(
            of: find.byKey(ValueKey(foreignFp)),
            matching: find.text(strings.sendFilesEllipsis),
          ),
        );
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 240));
        await tester.tap(find.text(strings.sendFilesOption));
        await settleMenu(tester);

        expect(controller.calls, ['sendFiles $foreignFp']);
        expect(_menu, findsNothing);
      });
    });

    group('[$code] E778 no choice of folder (RF-421)', () {
      Future<void> expectNoChoice(
        WidgetTester tester,
        DelegatingController controller,
      ) async {
        expect(find.text(strings.destNoChoice(mineName)), findsOneWidget);
        expect(find.text(strings.destExplore), findsNothing);
        expect(find.text(strings.destDefaultFolder), findsOneWidget);
        expect(_row(tester, strings.destDefaultFolder).enabled, isTrue);
        expect(_row(tester, r'Documentos\fotos').enabled, isFalse);
        expect(_row(tester, r'Documentos\obra').enabled, isFalse);
        await tester.tap(find.text(r'Documentos\fotos'), warnIfMissed: false);
        await settleMenu(tester);
        expect(controller.sendPathsCalls, isEmpty);
      }

      final failures = <String, FutureOr<RemoteListing> Function()>{
        'no roots': () => const RemoteRoots([]),
        'not allowed': () =>
            const RemoteListingFailed(BrowseFailure.notAllowed),
        'busy': () => const RemoteListingFailed(BrowseFailure.busy),
        'no answer': () => const RemoteListingFailed(BrowseFailure.noAnswer),
        'not visible': () =>
            const RemoteListingFailed(BrowseFailure.notVisible),
      };
      for (final MapEntry(key: name, value: result) in failures.entries) {
        testWidgets('$name: default folder, one explanation, disabled rows', (
          tester,
        ) async {
          final (controller, _) = await pumpDestinationHome(
            tester,
            code,
            destinationState(favorites: [favPhotos], recent: [recentWork]),
          );
          controller.rootsResult = (_) async => result();

          await _open(tester, strings, controller);

          await expectNoChoice(tester, controller);
        });
      }

      testWidgets('2 s without an answer is the same, and an answer at 3 s '
          'changes nothing', (tester) async {
        final (controller, _) = await pumpDestinationHome(
          tester,
          code,
          destinationState(favorites: [favPhotos], recent: [recentWork]),
        );
        final pending = Completer<RemoteListing>();
        controller.rootsResult = (_) => pending.future;

        await _open(tester, strings, controller);
        expect(find.text(strings.destLoading), findsOneWidget);
        expect(_row(tester, r'Documentos\fotos').enabled, isTrue);

        await tester.pump(const Duration(milliseconds: 1400));
        expect(find.text(strings.destNoChoice(mineName)), findsNothing);
        await tester.pump(const Duration(milliseconds: 400));
        await tester.pump();

        await expectNoChoice(tester, controller);

        await tester.pump(const Duration(seconds: 1));
        pending.complete(const RemoteRoots([rootDocs], checks: [true, true]));
        await settleMenu(tester);

        await expectNoChoice(tester, controller);
        expect(_inMenu(find.text('Documentos')), findsNothing);
      });

      testWidgets('with no answer the default folder can still be chosen', (
        tester,
      ) async {
        final (controller, _) = await pumpDestinationHome(
          tester,
          code,
          destinationState(),
        );
        controller.rootsResult = (_) async =>
            const RemoteListingFailed(BrowseFailure.noAnswer);

        await _open(tester, strings, controller);
        await tester.tap(find.text(strings.destDefaultFolder));
        await settleMenu(tester);

        expect(controller.sendPathsCalls, [sentPaths]);
        expect(controller.sendDestinations.single, isNull);
      });
    });

    group('[$code] E779 destinations no longer available (RF-422)', () {
      testWidgets('check false disables them with the explanation, and a '
          'favourite whose root left too', (tester) async {
        const lost = SavedDestination(
          rootId: 'root-gone',
          rootName: 'Quitada',
          path: [],
        );
        final (controller, _) = await pumpDestinationHome(
          tester,
          code,
          destinationState(favorites: [favPhotos, lost], recent: [recentWork]),
        );
        controller.rootsResult = (_) async =>
            const RemoteRoots([rootDocs], checks: [false, true, false]);

        await _open(tester, strings, controller);

        expect(_row(tester, r'Documentos\fotos').enabled, isFalse);
        expect(_row(tester, 'Quitada').enabled, isFalse);
        expect(_row(tester, r'Documentos\obra').enabled, isFalse);
        expect(find.byTooltip(strings.destNoLongerAvailable), findsNWidgets(3));
        await tester.tap(find.text('Quitada'), warnIfMissed: false);
        await settleMenu(tester);
        expect(controller.sendPathsCalls, isEmpty);
        expect(
          controller.calls.where((c) => c.contains('removeFavorite')),
          isEmpty,
        );
      });

      testWidgets('an unavailable root stays listed and cannot be chosen', (
        tester,
      ) async {
        final (controller, _) = await pumpDestinationHome(
          tester,
          code,
          destinationState(),
        );
        controller.rootsResult = (_) async =>
            const RemoteRoots([rootDocs, rootUsb]);

        await _open(tester, strings, controller);

        expect(_row(tester, 'Pendrive').enabled, isFalse);
        expect(_row(tester, 'Documentos').enabled, isTrue);
      });
    });

    group('[$code] E780 Browse (RF-423)', () {
      Future<DelegatingController> openBrowse(WidgetTester tester) async {
        final (controller, _) = await pumpDestinationHome(
          tester,
          code,
          destinationState(),
        );
        controller
          ..rootsResult = ((_) async => const RemoteRoots([rootDocs, rootHome]))
          ..foldersResult = (_, rootId, path) async {
            if (path.isEmpty) {
              return const RemoteFolders(
                ['fotos', 'obra'],
                more: false,
                partial: false,
              );
            }
            if (path.last == 'fotos') {
              return const RemoteFolders(['2026'], more: false, partial: false);
            }
            return const RemoteFolders([], more: false, partial: false);
          };
        await _open(tester, strings, controller);
        await _openExplorer(tester, strings);
        return controller;
      }

      testWidgets('navigate, breadcrumbs, Back down to the roots, Send here', (
        tester,
      ) async {
        final controller = await openBrowse(tester);

        expect(find.text('Documentos'), findsOneWidget);
        expect(find.text(home), findsOneWidget);
        await _enter(tester, 'Documentos');
        await _enter(tester, 'fotos');
        expect(find.text('2026'), findsOneWidget);
        expect(find.text(strings.navIn('fotos')), findsOneWidget);
        expect(
          controller.calls.where((c) => c.startsWith('listRemoteFolders')),
          [
            'listRemoteFolders $mineFp root-docs ',
            'listRemoteFolders $mineFp root-docs fotos',
          ],
        );

        await tester.tap(find.byTooltip(strings.navBack));
        await settleNav(tester);
        expect(find.text('obra'), findsOneWidget);
        expect(
          controller.calls.where((c) => c.startsWith('listRemoteFolders')),
          hasLength(2),
        );

        await tester.tap(find.byTooltip(strings.navBack));
        await settleNav(tester);
        expect(find.text(home), findsOneWidget);
        expect(
          tester
              .widget<FilledButton>(
                find.widgetWithText(FilledButton, strings.navSendHere),
              )
              .onPressed,
          isNull,
        );

        await _enter(tester, 'Documentos');
        await _enter(tester, 'obra');
        await tester.tap(find.text(strings.navSendHere));
        await settleNav(tester);

        final destination = controller.sendDestinations.single!;
        expect(destination.rootId, rootDocs.id);
        expect(destination.path, ['obra']);
        expect(destination.newFolder, isNull);
        expect(_menu, findsNothing);
      });

      testWidgets('a breadcrumb jumps back and asks for nothing', (
        tester,
      ) async {
        final controller = await openBrowse(tester);
        await _enter(tester, 'Documentos');
        await _enter(tester, 'fotos');

        await tester.tap(
          find.descendant(of: _navigator, matching: find.text('Documentos')),
        );
        await settleNav(tester);

        expect(find.text('obra'), findsOneWidget);
        expect(
          controller.calls.where((c) => c.startsWith('listRemoteFolders')),
          hasLength(2),
        );
      });

      testWidgets('more and partial are said', (tester) async {
        final controller = await openBrowse(tester);
        controller.foldersResult = (_, _, _) async =>
            const RemoteFolders(['fotos'], more: true, partial: true);

        await _enter(tester, 'Documentos');

        expect(find.text(strings.navMore), findsOneWidget);
        expect(find.text(strings.navPartial), findsOneWidget);
      });

      for (final reason in [
        BrowseFailure.unavailable,
        BrowseFailure.notAllowed,
      ]) {
        testWidgets('${reason.name} explains and goes back to the roots', (
          tester,
        ) async {
          final controller = await openBrowse(tester);
          await _enter(tester, 'Documentos');
          controller.foldersResult = (_, _, _) async =>
              RemoteListingFailed(reason);

          await _enter(tester, 'fotos');

          expect(find.text(strings.navGone), findsOneWidget);
          expect(find.text(home), findsOneWidget);
          expect(find.text('obra'), findsNothing);
        });
      }

      testWidgets('busy stays where it was and says so', (tester) async {
        final controller = await openBrowse(tester);
        await _enter(tester, 'Documentos');
        controller.foldersResult = (_, _, _) async =>
            const RemoteListingFailed(BrowseFailure.busy);

        await _enter(tester, 'fotos');

        expect(find.text(strings.navBusy(mineName)), findsOneWidget);
        expect(find.text('obra'), findsOneWidget);
      });

      testWidgets('a late answer after Back is ignored', (tester) async {
        final controller = await openBrowse(tester);
        await _enter(tester, 'Documentos');
        final pending = Completer<RemoteListing>();
        controller.foldersResult = (_, _, _) => pending.future;

        await tester.tap(find.text('fotos'));
        await tester.pump();
        await tester.tap(find.byTooltip(strings.navBack));
        await settleNav(tester);
        expect(find.text(home), findsOneWidget);

        pending.complete(
          const RemoteFolders(['tarde'], more: false, partial: false),
        );
        await settleNav(tester);

        expect(find.text('tarde'), findsNothing);
        expect(find.text(home), findsOneWidget);
      });

      testWidgets('the default folder has no way in: only roots are listed', (
        tester,
      ) async {
        await openBrowse(tester);

        expect(find.text(strings.destDefaultFolder), findsNothing);
      });

      testWidgets('it never shows anything that is not a folder name', (
        tester,
      ) async {
        await openBrowse(tester);
        await _enter(tester, 'Documentos');

        final texts = visibleTexts(tester);
        expect(texts.where((t) => t.contains(r':\')), isEmpty);
      });

      testWidgets('with the keyboard: Esc goes back to the menu and then '
          'closes, without sending', (tester) async {
        final controller = await openBrowse(tester);

        await tester.sendKeyEvent(LogicalKeyboardKey.escape);
        await settleNav(tester);

        expect(_navigator, findsNothing);
        expect(_menu, findsOneWidget);

        await tester.sendKeyEvent(LogicalKeyboardKey.escape);
        await settleNav(tester);

        expect(_menu, findsNothing);
        expect(controller.sendPathsCalls, isEmpty);
      });

      testWidgets('with the keyboard: Enter enters and Backspace goes up, '
          'even in an empty folder', (tester) async {
        await openBrowse(tester);

        await tester.sendKeyEvent(LogicalKeyboardKey.enter);
        await settleNav(tester);
        expect(find.text('fotos'), findsOneWidget);

        await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
        await tester.pump();
        await tester.sendKeyEvent(LogicalKeyboardKey.enter);
        await settleNav(tester);
        expect(find.text(strings.navNoSubfolders), findsOneWidget);

        await tester.sendKeyEvent(LogicalKeyboardKey.backspace);
        await settleNav(tester);
        expect(find.text('fotos'), findsOneWidget);
      });
    });

    group('[$code] E781 a new folder (RF-424)', () {
      Future<FolderNavigatorController> pumpNavigator(
        WidgetTester tester,
        FakeAppController controller, {
        List<String> folders = const ['Fotos'],
        List<RemoteRoot> roots = const [rootDocs],
        String? enterRoot = 'root-docs',
        bool openField = true,
      }) async {
        await tester.binding.setSurfaceSize(const Size(600, 700));
        addTearDown(() => tester.binding.setSurfaceSize(null));
        controller.foldersResult = (_, _, _) async =>
            RemoteFolders(folders, more: false, partial: false);
        final navigator = FolderNavigatorController(
          app: controller,
          fingerprint: mineFp,
          roots: roots,
          mode: NavigatorMode.send,
        );
        addTearDown(navigator.dispose);
        if (enterRoot != null) await navigator.enterRoot(enterRoot);
        await tester.pumpWidget(
          MaterialApp(
            theme: buildTheme(Brightness.light),
            locale: Locale(code),
            supportedLocales: const [Locale('en'), Locale('es')],
            localizationsDelegates: const [
              AppStringsDelegate(),
              GlobalMaterialLocalizations.delegate,
              GlobalWidgetsLocalizations.delegate,
              GlobalCupertinoLocalizations.delegate,
            ],
            home: Scaffold(
              body: FolderNavigator(
                controller: navigator,
                deviceName: mineName,
                onPick: () {},
                onExit: () {},
              ),
            ),
          ),
        );
        await settleNav(tester);
        if (openField) {
          await tester.tap(find.text(strings.navNewFolder).last);
          await settleNav(tester);
        }
        return navigator;
      }

      Finder field() =>
          find.descendant(of: _navigator, matching: find.byType(TextField));

      for (final bad in ['a/b', 'con', 'nombre.', ' ', '..']) {
        testWidgets('"$bad" is not valid and says why', (tester) async {
          final controller = FakeAppController(state: destinationState());
          final navigator = await pumpNavigator(tester, controller);

          await tester.enterText(field(), bad);
          await tester.tap(find.text(strings.navCreate));
          await settleNav(tester);

          expect(find.text(strings.navNameInvalid), findsOneWidget);
          expect(navigator.insideNew, isFalse);
        });
      }

      for (final repository in ['.git', '.GIT', '.Git', 'GIT~1']) {
        testWidgets('"$repository" is refused here, like the receiver does, '
            'with its own message (B7)', (tester) async {
          final controller = FakeAppController(state: destinationState());
          final navigator = await pumpNavigator(tester, controller);

          await tester.enterText(field(), repository);
          await tester.tap(find.text(strings.navCreate));
          await settleNav(tester);

          expect(find.text(strings.navNameRepository), findsOneWidget);
          expect(find.text(strings.navNameInvalid), findsNothing);
          expect(navigator.insideNew, isFalse);
          expect(
            navigator.validateNewFolder(repository),
            NewFolderProblem.repository,
          );
        });
      }

      testWidgets('"git" and ".github" are ordinary names', (tester) async {
        final controller = FakeAppController(state: destinationState());
        final navigator = await pumpNavigator(tester, controller);

        expect(navigator.validateNewFolder('git'), isNull);
        expect(navigator.validateNewFolder('.github'), isNull);
      });

      testWidgets('subfolder names, crumbs and the footer hide U+200E, '
          'U+200F and U+061C, but the request keeps the real name (M3)', (
        tester,
      ) async {
        final controller = FakeAppController(state: destinationState());
        final navigator = await pumpNavigator(
          tester,
          controller,
          folders: const ['a\u200Eb', 'c\u200Fd', 'e\u061Cf'],
          openField: false,
        );

        for (final shown in ['ab', 'cd', 'ef']) {
          expect(
            find.descendant(of: _navigator, matching: find.text(shown)),
            findsOneWidget,
          );
        }
        await tester.tap(find.text('cd'));
        await settleNav(tester);

        expect(
          controller.calls.last,
          'listRemoteFolders $mineFp root-docs c\u200Fd',
        );
        expect(navigator.current?.path, ['c\u200Fd']);
        expect(
          find.descendant(of: _navigator, matching: find.text('cd')),
          findsNWidgets(2),
        );
        expect(
          find.descendant(
            of: _navigator,
            matching: find.text(strings.navIn('cd')),
          ),
          findsOneWidget,
        );
        final shownTexts = [
          for (final text in tester.widgetList<Text>(
            find.descendant(of: _navigator, matching: find.byType(Text)),
          ))
            text.data ?? text.textSpan?.toPlainText() ?? '',
        ];
        for (final text in shownTexts) {
          expect(text, isNot(contains('\u200E')));
          expect(text, isNot(contains('\u200F')));
          expect(text, isNot(contains('\u061C')));
        }
      });

      testWidgets('two roots with the same name are told apart by their id '
          '(B2)', (tester) async {
        final controller = FakeAppController(state: destinationState());
        final navigator = await pumpNavigator(
          tester,
          controller,
          roots: const [
            RemoteRoot(
              id: 'root-a',
              name: 'Datos',
              home: false,
              available: true,
            ),
            RemoteRoot(
              id: 'root-b',
              name: 'Datos',
              home: false,
              available: true,
            ),
          ],
          enterRoot: null,
          openField: false,
        );

        expect(
          find.descendant(of: _navigator, matching: find.text('Datos')),
          findsNWidgets(2),
        );
        await tester.tap(
          find.descendant(of: _navigator, matching: find.text('Datos')).at(1),
        );
        await settleNav(tester);

        expect(controller.calls.last, 'listRemoteFolders $mineFp root-b ');
        expect(navigator.current?.rootId, 'root-b');
      });

      testWidgets('a name already listed, ignoring case, says why', (
        tester,
      ) async {
        final controller = FakeAppController(state: destinationState());
        final navigator = await pumpNavigator(tester, controller);

        await tester.enterText(field(), 'FOTOS');
        await tester.tap(find.text(strings.navCreate));
        await settleNav(tester);

        expect(find.text(strings.navNameExists), findsOneWidget);
        expect(navigator.insideNew, isFalse);
      });

      testWidgets('a valid name is the destination, nothing is asked and a '
          'second one cannot be created inside it', (tester) async {
        final controller = FakeAppController(state: destinationState());
        final navigator = await pumpNavigator(tester, controller);
        final before = controller.calls.length;

        await tester.enterText(field(), 'prueba-007');
        await tester.tap(find.text(strings.navCreate));
        await settleNav(tester);

        expect(find.text(strings.navNewFolderEmpty(mineName)), findsOneWidget);
        expect(controller.calls.length, before);
        expect(navigator.current?.path, isEmpty);
        expect(navigator.current?.newFolder, 'prueba-007');
        expect(navigator.canCreateFolder, isFalse);
      });

      testWidgets('the row reads "Will be created on arrival"', (tester) async {
        final controller = FakeAppController(state: destinationState());
        await pumpNavigator(tester, controller);

        await tester.enterText(field(), 'prueba-007');
        await tester.tap(find.text(strings.navCreate));
        await settleNav(tester);

        expect(find.text(strings.navWillBeCreated), findsOneWidget);
      });

      testWidgets('inside the real menu the name field can be opened', (
        tester,
      ) async {
        final (controller, _) = await pumpDestinationHome(
          tester,
          code,
          destinationState(),
        );
        controller
          ..rootsResult = ((_) async => const RemoteRoots([rootDocs]))
          ..foldersResult = (_, _, _) async =>
              const RemoteFolders(['Fotos'], more: false, partial: false);
        await _open(tester, strings, controller);
        await _openExplorer(tester, strings);
        await _enter(tester, 'Documentos');

        await tester.tap(find.text(strings.navNewFolder).last);
        await settleNav(tester);

        expect(tester.takeException(), isNull);
        expect(
          find.descendant(of: _navigator, matching: find.byType(TextField)),
          findsOneWidget,
        );
      });
    });

    group('[$code] E782 an unreadable answer (RF-425)', () {
      testWidgets('in the menu: its explanation, and like no choice', (
        tester,
      ) async {
        final (controller, _) = await pumpDestinationHome(
          tester,
          code,
          destinationState(favorites: [favPhotos]),
        );
        controller.rootsResult = (_) async =>
            const RemoteListingFailed(BrowseFailure.unreadable);

        await _open(tester, strings, controller);

        expect(find.text(strings.destUnreadable(mineName)), findsOneWidget);
        expect(find.text(strings.destExplore), findsNothing);
        expect(_row(tester, r'Documentos\fotos').enabled, isFalse);
        expect(_row(tester, strings.destDefaultFolder).enabled, isTrue);
      });

      testWidgets('in Browse: its explanation and it stays', (tester) async {
        final (controller, _) = await pumpDestinationHome(
          tester,
          code,
          destinationState(),
        );
        controller
          ..rootsResult = ((_) async => const RemoteRoots([rootDocs]))
          ..foldersResult = (_, _, _) async =>
              const RemoteListingFailed(BrowseFailure.unreadable);
        await _open(tester, strings, controller);
        await _openExplorer(tester, strings);

        await _enter(tester, 'Documentos');

        expect(find.text(strings.navUnreadable(mineName)), findsOneWidget);
        expect(find.text('Documentos'), findsOneWidget);
      });
    });

    group('[$code] fewer animations (RF-423)', () {
      testWidgets('Browse opens without a layout error', (tester) async {
        final (controller, _) = await pumpDestinationHome(
          tester,
          code,
          destinationState(),
          reduceMotion: true,
        );
        controller.rootsResult = (_) async => const RemoteRoots([rootDocs]);

        await _open(tester, strings, controller);
        await _openExplorer(tester, strings);

        expect(tester.takeException(), isNull);
      });
    });

    group('[$code] E791 the home root in the menu and in Browse', () {
      testWidgets('reads as the home folder, never the user name', (
        tester,
      ) async {
        final (controller, _) = await pumpDestinationHome(
          tester,
          code,
          destinationState(),
        );
        controller.rootsResult = (_) async => const RemoteRoots([rootHome]);

        await _open(tester, strings, controller);
        expect(find.text(home), findsOneWidget);
        expect(find.text('david'), findsNothing);

        await _openExplorer(tester, strings);
        expect(find.text(home), findsOneWidget);
        expect(find.text('david'), findsNothing);
      });
    });
  }
}
