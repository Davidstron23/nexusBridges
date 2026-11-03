import 'dart:async';
import 'dart:io';

import '../identity/identity.dart' show DeviceIdentity;
import '../pairing/pairing.dart' show PairedDevicesStore;
import '../protocol/protocol.dart' show Limits, monotonicClock;
import '../server/server.dart' show ApiRoute, ApiUploadRoute;
import 'folder_writer.dart' show ClearHidden, MarkFile;
import 'journal.dart' show TempJournal;
import 'messages.dart' show DestinationRequest;
import 'names.dart' show visibleFileName;
import 'pickers.dart' show PickerTracker;
import 'platform.dart'
    show FileSystemPlatform, FilePicker, FolderRevealer, FreeNameMove;
import 'receiver.dart' show TransferReceiver;
import 'sender.dart' show TransferSender;
import 'windows_file_system.dart' show WindowsFileSystemPlatform;
import 'windows_shell.dart' show WindowsFolderRevealer;
import 'writer.dart' show writeAllBytes;

export '../transport/transport.dart' show AbortSignal;
export 'folder_size.dart' show measureFolderSize;
export 'folders.dart'
    show
        ForbiddenFolders,
        isAdminShare,
        isForbiddenFolder,
        isInsideTempFolder,
        isSameOrInside,
        loadForbiddenFolders,
        samePath,
        tempFolderName,
        tempPrefix;
export 'journal.dart' show TempJournal;
export 'messages.dart' show DestinationRequest;
export 'names.dart'
    show
        RelativePathProblem,
        baseName,
        candidateFolderName,
        candidateName,
        checkRelativePath,
        isAppReservedName,
        isBlockedType,
        isValidFileName,
        isValidFolderName,
        visibleFileName;
export 'platform.dart'
    show
        DestinationChanged,
        FileSystemPlatform,
        FilePicker,
        FolderRevealer,
        FreeNameMove,
        MoveFailed,
        MovedTo,
        NameTooLong,
        NoFreeName;
export 'windows_file_system.dart' show WindowsFileSystemPlatform;
export 'windows_shell.dart' show WindowsFilePicker;
export 'writer.dart' show writeAllBytes;

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
  unconfirmed,
  shortcut,
  wholeDrive,
  protectedData,
  notFound,
  tooManyEntries,
  tooDeep,
  tooLargeForPeer,
  unexpectedData,
  defaultFolderOnly,
  destinationUnavailable,
  destinationMissing,
  destinationLost,
  shareRemoved,
  peerMarkedForeign;

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
    pathTooLong ||
    shortcut ||
    wholeDrive ||
    protectedData ||
    tooManyEntries ||
    tooDeep ||
    tooLargeForPeer ||
    defaultFolderOnly ||
    destinationUnavailable ||
    destinationMissing => TransferResultKind.rejected,
    cancelledHere ||
    cancelledByPeer ||
    unpaired ||
    shareRemoved ||
    peerMarkedForeign => TransferResultKind.cancelled,
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
    interfaceDown ||
    notFound ||
    unexpectedData ||
    destinationLost => TransferResultKind.failed,
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

final class FolderSummaryView {
  const FolderSummaryView({
    required this.files,
    required this.folders,
    required this.totalBytes,
    required this.excludedFolders,
    required this.excludedBytes,
    required this.linksOmitted,
    required this.protectedOmitted,
    required this.blockedOmitted,
    required this.containsPrograms,
    this.excludedBytesPartial = false,
  });

  final int files;
  final int folders;
  final int totalBytes;
  final int excludedFolders;
  final int excludedBytes;
  final int linksOmitted;
  final int protectedOmitted;
  final int blockedOmitted;
  final bool containsPrograms;
  final bool excludedBytesPartial;

  @override
  bool operator ==(Object other) =>
      other is FolderSummaryView &&
      other.files == files &&
      other.folders == folders &&
      other.totalBytes == totalBytes &&
      other.excludedFolders == excludedFolders &&
      other.excludedBytes == excludedBytes &&
      other.linksOmitted == linksOmitted &&
      other.protectedOmitted == protectedOmitted &&
      other.blockedOmitted == blockedOmitted &&
      other.containsPrograms == containsPrograms &&
      other.excludedBytesPartial == excludedBytesPartial;

  @override
  int get hashCode => Object.hash(
    files,
    folders,
    totalBytes,
    excludedFolders,
    excludedBytes,
    linksOmitted,
    protectedOmitted,
    blockedOmitted,
    containsPrograms,
    excludedBytesPartial,
  );
}

final class FirstLevelItem {
  const FirstLevelItem({required this.name, required this.isFolder});

  final String name;
  final bool isFolder;

  @override
  bool operator ==(Object other) =>
      other is FirstLevelItem &&
      other.name == name &&
      other.isFolder == isFolder;

  @override
  int get hashCode => Object.hash(name, isFolder);
}

bool _sameItems(List<FirstLevelItem> a, List<FirstLevelItem> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

final class DestinationLabel {
  const DestinationLabel({
    required this.rootName,
    required this.path,
    this.rootId,
    this.home = false,
  });

  final String? rootId;
  final String rootName;
  final bool home;
  final List<String> path;

  String display({required String homeName}) => [
    visibleFileName(home ? homeName : rootName),
    for (final part in path) visibleFileName(part),
  ].join(r'\');

  @override
  bool operator ==(Object other) =>
      other is DestinationLabel &&
      other.rootId == rootId &&
      other.rootName == rootName &&
      other.home == home &&
      _sameNames(other.path, path);

  @override
  int get hashCode => Object.hash(rootId, rootName, home, Object.hashAll(path));
}

bool _sameNames(List<String> a, List<String> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

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
    this.isFolder = false,
    this.fileCount = 0,
    this.sentFiles = 0,
    this.preparedEntries = 0,
    this.preparedFiles = 0,
    this.summary,
    this.destination,
  });

  final String peerFingerprint;
  final String? peerName;
  final String fileName;
  final int size;
  final bool isProgram;
  final OutgoingPhase phase;
  final int sentBytes;
  final bool cancelling;
  final bool isFolder;
  final int fileCount;
  final int sentFiles;
  final int preparedEntries;
  final int preparedFiles;
  final FolderSummaryView? summary;
  final DestinationLabel? destination;

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
      other.cancelling == cancelling &&
      other.isFolder == isFolder &&
      other.fileCount == fileCount &&
      other.sentFiles == sentFiles &&
      other.preparedEntries == preparedEntries &&
      other.preparedFiles == preparedFiles &&
      other.summary == summary &&
      other.destination == destination;

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
    isFolder,
    fileCount,
    sentFiles,
    preparedEntries,
    preparedFiles,
    summary,
    destination,
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
    this.afterEndPath,
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
  final String? afterEndPath;

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
      other.afterEnd == afterEnd &&
      other.afterEndPath == afterEndPath;

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
    afterEndPath,
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
    this.isFolder = false,
    this.fileCount = 0,
    this.receivedFiles = 0,
    this.firstLevel = const [],
    this.moreFirstLevel = 0,
    this.canCancel = true,
    this.containsGitRepository = false,
    this.destination,
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
  final bool isFolder;
  final int fileCount;
  final int receivedFiles;
  final List<FirstLevelItem> firstLevel;
  final int moreFirstLevel;
  final bool canCancel;
  final bool containsGitRepository;
  final DestinationLabel? destination;

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
      other.receivedBytes == receivedBytes &&
      other.isFolder == isFolder &&
      other.fileCount == fileCount &&
      other.receivedFiles == receivedFiles &&
      _sameItems(other.firstLevel, firstLevel) &&
      other.moreFirstLevel == moreFirstLevel &&
      other.canCancel == canCancel &&
      other.containsGitRepository == containsGitRepository &&
      other.destination == destination;

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
    isFolder,
    fileCount,
    receivedFiles,
    Object.hashAll(firstLevel),
    moreFirstLevel,
    canCancel,
    containsGitRepository,
    destination,
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
    this.isFolder = false,
    this.fileCount = 0,
    this.problemPath,
    this.size = 0,
    this.containsGitRepository = false,
    this.destination,
  });

  final TransferDirection direction;
  final String peerFingerprint;
  final String? peerName;
  final String fileName;
  final bool isProgram;
  final TransferOutcome outcome;
  final bool canReveal;
  final bool isFolder;
  final int fileCount;
  final String? problemPath;
  final int size;
  final bool containsGitRepository;
  final DestinationLabel? destination;

  @override
  bool operator ==(Object other) =>
      other is TransferResultView &&
      other.direction == direction &&
      other.peerFingerprint == peerFingerprint &&
      other.peerName == peerName &&
      other.fileName == fileName &&
      other.isProgram == isProgram &&
      other.outcome == outcome &&
      other.canReveal == canReveal &&
      other.isFolder == isFolder &&
      other.fileCount == fileCount &&
      other.problemPath == problemPath &&
      other.size == size &&
      other.containsGitRepository == containsGitRepository &&
      other.destination == destination;

  @override
  int get hashCode => Object.hash(
    direction,
    peerFingerprint,
    peerName,
    fileName,
    isProgram,
    outcome,
    canReveal,
    isFolder,
    fileCount,
    problemPath,
    size,
    containsGitRepository,
    destination,
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

sealed class SendDestination {
  const SendDestination();
}

final class ReceiveFolderDestination extends SendDestination {
  const ReceiveFolderDestination();
}

final class SharedFolderDestination extends SendDestination {
  const SharedFolderDestination({
    required this.rootId,
    required this.rootName,
    required this.path,
    this.home = false,
    this.newFolder,
  });

  final String rootId;
  final String rootName;
  final bool home;
  final List<String> path;
  final String? newFolder;

  DestinationLabel get label => DestinationLabel(
    rootId: rootId,
    rootName: rootName,
    home: home,
    path: [...path, ?newFolder],
  );
}

final class SharedRootGrant {
  const SharedRootGrant({
    required this.rootId,
    required this.label,
    required this.home,
    required this.pathUnits,
  });

  final String rootId;
  final String label;
  final bool home;
  final int pathUnits;
}

sealed class SharedResolution {
  const SharedResolution();
}

final class SharedResolved extends SharedResolution {
  const SharedResolved(this.lease);

  final SharedLease lease;
}

final class SharedRefused extends SharedResolution {
  const SharedRefused(this.reason);

  final SharedRefusal reason;
}

enum SharedRefusal { unavailable, missing }

abstract interface class SharedLease {
  String get folderPath;

  String get volumeId;

  bool get supportsMark;

  bool get cloud;

  int? get freeBytes;

  DestinationLabel get label;

  Future<bool> prepare();

  Future<FreeNameMove> recheckAndMove({
    required String tempName,
    required bool isFolder,
    required String name,
    int? maxNameUnits,
  });

  Future<void> release({required bool saved});
}

abstract interface class SharedFolders {
  Stream<void> get changes;

  SharedRootGrant? grantFor(String fingerprint, String rootId);

  Future<SharedResolution> resolve(
    String fingerprint,
    DestinationRequest destination, {
    required Duration timeout,
  });
}

final class NoSharedFolders implements SharedFolders {
  const NoSharedFolders();

  @override
  Stream<void> get changes => const Stream<void>.empty();

  @override
  SharedRootGrant? grantFor(String fingerprint, String rootId) => null;

  @override
  Future<SharedResolution> resolve(
    String fingerprint,
    DestinationRequest destination, {
    required Duration timeout,
  }) async => const SharedRefused(SharedRefusal.unavailable);
}

abstract interface class ExclusionSource {
  Future<List<String>?> load();
}

const List<String> defaultExclusions = ['node_modules', 'build', '.dart_tool'];

final class NoExclusionSource implements ExclusionSource {
  const NoExclusionSource();

  @override
  Future<List<String>?> load() async => null;
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

sealed class FolderChangeResult {
  const FolderChangeResult();
}

final class FolderChanged extends FolderChangeResult {
  const FolderChanged(this.path);

  final String path;
}

final class FolderUnchanged extends FolderChangeResult {
  const FolderUnchanged();
}

final class FolderChangeBlocked extends FolderChangeResult {
  const FolderChangeBlocked();
}

final class FolderChangeRefused extends FolderChangeResult {
  const FolderChangeRefused(this.problem, this.path);

  final FolderProblem problem;
  final String path;
}

final class FolderChangeNeedsConfirmation extends FolderChangeResult {
  const FolderChangeNeedsConfirmation({
    required this.changeId,
    required this.path,
    required this.noMark,
    required this.remote,
  });

  final String changeId;
  final String path;
  final bool noMark;
  final bool remote;
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
    ExclusionSource exclusions = const NoExclusionSource(),
    Future<void> Function(int entry)? beforeStreamEntry,
    MarkFile? markFile,
    ClearHidden? clearHidden,
    SharedFolders sharedFolders = const NoSharedFolders(),
    this._log = _noLog,
  }) : _picker = picker,
       _revealer = revealer ?? const WindowsFolderRevealer() {
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
      markFile: markFile,
      clearHidden: clearHidden,
      shared: sharedFolders,
      picker: picker,
      pickers: _pickers,
      onChanged: _notify,
      onResult: _result,
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
      onResult: _result,
      onFilePicker: (open) => open ? _pickers.open() : _pickers.close(),
      log: _log,
      dataDirPath: dataDirPath,
      exclusions: exclusions,
      beforeStreamEntry: beforeStreamEntry,
    );
  }

  final Duration _tickInterval;

  final void Function(String) _log;

  final FolderRevealer _revealer;

  final FilePicker _picker;

  bool _multiPickerOpen = false;

  late final TransferReceiver _receiver;

  late final PickerTracker _pickers;

  late final TransferSender _sender;

  final StreamController<void> _changes = StreamController<void>.broadcast();

  final StreamController<TransferEvent> _events =
      StreamController<TransferEvent>.broadcast();

  final StreamController<TransferResultView> _finished =
      StreamController<TransferResultView>.broadcast();

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
    bool,
    String?,
  )?
  _lastNotified = (null, null, null, null, false, false, false, null);

  List<ApiRoute> get routes => _receiver.routes;

  List<ApiUploadRoute> get uploadRoutes => _receiver.uploadRoutes;

  IncomingTransferView? get incoming => _receiver.incoming;

  TransferResultView? get lastReceived => _receiver.lastReceived;

  bool get busy => _receiver.busy || sending;

  bool get pickerOpen => _pickers.isOpen;

  bool get receiveFolderLocked => _receiver.receiveFolderLocked;

  String? get receiveFolderPath => _receiver.receiveFolderPath;

  Stream<void> get changes => _changes.stream;

  Stream<TransferEvent> get events => _events.stream;

  Stream<TransferResultView> get finished => _finished.stream;

  void start() {
    if (_closed || _timer != null) return;
    _timer = Timer.periodic(_tickInterval, (_) => _tick());
    unawaited(_receiver.start().then((_) => _syncFolderPath()));
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

  Future<FolderChangeResult> changeReceiveFolder() =>
      _receiver.changeReceiveFolder();

  Future<FolderChangeResult> confirmReceiveFolder(String changeId) =>
      _receiver.confirmReceiveFolder(changeId);

  void cancelReceiveFolderChange(String changeId) =>
      _receiver.cancelReceiveFolderChange(changeId);

  void interfacesChanged(Set<String> activeInterfaceIds) {
    _receiver.interfacesChanged(activeInterfaceIds);
    _sender.interfacesChanged(activeInterfaceIds);
  }

  int sessionsVia(Set<String> interfaceIds) =>
      _receiver.sessionsVia(interfaceIds) + _sender.sessionsVia(interfaceIds);

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
    await _finished.close();
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
      receiveFolderLocked,
      receiveFolderPath,
    );
    if (current == _lastNotified) return;
    _lastNotified = current;
    _changes.add(null);
  }

  void _syncFolderPath() {
    final last = _lastNotified;
    if (_closed || last == null) return;
    _lastNotified = (
      last.$1,
      last.$2,
      last.$3,
      last.$4,
      last.$5,
      last.$6,
      last.$7,
      receiveFolderPath,
    );
  }

  void _emit(TransferEvent event) {
    if (_closed) return;
    _events.add(event);
  }

  void _result(TransferResultView result) {
    if (_closed) return;
    _finished.add(result);
  }

  OutgoingTransferView? get outgoing => _sender.outgoing;

  TransferResultView? get lastSent => _sender.lastSent;

  bool get sending => _sender.sending || _multiPickerOpen;

  Future<List<String>> pickFilesToSend() => _pickMany(_picker.pickFiles);

  Future<List<String>> pickFoldersToSend() => _pickMany(_picker.pickFolders);

  Future<String?> pickFolderToShare() async {
    if (_closed || _closing != null || _pickers.isOpen) return null;
    _pickers.open();
    _notify();
    String? chosen;
    try {
      chosen = await _picker.pickFolder();
    } catch (e) {
      _log('share picker failed: ${e.runtimeType}');
    } finally {
      _pickers.close();
      _notify();
    }
    if (_closed || _closing != null) return null;
    return chosen;
  }

  Future<List<String>> _pickMany(Future<List<String>> Function() pick) async {
    if (_closed || _closing != null || _pickers.isOpen) return const [];
    _multiPickerOpen = true;
    _pickers.open();
    _notify();
    List<String> chosen = const [];
    try {
      chosen = await pick();
    } catch (e) {
      _log('multiple picker failed: ${e.runtimeType}');
    } finally {
      _multiPickerOpen = false;
      _pickers.close();
      _notify();
    }
    if (_closed || _closing != null) return const [];
    return chosen;
  }

  Future<SendStart> sendFile(
    SendTarget target, {
    required SendTarget? Function() refresh,
  }) => _sender.sendFile(target, refresh: refresh);

  Future<TransferResultView?> sendElement(
    SendTarget target,
    String path, {
    required SendTarget? Function() refresh,
    SendDestination destination = const ReceiveFolderDestination(),
  }) => _sender.sendElement(
    target,
    path,
    refresh: refresh,
    destination: destination,
  );

  void cancelOutgoing() => _sender.cancelOutgoing();

  Future<RevealResult> revealLastReceived() async {
    final result = _receiver.lastReceived;
    final path = _receiver.lastReceivedPath;
    if (_closing != null ||
        result == null ||
        !result.canReveal ||
        path == null) {
      return RevealResult.unavailable;
    }
    try {
      return await _revealer.reveal(path);
    } catch (e) {
      _log('reveal failed: ${e.runtimeType}');
      return RevealResult.unavailable;
    }
  }
}
