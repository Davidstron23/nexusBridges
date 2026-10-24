import '../storage/storage.dart';
import 'folders.dart' show samePath;
import 'transfer.dart' show ReceiveFolder;

void _noLog(String message) {}

const int _maxPathUnits = 32767;

final class TempJournal {
  TempJournal(this._store, {this._log = _noLog});

  static const int maxFolders = 64;

  final JsonFileStore _store;
  final void Function(String) _log;

  List<ReceiveFolder> _folders = const [];
  Future<void> _tail = Future<void>.value();

  List<ReceiveFolder> get folders => _folders;

  Future<void> load() async {
    try {
      final json = await _store.readVersioned(1);
      _folders = json == null ? const [] : _parse(json['folders']);
    } on FormatException {
      _folders = const [];
      try {
        await _store.quarantine(DateTime.now());
      } catch (e) {
        _log('cleanup journal quarantine failed: ${e.runtimeType}');
      }
    } on Exception catch (e) {
      _folders = const [];
      _log('cleanup journal read failed: ${e.runtimeType}');
    }
  }

  Future<void> add(ReceiveFolder folder) {
    final list = [..._folders];
    final index = list.indexWhere((f) => samePath(f.path, folder.path));
    if (index >= 0) {
      if (list[index].volumeId == folder.volumeId) return _tail;
      list[index] = folder;
    } else {
      list.add(folder);
      if (list.length > maxFolders) list.removeAt(0);
    }
    _folders = List.unmodifiable(list);
    return _persist();
  }

  Future<void> remove(String path) {
    final list = [
      for (final f in _folders)
        if (!samePath(f.path, path)) f,
    ];
    if (list.length == _folders.length) return _tail;
    _folders = List.unmodifiable(list);
    return _persist();
  }

  Future<void> _persist() {
    final run = _tail.then((_) => _writeMemory());
    _tail = run;
    return run;
  }

  Future<void> _writeMemory() async {
    try {
      await _store.write({
        'version': 1,
        'folders': [
          for (final f in _folders) {'path': f.path, 'volume': f.volumeId},
        ],
      });
    } catch (e) {
      _log('cleanup journal write failed: ${e.runtimeType}');
    }
  }

  static List<ReceiveFolder> _parse(Object? raw) {
    if (raw is! List<Object?>) {
      throw const FormatException('folders is not a list');
    }
    final parsed = <ReceiveFolder>[];
    for (final item in raw) {
      if (item is! Map<String, Object?> || item.length != 2) {
        throw const FormatException('folder is not valid');
      }
      final path = item['path'];
      final volume = item['volume'];
      if (path is! String ||
          volume is! String ||
          path.isEmpty ||
          path.length > _maxPathUnits ||
          volume.isEmpty) {
        throw const FormatException('folder has invalid fields');
      }
      final index = parsed.indexWhere((f) => samePath(f.path, path));
      if (index >= 0) parsed.removeAt(index);
      parsed.add(ReceiveFolder(path: path, volumeId: volume));
    }
    if (parsed.length > maxFolders) {
      parsed.removeRange(0, parsed.length - maxFolders);
    }
    return List.unmodifiable(parsed);
  }
}
