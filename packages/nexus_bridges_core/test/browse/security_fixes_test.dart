@TestOn('windows')
library;

import 'dart:async';
import 'dart:io';

import 'package:nexus_bridges_core/src/browse/browse.dart';
import 'package:nexus_bridges_core/src/protocol/protocol.dart' show Limits;
import 'package:nexus_bridges_core/src/storage/storage.dart';
import 'package:nexus_bridges_core/src/transfer/platform.dart'
    show SystemFolders;
import 'package:nexus_bridges_core/src/transfer/transfer.dart'
    show
        DestinationChanged,
        DestinationRequest,
        MovedTo,
        SharedRefused,
        SharedResolved,
        tempFolderName;
import 'package:nexus_bridges_core/src/winio/winio.dart';
import 'package:test/test.dart';

import '../transfer/receiver_harness.dart' show TransferPlatform;
import 'junction_support.dart';
import 'share_admission_support.dart';
import 'share_fs_support.dart';

final RegExp witnessName = RegExp(r'^~nexusbridges-[0-9a-f]{16}\.hold$');

Future<ChainHandles> preparedChain(
  ShareTree tree,
  List<String> path, {
  required List<ChainHandles> live,
}) async {
  final result = await tree.fs.openChain(tree.root, path);
  expect(result, isA<ChainOpened>());
  final chain = (result as ChainOpened).chain;
  live.add(chain);
  expect(await tree.fs.prepareChain(chain), isTrue);
  return chain;
}

Future<void> releaseAll(ShareTree tree, List<ChainHandles> live) async {
  for (final chain in live) {
    await tree.fs.releaseChain(chain, saved: false);
  }
  live.clear();
}

List<String> namesIn(String folder) => [
  for (final entity in Directory(folder).listSync())
    entity.uri.pathSegments.where((s) => s.isNotEmpty).last,
];

DestinationRequest requestFor(int id, List<String> path) =>
    DestinationRequest(rootId: hexId(id), path: path, newFolder: null);

void main() {
  group('B-1 the temp folder of a locked chain is never empty [SEG]', () {
    test('B-1 with the chain open the temp folder cannot become a junction '
        'and the temp file stays inside', () async {
      final tree = await shareTree();
      final live = <ChainHandles>[];
      final chain = await preparedChain(tree, ['destino'], live: live);
      final incoming = chain.incomingPath!;
      expect(namesIn(incoming), hasLength(1));
      expect(namesIn(incoming).single, matches(witnessName));
      final full = turnIntoJunction(incoming, tree.outside);
      expect(full, isNot('ok'));
      expect(
        FileSystemEntity.typeSync(incoming, followLinks: false),
        FileSystemEntityType.directory,
      );
      final attributes = turnIntoJunction(
        incoming,
        tree.outside,
        access: writeAttributesOnly,
      );
      expect(attributes, isNot('ok'));
      expect(
        FileSystemEntity.typeSync(incoming, followLinks: false),
        FileSystemEntityType.directory,
      );
      expect(turnIntoJunction(tree.child('otra'), tree.outside), 'ok');
      File('$incoming\\~nexusbridges-0123456789ab.tmp').writeAsStringSync('x');
      expect(tree.outsideNames(), ['centinela']);
      final moved = await tree.fs.recheckAndMove(
        chain,
        tempName: '~nexusbridges-0123456789ab.tmp',
        isFolder: false,
        name: 'informe.txt',
      );
      expect(moved, isA<MovedTo>());
      expect(tree.outsideNames(), ['centinela']);
      await tree.fs.releaseChain(chain, saved: true);
      live.clear();
      expect(File(tree.child('destino\\informe.txt')).readAsStringSync(), 'x');
      expect(Directory(incoming).existsSync(), isFalse);
      expect(renames(tree.child('destino'), tree.child('destino2')), isTrue);
    });

    test('B-1 each lease has its own witness and the temp folder goes away '
        'with the last one', () async {
      final tree = await shareTree();
      final live = <ChainHandles>[];
      final first = await preparedChain(tree, ['destino'], live: live);
      final second = await preparedChain(tree, ['destino'], live: live);
      final incoming = first.incomingPath!;
      expect(namesIn(incoming), hasLength(2));
      expect(namesIn(incoming), everyElement(matches(witnessName)));
      await tree.fs.releaseChain(first, saved: false);
      live.remove(first);
      expect(namesIn(incoming), hasLength(1));
      expect(turnIntoJunction(incoming, tree.outside), isNot('ok'));
      await tree.fs.releaseChain(second, saved: false);
      live.remove(second);
      expect(Directory(incoming).existsSync(), isFalse);
      expect(tree.outsideNames(), ['centinela']);
    });

    test('B-1 the witness file is deleted when its handle closes and a '
        'second one cannot open the same name', () async {
      final tree = await shareTree();
      final opened = openFolderByPathSync(tree.child('destino'), lock: true);
      final folder = (opened as FolderOpened).handle;
      try {
        final witness = createWitnessFileSync(folder, 'testigo.hold');
        expect(witness, isNotNull);
        expect(File(tree.child('destino\\testigo.hold')).existsSync(), isTrue);
        expect(createWitnessFileSync(folder, 'testigo.hold'), isNull);
        expect(createWitnessFileSync(folder, r'a\b'), isNull);
        expect(createWitnessFileSync(folder, 'a:b'), isNull);
        closeHandleSync(witness!);
        expect(File(tree.child('destino\\testigo.hold')).existsSync(), isFalse);
      } finally {
        closeHandleSync(folder);
      }
    });
  });

  group('B-3 the rules of G2 are repeated on the root [SEG]', () {
    test('B-3 a root recorded as the data folder, a folder inside it, the '
        'Windows folder, the system drive root or the temp folder grants '
        'nothing', () async {
      final tree = await shareTree();
      Directory('${tree.base}\\data\\identity').createSync();
      final bad = [
        recordFor('${tree.base}\\data', id: 20),
        recordFor('${tree.base}\\data\\identity', id: 21),
        recordFor('${tree.base}\\sys\\windows', id: 22),
        recordFor('${tree.base}\\sys\\root', id: 23),
        recordFor('${tree.docs}\\$tempFolderName', id: 24),
        recordFor('${tree.base}\\sys\\pf', id: 25),
      ];
      for (final record in bad) {
        expect(
          await tree.fs.openChain(record, const []),
          isA<ChainUnavailable>(),
          reason: record.path,
        );
        expect(
          await tree.fs.listFolders(
            record,
            const [],
            cap: Limits.browseEnumerationCap,
            max: Limits.maxBrowseEntries,
          ),
          isA<FolderUnavailable>(),
          reason: record.path,
        );
      }
      final zero = await tree.fs.levelZero(
        [tree.root, ...bad],
        [(tree.root, const []), for (final record in bad) (record, const [])],
        budget: Limits.shareCheckTimeout,
      );
      expect(zero.available, [true, ...List.filled(bad.length, false)]);
      expect(zero.checks, [true, ...List.filled(bad.length, false)]);
      await zero.exited;
      final good = await tree.fs.openChain(tree.root, const []);
      expect(good, isA<ChainOpened>());
      await tree.fs.releaseChain((good as ChainOpened).chain, saved: false);
    });

    test('B-3 a root that contains the data folder stays usable and the data '
        'folder stays out', () async {
      final tree = await shareTree();
      final baseRoot = recordFor(tree.base, id: 26);
      final zero = await tree.fs.levelZero(
        [baseRoot],
        [
          (baseRoot, const ['docs']),
          (baseRoot, const ['data']),
        ],
        budget: Limits.shareCheckTimeout,
      );
      expect(zero.available, [true]);
      expect(zero.checks, [true, false]);
      await zero.exited;
    });

    test('B-3 when the forbidden folders cannot be loaded, even the root is '
        'refused', () async {
      final tree = await shareTree();
      final sys = '${tree.base}\\sys';
      final failing = TransferPlatform(
        SystemFolders(
          downloads: '$sys\\downloads',
          startup: '${tree.docs}\\Inicio',
          startMenu: '$sys\\startmenu',
          windows: '$sys\\windows',
          programFiles: '$sys\\pf',
          systemDriveRoot: '$sys\\root',
        ),
      )..systemError = StateError('no system folders');
      final fs = WindowsShareFileSystem(
        platform: failing,
        dataDirs: ['${tree.base}\\data'],
      );
      expect(await fs.openChain(tree.root, const []), isA<ChainUnavailable>());
      expect(
        await fs.listFolders(
          tree.root,
          const [],
          cap: Limits.browseEnumerationCap,
          max: Limits.maxBrowseEntries,
        ),
        isA<FolderUnavailable>(),
      );
      final zero = await fs.levelZero(
        [tree.root],
        [(tree.root, const [])],
        budget: Limits.shareCheckTimeout,
      );
      expect(zero.available, [false]);
      expect(zero.checks, [false]);
    });

    test('B-3 a shares.json written by hand with those roots grants '
        'nothing', () async {
      final place = await admissionPlace(open: false);
      Directory('${place.base}\\data\\identity').createSync(recursive: true);
      final good = place.folder('bueno');
      final store = SharesStore(
        JsonFileStore(place.sharesFile),
        ownerFingerprint: owner.fingerprint,
      );
      expect(
        await store.write({
          mine.fingerprint: [
            recordFor(place.dataDir, id: 1, label: 'data'),
            recordFor('${place.base}\\sys\\windows', id: 2, label: 'windows'),
            recordFor(good, id: 3, label: 'bueno'),
          ],
        }),
        isTrue,
      );
      expect(await place.open(), SharesLoadResult.loaded);
      await place.service.refreshAvailability(mine.fingerprint);
      expect(place.service.viewsFor(mine.fingerprint).map((v) => v.available), [
        false,
        false,
        true,
      ]);
      for (final id in [1, 2]) {
        final refused = await place.service.resolve(
          mine.fingerprint,
          requestFor(id, const []),
          timeout: Limits.shareCheckTimeout,
        );
        expect(refused, isA<SharedRefused>(), reason: 'root $id');
      }
      final allowed = await place.service.resolve(
        mine.fingerprint,
        requestFor(3, const []),
        timeout: Limits.shareCheckTimeout,
      );
      expect(allowed, isA<SharedResolved>());
      await (allowed as SharedResolved).lease.release(saved: false);
    });
  });

  group('B-2 a path component that is a file is a missing one [SEG]', () {
    test('B-2 openChain gives ChainMissing for a file in path, like for '
        'nothing, and the levelZero check says false for both', () async {
      final tree = await shareTree();
      File(tree.child('sub\\archivo')).writeAsStringSync('x');
      for (final path in [
        ['suelto.txt'],
        ['nada.txt'],
        ['sub', 'archivo'],
        ['sub', 'nada'],
        ['suelto.txt', 'dentro'],
      ]) {
        expect(
          await tree.fs.openChain(tree.root, path),
          isA<ChainMissing>(),
          reason: '$path',
        );
      }
      for (final path in [
        ['Oculta'],
        ['union'],
        ['CON'],
      ]) {
        expect(
          await tree.fs.openChain(tree.root, path),
          isA<ChainUnavailable>(),
          reason: '$path',
        );
      }
      final zero = await tree.fs.levelZero(const [], [
        (tree.root, ['suelto.txt']),
        (tree.root, ['nada.txt']),
      ], budget: Limits.shareCheckTimeout);
      expect(zero.checks, [false, false]);
      await zero.exited;
      final fileAsNew = await tree.fs.openChain(
        tree.root,
        const [],
        newFolder: 'suelto.txt',
      );
      expect(fileAsNew, isA<ChainUnavailable>());
      expect(File(tree.child('suelto.txt')).readAsStringSync(), 'archivo');
    });
  });

  group('B-4 G8 is repeated after each wait of the move retries [SEG]', () {
    test('B-4 a folder of the chain marked hidden while the move waits for a '
        'busy temp file gives DestinationChanged and nothing lands', () async {
      final tree = await shareTree();
      final live = <ChainHandles>[];
      addTearDown(() => releaseAll(tree, live));
      Directory(tree.child('sub\\hija')).createSync();
      final chain = await preparedChain(tree, ['sub', 'hija'], live: live);
      const temp = '~nexusbridges-0123456789ab.tmp';
      final path = '${chain.incomingPath}\\$temp';
      File(path).writeAsStringSync('x');
      final holder = File(path).openSync(mode: FileMode.append);
      addTearDown(() {
        try {
          holder.closeSync();
        } on FileSystemException {
          return;
        }
      });
      addTearDown(() {
        Process.runSync('attrib', [
          '-h',
          tree.child('sub'),
        ], workingDirectory: Directory.systemTemp.path);
      });
      final moving = tree.fs.recheckAndMove(
        chain,
        tempName: temp,
        isFolder: false,
        name: 'informe.txt',
      );
      await Future<void>.delayed(const Duration(milliseconds: 100));
      attrib('+h', tree.child('sub'));
      await Future<void>.delayed(const Duration(milliseconds: 400));
      holder.closeSync();
      expect(await moving, isA<DestinationChanged>());
      expect(File(tree.child('sub\\hija\\informe.txt')).existsSync(), isFalse);
      expect(File(path).existsSync(), isTrue);
    });

    test('B-4 a busy temp file that comes free without any change is still '
        'moved', () async {
      final tree = await shareTree();
      final live = <ChainHandles>[];
      addTearDown(() => releaseAll(tree, live));
      final chain = await preparedChain(tree, ['sub'], live: live);
      const temp = '~nexusbridges-0123456789ab.tmp';
      final path = '${chain.incomingPath}\\$temp';
      File(path).writeAsStringSync('x');
      final holder = File(path).openSync(mode: FileMode.append);
      addTearDown(() {
        try {
          holder.closeSync();
        } on FileSystemException {
          return;
        }
      });
      final moving = tree.fs.recheckAndMove(
        chain,
        tempName: temp,
        isFolder: false,
        name: 'informe.txt',
      );
      await Future<void>.delayed(const Duration(milliseconds: 150));
      holder.closeSync();
      expect(await moving, isA<MovedTo>());
      expect(File(tree.child('sub\\informe.txt')).readAsStringSync(), 'x');
    });
  });
}
