import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:nexus_bridges_core/src/protocol/protocol.dart';
import 'package:nexus_bridges_core/src/transfer/manifest.dart';
import 'package:nexus_bridges_core/src/transfer/messages.dart';
import 'package:nexus_bridges_core/src/transfer/names.dart';
import 'package:nexus_bridges_core/src/transfer/transfer.dart';
import 'package:test/test.dart';

import 'folder_manifest_support.dart';

const ManifestRefusal incompatible = ManifestRefusal.incompatible;
const ManifestRefusal invalidName = ManifestRefusal.invalidName;
const ManifestRefusal blockedType = ManifestRefusal.blockedType;
const ManifestRefusal tooLarge = ManifestRefusal.tooLarge;

final String rlo = String.fromCharCode(0x202E);
final String zeroWidth = String.fromCharCode(0x200B);

void main() {
  group('the reader accepts a well formed manifest', () {
    test('it rebuilds the same tree, in any chunking', () {
      final (:manifest, :encoded) = sampleTree();
      final declared = declareFor(manifest, encoded);

      for (final sizes in <Iterable<int>?>[
        null,
        [1],
        [2, 3, 5],
        [7],
        [encoded.length - 1, 1],
      ]) {
        final result = readAll(encoded, declared, chunkSizes: sizes);
        expect(result.refusal, isNull, reason: '$sizes');
        final read = result.manifest!;
        expect(read.length, manifest.length);
        for (var i = 1; i <= read.length; i++) {
          expect(read.parentOf(i), manifest.parentOf(i));
          expect(read.nameOf(i), manifest.nameOf(i));
          expect(read.isFolder(i), manifest.isFolder(i));
          expect(read.sizeOf(i), manifest.sizeOf(i));
          expect(read.hashOf(i), manifest.hashOf(i));
          expect(read.relativePath(i), manifest.relativePath(i));
        }
        expect(encodeManifest(read), encoded);
      }
    });

    test('files, folders, totalBytes, depth and longest are computed', () {
      final (:manifest, encoded: _) = sampleTree();

      expect(manifest.length, 5);
      expect(manifest.files, 2);
      expect(manifest.folders, 3);
      expect(manifest.totalBytes, 12);
      expect(manifest.depth, 3);
      expect(manifest.longest, r'src\b'.length + Limits.folderDirPathReserve);
      expect(manifest.relativePath(5), r'src\b\c.txt');
      expect(manifest.depthOf(5), 3);
      expect(manifest.fileIndexes, [4, 5]);
    });

    test('longest takes a file when it is the longest path', () {
      final builder = ManifestBuilder();
      final folder = builder.addFolder(0, 'x');
      final file = builder.addFile(folder, 'a' * 30, 1);
      builder.setFile(file, 1, Uint8List(32));

      expect(builder.build().longest, 32);
    });

    test('an empty manifest is a folder with nothing inside', () {
      final declared = declare(
        entries: 0,
        manifestBytes: 0,
        files: 0,
        bytes: 0,
        depth: 0,
        longest: 0,
      );
      final reader = ManifestReader(declared);
      final result = reader.close();

      expect(result.refusal, isNull);
      expect(result.manifest!.length, 0);
      expect(result.manifest!.firstLevelCount, 0);
    });

    test('equal names under different parents are not a clash', () {
      final lines = [
        folderLine(0, 'a'),
        folderLine(0, 'b'),
        fileLine(1, 'same.txt', 1),
        fileLine(2, 'same.txt', 1),
      ];

      expect(addRefusal(lines), isNull);
    });

    test('a line of exactly 2048 bytes with its newline is accepted', () {
      final line = folderLine(0, 'a');
      final padded = line + ' ' * (2047 - line.length);
      final bytes = linesToBytes([padded]);
      expect(bytes.length, 2048);

      expect(addRefusal([padded]), isNull);
    });
  });

  group('E430, RF-264: names that could escape the folder', () {
    final escapes = [
      '..',
      '.',
      r'a\..\..\x',
      r'C:\x',
      'C:x',
      r'\x',
      r'\\equipo\c$\x',
      r'\\?\C:\x',
      r'a\\b',
      r'a\',
      r'.\a',
      'a/b',
      '../x',
    ];

    for (final name in escapes) {
      test('folder named "$name" is invalid', () {
        expect(addRefusal([folderLine(0, name)]), invalidName);
      });

      test('file named "$name" is invalid', () {
        expect(addRefusal([fileLine(0, name, 1)]), invalidName);
      });
    }

    test('the same names deep inside are invalid too', () {
      for (final name in escapes) {
        final lines = [
          folderLine(0, 'p'),
          folderLine(1, 'q'),
          fileLine(2, name, 1),
        ];
        expect(addRefusal(lines), invalidName, reason: name);
      }
    });

    test('a parent equal to the line index or greater is refused', () {
      expect(addRefusal([folderLine(1, 'a')]), incompatible);
      expect(addRefusal([folderLine(2, 'a')]), incompatible);
      expect(
        addRefusal([folderLine(0, 'a'), folderLine(2, 'b')]),
        incompatible,
      );
      expect(
        addRefusal([folderLine(0, 'a'), folderLine(99999, 'b')]),
        incompatible,
      );
    });

    test('a negative parent is refused', () {
      expect(addRefusal([folderLine(-1, 'a')]), incompatible);
    });

    test('a parent that is a file is refused', () {
      expect(
        addRefusal([fileLine(0, 'a', 1), folderLine(1, 'b')]),
        incompatible,
      );
      expect(
        addRefusal([fileLine(0, 'a', 1), fileLine(1, 'b', 1)]),
        incompatible,
      );
    });

    test('a line with a carriage return is refused', () {
      final bytes = Uint8List.fromList(utf8.encode('[0,"a"]\r\n'));
      final reader = ManifestReader(
        declare(entries: 1, manifestBytes: bytes.length),
      );

      expect(reader.add(bytes), incompatible);
    });

    test('an empty line is refused, first or in the middle', () {
      expect(addRefusal(['']), incompatible);
      expect(addRefusal([folderLine(0, 'a'), '']), incompatible);
      expect(
        addRefusal([folderLine(0, 'a'), '', folderLine(0, 'b')]),
        incompatible,
      );
    });

    test('a line of 2049 bytes with its newline is refused', () {
      final line = folderLine(0, 'a');
      final padded = line + ' ' * (2048 - line.length);
      expect(linesToBytes([padded]).length, 2049);

      expect(addRefusal([padded]), incompatible);
    });

    test(
      'a line without newline that passes 2048 bytes is refused at once',
      () {
        final bytes = Uint8List(4096)..fillRange(0, 4096, 0x20);
        final reader = ManifestReader(declare(entries: 1, manifestBytes: 4096));

        expect(reader.add(bytes), incompatible);
        expect(reader.add(Uint8List.fromList([10])), incompatible);
        expect(reader.close().refusal, incompatible);
      },
    );

    test('malformed UTF-8 is refused', () {
      for (final bad in [
        [0xC3, 0x28],
        [0xFF],
        [0xE2, 0x82],
        [0xC0, 0xAF],
        [0xED, 0xA0, 0x80],
      ]) {
        final bytes = Uint8List.fromList([
          ...utf8.encode('[0,"'),
          ...bad,
          ...utf8.encode('"]\n'),
        ]);
        final reader = ManifestReader(
          declare(entries: 1, manifestBytes: bytes.length),
        );

        expect(reader.add(bytes), incompatible, reason: '$bad');
      }
    });

    test('a byte order mark at the start of a line is refused', () {
      final bytes = Uint8List.fromList([
        0xEF,
        0xBB,
        0xBF,
        ...utf8.encode('[0,"a"]\n'),
      ]);
      final reader = ManifestReader(
        declare(entries: 1, manifestBytes: bytes.length),
      );

      expect(reader.add(bytes), incompatible);
    });

    test('bytes beyond the declared manifestBytes are refused', () {
      final bytes = linesToBytes([folderLine(0, 'a')]);
      final reader = ManifestReader(
        declare(entries: 1, manifestBytes: bytes.length - 1),
      );

      expect(reader.add(bytes), incompatible);
    });

    test('fewer bytes than declared are refused on close', () {
      final bytes = linesToBytes([folderLine(0, 'a')]);
      final reader = ManifestReader(
        declare(entries: 1, manifestBytes: bytes.length + 1, files: 0),
      );

      expect(reader.add(bytes), isNull);
      expect(reader.close().refusal, incompatible);
    });

    test('a last line without newline is refused on close', () {
      final bytes = Uint8List.fromList(utf8.encode('[0,"a"]'));
      final reader = ManifestReader(
        declare(entries: 1, manifestBytes: bytes.length, files: 0),
      );

      expect(reader.add(bytes), isNull);
      expect(reader.close().refusal, incompatible);
    });

    test('wrong shapes are refused', () {
      final shapes = [
        '{"a":1}',
        '"text"',
        '7',
        'null',
        '[]',
        '[0]',
        '[0,"a",1]',
        '[0,"a",1,"${'a' * 64}",1]',
        '["0","a"]',
        '[0.5,"a"]',
        '[0,7]',
        '[0,null]',
        '[0,"a",-1,"${'a' * 64}"]',
        '[0,"a",1.5,"${'a' * 64}"]',
        '[0,"a","1","${'a' * 64}"]',
        '[0,"a",${Limits.maxTransferSize + 1},"${'a' * 64}"]',
        '[0,"a",1,"${'A' * 64}"]',
        '[0,"a",1,"${'a' * 63}"]',
        '[0,"a",1,"${'a' * 65}"]',
        '[0,"a",1,"${'g' * 64}"]',
        '[0,"a",1,7]',
        '[0,"a"',
        '[0,"a"]]',
        'not json',
      ];
      for (final shape in shapes) {
        expect(addRefusal([shape]), incompatible, reason: shape);
      }
    });

    test('file sizes whose sum passes maxTransferSize are refused', () {
      final half = Limits.maxTransferSize ~/ 2 + 1;

      expect(
        addRefusal([fileLine(0, 'a', half), fileLine(0, 'b', half)]),
        incompatible,
      );
      expect(
        addRefusal([
          fileLine(0, 'a', Limits.maxTransferSize),
          fileLine(0, 'b', 1),
        ]),
        incompatible,
      );
      expect(addRefusal([fileLine(0, 'a', Limits.maxTransferSize)]), isNull);
    });

    test('after a refusal the reader keeps it and ignores the rest', () {
      final bytes = linesToBytes([folderLine(0, '..'), folderLine(0, 'ok')]);
      final reader = ManifestReader(
        declare(entries: 2, manifestBytes: bytes.length),
      );

      expect(reader.add(bytes), invalidName);
      expect(reader.add(linesToBytes([folderLine(0, 'z')])), invalidName);
      expect(reader.close().refusal, invalidName);
      expect(reader.close().manifest, isNull);
    });

    test('close refuses when the real counts differ from the offer', () {
      final (:manifest, :encoded) = sampleTree();
      final tweaks = <String, FolderManifestTweak>{
        'files': (m, e) => declare(
          entries: m.length,
          manifestBytes: e.length,
          files: m.files + 1,
          bytes: m.totalBytes,
          depth: m.depth,
          longest: m.longest,
        ),
        'bytes': (m, e) => declare(
          entries: m.length,
          manifestBytes: e.length,
          files: m.files,
          bytes: m.totalBytes + 1,
          depth: m.depth,
          longest: m.longest,
        ),
        'depth': (m, e) => declare(
          entries: m.length,
          manifestBytes: e.length,
          files: m.files,
          bytes: m.totalBytes,
          depth: m.depth - 1,
          longest: m.longest,
        ),
        'longest shorter': (m, e) => declare(
          entries: m.length,
          manifestBytes: e.length,
          files: m.files,
          bytes: m.totalBytes,
          depth: m.depth,
          longest: m.longest - 1,
        ),
        'longest longer': (m, e) => declare(
          entries: m.length,
          manifestBytes: e.length,
          files: m.files,
          bytes: m.totalBytes,
          depth: m.depth,
          longest: m.longest + 1,
        ),
        'entries': (m, e) => declare(
          entries: m.length + 1,
          manifestBytes: e.length,
          files: m.files,
          bytes: m.totalBytes,
          depth: m.depth,
          longest: m.longest,
        ),
      };
      for (final MapEntry(:key, :value) in tweaks.entries) {
        final result = readAll(encoded, value(manifest, encoded));
        expect(result.refusal, incompatible, reason: key);
        expect(result.manifest, isNull, reason: key);
      }
    });
  });

  group('E432, RF-265: names Windows does not allow', () {
    final invalid = <String, String>{
      'CON': 'CON',
      'con': 'con',
      'aux.c': 'aux.c',
      'COM1': 'COM1',
      'COM1.txt': 'COM1.txt',
      'COM\u00B9.txt': 'COM superscript one',
      'LPT\u00B2': 'LPT superscript two',
      'a:b': 'colon',
      'x.': 'trailing dot',
      'x ': 'trailing space',
      'a${rlo}b': 'right to left override',
      'a${zeroWidth}b': 'zero width space',
      'a\u0001b': 'C0 control',
      'a\u001Fb': 'C0 control 1F',
      'a\u0080b': 'C1 control 80',
      'a\u0085b': 'C1 control 85',
      'a\u009Fb': 'C1 control 9F',
      'a' * 256: '256 units',
      '': 'empty',
      'a<b': 'less than',
      'a|b': 'pipe',
      'a*b': 'star',
      'a?b': 'question mark',
      'a"b': 'quote',
    };

    for (final MapEntry(key: name, value: label) in invalid.entries) {
      test('$label at the first level, as folder and as file', () {
        expect(addRefusal([folderLine(0, name)]), invalidName);
        expect(addRefusal([fileLine(0, name, 1)]), invalidName);
      });

      test('$label at the third level, as folder and as file', () {
        final base = [folderLine(0, 'p'), folderLine(1, 'q')];
        expect(addRefusal([...base, folderLine(2, name)]), invalidName);
        expect(addRefusal([...base, fileLine(2, name, 1)]), invalidName);
      });
    }

    test('src plus aux.c reads as two names and the second is invalid', () {
      expect(
        addRefusal([folderLine(0, 'src'), fileLine(1, 'aux.c', 1)]),
        invalidName,
      );
      expect(
        addRefusal([folderLine(0, 'a'), fileLine(1, 'COM\u00B9.txt', 1)]),
        invalidName,
      );
    });

    test('256 units is invalid and 255 units is valid', () {
      expect(addRefusal([fileLine(0, 'a' * 255, 1)]), isNull);
      expect(addRefusal([fileLine(0, 'a' * 256, 1)]), invalidName);
    });

    test('the same names are invalid as the name of the offered folder', () {
      for (final name in invalid.keys) {
        expect(isValidFileName(name), isFalse, reason: label(name));
      }
    });
  });

  group('E433, RF-266: clashes without regard to case', () {
    test('a.txt and A.TXT in the same folder', () {
      expect(
        addRefusal([fileLine(0, 'a.txt', 1), fileLine(0, 'A.TXT', 1)]),
        invalidName,
      );
    });

    test('a file and a folder with the same name in different case', () {
      expect(
        addRefusal([fileLine(0, 'src', 1), folderLine(0, 'SRC')]),
        invalidName,
      );
      expect(
        addRefusal([folderLine(0, 'src'), fileLine(0, 'Src', 1)]),
        invalidName,
      );
    });

    test('the same folder twice', () {
      expect(
        addRefusal([folderLine(0, 'docs'), folderLine(0, 'DOCS')]),
        invalidName,
      );
    });

    test('the very same line twice', () {
      final line = fileLine(0, 'a.txt', 1);

      expect(addRefusal([line, line]), invalidName);
    });

    test('non ASCII letters clash by case too', () {
      expect(
        addRefusal([folderLine(0, '\u00E9'), folderLine(0, '\u00C9')]),
        invalidName,
      );
    });

    test('the clash is checked per folder, deep inside as well', () {
      final base = [folderLine(0, 'p'), folderLine(1, 'q')];

      expect(
        addRefusal([...base, fileLine(2, 'a.txt', 1), fileLine(2, 'A.txt', 1)]),
        invalidName,
      );
    });

    test('a file cannot be the parent of main.dart', () {
      expect(
        addRefusal([fileLine(0, 'src', 1), fileLine(1, 'main.dart', 1)]),
        incompatible,
      );
      expect(
        addRefusal([fileLine(0, 'src', 1), folderLine(1, 'main.dart')]),
        incompatible,
      );
    });
  });

  group('E434, RF-267: blocked types in files and folders', () {
    test('desktop.ini inside a folder', () {
      expect(
        addRefusal([folderLine(0, 'sub'), fileLine(1, 'desktop.ini', 1)]),
        blockedType,
      );
      expect(
        addRefusal([folderLine(0, 'sub'), fileLine(1, 'DESKTOP.INI', 1)]),
        blockedType,
      );
    });

    test('x.LNK at the third level', () {
      expect(
        addRefusal([
          folderLine(0, 'p'),
          folderLine(1, 'q'),
          fileLine(2, 'x.LNK', 1),
        ]),
        blockedType,
      );
    });

    test('a file with a class id segment', () {
      expect(
        addRefusal([
          fileLine(0, 'a.txt.{3050f4d8-98B5-11CF-BB82-00AA00BDCE0B}', 1),
        ]),
        blockedType,
      );
    });

    test('P-1: a folder with a class id segment, at any level', () {
      const name = 'x.{645FF040-5081-101B-9F08-00AA002F954E}';
      final base = [folderLine(0, 'p'), folderLine(1, 'q')];

      expect(addRefusal([folderLine(0, name)]), blockedType);
      expect(addRefusal([...base, folderLine(2, name)]), blockedType);
    });

    test('P-1: a folder named desktop.ini, at any level', () {
      final base = [folderLine(0, 'p'), folderLine(1, 'q')];

      expect(addRefusal([folderLine(0, 'desktop.ini')]), blockedType);
      expect(addRefusal([...base, folderLine(2, 'desktop.ini')]), blockedType);
    });

    test('P-1: a folder named algo.LNK, at any level', () {
      final base = [folderLine(0, 'p'), folderLine(1, 'q')];

      expect(addRefusal([folderLine(0, 'algo.LNK')]), blockedType);
      expect(addRefusal([...base, folderLine(2, 'algo.LNK')]), blockedType);
    });

    test('every blocked suffix is refused for files and folders', () {
      for (final suffix in [
        '.lnk',
        '.url',
        '.scf',
        '.library-ms',
        '.searchconnector-ms',
        '.pif',
        '.settingcontent-ms',
        '.search-ms',
      ]) {
        expect(
          addRefusal([fileLine(0, 'x$suffix', 1)]),
          blockedType,
          reason: suffix,
        );
        expect(
          addRefusal([folderLine(0, 'x$suffix')]),
          blockedType,
          reason: suffix,
        );
      }
    });

    test('similar but harmless names are accepted', () {
      expect(addRefusal([fileLine(0, 'link.txt', 1)]), isNull);
      expect(addRefusal([folderLine(0, 'lnk')]), isNull);
      expect(addRefusal([fileLine(0, 'desktop.ini.txt', 1)]), isNull);
      expect(addRefusal([fileLine(0, 'x.{not-a-guid}', 1)]), isNull);
    });
  });

  group('E435, RF-268: limits', () {
    test('an offer declaring 100 001 entries exceeds the limits', () {
      expect(
        declare(
          entries: Limits.maxFolderEntries + 1,
          manifestBytes: 1 << 20,
        ).exceedsLimits,
        isTrue,
      );
      expect(
        declare(
          entries: Limits.maxFolderEntries,
          manifestBytes: 1 << 20,
        ).exceedsLimits,
        isFalse,
      );
    });

    test('an offer with manifestBytes of 16 MiB + 1 exceeds the limits', () {
      expect(
        declare(
          entries: 10,
          manifestBytes: Limits.maxManifestBytes + 1,
        ).exceedsLimits,
        isTrue,
      );
      expect(
        declare(
          entries: 10,
          manifestBytes: Limits.maxManifestBytes,
        ).exceedsLimits,
        isFalse,
      );
    });

    test('an offer with depth 65 exceeds the limits', () {
      expect(
        declare(entries: 10, manifestBytes: 100, depth: 65).exceedsLimits,
        isTrue,
      );
      expect(
        declare(entries: 10, manifestBytes: 100, depth: 64).exceedsLimits,
        isFalse,
      );
    });

    test('declared 10 and 11 lines arrive: refused at line 11', () {
      final lines = [for (var i = 0; i < 11; i++) folderLine(0, 'f$i')];
      final bytes = linesToBytes(lines);
      final reader = ManifestReader(
        declare(entries: 10, manifestBytes: bytes.length),
      );
      final firstTen = linesToBytes(lines.take(10).toList());

      expect(reader.add(firstTen), isNull);
      expect(reader.add(linesToBytes([lines[10]])), incompatible);
    });

    test('the eleventh line is not even parsed', () {
      final lines = [
        for (var i = 0; i < 10; i++) folderLine(0, 'f$i'),
        '..not json, and not read..',
      ];
      final bytes = linesToBytes(lines);
      final reader = ManifestReader(
        declare(entries: 10, manifestBytes: bytes.length),
      );

      expect(reader.add(bytes), incompatible);
    });

    test('a depth of 64 is accepted and 65 is too large', () {
      List<String> chain(int count) => [
        for (var i = 0; i < count; i++) folderLine(i, 'd$i'),
      ];

      expect(addRefusal(chain(64)), isNull);
      expect(addRefusal(chain(65)), tooLarge);
      expect(addRefusal([...chain(64), fileLine(64, 'f.txt', 1)]), tooLarge);
    });

    test('more entries than maxFolderEntries are too large', () {
      final lines = [
        for (var i = 0; i < Limits.maxFolderEntries + 1; i++)
          folderLine(0, 'f$i'),
      ];
      final bytes = linesToBytes(lines);
      final reader = ManifestReader(
        declare(entries: lines.length, manifestBytes: bytes.length),
      );

      expect(reader.add(bytes), tooLarge);
    });

    test('exactly maxFolderEntries entries are read and counted', () {
      final lines = [
        for (var i = 0; i < Limits.maxFolderEntries; i++) folderLine(0, 'f$i'),
      ];
      final bytes = linesToBytes(lines);
      final reader = ManifestReader(
        declare(
          entries: lines.length,
          manifestBytes: bytes.length,
          files: 0,
          bytes: 0,
          depth: 1,
          longest: 'f99999'.length + Limits.folderDirPathReserve,
        ),
      );

      expect(reader.add(bytes), isNull);
      final result = reader.close();
      expect(result.refusal, isNull);
      expect(result.manifest!.length, Limits.maxFolderEntries);
      expect(result.manifest!.firstLevelCount, Limits.maxFolderEntries);
    });
  });

  group('E437, RF-271: first level', () {
    ManifestBuilder sevenChildren() {
      final builder = ManifestBuilder();
      builder.addFolder(0, 'banana');
      builder.addFile(0, 'Apple', 1);
      builder.addFile(0, 'cherry', 1);
      final date = builder.addFolder(0, 'Date');
      builder.addFile(0, 'apple2', 1);
      builder.addFile(0, 'Zed', 1);
      builder.addFolder(0, 'ELDER');
      builder.addFile(date, 'inside.txt', 1);
      return builder;
    }

    test('the first five, sorted without regard to case, and the count', () {
      final manifest = sevenChildren().build();

      expect(manifest.firstLevelCount, 7);
      expect(manifest.firstLevel(), const [
        FirstLevelItem(name: 'Apple', isFolder: false),
        FirstLevelItem(name: 'apple2', isFolder: false),
        FirstLevelItem(name: 'banana', isFolder: true),
        FirstLevelItem(name: 'cherry', isFolder: false),
        FirstLevelItem(name: 'Date', isFolder: true),
      ]);
    });

    test('max changes how many come back, never the count', () {
      final manifest = sevenChildren().build();

      expect(manifest.firstLevel(max: 2).map((item) => item.name), [
        'Apple',
        'apple2',
      ]);
      expect(manifest.firstLevel(max: 20).length, 7);
      expect(manifest.firstLevel(max: 0), isEmpty);
      expect(manifest.firstLevelCount, 7);
    });

    test('names that differ only in case keep a stable order', () {
      final builder = ManifestBuilder()
        ..addFile(0, 'a', 1)
        ..addFile(0, 'A', 1);

      expect(builder.build().firstLevel().map((item) => item.name), ['A', 'a']);
    });

    test('the same order comes out of a manifest read from the wire', () {
      final built = sevenChildren().build();
      final encoded = encodeManifest(built);
      final result = readAll(encoded, declareFor(built, encoded));

      expect(result.refusal, isNull);
      expect(result.manifest!.firstLevel(), built.firstLevel());
      expect(result.manifest!.firstLevelCount, 7);
    });

    test('an empty folder has no first level', () {
      final manifest = ManifestBuilder().build();

      expect(manifest.firstLevel(), isEmpty);
      expect(manifest.firstLevelCount, 0);
    });
  });

  group('M-2 and Q-2: the first level is computed once per manifest', () {
    ManifestBuilder flat(int count) {
      final builder = ManifestBuilder();
      for (var i = 0; i < count; i++) {
        builder.setFile(
          builder.addFile(0, 'f${count - i}.txt', 1),
          1,
          Uint8List(32),
        );
      }
      return builder;
    }

    test('100000 flat entries: 100 repeated reads take no time and give the '
        'same list', () {
      final manifest = flat(100000).build();
      final first = manifest.firstLevel();

      final watch = Stopwatch()..start();
      for (var k = 0; k < 100; k++) {
        expect(identical(manifest.firstLevel(), first), isTrue);
        expect(manifest.firstLevelCount, 100000);
      }
      watch.stop();

      expect(watch.elapsedMilliseconds, lessThan(50));
      expect(first.map((item) => item.name), [
        'f1.txt',
        'f10.txt',
        'f100.txt',
        'f1000.txt',
        'f10000.txt',
      ]);
    });

    test('the first five come out the same as with a full sort, for random '
        'names with mixed case', () {
      final random = Random(7);
      const letters = 'aAbBcCzZ_-.0123';
      for (var round = 0; round < 40; round++) {
        final builder = ManifestBuilder();
        final seen = <String>{};
        final count = 1 + random.nextInt(60);
        while (seen.length < count) {
          final name = String.fromCharCodes([
            for (var k = 0; k < 1 + random.nextInt(4); k++)
              letters.codeUnitAt(random.nextInt(letters.length)),
          ]);
          if (seen.add(name)) {
            if (random.nextBool()) {
              builder.addFolder(0, name);
            } else {
              builder.addFile(0, name, 1);
            }
          }
        }
        final manifest = builder.build();

        expect(
          manifest.firstLevel(),
          manifest.firstLevel(max: count).take(5).toList(),
          reason: 'round $round',
        );
        expect(manifest.firstLevelCount, count);
      }
    });

    test('children of folders never count as first level', () {
      final builder = ManifestBuilder();
      final folder = builder.addFolder(0, 'zz');
      builder.addFile(folder, 'aa', 1);
      builder.addFile(folder, 'ab', 1);

      final manifest = builder.build();

      expect(manifest.firstLevelCount, 1);
      expect(manifest.firstLevel().single.name, 'zz');
    });
  });

  group('M-3: an entry named .git at any level', () {
    bool hasGit(List<String> lines) {
      final built = ManifestBuilder();
      final folders = <int>[0];
      for (final line in lines) {
        final parts = line.split('|');
        final parent = folders[int.parse(parts[0])];
        if (parts[1] == 'd') {
          folders.add(built.addFolder(parent, parts[2]));
        } else {
          built.addFile(parent, parts[2], 1);
        }
      }
      return built.build().containsGitEntry;
    }

    test('at the first level, deep inside and in any case', () {
      expect(hasGit(['0|d|.git']), isTrue);
      expect(hasGit(['0|d|src', '1|d|vendor', '2|d|.git']), isTrue);
      expect(hasGit(['0|d|.GIT']), isTrue);
      expect(hasGit(['0|f|.git']), isTrue);
      expect(hasGit(['0|d|a', '1|d|b', '2|f|.GIT']), isTrue);
      expect(hasGit(['0|d|.Git']), isTrue);
      expect(hasGit(['0|d|a', '1|d|.gIt', '2|f|HEAD']), isTrue);
    });

    test('look alikes are not a .git entry', () {
      expect(hasGit(['0|d|.github']), isFalse);
      expect(hasGit(['0|d|x.git']), isFalse);
      expect(hasGit(['0|f|.gitignore']), isFalse);
      expect(hasGit(['0|d|.git2']), isFalse);
      expect(hasGit(['0|d|git']), isFalse);
      expect(hasGit([]), isFalse);
    });

    test('a manifest read from the wire says the same', () {
      final builder = ManifestBuilder();
      final src = builder.addFolder(0, 'src');
      builder.addFolder(src, '.git');
      final built = builder.build();
      final encoded = encodeManifest(built);

      final result = readAll(encoded, declareFor(built, encoded));

      expect(result.refusal, isNull);
      expect(result.manifest!.containsGitEntry, isTrue);
    });
  });

  group('E594: names reserved by the app', () {
    final reserved = [
      '.nexusbridges-incoming',
      '.NexusBridges-Incoming',
      '.NEXUSBRIDGES-INCOMING',
      '~nexusbridges-abc',
      '~NEXUSBRIDGES-0123456789ab',
      '~NexusBridges-',
    ];

    for (final name in reserved) {
      test('"$name" is invalid at any level, as folder and as file', () {
        final base = [folderLine(0, 'p'), folderLine(1, 'q')];

        expect(addRefusal([folderLine(0, name)]), invalidName);
        expect(addRefusal([fileLine(0, name, 1)]), invalidName);
        expect(addRefusal([...base, folderLine(2, name)]), invalidName);
        expect(addRefusal([...base, fileLine(2, name, 1)]), invalidName);
      });
    }

    test('look alikes are not reserved', () {
      for (final name in [
        '.nexusbridges-incoming2',
        'x.nexusbridges-incoming',
        '~nexusbridges',
        '~nexusbridge-x',
        'nexusbridges-x',
        '.nexusbridges',
      ]) {
        expect(addRefusal([folderLine(0, name)]), isNull, reason: name);
      }
    });
  });
}

typedef FolderManifestTweak = FolderOfferRequest Function(
  FolderManifest manifest,
  Uint8List encoded,
);

String label(String name) => name.isEmpty ? '(empty)' : name;
