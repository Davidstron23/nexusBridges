import '../protocol/protocol.dart';
import 'registry.dart';

const int _shortFingerprintLength = 8;

String _shortFingerprint(String fingerprint) =>
    fingerprint.length > _shortFingerprintLength
    ? fingerprint.substring(0, _shortFingerprintLength)
    : fingerprint;

Map<String, String> displayNames(List<DiscoveredDevice> devices) {
  final uses = <String, int>{};
  for (final device in devices) {
    final name = device.info.name;
    if (name != null) uses[name] = (uses[name] ?? 0) + 1;
  }
  return {
    for (final device in devices)
      device.info.fingerprint: _displayNameOf(device.info, uses),
  };
}

String _displayNameOf(DeviceInfo info, Map<String, int> uses) {
  final short = _shortFingerprint(info.fingerprint);
  final name = info.name;
  if (name == null) return short;
  return (uses[name] ?? 0) > 1 ? '$name · $short' : name;
}

bool shouldSuggestRescan({
  required bool anyActive,
  required DateTime? emptySince,
  required DateTime now,
}) {
  return anyActive &&
      emptySince != null &&
      now.difference(emptySince) >= Limits.rescanHintAfter;
}
