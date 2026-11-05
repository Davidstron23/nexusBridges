import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/widgets.dart';

import 'package:nexus_bridges_core/nexus_bridges_core.dart'
    show SharedFolderDestination;

import '../ui/portal/portal_controller.dart';
import 'drop_events.dart';

const int maxDropItems = 1000;
const Duration portalDelay = Duration(milliseconds: 500);
const Duration prefetchDelay = Duration(milliseconds: 200);

sealed class DropOutcome {
  const DropOutcome();
}

final class DropSend extends DropOutcome {
  const DropSend(this.fingerprint, this.paths);

  final String fingerprint;
  final List<String> paths;
}

final class DropSendTo extends DropOutcome {
  const DropSendTo(this.fingerprint, this.paths, this.destination);

  final String fingerprint;
  final List<String> paths;
  final SharedFolderDestination destination;
}

final class DropToTray extends DropOutcome {
  const DropToTray(this.paths, this.count, {this.blockedFingerprint});

  final List<String> paths;
  final int count;
  final String? blockedFingerprint;
}

final class DropTooMany extends DropOutcome {
  const DropTooMany();
}

bool _never() => false;

final class _Zone {
  const _Zone(this.fingerprint, this.key);

  final String fingerprint;
  final GlobalKey key;
}

class DropController extends ChangeNotifier {
  DropController({
    required this.canSendTo,
    required this.isMine,
    required this.onPortal,
    required this.onOutcome,
    this.isBlocked = _never,
    this.blocked = _never,
    this.portalAfter = portalDelay,
    this.prefetchAfter = prefetchDelay,
    this.onPrefetch,
    this.portal,
  });

  final bool Function(String fingerprint) canSendTo;
  final bool Function(String fingerprint) isMine;
  final void Function(String fingerprint) onPortal;
  final void Function(DropOutcome outcome) onOutcome;
  final bool Function() isBlocked;
  final bool Function() blocked;
  final Duration portalAfter;
  final Duration prefetchAfter;
  final void Function(String fingerprint)? onPrefetch;
  final PortalController? portal;

  final List<_Zone> _zones = [];
  bool _dragging = false;
  Offset _position = Offset.zero;
  String? _hovered;
  Timer? _portalTimer;
  Timer? _prefetchTimer;

  bool get dragging => _dragging;

  Offset get position => _position;

  String? get hovered => _hovered;

  Rect? zoneRect(String fingerprint) {
    Rect? first;
    for (final zone in _zones) {
      if (zone.fingerprint != fingerprint) continue;
      final render = zone.key.currentContext?.findRenderObject();
      if (render is! RenderBox || !render.attached || !render.hasSize) continue;
      final rect = render.localToGlobal(Offset.zero) & render.size;
      if (rect.contains(_position)) return rect;
      first ??= rect;
    }
    return first;
  }

  void register(String fingerprint, GlobalKey key) {
    _zones.removeWhere((zone) => zone.key == key);
    _zones.add(_Zone(fingerprint, key));
  }

  void unregister(GlobalKey key) {
    _zones.removeWhere((zone) => zone.key == key);
  }

  void handle(DropEvent event) {
    if (blocked()) {
      _reset();
      return;
    }
    switch (event) {
      case DropEnter(:final position):
        _track(position);
      case DropOver(:final position):
        _track(position);
      case DropLeave():
        _reset();
      case DropDone(:final position, :final paths, :final count):
        final lit = _dragging ? _hovered : null;
        final under = isBlocked() ? null : _zoneAt(position);
        final target = !_dragging || under == lit ? under : null;
        final portal = this.portal;
        final portalHit = portal?.hitTest(position);
        final portalDevice = portal?.fingerprint;
        final destination = portal?.drop(portalHit);
        _reset();
        if (portalHit != null && portalDevice != null) {
          if (destination == null) return;
          _resolve(portalDevice, paths, count, destination: destination);
          return;
        }
        _resolve(target, paths, count);
    }
  }

  void _track(Offset position) {
    if (isBlocked()) {
      _reset();
      return;
    }
    _position = position;
    final changed = !_dragging;
    _dragging = true;
    final portal = this.portal;
    if (changed) portal?.dragStarted();
    final target = _zoneAt(position);
    if (portal != null && portal.isOpen) {
      final hit = portal.hitTest(position);
      if (hit != null) {
        portal.hover(hit, position);
        if (_hovered != portal.fingerprint) _hovered = portal.fingerprint;
        notifyListeners();
        return;
      }
      if (target == portal.fingerprint) {
        portal.pointerBackOnDevice();
        portal.hover(null, position);
      } else {
        portal.pointerOutside(overOtherDevice: target != null);
      }
    }
    if (target != _hovered) {
      _hover(target);
    } else if (changed) {
      notifyListeners();
    }
  }

  void _hover(String? fingerprint) {
    _portalTimer?.cancel();
    _portalTimer = null;
    _prefetchTimer?.cancel();
    _prefetchTimer = null;
    _hovered = fingerprint;
    if (fingerprint != null && canSendTo(fingerprint)) {
      if (isMine(fingerprint)) {
        _prefetchTimer = Timer(prefetchAfter, () {
          _prefetchTimer = null;
          if (_hovered == fingerprint && canSendTo(fingerprint)) {
            onPrefetch?.call(fingerprint);
          }
        });
      }
      _portalTimer = Timer(portalAfter, () {
        _portalTimer = null;
        if (_hovered == fingerprint &&
            canSendTo(fingerprint) &&
            isMine(fingerprint)) {
          onPortal(fingerprint);
        }
      });
    }
    notifyListeners();
  }

  void _reset() {
    _portalTimer?.cancel();
    _portalTimer = null;
    _prefetchTimer?.cancel();
    _prefetchTimer = null;
    if (!_dragging && _hovered == null) return;
    portal?.dragEnded();
    _dragging = false;
    _hovered = null;
    notifyListeners();
  }

  void _resolve(
    String? target,
    List<String> paths,
    int count, {
    SharedFolderDestination? destination,
  }) {
    if (paths.isEmpty) return;
    if (count > paths.length && count <= maxDropItems) return;
    if (target != null && canSendTo(target)) {
      onOutcome(
        count > maxDropItems
            ? const DropTooMany()
            : destination != null
            ? DropSendTo(target, paths, destination)
            : DropSend(target, paths),
      );
      return;
    }
    onOutcome(DropToTray(paths, count, blockedFingerprint: target));
  }

  String? _zoneAt(Offset position) {
    final live = <(String, RenderObject)>[];
    int? viewId;
    for (final zone in _zones) {
      final context = zone.key.currentContext;
      if (context == null) continue;
      final render = context.findRenderObject();
      if (render == null || !render.attached) continue;
      viewId ??= View.maybeOf(context)?.viewId;
      live.add((zone.fingerprint, render));
    }
    if (live.isEmpty || viewId == null) return null;
    final result = HitTestResult();
    WidgetsBinding.instance.hitTestInView(result, position, viewId);
    final hit = {for (final entry in result.path) entry.target};
    for (final (fingerprint, render) in live) {
      if (hit.contains(render)) return fingerprint;
    }
    return null;
  }

  @override
  void dispose() {
    _portalTimer?.cancel();
    _portalTimer = null;
    _prefetchTimer?.cancel();
    _prefetchTimer = null;
    super.dispose();
  }
}
