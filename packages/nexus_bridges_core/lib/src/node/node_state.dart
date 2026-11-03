import '../browse/browse.dart' show ShareView;
import '../discovery/discovery.dart';
import '../outbox/outbox.dart' show SendQueuesView, TrayItemView;
import '../pairing_flow/pairing_flow.dart' show PairingView;
import '../protocol/protocol.dart' show DeviceNameProblem, DeviceType;
import '../transfer/transfer.dart'
    show
        IncomingTransferView,
        OutgoingTransferView,
        TransferResultView,
        defaultExclusions;
import 'settings_rules.dart' show ExclusionProblem;

enum IdentityStatus { ok, reset, failed }

enum PairRequestResult {
  started,
  alreadyInProgress,
  tooManyPaired,
  unavailable,
}

enum SendResult {
  started,
  queued,
  nothingChosen,
  otherTargetBusy,
  tooMany,
  unavailable,
}

enum TrayResult { added, nothingNew, tooMany, unavailable }

enum NoticeKind {
  attemptCancelled,
  attemptDataMismatch,
  attemptLost,
  unpairedByPeer,
  unpairNotSaved,
  changeNotSaved,
  ignoreNotSaved,
  pairingNotSaved,
  pairingFailed,
  pairingPaused,
  replaceWithdrawn,
  receiveFolderNotSaved,
  peerCancelledTransfer,
  settingNotSaved,
  networkStopNotSaved,
  sharesNotSaved,
  shareAddNotSaved,
  sharesReset,
  sharesPartlyReset,
}

final class NetworkPrompt {
  const NetworkPrompt(this.networkId, this.networkName);

  final String networkId;
  final String networkName;

  @override
  bool operator ==(Object other) =>
      other is NetworkPrompt &&
      other.networkId == networkId &&
      other.networkName == networkName;

  @override
  int get hashCode => Object.hash(networkId, networkName);
}

final class DeviceEntry {
  const DeviceEntry({
    required this.fingerprint,
    required this.displayName,
    required this.deviceType,
    required this.visible,
    required this.paired,
    required this.mine,
    required this.ignored,
    required this.mismatch,
    required this.possiblyReplaces,
  });

  final String fingerprint;
  final String displayName;
  final DeviceType? deviceType;
  final bool visible;
  final bool paired;
  final bool mine;
  final bool ignored;
  final bool mismatch;
  final String? possiblyReplaces;

  bool get canPair => visible && (paired ? mismatch : !ignored);

  bool get canSendFile => paired && visible && !mismatch;

  @override
  bool operator ==(Object other) =>
      other is DeviceEntry &&
      other.fingerprint == fingerprint &&
      other.displayName == displayName &&
      other.deviceType == deviceType &&
      other.visible == visible &&
      other.paired == paired &&
      other.mine == mine &&
      other.ignored == ignored &&
      other.mismatch == mismatch &&
      other.possiblyReplaces == possiblyReplaces;

  @override
  int get hashCode => Object.hash(
    fingerprint,
    displayName,
    deviceType,
    visible,
    paired,
    mine,
    ignored,
    mismatch,
    possiblyReplaces,
  );
}

final class PeerSettingsView {
  const PeerSettingsView({
    required this.fingerprint,
    required this.realName,
    required this.mine,
    required this.visible,
    this.shares = const [],
    this.sharesUnsaved = false,
  });

  final String fingerprint;
  final String realName;
  final bool mine;
  final bool visible;
  final List<ShareView> shares;
  final bool sharesUnsaved;

  @override
  bool operator ==(Object other) =>
      other is PeerSettingsView &&
      other.fingerprint == fingerprint &&
      other.realName == realName &&
      other.mine == mine &&
      other.visible == visible &&
      other.sharesUnsaved == sharesUnsaved &&
      other.shares.length == shares.length &&
      Iterable<int>.generate(shares.length)
          .every((i) => other.shares[i] == shares[i]);

  @override
  int get hashCode => Object.hash(
    fingerprint,
    realName,
    mine,
    visible,
    sharesUnsaved,
    Object.hashAll(shares),
  );
}

final class Notice {
  const Notice({
    required this.id,
    required this.kind,
    this.deviceName,
    this.count = 1,
    this.detail,
  });

  final int id;
  final NoticeKind kind;
  final String? deviceName;
  final int count;
  final String? detail;

  bool get canRetry =>
      kind == NoticeKind.unpairNotSaved ||
      kind == NoticeKind.changeNotSaved ||
      kind == NoticeKind.networkStopNotSaved ||
      kind == NoticeKind.sharesNotSaved;

  @override
  bool operator ==(Object other) =>
      other is Notice &&
      other.id == id &&
      other.kind == kind &&
      other.deviceName == deviceName &&
      other.count == count &&
      other.detail == detail;

  @override
  int get hashCode => Object.hash(id, kind, deviceName, count, detail);
}

sealed class PairingQuestion {
  const PairingQuestion();

  String get fingerprint;

  String get deviceName;
}

final class ReplaceQuestion extends PairingQuestion {
  const ReplaceQuestion({
    required this.fingerprint,
    required this.deviceName,
    required this.oldFingerprint,
    required this.oldName,
  });

  @override
  final String fingerprint;

  @override
  final String deviceName;

  final String oldFingerprint;
  final String oldName;

  @override
  bool operator ==(Object other) =>
      other is ReplaceQuestion &&
      other.fingerprint == fingerprint &&
      other.deviceName == deviceName &&
      other.oldFingerprint == oldFingerprint &&
      other.oldName == oldName;

  @override
  int get hashCode =>
      Object.hash(fingerprint, deviceName, oldFingerprint, oldName);
}

final class MineQuestion extends PairingQuestion {
  const MineQuestion({required this.fingerprint, required this.deviceName});

  @override
  final String fingerprint;

  @override
  final String deviceName;

  @override
  bool operator ==(Object other) =>
      other is MineQuestion &&
      other.fingerprint == fingerprint &&
      other.deviceName == deviceName;

  @override
  int get hashCode => Object.hash(MineQuestion, fingerprint, deviceName);
}

final class DeviceNameResult {
  const DeviceNameResult({this.problem, this.saved = true});

  final DeviceNameProblem? problem;
  final bool saved;

  @override
  bool operator ==(Object other) =>
      other is DeviceNameResult &&
      other.problem == problem &&
      other.saved == saved;

  @override
  int get hashCode => Object.hash(problem, saved);
}

final class ExclusionOutcome {
  const ExclusionOutcome({this.problem, this.saved = true});

  final ExclusionProblem? problem;
  final bool saved;

  @override
  bool operator ==(Object other) =>
      other is ExclusionOutcome &&
      other.problem == problem &&
      other.saved == saved;

  @override
  int get hashCode => Object.hash(problem, saved);
}

final class SettingsView {
  const SettingsView({
    this.customName,
    this.windowsName = '',
    this.exclusions = defaultExclusions,
    this.receiveFolder,
    this.receiveFolderLocked = false,
  });

  final String? customName;
  final String windowsName;
  final List<String> exclusions;
  final String? receiveFolder;
  final bool receiveFolderLocked;

  @override
  bool operator ==(Object other) =>
      other is SettingsView &&
      other.customName == customName &&
      other.windowsName == windowsName &&
      _sameNames(other.exclusions, exclusions) &&
      other.receiveFolder == receiveFolder &&
      other.receiveFolderLocked == receiveFolderLocked;

  @override
  int get hashCode => Object.hash(
    customName,
    windowsName,
    Object.hashAll(exclusions),
    receiveFolder,
    receiveFolderLocked,
  );
}

bool _sameNames(List<String> a, List<String> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

final class TrustedNetworkView {
  const TrustedNetworkView({
    required this.networkId,
    required this.name,
    required this.trustedAt,
    required this.connected,
    this.transfers = 0,
    this.pairing = false,
  });

  final String networkId;
  final String? name;
  final DateTime trustedAt;
  final bool connected;
  final int transfers;
  final bool pairing;

  @override
  bool operator ==(Object other) =>
      other is TrustedNetworkView &&
      other.networkId == networkId &&
      other.name == name &&
      other.trustedAt == trustedAt &&
      other.connected == connected &&
      other.transfers == transfers &&
      other.pairing == pairing;

  @override
  int get hashCode =>
      Object.hash(networkId, name, trustedAt, connected, transfers, pairing);
}

final class IgnoredDeviceView {
  const IgnoredDeviceView({
    required this.fingerprint,
    required this.name,
    required this.shortFingerprint,
    required this.ignoredAt,
  });

  final String fingerprint;
  final String name;
  final String shortFingerprint;
  final DateTime ignoredAt;

  @override
  bool operator ==(Object other) =>
      other is IgnoredDeviceView &&
      other.fingerprint == fingerprint &&
      other.name == name &&
      other.shortFingerprint == shortFingerprint &&
      other.ignoredAt == ignoredAt;

  @override
  int get hashCode =>
      Object.hash(fingerprint, name, shortFingerprint, ignoredAt);
}

final class SelectionProgress {
  const SelectionProgress({
    required this.selectionId,
    required this.doneBytes,
    required this.totalBytes,
    required this.currentName,
    required this.currentIsFolder,
    required this.finished,
  });

  final int selectionId;
  final int doneBytes;
  final int totalBytes;
  final String? currentName;
  final bool currentIsFolder;
  final bool finished;

  @override
  bool operator ==(Object other) =>
      other is SelectionProgress &&
      other.selectionId == selectionId &&
      other.doneBytes == doneBytes &&
      other.totalBytes == totalBytes &&
      other.currentName == currentName &&
      other.currentIsFolder == currentIsFolder &&
      other.finished == finished;

  @override
  int get hashCode => Object.hash(
    selectionId,
    doneBytes,
    totalBytes,
    currentName,
    currentIsFolder,
    finished,
  );
}

final class NodeState {
  const NodeState({
    this.identityStatus = IdentityStatus.ok,
    this.identityError,
    this.prompts = const [],
    this.paused = false,
    this.pausedNetworks = const [],
    this.activeNetworks = const [],
    this.devices = const [],
    this.displayNames = const {},
    this.suggestRescan = false,
    this.portInUse,
    this.decisionNotSaved = false,
    this.deviceName = '',
    this.settings = const SettingsView(),
    this.fingerprint = '',
    this.entries = const [],
    this.pairing,
    this.pairingNamesake,
    this.questions = const [],
    this.notices = const [],
    this.unsavedChanges = false,
    this.scanning = false,
    this.outgoing,
    this.incoming,
    this.lastSent,
    this.lastReceived,
    this.transferInProgress = false,
    this.pickerOpen = false,
    this.incomingNamesake,
    this.queues,
    this.lastQueues,
    this.tray = const [],
    this.sendingTo,
    this.selectionProgress,
    this.ignoredDevices = const [],
    this.trustedNetworks = const [],
    this.peers = const {},
  });

  final IdentityStatus identityStatus;
  final String? identityError;
  final List<NetworkPrompt> prompts;
  final bool paused;
  final List<NetworkPrompt> pausedNetworks;
  final List<NetworkPrompt> activeNetworks;
  final List<DiscoveredDevice> devices;
  final Map<String, String> displayNames;
  final bool suggestRescan;
  final int? portInUse;
  final bool decisionNotSaved;
  final String deviceName;
  final SettingsView settings;
  final String fingerprint;
  final List<DeviceEntry> entries;
  final PairingView? pairing;
  final String? pairingNamesake;
  final List<PairingQuestion> questions;
  final List<Notice> notices;
  final bool unsavedChanges;
  final bool scanning;
  final OutgoingTransferView? outgoing;
  final IncomingTransferView? incoming;
  final TransferResultView? lastSent;
  final TransferResultView? lastReceived;
  final bool transferInProgress;
  final bool pickerOpen;
  final String? incomingNamesake;
  final SendQueuesView? queues;
  final SendQueuesView? lastQueues;
  final List<TrayItemView> tray;
  final String? sendingTo;
  final SelectionProgress? selectionProgress;
  final List<IgnoredDeviceView> ignoredDevices;
  final List<TrustedNetworkView> trustedNetworks;
  final Map<String, PeerSettingsView> peers;

  bool canSendTo(String fingerprint) {
    for (final entry in entries) {
      if (entry.fingerprint != fingerprint) continue;
      return entry.canSendFile &&
          !pickerOpen &&
          (sendingTo == null || sendingTo == fingerprint);
    }
    return false;
  }
}
