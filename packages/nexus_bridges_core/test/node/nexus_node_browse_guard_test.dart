@TestOn('windows')
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:nexus_bridges_core/src/browse/browse.dart';
import 'package:nexus_bridges_core/src/pairing/pairing.dart' show PeerRelation;
import 'package:nexus_bridges_core/src/protocol/protocol.dart';
import 'package:nexus_bridges_core/src/transfer/transfer.dart'
    show SharedFolderDestination, TransferOutcome, tempFolderName;
import 'package:test/test.dart';

import 'guard_nodes_support.dart';
import 'transfer_nodes_harness.dart';

void main() {
  group('E721 only a granted "mine" peer gets content (RF-408) [SEG]', () {
    test('E721 a root of another peer, an invented root, a removed root and '
        'a foreign peer get the same 403 byte by byte, with no disk access, '
        'and a stranger is cut at the TLS handshake', () async {
      late CountingShareFileSystem fs;
      final (a, b, c) = await transferTrio(
        cAtB: PeerRelation.mine,
        before: (a, b, c) async {
          for (final name in ['docs\\sub', 'decee', 'quitada']) {
            Directory('${b.base}\\$name').createSync(recursive: true);
          }
          fs = countingFor(b);
        },
      );
      final rootA = await addRoot(b, a, docsOf(b));
      final rootC = await addRoot(b, c, '${b.base}\\decee');
      final gone = await addRoot(b, c, '${b.base}\\quitada');
      await b.node.removeShare(c.fingerprint, gone);
      fs.reset();

      for (final id in [rootA, 'f' * 32, gone]) {
        await expectBrowse(
          c,
          b,
          foldersAsk(id, const []),
          403,
          forbiddenBody,
          reason: id,
        );
        await expectBrowse(
          c,
          b,
          foldersAsk(id, const ['sub']),
          403,
          forbiddenBody,
          reason: id,
        );
      }
      expect(fs.touches, 0);

      await b.node.setMine(c.fingerprint, mine: false);
      for (final ask in [
        rootsAsk(),
        rootsAsk(
          check: [
            {'root': rootC, 'path': <String>[]},
          ],
        ),
        foldersAsk(rootC, const []),
        foldersAsk(rootA, const []),
        foldersAsk('f' * 32, const []),
      ]) {
        await expectBrowse(c, b, ask, 403, forbiddenBody, reason: '$ask');
      }
      expect(fs.touches, 0);
      expect(
        (await c.node.listRemoteRoots(
          b.fingerprint,
        ) as RemoteListingFailed).reason,
        BrowseFailure.notAllowed,
      );
      expect(fs.touches, 0);

      final stranger = await TransferNode.create(
        'Stranger',
        '127.0.0.4',
        port: b.port,
      );
      final cut = await rawPost(
        stranger,
        b,
        ApiPaths.browse,
        foldersAsk(rootA, const []),
      );
      expect(cut, isNull);
      expect(fs.touches, 0);

      final held = await rawPost(a, b, ApiPaths.browse, rootsAsk());
      expect(held!.status, 200);
    }, timeout: transferTimeout);

    test('E721 a root removed while a listing runs gives the same 403 and no '
        'content (G9 step 8)', () async {
      final g = await guardedNodes();
      final gate = g.fs.listGate = Completer<void>();
      addTearDown(() {
        if (!gate.isCompleted) gate.complete();
      });
      final pending = rawPost(
        g.a,
        g.b,
        ApiPaths.browse,
        foldersAsk(g.rootId, const []),
      );
      await eventually(
        () => g.fs.touches > 0,
        limit: transferWait,
        reason: 'listing started',
      );
      await g.b.node.removeShare(g.a.fingerprint, g.rootId);
      gate.complete();
      final reply = await pending;
      expect(reply!.status, 403);
      expect(reply.body, forbiddenBody);
    }, timeout: transferTimeout);
  });

  group('E722 nothing but names leaves the receiver (RF-409) [SEG]', () {
    test(
      'E722 files, a .lnk and a desktop.ini stay hidden, the keys are '
      'exactly the format and the bytes carry no path nor user name',
      () async {
        final user = Platform.environment['USERNAME'] ?? 'no-user-name';
        final g = await guardedNodes(
          tree: (b) {
            final docs = docsOf(b);
            Directory('$docs\\juegos').createSync(recursive: true);
            Directory('$docs\\mods').createSync();
            for (final name in ['a.txt', 'b.exe', 'c.lnk', 'desktop.ini']) {
              File('$docs\\$name').writeAsStringSync('dato');
            }
            return true;
          },
        );
        final docs = g.docs;

        final zero = (await rawPost(g.a, g.b, ApiPaths.browse, rootsAsk()))!;
        expect(zero.status, 200);
        final zeroJson = bodyOf(zero)! as Map<String, Object?>;
        expect(zeroJson.keys, ['roots']);
        final root = (zeroJson['roots']! as List<Object?>).single;
        expect((root! as Map<String, Object?>).keys.toSet(), {
          'id',
          'name',
          'home',
          'available',
        });

        final listed = (await rawPost(
          g.a,
          g.b,
          ApiPaths.browse,
          foldersAsk(g.rootId, const []),
        ))!;
        expect(listed.status, 200);
        expect(bodyOf(listed), {
          'folders': ['juegos', 'mods'],
          'more': false,
          'partial': false,
        });

        for (final reply in [zero, listed]) {
          final text = utf8.decode(reply.body);
          for (final secret in [
            docs,
            jsonEncode(docs),
            g.b.base,
            docs.replaceAll(r'\', '/'),
            user,
          ]) {
            expect(
              text.toLowerCase(),
              isNot(contains(secret.toLowerCase())),
              reason: secret,
            );
          }
        }
      },
      timeout: transferTimeout,
    );
  });

  group('E723 traps inside a root (RF-410) [SEG]', () {
    late Guarded g;
    late bool symlinked;

    setUp(() async {
      symlinked = false;
      g = await guardedNodes(tree: (b) => symlinked = buildTrapTree(b));
    });

    test(
      'E723 only the plain folders are listed; the junctions, links, '
      'hidden, system, forbidden, temp, reserved folders and the file give '
      'the same 404 by name and by short name, the sentinel never shows',
      () async {
        final listed = await g.a.node.listRemoteFolders(
          g.b.fingerprint,
          g.rootId,
          const [],
        );
        expect((listed as RemoteFolders).names, plainFolders);

        final traps = <String>[
          'union',
          'interna',
          'ventanas',
          if (symlinked) 'enlace',
          'Oculta',
          'Sistema',
          '.git',
          'Inicio',
          tempFolderName,
          'f',
          'CON',
          'x.',
        ];
        for (final name in traps) {
          g.b.clock.advance(const Duration(seconds: 1));
          await expectBrowse(
            g.a,
            g.b,
            foldersAsk(g.rootId, [name]),
            404,
            unavailableBody,
            reason: name,
          );
        }
        g.b.clock.advance(Limits.browseWindow);
        for (final name in ['union', 'ventanas', 'interna']) {
          await expectBrowse(
            g.a,
            g.b,
            foldersAsk(g.rootId, [name, 'centinela']),
            404,
            unavailableBody,
            reason: name,
          );
        }
        expect(namesIn(g.outside), ['centinela']);
      },
      timeout: transferTimeout,
    );

    test('E723 the 8.3 names of x. and .nexusbridges-incoming and of a plain '
        'folder never open anything (punto 1)', () async {
      final shortX = shortNameOf('${g.docs}\\x.');
      final shortTemp = shortNameOf('${g.docs}\\$tempFolderName');
      final shortLong = shortNameOf('${g.docs}\\MiProyectoLargo');
      final names = [
        for (final name in [shortX, shortTemp, shortLong])
          if (name.isNotEmpty) name,
      ];
      if (names.isEmpty) {
        markTestSkipped('this volume has no 8.3 names');
        return;
      }
      for (final name in names) {
        await expectBrowse(
          g.a,
          g.b,
          foldersAsk(g.rootId, [name]),
          404,
          unavailableBody,
          reason: name,
        );
      }
    }, timeout: transferTimeout);
  });

  group('E724 a hidden root (RF-410)', () {
    test('E724 the owner chose it: it is listed and explored, its hidden '
        'children are not', () async {
      final g = await guardedNodes(
        tree: (b) {
          final docs = docsOf(b);
          Directory('$docs\\sub').createSync(recursive: true);
          Directory('$docs\\oculta').createSync();
          attrib('+h', '$docs\\oculta');
          attrib('+h', docs);
          return true;
        },
      );
      final zero = await g.a.node.listRemoteRoots(g.b.fingerprint);
      final root = (zero as RemoteRoots).roots.single;
      expect(root.available, isTrue);
      final listed = await g.a.node.listRemoteFolders(
        g.b.fingerprint,
        root.id,
        const [],
      );
      expect((listed as RemoteFolders).names, ['sub']);
    }, timeout: transferTimeout);
  });

  group('E725 invalid paths over the network (RF-411) [SEG]', () {
    test('E725 every path of E700 gives the same 404 and the disk is never '
        'touched', () async {
      final g = await guardedNodes();
      final tooLong = 'a' * (237 - g.docs.length);
      final traps = <List<String>>[
        ['..'],
        ['.'],
        ['a', '..'],
        ['a', '..', '..', 'Windows'],
        [r'a\..\..\Windows'],
        [r'C:\Windows'],
        ['C:'],
        [r'\\host\share'],
        [r'\\?\C:\'],
        [r'\\.\C:'],
        ['a\u{1}b'],
        ['a*'],
        ['a?'],
        ['a"'],
        ['a<'],
        ['a>'],
        ['a|'],
        ['a/b'],
        ['a:b'],
        ['CON'],
        ['con.txt'],
        ['COM\u{B9}'],
        ['x.'],
        ['x '],
        ['a\u{202E}b'],
        List.filled(33, 'a'),
        ['sub', tooLong],
      ];
      for (final trap in traps) {
        g.b.clock.advance(const Duration(seconds: 1));
        await expectBrowse(
          g.a,
          g.b,
          foldersAsk(g.rootId, trap),
          404,
          unavailableBody,
          reason: '$trap',
        );
      }
      await expectBrowse(
        g.a,
        g.b,
        foldersAsk(g.rootId, const ['']),
        400,
        utf8.encode('{"error":"bad_request"}'),
      );
      expect(g.fs.touches, 0);
    }, timeout: transferTimeout);
  });

  group('E726 size of a listing (RF-412)', () {
    test('E726 1001 folders give 1000 in folderKey order with more; 1000 '
        'exact give no more; the sender accepts the answer', () async {
      final expected = [
        for (var i = 0; i < 1001; i++) 'c${i.toString().padLeft(4, '0')}',
      ];
      final g = await guardedNodes(
        tree: (b) {
          final docs = docsOf(b);
          for (final name in expected) {
            Directory('$docs\\$name').createSync(recursive: true);
          }
          return true;
        },
      );
      final over = await g.a.node.listRemoteFolders(
        g.b.fingerprint,
        g.rootId,
        const [],
      );
      expect((over as RemoteFolders).names, expected.take(1000).toList());
      expect(over.more, isTrue);
      expect(over.partial, isFalse);

      Directory('${g.docs}\\c1000').deleteSync();
      final exact = await g.a.node.listRemoteFolders(
        g.b.fingerprint,
        g.rootId,
        const [],
      );
      expect((exact as RemoteFolders).names, hasLength(1000));
      expect(exact.more, isFalse);
    }, timeout: transferTimeout);

    test('E726 straße and STRASSE both come out and the sender keeps them; '
        'mixed case is ordered by folderKey', () async {
      final g = await guardedNodes(
        tree: (b) {
          final docs = docsOf(b);
          for (final name in ['straße', 'STRASSE', 'beta', 'Alfa']) {
            Directory('$docs\\$name').createSync(recursive: true);
          }
          return true;
        },
      );
      final listed = await g.a.node.listRemoteFolders(
        g.b.fingerprint,
        g.rootId,
        const [],
      );
      final names = (listed as RemoteFolders).names;
      expect(names.toSet(), {'straße', 'STRASSE', 'beta', 'Alfa'});
      final keys = [for (final name in names) folderKey(name)];
      expect(keys, [...keys]..sort());
    }, timeout: transferTimeout);
  });

  group('E728 limits over the network (RF-412) [SEG]', () {
    test('E728 the 21st request in 10 s gets 429, refused requests count too '
        'and one more is admitted after the window', () async {
      final g = await guardedNodes();
      for (var i = 0; i < 20; i++) {
        final ask = i.isEven
            ? rootsAsk()
            : i % 3 == 0
            ? foldersAsk('f' * 32, const [])
            : <String, Object?>{'protocol': protocolVersion, 'root': 'x'};
        final reply = await rawPost(g.a, g.b, ApiPaths.browse, ask);
        expect(reply!.status, isNot(429), reason: 'request $i');
      }
      final touches = g.fs.touches;
      final limited = await rawPost(g.a, g.b, ApiPaths.browse, rootsAsk());
      expect(limited!.status, 429);
      expect(limited.body, utf8.encode('{"error":"rate_limited"}'));
      expect(g.fs.touches, touches);

      final client = await g.a.node.listRemoteRoots(g.b.fingerprint);
      expect((client as RemoteListingFailed).reason, BrowseFailure.busy);

      g.b.clock.advance(Limits.browseWindow);
      final again = await rawPost(g.a, g.b, ApiPaths.browse, rootsAsk());
      expect(again!.status, 200);
    }, timeout: transferTimeout);

    test('E728 a third concurrent request of the same peer gets 429 until a '
        'slot comes free', () async {
      final g = await guardedNodes();
      final gate = g.fs.listGate = Completer<void>();
      addTearDown(() {
        if (!gate.isCompleted) gate.complete();
      });
      final running = [
        rawPost(g.a, g.b, ApiPaths.browse, foldersAsk(g.rootId, const [])),
        rawPost(g.a, g.b, ApiPaths.browse, foldersAsk(g.rootId, const ['sub'])),
      ];
      await eventually(
        () => g.fs.touches >= 2,
        limit: transferWait,
        reason: 'two listings running',
      );
      final third = await rawPost(
        g.a,
        g.b,
        ApiPaths.browse,
        foldersAsk(g.rootId, const ['otra']),
      );
      expect(third!.status, 429);
      gate.complete();
      for (final reply in await Future.wait(running)) {
        expect(reply!.status, 200);
      }
      final after = await rawPost(
        g.a,
        g.b,
        ApiPaths.browse,
        foldersAsk(g.rootId, const ['otra']),
      );
      expect(after!.status, 200);
    }, timeout: transferTimeout);
  });

  group('E729 a root that changed (RF-404) [SEG]', () {
    Future<void> expectClosed(
      Guarded g,
      String rootId,
      TransferOutcome outcome,
    ) async {
      final zero = await g.a.node.listRemoteRoots(g.b.fingerprint);
      expect((zero as RemoteRoots).roots.single.available, isFalse);
      await expectBrowse(
        g.a,
        g.b,
        foldersAsk(rootId, const []),
        404,
        unavailableBody,
      );
      final sent = await g.sendFile(
        'nunca.txt',
        [1, 2, 3],
        SharedFolderDestination(
          rootId: rootId,
          rootName: 'docs',
          path: const [],
        ),
      );
      expect(sent.outcome, outcome);
      expect(g.b.state.lastReceived, isNull);
    }

    test('E729 another volume id with the same path', () async {
      late CountingShareFileSystem fs;
      final (a, b) = await transferNodes(
        before: (a, b) async {
          buildSimpleTree(b);
          fs = countingFor(b);
          final identity = await b.loadIdentity();
          final other = await a.loadIdentity();
          await writeSharesFile(b, identity, {
            other.fingerprint: [
              await recordOf(docsOf(b), volumeId: 'NTFS-00000000'),
            ],
          });
        },
      );
      final g = Guarded(a, b, fs, 1.toRadixString(16).padLeft(32, '0'));
      await expectClosed(g, g.rootId, TransferOutcome.destinationUnavailable);
      expect(namesIn(g.docs), ['otra', 'sub']);
    }, timeout: transferTimeout);

    test('E729 the root swapped for a junction with the same name that '
        'points outside', () async {
      final g = await guardedNodes();
      Directory(g.docs).renameSync('${g.docs}.aparte');
      junction(g.docs, g.outside);
      addTearDown(() => Directory(g.docs).deleteSync());
      await expectClosed(g, g.rootId, TransferOutcome.destinationUnavailable);
      expect(namesIn(g.outside), ['centinela']);
      expect(g.fs.lastSaved, anyOf(isNull, isFalse));
    }, timeout: transferTimeout);

    test('E729 the root deleted', () async {
      final g = await guardedNodes();
      Directory(g.docs).deleteSync(recursive: true);
      await expectClosed(g, g.rootId, TransferOutcome.destinationUnavailable);
      expect(Directory(g.docs).existsSync(), isFalse);
    }, timeout: transferTimeout);
  });

  group('E730 favourites check (RF-422)', () {
    test('E730 an existing destination is true; a deleted folder, a removed '
        'root and an invalid path are false', () async {
      final g = await guardedNodes(
        tree: (b) {
          final docs = docsOf(b);
          Directory('$docs\\sub\\borrada').createSync(recursive: true);
          Directory('$docs\\sigue').createSync();
          Directory('${b.base}\\otraraiz').createSync();
          return true;
        },
      );
      final extra = await addRoot(g.b, g.a, '${g.b.base}\\otraraiz');
      await g.b.node.removeShare(g.a.fingerprint, extra);
      Directory('${g.docs}\\sub\\borrada').deleteSync();
      final zero = await g.a.node.listRemoteRoots(
        g.b.fingerprint,
        check: [
          BrowseCheck(rootId: g.rootId, path: const ['sigue']),
          BrowseCheck(rootId: g.rootId, path: const ['sub', 'borrada']),
          BrowseCheck(rootId: extra, path: const []),
          BrowseCheck(rootId: g.rootId, path: const ['..']),
          BrowseCheck(rootId: g.rootId, path: const []),
        ],
      );
      expect((zero as RemoteRoots).checks, [true, false, false, false, true]);
    }, timeout: transferTimeout);
  });

  group('E731 the level zero budget (punto 10)', () {
    test('E731 a forbidden list that takes longer than the budget answers at '
        '1.5 s with the roots as unavailable, before the 2 s of the menu, and '
        'the next one sees them', () async {
      final gate = Completer<void>();
      addTearDown(() {
        if (!gate.isCompleted) gate.complete();
      });
      late CountingShareFileSystem fs;
      final (a, b) = await transferNodes(
        before: (a, b) async {
          buildSimpleTree(b);
          fs = countingFor(b);
          final identity = await b.loadIdentity();
          final other = await a.loadIdentity();
          await writeSharesFile(b, identity, {
            other.fingerprint: [await recordOf(docsOf(b))],
          });
          b.platform.systemGate = gate;
        },
      );
      expect(fs.touches, lessThan(3));
      final watch = Stopwatch()..start();
      final zero = await a.node.listRemoteRoots(b.fingerprint);
      watch.stop();
      expect(zero, isA<RemoteRoots>());
      expect((zero as RemoteRoots).roots.single.available, isFalse);
      expect(watch.elapsed, lessThan(Limits.browseRootsTimeout));
      expect(
        watch.elapsed,
        greaterThanOrEqualTo(const Duration(milliseconds: 1400)),
      );
      gate.complete();
      b.platform.systemGate = null;
      final later = await a.node.listRemoteRoots(b.fingerprint);
      expect((later as RemoteRoots).roots.single.available, isTrue);
    }, timeout: transferTimeout);
  });
}
