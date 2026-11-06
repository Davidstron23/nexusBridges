@TestOn('windows')
library;

import 'dart:convert';
import 'dart:io';

import 'package:nexus_bridges_core/src/node/node.dart';
import 'package:nexus_bridges_core/src/pairing/pairing.dart' show PeerRelation;
import 'package:nexus_bridges_core/src/protocol/protocol.dart';
import 'package:test/test.dart';

import '../peers/peer_notes_support.dart' show validDestination, validHistory;
import '../support/infra.dart';
import 'guard_nodes_support.dart';
import 'peer_notes_nodes_support.dart';
import 'transfer_nodes_harness.dart';

const String secretAlias = 'ApodoSecreto763';

Future<void> pause(Duration span) => Future<void>.delayed(span);

SavedDestination saved(
  Guarded g,
  List<String> path, {
  String rootName = 'docs',
}) => SavedDestination(rootId: g.rootId, rootName: rootName, path: path);

Map<String, Object?> peerRow(
  String fingerprint, {
  String? alias = 'Casa',
  List<Object?>? history,
}) => {
  'fingerprint': fingerprint,
  'alias': alias,
  'favorites': [validDestination()],
  'recent': <Object?>[],
  'history': history ?? [validHistory()],
};

void writePeersFile(TransferNode node, String owner, List<Object?> peers) =>
    peersFileOf(node).writeAsStringSync(
      jsonEncode({'version': 1, 'owner': owner, 'peers': peers}),
    );

void main() {
  group('E761 the recent destinations (RF-426)', () {
    test('a saved send to docs\\sub goes first, one that fails does not, and '
        'it survives a restart', () async {
      final g = await guardedNodes();

      final first = await g.sendFile('uno.txt', [1, 2, 3], g.to(const ['sub']));
      expect(first.outcome, TransferOutcome.saved);
      await untilView(g.a, g.b, (v) => v.recent.isNotEmpty);
      expect(viewOf(g.a, g.b)!.recent, [
        saved(g, const ['sub']),
      ]);

      final bad = await g.sendFile('dos.txt', [4], g.to(const ['no-existe']));
      expect(bad.outcome, TransferOutcome.destinationMissing);
      await historyOf(g.a, g.b, 2);
      expect(viewOf(g.a, g.b)!.recent, [
        saved(g, const ['sub']),
      ]);

      await g.sendFile('tres.txt', [5], g.to(const ['sub', 'deep']));
      await untilView(g.a, g.b, (v) => v.recent.length == 2);
      expect(viewOf(g.a, g.b)!.recent, [
        saved(g, const ['sub', 'deep']),
        saved(g, const ['sub']),
      ]);

      await g.a.restart();

      expect(viewOf(g.a, g.b)!.recent, [
        saved(g, const ['sub', 'deep']),
        saved(g, const ['sub']),
      ]);
    }, timeout: transferTimeout);

    test('a repeated destination does not repeat, even in another case, and '
        'moves to the front', () async {
      final g = await guardedNodes();

      await g.sendFile('a.txt', [1], g.to(const ['sub']));
      await untilView(g.a, g.b, (v) => v.recent.length == 1);
      await g.sendFile('b.txt', [1], g.to(const ['otra']));
      await untilView(g.a, g.b, (v) => v.recent.length == 2);
      await g.sendFile('c.txt', [1], g.to(const ['SUB']));
      await historyOf(g.a, g.b, 3);
      await untilView(
        g.a,
        g.b,
        (v) => v.recent.first.path.single.toLowerCase() == 'sub',
      );

      final recent = viewOf(g.a, g.b)!.recent;
      expect(recent, hasLength(2));
      expect(recent.last, saved(g, const ['otra']));
    }, timeout: transferTimeout);

    test('a send to the default folder is not a recent destination', () async {
      final (a, b) = await transferNodes();

      await a.send(b, await a.sourceFile('uno.txt', [1, 2]));
      await a.sentResult();
      await historyOf(a, b, 1);

      expect(viewOf(a, b)!.recent, isEmpty);
    }, timeout: transferTimeout);

    test('a send that creates a new folder remembers the folder that now '
        'exists', () async {
      final g = await guardedNodes();

      final result = await g.sendFile('a.txt', [
        1,
      ], g.to(const ['sub'], newFolder: 'nueva'));
      expect(result.outcome, TransferOutcome.saved);
      await untilView(g.a, g.b, (v) => v.recent.isNotEmpty);

      expect(viewOf(g.a, g.b)!.recent, [
        saved(g, const ['sub', 'nueva']),
      ]);
    }, timeout: transferTimeout);

    test('a personal folder keeps its home mark through a restart', () async {
      final (a, b) = await transferNodes(
        before: (a, b) async {
          final idA = await a.loadIdentity();
          final idB = await b.loadIdentity();
          writePeersFile(a, idA.fingerprint, [
            {
              'fingerprint': idB.fingerprint,
              'alias': null,
              'favorites': <Object?>[],
              'recent': [validDestination(rootName: '', home: true)],
              'history': [
                validHistory()
                  ..['destRoot'] = ''
                  ..['destHome'] = true,
              ],
            },
          ]);
        },
      );

      await a.restart();

      expect(peersFilesAside(a), isEmpty);
      expect(viewOf(a, b)!.recent.single.home, isTrue);
      expect(viewOf(a, b)!.history.single.destination?.home, isTrue);
      expect(viewOf(a, b)!.history.single.destination?.rootName, '');
    }, timeout: transferTimeout);
  });

  group('E762 the favorites (RF-428)', () {
    test('saved by fingerprint and in order, the ninth is full, one can be '
        'removed and they survive a restart', () async {
      final g = await guardedNodes();
      final names = ['z', 'a', 'm', 'b', 'y', 'c', 'x', 'd'];

      for (final name in names) {
        expect(
          g.a.node.addFavorite(g.b.fingerprint, saved(g, [name])),
          FavoriteResult.added,
        );
      }
      expect(
        g.a.node.addFavorite(g.b.fingerprint, saved(g, const ['novena'])),
        FavoriteResult.full,
      );
      expect(
        g.a.node.addFavorite(g.b.fingerprint, saved(g, const ['Z'])),
        FavoriteResult.alreadyThere,
      );
      await untilView(g.a, g.b, (v) => v.favorites.length == 8);
      expect(viewOf(g.a, g.b)!.favorites.map((f) => f.path.single), names);

      g.a.node.removeFavorite(g.b.fingerprint, 1);
      await untilView(g.a, g.b, (v) => v.favorites.length == 7);
      final left = ['z', ...names.skip(2)];
      expect(viewOf(g.a, g.b)!.favorites.map((f) => f.path.single), left);

      await g.a.restart();

      expect(viewOf(g.a, g.b)!.favorites.map((f) => f.path.single), left);
      expect(viewOf(g.b, g.a)!.favorites, isEmpty);
    }, timeout: transferTimeout);

    test('favorites are kept apart per peer', () async {
      final (a, b, c) = await transferTrio(cAtB: PeerRelation.mine);
      final root = '1' * 32;

      a.node.addFavorite(
        b.fingerprint,
        SavedDestination(rootId: root, rootName: 'de-b', path: const ['p']),
      );
      a.node.addFavorite(
        c.fingerprint,
        SavedDestination(rootId: root, rootName: 'de-c', path: const ['p']),
      );
      await untilView(a, c, (v) => v.favorites.isNotEmpty);

      expect(viewOf(a, b)!.favorites.single.rootName, 'de-b');
      expect(viewOf(a, c)!.favorites.single.rootName, 'de-c');
    }, timeout: transferTimeout);

    test('a destination that could not be stored gives full, the only other '
        'value of the enum, and nothing is kept', () async {
      final g = await guardedNodes();
      final fp = g.b.fingerprint;
      final refused = <SavedDestination>[
        SavedDestination(rootId: 'xyz', rootName: 'docs', path: const []),
        SavedDestination(rootId: 'A' * 32, rootName: 'docs', path: const []),
        SavedDestination(rootId: g.rootId, rootName: '', path: const []),
        SavedDestination(
          rootId: g.rootId,
          rootName: 'a\u{0007}',
          path: const [],
        ),
        SavedDestination(rootId: g.rootId, rootName: 'x' * 256, path: const []),
        saved(g, const ['..']),
        saved(g, const ['.']),
        saved(g, const ['']),
        saved(g, const ['a:b']),
        saved(g, const [r'a\b']),
        saved(g, const ['a/b']),
        saved(g, const ['CON']),
        saved(g, const ['fin.']),
        saved(g, const ['fin ']),
        saved(g, List.filled(Limits.maxRelativeDepth + 1, 'p')),
      ];

      for (final destination in refused) {
        expect(
          g.a.node.addFavorite(fp, destination),
          FavoriteResult.full,
          reason: '${destination.rootName}|${destination.path}',
        );
      }
      await pause(const Duration(milliseconds: 300));

      expect(viewOf(g.a, g.b)!.favorites, isEmpty);
    }, timeout: transferTimeout);

    test(
      'a home destination with an empty root name can be a favorite',
      () async {
        final g = await guardedNodes();

        expect(
          g.a.node.addFavorite(
            g.b.fingerprint,
            SavedDestination(
              rootId: g.rootId,
              rootName: '',
              home: true,
              path: const [],
            ),
          ),
          FavoriteResult.added,
        );
      },
      timeout: transferTimeout,
    );

    test('a fingerprint that is not paired stores nothing', () async {
      final (a, b) = await transferNodes();
      final stranger = 'F' * 64;
      final destination = SavedDestination(
        rootId: '1' * 32,
        rootName: 'docs',
        path: const [],
      );

      expect(a.node.addFavorite(stranger, destination), FavoriteResult.full);
      a.node.setAlias(stranger, 'Nadie');
      a.node.removeFavorite(stranger, 0);
      await pause(const Duration(milliseconds: 800));

      expect(peersText(a), isNot(contains(stranger)));
      expect(a.state.peers.keys, {b.fingerprint});
    }, timeout: transferTimeout);

    test('removing out of range does nothing', () async {
      final g = await guardedNodes();
      g.a.node.addFavorite(g.b.fingerprint, saved(g, const ['sub']));

      g.a.node.removeFavorite(g.b.fingerprint, 5);
      g.a.node.removeFavorite(g.b.fingerprint, -1);
      await pause(const Duration(milliseconds: 300));

      expect(viewOf(g.a, g.b)!.favorites, hasLength(1));
    }, timeout: transferTimeout);
  });

  group('E763 the alias (RF-429) [SEG]', () {
    test('changes displayName in the entries, keeps realName, and is removed '
        'when left empty', () async {
      final (a, b) = await transferNodes();
      final fp = b.fingerprint;

      a.node.setAlias(fp, '  Portátil de casa  ');
      await a.until((s) => a.entryOf(fp)?.alias != null);

      expect(a.entryOf(fp)!.displayName, 'Portátil de casa');
      expect(a.entryOf(fp)!.alias, 'Portátil de casa');
      expect(a.entryOf(fp)!.realName, 'Laptop');
      expect(viewOf(a, b)!.alias, 'Portátil de casa');
      expect(viewOf(a, b)!.realName, 'Laptop');

      a.node.setAlias(fp, '   ');
      await a.until((s) => a.entryOf(fp)?.alias == null);

      expect(a.entryOf(fp)!.displayName, 'Laptop');
      expect(a.entryOf(fp)!.realName, 'Laptop');
      expect(viewOf(a, b)!.alias, isNull);
    }, timeout: transferTimeout);

    test('survives a restart', () async {
      final (a, b) = await transferNodes();

      a.node.setAlias(b.fingerprint, 'Portátil');
      await a.restart();

      expect(a.entryOf(b.fingerprint)!.displayName, 'Portátil');
      expect(a.entryOf(b.fingerprint)!.realName, 'Laptop');
    }, timeout: transferTimeout);

    test('the queues keep the real name so the card can show both', () async {
      final (a, b) = await transferNodes();
      a.node.setAlias(b.fingerprint, 'Portátil');
      await a.until((s) => a.entryOf(b.fingerprint)?.alias != null);

      await a.node.sendPaths(b.fingerprint, [
        await a.sourceFile('uno.txt', [1]),
        await a.sourceFile('dos.txt', [2]),
      ]);
      await a.until((s) => s.queues != null, reason: 'the queues');

      expect(a.state.queues!.peerName, 'Laptop');
      expect(a.entryOf(b.fingerprint)!.displayName, 'Portátil');
    }, timeout: transferTimeout);

    test('no request and no announcement that leaves the node holds the '
        'alias: the bodies reach a recording peer', () async {
      final (a, peer) = await nodeWithRecorder();
      final capture = await AnnouncementCapture.of(a);
      await a.node.rescan();
      await a.until(
        (s) => a.entryOf(peer.fingerprint)?.visible == true,
        reason: 'the recording peer is visible',
      );

      a.node.setAlias(peer.fingerprint, secretAlias);
      await a.until((s) => a.entryOf(peer.fingerprint)?.alias == secretAlias);
      await a.node.rescan();
      await a.node.setDeviceName('Desk Renamed');
      await eventually(
        () => capture.namesFrom(a.fingerprint).isNotEmpty,
        reason: 'an announcement of A',
      );
      await a.node.listRemoteRoots(peer.fingerprint);
      await a.node.sendPaths(peer.fingerprint, [
        await a.sourceFile('uno.txt', [1, 2, 3]),
      ]);
      final first = await a.sentResult();
      await a.node.sendPaths(
        peer.fingerprint,
        [
          await a.sourceFile('dos.txt', [4]),
        ],
        destination: SharedFolderDestination(
          rootId: '1' * 32,
          rootName: 'docs',
          path: const ['sub'],
        ),
      );
      await a.sentResult(after: first);
      await a.node.unpair(peer.fingerprint);
      await eventually(
        () => peer.paths.contains(ApiPaths.unpair),
        reason: 'the unpair notice',
      );

      expect(
        peer.paths.toSet(),
        containsAll([
          ApiPaths.register,
          ApiPaths.browse,
          ApiPaths.transferOffer,
          ApiPaths.unpair,
        ]),
      );
      for (final (path, body) in peer.calls) {
        expect(body, isNot(contains(secretAlias)), reason: path);
      }
      expect(capture.namesFrom(a.fingerprint), isNotEmpty);
      expect(capture.anyContains(utf8.encode(secretAlias)), isFalse);
      expect(a.logs.join('\n'), isNot(contains(secretAlias)));
    }, timeout: transferTimeout);

    test('with two real nodes, the other one never learns it and only '
        'peers.json of this device holds it', () async {
      final (a, b) = await transferNodes();
      final fp = b.fingerprint;
      a.node.setAlias(fp, secretAlias);
      await a.until((s) => a.entryOf(fp)?.alias == secretAlias);

      await a.node.sendPaths(fp, [
        await a.sourceFile('uno.txt', [1, 2, 3]),
      ]);
      await a.sentResult();
      await b.receivedResult();
      await meet(a, b);
      await a.node.setMine(fp, mine: false);
      await a.node.setMine(fp, mine: true);
      await pause(const Duration(milliseconds: 800));

      expectNoAliasOnDisk(b.dataDir, secretAlias);
      expect(b.logs.join('\n'), isNot(contains(secretAlias)));
      expect(a.logs.join('\n'), isNot(contains(secretAlias)));
      expect(textWhenFree(a.pairedFile), isNot(contains(secretAlias)));
      expect(peersText(a), contains(secretAlias));
      expect(b.entryOf(a.fingerprint)!.displayName, 'Desk PC');
      expect(b.state.lastReceived!.peerName, isNot(contains(secretAlias)));
      expect(viewOf(b, a)!.alias, isNull);
    }, timeout: transferTimeout);
  });

  group('E765 peers.json that cannot be used (RF-406, RF-407)', () {
    test('a file that cannot be written gives one single peerNotesNotSaved, '
        'without retry, and the data stay for the session', () async {
      final g = await guardedNodes();
      final fp = g.b.fingerprint;
      Directory(peersFileOf(g.a).path).createSync();

      g.a.node.setAlias(fp, 'Casa');
      await g.a.until(
        (s) => g.a.noticesOf(NoticeKind.peerNotesNotSaved).isNotEmpty,
        reason: 'the notice',
      );

      expect(
        g.a.noticesOf(NoticeKind.peerNotesNotSaved).single.canRetry,
        isFalse,
      );
      expect(g.a.entryOf(fp)!.displayName, 'Casa');

      g.a.node.addFavorite(fp, saved(g, const ['sub']));
      await pause(const Duration(milliseconds: 1600));
      await g.sendFile('a.txt', [1], g.to(const ['sub']));
      await historyOf(g.a, g.b, 1);
      await pause(const Duration(milliseconds: 1600));

      expect(g.a.noticesOf(NoticeKind.peerNotesNotSaved), hasLength(1));
      expect(viewOf(g.a, g.b)!.alias, 'Casa');
      expect(viewOf(g.a, g.b)!.favorites, hasLength(1));
      expect(viewOf(g.a, g.b)!.recent, hasLength(1));
      expect(viewOf(g.a, g.b)!.history, hasLength(1));
    }, timeout: transferTimeout);

    test('after dismissing the notice it does not come back in the same '
        'session', () async {
      final (a, b) = await transferNodes();
      final fp = b.fingerprint;
      Directory(peersFileOf(a).path).createSync();

      a.node.setAlias(fp, 'Uno');
      await a.until(
        (s) => a.noticesOf(NoticeKind.peerNotesNotSaved).isNotEmpty,
        reason: 'the notice',
      );
      a.node.dismissNotice(a.noticesOf(NoticeKind.peerNotesNotSaved).single.id);
      a.node.setAlias(fp, 'Dos');
      await pause(const Duration(milliseconds: 1600));

      expect(a.noticesOf(NoticeKind.peerNotesNotSaved), isEmpty);
    }, timeout: transferTimeout);

    test(
      'closing with a file that cannot be written does not hang or fail',
      () async {
        final (a, b) = await transferNodes();
        Directory(peersFileOf(a).path).createSync();
        a.node.setAlias(b.fingerprint, 'Casa');

        await a.stop().timeout(scaled(const Duration(seconds: 15)));

        expect(peersFilesAside(a), isEmpty);
      },
      timeout: transferTimeout,
    );

    test('a broken file gives empty notes, is set apart, shows no notice and '
        'nothing else is touched', () async {
      final (a, b) = await transferNodes(
        before: (a, b) async {
          peersFileOf(a).writeAsStringSync('{"version":1,');
        },
      );

      expect(viewOf(a, b)!.alias, isNull);
      expect(viewOf(a, b)!.history, isEmpty);
      expect(peersFilesAside(a).single, contains('broken'));
      expect(peersFileOf(a).existsSync(), isFalse);
      expect(a.state.notices, isEmpty);
      expect(a.entryOf(b.fingerprint)!.paired, isTrue);

      a.node.setAlias(b.fingerprint, 'Casa');
      await peersFileShows(a, (text) => text.contains('Casa'));
    }, timeout: transferTimeout);

    test('a folder in the place of the file at boot is set apart and the node '
        'starts', () async {
      final (a, b) = await transferNodes(
        before: (a, b) async {
          Directory(peersFileOf(a).path).createSync();
        },
      );

      expect(viewOf(a, b)!.alias, isNull);
      expect(a.state.notices, isEmpty);
    }, timeout: transferTimeout);

    test('fingerprints that are not paired are dropped without notice and '
        'the file is rewritten', () async {
      final stranger = 'F' * 64;
      late String own;
      final (a, b) = await transferNodes(
        before: (a, b) async {
          final idA = await a.loadIdentity();
          final idB = await b.loadIdentity();
          own = idB.fingerprint;
          writePeersFile(a, idA.fingerprint, [
            peerRow(own),
            peerRow(stranger, alias: 'Ya no'),
          ]);
        },
      );

      expect(viewOf(a, b)!.alias, 'Casa');
      expect(a.state.notices, isEmpty);
      expect(peersText(a), isNot(contains(stranger)));
      expect(peersText(a), contains(own));
    }, timeout: transferTimeout);

    test(
      'the file of another identity is set apart as previous-identity',
      () async {
        final (a, b) = await transferNodes(
          before: (a, b) async {
            final idB = await b.loadIdentity();
            writePeersFile(a, 'E' * 64, [peerRow(idB.fingerprint)]);
          },
        );

        expect(viewOf(a, b)!.alias, isNull);
        expect(peersFilesAside(a).single, contains('previous-identity'));
        expect(a.state.notices, isEmpty);
      },
      timeout: transferTimeout,
    );

    test('losing the identity leaves the notes of the old list out '
        '(RF-418)', () async {
      final (a, b) = await transferNodes();
      a.node.setAlias(b.fingerprint, 'Casa');
      await a.stop();
      final key = File('${a.dataPath}\\identity\\private-key.dpapi');
      key.writeAsBytesSync([1, 2, 3]);

      await a.start();

      expect(a.state.identityStatus, IdentityStatus.reset);
      expect(a.state.peers, isEmpty);
      expect(peersText(a), isNot(contains('Casa')));
      expect(peersFilesAside(a).single, contains('previous-identity'));
    }, timeout: transferTimeout);

    test('a history entry with an outcome this version does not know stays '
        'in the file but is not shown', () async {
      final (a, b) = await transferNodes(
        before: (a, b) async {
          final idA = await a.loadIdentity();
          final idB = await b.loadIdentity();
          writePeersFile(a, idA.fingerprint, [
            peerRow(
              idB.fingerprint,
              history: [
                validHistory()..['outcome'] = 'fromTheFuture',
                validHistory()..['name'] = 'visible.zip',
              ],
            ),
          ]);
        },
      );

      expect(peersFilesAside(a), isEmpty);
      expect(viewOf(a, b)!.history.single.name, 'visible.zip');
      expect(viewOf(a, b)!.history.single.outcome, TransferOutcome.saved);
      expect(viewOf(a, b)!.history.single.direction, HistoryDirection.sent);
    }, timeout: transferTimeout);
  });

  group('the grouped write and the flush at close (plan, T7)', () {
    test('the alias is not written at once but within the delay', () async {
      final (a, b) = await transferNodes();

      a.node.setAlias(b.fingerprint, 'Casa');

      expect(peersFileOf(a).existsSync(), isFalse);
      await peersFileShows(
        a,
        (text) => text.contains('Casa'),
        limit: scaled(const Duration(seconds: 3)),
      );
    }, timeout: transferTimeout);

    test('closing right after a change saves it', () async {
      final g = await guardedNodes();
      final fp = g.b.fingerprint;

      g.a.node.setAlias(fp, 'Casa');
      g.a.node.addFavorite(fp, saved(g, const ['sub']));
      await g.a.stop();

      expect(peersText(g.a), contains('Casa'));
      expect(peersText(g.a), contains('sub'));
    }, timeout: transferTimeout);

    test('closing right after a send keeps its history', () async {
      final (a, b) = await transferNodes();

      await a.node.sendPaths(b.fingerprint, [
        await a.sourceFile('uno.txt', [1]),
      ]);
      await historyOf(a, b, 1);
      await a.restart();

      expect(viewOf(a, b)!.history.single.name, 'uno.txt');
    }, timeout: transferTimeout);
  });

  group('E766 all is forgotten when a peer leaves (RF-418)', () {
    Future<(Guarded, String)> withNotes() async {
      final g = await guardedNodes();
      final fp = g.b.fingerprint;
      g.a.node.setAlias(fp, 'Casa');
      g.a.node.addFavorite(fp, saved(g, const ['otra']));
      await g.sendFile('a.txt', [1], g.to(const ['sub']));
      await historyOf(g.a, g.b, 1);
      await historyOf(g.b, g.a, 1);
      await peersFileShows(g.a, (text) => text.contains('Casa'));
      await peersFileShows(g.a, (text) => text.contains('a.txt'));
      await peersFileShows(g.b, (text) => text.contains('a.txt'));
      return (g, fp);
    }

    test('after unpairing, the notes are empty on both sides, peers.json no '
        'longer names the peer, and a restart does not bring them '
        'back', () async {
      final (g, fp) = await withNotes();
      final afp = g.a.fingerprint;

      await g.a.node.unpair(fp);
      await g.a.until((s) => !s.peers.containsKey(fp));
      await g.b.until((s) => !s.peers.containsKey(afp));

      await peersFileShows(g.a, (text) => !text.contains(fp));
      await peersFileShows(g.b, (text) => !text.contains(afp));
      expect(peersText(g.a), isNot(contains('Casa')));
      expect(peersText(g.a), isNot(contains('a.txt')));
      expect(peersText(g.b), isNot(contains('a.txt')));

      await g.a.restart();

      expect(g.a.state.peers, isEmpty);
      expect(peersText(g.a), isNot(contains(fp)));
    }, timeout: transferTimeout);

    test('the file changes without the delay of the grouped write', () async {
      final (g, fp) = await withNotes();
      final watch = Stopwatch()..start();

      await g.a.node.unpair(fp);
      await peersFileShows(g.a, (text) => !text.contains(fp));

      expect(
        watch.elapsed,
        lessThan(scaled(const Duration(milliseconds: 450))),
      );
    }, timeout: transferTimeout);

    test('a change not yet written does not come back after unpairing and '
        'closing', () async {
      final (a, b) = await transferNodes();
      final fp = b.fingerprint;
      a.node.setAlias(fp, 'Primero');
      await a.node.unpair(fp);
      await a.stop();

      expect(peersText(a), isNot(contains(fp)));
      expect(peersText(a), isNot(contains('Primero')));
    }, timeout: transferTimeout);

    test(
      'leaving and pairing again starts with nothing, also the shares',
      () async {
        final (g, fp) = await withNotes();

        await g.a.node.unpair(fp);
        await g.a.until((s) => !s.peers.containsKey(fp));
        await g.b.until((s) => !s.peers.containsKey(g.a.fingerprint));
        await pairAgain(g.a, g.b);
        await pause(const Duration(milliseconds: 800));

        final view = viewOf(g.a, g.b)!;
        expect(view.alias, isNull);
        expect(view.favorites, isEmpty);
        expect(view.recent, isEmpty);
        expect(view.history, isEmpty);
        expect(viewOf(g.b, g.a)!.history, isEmpty);
        expect(viewOf(g.b, g.a)!.shares, isEmpty);
        expect(peersText(g.a), isNot(contains('Casa')));
        expect(peersText(g.a), isNot(contains('a.txt')));
      },
      timeout: transferTimeout,
    );

    test('after pairing again, the new notes are kept and saved', () async {
      final (g, fp) = await withNotes();

      await g.a.node.unpair(fp);
      await g.a.until((s) => !s.peers.containsKey(fp));
      await g.b.until((s) => !s.peers.containsKey(g.a.fingerprint));
      await pairAgain(g.a, g.b);
      g.a.node.setAlias(fp, 'Otro');

      await peersFileShows(g.a, (text) => text.contains('Otro'));
      await g.a.restart();

      expect(viewOf(g.a, g.b)!.alias, 'Otro');
      expect(viewOf(g.a, g.b)!.history, isEmpty);
    }, timeout: transferTimeout);

    test('a transfer cut by the unpair leaves nothing behind in the notes of '
        'the sender', () async {
      final g = await guardedNodes();
      final fp = g.b.fingerprint;
      final folder = await bigFolder(g.a, 'grande', files: 2);

      await g.start(folder, g.to(const ['sub']));
      await receivingBytes(g.b);
      await g.a.node.unpair(fp);
      await g.a.until(
        (s) => s.outgoing == null && s.sendingTo == null,
        reason: 'the transfer ends',
      );
      await pause(const Duration(milliseconds: 800));

      expect(peersText(g.a), isNot(contains(fp)));
      expect(g.a.state.peers.containsKey(fp), isFalse);
    }, timeout: transferTimeout);
  });

  group('the send helpers of T7', () {
    test('pickFilesFor and pickFoldersFor return what was picked', () async {
      final (a, b) = await transferNodes();
      final files = [r'C:\x\a.txt', r'C:\x\b.txt'];
      a.picker.nextFiles = files;
      a.picker.nextFolders = [r'C:\x\carpeta'];

      expect(await a.node.pickFilesFor(b.fingerprint), files);
      expect(await a.node.pickFoldersFor(b.fingerprint), [r'C:\x\carpeta']);
    }, timeout: transferTimeout);

    test('with a peer it cannot send to, the picker does not open', () async {
      final (a, _) = await transferNodes();
      a.picker.nextFiles = [r'C:\x\a.txt'];
      final before = a.picker.fileCalls;

      expect(await a.node.pickFilesFor('F' * 64), isEmpty);
      expect(await a.node.pickFoldersFor('F' * 64), isEmpty);

      expect(a.picker.fileCalls, before);
    }, timeout: transferTimeout);

    test('sendTray with a destination sends to that folder and keeps it as '
        'a recent one', () async {
      final g = await guardedNodes();
      await g.a.node.addToTray([
        await g.a.sourceFile('t.txt', [7, 7]),
      ]);
      await g.a.until((s) => s.tray.isNotEmpty);

      final result = await g.a.node.sendTray(
        g.b.fingerprint,
        destination: g.to(const ['sub']),
      );

      expect(result, anyOf(SendResult.started, SendResult.queued));
      await untilView(g.a, g.b, (v) => v.recent.isNotEmpty);
      expect(File('${g.docs}\\sub\\t.txt').existsSync(), isTrue);
      expect(viewOf(g.a, g.b)!.recent, [
        saved(g, const ['sub']),
      ]);
    }, timeout: transferTimeout);

    test(
      'sendTray without a destination still goes to the default folder',
      () async {
        final (a, b) = await transferNodes();
        await a.node.addToTray([
          await a.sourceFile('t.txt', [7]),
        ]);
        await a.until((s) => s.tray.isNotEmpty);

        await a.node.sendTray(b.fingerprint);
        await historyOf(a, b, 1);

        expect(viewOf(a, b)!.history.single.destination, isNull);
        expect(File('${b.recvDir}\\t.txt').existsSync(), isTrue);
      },
      timeout: transferTimeout,
    );
  });
}
