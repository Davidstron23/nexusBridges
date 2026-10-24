import 'dart:async';
import 'dart:io';
import 'dart:isolate';

import '../discovery/discovery.dart';
import '../identity/identity.dart';
import '../network/network.dart';
import '../pairing/pairing.dart'
    show
        IgnoredDevicesStore,
        PairedDevicesStore,
        PairedLoadResult,
        PeerRelation;
import '../pairing_flow/pairing_flow.dart';
import '../protocol/protocol.dart';
import '../server/server.dart' show ApiServer;
import '../storage/storage.dart' show JsonFileStore, defaultDataDir;
import 'entries.dart';
import 'node_state.dart';
import 'reconcile.dart';

export '../discovery/discovery.dart' show DiscoveredDevice;
export '../identity/identity.dart' show SecretProtector;
export '../network/network.dart' show NetworkDecision, AdapterInfo, Ipv4Subnet;
export '../pairing_flow/pairing_flow.dart'
    show PairingView, PairingRole, PairingPhase, PairingOutcome, ReceiverAnswer;
export '../protocol/protocol.dart' show DeviceInfo, DeviceType;
export 'node_state.dart';

void _noLog(String message) {}

const String _fallbackDeviceName = 'NexusBridges';

const Duration _suggestInterval = Duration(seconds: 1);

const int _maxNotices = 8;

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
    required this._monotonic,
    required this._presentInterval,
    required this._log,
    required this._pollInterval,
    required this._injectedChannel,
    required this._activeOf,
    required this._pairingTickInterval,
    required this._pairingPollHold,
  });

  static Future<NexusNode> start({
    Directory? dataDir,
    SecretProtector? protector,
    Future<List<AdapterInfo>> Function()? readNetworks,
    int port = defaultPort,
    String? deviceName,
    DateTime Function() now = DateTime.now,
    Duration Function() monotonic = monotonicClock,
    Duration presentInterval = Limits.announceInterval,
    void Function(String) log = _noLog,
    List<ActiveInterface> Function(List<InterfaceState>) activeOf =
        activeInterfaces,
    Duration pollInterval = const Duration(seconds: 2),
    MulticastChannel? channel,
    Duration pairingTickInterval = const Duration(seconds: 1),
    Duration pairingPollHold = Limits.pairingPollHold,
  }) async {
    final node = NexusNode._(
      dataDir: dataDir,
      protector: protector ?? DpapiSecretProtector(),
      read: readNetworks ?? singleFlight(_readWindowsNetworks),
      port: port,
      deviceName: _resolveDeviceName(deviceName),
      now: now,
      monotonic: monotonic,
      presentInterval: presentInterval,
      log: log,
      pollInterval: pollInterval,
      injectedChannel: channel,
      activeOf: activeOf,
      pairingTickInterval: pairingTickInterval,
      pairingPollHold: pairingPollHold,
    );
    await node._exclusive(node._boot);
    node._suggestTimer = Timer.periodic(_suggestInterval, (_) {
      if (node._closing) return;
      node._runDueChecks();
      node._expirePause();
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
  final Duration Function() _monotonic;
  final Duration _presentInterval;
  final void Function(String) _log;
  final Duration _pollInterval;
  final MulticastChannel? _injectedChannel;
  final List<ActiveInterface> Function(List<InterfaceState>) _activeOf;
  final Duration _pairingTickInterval;
  final Duration _pairingPollHold;

  final StreamController<NodeState> _states =
      StreamController<NodeState>.broadcast();

  late NodeState _state = NodeState(paused: true, deviceName: _deviceName);
  NodeState? _lastEmitted;

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
  bool _scanning = false;
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
  List<ActiveInterface> _listening = const [];
  List<DeviceEntry> _entries = const [];
  List<PairingQuestion> _questions = const [];
  List<Notice> _notices = const [];
  int _nextNoticeId = 1;
  DateTime? _pauseUntil;
  DateTime? _attemptsAt;
  final Map<String, int> _pairingRounds = {};

  NetworkTrustStore? _trust;
  PairedDevicesStore? _paired;
  IgnoredDevicesStore? _ignored;
  PairingCoordinator? _coordinator;
  PeerCheckScheduler? _scheduler;
  ApiServer? _server;
  MulticastChannel? _channel;
  DiscoveryService? _discovery;
  NetworkMonitor? _monitor;
  StreamSubscription<NetworkChange>? _changesSubscription;
  StreamSubscription<void>? _pairedSubscription;
  StreamSubscription<List<DiscoveredDevice>>? _devicesSubscription;
  StreamSubscription<void>? _coordinatorChangesSubscription;
  StreamSubscription<PairingEvent>? _coordinatorEventsSubscription;
  StreamSubscription<void>? _ignoredSubscription;
  StreamSubscription<void>? _pairedSaveSubscription;
  StreamSubscription<void>? _ignoredSaveSubscription;
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

  Future<PairRequestResult> pair(String fingerprint) async {
    var result = PairRequestResult.unavailable;
    await _run('pair', () async {
      result = _pairLocked(fingerprint);
    });
    return result;
  }

  void answerCode({required bool matches}) {
    _callCoordinator(
      'answer code',
      (coordinator) => coordinator.answerAsInitiator(matches: matches),
    );
  }

  void cancelPairing() {
    _callCoordinator(
      'cancel pairing',
      (coordinator) => coordinator.cancelAsInitiator(),
    );
  }

  void answerRequest(ReceiverAnswer answer) {
    _callCoordinator(
      'answer request',
      (coordinator) => coordinator.answerAsReceiver(answer),
    );
  }

  void dismissPairing() {
    _callCoordinator(
      'dismiss pairing',
      (coordinator) => coordinator.dismissOutcome(),
    );
  }

  Future<void> answerMine(String fingerprint, {required bool mine}) {
    return _run('answer mine', () async {
      _questions = List.unmodifiable([
        for (final question in _questions)
          if (question is! MineQuestion || question.fingerprint != fingerprint)
            question,
      ]);
      if (mine) await _setRelationLocked(fingerprint, PeerRelation.mine);
      _refresh();
    });
  }

  Future<void> setMine(String fingerprint, {required bool mine}) {
    return _run('set mine', () async {
      await _setRelationLocked(
        fingerprint,
        mine ? PeerRelation.mine : PeerRelation.foreign,
      );
      _refresh();
    });
  }

  Future<void> unpair(String fingerprint) {
    return _run('unpair', () async {
      await _unpairLocked(fingerprint);
    });
  }

  Future<void> answerReplace(String fingerprint, {required bool replace}) {
    return _run('answer replace', () async {
      String? oldFingerprint;
      final remaining = <PairingQuestion>[];
      for (final question in _questions) {
        if (question is ReplaceQuestion &&
            question.fingerprint == fingerprint) {
          oldFingerprint = question.oldFingerprint;
        } else {
          remaining.add(question);
        }
      }
      _questions = List.unmodifiable(remaining);
      if (replace && oldFingerprint != null) {
        await _unpairLocked(oldFingerprint);
      }
      _refresh();
    });
  }

  Future<void> unignore(String fingerprint) {
    return _run('unignore', () async {
      final ignored = _ignored;
      if (ignored == null) return;
      final saved = await ignored.unignore(fingerprint);
      if (!saved) _addNotice(NoticeKind.changeNotSaved);
      _refresh();
    });
  }

  Future<void> retrySave() {
    return _run('retry save', () async {
      final paired = _paired;
      final ignored = _ignored;
      if (paired == null || ignored == null) return;
      final pairedSaved = await paired.retrySave();
      final ignoredSaved = await ignored.retrySave();
      if (pairedSaved && ignoredSaved) {
        _notices = List.unmodifiable([
          for (final notice in _notices)
            if (!notice.canRetry) notice,
        ]);
      }
      _emit();
    });
  }

  void dismissNotice(int id) {
    _enqueue('dismiss notice', () async {
      _notices = List.unmodifiable([
        for (final notice in _notices)
          if (notice.id != id) notice,
      ]);
      _emit();
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
    _scanning = true;
    _emit();
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
      _scanning = false;
      _emit();
    }
  }

  Future<void> _boot() async {
    await _bootStages();
    _rebuildEntries();
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
    _listening = const [];
    _entries = const [];
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
        log: _log,
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
      ownerFingerprint: identity.fingerprint,
      now: _now,
    );
    final ignored = IgnoredDevicesStore(
      JsonFileStore(_fileIn(dir, 'ignored.json')),
      isPaired: paired.isPaired,
      now: _now,
    );
    try {
      await trust.load();
    } catch (e) {
      _log('networks load failed: ${e.runtimeType}');
    }
    PairedLoadResult? pairedResult;
    try {
      pairedResult = await paired.load();
    } catch (e) {
      _log('paired load failed: ${e.runtimeType}');
    }
    try {
      await ignored.load();
    } catch (e) {
      _log('ignored load failed: ${e.runtimeType}');
    }
    if (_closing) return;

    _identityStatus = switch (loaded) {
      IdentityReset() => IdentityStatus.reset,
      IdentityCreated() || IdentityLoaded() => IdentityStatus.ok,
    };
    if (pairedResult == PairedLoadResult.previousIdentity) {
      _identityStatus = IdentityStatus.reset;
    }
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
      monotonic: _monotonic,
      presentInterval: _presentInterval,
      log: _log,
    );
    final scheduler = PeerCheckScheduler(now: _now);
    final coordinator = PairingCoordinator(
      identity: identity,
      paired: paired,
      ignored: ignored,
      selfInfo: selfInfo,
      now: _now,
      tickInterval: _pairingTickInterval,
      pollHold: _pairingPollHold,
      log: _log,
    );
    final server = ApiServer(
      identity: identity,
      paired: paired,
      selfInfo: selfInfo,
      onRegistered: discovery.handleRegistration,
      routes: coordinator.routes,
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
    _paired = paired;
    _ignored = ignored;
    _scheduler = scheduler;
    _coordinator = coordinator;
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
    coordinator.start();
    _coordinatorChangesSubscription = coordinator.changes.listen(
      (_) => _emit(),
    );
    _coordinatorEventsSubscription = coordinator.events.listen(
      (event) => _enqueue('pairing event', () async => _onPairingEvent(event)),
    );
    _ignoredSubscription = ignored.changes.listen(
      (_) => _enqueue('ignored change', () async => _refresh()),
    );
    _pairedSaveSubscription = paired.saveStatusChanges.listen((_) => _emit());
    _ignoredSaveSubscription = ignored.saveStatusChanges.listen((_) => _emit());
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
    _rebuildEntries();
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
    final wanted = {for (final iface in active) iface.id};
    _notifyInterfaces(wanted);
    await server.syncInterfaces(active);
    final open = server.openInterfaceIds;
    final listening = [
      for (final iface in active)
        if (open.contains(iface.id)) iface,
    ];
    _listening = listening;
    await channel.syncInterfaces(listening);
    await discovery.syncInterfaces(listening);
    final bound = {for (final iface in listening) iface.id};
    if (bound.length != wanted.length) _notifyInterfaces(bound);
  }

  void _notifyInterfaces(Set<String> ids) {
    _callCoordinator(
      'interfaces changed',
      (coordinator) => coordinator.interfacesChanged(ids),
    );
  }

  Future<void> _enterPortInUseLocked(
    int port,
    ApiServer server,
    MulticastChannel channel,
    DiscoveryService discovery,
  ) async {
    _portInUse = port;
    _activeNetworks = {};
    _listening = const [];
    _notifyInterfaces(const {});
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
    final coordinator = _coordinator;
    final changes = _changesSubscription;
    final paired = _pairedSubscription;
    final devices = _devicesSubscription;
    final pairingChanges = _coordinatorChangesSubscription;
    final pairingEvents = _coordinatorEventsSubscription;
    final ignoredChanges = _ignoredSubscription;
    final pairedSave = _pairedSaveSubscription;
    final ignoredSave = _ignoredSaveSubscription;
    _trust = null;
    _paired = null;
    _ignored = null;
    _coordinator = null;
    _scheduler = null;
    _pairingRounds.clear();
    _questions = const [];
    _notices = const [];
    _pauseUntil = null;
    _attemptsAt = null;
    _monitor = null;
    _discovery = null;
    _server = null;
    _channel = null;
    _changesSubscription = null;
    _pairedSubscription = null;
    _devicesSubscription = null;
    _coordinatorChangesSubscription = null;
    _coordinatorEventsSubscription = null;
    _ignoredSubscription = null;
    _pairedSaveSubscription = null;
    _ignoredSaveSubscription = null;
    await _guard('network changes cancel', () => changes?.cancel());
    await _guard('paired changes cancel', () => paired?.cancel());
    await _guard('pairing changes cancel', () => pairingChanges?.cancel());
    await _guard('pairing events cancel', () => pairingEvents?.cancel());
    await _guard('ignored changes cancel', () => ignoredChanges?.cancel());
    await _guard('paired save status cancel', () => pairedSave?.cancel());
    await _guard('ignored save status cancel', () => ignoredSave?.cancel());
    await _guard('monitor stop', () => monitor?.stop());
    await _guard('pairing close', () => coordinator?.close());
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
    _renameVisiblePaired(devices);
    _rebuildEntries();
    _runDueChecks();
    _refreshSuggest();
    _emit();
  }

  void _rebuildEntries() {
    final paired = _paired;
    final ignored = _ignored;
    if (paired == null || ignored == null) {
      _entries = const [];
      return;
    }
    _entries = buildEntries(
      visible: _devices,
      paired: paired.devices,
      isIgnored: ignored.isIgnored,
      mismatched: _scheduler?.mismatched ?? const {},
    );
  }

  void _refresh() {
    _rebuildEntries();
    _emit();
  }

  void _callCoordinator(String what, void Function(PairingCoordinator) action) {
    final coordinator = _coordinator;
    if (_closing || coordinator == null) return;
    try {
      action(coordinator);
    } catch (e) {
      _log('$what failed: ${e.runtimeType}');
    }
  }

  PairRequestResult _pairLocked(String fingerprint) {
    final coordinator = _coordinator;
    final paired = _paired;
    if (coordinator == null || paired == null) {
      return PairRequestResult.unavailable;
    }
    DeviceEntry? entry;
    for (final candidate in _entries) {
      if (candidate.fingerprint == fingerprint) entry = candidate;
    }
    if (entry == null || !entry.canPair) return PairRequestResult.unavailable;
    if (!entry.paired &&
        paired.devices.length >= PairedDevicesStore.maxDevices) {
      return PairRequestResult.tooManyPaired;
    }
    final target = _targetFor(fingerprint);
    if (target == null) return PairRequestResult.unavailable;
    return switch (coordinator.tryPair(target)) {
      PairStart.started => PairRequestResult.started,
      PairStart.busy => PairRequestResult.alreadyInProgress,
    };
  }

  PairingTarget? _targetFor(String fingerprint) {
    for (final device in _devices) {
      if (device.info.fingerprint != fingerprint) continue;
      for (final iface in _listening) {
        if (iface.id != device.interfaceId) continue;
        return PairingTarget(
          fingerprint: fingerprint,
          name: device.info.name,
          address: device.address,
          port: device.info.port,
          interfaceId: device.interfaceId,
          localAddress: iface.subnet.address,
        );
      }
    }
    return null;
  }

  Future<void> _setRelationLocked(
    String fingerprint,
    PeerRelation relation,
  ) async {
    final paired = _paired;
    if (paired == null || !paired.isPaired(fingerprint)) return;
    final saved = await paired.setRelation(fingerprint, relation);
    if (!saved) _addNotice(NoticeKind.changeNotSaved);
  }

  Future<void> _unpairLocked(String fingerprint) async {
    final paired = _paired;
    if (paired == null) return;
    final device = paired.deviceOf(fingerprint);
    if (device == null) return;
    final target = _targetFor(fingerprint);
    final removal = paired.remove(fingerprint);
    final server = _server;
    if (server != null) {
      await _guard('trust rebuild', server.rebuildTrust);
    }
    _scheduler?.clear(fingerprint);
    _dropQuestionsAbout(fingerprint);
    final coordinator = _coordinator;
    if (target != null && coordinator != null) {
      unawaited(
        _guard('unpair notice', () => coordinator.notifyUnpaired(target)),
      );
    }
    final saved = await removal;
    if (!saved) {
      _addNotice(
        NoticeKind.unpairNotSaved,
        deviceName: _labelOf(fingerprint, device.name),
      );
    }
    _refresh();
  }

  void _runDueChecks() {
    final scheduler = _scheduler;
    final coordinator = _coordinator;
    final paired = _paired;
    if (_closing ||
        scheduler == null ||
        coordinator == null ||
        paired == null) {
      return;
    }
    final visible = <String, String>{};
    for (final device in _devices) {
      final fingerprint = device.info.fingerprint;
      if (paired.isPaired(fingerprint)) {
        visible[fingerprint] = device.address.address;
      }
    }
    for (final fingerprint in scheduler.due(visible)) {
      final target = _targetFor(fingerprint);
      if (target == null) {
        scheduler.finished(fingerprint, PeerStatus.unknown);
        continue;
      }
      unawaited(
        _checkPeer(
          scheduler,
          coordinator,
          target,
          _pairingRounds[fingerprint] ?? 0,
        ),
      );
    }
  }

  Future<void> _checkPeer(
    PeerCheckScheduler scheduler,
    PairingCoordinator coordinator,
    PairingTarget target,
    int round,
  ) async {
    var status = PeerStatus.unknown;
    try {
      status = await coordinator.checkPeer(target);
    } catch (e) {
      _log('peer check failed: ${e.runtimeType}');
    }
    if (_closing || !identical(_scheduler, scheduler)) return;
    if ((_pairingRounds[target.fingerprint] ?? 0) != round) {
      status = PeerStatus.unknown;
    }
    scheduler.finished(target.fingerprint, status);
    if (_paired?.isPaired(target.fingerprint) != true) {
      scheduler.clear(target.fingerprint);
    }
    _refresh();
  }

  void _renameVisiblePaired(List<DiscoveredDevice> devices) {
    final paired = _paired;
    if (paired == null) return;
    for (final device in devices) {
      final name = device.info.name;
      final saved = paired.deviceOf(device.info.fingerprint);
      if (name == null || saved == null || saved.name == name) continue;
      unawaited(_rename(paired, device.info.fingerprint, name));
    }
  }

  Future<void> _rename(
    PairedDevicesStore paired,
    String fingerprint,
    String name,
  ) async {
    try {
      if (!await paired.rename(fingerprint, name)) _log('rename not saved');
    } catch (e) {
      _log('rename failed: ${e.runtimeType}');
    }
  }

  void _onPairingEvent(PairingEvent event) {
    switch (event) {
      case PairingCompleted(:final fingerprint, :final isNew):
        _pairingRounds[fingerprint] = (_pairingRounds[fingerprint] ?? 0) + 1;
        _scheduler
          ?..clear(fingerprint)
          ..deferUntil(fingerprint, _now().add(Limits.peerCheckAfterPairing));
        if (isNew) _askAbout(fingerprint);
      case UnpairedByPeer(:final fingerprint, :final name, :final saved):
        _scheduler?.clear(fingerprint);
        _dropQuestionsAbout(fingerprint);
        _addNotice(
          NoticeKind.unpairedByPeer,
          deviceName: _labelOf(fingerprint, name),
        );
        if (!saved) _addNotice(NoticeKind.changeNotSaved);
      case PairingAttemptRejected(:final fingerprint, :final cause):
        _addFailedAttempt(cause, shortFingerprint(fingerprint));
      case PairingPaused(:final until):
        _showPause(until);
      case PairingNotSaved(:final fingerprint):
        _addNotice(
          NoticeKind.pairingNotSaved,
          deviceName: _labelOf(fingerprint, _knownNameOf(fingerprint)),
        );
      case PairingFailed(:final fingerprint):
        _addNotice(
          NoticeKind.pairingFailed,
          deviceName: _labelOf(fingerprint, _knownNameOf(fingerprint)),
        );
      case IgnoreNotSaved(:final fingerprint, :final name):
        _addNotice(
          NoticeKind.ignoreNotSaved,
          deviceName: _labelOf(fingerprint, name),
        );
    }
    _refresh();
  }

  void _askAbout(String fingerprint) {
    final paired = _paired;
    final device = paired?.deviceOf(fingerprint);
    if (paired == null || device == null) return;
    final label = _labelOf(fingerprint, device.name);
    final old = findReplaced(
      name: device.name,
      excluding: fingerprint,
      paired: paired.devices,
      isVisible: _isVisible,
    );
    _questions = List.unmodifiable([
      for (final question in _questions)
        if (question.fingerprint != fingerprint) question,
      if (old != null)
        ReplaceQuestion(
          fingerprint: fingerprint,
          deviceName: label,
          oldFingerprint: old.fingerprint,
          oldName: _labelOf(old.fingerprint, old.name),
        ),
      MineQuestion(fingerprint: fingerprint, deviceName: label),
    ]);
  }

  void _dropQuestionsAbout(String fingerprint) {
    _questions = List.unmodifiable([
      for (final question in _questions)
        if (question.fingerprint != fingerprint &&
            !(question is ReplaceQuestion &&
                question.oldFingerprint == fingerprint))
          question,
    ]);
  }

  bool _isVisible(String fingerprint) {
    return _devices.any((device) => device.info.fingerprint == fingerprint);
  }

  String? _knownNameOf(String fingerprint) {
    for (final device in _devices) {
      if (device.info.fingerprint == fingerprint) return device.info.name;
    }
    return _paired?.deviceOf(fingerprint)?.name;
  }

  String _labelOf(String fingerprint, String? name) {
    final clean = name == null ? null : sanitizeDisplayName(name);
    final short = shortFingerprint(fingerprint);
    return clean == null ? short : '$clean · $short';
  }

  void _addFailedAttempt(AttemptCause cause, String short) {
    final now = _now();
    final last = _attemptsAt;
    final fresh =
        last != null && now.difference(last) < Limits.pairingGlobalWindow;
    _attemptsAt = now;
    final index = _notices.indexWhere(
      (notice) =>
          notice.kind == NoticeKind.attemptCancelled ||
          notice.kind == NoticeKind.attemptDataMismatch,
    );
    if (index >= 0 && fresh) {
      final current = _notices[index];
      _notices = List.unmodifiable([
        for (var i = 0; i < _notices.length; i++)
          if (i == index)
            Notice(
              id: current.id,
              kind: NoticeKind.attemptCancelled,
              deviceName: short,
              count: current.count + 1,
            )
          else
            _notices[i],
      ]);
      return;
    }
    if (index >= 0) {
      _notices = List.unmodifiable([
        for (var i = 0; i < _notices.length; i++)
          if (i != index) _notices[i],
      ]);
    }
    _addNotice(
      cause == AttemptCause.commitmentMismatch
          ? NoticeKind.attemptDataMismatch
          : NoticeKind.attemptCancelled,
      deviceName: short,
    );
  }

  void _showPause(DateTime until) {
    _removePauseNotices();
    _addNotice(NoticeKind.pairingPaused);
    _pauseUntil = until;
  }

  void _expirePause() {
    final until = _pauseUntil;
    if (until == null || _now().isBefore(until)) return;
    _enqueue('pause ended', () async {
      final current = _pauseUntil;
      if (current == null || _now().isBefore(current)) return;
      _pauseUntil = null;
      _removePauseNotices();
      _emit();
    });
  }

  void _removePauseNotices() {
    _notices = List.unmodifiable([
      for (final notice in _notices)
        if (notice.kind != NoticeKind.pairingPaused) notice,
    ]);
  }

  void _addNotice(NoticeKind kind, {String? deviceName}) {
    final next = [
      ..._notices,
      Notice(id: _nextNoticeId++, kind: kind, deviceName: deviceName),
    ];
    _notices = List.unmodifiable(
      next.length > _maxNotices
          ? next.sublist(next.length - _maxNotices)
          : next,
    );
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
      entries: _entries,
      pairing: _coordinator?.view,
      questions: _questions,
      notices: _notices,
      unsavedChanges:
          (_paired?.hasUnsavedChanges ?? false) ||
          (_ignored?.hasUnsavedChanges ?? false),
      scanning: _scanning,
    );
    _state = next;
    final last = _lastEmitted;
    if (last != null && _sameState(last, next)) return;
    _lastEmitted = next;
    if (!_states.isClosed) _states.add(next);
  }
}

bool _sameState(NodeState a, NodeState b) {
  return a.identityStatus == b.identityStatus &&
      a.identityError == b.identityError &&
      a.paused == b.paused &&
      a.suggestRescan == b.suggestRescan &&
      a.portInUse == b.portInUse &&
      a.decisionNotSaved == b.decisionNotSaved &&
      a.deviceName == b.deviceName &&
      a.fingerprint == b.fingerprint &&
      a.unsavedChanges == b.unsavedChanges &&
      a.scanning == b.scanning &&
      a.pairing == b.pairing &&
      _sameList(a.entries, b.entries, (x, y) => x == y) &&
      _sameList(a.questions, b.questions, (x, y) => x == y) &&
      _sameList(a.notices, b.notices, (x, y) => x == y) &&
      _sameList(a.prompts, b.prompts, (x, y) => x == y) &&
      _sameList(a.pausedNetworks, b.pausedNetworks, (x, y) => x == y) &&
      _sameMap(a.displayNames, b.displayNames) &&
      _sameList(a.devices, b.devices, _sameDevice);
}

bool _sameList<T>(List<T> a, List<T> b, bool Function(T, T) same) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (!same(a[i], b[i])) return false;
  }
  return true;
}

bool _sameMap(Map<String, String> a, Map<String, String> b) {
  if (a.length != b.length) return false;
  for (final entry in a.entries) {
    if (!b.containsKey(entry.key) || b[entry.key] != entry.value) return false;
  }
  return true;
}

bool _sameDevice(DiscoveredDevice a, DiscoveredDevice b) {
  return a.info.fingerprint == b.info.fingerprint &&
      a.address.address == b.address.address &&
      a.info.name == b.info.name &&
      a.paired == b.paired &&
      a.interfaceId == b.interfaceId;
}
