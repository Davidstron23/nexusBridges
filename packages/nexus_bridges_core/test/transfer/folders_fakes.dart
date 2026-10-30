import 'dart:io';

import 'package:nexus_bridges_core/src/transfer/platform.dart';
import 'package:nexus_bridges_core/src/transfer/windows_file_system.dart';
import 'package:test/test.dart';

const WindowsFileSystemPlatform windowsFs = WindowsFileSystemPlatform();

const String hexA = '0123456789abcdef0123456789abcdef';
const String hexB = 'fedcba9876543210fedcba9876543210';
const String hexC = 'aaaaaaaabbbbbbbbccccccccdddddddd';

String ownTemp(String hex) => '~nexusbridges-$hex.partial';

String join(String folder, String name) =>
    folder.endsWith(r'\') ? '$folder$name' : '$folder\\$name';

Future<String> tempFolder([String prefix = 'nexus_t3_']) async {
  final dir = await Directory.systemTemp.createTemp(prefix);
  addTearDown(() async {
    if (await dir.exists()) await dir.delete(recursive: true);
  });
  final real = await windowsFs.realPath(dir.path);
  expect(real, isNotNull);
  return real!;
}

Future<String> makeDir(String path) async {
  await Directory(path).create();
  return path;
}

Future<String> makeJunction(String path, String target) async {
  final link = Link(path);
  await link.create(target);
  addTearDown(() async {
    try {
      await link.delete();
    } catch (_) {}
  });
  return path;
}

Set<String> treeOf(String root) {
  final dir = Directory(root);
  if (!dir.existsSync()) return {};
  return {
    for (final entry in dir.listSync(recursive: true, followLinks: false))
      entry.path.toUpperCase(),
  };
}

List<String> namesIn(String folder) =>
    Directory(folder)
        .listSync(followLinks: false)
        .map((e) => e.path.substring(e.path.lastIndexOf(r'\') + 1))
        .toList()
      ..sort();

final class FakePlatform implements FileSystemPlatform {
  FakePlatform({
    this.adjustRealPath,
    this.volume,
    this.noVolume = false,
    this.cloud,
    this.noFreeBytes = false,
    this.onCall,
    List<SystemFolders>? folderSequence,
  }) : folderSequence = folderSequence ?? [];

  final String? Function(String path, String? real)? adjustRealPath;
  final VolumeFacts? volume;
  final bool noVolume;
  final bool? cloud;
  final bool noFreeBytes;
  final Future<void> Function(String method, String path)? onCall;
  final List<SystemFolders> folderSequence;
  final List<String> calls = [];

  Future<void> _record(String method, String path) async {
    calls.add('$method $path');
    await onCall?.call(method, path);
  }

  List<String> callsOf(String method) => [
    for (final call in calls)
      if (call.startsWith('$method ')) call.substring(method.length + 1),
  ];

  @override
  Future<String?> realPath(String path) async {
    await _record('realPath', path);
    final real = await windowsFs.realPath(path);
    final adjust = adjustRealPath;
    return adjust == null ? real : adjust(path, real);
  }

  @override
  Future<VolumeFacts?> volumeFacts(String path) async {
    await _record('volumeFacts', path);
    if (noVolume) return null;
    return volume ?? await windowsFs.volumeFacts(path);
  }

  @override
  Future<int?> freeBytes(String path) async {
    await _record('freeBytes', path);
    if (noFreeBytes) return null;
    return windowsFs.freeBytes(path);
  }

  @override
  Future<bool> isCloudSynced(String path) async {
    await _record('isCloudSynced', path);
    return cloud ?? await windowsFs.isCloudSynced(path);
  }

  @override
  Future<SystemFolders> systemFolders() async {
    await _record('systemFolders', '');
    if (folderSequence.isEmpty) return const SystemFolders();
    return folderSequence.removeAt(0);
  }

  @override
  Future<bool> setHidden(String path) async {
    await _record('setHidden', path);
    return windowsFs.setHidden(path);
  }

  @override
  Future<MoveOutcome> moveNoReplace(String from, String to) async {
    await _record('moveNoReplace', from);
    return MoveOutcome.failed;
  }

  @override
  Future<FreeNameMove> moveToFreeName(
    String from,
    String folder,
    String name,
  ) async {
    await _record('moveToFreeName', from);
    return const MoveFailed();
  }

  @override
  Future<FreeNameMove> moveFolderToFreeName(
    String from,
    String folder,
    String name, {
    required int maxNameUnits,
  }) async {
    await _record('moveFolderToFreeName', from);
    return const MoveFailed();
  }

  @override
  Future<bool> markFromInternet(String filePath) async {
    await _record('markFromInternet', filePath);
    return false;
  }

  @override
  Future<bool> deleteTree(String path) async {
    await _record('deleteTree', path);
    return windowsFs.deleteTree(path);
  }

  @override
  Future<bool> isDangerousType(String extension) async => false;
}
