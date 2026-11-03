import '../identity/identity.dart' show shortFingerprint;
import '../network/network.dart' show TrustedNetwork;
import '../pairing/pairing.dart' show IgnoredDevice;
import '../protocol/protocol.dart' show sanitizeDisplayName;
import '../transfer/transfer.dart' show defaultExclusions, isValidFileName;
import 'node_state.dart' show IgnoredDeviceView, TrustedNetworkView;

const int _maxExclusions = 64;

enum ExclusionProblem { empty, invalid, duplicate, full }

ExclusionProblem? exclusionProblem(String trimmed, List<String> current) {
  if (trimmed.isEmpty) return ExclusionProblem.empty;
  if (!isValidFileName(trimmed)) return ExclusionProblem.invalid;
  final upper = trimmed.toUpperCase();
  if (current.any((name) => name.toUpperCase() == upper)) {
    return ExclusionProblem.duplicate;
  }
  if (current.length >= _maxExclusions) return ExclusionProblem.full;
  return null;
}

List<String> effectiveExclusions(List<String>? saved) {
  if (saved == null ||
      saved.length > _maxExclusions ||
      !saved.every(isValidFileName)) {
    return List<String>.of(defaultExclusions);
  }
  final seen = <String>{};
  for (final name in saved) {
    if (!seen.add(name.toUpperCase())) {
      return List<String>.of(defaultExclusions);
    }
  }
  return List<String>.of(saved);
}

bool isDefaultExclusionList(List<String> names) {
  if (names.length != defaultExclusions.length) return false;
  final wanted = {for (final name in defaultExclusions) name.toUpperCase()};
  final present = {for (final name in names) name.toUpperCase()};
  return present.length == wanted.length && present.containsAll(wanted);
}

List<IgnoredDeviceView> ignoredDeviceViews(List<IgnoredDevice> devices) {
  final views = [
    for (final device in devices)
      IgnoredDeviceView(
        fingerprint: device.fingerprint,
        name: sanitizeDisplayName(device.name) ?? '',
        shortFingerprint: shortFingerprint(device.fingerprint),
        ignoredAt: device.ignoredAt,
      ),
  ];
  views.sort((a, b) {
    final byDate = b.ignoredAt.compareTo(a.ignoredAt);
    return byDate != 0 ? byDate : a.fingerprint.compareTo(b.fingerprint);
  });
  return views;
}

String? networkDisplayName(String networkId, String savedName) {
  if (savedName.isEmpty || savedName == networkId) return null;
  return sanitizeDisplayName(savedName);
}

List<TrustedNetworkView> trustedNetworkViews({
  required List<TrustedNetwork> trusted,
  required Set<String> connected,
  required int Function(String networkId) transfersOn,
  required bool Function(String networkId) pairingOn,
}) {
  final views = [
    for (final network in trusted)
      TrustedNetworkView(
        networkId: network.networkId,
        name: networkDisplayName(network.networkId, network.name),
        trustedAt: network.trustedAt,
        connected: connected.contains(network.networkId),
        transfers: connected.contains(network.networkId)
            ? transfersOn(network.networkId)
            : 0,
        pairing:
            connected.contains(network.networkId) &&
            pairingOn(network.networkId),
      ),
  ];
  views.sort((a, b) {
    if (a.connected != b.connected) return a.connected ? -1 : 1;
    final byDate = b.trustedAt.compareTo(a.trustedAt);
    return byDate != 0 ? byDate : a.networkId.compareTo(b.networkId);
  });
  return views;
}
