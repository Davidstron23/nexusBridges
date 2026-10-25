import 'dart:async';
import 'dart:io';

import 'package:nexus_bridges_core/src/identity/identity.dart';
import 'package:nexus_bridges_core/src/pairing/pairing.dart';
import 'package:nexus_bridges_core/src/protocol/protocol.dart';
import 'package:nexus_bridges_core/src/storage/storage.dart';
import 'package:nexus_bridges_core/src/transfer/pickers.dart';
import 'package:nexus_bridges_core/src/transfer/receiver.dart';
import 'package:nexus_bridges_core/src/transfer/transfer.dart';
import 'package:test/test.dart';

import 'receiver_harness.dart';

const Duration _almost = Duration(milliseconds: 59900);

const Duration _tenth = Duration(milliseconds: 100);

void expectOfferWaiting(RawReply? reply, {required bool picker}) {
  expect(reply, isNotNull);
  expect(reply!.status, 202, reason: reply.text);
  expect(reply.json, {'state': 'waiting', 'picker': picker});
}

void expectPollWaiting(RawReply? reply, {required bool picker}) {
  expect(reply, isNotNull);
  expect(reply!.status, 200, reason: reply.text);
  expect(reply.json, {'state': 'waiting', 'picker': picker});
}

void expectUnanswered(RawReply? reply) {
  expect(reply, isNotNull);
  expect(reply!.status, 200, reason: reply.text);
  expect(reply.json, {'state': 'rejected', 'reason': 'unanswered'});
}

final class DirectReceiver {
  DirectReceiver._(this.stack, this.receiver, this.tracker);

  final ReceiverStack stack;
  final TransferReceiver receiver;
  final PickerTracker tracker;

  static Future<DirectReceiver> start({
    required DeviceIdentity identity,
    required List<Peer> peers,
    Duration pollHold = const Duration(milliseconds: 50),
  }) async {
    late TransferReceiver receiver;
    late PickerTracker tracker;
    final stack = await ReceiverStack.start(
      identity: identity,
      peers: peers,
      routesOverride: (s) {
        tracker = PickerTracker(
          clock: s.clock.call,
          onChanged: (open, since) => receiver.pickersChanged(open, since),
        );
        receiver = TransferReceiver(
          paired: s.paired,
          folders: s.store,
          journal: TempJournal(
            JsonFileStore(File('${s.dataDir}\\cleanup.json')),
          ),
          fs: s.platform,
          dataDirPath: s.dataDir,
          clock: s.clock.call,
          pollHold: pollHold,
          picker: NoPicker(),
          pickers: tracker,
          onChanged: () {},
          emit: (_) {},
          log: s.logs.add,
        );
        receiver.start();
        addTearDown(receiver.close);
        return receiver.routes;
      },
    );
    return DirectReceiver._(stack, receiver, tracker);
  }

  IncomingStage? get stage => receiver.incoming?.stage;

  Future<void> advance(Peer peer, String id, Duration total) async {
    var left = total;
    while (left > Duration.zero) {
      final span = left < const Duration(seconds: 10)
          ? left
          : const Duration(seconds: 10);
      stack.clock.advance(span);
      left -= span;
      receiver.tick();
      await stack.wait(peer, id);
    }
    receiver.tick();
  }
}

void main() {
  late DeviceIdentity receiverId;
  late Peer laptop;
  late Peer portatil;

  setUpAll(() {
    receiverId = DeviceIdentity.generate();
    laptop = Peer(DeviceIdentity.generate(), name: 'Laptop');
    portatil = Peer(
      DeviceIdentity.generate(),
      name: 'PORTATIL',
      relation: PeerRelation.foreign,
    );
  });

  group('E74 RF-155 RF-205 RF-218 60 s deadlines', () {
    test('the warning is open at 59.9 s and unanswered at 60 s', () async {
      final s = await ReceiverStack.start(
        identity: receiverId,
        peers: [portatil],
        pollHold: const Duration(milliseconds: 50),
      );
      final id = newTransferId();
      expectOfferWaiting(await s.offer(portatil, transfer: id), picker: false);
      await eventually(() => s.incoming?.stage == IncomingStage.warning);
      await s.advanceWithPolls(portatil, id, _almost);
      await settle();
      expect(s.incoming?.stage, IncomingStage.warning);
      s.clock.advance(_tenth);
      await eventually(() => s.incoming == null, reason: 'warning expired');
      expect(s.coordinator.lastReceived?.outcome, TransferOutcome.unanswered);
      expectUnanswered(await s.wait(portatil, id));
    });

    test('the question with a problem and a caution in between is open at '
        '59.9 s and unanswered at 60 s', () async {
      final picker = HeldPicker();
      final s = await ReceiverStack.start(
        identity: receiverId,
        peers: [laptop],
        remembered: false,
        pollHold: const Duration(milliseconds: 50),
        picker: picker,
      );
      final proposed = '${s.downloadsDir}\\NexusBridges';
      final id = newTransferId();
      expectOfferWaiting(await s.offer(laptop, transfer: id), picker: false);
      await eventually(() => s.incoming?.stage == IncomingStage.folderQuestion);

      await s.advanceWithPolls(laptop, id, const Duration(seconds: 15));
      final run = s.coordinator.chooseOtherFolder(s.sid);
      picker.answer(s.platform.system.startup);
      await run;
      expect(s.incoming?.folder?.problem, FolderProblem.forbidden);

      await s.advanceWithPolls(laptop, id, const Duration(seconds: 15));
      s.platform.noMarkSupport = true;
      await s.coordinator.useProposedFolder(s.sid);
      expect(s.incoming?.folder?.cautionPath, proposed);
      expect(Directory(proposed).existsSync(), isTrue);

      await s.advanceWithPolls(laptop, id, const Duration(milliseconds: 29900));
      await settle();
      expect(s.incoming?.stage, IncomingStage.folderQuestion);
      expect(s.incoming?.folder?.cautionPath, proposed);

      s.clock.advance(_tenth);
      await eventually(() => s.incoming == null, reason: 'question expired');
      expect(s.coordinator.lastReceived?.outcome, TransferOutcome.unanswered);
      expectUnanswered(await s.wait(laptop, id));
      expect(s.store.saved, isEmpty);
      await eventually(
        () => !Directory(proposed).existsSync(),
        reason: 'unused folder removed',
      );
    });
  });

  group('E154 RF-155 RF-205 RF-218 deadlines frozen by a picker (D-10)', () {
    test('the warning does not expire with the file picker open and keeps the '
        '10 s it had left', () async {
      final d = await DirectReceiver.start(
        identity: receiverId,
        peers: [portatil],
      );
      final id = newTransferId();
      expectOfferWaiting(
        await d.stack.offer(portatil, transfer: id),
        picker: false,
      );
      await eventually(() => d.stage == IncomingStage.warning);
      await d.advance(portatil, id, const Duration(seconds: 50));
      expect(d.stage, IncomingStage.warning);

      d.tracker.open();
      await d.advance(portatil, id, const Duration(seconds: 30));
      expect(d.stage, IncomingStage.warning);
      expectPollWaiting(await d.stack.wait(portatil, id), picker: true);
      d.tracker.close();
      expectPollWaiting(await d.stack.wait(portatil, id), picker: false);

      await d.advance(portatil, id, const Duration(milliseconds: 9900));
      expect(d.stage, IncomingStage.warning);
      d.stack.clock.advance(_tenth);
      d.receiver.tick();
      expect(d.receiver.incoming, isNull);
      expect(d.receiver.lastReceived?.outcome, TransferOutcome.unanswered);
      expectUnanswered(await d.stack.wait(portatil, id));
    });

    test('a picker opened before the warning is shown only freezes from the '
        'moment it is shown, and the offer says picker true', () async {
      final d = await DirectReceiver.start(
        identity: receiverId,
        peers: [portatil],
      );
      d.tracker.open();
      d.stack.clock.advance(const Duration(seconds: 5));
      final id = newTransferId();
      expectOfferWaiting(
        await d.stack.offer(portatil, transfer: id),
        picker: true,
      );
      await eventually(() => d.stage == IncomingStage.warning);
      await d.advance(portatil, id, const Duration(seconds: 100));
      expect(d.stage, IncomingStage.warning);
      d.tracker.close();

      await d.advance(portatil, id, _almost);
      expect(d.stage, IncomingStage.warning);
      d.stack.clock.advance(_tenth);
      d.receiver.tick();
      expect(d.receiver.incoming, isNull);
      expect(d.receiver.lastReceived?.outcome, TransferOutcome.unanswered);
    });

    test('two pickers freeze until the last one closes', () async {
      final d = await DirectReceiver.start(
        identity: receiverId,
        peers: [portatil],
      );
      final id = newTransferId();
      expectOfferWaiting(
        await d.stack.offer(portatil, transfer: id),
        picker: false,
      );
      await eventually(() => d.stage == IncomingStage.warning);
      d.tracker.open();
      await d.advance(portatil, id, const Duration(seconds: 20));
      d.tracker.open();
      await d.advance(portatil, id, const Duration(seconds: 20));
      d.tracker.close();
      await d.advance(portatil, id, const Duration(seconds: 20));
      expectPollWaiting(await d.stack.wait(portatil, id), picker: true);
      d.tracker.close();
      await d.advance(portatil, id, _almost);
      expect(d.stage, IncomingStage.warning);
      d.stack.clock.advance(_tenth);
      d.receiver.tick();
      expect(d.receiver.lastReceived?.outcome, TransferOutcome.unanswered);
    });

    test('opening and closing a picker wakes a held wait with the new '
        'flag', () async {
      final d = await DirectReceiver.start(
        identity: receiverId,
        peers: [portatil],
        pollHold: const Duration(seconds: 8),
      );
      final id = newTransferId();
      expectOfferWaiting(
        await d.stack.offer(portatil, transfer: id),
        picker: false,
      );
      await eventually(() => d.stage == IncomingStage.warning);
      final stopwatch = Stopwatch()..start();
      final opened = d.stack.wait(portatil, id);
      await eventually(() => d.stack.handledOn(ApiPaths.transferWait) == 1);
      await settle();
      d.tracker.open();
      expectPollWaiting(await opened, picker: true);
      final closed = d.stack.wait(portatil, id);
      await eventually(() => d.stack.handledOn(ApiPaths.transferWait) == 2);
      await settle();
      d.tracker.close();
      expectPollWaiting(await closed, picker: false);
      expect(stopwatch.elapsed, lessThan(const Duration(seconds: 6)));
    });

    test('20 s without polls still withdraws the warning with a picker '
        'open', () async {
      final d = await DirectReceiver.start(
        identity: receiverId,
        peers: [portatil],
      );
      final id = newTransferId();
      expectOfferWaiting(
        await d.stack.offer(portatil, transfer: id),
        picker: false,
      );
      await eventually(() => d.stage == IncomingStage.warning);
      d.tracker.open();
      d.stack.clock.advance(const Duration(seconds: 20));
      d.receiver.tick();
      expect(d.receiver.incoming, isNull);
      expect(d.receiver.lastReceived, isNull);
      d.tracker.close();
    });

    test('the folder question survives 200 s with the folder picker open and '
        'keeps the 40 s it had left', () async {
      final picker = HeldPicker();
      final s = await ReceiverStack.start(
        identity: receiverId,
        peers: [laptop],
        remembered: false,
        pollHold: const Duration(milliseconds: 50),
        picker: picker,
      );
      final id = newTransferId();
      expectOfferWaiting(await s.offer(laptop, transfer: id), picker: false);
      await eventually(() => s.incoming?.stage == IncomingStage.folderQuestion);
      await s.advanceWithPolls(laptop, id, const Duration(seconds: 20));

      final run = s.coordinator.chooseOtherFolder(s.sid);
      expectPollWaiting(await s.wait(laptop, id), picker: true);
      await s.advanceWithPolls(laptop, id, const Duration(seconds: 200));
      await settle();
      expect(s.incoming?.stage, IncomingStage.folderQuestion);
      expect(s.incoming?.folder?.pickerOpen, isTrue);
      expect(s.coordinator.pickerOpen, isTrue);
      picker.answer(null);
      await run;
      expectPollWaiting(await s.wait(laptop, id), picker: false);

      await s.advanceWithPolls(laptop, id, const Duration(milliseconds: 39900));
      await settle();
      expect(s.incoming?.stage, IncomingStage.folderQuestion);
      s.clock.advance(_tenth);
      await eventually(() => s.incoming == null, reason: 'question expired');
      expect(s.coordinator.lastReceived?.outcome, TransferOutcome.unanswered);
      expectUnanswered(await s.wait(laptop, id));
    });

    test('the folder picker wakes a held wait at once', () async {
      final picker = HeldPicker();
      final s = await ReceiverStack.start(
        identity: receiverId,
        peers: [laptop],
        remembered: false,
        pollHold: const Duration(seconds: 8),
        picker: picker,
      );
      final id = newTransferId();
      expectOfferWaiting(await s.offer(laptop, transfer: id), picker: false);
      await eventually(() => s.incoming?.stage == IncomingStage.folderQuestion);
      final stopwatch = Stopwatch()..start();
      final held = s.wait(laptop, id);
      await eventually(() => s.handledOn(ApiPaths.transferWait) == 1);
      await settle();
      final run = s.coordinator.chooseOtherFolder(s.sid);
      expectPollWaiting(await held, picker: true);
      final again = s.wait(laptop, id);
      await eventually(() => s.handledOn(ApiPaths.transferWait) == 2);
      await settle();
      picker.answer(null);
      await run;
      expectPollWaiting(await again, picker: false);
      expect(stopwatch.elapsed, lessThan(const Duration(seconds: 6)));
    });
  });
}
