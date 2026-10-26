import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:nexus_bridges/src/ui/icons/file_icon.dart';

final RegExp _literalText = RegExp(r'''Text\(\s*['"]''');

const List<String> _acronyms = [
  'PDF',
  'XLS',
  'DOC',
  'PPT',
  'ZIP',
  'EXE',
  '</>',
];

final RegExp _acronymLiteral = RegExp(
  '[\'"](?:${_acronyms.map(RegExp.escape).join('|')})[\'"]',
);

List<File> _uiSources() {
  final directory = Directory(
    'lib${Platform.pathSeparator}src'
    '${Platform.pathSeparator}ui',
  );
  return [
    for (final entity in directory.listSync(recursive: true))
      if (entity is File && entity.path.endsWith('.dart')) entity,
  ];
}

void main() {
  group('RF-62 no literal texts in lib/src/ui', () {
    test('the pattern catches literal texts and lets AppStrings through', () {
      expect(_literalText.hasMatch("Text('Hola')"), isTrue);
      expect(_literalText.hasMatch('Text("Hola")'), isTrue);
      expect(_literalText.hasMatch("const Text(\n  'Hola',\n)"), isTrue);
      expect(_literalText.hasMatch("Text(  '''Hola''')"), isTrue);
      expect(_literalText.hasMatch('Text(strings.devicesTitle)'), isFalse);
      expect(_literalText.hasMatch('Text(\n  message,\n)'), isFalse);
    });

    test('lib/src/ui holds the screens and the pairing dialogs', () {
      final names = _uiSources()
          .map((file) => file.uri.pathSegments.last)
          .toSet();
      expect(
        names,
        containsAll([
          'home_screen.dart',
          'network_prompt_dialog.dart',
          'pairing_dialogs.dart',
        ]),
      );
    });

    test('the pairing dialogs take every text from AppStrings', () {
      final source = File(
        'lib${Platform.pathSeparator}src${Platform.pathSeparator}ui'
        '${Platform.pathSeparator}pairing_dialogs.dart',
      ).readAsStringSync();
      expect(_literalText.hasMatch(source), isFalse);
      expect(source, contains('AppStringsDelegate.of('));
      expect(
        RegExp(r'''(title|content|child|label):\s*(const\s+)?Text\(\s*['"]''')
            .hasMatch(source),
        isFalse,
      );
    });

    test('no file in lib/src/ui builds a Text from a literal', () {
      final offenders = <String>[];
      for (final file in _uiSources()) {
        final source = file.readAsStringSync();
        for (final match in _literalText.allMatches(source)) {
          final line = '\n'.allMatches(source.substring(0, match.start)).length;
          offenders.add('${file.path}:${line + 1}');
        }
      }
      expect(offenders, isEmpty);
    });
  });

  group('E259 point 138: file type acronyms live only in fileKindLabels', () {
    test('the pattern catches quoted acronyms and nothing else', () {
      expect(_acronymLiteral.hasMatch("'PDF'"), isTrue);
      expect(_acronymLiteral.hasMatch('"EXE"'), isTrue);
      expect(_acronymLiteral.hasMatch("label: '</>',"), isTrue);
      expect(_acronymLiteral.hasMatch("'PDFs'"), isFalse);
      expect(_acronymLiteral.hasMatch("'a.pdf'"), isFalse);
      expect(_acronymLiteral.hasMatch('FileKind.pdf'), isFalse);
      expect(_acronymLiteral.hasMatch("'Doc'"), isFalse);
    });

    test('fileKindLabels holds exactly the closed list', () {
      expect(fileKindLabels.values.toSet(), _acronyms.toSet());
      expect(fileKindLabels, hasLength(_acronyms.length));
    });

    test('file_icon.dart writes each acronym once, inside the map', () {
      final source = File(
        'lib${Platform.pathSeparator}src${Platform.pathSeparator}ui'
        '${Platform.pathSeparator}icons${Platform.pathSeparator}'
        'file_icon.dart',
      ).readAsStringSync();
      final start = source.indexOf('fileKindLabels = {');
      expect(start, isNot(-1));
      final end = source.indexOf('};', start);
      for (final acronym in _acronyms) {
        final hits = RegExp('[\'"]${RegExp.escape(acronym)}[\'"]')
            .allMatches(source)
            .toList();
        expect(hits, hasLength(1), reason: acronym);
        expect(
          hits.single.start,
          inInclusiveRange(start, end),
          reason: acronym,
        );
      }
    });

    test('no other file in lib/src/ui quotes an acronym', () {
      final offenders = <String>[];
      for (final file in _uiSources()) {
        if (file.uri.pathSegments.last == 'file_icon.dart') continue;
        final source = file.readAsStringSync();
        for (final match in _acronymLiteral.allMatches(source)) {
          final line = '\n'.allMatches(source.substring(0, match.start)).length;
          offenders.add('${file.path}:${line + 1} ${match.group(0)}');
        }
      }
      expect(offenders, isEmpty);
    });
  });
}
