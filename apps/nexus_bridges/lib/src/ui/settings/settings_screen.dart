import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../app_controller.dart';
import '../../l10n/app_strings.dart';
import '../icons/glyphs.dart';
import '../modal/timeline.dart';
import '../theme/app_theme.dart';
import '../theme/tokens.dart';
import 'appearance_section.dart';
import 'device_name_section.dart';
import 'exclusions_section.dart';
import 'ignored_section.dart';
import 'inline_confirm.dart';
import 'language_section.dart';
import 'networks_section.dart';
import 'receive_section.dart';
import 'settings_controller.dart';
import 'system_tray_section.dart';

const double _headerHeight = 66;
const double _headerMaxWidth = 928;
const double _sidePadding = 24;
const double _navWidth = 185;
const double _navItemHeight = 38;
const double _navGap = 2;
const double _navTop = 14;
const double _navRadius = 9;
const double _columnGap = 36;
const double _contentMaxWidth = 590;
const double _rightMargin = 170;
const double _cardGap = 14;
const double _spyLine = 120;
const double _jumpGap = 14;
const double _fadeHeight = 14;
const double _navFootPadding = 32;
const double _backSize = 34;
const Duration _indicatorSlide = Duration(milliseconds: 450);
const Duration _jumpDuration = Duration(milliseconds: 500);
const int _sectionCount = 8;

final class _Entry {
  const _Entry({required this.icon, required this.title, required this.build});

  final Glyph icon;
  final String title;
  final Widget Function() build;
}

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({
    required this.controller,
    required this.settings,
    super.key,
  });

  final AppController controller;
  final SettingsController settings;

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  final ScrollController _scroll = ScrollController();
  final GlobalKey _contentKey = GlobalKey();
  final List<GlobalKey> _keys = List.generate(
    _sectionCount,
    (_) => GlobalKey(),
  );
  final ValueNotifier<int> _active = ValueNotifier(0);
  final ConfirmRegistry _cancelConfirm = ConfirmRegistry();
  final ValueNotifier<double> _pad = ValueNotifier(0);
  bool _jumping = false;
  bool _measureQueued = false;

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_onScroll);
    _queueMeasure();
  }

  @override
  void dispose() {
    _scroll.removeListener(_onScroll);
    _scroll.dispose();
    _active.dispose();
    _pad.dispose();
    super.dispose();
  }

  void _escape() {
    final cancel = _cancelConfirm.value;
    if (cancel != null) {
      cancel();
      return;
    }
    widget.settings.close();
  }

  void _onScroll() {
    if (!_jumping) _measure();
  }

  void _queueMeasure() {
    if (_measureQueued) return;
    _measureQueued = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _measureQueued = false;
      _measure();
    });
  }

  int get _visibleSections =>
      widget.controller.systemTrayAvailable ? _sectionCount : _sectionCount - 1;

  List<double>? _tops() {
    final content = _contentKey.currentContext?.findRenderObject();
    if (content is! RenderBox || !content.attached) return null;
    final tops = <double>[];
    for (final key in _keys.take(_visibleSections)) {
      final render = key.currentContext?.findRenderObject();
      if (render is! RenderBox || !render.attached) return null;
      tops.add(render.localToGlobal(Offset.zero, ancestor: content).dy);
    }
    return tops;
  }

  bool _fitPad(List<double> tops) {
    final content =
        _contentKey.currentContext!.findRenderObject()! as RenderBox;
    final natural = math.max(
      0.0,
      content.size.height - _pad.value - _scroll.position.viewportDimension,
    );
    final needed = tops.last - (_spyLine - 16);
    final pad = math.max(0.0, (needed - natural).ceilToDouble());
    if ((pad - _pad.value).abs() <= 1) return false;
    _pad.value = pad;
    return true;
  }

  void _measure() {
    if (!mounted || !_scroll.hasClients) return;
    final tops = _tops();
    if (tops == null) return;
    final y = _scroll.offset + _spyLine;
    var current = 0;
    for (var i = 0; i < tops.length; i++) {
      if (tops[i] <= y) current = i;
    }
    if (_active.value != current) _active.value = current;
    _fitPad(tops);
  }

  void _jump(int index) {
    _active.value = index;
    final tops = _tops();
    if (tops == null || !_scroll.hasClients) return;
    if (_fitPad(tops)) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _jump(index);
      });
      return;
    }
    final target = (tops[index] - _jumpGap).clamp(
      0.0,
      _scroll.position.maxScrollExtent,
    );
    if ((target - _scroll.offset).abs() < 2) return;
    if (MediaQuery.disableAnimationsOf(context)) {
      _scroll.jumpTo(target);
      return;
    }
    _jumping = true;
    unawaited(
      _scroll
          .animateTo(target, duration: _jumpDuration, curve: labEaseOut)
          .whenComplete(() => _jumping = false),
    );
  }

  void _wheel(PointerSignalEvent event) {
    if (event is! PointerScrollEvent || !_scroll.hasClients) return;
    final position = _scroll.position;
    _scroll.jumpTo(
      (_scroll.offset + event.scrollDelta.dy).clamp(
        position.minScrollExtent,
        position.maxScrollExtent,
      ),
    );
  }

  List<_Entry> _entries(AppStrings strings) {
    final controller = widget.controller;
    return [
      _Entry(
        icon: Glyphs.monitor,
        title: strings.sectionDevice,
        build: () => DeviceNameSection(controller: controller),
      ),
      _Entry(
        icon: Glyphs.moon,
        title: strings.sectionAppearance,
        build: () => AppearanceSection(controller: controller),
      ),
      _Entry(
        icon: Glyphs.globe,
        title: strings.sectionLanguage,
        build: () => LanguageSection(controller: controller),
      ),
      _Entry(
        icon: Glyphs.inbox,
        title: strings.sectionReceive,
        build: () => ReceiveSection(controller: controller),
      ),
      _Entry(
        icon: Glyphs.folderX,
        title: strings.sectionExclusions,
        build: () => ExclusionsSection(controller: controller),
      ),
      if (controller.systemTrayAvailable)
        _Entry(
          icon: Glyphs.taskbar,
          title: strings.sectionSystemTray,
          build: () => SystemTraySection(controller: controller),
        ),
      _Entry(
        icon: Glyphs.wifi,
        title: strings.sectionNetworks,
        build: () => NetworksSection(controller: controller),
      ),
      _Entry(
        icon: Glyphs.eyeOff,
        title: strings.sectionIgnored,
        build: () => IgnoredSection(controller: controller),
      ),
    ];
  }

  @override
  Widget build(BuildContext context) {
    final colors = NbColors.of(context);
    final strings = AppStringsDelegate.of(context);
    final entries = _entries(strings);
    return ConfirmScope(
      cancel: _cancelConfirm,
      child: CallbackShortcuts(
        bindings: {const SingleActivator(LogicalKeyboardKey.escape): _escape},
        child: FocusScope(
          autofocus: true,
          child: Material(
            color: colors.ground,
            child: FocusTraversalGroup(
              policy: OrderedTraversalPolicy(),
              child: Column(
                children: [
                  FocusTraversalOrder(
                    order: const NumericFocusOrder(0),
                    child: _Header(
                      strings: strings,
                      controller: widget.controller,
                      onBack: widget.settings.close,
                    ),
                  ),
                  Expanded(
                    child: LayoutBuilder(
                      builder: (context, constraints) {
                        final inner = constraints.maxWidth - 2 * _sidePadding;
                        final contentWidth = math.max(
                          0.0,
                          math.min(
                            _contentMaxWidth,
                            inner - _navWidth - _columnGap,
                          ),
                        );
                        final contentLeft = math.max(
                          _navWidth + _columnGap,
                          inner - _rightMargin - contentWidth,
                        );
                        return Stack(
                          children: [
                            Positioned.fill(
                              child: FocusTraversalOrder(
                                order: const NumericFocusOrder(2),
                                child: FocusTraversalGroup(
                                  child: Scrollbar(
                                    controller: _scroll,
                                    child: SingleChildScrollView(
                                      controller: _scroll,
                                      child:
                                          NotificationListener<
                                            SizeChangedLayoutNotification
                                          >(
                                            onNotification: (_) {
                                              _queueMeasure();
                                              return false;
                                            },
                                            child: SizeChangedLayoutNotifier(
                                              child: _Content(
                                                key: _contentKey,
                                                left:
                                                    _sidePadding + contentLeft,
                                                width: contentWidth,
                                                pad: _pad,
                                                entries: entries,
                                                keys: _keys,
                                                footer: strings.settingsFooter,
                                              ),
                                            ),
                                          ),
                                    ),
                                  ),
                                ),
                              ),
                            ),
                            Positioned(
                              left: _sidePadding,
                              top: 0,
                              bottom: 0,
                              width: _navWidth,
                              child: FocusTraversalOrder(
                                order: const NumericFocusOrder(1),
                                child: FocusTraversalGroup(
                                  child: Listener(
                                    onPointerSignal: _wheel,
                                    child: _Nav(
                                      entries: entries,
                                      active: _active,
                                      foot: strings.settingsNavFoot,
                                      onSelect: _jump,
                                    ),
                                  ),
                                ),
                              ),
                            ),
                            const _TopFade(),
                          ],
                        );
                      },
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _TopFade extends StatelessWidget {
  const _TopFade();

  @override
  Widget build(BuildContext context) {
    final ground = NbColors.of(context).ground;
    return Positioned(
      left: 0,
      right: 0,
      top: 0,
      height: _fadeHeight,
      child: IgnorePointer(
        child: DecoratedBox(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [ground, ground.withValues(alpha: 0)],
            ),
          ),
        ),
      ),
    );
  }
}

class _Content extends StatelessWidget {
  const _Content({
    required this.left,
    required this.width,
    required this.pad,
    required this.entries,
    required this.keys,
    required this.footer,
    super.key,
  });

  final double left;
  final double width;
  final ValueListenable<double> pad;
  final List<_Entry> entries;
  final List<GlobalKey> keys;
  final String footer;

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: Alignment.topLeft,
      child: Padding(
        padding: EdgeInsets.only(left: left, top: _navTop, bottom: 32),
        child: SizedBox(
          width: width,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              for (var i = 0; i < entries.length; i++) ...[
                if (i > 0) const SizedBox(height: _cardGap),
                RepaintBoundary(key: keys[i], child: entries[i].build()),
              ],
              const SizedBox(height: 22),
              _Footer(text: footer),
              ValueListenableBuilder<double>(
                valueListenable: pad,
                builder: (context, height, _) => SizedBox(height: height),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Nav extends StatelessWidget {
  const _Nav({
    required this.entries,
    required this.active,
    required this.foot,
    required this.onSelect,
  });

  final List<_Entry> entries;
  final ValueNotifier<int> active;
  final String foot;
  final ValueChanged<int> onSelect;

  @override
  Widget build(BuildContext context) {
    final colors = NbColors.of(context);
    final animate = !MediaQuery.disableAnimationsOf(context);
    return LayoutBuilder(
      builder: (context, constraints) {
        final listHeight =
            _navTop +
            entries.length * _navItemHeight +
            (entries.length - 1) * _navGap;
        final lineHeight = MediaQuery.textScalerOf(context).scale(17);
        final room = constraints.maxHeight - listHeight - _navFootPadding;
        final lines = (room / lineHeight).floor();
        return RepaintBoundary(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.only(top: _navTop),
                child: ValueListenableBuilder<int>(
                  valueListenable: active,
                  builder: (context, current, _) => Stack(
                    children: [
                      AnimatedPositioned(
                        duration: animate ? _indicatorSlide : Duration.zero,
                        curve: labEaseOut,
                        left: 0,
                        right: 0,
                        top: current * (_navItemHeight + _navGap),
                        height: _navItemHeight,
                        child: DecoratedBox(
                          decoration: BoxDecoration(
                            color: colors.card,
                            borderRadius: BorderRadius.circular(_navRadius),
                            boxShadow: colors.cardShadow,
                          ),
                          child: Align(
                            alignment: Alignment.centerLeft,
                            child: DecoratedBox(
                              decoration: BoxDecoration(
                                color: colors.primary,
                                borderRadius: BorderRadius.circular(2),
                              ),
                              child: const SizedBox(width: 3, height: 16),
                            ),
                          ),
                        ),
                      ),
                      Column(
                        children: [
                          for (var i = 0; i < entries.length; i++) ...[
                            if (i > 0) const SizedBox(height: _navGap),
                            _NavButton(
                              entry: entries[i],
                              selected: i == current,
                              onTap: () => onSelect(i),
                            ),
                          ],
                        ],
                      ),
                    ],
                  ),
                ),
              ),
              const Spacer(),
              if (lines >= 1)
                Padding(
                  padding: const EdgeInsets.fromLTRB(14, 12, 12, 20),
                  child: Text(
                    foot,
                    maxLines: lines,
                    overflow: TextOverflow.ellipsis,
                    style: NbText.caption.copyWith(
                      color: colors.textWeak,
                      fontSize: 12.5,
                      height: 17 / 12.5,
                    ),
                  ),
                ),
            ],
          ),
        );
      },
    );
  }
}

class _NavButton extends StatefulWidget {
  const _NavButton({
    required this.entry,
    required this.selected,
    required this.onTap,
  });

  final _Entry entry;
  final bool selected;
  final VoidCallback onTap;

  @override
  State<_NavButton> createState() => _NavButtonState();
}

class _NavButtonState extends State<_NavButton> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final colors = NbColors.of(context);
    final selected = widget.selected;
    final ink = selected || _hovered ? colors.text : colors.textWeak;
    return Semantics(
      button: true,
      selected: selected,
      label: widget.entry.title,
      excludeSemantics: true,
      onTap: widget.onTap,
      child: SizedBox(
        height: _navItemHeight,
        child: Material(
          type: MaterialType.transparency,
          child: InkWell(
            borderRadius: BorderRadius.circular(_navRadius),
            onTap: widget.onTap,
            onHover: (value) => setState(() => _hovered = value),
            hoverColor: selected ? Colors.transparent : colors.controlHover,
            highlightColor: Colors.transparent,
            splashFactory: NoSplash.splashFactory,
            mouseCursor: SystemMouseCursors.click,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(14, 0, 12, 0),
              child: Row(
                children: [
                  GlyphIcon(widget.entry.icon, size: 16, color: ink),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      widget.entry.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: NbText.button.copyWith(color: ink),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _Header extends StatelessWidget {
  const _Header({
    required this.strings,
    required this.controller,
    required this.onBack,
  });

  final AppStrings strings;
  final AppController controller;
  final VoidCallback onBack;

  @override
  Widget build(BuildContext context) {
    final colors = NbColors.of(context);
    return Align(
      alignment: Alignment.topLeft,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: _headerMaxWidth),
        child: SizedBox(
          height: _headerHeight,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 24, 0),
            child: Row(
              children: [
                BackButtonCircle(
                  tooltip: strings.settingsBack,
                  onPressed: onBack,
                ),
                const SizedBox(width: 12),
                Flexible(
                  child: ListenableBuilder(
                    listenable: controller,
                    builder: (context, _) => Row(
                      crossAxisAlignment: CrossAxisAlignment.baseline,
                      textBaseline: TextBaseline.alphabetic,
                      children: [
                        Text(
                          strings.settingsTitle,
                          maxLines: 1,
                          style: NbText.title.copyWith(
                            color: colors.text,
                            fontSize: 20,
                            height: 26 / 20,
                            letterSpacing: -0.24,
                            fontVariations: [
                              FontVariation.weight(colors.headingWeight),
                            ],
                          ),
                        ),
                        const SizedBox(width: 14),
                        Flexible(
                          child: DecoratedBox(
                            decoration: BoxDecoration(
                              border: Border(
                                left: BorderSide(color: colors.border),
                              ),
                            ),
                            child: Padding(
                              padding: const EdgeInsets.only(left: 14),
                              child: Text(
                                strings.settingsSubtitle(
                                  controller.state?.deviceName ?? '',
                                ),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: NbText.body.copyWith(
                                  color: colors.textWeak,
                                ),
                              ),
                            ),
                          ),
                        ),
                      ],
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

class BackButtonCircle extends StatefulWidget {
  const BackButtonCircle({
    required this.tooltip,
    required this.onPressed,
    super.key,
  });

  final String tooltip;
  final VoidCallback onPressed;

  @override
  State<BackButtonCircle> createState() => _BackButtonCircleState();
}

class _BackButtonCircleState extends State<BackButtonCircle> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final colors = NbColors.of(context);
    final animate = !MediaQuery.disableAnimationsOf(context);
    return Tooltip(
      message: widget.tooltip,
      child: Semantics(
        button: true,
        label: widget.tooltip,
        excludeSemantics: true,
        onTap: widget.onPressed,
        child: AnimatedSlide(
          offset: Offset(_hovered && animate ? -2 / _backSize : 0, 0),
          duration: const Duration(milliseconds: 350),
          curve: labEaseOut,
          child: Material(
            type: MaterialType.transparency,
            child: InkResponse(
              onTap: widget.onPressed,
              onHover: (value) => setState(() => _hovered = value),
              radius: _backSize / 2,
              containedInkWell: true,
              customBorder: const CircleBorder(),
              hoverColor: colors.controlHover,
              highlightColor: Colors.transparent,
              splashFactory: NoSplash.splashFactory,
              mouseCursor: SystemMouseCursors.click,
              child: SizedBox.square(
                dimension: _backSize,
                child: Center(
                  child: GlyphIcon(
                    Glyphs.back,
                    size: 18,
                    color: _hovered ? colors.text : colors.textWeak,
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _Footer extends StatelessWidget {
  const _Footer({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    final colors = NbColors.of(context);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(top: 1),
          child: GlyphIcon(Glyphs.check, size: 14, color: colors.successInk),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            text,
            style: NbText.caption.copyWith(
              color: colors.textWeak,
              height: 17 / 12,
            ),
          ),
        ),
      ],
    );
  }
}
