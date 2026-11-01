import '../protocol/protocol.dart' show Limits;
import 'folders.dart' show isSameOrInside;
import 'manifest.dart' show ManifestBuilder;
import 'names.dart' show isAppReservedName, isBlockedType, isValidFileName;
import 'transfer.dart' show TransferOutcome;

final class ListedEntry {
  const ListedEntry({
    required this.name,
    required this.isDirectory,
    required this.reparseTag,
    required this.size,
  });

  final String name;
  final bool isDirectory;
  final int? reparseTag;
  final int size;
}

abstract interface class FolderLister {
  List<ListedEntry> list(String directoryPath);
}

bool isLinkTag(int tag) => (tag & 0x20000000) != 0 || tag == 0x8000001B;

final class WalkResult {
  WalkResult(this.builder);

  final ManifestBuilder builder;
  int linksOmitted = 0;
  int protectedOmitted = 0;
  int blockedOmitted = 0;
  int excludedFolders = 0;
  final List<String> excludedPaths = [];
  TransferOutcome? stopped;
  String? problemPath;
  bool cancelled = false;
}

final class _Pending {
  const _Pending(this.index, this.path, this.relative, this.depth);

  final int index;
  final String path;
  final String relative;
  final int depth;
}

String _join(String folder, String name) =>
    folder.endsWith(r'\') ? '$folder$name' : '$folder\\$name';

WalkResult walkFolder({
  required FolderLister lister,
  required String rootPath,
  required Set<String> exclusions,
  required String dataDirRealPath,
  bool Function()? isCancelled,
  void Function(int entries)? onProgress,
}) {
  final builder = ManifestBuilder();
  final result = WalkResult(builder);
  final pending = <_Pending>[_Pending(0, rootPath, '', 0)];

  void stop(TransferOutcome outcome, String? path) {
    result.stopped = outcome;
    result.problemPath = path;
  }

  while (pending.isNotEmpty) {
    if (isCancelled != null && isCancelled()) {
      result.cancelled = true;
      return result;
    }
    final folder = pending.removeLast();
    final List<ListedEntry> listed;
    try {
      listed = lister.list(folder.path);
    } catch (_) {
      stop(
        TransferOutcome.unreadable,
        folder.relative.isEmpty ? null : folder.relative,
      );
      return result;
    }
    listed.sort((a, b) {
      final byUpper = a.name.toUpperCase().compareTo(b.name.toUpperCase());
      return byUpper != 0 ? byUpper : a.name.compareTo(b.name);
    });
    final siblings = <String>{};
    final subfolders = <_Pending>[];
    for (final entry in listed) {
      final relative = folder.relative.isEmpty
          ? entry.name
          : _join(folder.relative, entry.name);
      final tag = entry.reparseTag;
      if (tag != null && isLinkTag(tag)) {
        result.linksOmitted++;
        continue;
      }
      final childDepth = folder.depth + 1;
      if (entry.isDirectory) {
        final childPath = _join(folder.path, entry.name);
        if (isAppReservedName(entry.name) ||
            (dataDirRealPath.isNotEmpty &&
                isSameOrInside(childPath, dataDirRealPath))) {
          result.protectedOmitted++;
          continue;
        }
        if (exclusions.contains(entry.name.toUpperCase())) {
          result.excludedFolders++;
          result.excludedPaths.add(childPath);
          continue;
        }
        if (!isValidFileName(entry.name)) {
          stop(TransferOutcome.invalidName, relative);
          return result;
        }
        if (isBlockedType(entry.name)) {
          result.blockedOmitted++;
          continue;
        }
        if (childDepth > Limits.maxFolderDepth) {
          stop(TransferOutcome.tooDeep, relative);
          return result;
        }
        if (!siblings.add(entry.name.toUpperCase())) {
          stop(TransferOutcome.invalidName, relative);
          return result;
        }
        final index = builder.addFolder(folder.index, entry.name);
        subfolders.add(_Pending(index, childPath, relative, childDepth));
      } else {
        if (isAppReservedName(entry.name)) {
          result.protectedOmitted++;
          continue;
        }
        if (isBlockedType(entry.name)) {
          result.blockedOmitted++;
          continue;
        }
        if (!isValidFileName(entry.name)) {
          stop(TransferOutcome.invalidName, relative);
          return result;
        }
        if (childDepth > Limits.maxFolderDepth) {
          stop(TransferOutcome.tooDeep, relative);
          return result;
        }
        if (!siblings.add(entry.name.toUpperCase())) {
          stop(TransferOutcome.invalidName, relative);
          return result;
        }
        builder.addFile(folder.index, entry.name, entry.size);
      }
      if (builder.length > Limits.maxFolderEntries) {
        stop(TransferOutcome.tooManyEntries, null);
        return result;
      }
    }
    pending.addAll(subfolders.reversed);
    onProgress?.call(builder.length);
  }
  return result;
}

final class FolderMeasure {
  const FolderMeasure({required this.bytes, required this.partial});

  final int bytes;
  final bool partial;
}

FolderMeasure measureFolders({
  required FolderLister lister,
  required List<String> roots,
  required Duration Function() elapsed,
  required bool Function() isCancelled,
  int maxEntries = Limits.folderMeasureMaxEntries,
  Duration cap = Limits.folderMeasureCap,
}) {
  final pending = List<String>.of(roots.reversed);
  var bytes = 0;
  var entries = 0;
  var partial = false;
  while (pending.isNotEmpty) {
    if (isCancelled() || elapsed() >= cap) {
      return FolderMeasure(bytes: bytes, partial: true);
    }
    final folder = pending.removeLast();
    final List<ListedEntry> listed;
    try {
      listed = lister.list(folder);
    } catch (_) {
      partial = true;
      continue;
    }
    for (final entry in listed) {
      final tag = entry.reparseTag;
      if (tag != null && isLinkTag(tag)) continue;
      entries++;
      if (entries > maxEntries) {
        return FolderMeasure(bytes: bytes, partial: true);
      }
      if (entry.isDirectory) {
        pending.add(_join(folder, entry.name));
      } else {
        bytes += entry.size;
      }
    }
  }
  return FolderMeasure(bytes: bytes, partial: partial);
}
