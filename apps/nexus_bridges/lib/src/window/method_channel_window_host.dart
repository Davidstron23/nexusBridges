import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'window_host.dart';

const String windowChannelName = 'nexus_bridges/window';

final class MethodChannelWindowHost implements WindowHost {
  MethodChannelWindowHost({
    this._channel = const MethodChannel(windowChannelName),
  }) {
    _channel.setMethodCallHandler(_onCall);
  }

  final MethodChannel _channel;
  final StreamController<WindowEvent> _events =
      StreamController<WindowEvent>.broadcast();

  @override
  Stream<WindowEvent> get events => _events.stream;

  Future<Object?> _onCall(MethodCall call) async {
    switch (call.method) {
      case 'closeRequested':
        _events.add(const CloseRequested());
      case 'exitRequested':
        _events.add(const ExitRequested());
      case 'trayVisibility':
        final arguments = call.arguments;
        final visible = arguments is Map ? arguments['visible'] : null;
        if (visible is bool) {
          _events.add(TrayVisibilityChanged(visible));
        }
    }
    return null;
  }

  Future<T?> _invoke<T>(String method, [Object? arguments]) async {
    try {
      return await _channel.invokeMethod<T>(method, arguments);
    } on MissingPluginException catch (error) {
      debugPrint('window $method unavailable: ${error.runtimeType}');
    } on PlatformException catch (error) {
      debugPrint('window $method failed: ${error.runtimeType}');
    }
    return null;
  }

  @override
  Future<bool> attach() async => await _invoke<bool>('attach') ?? false;

  @override
  Future<bool> setTray({
    required bool enabled,
    required TrayTexts texts,
  }) async {
    final visible = await _invoke<bool>('setTray', {
      'enabled': enabled,
      'tooltip': texts.tooltip,
      'open': texts.open,
      'exit': texts.exit,
    });
    return visible ?? false;
  }

  @override
  Future<bool> showTrayHint({
    required String title,
    required String body,
  }) async {
    final shown = await _invoke<bool>('showTrayHint', {
      'title': title,
      'body': body,
    });
    return shown ?? false;
  }

  @override
  Future<void> hide() async {
    await _invoke<void>('hide');
  }

  @override
  Future<void> show() async {
    await _invoke<void>('show');
  }

  @override
  Future<void> minimize() async {
    await _invoke<void>('minimize');
  }

  @override
  Future<bool> attention() async {
    final reply = await _invoke<Map<Object?, Object?>>('attention');
    return reply?['foreground'] == true;
  }

  @override
  Future<void> setDarkTitleBar(bool dark) async {
    await _invoke<void>('setDarkTitleBar', {'dark': dark});
  }

  @override
  Future<void> quit() async {
    await _invoke<void>('quit');
  }
}
