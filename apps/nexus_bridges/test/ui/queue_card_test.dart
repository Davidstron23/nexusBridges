import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nexus_bridges/src/l10n/app_strings.dart';
import 'package:nexus_bridges/src/ui/activity_cards.dart';
import 'package:nexus_bridges/src/ui/format.dart';
import 'package:nexus_bridges/src/ui/queue_card.dart';
import 'package:nexus_bridges/src/ui/theme/components.dart';
import 'package:nexus_bridges_core/nexus_bridges_core.dart';

import 'fake_app_controller.dart';
import 'transfer_fixtures.dart';

QueueItemView _item(
  String id,
  String name, {
  QueueItemState state = QueueItemState.pending,
  bool folder = false,
  TransferOutcome? outcome,
  String? problemPath,
}) {
  return QueueItemView(
    id: id,
    name: name,
    isFolder: folder,
    isArchive: name.endsWith('.zip'),
    state: state,
    outcome: outcome,
    problemPath: problemPath,
  );
}

QueueItemView _delivered(String id, String name, {bool folder = false}) =>
    _item(
      id,
      name,
      state: QueueItemState.done,
      outcome: TransferOutcome.saved,
      folder: folder,
    );

SendQueuesView _queues({
  List<QueueItemView> loose = const [],
  List<QueueItemView> bundles = const [],
  bool finished = false,
  int? delivered,
  int selectionId = 1,
}) {
  final all = [...loose, ...bundles];
  return SendQueuesView(
    selectionId: selectionId,
    peerFingerprint: senderFingerprint,
    peerName: senderName,
    loose: loose,
    bundles: bundles,
    finished: finished,
    delivered:
        delivered ??
        all
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

NodeState _state(
  SendQueuesView queues, {
  OutgoingTransferView? outgoing,
  TransferResultView? lastSent,
  SelectionProgress? progress,
}) {
  return NodeState(
    queues: queues,
    outgoing: outgoing,
    lastSent: lastSent,
    selectionProgress: progress,
    transferInProgress: !queues.finished,
  );
}

Future<FakeAppController> _pump(
  WidgetTester tester,
  String code,
  NodeState state,
) async {
  setWindow(tester, const Size(800, 1800));
  final controller = FakeAppController(state: state);
  await tester.pumpWidget(
    columnApp(
      controller,
      code,
      (current) => ActivityPanel(controller: controller, state: current),
    ),
  );
  await tester.pump();
  return controller;
}

final Finder _card = find.byType(QueueCard);

Finder _text(String text) => textIn(_card, text);

Finder _tooltip(String message) => inside(
  _card,
  find.byWidgetPredicate(
    (widget) => widget is Tooltip && widget.message == message,
  ),
);

final SendQueuesView _running = _queues(
  loose: [
    _delivered('l1', 'acta.pdf'),
    _item('l2', 'informe.xlsx', state: QueueItemState.inProgress),
    _item('l3', 'zeta.txt'),
  ],
  bundles: [_item('b1', 'proyecto', folder: true)],
);

OutgoingTransferView get _uploading =>
    outgoingView(fileName: 'informe.xlsx', size: 2048, sent: 512);

void main() {
  for (final code in languageCodes) {
    final strings = stringsFor(code);

    group('[$code] E545 queue card (RF-295 to RF-297, RF-301)', () {
      testWidgets('shows the two queues, the state of each item and the '
          'progress of the one in course', (tester) async {
        await _pump(tester, code, _state(_running, outgoing: _uploading));

        expect(_text(strings.queueTitle(senderName)), findsOneWidget);
        expect(chipIn(tester, _card).label, strings.chipInProgress);
        expect(_text(strings.looseQueue), findsOneWidget);
        expect(_text(strings.bundleQueue), findsOneWidget);
        expect(_text(strings.deliveredSummary(1, 3)), findsOneWidget);
        expect(_text(strings.deliveredSummary(0, 1)), findsOneWidget);
        for (final name in ['acta.pdf', 'informe.xlsx', 'zeta.txt']) {
          expect(_text(name), findsOneWidget);
        }
        expect(_text('proyecto'), findsOneWidget);
        expect(_text(strings.chipDelivered), findsOneWidget);
        expect(_text(strings.queuePending), findsNWidgets(2));
        expect(
          _text(
            strings.progressLine(
              25,
              formatSize(512, code),
              formatSize(2048, code),
            ),
          ),
          findsOneWidget,
        );
        expect(_text(strings.queueRemaining(2)), findsOneWidget);
        expect(_text(strings.queueCancelAll), findsOneWidget);
        expect(find.byType(NbProgressBar), findsNWidgets(2));
      });

      testWidgets('Remove on a pending item asks the controller to drop it, '
          'with a tooltip on the button', (tester) async {
        final controller = await _pump(
          tester,
          code,
          _state(_running, outgoing: _uploading),
        );

        expect(_tooltip(strings.queueRemove), findsNWidgets(2));
        await tester.tap(_tooltip(strings.queueRemove).first);
        await tester.pump();

        expect(controller.calls, ['removeQueueItem l3']);
      });

      testWidgets('Remove has a target of at least 44 px', (tester) async {
        await _pump(tester, code, _state(_running, outgoing: _uploading));

        final size = tester.getSize(_tooltip(strings.queueRemove).first);
        expect(size.width, greaterThanOrEqualTo(44));
        expect(size.height, greaterThanOrEqualTo(44));
      });

      testWidgets('Cancel of the item in course works once armed and names '
          'that item', (tester) async {
        final controller = await _pump(
          tester,
          code,
          _state(_running, outgoing: _uploading),
        );

        final cancel = buttonIn(_card, strings.cancelButton);
        expect(isEnabled(tester, cancel), isFalse);
        await arm(tester);
        expect(isEnabled(tester, cancel), isTrue);
        await tester.tap(cancel);
        await tester.pump();

        expect(controller.calls, ['cancelQueueItem l2']);
      });

      testWidgets('Cancel all calls the controller', (tester) async {
        final controller = await _pump(
          tester,
          code,
          _state(_running, outgoing: _uploading),
        );

        await tester.tap(buttonIn(_card, strings.queueCancelAll));
        await tester.pump();

        expect(controller.calls, ['cancelAllQueued']);
      });

      testWidgets('while an item is being cancelled it shows '
          'cancellingTransfer and no Cancel', (tester) async {
        await _pump(
          tester,
          code,
          _state(
            _running,
            outgoing: outgoingView(
              fileName: 'informe.xlsx',
              size: 2048,
              sent: 512,
              cancelling: true,
            ),
          ),
        );

        expect(_text(strings.cancellingTransfer), findsOneWidget);
        expect(buttonIn(_card, strings.cancelButton), findsNothing);
      });

      testWidgets('the last item says so instead of counting', (tester) async {
        await _pump(
          tester,
          code,
          _state(
            _queues(
              loose: [
                _delivered('l1', 'acta.pdf'),
                _item('l2', 'informe.xlsx', state: QueueItemState.inProgress),
              ],
            ),
            outgoing: _uploading,
          ),
        );

        expect(_text(strings.queueLastItem), findsOneWidget);
      });

      testWidgets('a section whose items are all delivered folds while the '
          'other one runs, and its header opens it again', (tester) async {
        await _pump(
          tester,
          code,
          _state(
            _queues(
              loose: [_delivered('l1', 'acta.pdf')],
              bundles: [
                _item(
                  'b1',
                  'proyecto',
                  folder: true,
                  state: QueueItemState.inProgress,
                ),
              ],
            ),
            outgoing: outgoingView(fileName: 'proyecto', size: 2048),
          ),
        );

        expect(_text('acta.pdf'), findsNothing);
        expect(_text('proyecto'), findsOneWidget);

        await tester.tap(_text(strings.looseQueue));
        await tester.pumpAndSettle();
        expect(_text('acta.pdf'), findsOneWidget);

        await tester.tap(_text(strings.looseQueue));
        await tester.pumpAndSettle();
        expect(_text('acta.pdf'), findsNothing);
      });

      testWidgets('with reduced motion a section opens and folds at once', (
        tester,
      ) async {
        setWindow(tester, const Size(800, 1800));
        final controller = FakeAppController(
          state: _state(_running, outgoing: _uploading),
        );
        await tester.pumpWidget(
          MediaQuery(
            data: const MediaQueryData(disableAnimations: true),
            child: columnApp(
              controller,
              code,
              (current) =>
                  ActivityPanel(controller: controller, state: current),
            ),
          ),
        );
        await tester.pump();

        await tester.tap(_text(strings.looseQueue));
        await tester.pump();
        expect(_text('zeta.txt'), findsNothing);
      });
    });

    group('[$code] E545 adding to a running queue (point 24, RF-290)', () {
      testWidgets('a new selection to the same device goes to the end of each '
          'queue without restarting the card', (tester) async {
        final controller = await _pump(
          tester,
          code,
          _state(_running, outgoing: _uploading),
        );
        final before = tester.state(_card);
        await tester.tap(_text(strings.bundleQueue));
        await tester.pumpAndSettle();
        expect(_text('proyecto'), findsNothing);

        controller.emit(
          _state(
            _queues(
              loose: [..._running.loose, _item('l4', 'alfa.txt')],
              bundles: [..._running.bundles, _item('b2', 'datos.zip')],
            ),
            outgoing: _uploading,
          ),
        );
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 600));

        expect(tester.state(_card), same(before));
        expect(_text('alfa.txt'), findsOneWidget);
        expect(
          tester.getTopLeft(_text('alfa.txt')).dy,
          greaterThan(tester.getTopLeft(_text('zeta.txt')).dy),
        );
        expect(_text('datos.zip'), findsNothing);
        expect(_text(strings.queueRemaining(4)), findsOneWidget);
        expect(_text('informe.xlsx'), findsOneWidget);
        expect(
          _text(
            strings.progressLine(
              25,
              formatSize(512, code),
              formatSize(2048, code),
            ),
          ),
          findsOneWidget,
        );

        await tester.tap(_text(strings.bundleQueue));
        await tester.pumpAndSettle();
        expect(_text('proyecto'), findsOneWidget);
        expect(_text('datos.zip'), findsOneWidget);
        expect(
          tester.getTopLeft(_text('datos.zip')).dy,
          greaterThan(tester.getTopLeft(_text('proyecto')).dy),
        );
      });

      testWidgets('a different selection id starts the card from scratch', (
        tester,
      ) async {
        final controller = await _pump(
          tester,
          code,
          _state(_running, outgoing: _uploading),
        );
        await tester.tap(_text(strings.bundleQueue));
        await tester.pumpAndSettle();
        expect(_text('proyecto'), findsNothing);

        controller.emit(
          _state(
            _queues(
              selectionId: 2,
              bundles: [_item('b9', 'otra', folder: true)],
            ),
          ),
        );
        await tester.pump();
        await tester.pumpAndSettle();

        expect(_text('otra'), findsOneWidget);
        expect(_text(strings.looseQueue), findsNothing);
      });
    });

    group('[$code] E544 and E559 queue results (RF-285, RF-295, RF-307)', () {
      testWidgets('finished: "Last sent" with every item and its reason, '
          'and "n of m delivered"', (tester) async {
        final finished = _queues(
          finished: true,
          loose: [
            _delivered('l1', 'acta.pdf'),
            _item(
              'l2',
              'enlace.lnk',
              state: QueueItemState.done,
              outcome: TransferOutcome.shortcut,
            ),
            _item(
              'l3',
              'zeta.txt',
              state: QueueItemState.notSent,
              outcome: TransferOutcome.declined,
            ),
          ],
          bundles: [
            _item(
              'b1',
              'proyecto',
              folder: true,
              state: QueueItemState.done,
              outcome: TransferOutcome.unreadable,
              problemPath: r'src\a.txt',
            ),
          ],
        );
        await _pump(
          tester,
          code,
          _state(
            finished,
            lastSent: resultView(direction: TransferDirection.outgoing),
          ),
        );

        expect(_text(strings.lastSentTitle), findsOneWidget);
        expect(find.byKey(const ValueKey('activity-last-sent')), findsNothing);
        expect(_text(strings.toPeer(senderName)), findsOneWidget);
        expect(chipIn(tester, _card).label, strings.chipFailed);
        expect(
          _text(strings.sentOutcome(TransferOutcome.shortcut)),
          findsOneWidget,
        );
        expect(
          _text(
            strings.queueNotSent(strings.sentOutcome(TransferOutcome.declined)),
          ),
          findsOneWidget,
        );
        expect(
          _text(strings.outcomeUnreadableEntry(r'src\a.txt')),
          findsOneWidget,
        );
        expect(_text(strings.deliveredSummary(1, 4)), findsNWidgets(1));
        expect(buttonIn(_card, strings.queueCancelAll), findsNothing);
        expect(_tooltip(strings.queueRemove), findsNothing);
      });

      testWidgets('finished and all delivered: Delivered chip and the '
          'summary', (tester) async {
        await _pump(
          tester,
          code,
          _state(
            _queues(
              finished: true,
              loose: [_delivered('l1', 'a.pdf'), _delivered('l2', 'b.pdf')],
            ),
          ),
        );

        expect(chipIn(tester, _card).label, strings.chipDelivered);
        expect(chipIn(tester, _card).tone, ChipTone.ok);
        expect(_text(strings.deliveredSummary(2, 2)), findsNWidgets(2));
      });

      testWidgets('finished with only cancelled items: Cancelled chip', (
        tester,
      ) async {
        await _pump(
          tester,
          code,
          _state(
            _queues(
              finished: true,
              loose: [
                _item(
                  'l1',
                  'a.pdf',
                  state: QueueItemState.done,
                  outcome: TransferOutcome.cancelledHere,
                ),
                _item(
                  'l2',
                  'b.pdf',
                  state: QueueItemState.notSent,
                  outcome: TransferOutcome.cancelledHere,
                ),
              ],
            ),
          ),
        );

        expect(chipIn(tester, _card).label, strings.chipCancelled);
      });

      testWidgets('a folder the other device cannot receive explains it', (
        tester,
      ) async {
        await _pump(
          tester,
          code,
          _state(
            _queues(
              finished: true,
              bundles: [
                _item(
                  'b1',
                  'proyecto',
                  folder: true,
                  state: QueueItemState.done,
                  outcome: TransferOutcome.incompatible,
                ),
              ],
            ),
          ),
        );

        expect(_text(strings.outcomeFolderIncompatible), findsOneWidget);
      });
    });

    group(
      '[$code] E542 folder in course inside the queue (RF-258, RF-259)',
      () {
        testWidgets('preparing: the count so far; uploading: summary, '
            'n of m files and the bar', (tester) async {
          final queues = _queues(
            bundles: [
              _item(
                'b1',
                'proyecto',
                folder: true,
                state: QueueItemState.inProgress,
              ),
            ],
          );
          final controller = await _pump(
            tester,
            code,
            _state(
              queues,
              outgoing: const OutgoingTransferView(
                peerFingerprint: '',
                peerName: null,
                fileName: 'proyecto',
                size: 0,
                isProgram: false,
                phase: OutgoingPhase.preparing,
                sentBytes: 0,
                cancelling: false,
                isFolder: true,
                preparedEntries: 1234,
              ),
            ),
          );
          expect(_text(strings.preparingItems(1234)), findsNothing);

          controller.emit(
            _state(
              queues,
              outgoing: OutgoingTransferView(
                peerFingerprint: senderFingerprint,
                peerName: senderName,
                fileName: 'proyecto',
                size: 0,
                isProgram: false,
                phase: OutgoingPhase.preparing,
                sentBytes: 0,
                cancelling: false,
                isFolder: true,
                preparedEntries: 1234,
              ),
            ),
          );
          await tester.pump();
          expect(_text(strings.preparingItems(1234)), findsOneWidget);

          const summary = FolderSummaryView(
            files: 14,
            folders: 2,
            totalBytes: 4096,
            excludedFolders: 2,
            excludedBytes: 2048,
            linksOmitted: 1,
            protectedOmitted: 0,
            blockedOmitted: 3,
            containsPrograms: true,
          );
          OutgoingTransferView folderIn(OutgoingPhase phase) {
            return OutgoingTransferView(
              peerFingerprint: senderFingerprint,
              peerName: senderName,
              fileName: 'proyecto',
              size: 4096,
              isProgram: true,
              phase: phase,
              sentBytes: 1024,
              cancelling: false,
              isFolder: true,
              fileCount: 14,
              sentFiles: 3,
              summary: summary,
            );
          }

          controller.emit(
            _state(queues, outgoing: folderIn(OutgoingPhase.waiting)),
          );
          await tester.pump();
          expect(
            _text(strings.folderSummary(14, formatSize(4096, code))),
            findsOneWidget,
          );

          controller.emit(
            _state(queues, outgoing: folderIn(OutgoingPhase.uploading)),
          );
          await tester.pump();

          expect(_text(strings.filesProgress(3, 14)), findsOneWidget);
          expect(
            _text(strings.folderSummary(14, formatSize(4096, code))),
            findsNothing,
          );
          expect(
            _text(strings.foldersLeftOut(2, formatSize(2048, code))),
            findsOneWidget,
          );
          expect(_text(strings.linksNotFollowed(1)), findsOneWidget);
          expect(_text(strings.blockedLeftOut(3)), findsOneWidget);
          expect(_text(strings.containsPrograms), findsOneWidget);
          expect(_text(strings.appDataLeftOut), findsNothing);
        });
      },
    );

    group('[$code] the activity panel with queues (RF-285)', () {
      testWidgets('shows the queue card instead of the single card and of '
          'Last sent', (tester) async {
        await _pump(
          tester,
          code,
          _state(
            _running,
            outgoing: _uploading,
            lastSent: resultView(direction: TransferDirection.outgoing),
          ),
        );

        expect(find.byKey(const ValueKey('activity-queues')), findsOneWidget);
        expect(find.byKey(const ValueKey('activity-outgoing')), findsNothing);
        expect(find.byKey(const ValueKey('activity-last-sent')), findsNothing);
      });

      testWidgets('the total bar follows the bytes of the whole selection', (
        tester,
      ) async {
        await _pump(
          tester,
          code,
          _state(
            _running,
            outgoing: _uploading,
            progress: const SelectionProgress(
              selectionId: 1,
              doneBytes: 500,
              totalBytes: 1000,
              currentName: 'informe.xlsx',
              currentIsFolder: false,
              finished: false,
            ),
          ),
        );

        expect(_text(formatPercent(50, code)), findsOneWidget);
      });

      testWidgets('a selection progress of another selection counts as zero', (
        tester,
      ) async {
        await _pump(
          tester,
          code,
          _state(
            _running,
            outgoing: _uploading,
            progress: const SelectionProgress(
              selectionId: 7,
              doneBytes: 500,
              totalBytes: 1000,
              currentName: null,
              currentIsFolder: false,
              finished: false,
            ),
          ),
        );

        expect(_text(formatPercent(0, code)), findsOneWidget);
      });
    });
  }
}
