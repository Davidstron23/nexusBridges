import '../discovery/discovery.dart' show DiscoveredDevice, displayNamesFor;
import '../pairing/pairing.dart' show PairedDevice, PeerRelation;
import '../protocol/protocol.dart' show sanitizeDisplayName;
import 'node_state.dart' show DeviceEntry;

bool sameName(String? a, String? b) {
  if (a == null || b == null) return false;
  final left = sanitizeDisplayName(a);
  final right = sanitizeDisplayName(b);
  return left != null &&
      right != null &&
      left.toLowerCase() == right.toLowerCase();
}

PairedDevice? findReplaced({
  required String? name,
  required String excluding,
  required List<PairedDevice> paired,
  required bool Function(String) isVisible,
}) {
  if (name == null) return null;
  PairedDevice? newest;
  for (final other in paired) {
    if (other.fingerprint == excluding || isVisible(other.fingerprint)) {
      continue;
    }
    if (!sameName(name, other.name)) continue;
    if (newest == null || other.pairedAt.isAfter(newest.pairedAt)) {
      newest = other;
    }
  }
  return newest;
}

final class _Row {
  const _Row(this.fingerprint, this.name, this.device, this.stored);

  final String fingerprint;
  final String? name;
  final DiscoveredDevice? device;
  final PairedDevice? stored;
}

String? _cleanName(String? name) =>
    name == null ? null : sanitizeDisplayName(name);

List<DeviceEntry> buildEntries({
  required List<DiscoveredDevice> visible,
  required List<PairedDevice> paired,
  required bool Function(String) isIgnored,
  required Set<String> mismatched,
}) {
  final storedBy = {for (final device in paired) device.fingerprint: device};
  final visibleBy = <String, DiscoveredDevice>{};
  for (final device in visible) {
    visibleBy.putIfAbsent(device.info.fingerprint, () => device);
  }
  final rows = <_Row>[
    for (final MapEntry(:key, :value) in visibleBy.entries)
      _Row(key, _cleanName(value.info.name), value, storedBy[key]),
    for (final device in paired)
      if (!visibleBy.containsKey(device.fingerprint))
        _Row(device.fingerprint, _cleanName(device.name), null, device),
  ];
  final names = displayNamesFor([
    for (final row in rows) (row.fingerprint, row.name),
  ]);
  final entries = [
    for (final row in rows)
      DeviceEntry(
        fingerprint: row.fingerprint,
        displayName: names[row.fingerprint]!,
        deviceType: row.device?.info.deviceType,
        visible: row.device != null,
        paired: row.stored != null,
        mine: row.stored?.relation == PeerRelation.mine,
        ignored:
            row.device != null &&
            row.stored == null &&
            isIgnored(row.fingerprint),
        mismatch:
            row.device != null &&
            row.stored != null &&
            mismatched.contains(row.fingerprint),
        possiblyReplaces: _possiblyReplaces(row, paired, visibleBy, names),
      ),
  ];
  entries.sort((a, b) {
    final byName = a.displayName.toLowerCase().compareTo(
      b.displayName.toLowerCase(),
    );
    return byName != 0 ? byName : a.fingerprint.compareTo(b.fingerprint);
  });
  return entries;
}

String? _possiblyReplaces(
  _Row row,
  List<PairedDevice> paired,
  Map<String, DiscoveredDevice> visibleBy,
  Map<String, String> names,
) {
  if (row.device == null || row.stored != null) return null;
  final old = findReplaced(
    name: row.name,
    excluding: row.fingerprint,
    paired: paired,
    isVisible: visibleBy.containsKey,
  );
  return old == null ? null : names[old.fingerprint];
}
