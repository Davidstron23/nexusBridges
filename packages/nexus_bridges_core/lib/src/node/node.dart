import 'dart:async';
import 'dart:io';
import 'dart:isolate';

import '../browse/browse.dart'
    show
        BrowseClient,
        BrowseCheck,
        BrowseFailure,
        BrowseServer,
        RemoteListing,
        RemoteListingFailed,
        ShareAdded,
        ShareAddOutcome,
        SharePickCancelled,
        ShareRefusal,
        ShareRefused,
        ShareService,
        ShareWriteFileSystem,
        SharesLoadResult,
        SharesStore,
        WindowsShareFileSystem;
import '../discovery/discovery.dart';
import '../identity/identity.dart';
import '../network/network.dart';
import '../outbox/outbox.dart'
    show
        ElementKind,
        ElementProbe,
        ElementSender,
        QueueItemState,
        SelectionResult,
        SendQueues,
        SendQueuesView,
        SendTray,
        TrayAddResult;
import '../pairing/pairing.dart'
    show
        IgnoredDevicesStore,
        PairedDevicesStore,
        PairedDevice,
        PairedLoadResult,
        PeerRelation;
import '../pairing_flow/pairing_flow.dart';
import '../protocol/protocol.dart';
import '../server/server.dart' show ApiServer;
import '../settings/settings.dart'
    show SavedReceiveFolder, SettingsSnapshot, SettingsStore, ThemeChoice;
import '../storage/storage.dart' show JsonFileStore, defaultDataDir;
import '../transfer/transfer.dart'
    show
        AbortSignal,
        ExclusionSource,
        FilePicker,
        FileSystemPlatform,
        FolderChangeBlocked,
        FolderChangeResult,
        FolderRevealer,
        FolderUnchanged,
        OutgoingPhase,
        PeerCancelledTransfer,
        ReceiveFolder,
        ReceiveFolderDestination,
        ReceiveFolderNotSaved,
        ReceiveFolderStore,
        RevealResult,
        SendDestination,
        SendTarget,
        TempJournal,
        TransferCoordinator,
        TransferEvent,
        TransferOutcome,
        TransferResultView,
        WindowsFileSystemPlatform,
        WindowsFilePicker,
        defaultExclusions,
        measureFolderSize,
        writeAllBytes;
import 'entries.dart' hide namesakeOf;
import 'entries.dart' as entries show namesakeOf;
import 'node_state.dart';
import 'reconcile.dart';
import 'settings_rules.dart';

export '../discovery/discovery.dart' show DiscoveredDevice;
export '../identity/identity.dart' show SecretProtector;
export '../network/network.dart' show NetworkDecision, AdapterInfo, Ipv4Subnet;
export '../outbox/outbox.dart'
    show QueueItemState, QueueItemView, SendQueuesView, TrayItemView;
export '../pairing_flow/pairing_flow.dart'
    show PairingView, PairingRole, PairingPhase, PairingOutcome, ReceiverAnswer;
export '../protocol/protocol.dart'
    show DeviceInfo, DeviceNameProblem, DeviceType, deviceNameProblem;
export '../settings/settings.dart' show ThemeChoice;
export '../transfer/transfer.dart'
    show
        FirstLevelItem,
        FolderSummaryView,
        FolderChangeResult,
        FolderChanged,
        FolderUnchanged,
        FolderChangeBlocked,
        FolderChangeRefused,
        FolderChangeNeedsConfirmation,
        OutgoingTransferView,
        OutgoingPhase,
        IncomingTransferView,
        IncomingStage,
        FolderQuestionView,
        FolderQuestionKind,
        FolderProblem,
        AfterEndResult,
        TransferResultView,
        TransferDirection,
        TransferOutcome,
        TransferResultKind,
        RevealResult;
export 'node_state.dart';
export 'settings_rules.dart'
    show ExclusionProblem, exclusionProblem, isDefaultExclusionList;

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

final class _SettingsReceiveFolders implements ReceiveFolderStore {
  _SettingsReceiveFolders(this._settings);

  final SettingsStore _settings;

  @override
  Future<ReceiveFolder?> load() async {
    final saved = await _settings.readReceiveFolder();
    if (saved == null) return null;
    return ReceiveFolder(path: saved.path, volumeId: saved.volumeId);
  }

  @override
  Future<bool> save(ReceiveFolder folder) async {
    try {
      return await _settings.writeReceiveFolder(
        SavedReceiveFolder(path: folder.path, volumeId: folder.volumeId),
      );
    } catch (_) {
      return false;
    }
  }
}

final class _MemoryExclusions implements ExclusionSource {
  _MemoryExclusions(this._node);

  final NexusNode _node;

  @override
  Future<List<String>?> load() async => List<String>.of(_node._exclusions);
}

Future<ElementProbe> _probeElement(String path) async {
  try {
    final type = await FileSystemEntity.type(path, followLinks: true);
    if (type == FileSystemEntityType.file) {
      int? size;
      try {
        size = await File(path).length();
      } catch (_) {
        size = null;
      }
      return ElementProbe(kind: ElementKind.file, size: size);
    }
    if (type == FileSystemEntityType.directory) {
      return const ElementProbe(kind: ElementKind.folder);
    }
    if (type == FileSystemEntityType.notFound) {
      return const ElementProbe(kind: ElementKind.missing);
    }
  } catch (_) {
    return const ElementProbe(kind: ElementKind.other);
  }
  return const ElementProbe(kind: ElementKind.other);
}

final class _ElementSenderAdapter implements ElementSender {
  _ElementSenderAdapter(this._transfers, this._targetOf, this._isForeign);

  final TransferCoordinator _transfers;
  final SendTarget? Function(String fingerprint) _targetOf;
  final bool Function(String fingerprint) _isForeign;

  @override
  bool get cancelEndsQueue {
    final outgoing = _transfers.outgoing;
    return outgoing != null &&
        outgoing.phase == OutgoingPhase.waiting &&
        _isForeign(outgoing.peerFingerprint);
  }

  @override
  Future<TransferResultView?> send(
    SendTarget target,
    String path,
    SendDestination destination,
  ) => _transfers.sendElement(
    target,
    path,
    refresh: () => _targetOf(target.fingerprint),
    destination: destination,
  );

  @override
  void cancelCurrent() => _transfers.cancelOutgoing();
}

final class NexusNode {
  NexusNode._({
    required this._dataDir,
    required this._protector,
    required this._read,
    required this._port,
    required this._windowsName,
    required this._now,
    required this._monotonic,
    required this._presentInterval,
    required this._log,
    required this._pollInterval,
    required this._injectedChannel,
    required this._activeOf,
    required this._pairingTickInterval,
    required this._pairingPollHold,
    required this._ownerWindowClass,
    required this._ownerWindowTitle,
    required this._fileSystem,
    required this._shareFileSystem,
    required this._picker,
    required this._revealer,
    required this._clock,
    required this._transferTickInterval,
    required this._transferPollHold,
    required this._transferIdleTimeout,
    required this._transferConfirmTimeout,
    required this._transferWriteBytes,
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
    String ownerWindowClass = '',
    String ownerWindowTitle = '',
    FileSystemPlatform? fileSystem,
    ShareWriteFileSystem? shareFileSystem,
    FilePicker? picker,
    FolderRevealer? revealer,
    Duration Function() clock = monotonicClock,
    Duration transferTickInterval = const Duration(seconds: 1),
    Duration transferPollHold = Limits.transferPollHold,
    Duration transferIdleTimeout = Limits.transferIdleTimeout,
    Duration transferConfirmTimeout = Limits.transferConfirmTimeout,
    Future<void> Function(RandomAccessFile, List<int>)? transferWriteBytes,
  }) async {
    final node = NexusNode._(
      dataDir: dataDir,
      protector: protector ?? DpapiSecretProtector(),
      read: readNetworks ?? singleFlight(_readWindowsNetworks),
      port: port,
      windowsName: _resolveDeviceName(deviceName),
      now: now,
      monotonic: monotonic,
      presentInterval: presentInterval,
      log: log,
      pollInterval: pollInterval,
      injectedChannel: channel,
      activeOf: activeOf,
      pairingTickInterval: pairingTickInterval,
      pairingPollHold: pairingPollHold,
      ownerWindowClass: ownerWindowClass,
      ownerWindowTitle: ownerWindowTitle,
      fileSystem: fileSystem,
      shareFileSystem: shareFileSystem,
      picker: picker,
      revealer: revealer,
      clock: clock,
      transferTickInterval: transferTickInterval,
      transferPollHold: transferPollHold,
      transferIdleTimeout: transferIdleTimeout,
      transferConfirmTimeout: transferConfirmTimeout,
      transferWriteBytes: transferWriteBytes,
    );
    await node._exclusive(node._boot);
    node._suggestTimer = Timer.periodic(_suggestInterval, (_) {
      if (node._closing) return;
      node._runDueChecks();
      node._expirePause();
      if (node._updateAbsences()) node._refresh();
      if (node._refreshSuggest()) node._emit();
    });
    return node;
  }

  final Directory? _dataDir;
  final SecretProtector _protector;
  final Future<List<AdapterInfo>> Function() _read;
  final int _port;
  final String _windowsName;
  final DateTime Function() _now;
  final Duration Function() _monotonic;
  final Duration _presentInterval;
  final void Function(String) _log;
  final Duration _pollInterval;
  final MulticastChannel? _injectedChannel;
  final List<ActiveInterface> Function(List<InterfaceState>) _activeOf;
  final Duration _pairingTickInterval;
  final Duration _pairingPollHold;
  final String _ownerWindowClass;
  final String _ownerWindowTitle;
  final FileSystemPlatform? _fileSystem;
  final ShareWriteFileSystem? _shareFileSystem;
  final FilePicker? _picker;
  final FolderRevealer? _revealer;
  final Duration Function() _clock;
  final Duration _transferTickInterval;
  final Duration _transferPollHold;
  final Duration _transferIdleTimeout;
  final Duration _transferConfirmTimeout;
  final Future<void> Function(RandomAccessFile, List<int>)? _transferWriteBytes;

  final StreamController<NodeState> _states =
      StreamController<NodeState>.broadcast();

  late NodeState _state = NodeState(
    paused: true,
    deviceName: _effectiveName,
    settings: SettingsView(windowsName: _windowsName),
  );
  NodeState? _lastEmitted;

  Future<void> _tail = Future<void>.value();
  Future<void>? _rescanning;
  Future<void>? _shutdown;
  bool _closing = false;

  IdentityStatus _identityStatus = IdentityStatus.ok;
  String? _identityError;
  String _fingerprint = '';
  String? _customName;
  List<String> _exclusions = List<String>.of(defaultExclusions);
  SettingsStore? _settings;
  Timer? _renameTimer;
  int? _portInUse;
  List<DiscoveredDevice> _devices = const [];
  Map<String, String> _displayNames = const {};
  bool _suggestRescan = false;
  bool _scanning = false;
  DateTime? _emptySince;
  List<NetworkPrompt> _prompts = const [];
  List<NetworkPrompt> _pausedNetworks = const [];
  List<NetworkPrompt> _trustedInUse = const [];
  bool _paused = true;
  bool _decisionNotSaved = false;
  NetworkChange? _lastChange;
  bool _resumePending = false;
  final Set<String> _dismissed = {};
  final Set<String> _asking = {};
  Map<String, String> _activeNetworks = {};
  List<ActiveInterface> _listening = const [];
  Set<String> _farewell = const {};
  List<DeviceEntry> _entries = const [];
  List<PairingQuestion> _questions = const [];
  List<Notice> _notices = const [];
  int _nextNoticeId = 1;
  DateTime? _pauseUntil;
  DateTime? _attemptsAt;
  DateTime? _discoveringSince;
  final Map<String, DateTime> _seenAt = {};
  Set<String> _longAbsent = const {};
  final Map<String, int> _pairingRounds = {};
  int _progressId = 0;
  int _progressMax = 0;
  int _progressTotal = 0;
  String? _progressName;
  bool _progressFolder = false;

  NetworkTrustStore? _trust;
  PairedDevicesStore? _paired;
  IgnoredDevicesStore? _ignored;
  PairingCoordinator? _coordinator;
  TransferCoordinator? _transfers;
  SendQueues? _queues;
  SendTray? _tray;
  ShareService? _shares;
  BrowseClient? _browseClient;
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
  StreamSubscription<void>? _transfersChangesSubscription;
  StreamSubscription<TransferEvent>? _transfersEventsSubscription;
  StreamSubscription<void>? _queuesSubscription;
  StreamSubscription<void>? _traySubscription;
  StreamSubscription<void>? _ignoredSubscription;
  StreamSubscription<void>? _pairedSaveSubscription;
  StreamSubscription<void>? _ignoredSaveSubscription;
  StreamSubscription<void>? _sharesChangesSubscription;
  StreamSubscription<void>? _sharesSaveSubscription;
  Timer? _suggestTimer;

  String get _effectiveName => _customName ?? _windowsName;

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
      if (saved) _removeNotices(NoticeKind.networkStopNotSaved);
      _dismissed.remove(networkId);
      _asking.remove(networkId);
      await _reconcileLocked();
    });
  }

  Future<void> stopUsingNetwork(String networkId) {
    return _run('stop using network', () async {
      final trust = _trust;
      if (trust == null) return;
      final entry = trust.trustedEntry(networkId);
      if (entry == null) return;
      final ids = _interfaceIdsOf(networkId);
      final saving = trust.setDecision(
        networkId,
        NetworkDecision.untrusted,
        name: entry.name,
      );
      unawaited(saving.then<void>((_) {}, onError: (Object _) {}));
      _farewell = ids;
      try {
        await _reconcileLocked();
      } catch (e) {
        _log('stop using network reconcile failed: ${e.runtimeType}');
      } finally {
        _farewell = const {};
      }
      var saved = false;
      try {
        saved = await saving;
      } catch (e) {
        _log('network save failed: ${e.runtimeType}');
      }
      if (saved) {
        _decisionNotSaved = false;
        _removeNotices(NoticeKind.networkStopNotSaved);
      } else {
        _addNotice(
          NoticeKind.networkStopNotSaved,
          detail: networkDisplayName(networkId, entry.name),
        );
      }
      _emit();
    });
  }

  Set<String> _interfaceIdsOf(String networkId) {
    final adapters = _lastChange?.adapters ?? const <AdapterInfo>[];
    final adapterIds = {
      for (final adapter in adapters)
        if (adapter.networkId == networkId) adapter.id,
    };
    return {
      for (final iface in _listening)
        if (adapterIds.contains(iface.adapterId)) iface.id,
    };
  }

  List<TrustedNetworkView> _trustedNetworkViews() {
    final trust = _trust;
    if (trust == null) return const [];
    final adapters = _lastChange?.adapters ?? const <AdapterInfo>[];
    final connected = {
      for (final adapter in adapters)
        if (isUsableAdapter(adapter)) adapter.networkId!,
    };
    final transfers = _transfers;
    final coordinator = _coordinator;
    return trustedNetworkViews(
      trusted: trust.trusted,
      connected: connected,
      transfersOn: (id) => transfers?.sessionsVia(_interfaceIdsOf(id)) ?? 0,
      pairingOn: (id) =>
          coordinator?.isPairingVia(_interfaceIdsOf(id)) ?? false,
    );
  }

  void _removeNotices(NoticeKind kind) {
    _notices = List.unmodifiable([
      for (final notice in _notices)
        if (notice.kind != kind) notice,
    ]);
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

  void cancelRequest() {
    _callCoordinator(
      'cancel request',
      (coordinator) => coordinator.cancelAsReceiver(),
    );
  }

  void dismissPairing() {
    _callCoordinator(
      'dismiss pairing',
      (coordinator) => coordinator.dismissOutcome(),
    );
  }

  Future<SendResult> sendFiles(String fingerprint) =>
      _sendPicked(fingerprint, (transfers) => transfers.pickFilesToSend());

  Future<SendResult> sendFolders(String fingerprint) =>
      _sendPicked(fingerprint, (transfers) => transfers.pickFoldersToSend());

  Future<SendResult> sendPaths(
    String fingerprint,
    List<String> paths, {
    SendDestination destination = const ReceiveFolderDestination(),
  }) async {
    SendQueues? queues;
    String? peerName;
    var result = SendResult.unavailable;
    await _run('send paths', () async {
      final current = _queues;
      if (current == null) return;
      final blocked = _sendBlock(fingerprint);
      if (blocked != null) {
        result = blocked;
        return;
      }
      for (final entry in _entries) {
        if (entry.fingerprint == fingerprint) peerName = entry.displayName;
      }
      queues = current;
    });
    final active = queues;
    if (active == null) return result;
    try {
      final selection = await active.submit(
        fingerprint,
        paths,
        refresh: () => _sendTargetOf(fingerprint),
        peerName: peerName,
        destination: destination,
      );
      return switch (selection) {
        SelectionResult.started => SendResult.started,
        SelectionResult.queued => SendResult.queued,
        SelectionResult.otherTargetBusy => SendResult.otherTargetBusy,
        SelectionResult.tooMany => SendResult.tooMany,
        SelectionResult.empty => SendResult.nothingChosen,
        SelectionResult.closed => SendResult.unavailable,
      };
    } catch (e) {
      _log('send paths failed: ${e.runtimeType}');
      return SendResult.unavailable;
    }
  }

  void cancelQueueItem(String itemId) {
    _enqueue('cancel queue item', () async => _queues?.cancelItem(itemId));
  }

  void removeQueueItem(String itemId) {
    _enqueue('remove queue item', () async => _queues?.removeItem(itemId));
  }

  void cancelAllQueued() {
    _enqueue('cancel all queued', () async => _queues?.cancelAll());
  }

  Future<TrayResult> addToTray(List<String> paths, {int? totalCount}) async {
    final tray = _tray;
    if (_closing || tray == null) return TrayResult.unavailable;
    if (totalCount != null && totalCount > Limits.maxSelectionItems) {
      return TrayResult.tooMany;
    }
    try {
      return switch (await tray.add(paths)) {
        TrayAddResult.added => TrayResult.added,
        TrayAddResult.nothingNew => TrayResult.nothingNew,
        TrayAddResult.tooMany => TrayResult.tooMany,
      };
    } catch (e) {
      _log('add to tray failed: ${e.runtimeType}');
      return TrayResult.unavailable;
    }
  }

  void removeFromTray(String itemId) {
    if (_closing) return;
    _tray?.remove(itemId);
  }

  void clearTray() {
    if (_closing) return;
    _tray?.clear();
  }

  Future<SendResult> sendTray(String fingerprint) async {
    final tray = _tray;
    if (_closing || tray == null) return SendResult.unavailable;
    final batch = tray.take();
    SendResult result;
    try {
      result = await sendPaths(fingerprint, batch.paths);
    } catch (_) {
      tray.restore(batch);
      rethrow;
    }
    if (result != SendResult.started && result != SendResult.queued) {
      tray.restore(batch);
    }
    return result;
  }

  Future<SendResult> _sendPicked(
    String fingerprint,
    Future<List<String>> Function(TransferCoordinator) pick,
  ) async {
    TransferCoordinator? transfers;
    var result = SendResult.unavailable;
    await _run('send picked', () async {
      final current = _transfers;
      if (current == null) return;
      final blocked = _sendBlock(fingerprint);
      if (blocked != null) {
        result = blocked;
        return;
      }
      transfers = current;
    });
    final active = transfers;
    if (active == null) return result;
    try {
      final chosen = await pick(active);
      if (chosen.isEmpty) return SendResult.nothingChosen;
      return await sendPaths(fingerprint, chosen);
    } catch (e) {
      _log('send picked failed: ${e.runtimeType}');
      return SendResult.unavailable;
    }
  }

  SendResult? _sendBlock(String fingerprint) {
    DeviceEntry? entry;
    for (final candidate in _entries) {
      if (candidate.fingerprint == fingerprint) entry = candidate;
    }
    if (entry == null || !entry.canSendFile) return SendResult.unavailable;
    final busyWith = _sendingTo();
    if (busyWith != null && busyWith != fingerprint) {
      return SendResult.otherTargetBusy;
    }
    if (_transfers?.pickerOpen ?? false) return SendResult.unavailable;
    if (_sendTargetOf(fingerprint) == null) return SendResult.unavailable;
    return null;
  }

  String? _sendingTo() {
    final target = _queues?.target;
    if (target != null) return target;
    return _transfers?.outgoing?.peerFingerprint;
  }

  void cancelSending() {
    _queueTransfers(
      'cancel sending',
      (transfers) => transfers.cancelOutgoing(),
    );
  }

  void cancelReceiving(String sessionId) {
    _queueTransfers(
      'cancel receiving',
      (transfers) => transfers.cancelIncoming(sessionId),
    );
  }

  void answerIncoming(String sessionId, {required bool accept}) {
    _queueTransfers(
      'answer incoming',
      (transfers) => transfers.answerWarning(sessionId, accept: accept),
    );
  }

  Future<void> useProposedFolder(String sessionId) {
    return _startTransfers(
      'use proposed folder',
      (transfers) => transfers.useProposedFolder(sessionId),
    );
  }

  Future<void> chooseOtherFolder(String sessionId) {
    return _startTransfers(
      'choose other folder',
      (transfers) => transfers.chooseOtherFolder(sessionId),
    );
  }

  void useFolderAnyway(String sessionId) {
    _queueTransfers(
      'use folder anyway',
      (transfers) => transfers.useFolderAnyway(sessionId),
    );
  }

  void cancelFolderQuestion(String sessionId) {
    _queueTransfers(
      'cancel folder question',
      (transfers) => transfers.cancelFolderQuestion(sessionId),
    );
  }

  Future<void> rememberFolderAfterEnd(
    String sessionId, {
    required bool remember,
  }) {
    return _startTransfers(
      'remember folder',
      (transfers) =>
          transfers.rememberFolderAfterEnd(sessionId, remember: remember),
    );
  }

  void dismissFolderPanel(String sessionId) {
    _queueTransfers(
      'dismiss folder panel',
      (transfers) => transfers.dismissFolderPanel(sessionId),
    );
  }

  Future<FolderChangeResult> changeReceiveFolder() {
    return _folderChange(
      'change receive folder',
      (transfers) => transfers.changeReceiveFolder(),
    );
  }

  Future<FolderChangeResult> confirmReceiveFolder(String changeId) {
    return _folderChange(
      'confirm receive folder',
      (transfers) => transfers.confirmReceiveFolder(changeId),
    );
  }

  void cancelReceiveFolderChange(String changeId) {
    _callTransfers(
      'cancel receive folder change',
      (transfers) => transfers.cancelReceiveFolderChange(changeId),
    );
  }

  Future<FolderChangeResult> _folderChange(
    String what,
    Future<FolderChangeResult> Function(TransferCoordinator) action,
  ) async {
    TransferCoordinator? transfers;
    await _run(what, () async {
      transfers = _transfers;
    });
    final active = transfers;
    if (active == null || _closing) return const FolderChangeBlocked();
    try {
      return await action(active);
    } catch (e) {
      _log('$what failed: ${e.runtimeType}');
      return const FolderUnchanged();
    }
  }

  Future<RevealResult> revealLastReceived() async {
    Future<RevealResult>? pending;
    await _run('reveal last received', () async {
      pending = _transfers?.revealLastReceived();
    });
    final reveal = pending;
    if (reveal == null) return RevealResult.unavailable;
    try {
      return await reveal;
    } catch (e) {
      _log('reveal failed: ${e.runtimeType}');
      return RevealResult.unavailable;
    }
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
      String? oldName;
      final remaining = <PairingQuestion>[];
      for (final question in _questions) {
        if (question is ReplaceQuestion &&
            question.fingerprint == fingerprint) {
          oldFingerprint = question.oldFingerprint;
          oldName = question.oldName;
        } else {
          remaining.add(question);
        }
      }
      _questions = List.unmodifiable(remaining);
      if (replace && oldFingerprint != null) {
        if (_seenRecently(oldFingerprint)) {
          _addNotice(NoticeKind.replaceWithdrawn, deviceName: oldName);
        } else {
          await _unpairLocked(oldFingerprint);
        }
      }
      _refresh();
    });
  }

  Future<void> _withdrawReappeared() async {
    final remaining = <PairingQuestion>[];
    var removed = false;
    for (final question in _questions) {
      if (question is ReplaceQuestion &&
          _seenRecently(question.oldFingerprint)) {
        _addNotice(NoticeKind.replaceWithdrawn, deviceName: question.oldName);
        removed = true;
      } else {
        remaining.add(question);
      }
    }
    if (!removed) return;
    _questions = List.unmodifiable(remaining);
    _refresh();
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

  Future<DeviceNameResult> setDeviceName(String? name) async {
    var result = const DeviceNameResult();
    await _run('set device name', () async {
      final String? next;
      if (name == null) {
        next = null;
      } else {
        next = name.trim();
        final problem = deviceNameProblem(next);
        if (problem != null) {
          result = DeviceNameResult(problem: problem);
          return;
        }
      }
      if (next == _customName) return;
      _customName = next;
      _emit();
      final discovery = _discovery;
      discovery?.announceNow();
      discovery?.presentNow();
      _renameTimer?.cancel();
      _renameTimer = Timer(Limits.renameCheckInterval, () {
        if (_closing) return;
        final discovery = _discovery;
        discovery?.announceNow();
        discovery?.presentNow();
      });
      var saved = false;
      try {
        saved = await _settings?.writeDeviceName(next) ?? false;
      } catch (e) {
        _log('device name save failed: ${e.runtimeType}');
      }
      if (!saved) {
        _addNotice(NoticeKind.settingNotSaved);
        result = const DeviceNameResult(saved: false);
      }
      _emit();
    });
    return result;
  }

  String? namesakeOf(String candidate) {
    for (final device in _devices) {
      final name = device.info.name;
      if (device.info.fingerprint != _fingerprint &&
          sameName(candidate, name)) {
        return sanitizeDisplayName(name!);
      }
    }
    for (final device in _paired?.devices ?? const <PairedDevice>[]) {
      if (device.fingerprint != _fingerprint &&
          sameName(candidate, device.name)) {
        return sanitizeDisplayName(device.name);
      }
    }
    return null;
  }

  Future<void> saveLanguage(String code) {
    return _saveSetting(
      'save language',
      (settings) => settings.writeLanguage(code),
    );
  }

  Future<void> saveTheme(ThemeChoice theme) {
    return _saveSetting('save theme', (settings) => settings.writeTheme(theme));
  }

  Future<void> saveCloseToTray(bool enabled) {
    return _saveSetting(
      'save close to tray',
      (settings) => settings.writeCloseToTray(enabled),
    );
  }

  Future<void> saveTrayHintShown() {
    return _saveSetting(
      'save tray hint',
      (settings) => settings.writeTrayHintShown(),
      notice: false,
    );
  }

  Future<ExclusionOutcome> addExclusion(String raw) async {
    var outcome = const ExclusionOutcome();
    await _run('add exclusion', () async {
      final trimmed = raw.trim();
      final problem = exclusionProblem(trimmed, _exclusions);
      if (problem != null) {
        outcome = ExclusionOutcome(problem: problem);
        return;
      }
      _exclusions = [..._exclusions, trimmed];
      _emit();
      if (!await _writeExclusions()) {
        outcome = const ExclusionOutcome(saved: false);
      }
    });
    return outcome;
  }

  Future<void> removeExclusion(String name) {
    return _run('remove exclusion', () async {
      final upper = name.toUpperCase();
      final remaining = [
        for (final kept in _exclusions)
          if (kept.toUpperCase() != upper) kept,
      ];
      if (remaining.length == _exclusions.length) return;
      _exclusions = remaining;
      _emit();
      await _writeExclusions();
    });
  }

  Future<void> restoreExclusions() {
    return _run('restore exclusions', () async {
      if (isDefaultExclusionList(_exclusions)) return;
      _exclusions = List<String>.of(defaultExclusions);
      _emit();
      await _writeExclusions();
    });
  }

  Future<bool> _writeExclusions() async {
    var saved = false;
    try {
      saved = await _settings?.writeExclusions(_exclusions) ?? false;
    } catch (e) {
      _log('exclusions save failed: ${e.runtimeType}');
    }
    if (!saved) {
      _addNotice(NoticeKind.settingNotSaved);
      _emit();
    }
    return saved;
  }

  Future<void> _saveSetting(
    String what,
    Future<bool> Function(SettingsStore settings) write, {
    bool notice = true,
  }) {
    return _run(what, () async {
      final settings = _settings;
      if (settings == null) return;
      var saved = false;
      try {
        saved = await write(settings);
      } catch (e) {
        _log('$what failed: ${e.runtimeType}');
      }
      if (!saved && notice) {
        _addNotice(NoticeKind.settingNotSaved);
        _emit();
      }
    });
  }

  Future<void> retrySave() {
    return _run('retry save', () async {
      final paired = _paired;
      final ignored = _ignored;
      final trust = _trust;
      if (paired == null || ignored == null) return;
      final pairedSaved = await paired.retrySave();
      final ignoredSaved = await ignored.retrySave();
      var trustSaved = true;
      if (trust != null && trust.hasUnsavedChanges) {
        try {
          trustSaved = await trust.retrySave();
        } catch (e) {
          _log('network retry failed: ${e.runtimeType}');
          trustSaved = false;
        }
        if (trustSaved) {
          _decisionNotSaved = false;
          _removeNotices(NoticeKind.networkStopNotSaved);
        }
      }
      final sharesSaved = await (_shares?.retrySave() ?? Future.value(true));
      if (pairedSaved && ignoredSaved && trustSaved && sharesSaved) {
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
    _renameTimer?.cancel();
    _renameTimer = null;
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
    _discoveringSince = null;
    _seenAt.clear();
    _longAbsent = const {};
    _displayNames = const {};
    _prompts = const [];
    _pausedNetworks = const [];
    _trustedInUse = const [];
    _paused = true;
    _decisionNotSaved = false;
    _lastChange = null;
    _resumePending = false;
    _activeNetworks = {};
    _listening = const [];
    _entries = const [];
    _resetProgress();
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
    final shareFs =
        _shareFileSystem ??
        WindowsShareFileSystem(
          platform: _fileSystem ?? const WindowsFileSystemPlatform(),
          dataDirs: [dir.path],
        );
    final shares = ShareService(
      store: SharesStore(
        JsonFileStore(_fileIn(dir, 'shares.json')),
        ownerFingerprint: identity.fingerprint,
        now: _now,
      ),
      paired: paired,
      fileSystem: shareFs,
      dataDirPath: dir.path,
      clock: _clock,
      now: _now,
      log: _log,
    );
    try {
      switch (await shares.load()) {
        case SharesLoadResult.quarantined:
          _addNotice(NoticeKind.sharesReset);
        case SharesLoadResult.partlyDropped:
          _addNotice(NoticeKind.sharesPartlyReset);
        case SharesLoadResult.missing ||
            SharesLoadResult.loaded ||
            SharesLoadResult.previousIdentity:
          break;
      }
    } catch (e) {
      _log('shares load failed: ${e.runtimeType}');
    }
    final browseServer = BrowseServer(
      shares: shares,
      fileSystem: shareFs,
      clock: _clock,
      log: _log,
    );
    final settings = SettingsStore(
      JsonFileStore(_fileIn(dir, 'settings.json')),
      now: _now,
    );
    var snapshot = const SettingsSnapshot();
    try {
      snapshot = await settings.load();
    } catch (e) {
      _log('settings load failed: ${e.runtimeType}');
    }
    final journal = TempJournal(
      JsonFileStore(_fileIn(dir, 'cleanup.json')),
      log: _log,
    );
    try {
      await journal.load();
    } catch (e) {
      _log('cleanup journal load failed: ${e.runtimeType}');
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
    _settings = settings;
    final savedName = snapshot.deviceName;
    _customName = savedName != null && deviceNameProblem(savedName) == null
        ? savedName
        : null;
    _exclusions = effectiveExclusions(snapshot.exclusions);

    final channel =
        _injectedChannel ?? MulticastChannel(port: _port, log: _log);
    final verifier = DeviceVerifier(identity: identity);
    final scanner = SubnetScanner(verifier: verifier, port: _port);
    DeviceInfo selfInfo() => DeviceInfo(
      name: _effectiveName,
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
    final exclusions = _MemoryExclusions(this);
    final transfers = TransferCoordinator(
      identity: identity,
      paired: paired,
      folders: _SettingsReceiveFolders(settings),
      journal: journal,
      dataDirPath: dir.path,
      picker:
          _picker ??
          WindowsFilePicker(
            ownerWindowClass: _ownerWindowClass,
            ownerWindowTitle: _ownerWindowTitle,
          ),
      fileSystem: _fileSystem ?? const WindowsFileSystemPlatform(),
      revealer: _revealer,
      clock: _clock,
      tickInterval: _transferTickInterval,
      pollHold: _transferPollHold,
      idleTimeout: _transferIdleTimeout,
      confirmTimeout: _transferConfirmTimeout,
      writeBytes: _transferWriteBytes ?? writeAllBytes,
      exclusions: exclusions,
      sharedFolders: shares,
      log: _log,
    );
    final queues = SendQueues(
      sender: _ElementSenderAdapter(
        transfers,
        _sendTargetOf,
        (fingerprint) =>
            paired.deviceOf(fingerprint)?.relation == PeerRelation.foreign,
      ),
      probe: _probeElement,
      measureFolder: (path, abort) => _measureFolder(exclusions, path, abort),
      log: _log,
    );
    final tray = SendTray(probe: _probeElement);
    final server = ApiServer(
      identity: identity,
      paired: paired,
      selfInfo: selfInfo,
      onRegistered: discovery.handleRegistration,
      routes: [
        ...coordinator.routes,
        ...transfers.routes,
        ...browseServer.routes,
      ],
      uploadRoutes: transfers.uploadRoutes,
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
    _transfers = transfers;
    _queues = queues;
    _tray = tray;
    _shares = shares;
    _browseClient = BrowseClient(identity: identity);
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
    transfers.start();
    _transfersChangesSubscription = transfers.changes.listen((_) => _emit());
    _transfersEventsSubscription = transfers.events.listen(
      (event) =>
          _enqueue('transfer event', () async => _onTransferEvent(event)),
    );
    _queuesSubscription = queues.changes.listen((_) => _emit());
    _traySubscription = tray.changes.listen((_) => _emit());
    unawaited(_guard('temp cleanup', transfers.cleanupAtStart));
    _ignoredSubscription = ignored.changes.listen(
      (_) => _enqueue('ignored change', () async => _refresh()),
    );
    _pairedSaveSubscription = paired.saveStatusChanges.listen((_) => _emit());
    _ignoredSaveSubscription = ignored.saveStatusChanges.listen((_) => _emit());
    _sharesChangesSubscription = shares.changes.listen((_) => _emit());
    _sharesSaveSubscription = shares.saveStatusChanges.listen((_) => _emit());
    _changesSubscription = monitor.changes.listen(
      (change) => _enqueue('network change', () async {
        _lastChange = change;
        _resumePending = change.resumed;
        await _reconcileLocked();
      }),
    );
    monitor.start();
  }

  Future<int?> _measureFolder(
    ExclusionSource exclusions,
    String path,
    AbortSignal abort,
  ) async {
    List<String>? loaded;
    try {
      loaded = await exclusions.load();
    } catch (e) {
      _log('exclusions load failed: ${e.runtimeType}');
    }
    return measureFolderSize(path, exclusions: loaded, abort: abort);
  }

  void _stopQueuesIfUnpaired() {
    final queues = _queues;
    final paired = _paired;
    if (queues == null || paired == null) return;
    final target = queues.target;
    if (target != null && !paired.isPaired(target)) {
      queues.stopFor(target, TransferOutcome.unpaired);
    }
  }

  Future<void> _onPairedChanged() async {
    _callTransfers('paired changed', (transfers) => transfers.pairedChanged());
    _stopQueuesIfUnpaired();
    final current = _paired;
    if (current != null) {
      _seenAt.removeWhere((fingerprint, _) => !current.isPaired(fingerprint));
    }
    _updateAbsences();
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
    _trustedInUse = _portInUse == null ? plan.activeNetworks : const [];
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
    final before = {for (final iface in _listening) iface.id};
    _notifyInterfaces(wanted);
    try {
      await server.syncInterfaces(active);
    } finally {
      final open = server.openInterfaceIds;
      final listening = [
        for (final iface in active)
          if (open.contains(iface.id)) iface,
      ];
      _listening = listening;
      _discoveringSince = listening.isEmpty
          ? null
          : (_discoveringSince ?? _now());
      final farewell = _farewell.intersection(before).difference({
        for (final iface in listening) iface.id,
      });
      _farewell = const {};
      if (farewell.isNotEmpty) discovery.sayGoodbye(farewell);
      await channel.syncInterfaces(listening);
      await discovery.syncInterfaces(listening);
      final bound = {for (final iface in listening) iface.id};
      if (bound.length != wanted.length) _notifyInterfaces(bound);
    }
  }

  void _notifyInterfaces(Set<String> ids) {
    _callCoordinator(
      'interfaces changed',
      (coordinator) => coordinator.interfacesChanged(ids),
    );
    _callTransfers(
      'transfers interfaces changed',
      (transfers) => transfers.interfacesChanged(ids),
    );
  }

  Future<void> _enterPortInUseLocked(
    int port,
    ApiServer server,
    MulticastChannel channel,
    DiscoveryService discovery,
  ) async {
    _portInUse = port;
    _discoveringSince = null;
    _activeNetworks = {};
    _listening = const [];
    _notifyInterfaces(const {});
    await _guard('server sync', () => server.syncInterfaces(const []));
    await _guard('channel sync', () => channel.syncInterfaces(const []));
    await _guard('discovery sync', () => discovery.syncInterfaces(const []));
    await _guard('channel close', () => channel.close());
  }

  Future<void> _cancelTransfersWith(String fingerprint) async {
    final transfers = _transfers;
    if (transfers == null) return;
    try {
      await transfers.peerUnpaired(fingerprint);
    } catch (e) {
      _log('transfers unpair failed: ${e.runtimeType}');
    }
  }

  Future<void> _closeResourcesLocked({required bool sayGoodbye}) async {
    _renameTimer?.cancel();
    _renameTimer = null;
    _settings = null;
    final monitor = _monitor;
    final discovery = _discovery;
    final server = _server;
    final channel = _channel;
    final coordinator = _coordinator;
    final transfers = _transfers;
    final queues = _queues;
    final tray = _tray;
    final shares = _shares;
    final queuesChanges = _queuesSubscription;
    final trayChanges = _traySubscription;
    final changes = _changesSubscription;
    final paired = _pairedSubscription;
    final devices = _devicesSubscription;
    final pairingChanges = _coordinatorChangesSubscription;
    final pairingEvents = _coordinatorEventsSubscription;
    final transfersChanges = _transfersChangesSubscription;
    final transfersEvents = _transfersEventsSubscription;
    final ignoredChanges = _ignoredSubscription;
    final pairedSave = _pairedSaveSubscription;
    final ignoredSave = _ignoredSaveSubscription;
    final sharesChanges = _sharesChangesSubscription;
    final sharesSave = _sharesSaveSubscription;
    _trust = null;
    _paired = null;
    _ignored = null;
    _coordinator = null;
    _transfers = null;
    _queues = null;
    _tray = null;
    _shares = null;
    _browseClient = null;
    _scheduler = null;
    _pairingRounds.clear();
    _resetProgress();
    _questions = const [];
    _notices = const [];
    _pauseUntil = null;
    _attemptsAt = null;
    _discoveringSince = null;
    _seenAt.clear();
    _longAbsent = const {};
    _monitor = null;
    _discovery = null;
    _server = null;
    _channel = null;
    _changesSubscription = null;
    _pairedSubscription = null;
    _devicesSubscription = null;
    _coordinatorChangesSubscription = null;
    _coordinatorEventsSubscription = null;
    _transfersChangesSubscription = null;
    _transfersEventsSubscription = null;
    _queuesSubscription = null;
    _traySubscription = null;
    _ignoredSubscription = null;
    _pairedSaveSubscription = null;
    _ignoredSaveSubscription = null;
    _sharesChangesSubscription = null;
    _sharesSaveSubscription = null;
    await _guard('network changes cancel', () => changes?.cancel());
    await _guard('paired changes cancel', () => paired?.cancel());
    await _guard('pairing changes cancel', () => pairingChanges?.cancel());
    await _guard('pairing events cancel', () => pairingEvents?.cancel());
    await _guard('transfers changes cancel', () => transfersChanges?.cancel());
    await _guard('transfers events cancel', () => transfersEvents?.cancel());
    await _guard('queues changes cancel', () => queuesChanges?.cancel());
    await _guard('tray changes cancel', () => trayChanges?.cancel());
    await _guard('ignored changes cancel', () => ignoredChanges?.cancel());
    await _guard('paired save status cancel', () => pairedSave?.cancel());
    await _guard('ignored save status cancel', () => ignoredSave?.cancel());
    await _guard('shares changes cancel', () => sharesChanges?.cancel());
    await _guard('shares save status cancel', () => sharesSave?.cancel());
    await _guard('monitor stop', () => monitor?.stop());
    await _guard('queues close', () => queues?.close());
    await _guard('tray close', () => tray?.close());
    await _guard('shares close', () => shares?.close());
    await _guard(
      'transfers close',
      () => transfers?.close().timeout(Limits.transferCloseBudget),
    );
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
    final now = _now();
    final paired = _paired;
    if (paired != null) {
      for (final device in [..._devices, ...devices]) {
        final fingerprint = device.info.fingerprint;
        if (paired.isPaired(fingerprint)) _seenAt[fingerprint] = now;
      }
    }
    _devices = devices;
    _displayNames = displayNames(devices);
    _renameVisiblePaired(devices);
    _updateAbsences();
    _rebuildEntries();
    if (_questions.any(
      (question) =>
          question is ReplaceQuestion && _isVisible(question.oldFingerprint),
    )) {
      _enqueue('replace withdrawn', _withdrawReappeared);
    }
    _runDueChecks();
    _refreshSuggest();
    _emit();
  }

  bool _seenRecently(String fingerprint) {
    if (_isVisible(fingerprint)) return true;
    final seen = _seenAt[fingerprint];
    return seen != null && _now().difference(seen) < Limits.replaceAfterAbsence;
  }

  bool _absentLongEnough(String fingerprint) {
    final since = _discoveringSince;
    return !_seenRecently(fingerprint) &&
        since != null &&
        _now().difference(since) >= Limits.replaceAfterAbsence;
  }

  bool _updateAbsences() {
    final paired = _paired;
    final next = paired == null
        ? const <String>{}
        : {
            for (final device in paired.devices)
              if (_absentLongEnough(device.fingerprint)) device.fingerprint,
          };
    if (next.length == _longAbsent.length && _longAbsent.containsAll(next)) {
      return false;
    }
    _longAbsent = next;
    return true;
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
      isReplaceable: _longAbsent.contains,
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

  void _callTransfers(String what, void Function(TransferCoordinator) action) {
    final transfers = _transfers;
    if (_closing || transfers == null) return;
    try {
      action(transfers);
    } catch (e) {
      _log('$what failed: ${e.runtimeType}');
    }
  }

  void _queueTransfers(String what, void Function(TransferCoordinator) action) {
    _enqueue(what, () async => _callTransfers(what, action));
  }

  Future<void> _startTransfers(
    String what,
    Future<void> Function(TransferCoordinator) action,
  ) {
    return _run(what, () async {
      final transfers = _transfers;
      if (transfers == null) return;
      unawaited(_guard(what, () => action(transfers)));
    });
  }

  Future<RemoteListing> listRemoteRoots(
    String fingerprint, {
    List<BrowseCheck> check = const [],
  }) async {
    final client = _browseClient;
    final target = _browseTargetOf(fingerprint);
    if (client == null || target == null) {
      return const RemoteListingFailed(BrowseFailure.notVisible);
    }
    try {
      return await client.roots(target, checks: check);
    } catch (e) {
      _log('list remote roots failed: ${e.runtimeType}');
      return const RemoteListingFailed(BrowseFailure.noAnswer);
    }
  }

  Future<RemoteListing> listRemoteFolders(
    String fingerprint,
    String rootId,
    List<String> path,
  ) async {
    final client = _browseClient;
    final target = _browseTargetOf(fingerprint);
    if (client == null || target == null) {
      return const RemoteListingFailed(BrowseFailure.notVisible);
    }
    try {
      return await client.folders(target, rootId, path);
    } catch (e) {
      _log('list remote folders failed: ${e.runtimeType}');
      return const RemoteListingFailed(BrowseFailure.noAnswer);
    }
  }

  Future<ShareAddOutcome> addShare(String fingerprint) async {
    final shares = _shares;
    final transfers = _transfers;
    if (shares == null || transfers == null || !_isMine(fingerprint)) {
      return const ShareRefused(ShareRefusal.missing);
    }
    try {
      final path = await transfers.pickFolderToShare();
      if (path == null) return const SharePickCancelled();
      if (_closing || !identical(_shares, shares) || !_isMine(fingerprint)) {
        return const ShareRefused(ShareRefusal.missing);
      }
      return _afterShareAdd(await shares.addPath(fingerprint, path));
    } catch (e) {
      _log('add share failed: ${e.runtimeType}');
      return const ShareRefused(ShareRefusal.unknownDrive);
    }
  }

  Future<ShareAddOutcome> confirmShare(
    String fingerprint,
    String pendingId,
  ) async {
    final shares = _shares;
    if (shares == null || !_isMine(fingerprint)) {
      return const ShareRefused(ShareRefusal.missing);
    }
    try {
      final outcome = await shares.confirm(fingerprint, pendingId);
      if (_closing || !identical(_shares, shares)) {
        return const ShareRefused(ShareRefusal.missing);
      }
      return _afterShareAdd(outcome);
    } catch (e) {
      _log('confirm share failed: ${e.runtimeType}');
      return const ShareRefused(ShareRefusal.unknownDrive);
    }
  }

  void cancelPendingShare(String pendingId) {
    _shares?.dropPending(pendingId);
  }

  Future<void> removeShare(String fingerprint, String rootId) async {
    final shares = _shares;
    if (shares == null || _closing) return;
    try {
      final saved = await shares.remove(fingerprint, rootId);
      if (!saved) _addSharesNotSavedNotice();
    } catch (e) {
      _log('remove share failed: ${e.runtimeType}');
    }
    _emit();
  }

  Future<void> refreshShares(String fingerprint) async {
    final shares = _shares;
    if (shares == null || _closing) return;
    try {
      await shares.refreshAvailability(fingerprint);
    } catch (e) {
      _log('refresh shares failed: ${e.runtimeType}');
    }
    _emit();
  }

  ShareAddOutcome _afterShareAdd(ShareAddOutcome outcome) {
    if (outcome is ShareAdded && !outcome.saved) {
      _addNotice(NoticeKind.shareAddNotSaved);
    }
    _emit();
    return outcome;
  }

  void _addSharesNotSavedNotice() {
    if (_notices.any((notice) => notice.kind == NoticeKind.sharesNotSaved)) {
      return;
    }
    _addNotice(NoticeKind.sharesNotSaved);
  }

  bool _isMine(String fingerprint) {
    if (_closing) return false;
    for (final entry in _entries) {
      if (entry.fingerprint == fingerprint) return entry.paired && entry.mine;
    }
    return false;
  }

  SendTarget? _browseTargetOf(String fingerprint) {
    for (final entry in _entries) {
      if (entry.fingerprint == fingerprint) {
        return entry.canSendFile ? _sendTargetOf(fingerprint) : null;
      }
    }
    return null;
  }

  SendTarget? _sendTargetOf(String fingerprint) {
    if (_closing) return null;
    final paired = _paired;
    if (paired == null || !paired.isPaired(fingerprint)) return null;
    final target = _targetFor(fingerprint);
    if (target == null) return null;
    return SendTarget(
      fingerprint: fingerprint,
      address: target.address,
      port: target.port,
      interfaceId: target.interfaceId,
      localAddress: target.localAddress,
    );
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
    final cancelled = _cancelTransfersWith(fingerprint);
    _queues?.stopFor(fingerprint, TransferOutcome.unpaired);
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
        _guard('unpair notice', () async {
          await cancelled;
          await coordinator.notifyUnpaired(target);
        }),
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

  void _onTransferEvent(TransferEvent event) {
    switch (event) {
      case ReceiveFolderNotSaved(:final path):
        _addNotice(NoticeKind.receiveFolderNotSaved, detail: path);
      case PeerCancelledTransfer(:final peerFingerprint, :final peerName):
        final short = shortFingerprint(peerFingerprint);
        _notices = List.unmodifiable([
          for (final notice in _notices)
            if (!_isCancelNoticeOf(notice, short)) notice,
        ]);
        _addNotice(
          NoticeKind.peerCancelledTransfer,
          detail: _labelOf(peerFingerprint, peerName),
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
      isReplaceable: _absentLongEnough,
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
          notice.kind == NoticeKind.attemptDataMismatch ||
          notice.kind == NoticeKind.attemptLost,
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
    _addNotice(switch (cause) {
      AttemptCause.commitmentMismatch => NoticeKind.attemptDataMismatch,
      AttemptCause.cancelledAfterReveal => NoticeKind.attemptCancelled,
      AttemptCause.lostAfterReveal => NoticeKind.attemptLost,
    }, deviceName: short);
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

  void _addNotice(NoticeKind kind, {String? deviceName, String? detail}) {
    final next = [
      ..._notices,
      Notice(
        id: _nextNoticeId++,
        kind: kind,
        deviceName: deviceName,
        detail: detail,
      ),
    ];
    while (next.length > _maxNotices) {
      final index = next.indexWhere((notice) => !_isProtected(notice));
      next.removeAt(index < 0 ? 0 : index);
    }
    _notices = List.unmodifiable(next);
  }

  bool _isProtected(Notice notice) =>
      notice.canRetry ||
      notice.kind == NoticeKind.attemptDataMismatch ||
      notice.kind == NoticeKind.unpairedByPeer ||
      notice.kind == NoticeKind.pairingPaused;

  bool _isCancelNoticeOf(Notice notice, String short) {
    final detail = notice.detail;
    return notice.kind == NoticeKind.peerCancelledTransfer &&
        detail != null &&
        (detail == short || detail.endsWith(' · $short'));
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

  void _resetProgress() {
    _progressId = 0;
    _progressMax = 0;
    _progressTotal = 0;
    _progressName = null;
    _progressFolder = false;
  }

  SelectionProgress? _selectionProgress(SendQueuesView? view) {
    final queues = _queues;
    final transfers = _transfers;
    if (queues == null) return null;
    final id = queues.selectionId;
    if (id == 0) return null;
    if (id != _progressId) {
      _resetProgress();
      _progressId = id;
    }
    final outgoing = transfers?.outgoing;
    if (outgoing != null) {
      _progressName = outgoing.fileName;
      _progressFolder = outgoing.isFolder;
    } else if (view != null) {
      for (final item in [...view.loose, ...view.bundles]) {
        if (item.state != QueueItemState.inProgress) continue;
        _progressName = item.name;
        _progressFolder = item.isFolder;
      }
    }
    var done = 0;
    var total = 0;
    var finished = false;
    if (view != null) {
      final size = outgoing?.size ?? 0;
      final current = size > 0 ? size : (view.currentProbeSize ?? 0);
      done = view.completedBytes + (outgoing?.sentBytes ?? 0);
      total = view.completedBytes + current + view.pendingKnownBytes;
      finished = view.finished;
    } else if (queues.active) {
      done = outgoing?.sentBytes ?? 0;
      if ((outgoing?.size ?? 0) > 0) _progressTotal = outgoing!.size;
      total = _progressTotal;
    } else {
      finished = true;
      final sent = transfers?.lastSent?.size ?? 0;
      total = sent > 0 ? sent : _progressTotal;
    }
    if (done < _progressMax) done = _progressMax;
    if (total < done) total = done;
    if (finished) done = total;
    _progressMax = done;
    return SelectionProgress(
      selectionId: id,
      doneBytes: done,
      totalBytes: total,
      currentName: _progressName,
      currentIsFolder: _progressFolder,
      finished: finished,
    );
  }

  Map<String, PeerSettingsView> _peerViews() {
    final shares = _shares;
    if (shares == null) return const {};
    final unsaved = shares.hasUnsavedRemoval;
    return {
      for (final entry in _entries)
        if (entry.paired)
          entry.fingerprint: PeerSettingsView(
            fingerprint: entry.fingerprint,
            realName: entry.displayName,
            mine: entry.mine,
            visible: entry.visible,
            shares: shares.viewsFor(entry.fingerprint),
            sharesUnsaved: unsaved,
          ),
    };
  }

  void _emit() {
    if (_closing) return;
    final view = _coordinator?.view;
    final paired = _paired;
    final transfers = _transfers;
    final queues = _queues;
    final queuesView = queues?.view;
    final incoming = transfers?.incoming;
    final next = NodeState(
      identityStatus: _identityStatus,
      identityError: _identityError,
      prompts: _prompts,
      paused: _paused,
      pausedNetworks: _pausedNetworks,
      activeNetworks: _trustedInUse,
      devices: _devices,
      displayNames: _displayNames,
      suggestRescan: _suggestRescan,
      portInUse: _portInUse,
      decisionNotSaved: _decisionNotSaved,
      deviceName: _effectiveName,
      settings: SettingsView(
        customName: _customName,
        windowsName: _windowsName,
        exclusions: List<String>.unmodifiable(_exclusions),
        receiveFolder: transfers?.receiveFolderPath,
        receiveFolderLocked: transfers?.receiveFolderLocked ?? false,
      ),
      fingerprint: _fingerprint,
      entries: _entries,
      pairing: view,
      pairingNamesake: view == null || paired == null
          ? null
          : entries.namesakeOf(
              name: view.peerName,
              excluding: view.peerFingerprint,
              paired: paired.devices,
            ),
      questions: _questions,
      notices: _notices,
      unsavedChanges:
          (_paired?.hasUnsavedChanges ?? false) ||
          (_ignored?.hasUnsavedChanges ?? false),
      scanning: _scanning,
      outgoing: transfers?.outgoing,
      incoming: incoming,
      lastSent: transfers?.lastSent,
      lastReceived: transfers?.lastReceived,
      transferInProgress:
          (transfers?.busy ?? false) || (queues?.active ?? false),
      pickerOpen: transfers?.pickerOpen ?? false,
      incomingNamesake: incoming == null || paired == null
          ? null
          : entries.namesakeOf(
              name: incoming.peerName,
              excluding: incoming.peerFingerprint,
              paired: paired.devices,
            ),
      queues: queuesView,
      lastQueues: queues?.previous,
      tray: _tray?.items ?? const [],
      sendingTo: _sendingTo(),
      selectionProgress: _selectionProgress(queuesView),
      ignoredDevices: ignoredDeviceViews(_ignored?.devices ?? const []),
      trustedNetworks: _trustedNetworkViews(),
      peers: _peerViews(),
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
      a.settings == b.settings &&
      a.fingerprint == b.fingerprint &&
      a.unsavedChanges == b.unsavedChanges &&
      a.scanning == b.scanning &&
      a.outgoing == b.outgoing &&
      a.incoming == b.incoming &&
      a.lastSent == b.lastSent &&
      a.lastReceived == b.lastReceived &&
      a.transferInProgress == b.transferInProgress &&
      a.pickerOpen == b.pickerOpen &&
      a.incomingNamesake == b.incomingNamesake &&
      a.pairing == b.pairing &&
      a.pairingNamesake == b.pairingNamesake &&
      a.queues == b.queues &&
      a.lastQueues == b.lastQueues &&
      a.sendingTo == b.sendingTo &&
      a.selectionProgress == b.selectionProgress &&
      _sameList(a.tray, b.tray, (x, y) => x == y) &&
      _sameList(a.ignoredDevices, b.ignoredDevices, (x, y) => x == y) &&
      _sameList(a.trustedNetworks, b.trustedNetworks, (x, y) => x == y) &&
      _sameList(a.entries, b.entries, (x, y) => x == y) &&
      _sameList(a.questions, b.questions, (x, y) => x == y) &&
      _sameList(a.notices, b.notices, (x, y) => x == y) &&
      _sameList(a.prompts, b.prompts, (x, y) => x == y) &&
      _sameList(a.pausedNetworks, b.pausedNetworks, (x, y) => x == y) &&
      _sameList(a.activeNetworks, b.activeNetworks, (x, y) => x == y) &&
      _samePeers(a.peers, b.peers) &&
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

bool _samePeers(
  Map<String, PeerSettingsView> a,
  Map<String, PeerSettingsView> b,
) {
  if (a.length != b.length) return false;
  for (final entry in a.entries) {
    if (b[entry.key] != entry.value) return false;
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
