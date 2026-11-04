import 'package:flutter/material.dart';

import '../icons/glyphs.dart';
import '../modal/timeline.dart';
import '../theme/app_theme.dart';
import '../theme/tokens.dart';
import 'state_blend.dart';

const double _trackRadius = 10;
const double _thumbRadius = 7;
const double _trackPadding = 3;
const double _segmentHeight = 32;
const Duration _slide = Duration(milliseconds: 420);
const Duration _inkFade = Duration(milliseconds: 350);

final class SegmentOption<T> {
  const SegmentOption({required this.value, required this.label, this.icon});

  final T value;
  final String label;
  final Glyph? icon;
}

class SegmentedChoice<T> extends StatelessWidget {
  const SegmentedChoice({
    required this.options,
    required this.value,
    required this.onChanged,
    super.key,
  });

  final List<SegmentOption<T>> options;
  final T value;
  final ValueChanged<T> onChanged;

  @override
  Widget build(BuildContext context) {
    final colors = NbColors.of(context);
    final animate = !MediaQuery.disableAnimationsOf(context);
    final count = options.length;
    final found = options.indexWhere((option) => option.value == value);
    final index = found < 0 ? 0 : found;
    final height = MediaQuery.textScalerOf(context).scale(_segmentHeight);
    return Semantics(
      container: true,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: colors.segment,
          borderRadius: BorderRadius.circular(_trackRadius),
        ),
        child: Padding(
          padding: const EdgeInsets.all(_trackPadding),
          child: SizedBox(
            height: height,
            child: Stack(
              fit: StackFit.expand,
              children: [
                AnimatedAlign(
                  alignment: Alignment(
                    count < 2 ? 0 : -1 + 2 * index / (count - 1),
                    0,
                  ),
                  duration: animate ? _slide : Duration.zero,
                  curve: labEaseOut,
                  child: FractionallySizedBox(
                    widthFactor: 1 / count,
                    heightFactor: 1,
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        color: colors.card,
                        borderRadius: BorderRadius.circular(_thumbRadius),
                        boxShadow: [
                          BoxShadow(
                            color: colors.nodeShadow,
                            offset: const Offset(0, 1),
                            blurRadius: 2,
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
                Row(
                  children: [
                    for (final option in options)
                      Expanded(
                        child: _Segment<T>(
                          option: option,
                          selected: option.value == value,
                          animate: animate,
                          onTap: () => onChanged(option.value),
                        ),
                      ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _Segment<T> extends StatelessWidget {
  const _Segment({
    required this.option,
    required this.selected,
    required this.animate,
    required this.onTap,
  });

  final SegmentOption<T> option;
  final bool selected;
  final bool animate;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = NbColors.of(context);
    final icon = option.icon;
    return Semantics(
      button: true,
      inMutuallyExclusiveGroup: true,
      selected: selected,
      label: option.label,
      excludeSemantics: true,
      onTap: onTap,
      child: Material(
        type: MaterialType.transparency,
        child: InkWell(
          borderRadius: BorderRadius.circular(_thumbRadius),
          mouseCursor: selected
              ? SystemMouseCursors.basic
              : SystemMouseCursors.click,
          hoverColor: Colors.transparent,
          highlightColor: Colors.transparent,
          splashFactory: NoSplash.splashFactory,
          onTap: onTap,
          child: Center(
            child: StateBlend(
              on: selected,
              duration: animate ? _inkFade : Duration.zero,
              curve: Curves.ease,
              builder: (context, t) => Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (icon != null) ...[
                    GlyphIcon(
                      icon,
                      size: 15,
                      color: Color.lerp(colors.textWeak, colors.text, t),
                    ),
                    const SizedBox(width: 7),
                  ],
                  Flexible(
                    child: Text(
                      option.label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: NbText.button.copyWith(
                        color: Color.lerp(colors.textWeak, colors.text, t),
                      ),
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
