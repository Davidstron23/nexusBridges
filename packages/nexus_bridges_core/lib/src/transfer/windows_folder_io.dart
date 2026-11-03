import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:win32/win32.dart';

import '../winio/winio.dart';
import 'folder_walk.dart' show DataFolderKind, FolderLister, ListedEntry;
import 'hashing.dart' show startSha256;

const int _genericRead = 0x80000000;
const int _genericWrite = 0x40000000;
const int _deleteAccess = 0x00010000;
const int _synchronize = 0x00100000;
const int _fileListDirectory = 0x0001;
const int _fileTraverse = 0x0020;
const int _fileAttributeTagInfo = 9;
const int _noReparseTag = 0;
const int _fileReadAttributes = 0x0080;
const int _fileWriteAttributes = 0x0100;
const int _shareRead = 1;
const int _shareWrite = 2;
const int _shareAll = 7;
const int _fileOpen = 1;
const int _fileCreate = 2;
const int _fileOverwriteIf = 5;
const int _optionDirectory = 0x00000001;
const int _optionNonDirectory = 0x00000040;
const int _optionSynchronous = 0x00000020;
const int _optionReparse = 0x00200000;
const int _objCaseInsensitive = 0x40;
const int _attributeNormal = 0x80;
const int _attributeHidden = 0x02;
const int _attributeDirectory = 0x10;
const int _attributeReparse = 0x400;
const int _statusDiskFull = 0xC000007F;
const int _statusNoMoreFiles = 0x80000006;
const int _statusNoSuchFile = 0xC000000F;
const int _statusSuccess = 0;
const int _listBufferBytes = 65536;
const int _fullDirectoryInformation = 2;
const int _nameOffset = 68;
const int _finalPathChars = 32768;
const int _readChunkBytes = 1048576;
const String _zoneIdentifierText = '[ZoneTransfer]\r\nZoneId=3\r\n';

typedef _AssocIsDangerousNative = Int32 Function(Pointer<Utf16>);

typedef _AssocIsDangerous = int Function(Pointer<Utf16>);

bool isDangerousTypeSync(String extension) {
  try {
    final library = DynamicLibrary.open('shlwapi.dll');
    final query = library
        .lookupFunction<_AssocIsDangerousNative, _AssocIsDangerous>(
          'AssocIsDangerous',
        );
    return using((arena) => query(arena.pcwstr(extension)) != 0);
  } catch (_) {
    return false;
  }
}

Set<String> dangerousExtensionsSync(Set<String> extensions) {
  try {
    final library = DynamicLibrary.open('shlwapi.dll');
    final query = library
        .lookupFunction<_AssocIsDangerousNative, _AssocIsDangerous>(
          'AssocIsDangerous',
        );
    return using(
      (arena) => {
        for (final extension in extensions)
          if (query(arena.pcwstr(extension)) != 0) extension,
      },
    );
  } catch (_) {
    return Set<String>.of(extensions);
  }
}

int? _folderReparseTag(Arena arena, HANDLE handle) {
  final info = arena<BY_HANDLE_FILE_INFORMATION>();
  final Win32Result(value: informed) = GetFileInformationByHandle(handle, info);
  if (!informed) return null;
  if ((info.ref.dwFileAttributes & _attributeReparse) == 0) {
    return _noReparseTag;
  }
  final tagInfo = arena<Uint32>(2);
  final ok = loadGetFileInformationByHandleEx()(
    handle.cast<Void>(),
    _fileAttributeTagInfo,
    tagInfo.cast<Void>(),
    8,
  );
  if (ok == 0) return null;
  return tagInfo[1];
}

bool _sameFinalPath(String resolved, String expected) {
  String trimmed(String path) {
    var text = path.toUpperCase();
    while (text.length > 3 && text.endsWith(r'\')) {
      text = text.substring(0, text.length - 1);
    }
    return text;
  }

  return trimmed(resolved) == trimmed(expected);
}

List<RawEntry> listDirectorySync(
  String directoryPath, {
  bool allowNonLinkReparse = false,
  bool verifyFinalPath = false,
}) {
  return using((arena) {
    final Win32Result(value: handle) = CreateFile(
      arena.pcwstr(extendedPath(directoryPath)),
      _fileListDirectory | _fileReadAttributes | _synchronize,
      FILE_SHARE_MODE(_shareAll),
      null,
      OPEN_EXISTING,
      FILE_FLAG_BACKUP_SEMANTICS | FILE_FLAG_OPEN_REPARSE_POINT,
      null,
    );
    if (!handle.isValid) {
      throw const FileSystemException('The folder could not be listed');
    }
    try {
      if (allowNonLinkReparse) {
        final tag = _folderReparseTag(arena, handle);
        if (tag == null || (tag != _noReparseTag && isLinkTag(tag))) {
          throw const FileSystemException('The folder could not be listed');
        }
      } else if (_isReparse(arena, handle)) {
        throw const FileSystemException('The folder could not be listed');
      }
      if (verifyFinalPath) {
        final resolved = _finalPath(arena, handle);
        if (resolved == null ||
            !_sameFinalPath(
              resolved,
              stripExtendedPrefix(extendedPath(directoryPath)),
            )) {
          throw const FileSystemException('The folder could not be listed');
        }
      }
      final query = loadNtQueryDirectoryFile();
      final buffer = arena<Uint8>(_listBufferBytes);
      final status = arena<IoStatusBlock>();
      final entries = <RawEntry>[];
      var restart = 1;
      while (true) {
        final code =
            query(
              handle.cast<Void>(),
              nullptr,
              nullptr,
              nullptr,
              status,
              buffer.cast<Void>(),
              _listBufferBytes,
              _fullDirectoryInformation,
              0,
              nullptr,
              restart,
            ) &
            0xFFFFFFFF;
        if (code == _statusNoMoreFiles ||
            (restart == 1 && code == _statusNoSuchFile)) {
          return entries;
        }
        if (code != _statusSuccess) {
          throw const FileSystemException('The folder could not be listed');
        }
        restart = 0;
        var offset = 0;
        while (true) {
          final record = buffer + offset;
          final fields = record.cast<Uint32>();
          final attributes = fields[14];
          final nameBytes = fields[15];
          final name = String.fromCharCodes(
            (record + _nameOffset).cast<Uint16>().asTypedList(nameBytes ~/ 2),
          );
          if (name != '.' && name != '..') {
            entries.add(
              RawEntry(
                name: name,
                attributes: attributes,
                reparseTag: (attributes & _attributeReparse) != 0
                    ? fields[16]
                    : null,
                size: record.cast<Int64>()[5],
              ),
            );
          }
          final next = fields[0];
          if (next == 0) break;
          offset += next;
        }
      }
    } finally {
      handle.close();
    }
  });
}

final class WindowsFolderLister implements FolderLister {
  const WindowsFolderLister();

  @override
  List<ListedEntry> list(String directoryPath) => [
    for (final entry in listDirectorySync(
      directoryPath,
      allowNonLinkReparse: true,
      verifyFinalPath: true,
    ))
      ListedEntry(
        name: entry.name,
        isDirectory: entry.isDirectory,
        reparseTag: entry.reparseTag,
        size: entry.size,
      ),
  ];
}

String? _finalPath(Arena arena, HANDLE handle) {
  final buffer = arena.pwstrBuffer(_finalPathChars);
  final Win32Result(:value) = GetFinalPathNameByHandle(
    handle,
    buffer,
    _finalPathChars,
    FILE_NAME_NORMALIZED,
  );
  if (value == 0 || value >= _finalPathChars) return null;
  return stripExtendedPrefix(buffer.toDartString(length: value));
}

String? finalPathOfHandle(HANDLE handle) =>
    using((arena) => _finalPath(arena, handle));

typedef _CreateMutexNative = Pointer<Void> Function(
  Pointer<Void>,
  Int32,
  Pointer<Void>,
);
typedef _CreateMutex = Pointer<Void> Function(
  Pointer<Void>,
  int,
  Pointer<Void>,
);
typedef _WaitNative = Uint32 Function(Pointer<Void>, Uint32);
typedef _Wait = int Function(Pointer<Void>, int);
typedef _ReleaseNative = Int32 Function(Pointer<Void>);
typedef _Release = int Function(Pointer<Void>);

const int _waitInfinite = 0xFFFFFFFF;
const int _waitAbandoned = 0x80;

final class _MutexApi {
  _MutexApi._(this.create, this.wait, this.release);

  static final _MutexApi instance = _load();

  static _MutexApi _load() {
    final library = DynamicLibrary.open('kernel32.dll');
    return _MutexApi._(
      library.lookupFunction<_CreateMutexNative, _CreateMutex>('CreateMutexW'),
      library.lookupFunction<_WaitNative, _Wait>('WaitForSingleObject'),
      library.lookupFunction<_ReleaseNative, _Release>('ReleaseMutex'),
    );
  }

  final _CreateMutex create;
  final _Wait wait;
  final _Release release;

  void locked(Pointer<Void> mutex, void Function() action) {
    final result = wait(mutex, _waitInfinite);
    if (result != 0 && result != _waitAbandoned) return;
    try {
      action();
    } finally {
      release(mutex);
    }
  }
}

final class ReadCancelGate {
  ReadCancelGate._(this._slot, this._mutex);

  factory ReadCancelGate.create() => ReadCancelGate._(
    calloc<IntPtr>(),
    _MutexApi.instance.create(nullptr, 0, nullptr),
  );

  final Pointer<IntPtr> _slot;
  final Pointer<Void> _mutex;

  int get slotAddress => _slot.address;

  int get mutexAddress => _mutex.address;

  void cancelPending() {
    if (_mutex == nullptr) return;
    _MutexApi.instance.locked(_mutex, () {
      final address = _slot.value;
      if (address == 0) return;
      CancelIoEx(HANDLE(Pointer.fromAddress(address)), null);
    });
  }

  void dispose() {
    calloc.free(_slot);
    if (_mutex != nullptr) HANDLE(_mutex).close();
  }
}

final class ReadCancelPort {
  ReadCancelPort(int slotAddress, int mutexAddress)
    : _slot = Pointer<IntPtr>.fromAddress(slotAddress),
      _mutex = Pointer<Void>.fromAddress(mutexAddress);

  final Pointer<IntPtr> _slot;
  final Pointer<Void> _mutex;

  void publish(HANDLE handle) {
    if (_mutex == nullptr) return;
    _MutexApi.instance.locked(_mutex, () => _slot.value = handle.address);
  }

  void retract() {
    if (_mutex == nullptr) return;
    _MutexApi.instance.locked(_mutex, () => _slot.value = 0);
  }
}

bool _isInside(String candidate, String rootFinal) =>
    candidate.toUpperCase().startsWith('${rootFinal.toUpperCase()}\\');

Uint8List _hexToBytes(String hex) {
  final bytes = Uint8List(hex.length ~/ 2);
  for (var i = 0; i < bytes.length; i++) {
    bytes[i] = int.parse(hex.substring(i * 2, i * 2 + 2), radix: 16);
  }
  return bytes;
}

sealed class FileHashResult {
  const FileHashResult();
}

final class FileHashed extends FileHashResult {
  const FileHashed({
    required this.size,
    required this.sha256,
    required this.volume,
    required this.index,
    required this.links,
  });

  final int size;
  final Uint8List sha256;
  final int volume;
  final int index;
  final int links;
}

final class FileHashFailed extends FileHashResult {
  const FileHashFailed();
}

final class FileHashCancelled extends FileHashResult {
  const FileHashCancelled();
}

final class FileHashSkipped extends FileHashResult {
  const FileHashSkipped();
}

FileHashResult hashFileSync(
  String path, {
  required Pointer<Uint8> buffer,
  required bool Function() isCancelled,
  bool Function(int volume, int index)? isProtected,
  ReadCancelPort? cancelPort,
}) {
  return using((arena) {
    final Win32Result(value: handle) = CreateFile(
      arena.pcwstr(extendedPath(path)),
      _genericRead,
      FILE_SHARE_MODE(_shareAll),
      null,
      OPEN_EXISTING,
      FILE_FLAG_SEQUENTIAL_SCAN,
      null,
    );
    if (!handle.isValid) return const FileHashFailed();
    final digest = startSha256();
    cancelPort?.publish(handle);
    try {
      final resolved = _finalPath(arena, handle);
      if (resolved == null ||
          resolved.toUpperCase() !=
              stripExtendedPrefix(extendedPath(path)).toUpperCase()) {
        return const FileHashFailed();
      }
      final info = arena<BY_HANDLE_FILE_INFORMATION>();
      final Win32Result(value: informed) = GetFileInformationByHandle(
        handle,
        info,
      );
      if (!informed) return const FileHashFailed();
      if ((info.ref.dwFileAttributes & _attributeDirectory) != 0) {
        return const FileHashFailed();
      }
      if (isProtected != null &&
          isProtected(
            info.ref.dwVolumeSerialNumber,
            (info.ref.nFileIndexHigh << 32) | info.ref.nFileIndexLow,
          )) {
        return const FileHashSkipped();
      }
      final expected = arena<Int64>();
      final Win32Result(value: sized) = GetFileSizeEx(handle, expected);
      if (!sized) return const FileHashFailed();
      final read = arena<Uint32>();
      var total = 0;
      while (true) {
        if (isCancelled()) return const FileHashCancelled();
        final Win32Result(value: ok) = ReadFile(
          handle,
          buffer,
          _readChunkBytes,
          read,
          null,
        );
        if (!ok) return const FileHashFailed();
        final count = read.value;
        if (count == 0) break;
        digest.add(buffer.asTypedList(count));
        total += count;
      }
      if (total != expected.value) return const FileHashFailed();
      final hex = digest.close();
      if (hex == null) return const FileHashFailed();
      return FileHashed(
        size: total,
        sha256: _hexToBytes(hex),
        volume: info.ref.dwVolumeSerialNumber,
        index: (info.ref.nFileIndexHigh << 32) | info.ref.nFileIndexLow,
        links: info.ref.nNumberOfLinks,
      );
    } finally {
      cancelPort?.retract();
      digest.dispose();
      handle.close();
    }
  });
}

Set<(int, int)>? fileIdsUnder(
  String folderPath, {
  bool includeFolders = false,
}) {
  final ids = <(int, int)>{};
  bool addIdentityOf(String path) {
    final identity = _pathIdentity(path);
    if (!identity.found) return false;
    ids.add((identity.volume, identity.index));
    return true;
  }

  bool isMissing(String folder) =>
      FileSystemEntity.typeSync(folder, followLinks: false) ==
      FileSystemEntityType.notFound;

  bool visit(String folder) {
    final List<RawEntry> entries;
    try {
      entries = listDirectorySync(folder);
    } catch (_) {
      return isMissing(folder);
    }
    if (includeFolders && !addIdentityOf(folder)) return false;
    for (final entry in entries) {
      if ((entry.attributes & _attributeReparse) != 0) continue;
      final child = folder.endsWith(r'\')
          ? '$folder${entry.name}'
          : '$folder\\${entry.name}';
      if (entry.isDirectory) {
        if (!visit(child)) return false;
      } else if (!addIdentityOf(child)) {
        return false;
      }
    }
    return true;
  }

  return visit(folderPath) ? ids : null;
}

final class _PathIdentity {
  const _PathIdentity.found(this.volume, this.index, this.links) : error = 0;

  const _PathIdentity.failed(this.error) : volume = 0, index = 0, links = 0;

  final int volume;
  final int index;
  final int links;
  final int error;

  bool get found => error == 0;
}

_PathIdentity _pathIdentity(String path) {
  return using((arena) {
    final Win32Result(value: handle, error: openError) = CreateFile(
      arena.pcwstr(extendedPath(path)),
      _fileReadAttributes,
      FILE_SHARE_MODE(_shareAll),
      null,
      OPEN_EXISTING,
      FILE_FLAG_BACKUP_SEMANTICS | FILE_FLAG_OPEN_REPARSE_POINT,
      null,
    );
    if (!handle.isValid) return _PathIdentity.failed(openError);
    try {
      final info = arena<BY_HANDLE_FILE_INFORMATION>();
      final Win32Result(value: informed, error: infoError) =
          GetFileInformationByHandle(handle, info);
      if (!informed) {
        return _PathIdentity.failed(infoError == 0 ? 1 : infoError);
      }
      return _PathIdentity.found(
        info.ref.dwVolumeSerialNumber,
        (info.ref.nFileIndexHigh << 32) | info.ref.nFileIndexLow,
        info.ref.nNumberOfLinks,
      );
    } finally {
      handle.close();
    }
  });
}

enum DataCheck { clear, inData, unreadable }

DataCheck checkAgainstData(String path, String dataFolder) {
  final identity = _pathIdentity(path);
  if (!identity.found) return DataCheck.unreadable;
  final ids = fileIdsUnder(dataFolder, includeFolders: true);
  if (ids == null) return DataCheck.inData;
  return ids.contains((identity.volume, identity.index))
      ? DataCheck.inData
      : DataCheck.clear;
}

DataFolderKind folderKindAmong(String path, Set<(int, int)> ids) {
  final identity = _pathIdentity(path);
  if (!identity.found) return DataFolderKind.unknown;
  return ids.contains((identity.volume, identity.index))
      ? DataFolderKind.inside
      : DataFolderKind.outside;
}

final class SendFileReader {
  SendFileReader._(this._handle, this.size, this._cancelPort)
    : _count = calloc<Uint32>() {
    _cancelPort?.publish(_handle);
  }

  final HANDLE _handle;
  final ReadCancelPort? _cancelPort;
  final Pointer<Uint32> _count;
  final int size;
  bool _closed = false;

  int read(Pointer<Uint8> buffer, int length) {
    if (_closed) return -1;
    final Win32Result(value: ok) = ReadFile(
      _handle,
      buffer,
      length,
      _count,
      null,
    );
    return ok ? _count.value : -1;
  }

  void close() {
    if (_closed) return;
    _closed = true;
    _cancelPort?.retract();
    _handle.close();
    calloc.free(_count);
  }
}

HANDLE? _openForSend(Arena arena, String path, {required bool reparse}) {
  final Win32Result(value: handle) = CreateFile(
    arena.pcwstr(extendedPath(path)),
    _genericRead,
    FILE_SHARE_MODE(_shareAll),
    null,
    OPEN_EXISTING,
    reparse
        ? FILE_FLAG_SEQUENTIAL_SCAN | FILE_FLAG_OPEN_REPARSE_POINT
        : FILE_FLAG_SEQUENTIAL_SCAN,
    null,
  );
  return handle.isValid ? handle : null;
}

bool _isTheFileFromPlan(
  Arena arena,
  HANDLE handle, {
  required String path,
  required int volume,
  required int index,
  required int? size,
}) {
  final resolved = _finalPath(arena, handle);
  if (resolved == null ||
      resolved.toUpperCase() !=
          stripExtendedPrefix(extendedPath(path)).toUpperCase()) {
    return false;
  }
  final info = arena<BY_HANDLE_FILE_INFORMATION>();
  final Win32Result(value: informed) = GetFileInformationByHandle(handle, info);
  if (!informed) return false;
  if ((info.ref.dwFileAttributes & _attributeDirectory) != 0) return false;
  if (info.ref.dwVolumeSerialNumber != volume ||
      ((info.ref.nFileIndexHigh << 32) | info.ref.nFileIndexLow) != index) {
    return false;
  }
  final length = arena<Int64>();
  final Win32Result(value: sized) = GetFileSizeEx(handle, length);
  return sized && (size == null || length.value == size);
}

SendFileReader? openFileForSend({
  required String path,
  required int volume,
  required int index,
  int? size,
  ReadCancelPort? cancelPort,
}) {
  return using((arena) {
    var handle = _openForSend(arena, path, reparse: true);
    if (handle == null) return null;
    var keep = false;
    try {
      final info = arena<BY_HANDLE_FILE_INFORMATION>();
      final Win32Result(value: informed) = GetFileInformationByHandle(
        handle,
        info,
      );
      if (!informed) return null;
      if ((info.ref.dwFileAttributes & _attributeReparse) != 0) {
        final tag = _folderReparseTag(arena, handle);
        if (tag == null || isLinkTag(tag)) return null;
        handle.close();
        handle = _openForSend(arena, path, reparse: false);
        if (handle == null) return null;
      }
      if (!_isTheFileFromPlan(
        arena,
        handle,
        path: path,
        volume: volume,
        index: index,
        size: size,
      )) {
        return null;
      }
      final length = arena<Int64>();
      final Win32Result(value: sized) = GetFileSizeEx(handle, length);
      if (!sized) return null;
      keep = true;
      return SendFileReader._(handle, length.value, cancelPort);
    } finally {
      if (!keep && handle != null) handle.close();
    }
  });
}

Pointer<Uint8> allocateReadBuffer() => calloc<Uint8>(_readChunkBytes);

void freeReadBuffer(Pointer<Uint8> buffer) => calloc.free(buffer);

NodeResult _createRelative(
  HANDLE? parent,
  String name, {
  required int access,
  required int share,
  required int disposition,
  required int options,
  required int attributes,
}) {
  return using((arena) {
    final text = name.toNativeUtf16(allocator: arena);
    final unicode = arena<UnicodeString>();
    unicode.ref
      ..length = name.length * 2
      ..maximumLength = name.length * 2 + 2
      ..buffer = text.cast<Uint16>();
    final object = arena<ObjectAttributes>();
    object.ref
      ..length = sizeOf<ObjectAttributes>()
      ..rootDirectory = parent?.cast<Void>() ?? nullptr
      ..objectName = unicode
      ..attributes = _objCaseInsensitive
      ..securityDescriptor = nullptr
      ..securityQualityOfService = nullptr;
    final out = arena<Pointer<Void>>();
    final status = arena<IoStatusBlock>();
    final code =
        loadNtCreateFile()(
          out,
          access,
          object,
          status,
          nullptr,
          attributes,
          share,
          disposition,
          options,
          nullptr,
          0,
        ) &
        0xFFFFFFFF;
    if (code >= 0xC0000000) {
      return NodeFailed(diskFull: code == _statusDiskFull);
    }
    final handle = HANDLE(out.value);
    if (!handle.isValid) return const NodeFailed(diskFull: false);
    return NodeCreated(handle);
  });
}

bool _isReparse(Arena arena, HANDLE handle) {
  final info = arena<BY_HANDLE_FILE_INFORMATION>();
  final Win32Result(:value) = GetFileInformationByHandle(handle, info);
  if (!value) return true;
  return (info.ref.dwFileAttributes & _attributeReparse) != 0;
}

NodeResult createFolderExclusive(
  HANDLE parent,
  String name, {
  required String rootFinal,
  required bool existing,
}) {
  final result = _createRelative(
    parent,
    name,
    access:
        _fileListDirectory |
        _fileTraverse |
        _synchronize |
        _deleteAccess |
        _fileWriteAttributes |
        _fileReadAttributes,
    share: _shareRead | _shareWrite,
    disposition: existing ? _fileOpen : _fileCreate,
    options: _optionDirectory | _optionReparse | _optionSynchronous,
    attributes: 0,
  );
  if (result is! NodeCreated) return result;
  final handle = result.handle;
  final trusted = using((arena) {
    if (_isReparse(arena, handle)) return false;
    final resolved = _finalPath(arena, handle);
    return resolved != null && _isInside(resolved, rootFinal);
  });
  if (trusted) return result;
  deleteByHandle(handle);
  handle.close();
  return const NodeFailed(diskFull: false);
}

NodeResult createFileExclusive(
  HANDLE parent,
  String name, {
  required String rootFinal,
}) {
  final result = _createRelative(
    parent,
    name,
    access: _genericWrite | _deleteAccess | _synchronize | _fileReadAttributes,
    share: 0,
    disposition: _fileCreate,
    options: _optionNonDirectory | _optionReparse | _optionSynchronous,
    attributes: _attributeNormal,
  );
  if (result is! NodeCreated) return result;
  final handle = result.handle;
  final trusted = using((arena) {
    if (_isReparse(arena, handle)) return false;
    final resolved = _finalPath(arena, handle);
    return resolved != null && _isInside(resolved, rootFinal);
  });
  if (trusted) return result;
  deleteByHandle(handle);
  handle.close();
  return const NodeFailed(diskFull: false);
}

int writeAllSync(HANDLE file, Pointer<Uint8> data, int length) {
  return using((arena) {
    final write = loadNtWriteFile();
    final status = arena<IoStatusBlock>();
    var offset = 0;
    while (offset < length) {
      final code =
          write(
            file.cast<Void>(),
            nullptr,
            nullptr,
            nullptr,
            status,
            (data + offset).cast<Void>(),
            length - offset,
            nullptr,
            nullptr,
          ) &
          0xFFFFFFFF;
      if (code != _statusSuccess) return code;
      final written = status.ref.information;
      if (written <= 0) return 1;
      offset += written;
    }
    return 0;
  });
}

bool isDiskFullError(int status) => status == _statusDiskFull;

bool markFromInternetSync(HANDLE parent, String name) {
  final streamName = '$name:Zone.Identifier';
  final created = _createRelative(
    parent,
    streamName,
    access: _genericWrite | _synchronize,
    share: 0,
    disposition: _fileOverwriteIf,
    options: _optionNonDirectory | _optionReparse | _optionSynchronous,
    attributes: _attributeNormal,
  );
  if (created is! NodeCreated) return false;
  final writeHandle = created.handle;
  try {
    final bytes = Uint8List.fromList(_zoneIdentifierText.codeUnits);
    final ok = using((arena) {
      final data = arena<Uint8>(bytes.length);
      data.asTypedList(bytes.length).setAll(0, bytes);
      return writeAllSync(writeHandle, data, bytes.length) == 0;
    });
    if (!ok) return false;
  } finally {
    writeHandle.close();
  }
  final opened = _createRelative(
    parent,
    streamName,
    access: _genericRead | _synchronize,
    share: _shareRead,
    disposition: _fileOpen,
    options: _optionNonDirectory | _optionReparse | _optionSynchronous,
    attributes: 0,
  );
  if (opened is! NodeCreated) return false;
  final readHandle = opened.handle;
  try {
    return using((arena) {
      final buffer = arena<Uint8>(256);
      final read = arena<Uint32>();
      final Win32Result(value: ok) = ReadFile(
        readHandle,
        buffer,
        256,
        read,
        null,
      );
      if (!ok) return false;
      final text = String.fromCharCodes(buffer.asTypedList(read.value));
      return text == _zoneIdentifierText;
    });
  } finally {
    readHandle.close();
  }
}

NodeResult openRootSync(String path) {
  return using((arena) {
    final Win32Result(value: handle) = CreateFile(
      arena.pcwstr(extendedPath(path)),
      _fileListDirectory |
          _fileTraverse |
          _deleteAccess |
          _fileWriteAttributes |
          _fileReadAttributes |
          _synchronize,
      FILE_SHARE_MODE(_shareRead | _shareWrite),
      null,
      OPEN_EXISTING,
      FILE_FLAG_BACKUP_SEMANTICS | FILE_FLAG_OPEN_REPARSE_POINT,
      null,
    );
    if (!handle.isValid) return const NodeFailed(diskFull: false);
    if (_isReparse(arena, handle)) {
      handle.close();
      return const NodeFailed(diskFull: false);
    }
    return NodeCreated(handle);
  });
}

bool createFolderByPathSync(String path) {
  return using((arena) {
    final Win32Result(:value) = CreateDirectory(
      arena.pcwstr(extendedPath(path)),
      null,
    );
    return value;
  });
}

bool setHiddenByPathSync(String path) {
  return using((arena) {
    final Win32Result(:value) = SetFileAttributes(
      arena.pcwstr(extendedPath(path)),
      FILE_FLAGS_AND_ATTRIBUTES(_attributeHidden),
    );
    return value;
  });
}

bool clearHiddenByHandleSync(HANDLE handle) {
  return using((arena) {
    final info = arena<Uint8>(40);
    info.cast<Uint32>()[8] = _attributeNormal;
    final Win32Result(:value) = SetFileInformationByHandle(
      handle,
      FileBasicInfo,
      info,
      40,
    );
    return value;
  });
}

bool deleteTreeNoFollowSync(String path) {
  return using((arena) {
    final extended = extendedPath(path);
    final Win32Result(value: attributes) = GetFileAttributes(
      arena.pcwstr(extended),
    );
    if (attributes == 0xFFFFFFFF) {
      return FileSystemEntity.typeSync(extended, followLinks: false) ==
          FileSystemEntityType.notFound;
    }
    if ((attributes & _attributeReparse) != 0) {
      return _removeLink(arena, extended, attributes);
    }
    if ((attributes & _attributeDirectory) == 0) {
      return _deleteFile(arena, extended);
    }
    return _deleteDirectory(arena, path, extended);
  });
}

bool _removeLink(Arena arena, String extended, int attributes) {
  if ((attributes & _attributeDirectory) != 0) {
    final Win32Result(:value) = RemoveDirectory(arena.pcwstr(extended));
    return value;
  }
  return _deleteFile(arena, extended);
}

bool _deleteFile(Arena arena, String extended) {
  SetFileAttributes(
    arena.pcwstr(extended),
    FILE_FLAGS_AND_ATTRIBUTES(_attributeNormal),
  );
  final Win32Result(:value) = DeleteFile(arena.pcwstr(extended));
  return value;
}

bool _deleteDirectory(Arena arena, String path, String extended) {
  var clean = true;
  final List<RawEntry> entries;
  try {
    entries = listDirectorySync(path);
  } catch (_) {
    return false;
  }
  for (final entry in entries) {
    final child = path.endsWith(r'\')
        ? '$path${entry.name}'
        : '$path\\${entry.name}';
    final childExtended = extendedPath(child);
    if ((entry.attributes & _attributeReparse) != 0) {
      clean = _removeLink(arena, childExtended, entry.attributes) && clean;
    } else if (entry.isDirectory) {
      clean = _deleteDirectory(arena, child, childExtended) && clean;
    } else {
      clean = _deleteFile(arena, childExtended) && clean;
    }
  }
  if (!clean) return false;
  final Win32Result(:value) = RemoveDirectory(arena.pcwstr(extended));
  return value;
}

bool verifyTree(
  String root,
  int expectedEntries, {
  bool Function()? isCancelled,
}) {
  var count = 0;
  bool walk(String folder) {
    if (isCancelled != null && isCancelled()) return false;
    final List<RawEntry> entries;
    try {
      entries = listDirectorySync(folder);
    } catch (_) {
      return false;
    }
    for (final entry in entries) {
      if ((entry.attributes & _attributeReparse) != 0) return false;
      count++;
      if (entry.isDirectory) {
        final child = folder.endsWith(r'\')
            ? '$folder${entry.name}'
            : '$folder\\${entry.name}';
        if (!walk(child)) return false;
      }
    }
    return true;
  }

  return walk(root) && count == expectedEntries;
}
