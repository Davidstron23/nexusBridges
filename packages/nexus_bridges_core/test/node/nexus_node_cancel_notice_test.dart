import 'package:nexus_bridges_core/src/identity/identity.dart'
    show shortFingerprint;
import 'package:nexus_bridges_core/src/node/node.dart';
import 'package:nexus_bridges_core/src/pairing/pairing.dart' show PeerRelation;
import 'package:test/test.dart';

import 'transfer_nodes_harness.dart';

final String _dot = String.fromCharCode(0x00B7);

Future<Notice> _cancelOnce(TransferNode a, TransferNode b, String path) async {
  final before = b.state.notices.isEmpty ? -1 : b.state.notices.last.id;
  expect(await a.send(b, path), SendFileResult.started);
  await b.incomingAt(IncomingStage.warning);
  a.node.cancelSending();
  await a.sentResult(after: a.state.lastSent);
  final s = await b.until(
    (s) =>
        s.incoming == null &&
        s.notices.any(
          (n) => n.kind == NoticeKind.peerCancelledTransfer && n.id > before,
        ),
    reason: 'cancel notice in B',
  );
  return s.notices.lastWhere((n) => n.kind == NoticeKind.peerCancelledTransfer);
}

void main() {
  group('E242, PR4-2: the cancel note carries the short fingerprint', () {
    test('a paired device with a name: name and short fingerprint', () async {
      final (a, b) = await transferNodes(aAtB: PeerRelation.foreign);
      final path = await a.sourceFile('named.txt', [1, 2, 3]);

      final notice = await _cancelOnce(a, b, path);

      expect(notice.detail, 'Desk PC $_dot ${shortFingerprint(a.fingerprint)}');
      expect(notice.deviceName, isNull);
    }, timeout: transferTimeout);
  });

  group('E243 [SEG], PR4-3, probe P4: nine cancels from one device', () {
    test('a foreign sender that offers and cancels nine times, a minute '
        'apart, leaves one cancel notice in B, always the latest', () async {
      final (a, b) = await transferNodes(aAtB: PeerRelation.foreign);
      final path = await a.sourceFile('p4.txt', List<int>.filled(10, 1));
      final label = 'Desk PC $_dot ${shortFingerprint(a.fingerprint)}';
      final seen = <int>[];

      for (var round = 0; round < 9; round++) {
        final notice = await _cancelOnce(a, b, path);
        seen.add(notice.id);
        expect(b.state.notices, [notice], reason: 'round $round');
        expect(notice.detail, label);
        b.clock.advance(const Duration(seconds: 61));
        a.clock.advance(const Duration(seconds: 61));
      }

      expect(seen.toSet(), hasLength(9));
      for (var i = 1; i < seen.length; i++) {
        expect(seen[i], greaterThan(seen[i - 1]));
      }
    }, timeout: const Timeout(Duration(minutes: 4)));
  });
}
