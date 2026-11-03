import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:win32/win32.dart';

import 'nt.dart';
import 'paths.dart';
import 'reparse.dart';

const int _deleteAccess = 0x00010000;
const int _synchronize = 0x00100000;
const int _fileListDirectory = 0x0001;
const int _fileTraverse = 0x0020;
const int _fileReadAttributes = 0x0080;
const int _shareRead = 1;
const int _shareWrite = 2;
const int _shareDelete = 4;
const int _fileOpen = 1;
const int _fileOpenIf = 3;
const int _fileCreated = 2;
const int _optionDirectory = 0x00000001;
const int _optionNonDirectory = 0x00000040;
const int _optionSynchronous = 0x00000020;
const int _optionReparse = 0x00200000;
const int _fileRenameInformation = 10;
const int _fileDispositionInformation = 13;
const int _renameHeaderBytes = 24;
const int _statusSharingViolation = 0xC0000043;
const int _statusObjectNameCollision = 0xC0000035;
const int _statusDirectoryNotEmpty = 0xC0000101;
const int _objCaseInsensitive = 0x40;
const int _attributeHidden = 0x02;
const int _attributeSystem = 0x04;
const int _attributeDirectory = 0x10;
const int _attributeReparse = 0x400;
const int _fileAttributeTagInfo = 9;
const int _ntFailure = 0x80000000;
const int _statusNoMoreFiles = 0x80000006;
const int _statusNoSuchFile = 0xC000000F;
const int _statusObjectNameNotFound = 0xC0000034;
const int _statusObjectPathNotFound = 0xC000003A;
const int _statusNotADirectory = 0xC0000103;
const int _statusAccessDenied = 0xC0000022;
const int _errorFileNotFound = 2;
const int _errorPathNotFound = 3;
const int _errorAccessDenied = 5;
const int _listBufferBytes = 65536;
const int _fullDirectoryInformation = 2;
const int _nameOffset = 68;
const int _finalPathChars = 32768;
const int _volumeNameChars = 261;
const int _volumeSerialDigits = 8;
const int _volumeSystemChars = 16;
const int _lockedAccess =
    _fileListDirectory | _fileTraverse | _fileReadAttributes | _synchronize;

final class RawEntry {
  const RawEntry({
    required this.name,
    required this.attributes,
    required this.reparseTag,
    required this.size,
  });

  final String name;
  final int attributes;
  final int? reparseTag;
  final int size;

  bool get isDirectory => (attributes & _attributeDirectory) != 0;
}

sealed class NodeResult {
  const NodeResult();
}

final class NodeCreated extends NodeResult {
  const NodeCreated(this.handle);

  final HANDLE handle;
}

final class NodeFailed extends NodeResult {
  const NodeFailed({required this.diskFull});

  final bool diskFull;
}

bool deleteByHandle(HANDLE handle) {
  return using((arena) {
    final flag = arena<Uint8>(4);
    flag.value = 1;
    final Win32Result(:value) = SetFileInformationByHandle(
      handle,
      FileDispositionInfo,
      flag,
      1,
    );
    return value;
  });
}

final class FolderFacts {
  const FolderFacts({
    required this.attributes,
    required this.reparseTag,
    required this.volumeId,
    required this.supportsNamedStreams,
    required this.finalPath,
  });

  final int attributes;
  final int? reparseTag;
  final String volumeId;
  final bool supportsNamedStreams;
  final String finalPath;

  bool get hidden => (attributes & _attributeHidden) != 0;

  bool get system => (attributes & _attributeSystem) != 0;

  bool get isLink {
    final tag = reparseTag;
    return tag != null && isLinkTag(tag);
  }

  String get realName {
    var end = finalPath.length;
    while (end > 0 && finalPath.codeUnitAt(end - 1) == 0x5C) {
      end--;
    }
    if (end == 0) return '';
    final cut = finalPath.lastIndexOf(r'\', end - 1);
    return finalPath.substring(cut + 1, end);
  }
}

enum FolderOpenFailure { notFound, notAFolder, denied, other }

sealed class FolderOpen {
  const FolderOpen();
}

final class FolderOpened extends FolderOpen {
  const FolderOpened(this.handle, {required this.created});

  final int handle;
  final bool created;
}

final class FolderOpenFailed extends FolderOpen {
  const FolderOpenFailed(this.reason);

  final FolderOpenFailure reason;
}

abstract interface class DirectoryBatches {
  List<RawEntry>? next();

  void close();
}

HANDLE _handleOf(int address) => HANDLE(Pointer.fromAddress(address));

FolderOpen openFolderByPathSync(String path, {required bool lock}) {
  return using((arena) {
    final Win32Result(value: handle, error: error) = CreateFile(
      arena.pcwstr(extendedPath(path)),
      _lockedAccess,
      FILE_SHARE_MODE(
        lock
            ? _shareRead | _shareWrite
            : _shareRead | _shareWrite | _shareDelete,
      ),
      null,
      OPEN_EXISTING,
      FILE_FLAG_BACKUP_SEMANTICS | FILE_FLAG_OPEN_REPARSE_POINT,
      null,
    );
    if (!handle.isValid) {
      return FolderOpenFailed(switch (error) {
        _errorFileNotFound || _errorPathNotFound => FolderOpenFailure.notFound,
        _errorAccessDenied => FolderOpenFailure.denied,
        _ => FolderOpenFailure.other,
      });
    }
    final info = arena<BY_HANDLE_FILE_INFORMATION>();
    final Win32Result(value: informed) = GetFileInformationByHandle(
      handle,
      info,
    );
    if (!informed) {
      handle.close();
      return const FolderOpenFailed(FolderOpenFailure.other);
    }
    if ((info.ref.dwFileAttributes & _attributeDirectory) == 0) {
      handle.close();
      return const FolderOpenFailed(FolderOpenFailure.notAFolder);
    }
    return FolderOpened(handle.address, created: false);
  });
}

bool _isSingleName(String name) {
  if (name.isEmpty) return false;
  for (var i = 0; i < name.length; i++) {
    final unit = name.codeUnitAt(i);
    if (unit == 0x5C || unit == 0x2F || unit == 0x3A || unit == 0) {
      return false;
    }
  }
  return true;
}

typedef _NtOpened = ({int code, int handle, int information});

_NtOpened _ntOpenRelative(
  int parent,
  String name, {
  required int access,
  required int share,
  required int disposition,
  required int options,
  int attributes = 0,
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
      ..rootDirectory = _handleOf(parent).cast<Void>()
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
    if (code >= _ntFailure) {
      return (code: code, handle: 0, information: 0);
    }
    final handle = HANDLE(out.value);
    if (!handle.isValid) {
      return (code: _ntFailure, handle: 0, information: 0);
    }
    return (
      code: code,
      handle: handle.address,
      information: status.ref.information,
    );
  });
}

FolderOpen openFolderRelativeSync(
  int parent,
  String name, {
  required bool lock,
  bool create = false,
  bool hideIfCreated = false,
}) {
  if (!_isSingleName(name)) {
    return const FolderOpenFailed(FolderOpenFailure.other);
  }
  final opened = _ntOpenRelative(
    parent,
    name,
    access: _lockedAccess,
    share: lock
        ? _shareRead | _shareWrite
        : _shareRead | _shareWrite | _shareDelete,
    disposition: create ? _fileOpenIf : _fileOpen,
    options: _optionDirectory | _optionReparse | _optionSynchronous,
    attributes: create && hideIfCreated ? _attributeHidden : 0,
  );
  if (opened.code >= _ntFailure) {
    return FolderOpenFailed(switch (opened.code) {
      _statusObjectNameNotFound ||
      _statusObjectPathNotFound => FolderOpenFailure.notFound,
      _statusNotADirectory => FolderOpenFailure.notAFolder,
      _statusAccessDenied => FolderOpenFailure.denied,
      _ => FolderOpenFailure.other,
    });
  }
  return FolderOpened(
    opened.handle,
    created: create && opened.information == _fileCreated,
  );
}

enum DeleteStatus { deleted, notEmpty, busy, mismatch, failed }

sealed class OpenForRename {
  const OpenForRename();
}

final class RenameSourceOpened extends OpenForRename {
  const RenameSourceOpened(this.handle);

  final int handle;
}

final class RenameSourceBusy extends OpenForRename {
  const RenameSourceBusy();
}

final class RenameSourceFailed extends OpenForRename {
  const RenameSourceFailed();
}

enum RenameStatus { renamed, nameTaken, busy, failed }

String _trimmedUpper(String path) {
  var text = path.toUpperCase();
  while (text.length > 3 && text.endsWith(r'\')) {
    text = text.substring(0, text.length - 1);
  }
  return text;
}

DeleteStatus deleteEmptyFolderRelativeSync(
  int parent,
  String name, {
  required String expectedFinalPath,
}) {
  if (!_isSingleName(name)) return DeleteStatus.failed;
  final opened = _ntOpenRelative(
    parent,
    name,
    access: _deleteAccess | _fileReadAttributes | _synchronize,
    share: _shareRead | _shareWrite | _shareDelete,
    disposition: _fileOpen,
    options: _optionDirectory | _optionReparse | _optionSynchronous,
  );
  if (opened.code >= _ntFailure) {
    return opened.code == _statusSharingViolation
        ? DeleteStatus.busy
        : DeleteStatus.failed;
  }
  try {
    final facts = folderFactsSync(opened.handle);
    if (facts == null) return DeleteStatus.failed;
    if (facts.reparseTag != null ||
        _trimmedUpper(facts.finalPath) != _trimmedUpper(expectedFinalPath)) {
      return DeleteStatus.mismatch;
    }
    final code = using((arena) {
      final flag = arena<Uint8>(4);
      flag.value = 1;
      final status = arena<IoStatusBlock>();
      return loadNtSetInformationFile()(
            _handleOf(opened.handle).cast<Void>(),
            status,
            flag.cast<Void>(),
            1,
            _fileDispositionInformation,
          ) &
          0xFFFFFFFF;
    });
    if (code == 0) return DeleteStatus.deleted;
    if (code == _statusDirectoryNotEmpty) return DeleteStatus.notEmpty;
    if (code == _statusSharingViolation) return DeleteStatus.busy;
    return DeleteStatus.failed;
  } finally {
    closeHandleSync(opened.handle);
  }
}

OpenForRename openForRenameRelativeSync(
  int parent,
  String name, {
  required bool directory,
}) {
  if (!_isSingleName(name)) return const RenameSourceFailed();
  final opened = _ntOpenRelative(
    parent,
    name,
    access: _deleteAccess | _fileReadAttributes | _synchronize,
    share: _shareRead,
    disposition: _fileOpen,
    options:
        _optionReparse |
        _optionSynchronous |
        (directory ? _optionDirectory : _optionNonDirectory),
  );
  if (opened.code >= _ntFailure) {
    return opened.code == _statusSharingViolation
        ? const RenameSourceBusy()
        : const RenameSourceFailed();
  }
  final reparse = using((arena) {
    final info = arena<BY_HANDLE_FILE_INFORMATION>();
    final Win32Result(value: informed) = GetFileInformationByHandle(
      _handleOf(opened.handle),
      info,
    );
    return !informed || (info.ref.dwFileAttributes & _attributeReparse) != 0;
  });
  if (reparse) {
    closeHandleSync(opened.handle);
    return const RenameSourceFailed();
  }
  return RenameSourceOpened(opened.handle);
}

RenameStatus renameRelativeSync(int source, int targetFolder, String name) {
  if (!_isSingleName(name)) return RenameStatus.failed;
  final code = using((arena) {
    final bytes = name.length * 2;
    final buffer = arena<Uint8>(_renameHeaderBytes + bytes);
    final fields = buffer.cast<Uint32>();
    fields[0] = 0;
    fields[1] = 0;
    buffer.cast<IntPtr>()[1] = _handleOf(targetFolder).address;
    fields[4] = bytes;
    final units = (buffer + 20).cast<Uint16>();
    for (var i = 0; i < name.length; i++) {
      units[i] = name.codeUnitAt(i);
    }
    final status = arena<IoStatusBlock>();
    return loadNtSetInformationFile()(
          _handleOf(source).cast<Void>(),
          status,
          buffer.cast<Void>(),
          _renameHeaderBytes + bytes,
          _fileRenameInformation,
        ) &
        0xFFFFFFFF;
  });
  if (code == 0) return RenameStatus.renamed;
  if (code == _statusObjectNameCollision) return RenameStatus.nameTaken;
  if (code == _statusSharingViolation || code == _statusAccessDenied) {
    return RenameStatus.busy;
  }
  return RenameStatus.failed;
}

List<String> childNameKeysSync(
  int folder, {
  String Function(String name)? key,
}) {
  final batches = directoryBatchesSync(folder);
  try {
    final names = <String>[];
    while (true) {
      final batch = batches.next();
      if (batch == null) break;
      for (final entry in batch) {
        names.add(key == null ? entry.name : key(entry.name));
      }
    }
    return names;
  } finally {
    batches.close();
  }
}

FolderFacts? folderFactsSync(int handleAddress) {
  final handle = _handleOf(handleAddress);
  return using((arena) {
    final info = arena<BY_HANDLE_FILE_INFORMATION>();
    final Win32Result(value: informed) = GetFileInformationByHandle(
      handle,
      info,
    );
    if (!informed) return null;
    final attributes = info.ref.dwFileAttributes;
    int? tag;
    if ((attributes & _attributeReparse) != 0) {
      final tagInfo = arena<Uint32>(2);
      final ok = loadGetFileInformationByHandleEx()(
        handle.cast<Void>(),
        _fileAttributeTagInfo,
        tagInfo.cast<Void>(),
        8,
      );
      if (ok == 0) return null;
      tag = tagInfo[1];
    }
    final serial = arena<Uint32>();
    final flags = arena<Uint32>();
    final system = arena.pwstrBuffer(_volumeNameChars);
    final Win32Result(value: volumeKnown) = GetVolumeInformationByHandle(
      handle,
      null,
      0,
      serial,
      null,
      flags,
      system,
      _volumeNameChars,
    );
    if (!volumeKnown) return null;
    var systemName = system.toDartString().replaceAll(
      RegExp(r'[^A-Za-z0-9]'),
      '',
    );
    if (systemName.length > _volumeSystemChars) {
      systemName = systemName.substring(0, _volumeSystemChars);
    }
    final serialHex = serial.value
        .toRadixString(16)
        .padLeft(_volumeSerialDigits, '0');
    final buffer = arena.pwstrBuffer(_finalPathChars);
    final Win32Result(value: length) = GetFinalPathNameByHandle(
      handle,
      buffer,
      _finalPathChars,
      FILE_NAME_NORMALIZED,
    );
    if (length == 0 || length >= _finalPathChars) return null;
    return FolderFacts(
      attributes: attributes,
      reparseTag: tag,
      volumeId: '$systemName-$serialHex',
      supportsNamedStreams: (flags.value & FILE_NAMED_STREAMS) != 0,
      finalPath: stripExtendedPrefix(buffer.toDartString(length: length)),
    );
  });
}

DirectoryBatches directoryBatchesSync(int handleAddress) =>
    _FolderBatches(handleAddress);

final class _FolderBatches implements DirectoryBatches {
  _FolderBatches(int handleAddress)
    : _handle = _handleOf(handleAddress),
      _buffer = calloc<Uint8>(_listBufferBytes),
      _status = calloc<IoStatusBlock>();

  final HANDLE _handle;
  final Pointer<Uint8> _buffer;
  final Pointer<IoStatusBlock> _status;
  bool _first = true;
  bool _done = false;
  bool _closed = false;

  @override
  List<RawEntry>? next() {
    if (_closed || _done) return null;
    final code =
        loadNtQueryDirectoryFile()(
          _handle.cast<Void>(),
          nullptr,
          nullptr,
          nullptr,
          _status,
          _buffer.cast<Void>(),
          _listBufferBytes,
          _fullDirectoryInformation,
          0,
          nullptr,
          _first ? 1 : 0,
        ) &
        0xFFFFFFFF;
    if (code == _statusNoMoreFiles || (_first && code == _statusNoSuchFile)) {
      _done = true;
      return null;
    }
    if (code != 0) {
      _done = true;
      throw const FileSystemException('The folder could not be listed');
    }
    _first = false;
    final entries = <RawEntry>[];
    var offset = 0;
    while (true) {
      final record = _buffer + offset;
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
      final nextOffset = fields[0];
      if (nextOffset == 0) break;
      offset += nextOffset;
    }
    return entries;
  }

  @override
  void close() {
    if (_closed) return;
    _closed = true;
    calloc.free(_buffer);
    calloc.free(_status);
  }
}

void closeHandleSync(int handleAddress) => _handleOf(handleAddress).close();
