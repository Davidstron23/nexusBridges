@TestOn('windows')
library;

import 'dart:convert';
import 'dart:io';

import 'package:nexus_bridges_core/src/browse/browse.dart';
import 'package:nexus_bridges_core/src/identity/identity.dart';
import 'package:nexus_bridges_core/src/node/node.dart';
import 'package:nexus_bridges_core/src/pairing/pairing.dart' show PeerRelation;
import 'package:nexus_bridges_core/src/protocol/protocol.dart';
import 'package:nexus_bridges_core/src/storage/storage.dart';
import 'package:nexus_bridges_core/src/transport/transport.dart';
import 'package:test/test.dart';

import 'transfer_nodes_harness.dart';

Matcher refusedWith(ShareRefusal reason) =>
    isA<ShareRefused>().having((r) => r.reason, 'reason', reason);

Matcher addedSaved(bool saved) =>
    isA<ShareAdded>().having((a) => a.saved, 'saved', saved);

File sharesFileOf(TransferNode node) => File('${node.dataPath}\\shares.json');

void breakShares(TransferNode node) {
  final file = sharesFileOf(node);
  if (file.existsSync()) file.deleteSync();
  Directory(file.path).createSync();
}

void mendShares(TransferNode node) {
  final dir = Directory(sharesFileOf(node).path);
  if (dir.existsSync()) dir.deleteSync(recursive: true);
}

List<String> setApart(TransferNode node) => [
  for (final entity in Directory(node.dataPath).listSync())
    if (entity.path.split(r'\').last.startsWith('shares.json.'))
      entity.path.split(r'\').last,
];

Future<ShareRecord> docsRecord(TransferNode node, {int id = 1}) async {
  final docs = '${node.base}\\docs';
  Directory(docs).createSync(recursive: true);
  final facts = await realFs.volumeFacts(docs);
  return ShareRecord(
    id: id.toRadixString(16).padLeft(32, '0'),
    path: docs,
    volumeId: facts!.volumeId,
    label: 'docs',
    home: false,
    drive: DriveKind.fixed,
    addedAt: DateTime.utc(2026, 11, 1),
  );
}

Future<void> writeShares(
  TransferNode node,
  DeviceIdentity owner,
  Map<String, List<ShareRecord>> shares,
) async {
  expect(
    await SharesStore(
      JsonFileStore(sharesFileOf(node)),
      ownerFingerprint: owner.fingerprint,
    ).write(shares),
    isTrue,
  );
}

Future<HttpsResponse?> rawPost(
  TransferNode from,
  TransferNode to,
  String path,
  Object? json,
) async {
  final caller = await from.loadIdentity();
  return postJson(
    address: to.address,
    port: to.port,
    path: path,
    json: json,
    context: caller.clientContext(presentCertificate: true),
    acceptServer: (certificate) {
      try {
        return fingerprintOfCertificate(certificate.der) == to.fingerprint;
      } on FormatException {
        return false;
      }
    },
    sourceAddress: from.address,
  );
}

Object? bodyOf(HttpsResponse response) {
  try {
    return jsonDecode(utf8.decode(response.body));
  } on FormatException {
    return null;
  }
}

void main() {
  group('E715 adding and removing a folder from the node (RF-400)', () {
    test('E715 addShare opens the folder picker, peers shows the full path '
        'and removeShare takes it away', () async {
      final (a, b) = await transferNodes();
      final docs = '${b.base}\\docs';
      Directory(docs).createSync();
      final peer = b.state.peers[a.fingerprint]!;
      expect(peer.fingerprint, a.fingerprint);
      expect(peer.realName, a.name);
      expect(peer.mine, isTrue);
      expect(peer.visible, isTrue);
      expect(peer.shares, isEmpty);
      expect(peer.sharesUnsaved, isFalse);
      expect(b.state.peers.keys, [a.fingerprint]);

      b.picker.nextFolder = docs;
      final calls = b.picker.folderCalls;
      expect(await b.node.addShare(a.fingerprint), addedSaved(true));
      expect(b.picker.folderCalls, calls + 1);
      final state = await b.until(
        (s) => s.peers[a.fingerprint]?.shares.length == 1,
      );
      final view = state.peers[a.fingerprint]!.shares.single;
      expect(view.path, docs);
      expect(view.label, 'docs');
      expect(view.home, isFalse);
      expect(view.drive, DriveKind.fixed);
      expect(view.available, isNull);

      await b.node.refreshShares(a.fingerprint);
      expect(b.state.peers[a.fingerprint]!.shares.single.available, isTrue);

      b.picker.nextFolder = null;
      expect(await b.node.addShare(a.fingerprint), isA<SharePickCancelled>());

      await b.node.removeShare(a.fingerprint, view.rootId);
      await b.until((s) => s.peers[a.fingerprint]!.shares.isEmpty);
      expect(b.noticesOf(NoticeKind.sharesNotSaved), isEmpty);
      final roots = await a.node.listRemoteRoots(b.fingerprint);
      expect((roots as RemoteRoots).roots, isEmpty);
      expect(b.logs.join('\n'), isNot(contains(docs)));
    }, timeout: transferTimeout);
  });

  group('E711 confirmation from the node only for a "mine" peer (RF-403)', () {
    test('E711 a folder without the mark asks, confirmShare adds it, and '
        'cancelPendingShare drops another one', () async {
      final (a, b) = await transferNodes();
      b.platform.noMarkSupport = true;
      final first = '${b.base}\\fat1';
      final second = '${b.base}\\fat2';
      Directory(first).createSync();
      Directory(second).createSync();
      b.picker.nextFolder = first;
      final asked = await b.node.addShare(a.fingerprint);
      expect(asked, isA<ShareNeedsConfirmation>());
      final pending = asked as ShareNeedsConfirmation;
      expect(pending.withoutMark, isTrue);
      expect(b.state.peers[a.fingerprint]!.shares, isEmpty);
      expect(
        await b.node.confirmShare(a.fingerprint, pending.pendingId),
        addedSaved(true),
      );
      expect(b.state.peers[a.fingerprint]!.shares.single.path, first);

      b.picker.nextFolder = second;
      final other =
          await b.node.addShare(a.fingerprint) as ShareNeedsConfirmation;
      b.node.cancelPendingShare(other.pendingId);
      expect(
        await b.node.confirmShare(a.fingerprint, other.pendingId),
        refusedWith(ShareRefusal.missing),
      );
      expect(b.state.peers[a.fingerprint]!.shares, hasLength(1));
    }, timeout: transferTimeout);

    test('E711 a peer marked foreign cannot add nor confirm, its pending is '
        'refused and its roots stay paused', () async {
      final (a, b) = await transferNodes();
      b.platform.noMarkSupport = true;
      final kept = '${b.base}\\kept';
      final asked = '${b.base}\\asked';
      Directory(kept).createSync();
      Directory(asked).createSync();
      b.platform.noMarkSupport = false;
      b.picker.nextFolder = kept;
      expect(await b.node.addShare(a.fingerprint), addedSaved(true));
      b.platform.noMarkSupport = true;
      b.picker.nextFolder = asked;
      final pending =
          await b.node.addShare(a.fingerprint) as ShareNeedsConfirmation;

      await b.node.setMine(a.fingerprint, mine: false);
      await b.until((s) => s.peers[a.fingerprint]?.mine == false);
      expect(
        await b.node.confirmShare(a.fingerprint, pending.pendingId),
        refusedWith(ShareRefusal.missing),
      );
      final calls = b.picker.folderCalls;
      expect(
        await b.node.addShare(a.fingerprint),
        refusedWith(ShareRefusal.missing),
      );
      expect(b.picker.folderCalls, calls);
      final paused = b.state.peers[a.fingerprint]!;
      expect(paused.shares.single.path, kept);
      final roots = await a.node.listRemoteRoots(b.fingerprint);
      expect((roots as RemoteListingFailed).reason, BrowseFailure.notAllowed);

      await b.node.setMine(a.fingerprint, mine: true);
      await b.until((s) => s.peers[a.fingerprint]?.mine == true);
      final back = await a.node.listRemoteRoots(b.fingerprint);
      expect((back as RemoteRoots).roots, hasLength(1));
      expect(b.state.peers[a.fingerprint]!.shares, hasLength(1));
    }, timeout: transferTimeout);

    test('E711 confirmShare for a fingerprint that is not paired is '
        'missing', () async {
      final (a, b) = await transferNodes();
      expect(
        await b.node.confirmShare('F' * 64, 'f' * 32),
        refusedWith(ShareRefusal.missing),
      );
      expect(
        await b.node.addShare('F' * 64),
        refusedWith(ShareRefusal.missing),
      );
      expect(b.state.peers.containsKey('F' * 64), isFalse);
      expect(b.state.peers.keys, [a.fingerprint]);
    }, timeout: transferTimeout);
  });

  group('E714 saving fails (RF-406)', () {
    test('E714 removing with the store failing removes in memory, warns with '
        'retry and retrySave fixes it; adding warns that it will not be '
        'remembered', () async {
      final (a, b) = await transferNodes();
      final docs = '${b.base}\\docs';
      Directory(docs).createSync();
      b.picker.nextFolder = docs;
      expect(await b.node.addShare(a.fingerprint), addedSaved(true));
      final rootId = b.state.peers[a.fingerprint]!.shares.single.rootId;

      breakShares(b);
      await b.node.removeShare(a.fingerprint, rootId);
      final warned = await b.until(
        (s) => s.notices.any((n) => n.kind == NoticeKind.sharesNotSaved),
      );
      final notice = warned.notices.singleWhere(
        (n) => n.kind == NoticeKind.sharesNotSaved,
      );
      expect(notice.canRetry, isTrue);
      expect(warned.peers[a.fingerprint]!.shares, isEmpty);
      expect(warned.peers[a.fingerprint]!.sharesUnsaved, isTrue);
      final listed = await a.node.listRemoteFolders(
        b.fingerprint,
        rootId,
        const [],
      );
      expect((listed as RemoteListingFailed).reason, BrowseFailure.notAllowed);

      await b.node.retrySave();
      expect(b.noticesOf(NoticeKind.sharesNotSaved), hasLength(1));

      mendShares(b);
      await b.node.retrySave();
      await b.until(
        (s) =>
            s.notices.every((n) => n.kind != NoticeKind.sharesNotSaved) &&
            s.peers[a.fingerprint]?.sharesUnsaved == false,
      );

      breakShares(b);
      final other = '${b.base}\\otra';
      Directory(other).createSync();
      b.picker.nextFolder = other;
      expect(await b.node.addShare(a.fingerprint), addedSaved(false));
      final added = await b.until(
        (s) => s.notices.any((n) => n.kind == NoticeKind.shareAddNotSaved),
      );
      expect(
        added.notices
            .singleWhere((n) => n.kind == NoticeKind.shareAddNotSaved)
            .canRetry,
        isFalse,
      );
      expect(added.peers[a.fingerprint]!.shares.single.path, other);
      expect(added.peers[a.fingerprint]!.sharesUnsaved, isFalse);
      mendShares(b);
    }, timeout: transferTimeout);
  });

  group('E713 a bad shares.json starts closed (RF-407) [SEG]', () {
    test('E713 broken JSON: no roots, the file is set apart and sharesReset '
        'is shown', () async {
      final (a, b) = await transferNodes(
        before: (a, b) async {
          sharesFileOf(b).writeAsStringSync('{"version":1,"owner":');
        },
      );
      expect(b.noticesOf(NoticeKind.sharesReset), hasLength(1));
      expect(b.noticesOf(NoticeKind.sharesPartlyReset), isEmpty);
      expect(b.state.peers[a.fingerprint]!.shares, isEmpty);
      expect(setApart(b), isNotEmpty);
      final roots = await a.node.listRemoteRoots(b.fingerprint);
      expect((roots as RemoteRoots).roots, isEmpty);
    }, timeout: transferTimeout);

    test('E713 a relative path quarantines the whole file', () async {
      final (a, b) = await transferNodes(
        before: (a, b) async {
          final idA = await a.loadIdentity();
          final idB = await b.loadIdentity();
          final record = await docsRecord(b);
          await writeShares(b, idB, {
            idA.fingerprint: [record],
          });
          final json = jsonDecode(
            sharesFileOf(b).readAsStringSync(),
          ) as Map<String, Object?>;
          final peers = json['peers']! as List;
          final roots = (peers.single as Map)['roots']! as List;
          (roots.single as Map)['path'] = r'docs\sub';
          sharesFileOf(b).writeAsStringSync(jsonEncode(json));
        },
      );
      expect(b.noticesOf(NoticeKind.sharesReset), hasLength(1));
      expect(b.state.peers[a.fingerprint]!.shares, isEmpty);
      final roots = await a.node.listRemoteRoots(b.fingerprint);
      expect((roots as RemoteRoots).roots, isEmpty);
    }, timeout: transferTimeout);

    test('E713 roots of a fingerprint that is not paired are dropped, the '
        'others stay and sharesPartlyReset is shown', () async {
      final (a, b) = await transferNodes(
        before: (a, b) async {
          final idA = await a.loadIdentity();
          final idB = await b.loadIdentity();
          final gone = DeviceIdentity.generate();
          await writeShares(b, idB, {
            idA.fingerprint: [await docsRecord(b)],
            gone.fingerprint: [await docsRecord(b, id: 2)],
          });
        },
      );
      expect(b.noticesOf(NoticeKind.sharesPartlyReset), hasLength(1));
      expect(b.noticesOf(NoticeKind.sharesReset), isEmpty);
      expect(b.state.peers[a.fingerprint]!.shares, hasLength(1));
      expect(setApart(b), isNotEmpty);
      final roots = await a.node.listRemoteRoots(b.fingerprint);
      expect((roots as RemoteRoots).roots.single.name, 'docs');
      final saved = jsonDecode(
        sharesFileOf(b).readAsStringSync(),
      ) as Map<String, Object?>;
      expect((saved['peers']! as List), hasLength(1));
    }, timeout: transferTimeout);

    test('E713 a file of another identity starts empty without a shares '
        'notice', () async {
      final (a, b) = await transferNodes(
        before: (a, b) async {
          final idA = await a.loadIdentity();
          await writeShares(b, DeviceIdentity.generate(), {
            idA.fingerprint: [await docsRecord(b)],
          });
        },
      );
      expect(b.noticesOf(NoticeKind.sharesReset), isEmpty);
      expect(b.noticesOf(NoticeKind.sharesPartlyReset), isEmpty);
      expect(b.state.peers[a.fingerprint]!.shares, isEmpty);
      expect(setApart(b), isNotEmpty);
    }, timeout: transferTimeout);

    test('E713 the roots survive a restart when the file is good', () async {
      final (a, b) = await transferNodes();
      final docs = '${b.base}\\docs';
      Directory(docs).createSync();
      b.picker.nextFolder = docs;
      expect(await b.node.addShare(a.fingerprint), addedSaved(true));
      final before = b.state.peers[a.fingerprint]!.shares.single;
      await b.restart();
      await meet(a, b);
      final after = b.state.peers[a.fingerprint]!.shares.single;
      expect(after.rootId, before.rootId);
      expect(after.path, docs);
      expect(b.noticesOf(NoticeKind.sharesReset), isEmpty);
    }, timeout: transferTimeout);
  });

  group('E712 no route creates or changes roots (RF-401) [SEG]', () {
    test('E712 the node answers browse, every other share path is not found '
        'and posting garbage to every route leaves the roots as they '
        'were', () async {
      final (a, b) = await transferNodes();
      final docs = '${b.base}\\docs';
      Directory(docs).createSync();
      b.picker.nextFolder = docs;
      expect(await b.node.addShare(a.fingerprint), addedSaved(true));
      final views = b.state.peers[a.fingerprint]!.shares;
      final file = sharesFileOf(b).readAsBytesSync();

      final browse = await rawPost(a, b, ApiPaths.browse, {
        'protocol': protocolVersion,
      });
      expect(browse?.status, 200);

      for (final invented in [
        '${ApiPaths.browse}/add',
        '${ApiPaths.browse}/remove',
        '${ApiPaths.browse}/roots',
        '/api/nexusbridges/v1/shares',
        '/api/nexusbridges/v1/shares/add',
        '/api/nexusbridges/v1/share',
        '/api/nexusbridges/v1/roots',
      ]) {
        final reply = await rawPost(a, b, invented, {
          'protocol': protocolVersion,
          'path': docs,
        });
        expect(reply?.status, 404, reason: invented);
        expect(bodyOf(reply!), {'error': 'not_found'}, reason: invented);
      }

      for (final path in [
        ApiPaths.browse,
        ApiPaths.transferOffer,
        ApiPaths.transferWait,
        ApiPaths.transferCancel,
        ApiPaths.transferManifest,
        ApiPaths.pairStatus,
      ]) {
        for (final body in [
          {'protocol': protocolVersion, 'absolutePath': r'C:\Windows'},
          {'protocol': protocolVersion, 'add': docs, 'root': 'f' * 32},
          {
            'protocol': protocolVersion,
            'remove': views.single.rootId,
            'root': views.single.rootId,
            'path': <Object?>[],
          },
        ]) {
          await rawPost(a, b, path, body);
        }
      }
      expect(b.state.peers[a.fingerprint]!.shares, views);
      expect(sharesFileOf(b).readAsBytesSync(), file);
    }, timeout: transferTimeout);
  });

  group('NodeState.peers (T3)', () {
    test('peers only lists paired devices with mine, visible and the real '
        'name', () async {
      final (a, b) = await transferNodes(aAtB: PeerRelation.foreign);
      final peer = b.state.peers[a.fingerprint]!;
      expect(peer.mine, isFalse);
      expect(peer.visible, isTrue);
      expect(peer.realName, a.name);
      expect(peer.shares, isEmpty);
      await a.stop();
      b.elapsed += const Duration(seconds: 31);
      await b.until((s) => s.peers[a.fingerprint]?.visible == false);
      await b.node.unpair(a.fingerprint);
      await b.until((s) => !s.peers.containsKey(a.fingerprint));
      expect(b.state.peers, isEmpty);
    }, timeout: transferTimeout);
  });
}
