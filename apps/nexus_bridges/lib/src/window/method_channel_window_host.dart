import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'window_host.dart';

const String windowChannelName = 'nexus_bridges/window';

final class MethodChannelWindowHost implements WindowHost {
  MethodChannelWindowHost({
    this._channel = const MethodChannel(windowChannelName),
  });

  final MethodChannel _channel;

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
  Future<void> setDarkTitleBar(bool dark) async {
    await _invoke<void>('setDarkTitleBar', {'dark': dark});
  }
}
