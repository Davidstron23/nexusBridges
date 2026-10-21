import 'dart:async';
import 'dart:convert';

import 'package:crypto/crypto.dart';

import '../storage/storage.dart';

enum Permission { send, receive, browse }

const String _pemBegin = '-----BEGIN CERTIFICATE-----';
const String _pemEnd = '-----END CERTIFICATE-----';

final RegExp _fingerprintPattern = RegExp(r'^[0-9A-F]{64}$');
final RegExp _whitespace = RegExp(r'\s+');

List<int> _certificateDerOf(String pem) {
  final begin = pem.indexOf(_pemBegin);
  if (begin < 0 || pem.indexOf(_pemBegin, begin + 1) >= 0) {
    throw const FormatException('certificate is not a single PEM block');
  }
  final bodyStart = begin + _pemBegin.length;
  final end = pem.indexOf(_pemEnd, bodyStart);
  if (end < 0 || pem.indexOf(_pemEnd, end + 1) >= 0) {
    throw const FormatException('certificate is not a single PEM block');
  }
  if (pem.substring(0, begin).trim().isNotEmpty ||
      pem.substring(end + _pemEnd.length).trim().isNotEmpty) {
    throw const FormatException('certificate has data outside the PEM block');
  }
  final body = pem.substring(bodyStart, end).replaceAll(_whitespace, '');
  if (body.isEmpty || body.contains('-')) {
    throw const FormatException('certificate body is not valid');
  }
  final List<int> der;
  try {
    der = base64.decode(body);
  } on FormatException {
    throw const FormatException('certificate body is not valid base64');
  }
  if (der.isEmpty) {
    throw const FormatException('certificate body is empty');
  }
  return der;
}

void _checkPairedIdentity(String fingerprint, String certificatePem) {
  if (!_fingerprintPattern.hasMatch(fingerprint)) {
    throw const FormatException('fingerprint has an invalid format');
  }
  final der = _certificateDerOf(certificatePem);
  if (sha256.convert(der).toString().toUpperCase() != fingerprint) {
    throw const FormatException('fingerprint does not match the certificate');
  }
}

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
    _checkPairedIdentity(fingerprint, certificatePem);
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
    for (var i = 0; i < copy.length; i++) {
      try {
        _checkPairedIdentity(copy[i].fingerprint, copy[i].certificatePem);
      } on FormatException catch (e) {
        throw ArgumentError.value(
          i,
          'devices',
          'invalid paired device: ${e.message}',
        );
      }
    }
    await _store.write({
      'version': 1,
      'devices': [for (final d in copy) d.toJson()],
    });
    _devices = copy;
    _changes.add(null);
  }
}
