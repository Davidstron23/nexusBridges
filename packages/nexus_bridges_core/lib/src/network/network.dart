import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import '../storage/storage.dart';

export 'windows_snapshot_reader.dart' show WindowsNetworkSnapshotReader;

void _noLog(String message) {}

int? _ipv4ToInt(InternetAddress address) {
  if (address.type != InternetAddressType.IPv4) return null;
  final raw = address.rawAddress;
  if (raw.length != 4) return null;
  return (raw[0] << 24) | (raw[1] << 16) | (raw[2] << 8) | raw[3];
}

InternetAddress _intToIpv4(int value) => InternetAddress.fromRawAddress(
  Uint8List.fromList([
    (value >> 24) & 0xFF,
    (value >> 16) & 0xFF,
    (value >> 8) & 0xFF,
    value & 0xFF,
  ]),
  type: InternetAddressType.IPv4,
);

int? _maskOf(int prefix) {
  if (prefix < 0 || prefix > 32) return null;
  return prefix == 0 ? 0 : (0xFFFFFFFF << (32 - prefix)) & 0xFFFFFFFF;
}

final class Ipv4Subnet {
  const Ipv4Subnet(this.address, this.prefixLength);

  final InternetAddress address;
  final int prefixLength;

  bool contains(InternetAddress other) {
    final own = _ipv4ToInt(address);
    final candidate = _ipv4ToInt(other);
    final mask = _maskOf(prefixLength);
    if (own == null || candidate == null || mask == null) return false;
    return (own & mask) == (candidate & mask);
  }

  List<InternetAddress> slash24Hosts() {
    final own = _ipv4ToInt(address);
    if (own == null) return const [];
    final base = own & 0xFFFFFF00;
    return [
      for (var host = 1; host <= 254; host++)
        if ((base | host) != own) _intToIpv4(base | host),
    ];
  }

  @override
  bool operator ==(Object other) =>
      other is Ipv4Subnet &&
      other.address == address &&
      other.prefixLength == prefixLength;

  @override
  int get hashCode => Object.hash(address, prefixLength);
}

final class AdapterInfo {
  const AdapterInfo({
    required this.id,
    required this.friendlyName,
    required this.description,
    required this.ifType,
    required this.isUp,
    required this.ipv4,
    required this.hasGateway,
    this.networkId,
    this.networkName,
  });

  final String id;
  final String friendlyName;
  final String description;
  final int ifType;
  final bool isUp;
  final List<Ipv4Subnet> ipv4;
  final bool hasGateway;
  final String? networkId;
  final String? networkName;
}

const int _loopbackIfType = 24;

const List<String> _virtualAdapterPatterns = [
  'hyper-v virtual ethernet',
  'virtualbox host-only',
  'vmware virtual ethernet',
  'vethernet (wsl',
];

const int _linkLocalPrefix = 0xA9FE;
const int _minimumPrefixLength = 8;
const int _maximumPrefixLength = 32;

bool _isRoutableSubnet(Ipv4Subnet subnet) {
  final value = _ipv4ToInt(subnet.address);
  if (value == null) return false;
  if (subnet.prefixLength < _minimumPrefixLength ||
      subnet.prefixLength > _maximumPrefixLength) {
    return false;
  }
  final firstOctet = value >> 24;
  if (firstOctet == 0 || firstOctet == 127 || firstOctet >= 224) return false;
  return (value >> 16) != _linkLocalPrefix;
}

bool isVirtualInternal(AdapterInfo a) {
  if (a.hasGateway) return false;
  final description = a.description.toLowerCase();
  final friendlyName = a.friendlyName.toLowerCase();
  return _virtualAdapterPatterns.any(
    (pattern) =>
        description.contains(pattern) || friendlyName.contains(pattern),
  );
}

bool isUsableAdapter(AdapterInfo a) {
  if (!a.isUp) return false;
  if (a.ifType == _loopbackIfType) return false;
  if (!a.ipv4.any(_isRoutableSubnet)) return false;
  if (a.networkId == null) return false;
  if (isVirtualInternal(a)) return false;
  return true;
}

enum NetworkDecision { trusted, untrusted }

enum InterfaceStatus { active, paused, undecided }

final class InterfaceState {
  const InterfaceState(this.adapter, this.status);

  final AdapterInfo adapter;
  final InterfaceStatus status;
}

List<InterfaceState> evaluateInterfaces(
  List<AdapterInfo> adapters,
  NetworkDecision? Function(String networkId) decisionOf,
) {
  return [
    for (final adapter in adapters)
      if (isUsableAdapter(adapter))
        InterfaceState(adapter, switch (decisionOf(adapter.networkId!)) {
          NetworkDecision.trusted => InterfaceStatus.active,
          NetworkDecision.untrusted => InterfaceStatus.paused,
          null => InterfaceStatus.undecided,
        }),
  ];
}

final class ActiveInterface {
  const ActiveInterface({
    required this.id,
    required this.adapterId,
    required this.friendlyName,
    required this.subnet,
  });

  final String id;
  final String adapterId;
  final String friendlyName;
  final Ipv4Subnet subnet;
}

List<ActiveInterface> activeInterfaces(List<InterfaceState> states) {
  return [
    for (final state in states)
      if (state.status == InterfaceStatus.active)
        for (final subnet in state.adapter.ipv4)
          if (_isRoutableSubnet(subnet))
            ActiveInterface(
              id: '${state.adapter.id}#${subnet.address.address}',
              adapterId: state.adapter.id,
              friendlyName: state.adapter.friendlyName,
              subnet: subnet,
            ),
  ];
}

bool originAllowed(InternetAddress remote, Ipv4Subnet arrivedOn) {
  if (!arrivedOn.contains(remote)) return false;
  if (arrivedOn.prefixLength > 30) return true;
  final value = _ipv4ToInt(remote);
  final mask = _maskOf(arrivedOn.prefixLength);
  if (value == null || mask == null) return false;
  final network = value & mask;
  final broadcast = network | (~mask & 0xFFFFFFFF);
  return value != network && value != broadcast;
}

bool detectResume(DateTime previousTick, DateTime now, Duration interval) {
  return now.difference(previousTick) > interval * 3;
}

abstract interface class NetworkSnapshotReader {
  List<AdapterInfo> read();
}

final class _TrustEntry {
  const _TrustEntry(this.decision, this.name, this.decidedAt);

  final NetworkDecision decision;
  final String name;
  final DateTime decidedAt;
}

final class NetworkTrustStore {
  NetworkTrustStore(this._store, {this._now = DateTime.now});

  final JsonFileStore _store;
  final DateTime Function() _now;
  final Map<String, _TrustEntry> _entries = {};

  Future<void> load() async {
    _entries.clear();
    try {
      final json = await _store.read();
      if (json != null) _entries.addAll(_parseEntries(json));
    } on FormatException {
      await _store.quarantine(_now());
    }
  }

  NetworkDecision? decisionFor(String networkId) =>
      _entries[networkId]?.decision;

  Future<bool> setDecision(
    String networkId,
    NetworkDecision decision, {
    required String name,
  }) async {
    _entries[networkId] = _TrustEntry(decision, name, _now().toUtc());
    try {
      await _store.write(_toJson());
      return true;
    } on FileSystemException {
      return false;
    }
  }

  Map<String, Object?> _toJson() => {
    'version': 1,
    'networks': {
      for (final entry in _entries.entries)
        entry.key: {
          'decision': entry.value.decision.name,
          'name': entry.value.name,
          'decidedAt': entry.value.decidedAt.toUtc().toIso8601String(),
        },
    },
  };

  Map<String, _TrustEntry> _parseEntries(Map<String, Object?> json) {
    final networks = json['networks'];
    if (networks == null) return const {};
    if (networks is! Map) throw const FormatException('invalid networks');
    final result = <String, _TrustEntry>{};
    for (final MapEntry(:key, :value) in networks.entries) {
      if (key is! String || value is! Map) continue;
      final decision = switch (value['decision']) {
        'trusted' => NetworkDecision.trusted,
        'untrusted' => NetworkDecision.untrusted,
        _ => null,
      };
      if (decision == null) continue;
      final name = value['name'];
      final decidedAt = value['decidedAt'];
      result[key] = _TrustEntry(
        decision,
        name is String ? name : '',
        (decidedAt is String ? DateTime.tryParse(decidedAt) : null) ?? _now(),
      );
    }
    return result;
  }
}

final class NetworkChange {
  const NetworkChange(this.adapters, {required this.resumed});

  final List<AdapterInfo> adapters;
  final bool resumed;
}

bool _sameSubnets(List<Ipv4Subnet> a, List<Ipv4Subnet> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

bool _adaptersChanged(List<AdapterInfo> before, List<AdapterInfo> after) {
  if (before.length != after.length) return true;
  for (var i = 0; i < before.length; i++) {
    final a = before[i];
    final b = after[i];
    if (a.id != b.id ||
        a.isUp != b.isUp ||
        a.networkId != b.networkId ||
        a.hasGateway != b.hasGateway ||
        !_sameSubnets(a.ipv4, b.ipv4)) {
      return true;
    }
  }
  return false;
}

final class _ReadTimedOut implements Exception {
  const _ReadTimedOut();
}

final class _MonitorStopped implements Exception {
  const _MonitorStopped();
}

final class NetworkMonitor {
  NetworkMonitor({
    required this._read,
    this._interval = const Duration(seconds: 2),
    this._readTimeout = const Duration(seconds: 10),
    this._now = DateTime.now,
    this._log = _noLog,
  });

  final Duration _interval;
  final Duration _readTimeout;
  final Future<List<AdapterInfo>> Function() _read;
  final DateTime Function() _now;
  final void Function(String) _log;
  final StreamController<NetworkChange> _controller =
      StreamController<NetworkChange>.broadcast();

  Timer? _timer;
  Timer? _readDeadline;
  Completer<List<AdapterInfo>>? _pendingRead;
  bool _reading = false;
  DateTime? _previousTick;
  List<AdapterInfo>? _last;

  Stream<NetworkChange> get changes => _controller.stream;

  void start() {
    if (_timer != null || _controller.isClosed) return;
    _timer = Timer.periodic(_interval, (_) => unawaited(_tick()));
    unawaited(_tick());
  }

  Future<void> stop() async {
    _timer?.cancel();
    _timer = null;
    _readDeadline?.cancel();
    _readDeadline = null;
    final pending = _pendingRead;
    _pendingRead = null;
    if (pending != null && !pending.isCompleted) {
      pending.completeError(const _MonitorStopped());
    }
    if (!_controller.isClosed) await _controller.close();
  }

  Future<void> _tick() async {
    if (_reading || _controller.isClosed) return;
    _reading = true;
    try {
      final tickTime = _now();
      final previousTick = _previousTick;
      _previousTick = tickTime;
      final List<AdapterInfo> adapters;
      final pending = Completer<List<AdapterInfo>>();
      _pendingRead = pending;
      _readDeadline = Timer(_readTimeout, () {
        if (!pending.isCompleted) pending.completeError(const _ReadTimedOut());
      });
      Future<List<AdapterInfo>>.sync(_read).then(
        (value) {
          if (!pending.isCompleted) pending.complete(value);
        },
        onError: (Object error, StackTrace stackTrace) {
          if (!pending.isCompleted) pending.completeError(error, stackTrace);
        },
      );
      try {
        adapters = await pending.future;
      } on _MonitorStopped {
        return;
      } on _ReadTimedOut {
        if (_controller.isClosed) return;
        _log('network read timed out');
        final previous = _last;
        _last = const [];
        if (previous == null || previous.isNotEmpty) {
          _controller.add(const NetworkChange([], resumed: false));
        }
        return;
      } catch (e) {
        if (_controller.isClosed) return;
        _log('network read failed: ${e.runtimeType}');
        return;
      } finally {
        _readDeadline?.cancel();
        _readDeadline = null;
        if (identical(_pendingRead, pending)) _pendingRead = null;
      }
      if (_controller.isClosed) return;
      final resumed =
          previousTick != null &&
          detectResume(previousTick, tickTime, _interval);
      final previous = _last;
      _last = adapters;
      if (previous == null || resumed || _adaptersChanged(previous, adapters)) {
        _controller.add(NetworkChange(adapters, resumed: resumed));
      }
    } finally {
      _reading = false;
    }
  }
}
