import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:nexus_bridges/src/ui/icons/file_icon.dart';

final RegExp _literalText = RegExp(r'''Text\(\s*['"]''');

final RegExp _literalSpan = RegExp(
  r'''TextSpan\(\s*(?:\w+:\s*[^,()]+,\s*)*text:\s*['"]''',
);

final RegExp _materialIcon = RegExp(r'\bIcons\.');

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

  group('point 124: no literal TextSpan in lib/src/ui', () {
    test('the pattern catches literal spans and lets variables through', () {
      expect(_literalSpan.hasMatch("TextSpan(text: 'Hola')"), isTrue);
      expect(_literalSpan.hasMatch('TextSpan(text: "Hola")'), isTrue);
      expect(
        _literalSpan.hasMatch("const TextSpan(\n  text: 'Hola',\n)"),
        isTrue,
      );
      expect(_literalSpan.hasMatch("TextSpan(text:'Hola')"), isTrue);
      expect(_literalSpan.hasMatch("TextSpan(text: '''Hola''')"), isTrue);
      expect(
        _literalSpan.hasMatch("TextSpan(style: style, text: 'Hola')"),
        isTrue,
      );
      expect(
        _literalSpan.hasMatch(
          "TextSpan(\n  style: NbText.title,\n  text: 'Hola',\n)",
        ),
        isTrue,
      );
      expect(_literalSpan.hasMatch('TextSpan(text: label, style: s)'), isFalse);
      expect(
        _literalSpan.hasMatch('TextSpan(text: strings.appTitle)'),
        isFalse,
      );
      expect(
        _literalSpan.hasMatch('TextSpan(style: style, text: scene.title)'),
        isFalse,
      );
      expect(_literalSpan.hasMatch('TextSpan(children: spans)'), isFalse);
    });

    test('lib/src/ui does build TextSpans, so the check is not empty', () {
      final spans = [
        for (final file in _uiSources())
          ...RegExp(r'TextSpan\(').allMatches(file.readAsStringSync()),
      ];
      expect(spans, isNotEmpty);
    });

    test('no file in lib/src/ui builds a TextSpan from a literal', () {
      final offenders = <String>[];
      for (final file in _uiSources()) {
        final source = file.readAsStringSync();
        for (final match in _literalSpan.allMatches(source)) {
          final line = '\n'.allMatches(source.substring(0, match.start)).length;
          offenders.add('${file.path}:${line + 1}');
        }
      }
      expect(offenders, isEmpty);
    });
  });

  group('point 124: no Material Icons in lib/src/ui', () {
    test('the pattern catches Icons. and lets the own glyphs through', () {
      expect(_materialIcon.hasMatch('Icon(Icons.computer)'), isTrue);
      expect(
        _materialIcon.hasMatch('icon: const Icon(Icons.more_vert),'),
        isTrue,
      );
      expect(_materialIcon.hasMatch('Icons.smartphone'), isTrue);
      expect(_materialIcon.hasMatch('(Icons.send)'), isTrue);
      expect(_materialIcon.hasMatch('GlyphIcon(Glyphs.more)'), isFalse);
      expect(_materialIcon.hasMatch('CupertinoIcons.add'), isFalse);
      expect(_materialIcon.hasMatch('AppIcons.send'), isFalse);
      expect(_materialIcon.hasMatch('IconsTheme.of(context)'), isFalse);
      expect(_materialIcon.hasMatch('Glyphs.send'), isFalse);
    });

    test('lib/src/ui does draw its own glyphs, so the check is not empty', () {
      final glyphs = [
        for (final file in _uiSources())
          ...RegExp(r'GlyphIcon\(').allMatches(file.readAsStringSync()),
      ];
      expect(glyphs, isNotEmpty);
    });

    test('no file in lib/src/ui uses Icons.', () {
      final offenders = <String>[];
      for (final file in _uiSources()) {
        final source = file.readAsStringSync();
        for (final match in _materialIcon.allMatches(source)) {
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

  group('E858 the files of spec 008 take every text from AppStrings', () {
    final named = RegExp(
      r'''(?<![A-Za-z])(?:tooltip|label|message|title|semanticsLabel|hintText):\s*['"]''',
    );

    List<File> sources() {
      final sep = Platform.pathSeparator;
      final settings = Directory('lib${sep}src${sep}ui${sep}settings');
      final window = Directory('lib${sep}src${sep}window');
      return [
        for (final directory in [settings, window])
          for (final entity in directory.listSync(recursive: true))
            if (entity is File && entity.path.endsWith('.dart')) entity,
        File('lib${sep}src${sep}ui${sep}attention.dart'),
      ];
    }

    test('the scan covers the settings screen, its sections, attention and '
        'the window host', () {
      final names = sources().map((file) => file.uri.pathSegments.last).toSet();
      expect(
        names,
        containsAll([
          'settings_screen.dart',
          'settings_layer.dart',
          'device_name_section.dart',
          'appearance_section.dart',
          'language_section.dart',
          'receive_section.dart',
          'exclusions_section.dart',
          'system_tray_section.dart',
          'networks_section.dart',
          'ignored_section.dart',
          'inline_confirm.dart',
          'attention.dart',
          'window_host.dart',
          'method_channel_window_host.dart',
          'title_bar_sync.dart',
        ]),
      );
    });

    test('the named-argument pattern catches literals and lets AppStrings '
        'through', () {
      expect(named.hasMatch("tooltip: 'Ajustes'"), isTrue);
      expect(named.hasMatch('label: "Quitar"'), isTrue);
      expect(named.hasMatch('tooltip: strings.settingsButton'), isFalse);
      expect(named.hasMatch('label: widget.label'), isFalse);
    });

    test('no literal Text, TextSpan, Icons or named text argument', () {
      final offenders = <String>[];
      for (final file in sources()) {
        final source = file.readAsStringSync();
        for (final pattern in [
          _literalText,
          _literalSpan,
          _materialIcon,
          named,
        ]) {
          for (final match in pattern.allMatches(source)) {
            final line = RegExp(r'\n')
                .allMatches(source.substring(0, match.start))
                .length;
            offenders.add('${file.path}:${line + 1}');
          }
        }
      }
      expect(offenders, isEmpty);
    });

    test('the settings files read their texts from AppStringsDelegate', () {
      final sep = Platform.pathSeparator;
      for (final name in [
        'settings_screen.dart',
        'device_name_section.dart',
        'appearance_section.dart',
        'language_section.dart',
        'receive_section.dart',
        'exclusions_section.dart',
        'system_tray_section.dart',
        'networks_section.dart',
        'ignored_section.dart',
      ]) {
        final source = File('lib${sep}src${sep}ui${sep}settings$sep$name')
            .readAsStringSync();
        expect(source, contains('AppStringsDelegate.of('), reason: name);
      }
    });
  });
}
