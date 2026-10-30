import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';

import 'package:ffi/ffi.dart';
import 'package:win32/win32.dart';

import '../protocol/protocol.dart' show Limits;
import 'names.dart'
    show
        baseName,
        candidateFolderName,
        candidateName,
        isBlockedType,
        isValidFileName;
import 'platform.dart';
import 'windows_folder_io.dart'
    show extendedPath, isDangerousTypeSync, stripExtendedPrefix;

const int _moved = -2;
const int _lostCode = -1;
const int _errorAccessDenied = 5;
const int _errorSharingViolation = 32;
const int _errorFileExists = 80;
const int _errorAlreadyExists = 183;
const int _hresultMoreData = 0x800700EA;
const int _invalidFileAttributes = 0xFFFFFFFF;
const int _finalPathChars = 32768;
const int _volumeNameChars = 261;
const int _syncRootInfoBytes = 1024;
const int _syncRootInfoBasic = 0;
const int _volumeSerialDigits = 8;
const int _volumeSystemChars = 16;
const int _maxNameAttempts = 9999;

const List<Duration> _moveRetryWaits = [
  Duration(milliseconds: 20),
  Duration(milliseconds: 40),
  Duration(milliseconds: 80),
  Duration(milliseconds: 160),
  Duration(milliseconds: 320),
];

const List<Duration> _folderMoveRetryWaits = [
  Duration(milliseconds: 20),
  Duration(milliseconds: 40),
  Duration(milliseconds: 80),
  Duration(milliseconds: 160),
  Duration(milliseconds: 320),
  Duration(milliseconds: 640),
  Duration(milliseconds: 640),
  Duration(milliseconds: 640),
  Duration(milliseconds: 640),
  Duration(milliseconds: 640),
];

const String _zoneIdentifierText = '[ZoneTransfer]\r\nZoneId=3\r\n';

typedef _CfGetSyncRootInfoNative = Int32 Function(
  Pointer<Utf16>,
  Int32,
  Pointer<Void>,
  Uint32,
  Pointer<Uint32>,
);

typedef _CfGetSyncRootInfo = int Function(
  Pointer<Utf16>,
  int,
  Pointer<Void>,
  int,
  Pointer<Uint32>,
);

final class WindowsFileSystemPlatform implements FileSystemPlatform {
  const WindowsFileSystemPlatform();

  @override
  Future<String?> realPath(String path) =>
      _inIsolate<String?>(() => _realPathSync(path), null);

  @override
  Future<VolumeFacts?> volumeFacts(String path) =>
      _inIsolate<VolumeFacts?>(() => _volumeFactsSync(path), null);

  @override
  Future<int?> freeBytes(String path) =>
      _inIsolate<int?>(() => _freeBytesSync(path), null);

  @override
  Future<bool> isCloudSynced(String path) =>
      _inIsolate<bool>(() => _isCloudSyncedSync(path), false);

  @override
  Future<SystemFolders> systemFolders() =>
      _inIsolate<SystemFolders>(_systemFoldersSync, const SystemFolders());

  @override
  Future<bool> setHidden(String path) =>
      _inIsolate<bool>(() => _setHiddenSync(path), false);

  @override
  Future<MoveOutcome> moveNoReplace(String from, String to) =>
      _inIsolate<MoveOutcome>(
        () => _moveNoReplaceSync(from, to),
        MoveOutcome.failed,
      );

  @override
  Future<FreeNameMove> moveToFreeName(
    String from,
    String folder,
    String name,
  ) => _inIsolate<FreeNameMove>(
    () => _moveToFreeNameSync(from, folder, name),
    const MoveFailed(),
  );

  @override
  Future<FreeNameMove> moveFolderToFreeName(
    String from,
    String folder,
    String name, {
    required int maxNameUnits,
  }) => _inIsolate<FreeNameMove>(
    () => _moveFolderToFreeNameSync(from, folder, name, maxNameUnits),
    const MoveFailed(),
  );

  @override
  Future<bool> markFromInternet(String filePath) async {
    try {
      if (!await File(filePath).exists()) return false;
      final stream = File('$filePath:Zone.Identifier');
      await stream.writeAsString(_zoneIdentifierText, flush: true);
      return await stream.readAsString() == _zoneIdentifierText;
    } catch (_) {
      return false;
    }
  }

  @override
  Future<bool> isDangerousType(String extension) =>
      _inIsolate<bool>(() => isDangerousTypeSync(extension), false);
}

Future<T> _inIsolate<T>(T Function() work, T fallback) async {
  try {
    return await Isolate.run(work);
  } catch (_) {
    return fallback;
  }
}

HANDLE? _openForQuery(Arena arena, String path) {
  final Win32Result(:value) = CreateFile(
    arena.pcwstr(path),
    FILE_READ_ATTRIBUTES,
    FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE,
    null,
    OPEN_EXISTING,
    FILE_FLAG_BACKUP_SEMANTICS,
    null,
  );
  return value.isValid ? value : null;
}

T? _withHandle<T>(String path, T? Function(Arena arena, HANDLE handle) body) {
  return using((arena) {
    final handle = _openForQuery(arena, path);
    if (handle == null) return null;
    try {
      return body(arena, handle);
    } finally {
      handle.close();
    }
  });
}

bool _isUncPath(String path) {
  if (path.startsWith(r'\\?\UNC\')) return true;
  return path.startsWith(r'\\') &&
      !path.startsWith(r'\\?\') &&
      !path.startsWith(r'\\.\');
}

bool _pathExists(Arena arena, String path) {
  final Win32Result(:value) = GetFileAttributes(arena.pcwstr(path));
  return value != _invalidFileAttributes;
}

String? _realPathSync(String path) {
  return _withHandle<String>(path, (arena, handle) {
    final buffer = arena.pwstrBuffer(_finalPathChars);
    final Win32Result(:value) = GetFinalPathNameByHandle(
      handle,
      buffer,
      _finalPathChars,
      FILE_NAME_NORMALIZED,
    );
    if (value == 0 || value >= _finalPathChars) return null;
    return stripExtendedPrefix(buffer.toDartString(length: value));
  });
}

VolumeFacts? _volumeFactsSync(String path) {
  return _withHandle<VolumeFacts>(path, (arena, handle) {
    final serial = arena<Uint32>();
    final flags = arena<Uint32>();
    final system = arena.pwstrBuffer(_volumeNameChars);
    final Win32Result(:value) = GetVolumeInformationByHandle(
      handle,
      null,
      0,
      serial,
      null,
      flags,
      system,
      _volumeNameChars,
    );
    if (!value) return null;
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
    return VolumeFacts(
      volumeId: '$systemName-$serialHex',
      supportsNamedStreams: (flags.value & FILE_NAMED_STREAMS) != 0,
      isRemote: _isRemote(arena, path),
    );
  });
}

bool _isRemote(Arena arena, String path) {
  if (_isUncPath(path)) return true;
  final root = arena.pwstrBuffer(_finalPathChars);
  final Win32Result(:value) = GetVolumePathName(
    arena.pcwstr(path),
    root,
    _finalPathChars,
  );
  if (!value) return false;
  return GetDriveType(PCWSTR(root)) == DRIVE_REMOTE;
}

int? _freeBytesSync(String path) {
  return using((arena) {
    final available = arena<Uint64>();
    final Win32Result(:value) = GetDiskFreeSpaceEx(
      arena.pcwstr(path),
      available,
      null,
      null,
    );
    return value ? available.value : null;
  });
}

bool _isCloudSyncedSync(String path) {
  try {
    final library = DynamicLibrary.open('cldapi.dll');
    final query = library
        .lookupFunction<_CfGetSyncRootInfoNative, _CfGetSyncRootInfo>(
          'CfGetSyncRootInfoByPath',
        );
    return using((arena) {
      final buffer = arena<Uint8>(_syncRootInfoBytes);
      final returned = arena<Uint32>();
      final result =
          query(
            arena.pcwstr(path),
            _syncRootInfoBasic,
            buffer.cast<Void>(),
            _syncRootInfoBytes,
            returned,
          ) &
          0xFFFFFFFF;
      return result == 0 || result == _hresultMoreData;
    });
  } catch (_) {
    return false;
  }
}

String? _knownFolder(Arena arena, GUID id) {
  try {
    final path = SHGetKnownFolderPath(
      id.toNative(allocator: arena),
      KF_FLAG_DEFAULT,
      null,
    );
    try {
      final text = path.toDartString();
      return text.isEmpty ? null : text;
    } finally {
      CoTaskMemFree(path);
    }
  } catch (_) {
    return null;
  }
}

String? _environmentPath(String name, [String? suffix]) {
  final base = Platform.environment[name];
  if (base == null || base.isEmpty) return null;
  return suffix == null ? base : '$base\\$suffix';
}

String? _systemDriveRoot(String? windows) {
  if (windows != null &&
      windows.length >= 3 &&
      windows[1] == ':' &&
      windows[2] == r'\') {
    return windows.substring(0, 3);
  }
  final drive = Platform.environment['SystemDrive'];
  if (drive == null || drive.isEmpty) return null;
  return '$drive\\';
}

SystemFolders _systemFoldersSync() {
  return using((arena) {
    final windows =
        _knownFolder(arena, FOLDERID_Windows) ?? _environmentPath('WINDIR');
    return SystemFolders(
      downloads:
          _knownFolder(arena, FOLDERID_Downloads) ??
          _environmentPath('USERPROFILE', 'Downloads'),
      startup:
          _knownFolder(arena, FOLDERID_Startup) ??
          _environmentPath(
            'APPDATA',
            r'Microsoft\Windows\Start Menu\Programs\Startup',
          ),
      commonStartup:
          _knownFolder(arena, FOLDERID_CommonStartup) ??
          _environmentPath(
            'ProgramData',
            r'Microsoft\Windows\Start Menu\Programs\StartUp',
          ),
      startMenu:
          _knownFolder(arena, FOLDERID_StartMenu) ??
          _environmentPath('APPDATA', r'Microsoft\Windows\Start Menu'),
      commonStartMenu:
          _knownFolder(arena, FOLDERID_CommonStartMenu) ??
          _environmentPath('ProgramData', r'Microsoft\Windows\Start Menu'),
      windows: windows,
      programFiles:
          _knownFolder(arena, FOLDERID_ProgramFiles) ??
          _environmentPath('ProgramFiles'),
      programFilesX86:
          _knownFolder(arena, FOLDERID_ProgramFilesX86) ??
          _environmentPath('ProgramFiles(x86)'),
      systemDriveRoot: _systemDriveRoot(windows),
    );
  });
}

bool _setHiddenSync(String path) {
  return using((arena) {
    final name = arena.pcwstr(path);
    final Win32Result(value: attributes) = GetFileAttributes(name);
    if (attributes == _invalidFileAttributes) return false;
    final Win32Result(:value) = SetFileAttributes(
      name,
      FILE_ATTRIBUTE_HIDDEN | attributes,
    );
    return value;
  });
}

MoveOutcome _moveNoReplaceSync(
  String from,
  String to, {
  List<Duration> waits = _moveRetryWaits,
}) {
  final source = extendedPath(from);
  final target = extendedPath(to);
  var retry = 0;
  while (true) {
    final int code = using((arena) {
      final Win32Result(:value, error: lastError) = MoveFileEx(
        arena.pcwstr(source),
        arena.pcwstr(target),
        const MOVE_FILE_FLAGS(0),
      );
      if (value) return _moved;
      final unknown = lastError == 0;
      if ((unknown || lastError == _errorAccessDenied) &&
          _pathExists(arena, target)) {
        return _errorAlreadyExists;
      }
      return unknown ? _lostCode : lastError;
    });
    if (code == _moved) return MoveOutcome.moved;
    if (code == _errorFileExists || code == _errorAlreadyExists) {
      return MoveOutcome.nameTaken;
    }
    final retryable =
        code == _errorSharingViolation ||
        code == _errorAccessDenied ||
        code == _lostCode;
    if (!retryable || retry >= waits.length) {
      return MoveOutcome.failed;
    }
    sleep(waits[retry]);
    retry++;
  }
}

FreeNameMove _moveToFreeNameSync(String from, String folder, String name) {
  if (!isValidFileName(name) || isBlockedType(name)) return const MoveFailed();
  final taken = <String>{};
  try {
    for (final entry in Directory(folder).listSync(followLinks: false)) {
      taken.add(baseName(entry.path).toUpperCase());
    }
  } catch (_) {
    return const MoveFailed();
  }
  final prefix = folder.endsWith(r'\') ? folder : '$folder\\';
  for (var n = 0; n <= _maxNameAttempts; n++) {
    final candidate = candidateName(name, n);
    if (candidate == null) continue;
    final upper = candidate.toUpperCase();
    if (taken.contains(upper)) continue;
    final target = '$prefix$candidate';
    if (target.length > Limits.maxFinalPathChars) return const MoveFailed();
    switch (_moveNoReplaceSync(from, target)) {
      case MoveOutcome.moved:
        return MovedTo(candidate);
      case MoveOutcome.nameTaken:
        taken.add(upper);
      case MoveOutcome.failed:
        return const MoveFailed();
    }
  }
  return const NoFreeName();
}

FreeNameMove _moveFolderToFreeNameSync(
  String from,
  String folder,
  String name,
  int maxNameUnits,
) {
  if (!isValidFileName(name) || isBlockedType(name)) return const MoveFailed();
  final taken = <String>{};
  try {
    for (final entry in Directory(folder).listSync(followLinks: false)) {
      taken.add(baseName(entry.path).toUpperCase());
    }
  } catch (_) {
    return const MoveFailed();
  }
  final prefix = folder.endsWith(r'\') ? folder : '$folder\\';
  for (var n = 0; n <= _maxNameAttempts; n++) {
    final candidate = candidateFolderName(name, n);
    if (candidate == null) return const NameTooLong();
    if (candidate.length > maxNameUnits) return const NameTooLong();
    final upper = candidate.toUpperCase();
    if (taken.contains(upper)) continue;
    switch (_moveNoReplaceSync(
      from,
      '$prefix$candidate',
      waits: _folderMoveRetryWaits,
    )) {
      case MoveOutcome.moved:
        return MovedTo(candidate);
      case MoveOutcome.nameTaken:
        taken.add(upper);
      case MoveOutcome.failed:
        return const MoveFailed();
    }
  }
  return const NoFreeName();
}
