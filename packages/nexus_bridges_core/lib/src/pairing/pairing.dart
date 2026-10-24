import 'dart:async';

import '../identity/identity.dart';
import '../storage/storage.dart';

enum Permission { send, receive, browse }

enum PeerRelation { mine, foreign }

Set<Permission> permissionsFor(PeerRelation relation) => switch (relation) {
  PeerRelation.mine => const {
    Permission.send,
    Permission.receive,
    Permission.browse,
  },
  PeerRelation.foreign => const {Permission.receive},
};

const int _maxNameRunes = 64;

String _clipName(String name) =>
    String.fromCharCodes(name.runes.take(_maxNameRunes));

final RegExp _fingerprintPattern = RegExp(r'^[0-9A-F]{64}$');

void _checkPairedIdentity(String fingerprint, String certificatePem) {
  if (!_fingerprintPattern.hasMatch(fingerprint)) {
    throw const FormatException('fingerprint has an invalid format');
  }
  final certificate = PeerCertificate.tryParse(certificatePem);
  if (certificate == null) {
    throw const FormatException('certificate is not valid');
  }
  if (certificate.fingerprint != fingerprint) {
    throw const FormatException('fingerprint does not match the certificate');
  }
}

final class PairedDevice {
  const PairedDevice({
    required this.fingerprint,
    required this.name,
    required this.certificatePem,
    required this.relation,
    required this.pairedAt,
  });

  final String fingerprint;

  final String name;

  final String certificatePem;

  final PeerRelation relation;

  final DateTime pairedAt;

  Set<Permission> get permissions => permissionsFor(relation);

  PairedDevice copyWith({String? name, PeerRelation? relation}) {
    return PairedDevice(
      fingerprint: fingerprint,
      name: name ?? this.name,
      certificatePem: certificatePem,
      relation: relation ?? this.relation,
      pairedAt: pairedAt,
    );
  }

  Map<String, Object?> toJson() => {
    'fingerprint': fingerprint,
    'name': name,
    'certificatePem': certificatePem,
    'relation': relation.name,
    'pairedAt': pairedAt.toUtc().toIso8601String(),
  };

  static PairedDevice fromJson(Object? json) {
    if (json is! Map<String, Object?>) {
      throw const FormatException('device is not a JSON object');
    }
    final fingerprint = json['fingerprint'];
    final name = json['name'];
    final certificatePem = json['certificatePem'];
    final relation = json['relation'];
    final pairedAt = json['pairedAt'];
    if (fingerprint is! String ||
        name is! String ||
        certificatePem is! String ||
        relation is! String ||
        pairedAt is! String) {
      throw const FormatException('device has missing or invalid fields');
    }
    _checkPairedIdentity(fingerprint, certificatePem);
    final parsedRelation = PeerRelation.values.asNameMap()[relation];
    if (parsedRelation == null) {
      throw const FormatException('relation is not valid');
    }
    if (name.runes.length > _maxNameRunes) {
      throw const FormatException('name is too long');
    }
    return PairedDevice(
      fingerprint: fingerprint,
      name: name,
      certificatePem: certificatePem,
      relation: parsedRelation,
      pairedAt: DateTime.parse(pairedAt).toUtc(),
    );
  }
}

enum PairedLoadResult { missing, loaded, quarantined, previousIdentity }

enum AddResult { added, alreadyPaired, duplicateSubject, full, notSaved }

String? _canonicalNameOf(PairedDevice device) =>
    PeerCertificate.tryParse(device.certificatePem)?.canonicalName;

final class PairedDevicesStore {
  PairedDevicesStore(
    this._store, {
    required String ownerFingerprint,
    DateTime Function() now = DateTime.now,
  }) : _owner = ownerFingerprint,
       _clock = now;

  static const int maxDevices = 32;

  final JsonFileStore _store;
  final String _owner;
  final DateTime Function() _clock;
  final StreamController<void> _changes = StreamController<void>.broadcast();
  final StreamController<void> _saveStatus = StreamController<void>.broadcast();

  List<PairedDevice> _devices = const [];
  bool _unsaved = false;
  Future<void> _tail = Future<void>.value();

  List<PairedDevice> get devices => _devices;

  bool get hasUnsavedChanges => _unsaved;

  Stream<void> get changes => _changes.stream;

  Stream<void> get saveStatusChanges => _saveStatus.stream;

  Future<PairedLoadResult> load() async {
    try {
      final json = await _store.readVersioned(2);
      if (json == null) {
        _devices = const [];
        return PairedLoadResult.missing;
      }
      final owner = json['owner'];
      if (owner is! String || !_fingerprintPattern.hasMatch(owner)) {
        throw const FormatException('owner is not valid');
      }
      if (owner != _owner) {
        _devices = const [];
        await _store.quarantine(_clock(), reason: 'previous-identity');
        return PairedLoadResult.previousIdentity;
      }
      _devices = _parseDevices(json['devices']);
      return PairedLoadResult.loaded;
    } on FormatException {
      _devices = const [];
      await _store.quarantine(_clock());
      return PairedLoadResult.quarantined;
    }
  }

  PairedDevice? deviceOf(String fingerprint) {
    for (final device in _devices) {
      if (device.fingerprint == fingerprint) return device;
    }
    return null;
  }

  bool isPaired(String fingerprint) => deviceOf(fingerprint) != null;

  Future<AddResult> add(
    PairedDevice given, {
    Duration timeout = const Duration(seconds: 10),
  }) async {
    final device = given.copyWith(name: _clipName(given.name));
    try {
      _checkPairedIdentity(device.fingerprint, device.certificatePem);
    } on FormatException catch (e) {
      throw ArgumentError.value(
        device.fingerprint,
        'device',
        'invalid paired device: ${e.message}',
      );
    }
    final canonical = _canonicalNameOf(device)!;
    final refused = _refusalFor(device, canonical);
    if (refused != null) return refused;

    var abandoned = false;
    final attempt = _enqueue<AddResult>(() async {
      if (abandoned) return AddResult.notSaved;
      final again = _refusalFor(device, canonical);
      if (again != null) return again;
      final written = await _persist([..._devices, device]);
      if (abandoned) {
        unawaited(_enqueue(_writeMemory));
        return AddResult.notSaved;
      }
      if (!written) return AddResult.notSaved;
      _devices = List.unmodifiable([..._devices, device]);
      _changes.add(null);
      return AddResult.added;
    });
    return attempt.timeout(
      timeout,
      onTimeout: () {
        abandoned = true;
        return AddResult.notSaved;
      },
    );
  }

  Future<bool> remove(String fingerprint) {
    if (!isPaired(fingerprint)) return Future<bool>.value(true);
    _devices = List.unmodifiable([
      for (final d in _devices)
        if (d.fingerprint != fingerprint) d,
    ]);
    _changes.add(null);
    return _enqueue(_writeMemory);
  }

  Future<bool> setRelation(String fingerprint, PeerRelation relation) {
    return _update(fingerprint, (d) => d.copyWith(relation: relation));
  }

  Future<bool> rename(String fingerprint, String name) {
    final clipped = _clipName(name);
    return _update(fingerprint, (d) => d.copyWith(name: clipped), silent: true);
  }

  Future<bool> retrySave() => _enqueue(_writeMemory);

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
    await _enqueue<void>(() async {
      try {
        await _store.write(_jsonOf(copy));
      } catch (_) {
        _setUnsaved(true);
        rethrow;
      }
      _setUnsaved(false);
      _devices = copy;
      _changes.add(null);
    });
  }

  Future<bool> _update(
    String fingerprint,
    PairedDevice Function(PairedDevice) change, {
    bool silent = false,
  }) {
    final index = _devices.indexWhere((d) => d.fingerprint == fingerprint);
    if (index < 0) return Future<bool>.value(false);
    final current = _devices[index];
    final updated = change(current);
    if (updated.name != current.name || updated.relation != current.relation) {
      _devices = List.unmodifiable([..._devices]..[index] = updated);
      _changes.add(null);
    }
    return _enqueue(() => _persist(_devices, silent: silent));
  }

  AddResult? _refusalFor(PairedDevice device, String canonical) {
    if (isPaired(device.fingerprint)) return AddResult.alreadyPaired;
    if (_devices.length >= maxDevices) return AddResult.full;
    if (_devices.any((d) => _canonicalNameOf(d) == canonical)) {
      return AddResult.duplicateSubject;
    }
    return null;
  }

  Future<T> _enqueue<T>(Future<T> Function() action) {
    final run = _tail.then((_) => action());
    _tail = run.then((_) {}, onError: (Object _) {});
    return run;
  }

  Future<bool> _writeMemory() => _persist(_devices);

  Future<bool> _persist(
    List<PairedDevice> devices, {
    bool silent = false,
  }) async {
    try {
      await _store.write(_jsonOf(devices));
    } on Exception {
      if (!silent) _setUnsaved(true);
      return false;
    }
    _setUnsaved(false);
    return true;
  }

  void _setUnsaved(bool value) {
    if (_unsaved == value) return;
    _unsaved = value;
    _saveStatus.add(null);
  }

  Map<String, Object?> _jsonOf(List<PairedDevice> devices) => {
    'version': 2,
    'owner': _owner,
    'devices': [for (final d in devices) d.toJson()],
  };

  static List<PairedDevice> _parseDevices(Object? raw) {
    if (raw is! List<Object?>) {
      throw const FormatException('devices is not a list');
    }
    final fingerprints = <String>{};
    final subjects = <String>{};
    final result = <PairedDevice>[];
    for (final item in raw) {
      final device = PairedDevice.fromJson(item);
      if (!fingerprints.add(device.fingerprint)) {
        throw const FormatException('fingerprint is repeated');
      }
      if (!subjects.add(_canonicalNameOf(device)!)) {
        throw const FormatException('subject name is repeated');
      }
      result.add(device);
    }
    return List.unmodifiable(result);
  }
}

enum IgnoreResult { ignored, notSaved, refused }

final class IgnoredDevice {
  const IgnoredDevice({
    required this.fingerprint,
    required this.name,
    required this.ignoredAt,
  });

  final String fingerprint;

  final String name;

  final DateTime ignoredAt;

  Map<String, Object?> toJson() => {
    'fingerprint': fingerprint,
    'name': name,
    'ignoredAt': ignoredAt.toUtc().toIso8601String(),
  };

  static IgnoredDevice fromJson(Object? json) {
    if (json is! Map<String, Object?>) {
      throw const FormatException('ignored device is not a JSON object');
    }
    final fingerprint = json['fingerprint'];
    final name = json['name'];
    final ignoredAt = json['ignoredAt'];
    if (fingerprint is! String || name is! String || ignoredAt is! String) {
      throw const FormatException(
        'ignored device has missing or invalid fields',
      );
    }
    if (!_fingerprintPattern.hasMatch(fingerprint)) {
      throw const FormatException('fingerprint has an invalid format');
    }
    if (name.runes.length > _maxNameRunes) {
      throw const FormatException('name is too long');
    }
    return IgnoredDevice(
      fingerprint: fingerprint,
      name: name,
      ignoredAt: DateTime.parse(ignoredAt).toUtc(),
    );
  }
}

final class IgnoredDevicesStore {
  IgnoredDevicesStore(
    this._store, {
    required bool Function(String fingerprint) isPaired,
    DateTime Function() now = DateTime.now,
  }) : _pairedCheck = isPaired,
       _clock = now;

  static const int maxDevices = 256;

  final JsonFileStore _store;
  final bool Function(String fingerprint) _pairedCheck;
  final DateTime Function() _clock;
  final StreamController<void> _changes = StreamController<void>.broadcast();
  final StreamController<void> _saveStatus = StreamController<void>.broadcast();

  List<IgnoredDevice> _devices = const [];
  bool _unsaved = false;
  Future<void> _tail = Future<void>.value();

  List<IgnoredDevice> get devices => _devices;

  bool get hasUnsavedChanges => _unsaved;

  Stream<void> get changes => _changes.stream;

  Stream<void> get saveStatusChanges => _saveStatus.stream;

  bool isIgnored(String fingerprint) {
    return _devices.any((d) => d.fingerprint == fingerprint);
  }

  Future<void> load() async {
    try {
      final json = await _store.readVersioned(1);
      if (json == null) {
        _devices = const [];
        return;
      }
      _devices = _parseDevices(json['devices']);
    } on FormatException {
      _devices = const [];
      await _store.quarantine(_clock());
    }
  }

  Future<IgnoreResult> ignore(String fingerprint, {required String name}) {
    if (!_fingerprintPattern.hasMatch(fingerprint)) {
      return Future<IgnoreResult>.error(
        ArgumentError.value(
          fingerprint,
          'fingerprint',
          'fingerprint has an invalid format',
        ),
      );
    }
    if (_pairedCheck(fingerprint)) {
      return Future<IgnoreResult>.value(IgnoreResult.refused);
    }
    final entry = IgnoredDevice(
      fingerprint: fingerprint,
      name: _clipName(name),
      ignoredAt: _clock().toUtc(),
    );
    final list = [..._devices];
    final index = list.indexWhere((d) => d.fingerprint == fingerprint);
    if (index >= 0) {
      list[index] = entry;
    } else {
      list.add(entry);
      if (list.length > maxDevices) {
        var oldest = 0;
        for (var i = 1; i < list.length; i++) {
          if (list[i].ignoredAt.isBefore(list[oldest].ignoredAt)) oldest = i;
        }
        list.removeAt(oldest);
      }
    }
    _devices = List.unmodifiable(list);
    _changes.add(null);
    return _enqueue(_writeMemory)
        .then((saved) => saved ? IgnoreResult.ignored : IgnoreResult.notSaved);
  }

  Future<bool> unignore(String fingerprint) {
    if (!isIgnored(fingerprint)) return Future<bool>.value(true);
    _devices = List.unmodifiable([
      for (final d in _devices)
        if (d.fingerprint != fingerprint) d,
    ]);
    _changes.add(null);
    return _enqueue(_writeMemory);
  }

  Future<bool> retrySave() => _enqueue(_writeMemory);

  Future<T> _enqueue<T>(Future<T> Function() action) {
    final run = _tail.then((_) => action());
    _tail = run.then((_) {}, onError: (Object _) {});
    return run;
  }

  Future<bool> _writeMemory() async {
    try {
      await _store.write(_jsonOf(_devices));
    } on Exception {
      _setUnsaved(true);
      return false;
    }
    _setUnsaved(false);
    return true;
  }

  void _setUnsaved(bool value) {
    if (_unsaved == value) return;
    _unsaved = value;
    _saveStatus.add(null);
  }

  Map<String, Object?> _jsonOf(List<IgnoredDevice> devices) => {
    'version': 1,
    'devices': [for (final d in devices) d.toJson()],
  };

  static List<IgnoredDevice> _parseDevices(Object? raw) {
    if (raw is! List<Object?>) {
      throw const FormatException('devices is not a list');
    }
    final fingerprints = <String>{};
    final parsed = <IgnoredDevice>[];
    for (final item in raw) {
      final device = IgnoredDevice.fromJson(item);
      if (!fingerprints.add(device.fingerprint)) {
        throw const FormatException('fingerprint is repeated');
      }
      parsed.add(device);
    }
    if (parsed.length <= maxDevices) return List.unmodifiable(parsed);
    final ranked = [for (var i = 0; i < parsed.length; i++) i]
      ..sort((a, b) {
        final byDate = parsed[b].ignoredAt.compareTo(parsed[a].ignoredAt);
        return byDate != 0 ? byDate : b.compareTo(a);
      });
    final keep = ranked.take(maxDevices).toSet();
    return List.unmodifiable([
      for (var i = 0; i < parsed.length; i++)
        if (keep.contains(i)) parsed[i],
    ]);
  }
}
