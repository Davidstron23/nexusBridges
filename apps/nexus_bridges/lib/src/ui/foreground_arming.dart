import 'dart:async';

import 'package:flutter/widgets.dart';

import 'armed.dart';

final class ForegroundArming extends ValueNotifier<bool> {
  ForegroundArming({this._delay = dialogActivationDelay}) : super(false) {
    _lifecycle = AppLifecycleListener(onStateChange: _onState);
    final current = WidgetsBinding.instance.lifecycleState;
    if (current == null || current == AppLifecycleState.resumed) _schedule();
  }

  final Duration _delay;
  late final AppLifecycleListener _lifecycle;
  Timer? _timer;

  void _schedule() {
    _timer?.cancel();
    _timer = Timer(_delay, () {
      _timer = null;
      value = true;
    });
  }

  void _onState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      if (!value && _timer == null) _schedule();
      return;
    }
    _timer?.cancel();
    _timer = null;
    value = false;
  }

  @override
  void dispose() {
    _timer?.cancel();
    _timer = null;
    _lifecycle.dispose();
    super.dispose();
  }
}

final class ForegroundArmingScope extends InheritedNotifier<ForegroundArming> {
  const ForegroundArmingScope({
    required ForegroundArming arming,
    required super.child,
    super.key,
  }) : super(notifier: arming);

  static bool armedOf(BuildContext context) {
    final scope = context
        .getInheritedWidgetOfExactType<ForegroundArmingScope>();
    return scope?.notifier?.value ?? true;
  }
}
