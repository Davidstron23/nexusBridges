import 'dart:async';

import 'package:nexus_bridges_core/src/browse/browse.dart';
import 'package:nexus_bridges_core/src/transfer/platform.dart'
    show FreeNameMove;
import 'package:nexus_bridges_core/src/transfer/transfer.dart'
    show ForbiddenFolders;

final class CountingShareFileSystem implements ShareWriteFileSystem {
  CountingShareFileSystem(this.real);

  final ShareWriteFileSystem real;
  int touches = 0;
  int opened = 0;
  int chains = 0;
  int prepared = 0;
  int rechecks = 0;
  int releases = 0;
  bool? lastSaved;
  int? freeBytes;
  FreeNameMove? forcedMove;
  Completer<void>? listGate;
  Completer<void>? rootsGate;
  Future<void> Function()? beforePrepare;
  Future<void> Function()? afterPrepare;
  Future<void> Function()? beforeMove;

  int get unreleased => chains - releases;

  void reset() {
    touches = 0;
    opened = 0;
    chains = 0;
    prepared = 0;
    rechecks = 0;
    releases = 0;
    lastSaved = null;
  }

  @override
  Future<ForbiddenFolders?> forbiddenFolders() {
    touches++;
    return real.forbiddenFolders();
  }

  @override
  Future<String?> profilePath() {
    touches++;
    return real.profilePath();
  }

  @override
  Future<LevelZeroFacts> levelZero(
    List<ShareRecord> roots,
    List<(ShareRecord, List<String>)> checks, {
    required Duration budget,
  }) async {
    touches++;
    final gate = rootsGate;
    if (gate != null) await gate.future;
    return real.levelZero(roots, checks, budget: budget);
  }

  @override
  Future<FolderListing> listFolders(
    ShareRecord root,
    List<String> path, {
    required Duration cap,
    required int max,
  }) async {
    touches++;
    final gate = listGate;
    if (gate != null) await gate.future;
    return real.listFolders(root, path, cap: cap, max: max);
  }

  @override
  Future<bool> exists(String path) {
    touches++;
    return real.exists(path);
  }

  @override
  Future<ShareProbe?> probe(String path) {
    touches++;
    return real.probe(path);
  }

  @override
  Future<ChainResult> openChain(
    ShareRecord root,
    List<String> path, {
    String? newFolder,
  }) async {
    touches++;
    opened++;
    final result = await real.openChain(root, path, newFolder: newFolder);
    if (result is! ChainOpened) return result;
    chains++;
    final free = freeBytes;
    if (free == null) return result;
    final chain = result.chain;
    return ChainOpened(
      ChainHandles(
        folderPath: chain.folderPath,
        volumeId: chain.volumeId,
        supportsMark: chain.supportsMark,
        cloud: chain.cloud,
        freeBytes: free,
        rootPath: chain.rootPath,
        rootVolume: chain.rootVolume,
        newFolder: chain.newFolder,
        forbiddenTrees: chain.forbiddenTrees,
        forbiddenExact: chain.forbiddenExact,
        handles: chain.handles,
        finalPaths: chain.finalPaths,
        names: chain.names,
      ),
    );
  }

  @override
  Future<bool> prepareChain(ChainHandles chain) async {
    touches++;
    prepared++;
    final before = beforePrepare;
    if (before != null) await before();
    final ok = await real.prepareChain(chain);
    final after = afterPrepare;
    if (after != null) await after();
    return ok;
  }

  @override
  Future<FreeNameMove> recheckAndMove(
    ChainHandles chain, {
    required String tempName,
    required bool isFolder,
    required String name,
    int? maxNameUnits,
  }) async {
    touches++;
    rechecks++;
    final before = beforeMove;
    if (before != null) await before();
    final forced = forcedMove;
    if (forced != null) return forced;
    return real.recheckAndMove(
      chain,
      tempName: tempName,
      isFolder: isFolder,
      name: name,
      maxNameUnits: maxNameUnits,
    );
  }

  @override
  Future<void> releaseChain(ChainHandles chain, {required bool saved}) async {
    touches++;
    await real.releaseChain(chain, saved: saved);
    releases++;
    lastSaved = saved;
  }
}
