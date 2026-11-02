import 'dart:async';

import '../protocol/protocol.dart' show Limits;
import '../transfer/transfer.dart' show visibleFileName;
import 'path_key.dart';
import 'policy.dart';
import 'selection.dart';

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
  }) : key = pathKey(path);

  final String id;
  final String path;
  final String name;
  final bool isFolder;
  final String key;

  TrayItemView toView() => TrayItemView(id: id, name: name, isFolder: isFolder);
}

final class TrayBatch {
  TrayBatch._(this._entries);

  final List<_TrayEntry> _entries;

  bool get isEmpty => _entries.isEmpty;

  List<String> get paths =>
      List.unmodifiable(_entries.map((entry) => entry.path));
}

final class SendTray {
  SendTray({required this._probe});

  final Future<ElementProbe> Function(String path) _probe;

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
      final path = normalizeElementPath(raw);
      if (path.isEmpty) continue;
      final key = pathKey(path);
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
          name: visibleFileName(baseNameOfPath(path)),
          isFolder: probe.kind == ElementKind.folder || isDriveRootPath(path),
        ),
      );
    }
    for (final entry in described) {
      _keys.add(entry.key);
    }
    _entries.addAll(described);
    _emit();
    return TrayAddResult.added;
  }

  void remove(String id) {
    final index = _entries.indexWhere((entry) => entry.id == id);
    if (index < 0) return;
    final entry = _entries.removeAt(index);
    _keys.remove(entry.key);
    _emit();
  }

  TrayBatch take() {
    final taken = List<_TrayEntry>.of(_entries);
    if (taken.isEmpty) return TrayBatch._(taken);
    _entries.clear();
    _keys.clear();
    _emit();
    return TrayBatch._(taken);
  }

  void restore(TrayBatch batch) {
    final back = <_TrayEntry>[];
    for (final entry in batch._entries) {
      if (_keys.add(entry.key)) back.add(entry);
    }
    if (back.isEmpty) return;
    _entries.insertAll(0, back);
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
