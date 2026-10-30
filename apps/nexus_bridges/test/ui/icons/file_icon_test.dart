import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nexus_bridges/src/l10n/app_strings.dart';
import 'package:nexus_bridges/src/ui/icons/file_icon.dart';
import 'package:nexus_bridges/src/ui/theme/app_theme.dart';

const Map<FileKind, List<String>> _extensions = {
  FileKind.pdf: ['pdf'],
  FileKind.sheet: ['xls', 'xlsx', 'csv'],
  FileKind.doc: ['doc', 'docx', 'txt', 'md'],
  FileKind.slides: ['ppt', 'pptx'],
  FileKind.archive: ['zip', 'rar', '7z'],
  FileKind.image: ['png', 'jpg', 'jpeg', 'gif', 'webp', 'heic'],
  FileKind.video: ['mp4', 'mov', 'mkv', 'avi'],
  FileKind.audio: ['mp3', 'wav', 'flac', 'm4a'],
  FileKind.code: ['js', 'ts', 'dart', 'html', 'css', 'json', 'py'],
  FileKind.program: ['exe', 'msi', 'bat'],
};

const Map<FileKind, Color> _designColors = {
  FileKind.pdf: Color(0xFFDC3251),
  FileKind.sheet: Color(0xFF1EA885),
  FileKind.doc: Color(0xFF2F6FDE),
  FileKind.slides: Color(0xFFE5683A),
  FileKind.archive: Color(0xFF8F8D8A),
  FileKind.image: Color(0xFF12A3A3),
  FileKind.video: Color(0xFFD9457E),
  FileKind.audio: Color(0xFFE0A20F),
  FileKind.code: Color(0xFF56627A),
  FileKind.program: Color(0xFF5E5A6E),
  FileKind.other: Color(0xFF9A97A6),
};

const Map<FileKind, String> _sampleNames = {
  FileKind.pdf: 'factura.pdf',
  FileKind.sheet: 'cuentas.xlsx',
  FileKind.doc: 'notas.md',
  FileKind.slides: 'charla.pptx',
  FileKind.archive: 'repo.zip',
  FileKind.image: 'foto.jpg',
  FileKind.video: 'clip.mp4',
  FileKind.audio: 'tema.flac',
  FileKind.code: 'main.dart',
  FileKind.program: 'setup.msi',
  FileKind.other: 'datos.bin',
};

const Set<FileKind> _pictogramKinds = {
  FileKind.image,
  FileKind.video,
  FileKind.audio,
  FileKind.other,
};

const Color _white = Color(0xFFFFFFFF);

Future<void> _pump(
  WidgetTester tester,
  Widget child, {
  Brightness brightness = Brightness.light,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      supportedLocales: const [Locale('en'), Locale('es')],
      localizationsDelegates: const [
        AppStringsDelegate(),
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      theme: buildTheme(brightness),
      themeAnimationDuration: Duration.zero,
      home: Scaffold(body: Center(child: child)),
    ),
  );
  await tester.pump();
}

RenderObject _painterOf(WidgetTester tester, Finder owner) =>
    tester.renderObject(
      find.descendant(of: owner, matching: find.byType(CustomPaint)).first,
    );

void main() {
  group('E259: fileKindOf', () {
    for (final entry in _extensions.entries) {
      test('${entry.value.join(', ')} are ${entry.key.name}', () {
        for (final extension in entry.value) {
          expect(fileKindOf('archivo.$extension'), entry.key);
          expect(fileKindOf('archivo.${extension.toUpperCase()}'), entry.key);
        }
      });
    }

    test('every kind of the table except other is reachable by extension', () {
      expect(
        _extensions.keys.toSet(),
        FileKind.values.where((kind) => kind != FileKind.other).toSet(),
      );
    });

    test('the extension is read in any case', () {
      expect(fileKindOf('A.PDF'), FileKind.pdf);
      expect(fileKindOf('Foto.JpEg'), FileKind.image);
      expect(fileKindOf('BACKUP.7Z'), FileKind.archive);
    });

    test('only the text after the last dot counts', () {
      expect(fileKindOf('factura.pdf.exe'), FileKind.program);
      expect(fileKindOf('setup.exe.pdf'), FileKind.pdf);
      expect(fileKindOf('copia.tar.gz'), FileKind.other);
      expect(fileKindOf('v1.2.final.docx'), FileKind.doc);
    });

    test('names without a usable extension are other', () {
      expect(fileKindOf('notas'), FileKind.other);
      expect(fileKindOf('.oculto'), FileKind.other);
      expect(fileKindOf('.pdf'), FileKind.other);
      expect(fileKindOf('a.'), FileKind.other);
      expect(fileKindOf('informe.pdf.'), FileKind.other);
      expect(fileKindOf(''), FileKind.other);
      expect(fileKindOf('.'), FileKind.other);
      expect(fileKindOf('x.ps1'), FileKind.other);
      expect(fileKindOf('datos.xyz'), FileKind.other);
    });

    test('isProgram wins over the extension', () {
      expect(fileKindOf('x.ps1', isProgram: true), FileKind.program);
      expect(fileKindOf('informe.pdf', isProgram: true), FileKind.program);
      expect(fileKindOf('notas', isProgram: true), FileKind.program);
      expect(fileKindOf('.oculto', isProgram: true), FileKind.program);
    });
  });

  group('E259: fileKindLabels', () {
    test('seven kinds carry an acronym and the rest a pictogram', () {
      expect(fileKindLabels, const {
        FileKind.pdf: 'PDF',
        FileKind.sheet: 'XLS',
        FileKind.doc: 'DOC',
        FileKind.slides: 'PPT',
        FileKind.archive: 'ZIP',
        FileKind.program: 'EXE',
        FileKind.code: '</>',
      });
      expect(
        FileKind.values.where((kind) => !fileKindLabels.containsKey(kind)),
        unorderedEquals(_pictogramKinds),
      );
    });
  });

  group('E259: paintFileIcon', () {
    for (final kind in FileKind.values) {
      test('${kind.name} paints the sheet in its DESIGN.md color', () {
        final canvas = TestRecordingCanvas();
        paintFileIcon(canvas, const Rect.fromLTWH(0, 0, 32, 38), kind);
        expect(canvas.getSaveCount(), 0);
        final paths = [
          for (final call in canvas.invocations)
            if (call.invocation.memberName == #drawPath)
              call.invocation.positionalArguments,
        ];
        final sheet = paths[0];
        expect(
          (sheet[1] as Paint).color.toARGB32(),
          _designColors[kind]!.toARGB32(),
        );
        expect((sheet[1] as Paint).style, PaintingStyle.fill);
        final sheetPath = sheet[0] as Path;
        expect(sheetPath.contains(const Offset(15, 20)), isTrue);
        expect(sheetPath.contains(const Offset(27, 3)), isFalse);
        final fold = paths[1];
        expect((fold[1] as Paint).style, PaintingStyle.fill);
        expect(
          (fold[1] as Paint).color.toARGB32(),
          _white.withValues(alpha: 0.35).toARGB32(),
        );
        final paragraphs = canvas.invocations.where(
          (call) => call.invocation.memberName == #drawParagraph,
        );
        if (_pictogramKinds.contains(kind)) {
          expect(paragraphs, isEmpty);
          final pictogram = paths.skip(2).toList();
          expect(pictogram, isNotEmpty);
          for (final part in pictogram) {
            final paint = part[1] as Paint;
            expect(paint.color.toARGB32(), _white.toARGB32());
            expect(paint.style, PaintingStyle.stroke);
            expect(paint.strokeWidth, closeTo(1.5, 1e-6));
          }
        } else {
          expect(paragraphs, hasLength(1));
          expect(paths, hasLength(2));
        }
      });
    }

    test('the 32 x 38 box is scaled to the height of the rect', () {
      final canvas = TestRecordingCanvas();
      paintFileIcon(canvas, const Rect.fromLTWH(5, 7, 64, 76), FileKind.pdf);
      final calls = [
        for (final call in canvas.invocations)
          if (call.invocation.memberName == #translate ||
              call.invocation.memberName == #scale)
            call.invocation,
      ];
      expect(calls[0].memberName, #translate);
      expect(calls[0].positionalArguments.take(2), [5.0, 7.0]);
      expect(calls[1].memberName, #scale);
      expect(calls[1].positionalArguments.first, 2.0);
    });

    test('the pictogram is a 16 px glyph moved to (7, 15)', () {
      final canvas = TestRecordingCanvas();
      paintFileIcon(canvas, const Rect.fromLTWH(0, 0, 32, 38), FileKind.other);
      final translations = [
        for (final call in canvas.invocations)
          if (call.invocation.memberName == #translate)
            call.invocation.positionalArguments.take(2).toList(),
      ];
      expect(translations, contains(equals([7.0, 15.0])));
    });
  });

  group('E259: FileIcon', () {
    for (final brightness in Brightness.values) {
      for (final height in [24.0, 38.0]) {
        testWidgets('every kind at $height px in ${brightness.name}', (
          tester,
        ) async {
          await _pump(
            tester,
            Wrap(
              children: [
                for (final kind in FileKind.values)
                  FileIcon(
                    fileName: _sampleNames[kind]!,
                    height: height,
                    key: ValueKey(kind),
                  ),
              ],
            ),
            brightness: brightness,
          );
          expect(tester.takeException(), isNull);
          for (final kind in FileKind.values) {
            final icon = find.byKey(ValueKey(kind));
            expect(tester.getSize(icon), Size(height * 32 / 38, height));
            expect(
              _painterOf(tester, icon),
              paints..path(color: _designColors[kind]),
            );
          }
        });
      }
    }

    testWidgets('the default height is 38', (tester) async {
      await _pump(tester, const FileIcon(fileName: 'a.pdf'));
      expect(tester.getSize(find.byType(FileIcon)), const Size(32, 38));
    });

    testWidgets('isProgram paints the program sheet', (tester) async {
      await _pump(
        tester,
        const FileIcon(fileName: 'script.ps1', isProgram: true),
      );
      expect(
        _painterOf(tester, find.byType(FileIcon)),
        paints..path(color: _designColors[FileKind.program]),
      );
    });

    testWidgets('a program disguised as a pdf shows as a program', (
      tester,
    ) async {
      await _pump(tester, const FileIcon(fileName: 'factura.pdf.exe'));
      expect(
        _painterOf(tester, find.byType(FileIcon)),
        paints..path(color: _designColors[FileKind.program]),
      );
    });

    testWidgets('the icon is decorative', (tester) async {
      final handle = tester.ensureSemantics();
      await _pump(
        tester,
        Semantics(
          container: true,
          label: 'host',
          child: const FileIcon(fileName: 'a.pdf'),
        ),
      );
      final node = tester.getSemantics(find.byType(FileIcon));
      expect(node.label, 'host');
      expect(node.childrenCount, 0);
      handle.dispose();
    });
  });
}
