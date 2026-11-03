import '../discovery/discovery.dart';
import '../outbox/outbox.dart' show SendQueuesView, TrayItemView;
import '../pairing_flow/pairing_flow.dart' show PairingView;
import '../protocol/protocol.dart' show DeviceNameProblem, DeviceType;
import '../transfer/transfer.dart'
    show IncomingTransferView, OutgoingTransferView, TransferResultView;

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
      kind == NoticeKind.unpairNotSaved || kind == NoticeKind.changeNotSaved;

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

final class SettingsView {
  const SettingsView({this.customName, this.windowsName = ''});

  final String? customName;
  final String windowsName;

  @override
  bool operator ==(Object other) =>
      other is SettingsView &&
      other.customName == customName &&
      other.windowsName == windowsName;

  @override
  int get hashCode => Object.hash(customName, windowsName);
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
