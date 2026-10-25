@TestOn('windows')
library;

import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:nexus_bridges_core/src/pairing/pairing.dart';
import 'package:nexus_bridges_core/src/protocol/protocol.dart';
import 'package:nexus_bridges_core/src/transfer/transfer.dart';
import 'package:test/test.dart';

import '../pairing_flow/receiver_harness.dart' show TimerTracker;
import 'transfer_stacks_harness.dart';

const int mib = 1048576;

Uint8List randomBytes(int length, int seed) {
  final random = Random(seed);
  final bytes = Uint8List(length);
  for (var i = 0; i < length; i++) {
    bytes[i] = random.nextInt(256);
  }
  return bytes;
}

Future<(TransferStack, TransferStack)> stacks({
  PeerRelation senderAtReceiver = PeerRelation.mine,
  WriteBytes? writesAtA,
  WriteBytes? writesAtB,
}) async {
  final a = await TransferStack.start(
    name: 'A',
    address: hostA,
    writeBytes: writesAtA,
  );
  final b = await TransferStack.start(
    name: 'B',
    address: hostB,
    writeBytes: writesAtB,
  );
  await link(a, b, senderAtReceiver: senderAtReceiver);
  return (a, b);
}

Completer<void> heldPicker(TransferStack s) {
  final gate = Completer<void>();
  addTearDown(() {
    if (!gate.isCompleted) gate.complete();
  });
  s.picker
    ..gate = gate
    ..next = null;
  return gate;
}

Future<void> advanceWithPolls(TransferStack s, Duration total) async {
  var left = total;
  while (left > Duration.zero) {
    final span = left < const Duration(seconds: 10)
        ? left
        : const Duration(seconds: 10);
    s.clock.advance(span);
    left -= span;
    final target = s.handledOn(ApiPaths.transferWait) + 1;
    await eventually(
      () => s.handledOn(ApiPaths.transferWait) >= target,
      reason: 'a poll after advancing ${s.name}',
    );
  }
}

Future<void> sendBothWays(TransferStack a, TransferStack b) async {
  final pathA = await a.sourceFile('de-a.bin', randomBytes(8 * mib, 1));
  final pathB = await b.sourceFile('de-b.bin', randomBytes(8 * mib, 2));
  expect(await a.send(b, pathA), SendStart.started);
  expect(await b.send(a, pathB), SendStart.started);
  await eventually(
    () =>
        a.outgoing?.phase == OutgoingPhase.uploading &&
        b.outgoing?.phase == OutgoingPhase.uploading &&
        a.incoming?.stage == IncomingStage.receiving &&
        b.incoming?.stage == IncomingStage.receiving,
    reason: 'both uploads running',
  );
}

Future<void> nothingLeft(TransferStack s) async {
  await eventually(
    () => !Directory(s.tempSub).existsSync(),
    reason: '${s.name} temporary subfolder removed',
  );
  expect(s.incoming, isNull);
  expect(Directory(s.receiveDir).listSync(), isEmpty);
}

Future<void> peerEndsWithoutSaving(TransferStack b) async {
  final sent = await b.sentResult(limit: const Duration(seconds: 15));
  expect(sent.outcome.kind, isNot(TransferResultKind.saved));
  final received = await b.receivedResult();
  expect(received.outcome.kind, isNot(TransferResultKind.saved));
  await nothingLeft(b);
}

void main() {
  group('E154 RF-155 RF-218 D-10 the file picker of the sending side', () {
    test('freezes the 60 s of a warning shown by the receiving side and the '
        'warning keeps the 10 s it had left', () async {
      final (a, b) = await stacks(senderAtReceiver: PeerRelation.foreign);
      final pickerFlags = <Object?>[];
      b.wrappers[ApiPaths.transferWait] = (call, inner) async {
        final reply = await inner(call);
        pickerFlags.add(reply.json['picker']);
        return reply;
      };
      final path = await a.sourceFile('informe.bin', randomBytes(4096, 154));
      expect(await a.send(b, path), SendStart.started);
      await eventually(() => b.incoming?.stage == IncomingStage.warning);
      await advanceWithPolls(b, const Duration(seconds: 50));
      expect(b.incoming?.stage, IncomingStage.warning);

      final gate = heldPicker(b);
      final opened = b.coordinator.sendFile(
        b.targetOf(a),
        refresh: () => b.targetOf(a),
      );
      await eventually(() => b.picker.fileCalls == 1);
      expect(b.coordinator.pickerOpen, isTrue);
      expect(b.coordinator.sending, isTrue);
      expect(b.coordinator.busy, isTrue);
      pickerFlags.clear();
      await advanceWithPolls(b, const Duration(seconds: 30));
      expect(b.incoming?.stage, IncomingStage.warning);
      expect(pickerFlags, contains(true));

      gate.complete();
      expect(await opened, SendStart.nothingChosen);
      expect(b.coordinator.pickerOpen, isFalse);
      expect(b.coordinator.sending, isFalse);
      expect(b.lastSent, isNull);
      await advanceWithPolls(b, const Duration(milliseconds: 9900));
      await settle();
      expect(b.incoming?.stage, IncomingStage.warning);
      b.clock.advance(const Duration(milliseconds: 100));
      await eventually(() => b.incoming == null, reason: 'warning expired');
      expect(b.lastReceived!.outcome, TransferOutcome.unanswered);
      expect((await a.sentResult()).outcome, TransferOutcome.unanswered);
    }, timeout: const Timeout(Duration(seconds: 60)));
  });

  group('RF-141 RF-143 busy covers both sides', () {
    test('busy is true with only an outgoing send, with only an incoming one '
        'and with the file picker open, and false again after', () async {
      final writes = WriteThrottle()..hold();
      final (a, b) = await stacks(writesAtB: writes.call);
      final busyA = <bool>[];
      final busyB = <bool>[];
      a.coordinator.changes.listen((_) => busyA.add(a.coordinator.busy));
      b.coordinator.changes.listen((_) => busyB.add(b.coordinator.busy));
      final path = await a.sourceFile('informe.bin', randomBytes(8 * mib, 1));
      expect(await a.send(b, path), SendStart.started);
      await eventually(() => writes.calls >= 1, reason: 'upload started');
      expect(a.incoming, isNull);
      expect(a.coordinator.busy, isTrue);
      expect(b.outgoing, isNull);
      expect(b.coordinator.busy, isTrue);
      writes.open();
      expect((await a.sentResult()).outcome, TransferOutcome.saved);
      await b.receivedResult();
      await eventually(() => !a.coordinator.busy && !b.coordinator.busy);
      await settle();
      expect(busyA, containsAllInOrder([true, false]));
      expect(busyA.last, isFalse);
      expect(busyB, containsAllInOrder([true, false]));
      expect(busyB.last, isFalse);

      final gate = heldPicker(a);
      final opened = a.coordinator.sendFile(
        a.targetOf(b),
        refresh: () => a.targetOf(b),
      );
      await eventually(() => a.picker.fileCalls == 2);
      expect(a.coordinator.busy, isTrue);
      expect(a.coordinator.pickerOpen, isTrue);
      gate.complete();
      expect(await opened, SendStart.nothingChosen);
      expect(a.coordinator.busy, isFalse);
      expect(a.coordinator.pickerOpen, isFalse);
    });
  });

  group('RF-188 RF-189 RF-191 network and pairing changes reach both '
      'sides', () {
    test('interfacesChanged without the interface ends the outgoing and the '
        'incoming send as interface down', () async {
      final (a, b) = await stacks(
        writesAtA: WriteThrottle(delay: const Duration(milliseconds: 20)).call,
        writesAtB: WriteThrottle(delay: const Duration(milliseconds: 20)).call,
      );
      await sendBothWays(a, b);
      a.coordinator.interfacesChanged({'other#10.0.0.1'});
      expect(a.outgoing, isNull);
      expect(a.incoming, isNull);
      expect(a.lastSent!.outcome, TransferOutcome.interfaceDown);
      expect(a.lastReceived!.outcome, TransferOutcome.interfaceDown);
      expect(a.coordinator.busy, isFalse);
      await nothingLeft(a);
      await peerEndsWithoutSaving(b);
    }, timeout: const Timeout(Duration(seconds: 60)));

    test(
      'pairedChanged without the peer ends both sends as unpaired',
      () async {
        final (a, b) = await stacks(
          writesAtA: WriteThrottle(delay: const Duration(milliseconds: 20))
              .call,
          writesAtB: WriteThrottle(delay: const Duration(milliseconds: 20))
              .call,
        );
        await sendBothWays(a, b);
        a.coordinator.pairedChanged();
        expect(a.outgoing, isNotNull);
        expect(a.incoming, isNotNull);
        await a.paired.remove(b.fingerprint);
        a.coordinator.pairedChanged();
        expect(a.outgoing, isNull);
        expect(a.incoming, isNull);
        expect(a.lastSent!.outcome, TransferOutcome.unpaired);
        expect(a.lastReceived!.outcome, TransferOutcome.unpaired);
        await nothingLeft(a);
        await peerEndsWithoutSaving(b);
      },
      timeout: const Timeout(Duration(seconds: 60)),
    );

    test('peerUnpaired ends both sends as unpaired', () async {
      final (a, b) = await stacks(
        writesAtA: WriteThrottle(delay: const Duration(milliseconds: 20)).call,
        writesAtB: WriteThrottle(delay: const Duration(milliseconds: 20)).call,
      );
      await sendBothWays(a, b);
      await a.coordinator.peerUnpaired(b.fingerprint);
      expect(a.outgoing, isNull);
      expect(a.incoming, isNull);
      expect(a.lastSent!.outcome, TransferOutcome.unpaired);
      expect(a.lastReceived!.outcome, TransferOutcome.unpaired);
      await nothingLeft(a);
      await peerEndsWithoutSaving(b);
    }, timeout: const Timeout(Duration(seconds: 60)));
  });

  group('A24 RF-186 close() closes both sides', () {
    test('within the budget, with no timer, temporary or send left', () async {
      final tracker = TimerTracker();
      final b = await TransferStack.start(
        name: 'B',
        address: hostB,
        writeBytes: WriteThrottle(delay: const Duration(milliseconds: 20)).call,
      );
      await runZoned(() async {
        final a = await TransferStack.start(
          name: 'A',
          address: hostA,
          writeBytes: WriteThrottle(delay: const Duration(milliseconds: 20))
              .call,
        );
        await link(a, b);
        await sendBothWays(a, b);
        final stopwatch = Stopwatch()..start();
        await a.coordinator.close();
        final changes = <void>[];
        var ended = false;
        a.coordinator.changes.listen(changes.add, onDone: () => ended = true);
        expect(stopwatch.elapsed, lessThan(Limits.transferCloseBudget));
        expect(a.outgoing, isNull);
        expect(a.incoming, isNull);
        expect(a.coordinator.busy, isFalse);
        expect(a.lastSent!.outcome, TransferOutcome.cancelledHere);
        expect(a.lastReceived!.outcome, TransferOutcome.cancelledHere);
        await nothingLeft(a);
        await peerEndsWithoutSaving(b);
        await settle(const Duration(milliseconds: 300));
        expect(tracker.createdBy('src/transfer/'), greaterThan(0));
        expect(tracker.activeBy('src/transfer/'), 0);
        expect(tracker.activeBy('src/transport/'), 0);
        a.clock.advance(const Duration(hours: 1));
        await settle();
        expect(changes, isEmpty);
        expect(ended, isTrue);
        expect(a.lastSent!.outcome, TransferOutcome.cancelledHere);
        expect(
          await a.coordinator.sendFile(
            a.targetOf(b),
            refresh: () => a.targetOf(b),
          ),
          SendStart.nothingChosen,
        );
      }, zoneSpecification: tracker.specification);
    }, timeout: const Timeout(Duration(seconds: 60)));
  });
}
