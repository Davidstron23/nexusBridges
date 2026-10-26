import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:nexus_bridges/src/l10n/app_strings.dart';
import 'package:nexus_bridges/src/ui/diagram/flow_layout.dart';
import 'package:nexus_bridges/src/ui/diagram/flow_scene.dart';
import 'package:nexus_bridges/src/ui/format.dart';
import 'package:nexus_bridges/src/ui/theme/components.dart' show ChipTone;
import 'package:nexus_bridges_core/nexus_bridges_core.dart';

const String _dot = '\u00B7';
const Size _wide = Size(788, 588);
const Size _small = Size(572, 468);

DeviceEntry _entry(
  String fingerprint, {
  String? name,
  bool visible = true,
  bool paired = true,
  bool mine = true,
  DeviceType? type = DeviceType.desktop,
}) => DeviceEntry(
  fingerprint: fingerprint,
  displayName: name ?? 'Device $fingerprint',
  deviceType: type,
  visible: visible,
  paired: paired,
  mine: mine,
  ignored: false,
  mismatch: false,
  possiblyReplaces: null,
);

OutgoingTransferView _out(
  String fingerprint,
  OutgoingPhase phase, {
  int size = 1000,
  int sent = 0,
  String fileName = 'out.txt',
  bool isProgram = false,
}) => OutgoingTransferView(
  peerFingerprint: fingerprint,
  peerName: 'Peer',
  fileName: fileName,
  size: size,
  isProgram: isProgram,
  phase: phase,
  sentBytes: sent,
  cancelling: false,
);

IncomingTransferView _in(
  String fingerprint,
  IncomingStage stage, {
  int size = 1000,
  int received = 0,
  String fileName = 'in.txt',
  bool isProgram = false,
  String sessionId = 's1',
}) => IncomingTransferView(
  sessionId: sessionId,
  peerFingerprint: fingerprint,
  peerName: 'Peer',
  fileName: fileName,
  size: size,
  isProgram: isProgram,
  stage: stage,
  receivedBytes: received,
);

TransferResultView _result(
  String fingerprint,
  TransferOutcome outcome, {
  TransferDirection direction = TransferDirection.outgoing,
  String fileName = 'done.txt',
}) => TransferResultView(
  direction: direction,
  peerFingerprint: fingerprint,
  peerName: 'Peer',
  fileName: fileName,
  isProgram: false,
  outcome: outcome,
  canReveal: false,
);

NodeState _state({
  List<DeviceEntry> entries = const [],
  OutgoingTransferView? outgoing,
  IncomingTransferView? incoming,
  TransferResultView? lastSent,
  TransferResultView? lastReceived,
  String deviceName = 'Main PC',
  String fingerprint = 'ABCDEF0123456789ABCDEF',
}) => NodeState(
  entries: entries,
  outgoing: outgoing,
  incoming: incoming,
  lastSent: lastSent,
  lastReceived: lastReceived,
  deviceName: deviceName,
  fingerprint: fingerprint,
);

List<String> _fingerprints(FlowScene scene) => [
  for (final peer in scene.peers) peer.fingerprint,
];

void main() {
  group('E262: linkFor, sending', () {
    for (final phase in [
      OutgoingPhase.preparing,
      OutgoingPhase.requesting,
      OutgoingPhase.waiting,
    ]) {
      test('$phase is waiting towards the peer', () {
        final link = linkFor(
          _state(
            outgoing: _out('A', phase, fileName: 'setup.exe', isProgram: true),
          ),
          'A',
        );
        expect(link.state, LinkState.waiting);
        expect(link.towardsHub, isFalse);
        expect(link.fileName, 'setup.exe');
        expect(link.isProgram, isTrue);
      });
    }

    test('uploading is active with sentBytes / size', () {
      final link = linkFor(
        _state(
          outgoing: _out(
            'A',
            OutgoingPhase.uploading,
            size: 1000,
            sent: 250,
            fileName: 'video.mp4',
          ),
        ),
        'A',
      );
      expect(
        link,
        const LinkView(
          state: LinkState.active,
          progress: 0.25,
          fileName: 'video.mp4',
        ),
      );
    });

    test('uploading a file of 0 bytes is complete at once', () {
      final link = linkFor(
        _state(outgoing: _out('A', OutgoingPhase.uploading, size: 0)),
        'A',
      );
      expect(link.state, LinkState.active);
      expect(link.progress, 1);
    });

    test('the upload progress is clamped between 0 and 1', () {
      expect(
        linkFor(
          _state(
            outgoing: _out('A', OutgoingPhase.uploading, size: 100, sent: 400),
          ),
          'A',
        ).progress,
        1,
      );
      expect(
        linkFor(
          _state(
            outgoing: _out('A', OutgoingPhase.uploading, size: 100, sent: -5),
          ),
          'A',
        ).progress,
        0,
      );
    });

    test('verifying is active and full, whatever was sent', () {
      final link = linkFor(
        _state(outgoing: _out('A', OutgoingPhase.verifying, sent: 0)),
        'A',
      );
      expect(link.state, LinkState.active);
      expect(link.progress, 1);
      expect(link.towardsHub, isFalse);
    });

    test('a send to another peer leaves this one idle', () {
      expect(
        linkFor(_state(outgoing: _out('B', OutgoingPhase.uploading)), 'A'),
        const LinkView(),
      );
    });
  });

  group('E262: linkFor, receiving', () {
    for (final stage in [IncomingStage.warning, IncomingStage.folderQuestion]) {
      test('$stage is asking towards the hub', () {
        final link = linkFor(
          _state(
            incoming: _in('A', stage, fileName: 'tool.ps1', isProgram: true),
          ),
          'A',
        );
        expect(link.state, LinkState.asking);
        expect(link.towardsHub, isTrue);
        expect(link.fileName, 'tool.ps1');
        expect(link.isProgram, isTrue);
      });
    }

    test('waitingData is waiting towards the hub', () {
      final link = linkFor(
        _state(incoming: _in('A', IncomingStage.waitingData)),
        'A',
      );
      expect(link.state, LinkState.waiting);
      expect(link.towardsHub, isTrue);
      expect(link.fileName, 'in.txt');
    });

    test('receiving is active towards the hub with receivedBytes / size', () {
      final link = linkFor(
        _state(
          incoming: _in('A', IncomingStage.receiving, size: 400, received: 100),
        ),
        'A',
      );
      expect(
        link,
        const LinkView(
          state: LinkState.active,
          towardsHub: true,
          progress: 0.25,
          fileName: 'in.txt',
        ),
      );
    });

    test('receiving a file of 0 bytes gives 1', () {
      final link = linkFor(
        _state(incoming: _in('A', IncomingStage.receiving, size: 0)),
        'A',
      );
      expect(link.progress, 1);
      expect(link.state, LinkState.active);
    });

    test('the receive progress is clamped between 0 and 1', () {
      expect(
        linkFor(
          _state(
            incoming: _in('A', IncomingStage.receiving, size: 10, received: 50),
          ),
          'A',
        ).progress,
        1,
      );
    });

    test('verifying is active and full towards the hub', () {
      final link = linkFor(
        _state(incoming: _in('A', IncomingStage.verifying, received: 0)),
        'A',
      );
      expect(link.state, LinkState.active);
      expect(link.towardsHub, isTrue);
      expect(link.progress, 1);
    });

    test('ended is idle, or done when it is the done fingerprint', () {
      final state = _state(incoming: _in('A', IncomingStage.ended));
      expect(linkFor(state, 'A'), const LinkView());
      expect(linkFor(state, 'A', doneFingerprint: 'A').state, LinkState.done);
    });

    test('a reception from another peer leaves this one idle', () {
      expect(
        linkFor(_state(incoming: _in('B', IncomingStage.receiving)), 'A'),
        const LinkView(),
      );
    });
  });

  group('E262: linkFor, priority', () {
    test('the question wins over the send to the same peer', () {
      for (final stage in [
        IncomingStage.warning,
        IncomingStage.folderQuestion,
      ]) {
        final link = linkFor(
          _state(
            outgoing: _out('A', OutgoingPhase.uploading, sent: 500),
            incoming: _in('A', stage, fileName: 'question.txt'),
          ),
          'A',
          doneFingerprint: 'A',
        );
        expect(link.state, LinkState.asking, reason: '$stage');
        expect(link.towardsHub, isTrue);
        expect(link.fileName, 'question.txt');
      }
    });

    test('the send wins over a reception in progress from the same peer', () {
      for (final stage in [
        IncomingStage.waitingData,
        IncomingStage.receiving,
        IncomingStage.verifying,
      ]) {
        final link = linkFor(
          _state(
            outgoing: _out(
              'A',
              OutgoingPhase.uploading,
              sent: 500,
              fileName: 'sent.txt',
            ),
            incoming: _in('A', stage, received: 100),
          ),
          'A',
        );
        expect(
          link,
          const LinkView(
            state: LinkState.active,
            progress: 0.5,
            fileName: 'sent.txt',
          ),
          reason: '$stage',
        );
      }
    });

    test('a send waiting wins over a reception from the same peer', () {
      final link = linkFor(
        _state(
          outgoing: _out('A', OutgoingPhase.requesting, fileName: 'sent.txt'),
          incoming: _in('A', IncomingStage.receiving, received: 900),
        ),
        'A',
      );
      expect(link.state, LinkState.waiting);
      expect(link.towardsHub, isFalse);
      expect(link.fileName, 'sent.txt');
    });

    test('done only when nothing else is going on with that peer', () {
      expect(
        linkFor(_state(), 'A', doneFingerprint: 'A').state,
        LinkState.done,
      );
      expect(
        linkFor(
          _state(outgoing: _out('A', OutgoingPhase.waiting)),
          'A',
          doneFingerprint: 'A',
        ).state,
        LinkState.waiting,
      );
      expect(
        linkFor(
          _state(incoming: _in('A', IncomingStage.receiving)),
          'A',
          doneFingerprint: 'A',
        ).state,
        LinkState.active,
      );
      expect(linkFor(_state(), 'A', doneFingerprint: 'B'), const LinkView());
    });

    test('without anything, idle', () {
      final link = linkFor(const NodeState(), 'A');
      expect(link, const LinkView());
      expect(link.state, LinkState.idle);
      expect(link.towardsHub, isFalse);
      expect(link.progress, 0);
      expect(link.fileName, isNull);
      expect(link.isProgram, isFalse);
    });
  });

  group('E262: LinkView', () {
    test('compares by value', () {
      const base = LinkView(
        state: LinkState.active,
        towardsHub: true,
        progress: 0.5,
        fileName: 'a.txt',
        isProgram: true,
      );
      const same = LinkView(
        state: LinkState.active,
        towardsHub: true,
        progress: 0.5,
        fileName: 'a.txt',
        isProgram: true,
      );
      expect(base, same);
      expect(base.hashCode, same.hashCode);
      for (final other in const [
        LinkView(
          state: LinkState.waiting,
          towardsHub: true,
          progress: 0.5,
          fileName: 'a.txt',
          isProgram: true,
        ),
        LinkView(
          state: LinkState.active,
          progress: 0.5,
          fileName: 'a.txt',
          isProgram: true,
        ),
        LinkView(
          state: LinkState.active,
          towardsHub: true,
          progress: 0.6,
          fileName: 'a.txt',
          isProgram: true,
        ),
        LinkView(
          state: LinkState.active,
          towardsHub: true,
          progress: 0.5,
          fileName: 'b.txt',
          isProgram: true,
        ),
        LinkView(
          state: LinkState.active,
          towardsHub: true,
          progress: 0.5,
          fileName: 'a.txt',
        ),
      ]) {
        expect(base == other, isFalse, reason: '$other');
      }
    });
  });

  group('E262: newlyDone (point 146)', () {
    final saved = _result('A', TransferOutcome.saved);
    final sending = _out('A', OutgoingPhase.verifying);

    test('without a state before, null', () {
      expect(newlyDone(null, _state(lastSent: saved)), isNull);
      expect(
        newlyDone(
          null,
          _state(
            lastReceived: _result(
              'A',
              TransferOutcome.saved,
              direction: TransferDirection.incoming,
            ),
          ),
        ),
        isNull,
      );
    });

    test('a send that ends with a saved result gives its fingerprint', () {
      expect(
        newlyDone(
          _state(outgoing: sending),
          _state(lastSent: _result('B', TransferOutcome.saved)),
        ),
        'B',
      );
    });

    test('saved without the mark also counts as saved', () {
      expect(
        newlyDone(
          _state(outgoing: sending),
          _state(lastSent: _result('A', TransferOutcome.savedWithoutMark)),
        ),
        'A',
      );
    });

    test('two sends in a row with the same lastSent by value give done '
        'both times', () {
      final first = newlyDone(
        _state(outgoing: sending),
        _state(lastSent: saved),
      );
      final again = newlyDone(
        _state(outgoing: sending, lastSent: saved),
        _state(lastSent: _result('A', TransferOutcome.saved)),
      );
      expect(first, 'A');
      expect(again, 'A');
    });

    test('a send that ends with a result that is not saved gives null', () {
      for (final outcome in [
        TransferOutcome.declined,
        TransferOutcome.cancelledHere,
        TransferOutcome.connectionLost,
        TransferOutcome.unconfirmed,
      ]) {
        expect(
          newlyDone(
            _state(outgoing: sending),
            _state(lastSent: _result('A', outcome)),
          ),
          isNull,
          reason: '$outcome',
        );
      }
    });

    test('a new lastSent without a send before (immediate result) gives '
        'null', () {
      expect(newlyDone(_state(), _state(lastSent: saved)), isNull);
      expect(
        newlyDone(
          _state(lastSent: _result('B', TransferOutcome.saved)),
          _state(lastSent: saved),
        ),
        isNull,
      );
    });

    test('a send still in progress gives null, even with a saved lastSent', () {
      expect(
        newlyDone(
          _state(outgoing: _out('A', OutgoingPhase.uploading), lastSent: saved),
          _state(outgoing: sending, lastSent: saved),
        ),
        isNull,
      );
    });

    test('a state that does not change gives null', () {
      final state = _state(lastSent: saved);
      expect(newlyDone(state, state), isNull);
      expect(newlyDone(_state(), _state()), isNull);
    });

    final received = _result(
      'C',
      TransferOutcome.saved,
      direction: TransferDirection.incoming,
    );

    for (final stage in [
      IncomingStage.waitingData,
      IncomingStage.receiving,
      IncomingStage.verifying,
    ]) {
      test('a reception in $stage that ends with a saved result gives its '
          'fingerprint', () {
        expect(
          newlyDone(
            _state(incoming: _in('C', stage)),
            _state(lastReceived: received),
          ),
          'C',
        );
        expect(
          newlyDone(
            _state(incoming: _in('C', stage)),
            _state(
              incoming: _in('C', IncomingStage.ended),
              lastReceived: received,
            ),
          ),
          'C',
        );
      });
    }

    test('two receptions in a row with the same lastReceived by value give '
        'done both times', () {
      expect(
        newlyDone(
          _state(
            incoming: _in('C', IncomingStage.verifying),
            lastReceived: received,
          ),
          _state(lastReceived: received),
        ),
        'C',
      );
    });

    test('receiving that moves to verifying is not done yet', () {
      expect(
        newlyDone(
          _state(
            incoming: _in('C', IncomingStage.receiving),
            lastReceived: received,
          ),
          _state(
            incoming: _in('C', IncomingStage.verifying),
            lastReceived: received,
          ),
        ),
        isNull,
      );
      expect(
        newlyDone(
          _state(incoming: _in('C', IncomingStage.waitingData)),
          _state(
            incoming: _in('C', IncomingStage.receiving),
            lastReceived: received,
          ),
        ),
        isNull,
      );
    });

    test(
      'a reception that ends with a result that is not saved gives null',
      () {
        expect(
          newlyDone(
            _state(incoming: _in('C', IncomingStage.receiving)),
            _state(
              lastReceived: _result(
                'C',
                TransferOutcome.damaged,
                direction: TransferDirection.incoming,
              ),
            ),
          ),
          isNull,
        );
      },
    );

    test('a warning or a folder question that goes away is not a finished '
        'reception', () {
      for (final stage in [
        IncomingStage.warning,
        IncomingStage.folderQuestion,
      ]) {
        expect(
          newlyDone(
            _state(incoming: _in('C', stage)),
            _state(lastReceived: received),
          ),
          isNull,
          reason: '$stage',
        );
      }
    });

    test('a new lastReceived without a reception before gives null', () {
      expect(newlyDone(_state(), _state(lastReceived: received)), isNull);
    });
  });

  group('E262: buildFlowScene', () {
    final entries = [
      _entry('MINE', name: 'Laptop', mine: true),
      _entry('FOREIGN', name: 'Ana PC', mine: false, type: DeviceType.mobile),
      _entry('HIDDEN', name: 'Old PC', mine: true, visible: false, type: null),
      _entry('NEAR', name: 'Unpaired', paired: false),
      _entry('FAR', name: 'Unpaired hidden', paired: false, visible: false),
    ];

    for (final language in ['es', 'en']) {
      final strings = stringsFor(language);

      test('in $language: only the paired peers, in their order, with the '
          'texts of AppStrings', () {
        final scene = buildFlowScene(
          state: _state(entries: entries),
          strings: strings,
          size: _wide,
          hovered: 'FOREIGN',
        );
        expect(_fingerprints(scene), ['MINE', 'FOREIGN', 'HIDDEN']);
        expect(scene.title, strings.diagramTitle);
        expect(scene.count, strings.diagramCount(3, 2));
        expect(scene.hubName, 'Main PC');
        expect(scene.hubCaption, strings.thisDeviceCaption('ABCDEF01'));
        expect(scene.hovered, 'FOREIGN');
        expect(scene.overflowLabel, isNull);
        expect(scene.animates, isFalse);
        expect(scene.layout.slots, hasLength(3));
        expect(scene.layout.hidden, 0);

        final mine = scene.peers[0];
        expect(mine.name, 'Laptop');
        expect(mine.deviceType, DeviceType.desktop);
        expect(mine.visible, isTrue);
        expect(mine.chipText, strings.chipMine);
        expect(mine.chipTone, ChipTone.run);
        expect(mine.link, const LinkView());

        final foreign = scene.peers[1];
        expect(foreign.name, 'Ana PC');
        expect(foreign.deviceType, DeviceType.mobile);
        expect(foreign.chipText, strings.chipForeign);
        expect(foreign.chipTone, ChipTone.foreign);

        final hidden = scene.peers[2];
        expect(hidden.deviceType, isNull);
        expect(hidden.visible, isFalse);
        expect(hidden.chipText, strings.notVisibleLabel);
        expect(hidden.chipTone, ChipTone.notVisible);
      });
    }

    test('the texts in Spanish', () {
      final scene = buildFlowScene(
        state: _state(entries: entries),
        strings: stringsFor('es'),
        size: _wide,
      );
      expect(scene.title, 'Mi red');
      expect(scene.count, '3 equipos $_dot 2 a la vista');
      expect(scene.hubCaption, 'ABCDEF01 $_dot este equipo');
      expect(
        [for (final peer in scene.peers) peer.chipText],
        ['M\u00EDo', 'Ajeno', 'No visible'],
      );
    });

    test('the texts in English', () {
      final scene = buildFlowScene(
        state: _state(entries: entries),
        strings: stringsFor('en'),
        size: _wide,
      );
      expect(scene.title, 'My network');
      expect(scene.count, '3 devices $_dot 2 visible');
      expect(scene.hubCaption, 'ABCDEF01 $_dot this device');
      expect(
        [for (final peer in scene.peers) peer.chipText],
        ['Mine', "Someone else's", 'Not visible'],
      );
    });

    test('a fingerprint shorter than 8 characters is used whole', () {
      final scene = buildFlowScene(
        state: _state(fingerprint: 'AB12'),
        strings: stringsFor('en'),
        size: _wide,
      );
      expect(scene.hubCaption, 'AB12 $_dot this device');
    });

    test('point 140: with an empty NodeState it does not throw and the '
        'caption is only "this device"', () {
      for (final language in ['es', 'en']) {
        final strings = stringsFor(language);
        for (final size in const [_wide, Size.zero, Size(-5, -5)]) {
          final scene = buildFlowScene(
            state: const NodeState(),
            strings: strings,
            size: size,
          );
          expect(scene.peers, isEmpty);
          expect(scene.layout.slots, isEmpty);
          expect(scene.hubName, isEmpty);
          expect(scene.count, strings.diagramCount(0, 0));
          expect(scene.overflowLabel, isNull);
          expect(scene.animates, isFalse);
          expect(scene.hovered, isNull);
        }
      }
      expect(
        buildFlowScene(
          state: const NodeState(),
          strings: stringsFor('es'),
          size: _wide,
        ).hubCaption,
        'este equipo',
      );
      expect(
        buildFlowScene(
          state: const NodeState(),
          strings: stringsFor('en'),
          size: _wide,
        ).hubCaption,
        'this device',
      );
    });

    test('the layout is the one of layoutFlow with the paired peers', () {
      final scene = buildFlowScene(
        state: _state(entries: entries),
        strings: stringsFor('en'),
        size: _wide,
      );
      final layout = layoutFlow(_wide, 3);
      expect(scene.layout.size, layout.size);
      expect(scene.layout.hub, layout.hub);
      expect(
        [for (final slot in scene.layout.slots) slot.center],
        [for (final slot in layout.slots) slot.center],
      );
    });

    test('each peer carries the link of linkFor', () {
      final state = _state(
        entries: entries,
        outgoing: _out('MINE', OutgoingPhase.uploading, sent: 300),
        incoming: _in('FOREIGN', IncomingStage.warning),
      );
      final scene = buildFlowScene(
        state: state,
        strings: stringsFor('en'),
        size: _wide,
        doneFingerprint: 'HIDDEN',
      );
      for (final peer in scene.peers) {
        expect(
          peer.link,
          linkFor(state, peer.fingerprint, doneFingerprint: 'HIDDEN'),
          reason: peer.fingerprint,
        );
      }
      expect(scene.peers[2].link.state, LinkState.done);
    });

    test('when everybody fits, the order of entries does not change, even '
        'with links in use', () {
      final scene = buildFlowScene(
        state: _state(
          entries: entries,
          outgoing: _out('HIDDEN', OutgoingPhase.waiting),
        ),
        strings: stringsFor('en'),
        size: _wide,
      );
      expect(_fingerprints(scene), ['MINE', 'FOREIGN', 'HIDDEN']);
    });

    final crowd = [
      _entry('P0', visible: false),
      _entry('P1', visible: false),
      _entry('P2'),
      _entry('P3', mine: false),
      _entry('P4', visible: false),
      _entry('P5'),
      _entry('P6'),
      _entry('P7', visible: false),
      _entry('U0', paired: false),
    ];

    test('with overflow, first the links in use, then the visible ones and '
        'then the rest, in a stable order, and the "+k" disc', () {
      final scene = buildFlowScene(
        state: _state(
          entries: crowd,
          outgoing: _out('P6', OutgoingPhase.uploading),
          incoming: _in('P7', IncomingStage.receiving),
        ),
        strings: stringsFor('es'),
        size: _small,
      );
      expect(scene.layout.hidden, 2);
      expect(_fingerprints(scene), ['P6', 'P7', 'P2', 'P3', 'P5', 'P0']);
      expect(scene.overflowLabel, formatOverflow(2));
      expect(scene.overflowLabel, '+2');
      expect(scene.count, '8 equipos $_dot 4 a la vista');
      expect(scene.layout.slots.last.overflow, isTrue);
      expect(scene.peers, hasLength(scene.layout.slots.length - 1));
    });

    test('with overflow, a done link also goes first', () {
      final scene = buildFlowScene(
        state: _state(
          entries: crowd,
          outgoing: _out('P6', OutgoingPhase.uploading),
          incoming: _in('P7', IncomingStage.receiving),
        ),
        strings: stringsFor('en'),
        size: _small,
        doneFingerprint: 'P4',
      );
      expect(_fingerprints(scene), ['P4', 'P6', 'P7', 'P2', 'P3', 'P5']);
    });

    test('with overflow and every link idle: the visible ones, then the '
        'rest', () {
      final scene = buildFlowScene(
        state: _state(entries: crowd),
        strings: stringsFor('en'),
        size: _small,
      );
      expect(_fingerprints(scene), ['P2', 'P3', 'P5', 'P6', 'P0', 'P1']);
      expect(scene.overflowLabel, '+2');
    });

    test('32 paired peers at 788x588: 13 peers and "+19"', () {
      final scene = buildFlowScene(
        state: _state(entries: [for (var i = 0; i < 32; i++) _entry('F$i')]),
        strings: stringsFor('en'),
        size: _wide,
      );
      expect(scene.peers, hasLength(13));
      expect(scene.overflowLabel, formatOverflow(19));
      expect(scene.overflowLabel, '+19');
      expect(_fingerprints(scene), [for (var i = 0; i < 13; i++) 'F$i']);
    });

    test('animates is false at rest, also with results and a done link', () {
      final scene = buildFlowScene(
        state: _state(
          entries: entries,
          lastSent: _result('MINE', TransferOutcome.saved),
          lastReceived: _result(
            'FOREIGN',
            TransferOutcome.saved,
            direction: TransferDirection.incoming,
          ),
          incoming: _in('FOREIGN', IncomingStage.ended),
        ),
        strings: stringsFor('en'),
        size: _wide,
        doneFingerprint: 'MINE',
      );
      expect(scene.peers.first.link.state, LinkState.done);
      expect(scene.animates, isFalse);
    });

    test('animates is true with a link waiting, asking or active', () {
      final busy = <NodeState>[
        _state(
          entries: entries,
          outgoing: _out('MINE', OutgoingPhase.preparing),
        ),
        _state(
          entries: entries,
          outgoing: _out('MINE', OutgoingPhase.uploading),
        ),
        _state(
          entries: entries,
          outgoing: _out('MINE', OutgoingPhase.verifying),
        ),
        _state(
          entries: entries,
          incoming: _in('FOREIGN', IncomingStage.warning),
        ),
        _state(
          entries: entries,
          incoming: _in('FOREIGN', IncomingStage.folderQuestion),
        ),
        _state(
          entries: entries,
          incoming: _in('FOREIGN', IncomingStage.waitingData),
        ),
        _state(
          entries: entries,
          incoming: _in('FOREIGN', IncomingStage.receiving),
        ),
        _state(
          entries: entries,
          incoming: _in('FOREIGN', IncomingStage.verifying),
        ),
      ];
      for (final state in busy) {
        final scene = buildFlowScene(
          state: state,
          strings: stringsFor('en'),
          size: _wide,
        );
        expect(scene.animates, isTrue);
      }
    });
  });
}
