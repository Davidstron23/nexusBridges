import 'dart:ffi';

import 'package:ffi/ffi.dart';
import 'package:nexus_bridges_core/src/winio/winio.dart' show extendedPath;
import 'package:win32/win32.dart';

String shortNameOf(String path) => using((arena) {
  final data = arena<WIN32_FIND_DATA>();
  final Win32Result(value: handle) = FindFirstFile(
    arena.pcwstr(extendedPath(path)),
    data,
  );
  if (!handle.isValid) return '';
  try {
    return data.ref.cAlternateFileName;
  } finally {
    FindClose(handle);
  }
});

bool makeRawFolder(String path) => using((arena) {
  final Win32Result(:value) = CreateDirectory(
    arena.pcwstr(extendedPath(path)),
    null,
  );
  return value;
});
