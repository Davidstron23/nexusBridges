import '../protocol/protocol.dart' show Limits, folderKey, protocolVersion;
import '../transfer/transfer.dart' show isValidFolderName;
import 'client.dart' show BrowseCheck, RemoteFolders, RemoteRoot, RemoteRoots;
import 'labels.dart' show isValidRootLabel;

const int _maxProtocolLength = 16;
const int _maxPathComponents = 64;
const int _maxComponentUnits = 1024;
const int _maxRoots = 16;

final RegExp _protocolPattern = RegExp(r'^\d+\.\d+$');
final RegExp _rootIdPattern = RegExp(r'^[0-9a-f]{32}$');

Map<Object?, Object?>? _objectWithKeys(Object? json, Set<String> keys) {
  if (json is! Map<Object?, Object?> || json.length != keys.length) {
    return null;
  }
  if (!keys.every(json.containsKey)) return null;
  return json;
}

bool _compatibleProtocol(Object? value) {
  if (value is! String ||
      value.length > _maxProtocolLength ||
      !_protocolPattern.hasMatch(value)) {
    return false;
  }
  final major = int.tryParse(value.split('.').first);
  final ownMajor = int.tryParse(protocolVersion.split('.').first);
  return major != null && major == ownMajor;
}

List<String>? _pathOf(Object? value) {
  if (value is! List<Object?> || value.length > _maxPathComponents) return null;
  final path = <String>[];
  for (final component in value) {
    if (component is! String ||
        component.isEmpty ||
        component.length > _maxComponentUnits) {
      return null;
    }
    path.add(component);
  }
  return path;
}

BrowseCheck? _checkOf(Object? value) {
  final map = _objectWithKeys(value, const {'root', 'path'});
  if (map == null) return null;
  final root = map['root'];
  final path = _pathOf(map['path']);
  if (root is! String || !_rootIdPattern.hasMatch(root) || path == null) {
    return null;
  }
  return BrowseCheck(rootId: root, path: path);
}

sealed class BrowseRequest {
  const BrowseRequest();

  static BrowseRequest? tryParse(Object? json) {
    if (json is Map<Object?, Object?> && json.containsKey('root')) {
      final map = _objectWithKeys(json, const {'protocol', 'root', 'path'});
      if (map == null || !_compatibleProtocol(map['protocol'])) return null;
      final root = map['root'];
      final path = _pathOf(map['path']);
      if (root is! String || !_rootIdPattern.hasMatch(root) || path == null) {
        return null;
      }
      return FoldersRequest(rootId: root, path: path);
    }
    if (json is Map<Object?, Object?> && json.containsKey('check')) {
      final map = _objectWithKeys(json, const {'protocol', 'check'});
      if (map == null || !_compatibleProtocol(map['protocol'])) return null;
      final raw = map['check'];
      if (raw is! List<Object?> ||
          raw.isEmpty ||
          raw.length > Limits.maxBrowseChecks) {
        return null;
      }
      final checks = <BrowseCheck>[];
      for (final item in raw) {
        final check = _checkOf(item);
        if (check == null) return null;
        checks.add(check);
      }
      return RootsRequest(checks: List.unmodifiable(checks));
    }
    final map = _objectWithKeys(json, const {'protocol'});
    if (map == null || !_compatibleProtocol(map['protocol'])) return null;
    return const RootsRequest(checks: []);
  }
}

final class RootsRequest extends BrowseRequest {
  const RootsRequest({required this.checks});

  final List<BrowseCheck> checks;
}

final class FoldersRequest extends BrowseRequest {
  const FoldersRequest({required this.rootId, required this.path});

  final String rootId;
  final List<String> path;
}

Map<String, Object?> rootsRequestJson(List<BrowseCheck> checks) => {
  'protocol': protocolVersion,
  if (checks.isNotEmpty)
    'check': [
      for (final check in checks) {'root': check.rootId, 'path': check.path},
    ],
};

Map<String, Object?> foldersRequestJson(String rootId, List<String> path) => {
  'protocol': protocolVersion,
  'root': rootId,
  'path': path,
};

RemoteRoots? parseRootsResponse(Object? json, {required int checks}) {
  final keys = checks > 0 ? const {'roots', 'checks'} : const {'roots'};
  final map = _objectWithKeys(json, keys);
  if (map == null) return null;
  final rawRoots = map['roots'];
  if (rawRoots is! List<Object?> || rawRoots.length > _maxRoots) return null;
  final roots = <RemoteRoot>[];
  final ids = <String>{};
  final names = <String>{};
  var homes = 0;
  for (final raw in rawRoots) {
    final item = _objectWithKeys(raw, const {
      'id',
      'name',
      'home',
      'available',
    });
    if (item == null) return null;
    final id = item['id'];
    final name = item['name'];
    final home = item['home'];
    final available = item['available'];
    if (id is! String || !_rootIdPattern.hasMatch(id) || !ids.add(id)) {
      return null;
    }
    if (name is! String || home is! bool || available is! bool) return null;
    if (home) {
      if (name.isNotEmpty) return null;
      homes++;
      if (homes > 1) return null;
    } else {
      if (!isValidRootLabel(name)) return null;
      if (!names.add(folderKey(name))) return null;
    }
    roots.add(RemoteRoot(id: id, name: name, home: home, available: available));
  }
  var checked = const <bool>[];
  if (checks > 0) {
    final rawChecks = map['checks'];
    if (rawChecks is! List<Object?> || rawChecks.length != checks) return null;
    final values = <bool>[];
    for (final value in rawChecks) {
      if (value is! bool) return null;
      values.add(value);
    }
    checked = values;
  }
  return RemoteRoots(List.unmodifiable(roots), checks: checked);
}

RemoteFolders? parseFoldersResponse(Object? json) {
  final map = _objectWithKeys(json, const {'folders', 'more', 'partial'});
  if (map == null) return null;
  final rawFolders = map['folders'];
  final more = map['more'];
  final partial = map['partial'];
  if (rawFolders is! List<Object?> ||
      rawFolders.length > Limits.maxBrowseEntries ||
      more is! bool ||
      partial is! bool) {
    return null;
  }
  final names = <String>[];
  final keys = <String>{};
  for (final name in rawFolders) {
    if (name is! String ||
        !isValidFolderName(name) ||
        !keys.add(folderKey(name))) {
      return null;
    }
    names.add(name);
  }
  return RemoteFolders(List.unmodifiable(names), more: more, partial: partial);
}
