import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

const String dropChannelName = 'nexus_bridges/drop';
const int maxDropPaths = 1001;

sealed class DropEvent {
  const DropEvent();
}

final class DropEnter extends DropEvent {
  const DropEnter(this.position);

  final Offset position;
}

final class DropOver extends DropEvent {
  const DropOver(this.position);

  final Offset position;
}

final class DropLeave extends DropEvent {
  const DropLeave();
}

final class DropDone extends DropEvent {
  const DropDone(this.position, this.paths, this.count);

  final Offset position;
  final List<String> paths;
  final int count;
}

abstract interface class DropEvents {
  Stream<DropEvent> get events;
}

double _platformPixelRatio() {
  final ratio =
      WidgetsBinding.instance.platformDispatcher.implicitView?.devicePixelRatio;
  return ratio ?? 1;
}

class MethodChannelDropEvents implements DropEvents {
  MethodChannelDropEvents({
    MethodChannel? channel,
    double Function()? devicePixelRatio,
  }) : _channel = channel ?? const MethodChannel(dropChannelName),
       _pixelRatio = devicePixelRatio ?? _platformPixelRatio {
    _controller = StreamController<DropEvent>.broadcast(
      onListen: () => _channel.setMethodCallHandler(_onCall),
      onCancel: () => _channel.setMethodCallHandler(null),
    );
  }

  final MethodChannel _channel;
  final double Function() _pixelRatio;
  late final StreamController<DropEvent> _controller;

  @override
  Stream<DropEvent> get events => _controller.stream;

  Future<void> _onCall(MethodCall call) async {
    final event = _parse(call);
    if (event != null) _controller.add(event);
  }

  DropEvent? _parse(MethodCall call) {
    switch (call.method) {
      case 'leave':
        return const DropLeave();
      case 'enter':
        final position = _position(call.arguments);
        return position == null ? null : DropEnter(position);
      case 'over':
        final position = _position(call.arguments);
        return position == null ? null : DropOver(position);
      case 'drop':
        return _drop(call.arguments);
      default:
        return null;
    }
  }

  Offset? _position(Object? arguments) {
    if (arguments is! Map) return null;
    final x = arguments['x'];
    final y = arguments['y'];
    if (x is! num || y is! num || !x.isFinite || !y.isFinite) return null;
    final ratio = _pixelRatio();
    final scale = ratio.isFinite && ratio > 0 ? ratio : 1.0;
    return Offset(x / scale, y / scale);
  }

  DropEvent? _drop(Object? arguments) {
    final position = _position(arguments);
    if (position == null || arguments is! Map) return null;
    final rawPaths = arguments['paths'];
    final count = arguments['count'];
    if (rawPaths is! List || count is! int) return null;
    final paths = <String>[];
    for (final path in rawPaths) {
      if (path is! String || path.isEmpty) return null;
      if (paths.length < maxDropPaths) paths.add(path);
    }
    if (paths.isEmpty || count < paths.length) return null;
    return DropDone(position, List.unmodifiable(paths), count);
  }
}
