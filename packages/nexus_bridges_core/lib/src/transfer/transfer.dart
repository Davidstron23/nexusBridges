import 'dart:io';

enum TransferDirection { outgoing, incoming }

enum TransferResultKind { saved, rejected, cancelled, failed, unconfirmed }

enum TransferOutcome {
  saved,
  savedWithoutMark,
  declined,
  busy,
  unanswered,
  invalidName,
  blockedType,
  incompatible,
  noSpace,
  noFolder,
  pathTooLong,
  cancelledHere,
  cancelledByPeer,
  unpaired,
  unreadable,
  noContact,
  uploadNotStarted,
  connectionLost,
  idle,
  tooManyBytes,
  writeFailed,
  diskFull,
  damaged,
  markFailed,
  moveFailed,
  noFreeName,
  interfaceDown,
  unconfirmed;

  TransferResultKind get kind => switch (this) {
    saved || savedWithoutMark => TransferResultKind.saved,
    declined ||
    busy ||
    unanswered ||
    invalidName ||
    blockedType ||
    incompatible ||
    noSpace ||
    noFolder ||
    pathTooLong => TransferResultKind.rejected,
    cancelledHere ||
    cancelledByPeer ||
    unpaired => TransferResultKind.cancelled,
    unreadable ||
    noContact ||
    uploadNotStarted ||
    connectionLost ||
    idle ||
    tooManyBytes ||
    writeFailed ||
    diskFull ||
    damaged ||
    markFailed ||
    moveFailed ||
    noFreeName ||
    interfaceDown => TransferResultKind.failed,
    unconfirmed => TransferResultKind.unconfirmed,
  };
}

enum OutgoingPhase { preparing, requesting, waiting, uploading, verifying }

enum IncomingStage {
  warning,
  folderQuestion,
  waitingData,
  receiving,
  verifying,
  ended,
}

enum FolderQuestionKind { firstTime, thisTime }

enum FolderProblem {
  rememberedUnavailable,
  forbidden,
  cannotUse,
  unknownVolume,
  stillUnavailable,
  adminShare,
}

enum AfterEndResult { remembered, notUsable, needsConfirmation }

enum RevealResult { shown, folderOnly, unavailable }

enum SendStart { started, nothingChosen, alreadySending }

final class OutgoingTransferView {
  const OutgoingTransferView({
    required this.peerFingerprint,
    required this.peerName,
    required this.fileName,
    required this.size,
    required this.isProgram,
    required this.phase,
    required this.sentBytes,
    required this.cancelling,
  });

  final String peerFingerprint;
  final String? peerName;
  final String fileName;
  final int size;
  final bool isProgram;
  final OutgoingPhase phase;
  final int sentBytes;
  final bool cancelling;

  @override
  bool operator ==(Object other) =>
      other is OutgoingTransferView &&
      other.peerFingerprint == peerFingerprint &&
      other.peerName == peerName &&
      other.fileName == fileName &&
      other.size == size &&
      other.isProgram == isProgram &&
      other.phase == phase &&
      other.sentBytes == sentBytes &&
      other.cancelling == cancelling;

  @override
  int get hashCode => Object.hash(
    peerFingerprint,
    peerName,
    fileName,
    size,
    isProgram,
    phase,
    sentBytes,
    cancelling,
  );
}

final class FolderQuestionView {
  const FolderQuestionView({
    required this.kind,
    required this.proposedPath,
    this.problem,
    this.problemPath,
    this.cautionPath,
    this.cautionNoMark = false,
    this.cautionRemote = false,
    this.pickerOpen = false,
    this.inspecting = false,
    this.afterEnd,
  });

  final FolderQuestionKind kind;
  final String proposedPath;
  final FolderProblem? problem;
  final String? problemPath;
  final String? cautionPath;
  final bool cautionNoMark;
  final bool cautionRemote;
  final bool pickerOpen;
  final bool inspecting;
  final AfterEndResult? afterEnd;

  @override
  bool operator ==(Object other) =>
      other is FolderQuestionView &&
      other.kind == kind &&
      other.proposedPath == proposedPath &&
      other.problem == problem &&
      other.problemPath == problemPath &&
      other.cautionPath == cautionPath &&
      other.cautionNoMark == cautionNoMark &&
      other.cautionRemote == cautionRemote &&
      other.pickerOpen == pickerOpen &&
      other.inspecting == inspecting &&
      other.afterEnd == afterEnd;

  @override
  int get hashCode => Object.hash(
    kind,
    proposedPath,
    problem,
    problemPath,
    cautionPath,
    cautionNoMark,
    cautionRemote,
    pickerOpen,
    inspecting,
    afterEnd,
  );
}

final class IncomingTransferView {
  const IncomingTransferView({
    required this.peerFingerprint,
    required this.peerName,
    required this.fileName,
    required this.size,
    required this.isProgram,
    required this.stage,
    this.withoutMark = false,
    this.folder,
    this.receivedBytes = 0,
  });

  final String peerFingerprint;
  final String? peerName;
  final String fileName;
  final int size;
  final bool isProgram;
  final IncomingStage stage;
  final bool withoutMark;
  final FolderQuestionView? folder;
  final int receivedBytes;

  @override
  bool operator ==(Object other) =>
      other is IncomingTransferView &&
      other.peerFingerprint == peerFingerprint &&
      other.peerName == peerName &&
      other.fileName == fileName &&
      other.size == size &&
      other.isProgram == isProgram &&
      other.stage == stage &&
      other.withoutMark == withoutMark &&
      other.folder == folder &&
      other.receivedBytes == receivedBytes;

  @override
  int get hashCode => Object.hash(
    peerFingerprint,
    peerName,
    fileName,
    size,
    isProgram,
    stage,
    withoutMark,
    folder,
    receivedBytes,
  );
}

final class TransferResultView {
  const TransferResultView({
    required this.direction,
    required this.peerFingerprint,
    required this.peerName,
    required this.fileName,
    required this.isProgram,
    required this.outcome,
    required this.canReveal,
  });

  final TransferDirection direction;
  final String peerFingerprint;
  final String? peerName;
  final String fileName;
  final bool isProgram;
  final TransferOutcome outcome;
  final bool canReveal;

  @override
  bool operator ==(Object other) =>
      other is TransferResultView &&
      other.direction == direction &&
      other.peerFingerprint == peerFingerprint &&
      other.peerName == peerName &&
      other.fileName == fileName &&
      other.isProgram == isProgram &&
      other.outcome == outcome &&
      other.canReveal == canReveal;

  @override
  int get hashCode => Object.hash(
    direction,
    peerFingerprint,
    peerName,
    fileName,
    isProgram,
    outcome,
    canReveal,
  );
}

final class SendTarget {
  const SendTarget({
    required this.fingerprint,
    required this.address,
    required this.port,
    required this.interfaceId,
    required this.localAddress,
  });

  final String fingerprint;
  final InternetAddress address;
  final int port;
  final String interfaceId;
  final InternetAddress localAddress;

  @override
  bool operator ==(Object other) =>
      other is SendTarget &&
      other.fingerprint == fingerprint &&
      other.address == address &&
      other.port == port &&
      other.interfaceId == interfaceId &&
      other.localAddress == localAddress;

  @override
  int get hashCode =>
      Object.hash(fingerprint, address, port, interfaceId, localAddress);
}

final class ReceiveFolder {
  const ReceiveFolder({required this.path, required this.volumeId});

  final String path;
  final String volumeId;
}

abstract interface class ReceiveFolderStore {
  Future<ReceiveFolder?> load();

  Future<bool> save(ReceiveFolder folder);
}

sealed class TransferEvent {
  const TransferEvent();
}

final class ReceiveFolderNotSaved extends TransferEvent {
  const ReceiveFolderNotSaved(this.path);

  final String path;
}

final class PeerCancelledTransfer extends TransferEvent {
  const PeerCancelledTransfer({
    required this.peerFingerprint,
    required this.peerName,
  });

  final String peerFingerprint;
  final String? peerName;
}
