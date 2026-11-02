import 'dart:io';

import 'package:nexus_bridges_core/src/outbox/outbox.dart';
import 'package:nexus_bridges_core/src/outbox/path_key.dart';
import 'package:test/test.dart';

Future<ElementProbe> _probe(String path) async =>
    const ElementProbe(kind: ElementKind.file, size: 1);

void main() {
  group('Q-6: the comparison key follows NTFS letter case', () {
    test('ASCII letters, slashes and final separators are folded', () {
      final key = pathKey(r'C:\in\Informe.pdf');
      expect(pathKey(r'c:\IN\informe.PDF'), key);
      expect(pathKey('C:/in/Informe.pdf'), key);
      expect(pathKey(r'C:\in\Informe.pdf\'), key);
      expect(pathKey(r'C:\in\Informe.pdf\\'), key);
      expect(pathKey(r'C:\in\Informe.txt'), isNot(key));
    });

    test('drive roots are one key however they are written', () {
      expect(pathKey('C:'), pathKey(r'c:\'));
      expect(pathKey('C:/'), pathKey(r'C:\'));
      expect(pathKey(r'D:\'), isNot(pathKey(r'C:\')));
    });

    test('the dotless i is not the letter i and the dotted capital is not '
        'either', () {
      expect(pathKey(r'C:\x\ı.txt'), isNot(pathKey(r'C:\x\i.txt')));
      expect(pathKey(r'C:\x\ı.txt'), isNot(pathKey(r'C:\x\I.txt')));
      expect(pathKey(r'C:\x\i.txt'), pathKey(r'C:\x\I.txt'));
      expect(pathKey(r'C:\x\İ.txt'), isNot(pathKey(r'C:\x\i.txt')));
    });

    test('the sharp s is not SS, but the capital of an accented letter is the '
        'same letter', () {
      expect(pathKey(r'C:\x\straße.txt'), isNot(pathKey(r'C:\x\STRASSE.txt')));
      expect(pathKey(r'C:\x\straße.txt'), pathKey(r'C:\x\STRAßE.txt'));
      expect(pathKey(r'C:\x\café.txt'), pathKey(r'C:\x\CAFÉ.txt'));
    });

    test('the long s, the micro sign, the final sigma and the Kelvin sign '
        'stay apart', () {
      expect(pathKey(r'C:\x\ſ'), isNot(pathKey(r'C:\x\s')));
      expect(pathKey(r'C:\x\µ'), isNot(pathKey(r'C:\x\Μ')));
      expect(pathKey(r'C:\x\ς'), isNot(pathKey(r'C:\x\Σ')));
      expect(pathKey(r'C:\x\σ'), pathKey(r'C:\x\Σ'));
      expect(pathKey('C:\\x\\\u212a'), isNot(pathKey(r'C:\x\k')));
    });

    test('letters outside the basic plane are not folded', () {
      expect(pathKey('C:\\x\\\u{10428}'), isNot(pathKey('C:\\x\\\u{10400}')));
    });

    test('the key agrees with what NTFS does on a real disk', () {
      final root = Directory.systemTemp.createTempSync('path_key_');
      addTearDown(() => root.deleteSync(recursive: true));
      final pairs = [
        ('ı', 'I'),
        ('ı', 'i'),
        ('i', 'I'),
        ('İ', 'i'),
        ('ſ', 'S'),
        ('µ', 'Μ'),
        ('ς', 'Σ'),
        ('σ', 'Σ'),
        ('ǅ', 'Ǆ'),
        ('ǆ', 'Ǆ'),
        ('\u212a', 'k'),
        ('\u212a', 'K'),
        ('é', 'É'),
        ('ᾳ', 'ᾼ'),
        ('ẞ', 'ß'),
        ('\u{10428}', '\u{10400}'),
      ];
      for (final (first, second) in pairs) {
        final created = File('${root.path}\\X$first.t')
          ..writeAsBytesSync(const [1]);
        final sameOnDisk = File('${root.path}\\X$second.t').existsSync();
        created.deleteSync();
        expect(
          pathKey('X$first.t') == pathKey('X$second.t'),
          sameOnDisk,
          reason:
              'U+${first.runes.first.toRadixString(16)} against '
              'U+${second.runes.first.toRadixString(16)}',
        );
      }
    });
  });

  group('the tray and the key', () {
    test(
      'Q-6 ı.txt and i.txt are two files, I.txt is the same as i.txt',
      () async {
        final tray = SendTray(probe: _probe);

        expect(
          await tray.add([r'C:\x\ı.txt', r'C:\x\I.txt', r'C:\x\i.txt']),
          TrayAddResult.added,
        );

        expect(tray.paths, [r'C:\x\ı.txt', r'C:\x\I.txt']);
      },
    );

    test('Q-6 straße.txt and STRASSE.txt are two files', () async {
      final tray = SendTray(probe: _probe);

      expect(
        await tray.add([r'C:\x\straße.txt', r'C:\x\STRASSE.txt']),
        TrayAddResult.added,
      );

      expect(tray.paths, [r'C:\x\straße.txt', r'C:\x\STRASSE.txt']);
    });
  });
}
