@TestOn('windows')
library;

import 'dart:io';

import 'package:nexus_bridges_core/src/browse/browse.dart';
import 'package:nexus_bridges_core/src/transfer/transfer.dart'
    show TransferOutcome;
import 'package:test/test.dart';

import 'guard_nodes_support.dart';
import 'transfer_nodes_harness.dart';

void main() {
  group('E787 the portal asks like Browse (RF-435) [SEG]', () {
    test('E787 a walk over roots and folders is told busy on the 21st '
        'request within the window', () async {
      final g = await guardedNodes();

      for (var i = 0; i < 20; i++) {
        final listing = i.isEven
            ? await g.a.node.listRemoteRoots(g.b.fingerprint)
            : await g.a.node.listRemoteFolders(
                g.b.fingerprint,
                g.rootId,
                const ['sub'],
              );
        expect(listing, isNot(isA<RemoteListingFailed>()), reason: 'walk $i');
      }

      final limited = await g.a.node.listRemoteFolders(
        g.b.fingerprint,
        g.rootId,
        const [],
      );

      expect((limited as RemoteListingFailed).reason, BrowseFailure.busy);
    }, timeout: transferTimeout);

    test('E787 a receiver that has the sender as someone else leaves the '
        'portal shut', () async {
      final g = await guardedNodes();
      await g.b.node.setMine(g.a.fingerprint, mine: false);

      final listing = await g.a.node.listRemoteRoots(g.b.fingerprint);

      expect((listing as RemoteListingFailed).reason, BrowseFailure.notAllowed);
    }, timeout: transferTimeout);

    test(
      'E787 without folders for this sender there are no roots to show',
      () async {
        final g = await guardedNodes();
        await g.b.node.removeShare(g.a.fingerprint, g.rootId);

        final listing = await g.a.node.listRemoteRoots(g.b.fingerprint);

        expect((listing as RemoteRoots).roots, isEmpty);
      },
      timeout: transferTimeout,
    );

    test('E787 dropping on a folder the receiver just removed is refused '
        'writing nothing', () async {
      final g = await guardedNodes();
      final before = folderShot(g.docs);
      await g.b.node.removeShare(g.a.fingerprint, g.rootId);

      final sent = await g.sendFile('a.txt', [1, 2], g.to(const ['sub']));

      expect(sent.outcome, TransferOutcome.destinationUnavailable);
      expect(folderShot(g.docs), before);
    }, timeout: transferTimeout);
  });

  group('E781 a new folder over the network (RF-424)', () {
    test(
      'E781 the receiver has no folder until the transfer arrives',
      () async {
        final g = await guardedNodes();
        final target = '${g.docs}\\sub\\prueba-007';
        expect(exists(target), isFalse);

        final listing = await g.a.node.listRemoteFolders(
          g.b.fingerprint,
          g.rootId,
          const ['sub'],
        );
        expect((listing as RemoteFolders).names, isNot(contains('prueba-007')));
        expect(exists(target), isFalse);

        final sent = await g.sendFile('a.txt', [
          1,
          2,
          3,
        ], g.to(const ['sub'], newFolder: 'prueba-007'));

        expect(sent.outcome, TransferOutcome.saved);
        expect(File('$target\\a.txt').readAsBytesSync(), [1, 2, 3]);
      },
      timeout: transferTimeout,
    );
  });
}
