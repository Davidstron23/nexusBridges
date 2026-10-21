import 'dart:ffi';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:win32/win32.dart';

import 'identity.dart';

const int _uiForbidden = 0x1;

final class DpapiSecretProtector implements SecretProtector {
  @override
  Uint8List protect(Uint8List data) {
    return using((arena) {
      final input = arena<CRYPT_INTEGER_BLOB>();
      final output = arena<CRYPT_INTEGER_BLOB>();
      input.ref
        ..cbData = data.length
        ..pbData = _copyToNative(arena, data);

      final Win32Result(:value, :error) = CryptProtectData(
        input,
        null,
        null,
        null,
        _uiForbidden,
        output,
      );
      if (!value) throw StateError('DPAPI protect failed: $error');
      return _takeOutput(output);
    });
  }

  @override
  Uint8List? unprotect(Uint8List data) {
    try {
      return using((arena) {
        final input = arena<CRYPT_INTEGER_BLOB>();
        final output = arena<CRYPT_INTEGER_BLOB>();
        input.ref
          ..cbData = data.length
          ..pbData = _copyToNative(arena, data);

        final Win32Result(:value) = CryptUnprotectData(
          input,
          null,
          null,
          null,
          _uiForbidden,
          output,
        );
        return value ? _takeOutput(output) : null;
      });
    } catch (_) {
      return null;
    }
  }
}

Pointer<Uint8> _copyToNative(Arena arena, Uint8List data) {
  final pointer = arena<Uint8>(data.isEmpty ? 1 : data.length);
  pointer.asTypedList(data.length).setAll(0, data);
  return pointer;
}

Uint8List _takeOutput(Pointer<CRYPT_INTEGER_BLOB> output) {
  final blob = output.ref;
  final copy = Uint8List.fromList(blob.pbData.asTypedList(blob.cbData));
  LocalFree(HLOCAL(blob.pbData.cast()));
  return copy;
}
