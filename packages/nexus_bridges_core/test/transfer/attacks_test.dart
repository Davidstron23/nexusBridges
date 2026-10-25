@TestOn('windows')
library;

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:nexus_bridges_core/src/identity/identity.dart';
import 'package:nexus_bridges_core/src/node/node.dart';
import 'package:nexus_bridges_core/src/pairing/pairing.dart';
import 'package:nexus_bridges_core/src/protocol/protocol.dart';
import 'package:nexus_bridges_core/src/transfer/transfer.dart'
    show SendStart, SendTarget;
import 'package:nexus_bridges_core/src/transport/transport.dart';
import 'package:test/test.dart';

import '../support/infra.dart';
import 'attacks_harness.dart';
import 'transfer_stacks_harness.dart' show TransferStack, hostA, hostF;

const Timeout long = Timeout(Duration(minutes: 2));

const String forbiddenText = '{"error":"forbidden"}';

const PeerRelation mine = PeerRelation.mine;

const PeerRelation foreign = PeerRelation.foreign;

void expectForbidden(StreamPostResult result) {
  final reply = answeredOf(result);
  expect(reply?.status, 403, reason: '$result');
  expect(reply!.text, forbiddenText);
}

void expectCut(StreamPostResult result) {
  expect(result, isA<StreamPostFailed>());
  expect(
    (result as StreamPostFailed).failure,
    isIn([StreamPostFailure.notConnected, StreamPostFailure.connectionLost]),
  );
}

Future<void> expectNothingIn(TransferNode b) async {
  await eventually(
    () => !anyTempIn(b.receiveDir),
    limit: scaled(nodeLimit),
    reason: 'no temporary file left',
  );
  expect(treeOf(b.receiveDir), isEmpty);
  await eventually(
    () async => (await b.journalFolders()).isEmpty,
    limit: scaled(nodeLimit),
    reason: 'cleanup journal empty',
  );
}

Future<(TransferNode, TransferNode)> twoNodes({
  PeerRelation aAtB = mine,
  bool remembered = true,
  void Function(TransferNode b)? configureB,
}) async {
  final [a, b] = await transferNodes(['Laptop', 'Sobremesa']);
  await a.trust([(b, mine)]);
  await b.trust([(a, aAtB)]);
  if (remembered) await b.rememberReceiveFolder();
  configureB?.call(b);
  await startAll([a, b]);
  await meetAll([a, b]);
  await canSend(a, b);
  return (a, b);
}

Future<(TransferNode, TransferNode, TransferNode)> threeNodes({
  bool secondInterfaceOnB = false,
}) async {
  final [a, b, c] = await transferNodes([
    'Laptop',
    'Sobremesa',
    'Tableta',
  ], extraHosts: secondInterfaceOnB ? const ['127.0.0.4'] : const []);
  await a.trust([(b, mine)]);
  await c.trust([(b, mine)]);
  await b.trust([(a, mine), (c, mine)]);
  await b.rememberReceiveFolder();
  if (secondInterfaceOnB) {
    b.interfaces = [
      (adapterId: wifiId, address: b.address),
      (adapterId: ethernetId, address: '127.0.0.4'),
    ];
  }
  await startAll([a, b, c]);
  await meetAll([a, b, c]);
  await canSend(a, b);
  await canSend(c, b);
  return (a, b, c);
}

Future<void> exhaustPairStatus(TransferNode b, InternetAddress from) async {
  final stranger = DeviceIdentity.generate();
  Future<int?> ask() async => (await postJson(
    address: b.internetAddress,
    port: b.port,
    path: ApiPaths.pairStatus,
    json: const <String, Object?>{},
    context: stranger.clientContext(),
    acceptServer: (certificate) =>
        certificateMatches(certificate, b.fingerprint),
    sourceAddress: from,
  ))?.status;
  for (var i = 0; i < Limits.pairStatusPerMinute; i++) {
    await ask();
  }
  expect(await ask(), 429);
}

Future<String> waitingSession(TransferNode b) async {
  final s = await b.until(
    (s) => s.incoming?.stage == IncomingStage.warning,
    reason: '${b.name} warning on screen',
  );
  return s.incoming!.sessionId;
}

Future<void> waitingData(TransferNode b) => b.until(
  (s) => s.incoming?.stage == IncomingStage.waitingData,
  reason: '${b.name} waiting for the data',
);

void main() {
  group('E147 SEC-04 RF-216 RF-189 unpaired and unpaired halfway with real '
      'nodes', () {
    test('C, not paired at B, sends from its own node: the offer is cut in '
        'the handshake, a forged upload too, and nothing reaches B', () async {
      final [a, b, c] = await transferNodes(['Laptop', 'Sobremesa', 'Intruso']);
      await a.trust([(b, mine)]);
      await b.trust([(a, mine)]);
      await c.trust([(b, mine)]);
      await b.rememberReceiveFolder();
      await startAll([a, b], later: [c]);
      await exhaustPairStatus(b, c.internetAddress);
      await c.start();
      await meetAll([a, b, c]);
      await canSend(c, b);
      await Future<void>.delayed(const Duration(milliseconds: 1500));
      expect(c.entryOf(b)?.mismatch, isFalse);
      final inspected = b.platform.calls.length;

      final path = await c.sourceFile(
        'informe.bin',
        patternBytes(256 * kib, 1),
      );
      expect(await c.sendTo(b, path), SendFileResult.started);
      final sent = await c.sentResult();
      expect(sent.outcome, TransferOutcome.noContact);
      expect(sent.peerFingerprint, b.fingerprint);

      final forged = b.forgedAs(c);
      final body = patternBytes(4 * kib, 2);
      expectCut(
        await forged.upload(
          transfer: newTransferId(),
          permit: newTransferId(),
          contentLength: body.length,
          body: chunksOf(body),
        ),
      );
      expect(
        await forged.offer(
          transfer: newTransferId(),
          name: 'informe.bin',
          size: body.length,
          sha256: digestOf(body),
        ),
        isNull,
      );
      expect(await forged.cutInHandshake(), isTrue);
      expect(await b.forgedAs(a).cutInHandshake(), isFalse);

      await Future<void>.delayed(const Duration(milliseconds: 300));
      expect(b.platform.calls.length, inspected);
      expect(b.state.incoming, isNull);
      expect(b.state.lastReceived, isNull);
      expect(b.state.transferInProgress, isFalse);
      expect(b.state.notices, isEmpty);
      await expectNothingIn(b);
    }, timeout: long);

    test('with its own state check C sees the mismatch and its node does not '
        'even open the picker', () async {
      final [a, b, c] = await transferNodes(['Laptop', 'Sobremesa', 'Intruso']);
      await a.trust([(b, mine)]);
      await b.trust([(a, mine)]);
      await c.trust([(b, mine)]);
      await b.rememberReceiveFolder();
      await startAll([a, b, c]);
      await meetAll([a, b, c]);
      await eventually(
        () => c.entryOf(b)?.mismatch == true,
        limit: scaled(nodeLimit),
        reason: 'C sees the mismatch',
      );
      final inspected = b.platform.calls.length;

      final path = await c.sourceFile('informe.bin', patternBytes(4 * kib, 3));
      expect(await c.sendTo(b, path), SendFileResult.unavailable);
      expect(c.picker.fileCalls, 0);
      await Future<void>.delayed(const Duration(milliseconds: 300));
      expect(c.state.lastSent, isNull);
      expect(b.platform.calls.length, inspected);
      expect(b.state.lastReceived, isNull);
      expect(treeOf(b.receiveDir), isEmpty);
    }, timeout: long);

    test('A uploading to B and B unpairs A halfway: the upload is cut, '
        'unpaired on both, and no temporary file', () async {
      final throttle = WriteThrottle(delay: const Duration(milliseconds: 10));
      final (a, b) = await twoNodes(
        configureB: (b) => b.writeBytes = throttle.call,
      );
      final path = await a.sourceFile('grande.bin', patternBytes(24 * mib, 4));

      expect(await a.sendTo(b, path), SendFileResult.started);
      await b.until(
        (s) =>
            s.incoming?.stage == IncomingStage.receiving &&
            s.incoming!.receivedBytes > 0,
        reason: 'B receiving',
      );
      expect(Directory(b.tempSub).existsSync(), isTrue);
      await b.node.unpair(a.fingerprint);

      final received = await b.receivedResult();
      expect(received.outcome, TransferOutcome.unpaired);
      final sent = await a.sentResult();
      expect(sent.outcome, TransferOutcome.unpaired);
      await expectNothingIn(b);
      await eventually(
        () => a.entryOf(b)?.paired == false,
        limit: scaled(nodeLimit),
        reason: 'A no longer paired with B',
      );
      expect(throttle.written, lessThan(24 * mib));
    }, timeout: long);

    test('a permit obtained before the unpairing is cut in the handshake when '
        'A retries with it', () async {
      final (a, b) = await twoNodes(
        configureB: (b) =>
            b.writeBytes = WriteThrottle(delay: const Duration(milliseconds: 5))
                .call,
      );
      final forged = b.forgedAs(a);
      final content = patternBytes(8 * mib, 5);
      final grant = await forged.grant(content);
      final gate = Completer<void>();
      addTearDown(() {
        if (!gate.isCompleted) gate.complete();
      });
      Stream<List<int>> stalled() async* {
        yield content.sublist(0, mib);
        await gate.future;
        yield content.sublist(mib);
      }

      final first = forged.upload(
        transfer: grant.transfer,
        permit: grant.permit,
        contentLength: content.length,
        body: stalled(),
      );
      await b.until(
        (s) =>
            s.incoming?.stage == IncomingStage.receiving &&
            s.incoming!.receivedBytes > 0,
        reason: 'B receiving',
      );
      await b.node.unpair(a.fingerprint);
      expect((await b.receivedResult()).outcome, TransferOutcome.unpaired);
      gate.complete();
      final cut = await first;
      expect(outcomeOfReply(answeredOf(cut)), isNot(TransferOutcome.saved));

      expectCut(await forged.send(grant));
      expect(await forged.cutInHandshake(), isTrue);
      await expectNothingIn(b);
      expect(b.state.lastReceived?.outcome, TransferOutcome.unpaired);
    }, timeout: long);
  });

  group('E148 SEC-08 RF-158 to RF-161 permits with three real nodes', () {
    test('C, paired with B, presents the permit of A: 403 and B unchanged; '
        'then A uploads with the same permit', () async {
      final (a, b, c) = await threeNodes();
      final content = patternBytes(256 * kib, 6);
      final grant = await b.forgedAs(a).grant(content);
      await waitingData(b);
      final before = treeOf(b.receiveDir);
      final fromC = b.forgedAs(c);

      expectForbidden(
        await fromC.upload(
          transfer: grant.transfer,
          permit: grant.permit,
          contentLength: content.length,
          body: chunksOf(content),
        ),
      );
      expect(treeOf(b.receiveDir), before);
      expectForbidden(
        await fromC.upload(
          transfer: newTransferId(),
          permit: grant.permit,
          contentLength: content.length,
          body: chunksOf(content),
        ),
      );
      expect(treeOf(b.receiveDir), before);
      expect(b.state.incoming?.stage, IncomingStage.waitingData);
      expect(b.state.lastReceived, isNull);

      final saved = await b.forgedAs(a).send(grant);
      expect(outcomeOfReply(answeredOf(saved)), TransferOutcome.saved);
      expect(File('${b.receiveDir}\\informe.bin').readAsBytesSync(), content);
      expect(b.state.lastReceived?.peerFingerprint, a.fingerprint);
    }, timeout: long);

    test(
      'A repeats the permit after saving: 403 and nothing changes',
      () async {
        final (a, b, _) = await threeNodes();
        final forged = b.forgedAs(a);
        final content = patternBytes(128 * kib, 7);
        final grant = await forged.grant(content);
        expect(
          outcomeOfReply(answeredOf(await forged.send(grant))),
          TransferOutcome.saved,
        );
        final last = (await b.receivedResult()).outcome;
        expect(last, TransferOutcome.saved);
        final before = treeOf(b.receiveDir);

        expectForbidden(await forged.send(grant));
        expectForbidden(
          await forged.upload(
            transfer: grant.transfer,
            permit: grant.permit,
            contentLength: 1,
            body: chunksOf(const [1]),
          ),
        );
        expect(treeOf(b.receiveDir), before);
        expect(b.state.lastReceived?.outcome, TransferOutcome.saved);
        expect(b.state.incoming?.stage, isNot(IncomingStage.receiving));
      },
      timeout: long,
    );

    test('A presents the permit of another session of its own that already '
        'ended: 403 with either id, then the current one saves', () async {
      final (a, b, _) = await threeNodes();
      final forged = b.forgedAs(a);
      final firstContent = patternBytes(64 * kib, 8);
      final first = await forged.grant(firstContent, name: 'primero.bin');
      expect(
        outcomeOfReply(answeredOf(await forged.send(first))),
        TransferOutcome.saved,
      );
      final secondContent = patternBytes(64 * kib, 9);
      final second = await forged.grant(secondContent, name: 'segundo.bin');
      await waitingData(b);
      final before = treeOf(b.receiveDir);

      expectForbidden(
        await forged.upload(
          transfer: second.transfer,
          permit: first.permit,
          contentLength: secondContent.length,
          body: chunksOf(secondContent),
        ),
      );
      expectForbidden(
        await forged.upload(
          transfer: first.transfer,
          permit: first.permit,
          contentLength: secondContent.length,
          body: chunksOf(secondContent),
        ),
      );
      expect(treeOf(b.receiveDir), before);
      expect(b.state.incoming?.stage, IncomingStage.waitingData);

      expect(
        outcomeOfReply(answeredOf(await forged.send(second))),
        TransferOutcome.saved,
      );
      expect(
        File('${b.receiveDir}\\segundo.bin').readAsBytesSync(),
        secondContent,
      );
    }, timeout: long);

    test('a permit used 31 s after the acceptance: B ends uploadNotStarted '
        'and the upload gets 403', () async {
      final (a, b, _) = await threeNodes();
      final forged = b.forgedAs(a);
      final content = patternBytes(64 * kib, 10);
      final grant = await forged.grant(content);
      await waitingData(b);
      b.clock.advance(const Duration(seconds: 31));

      expect(
        (await b.receivedResult()).outcome,
        TransferOutcome.uploadNotStarted,
      );
      final before = treeOf(b.receiveDir);
      expectForbidden(await forged.send(grant));
      expect(treeOf(b.receiveDir), before);
      expect(before, isEmpty);
      expect(b.state.lastReceived?.outcome, TransferOutcome.uploadNotStarted);
    }, timeout: long);

    test('C cannot read the permit of A with wait nor cancel A with its id; A '
        'still saves', () async {
      final (a, b, c) = await threeNodes();
      final content = patternBytes(64 * kib, 11);
      final grant = await b.forgedAs(a).grant(content);
      await waitingData(b);
      final fromC = b.forgedAs(c);

      final peek = await fromC.wait(grant.transfer);
      expect(peek?.status, 404);
      expect(peek!.text, isNot(contains(grant.permit)));
      final cancel = await fromC.cancel(grant.transfer);
      expect(cancel?.status, 200);
      expect(cancel!.state, 'cancelled');
      expect(b.state.incoming?.stage, IncomingStage.waitingData);
      final own = await b.forgedAs(a).wait(grant.transfer);
      expect(own?.state, 'accepted');

      expect(
        outcomeOfReply(answeredOf(await b.forgedAs(a).send(grant))),
        TransferOutcome.saved,
      );
      expect(File('${b.receiveDir}\\informe.bin').readAsBytesSync(), content);
    }, timeout: long);

    test('a permit header sent twice or in upper case is 403 and does not '
        'spend the permit', () async {
      final (a, b, _) = await threeNodes();
      final forged = b.forgedAs(a);
      final content = patternBytes(16 * kib, 26);
      final grant = await forged.grant(content);
      await waitingData(b);
      final transferLine = '${TransferHeaders.transfer}: ${grant.transfer}';

      expect(
        await forged.rawUpload([
          transferLine,
          '${TransferHeaders.permit}: ${newTransferId()}',
          '${TransferHeaders.permit}: ${grant.permit}',
        ], content),
        403,
      );
      expect(
        await forged.rawUpload([
          transferLine,
          '${TransferHeaders.permit}: ${grant.permit.toUpperCase()}',
        ], content),
        403,
      );
      expect(
        await forged.rawUpload([
          '${TransferHeaders.transfer}: ${grant.transfer.toUpperCase()}',
          '${TransferHeaders.permit}: ${grant.permit}',
        ], content),
        403,
      );
      expect(treeOf(b.receiveDir), isEmpty);
      expect(b.state.incoming?.stage, IncomingStage.waitingData);

      expect(
        await forged.rawUpload([
          transferLine,
          '${TransferHeaders.permit.toUpperCase()}: ${grant.permit}',
        ], content),
        200,
      );
      expect((await b.receivedResult()).outcome, TransferOutcome.saved);
      expect(File('${b.receiveDir}\\informe.bin').readAsBytesSync(), content);
    }, timeout: long);

    test(
      'C cancelling a guessed id before A offers it does not block A',
      () async {
        final (a, b, c) = await threeNodes();
        final content = patternBytes(16 * kib, 27);
        final transfer = newTransferId();
        final cancel = await b.forgedAs(c).cancel(transfer);
        expect(cancel?.state, 'cancelled');

        final reply = await b
            .forgedAs(a)
            .offer(
              transfer: transfer,
              name: 'informe.bin',
              size: content.length,
              sha256: digestOf(content),
            );
        expect(reply?.status, 200, reason: reply?.text);
        expect(reply!.state, 'accepted');
        final grant = (
          transfer: transfer,
          permit: reply.json['permit']! as String,
          content: content,
        );
        expect(
          outcomeOfReply(answeredOf(await b.forgedAs(a).send(grant))),
          TransferOutcome.saved,
        );
      },
      timeout: long,
    );

    test('the right permit through another interface of B: 403 without '
        'spending it; through the offer interface it saves', () async {
      final (a, b, _) = await threeNodes(secondInterfaceOnB: true);
      final other = InternetAddress('127.0.0.4');
      final forged = b.forgedAs(a);
      expect(await forged.cutInHandshake(at: other), isFalse);
      final content = patternBytes(64 * kib, 12);
      final grant = await forged.grant(content);
      await waitingData(b);

      expectForbidden(await forged.send(grant, at: other));
      expect(treeOf(b.receiveDir), isEmpty);
      expect(b.state.incoming?.stage, IncomingStage.waitingData);

      expect(
        outcomeOfReply(answeredOf(await forged.send(grant))),
        TransferOutcome.saved,
      );
    }, timeout: long);
  });

  group('E149 SEC-10 RF-165 RF-170 RF-171 data that does not match with real '
      'nodes', () {
    test('a test link that sends size + 1 bytes: tooManyBytes on both and '
        'neither file nor temporary in B', () async {
      final (a, b) = await twoNodes();
      final forged = b.forgedAs(a);
      final content = patternBytes(256 * kib, 13);
      final grant = await forged.grant(content);
      final longer = Uint8List(content.length + 1)
        ..setAll(0, content)
        ..[content.length] = 0x41;

      final result = await forged.upload(
        transfer: grant.transfer,
        permit: grant.permit,
        contentLength: longer.length,
        body: chunksOf(longer),
      );
      expect(outcomeOfReply(answeredOf(result)), TransferOutcome.tooManyBytes);
      expect((await b.receivedResult()).outcome, TransferOutcome.tooManyBytes);
      await expectNothingIn(b);
    }, timeout: long);

    test('a test link that sends other content of the same size: damaged on '
        'both and neither file nor temporary in B', () async {
      final (a, b) = await twoNodes();
      final forged = b.forgedAs(a);
      final content = patternBytes(256 * kib, 14);
      final grant = await forged.grant(content);
      final other = Uint8List.fromList(content)..[1000] ^= 0xFF;

      final result = await forged.upload(
        transfer: grant.transfer,
        permit: grant.permit,
        contentLength: other.length,
        body: chunksOf(other),
      );
      expect(outcomeOfReply(answeredOf(result)), TransferOutcome.damaged);
      expect((await b.receivedResult()).outcome, TransferOutcome.damaged);
      await expectNothingIn(b);
    }, timeout: long);

    test('the node of A whose file changes between the offer and the upload: '
        'damaged on both, nothing in B', () async {
      final (a, b) = await twoNodes(aAtB: foreign);
      final content = patternBytes(512 * kib, 15);
      final path = await a.sourceFile('informe.bin', content);

      expect(await a.sendTo(b, path), SendFileResult.started);
      final session = await waitingSession(b);
      await a.until((s) => s.outgoing?.phase == OutgoingPhase.waiting);
      final changed = Uint8List.fromList(content)..[0] ^= 0x01;
      await File(path).writeAsBytes(changed, flush: true);
      b.node.answerIncoming(session, accept: true);

      expect((await a.sentResult()).outcome, TransferOutcome.damaged);
      expect((await b.receivedResult()).outcome, TransferOutcome.damaged);
      await expectNothingIn(b);
    }, timeout: long);

    test('the node of A whose file grows after the offer sends only the '
        'announced bytes and B saves exactly them', () async {
      final (a, b) = await twoNodes(aAtB: foreign);
      final content = patternBytes(256 * kib, 16);
      final path = await a.sourceFile('informe.bin', content);

      expect(await a.sendTo(b, path), SendFileResult.started);
      final session = await waitingSession(b);
      await File(
        path,
      ).writeAsBytes(patternBytes(mib, 17), mode: FileMode.append, flush: true);
      b.node.answerIncoming(session, accept: true);

      expect((await a.sentResult()).outcome, TransferOutcome.saved);
      expect((await b.receivedResult()).outcome, TransferOutcome.saved);
      expect(File('${b.receiveDir}\\informe.bin').readAsBytesSync(), content);
    }, timeout: long);

    test('a test link that announces fewer bytes than the offer: '
        'connectionLost and nothing in B', () async {
      final (a, b) = await twoNodes();
      final forged = b.forgedAs(a);
      final content = patternBytes(64 * kib, 18);
      final grant = await forged.grant(content);
      final shorter = content.sublist(0, content.length - 1);

      final result = await forged.upload(
        transfer: grant.transfer,
        permit: grant.permit,
        contentLength: shorter.length,
        body: chunksOf(shorter),
      );
      expect(
        outcomeOfReply(answeredOf(result)),
        TransferOutcome.connectionLost,
      );
      expect(
        (await b.receivedResult()).outcome,
        TransferOutcome.connectionLost,
      );
      await expectNothingIn(b);
    }, timeout: long);
  });

  group('E150 SEC-11 RF-149 no space with real nodes', () {
    test('a remembered folder with less than size + 1 GiB free: noSpace in A '
        'and in the last reception of B, nothing created', () async {
      final content = patternBytes(256 * kib, 19);
      final (a, b) = await twoNodes(
        configureB: (b) =>
            b.platform.freeBytesOverride = content.length + gib - 1,
      );
      final path = await a.sourceFile('informe.bin', content);

      expect(await a.sendTo(b, path), SendFileResult.started);
      expect((await a.sentResult()).outcome, TransferOutcome.noSpace);
      final received = await b.receivedResult();
      expect(received.outcome, TransferOutcome.noSpace);
      expect(received.fileName, 'informe.bin');
      expect(b.state.incoming, isNull);
      expect(treeOf(b.receiveDir), isEmpty);
      expect(await b.journalFolders(), isEmpty);
    }, timeout: long);

    test('the first-time question with a folder without room: noSpace in A '
        'and in B, nothing created inside the folder', () async {
      final (a, b) = await twoNodes(
        remembered: false,
        configureB: (b) => b.platform.freeBytesOverride = 10,
      );
      final path = await a.sourceFile(
        'informe.bin',
        patternBytes(64 * kib, 20),
      );

      expect(await a.sendTo(b, path), SendFileResult.started);
      final asked = await b.until(
        (s) => s.incoming?.stage == IncomingStage.folderQuestion,
        reason: 'folder question',
      );
      expect(asked.incoming!.folder?.kind, FolderQuestionKind.firstTime);
      expect(asked.incoming!.folder?.proposedPath, b.proposedDir);
      await b.node.useProposedFolder(asked.incoming!.sessionId);

      expect((await a.sentResult()).outcome, TransferOutcome.noSpace);
      expect((await b.receivedResult()).outcome, TransferOutcome.noSpace);
      expect(treeOf(b.proposedDir), isEmpty);
      expect(treeOf(b.receiveDir), isEmpty);
    }, timeout: long);
  });

  group('E151 SEC-12 RF-172 RF-207 mark of the web with real nodes', () {
    test('B with an NTFS folder: the saved file carries Zone.Identifier with '
        'ZoneId=3', () async {
      final (a, b) = await twoNodes();
      final content = patternBytes(128 * kib, 21);
      final path = await a.sourceFile('factura.pdf', content);

      expect(await a.sendTo(b, path), SendFileResult.started);
      expect((await a.sentResult()).outcome, TransferOutcome.saved);
      final received = await b.receivedResult();
      expect(received.outcome, TransferOutcome.saved);
      final saved = '${b.receiveDir}\\factura.pdf';
      expect(File(saved).readAsBytesSync(), content);
      expect(File('$saved:Zone.Identifier').readAsStringSync(), zoneMark);
    }, timeout: long);

    test('B with fake facts without streams: savedWithoutMark on both and no '
        'stream', () async {
      final (a, b) = await twoNodes(
        configureB: (b) => b.platform.noMarkSupport = true,
      );
      final content = patternBytes(128 * kib, 22);
      final path = await a.sourceFile('factura.pdf', content);

      expect(await a.sendTo(b, path), SendFileResult.started);
      expect((await a.sentResult()).outcome, TransferOutcome.savedWithoutMark);
      expect(
        (await b.receivedResult()).outcome,
        TransferOutcome.savedWithoutMark,
      );
      final saved = '${b.receiveDir}\\factura.pdf';
      expect(File(saved).readAsBytesSync(), content);
      expect(File('$saved:Zone.Identifier').existsSync(), isFalse);
    }, timeout: long);
  });

  group('[SEG] RF-145 RF-211 RF-214 trap names from a paired sender', () {
    final rlo = String.fromCharCode(0x202E);
    final zwsp = String.fromCharCode(0x200B);
    final bom = String.fromCharCode(0xFEFF);
    final nul = String.fromCharCode(0);

    test('paths, streams, reserved names and invisible characters get 422 '
        'and blocked types 415, with no view and nothing written', () async {
      expect(rlo.codeUnits, [0x202E]);
      final (a, b) = await twoNodes();
      final forged = b.forgedAs(a);
      final invalid = [
        r'..\evil.txt',
        '../evil.txt',
        r'C:\Windows\evil.txt',
        r'\\srv\share\evil.txt',
        r'sub\evil.txt',
        'evil.txt:Zone.Identifier',
        r'evil.txt::$DATA',
        'factura${rlo}fdp.exe',
        'evil$zwsp.txt',
        '${bom}evil.txt',
        'evil${nul}x.txt',
        'CON.txt',
        'nul',
        'evil.txt.',
        'evil.txt ',
        '..',
      ];
      final blocked = ['evil.lnk', 'Desktop.ini', 'evil.url', 'evil.scf'];
      final content = patternBytes(kib, 23);

      for (final name in invalid) {
        final reply = await forged.offer(
          transfer: newTransferId(),
          name: name,
          size: content.length,
          sha256: digestOf(content),
        );
        expect(reply?.status, 422, reason: name.codeUnits.toString());
        expect(reply!.error, 'invalid_name');
      }
      for (final name in blocked) {
        final reply = await forged.offer(
          transfer: newTransferId(),
          name: name,
          size: content.length,
          sha256: digestOf(content),
        );
        expect(reply?.status, 415, reason: name);
        expect(reply!.error, 'blocked_type');
      }
      await Future<void>.delayed(const Duration(milliseconds: 200));
      expect(b.state.incoming, isNull);
      expect(b.state.lastReceived, isNull);
      expect(treeOf(b.receiveDir), isEmpty);
      expect(Directory(b.base).listSync().map((e) => e.path).toSet(), {
        for (final child in const [
          'data',
          'recv',
          'source',
          'downloads',
          'sys',
        ])
          '${b.base}\\$child',
      });

      final control = await forged.grant(content, name: 'informe.txt');
      expect(
        outcomeOfReply(answeredOf(await forged.send(control))),
        TransferOutcome.saved,
      );
      expect(treeOf(b.receiveDir).keys, ['informe.txt']);
    }, timeout: long);

    test('the node of A refuses a file whose name carries U+202E before '
        'contacting B', () async {
      final (a, b) = await twoNodes();
      final inspected = b.platform.calls.length;
      final path = await a.sourceFile(
        'informe${rlo}txt.pdf',
        patternBytes(kib, 24),
      );

      expect(await a.sendTo(b, path), SendFileResult.started);
      final sent = await a.sentResult();
      expect(sent.outcome, TransferOutcome.invalidName);
      expect(sent.fileName, isNot(contains(rlo)));
      await Future<void>.delayed(const Duration(milliseconds: 300));
      expect(b.platform.calls.length, inspected);
      expect(b.state.lastReceived, isNull);
    }, timeout: long);
  });

  group('[SEG] a hostile receiver cannot hang the sender', () {
    Future<(TransferStack, HostileReceiver, SendTarget, String)>
    hostile() async {
      final a = await TransferStack.start(name: 'A', address: hostA);
      final receiver = await HostileReceiver.start(hostF);
      await a.trust(receiver.identity, name: 'Hostil');
      final path = await a.sourceFile(
        'informe.bin',
        patternBytes(64 * kib, 25),
      );
      return (
        a,
        receiver,
        a.targetAt(
          receiver.address,
          receiver.port,
          fingerprint: receiver.fingerprint,
        ),
        path,
      );
    }

    for (final declared in const [true, false]) {
      final framing = declared ? 'a declared length' : 'chunked framing';
      final when = declared ? 'at the absolute 10 s' : 'at once';
      test('an answer to the offer with $framing that trickles one byte every '
          '200 ms ends in noContact $when', () async {
        final (a, receiver, target, path) = await hostile();
        receiver.onOffer = (request) =>
            receiver.trickle(request, declared: declared);
        final watch = Stopwatch()..start();

        expect(await a.sendTo(target, path), SendStart.started);
        final sent = await a.sentResult(limit: const Duration(seconds: 20));
        watch.stop();
        expect(sent.outcome, TransferOutcome.noContact);
        if (declared) {
          expect(watch.elapsed, greaterThan(const Duration(seconds: 9)));
          expect(watch.elapsed, lessThan(const Duration(seconds: 13)));
        } else {
          expect(watch.elapsed, lessThan(const Duration(seconds: 5)));
        }
        expect(a.coordinator.sending, isFalse);
        expect(receiver.count(ApiPaths.transferUpload), 0);
      }, timeout: long);

      test('an answer of 1 MiB to the offer with $framing ends in noContact '
          'at once', () async {
        final (a, receiver, target, path) = await hostile();
        receiver.onOffer = (request) => receiver.answerJson(request, 200, {
          'state': 'waiting',
          'pad': 'x' * (1 << 20),
        }, declared: declared);
        final watch = Stopwatch()..start();

        expect(await a.sendTo(target, path), SendStart.started);
        final sent = await a.sentResult(limit: const Duration(seconds: 20));
        expect(sent.outcome, TransferOutcome.noContact);
        expect(watch.elapsed, lessThan(const Duration(seconds: 5)));
        expect(a.coordinator.sending, isFalse);
      }, timeout: long);
    }

    test(
      'an acceptance with a permit that is not 32 lowercase hex never '
      'reaches the upload, and a line break cannot inject a header',
      () async {
        final (a, receiver, target, path) = await hostile();
        final permits = <Object>[
          '${'0' * 32}\r\nX-Injected: 1',
          '0' * 31,
          '0' * 33,
          'ABCDEF0123456789ABCDEF0123456789',
          12345,
        ];
        for (final permit in permits) {
          receiver.onOffer = (request) => receiver.answerJson(request, 200, {
            'state': 'accepted',
            'permit': permit,
          });
          final before = a.coordinator.lastSent;
          expect(await a.sendTo(target, path), SendStart.started);
          final sent = await a.sentResult(
            after: before,
            limit: const Duration(seconds: 20),
          );
          expect(sent.outcome, TransferOutcome.noContact, reason: '$permit');
        }
        expect(receiver.count(ApiPaths.transferUpload), 0);
      },
      timeout: long,
    );
  });
}
