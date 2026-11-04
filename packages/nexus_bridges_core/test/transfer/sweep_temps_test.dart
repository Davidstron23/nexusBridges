@TestOn('windows')
library;

import 'dart:io';

import 'package:nexus_bridges_core/src/storage/storage.dart';
import 'package:nexus_bridges_core/src/transfer/folders.dart';
import 'package:nexus_bridges_core/src/transfer/journal.dart';
import 'package:nexus_bridges_core/src/transfer/transfer.dart'
    show ReceiveFolder;
import 'package:test/test.dart';

import 'folders_fakes.dart';

const ForbiddenFolders noneForbidden = ForbiddenFolders(trees: [], exact: []);

Future<File> writeText(String path, String text) async {
  final file = File(path);
  await file.writeAsString(text, flush: true);
  return file;
}

void main() {
  late String root;
  late String folder;
  late String sub;

  setUp(() async {
    root = await tempFolder();
    folder = await makeDir(join(root, 'Recibidos'));
    sub = join(folder, tempFolderName);
  });

  group('sweepTemps deletes only its own temps (E27, RF-235)', () {
    test('two own temps go; the user file, the folder with a temp name and '
        'the temp outside the subfolder stay', () async {
      await makeDir(sub);
      await writeText(join(sub, ownTemp(hexA)), 'parcial a');
      await writeText(join(sub, ownTemp(hexB)), 'parcial b');
      final userFile = await writeText(
        join(sub, '~nexusbridges-foo.partial'),
        'del usuario',
      );
      final folderWithTempName = await makeDir(join(sub, ownTemp(hexC)));
      final outside = await writeText(join(folder, ownTemp(hexA)), 'fuera');

      final clean = await sweepTemps(folder, windowsFs);

      expect(clean, isFalse);
      expect(await Directory(sub).exists(), isTrue);
      expect(
        namesIn(sub),
        unorderedEquals(['~nexusbridges-foo.partial', ownTemp(hexC)]),
      );
      expect(await userFile.readAsString(), 'del usuario');
      expect(await Directory(folderWithTempName).exists(), isTrue);
      expect(await outside.readAsString(), 'fuera');
    });

    test('it does not go into subfolders', () async {
      await makeDir(sub);
      final nested = await makeDir(join(sub, 'nested'));
      final deep = await writeText(join(nested, ownTemp(hexA)), 'profundo');

      expect(await sweepTemps(folder, windowsFs), isFalse);
      expect(await deep.readAsString(), 'profundo');
    });

    test('it does not follow a junction inside the subfolder, even one '
        'with a temp name', () async {
      await makeDir(sub);
      final elsewhere = await makeDir(join(root, 'Elsewhere'));
      final target = await writeText(join(elsewhere, ownTemp(hexA)), 'ajeno');
      await makeJunction(join(sub, ownTemp(hexB)), elsewhere);

      await sweepTemps(folder, windowsFs);

      expect(await target.readAsString(), 'ajeno');
      expect(namesIn(elsewhere), [ownTemp(hexA)]);
    });

    test('a temp subfolder that is a junction is not touched', () async {
      final elsewhere = await makeDir(join(root, 'Elsewhere'));
      final target = await writeText(join(elsewhere, ownTemp(hexA)), 'ajeno');
      await makeJunction(sub, elsewhere);

      expect(await sweepTemps(folder, windowsFs), isFalse);
      expect(await target.readAsString(), 'ajeno');
      expect(namesIn(elsewhere), [ownTemp(hexA)]);
    });

    test('a file named like the temp subfolder is not touched', () async {
      final blocker = await writeText(sub, 'del usuario');

      expect(await sweepTemps(folder, windowsFs), isFalse);
      expect(await blocker.readAsString(), 'del usuario');
    });

    test('a temp subfolder whose real path is elsewhere is not '
        'touched', () async {
      await makeDir(sub);
      final temp = await writeText(join(sub, ownTemp(hexA)), 'parcial');
      final fs = FakePlatform(
        adjustRealPath: (path, real) =>
            samePath(path, sub) ? join(root, 'Elsewhere') : real,
      );

      expect(await sweepTemps(folder, fs), isFalse);
      expect(await temp.readAsString(), 'parcial');
    });

    test('temps in keep stay, compared without case', () async {
      await makeDir(sub);
      final active = await writeText(join(sub, ownTemp(hexA)), 'activo');
      await writeText(join(sub, ownTemp(hexB)), 'viejo');

      final clean = await sweepTemps(
        folder,
        windowsFs,
        keep: {active.path.toUpperCase()},
      );

      expect(clean, isFalse);
      expect(namesIn(sub), [ownTemp(hexA)]);
      expect(await active.readAsString(), 'activo');
    });

    test('a temp it cannot delete is skipped without throwing and the rest '
        'are deleted', () async {
      await makeDir(sub);
      final busy = await writeText(join(sub, ownTemp(hexA)), 'en uso');
      await writeText(join(sub, ownTemp(hexB)), 'viejo');
      final handle = await busy.open(mode: FileMode.append);
      addTearDown(handle.close);

      final clean = await sweepTemps(folder, windowsFs);

      expect(clean, isFalse);
      expect(namesIn(sub), [ownTemp(hexA)]);
    });

    test('without a temp subfolder it is already clean', () async {
      expect(await sweepTemps(folder, windowsFs), isTrue);
      expect(namesIn(folder), isEmpty);
    });

    test('a folder that does not exist counts as clean and is not '
        'created', () async {
      final missing = join(root, 'Missing');

      expect(await sweepTemps(missing, windowsFs), isTrue);
      expect(await Directory(missing).exists(), isFalse);
    });
  });

  group('sweepTemps removes the empty subfolder (E28, RF-231)', () {
    test('with only its own temps the subfolder disappears', () async {
      await makeDir(sub);
      await writeText(join(sub, ownTemp(hexA)), 'a');
      await writeText(join(sub, ownTemp(hexB)), 'b');

      expect(await sweepTemps(folder, windowsFs), isTrue);
      expect(await Directory(sub).exists(), isFalse);
      expect(namesIn(folder), isEmpty);
    });

    test('an empty subfolder disappears too', () async {
      await makeDir(sub);

      expect(await sweepTemps(folder, windowsFs), isTrue);
      expect(await Directory(sub).exists(), isFalse);
    });
  });

  group('journal folder renamed and restored (E27, RF-187, RF-234)', () {
    test('while the folder is missing the entry stays; when it is back it '
        'is cleaned and leaves the journal', () async {
      await makeDir(sub);
      final temp = join(sub, ownTemp(hexA));
      await writeText(temp, 'restos');
      final volume = (await windowsFs.volumeFacts(folder))!.volumeId;
      final store = JsonFileStore(File(join(root, 'cleanup.json')));
      final journal = TempJournal(store);
      await journal.add(ReceiveFolder(path: folder, volumeId: volume));

      Future<void> cleanupAtStart() async {
        final restarted = TempJournal(store);
        await restarted.load();
        for (final entry in [...restarted.folders]) {
          final result = await inspectFolder(
            entry.path,
            fs: windowsFs,
            forbidden: noneForbidden,
            mayCreate: false,
            expectedVolume: entry.volumeId,
          );
          if (result is FolderUsable &&
              await sweepTemps(result.target.path, windowsFs)) {
            await restarted.remove(entry.path);
          }
        }
      }

      final renamed = join(root, 'Renombrada');
      await Directory(folder).rename(renamed);

      await cleanupAtStart();

      final whileAway = TempJournal(store);
      await whileAway.load();
      expect(whileAway.folders.map((f) => f.path), [folder]);
      expect(await Directory(folder).exists(), isFalse);
      expect(
        await File(join(join(renamed, tempFolderName), ownTemp(hexA))).exists(),
        isTrue,
      );

      await Directory(renamed).rename(folder);

      await cleanupAtStart();

      final afterReturn = TempJournal(store);
      await afterReturn.load();
      expect(afterReturn.folders, isEmpty);
      expect(await File(temp).exists(), isFalse);
      expect(await Directory(sub).exists(), isFalse);
    });
  });

  group('sweepTemps at the long-path limit (Q-1, G11)', () {
    Future<String> folderOfLength(int length) async {
      var current = root;
      while (current.length + 1 < length) {
        final room = length - current.length - 1;
        final segment = room > 50 ? 50 : room;
        current = '$current\\${'a' * segment}';
        await Directory('\\\\?\\$current').create();
      }
      expect(current.length, length);
      addTearDown(() async {
        await Process.run('cmd', ['/c', 'rmdir', '/s', '/q', '\\\\?\\$root']);
      });
      return current;
    }

    String extended(String path) => '\\\\?\\$path';

    for (final length in [234, 235, 236]) {
      test('a folder of $length characters has its own temps swept and the '
          'subfolder removed', () async {
        final long = await folderOfLength(length);
        final longSub = join(long, tempFolderName);
        await Directory(extended(longSub)).create();
        final partial = join(longSub, ownTemp(hexA));
        final hold = join(longSub, '~nexusbridges-0123456789abcdef.hold');
        final tree = join(longSub, '~nexusbridges-0123456789ab');
        await File(extended(partial)).writeAsString('parcial');
        await File(extended(hold)).writeAsString('');
        await Directory(extended(tree)).create();
        await File(extended(join(tree, 'dentro.txt'))).writeAsString('x');

        final clean = await sweepTemps(long, windowsFs);

        expect(clean, isTrue);
        expect(await File(extended(partial)).exists(), isFalse);
        expect(await File(extended(hold)).exists(), isFalse);
        expect(await Directory(extended(tree)).exists(), isFalse);
        expect(await Directory(extended(longSub)).exists(), isFalse);
      });

      test('a folder of $length characters keeps what is not its own and '
          'is not clean', () async {
        final long = await folderOfLength(length);
        final longSub = join(long, tempFolderName);
        await Directory(extended(longSub)).create();
        final partial = join(longSub, ownTemp(hexA));
        final foreign = join(longSub, 'ajeno.txt');
        await File(extended(partial)).writeAsString('parcial');
        await File(extended(foreign)).writeAsString('del usuario');

        final clean = await sweepTemps(long, windowsFs);

        expect(clean, isFalse);
        expect(await File(extended(partial)).exists(), isFalse);
        expect(await File(extended(foreign)).readAsString(), 'del usuario');
      });

      test('a folder of $length characters keeps a temp that is in keep and '
          'hands a temp folder to deferTree with its plain path', () async {
        final long = await folderOfLength(length);
        final longSub = join(long, tempFolderName);
        await Directory(extended(longSub)).create();
        final active = join(longSub, ownTemp(hexA));
        final tree = join(longSub, '~nexusbridges-0123456789ab');
        await File(extended(active)).writeAsString('activo');
        await Directory(extended(tree)).create();
        final deferred = <String>[];

        final clean = await sweepTemps(
          long,
          windowsFs,
          keep: {active.toUpperCase()},
          deferTree: deferred.add,
        );

        expect(clean, isFalse);
        expect(await File(extended(active)).readAsString(), 'activo');
        expect(deferred, [tree]);
        expect(await Directory(extended(tree)).exists(), isTrue);
      });
    }
  });
}
