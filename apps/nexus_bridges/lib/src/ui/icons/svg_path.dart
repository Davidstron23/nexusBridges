import 'dart:ui';

const String _supportedCommands = 'MmLlHhVvCcAaZz';

Path parseSvgPath(String data) {
  final reader = _PathReader(data);
  final path = Path();
  reader.skipSeparators();
  if (reader.atEnd) return path;

  var command = '';
  var x = 0.0;
  var y = 0.0;
  var startX = 0.0;
  var startY = 0.0;

  while (true) {
    reader.skipSeparators();
    if (reader.atEnd) break;

    if (reader.peekIsLetter) {
      final position = reader.position;
      final letter = reader.next();
      if (!_supportedCommands.contains(letter)) {
        throw FormatException(
          'Unsupported path command "$letter" at position $position',
          data,
          position,
        );
      }
      if (command.isEmpty && letter != 'M' && letter != 'm') {
        throw FormatException(
          'A path must start with M or m, found "$letter" at position '
          '$position',
          data,
          position,
        );
      }
      command = letter;
      if (command == 'Z' || command == 'z') {
        path.close();
        x = startX;
        y = startY;
        continue;
      }
    } else {
      if (command.isEmpty) {
        throw FormatException(
          'A path must start with M or m, found a number at position '
          '${reader.position}',
          data,
          reader.position,
        );
      }
      if (command == 'Z' || command == 'z') {
        throw FormatException(
          'Unexpected number after a close command at position '
          '${reader.position}',
          data,
          reader.position,
        );
      }
    }

    switch (command) {
      case 'M':
        final nx = reader.number();
        final ny = reader.number();
        path.moveTo(nx, ny);
        x = startX = nx;
        y = startY = ny;
        command = 'L';
      case 'm':
        final dx = reader.number();
        final dy = reader.number();
        path.relativeMoveTo(dx, dy);
        x = startX = x + dx;
        y = startY = y + dy;
        command = 'l';
      case 'L':
        final nx = reader.number();
        final ny = reader.number();
        path.lineTo(nx, ny);
        x = nx;
        y = ny;
      case 'l':
        final dx = reader.number();
        final dy = reader.number();
        path.relativeLineTo(dx, dy);
        x += dx;
        y += dy;
      case 'H':
        final nx = reader.number();
        path.lineTo(nx, y);
        x = nx;
      case 'h':
        final dx = reader.number();
        path.relativeLineTo(dx, 0);
        x += dx;
      case 'V':
        final ny = reader.number();
        path.lineTo(x, ny);
        y = ny;
      case 'v':
        final dy = reader.number();
        path.relativeLineTo(0, dy);
        y += dy;
      case 'C':
        final x1 = reader.number();
        final y1 = reader.number();
        final x2 = reader.number();
        final y2 = reader.number();
        final nx = reader.number();
        final ny = reader.number();
        path.cubicTo(x1, y1, x2, y2, nx, ny);
        x = nx;
        y = ny;
      case 'c':
        final x1 = reader.number();
        final y1 = reader.number();
        final x2 = reader.number();
        final y2 = reader.number();
        final dx = reader.number();
        final dy = reader.number();
        path.relativeCubicTo(x1, y1, x2, y2, dx, dy);
        x += dx;
        y += dy;
      case 'A':
        final rx = reader.number();
        final ry = reader.number();
        final rotation = reader.number();
        final large = reader.flag();
        final sweep = reader.flag();
        final nx = reader.number();
        final ny = reader.number();
        if (rx == 0 || ry == 0) {
          path.lineTo(nx, ny);
        } else {
          path.arcToPoint(
            Offset(nx, ny),
            radius: Radius.elliptical(rx.abs(), ry.abs()),
            rotation: rotation,
            largeArc: large == 1,
            clockwise: sweep == 1,
          );
        }
        x = nx;
        y = ny;
      case 'a':
        final rx = reader.number();
        final ry = reader.number();
        final rotation = reader.number();
        final large = reader.flag();
        final sweep = reader.flag();
        final dx = reader.number();
        final dy = reader.number();
        if (rx == 0 || ry == 0) {
          path.relativeLineTo(dx, dy);
        } else {
          path.relativeArcToPoint(
            Offset(dx, dy),
            radius: Radius.elliptical(rx.abs(), ry.abs()),
            rotation: rotation,
            largeArc: large == 1,
            clockwise: sweep == 1,
          );
        }
        x += dx;
        y += dy;
    }
  }
  return path;
}

final class _PathReader {
  _PathReader(this._data);

  final String _data;
  int _index = 0;

  int get position => _index;

  bool get atEnd => _index >= _data.length;

  bool get peekIsLetter {
    final unit = _data.codeUnitAt(_index);
    return (unit >= 0x41 && unit <= 0x5A) || (unit >= 0x61 && unit <= 0x7A);
  }

  String next() => _data[_index++];

  void skipSeparators() {
    while (_index < _data.length) {
      final unit = _data.codeUnitAt(_index);
      if (unit == 0x20 ||
          unit == 0x2C ||
          unit == 0x09 ||
          unit == 0x0A ||
          unit == 0x0D) {
        _index++;
      } else {
        break;
      }
    }
  }

  int flag() {
    skipSeparators();
    if (atEnd) {
      throw FormatException(
        'Expected an arc flag at position $_index',
        _data,
        _index,
      );
    }
    final unit = _data.codeUnitAt(_index);
    if (unit != 0x30 && unit != 0x31) {
      throw FormatException(
        'Expected an arc flag (0 or 1) at position $_index',
        _data,
        _index,
      );
    }
    _index++;
    return unit - 0x30;
  }

  double number() {
    skipSeparators();
    final begin = _index;
    var cursor = _index;
    if (cursor < _data.length && _isSign(_data.codeUnitAt(cursor))) cursor++;
    final integerStart = cursor;
    while (cursor < _data.length && _isDigit(_data.codeUnitAt(cursor))) {
      cursor++;
    }
    final integerDigits = cursor - integerStart;
    var fractionDigits = 0;
    if (cursor < _data.length && _data.codeUnitAt(cursor) == 0x2E) {
      cursor++;
      final fractionStart = cursor;
      while (cursor < _data.length && _isDigit(_data.codeUnitAt(cursor))) {
        cursor++;
      }
      fractionDigits = cursor - fractionStart;
    }
    if (integerDigits == 0 && fractionDigits == 0) {
      throw FormatException(
        'Expected a number at position $begin',
        _data,
        begin,
      );
    }
    if (cursor < _data.length &&
        (_data.codeUnitAt(cursor) == 0x65 ||
            _data.codeUnitAt(cursor) == 0x45)) {
      var exponent = cursor + 1;
      if (exponent < _data.length && _isSign(_data.codeUnitAt(exponent))) {
        exponent++;
      }
      final digitsStart = exponent;
      while (exponent < _data.length && _isDigit(_data.codeUnitAt(exponent))) {
        exponent++;
      }
      if (exponent == digitsStart) {
        throw FormatException(
          'Expected exponent digits at position $exponent',
          _data,
          exponent,
        );
      }
      cursor = exponent;
    }
    _index = cursor;
    return double.parse(_data.substring(begin, cursor));
  }

  static bool _isDigit(int unit) => unit >= 0x30 && unit <= 0x39;

  static bool _isSign(int unit) => unit == 0x2B || unit == 0x2D;
}
