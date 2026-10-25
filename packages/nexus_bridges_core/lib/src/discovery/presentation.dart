import '../identity/identity.dart' show shortFingerprint;
import '../protocol/protocol.dart';
import 'registry.dart';

final RegExp _unicodeSpaces = RegExp(
  r'[\u0009-\u000D\u0020\u0085\u00A0\u1680\u2000-\u200A\u2028\u2029\u202F\u205F\u3000]+',
);

final RegExp _combiningMarks = RegExp(r'\p{M}', unicode: true);

const List<(int, int, String)> _latinBases = [
  (0xC0, 0xC5, 'a'),
  (0xC7, 0xC7, 'c'),
  (0xC8, 0xCB, 'e'),
  (0xCC, 0xCF, 'i'),
  (0xD1, 0xD1, 'n'),
  (0xD2, 0xD6, 'o'),
  (0xD8, 0xD8, 'o'),
  (0xD9, 0xDC, 'u'),
  (0xDD, 0xDD, 'y'),
  (0xE0, 0xE5, 'a'),
  (0xE7, 0xE7, 'c'),
  (0xE8, 0xEB, 'e'),
  (0xEC, 0xEF, 'i'),
  (0xF1, 0xF1, 'n'),
  (0xF2, 0xF6, 'o'),
  (0xF8, 0xF8, 'o'),
  (0xF9, 0xFC, 'u'),
  (0xFD, 0xFD, 'y'),
  (0xFF, 0xFF, 'y'),
  (0x100, 0x105, 'a'),
  (0x106, 0x10D, 'c'),
  (0x10E, 0x111, 'd'),
  (0x112, 0x11B, 'e'),
  (0x11C, 0x123, 'g'),
  (0x124, 0x127, 'h'),
  (0x128, 0x131, 'i'),
  (0x134, 0x135, 'j'),
  (0x136, 0x137, 'k'),
  (0x139, 0x142, 'l'),
  (0x143, 0x148, 'n'),
  (0x14C, 0x151, 'o'),
  (0x154, 0x159, 'r'),
  (0x15A, 0x161, 's'),
  (0x162, 0x167, 't'),
  (0x168, 0x173, 'u'),
  (0x174, 0x175, 'w'),
  (0x176, 0x178, 'y'),
  (0x179, 0x17E, 'z'),
  (0x17F, 0x17F, 's'),
];

String _baseOf(int rune) {
  if (rune >= 0xC0 && rune <= 0x17F) {
    for (final (first, last, base) in _latinBases) {
      if (rune >= first && rune <= last) return base;
    }
  }
  return String.fromCharCode(rune);
}

String foldedName(String name) {
  final lower = name.toLowerCase().replaceAll(_combiningMarks, '');
  final folded = StringBuffer();
  for (final rune in lower.runes) {
    folded.write(_baseOf(rune));
  }
  return folded.toString();
}

String similarityKey(String name) =>
    foldedName(name).replaceAll(_unicodeSpaces, ' ').trim();

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
      final key = similarityKey(name);
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
  return (uses[similarityKey(name)] ?? 0) > 1 ? '$name · $short' : name;
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
