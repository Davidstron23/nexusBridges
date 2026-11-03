import 'dart:async';
import 'dart:math';

import '../pairing/pairing.dart' show PairedDevicesStore, Permission;
import '../protocol/protocol.dart' show Limits, monotonicClock;
import '../transfer/transfer.dart'
    show
        DestinationChanged,
        DestinationLabel,
        DestinationRequest,
        FreeNameMove,
        MoveFailed,
        SharedFolders,
        SharedLease,
        SharedRefusal,
        SharedRefused,
        SharedResolution,
        SharedResolved,
        SharedRootGrant,
        baseName,
        checkRelativePath,
        isAdminShare,
        isForbiddenFolder,
        isInsideTempFolder,
        isSameOrInside,
        isValidFileName,
        samePath;
import 'labels.dart' show isValidRootLabel, parentLabelOf, visibleRootNames;
import 'share_fs.dart';
import 'shares_store.dart';

void _noLog(String message) {}

final RegExp _driveRoot = RegExp(r'^[A-Za-z]:\\?$');

int sharePathUnits(ShareRecord root) {
  var units = root.path.length;
  while (units > 3 && root.path.codeUnitAt(units - 1) == 0x5C) {
    units--;
  }
  return units;
}

final class _ShareLease implements SharedLease {
  _ShareLease({
    required this._fs,
    required this._chain,
    required this.label,
    required this._log,
  });

  final ShareWriteFileSystem _fs;
  final ChainHandles _chain;
  final void Function(String) _log;
  Future<void> _tail = Future<void>.value();
  Future<void>? _releasing;
  bool _released = false;

  @override
  final DestinationLabel label;

  @override
  String get folderPath => _chain.folderPath;

  @override
  String get volumeId => _chain.volumeId;

  @override
  bool get supportsMark => _chain.supportsMark;

  @override
  bool get cloud => _chain.cloud;

  @override
  int? get freeBytes => _chain.freeBytes;

  Future<T> _enqueue<T>(Future<T> Function() action) {
    final run = _tail.then((_) => action());
    _tail = run.then((_) {}, onError: (Object _) {});
    return run;
  }

  @override
  Future<bool> prepare() => _enqueue(() async {
    if (_released) return false;
    try {
      return await _fs.prepareChain(_chain);
    } catch (e) {
      _log('shares prepare failed: ${e.runtimeType}');
      return false;
    }
  });

  @override
  Future<FreeNameMove> recheckAndMove({
    required String tempName,
    required bool isFolder,
    required String name,
    int? maxNameUnits,
  }) => _enqueue(() async {
    if (_released) return const DestinationChanged();
    try {
      return await _fs.recheckAndMove(
        _chain,
        tempName: tempName,
        isFolder: isFolder,
        name: name,
        maxNameUnits: maxNameUnits,
      );
    } catch (e) {
      _log('shares move failed: ${e.runtimeType}');
      return const MoveFailed();
    }
  });

  @override
  Future<void> release({required bool saved}) {
    final current = _releasing;
    if (current != null) return current;
    _released = true;
    return _releasing = _enqueue(() async {
      try {
        await _fs.releaseChain(_chain, saved: saved);
      } catch (e) {
        _log('shares release failed: ${e.runtimeType}');
      }
    });
  }
}

final class ShareView {
  const ShareView({
    required this.rootId,
    required this.label,
    required this.home,
    required this.path,
    required this.drive,
    required this.available,
  });

  final String rootId;
  final String label;
  final bool home;
  final String path;
  final DriveKind drive;
  final bool? available;

  @override
  bool operator ==(Object other) =>
      other is ShareView &&
      other.rootId == rootId &&
      other.label == label &&
      other.home == home &&
      other.path == path &&
      other.drive == drive &&
      other.available == available;

  @override
  int get hashCode => Object.hash(rootId, label, home, path, drive, available);
}

enum ShareRefusal {
  networkDrive,
  adminShare,
  unknownDrive,
  forbidden,
  appData,
  tempFolder,
  tooLong,
  missing,
  alreadyAdded,
  full,
}

sealed class ShareAddOutcome {
  const ShareAddOutcome();
}

final class ShareAdded extends ShareAddOutcome {
  const ShareAdded({required this.saved});

  final bool saved;
}

final class ShareRefused extends ShareAddOutcome {
  const ShareRefused(this.reason);

  final ShareRefusal reason;
}

final class ShareNeedsConfirmation extends ShareAddOutcome {
  const ShareNeedsConfirmation({
    required this.pendingId,
    required this.path,
    required this.cloud,
    required this.withoutMark,
  });

  final String pendingId;
  final String path;
  final bool cloud;
  final bool withoutMark;
}

final class SharePickCancelled extends ShareAddOutcome {
  const SharePickCancelled();
}

abstract interface class ShareReader {
  bool mayBrowse(String fingerprint);

  List<ShareRecord> rootsFor(String fingerprint);

  ShareRecord? rootFor(String fingerprint, String rootId);
}

String _randomHex32() {
  final random = Random.secure();
  final buffer = StringBuffer();
  for (var i = 0; i < 16; i++) {
    buffer.write(random.nextInt(256).toRadixString(16).padLeft(2, '0'));
  }
  return buffer.toString();
}

final class _PendingShare {
  const _PendingShare({
    required this.fingerprint,
    required this.path,
    required this.createdAt,
  });

  final String fingerprint;
  final String path;
  final Duration createdAt;
}

const int _maxPendingShares = 32;

final class ShareService implements ShareReader, SharedFolders {
  ShareService({
    required this._store,
    required this._paired,
    required ShareWriteFileSystem fileSystem,
    required this._dataDirPath,
    this._clock = monotonicClock,
    this._log = _noLog,
  }) : _fs = fileSystem;

  final SharesStore _store;
  final PairedDevicesStore _paired;
  final ShareWriteFileSystem _fs;
  final String _dataDirPath;
  final Duration Function() _clock;
  final void Function(String) _log;
  final StreamController<void> _changes = StreamController<void>.broadcast();
  final StreamController<void> _saveStatus = StreamController<void>.broadcast();
  final Map<String, _PendingShare> _pending = {};
  final Map<String, bool> _availability = {};

  Map<String, List<ShareRecord>> _shares = const {};
  Future<void> _tail = Future<void>.value();
  bool _closed = false;
  bool _unsaved = false;
  bool _removalAtRisk = false;
  int _removalGeneration = 0;
  String? _profile;

  @override
  Stream<void> get changes => _changes.stream;

  Stream<void> get saveStatusChanges => _saveStatus.stream;

  bool get hasUnsavedRemoval => _unsaved;

  Set<String> get knownPeers => Set.unmodifiable(_shares.keys);

  Future<SharesLoadResult> load() async {
    final (result, loaded) = await _store.load(isPaired: _paired.isPaired);
    _shares = {
      for (final entry in loaded.entries)
        entry.key: List.unmodifiable(entry.value),
    };
    try {
      _profile = await _fs.profilePath();
    } catch (_) {
      _profile = null;
    }
    return result;
  }

  String _visibleNameOf(String fingerprint, ShareRecord record) {
    if (record.home) return '';
    final roots = rootsFor(fingerprint);
    final names = visibleRootNames([
      for (final root in roots)
        (
          label: root.label,
          home: root.home,
          parentLabel: parentLabelOf(root.path, profilePath: _profile),
        ),
    ]);
    for (var i = 0; i < roots.length; i++) {
      if (roots[i].id == record.id) return names[i];
    }
    return record.label;
  }

  @override
  SharedRootGrant? grantFor(String fingerprint, String rootId) {
    final record = rootFor(fingerprint, rootId);
    if (record == null) return null;
    return SharedRootGrant(
      rootId: record.id,
      label: _visibleNameOf(fingerprint, record),
      home: record.home,
      pathUnits: sharePathUnits(record),
    );
  }

  @override
  Future<SharedResolution> resolve(
    String fingerprint,
    DestinationRequest destination, {
    required Duration timeout,
  }) async {
    try {
      final record = rootFor(fingerprint, destination.rootId);
      if (record == null ||
          checkRelativePath(
                destination.path,
                newFolder: destination.newFolder,
                rootPathUnits: sharePathUnits(record),
              ) !=
              null) {
        return const SharedRefused(SharedRefusal.unavailable);
      }
      final label = DestinationLabel(
        rootName: _visibleNameOf(fingerprint, record),
        home: record.home,
        path: [...destination.path, ?destination.newFolder],
      );
      final opening = _fs.openChain(
        record,
        destination.path,
        newFolder: destination.newFolder,
      );
      final ChainResult result;
      try {
        result = await opening.timeout(timeout);
      } on TimeoutException {
        unawaited(
          opening.then<void>((late) async {
            if (late is ChainOpened) {
              await _fs.releaseChain(late.chain, saved: false);
            }
          }, onError: (Object _) {}),
        );
        return const SharedRefused(SharedRefusal.unavailable);
      }
      switch (result) {
        case ChainMissing():
          return const SharedRefused(SharedRefusal.missing);
        case ChainUnavailable():
          return const SharedRefused(SharedRefusal.unavailable);
        case ChainOpened(:final chain):
          if (rootFor(fingerprint, destination.rootId)?.id != record.id) {
            await _fs.releaseChain(chain, saved: false);
            return const SharedRefused(SharedRefusal.unavailable);
          }
          return SharedResolved(
            _ShareLease(fs: _fs, chain: chain, label: label, log: _log),
          );
      }
    } catch (e) {
      _log('shares resolve failed: ${e.runtimeType}');
      return const SharedRefused(SharedRefusal.unavailable);
    }
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    _pending.clear();
    await _changes.close();
    await _saveStatus.close();
  }

  void _notifyChanges() {
    if (!_closed) _changes.add(null);
  }

  void _setUnsaved(bool value) {
    if (_unsaved == value) return;
    _unsaved = value;
    if (!_closed) _saveStatus.add(null);
  }

  @override
  bool mayBrowse(String fingerprint) =>
      _paired.deviceOf(fingerprint)?.permissions.contains(Permission.browse) ??
      false;

  @override
  List<ShareRecord> rootsFor(String fingerprint) =>
      mayBrowse(fingerprint) ? _shares[fingerprint] ?? const [] : const [];

  @override
  ShareRecord? rootFor(String fingerprint, String rootId) {
    for (final root in rootsFor(fingerprint)) {
      if (root.id == rootId) return root;
    }
    return null;
  }

  List<ShareView> viewsFor(String fingerprint) => [
    for (final root in _shares[fingerprint] ?? const <ShareRecord>[])
      ShareView(
        rootId: root.id,
        label: root.label,
        home: root.home,
        path: root.path,
        drive: root.drive,
        available: _availability[root.id],
      ),
  ];

  Future<ShareAddOutcome> addPath(String fingerprint, String path) async {
    try {
      return _logged(await _addPath(fingerprint, path, confirmed: false));
    } catch (e) {
      _log('shares add failed: ${e.runtimeType}');
      return const ShareRefused(ShareRefusal.unknownDrive);
    }
  }

  Future<ShareAddOutcome> confirm(String fingerprint, String pendingId) async {
    try {
      _purgePending();
      final pending = _pending[pendingId];
      if (pending == null || pending.fingerprint != fingerprint) {
        return _logged(const ShareRefused(ShareRefusal.missing));
      }
      _pending.remove(pendingId);
      return _logged(
        await _addPath(fingerprint, pending.path, confirmed: true),
      );
    } catch (e) {
      _log('shares confirm failed: ${e.runtimeType}');
      return const ShareRefused(ShareRefusal.unknownDrive);
    }
  }

  void dropPending(String pendingId) {
    _pending.remove(pendingId);
  }

  ShareAddOutcome _logged(ShareAddOutcome outcome) {
    switch (outcome) {
      case ShareRefused(:final reason):
        _log('shares add refused ${reason.name}');
      case ShareNeedsConfirmation():
        _log('shares add needs confirmation');
      case ShareAdded() || SharePickCancelled():
        break;
    }
    return outcome;
  }

  void _purgePending() {
    final now = _clock();
    _pending.removeWhere(
      (_, pending) => now - pending.createdAt >= Limits.pendingShareTimeout,
    );
  }

  ShareNeedsConfirmation _pend(
    String fingerprint,
    String path,
    ShareProbe probe,
  ) {
    _purgePending();
    while (_pending.length >= _maxPendingShares) {
      _pending.remove(_pending.keys.first);
    }
    final id = _randomHex32();
    _pending[id] = _PendingShare(
      fingerprint: fingerprint,
      path: path,
      createdAt: _clock(),
    );
    return ShareNeedsConfirmation(
      pendingId: id,
      path: probe.realPath,
      cloud: probe.cloud,
      withoutMark: !probe.supportsMark,
    );
  }

  Future<ShareAddOutcome> _addPath(
    String fingerprint,
    String path, {
    required bool confirmed,
  }) async {
    if (_roots(fingerprint).length >= Limits.maxSharesPerPeer) {
      return const ShareRefused(ShareRefusal.full);
    }
    if (isAdminShare(path)) return const ShareRefused(ShareRefusal.adminShare);
    if (path.startsWith(r'\\')) {
      return const ShareRefused(ShareRefusal.networkDrive);
    }
    if (!await _fs.exists(path)) {
      return const ShareRefused(ShareRefusal.missing);
    }
    final probe = await _fs.probe(path);
    if (probe == null) return const ShareRefused(ShareRefusal.unknownDrive);
    final real = probe.realPath;
    if (isAdminShare(real)) return const ShareRefused(ShareRefusal.adminShare);
    if (probe.remote) return const ShareRefused(ShareRefusal.networkDrive);
    final drive = probe.drive;
    if (drive == null) return const ShareRefused(ShareRefusal.unknownDrive);
    final dataReal = (await _fs.probe(_dataDirPath))?.realPath ?? _dataDirPath;
    if (isSameOrInside(real, dataReal)) {
      return const ShareRefused(ShareRefusal.appData);
    }
    final forbidden = await _fs.forbiddenFolders();
    if (forbidden == null) return const ShareRefused(ShareRefusal.unknownDrive);
    if (isForbiddenFolder(real, forbidden)) {
      return const ShareRefused(ShareRefusal.forbidden);
    }
    if (isInsideTempFolder(real)) {
      return const ShareRefused(ShareRefusal.tempFolder);
    }
    if (real.length > Limits.maxShareFolderChars) {
      return const ShareRefused(ShareRefusal.tooLong);
    }
    final label = _labelOf(probe);
    if (label == null) return const ShareRefused(ShareRefusal.forbidden);
    if (!_paired.isPaired(fingerprint)) {
      return const ShareRefused(ShareRefusal.missing);
    }
    final current = _roots(fingerprint);
    if (current.length >= Limits.maxSharesPerPeer) {
      return const ShareRefused(ShareRefusal.full);
    }
    if (current.any((root) => samePath(root.path, real))) {
      return const ShareRefused(ShareRefusal.alreadyAdded);
    }
    if (!confirmed && (probe.cloud || !probe.supportsMark)) {
      return _pend(fingerprint, path, probe);
    }
    final record = ShareRecord(
      id: _randomHex32(),
      path: real,
      volumeId: probe.volumeId,
      label: label,
      home: probe.home,
      drive: drive,
      addedAt: DateTime.now().toUtc(),
    );
    _shares = {
      ..._shares,
      fingerprint: List.unmodifiable([...current, record]),
    };
    _notifyChanges();
    final saved = await _enqueue(_write);
    _log('shares add ok');
    return ShareAdded(saved: saved);
  }

  Future<bool> remove(String fingerprint, String rootId) {
    final current = _roots(fingerprint);
    if (!current.any((root) => root.id == rootId)) {
      return Future<bool>.value(true);
    }
    _replaceRoots(fingerprint, [
      for (final root in current)
        if (root.id != rootId) root,
    ]);
    _availability.remove(rootId);
    _log('shares remove');
    return _afterRemoval();
  }

  Future<bool> forget(String fingerprint) {
    final current = _roots(fingerprint);
    if (current.isEmpty) return Future<bool>.value(true);
    _replaceRoots(fingerprint, const []);
    for (final root in current) {
      _availability.remove(root.id);
    }
    _pending.removeWhere((_, pending) => pending.fingerprint == fingerprint);
    _log('shares forget ${current.length}');
    return _afterRemoval();
  }

  Future<bool> retrySave() => _enqueue(_write);

  Future<void> refreshAvailability(String fingerprint) async {
    final roots = _roots(fingerprint);
    if (roots.isEmpty) return;
    try {
      final facts = await _fs.levelZero(
        roots,
        const [],
        budget: Limits.shareCheckTimeout,
      );
      final still = {for (final root in _roots(fingerprint)) root.id};
      for (var i = 0; i < roots.length && i < facts.available.length; i++) {
        if (still.contains(roots[i].id)) {
          _availability[roots[i].id] = facts.available[i];
        }
      }
    } catch (e) {
      _log('shares refresh failed: ${e.runtimeType}');
    }
  }

  void _replaceRoots(String fingerprint, List<ShareRecord> roots) {
    final next = {..._shares};
    if (roots.isEmpty) {
      next.remove(fingerprint);
    } else {
      next[fingerprint] = List.unmodifiable(roots);
    }
    _shares = next;
  }

  Future<bool> _afterRemoval() {
    _removalAtRisk = true;
    _removalGeneration++;
    _notifyChanges();
    return _enqueue(_write);
  }

  Future<bool> _write() async {
    final generation = _removalGeneration;
    final saved = await _store.write(_shares);
    if (saved) {
      if (_removalGeneration == generation) _removalAtRisk = false;
      _setUnsaved(false);
    } else {
      _setUnsaved(_removalAtRisk);
    }
    return saved;
  }

  List<ShareRecord> _roots(String fingerprint) =>
      _shares[fingerprint] ?? const [];

  String? _labelOf(ShareProbe probe) {
    if (probe.home) return '';
    final real = probe.realPath;
    if (_driveRoot.hasMatch(real)) return '${real[0].toUpperCase()}:';
    final label = probe.explorerName ?? baseName(real);
    return isValidFileName(label) && isValidRootLabel(label) ? label : null;
  }

  Future<T> _enqueue<T>(Future<T> Function() action) {
    final run = _tail.then((_) => action());
    _tail = run.then((_) {}, onError: (Object _) {});
    return run;
  }
}
