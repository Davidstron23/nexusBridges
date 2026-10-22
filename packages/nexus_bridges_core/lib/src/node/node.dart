import 'dart:async';
import 'dart:io';
import 'dart:isolate';

import '../discovery/discovery.dart';
import '../identity/identity.dart';
import '../network/network.dart';
import '../pairing/pairing.dart' show PairedDevicesStore;
import '../protocol/protocol.dart';
import '../server/server.dart' show ApiServer;
import '../storage/storage.dart' show JsonFileStore, defaultDataDir;
import 'node_state.dart';
import 'reconcile.dart';

export '../discovery/discovery.dart' show DiscoveredDevice;
export '../identity/identity.dart' show SecretProtector;
export '../network/network.dart' show NetworkDecision, AdapterInfo;
export '../protocol/protocol.dart' show DeviceInfo, DeviceType;
export 'node_state.dart';

void _noLog(String message) {}

const String _fallbackDeviceName = 'NexusBridges';

const Duration _suggestInterval = Duration(seconds: 1);

Future<List<AdapterInfo>> _readWindowsNetworks() =>
    Isolate.run(() => WindowsNetworkSnapshotReader().read());

String _resolveDeviceName(String? requested) {
  var raw = requested;
  if (raw == null) {
    try {
      raw = Platform.localHostname;
    } catch (_) {
      raw = null;
    }
  }
  return sanitizeDisplayName(raw ?? '') ?? _fallbackDeviceName;
}

File _fileIn(Directory dir, String name) =>
    File('${dir.path}${Platform.pathSeparator}$name');

final class NexusNode {
  NexusNode._({
    required this._dataDir,
    required this._protector,
    required this._read,
    required this._port,
    required this._deviceName,
    required this._now,
    required this._log,
    required this._pollInterval,
    required this._injectedChannel,
    required this._activeOf,
  });

  static Future<NexusNode> start({
    Directory? dataDir,
    SecretProtector? protector,
    Future<List<AdapterInfo>> Function()? readNetworks,
    int port = defaultPort,
    String? deviceName,
    DateTime Function() now = DateTime.now,
    void Function(String) log = _noLog,
    List<ActiveInterface> Function(List<InterfaceState>) activeOf =
        activeInterfaces,
    Duration pollInterval = const Duration(seconds: 2),
    MulticastChannel? channel,
  }) async {
    final node = NexusNode._(
      dataDir: dataDir,
      protector: protector ?? DpapiSecretProtector(),
      read: readNetworks ?? singleFlight(_readWindowsNetworks),
      port: port,
      deviceName: _resolveDeviceName(deviceName),
      now: now,
      log: log,
      pollInterval: pollInterval,
      injectedChannel: channel,
      activeOf: activeOf,
    );
    await node._exclusive(node._boot);
    node._suggestTimer = Timer.periodic(_suggestInterval, (_) {
      if (node._closing) return;
      if (node._refreshSuggest()) node._emit();
    });
    return node;
  }

  final Directory? _dataDir;
  final SecretProtector _protector;
  final Future<List<AdapterInfo>> Function() _read;
  final int _port;
  final String _deviceName;
  final DateTime Function() _now;
  final void Function(String) _log;
  final Duration _pollInterval;
  final MulticastChannel? _injectedChannel;
  final List<ActiveInterface> Function(List<InterfaceState>) _activeOf;

  final StreamController<NodeState> _states =
      StreamController<NodeState>.broadcast();

  late NodeState _state = NodeState(paused: true, deviceName: _deviceName);

  Future<void> _tail = Future<void>.value();
  Future<void>? _rescanning;
  Future<void>? _shutdown;
  bool _closing = false;

  IdentityStatus _identityStatus = IdentityStatus.ok;
  String? _identityError;
  String _fingerprint = '';
  int? _portInUse;
  List<DiscoveredDevice> _devices = const [];
  Map<String, String> _displayNames = const {};
  bool _suggestRescan = false;
  DateTime? _emptySince;
  List<NetworkPrompt> _prompts = const [];
  List<NetworkPrompt> _pausedNetworks = const [];
  bool _paused = true;
  bool _decisionNotSaved = false;
  NetworkChange? _lastChange;
  bool _resumePending = false;
  final Set<String> _dismissed = {};
  final Set<String> _asking = {};
  Map<String, String> _activeNetworks = {};

  NetworkTrustStore? _trust;
  ApiServer? _server;
  MulticastChannel? _channel;
  DiscoveryService? _discovery;
  NetworkMonitor? _monitor;
  StreamSubscription<NetworkChange>? _changesSubscription;
  StreamSubscription<void>? _pairedSubscription;
  StreamSubscription<List<DiscoveredDevice>>? _devicesSubscription;
  Timer? _suggestTimer;

  NodeState get state => _state;

  Stream<NodeState> get states => _states.stream;

  Future<void> rescan() => _rescanning ??= _rescan();

  Future<void> decideNetwork(String networkId, NetworkDecision decision) {
    return _run('decide network', () async {
      final trust = _trust;
      if (trust == null) return;
      var saved = false;
      try {
        saved = await trust.setDecision(
          networkId,
          decision,
          name: _networkNameOf(networkId),
        );
      } catch (e) {
        _log('decision save failed: ${e.runtimeType}');
      }
      _decisionNotSaved = !saved;
      _dismissed.remove(networkId);
      _asking.remove(networkId);
      await _reconcileLocked();
    });
  }

  void dismissPrompt(String networkId) {
    _enqueue('dismiss prompt', () async {
      _dismissed.add(networkId);
      _asking.remove(networkId);
      await _reconcileLocked();
    });
  }

  void askAgain(String networkId) {
    _enqueue('ask again', () async {
      _asking.add(networkId);
      _dismissed.remove(networkId);
      await _reconcileLocked();
    });
  }

  Future<void> retry() {
    return _exclusive(() async {
      if (_closing) return;
      if (_identityStatus == IdentityStatus.failed) {
        await _closeResourcesLocked(sayGoodbye: false);
        await _boot();
      } else if (_portInUse != null) {
        await _retryPortLocked();
      }
    });
  }

  Future<void> shutdown() => _shutdown ??= _shutdownNow();

  Future<void> _shutdownNow() {
    _closing = true;
    _suggestTimer?.cancel();
    _suggestTimer = null;
    return _exclusive(() async {
      await _closeResourcesLocked(sayGoodbye: true);
      if (!_states.isClosed) await _states.close();
    });
  }

  Future<void> _exclusive(Future<void> Function() action) {
    final run = _tail.then((_) => action());
    _tail = run.then((_) {}, onError: (Object _) {});
    return run;
  }

  Future<void> _run(String what, Future<void> Function() action) {
    return _exclusive(() async {
      if (_closing) return;
      try {
        await action();
      } catch (e) {
        _log('$what failed: ${e.runtimeType}');
      }
    });
  }

  void _enqueue(String what, Future<void> Function() action) {
    unawaited(_run(what, action));
  }

  Future<void> _rescan() async {
    try {
      Future<void>? scan;
      await _exclusive(() async {
        if (_closing) return;
        scan = _discovery?.rescan();
      });
      await scan;
    } catch (e) {
      _log('rescan failed: ${e.runtimeType}');
    } finally {
      _rescanning = null;
    }
  }

  Future<void> _boot() async {
    await _bootStages();
    _refreshSuggest();
    _emit();
  }

  Future<void> _bootStages() async {
    _identityStatus = IdentityStatus.ok;
    _identityError = null;
    _fingerprint = '';
    _portInUse = null;
    _devices = const [];
    _displayNames = const {};
    _prompts = const [];
    _pausedNetworks = const [];
    _paused = true;
    _decisionNotSaved = false;
    _lastChange = null;
    _resumePending = false;
    _activeNetworks = {};
    if (_closing) return;

    final Directory dir;
    try {
      dir = _dataDir ?? defaultDataDir();
    } on StateError {
      _failIdentity('data directory unavailable');
      return;
    }

    final IdentityLoadResult loaded;
    try {
      loaded = await IdentityStore(
        dataDir: dir,
        protector: _protector,
        now: _now,
      ).loadOrCreate();
    } on IdentityCreationException catch (e) {
      _log('identity failed: ${e.runtimeType}');
      _failIdentity(e.reason);
      return;
    } catch (e) {
      _log('identity failed: ${e.runtimeType}');
      _failIdentity('identity unavailable');
      return;
    }
    final identity = loaded.identity;

    final trust = NetworkTrustStore(
      JsonFileStore(_fileIn(dir, 'networks.json')),
      now: _now,
    );
    final paired = PairedDevicesStore(
      JsonFileStore(_fileIn(dir, 'paired.json')),
      now: _now,
    );
    try {
      await trust.load();
    } catch (e) {
      _log('networks load failed: ${e.runtimeType}');
    }
    try {
      await paired.load();
    } catch (e) {
      _log('paired load failed: ${e.runtimeType}');
    }
    if (_closing) return;

    _identityStatus = switch (loaded) {
      IdentityReset() => IdentityStatus.reset,
      IdentityCreated() || IdentityLoaded() => IdentityStatus.ok,
    };
    _fingerprint = identity.fingerprint;

    final channel =
        _injectedChannel ?? MulticastChannel(port: _port, log: _log);
    final verifier = DeviceVerifier(identity: identity);
    final scanner = SubnetScanner(verifier: verifier, port: _port);
    DeviceInfo selfInfo() => DeviceInfo(
      name: _deviceName,
      fingerprint: identity.fingerprint,
      port: _server?.boundPort ?? _port,
      protocol: protocolVersion,
      deviceType: DeviceType.desktop,
    );
    final discovery = DiscoveryService(
      identity: identity,
      selfInfo: selfInfo,
      paired: paired,
      channel: channel,
      verifier: verifier,
      scanner: scanner,
      now: _now,
      log: _log,
    );
    final server = ApiServer(
      identity: identity,
      paired: paired,
      selfInfo: selfInfo,
      onRegistered: discovery.handleRegistration,
      port: _port,
      now: _now,
      log: _log,
    );
    final monitor = NetworkMonitor(
      read: _read,
      interval: _pollInterval,
      now: _now,
      log: _log,
    );
    _trust = trust;
    _channel = channel;
    _discovery = discovery;
    _server = server;
    _monitor = monitor;

    try {
      await server.rebuildTrust();
    } catch (e) {
      _log('initial trust failed: ${e.runtimeType}');
    }
    try {
      await channel.open();
    } on PortInUseException catch (e) {
      _portInUse = e.port;
    } catch (e) {
      _log('channel open failed: ${e.runtimeType}');
    }

    _devicesSubscription = discovery.devices.listen(_onDevices);
    await discovery.start();
    _pairedSubscription = paired.changes.listen(
      (_) => _enqueue('paired change', _onPairedChanged),
    );
    _changesSubscription = monitor.changes.listen(
      (change) => _enqueue('network change', () async {
        _lastChange = change;
        _resumePending = change.resumed;
        await _reconcileLocked();
      }),
    );
    monitor.start();
  }

  Future<void> _onPairedChanged() async {
    final server = _server;
    if (server == null) return;
    try {
      await server.rebuildTrust();
    } catch (e) {
      _log('trust rebuild failed: ${e.runtimeType}');
    }
    await _reconcileLocked();
  }

  Future<void> _retryPortLocked() async {
    final channel = _channel;
    if (channel == null) return;
    _portInUse = null;
    try {
      await channel.open();
    } on PortInUseException catch (e) {
      _portInUse = e.port;
    } catch (e) {
      _log('channel open failed: ${e.runtimeType}');
    }
    await _reconcileLocked();
  }

  String _networkNameOf(String networkId) {
    final change = _lastChange;
    if (change == null) return networkId;
    final known = reconcileNetworks(
      adapters: change.adapters,
      decisionOf: (_) => null,
      dismissed: const {},
      asking: const {},
    );
    for (final prompt in known.prompts) {
      if (prompt.networkId == networkId) return prompt.networkName;
    }
    return networkId;
  }

  Future<void> _reconcileLocked() async {
    final trust = _trust;
    final server = _server;
    final channel = _channel;
    final discovery = _discovery;
    if (_closing ||
        trust == null ||
        server == null ||
        channel == null ||
        discovery == null) {
      return;
    }
    final adapters = _lastChange?.adapters ?? const <AdapterInfo>[];
    final plan = reconcileNetworks(
      adapters: adapters,
      decisionOf: trust.decisionFor,
      dismissed: _dismissed,
      asking: _asking,
      activeOf: _activeOf,
    );
    if (_portInUse == null) {
      try {
        await _applyPlanLocked(plan, adapters, server, channel, discovery);
      } on PortInUseException catch (e) {
        await _enterPortInUseLocked(e.port, server, channel, discovery);
      } catch (e) {
        _log('reconcile failed: ${e.runtimeType}');
      }
    }
    if (_closing) return;
    _prompts = plan.prompts;
    _pausedNetworks = plan.pausedNetworks;
    _paused = plan.paused;
    _refreshSuggest();
    _emit();
  }

  Future<void> _applyPlanLocked(
    NetworkPlan plan,
    List<AdapterInfo> adapters,
    ApiServer server,
    MulticastChannel channel,
    DiscoveryService discovery,
  ) async {
    final networkOf = {
      for (final adapter in adapters)
        if (adapter.networkId != null) adapter.id: adapter.networkId!,
    };
    final current = <String, String>{};
    for (final iface in plan.active) {
      final networkId = networkOf[iface.adapterId];
      if (networkId != null) current[iface.adapterId] = networkId;
    }
    final moved = {
      for (final entry in current.entries)
        if (_activeNetworks[entry.key] case final before?
            when before != entry.value)
          entry.key,
    };
    if (moved.isNotEmpty) {
      await _syncAllLocked(
        [
          for (final iface in plan.active)
            if (!moved.contains(iface.adapterId)) iface,
        ],
        server,
        channel,
        discovery,
      );
    }
    await _syncAllLocked(plan.active, server, channel, discovery);
    _activeNetworks = current;
    if (_resumePending) {
      _resumePending = false;
      discovery.announceNow();
    }
  }

  Future<void> _syncAllLocked(
    List<ActiveInterface> active,
    ApiServer server,
    MulticastChannel channel,
    DiscoveryService discovery,
  ) async {
    await server.syncInterfaces(active);
    final open = server.openInterfaceIds;
    final listening = [
      for (final iface in active)
        if (open.contains(iface.id)) iface,
    ];
    await channel.syncInterfaces(listening);
    await discovery.syncInterfaces(listening);
  }

  Future<void> _enterPortInUseLocked(
    int port,
    ApiServer server,
    MulticastChannel channel,
    DiscoveryService discovery,
  ) async {
    _portInUse = port;
    _activeNetworks = {};
    await _guard('server sync', () => server.syncInterfaces(const []));
    await _guard('channel sync', () => channel.syncInterfaces(const []));
    await _guard('discovery sync', () => discovery.syncInterfaces(const []));
    await _guard('channel close', () => channel.close());
  }

  Future<void> _closeResourcesLocked({required bool sayGoodbye}) async {
    final monitor = _monitor;
    final discovery = _discovery;
    final server = _server;
    final channel = _channel;
    final changes = _changesSubscription;
    final paired = _pairedSubscription;
    final devices = _devicesSubscription;
    _trust = null;
    _monitor = null;
    _discovery = null;
    _server = null;
    _channel = null;
    _changesSubscription = null;
    _pairedSubscription = null;
    _devicesSubscription = null;
    await _guard('network changes cancel', () => changes?.cancel());
    await _guard('paired changes cancel', () => paired?.cancel());
    await _guard('monitor stop', () => monitor?.stop());
    await _guard('server close', () => server?.close());
    await _guard('discovery stop', () {
      return discovery?.stop(sayGoodbye: sayGoodbye);
    });
    await _guard('devices cancel', () => devices?.cancel());
    await _guard('channel close', () => channel?.close());
  }

  Future<void> _guard(String what, FutureOr<void> Function() action) async {
    try {
      await action();
    } catch (e) {
      _log('$what failed: ${e.runtimeType}');
    }
  }

  void _failIdentity(String reason) {
    _identityStatus = IdentityStatus.failed;
    _identityError = reason;
  }

  void _onDevices(List<DiscoveredDevice> devices) {
    if (_closing) return;
    _devices = devices;
    _displayNames = displayNames(devices);
    _refreshSuggest();
    _emit();
  }

  bool _refreshSuggest() {
    final now = _now();
    final anyActive = !_paused && _portInUse == null;
    if (anyActive && _devices.isEmpty) {
      _emptySince ??= now;
    } else {
      _emptySince = null;
    }
    final suggest = shouldSuggestRescan(
      anyActive: anyActive,
      emptySince: _emptySince,
      now: now,
    );
    final changed = suggest != _suggestRescan;
    _suggestRescan = suggest;
    return changed;
  }

  void _emit() {
    if (_closing) return;
    final next = NodeState(
      identityStatus: _identityStatus,
      identityError: _identityError,
      prompts: _prompts,
      paused: _paused,
      pausedNetworks: _pausedNetworks,
      devices: _devices,
      displayNames: _displayNames,
      suggestRescan: _suggestRescan,
      portInUse: _portInUse,
      decisionNotSaved: _decisionNotSaved,
      deviceName: _deviceName,
      fingerprint: _fingerprint,
    );
    _state = next;
    if (!_states.isClosed) _states.add(next);
  }
}
