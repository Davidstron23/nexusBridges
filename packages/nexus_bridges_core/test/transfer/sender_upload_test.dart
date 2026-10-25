@TestOn('windows')
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:ffi/ffi.dart';
import 'package:nexus_bridges_core/src/pairing/pairing.dart';
import 'package:nexus_bridges_core/src/protocol/protocol.dart';
import 'package:nexus_bridges_core/src/transfer/folders.dart'
    show tempFolderName, tempPrefix, tempSuffix;
import 'package:nexus_bridges_core/src/transfer/transfer.dart';
import 'package:test/test.dart';
import 'package:win32/win32.dart';

import 'transfer_stacks_harness.dart';

const int kib = 1024;

const int mib = 1048576;

const FaceAnswer notFound = (404, {'error': 'not_found'});

final RegExp tempName = RegExp(
  '^${RegExp.escape(tempPrefix)}[0-9a-f]{32}${RegExp.escape(tempSuffix)}\$',
);

Uint8List randomBytes(int length, int seed) {
  final random = Random(seed);
  final bytes = Uint8List(length);
  for (var i = 0; i < length; i++) {
    bytes[i] = random.nextInt(256);
  }
  return bytes;
}

String digestOf(List<int> bytes) => sha256.convert(bytes).toString();

int attributesOf(String path) => using((arena) {
  final Win32Result(:value) = GetFileAttributes(arena.pcwstr(path));
  return value;
});

bool hasMark(String path) => File('$path:Zone.Identifier').existsSync();

List<String> namesIn(String folder) => [
  for (final entity in Directory(folder).listSync(followLinks: false))
    entity.path.substring(folder.length + 1),
]..sort();

Future<(TransferStack, TransferStack)> stacks({
  PeerRelation senderAtReceiver = PeerRelation.mine,
  WriteBytes? receiverWrites,
  WriteBytes? senderWrites,
  Duration pollHold = const Duration(milliseconds: 200),
  Duration senderConfirm = Limits.transferConfirmTimeout,
  String Function(String base)? receiveChild,
}) async {
  final a = await TransferStack.start(
    name: 'A',
    address: hostA,
    pollHold: pollHold,
    confirmTimeout: senderConfirm,
    writeBytes: senderWrites,
  );
  final b = await TransferStack.start(
    name: 'B',
    address: hostB,
    pollHold: pollHold,
    writeBytes: receiverWrites,
    receiveChild: receiveChild,
  );
  await link(a, b, senderAtReceiver: senderAtReceiver);
  return (a, b);
}

Future<(TransferStack, TransferFace, SendTarget)> faceTarget({
  Duration pollHold = const Duration(milliseconds: 200),
  Duration idleTimeout = Limits.transferIdleTimeout,
}) async {
  final a = await TransferStack.start(
    name: 'A',
    address: hostA,
    pollHold: pollHold,
    idleTimeout: idleTimeout,
  );
  final face = await TransferFace.start();
  await a.trust(face.identity, name: 'Face');
  face.handlers[ApiPaths.transferOffer] = (_) =>
      (200, {'state': 'accepted', 'permit': randomHex(16)});
  return (
    a,
    face,
    a.targetAt(face.address, face.port, fingerprint: face.fingerprint),
  );
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

Future<void> nothingLeft(TransferStack s) async {
  await eventually(
    () => !Directory(s.tempSub).existsSync(),
    reason: '${s.name} temporary subfolder removed',
  );
  expect(s.incoming, isNull);
}

Future<void> waitsMore(TransferStack s, int n) {
  final target = s.handledOn(ApiPaths.transferWait) + n;
  return eventually(
    () => s.handledOn(ApiPaths.transferWait) >= target,
    reason: '$n more waits at ${s.name}',
  );
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
  group('E116 RF-179 RF-180 a complete send', () {
    test('a 3 MiB file is saved with its SHA-256 verified, marked, and the '
        'sender says saved only once the receiver has it', () async {
      final (a, b) = await stacks();
      final data = randomBytes(3 * mib, 116);
      TransferResultView? receiverAtSaved;
      a.coordinator.changes.listen((_) {
        if (a.lastSent != null) receiverAtSaved ??= b.lastReceived;
      });
      await sendData(a, b, 'informe.bin', data);
      final sent = await a.sentResult();
      expect(sent.outcome, TransferOutcome.saved);
      expect(sent.outcome.kind, TransferResultKind.saved);
      expect(sent.direction, TransferDirection.outgoing);
      expect(sent.peerFingerprint, b.fingerprint);
      expect(sent.peerName, 'Sobremesa');
      expect(sent.fileName, 'informe.bin');
      expect(sent.canReveal, isFalse);
      expect(receiverAtSaved?.outcome, TransferOutcome.saved);
      final received = await b.receivedResult();
      expect(received.outcome, TransferOutcome.saved);
      expect(received.direction, TransferDirection.incoming);
      expect(received.peerName, 'Laptop');
      expect(received.canReveal, isTrue);
      final saved = File('${b.receiveDir}\\informe.bin');
      final offer = b.bodiesOn(ApiPaths.transferOffer).single;
      expect(offer['sha256'], digestOf(data));
      expect(digestOf(saved.readAsBytesSync()), offer['sha256']);
      expect(saved.lengthSync(), 3 * mib);
      expect(hasMark(saved.path), isTrue);
      expect(
        a.phasesSeen,
        containsAllInOrder([
          OutgoingPhase.preparing,
          OutgoingPhase.uploading,
          OutgoingPhase.verifying,
        ]),
      );
      for (final view in a.outgoingSeen) {
        if (view.phase == OutgoingPhase.verifying) {
          expect(view.sentBytes, 3 * mib);
        }
      }
      expect(b.handledOn(ApiPaths.transferUpload), 1);
      expect(namesIn(b.receiveDir), ['informe.bin']);
      await nothingLeft(b);
      expect(a.coordinator.busy, isFalse);
      expect(b.coordinator.busy, isFalse);
    });
  });

  group('E118 RF-163 RF-223 progress and empty files', () {
    test('0 bytes: from uploading to verifying with nothing sent, never a '
        'partial amount, and saved on both', () async {
      final (a, b) = await stacks();
      await sendData(a, b, 'vacio.txt', const []);
      expect((await a.sentResult()).outcome, TransferOutcome.saved);
      final upload = [
        for (final view in a.outgoingSeen)
          if (view.phase == OutgoingPhase.uploading ||
              view.phase == OutgoingPhase.verifying)
            view,
      ];
      expect(upload, isNotEmpty);
      for (final view in upload) {
        expect(view.size, 0);
        expect(view.sentBytes, 0);
      }
      expect(
        a.phasesSeen,
        containsAllInOrder([OutgoingPhase.uploading, OutgoingPhase.verifying]),
      );
      expect((await b.receivedResult()).outcome, TransferOutcome.saved);
      final saved = File('${b.receiveDir}\\vacio.txt');
      expect(saved.lengthSync(), 0);
      expect(hasMark(saved.path), isTrue);
      await nothingLeft(b);
    });

    test('1 byte: saved on both with its byte', () async {
      final (a, b) = await stacks();
      await sendData(a, b, 'uno.txt', const [42]);
      expect((await a.sentResult()).outcome, TransferOutcome.saved);
      for (final view in a.outgoingSeen) {
        if (view.phase == OutgoingPhase.verifying) expect(view.sentBytes, 1);
        expect(view.sentBytes, lessThanOrEqualTo(1));
      }
      expect((await b.receivedResult()).outcome, TransferOutcome.saved);
      expect(File('${b.receiveDir}\\uno.txt').readAsBytesSync(), [42]);
    });

    test('8 MiB with a still clock: sentBytes only grows, ends at the size, '
        'and changes come only on the first and the last byte', () async {
      final (a, b) = await stacks(
        receiverWrites: WriteThrottle(delay: const Duration(milliseconds: 1))
            .call,
      );
      var uploadingChanges = 0;
      a.coordinator.changes.listen((_) {
        if (a.outgoing?.phase == OutgoingPhase.uploading) uploadingChanges++;
      });
      final data = randomBytes(8 * mib, 118);
      await sendData(a, b, 'grande.bin', data);
      expect((await a.sentResult()).outcome, TransferOutcome.saved);
      final sent = [
        for (final view in a.outgoingSeen)
          if (view.phase == OutgoingPhase.uploading ||
              view.phase == OutgoingPhase.verifying)
            view.sentBytes,
      ];
      for (var i = 1; i < sent.length; i++) {
        expect(sent[i], greaterThanOrEqualTo(sent[i - 1]));
      }
      expect(sent.toSet().length, greaterThan(3));
      expect(sent.last, 8 * mib);
      expect(uploadingChanges, lessThanOrEqualTo(4));
      expect(
        File('${b.receiveDir}\\grande.bin').readAsBytesSync(),
        orderedEquals(data),
      );
    });
  });

  group('E87 RF-162 RF-163 during the upload', () {
    Future<void> watchUpload({
      String Function(String base)? receiveChild,
    }) async {
      final (a, b) = await stacks(
        receiverWrites: WriteThrottle(delay: const Duration(milliseconds: 8))
            .call,
        receiveChild: receiveChild,
      );
      a.followRealTime();
      b.followRealTime();
      final stopwatch = Stopwatch()..start();
      final senderMarks = <Duration>[];
      final receiverMarks = <Duration>[];
      a.coordinator.changes.listen((_) {
        if (a.outgoing?.phase == OutgoingPhase.uploading) {
          senderMarks.add(stopwatch.elapsed);
        }
      });
      b.coordinator.changes.listen((_) {
        if (b.incoming?.stage == IncomingStage.receiving) {
          receiverMarks.add(stopwatch.elapsed);
        }
      });
      final data = randomBytes(8 * mib, 87);
      await sendData(a, b, 'informe.bin', data);
      var looks = 0;
      var hidden = false;
      while (a.lastSent == null) {
        if (b.incoming?.stage == IncomingStage.receiving) {
          final top = namesIn(b.receiveDir);
          final inner = Directory(b.tempSub).existsSync()
              ? namesIn(b.tempSub)
              : const <String>[];
          if (b.incoming?.stage == IncomingStage.receiving) {
            expect(top, anyOf(isEmpty, [tempFolderName]));
            expect(inner.length, lessThanOrEqualTo(1));
            if (inner.isNotEmpty) {
              looks++;
              expect(top, [tempFolderName]);
              expect(inner.single, matches(tempName));
              if (attributesOf(b.tempSub) & FILE_ATTRIBUTE_HIDDEN != 0) {
                hidden = true;
              }
            }
          }
        }
        await Future<void>.delayed(const Duration(milliseconds: 40));
        if (stopwatch.elapsed > const Duration(seconds: 40)) {
          fail('the upload did not end');
        }
      }
      expect(a.lastSent!.outcome, TransferOutcome.saved);
      expect(looks, greaterThan(3));
      expect(hidden, isTrue);
      expect(senderMarks.length, greaterThanOrEqualTo(2));
      expect(receiverMarks.length, greaterThanOrEqualTo(2));
      for (final marks in [senderMarks, receiverMarks]) {
        for (var i = 1; i < marks.length; i++) {
          expect(
            marks[i] - marks[i - 1],
            lessThanOrEqualTo(const Duration(seconds: 1)),
          );
        }
      }
      expect((await b.receivedResult()).outcome, TransferOutcome.saved);
      expect(
        File('${b.receiveDir}\\informe.bin').readAsBytesSync(),
        orderedEquals(data),
      );
      await nothingLeft(b);
      expect(namesIn(b.receiveDir), ['informe.bin']);
    }

    test('8 MiB with reads of the folder: only the hidden subfolder with one '
        'temporary, and progress on both at least once a second', () async {
      await watchUpload();
    }, timeout: const Timeout(Duration(seconds: 90)));

    test('the same with a receive folder of more than 200 characters is '
        'saved intact', () async {
      late String folder;
      await watchUpload(
        receiveChild: (base) {
          final pad = 212 - base.length - 6;
          folder = 'long\\${'x' * pad}';
          return folder;
        },
      );
      expect(folder.length, greaterThan(100));
    }, timeout: const Timeout(Duration(seconds: 90)));
  });

  group('E114 E116 RF-224 RF-180 checking until the receiver answers', () {
    test('with the finish held on the receiver the sender stays checking, '
        'renewed by its waits, and ends saved with the answer', () async {
      final (a, b) = await stacks();
      final mark = MarkHold(b);
      final data = randomBytes(256 * kib, 114);
      await sendData(a, b, 'informe.bin', data);
      await mark.reached.future;
      await a.phase(OutgoingPhase.verifying);
      final view = a.outgoing!;
      expect(view.sentBytes, 256 * kib);
      expect(view.size, 256 * kib);
      expect(view.cancelling, isFalse);
      expect(b.incoming!.stage, IncomingStage.verifying);
      final waits = b.handledOn(ApiPaths.transferWait);
      await settle(const Duration(milliseconds: 2500));
      expect(a.outgoing!.phase, OutgoingPhase.verifying);
      expect(a.lastSent, isNull);
      expect(
        b.handledOn(ApiPaths.transferWait) - waits,
        greaterThanOrEqualTo(2),
      );
      mark.open();
      expect((await a.sentResult()).outcome, TransferOutcome.saved);
      expect((await b.receivedResult()).outcome, TransferOutcome.saved);
      expect(
        File('${b.receiveDir}\\informe.bin').readAsBytesSync(),
        orderedEquals(data),
      );
    });
  });

  group('E115 RF-225 without confirmation', () {
    test('a receiver that reads everything and never answers ends as '
        'unconfirmed 30 s after the last byte, and not before', () async {
      final (a, face, target) = await faceTarget();
      face.onUpload = (request, upload) async {
        await upload.readAll(request);
        return face.hold();
      };
      final path = await a.sourceFile('informe.bin', randomBytes(64 * kib, 1));
      expect(await a.sendTo(target, path), SendStart.started);
      await a.phase(OutgoingPhase.verifying);
      await eventually(() => face.uploads.single.complete);
      a.clock.advance(const Duration(milliseconds: 29900));
      await face.moreWaits(1);
      await settle();
      expect(a.outgoing!.phase, OutgoingPhase.verifying);
      expect(a.lastSent, isNull);
      a.clock.advance(const Duration(milliseconds: 100));
      final result = await a.sentResult();
      expect(result.outcome, TransferOutcome.unconfirmed);
      expect(result.outcome.kind, TransferResultKind.unconfirmed);
      expect(face.uploads.single.received.length, 64 * kib);
    });
  });

  group('E168 RF-179 RF-225 a slow drive while saving', () {
    test('a move that takes 45 s keeps the sender checking, renewed by each '
        'wait that says saving, and it ends saved', () async {
      final (a, b) = await stacks();
      final move = Gate<void>(null);
      b.platform.move = (from, folder, name) async {
        await move.wait();
        return realFs.moveToFreeName(from, folder, name);
      };
      await sendData(a, b, 'informe.bin', randomBytes(128 * kib, 168));
      await move.reached.future;
      await a.phase(OutgoingPhase.verifying);
      for (final step in const [10, 10, 10, 10, 5]) {
        a.clock.advance(Duration(seconds: step));
        await waitsMore(b, 2);
        expect(a.outgoing?.phase, OutgoingPhase.verifying);
        expect(a.lastSent, isNull);
      }
      move.open(null);
      expect((await a.sentResult()).outcome, TransferOutcome.saved);
      expect((await b.receivedResult()).outcome, TransferOutcome.saved);
    }, timeout: const Timeout(Duration(seconds: 60)));

    test('a move that takes 11 min ends as unconfirmed at the 10 min cap even '
        'with renewals, and the receiver still saves it', () async {
      final (a, b) = await stacks(senderConfirm: const Duration(minutes: 5));
      final move = Gate<void>(null);
      b.platform.move = (from, folder, name) async {
        await move.wait();
        return realFs.moveToFreeName(from, folder, name);
      };
      await sendData(a, b, 'informe.bin', randomBytes(128 * kib, 169));
      await move.reached.future;
      await a.phase(OutgoingPhase.verifying);
      for (final step in const [
        Duration(minutes: 4),
        Duration(minutes: 4),
        Duration(minutes: 1, seconds: 59, milliseconds: 900),
      ]) {
        a.clock.advance(step);
        await waitsMore(b, 2);
        expect(a.outgoing?.phase, OutgoingPhase.verifying);
      }
      expect(a.lastSent, isNull);
      a.clock.advance(const Duration(milliseconds: 100));
      expect((await a.sentResult()).outcome, TransferOutcome.unconfirmed);
      move.open(null);
      expect((await b.receivedResult()).outcome, TransferOutcome.saved);
    }, timeout: const Timeout(Duration(seconds: 60)));
  });

  group('E160 RF-179 RF-225 asking after a failure', () {
    test('a cut after the last byte, two 429 and a held saving end as saved '
        'within 30 s, a second after each 429', () async {
      final (a, face, target) = await faceTarget(
        pollHold: Limits.transferPollHold,
      );
      final stopwatch = Stopwatch()..start();
      var cut = false;
      var heldBeforeCut = 0;
      final afterCut = <Duration>[];
      face.onUpload = (request, upload) async {
        await upload.readAll(request);
        await eventually(
          () => heldBeforeCut >= 1,
          reason: 'a renewal held before the cut',
        );
        cut = true;
        return null;
      };
      face.handlers[ApiPaths.transferWait] = (_) async {
        if (!cut) {
          heldBeforeCut++;
          return face.hold();
        }
        afterCut.add(stopwatch.elapsed);
        switch (afterCut.length) {
          case 1 || 2:
            return (429, {'error': 'rate_limited'});
          case 3:
            await Future<void>.delayed(const Duration(seconds: 7));
            return (200, {'state': 'saving'});
          default:
            return savedAnswer;
        }
      };
      final path = await a.sourceFile('informe.bin', randomBytes(256 * kib, 2));
      expect(await a.sendTo(target, path), SendStart.started);
      final result = await a.sentResult(limit: const Duration(seconds: 30));
      expect(result.outcome, TransferOutcome.saved);
      expect(stopwatch.elapsed, lessThan(const Duration(seconds: 30)));
      expect(afterCut, hasLength(4));
      expect(
        afterCut[1] - afterCut[0],
        greaterThan(const Duration(milliseconds: 900)),
      );
      expect(
        afterCut[2] - afterCut[1],
        greaterThan(const Duration(milliseconds: 900)),
      );
      expect(
        afterCut[3] - afterCut[2],
        greaterThan(const Duration(seconds: 6)),
      );
    }, timeout: const Timeout(Duration(seconds: 60)));

    test('a cut after the last byte with nobody to ask ends as '
        'unconfirmed', () async {
      final (a, face, target) = await faceTarget();
      face.handlers[ApiPaths.transferWait] = (_) => notFound;
      face.onUpload = (request, upload) async {
        await upload.readAll(request);
        return null;
      };
      final path = await a.sourceFile('informe.bin', randomBytes(64 * kib, 3));
      expect(await a.sendTo(target, path), SendStart.started);
      expect((await a.sentResult()).outcome, TransferOutcome.unconfirmed);
      expect(face.uploads.single.complete, isTrue);
    });

    test('a cut in the middle of the body while the waits keep saying '
        'uploading ends as connection lost 30 s after the cut', () async {
      final (a, face, target) = await faceTarget();
      face.onUpload = (request, upload) async {
        await upload.readSome(request);
        return null;
      };
      face.handlers[ApiPaths.transferWait] = (_) =>
          (200, {'state': 'uploading'});
      final path = await a.sourceFile('informe.bin', randomBytes(8 * mib, 4));
      expect(await a.sendTo(target, path), SendStart.started);
      await eventually(() => face.uploads.isNotEmpty);
      await face.moreWaits(2);
      expect(a.lastSent, isNull);
      expect(a.outgoing!.phase, OutgoingPhase.uploading);
      a.clock.advance(const Duration(milliseconds: 29900));
      await face.moreWaits(1);
      await settle();
      expect(a.lastSent, isNull);
      a.clock.advance(const Duration(milliseconds: 100));
      final result = await a.sentResult();
      expect(result.outcome, TransferOutcome.connectionLost);
      expect(face.uploads.single.complete, isFalse);
    });
  });

  group('A19 answers to the upload', () {
    test('each answer to the upload gives its outcome, asking with wait when '
        'it says nothing', () async {
      final (a, face, target) = await faceTarget();
      final cases = <(String, FaceAnswer, FaceAnswer, TransferOutcome)>[
        (
          '403 and nothing to ask',
          (403, {'error': 'forbidden'}),
          notFound,
          TransferOutcome.uploadNotStarted,
        ),
        (
          '403 and the wait says saved',
          (403, {'error': 'forbidden'}),
          savedAnswer,
          TransferOutcome.saved,
        ),
        (
          '200 without a result',
          (200, {'state': 'uploading'}),
          notFound,
          TransferOutcome.uploadNotStarted,
        ),
        (
          '200 with an unknown body',
          (200, {'what': 1}),
          notFound,
          TransferOutcome.uploadNotStarted,
        ),
        (
          '500',
          (500, {'error': 'internal'}),
          notFound,
          TransferOutcome.uploadNotStarted,
        ),
        (
          'damaged',
          (200, {'state': 'failed', 'reason': 'damaged'}),
          notFound,
          TransferOutcome.damaged,
        ),
        (
          'move failed',
          (200, {'state': 'failed', 'reason': 'move_failed'}),
          notFound,
          TransferOutcome.moveFailed,
        ),
        (
          'saved without the mark',
          (200, {'state': 'saved', 'marked': false}),
          notFound,
          TransferOutcome.savedWithoutMark,
        ),
        (
          'cancelled by the receiver',
          (200, {'state': 'cancelled'}),
          notFound,
          TransferOutcome.cancelledByPeer,
        ),
      ];
      final path = await a.sourceFile('informe.bin', randomBytes(32 * kib, 5));
      TransferResultView? previous;
      for (final (label, uploadAnswer, waitAnswer, outcome) in cases) {
        face.onUpload = (request, upload) async {
          await upload.readAll(request);
          return uploadAnswer;
        };
        face.handlers[ApiPaths.transferWait] = (_) => waitAnswer;
        expect(await a.sendTo(target, path), SendStart.started);
        final result = await a.sentResult(after: previous);
        expect(result.outcome, outcome, reason: label);
        previous = result;
      }
      expect(face.uploads, hasLength(cases.length));
    });

    test('a final state in a renewal wait does not end the send; the answer '
        'of the upload does', () async {
      final (a, face, target) = await faceTarget();
      face.handlers[ApiPaths.transferWait] = (_) =>
          (200, {'state': 'failed', 'reason': 'damaged'});
      face.onUpload = (request, upload) async {
        await upload.readAll(request);
        await face.moreWaits(2);
        return savedAnswer;
      };
      final path = await a.sourceFile('informe.bin', randomBytes(32 * kib, 6));
      expect(await a.sendTo(target, path), SendStart.started);
      expect((await a.sentResult()).outcome, TransferOutcome.saved);
      expect(face.count(ApiPaths.transferWait), greaterThanOrEqualTo(2));
    });

    test('a receiver that stops listening after accepting ends as upload not '
        'started', () async {
      final (a, face, target) = await faceTarget();
      face.handlers[ApiPaths.transferOffer] = (_) {
        unawaited(face.server.close());
        return (200, {'state': 'accepted', 'permit': randomHex(16)});
      };
      final path = await a.sourceFile('informe.bin', randomBytes(32 * kib, 7));
      expect(await a.sendTo(target, path), SendStart.started);
      expect((await a.sentResult()).outcome, TransferOutcome.uploadNotStarted);
      expect(face.uploads, isEmpty);
    });

    test('an upload that stalls asks and ends as idle', () async {
      final (a, face, target) = await faceTarget(
        idleTimeout: const Duration(seconds: 1),
      );
      face.handlers[ApiPaths.transferWait] = (_) => notFound;
      face.onUpload = (request, upload) async {
        await upload.readSome(request);
        return face.hold();
      };
      final path = await a.sourceFile('informe.bin', randomBytes(16 * mib, 8));
      expect(await a.sendTo(target, path), SendStart.started);
      final result = await a.sentResult(limit: const Duration(seconds: 15));
      expect(result.outcome, TransferOutcome.idle);
      expect(face.uploads.single.complete, isFalse);
    });
  });

  group('E117 RF-169 RF-171 a source that changes', () {
    test('a source cut short halfway ends as unreadable on both and the '
        'receiver keeps nothing', () async {
      final writes = WriteThrottle()..hold();
      final (a, b) = await stacks(receiverWrites: writes.call);
      final data = randomBytes(16 * mib, 117);
      final path = await sendData(a, b, 'informe.bin', data);
      await eventually(() => writes.calls >= 1, reason: 'upload started');
      await settle(const Duration(milliseconds: 300));
      expect(a.outgoing!.sentBytes, lessThan(8 * mib - 128 * kib));
      final file = File(path).openSync(mode: FileMode.append);
      file.truncateSync(8 * mib);
      file.closeSync();
      writes.open();
      final result = await a.sentResult();
      expect(result.outcome, TransferOutcome.unreadable);
      expect(result.outcome.kind, TransferResultKind.failed);
      expect(
        b.bodiesOn(ApiPaths.transferCancel).single['reason'],
        'unreadable',
      );
      expect((await b.receivedResult()).outcome, TransferOutcome.unreadable);
      await nothingLeft(b);
      expect(namesIn(b.receiveDir), isEmpty);
    });

    test('a source that changes with the same size is damaged on both and '
        'nothing is kept', () async {
      final (a, b) = await stacks();
      final original = randomBytes(mib, 171);
      final other = randomBytes(mib, 172);
      late String path;
      b.wrappers[ApiPaths.transferOffer] = (call, inner) async {
        await File(path).writeAsBytes(other, flush: true);
        return inner(call);
      };
      path = await sendData(a, b, 'informe.bin', original);
      final result = await a.sentResult();
      expect(result.outcome, TransferOutcome.damaged);
      expect((await b.receivedResult()).outcome, TransferOutcome.damaged);
      await nothingLeft(b);
      expect(namesIn(b.receiveDir), isEmpty);
    });
  });

  group('E94 E119 RF-164 RF-183 cancelling an accepted send', () {
    test('during the upload: cancelling is false until asked, then true, '
        'the sender ends cancelled here and the receiver keeps '
        'nothing', () async {
      final writes = WriteThrottle()..hold();
      final (a, b) = await stacks(receiverWrites: writes.call);
      await sendData(a, b, 'informe.bin', randomBytes(8 * mib, 94));
      await eventually(() => writes.calls >= 1, reason: 'upload started');
      expect(a.outgoing!.phase, OutgoingPhase.uploading);
      expect(a.outgoingSeen.where((v) => v.cancelling), isEmpty);
      a.coordinator.cancelOutgoing();
      expect(a.outgoing!.cancelling, isTrue);
      expect(a.lastSent, isNull);
      final result = await a.sentResult();
      expect(result.outcome, TransferOutcome.cancelledHere);
      expect(result.outcome.kind, TransferResultKind.cancelled);
      expect(b.bodiesOn(ApiPaths.transferCancel).single['reason'], 'cancelled');
      writes.open();
      expect(
        (await b.receivedResult()).outcome,
        TransferOutcome.cancelledByPeer,
      );
      await nothingLeft(b);
      expect(namesIn(b.receiveDir), isEmpty);
      final seen = a.outgoingSeen;
      final first = seen.indexWhere((v) => v.cancelling);
      expect(first, greaterThan(0));
      expect(
        seen.skip(first),
        everyElement(predicate<OutgoingTransferView>((v) => v.cancelling)),
      );
    });

    test('while checking with the finish held: the cancel waits for the end, '
        'answers saved and the sender shows saved', () async {
      final (a, b) = await stacks();
      final mark = MarkHold(b);
      final data = randomBytes(256 * kib, 95);
      await sendData(a, b, 'informe.bin', data);
      await mark.reached.future;
      await a.phase(OutgoingPhase.verifying);
      a.coordinator.cancelOutgoing();
      expect(a.outgoing!.cancelling, isTrue);
      expect(a.outgoing!.phase, OutgoingPhase.verifying);
      await eventually(() => b.handledOn(ApiPaths.transferCancel) == 1);
      await settle(const Duration(milliseconds: 300));
      expect(a.lastSent, isNull);
      mark.open();
      expect((await a.sentResult()).outcome, TransferOutcome.saved);
      expect((await b.receivedResult()).outcome, TransferOutcome.saved);
      expect(
        File('${b.receiveDir}\\informe.bin').readAsBytesSync(),
        orderedEquals(data),
      );
    });

    test('a cancel that is never answered is waited 2 s and then the upload '
        'is cut', () async {
      final (a, face, target) = await faceTarget();
      face.onUpload = (request, upload) async {
        await upload.readSome(request);
        return face.hold();
      };
      face.handlers[ApiPaths.transferCancel] = (_) => face.hold();
      final path = await a.sourceFile('informe.bin', randomBytes(8 * mib, 96));
      expect(await a.sendTo(target, path), SendStart.started);
      await eventually(() => face.uploads.isNotEmpty);
      expect(a.outgoing!.phase, OutgoingPhase.uploading);
      final stopwatch = Stopwatch()..start();
      a.coordinator.cancelOutgoing();
      expect(a.outgoing!.cancelling, isTrue);
      a.coordinator.cancelOutgoing();
      final result = await a.sentResult();
      expect(result.outcome, TransferOutcome.cancelledHere);
      expect(
        stopwatch.elapsed,
        greaterThan(const Duration(milliseconds: 1800)),
      );
      expect(stopwatch.elapsed, lessThan(const Duration(milliseconds: 3500)));
      expect(face.count(ApiPaths.transferCancel), 1);
    });
  });

  group('E96 RF-188 the interface of the sender goes down', () {
    test('while the warning is open: interface down at once and the '
        'receiver withdraws the warning', () async {
      final (a, b) = await stacks(senderAtReceiver: PeerRelation.foreign);
      await sendData(a, b, 'informe.bin', randomBytes(32 * kib, 961));
      await a.phase(OutgoingPhase.waiting);
      await eventually(() => b.incoming?.stage == IncomingStage.warning);
      a.coordinator.interfacesChanged({'other#10.0.0.1'});
      expect(a.outgoing, isNull);
      expect(a.lastSent!.outcome, TransferOutcome.interfaceDown);
      expect(a.lastSent!.outcome.kind, TransferResultKind.failed);
      await eventually(
        () => b.events.whereType<PeerCancelledTransfer>().isNotEmpty,
      );
      expect(b.incoming, isNull);
      expect(b.lastReceived, isNull);
    });

    test('accepted, before the receiver reads the upload: interface down '
        'and the receiver ends it without a temporary', () async {
      final (a, b) = await stacks();
      final held = Gate<void>(null);
      b.uploadWrapper = (upload, inner) async {
        await held.wait();
        return inner(upload);
      };
      await sendData(a, b, 'informe.bin', randomBytes(32 * kib, 962));
      await held.reached.future;
      expect(a.outgoing!.phase, OutgoingPhase.uploading);
      a.coordinator.interfacesChanged(const {});
      expect(a.lastSent!.outcome, TransferOutcome.interfaceDown);
      await eventually(() => b.handledOn(ApiPaths.transferCancel) == 1);
      expect(
        (await b.receivedResult()).outcome,
        TransferOutcome.cancelledByPeer,
      );
      held.open(null);
      await nothingLeft(b);
      expect(namesIn(b.receiveDir), isEmpty);
    });

    test('during the upload: interface down and the receiver keeps '
        'nothing', () async {
      final writes = WriteThrottle()..hold();
      final (a, b) = await stacks(receiverWrites: writes.call);
      await sendData(a, b, 'informe.bin', randomBytes(8 * mib, 963));
      await eventually(() => writes.calls >= 1, reason: 'upload started');
      a.coordinator.interfacesChanged({a.iface.id, 'other#10.0.0.1'});
      await settle();
      expect(a.outgoing!.phase, OutgoingPhase.uploading);
      a.coordinator.interfacesChanged({'other#10.0.0.1'});
      expect(a.outgoing, isNull);
      expect(a.lastSent!.outcome, TransferOutcome.interfaceDown);
      writes.open();
      expect(
        (await b.receivedResult()).outcome,
        TransferOutcome.cancelledByPeer,
      );
      await nothingLeft(b);
      expect(namesIn(b.receiveDir), isEmpty);
    });
  });

  group('E98 RF-190 the relation changes after accepting', () {
    test('from mine to foreign while uploading: the send ends saved', () async {
      final writes = WriteThrottle()..hold();
      final (a, b) = await stacks(receiverWrites: writes.call);
      final data = randomBytes(2 * mib, 98);
      await sendData(a, b, 'informe.bin', data);
      await eventually(() => writes.calls >= 1, reason: 'upload started');
      await b.trust(a.identity, name: 'Laptop', relation: PeerRelation.foreign);
      b.coordinator.pairedChanged();
      writes.open();
      expect((await a.sentResult()).outcome, TransferOutcome.saved);
      expect((await b.receivedResult()).outcome, TransferOutcome.saved);
      expect(
        File('${b.receiveDir}\\informe.bin').readAsBytesSync(),
        orderedEquals(data),
      );
    });

    test('from foreign to mine after accepting the warning: the send ends '
        'saved', () async {
      final writes = WriteThrottle()..hold();
      final (a, b) = await stacks(
        senderAtReceiver: PeerRelation.foreign,
        receiverWrites: writes.call,
      );
      await sendData(a, b, 'informe.bin', randomBytes(2 * mib, 99));
      await eventually(() => b.incoming?.stage == IncomingStage.warning);
      b.coordinator.answerWarning(b.incoming!.sessionId, accept: true);
      await eventually(() => writes.calls >= 1, reason: 'upload started');
      await b.trust(a.identity, name: 'Laptop');
      b.coordinator.pairedChanged();
      writes.open();
      expect((await a.sentResult()).outcome, TransferOutcome.saved);
      expect((await b.receivedResult()).outcome, TransferOutcome.saved);
    });
  });

  group('E99 RF-191 both directions at once', () {
    for (final size in const [0, 1, 8 * mib]) {
      test('A and B send each other $size bytes at the same time and both '
          'files are saved', () async {
        final (a, b) = await stacks(
          receiverWrites: WriteThrottle(delay: const Duration(milliseconds: 1))
              .call,
          senderWrites: WriteThrottle(delay: const Duration(milliseconds: 1))
              .call,
        );
        final fromA = randomBytes(size, 1);
        final fromB = randomBytes(size, 2);
        final pathA = await a.sourceFile('de-a.bin', fromA);
        final pathB = await b.sourceFile('de-b.bin', fromB);
        var overlap = false;
        final sampler = Timer.periodic(const Duration(milliseconds: 2), (_) {
          if (a.outgoing != null && a.incoming != null) overlap = true;
        });
        addTearDown(sampler.cancel);
        final starts = await Future.wait([a.send(b, pathA), b.send(a, pathB)]);
        expect(starts, [SendStart.started, SendStart.started]);
        final results = await Future.wait([
          a.sentResult(limit: const Duration(seconds: 20)),
          b.sentResult(limit: const Duration(seconds: 20)),
        ]);
        sampler.cancel();
        for (final result in results) {
          expect(result.outcome, TransferOutcome.saved);
        }
        expect((await a.receivedResult()).outcome, TransferOutcome.saved);
        expect((await b.receivedResult()).outcome, TransferOutcome.saved);
        expect(
          File('${b.receiveDir}\\de-a.bin').readAsBytesSync(),
          orderedEquals(fromA),
        );
        expect(
          File('${a.receiveDir}\\de-b.bin').readAsBytesSync(),
          orderedEquals(fromB),
        );
        if (size > 1) expect(overlap, isTrue);
        await nothingLeft(a);
        await nothingLeft(b);
      }, timeout: const Timeout(Duration(seconds: 60)));
    }
  });

  group('E100 RF-197 [SEG] nothing secret in the records', () {
    test('success, damaged, cancelled and unreadable never write a permit or '
        'the content in the records or in the views', () async {
      final writes = WriteThrottle();
      final (a, b) = await stacks(receiverWrites: writes.call);
      final permits = <String>[];
      String? swapPath;
      Uint8List? swapWith;
      b.wrappers[ApiPaths.transferOffer] = (call, inner) async {
        final path = swapPath;
        final other = swapWith;
        if (path != null && other != null) {
          await File(path).writeAsBytes(other, flush: true);
        }
        final reply = await inner(call);
        final permit = reply.json['permit'];
        if (permit is String) permits.add(permit);
        return reply;
      };
      final marker = 'NB-E100-${randomHex(8)}';
      Uint8List content(int length, int seed) => Uint8List.fromList([
        ...utf8.encode(marker),
        ...randomBytes(length, seed),
        ...utf8.encode(marker),
      ]);
      final views = <String>[];
      a.coordinator.changes.listen((_) {
        views
          ..add('${a.outgoing}')
          ..add('${a.lastSent}');
      });
      b.coordinator.changes.listen((_) {
        views
          ..add('${b.incoming}')
          ..add('${b.lastReceived}');
      });

      await sendData(a, b, 'uno.txt', content(64 * kib, 1));
      var last = await a.sentResult();
      expect(last.outcome, TransferOutcome.saved);

      swapPath = '${a.sourceDir}\\dos.txt';
      swapWith = content(64 * kib, 3);
      await sendData(a, b, 'dos.txt', content(64 * kib, 2));
      last = await a.sentResult(after: last);
      expect(last.outcome, TransferOutcome.damaged);
      swapPath = null;
      swapWith = null;

      writes.hold();
      final calls = writes.calls;
      await sendData(a, b, 'tres.txt', content(4 * mib, 4));
      await eventually(() => writes.calls > calls, reason: 'third upload');
      a.coordinator.cancelOutgoing();
      last = await a.sentResult(after: last);
      expect(last.outcome, TransferOutcome.cancelledHere);
      writes.open();
      await nothingLeft(b);

      writes.hold();
      final again = writes.calls;
      final path = await sendData(a, b, 'cuatro.txt', content(16 * mib, 5));
      await eventually(() => writes.calls > again, reason: 'fourth upload');
      await settle(const Duration(milliseconds: 300));
      final file = File(path).openSync(mode: FileMode.append);
      file.truncateSync(12 * mib);
      file.closeSync();
      writes.open();
      last = await a.sentResult(after: last);
      expect(last.outcome, TransferOutcome.unreadable);
      await nothingLeft(b);

      expect(permits, hasLength(4));
      final text = [...a.logs, ...b.logs, ...views].join('\n').toLowerCase();
      for (final permit in permits) {
        expect(text, isNot(contains(permit.toLowerCase())));
      }
      expect(text, isNot(contains(marker.toLowerCase())));
      expect(text, isNot(contains(a.base.toLowerCase())));
    }, timeout: const Timeout(Duration(seconds: 60)));
  });

  group('E62 RF-207 a drive without the mark', () {
    test('foreign with the remembered folder on it: the warning says so and '
        'both see saved without the mark, with no Zone.Identifier', () async {
      final (a, b) = await stacks(senderAtReceiver: PeerRelation.foreign);
      b.platform.noMarkSupport = true;
      await sendData(a, b, 'informe.txt', randomBytes(64 * kib, 62));
      await eventually(() => b.incoming?.stage == IncomingStage.warning);
      expect(b.incoming!.withoutMark, isTrue);
      b.coordinator.answerWarning(b.incoming!.sessionId, accept: true);
      final sent = await a.sentResult();
      expect(sent.outcome, TransferOutcome.savedWithoutMark);
      expect(sent.outcome.kind, TransferResultKind.saved);
      final received = await b.receivedResult();
      expect(received.outcome, TransferOutcome.savedWithoutMark);
      final saved = '${b.receiveDir}\\informe.txt';
      expect(File(saved).existsSync(), isTrue);
      expect(hasMark(saved), isFalse);
    });

    test('mine with the same folder: no warning and saved without the mark '
        'on both', () async {
      final (a, b) = await stacks();
      b.platform.noMarkSupport = true;
      await sendData(a, b, 'informe.txt', randomBytes(64 * kib, 63));
      expect((await a.sentResult()).outcome, TransferOutcome.savedWithoutMark);
      expect(
        (await b.receivedResult()).outcome,
        TransferOutcome.savedWithoutMark,
      );
      expect(
        b.incomingSeen.where((v) => v.stage == IncomingStage.warning),
        isEmpty,
      );
      expect(hasMark('${b.receiveDir}\\informe.txt'), isFalse);
    });
  });

  group('E170 RF-186 RF-189 the sender closes or unpairs', () {
    test('closing while preparing: the receiver sees nothing', () async {
      final (a, b) = await stacks();
      final typeCheck = Gate<bool>(false);
      a.platform.dangerous = (_) => typeCheck.wait();
      await sendData(a, b, 'x.chm', randomBytes(32 * kib, 170));
      await typeCheck.reached.future;
      expect(a.outgoing!.phase, OutgoingPhase.preparing);
      await a.coordinator.close();
      expect(a.lastSent!.outcome, TransferOutcome.cancelledHere);
      await settle(const Duration(milliseconds: 300));
      expect(b.handledTotal, 0);
      expect(b.incomingSeen, isEmpty);
      expect(b.lastReceived, isNull);
    });

    test('closing while checking with the finish held ends within the budget '
        'and the receiver still saves the file', () async {
      final (a, b) = await stacks();
      final mark = MarkHold(b);
      await sendData(a, b, 'informe.bin', randomBytes(256 * kib, 171));
      await mark.reached.future;
      await a.phase(OutgoingPhase.verifying);
      final stopwatch = Stopwatch()..start();
      await a.coordinator.close();
      expect(stopwatch.elapsed, lessThan(Limits.transferCloseBudget));
      expect(a.lastSent!.outcome, TransferOutcome.cancelledHere);
      expect(b.handledOn(ApiPaths.transferCancel), 1);
      mark.open();
      expect((await b.receivedResult()).outcome, TransferOutcome.saved);
    });

    test('peerUnpaired while uploading ends as unpaired, sends the cancel '
        'and the receiver keeps nothing', () async {
      final writes = WriteThrottle()..hold();
      final (a, b) = await stacks(receiverWrites: writes.call);
      await sendData(a, b, 'informe.bin', randomBytes(4 * mib, 172));
      await eventually(() => writes.calls >= 1, reason: 'upload started');
      final stopwatch = Stopwatch()..start();
      await a.coordinator.peerUnpaired(b.fingerprint);
      expect(stopwatch.elapsed, lessThan(const Duration(milliseconds: 2500)));
      expect(a.outgoing, isNull);
      expect(a.lastSent!.outcome, TransferOutcome.unpaired);
      expect(a.lastSent!.outcome.kind, TransferResultKind.cancelled);
      await eventually(() => b.handledOn(ApiPaths.transferCancel) == 1);
      expect(b.bodiesOn(ApiPaths.transferCancel).single['reason'], 'cancelled');
      writes.open();
      final received = await b.receivedResult();
      expect(received.outcome, isNot(TransferOutcome.saved));
      expect(received.outcome.kind, isNot(TransferResultKind.saved));
      await nothingLeft(b);
      expect(namesIn(b.receiveDir), isEmpty);
    });

    test('peerUnpaired while waiting returns once the cancel is delivered '
        'and the receiver withdraws the warning', () async {
      final (a, b) = await stacks(senderAtReceiver: PeerRelation.foreign);
      await sendData(a, b, 'informe.bin', randomBytes(32 * kib, 173));
      await a.phase(OutgoingPhase.waiting);
      await eventually(() => b.incoming?.stage == IncomingStage.warning);
      await a.coordinator.peerUnpaired(b.fingerprint);
      expect(b.handledOn(ApiPaths.transferCancel), 1);
      expect(a.lastSent!.outcome, TransferOutcome.unpaired);
      await eventually(
        () => b.events.whereType<PeerCancelledTransfer>().isNotEmpty,
      );
      expect(b.incoming, isNull);
    });

    test('peerUnpaired of another device changes nothing', () async {
      final writes = WriteThrottle()..hold();
      final (a, b) = await stacks(receiverWrites: writes.call);
      await sendData(a, b, 'informe.bin', randomBytes(mib, 174));
      await eventually(() => writes.calls >= 1, reason: 'upload started');
      await a.coordinator.peerUnpaired(a.fingerprint);
      expect(a.outgoing, isNotNull);
      expect(a.lastSent, isNull);
      expect(b.handledOn(ApiPaths.transferCancel), 0);
      writes.open();
      expect((await a.sentResult()).outcome, TransferOutcome.saved);
    });

    test('pairedChanged without the receiver ends as unpaired at once and the '
        'receiver keeps nothing', () async {
      final writes = WriteThrottle()..hold();
      final (a, b) = await stacks(receiverWrites: writes.call);
      await sendData(a, b, 'informe.bin', randomBytes(8 * mib, 175));
      await eventually(() => writes.calls >= 1, reason: 'upload started');
      a.coordinator.pairedChanged();
      expect(a.outgoing!.phase, OutgoingPhase.uploading);
      await a.paired.remove(b.fingerprint);
      a.coordinator.pairedChanged();
      expect(a.outgoing, isNull);
      expect(a.lastSent!.outcome, TransferOutcome.unpaired);
      writes.open();
      expect(
        (await b.receivedResult()).outcome,
        TransferOutcome.cancelledByPeer,
      );
      await nothingLeft(b);
    });

    test('the receiver unpairing the sender while uploading: the sender '
        'sees the cut and ends as connection lost', () async {
      final writes = WriteThrottle()..hold();
      final (a, b) = await stacks(receiverWrites: writes.call);
      await sendData(a, b, 'informe.bin', randomBytes(4 * mib, 176));
      await eventually(() => writes.calls >= 1, reason: 'upload started');
      await b.forget(a.fingerprint);
      await b.coordinator.peerUnpaired(a.fingerprint);
      writes.open();
      expect((await b.receivedResult()).outcome, TransferOutcome.unpaired);
      await nothingLeft(b);
      await settle(const Duration(milliseconds: 500));
      expect(a.lastSent, isNull);
      a.clock.advance(Limits.transferConfirmTimeout);
      final result = await a.sentResult();
      expect(result.outcome, TransferOutcome.connectionLost);
    });
  });

  group('A24 closing the sending side', () {
    test('closing while uploading to a receiver that never answers the cancel '
        'ends within 2.5 s', () async {
      final (a, face, target) = await faceTarget();
      face.onUpload = (request, upload) async {
        await upload.readSome(request);
        return face.hold();
      };
      face.handlers[ApiPaths.transferCancel] = (_) => face.hold();
      final path = await a.sourceFile('informe.bin', randomBytes(8 * mib, 24));
      expect(await a.sendTo(target, path), SendStart.started);
      await eventually(() => face.uploads.isNotEmpty);
      final stopwatch = Stopwatch()..start();
      await a.coordinator.close();
      expect(stopwatch.elapsed, lessThan(const Duration(milliseconds: 2500)));
      expect(a.lastSent!.outcome, TransferOutcome.cancelledHere);
      expect(face.count(ApiPaths.transferCancel), 1);
    });
  });
}
