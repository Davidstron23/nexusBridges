import '../transfer/transfer.dart' show ForbiddenFolders, FreeNameMove;
import 'shares_store.dart';

final class ShareProbe {
  const ShareProbe({
    required this.realPath,
    required this.volumeId,
    required this.drive,
    required this.remote,
    required this.supportsMark,
    required this.cloud,
    required this.explorerName,
    required this.home,
  });

  final String realPath;
  final String volumeId;
  final DriveKind? drive;
  final bool remote;
  final bool supportsMark;
  final bool cloud;
  final String? explorerName;
  final bool home;
}

final class LevelZeroFacts {
  const LevelZeroFacts({
    required this.available,
    required this.checks,
    this.exited,
  });

  final List<bool> available;
  final List<bool> checks;
  final Future<void>? exited;
}

sealed class FolderListing {
  const FolderListing();
}

final class FolderListed extends FolderListing {
  const FolderListed(this.names, {required this.more, required this.partial});

  final List<String> names;
  final bool more;
  final bool partial;
}

final class FolderUnavailable extends FolderListing {
  const FolderUnavailable();
}

final class ChainHandles {
  ChainHandles({
    required this.folderPath,
    required this.volumeId,
    this.supportsMark = true,
    this.cloud = false,
    this.freeBytes,
    this.rootPath = '',
    this.rootVolume = '',
    this.newFolder,
    this.forbiddenTrees = const [],
    this.forbiddenExact = const [],
    List<int>? handles,
    List<String>? finalPaths,
    List<String>? names,
  }) : handles = handles ?? <int>[],
       finalPaths = finalPaths ?? <String>[],
       names = names ?? <String>[];

  final List<int> handles;
  final List<String> finalPaths;
  final List<String> names;
  final String rootPath;
  final String rootVolume;
  final String? newFolder;
  final List<String> forbiddenTrees;
  final List<String> forbiddenExact;
  final String volumeId;
  final bool supportsMark;
  final bool cloud;
  final int? freeBytes;
  String folderPath;
  int? incomingHandle;
  String? incomingPath;
  bool createdNew = false;
  bool createdIncoming = false;
}

sealed class ChainResult {
  const ChainResult();
}

final class ChainOpened extends ChainResult {
  const ChainOpened(this.chain);

  final ChainHandles chain;
}

final class ChainMissing extends ChainResult {
  const ChainMissing();
}

final class ChainUnavailable extends ChainResult {
  const ChainUnavailable();
}

abstract interface class ShareBrowseFileSystem {
  Future<ForbiddenFolders?> forbiddenFolders();

  Future<String?> profilePath();

  Future<LevelZeroFacts> levelZero(
    List<ShareRecord> roots,
    List<(ShareRecord, List<String>)> checks, {
    required Duration budget,
  });

  Future<FolderListing> listFolders(
    ShareRecord root,
    List<String> path, {
    required Duration cap,
    required int max,
  });
}

abstract interface class ShareWriteFileSystem implements ShareBrowseFileSystem {
  Future<bool> exists(String path);

  Future<ShareProbe?> probe(String path);

  Future<ChainResult> openChain(
    ShareRecord root,
    List<String> path, {
    String? newFolder,
  });

  Future<bool> prepareChain(ChainHandles chain);

  Future<FreeNameMove> recheckAndMove(
    ChainHandles chain, {
    required String tempName,
    required bool isFolder,
    required String name,
    int? maxNameUnits,
  });

  Future<void> releaseChain(ChainHandles chain, {required bool saved});
}
