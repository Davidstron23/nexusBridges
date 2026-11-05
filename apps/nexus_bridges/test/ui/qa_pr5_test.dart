import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nexus_bridges/src/drop/drop_events.dart';
import 'package:nexus_bridges/src/l10n/app_strings.dart';
import 'package:nexus_bridges/src/ui/activity_cards.dart';
import 'package:nexus_bridges/src/ui/diagram/flow_painter.dart';
import 'package:nexus_bridges/src/ui/exit_flow.dart';
import 'package:nexus_bridges/src/ui/home_screen.dart';
import 'package:nexus_bridges/src/ui/incoming_cards.dart';
import 'package:nexus_bridges/src/ui/modal/modal_frame.dart';
import 'package:nexus_bridges/src/ui/queue_card.dart';
import 'package:nexus_bridges/src/ui/theme/app_theme.dart';
import 'package:nexus_bridges/src/ui/theme/components.dart';
import 'package:nexus_bridges/src/ui/tray_panel.dart';
import 'package:nexus_bridges_core/nexus_bridges_core.dart';

import '../drop/fake_drop_events.dart';
import 'fake_app_controller.dart';
import 'pairing_fixtures.dart' show entry;
import 'transfer_fixtures.dart';

final String _fpA = fingerprintOf('AAAA1111');
final String _fpB = fingerprintOf('BBBB2222');
final String _fpC = fingerprintOf('CCCC3333');
final String _fpD = fingerprintOf('DDDD4444');

const Duration _fade = Duration(milliseconds: 460);

const List<String> _paths = [r'C:\work\a.txt', r'C:\work\project'];

const Offset _empty = Offset(420, 740);

QueueItemView _item(
  String id,
  String name, {
  QueueItemState state = QueueItemState.pending,
  TransferOutcome? outcome,
  bool folder = false,
}) => QueueItemView(
  id: id,
  name: name,
  isFolder: folder,
  isArchive: name.endsWith('.zip'),
  state: state,
  outcome: outcome,
);

QueueItemView _delivered(String id, String name) =>
    _item(id, name, state: QueueItemState.done, outcome: TransferOutcome.saved);

SendQueuesView _queues({
  List<QueueItemView> loose = const [],
  List<QueueItemView> bundles = const [],
  bool? finished,
  int selectionId = 1,
  String? fingerprint,
}) {
  final all = [...loose, ...bundles];
  return SendQueuesView(
    selectionId: selectionId,
    peerFingerprint: fingerprint ?? senderFingerprint,
    peerName: senderName,
    loose: loose,
    bundles: bundles,
    finished:
        finished ??
        all.every(
          (item) =>
              item.state == QueueItemState.done ||
              item.state == QueueItemState.notSent,
        ),
    delivered: all
        .where(
          (item) =>
              item.state == QueueItemState.done &&
              item.outcome == TransferOutcome.saved,
        )
        .length,
    total: all.length,
    completedBytes: 0,
    pendingKnownBytes: 0,
    currentProbeSize: null,
  );
}

String _numbered(String prefix, int i, String extension) =>
    '$prefix${i.toString().padLeft(4, '0')}$extension';

NodeState _dropState({
  bool swapped = false,
  List<TrayItemView> tray = const [],
}) {
  final a = entry(
    fingerprint: _fpA,
    name: 'PC principal',
    paired: true,
    mine: true,
  );
  final b = entry(fingerprint: _fpB, name: 'Torre', paired: true);
  return NodeState(
    entries: [
      if (swapped) ...[b, a] else ...[a, b],
      entry(fingerprint: _fpC, name: 'Portatil', paired: true),
      entry(fingerprint: _fpD, name: 'Movil'),
    ],
    tray: tray,
  );
}

Future<(FakeAppController, FakeDropEvents)> _pumpDrop(
  WidgetTester tester,
  String code,
  NodeState state,
) async {
  tester.view.physicalSize = const Size(1200, 800);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final controller = FakeAppController(state: state);
  final events = FakeDropEvents();
  addTearDown(events.close);
  await pumpHome(tester, controller, code, dropEvents: events);
  return (controller, events);
}

Offset _row(WidgetTester tester, String fingerprint) =>
    tester.getCenter(find.byKey(ValueKey(fingerprint)));

FlowPainter _flow(WidgetTester tester) {
  for (final paint in tester.widgetList<CustomPaint>(
    find.byType(CustomPaint),
  )) {
    final painter = paint.foregroundPainter;
    if (painter is FlowPainter) return painter;
  }
  throw StateError('no flow painter');
}

Future<void> _frames(WidgetTester tester) async {
  await tester.pump();
  await tester.pump();
}

void _openModal(WidgetTester tester) {
  unawaited(
    showDialog<void>(
      context: tester.element(find.byType(HomeScreen)),
      builder: (_) => const AlertDialog(content: Text('modal')),
    ),
  );
}

RenderParagraph _paragraph(WidgetTester tester, Finder text) =>
    tester.renderObject<RenderParagraph>(
      find.descendant(of: text, matching: find.byType(RichText)).first,
    );

void _expectWhole(WidgetTester tester, Finder text, String reason) {
  final paragraph = _paragraph(tester, text);
  expect(paragraph.didExceedMaxLines, isFalse, reason: reason);
  expect(
    paragraph.textSize.width,
    lessThanOrEqualTo(paragraph.size.width + 0.5),
    reason: '$reason width',
  );
  expect(
    paragraph.textSize.height,
    lessThanOrEqualTo(paragraph.size.height + 0.5),
    reason: '$reason height',
  );
}

void _expectInside(WidgetTester tester, Finder inner, Finder outer) {
  final a = tester.getRect(inner);
  final b = tester.getRect(outer);
  expect(a.left, greaterThanOrEqualTo(b.left - 0.5));
  expect(a.top, greaterThanOrEqualTo(b.top - 0.5));
  expect(a.right, lessThanOrEqualTo(b.right + 0.5));
  expect(a.bottom, lessThanOrEqualTo(b.bottom + 0.5));
}

Widget _plainApp(String code, Widget child, {TextStyle? defaultStyle}) {
  return MaterialApp(
    locale: Locale(code),
    supportedLocales: const [Locale('en'), Locale('es')],
    localizationsDelegates: const [
      AppStringsDelegate(),
      GlobalMaterialLocalizations.delegate,
      GlobalWidgetsLocalizations.delegate,
      GlobalCupertinoLocalizations.delegate,
    ],
    theme: buildTheme(Brightness.light),
    home: Scaffold(
      body: Align(
        alignment: Alignment.topLeft,
        child: SizedBox(
          width: 300,
          child: defaultStyle == null
              ? child
              : DefaultTextStyle.merge(style: defaultStyle, child: child),
        ),
      ),
    ),
  );
}

void main() {
  for (final code in languageCodes) {
    final strings = stringsFor(code);
    final card = find.byType(QueueCard);

    group('[$code] Q-2, RF-295, RF-301: a queue card with 1 000 items', () {
      List<QueueItemView> thousand({int running = 3}) => [
        for (var i = 0; i < 1000; i++)
          i < running
              ? _delivered('l$i', _numbered('f', i, '.txt'))
              : _item(
                  'l$i',
                  _numbered('f', i, '.txt'),
                  state: i == running
                      ? QueueItemState.inProgress
                      : QueueItemState.pending,
                ),
      ];

      testWidgets('Q-2 at 1280x720 the item in course and Cancel all are on '
          'screen and can be tapped without scrolling, and only a few rows '
          'are built', (tester) async {
        setWindow(tester, const Size(1280, 720));
        final queues = _queues(loose: thousand());
        final controller = FakeAppController(
          state: NodeState(
            entries: [
              entry(
                fingerprint: senderFingerprint,
                name: senderName,
                paired: true,
                mine: true,
              ),
            ],
            queues: queues,
            outgoing: outgoingView(fileName: 'f0003.txt'),
            sendingTo: senderFingerprint,
            transferInProgress: true,
          ),
        );
        await pumpHome(tester, controller, code, settle: false);

        final screen = Offset.zero & const Size(1280, 720);
        final cancelAll = textIn(card, strings.queueCancelAll);
        expect(cancelAll.hitTestable(), findsOneWidget);
        expect(screen.contains(tester.getCenter(cancelAll)), isTrue);
        final running = textIn(card, 'f0003.txt');
        expect(running.hitTestable(), findsOneWidget);
        expect(screen.contains(tester.getCenter(running)), isTrue);
        final cancel = textIn(card, strings.cancelButton);
        expect(cancel.hitTestable(), findsOneWidget);
        expect(textIn(card, strings.queueRemaining(996)), findsOneWidget);

        final rows = find.byWidgetPredicate(
          (widget) =>
              widget.key is ValueKey<String> &&
              (widget.key! as ValueKey<String>).value.startsWith('queue-row-'),
        );
        expect(rows.evaluate().length, lessThan(30));
        expect(textIn(card, 'f0500.txt'), findsNothing);

        await tester.tap(cancelAll);
        await tester.pump();
        expect(controller.calls, contains('cancelAllQueued'));
      });

      testWidgets('Q-2 a section of more than 20 items starts folded, one of '
          '20 starts open, and an open long section is a bounded list', (
        tester,
      ) async {
        final loose = [
          for (var i = 0; i < 20; i++)
            _item(
              'l$i',
              _numbered('a', i, '.txt'),
              state: i == 0
                  ? QueueItemState.inProgress
                  : QueueItemState.pending,
            ),
        ];
        final bundles = [
          for (var i = 0; i < 21; i++) _item('b$i', _numbered('z', i, '.zip')),
        ];
        setWindow(tester, const Size(800, 1800));
        final controller = FakeAppController(
          state: NodeState(
            queues: _queues(loose: loose, bundles: bundles),
            transferInProgress: true,
          ),
        );
        await tester.pumpWidget(
          columnApp(
            controller,
            code,
            (current) => ActivityPanel(controller: controller, state: current),
          ),
        );
        await tester.pump();

        expect(textIn(card, 'a0001.txt'), findsOneWidget);
        expect(textIn(card, 'z0000.zip'), findsNothing);
        final looseList = find.byKey(
          ValueKey('queue-list-${strings.looseQueue}'),
        );
        expect(looseList, findsOneWidget);
        expect(tester.getSize(looseList).height, lessThanOrEqualTo(300));

        await tester.tap(textIn(card, strings.bundleQueue));
        await tester.pumpAndSettle();

        final bundleList = find.byKey(
          ValueKey('queue-list-${strings.bundleQueue}'),
        );
        expect(bundleList, findsOneWidget);
        expect(tester.getSize(bundleList).height, lessThanOrEqualTo(300));
        expect(textIn(card, 'z0000.zip'), findsOneWidget);
        expect(textIn(card, 'z0020.zip'), findsNothing);

        await tester.drag(bundleList, const Offset(0, -2000));
        await tester.pumpAndSettle();
        expect(textIn(card, 'z0020.zip'), findsOneWidget);
        expect(textIn(card, strings.queueCancelAll), findsOneWidget);
      });
    });

    group('[$code] Q-3, RF-284: what is active goes before the results', () {
      testWidgets('Q-3 a reception in course goes above a finished queue '
          'card', (tester) async {
        await pumpColumn(
          tester,
          code,
          NodeState(
            queues: _queues(
              loose: [_delivered('l1', 'a.pdf'), _delivered('l2', 'b.pdf')],
            ),
            incoming: incomingView(
              stage: IncomingStage.receiving,
              received: 512,
            ),
          ),
          (controller, state) =>
              ActivityPanel(controller: controller, state: state),
        );

        final incoming = find.byKey(const ValueKey('activity-incoming'));
        final queues = find.byKey(const ValueKey('activity-queues'));
        expect(incoming, findsOneWidget);
        expect(queues, findsOneWidget);
        expect(
          tester.getTopLeft(incoming).dy,
          lessThan(tester.getTopLeft(queues).dy),
        );
      });

      testWidgets('Q-3 a queue in course still goes above the reception', (
        tester,
      ) async {
        await pumpColumn(
          tester,
          code,
          NodeState(
            queues: _queues(
              loose: [
                _delivered('l1', 'a.pdf'),
                _item('l2', 'b.pdf', state: QueueItemState.inProgress),
              ],
            ),
            incoming: incomingView(
              stage: IncomingStage.receiving,
              received: 512,
            ),
            transferInProgress: true,
          ),
          (controller, state) =>
              ActivityPanel(controller: controller, state: state),
        );

        expect(
          tester.getTopLeft(find.byKey(const ValueKey('activity-queues'))).dy,
          lessThan(
            tester
                .getTopLeft(find.byKey(const ValueKey('activity-incoming')))
                .dy,
          ),
        );
      });
    });

    group('[$code] Q-4: a long name keeps its whole extension', () {
      final name =
          '${('Informe trimestral de resultados consolidados ' * 4).substring(0, 111)}2026';
      final long = '$name.xlsx';

      for (final spacing in [0.25, 1.0]) {
        testWidgets('Q-4 with letterSpacing $spacing inherited from the '
            'default style, 120 characters in 300 px end in .xlsx and do not '
            'overflow', (tester) async {
          expect(long.length, 120);
          await tester.pumpWidget(
            _plainApp(
              code,
              FittedName(name: long, style: const TextStyle(fontSize: 14)),
              defaultStyle: TextStyle(letterSpacing: spacing),
            ),
          );

          final text = tester.widget<Text>(
            find.descendant(
              of: find.byType(FittedName),
              matching: find.byType(Text),
            ),
          );
          expect(text.data, endsWith('.xlsx'));
          expect(text.data, contains('\u2026'));
          final paragraph = _paragraph(tester, find.byType(FittedName));
          expect(paragraph.didExceedMaxLines, isFalse);
          expect(paragraph.size.width, lessThanOrEqualTo(300));
          expect(
            paragraph.getMaxIntrinsicWidth(double.infinity),
            lessThanOrEqualTo(paragraph.size.width + 0.01),
          );
        });
      }

      testWidgets('Q-4 in the row of a queue the long name ends in .xlsx and '
          'fits', (tester) async {
        await pumpColumn(
          tester,
          code,
          NodeState(
            queues: _queues(
              loose: [
                _item('l1', long, state: QueueItemState.inProgress),
                _item('l2', 'b.pdf'),
              ],
            ),
            transferInProgress: true,
          ),
          (controller, state) =>
              ActivityPanel(controller: controller, state: state),
          width: 300,
        );

        final fitted = inside(card, find.byType(FittedName)).first;
        final text = tester.widget<Text>(
          find.descendant(of: fitted, matching: find.byType(Text)),
        );
        expect(text.data, endsWith('.xlsx'));
        final paragraph = _paragraph(tester, fitted);
        expect(paragraph.didExceedMaxLines, isFalse);
        expect(
          paragraph.getMaxIntrinsicWidth(double.infinity),
          lessThanOrEqualTo(paragraph.size.width + 0.01),
        );
      });
    });

    group('[$code] Q-5, RF-285: the card after Cancel all', () {
      testWidgets('Q-5 Cancelled chip and "n of m delivered" counting what was '
          'not sent', (tester) async {
        await pumpColumn(
          tester,
          code,
          NodeState(
            queues: _queues(
              loose: [
                _delivered('l1', 'a.pdf'),
                _delivered('l2', 'b.pdf'),
                _delivered('l3', 'c.pdf'),
                _item(
                  'l4',
                  'd.pdf',
                  state: QueueItemState.done,
                  outcome: TransferOutcome.cancelledHere,
                ),
                for (var i = 5; i < 10; i++)
                  _item(
                    'l$i',
                    'p$i.pdf',
                    state: QueueItemState.notSent,
                    outcome: TransferOutcome.cancelledHere,
                  ),
              ],
            ),
          ),
          (controller, state) =>
              ActivityPanel(controller: controller, state: state),
        );

        expect(chipIn(tester, card).label, strings.chipCancelled);
        expect(chipIn(tester, card).tone, isNot(ChipTone.ok));
        expect(textIn(card, strings.chipDelivered), findsNothing);
        expect(textIn(card, strings.deliveredSummary(3, 9)), findsWidgets);
        expect(textIn(card, strings.deliveredSummary(3, 3)), findsNothing);

        await tester.tap(textIn(card, strings.looseQueue));
        await tester.pumpAndSettle();
        expect(
          textIn(
            card,
            strings.queueNotSent(
              strings.sentOutcome(TransferOutcome.cancelledHere),
            ),
          ),
          findsWidgets,
        );
      });

      testWidgets('Q-5 the item in course cancelled also leaves the card '
          'cancelled and counts in the total', (tester) async {
        await pumpColumn(
          tester,
          code,
          NodeState(
            queues: _queues(
              loose: [
                _delivered('l1', 'a.pdf'),
                _delivered('l2', 'b.pdf'),
                _item(
                  'l3',
                  'c.pdf',
                  state: QueueItemState.done,
                  outcome: TransferOutcome.cancelledHere,
                ),
              ],
            ),
          ),
          (controller, state) =>
              ActivityPanel(controller: controller, state: state),
        );

        expect(chipIn(tester, card).label, strings.chipCancelled);
        expect(textIn(card, strings.deliveredSummary(2, 3)), findsWidgets);
      });
    });

    group('[$code] Q-6: one message at a time when dropping', () {
      testWidgets('Q-6 a second message replaces the first at once', (
        tester,
      ) async {
        final (controller, events) = await _pumpDrop(
          tester,
          code,
          _dropState(),
        );
        controller.addToTrayResult = TrayResult.nothingNew;

        events.add(DropDone(_empty, _paths, 2));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 750));
        expect(find.text(strings.trayNothingNew), findsOneWidget);

        final many = [for (var i = 0; i < 1001; i++) 'C:\\many\\f$i'];
        events.add(DropDone(_row(tester, _fpA), many, 5000));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 400));
        await tester.pump(const Duration(milliseconds: 400));

        expect(find.text(strings.tooManySelected), findsOneWidget);
        expect(find.text(strings.trayNothingNew), findsNothing);
        expect(find.byType(SnackBar), findsOneWidget);
      });
    });

    group('[$code] Q-8, RF-285: Last sent with a single send after queues', () {
      testWidgets('Q-8 while a single send runs, Last sent is the summary of '
          'the previous queues and not their last item', (tester) async {
        await pumpColumn(
          tester,
          code,
          NodeState(
            outgoing: outgoingView(fileName: 'proyecto'),
            lastQueues: _queues(
              loose: [
                _delivered('l1', 'a.pdf'),
                _delivered('l2', 'b.pdf'),
                _delivered('l3', 'c.pdf'),
              ],
              bundles: [_delivered('b1', 'archivo.zip')],
            ),
            lastSent: resultView(
              direction: TransferDirection.outgoing,
              fileName: 'archivo.zip',
            ),
            transferInProgress: true,
          ),
          (controller, state) =>
              ActivityPanel(controller: controller, state: state),
        );

        final last = find.byKey(const ValueKey('activity-last-queues'));
        final outgoing = find.byKey(const ValueKey('activity-outgoing'));
        expect(last, findsOneWidget);
        expect(outgoing, findsOneWidget);
        expect(find.byKey(const ValueKey('activity-last-sent')), findsNothing);
        expect(textIn(last, strings.lastSentTitle), findsOneWidget);
        expect(textIn(last, strings.deliveredSummary(4, 4)), findsWidgets);
        expect(chipIn(tester, last).label, strings.chipDelivered);
        expect(
          tester.getTopLeft(outgoing).dy,
          lessThan(tester.getTopLeft(last).dy),
        );
      });

      testWidgets('Q-8 without previous queues Last sent is still the last '
          'result', (tester) async {
        await pumpColumn(
          tester,
          code,
          NodeState(
            outgoing: outgoingView(fileName: 'proyecto'),
            lastSent: resultView(
              direction: TransferDirection.outgoing,
              fileName: 'archivo.zip',
            ),
            transferInProgress: true,
          ),
          (controller, state) =>
              ActivityPanel(controller: controller, state: state),
        );

        expect(
          find.byKey(const ValueKey('activity-last-queues')),
          findsNothing,
        );
        expect(
          find.byKey(const ValueKey('activity-last-sent')),
          findsOneWidget,
        );
      });
    });

    group('[$code] Q-11, RF-310: the tray and the counters with big text', () {
      final tray = [
        const TrayItemView(id: 't1', name: 'contrato.pdf', isFolder: false),
        const TrayItemView(id: 't2', name: 'fotos', isFolder: true),
        const TrayItemView(id: 't3', name: 'notas.txt', isFolder: false),
      ];

      Future<void> pumpBig(WidgetTester tester, double scale) async {
        setWindow(tester, const Size(970, 720));
        tester.platformDispatcher.textScaleFactorTestValue = scale;
        addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
        final controller = FakeAppController(state: _dropState(tray: tray));
        await pumpHome(tester, controller, code);
        expect(tester.takeException(), isNull);
      }

      for (final scale in [1.5, 2.0]) {
        final percent = (scale * 100).round();

        testWidgets('Q-11 at $percent % in a window of 970 px the tray title '
            'keeps its count, whole and inside the panel', (tester) async {
          await pumpBig(tester, scale);

          final panel = find.byType(TrayPanel);
          final title = find.text(strings.trayTitle(3));
          expect(title, findsOneWidget);
          _expectWhole(tester, title, 'tray title');
          _expectInside(tester, title, panel);
          _expectInside(
            tester,
            find.byKey(const ValueKey('tray-remove-all')),
            panel,
          );
        });

        testWidgets('Q-11 at $percent % the chip of a device of mine is not '
            'cut', (tester) async {
          await pumpBig(tester, scale);

          final chips = find.widgetWithText(StatusChip, strings.chipMine);
          expect(chips, findsWidgets);
          for (var i = 0; i < chips.evaluate().length; i++) {
            final chip = chips.at(i);
            final label = find.descendant(
              of: chip,
              matching: find.text(strings.chipMine),
            );
            _expectWhole(tester, label, 'chip $i');
            _expectInside(tester, label, chip);
          }
        });

        testWidgets('Q-11 at $percent % the counter of the devices tab is not '
            'cut', (tester) async {
          await pumpBig(tester, scale);

          final tab = find
              .ancestor(
                of: find.text(strings.devicesTab),
                matching: find.byType(InkWell),
              )
              .first;
          final badge = find.descendant(of: tab, matching: find.text('3'));
          expect(badge, findsOneWidget);
          final box = find
              .ancestor(of: badge, matching: find.byType(Container))
              .first;
          _expectWhole(tester, badge, 'badge');
          _expectInside(tester, badge, box);
        });
      }
    });

    group('[$code] Q-14 and B-1: where a drop goes', () {
      testWidgets('Q-14 with a modal on top nothing lights up, there is no '
          'hint and the drop goes to the tray as outside', (tester) async {
        final (controller, events) = await _pumpDrop(
          tester,
          code,
          _dropState(),
        );
        _openModal(tester);
        await tester.pumpAndSettle();

        events.add(DropEnter(_row(tester, _fpA)));
        await tester.pump();
        await tester.pump(_fade);
        expect(find.text(strings.dragHint), findsNothing);
        expect(_flow(tester).hot, isNull);
        expect(_flow(tester).dragFade!.value, 0);

        events.add(DropOver(_row(tester, _fpB)));
        await tester.pump(_fade);
        expect(find.text(strings.dragHint), findsNothing);

        events.add(DropDone(_row(tester, _fpA), _paths, 2));
        await _frames(tester);
        expect(controller.calls, ['addToTray ${_paths.join('|')} 2']);
        expect(controller.sendPathsCalls, isEmpty);
        expect(find.byType(SnackBar), findsNothing);

        Navigator.of(tester.element(find.text('modal'))).pop();
        await tester.pumpAndSettle();
        events.add(DropEnter(_row(tester, _fpB)));
        await tester.pump();
        await tester.pump(_fade);
        expect(find.text(strings.dragHint), findsOneWidget);
        events.add(DropDone(_row(tester, _fpB), _paths, 2));
        await _frames(tester);
        expect(controller.sendPathsCalls, [_paths]);
      });

      testWidgets('Q-14 a modal that opens during the drag puts the hint '
          'away', (tester) async {
        final (controller, events) = await _pumpDrop(
          tester,
          code,
          _dropState(),
        );

        events.add(DropEnter(_row(tester, _fpB)));
        await tester.pump();
        await tester.pump(_fade);
        expect(find.text(strings.dragHint), findsOneWidget);

        _openModal(tester);
        await tester.pump();
        await tester.pump(_fade);
        events.add(DropOver(_row(tester, _fpB)));
        await tester.pump();
        await tester.pump(_fade);
        await tester.pump(_fade);
        expect(find.text(strings.dragHint), findsNothing);
        expect(_flow(tester).hot, isNull);

        events.add(DropDone(_row(tester, _fpB), _paths, 2));
        await _frames(tester);
        expect(controller.sendPathsCalls, isEmpty);
        expect(controller.addToTrayCalls, [_paths]);
      });

      testWidgets('B-1 if the list reorders between the last over and the '
          'drop, it goes to the tray as outside and never to the device now '
          'under the pointer', (tester) async {
        final (controller, events) = await _pumpDrop(
          tester,
          code,
          _dropState(),
        );
        final lit = _row(tester, _fpA);

        events.add(DropEnter(lit));
        await tester.pump();
        await tester.pump(_fade);
        expect(_flow(tester).hot, _fpA);

        controller.emit(_dropState(swapped: true));
        await _frames(tester);
        expect((_row(tester, _fpB) - lit).distance, lessThan(1));

        events.add(DropDone(lit, _paths, 2));
        await _frames(tester);

        expect(controller.sendPathsCalls, isEmpty);
        expect(controller.calls, ['addToTray ${_paths.join('|')} 2']);
        expect(find.byType(SnackBar), findsNothing);
      });

      testWidgets('B-1 with the same device under the pointer it is still '
          'sent', (tester) async {
        final (controller, events) = await _pumpDrop(
          tester,
          code,
          _dropState(),
        );

        events.add(DropEnter(_row(tester, _fpA)));
        await tester.pump(_fade);
        events.add(DropOver(_row(tester, _fpB)));
        await tester.pump(_fade);
        events.add(DropDone(_row(tester, _fpB), _paths, 2));
        await _frames(tester);

        expect(controller.calls, ['sendPaths $_fpB ${_paths.join('|')}']);
      });

      testWidgets('B-1 a drop without a previous enter goes to the device '
          'under the pointer', (tester) async {
        final (controller, events) = await _pumpDrop(
          tester,
          code,
          _dropState(),
        );

        events.add(DropDone(_row(tester, _fpB), _paths, 2));
        await _frames(tester);

        expect(controller.calls, ['sendPaths $_fpB ${_paths.join('|')}']);
        expect(controller.addToTrayCalls, isEmpty);
      });
    });

    group('[$code] B-4, RF-271: first level names of a foreign folder', () {
      testWidgets('B-4 a long name keeps its extension, cut in the middle', (
        tester,
      ) async {
        const tricky =
            'Factura_marzo_2026_definitiva_revisada_firmada________.pdf.exe';
        await pumpColumn(
          tester,
          code,
          NodeState(
            incoming: IncomingTransferView(
              sessionId: 's1',
              peerFingerprint: senderFingerprint,
              peerName: senderName,
              fileName: 'proyecto',
              size: 1536,
              isProgram: true,
              stage: IncomingStage.warning,
              receivedBytes: 0,
              isFolder: true,
              fileCount: 3,
              firstLevel: const [
                FirstLevelItem(name: tricky, isFolder: false),
                FirstLevelItem(name: 'src', isFolder: true),
              ],
            ),
          ),
          (controller, state) =>
              IncomingCards(controller: controller, state: state),
        );

        final list = find.byKey(const ValueKey('first-level-list'));
        final fitted = inside(list, find.byType(FittedName)).first;
        final text = tester.widget<Text>(
          find.descendant(of: fitted, matching: find.byType(Text)),
        );
        expect(text.data, isNot(tricky));
        expect(text.data, endsWith('.exe'));
        expect(text.data, contains('\u2026'));
        final paragraph = _paragraph(tester, fitted);
        expect(paragraph.didExceedMaxLines, isFalse);
        expect(
          paragraph.getMaxIntrinsicWidth(double.infinity),
          lessThanOrEqualTo(paragraph.size.width + 0.01),
        );
      });
    });

    group('[$code] RF-299: closing with queues not finished', () {
      Future<GlobalKey<NavigatorState>> host(WidgetTester tester) async {
        setWindow(tester, const Size(800, 600));
        final key = GlobalKey<NavigatorState>();
        await tester.pumpWidget(
          MaterialApp(
            navigatorKey: key,
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(context).copyWith(disableAnimations: true),
              child: child!,
            ),
            locale: Locale(code),
            supportedLocales: const [Locale('en'), Locale('es')],
            localizationsDelegates: const [
              AppStringsDelegate(),
              GlobalMaterialLocalizations.delegate,
              GlobalWidgetsLocalizations.delegate,
              GlobalCupertinoLocalizations.delegate,
            ],
            home: const Scaffold(),
          ),
        );
        await tester.pumpAndSettle();
        return key;
      }

      Future<void> ask(
        WidgetTester tester,
        GlobalKey<NavigatorState> key,
        NodeState state,
      ) async {
        unawaited(
          confirmCloseDuringTransfer(
            key.currentContext!,
            FakeAppController(state: state),
          ),
        );
        await tester.pumpAndSettle();
        expect(find.byType(NbModal), findsOneWidget);
      }

      test('RF-299 the new text is its own and says the pending will not be '
          'sent', () {
        expect(strings.closeWithQueuesBody, isNotEmpty);
        expect(
          strings.closeWithQueuesBody,
          isNot(strings.closeDuringTransferBody),
        );
      });

      testWidgets('RF-299 with queues still running the dialog says that '
          'what is pending will not be sent', (tester) async {
        final key = await host(tester);
        await ask(
          tester,
          key,
          NodeState(
            transferInProgress: true,
            queues: _queues(
              loose: [
                _item('l1', 'a.pdf', state: QueueItemState.inProgress),
                _item('l2', 'b.pdf'),
              ],
            ),
          ),
        );

        expect(find.text(strings.closeDuringTransferTitle), findsOneWidget);
        expect(find.text(strings.closeWithQueuesBody), findsOneWidget);
        expect(find.text(strings.closeDuringTransferBody), findsNothing);
        await tester.tap(find.text(strings.keepOpenButton));
        await tester.pumpAndSettle();
      });

      testWidgets('RF-299 a single send or finished queues keep the usual '
          'text', (tester) async {
        final key = await host(tester);
        await ask(tester, key, const NodeState(transferInProgress: true));
        expect(find.text(strings.closeDuringTransferBody), findsOneWidget);
        expect(find.text(strings.closeWithQueuesBody), findsNothing);
        await tester.tap(find.text(strings.keepOpenButton));
        await tester.pumpAndSettle();

        await ask(
          tester,
          key,
          NodeState(
            transferInProgress: true,
            queues: _queues(loose: [_delivered('l1', 'a.pdf')]),
          ),
        );
        expect(find.text(strings.closeDuringTransferBody), findsOneWidget);
        expect(find.text(strings.closeWithQueuesBody), findsNothing);
        await tester.tap(find.text(strings.keepOpenButton));
        await tester.pumpAndSettle();
      });
    });
  }
}
