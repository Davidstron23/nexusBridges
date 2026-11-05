import 'package:flutter/material.dart';

import '../icons/glyphs.dart';
import '../modal/timeline.dart';
import '../theme/app_theme.dart';
import '../theme/tokens.dart';

const Duration _grow = Duration(milliseconds: 420);
const double _boxRadius = 12;

class InlineConfirm extends StatefulWidget {
  const InlineConfirm({
    required this.open,
    required this.message,
    required this.confirmLabel,
    required this.cancelLabel,
    required this.onConfirm,
    required this.onCancel,
    this.danger = false,
    this.ice = false,
    this.margin = const EdgeInsets.only(top: 10),
    super.key,
  });

  final bool open;
  final Widget message;
  final String confirmLabel;
  final String cancelLabel;
  final VoidCallback onConfirm;
  final VoidCallback onCancel;
  final bool danger;
  final bool ice;
  final EdgeInsets margin;

  @override
  State<InlineConfirm> createState() => _InlineConfirmState();
}

class _InlineConfirmState extends State<InlineConfirm> {
  late InlineConfirm _shown = widget;

  @override
  void didUpdateWidget(InlineConfirm oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.open) _shown = widget;
  }

  Widget _box(BuildContext context, InlineConfirm shown, bool open) {
    final colors = NbColors.of(context);
    final themed = Theme.of(context).textButtonTheme.style;
    final danger = shown.danger;
    return Padding(
      padding: shown.margin,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: danger
              ? colors.dangerWeak
              : (shown.ice ? colors.iceWeak : colors.segment),
          borderRadius: BorderRadius.circular(_boxRadius),
        ),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (danger || shown.ice) ...[
                    Padding(
                      padding: const EdgeInsets.only(top: 1),
                      child: GlyphIcon(
                        danger ? Glyphs.warn : Glyphs.info,
                        size: 16,
                        color: danger ? colors.danger : colors.ice,
                      ),
                    ),
                    const SizedBox(width: 8),
                  ],
                  Expanded(
                    child: DefaultTextStyle.merge(
                      style: NbText.caption.copyWith(
                        color: danger || shown.ice
                            ? colors.text
                            : colors.textWeak,
                        fontSize: 12.5,
                        height: 18 / 12.5,
                      ),
                      child: shown.message,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              Align(
                alignment: Alignment.centerRight,
                child: TextButtonTheme(
                  data: TextButtonThemeData(style: smallButton.merge(themed)),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      TextButton(
                        onPressed: open ? shown.onCancel : null,
                        style: TextButton.styleFrom(
                          foregroundColor: colors.textWeak,
                        ),
                        child: Text(shown.cancelLabel),
                      ),
                      const SizedBox(width: 8),
                      FilledButton(
                        onPressed: open ? shown.onConfirm : null,
                        style: smallButton.merge(
                          danger
                              ? FilledButton.styleFrom(
                                  backgroundColor: colors.dangerFill,
                                  foregroundColor: colors.onPrimary,
                                )
                              : null,
                        ),
                        child: Text(shown.confirmLabel),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final animate = !MediaQuery.disableAnimationsOf(context);
    final open = widget.open;
    final shown = _shown;
    return TweenAnimationBuilder<double>(
      tween: Tween<double>(end: open ? 1 : 0),
      duration: animate ? _grow : Duration.zero,
      curve: labEaseOut,
      builder: (context, t, _) {
        if (t <= 0 && !open) {
          return const SizedBox(width: double.infinity, height: 0);
        }
        final opacity = t.clamp(0.0, 1.0);
        return ClipRect(
          child: Align(
            alignment: Alignment.topCenter,
            heightFactor: opacity,
            child: Opacity(
              opacity: opacity,
              child: ExcludeFocus(
                excluding: !open,
                child: IgnorePointer(
                  ignoring: !open,
                  child: _box(context, shown, open),
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

class ConfirmRegistry {
  final List<VoidCallback> _open = [];

  VoidCallback? get value => _open.isEmpty ? null : _open.last;

  void add(VoidCallback cancel) => _open.add(cancel);

  void remove(VoidCallback cancel) {
    final index = _open.lastIndexOf(cancel);
    if (index >= 0) _open.removeAt(index);
  }
}

class ConfirmScope extends InheritedWidget {
  const ConfirmScope({required this.cancel, required super.child, super.key});

  final ConfirmRegistry cancel;

  static ConfirmRegistry? maybeOf(BuildContext context) {
    return context.dependOnInheritedWidgetOfExactType<ConfirmScope>()?.cancel;
  }

  @override
  bool updateShouldNotify(ConfirmScope oldWidget) => cancel != oldWidget.cancel;
}

mixin ConfirmCancelMixin<T extends StatefulWidget> on State<T> {
  ConfirmRegistry? _scope;
  VoidCallback? _registered;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _scope = ConfirmScope.maybeOf(context);
  }

  void registerConfirm(VoidCallback cancel) {
    final scope = _scope;
    if (scope == null || _registered != null) return;
    _registered = cancel;
    scope.add(cancel);
  }

  void unregisterConfirm() {
    final scope = _scope;
    final registered = _registered;
    if (scope == null || registered == null) return;
    scope.remove(registered);
    _registered = null;
  }

  @override
  void dispose() {
    unregisterConfirm();
    super.dispose();
  }
}
