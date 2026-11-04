import 'dart:ffi';

final class UnicodeString extends Struct {
  @Uint16()
  external int length;

  @Uint16()
  external int maximumLength;

  external Pointer<Uint16> buffer;
}

final class ObjectAttributes extends Struct {
  @Uint32()
  external int length;

  external Pointer<Void> rootDirectory;

  external Pointer<UnicodeString> objectName;

  @Uint32()
  external int attributes;

  external Pointer<Void> securityDescriptor;

  external Pointer<Void> securityQualityOfService;
}

final class IoStatusBlock extends Struct {
  @IntPtr()
  external int status;

  @IntPtr()
  external int information;
}

typedef NtCreateFileNative = Int32 Function(
  Pointer<Pointer<Void>>,
  Uint32,
  Pointer<ObjectAttributes>,
  Pointer<IoStatusBlock>,
  Pointer<Int64>,
  Uint32,
  Uint32,
  Uint32,
  Uint32,
  Pointer<Void>,
  Uint32,
);

typedef NtCreateFile = int Function(
  Pointer<Pointer<Void>>,
  int,
  Pointer<ObjectAttributes>,
  Pointer<IoStatusBlock>,
  Pointer<Int64>,
  int,
  int,
  int,
  int,
  Pointer<Void>,
  int,
);

typedef NtQueryDirectoryFileNative = Int32 Function(
  Pointer<Void>,
  Pointer<Void>,
  Pointer<Void>,
  Pointer<Void>,
  Pointer<IoStatusBlock>,
  Pointer<Void>,
  Uint32,
  Int32,
  Uint8,
  Pointer<Void>,
  Uint8,
);

typedef NtQueryDirectoryFile = int Function(
  Pointer<Void>,
  Pointer<Void>,
  Pointer<Void>,
  Pointer<Void>,
  Pointer<IoStatusBlock>,
  Pointer<Void>,
  int,
  int,
  int,
  Pointer<Void>,
  int,
);

typedef NtWriteFileNative = Int32 Function(
  Pointer<Void>,
  Pointer<Void>,
  Pointer<Void>,
  Pointer<Void>,
  Pointer<IoStatusBlock>,
  Pointer<Void>,
  Uint32,
  Pointer<Int64>,
  Pointer<Uint32>,
);

typedef NtWriteFile = int Function(
  Pointer<Void>,
  Pointer<Void>,
  Pointer<Void>,
  Pointer<Void>,
  Pointer<IoStatusBlock>,
  Pointer<Void>,
  int,
  Pointer<Int64>,
  Pointer<Uint32>,
);

typedef NtSetInformationFileNative = Int32 Function(
  Pointer<Void>,
  Pointer<IoStatusBlock>,
  Pointer<Void>,
  Uint32,
  Int32,
);

typedef NtSetInformationFile = int Function(
  Pointer<Void>,
  Pointer<IoStatusBlock>,
  Pointer<Void>,
  int,
  int,
);

typedef GetFileInformationByHandleExNative = Int32 Function(
  Pointer<Void>,
  Int32,
  Pointer<Void>,
  Uint32,
);

typedef GetFileInformationByHandleEx = int Function(
  Pointer<Void>,
  int,
  Pointer<Void>,
  int,
);

GetFileInformationByHandleEx? _getFileInformationByHandleEx;

GetFileInformationByHandleEx loadGetFileInformationByHandleEx() {
  final cached = _getFileInformationByHandleEx;
  if (cached != null) return cached;
  final library = DynamicLibrary.open('kernel32.dll');
  return _getFileInformationByHandleEx = library
      .lookupFunction<
        GetFileInformationByHandleExNative,
        GetFileInformationByHandleEx
      >('GetFileInformationByHandleEx');
}

NtQueryDirectoryFile? _ntQueryDirectoryFile;

NtQueryDirectoryFile loadNtQueryDirectoryFile() {
  final cached = _ntQueryDirectoryFile;
  if (cached != null) return cached;
  final library = DynamicLibrary.open('ntdll.dll');
  return _ntQueryDirectoryFile = library
      .lookupFunction<NtQueryDirectoryFileNative, NtQueryDirectoryFile>(
        'NtQueryDirectoryFile',
      );
}

NtWriteFile? _ntWriteFile;

NtWriteFile loadNtWriteFile() {
  final cached = _ntWriteFile;
  if (cached != null) return cached;
  final library = DynamicLibrary.open('ntdll.dll');
  return _ntWriteFile = library.lookupFunction<NtWriteFileNative, NtWriteFile>(
    'NtWriteFile',
  );
}

NtSetInformationFile? _ntSetInformationFile;

NtSetInformationFile loadNtSetInformationFile() {
  final cached = _ntSetInformationFile;
  if (cached != null) return cached;
  final library = DynamicLibrary.open('ntdll.dll');
  return _ntSetInformationFile = library
      .lookupFunction<NtSetInformationFileNative, NtSetInformationFile>(
        'NtSetInformationFile',
      );
}

NtCreateFile? _ntCreateFile;

NtCreateFile loadNtCreateFile() {
  final cached = _ntCreateFile;
  if (cached != null) return cached;
  final library = DynamicLibrary.open('ntdll.dll');
  return _ntCreateFile = library
      .lookupFunction<NtCreateFileNative, NtCreateFile>('NtCreateFile');
}
