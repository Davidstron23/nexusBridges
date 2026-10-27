import 'dart:async';

import 'package:flutter/widgets.dart';

const Duration dialogActivationDelay = Duration(milliseconds: 500);

mixin ArmingState<T extends StatefulWidget> on State<T> {
  bool _armed = false;
  bool _foreground = true;
  Timer? _armTimer;
  late final AppLifecycleListener _lifecycle;

  bool get armed => _armed;

  @override
  void initState() {
    super.initState();
    final current = WidgetsBinding.instance.lifecycleState;
    _foreground = current == null || current == AppLifecycleState.resumed;
    _lifecycle = AppLifecycleListener(onStateChange: _onLifecycleChanged);
    rearm();
  }

  void rearm() {
    _armTimer?.cancel();
    _armTimer = null;
    _armed = false;
    if (!_foreground) return;
    _armTimer = Timer(dialogActivationDelay, () {
      if (mounted) setState(() => _armed = true);
    });
  }

  void _onLifecycleChanged(AppLifecycleState state) {
    if (!mounted) return;
    final foreground = state == AppLifecycleState.resumed;
    if (foreground == _foreground) return;
    setState(() {
      _foreground = foreground;
      rearm();
    });
  }

  @override
  void dispose() {
    _armTimer?.cancel();
    _lifecycle.dispose();
    super.dispose();
  }
}

class Armed extends StatefulWidget {
  const Armed({required this.armKey, required this.builder, super.key});

  final Object armKey;
  final Widget Function(BuildContext context, bool armed) builder;

  @override
  State<Armed> createState() => _ArmedState();
}

class _ArmedState extends State<Armed> with ArmingState<Armed> {
  @override
  void didUpdateWidget(Armed oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.armKey != widget.armKey) rearm();
  }

  @override
  Widget build(BuildContext context) => widget.builder(context, armed);
}
