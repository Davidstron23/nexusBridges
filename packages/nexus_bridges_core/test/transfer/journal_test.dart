import 'dart:convert';
import 'dart:io';

import 'package:nexus_bridges_core/src/storage/storage.dart';
import 'package:nexus_bridges_core/src/transfer/journal.dart';
import 'package:nexus_bridges_core/src/transfer/transfer.dart'
    show ReceiveFolder;
import 'package:test/test.dart';

const String folderA = r'D:\Recibidos';
const String folderB = r'E:\Fotos';
const String volumeA = 'exFAT-0f00ba11';
const String volumeB = 'NTFS-1a2b3c4d';

List<(String, String)> entriesOf(TempJournal journal) => [
  for (final f in journal.folders) (f.path, f.volumeId),
];

void main() {
  late Directory dataDir;
  late File journalFile;
  late List<String> logs;

  setUp(() async {
    dataDir = await Directory.systemTemp.createTemp('nexus_t3_journal_');
    addTearDown(() => dataDir.delete(recursive: true));
    journalFile = File('${dataDir.path}${Platform.pathSeparator}cleanup.json');
    logs = [];
  });

  TempJournal journalAt(File file) =>
      TempJournal(JsonFileStore(file), log: logs.add);

  Future<Map<String, Object?>> fileJson() async =>
      jsonDecode(await journalFile.readAsString()) as Map<String, Object?>;

  List<String> namesInData() =>
      dataDir
          .listSync()
          .map((e) => e.path.substring(e.path.lastIndexOf(r'\') + 1))
          .toList()
        ..sort();

  group('TempJournal writes (RF-187, RF-234, D16)', () {
    test(
      'add keeps the folder in memory at once and writes version 1',
      () async {
        final journal = journalAt(journalFile);

        final pending = journal.add(
          const ReceiveFolder(path: folderA, volumeId: volumeA),
        );
        expect(entriesOf(journal), [(folderA, volumeA)]);
        await pending;

        expect(await fileJson(), {
          'version': 1,
          'folders': [
            {'path': folderA, 'volume': volumeA},
          ],
        });
      },
    );

    test('a new journal loaded from the file sees the same folders', () async {
      final journal = journalAt(journalFile);
      await journal.add(const ReceiveFolder(path: folderA, volumeId: volumeA));
      await journal.add(const ReceiveFolder(path: folderB, volumeId: volumeB));

      final reloaded = journalAt(journalFile);
      await reloaded.load();

      expect(entriesOf(reloaded), [(folderA, volumeA), (folderB, volumeB)]);
    });

    test('adding the same folder with the same volume, even with other case, '
        'does not write again', () async {
      final journal = journalAt(journalFile);
      await journal.add(const ReceiveFolder(path: folderA, volumeId: volumeA));
      await journalFile.delete();

      await journal.add(
        const ReceiveFolder(path: r'd:\RECIBIDOS\', volumeId: volumeA),
      );

      expect(await journalFile.exists(), isFalse);
      expect(entriesOf(journal), [(folderA, volumeA)]);
    });

    test('adding the same folder with another volume updates it in '
        'place', () async {
      final journal = journalAt(journalFile);
      await journal.add(const ReceiveFolder(path: folderA, volumeId: volumeA));
      await journal.add(const ReceiveFolder(path: folderB, volumeId: volumeB));

      await journal.add(
        const ReceiveFolder(path: r'd:\recibidos', volumeId: volumeB),
      );

      expect(entriesOf(journal), [
        (r'd:\recibidos', volumeB),
        (folderB, volumeB),
      ]);
      expect((await fileJson())['folders'], [
        {'path': r'd:\recibidos', 'volume': volumeB},
        {'path': folderB, 'volume': volumeB},
      ]);
    });

    test('it keeps at most 64 folders and the oldest leaves', () async {
      final journal = journalAt(journalFile);
      for (var i = 0; i < 65; i++) {
        await journal.add(ReceiveFolder(path: 'D:\\R$i', volumeId: volumeA));
      }

      expect(journal.folders.length, TempJournal.maxFolders);
      expect(TempJournal.maxFolders, 64);
      expect(journal.folders.first.path, r'D:\R1');
      expect(journal.folders.last.path, r'D:\R64');
      expect(((await fileJson())['folders'] as List).length, 64);
    });

    test('remove takes the folder out, without case, and writes', () async {
      final journal = journalAt(journalFile);
      await journal.add(const ReceiveFolder(path: folderA, volumeId: volumeA));
      await journal.add(const ReceiveFolder(path: folderB, volumeId: volumeB));

      final pending = journal.remove(r'd:/recibidos/');
      expect(entriesOf(journal), [(folderB, volumeB)]);
      await pending;

      expect((await fileJson())['folders'], [
        {'path': folderB, 'volume': volumeB},
      ]);
    });

    test('removing a folder that is not there does not write', () async {
      final journal = journalAt(journalFile);
      await journal.add(const ReceiveFolder(path: folderA, volumeId: volumeA));
      await journalFile.delete();

      await journal.remove(folderB);

      expect(await journalFile.exists(), isFalse);
      expect(entriesOf(journal), [(folderA, volumeA)]);
    });

    test('writes started together all land, in order', () async {
      final journal = journalAt(journalFile);

      await Future.wait([
        journal.add(const ReceiveFolder(path: folderA, volumeId: volumeA)),
        journal.add(const ReceiveFolder(path: folderB, volumeId: volumeB)),
        journal.remove(folderA),
      ]);

      expect((await fileJson())['folders'], [
        {'path': folderB, 'volume': volumeB},
      ]);
    });

    test('a write that fails is logged by type, does not throw and memory '
        'keeps the change (D16)', () async {
      final blocker = File('${dataDir.path}${Platform.pathSeparator}blocker');
      await blocker.writeAsString('soy un archivo');
      final journal = journalAt(
        File('${blocker.path}${Platform.pathSeparator}cleanup.json'),
      );

      await journal.add(const ReceiveFolder(path: folderA, volumeId: volumeA));
      await journal.remove(folderA);

      expect(journal.folders, isEmpty);
      expect(logs.length, 2);
      for (final line in logs) {
        expect(line, startsWith('cleanup journal write failed: '));
        expect(line, isNot(contains('Recibidos')));
        expect(line, isNot(contains(dataDir.path)));
      }
      expect(await blocker.readAsString(), 'soy un archivo');
    });
  });

  group('TempJournal.load', () {
    test('without a file it is empty and creates nothing', () async {
      final journal = journalAt(journalFile);

      await journal.load();

      expect(journal.folders, isEmpty);
      expect(namesInData(), isEmpty);
      expect(logs, isEmpty);
    });

    test('duplicates in the file keep the last one and more than 64 keep the '
        'newest', () async {
      await journalFile.writeAsString(
        jsonEncode({
          'version': 1,
          'folders': [
            {'path': folderA, 'volume': volumeA},
            for (var i = 0; i < 64; i++) {'path': 'D:\\R$i', 'volume': volumeA},
            {'path': r'd:\recibidos', 'volume': volumeB},
          ],
        }),
      );
      final journal = journalAt(journalFile);

      await journal.load();

      expect(journal.folders.length, 64);
      expect(journal.folders.first.path, r'D:\R1');
      expect(entriesOf(journal).last, (r'd:\recibidos', volumeB));
    });

    final broken = <String, String>{
      'broken JSON': '{"version":1,"folders":[',
      'a JSON array': '[]',
      'version 2': '{"version":2,"folders":[]}',
      'no version': '{"folders":[]}',
      'folders not a list': '{"version":1,"folders":{}}',
      'no folders key': '{"version":1}',
      'an entry that is not an object': '{"version":1,"folders":["D:\\\\R"]}',
      'an entry with a number as path':
          '{"version":1,"folders":[{"path":5,"volume":"$volumeA"}]}',
      'an entry with an empty path':
          '{"version":1,"folders":[{"path":"","volume":"$volumeA"}]}',
      'an entry with an empty volume':
          '{"version":1,"folders":[{"path":"D:\\\\R","volume":""}]}',
      'an entry with a null volume':
          '{"version":1,"folders":[{"path":"D:\\\\R","volume":null}]}',
      'an entry with an extra key':
          '{"version":1,"folders":[{"path":"D:\\\\R","volume":"$volumeA",'
          '"x":1}]}',
      'an entry without volume': '{"version":1,"folders":[{"path":"D:\\\\R"}]}',
    };

    for (final MapEntry(key: label, value: content) in broken.entries) {
      test('$label is quarantined and loads empty', () async {
        await journalFile.writeAsString(content);
        final journal = journalAt(journalFile);

        await journal.load();

        expect(journal.folders, isEmpty);
        expect(await journalFile.exists(), isFalse);
        final names = namesInData();
        expect(names.length, 1);
        expect(names.single, startsWith('cleanup.json.broken-'));
        expect(
          await File('${dataDir.path}${Platform.pathSeparator}${names.single}')
              .readAsString(),
          content,
        );
      });
    }

    test('a path longer than 32767 units is quarantined', () async {
      final longPath = 'D:\\${'a' * 32767}';
      await journalFile.writeAsString(
        jsonEncode({
          'version': 1,
          'folders': [
            {'path': longPath, 'volume': volumeA},
          ],
        }),
      );
      final journal = journalAt(journalFile);

      await journal.load();

      expect(journal.folders, isEmpty);
      expect(await journalFile.exists(), isFalse);
    });

    test('a file it cannot read loads empty, is logged by type and is not '
        'quarantined', () async {
      await journalFile.writeAsString(
        jsonEncode({
          'version': 1,
          'folders': [
            {'path': folderA, 'volume': volumeA},
          ],
        }),
      );
      final handle = await journalFile.open(mode: FileMode.append);
      addTearDown(handle.close);
      await handle.lock(FileLock.exclusive);

      final journal = journalAt(journalFile);
      await journal.load();

      expect(journal.folders, isEmpty);
      expect(namesInData(), ['cleanup.json']);
      expect(logs, hasLength(1));
      expect(logs.single, startsWith('cleanup journal read failed: '));
      expect(logs.single, isNot(contains('Recibidos')));
    });

    test('the folders list cannot be changed from outside', () async {
      final journal = journalAt(journalFile);
      await journal.add(const ReceiveFolder(path: folderA, volumeId: volumeA));

      expect(
        () => journal.folders.add(
          const ReceiveFolder(path: folderB, volumeId: volumeB),
        ),
        throwsUnsupportedError,
      );
    });
  });
}
