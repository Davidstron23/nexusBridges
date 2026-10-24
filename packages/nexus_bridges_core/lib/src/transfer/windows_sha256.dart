import 'dart:ffi';

import 'package:ffi/ffi.dart';

import 'hashing.dart' show Sha256Stream;

const int _hashChunkBytes = 1048576;
const int _digestBytes = 32;

typedef _OpenProviderNative = Int32 Function(
  Pointer<IntPtr>,
  Pointer<Utf16>,
  Pointer<Utf16>,
  Uint32,
);

typedef _OpenProvider = int Function(
  Pointer<IntPtr>,
  Pointer<Utf16>,
  Pointer<Utf16>,
  int,
);

typedef _CreateHashNative = Int32 Function(
  IntPtr,
  Pointer<IntPtr>,
  Pointer<Uint8>,
  Uint32,
  Pointer<Uint8>,
  Uint32,
  Uint32,
);

typedef _CreateHash = int Function(
  int,
  Pointer<IntPtr>,
  Pointer<Uint8>,
  int,
  Pointer<Uint8>,
  int,
  int,
);

typedef _HashDataNative = Int32 Function(
  IntPtr,
  Pointer<Uint8>,
  Uint32,
  Uint32,
);

typedef _HashData = int Function(int, Pointer<Uint8>, int, int);

typedef _FinishHashNative = Int32 Function(
  IntPtr,
  Pointer<Uint8>,
  Uint32,
  Uint32,
);

typedef _FinishHash = int Function(int, Pointer<Uint8>, int, int);

typedef _DestroyHashNative = Int32 Function(IntPtr);

typedef _DestroyHash = int Function(int);

final class _Cng {
  _Cng({
    required this.provider,
    required this.createHash,
    required this.hashData,
    required this.finishHash,
    required this.destroyHash,
  });

  final int provider;
  final _CreateHash createHash;
  final _HashData hashData;
  final _FinishHash finishHash;
  final _DestroyHash destroyHash;
}

_Cng? _cng;
bool _cngLoaded = false;

_Cng? _loadCng() {
  if (_cngLoaded) return _cng;
  _cngLoaded = true;
  try {
    final library = DynamicLibrary.open('bcrypt.dll');
    final open = library.lookupFunction<_OpenProviderNative, _OpenProvider>(
      'BCryptOpenAlgorithmProvider',
    );
    final create = library.lookupFunction<_CreateHashNative, _CreateHash>(
      'BCryptCreateHash',
    );
    final data = library.lookupFunction<_HashDataNative, _HashData>(
      'BCryptHashData',
    );
    final finish = library.lookupFunction<_FinishHashNative, _FinishHash>(
      'BCryptFinishHash',
    );
    final destroy = library.lookupFunction<_DestroyHashNative, _DestroyHash>(
      'BCryptDestroyHash',
    );
    final provider = using((arena) {
      final handle = arena<IntPtr>();
      final status = open(
        handle,
        'SHA256'.toNativeUtf16(allocator: arena),
        nullptr,
        0,
      );
      return status == 0 ? handle.value : 0;
    });
    if (provider == 0) return null;
    return _cng = _Cng(
      provider: provider,
      createHash: create,
      hashData: data,
      finishHash: finish,
      destroyHash: destroy,
    );
  } catch (_) {
    return null;
  }
}

Sha256Stream? startWindowsSha256() {
  try {
    final cng = _loadCng();
    if (cng == null) return null;
    return _WindowsSha256._start(cng);
  } catch (_) {
    return null;
  }
}

final class _WindowsSha256 implements Sha256Stream {
  _WindowsSha256._(this._cng, this._hash, this._buffer);

  final _Cng _cng;
  final int _hash;
  final Pointer<Uint8> _buffer;
  bool _failed = false;
  bool _done = false;
  bool _released = false;

  static _WindowsSha256? _start(_Cng cng) {
    final handle = calloc<IntPtr>();
    try {
      final status = cng.createHash(
        cng.provider,
        handle,
        nullptr,
        0,
        nullptr,
        0,
        0,
      );
      if (status != 0 || handle.value == 0) return null;
      return _WindowsSha256._(
        cng,
        handle.value,
        calloc<Uint8>(_hashChunkBytes),
      );
    } finally {
      calloc.free(handle);
    }
  }

  @override
  void add(List<int> bytes) {
    if (_done || _failed) return;
    try {
      var offset = 0;
      while (offset < bytes.length) {
        final count = bytes.length - offset < _hashChunkBytes
            ? bytes.length - offset
            : _hashChunkBytes;
        _buffer.asTypedList(count).setRange(0, count, bytes, offset);
        if (_cng.hashData(_hash, _buffer, count, 0) != 0) {
          _failed = true;
          return;
        }
        offset += count;
      }
    } catch (_) {
      _failed = true;
    }
  }

  @override
  String? close() {
    if (_done) return null;
    _done = true;
    String? result;
    if (!_failed) {
      final output = calloc<Uint8>(_digestBytes);
      try {
        if (_cng.finishHash(_hash, output, _digestBytes, 0) == 0) {
          final buffer = StringBuffer();
          for (final byte in output.asTypedList(_digestBytes)) {
            buffer.write(byte.toRadixString(16).padLeft(2, '0'));
          }
          result = buffer.toString();
        }
      } catch (_) {
        result = null;
      } finally {
        calloc.free(output);
      }
    }
    _release();
    return result;
  }

  @override
  void dispose() {
    _done = true;
    _release();
  }

  void _release() {
    if (_released) return;
    _released = true;
    try {
      _cng.destroyHash(_hash);
    } catch (_) {}
    calloc.free(_buffer);
  }
}
