import '../discovery/discovery.dart';
import '../pairing_flow/pairing_flow.dart' show PairingView;
import '../protocol/protocol.dart' show DeviceType;

enum IdentityStatus { ok, reset, failed }

enum PairRequestResult {
  started,
  alreadyInProgress,
  tooManyPaired,
  unavailable,
}

enum NoticeKind {
  attemptCancelled,
  attemptDataMismatch,
  unpairedByPeer,
  unpairNotSaved,
  changeNotSaved,
  ignoreNotSaved,
  pairingNotSaved,
  pairingFailed,
  pairingPaused,
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
  });

  final int id;
  final NoticeKind kind;
  final String? deviceName;
  final int count;

  bool get canRetry =>
      kind == NoticeKind.unpairNotSaved || kind == NoticeKind.changeNotSaved;

  @override
  bool operator ==(Object other) =>
      other is Notice &&
      other.id == id &&
      other.kind == kind &&
      other.deviceName == deviceName &&
      other.count == count;

  @override
  int get hashCode => Object.hash(id, kind, deviceName, count);
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

final class NodeState {
  const NodeState({
    this.identityStatus = IdentityStatus.ok,
    this.identityError,
    this.prompts = const [],
    this.paused = false,
    this.pausedNetworks = const [],
    this.devices = const [],
    this.displayNames = const {},
    this.suggestRescan = false,
    this.portInUse,
    this.decisionNotSaved = false,
    this.deviceName = '',
    this.fingerprint = '',
    this.entries = const [],
    this.pairing,
    this.questions = const [],
    this.notices = const [],
    this.unsavedChanges = false,
    this.scanning = false,
  });

  final IdentityStatus identityStatus;
  final String? identityError;
  final List<NetworkPrompt> prompts;
  final bool paused;
  final List<NetworkPrompt> pausedNetworks;
  final List<DiscoveredDevice> devices;
  final Map<String, String> displayNames;
  final bool suggestRescan;
  final int? portInUse;
  final bool decisionNotSaved;
  final String deviceName;
  final String fingerprint;
  final List<DeviceEntry> entries;
  final PairingView? pairing;
  final List<PairingQuestion> questions;
  final List<Notice> notices;
  final bool unsavedChanges;
  final bool scanning;
}
