import '../identity/identity.dart' show shortFingerprint;
import '../protocol/protocol.dart';
import 'registry.dart';

final RegExp _unicodeSpaces = RegExp(
  r'[\u0009-\u000D\u0020\u0085\u00A0\u1680\u2000-\u200A\u2028\u2029\u202F\u205F\u3000]+',
);

String _similarityKey(String name) =>
    name.toLowerCase().replaceAll(_unicodeSpaces, ' ').trim();

Map<String, String> displayNames(List<DiscoveredDevice> devices) {
  return displayNamesFor([
    for (final device in devices) (device.info.fingerprint, device.info.name),
  ]);
}

Map<String, String> displayNamesFor(
  List<(String fingerprint, String? name)> devices,
) {
  final uses = <String, int>{};
  for (final (_, name) in devices) {
    if (name != null) {
      final key = _similarityKey(name);
      uses[key] = (uses[key] ?? 0) + 1;
    }
  }
  return {
    for (final (fingerprint, name) in devices)
      fingerprint: _displayNameOf(fingerprint, name, uses),
  };
}

String _displayNameOf(String fingerprint, String? name, Map<String, int> uses) {
  final short = shortFingerprint(fingerprint);
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
