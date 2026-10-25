import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:nexus_bridges_core/src/identity/identity.dart';
import 'package:nexus_bridges_core/src/node/node.dart';
import 'package:nexus_bridges_core/src/pairing/pairing.dart';
import 'package:nexus_bridges_core/src/pairing_flow/crypto.dart';
import 'package:nexus_bridges_core/src/pairing_flow/messages.dart';
import 'package:nexus_bridges_core/src/protocol/protocol.dart'
    show ApiPaths, Limits;
import 'package:nexus_bridges_core/src/storage/storage.dart';
import 'package:nexus_bridges_core/src/transport/transport.dart';
import 'package:test/test.dart';

import '../server/api_server_harness.dart' show anonymousContext;
import '../transfer/attacks_harness.dart';
import 'pairing_nodes_harness.dart' show breakFile;

const Timeout _long = Timeout(Duration(minutes: 4));

final InternetAddress _guestAddress = InternetAddress('127.0.0.2');

final InternetAddress _strangerAddress = InternetAddress('127.0.0.3');

final String _dot = String.fromCharCode(0x00B7);

final class _Guest {
  _Guest(this.name, this.relation) : identity = DeviceIdentity.generate();

  final String name;
  final PeerRelation relation;
  final DeviceIdentity identity;

  String get fingerprint => identity.fingerprint;

  String get label => '$name $_dot ${shortFingerprint(fingerprint)}';

  ForgedPeer toward(TransferNode b) =>
      ForgedPeer(identity, from: _guestAddress, target: b);
}

Future<TransferNode> _receiverWith(List<_Guest> guests) async {
  final nodes = await transferNodes(const ['Laptop']);
  final b = nodes.single;
  await PairedDevicesStore(
    JsonFileStore(File('${b.dataDir}\\paired.json')),
    ownerFingerprint: b.fingerprint,
    now: b.now,
  ).replaceAll([
    for (final guest in guests)
      PairedDevice(
        fingerprint: guest.fingerprint,
        name: guest.name,
        certificatePem: guest.identity.certificatePem,
        relation: guest.relation,
        pairedAt: DateTime.utc(2026, 10, 1),
      ),
  ]);
  await b.rememberReceiveFolder();
  await b.start();
  return b;
}

File _pairedFileOf(TransferNode b) => File('${b.dataDir}\\paired.json');

int _lastId(TransferNode b) =>
    b.state.notices.isEmpty ? -1 : b.state.notices.last.id;

List<Notice> _cancelNotices(TransferNode b) => [
  for (final notice in b.state.notices)
    if (notice.kind == NoticeKind.peerCancelledTransfer) notice,
];

Future<void> _offerAndCancel(
  TransferNode b,
  _Guest guest, {
  bool expectNotice = true,
}) async {
  final before = _lastId(b);
  final peer = guest.toward(b);
  final content = utf8.encode('hello from ${guest.name}');
  final transfer = newTransferId();
  final offered = await peer.offer(
    transfer: transfer,
    name: 'notes.txt',
    size: content.length,
    sha256: digestOf(content),
  );
  expect(offered?.status, 202, reason: offered?.text);
  expect(offered!.state, 'waiting');
  await b.until(
    (s) =>
        s.incoming?.stage == IncomingStage.warning &&
        s.incoming!.peerFingerprint == guest.fingerprint,
    reason: 'warning from ${guest.name}',
  );
  final cancelled = await peer.cancel(transfer);
  expect(cancelled?.status, 200, reason: cancelled?.text);
  await b.until((s) => s.incoming == null, reason: 'card of ${guest.name}');
  if (expectNotice) {
    await b.until(
      (s) => s.notices.any(
        (n) => n.kind == NoticeKind.peerCancelledTransfer && n.id > before,
      ),
      reason: 'cancel notice of ${guest.name}',
    );
  } else {
    await Future<void>.delayed(const Duration(milliseconds: 300));
  }
  b.clock.advance(const Duration(seconds: 61));
}

Future<void> _unpairedBy(TransferNode b, _Guest guest) async {
  final reply = await guest
      .toward(b)
      .post(ApiPaths.unpair, const <String, Object?>{});
  expect(reply?.status, 200, reason: reply?.text);
  await b.until(
    (s) => s.notices.any((n) => n.kind == NoticeKind.unpairedByPeer),
    reason: 'unpairedByPeer from ${guest.name}',
  );
}

Future<void> _dataMismatchOn(TransferNode b) async {
  final before = _lastId(b);
  final identity = DeviceIdentity.generate();
  final nonce = randomBytes(nonceLength);
  final commitment = commitmentOf(
    role: PairingRole.initiator,
    fingerprint: identity.fingerprint,
    nonce: nonce,
  );
  final transcript = startTranscript(
    initiatorFingerprint: identity.fingerprint,
    receiverFingerprint: b.fingerprint,
    name: 'Stranger',
    deviceType: DeviceType.desktop,
    initiatorCommitment: commitment,
  );
  Future<HttpsResponse?> post(String path, Object? json) => postJson(
    address: b.internetAddress,
    port: b.port,
    path: path,
    json: json,
    context: anonymousContext,
    acceptServer: (certificate) {
      try {
        return fingerprintOfCertificate(certificate.der) == b.fingerprint;
      } on FormatException {
        return false;
      }
    },
    sourceAddress: _strangerAddress,
    maxResponseBytes: Limits.maxPairingBodyBytes,
  );

  final started = await post(
    ApiPaths.pairStart,
    StartRequest(
      certificate: identity.certificatePem,
      name: 'Stranger',
      deviceType: DeviceType.desktop,
      commitment: commitment,
      proof: identity.sign(transcript),
    ).toJson(),
  );
  expect(started?.status, 200);
  final reply = StartReply.tryParse(
    jsonDecode(utf8.decode(started!.body)) as Map<String, Object?>,
  )!;
  final other = Uint8List.fromList(randomBytes(nonceLength));
  final revealed = await post(
    ApiPaths.pairReveal,
    RevealRequest(
      session: reply.session,
      nonce: other,
      signature: identity.sign(
        revealTranscript(
          startTranscript: transcript,
          sessionId: reply.session,
          receiverCommitment: reply.commitment,
          initiatorNonce: other,
        ),
      ),
    ).toJson(),
  );
  expect(revealed?.status, 403);
  await b.until(
    (s) => s.notices.any(
      (n) => n.kind == NoticeKind.attemptDataMismatch && n.id > before,
    ),
    reason: 'attemptDataMismatch',
  );
  await b.until((s) => s.pairing == null, reason: 'no pairing on screen');
}

void main() {
  group('E242, PR4-2: the cancel note carries the short fingerprint', () {
    test('a paired device whose stored name cleans to nothing gets only its '
        'short fingerprint', () async {
      final unnamed = _Guest('   ', PeerRelation.foreign);
      final b = await _receiverWith([unnamed]);

      await _offerAndCancel(b, unnamed);

      expect(
        _cancelNotices(b).single.detail,
        shortFingerprint(unnamed.fingerprint),
      );
    }, timeout: _long);

    test('a foreign device that took the name of a mine one is told apart by '
        'its short fingerprint', () async {
      final mine = _Guest('Desk PC', PeerRelation.mine);
      final namesake = _Guest('Desk PC', PeerRelation.foreign);
      final b = await _receiverWith([mine, namesake]);

      await _offerAndCancel(b, namesake);

      final detail = _cancelNotices(b).single.detail;
      expect(detail, namesake.label);
      expect(detail, isNot(mine.label));
      expect(detail, isNot('Desk PC'));
    }, timeout: _long);
  });

  group('E243 [SEG], PR4-3: one cancel notice per paired device', () {
    test('a foreign device that offers and cancels nine times leaves a single '
        'notice of its own, the earlier attemptDataMismatch and unpairedByPeer '
        'stay, and a second device keeps its own notice', () async {
      final foreign = _Guest('Guest PC', PeerRelation.foreign);
      final other = _Guest('Other PC', PeerRelation.foreign);
      final leaving = _Guest('Old PC', PeerRelation.foreign);
      final b = await _receiverWith([foreign, other, leaving]);

      await _dataMismatchOn(b);
      await _unpairedBy(b, leaving);
      final earlier = b.state.notices;
      expect(earlier.map((n) => n.kind), [
        NoticeKind.attemptDataMismatch,
        NoticeKind.unpairedByPeer,
      ]);

      for (var round = 0; round < 9; round++) {
        await _offerAndCancel(b, foreign);
        final mine = _cancelNotices(b);
        expect(mine, hasLength(1), reason: 'round $round');
        expect(mine.single.detail, foreign.label);
        expect(mine.single.id, _lastId(b));
      }
      expect(b.state.notices.take(2), earlier);
      expect(b.state.notices, hasLength(3));

      await _offerAndCancel(b, other);
      await _offerAndCancel(b, other);

      expect(b.state.notices.take(2), earlier);
      expect(
        [for (final n in _cancelNotices(b)) n.detail],
        [foreign.label, other.label],
      );
      expect(b.state.notices, hasLength(4));
    }, timeout: _long);
  });

  group('E244 [SEG], PR4-3: protected notices survive the cut to 8', () {
    test('with unpairedByPeer, changeNotSaved (retry) and attemptDataMismatch '
        'in the list, eight cancel notices of eight devices do not push them '
        'out: the oldest cancel notices go instead', () async {
      final guests = [
        for (var i = 0; i < 8; i++) _Guest('Guest $i', PeerRelation.foreign),
      ];
      final leaving = _Guest('Old PC', PeerRelation.foreign);
      final b = await _receiverWith([...guests, leaving]);
      breakFile(_pairedFileOf(b));

      await _dataMismatchOn(b);
      await _unpairedBy(b, leaving);
      await b.until(
        (s) => s.notices.any((n) => n.kind == NoticeKind.changeNotSaved),
        reason: 'changeNotSaved',
      );
      final protected = b.state.notices;
      expect(protected.map((n) => n.kind), [
        NoticeKind.attemptDataMismatch,
        NoticeKind.unpairedByPeer,
        NoticeKind.changeNotSaved,
      ]);
      expect(protected[1].deviceName, leaving.label);
      expect(protected[2].canRetry, isTrue);

      for (final guest in guests) {
        await _offerAndCancel(b, guest);
      }

      final notices = b.state.notices;
      expect(notices, hasLength(8));
      expect(notices.take(3), protected);
      expect(
        [for (final n in notices.skip(3)) n.detail],
        [for (final guest in guests.skip(3)) guest.label],
      );
      expect(
        notices
            .skip(3)
            .every((n) => n.kind == NoticeKind.peerCancelledTransfer),
        isTrue,
      );
      expect(b.state.unsavedChanges, isTrue);
    }, timeout: _long);
  });

  group('E245, PR4-3: when all eight are protected', () {
    test('one more protected notice pushes out the oldest one, even if it is '
        'protected, and the list stays at 8', () async {
      final guest = _Guest('Guest PC', PeerRelation.foreign);
      final leaving = _Guest('Old PC', PeerRelation.foreign);
      final b = await _receiverWith([guest, leaving]);
      breakFile(_pairedFileOf(b));
      await _unpairedBy(b, leaving);
      await b.until(
        (s) => s.notices.any((n) => n.kind == NoticeKind.changeNotSaved),
        reason: 'changeNotSaved',
      );

      for (var i = 0; i < 6; i++) {
        await b.node.setMine(guest.fingerprint, mine: i.isEven);
      }
      final full = b.state.notices;
      expect(full, hasLength(8));
      expect(full.first.kind, NoticeKind.unpairedByPeer);
      expect(
        full.skip(1).every((n) => n.kind == NoticeKind.changeNotSaved),
        isTrue,
      );

      await b.node.setMine(guest.fingerprint, mine: true);

      final after = b.state.notices;
      expect(after, hasLength(8));
      expect(after.take(7), full.skip(1));
      expect(after.last.kind, NoticeKind.changeNotSaved);
      expect(after.last.id, greaterThan(full.last.id));
      expect(after.any((n) => n.kind == NoticeKind.unpairedByPeer), isFalse);
    }, timeout: _long);

    test('a new notice that is not protected is the one dropped, and the '
        'eight protected ones stay as they were', () async {
      final toggled = _Guest('Guest PC', PeerRelation.foreign);
      final sender = _Guest('Sender PC', PeerRelation.foreign);
      final leaving = _Guest('Old PC', PeerRelation.foreign);
      final b = await _receiverWith([toggled, sender, leaving]);
      breakFile(_pairedFileOf(b));
      await _unpairedBy(b, leaving);
      await b.until(
        (s) => s.notices.any((n) => n.kind == NoticeKind.changeNotSaved),
        reason: 'changeNotSaved',
      );
      for (var i = 0; i < 6; i++) {
        await b.node.setMine(toggled.fingerprint, mine: i.isEven);
      }
      final full = b.state.notices;
      expect(full, hasLength(8));

      await _offerAndCancel(b, sender, expectNotice: false);

      expect(b.state.notices, full);
      expect(_cancelNotices(b), isEmpty);
    }, timeout: _long);
  });
}
