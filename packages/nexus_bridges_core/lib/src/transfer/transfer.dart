import 'dart:async';
import 'dart:io';

import '../identity/identity.dart' show DeviceIdentity;
import '../pairing/pairing.dart' show PairedDevicesStore;
import '../protocol/protocol.dart' show Limits, monotonicClock;
import '../server/server.dart' show ApiRoute, ApiUploadRoute;
import 'journal.dart' show TempJournal;
import 'pickers.dart' show PickerTracker;
import 'platform.dart' show FileSystemPlatform, FilePicker, FolderRevealer;
import 'receiver.dart' show TransferReceiver;
import 'sender.dart' show TransferSender;
import 'windows_file_system.dart' show WindowsFileSystemPlatform;
import 'writer.dart' show writeAllBytes;

void _noLog(String message) {}

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
    required this.sessionId,
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

  final String sessionId;
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
      other.sessionId == sessionId &&
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
    sessionId,
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

final class TransferCoordinator {
  TransferCoordinator({
    required DeviceIdentity identity,
    required PairedDevicesStore paired,
    required ReceiveFolderStore folders,
    required TempJournal journal,
    required String dataDirPath,
    required FilePicker picker,
    FileSystemPlatform fileSystem = const WindowsFileSystemPlatform(),
    FolderRevealer? revealer,
    Duration Function() clock = monotonicClock,
    this._tickInterval = const Duration(milliseconds: 250),
    Duration pollHold = Limits.transferPollHold,
    Duration idleTimeout = Limits.transferIdleTimeout,
    Duration confirmTimeout = Limits.transferConfirmTimeout,
    Future<void> Function(RandomAccessFile file, List<int> bytes) writeBytes =
        writeAllBytes,
    this._log = _noLog,
  }) {
    _pickers = PickerTracker(
      clock: clock,
      onChanged: (open, since) => _receiver.pickersChanged(open, since),
    );
    _receiver = TransferReceiver(
      paired: paired,
      folders: folders,
      journal: journal,
      fs: fileSystem,
      dataDirPath: dataDirPath,
      clock: clock,
      pollHold: pollHold,
      writeBytes: writeBytes,
      idleTimeout: idleTimeout,
      picker: picker,
      pickers: _pickers,
      onChanged: _notify,
      emit: _emit,
      log: _log,
    );
    _sender = TransferSender(
      identity: identity,
      paired: paired,
      picker: picker,
      fs: fileSystem,
      clock: clock,
      pollHold: pollHold,
      idleTimeout: idleTimeout,
      confirmTimeout: confirmTimeout,
      onChanged: _notify,
      onFilePicker: (open) => open ? _pickers.open() : _pickers.close(),
      log: _log,
    );
  }

  final Duration _tickInterval;

  final void Function(String) _log;

  late final TransferReceiver _receiver;

  late final PickerTracker _pickers;

  late final TransferSender _sender;

  final StreamController<void> _changes = StreamController<void>.broadcast();

  final StreamController<TransferEvent> _events =
      StreamController<TransferEvent>.broadcast();

  Timer? _timer;

  Future<void>? _closing;

  bool _closed = false;

  (
    IncomingTransferView?,
    TransferResultView?,
    OutgoingTransferView?,
    TransferResultView?,
    bool,
    bool,
  )?
  _lastNotified = (null, null, null, null, false, false);

  List<ApiRoute> get routes => _receiver.routes;

  List<ApiUploadRoute> get uploadRoutes => _receiver.uploadRoutes;

  IncomingTransferView? get incoming => _receiver.incoming;

  TransferResultView? get lastReceived => _receiver.lastReceived;

  bool get busy => _receiver.busy || _sender.sending;

  bool get pickerOpen => _pickers.isOpen;

  Stream<void> get changes => _changes.stream;

  Stream<TransferEvent> get events => _events.stream;

  void start() {
    if (_closed || _timer != null) return;
    _timer = Timer.periodic(_tickInterval, (_) => _tick());
    _receiver.start();
  }

  Future<void> cleanupAtStart() => _receiver.cleanupAtStart();

  void answerWarning(String sessionId, {required bool accept}) {
    _receiver.answerWarning(sessionId, accept: accept);
  }

  void cancelIncoming(String sessionId) => _receiver.cancelIncoming(sessionId);

  Future<void> useProposedFolder(String sessionId) =>
      _receiver.useProposedFolder(sessionId);

  Future<void> chooseOtherFolder(String sessionId) =>
      _receiver.chooseOtherFolder(sessionId);

  void useFolderAnyway(String sessionId) =>
      _receiver.useFolderAnyway(sessionId);

  void cancelFolderQuestion(String sessionId) =>
      _receiver.cancelFolderQuestion(sessionId);

  Future<void> rememberFolderAfterEnd(
    String sessionId, {
    required bool remember,
  }) => _receiver.rememberFolderAfterEnd(sessionId, remember: remember);

  void dismissFolderPanel(String sessionId) =>
      _receiver.dismissFolderPanel(sessionId);

  void interfacesChanged(Set<String> activeInterfaceIds) {
    _receiver.interfacesChanged(activeInterfaceIds);
    _sender.interfacesChanged(activeInterfaceIds);
  }

  void pairedChanged() {
    _receiver.pairedChanged();
    _sender.pairedChanged();
  }

  Future<void> peerUnpaired(String fingerprint) async {
    _receiver.peerUnpaired(fingerprint);
    await _sender.peerUnpaired(fingerprint);
  }

  Future<void> close() => _closing ??= _close();

  Future<void> _close() async {
    _timer?.cancel();
    _timer = null;
    await Future.wait([_receiver.close(), _sender.close()]);
    _closed = true;
    await _changes.close();
    await _events.close();
  }

  void _tick() {
    _sender.tick();
    try {
      _receiver.tick();
    } catch (e) {
      _log('transfer tick failed: ${e.runtimeType}');
    }
  }

  void _notify() {
    if (_closed) return;
    final current = (
      incoming,
      lastReceived,
      outgoing,
      lastSent,
      busy,
      pickerOpen,
    );
    if (current == _lastNotified) return;
    _lastNotified = current;
    _changes.add(null);
  }

  void _emit(TransferEvent event) {
    if (_closed) return;
    _events.add(event);
  }

  OutgoingTransferView? get outgoing => _sender.outgoing;

  TransferResultView? get lastSent => _sender.lastSent;

  bool get sending => _sender.sending;

  Future<SendStart> sendFile(
    SendTarget target, {
    required SendTarget? Function() refresh,
  }) => _sender.sendFile(target, refresh: refresh);

  void cancelOutgoing() => _sender.cancelOutgoing();
}
