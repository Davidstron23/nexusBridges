import 'dart:async';

import '../network/network.dart';
import '../protocol/protocol.dart';
import 'node_state.dart';

Future<List<AdapterInfo>> Function() singleFlight(
  Future<List<AdapterInfo>> Function() read,
) {
  Future<List<AdapterInfo>>? inFlight;
  return () {
    final running = inFlight;
    if (running != null) return running;
    final started = Future<List<AdapterInfo>>.sync(read);
    inFlight = started;
    void release() {
      if (identical(inFlight, started)) inFlight = null;
    }

    unawaited(started.then((_) => release(), onError: (Object _) => release()));
    return started;
  };
}

final class NetworkPlan {
  const NetworkPlan({
    required this.active,
    required this.prompts,
    required this.pausedNetworks,
    required this.activeNetworks,
    required this.paused,
  });

  final List<ActiveInterface> active;
  final List<NetworkPrompt> prompts;
  final List<NetworkPrompt> pausedNetworks;
  final List<NetworkPrompt> activeNetworks;
  final bool paused;
}

String _promptName(AdapterInfo adapter) =>
    sanitizeDisplayName(adapter.networkName ?? '') ??
    sanitizeDisplayName(adapter.friendlyName) ??
    adapter.networkId!;

NetworkPlan reconcileNetworks({
  required List<AdapterInfo> adapters,
  required NetworkDecision? Function(String networkId) decisionOf,
  required Set<String> dismissed,
  required Set<String> asking,
  List<ActiveInterface> Function(List<InterfaceState>) activeOf =
      activeInterfaces,
}) {
  final states = evaluateInterfaces(adapters, decisionOf);
  final active = activeOf(states);
  final adapterById = {for (final s in states) s.adapter.id: s.adapter};
  final activeNetworks = <NetworkPrompt>[];
  final seenNetworks = <String>{};
  for (final interface in active) {
    final adapter = adapterById[interface.adapterId];
    final networkId = adapter?.networkId;
    if (adapter == null || networkId == null) continue;
    if (seenNetworks.add(networkId)) {
      activeNetworks.add(NetworkPrompt(networkId, _promptName(adapter)));
    }
  }

  final firstOfNetwork = <String, InterfaceState>{};
  for (final state in states) {
    firstOfNetwork.putIfAbsent(state.adapter.networkId!, () => state);
  }

  final prompts = <NetworkPrompt>[];
  final pausedNetworks = <NetworkPrompt>[];
  for (final MapEntry(key: networkId, value: state) in firstOfNetwork.entries) {
    final isAsking = asking.contains(networkId);
    final showPrompt = switch (state.status) {
      InterfaceStatus.undecided => isAsking || !dismissed.contains(networkId),
      InterfaceStatus.paused => isAsking,
      InterfaceStatus.active => false,
    };
    final prompt = NetworkPrompt(networkId, _promptName(state.adapter));
    if (showPrompt) {
      prompts.add(prompt);
    } else if (state.status != InterfaceStatus.active) {
      pausedNetworks.add(prompt);
    }
  }

  return NetworkPlan(
    active: active,
    prompts: prompts,
    pausedNetworks: pausedNetworks,
    activeNetworks: activeNetworks,
    paused: active.isEmpty,
  );
}
