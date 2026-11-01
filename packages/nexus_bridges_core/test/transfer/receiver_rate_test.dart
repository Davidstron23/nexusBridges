@TestOn('windows')
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:nexus_bridges_core/src/identity/identity.dart';
import 'package:nexus_bridges_core/src/pairing/pairing.dart';
import 'package:nexus_bridges_core/src/protocol/protocol.dart';
import 'package:nexus_bridges_core/src/transfer/transfer.dart';
import 'package:nexus_bridges_core/src/transport/transport.dart';
import 'package:test/test.dart';

import 'receiver_harness.dart';

const Timeout long = Timeout(Duration(minutes: 2));

void expectLimited(RawReply? reply) {
  expect(reply, isNotNull);
  expect(reply!.status, 429, reason: reply.text);
  expect(reply.json, {'error': 'rate_limited'});
}

void main() {
  late DeviceIdentity receiver;
  late Peer laptop;
  late Peer desk;
  late Peer portatil;
  late Peer tablet;

  setUpAll(() {
    receiver = DeviceIdentity.generate();
    laptop = Peer(DeviceIdentity.generate(), name: 'Laptop');
    desk = Peer(DeviceIdentity.generate(), name: 'Sobremesa');
    portatil = Peer(
      DeviceIdentity.generate(),
      name: 'PORTATIL',
      relation: PeerRelation.foreign,
    );
    tablet = Peer(
      DeviceIdentity.generate(),
      name: 'Tablet',
      relation: PeerRelation.foreign,
    );
  });

  Future<ReceiverStack> stack({
    void Function(TransferPlatform platform)? configure,
  }) => ReceiverStack.start(
    identity: receiver,
    peers: [laptop, desk, portatil, tablet],
    configure: configure,
  );

  Uint8List bytesOf(int index) =>
      Uint8List.fromList(utf8.encode('contents of file $index'));

  Future<StreamPostResult> upload(
    ReceiverStack s,
    Peer peer,
    String transfer,
    String permit,
    Uint8List bytes,
  ) => s.postUpload(
    peer.identity,
    headers: {
      TransferHeaders.transfer: transfer,
      TransferHeaders.permit: permit,
    },
    contentLength: bytes.length,
    body: Stream.value(bytes),
  );

  Future<RawReply?> offerOf(
    ReceiverStack s,
    Peer peer,
    String transfer,
    String name,
    Uint8List bytes,
  ) => s.post(
    peer.identity,
    ApiPaths.transferOffer,
    s.offerBody(
      transfer: transfer,
      name: name,
      size: bytes.length,
      sha256: sha256.convert(bytes).toString(),
    ),
  );

  String savedPermit(RawReply? reply) {
    expect(reply, isNotNull);
    expect(reply!.status, 200, reason: reply.text);
    expect(reply.state, 'accepted');
    return reply.json['permit']! as String;
  }

  Future<void> sendMine(ReceiverStack s, Peer peer, int index) async {
    final bytes = bytesOf(index);
    final transfer = newTransferId();
    final permit = savedPermit(
      await offerOf(s, peer, transfer, 'file$index.txt', bytes),
    );
    final result = await upload(s, peer, transfer, permit, bytes);
    final response = (result as StreamPostAnswered).response;
    expect(response.status, 200, reason: 'file $index');
    expect(
      jsonDecode(utf8.decode(response.body)),
      containsPair('state', 'saved'),
    );
  }

  Future<String> acceptForeign(ReceiverStack s, Peer peer, int index) async {
    final bytes = bytesOf(index);
    final transfer = newTransferId();
    final first = await offerOf(s, peer, transfer, 'file$index.txt', bytes);
    expect(first?.status, 202, reason: first?.text);
    await eventually(
      () => s.incoming?.stage == IncomingStage.warning,
      reason: 'warning of file $index',
    );
    s.coordinator.answerWarning(s.sid, accept: true);
    final second = await s.wait(peer, transfer);
    final permit = savedPermit(second);
    return '$transfer:$permit';
  }

  Future<void> sendForeign(ReceiverStack s, Peer peer, int index) async {
    final pair = (await acceptForeign(s, peer, index)).split(':');
    final result = await upload(s, peer, pair[0], pair[1], bytesOf(index));
    final response = (result as StreamPostAnswered).response;
    expect(response.status, 200, reason: 'file $index');
    expect(
      jsonDecode(utf8.decode(response.body)),
      containsPair('state', 'saved'),
    );
  }

  Future<void> setRelation(ReceiverStack s, Peer peer, PeerRelation to) async {
    await s.paired.replaceAll([
      for (final device in s.paired.devices)
        if (device.fingerprint == peer.fingerprint)
          PairedDevice(
            fingerprint: device.fingerprint,
            name: device.name,
            certificatePem: device.certificatePem,
            relation: to,
            pairedAt: device.pairedAt,
          )
        else
          device,
    ]);
    s.coordinator.pairedChanged();
  }

  group('E585 [SEG] an exhausted upload quota gives 429 before anything is '
      'shown', () {
    test('a foreign peer with 12 uploads accepted in the last minute offers '
        'again: 429, no warning, nothing written', () async {
      final s = await stack();
      for (var i = 0; i < 12; i++) {
        await sendForeign(s, portatil, i);
      }
      expect(treeNames(s), hasLength(12));
      final shown = s.seen.length;
      final events = s.events.length;
      final inspected = s.platform.calls.length;

      expectLimited(await s.offer(portatil, name: 'one-more.txt'));

      expect(s.incoming, isNull);
      expect(s.coordinator.busy, isFalse);
      expect(s.seen.length, shown);
      expect(s.events.length, events);
      expect(s.platform.calls.length, inspected);
      expect(treeNames(s), hasLength(12));
      expect(s.coordinator.lastReceived?.fileName, 'file11.txt');
      for (final line in s.logs) {
        expect(line, isNot(contains(portatil.fingerprint)));
      }
    }, timeout: long);

    test('the same foreign peer gets room again once the marks fall out of '
        'the window', () async {
      final s = await stack();
      for (var i = 0; i < 12; i++) {
        await sendForeign(s, portatil, i);
      }
      expectLimited(await s.offer(portatil));
      s.clock.advance(const Duration(seconds: 61));
      final reply = await s.offer(portatil);
      expect(reply?.status, 202, reason: reply?.text);
      await eventually(
        () => s.incoming?.stage == IncomingStage.warning,
        reason: 'warning back on screen',
      );
    }, timeout: long);

    test('a mine peer sends 20 files in a row with 200 ms between them and '
        'never gets 429', () async {
      final s = await stack();
      for (var i = 0; i < 20; i++) {
        await sendMine(s, laptop, i);
        s.clock.advance(Limits.queueElementGap);
      }
      expect(treeNames(s), hasLength(20));
      expect(s.coordinator.lastReceived?.outcome, TransferOutcome.saved);
    }, timeout: long);

    test('the quota of one foreign peer does not touch another one behind '
        'the same address', () async {
      final s = await stack();
      for (var i = 0; i < 12; i++) {
        await sendForeign(s, portatil, i);
      }
      expectLimited(await s.offer(portatil));
      final reply = await s.offer(tablet);
      expect(reply?.status, 202, reason: reply?.text);
    }, timeout: long);
  });

  group('E586 [SEG] a granted upload is never limited', () {
    test('the 12th quota is taken at acceptance: the upload with its permit '
        'still goes through and saves', () async {
      final s = await stack();
      for (var i = 0; i < 11; i++) {
        await sendForeign(s, portatil, i);
      }
      final pair = (await acceptForeign(s, portatil, 11)).split(':');
      final result = await upload(s, portatil, pair[0], pair[1], bytesOf(11));
      final response = (result as StreamPostAnswered).response;
      expect(response.status, 200, reason: utf8.decode(response.body));
      expect(
        jsonDecode(utf8.decode(response.body)),
        containsPair('state', 'saved'),
      );
      expect(treeNames(s), hasLength(12));
      expectLimited(await s.offer(portatil, name: 'late.txt'));
    }, timeout: long);

    test(
      'marking the sender as foreign during the upload does not cut it',
      () async {
        final s = await stack();
        final bytes = Uint8List.fromList(
          List<int>.generate(2 * 1024 * 1024, (i) => i % 251),
        );
        final transfer = newTransferId();
        final permit = savedPermit(
          await offerOf(s, laptop, transfer, 'big.bin', bytes),
        );
        final body = StreamController<List<int>>();
        final result = s.postUpload(
          laptop.identity,
          headers: {
            TransferHeaders.transfer: transfer,
            TransferHeaders.permit: permit,
          },
          contentLength: bytes.length,
          body: body.stream,
        );
        body.add(Uint8List.sublistView(bytes, 0, 512 * 1024));
        await eventually(
          () =>
              s.incoming?.stage == IncomingStage.receiving &&
              s.incoming!.receivedBytes == 512 * 1024,
          reason: 'first half written',
        );

        await setRelation(s, laptop, PeerRelation.foreign);
        expect(s.incoming?.stage, IncomingStage.receiving);

        body.add(Uint8List.sublistView(bytes, 512 * 1024));
        await body.close();
        final response = ((await result) as StreamPostAnswered).response;
        expect(response.status, 200, reason: utf8.decode(response.body));
        expect(
          jsonDecode(utf8.decode(response.body)),
          containsPair('state', 'saved'),
        );
        expect(s.coordinator.lastReceived?.outcome, TransferOutcome.saved);
      },
      timeout: long,
    );
  });

  group('E582 point 13: the quota is checked again with the relation of the '
      'moment of the decision', () {
    test('a mine peer with 20 uploads in the minute becomes foreign while its '
        'offer is being checked: 429 without anything shown and without a '
        'block, and room returns as the marks fall', () async {
      final s = await stack();
      for (var i = 0; i < 20; i++) {
        await sendMine(s, laptop, i);
        s.clock.advance(const Duration(seconds: 3));
      }
      final gate = Completer<void>();
      s.platform.volumeGate = gate;
      final shown = s.seen.length;
      final pending = s.offer(laptop, name: 'held.txt');
      await eventually(() => s.coordinator.busy, reason: 'offer admitted');

      await setRelation(s, laptop, PeerRelation.foreign);
      gate.complete();
      expectLimited(await pending);
      expect(s.incoming, isNull);
      expect(s.coordinator.busy, isFalse);
      expect(s.seen.length, shown);
      s.platform.volumeGate = null;

      expectLimited(await s.offer(laptop, name: 'again.txt'));

      s.clock.advance(const Duration(seconds: 27));
      final reply = await s.offer(laptop, name: 'later.txt');
      expect(reply?.status, 202, reason: reply?.text);
      await eventually(
        () => s.incoming?.stage == IncomingStage.warning,
        reason: 'warning of a foreign sender',
      );
    }, timeout: long);

    test(
      'a foreign peer turned mine has the high limit on its next offer',
      () async {
        final s = await stack();
        for (var i = 0; i < 12; i++) {
          await sendForeign(s, portatil, i);
        }
        expectLimited(await s.offer(portatil));
        await setRelation(s, portatil, PeerRelation.mine);
        final transfer = newTransferId();
        savedPermit(
          await s.offer(portatil, transfer: transfer, name: 'now-mine.txt'),
        );
      },
      timeout: long,
    );
  });

  group('wait and cancel are counted per fingerprint and relation', () {
    test('a foreign peer gets 120 waits and the 121st is 429, then it stays '
        'blocked for a minute while another foreign peer is not', () async {
      final s = await stack();
      final transfer = newTransferId();
      for (var i = 0; i < 120; i++) {
        final reply = await s.wait(portatil, transfer);
        expect(reply?.status, 404, reason: 'wait ${i + 1}');
      }
      expectLimited(await s.wait(portatil, transfer));
      s.clock.advance(const Duration(seconds: 30));
      expectLimited(await s.wait(portatil, transfer));
      expect((await s.wait(tablet, transfer))?.status, 404);
      s.clock.advance(const Duration(seconds: 31));
      expect((await s.wait(portatil, transfer))?.status, 404);
    }, timeout: long);

    test('a foreign peer gets 30 cancels and the 31st is 429; a mine peer is '
        'not limited at 31', () async {
      final s = await stack();
      for (var i = 0; i < 30; i++) {
        final reply = await s.cancel(portatil, newTransferId());
        expect(reply?.status, 200, reason: 'cancel ${i + 1}');
      }
      expectLimited(await s.cancel(portatil, newTransferId()));
      for (var i = 0; i < 31; i++) {
        final reply = await s.cancel(laptop, newTransferId());
        expect(reply?.status, 200, reason: 'mine cancel ${i + 1}');
      }
    }, timeout: long);

    test(
      '30 offers refused for a foreign peer count and the 31st is 429',
      () async {
        final s = await stack();
        for (var i = 0; i < 30; i++) {
          final reply = await s.offer(portatil, name: 'CON');
          expect(reply?.status, 422, reason: 'offer ${i + 1}');
        }
        expectLimited(await s.offer(portatil, name: 'CON'));
        expect((await s.offer(laptop, name: 'CON'))?.status, 422);
      },
      timeout: long,
    );
  });

  group('E584 unpairing forgets the counts', () {
    test(
      'after unpairing and pairing again the account starts from zero',
      () async {
        final s = await stack();
        for (var i = 0; i < 30; i++) {
          await s.cancel(portatil, newTransferId());
        }
        expectLimited(await s.cancel(portatil, newTransferId()));

        await s.paired.replaceAll([
          for (final device in s.paired.devices)
            if (device.fingerprint != portatil.fingerprint) device,
        ]);
        s.coordinator.pairedChanged();
        await s.paired.replaceAll([...s.paired.devices, portatil.device]);
        await s.server.rebuildTrust();

        expect((await s.cancel(portatil, newTransferId()))?.status, 200);
      },
      timeout: long,
    );

    test('peerUnpaired forgets them too', () async {
      final s = await stack();
      for (var i = 0; i < 31; i++) {
        await s.cancel(portatil, newTransferId());
      }
      expectLimited(await s.cancel(portatil, newTransferId()));
      await s.coordinator.peerUnpaired(portatil.fingerprint);
      expect((await s.cancel(portatil, newTransferId()))?.status, 200);
    }, timeout: long);
  });
}

List<String> treeNames(ReceiverStack s) => [
  for (final entity in Directory(s.receiveDir).listSync(followLinks: false))
    entity.path,
];
