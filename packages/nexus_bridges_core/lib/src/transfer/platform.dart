import '../protocol/protocol.dart' show Limits;
import 'names.dart' show isProgram, windowsExtension;
import 'transfer.dart' show RevealResult;

final class VolumeFacts {
  const VolumeFacts({
    required this.volumeId,
    required this.supportsNamedStreams,
    required this.isRemote,
  });

  final String volumeId;
  final bool supportsNamedStreams;
  final bool isRemote;
}

final class SystemFolders {
  const SystemFolders({
    this.downloads,
    this.startup,
    this.commonStartup,
    this.startMenu,
    this.commonStartMenu,
    this.windows,
    this.programFiles,
    this.programFilesX86,
    this.systemDriveRoot,
  });

  final String? downloads;
  final String? startup;
  final String? commonStartup;
  final String? startMenu;
  final String? commonStartMenu;
  final String? windows;
  final String? programFiles;
  final String? programFilesX86;
  final String? systemDriveRoot;
}

enum MoveOutcome { moved, nameTaken, failed }

sealed class FreeNameMove {
  const FreeNameMove();
}

final class MovedTo extends FreeNameMove {
  const MovedTo(this.finalName);

  final String finalName;
}

final class NoFreeName extends FreeNameMove {
  const NoFreeName();
}

final class MoveFailed extends FreeNameMove {
  const MoveFailed();
}

final class NameTooLong extends FreeNameMove {
  const NameTooLong();
}

abstract interface class FileSystemPlatform {
  Future<String?> realPath(String path);

  Future<VolumeFacts?> volumeFacts(String path);

  Future<int?> freeBytes(String path);

  Future<bool> isCloudSynced(String path);

  Future<SystemFolders> systemFolders();

  Future<bool> setHidden(String path);

  Future<MoveOutcome> moveNoReplace(String from, String to);

  Future<FreeNameMove> moveToFreeName(String from, String folder, String name);

  Future<FreeNameMove> moveFolderToFreeName(
    String from,
    String folder,
    String name, {
    required int maxNameUnits,
  });

  Future<bool> markFromInternet(String filePath);

  Future<bool> deleteTree(String path);

  Future<bool> isDangerousType(String extension);

  Future<Set<String>> dangerousExtensions(Set<String> extensions);
}

Future<bool> isProgramHere(
  String name,
  FileSystemPlatform fs, {
  Duration timeout = Limits.transferTypeCheckTimeout,
}) async {
  if (isProgram(name)) return true;
  final extension = windowsExtension(name);
  if (extension == null) return false;
  try {
    return await fs.isDangerousType(extension).timeout(timeout);
  } catch (_) {
    return false;
  }
}

abstract interface class FilePicker {
  Future<String?> pickFile();

  Future<String?> pickFolder({String? startIn});

  Future<List<String>> pickFiles();

  Future<List<String>> pickFolders();
}

abstract interface class FolderRevealer {
  Future<RevealResult> reveal(String filePath);
}
