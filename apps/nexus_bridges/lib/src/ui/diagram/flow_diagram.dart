import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:nexus_bridges_core/nexus_bridges_core.dart';

import '../../l10n/app_strings.dart';
import '../device_list.dart' show discToneFor;
import '../icons/device_disc.dart';
import '../send_menu.dart';
import '../theme/app_theme.dart';
import '../theme/components.dart';
import '../theme/tokens.dart';
import 'flow_layout.dart';
import 'flow_painter.dart';
import 'flow_scene.dart';

const Duration _clockPeriod = Duration(milliseconds: 14400);
const Duration _hoverDuration = Duration(milliseconds: 200);
const Duration _popoverDuration = Duration(milliseconds: 240);
const Duration _doneDuration = Duration(milliseconds: 3200);
const Cubic _motionCurve = Cubic(0.2, 0.8, 0.2, 1);
const double _popoverWidth = 264;
const double _hitExtra = 6;
const int _shortLength = 8;

String _shortOf(String fingerprint) =>
    fingerprint.substring(0, math.min(_shortLength, fingerprint.length));

DeviceEntry? _pairedEntry(NodeState state, String? fingerprint) {
  if (fingerprint == null) return null;
  for (final entry in state.entries) {
    if (entry.paired && entry.fingerprint == fingerprint) return entry;
  }
  return null;
}

class FlowDiagram extends StatefulWidget {
  const FlowDiagram({
    required this.state,
    required this.hovered,
    required this.onSendFiles,
    required this.onSendFolders,
    required this.onShowDevices,
    super.key,
  });

  final NodeState state;
  final ValueNotifier<String?> hovered;
  final void Function(String fingerprint) onSendFiles;
  final void Function(String fingerprint) onSendFolders;
  final VoidCallback onShowDevices;

  @override
  State<FlowDiagram> createState() => _FlowDiagramState();
}

class _FlowDiagramState extends State<FlowDiagram>
    with TickerProviderStateMixin {
  late final AnimationController _clock;
  late final AnimationController _hover;
  late final CurvedAnimation _hoverCurve;
  Timer? _doneTimer;
  String? _done;
  String? _popoverFor;
  String? _shownHover;
  NodeState? _previous;
  bool _reduceMotion = false;

  @override
  void initState() {
    super.initState();
    _clock = AnimationController(vsync: this, duration: _clockPeriod);
    _hover = AnimationController(vsync: this, duration: _hoverDuration);
    _hoverCurve = CurvedAnimation(parent: _hover, curve: _motionCurve);
    _hover.addStatusListener(_onHoverStatus);
    widget.hovered.addListener(_onHovered);
    _previous = widget.state;
    _shownHover = widget.hovered.value;
    if (_shownHover != null) _hover.value = 1;
  }

  @override
  void didUpdateWidget(FlowDiagram oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.hovered, widget.hovered)) {
      oldWidget.hovered.removeListener(_onHovered);
      widget.hovered.addListener(_onHovered);
      _onHovered();
    }
    final finished = newlyDone(_previous, widget.state);
    _previous = widget.state;
    if (finished != null) {
      _doneTimer?.cancel();
      _done = finished;
      _doneTimer = Timer(_doneDuration, () {
        if (!mounted) return;
        setState(() => _done = null);
      });
    }
    if (_popoverFor != null &&
        _pairedEntry(widget.state, _popoverFor) == null) {
      _popoverFor = null;
    }
  }

  @override
  void dispose() {
    _doneTimer?.cancel();
    widget.hovered.removeListener(_onHovered);
    _hover.removeStatusListener(_onHoverStatus);
    _hoverCurve.dispose();
    _hover.dispose();
    _clock.dispose();
    super.dispose();
  }

  void _onHovered() {
    final fingerprint = widget.hovered.value;
    if (fingerprint != null) {
      if (_shownHover != fingerprint) setState(() => _shownHover = fingerprint);
      if (_reduceMotion) {
        _hover.value = 1;
      } else {
        _hover.forward(from: 0);
      }
      return;
    }
    if (_reduceMotion) {
      _hover.value = 0;
      if (_shownHover != null) setState(() => _shownHover = null);
    } else {
      _hover.reverse();
    }
  }

  void _onHoverStatus(AnimationStatus status) {
    if (status == AnimationStatus.dismissed &&
        widget.hovered.value == null &&
        _shownHover != null &&
        mounted) {
      setState(() => _shownHover = null);
    }
  }

  void _closePopover() {
    if (_popoverFor != null) setState(() => _popoverFor = null);
  }

  void _syncClock(bool animates) {
    if (animates && !_reduceMotion) {
      if (!_clock.isAnimating) _clock.repeat();
    } else if (_clock.isAnimating) {
      _clock.stop();
    }
  }

  @override
  Widget build(BuildContext context) {
    final strings = AppStringsDelegate.of(context);
    final colors = NbColors.of(context);
    final textDirection = Directionality.of(context);
    _reduceMotion = MediaQuery.disableAnimationsOf(context);

    return LayoutBuilder(
      builder: (context, constraints) {
        final scene = buildFlowScene(
          state: widget.state,
          strings: strings,
          size: constraints.biggest,
          doneFingerprint: _done,
          hovered: _shownHover,
        );
        _syncClock(scene.animates);
        final layout = scene.layout;
        final hitRadius = layout.peerRadius + _hitExtra;

        final zones = <Widget>[];
        for (var i = 0; i < scene.peers.length; i++) {
          final peer = scene.peers[i];
          zones.add(
            Positioned.fromRect(
              key: ValueKey('flow-peer-${peer.fingerprint}'),
              rect: Rect.fromCircle(
                center: layout.slots[i].center,
                radius: hitRadius,
              ),
              child: Semantics(
                button: true,
                label: peer.name,
                child: MouseRegion(
                  cursor: SystemMouseCursors.click,
                  onEnter: (_) => widget.hovered.value = peer.fingerprint,
                  onExit: (_) {
                    if (widget.hovered.value == peer.fingerprint) {
                      widget.hovered.value = null;
                    }
                  },
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: () => setState(() => _popoverFor = peer.fingerprint),
                  ),
                ),
              ),
            ),
          );
        }
        for (final slot in layout.slots) {
          if (!slot.overflow) continue;
          zones.add(
            Positioned.fromRect(
              key: const ValueKey('flow-more'),
              rect: Rect.fromCircle(center: slot.center, radius: hitRadius),
              child: Semantics(
                button: true,
                label: scene.overflowLabel,
                child: MouseRegion(
                  cursor: SystemMouseCursors.click,
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: widget.onShowDevices,
                  ),
                ),
              ),
            ),
          );
        }

        final popover = _popover(scene, strings);

        return ClipRect(
          child: Stack(
            fit: StackFit.expand,
            children: [
              RepaintBoundary(
                child: CustomPaint(
                  size: Size.infinite,
                  painter: FlowBackgroundPainter(
                    layout: layout,
                    colors: colors,
                  ),
                ),
              ),
              RepaintBoundary(
                child: CustomPaint(
                  size: Size.infinite,
                  foregroundPainter: FlowPainter(
                    scene: scene,
                    colors: colors,
                    clock: _clock,
                    hover: _hoverCurve,
                    reduceMotion: _reduceMotion,
                    textDirection: textDirection,
                  ),
                ),
              ),
              ...zones,
              ...popover,
            ],
          ),
        );
      },
    );
  }

  List<Widget> _popover(FlowScene scene, AppStrings strings) {
    final fingerprint = _popoverFor;
    final entry = _pairedEntry(widget.state, fingerprint);
    if (fingerprint == null || entry == null) return const [];
    final index = scene.peers.indexWhere((p) => p.fingerprint == fingerprint);
    if (index < 0) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _popoverFor == fingerprint) _closePopover();
      });
      return const [];
    }
    final slot = scene.layout.slots[index];
    return [
      Positioned.fill(
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: _closePopover,
        ),
      ),
      Positioned.fill(
        child: CallbackShortcuts(
          bindings: {
            const SingleActivator(LogicalKeyboardKey.escape): _closePopover,
          },
          child: Focus(
            autofocus: true,
            child: _PopoverLayer(
              anchor: slot.center,
              radius: scene.layout.peerRadius,
              reduceMotion: _reduceMotion,
              child: _FlowPopover(
                entry: entry,
                state: widget.state,
                tone: discToneFor(widget.state, entry),
                onFiles: () {
                  _closePopover();
                  widget.onSendFiles(entry.fingerprint);
                },
                onFolders: () {
                  _closePopover();
                  widget.onSendFolders(entry.fingerprint);
                },
              ),
            ),
          ),
        ),
      ),
    ];
  }
}

class _PopoverDelegate extends SingleChildLayoutDelegate {
  const _PopoverDelegate({required this.center, required this.radius});

  final Offset center;
  final double radius;

  @override
  BoxConstraints getConstraintsForChild(BoxConstraints constraints) =>
      constraints.loosen();

  @override
  Offset getPositionForChild(Size size, Size childSize) => placePopover(
    area: size,
    center: center,
    radius: radius,
    popover: childSize,
  );

  @override
  bool shouldRelayout(_PopoverDelegate oldDelegate) =>
      oldDelegate.center != center || oldDelegate.radius != radius;
}

class _PopoverLayer extends StatefulWidget {
  const _PopoverLayer({
    required this.anchor,
    required this.radius,
    required this.reduceMotion,
    required this.child,
  });

  final Offset anchor;
  final double radius;
  final bool reduceMotion;
  final Widget child;

  @override
  State<_PopoverLayer> createState() => _PopoverLayerState();
}

class _PopoverLayerState extends State<_PopoverLayer>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  late final CurvedAnimation _curve;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(vsync: this, duration: _popoverDuration);
    _curve = CurvedAnimation(parent: _controller, curve: _motionCurve);
    if (widget.reduceMotion) {
      _controller.value = 1;
    } else {
      _controller.forward();
    }
  }

  @override
  void dispose() {
    _curve.dispose();
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, box) {
        final alignment = Alignment(
          box.maxWidth > 0 ? 2 * widget.anchor.dx / box.maxWidth - 1 : 0,
          box.maxHeight > 0 ? 2 * widget.anchor.dy / box.maxHeight - 1 : 0,
        );
        return FadeTransition(
          opacity: _curve,
          child: ScaleTransition(
            scale: Tween<double>(begin: 0.5, end: 1).animate(_curve),
            alignment: alignment,
            child: CustomSingleChildLayout(
              delegate: _PopoverDelegate(
                center: widget.anchor,
                radius: widget.radius,
              ),
              child: widget.child,
            ),
          ),
        );
      },
    );
  }
}

class _FlowPopover extends StatelessWidget {
  const _FlowPopover({
    required this.entry,
    required this.state,
    required this.tone,
    required this.onFiles,
    required this.onFolders,
  });

  final DeviceEntry entry;
  final NodeState state;
  final DiscTone tone;
  final VoidCallback onFiles;
  final VoidCallback onFolders;

  @override
  Widget build(BuildContext context) {
    final strings = AppStringsDelegate.of(context);
    final colors = NbColors.of(context);
    final radius = BorderRadius.circular(12);
    final caption = NbText.caption.copyWith(color: colors.textWeak);
    final explanation = sendExplanation(strings, state, entry);

    return SizedBox(
      width: _popoverWidth,
      child: DecoratedBox(
        decoration: BoxDecoration(
          borderRadius: radius,
          boxShadow: colors.popoverShadow,
        ),
        child: Card(
          clipBehavior: Clip.antiAlias,
          margin: EdgeInsets.zero,
          shape: RoundedRectangleBorder(borderRadius: radius),
          child: Padding(
            padding: const EdgeInsets.all(10),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    DeviceDisc(type: entry.deviceType, size: 32, tone: tone),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            entry.displayName,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: NbText.bodyStrong.copyWith(
                              color: colors.text,
                            ),
                          ),
                          const SizedBox(height: 3),
                          Wrap(
                            spacing: 8,
                            runSpacing: 2,
                            crossAxisAlignment: WrapCrossAlignment.center,
                            children: [
                              StatusChip(
                                height: 20,
                                label: entry.mine
                                    ? strings.chipMine
                                    : strings.chipForeign,
                                tone: entry.mine
                                    ? ChipTone.run
                                    : ChipTone.foreign,
                              ),
                              Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Container(
                                    width: 6,
                                    height: 6,
                                    decoration: BoxDecoration(
                                      shape: BoxShape.circle,
                                      color: entry.visible
                                          ? colors.successInk
                                          : colors.hint,
                                    ),
                                  ),
                                  const SizedBox(width: 4),
                                  Flexible(
                                    child: Text(
                                      entry.visible
                                          ? strings.visibleLabel
                                          : strings.notVisibleLabel,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: caption,
                                    ),
                                  ),
                                ],
                              ),
                            ],
                          ),
                          const SizedBox(height: 2),
                          Text(
                            strings.fingerprintLine(
                              _shortOf(entry.fingerprint),
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: caption,
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
                if (explanation != null) ...[
                  const SizedBox(height: 8),
                  Text(explanation, style: caption),
                ],
                const SizedBox(height: 10),
                SizedBox(
                  width: double.infinity,
                  child: SendMenuButton(
                    enabled: state.canSendTo(entry.fingerprint),
                    height: 32,
                    onFiles: onFiles,
                    onFolders: onFolders,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
