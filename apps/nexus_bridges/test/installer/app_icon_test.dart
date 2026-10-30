import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

const String _iconPath = 'windows/runner/resources/app_icon.ico';
const String _resourcePath = 'windows/runner/Runner.rc';

const int _headerSize = 6;
const int _entrySize = 16;
const int _imageCount = 7;

int _entry(int index) => _headerSize + _entrySize * index;

void main() {
  late Uint8List bytes;
  late ByteData data;

  setUpAll(() {
    bytes = File(_iconPath).readAsBytesSync();
    data = ByteData.sublistView(bytes);
  });

  group('E255: the window icon is the one of the design', () {
    test('the header is an icon: reserved 0 and type 1', () {
      expect(bytes.length, greaterThan(_headerSize));
      expect(data.getUint16(0, Endian.little), 0);
      expect(data.getUint16(2, Endian.little), 1);
    });

    test('it holds 7 images and room for their entries', () {
      expect(data.getUint16(4, Endian.little), _imageCount);
      expect(bytes.length, greaterThan(_entry(_imageCount)));
    });

    test('the widths are 16, 24, 32, 48, 64, 128 and 256, written as 0', () {
      final widths = [for (var i = 0; i < _imageCount; i++) bytes[_entry(i)]];
      expect(widths, hasLength(_imageCount));
      expect(widths.toSet(), {16, 24, 32, 48, 64, 128, 0});
    });

    test('every image is square', () {
      for (var i = 0; i < _imageCount; i++) {
        expect(bytes[_entry(i) + 1], bytes[_entry(i)], reason: 'image $i');
      }
    });

    test('every image lies inside the file, after the entries', () {
      for (var i = 0; i < _imageCount; i++) {
        final size = data.getUint32(_entry(i) + 8, Endian.little);
        final offset = data.getUint32(_entry(i) + 12, Endian.little);
        expect(size, greaterThan(0), reason: 'image $i');
        expect(offset, greaterThanOrEqualTo(_entry(_imageCount)));
        expect(offset + size, lessThanOrEqualTo(bytes.length));
      }
    });

    test('the runner resources still point to this icon', () {
      final resources = File(_resourcePath).readAsStringSync();
      expect(
        resources.contains(
          RegExp(r'IDI_APP_ICON\s+ICON\s+"resources\\\\app_icon\.ico"'),
        ),
        isTrue,
      );
    });
  });
}
