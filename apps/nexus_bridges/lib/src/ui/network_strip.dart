import 'package:flutter/material.dart';
import 'package:nexus_bridges_core/nexus_bridges_core.dart';

import '../l10n/app_strings.dart';
import 'icons/device_disc.dart';
import 'icons/glyphs.dart';
import 'theme/app_theme.dart';
import 'theme/tokens.dart';

const double _stripHeight = 60;
const double _stripRadius = 14;
const double _noteBreakpoint = 700;
const double _rescanHeight = 36;
const Duration _spinPeriod = Duration(milliseconds: 900);
const String _titleSeparator = ' · ';

class NetworkStrip extends StatefulWidget {
  const NetworkStrip({
    required this.state,
    required this.onRescan,
    required this.onTrust,
    this.onSettings,
    this.compact = false,
    super.key,
  });

  final NodeState state;
  final VoidCallback onRescan;
  final void Function(String networkId) onTrust;
  final VoidCallback? onSettings;
  final bool compact;

  @override
  State<NetworkStrip> createState() => _NetworkStripState();
}

class _NetworkStripState extends State<NetworkStrip>
    with SingleTickerProviderStateMixin {
  late final AnimationController _spin;
  bool _reduceMotion = false;

  @override
  void initState() {
    super.initState();
    _spin = AnimationController(vsync: this, duration: _spinPeriod);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _reduceMotion = MediaQuery.disableAnimationsOf(context);
    _syncSpin();
  }

  @override
  void didUpdateWidget(NetworkStrip oldWidget) {
    super.didUpdateWidget(oldWidget);
    _syncSpin();
  }

  @override
  void dispose() {
    _spin.dispose();
    super.dispose();
  }

  void _syncSpin() {
    if (widget.state.scanning && !_reduceMotion) {
      if (!_spin.isAnimating) _spin.repeat();
    } else if (_spin.isAnimating) {
      _spin.stop();
      _spin.value = 0;
    }
  }

  Widget _rescanButton(AppStrings strings, {required double iconSize}) {
    final onPressed = widget.state.scanning ? null : widget.onRescan;
    final icon = RotationTransition(
      turns: _spin,
      child: GlyphIcon(Glyphs.refresh, size: iconSize),
    );
    if (widget.compact) {
      return IconButton.outlined(
        onPressed: onPressed,
        tooltip: strings.rescanButton,
        icon: icon,
        style: const ButtonStyle(
          fixedSize: WidgetStatePropertyAll(Size.square(_rescanHeight)),
        ),
      );
    }
    return OutlinedButton.icon(
      onPressed: onPressed,
      icon: icon,
      label: Text(strings.rescanButton),
      style: const ButtonStyle(
        minimumSize: WidgetStatePropertyAll(Size(0, _rescanHeight)),
        padding: WidgetStatePropertyAll(EdgeInsets.symmetric(horizontal: 16)),
        shape: WidgetStatePropertyAll(StadiumBorder()),
      ),
    );
  }

  Widget _settingsButton(AppStrings strings) {
    return IconButton.outlined(
      onPressed: widget.onSettings,
      tooltip: strings.settingsButton,
      icon: const GlyphIcon(Glyphs.sliders, size: 16),
      style: const ButtonStyle(
        fixedSize: WidgetStatePropertyAll(Size.square(_rescanHeight)),
      ),
    );
  }

  Widget _trusted(AppStrings strings, NbColors colors) {
    final state = widget.state;
    final names = [
      for (final network in state.activeNetworks)
        if (network.networkName.isNotEmpty) network.networkName,
    ];
    final named = names.isNotEmpty;
    final title = named
        ? names.join(_titleSeparator)
        : strings.trustedNetworkLabel;
    final status = state.scanning
        ? strings.searchingDevices
        : (named ? strings.trustedNetworkLabel : null);
    return LayoutBuilder(
      builder: (context, constraints) {
        final showNote = constraints.maxWidth >= _noteBreakpoint;
        return DecoratedBox(
          decoration: BoxDecoration(
            color: colors.netSurface,
            borderRadius: BorderRadius.circular(_stripRadius),
          ),
          child: SizedBox(
            height: _stripHeight,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(14, 0, 12, 0),
              child: Row(
                children: [
                  const NetworkDisc(trusted: true),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Row(
                      children: [
                        Flexible(
                          child: Text(
                            title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: NbText.bodyStrong.copyWith(
                              color: colors.text,
                            ),
                          ),
                        ),
                        if (status != null) ...[
                          const SizedBox(width: 12),
                          Flexible(
                            child: Text(
                              status,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: NbText.bodySm.copyWith(
                                color: colors.textWeak,
                              ),
                            ),
                          ),
                        ],
                        if (showNote) ...[
                          const SizedBox(width: 12),
                          SizedBox(
                            width: 1,
                            height: 20,
                            child: ColoredBox(
                              color: colors.border.withValues(alpha: 0.7),
                            ),
                          ),
                          const SizedBox(width: 12),
                          Flexible(
                            flex: 2,
                            child: Text(
                              strings.onlyPairedCanSend,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: NbText.bodySm.copyWith(
                                color: colors.textWeak,
                              ),
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                  const SizedBox(width: 12),
                  _rescanButton(strings, iconSize: widget.compact ? 16 : 14),
                  if (widget.onSettings != null) ...[
                    const SizedBox(width: 8),
                    _settingsButton(strings),
                  ],
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _paused(AppStrings strings, NbColors colors) {
    final state = widget.state;
    final themed = Theme.of(context).textButtonTheme.style;
    return DecoratedBox(
      decoration: ShapeDecoration(
        color: colors.card,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(_stripRadius),
          side: BorderSide(
            color: colors.border,
            strokeAlign: BorderSide.strokeAlignInside,
          ),
        ),
      ),
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: _stripHeight),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(14, 8, 12, 8),
          child: Row(
            children: [
              const NetworkDisc(trusted: false),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      strings.pausedBanner,
                      maxLines: 3,
                      overflow: TextOverflow.ellipsis,
                      style: NbText.bodyStrong.copyWith(color: colors.text),
                    ),
                    if (state.scanning)
                      Text(
                        strings.searchingDevices,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: NbText.bodySm.copyWith(color: colors.textWeak),
                      ),
                    if (state.pausedNetworks.isNotEmpty) ...[
                      const SizedBox(height: 4),
                      TextButtonTheme(
                        data: TextButtonThemeData(
                          style: smallButton.merge(themed),
                        ),
                        child: Wrap(
                          spacing: 8,
                          runSpacing: 4,
                          children: [
                            for (final network in state.pausedNetworks)
                              TextButton(
                                onPressed: () =>
                                    widget.onTrust(network.networkId),
                                child: Text(
                                  strings.trustNetworkButton(
                                    network.networkName,
                                  ),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                          ],
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              const SizedBox(width: 12),
              _rescanButton(strings, iconSize: widget.compact ? 16 : 14),
              if (widget.onSettings != null) ...[
                const SizedBox(width: 8),
                _settingsButton(strings),
              ],
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final strings = AppStringsDelegate.of(context);
    final colors = NbColors.of(context);
    return widget.state.paused
        ? _paused(strings, colors)
        : _trusted(strings, colors);
  }
}
