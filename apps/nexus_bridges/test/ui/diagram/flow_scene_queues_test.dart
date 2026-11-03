import 'package:flutter_test/flutter_test.dart';
import 'package:nexus_bridges/src/ui/diagram/flow_scene.dart';
import 'package:nexus_bridges_core/nexus_bridges_core.dart';

const String _peer = 'B';

QueueItemView _item(
  String id,
  QueueItemState state, [
  TransferOutcome? outcome,
]) => QueueItemView(
  id: id,
  name: '$id.txt',
  isFolder: false,
  isArchive: false,
  state: state,
  outcome: outcome,
);

SendQueuesView _queues(
  List<QueueItemView> items, {
  int selectionId = 1,
  bool? finished,
}) {
  final delivered = items
      .where(
        (item) =>
            item.state == QueueItemState.done &&
            (item.outcome == TransferOutcome.saved ||
                item.outcome == TransferOutcome.savedWithoutMark),
      )
      .length;
  return SendQueuesView(
    selectionId: selectionId,
    peerFingerprint: _peer,
    peerName: 'Peer',
    loose: items,
    bundles: const [],
    finished:
        finished ??
        items.every(
          (item) =>
              item.state == QueueItemState.done ||
              item.state == QueueItemState.notSent,
        ),
    delivered: delivered,
    total: items.length,
    completedBytes: 0,
    pendingKnownBytes: 0,
    currentProbeSize: null,
  );
}

OutgoingTransferView _sending(String fileName) => OutgoingTransferView(
  peerFingerprint: _peer,
  peerName: 'Peer',
  fileName: fileName,
  size: 100,
  isProgram: false,
  phase: OutgoingPhase.verifying,
  sentBytes: 100,
  cancelling: false,
);

TransferResultView _sent(String fileName, TransferOutcome outcome) =>
    TransferResultView(
      direction: TransferDirection.outgoing,
      peerFingerprint: _peer,
      peerName: 'Peer',
      fileName: fileName,
      isProgram: false,
      outcome: outcome,
      canReveal: false,
    );

NodeState _state({
  SendQueuesView? queues,
  OutgoingTransferView? outgoing,
  TransferResultView? lastSent,
}) => NodeState(queues: queues, outgoing: outgoing, lastSent: lastSent);

void main() {
  group('Q-7, RF-285: the tick of the diagram with queues', () {
    final saved = TransferOutcome.saved;

    test('Q-7 queues that end with every item delivered give the tick', () {
      final running = _queues([
        _item('a', QueueItemState.done, saved),
        _item('b', QueueItemState.inProgress),
      ]);
      final done = _queues([
        _item('a', QueueItemState.done, saved),
        _item('b', QueueItemState.done, saved),
      ]);

      expect(
        newlyDone(
          _state(queues: running, outgoing: _sending('b.txt')),
          _state(queues: done, lastSent: _sent('b.txt', saved)),
        ),
        _peer,
      );
    });

    test('Q-7 queues that end failed give no tick even if the last item was '
        'saved', () {
      final running = _queues([
        _item('a', QueueItemState.done, TransferOutcome.unreadable),
        _item('b', QueueItemState.done, TransferOutcome.cancelledHere),
        _item('c', QueueItemState.inProgress),
      ]);
      final done = _queues([
        _item('a', QueueItemState.done, TransferOutcome.unreadable),
        _item('b', QueueItemState.done, TransferOutcome.cancelledHere),
        _item('c', QueueItemState.done, saved),
      ]);

      expect(done.delivered, lessThan(done.total));
      expect(
        newlyDone(
          _state(queues: running, outgoing: _sending('c.txt')),
          _state(queues: done, lastSent: _sent('c.txt', saved)),
        ),
        isNull,
      );
    });

    test('Q-7 queues cancelled with Cancel all give no tick', () {
      final running = _queues([
        _item('a', QueueItemState.done, saved),
        _item('b', QueueItemState.inProgress),
        _item('c', QueueItemState.pending),
      ]);
      final done = _queues([
        _item('a', QueueItemState.done, saved),
        _item('b', QueueItemState.done, TransferOutcome.cancelledHere),
        _item('c', QueueItemState.notSent, TransferOutcome.cancelledHere),
      ]);

      expect(
        newlyDone(
          _state(queues: running, outgoing: _sending('b.txt')),
          _state(
            queues: done,
            lastSent: _sent('b.txt', TransferOutcome.cancelledHere),
          ),
        ),
        isNull,
      );
    });

    test('Q-7 one item saved while the queues still run gives no tick', () {
      final before = _queues([
        _item('a', QueueItemState.inProgress),
        _item('b', QueueItemState.pending),
      ]);
      final after = _queues([
        _item('a', QueueItemState.done, saved),
        _item('b', QueueItemState.pending),
      ]);

      expect(after.finished, isFalse);
      expect(
        newlyDone(
          _state(queues: before, outgoing: _sending('a.txt')),
          _state(queues: after, lastSent: _sent('a.txt', saved)),
        ),
        isNull,
      );
    });

    test('Q-7 a finished view seen again for the same selection gives no new '
        'tick, and a new selection that ends all delivered gives one', () {
      final done = _queues([
        _item('a', QueueItemState.done, saved),
        _item('b', QueueItemState.done, saved),
      ]);
      final again = _queues([
        _item('a', QueueItemState.done, saved),
        _item('b', QueueItemState.done, saved),
      ]);
      final next = _queues([
        _item('c', QueueItemState.done, saved),
        _item('d', QueueItemState.done, saved),
      ], selectionId: 2);

      expect(newlyDone(_state(queues: done), _state(queues: again)), isNull);
      expect(newlyDone(_state(queues: done), _state(queues: next)), _peer);
    });

    test('Q-7 an empty finished view gives no tick', () {
      final empty = _queues(const [], finished: true);

      expect(
        newlyDone(
          _state(queues: _queues([_item('a', QueueItemState.inProgress)])),
          _state(queues: empty),
        ),
        isNull,
      );
    });
  });
}
