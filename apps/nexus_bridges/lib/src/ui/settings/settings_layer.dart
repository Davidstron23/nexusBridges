import 'dart:ui' show ImageFilter;

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
const double _mainScale = 0.015;
const double _mainBlur = 2;
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
    super.dispose();
  }

  void _onStatus(AnimationStatus status) {
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
      if (_reduceMotion) {
        _motion.value = 1;
      } else {
        _motion.forward();
      }
    } else if (!settings.isOpen && _wasOpen) {
      _wasOpen = false;
      if (settings.instant || _reduceMotion) {
        _motion.value = 0;
      } else {
        _motion.reverse();
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
            listenable: Listenable.merge([settings, _motion]),
            builder: (context, child) {
              final phase = _Phase.of(_motion);
              final blur = _mainBlur * phase.away;
              return ExcludeFocus(
                excluding: settings.isOpen,
                child: IgnorePointer(
                  ignoring: settings.isOpen,
                  child: TickerMode(
                    enabled: !(settings.isOpen && _motion.isCompleted),
                    child: Opacity(
                      opacity: phase.mainOpacity,
                      child: Transform(
                        alignment: Alignment.center,
                        transform: Matrix4.identity()
                          ..translateByDouble(-_mainShift * phase.away, 0, 0, 1)
                          ..scaleByDouble(
                            1 - _mainScale * phase.away,
                            1 - _mainScale * phase.away,
                            1,
                            1,
                          ),
                        child: ImageFiltered(
                          enabled: blur > 0.05,
                          imageFilter: ImageFilter.blur(
                            sigmaX: blur,
                            sigmaY: blur,
                          ),
                          child: child,
                        ),
                      ),
                    ),
                  ),
                ),
              );
            },
            child: widget.child,
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
                animation: _motion,
                builder: (context, child) {
                  final phase = _Phase.of(_motion);
                  return Opacity(
                    opacity: phase.screenOpacity,
                    child: Transform.translate(
                      offset: Offset(phase.screenShift, 0),
                      child: child,
                    ),
                  );
                },
                child: SettingsScreen(
                  controller: widget.controller,
                  settings: settings,
                ),
              ),
            );
          },
        ),
      ],
    );
  }
}
