import '../discovery/discovery.dart';

enum IdentityStatus { ok, reset, failed }

final class NetworkPrompt {
  const NetworkPrompt(this.networkId, this.networkName);

  final String networkId;
  final String networkName;

  @override
  bool operator ==(Object other) =>
      other is NetworkPrompt &&
      other.networkId == networkId &&
      other.networkName == networkName;

  @override
  int get hashCode => Object.hash(networkId, networkName);
}

final class NodeState {
  const NodeState({
    this.identityStatus = IdentityStatus.ok,
    this.identityError,
    this.prompts = const [],
    this.paused = false,
    this.pausedNetworks = const [],
    this.devices = const [],
    this.displayNames = const {},
    this.suggestRescan = false,
    this.portInUse,
    this.decisionNotSaved = false,
    this.deviceName = '',
    this.fingerprint = '',
  });

  final IdentityStatus identityStatus;
  final String? identityError;
  final List<NetworkPrompt> prompts;
  final bool paused;
  final List<NetworkPrompt> pausedNetworks;
  final List<DiscoveredDevice> devices;
  final Map<String, String> displayNames;
  final bool suggestRescan;
  final int? portInUse;
  final bool decisionNotSaved;
  final String deviceName;
  final String fingerprint;
}
