import 'package:flutter_test/flutter_test.dart';
import 'package:nexus_bridges/src/ui/attention.dart';
import 'package:nexus_bridges_core/nexus_bridges_core.dart';

import 'fake_app_controller.dart';
import 'pairing_fixtures.dart';
import 'transfer_fixtures.dart';

const FolderQuestionView _firstTime = FolderQuestionView(
  kind: FolderQuestionKind.firstTime,
  proposedPath: r'C:\Users\David\Downloads',
);

const FolderQuestionView _thisTime = FolderQuestionView(
  kind: FolderQuestionKind.thisTime,
  proposedPath: r'C:\Users\David\Downloads',
);

NodeState _with({IncomingTransferView? incoming, PairingView? pairing}) =>
    NodeState(incoming: incoming, pairing: pairing);

void main() {
  group('E853 attentionItemsOf: what needs an answer (RF-505, RF-529)', () {
    test('nothing without a state or with an empty one', () {
      expect(attentionItemsOf(null), isEmpty);
      expect(attentionItemsOf(const NodeState()), isEmpty);
    });

    test('the stranger warning, the folder question of both kinds and the '
        'pairing request as receiver', () {
      expect(attentionItemsOf(_with(incoming: incomingView(id: 's1'))), {
        'warning:s1',
      });
      expect(
        attentionItemsOf(
          _with(
            incoming: incomingView(
              id: 's2',
              stage: IncomingStage.folderQuestion,
              folder: _firstTime,
            ),
          ),
        ),
        {'folder:s2:firstTime'},
      );
      expect(
        attentionItemsOf(
          _with(
            incoming: incomingView(
              id: 's3',
              stage: IncomingStage.folderQuestion,
              folder: _thisTime,
            ),
          ),
        ),
        {'folder:s3:thisTime'},
      );
      expect(
        attentionItemsOf(
          _with(
            pairing: view(
              role: PairingRole.receiver,
              phase: PairingPhase.comparing,
            ),
          ),
        ),
        {'pairing:$peerFingerprint'},
      );
    });

    test('a warning and a pairing request at once give both', () {
      expect(
        attentionItemsOf(
          _with(
            incoming: incomingView(id: 's1'),
            pairing: view(
              role: PairingRole.receiver,
              phase: PairingPhase.comparing,
            ),
          ),
        ),
        {'warning:s1', 'pairing:$peerFingerprint'},
      );
    });

    test('not what arrives from a "mine" without asking, results, notices, '
        'the network question, pairing as initiator, "is it yours?" nor the '
        'panel after the end', () {
      for (final stage in [
        IncomingStage.waitingData,
        IncomingStage.receiving,
        IncomingStage.verifying,
        IncomingStage.ended,
      ]) {
        expect(
          attentionItemsOf(_with(incoming: incomingView(stage: stage))),
          isEmpty,
          reason: stage.name,
        );
      }
      expect(
        attentionItemsOf(
          _with(incoming: incomingView(stage: IncomingStage.folderQuestion)),
        ),
        isEmpty,
      );
      expect(
        attentionItemsOf(
          _with(
            incoming: incomingView(
              stage: IncomingStage.ended,
              folder: const FolderQuestionView(
                kind: FolderQuestionKind.firstTime,
                proposedPath: r'C:\x',
                afterEnd: AfterEndResult.remembered,
              ),
            ),
          ),
        ),
        isEmpty,
      );
      expect(
        attentionItemsOf(
          NodeState(
            lastReceived: resultView(),
            lastSent: resultView(direction: TransferDirection.outgoing),
            notices: const [Notice(id: 1, kind: NoticeKind.settingNotSaved)],
            prompts: const [NetworkPrompt('{N}', 'Casa')],
            questions: const [
              MineQuestion(fingerprint: 'F', deviceName: 'X'),
              ReplaceQuestion(
                fingerprint: 'F',
                deviceName: 'X',
                oldFingerprint: 'G',
                oldName: 'Y',
              ),
            ],
          ),
        ),
        isEmpty,
      );
      for (final phase in PairingPhase.values) {
        expect(
          attentionItemsOf(
            _with(
              pairing: view(role: PairingRole.initiator, phase: phase),
            ),
          ),
          isEmpty,
          reason: 'initiator ${phase.name}',
        );
      }
      for (final phase in PairingPhase.values) {
        if (phase == PairingPhase.comparing) continue;
        expect(
          attentionItemsOf(
            _with(
              pairing: view(role: PairingRole.receiver, phase: phase),
            ),
          ),
          isEmpty,
          reason: 'receiver ${phase.name}',
        );
      }
      expect(
        attentionItemsOf(
          _with(
            pairing: view(
              role: PairingRole.receiver,
              phase: PairingPhase.comparing,
              outcome: PairingOutcome.rejected,
            ),
          ),
        ),
        isEmpty,
      );
    });
  });

  group('E853 AttentionWatcher: tick only for something new', () {
    test('what is already there at the start does not raise tick', () {
      final controller = FakeAppController(
        state: _with(incoming: incomingView()),
      );
      final watcher = AttentionWatcher(controller);
      addTearDown(watcher.dispose);
      expect(watcher.tick, 0);
      controller.emit(_with(incoming: incomingView()));
      expect(watcher.tick, 0);
    });

    test('a warning raises tick once and notifies; the same warning again '
        'does not', () {
      final controller = FakeAppController(state: const NodeState());
      final watcher = AttentionWatcher(controller);
      addTearDown(watcher.dispose);
      var notified = 0;
      watcher.addListener(() => notified++);

      controller.emit(_with(incoming: incomingView(id: 's1')));
      expect(watcher.tick, 1);
      expect(notified, 1);
      controller.emit(_with(incoming: incomingView(id: 's1', size: 99)));
      expect(watcher.tick, 1);
      expect(notified, 1);
    });

    test('accepting the warning and then the folder question raises tick '
        'again, and its other kind too', () {
      final controller = FakeAppController(state: const NodeState());
      final watcher = AttentionWatcher(controller);
      addTearDown(watcher.dispose);

      controller.emit(_with(incoming: incomingView(id: 's1')));
      controller.emit(
        _with(
          incoming: incomingView(
            id: 's1',
            stage: IncomingStage.folderQuestion,
            folder: _firstTime,
          ),
        ),
      );
      expect(watcher.tick, 2);
      controller.emit(
        _with(
          incoming: incomingView(
            id: 's1',
            stage: IncomingStage.folderQuestion,
            folder: _thisTime,
          ),
        ),
      );
      expect(watcher.tick, 3);
    });

    test('a warning that goes away and comes back raises tick again', () {
      final controller = FakeAppController(state: const NodeState());
      final watcher = AttentionWatcher(controller);
      addTearDown(watcher.dispose);

      controller.emit(_with(incoming: incomingView(id: 's1')));
      controller.emit(const NodeState());
      controller.emit(_with(incoming: incomingView(id: 's1')));
      expect(watcher.tick, 2);
    });

    test('a pairing request as receiver raises tick; one that ends does not; '
        'what does not need an answer never does', () {
      final controller = FakeAppController(state: const NodeState());
      final watcher = AttentionWatcher(controller);
      addTearDown(watcher.dispose);

      controller.emit(
        _with(
          pairing: view(
            role: PairingRole.receiver,
            phase: PairingPhase.comparing,
          ),
        ),
      );
      expect(watcher.tick, 1);
      controller.emit(
        _with(
          pairing: view(
            role: PairingRole.receiver,
            phase: PairingPhase.finished,
            outcome: PairingOutcome.paired,
          ),
        ),
      );
      controller.emit(
        NodeState(
          lastReceived: resultView(),
          incoming: incomingView(stage: IncomingStage.receiving),
          notices: const [Notice(id: 2, kind: NoticeKind.unpairNotSaved)],
        ),
      );
      expect(watcher.tick, 1);
    });

    test('two new items at once raise tick once', () {
      final controller = FakeAppController(state: const NodeState());
      final watcher = AttentionWatcher(controller);
      addTearDown(watcher.dispose);

      controller.emit(
        _with(
          incoming: incomingView(id: 's1'),
          pairing: view(
            role: PairingRole.receiver,
            phase: PairingPhase.comparing,
          ),
        ),
      );
      expect(watcher.tick, 1);
    });

    test('after dispose it stops listening', () {
      final controller = FakeAppController(state: const NodeState());
      final watcher = AttentionWatcher(controller)..dispose();
      controller.emit(_with(incoming: incomingView(id: 's9')));
      expect(watcher.tick, 0);
      watcher.dispose();
    });
  });
}
