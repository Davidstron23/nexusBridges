@TestOn('windows')
library;

import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:nexus_bridges_core/src/identity/identity.dart';
import 'package:nexus_bridges_core/src/protocol/protocol.dart';
import 'package:nexus_bridges_core/src/transfer/folders.dart'
    show tempFolderName;
import 'package:nexus_bridges_core/src/transfer/transfer.dart';
import 'package:nexus_bridges_core/src/transport/transport.dart';
import 'package:test/test.dart';

import '../server/api_server_harness.dart' show loopbackInterface;
import 'transfer_stacks_harness.dart';

const int kib = 1024;

const int mib = 1048576;

final InternetAddress secondB = InternetAddress('127.0.0.16');

Uint8List randomBytes(int length, int seed) {
  final random = Random(seed);
  final bytes = Uint8List(length);
  for (var i = 0; i < length; i++) {
    bytes[i] = random.nextInt(256);
  }
  return bytes;
}

Future<(TransferStack, TransferStack)> stacks({
  WriteBytes? receiverWrites,
  bool secondListener = false,
}) async {
  final a = await TransferStack.start(name: 'A', address: hostA);
  final b = await TransferStack.start(
    name: 'B',
    address: hostB,
    writeBytes: receiverWrites,
    extraInterfaces: [
      if (secondListener)
        loopbackInterface(adapterId: 'second', address: secondB.address),
    ],
  );
  await link(a, b);
  return (a, b);
}

final class MarkHold {
  MarkHold(TransferStack stack) {
    stack.platform.mark = call;
    addTearDown(open);
  }

  final Completer<void> reached = Completer<void>();
  final Completer<void> _gate = Completer<void>();

  void open() {
    if (!_gate.isCompleted) _gate.complete();
  }

  Future<bool> call(String path) async {
    if (!reached.isCompleted) reached.complete();
    await _gate.future;
    return realFs.markFromInternet(path);
  }
}

Future<String> sendData(
  TransferStack a,
  TransferStack b,
  String name,
  List<int> data,
) async {
  final path = await a.sourceFile(name, data);
  expect(await a.send(b, path), SendStart.started);
  return path;
}

void main() {
  group('E230 E231 [SEG] PR3-1 unpairing while uploading cuts at once', () {
    test('E230 while uploading with the cancel held 1.9 s by the receiver: '
        'unpaired at once, the body stops and the cancel still '
        'arrives', () async {
      final (a, b) = await stacks(
        receiverWrites: WriteThrottle(delay: const Duration(milliseconds: 3))
            .call,
      );
      b.wrappers[ApiPaths.transferCancel] = (call, inner) async {
        await Future<void>.delayed(const Duration(milliseconds: 1900));
        return inner(call);
      };
      await sendData(a, b, 'grande.bin', randomBytes(64 * mib, 230));
      await eventually(
        () => (b.incoming?.receivedBytes ?? 0) >= 2 * mib,
        reason: 'the upload is flowing',
      );
      var most = 0;
      final sampler = Timer.periodic(const Duration(milliseconds: 1), (_) {
        final received = b.incoming?.receivedBytes;
        if (received != null && received > most) most = received;
      });
      addTearDown(sampler.cancel);
      final at = b.incoming!.receivedBytes;
      final stopwatch = Stopwatch()..start();
      final pending = a.coordinator.peerUnpaired(b.fingerprint);
      expect(a.outgoing, isNull);
      expect(a.lastSent!.outcome, TransferOutcome.unpaired);
      await pending;
      expect(
        stopwatch.elapsed,
        greaterThan(const Duration(milliseconds: 1700)),
      );
      expect(stopwatch.elapsed, lessThan(const Duration(milliseconds: 2600)));
      expect(b.handledOn(ApiPaths.transferCancel), 1);
      expect(b.bodiesOn(ApiPaths.transferCancel).single['reason'], 'cancelled');
      final received = await b.receivedResult();
      sampler.cancel();
      expect(received.outcome.kind, isNot(TransferResultKind.saved));
      expect(most - at, lessThan(mib));
      await eventually(
        () => !Directory(b.tempSub).existsSync(),
        reason: 'temporary removed',
      );
      expect(Directory(b.receiveDir).listSync(), isEmpty);
    }, timeout: const Timeout(Duration(seconds: 60)));

    test('E231 while checking: unpaired at once, the cancel is sent, the call '
        'returns within 2 s and the whole file is still saved (point '
        '77)', () async {
      final (a, b) = await stacks();
      final mark = MarkHold(b);
      final data = randomBytes(256 * kib, 231);
      await sendData(a, b, 'informe.bin', data);
      await mark.reached.future;
      await a.phase(OutgoingPhase.verifying);
      expect(b.incoming!.stage, IncomingStage.verifying);
      final stopwatch = Stopwatch()..start();
      final pending = a.coordinator.peerUnpaired(b.fingerprint);
      expect(a.outgoing, isNull);
      expect(a.lastSent!.outcome, TransferOutcome.unpaired);
      await pending;
      expect(stopwatch.elapsed, lessThan(const Duration(milliseconds: 2600)));
      expect(b.handledOn(ApiPaths.transferCancel), 1);
      await b.coordinator.peerUnpaired(a.fingerprint);
      b.coordinator.interfacesChanged(const {});
      expect(b.incoming?.stage, IncomingStage.verifying);
      mark.open();
      expect((await b.receivedResult()).outcome, TransferOutcome.saved);
      expect(
        File('${b.receiveDir}\\informe.bin').readAsBytesSync(),
        orderedEquals(data),
      );
      expect(a.lastSent!.outcome, TransferOutcome.unpaired);
    });
  });

  group('E232 E233 [SEG] PR3-2 the permit belongs to the interface of the '
      'offer', () {
    test('E232 an upload with the right permit through another listener gets '
        '403, writes nothing and leaves the permit for the good '
        'one', () async {
      final (a, b) = await stacks(secondListener: true);
      String? transfer;
      String? permit;
      b.wrappers[ApiPaths.transferOffer] = (call, inner) async {
        final reply = await inner(call);
        final body = call.json;
        if (body is Map<String, Object?>) {
          transfer = body['transfer'] as String?;
        }
        permit = reply.json['permit'] as String?;
        return reply;
      };
      final hold = Gate<void>(null);
      b.uploadWrapper = (upload, inner) async {
        if (upload.via.id == b.iface.id) await hold.wait();
        return inner(upload);
      };
      final data = randomBytes(256 * kib, 232);
      await sendData(a, b, 'informe.bin', data);
      await hold.reached.future;
      expect(permit, isNotNull);
      expect(b.incoming!.stage, IncomingStage.waitingData);

      final stray = await postStream(
        address: secondB,
        port: b.port,
        path: ApiPaths.transferUpload,
        headers: {
          TransferHeaders.transfer: transfer!,
          TransferHeaders.permit: permit!,
        },
        contentLength: data.length,
        body: Stream.value(data),
        context: a.identity.clientContext(presentCertificate: true),
        acceptServer: (certificate) =>
            certificateMatches(certificate, b.fingerprint),
        sourceAddress: hostA,
        idleTimeout: const Duration(seconds: 10),
        answerTimeout: const Duration(seconds: 10),
      );
      expect(stray, isA<StreamPostAnswered>());
      final response = (stray as StreamPostAnswered).response;
      expect(response.status, 403);
      expect(String.fromCharCodes(response.body), '{"error":"forbidden"}');
      expect(b.handledOn(ApiPaths.transferUpload), 2);
      expect(Directory(b.tempSub).existsSync(), isFalse);
      expect(Directory(b.receiveDir).listSync(), isEmpty);
      expect(b.journal.folders, isEmpty);
      expect(b.incoming!.stage, IncomingStage.waitingData);
      expect(b.lastReceived, isNull);

      hold.open(null);
      expect((await a.sentResult()).outcome, TransferOutcome.saved);
      expect((await b.receivedResult()).outcome, TransferOutcome.saved);
      expect(
        File('${b.receiveDir}\\informe.bin').readAsBytesSync(),
        orderedEquals(data),
      );
      expect(b.logs.join('\n'), isNot(contains(permit!)));
    });

    test('E233 with two listeners, an offer and an upload through the same '
        'one are saved, also through the second one', () async {
      final (a, b) = await stacks(secondListener: true);
      final first = randomBytes(64 * kib, 233);
      await sendData(a, b, 'uno.bin', first);
      final one = await a.sentResult();
      expect(one.outcome, TransferOutcome.saved);
      final second = randomBytes(64 * kib, 234);
      final path = await a.sourceFile('dos.bin', second);
      final viaSecond = a.targetAt(secondB, b.port, fingerprint: b.fingerprint);
      expect(await a.sendTo(viaSecond, path), SendStart.started);
      expect((await a.sentResult(after: one)).outcome, TransferOutcome.saved);
      expect(
        File('${b.receiveDir}\\uno.bin').readAsBytesSync(),
        orderedEquals(first),
      );
      expect(
        File('${b.receiveDir}\\dos.bin').readAsBytesSync(),
        orderedEquals(second),
      );
    });
  });

  group('E234 [SEG] PR3-3 refresh must give the chosen device', () {
    test('a refresh with the target of another paired device ends as no '
        'contact with no session and no connection', () async {
      final (a, b) = await stacks();
      final c = await TransferStack.start(name: 'C', address: hostC);
      await link(a, c);
      final path = await a.sourceFile('informe.bin', randomBytes(4 * kib, 1));
      expect(
        await a.sendTo(a.targetOf(b), path, refresh: () => a.targetOf(c)),
        SendStart.started,
      );
      final result = a.lastSent!;
      expect(result.outcome, TransferOutcome.noContact);
      expect(result.peerFingerprint, b.fingerprint);
      expect(a.outgoing, isNull);
      expect(a.coordinator.sending, isFalse);
      await settle(const Duration(milliseconds: 400));
      expect(a.outgoingSeen, isEmpty);
      expect(b.handledTotal, 0);
      expect(c.handledTotal, 0);
      expect(c.incomingSeen, isEmpty);
    });
  });

  group('E235 E236 [SEG] PR3-4 close() of the receiver waits for the writer '
      'being opened', () {
    test('E235 with the open of the writer held, close() does not return '
        'until it is released and leaves no subfolder nor journal '
        'entry', () async {
      final (a, b) = await stacks();
      final opening = Gate<void>(null);
      b.uploadWrapper = (upload, inner) {
        b.platform.hold = (method, path) async {
          if (method == 'realPath' && path.endsWith('\\$tempFolderName')) {
            await opening.wait();
          }
        };
        return inner(upload);
      };
      await sendData(a, b, 'informe.bin', randomBytes(256 * kib, 235));
      await opening.reached.future;
      var closed = false;
      final closing = b.coordinator.close().then((_) => closed = true);
      await settle(const Duration(milliseconds: 600));
      expect(closed, isFalse);
      opening.open(null);
      await closing.timeout(const Duration(seconds: 5));
      expect(Directory(b.tempSub).existsSync(), isFalse);
      expect(b.journal.folders, isEmpty);
      expect(b.lastReceived!.outcome, TransferOutcome.cancelledHere);
      await settle(const Duration(milliseconds: 400));
      expect(Directory(b.tempSub).existsSync(), isFalse);
      expect(Directory(b.receiveDir).listSync(), isEmpty);
    });

    test('E236 closing while the journal entry is being written leaves no '
        'journal entry nor subfolder', () async {
      final (a, b) = await stacks();
      Future<void>? closing;
      b.uploadWrapper = (upload, inner) {
        final reply = inner(upload);
        closing = b.coordinator.close();
        return reply;
      };
      await sendData(a, b, 'informe.bin', randomBytes(256 * kib, 236));
      await eventually(() => closing != null, reason: 'close started');
      await closing!.timeout(const Duration(seconds: 5));
      expect(b.journal.folders, isEmpty);
      expect(Directory(b.tempSub).existsSync(), isFalse);
      expect(b.lastReceived!.outcome, TransferOutcome.cancelledHere);
      await settle(const Duration(milliseconds: 400));
      expect(Directory(b.tempSub).existsSync(), isFalse);
      expect(Directory(b.receiveDir).listSync(), isEmpty);
      final saved = File('${b.dataDir}\\cleanup.json');
      if (saved.existsSync()) {
        expect(saved.readAsStringSync(), isNot(contains('recv')));
      }
    });
  });
}
