@TestOn('windows')
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:nexus_bridges_core/src/identity/identity.dart';
import 'package:nexus_bridges_core/src/pairing/pairing.dart';
import 'package:nexus_bridges_core/src/protocol/protocol.dart';
import 'package:nexus_bridges_core/src/transfer/folders.dart'
    show tempFolderName;
import 'package:nexus_bridges_core/src/transfer/messages.dart';
import 'package:nexus_bridges_core/src/transfer/transfer.dart';
import 'package:nexus_bridges_core/src/transport/transport.dart';
import 'package:test/test.dart';

import 'folder_manifest_support.dart' show fileLine, folderLine;
import 'receiver_folder_support.dart';
import 'receiver_harness.dart';

const String forbiddenText = '{"error":"forbidden"}';

void expectBusy(RawReply? reply) {
  expect(reply, isNotNull);
  expect(reply!.status, 409, reason: reply.text);
  expect(reply.json, {'error': 'busy'});
}

void expectError(RawReply? reply, int status, String error) {
  expect(reply, isNotNull);
  expect(reply!.status, status, reason: reply.text);
  expect(reply.json, {'error': error});
}

void expectWaitingNoPicker(RawReply? reply, {required int status}) {
  expect(reply, isNotNull);
  expect(reply!.status, status, reason: reply.text);
  expect(reply.json, {'state': 'waiting', 'picker': false});
}

void expectForbidden(RawReply reply) {
  expect(reply.status, 403, reason: reply.text);
  expect(reply.text, forbiddenText);
}

String expectAccepted(RawReply? reply) {
  expect(reply, isNotNull);
  expect(reply!.status, 200, reason: reply.text);
  expect(reply.state, 'accepted', reason: reply.text);
  final permit = reply.json['permit'] as String;
  expect(permit, matches(hex32));
  return permit;
}

FolderOfferRequest withLongest(FolderOfferRequest declared, int longest) =>
    FolderOfferRequest(
      transfer: declared.transfer,
      name: declared.name,
      entries: declared.entries,
      files: declared.files,
      bytes: declared.bytes,
      depth: declared.depth,
      longest: longest,
      manifestBytes: declared.manifestBytes,
    );

FolderOfferRequest withBytes(FolderOfferRequest declared, int bytes) =>
    FolderOfferRequest(
      transfer: declared.transfer,
      name: declared.name,
      entries: declared.entries,
      files: declared.files,
      bytes: bytes,
      depth: declared.depth,
      longest: declared.longest,
      manifestBytes: declared.manifestBytes,
    );

void main() {
  late DeviceIdentity receiver;
  late Peer laptop;
  late Peer portatil;

  setUpAll(() {
    receiver = DeviceIdentity.generate();
    laptop = Peer(DeviceIdentity.generate(), name: 'Laptop');
    portatil = Peer(
      DeviceIdentity.generate(),
      name: 'PORTATIL',
      relation: PeerRelation.foreign,
    );
  });

  Future<ReceiverStack> stack({
    bool remembered = true,
    void Function(TransferPlatform platform)? configure,
  }) => ReceiverStack.start(
    identity: receiver,
    peers: [laptop, portatil],
    remembered: remembered,
    configure: configure,
  );

  Set<String> outsideData(ReceiverStack s) => {
    for (final path in everythingUnder(s.base))
      if (!path.startsWith('data')) path,
  };

  Future<void> waitStage(ReceiverStack s, IncomingStage stage) =>
      eventually(() => s.incoming?.stage == stage, reason: 'stage $stage');

  Future<RawReply> foreignToWarning(ReceiverStack s, FolderJob job) async {
    final permit = await s.askManifest(portatil, job.declared);
    final reply = await s.sendManifest(portatil, job, permit);
    expectWaitingNoPicker(reply, status: 202);
    await waitStage(s, IncomingStage.warning);
    return reply;
  }

  Future<void> expectSenderBlocked(ReceiverStack s, Peer peer) async {
    final job = folderJob([('x', null)]);
    expectError(await s.offerFolder(peer, job.declared), 403, 'declined');
    s.clock.advance(const Duration(seconds: 59));
    expectError(await s.offerFolder(peer, job.declared), 403, 'declined');
    s.clock.advance(const Duration(seconds: 2));
    final reply = await s.offerFolder(peer, job.declared);
    expect(reply?.status, 202, reason: reply?.text);
    expect(reply?.state, 'manifest');
  }

  group('E450, RF-263: a folder is one session from offer to result', () {
    test('a "mine" folder: offers during the manifest and the upload get '
        '409, nothing is shown before the result and there is one '
        'result', () async {
      final s = await stack();
      s.sampleViews();
      final job = folderJob([
        ('src', null),
        (r'src\a.txt', smallFile),
        ('docs', null),
      ]);
      final permit = await s.askManifest(laptop, job.declared);
      expect(s.coordinator.busy, isTrue);
      expect(s.incoming, isNull);
      expectBusy(await s.offer(laptop));
      expectBusy(
        await s.offerFolder(portatil, folderJob([('x', null)]).declared),
      );
      expectBusy(
        await s.offerFolder(laptop, folderJob([('y', null)]).declared),
      );

      final reply = await s.sendManifest(laptop, job, permit);
      final uploadPermit = expectAccepted(reply);
      await waitStage(s, IncomingStage.waitingData);
      expectBusy(await s.offer(laptop));
      expect(s.incoming?.isFolder, isTrue);
      expect(s.incoming?.fileCount, 1);
      expect(s.incoming?.fileName, 'proyecto');

      final saved = await s.sendFolder(laptop, job, uploadPermit);
      expect(saved.status, 200, reason: saved.text);
      expect(saved.json, {
        'state': 'saved',
        'marked': true,
        'name': 'proyecto',
      });
      await eventually(
        () => s.coordinator.lastReceived != null && !s.coordinator.busy,
        reason: 'result',
      );
      expect(s.coordinator.lastReceived?.outcome, TransferOutcome.saved);
      expect(s.coordinator.lastReceived?.isFolder, isTrue);
      expect(
        s.seen.where((view) => view.stage == IncomingStage.warning),
        isEmpty,
      );
      expect(s.events, isEmpty);
      expect(
        File('${s.receiveDir}\\proyecto\\src\\a.txt').readAsStringSync(),
        'hello folder',
      );
    });

    test('a "foreign" folder: one warning for the whole folder, then one '
        'result, and offers in between get 409', () async {
      final s = await stack();
      s.sampleViews();
      final job = folderJob([(r'a.txt', smallFile)]);
      final permit = await s.askManifest(portatil, job.declared);
      expectBusy(await s.offer(portatil));
      expect(s.incoming, isNull);
      expectWaitingNoPicker(
        await s.sendManifest(portatil, job, permit),
        status: 202,
      );
      await waitStage(s, IncomingStage.warning);
      expectBusy(await s.offer(laptop));
      expectBusy(
        await s.offerFolder(portatil, folderJob([('x', null)]).declared),
      );
      expect(s.incoming?.isFolder, isTrue);
      expectWaitingNoPicker(await s.wait(portatil, job.transfer), status: 200);

      s.coordinator.answerWarning(s.sid, accept: true);
      await waitStage(s, IncomingStage.waitingData);
      final uploadPermit = expectAccepted(await s.wait(portatil, job.transfer));
      expectBusy(await s.offer(laptop));
      final saved = await s.sendFolder(portatil, job, uploadPermit);
      expect(saved.json, {
        'state': 'saved',
        'marked': true,
        'name': 'proyecto',
      });
      await eventually(
        () => s.coordinator.lastReceived != null && !s.coordinator.busy,
        reason: 'result',
      );
      expect(
        s.seen
            .where((view) => view.stage == IncomingStage.warning)
            .map((view) => view.sessionId)
            .toSet(),
        hasLength(1),
      );
      expect(s.coordinator.lastReceived?.outcome, TransferOutcome.saved);
    });
  });

  group('Q-4, RF-263: wait while the manifest is pending', () {
    test('a wait before and during the manifest answers waiting with no '
        'picker, never the permit', () async {
      final s = await stack();
      final job = folderJob([('a.txt', smallFile)]);
      final permit = await s.askManifest(laptop, job.declared);

      final before = await s.wait(laptop, job.transfer);
      expectWaitingNoPicker(before, status: 200);
      expect(before!.text, isNot(contains(permit)));

      final held = HeldBody();
      final pending = s.postManifest(
        laptop,
        transfer: job.transfer,
        permit: permit,
        bytes: job.encoded,
        body: held.stream,
      );
      held.send(job.encoded.sublist(0, 4));
      await eventually(
        () => s.handledOn(ApiPaths.transferManifest) == 1,
        reason: 'manifest route reached',
      );
      final during = await s.wait(laptop, job.transfer);
      expectWaitingNoPicker(during, status: 200);
      held.send(job.encoded.sublist(4));
      held.finish();
      expect(answered(await pending).status, 200);
    });
  });

  group('first time: the folder question comes after the manifest', () {
    test('a "mine" folder with no remembered folder: manifest, question, '
        'accepted, saved in Downloads\\NexusBridges', () async {
      final s = await stack(remembered: false);
      final job = folderJob([('a.txt', smallFile)]);
      final permit = await s.askManifest(laptop, job.declared);
      expect(s.incoming, isNull);
      expectWaitingNoPicker(
        await s.sendManifest(laptop, job, permit),
        status: 202,
      );
      await waitStage(s, IncomingStage.folderQuestion);
      expect(s.incoming?.isFolder, isTrue);
      expect(s.incoming?.folder?.kind, FolderQuestionKind.firstTime);

      await s.coordinator.useProposedFolder(s.sid);
      await waitStage(s, IncomingStage.waitingData);
      final uploadPermit = expectAccepted(await s.wait(laptop, job.transfer));
      final saved = await s.sendFolder(laptop, job, uploadPermit);

      expect(saved.json, {
        'state': 'saved',
        'marked': true,
        'name': 'proyecto',
      });
      expect(
        File('${s.downloadsDir}\\NexusBridges\\proyecto\\a.txt')
            .readAsStringSync(),
        'hello folder',
      );
    });

    test('a "foreign" folder with no remembered folder: first the warning '
        'and then the question', () async {
      final s = await stack(remembered: false);
      final job = folderJob([('a.txt', smallFile)]);
      await foreignToWarning(s, job);

      s.coordinator.answerWarning(s.sid, accept: true);
      await waitStage(s, IncomingStage.folderQuestion);
      await s.coordinator.useProposedFolder(s.sid);
      await waitStage(s, IncomingStage.waitingData);
      final uploadPermit = expectAccepted(await s.wait(portatil, job.transfer));
      final saved = await s.sendFolder(portatil, job, uploadPermit);
      expect(saved.json['state'], 'saved');
    });
  });

  group('E451, RF-264: paths that escape, with a modified client', () {
    final escapes = [
      '..',
      '.',
      r'a\..\..\x',
      r'C:\x',
      'C:x',
      r'\x',
      r'\\equipo\c$\x',
      r'\\?\C:\x',
      r'a\\b',
      r'a\',
      r'.\a',
      'a/b',
      '../x',
    ];

    final structural =
        <String, ({FolderOfferRequest declared, Uint8List bytes})>{
          'a parent equal to its own index': trapManifest(['[1,"abcdef"]']),
          'a parent greater than its own index': trapManifest(['[5,"abcdef"]']),
          'a negative parent': trapManifest(['[-1,"abcdef"]']),
          'a file as the parent': trapManifest([
            fileLine(0, 'a.txt', 1),
            folderLine(1, 'inside'),
          ]),
          'a line with a carriage return': trapManifest(
            const [],
            raw: Uint8List.fromList(
              utf8.encode('[0,"abcdef"]\r\n[0,"ghijkl"]\n'),
            ),
          ),
          'an empty line': trapManifest([
            folderLine(0, 'abcdef'),
            '',
            folderLine(0, 'ghijkl'),
          ]),
          'a line of 2049 bytes': trapManifest([
            '[0,"${'a' * 2042}"]',
            folderLine(0, 'abcdef'),
          ]),
          'malformed UTF-8': trapManifest(
            const [],
            raw: Uint8List.fromList([
              ...utf8.encode('[0,"ab'),
              0xFF,
              ...utf8.encode('cd"]\n[0,"ghijkl"]\n'),
            ]),
          ),
          'not a JSON list': trapManifest([
            '{"a":1,"b":2}',
            folderLine(0, 'abc'),
          ]),
        };

    Future<void> expectRejectedSilently(
      ReceiverStack s,
      ({FolderOfferRequest declared, Uint8List bytes}) trap,
      Set<int> statuses,
      Set<String> before,
    ) async {
      final permit = await s.askManifest(laptop, trap.declared);
      final reply = answered(
        await s.postManifest(
          laptop,
          transfer: trap.declared.transfer,
          permit: permit,
          bytes: trap.bytes,
        ),
      );
      expect(statuses, contains(reply.status), reason: reply.text);
      expect(s.incoming, isNull);
      await endedQuietly(s);
      expect(Directory('${s.receiveDir}\\$tempFolderName').existsSync(), false);
      expect(outsideData(s), before);
    }

    test('every escaping name, as folder and as file, is refused with 422 '
        'and nothing is shown or created', () async {
      final s = await stack();
      s.sampleViews();
      final before = outsideData(s);
      for (final name in escapes) {
        for (final line in [folderLine(0, name), fileLine(0, name, 1)]) {
          final trap = trapManifest([line, folderLine(0, 'abcdef')]);
          await expectRejectedSilently(s, trap, {422}, before);
        }
      }
      expectNothingShown(s);
    }, timeout: const Timeout(Duration(minutes: 2)));

    test('the same escaping names deep inside are refused too', () async {
      final s = await stack();
      s.sampleViews();
      final before = outsideData(s);
      for (final name in escapes) {
        final trap = trapManifest([
          folderLine(0, 'abcdef'),
          folderLine(1, 'ghijkl'),
          fileLine(2, name, 1),
        ]);
        await expectRejectedSilently(s, trap, {422}, before);
      }
      expectNothingShown(s);
    }, timeout: const Timeout(Duration(minutes: 2)));

    for (final MapEntry(key: label, value: trap) in structural.entries) {
      test('$label is refused with 400', () async {
        final s = await stack();
        s.sampleViews();
        final before = outsideData(s);
        await expectRejectedSilently(s, trap, {400}, before);
        expectNothingShown(s);
      });
    }
  });

  group('E452, RF-265: invalid names, with a modified client', () {
    final invalid = <String>[
      'CON',
      'aux.c',
      'COM1.txt',
      'COM\u00B9.txt',
      'a:b',
      'x.',
      'x ',
      'a\u202Eb',
      'a\u200Bb',
      'a\u0001b',
      'a\u0085b',
      'a' * 256,
      'a<b',
      'a|b',
    ];

    test('as the name of the folder in the offer: 422 invalid_name and '
        'nothing shown', () async {
      final s = await stack();
      s.sampleViews();
      final before = outsideData(s);
      for (final name in invalid) {
        final job = folderJob([('a.txt', smallFile)], name: 'valid');
        final declared = FolderOfferRequest(
          transfer: job.transfer,
          name: name,
          entries: job.declared.entries,
          files: job.declared.files,
          bytes: job.declared.bytes,
          depth: job.declared.depth,
          longest: job.declared.longest,
          manifestBytes: job.declared.manifestBytes,
        );
        expectError(await s.offerFolder(laptop, declared), 422, 'invalid_name');
      }
      expect(s.coordinator.busy, isFalse);
      expect(outsideData(s), before);
      expectNothingShown(s);
    });

    test('inside the manifest, at the first and the third level: 422 '
        'invalid_name and nothing shown', () async {
      final s = await stack();
      s.sampleViews();
      final before = outsideData(s);
      for (final name in invalid) {
        for (final lines in [
          [folderLine(0, name), folderLine(0, 'abcdef')],
          [
            folderLine(0, 'abcdef'),
            folderLine(1, 'ghijkl'),
            fileLine(2, name, 1),
          ],
        ]) {
          final trap = trapManifest(lines);
          final permit = await s.askManifest(laptop, trap.declared);
          final reply = answered(
            await s.postManifest(
              laptop,
              transfer: trap.declared.transfer,
              permit: permit,
              bytes: trap.bytes,
            ),
          );
          expect(reply.status, 422, reason: '$name ${reply.text}');
          expect(reply.json, {'error': 'invalid_name'});
          await endedQuietly(s);
        }
      }
      expect(outsideData(s), before);
      expectNothingShown(s);
    }, timeout: const Timeout(Duration(minutes: 2)));
  });

  group('E453, RF-266: clashes, with a modified client', () {
    final clashes = <String, List<String>>{
      'a.txt and A.TXT': [fileLine(0, 'a.txt', 1), fileLine(0, 'A.TXT', 1)],
      'a file and a folder in different case': [
        fileLine(0, 'src', 1),
        folderLine(0, 'SRC'),
      ],
      'a folder and a file in different case': [
        folderLine(0, 'src'),
        fileLine(0, 'Src', 1),
      ],
      'the same line twice': [folderLine(0, 'abcdef'), folderLine(0, 'abcdef')],
    };

    for (final MapEntry(key: label, value: lines) in clashes.entries) {
      test('$label: refused and nothing shown', () async {
        final s = await stack();
        s.sampleViews();
        final before = outsideData(s);
        final trap = trapManifest(lines);
        final permit = await s.askManifest(laptop, trap.declared);
        final reply = answered(
          await s.postManifest(
            laptop,
            transfer: trap.declared.transfer,
            permit: permit,
            bytes: trap.bytes,
          ),
        );
        expect(reply.status, 422, reason: reply.text);
        await endedQuietly(s);
        expect(outsideData(s), before);
        expectNothingShown(s);
      });
    }
  });

  group('E454, RF-267: blocked types, with a modified client', () {
    const guidFolder = 'x.{645FF040-5081-101B-9F08-00AA002F954E}';
    final blocked = <String, List<String>>{
      'desktop.ini inside a folder': [
        folderLine(0, 'sub'),
        fileLine(1, 'desktop.ini', 1),
      ],
      'x.LNK at the third level': [
        folderLine(0, 'p'),
        folderLine(1, 'q'),
        fileLine(2, 'x.LNK', 1),
      ],
      'a file with a class id segment': [
        fileLine(0, 'a.txt.{3050f4d8-98B5-11CF-BB82-00AA00BDCE0B}', 1),
      ],
      'a folder with a class id segment': [folderLine(0, guidFolder)],
      'a folder named desktop.ini': [folderLine(0, 'desktop.ini')],
      'a folder named algo.LNK': [
        folderLine(0, 'p'),
        folderLine(1, 'algo.LNK'),
      ],
    };

    for (final MapEntry(key: label, value: lines) in blocked.entries) {
      test('$label: 415 blocked_type and nothing shown', () async {
        final s = await stack();
        s.sampleViews();
        final before = outsideData(s);
        final trap = trapManifest([...lines, folderLine(0, 'abcdefgh')]);
        final permit = await s.askManifest(laptop, trap.declared);
        final reply = answered(
          await s.postManifest(
            laptop,
            transfer: trap.declared.transfer,
            permit: permit,
            bytes: trap.bytes,
          ),
        );
        expect(reply.status, 415, reason: reply.text);
        expect(reply.json, {'error': 'blocked_type'});
        await endedQuietly(s);
        expect(outsideData(s), before);
        expectNothingShown(s);
      });
    }

    test(
      'the name of the folder itself: 415 blocked_type at the offer',
      () async {
        final s = await stack();
        s.sampleViews();
        for (final name in ['desktop.ini', 'acceso.LNK', guidFolder, 'a.url']) {
          final job = folderJob([('a.txt', smallFile)]);
          final declared = FolderOfferRequest(
            transfer: job.transfer,
            name: name,
            entries: job.declared.entries,
            files: job.declared.files,
            bytes: job.declared.bytes,
            depth: job.declared.depth,
            longest: job.declared.longest,
            manifestBytes: job.declared.manifestBytes,
          );
          expectError(
            await s.offerFolder(laptop, declared),
            415,
            'blocked_type',
          );
        }
        expectNothingShown(s);
      },
    );

    test('a refused manifest of a "foreign" does not count as a recent '
        'rejection', () async {
      final s = await stack();
      final trap = trapManifest([folderLine(0, 'desktop.ini')]);
      final permit = await s.askManifest(portatil, trap.declared);
      final reply = answered(
        await s.postManifest(
          portatil,
          transfer: trap.declared.transfer,
          permit: permit,
          bytes: trap.bytes,
        ),
      );
      expect(reply.status, 415);
      await endedQuietly(s);
      final job = folderJob([('x', null)]);
      expect((await s.offerFolder(portatil, job.declared))?.status, 202);
    });
  });

  group('E455, RF-268: limits, with a modified client', () {
    FolderOfferRequest declared({
      int entries = 10,
      int depth = 1,
      int? manifestBytes,
    }) => FolderOfferRequest(
      transfer: newId(),
      name: 'proyecto',
      entries: entries,
      files: 0,
      bytes: 0,
      depth: depth,
      longest: 0,
      manifestBytes: manifestBytes ?? max(entries * 6, 64),
    );

    test('an offer above the limits gets 413 too_large without asking for '
        'a manifest', () async {
      final s = await stack();
      s.sampleViews();
      for (final request in [
        declared(entries: Limits.maxFolderEntries + 1, manifestBytes: 1 << 20),
        declared(depth: Limits.maxFolderDepth + 1),
        declared(manifestBytes: Limits.maxManifestBytes + 1),
      ]) {
        final reply = await s.offerFolder(laptop, request);
        expectError(reply, 413, 'too_large');
        expect(
          offerOutcome(reply!.status, reply.json),
          TransferOutcome.tooLargeForPeer,
        );
        expect(s.coordinator.busy, isFalse);
      }
      final foreign = await s.offerFolder(portatil, declared(depth: 65));
      expectError(foreign, 413, 'too_large');
      expect(s.handledOn(ApiPaths.transferManifest), 0);
      expectNothingShown(s);
    });

    test('the limits are exact: 100 000 entries, 64 levels and 16 MiB '
        'are asked for a manifest', () async {
      final s = await stack();
      for (final request in [
        declared(entries: Limits.maxFolderEntries, manifestBytes: 1 << 20),
        declared(depth: Limits.maxFolderDepth),
        declared(manifestBytes: Limits.maxManifestBytes),
      ]) {
        final reply = await s.offerFolder(laptop, request);
        expect(reply?.status, 202, reason: reply?.text);
        expect((await s.cancel(laptop, request.transfer))?.status, 200);
        await endedQuietly(s);
      }
    });

    test('more lines than declared: refused at the extra line without '
        'reading the rest', () async {
      final s = await stack();
      s.sampleViews();
      final lines = [for (var i = 0; i < 10; i++) folderLine(0, 'folder$i')];
      final bytes = Uint8List.fromList(
        utf8.encode(lines.map((line) => '$line\n').join()),
      );
      final request = FolderOfferRequest(
        transfer: newId(),
        name: 'proyecto',
        entries: 3,
        files: 0,
        bytes: 0,
        depth: 1,
        longest: 0,
        manifestBytes: bytes.length,
      );
      final permit = await s.askManifest(laptop, request);
      final held = HeldBody();
      final pending = s.postManifest(
        laptop,
        transfer: request.transfer,
        permit: permit,
        bytes: bytes,
        body: held.stream,
      );
      final firstFour = lines.take(4).map((line) => '$line\n').join();
      held.send(utf8.encode(firstFour));
      await endedQuietly(s);
      held.send(bytes.sublist(utf8.encode(firstFour).length));
      held.finish();
      final reply = answered(await pending);
      expect(reply.status, 400, reason: reply.text);
      expectNothingShown(s);
    });

    test('65 levels of folders in the manifest: 413 too_large and nothing '
        'shown', () async {
      final s = await stack();
      s.sampleViews();
      final chain = [for (var i = 0; i < 65; i++) folderLine(i, 'd$i')];
      final trap = trapManifest(chain);
      final request = FolderOfferRequest(
        transfer: trap.declared.transfer,
        name: 'proyecto',
        entries: trap.declared.entries,
        files: 0,
        bytes: 0,
        depth: 64,
        longest: 0,
        manifestBytes: trap.bytes.length,
      );
      final permit = await s.askManifest(laptop, request);
      final reply = answered(
        await s.postManifest(
          laptop,
          transfer: request.transfer,
          permit: permit,
          bytes: trap.bytes,
        ),
      );
      expectError(reply, 413, 'too_large');
      await endedQuietly(s);
      expectNothingShown(s);
    });

    test(
      'a manifest whose Content-Length is not the declared one: 400',
      () async {
        final s = await stack();
        final job = folderJob([('a.txt', smallFile)]);
        final permit = await s.askManifest(laptop, job.declared);
        final shorter = job.encoded.sublist(0, job.encoded.length - 1);
        final reply = answered(
          await s.postManifest(
            laptop,
            transfer: job.transfer,
            permit: permit,
            bytes: shorter,
          ),
        );
        expectError(reply, 400, 'incompatible');
        await endedQuietly(s);
      },
    );
  });

  group('E456, RF-269: space for the folder plus 1 GiB', () {
    final files = <TreeEntry>[
      ('a.bin', Uint8List(40)),
      ('b.bin', Uint8List(60)),
    ];

    test('a remembered folder with less space than the declared total plus '
        '1 GiB: 507 no_space on the offer', () async {
      final job = folderJob(files);
      final s = await stack(
        configure: (p) => p.freeBytesOverride =
            job.manifest.totalBytes + Limits.transferSpaceMargin - 1,
      );
      expectError(await s.offerFolder(laptop, job.declared), 507, 'no_space');
      expect(s.coordinator.busy, isFalse);
      expect(Directory('${s.receiveDir}\\$tempFolderName').existsSync(), false);
    });

    test('exactly total plus 1 GiB is enough', () async {
      final job = folderJob(files);
      final s = await stack(
        configure: (p) => p.freeBytesOverride =
            job.manifest.totalBytes + Limits.transferSpaceMargin,
      );
      await s.askManifest(laptop, job.declared);
    });

    test('a declared total smaller than the real one passes the offer and '
        'the manifest is refused as incompatible', () async {
      final job = folderJob(files);
      final s = await stack(
        configure: (p) => p.freeBytesOverride =
            job.manifest.totalBytes + Limits.transferSpaceMargin - 1,
      );
      s.sampleViews();
      final lying = withBytes(job.declared, job.manifest.totalBytes - 1);
      final permit = await s.askManifest(laptop, lying);
      final reply = await s.sendManifest(laptop, job, permit);
      expectError(reply, 400, 'incompatible');
      await endedQuietly(s);
      expectNothingShown(s);
    });

    test('unknown free space: accepted', () async {
      final job = folderJob(files);
      final s = await stack(configure: (p) => p.freeBytesUnknown = true);
      final permit = await s.askManifest(laptop, job.declared);
      expectAccepted(await s.sendManifest(laptop, job, permit));
    });
  });

  group('E457, RF-270: the longest path against the receive folder', () {
    int tempMax(ReceiverStack s) => 259 - s.receiveDir.length - 51;

    int finalMax(ReceiverStack s, String name) =>
        259 - s.receiveDir.length - 1 - name.length - 4 - 1;

    test(
      'a longest path that leaves the final path at 260 gets 422 '
      'path_too_long on the offer; at 259 it is asked for a manifest',
      () async {
        final s = await stack();
        s.sampleViews();
        final job = folderJob([('a.txt', smallFile)]);
        final limit = min(tempMax(s), finalMax(s, 'proyecto'));
        final reply = await s.offerFolder(
          laptop,
          withLongest(job.declared, limit + 1),
        );
        expectError(reply, 422, 'path_too_long');
        expect(
          offerOutcome(reply!.status, reply.json),
          TransferOutcome.pathTooLong,
        );
        expect(s.coordinator.busy, isFalse);
        expectNothingShown(s);
        expect(
          (await s.offerFolder(
            laptop,
            withLongest(job.declared, limit),
          ))?.status,
          202,
        );
      },
    );

    test(
      'the budget of the folder name: a long name moves the final bound',
      () async {
        final s = await stack();
        final name = 'n' * 60;
        final job = folderJob([('a.txt', smallFile)], name: name);
        final limit = min(tempMax(s), finalMax(s, name));
        expect(finalMax(s, name), lessThan(tempMax(s)));
        expectError(
          await s.offerFolder(laptop, withLongest(job.declared, limit + 1)),
          422,
          'path_too_long',
        );
        expect(
          (await s.offerFolder(
            laptop,
            withLongest(job.declared, limit),
          ))?.status,
          202,
        );
      },
    );

    test('a declared longest shorter than the real one is refused when the '
        'manifest ends', () async {
      final s = await stack();
      s.sampleViews();
      final job = folderJob([
        ('carpeta-larga', null),
        (r'carpeta-larga\archivo-largo.txt', smallFile),
      ]);
      final lying = withLongest(job.declared, job.declared.longest - 1);
      final permit = await s.askManifest(laptop, lying);
      final reply = await s.sendManifest(laptop, job, permit);
      expectError(reply, 400, 'incompatible');
      await endedQuietly(s);
      expectNothingShown(s);
    });
  });

  group('E458, RF-271: the warning of a "foreign" with the summary', () {
    FolderJob sevenAtFirstLevel() => folderJob([
      ('beta.txt', smallFile),
      ('Alpha', null),
      ('gamma', null),
      (r'gamma\inner.txt', smallFile),
      ('Delta.md', smallFile),
      ('epsilon', null),
      ('Zeta.txt', smallFile),
      ('eta.txt', smallFile),
    ]);

    test('seven names at the first level: the warning has the five first '
        'in alphabetical order with their type and two more', () async {
      final s = await stack();
      final job = sevenAtFirstLevel();
      final before = outsideData(s);
      await foreignToWarning(s, job);

      final view = s.incoming!;
      expect(view.stage, IncomingStage.warning);
      expect(view.peerName, 'PORTATIL');
      expect(view.peerFingerprint, portatil.fingerprint);
      expect(view.fileName, 'proyecto');
      expect(view.isFolder, isTrue);
      expect(view.fileCount, 5);
      expect(view.size, job.manifest.totalBytes);
      expect(view.firstLevel, const [
        FirstLevelItem(name: 'Alpha', isFolder: true),
        FirstLevelItem(name: 'beta.txt', isFolder: false),
        FirstLevelItem(name: 'Delta.md', isFolder: false),
        FirstLevelItem(name: 'epsilon', isFolder: true),
        FirstLevelItem(name: 'eta.txt', isFolder: false),
      ]);
      expect(view.moreFirstLevel, 2);
      expect(view.isProgram, isFalse);
      expect(outsideData(s), before);
      expect(Directory('${s.receiveDir}\\$tempFolderName').existsSync(), false);
    });

    test('rejecting writes nothing, tells the sender "declined" and blocks '
        'it for a minute', () async {
      final s = await stack();
      final job = sevenAtFirstLevel();
      final before = outsideData(s);
      await foreignToWarning(s, job);

      s.coordinator.answerWarning(s.sid, accept: false);
      await endedQuietly(s);

      expect(s.coordinator.lastReceived?.outcome, TransferOutcome.declined);
      expect(s.coordinator.lastReceived?.isFolder, isTrue);
      final answer = await s.wait(portatil, job.transfer);
      expect(answer?.json, {'state': 'rejected', 'reason': 'declined'});
      expect(outsideData(s), before);
      await expectSenderBlocked(s, portatil);
    });
  });

  group('E459, RF-305: a folder with programs', () {
    FolderJob job(List<TreeEntry> entries) => folderJob(entries);

    test('src\\index.js: the warning says it contains programs', () async {
      final s = await stack();
      await foreignToWarning(
        s,
        job([('src', null), (r'src\index.js', smallFile)]),
      );
      expect(s.incoming?.isProgram, isTrue);
      expect(s.platform.dangerousBatches, isEmpty);
    });

    test('only .txt files: it does not', () async {
      final s = await stack();
      await foreignToWarning(
        s,
        job([('a.txt', smallFile), ('b.TXT', smallFile), ('docs', null)]),
      );
      expect(s.incoming?.isProgram, isFalse);
      expect(s.platform.dangerousBatches, [
        {'.txt'},
      ]);
    });

    test('an extension Windows calls dangerous counts, asked once in one '
        'call and in lower case', () async {
      final s = await stack(
        configure: (p) => p.dangerousBatch = (extensions) async => {
          for (final extension in extensions)
            if (extension == '.weird') extension,
        },
      );
      await foreignToWarning(
        s,
        job([
          ('a.WEIRD', smallFile),
          ('b.weird', smallFile),
          ('c.txt', smallFile),
        ]),
      );
      expect(s.incoming?.isProgram, isTrue);
      expect(s.platform.dangerousBatches, [
        {'.weird', '.txt'},
      ]);
    });

    test('more than 4096 distinct extensions: taken as true without '
        'asking Windows', () async {
      final s = await stack();
      final many = [
        for (var i = 0; i <= Limits.maxDangerousExtensions; i++)
          ('f$i.e$i', Uint8List(0)),
      ];
      await foreignToWarning(s, job(many));
      expect(s.incoming?.isProgram, isTrue);
      expect(s.platform.dangerousBatches, isEmpty);
    }, timeout: const Timeout(Duration(minutes: 2)));

    test('exactly 4096 distinct extensions are asked in one call', () async {
      final s = await stack();
      final many = [
        for (var i = 0; i < Limits.maxDangerousExtensions; i++)
          ('f$i.e$i', Uint8List(0)),
      ];
      await foreignToWarning(s, job(many));
      expect(s.incoming?.isProgram, isFalse);
      expect(s.platform.dangerousBatches.single, hasLength(4096));
    }, timeout: const Timeout(Duration(minutes: 2)));

    test('the result of a "mine" folder with programs says so', () async {
      final s = await stack();
      final folder = job([(r'run.ps1', smallFile)]);
      final uploadPermit = await s.acceptedPermit(laptop, folder);
      await s.sendFolder(laptop, folder, uploadPermit);
      await eventually(
        () => s.coordinator.lastReceived != null,
        reason: 'result',
      );
      expect(s.coordinator.lastReceived?.isProgram, isTrue);
      expect(s.coordinator.lastReceived?.outcome, TransferOutcome.saved);
    });
  });

  group('E599, RF-305 point 20: the type check is bounded', () {
    test(
      'a Windows query that never answers: contains programs after 1 s',
      () async {
        final never = Completer<Set<String>>();
        final s = await stack(
          configure: (p) => p.dangerousBatch = (_) => never.future,
        );
        final job = folderJob([('a.txt', smallFile)]);
        final watch = Stopwatch()..start();
        await foreignToWarning(s, job);
        expect(s.incoming?.isProgram, isTrue);
        expect(
          watch.elapsed,
          greaterThanOrEqualTo(Limits.transferTypeCheckTimeout),
        );
        expect(watch.elapsed, lessThan(const Duration(seconds: 6)));
      },
    );

    test('a Windows query that throws: contains programs', () async {
      final s = await stack(
        configure: (p) =>
            p.dangerousBatch = (_) async => throw StateError('no answer'),
      );
      await foreignToWarning(s, folderJob([('a.txt', smallFile)]));
      expect(s.incoming?.isProgram, isTrue);
    });

    test(
      'a Windows query that answers nothing dangerous: it does not',
      () async {
        final s = await stack(
          configure: (p) => p.dangerousBatch = (_) async => <String>{},
        );
        await foreignToWarning(s, folderJob([('a.txt', smallFile)]));
        expect(s.incoming?.isProgram, isFalse);
      },
    );
  });

  group('E460, RF-272: the offer has no destination', () {
    test('a folder offer with a destination key is 400 incompatible, for '
        'a "mine" and for a "foreign"', () async {
      final s = await stack();
      s.sampleViews();
      final job = folderJob([('a.txt', smallFile)]);
      for (final peer in [laptop, portatil]) {
        final reply = await s.offerFolder(
          peer,
          job.declared,
          extra: {
            'destination': {'root': 'x'},
          },
        );
        expectError(reply, 400, 'incompatible');
        expect(s.coordinator.busy, isFalse);
      }
      expectNothingShown(s);
    });

    test(
      'a "mine" and a "foreign" folder both go to the receive folder',
      () async {
        final s = await stack();
        final mine = folderJob([('a.txt', smallFile)], name: 'mia');
        final minePermit = await s.acceptedPermit(laptop, mine);
        final saved = await s.sendFolder(laptop, mine, minePermit);
        expect(saved.json['name'], 'mia');
        await endedQuietly(s);

        final theirs = folderJob([('b.txt', smallFile)], name: 'ajena');
        await foreignToWarning(s, theirs);
        s.coordinator.answerWarning(s.sid, accept: true);
        await waitStage(s, IncomingStage.waitingData);
        final theirPermit = expectAccepted(
          await s.wait(portatil, theirs.transfer),
        );
        expect(
          (await s.sendFolder(portatil, theirs, theirPermit)).json['name'],
          'ajena',
        );
        await eventually(
          () => !Directory('${s.receiveDir}\\$tempFolderName').existsSync(),
          reason: 'temporary folder gone',
        );
        expect(
          Directory(s.receiveDir)
              .listSync(followLinks: false)
              .map((e) => e.path.substring(s.receiveDir.length + 1))
              .toSet(),
          {'mia', 'ajena'},
        );
      },
    );
  });

  group('E461, SEC-07: the manifest has its own deadlines', () {
    Future<(Future<StreamPostResult>, HeldBody, String)> startReading(
      ReceiverStack s,
      Peer peer,
      FolderJob job, {
      int firstBytes = 8,
    }) async {
      final permit = await s.askManifest(peer, job.declared);
      final held = HeldBody();
      final pending = s.postManifest(
        peer,
        transfer: job.transfer,
        permit: permit,
        bytes: job.encoded,
        body: held.stream,
      );
      held.send(job.encoded.sublist(0, firstBytes));
      await eventually(
        () => s.handledOn(ApiPaths.transferManifest) >= 1,
        reason: 'manifest route reached',
      );
      await settle();
      return (pending, held, permit);
    }

    void expectCut(StreamPostResult result) {
      expect(result, isA<StreamPostFailed>());
    }

    test('a manifest that does not start in 10 s: the session ends '
        'silently', () async {
      final s = await stack();
      s.sampleViews();
      final job = folderJob([('a.txt', smallFile)]);
      final permit = await s.askManifest(laptop, job.declared);
      s.clock.advance(const Duration(seconds: 9));
      await settle();
      expect(s.coordinator.busy, isTrue);
      s.clock.advance(const Duration(seconds: 1));
      await endedQuietly(s);
      expectNothingShown(s);
      final late = await s.postManifest(
        laptop,
        transfer: job.transfer,
        permit: permit,
        bytes: job.encoded,
      );
      expectForbidden(answered(late));
      expect((await s.offerFolder(laptop, job.declared))?.status, 202);
    });

    test('a manifest that stops for 5 s is cut (not 30 s)', () async {
      final s = await stack();
      s.sampleViews();
      final job = folderJob([('a.txt', smallFile)]);
      final (pending, _, _) = await startReading(s, laptop, job);
      s.clock.advance(const Duration(seconds: 4));
      await settle();
      expect(s.coordinator.busy, isTrue);
      s.clock.advance(const Duration(seconds: 1));
      await endedQuietly(s);
      expectCut(await pending);
      expectNothingShown(s);
    });

    test('a manifest above its cap is cut even if it keeps arriving', () async {
      final s = await stack();
      s.sampleViews();
      final job = flatFolders(400);
      final (pending, held, _) = await startReading(
        s,
        laptop,
        job,
        firstBytes: 100,
      );
      var sent = 100;
      for (var step = 0; step < 3; step++) {
        s.clock.advance(const Duration(seconds: 3));
        held.send(job.encoded.sublist(sent, sent + 100));
        sent += 100;
        await settle();
        expect(s.coordinator.busy, isTrue, reason: 'step $step');
      }
      s.clock.advance(const Duration(seconds: 3));
      held.send(job.encoded.sublist(sent, sent + 100));
      await endedQuietly(s);
      expectCut(await pending);
      expectNothingShown(s);
    });

    test('a manifest that keeps arriving for more than 10 s is not cut '
        'while it is under its cap', () async {
      final s = await stack();
      final job = flatFolders(75000);
      expect(job.encoded.length, greaterThan(1000000));
      final (pending, held, _) = await startReading(
        s,
        laptop,
        job,
        firstBytes: 64 * kib,
      );
      var sent = 64 * kib;
      final cap =
          Limits.manifestCapBase +
          Duration(
            seconds: job.encoded.length ~/ Limits.manifestMinBytesPerSecond,
          );
      expect(cap, greaterThan(const Duration(seconds: 13)));
      for (var step = 0; step < 4; step++) {
        s.clock.advance(const Duration(seconds: 3));
        held.send(job.encoded.sublist(sent, sent + 64 * kib));
        sent += 64 * kib;
        await settle();
        expect(s.coordinator.busy, isTrue, reason: 'step $step');
      }
      expect(s.clock.now, greaterThan(const Duration(hours: 3, seconds: 11)));
      held.send(job.encoded.sublist(sent));
      held.finish();
      expectAccepted(answered(await pending));
    }, timeout: const Timeout(Duration(minutes: 2)));

    test(
      'the cap of an unfinished manifest is 10 s plus 1 s per 256 KiB',
      () async {
        final s = await stack();
        final job = flatFolders(75000);
        final (pending, held, _) = await startReading(s, laptop, job);
        expect(job.encoded.length ~/ 262144, 4);
        var sent = 8;
        Future<void> beat(Duration span) async {
          s.clock.advance(span);
          held.send(job.encoded.sublist(sent, sent + 8));
          sent += 8;
          await settle();
        }

        for (var step = 0; step < 4; step++) {
          await beat(const Duration(seconds: 3));
          expect(s.coordinator.busy, isTrue, reason: '${(step + 1) * 3} s');
        }
        await beat(const Duration(seconds: 1));
        expect(s.coordinator.busy, isTrue, reason: '13 s');
        await beat(const Duration(seconds: 2));
        await endedQuietly(s);
        expectCut(await pending);
      },
    );

    test('a "foreign" whose manifest never starts counts as a recent '
        'rejection for a minute', () async {
      final s = await stack();
      final job = folderJob([('a.txt', smallFile)]);
      await s.askManifest(portatil, job.declared);
      s.clock.advance(const Duration(seconds: 10));
      await endedQuietly(s);
      await expectSenderBlocked(s, portatil);
    });

    test('a "foreign" whose manifest stalls counts as a recent '
        'rejection', () async {
      final s = await stack();
      final job = folderJob([('a.txt', smallFile)]);
      final (pending, _, _) = await startReading(s, portatil, job);
      s.clock.advance(const Duration(seconds: 5));
      await endedQuietly(s);
      expectCut(await pending);
      await expectSenderBlocked(s, portatil);
    });

    test('a "foreign" whose manifest passes its cap counts as a recent '
        'rejection', () async {
      final s = await stack();
      final job = flatFolders(400);
      final (pending, held, _) = await startReading(
        s,
        portatil,
        job,
        firstBytes: 100,
      );
      var sent = 100;
      for (var step = 0; step < 4; step++) {
        s.clock.advance(const Duration(seconds: 3));
        held.send(job.encoded.sublist(sent, sent + 100));
        sent += 100;
        await settle();
      }
      await endedQuietly(s);
      expectCut(await pending);
      await expectSenderBlocked(s, portatil);
    });

    test('a "foreign" that cuts the connection halfway counts as a recent '
        'rejection', () async {
      final s = await stack();
      final job = folderJob([('a.txt', smallFile)]);
      final (pending, held, _) = await startReading(s, portatil, job);
      held.breakOff();
      await endedQuietly(s);
      await pending.timeout(const Duration(seconds: 10));
      await expectSenderBlocked(s, portatil);
    });

    test('a "foreign" that cancels during the manifest counts as a recent '
        'rejection; the cancel shows nothing', () async {
      final s = await stack();
      s.sampleViews();
      final job = folderJob([('a.txt', smallFile)]);
      final (pending, _, _) = await startReading(s, portatil, job);
      final reply = await s.cancel(portatil, job.transfer);
      expect(reply?.status, 200);
      expect(reply?.json, {'state': 'cancelled'});
      await endedQuietly(s);
      expectCut(await pending);
      expectNothingShown(s);
      expect((await s.wait(portatil, job.transfer))?.json, {
        'state': 'cancelled',
      });
      await expectSenderBlocked(s, portatil);
    });

    test('the same failures of a "mine" never block it', () async {
      final s = await stack();
      final job = folderJob([('a.txt', smallFile)]);
      await s.askManifest(laptop, job.declared);
      s.clock.advance(const Duration(seconds: 10));
      await endedQuietly(s);
      final (pending, _, _) = await startReading(s, laptop, job);
      s.clock.advance(const Duration(seconds: 5));
      await endedQuietly(s);
      expectCut(await pending);
      final again = folderJob([('b.txt', smallFile)]);
      final (second, _, _) = await startReading(s, laptop, again);
      expect((await s.cancel(laptop, again.transfer))?.status, 200);
      await endedQuietly(s);
      expectCut(await second);
      expect((await s.offerFolder(laptop, job.declared))?.status, 202);
    });

    test('the manifest of a "foreign" that is complete and then declined '
        'is a normal rejection, not a second one', () async {
      final s = await stack();
      final job = folderJob([('a.txt', smallFile)]);
      await foreignToWarning(s, job);
      s.coordinator.answerWarning(s.sid, accept: false);
      await endedQuietly(s);
      await expectSenderBlocked(s, portatil);
    });

    test('the permit of the manifest: absent, wrong, from another session, '
        'already used or from another paired device is the same 403', () async {
      final s = await stack();
      s.sampleViews();
      final first = folderJob([('a.txt', smallFile)]);
      final stale = await s.askManifest(laptop, first.declared);
      expect((await s.cancel(laptop, first.transfer))?.status, 200);
      await endedQuietly(s);

      final job = folderJob([('b.txt', smallFile)]);
      final permit = await s.askManifest(laptop, job.declared);
      final replies = <RawReply>[
        answered(
          await s.postManifest(
            laptop,
            transfer: job.transfer,
            permit: null,
            bytes: job.encoded,
          ),
        ),
        answered(
          await s.postManifest(
            laptop,
            transfer: job.transfer,
            permit: '0123456789abcdef0123456789abcdef',
            bytes: job.encoded,
          ),
        ),
        answered(
          await s.postManifest(
            laptop,
            transfer: job.transfer,
            permit: stale,
            bytes: job.encoded,
          ),
        ),
        answered(
          await s.postManifest(
            laptop,
            transfer: newId(),
            permit: permit,
            bytes: job.encoded,
          ),
        ),
        answered(
          await s.postManifest(
            laptop,
            transfer: job.transfer,
            permit: permit,
            bytes: job.encoded,
            as: portatil.identity,
          ),
        ),
      ];
      for (final reply in replies) {
        expectForbidden(reply);
      }
      expect(replies.map((reply) => reply.text).toSet(), hasLength(1));
      expect(s.coordinator.busy, isTrue);

      expectAccepted(await s.sendManifest(laptop, job, permit));
      expectForbidden(
        answered(
          await s.postManifest(
            laptop,
            transfer: job.transfer,
            permit: permit,
            bytes: job.encoded,
          ),
        ),
      );
      expect(s.incoming?.stage, isNot(IncomingStage.warning));
    });

    test('a cancel from the sender during the manifest leaves a record and '
        'shows nothing', () async {
      final s = await stack();
      s.sampleViews();
      final job = folderJob([('a.txt', smallFile)]);
      final (pending, _, _) = await startReading(s, laptop, job);
      final reply = await s.cancel(laptop, job.transfer);
      expect(reply?.json, {'state': 'cancelled'});
      await endedQuietly(s);
      expectCut(await pending);
      expectNothingShown(s);
      expect((await s.wait(laptop, job.transfer))?.json, {
        'state': 'cancelled',
      });
      expect(s.logs.where((line) => line.contains('failed')), isEmpty);
    });
  });
}
