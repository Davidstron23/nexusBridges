import '../protocol/protocol.dart' show Limits, folderKey, sanitizeDisplayName;

bool _sameStrings(List<String> a, List<String> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

final class SavedDestination {
  const SavedDestination({
    required this.rootId,
    required this.rootName,
    required this.path,
    this.home = false,
  });

  final String rootId;
  final String rootName;
  final bool home;
  final List<String> path;

  @override
  bool operator ==(Object other) =>
      other is SavedDestination &&
      other.rootId == rootId &&
      other.rootName == rootName &&
      other.home == home &&
      _sameStrings(other.path, path);

  @override
  int get hashCode => Object.hash(rootId, rootName, home, Object.hashAll(path));
}

enum HistoryDirection { sent, received }

final class HistoryEntry {
  const HistoryEntry({
    required this.at,
    required this.direction,
    required this.name,
    required this.isFolder,
    required this.fileCount,
    required this.itemCount,
    required this.delivered,
    required this.size,
    required this.destinationRoot,
    required this.destinationHome,
    required this.destinationPath,
    required this.outcome,
  });

  final DateTime at;
  final HistoryDirection direction;
  final String name;
  final bool isFolder;
  final int fileCount;
  final int itemCount;
  final int delivered;
  final int size;
  final String? destinationRoot;
  final bool destinationHome;
  final List<String> destinationPath;
  final String outcome;

  @override
  bool operator ==(Object other) =>
      other is HistoryEntry &&
      other.at == at &&
      other.direction == direction &&
      other.name == name &&
      other.isFolder == isFolder &&
      other.fileCount == fileCount &&
      other.itemCount == itemCount &&
      other.delivered == delivered &&
      other.size == size &&
      other.destinationRoot == destinationRoot &&
      other.destinationHome == destinationHome &&
      _sameStrings(other.destinationPath, destinationPath) &&
      other.outcome == outcome;

  @override
  int get hashCode => Object.hash(
    at,
    direction,
    name,
    isFolder,
    fileCount,
    itemCount,
    delivered,
    size,
    destinationRoot,
    destinationHome,
    Object.hashAll(destinationPath),
    outcome,
  );
}

final class PeerNote {
  const PeerNote({
    this.alias,
    this.favorites = const [],
    this.recent = const [],
    this.history = const [],
  });

  final String? alias;
  final List<SavedDestination> favorites;
  final List<SavedDestination> recent;
  final List<HistoryEntry> history;

  bool get isEmpty =>
      alias == null && favorites.isEmpty && recent.isEmpty && history.isEmpty;

  PeerNote copyWith({
    Object? alias = _keep,
    List<SavedDestination>? favorites,
    List<SavedDestination>? recent,
    List<HistoryEntry>? history,
  }) => PeerNote(
    alias: identical(alias, _keep) ? this.alias : alias as String?,
    favorites: favorites ?? this.favorites,
    recent: recent ?? this.recent,
    history: history ?? this.history,
  );
}

const Object _keep = Object();

enum FavoriteResult { added, alreadyThere, full }

String? cleanAlias(String raw) => sanitizeDisplayName(raw);

bool sameDestination(SavedDestination a, SavedDestination b) {
  if (a.rootId != b.rootId || a.path.length != b.path.length) return false;
  for (var i = 0; i < a.path.length; i++) {
    if (folderKey(a.path[i]) != folderKey(b.path[i])) return false;
  }
  return true;
}

List<SavedDestination> withRecent(
  List<SavedDestination> current,
  SavedDestination added,
) {
  return List.unmodifiable(
    [
      added,
      for (final item in current)
        if (!sameDestination(item, added)) item,
    ].take(Limits.maxRecentPerPeer),
  );
}

List<HistoryEntry> withHistory(List<HistoryEntry> current, HistoryEntry added) {
  return List.unmodifiable([added, ...current].take(Limits.maxHistoryPerPeer));
}
