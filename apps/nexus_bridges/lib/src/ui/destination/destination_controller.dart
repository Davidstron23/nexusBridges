import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:nexus_bridges_core/nexus_bridges_core.dart';

import '../../app_controller.dart';
import 'navigator_controller.dart';

enum MenuStatus { loading, ready, noChoice, unreadable }

enum MenuOrigin { drop, picker, tray }

const Duration menuRootsTimeout = Duration(seconds: 2);

sealed class MenuItem {
  const MenuItem();
}

final class FavoriteItem extends MenuItem {
  const FavoriteItem(this.destination, {this.available});

  final SavedDestination destination;
  final bool? available;
}

final class DefaultFolderItem extends MenuItem {
  const DefaultFolderItem();
}

final class RootItem extends MenuItem {
  const RootItem(this.root);

  final RemoteRoot root;
}

final class RecentItem extends MenuItem {
  const RecentItem(this.destination, {this.available});

  final SavedDestination destination;
  final bool? available;
}

final class ExploreItem extends MenuItem {
  const ExploreItem();
}

SharedFolderDestination _destinationOf(SavedDestination saved) =>
    SharedFolderDestination(
      rootId: saved.rootId,
      rootName: saved.rootName,
      home: saved.home,
      path: saved.path,
    );

final class DestinationMenuController extends ChangeNotifier {
  DestinationMenuController({
    required this._app,
    required String fingerprint,
    required List<String> paths,
    required this._origin,
    this._cached,
    this._rootsTimeout = menuRootsTimeout,
    this.homeName = 'Home',
    this.onDone,
  }) : _fingerprint = fingerprint,
       _paths = List.unmodifiable(paths) {
    final peer = _app.state?.peers[fingerprint];
    _favorites = List.of(peer?.favorites ?? const <SavedDestination>[]);
    _recents = List.of(peer?.recent ?? const <SavedDestination>[]);
    _items = _build();
    _focused = _firstEnabled();
    unawaited(_load());
  }

  final AppController _app;
  final String _fingerprint;
  final List<String> _paths;
  final MenuOrigin _origin;
  final RemoteRoots? _cached;
  final Duration _rootsTimeout;
  final String homeName;
  final void Function(SendResult? result)? onDone;

  late final List<SavedDestination> _favorites;
  late final List<SavedDestination> _recents;
  List<RemoteRoot> _roots = const [];
  List<bool?> _favoriteAvailable = const [];
  List<bool?> _recentAvailable = const [];
  late List<MenuItem> _items;
  MenuStatus _status = MenuStatus.loading;
  int _focused = 0;
  bool _settled = false;
  bool _finished = false;
  bool _disposed = false;

  String get fingerprint => _fingerprint;

  List<String> get paths => _paths;

  MenuOrigin get origin => _origin;

  MenuStatus get status => _status;

  List<MenuItem> get items => List.unmodifiable(_items);

  int get focused => _focused;

  List<RemoteRoot> get roots => List.unmodifiable(_roots);

  bool get finished => _finished;

  List<MenuItem> _build() {
    final noChoice =
        _status == MenuStatus.noChoice || _status == MenuStatus.unreadable;
    return [
      for (var i = 0; i < _favorites.length; i++)
        FavoriteItem(
          _favorites[i],
          available: i < _favoriteAvailable.length
              ? _favoriteAvailable[i]
              : null,
        ),
      const DefaultFolderItem(),
      for (final root in _roots) RootItem(root),
      for (var i = 0; i < _recents.length; i++)
        RecentItem(
          _recents[i],
          available: i < _recentAvailable.length ? _recentAvailable[i] : null,
        ),
      if (!noChoice) const ExploreItem(),
    ];
  }

  bool isEnabled(MenuItem item) {
    final blocked =
        _status == MenuStatus.noChoice || _status == MenuStatus.unreadable;
    return switch (item) {
      FavoriteItem(:final available) => !blocked && available != false,
      RecentItem(:final available) => !blocked && available != false,
      DefaultFolderItem() => true,
      RootItem(:final root) => root.available,
      ExploreItem() => _status == MenuStatus.ready,
    };
  }

  int _firstEnabled() {
    for (var i = 0; i < _items.length; i++) {
      if (isEnabled(_items[i])) return i;
    }
    return 0;
  }

  void focus(int index) {
    if (index < 0 || index >= _items.length || index == _focused) return;
    if (!isEnabled(_items[index])) return;
    _focused = index;
    _notify();
  }

  void moveFocus(int delta) {
    if (_items.isEmpty) return;
    var index = _focused;
    for (var step = 0; step < _items.length; step++) {
      index = (index + delta) % _items.length;
      if (index < 0) index += _items.length;
      if (isEnabled(_items[index])) {
        _focused = index;
        _notify();
        return;
      }
    }
  }

  Future<void> _load() async {
    final cached = _cached;
    final nothingToCheck = _favorites.isEmpty && _recents.isEmpty;
    final Future<RemoteListing> pending = cached != null && nothingToCheck
        ? Future<RemoteListing>.value(cached)
        : _app.listRemoteRoots(
            _fingerprint,
            check: [..._favorites, ..._recents],
          );
    RemoteListing listing;
    try {
      listing = await pending.timeout(_rootsTimeout);
    } on TimeoutException {
      _settle(MenuStatus.noChoice);
      return;
    } catch (_) {
      _settle(MenuStatus.unreadable);
      return;
    }
    if (_settled || _disposed) return;
    switch (listing) {
      case RemoteRoots(:final roots, :final checks):
        if (roots.isEmpty) {
          _settle(MenuStatus.noChoice);
          return;
        }
        _roots = roots;
        final ids = {for (final root in roots) root.id};
        _favoriteAvailable = [
          for (var i = 0; i < _favorites.length; i++)
            ids.contains(_favorites[i].rootId) &&
                (i >= checks.length || checks[i]),
        ];
        _recentAvailable = [
          for (var i = 0; i < _recents.length; i++)
            ids.contains(_recents[i].rootId) &&
                (_favorites.length + i >= checks.length ||
                    checks[_favorites.length + i]),
        ];
        _settle(MenuStatus.ready);
      case RemoteFolders():
        _settle(MenuStatus.unreadable);
      case RemoteListingFailed(:final reason):
        _settle(
          reason == BrowseFailure.unreadable
              ? MenuStatus.unreadable
              : MenuStatus.noChoice,
        );
    }
  }

  void _settle(MenuStatus status) {
    if (_settled || _disposed) return;
    _settled = true;
    final current = _focused < _items.length ? _items[_focused] : null;
    _status = status;
    _items = _build();
    var next = -1;
    if (current != null) {
      for (var i = 0; i < _items.length; i++) {
        if (_sameItem(_items[i], current) && isEnabled(_items[i])) next = i;
      }
    }
    _focused = next >= 0 ? next : _firstEnabled();
    _notify();
  }

  bool _sameItem(MenuItem a, MenuItem b) => switch ((a, b)) {
    (FavoriteItem(:final destination), FavoriteItem(destination: final o)) =>
      destination == o,
    (RecentItem(:final destination), RecentItem(destination: final o)) =>
      destination == o,
    (RootItem(:final root), RootItem(root: final o)) => root.id == o.id,
    (DefaultFolderItem(), DefaultFolderItem()) => true,
    (ExploreItem(), ExploreItem()) => true,
    _ => false,
  };

  SharedFolderDestination? destinationOf(MenuItem item) => switch (item) {
    FavoriteItem(:final destination) => _destinationOf(destination),
    RecentItem(:final destination) => _destinationOf(destination),
    RootItem(:final root) => SharedFolderDestination(
      rootId: root.id,
      rootName: root.name,
      home: root.home,
      path: const [],
    ),
    DefaultFolderItem() || ExploreItem() => null,
  };

  Future<void> choose(MenuItem item) async {
    if (_finished || item is ExploreItem || !isEnabled(item)) return;
    await sendTo(destinationOf(item));
  }

  Future<void> sendTo(SharedFolderDestination? destination) async {
    if (_finished) return;
    _finished = true;
    final SendResult result;
    try {
      result = _origin == MenuOrigin.tray
          ? await _app.sendTray(_fingerprint, destination: destination)
          : await _app.sendPaths(
              _fingerprint,
              _paths,
              destination: destination,
            );
    } catch (_) {
      onDone?.call(SendResult.unavailable);
      return;
    }
    onDone?.call(result);
  }

  FolderNavigatorController openExplorer() => FolderNavigatorController(
    app: _app,
    fingerprint: _fingerprint,
    roots: _roots,
    mode: NavigatorMode.send,
    homeName: homeName,
  );

  void cancel() {
    if (_finished) return;
    _finished = true;
    onDone?.call(null);
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}
