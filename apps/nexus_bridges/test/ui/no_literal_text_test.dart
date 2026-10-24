import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

final RegExp _literalText = RegExp(r'''Text\(\s*['"]''');

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
}
