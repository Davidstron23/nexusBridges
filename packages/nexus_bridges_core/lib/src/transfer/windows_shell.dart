import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';

import 'package:ffi/ffi.dart';
import 'package:win32/win32.dart';

import 'platform.dart';
import 'transfer.dart' show RevealResult;

const int _shellExecuteSuccessAbove = 32;

typedef _IlCreateFromPathNative = Pointer<Void> Function(Pointer<Utf16>);

typedef _IlCreateFromPath = Pointer<Void> Function(Pointer<Utf16>);

typedef _IlFreeNative = Void Function(Pointer<Void>);

typedef _IlFree = void Function(Pointer<Void>);

typedef _OpenFolderAndSelectNative = Int32 Function(
  Pointer<Void>,
  Uint32,
  Pointer<Pointer<Void>>,
  Uint32,
);

typedef _OpenFolderAndSelect = int Function(
  Pointer<Void>,
  int,
  Pointer<Pointer<Void>>,
  int,
);

final class WindowsFilePicker implements FilePicker {
  const WindowsFilePicker({
    required this.ownerWindowClass,
    required this.ownerWindowTitle,
  });

  final String ownerWindowClass;
  final String ownerWindowTitle;

  @override
  Future<String?> pickFile() {
    final windowClass = ownerWindowClass;
    final windowTitle = ownerWindowTitle;
    return _pickInIsolate(
      () => _pickSync(windowClass, windowTitle, folder: false, startIn: null),
    );
  }

  @override
  Future<String?> pickFolder({String? startIn}) {
    final windowClass = ownerWindowClass;
    final windowTitle = ownerWindowTitle;
    return _pickInIsolate(
      () => _pickSync(windowClass, windowTitle, folder: true, startIn: startIn),
    );
  }
}

final class WindowsFolderRevealer implements FolderRevealer {
  const WindowsFolderRevealer();

  @override
  Future<RevealResult> reveal(String filePath) async {
    if (!_isAbsoluteWindowsPath(filePath)) return RevealResult.unavailable;
    try {
      return await Isolate.run(() => _revealSync(filePath));
    } catch (_) {
      return RevealResult.unavailable;
    }
  }
}

final RegExp _driveAbsolutePath = RegExp(r'^[A-Za-z]:\\');

final RegExp _uncAbsolutePath = RegExp(r'^\\\\[^\\?.][^\\]*\\[^\\]+');

bool _isAbsoluteWindowsPath(String path) =>
    _driveAbsolutePath.hasMatch(path) || _uncAbsolutePath.hasMatch(path);

RevealResult revealPlanFor(bool itemExists, bool parentExists) {
  if (itemExists) return RevealResult.shown;
  if (parentExists) return RevealResult.folderOnly;
  return RevealResult.unavailable;
}

Future<String?> _pickInIsolate(String? Function() work) async {
  try {
    return await Isolate.run(work);
  } catch (_) {
    return null;
  }
}

HWND? _findOwner(Arena arena, String windowClass, String windowTitle) {
  if (windowClass.isEmpty && windowTitle.isEmpty) return null;
  final Win32Result(:value) = FindWindow(
    windowClass.isEmpty ? null : arena.pcwstr(windowClass),
    windowTitle.isEmpty ? null : arena.pcwstr(windowTitle),
  );
  return value == nullptr ? null : value;
}

void _setStartFolder(Arena arena, IFileOpenDialog dialog, String startIn) {
  try {
    if (!Directory(startIn).existsSync()) return;
    final folder = SHCreateItemFromParsingName<IShellItem>(
      arena.pcwstr(startIn),
      null,
    );
    try {
      dialog.setFolder(folder);
    } finally {
      folder.release();
    }
  } catch (_) {
    return;
  }
}

String? _chosenPath(IFileOpenDialog dialog) {
  final item = dialog.getResult();
  if (item == null) return null;
  try {
    final name = item.getDisplayName(SIGDN_FILESYSPATH);
    try {
      final text = name.toDartString();
      return text.isEmpty ? null : text;
    } finally {
      CoTaskMemFree(name);
    }
  } finally {
    item.release();
  }
}

String? _pickSync(
  String windowClass,
  String windowTitle, {
  required bool folder,
  required String? startIn,
}) {
  if (!CoInitializeEx(COINIT_APARTMENTTHREADED).isOk) return null;
  try {
    return using((arena) {
      final dialog = createInstance<IFileOpenDialog>(FileOpenDialog);
      try {
        final options = dialog.getOptions();
        dialog.setOptions(
          folder
              ? options |
                    FOS_PICKFOLDERS |
                    FOS_FORCEFILESYSTEM |
                    FOS_PATHMUSTEXIST
              : options |
                    FOS_FORCEFILESYSTEM |
                    FOS_FILEMUSTEXIST |
                    FOS_PATHMUSTEXIST,
        );
        if (folder && startIn != null && startIn.isNotEmpty) {
          _setStartFolder(arena, dialog, startIn);
        }
        dialog.show(_findOwner(arena, windowClass, windowTitle));
        return _chosenPath(dialog);
      } finally {
        dialog.release();
      }
    });
  } catch (_) {
    return null;
  } finally {
    CoUninitialize();
  }
}

RevealResult _revealSync(String filePath) {
  if (!CoInitializeEx(COINIT_APARTMENTTHREADED).isOk) {
    return RevealResult.unavailable;
  }
  try {
    final shell = DynamicLibrary.open('shell32.dll');
    final createPidl = shell
        .lookupFunction<_IlCreateFromPathNative, _IlCreateFromPath>(
          'ILCreateFromPathW',
        );
    final freePidl = shell.lookupFunction<_IlFreeNative, _IlFree>('ILFree');
    final openAndSelect = shell
        .lookupFunction<_OpenFolderAndSelectNative, _OpenFolderAndSelect>(
          'SHOpenFolderAndSelectItems',
        );
    final folderPath = File(filePath).parent.path;
    final plan = revealPlanFor(
      _isFileOrFolder(FileSystemEntity.typeSync(filePath)),
      FileSystemEntity.typeSync(folderPath) == FileSystemEntityType.directory,
    );
    switch (plan) {
      case RevealResult.shown:
        var selected = false;
        try {
          selected = _selectInFolder(
            filePath,
            createPidl,
            freePidl,
            openAndSelect,
          );
        } catch (_) {
          selected = false;
        }
        if (selected) return RevealResult.shown;
        return _exploreFolder(folderPath)
            ? RevealResult.folderOnly
            : RevealResult.unavailable;
      case RevealResult.folderOnly:
        return _exploreFolder(folderPath)
            ? RevealResult.folderOnly
            : RevealResult.unavailable;
      case RevealResult.unavailable:
        return RevealResult.unavailable;
    }
  } catch (_) {
    return RevealResult.unavailable;
  } finally {
    CoUninitialize();
  }
}

bool _isFileOrFolder(FileSystemEntityType type) =>
    type == FileSystemEntityType.file || type == FileSystemEntityType.directory;

bool _selectInFolder(
  String filePath,
  _IlCreateFromPath createPidl,
  _IlFree freePidl,
  _OpenFolderAndSelect openAndSelect,
) {
  return using((arena) {
    final pidl = createPidl(arena.pcwstr(filePath));
    if (pidl == nullptr) return false;
    try {
      return HRESULT(openAndSelect(pidl, 0, nullptr, 0)).isOk;
    } finally {
      freePidl(pidl);
    }
  });
}

bool _exploreFolder(String folderPath) {
  return using((arena) {
    final result = ShellExecute(
      null,
      arena.pcwstr('explore'),
      arena.pcwstr(folderPath),
      null,
      null,
      SW_SHOWNORMAL,
    );
    return result.address > _shellExecuteSuccessAbove;
  });
}
