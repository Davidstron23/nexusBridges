import 'package:nexus_bridges_core/src/browse/browse.dart';
import 'package:nexus_bridges_core/src/browse/messages.dart'
    show BrowseRequest, FoldersRequest, RootsRequest;
import 'package:nexus_bridges_core/src/protocol/protocol.dart';
import 'package:nexus_bridges_core/src/transfer/transfer.dart'
    show
        ForbiddenFolders,
        RelativePathProblem,
        checkRelativePath,
        isValidFolderName;
import 'package:nexus_bridges_core/src/winio/winio.dart'
    show DirectoryBatches, RawEntry;
import 'package:test/test.dart';

const int _directory = 0x10;
const int _hidden = 0x02;
const int _system = 0x04;
const int _reparse = 0x400;

RawEntry folder(String name, {int extra = 0, int? tag}) => RawEntry(
  name: name,
  attributes: _directory | extra | (tag == null ? 0 : _reparse),
  reparseTag: tag,
  size: 0,
);

RawEntry file(String name) =>
    RawEntry(name: name, attributes: 0x20, reparseTag: null, size: 10);

const ForbiddenFolders noForbidden = ForbiddenFolders(trees: [], exact: []);

final class ListBatches implements DirectoryBatches {
  ListBatches(this.batches, {this.onNext});

  final List<List<RawEntry>> batches;
  final void Function()? onNext;
  int served = 0;
  bool closed = false;

  @override
  List<RawEntry>? next() {
    onNext?.call();
    if (served >= batches.length) return null;
    return batches[served++];
  }

  @override
  void close() => closed = true;
}

Map<String, Object?> rootJson(
  String id, {
  String name = 'docs',
  bool home = false,
  bool available = true,
}) => {'id': id, 'name': name, 'home': home, 'available': available};

String hexId(int n) => n.toRadixString(16).padLeft(32, '0');

void main() {
  group('G1 checkRelativePath (RF-411) [SEG]', () {
    RelativePathProblem? check(
      List<String> path, {
      String? newFolder,
      int units = 10,
    }) => checkRelativePath(path, newFolder: newFolder, rootPathUnits: units);

    test('G1 a path of plain names is valid', () {
      expect(check(['mods', '2024']), isNull);
      expect(check([]), isNull);
      expect(check(['mods'], newFolder: 'nueva'), isNull);
    });

    test('G1 traversal, separators, drives and device paths are invalid', () {
      final traps = <List<String>>[
        ['..'],
        ['.'],
        [''],
        ['a', '', 'b'],
        [r'a\..\..\Windows'],
        ['a', '..', '..', 'Windows'],
        [r'C:\Windows'],
        ['C:'],
        [r'\\host\share'],
        [r'\\?\C:\'],
        [r'\\.\C:'],
        ['a/b'],
        ['a:b'],
        [r'a\b'],
        ['a\u{0}b'],
        ['a\u{1}b'],
        ['a\u{9F}b'],
        ['a*'],
        ['a?'],
        ['a"'],
        ['a<'],
        ['a>'],
        ['a|'],
      ];
      for (final trap in traps) {
        expect(
          check(trap),
          RelativePathProblem.invalidName,
          reason: trap.map((s) => s.codeUnits).toString(),
        );
      }
    });

    test('G1 reserved, trailing dot or space, bidi and app names are '
        'invalid', () {
      final traps = [
        'CON',
        'con.txt',
        'COM\u{B9}',
        'LPT\u{B2}',
        'NUL',
        'x.',
        'x ',
        'a\u{202E}gpj.exe',
        'desktop.ini',
        'x.{3050f4d8-98B5-11CF-BB82-00AA00BDCE0B}',
        '.nexusbridges-incoming',
        '~nexusbridges-abc',
        'a\u{D800}b',
      ];
      for (final trap in traps) {
        expect(
          check(['ok', trap]),
          RelativePathProblem.invalidName,
          reason: trap.codeUnits.toString(),
        );
        expect(
          check(['ok'], newFolder: trap),
          RelativePathProblem.invalidName,
          reason: 'newFolder ${trap.codeUnits}',
        );
      }
    });

    test('G1 depth: 32 levels pass and 33 are tooDeep, the new folder '
        'counts', () {
      final levels32 = List.filled(32, 'a');
      expect(check(levels32), isNull);
      expect(check(List.filled(33, 'a')), RelativePathProblem.tooDeep);
      expect(check(levels32, newFolder: 'b'), RelativePathProblem.tooDeep);
      expect(check(List.filled(31, 'a'), newFolder: 'b'), isNull);
    });

    test('G1 length: 236 units exactly pass and 237 are tooLong', () {
      expect(check(['abc'], units: 232), isNull);
      expect(check(['abc'], units: 233), RelativePathProblem.tooLong);
      expect(check(['ab'], newFolder: 'c', units: 231), isNull);
      expect(
        check(['ab'], newFolder: 'c', units: 232),
        RelativePathProblem.tooLong,
      );
    });

    test('G1 isValidFolderName: limits and good names', () {
      expect(isValidFolderName(''), isFalse);
      expect(isValidFolderName('a' * 256), isFalse);
      expect(isValidFolderName('a' * 255), isTrue);
      for (final good in [
        'mods',
        'Proyecto (1)',
        'canción',
        'familia \u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467}',
        '.git',
      ]) {
        expect(isValidFolderName(good), isTrue, reason: good);
      }
    });
  });

  group('E708 folderKey (punto 19)', () {
    test('E708 keeps the length and only folds single-unit uppercase', () {
      for (final name in ['stra\u{DF}e', '\u{FB01}le', '\u{1F600}x', 'a']) {
        expect(folderKey(name).length, name.length, reason: name);
      }
      expect(folderKey('stra\u{DF}e'), 'STRA\u{DF}E');
      expect(folderKey('\u{FB01}'), '\u{FB01}');
      expect(folderKey('a'), 'A');
      expect(folderKey('\u{1F600}'), '\u{1F600}');
    });

    test('E708 straße and STRASSE differ, Mods and mods match', () {
      expect(folderKey('stra\u{DF}e'), isNot(folderKey('STRASSE')));
      expect(folderKey('Mods'), folderKey('mods'));
      expect(folderKey('Año'), folderKey('AÑO'));
    });
  });

  group('G5 FolderCollector (RF-409, RF-410, RF-412)', () {
    FolderCollector collector({
      int max = 1000,
      ForbiddenFolders forbidden = noForbidden,
    }) => FolderCollector(
      max: max,
      parentFinalPath: r'C:\root\docs',
      forbidden: forbidden,
    );

    test('G5 only plain visible folders with valid names are kept', () {
      final c = collector()
        ..add([
          folder('sub'),
          folder('otra'),
          file('suelto.txt'),
          file('acceso.lnk'),
          file('desktop.ini'),
          folder('oculta', extra: _hidden),
          folder('sistema', extra: _system),
          folder('.git', extra: _hidden),
          folder('union', tag: 0xA0000003),
          folder('enlace', tag: 0xA000000C),
          folder('CON'),
          folder('x.'),
          folder('x '),
          folder('desktop.ini'),
          folder('.nexusbridges-incoming'),
          folder('~nexusbridges-0123456789ab'),
          folder('a\u{202E}b'),
        ]);
      final result = c.finish();
      expect(result.names, ['otra', 'sub']);
      expect(result.more, isFalse);
    });

    test('E724 a cloud placeholder tag (0x9000001A) is listed', () {
      final c = collector()..add([folder('nube', tag: 0x9000001A)]);
      expect(c.finish().names, ['nube']);
    });

    test('G5 forbidden folders below the parent are not listed', () {
      final c = collector(
        forbidden: const ForbiddenFolders(
          trees: [r'C:\root\docs\Inicio'],
          exact: [r'c:\ROOT\docs\exacta'],
        ),
      )..add([folder('Inicio'), folder('exacta'), folder('libre')]);
      expect(c.finish().names, ['libre']);
    });

    test('G5 sorted by folderKey then by name, one name per key', () {
      final c = collector()
        ..add([
          folder('beta'),
          folder('Alpha'),
          folder('alpha'),
          folder('STRASSE'),
          folder('stra\u{DF}e'),
          folder('Gamma'),
        ]);
      final names = c.finish().names;
      expect(names, ['Alpha', 'beta', 'Gamma', 'STRASSE', 'stra\u{DF}e']);
    });

    test('G5 1001 folders give 1000 with more, 1000 exact give no more', () {
      final many = collector()
        ..add([for (var i = 0; i < 1001; i++) folder('f${1000 + i}')]);
      final cut = many.finish();
      expect(cut.names, hasLength(1000));
      expect(cut.more, isTrue);
      expect(cut.names.first, 'f1000');
      expect(cut.names.last, 'f1999');
      final exact = collector()
        ..add([for (var i = 0; i < 1000; i++) folder('f${1000 + i}')]);
      final whole = exact.finish();
      expect(whole.names, hasLength(1000));
      expect(whole.more, isFalse);
    });

    test('G5 trimming across batches keeps the smallest names', () {
      final c = collector(max: 3);
      for (var b = 9; b >= 0; b--) {
        c.add([folder('n$b'), folder('m$b')]);
      }
      final result = c.finish();
      expect(result.names, ['m0', 'm1', 'm2']);
      expect(result.more, isTrue);
    });
  });

  group('G5 enumerateFolders (RF-412)', () {
    test('E727 a clock that moves 1 s per batch cuts at 5 s with '
        'partial', () {
      var now = Duration.zero;
      final batches = ListBatches([
        for (var b = 0; b < 20; b++) [folder('b$b')],
      ]);
      final listed = enumerateFolders(
        batches: batches,
        collector: FolderCollector(
          max: 1000,
          parentFinalPath: r'C:\r',
          forbidden: noForbidden,
        ),
        clock: () {
          final t = now;
          now += const Duration(seconds: 1);
          return t;
        },
        cap: const Duration(seconds: 5),
      );
      expect(listed.partial, isTrue);
      expect(batches.served, lessThan(20));
      expect(listed.names.length, batches.served);
    });

    test('G5 every batch read with no cut gives partial false', () {
      final batches = ListBatches([
        [folder('a'), file('x')],
        [folder('b')],
      ]);
      final listed = enumerateFolders(
        batches: batches,
        collector: FolderCollector(
          max: 1000,
          parentFinalPath: r'C:\r',
          forbidden: noForbidden,
        ),
        clock: () => Duration.zero,
        cap: const Duration(seconds: 5),
      );
      expect(listed.names, ['a', 'b']);
      expect(listed.partial, isFalse);
      expect(listed.more, isFalse);
    });

    test('G5 the scan budget stops the walk with partial', () {
      final batches = ListBatches([
        for (var b = 0; b < 10; b++)
          [for (var i = 0; i < 10; i++) file('$b$i')],
      ]);
      final listed = enumerateFolders(
        batches: batches,
        collector: FolderCollector(
          max: 1000,
          parentFinalPath: r'C:\r',
          forbidden: noForbidden,
        ),
        clock: () => Duration.zero,
        cap: const Duration(seconds: 5),
        maxScan: 30,
      );
      expect(listed.partial, isTrue);
      expect(batches.served, 3);
    });

    test('E727 300 000 entries end in 1000 names with more', () {
      final batches = ListBatches([
        for (var b = 0; b < 300; b++)
          [for (var i = 0; i < 1000; i++) folder('n${b * 1000 + i}')],
      ]);
      final listed = enumerateFolders(
        batches: batches,
        collector: FolderCollector(
          max: 1000,
          parentFinalPath: r'C:\r',
          forbidden: noForbidden,
        ),
        clock: () => Duration.zero,
        cap: const Duration(seconds: 5),
        maxScan: 400000,
      );
      expect(listed.names, hasLength(1000));
      expect(listed.more, isTrue);
      expect(listed.partial, isFalse);
    });
  });

  group('G9 SlidingWindowLimiter (RF-412)', () {
    test('G9 20 requests in 10 s pass, the 21st is refused and one more '
        'passes at 10 s', () {
      var now = const Duration(hours: 1);
      final limiter = SlidingWindowLimiter(
        limit: Limits.browseRequestsPerWindow,
        window: Limits.browseWindow,
        clock: () => now,
      );
      for (var i = 0; i < 20; i++) {
        expect(limiter.tryAcquire('A'), isTrue, reason: 'request $i');
        now += const Duration(milliseconds: 100);
      }
      expect(limiter.tryAcquire('A'), isFalse);
      now = const Duration(hours: 1) + const Duration(milliseconds: 9999);
      expect(limiter.tryAcquire('A'), isFalse);
      now = const Duration(hours: 1, seconds: 10);
      expect(limiter.tryAcquire('A'), isTrue);
      expect(limiter.tryAcquire('A'), isFalse);
    });

    test('G9 every fingerprint has its own window and forget clears it', () {
      final now = Duration.zero;
      final limiter = SlidingWindowLimiter(
        limit: 2,
        window: const Duration(seconds: 10),
        clock: () => now,
      );
      expect(limiter.tryAcquire('A'), isTrue);
      expect(limiter.tryAcquire('A'), isTrue);
      expect(limiter.tryAcquire('A'), isFalse);
      expect(limiter.tryAcquire('B'), isTrue);
      limiter.forget('A');
      expect(limiter.tryAcquire('A'), isTrue);
    });
  });

  group('G5 visibleRootNames and parentLabelOf (RF-409, punto 8)', () {
    test('E706 parentLabelOf gives the parent name or the drive letter', () {
      expect(parentLabelOf(r'C:\personal\dev', profilePath: null), 'personal');
      expect(parentLabelOf(r'D:\dev', profilePath: null), 'D:');
      expect(parentLabelOf(r'd:\dev\', profilePath: null), 'D:');
      expect(parentLabelOf(r'E:\', profilePath: null), 'E:');
    });

    test('E709 the profile folder is never the qualifier', () {
      const profile = r'C:\Users\Bob';
      expect(parentLabelOf(r'C:\Users\Bob\dev', profilePath: profile), 'C:');
      expect(parentLabelOf(r'c:\users\bob\Bob', profilePath: profile), 'C:');
      expect(
        parentLabelOf(r'C:\Users\Bob\proyectos\dev', profilePath: profile),
        'proyectos',
      );
    });

    test('E706 repeated labels get the parent, unique ones stay', () {
      final names = visibleRootNames([
        (label: 'dev', home: false, parentLabel: 'personal'),
        (label: 'Dev', home: false, parentLabel: 'proyectos'),
        (label: 'docs', home: false, parentLabel: 'x'),
      ]);
      expect(names, ['dev (personal)', 'Dev (proyectos)', 'docs']);
    });

    test('E706 three dev with the same parent are numbered by order', () {
      final names = visibleRootNames([
        (label: 'dev', home: false, parentLabel: 'x'),
        (label: 'dev', home: false, parentLabel: 'x'),
        (label: 'dev', home: false, parentLabel: 'x'),
      ]);
      expect(names, ['dev (x)', 'dev (x 2)', 'dev (x 3)']);
    });

    test('E709 the home root has an empty name and is never grouped', () {
      final names = visibleRootNames([
        (label: '', home: true, parentLabel: 'C:'),
        (label: 'dev', home: false, parentLabel: 'C:'),
        (label: 'dev', home: false, parentLabel: 'D:'),
      ]);
      expect(names, ['', 'dev (C:)', 'dev (D:)']);
    });

    test('E706 isValidRootLabel accepts the forms it builds', () {
      for (final good in [
        'dev',
        'D:',
        'dev (personal)',
        'dev (D:)',
        'dev (x 2)',
        'dev (D: 3)',
        'Documentos',
      ]) {
        expect(isValidRootLabel(good), isTrue, reason: good);
      }
      for (final bad in ['', 'a\u{202E}b', 'a' * 521, 'CON', '..']) {
        expect(
          isValidRootLabel(bad),
          isFalse,
          reason: bad.codeUnits.take(8).toString(),
        );
      }
    });
  });

  group('G10 parseRootsResponse (RF-425)', () {
    test('G10 a valid answer is read with its checks', () {
      final parsed = parseRootsResponse({
        'roots': [
          rootJson(hexId(1)),
          rootJson(hexId(2), name: '', home: true, available: false),
        ],
        'checks': [true, false],
      }, checks: 2);
      expect(parsed, isNotNull);
      expect(parsed!.roots, [
        RemoteRoot(id: hexId(1), name: 'docs', home: false, available: true),
        RemoteRoot(id: hexId(2), name: '', home: true, available: false),
      ]);
      expect(parsed.checks, [true, false]);
      expect(parseRootsResponse({'roots': <Object?>[]}, checks: 0), isNotNull);
    });

    test('E704 every malformed roots answer is discarded whole', () {
      final bad = <(Object?, int)>[
        (null, 0),
        ('roots', 0),
        ({'roots': <Object?>[], 'path': 'C:'}, 0),
        (<String, Object?>{}, 0),
        ({'roots': <Object?>[]}, 1),
        ({'roots': <Object?>[], 'checks': <Object?>[]}, 0),
        (
          {
            'roots': <Object?>[],
            'checks': [true],
          },
          2,
        ),
        (
          {
            'roots': <Object?>[],
            'checks': ['yes'],
          },
          1,
        ),
        (
          {
            'roots': [
              for (var i = 0; i < 17; i++) rootJson(hexId(i), name: 'r$i'),
            ],
          },
          0,
        ),
        (
          {
            'roots': [rootJson(hexId(1)), rootJson(hexId(1), name: 'b')],
          },
          0,
        ),
        (
          {
            'roots': [rootJson(hexId(1)), rootJson(hexId(2), name: 'DOCS')],
          },
          0,
        ),
        (
          {
            'roots': [rootJson(hexId(1), name: 'x', home: true)],
          },
          0,
        ),
        (
          {
            'roots': [rootJson(hexId(1), name: '')],
          },
          0,
        ),
        (
          {
            'roots': [
              rootJson(hexId(1), name: '', home: true),
              rootJson(hexId(2), name: '', home: true),
            ],
          },
          0,
        ),
        (
          {
            'roots': [rootJson(hexId(1), name: 'a\u{202E}b')],
          },
          0,
        ),
        (
          {
            'roots': [rootJson(hexId(1), name: '..')],
          },
          0,
        ),
        (
          {
            'roots': [rootJson('ABCDEF0123456789ABCDEF0123456789')],
          },
          0,
        ),
        (
          {
            'roots': [
              {...rootJson(hexId(1)), 'path': r'C:\docs'},
            ],
          },
          0,
        ),
        (
          {
            'roots': [
              {'id': hexId(1), 'name': 'docs', 'home': false},
            ],
          },
          0,
        ),
        (
          {
            'roots': [
              {...rootJson(hexId(1)), 'available': 'yes'},
            ],
          },
          0,
        ),
      ];
      for (final (json, checks) in bad) {
        expect(
          parseRootsResponse(json, checks: checks),
          isNull,
          reason: '$json',
        );
      }
    });

    test('E704 straße and STRASSE are two different roots', () {
      final parsed = parseRootsResponse({
        'roots': [
          rootJson(hexId(1), name: 'stra\u{DF}e'),
          rootJson(hexId(2), name: 'STRASSE'),
        ],
      }, checks: 0);
      expect(parsed?.roots, hasLength(2));
    });
  });

  group('G10 parseFoldersResponse (RF-425)', () {
    Map<String, Object?> body(List<Object?> folders) => {
      'folders': folders,
      'more': false,
      'partial': false,
    };

    test('G10 a valid listing is read', () {
      final parsed = parseFoldersResponse({
        'folders': ['otra', 'sub'],
        'more': true,
        'partial': false,
      });
      expect(parsed?.names, ['otra', 'sub']);
      expect(parsed?.more, isTrue);
      expect(parsed?.partial, isFalse);
      expect(
        parseFoldersResponse(body([for (var i = 0; i < 1000; i++) 'f$i'])),
        isNotNull,
      );
    });

    test('E704 every malformed listing is discarded whole', () {
      final bad = <Object?>[
        null,
        body([for (var i = 0; i < 1001; i++) 'f$i']),
        body(['..']),
        body(['ok', 'a\u{202E}b']),
        body(['Mods', 'mods']),
        body(['CON']),
        body(['']),
        body([1]),
        {
          ...body(['a']),
          'path': r'C:\docs',
        },
        {
          'folders': ['a'],
          'more': false,
        },
        {
          'folders': ['a'],
          'more': 'no',
          'partial': false,
        },
        {'folders': 'a', 'more': false, 'partial': false},
      ];
      for (final json in bad) {
        expect(parseFoldersResponse(json), isNull, reason: '$json');
      }
    });

    test('E704 straße and STRASSE in the same listing are accepted', () {
      expect(
        parseFoldersResponse(body(['stra\u{DF}e', 'STRASSE']))?.names,
        hasLength(2),
      );
    });
  });

  group('G9 BrowseRequest formats 1 and 2', () {
    test('G9 the three valid forms are read', () {
      expect(BrowseRequest.tryParse({'protocol': '1.2'}), isA<RootsRequest>());
      final checked = BrowseRequest.tryParse({
        'protocol': '1.9',
        'check': [
          {
            'root': hexId(1),
            'path': ['a'],
          },
        ],
      });
      expect(checked, isA<RootsRequest>());
      expect((checked! as RootsRequest).checks.single.path, ['a']);
      final folders = BrowseRequest.tryParse({
        'protocol': '1.2',
        'root': hexId(3),
        'path': <Object?>[],
      });
      expect(folders, isA<FoldersRequest>());
      expect((folders! as FoldersRequest).rootId, hexId(3));
    });

    test('G9 structure errors are refused, name validity is left to G1', () {
      final bad = <Object?>[
        null,
        <String, Object?>{},
        {'protocol': '2.0'},
        {'protocol': 12},
        {'protocol': '1.2', 'extra': 1},
        {'protocol': '1.2', 'check': <Object?>[]},
        {
          'protocol': '1.2',
          'check': [
            for (var i = 0; i < 17; i++)
              {'root': hexId(i), 'path': <Object?>[]},
          ],
        },
        {
          'protocol': '1.2',
          'check': [
            {'root': hexId(1)},
          ],
        },
        {'protocol': '1.2', 'root': 'C:', 'path': <Object?>[]},
        {'protocol': '1.2', 'root': hexId(1), 'path': 'a'},
        {
          'protocol': '1.2',
          'root': hexId(1),
          'path': [''],
        },
        {
          'protocol': '1.2',
          'root': hexId(1),
          'path': ['a' * 1025],
        },
        {'protocol': '1.2', 'root': hexId(1), 'path': List.filled(65, 'a')},
        {'protocol': '1.2', 'root': hexId(1)},
        {'protocol': '1.2', 'root': hexId(1), 'path': <Object?>[], 'x': 1},
      ];
      for (final json in bad) {
        expect(BrowseRequest.tryParse(json), isNull, reason: '$json');
      }
      expect(
        BrowseRequest.tryParse({
          'protocol': '1.2',
          'root': hexId(1),
          'path': ['..', 'CON'],
        }),
        isA<FoldersRequest>(),
      );
    });
  });
}
