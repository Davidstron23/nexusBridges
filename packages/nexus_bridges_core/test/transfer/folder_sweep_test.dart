@TestOn('windows')
library;

import 'dart:io';

import 'package:nexus_bridges_core/src/transfer/folders.dart';
import 'package:test/test.dart';

import 'folders_fakes.dart' hide join;

const String folderA = '~nexusbridges-0123456789ab';
const String folderB = '~nexusbridges-fedcba987654';
const String folderC = '~nexusbridges-aaaaaaaaaaaa';

Future<void> fill(String folder) async {
  await makeDir(folder);
  await makeDir(j(folder, 'inner'));
  await makeDir(j(folder, 'empty'));
  await File(j(folder, 'one.txt')).writeAsString('1');
  await File(j(folder, 'inner', 'two.txt')).writeAsString('2');
}

String j(String a, [String? b, String? c, String? d]) =>
    [a, ?b, ?c, ?d].join(r'\');

void main() {
  late String root;
  late String folder;
  late String sub;

  setUp(() async {
    root = await tempFolder('nexus_t6_sweep_');
    folder = await makeDir(j(root, 'Recibidos'));
    sub = j(folder, tempFolderName);
    await makeDir(sub);
  });

  group('names of the folder temps', () {
    test('only twelve lower-case hex digits after the prefix are ours', () {
      expect(isOwnFolderTempName(folderA), isTrue);
      expect(isOwnFolderTempName(folderB), isTrue);
      for (final name in [
        '~nexusbridges-0123456789a',
        '~nexusbridges-0123456789abc',
        '~nexusbridges-0123456789AB',
        '~NEXUSBRIDGES-0123456789ab',
        '~nexusbridges-0123456789ag',
        'nexusbridges-0123456789ab',
        '~nexusbridges-0123456789ab.partial',
        '~nexusbridges-0123456789ab ',
        '',
      ]) {
        expect(isOwnFolderTempName(name), isFalse, reason: name);
      }
    });

    test('a new name is ours, has the prefix and is not repeated', () {
      final names = {for (var i = 0; i < 200; i++) newFolderTempName()};

      expect(names, hasLength(200));
      expect(names.every(isOwnFolderTempName), isTrue);
      expect(names.every((name) => name.startsWith(tempPrefix)), isTrue);
    });
  });

  group('sweepTemps and the folder temps (F8, Q-9)', () {
    test('a leftover hidden folder temp with files, empty folders and a '
        'read-only file is deleted whole', () async {
      await fill(j(sub, folderA));
      await windowsFs.setHidden(j(sub, folderA));
      Process.runSync('attrib', ['+R', j(sub, folderA, 'one.txt')]);

      final clean = await sweepTemps(folder, windowsFs);

      expect(clean, isTrue);
      expect(Directory(sub).existsSync(), isFalse);
      expect(Directory(folder).existsSync(), isTrue);
    });

    test(
      'file temps and folder temps go together and the rest stays',
      () async {
        await fill(j(sub, folderA));
        await File(j(sub, ownTemp(hexA))).writeAsString('parcial');
        await fill(j(sub, 'mine'));
        await fill(j(sub, '~nexusbridges-0123456789a'));
        await fill(j(sub, '~nexusbridges-0123456789ABCD'));
        await File(j(sub, '~nexusbridges-foo.partial')).writeAsString('x');

        final clean = await sweepTemps(folder, windowsFs);

        expect(clean, isFalse);
        expect(
          namesIn(sub),
          unorderedEquals([
            'mine',
            '~nexusbridges-0123456789a',
            '~nexusbridges-0123456789ABCD',
            '~nexusbridges-foo.partial',
          ]),
        );
        expect(File(j(sub, 'mine', 'inner', 'two.txt')).existsSync(), isTrue);
      },
    );

    test('a folder temp that is in use is kept with everything inside, the '
        'other ones go', () async {
      await fill(j(sub, folderA));
      await fill(j(sub, folderB));

      final clean = await sweepTemps(
        folder,
        windowsFs,
        keep: {j(sub, folderA.toUpperCase())},
      );

      expect(clean, isFalse);
      expect(namesIn(sub), [folderA]);
      expect(File(j(sub, folderA, 'inner', 'two.txt')).existsSync(), isTrue);
    });

    test('a junction with the pattern name is removed as a link and its '
        'target stays untouched', () async {
      final target = await makeDir(j(root, 'precious'));
      await File(j(target, 'keep.txt')).writeAsString('keep');
      await makeDir(j(target, 'sub'));
      await File(j(target, 'sub', 'deep.txt')).writeAsString('deep');
      await makeJunction(j(sub, folderA), target);

      final clean = await sweepTemps(folder, windowsFs);

      expect(clean, isTrue);
      expect(
        FileSystemEntity.typeSync(j(sub, folderA)),
        FileSystemEntityType.notFound,
      );
      expect(File(j(target, 'keep.txt')).readAsStringSync(), 'keep');
      expect(File(j(target, 'sub', 'deep.txt')).readAsStringSync(), 'deep');
    });

    test(
      'a junction inside a folder temp is removed without entering it',
      () async {
        final target = await makeDir(j(root, 'precious'));
        await File(j(target, 'keep.txt')).writeAsString('keep');
        await fill(j(sub, folderC));
        await makeJunction(j(sub, folderC, 'door'), target);

        final clean = await sweepTemps(folder, windowsFs);

        expect(clean, isTrue);
        expect(File(j(target, 'keep.txt')).readAsStringSync(), 'keep');
        expect(Directory(sub).existsSync(), isFalse);
      },
    );

    test('a file with a folder temp name is not touched and a folder with a '
        'file temp name is not touched', () async {
      await File(j(sub, folderA)).writeAsString('file');
      await makeDir(j(sub, ownTemp(hexA)));

      final clean = await sweepTemps(folder, windowsFs);

      expect(clean, isFalse);
      expect(namesIn(sub), unorderedEquals([folderA, ownTemp(hexA)]));
    });

    test(
      'Q-1: with deferTree the folder temps are handed over and not '
      'deleted, while files and links are still removed on the spot',
      () async {
        await fill(j(sub, folderA));
        await fill(j(sub, folderB));
        await fill(j(sub, folderC));
        await File(j(sub, ownTemp(hexA))).writeAsString('partial');
        final handed = <String>[];

        final clean = await sweepTemps(
          folder,
          windowsFs,
          keep: {j(sub, folderC)},
          deferTree: handed.add,
        );

        expect(clean, isFalse);
        expect(handed, unorderedEquals([j(sub, folderA), j(sub, folderB)]));
        expect(namesIn(sub), unorderedEquals([folderA, folderB, folderC]));
        expect(File(j(sub, folderA, 'one.txt')).existsSync(), isTrue);
      },
    );

    test(
      'Q-1: deferTree is not called when there is nothing to delete',
      () async {
        var calls = 0;

        final clean = await sweepTemps(
          folder,
          windowsFs,
          deferTree: (_) => calls++,
        );

        expect(clean, isTrue);
        expect(calls, 0);
        expect(Directory(sub).existsSync(), isFalse);
      },
    );
  });

  group('FileSystemPlatform.deleteTree', () {
    test('it deletes a whole tree, a missing path counts as deleted and a '
        'junction is only unlinked', () async {
      final tree = j(root, 'tree');
      await fill(tree);
      final target = await makeDir(j(root, 'precious'));
      await File(j(target, 'keep.txt')).writeAsString('keep');
      await makeJunction(j(tree, 'door'), target);

      expect(await windowsFs.deleteTree(tree), isTrue);
      expect(Directory(tree).existsSync(), isFalse);
      expect(File(j(target, 'keep.txt')).existsSync(), isTrue);
      expect(await windowsFs.deleteTree(tree), isTrue);
      expect(await windowsFs.deleteTree(j(root, 'never', 'was')), isTrue);
    });

    test('a path that is a junction is unlinked and never followed', () async {
      final target = await makeDir(j(root, 'precious'));
      await File(j(target, 'keep.txt')).writeAsString('keep');
      final link = await makeJunction(j(root, 'link'), target);

      expect(await windowsFs.deleteTree(link), isTrue);

      expect(Directory(link).existsSync(), isFalse);
      expect(File(j(target, 'keep.txt')).readAsStringSync(), 'keep');
    });
  });
}
