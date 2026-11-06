import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nexus_bridges/src/drop/drop_events.dart';
import 'package:nexus_bridges/src/l10n/app_strings.dart';
import 'package:nexus_bridges/src/ui/destination/destination_menu.dart';
import 'package:nexus_bridges/src/ui/portal/portal_controller.dart';
import 'package:nexus_bridges/src/ui/portal/portal_panel.dart';
import 'package:nexus_bridges_core/nexus_bridges_core.dart';

import '../../drop/fake_drop_events.dart';
import '../destination/destination_fixtures.dart';
import '../fake_app_controller.dart';
import '../segoe_font.dart';

final Finder _panel = find.byType(PortalPanel);
final Finder _menu = find.byType(DestinationMenu);

Finder _inPanel(Finder finder) => find.descendant(of: _panel, matching: finder);

Future<void> _settlePanel(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 500));
  await tester.pump();
}

Future<void> _hold(
  WidgetTester tester,
  FakeDropEvents events,
  Offset at,
) async {
  events.add(DropEnter(at));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 210));
  await tester.pump(const Duration(milliseconds: 300));
  await tester.pump();
}

Future<void> _over(
  WidgetTester tester,
  FakeDropEvents events,
  Offset at,
) async {
  events.add(DropOver(at));
  await tester.pump();
}

Future<void> _holdOnFolder(
  WidgetTester tester,
  FakeDropEvents events,
  String label,
) async {
  final at = tester.getCenter(_inPanel(find.text(label)));
  await _over(tester, events, at + const Offset(7, 0));
  await _over(tester, events, at);
  await tester.pump(const Duration(milliseconds: 510));
  await tester.pump();
  await _settlePanel(tester);
}

void _folders(DelegatingController controller) {
  controller.foldersResult = (_, rootId, path) async {
    if (path.isEmpty) {
      return const RemoteFolders(
        ['fotos', 'obra'],
        more: false,
        partial: false,
      );
    }
    return const RemoteFolders(['2026'], more: false, partial: false);
  };
}

void main() {
  setUpAll(loadSegoe);

  for (final code in languageCodes) {
    final strings = stringsFor(code);
    final home = strings.homeFolder;

    Future<(DelegatingController, FakeDropEvents)> pumpWithRoots(
      WidgetTester tester, {
      NodeState? state,
      Size size = const Size(1200, 800),
    }) async {
      final (controller, events) = await pumpDestinationHome(
        tester,
        code,
        state ?? destinationState(withOther: true),
        size: size,
      );
      controller.rootsResult = (_) async =>
          const RemoteRoots([rootDocs, rootHome, rootUsb]);
      _folders(controller);
      return (controller, events);
    }

    group('[$code] E783 the portal opens by holding (RF-431)', () {
      for (final (surface, at) in <(String, Offset Function(WidgetTester))>[
        ('disc', (tester) => discOf(tester, mineFp)),
        ('row', (tester) => rowOf(tester, mineFp)),
      ]) {
        testWidgets('on the $surface it opens at 0.5 s with the available '
            'roots and only them', (tester) async {
          final (controller, events) = await pumpWithRoots(tester);

          events.add(DropEnter(at(tester)));
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 210));
          expect(controller.prefetched, [mineFp]);
          await tester.pump(const Duration(milliseconds: 270));
          expect(_panel, findsNothing);
          await tester.pump(const Duration(milliseconds: 30));
          await tester.pump();

          expect(_panel, findsOneWidget);
          await _settlePanel(tester);
          expect(_inPanel(find.text('Documentos')), findsOneWidget);
          expect(_inPanel(find.text(home)), findsOneWidget);
          expect(_inPanel(find.text('Pendrive')), findsNothing);
          expect(controller.rootRequests, 1);
          expect(controller.sendPathsCalls, isEmpty);

          events.add(const DropLeave());
          await tester.pump();
        });
      }

      testWidgets('opened from the disc it stays put when the pointer moves '
          'onto it', (tester) async {
        final (_, events) = await pumpWithRoots(tester);
        await _hold(tester, events, discOf(tester, mineFp));
        await _settlePanel(tester);
        final before = tester.getRect(_panel);

        await _over(
          tester,
          events,
          tester.getCenter(_inPanel(find.text('Documentos'))),
        );
        await tester.pump();

        expect(tester.getRect(_panel), before);
        events.add(const DropLeave());
        await tester.pump();
      });

      testWidgets('with the list at 1.2 s it opens then', (tester) async {
        final (controller, events) = await pumpWithRoots(tester);
        final pending = Completer<RemoteListing>();
        controller.rootsResult = (_) => pending.future;

        await _hold(tester, events, discOf(tester, mineFp));
        expect(_panel, findsNothing);
        await tester.pump(const Duration(milliseconds: 690));
        expect(_panel, findsNothing);

        pending.complete(const RemoteRoots([rootDocs]));
        await tester.pump();
        await tester.pump();

        expect(_panel, findsOneWidget);
        events.add(const DropLeave());
        await tester.pump();
      });

      testWidgets('a late list does not open it once the pointer left the '
          'device (B3)', (tester) async {
        final (controller, events) = await pumpWithRoots(tester);
        final pending = Completer<RemoteListing>();
        controller.rootsResult = (_) => pending.future;

        await _hold(tester, events, discOf(tester, mineFp));
        await _over(tester, events, const Offset(5, 5));
        await tester.pump(const Duration(milliseconds: 300));
        pending.complete(const RemoteRoots([rootDocs]));
        await tester.pump();
        await tester.pump();

        expect(_panel, findsNothing);
        events.add(const DropLeave());
        await tester.pump();
      });

      testWidgets('with the list at 3 s it never opens', (tester) async {
        final (controller, events) = await pumpWithRoots(tester);
        final pending = Completer<RemoteListing>();
        controller.rootsResult = (_) => pending.future;

        await _hold(tester, events, discOf(tester, mineFp));
        await tester.pump(const Duration(milliseconds: 2500));
        pending.complete(const RemoteRoots([rootDocs]));
        await tester.pump();
        await tester.pump();

        expect(_panel, findsNothing);
        events.add(const DropLeave());
        await tester.pump();
      });

      testWidgets('one request per device and drag, however it comes back', (
        tester,
      ) async {
        final (controller, events) = await pumpWithRoots(tester);
        final disc = discOf(tester, mineFp);

        for (var i = 0; i < 3; i++) {
          await _over(tester, events, disc);
          await tester.pump(const Duration(milliseconds: 300));
          await _over(tester, events, const Offset(5, 5));
          await tester.pump(const Duration(milliseconds: 50));
        }
        await _over(tester, events, disc);
        await tester.pump(const Duration(milliseconds: 600));
        await tester.pump();

        expect(controller.rootRequests, 1);
        expect(_panel, findsOneWidget);
        events.add(const DropLeave());
        await tester.pump();
      });

      testWidgets('a new drag asks again', (tester) async {
        final (controller, events) = await pumpWithRoots(tester);

        await _hold(tester, events, discOf(tester, mineFp));
        events.add(const DropLeave());
        await tester.pump();
        await _hold(tester, events, discOf(tester, mineFp));

        expect(controller.rootRequests, 2);
        events.add(const DropLeave());
        await tester.pump();
      });
    });

    group('[$code] E784 no portal (RF-432)', () {
      testWidgets('someone else: no request, a drop sends without a menu', (
        tester,
      ) async {
        final (controller, events) = await pumpWithRoots(tester);
        final at = discOf(tester, foreignFp);

        await _hold(tester, events, at);
        await tester.pump(const Duration(milliseconds: 600));

        expect(_panel, findsNothing);
        expect(controller.rootRequests, 0);

        events.add(DropDone(at, sentPaths, sentPaths.length));
        await settleMenu(tester);

        expect(_menu, findsNothing);
        expect(controller.sendPathsCalls, [sentPaths]);
        expect(controller.sendDestinations.single, isNull);
      });

      final refused = <String, RemoteListing>{
        'no roots': const RemoteRoots([]),
        'only unavailable roots': const RemoteRoots([rootUsb]),
        'busy': const RemoteListingFailed(BrowseFailure.busy),
        'not allowed': const RemoteListingFailed(BrowseFailure.notAllowed),
        'no answer': const RemoteListingFailed(BrowseFailure.noAnswer),
        'unreadable': const RemoteListingFailed(BrowseFailure.unreadable),
      };
      for (final MapEntry(key: name, value: answer) in refused.entries) {
        testWidgets('$name: it does not open and nothing tells why', (
          tester,
        ) async {
          final (controller, events) = await pumpWithRoots(tester);
          controller.rootsResult = (_) async => answer;

          await _hold(tester, events, discOf(tester, mineFp));
          await tester.pump(const Duration(milliseconds: 2500));

          expect(_panel, findsNothing);
          expect(find.text(strings.destNoChoice(mineName)), findsNothing);
          expect(find.text(strings.navBusy(mineName)), findsNothing);
          events.add(const DropLeave());
          await tester.pump();
        });
      }

      testWidgets('without roots, a drop opens the menu with the explanation', (
        tester,
      ) async {
        final (controller, events) = await pumpWithRoots(tester);
        controller.rootsResult = (_) async => const RemoteRoots([]);
        final at = discOf(tester, mineFp);

        await _hold(tester, events, at);
        events.add(DropDone(at, sentPaths, sentPaths.length));
        await settleMenu(tester);

        expect(_menu, findsOneWidget);
        expect(find.text(strings.destNoChoice(mineName)), findsOneWidget);
        expect(controller.sendPathsCalls, isEmpty);
      });

      testWidgets('a device out of sight does not open it', (tester) async {
        final (controller, events) = await pumpWithRoots(
          tester,
          state: destinationState(visible: false),
        );

        await _hold(tester, events, rowOf(tester, mineFp));

        expect(_panel, findsNothing);
        expect(controller.rootRequests, 0);
        events.add(const DropLeave());
        await tester.pump();
      });
    });

    group('[$code] E785 navigate without dropping (RF-433)', () {
      testWidgets('holding on a folder enters, on Back goes up, with '
          'breadcrumbs', (tester) async {
        final (controller, events) = await pumpWithRoots(tester);
        await _hold(tester, events, rowOf(tester, mineFp));
        await _settlePanel(tester);

        await _holdOnFolder(tester, events, 'Documentos');

        expect(_inPanel(find.text('fotos')), findsOneWidget);
        expect(
          _inPanel(find.text(strings.portalHereIn('Documentos'))),
          findsOneWidget,
        );
        expect(_inPanel(find.text(mineName)), findsWidgets);
        expect(
          controller.calls,
          contains('listRemoteFolders $mineFp root-docs '),
        );

        await _holdOnFolder(tester, events, 'fotos');
        expect(_inPanel(find.text('2026')), findsOneWidget);
        expect(
          _inPanel(find.text(strings.portalBack('Documentos'))),
          findsOneWidget,
        );

        await _holdOnFolder(tester, events, strings.portalBack('Documentos'));
        expect(_inPanel(find.text('fotos')), findsOneWidget);

        await _holdOnFolder(tester, events, strings.portalBack(mineName));
        expect(_inPanel(find.text(home)), findsOneWidget);
        expect(controller.sendPathsCalls, isEmpty);
        events.add(const DropLeave());
        await tester.pump();
      });

      testWidgets('less than 0.5 s on a folder does not enter', (tester) async {
        final (controller, events) = await pumpWithRoots(tester);
        await _hold(tester, events, rowOf(tester, mineFp));
        await _settlePanel(tester);

        final at = tester.getCenter(_inPanel(find.text('Documentos')));
        await _over(tester, events, at);
        await tester.pump(const Duration(milliseconds: 400));
        await _over(tester, events, const Offset(5, 5));
        await tester.pump(const Duration(milliseconds: 200));

        expect(
          controller.calls.where((c) => c.startsWith('listRemoteFolders')),
          isEmpty,
        );
        events.add(const DropLeave());
        await tester.pump();
      });

      testWidgets('the new row under the pointer does not start by itself', (
        tester,
      ) async {
        final (controller, events) = await pumpWithRoots(tester);
        await _hold(tester, events, rowOf(tester, mineFp));
        await _settlePanel(tester);

        final at = tester.getCenter(_inPanel(find.text('Documentos')));
        await _over(tester, events, at);
        await tester.pump(const Duration(milliseconds: 510));
        await tester.pump();
        await _settlePanel(tester);
        final before = controller.calls.length;

        await _over(tester, events, at + const Offset(2, 0));
        await tester.pump(const Duration(milliseconds: 700));

        expect(controller.calls.length, before);
        events.add(const DropLeave());
        await tester.pump();
      });

      testWidgets('it says when the list is trimmed or incomplete', (
        tester,
      ) async {
        final (controller, events) = await pumpWithRoots(tester);
        controller.foldersResult = (_, _, _) async =>
            const RemoteFolders(['fotos'], more: true, partial: true);
        await _hold(tester, events, rowOf(tester, mineFp));
        await _settlePanel(tester);

        await _holdOnFolder(tester, events, 'Documentos');

        expect(_inPanel(find.text(strings.navMore)), findsOneWidget);
        expect(_inPanel(find.text(strings.navPartial)), findsOneWidget);
        events.add(const DropLeave());
        await tester.pump();
      });

      testWidgets('a folder that left explains and goes back to the roots', (
        tester,
      ) async {
        final (controller, events) = await pumpWithRoots(tester);
        await _hold(tester, events, rowOf(tester, mineFp));
        await _settlePanel(tester);
        await _holdOnFolder(tester, events, 'Documentos');
        controller.foldersResult = (_, _, _) async =>
            const RemoteListingFailed(BrowseFailure.unavailable);

        await _holdOnFolder(tester, events, 'fotos');

        expect(_inPanel(find.text(strings.navGone)), findsOneWidget);
        expect(_inPanel(find.text(home)), findsOneWidget);
        expect(_inPanel(find.text('obra')), findsNothing);
        events.add(const DropLeave());
        await tester.pump();
      });

      testWidgets('busy stays in the open folder and lets it drop there', (
        tester,
      ) async {
        final (controller, events) = await pumpWithRoots(tester);
        await _hold(tester, events, rowOf(tester, mineFp));
        await _settlePanel(tester);
        await _holdOnFolder(tester, events, 'Documentos');
        controller.foldersResult = (_, _, _) async =>
            const RemoteListingFailed(BrowseFailure.busy);

        await _holdOnFolder(tester, events, 'fotos');

        expect(_inPanel(find.text(strings.navBusy(mineName))), findsOneWidget);
        final here = tester.getCenter(
          _inPanel(find.text(strings.portalHereIn('Documentos'))),
        );
        events.add(DropOver(here));
        await tester.pump();
        events.add(DropDone(here, sentPaths, sentPaths.length));
        await settleMenu(tester);

        expect(controller.sendDestinations.single!.path, isEmpty);
        expect(controller.sendDestinations.single!.rootId, rootDocs.id);
      });

      testWidgets('there is no new folder and no default folder', (
        tester,
      ) async {
        final (_, events) = await pumpWithRoots(tester);
        await _hold(tester, events, rowOf(tester, mineFp));
        await _settlePanel(tester);

        expect(_inPanel(find.text(strings.destDefaultFolder)), findsNothing);
        await _holdOnFolder(tester, events, 'Documentos');
        expect(_inPanel(find.text(strings.navNewFolder)), findsNothing);
        expect(_inPanel(find.text(strings.destDefaultFolder)), findsNothing);
        events.add(const DropLeave());
        await tester.pump();
      });
    });

    group('[$code] E786 dropping and leaving (RF-434)', () {
      testWidgets('on a root it sends there without a menu', (tester) async {
        final (controller, events) = await pumpWithRoots(tester);
        await _hold(tester, events, rowOf(tester, mineFp));
        await _settlePanel(tester);

        final at = tester.getCenter(_inPanel(find.text('Documentos')));
        await _over(tester, events, at);
        events.add(DropDone(at, sentPaths, sentPaths.length));
        await settleMenu(tester);

        expect(_menu, findsNothing);
        expect(_panel, findsNothing);
        expect(controller.sendPathsCalls, [sentPaths]);
        final destination = controller.sendDestinations.single!;
        expect(destination.rootId, rootDocs.id);
        expect(destination.path, isEmpty);
      });

      testWidgets('on a subfolder it sends there', (tester) async {
        final (controller, events) = await pumpWithRoots(tester);
        await _hold(tester, events, rowOf(tester, mineFp));
        await _settlePanel(tester);
        await _holdOnFolder(tester, events, 'Documentos');

        final at = tester.getCenter(_inPanel(find.text('obra')));
        await _over(tester, events, at);
        events.add(DropDone(at, sentPaths, sentPaths.length));
        await settleMenu(tester);

        expect(controller.sendDestinations.single!.path, ['obra']);
      });

      testWidgets('on the background with a folder open, to the open one', (
        tester,
      ) async {
        final (controller, events) = await pumpWithRoots(tester);
        await _hold(tester, events, rowOf(tester, mineFp));
        await _settlePanel(tester);
        await _holdOnFolder(tester, events, 'Documentos');

        final at = tester.getTopLeft(_panel) + const Offset(40, 18);
        await _over(tester, events, at);
        events.add(DropDone(at, sentPaths, sentPaths.length));
        await settleMenu(tester);

        expect(_menu, findsNothing);
        expect(controller.sendDestinations.single!.rootId, rootDocs.id);
        expect(controller.sendDestinations.single!.path, isEmpty);
      });

      testWidgets('on Back with a folder open, to the open one (B1)', (
        tester,
      ) async {
        final (controller, events) = await pumpWithRoots(tester);
        await _hold(tester, events, rowOf(tester, mineFp));
        await _settlePanel(tester);
        await _holdOnFolder(tester, events, 'Documentos');
        await _holdOnFolder(tester, events, 'obra');

        final at = tester.getCenter(
          _inPanel(find.text(strings.portalBack('Documentos'))),
        );
        await _over(tester, events, at);
        events.add(DropDone(at, sentPaths, sentPaths.length));
        await settleMenu(tester);

        expect(_menu, findsNothing);
        expect(_panel, findsNothing);
        expect(controller.sendDestinations.single!.rootId, rootDocs.id);
        expect(controller.sendDestinations.single!.path, ['obra']);
      });

      testWidgets('two roots with the same name: the drop and the hold use '
          'the one under the pointer (B2)', (tester) async {
        final (controller, events) = await pumpWithRoots(tester);
        controller.rootsResult = (_) async => const RemoteRoots([
          RemoteRoot(id: 'root-a', name: 'Datos', home: false, available: true),
          RemoteRoot(id: 'root-b', name: 'Datos', home: false, available: true),
        ]);
        await _hold(tester, events, rowOf(tester, mineFp));
        await _settlePanel(tester);
        expect(_inPanel(find.text('Datos')), findsNWidgets(2));

        final second = tester.getCenter(_inPanel(find.text('Datos')).at(1));
        await _over(tester, events, second + const Offset(7, 0));
        await _over(tester, events, second);
        await tester.pump(const Duration(milliseconds: 510));
        await tester.pump();
        await _settlePanel(tester);
        expect(controller.calls, contains('listRemoteFolders $mineFp root-b '));
        expect(
          controller.calls,
          isNot(contains('listRemoteFolders $mineFp root-a ')),
        );
        events.add(const DropLeave());
        await tester.pump();

        await _hold(tester, events, rowOf(tester, mineFp));
        await _settlePanel(tester);
        final at = tester.getCenter(_inPanel(find.text('Datos')).at(1));
        await _over(tester, events, at);
        events.add(DropDone(at, sentPaths, sentPaths.length));
        await settleMenu(tester);

        expect(controller.sendDestinations.single!.rootId, 'root-b');
      });

      testWidgets('subfolders, crumbs and "Here, in" hide U+200E, U+200F and '
          'U+061C, and a drop sends the real name (M3)', (tester) async {
        final (controller, events) = await pumpWithRoots(tester);
        controller.foldersResult = (_, rootId, path) async => path.isEmpty
            ? const RemoteFolders(
                ['a\u200Eb', 'c\u200Fd', 'e\u061Cf'],
                more: false,
                partial: false,
              )
            : const RemoteFolders(['g\u200Fh'], more: false, partial: false);
        await _hold(tester, events, rowOf(tester, mineFp));
        await _settlePanel(tester);
        await _holdOnFolder(tester, events, 'Documentos');

        for (final shown in ['ab', 'cd', 'ef']) {
          expect(_inPanel(find.text(shown)), findsOneWidget);
        }
        await _holdOnFolder(tester, events, 'cd');

        expect(_inPanel(find.text('gh')), findsOneWidget);
        expect(_inPanel(find.text(strings.portalHereIn('cd'))), findsOneWidget);
        expect(_inPanel(find.text('cd')), findsOneWidget);
        for (final text in tester.widgetList<Text>(
          _inPanel(find.byType(Text)),
        )) {
          final data = text.data ?? text.textSpan?.toPlainText() ?? '';
          expect(data, isNot(contains('\u200E')));
          expect(data, isNot(contains('\u200F')));
          expect(data, isNot(contains('\u061C')));
        }

        final at = tester.getCenter(_inPanel(find.text('gh')));
        await _over(tester, events, at);
        events.add(DropDone(at, sentPaths, sentPaths.length));
        await settleMenu(tester);

        expect(controller.sendDestinations.single!.path, [
          'c\u200Fd',
          'g\u200Fh',
        ]);
      });

      testWidgets('on the background at the roots, nothing and it closes', (
        tester,
      ) async {
        final (controller, events) = await pumpWithRoots(tester);
        await _hold(tester, events, rowOf(tester, mineFp));
        await _settlePanel(tester);

        final at = tester.getTopLeft(_panel) + const Offset(40, 18);
        await _over(tester, events, at);
        events.add(DropDone(at, sentPaths, sentPaths.length));
        await settleMenu(tester);

        expect(_panel, findsNothing);
        expect(_menu, findsNothing);
        expect(controller.sendPathsCalls, isEmpty);
        expect(controller.addToTrayCalls, isEmpty);
      });

      testWidgets('DropLeave closes without sending', (tester) async {
        final (controller, events) = await pumpWithRoots(tester);
        await _hold(tester, events, rowOf(tester, mineFp));
        await _settlePanel(tester);

        events.add(const DropLeave());
        await settleMenu(tester);

        expect(_panel, findsNothing);
        expect(controller.sendPathsCalls, isEmpty);
      });

      testWidgets('leaving the portal and the device closes at 0.4 s, and '
          'coming back in time keeps it', (tester) async {
        final (_, events) = await pumpWithRoots(tester);
        final disc = rowOf(tester, mineFp);
        await _hold(tester, events, disc);
        await _settlePanel(tester);

        await _over(tester, events, const Offset(5, 5));
        await tester.pump(const Duration(milliseconds: 300));
        await _over(tester, events, disc);
        await tester.pump(const Duration(milliseconds: 300));
        expect(_panel, findsOneWidget);

        await _over(tester, events, const Offset(5, 5));
        await tester.pump(const Duration(milliseconds: 390));
        expect(_panel, findsOneWidget);
        await tester.pump(const Duration(milliseconds: 20));
        await tester.pump();
        expect(_panel, findsNothing);
        events.add(const DropLeave());
        await tester.pump();
      });

      testWidgets('over another device it closes at once and a drop there '
          'follows the 006', (tester) async {
        final (controller, events) = await pumpWithRoots(tester);
        await _hold(tester, events, rowOf(tester, mineFp));
        await _settlePanel(tester);

        final other = rowOf(tester, foreignFp);
        await _over(tester, events, other);
        await tester.pump();
        expect(_panel, findsNothing);

        events.add(DropDone(other, sentPaths, sentPaths.length));
        await settleMenu(tester);

        expect(
          controller.calls,
          contains('sendPaths $foreignFp ${sentPaths.join('|')}'),
        );
        expect(controller.sendDestinations.single, isNull);
      });

      testWidgets('more than 1000 items shows the 006 message, sends nothing', (
        tester,
      ) async {
        final (controller, events) = await pumpWithRoots(tester);
        await _hold(tester, events, rowOf(tester, mineFp));
        await _settlePanel(tester);

        final at = tester.getCenter(_inPanel(find.text('Documentos')));
        await _over(tester, events, at);
        events.add(DropDone(at, sentPaths, 1001));
        await settleMenu(tester);
        await tester.pump(const Duration(milliseconds: 750));

        expect(controller.sendPathsCalls, isEmpty);
        expect(find.text(strings.tooManySelected), findsOneWidget);
      });
    });

    group('[$code] a long list in the portal (RF-433, 760x520)', () {
      testWidgets('300 subfolders fit without overflowing', (tester) async {
        final (controller, events) = await pumpWithRoots(
          tester,
          size: const Size(760, 520),
        );
        controller.foldersResult = (_, _, _) async => RemoteFolders(
          [for (var i = 0; i < 300; i++) 'carpeta-$i'],
          more: false,
          partial: false,
        );
        await tester.tap(find.text(strings.devicesTab));
        await settleMenu(tester);
        await _hold(tester, events, rowOf(tester, mineFp));
        await _settlePanel(tester);

        await _holdOnFolder(tester, events, 'Documentos');

        expect(tester.takeException(), isNull);
        events.add(const DropLeave());
        await tester.pump();
      });
    });
  }

  group('E783 the 2 s window with the injected clock (RF-431)', () {
    late DateTime clock;
    late DelegatingController app;
    late PortalController portal;

    setUp(() {
      clock = DateTime(2026, 11, 5, 12);
      app = DelegatingController(state: destinationState());
      portal = PortalController(
        app: app,
        homeName: () => 'Home',
        anchorOf: (_) => null,
        now: () => clock,
      );
      addTearDown(portal.dispose);
    });

    test('an answer before 2 s from the prefetch opens', () async {
      final pending = Completer<RemoteListing>();
      app.rootsResult = (_) => pending.future;
      portal
        ..dragStarted()
        ..prefetch(mineFp);
      clock = clock.add(const Duration(milliseconds: 300));
      final opened = portal.request(mineFp);
      clock = clock.add(const Duration(milliseconds: 1500));
      pending.complete(const RemoteRoots([rootDocs]));
      await opened;

      expect(portal.isOpen, isTrue);
      expect(app.rootRequests, 1);
    });

    test('a request after 2 s from the prefetch does not wait', () async {
      final pending = Completer<RemoteListing>();
      app.rootsResult = (_) => pending.future;
      portal
        ..dragStarted()
        ..prefetch(mineFp);
      clock = clock.add(const Duration(milliseconds: 2100));

      await portal.request(mineFp);
      pending.complete(const RemoteRoots([rootDocs]));
      await pumpEventQueue();

      expect(portal.isOpen, isFalse);
    });

    test('after dragEnded a late answer opens nothing', () async {
      final pending = Completer<RemoteListing>();
      app.rootsResult = (_) => pending.future;
      portal
        ..dragStarted()
        ..prefetch(mineFp);
      final opened = portal.request(mineFp);
      portal.dragEnded();

      pending.complete(const RemoteRoots([rootDocs]));
      await opened;
      await pumpEventQueue();

      expect(portal.isOpen, isFalse);
    });

    test('cancelPending drops a request that is still waiting (B3)', () async {
      final pending = Completer<RemoteListing>();
      app.rootsResult = (_) => pending.future;
      portal
        ..dragStarted()
        ..prefetch(mineFp);
      final opened = portal.request(mineFp);
      portal.cancelPending();

      pending.complete(const RemoteRoots([rootDocs]));
      await opened;
      await pumpEventQueue();

      expect(portal.isOpen, isFalse);
    });

    test('prefetch without a drag asks for nothing', () async {
      portal.prefetch(mineFp);
      await portal.request(mineFp);

      expect(app.rootRequests, 0);
      expect(portal.isOpen, isFalse);
    });
  });
}
