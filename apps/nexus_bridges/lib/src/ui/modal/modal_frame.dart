import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';

import '../icons/glyphs.dart';
import '../theme/app_theme.dart';
import '../theme/tokens.dart';

const Size modalSize = Size(400, 488);
const double modalRadius = 20;
const EdgeInsets modalPadding = EdgeInsets.fromLTRB(28, 28, 28, 34);
const double modalScrimPadding = 16;
const Duration modalTransitionDuration = Duration(milliseconds: 320);
const Duration modalViewInDuration = Duration(milliseconds: 360);
const Duration modalViewInDelay = Duration(milliseconds: 50);
const Duration modalViewOutDuration = Duration(milliseconds: 180);

const Cubic _labEaseOut = Cubic(0.23, 1, 0.32, 1);
const String _slot = '\u{E000}';

final class _FrameFocusScope extends InheritedWidget {
  const _FrameFocusScope({required this.node, required super.child});

  final FocusNode node;

  @override
  bool updateShouldNotify(_FrameFocusScope oldWidget) => node != oldWidget.node;
}

class NbModal extends StatelessWidget {
  const NbModal({required this.child, super.key});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final colors = NbColors.of(context);
    final radius = BorderRadius.circular(modalRadius);
    return Semantics(
      scopesRoute: true,
      explicitChildNodes: true,
      child: Padding(
        padding: const EdgeInsets.all(modalScrimPadding),
        child: LayoutBuilder(
          builder: (context, constraints) {
            return Center(
              child: SizedBox(
                width: math.min(modalSize.width, constraints.maxWidth),
                height: math.min(modalSize.height, constraints.maxHeight),
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  excludeFromSemantics: true,
                  onTap: () {},
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      color: colors.card,
                      borderRadius: radius,
                      boxShadow: colors.popoverShadow,
                    ),
                    child: ClipRRect(
                      borderRadius: radius,
                      child: Material(
                        type: MaterialType.transparency,
                        child: child,
                      ),
                    ),
                  ),
                ),
              ),
            );
          },
        ),
      ),
    );
  }
}

class NbModalRoute<T> extends RawDialogRoute<T> {
  NbModalRoute({
    required BuildContext context,
    required WidgetBuilder builder,
    VoidCallback? Function()? onDismiss,
  }) : this._(
         scrim: NbColors.of(context).scrim,
         reduceMotion: MediaQuery.disableAnimationsOf(context),
         builder: builder,
         onDismiss: onDismiss,
       );

  NbModalRoute._({
    required Color scrim,
    required bool reduceMotion,
    required WidgetBuilder builder,
    required VoidCallback? Function()? onDismiss,
  }) : super(
         barrierDismissible: false,
         barrierColor: scrim,
         transitionDuration: reduceMotion
             ? Duration.zero
             : modalTransitionDuration,
         transitionBuilder: (context, animation, secondaryAnimation, child) =>
             child,
         pageBuilder: (context, animation, secondaryAnimation) => _ModalPage(
           animation: animation,
           builder: builder,
           onDismiss: onDismiss,
         ),
       );
}

class _ModalPage extends StatefulWidget {
  const _ModalPage({
    required this.animation,
    required this.builder,
    required this.onDismiss,
  });

  final Animation<double> animation;
  final WidgetBuilder builder;
  final VoidCallback? Function()? onDismiss;

  @override
  State<_ModalPage> createState() => _ModalPageState();
}

class _ModalPageState extends State<_ModalPage> {
  final FocusNode _frameFocus = FocusNode(debugLabel: 'NbModalFrame');

  @override
  void dispose() {
    _frameFocus.dispose();
    super.dispose();
  }

  void _dismiss() {
    widget.onDismiss?.call()?.call();
  }

  @override
  Widget build(BuildContext context) {
    return _FrameFocusScope(
      node: _frameFocus,
      child: CallbackShortcuts(
        bindings: {const SingleActivator(LogicalKeyboardKey.escape): _dismiss},
        child: Focus(
          autofocus: true,
          focusNode: _frameFocus,
          child: Stack(
            fit: StackFit.expand,
            children: [
              Positioned.fill(
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  excludeFromSemantics: true,
                  onTap: _dismiss,
                ),
              ),
              _Entrance(
                animation: widget.animation,
                child: NbModal(child: Builder(builder: widget.builder)),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Entrance extends StatelessWidget {
  const _Entrance({required this.animation, required this.child});

  final Animation<double> animation;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final eased = animation.drive(CurveTween(curve: _labEaseOut));
    return FadeTransition(
      opacity: eased,
      child: ScaleTransition(
        scale: eased.drive(Tween<double>(begin: 0.96, end: 1)),
        child: AnimatedBuilder(
          animation: eased,
          child: child,
          builder: (context, child) => Transform.translate(
            offset: Offset(0, 10 * (1 - eased.value)),
            child: child,
          ),
        ),
      ),
    );
  }
}

enum ModalViewLayout { standard, centered, result, titleFirst }

class ModalView extends StatelessWidget {
  const ModalView({
    required this.title,
    this.layout = ModalViewLayout.standard,
    this.stage,
    this.eyebrow,
    this.body = const [],
    this.pair = const [],
    this.actions = const [],
    super.key,
  });

  final ModalViewLayout layout;
  final Widget? stage;
  final ModalEyebrow? eyebrow;
  final String title;
  final List<Widget> body;
  final List<Widget> pair;
  final List<Widget> actions;

  @override
  Widget build(BuildContext context) {
    final colors = NbColors.of(context);
    final centered = layout == ModalViewLayout.centered;
    final titleFirst = layout == ModalViewLayout.titleFirst;
    final (
      double fontSize,
      double lineHeight,
      double maxWidth,
    ) = switch (layout) {
      ModalViewLayout.standard || ModalViewLayout.centered => (19, 25, 330),
      ModalViewLayout.result => (21, 28, 320),
      ModalViewLayout.titleFirst => (22, 28, 330),
    };
    final titleWidget = Semantics(
      header: true,
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: maxWidth),
        child: Text(
          title,
          textAlign: TextAlign.center,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: NbText.title.copyWith(
            fontSize: fontSize,
            height: lineHeight / fontSize,
            letterSpacing: -0.012 * fontSize,
            color: colors.text,
            fontVariations: [FontVariation.weight(colors.headingWeight)],
          ),
        ),
      ),
    );
    final stage = this.stage;
    final topChildren = <Widget>[
      if (!titleFirst && stage != null) stage,
      titleWidget,
      ...body,
      if (titleFirst && stage != null) stage,
    ];
    final zone = ScrollConfiguration(
      behavior: ScrollConfiguration.of(context).copyWith(scrollbars: false),
      child: LayoutBuilder(
        builder: (context, constraints) {
          return SingleChildScrollView(
            primary: false,
            child: ConstrainedBox(
              constraints: BoxConstraints(
                minWidth: constraints.maxWidth,
                minHeight: centered ? 0 : constraints.maxHeight,
              ),
              child: Padding(
                padding: EdgeInsets.only(top: titleFirst ? 16 : 0),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  mainAxisAlignment: titleFirst
                      ? MainAxisAlignment.start
                      : MainAxisAlignment.center,
                  children: topChildren,
                ),
              ),
            ),
          );
        },
      ),
    );
    final buttons = <Widget>[
      if (pair.isNotEmpty)
        IntrinsicHeight(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              for (var i = 0; i < pair.length; i++) ...[
                if (i > 0) const SizedBox(width: 10),
                Expanded(child: pair[i]),
              ],
            ],
          ),
        ),
      for (var i = 0; i < actions.length; i++) ...[
        if (pair.isNotEmpty || i > 0) const SizedBox(height: 10),
        actions[i],
      ],
    ];
    final eyebrow = this.eyebrow;
    return Semantics(
      namesRoute: true,
      label: title,
      explicitChildNodes: true,
      child: Stack(
        fit: StackFit.expand,
        children: [
          Padding(
            padding: modalPadding,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              mainAxisAlignment: centered
                  ? MainAxisAlignment.center
                  : MainAxisAlignment.start,
              children: [
                if (centered) Flexible(child: zone) else Expanded(child: zone),
                if (buttons.isNotEmpty)
                  SizedBox(height: titleFirst ? 28 : (centered ? 20 : 16)),
                ...buttons,
              ],
            ),
          ),
          if (eyebrow != null)
            Positioned(top: 36, left: 0, right: 0, child: eyebrow),
        ],
      ),
    );
  }
}

enum EyebrowTone { ok, bad, warn, ice, neutral }

class ModalEyebrow extends StatefulWidget {
  const ModalEyebrow({
    required this.text,
    required this.tone,
    this.delay,
    super.key,
  });

  final String text;
  final EyebrowTone tone;
  final Duration? delay;

  @override
  State<ModalEyebrow> createState() => _ModalEyebrowState();
}

class _ModalEyebrowState extends State<ModalEyebrow>
    with SingleTickerProviderStateMixin {
  static const Duration _fade = Duration(milliseconds: 400);

  late final Duration _delay =
      widget.delay ??
      Duration(milliseconds: widget.tone == EyebrowTone.ok ? 900 : 250);
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: _delay + _fade,
  );
  late final Animation<double> _progress = _controller.drive(
    CurveTween(
      curve: Interval(
        _delay.inMilliseconds / (_delay + _fade).inMilliseconds,
        1,
        curve: _labEaseOut,
      ),
    ),
  );
  bool _started = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (MediaQuery.disableAnimationsOf(context)) {
      _controller.value = 1;
    } else if (!_started) {
      _started = true;
      _controller.forward();
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = NbColors.of(context);
    final ink = switch (widget.tone) {
      EyebrowTone.ok => colors.successInk,
      EyebrowTone.bad => colors.danger,
      EyebrowTone.warn => colors.warning,
      EyebrowTone.ice => colors.ice,
      EyebrowTone.neutral => colors.textWeak,
    };
    return Semantics(
      label: widget.text,
      child: ExcludeSemantics(
        child: FadeTransition(
          opacity: _progress,
          child: ScaleTransition(
            scale: _progress.drive(Tween<double>(begin: 0.9, end: 1)),
            child: Text(
              widget.text.toUpperCase(),
              textAlign: TextAlign.center,
              style: NbText.label.copyWith(
                fontSize: 11.5,
                fontWeight: FontWeight.w700,
                height: 16 / 11.5,
                letterSpacing: 1.725,
                color: ink,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

TextSpan emphasized(
  String Function(String part) build,
  String part, {
  required TextStyle base,
  required TextStyle strong,
}) {
  final pieces = build(_slot).split(_slot);
  if (pieces.length == 2) {
    return TextSpan(
      style: base,
      children: [
        TextSpan(text: pieces[0]),
        TextSpan(text: part, style: strong),
        TextSpan(text: pieces[1]),
      ],
    );
  }
  return TextSpan(style: base, text: build(part));
}

class ModalLead extends StatelessWidget {
  const ModalLead({required String this.text, this.tight = false, super.key})
    : _build = null,
      strong = null;

  const ModalLead.rich({
    required String Function(String part) this._build,
    required String this.strong,
    this.tight = false,
    super.key,
  }) : text = null;

  final String? text;
  final String Function(String part)? _build;
  final String? strong;
  final bool tight;

  @override
  Widget build(BuildContext context) {
    final colors = NbColors.of(context);
    final style = NbText.body.copyWith(
      fontSize: tight ? 13 : 14,
      height: tight ? 18 / 13 : 20 / 14,
      color: colors.textWeak,
    );
    final text = this.text;
    final template = _build;
    final strong = this.strong;
    final Widget content;
    if (text != null) {
      content = Text(text, textAlign: TextAlign.center, style: style);
    } else {
      content = Text.rich(
        emphasized(
          template!,
          strong!,
          base: style,
          strong: style.copyWith(
            color: colors.text,
            fontWeight: FontWeight.w600,
          ),
        ),
        textAlign: TextAlign.center,
      );
    }
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 320),
        child: content,
      ),
    );
  }
}

class ModalAlert extends StatelessWidget {
  const ModalAlert({required this.text, super.key});

  final String text;

  @override
  Widget build(BuildContext context) {
    final colors = NbColors.of(context);
    return Padding(
      padding: const EdgeInsets.only(top: 12),
      child: SizedBox(
        width: double.infinity,
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: colors.dangerWeak,
            borderRadius: BorderRadius.circular(12),
          ),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: const EdgeInsets.only(top: 1),
                  child: GlyphIcon(Glyphs.warn, size: 16, color: colors.danger),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    text,
                    textAlign: TextAlign.start,
                    style: NbText.label.copyWith(
                      fontSize: 12.5,
                      height: 17 / 12.5,
                      color: colors.danger,
                    ),
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

class ModalNote extends StatelessWidget {
  const ModalNote({required this.text, super.key});

  final String text;

  @override
  Widget build(BuildContext context) {
    final colors = NbColors.of(context);
    return Padding(
      padding: const EdgeInsets.only(top: 12),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          GlyphIcon(Glyphs.check, size: 13, color: colors.successInk),
          const SizedBox(width: 6),
          Flexible(
            child: Text(
              text,
              textAlign: TextAlign.center,
              style: NbText.body.copyWith(
                fontSize: 12,
                height: 16 / 12,
                color: colors.textWeak,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class ModalViewSwitcher extends StatefulWidget {
  const ModalViewSwitcher({
    required this.viewKey,
    required this.child,
    super.key,
  });

  final Object viewKey;
  final Widget child;

  static FocusNode? frameFocusOf(BuildContext context) {
    return context.getInheritedWidgetOfExactType<_FrameFocusScope>()?.node;
  }

  @override
  State<ModalViewSwitcher> createState() => _ModalViewSwitcherState();
}

final Duration _enterTotal = modalViewInDelay + modalViewInDuration;
final Interval _enterCurve = Interval(
  modalViewInDelay.inMilliseconds / _enterTotal.inMilliseconds,
  1,
  curve: _labEaseOut,
);

final class _ViewEntry {
  _ViewEntry({required this.key, required this.child});

  final Object key;
  Widget child;
  bool leaving = false;
  AnimationController? entering;
  AnimationController? exiting;

  double get enterProgress {
    final controller = entering;
    return controller == null ? 1 : _enterCurve.transform(controller.value);
  }

  double get exitProgress {
    final controller = exiting;
    return controller == null ? 0 : _labEaseOut.transform(controller.value);
  }

  Listenable get listenable => Listenable.merge([?entering, ?exiting]);
}

class _ModalViewSwitcherState extends State<ModalViewSwitcher>
    with TickerProviderStateMixin {
  late _ViewEntry _current = _ViewEntry(
    key: widget.viewKey,
    child: widget.child,
  );
  final List<_ViewEntry> _leaving = [];
  final List<AnimationController> _retired = [];

  void _retire(AnimationController? controller) {
    if (controller == null) return;
    _retired.add(controller);
    SchedulerBinding.instance.addPostFrameCallback((_) {
      if (_retired.remove(controller)) controller.dispose();
    });
  }

  void _release(_ViewEntry entry) {
    _retire(entry.entering);
    _retire(entry.exiting);
    entry.entering = null;
    entry.exiting = null;
  }

  @override
  void didUpdateWidget(ModalViewSwitcher oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.viewKey == _current.key) {
      _current.child = widget.child;
      return;
    }
    final reduce = MediaQuery.disableAnimationsOf(context);
    final previous = _current;
    final stale = _leaving.where((e) => e.key == widget.viewKey).toList();
    for (final entry in stale) {
      _leaving.remove(entry);
      _release(entry);
    }
    _current = _ViewEntry(key: widget.viewKey, child: widget.child);
    if (reduce) {
      _release(previous);
      for (final entry in _leaving) {
        _release(entry);
      }
      _leaving.clear();
    } else {
      _startEntering(_current);
      _startLeaving(previous);
    }
    _returnFocusToFrame(_current);
  }

  void _startEntering(_ViewEntry entry) {
    final controller = AnimationController(vsync: this, duration: _enterTotal);
    entry.entering = controller;
    controller.addStatusListener((status) {
      if (status == AnimationStatus.completed && mounted) {
        setState(() {
          if (entry.entering == controller) {
            entry.entering = null;
            _retire(controller);
          }
        });
      }
    });
    controller.forward();
  }

  void _startLeaving(_ViewEntry entry) {
    final controller = AnimationController(
      vsync: this,
      duration: modalViewOutDuration,
    );
    entry.leaving = true;
    entry.exiting = controller;
    _leaving.add(entry);
    controller.addStatusListener((status) {
      if (status == AnimationStatus.completed && mounted) {
        setState(() {
          _leaving.remove(entry);
          _release(entry);
        });
      }
    });
    controller.forward();
  }

  void _returnFocusToFrame(_ViewEntry entry) {
    SchedulerBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final frame = ModalViewSwitcher.frameFocusOf(context);
      if (frame == null) return;
      if (ModalRoute.of(context)?.isCurrent == false) return;
      final focus = FocusManager.instance.primaryFocus;
      if (focus == null || !_isInside(focus, entry)) frame.requestFocus();
    });
  }

  bool _isInside(FocusNode focus, _ViewEntry entry) {
    final context = focus.context;
    if (context == null) return false;
    final target = ObjectKey(entry);
    var found = false;
    context.visitAncestorElements((element) {
      if (element.widget.key == target) {
        found = true;
        return false;
      }
      return true;
    });
    return found;
  }

  @override
  void dispose() {
    for (final entry in [..._leaving, _current]) {
      entry.entering?.dispose();
      entry.exiting?.dispose();
    }
    for (final controller in _retired) {
      controller.dispose();
    }
    _retired.clear();
    super.dispose();
  }

  Widget _slotOf(_ViewEntry entry) {
    final leaving = entry.leaving;
    return KeyedSubtree(
      key: ObjectKey(entry),
      child: KeyedSubtree(
        key: ValueKey<Object>(entry.key),
        child: AnimatedBuilder(
          animation: entry.listenable,
          child: ExcludeSemantics(
            excluding: leaving,
            child: ExcludeFocus(
              excluding: leaving,
              child: IgnorePointer(ignoring: leaving, child: entry.child),
            ),
          ),
          builder: (context, child) {
            final entered = entry.enterProgress;
            final exited = entry.exitProgress;
            final blur = 3 * (1 - entered) + 3 * exited;
            return ImageFiltered(
              enabled: blur > 0.01,
              imageFilter: ui.ImageFilter.blur(sigmaX: blur, sigmaY: blur),
              child: Opacity(
                opacity: (entered * (1 - exited)).clamp(0.0, 1.0),
                child: Transform.translate(
                  offset: Offset(0, 10 * (1 - entered) - 6 * exited),
                  child: child,
                ),
              ),
            );
          },
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      fit: StackFit.expand,
      children: [
        for (final entry in _leaving) _slotOf(entry),
        _slotOf(_current),
      ],
    );
  }
}
