import 'dart:io';

import '../protocol/protocol.dart';

final class DiscoveredDevice {
  const DiscoveredDevice({
    required this.info,
    required this.address,
    required this.interfaceId,
    required this.paired,
    required this.lastSeen,
  });

  final DeviceInfo info;

  final InternetAddress address;

  final String interfaceId;

  final bool paired;

  final DateTime lastSeen;
}

sealed class RegistryAction {
  const RegistryAction();
}

final class Ignore extends RegistryAction {
  const Ignore();
}

final class Refreshed extends RegistryAction {
  const Refreshed();
}

final class Verify extends RegistryAction {
  const Verify(this.info, this.address, this.interfaceId);

  final DeviceInfo info;

  final InternetAddress address;

  final String interfaceId;
}

final class _Entry {
  _Entry(this.info, this.address, this.interfaceId, this.lastSeen);

  DeviceInfo info;

  InternetAddress address;

  String interfaceId;

  DateTime lastSeen;
}

final class DiscoveryRegistry {
  DiscoveryRegistry({
    required this._selfFingerprint,
    required this._isPaired,
    this._now = DateTime.now,
  });

  final String _selfFingerprint;

  final bool Function(String) _isPaired;

  final DateTime Function() _now;

  final Map<String, _Entry> _entries = {};

  List<DiscoveredDevice> get devices {
    final list = [
      for (final entry in _entries.values)
        DiscoveredDevice(
          info: entry.info,
          address: entry.address,
          interfaceId: entry.interfaceId,
          paired: _isPaired(entry.info.fingerprint),
          lastSeen: entry.lastSeen,
        ),
    ];
    list.sort((a, b) {
      final byName = (a.info.name ?? '').toLowerCase().compareTo(
        (b.info.name ?? '').toLowerCase(),
      );
      return byName != 0
          ? byName
          : a.info.fingerprint.compareTo(b.info.fingerprint);
    });
    return list;
  }

  RegistryAction onAnnouncement(
    Announcement a,
    InternetAddress from,
    String interfaceId,
  ) {
    final fingerprint = a.info.fingerprint;
    if (fingerprint == _selfFingerprint) return const Ignore();
    final known = _entries[fingerprint];
    if (a.kind == AnnouncementKind.bye) {
      if (known != null && known.address.address == from.address) {
        _entries.remove(fingerprint);
        return const Refreshed();
      }
      return const Ignore();
    }
    if (known != null && known.address.address == from.address) {
      known.lastSeen = _now();
      return const Refreshed();
    }
    if (known != null) return Verify(a.info, from, interfaceId);
    if (_unpairedLimitReached(fingerprint)) return const Ignore();
    return Verify(a.info, from, interfaceId);
  }

  bool onVerified(
    DeviceInfo info,
    InternetAddress address,
    String interfaceId,
  ) {
    final fingerprint = info.fingerprint;
    if (fingerprint == _selfFingerprint) return false;
    final known = _entries[fingerprint];
    if (known == null) {
      if (_unpairedLimitReached(fingerprint)) return false;
      _entries[fingerprint] = _Entry(info, address, interfaceId, _now());
      return true;
    }
    known
      ..info = info
      ..address = address
      ..interfaceId = interfaceId
      ..lastSeen = _now();
    return true;
  }

  List<String> expire() {
    final now = _now();
    final expired = [
      for (final MapEntry(:key, :value) in _entries.entries)
        if (now.difference(value.lastSeen) > Limits.expireAfter) key,
    ];
    expired.forEach(_entries.remove);
    return expired;
  }

  void dropInterface(String interfaceId) {
    _entries.removeWhere((_, entry) => entry.interfaceId == interfaceId);
  }

  bool _unpairedLimitReached(String fingerprint) {
    if (_isPaired(fingerprint)) return false;
    final unpaired = _entries.keys.where((key) => !_isPaired(key)).length;
    return unpaired >= Limits.maxListedUnpaired;
  }
}
