import 'package:nexus_bridges_core/src/transfer/names.dart';
import 'package:test/test.dart';

String ch(int codePoint) => String.fromCharCode(codePoint);

String chars(List<int> codePoints) => String.fromCharCodes(codePoints);

final String emoji = ch(0x1F600);

final String replacement = ch(0xFFFD);

bool hasLoneSurrogate(String text) {
  final units = text.codeUnits;
  for (var i = 0; i < units.length; i++) {
    final unit = units[i];
    final high = unit >= 0xD800 && unit <= 0xDBFF;
    final low = unit >= 0xDC00 && unit <= 0xDFFF;
    if (high) {
      final next = i + 1 < units.length ? units[i + 1] : 0;
      if (next < 0xDC00 || next > 0xDFFF) return true;
      i++;
    } else if (low) {
      return true;
    }
  }
  return false;
}

final List<int> controlAndInvisible = [
  for (var c = 0x0000; c <= 0x001F; c++) c,
  0x007F,
  for (var c = 0x0080; c <= 0x009F; c++) c,
  for (var c = 0x202A; c <= 0x202E; c++) c,
  for (var c = 0x2066; c <= 0x2069; c++) c,
  0x200B,
  0xFEFF,
  for (var c = 0x2060; c <= 0x2064; c++) c,
  0x180E,
  for (var c = 0x206A; c <= 0x206F; c++) c,
  for (var c = 0xFFF9; c <= 0xFFFB; c++) c,
  0x115F,
  0x1160,
  0x3164,
  0xFFA0,
];

const List<String> reservedStems = [
  'CON',
  'PRN',
  'AUX',
  'NUL',
  r'CONIN$',
  r'CONOUT$',
  'COM0',
  'COM1',
  'COM2',
  'COM3',
  'COM4',
  'COM5',
  'COM6',
  'COM7',
  'COM8',
  'COM9',
  'LPT0',
  'LPT1',
  'LPT2',
  'LPT3',
  'LPT4',
  'LPT5',
  'LPT6',
  'LPT7',
  'LPT8',
  'LPT9',
];

const List<String> programExtensions = [
  '.exe',
  '.msi',
  '.msix',
  '.bat',
  '.cmd',
  '.com',
  '.scr',
  '.ps1',
  '.vbs',
  '.js',
  '.jse',
  '.wsf',
  '.hta',
  '.cpl',
  '.jar',
  '.reg',
  '.appx',
  '.dll',
  '.sys',
  '.application',
];

void main() {
  group('E1, RF-145, RF-211: valid file names', () {
    final family = chars([0x1F468, 0x200D, 0x1F469, 0x200D, 0x1F467]);
    final persian = chars([
      0x0645,
      0x06CC,
      0x200C,
      0x062E,
      0x0648,
      0x0627,
      0x0647,
      0x0645,
    ]);
    final hebrew = chars([0x05E9, 0x05DC, 0x05D5, 0x05DD, 0x200F]);
    final heart = chars([0x2764, 0xFE0F]);

    final valid = <String, String>{
      'plain name': 'informe.pdf',
      'emoji joined with U+200D': '$family.png',
      'Persian word with U+200C': '$persian.txt',
      'Hebrew name with U+200F': '$hebrew.txt',
      'emoji with U+FE0F': '$heart.txt',
      '253 ASCII and one emoji (255 units)': '${'a' * 253}$emoji',
    };

    for (final MapEntry(key: label, value: name) in valid.entries) {
      test(label, () => expect(isValidFileName(name), isTrue));
    }

    test('the emoji case measures exactly 255 UTF-16 units', () {
      expect(valid['253 ASCII and one emoji (255 units)']!.length, 255);
    });

    test(
      'U+200E and every variation selector U+FE00 to U+FE0F are allowed',
      () {
        expect(isValidFileName('a${ch(0x200E)}b.txt'), isTrue);
        for (var c = 0xFE00; c <= 0xFE0F; c++) {
          expect(
            isValidFileName('a${ch(c)}.txt'),
            isTrue,
            reason: c.toRadixString(16),
          );
        }
      },
    );

    test('characters just outside the forbidden ranges are allowed', () {
      for (final c in [
        0x0020,
        0x00A0,
        0x00B9,
        0x180D,
        0x180F,
        0x200A,
        0x2065,
        0x2070,
        0x1161,
        0x3165,
        0xFFA1,
        0xFFF8,
        0xFFFC,
      ]) {
        expect(
          isValidFileName('a${ch(c)}b.txt'),
          isTrue,
          reason: c.toRadixString(16),
        );
      }
    });

    test('a name with a dot in the middle, a leading dot or spaces inside', () {
      expect(isValidFileName('.gitignore'), isTrue);
      expect(isValidFileName('a.tar.gz'), isTrue);
      expect(isValidFileName('mi informe final.docx'), isTrue);
      expect(isValidFileName('a'), isTrue);
    });
  });

  group('E2, RF-145, RF-211: invalid file names', () {
    final invalid = <String, String>{
      'empty': '',
      '256 units': 'a' * 256,
      '254 ASCII and one emoji (256 units)': '${'a' * 254}$emoji',
      'lone high surrogate': 'a${ch(0xD800)}.txt',
      'lone low surrogate': 'a${ch(0xDC00)}.txt',
      'surrogates in the wrong order': 'a${ch(0xDC00)}${ch(0xD800)}.txt',
      'high surrogate at the end': 'a.txt${ch(0xDBFF)}',
      'colon': 'a:b',
      'backslash going up': r'..\x',
      'slash': 'a/b',
      'asterisk': 'a*b',
      'question mark': 'a?b',
      'double quote': 'a"b',
      'less than': 'a<b',
      'greater than': 'a>b',
      'pipe': 'a|b',
      'U+0001': 'a${ch(0x0001)}b',
      'U+007F': 'a${ch(0x007F)}b',
      'U+0085': 'a${ch(0x0085)}b',
      'U+202E': 'a${ch(0x202E)}b',
      'U+2066': 'a${ch(0x2066)}b',
      'U+200B': 'a${ch(0x200B)}b',
      'U+FEFF': 'a${ch(0xFEFF)}b',
      'U+2060': 'a${ch(0x2060)}b',
      'U+180E': 'a${ch(0x180E)}b',
      'U+206A': 'a${ch(0x206A)}b',
      'U+FFF9': 'a${ch(0xFFF9)}b',
      'U+115F': 'a${ch(0x115F)}b',
      'U+3164': 'a${ch(0x3164)}b',
      'U+FFA0': 'a${ch(0xFFA0)}b',
      'one dot': '.',
      'two dots': '..',
      'ending in a dot': 'x.',
      'ending in a space': 'x ',
    };

    for (final MapEntry(key: label, value: name) in invalid.entries) {
      test(label, () => expect(isValidFileName(name), isFalse));
    }

    test('every character of the control and invisible lists, anywhere', () {
      for (final c in controlAndInvisible) {
        final hex = c.toRadixString(16);
        expect(isValidFileName('a${ch(c)}b.txt'), isFalse, reason: hex);
        expect(isValidFileName('${ch(c)}b.txt'), isFalse, reason: hex);
        expect(isValidFileName('b.tx${ch(c)}t'), isFalse, reason: hex);
      }
    });

    test('each forbidden ASCII character, also at the start and the end', () {
      for (final c in r'\/:*?"<>|'.split('')) {
        expect(isValidFileName('${c}a.txt'), isFalse, reason: c);
        expect(isValidFileName('a.txt$c'), isFalse, reason: c);
      }
    });

    test('several dots or spaces at the end', () {
      expect(isValidFileName('informe.pdf...'), isFalse);
      expect(isValidFileName('informe.pdf. '), isFalse);
      expect(isValidFileName('   '), isFalse);
    });
  });

  group('E3, RF-145: reserved Windows names', () {
    final reserved = [
      'CON',
      'con.txt',
      'CON .txt',
      'aux.tar.gz',
      'COM${ch(0x00B9)}.txt',
      r'CONIN$',
      r'conout$.log',
      'LPT0',
      'com0.txt',
    ];

    for (final name in reserved) {
      test(
        '"$name" is not valid',
        () => expect(isValidFileName(name), isFalse),
      );
    }

    for (final name in ['CONSOLE.txt', 'COM10.txt', 'xcon.txt']) {
      test('"$name" is valid', () => expect(isValidFileName(name), isTrue));
    }

    test('every reserved stem, in any case, alone, with an extension and '
        'with spaces before the first dot', () {
      for (final stem in [
        ...reservedStems,
        for (final digit in [0x00B9, 0x00B2, 0x00B3]) ...[
          'COM${ch(digit)}',
          'LPT${ch(digit)}',
        ],
      ]) {
        for (final variant in [stem, stem.toLowerCase()]) {
          expect(isValidFileName(variant), isFalse, reason: variant);
          expect(isValidFileName('$variant.txt'), isFalse, reason: variant);
          expect(isValidFileName('$variant  .txt'), isFalse, reason: variant);
          expect(isValidFileName('$variant.a.b'), isFalse, reason: variant);
        }
      }
    });

    test('a reserved word that is not the part before the first dot is '
        'valid', () {
      expect(isValidFileName('informe.con'), isTrue);
      expect(isValidFileName('x.CON.txt'), isTrue);
      expect(isValidFileName('NUL1.txt'), isTrue);
      expect(isValidFileName('LPT.txt'), isTrue);
      expect(isValidFileName('COM${ch(0x2074)}.txt'), isTrue);
    });
  });

  group('E4, RF-211, RF-214: blocked types', () {
    for (final name in [
      'x.LNK',
      'a.url',
      'b.scf',
      'c.library-ms',
      'd.searchConnector-ms',
      'Desktop.ini',
    ]) {
      test('"$name" is blocked', () => expect(isBlockedType(name), isTrue));
    }

    for (final name in ['desktop.ini.txt', 'x.lnk.txt', 'lnk']) {
      test('"$name" is not blocked', () {
        expect(isBlockedType(name), isFalse);
      });
    }

    test('the checks ignore case', () {
      expect(isBlockedType('DESKTOP.INI'), isTrue);
      expect(isBlockedType('Atajo.Url'), isTrue);
      expect(isBlockedType('x.SEARCHCONNECTOR-MS'), isTrue);
      expect(isBlockedType('x.Library-MS'), isTrue);
    });

    test('only the name desktop.ini is blocked, not one that ends in it', () {
      expect(isBlockedType('xdesktop.ini'), isFalse);
      expect(isBlockedType('config.ini'), isFalse);
    });

    test('a program is not a blocked type', () {
      expect(isBlockedType('setup.exe'), isFalse);
    });
  });

  group('E5, RF-232: programs', () {
    test('"factura.pdf.exe" and "x.PS1" are programs', () {
      expect(isProgram('factura.pdf.exe'), isTrue);
      expect(isProgram('x.PS1'), isTrue);
    });

    test('every extension of the list, in lower and upper case', () {
      for (final extension in programExtensions) {
        expect(isProgram('x$extension'), isTrue, reason: extension);
        expect(
          isProgram('x${extension.toUpperCase()}'),
          isTrue,
          reason: extension,
        );
      }
    });

    test('"x.exe.txt" is not a program', () {
      expect(isProgram('x.exe.txt'), isFalse);
    });

    test('names that only look close are not programs', () {
      for (final name in [
        'x.json',
        'x.exes',
        'exe',
        'x.jsx',
        'informe.pdf',
        'x.lnk',
      ]) {
        expect(isProgram(name), isFalse, reason: name);
      }
    });

    test('plan point 66: ".dll", ".sys" and ".application" are programs, '
        'their near names are not', () {
      for (final name in ['x.dll', 'DRIVER.SYS', 'app.Application']) {
        expect(isProgram(name), isTrue, reason: name);
      }
      for (final name in ['x.dl', 'x.dlls', 'x.system', 'x.applications']) {
        expect(isProgram(name), isFalse, reason: name);
      }
    });
  });

  group('E6, RF-175, RF-226: candidate names', () {
    test('n 0 gives the name itself', () {
      expect(candidateName('informe.pdf', 0), 'informe.pdf');
      expect(candidateName('.gitignore', 0), '.gitignore');
    });

    test('("informe.pdf", 1) gives "informe (1).pdf"', () {
      expect(candidateName('informe.pdf', 1), 'informe (1).pdf');
    });

    test('("informe", 1) gives "informe (1)"', () {
      expect(candidateName('informe', 1), 'informe (1)');
    });

    test('("a.tar.gz", 2) gives "a.tar (2).gz": the extension is from the '
        'last dot', () {
      expect(candidateName('a.tar.gz', 2), 'a.tar (2).gz');
    });

    test('(".gitignore", 1) gives ".gitignore (1)": a first-character dot is '
        'not an extension', () {
      expect(candidateName('.gitignore', 1), '.gitignore (1)');
      expect(candidateName('.config.json', 3), '.config (3).json');
    });

    test('254 units "a...a.txt" with n 1 gives 255 units ending in '
        '" (1).txt"', () {
      final name = '${'a' * 250}.txt';
      expect(name.length, 254);

      final candidate = candidateName(name, 1)!;

      expect(candidate.length, 255);
      expect(candidate, endsWith(' (1).txt'));
      expect(candidate, '${'a' * 247} (1).txt');
    });

    test('a name that fits with the suffix is not cut', () {
      final name = '${'a' * 247}.txt';
      expect(candidateName(name, 1), '${'a' * 247} (1).txt');
    });

    test('an emoji right at the cut is dropped whole, never half', () {
      final name = '${'a' * 246}$emoji${'b' * 5}.txt';

      final candidate = candidateName(name, 1)!;

      expect(hasLoneSurrogate(candidate), isFalse);
      expect(candidate, '${'a' * 246} (1).txt');
      expect(candidate.length, lessThanOrEqualTo(255));
      expect(isValidFileName(candidate), isTrue);
    });

    test('an emoji that fits whole before the cut is kept', () {
      final name = '${'a' * 245}$emoji${'b' * 5}.txt';

      final candidate = candidateName(name, 1)!;

      expect(candidate, '${'a' * 245}$emoji (1).txt');
      expect(candidate.length, 255);
    });

    test('a cut that leaves a dot or a space at the end removes them', () {
      final withDot = '${'a' * 245} .${'b' * 10}.txt';
      final withSpace = '${'a' * 246} ${'b' * 10}.txt';
      final withDots = '${'a' * 244}. .${'b' * 10}.txt';

      for (final name in [withDot, withSpace, withDots]) {
        final candidate = candidateName(name, 1)!;
        final beforeSuffix = candidate.substring(
          0,
          candidate.indexOf(' (1).txt'),
        );
        expect(beforeSuffix, isNot(endsWith('.')), reason: candidate);
        expect(beforeSuffix, isNot(endsWith(' ')), reason: candidate);
        expect(candidate, endsWith(' (1).txt'));
        expect(isValidFileName(candidate), isTrue, reason: candidate);
      }
      expect(candidateName(withDot, 1), '${'a' * 245} (1).txt');
      expect(candidateName(withSpace, 1), '${'a' * 246} (1).txt');
      expect(candidateName(withDots, 1), '${'a' * 244} (1).txt');
    });

    test('n 9999 gives " (9999)"', () {
      expect(candidateName('informe.pdf', 9999), 'informe (9999).pdf');

      final long = candidateName('${'a' * 251}.txt', 9999)!;
      expect(long, '${'a' * 244} (9999).txt');
      expect(long.length, 255);
    });

    test('an extension of 250 units leaves no room and gives null', () {
      expect(candidateName('a.${'x' * 250}', 1), isNull);
      expect(candidateName('a.${'x' * 249}', 10), isNull);
    });

    test('the extension is never cut: with room for one unit the base keeps '
        'one unit', () {
      final extension = '.${'x' * 249}';

      final candidate = candidateName('abc$extension', 1)!;

      expect(candidate, 'a (1)$extension');
      expect(candidate.length, 255);
    });

    test('a base that is only dots and spaces after the cut gives null', () {
      expect(candidateName('${' ' * 250}.txt', 1), isNull);
    });

    test('every candidate of a long valid name is valid and fits', () {
      final name = '${'x' * 120}$emoji${'y' * 120}.pdf';
      for (final n in [1, 9, 10, 99, 100, 999, 1000, 9999]) {
        final candidate = candidateName(name, n)!;
        expect(candidate.length, lessThanOrEqualTo(255), reason: '$n');
        expect(candidate, endsWith(' ($n).pdf'), reason: '$n');
        expect(isValidFileName(candidate), isTrue, reason: '$n');
      }
    });
  });

  group('E7, RF-196: visible file name', () {
    test('"factura" + U+202E + "fdp.exe" shows U+FFFD in place of U+202E', () {
      expect(
        visibleFileName('factura${ch(0x202E)}fdp.exe'),
        'factura${replacement}fdp.exe',
      );
    });

    test('"informe.pdf" stays the same', () {
      expect(visibleFileName('informe.pdf'), 'informe.pdf');
    });

    test('every character of the control and invisible lists becomes '
        'U+FFFD', () {
      for (final c in controlAndInvisible) {
        expect(
          visibleFileName('a${ch(c)}b.txt'),
          'a${replacement}b.txt',
          reason: c.toRadixString(16),
        );
      }
    });

    test('lone surrogates become U+FFFD and paired ones stay', () {
      expect(visibleFileName('a${ch(0xD800)}b'), 'a${replacement}b');
      expect(visibleFileName('a${ch(0xDC00)}b'), 'a${replacement}b');
      expect(visibleFileName('a${ch(0xDBFF)}'), 'a$replacement');
      expect(visibleFileName('$emoji.png'), '$emoji.png');
    });

    test('several dangerous characters are each replaced', () {
      expect(
        visibleFileName('${ch(0x202E)}x${ch(0x200B)}${ch(0x0007)}.exe'),
        '${replacement}x$replacement$replacement.exe',
      );
    });

    test('valid names with allowed invisibles stay the same', () {
      for (final name in [
        '${chars([0x1F468, 0x200D, 0x1F469])}.png',
        '${chars([0x0645, 0x200C, 0x062E])}.txt',
        '${chars([0x05E9, 0x200F])}.txt',
        '${chars([0x2764, 0xFE0F])}.txt',
        'a${ch(0x200E)}b.txt',
      ]) {
        expect(isValidFileName(name), isTrue);
        expect(visibleFileName(name), name);
      }
    });

    test('the visible name of any name has no dangerous character left', () {
      final hostile =
          '${ch(0x202E)}${ch(0xD800)}${ch(0x2066)}${ch(0x0000)}'
          '${ch(0xFEFF)}${ch(0x3164)}gpj.exe';

      final visible = visibleFileName(hostile);

      expect(hasLoneSurrogate(visible), isFalse);
      for (final c in controlAndInvisible) {
        expect(visible.contains(ch(c)), isFalse, reason: c.toRadixString(16));
      }
      expect(visible, endsWith('gpj.exe'));
    });
  });

  group('baseName', () {
    test('what follows the last backslash or slash', () {
      expect(baseName(r'C:\Users\David\informe.pdf'), 'informe.pdf');
      expect(baseName('C:/Users/David/informe.pdf'), 'informe.pdf');
      expect(baseName(r'C:\a/b\c.txt'), 'c.txt');
      expect(baseName(r'\\server\share\x.zip'), 'x.zip');
      expect(baseName('informe.pdf'), 'informe.pdf');
      expect(baseName(r'C:\carpeta\'), '');
    });
  });

  group('E178, RF-211, RF-214: blocked types of v3', () {
    const blocked = [
      'x.PIF',
      'y.settingcontent-ms',
      'z.SettingContent-MS',
      'a.search-ms',
      'b.theme',
      'c.THEMEPACK',
      'd.deskthemepack',
      'informe.txt.{3050f4d8-98B5-11CF-BB82-00AA00BDCE0B}',
      'a.{3050F4D8-98B5-11CF-BB82-00AA00BDCE0B}.txt',
    ];
    const allowed = [
      'x.pif.txt',
      'x.theme.txt',
      '{3050f4d8-98B5-11CF-BB82-00AA00BDCE0B}.txt',
      'x.{3050f4d8-98B5}',
      'x.{zzzzzzzz-98B5-11CF-BB82-00AA00BDCE0B}',
      'x.searchconnector-ms.txt',
    ];

    for (final name in blocked) {
      test('"$name" is blocked and still a valid name', () {
        expect(isBlockedType(name), isTrue);
        expect(isValidFileName(name), isTrue);
      });
    }

    for (final name in allowed) {
      test('"$name" is not blocked and is a valid name', () {
        expect(isBlockedType(name), isFalse);
        expect(isValidFileName(name), isTrue);
      });
    }

    test('the blocked types of v3 are not programs of the fixed list', () {
      for (final name in blocked) {
        expect(isProgram(name), isFalse, reason: name);
      }
    });

    test('a CLSID segment in the middle of a long name is blocked', () {
      expect(
        isBlockedType('a.b.{00021401-0000-0000-C000-000000000046}.c.d'),
        isTrue,
      );
    });
  });

  group('E179, RF-145, RF-196, RF-211: names of v3', () {
    final scotland = flag([0xE0067, 0xE0062, 0xE0073, 0xE0063, 0xE0074]);
    final england = flag([0xE0067, 0xE0062, 0xE0065, 0xE006E, 0xE0067]);
    final wales = flag([0xE0067, 0xE0062, 0xE0077, 0xE006C, 0xE0073]);
    final scotlandWithoutEnd = chars([
      0x1F3F4,
      0xE0067,
      0xE0062,
      0xE0073,
      0xE0063,
      0xE0074,
    ]);
    final scotlandWithCapital = flag([
      0xE0067,
      0xE0062,
      0xE0053,
      0xE0063,
      0xE0074,
    ]);
    final sevenTags = flag([
      0xE0067,
      0xE0062,
      0xE0073,
      0xE0063,
      0xE0074,
      0xE0061,
      0xE0062,
    ]);

    final invalid = <String, String>{
      'U+2028 inside': 'factura.pdf${ch(0x2028)}x.exe',
      'U+2029 inside': 'factura.pdf${ch(0x2029)}x.exe',
      'U+00AD inside': 'a${ch(0x00AD)}b.txt',
      'a lone U+E0000': 'a${ch(0xE0000)}.txt',
      'a lone U+E0041': 'a${ch(0xE0041)}.txt',
      'a lone U+E007F': 'a${ch(0xE007F)}.txt',
      'a Scotland flag without U+E007F': '$scotlandWithoutEnd.txt',
      'a flag with a capital tag U+E0053': '$scotlandWithCapital.txt',
      'a flag with 7 tags': '$sevenTags.txt',
      'a good flag and then a lone tag': '$scotland${ch(0xE0067)}.txt',
    };

    final valid = <String, String>{
      'U+061C inside': 'a${ch(0x061C)}b.txt',
      'U+034F inside': 'a${ch(0x034F)}b.txt',
      'U+FFFC inside': 'a${ch(0xFFFC)}b.txt',
      'the Scotland flag': '$scotland.txt',
      'the England and Wales flags together': '$england$wales.txt',
    };

    for (final MapEntry(key: label, value: name) in invalid.entries) {
      test('$label is not a valid name', () {
        expect(isValidFileName(name), isFalse);
      });
    }

    for (final MapEntry(key: label, value: name) in valid.entries) {
      test('$label is a valid name', () {
        expect(isValidFileName(name), isTrue);
      });
    }

    test('a flag with no tags is not valid', () {
      expect(isValidFileName('${chars([0x1F3F4, 0xE007F])}.txt'), isFalse);
    });

    test('a flag with 1 and with 6 tags is valid', () {
      expect(isValidFileName('${flag([0xE0067])}.txt'), isTrue);
      expect(
        isValidFileName(
          '${flag([0xE0067, 0xE0062, 0xE0061, 0xE0062, 0xE0063, 0xE0031])}.txt',
        ),
        isTrue,
      );
    });

    test('the tag ranges of a flag are exactly 0 to 9 and a to z', () {
      for (final tag in [0xE0030, 0xE0039, 0xE0061, 0xE007A]) {
        expect(
          isValidFileName('${flag([0xE0067, tag])}.txt'),
          isTrue,
          reason: tag.toRadixString(16),
        );
      }
      for (final tag in [
        0xE0020,
        0xE002F,
        0xE003A,
        0xE0041,
        0xE005A,
        0xE0060,
        0xE007B,
        0xE007E,
      ]) {
        expect(
          isValidFileName('${flag([0xE0067, tag])}.txt'),
          isFalse,
          reason: tag.toRadixString(16),
        );
      }
    });

    test('every lone tag from U+E0000 to U+E007F is refused', () {
      for (var c = 0xE0000; c <= 0xE007F; c++) {
        expect(
          isValidFileName('a${ch(c)}.txt'),
          isFalse,
          reason: c.toRadixString(16),
        );
      }
    });

    test('a tag right before a flag is still refused', () {
      expect(isValidFileName('${ch(0xE0067)}$scotland.txt'), isFalse);
    });

    test('a waving black flag alone is a normal emoji', () {
      expect(isValidFileName('${ch(0x1F3F4)}.txt'), isTrue);
      expect(visibleFileName('${ch(0x1F3F4)}.txt'), '${ch(0x1F3F4)}.txt');
    });

    test('visibleFileName of "a" + U+2028 + "b" is "a" + U+FFFD + "b"', () {
      expect(visibleFileName('a${ch(0x2028)}b'), 'a${replacement}b');
    });

    test('visibleFileName of "a" + U+E0041 + "b" uses one U+FFFD for the '
        'pair', () {
      final visible = visibleFileName('a${ch(0xE0041)}b');
      expect(visible, 'a${replacement}b');
      expect(visible.length, 3);
    });

    test('visibleFileName keeps the Scotland flag intact', () {
      expect(visibleFileName('$scotland.txt'), '$scotland.txt');
      expect(visibleFileName('$england$wales.txt'), '$england$wales.txt');
    });

    test('visibleFileName replaces U+00AD and U+2029 too', () {
      expect(visibleFileName('a${ch(0x00AD)}b'), 'a${replacement}b');
      expect(visibleFileName('a${ch(0x2029)}b'), 'a${replacement}b');
    });

    test('visibleFileName of a flag with no tags keeps the base emoji and '
        'replaces the end tag', () {
      expect(
        visibleFileName(chars([0x1F3F4, 0xE007F])),
        '${ch(0x1F3F4)}$replacement',
      );
    });

    test('visibleFileName of a broken flag replaces each tag', () {
      expect(
        visibleFileName('$scotlandWithoutEnd.txt'),
        '${ch(0x1F3F4)}${replacement * 5}.txt',
      );
    });

    test('the visible name of every invalid name of v3 is a valid name', () {
      for (final MapEntry(key: label, value: name) in invalid.entries) {
        final visible = visibleFileName(name);
        expect(hasLoneSurrogate(visible), isFalse, reason: label);
        expect(isValidFileName(visible), isTrue, reason: label);
      }
    });

    test('the allowed characters stay the same in the visible name', () {
      for (final name in valid.values) {
        expect(visibleFileName(name), name);
      }
    });

    test('windowsExtension gives the extension as Windows sees it', () {
      expect(windowsExtension('a.pdf'), '.pdf');
      expect(windowsExtension('a.tar.gz'), '.gz');
      expect(windowsExtension('.bashrc'), '.bashrc');
      expect(windowsExtension('a'), isNull);
      expect(windowsExtension('a.b c'), isNull);
    });

    test('windowsExtension keeps the case and a dot at the end', () {
      expect(windowsExtension('X.CHM'), '.CHM');
      expect(windowsExtension('a.'), '.');
      expect(windowsExtension('a b.txt'), '.txt');
    });
  });
}

String flag(List<int> tags) => chars([0x1F3F4, ...tags, 0xE007F]);
