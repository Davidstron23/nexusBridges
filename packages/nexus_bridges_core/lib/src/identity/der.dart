import 'dart:convert';
import 'dart:typed_data';

FormatException _invalid() => const FormatException('invalid DER');

final class DerElement {
  const DerElement({
    required this.tag,
    required this.start,
    required this.headerLength,
    required this.length,
  });

  final int tag;

  final int start;

  final int headerLength;

  final int length;

  int get valueStart => start + headerLength;

  int get end => valueStart + length;
}

DerElement readDerElement(Uint8List source, int offset, int limit) {
  if (offset < 0 || limit > source.length || offset + 2 > limit) {
    throw _invalid();
  }
  final tag = source[offset];
  if (tag & 0x1F == 0x1F) throw _invalid();
  final first = source[offset + 1];
  final int length;
  final int headerLength;
  if (first < 0x80) {
    length = first;
    headerLength = 2;
  } else {
    final count = first & 0x7F;
    if (count < 1 || count > 3 || offset + 2 + count > limit) throw _invalid();
    var value = 0;
    for (var i = 0; i < count; i++) {
      value = (value << 8) | source[offset + 2 + i];
    }
    if (source[offset + 2] == 0 || value < 0x80) throw _invalid();
    length = value;
    headerLength = 2 + count;
  }
  if (offset + headerLength + length > limit) throw _invalid();
  return DerElement(
    tag: tag,
    start: offset,
    headerLength: headerLength,
    length: length,
  );
}

List<DerElement> readDerChildren(Uint8List source, DerElement parent) {
  final children = <DerElement>[];
  var offset = parent.valueStart;
  while (offset < parent.end) {
    final child = readDerElement(source, offset, parent.end);
    children.add(child);
    offset = child.end;
  }
  if (offset != parent.end) throw _invalid();
  return children;
}

Uint8List derBytes(Uint8List source, DerElement element) =>
    Uint8List.fromList(source.sublist(element.start, element.end));

Uint8List derValue(Uint8List source, DerElement element) =>
    Uint8List.fromList(source.sublist(element.valueStart, element.end));

const int _tagInteger = 0x02;
const int _tagBitString = 0x03;
const int _tagOid = 0x06;
const int _tagUtf8String = 0x0C;
const int _tagSequence = 0x30;
const int _tagSet = 0x31;
const int _tagPrintableString = 0x13;
const int _tagUtcTime = 0x17;
const int _tagGeneralizedTime = 0x18;
const int _tagContextExplicit = 0xA0;

Uint8List _derLength(int length) {
  if (length < 0x80) return Uint8List.fromList([length]);
  if (length < 0x100) return Uint8List.fromList([0x81, length]);
  if (length < 0x10000) {
    return Uint8List.fromList([0x82, length >> 8, length & 0xFF]);
  }
  if (length < 0x1000000) {
    return Uint8List.fromList([
      0x83,
      length >> 16,
      (length >> 8) & 0xFF,
      length & 0xFF,
    ]);
  }
  throw ArgumentError.value(length, 'length', 'too long');
}

Uint8List _tlv(int tag, List<int> content) {
  final length = _derLength(content.length);
  final out = Uint8List(1 + length.length + content.length);
  out[0] = tag;
  out.setRange(1, 1 + length.length, length);
  out.setRange(1 + length.length, out.length, content);
  return out;
}

Uint8List _concat(List<Uint8List> items) {
  final builder = BytesBuilder(copy: false);
  for (final item in items) {
    builder.add(item);
  }
  return builder.takeBytes();
}

Uint8List derSequence(List<Uint8List> items) =>
    _tlv(_tagSequence, _concat(items));

Uint8List derSet(List<Uint8List> items) => _tlv(_tagSet, _concat(items));

Uint8List derInteger(Uint8List magnitude) {
  var first = 0;
  while (first < magnitude.length - 1 && magnitude[first] == 0) {
    first++;
  }
  final digits = magnitude.isEmpty
      ? Uint8List.fromList([0])
      : Uint8List.sublistView(magnitude, first);
  if (digits[0] & 0x80 != 0) {
    return _tlv(_tagInteger, [0x00, ...digits]);
  }
  return _tlv(_tagInteger, digits);
}

Uint8List derIntegerFromBigInt(BigInt value) {
  if (value.isNegative) {
    throw ArgumentError.value(value, 'value', 'must not be negative');
  }
  if (value == BigInt.zero) return derInteger(Uint8List.fromList([0]));
  final bytes = <int>[];
  var rest = value;
  while (rest > BigInt.zero) {
    bytes.add((rest & BigInt.from(0xFF)).toInt());
    rest = rest >> 8;
  }
  return derInteger(Uint8List.fromList(bytes.reversed.toList()));
}

Uint8List derOid(List<int> encoded) => _tlv(_tagOid, encoded);

Uint8List derPrintable(String value) =>
    _tlv(_tagPrintableString, ascii.encode(value));

Uint8List derUtf8(String value) => _tlv(_tagUtf8String, utf8.encode(value));

Uint8List derUtcTime(String value) => _tlv(_tagUtcTime, ascii.encode(value));

Uint8List derGeneralizedTime(String value) =>
    _tlv(_tagGeneralizedTime, ascii.encode(value));

Uint8List derBitString(Uint8List bytes) =>
    _tlv(_tagBitString, [0x00, ...bytes]);

Uint8List derExplicit(int tag, Uint8List content) {
  final number = tag & 0x1F;
  if (number == 0x1F) throw ArgumentError.value(tag, 'tag', 'not supported');
  return _tlv(_tagContextExplicit | number, content);
}
