import 'dart:async';

import 'package:flutter/widgets.dart';

const Duration dialogActivationDelay = Duration(milliseconds: 500);

mixin ArmingState<T extends StatefulWidget> on State<T> {
  bool _armed = false;
  bool _foreground = true;
  bool _onTop = true;
  Timer? _armTimer;
  late final AppLifecycleListener _lifecycle;

  bool get armed => _armed;

  bool get coverOnly => false;

  @override
  void initState() {
    super.initState();
    final current = WidgetsBinding.instance.lifecycleState;
    _foreground =
        coverOnly || current == null || current == AppLifecycleState.resumed;
    _lifecycle = AppLifecycleListener(onStateChange: _onLifecycleChanged);
    if (coverOnly) {
      _armed = true;
    } else {
      rearm();
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final onTop = ModalRoute.isCurrentOf(context) ?? true;
    if (onTop == _onTop) return;
    _onTop = onTop;
    rearm();
  }

  void rearm() {
    _armTimer?.cancel();
    _armTimer = null;
    _armed = false;
    if (!_foreground || !_onTop) return;
    _armTimer = Timer(dialogActivationDelay, () {
      if (mounted) setState(() => _armed = true);
    });
  }

  void _onLifecycleChanged(AppLifecycleState state) {
    if (!mounted || coverOnly) return;
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
