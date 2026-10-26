import 'dart:async';

import 'package:flutter/widgets.dart';

import 'pairing_dialogs.dart' show dialogActivationDelay;

class Armed extends StatefulWidget {
  const Armed({required this.armKey, required this.builder, super.key});

  final Object armKey;
  final Widget Function(BuildContext context, bool armed) builder;

  @override
  State<Armed> createState() => _ArmedState();
}

class _ArmedState extends State<Armed> {
  bool _armed = false;
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _arm();
  }

  @override
  void didUpdateWidget(Armed oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.armKey != widget.armKey) {
      _armed = false;
      _arm();
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  void _arm() {
    _timer?.cancel();
    _timer = Timer(dialogActivationDelay, () {
      if (mounted) setState(() => _armed = true);
    });
  }

  @override
  Widget build(BuildContext context) => widget.builder(context, _armed);
}
