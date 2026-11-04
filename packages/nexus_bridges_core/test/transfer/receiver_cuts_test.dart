@TestOn('windows')
library;

import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:nexus_bridges_core/src/identity/identity.dart';
import 'package:nexus_bridges_core/src/pairing/pairing.dart';
import 'package:nexus_bridges_core/src/protocol/protocol.dart';
import 'package:nexus_bridges_core/src/transfer/transfer.dart';
import 'package:nexus_bridges_core/src/transport/transport.dart';
import 'package:test/test.dart';

import '../pairing_flow/receiver_harness.dart' show TimerTracker;
import '../server/api_server_harness.dart' show loopbackInterface;
import 'receiver_harness.dart';

const int kib = 1024;

const int mib = 1048576;

const String otherInterfaceId = 'other#10.0.0.1';

const Map<String, Object?> cancelledState = {'state': 'cancelled'};

const Map<String, Object?> savedState = {'state': 'saved', 'marked': true};

Map<String, Object?> failedState(String reason) => {
  'state': 'failed',
  'reason': reason,
};

Uint8List randomBytes(int length, int seed) {
  final random = Random(seed);
  final bytes = Uint8List(length);
  for (var i = 0; i < length; i++) {
    bytes[i] = random.nextInt(256);
  }
  return bytes;
}

String digestOf(List<int> bytes) => sha256.convert(bytes).toString();

Stream<List<int>> chunked(Uint8List bytes, [int size = 64 * kib]) async* {
  for (var i = 0; i < bytes.length; i += size) {
    yield Uint8List.sublistView(bytes, i, min(i + size, bytes.length));
  }
}

List<String> treeOf(String folder) => [
  for (final entity in Directory(
    folder,
  ).listSync(recursive: true, followLinks: false))
    entity.path.substring(folder.length + 1),
]..sort();

String subOf(String folder) => '$folder\\$tempFolderName';

Map<String, String> headersFor(String transfer, String? permit) => {
  TransferHeaders.transfer: transfer,
  TransferHeaders.permit: ?permit,
};

RawReply answered(StreamPostResult result) {
  if (result is StreamPostFailed) {
    fail('upload failed with ${result.failure.name} after ${result.sent}');
  }
  final response = (result as StreamPostAnswered).response;
  return RawReply(response.status, response.body);
}

void expectState(RawReply? reply, Map<String, Object?> json) {
  expect(reply, isNotNull);
  expect(reply!.status, 200, reason: reply.text);
  expect(reply.json, json);
}

void expectForbidden(RawReply reply) {
  expect(reply.status, 403, reason: reply.text);
  expect(reply.json, {'error': 'forbidden'});
}

void expectGone(RawReply? reply) {
  expect(reply, isNotNull);
  expect(reply!.status, 410, reason: reply.text);
  expect(reply.json, {'error': 'cancelled'});
}

void expectCleanLogs(ReceiverStack s, Iterable<String> permits) {
  final base = s.base.toLowerCase();
  for (final line in s.logs) {
    final lower = line.toLowerCase();
    for (final permit in permits) {
      expect(lower, isNot(contains(permit)), reason: 'permit in a log line');
    }
    expect(lower, isNot(contains(base)), reason: line);
  }
}

final class Accepted {
  Accepted(this.transfer, this.permit, this.bytes);

  final String transfer;
  final String permit;
  final Uint8List bytes;

  Map<String, String> get headers => headersFor(transfer, permit);
}

final class HeldBody {
  HeldBody() {
    addTearDown(() {
      if (!_controller.isClosed) unawaited(_controller.close());
    });
  }

  final StreamController<List<int>> _controller = StreamController<List<int>>();

  Stream<List<int>> get stream => _controller.stream;

  void sendAll(Uint8List bytes) {
    for (var i = 0; i < bytes.length; i += 64 * kib) {
      _controller.add(
        Uint8List.sublistView(bytes, i, min(i + 64 * kib, bytes.length)),
      );
    }
  }

  void finish() => unawaited(_controller.close());

  void breakOff() => _controller.addError(StateError('source closed'));
}

final class Pending<T> {
  Pending(this.future) {
    future.then(
      (value) {
        result = value;
        done = true;
      },
      onError: (Object error) {
        failure = error;
        done = true;
      },
    );
  }

  final Future<T> future;
  bool done = false;
  T? result;
  Object? failure;
}

final class MarkGate {
  MarkGate({this.marks = true}) {
    addTearDown(open);
  }

  final bool marks;
  final Completer<void> reached = Completer<void>();
  final Completer<void> _gate = Completer<void>();

  void open() {
    if (!_gate.isCompleted) _gate.complete();
  }

  Future<bool> call(String path) async {
    if (!reached.isCompleted) reached.complete();
    await _gate.future;
    return marks ? realFs.markFromInternet(path) : false;
  }
}

final class WriteGate {
  WriteGate() {
    addTearDown(open);
  }

  int calls = 0;
  final Completer<void> reached = Completer<void>();
  final Completer<void> _gate = Completer<void>();

  void open() {
    if (!_gate.isCompleted) _gate.complete();
  }

  Future<void> call(RandomAccessFile file, List<int> bytes) async {
    calls++;
    if (calls == 1) {
      reached.complete();
      await _gate.future;
    }
    await writeAllBytes(file, bytes);
  }
}

Future<void> Function(RandomAccessFile file, List<int> bytes) failingWrite(
  Object error, {
  int onCall = 1,
}) {
  var calls = 0;
  return (file, bytes) async {
    calls++;
    if (calls >= onCall) throw error;
    await writeAllBytes(file, bytes);
  };
}

FileSystemException diskFullError(int code) =>
    FileSystemException('write refused', '', OSError('disk full', code));

void main() {
  late DeviceIdentity receiver;
  late Peer laptop;
  late Peer desk;
  late Peer portatil;
  late String loopbackId;

  setUpAll(() {
    receiver = DeviceIdentity.generate();
    laptop = Peer(DeviceIdentity.generate(), name: 'Laptop');
    desk = Peer(DeviceIdentity.generate(), name: 'Sobremesa');
    portatil = Peer(
      DeviceIdentity.generate(),
      name: 'PORTATIL',
      relation: PeerRelation.foreign,
    );
    loopbackId = loopbackInterface().id;
  });

  Future<ReceiverStack> stack({
    Duration pollHold = const Duration(milliseconds: 200),
    void Function(TransferPlatform platform)? configure,
    bool remembered = true,
    Future<void> Function(RandomAccessFile file, List<int> bytes)? writeBytes,
  }) => ReceiverStack.start(
    identity: receiver,
    peers: [laptop, desk, portatil],
    pollHold: pollHold,
    configure: configure,
    remembered: remembered,
    writeBytes: writeBytes,
  );

  Future<Accepted> accept(
    ReceiverStack s,
    Peer peer,
    Uint8List bytes, {
    String name = 'informe.txt',
  }) async {
    final transfer = newTransferId();
    final reply = await s.post(
      peer.identity,
      ApiPaths.transferOffer,
      s.offerBody(
        transfer: transfer,
        name: name,
        size: bytes.length,
        sha256: digestOf(bytes),
      ),
    );
    expect(reply, isNotNull);
    expect(reply!.status, 200, reason: reply.text);
    expect(reply.state, 'accepted');
    final permit = reply.json['permit']! as String;
    await eventually(
      () => s.incoming?.stage == IncomingStage.waitingData,
      reason: 'accepted card shown',
    );
    return Accepted(transfer, permit, bytes);
  }

  Future<StreamPostResult> send(
    ReceiverStack s,
    Peer peer,
    Accepted a, {
    Uint8List? bytes,
  }) {
    final body = bytes ?? a.bytes;
    return s.postUpload(
      peer.identity,
      headers: a.headers,
      contentLength: body.length,
      body: chunked(body),
    );
  }

  Future<HeldBody> startHeld(
    ReceiverStack s,
    Peer peer,
    Accepted a,
    int firstBytes,
    void Function(Future<StreamPostResult> result) keep,
  ) async {
    final held = HeldBody();
    keep(
      s.postUpload(
        peer.identity,
        headers: a.headers,
        contentLength: a.bytes.length,
        body: held.stream,
      ),
    );
    held.sendAll(Uint8List.sublistView(a.bytes, 0, firstBytes));
    await eventually(
      () =>
          s.incoming?.stage == IncomingStage.receiving &&
          s.incoming!.receivedBytes == firstBytes,
      reason: 'first $firstBytes bytes written',
    );
    return held;
  }

  Future<void> expectNothingLeft(ReceiverStack s, String folder) async {
    await eventually(
      () => !Directory(subOf(folder)).existsSync(),
      reason: 'temporary subfolder removed',
    );
    await eventually(
      () => s.journal.folders.isEmpty,
      reason: 'journal emptied',
    );
    expect(s.coordinator.busy, isFalse);
    expect(s.incoming, isNull);
  }

  Future<void> expectEndedUpload(
    ReceiverStack s,
    Peer peer,
    Accepted a,
    Future<StreamPostResult> result,
    TransferOutcome outcome,
    Map<String, Object?> remote,
  ) async {
    await eventually(
      () => s.coordinator.lastReceived?.outcome == outcome,
      reason: 'session ended as ${outcome.name}',
    );
    expect(s.incoming, isNull);
    expect(
      await result.timeout(const Duration(seconds: 5)),
      isA<StreamPostFailed>(),
      reason: 'the upload connection is cut',
    );
    await expectNothingLeft(s, s.receiveDir);
    expect(treeOf(s.receiveDir), isEmpty);
    expectState(await s.wait(peer, a.transfer), remote);
    expectForbidden(answered(await send(s, peer, a)));
    expect(treeOf(s.receiveDir), isEmpty);
    expect(s.journal.folders, isEmpty);
    expect(s.events, isEmpty);
    expectCleanLogs(s, [a.permit]);
  }

  Future<void> expectShutOut(ReceiverStack s, Peer peer, Accepted a) async {
    final before = s.handledOn(ApiPaths.transferUpload);
    final result = await send(s, peer, a);
    if (result is StreamPostAnswered) {
      expect(result.response.status, 401);
    }
    expect(s.handledOn(ApiPaths.transferUpload), before);
    expect(treeOf(s.receiveDir), isEmpty);
  }

  Future<void> forget(ReceiverStack s, Peer peer) async {
    await s.paired.remove(peer.fingerprint);
    await s.server.rebuildTrust();
  }

  final unpairings =
      <(String, Future<void> Function(ReceiverStack s, Peer peer))>[
        (
          'peerUnpaired',
          (s, peer) => s.coordinator.peerUnpaired(peer.fingerprint),
        ),
        (
          'pairedChanged',
          (s, peer) async {
            await s.paired.remove(peer.fingerprint);
            s.coordinator.pairedChanged();
          },
        ),
      ];

  group('T10 E86 RF-161 the upload must start within 30 s', () {
    test('without an upload in 30 s the permit expires: uploadNotStarted on '
        'both sides, and a later upload gets 403 and writes nothing', () async {
      final s = await stack();
      final a = await accept(s, laptop, randomBytes(4 * kib, 86));

      s.clock.advance(const Duration(seconds: 29, milliseconds: 900));
      await settle();
      expect(s.incoming?.stage, IncomingStage.waitingData);
      s.clock.advance(const Duration(milliseconds: 100));
      await eventually(() => s.incoming == null, reason: 'permit expired');

      expect(
        s.coordinator.lastReceived?.outcome,
        TransferOutcome.uploadNotStarted,
      );
      expectState(
        await s.wait(laptop, a.transfer),
        failedState('upload_not_started'),
      );
      expectForbidden(answered(await send(s, laptop, a)));
      expect(treeOf(s.receiveDir), isEmpty);
      expect(s.journal.folders, isEmpty);
      expect(s.coordinator.busy, isFalse);
      expect(s.events, isEmpty);
      expectCleanLogs(s, [a.permit]);
    });

    test('an upload that starts at 29.9 s is not cut by the start deadline '
        'and saves', () async {
      final s = await stack();
      final a = await accept(s, laptop, randomBytes(256 * kib, 861));
      s.clock.advance(const Duration(seconds: 29, milliseconds: 900));
      late Future<StreamPostResult> result;
      final held = await startHeld(s, laptop, a, 64 * kib, (r) => result = r);

      s.clock.advance(const Duration(seconds: 5));
      await settle();
      expect(s.incoming?.stage, IncomingStage.receiving);

      held.sendAll(Uint8List.sublistView(a.bytes, 64 * kib));
      held.finish();
      expectState(answered(await result), savedState);
      expect(File('${s.receiveDir}\\informe.txt').readAsBytesSync(), a.bytes);
      await expectNothingLeft(s, s.receiveDir);
    });
  });

  group('T10 E90 RF-167 inactivity during the upload', () {
    test('half the data and then nothing for 30 s ends in idle, cuts the '
        'connection and leaves no temporary, journal entry or timer', () async {
      final tracker = TimerTracker();
      await runZoned(() async {
        final s = await stack();
        final a = await accept(s, laptop, randomBytes(512 * kib, 90));
        late Future<StreamPostResult> result;
        await startHeld(s, laptop, a, 256 * kib, (r) => result = r);
        expect(Directory(subOf(s.receiveDir)).existsSync(), isTrue);

        s.clock.advance(const Duration(seconds: 29, milliseconds: 900));
        await settle();
        expect(s.incoming?.stage, IncomingStage.receiving);
        s.clock.advance(const Duration(milliseconds: 100));

        await expectEndedUpload(
          s,
          laptop,
          a,
          result,
          TransferOutcome.idle,
          failedState('idle'),
        );

        await s.close();
        await settle();
        expect(tracker.createdBy('src/transfer/'), greaterThan(0));
        expect(tracker.activeBy('src/transfer/'), 0);
        expect(tracker.activeBy('src/server/'), 0);
        expect(tracker.activeBy('src/transport/'), 0);
      }, zoneSpecification: tracker.specification);
    });

    test('the 30 s count from the last data written, not from the start of '
        'the upload', () async {
      final s = await stack();
      final a = await accept(s, laptop, randomBytes(512 * kib, 901));
      late Future<StreamPostResult> result;
      final held = await startHeld(s, laptop, a, 64 * kib, (r) => result = r);

      s.clock.advance(const Duration(seconds: 20));
      held.sendAll(Uint8List.sublistView(a.bytes, 64 * kib, 128 * kib));
      await eventually(() => s.incoming?.receivedBytes == 128 * kib);
      s.clock.advance(const Duration(seconds: 29, milliseconds: 900));
      await settle();
      expect(s.incoming?.stage, IncomingStage.receiving);

      s.clock.advance(const Duration(milliseconds: 100));
      await expectEndedUpload(
        s,
        laptop,
        a,
        result,
        TransferOutcome.idle,
        failedState('idle'),
      );
    });

    test('a slow disk is not inactivity: with a write held for 90 s the '
        'upload goes on, then counts 30 s from that write and saves', () async {
      final write = WriteGate();
      final s = await stack(writeBytes: write.call);
      final a = await accept(s, laptop, randomBytes(mib + 512 * kib, 902));
      final held = HeldBody();
      final result = s.postUpload(
        laptop.identity,
        headers: a.headers,
        contentLength: a.bytes.length,
        body: held.stream,
      );
      held.sendAll(Uint8List.sublistView(a.bytes, 0, mib + 64 * kib));
      await write.reached.future;

      s.clock.advance(const Duration(seconds: 31));
      await settle(const Duration(milliseconds: 150));
      expect(s.incoming?.stage, IncomingStage.receiving);
      s.clock.advance(const Duration(seconds: 59));
      await settle(const Duration(milliseconds: 150));
      expect(s.incoming?.stage, IncomingStage.receiving);
      expect(s.coordinator.lastReceived, isNull);

      write.open();
      await eventually(
        () => s.incoming?.receivedBytes == mib + 64 * kib,
        reason: 'held write done',
      );
      s.clock.advance(const Duration(seconds: 29, milliseconds: 900));
      await settle();
      expect(s.incoming?.stage, IncomingStage.receiving);

      held.sendAll(Uint8List.sublistView(a.bytes, mib + 64 * kib));
      held.finish();
      expectState(answered(await result), savedState);
      expect(File('${s.receiveDir}\\informe.txt').readAsBytesSync(), a.bytes);
      expect(s.coordinator.lastReceived?.outcome, TransferOutcome.saved);
      await expectNothingLeft(s, s.receiveDir);
    });
  });

  group('T10 E91 E152 RF-168 writes that fail', () {
    test('E91 a write that fails past 1 MiB ends in writeFailed on both '
        'sides, cuts the upload and leaves nothing; the log has only the '
        'error type', () async {
      final s = await stack(
        writeBytes: failingWrite(const FileSystemException('write refused')),
      );
      final a = await accept(s, laptop, randomBytes(2 * mib, 91));

      await expectEndedUpload(
        s,
        laptop,
        a,
        send(s, laptop, a),
        TransferOutcome.writeFailed,
        failedState('write_failed'),
      );
      expect(
        s.logs.any((line) => line.contains('FileSystemException')),
        isTrue,
        reason: '${s.logs}',
      );
    });

    for (final code in [112, 39]) {
      test('E152 D-9 with unknown free space the offer is accepted without '
          'asking, and a full disk (error $code) halfway ends in diskFull on '
          'both sides with the temporary and the subfolder deleted', () async {
        final s = await stack(
          configure: (p) => p.freeBytesUnknown = true,
          writeBytes: failingWrite(diskFullError(code)),
        );
        final a = await accept(s, laptop, randomBytes(2 * mib, 152));
        expect(s.platform.freeCalls, greaterThan(0));
        expect(
          s.seen.where((v) => v.stage != IncomingStage.waitingData),
          isEmpty,
        );

        await expectEndedUpload(
          s,
          laptop,
          a,
          send(s, laptop, a),
          TransferOutcome.diskFull,
          failedState('disk_full'),
        );
      });
    }

    test('D-9 a full disk on the last write, while verifying, answers '
        'disk_full on the same connection and leaves nothing', () async {
      final s = await stack(
        writeBytes: failingWrite(diskFullError(112), onCall: 2),
      );
      final a = await accept(s, laptop, randomBytes(mib + 512 * kib, 1521));

      expectState(answered(await send(s, laptop, a)), failedState('disk_full'));
      expect(s.coordinator.lastReceived?.outcome, TransferOutcome.diskFull);
      expect(treeOf(s.receiveDir), isEmpty);
      await expectNothingLeft(s, s.receiveDir);
    });
  });

  group('T10 RF-166 the connection is lost', () {
    test('a sender that disappears halfway ends in connectionLost, and its '
        'next wait is told connection_lost', () async {
      final s = await stack();
      final a = await accept(s, laptop, randomBytes(mib, 166));
      late Future<StreamPostResult> result;
      final held = await startHeld(s, laptop, a, 256 * kib, (r) => result = r);

      held.breakOff();

      expect(await result, isA<StreamPostFailed>());
      await eventually(
        () => s.coordinator.lastReceived != null,
        reason: 'session ended',
      );
      expect(
        s.coordinator.lastReceived?.outcome,
        TransferOutcome.connectionLost,
      );
      await expectNothingLeft(s, s.receiveDir);
      expect(treeOf(s.receiveDir), isEmpty);
      expectState(
        await s.wait(laptop, a.transfer),
        failedState('connection_lost'),
      );
    });
  });

  group('T10 E93 E95 RF-184 RF-169 cancelling an accepted send', () {
    test('E93 the receiver cancels during the upload: the upload is cut, the '
        'sender is told cancelled, nothing is left and the permit is '
        'spent', () async {
      final s = await stack();
      final a = await accept(s, laptop, randomBytes(mib, 93));
      late Future<StreamPostResult> result;
      await startHeld(s, laptop, a, 128 * kib, (r) => result = r);

      s.coordinator.cancelIncoming(s.sid);

      expect(s.incoming, isNull);
      await expectEndedUpload(
        s,
        laptop,
        a,
        result,
        TransferOutcome.cancelledHere,
        cancelledState,
      );
    });

    test('E93 the receiver cancels before the upload starts: the sender is '
        'told cancelled and the permit then gets 403', () async {
      final s = await stack();
      final a = await accept(s, laptop, randomBytes(4 * kib, 931));

      s.coordinator.cancelIncoming(s.sid);

      expect(s.incoming, isNull);
      expect(s.coordinator.busy, isFalse);
      expect(
        s.coordinator.lastReceived?.outcome,
        TransferOutcome.cancelledHere,
      );
      expectState(await s.wait(laptop, a.transfer), cancelledState);
      expectForbidden(answered(await send(s, laptop, a)));
      expect(treeOf(s.receiveDir), isEmpty);
      expect(s.journal.folders, isEmpty);
      expect(s.handledOn(ApiPaths.transferUpload), 1);
    });

    test('E95 a cancel with reason unreadable before the upload ends as '
        'unreadable and the permit then gets 403', () async {
      final s = await stack();
      final a = await accept(s, laptop, randomBytes(4 * kib, 95));

      expectState(
        await s.cancel(laptop, a.transfer, reason: 'unreadable'),
        failedState('unreadable'),
      );

      expect(s.incoming, isNull);
      expect(s.coordinator.lastReceived?.outcome, TransferOutcome.unreadable);
      expectState(await s.wait(laptop, a.transfer), failedState('unreadable'));
      expectForbidden(answered(await send(s, laptop, a)));
      expect(treeOf(s.receiveDir), isEmpty);
    });

    test('[SEG] cancelIncoming during the upload with an old, empty, made-up '
        'or wire id does nothing and the upload still saves', () async {
      final s = await stack();
      await accept(s, laptop, randomBytes(2 * kib, 1));
      final oldSid = s.sid;
      s.coordinator.cancelIncoming(oldSid);
      expect(
        s.coordinator.lastReceived?.outcome,
        TransferOutcome.cancelledHere,
      );
      final before = s.coordinator.lastReceived;

      final a = await accept(s, laptop, randomBytes(512 * kib, 2));
      late Future<StreamPostResult> result;
      final held = await startHeld(s, laptop, a, 128 * kib, (r) => result = r);
      final sid = s.sid;
      expect(sid, isNot(oldSid));

      for (final id in [
        oldSid,
        '',
        newTransferId(),
        a.transfer,
        a.permit,
        sid.toUpperCase(),
        ' $sid',
        '$sid ',
      ]) {
        s.coordinator.cancelIncoming(id);
        expect(s.incoming?.stage, IncomingStage.receiving, reason: id);
        expect(s.sid, sid, reason: id);
      }
      expect(identical(s.coordinator.lastReceived, before), isTrue);
      expect(Directory(subOf(s.receiveDir)).existsSync(), isTrue);

      held.sendAll(Uint8List.sublistView(a.bytes, 128 * kib));
      held.finish();
      expectState(answered(await result), savedState);
      expect(File('${s.receiveDir}\\informe.txt').readAsBytesSync(), a.bytes);
      await expectNothingLeft(s, s.receiveDir);
    });

    test('cancelIncoming while verifying does nothing and the file is '
        'saved', () async {
      final mark = MarkGate();
      final s = await stack(configure: (p) => p.mark = mark.call);
      final a = await accept(s, laptop, randomBytes(128 * kib, 932));
      final result = send(s, laptop, a);
      await mark.reached.future;
      expect(s.incoming?.stage, IncomingStage.verifying);

      s.coordinator.cancelIncoming(s.sid);
      expect(s.incoming?.stage, IncomingStage.verifying);

      mark.open();
      expectState(answered(await result), savedState);
      expect(s.coordinator.lastReceived?.outcome, TransferOutcome.saved);
      expect(File('${s.receiveDir}\\informe.txt').readAsBytesSync(), a.bytes);
      await expectNothingLeft(s, s.receiveDir);
    });

    test('E94 point 78 a remote cancel while verifying waits for the end and '
        'answers the failure when saving fails', () async {
      final mark = MarkGate(marks: false);
      final s = await stack(configure: (p) => p.mark = mark.call);
      final a = await accept(s, laptop, randomBytes(128 * kib, 78));
      final result = send(s, laptop, a);
      await mark.reached.future;

      final cancel = Pending(s.cancel(laptop, a.transfer));
      await settle(const Duration(milliseconds: 400));
      expect(cancel.done, isFalse, reason: 'cancel waits while verifying');
      expect(s.incoming?.stage, IncomingStage.verifying);

      mark.open();
      expectState(answered(await result), failedState('mark_failed'));
      await eventually(() => cancel.done, reason: 'cancel answered');
      expectState(cancel.result, failedState('mark_failed'));
      expect(s.coordinator.lastReceived?.outcome, TransferOutcome.markFailed);
      expect(treeOf(s.receiveDir), isEmpty);
      await expectNothingLeft(s, s.receiveDir);
    });
  });

  group('T10 E97 RF-189 RF-236 unpairing the sender', () {
    for (final (label, unpair) in unpairings) {
      test('E97 $label during the upload: the upload is cut, unpaired, '
          'nothing is left and the permit is shut out at the '
          'handshake', () async {
        final s = await stack();
        final a = await accept(s, laptop, randomBytes(mib, 97));
        late Future<StreamPostResult> result;
        await startHeld(s, laptop, a, 128 * kib, (r) => result = r);

        await unpair(s, laptop);
        expect(s.incoming, isNull);
        await forget(s, laptop);

        expect(
          await result.timeout(const Duration(seconds: 5)),
          isA<StreamPostFailed>(),
        );
        expect(s.coordinator.lastReceived?.outcome, TransferOutcome.unpaired);
        await expectNothingLeft(s, s.receiveDir);
        expect(treeOf(s.receiveDir), isEmpty);
        expect(s.events, isEmpty);
        await expectShutOut(s, laptop, a);
        expectCleanLogs(s, [a.permit]);
      });

      test('E97 $label with the send accepted: unpaired and the permit is '
          'shut out at the handshake', () async {
        final s = await stack();
        final a = await accept(s, laptop, randomBytes(4 * kib, 971));

        await unpair(s, laptop);
        expect(s.incoming, isNull);
        expect(s.coordinator.lastReceived?.outcome, TransferOutcome.unpaired);
        await forget(s, laptop);

        await expectShutOut(s, laptop, a);
        expect(s.journal.folders, isEmpty);
        expect(s.coordinator.busy, isFalse);
        expect(s.events, isEmpty);
      });

      test(
        'E97 RF-236 $label with the warning open closes the card as '
        'unpaired, without the cancel notice or a recent rejection',
        () async {
          final s = await stack();
          final offer = await s.offer(portatil);
          expect(offer?.status, 202, reason: offer?.text);
          expect(s.incoming?.stage, IncomingStage.warning);

          await unpair(s, portatil);
          expect(s.incoming, isNull);
          await forget(s, portatil);

          expect(s.coordinator.lastReceived?.outcome, TransferOutcome.unpaired);
          expect(s.coordinator.lastReceived?.peerName, 'PORTATIL');
          expect(s.coordinator.busy, isFalse);
          await settle();
          expect(s.events, isEmpty);

          await s.pairWith([portatil]);
          final again = await s.offer(portatil);
          expect(again?.status, 202, reason: again?.text);
          expect(s.incoming?.stage, IncomingStage.warning);
        },
      );

      test('E97 RF-236 $label with the folder question open closes it as '
          'unpaired and remembers nothing', () async {
        final s = await stack(remembered: false);
        final offer = await s.offer(laptop);
        expect(offer?.status, 202, reason: offer?.text);
        expect(s.incoming?.stage, IncomingStage.folderQuestion);

        await unpair(s, laptop);
        expect(s.incoming, isNull);
        await forget(s, laptop);

        expect(s.coordinator.lastReceived?.outcome, TransferOutcome.unpaired);
        expect(s.coordinator.busy, isFalse);
        expect(s.store.saved, isEmpty);
        expect(s.picker.calls, 0);
        await settle();
        expect(s.events, isEmpty);
      });

      test('point 77 $label while checking ends in silence and the held '
          'offer gets 410', () async {
        final gate = Completer<void>();
        addTearDown(() {
          if (!gate.isCompleted) gate.complete();
        });
        final s = await stack(configure: (p) => p.volumeGate = gate);
        s.sampleViews();
        final pending = s.offer(laptop);
        await eventually(() => s.platform.volumeCalls > 0, reason: 'checking');
        expect(s.coordinator.busy, isTrue);

        await unpair(s, laptop);
        gate.complete();

        expectGone(await pending);
        await settle();
        expect(s.seen, isEmpty);
        expect(s.incoming, isNull);
        expect(s.coordinator.lastReceived, isNull);
        expect(s.coordinator.busy, isFalse);
        expect(s.events, isEmpty);
        expect(treeOf(s.receiveDir), isEmpty);
      });

      test('point 77 $label while verifying changes nothing and the file is '
          'saved', () async {
        final mark = MarkGate();
        final s = await stack(configure: (p) => p.mark = mark.call);
        final a = await accept(s, laptop, randomBytes(256 * kib, 77));
        final result = Pending(send(s, laptop, a));
        await mark.reached.future;
        final sid = s.sid;

        await unpair(s, laptop);
        expect(s.incoming?.stage, IncomingStage.verifying);
        expect(s.sid, sid);
        await forget(s, laptop);
        expect(s.incoming?.stage, IncomingStage.verifying);

        mark.open();
        await eventually(
          () => s.coordinator.lastReceived != null,
          reason: 'session ended',
        );
        expect(s.coordinator.lastReceived?.outcome, TransferOutcome.saved);
        expect(File('${s.receiveDir}\\informe.txt').readAsBytesSync(), a.bytes);
        expect(treeOf(s.receiveDir), ['informe.txt']);
        await expectNothingLeft(s, s.receiveDir);
        await eventually(() => result.done, reason: 'upload call over');
      });
    }

    test('unpairing another device does nothing to the upload', () async {
      final s = await stack();
      final a = await accept(s, laptop, randomBytes(512 * kib, 972));
      late Future<StreamPostResult> result;
      final held = await startHeld(s, laptop, a, 128 * kib, (r) => result = r);

      await s.coordinator.peerUnpaired(desk.fingerprint);
      await s.paired.remove(desk.fingerprint);
      s.coordinator.pairedChanged();
      await s.server.rebuildTrust();
      await settle();
      expect(s.incoming?.stage, IncomingStage.receiving);

      held.sendAll(Uint8List.sublistView(a.bytes, 128 * kib));
      held.finish();
      expectState(answered(await result), savedState);
      expect(s.coordinator.lastReceived?.outcome, TransferOutcome.saved);
      await expectNothingLeft(s, s.receiveDir);
    });

    test('pairedChanged with the sender still paired does nothing', () async {
      final s = await stack();
      final a = await accept(s, laptop, randomBytes(4 * kib, 973));
      s.coordinator.pairedChanged();
      expect(s.incoming?.stage, IncomingStage.waitingData);
      expectState(answered(await send(s, laptop, a)), savedState);
    });

    test('point 78 peerUnpaired returns at once with a slow write held, and '
        'the temporary is deleted once the write ends', () async {
      final write = WriteGate();
      final s = await stack(writeBytes: write.call);
      final a = await accept(s, laptop, randomBytes(mib + 256 * kib, 974));
      final held = HeldBody();
      final result = s.postUpload(
        laptop.identity,
        headers: a.headers,
        contentLength: a.bytes.length,
        body: held.stream,
      );
      held.sendAll(Uint8List.sublistView(a.bytes, 0, mib + 64 * kib));
      await write.reached.future;

      await s.coordinator
          .peerUnpaired(laptop.fingerprint)
          .timeout(const Duration(milliseconds: 500));
      expect(s.incoming, isNull);
      expect(s.coordinator.lastReceived?.outcome, TransferOutcome.unpaired);

      write.open();
      expect(
        await result.timeout(const Duration(seconds: 5)),
        isA<StreamPostFailed>(),
      );
      await expectNothingLeft(s, s.receiveDir);
      expect(treeOf(s.receiveDir), isEmpty);
    });
  });

  group('T10 D29 RF-188 the interface of the session goes down', () {
    test('during the upload: interfaceDown, the upload is cut, nothing is '
        'left and the sender is told; no timer is left', () async {
      final tracker = TimerTracker();
      await runZoned(() async {
        final s = await stack();
        final a = await accept(s, laptop, randomBytes(mib, 188));
        late Future<StreamPostResult> result;
        await startHeld(s, laptop, a, 128 * kib, (r) => result = r);

        s.coordinator.interfacesChanged({loopbackId, otherInterfaceId});
        await settle();
        expect(s.incoming?.stage, IncomingStage.receiving);

        s.coordinator.interfacesChanged({otherInterfaceId});
        expect(s.incoming, isNull);
        await expectEndedUpload(
          s,
          laptop,
          a,
          result,
          TransferOutcome.interfaceDown,
          failedState('interface_down'),
        );

        await s.close();
        await settle();
        expect(tracker.activeBy('src/transfer/'), 0);
        expect(tracker.activeBy('src/server/'), 0);
        expect(tracker.activeBy('src/transport/'), 0);
      }, zoneSpecification: tracker.specification);
    });

    test('with the send accepted: interfaceDown and the permit gets '
        '403', () async {
      final s = await stack();
      final a = await accept(s, laptop, randomBytes(4 * kib, 1881));

      s.coordinator.interfacesChanged(const {});

      expect(s.incoming, isNull);
      expect(
        s.coordinator.lastReceived?.outcome,
        TransferOutcome.interfaceDown,
      );
      expectState(
        await s.wait(laptop, a.transfer),
        failedState('interface_down'),
      );
      expectForbidden(answered(await send(s, laptop, a)));
      expect(treeOf(s.receiveDir), isEmpty);
      expect(s.journal.folders, isEmpty);
    });

    test('with the warning open: the card closes as interfaceDown', () async {
      final s = await stack();
      final transfer = newTransferId();
      final offer = await s.offer(portatil, transfer: transfer);
      expect(offer?.status, 202, reason: offer?.text);

      s.coordinator.interfacesChanged(const {});

      expect(s.incoming, isNull);
      expect(
        s.coordinator.lastReceived?.outcome,
        TransferOutcome.interfaceDown,
      );
      expectState(
        await s.wait(portatil, transfer),
        failedState('interface_down'),
      );
      await settle();
      expect(s.events, isEmpty);
    });

    test('with the folder question open: it closes as interfaceDown and '
        'remembers nothing', () async {
      final s = await stack(remembered: false);
      final offer = await s.offer(laptop);
      expect(offer?.status, 202, reason: offer?.text);
      expect(s.incoming?.stage, IncomingStage.folderQuestion);

      s.coordinator.interfacesChanged({otherInterfaceId});

      expect(s.incoming, isNull);
      expect(
        s.coordinator.lastReceived?.outcome,
        TransferOutcome.interfaceDown,
      );
      expect(s.store.saved, isEmpty);
      expect(s.coordinator.busy, isFalse);
    });

    test('point 77 while checking: ends in silence and the held offer gets '
        '410', () async {
      final gate = Completer<void>();
      addTearDown(() {
        if (!gate.isCompleted) gate.complete();
      });
      final s = await stack(configure: (p) => p.volumeGate = gate);
      s.sampleViews();
      final pending = s.offer(laptop);
      await eventually(() => s.platform.volumeCalls > 0, reason: 'checking');

      s.coordinator.interfacesChanged(const {});
      gate.complete();

      expectGone(await pending);
      await settle();
      expect(s.seen, isEmpty);
      expect(s.coordinator.lastReceived, isNull);
      expect(s.coordinator.busy, isFalse);
      expect(s.events, isEmpty);
    });

    test('point 77 while verifying: nothing changes, the file is saved and '
        'the answer says so', () async {
      final mark = MarkGate();
      final s = await stack(configure: (p) => p.mark = mark.call);
      final a = await accept(s, laptop, randomBytes(256 * kib, 1882));
      final result = send(s, laptop, a);
      await mark.reached.future;

      s.coordinator.interfacesChanged(const {});
      expect(s.incoming?.stage, IncomingStage.verifying);

      mark.open();
      expectState(answered(await result), savedState);
      expect(s.coordinator.lastReceived?.outcome, TransferOutcome.saved);
      expect(File('${s.receiveDir}\\informe.txt').readAsBytesSync(), a.bytes);
      await expectNothingLeft(s, s.receiveDir);
    });
  });

  group('T10 A24 close() with an upload', () {
    test('close with a slow write held cuts the upload, waits for the write '
        'and leaves nothing', () async {
      final write = WriteGate();
      final s = await stack(writeBytes: write.call);
      final a = await accept(s, laptop, randomBytes(mib + 256 * kib, 241));
      final held = HeldBody();
      final result = s.postUpload(
        laptop.identity,
        headers: a.headers,
        contentLength: a.bytes.length,
        body: held.stream,
      );
      held.sendAll(Uint8List.sublistView(a.bytes, 0, mib + 64 * kib));
      await write.reached.future;

      final closing = Pending(s.coordinator.close());
      await settle(const Duration(milliseconds: 300));
      expect(closing.done, isFalse, reason: 'close waits for the write');
      expect(
        s.coordinator.lastReceived?.outcome,
        TransferOutcome.cancelledHere,
      );

      write.open();
      await closing.future.timeout(Limits.transferCloseBudget);
      expect(
        await result.timeout(const Duration(seconds: 5)),
        isA<StreamPostFailed>(),
      );
      expect(Directory(subOf(s.receiveDir)).existsSync(), isFalse);
      expect(s.journal.folders, isEmpty);
      expect(treeOf(s.receiveDir), isEmpty);
    });

    test('close while verifying waits for the end when it comes within '
        '2 s, and the file is saved', () async {
      final mark = MarkGate();
      final s = await stack(configure: (p) => p.mark = mark.call);
      final a = await accept(s, laptop, randomBytes(128 * kib, 242));
      final result = send(s, laptop, a);
      await mark.reached.future;

      final stopwatch = Stopwatch()..start();
      final closing = Pending(s.coordinator.close());
      await settle(const Duration(milliseconds: 300));
      expect(closing.done, isFalse, reason: 'close waits for verifying');

      mark.open();
      await closing.future;
      expect(stopwatch.elapsed, lessThan(const Duration(seconds: 2)));
      expectState(answered(await result), savedState);
      expect(s.coordinator.lastReceived?.outcome, TransferOutcome.saved);
      expect(File('${s.receiveDir}\\informe.txt').readAsBytesSync(), a.bytes);
      expect(Directory(subOf(s.receiveDir)).existsSync(), isFalse);
      await eventually(() => s.journal.folders.isEmpty);
    });

    test('close with verifying held for more than 2 s returns within the '
        '4 s budget, answers the held wait and leaves no timer', () async {
      final tracker = TimerTracker();
      await runZoned(() async {
        final mark = MarkGate();
        final s = await stack(
          pollHold: const Duration(seconds: 8),
          configure: (p) => p.mark = mark.call,
        );
        final a = await accept(s, laptop, randomBytes(128 * kib, 243));
        final result = Pending(send(s, laptop, a));
        await mark.reached.future;
        final heldWait = Pending(s.wait(laptop, a.transfer));
        await eventually(() => s.handledOn(ApiPaths.transferWait) == 1);
        await settle();
        expect(heldWait.done, isFalse);

        final stopwatch = Stopwatch()..start();
        await s.coordinator.close();
        final took = stopwatch.elapsed;
        expect(took, greaterThanOrEqualTo(const Duration(milliseconds: 1900)));
        expect(took, lessThan(Limits.transferCloseBudget));
        await eventually(
          () => heldWait.done,
          limit: const Duration(milliseconds: 500),
          reason: 'held wait answered by close',
        );
        expect(heldWait.result?.status, 200);

        mark.open();
        await eventually(() => result.done, reason: 'upload call over');
        await eventually(
          () => !Directory(subOf(s.receiveDir)).existsSync(),
          reason: 'no temporary subfolder',
        );
        await eventually(() => s.journal.folders.isEmpty);
        expect(treeOf(s.receiveDir), anyOf(isEmpty, ['informe.txt']));

        await s.close();
        await settle();
        expect(tracker.activeBy('src/transfer/'), 0);
      }, zoneSpecification: tracker.specification);
    });
  });

  group('T10 RF-163 progress during the upload', () {
    test('progress is published for the first byte, then at most every '
        '250 ms and at least once a second while data arrives, and when '
        'verifying starts', () async {
      final s = await stack();
      final a = await accept(s, laptop, randomBytes(2 * mib, 163));
      final held = HeldBody();
      final result = s.postUpload(
        laptop.identity,
        headers: a.headers,
        contentLength: a.bytes.length,
        body: held.stream,
      );
      var sent = 0;
      Future<int> push(int length) async {
        final before = s.views.length;
        held.sendAll(Uint8List.sublistView(a.bytes, sent, sent + length));
        sent += length;
        await eventually(
          () => s.incoming?.receivedBytes == sent,
          reason: '$sent bytes written',
        );
        await settle(const Duration(milliseconds: 40));
        return s.views.length - before;
      }

      expect(await push(64 * kib), inInclusiveRange(1, 2));
      expect(s.views.last?.stage, IncomingStage.receiving);
      expect(s.views.last?.receivedBytes, inInclusiveRange(1, 64 * kib));

      expect(await push(15 * 64 * kib), 0);
      s.clock.advance(const Duration(milliseconds: 249));
      expect(await push(64 * kib), 0);
      s.clock.advance(const Duration(milliseconds: 1));
      expect(await push(64 * kib), 1);
      expect(
        s.views.last?.receivedBytes,
        inInclusiveRange(sent - 64 * kib, sent),
      );
      s.clock.advance(const Duration(milliseconds: 100));
      expect(await push(64 * kib), 0);
      s.clock.advance(const Duration(seconds: 1));
      expect(await push(64 * kib), 1);
      expect(
        s.views.last?.receivedBytes,
        inInclusiveRange(sent - 64 * kib, sent),
      );

      held.sendAll(Uint8List.sublistView(a.bytes, sent));
      held.finish();
      expectState(answered(await result), savedState);
      expect(
        s.views.any(
          (v) =>
              v?.stage == IncomingStage.verifying &&
              v!.receivedBytes == a.bytes.length,
        ),
        isTrue,
      );
    });
  });
}
