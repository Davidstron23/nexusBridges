import 'dart:async';

import '../protocol/protocol.dart' show Limits;
import '../storage/storage.dart' show JsonFileStore;
import 'notes_store.dart';
import 'rules.dart';

export 'rules.dart'
    show
        FavoriteResult,
        HistoryDirection,
        HistoryEntry,
        PeerNote,
        SavedDestination,
        cleanAlias,
        sameDestination,
        withHistory,
        withRecent;

final RegExp _controlCharacters = RegExp(r'[\x00-\x1F]');

const int _maxStoredNameUnits = 255;

String _storableName(String raw) {
  final kept = <int>[];
  var units = 0;
  for (final rune in raw.replaceAll(_controlCharacters, '\u{FFFD}').runes) {
    units += rune > 0xFFFF ? 2 : 1;
    if (units > _maxStoredNameUnits) break;
    kept.add(rune);
  }
  final text = String.fromCharCodes(kept);
  return text.isEmpty ? '\u{FFFD}' : text;
}

final class PeerNotes {
  PeerNotes(
    JsonFileStore store, {
    required String ownerFingerprint,
    this._writeDelay = Limits.peerNotesWriteDelay,
    DateTime Function() now = DateTime.now,
  }) : _store = PeerNotesStore(
         store,
         ownerFingerprint: ownerFingerprint,
         now: now,
       );

  final PeerNotesStore _store;
  final Duration _writeDelay;
  final StreamController<void> _changes = StreamController<void>.broadcast();
  final StreamController<void> _saveFailures =
      StreamController<void>.broadcast();

  Map<String, PeerNote> _notes = const {};
  Timer? _timer;
  bool _dirty = false;
  Future<void> _tail = Future<void>.value();

  Stream<void> get changes => _changes.stream;

  Stream<void> get saveFailures => _saveFailures.stream;

  Set<String> get knownPeers => Set.unmodifiable(_notes.keys);

  PeerNote noteOf(String fingerprint) =>
      _notes[fingerprint] ?? const PeerNote();

  Future<bool> load({
    required bool Function(String fingerprint) isPaired,
  }) async {
    try {
      final (result, loaded) = await _store.load(isPaired: isPaired);
      _notes = {
        for (final entry in loaded.entries)
          if (!entry.value.isEmpty) entry.key: entry.value,
      };
      return result == PeerNotesLoadResult.missing ||
          result == PeerNotesLoadResult.loaded ||
          result == PeerNotesLoadResult.partlyDropped;
    } catch (_) {
      _notes = const {};
      return false;
    }
  }

  void setAlias(String fingerprint, String raw) {
    final alias = cleanAlias(raw);
    final current = noteOf(fingerprint);
    if (current.alias == alias) return;
    _put(fingerprint, current.copyWith(alias: alias));
  }

  FavoriteResult addFavorite(String fingerprint, SavedDestination destination) {
    final current = noteOf(fingerprint);
    if (current.favorites.any((item) => sameDestination(item, destination))) {
      return FavoriteResult.alreadyThere;
    }
    if (current.favorites.length >= Limits.maxFavoritesPerPeer) {
      return FavoriteResult.full;
    }
    _put(
      fingerprint,
      current.copyWith(
        favorites: List.unmodifiable([...current.favorites, destination]),
      ),
    );
    return FavoriteResult.added;
  }

  void removeFavorite(String fingerprint, int index) {
    final current = noteOf(fingerprint);
    if (index < 0 || index >= current.favorites.length) return;
    _put(
      fingerprint,
      current.copyWith(
        favorites: List.unmodifiable([
          for (var i = 0; i < current.favorites.length; i++)
            if (i != index) current.favorites[i],
        ]),
      ),
    );
  }

  void addRecent(String fingerprint, SavedDestination destination) {
    final current = noteOf(fingerprint);
    _put(
      fingerprint,
      current.copyWith(recent: withRecent(current.recent, destination)),
    );
  }

  void appendHistory(String fingerprint, HistoryEntry entry) {
    final current = noteOf(fingerprint);
    final stored = HistoryEntry(
      at: entry.at,
      direction: entry.direction,
      name: _storableName(entry.name),
      isFolder: entry.isFolder,
      fileCount: entry.fileCount < 0 ? 0 : entry.fileCount,
      itemCount: entry.itemCount < 1 ? 1 : entry.itemCount,
      delivered: entry.delivered.clamp(
        0,
        entry.itemCount < 1 ? 1 : entry.itemCount,
      ),
      size: entry.size < 0 ? 0 : entry.size,
      destinationRoot: switch (entry.destinationRoot) {
        null => null,
        '' => '',
        final root => _storableName(root),
      },
      destinationHome: entry.destinationHome,
      destinationPath: isStorablePath(entry.destinationPath)
          ? entry.destinationPath
          : const [],
      outcome: entry.outcome,
    );
    _put(
      fingerprint,
      current.copyWith(history: withHistory(current.history, stored)),
    );
  }

  void forget(String fingerprint) {
    if (!_notes.containsKey(fingerprint)) return;
    final next = {..._notes}..remove(fingerprint);
    _notes = next;
    _notify();
    _schedule(const Duration());
  }

  Future<void> flush() async {
    _timer?.cancel();
    _timer = null;
    if (_dirty) await _enqueue();
    await _tail;
  }

  void _put(String fingerprint, PeerNote note) {
    final next = {..._notes};
    if (note.isEmpty) {
      next.remove(fingerprint);
    } else {
      next[fingerprint] = note;
    }
    _notes = next;
    _notify();
    _schedule(_writeDelay);
  }

  void _notify() {
    if (!_changes.isClosed) _changes.add(null);
  }

  void _schedule(Duration delay) {
    _dirty = true;
    if (_timer != null && delay != const Duration()) return;
    _timer?.cancel();
    _timer = Timer(delay, () {
      _timer = null;
      unawaited(_enqueue());
    });
  }

  Future<void> _enqueue() {
    final run = _tail.then((_) => _write());
    _tail = run.then((_) {}, onError: (Object _) {});
    return run;
  }

  Future<void> _write() async {
    if (!_dirty) return;
    _dirty = false;
    final saved = await _store.write(_notes);
    if (!saved && !_saveFailures.isClosed) _saveFailures.add(null);
  }
}
