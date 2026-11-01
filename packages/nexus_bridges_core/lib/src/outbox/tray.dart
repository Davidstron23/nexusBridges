import 'dart:async';

import '../protocol/protocol.dart' show Limits;
import 'policy.dart';
import 'selection.dart';

String _sameName(String name) => name;

enum TrayAddResult { added, nothingNew, tooMany }

final class TrayItemView {
  const TrayItemView({
    required this.id,
    required this.name,
    required this.isFolder,
  });

  final String id;
  final String name;
  final bool isFolder;

  @override
  bool operator ==(Object other) =>
      other is TrayItemView &&
      other.id == id &&
      other.name == name &&
      other.isFolder == isFolder;

  @override
  int get hashCode => Object.hash(id, name, isFolder);
}

final class _TrayEntry {
  _TrayEntry({
    required this.id,
    required this.path,
    required this.name,
    required this.isFolder,
  });

  final String id;
  final String path;
  final String name;
  final bool isFolder;

  TrayItemView toView() => TrayItemView(id: id, name: name, isFolder: isFolder);
}

String _normalizePath(String path) {
  final slashed = path.replaceAll('/', r'\');
  if (isDriveRootPath(slashed)) {
    return '${slashed.substring(0, 2)}\\';
  }
  var end = slashed.length;
  while (end > 0 && slashed[end - 1] == r'\') {
    end--;
  }
  return end == 0 ? slashed : slashed.substring(0, end);
}

final class SendTray {
  SendTray({required this._probe, this._displayName = _sameName});

  final Future<ElementProbe> Function(String path) _probe;
  final String Function(String name) _displayName;

  final StreamController<void> _changes = StreamController<void>.broadcast();
  final List<_TrayEntry> _entries = [];
  final Set<String> _keys = {};

  Future<void> _lock = Future<void>.value();
  int _counter = 0;

  Stream<void> get changes => _changes.stream;

  List<TrayItemView> get items =>
      List.unmodifiable(_entries.map((entry) => entry.toView()));

  List<String> get paths =>
      List.unmodifiable(_entries.map((entry) => entry.path));

  Future<TrayAddResult> add(List<String> paths) {
    final copy = List<String>.of(paths);
    final run = _lock.then((_) => _add(copy));
    _lock = run.then((_) {}, onError: (Object _) {});
    return run;
  }

  Future<TrayAddResult> _add(List<String> paths) async {
    final fresh = <String>[];
    final seen = <String>{};
    for (final raw in paths) {
      final path = _normalizePath(raw);
      if (path.isEmpty) continue;
      final key = path.toUpperCase();
      if (_keys.contains(key) || !seen.add(key)) continue;
      fresh.add(path);
    }
    if (fresh.isEmpty) return TrayAddResult.nothingNew;
    if (_entries.length + fresh.length > Limits.maxSelectionItems) {
      return TrayAddResult.tooMany;
    }
    final described = <_TrayEntry>[];
    for (final path in fresh) {
      ElementProbe probe;
      try {
        probe = await _probe(path);
      } catch (_) {
        probe = const ElementProbe(kind: ElementKind.other);
      }
      described.add(
        _TrayEntry(
          id: 't${++_counter}',
          path: path,
          name: _displayName(baseNameOfPath(path)),
          isFolder: probe.kind == ElementKind.folder || isDriveRootPath(path),
        ),
      );
    }
    for (final entry in described) {
      _keys.add(entry.path.toUpperCase());
    }
    _entries.addAll(described);
    _emit();
    return TrayAddResult.added;
  }

  void remove(String id) {
    final index = _entries.indexWhere((entry) => entry.id == id);
    if (index < 0) return;
    final entry = _entries.removeAt(index);
    _keys.remove(entry.path.toUpperCase());
    _emit();
  }

  void clear() {
    if (_entries.isEmpty) return;
    _entries.clear();
    _keys.clear();
    _emit();
  }

  Future<void> close() async {
    if (_changes.isClosed) return;
    await _changes.close();
  }

  void _emit() {
    if (_changes.isClosed) return;
    _changes.add(null);
  }
}
