import 'dart:ffi';

import 'package:ffi/ffi.dart';

typedef _CreateFileN = IntPtr Function(
  Pointer<Utf16>,
  Uint32,
  Uint32,
  Pointer<Void>,
  Uint32,
  Uint32,
  IntPtr,
);
typedef _CreateFileD = int Function(
  Pointer<Utf16>,
  int,
  int,
  Pointer<Void>,
  int,
  int,
  int,
);
typedef _IoctlN = Int32 Function(
  IntPtr,
  Uint32,
  Pointer<Void>,
  Uint32,
  Pointer<Void>,
  Uint32,
  Pointer<Uint32>,
  Pointer<Void>,
);
typedef _IoctlD = int Function(
  int,
  int,
  Pointer<Void>,
  int,
  Pointer<Void>,
  int,
  Pointer<Uint32>,
  Pointer<Void>,
);
typedef _CloseN = Int32 Function(IntPtr);
typedef _CloseD = int Function(int);
typedef _LastN = Uint32 Function();
typedef _LastD = int Function();

final DynamicLibrary _k32 = DynamicLibrary.open('kernel32.dll');
final _CreateFileD _createFile = _k32
    .lookupFunction<_CreateFileN, _CreateFileD>('CreateFileW');
final _IoctlD _ioctl = _k32.lookupFunction<_IoctlN, _IoctlD>('DeviceIoControl');
final _CloseD _close = _k32.lookupFunction<_CloseN, _CloseD>('CloseHandle');
final _LastD _lastError = _k32.lookupFunction<_LastN, _LastD>('GetLastError');

const int genericWrite = 0x40000000;
const int writeAttributesOnly = 0x100 | 0x00100000;

String turnIntoJunction(
  String folder,
  String target, {
  int access = genericWrite,
}) {
  return using((arena) {
    final handle = _createFile(
      folder.toNativeUtf16(allocator: arena),
      access,
      7,
      nullptr,
      3,
      0x02000000 | 0x00200000,
      0,
    );
    if (handle == -1 || handle == 0) return 'open failed ${_lastError()}';
    try {
      final substitute = '\\??\\$target';
      final printName = target;
      final pathBytes = (substitute.length + 1 + printName.length + 1) * 2;
      final dataLength = 8 + pathBytes;
      final total = 8 + dataLength;
      final buffer = arena<Uint8>(total);
      final words = buffer.cast<Uint32>();
      final halves = buffer.cast<Uint16>();
      words[0] = 0xA0000003;
      halves[2] = dataLength;
      halves[5] = substitute.length * 2;
      halves[6] = (substitute.length + 1) * 2;
      halves[7] = printName.length * 2;
      final path = (buffer + 16).cast<Uint16>();
      var i = 0;
      for (final unit in substitute.codeUnits) {
        path[i++] = unit;
      }
      path[i++] = 0;
      for (final unit in printName.codeUnits) {
        path[i++] = unit;
      }
      path[i++] = 0;
      final returned = arena<Uint32>();
      final done = _ioctl(
        handle,
        0x000900A4,
        buffer.cast<Void>(),
        total,
        nullptr,
        0,
        returned,
        nullptr,
      );
      return done != 0 ? 'ok' : 'ioctl failed ${_lastError()}';
    } finally {
      _close(handle);
    }
  });
}
