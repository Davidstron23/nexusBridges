import 'package:flutter_test/flutter_test.dart';
import 'package:nexus_bridges/src/ui/home_layout.dart';
import 'package:nexus_bridges_core/nexus_bridges_core.dart';

const String _peerA = 'AAAA';
const String _peerB = 'BBBB';

OutgoingTransferView _out({
  String peer = _peerA,
  String fileName = 'report.pdf',
  OutgoingPhase phase = OutgoingPhase.uploading,
  int sent = 0,
}) => OutgoingTransferView(
  peerFingerprint: peer,
  peerName: 'Peer',
  fileName: fileName,
  size: 1000,
  isProgram: false,
  phase: phase,
  sentBytes: sent,
  cancelling: false,
);

IncomingTransferView _in(
  IncomingStage stage, {
  int received = 0,
  String sessionId = 's1',
}) => IncomingTransferView(
  sessionId: sessionId,
  peerFingerprint: _peerB,
  peerName: 'Peer',
  fileName: 'photo.jpg',
  size: 1000,
  isProgram: false,
  stage: stage,
  receivedBytes: received,
);

TransferResultView _result(
  TransferDirection direction, {
  TransferOutcome outcome = TransferOutcome.saved,
  String fileName = 'report.pdf',
}) => TransferResultView(
  direction: direction,
  peerFingerprint: _peerA,
  peerName: 'Peer',
  fileName: fileName,
  isProgram: false,
  outcome: outcome,
  canReveal: true,
);

SendQueuesView _queues({int selectionId = 1}) => SendQueuesView(
  selectionId: selectionId,
  peerFingerprint: _peerA,
  peerName: 'Peer',
  loose: const [],
  bundles: const [],
  finished: false,
  delivered: 0,
  total: 0,
  completedBytes: 0,
  pendingKnownBytes: 0,
  currentProbeSize: null,
);

const List<IncomingStage> _activeStages = [
  IncomingStage.waitingData,
  IncomingStage.receiving,
  IncomingStage.verifying,
];

const List<IncomingStage> _quietStages = [
  IncomingStage.warning,
  IncomingStage.folderQuestion,
  IncomingStage.ended,
];

void main() {
  group('E264 columnWidthFor', () {
    final cases = <double, double>{
      0: 280,
      288: 280,
      668: 280,
      716: 280,
      728: 280,
      768: 280,
      933: 280,
      1000: 300,
      1148: 344.4,
      1166: 349.8,
      1167: 350,
      1600: 350,
      4000: 350,
    };
    for (final MapEntry(key: body, value: column) in cases.entries) {
      test('a body of $body gives a column of $column', () {
        expect(columnWidthFor(body), closeTo(column, 1e-9));
      });
    }

    test('the column is 30 % of the body between 280 and 350', () {
      for (var body = 0.0; body <= 2000; body += 7) {
        final width = columnWidthFor(body);
        expect(width, inInclusiveRange(280, 350));
        if (body * 0.3 >= 280 && body * 0.3 <= 350) {
          expect(width, closeTo(body * 0.3, 1e-9));
        }
      }
    });
  });

  group('E264 showsDiagram', () {
    final cases = <double, bool>{
      0: false,
      288: false,
      320: false,
      668: false,
      715: false,
      715.9: false,
      716: true,
      728: true,
      768: true,
      1148: true,
      2000: true,
    };
    for (final MapEntry(key: body, value: shows) in cases.entries) {
      test('a body of $body ${shows ? 'shows' : 'hides'} the diagram', () {
        expect(showsDiagram(body), shows);
      });
    }

    test('the diagram shows exactly when it gets 420 px or more', () {
      for (var body = 0.0; body <= 2000; body += 0.5) {
        final diagram = body - 16 - columnWidthFor(body);
        expect(showsDiagram(body), diagram >= 420, reason: 'body $body');
      }
    });

    test('the minimum window of 760 leaves a diagram of 432 and a column '
        'of 280', () {
      const body = 760.0 - 32;
      expect(showsDiagram(body), isTrue);
      expect(columnWidthFor(body), 280);
      expect(body - 16 - columnWidthFor(body), 432);
    });
  });

  group('E266 hasActivity', () {
    test('an empty state has no activity', () {
      expect(hasActivity(const NodeState()), isFalse);
    });

    test('a state with devices, notices and scanning but no transfer has '
        'no activity', () {
      expect(
        hasActivity(
          const NodeState(
            scanning: true,
            suggestRescan: true,
            decisionNotSaved: true,
            notices: [Notice(id: 1, kind: NoticeKind.pairingPaused)],
          ),
        ),
        isFalse,
      );
    });

    for (final phase in OutgoingPhase.values) {
      test('an outgoing transfer in ${phase.name} is activity', () {
        expect(hasActivity(NodeState(outgoing: _out(phase: phase))), isTrue);
      });
    }

    for (final stage in _activeStages) {
      test('an incoming transfer in ${stage.name} is activity', () {
        expect(hasActivity(NodeState(incoming: _in(stage))), isTrue);
      });
    }

    for (final stage in _quietStages) {
      test('an incoming transfer in ${stage.name} is not activity', () {
        expect(hasActivity(NodeState(incoming: _in(stage))), isFalse);
      });
    }

    for (final outcome in TransferOutcome.values) {
      test('a lastSent ${outcome.name} is activity', () {
        expect(
          hasActivity(
            NodeState(
              lastSent: _result(TransferDirection.outgoing, outcome: outcome),
            ),
          ),
          isTrue,
        );
      });

      test('a lastReceived ${outcome.name} is activity', () {
        expect(
          hasActivity(
            NodeState(
              lastReceived: _result(
                TransferDirection.incoming,
                outcome: outcome,
              ),
            ),
          ),
          isTrue,
        );
      });
    }
  });

  group('E545 queues in the activity tab', () {
    test('hasActivity is true with queues even between two items', () {
      expect(hasActivity(NodeState(queues: _queues())), isTrue);
    });

    test('shouldShowActivity: queues that appear or a new selection ask for '
        'the tab, the same selection does not', () {
      final none = const NodeState();
      final first = NodeState(queues: _queues());
      expect(shouldShowActivity(none, first), isTrue);
      expect(shouldShowActivity(first, NodeState(queues: _queues())), isFalse);
      expect(
        shouldShowActivity(first, NodeState(queues: _queues(selectionId: 2))),
        isTrue,
      );
    });
  });

  group('E266 shouldShowActivity', () {
    test('nothing before and nothing after does not switch', () {
      expect(shouldShowActivity(null, const NodeState()), isFalse);
      expect(shouldShowActivity(const NodeState(), const NodeState()), isFalse);
    });

    group('outgoing', () {
      test('a new outgoing switches, from null or from an empty state', () {
        final after = NodeState(outgoing: _out());
        expect(shouldShowActivity(null, after), isTrue);
        expect(shouldShowActivity(const NodeState(), after), isTrue);
      });

      test('the same outgoing that only progresses does not switch', () {
        for (final (before, after) in [
          (_out(sent: 0), _out(sent: 500)),
          (
            _out(phase: OutgoingPhase.preparing),
            _out(phase: OutgoingPhase.requesting),
          ),
          (
            _out(phase: OutgoingPhase.uploading, sent: 1000),
            _out(phase: OutgoingPhase.verifying, sent: 1000),
          ),
        ]) {
          expect(
            shouldShowActivity(
              NodeState(outgoing: before),
              NodeState(outgoing: after),
            ),
            isFalse,
          );
        }
      });

      test('an outgoing to another device switches', () {
        expect(
          shouldShowActivity(
            NodeState(outgoing: _out(peer: _peerA)),
            NodeState(outgoing: _out(peer: _peerB)),
          ),
          isTrue,
        );
      });

      test('an outgoing of another file switches', () {
        expect(
          shouldShowActivity(
            NodeState(outgoing: _out(fileName: 'a.txt')),
            NodeState(outgoing: _out(fileName: 'b.txt')),
          ),
          isTrue,
        );
      });

      test('an outgoing that goes away without a result does not switch', () {
        expect(
          shouldShowActivity(NodeState(outgoing: _out()), const NodeState()),
          isFalse,
        );
      });
    });

    group('incoming', () {
      for (final stage in _activeStages) {
        test('${stage.name} from nothing switches', () {
          final after = NodeState(incoming: _in(stage));
          expect(shouldShowActivity(null, after), isTrue);
          expect(shouldShowActivity(const NodeState(), after), isTrue);
        });
      }

      for (final stage in _quietStages) {
        test('${stage.name} from nothing does not switch', () {
          final after = NodeState(incoming: _in(stage));
          expect(shouldShowActivity(null, after), isFalse);
          expect(shouldShowActivity(const NodeState(), after), isFalse);
        });
      }

      final transitions = <(IncomingStage, IncomingStage, bool)>[
        (IncomingStage.warning, IncomingStage.folderQuestion, false),
        (IncomingStage.warning, IncomingStage.waitingData, true),
        (IncomingStage.folderQuestion, IncomingStage.waitingData, true),
        (IncomingStage.waitingData, IncomingStage.receiving, true),
        (IncomingStage.receiving, IncomingStage.verifying, true),
        (IncomingStage.verifying, IncomingStage.ended, false),
        (IncomingStage.receiving, IncomingStage.ended, false),
        (IncomingStage.ended, IncomingStage.warning, false),
      ];
      for (final (from, to, switches) in transitions) {
        test('${from.name} to ${to.name} '
            '${switches ? 'switches' : 'does not switch'}', () {
          expect(
            shouldShowActivity(
              NodeState(incoming: _in(from)),
              NodeState(incoming: _in(to)),
            ),
            switches,
          );
        });
      }

      test('receiving that only progresses does not switch', () {
        expect(
          shouldShowActivity(
            NodeState(incoming: _in(IncomingStage.receiving, received: 10)),
            NodeState(incoming: _in(IncomingStage.receiving, received: 900)),
          ),
          isFalse,
        );
      });

      test('an incoming that goes away without a result does not switch', () {
        expect(
          shouldShowActivity(
            NodeState(incoming: _in(IncomingStage.receiving)),
            const NodeState(),
          ),
          isFalse,
        );
      });
    });

    for (final (label, build) in [
      ('lastSent', (TransferResultView? result) => NodeState(lastSent: result)),
      (
        'lastReceived',
        (TransferResultView? result) => NodeState(lastReceived: result),
      ),
    ]) {
      group(label, () {
        final first = _result(TransferDirection.outgoing, fileName: 'a.txt');
        final second = _result(TransferDirection.outgoing, fileName: 'b.txt');
        final failed = _result(
          TransferDirection.outgoing,
          fileName: 'a.txt',
          outcome: TransferOutcome.connectionLost,
        );

        test('null to a value switches, also from a null state', () {
          expect(shouldShowActivity(null, build(first)), isTrue);
          expect(shouldShowActivity(build(null), build(first)), isTrue);
        });

        test('a failed result switches too', () {
          expect(shouldShowActivity(build(null), build(failed)), isTrue);
        });

        test('the same value again does not switch', () {
          expect(shouldShowActivity(build(first), build(first)), isFalse);
        });

        test('another value switches', () {
          expect(shouldShowActivity(build(first), build(second)), isTrue);
          expect(shouldShowActivity(build(first), build(failed)), isTrue);
        });

        test('going back to null does not switch', () {
          expect(shouldShowActivity(build(first), build(null)), isFalse);
        });
      });
    }

    test('an outgoing that ends in a result switches', () {
      expect(
        shouldShowActivity(
          NodeState(outgoing: _out()),
          NodeState(lastSent: _result(TransferDirection.outgoing)),
        ),
        isTrue,
      );
    });

    test('changes outside transfers do not switch', () {
      final before = NodeState(
        lastSent: _result(TransferDirection.outgoing),
        lastReceived: _result(TransferDirection.incoming),
        outgoing: _out(),
        incoming: _in(IncomingStage.receiving),
      );
      final after = NodeState(
        lastSent: _result(TransferDirection.outgoing),
        lastReceived: _result(TransferDirection.incoming),
        outgoing: _out(),
        incoming: _in(IncomingStage.receiving),
        scanning: true,
        paused: true,
        decisionNotSaved: true,
      );
      expect(shouldShowActivity(before, after), isFalse);
    });
  });
}
