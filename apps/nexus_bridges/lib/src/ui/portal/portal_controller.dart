import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:nexus_bridges_core/nexus_bridges_core.dart';

import '../../app_controller.dart';
import '../destination/navigator_controller.dart';

const Duration portalHoldDelay = Duration(milliseconds: 500);
const Duration portalGrace = Duration(milliseconds: 400);
const Duration portalRootsWait = Duration(seconds: 2);
const Duration portalCacheLife = Duration(seconds: 5);
const double portalMoveLock = 6;
const double portalEdgeBand = 48;
const double portalEdgeSlowest = 1.5;
const double portalEdgeFastest = 6;
const Duration portalEdgeTick = Duration(milliseconds: 16);

sealed class PortalHit {
  const PortalHit();
}

final class PortalFolderHit extends PortalHit {
  const PortalFolderHit(this.name, {this.rootId});

  final String name;
  final String? rootId;

  @override
  bool operator ==(Object other) =>
      other is PortalFolderHit && other.name == name && other.rootId == rootId;

  @override
  int get hashCode => Object.hash(PortalFolderHit, name, rootId);
}

final class PortalBackHit extends PortalHit {
  const PortalBackHit();

  @override
  bool operator ==(Object other) => other is PortalBackHit;

  @override
  int get hashCode => (PortalBackHit).hashCode;
}

final class PortalHereHit extends PortalHit {
  const PortalHereHit();

  @override
  bool operator ==(Object other) => other is PortalHereHit;

  @override
  int get hashCode => (PortalHereHit).hashCode;
}

final class PortalBackgroundHit extends PortalHit {
  const PortalBackgroundHit();

  @override
  bool operator ==(Object other) => other is PortalBackgroundHit;

  @override
  int get hashCode => (PortalBackgroundHit).hashCode;
}

final class _Fetch {
  _Fetch(this.startedAt, this.future);

  final DateTime startedAt;
  final Future<RemoteListing> future;
  RemoteListing? result;
  DateTime? arrivedAt;
}

final class PortalController extends ChangeNotifier {
  PortalController({
    required this.app,
    required this.homeName,
    required this.anchorOf,
    DateTime Function()? now,
    this.holdDelay = portalHoldDelay,
    this.grace = portalGrace,
    this.rootsWait = portalRootsWait,
  }) : _now = now ?? DateTime.now;

  final AppController app;
  final String Function() homeName;
  final Rect? Function(String fingerprint) anchorOf;
  final Duration holdDelay;
  final Duration grace;
  final Duration rootsWait;
  final DateTime Function() _now;

  final Map<String, _Fetch> _fetches = {};
  final Map<PortalHit, GlobalKey> _rows = {};
  GlobalKey? _panelKey;
  GlobalKey? _listKey;
  ScrollController? _listScroll;
  Timer? _scrollTimer;
  double _scrollStep = 0;
  FolderNavigatorController? _navigator;
  String? _fingerprint;
  Rect? _anchor;
  PortalHit? _armed;
  Offset? _lock;
  Timer? _holdTimer;
  Timer? _closeTimer;
  bool _dragging = false;
  int _requestId = 0;
  bool _disposed = false;

  bool get isOpen => _navigator != null;

  String? get fingerprint => _fingerprint;

  FolderNavigatorController? get navigator => _navigator;

  PortalHit? get armed => _armed;

  Rect? get anchor => _fingerprint == null ? null : _anchor;

  void dragStarted() {
    _closeNow();
    _fetches.clear();
    _dragging = true;
  }

  void dragEnded() {
    _dragging = false;
    _requestId++;
    _closeNow();
  }

  void cancelPending() => _requestId++;

  void prefetch(String fingerprint) {
    if (!_dragging || _fetches.containsKey(fingerprint)) return;
    final fetch = _Fetch(_now(), app.listRemoteRoots(fingerprint));
    _fetches[fingerprint] = fetch;
    unawaited(
      fetch.future.then((value) {
        fetch.result = value;
        fetch.arrivedAt = _now();
      }, onError: (_) {}),
    );
  }

  RemoteRoots? cachedRoots(String fingerprint) {
    final fetch = _fetches[fingerprint];
    final result = fetch?.result;
    final arrived = fetch?.arrivedAt;
    if (result is! RemoteRoots || arrived == null) return null;
    if (_now().difference(arrived) > portalCacheLife) return null;
    return result;
  }

  Future<void> request(String fingerprint) async {
    if (!_dragging || (isOpen && _fingerprint == fingerprint)) return;
    prefetch(fingerprint);
    final fetch = _fetches[fingerprint];
    if (fetch == null) return;
    final anchor = anchorOf(fingerprint);
    final id = ++_requestId;
    RemoteListing? listing = fetch.result;
    if (listing == null) {
      final left = rootsWait - _now().difference(fetch.startedAt);
      if (left <= Duration.zero) return;
      try {
        listing = await fetch.future.timeout(left);
      } catch (_) {
        return;
      }
    }
    if (_disposed || id != _requestId || !_dragging) return;
    if (listing is! RemoteRoots) return;
    final available = [
      for (final root in listing.roots)
        if (root.available) root,
    ];
    if (available.isEmpty) return;
    _open(fingerprint, available, anchor);
  }

  void _open(String fingerprint, List<RemoteRoot> roots, Rect? anchor) {
    _closeNow();
    _fingerprint = fingerprint;
    _anchor = anchor;
    _navigator = FolderNavigatorController(
      app: app,
      fingerprint: fingerprint,
      roots: roots,
      mode: NavigatorMode.portal,
      homeName: homeName(),
    )..addListener(_onNavigator);
    _lock = null;
    _notify();
  }

  void _onNavigator() => _notify();

  void bindPanel(GlobalKey key) => _panelKey = key;

  void registerRow(PortalHit hit, GlobalKey key) => _rows[hit] = key;

  void clearRows() => _rows.clear();

  void bindList(GlobalKey key, ScrollController controller) {
    _listKey = key;
    _listScroll = controller;
  }

  void unbindList(ScrollController controller) {
    if (_listScroll != controller) return;
    _listScroll = null;
    _listKey = null;
    _stopScroll();
  }

  double _edgeStep(Offset position) {
    final controller = _listScroll;
    final rect = _rectOf(_listKey);
    if (controller == null || rect == null || !controller.hasClients) return 0;
    if (position.dx < rect.left || position.dx > rect.right) return 0;
    final metrics = controller.position;
    final top = position.dy - rect.top;
    final bottom = rect.bottom - position.dy;
    if (top >= 0 && top < portalEdgeBand && metrics.pixels > 0) {
      final depth = 1 - top / portalEdgeBand;
      return -(portalEdgeSlowest +
          (portalEdgeFastest - portalEdgeSlowest) * depth);
    }
    if (bottom >= 0 &&
        bottom < portalEdgeBand &&
        metrics.pixels < metrics.maxScrollExtent) {
      final depth = 1 - bottom / portalEdgeBand;
      return portalEdgeSlowest +
          (portalEdgeFastest - portalEdgeSlowest) * depth;
    }
    return 0;
  }

  void _startScroll(double step) {
    _scrollStep = step;
    _scrollTimer ??= Timer.periodic(portalEdgeTick, (_) {
      final controller = _listScroll;
      if (controller == null || !controller.hasClients) {
        _stopScroll();
        return;
      }
      final metrics = controller.position;
      final next = (metrics.pixels + _scrollStep).clamp(
        metrics.minScrollExtent,
        metrics.maxScrollExtent,
      );
      if (next == metrics.pixels) {
        _stopScroll();
        return;
      }
      controller.jumpTo(next);
    });
  }

  void _stopScroll() {
    _scrollTimer?.cancel();
    _scrollTimer = null;
    _scrollStep = 0;
  }

  Rect? _rectOf(GlobalKey? key) {
    final context = key?.currentContext;
    if (context == null) return null;
    final render = context.findRenderObject();
    if (render is! RenderBox || !render.attached || !render.hasSize) {
      return null;
    }
    return render.localToGlobal(Offset.zero) & render.size;
  }

  PortalHit? hitTest(Offset position) {
    if (!isOpen) return null;
    final list = _rectOf(_listKey);
    for (final entry in _rows.entries) {
      if (entry.key is PortalFolderHit &&
          list != null &&
          !list.contains(position)) {
        continue;
      }
      final rect = _rectOf(entry.value);
      if (rect != null && rect.contains(position)) return entry.key;
    }
    final panel = _rectOf(_panelKey);
    if (panel != null && panel.contains(position)) {
      return const PortalBackgroundHit();
    }
    return null;
  }

  void hover(PortalHit? hit, Offset position) {
    if (!isOpen) return;
    _closeTimer?.cancel();
    _closeTimer = null;
    final step = _edgeStep(position);
    if (step != 0) {
      _holdTimer?.cancel();
      _holdTimer = null;
      if (_armed != null) {
        _armed = null;
        _notify();
      }
      _startScroll(step);
      return;
    }
    _stopScroll();
    final lock = _lock;
    if (lock != null) {
      if ((position - lock).distance < portalMoveLock) return;
      _lock = null;
    }
    if (hit == _armed) return;
    _holdTimer?.cancel();
    _holdTimer = null;
    _armed = hit;
    _notify();
    if (hit is PortalFolderHit || hit is PortalBackHit) {
      final target = hit;
      _holdTimer = Timer(holdDelay, () {
        _holdTimer = null;
        if (_armed != target || !isOpen) return;
        unawaited(_navigate(target!, position));
      });
    }
  }

  Future<void> _navigate(PortalHit hit, Offset position) async {
    final navigator = _navigator;
    if (navigator == null) return;
    switch (hit) {
      case PortalFolderHit(:final name, :final rootId):
        if (rootId != null) {
          await navigator.enterRoot(rootId);
        } else {
          await navigator.enter(name);
        }
      case PortalBackHit():
        navigator.back();
      default:
        return;
    }
    if (_disposed || _navigator != navigator) return;
    _armed = null;
    _lock = position;
    _notify();
  }

  void pointerOutside({required bool overOtherDevice}) {
    if (!isOpen) return;
    _stopScroll();
    _holdTimer?.cancel();
    _holdTimer = null;
    if (_armed != null) {
      _armed = null;
      _notify();
    }
    if (overOtherDevice) {
      _closeNow();
      return;
    }
    _closeTimer ??= Timer(grace, () {
      _closeTimer = null;
      _closeNow();
    });
  }

  void pointerBackOnDevice() {
    _closeTimer?.cancel();
    _closeTimer = null;
  }

  SharedFolderDestination? drop(PortalHit? hit) {
    final navigator = _navigator;
    if (navigator == null || hit == null) return null;
    SharedFolderDestination? destination;
    switch (hit) {
      case PortalFolderHit(:final name, :final rootId):
        if (navigator.atRoots) {
          final root = rootId == null ? null : navigator.rootWithId(rootId);
          if (root != null) {
            destination = SharedFolderDestination(
              rootId: root.id,
              rootName: root.name,
              home: root.home,
              path: const [],
            );
          }
        } else if (rootId == null) {
          final current = navigator.current;
          if (current != null && navigator.stack.last.folders.contains(name)) {
            destination = SharedFolderDestination(
              rootId: current.rootId,
              rootName: current.rootName,
              home: current.home,
              path: [...current.path, name],
            );
          }
        }
      case PortalHereHit() || PortalBackgroundHit() || PortalBackHit():
        destination = navigator.current;
    }
    return destination;
  }

  void _closeNow() {
    _stopScroll();
    _holdTimer?.cancel();
    _holdTimer = null;
    _closeTimer?.cancel();
    _closeTimer = null;
    final navigator = _navigator;
    if (navigator == null && _fingerprint == null) return;
    _navigator = null;
    _fingerprint = null;
    _anchor = null;
    _armed = null;
    _lock = null;
    _rows.clear();
    if (navigator != null) {
      navigator.removeListener(_onNavigator);
      WidgetsBinding.instance.addPostFrameCallback((_) => navigator.dispose());
    }
    _notify();
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _stopScroll();
    _holdTimer?.cancel();
    _closeTimer?.cancel();
    _navigator?.removeListener(_onNavigator);
    _navigator?.dispose();
    super.dispose();
  }
}
