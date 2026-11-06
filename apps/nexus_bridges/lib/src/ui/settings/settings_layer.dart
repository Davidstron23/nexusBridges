import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../app_controller.dart';
import '../attention.dart';
import '../modal/timeline.dart';
import 'settings_controller.dart';
import 'settings_screen.dart';

const Duration _enterTotal = Duration(milliseconds: 620);
const Duration _exitTotal = Duration(milliseconds: 500);
const double _enterMs = 620;
const double _exitMs = 500;
const double _screenShift = 44;
const double _mainShift = 36;
const double _paintOpacity = 1 / 255;
const Cubic _ease = labEaseOut;
const Cubic _easeIn = Cubic(0.55, 0, 1, 0.45);

double _span(double elapsed, double from, double length) {
  return ((elapsed - from) / length).clamp(0.0, 1.0);
}

final class _Phase {
  const _Phase({
    required this.away,
    required this.mainOpacity,
    required this.screenOpacity,
    required this.screenShift,
  });

  final double away;
  final double mainOpacity;
  final double screenOpacity;
  final double screenShift;

  static _Phase of(AnimationController motion) {
    final value = motion.value;
    if (motion.status == AnimationStatus.reverse) {
      final elapsed = (1 - value) * _exitMs;
      return _Phase(
        away: 1 - _ease.transform(_span(elapsed, 0, 500)),
        mainOpacity: _ease.transform(_span(elapsed, 0, 420)),
        screenOpacity: 1 - _ease.transform(_span(elapsed, 0, 340)),
        screenShift: _screenShift * _easeIn.transform(_span(elapsed, 0, 400)),
      );
    }
    final elapsed = value * _enterMs;
    return _Phase(
      away: _ease.transform(_span(elapsed, 0, 500)),
      mainOpacity: 1 - _ease.transform(_span(elapsed, 0, 420)),
      screenOpacity: _ease.transform(_span(elapsed, 60, 500)),
      screenShift:
          _screenShift * (1 - _ease.transform(_span(elapsed, 60, 560))),
    );
  }
}

class SettingsLayer extends StatefulWidget {
  const SettingsLayer({
    required this.controller,
    required this.settings,
    required this.child,
    this.attention,
    super.key,
  });

  final AppController controller;
  final SettingsController settings;
  final AttentionWatcher? attention;
  final Widget child;

  @override
  State<SettingsLayer> createState() => _SettingsLayerState();
}

class _SettingsLayerState extends State<SettingsLayer>
    with SingleTickerProviderStateMixin {
  late final AnimationController _motion = AnimationController(
    vsync: this,
    duration: _enterTotal,
    reverseDuration: _exitTotal,
  );
  final SnapshotController _snapshots = SnapshotController();
  int _preparing = 0;
  bool _wasOpen = false;
  bool _reduceMotion = false;
  bool _closedByAttention = false;
  FocusNode? _returnFocus;

  @override
  void initState() {
    super.initState();
    _motion.addStatusListener(_onStatus);
    widget.settings.addListener(_onSettings);
    widget.attention?.addListener(_onAttention);
    if (widget.settings.isOpen) {
      _wasOpen = true;
      _motion.value = 1;
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _reduceMotion = MediaQuery.disableAnimationsOf(context);
  }

  @override
  void didUpdateWidget(SettingsLayer oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.settings != widget.settings) {
      oldWidget.settings.removeListener(_onSettings);
      widget.settings.addListener(_onSettings);
    }
    if (oldWidget.attention != widget.attention) {
      oldWidget.attention?.removeListener(_onAttention);
      widget.attention?.addListener(_onAttention);
    }
  }

  @override
  void dispose() {
    widget.settings.removeListener(_onSettings);
    widget.attention?.removeListener(_onAttention);
    _motion.dispose();
    _snapshots.dispose();
    super.dispose();
  }

  double _painted(double opacity) =>
      _snapshots.allowSnapshotting ? math.max(opacity, _paintOpacity) : opacity;

  void _startWhenPainted(void Function() start) {
    final turn = ++_preparing;
    final binding = WidgetsBinding.instance;
    binding.addPostFrameCallback((_) {
      if (!mounted || turn != _preparing) return;
      binding.addPostFrameCallback((_) {
        if (mounted && turn == _preparing) start();
      });
      binding.scheduleFrame();
    });
  }

  void _onStatus(AnimationStatus status) {
    if (status.isAnimating) return;
    _snapshots.allowSnapshotting = false;
    if (status != AnimationStatus.dismissed) return;
    widget.settings.exitFinished();
    _restoreFocus();
  }

  void _restoreFocus() {
    final node = _returnFocus;
    _returnFocus = null;
    if (node == null || _closedByAttention) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || widget.settings.isOpen) return;
      if (node.context != null && node.canRequestFocus) node.requestFocus();
    });
  }

  void _onSettings() {
    final settings = widget.settings;
    if (settings.isOpen && !_wasOpen) {
      _wasOpen = true;
      _closedByAttention = false;
      if (_returnFocus == null) {
        final focused = FocusManager.instance.primaryFocus;
        _returnFocus = focused is FocusScopeNode ? null : focused;
      }
      _preparing++;
      if (_reduceMotion) {
        _motion.value = 1;
      } else if (_motion.isCompleted) {
        _snapshots.allowSnapshotting = false;
      } else if (_motion.isAnimating) {
        _motion.forward();
      } else {
        _snapshots.allowSnapshotting = true;
        _startWhenPainted(_motion.forward);
      }
    } else if (!settings.isOpen && _wasOpen) {
      _wasOpen = false;
      _preparing++;
      if (_motion.isDismissed) {
        _onStatus(AnimationStatus.dismissed);
      } else if (settings.instant || _reduceMotion) {
        _motion.value = 0;
      } else if (_motion.isAnimating) {
        _motion.reverse();
      } else {
        _snapshots.allowSnapshotting = true;
        _startWhenPainted(_motion.reverse);
      }
    }
  }

  void _onAttention() {
    final settings = widget.settings;
    if (!settings.isOpen) return;
    _closedByAttention = true;
    final lifecycle = WidgetsBinding.instance.lifecycleState;
    final hidden =
        lifecycle == AppLifecycleState.hidden ||
        lifecycle == AppLifecycleState.paused;
    settings.close(instant: hidden);
  }

  @override
  Widget build(BuildContext context) {
    final settings = widget.settings;
    return Stack(
      children: [
        Positioned.fill(
          child: ListenableBuilder(
            listenable: Listenable.merge([settings, _motion, _snapshots]),
            builder: (context, child) {
              final phase = _Phase.of(_motion);
              return ExcludeFocus(
                excluding: settings.isOpen,
                child: IgnorePointer(
                  ignoring: settings.isOpen,
                  child: TickerMode(
                    enabled: !settings.isOpen && _motion.isDismissed,
                    child: Opacity(
                      opacity: _painted(phase.mainOpacity),
                      child: Transform.translate(
                        offset: Offset(-_mainShift * phase.away, 0),
                        child: child,
                      ),
                    ),
                  ),
                ),
              );
            },
            child: RepaintBoundary(
              child: SnapshotWidget(
                controller: _snapshots,
                mode: SnapshotMode.permissive,
                child: widget.child,
              ),
            ),
          ),
        ),
        ListenableBuilder(
          listenable: settings,
          builder: (context, _) {
            if (!settings.isOpen && !settings.closing) {
              return const SizedBox.shrink();
            }
            return Positioned.fill(
              child: AnimatedBuilder(
                animation: Listenable.merge([_motion, _snapshots]),
                builder: (context, child) {
                  final phase = _Phase.of(_motion);
                  return Opacity(
                    opacity: _painted(phase.screenOpacity),
                    child: Transform.translate(
                      offset: Offset(phase.screenShift, 0),
                      child: child,
                    ),
                  );
                },
                child: RepaintBoundary(
                  child: SnapshotWidget(
                    controller: _snapshots,
                    mode: SnapshotMode.permissive,
                    child: SettingsScreen(
                      controller: widget.controller,
                      settings: settings,
                    ),
                  ),
                ),
              ),
            );
          },
        ),
      ],
    );
  }
}
