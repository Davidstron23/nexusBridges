import 'package:flutter/material.dart';

import 'app_theme.dart';
import 'tokens.dart';

class NbCard extends StatelessWidget {
  const NbCard({
    required this.child,
    this.padding = const EdgeInsets.fromLTRB(16, 14, 16, 14),
    this.ring,
    super.key,
  });

  final Widget child;
  final EdgeInsetsGeometry padding;
  final Color? ring;

  @override
  Widget build(BuildContext context) {
    final colors = NbColors.of(context);
    final radius = BorderRadius.circular(12);
    final ring = this.ring;
    return DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: radius,
        boxShadow: colors.cardShadow,
      ),
      child: Card(
        clipBehavior: Clip.antiAlias,
        shape: ring == null
            ? null
            : RoundedRectangleBorder(
                borderRadius: radius,
                side: BorderSide(
                  color: ring,
                  width: 1.5,
                  strokeAlign: BorderSide.strokeAlignInside,
                ),
              ),
        child: Padding(padding: padding, child: child),
      ),
    );
  }
}

enum ChipTone { ok, fail, run, wait, foreign, notVisible }

class StatusChip extends StatelessWidget {
  const StatusChip({
    required this.label,
    required this.tone,
    this.icon,
    this.height = 22,
    super.key,
  });

  final String label;
  final ChipTone tone;
  final Widget? icon;
  final double height;

  @override
  Widget build(BuildContext context) {
    final colors = NbColors.of(context);
    final (Color? fill, Color ink, BorderSide? side) = switch (tone) {
      ChipTone.ok => (colors.successWeak, colors.successInk, null),
      ChipTone.fail => (colors.dangerWeak, colors.danger, null),
      ChipTone.run => (colors.primaryWeak, colors.primaryInk, null),
      ChipTone.wait => (colors.surfaceWeak, colors.textWeak, null),
      ChipTone.foreign => (
        colors.surfaceWeak,
        colors.textWeak,
        BorderSide(color: colors.border),
      ),
      ChipTone.notVisible => (
        null,
        colors.textWeak,
        BorderSide(color: colors.hint),
      ),
    };
    final icon = this.icon;
    return Container(
      constraints: BoxConstraints(minHeight: height),
      padding: const EdgeInsets.symmetric(horizontal: 9),
      decoration: ShapeDecoration(
        color: fill,
        shape: StadiumBorder(side: side ?? BorderSide.none),
      ),
      child: IconTheme(
        data: IconThemeData(color: ink, size: 12),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            if (icon != null) ...[icon, const SizedBox(width: 4)],
            Flexible(
              child: Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: NbText.label.copyWith(color: ink),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class NbProgressBar extends StatelessWidget {
  const NbProgressBar({required this.value, super.key});

  final double value;

  @override
  Widget build(BuildContext context) {
    final colors = NbColors.of(context);
    final factor = value.isNaN ? 0.0 : value.clamp(0.0, 1.0);
    final radius = BorderRadius.circular(3);
    return Container(
      height: 6,
      decoration: BoxDecoration(color: colors.track, borderRadius: radius),
      alignment: Alignment.centerLeft,
      child: FractionallySizedBox(
        widthFactor: factor,
        heightFactor: 1,
        child: DecoratedBox(
          decoration: BoxDecoration(
            borderRadius: radius,
            gradient: LinearGradient(colors: [colors.hubTop, colors.primary]),
          ),
        ),
      ),
    );
  }
}

class NoticeCard extends StatelessWidget {
  const NoticeCard({required this.message, this.actions = const [], super.key});

  final String message;
  final List<Widget> actions;

  @override
  Widget build(BuildContext context) {
    final colors = NbColors.of(context);
    final themed = Theme.of(context).textButtonTheme.style;
    return NbCard(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(message, style: NbText.body.copyWith(color: colors.text)),
          if (actions.isNotEmpty) ...[
            const SizedBox(height: 8),
            TextButtonTheme(
              data: TextButtonThemeData(style: smallButton.merge(themed)),
              child: Wrap(spacing: 8, runSpacing: 4, children: actions),
            ),
          ],
        ],
      ),
    );
  }
}
