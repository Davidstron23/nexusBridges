import 'dart:io';

import 'package:nexus_bridges_core/src/protocol/protocol.dart';
import 'package:nexus_bridges_core/src/transfer/folder_walk.dart';
import 'package:nexus_bridges_core/src/transfer/transfer.dart';
import 'package:test/test.dart';

const int junctionTag = 0xA0000003;
const int symlinkTag = 0xA000000C;
const int wslLinkTag = 0xA000001D;
const int appAliasTag = 0x8000001B;
const int cloudTag = 0x9000701A;

ListedEntry file(String name, [int size = 1, int? tag]) =>
    ListedEntry(name: name, isDirectory: false, reparseTag: tag, size: size);

ListedEntry dir(String name, [int? tag]) =>
    ListedEntry(name: name, isDirectory: true, reparseTag: tag, size: 0);

final class FakeLister implements FolderLister {
  FakeLister(this.tree);

  final Map<String, List<ListedEntry>> tree;
  final List<String> listed = [];

  @override
  List<ListedEntry> list(String directoryPath) {
    listed.add(directoryPath);
    final entries = tree[directoryPath];
    if (entries == null) {
      throw const FileSystemException('The folder could not be listed');
    }
    return List<ListedEntry>.of(entries);
  }
}

const String root = r'C:\work\proj';
const String dataDir = r'C:\Users\u\AppData\Local\NexusBridges';

WalkResult walk(
  Map<String, List<ListedEntry>> tree, {
  Set<String> exclusions = const {},
  String rootPath = root,
  String data = dataDir,
  bool Function()? isCancelled,
}) => walkFolder(
  lister: FakeLister(tree),
  rootPath: rootPath,
  exclusions: exclusions,
  dataDirRealPath: data,
  isCancelled: isCancelled,
);

List<String> pathsOf(WalkResult result) {
  final manifest = result.builder.build();
  return [for (var i = 1; i <= manifest.length; i++) manifest.relativePath(i)];
}

void main() {
  group('E407, RF-256 and DP-6: which reparse tags are links', () {
    test('name surrogates and the app execution alias are links', () {
      expect(isLinkTag(0xA000000C), isTrue);
      expect(isLinkTag(0xA0000003), isTrue);
      expect(isLinkTag(0xA000001D), isTrue);
      expect(isLinkTag(0x8000001B), isTrue);
    });

    test('cloud, compression and deduplication tags are not links', () {
      expect(isLinkTag(0x9000001A), isFalse);
      expect(isLinkTag(0x9000601A), isFalse);
      expect(isLinkTag(0x80000017), isFalse);
      expect(isLinkTag(0x80000013), isFalse);
    });
  });

  group('E401, RF-253: exclusions in the walk', () {
    final tree = <String, List<ListedEntry>>{
      root: [
        dir('node_modules'),
        dir('src'),
        dir('node_modules_old'),
        file('build', 10),
        file('keep.txt', 5),
      ],
      '$root\\node_modules': [file('dep.js', 100)],
      '$root\\src': [dir('Node_Modules'), file('main.dart', 7)],
      '$root\\src\\Node_Modules': [file('inner.js', 40), dir('deep')],
      '$root\\src\\Node_Modules\\deep': [file('x.js', 2)],
      '$root\\node_modules_old': [file('old.js', 3)],
    };

    test('excluded folders are left out at any depth, without regard to case, '
        'and only the folders: a file called build travels, a folder '
        'sharing a prefix stays', () {
      final result = walk(tree, exclusions: {'NODE_MODULES', 'BUILD'});

      expect(result.stopped, isNull);
      expect(pathsOf(result), [
        'build',
        'keep.txt',
        'node_modules_old',
        'src',
        'node_modules_old\\old.js',
        'src\\main.dart',
      ]);
      expect(result.excludedFolders, 2);
      expect(result.excludedPaths, [
        '$root\\node_modules',
        '$root\\src\\Node_Modules',
      ]);
    });

    test('the size of the excluded folders is measured apart, with every '
        'nested file', () {
      final result = walk(tree, exclusions: {'NODE_MODULES'});

      final measure = measureFolders(
        lister: FakeLister(tree),
        roots: result.excludedPaths,
        elapsed: () => Duration.zero,
        isCancelled: () => false,
      );

      expect(measure.bytes, 100 + 40 + 2);
      expect(measure.partial, isFalse);
    });

    test('the chosen folder is sent whole even when its name is excluded', () {
      final result = walk(
        {
          r'C:\work\build': [file('a.txt', 4), dir('b')],
          r'C:\work\build\b': [file('c.txt', 6)],
        },
        exclusions: {'BUILD'},
        rootPath: r'C:\work\build',
      );

      expect(pathsOf(result), ['a.txt', 'b', 'b\\c.txt']);
      expect(result.excludedFolders, 0);
    });

    test('excluded folders count before anything inside them is listed', () {
      final lister = FakeLister(tree);

      walkFolder(
        lister: lister,
        rootPath: root,
        exclusions: {'NODE_MODULES'},
        dataDirRealPath: dataDir,
      );

      expect(lister.listed, isNot(contains('$root\\node_modules')));
      expect(lister.listed, isNot(contains('$root\\src\\Node_Modules')));
    });
  });

  group('DP-6: links by tag in the walk', () {
    test('links of every kind are counted and never listed', () {
      final lister = FakeLister({
        root: [
          dir('junction', junctionTag),
          dir('symlink', symlinkTag),
          file('filelink', 3, symlinkTag),
          dir('wsl', wslLinkTag),
          file('alias.exe', 0, appAliasTag),
          file('own.txt', 8),
        ],
      });

      final result = walkFolder(
        lister: lister,
        rootPath: root,
        exclusions: const {},
        dataDirRealPath: dataDir,
      );

      expect(result.linksOmitted, 5);
      expect(pathsOf(result), ['own.txt']);
      expect(lister.listed, [root]);
    });

    test('a folder and a file with a cloud tag are read like any other', () {
      final result = walk({
        root: [dir('Cloud', cloudTag), file('placeholder.txt', 900, cloudTag)],
        '$root\\Cloud': [file('inside.txt', 12)],
      });

      expect(result.linksOmitted, 0);
      expect(pathsOf(result), [
        'Cloud',
        'placeholder.txt',
        'Cloud\\inside.txt',
      ]);
    });
  });

  group('RF-257: protected data in the walk', () {
    test('the data folder is left out by its real path wherever it is '
        'reached, and the app reserved names too', () {
      final result = walk({
        root: [
          dir('data'),
          dir('.nexusbridges-incoming'),
          dir('.NexusBridges-Incoming'),
          dir('~nexusbridges-0123456789ab'),
          file('~nexusbridges-abc.partial', 9),
          file('ok.txt', 1),
        ],
        '$root\\data': [file('x', 1)],
      }, data: '$root\\data');

      expect(result.protectedOmitted, 5);
      expect(pathsOf(result), ['ok.txt']);
    });

    test('a folder next to the data folder with the same prefix stays', () {
      final result = walk({
        root: [dir('data'), dir('data-old')],
        '$root\\data': const [],
        '$root\\data-old': [file('f.txt', 1)],
      }, data: '$root\\data');

      expect(result.protectedOmitted, 1);
      expect(pathsOf(result), ['data-old', 'data-old\\f.txt']);
    });

    test('without a data folder nothing is protected by path', () {
      final result = walk({
        root: [dir('data')],
        '$root\\data': [file('f.txt', 1)],
      }, data: '');

      expect(result.protectedOmitted, 0);
      expect(pathsOf(result), ['data', 'data\\f.txt']);
    });

    test('protection comes before an exclusion with the same name', () {
      final result = walk(
        {
          root: [dir('build')],
        },
        exclusions: {'BUILD'},
        data: '$root\\build',
      );

      expect(result.protectedOmitted, 1);
      expect(result.excludedFolders, 0);
    });
  });

  group('RF-303 and P-1: blocked types in the walk', () {
    test('files and folders of a blocked type are left out and counted, '
        'with everything inside the folders', () {
      final result = walk({
        root: [
          file('desktop.ini', 1),
          dir('sub'),
          dir('x.{645FF040-5081-101B-9F08-00AA002F954E}'),
          dir('desktop.ini.d'),
          dir('algo.LNK'),
          file('fine.txt', 2),
        ],
        '$root\\sub': [file('enlace.LNK', 1), file('a.txt', 1)],
        '$root\\desktop.ini.d': [file('b.txt', 1)],
      });

      expect(result.blockedOmitted, 4);
      expect(pathsOf(result), [
        'desktop.ini.d',
        'fine.txt',
        'sub',
        'desktop.ini.d\\b.txt',
        'sub\\a.txt',
      ]);
    });
  });

  group('RF-261 and RF-266: names and siblings in the walk', () {
    test('an invalid file name stops the walk with its relative path', () {
      final result = walk({
        root: [dir('sub')],
        '$root\\sub': [file('x.', 1)],
      });

      expect(result.stopped, TransferOutcome.invalidName);
      expect(result.problemPath, 'sub\\x.');
    });

    test('an invalid folder name stops the walk before its content', () {
      final lister = FakeLister({
        root: [dir('bad ')],
        '$root\\bad ': [file('a', 1)],
      });

      final result = walkFolder(
        lister: lister,
        rootPath: root,
        exclusions: const {},
        dataDirRealPath: dataDir,
      );

      expect(result.stopped, TransferOutcome.invalidName);
      expect(result.problemPath, 'bad ');
      expect(lister.listed, [root]);
    });

    test('two siblings that differ only in case stop the walk with the path '
        'of the second', () {
      final result = walk({
        root: [file('a.txt', 1), file('A.TXT', 1)],
      });

      expect(result.stopped, TransferOutcome.invalidName);
      expect(result.problemPath, 'a.txt');
    });

    test('a file and a folder with the same name stop the walk', () {
      final result = walk({
        root: [file('src', 1), dir('SRC')],
      });

      expect(result.stopped, TransferOutcome.invalidName);
    });
  });

  group('RF-260: limits in the walk', () {
    test('sixty-four levels pass and the sixty-fifth stops with its path', () {
      Map<String, List<ListedEntry>> nested(int levels) {
        final tree = <String, List<ListedEntry>>{};
        var path = root;
        for (var i = 0; i < levels; i++) {
          tree[path] = [dir('d')];
          path = '$path\\d';
        }
        tree[path] = const [];
        return tree;
      }

      final ok = walk(nested(Limits.maxFolderDepth));
      expect(ok.stopped, isNull);
      expect(ok.builder.length, Limits.maxFolderDepth);

      final deep = walk(nested(Limits.maxFolderDepth + 1));
      expect(deep.stopped, TransferOutcome.tooDeep);
      expect(deep.problemPath, List.filled(65, 'd').join('\\'));
    });

    test('a file at depth sixty-five stops the walk', () {
      final tree = <String, List<ListedEntry>>{};
      var path = root;
      for (var i = 0; i < Limits.maxFolderDepth; i++) {
        tree[path] = [dir('d')];
        path = '$path\\d';
      }
      tree[path] = [file('f.txt', 1)];

      final result = walk(tree);

      expect(result.stopped, TransferOutcome.tooDeep);
    });

    test('exactly the maximum of entries passes and one more stops', () {
      Map<String, List<ListedEntry>> flat(int count) => {
        root: [for (var i = 0; i < count; i++) file('f$i.txt', 0)],
      };

      final ok = walk(flat(Limits.maxFolderEntries));
      expect(ok.stopped, isNull);
      expect(ok.builder.length, Limits.maxFolderEntries);

      final over = walk(flat(Limits.maxFolderEntries + 1));
      expect(over.stopped, TransferOutcome.tooManyEntries);
      expect(over.problemPath, isNull);
    });
  });

  group('RF-262 and DP-8: folders that cannot be listed', () {
    test('a subfolder that fails stops the walk with unreadable and its '
        'path', () {
      final result = walk({
        root: [dir('a'), dir('b')],
        '$root\\a': [file('f', 1)],
      });

      expect(result.stopped, TransferOutcome.unreadable);
      expect(result.problemPath, 'b');
    });

    test('the chosen folder failing stops without a path', () {
      final result = walk(const {});

      expect(result.stopped, TransferOutcome.unreadable);
      expect(result.problemPath, isNull);
    });
  });

  group('RF-258: cancellation in the walk', () {
    test('a raised flag stops the walk between folders', () {
      var calls = 0;
      final result = walk({
        root: [dir('a'), dir('b')],
        '$root\\a': const [],
        '$root\\b': const [],
      }, isCancelled: () => ++calls > 1);

      expect(result.cancelled, isTrue);
      expect(result.stopped, isNull);
    });
  });

  group('E589 and punto 19: measuring what was left out', () {
    final tree = <String, List<ListedEntry>>{
      r'C:\x\a': [file('f', 10), dir('sub'), dir('link', junctionTag)],
      r'C:\x\a\sub': [file('g', 20)],
      r'C:\x\a\link': [file('never', 999)],
      r'C:\x\b': [file('h', 5)],
    };

    test('sums every file below every root and skips links', () {
      final measure = measureFolders(
        lister: FakeLister(tree),
        roots: [r'C:\x\a', r'C:\x\b'],
        elapsed: () => Duration.zero,
        isCancelled: () => false,
      );

      expect(measure.bytes, 35);
      expect(measure.partial, isFalse);
    });

    test('a folder that cannot be listed makes the result partial', () {
      final measure = measureFolders(
        lister: FakeLister(tree),
        roots: [r'C:\x\a', r'C:\x\missing'],
        elapsed: () => Duration.zero,
        isCancelled: () => false,
      );

      expect(measure.bytes, 30);
      expect(measure.partial, isTrue);
    });

    test('the entry cap stops it and keeps what was counted', () {
      final measure = measureFolders(
        lister: FakeLister({
          r'C:\x\a': [for (var i = 0; i < 10; i++) file('f$i', 1)],
        }),
        roots: [r'C:\x\a'],
        elapsed: () => Duration.zero,
        isCancelled: () => false,
        maxEntries: 4,
      );

      expect(measure.bytes, 4);
      expect(measure.partial, isTrue);
    });

    test('the time cap stops it between folders', () {
      var now = Duration.zero;
      final lister = FakeLister(tree);
      final measure = measureFolders(
        lister: _AdvancingLister(
          lister,
          () => now += const Duration(seconds: 6),
        ),
        roots: [r'C:\x\a', r'C:\x\b'],
        elapsed: () => now,
        isCancelled: () => false,
      );

      expect(measure.partial, isTrue);
      expect(lister.listed.length, lessThan(4));
    });

    test('cancelling stops it at once', () {
      final lister = FakeLister(tree);
      final measure = measureFolders(
        lister: lister,
        roots: [r'C:\x\a'],
        elapsed: () => Duration.zero,
        isCancelled: () => true,
      );

      expect(measure.partial, isTrue);
      expect(measure.bytes, 0);
      expect(lister.listed, isEmpty);
    });
  });
}

final class _AdvancingLister implements FolderLister {
  _AdvancingLister(this.inner, this.onList);

  final FolderLister inner;
  final void Function() onList;

  @override
  List<ListedEntry> list(String directoryPath) {
    onList();
    return inner.list(directoryPath);
  }
}
