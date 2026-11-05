@TestOn('windows')
library;

import 'dart:convert';
import 'dart:io';

import 'package:nexus_bridges_core/src/node/node.dart';
import 'package:test/test.dart';

import '../support/infra.dart';
import 'guard_nodes_support.dart';
import 'peer_notes_nodes_support.dart';
import 'transfer_nodes_harness.dart';

const String sentinel = 'CENTINELA-DEL-CONTENIDO-764';

Future<List<String>> threeFiles(TransferNode node) async => [
  await node.sourceFile('alfa.txt', utf8.encode('$sentinel-1')),
  await node.sourceFile('beta.txt', utf8.encode('$sentinel-22')),
  await node.sourceFile('gama.txt', utf8.encode('$sentinel-333')),
];

int sizeOf(List<String> paths) =>
    paths.map((path) => File(path).lengthSync()).reduce((a, b) => a + b);

void main() {
  group('E764 the history (RF-430, punto 16) [SEG]', () {
    test('three files to docs leave one entry in the sender and three in the '
        'receiver', () async {
      final g = await guardedNodes();
      final paths = await threeFiles(g.a);
      final total = sizeOf(paths);

      await g.a.node.sendPaths(
        g.b.fingerprint,
        paths,
        destination: g.to(const []),
      );
      await historyOf(g.a, g.b, 1);
      await historyOf(g.b, g.a, 3);
      await Future<void>.delayed(const Duration(milliseconds: 300));

      final sent = viewOf(g.a, g.b)!.history;
      expect(sent, hasLength(1));
      expect(sent.single.direction, HistoryDirection.sent);
      expect(sent.single.name, 'alfa.txt');
      expect(sent.single.isFolder, isFalse);
      expect(sent.single.itemCount, 3);
      expect(sent.single.delivered, 3);
      expect(sent.single.size, total);
      expect(sent.single.destination?.rootName, 'docs');
      expect(sent.single.destination?.path, isEmpty);
      expect(sent.single.outcome, TransferOutcome.saved);
      expect(sent.single.at, g.a.wallClock);

      final received = viewOf(g.b, g.a)!.history;
      expect(received, hasLength(3));
      expect(received.map((e) => e.name), ['gama.txt', 'beta.txt', 'alfa.txt']);
      for (final entry in received) {
        expect(entry.direction, HistoryDirection.received);
        expect(entry.itemCount, 1);
        expect(entry.delivered, 1);
        expect(entry.outcome, TransferOutcome.saved);
        expect(entry.destination?.rootName, 'docs');
      }
      expect(received.map((e) => e.size).reduce((a, b) => a + b), total);
    }, timeout: transferTimeout);

    test('a selection of three where the second fails leaves delivered 2 and '
        'the reason of that second one', () async {
      final g = await guardedNodes();
      final paths = [
        await g.a.sourceFile('alfa.txt', [1]),
        await g.a.sourceFile('beta.lnk', [2]),
        await g.a.sourceFile('gama.txt', [3]),
      ];

      await g.a.node.sendPaths(
        g.b.fingerprint,
        paths,
        destination: g.to(const ['sub']),
      );
      final view = await historyOf(g.a, g.b, 1);

      final failed = g.a.state.queues!.loose.firstWhere(
        (item) => item.name == 'beta.lnk',
      );
      expect(failed.outcome, isNot(TransferOutcome.saved));
      final entry = view.history.single;
      expect(entry.name, 'alfa.txt');
      expect(entry.itemCount, 3);
      expect(entry.delivered, 2);
      expect(entry.outcome, failed.outcome);
      expect(File('${g.docs}\\sub\\gama.txt').existsSync(), isTrue);
    }, timeout: transferTimeout);

    test(
      'when nothing arrives the entry has delivered 0 and the reason',
      () async {
        final g = await guardedNodes();

        final result = await g.sendFile('a.txt', [
          1,
        ], g.to(const ['no-existe']));
        final view = await historyOf(g.a, g.b, 1);

        expect(result.outcome, TransferOutcome.destinationMissing);
        expect(view.history.single.delivered, 0);
        expect(view.history.single.itemCount, 1);
        expect(view.history.single.outcome, TransferOutcome.destinationMissing);
        expect(view.history.single.destination?.path, ['no-existe']);
      },
      timeout: transferTimeout,
    );

    test('a folder leaves its file count on both sides', () async {
      final g = await guardedNodes();
      final folder = await smallFolder(g.a, 'proyecto');

      await g.a.node.sendPaths(g.b.fingerprint, [
        folder,
      ], destination: g.to(const ['sub']));
      final sent = (await historyOf(g.a, g.b, 1)).history.single;
      final received = (await historyOf(g.b, g.a, 1)).history.single;

      expect(sent.name, 'proyecto');
      expect(sent.isFolder, isTrue);
      expect(sent.fileCount, 2);
      expect(sent.itemCount, 1);
      expect(sent.delivered, 1);
      expect(sent.outcome, TransferOutcome.saved);
      expect(received.name, 'proyecto');
      expect(received.isFolder, isTrue);
      expect(received.fileCount, 2);
      expect(received.itemCount, 1);
      expect(received.destination?.path, ['sub']);
    }, timeout: transferTimeout);

    test(
      'a send to the default folder has no destination in the history',
      () async {
        final (a, b) = await transferNodes();

        await a.send(b, await a.sourceFile('uno.txt', [1, 2]));
        final sent = (await historyOf(a, b, 1)).history.single;
        final received = (await historyOf(b, a, 1)).history.single;

        expect(sent.destination, isNull);
        expect(sent.size, 2);
        expect(received.destination, isNull);
      },
      timeout: transferTimeout,
    );

    test('the newest entry goes first', () async {
      final (a, b) = await transferNodes();

      await a.send(b, await a.sourceFile('uno.txt', [1]));
      final first = await a.sentResult();
      await a.send(b, await a.sourceFile('dos.txt', [2]));
      await a.sentResult(after: first);
      final view = await historyOf(a, b, 2);

      expect(view.history.map((e) => e.name), ['dos.txt', 'uno.txt']);
    }, timeout: transferTimeout);

    test('both histories survive a restart', () async {
      final g = await guardedNodes();

      await g.a.node.sendPaths(
        g.b.fingerprint,
        await threeFiles(g.a),
        destination: g.to(const ['sub']),
      );
      final sent = (await historyOf(g.a, g.b, 1)).history;
      final received = (await historyOf(g.b, g.a, 3)).history;
      await peersFileShows(g.a, (text) => text.contains('alfa.txt'));
      await peersFileShows(g.b, (text) => text.contains('gama.txt'));

      await g.a.restart();
      await g.b.restart();

      expect(viewOf(g.a, g.b)!.history, sent);
      expect(viewOf(g.b, g.a)!.history, received);
      expect(peersFilesAside(g.a), isEmpty);
      expect(peersFilesAside(g.b), isEmpty);
    }, timeout: transferTimeout);

    test(
      'peers.json holds no upload permit, no content and no local path',
      () async {
        final g = await guardedNodes();

        await g.a.node.sendPaths(
          g.b.fingerprint,
          await threeFiles(g.a),
          destination: g.to(const ['sub']),
        );
        await historyOf(g.a, g.b, 1);
        await historyOf(g.b, g.a, 3);
        await peersFileShows(g.a, (text) => text.contains('alfa.txt'));
        await peersFileShows(g.b, (text) => text.contains('gama.txt'));
        await g.a.stop();
        await g.b.stop();

        for (final node in [g.a, g.b]) {
          final text = peersText(node);
          expect(looseHex32(text, {g.rootId}), isEmpty, reason: node.name);
          expect(text, isNot(contains(sentinel)), reason: node.name);
          expect(text, isNot(contains(r':\\')), reason: node.name);
          expect(
            text,
            isNot(contains(node.base.replaceAll(r'\', r'\\'))),
            reason: node.name,
          );
        }
      },
      timeout: transferTimeout,
    );

    test('a selection of 200 elements takes one single entry in the sender '
        'and the receiver keeps its last 50', () async {
      final g = await guardedNodes();
      final paths = [
        for (var i = 0; i < 200; i++)
          await g.a.sourceFile('n${i.toString().padLeft(3, '0')}.txt', [
            i % 256,
          ]),
      ];

      await g.a.node.sendPaths(
        g.b.fingerprint,
        paths,
        destination: g.to(const ['sub']),
      );
      final view = await historyOf(
        g.a,
        g.b,
        1,
        limit: scaled(const Duration(minutes: 3)),
      );

      expect(view.history, hasLength(1));
      expect(view.history.single.itemCount, 200);
      expect(
        view.history.single.delivered,
        200,
        reason: 'stopped with ${view.history.single.outcome.name}',
      );
      expect(view.history.single.name, 'n000.txt');
      final received = (await historyOf(g.b, g.a, 50)).history;
      expect(received, hasLength(50));
      expect(received.first.name, 'n199.txt');
      expect(viewOf(g.a, g.b)!.recent, hasLength(1));
    }, timeout: const Timeout(Duration(minutes: 4)));

    test('two selections that overlap are two entries (D-13)', () async {
      final g = await guardedNodes();
      final fp = g.b.fingerprint;
      final first = await bigFolder(g.a, 'grande', files: 1, size: 8 << 20);
      final second = await g.a.sourceFile('segundo.txt', [1, 2]);

      await g.a.node.sendPaths(fp, [first], destination: g.to(const ['sub']));
      await g.a.until((s) => s.sendingTo != null || s.outgoing != null);
      await g.a.node.sendPaths(fp, [second], destination: g.to(const ['otra']));
      final view = await historyOf(
        g.a,
        g.b,
        2,
        limit: scaled(const Duration(seconds: 40)),
      );

      expect(view.history.map((e) => e.name).toSet(), {
        'grande',
        'segundo.txt',
      });
      for (final entry in view.history) {
        expect(entry.itemCount, 1);
      }
    }, timeout: transferTimeout);

    test('a failed send with a destination the notes could never load does '
        'not cost the rest of the file at the next start', () async {
      final g = await guardedNodes();
      final fp = g.b.fingerprint;
      g.a.node.setAlias(fp, 'Casa');
      final bad = SharedFolderDestination(
        rootId: g.rootId,
        rootName: 'docs',
        path: const ['a:b'],
      );

      await g.sendFile('x.txt', [1], bad);
      await historyOf(g.a, g.b, 1);
      await g.a.restart();

      expect(peersFilesAside(g.a), isEmpty);
      expect(viewOf(g.a, g.b)!.alias, 'Casa');
    }, timeout: transferTimeout);
  });

  group('the whole task, with two real nodes (T7, "hecho cuando")', () {
    test('three files to docs\\sub: history, recent, alias, restart and '
        'unpair', () async {
      final g = await guardedNodes();
      final fp = g.b.fingerprint;
      final afp = g.a.fingerprint;

      g.a.node.setAlias(fp, 'Portátil');
      await g.a.node.sendPaths(
        fp,
        await threeFiles(g.a),
        destination: g.to(const ['sub']),
      );
      await historyOf(g.a, g.b, 1);
      await historyOf(g.b, g.a, 3);
      await untilView(g.a, g.b, (v) => v.recent.isNotEmpty);

      final destination = SavedDestination(
        rootId: g.rootId,
        rootName: 'docs',
        path: const ['sub'],
      );
      expect(viewOf(g.a, g.b)!.history, hasLength(1));
      expect(viewOf(g.a, g.b)!.recent, [destination]);
      expect(g.a.entryOf(fp)!.displayName, 'Portátil');
      expectNoAliasOnDisk(g.b.dataDir, 'Portátil');

      await g.a.restart();
      await g.b.restart();
      expect(viewOf(g.a, g.b)!.history, hasLength(1));
      expect(viewOf(g.a, g.b)!.recent, [destination]);
      expect(viewOf(g.b, g.a)!.history, hasLength(3));
      expect(g.a.entryOf(fp)!.displayName, 'Portátil');

      await meet(g.a, g.b);
      await g.a.node.unpair(fp);
      await g.a.until((s) => !s.peers.containsKey(fp));
      await g.b.until((s) => !s.peers.containsKey(afp));
      await peersFileShows(g.a, (text) => !text.contains(fp));
      await peersFileShows(g.b, (text) => !text.contains(afp));
    }, timeout: transferTimeout);
  });
}
