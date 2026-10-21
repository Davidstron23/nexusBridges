import 'dart:async';

import '../storage/storage.dart';

enum Permission { send, receive, browse }

final class PairedDevice {
  const PairedDevice({
    required this.fingerprint,
    required this.name,
    required this.certificatePem,
    required this.permissions,
    required this.pairedAt,
  });

  final String fingerprint;

  final String name;

  final String certificatePem;

  final Set<Permission> permissions;

  final DateTime pairedAt;

  Map<String, Object?> toJson() => {
    'fingerprint': fingerprint,
    'name': name,
    'certificatePem': certificatePem,
    'permissions': [for (final p in permissions) p.name],
    'pairedAt': pairedAt.toUtc().toIso8601String(),
  };

  static PairedDevice fromJson(Object? json) {
    if (json is! Map<String, Object?>) {
      throw const FormatException('device is not a JSON object');
    }
    final fingerprint = json['fingerprint'];
    final name = json['name'];
    final certificatePem = json['certificatePem'];
    final permissions = json['permissions'];
    final pairedAt = json['pairedAt'];
    if (fingerprint is! String ||
        name is! String ||
        certificatePem is! String ||
        permissions is! List<Object?> ||
        pairedAt is! String) {
      throw const FormatException('device has missing or invalid fields');
    }
    final known = Permission.values.asNameMap();
    return PairedDevice(
      fingerprint: fingerprint,
      name: name,
      certificatePem: certificatePem,
      permissions: {
        for (final p in permissions)
          if (p is String && known[p] != null) known[p]!,
      },
      pairedAt: DateTime.parse(pairedAt).toUtc(),
    );
  }
}

final class PairedDevicesStore {
  PairedDevicesStore(this._store, {DateTime Function() now = DateTime.now})
    : _clock = now;

  final JsonFileStore _store;
  final DateTime Function() _clock;
  final StreamController<void> _changes = StreamController<void>.broadcast();

  List<PairedDevice> _devices = const [];

  List<PairedDevice> get devices => _devices;

  Stream<void> get changes => _changes.stream;

  Future<void> load() async {
    try {
      final json = await _store.read();
      if (json == null) {
        _devices = const [];
        return;
      }
      final raw = json['devices'];
      if (raw is! List<Object?>) {
        throw const FormatException('devices is not a list');
      }
      _devices = List.unmodifiable(raw.map(PairedDevice.fromJson));
    } on FormatException {
      _devices = const [];
      await _store.quarantine(_clock());
    }
  }

  bool isPaired(String fingerprint) =>
      _devices.any((d) => d.fingerprint == fingerprint);

  Future<void> replaceAll(List<PairedDevice> devices) async {
    final copy = List<PairedDevice>.unmodifiable(devices);
    await _store.write({
      'version': 1,
      'devices': [for (final d in copy) d.toJson()],
    });
    _devices = copy;
    _changes.add(null);
  }
}
