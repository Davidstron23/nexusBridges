import 'package:flutter/foundation.dart';
import 'package:nexus_bridges_core/nexus_bridges_core.dart';

import '../../app_controller.dart';

enum NavigatorMode { send, favorite, portal }

enum NavStatus { idle, loading, gone, busy, unreadable }

enum NewFolderProblem { invalid, repository, exists }

final class NavLevel {
  const NavLevel({
    required this.name,
    required this.folders,
    this.more = false,
    this.partial = false,
    this.isNew = false,
    this.rootIds,
  });

  final String? name;
  final List<String> folders;
  final bool more;
  final bool partial;
  final bool isNew;
  final List<String>? rootIds;
}

final class FolderNavigatorController extends ChangeNotifier {
  FolderNavigatorController({
    required this._app,
    required this._fingerprint,
    required List<RemoteRoot> roots,
    required this._mode,
    this._homeName = 'Home',
  }) : _roots = [
         for (final root in roots)
           if (root.available) root,
       ] {
    _stack = [
      NavLevel(
        name: null,
        folders: [
          for (final root in _roots) root.displayName(homeName: _homeName),
        ],
        rootIds: [for (final root in _roots) root.id],
      ),
    ];
  }

  final AppController _app;
  final String _fingerprint;
  final NavigatorMode _mode;
  final String _homeName;
  final List<RemoteRoot> _roots;
  late List<NavLevel> _stack;
  RemoteRoot? _root;
  NavStatus _status = NavStatus.idle;
  int _generation = 0;
  bool _disposed = false;

  NavigatorMode get mode => _mode;

  List<NavLevel> get stack => List.unmodifiable(_stack);

  NavStatus get status => _status;

  RemoteRoot? get root => _root;

  List<RemoteRoot> get roots => List.unmodifiable(_roots);

  bool get atRoots => _stack.length == 1;

  bool get insideNew => _stack.last.isNew;

  bool get canCreateFolder =>
      _mode == NavigatorMode.send && !atRoots && !insideNew;

  Future<void> enterRoot(String rootId) async {
    if (!atRoots) return;
    final root = rootWithId(rootId);
    if (root == null) return;
    await _open(root, const [], root.displayName(homeName: _homeName));
  }

  Future<void> enter(String name) async {
    if (atRoots) return;
    if (!_stack.last.folders.contains(name)) return;
    await _open(_root!, [..._pathOfStack(), name], name);
  }

  RemoteRoot? rootWithId(String rootId) {
    for (final root in _roots) {
      if (root.id == rootId) return root;
    }
    return null;
  }

  Future<void> _open(RemoteRoot root, List<String> path, String name) async {
    if (_status == NavStatus.loading || _stack.last.isNew) return;
    final generation = ++_generation;
    _status = NavStatus.loading;
    _notify();
    final listing = await _app.listRemoteFolders(_fingerprint, root.id, path);
    if (_disposed || generation != _generation) return;
    switch (listing) {
      case RemoteFolders():
        _root = root;
        _stack = [
          ..._stack,
          NavLevel(
            name: name,
            folders: listing.names,
            more: listing.more,
            partial: listing.partial,
          ),
        ];
        _status = NavStatus.idle;
      case RemoteRoots():
        _status = NavStatus.unreadable;
      case RemoteListingFailed(:final reason):
        switch (reason) {
          case BrowseFailure.unavailable || BrowseFailure.notAllowed:
            _status = NavStatus.gone;
            _toRoots();
          case BrowseFailure.busy || BrowseFailure.noAnswer:
            _status = NavStatus.busy;
          case BrowseFailure.unreadable || BrowseFailure.notVisible:
            _status = NavStatus.unreadable;
        }
    }
    _notify();
  }

  void back() {
    if (atRoots) return;
    backTo(_stack.length - 2);
  }

  void backTo(int depth) {
    if (depth < 0 || depth >= _stack.length - 1) return;
    _generation++;
    _stack = _stack.sublist(0, depth + 1);
    if (_stack.length == 1) _root = null;
    _status = NavStatus.idle;
    _notify();
  }

  NewFolderProblem? validateNewFolder(String name) {
    if (!isValidFolderName(name)) return NewFolderProblem.invalid;
    if (isRepositoryFolderName(name)) return NewFolderProblem.repository;
    final key = folderKey(name);
    for (final folder in _stack.last.folders) {
      if (folderKey(folder) == key) return NewFolderProblem.exists;
    }
    return null;
  }

  void createVirtual(String name) {
    if (!canCreateFolder || validateNewFolder(name) != null) return;
    _stack = [..._stack, NavLevel(name: name, folders: const [], isNew: true)];
    _status = NavStatus.idle;
    _notify();
  }

  SharedFolderDestination? get current {
    final root = _root;
    if (atRoots || root == null) return null;
    final last = _stack.last;
    final path = _pathOfStack(skipNew: true);
    return SharedFolderDestination(
      rootId: root.id,
      rootName: root.name,
      home: root.home,
      path: path,
      newFolder: last.isNew ? last.name : null,
    );
  }

  SavedDestination? get currentSaved {
    final root = _root;
    if (atRoots || root == null || insideNew) return null;
    return SavedDestination(
      rootId: root.id,
      rootName: root.name,
      home: root.home,
      path: _pathOfStack(),
    );
  }

  String get currentLabel {
    final destination = current;
    if (destination == null) return '';
    return destination.label.display(homeName: _homeName);
  }

  List<String> _pathOfStack({bool skipNew = false}) => [
    for (var i = 2; i < _stack.length; i++)
      if (!(skipNew && _stack[i].isNew)) _stack[i].name!,
  ];

  void _toRoots() {
    _stack = [_stack.first];
    _root = null;
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
