import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:nexus_bridges_core/src/identity/identity.dart';
import 'package:nexus_bridges_core/src/pairing/pairing.dart';
import 'package:nexus_bridges_core/src/protocol/protocol.dart';
import 'package:nexus_bridges_core/src/server/server.dart';
import 'package:nexus_bridges_core/src/transfer/transfer.dart';
import 'package:nexus_bridges_core/src/transport/transport.dart';
import 'package:test/test.dart';

import '../server/api_server_harness.dart' show freePort;
import 'transfer_stacks_harness.dart';

Uint8List bytesOf(int length) {
  final data = Uint8List(length);
  for (var i = 0; i < length; i++) {
    data[i] = (i * 31 + 7) & 0xff;
  }
  return data;
}

final RegExp hex32 = RegExp(r'^[0-9a-f]{32}$');

final String rlo = String.fromCharCode(0x202E);

final String replacement = String.fromCharCode(0xFFFD);

Future<(TransferStack, TransferStack)> pairOfStacks({
  PeerRelation senderAtReceiver = PeerRelation.mine,
  bool remembered = true,
  WriteBytes? receiverWrites,
}) async {
  final a = await TransferStack.start(name: 'A', address: hostA);
  final b = await TransferStack.start(
    name: 'B',
    address: hostB,
    remembered: remembered,
    writeBytes: receiverWrites,
  );
  await link(a, b, senderAtReceiver: senderAtReceiver);
  return (a, b);
}

Future<(TransferStack, TransferFace, SendTarget)> stackAndFace() async {
  final a = await TransferStack.start(name: 'A', address: hostA);
  final face = await TransferFace.start();
  await a.trust(face.identity, name: 'Face');
  final target = a.targetAt(
    face.address,
    face.port,
    fingerprint: face.fingerprint,
  );
  return (a, face, target);
}

Completer<T> heldGate<T>(T fallback) {
  final gate = Completer<T>();
  addTearDown(() {
    if (!gate.isCompleted) gate.complete(fallback);
  });
  return gate;
}

Future<HttpsResponse?> rawWait(
  DeviceIdentity from,
  InternetAddress source,
  TransferStack to,
  String transfer,
) => postJson(
  address: to.address,
  port: to.port,
  path: ApiPaths.transferWait,
  json: {'transfer': transfer},
  context: from.clientContext(presentCertificate: true),
  acceptServer: (certificate) =>
      certificateMatches(certificate, to.fingerprint),
  sourceAddress: source,
  timeout: const Duration(seconds: 5),
  maxResponseBytes: Limits.maxTransferBodyBytes,
);

void main() {
  group('E103 RF-134 only on request', () {
    test(
      'two stacks with network and pairing changes never offer anything',
      () async {
        final (a, b) = await pairOfStacks();
        for (var i = 0; i < 15; i++) {
          a.clock.advance(const Duration(seconds: 1));
          b.clock.advance(const Duration(seconds: 1));
          if (i.isEven) {
            await a.server.syncInterfaces(const []);
            await a.server.syncInterfaces([a.iface]);
          } else {
            await b.forget(a.fingerprint);
            await b.trust(a.identity);
          }
          await settle(const Duration(milliseconds: 60));
        }
        expect(a.offersReceived, 0);
        expect(b.offersReceived, 0);
        expect(a.handledTotal, 0);
        expect(b.handledTotal, 0);
        expect(a.picker.fileCalls, 0);
        expect(b.picker.fileCalls, 0);
        expect(a.lastSent, isNull);
        expect(b.lastSent, isNull);
        expect(a.outgoingSeen, isEmpty);
        expect(b.outgoingSeen, isEmpty);
      },
    );
  });

  group('E104 RF-133 the picker is closed', () {
    test(
      'nothing is chosen, nothing is sent and the last send stays',
      () async {
        final (a, b) = await pairOfStacks();
        final lnk = await a.sourceFile('acceso.lnk', bytesOf(16));
        expect(await a.send(b, lnk), SendStart.started);
        final before = a.lastSent;
        expect(before!.outcome, TransferOutcome.blockedType);
        final target = a.targetOf(b);
        a.picker.next = null;
        expect(
          await a.coordinator.sendFile(target, refresh: () => target),
          SendStart.nothingChosen,
        );
        expect(identical(a.lastSent, before), isTrue);
        expect(a.outgoing, isNull);
        expect(a.coordinator.sending, isFalse);
        expect(a.coordinator.busy, isFalse);
        a.picker.next = '';
        expect(
          await a.coordinator.sendFile(target, refresh: () => target),
          SendStart.nothingChosen,
        );
        a.picker
          ..next = lnk
          ..failure = StateError('picker broke');
        expect(
          await a.coordinator.sendFile(target, refresh: () => target),
          SendStart.nothingChosen,
        );
        expect(identical(a.lastSent, before), isTrue);
        expect(a.logs, contains('file picker failed: StateError'));
        await settle();
        expect(b.handledTotal, 0);
        expect(a.picker.fileCalls, 4);
        expect(a.outgoingSeen, isEmpty);
      },
    );
  });

  group('E110 RF-141 already sending', () {
    test(
      'a second send while the picker is open does not open it again',
      () async {
        final (a, b) = await pairOfStacks(
          senderAtReceiver: PeerRelation.foreign,
        );
        final path = await a.sourceFile('informe.pdf', bytesOf(1024));
        final target = a.targetOf(b);
        a.picker
          ..gate = heldGate<void>(null)
          ..next = path;
        final first = a.coordinator.sendFile(target, refresh: () => target);
        await eventually(() => a.picker.fileCalls == 1);
        expect(a.coordinator.sending, isTrue);
        expect(a.coordinator.busy, isTrue);
        expect(a.outgoing, isNull);
        expect(
          await a.coordinator.sendFile(target, refresh: () => target),
          SendStart.alreadySending,
        );
        expect(a.picker.fileCalls, 1);
        a.picker.gate!.complete();
        a.picker.gate = null;
        expect(await first, SendStart.started);
        await a.phase(OutgoingPhase.waiting);
        expect(b.offersReceived, 1);
      },
    );

    test(
      'a second send while one is waiting is refused without the picker',
      () async {
        final (a, b) = await pairOfStacks(
          senderAtReceiver: PeerRelation.foreign,
        );
        final first = await a.sourceFile('informe.pdf', bytesOf(1024));
        final second = await a.sourceFile('otro.pdf', bytesOf(2048));
        expect(await a.send(b, first), SendStart.started);
        await a.phase(OutgoingPhase.waiting);
        final view = a.outgoing;
        expect(await a.send(b, second), SendStart.alreadySending);
        expect(a.picker.fileCalls, 1);
        expect(a.outgoing, view);
        expect(a.outgoing!.fileName, 'informe.pdf');
        expect(a.lastSent, isNull);
        await settle();
        expect(b.offersReceived, 1);
      },
    );
  });

  group('E164 RF-132 RF-240 after the file is chosen', () {
    test(
      'unpaired while the picker was open ends as unpaired without an offer',
      () async {
        final (a, b) = await pairOfStacks();
        final path = await a.sourceFile('informe.pdf', bytesOf(1024));
        final target = a.targetOf(b);
        a.picker
          ..gate = heldGate<void>(null)
          ..next = path;
        final start = a.coordinator.sendFile(target, refresh: () => target);
        await eventually(() => a.picker.fileCalls == 1);
        await a.forget(b.fingerprint);
        a.picker.gate!.complete();
        expect(await start, SendStart.started);
        final result = a.lastSent!;
        expect(result.direction, TransferDirection.outgoing);
        expect(result.outcome, TransferOutcome.unpaired);
        expect(result.peerFingerprint, b.fingerprint);
        expect(result.peerName, isNull);
        expect(result.fileName, 'informe.pdf');
        expect(result.canReveal, isFalse);
        expect(a.outgoing, isNull);
        expect(a.coordinator.sending, isFalse);
        await settle();
        expect(a.outgoingSeen, isEmpty);
        expect(a.platform.dangerousAsked, isEmpty);
        expect(b.handledTotal, 0);
      },
    );

    test('a target without address after picking ends as no contact without an offer', () async {
      final (a, b) = await pairOfStacks();
      final path = await a.sourceFile('informe.pdf', bytesOf(1024));
      a.picker.next = path;
      expect(
        await a.coordinator.sendFile(a.targetOf(b), refresh: () => null),
        SendStart.started,
      );
      final result = a.lastSent!;
      expect(result.outcome, TransferOutcome.noContact);
      expect(result.peerName, 'Sobremesa');
      expect(a.outgoing, isNull);
      await settle();
      expect(a.outgoingSeen, isEmpty);
      expect(b.handledTotal, 0);
    });

    test('a refresh that throws ends as no contact', () async {
      final (a, b) = await pairOfStacks();
      final path = await a.sourceFile('informe.pdf', bytesOf(1024));
      a.picker.next = path;
      expect(
        await a.coordinator.sendFile(
          a.targetOf(b),
          refresh: () => throw StateError('registry'),
        ),
        SendStart.started,
      );
      expect(a.lastSent!.outcome, TransferOutcome.noContact);
      expect(a.logs, contains('send target refresh failed: StateError'));
      await settle();
      expect(b.handledTotal, 0);
    });

    test(
      'closing the coordinator with the picker open starts nothing',
      () async {
        final (a, b) = await pairOfStacks();
        final path = await a.sourceFile('informe.pdf', bytesOf(1024));
        final target = a.targetOf(b);
        a.picker
          ..gate = heldGate<void>(null)
          ..next = path;
        final start = a.coordinator.sendFile(target, refresh: () => target);
        await eventually(() => a.picker.fileCalls == 1);
        await a.coordinator.close();
        a.picker.gate!.complete();
        expect(await start, SendStart.nothingChosen);
        expect(a.lastSent, isNull);
        expect(a.outgoing, isNull);
        await settle();
        expect(b.handledTotal, 0);
      },
    );

    test('the refreshed target is the one that gets the offer', () async {
      final (a, b) = await pairOfStacks();
      final path = await a.sourceFile('informe.pdf', bytesOf(1024));
      final stale = a.targetAt(
        b.address,
        await freePort(address: b.address),
        fingerprint: b.fingerprint,
      );
      expect(
        await a.sendTo(stale, path, refresh: () => a.targetOf(b)),
        SendStart.started,
      );
      expect((await a.sentResult()).outcome, TransferOutcome.saved);
      expect(b.offersReceived, 1);
      expect(b.handledOn(ApiPaths.transferUpload), 1);
    });
  });

  group('E113 RF-213 the peer leaving the view does not cut the send', () {
    test('refresh is asked once and the send goes on to the end without '
        'it', () async {
      final (a, b) = await pairOfStacks(senderAtReceiver: PeerRelation.foreign);
      final path = await a.sourceFile('informe.pdf', bytesOf(1024));
      final target = a.targetOf(b);
      var visible = true;
      var refreshes = 0;
      expect(
        await a.sendTo(
          target,
          path,
          refresh: () {
            refreshes++;
            return visible ? target : null;
          },
        ),
        SendStart.started,
      );
      visible = false;
      await a.phase(OutgoingPhase.waiting);
      await eventually(() => b.incoming?.stage == IncomingStage.warning);
      b.coordinator.answerWarning(b.incoming!.sessionId, accept: true);
      expect((await a.sentResult()).outcome, TransferOutcome.saved);
      expect(refreshes, 1);
      expect(b.lastReceived!.outcome, TransferOutcome.saved);
    });
  });

  group('E105 RF-211 RF-212 [SEG] name and type before preparing', () {
    test('a blocked type is refused without reading it', () async {
      final (a, b) = await pairOfStacks();
      final path = await a.sourceFile('x.lnk', bytesOf(64));
      await lockExclusively(path);
      expect(await a.send(b, path), SendStart.started);
      final result = a.lastSent!;
      expect(result.outcome, TransferOutcome.blockedType);
      expect(result.fileName, 'x.lnk');
      expect(result.peerName, 'Sobremesa');
      expect(a.outgoing, isNull);
      expect(a.coordinator.sending, isFalse);
      await settle();
      expect(a.outgoingSeen, isEmpty);
      expect(a.platform.dangerousAsked, isEmpty);
      expect(b.handledTotal, 0);
    });

    test(
      'a name with U+202E is refused as invalid without reading it',
      () async {
        final (a, b) = await pairOfStacks();
        final path = await a.sourceFile('factura${rlo}fdp.exe', bytesOf(64));
        await lockExclusively(path);
        expect(await a.send(b, path), SendStart.started);
        final result = a.lastSent!;
        expect(result.outcome, TransferOutcome.invalidName);
        expect(result.fileName, 'factura${replacement}fdp.exe');
        expect(result.fileName, isNot(contains(rlo)));
        expect(result.isProgram, isTrue);
        expect(a.outgoing, isNull);
        await settle();
        expect(a.outgoingSeen, isEmpty);
        expect(a.platform.dangerousAsked, isEmpty);
        expect(b.handledTotal, 0);
      },
    );

    test('a reserved name is refused before touching the disk', () async {
      final (a, b) = await pairOfStacks();
      expect(await a.send(b, '${a.sourceDir}\\CON.txt'), SendStart.started);
      expect(a.lastSent!.outcome, TransferOutcome.invalidName);
      await settle();
      expect(a.outgoingSeen, isEmpty);
      expect(b.handledTotal, 0);
    });
  });

  group('E106 RF-135 RF-136 RF-138 preparing', () {
    test(
      'a 3 MiB file is prepared and offered with its size and digest',
      () async {
        final (a, b) = await pairOfStacks();
        final typeGate = heldGate<void>(null);
        a.platform.dangerous = (_) => typeGate.future.then((_) => false);
        final data = bytesOf(3 * 1024 * 1024);
        final path = await a.sourceFile('informe.pdf', data);
        expect(await a.send(b, path), SendStart.started);
        final preparing = a.outgoing!;
        expect(preparing.phase, OutgoingPhase.preparing);
        expect(preparing.size, 0);
        expect(preparing.fileName, 'informe.pdf');
        expect(preparing.peerFingerprint, b.fingerprint);
        expect(preparing.peerName, 'Sobremesa');
        expect(preparing.isProgram, isFalse);
        expect(preparing.sentBytes, 0);
        expect(preparing.cancelling, isFalse);
        expect(a.coordinator.sending, isTrue);
        expect(a.coordinator.busy, isTrue);
        await settle(const Duration(milliseconds: 300));
        expect(a.outgoing!.phase, OutgoingPhase.preparing);
        expect(b.offersReceived, 0);
        typeGate.complete();
        expect((await a.sentResult()).outcome, TransferOutcome.saved);
        final offers = b.bodiesOn(ApiPaths.transferOffer);
        expect(offers, hasLength(1));
        final offer = offers.single;
        expect(offer.keys.toSet(), {
          'protocol',
          'transfer',
          'name',
          'size',
          'sha256',
        });
        expect(offer['protocol'], protocolVersion);
        expect(offer['transfer'], matches(hex32));
        expect(offer['name'], 'informe.pdf');
        expect(offer['size'], 3 * 1024 * 1024);
        expect(offer['sha256'], sha256.convert(data).toString());
        expect(
          a.phasesSeen.toSet(),
          containsAll([OutgoingPhase.preparing, OutgoingPhase.uploading]),
        );
        for (final view in a.outgoingSeen) {
          expect(
            view.size,
            view.phase == OutgoingPhase.preparing ? 0 : 3 * 1024 * 1024,
          );
        }
        expect(b.incomingSeen, isNotEmpty);
        expect(b.incomingSeen.map((v) => v.size).toSet(), {3 * 1024 * 1024});
        expect(b.lastReceived!.outcome, TransferOutcome.saved);
      },
    );

    test('cancelling while preparing ends at once as cancelled here', () async {
      final (a, b) = await pairOfStacks();
      a.platform.dangerous = (_) => heldGate<bool>(false).future;
      final path = await a.sourceFile('informe.pdf', bytesOf(64 * 1024));
      expect(await a.send(b, path), SendStart.started);
      expect(a.outgoing!.phase, OutgoingPhase.preparing);
      a.coordinator.cancelOutgoing();
      expect(a.outgoing, isNull);
      expect(a.coordinator.sending, isFalse);
      final result = a.lastSent!;
      expect(result.outcome, TransferOutcome.cancelledHere);
      expect(result.outcome.kind, TransferResultKind.cancelled);
      await settle(const Duration(milliseconds: 1300));
      expect(identical(a.lastSent, result), isTrue);
      expect(b.handledTotal, 0);
    });

    test('cancelling during the digest of a big file sends nothing', () async {
      final (a, b) = await pairOfStacks();
      final path = await a.sourceFile('video.mp4', bytesOf(48 * 1024 * 1024));
      expect(await a.send(b, path), SendStart.started);
      expect(a.outgoing!.phase, OutgoingPhase.preparing);
      a.coordinator.cancelOutgoing();
      expect(a.lastSent!.outcome, TransferOutcome.cancelledHere);
      await settle(const Duration(milliseconds: 1500));
      expect(a.lastSent!.outcome, TransferOutcome.cancelledHere);
      expect(a.outgoing, isNull);
      expect(b.handledTotal, 0);
      await eventually(() {
        try {
          File(path).deleteSync();
          return true;
        } on FileSystemException {
          return false;
        }
      }, reason: 'the source is released');
    });
  });

  group('E107 RF-137 unreadable source', () {
    test('a file locked by another program ends as unreadable', () async {
      final (a, b) = await pairOfStacks();
      final path = await a.sourceFile('informe.pdf', bytesOf(4096));
      await lockExclusively(path);
      expect(await a.send(b, path), SendStart.started);
      final result = await a.sentResult();
      expect(result.outcome, TransferOutcome.unreadable);
      expect(result.fileName, 'informe.pdf');
      expect(a.phasesSeen.toSet(), {OutgoingPhase.preparing});
      await settle();
      expect(b.handledTotal, 0);
    });

    test(
      'a file that disappeared before preparing ends as unreadable',
      () async {
        final (a, b) = await pairOfStacks();
        expect(
          await a.send(b, '${a.sourceDir}\\ya-no-esta.pdf'),
          SendStart.started,
        );
        expect((await a.sentResult()).outcome, TransferOutcome.unreadable);
        await settle();
        expect(b.handledTotal, 0);
      },
    );
  });

  group('E188 [SEG] RF-137 no paths in the records', () {
    test('the unreadable record has the exception type and no path', () async {
      final (a, b) = await pairOfStacks();
      final folderTag = 'nb-e188-${randomHex(8)}';
      final fileTag = 'informe-${randomHex(8)}';
      final folder = Directory('${a.sourceDir}\\$folderTag')..createSync();
      final path = '${folder.path}\\$fileTag.txt';
      await File(path).writeAsBytes(bytesOf(2048), flush: true);
      await lockExclusively(path);
      expect(await a.send(b, path), SendStart.started);
      expect((await a.sentResult()).outcome, TransferOutcome.unreadable);
      await settle();
      final records = [...a.logs, ...b.logs];
      expect(
        records,
        contains(matches(RegExp(r'^send source unreadable: \w*Exception$'))),
      );
      final text = records.join('\n');
      expect(text, isNot(contains(folderTag)));
      expect(text, isNot(contains(fileTag)));
      expect(text, isNot(contains(a.base)));
      final user = Platform.environment['USERNAME'] ?? '';
      if (user.isNotEmpty) {
        expect(text.toLowerCase(), isNot(contains(user.toLowerCase())));
      }
    });

    test('the permit and the path never reach the records, also after the '
        'upload', () async {
      final (a, b) = await pairOfStacks();
      String? granted;
      b.wrappers[ApiPaths.transferOffer] = (call, inner) async {
        final reply = await inner(call);
        granted = reply.json['permit'] as String?;
        return reply;
      };
      final path = await a.sourceFile('informe.pdf', bytesOf(4096));
      expect(await a.send(b, path), SendStart.started);
      expect((await a.sentResult()).outcome, TransferOutcome.saved);
      expect(granted, matches(hex32));
      expect(b.handledOn(ApiPaths.transferUpload), 1);
      await a.coordinator.close();
      await b.coordinator.close();
      final text = [...a.logs, ...b.logs].join('\n');
      expect(text, isNot(contains(granted!)));
      expect(text, isNot(contains(a.sourceDir)));
      expect(text, isNot(contains(b.receiveDir)));
      expect(text, isNot(contains('informe.pdf')));
    });
  });

  group('E108 RF-139 [SEG] fingerprint of the receiver', () {
    test('another identity at the receiver address gets nothing and ends as no contact', () async {
      final (a, b) = await pairOfStacks();
      final c = await TransferStack.start(name: 'C', address: hostC);
      await link(a, c);
      final path = await a.sourceFile('informe.pdf', bytesOf(1024));
      final impostor = a.targetAt(
        c.address,
        c.port,
        fingerprint: b.fingerprint,
      );
      expect(await a.sendTo(impostor, path), SendStart.started);
      final result = await a.sentResult();
      expect(result.outcome, TransferOutcome.noContact);
      expect(result.peerFingerprint, b.fingerprint);
      await settle(const Duration(milliseconds: 400));
      expect(c.handledTotal, 0);
      expect(b.handledTotal, 0);
      expect(c.incomingSeen, isEmpty);
    });
  });

  group('E109 RF-140 no contact', () {
    test('nothing listening ends as no contact quickly', () async {
      final (a, b) = await pairOfStacks();
      final path = await a.sourceFile('informe.pdf', bytesOf(1024));
      final nobody = a.targetAt(
        hostC,
        await freePort(address: hostC),
        fingerprint: b.fingerprint,
      );
      final stopwatch = Stopwatch()..start();
      expect(await a.sendTo(nobody, path), SendStart.started);
      expect((await a.sentResult()).outcome, TransferOutcome.noContact);
      expect(stopwatch.elapsed, lessThan(const Duration(seconds: 5)));
      expect(b.handledTotal, 0);
    });

    test(
      'a server that never talks and a receiver that never answers end in 10 s',
      () async {
        final a = await TransferStack.start(name: 'A', address: hostA);
        final c = await TransferStack.start(name: 'C', address: hostC);
        final silent = await silentServer(hostB);
        final face = await TransferFace.start();
        face.handlers[ApiPaths.transferOffer] = (_) => face.hold();
        final quiet = DeviceIdentity.generate();
        await a.trust(quiet, name: 'Quiet');
        await c.trust(face.identity, name: 'Face');
        final toSilent = a.targetAt(
          hostB,
          silent.port,
          fingerprint: quiet.fingerprint,
        );
        final toFace = c.targetAt(
          face.address,
          face.port,
          fingerprint: face.fingerprint,
        );
        final pathA = await a.sourceFile('informe.pdf', bytesOf(1024));
        final pathC = await c.sourceFile('informe.pdf', bytesOf(1024));
        expect(await a.sendTo(toSilent, pathA), SendStart.started);
        expect(await c.sendTo(toFace, pathC), SendStart.started);
        await a.phase(OutgoingPhase.requesting);
        final sinceA = Stopwatch()..start();
        await c.phase(OutgoingPhase.requesting);
        final sinceC = Stopwatch()..start();
        final results = await Future.wait([
          a.sentResult(limit: const Duration(seconds: 14)),
          c.sentResult(limit: const Duration(seconds: 14)),
        ]);
        for (final result in results) {
          expect(result.outcome, TransferOutcome.noContact);
        }
        expect(sinceA.elapsed, lessThan(const Duration(seconds: 11)));
        expect(sinceC.elapsed, lessThan(const Duration(seconds: 11)));
        expect(sinceA.elapsed, greaterThan(const Duration(milliseconds: 9500)));
        await eventually(() => face.count(ApiPaths.transferCancel) == 1);
        final offer = face.bodiesOn(ApiPaths.transferOffer).single;
        expect(face.bodiesOn(ApiPaths.transferCancel).single, {
          'transfer': offer['transfer'],
          'reason': 'no_contact',
        });
      },
      timeout: const Timeout(Duration(seconds: 45)),
    );
  });

  group('E111 RF-153 waiting for the decision', () {
    test(
      'a foreign receiver warns and the sender waits until it accepts',
      () async {
        final (a, b) = await pairOfStacks(
          senderAtReceiver: PeerRelation.foreign,
        );
        final stopwatch = Stopwatch()..start();
        final arrivals = <Duration>[];
        b.wrappers[ApiPaths.transferWait] = (call, inner) {
          arrivals.add(stopwatch.elapsed);
          return inner(call);
        };
        final path = await a.sourceFile('informe.pdf', bytesOf(1536));
        expect(await a.send(b, path), SendStart.started);
        await a.phase(OutgoingPhase.waiting);
        await eventually(() => b.incoming?.stage == IncomingStage.warning);
        final waiting = a.outgoing!;
        expect(waiting.size, 1536);
        expect(waiting.cancelling, isFalse);
        expect(waiting.peerName, 'Sobremesa');
        await eventually(
          () => arrivals.length >= 3,
          reason: 'three waits while the warning is open',
        );
        expect(a.outgoing!.phase, OutgoingPhase.waiting);
        expect(a.lastSent, isNull);
        for (var i = 1; i < arrivals.length; i++) {
          expect(
            arrivals[i] - arrivals[i - 1],
            greaterThan(const Duration(milliseconds: 900)),
            reason: 'gap between wait ${i - 1} and wait $i',
          );
        }
        b.coordinator.answerWarning(b.incoming!.sessionId, accept: true);
        final result = await a.sentResult();
        expect(result.outcome, TransferOutcome.saved);
        expect(a.phasesSeen, contains(OutgoingPhase.uploading));
        expect(b.lastReceived!.outcome, TransferOutcome.saved);
        expect(a.coordinator.sending, isFalse);
      },
    );

    test('a declined warning ends as declined on both', () async {
      final (a, b) = await pairOfStacks(senderAtReceiver: PeerRelation.foreign);
      final path = await a.sourceFile('informe.pdf', bytesOf(1536));
      expect(await a.send(b, path), SendStart.started);
      await a.phase(OutgoingPhase.waiting);
      await eventually(() => b.incoming?.stage == IncomingStage.warning);
      b.coordinator.answerWarning(b.incoming!.sessionId, accept: false);
      final result = await a.sentResult();
      expect(result.outcome, TransferOutcome.declined);
      expect(result.outcome.kind, TransferResultKind.rejected);
      expect(b.lastReceived!.outcome, TransferOutcome.declined);
    });

    test('a warning nobody answers ends as unanswered', () async {
      final (a, b) = await pairOfStacks(senderAtReceiver: PeerRelation.foreign);
      final path = await a.sourceFile('informe.pdf', bytesOf(1536));
      expect(await a.send(b, path), SendStart.started);
      await a.phase(OutgoingPhase.waiting);
      await eventually(() => b.incoming?.stage == IncomingStage.warning);
      b.clock.advance(Limits.transferPromptTimeout);
      expect((await a.sentResult()).outcome, TransferOutcome.unanswered);
    });

    test('a receiver busy with another send ends as busy', () async {
      final (a, b) = await pairOfStacks(senderAtReceiver: PeerRelation.foreign);
      final c = await TransferStack.start(name: 'C', address: hostC);
      await link(c, b);
      final pathA = await a.sourceFile('informe.pdf', bytesOf(1536));
      final pathC = await c.sourceFile('otro.pdf', bytesOf(1536));
      expect(await a.send(b, pathA), SendStart.started);
      await a.phase(OutgoingPhase.waiting);
      expect(await c.send(b, pathC), SendStart.started);
      expect((await c.sentResult()).outcome, TransferOutcome.busy);
      expect(a.outgoing!.phase, OutgoingPhase.waiting);
    });

    test('a recent rejection ends as declined without a new warning', () async {
      final (a, b) = await pairOfStacks(senderAtReceiver: PeerRelation.foreign);
      final path = await a.sourceFile('informe.pdf', bytesOf(1536));
      expect(await a.send(b, path), SendStart.started);
      await eventually(() => b.incoming?.stage == IncomingStage.warning);
      b.coordinator.answerWarning(b.incoming!.sessionId, accept: false);
      final first = await a.sentResult();
      final warnings = b.incomingSeen.length;
      expect(await a.send(b, path), SendStart.started);
      final second = await a.sentResult(after: first);
      expect(second.outcome, TransferOutcome.declined);
      await settle();
      expect(b.incomingSeen.length, warnings);
      expect(b.incoming, isNull);
    });
  });

  group('cancelOutgoing before the acceptance (RF-153, RF-156)', () {
    test('while waiting it ends at once and withdraws the warning', () async {
      final (a, b) = await pairOfStacks(senderAtReceiver: PeerRelation.foreign);
      final path = await a.sourceFile('informe.pdf', bytesOf(1536));
      expect(await a.send(b, path), SendStart.started);
      await a.phase(OutgoingPhase.waiting);
      await eventually(() => b.incoming?.stage == IncomingStage.warning);
      a.coordinator.cancelOutgoing();
      expect(a.outgoing, isNull);
      expect(a.coordinator.sending, isFalse);
      expect(a.lastSent!.outcome, TransferOutcome.cancelledHere);
      await eventually(
        () => b.events.whereType<PeerCancelledTransfer>().isNotEmpty,
      );
      final notice = b.events.whereType<PeerCancelledTransfer>().single;
      expect(notice.peerFingerprint, a.fingerprint);
      expect(notice.peerName, 'Laptop');
      expect(b.incoming, isNull);
      expect(b.lastReceived, isNull);
      final offer = b.bodiesOn(ApiPaths.transferOffer).single;
      expect(b.bodiesOn(ApiPaths.transferCancel).single, {
        'transfer': offer['transfer'],
        'reason': 'cancelled',
      });
      expect(a.outgoingSeen.where((v) => v.cancelling), isEmpty);
    });

    test('while requesting it ends at once and sends the cancel', () async {
      final (a, b) = await pairOfStacks();
      final offerGate = heldGate<void>(null);
      b.wrappers[ApiPaths.transferOffer] = (call, inner) async {
        await offerGate.future;
        return inner(call);
      };
      final path = await a.sourceFile('informe.pdf', bytesOf(1536));
      expect(await a.send(b, path), SendStart.started);
      await a.phase(OutgoingPhase.requesting);
      await eventually(() => b.offersReceived == 1);
      a.coordinator.cancelOutgoing();
      expect(a.outgoing, isNull);
      final result = a.lastSent!;
      expect(result.outcome, TransferOutcome.cancelledHere);
      await eventually(() => b.handledOn(ApiPaths.transferCancel) == 1);
      expect(b.bodiesOn(ApiPaths.transferCancel).single['reason'], 'cancelled');
      offerGate.complete();
      await settle(const Duration(milliseconds: 400));
      expect(identical(a.lastSent, result), isTrue);
      expect(b.incoming, isNull);
      expect(b.lastReceived, isNull);
    });

    test('cancelling with nothing in progress does nothing', () async {
      final (a, _) = await pairOfStacks();
      a.coordinator.cancelOutgoing();
      expect(a.lastSent, isNull);
      expect(a.outgoing, isNull);
    });
  });

  group('E163 RF-140 RF-240 the offer reply is lost', () {
    test('the sender ends as no contact and the receiver withdraws without a result', () async {
      final a = await TransferStack.start(name: 'A', address: hostA);
      final b = await TransferStack.start(name: 'B', address: hostB);
      final c = await TransferStack.start(name: 'C', address: hostC);
      final d = await TransferStack.start(
        name: 'D',
        address: InternetAddress('127.0.0.15'),
      );
      await link(a, b, senderAtReceiver: PeerRelation.foreign);
      await link(c, d);
      final release = heldGate<void>(null);
      final lost = <String, ApiReply>{};
      for (final receiver in [b, d]) {
        receiver.wrappers[ApiPaths.transferOffer] = (call, inner) async {
          final reply = await inner(call);
          lost[receiver.name] = reply;
          await reply.afterResponse?.call();
          await release.future;
          return ApiReply(reply.status, reply.json);
        };
      }
      final pathA = await a.sourceFile('informe.pdf', bytesOf(1536));
      final pathC = await c.sourceFile('informe.pdf', bytesOf(1536));
      expect(await a.send(b, pathA), SendStart.started);
      expect(await c.send(d, pathC), SendStart.started);
      await eventually(() => b.incoming?.stage == IncomingStage.warning);
      await eventually(() => d.incoming?.stage == IncomingStage.waitingData);
      expect(lost['B']!.status, 202);
      expect(lost['D']!.status, 200);
      final results = await Future.wait([
        a.sentResult(limit: const Duration(seconds: 14)),
        c.sentResult(limit: const Duration(seconds: 14)),
      ]);
      for (final result in results) {
        expect(result.outcome, TransferOutcome.noContact);
      }
      for (final receiver in [b, d]) {
        await eventually(
          () => receiver.events.whereType<PeerCancelledTransfer>().isNotEmpty,
          reason: '${receiver.name} notice',
        );
        expect(receiver.incoming, isNull);
        expect(receiver.lastReceived, isNull);
        final offer = receiver.bodiesOn(ApiPaths.transferOffer).single;
        expect(receiver.bodiesOn(ApiPaths.transferCancel).single, {
          'transfer': offer['transfer'],
          'reason': 'no_contact',
        });
      }
      final transfer =
          d.bodiesOn(ApiPaths.transferOffer).single['transfer']! as String;
      final after = await rawWait(c.identity, c.address, d, transfer);
      expect(after, isNotNull);
      expect(after!.status, 200);
      expect(jsonDecode(utf8.decode(after.body)), {'state': 'cancelled'});
      release.complete();
    }, timeout: const Timeout(Duration(seconds: 45)));
  });

  group('offer answers (A19 and punto 63)', () {
    test('each answer to the offer gives its outcome', () async {
      final (a, face, target) = await stackAndFace();
      final path = await a.sourceFile('informe.pdf', bytesOf(1024));
      final grant = randomHex(16);
      final cases = <(FaceAnswer, TransferOutcome)>[
        ((409, {'error': 'busy'}), TransferOutcome.busy),
        ((429, {'error': 'rate_limited'}), TransferOutcome.busy),
        ((503, {'error': 'unavailable'}), TransferOutcome.busy),
        ((403, {'error': 'declined'}), TransferOutcome.declined),
        ((403, {'error': 'forbidden'}), TransferOutcome.noContact),
        ((400, {'error': 'incompatible'}), TransferOutcome.incompatible),
        ((413, {'error': 'too_large'}), TransferOutcome.incompatible),
        ((422, {'error': 'invalid_name'}), TransferOutcome.invalidName),
        ((422, {'error': 'path_too_long'}), TransferOutcome.pathTooLong),
        ((415, {'error': 'blocked_type'}), TransferOutcome.blockedType),
        ((507, {'error': 'no_space'}), TransferOutcome.noSpace),
        ((500, {'error': 'internal'}), TransferOutcome.noContact),
        ((404, {'error': 'not_found'}), TransferOutcome.noContact),
        (
          (200, {'state': 'waiting', 'picker': false}),
          TransferOutcome.noContact,
        ),
        (
          (202, {'state': 'accepted', 'permit': grant}),
          TransferOutcome.noContact,
        ),
        ((200, {'state': 'accepted'}), TransferOutcome.noContact),
        ((202, {'state': 'waiting'}), TransferOutcome.noContact),
        (
          (200, {'state': 'rejected', 'reason': 'declined'}),
          TransferOutcome.noContact,
        ),
      ];
      TransferResultView? previous;
      for (final (answer, outcome) in cases) {
        face.handlers[ApiPaths.transferOffer] = (_) => answer;
        expect(await a.sendTo(target, path), SendStart.started);
        final result = await a.sentResult(after: previous);
        expect(result.outcome, outcome, reason: '${answer.$1} ${answer.$2}');
        previous = result;
      }
      expect(face.count(ApiPaths.transferOffer), cases.length);
      expect(face.count(ApiPaths.transferWait), 0);
      expect(face.count(ApiPaths.transferCancel), 0);
      expect(a.logs.join('\n'), isNot(contains(grant)));
    });

    test('an immediate acceptance uploads at once with the permit and ends '
        'with the answer of the upload', () async {
      final (a, face, target) = await stackAndFace();
      final grant = randomHex(16);
      face.handlers[ApiPaths.transferOffer] = (_) =>
          (200, {'state': 'accepted', 'permit': grant});
      final data = bytesOf(1024);
      final path = await a.sourceFile('informe.pdf', data);
      expect(await a.sendTo(target, path), SendStart.started);
      final result = await a.sentResult();
      expect(result.outcome, TransferOutcome.saved);
      expect(a.phasesSeen, contains(OutgoingPhase.uploading));
      expect(face.calls.take(2).map((c) => c.path), [
        ApiPaths.transferOffer,
        ApiPaths.transferUpload,
      ]);
      final offer = face.bodiesOn(ApiPaths.transferOffer).single;
      final upload = face.uploads.single;
      expect(upload.transfer, offer['transfer']);
      expect(upload.permit, grant);
      expect(upload.contentLength, 1024);
      expect(upload.received.toBytes(), data);
      expect(a.logs.join('\n'), isNot(contains(grant)));
    });
  });

  group('wait answers (A19 and punto 63)', () {
    test('each answer to the wait gives its outcome', () async {
      final (a, face, target) = await stackAndFace();
      final path = await a.sourceFile('informe.pdf', bytesOf(1024));
      final cases = <(FaceAnswer, TransferOutcome)>[
        (
          (200, {'state': 'rejected', 'reason': 'declined'}),
          TransferOutcome.declined,
        ),
        (
          (200, {'state': 'rejected', 'reason': 'unanswered'}),
          TransferOutcome.unanswered,
        ),
        (
          (200, {'state': 'rejected', 'reason': 'no_folder'}),
          TransferOutcome.noFolder,
        ),
        (
          (200, {'state': 'rejected', 'reason': 'no_space'}),
          TransferOutcome.noSpace,
        ),
        (
          (200, {'state': 'rejected', 'reason': 'path_too_long'}),
          TransferOutcome.pathTooLong,
        ),
        ((200, {'state': 'cancelled'}), TransferOutcome.cancelledByPeer),
        ((404, {'error': 'not_found'}), TransferOutcome.noContact),
        ((401, {'error': 'unauthorized'}), TransferOutcome.noContact),
        ((500, {'error': 'internal'}), TransferOutcome.noContact),
        ((200, {'state': 'uploading'}), TransferOutcome.noContact),
        ((200, {'state': 'waiting'}), TransferOutcome.noContact),
        ((200, {'state': 'accepted'}), TransferOutcome.noContact),
        (
          (200, {'state': 'rejected', 'reason': 'whatever'}),
          TransferOutcome.noContact,
        ),
      ];
      TransferResultView? previous;
      for (final (answer, outcome) in cases) {
        face.handlers[ApiPaths.transferWait] = (_) => answer;
        expect(await a.sendTo(target, path), SendStart.started);
        final result = await a.sentResult(after: previous);
        expect(result.outcome, outcome, reason: '${answer.$1} ${answer.$2}');
        previous = result;
      }
    });

    test('a 429 and a lost wait reply are retried after a second', () async {
      final (a, face, target) = await stackAndFace();
      final grant = randomHex(16);
      final stamps = <Duration>[];
      final stopwatch = Stopwatch()..start();
      face.handlers[ApiPaths.transferWait] = (_) {
        stamps.add(stopwatch.elapsed);
        return switch (stamps.length) {
          1 => (429, {'error': 'rate_limited'}),
          2 => null,
          _ => (200, {'state': 'accepted', 'permit': grant}),
        };
      };
      var uploadAt = Duration.zero;
      face.onUpload = (request, upload) async {
        uploadAt = stopwatch.elapsed;
        await upload.readAll(request);
        return savedAnswer;
      };
      final path = await a.sourceFile('informe.pdf', bytesOf(1024));
      expect(await a.sendTo(target, path), SendStart.started);
      final result = await a.sentResult(limit: const Duration(seconds: 10));
      expect(result.outcome, TransferOutcome.saved);
      expect(stamps.length, greaterThanOrEqualTo(3));
      expect(
        stamps[1] - stamps[0],
        greaterThan(const Duration(milliseconds: 900)),
      );
      expect(
        stamps[2] - stamps[1],
        greaterThan(const Duration(milliseconds: 900)),
      );
      expect(uploadAt, greaterThanOrEqualTo(stamps[2]));
      expect(face.uploads.single.permit, grant);
      expect(a.logs.join('\n'), isNot(contains(grant)));
    });

    test('every wait carries the transfer of the offer', () async {
      final (a, face, target) = await stackAndFace();
      final path = await a.sourceFile('informe.pdf', bytesOf(1024));
      expect(await a.sendTo(target, path), SendStart.started);
      await a.phase(OutgoingPhase.waiting);
      await face.moreWaits(3);
      final offer = face.bodiesOn(ApiPaths.transferOffer).single;
      for (final wait in face.bodiesOn(ApiPaths.transferWait)) {
        expect(wait, {'transfer': offer['transfer']});
      }
    });
  });

  group('E112 RF-219 150 s without a decision', () {
    test('a receiver that always waits ends as unanswered at 150 s', () async {
      final (a, face, target) = await stackAndFace();
      final path = await a.sourceFile('informe.pdf', bytesOf(1024));
      expect(await a.sendTo(target, path), SendStart.started);
      await a.phase(OutgoingPhase.waiting);
      a.clock.advance(const Duration(milliseconds: 149900));
      await face.moreWaits(2);
      await settle();
      expect(a.outgoing!.phase, OutgoingPhase.waiting);
      expect(a.lastSent, isNull);
      expect(face.count(ApiPaths.transferCancel), 0);
      a.clock.advance(const Duration(milliseconds: 100));
      final result = await a.sentResult();
      expect(result.outcome, TransferOutcome.unanswered);
      await eventually(() => face.count(ApiPaths.transferCancel) == 1);
      final offer = face.bodiesOn(ApiPaths.transferOffer).single;
      expect(face.bodiesOn(ApiPaths.transferCancel).single, {
        'transfer': offer['transfer'],
        'reason': 'cancelled',
      });
    });
  });

  group('E176 [SEG] RF-219 the wait with the picker open is bounded', () {
    test(
      'time with the picker open is not counted towards the 150 s',
      () async {
        final (a, face, target) = await stackAndFace();
        final path = await a.sourceFile('informe.pdf', bytesOf(1024));
        expect(await a.sendTo(target, path), SendStart.started);
        await a.phase(OutgoingPhase.waiting);
        a.clock.advance(const Duration(seconds: 100));
        face.picker = true;
        await face.moreWaits(2);
        a.clock.advance(const Duration(seconds: 100));
        await face.moreWaits(2);
        a.clock.advance(const Duration(seconds: 100));
        await face.moreWaits(2);
        expect(a.outgoing!.phase, OutgoingPhase.waiting);
        face.picker = false;
        await face.moreWaits(2);
        a.clock.advance(const Duration(milliseconds: 49900));
        await face.moreWaits(2);
        await settle();
        expect(a.outgoing!.phase, OutgoingPhase.waiting);
        expect(a.lastSent, isNull);
        a.clock.advance(const Duration(milliseconds: 100));
        expect((await a.sentResult()).outcome, TransferOutcome.unanswered);
        await eventually(() => face.count(ApiPaths.transferCancel) == 1);
      },
    );

    test('a receiver that always has the picker open ends at 10 min', () async {
      final (a, face, target) = await stackAndFace();
      face.picker = true;
      final path = await a.sourceFile('informe.pdf', bytesOf(1024));
      expect(await a.sendTo(target, path), SendStart.started);
      await a.phase(OutgoingPhase.waiting);
      for (var i = 0; i < 5; i++) {
        a.clock.advance(const Duration(minutes: 1));
        await face.moreWaits(1);
      }
      a.clock.advance(const Duration(minutes: 4, milliseconds: 59900));
      await face.moreWaits(2);
      await settle();
      expect(a.outgoing!.phase, OutgoingPhase.waiting);
      expect(a.lastSent, isNull);
      a.clock.advance(const Duration(milliseconds: 100));
      expect((await a.sentResult()).outcome, TransferOutcome.unanswered);
      await eventually(() => face.count(ApiPaths.transferCancel) == 1);
      expect(
        face.bodiesOn(ApiPaths.transferCancel).single['reason'],
        'cancelled',
      );
    });

    for (final picker in [false, true]) {
      test(
        'cancelOutgoing ends at once in the middle (picker $picker)',
        () async {
          final (a, face, target) = await stackAndFace();
          face.picker = picker;
          final path = await a.sourceFile('informe.pdf', bytesOf(1024));
          expect(await a.sendTo(target, path), SendStart.started);
          await a.phase(OutgoingPhase.waiting);
          a.clock.advance(const Duration(seconds: 120));
          await face.moreWaits(2);
          expect(a.outgoing!.phase, OutgoingPhase.waiting);
          a.coordinator.cancelOutgoing();
          expect(a.outgoing, isNull);
          expect(a.lastSent!.outcome, TransferOutcome.cancelledHere);
          await eventually(() => face.count(ApiPaths.transferCancel) == 1);
          expect(
            face.bodiesOn(ApiPaths.transferCancel).single['reason'],
            'cancelled',
          );
        },
      );
    }
  });

  group('E190 RF-232 program according to Windows on the sender', () {
    test('a type Windows calls dangerous is a program on both sides', () async {
      final (a, b) = await pairOfStacks(senderAtReceiver: PeerRelation.foreign);
      final typeGate = heldGate<bool>(false);
      a.platform.dangerous = (extension) =>
          extension == '.chm' ? typeGate.future : Future.value(false);
      b.platform.dangerous = (extension) async => extension == '.chm';
      bool? programAtOffer;
      b.wrappers[ApiPaths.transferOffer] = (call, inner) {
        programAtOffer = a.outgoing?.isProgram;
        return inner(call);
      };
      final path = await a.sourceFile('x.chm', bytesOf(2048));
      expect(await a.send(b, path), SendStart.started);
      expect(a.outgoing!.phase, OutgoingPhase.preparing);
      expect(a.outgoing!.isProgram, isFalse);
      typeGate.complete(true);
      await eventually(() => a.outgoing?.isProgram == true);
      await a.phase(OutgoingPhase.waiting);
      expect(programAtOffer, isTrue);
      for (final view in a.outgoingSeen) {
        if (view.phase != OutgoingPhase.preparing) {
          expect(view.isProgram, isTrue);
        }
      }
      await eventually(() => b.incoming?.stage == IncomingStage.warning);
      expect(b.incoming!.isProgram, isTrue);
      b.coordinator.answerWarning(b.incoming!.sessionId, accept: false);
      final result = await a.sentResult();
      expect(result.outcome, TransferOutcome.declined);
      expect(result.isProgram, isTrue);
      expect(result.fileName, 'x.chm');
      expect(b.lastReceived!.isProgram, isTrue);
      expect(a.platform.dangerousAsked, ['.chm']);
    });

    test('a type check that never answers falls back after 1 s', () async {
      final (a, b) = await pairOfStacks();
      a.platform.dangerous = (_) => heldGate<bool>(false).future;
      final path = await a.sourceFile('x.chm', bytesOf(2048));
      final stopwatch = Stopwatch()..start();
      expect(await a.send(b, path), SendStart.started);
      await eventually(() => b.offersReceived == 1);
      expect(stopwatch.elapsed, greaterThan(const Duration(milliseconds: 900)));
      expect(stopwatch.elapsed, lessThan(const Duration(seconds: 4)));
      final result = await a.sentResult();
      expect(result.outcome, TransferOutcome.saved);
      expect(result.isProgram, isFalse);
      expect(
        a.outgoingSeen.where((v) => v.phase != OutgoingPhase.preparing),
        everyElement(
          isA<OutgoingTransferView>().having(
            (v) => v.isProgram,
            'isProgram',
            isFalse,
          ),
        ),
      );
    });

    test('the fixed list makes a program without asking Windows', () async {
      final (a, b) = await pairOfStacks(senderAtReceiver: PeerRelation.foreign);
      final path = await a.sourceFile('setup.exe', bytesOf(2048));
      expect(await a.send(b, path), SendStart.started);
      expect(a.outgoing!.isProgram, isTrue);
      await a.phase(OutgoingPhase.waiting);
      expect(a.outgoing!.isProgram, isTrue);
      expect(a.platform.dangerousAsked, isEmpty);
    });
  });

  group('close of the sending side (punto 63)', () {
    test('closing while waiting cancels and the receiver withdraws', () async {
      final (a, b) = await pairOfStacks(senderAtReceiver: PeerRelation.foreign);
      final path = await a.sourceFile('informe.pdf', bytesOf(1536));
      expect(await a.send(b, path), SendStart.started);
      await a.phase(OutgoingPhase.waiting);
      await eventually(() => b.incoming?.stage == IncomingStage.warning);
      final stopwatch = Stopwatch()..start();
      await a.coordinator.close();
      expect(stopwatch.elapsed, lessThan(const Duration(milliseconds: 2500)));
      expect(a.lastSent!.outcome, TransferOutcome.cancelledHere);
      expect(b.handledOn(ApiPaths.transferCancel), 1);
      await eventually(
        () => b.events.whereType<PeerCancelledTransfer>().isNotEmpty,
      );
      expect(b.incoming, isNull);
      expect(b.lastReceived, isNull);
    });

    test('E170 RF-186 closing during the upload cancels first, the receiver '
        'ends it as cancelled by the peer and keeps no temporary', () async {
      final writes = WriteThrottle()..hold();
      final (a, b) = await pairOfStacks(receiverWrites: writes.call);
      final path = await a.sourceFile('informe.pdf', bytesOf(8 * 1024 * 1024));
      expect(await a.send(b, path), SendStart.started);
      await eventually(() => writes.calls >= 1, reason: 'upload started');
      expect(a.outgoing!.phase, OutgoingPhase.uploading);
      final stopwatch = Stopwatch()..start();
      await a.coordinator.close();
      expect(stopwatch.elapsed, lessThan(Limits.transferCloseBudget));
      expect(a.lastSent!.outcome, TransferOutcome.cancelledHere);
      expect(b.handledOn(ApiPaths.transferCancel), 1);
      expect(b.bodiesOn(ApiPaths.transferCancel).single['reason'], 'cancelled');
      writes.open();
      expect(
        (await b.receivedResult()).outcome,
        TransferOutcome.cancelledByPeer,
      );
      expect(b.incoming, isNull);
      await eventually(
        () => !Directory(b.tempSub).existsSync(),
        reason: 'temporary removed',
      );
      expect(Directory(b.receiveDir).listSync(), isEmpty);
    });

    test('closing does not wait for a cancel that never ends', () async {
      final (a, face, target) = await stackAndFace();
      face.handlers[ApiPaths.transferCancel] = (_) => face.hold();
      final path = await a.sourceFile('informe.pdf', bytesOf(1024));
      expect(await a.sendTo(target, path), SendStart.started);
      await a.phase(OutgoingPhase.waiting);
      final stopwatch = Stopwatch()..start();
      await a.coordinator.close();
      expect(stopwatch.elapsed, lessThan(const Duration(milliseconds: 2500)));
      expect(face.count(ApiPaths.transferCancel), 1);
      expect(a.lastSent!.outcome, TransferOutcome.cancelledHere);
    });
  });
}
