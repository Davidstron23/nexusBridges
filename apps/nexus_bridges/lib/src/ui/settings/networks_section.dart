import 'dart:async';

import 'package:flutter/material.dart';
import 'package:nexus_bridges_core/nexus_bridges_core.dart';

import '../../app_controller.dart';
import '../../l10n/app_strings.dart';
import '../format.dart';
import '../icons/glyphs.dart';
import '../theme/app_theme.dart';
import '../theme/components.dart';
import '../theme/tokens.dart';
import 'inline_confirm.dart';
import 'settings_field.dart';
import 'settings_rows.dart';
import 'settings_section.dart';

class NetworksSection extends StatefulWidget {
  const NetworksSection({required this.controller, super.key});

  final AppController controller;

  @override
  State<NetworksSection> createState() => _NetworksSectionState();
}

class _NetworksSectionState extends State<NetworksSection>
    with ConfirmCancelMixin<NetworksSection> {
  String? _confirmingId;
  late final List<String> _order = [
    for (final network in widget.controller.state?.trustedNetworks ?? const [])
      network.networkId,
  ];

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_onController);
  }

  @override
  void didUpdateWidget(NetworksSection oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller == widget.controller) return;
    oldWidget.controller.removeListener(_onController);
    widget.controller.addListener(_onController);
  }

  @override
  void dispose() {
    widget.controller.removeListener(_onController);
    super.dispose();
  }

  TrustedNetworkView? _viewOf(String id) {
    final networks = widget.controller.state?.trustedNetworks ?? const [];
    for (final network in networks) {
      if (network.networkId == id) return network;
    }
    return null;
  }

  void _onController() {
    final id = _confirmingId;
    if (id != null && !(_viewOf(id)?.connected ?? false)) {
      unregisterConfirm();
      _confirmingId = null;
    }
    setState(() {});
  }

  void _ask(TrustedNetworkView network) {
    if (!network.connected) {
      unawaited(widget.controller.stopUsingNetwork(network.networkId));
      return;
    }
    if (_confirmingId == network.networkId) {
      _cancelConfirm();
      return;
    }
    setState(() => _confirmingId = network.networkId);
    registerConfirm(_cancelConfirm);
  }

  void _cancelConfirm() {
    unregisterConfirm();
    if (!mounted) return;
    setState(() => _confirmingId = null);
  }

  void _confirm(String id) {
    unregisterConfirm();
    setState(() => _confirmingId = null);
    unawaited(widget.controller.stopUsingNetwork(id));
  }

  List<TrustedNetworkView> _frozenOrder(List<TrustedNetworkView> networks) {
    for (final network in networks) {
      if (!_order.contains(network.networkId)) _order.add(network.networkId);
    }
    final sorted = [...networks];
    sorted.sort(
      (a, b) =>
          _order.indexOf(a.networkId).compareTo(_order.indexOf(b.networkId)),
    );
    return sorted;
  }

  Widget _row(BuildContext context, TrustedNetworkView network, int index) {
    final strings = AppStringsDelegate.of(context);
    final colors = NbColors.of(context);
    final name = network.name ?? strings.unnamedNetwork;
    final bold = NbText.caption.copyWith(
      color: colors.text,
      fontSize: 12.5,
      fontWeight: FontWeight.w600,
    );
    final open = _confirmingId == network.networkId && network.connected;
    return Column(
      key: ValueKey('network-${network.networkId}'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SettingsRow(
          divider: index > 0,
          leading: GlyphIcon(
            Glyphs.wifi,
            size: 24,
            color: network.connected ? colors.successInk : colors.textWeak,
          ),
          title: name,
          subtitle: strings.trustedOn(
            formatShortDate(
              network.trustedAt,
              widget.controller.languageCode,
              strings,
            ),
          ),
          trailing: Wrap(
            spacing: 12,
            runSpacing: 4,
            alignment: WrapAlignment.end,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              if (network.connected)
                StatusChip(
                  label: strings.connectedNow,
                  tone: ChipTone.ok,
                  height: 20,
                ),
              TextButton(
                onPressed: () => _ask(network),
                style: smallButton.merge(
                  TextButton.styleFrom(foregroundColor: colors.danger).copyWith(
                    backgroundColor: WidgetStateProperty.resolveWith(
                      (states) => states.contains(WidgetState.hovered)
                          ? colors.dangerWeak
                          : Colors.transparent,
                    ),
                  ),
                ),
                child: Text(strings.stopUsingButton),
              ),
            ],
          ),
        ),
        InlineConfirm(
          open: open,
          danger: true,
          margin: const EdgeInsets.fromLTRB(12, 0, 12, 12),
          message: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text.rich(
                TextSpan(
                  children: leadSentenceBold(
                    strings.stopUsingConfirm(name),
                    bold,
                  ),
                ),
              ),
              if (network.transfers > 0 || network.pairing)
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Text(
                    [
                      if (network.transfers > 0)
                        strings.transfersStopped(network.transfers),
                      if (network.pairing) strings.pairingCancelled,
                    ].join(' '),
                    style: bold,
                  ),
                ),
            ],
          ),
          confirmLabel: strings.stopUsingConfirmButton,
          cancelLabel: strings.cancelButton,
          onConfirm: () => _confirm(network.networkId),
          onCancel: _cancelConfirm,
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final strings = AppStringsDelegate.of(context);
    final networks = _frozenOrder(
      widget.controller.state?.trustedNetworks ?? const [],
    );
    return SettingsSection(
      icon: Glyphs.wifi,
      title: strings.sectionNetworks,
      description: strings.networksInfo,
      child: SettingsRowList<TrustedNetworkView>(
        items: networks,
        idOf: (network) => network.networkId,
        rowBuilder: _row,
        emptyText: strings.networksEmpty,
      ),
    );
  }
}
