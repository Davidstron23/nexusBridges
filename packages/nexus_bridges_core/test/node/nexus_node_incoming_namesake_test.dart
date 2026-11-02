import 'package:nexus_bridges_core/src/identity/identity.dart';
import 'package:nexus_bridges_core/src/node/node.dart';
import 'package:nexus_bridges_core/src/pairing/pairing.dart' show PeerRelation;
import 'package:test/test.dart';

import 'pairing_nodes_harness.dart' show pairedEntryFor;
import 'transfer_nodes_harness.dart';

final String _acuteA = String.fromCharCode(0x00E1);
final String _combiningAcute = String.fromCharCode(0x0301);
final String _laptopNfc = 'Port${_acuteA}til de David';
final String _laptopNfd = 'Porta${_combiningAcute}til de David';

final class _Seeded {
  _Seeded(this.a, this.b, this.other);

  final TransferNode a;
  final TransferNode b;
  final DeviceIdentity other;
}

Future<_Seeded> _nodesWithOther({
  required String nameA,
  required String otherName,
  PeerRelation aAtB = PeerRelation.foreign,
  PeerRelation otherRelation = PeerRelation.mine,
  bool rememberB = true,
}) async {
  final other = DeviceIdentity.generate();
  final (a, b) = await transferNodes(
    aAtB: aAtB,
    nameA: nameA,
    rememberB: rememberB,
    before: (a, b) async {
      final idA = await a.loadIdentity();
      final idB = await b.loadIdentity();
      await b.writePaired(idB, [
        pairedEntryFor(idA, name: nameA, relation: aAtB),
        pairedEntryFor(other, name: otherName, relation: otherRelation),
      ]);
    },
  );
  expect(
    b.state.entries.where((e) => e.fingerprint == other.fingerprint),
    hasLength(1),
  );
  return _Seeded(a, b, other);
}

void _expectNamesakeOnlyWithIncoming(List<NodeState> states, String? expected) {
  expect(states.where((s) => s.incoming != null), isNotEmpty);
  for (final s in states) {
    if (s.incoming == null) {
      expect(s.incomingNamesake, isNull);
    } else {
      expect(s.incomingNamesake, expected, reason: '${s.incoming!.stage}');
    }
  }
}

void main() {
  group('E248, RF-151: incomingNamesake with two real nodes', () {
    test('a foreign sender named like another paired device gives that name '
        'while the warning is shown, and null once it is rejected', () async {
      final seeded = await _nodesWithOther(
        nameA: _laptopNfc,
        otherName: _laptopNfc,
      );
      final a = seeded.a;
      final b = seeded.b;
      expect(b.state.incomingNamesake, isNull);
      final mark = b.states.length;
      final path = await a.sourceFile('notes.txt', [1, 2, 3]);

      expect(await a.send(b, path), SendResult.started);
      final warning = await b.incomingAt(IncomingStage.warning);
      expect(warning.peerFingerprint, a.fingerprint);
      expect(b.state.incomingNamesake, _laptopNfc);

      b.node.answerIncoming(warning.sessionId, accept: false);
      await b.until((s) => s.incoming == null, reason: 'warning gone in B');
      expect(b.state.incomingNamesake, isNull);
      expect((await a.sentResult()).outcome, TransferOutcome.declined);

      _expectNamesakeOnlyWithIncoming(b.states.skip(mark).toList(), _laptopNfc);
    }, timeout: transferTimeout);

    test('the name stays through the whole accepted session and goes back '
        'to null when the file is saved', () async {
      final seeded = await _nodesWithOther(
        nameA: _laptopNfc,
        otherName: _laptopNfc,
      );
      final a = seeded.a;
      final b = seeded.b;
      final mark = b.states.length;
      final path = await a.sourceFile('report.txt', List<int>.filled(4096, 9));

      expect(await a.send(b, path), SendResult.started);
      final warning = await b.incomingAt(IncomingStage.warning);
      expect(b.state.incomingNamesake, _laptopNfc);
      b.node.answerIncoming(warning.sessionId, accept: true);

      expect((await b.receivedResult()).outcome, TransferOutcome.saved);
      await b.until((s) => s.incoming == null, reason: 'session over in B');
      expect(b.state.incomingNamesake, isNull);
      expect((await a.sentResult()).outcome, TransferOutcome.saved);

      _expectNamesakeOnlyWithIncoming(b.states.skip(mark).toList(), _laptopNfc);
    }, timeout: transferTimeout);

    test('the sender name in NFD matches a paired device whose name is in '
        'NFC, and a foreign namesake counts too', () async {
      expect(_laptopNfd, isNot(_laptopNfc));
      final seeded = await _nodesWithOther(
        nameA: _laptopNfd,
        otherName: _laptopNfc,
        otherRelation: PeerRelation.foreign,
      );
      final a = seeded.a;
      final b = seeded.b;
      final mark = b.states.length;
      final path = await a.sourceFile('nfd.txt', [4]);

      expect(await a.send(b, path), SendResult.started);
      final warning = await b.incomingAt(IncomingStage.warning);
      expect(b.state.incomingNamesake, _laptopNfc);

      b.node.answerIncoming(warning.sessionId, accept: false);
      await b.until((s) => s.incoming == null, reason: 'warning gone in B');
      expect(b.state.incomingNamesake, isNull);

      _expectNamesakeOnlyWithIncoming(b.states.skip(mark).toList(), _laptopNfc);
    }, timeout: transferTimeout);

    test('case and accents are folded: a paired "PORTATIL DE DAVID" is a '
        'namesake of the sender and its own name is the one given', () async {
      final seeded = await _nodesWithOther(
        nameA: _laptopNfc,
        otherName: 'PORTATIL DE DAVID',
      );
      final a = seeded.a;
      final b = seeded.b;
      final path = await a.sourceFile('fold.txt', [5]);

      expect(await a.send(b, path), SendResult.started);
      final warning = await b.incomingAt(IncomingStage.warning);
      expect(b.state.incomingNamesake, 'PORTATIL DE DAVID');

      b.node.answerIncoming(warning.sessionId, accept: false);
      await b.until((s) => s.incoming == null, reason: 'warning gone in B');
      expect(b.state.incomingNamesake, isNull);
    }, timeout: transferTimeout);

    test('without a namesake it is null during the whole session: another '
        'paired name does not count and the sender is not its own '
        'namesake', () async {
      final seeded = await _nodesWithOther(
        nameA: 'Desk PC',
        otherName: _laptopNfc,
      );
      final a = seeded.a;
      final b = seeded.b;
      final mark = b.states.length;
      final path = await a.sourceFile('plain.txt', [6]);

      expect(await a.send(b, path), SendResult.started);
      final warning = await b.incomingAt(IncomingStage.warning);
      expect(b.state.incomingNamesake, isNull);

      b.node.answerIncoming(warning.sessionId, accept: true);
      expect((await b.receivedResult()).outcome, TransferOutcome.saved);

      final seen = b.states.skip(mark).toList();
      expect(seen.where((s) => s.incoming != null), isNotEmpty);
      expect(seen.map((s) => s.incomingNamesake), everyElement(isNull));
    }, timeout: transferTimeout);

    test('a "mine" sender without a remembered folder: the folder question '
        'carries the namesake, and cancelling it brings null', () async {
      final seeded = await _nodesWithOther(
        nameA: _laptopNfc,
        otherName: _laptopNfc,
        aAtB: PeerRelation.mine,
        rememberB: false,
      );
      final a = seeded.a;
      final b = seeded.b;
      final mark = b.states.length;
      final path = await a.sourceFile('mine.txt', [7]);

      expect(await a.send(b, path), SendResult.started);
      final question = await b.incomingAt(IncomingStage.folderQuestion);
      expect(b.state.incomingNamesake, _laptopNfc);

      b.node.cancelFolderQuestion(question.sessionId);
      await b.until((s) => s.incoming == null, reason: 'question gone in B');
      expect(b.state.incomingNamesake, isNull);
      await a.sentResult();

      _expectNamesakeOnlyWithIncoming(b.states.skip(mark).toList(), _laptopNfc);
    }, timeout: transferTimeout);

    test('unpairing the namesake while the warning is open emits a state '
        'with the same warning and incomingNamesake null', () async {
      final seeded = await _nodesWithOther(
        nameA: _laptopNfc,
        otherName: _laptopNfc,
      );
      final a = seeded.a;
      final b = seeded.b;
      final path = await a.sourceFile('live.txt', [8]);

      expect(await a.send(b, path), SendResult.started);
      final warning = await b.incomingAt(IncomingStage.warning);
      expect(b.state.incomingNamesake, _laptopNfc);

      await b.node.unpair(seeded.other.fingerprint);
      final after = await b.until(
        (s) => s.incomingNamesake == null,
        reason: 'namesake gone in B',
      );
      expect(after.incoming?.sessionId, warning.sessionId);
      expect(after.incoming?.stage, IncomingStage.warning);

      b.node.answerIncoming(warning.sessionId, accept: false);
      await b.until((s) => s.incoming == null, reason: 'warning gone in B');
    }, timeout: transferTimeout);
  });
}
