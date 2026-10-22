import '../protocol/protocol.dart';
import 'registry.dart';

const int _shortFingerprintLength = 8;

String _shortFingerprint(String fingerprint) =>
    fingerprint.length > _shortFingerprintLength
    ? fingerprint.substring(0, _shortFingerprintLength)
    : fingerprint;

final RegExp _unicodeSpaces = RegExp(
  r'[\u0009-\u000D\u0020\u0085\u00A0\u1680\u2000-\u200A\u2028\u2029\u202F\u205F\u3000]+',
);

String _similarityKey(String name) =>
    name.toLowerCase().replaceAll(_unicodeSpaces, ' ').trim();

Map<String, String> displayNames(List<DiscoveredDevice> devices) {
  final uses = <String, int>{};
  for (final device in devices) {
    final name = device.info.name;
    if (name != null) {
      final key = _similarityKey(name);
      uses[key] = (uses[key] ?? 0) + 1;
    }
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
  return (uses[_similarityKey(name)] ?? 0) > 1 ? '$name · $short' : name;
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
