@TestOn('windows')
library;

import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:ffi/ffi.dart';
import 'package:nexus_bridges_core/src/identity/identity.dart';
import 'package:nexus_bridges_core/src/pairing/pairing.dart';
import 'package:nexus_bridges_core/src/protocol/protocol.dart';
import 'package:nexus_bridges_core/src/server/server.dart';
import 'package:nexus_bridges_core/src/transfer/folders.dart'
    show tempFolderName, tempPrefix, tempSuffix;
import 'package:nexus_bridges_core/src/transfer/platform.dart';
import 'package:nexus_bridges_core/src/transfer/transfer.dart';
import 'package:nexus_bridges_core/src/transport/transport.dart';
import 'package:test/test.dart';
import 'package:win32/win32.dart';

import 'receiver_harness.dart';

const int kib = 1024;

const int mib = 1048576;

const String emptySha256 =
    'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855';

final RegExp tempName = RegExp(r'^~nexusbridges-[0-9a-f]{32}\.partial$');

final RegExp ioErrorType = RegExp(r'(PathNotFound|FileSystem)Exception');

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

int attributesOf(String path) => using((arena) {
  final Win32Result(:value) = GetFileAttributes(arena.pcwstr(path));
  return value;
});

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

void expectState(RawReply reply, Map<String, Object?> json) {
  expect(reply.status, 200, reason: reply.text);
  expect(reply.json, json);
}

void expectForbidden(RawReply reply) {
  expect(reply.status, 403, reason: reply.text);
  expect(reply.json, {'error': 'forbidden'});
}

List<String> journalPaths(ReceiverStack s) => [
  for (final folder in s.journal.folders) folder.path.toLowerCase(),
];

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

  void send(List<int> bytes) => _controller.add(bytes);

  void sendAll(Uint8List bytes) {
    for (var i = 0; i < bytes.length; i += 64 * kib) {
      send(Uint8List.sublistView(bytes, i, min(i + 64 * kib, bytes.length)));
    }
  }

  void finish() => unawaited(_controller.close());

  void breakOff() => _controller.addError(StateError('source closed'));
}

final class Pending<T> {
  Pending(Future<T> future) {
    future.then((value) {
      result = value;
      done = true;
    });
  }

  bool done = false;
  T? result;
}

void main() {
  late DeviceIdentity receiver;
  late Peer laptop;
  late Peer desk;
  late Peer portatil;
  late DeviceIdentity stranger;

  setUpAll(() {
    receiver = DeviceIdentity.generate();
    laptop = Peer(DeviceIdentity.generate(), name: 'Laptop');
    desk = Peer(DeviceIdentity.generate(), name: 'Sobremesa');
    portatil = Peer(
      DeviceIdentity.generate(),
      name: 'PORTATIL',
      relation: PeerRelation.foreign,
    );
    stranger = DeviceIdentity.generate();
  });

  Future<ReceiverStack> stack({
    Duration pollHold = const Duration(milliseconds: 200),
    void Function(TransferPlatform platform)? configure,
    String Function(String base)? rememberedPath,
    List<ApiRoute> Function(ReceiverStack stack)? routesOverride,
  }) => ReceiverStack.start(
    identity: receiver,
    peers: [laptop, desk, portatil],
    pollHold: pollHold,
    configure: configure,
    rememberedPath: rememberedPath,
    routesOverride: routesOverride,
  );

  Future<Accepted> accept(
    ReceiverStack s,
    Peer peer,
    Uint8List bytes, {
    String name = 'informe.txt',
    String? digest,
    bool shown = true,
  }) async {
    final transfer = newTransferId();
    final reply = await s.post(
      peer.identity,
      ApiPaths.transferOffer,
      s.offerBody(
        transfer: transfer,
        name: name,
        size: bytes.length,
        sha256: digest ?? digestOf(bytes),
      ),
    );
    expect(reply, isNotNull);
    expect(reply!.status, 200, reason: reply.text);
    expect(reply.state, 'accepted');
    final permit = reply.json['permit']! as String;
    expect(permit, matches(hex32));
    if (shown) {
      await eventually(
        () => s.incoming?.stage == IncomingStage.waitingData,
        reason: 'accepted card shown',
      );
    }
    return Accepted(transfer, permit, bytes);
  }

  Future<StreamPostResult> send(
    ReceiverStack s,
    Peer peer,
    Accepted a, {
    Map<String, String>? headers,
    Uint8List? bytes,
    int? length,
  }) {
    final body = bytes ?? a.bytes;
    return s.postUpload(
      peer.identity,
      headers: headers ?? a.headers,
      contentLength: length ?? body.length,
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

  group('T9 RF-162 RF-170 RF-172 RF-174 RF-231 a file is saved', () {
    test('a 3 MiB file from the raw client is written to a hidden temporary, '
        'then saved with its name, the web mark and no temporary', () async {
      final s = await stack();
      final a = await accept(s, laptop, randomBytes(3 * mib + 123, 9));
      expect(s.handledOn(ApiPaths.transferUpload), 0);

      late Future<StreamPostResult> result;
      final held = await startHeld(
        s,
        laptop,
        a,
        mib + mib ~/ 2,
        (r) => result = r,
      );
      final sub = subOf(s.receiveDir);
      final during = treeOf(s.receiveDir);
      expect(during, hasLength(2), reason: '$during');
      expect(during.first, tempFolderName);
      final temp = during.last.substring(tempFolderName.length + 1);
      expect(temp, matches(tempName));
      expect(File('$sub\\$temp').lengthSync(), greaterThanOrEqualTo(mib));
      expect(attributesOf(sub) & FILE_ATTRIBUTE_HIDDEN, isNot(0));
      expect(File('${s.receiveDir}\\informe.txt').existsSync(), isFalse);
      expect(journalPaths(s), [s.receiveDir.toLowerCase()]);
      expect(s.incoming?.fileName, 'informe.txt');
      expect(s.incoming?.size, a.bytes.length);
      expect(s.coordinator.busy, isTrue);

      held.sendAll(Uint8List.sublistView(a.bytes, mib + mib ~/ 2));
      held.finish();
      expectState(answered(await result), {'state': 'saved', 'marked': true});

      final saved = File('${s.receiveDir}\\informe.txt');
      expect(saved.readAsBytesSync(), a.bytes);
      expect(
        File('${saved.path}:Zone.Identifier').readAsStringSync(),
        contains('ZoneId=3'),
      );
      expect(treeOf(s.receiveDir), ['informe.txt']);
      await expectNothingLeft(s, s.receiveDir);
      expect(
        s.coordinator.lastReceived,
        TransferResultView(
          direction: TransferDirection.incoming,
          peerFingerprint: laptop.fingerprint,
          peerName: 'Laptop',
          fileName: 'informe.txt',
          isProgram: false,
          outcome: TransferOutcome.saved,
          canReveal: true,
          size: a.bytes.length,
        ),
      );
      expect(
        s.seen.any((v) => v.stage == IncomingStage.receiving),
        isTrue,
        reason: 'the card showed the receiving stage',
      );
      expect(s.handledOn(ApiPaths.transferUpload), 1);
      expectCleanLogs(s, [a.permit]);
    });

    test('RF-175 RF-176 a taken name is saved as "informe (1).txt" and the '
        'existing file is not touched', () async {
      final s = await stack();
      final existing = File('${s.receiveDir}\\informe.txt')
        ..writeAsStringSync('original');
      final before = existing.lastModifiedSync();
      final a = await accept(s, laptop, randomBytes(2 * kib, 3));

      expectState(answered(await send(s, laptop, a)), {
        'state': 'saved',
        'marked': true,
      });

      expect(existing.readAsStringSync(), 'original');
      expect(existing.lastModifiedSync(), before);
      expect(
        File('${s.receiveDir}\\informe (1).txt').readAsBytesSync(),
        a.bytes,
      );
      expect(treeOf(s.receiveDir), ['informe (1).txt', 'informe.txt']);
      expect(s.coordinator.lastReceived?.fileName, 'informe (1).txt');
      expect(s.coordinator.lastReceived?.canReveal, isTrue);
      expect(s.coordinator.lastReceived?.outcome, TransferOutcome.saved);
      await expectNothingLeft(s, s.receiveDir);
    });

    test('RF-223 a 0 byte file is saved empty, verified and marked', () async {
      final s = await stack();
      final a = await accept(s, laptop, Uint8List(0), name: 'vacio.txt');

      final result = await s.postUpload(
        laptop.identity,
        headers: a.headers,
        contentLength: 0,
        body: const Stream<List<int>>.empty(),
      );
      expectState(answered(result), {'state': 'saved', 'marked': true});

      final saved = File('${s.receiveDir}\\vacio.txt');
      expect(saved.lengthSync(), 0);
      expect(File('${saved.path}:Zone.Identifier').existsSync(), isTrue);
      expect(s.coordinator.lastReceived?.outcome, TransferOutcome.saved);
      expect(s.coordinator.lastReceived?.fileName, 'vacio.txt');
      await expectNothingLeft(s, s.receiveDir);
    });

    test('D-2 RF-172 a drive without the mark saves without it and says so '
        'to the sender', () async {
      final s = await stack(configure: (p) => p.noMarkSupport = true);
      final a = await accept(s, laptop, randomBytes(4 * kib, 4));

      expectState(answered(await send(s, laptop, a)), {
        'state': 'saved',
        'marked': false,
      });

      final saved = File('${s.receiveDir}\\informe.txt');
      expect(saved.readAsBytesSync(), a.bytes);
      expect(File('${saved.path}:Zone.Identifier').existsSync(), isFalse);
      expect(
        s.coordinator.lastReceived?.outcome,
        TransferOutcome.savedWithoutMark,
      );
      expect(s.coordinator.lastReceived?.canReveal, isTrue);
      await expectNothingLeft(s, s.receiveDir);
    });

    test('E38 RF-230 the hidden, read-only 2020 source arrives as a plain '
        'file dated now', () async {
      final s = await stack();
      final origin = Directory('${s.base}\\origen')..createSync();
      final source = File('${origin.path}\\informe.txt')
        ..writeAsBytesSync(randomBytes(8 * kib, 38));
      source.setLastModifiedSync(DateTime(2020, 3, 1, 12));
      final set = await Process.run('attrib', ['+h', '+r', source.path]);
      expect(set.exitCode, 0, reason: '${set.stderr}');
      addTearDown(() => Process.run('attrib', ['-h', '-r', source.path]));
      expect(attributesOf(source.path) & FILE_ATTRIBUTE_HIDDEN, isNot(0));
      expect(attributesOf(source.path) & FILE_ATTRIBUTE_READONLY, isNot(0));
      expect(source.lastModifiedSync().year, 2020);

      final bytes = source.readAsBytesSync();
      final a = await accept(s, laptop, bytes);
      final started = DateTime.now();
      final result = await s.postUpload(
        laptop.identity,
        headers: a.headers,
        contentLength: bytes.length,
        body: source.openRead(),
      );
      expectState(answered(result), {'state': 'saved', 'marked': true});

      final saved = '${s.receiveDir}\\informe.txt';
      expect(File(saved).readAsBytesSync(), bytes);
      final attributes = attributesOf(saved);
      expect(attributes & FILE_ATTRIBUTE_HIDDEN, 0);
      expect(attributes & FILE_ATTRIBUTE_READONLY, 0);
      final modified = File(saved).lastModifiedSync();
      expect(
        modified.isAfter(started.subtract(const Duration(seconds: 5))),
        isTrue,
        reason: '$modified',
      );
      await expectNothingLeft(s, s.receiveDir);
    });
  });

  group('T9 RF-170 RF-171 RF-173 RF-177 RF-227 a file that cannot be kept', () {
    test('E92 a different content of the same size is damaged on both sides '
        'and leaves nothing', () async {
      final s = await stack();
      final good = randomBytes(64 * kib, 92);
      final a = await accept(s, laptop, good);
      final other = Uint8List.fromList(good)..[1000] ^= 0xFF;

      expectState(answered(await send(s, laptop, a, bytes: other)), {
        'state': 'failed',
        'reason': 'damaged',
      });

      expect(treeOf(s.receiveDir), isEmpty);
      expect(s.coordinator.lastReceived?.outcome, TransferOutcome.damaged);
      expect(s.coordinator.lastReceived?.canReveal, isFalse);
      expect(s.coordinator.lastReceived?.fileName, 'informe.txt');
      await expectNothingLeft(s, s.receiveDir);
      expectCleanLogs(s, [a.permit]);
    });

    test('RF-173 a mark that cannot be set deletes the temporary', () async {
      final s = await stack(configure: (p) => p.mark = (_) async => false);
      final a = await accept(s, laptop, randomBytes(4 * kib, 173));

      expectState(answered(await send(s, laptop, a)), {
        'state': 'failed',
        'reason': 'mark_failed',
      });

      expect(treeOf(s.receiveDir), isEmpty);
      expect(s.coordinator.lastReceived?.outcome, TransferOutcome.markFailed);
      await expectNothingLeft(s, s.receiveDir);
    });

    test('RF-177 a move that fails deletes the temporary', () async {
      final s = await stack(
        configure: (p) => p.move = (_, _, _) async => const MoveFailed(),
      );
      final a = await accept(s, laptop, randomBytes(4 * kib, 177));

      expectState(answered(await send(s, laptop, a)), {
        'state': 'failed',
        'reason': 'move_failed',
      });

      expect(treeOf(s.receiveDir), isEmpty);
      expect(s.coordinator.lastReceived?.outcome, TransferOutcome.moveFailed);
      await expectNothingLeft(s, s.receiveDir);
    });

    test('RF-227 no free name up to 9999 deletes the temporary', () async {
      final s = await stack(
        configure: (p) => p.move = (_, _, _) async => const NoFreeName(),
      );
      final a = await accept(s, laptop, randomBytes(4 * kib, 227));

      expectState(answered(await send(s, laptop, a)), {
        'state': 'failed',
        'reason': 'no_free_name',
      });

      expect(treeOf(s.receiveDir), isEmpty);
      expect(s.coordinator.lastReceived?.outcome, TransferOutcome.noFreeName);
      await expectNothingLeft(s, s.receiveDir);
    });
  });

  group('T9 RF-165 D13 announced length', () {
    test('[SEG] E88 a Content-Length one byte over the size fails with '
        'too_many_bytes and writes nothing', () async {
      final s = await stack();
      final a = await accept(s, laptop, randomBytes(2 * kib, 88));
      final callsBefore = s.platform.calls.length;

      expectState(
        answered(await send(s, laptop, a, bytes: randomBytes(2 * kib + 1, 1))),
        {'state': 'failed', 'reason': 'too_many_bytes'},
      );

      expect(treeOf(s.receiveDir), isEmpty);
      expect(s.coordinator.lastReceived?.outcome, TransferOutcome.tooManyBytes);
      await expectNothingLeft(s, s.receiveDir);
      expect(s.platform.calls.skip(callsBefore), isEmpty);
    });

    test('[SEG] E88 with a size over 64 KiB the extra byte also cuts and '
        'leaves nothing', () async {
      final s = await stack();
      final a = await accept(s, laptop, randomBytes(200 * kib, 881));

      final result = await send(
        s,
        laptop,
        a,
        bytes: randomBytes(200 * kib + 1, 2),
      );
      if (result is StreamPostAnswered) {
        expectState(answered(result), {
          'state': 'failed',
          'reason': 'too_many_bytes',
        });
      }

      expect(treeOf(s.receiveDir), isEmpty);
      expect(s.coordinator.lastReceived?.outcome, TransferOutcome.tooManyBytes);
      await expectNothingLeft(s, s.receiveDir);
    });

    test('a Content-Length under the size fails with connection_lost and '
        'writes nothing', () async {
      final s = await stack();
      final a = await accept(s, laptop, randomBytes(2 * kib, 87));

      expectState(
        answered(
          await send(
            s,
            laptop,
            a,
            bytes: Uint8List.sublistView(a.bytes, 0, 2 * kib - 1),
          ),
        ),
        {'state': 'failed', 'reason': 'connection_lost'},
      );

      expect(treeOf(s.receiveDir), isEmpty);
      expect(
        s.coordinator.lastReceived?.outcome,
        TransferOutcome.connectionLost,
      );
      await expectNothingLeft(s, s.receiveDir);
    });

    test('E89 RF-231 a client that closes halfway ends in connectionLost '
        'without temporary or subfolder', () async {
      final s = await stack();
      final a = await accept(s, laptop, randomBytes(2 * mib, 89));
      late Future<StreamPostResult> result;
      final held = await startHeld(s, laptop, a, 512 * kib, (r) => result = r);
      expect(Directory(subOf(s.receiveDir)).existsSync(), isTrue);

      held.breakOff();

      final outcome = await result;
      expect(outcome, isA<StreamPostFailed>());
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
    });
  });

  group('[SEG] E83 E84 E85 RF-158 RF-159 RF-160 the upload permit', () {
    test('E83 no header, a wrong permit or a malformed one get the same 403 '
        'and write nothing; then the right upload works', () async {
      final s = await stack();
      final a = await accept(s, laptop, randomBytes(2 * kib, 83));
      final wrong = newTransferId();
      final attempts = <String, Map<String, String>>{
        'no headers': {},
        'no permit': headersFor(a.transfer, null),
        'no transfer': {TransferHeaders.permit: a.permit},
        'wrong permit': headersFor(a.transfer, wrong),
        'upper case permit': headersFor(a.transfer, a.permit.toUpperCase()),
        'short permit': headersFor(a.transfer, a.permit.substring(1)),
        'long permit': headersFor(a.transfer, '${a.permit}0'),
        'wrong transfer': headersFor(newTransferId(), a.permit),
      };
      List<int>? first;
      for (final MapEntry(key: label, value: headers) in attempts.entries) {
        final reply = answered(await send(s, laptop, a, headers: headers));
        expectForbidden(reply);
        first ??= reply.body;
        expect(reply.body, first, reason: label);
        expect(treeOf(s.receiveDir), isEmpty, reason: label);
        expect(s.journal.folders, isEmpty, reason: label);
        expect(s.incoming?.stage, IncomingStage.waitingData, reason: label);
      }
      expect(s.handledOn(ApiPaths.transferUpload), attempts.length);
      expect(s.coordinator.lastReceived, isNull);

      expectState(answered(await send(s, laptop, a)), {
        'state': 'saved',
        'marked': true,
      });
      expect(File('${s.receiveDir}\\informe.txt').readAsBytesSync(), a.bytes);
      expectCleanLogs(s, [a.permit, wrong]);
    });

    test('E84 another paired device with the id and permit of the sender '
        'gets 403; then the sender uploads', () async {
      final s = await stack();
      final a = await accept(s, laptop, randomBytes(2 * kib, 84));

      expectForbidden(answered(await send(s, desk, a)));
      expect(treeOf(s.receiveDir), isEmpty);
      expect(s.incoming?.stage, IncomingStage.waitingData);

      expectState(answered(await send(s, laptop, a)), {
        'state': 'saved',
        'marked': true,
      });
      expect(s.coordinator.lastReceived?.peerFingerprint, laptop.fingerprint);
    });

    test('E85 a second upload after saving gets 403', () async {
      final s = await stack();
      final a = await accept(s, laptop, randomBytes(2 * kib, 85));
      expectState(answered(await send(s, laptop, a)), {
        'state': 'saved',
        'marked': true,
      });
      final after = treeOf(s.receiveDir);

      expectForbidden(
        answered(await send(s, laptop, a, bytes: randomBytes(2 * kib, 5))),
      );

      expect(treeOf(s.receiveDir), after);
      expect(File('${s.receiveDir}\\informe.txt').readAsBytesSync(), a.bytes);
      expect(s.coordinator.lastReceived?.outcome, TransferOutcome.saved);
    });

    test('E85 a second upload while the first is running gets 403 and the '
        'first one still saves', () async {
      final s = await stack();
      final a = await accept(s, laptop, randomBytes(256 * kib, 851));
      late Future<StreamPostResult> result;
      final held = await startHeld(s, laptop, a, 64 * kib, (r) => result = r);

      expectForbidden(answered(await send(s, laptop, a)));
      expect(s.incoming?.stage, IncomingStage.receiving);
      expect(
        Directory(subOf(s.receiveDir)).listSync().whereType<File>(),
        hasLength(1),
      );

      held.sendAll(Uint8List.sublistView(a.bytes, 64 * kib));
      held.finish();
      expectState(answered(await result), {'state': 'saved', 'marked': true});
      expect(treeOf(s.receiveDir), ['informe.txt']);
      await expectNothingLeft(s, s.receiveDir);
    });

    test('E85 two uploads racing with the same permit: one saves, the other '
        'gets 403', () async {
      final s = await stack();
      final a = await accept(s, laptop, randomBytes(2 * kib, 852));

      final replies = [
        for (final r in await Future.wait([
          send(s, laptop, a),
          send(s, laptop, a),
        ]))
          answered(r),
      ]..sort((x, y) => x.status.compareTo(y.status));

      expectState(replies.first, {'state': 'saved', 'marked': true});
      expectForbidden(replies.last);
      expect(treeOf(s.receiveDir), ['informe.txt']);
      expect(File('${s.receiveDir}\\informe.txt').readAsBytesSync(), a.bytes);
    });

    test(
      'the permit of an earlier session never opens the current one',
      () async {
        final s = await stack();
        final old = await accept(s, laptop, randomBytes(2 * kib, 11));
        s.coordinator.cancelIncoming(s.sid);
        expect(
          s.coordinator.lastReceived?.outcome,
          TransferOutcome.cancelledHere,
        );
        final now = await accept(s, laptop, randomBytes(2 * kib, 12));

        for (final headers in [
          headersFor(now.transfer, old.permit),
          headersFor(old.transfer, old.permit),
          headersFor(old.transfer, now.permit),
        ]) {
          expectForbidden(
            answered(await send(s, laptop, now, headers: headers)),
          );
        }
        expect(treeOf(s.receiveDir), isEmpty);
        expect(s.incoming?.stage, IncomingStage.waitingData);

        expectState(answered(await send(s, laptop, now)), {
          'state': 'saved',
          'marked': true,
        });
        expect(
          File('${s.receiveDir}\\informe.txt').readAsBytesSync(),
          now.bytes,
        );
        expectCleanLogs(s, [old.permit, now.permit]);
      },
    );

    test('without a session, or with one still showing the warning, an '
        'upload gets 403', () async {
      final s = await stack();
      final bytes = randomBytes(2 * kib, 13);
      final none = Accepted(newTransferId(), newTransferId(), bytes);
      expectForbidden(answered(await send(s, laptop, none)));
      expect(s.incoming, isNull);

      final transfer = newTransferId();
      final offer = await s.post(
        portatil.identity,
        ApiPaths.transferOffer,
        s.offerBody(
          transfer: transfer,
          name: 'informe.txt',
          size: bytes.length,
          sha256: digestOf(bytes),
        ),
      );
      expect(offer?.status, 202);
      await eventually(() => s.incoming?.stage == IncomingStage.warning);
      expectForbidden(
        answered(
          await send(s, portatil, Accepted(transfer, newTransferId(), bytes)),
        ),
      );
      expect(s.incoming?.stage, IncomingStage.warning);
      expect(treeOf(s.receiveDir), isEmpty);
      expect(s.journal.folders, isEmpty);
      expect(s.handledOn(ApiPaths.transferUpload), 2);
    });

    test('E54 SEC-04 an unpaired identity never reaches the upload '
        'handler', () async {
      final s = await stack();
      final bytes = randomBytes(2 * kib, 54);
      final offer = await s.post(
        stranger,
        ApiPaths.transferOffer,
        s.offerBody(
          transfer: newTransferId(),
          size: bytes.length,
          sha256: digestOf(bytes),
        ),
      );
      if (offer != null) expect(offer.status, 401, reason: offer.text);

      for (final context in [
        stranger.clientContext(presentCertificate: true),
        stranger.clientContext(),
      ]) {
        final result = await s.postUpload(
          stranger,
          headers: headersFor(newTransferId(), newTransferId()),
          contentLength: bytes.length,
          body: chunked(bytes),
          context: context,
        );
        if (result is StreamPostAnswered) {
          expect(result.response.status, 401);
        }
      }

      expect(s.handledTotal, 0);
      expect(s.handledOn(ApiPaths.transferUpload), 0);
      expect(s.views, isEmpty);
      expect(s.incoming, isNull);
      expect(treeOf(s.receiveDir), isEmpty);
      expect(s.journal.folders, isEmpty);
    });
  });

  group('[SEG] E187 RF-197 paths and permits stay out of the logs', () {
    test('a receive folder renamed after accepting gives write_failed and the '
        'log has the error type, never the path or the user', () async {
      final marker = 'nb-e187-${newTransferId().substring(0, 16)}';
      late String folder;
      final s = await stack(
        rememberedPath: (base) {
          folder = '$base\\$marker';
          Directory(folder).createSync();
          return folder;
        },
      );
      final a = await accept(s, laptop, randomBytes(2 * kib, 187));
      final moved = '${s.base}\\movida';
      Directory(folder).renameSync(moved);

      final reply = answered(await send(s, laptop, a));
      expectState(reply, {'state': 'failed', 'reason': 'write_failed'});
      expect(reply.text, isNot(contains(marker)));

      expect(s.coordinator.lastReceived?.outcome, TransferOutcome.writeFailed);
      expect(s.logs.any(ioErrorType.hasMatch), isTrue, reason: '${s.logs}');
      final user = Platform.environment['USERNAME']!.toLowerCase();
      expect(s.base.toLowerCase(), contains(user));
      for (final line in s.logs) {
        final lower = line.toLowerCase();
        expect(lower, isNot(contains(marker)));
        expect(lower, isNot(contains(user)));
        expect(lower, isNot(contains(folder.toLowerCase())));
        expect(lower, isNot(contains(moved.toLowerCase())));
      }
      expectCleanLogs(s, [a.permit]);
      expect(treeOf(moved), isEmpty);
      expect(Directory(folder).existsSync(), isFalse);
      await expectNothingLeft(s, folder);
    });
  });

  group(
    '[SEG] RF-234 RF-235 the cleanup never deletes an active temporary',
    () {
      test('cleanupAtStart during an upload keeps the temporary being written '
          'and the upload still saves', () async {
        final s = await stack();
        final a = await accept(s, laptop, randomBytes(2 * mib, 234));
        late Future<StreamPostResult> result;
        final held = await startHeld(
          s,
          laptop,
          a,
          mib + 64 * kib,
          (r) => result = r,
        );
        final sub = subOf(s.receiveDir);
        final active = Directory(sub).listSync().whereType<File>().single.path;
        final stale = File('$sub\\$tempPrefix${newTransferId()}$tempSuffix')
          ..writeAsStringSync('old partial');
        expect(journalPaths(s), [s.receiveDir.toLowerCase()]);

        await s.coordinator.cleanupAtStart();

        expect(File(active).existsSync(), isTrue);
        expect(File(active).lengthSync(), greaterThanOrEqualTo(mib));
        expect(stale.existsSync(), isFalse);
        expect(journalPaths(s), [s.receiveDir.toLowerCase()]);
        expect(s.incoming?.stage, IncomingStage.receiving);

        held.sendAll(Uint8List.sublistView(a.bytes, mib + 64 * kib));
        held.finish();
        expectState(answered(await result), {'state': 'saved', 'marked': true});
        expect(File('${s.receiveDir}\\informe.txt').readAsBytesSync(), a.bytes);
        expect(treeOf(s.receiveDir), ['informe.txt']);
        await expectNothingLeft(s, s.receiveDir);
      });
    },
  );

  group('T9 plan point 66 sessions during the upload', () {
    test('a valid upload on an accepted session not yet shown shows it '
        'and saves', () async {
      final s = await stack(
        routesOverride: (stack) => [
          for (final route in stack.coordinator.routes)
            route.path == ApiPaths.transferOffer
                ? ApiRoute(
                    path: route.path,
                    access: route.access,
                    maxBodyBytes: route.maxBodyBytes,
                    limit: route.limit,
                    handle: (call) async {
                      final reply = await route.handle(call);
                      return ApiReply(
                        reply.status,
                        reply.json,
                        onUndelivered: reply.onUndelivered,
                      );
                    },
                  )
                : route,
        ],
      );
      final a = await accept(
        s,
        laptop,
        randomBytes(64 * kib, 66),
        shown: false,
      );
      await settle();
      expect(s.incoming, isNull);
      expect(s.seen, isEmpty);

      late Future<StreamPostResult> result;
      final held = await startHeld(s, laptop, a, 16 * kib, (r) => result = r);
      expect(s.incoming?.peerFingerprint, laptop.fingerprint);

      held.sendAll(Uint8List.sublistView(a.bytes, 16 * kib));
      held.finish();
      expectState(answered(await result), {'state': 'saved', 'marked': true});
      expect(s.coordinator.lastReceived?.outcome, TransferOutcome.saved);
      await expectNothingLeft(s, s.receiveDir);
    });

    test('A17 wait is held while uploading and while saving; a cancel while '
        'saving waits for the end, answers saved and the file is '
        'saved', () async {
      final markGate = Completer<void>();
      final markReached = Completer<void>();
      final s = await stack(
        pollHold: const Duration(seconds: 4),
        configure: (p) => p.mark = (path) async {
          if (!markReached.isCompleted) markReached.complete();
          await markGate.future;
          return realFs.markFromInternet(path);
        },
      );
      addTearDown(() {
        if (!markGate.isCompleted) markGate.complete();
      });
      final a = await accept(s, laptop, randomBytes(128 * kib, 17));
      late Future<StreamPostResult> result;
      final held = await startHeld(s, laptop, a, 32 * kib, (r) => result = r);

      final uploadingWait = Pending(s.wait(laptop, a.transfer));
      await settle(const Duration(milliseconds: 400));
      expect(uploadingWait.done, isFalse, reason: 'wait held while uploading');

      held.sendAll(Uint8List.sublistView(a.bytes, 32 * kib));
      held.finish();
      await markReached.future;
      await eventually(() => uploadingWait.done, reason: 'wait woken');
      expect(uploadingWait.result?.json, {'state': 'saving'});
      expect(s.incoming?.stage, IncomingStage.verifying);
      expect(s.incoming?.receivedBytes, a.bytes.length);

      final savingWait = Pending(s.wait(laptop, a.transfer));
      await settle(const Duration(milliseconds: 400));
      expect(savingWait.done, isFalse, reason: 'wait held while saving');

      final cancel = Pending(s.cancel(laptop, a.transfer));
      await settle(const Duration(milliseconds: 400));
      expect(cancel.done, isFalse, reason: 'cancel waits while saving');
      expect(s.incoming?.stage, IncomingStage.verifying);

      markGate.complete();
      expectState(answered(await result), {'state': 'saved', 'marked': true});
      await eventually(() => cancel.done, reason: 'cancel answered at the end');
      expect(cancel.result?.status, 200);
      expect(cancel.result?.json, {'state': 'saved', 'marked': true});
      await eventually(() => savingWait.done, reason: 'wait woken at the end');
      expect(savingWait.result?.json, {'state': 'saved', 'marked': true});
      expect(File('${s.receiveDir}\\informe.txt').readAsBytesSync(), a.bytes);
      expect(s.coordinator.lastReceived?.outcome, TransferOutcome.saved);
      await expectNothingLeft(s, s.receiveDir);
    });

    for (final (reason, outcome, json) in [
      (
        'cancelled',
        TransferOutcome.cancelledByPeer,
        <String, Object?>{'state': 'cancelled'},
      ),
      (
        'unreadable',
        TransferOutcome.unreadable,
        <String, Object?>{'state': 'failed', 'reason': 'unreadable'},
      ),
    ]) {
      test('A17 a remote cancel "$reason" while uploading ends the session, '
          'cuts the upload and deletes the temporary', () async {
        final s = await stack();
        final a = await accept(s, laptop, randomBytes(mib, 171));
        late Future<StreamPostResult> result;
        await startHeld(s, laptop, a, 128 * kib, (r) => result = r);
        expect(Directory(subOf(s.receiveDir)).existsSync(), isTrue);

        final cancel = await s.cancel(laptop, a.transfer, reason: reason);
        expect(cancel?.status, 200);
        expect(cancel?.json, json);

        expect(await result, isA<StreamPostFailed>());
        expect(s.coordinator.lastReceived?.outcome, outcome);
        await expectNothingLeft(s, s.receiveDir);
        expect(treeOf(s.receiveDir), isEmpty);
        expect((await s.wait(laptop, a.transfer))?.json, json);
      });
    }

    test('A24 closing the coordinator while uploading cuts the upload and '
        'leaves no temporary', () async {
      final s = await stack();
      final a = await accept(s, laptop, randomBytes(mib, 24));
      late Future<StreamPostResult> result;
      await startHeld(s, laptop, a, 128 * kib, (r) => result = r);

      await s.coordinator.close();

      expect(await result, isA<StreamPostFailed>());
      expect(
        s.coordinator.lastReceived?.outcome,
        TransferOutcome.cancelledHere,
      );
      expect(Directory(subOf(s.receiveDir)).existsSync(), isFalse);
      expect(s.journal.folders, isEmpty);
      expect(treeOf(s.receiveDir), isEmpty);
    });
  });

  test('the upload route is paired only, outside the anonymous paths and '
      'limited to 300 a minute per address', () async {
    final s = await stack();
    final route = s.coordinator.uploadRoutes.singleWhere(
      (route) => route.path == ApiPaths.transferUpload,
    );
    expect(route.path, ApiPaths.transferUpload);
    expect(ApiPaths.anonymous, isNot(contains(route.path)));
    expect(route.limit?.maxPerWindow, 300);
    expect(route.limit?.window, const Duration(minutes: 1));
    expect(route.limit?.block, const Duration(minutes: 1));
    expect(
      s.coordinator.routes.map((r) => r.path),
      isNot(contains(ApiPaths.transferUpload)),
    );
  });
}
