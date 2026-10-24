import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:nexus_bridges_core/src/identity/identity.dart';
import 'package:nexus_bridges_core/src/pairing/pairing.dart';
import 'package:nexus_bridges_core/src/protocol/protocol.dart';
import 'package:nexus_bridges_core/src/server/server.dart';
import 'package:nexus_bridges_core/src/transfer/transfer.dart';
import 'package:test/test.dart';

import '../pairing_flow/receiver_harness.dart' show TimerTracker;
import '../server/api_server_harness.dart';
import 'receiver_harness.dart';

void expectError(RawReply? reply, int status, String code) {
  expect(reply, isNotNull, reason: 'no reply, expected $status $code');
  expect(reply!.status, status, reason: reply.text);
  expect(reply.json, {'error': code});
}

void expectState(RawReply? reply, Map<String, Object?> state) {
  expect(reply, isNotNull, reason: 'no reply, expected $state');
  expect(reply!.status, 200, reason: reply.text);
  expect(reply.json, state);
}

void expectWaiting(RawReply? reply) {
  expect(reply, isNotNull);
  expect(reply!.status, 202, reason: reply.text);
  expect(reply.json, {'state': 'waiting', 'picker': false});
}

String expectAccepted(RawReply? reply) {
  expect(reply, isNotNull);
  expect(reply!.status, 200, reason: reply.text);
  expect(reply.state, 'accepted');
  final permit = reply.json['permit'] as String;
  expect(permit, matches(hex32));
  return permit;
}

const Map<String, Object?> cancelled = {'state': 'cancelled'};
const Map<String, Object?> waiting = {'state': 'waiting', 'picker': false};
const Map<String, Object?> declined = {
  'state': 'rejected',
  'reason': 'declined',
};
const Map<String, Object?> unanswered = {
  'state': 'rejected',
  'reason': 'unanswered',
};

ApiCall callFrom(Peer peer, String path, Object? json) => ApiCall(
  path: path,
  clientFingerprint: peer.fingerprint,
  remoteAddress: loopback,
  via: loopbackInterface(),
  json: json,
);

void main() {
  late DeviceIdentity receiver;
  late Peer laptop;
  late Peer portatil;
  late Peer tablet;
  late Peer phone;

  setUpAll(() {
    receiver = DeviceIdentity.generate();
    laptop = Peer(DeviceIdentity.generate(), name: 'Laptop');
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
    phone = Peer(
      DeviceIdentity.generate(),
      name: 'Movil',
      relation: PeerRelation.foreign,
    );
  });

  Future<ReceiverStack> stack({
    bool remembered = true,
    Duration pollHold = const Duration(milliseconds: 200),
    void Function(TransferPlatform platform)? configure,
  }) => ReceiverStack.start(
    identity: receiver,
    peers: [laptop, portatil, tablet, phone],
    remembered: remembered,
    pollHold: pollHold,
    configure: configure,
  );

  Future<TransferResultView> declinedBefore(ReceiverStack s, Peer peer) async {
    expectWaiting(await s.offer(peer, name: 'antes.txt'));
    s.coordinator.answerWarning(s.sid, accept: false);
    final last = s.coordinator.lastReceived!;
    expect(last.outcome, TransferOutcome.declined);
    return last;
  }

  group('E56 RF-215 insistent foreign device', () {
    test('a rejection blocks that device for exactly one minute', () async {
      final s = await stack();
      final first = newTransferId();
      expectWaiting(await s.offer(portatil, transfer: first));
      s.coordinator.answerWarning(s.sid, accept: false);
      expectState(await s.wait(portatil, first), declined);
      final last = s.coordinator.lastReceived;
      expect(last?.outcome, TransferOutcome.declined);
      expect(last?.peerName, 'PORTATIL');
      final changes = s.views.length;

      s.clock.advance(const Duration(seconds: 59));
      expectError(await s.offer(portatil), 403, 'declined');
      s.clock.advance(const Duration(milliseconds: 900));
      expectError(await s.offer(portatil), 403, 'declined');
      expect(s.incoming, isNull);
      expect(s.views.length, changes);
      expect(identical(s.coordinator.lastReceived, last), isTrue);

      s.clock.advance(const Duration(milliseconds: 100));
      expectWaiting(await s.offer(portatil));
      expect(s.incoming?.stage, IncomingStage.warning);
    });

    test('a warning that expires does not block the device', () async {
      final s = await stack();
      final id = newTransferId();
      expectWaiting(await s.offer(portatil, transfer: id));
      await s.advanceWithPolls(portatil, id, const Duration(seconds: 60));
      await eventually(() => s.incoming == null, reason: 'warning expired');
      expect(s.coordinator.lastReceived?.outcome, TransferOutcome.unanswered);
      expectState(await s.wait(portatil, id), unanswered);
      expectWaiting(await s.offer(portatil));
      expect(s.incoming?.stage, IncomingStage.warning);
    });

    test('another device is not blocked by the rejection', () async {
      final s = await stack();
      await declinedBefore(s, portatil);
      expectWaiting(await s.offer(tablet));
    });

    test('an own device is never blocked', () async {
      final s = await stack();
      await declinedBefore(s, portatil);
      expect(
        await s.paired.setRelation(portatil.fingerprint, PeerRelation.mine),
        isTrue,
      );
      expectAccepted(await s.offer(portatil));
      s.coordinator.cancelIncoming(s.sid);
      expect(
        await s.paired.setRelation(portatil.fingerprint, PeerRelation.foreign),
        isTrue,
      );
      expectError(await s.offer(portatil), 403, 'declined');
    });
  });

  group('E79 RF-154 rejecting the warning', () {
    test(
      'the sender sees declined at once and the rejection is recorded',
      () async {
        final s = await stack(pollHold: const Duration(seconds: 5));
        final id = newTransferId();
        expectWaiting(await s.offer(portatil, transfer: id));
        final stopwatch = Stopwatch()..start();
        final held = s.wait(portatil, id);
        await eventually(() => s.handledOn(ApiPaths.transferWait) == 1);
        await settle();
        s.coordinator.answerWarning(s.sid, accept: false);
        expectState(await held, declined);
        expect(stopwatch.elapsed, lessThan(const Duration(seconds: 3)));
        expect(s.incoming, isNull);
        expect(s.coordinator.busy, isFalse);
        expect(s.coordinator.lastReceived?.outcome, TransferOutcome.declined);
        expect(
          s.coordinator.lastReceived?.direction,
          TransferDirection.incoming,
        );
        expect(s.coordinator.lastReceived?.fileName, 'informe.pdf');
        expect(s.events, isEmpty);
        expectError(await s.offer(portatil), 403, 'declined');
      },
    );

    test(
      'accepting the warning hands the permit to the waiting sender',
      () async {
        final s = await stack(pollHold: const Duration(seconds: 5));
        final id = newTransferId();
        expectWaiting(await s.offer(portatil, transfer: id));
        final held = s.wait(portatil, id);
        await eventually(() => s.handledOn(ApiPaths.transferWait) == 1);
        await settle();
        s.coordinator.answerWarning(s.sid, accept: true);
        final reply = await held;
        expect(reply?.status, 200);
        expect(reply?.state, 'accepted');
        expect(reply?.json['permit'], matches(hex32));
        expect(s.incoming?.stage, IncomingStage.waitingData);
      },
    );

    test('answering when there is no warning does nothing', () async {
      final s = await stack();
      s.coordinator.answerWarning(s.sid, accept: false);
      s.coordinator.answerWarning(s.sid, accept: true);
      final id = newTransferId();
      final permit = expectAccepted(await s.offer(laptop, transfer: id));
      s.coordinator.answerWarning(s.sid, accept: false);
      expect(s.incoming?.stage, IncomingStage.waitingData);
      expectState(await s.wait(laptop, id), {
        'state': 'accepted',
        'permit': permit,
      });
    });
  });

  group('RF-155 the warning lasts 60 s', () {
    test('open at 59.9 s and unanswered at 60 s', () async {
      final s = await stack();
      final id = newTransferId();
      expectWaiting(await s.offer(portatil, transfer: id));
      await s.advanceWithPolls(
        portatil,
        id,
        const Duration(seconds: 59, milliseconds: 900),
      );
      await settle();
      expect(s.incoming?.stage, IncomingStage.warning);
      s.clock.advance(const Duration(milliseconds: 100));
      await eventually(() => s.incoming == null, reason: 'warning expired');
      expect(s.coordinator.lastReceived?.outcome, TransferOutcome.unanswered);
      expect(s.events, isEmpty);
      expectState(await s.wait(portatil, id), unanswered);
    });
  });

  group('E80 RF-156 the sender cancels with the card open', () {
    test('with the warning open', () async {
      final s = await stack();
      final before = await declinedBefore(s, tablet);
      final id = newTransferId();
      expectWaiting(await s.offer(portatil, transfer: id));
      expect(s.incoming?.stage, IncomingStage.warning);

      expectState(await s.cancel(portatil, id), cancelled);
      expect(s.incoming, isNull);
      expect(s.coordinator.busy, isFalse);
      expect(s.events, hasLength(1));
      final event = s.events.single as PeerCancelledTransfer;
      expect(event.peerFingerprint, portatil.fingerprint);
      expect(event.peerName, 'PORTATIL');
      expect(identical(s.coordinator.lastReceived, before), isTrue);
      expectState(await s.wait(portatil, id), cancelled);
      expectError(await s.offer(portatil), 403, 'declined');
      s.clock.advance(const Duration(seconds: 60));
      expectWaiting(await s.offer(portatil));
    });

    test('with the folder question open', () async {
      final s = await stack(remembered: false);
      final before = await declinedBefore(s, tablet);
      final id = newTransferId();
      expectWaiting(await s.offer(laptop, transfer: id));
      final view = s.incoming!;
      expect(view.stage, IncomingStage.folderQuestion);
      expect(view.folder?.kind, FolderQuestionKind.firstTime);
      expect(view.folder?.proposedPath, '${s.downloadsDir}\\NexusBridges');
      expect(view.folder?.problem, isNull);

      expectState(await s.cancel(laptop, id), cancelled);
      expect(s.incoming, isNull);
      expect(s.coordinator.busy, isFalse);
      final event = s.events.single as PeerCancelledTransfer;
      expect(event.peerFingerprint, laptop.fingerprint);
      expect(event.peerName, 'Laptop');
      expect(identical(s.coordinator.lastReceived, before), isTrue);
      expect(s.store.saved, isEmpty);
      expect(
        Directory('${s.downloadsDir}\\NexusBridges').existsSync(),
        isFalse,
      );
    });

    test(
      'a held wait is woken by the cancellation of another request',
      () async {
        final s = await stack(pollHold: const Duration(seconds: 5));
        final id = newTransferId();
        expectWaiting(await s.offer(portatil, transfer: id));
        final stopwatch = Stopwatch()..start();
        final held = s.wait(portatil, id);
        await eventually(() => s.handledOn(ApiPaths.transferWait) == 1);
        await settle();
        expectState(await s.cancel(portatil, id), cancelled);
        expectState(await held, cancelled);
        expect(stopwatch.elapsed, lessThan(const Duration(seconds: 3)));
      },
    );
  });

  group('A14 the folder question view', () {
    test(
      'a remembered folder that cannot be used asks for this time only',
      () async {
        final s = await ReceiverStack.start(
          identity: receiver,
          peers: [laptop],
          rememberedPath: (base) => '$base\\gone\\recv',
        );
        final gone = '${s.base}\\gone\\recv';
        expectWaiting(await s.offer(laptop));
        final view = s.incoming!;
        expect(view.stage, IncomingStage.folderQuestion);
        expect(view.folder?.kind, FolderQuestionKind.thisTime);
        expect(view.folder?.proposedPath, gone);
        expect(view.folder?.problem, FolderProblem.rememberedUnavailable);
        expect(Directory(gone).existsSync(), isFalse);
        expect(Directory('${s.base}\\gone').existsSync(), isFalse);
        expect(s.store.saved, isEmpty);
      },
    );

    test(
      'a folder store that fails is treated as no remembered folder',
      () async {
        final s = await ReceiverStack.start(
          identity: receiver,
          peers: [laptop],
          remembered: false,
          storeOverride: _FailingStore(),
        );
        expectWaiting(await s.offer(laptop));
        expect(s.incoming?.stage, IncomingStage.folderQuestion);
        expect(s.incoming?.folder?.kind, FolderQuestionKind.firstTime);
        final joined = s.logs.join('\n');
        expect(joined, contains('FileSystemException'));
        expect(joined, isNot(contains('nb-hidden-folder')));
        expect(joined, isNot(contains(s.base)));
      },
    );
  });

  group('E81 RF-233 cancel before anything is shown', () {
    test(
      'a cancel during the folder check ends the offer in silence with 410',
      () async {
        final gate = Completer<void>();
        final s = await stack(configure: (p) => p.volumeGate = gate);
        s.sampleViews();
        final id = newTransferId();
        final pending = s.offer(portatil, transfer: id);
        await eventually(() => s.coordinator.busy, reason: 'offer admitted');
        await eventually(() => s.platform.volumeCalls > 0, reason: 'checking');

        expectState(await s.cancel(portatil, id), cancelled);
        expect(s.coordinator.busy, isFalse);
        gate.complete();
        expectError(await pending, 410, 'cancelled');
        await settle();

        expect(s.seen, isEmpty);
        expect(s.views.whereType<IncomingTransferView>(), isEmpty);
        expect(s.coordinator.lastReceived, isNull);
        expect(s.events, isEmpty);
        expectState(await s.wait(portatil, id), cancelled);
        expectWaiting(await s.offer(portatil));
      },
    );

    test('a cancel that arrives before the offer leaves a tombstone', () async {
      final s = await stack();
      s.sampleViews();
      final id = newTransferId();
      expectState(await s.cancel(portatil, id), cancelled);
      expectError(await s.offer(portatil, transfer: id), 410, 'cancelled');
      expect(s.coordinator.busy, isFalse);
      await settle();
      expect(s.seen, isEmpty);
      expect(s.views, isEmpty);
      expect(s.coordinator.lastReceived, isNull);
      expect(s.events, isEmpty);
      expectWaiting(await s.offer(portatil));
    });

    test('the tombstone belongs to the fingerprint that cancelled', () async {
      final s = await stack();
      final id = newTransferId();
      expectState(await s.cancel(portatil, id), cancelled);
      expectWaiting(await s.offer(tablet, transfer: id));
    });

    test('a no_contact cancel during the check is silent too', () async {
      final gate = Completer<void>();
      final s = await stack(configure: (p) => p.volumeGate = gate);
      s.sampleViews();
      final id = newTransferId();
      final pending = s.offer(laptop, transfer: id);
      await eventually(() => s.platform.volumeCalls > 0, reason: 'checking');
      expectState(await s.cancel(laptop, id, reason: 'no_contact'), cancelled);
      gate.complete();
      expectError(await pending, 410, 'cancelled');
      await settle();
      expect(s.seen, isEmpty);
      expect(s.events, isEmpty);
      expect(s.coordinator.lastReceived, isNull);
    });
  });

  group('RF-233 no_contact after something was shown', () {
    test(
      'with the warning open the card is withdrawn with the notice',
      () async {
        final s = await stack();
        final id = newTransferId();
        expectWaiting(await s.offer(portatil, transfer: id));
        expectState(
          await s.cancel(portatil, id, reason: 'no_contact'),
          cancelled,
        );
        expect(s.incoming, isNull);
        expect(s.events.single, isA<PeerCancelledTransfer>());
        expect(s.coordinator.lastReceived, isNull);
      },
    );

    test('an accepted own device loses its permit with the notice', () async {
      final s = await stack();
      final before = await declinedBefore(s, tablet);
      final id = newTransferId();
      final permit = expectAccepted(await s.offer(laptop, transfer: id));
      final reply = await s.cancel(laptop, id, reason: 'no_contact');
      expectState(reply, cancelled);
      expect(reply!.text, isNot(contains(permit)));
      expect(s.incoming, isNull);
      expect(s.coordinator.busy, isFalse);
      final event = s.events.single as PeerCancelledTransfer;
      expect(event.peerFingerprint, laptop.fingerprint);
      expect(event.peerName, 'Laptop');
      expect(identical(s.coordinator.lastReceived, before), isTrue);
      final wait = await s.wait(laptop, id);
      expectState(wait, cancelled);
    });
  });

  group('cancelIncoming before the upload', () {
    test('an accepted session ends as cancelled here and counts', () async {
      final s = await stack();
      final id = newTransferId();
      final permit = expectAccepted(await s.offer(laptop, transfer: id));
      s.coordinator.cancelIncoming(s.sid);
      expect(s.incoming, isNull);
      expect(s.coordinator.busy, isFalse);
      expect(
        s.coordinator.lastReceived?.outcome,
        TransferOutcome.cancelledHere,
      );
      final wait = await s.wait(laptop, id);
      expectState(wait, cancelled);
      expect(wait!.text, isNot(contains(permit)));
      expect(s.events, isEmpty);
    });

    test('it does nothing with the warning open', () async {
      final s = await stack();
      expectWaiting(await s.offer(portatil));
      s.coordinator.cancelIncoming(s.sid);
      expect(s.incoming?.stage, IncomingStage.warning);
      expect(s.coordinator.lastReceived, isNull);
    });
  });

  group('A18 tick', () {
    test('an accepted session without upload ends at 30 s', () async {
      final s = await stack();
      final id = newTransferId();
      expectAccepted(await s.offer(laptop, transfer: id));
      s.clock.advance(const Duration(seconds: 29, milliseconds: 900));
      await settle();
      expect(s.incoming?.stage, IncomingStage.waitingData);
      s.clock.advance(const Duration(milliseconds: 100));
      await eventually(() => s.incoming == null, reason: 'permit expired');
      expect(
        s.coordinator.lastReceived?.outcome,
        TransferOutcome.uploadNotStarted,
      );
      expectState(await s.wait(laptop, id), {
        'state': 'failed',
        'reason': 'upload_not_started',
      });
    });

    test(
      'records of ended sessions answer for 30 s and then are gone',
      () async {
        final s = await stack();
        final id = newTransferId();
        expectWaiting(await s.offer(portatil, transfer: id));
        s.coordinator.answerWarning(s.sid, accept: false);
        s.clock.advance(const Duration(seconds: 29, milliseconds: 900));
        expectState(await s.wait(portatil, id), declined);
        expectState(await s.cancel(portatil, id), declined);
        s.clock.advance(const Duration(milliseconds: 100));
        await settle();
        expectError(await s.wait(portatil, id), 404, 'not_found');
      },
    );

    test('a tombstone lasts 30 s', () async {
      final s = await stack();
      final id = newTransferId();
      expectState(await s.cancel(laptop, id), cancelled);
      s.clock.advance(const Duration(seconds: 29, milliseconds: 900));
      expectError(await s.offer(laptop, transfer: id), 410, 'cancelled');
      s.clock.advance(const Duration(milliseconds: 100));
      await settle();
      expectError(await s.wait(laptop, id), 404, 'not_found');
      expectAccepted(await s.offer(laptop, transfer: id));
    });

    test('wait for an id that never existed is not_found', () async {
      final s = await stack();
      expectError(await s.wait(laptop, newTransferId()), 404, 'not_found');
      final bad = await s.post(laptop.identity, ApiPaths.transferWait, {
        'transfer': 'X',
      });
      expectError(bad, 400, 'incompatible');
      final badCancel = await s.post(laptop.identity, ApiPaths.transferCancel, {
        'transfer': newTransferId(),
        'reason': 'later',
      });
      expectError(badCancel, 400, 'incompatible');
    });
  });

  group('E158 RF-233 the sender disappears', () {
    test('no wait for 20 s withdraws the warning with the notice', () async {
      final s = await stack();
      final before = await declinedBefore(s, tablet);
      final id = newTransferId();
      expectWaiting(await s.offer(portatil, transfer: id));
      s.clock.advance(const Duration(seconds: 19, milliseconds: 900));
      await settle();
      expect(s.incoming?.stage, IncomingStage.warning);
      expect(s.events, isEmpty);

      s.clock.advance(const Duration(milliseconds: 100));
      await eventually(() => s.incoming == null, reason: 'withdrawn');
      final event = s.events.single as PeerCancelledTransfer;
      expect(event.peerFingerprint, portatil.fingerprint);
      expect(event.peerName, 'PORTATIL');
      expect(identical(s.coordinator.lastReceived, before), isTrue);
      expect(s.coordinator.busy, isFalse);

      expectState(await s.wait(portatil, id), cancelled);
    });

    test('a held wait keeps the warning alive past 20 s', () async {
      final s = await stack(pollHold: const Duration(seconds: 2));
      final id = newTransferId();
      expectWaiting(await s.offer(portatil, transfer: id));
      final held = s.wait(portatil, id);
      await eventually(() => s.handledOn(ApiPaths.transferWait) == 1);
      s.clock.advance(const Duration(seconds: 25));
      await settle(const Duration(milliseconds: 300));
      expect(s.incoming?.stage, IncomingStage.warning);
      expect(s.events, isEmpty);
      expect((await held)?.json, {'state': 'waiting', 'picker': false});
    });

    test(
      'an offer whose sender left while checking is dropped in silence',
      () async {
        final gate = Completer<void>();
        final s = await stack(configure: (p) => p.volumeGate = gate);
        s.sampleViews();
        final id = newTransferId();
        final client = await TlsClient.connect(
          s.port,
          serverFingerprint: receiver.fingerprint,
          context: portatil.identity.clientContext(presentCertificate: true),
        );
        client.write(
          httpRequest(
            'POST',
            ApiPaths.transferOffer,
            body: utf8.encode(jsonEncode(s.offerBody(transfer: id))),
            headers: const {'content-type': 'application/json; charset=utf-8'},
          ),
        );
        await eventually(() => s.platform.volumeCalls > 0, reason: 'checking');
        client.socket.destroy();
        await settle(const Duration(milliseconds: 200));
        gate.complete();
        await eventually(
          () => !s.coordinator.busy,
          reason: 'session dropped',
          limit: const Duration(seconds: 10),
        );
        await settle();

        expect(s.seen, isEmpty, reason: 'no card may ever be shown');
        expect(s.events, isEmpty, reason: 'nothing was shown, so no notice');
        expect(s.coordinator.lastReceived, isNull);
        expectState(await s.wait(portatil, id), cancelled);
      },
    );

    test('an undelivered wait reply withdraws the open warning', () async {
      final s = await stack(pollHold: const Duration(milliseconds: 600));
      final id = newTransferId();
      expectWaiting(await s.offer(portatil, transfer: id));
      final client = await TlsClient.connect(
        s.port,
        serverFingerprint: receiver.fingerprint,
        context: portatil.identity.clientContext(presentCertificate: true),
      );
      client.write(
        httpRequest(
          'POST',
          ApiPaths.transferWait,
          body: utf8.encode(jsonEncode({'transfer': id})),
          headers: const {'content-type': 'application/json; charset=utf-8'},
        ),
      );
      await eventually(() => s.handledOn(ApiPaths.transferWait) == 1);
      client.socket.destroy();
      await eventually(
        () => s.incoming == null,
        reason: 'withdrawn',
        limit: const Duration(seconds: 10),
      );
      expect(s.events.single, isA<PeerCancelledTransfer>());
      expect(s.coordinator.lastReceived, isNull);
      expectState(await s.wait(portatil, id), cancelled);
    });
  });

  group('E101 RF-240 what counts as the last reception', () {
    test(
      'silent step 1 rejections never count; a shown warning does',
      () async {
        final s = await stack();
        final tombstone = newTransferId();
        expectState(await s.cancel(laptop, tombstone), cancelled);
        expectError(
          await s.offer(laptop, transfer: tombstone),
          410,
          'cancelled',
        );
        expectError(await s.offer(laptop, name: 'CON'), 422, 'invalid_name');
        expectError(await s.offer(laptop, name: 'x.lnk'), 415, 'blocked_type');
        expectError(
          await s.post(laptop.identity, ApiPaths.transferOffer, {'a': 1}),
          400,
          'incompatible',
        );
        expect(s.coordinator.lastReceived, isNull);
        expect(s.views, isEmpty);

        expectWaiting(await s.offer(portatil));
        expect(s.coordinator.lastReceived, isNull);
        s.coordinator.answerWarning(s.sid, accept: false);
        final shown = s.coordinator.lastReceived;
        expect(shown?.outcome, TransferOutcome.declined);
        expect(shown?.peerFingerprint, portatil.fingerprint);

        expectError(await s.offer(portatil), 403, 'declined');
        expectWaiting(await s.offer(tablet));
        expectError(await s.offer(phone), 409, 'busy');
        expect(identical(s.coordinator.lastReceived, shown), isTrue);

        s.coordinator.answerWarning(s.sid, accept: true);
        expect(s.incoming?.stage, IncomingStage.waitingData);
        s.coordinator.cancelIncoming(s.sid);
        expect(
          s.coordinator.lastReceived?.outcome,
          TransferOutcome.cancelledHere,
        );
        expect(s.coordinator.lastReceived?.peerName, 'Tablet');
      },
    );
  });

  group('E162 [SEG] records are bounded', () {
    test(
      '300 cancels with random ids keep 16 for that device and spare others',
      () async {
        final s = await stack();
        final other = newTransferId();
        expectState(await s.cancel(tablet, other), cancelled);

        final ids = [for (var i = 0; i < 300; i++) newTransferId()];
        for (var i = 0; i < ids.length; i += 6) {
          final replies = await Future.wait([
            for (final id in ids.skip(i).take(6)) s.cancel(portatil, id),
          ]);
          for (final reply in replies) {
            expectState(reply, cancelled);
          }
        }

        final wait = s.coordinator.routes.firstWhere(
          (r) => r.path == ApiPaths.transferWait,
        );
        var kept = 0;
        for (final id in ids) {
          final reply = await wait.handle(
            callFrom(portatil, ApiPaths.transferWait, {'transfer': id}),
          );
          if (reply.status == 200) {
            kept++;
            expect(reply.json, cancelled);
          } else {
            expect(reply.status, 404);
          }
        }
        expect(kept, Limits.transferMaxRecordsPerPeer);

        expectState(await s.wait(tablet, other), cancelled);
        expectError(await s.offer(tablet, transfer: other), 410, 'cancelled');
      },
      timeout: const Timeout(Duration(minutes: 3)),
    );

    test('20 devices with 20 cancels each keep at most 256 in total', () async {
      final peers = [
        for (var i = 0; i < 20; i++)
          Peer(DeviceIdentity.generate(), name: 'P$i'),
      ];
      final s = await ReceiverStack.start(identity: receiver, peers: peers);
      final idsOf = <Peer, List<String>>{};
      for (final peer in peers) {
        final ids = [for (var i = 0; i < 20; i++) newTransferId()];
        idsOf[peer] = ids;
        for (var i = 0; i < ids.length; i += 6) {
          final replies = await Future.wait([
            for (final id in ids.skip(i).take(6)) s.cancel(peer, id),
          ]);
          for (final reply in replies) {
            expectState(reply, cancelled);
          }
        }
      }
      final wait = s.coordinator.routes.firstWhere(
        (r) => r.path == ApiPaths.transferWait,
      );
      var total = 0;
      final keptBy = <int>[];
      for (final peer in peers) {
        var kept = 0;
        for (final id in idsOf[peer]!) {
          final reply = await wait.handle(
            callFrom(peer, ApiPaths.transferWait, {'transfer': id}),
          );
          if (reply.status == 200) kept++;
        }
        expect(kept, lessThanOrEqualTo(Limits.transferMaxRecordsPerPeer));
        keptBy.add(kept);
        total += kept;
      }
      expect(total, Limits.transferMaxRecordsTotal);
      expect(keptBy.last, Limits.transferMaxRecordsPerPeer);
      expect(keptBy.first, 0);
    }, timeout: const Timeout(Duration(minutes: 3)));
  });

  group('RF-233 nothing is shown until the offer reply is delivered', () {
    Future<ApiReply> decide(ReceiverStack s, Peer peer, String id) {
      final offer = s.coordinator.routes.firstWhere(
        (r) => r.path == ApiPaths.transferOffer,
      );
      return offer.handle(
        callFrom(peer, ApiPaths.transferOffer, s.offerBody(transfer: id)),
      );
    }

    test(
      'a decided warning stays hidden until the reply is delivered',
      () async {
        final s = await stack();
        s.sampleViews();
        final id = newTransferId();
        final reply = await decide(s, portatil, id);
        expect(reply.status, 202);
        expect(reply.afterResponse, isNotNull);
        expect(reply.onUndelivered, isNotNull);
        await settle();
        expect(s.incoming, isNull);
        expect(s.seen, isEmpty);
        expect(s.views.whereType<IncomingTransferView>(), isEmpty);
        expect(s.coordinator.busy, isTrue);
        expectError(await s.offer(tablet), 409, 'busy');

        s.coordinator.answerWarning(s.sid, accept: false);
        s.coordinator.answerWarning(s.sid, accept: true);
        s.coordinator.cancelIncoming(s.sid);
        expect(s.coordinator.busy, isTrue);
        expect(s.coordinator.lastReceived, isNull);

        s.clock.advance(const Duration(seconds: 5));
        await reply.afterResponse!();
        expect(s.incoming?.stage, IncomingStage.warning);
        expect(s.incoming?.peerName, 'PORTATIL');

        await s.advanceWithPolls(
          portatil,
          id,
          const Duration(seconds: 59, milliseconds: 900),
        );
        await settle();
        expect(s.incoming?.stage, IncomingStage.warning);

        s.coordinator.answerWarning(s.sid, accept: false);
        expect(s.coordinator.lastReceived?.outcome, TransferOutcome.declined);
        expectError(await s.offer(portatil), 403, 'declined');
      },
    );

    test('an undelivered warning ends in silence and does not block', () async {
      final s = await stack();
      s.sampleViews();
      final id = newTransferId();
      final reply = await decide(s, portatil, id);
      expect(reply.status, 202);
      reply.onUndelivered!();
      await reply.afterResponse!();
      await settle();
      expect(s.incoming, isNull);
      expect(s.seen, isEmpty);
      expect(s.views.whereType<IncomingTransferView>(), isEmpty);
      expect(s.events, isEmpty);
      expect(s.coordinator.lastReceived, isNull);
      expect(s.coordinator.busy, isFalse);
      expectState(await s.wait(portatil, id), cancelled);
      expectWaiting(await s.offer(portatil));
    });

    test(
      'an own device whose acceptance is not delivered keeps no permit',
      () async {
        final s = await stack();
        final before = await declinedBefore(s, tablet);
        s.sampleViews();
        s.seen.clear();
        final id = newTransferId();
        final reply = await decide(s, laptop, id);
        expect(reply.status, 200);
        final permit = reply.json['permit'] as String;
        expect(permit, matches(hex32));
        expect(s.incoming, isNull);

        reply.onUndelivered!();
        await reply.afterResponse!();
        await settle();
        expect(s.incoming, isNull);
        expect(s.seen, isEmpty);
        expect(s.events, isEmpty);
        expect(identical(s.coordinator.lastReceived, before), isTrue);
        expect(s.coordinator.busy, isFalse);
        final wait = await s.wait(laptop, id);
        expectState(wait, cancelled);
        expect(wait!.text, isNot(contains(permit)));
        expect(s.logs.join('\n'), isNot(contains(permit)));
        expectAccepted(await s.offer(laptop));
      },
    );

    test('a decision never delivered is dropped in silence at 10 s', () async {
      final s = await stack();
      s.sampleViews();
      final warned = newTransferId();
      final reply = await decide(s, portatil, warned);
      expect(reply.status, 202);
      s.clock.advance(const Duration(seconds: 9, milliseconds: 900));
      await settle();
      expect(s.coordinator.busy, isTrue);
      expect(s.incoming, isNull);
      s.clock.advance(const Duration(milliseconds: 100));
      await eventually(() => !s.coordinator.busy, reason: 'safety net');
      await reply.afterResponse!();
      await settle();
      expect(s.incoming, isNull);
      expect(s.seen, isEmpty);
      expect(s.events, isEmpty);
      expect(s.coordinator.lastReceived, isNull);
      expectState(await s.wait(portatil, warned), cancelled);

      final accepted = newTransferId();
      final acceptance = await decide(s, laptop, accepted);
      expect(acceptance.status, 200);
      s.clock.advance(Limits.transferMessageTimeout);
      await eventually(() => !s.coordinator.busy, reason: 'safety net');
      expect(s.events, isEmpty);
      expect(s.coordinator.lastReceived, isNull);
      expectState(await s.wait(laptop, accepted), cancelled);
    });

    test(
      'an accepted session hidden until delivery counts its 30 s from then',
      () async {
        final s = await stack();
        final id = newTransferId();
        final reply = await decide(s, laptop, id);
        s.clock.advance(const Duration(seconds: 9));
        await reply.afterResponse!();
        expect(s.incoming?.stage, IncomingStage.waitingData);
        s.clock.advance(const Duration(seconds: 29, milliseconds: 900));
        await settle();
        expect(s.incoming?.stage, IncomingStage.waitingData);
        s.clock.advance(const Duration(milliseconds: 100));
        await eventually(() => s.incoming == null, reason: 'permit expired');
        expect(
          s.coordinator.lastReceived?.outcome,
          TransferOutcome.uploadNotStarted,
        );
      },
    );

    test('an undelivered reply after the card was shown withdraws it with the notice', () async {
      final s = await stack();
      final reply = await decide(s, portatil, newTransferId());
      await reply.afterResponse!();
      expect(s.incoming?.stage, IncomingStage.warning);
      reply.onUndelivered!();
      expect(s.incoming, isNull);
      await settle();
      expect(s.events.single, isA<PeerCancelledTransfer>());
      expect(s.coordinator.lastReceived, isNull);
    });
  });

  group('A24 close() for the incoming side without upload', () {
    test(
      'close with the warning open declines it and wakes the held wait',
      () async {
        final tracker = TimerTracker();
        await runZoned(() async {
          final s = await stack(pollHold: const Duration(seconds: 8));
          final id = newTransferId();
          expectWaiting(await s.offer(portatil, transfer: id));
          final held = s.wait(portatil, id);
          await eventually(() => s.handledOn(ApiPaths.transferWait) == 1);
          await settle();
          expect(tracker.activeBy('src/transfer/'), greaterThanOrEqualTo(2));

          final stopwatch = Stopwatch()..start();
          await s.coordinator.close();
          expect(stopwatch.elapsed, lessThan(const Duration(seconds: 4)));
          expectState(await held, declined);
          expect(stopwatch.elapsed, lessThan(const Duration(seconds: 4)));
          expect(s.coordinator.lastReceived?.outcome, TransferOutcome.declined);
          expect(s.incoming, isNull);
          expect(s.coordinator.busy, isFalse);
          expect(s.events, isEmpty);

          final late = await s.offer(laptop);
          if (late != null) expectError(late, 503, 'busy');
          await settle();
          expect(tracker.createdBy('src/transfer/'), greaterThanOrEqualTo(2));
          expect(tracker.activeBy('src/transfer/'), 0);
          await s.coordinator.close();
        }, zoneSpecification: tracker.specification);
      },
    );

    test('close with the folder question open ends it as no folder', () async {
      final s = await stack(
        remembered: false,
        pollHold: const Duration(seconds: 8),
      );
      final id = newTransferId();
      expectWaiting(await s.offer(laptop, transfer: id));
      expect(s.incoming?.stage, IncomingStage.folderQuestion);
      final held = s.wait(laptop, id);
      await eventually(() => s.handledOn(ApiPaths.transferWait) == 1);
      await settle();
      await s.coordinator.close();
      expectState(await held, {'state': 'rejected', 'reason': 'no_folder'});
      expect(s.coordinator.lastReceived?.outcome, TransferOutcome.noFolder);
      expect(s.store.saved, isEmpty);
    });

    test('close with an accepted session ends it as cancelled here', () async {
      final s = await stack();
      expectAccepted(await s.offer(laptop));
      await s.coordinator.close();
      expect(
        s.coordinator.lastReceived?.outcome,
        TransferOutcome.cancelledHere,
      );
      expect(s.coordinator.busy, isFalse);
    });

    test('close while checking ends the offer in silence', () async {
      final gate = Completer<void>();
      final s = await stack(configure: (p) => p.volumeGate = gate);
      s.sampleViews();
      final pending = s.offer(portatil);
      await eventually(() => s.platform.volumeCalls > 0, reason: 'checking');
      await s.coordinator.close();
      gate.complete();
      final reply = await pending;
      expect(reply?.status, isNot(anyOf(200, 202)));
      await settle();
      expect(s.seen, isEmpty);
      expect(s.coordinator.lastReceived, isNull);
      expect(s.events, isEmpty);
    });

    test('close twice and the streams finish', () async {
      final s = await stack();
      var changesDone = false;
      var eventsDone = false;
      s.coordinator.changes.listen(null, onDone: () => changesDone = true);
      s.coordinator.events.listen(null, onDone: () => eventsDone = true);
      await s.coordinator.close();
      await s.coordinator.close();
      await settle();
      expect(changesDone, isTrue);
      expect(eventsDone, isTrue);
    });
  });

  group('[SEG] RF-197 nothing secret in the logs', () {
    test('the logs never carry a permit, a folder or a file name', () async {
      final s = await stack(
        configure: (p) => p.dangerous = (_) => Future.error(StateError('x')),
      );
      final permits = <String>[];
      for (var i = 0; i < 5; i++) {
        final id = newTransferId();
        permits.add(
          expectAccepted(
            await s.offer(laptop, transfer: id, name: 'nb-t6-$i.chm'),
          ),
        );
        await s.cancel(
          laptop,
          id,
          reason: i.isEven ? 'cancelled' : 'no_contact',
        );
      }
      final joined = s.logs.join('\n');
      for (final permit in permits) {
        expect(joined, isNot(contains(permit)));
      }
      expect(joined, isNot(contains(s.base)));
      expect(joined, isNot(contains('nb-t6-')));
    });
  });

  group('E198 M1 the warning answer is bound to the session it was shown '
      'for', () {
    test(
      'the id of an earlier session of another device does nothing',
      () async {
        final s = await stack();
        final first = newTransferId();
        expectWaiting(await s.offer(tablet, transfer: first));
        final old = s.sid;
        expect(old, matches(hex32));
        expectState(await s.cancel(tablet, first), cancelled);
        expect(s.incoming, isNull);

        final id = newTransferId();
        expectWaiting(await s.offer(portatil, transfer: id));
        final view = s.incoming!;
        expect(view.sessionId, isNot(old));
        s.coordinator.answerWarning(old, accept: true);
        expect(s.incoming, view);
        s.coordinator.answerWarning(old, accept: false);
        expect(s.incoming, view);
        expect(s.coordinator.busy, isTrue);
        expect(s.coordinator.lastReceived, isNull);
        expectState(await s.wait(portatil, id), waiting);

        s.coordinator.answerWarning(view.sessionId, accept: true);
        expect(s.incoming?.stage, IncomingStage.waitingData);
        expect(s.incoming?.sessionId, view.sessionId);
        expectAccepted(await s.wait(portatil, id));
      },
    );

    test(
      'the id of an earlier session of the same device does nothing',
      () async {
        final s = await stack();
        final first = newTransferId();
        expectWaiting(await s.offer(portatil, transfer: first));
        final old = s.sid;
        expectState(await s.cancel(portatil, first), cancelled);
        s.clock.advance(const Duration(seconds: 60));

        final id = newTransferId();
        expectWaiting(await s.offer(portatil, transfer: id));
        final view = s.incoming!;
        expect(view.sessionId, isNot(old));
        s.coordinator.answerWarning(old, accept: false);
        expect(s.incoming, view);
        expect(s.coordinator.lastReceived, isNull);
        expectState(await s.wait(portatil, id), waiting);
        s.coordinator.answerWarning(old, accept: true);
        expect(s.incoming, view);
        expectState(await s.wait(portatil, id), waiting);

        s.coordinator.answerWarning(view.sessionId, accept: false);
        expect(s.incoming, isNull);
        expect(s.coordinator.lastReceived?.outcome, TransferOutcome.declined);
        expectState(await s.wait(portatil, id), declined);
      },
    );

    test('an empty, made up or look-alike id does nothing', () async {
      final s = await stack();
      final id = newTransferId();
      expectWaiting(await s.offer(portatil, transfer: id));
      final view = s.incoming!;
      final sid = view.sessionId;
      final fakes = <String>[
        '',
        newTransferId(),
        id,
        sid.toUpperCase(),
        ' $sid',
        '$sid ',
        sid.substring(1),
        '${sid.substring(0, 31)}${sid.endsWith('0') ? '1' : '0'}',
        '$sid$sid',
      ].where((fake) => fake != sid);
      for (final fake in fakes) {
        s.coordinator.answerWarning(fake, accept: true);
        s.coordinator.answerWarning(fake, accept: false);
        expect(s.incoming, view, reason: fake);
      }
      expect(s.coordinator.lastReceived, isNull);
      expectState(await s.wait(portatil, id), waiting);

      s.coordinator.answerWarning(sid, accept: true);
      expect(s.incoming?.stage, IncomingStage.waitingData);
      expectAccepted(await s.wait(portatil, id));
    });
  });

  group('E200 M1 the session id', () {
    test('it is 32 lowercase hex, stays the same through the warning, the '
        'question and the acceptance, and never leaves the receiver', () async {
      final s = await stack(remembered: false);
      s.sampleViews();
      final id = newTransferId();
      final offer = await s.offer(portatil, transfer: id);
      expectWaiting(offer);
      final sid = s.sid;
      expect(sid, matches(hex32));
      expect(sid, isNot(id));
      expect(s.incoming?.stage, IncomingStage.warning);

      s.coordinator.answerWarning(sid, accept: true);
      expect(s.incoming?.stage, IncomingStage.folderQuestion);
      expect(s.sid, sid);
      final asking = await s.wait(portatil, id);
      expectState(asking, waiting);

      await s.coordinator.useProposedFolder(sid);
      await eventually(
        () => s.incoming?.stage == IncomingStage.waitingData,
        reason: 'accepted',
      );
      expect(s.sid, sid);
      final accepted = await s.wait(portatil, id);
      final permit = expectAccepted(accepted);
      expect(permit, isNot(sid));

      for (final reply in [offer!, asking!, accepted!]) {
        expect(reply.text, isNot(contains(sid)));
      }
      await settle();
      expect(s.seen, isNotEmpty);
      expect(s.seen.map((v) => v.sessionId).toSet(), {sid});
      expect(s.logs.join('\n'), isNot(contains(sid)));
    });

    test('each session has its own id and two views that differ only in it '
        'are different', () async {
      final s = await stack();
      final views = <IncomingTransferView>[];
      for (var i = 0; i < 20; i++) {
        final id = newTransferId();
        expectAccepted(await s.offer(laptop, transfer: id));
        final view = s.incoming!;
        expect(view.sessionId, isNot(id));
        expect(s.incoming, view);
        expect(s.incoming!.hashCode, view.hashCode);
        views.add(view);
        s.coordinator.cancelIncoming(view.sessionId);
        expect(s.incoming, isNull);
      }
      expect(views.map((v) => v.sessionId).toSet(), hasLength(20));
      for (final view in views) {
        expect(view.sessionId, matches(hex32));
      }

      final a = views[0];
      final b = views[1];
      expect(a == b, isFalse);
      expect(a.hashCode, isNot(b.hashCode));
      final rebuilt = IncomingTransferView(
        sessionId: a.sessionId,
        peerFingerprint: b.peerFingerprint,
        peerName: b.peerName,
        fileName: b.fileName,
        size: b.size,
        isProgram: b.isProgram,
        stage: b.stage,
        withoutMark: b.withoutMark,
        folder: b.folder,
        receivedBytes: b.receivedBytes,
      );
      expect(rebuilt, a);
      expect(rebuilt.hashCode, a.hashCode);
    });
  });

  group('E201 M2 a foreign sender that withdraws a warning already seen', () {
    test('a cancel blocks it for one minute like a rejection, once, without '
        'counting as the last reception and without blocking others', () async {
      final s = await stack();
      final id = newTransferId();
      expectWaiting(await s.offer(portatil, transfer: id));
      expect(s.incoming?.stage, IncomingStage.warning);

      expectState(await s.cancel(portatil, id), cancelled);
      expect(s.incoming, isNull);
      expect(s.coordinator.busy, isFalse);
      expect(s.events, hasLength(1));
      final event = s.events.single as PeerCancelledTransfer;
      expect(event.peerFingerprint, portatil.fingerprint);
      expect(s.coordinator.lastReceived, isNull);
      final changes = s.views.length;

      expectError(await s.offer(portatil), 403, 'declined');
      expectError(await s.offer(portatil, name: 'otro.txt'), 403, 'declined');
      expect(s.views.length, changes);
      expect(s.incoming, isNull);
      expect(s.coordinator.lastReceived, isNull);
      expect(s.events, hasLength(1));

      expectWaiting(await s.offer(tablet));
      expect(s.incoming?.peerFingerprint, tablet.fingerprint);
      s.coordinator.answerWarning(s.sid, accept: true);
      s.coordinator.cancelIncoming(s.sid);
      expectAccepted(await s.offer(laptop));
      s.coordinator.cancelIncoming(s.sid);

      s.clock.advance(const Duration(seconds: 59, milliseconds: 900));
      expectError(await s.offer(portatil), 403, 'declined');
      s.clock.advance(const Duration(milliseconds: 100));
      expectWaiting(await s.offer(portatil));
      expect(s.incoming?.stage, IncomingStage.warning);
      expect(s.events, hasLength(1));
    });

    test('a device turned foreign before the warning blocks itself when it '
        'cancels', () async {
      final s = await stack(remembered: false);
      final id = newTransferId();
      expectWaiting(await s.offer(laptop, transfer: id));
      expect(s.incoming?.stage, IncomingStage.folderQuestion);
      expect(
        await s.paired.setRelation(laptop.fingerprint, PeerRelation.foreign),
        isTrue,
      );
      await s.coordinator.useProposedFolder(s.sid);
      await eventually(
        () => s.incoming?.stage == IncomingStage.warning,
        reason: 'warning after the folder',
      );
      expectState(await s.cancel(laptop, id), cancelled);
      expectError(await s.offer(laptop), 403, 'declined');
    });
  });

  group('E202 M2 the other ways a seen warning is withdrawn', () {
    test('20 s without polls blocks it the same way', () async {
      final s = await stack();
      expectWaiting(await s.offer(portatil));
      s.clock.advance(Limits.transferPollGap);
      await eventually(() => s.incoming == null, reason: 'withdrawn');
      expect(s.events.single, isA<PeerCancelledTransfer>());
      expect(s.coordinator.lastReceived, isNull);

      expectError(await s.offer(portatil), 403, 'declined');
      expectWaiting(await s.offer(tablet));
      s.coordinator.answerWarning(s.sid, accept: true);
      s.coordinator.cancelIncoming(s.sid);

      s.clock.advance(const Duration(seconds: 59, milliseconds: 900));
      expectError(await s.offer(portatil), 403, 'declined');
      s.clock.advance(const Duration(milliseconds: 100));
      expectWaiting(await s.offer(portatil));
      expect(s.events, hasLength(1));
    });

    test('an offer reply lost after the warning was shown blocks it the same '
        'way', () async {
      final s = await stack();
      final reply = await _offerByHand(s, portatil, newTransferId());
      expect(reply.status, 202);
      await reply.afterResponse!();
      expect(s.incoming?.stage, IncomingStage.warning);
      reply.onUndelivered!();
      expect(s.incoming, isNull);
      await settle();
      expect(s.events.single, isA<PeerCancelledTransfer>());
      expect(s.coordinator.lastReceived, isNull);

      expectError(await s.offer(portatil), 403, 'declined');
      expectWaiting(await s.offer(tablet));
      s.coordinator.answerWarning(s.sid, accept: true);
      s.coordinator.cancelIncoming(s.sid);
      s.clock.advance(const Duration(seconds: 60));
      expectWaiting(await s.offer(portatil));
    });

    test('a wait reply lost with the warning open blocks it the same '
        'way', () async {
      final s = await stack(pollHold: const Duration(milliseconds: 600));
      final id = newTransferId();
      expectWaiting(await s.offer(portatil, transfer: id));
      final client = await TlsClient.connect(
        s.port,
        serverFingerprint: receiver.fingerprint,
        context: portatil.identity.clientContext(presentCertificate: true),
      );
      client.write(
        httpRequest(
          'POST',
          ApiPaths.transferWait,
          body: utf8.encode(jsonEncode({'transfer': id})),
          headers: const {'content-type': 'application/json; charset=utf-8'},
        ),
      );
      await eventually(() => s.handledOn(ApiPaths.transferWait) == 1);
      client.socket.destroy();
      await eventually(
        () => s.incoming == null,
        reason: 'withdrawn',
        limit: const Duration(seconds: 10),
      );
      expect(s.events.single, isA<PeerCancelledTransfer>());
      expectError(await s.offer(portatil), 403, 'declined');
      s.clock.advance(const Duration(seconds: 60));
      expectWaiting(await s.offer(portatil));
    });

    test('a no_contact cancel with the warning open blocks it the same '
        'way', () async {
      final s = await stack();
      final id = newTransferId();
      expectWaiting(await s.offer(portatil, transfer: id));
      expectState(
        await s.cancel(portatil, id, reason: 'no_contact'),
        cancelled,
      );
      expect(s.events.single, isA<PeerCancelledTransfer>());
      expectError(await s.offer(portatil), 403, 'declined');
    });
  });

  group('E203 M2 withdrawals that do not block', () {
    test('an own device that cancels the question or the acceptance', () async {
      final s = await stack(remembered: false);
      final asked = newTransferId();
      expectWaiting(await s.offer(laptop, transfer: asked));
      expect(s.incoming?.stage, IncomingStage.folderQuestion);
      expectState(await s.cancel(laptop, asked), cancelled);
      expectWaiting(await s.offer(laptop));
      await s.coordinator.useProposedFolder(s.sid);
      await eventually(
        () => s.incoming?.stage == IncomingStage.waitingData,
        reason: 'accepted',
      );
      final id = newTransferId();
      s.coordinator.cancelIncoming(s.sid);
      expectAccepted(await s.offer(laptop, transfer: id));
      expectState(await s.cancel(laptop, id), cancelled);
      expectAccepted(await s.offer(laptop));
    });

    test('a foreign device turned own before it cancels the warning is not '
        'blocked', () async {
      final s = await stack();
      final id = newTransferId();
      expectWaiting(await s.offer(portatil, transfer: id));
      expect(
        await s.paired.setRelation(portatil.fingerprint, PeerRelation.mine),
        isTrue,
      );
      expectState(await s.cancel(portatil, id), cancelled);
      expect(
        await s.paired.setRelation(portatil.fingerprint, PeerRelation.foreign),
        isTrue,
      );
      expectWaiting(await s.offer(portatil));
    });

    test('a foreign device that cancels while it is being checked', () async {
      final gate = Completer<void>();
      final s = await stack(configure: (p) => p.volumeGate = gate);
      final id = newTransferId();
      final pending = s.offer(portatil, transfer: id);
      await eventually(() => s.platform.volumeCalls > 0, reason: 'checking');
      expectState(await s.cancel(portatil, id), cancelled);
      gate.complete();
      expectError(await pending, 410, 'cancelled');
      expect(s.events, isEmpty);
      expectWaiting(await s.offer(portatil));
    });

    test(
      'a foreign device that cancels with the folder question open',
      () async {
        final s = await stack(remembered: false);
        final id = newTransferId();
        expectWaiting(await s.offer(portatil, transfer: id));
        s.coordinator.answerWarning(s.sid, accept: true);
        expect(s.incoming?.stage, IncomingStage.folderQuestion);
        expectState(await s.cancel(portatil, id), cancelled);
        expect(s.events.single, isA<PeerCancelledTransfer>());
        expectWaiting(await s.offer(portatil));
      },
    );

    test('a foreign device that cancels once accepted, with either '
        'reason', () async {
      final s = await stack();
      for (final reason in ['cancelled', 'no_contact']) {
        final id = newTransferId();
        expectWaiting(await s.offer(portatil, transfer: id));
        s.coordinator.answerWarning(s.sid, accept: true);
        expect(s.incoming?.stage, IncomingStage.waitingData, reason: reason);
        expect((await s.cancel(portatil, id, reason: reason))?.status, 200);
        expect(s.incoming, isNull, reason: reason);
      }
      expectWaiting(await s.offer(portatil));
    });

    test('a warning that expires at 60 s', () async {
      final s = await stack();
      final id = newTransferId();
      expectWaiting(await s.offer(portatil, transfer: id));
      await s.advanceWithPolls(portatil, id, Limits.transferPromptTimeout);
      await eventually(() => s.incoming == null, reason: 'warning expired');
      expect(s.coordinator.lastReceived?.outcome, TransferOutcome.unanswered);
      expect((await s.cancel(portatil, id))?.status, 200);
      expectWaiting(await s.offer(portatil));
    });

    test('a device unpaired with its warning open', () async {
      final s = await stack();
      final id = newTransferId();
      expectWaiting(await s.offer(portatil, transfer: id));
      final sid = s.sid;
      expect(await s.paired.remove(portatil.fingerprint), isTrue);
      s.coordinator.answerWarning(sid, accept: true);
      expect(s.incoming, isNull);
      expect(s.coordinator.lastReceived?.outcome, TransferOutcome.unpaired);
      expect(s.events, isEmpty);
      await s.pairWith([portatil]);
      expectWaiting(await s.offer(portatil));
    });
  });
}

Future<ApiReply> _offerByHand(ReceiverStack s, Peer peer, String id) {
  final offer = s.coordinator.routes.firstWhere(
    (r) => r.path == ApiPaths.transferOffer,
  );
  return offer.handle(
    callFrom(peer, ApiPaths.transferOffer, s.offerBody(transfer: id)),
  );
}

final class _FailingStore implements ReceiveFolderStore {
  @override
  Future<ReceiveFolder?> load() => Future.error(
    const FileSystemException(
      'cannot read',
      r'C:\Users\someone\nb-hidden-folder',
    ),
  );

  @override
  Future<bool> save(ReceiveFolder folder) async => false;
}
