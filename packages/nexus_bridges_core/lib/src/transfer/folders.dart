import 'dart:io';
import 'dart:math';

import '../protocol/protocol.dart' show Limits;
import '../transport/transport.dart' show AbortSignal;
import 'names.dart' show baseName, isValidFileName;
import 'platform.dart';

const String tempFolderName = '.nexusbridges-incoming';
const String tempPrefix = '~nexusbridges-';
const String tempSuffix = '.partial';

final class ForbiddenFolders {
  const ForbiddenFolders({required this.trees, required this.exact});

  final List<String> trees;
  final List<String> exact;
}

final class ReceiveTarget {
  const ReceiveTarget({
    required this.path,
    required this.volumeId,
    required this.supportsMark,
    required this.remote,
    required this.cloud,
    required this.freeBytes,
  });

  final String path;
  final String volumeId;
  final bool supportsMark;
  final bool remote;
  final bool cloud;
  final int? freeBytes;
}

sealed class FolderInspection {
  const FolderInspection();
}

final class FolderUsable extends FolderInspection {
  const FolderUsable(this.target, {required this.createdNow});

  final ReceiveTarget target;
  final bool createdNow;
}

final class FolderRefused extends FolderInspection {
  const FolderRefused(this.reason);

  final FolderRefusal reason;
}

enum FolderRefusal {
  forbidden,
  cannotUse,
  unknownVolume,
  otherVolume,
  adminShare,
}

final RegExp _driveRoot = RegExp(r'^[A-Za-z]:\\$');
final RegExp _driveOnly = RegExp(r'^[A-Za-z]:$');
final RegExp _absolutePath = RegExp(r'^(?:[A-Za-z]:\\|\\\\[^\\]+\\[^\\]+)');
final RegExp _badPathChars = RegExp(r'[*?"<>|:\u0000-\u001F]');
final RegExp _uncServerOnly = RegExp(r'^\\\\[^\\]*$');
final RegExp _ownTempName = RegExp(r'^~nexusbridges-[0-9a-f]{32}\.partial$');
final RegExp _ownFolderTempName = RegExp(r'^~nexusbridges-[0-9a-f]{12}$');
final RegExp _deviceUncPrefix = RegExp(r'^\\\\\.\\UNC\\', caseSensitive: false);
final RegExp _uncShare = RegExp(r'^\\\\([^\\]+)\\([^\\]+)(?:\\|$)');

String _normalize(String path) {
  var normalized = path.replaceAll('/', r'\');
  while (normalized.length > 1 &&
      normalized.endsWith(r'\') &&
      !_driveRoot.hasMatch(normalized)) {
    normalized = normalized.substring(0, normalized.length - 1);
  }
  return normalized;
}

String _join(String folder, String name) =>
    folder.endsWith(r'\') ? '$folder$name' : '$folder\\$name';

String? _parentOf(String normalized) {
  final cut = normalized.lastIndexOf(r'\');
  if (cut < 0) return null;
  final parent = normalized.substring(0, cut);
  if (_driveOnly.hasMatch(parent)) return '$parent\\';
  if (parent.isEmpty || _uncServerOnly.hasMatch(parent)) return null;
  return parent;
}

bool _isUsablePath(String normalized) {
  if (!_absolutePath.hasMatch(normalized)) return false;
  return !_badPathChars.hasMatch(normalized.substring(2));
}

bool samePath(String a, String b) =>
    _normalize(a).toUpperCase() == _normalize(b).toUpperCase();

bool isAdminShare(String path) {
  var normalized = path.replaceAll('/', r'\');
  if (_deviceUncPrefix.hasMatch(normalized)) {
    normalized = r'\\' + normalized.substring(8);
  }
  final match = _uncShare.firstMatch(normalized);
  return match != null && match.group(2)!.endsWith(r'$');
}

bool isInsideTempFolder(String path) {
  final upperTemp = tempFolderName.toUpperCase();
  return _normalize(path)
      .split(r'\')
      .any((segment) => segment.toUpperCase() == upperTemp);
}

bool isSameOrInside(String path, String ancestor) {
  final inner = _normalize(path).toUpperCase();
  final outer = _normalize(ancestor).toUpperCase();
  if (inner == outer) return true;
  final prefix = outer.endsWith(r'\') ? outer : '$outer\\';
  return inner.startsWith(prefix);
}

bool isForbiddenFolder(String realPath, ForbiddenFolders forbidden) {
  return forbidden.trees.any((tree) => isSameOrInside(realPath, tree)) ||
      forbidden.exact.any((exact) => samePath(realPath, exact));
}

Future<ForbiddenFolders?> loadForbiddenFolders(
  FileSystemPlatform fs,
  SystemFolders folders, {
  required List<String> dataDirs,
}) async {
  final windows = folders.windows;
  final programFiles = folders.programFiles;
  final startup = folders.startup;
  final startMenu = folders.startMenu;
  final systemDriveRoot = folders.systemDriveRoot;
  if (windows == null ||
      programFiles == null ||
      startup == null ||
      startMenu == null ||
      systemDriveRoot == null) {
    return null;
  }
  final trees = <String>[];
  for (final path in [
    startup,
    folders.commonStartup,
    startMenu,
    folders.commonStartMenu,
    windows,
    programFiles,
    folders.programFilesX86,
  ]) {
    if (path == null) continue;
    trees.add(await fs.realPath(path) ?? path);
  }
  for (final dir in dataDirs) {
    var exists = false;
    try {
      exists = await Directory(dir).exists();
    } catch (_) {}
    trees.add(exists ? await fs.realPath(dir) ?? dir : dir);
  }
  return ForbiddenFolders(trees: trees, exact: [systemDriveRoot]);
}

bool _isAborted(AbortSignal? abort) => abort != null && abort.aborted;

Future<void> _deleteIfEmpty(String path) async {
  try {
    await Directory(path).delete();
  } catch (_) {}
}

Future<bool> _isDirectory(String path) async {
  try {
    return await Directory(path).exists();
  } catch (_) {
    return false;
  }
}

String _randomHex32() {
  final random = Random.secure();
  final buffer = StringBuffer();
  for (var i = 0; i < 16; i++) {
    buffer.write(random.nextInt(256).toRadixString(16).padLeft(2, '0'));
  }
  return buffer.toString();
}

Future<FolderInspection> inspectFolder(
  String path, {
  required FileSystemPlatform fs,
  required ForbiddenFolders? forbidden,
  required bool mayCreate,
  String? expectedVolume,
  AbortSignal? abort,
}) async {
  final created = <String>[];
  try {
    return await _inspect(
      path,
      fs: fs,
      forbidden: forbidden,
      mayCreate: mayCreate,
      expectedVolume: expectedVolume,
      abort: abort,
      created: created,
    );
  } catch (_) {
    for (final folder in created) {
      await _deleteIfEmpty(folder);
    }
    return const FolderRefused(FolderRefusal.cannotUse);
  }
}

Future<FolderInspection> _inspect(
  String path, {
  required FileSystemPlatform fs,
  required ForbiddenFolders? forbidden,
  required bool mayCreate,
  required String? expectedVolume,
  required AbortSignal? abort,
  required List<String> created,
}) async {
  const cannotUse = FolderRefused(FolderRefusal.cannotUse);
  if (forbidden == null) return cannotUse;
  final p = _normalize(path);
  if (!_isUsablePath(p)) return cannotUse;
  if (isAdminShare(p)) return const FolderRefused(FolderRefusal.adminShare);
  if (isInsideTempFolder(p)) return cannotUse;

  final exists = await _isDirectory(p);
  final String anchor;
  if (exists) {
    anchor = p;
  } else {
    final parent = _parentOf(p);
    if (parent == null || !await _isDirectory(parent)) return cannotUse;
    if (!isValidFileName(baseName(p))) return cannotUse;
    anchor = parent;
  }

  final real = await fs.realPath(anchor);
  if (real == null) return cannotUse;
  final candidate = exists ? real : _join(real, baseName(p));
  if (isAdminShare(candidate)) {
    return const FolderRefused(FolderRefusal.adminShare);
  }
  if (isInsideTempFolder(candidate)) return cannotUse;
  if (candidate.length + 1 + tempFolderName.length > Limits.maxFinalPathChars) {
    return cannotUse;
  }
  if (isForbiddenFolder(candidate, forbidden)) {
    return const FolderRefused(FolderRefusal.forbidden);
  }

  final facts = await fs.volumeFacts(anchor);
  if (facts == null) {
    return FolderRefused(
      expectedVolume != null
          ? FolderRefusal.otherVolume
          : FolderRefusal.unknownVolume,
    );
  }
  if (expectedVolume != null && facts.volumeId != expectedVolume) {
    return const FolderRefused(FolderRefusal.otherVolume);
  }

  if (_isAborted(abort)) return cannotUse;
  var createdNow = false;
  if (!exists) {
    if (!mayCreate) return cannotUse;
    await Directory(p).create();
    created.add(p);
    createdNow = true;
    final createdReal = await fs.realPath(p);
    if (createdReal == null || !samePath(createdReal, candidate)) {
      await _deleteIfEmpty(p);
      return cannotUse;
    }
  }

  if (_isAborted(abort)) {
    if (createdNow) await _deleteIfEmpty(p);
    return cannotUse;
  }
  if (!await _probeWrite(fs, candidate, abort)) {
    if (createdNow) await _deleteIfEmpty(p);
    return cannotUse;
  }

  final free = await fs.freeBytes(candidate);
  final cloud = await fs.isCloudSynced(candidate);
  return FolderUsable(
    ReceiveTarget(
      path: candidate,
      volumeId: facts.volumeId,
      supportsMark: facts.supportsNamedStreams,
      remote: facts.isRemote,
      cloud: cloud,
      freeBytes: free,
    ),
    createdNow: createdNow,
  );
}

Future<bool> _probeWrite(
  FileSystemPlatform fs,
  String folder,
  AbortSignal? abort,
) async {
  final sub = _join(folder, tempFolderName);
  var createdSub = false;
  try {
    final kind = await FileSystemEntity.type(sub, followLinks: false);
    if (kind == FileSystemEntityType.notFound) {
      if (_isAborted(abort)) return false;
      await Directory(sub).create();
      createdSub = true;
    } else if (kind != FileSystemEntityType.directory) {
      return false;
    }
    final realSub = await fs.realPath(sub);
    if (realSub == null || !samePath(realSub, sub)) {
      if (createdSub) await _deleteIfEmpty(sub);
      return false;
    }
    await fs.setHidden(sub);
    if (_isAborted(abort)) {
      if (createdSub) await _deleteIfEmpty(sub);
      return false;
    }
    final probe = File(_join(sub, '$tempPrefix${_randomHex32()}$tempSuffix'));
    try {
      await probe.writeAsBytes(const <int>[], flush: true);
    } finally {
      try {
        await probe.delete();
      } catch (_) {}
    }
    if (createdSub) await _deleteIfEmpty(sub);
    return true;
  } catch (_) {
    if (createdSub) await _deleteIfEmpty(sub);
    return false;
  }
}

bool isOwnTempName(String fileName) => _ownTempName.hasMatch(fileName);

bool isOwnFolderTempName(String folderName) =>
    _ownFolderTempName.hasMatch(folderName);

String newFolderTempName() {
  final random = Random.secure();
  final buffer = StringBuffer(tempPrefix);
  for (var i = 0; i < 6; i++) {
    buffer.write(random.nextInt(256).toRadixString(16).padLeft(2, '0'));
  }
  return buffer.toString();
}

Future<bool> sweepTemps(
  String folderRealPath,
  FileSystemPlatform fs, {
  Set<String> keep = const {},
}) async {
  final sub = _join(folderRealPath, tempFolderName);
  try {
    final kind = await FileSystemEntity.type(sub, followLinks: false);
    if (kind != FileSystemEntityType.directory) {
      return kind == FileSystemEntityType.notFound;
    }
    final realSub = await fs.realPath(sub);
    if (realSub == null || !samePath(realSub, sub)) return false;
    final entries = await Directory(sub).list(followLinks: false).toList();
    for (final entry in entries) {
      final name = baseName(entry.path);
      final ownFile = isOwnTempName(name);
      final ownFolder = isOwnFolderTempName(name);
      if (!ownFile && !ownFolder) continue;
      if (keep.any((active) => samePath(active, entry.path))) continue;
      try {
        final kind = await FileSystemEntity.type(
          entry.path,
          followLinks: false,
        );
        switch (kind) {
          case FileSystemEntityType.link:
            await Link(entry.path).delete();
          case FileSystemEntityType.directory:
            if (ownFolder) await fs.deleteTree(entry.path);
          case FileSystemEntityType.file:
            if (ownFile) await File(entry.path).delete();
          default:
            break;
        }
      } catch (_) {}
    }
    await _deleteIfEmpty(sub);
    return await FileSystemEntity.type(sub, followLinks: false) ==
        FileSystemEntityType.notFound;
  } catch (_) {
    return false;
  }
}
