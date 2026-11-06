import 'package:flutter/material.dart';
import 'package:nexus_bridges_core/nexus_bridges_core.dart';

import '../../app_controller.dart';
import '../../l10n/app_strings.dart';
import '../destination/folder_navigator.dart';
import '../destination/navigator_controller.dart';
import '../icons/device_disc.dart';
import '../icons/glyphs.dart';
import '../diagram/flow_painter.dart' show dashPath;
import '../modal/timeline.dart';
import '../theme/app_theme.dart';
import '../theme/tokens.dart';
import 'portal_controller.dart';

const double portalWidth = 284;
const double _rowHeight = 40;
const double _gap = 22;
const double _verticalShift = 70;
const double _chrome = 340;
const double _minList = 80;
const double _maxList = 360;
const Duration _openMotion = Duration(milliseconds: 420);
const Duration _paneMotion = Duration(milliseconds: 420);

class PortalHost extends StatelessWidget {
  const PortalHost({required this.portal, required this.controller, super.key});

  final PortalController portal;
  final AppController controller;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: portal,
      builder: (context, _) {
        final navigator = portal.navigator;
        final fingerprint = portal.fingerprint;
        if (navigator == null || fingerprint == null) {
          return const SizedBox.shrink();
        }
        final box = context.findRenderObject();
        Rect? anchor = portal.anchor;
        if (anchor != null && box is RenderBox && box.hasSize) {
          anchor = box.globalToLocal(anchor.topLeft) & anchor.size;
        }
        return Positioned.fill(
          child: IgnorePointer(
            child: CustomSingleChildLayout(
              delegate: _PortalLayout(anchor),
              child: PortalPanel(
                key: ValueKey('portal-$fingerprint'),
                portal: portal,
                navigator: navigator,
                controller: controller,
                fingerprint: fingerprint,
              ),
            ),
          ),
        );
      },
    );
  }
}

class _PortalLayout extends SingleChildLayoutDelegate {
  const _PortalLayout(this.anchor);

  final Rect? anchor;

  @override
  BoxConstraints getConstraintsForChild(BoxConstraints constraints) =>
      constraints.loosen();

  @override
  Offset getPositionForChild(Size size, Size childSize) {
    const margin = 10.0;
    final rect = anchor;
    var x = rect == null
        ? size.width - childSize.width - margin
        : rect.left - _gap - childSize.width;
    var y = rect == null
        ? margin
        : rect.center.dy -
              (childSize.height / 2 < _verticalShift
                  ? childSize.height / 2
                  : _verticalShift);
    if (rect != null && x < margin) x = rect.right + _gap;
    final maxX = size.width - childSize.width - margin;
    final maxY = size.height - childSize.height - margin;
    x = x.clamp(margin, maxX < margin ? margin : maxX);
    y = y.clamp(margin, maxY < margin ? margin : maxY);
    return Offset(x, y);
  }

  @override
  bool shouldRelayout(_PortalLayout oldDelegate) =>
      oldDelegate.anchor != anchor;
}

class PortalPanel extends StatefulWidget {
  const PortalPanel({
    required this.portal,
    required this.navigator,
    required this.controller,
    required this.fingerprint,
    super.key,
  });

  final PortalController portal;
  final FolderNavigatorController navigator;
  final AppController controller;
  final String fingerprint;

  @override
  State<PortalPanel> createState() => _PortalPanelState();
}

class _PortalPanelState extends State<PortalPanel> {
  final GlobalKey _panelKey = GlobalKey();
  int _depth = 1;
  bool _forward = true;

  @override
  void initState() {
    super.initState();
    widget.portal.bindPanel(_panelKey);
    _depth = widget.navigator.stack.length;
    widget.navigator.addListener(_onNav);
  }

  @override
  void dispose() {
    widget.navigator.removeListener(_onNav);
    super.dispose();
  }

  void _onNav() {
    final depth = widget.navigator.stack.length;
    if (depth == _depth) return;
    setState(() {
      _forward = depth > _depth;
      _depth = depth;
    });
  }

  @override
  Widget build(BuildContext context) {
    final colors = NbColors.of(context);
    final strings = AppStringsDelegate.of(context);
    final animate = !MediaQuery.disableAnimationsOf(context);
    DeviceEntry? entry;
    for (final candidate in widget.controller.state?.entries ?? const []) {
      if (candidate.fingerprint == widget.fingerprint) entry = candidate;
    }
    final name = entry?.displayName ?? '';
    final nav = widget.navigator;
    final portal = widget.portal;
    portal.clearRows();
    final screen = MediaQuery.sizeOf(context).height;
    final maxList = (screen - _chrome).clamp(_minList, _maxList).toDouble();
    return TweenAnimationBuilder<double>(
      tween: Tween<double>(begin: animate ? 0 : 1, end: 1),
      duration: animate ? _openMotion : Duration.zero,
      curve: const Cubic(0.2, 0.8, 0.2, 1),
      builder: (context, t, child) => Opacity(
        opacity: t.clamp(0.0, 1.0),
        child: Transform.translate(
          offset: Offset(20 * (1 - t), 0),
          child: Transform.scale(
            scale: 0.6 + 0.4 * t,
            alignment: Alignment.centerRight,
            child: child,
          ),
        ),
      ),
      child: DecoratedBox(
        key: _panelKey,
        decoration: BoxDecoration(
          color: colors.menuSurface,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: colors.menuBorder),
          boxShadow: colors.menuShadow,
        ),
        child: SizedBox(
          width: portalWidth,
          child: Padding(
            padding: const EdgeInsets.all(8),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _head(strings, colors, entry, name),
                if (!nav.atRoots) _crumbs(colors, name),
                ClipRect(
                  child: AnimatedSwitcher(
                    duration: animate ? _paneMotion : Duration.zero,
                    switchInCurve: labEaseOut,
                    switchOutCurve: labEaseOut,
                    layoutBuilder: (current, previous) => Stack(
                      alignment: Alignment.topCenter,
                      children: [...previous, ?current],
                    ),
                    transitionBuilder: (child, animation) {
                      final incoming =
                          child.key == ValueKey<int>(nav.stack.length);
                      final begin = incoming
                          ? (_forward ? 0.36 : -0.36)
                          : (_forward ? -0.3 : 0.3);
                      return AnimatedBuilder(
                        animation: animation,
                        child: child,
                        builder: (context, child) => Opacity(
                          opacity: animation.value,
                          child: FractionalTranslation(
                            translation: Offset(
                              begin * (1 - animation.value),
                              0,
                            ),
                            child: child,
                          ),
                        ),
                      );
                    },
                    child: KeyedSubtree(
                      key: ValueKey<int>(nav.stack.length),
                      child: _rows(strings, colors, name, maxList),
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

  Widget _head(
    AppStrings strings,
    NbColors colors,
    DeviceEntry? entry,
    String name,
  ) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(6, 4, 6, 8),
      child: Row(
        children: [
          DeviceDisc(type: entry?.deviceType, size: 30, tone: DiscTone.sending),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: NbText.bodyStrong.copyWith(color: colors.text),
                ),
                Text(
                  strings.portalDropIn,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: NbText.caption.copyWith(color: colors.textWeak),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _crumbs(NbColors colors, String name) {
    final nav = widget.navigator;
    final parts = <Widget>[
      Flexible(
        child: Text(
          name,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: NbText.caption.copyWith(color: colors.textWeak),
        ),
      ),
      for (var i = 1; i < nav.stack.length; i++) ...[
        const SizedBox(width: 4),
        GlyphIcon(Glyphs.chevronRight, size: 11, color: colors.hint),
        const SizedBox(width: 4),
        Flexible(
          child: Text(
            visibleFileName(nav.stack[i].name ?? ''),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: NbText.caption.copyWith(
              color: colors.text,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
      ],
    ];
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 0, 8, 6),
      child: Row(children: parts),
    );
  }

  Widget _rows(
    AppStrings strings,
    NbColors colors,
    String name,
    double maxList,
  ) {
    final nav = widget.navigator;
    final level = nav.stack.last;
    final children = <Widget>[];
    final status = nav.status;
    final notice = switch (status) {
      NavStatus.busy => strings.navBusy(name),
      NavStatus.gone => strings.navGone,
      NavStatus.unreadable => strings.navUnreadable(name),
      _ => null,
    };
    if (notice != null) children.add(NavNotice(text: notice));
    if (!nav.atRoots) {
      final parent = nav.stack.length > 2
          ? visibleFileName(nav.stack[nav.stack.length - 2].name ?? name)
          : name;
      children.add(
        _PortalRow(
          portal: widget.portal,
          hit: const PortalBackHit(),
          glyph: Glyphs.back,
          label: strings.portalBack(parent),
          muted: true,
        ),
      );
      children.add(
        _PortalRow(
          portal: widget.portal,
          hit: const PortalHereHit(),
          glyph: Glyphs.drop,
          label: strings.portalHereIn(visibleFileName(level.name ?? '')),
        ),
      );
    }
    if (level.folders.isNotEmpty) {
      children.add(
        _FolderList(
          portal: widget.portal,
          folders: level.folders,
          rootIds: level.rootIds,
          maxHeight: maxList,
        ),
      );
    }
    if (level.more) children.add(NavNotice(text: strings.navMore));
    if (level.partial) children.add(NavNotice(text: strings.navPartial));
    if (nav.atRoots) {
      children.add(
        Padding(
          padding: const EdgeInsets.fromLTRB(8, 8, 8, 4),
          child: Text(
            strings.portalHold,
            style: NbText.caption.copyWith(
              color: colors.textWeak,
              fontSize: 11.5,
              height: 15 / 11.5,
            ),
          ),
        ),
      );
    }
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: children,
    );
  }
}

class _FolderList extends StatefulWidget {
  const _FolderList({
    required this.portal,
    required this.folders,
    required this.rootIds,
    required this.maxHeight,
  });

  final PortalController portal;
  final List<String> folders;
  final List<String>? rootIds;
  final double maxHeight;

  @override
  State<_FolderList> createState() => _FolderListState();
}

class _FolderListState extends State<_FolderList> {
  final GlobalKey _viewport = GlobalKey();
  final ScrollController _scroll = ScrollController();

  @override
  void initState() {
    super.initState();
    widget.portal.bindList(_viewport, _scroll);
  }

  @override
  void dispose() {
    widget.portal.unbindList(_scroll);
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final folders = widget.folders;
    final rootIds = widget.rootIds;
    final height = (folders.length * _rowHeight).clamp(0, widget.maxHeight);
    return SizedBox(
      key: _viewport,
      height: height.toDouble(),
      child: ListView.builder(
        controller: _scroll,
        physics: const ClampingScrollPhysics(),
        padding: EdgeInsets.zero,
        itemExtent: _rowHeight,
        itemCount: folders.length,
        itemBuilder: (context, index) => _PortalRow(
          key: ValueKey('portal-row-$index-${folders[index]}'),
          portal: widget.portal,
          hit: PortalFolderHit(
            folders[index],
            rootId: rootIds == null ? null : rootIds[index],
          ),
          glyph: Glyphs.folder,
          label: visibleFileName(folders[index]),
          chevron: true,
        ),
      ),
    );
  }
}

class _PortalRow extends StatefulWidget {
  const _PortalRow({
    super.key,
    required this.portal,
    required this.hit,
    required this.glyph,
    required this.label,
    this.muted = false,
    this.chevron = false,
  });

  final PortalController portal;
  final PortalHit hit;
  final Glyph glyph;
  final String label;
  final bool muted;
  final bool chevron;

  @override
  State<_PortalRow> createState() => _PortalRowState();
}

class _PortalRowState extends State<_PortalRow> {
  final GlobalKey _key = GlobalKey();

  @override
  Widget build(BuildContext context) {
    final colors = NbColors.of(context);
    final portal = widget.portal;
    portal.registerRow(widget.hit, _key);
    final hot = portal.armed == widget.hit;
    final arming =
        hot && (widget.hit is PortalFolderHit || widget.hit is PortalBackHit);
    final animate = !MediaQuery.disableAnimationsOf(context);
    return Container(
      key: _key,
      height: _rowHeight,
      margin: const EdgeInsets.only(bottom: 0),
      child: CustomPaint(
        foregroundPainter: _DashedBorder(
          color: hot ? colors.primary : colors.primary.withValues(alpha: 0),
        ),
        child: AnimatedContainer(
          duration: animate ? const Duration(milliseconds: 200) : Duration.zero,
          decoration: BoxDecoration(
            color: hot
                ? colors.primaryWeak
                : colors.primaryWeak.withValues(alpha: 0),
            borderRadius: BorderRadius.circular(9),
          ),
          child: Stack(
            children: [
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 10),
                child: Row(
                  children: [
                    GlyphIcon(
                      widget.glyph,
                      size: 18,
                      color: widget.muted ? colors.textWeak : colors.primaryInk,
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        widget.label,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: NbText.bodySm.copyWith(
                          color: colors.text,
                          fontWeight: FontWeight.w500,
                          height: 17 / 13,
                        ),
                      ),
                    ),
                    if (widget.chevron)
                      GlyphIcon(
                        Glyphs.chevronRight,
                        size: 13,
                        color: colors.hint,
                      ),
                  ],
                ),
              ),
              Positioned(
                left: 8,
                right: 8,
                bottom: 3,
                child: TweenAnimationBuilder<double>(
                  key: ValueKey(arming),
                  tween: Tween<double>(begin: 0, end: arming ? 1 : 0),
                  duration: arming && animate ? portalHoldDelay : Duration.zero,
                  builder: (context, t, _) => Align(
                    alignment: Alignment.centerLeft,
                    child: FractionallySizedBox(
                      widthFactor: t,
                      child: SizedBox(
                        height: 2,
                        child: DecoratedBox(
                          decoration: BoxDecoration(
                            color: colors.primary,
                            borderRadius: BorderRadius.circular(1),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _DashedBorder extends CustomPainter {
  const _DashedBorder({required this.color});

  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    if (color.a == 0) return;
    final rect = (Offset.zero & size).deflate(0.75);
    final path = Path()
      ..addRRect(RRect.fromRectAndRadius(rect, const Radius.circular(9)));
    canvas.drawPath(
      dashPath(path, const [4, 3]),
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.5
        ..color = color,
    );
  }

  @override
  bool shouldRepaint(_DashedBorder oldDelegate) => oldDelegate.color != color;
}
