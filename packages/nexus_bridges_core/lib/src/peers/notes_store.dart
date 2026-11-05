import '../protocol/protocol.dart' show Limits;
import '../storage/storage.dart' show JsonFileStore;
import 'rules.dart';

enum PeerNotesLoadResult {
  missing,
  loaded,
  quarantined,
  partlyDropped,
  previousIdentity,
}

const int _maxPeers = 32;
const int _maxNameUnits = 512;
const int _maxComponentUnits = 255;

final RegExp _fingerprintPattern = RegExp(r'^[0-9A-F]{64}$');
final RegExp _rootIdPattern = RegExp(r'^[0-9a-f]{32}$');
final RegExp _outcomePattern = RegExp(r'^[a-zA-Z]{1,40}$');
final RegExp _controlCharacters = RegExp(r'[\x00-\x1F]');
final RegExp _forbiddenComponentCharacters = RegExp(r'[\\/:*?"<>|]');

const Set<String> _storeKeys = {'version', 'owner', 'peers'};
const Set<String> _peerKeys = {
  'fingerprint',
  'alias',
  'favorites',
  'recent',
  'history',
};
const Set<String> _destinationKeys = {'root', 'rootName', 'home', 'path'};
const Set<String> _historyKeys = {
  'at',
  'dir',
  'name',
  'folder',
  'files',
  'items',
  'delivered',
  'size',
  'destRoot',
  'destHome',
  'destPath',
  'outcome',
};

bool _hasExactKeys(Map<String, Object?> map, Set<String> keys) =>
    map.length == keys.length && keys.every(map.containsKey);

bool _isStorableComponent(Object? part) =>
    part is String &&
    part.isNotEmpty &&
    part.length <= _maxComponentUnits &&
    !_controlCharacters.hasMatch(part) &&
    !_forbiddenComponentCharacters.hasMatch(part);

bool isStorablePath(List<String> parts) =>
    parts.length <= Limits.maxRelativeDepth &&
    parts.every(_isStorableComponent);

List<String> _parsePath(Object? value) {
  if (value is! List<Object?> || value.length > Limits.maxRelativeDepth) {
    throw const FormatException('path is not valid');
  }
  final parts = <String>[];
  for (final part in value) {
    if (!_isStorableComponent(part)) {
      throw const FormatException('path component is not valid');
    }
    parts.add(part as String);
  }
  return List.unmodifiable(parts);
}

String _parseRootName(Object? value, {required bool home}) {
  if (value is! String ||
      value.length > _maxComponentUnits ||
      (!home && value.isEmpty) ||
      _controlCharacters.hasMatch(value)) {
    throw const FormatException('root name is not valid');
  }
  return value;
}

SavedDestination _parseDestination(Object? json) {
  if (json is! Map<String, Object?> || !_hasExactKeys(json, _destinationKeys)) {
    throw const FormatException('destination is not valid');
  }
  final root = json['root'];
  final home = json['home'];
  if (root is! String || !_rootIdPattern.hasMatch(root)) {
    throw const FormatException('destination root is not valid');
  }
  if (home is! bool) throw const FormatException('destination home is bad');
  return SavedDestination(
    rootId: root,
    rootName: _parseRootName(json['rootName'], home: home),
    home: home,
    path: _parsePath(json['path']),
  );
}

List<SavedDestination> _parseDestinations(Object? json, int max) {
  if (json is! List<Object?> || json.length > max) {
    throw const FormatException('destinations are not valid');
  }
  return List.unmodifiable([for (final item in json) _parseDestination(item)]);
}

HistoryEntry _parseHistoryEntry(Object? json) {
  if (json is! Map<String, Object?> || !_hasExactKeys(json, _historyKeys)) {
    throw const FormatException('history entry is not valid');
  }
  final at = json['at'];
  final dir = json['dir'];
  final name = json['name'];
  final folder = json['folder'];
  final files = json['files'];
  final items = json['items'];
  final delivered = json['delivered'];
  final size = json['size'];
  final destRoot = json['destRoot'];
  final destHome = json['destHome'];
  final outcome = json['outcome'];
  final direction = dir is String
      ? HistoryDirection.values.asNameMap()[dir]
      : null;
  if (at is! String || direction == null) {
    throw const FormatException('history date or direction is not valid');
  }
  if (name is! String ||
      name.isEmpty ||
      name.length > _maxNameUnits ||
      _controlCharacters.hasMatch(name)) {
    throw const FormatException('history name is not valid');
  }
  if (folder is! bool || destHome is! bool) {
    throw const FormatException('history flags are not valid');
  }
  if (files is! int ||
      items is! int ||
      delivered is! int ||
      size is! int ||
      files < 0 ||
      items < 1 ||
      delivered < 0 ||
      delivered > items ||
      size < 0) {
    throw const FormatException('history counts are not valid');
  }
  if (destRoot != null &&
      (destRoot is! String ||
          destRoot.length > _maxComponentUnits ||
          _controlCharacters.hasMatch(destRoot))) {
    throw const FormatException('history destination is not valid');
  }
  if (outcome is! String || !_outcomePattern.hasMatch(outcome)) {
    throw const FormatException('history outcome is not valid');
  }
  return HistoryEntry(
    at: DateTime.parse(at).toUtc(),
    direction: direction,
    name: name,
    isFolder: folder,
    fileCount: files,
    itemCount: items,
    delivered: delivered,
    size: size,
    destinationRoot: destRoot as String?,
    destinationHome: destHome,
    destinationPath: _parsePath(json['destPath']),
    outcome: outcome,
  );
}

List<HistoryEntry> _parseHistory(Object? json) {
  if (json is! List<Object?> || json.length > Limits.maxHistoryPerPeer) {
    throw const FormatException('history is not valid');
  }
  return List.unmodifiable([for (final item in json) _parseHistoryEntry(item)]);
}

Map<String, PeerNote> _parseNotes(Object? json) {
  if (json is! Map<String, Object?> || !_hasExactKeys(json, _storeKeys)) {
    throw const FormatException('notes file is not valid');
  }
  final peers = json['peers'];
  if (peers is! List<Object?> || peers.length > _maxPeers) {
    throw const FormatException('peers is not valid');
  }
  final result = <String, PeerNote>{};
  for (final peer in peers) {
    if (peer is! Map<String, Object?> || !_hasExactKeys(peer, _peerKeys)) {
      throw const FormatException('peer is not valid');
    }
    final fingerprint = peer['fingerprint'];
    final alias = peer['alias'];
    if (fingerprint is! String ||
        !_fingerprintPattern.hasMatch(fingerprint) ||
        result.containsKey(fingerprint)) {
      throw const FormatException('peer fingerprint is not valid');
    }
    if (alias != null && (alias is! String || cleanAlias(alias) != alias)) {
      throw const FormatException('alias is not valid');
    }
    result[fingerprint] = PeerNote(
      alias: alias as String?,
      favorites: _parseDestinations(
        peer['favorites'],
        Limits.maxFavoritesPerPeer,
      ),
      recent: _parseDestinations(peer['recent'], Limits.maxRecentPerPeer),
      history: _parseHistory(peer['history']),
    );
  }
  return result;
}

Map<String, Object?> _destinationJson(SavedDestination destination) => {
  'root': destination.rootId,
  'rootName': destination.rootName,
  'home': destination.home,
  'path': destination.path,
};

Map<String, Object?> _historyJson(HistoryEntry entry) => {
  'at': entry.at.toUtc().toIso8601String(),
  'dir': entry.direction.name,
  'name': entry.name,
  'folder': entry.isFolder,
  'files': entry.fileCount,
  'items': entry.itemCount,
  'delivered': entry.delivered,
  'size': entry.size,
  'destRoot': entry.destinationRoot,
  'destHome': entry.destinationHome,
  'destPath': entry.destinationPath,
  'outcome': entry.outcome,
};

final class PeerNotesStore {
  PeerNotesStore(
    JsonFileStore store, {
    required String ownerFingerprint,
    DateTime Function() now = DateTime.now,
  }) : _store = store,
       _owner = ownerFingerprint,
       _clock = now;

  final JsonFileStore _store;
  final String _owner;
  final DateTime Function() _clock;

  Future<(PeerNotesLoadResult, Map<String, PeerNote>)> load({
    required bool Function(String fingerprint) isPaired,
  }) async {
    const empty = <String, PeerNote>{};
    final Map<String, Object?>? json;
    try {
      json = await _store.readVersioned(1);
    } catch (_) {
      await _quarantine('broken');
      return (PeerNotesLoadResult.quarantined, empty);
    }
    if (json == null) return (PeerNotesLoadResult.missing, empty);
    final owner = json['owner'];
    if (owner is String &&
        _fingerprintPattern.hasMatch(owner) &&
        owner != _owner) {
      await _quarantine('previous-identity');
      return (PeerNotesLoadResult.previousIdentity, empty);
    }
    final Map<String, PeerNote> parsed;
    try {
      if (owner != _owner) throw const FormatException('owner is not valid');
      parsed = _parseNotes(json);
    } catch (_) {
      await _quarantine('broken');
      return (PeerNotesLoadResult.quarantined, empty);
    }
    final kept = {
      for (final entry in parsed.entries)
        if (isPaired(entry.key)) entry.key: entry.value,
    };
    if (kept.length == parsed.length) {
      return (PeerNotesLoadResult.loaded, parsed);
    }
    await write(kept);
    return (PeerNotesLoadResult.partlyDropped, kept);
  }

  Future<bool> write(Map<String, PeerNote> notes) async {
    try {
      await _store.write({
        'version': 1,
        'owner': _owner,
        'peers': [
          for (final entry in notes.entries)
            if (!entry.value.isEmpty)
              {
                'fingerprint': entry.key,
                'alias': entry.value.alias,
                'favorites': [
                  for (final item in entry.value.favorites)
                    _destinationJson(item),
                ],
                'recent': [
                  for (final item in entry.value.recent) _destinationJson(item),
                ],
                'history': [
                  for (final item in entry.value.history) _historyJson(item),
                ],
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
