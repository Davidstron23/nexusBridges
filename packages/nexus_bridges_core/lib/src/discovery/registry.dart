import 'dart:io';

import '../protocol/protocol.dart';

const int _maxUnpairedPerAddress = 4;

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
  const Verify(
    this.info,
    this.address,
    this.interfaceId, {
    this.rename = false,
  });

  final DeviceInfo info;

  final InternetAddress address;

  final String interfaceId;

  final bool rename;
}

final class VerifyGoodbye extends RegistryAction {
  const VerifyGoodbye(this.info, this.address, this.interfaceId);

  final DeviceInfo info;

  final InternetAddress address;

  final String interfaceId;
}

final class _Entry {
  _Entry(
    this.info,
    this.address,
    this.interfaceId,
    this.lastSeen,
    this.seenAt, {
    required this.fromScan,
  });

  DeviceInfo info;

  InternetAddress address;

  String interfaceId;

  DateTime lastSeen;

  Duration seenAt;

  bool fromScan;
}

final class DiscoveryRegistry {
  DiscoveryRegistry({
    required this._selfFingerprint,
    required this._isPaired,
    this._now = DateTime.now,
    this._clock = monotonicClock,
  });

  final String _selfFingerprint;

  final bool Function(String) _isPaired;

  final DateTime Function() _now;

  final Duration Function() _clock;

  final Map<String, _Entry> _entries = {};

  final Map<String, Duration> _heardAt = {};

  final Map<String, Duration> _renameChecks = {};

  DiscoveredDevice _deviceOf(_Entry entry) => DiscoveredDevice(
    info: entry.info,
    address: entry.address,
    interfaceId: entry.interfaceId,
    paired: _isPaired(entry.info.fingerprint),
    lastSeen: entry.lastSeen,
  );

  List<DiscoveredDevice> get devices {
    final list = [for (final entry in _entries.values) _deviceOf(entry)];
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
        if (_isPaired(fingerprint)) {
          return VerifyGoodbye(known.info, known.address, known.interfaceId);
        }
        _entries.remove(fingerprint);
        _heardAt.remove(fingerprint);
        return const Refreshed();
      }
      return const Ignore();
    }
    if (known != null && known.address.address == from.address) {
      if (a.info.name != known.info.name && _renameCheckDue(fingerprint)) {
        return Verify(
          known.info,
          known.address,
          known.interfaceId,
          rename: true,
        );
      }
      if (known.fromScan && known.interfaceId == interfaceId) {
        _heardAt[fingerprint] = _clock();
      }
      known
        ..lastSeen = _now()
        ..seenAt = _clock();
      return const Refreshed();
    }
    if (known != null) return Verify(a.info, from, interfaceId);
    if (_unpairedLimitReached(fingerprint, from)) return const Ignore();
    return Verify(a.info, from, interfaceId);
  }

  bool _renameCheckDue(String fingerprint) {
    final clock = _clock();
    final last = _renameChecks[fingerprint];
    if (last != null && clock - last < Limits.renameCheckInterval) {
      return false;
    }
    _renameChecks[fingerprint] = clock;
    return true;
  }

  bool onVerified(
    DeviceInfo info,
    InternetAddress address,
    String interfaceId, {
    bool fromScan = false,
  }) {
    final fingerprint = info.fingerprint;
    if (fingerprint == _selfFingerprint) return false;
    final known = _entries[fingerprint];
    if (known == null) {
      if (_unpairedLimitReached(fingerprint, address)) return false;
      _entries[fingerprint] = _Entry(
        info,
        address,
        interfaceId,
        _now(),
        _clock(),
        fromScan: fromScan,
      );
      return true;
    }
    if (known.address.address != address.address &&
        _addressLimitReached(fingerprint, address)) {
      return false;
    }
    known
      ..info = info
      ..address = address
      ..interfaceId = interfaceId
      ..lastSeen = _now()
      ..seenAt = _clock();
    if (fromScan) known.fromScan = true;
    return true;
  }

  bool onGoodbyeFailed(String fingerprint, InternetAddress address) {
    final known = _entries[fingerprint];
    if (known == null || known.address.address != address.address) {
      return false;
    }
    _entries.remove(fingerprint);
    _heardAt.remove(fingerprint);
    return true;
  }

  List<DiscoveredDevice> dueForPresentation(Duration quiet) {
    final clock = _clock();
    return [
      for (final MapEntry(:key, :value) in _entries.entries)
        if (value.fromScan &&
            (_heardAt[key] == null || clock - _heardAt[key]! >= quiet))
          _deviceOf(value),
    ];
  }

  List<String> expire() {
    final now = _now();
    final clock = _clock();
    final expired = [
      for (final MapEntry(:key, :value) in _entries.entries)
        if (value.fromScan
            ? clock - value.seenAt >= Limits.expireAfter
            : now.difference(value.lastSeen) > Limits.expireAfter)
          key,
    ];
    expired.forEach(_entries.remove);
    expired.forEach(_heardAt.remove);
    _heardAt.removeWhere((_, heard) => clock - heard >= Limits.expireAfter);
    _renameChecks.removeWhere(
      (key, checked) =>
          !_entries.containsKey(key) ||
          clock - checked >= Limits.renameCheckInterval,
    );
    return expired;
  }

  void dropInterface(String interfaceId) {
    final dropped = [
      for (final MapEntry(:key, :value) in _entries.entries)
        if (value.interfaceId == interfaceId) key,
    ];
    dropped.forEach(_entries.remove);
    dropped.forEach(_heardAt.remove);
  }

  bool _unpairedLimitReached(String fingerprint, InternetAddress address) {
    if (_isPaired(fingerprint)) return false;
    final unpaired = _entries.keys.where((key) => !_isPaired(key)).length;
    if (unpaired >= Limits.maxListedUnpaired) return true;
    return _addressLimitReached(fingerprint, address);
  }

  bool _addressLimitReached(String fingerprint, InternetAddress address) {
    if (_isPaired(fingerprint)) return false;
    final sameAddress = _entries.entries
        .where(
          (entry) =>
              entry.key != fingerprint &&
              entry.value.address.address == address.address &&
              !_isPaired(entry.key),
        )
        .length;
    return sameAddress >= _maxUnpairedPerAddress;
  }
}
