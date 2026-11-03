import 'dart:io';

import 'package:nexus_bridges_core/src/node/node.dart';
import 'package:nexus_bridges_core/src/pairing_flow/pairing_flow.dart'
    show PairStart;
import 'package:test/test.dart';

import 'two_nodes_harness.dart';

File _ignoredFile(TestNode node) =>
    File('${node.dataDir.path}${sep}ignored.json');

void _break(File file) {
  if (file.existsSync()) file.deleteSync();
  Directory(file.path).createSync(recursive: true);
}

void _repair(File file) {
  final dir = Directory(file.path);
  if (dir.existsSync()) dir.deleteSync(recursive: true);
}

Future<void> _ignoreRequestFrom(TestNode initiator, TestNode receiver) async {
  await bothComparing(initiator, receiver);
  receiver.zone.run(() => receiver.node.answerRequest(ReceiverAnswer.ignore));
  await receiver.until(
    (s) => s.ignoredDevices.any((d) => d.fingerprint == initiator.fingerprint),
    reason: 'ignored by ${receiver.deviceName}',
  );
  await _settle(initiator);
}

Future<void> _settle(TestNode node) async {
  await node.until(
    (s) => s.pairing == null || s.pairing!.phase == PairingPhase.finished,
    reason: '${node.deviceName} pairing finished',
  );
  if (node.state.pairing != null) {
    node.zone.run(node.node.dismissPairing);
    await node.until(
      (s) => s.pairing == null,
      reason: '${node.deviceName} pairing dismissed',
    );
  }
}

Future<void> _refusedAttempt(TestNode initiator, TestNode receiver) async {
  final before = receiver.states.length;
  final notices = receiver.state.notices.length;
  expect(
    await initiator.inZone(() => initiator.node.pair(receiver.fingerprint)),
    PairRequestResult.started,
  );
  await initiator.until(
    (s) =>
        s.pairing?.phase == PairingPhase.finished ||
        s.pairing?.phase == PairingPhase.comparing,
    reason: 'the attempt is answered',
  );
  await pause();
  final shown = receiver.states.skip(before).any((s) => s.pairing != null);
  if (initiator.state.pairing?.phase == PairingPhase.comparing) {
    initiator.zone.run(initiator.node.cancelPairing);
  }
  await _settle(initiator);
  await _settle(receiver);
  expect(shown, isFalse, reason: 'the receiver never shows a pairing notice');
  expect(receiver.state.notices, hasLength(notices));
}

void main() {
  group('E816: unignore brings the pairing notice back without resetting the '
      'limits (RF-536 to RF-538, RF-74, RF-109) [SEG]', () {
    test('A ignores B; with B off A lists it, also after a restart; while '
        'ignored B gets no notice; after unignore the notice comes back with '
        'the code, and the four requests made while ignored still count: the '
        'sixth in the window gives none', () async {
      final (a, b) = await twoNodes(nameA: 'Desk PC', nameB: 'Laptop');
      await meet(a, b);

      await _ignoreRequestFrom(b, a);

      final view = a.state.ignoredDevices.single;
      expect(view.fingerprint, b.fingerprint);
      expect(view.name, 'Laptop');
      expect(view.shortFingerprint, b.fingerprint.substring(0, 8));
      expect(view.ignoredAt.isAtSameMomentAs(a.clock), isTrue);

      await b.node.shutdown();
      await pause();
      expect(a.state.ignoredDevices, [view]);
      await a.restart();
      expect(a.state.ignoredDevices, [view]);
      await b.restart();
      await meet(a, b);

      for (var i = 0; i < 4; i++) {
        await _refusedAttempt(b, a);
      }

      await a.inZone(() => a.node.unignore(b.fingerprint));
      expect(a.state.ignoredDevices, isEmpty);
      expect(a.entryOf(b.fingerprint)?.ignored, isFalse);

      expect(
        await b.inZone(() => b.node.pair(a.fingerprint)),
        PairRequestResult.started,
      );
      final asked = await a.until(
        (s) => s.pairing?.phase == PairingPhase.comparing,
        reason: 'A shows the pairing notice again',
      );
      await b.until(
        (s) => s.pairing?.phase == PairingPhase.comparing,
        reason: 'B comparing',
      );
      expect(asked.pairing!.role, PairingRole.receiver);
      expect(asked.pairing!.peerFingerprint, b.fingerprint);
      expect(asked.pairing!.code, isNotNull);
      expect(asked.pairing!.code, b.state.pairing!.code);
      b.zone.run(b.node.cancelPairing);
      await _settle(b);
      await _settle(a);

      await _refusedAttempt(b, a);
      expect(a.state.ignoredDevices, isEmpty);
    }, timeout: const Timeout(Duration(minutes: 3)));

    test('unignore of a device that is not ignored changes nothing and gives '
        'no notice', () async {
      final (a, _) = await twoNodes(nameA: 'Desk PC', nameB: 'Laptop');
      final before = a.state;

      await a.inZone(() => a.node.unignore('AB' * 32));

      expect(a.state.ignoredDevices, isEmpty);
      expect(a.state.notices, before.notices);
    }, timeout: twoNodesTimeout);
  });

  group('E817: unignore that cannot be saved (RF-539, RF-120)', () {
    test('with ignored.json not writable the device leaves the list for the '
        'session with a retryable notice; retrySave saves it once the file is '
        'writable again and the change survives a restart', () async {
      final (a, b) = await twoNodes(nameA: 'Desk PC', nameB: 'Laptop');
      await meet(a, b);
      await _ignoreRequestFrom(b, a);
      final file = _ignoredFile(a);
      await eventually(
        () async =>
            file.existsSync() &&
            (await file.readAsString()).contains(b.fingerprint),
        reason: 'the ignore is saved',
      );
      _break(file);

      await a.inZone(() => a.node.unignore(b.fingerprint));

      expect(a.state.ignoredDevices, isEmpty);
      expect(a.entryOf(b.fingerprint)?.ignored ?? false, isFalse);
      final notices = a.noticesOf(NoticeKind.changeNotSaved);
      expect(notices, hasLength(1));
      expect(notices.single.canRetry, isTrue);
      expect(a.state.unsavedChanges, isTrue);

      await a.inZone(a.node.retrySave);
      expect(a.noticesOf(NoticeKind.changeNotSaved), hasLength(1));

      _repair(file);
      await a.inZone(a.node.retrySave);

      expect(a.noticesOf(NoticeKind.changeNotSaved), isEmpty);
      expect(a.state.unsavedChanges, isFalse);
      expect(await file.readAsString(), isNot(contains(b.fingerprint)));

      await a.restart();
      expect(a.state.ignoredDevices, isEmpty);
    }, timeout: twoNodesTimeout);
  });

  group('E818: unignore sends nothing to the other device (RF-537)', () {
    test('after the ignore, unignore makes no request to the server of the '
        'ignored device', () async {
      late TestNode a;
      CountingPeer? peer;
      for (var attempt = 0; attempt < 5 && peer == null; attempt++) {
        final port = await freePort();
        a = await TestNode.create('Desk PC', hostA);
        a.port = port;
        if (!await a.launch()) {
          await a.node.shutdown();
          continue;
        }
        peer = await CountingPeer.start(address: hostB, port: port);
        if (peer == null) await a.node.shutdown();
      }
      final counting = peer!;
      await a.inZone(
        () => a.node.decideNetwork(homeNetwork, NetworkDecision.trusted),
      );
      bool seesPeer() => a.state.devices.any(
        (d) => d.info.fingerprint == counting.fingerprint,
      );
      for (var i = 0; i < 5 && !seesPeer(); i++) {
        await a.inZone(() => a.node.rescan());
        await pause(const Duration(milliseconds: 100));
      }
      await eventually(seesPeer, reason: 'A sees the peer');

      expect(
        counting.coordinator.tryPair(counting.targetOf(a)),
        PairStart.started,
      );
      await a.until((s) => s.pairing?.phase == PairingPhase.comparing);
      a.zone.run(() => a.node.answerRequest(ReceiverAnswer.ignore));
      await a.until(
        (s) =>
            s.ignoredDevices.any((d) => d.fingerprint == counting.fingerprint),
        reason: 'A ignores the peer',
      );
      await eventually(
        () => counting.coordinator.view?.phase == PairingPhase.finished,
        reason: 'the peer ends',
      );
      await pause(const Duration(seconds: 1));
      final handled = Map<String, int>.of(counting.handled);

      await a.inZone(() => a.node.unignore(counting.fingerprint));
      await pause(const Duration(seconds: 2));

      expect(a.state.ignoredDevices, isEmpty);
      expect(counting.handled, handled);
    }, timeout: twoNodesTimeout);
  });
}
