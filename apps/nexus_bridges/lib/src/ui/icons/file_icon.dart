import 'package:flutter/material.dart';

import '../theme/app_theme.dart';
import 'glyphs.dart';
import 'svg_path.dart';

enum FileKind {
  pdf,
  sheet,
  doc,
  slides,
  archive,
  image,
  video,
  audio,
  code,
  program,
  other,
}

const Map<FileKind, String> fileKindLabels = {
  FileKind.pdf: 'PDF',
  FileKind.sheet: 'XLS',
  FileKind.doc: 'DOC',
  FileKind.slides: 'PPT',
  FileKind.archive: 'ZIP',
  FileKind.program: 'EXE',
  FileKind.code: '</>',
};

const Map<String, FileKind> _extensionKinds = {
  'pdf': FileKind.pdf,
  'xls': FileKind.sheet,
  'xlsx': FileKind.sheet,
  'csv': FileKind.sheet,
  'doc': FileKind.doc,
  'docx': FileKind.doc,
  'txt': FileKind.doc,
  'md': FileKind.doc,
  'ppt': FileKind.slides,
  'pptx': FileKind.slides,
  'zip': FileKind.archive,
  'rar': FileKind.archive,
  '7z': FileKind.archive,
  'png': FileKind.image,
  'jpg': FileKind.image,
  'jpeg': FileKind.image,
  'gif': FileKind.image,
  'webp': FileKind.image,
  'heic': FileKind.image,
  'mp4': FileKind.video,
  'mov': FileKind.video,
  'mkv': FileKind.video,
  'avi': FileKind.video,
  'mp3': FileKind.audio,
  'wav': FileKind.audio,
  'flac': FileKind.audio,
  'm4a': FileKind.audio,
  'js': FileKind.code,
  'ts': FileKind.code,
  'dart': FileKind.code,
  'html': FileKind.code,
  'css': FileKind.code,
  'json': FileKind.code,
  'py': FileKind.code,
  'exe': FileKind.program,
  'msi': FileKind.program,
  'bat': FileKind.program,
};

FileKind fileKindOf(String fileName, {bool isProgram = false}) {
  if (isProgram) return FileKind.program;
  final dot = fileName.lastIndexOf('.');
  if (dot <= 0 || dot == fileName.length - 1) return FileKind.other;
  return _extensionKinds[fileName.substring(dot + 1).toLowerCase()] ??
      FileKind.other;
}

const Color _filePdf = Color(0xFFDC3251);
const Color _fileExcel = Color(0xFF1EA885);
const Color _fileWord = Color(0xFF2F6FDE);
const Color _filePowerpoint = Color(0xFFE5683A);
const Color _fileZip = Color(0xFF8F8D8A);
const Color _fileImage = Color(0xFF12A3A3);
const Color _fileVideo = Color(0xFFD9457E);
const Color _fileAudio = Color(0xFFE0A20F);
const Color _fileCode = Color(0xFF56627A);
const Color _fileProgram = Color(0xFF5E5A6E);
const Color _fileOther = Color(0xFF9A97A6);
const Color _fileWhite = Color(0xFFFFFFFF);

Color _sheetColorOf(FileKind kind) => switch (kind) {
  FileKind.pdf => _filePdf,
  FileKind.sheet => _fileExcel,
  FileKind.doc => _fileWord,
  FileKind.slides => _filePowerpoint,
  FileKind.archive => _fileZip,
  FileKind.image => _fileImage,
  FileKind.video => _fileVideo,
  FileKind.audio => _fileAudio,
  FileKind.code => _fileCode,
  FileKind.program => _fileProgram,
  FileKind.other => _fileOther,
};

const double _boxWidth = 32;
const double _boxHeight = 38;

final Path fileSheetPath = parseSvgPath(
  'M4 2h17l7 7v25a2 2 0 0 1-2 2H4a2 2 0 0 1-2-2V4a2 2 0 0 1 2-2z',
);
final Path _foldPath = parseSvgPath('M21 2v5a2 2 0 0 0 2 2h5');

const Glyph _imagePictogram = Glyph(
  box: 16,
  strokeWidth: 1.5,
  parts: [
    GlyphPart(RectShape(Rect.fromLTWH(2, 3, 12, 10), 1.4)),
    GlyphPart(SvgShape('M2 11l3.5-3.2 2.8 2.5 2-1.8L14 12')),
    GlyphPart(CircleShape(Offset(10.6, 6), 1.1)),
  ],
);

const Glyph _videoPictogram = Glyph(
  box: 16,
  strokeWidth: 1.5,
  parts: [
    GlyphPart(RectShape(Rect.fromLTWH(1.5, 4, 9, 8), 1.4)),
    GlyphPart(SvgShape('M10.5 7.2l4-2.2v6l-4-2.2')),
  ],
);

const Glyph _audioPictogram = Glyph(
  box: 16,
  strokeWidth: 1.5,
  parts: [
    GlyphPart(SvgShape('M6 11.5V3.8l7-1.5v7.7')),
    GlyphPart(CircleShape(Offset(4.3, 11.6), 1.8)),
    GlyphPart(CircleShape(Offset(11.3, 10.1), 1.8)),
  ],
);

const Glyph _otherPictogram = Glyph(
  box: 16,
  strokeWidth: 1.5,
  parts: [GlyphPart(SvgShape('M3.5 4h9M3.5 7h9M3.5 10h9M3.5 13h5.5'))],
);

Glyph _pictogramOf(FileKind kind) => switch (kind) {
  FileKind.image => _imagePictogram,
  FileKind.video => _videoPictogram,
  FileKind.audio => _audioPictogram,
  _ => _otherPictogram,
};

void paintFileIcon(Canvas canvas, Rect rect, FileKind kind) {
  final scale = rect.height / _boxHeight;
  canvas.save();
  canvas.translate(rect.left + (rect.width - _boxWidth * scale) / 2, rect.top);
  canvas.scale(scale);

  canvas.drawPath(fileSheetPath, Paint()..color = _sheetColorOf(kind));
  canvas.drawPath(
    _foldPath,
    Paint()
      ..style = PaintingStyle.fill
      ..color = _fileWhite.withValues(alpha: 0.35),
  );

  final label = fileKindLabels[kind];
  if (label != null) {
    final painter = TextPainter(
      text: TextSpan(
        text: label,
        style: NbText.fileExt.copyWith(
          color: _fileWhite,
          fontSize: kind == FileKind.code ? 9 : null,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    final baseline = painter.computeDistanceToActualBaseline(
      TextBaseline.alphabetic,
    );
    painter.paint(canvas, Offset(15 - painter.width / 2, 28 - baseline));
    painter.dispose();
  } else {
    paintGlyph(
      canvas,
      _pictogramOf(kind),
      const Rect.fromLTWH(7, 15, 16, 16),
      _fileWhite,
    );
  }
  canvas.restore();
}

class FileIcon extends StatelessWidget {
  const FileIcon({
    required this.fileName,
    this.isProgram = false,
    this.height = 38,
    super.key,
  });

  final String fileName;
  final bool isProgram;
  final double height;

  @override
  Widget build(BuildContext context) {
    final kind = fileKindOf(fileName, isProgram: isProgram);
    return ExcludeSemantics(
      child: CustomPaint(
        size: Size(height * _boxWidth / _boxHeight, height),
        painter: _FileIconPainter(kind),
      ),
    );
  }
}

class _FileIconPainter extends CustomPainter {
  const _FileIconPainter(this.kind);

  final FileKind kind;

  @override
  void paint(Canvas canvas, Size size) {
    paintFileIcon(canvas, Offset.zero & size, kind);
  }

  @override
  bool shouldRepaint(_FileIconPainter oldDelegate) => oldDelegate.kind != kind;
}
