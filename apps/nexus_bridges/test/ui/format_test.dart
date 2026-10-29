import 'package:flutter_test/flutter_test.dart';
import 'package:nexus_bridges/src/l10n/app_strings.dart';
import 'package:nexus_bridges/src/ui/format.dart';

final String _ellipsis = String.fromCharCode(0x2026);
final String _grin = String.fromCharCode(0x1F600);
final String _flagPart = String.fromCharCode(0x1F1EA);

const String _zeroWidthSpace = '\u200B';

const String _wordJoiner = '\u2060';

const String _noBreakSpace = '\u00A0';

const int _kib = 1024;
const int _mib = 1024 * _kib;
const int _gib = 1024 * _mib;
const int _tib = 1024 * _gib;

bool _hasLoneSurrogate(String text) =>
    text.runes.any((rune) => rune >= 0xD800 && rune <= 0xDFFF);

void main() {
  group('E146, RF-163: formatSize', () {
    final cases = <int, (String, String)>{
      0: ('0 bytes', '0 bytes'),
      1: ('1 byte', '1 byte'),
      2: ('2 bytes', '2 bytes'),
      1023: ('1023 bytes', '1023 bytes'),
      1024: ('1.0 KB', '1,0 KB'),
      1536: ('1.5 KB', '1,5 KB'),
      1843: ('1.8 KB', '1,8 KB'),
      10239: ('10.0 KB', '10,0 KB'),
      10240: ('10 KB', '10 KB'),
      1023 * _kib: ('1023 KB', '1023 KB'),
      _mib: ('1.0 MB', '1,0 MB'),
      150 * _mib: ('150 MB', '150 MB'),
      _gib: ('1.0 GB', '1,0 GB'),
      5 * _gib: ('5.0 GB', '5,0 GB'),
      _gib + _gib ~/ 2: ('1.5 GB', '1,5 GB'),
      20 * _gib: ('20 GB', '20 GB'),
      _tib: ('1.0 TB', '1,0 TB'),
      3 * _tib: ('3.0 TB', '3,0 TB'),
      5000 * _tib: ('5000 TB', '5000 TB'),
    };

    for (final entry in cases.entries) {
      test('${entry.key} bytes gives "${entry.value.$1}" in en and '
          '"${entry.value.$2}" in es', () {
        expect(formatSize(entry.key, 'en'), entry.value.$1);
        expect(formatSize(entry.key, 'es'), entry.value.$2);
      });
    }

    test('one byte is singular in both languages and the rest of the values '
        'under 1024 are plural (point 108)', () {
      expect(formatSize(1, 'en'), '1 byte');
      expect(formatSize(1, 'es'), '1 byte');
      for (final bytes in [0, 2, 3, 10, 512, 1023]) {
        expect(formatSize(bytes, 'en'), '$bytes bytes');
        expect(formatSize(bytes, 'es'), '$bytes bytes');
      }
    });

    test('values under 10 keep one decimal and values of 10 or more keep '
        'none, in every unit', () {
      expect(formatSize(9 * _mib, 'en'), '9.0 MB');
      expect(formatSize(10 * _mib, 'en'), '10 MB');
      expect(formatSize(99 * _gib, 'en'), '99 GB');
      expect(formatSize(9 * _tib + _tib ~/ 2, 'en'), '9.5 TB');
      expect(formatSize(9 * _tib + _tib ~/ 2, 'es'), '9,5 TB');
    });

    test('TB is the biggest unit: a huge size does not move to another unit '
        'nor overflow', () {
      final biggest = 0x7FFFFFFFFFFFFFFF;
      expect(formatSize(biggest, 'en'), '8388608 TB');
      expect(formatSize(biggest, 'es'), '8388608 TB');
      expect(formatSize(1024 * _tib, 'en'), '1024 TB');
    });

    test('the Spanish text only changes the decimal point, nothing else', () {
      for (final bytes in [1536, 150 * _mib, 5 * _gib, 3 * _tib]) {
        expect(
          formatSize(bytes, 'es'),
          formatSize(bytes, 'en').replaceFirst('.', ','),
        );
      }
    });
  });

  group('E146, RF-196: shortenFileName', () {
    test('a name that fits in 60 runes stays the same', () {
      expect(shortenFileName('informe.pdf'), 'informe.pdf');
      final sixty = '${'a' * 56}.exe';
      expect(sixty.runes.length, 60);
      expect(shortenFileName(sixty), sixty);
      expect(shortenFileName(''), '');
    });

    test('a name of 300 characters with .exe keeps the whole extension and '
        'ends in an ellipsis and .exe', () {
      final name = '${'f' * 296}.exe';
      final short = shortenFileName(name);
      expect(short.runes.length, 60);
      expect(short, endsWith('$_ellipsis.exe'));
      expect(short, '${'f' * 55}$_ellipsis.exe');
    });

    test('61 runes are shortened to exactly 60 with the extension', () {
      final name = '${'b' * 57}.txt';
      expect(name.runes.length, 61);
      expect(shortenFileName(name), '${'b' * 55}$_ellipsis.txt');
    });

    test('an extension of 16 runes with its dot is kept whole', () {
      final extension = '.${'x' * 15}';
      expect(extension.runes.length, 16);
      final short = shortenFileName('${'n' * 300}$extension');
      expect(short.runes.length, 60);
      expect(short, '${'n' * 43}$_ellipsis$extension');
    });

    test('an "extension" of 17 runes with its dot is not an extension: the '
        'first 59 runes and an ellipsis', () {
      final extension = '.${'x' * 16}';
      expect(extension.runes.length, 17);
      final name = '${'n' * 300}$extension';
      final short = shortenFileName(name);
      expect(short, '${'n' * 59}$_ellipsis');
      expect(short.runes.length, 60);
    });

    test('a long name without a dot: the first 59 runes and an ellipsis', () {
      expect(shortenFileName('z' * 300), '${'z' * 59}$_ellipsis');
    });

    test('a dot at the start is not an extension', () {
      final name = '.${'h' * 100}';
      expect(shortenFileName(name), '${name.substring(0, 59)}$_ellipsis');
    });

    test('a program with a double extension keeps the real one at the end '
        '(RF-232)', () {
      final name = 'factura ${'muy larga ' * 10}.pdf.exe';
      final short = shortenFileName(name);
      expect(short, endsWith('$_ellipsis.exe'));
      expect(short.runes.length, 60);
    });

    test('a short name with a double extension stays whole', () {
      expect(shortenFileName('factura.pdf.exe'), 'factura.pdf.exe');
    });

    test('emojis count as one rune each and are never split in half', () {
      final name = '${_grin * 100}.png';
      expect(name.length, 204);
      final short = shortenFileName(name);
      expect(short.runes.length, 60);
      expect(short, '${_grin * 55}$_ellipsis.png');
      expect(_hasLoneSurrogate(short), isFalse);
    });

    test('a name of 60 emojis fits and stays the same, even though it has '
        '120 code units', () {
      final name = _grin * 60;
      expect(shortenFileName(name), name);
    });

    test('emojis without an extension are cut on whole runes', () {
      final name = _flagPart * 80;
      final short = shortenFileName(name);
      expect(short.runes.length, 60);
      expect(short, '${_flagPart * 59}$_ellipsis');
      expect(_hasLoneSurrogate(short), isFalse);
    });

    test('an emoji inside the extension is kept whole', () {
      final extension = '.$_grin$_grin';
      final short = shortenFileName('${'q' * 100}$extension');
      expect(short, '${'q' * 56}$_ellipsis$extension');
      expect(_hasLoneSurrogate(short), isFalse);
    });

    test('maxRunes changes the limit', () {
      expect(
        shortenFileName('abcdefghijklmnop.txt', maxRunes: 10),
        'abcde$_ellipsis.txt',
      );
      expect(
        shortenFileName('abcdefghijklmnop', maxRunes: 10),
        'abcdefghi$_ellipsis',
      );
      expect(shortenFileName('abc.txt', maxRunes: 10), 'abc.txt');
    });
  });

  group('E146, RF-163, RF-223: percentOf', () {
    test('0 of 0 is 100 (an empty file is complete at once)', () {
      expect(percentOf(0, 0), 100);
    });

    test('rounds down and only gives 100 when everything is done', () {
      expect(percentOf(0, 100), 0);
      expect(percentOf(1, 3), 33);
      expect(percentOf(2, 3), 66);
      expect(percentOf(50, 100), 50);
      expect(percentOf(99, 100), 99);
      expect(percentOf(999999, 1000000), 99);
      expect(percentOf(100, 100), 100);
    });

    test('a huge file does not overflow', () {
      expect(percentOf(5 * _tib ~/ 2, 5 * _tib), 50);
      expect(percentOf(1024 * _tib - 1, 1024 * _tib), 99);
      expect(percentOf(1024 * _tib, 1024 * _tib), 100);
    });
  });

  group('E281: formatPercent', () {
    test('Spanish puts a space before the percent sign and English does '
        'not', () {
      expect(formatPercent(0, 'es'), '0 %');
      expect(formatPercent(0, 'en'), '0%');
      expect(formatPercent(61, 'es'), '61 %');
      expect(formatPercent(61, 'en'), '61%');
      expect(formatPercent(100, 'es'), '100 %');
      expect(formatPercent(100, 'en'), '100%');
    });

    test('any language other than Spanish gets the English form', () {
      for (final code in ['', 'fr', 'de', 'pt']) {
        expect(formatPercent(61, code), '61%', reason: code);
      }
    });

    test('the figure is the same as the one that starts progressLine', () {
      expect(
        stringsFor('es').progressLine(61, 'a', 'b'),
        startsWith('${formatPercent(61, 'es')} '),
      );
      expect(
        stringsFor('en').progressLine(61, 'a', 'b'),
        startsWith('${formatPercent(61, 'en')} '),
      );
    });
  });

  group('E260, E262: formatOverflow', () {
    test('is a plus sign and the number of hidden peers, the same in both '
        'languages', () {
      expect(formatOverflow(1), '+1');
      expect(formatOverflow(2), '+2');
      expect(formatOverflow(19), '+19');
      expect(formatOverflow(1000), '+1000');
    });
  });

  group('point 245: breakablePath', () {
    String visible(String text) =>
        text.replaceAll(_zeroWidthSpace, '').replaceAll(_wordJoiner, '');

    const paths = [
      r'C:\Users\Ana\Downloads\NexusBridges',
      r'D:\Recibidos',
      r'E:\',
      r'\\servidor\compartida\carpeta',
      r'C:\Users\Ana\Mis cosas\Fotos de 2026',
    ];

    const backslash = r'\';

    test('only adds invisible characters: the path is the same once they '
        'are removed', () {
      for (final path in paths) {
        expect(visible(breakablePath(path)), path, reason: path);
      }
    });

    test('every backslash is followed by a zero-width space and there is no '
        'other one', () {
      for (final path in paths) {
        final shown = breakablePath(path);
        final backslashes = backslash.allMatches(path).length;
        expect(_zeroWidthSpace.allMatches(shown).length, backslashes);
        expect(
          '$backslash$_zeroWidthSpace'.allMatches(shown).length,
          backslashes,
          reason: path,
        );
      }
    });

    test('a path without separators and an empty path stay the same', () {
      expect(breakablePath('Recibidos'), 'Recibidos');
      expect(breakablePath('C:'), 'C:');
      expect(breakablePath(''), '');
    });

    test('a network path keeps its two backslashes, each with its break', () {
      expect(
        breakablePath(r'\\servidor\compartida'),
        '$backslash$_zeroWidthSpace$backslash${_zeroWidthSpace}servidor'
        '$backslash${_zeroWidthSpace}compartida',
      );
    });

    test('the other spaces of the path are not touched', () {
      expect(
        visible(breakablePath(r'C:\Mis cosas\Fotos')).contains('Mis cosas'),
        isTrue,
      );
      expect(breakablePath(r'C:\Mis cosas').contains(_noBreakSpace), isFalse);
    });
  });

  group('point 245: glueFingerprint', () {
    const short = 'ABCD1234';

    test('joins the last word, the dot and the fingerprint with no-break '
        'spaces and leaves the rest of the name alone', () {
      final glued = glueFingerprint(
        'Port\u00E1til de Ana \u00B7 $short',
        short,
      );
      expect(
        glued,
        'Port\u00E1til de Ana$_noBreakSpace\u00B7$_noBreakSpace$short',
      );
      expect(glued.split(' '), [
        'Port\u00E1til',
        'de',
        'Ana$_noBreakSpace\u00B7$_noBreakSpace$short',
      ]);
    });

    test('a name of one word sticks to its fingerprint', () {
      expect(
        glueFingerprint('Torre \u00B7 $short', short),
        'Torre$_noBreakSpace\u00B7$_noBreakSpace$short',
      );
    });

    test('a name without a fingerprint stays the same', () {
      for (final name in ['Port\u00E1til de Ana', 'Torre', '']) {
        expect(glueFingerprint(name, short), name);
      }
    });

    test('a fingerprint that does not match the end stays the same', () {
      for (final name in [
        'Port\u00E1til de Ana \u00B7 WXYZ9876',
        'Port\u00E1til de Ana \u00B7 ${short.toLowerCase()}',
        'Port\u00E1til de Ana \u00B7 $short extra',
        'Port\u00E1til de Ana\u00B7$short',
        'Port\u00E1til de Ana $short',
        '$short \u00B7 Port\u00E1til de Ana',
      ]) {
        expect(glueFingerprint(name, short), name, reason: name);
      }
    });

    test('only the last dot is glued when the name has another one', () {
      expect(
        glueFingerprint('Casa \u00B7 Ana \u00B7 $short', short),
        'Casa \u00B7 Ana$_noBreakSpace\u00B7$_noBreakSpace$short',
      );
    });
  });

  group('point 245: withoutFingerprint', () {
    const short = 'ABCD1234';

    test('removes the dot and the fingerprint at the end of the name', () {
      expect(
        withoutFingerprint('Port\u00E1til de Ana \u00B7 $short', short),
        'Port\u00E1til de Ana',
      );
      expect(withoutFingerprint('Torre \u00B7 $short', short), 'Torre');
    });

    test('a name without a fingerprint stays the same', () {
      for (final name in ['Port\u00E1til de Ana', 'Torre', '']) {
        expect(withoutFingerprint(name, short), name);
      }
    });

    test('a fingerprint that does not match the end stays the same', () {
      for (final name in [
        'Port\u00E1til de Ana \u00B7 WXYZ9876',
        'Port\u00E1til de Ana \u00B7 ${short.toLowerCase()}',
        'Port\u00E1til de Ana \u00B7 $short extra',
        'Port\u00E1til de Ana\u00B7$short',
        'Port\u00E1til de Ana $short',
        '$short \u00B7 Port\u00E1til de Ana',
      ]) {
        expect(withoutFingerprint(name, short), name, reason: name);
      }
    });

    test('only the last fingerprint is removed when the name has another '
        'dot', () {
      expect(
        withoutFingerprint('Casa \u00B7 Ana \u00B7 $short', short),
        'Casa \u00B7 Ana',
      );
    });

    test('glueFingerprint and withoutFingerprint agree on when a name has '
        'the fingerprint', () {
      for (final name in [
        'Port\u00E1til de Ana \u00B7 $short',
        'Port\u00E1til de Ana \u00B7 WXYZ9876',
        'Port\u00E1til de Ana',
      ]) {
        final hasIt = withoutFingerprint(name, short) != name;
        expect(glueFingerprint(name, short) != name, hasIt, reason: name);
      }
    });
  });
}
