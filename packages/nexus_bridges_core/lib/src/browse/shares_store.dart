import '../protocol/protocol.dart' show Limits;
import '../storage/storage.dart' show JsonFileStore;
import '../transfer/transfer.dart' show isValidFileName;
import 'labels.dart' show isValidRootLabel;

enum DriveKind { fixed, removable }

final class ShareRecord {
  const ShareRecord({
    required this.id,
    required this.path,
    required this.volumeId,
    required this.label,
    required this.home,
    required this.drive,
    required this.addedAt,
  });

  final String id;
  final String path;
  final String volumeId;
  final String label;
  final bool home;
  final DriveKind drive;
  final DateTime addedAt;

  Map<String, Object?> toJson() => {
    'id': id,
    'path': path,
    'volume': volumeId,
    'label': label,
    'home': home,
    'drive': drive.name,
    'addedAt': addedAt.toUtc().toIso8601String(),
  };
}

enum SharesLoadResult {
  missing,
  loaded,
  quarantined,
  partlyDropped,
  previousIdentity,
}

const int _maxPeers = 32;

final RegExp _fingerprintPattern = RegExp(r'^[0-9A-F]{64}$');
final RegExp _rootIdPattern = RegExp(r'^[0-9a-f]{32}$');
final RegExp _volumePattern = RegExp(r'^[A-Za-z0-9]{1,16}-[0-9a-f]{8}$');
final RegExp _drivePathPattern = RegExp(r'^[A-Za-z]:\\');
final RegExp _badPathChars = RegExp(r'[*?"<>|\u0000-\u001F]');
final RegExp _driveLabelPattern = RegExp(r'^[A-Za-z]:$');

const Set<String> _storeKeys = {'version', 'owner', 'peers'};
const Set<String> _peerKeys = {'fingerprint', 'roots'};
const Set<String> _rootKeys = {
  'id',
  'path',
  'volume',
  'label',
  'home',
  'drive',
  'addedAt',
};

bool _hasExactKeys(Map<String, Object?> map, Set<String> keys) =>
    map.length == keys.length && keys.every(map.containsKey);

String _normalizedPathKey(String path) {
  var text = path.toUpperCase();
  while (text.length > 3 && text.endsWith(r'\')) {
    text = text.substring(0, text.length - 1);
  }
  return text;
}

ShareRecord _parseRecord(Object? json) {
  if (json is! Map<String, Object?> || !_hasExactKeys(json, _rootKeys)) {
    throw const FormatException('root is not valid');
  }
  final id = json['id'];
  final path = json['path'];
  final volume = json['volume'];
  final label = json['label'];
  final home = json['home'];
  final drive = json['drive'];
  final addedAt = json['addedAt'];
  if (id is! String || !_rootIdPattern.hasMatch(id)) {
    throw const FormatException('root id is not valid');
  }
  if (path is! String ||
      !_drivePathPattern.hasMatch(path) ||
      _badPathChars.hasMatch(path.substring(2)) ||
      path.length > Limits.maxShareFolderChars) {
    throw const FormatException('root path is not valid');
  }
  if (volume is! String || !_volumePattern.hasMatch(volume)) {
    throw const FormatException('root volume is not valid');
  }
  if (home is! bool) throw const FormatException('root home is not valid');
  if (label is! String ||
      (home
          ? label.isNotEmpty
          : (!isValidFileName(label) && !_driveLabelPattern.hasMatch(label)) ||
                !isValidRootLabel(label))) {
    throw const FormatException('root label is not valid');
  }
  final kind = drive is String ? DriveKind.values.asNameMap()[drive] : null;
  if (kind == null) throw const FormatException('root drive is not valid');
  if (addedAt is! String) throw const FormatException('root date is not valid');
  return ShareRecord(
    id: id,
    path: path,
    volumeId: volume,
    label: label,
    home: home,
    drive: kind,
    addedAt: DateTime.parse(addedAt).toUtc(),
  );
}

Map<String, List<ShareRecord>> _parseShares(Object? json) {
  if (json is! Map<String, Object?> || !_hasExactKeys(json, _storeKeys)) {
    throw const FormatException('shares file is not valid');
  }
  final peers = json['peers'];
  if (peers is! List<Object?> || peers.length > _maxPeers) {
    throw const FormatException('peers is not valid');
  }
  final result = <String, List<ShareRecord>>{};
  final ids = <String>{};
  for (final peer in peers) {
    if (peer is! Map<String, Object?> || !_hasExactKeys(peer, _peerKeys)) {
      throw const FormatException('peer is not valid');
    }
    final fingerprint = peer['fingerprint'];
    final roots = peer['roots'];
    if (fingerprint is! String ||
        !_fingerprintPattern.hasMatch(fingerprint) ||
        result.containsKey(fingerprint)) {
      throw const FormatException('peer fingerprint is not valid');
    }
    if (roots is! List<Object?> ||
        roots.isEmpty ||
        roots.length > Limits.maxSharesPerPeer) {
      throw const FormatException('roots is not valid');
    }
    final paths = <String>{};
    final records = <ShareRecord>[];
    for (final root in roots) {
      final record = _parseRecord(root);
      if (!ids.add(record.id)) {
        throw const FormatException('root id is repeated');
      }
      if (!paths.add(_normalizedPathKey(record.path))) {
        throw const FormatException('root path is repeated');
      }
      records.add(record);
    }
    result[fingerprint] = List.unmodifiable(records);
  }
  return result;
}

final class SharesStore {
  SharesStore(
    JsonFileStore store, {
    required String ownerFingerprint,
    DateTime Function() now = DateTime.now,
  }) : _store = store,
       _owner = ownerFingerprint,
       _clock = now;

  final JsonFileStore _store;
  final String _owner;
  final DateTime Function() _clock;

  Future<(SharesLoadResult, Map<String, List<ShareRecord>>)> load({
    required bool Function(String fingerprint) isPaired,
  }) async {
    const empty = <String, List<ShareRecord>>{};
    final Map<String, Object?>? json;
    try {
      json = await _store.readVersioned(1);
    } catch (_) {
      await _quarantine('broken');
      return (SharesLoadResult.quarantined, empty);
    }
    if (json == null) return (SharesLoadResult.missing, empty);
    final owner = json['owner'];
    if (owner is String &&
        _fingerprintPattern.hasMatch(owner) &&
        owner != _owner) {
      await _quarantine('previous-identity');
      return (SharesLoadResult.previousIdentity, empty);
    }
    final Map<String, List<ShareRecord>> parsed;
    try {
      if (owner != _owner) throw const FormatException('owner is not valid');
      parsed = _parseShares(json);
    } catch (_) {
      await _quarantine('broken');
      return (SharesLoadResult.quarantined, empty);
    }
    final kept = {
      for (final entry in parsed.entries)
        if (isPaired(entry.key)) entry.key: entry.value,
    };
    if (kept.length == parsed.length) return (SharesLoadResult.loaded, parsed);
    await _quarantine('unpaired');
    await write(kept);
    return (SharesLoadResult.partlyDropped, kept);
  }

  Future<bool> write(Map<String, List<ShareRecord>> shares) async {
    try {
      await _store.write({
        'version': 1,
        'owner': _owner,
        'peers': [
          for (final entry in shares.entries)
            if (entry.value.isNotEmpty)
              {
                'fingerprint': entry.key,
                'roots': [for (final root in entry.value) root.toJson()],
              },
        ],
      });
      return true;
    } catch (_) {
      return false;
    }
  }

  Future<void> _quarantine(String reason) async {
    try {
      await _store.quarantine(_clock(), reason: reason);
    } catch (_) {}
  }
}
