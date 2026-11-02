import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nexus_bridges/src/l10n/app_strings.dart';
import 'package:nexus_bridges/src/ui/activity_cards.dart';
import 'package:nexus_bridges/src/ui/format.dart';
import 'package:nexus_bridges/src/ui/icons/folder_icon.dart';
import 'package:nexus_bridges/src/ui/incoming_cards.dart';
import 'package:nexus_bridges/src/ui/theme/components.dart';
import 'package:nexus_bridges_core/nexus_bridges_core.dart';

import 'fake_app_controller.dart';
import 'transfer_fixtures.dart';

const FolderSummaryView _summary = FolderSummaryView(
  files: 1380,
  folders: 40,
  totalBytes: 4096,
  excludedFolders: 3,
  excludedBytes: 2048,
  linksOmitted: 2,
  protectedOmitted: 1,
  blockedOmitted: 5,
  containsPrograms: true,
);

OutgoingTransferView _folderOut({
  OutgoingPhase phase = OutgoingPhase.uploading,
  int size = 4096,
  int sent = 1024,
  int fileCount = 14,
  int sentFiles = 3,
  int preparedEntries = 0,
  bool cancelling = false,
  FolderSummaryView? summary,
  bool isProgram = false,
}) {
  return OutgoingTransferView(
    peerFingerprint: senderFingerprint,
    peerName: senderName,
    fileName: 'proyecto',
    size: size,
    isProgram: isProgram,
    phase: phase,
    sentBytes: sent,
    cancelling: cancelling,
    isFolder: true,
    fileCount: fileCount,
    sentFiles: sentFiles,
    preparedEntries: preparedEntries,
    summary: summary,
  );
}

IncomingTransferView _folderIn({
  IncomingStage stage = IncomingStage.warning,
  int size = 1536,
  int received = 0,
  int fileCount = 214,
  int receivedFiles = 0,
  List<FirstLevelItem> firstLevel = const [],
  int more = 0,
  bool isProgram = false,
  bool git = false,
  bool canCancel = true,
}) {
  return IncomingTransferView(
    sessionId: 's1',
    peerFingerprint: senderFingerprint,
    peerName: senderName,
    fileName: 'proyecto',
    size: size,
    isProgram: isProgram,
    stage: stage,
    receivedBytes: received,
    isFolder: true,
    fileCount: fileCount,
    receivedFiles: receivedFiles,
    firstLevel: firstLevel,
    moreFirstLevel: more,
    containsGitRepository: git,
    canCancel: canCancel,
  );
}

TransferResultView _folderResult({
  TransferDirection direction = TransferDirection.outgoing,
  TransferOutcome outcome = TransferOutcome.saved,
  String? problemPath,
  bool canReveal = false,
  bool isProgram = false,
  bool git = false,
  String fileName = 'proyecto',
  bool isFolder = true,
}) {
  return TransferResultView(
    direction: direction,
    peerFingerprint: senderFingerprint,
    peerName: senderName,
    fileName: fileName,
    isProgram: isProgram,
    outcome: outcome,
    canReveal: canReveal,
    isFolder: isFolder,
    fileCount: 214,
    problemPath: problemPath,
    size: 2048,
    containsGitRepository: git,
  );
}

Future<FakeAppController> _panel(
  WidgetTester tester,
  String code,
  NodeState state,
) {
  return pumpColumn(
    tester,
    code,
    state,
    (controller, current) =>
        ActivityPanel(controller: controller, state: current),
  );
}

final Finder _outgoing = find.byKey(const ValueKey('activity-outgoing'));
final Finder _incoming = find.byKey(const ValueKey('activity-incoming'));
final Finder _lastSent = find.byKey(const ValueKey('activity-last-sent'));
final Finder _lastReceived = find.byKey(
  const ValueKey('activity-last-received'),
);

void main() {
  for (final code in languageCodes) {
    final strings = stringsFor(code);

    group('[$code] E542 outgoing folder card (RF-258, RF-259)', () {
      testWidgets('preparing: the folder icon, the count so far and Cancel', (
        tester,
      ) async {
        final controller = await _panel(
          tester,
          code,
          NodeState(
            outgoing: _folderOut(
              phase: OutgoingPhase.preparing,
              preparedEntries: 1234,
              size: 0,
              sent: 0,
              fileCount: 0,
            ),
          ),
        );

        expect(inside(_outgoing, find.byType(FolderIcon)), findsOneWidget);
        expect(textIn(_outgoing, strings.preparingItems(1234)), findsOneWidget);
        expect(chipIn(tester, _outgoing).label, strings.chipPreparing);
        await arm(tester);
        await tester.tap(buttonIn(_outgoing, strings.cancelButton));
        await tester.pump();
        expect(controller.calls, ['cancelSending']);
      });

      testWidgets('the summary once the manifest is built: totals and what '
          'was left out', (tester) async {
        await _panel(
          tester,
          code,
          NodeState(
            outgoing: _folderOut(
              phase: OutgoingPhase.waiting,
              summary: _summary,
              isProgram: true,
              size: 4096,
              sent: 0,
              fileCount: 1380,
            ),
          ),
        );

        expect(
          textIn(
            _outgoing,
            strings.folderSummary(1380, formatSize(4096, code)),
          ),
          findsOneWidget,
        );
        expect(
          textIn(_outgoing, strings.foldersLeftOut(3, formatSize(2048, code))),
          findsOneWidget,
        );
        expect(textIn(_outgoing, strings.linksNotFollowed(2)), findsOneWidget);
        expect(textIn(_outgoing, strings.appDataLeftOut), findsOneWidget);
        expect(textIn(_outgoing, strings.blockedLeftOut(5)), findsOneWidget);
        expect(textIn(_outgoing, strings.containsPrograms), findsOneWidget);
        expect(textIn(_outgoing, strings.programLabel), findsNothing);
      });

      testWidgets('the size of the folders left out waits while it is still '
          'being worked out', (tester) async {
        await _panel(
          tester,
          code,
          NodeState(
            outgoing: _folderOut(
              phase: OutgoingPhase.waiting,
              summary: const FolderSummaryView(
                files: 10,
                folders: 1,
                totalBytes: 100,
                excludedFolders: 3,
                excludedBytes: 0,
                linksOmitted: 0,
                protectedOmitted: 0,
                blockedOmitted: 0,
                containsPrograms: false,
                excludedBytesPartial: true,
              ),
            ),
          ),
        );

        expect(
          textIn(_outgoing, strings.foldersLeftOut(3, null)),
          findsOneWidget,
        );
        expect(
          textIn(_outgoing, strings.foldersLeftOut(3, formatSize(0, code))),
          findsNothing,
        );
        expect(textIn(_outgoing, strings.linksNotFollowed(0)), findsNothing);
        expect(textIn(_outgoing, strings.containsPrograms), findsNothing);
      });

      testWidgets(
        'uploading: progress of the whole folder and "n of m files"',
        (tester) async {
          await _panel(
            tester,
            code,
            NodeState(outgoing: _folderOut(summary: _summary)),
          );

          expect(
            textIn(
              _outgoing,
              strings.progressLine(
                25,
                formatSize(1024, code),
                formatSize(4096, code),
              ),
            ),
            findsOneWidget,
          );
          expect(
            textIn(_outgoing, strings.filesProgress(3, 14)),
            findsOneWidget,
          );
          expect(chipIn(tester, _outgoing).label, strings.chipInProgress);
        },
      );

      testWidgets('a plain file keeps the file icon and has no "n of m"', (
        tester,
      ) async {
        await _panel(tester, code, NodeState(outgoing: outgoingView()));

        expect(inside(_outgoing, find.byType(FolderIcon)), findsNothing);
        expect(textIn(_outgoing, strings.filesProgress(0, 0)), findsNothing);
        expect(textIn(_outgoing, strings.containsPrograms), findsNothing);
      });
    });

    group('[$code] E543 warning of a foreign folder (RF-271, RF-305)', () {
      final names = [
        const FirstLevelItem(name: 'src', isFolder: true),
        const FirstLevelItem(name: 'docs', isFolder: true),
        const FirstLevelItem(name: 'README.md', isFolder: false),
        const FirstLevelItem(name: '.env', isFolder: false),
        const FirstLevelItem(name: 'pubspec.yaml', isFolder: false),
      ];

      testWidgets('count, size, five names with their type, "and n more", '
          'programs and Git', (tester) async {
        final controller = await pumpColumn(
          tester,
          code,
          NodeState(
            incoming: _folderIn(
              firstLevel: names,
              more: 2,
              isProgram: true,
              git: true,
            ),
          ),
          (controller, state) =>
              IncomingCards(controller: controller, state: state),
        );
        final card = find.byType(IncomingCards);

        expect(inside(card, find.byType(FolderIcon)), findsOneWidget);
        expect(
          textIn(card, strings.folderSummary(214, formatSize(1536, code))),
          findsOneWidget,
        );
        for (final item in names) {
          expect(textIn(card, item.name), findsOneWidget);
        }
        final list = find.byKey(const ValueKey('first-level-list'));
        expect(textIn(list, strings.firstLevelMore(2)), findsOneWidget);
        expect(textIn(card, strings.containsPrograms), findsOneWidget);
        expect(textIn(card, strings.containsGitRepository), findsOneWidget);
        expect(textIn(card, strings.programLabel), findsNothing);

        await arm(tester);
        await tester.ensureVisible(buttonIn(card, strings.acceptButton));
        await tester.pump();
        await tester.tap(buttonIn(card, strings.acceptButton));
        await tester.pump();
        expect(controller.calls, ['answerIncoming s1 true']);
      });

      testWidgets('the title says folder for a folder and file for a file', (
        tester,
      ) async {
        await pumpColumn(
          tester,
          code,
          NodeState(incoming: _folderIn()),
          (controller, state) =>
              IncomingCards(controller: controller, state: state),
        );
        final card = find.byType(IncomingCards);

        expect(
          textIn(card, strings.incomingFolderRequestTitle(senderName)),
          findsOneWidget,
        );
        expect(
          textIn(card, strings.incomingRequestTitle(senderName)),
          findsNothing,
        );
        expect(
          strings.incomingFolderRequestTitle(senderName),
          isNot(strings.incomingRequestTitle(senderName)),
        );
      });

      testWidgets('with no more names there is no "and n more"', (
        tester,
      ) async {
        await pumpColumn(
          tester,
          code,
          NodeState(incoming: _folderIn(firstLevel: names.take(2).toList())),
          (controller, state) =>
              IncomingCards(controller: controller, state: state),
        );
        final card = find.byType(IncomingCards);

        expect(textIn(card, strings.firstLevelMore(0)), findsNothing);
        expect(textIn(card, strings.containsPrograms), findsNothing);
        expect(textIn(card, strings.containsGitRepository), findsNothing);
      });

      testWidgets('a file shows no list of names', (tester) async {
        await pumpColumn(
          tester,
          code,
          NodeState(incoming: incomingView()),
          (controller, state) =>
              IncomingCards(controller: controller, state: state),
        );

        expect(find.byKey(const ValueKey('first-level-list')), findsNothing);
        expect(find.byType(FolderIcon), findsNothing);
      });
    });

    group('[$code] E546 receiving a folder (RF-284)', () {
      testWidgets('shows "n of m files" with the progress of the whole', (
        tester,
      ) async {
        await _panel(
          tester,
          code,
          NodeState(
            incoming: _folderIn(
              stage: IncomingStage.receiving,
              size: 2048,
              received: 1024,
              fileCount: 9,
              receivedFiles: 2,
            ),
          ),
        );

        expect(inside(_incoming, find.byType(FolderIcon)), findsOneWidget);
        expect(
          textIn(
            _incoming,
            strings.progressLine(
              50,
              formatSize(1024, code),
              formatSize(2048, code),
            ),
          ),
          findsOneWidget,
        );
        expect(textIn(_incoming, strings.filesProgress(2, 9)), findsOneWidget);
      });

      testWidgets('Cancel follows canCancel: shown while the folder is '
          'checked and gone once it moves', (tester) async {
        final controller = await _panel(
          tester,
          code,
          NodeState(
            incoming: _folderIn(
              stage: IncomingStage.verifying,
              size: 2048,
              received: 2048,
              receivedFiles: 9,
              fileCount: 9,
            ),
          ),
        );
        await arm(tester);
        expect(buttonIn(_incoming, strings.cancelButton), findsOneWidget);
        await tester.tap(buttonIn(_incoming, strings.cancelButton));
        await tester.pump();
        expect(controller.calls, ['cancelReceiving s1']);

        controller.emit(
          NodeState(
            incoming: _folderIn(
              stage: IncomingStage.verifying,
              size: 2048,
              received: 2048,
              receivedFiles: 9,
              fileCount: 9,
              canCancel: false,
            ),
          ),
        );
        await tester.pump();
        expect(buttonIn(_incoming, strings.cancelButton), findsNothing);
      });
    });

    group('[$code] E544 and E547 results of a folder (RF-283, RF-285)', () {
      testWidgets('sent: final name, count, size and the result', (
        tester,
      ) async {
        await _panel(
          tester,
          code,
          NodeState(lastSent: _folderResult(isProgram: true)),
        );

        expect(inside(_lastSent, find.byType(FolderIcon)), findsOneWidget);
        expect(textIn(_lastSent, 'proyecto'), findsOneWidget);
        expect(textIn(_lastSent, strings.toPeer(senderName)), findsOneWidget);
        expect(
          textIn(_lastSent, strings.folderSummary(214, formatSize(2048, code))),
          findsOneWidget,
        );
        expect(
          textIn(_lastSent, strings.sentOutcome(TransferOutcome.saved)),
          findsOneWidget,
        );
        expect(textIn(_lastSent, strings.containsPrograms), findsOneWidget);
        expect(chipIn(tester, _lastSent).label, strings.chipDelivered);
      });

      testWidgets('sent with the path that stopped it', (tester) async {
        for (final (outcome, line) in [
          (TransferOutcome.unreadable, strings.outcomeUnreadableEntry),
          (TransferOutcome.invalidName, strings.outcomeInvalidNameEntry),
        ]) {
          await _panel(
            tester,
            code,
            NodeState(
              lastSent: _folderResult(
                outcome: outcome,
                problemPath: r'src\a.txt',
              ),
            ),
          );
          expect(textIn(_lastSent, line(r'src\a.txt')), findsOneWidget);
          expect(chipIn(tester, _lastSent).tone, ChipTone.fail);
        }
      });

      testWidgets('a folder the other device cannot receive explains it, a '
          'file keeps the usual text', (tester) async {
        await _panel(
          tester,
          code,
          NodeState(
            lastSent: _folderResult(outcome: TransferOutcome.incompatible),
          ),
        );
        expect(
          textIn(_lastSent, strings.outcomeFolderIncompatible),
          findsOneWidget,
        );

        await _panel(
          tester,
          code,
          NodeState(
            lastSent: _folderResult(
              outcome: TransferOutcome.incompatible,
              isFolder: false,
              fileName: 'a.txt',
            ),
          ),
        );
        expect(
          textIn(_lastSent, strings.sentOutcome(TransferOutcome.incompatible)),
          findsOneWidget,
        );
      });

      testWidgets('received: the name, the peer, Git, programs and Show in '
          'folder', (tester) async {
        final controller = await _panel(
          tester,
          code,
          NodeState(
            lastReceived: _folderResult(
              direction: TransferDirection.incoming,
              canReveal: true,
              isProgram: true,
              git: true,
              fileName: 'proyecto (1)',
            ),
          ),
        );

        expect(textIn(_lastReceived, 'proyecto (1)'), findsOneWidget);
        expect(
          textIn(_lastReceived, strings.fromPeer(senderName)),
          findsOneWidget,
        );
        expect(
          textIn(_lastReceived, strings.containsGitRepository),
          findsOneWidget,
        );
        expect(textIn(_lastReceived, strings.containsPrograms), findsOneWidget);
        expect(chipIn(tester, _lastReceived).label, strings.chipSaved);

        await tester.tap(buttonIn(_lastReceived, strings.showInFolderButton));
        await tester.pump();
        expect(controller.calls, ['revealLastReceived']);
      });

      testWidgets('received without a place to reveal has no button', (
        tester,
      ) async {
        await _panel(
          tester,
          code,
          NodeState(
            lastReceived: _folderResult(
              direction: TransferDirection.incoming,
              outcome: TransferOutcome.damaged,
            ),
          ),
        );

        expect(
          buttonIn(_lastReceived, strings.showInFolderButton),
          findsNothing,
        );
        expect(
          textIn(
            _lastReceived,
            strings.receivedOutcome(TransferOutcome.damaged),
          ),
          findsOneWidget,
        );
      });
    });
  }
}
