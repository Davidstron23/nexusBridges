import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:nexus_bridges_core/nexus_bridges_core.dart' show ThemeChoice;

import '../app_controller.dart';
import '../ui/theme/app_theme.dart';
import 'window_host.dart';

bool effectiveDarkOf(ThemeChoice theme, Brightness platform) {
  return switch (theme) {
    ThemeChoice.dark => true,
    ThemeChoice.light => false,
    ThemeChoice.system => platform == Brightness.dark,
  };
}

final class TitleBarSync with WidgetsBindingObserver {
  TitleBarSync({
    required this._host,
    required this._controller,
    this._fade = themeFade,
  });

  final WindowHost _host;
  final AppController _controller;
  final Duration _fade;

  Timer? _timer;
  late bool _target;
  bool _started = false;

  bool get _dark => effectiveDarkOf(
    _controller.theme,
    WidgetsBinding.instance.platformDispatcher.platformBrightness,
  );

  void start() {
    if (_started) return;
    _started = true;
    _target = _dark;
    WidgetsBinding.instance.addObserver(this);
    _controller.addListener(_sync);
  }

  @override
  void didChangePlatformBrightness() => _sync();

  void _sync() {
    final dark = _dark;
    if (dark == _target) return;
    _target = dark;
    _timer?.cancel();
    final animated = !WidgetsBinding
        .instance
        .platformDispatcher
        .accessibilityFeatures
        .disableAnimations;
    if (!animated) {
      unawaited(_host.setDarkTitleBar(dark));
      return;
    }
    _timer = Timer(_fade ~/ 2, () => unawaited(_host.setDarkTitleBar(dark)));
  }

  void dispose() {
    if (!_started) return;
    _started = false;
    _timer?.cancel();
    _timer = null;
    _controller.removeListener(_sync);
    WidgetsBinding.instance.removeObserver(this);
  }
}
