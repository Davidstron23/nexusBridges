import 'package:flutter/material.dart';

import 'svg_path.dart';

const Color _folderBack = Color(0xFFD18E22);
const Color _folderFront = Color(0xFFF2B33D);
const Color _folderEdge = Color(0x40FFFFFF);

const double _boxWidth = 32;
const double _boxHeight = 38;

final Path _backPath = parseSvgPath(
  'M2 9a3 3 0 0 1 3-3h7.5l3 3.2H27a3 3 0 0 1 3 3V31a3 3 0 0 1-3 3H5a3 3 0 0 1-3-3z',
);
final Path _frontPath = parseSvgPath(
  'M2 14.5a3 3 0 0 1 3-3h22a3 3 0 0 1 3 3V31a3 3 0 0 1-3 3H5a3 3 0 0 1-3-3z',
);
final Path _edgePath = parseSvgPath('M2 17h28');

void paintFolderIcon(Canvas canvas, Rect rect) {
  final scale = rect.height / _boxHeight;
  canvas.save();
  canvas.translate(rect.left, rect.top);
  canvas.scale(scale);
  canvas.drawPath(_backPath, Paint()..color = _folderBack);
  canvas.drawPath(_frontPath, Paint()..color = _folderFront);
  canvas.drawPath(
    _edgePath,
    Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1
      ..color = _folderEdge,
  );
  canvas.restore();
}

class FolderIcon extends StatelessWidget {
  const FolderIcon({this.height = 38, super.key});

  final double height;

  @override
  Widget build(BuildContext context) {
    return ExcludeSemantics(
      child: CustomPaint(
        size: Size(height * _boxWidth / _boxHeight, height),
        painter: const _FolderIconPainter(),
      ),
    );
  }
}

class _FolderIconPainter extends CustomPainter {
  const _FolderIconPainter();

  @override
  void paint(Canvas canvas, Size size) {
    paintFolderIcon(canvas, Offset.zero & size);
  }

  @override
  bool shouldRepaint(_FolderIconPainter oldDelegate) => false;
}
