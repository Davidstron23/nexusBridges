import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'dart:math';

import 'package:ffi/ffi.dart';
import 'package:win32/win32.dart';

import '../protocol/protocol.dart' show Limits, folderKey;
import '../transfer/transfer.dart'
    show
        DestinationChanged,
        FileSystemPlatform,
        ForbiddenFolders,
        FreeNameMove,
        MoveFailed,
        MovedTo,
        NameTooLong,
        NoFreeName,
        WindowsFileSystemPlatform,
        candidateFolderName,
        candidateName,
        isBlockedType,
        isForbiddenFolder,
        isInsideTempFolder,
        isRepositoryFolderName,
        isSameOrInside,
        isValidFileName,
        isValidFolderName,
        loadForbiddenFolders,
        samePath,
        tempFolderName,
        tempPrefix;
import '../winio/winio.dart';
import 'enumerate.dart';
import 'share_fs.dart';
import 'shares_store.dart';

const String _witnessSuffix = '.hold';
const int _pathChars = 32768;
const int _maxNameAttempts = 9999;

const List<Duration> _moveWaits = [
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

final class _Chain {
  final List<int> handles = [];
  final List<FolderFacts> facts = [];

  void closeAll() {
    for (final handle in handles.reversed) {
      try {
        closeHandleSync(handle);
      } catch (_) {
        continue;
      }
    }
    handles.clear();
    facts.clear();
  }
}

String _witnessName() {
  final random = Random.secure();
  final buffer = StringBuffer(tempPrefix);
  for (var i = 0; i < 8; i++) {
    buffer.write(random.nextInt(256).toRadixString(16).padLeft(2, '0'));
  }
  buffer.write(_witnessSuffix);
  return buffer.toString();
}

bool _strictlyInside(String path, String ancestor) =>
    isSameOrInside(path, ancestor) && !samePath(path, ancestor);

String _join(String folder, String name) =>
    folder.endsWith(r'\') ? '$folder$name' : '$folder\\$name';

bool _acceptable(
  FolderFacts facts,
  String name,
  String rootFinal,
  ForbiddenFolders forbidden,
) {
  if (facts.isLink || facts.hidden || facts.system) return false;
  final realName = facts.realName;
  if (!isValidFolderName(realName) ||
      isRepositoryFolderName(realName) ||
      folderKey(realName) != folderKey(name)) {
    return false;
  }
  if (!_strictlyInside(facts.finalPath, rootFinal)) return false;
  return !isForbiddenFolder(facts.finalPath, forbidden) &&
      !isInsideTempFolder(facts.finalPath);
}

enum _Walk { ok, missing, unavailable }

(_Walk, _Chain?) _walk(
  String rootPath,
  String rootVolume,
  List<String> components,
  ForbiddenFolders forbidden, {
  required bool lock,
}) {
  final chain = _Chain();
  var opened = false;
  try {
    final root = openFolderByPathSync(rootPath, lock: lock);
    if (root is! FolderOpened) return (_Walk.unavailable, null);
    chain.handles.add(root.handle);
    final rootFacts = folderFactsSync(root.handle);
    if (rootFacts == null || rootFacts.isLink) return (_Walk.unavailable, null);
    if (!samePath(rootFacts.finalPath, rootPath) ||
        rootFacts.volumeId != rootVolume) {
      return (_Walk.unavailable, null);
    }
    if (isForbiddenFolder(rootFacts.finalPath, forbidden) ||
        isInsideTempFolder(rootFacts.finalPath)) {
      return (_Walk.unavailable, null);
    }
    chain.facts.add(rootFacts);
    for (final name in components) {
      final child = openFolderRelativeSync(
        chain.handles.last,
        name,
        lock: lock,
      );
      if (child is FolderOpenFailed) {
        return (
          child.reason == FolderOpenFailure.notFound ||
                  child.reason == FolderOpenFailure.notAFolder
              ? _Walk.missing
              : _Walk.unavailable,
          null,
        );
      }
      if (child is! FolderOpened) return (_Walk.unavailable, null);
      chain.handles.add(child.handle);
      final facts = folderFactsSync(child.handle);
      if (facts == null ||
          !_acceptable(facts, name, rootFacts.finalPath, forbidden)) {
        return (_Walk.unavailable, null);
      }
      chain.facts.add(facts);
    }
    opened = true;
    return (_Walk.ok, chain);
  } catch (_) {
    return (_Walk.unavailable, null);
  } finally {
    if (!opened) chain.closeAll();
  }
}

_Chain? _openChain(
  String rootPath,
  String rootVolume,
  List<String> components,
  ForbiddenFolders forbidden, {
  required bool lock,
}) {
  final (status, chain) = _walk(
    rootPath,
    rootVolume,
    components,
    forbidden,
    lock: lock,
  );
  return status == _Walk.ok ? chain : null;
}

FolderListing _listFoldersSync(
  String rootPath,
  String rootVolume,
  List<String> components,
  List<String> forbiddenTrees,
  List<String> forbiddenExact,
  int capMicroseconds,
  int max,
) {
  final forbidden = ForbiddenFolders(
    trees: forbiddenTrees,
    exact: forbiddenExact,
  );
  final chain = _openChain(
    rootPath,
    rootVolume,
    components,
    forbidden,
    lock: false,
  );
  if (chain == null) return const FolderUnavailable();
  DirectoryBatches? batches;
  try {
    batches = directoryBatchesSync(chain.handles.last);
    final collector = FolderCollector(
      max: max,
      parentFinalPath: chain.facts.last.finalPath,
      forbidden: forbidden,
    );
    final watch = Stopwatch()..start();
    return enumerateFolders(
      batches: batches,
      collector: collector,
      clock: () => watch.elapsed,
      cap: Duration(microseconds: capMicroseconds),
    );
  } catch (_) {
    return const FolderUnavailable();
  } finally {
    batches?.close();
    chain.closeAll();
  }
}

final class _LevelZeroJob {
  const _LevelZeroJob({
    required this.port,
    required this.roots,
    required this.checks,
    required this.forbiddenTrees,
    required this.forbiddenExact,
  });

  final SendPort port;
  final List<(String, String)> roots;
  final List<(String, String, List<String>)> checks;
  final List<String> forbiddenTrees;
  final List<String> forbiddenExact;
}

const int _kindRoot = 0;
const int _kindCheck = 1;

void _levelZeroEntry(_LevelZeroJob job) {
  final forbidden = ForbiddenFolders(
    trees: job.forbiddenTrees,
    exact: job.forbiddenExact,
  );
  for (var i = 0; i < job.roots.length; i++) {
    final (path, volume) = job.roots[i];
    final chain = _openChain(path, volume, const [], forbidden, lock: false);
    final ok = chain != null;
    chain?.closeAll();
    job.port.send((_kindRoot, i, ok));
  }
  for (var i = 0; i < job.checks.length; i++) {
    final (path, volume, components) = job.checks[i];
    final chain = _openChain(path, volume, components, forbidden, lock: false);
    final ok = chain != null;
    chain?.closeAll();
    job.port.send((_kindCheck, i, ok));
  }
}

DriveKind? _driveKindSync(String path) {
  return using((arena) {
    final root = arena.pwstrBuffer(_pathChars);
    final Win32Result(:value) = GetVolumePathName(
      arena.pcwstr(path),
      root,
      _pathChars,
    );
    if (!value) return null;
    final type = GetDriveType(PCWSTR(root));
    if (type == DRIVE_FIXED) return DriveKind.fixed;
    if (type == DRIVE_REMOVABLE) return DriveKind.removable;
    return null;
  });
}

String? _profileSync() {
  return using((arena) {
    try {
      final path = SHGetKnownFolderPath(
        FOLDERID_Profile.toNative(allocator: arena),
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
  });
}

List<String> _knownFolderPathsSync() {
  final paths = <String>[];
  for (final id in [FOLDERID_Documents, FOLDERID_Downloads, FOLDERID_Desktop]) {
    try {
      using((arena) {
        final path = SHGetKnownFolderPath(
          id.toNative(allocator: arena),
          KF_FLAG_DEFAULT,
          null,
        );
        try {
          final text = path.toDartString();
          if (text.isNotEmpty) paths.add(text);
        } finally {
          CoTaskMemFree(path);
        }
      });
    } catch (_) {
      continue;
    }
  }
  return paths;
}

String? _explorerNameSync(String path) {
  if (!CoInitializeEx(COINIT_APARTMENTTHREADED).isOk) return null;
  try {
    return using((arena) {
      final item = SHCreateItemFromParsingName<IShellItem>(
        arena.pcwstr(path),
        null,
      );
      try {
        final name = item.getDisplayName(SIGDN_NORMALDISPLAY);
        try {
          final text = name.toDartString();
          return text.isEmpty ? null : text;
        } finally {
          CoTaskMemFree(name);
        }
      } finally {
        item.release();
      }
    });
  } catch (_) {
    return null;
  } finally {
    CoUninitialize();
  }
}

final class _OpenReply {
  const _OpenReply(
    this.status, {
    this.handles = const [],
    this.finalPaths = const [],
    this.volumeId = '',
    this.supportsMark = true,
    this.folderPath = '',
    this.freePath = '',
  });

  final _Walk status;
  final List<int> handles;
  final List<String> finalPaths;
  final String volumeId;
  final bool supportsMark;
  final String folderPath;
  final String freePath;
}

_OpenReply _openChainSync(
  String rootPath,
  String rootVolume,
  List<String> components,
  String? newFolder,
  List<String> forbiddenTrees,
  List<String> forbiddenExact,
) {
  final forbidden = ForbiddenFolders(
    trees: forbiddenTrees,
    exact: forbiddenExact,
  );
  final (status, chain) = _walk(
    rootPath,
    rootVolume,
    components,
    forbidden,
    lock: true,
  );
  if (status != _Walk.ok || chain == null) return _OpenReply(status);
  var keep = false;
  try {
    var folderPath = chain.facts.last.finalPath;
    if (newFolder != null) {
      if (isRepositoryFolderName(newFolder)) {
        return const _OpenReply(_Walk.unavailable);
      }
      final probe = openFolderRelativeSync(
        chain.handles.last,
        newFolder,
        lock: false,
      );
      switch (probe) {
        case FolderOpened(:final handle):
          try {
            final facts = folderFactsSync(handle);
            if (facts == null ||
                !_acceptable(
                  facts,
                  newFolder,
                  chain.facts.first.finalPath,
                  forbidden,
                )) {
              return const _OpenReply(_Walk.unavailable);
            }
            folderPath = facts.finalPath;
          } finally {
            closeHandleSync(handle);
          }
        case FolderOpenFailed(:final reason):
          if (reason != FolderOpenFailure.notFound) {
            return const _OpenReply(_Walk.unavailable);
          }
          folderPath = _join(folderPath, newFolder);
      }
    }
    keep = true;
    return _OpenReply(
      _Walk.ok,
      handles: List<int>.of(chain.handles),
      finalPaths: [for (final facts in chain.facts) facts.finalPath],
      volumeId: chain.facts.first.volumeId,
      supportsMark: chain.facts.first.supportsNamedStreams,
      folderPath: folderPath,
      freePath: chain.facts.last.finalPath,
    );
  } catch (_) {
    return const _OpenReply(_Walk.unavailable);
  } finally {
    if (!keep) chain.closeAll();
  }
}

final class _PrepareReply {
  const _PrepareReply({
    required this.ok,
    this.newHandle,
    this.newFinalPath,
    this.createdNew = false,
    this.incomingHandle,
    this.witnessHandle,
    this.incomingPath,
    this.createdIncoming = false,
    this.folderPath,
  });

  final bool ok;
  final int? newHandle;
  final String? newFinalPath;
  final bool createdNew;
  final int? incomingHandle;
  final int? witnessHandle;
  final String? incomingPath;
  final bool createdIncoming;
  final String? folderPath;
}

_PrepareReply _prepareSync(ChainHandles chain) {
  final forbidden = ForbiddenFolders(
    trees: chain.forbiddenTrees,
    exact: chain.forbiddenExact,
  );
  final parent = chain.handles.last;
  final parentFinal = chain.finalPaths.last;
  final newFolder = chain.newFolder;
  var destination = parent;
  var destinationFinal = parentFinal;
  int? newHandle;
  var createdNew = false;
  String? newFinal;

  void undoNew() {
    final handle = newHandle;
    if (handle == null) return;
    closeHandleSync(handle);
    newHandle = null;
    if (createdNew && newFolder != null) {
      deleteEmptyFolderRelativeSync(
        parent,
        newFolder,
        expectedFinalPath: newFinal ?? _join(parentFinal, newFolder),
      );
    }
  }

  try {
    if (newFolder != null) {
      final opened = openFolderRelativeSync(
        parent,
        newFolder,
        lock: true,
        create: true,
      );
      if (opened is! FolderOpened) return const _PrepareReply(ok: false);
      newHandle = opened.handle;
      createdNew = opened.created;
      final facts = folderFactsSync(opened.handle);
      if (facts == null ||
          !_acceptable(facts, newFolder, chain.finalPaths.first, forbidden)) {
        undoNew();
        return const _PrepareReply(ok: false);
      }
      destination = opened.handle;
      destinationFinal = facts.finalPath;
      newFinal = facts.finalPath;
    }
    final incoming = openFolderRelativeSync(
      destination,
      tempFolderName,
      lock: true,
      create: true,
      hideIfCreated: true,
    );
    if (incoming is! FolderOpened) {
      undoNew();
      return const _PrepareReply(ok: false);
    }
    final expected = _join(destinationFinal, tempFolderName);
    final witness = createWitnessFileSync(incoming.handle, _witnessName());
    final facts = witness == null ? null : folderFactsSync(incoming.handle);
    if (facts == null ||
        facts.reparseTag != null ||
        !samePath(facts.finalPath, expected)) {
      if (witness != null) closeHandleSync(witness);
      closeHandleSync(incoming.handle);
      if (incoming.created) {
        deleteEmptyFolderRelativeSync(
          destination,
          tempFolderName,
          expectedFinalPath: expected,
        );
      }
      undoNew();
      return const _PrepareReply(ok: false);
    }
    return _PrepareReply(
      ok: true,
      newHandle: newHandle,
      newFinalPath: newFinal,
      createdNew: createdNew,
      incomingHandle: incoming.handle,
      witnessHandle: witness,
      incomingPath: facts.finalPath,
      createdIncoming: incoming.created,
      folderPath: destinationFinal,
    );
  } catch (_) {
    undoNew();
    return const _PrepareReply(ok: false);
  }
}

bool _stillTheSameChain(ChainHandles chain) {
  final handles = chain.handles;
  if (handles.isEmpty ||
      handles.length != chain.finalPaths.length ||
      handles.length != chain.names.length) {
    return false;
  }
  final forbidden = ForbiddenFolders(
    trees: chain.forbiddenTrees,
    exact: chain.forbiddenExact,
  );
  final rootFacts = folderFactsSync(handles.first);
  if (rootFacts == null ||
      rootFacts.isLink ||
      !samePath(rootFacts.finalPath, chain.rootPath) ||
      rootFacts.volumeId != chain.rootVolume ||
      !samePath(rootFacts.finalPath, chain.finalPaths.first)) {
    return false;
  }
  for (var i = 1; i < handles.length; i++) {
    final facts = folderFactsSync(handles[i]);
    if (facts == null ||
        !_acceptable(facts, chain.names[i], rootFacts.finalPath, forbidden) ||
        !samePath(facts.finalPath, chain.finalPaths[i])) {
      return false;
    }
  }
  final incoming = chain.incomingHandle;
  final incomingPath = chain.incomingPath;
  if (incoming == null || incomingPath == null) return false;
  final facts = folderFactsSync(incoming);
  return facts != null &&
      facts.reparseTag == null &&
      samePath(facts.finalPath, incomingPath);
}

FreeNameMove _recheckAndMoveSync(
  ChainHandles chain,
  String tempName,
  bool isFolder,
  String name,
  int? maxNameUnits,
  int budgetMicroseconds,
) {
  try {
    if (!_stillTheSameChain(chain)) return const DestinationChanged();
    if (!isValidFileName(name) || isBlockedType(name)) {
      return const MoveFailed();
    }
    final destination = chain.handles.last;
    final destinationPath = chain.finalPaths.last;
    final incoming = chain.incomingHandle!;
    final watch = Stopwatch()..start();
    final budget = Duration(microseconds: budgetMicroseconds);
    var attempt = 0;
    int source;
    while (true) {
      final opened = openForRenameRelativeSync(
        incoming,
        tempName,
        directory: isFolder,
      );
      if (opened is RenameSourceOpened) {
        source = opened.handle;
        break;
      }
      if (opened is! RenameSourceBusy ||
          attempt >= _moveWaits.length ||
          watch.elapsed >= budget) {
        return const MoveFailed();
      }
      sleep(_moveWaits[attempt++]);
      if (!_stillTheSameChain(chain)) return const DestinationChanged();
    }
    try {
      final taken = childNameKeysSync(destination, key: folderKey).toSet();
      for (var n = 0; n <= _maxNameAttempts; n++) {
        final candidate = isFolder
            ? candidateFolderName(name, n)
            : candidateName(name, n);
        if (candidate == null) {
          if (isFolder) return const NameTooLong();
          continue;
        }
        if (isFolder) {
          if (maxNameUnits != null && candidate.length > maxNameUnits) {
            return const NameTooLong();
          }
        } else if (_join(destinationPath, candidate).length >
            Limits.maxFinalPathChars) {
          return const MoveFailed();
        }
        final key = folderKey(candidate);
        if (taken.contains(key)) continue;
        var busy = 0;
        var next = false;
        while (!next) {
          switch (renameRelativeSync(source, destination, candidate)) {
            case RenameStatus.renamed:
              return MovedTo(candidate);
            case RenameStatus.nameTaken:
              taken.add(key);
              next = true;
            case RenameStatus.busy:
              if (busy >= _moveWaits.length || watch.elapsed >= budget) {
                return const MoveFailed();
              }
              sleep(_moveWaits[busy++]);
              if (!_stillTheSameChain(chain)) return const DestinationChanged();
            case RenameStatus.failed:
              return const MoveFailed();
          }
        }
      }
      return const NoFreeName();
    } finally {
      closeHandleSync(source);
    }
  } catch (_) {
    return const MoveFailed();
  }
}

void _releaseSync(ChainHandles chain, bool saved) {
  final handles = List<int>.of(chain.handles);
  final incoming = chain.incomingHandle;
  final incomingPath = chain.incomingPath;
  final witness = chain.witnessHandle;
  try {
    if (witness != null) closeHandleSync(witness);
  } catch (_) {}
  try {
    if (incoming != null) {
      closeHandleSync(incoming);
      if (handles.isNotEmpty && incomingPath != null) {
        deleteEmptyFolderRelativeSync(
          handles.last,
          tempFolderName,
          expectedFinalPath: incomingPath,
        );
      }
    }
  } catch (_) {}
  final newFolder = chain.newFolder;
  if (!saved &&
      chain.createdNew &&
      newFolder != null &&
      handles.length >= 2 &&
      chain.finalPaths.length == handles.length) {
    final folder = handles.removeLast();
    final folderPath = chain.finalPaths.last;
    try {
      closeHandleSync(folder);
      deleteEmptyFolderRelativeSync(
        handles.last,
        newFolder,
        expectedFinalPath: folderPath,
      );
    } catch (_) {}
  }
  for (final handle in handles.reversed) {
    try {
      closeHandleSync(handle);
    } catch (_) {
      continue;
    }
  }
}

final class WindowsShareFileSystem implements ShareWriteFileSystem {
  WindowsShareFileSystem({
    this._platform = const WindowsFileSystemPlatform(),
    required List<String> dataDirs,
  }) : _dataDirs = List.unmodifiable(dataDirs);

  final FileSystemPlatform _platform;
  final List<String> _dataDirs;
  ForbiddenFolders? _forbidden;
  String? _profile;

  @override
  Future<ForbiddenFolders?> forbiddenFolders() async {
    final cached = _forbidden;
    if (cached != null) return cached;
    try {
      final loaded = await loadForbiddenFolders(
        _platform,
        await _platform.systemFolders(),
        dataDirs: _dataDirs,
      );
      _forbidden = loaded;
      return loaded;
    } catch (_) {
      return null;
    }
  }

  @override
  Future<String?> profilePath() async {
    final cached = _profile;
    if (cached != null) return cached;
    try {
      final raw = await Isolate.run(_profileSync);
      if (raw == null) return null;
      final real = await _platform.realPath(raw) ?? raw;
      _profile = real;
      return real;
    } catch (_) {
      return null;
    }
  }

  @override
  Future<LevelZeroFacts> levelZero(
    List<ShareRecord> roots,
    List<(ShareRecord, List<String>)> checks, {
    required Duration budget,
  }) async {
    final available = List<bool>.filled(roots.length, false);
    final checked = List<bool>.filled(checks.length, false);
    if (roots.isEmpty && checks.isEmpty) {
      return LevelZeroFacts(available: available, checks: checked);
    }
    final watch = Stopwatch()..start();
    final forbidden = await forbiddenFolders().timeout(
      budget,
      onTimeout: () => null,
    );
    if (forbidden == null) {
      return LevelZeroFacts(available: available, checks: checked);
    }
    final results = ReceivePort();
    final exitPort = ReceivePort();
    final exited = Completer<void>();
    final done = Completer<void>();
    var pending = roots.length + checks.length;
    results.listen((message) {
      if (message is! (int, int, bool)) return;
      final (kind, index, ok) = message;
      if (kind == _kindRoot && index < available.length) {
        available[index] = ok;
      } else if (kind == _kindCheck && index < checked.length) {
        checked[index] = ok;
      } else {
        return;
      }
      pending--;
      if (pending <= 0 && !done.isCompleted) done.complete();
    });
    exitPort.listen((_) {
      results.close();
      exitPort.close();
      if (!exited.isCompleted) exited.complete();
      if (!done.isCompleted) done.complete();
    });
    try {
      await Isolate.spawn(
        _levelZeroEntry,
        _LevelZeroJob(
          port: results.sendPort,
          roots: [for (final root in roots) (root.path, root.volumeId)],
          checks: [
            for (final (root, path) in checks)
              (root.path, root.volumeId, List<String>.of(path)),
          ],
          forbiddenTrees: List<String>.of(forbidden.trees),
          forbiddenExact: List<String>.of(forbidden.exact),
        ),
        onExit: exitPort.sendPort,
      );
    } catch (_) {
      results.close();
      exitPort.close();
      return LevelZeroFacts(
        available: List<bool>.filled(roots.length, false),
        checks: List<bool>.filled(checks.length, false),
      );
    }
    final remaining = budget - watch.elapsed;
    if (remaining > Duration.zero) {
      await done.future.timeout(remaining, onTimeout: () {});
    }
    return LevelZeroFacts(
      available: List<bool>.of(available),
      checks: List<bool>.of(checked),
      exited: exited.future,
    );
  }

  @override
  Future<FolderListing> listFolders(
    ShareRecord root,
    List<String> path, {
    required Duration cap,
    required int max,
  }) async {
    final forbidden = await forbiddenFolders();
    if (forbidden == null) return const FolderUnavailable();
    final rootPath = root.path;
    final rootVolume = root.volumeId;
    final components = List<String>.of(path);
    final trees = List<String>.of(forbidden.trees);
    final exact = List<String>.of(forbidden.exact);
    final capMicroseconds = cap.inMicroseconds;
    try {
      return await Isolate.run(
        () => _listFoldersSync(
          rootPath,
          rootVolume,
          components,
          trees,
          exact,
          capMicroseconds,
          max,
        ),
      );
    } catch (_) {
      return const FolderUnavailable();
    }
  }

  @override
  Future<bool> exists(String path) async {
    try {
      return await FileSystemEntity.type(path, followLinks: true) ==
          FileSystemEntityType.directory;
    } catch (_) {
      return false;
    }
  }

  @override
  Future<ShareProbe?> probe(String path) async {
    try {
      final real = await _platform.realPath(path);
      if (real == null) return null;
      final volume = await _platform.volumeFacts(real);
      if (volume == null) return null;
      final unc = real.startsWith(r'\\');
      final remote = volume.isRemote || unc;
      final DriveKind? drive;
      if (remote) {
        drive = null;
      } else {
        drive = await Isolate.run(() => _driveKindSync(real));
      }
      final cloud = await _platform.isCloudSynced(real);
      final profile = await profilePath();
      final home = profile != null && samePath(real, profile);
      return ShareProbe(
        realPath: real,
        volumeId: volume.volumeId,
        drive: drive,
        remote: remote,
        supportsMark: volume.supportsNamedStreams,
        cloud: cloud,
        explorerName: home || remote ? null : await _explorerNameOf(real),
        home: home,
      );
    } catch (_) {
      return null;
    }
  }

  Future<String?> _explorerNameOf(String real) async {
    try {
      final known = await Isolate.run(_knownFolderPathsSync);
      for (final candidate in known) {
        final candidateReal = await _platform.realPath(candidate);
        if (candidateReal == null || !samePath(real, candidateReal)) continue;
        final name = await Isolate.run(() => _explorerNameSync(candidate));
        return name != null && isValidFileName(name) ? name : null;
      }
    } catch (_) {
      return null;
    }
    return null;
  }

  @override
  Future<ChainResult> openChain(
    ShareRecord root,
    List<String> path, {
    String? newFolder,
  }) async {
    final forbidden = await forbiddenFolders();
    if (forbidden == null) return const ChainUnavailable();
    final rootPath = root.path;
    final rootVolume = root.volumeId;
    final components = List<String>.of(path);
    final trees = List<String>.of(forbidden.trees);
    final exact = List<String>.of(forbidden.exact);
    final _OpenReply reply;
    try {
      reply = await Isolate.run(
        () => _openChainSync(
          rootPath,
          rootVolume,
          components,
          newFolder,
          trees,
          exact,
        ),
      );
    } catch (_) {
      return const ChainUnavailable();
    }
    switch (reply.status) {
      case _Walk.missing:
        return const ChainMissing();
      case _Walk.unavailable:
        return const ChainUnavailable();
      case _Walk.ok:
        break;
    }
    try {
      final cloud = await _platform.isCloudSynced(rootPath);
      final free = await _platform.freeBytes(reply.freePath);
      return ChainOpened(
        ChainHandles(
          folderPath: reply.folderPath,
          volumeId: reply.volumeId,
          supportsMark: reply.supportsMark,
          cloud: cloud,
          freeBytes: free,
          rootPath: rootPath,
          rootVolume: rootVolume,
          newFolder: newFolder,
          forbiddenTrees: trees,
          forbiddenExact: exact,
          handles: reply.handles,
          finalPaths: reply.finalPaths,
          names: ['', ...components],
        ),
      );
    } catch (_) {
      for (final handle in reply.handles.reversed) {
        try {
          closeHandleSync(handle);
        } catch (_) {
          continue;
        }
      }
      return const ChainUnavailable();
    }
  }

  @override
  Future<bool> prepareChain(ChainHandles chain) async {
    final _PrepareReply reply;
    try {
      reply = await Isolate.run(() => _prepareSync(chain));
    } catch (_) {
      return false;
    }
    if (!reply.ok) return false;
    final newHandle = reply.newHandle;
    final newFolder = chain.newFolder;
    if (newHandle != null && newFolder != null) {
      chain.handles.add(newHandle);
      chain.finalPaths.add(reply.newFinalPath ?? chain.folderPath);
      chain.names.add(newFolder);
      chain.createdNew = reply.createdNew;
    }
    chain
      ..incomingHandle = reply.incomingHandle
      ..witnessHandle = reply.witnessHandle
      ..incomingPath = reply.incomingPath
      ..createdIncoming = reply.createdIncoming;
    final folderPath = reply.folderPath;
    if (folderPath != null) chain.folderPath = folderPath;
    return true;
  }

  @override
  Future<FreeNameMove> recheckAndMove(
    ChainHandles chain, {
    required String tempName,
    required bool isFolder,
    required String name,
    int? maxNameUnits,
  }) async {
    try {
      return await Isolate.run(
        () => _recheckAndMoveSync(
          chain,
          tempName,
          isFolder,
          name,
          maxNameUnits,
          Limits.shareMoveRetryBudget.inMicroseconds,
        ),
      );
    } catch (_) {
      return const MoveFailed();
    }
  }

  @override
  Future<void> releaseChain(ChainHandles chain, {required bool saved}) async {
    try {
      await Isolate.run(() => _releaseSync(chain, saved));
    } catch (_) {
      for (final handle in [
        ?chain.witnessHandle,
        ?chain.incomingHandle,
        ...chain.handles.reversed,
      ]) {
        try {
          closeHandleSync(handle);
        } catch (_) {
          continue;
        }
      }
    }
  }
}
