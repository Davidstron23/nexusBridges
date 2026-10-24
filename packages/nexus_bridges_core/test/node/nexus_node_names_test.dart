import 'dart:io';

import 'package:nexus_bridges_core/src/node/node.dart';
import 'package:nexus_bridges_core/src/protocol/protocol.dart'
    show Announcement, AnnouncementKind, Limits, protocolVersion;
import 'package:test/test.dart';

import 'two_nodes_harness.dart';

const Duration _expired = Duration(seconds: 31);

Future<void> _forget(TestNode viewer, TestNode gone) async {
  viewer.advance(_expired);
  await viewer.until((s) => !viewer.sees(gone), reason: 'stale entry expired');
}

Future<String?> _savedNameOf(TestNode node, TestNode other) async {
  for (final device in await node.savedPaired()) {
    if (device['fingerprint'] == other.fingerprint) {
      return device['name'] as String?;
    }
  }
  return null;
}

void main() {
  group('names of paired devices (C71, RF-128, RF-129)', () {
    test('B comes back with another name: after its reverification A saves '
        'and shows the new name, and once B is gone again A shows the last '
        'saved one', () async {
      final (a, b) = await twoNodes(nameB: 'Laptop');
      await meet(a, b);
      await pairNodes(a, b);
      expect(await _savedNameOf(a, b), 'Laptop');

      await b.node.shutdown();
      await _forget(a, b);
      final away = a.entryOf(b.fingerprint)!;
      expect(away.visible, isFalse);
      expect(away.paired, isTrue);
      expect(away.displayName, 'Laptop');

      await b.restart(deviceName: 'Laptop Renamed');
      expect(a.entryOf(b.fingerprint)!.displayName, 'Laptop');

      await meet(a, b);
      await a.until(
        (s) => a.entryOf(b.fingerprint)?.displayName == 'Laptop Renamed',
        reason: 'new name shown',
      );
      expect(a.entryOf(b.fingerprint)!.visible, isTrue);
      expect(a.entryOf(b.fingerprint)!.paired, isTrue);
      await eventually(
        () async => await _savedNameOf(a, b) == 'Laptop Renamed',
        reason: 'new name saved',
      );

      await b.node.shutdown();
      await _forget(a, b);
      final gone = a.entryOf(b.fingerprint)!;
      expect(gone.visible, isFalse);
      expect(gone.displayName, 'Laptop Renamed');
    }, timeout: twoNodesTimeout);

    test('a node that starts with saved paired devices lists them at once '
        'as not visible with their saved names (RF-111, RF-129)', () async {
      final (a, b) = await twoNodes(nameB: 'Laptop');
      await meet(a, b);
      await pairNodes(a, b);
      await b.node.shutdown();

      await a.restart();

      await a.until(
        (s) => a.entryOf(b.fingerprint) != null,
        limit: const Duration(seconds: 3),
        reason: 'paired row right after start',
      );
      final entry = a.entryOf(b.fingerprint)!;
      expect(entry.paired, isTrue);
      expect(entry.visible, isFalse);
      expect(entry.displayName, 'Laptop');
      expect(entry.deviceType, isNull);
    }, timeout: twoNodesTimeout);
  });

  group('names only change through a verification (RF-128, D12)', () {
    test('a forged hello from the address of B with another name changes '
        'neither the row nor the saved name (control: a bye from there is '
        'heard and makes A check B, which stays)', () async {
      final (a, b) = await twoNodes(nameB: 'Laptop');
      await meet(a, b);
      await pairNodes(a, b);
      final socket = await RawDatagramSocket.bind(hostB, 0);
      addTearDown(socket.close);
      final forged = Announcement(
        AnnouncementKind.hello,
        DeviceInfo(
          name: 'Forged Name',
          fingerprint: b.fingerprint,
          port: b.port,
          protocol: protocolVersion,
          deviceType: DeviceType.desktop,
        ),
      ).encode();

      for (var i = 0; i < 3; i++) {
        socket.send(forged, hostA, a.udpPort);
        await pause(const Duration(milliseconds: 100));
      }
      await pause();

      expect(a.entryOf(b.fingerprint)!.displayName, 'Laptop');
      expect(await _savedNameOf(a, b), 'Laptop');

      expect(a.timers.createdBy('_verifyGoodbye'), 0);
      socket.send(
        Announcement(AnnouncementKind.bye, b.info).encode(),
        hostA,
        a.udpPort,
      );
      await eventually(
        () => a.timers.createdBy('_verifyGoodbye') > 0,
        reason: 'control: datagrams from that address do arrive',
      );
      await pause();
      expect(a.sees(b), isTrue);
      expect(a.entryOf(b.fingerprint)!.displayName, 'Laptop');
    }, timeout: twoNodesTimeout);

    test('a new name that cannot be saved is still shown, is only logged '
        'and adds no notice', () async {
      final (a, b) = await twoNodes(nameB: 'Laptop');
      await meet(a, b);
      await pairNodes(a, b);
      await b.node.shutdown();
      await _forget(a, b);
      await b.restart(deviceName: 'Laptop Renamed');
      final lock = HeldLock.on(a.pairedFile);

      await meet(a, b);
      await a.until(
        (s) => a.entryOf(b.fingerprint)?.displayName == 'Laptop Renamed',
        reason: 'new name shown',
      );
      await eventually(
        () => a.logs.contains('rename not saved'),
        reason: 'rename failure logged',
      );

      expect(a.state.notices, isEmpty);
      expect(a.state.unsavedChanges, isFalse);
      expect(a.states.where((s) => s.unsavedChanges), isEmpty);
      expect(lock.read(), contains('"Laptop"'));
      expect(a.entryOf(b.fingerprint)!.paired, isTrue);

      lock.release();
      await a.inZone(() => a.node.setMine(b.fingerprint, mine: true));

      final saved = a.pairedFile.readAsStringSync();
      expect(saved, contains('"Laptop Renamed"'));
      expect(saved, contains('"mine"'));
      expect(a.state.unsavedChanges, isFalse);
      expect(a.state.notices, isEmpty);
    }, timeout: twoNodesTimeout);
  });

  group('reinstalled device with the same name (C74, RF-123, RF-125 to '
      'RF-127)', () {
    Future<(TestNode, TestNode, String)> reinstalled() async {
      final (a, b) = await twoNodes(nameB: 'Laptop');
      await meet(a, b);
      await pairNodes(a, b);
      await a.inZone(() => a.node.answerMine(b.fingerprint, mine: true));
      final old = b.fingerprint;
      await b.node.shutdown();
      await Directory('${b.dataDir.path}${sep}identity')
          .delete(recursive: true);
      await _forget(a, b);
      a.advance(Limits.replaceAfterAbsence);
      await b.restart();
      expect(b.fingerprint, isNot(old));
      expect(b.state.identityStatus, IdentityStatus.reset);
      await meet(a, b);
      return (a, b, old);
    }

    test('the new identity is never taken for the old one: its row is not '
        'paired, it warns that it may replace the old one, and its client '
        'certificate is refused while the old one stays paired', () async {
      final (a, b, old) = await reinstalled();

      await a.until(
        (s) => a.entryOf(b.fingerprint)?.possiblyReplaces != null,
        reason: 'warning on the row of the new identity',
      );
      final entry = a.entryOf(b.fingerprint)!;
      expect(entry.paired, isFalse);
      expect(entry.visible, isTrue);
      expect(entry.possiblyReplaces, contains(old.substring(0, 8)));
      expect(a.entryOf(old)!.paired, isTrue);
      expect(a.entryOf(old)!.visible, isFalse);
      final newIdentity = await b.loadIdentity();
      expect(
        await registerWith(
          newIdentity,
          a,
          from: hostB,
          callerName: b.deviceName,
          callerPort: b.port,
        ),
        isNull,
      );
      expect(
        await registerWith(
          newIdentity,
          a,
          from: hostB,
          callerName: b.deviceName,
          callerPort: b.port,
          presentCertificate: false,
        ),
        200,
      );
    }, timeout: twoNodesTimeout);

    test('pairing the new one asks "replace?" before "is it yours?"; '
        'replacing unpairs the old one in memory and in the file and keeps '
        'the "is it yours?" question', () async {
      final (a, b, old) = await reinstalled();

      await pairNodes(a, b);

      final questions = a.state.questions
          .where((q) => q.fingerprint == b.fingerprint)
          .toList();
      expect(questions, hasLength(2));
      final replace = questions.first as ReplaceQuestion;
      expect(replace.oldFingerprint, old);
      expect(replace.oldName, contains(old.substring(0, 8)));
      expect(questions.last, isA<MineQuestion>());
      expect(b.state.questions.whereType<ReplaceQuestion>(), isEmpty);

      await a.inZone(() => a.node.answerReplace(b.fingerprint, replace: true));

      expect(a.entryOf(old), isNull);
      expect(await a.savedPairedFingerprints(), isNot(contains(old)));
      expect(await a.savedPairedFingerprints(), contains(b.fingerprint));
      expect(a.hasPaired(b), isTrue);
      expect(a.state.questions.map((q) => (q.runtimeType, q.fingerprint)), [
        (MineQuestion, b.fingerprint),
      ]);
      expect(a.state.notices, isEmpty);
    }, timeout: twoNodesTimeout);

    test('declining (or closing) the question keeps both paired', () async {
      final (a, b, old) = await reinstalled();
      await pairNodes(a, b);

      await a.inZone(() => a.node.answerReplace(b.fingerprint, replace: false));

      expect(a.entryOf(old)!.paired, isTrue);
      expect(a.hasPaired(b), isTrue);
      expect(
        await a.savedPairedFingerprints(),
        containsAll([old, b.fingerprint]),
      );
      expect(a.state.questions.map((q) => (q.runtimeType, q.fingerprint)), [
        (MineQuestion, b.fingerprint),
      ]);
    }, timeout: twoNodesTimeout);

    test('answerReplace for a device without a replace question unpairs '
        'nothing', () async {
      final (a, b, old) = await reinstalled();
      await pairNodes(a, b);
      await a.inZone(() => a.node.answerReplace(b.fingerprint, replace: false));

      await a.inZone(() => a.node.answerReplace(b.fingerprint, replace: true));
      await a.inZone(() => a.node.answerReplace(old, replace: true));

      expect(a.entryOf(old)!.paired, isTrue);
      expect(a.hasPaired(b), isTrue);
    }, timeout: twoNodesTimeout);
  });
}
