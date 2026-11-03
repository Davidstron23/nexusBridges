@TestOn('windows')
library;

import 'dart:io';

import 'package:nexus_bridges_core/src/browse/browse.dart';
import 'package:nexus_bridges_core/src/protocol/protocol.dart' show Limits;
import 'package:nexus_bridges_core/src/transfer/transfer.dart'
    show DestinationChanged, FreeNameMove, MovedTo, tempFolderName;
import 'package:test/test.dart';

import 'share_fs_support.dart';

Future<FolderListing> list(ShareTree tree, List<String> path) =>
    tree.fs.listFolders(
      tree.root,
      path,
      cap: Limits.browseEnumerationCap,
      max: Limits.maxBrowseEntries,
    );

Future<ChainHandles> openedChain(
  ShareTree tree,
  List<String> path, {
  String? newFolder,
}) async {
  final result = await tree.fs.openChain(tree.root, path, newFolder: newFolder);
  expect(result, isA<ChainOpened>());
  final chain = (result as ChainOpened).chain;
  live.add(chain);
  addTearDown(() async {
    if (live.remove(chain)) await tree.fs.releaseChain(chain, saved: false);
  });
  return chain;
}

final Set<ChainHandles> live = {};

Future<void> release(
  ShareTree tree,
  ChainHandles chain, {
  required bool saved,
}) async {
  if (live.remove(chain)) await tree.fs.releaseChain(chain, saved: saved);
}

Future<FreeNameMove> moveIn(
  ShareTree tree,
  ChainHandles chain,
  String content, {
  String name = 'informe.txt',
  String tempName = '~nexusbridges-0123456789ab.tmp',
}) {
  File('${chain.incomingPath}\\$tempName').writeAsStringSync(content);
  return tree.fs.recheckAndMove(
    chain,
    tempName: tempName,
    isFolder: false,
    name: name,
  );
}

void main() {
  group('G5 listFolders on a real tree (RF-409, RF-410) [SEG]', () {
    test(
      'E722 E723 the root lists only plain visible folders: no file, '
      'link, junction, hidden, system, forbidden, temp folder, CON or x.',
      () async {
        final tree = await shareTree();
        final listed = await list(tree, const []);
        expect(listed, isA<FolderListed>());
        final folders = listed as FolderListed;
        expect(folders.names, ['destino', 'MiProyectoLargo', 'otra', 'sub']);
        expect(folders.more, isFalse);
        expect(folders.partial, isFalse);
        expect(tree.outsideNames(), ['centinela']);
      },
    );

    test('E723 exploring a trap by name gives unavailable and the junction '
        'targets stay untouched', () async {
      final tree = await shareTree();
      final traps = <List<String>>[
        ['union'],
        ['interna'],
        ['ventanas'],
        ['Oculta'],
        ['Sistema'],
        ['.git'],
        ['Inicio'],
        ['f'],
        ['suelto.txt'],
        ['CON'],
        ['x.'],
        ['.nexusbridges-incoming'],
        ['falta'],
        ['sub', 'falta'],
        ['union', 'centinela'],
        if (tree.symlinked) ['enlace'],
      ];
      for (final trap in traps) {
        expect(
          await list(tree, trap),
          isA<FolderUnavailable>(),
          reason: '$trap',
        );
      }
      expect(tree.outsideNames(), ['centinela']);
      expect(Directory(r'C:\Windows\System32').existsSync(), isTrue);
      if (!tree.symlinked) {
        markTestSkipped('symbolic links need a privilege this session lacks');
      }
    });

    test('E723 the 8.3 short names of x. and .nexusbridges-incoming give '
        'unavailable (punto 1)', () async {
      final tree = await shareTree();
      final dotShort = shortNameOf(tree.child('x.'));
      final tempShort = shortNameOf(tree.child(tempFolderName));
      final longShort = shortNameOf(tree.child('MiProyectoLargo'));
      if (dotShort.isEmpty || tempShort.isEmpty || longShort.isEmpty) {
        markTestSkipped('the test volume does not make 8.3 names');
        return;
      }
      expect(await list(tree, [dotShort]), isA<FolderUnavailable>());
      expect(await list(tree, [tempShort]), isA<FolderUnavailable>());
      expect(await list(tree, [longShort]), isA<FolderUnavailable>());
      expect(await list(tree, ['MiProyectoLargo']), isA<FolderListed>());
    });

    test('G4 a name that differs only in case opens the real folder', () async {
      final tree = await shareTree();
      Directory(tree.child('sub\\hija')).createSync();
      final listed = await list(tree, ['SUB']);
      expect((listed as FolderListed).names, ['hija']);
    });

    test('E726 1001 folders give 1000 sorted with more, straße and STRASSE '
        'both listed', () async {
      final tree = await shareTree();
      final many = tree.child('muchas');
      for (var i = 0; i < 1001; i++) {
        Directory('$many\\c${1000 + i}').createSync(recursive: true);
      }
      final listed = await list(tree, ['muchas']) as FolderListed;
      expect(listed.names, hasLength(1000));
      expect(listed.more, isTrue);
      expect(listed.names.first, 'c1000');
      expect(listed.names.last, 'c1999');
      final mixed = tree.child('mixta');
      Directory('$mixed\\stra\u{DF}e').createSync(recursive: true);
      Directory('$mixed\\STRASSE').createSync();
      final both = await list(tree, ['mixta']) as FolderListed;
      expect(both.names, unorderedEquals(['stra\u{DF}e', 'STRASSE']));
    });
  });

  group('G3 root usable (RF-404)', () {
    test('E724 a hidden root is still listed and explored', () async {
      final tree = await shareTree();
      attrib('+h', tree.docs);
      final zero = await tree.fs.levelZero(
        [tree.root],
        const [],
        budget: Limits.shareCheckTimeout,
      );
      expect(zero.available, [true]);
      expect(await list(tree, const []), isA<FolderListed>());
    });

    test('E729 another volume id, a deleted root and a root swapped for a '
        'junction are not available', () async {
      final tree = await shareTree();
      final other = recordFor(
        tree.child('sub'),
        id: 2,
        volumeId: 'NTFS-00000000',
      );
      final gonePath = tree.child('borrar');
      Directory(gonePath).createSync();
      final gone = recordFor(gonePath, id: 3);
      Directory(gonePath).deleteSync();
      final swappedPath = tree.child('cambiada');
      Directory(swappedPath).createSync();
      final swapped = recordFor(swappedPath, id: 4);
      Directory(swappedPath).deleteSync();
      junction(swappedPath, tree.outside);
      final zero = await tree.fs.levelZero(
        [tree.root, other, gone, swapped],
        [
          (tree.root, ['sub']),
          (tree.root, ['union']),
          (tree.root, ['falta']),
          (tree.root, ['Oculta']),
          (swapped, const []),
          (tree.root, ['x.']),
        ],
        budget: Limits.shareCheckTimeout,
      );
      expect(zero.available, [true, false, false, false]);
      expect(zero.checks, [true, false, false, false, false, false]);
      await zero.exited;
      for (final record in [other, gone, swapped]) {
        expect(
          await tree.fs.listFolders(
            record,
            const [],
            cap: Limits.browseEnumerationCap,
            max: Limits.maxBrowseEntries,
          ),
          isA<FolderUnavailable>(),
        );
        expect(
          await tree.fs.openChain(record, const []),
          isA<ChainUnavailable>(),
        );
      }
      expect(tree.outsideNames(), ['centinela']);
    });

    test('E731 levelZero with nothing to check answers at once', () async {
      final tree = await shareTree();
      final zero = await tree.fs.levelZero(
        const [],
        const [],
        budget: Limits.shareCheckTimeout,
      );
      expect(zero.available, isEmpty);
      expect(zero.checks, isEmpty);
    });
  });

  group(
    'G7 openChain, prepareChain and releaseChain (RF-414, RF-415) [SEG]',
    () {
      test('G7 the locked chain stops renaming the destination and its '
          'ancestors until it is released', () async {
        final tree = await shareTree();
        Directory(tree.child('sub\\hija')).createSync();
        final result = await tree.fs.openChain(tree.root, ['sub', 'hija']);
        final chain = (result as ChainOpened).chain;
        expect(
          chain.folderPath.toUpperCase(),
          tree.child('sub\\hija').toUpperCase(),
        );
        expect(renames(tree.child('sub'), tree.child('sub2')), isFalse);
        expect(
          renames(tree.child('sub\\hija'), tree.child('sub\\h2')),
          isFalse,
        );
        expect(renames(tree.docs, '${tree.base}\\docs2'), isFalse);
        await tree.fs.releaseChain(chain, saved: false);
        expect(renames(tree.child('sub'), tree.child('sub2')), isTrue);
      });

      test(
        'G7 missing folders give ChainMissing, traps give ChainUnavailable',
        () async {
          final tree = await shareTree();
          File(tree.child('sub\\archivo')).writeAsStringSync('x');
          expect(
            await tree.fs.openChain(tree.root, ['falta']),
            isA<ChainMissing>(),
          );
          expect(
            await tree.fs.openChain(tree.root, ['sub', 'falta']),
            isA<ChainMissing>(),
          );
          expect(
            await tree.fs.openChain(tree.root, ['falta'], newFolder: 'nueva'),
            isA<ChainMissing>(),
          );
          expect(
            await tree.fs.openChain(tree.root, ['f']),
            isA<ChainMissing>(),
          );
          expect(
            await tree.fs.openChain(tree.root, ['sub', 'archivo']),
            isA<ChainMissing>(),
          );
          for (final trap in [
            ['union'],
            ['Oculta'],
            ['Inicio'],
            ['CON'],
            ['x.'],
            [tempFolderName],
            ['union', 'centinela'],
          ]) {
            expect(
              await tree.fs.openChain(tree.root, trap),
              isA<ChainUnavailable>(),
              reason: '$trap',
            );
          }
          expect(
            await tree.fs.openChain(tree.root, ['sub'], newFolder: 'archivo'),
            isA<ChainUnavailable>(),
          );
          expect(
            await tree.fs.openChain(tree.root, const [], newFolder: 'union'),
            isA<ChainUnavailable>(),
          );
          expect(
            await tree.fs.openChain(tree.root, const [], newFolder: 'Oculta'),
            isA<ChainUnavailable>(),
          );
          expect(Directory(tree.child('falta')).existsSync(), isFalse);
          expect(tree.outsideNames(), ['centinela']);
        },
      );

      test('G7 a new folder named like the 8.3 name of another folder is '
          'refused without writing in it (punto 1, DD-16)', () async {
        final tree = await shareTree();
        final longShort = shortNameOf(tree.child('MiProyectoLargo'));
        if (longShort.isEmpty) {
          markTestSkipped('the test volume does not make 8.3 names');
          return;
        }
        expect(
          await tree.fs.openChain(tree.root, const [], newFolder: longShort),
          isA<ChainUnavailable>(),
        );
        expect(Directory(tree.child('MiProyectoLargo')).listSync(), isEmpty);
      });

      test('G7 a new folder mods when Mods exists uses Mods', () async {
        final tree = await shareTree();
        Directory(tree.child('Mods')).createSync();
        final chain = await openedChain(tree, const [], newFolder: 'mods');
        expect(
          chain.folderPath.toUpperCase(),
          tree.child('Mods').toUpperCase(),
        );
        expect(await tree.fs.prepareChain(chain), isTrue);
        expect(chain.createdNew, isFalse);
        expect(chain.folderPath, endsWith(r'\Mods'));
        await release(tree, chain, saved: false);
        expect(Directory(tree.child('Mods')).existsSync(), isTrue);
      });

      test(
        'G7 G8 a file reaches docs\\sub through the temp folder and the temp '
        'folder is gone after release',
        () async {
          final tree = await shareTree();
          final chain = await openedChain(tree, ['sub']);
          expect(chain.cloud, isFalse);
          expect(chain.supportsMark, isTrue);
          expect(chain.freeBytes, greaterThan(0));
          expect(
            Directory(tree.child('sub\\$tempFolderName')).existsSync(),
            isFalse,
          );
          expect(await tree.fs.prepareChain(chain), isTrue);
          final incoming = tree.child('sub\\$tempFolderName');
          expect(chain.incomingPath?.toUpperCase(), incoming.toUpperCase());
          expect(Directory(incoming).existsSync(), isTrue);
          expect(await moveIn(tree, chain, 'uno'), isA<MovedTo>());
          final second = await moveIn(tree, chain, 'dos');
          expect((second as MovedTo).finalName, 'informe (1).txt');
          await release(tree, chain, saved: true);
          expect(
            File(tree.child('sub\\informe.txt')).readAsStringSync(),
            'uno',
          );
          expect(
            File(tree.child('sub\\informe (1).txt')).readAsStringSync(),
            'dos',
          );
          expect(Directory(incoming).existsSync(), isFalse);
          expect(renames(tree.child('sub'), tree.child('sub2')), isTrue);
        },
      );

      test('G7 a new folder is created at prepare, kept when saved and removed '
          'when the send fails', () async {
        final tree = await shareTree();
        final chain = await openedChain(tree, ['sub'], newFolder: 'nueva');
        expect(Directory(tree.child('sub\\nueva')).existsSync(), isFalse);
        expect(
          chain.folderPath.toUpperCase(),
          tree.child('sub\\nueva').toUpperCase(),
        );
        expect(await tree.fs.prepareChain(chain), isTrue);
        expect(chain.createdNew, isTrue);
        expect(Directory(tree.child('sub\\nueva')).existsSync(), isTrue);
        expect(
          renames(tree.child('sub\\nueva'), tree.child('sub\\n2')),
          isFalse,
        );
        expect(await moveIn(tree, chain, 'nuevo'), isA<MovedTo>());
        await release(tree, chain, saved: true);
        expect(
          File(tree.child('sub\\nueva\\informe.txt')).readAsStringSync(),
          'nuevo',
        );
        expect(
          Directory(tree.child('sub\\nueva\\$tempFolderName')).existsSync(),
          isFalse,
        );

        final failed = await openedChain(tree, ['sub'], newFolder: 'vacia');
        expect(await tree.fs.prepareChain(failed), isTrue);
        await release(tree, failed, saved: false);
        expect(Directory(tree.child('sub\\vacia')).existsSync(), isFalse);
      });

      test('E741 a new folder created by another program between resolve and '
          'prepare is used and never removed', () async {
        final tree = await shareTree();
        final chain = await openedChain(tree, ['sub'], newFolder: 'ajena');
        Directory(tree.child('sub\\ajena')).createSync();
        File(tree.child('sub\\ajena\\suyo.txt')).writeAsStringSync('suyo');
        expect(await tree.fs.prepareChain(chain), isTrue);
        expect(chain.createdNew, isFalse);
        await release(tree, chain, saved: false);
        expect(File(tree.child('sub\\ajena\\suyo.txt')).existsSync(), isTrue);
      });

      test('G8 a folder of the chain marked hidden during the session gives '
          'DestinationChanged and nothing lands', () async {
        final tree = await shareTree();
        Directory(tree.child('sub\\hija')).createSync();
        final chain = await openedChain(tree, ['sub', 'hija']);
        expect(await tree.fs.prepareChain(chain), isTrue);
        attrib('+h', tree.child('sub'));
        expect(await moveIn(tree, chain, 'x'), isA<DestinationChanged>());
        expect(
          File(tree.child('sub\\hija\\informe.txt')).existsSync(),
          isFalse,
        );
        attrib('-h', tree.child('sub'));
        expect(
          await moveIn(tree, chain, 'x', tempName: 't2.tmp'),
          isA<MovedTo>(),
        );
      });

      test('G8 two chains over the same destination live together', () async {
        final tree = await shareTree();
        final first = await openedChain(tree, ['sub']);
        final second = await openedChain(tree, ['sub']);
        expect(await tree.fs.prepareChain(first), isTrue);
        expect(await tree.fs.prepareChain(second), isTrue);
        expect(
          await moveIn(tree, first, 'a', tempName: 'a.tmp'),
          isA<MovedTo>(),
        );
        expect(
          await moveIn(tree, second, 'b', tempName: 'b.tmp'),
          isA<MovedTo>(),
        );
        await release(tree, first, saved: true);
        await release(tree, second, saved: true);
        expect(
          Directory(tree.child('sub'))
              .listSync()
              .map((e) => e.uri.pathSegments.last)
              .toSet(),
          {'informe.txt', 'informe (1).txt'},
        );
      });
    },
  );
}
