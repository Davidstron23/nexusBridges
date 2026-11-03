import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/widgets.dart';

import 'drop_events.dart';

const int maxDropItems = 1000;
const Duration portalDelay = Duration(milliseconds: 500);

sealed class DropOutcome {
  const DropOutcome();
}

final class DropSend extends DropOutcome {
  const DropSend(this.fingerprint, this.paths);

  final String fingerprint;
  final List<String> paths;
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
    this.portalAfter = portalDelay,
  });

  final bool Function(String fingerprint) canSendTo;
  final bool Function(String fingerprint) isMine;
  final void Function(String fingerprint) onPortal;
  final void Function(DropOutcome outcome) onOutcome;
  final Duration portalAfter;

  final List<_Zone> _zones = [];
  bool _dragging = false;
  Offset _position = Offset.zero;
  String? _hovered;
  Timer? _portalTimer;

  bool get dragging => _dragging;

  Offset get position => _position;

  String? get hovered => _hovered;

  void register(String fingerprint, GlobalKey key) {
    _zones.removeWhere((zone) => zone.key == key);
    _zones.add(_Zone(fingerprint, key));
  }

  void unregister(GlobalKey key) {
    _zones.removeWhere((zone) => zone.key == key);
  }

  void handle(DropEvent event) {
    switch (event) {
      case DropEnter(:final position):
        _track(position);
      case DropOver(:final position):
        _track(position);
      case DropLeave():
        _reset();
      case DropDone(:final position, :final paths, :final count):
        final target = _zoneAt(position);
        _reset();
        _resolve(target, paths, count);
    }
  }

  void _track(Offset position) {
    _position = position;
    final changed = !_dragging;
    _dragging = true;
    final target = _zoneAt(position);
    if (target != _hovered) {
      _hover(target);
    } else if (changed) {
      notifyListeners();
    }
  }

  void _hover(String? fingerprint) {
    _portalTimer?.cancel();
    _portalTimer = null;
    _hovered = fingerprint;
    if (fingerprint != null && canSendTo(fingerprint)) {
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
    if (!_dragging && _hovered == null) return;
    _dragging = false;
    _hovered = null;
    notifyListeners();
  }

  void _resolve(String? target, List<String> paths, int count) {
    if (paths.isEmpty) return;
    if (count > paths.length && count <= maxDropItems) return;
    if (target != null && canSendTo(target)) {
      onOutcome(
        count > maxDropItems ? const DropTooMany() : DropSend(target, paths),
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
    super.dispose();
  }
}
