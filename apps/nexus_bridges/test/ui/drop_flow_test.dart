import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nexus_bridges/src/drop/drop_events.dart';
import 'package:nexus_bridges/src/drop/drop_zone.dart';
import 'package:nexus_bridges/src/l10n/app_strings.dart';
import 'package:nexus_bridges/src/ui/destination/destination_menu.dart';
import 'package:nexus_bridges/src/ui/diagram/flow_painter.dart';
import 'package:nexus_bridges/src/ui/tray_panel.dart';
import 'package:nexus_bridges_core/nexus_bridges_core.dart';

import '../drop/fake_drop_events.dart';
import 'fake_app_controller.dart';
import 'pairing_fixtures.dart';

final String _fpA = fingerprintOf('AAAA1111');
final String _fpB = fingerprintOf('BBBB2222');
final String _fpC = fingerprintOf('CCCC3333');
final String _fpD = fingerprintOf('DDDD4444');

const Duration _fade = Duration(milliseconds: 460);

NodeState _state({
  String? sendingTo,
  bool hiddenC = false,
  List<TrayItemView> tray = const [],
}) {
  return NodeState(
    entries: [
      entry(fingerprint: _fpA, name: 'PC principal', paired: true, mine: true),
      entry(fingerprint: _fpB, name: 'Torre', paired: true),
      entry(
        fingerprint: _fpC,
        name: 'Portatil',
        paired: true,
        visible: !hiddenC,
      ),
      entry(fingerprint: _fpD, name: 'Movil'),
    ],
    sendingTo: sendingTo,
    tray: tray,
  );
}

const List<String> _paths = [r'C:\work\a.txt', r'C:\work\project'];

Future<(FakeAppController, FakeDropEvents)> _pump(
  WidgetTester tester,
  String code,
  NodeState state, {
  bool reduceMotion = false,
}) async {
  tester.view.physicalSize = const Size(1200, 800);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final controller = FakeAppController(state: state);
  final events = FakeDropEvents();
  addTearDown(events.close);
  await pumpHome(
    tester,
    controller,
    code,
    dropEvents: events,
    reduceMotion: reduceMotion,
  );
  return (controller, events);
}

Offset _row(WidgetTester tester, String fingerprint) =>
    tester.getCenter(find.byKey(ValueKey(fingerprint)));

Offset _disc(WidgetTester tester, String fingerprint) =>
    tester.getCenter(find.byKey(ValueKey('flow-peer-$fingerprint')));

const Offset _empty = Offset(420, 740);

FlowPainter _flow(WidgetTester tester) {
  for (final paint in tester.widgetList<CustomPaint>(
    find.byType(CustomPaint),
  )) {
    final painter = paint.foregroundPainter;
    if (painter is FlowPainter) return painter;
  }
  throw StateError('no flow painter');
}

double _rowOpacity(WidgetTester tester, String fingerprint) {
  final fades = find.descendant(
    of: find.byKey(ValueKey(fingerprint)),
    matching: find.byType(AnimatedOpacity),
  );
  return tester.widget<AnimatedOpacity>(fades.first).opacity;
}

Future<void> _settleFrames(WidgetTester tester) async {
  await tester.pump();
  await tester.pump();
}

void main() {
  for (final code in languageCodes) {
    final strings = stringsFor(code);

    group('[$code] E550 dragging lights up the devices that can receive '
        '(RF-287)', () {
      testWidgets('the hint shows, the tip hides and the ring lights up', (
        tester,
      ) async {
        final (_, events) = await _pump(tester, code, _state(hiddenC: true));

        expect(find.text(strings.dragHint), findsNothing);
        expect(find.text(strings.dragTipTitle), findsOneWidget);

        events.add(DropEnter(_empty));
        await tester.pump();
        await tester.pump(_fade);

        expect(find.text(strings.dragHint), findsOneWidget);
        final tip = find.descendant(
          of: find.byType(DragTip),
          matching: find.byType(Opacity),
        );
        expect(tester.widget<Opacity>(tip.first).opacity, 0);
        final flow = _flow(tester);
        expect(flow.lit, {_fpA, _fpB});
        expect(flow.hot, isNull);

        events.add(const DropLeave());
        await tester.pump();
        await tester.pump(_fade);
        await tester.pump(_fade);

        expect(find.text(strings.dragHint), findsNothing);
        expect(tester.widget<Opacity>(tip.first).opacity, 1);
      });

      testWidgets('rows: the ones that can receive stay, the rest dim', (
        tester,
      ) async {
        final (_, events) = await _pump(tester, code, _state(hiddenC: true));

        events.add(DropEnter(_empty));
        await tester.pump(_fade);

        expect(_rowOpacity(tester, _fpA), 1);
        expect(_rowOpacity(tester, _fpB), 1);
        expect(_rowOpacity(tester, _fpC), lessThan(1));
        expect(_rowOpacity(tester, _fpD), lessThan(1));
      });

      testWidgets('a busy queue to A keeps A lit and dims the others', (
        tester,
      ) async {
        final (_, events) = await _pump(tester, code, _state(sendingTo: _fpA));

        events.add(DropEnter(_empty));
        await tester.pump(_fade);

        expect(_flow(tester).lit, {_fpA});
      });

      testWidgets('the pointer over a lit device makes it hot', (tester) async {
        final (_, events) = await _pump(tester, code, _state());

        events.add(DropEnter(_disc(tester, _fpB)));
        await tester.pump(_fade);

        expect(_flow(tester).hot, _fpB);

        events.add(DropOver(_row(tester, _fpA)));
        await tester.pump(_fade);

        expect(_flow(tester).hot, _fpA);

        events.add(DropOver(_empty));
        await tester.pump(_fade);

        expect(_flow(tester).hot, isNull);
      });

      testWidgets('without the diagram the hint floats over the column', (
        tester,
      ) async {
        tester.view.physicalSize = const Size(700, 800);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        final controller = FakeAppController(state: _state());
        final events = FakeDropEvents();
        addTearDown(events.close);
        await pumpHome(tester, controller, code, dropEvents: events);

        expect(find.byType(DragTip), findsNothing);
        events.add(DropEnter(_row(tester, _fpB)));
        await tester.pump();
        await tester.pump(_fade);

        expect(find.text(strings.dragHint), findsOneWidget);
        expect(_rowOpacity(tester, _fpC), 1);
        expect(_rowOpacity(tester, _fpD), lessThan(1));

        events.add(DropDone(_row(tester, _fpB), _paths, 2));
        await tester.pump();
        await tester.pump(_fade);
        await tester.pump(_fade);

        expect(find.text(strings.dragHint), findsNothing);
        expect(controller.calls.last, startsWith('sendPaths $_fpB'));
      });

      testWidgets('reduced motion shows the hint at once', (tester) async {
        final (_, events) = await _pump(
          tester,
          code,
          _state(),
          reduceMotion: true,
        );

        events.add(DropEnter(_empty));
        await _settleFrames(tester);

        expect(find.text(strings.dragHint), findsOneWidget);
        final opacity = tester.widget<FadeTransition>(
          find.descendant(
            of: find.byType(DragPill),
            matching: find.byType(FadeTransition),
          ),
        );
        expect(opacity.opacity.value, 1);
      });
    });

    group('[$code] E551 dropping on a device that can receive (RF-288)', () {
      testWidgets('on its disc in the diagram it sends the paths', (
        tester,
      ) async {
        final (controller, events) = await _pump(tester, code, _state());

        events.add(DropEnter(_disc(tester, _fpB)));
        await tester.pump(_fade);
        events.add(DropDone(_disc(tester, _fpB), _paths, 2));
        await _settleFrames(tester);

        expect(controller.calls, ['sendPaths $_fpB ${_paths.join('|')}']);
        expect(controller.addToTrayCalls, isEmpty);
        expect(find.text(strings.dragHint), findsNothing);
      });

      testWidgets('on its row in the list it sends the paths', (tester) async {
        final (controller, events) = await _pump(tester, code, _state());

        events.add(DropEnter(_row(tester, _fpB)));
        await tester.pump(_fade);
        events.add(DropDone(_row(tester, _fpB), _paths, 2));
        await _settleFrames(tester);

        expect(controller.calls, ['sendPaths $_fpB ${_paths.join('|')}']);
        expect(controller.addToTrayCalls, isEmpty);
      });

      testWidgets('with queues to B, dropping on B sends and on A does not', (
        tester,
      ) async {
        final (controller, events) = await _pump(
          tester,
          code,
          _state(sendingTo: _fpB),
        );

        events.add(DropDone(_row(tester, _fpB), _paths, 2));
        await _settleFrames(tester);
        events.add(DropDone(_row(tester, _fpA), _paths, 2));
        await _settleFrames(tester);

        expect(controller.sendPathsCalls, hasLength(1));
        expect(controller.calls.first, startsWith('sendPaths $_fpB'));
        expect(controller.addToTrayCalls, hasLength(1));
      });

      testWidgets('a started send shows no message', (tester) async {
        final (controller, events) = await _pump(tester, code, _state());
        controller.sendPathsResult = SendResult.started;

        events.add(DropDone(_row(tester, _fpB), _paths, 2));
        await _settleFrames(tester);

        expect(find.byType(SnackBar), findsNothing);
      });

      testWidgets('a refused send explains the reason', (tester) async {
        final (controller, events) = await _pump(tester, code, _state());
        controller.sendPathsResult = SendResult.unavailable;

        events.add(DropDone(_row(tester, _fpB), _paths, 2));
        await _settleFrames(tester);

        expect(find.text(strings.sendUnavailable), findsOneWidget);
      });
    });

    group('[$code] E552 dropping outside or on a device that cannot receive '
        '(RF-289)', () {
      testWidgets('on an empty zone the paths go to the tray', (tester) async {
        final (controller, events) = await _pump(tester, code, _state());

        events.add(DropEnter(_empty));
        await tester.pump(_fade);
        events.add(DropDone(_empty, _paths, 2));
        await _settleFrames(tester);

        expect(controller.calls, ['addToTray ${_paths.join('|')} 2']);
        expect(controller.sendPathsCalls, isEmpty);
        expect(find.byType(SnackBar), findsNothing);
      });

      testWidgets('on a device that is not visible it goes to the tray and '
          'says why', (tester) async {
        final (controller, events) = await _pump(
          tester,
          code,
          _state(hiddenC: true),
        );

        events.add(DropEnter(_row(tester, _fpC)));
        await tester.pump(_fade);
        events.add(DropDone(_row(tester, _fpC), _paths, 2));
        await _settleFrames(tester);

        expect(controller.calls, ['addToTray ${_paths.join('|')} 2']);
        expect(controller.sendPathsCalls, isEmpty);
        expect(
          find.descendant(
            of: find.byType(SnackBar),
            matching: find.text(strings.sendNeedsVisible),
          ),
          findsOneWidget,
        );
      });

      testWidgets('on a device while sending to another it says to wait', (
        tester,
      ) async {
        final (controller, events) = await _pump(
          tester,
          code,
          _state(sendingTo: _fpA),
        );

        events.add(DropDone(_disc(tester, _fpB), _paths, 2));
        await _settleFrames(tester);

        expect(controller.sendPathsCalls, isEmpty);
        expect(controller.addToTrayCalls, [_paths]);
        expect(
          find.descendant(
            of: find.byType(SnackBar),
            matching: find.text(strings.waitForQueues('PC principal')),
          ),
          findsOneWidget,
        );
      });

      testWidgets('on an unpaired row it goes to the tray', (tester) async {
        final (controller, events) = await _pump(tester, code, _state());

        events.add(DropDone(_row(tester, _fpD), _paths, 2));
        await _settleFrames(tester);

        expect(controller.sendPathsCalls, isEmpty);
        expect(controller.addToTrayCalls, [_paths]);
      });

      testWidgets('what is already in the tray says so', (tester) async {
        final (controller, events) = await _pump(tester, code, _state());
        controller.addToTrayResult = TrayResult.nothingNew;

        events.add(DropDone(_empty, _paths, 2));
        await _settleFrames(tester);

        expect(find.text(strings.trayNothingNew), findsOneWidget);
      });

      testWidgets('a full tray says so', (tester) async {
        final (controller, events) = await _pump(tester, code, _state());
        controller.addToTrayResult = TrayResult.tooMany;

        events.add(DropDone(_empty, _paths, 2));
        await _settleFrames(tester);

        expect(find.text(strings.trayFull), findsOneWidget);
      });

      testWidgets('an unavailable node says so', (tester) async {
        final (controller, events) = await _pump(tester, code, _state());
        controller.addToTrayResult = TrayResult.unavailable;

        events.add(DropDone(_empty, _paths, 2));
        await _settleFrames(tester);

        expect(find.text(strings.sendUnavailable), findsOneWidget);
      });
    });

    group('[$code] E553 what carries no paths does nothing (RF-308)', () {
      testWidgets('without events nothing lights and nothing is called', (
        tester,
      ) async {
        final (controller, _) = await _pump(tester, code, _state());
        await tester.pump(_fade);

        expect(find.text(strings.dragHint), findsNothing);
        expect(_flow(tester).dragFade!.value, 0);
        expect(controller.calls, isEmpty);
      });

      testWidgets('leave without drop clears everything', (tester) async {
        final (controller, events) = await _pump(tester, code, _state());

        events.add(DropEnter(_disc(tester, _fpA)));
        await tester.pump(_fade);
        events.add(DropOver(_row(tester, _fpB)));
        await tester.pump(_fade);
        events.add(const DropLeave());
        await tester.pump(_fade);
        await tester.pump(_fade);

        expect(find.text(strings.dragHint), findsNothing);
        expect(_flow(tester).dragFade!.value, 0);
        expect(_flow(tester).hot, isNull);
        expect(controller.calls, isEmpty);
      });

      testWidgets('a drop with no paths calls nothing', (tester) async {
        final (controller, events) = await _pump(tester, code, _state());

        events.add(DropDone(_empty, const [], 0));
        await _settleFrames(tester);

        expect(controller.calls, isEmpty);
      });
    });

    group('[$code] RF-309 a selection of more than 1 000 items', () {
      final many = [for (var i = 0; i < 1001; i++) 'C:\\many\\f$i'];

      testWidgets('on a device it is not sent and the limit is explained', (
        tester,
      ) async {
        final (controller, events) = await _pump(tester, code, _state());

        events.add(DropDone(_row(tester, _fpA), many, 5000));
        await _settleFrames(tester);

        expect(controller.calls, isEmpty);
        expect(find.text(strings.tooManySelected), findsOneWidget);
      });

      testWidgets('outside it asks the tray with the real count and explains '
          'the limit', (tester) async {
        final (controller, events) = await _pump(tester, code, _state());
        controller.addToTrayResult = TrayResult.tooMany;

        events.add(DropDone(_empty, many, 5000));
        await _settleFrames(tester);

        expect(controller.addToTrayTotals, [5000]);
        expect(controller.sendPathsCalls, isEmpty);
        expect(find.text(strings.tooManySelected), findsOneWidget);
      });

      testWidgets('exactly 1 000 still goes through', (tester) async {
        final (controller, events) = await _pump(tester, code, _state());
        final thousand = many.take(1000).toList();

        events.add(DropDone(_row(tester, _fpB), thousand, 1000));
        await _settleFrames(tester);

        expect(controller.sendPathsCalls, [thousand]);
        expect(find.byType(SnackBar), findsNothing);
      });

      testWidgets('a count above the paths received is ignored as a '
          'malformed drop', (tester) async {
        final (controller, events) = await _pump(tester, code, _state());

        events.add(DropDone(_row(tester, _fpA), _paths, 40));
        await _settleFrames(tester);

        expect(controller.calls, isEmpty);
        expect(find.byType(SnackBar), findsNothing);
      });
    });

    group('[$code] E558 holding over a device asks for the portal '
        '(RF-316)', () {
      testWidgets('0.5 s over one of mine that can receive asks once', (
        tester,
      ) async {
        final (controller, events) = await _pump(tester, code, _state());

        events.add(DropEnter(_row(tester, _fpA)));
        await tester.pump(const Duration(milliseconds: 499));
        expect(controller.calls, isEmpty);

        await tester.pump(const Duration(milliseconds: 2));
        expect(controller.calls, ['requestPortal $_fpA']);

        events.add(DropOver(_disc(tester, _fpA)));
        await tester.pump(const Duration(seconds: 2));
        expect(controller.calls, ['requestPortal $_fpA']);

        events.add(DropDone(_disc(tester, _fpA), _paths, 2));
        await _settleFrames(tester);
        expect(controller.calls.first, 'requestPortal $_fpA');
        expect(
          controller.calls.where((call) => call.startsWith('requestPortal')),
          hasLength(1),
        );
        expect(controller.sendPathsCalls, isEmpty);
        expect(find.byType(DestinationMenu), findsOneWidget);
      });

      testWidgets('leaving at 0.3 s cancels it', (tester) async {
        final (controller, events) = await _pump(tester, code, _state());

        events.add(DropEnter(_row(tester, _fpA)));
        await tester.pump(const Duration(milliseconds: 300));
        events.add(DropOver(_empty));
        await tester.pump(const Duration(seconds: 1));

        expect(controller.calls, isEmpty);
      });

      testWidgets('leaving the window cancels it', (tester) async {
        final (controller, events) = await _pump(tester, code, _state());

        events.add(DropEnter(_row(tester, _fpA)));
        await tester.pump(const Duration(milliseconds: 300));
        events.add(const DropLeave());
        await tester.pump(const Duration(seconds: 1));

        expect(controller.calls, isEmpty);
      });

      testWidgets('moving to another device restarts the count', (
        tester,
      ) async {
        final (controller, events) = await _pump(tester, code, _state());

        events.add(DropEnter(_row(tester, _fpB)));
        await tester.pump(const Duration(milliseconds: 300));
        events.add(DropOver(_row(tester, _fpA)));
        await tester.pump(const Duration(milliseconds: 300));
        expect(controller.calls, isEmpty);

        await tester.pump(const Duration(milliseconds: 250));
        expect(controller.calls, ['requestPortal $_fpA']);
      });

      testWidgets('a foreign device never asks, and dropping still sends', (
        tester,
      ) async {
        final (controller, events) = await _pump(tester, code, _state());

        events.add(DropEnter(_row(tester, _fpB)));
        await tester.pump(const Duration(seconds: 1));
        expect(controller.calls, isEmpty);

        events.add(DropDone(_row(tester, _fpB), _paths, 2));
        await _settleFrames(tester);
        expect(controller.calls, ['sendPaths $_fpB ${_paths.join('|')}']);
      });

      testWidgets('a device that cannot receive never asks', (tester) async {
        final (controller, events) = await _pump(
          tester,
          code,
          _state(sendingTo: _fpB),
        );

        events.add(DropEnter(_row(tester, _fpA)));
        await tester.pump(const Duration(seconds: 1));

        expect(controller.calls, isEmpty);
      });
    });

    group('[$code] drag events through the real channel', () {
      testWidgets('at 150 % the physical pixels land on the right device', (
        tester,
      ) async {
        tester.view.physicalSize = const Size(1800, 1200);
        tester.view.devicePixelRatio = 1.5;
        addTearDown(tester.view.reset);
        final controller = FakeAppController(state: _state());
        await pumpHome(tester, controller, code);
        final logical = _row(tester, _fpB);
        final physical = logical * 1.5;

        await sendDropCall('enter', {'x': physical.dx, 'y': physical.dy});
        await tester.pump(_fade);
        expect(_flow(tester).hot, _fpB);

        await sendDropCall('drop', {
          'x': physical.dx.round(),
          'y': physical.dy.round(),
          'count': 2,
          'paths': _paths,
        });
        await _settleFrames(tester);

        expect(controller.calls, ['sendPaths $_fpB ${_paths.join('|')}']);
      });

      testWidgets('a malformed event does nothing', (tester) async {
        final controller = FakeAppController(state: _state());
        tester.view.physicalSize = const Size(1200, 800);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        await pumpHome(tester, controller, code);

        await sendDropCall('enter', {'x': 'left', 'y': 5});
        await sendDropCall('drop', {'x': 5, 'y': 5, 'count': 1, 'paths': 7});
        await tester.pump(_fade);

        expect(find.text(strings.dragHint), findsNothing);
        expect(controller.calls, isEmpty);
      });
    });

    group('[$code] E555 to E557 the To send tray (RF-310 to RF-312)', () {
      final tray = [
        const TrayItemView(id: 't1', name: 'contrato.pdf', isFolder: false),
        const TrayItemView(id: 't2', name: 'fotos', isFolder: true),
        const TrayItemView(id: 't3', name: 'notas.txt', isFolder: false),
      ];

      testWidgets('empty it takes no room', (tester) async {
        await _pump(tester, code, _state());

        expect(find.byType(TrayPanel), findsNothing);
        expect(tester.getSize(find.byType(TrayHost)).height, 0);
      });

      testWidgets('with items it shows the count and each name', (
        tester,
      ) async {
        await _pump(tester, code, _state(tray: tray));

        expect(find.text(strings.trayTitle(3)), findsOneWidget);
        expect(find.text('contrato.pdf'), findsOneWidget);
        expect(find.text('fotos'), findsOneWidget);
        expect(find.text('notas.txt'), findsOneWidget);
      });

      testWidgets('it appears and disappears with the state', (tester) async {
        final (controller, _) = await _pump(tester, code, _state());

        controller.emit(_state(tray: tray));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 600));
        expect(find.byType(TrayPanel), findsOneWidget);

        controller.emit(_state());
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 600));
        expect(find.byType(TrayPanel), findsNothing);
        expect(tester.getSize(find.byType(TrayHost)).height, 0);
      });

      testWidgets('removing one calls the controller with its id', (
        tester,
      ) async {
        final (controller, _) = await _pump(tester, code, _state(tray: tray));

        await tester.tap(find.byTooltip(strings.queueRemove).at(1));
        await tester.pump();

        expect(controller.calls, ['removeFromTray t2']);
      });

      testWidgets('remove all calls the controller', (tester) async {
        final (controller, _) = await _pump(tester, code, _state(tray: tray));

        await tester.tap(find.byKey(const ValueKey('tray-remove-all')));
        await tester.pump();

        expect(controller.calls, ['clearTray']);
      });

      testWidgets('send to a device sends the whole tray', (tester) async {
        final (controller, _) = await _pump(tester, code, _state(tray: tray));

        await tester.tap(
          find.descendant(
            of: find.byKey(ValueKey('tray-send-$_fpB')),
            matching: find.text(strings.traySendTo('Torre')),
          ),
        );
        await _settleFrames(tester);

        expect(controller.calls, ['sendTray $_fpB']);
      });

      testWidgets('a device that is not visible is off with its reason', (
        tester,
      ) async {
        final (controller, _) = await _pump(
          tester,
          code,
          _state(tray: tray, hiddenC: true),
        );
        final row = find.byKey(ValueKey('tray-send-$_fpC'));

        expect(
          find.descendant(
            of: row,
            matching: find.text(strings.sendNeedsVisible),
          ),
          findsOneWidget,
        );
        await tester.tap(
          find.descendant(
            of: row,
            matching: find.text(strings.traySendTo('Portatil')),
          ),
          warnIfMissed: false,
        );
        await tester.pump();

        expect(controller.calls, isEmpty);
      });

      testWidgets('while sending to A, B is off and says to wait', (
        tester,
      ) async {
        await _pump(tester, code, _state(tray: tray, sendingTo: _fpA));

        expect(
          find.descendant(
            of: find.byKey(ValueKey('tray-send-$_fpB')),
            matching: find.text(strings.waitForQueues('PC principal')),
          ),
          findsOneWidget,
        );
      });

      testWidgets('a refused send of the tray explains the reason', (
        tester,
      ) async {
        final (controller, _) = await _pump(tester, code, _state(tray: tray));
        controller.sendTrayResult = SendResult.unavailable;

        await tester.tap(find.text(strings.traySendTo('Torre')));
        await _settleFrames(tester);

        expect(find.text(strings.sendUnavailable), findsOneWidget);
      });

      testWidgets('with the keyboard: focus a Remove button and press Enter', (
        tester,
      ) async {
        final (controller, _) = await _pump(tester, code, _state(tray: tray));
        final cross = find
            .descendant(
              of: find.byKey(const ValueKey('tray-item-t3')),
              matching: find.byType(GestureDetector),
            )
            .first;
        Focus.of(tester.element(cross)).requestFocus();
        await tester.pump();

        await tester.sendKeyEvent(LogicalKeyboardKey.enter);
        await tester.pump();

        expect(controller.calls, ['removeFromTray t3']);
      });

      testWidgets('the new buttons are at least 44 px tall', (tester) async {
        await _pump(tester, code, _state(tray: tray));

        for (final finder in [
          find.byKey(const ValueKey('tray-remove-all')),
          find.byKey(const ValueKey('tray-item-t1')),
          find.descendant(
            of: find.byKey(ValueKey('tray-send-$_fpA')),
            matching: find.byType(TextButton),
          ),
          find.descendant(
            of: find.byKey(const ValueKey('tray-item-t1')),
            matching: find.byType(GestureDetector),
          ),
        ]) {
          expect(tester.getSize(finder).height, greaterThanOrEqualTo(44));
        }
        expect(
          tester
              .getSize(
                find.descendant(
                  of: find.byKey(const ValueKey('tray-item-t1')),
                  matching: find.byType(GestureDetector),
                ),
              )
              .width,
          greaterThanOrEqualTo(44),
        );
      });
    });
  }
}
