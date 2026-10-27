import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import '../pairing/pairing.dart'
    show PairedDevicesStore, PeerRelation, Permission;
import '../protocol/protocol.dart';
import '../server/server.dart';
import '../transport/transport.dart' show AbortSignal;
import 'decision.dart';
import 'folders.dart';
import 'messages.dart';
import 'names.dart'
    show isBlockedType, isProgram, isValidFileName, visibleFileName;
import 'pickers.dart';
import 'platform.dart';
import 'recent_rejections.dart';
import 'transfer.dart';
import 'writer.dart';

const Duration _closeHeldGrace = Duration(seconds: 1);

const Duration _closeFinishingGrace = Duration(seconds: 2);

const ApiReply _unauthorized = ApiReply(401, {'error': 'unauthorized'});

const ApiReply _declined = ApiReply(403, {'error': 'declined'});

const ApiReply _busy = ApiReply(409, {'error': 'busy'});

const ApiReply _unavailable = ApiReply(503, {'error': 'busy'});

const ApiReply _incompatible = ApiReply(400, {'error': 'incompatible'});

const ApiReply _cancelled = ApiReply(410, {'error': 'cancelled'});

const ApiReply _invalidName = ApiReply(422, {'error': 'invalid_name'});

const ApiReply _pathTooLong = ApiReply(422, {'error': 'path_too_long'});

const ApiReply _noSpace = ApiReply(507, {'error': 'no_space'});

const ApiReply _blockedType = ApiReply(415, {'error': 'blocked_type'});

const ApiReply _notFound = ApiReply(404, {'error': 'not_found'});

const ApiReply _internal = ApiReply(500, {'error': 'internal'});

const ApiReply _uploadForbidden = ApiReply(403, {'error': 'forbidden'});

const RouteLimit _offerLimit = RouteLimit(
  maxPerWindow: Limits.transferOffersPerMinute,
  window: Duration(minutes: 1),
  block: Limits.routeBlock,
);

const RouteLimit _waitLimit = RouteLimit(
  maxPerWindow: Limits.transferPollsPerMinute,
  window: Duration(minutes: 1),
  block: Limits.routeBlock,
);

const RouteLimit _cancelLimit = RouteLimit(
  maxPerWindow: Limits.transferCancelsPerMinute,
  window: Duration(minutes: 1),
  block: Limits.routeBlock,
);

const RouteLimit _uploadLimit = RouteLimit(
  maxPerWindow: Limits.transferUploadsPerMinute,
  window: Duration(minutes: 1),
  block: Limits.routeBlock,
);

final RegExp _permitPattern = RegExp(r'^[0-9a-f]{32}$');

final Uint8List _noPermit = Uint8List(16);

Uint8List? _permitBytes(String? value) {
  if (value == null || !_permitPattern.hasMatch(value)) return null;
  final bytes = Uint8List(16);
  for (var i = 0; i < 16; i++) {
    bytes[i] = int.parse(value.substring(i * 2, i * 2 + 2), radix: 16);
  }
  return bytes;
}

bool _permitMatches(String? presented, String? expected) {
  final given = _permitBytes(presented);
  final wanted = _permitBytes(expected);
  var difference = given == null || wanted == null ? 1 : 0;
  final left = given ?? _noPermit;
  final right = wanted ?? _noPermit;
  for (var i = 0; i < 16; i++) {
    difference |= left[i] ^ right[i];
  }
  return difference == 0;
}

String _joinPath(String folder, String name) =>
    folder.endsWith(r'\') ? '$folder$name' : '$folder\\$name';

bool _exceedsFinalPath(String folderPath, String name) {
  final separator = folderPath.endsWith(r'\') ? 0 : 1;
  return folderPath.length + separator + name.length > Limits.maxFinalPathChars;
}

String _randomHex32() {
  final random = Random.secure();
  final buffer = StringBuffer();
  for (var i = 0; i < 16; i++) {
    buffer.write(random.nextInt(256).toRadixString(16).padLeft(2, '0'));
  }
  return buffer.toString();
}

enum _InPhase {
  checking,
  warning,
  folderQuestion,
  accepted,
  uploading,
  finishing,
  ended,
}

final class _InSession {
  _InSession({
    required this.localId,
    required this.arrivedAt,
    required this.fingerprint,
    required this.id,
    required this.via,
    required this.name,
    required this.peerName,
    required this.size,
    required this.sha256,
    required this.isProgram,
  });

  final String localId;

  final Duration arrivedAt;

  final String fingerprint;

  final String id;

  final String via;

  final String name;

  final String? peerName;

  final int size;

  final String sha256;

  bool isProgram;

  _InPhase phase = _InPhase.checking;

  Duration? shownAt;

  Duration frozen = Duration.zero;

  bool shown = false;

  bool exposed = false;

  bool undelivered = false;

  Duration? decidedAt;

  bool warned = false;

  bool withoutMark = false;

  ReceiveTarget? target;

  String? tempPath;

  ReceiveFolder? remembered;

  bool rememberedLost = false;

  bool proposalLost = false;

  String proposedPath = '';

  _FolderAsk? ask;

  String? permit;

  Duration? acceptedAt;

  Duration? lastPollAt;

  bool permitUsed = false;

  Duration? lastDataAt;

  Duration? progressAt;

  bool writing = false;

  int received = 0;

  bool bodyFailed = false;

  ApiUpload? upload;

  IncomingFileWriter? writer;

  Completer<void>? bodyEnded;

  int held = 0;

  TransferOutcome? outcome;

  Completer<void> changed = Completer<void>();

  final Completer<void> finished = Completer<void>();
}

final class _FolderAsk {
  _FolderAsk({required this.kind, required this.proposedPath, this.problem});

  final FolderQuestionKind kind;

  final String proposedPath;

  FolderProblem? problem;

  String? problemPath;

  String? cautionPath;

  bool cautionNoMark = false;

  bool cautionRemote = false;

  ReceiveTarget? pending;

  bool pendingCreated = false;

  bool pickerOpen = false;

  bool inspecting = false;

  AfterEndResult? afterEnd;

  String? afterEndPath;

  FolderQuestionView get view => FolderQuestionView(
    kind: kind,
    proposedPath: proposedPath,
    problem: problem,
    problemPath: problemPath,
    cautionPath: cautionPath,
    cautionNoMark: cautionNoMark,
    cautionRemote: cautionRemote,
    pickerOpen: pickerOpen,
    inspecting: inspecting,
    afterEnd: afterEnd,
    afterEndPath: afterEndPath,
  );

  String? takeCreatedPending() {
    final path = pendingCreated ? pending?.path : null;
    clearCaution();
    return path;
  }

  void clearCaution() {
    cautionPath = null;
    cautionNoMark = false;
    cautionRemote = false;
    pending = null;
    pendingCreated = false;
  }
}

final class _Deadline {
  _Deadline({required this.at, required this.abort});

  final Duration at;

  final AbortSignal abort;

  final Completer<void> expired = Completer<void>();

  void expire() {
    abort.abort();
    if (!expired.isCompleted) expired.complete();
  }
}

final class _Record {
  const _Record({
    required this.fingerprint,
    required this.id,
    required this.state,
    required this.tombstone,
    required this.at,
  });

  final String fingerprint;

  final String id;

  final RemoteState state;

  final bool tombstone;

  final Duration at;
}

final class TransferReceiver {
  TransferReceiver({
    required this._paired,
    required this._folders,
    required this._journal,
    required this._fs,
    required this._dataDirPath,
    required this._clock,
    required this._pollHold,
    required this._picker,
    required this._pickers,
    required this._onChanged,
    required this._emit,
    required this._log,
    this._writeBytes = writeAllBytes,
    this._idleTimeout = Limits.transferIdleTimeout,
  });

  final PairedDevicesStore _paired;

  final ReceiveFolderStore _folders;

  final TempJournal _journal;

  final FileSystemPlatform _fs;

  final String _dataDirPath;

  final Duration Function() _clock;

  final Duration _pollHold;

  final FilePicker _picker;

  final PickerTracker _pickers;

  final void Function() _onChanged;

  final void Function(TransferEvent event) _emit;

  final void Function(String) _log;

  final Future<void> Function(RandomAccessFile file, List<int> bytes)
  _writeBytes;

  final Duration _idleTimeout;

  late final RecentRejections _recentRejections = RecentRejections(
    clock: _clock,
  );

  late final RecentRejections _recentNoSpace = RecentRejections(clock: _clock);

  final Map<(String, String), _Record> _records = {};

  _InSession? _active;

  TransferResultView? _lastReceived;

  String? _lastReceivedPath;

  bool _closed = false;

  int _held = 0;

  Completer<void>? _drained;

  Future<ReceiveFolder?>? _rememberedLoad;

  _InSession? _panel;

  _FolderAsk? _folderPickerAsk;

  final List<_Deadline> _deadlines = [];

  final Set<Future<void>> _cleanups = {};

  SystemFolders? _systemFolders;

  Future<SystemFolders>? _systemFoldersInFlight;

  ForbiddenFolders? _forbidden;

  Future<ForbiddenFolders?>? _forbiddenInFlight;

  Completer<void>? _cleanupDone;

  Future<void>? _cleanupRun;

  late final List<ApiRoute> routes = List.unmodifiable([
    ApiRoute(
      path: ApiPaths.transferOffer,
      access: RouteAccess.paired,
      handle: _handleOffer,
      maxBodyBytes: Limits.maxTransferBodyBytes,
      limit: _offerLimit,
    ),
    ApiRoute(
      path: ApiPaths.transferWait,
      access: RouteAccess.paired,
      handle: _handleWait,
      maxBodyBytes: Limits.maxTransferBodyBytes,
      limit: _waitLimit,
    ),
    ApiRoute(
      path: ApiPaths.transferCancel,
      access: RouteAccess.paired,
      handle: _handleCancel,
      maxBodyBytes: Limits.maxTransferBodyBytes,
      limit: _cancelLimit,
    ),
  ]);

  late final List<ApiUploadRoute> uploadRoutes = List.unmodifiable([
    ApiUploadRoute(
      path: ApiPaths.transferUpload,
      handle: _handleUpload,
      limit: _uploadLimit,
    ),
  ]);

  bool get busy => _active != null || _folderPickerAsk != null;

  TransferResultView? get lastReceived => _lastReceived;

  String? get lastReceivedPath => _lastReceivedPath;

  IncomingTransferView? get incoming {
    final session = _active;
    if (session != null && session.exposed) {
      final stage = switch (session.phase) {
        _InPhase.warning => IncomingStage.warning,
        _InPhase.folderQuestion => IncomingStage.folderQuestion,
        _InPhase.accepted => IncomingStage.waitingData,
        _InPhase.uploading => IncomingStage.receiving,
        _InPhase.finishing => IncomingStage.verifying,
        _InPhase.checking || _InPhase.ended => null,
      };
      if (stage != null) {
        return IncomingTransferView(
          sessionId: session.localId,
          peerFingerprint: session.fingerprint,
          peerName: session.peerName,
          fileName: visibleFileName(session.name),
          size: session.size,
          isProgram: session.isProgram,
          stage: stage,
          withoutMark: session.phase == _InPhase.warning && session.withoutMark,
          folder: session.phase == _InPhase.folderQuestion
              ? session.ask?.view
              : null,
          receivedBytes: session.received,
        );
      }
    }
    final ended = _panel;
    final ask = ended?.ask;
    if (ended == null || ask == null) return null;
    return IncomingTransferView(
      sessionId: ended.localId,
      peerFingerprint: ended.fingerprint,
      peerName: ended.peerName,
      fileName: visibleFileName(ended.name),
      size: ended.size,
      isProgram: ended.isProgram,
      stage: IncomingStage.ended,
      folder: ask.view,
    );
  }

  void start() {
    if (_closed) return;
    unawaited(_rememberedFolder());
    unawaited(_forbiddenFolders());
  }

  void answerWarning(String sessionId, {required bool accept}) {
    final session = _active;
    if (_closed ||
        session == null ||
        session.localId != sessionId ||
        !session.exposed ||
        session.phase != _InPhase.warning) {
      return;
    }
    if (accept) {
      session.warned = true;
      _advance(session);
      return;
    }
    _noteForeignRejection(session.fingerprint);
    _end(session, TransferOutcome.declined);
  }

  void _noteForeignRejection(String fingerprint) {
    final device = _paired.deviceOf(fingerprint);
    if (device != null && device.relation == PeerRelation.foreign) {
      _recentRejections.record(fingerprint);
    }
  }

  void cancelIncoming(String sessionId) {
    final session = _active;
    if (_closed ||
        session == null ||
        session.localId != sessionId ||
        !session.exposed ||
        (session.phase != _InPhase.accepted &&
            session.phase != _InPhase.uploading)) {
      return;
    }
    _end(session, TransferOutcome.cancelledHere);
  }

  void interfacesChanged(Set<String> activeInterfaceIds) {
    final session = _active;
    if (_closed || session == null) return;
    if (session.phase == _InPhase.finishing) return;
    if (activeInterfaceIds.contains(session.via)) return;
    _end(session, TransferOutcome.interfaceDown);
  }

  void pairedChanged() {
    final session = _active;
    if (_closed || session == null) return;
    if (session.phase == _InPhase.finishing) return;
    if (_paired.deviceOf(session.fingerprint) != null) return;
    _end(session, TransferOutcome.unpaired);
  }

  void peerUnpaired(String fingerprint) {
    final session = _active;
    if (_closed || session == null) return;
    if (session.phase == _InPhase.finishing) return;
    if (session.fingerprint != fingerprint) return;
    _end(session, TransferOutcome.unpaired);
  }

  void tick() {
    if (_closed) return;
    final now = _clock();
    final session = _active;
    if (session != null) _tickSession(session, now);
    for (final deadline in List<_Deadline>.of(_deadlines)) {
      if (now >= deadline.at) deadline.expire();
    }
    _pruneRecords(now);
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    final session = _active;
    _InSession? finishing;
    if (session != null) {
      switch (session.phase) {
        case _InPhase.checking:
          _end(session, TransferOutcome.cancelledHere, register: false);
        case _InPhase.warning:
          _end(session, TransferOutcome.declined);
        case _InPhase.folderQuestion:
          _end(session, TransferOutcome.noFolder);
        case _InPhase.accepted || _InPhase.uploading:
          _end(session, TransferOutcome.cancelledHere);
        case _InPhase.finishing:
          finishing = session;
        case _InPhase.ended:
          break;
      }
    }
    for (final deadline in List<_Deadline>.of(_deadlines)) {
      deadline.expire();
    }
    final panel = _panel;
    if (panel != null) _dropPanel(panel);
    if (finishing != null) {
      await finishing.finished.future.timeout(
        _closeFinishingGrace,
        onTimeout: () {},
      );
      _signal(finishing);
    }
    if (_held != 0) {
      final drained = Completer<void>();
      _drained = drained;
      final timer = Timer(_closeHeldGrace, () {
        if (!drained.isCompleted) drained.complete();
      });
      await drained.future;
      timer.cancel();
    }
    final cleanupRun = _cleanupRun;
    await Future.wait([...List<Future<void>>.of(_cleanups), ?cleanupRun]);
  }

  Future<void> cleanupAtStart() {
    if (_closed) return Future<void>.value();
    return _cleanupRun ??= _runCleanup();
  }

  Future<void> _runCleanup() async {
    final done = Completer<void>();
    _cleanupDone = done;
    try {
      for (final folder in List<ReceiveFolder>.of(_journal.folders)) {
        if (_closed) break;
        await _inspectBounded(
          folder.path,
          expectedVolume: folder.volumeId,
          mayCreate: false,
          until: _clock() + Limits.transferCleanupCheckTimeout,
          afterUsable: (target) =>
              _sweepFolder(target.path, journalPath: folder.path),
        );
      }
    } catch (e) {
      _log('startup cleanup failed: ${e.runtimeType}');
    } finally {
      if (!done.isCompleted) done.complete();
    }
  }

  Future<void> _sweepFolder(String path, {String? journalPath}) async {
    try {
      final clean = await sweepTemps(path, _fs, keep: _activeTemps());
      if (clean) await _journal.remove(journalPath ?? path);
    } catch (e) {
      _log('temp cleanup failed: ${e.runtimeType}');
    }
  }

  Set<String> _activeTemps() {
    final path = _active?.tempPath;
    return path == null ? const {} : {path};
  }

  void pickersChanged(bool open, Duration since) {
    final session = _active;
    if (session != null) {
      if (!open &&
          session.exposed &&
          (session.phase == _InPhase.warning ||
              session.phase == _InPhase.folderQuestion)) {
        final shownAt = session.shownAt;
        if (shownAt != null) {
          final from = since > shownAt ? since : shownAt;
          final span = _clock() - from;
          if (span > Duration.zero) session.frozen += span;
        }
      }
      _signal(session);
    }
    _onChanged();
  }

  Future<void> useProposedFolder(String sessionId) async {
    final action = _actionable(sessionId);
    if (action == null) return;
    await _probe(action.session, action.ask, action.ask.proposedPath);
  }

  Future<void> chooseOtherFolder(String sessionId) async {
    final action = _actionable(sessionId);
    if (action == null) return;
    final session = action.session;
    final ask = action.ask;
    ask.pickerOpen = true;
    _folderPickerAsk = ask;
    final created = ask.takeCreatedPending();
    if (created != null) _track(() => _removeIfEmpty(created));
    _pickers.open();
    _onChanged();
    String? chosen;
    try {
      chosen = await _picker.pickFolder(
        startIn: _parentFolder(ask.proposedPath),
      );
    } catch (e) {
      _log('folder picker failed: ${e.runtimeType}');
    }
    ask.pickerOpen = false;
    _folderPickerAsk = null;
    _pickers.close();
    if (_closed) {
      _onChanged();
      return;
    }
    if (session.phase == _InPhase.ended) {
      await _chooseAfterEnd(session, ask, chosen);
      return;
    }
    if (chosen == null) {
      _onChanged();
      return;
    }
    await _probe(session, ask, chosen);
  }

  void useFolderAnyway(String sessionId) {
    final action = _actionable(sessionId);
    final pending = action?.ask.pending;
    if (action == null || pending == null) return;
    final ask = action.ask;
    final createdNow = ask.pendingCreated;
    ask.inspecting = true;
    ask.clearCaution();
    _onChanged();
    unawaited(_confirm(action.session, ask, pending, createdNow));
  }

  void cancelFolderQuestion(String sessionId) {
    final action = _actionable(sessionId);
    if (action == null) return;
    _end(action.session, TransferOutcome.noFolder);
  }

  Future<void> rememberFolderAfterEnd(
    String sessionId, {
    required bool remember,
  }) async {
    final session = _panel;
    final ask = session?.ask;
    if (_closed ||
        session == null ||
        session.localId != sessionId ||
        ask == null ||
        ask.inspecting ||
        ask.pickerOpen ||
        ask.afterEnd != AfterEndResult.needsConfirmation) {
      return;
    }
    final target = ask.pending;
    if (!remember || target == null) {
      _dropPanel(session);
      return;
    }
    ask.inspecting = true;
    _onChanged();
    final path = target.path;
    try {
      await _remember(target);
      ask.clearCaution();
      ask.afterEnd = AfterEndResult.remembered;
      ask.afterEndPath = path;
    } finally {
      ask.inspecting = false;
      _onChanged();
    }
  }

  void dismissFolderPanel(String sessionId) {
    final session = _panel;
    final ask = session?.ask;
    if (_closed ||
        session == null ||
        session.localId != sessionId ||
        ask == null ||
        ask.inspecting ||
        ask.pickerOpen) {
      return;
    }
    _dropPanel(session);
  }

  ({_InSession session, _FolderAsk ask})? _actionable(String sessionId) {
    final session = _active;
    if (_closed ||
        session == null ||
        session.localId != sessionId ||
        !session.exposed ||
        session.phase != _InPhase.folderQuestion) {
      return null;
    }
    final ask = session.ask;
    if (ask == null || ask.inspecting || ask.pickerOpen) return null;
    return (session: session, ask: ask);
  }

  Future<void> _probe(_InSession session, _FolderAsk ask, String path) async {
    ask.inspecting = true;
    final created = ask.takeCreatedPending();
    _onChanged();
    try {
      if (created != null) await _removeIfEmpty(created);
      final remembered = session.remembered;
      final result = await _inspectBounded(
        path,
        expectedVolume: remembered != null && samePath(path, remembered.path)
            ? remembered.volumeId
            : null,
      );
      if (_closed || session.phase == _InPhase.ended) {
        _discardCreated(result);
        return;
      }
      switch (result) {
        case FolderRefused(:final reason):
          ask
            ..problem = _problemFor(reason, session, ask, path)
            ..problemPath = path;
        case FolderUsable(:final target, :final createdNow):
          if (target.remote || target.cloud || !target.supportsMark) {
            ask
              ..problem = null
              ..problemPath = null
              ..cautionPath = path
              ..cautionNoMark = !target.supportsMark
              ..cautionRemote = target.remote || target.cloud
              ..pending = target
              ..pendingCreated = createdNow;
          } else {
            await _chosen(session, ask, target, createdNow);
          }
      }
    } finally {
      ask.inspecting = false;
      _onChanged();
    }
  }

  Future<void> _confirm(
    _InSession session,
    _FolderAsk ask,
    ReceiveTarget target,
    bool createdNow,
  ) async {
    try {
      await _chosen(session, ask, target, createdNow);
    } catch (e) {
      _log('folder choice failed: ${e.runtimeType}');
    } finally {
      ask.inspecting = false;
      _onChanged();
    }
  }

  Future<void> _chosen(
    _InSession session,
    _FolderAsk ask,
    ReceiveTarget target,
    bool createdNow,
  ) async {
    if (ask.kind == FolderQuestionKind.firstTime) await _remember(target);
    if (_closed || session.phase == _InPhase.ended) {
      _keepRememberedPanel(session, ask, target);
      _dropUnused(ask, target, createdNow);
      return;
    }
    await _sweepFolder(target.path);
    if (_closed || session.phase == _InPhase.ended) {
      _keepRememberedPanel(session, ask, target);
      _dropUnused(ask, target, createdNow);
      return;
    }
    session.target = target;
    if (_limitReply(session, target) != null) {
      _dropUnused(ask, target, createdNow);
      return;
    }
    _advance(session);
  }

  void _keepRememberedPanel(
    _InSession session,
    _FolderAsk ask,
    ReceiveTarget target,
  ) {
    if (_closed || ask.kind != FolderQuestionKind.firstTime) return;
    ask
      ..problem = null
      ..problemPath = null
      ..afterEnd = AfterEndResult.remembered
      ..afterEndPath = target.path;
    if (_panel == null && !(_active?.exposed ?? false)) _panel = session;
  }

  void _dropUnused(_FolderAsk ask, ReceiveTarget target, bool createdNow) {
    if (createdNow && ask.kind == FolderQuestionKind.thisTime) {
      _track(() => _removeIfEmpty(target.path));
    }
  }

  ApiReply? _limitReply(_InSession session, ReceiveTarget target) {
    if (_exceedsFinalPath(target.path, session.name)) {
      _end(session, TransferOutcome.pathTooLong);
      return _pathTooLong;
    }
    if (!hasRoomFor(target.freeBytes, session.size)) {
      final throttled = _recentNoSpace.blocks(session.fingerprint);
      if (throttled && !session.exposed) {
        _end(session, TransferOutcome.noSpace, register: false);
      } else {
        session.shown = true;
        if (!throttled) _recentNoSpace.record(session.fingerprint);
        _end(session, TransferOutcome.noSpace);
      }
      return _noSpace;
    }
    return null;
  }

  Future<void> _remember(ReceiveTarget target) async {
    final folder = ReceiveFolder(path: target.path, volumeId: target.volumeId);
    var saved = false;
    try {
      saved = await _folders.save(folder);
    } catch (e) {
      _log('receive folder save failed: ${e.runtimeType}');
    }
    _rememberedLoad = Future<ReceiveFolder?>.value(folder);
    if (!saved) _emit(ReceiveFolderNotSaved(target.path));
  }

  Future<void> _chooseAfterEnd(
    _InSession session,
    _FolderAsk ask,
    String? chosen,
  ) async {
    if (chosen == null || ask.kind == FolderQuestionKind.thisTime) {
      _dropPanel(session);
      return;
    }
    ask
      ..problem = null
      ..problemPath = null;
    ask.inspecting = true;
    _onChanged();
    try {
      final result = await _inspectBounded(chosen);
      if (_closed || !identical(_panel, session)) {
        _discardCreated(result);
        return;
      }
      switch (result) {
        case FolderRefused():
          ask
            ..afterEnd = AfterEndResult.notUsable
            ..afterEndPath = chosen;
        case FolderUsable(:final target, :final createdNow):
          if (target.remote || target.cloud || !target.supportsMark) {
            ask
              ..cautionPath = chosen
              ..cautionNoMark = !target.supportsMark
              ..cautionRemote = target.remote || target.cloud
              ..pending = target
              ..pendingCreated = createdNow
              ..afterEnd = AfterEndResult.needsConfirmation;
          } else {
            await _remember(target);
            ask
              ..afterEnd = AfterEndResult.remembered
              ..afterEndPath = target.path;
          }
      }
    } finally {
      ask.inspecting = false;
      _onChanged();
    }
  }

  FolderProblem _problemFor(
    FolderRefusal reason,
    _InSession session,
    _FolderAsk ask,
    String path,
  ) {
    switch (reason) {
      case FolderRefusal.forbidden:
        return FolderProblem.forbidden;
      case FolderRefusal.unknownVolume:
        return FolderProblem.unknownVolume;
      case FolderRefusal.adminShare:
        return FolderProblem.adminShare;
      case FolderRefusal.cannotUse || FolderRefusal.otherVolume:
        final remembered = session.remembered;
        return ask.kind == FolderQuestionKind.thisTime &&
                remembered != null &&
                samePath(path, remembered.path)
            ? FolderProblem.stillUnavailable
            : FolderProblem.cannotUse;
    }
  }

  void _dropPanel(_InSession session) {
    if (!identical(_panel, session)) return;
    _panel = null;
    final created = session.ask?.takeCreatedPending();
    if (created != null) _track(() => _removeIfEmpty(created));
    _onChanged();
  }

  Future<FolderInspection> _inspectBounded(
    String path, {
    String? expectedVolume,
    bool mayCreate = true,
    Duration? until,
    Future<void> Function(ReceiveTarget target)? afterUsable,
  }) async {
    if (_closed) return const FolderRefused(FolderRefusal.cannotUse);
    final abort = AbortSignal();
    final deadline = _newDeadline(
      until ?? _clock() + Limits.transferFolderChoiceTimeout,
      abort,
    );
    final run = _inspectOnce(
      path,
      abort,
      expectedVolume,
      mayCreate,
      afterUsable,
    );
    unawaited(
      run.then((result) {
        if (deadline.expired.isCompleted) _discardCreated(result);
      }),
    );
    try {
      return await Future.any<FolderInspection>([
        run,
        deadline.expired.future.then<FolderInspection>(
          (_) => const FolderRefused(FolderRefusal.cannotUse),
        ),
      ]);
    } finally {
      _deadlines.remove(deadline);
    }
  }

  _Deadline _newDeadline(Duration at, AbortSignal abort) {
    final deadline = _Deadline(at: at, abort: abort);
    _deadlines.add(deadline);
    if (_clock() >= at) deadline.expire();
    return deadline;
  }

  Future<({bool expired, T? value})> _race<T>(
    Future<T> work,
    Duration until,
  ) async {
    final deadline = _newDeadline(until, AbortSignal());
    try {
      return await Future.any<({bool expired, T? value})>([
        work.then<({bool expired, T? value})>(
          (value) => (expired: false, value: value),
        ),
        deadline.expired.future.then<({bool expired, T? value})>(
          (_) => (expired: true, value: null),
        ),
      ]);
    } finally {
      _deadlines.remove(deadline);
    }
  }

  Future<FolderInspection> _inspectOnce(
    String path,
    AbortSignal abort,
    String? expectedVolume,
    bool mayCreate,
    Future<void> Function(ReceiveTarget target)? afterUsable,
  ) async {
    try {
      final forbidden = await _forbiddenFolders();
      final result = await inspectFolder(
        path,
        fs: _fs,
        forbidden: forbidden,
        mayCreate: mayCreate,
        expectedVolume: expectedVolume,
        abort: abort,
      );
      if (afterUsable != null && result is FolderUsable && !abort.aborted) {
        await afterUsable(result.target);
      }
      return result;
    } catch (e) {
      _log('folder inspection failed: ${e.runtimeType}');
      return const FolderRefused(FolderRefusal.cannotUse);
    }
  }

  void _discardCreated(FolderInspection result) {
    if (result is FolderUsable && result.createdNow) {
      final path = result.target.path;
      _track(() => _removeIfEmpty(path));
    }
  }

  Future<void> _removeIfEmpty(String path) async {
    try {
      await Directory(path).delete();
    } catch (_) {}
  }

  void _track(Future<void> Function() work) {
    late final Future<void> task;
    task = (() async {
      try {
        await work();
      } catch (e) {
        _log('folder cleanup failed: ${e.runtimeType}');
      }
    })().whenComplete(() => _cleanups.remove(task));
    _cleanups.add(task);
  }

  String? _parentFolder(String path) {
    final cut = path.lastIndexOf(r'\');
    return cut <= 0 ? null : path.substring(0, cut);
  }

  Future<ApiReply> _handleOffer(ApiCall call) async {
    if (_closed) return _unavailable;
    _InSession? session;
    try {
      final screened = _screen(call);
      session = screened.session;
      if (session == null) return screened.refusal ?? _internal;
      return await _admit(session);
    } catch (e) {
      _log('transfer offer failed: ${e.runtimeType}');
      if (session != null) {
        _end(session, TransferOutcome.cancelledByPeer, register: false);
      }
      return _internal;
    }
  }

  ({ApiReply? refusal, _InSession? session}) _screen(ApiCall call) {
    final fingerprint = call.clientFingerprint;
    if (fingerprint == null) return (refusal: _unauthorized, session: null);
    final device = _paired.deviceOf(fingerprint);
    if (device == null) return (refusal: _unauthorized, session: null);
    if (!device.permissions.contains(Permission.receive)) {
      return (refusal: _declined, session: null);
    }
    if (_active != null || _folderPickerAsk != null) {
      return (refusal: _busy, session: null);
    }
    if (device.relation == PeerRelation.foreign &&
        _recentRejections.blocks(fingerprint)) {
      return (refusal: _declined, session: null);
    }
    final request = OfferRequest.tryParse(call.json);
    if (request == null) return (refusal: _incompatible, session: null);
    if (_recordOf(fingerprint, request.transfer)?.tombstone ?? false) {
      return (refusal: _cancelled, session: null);
    }
    if (!isValidFileName(request.name)) {
      return (refusal: _invalidName, session: null);
    }
    if (isBlockedType(request.name)) {
      return (refusal: _blockedType, session: null);
    }
    final session = _InSession(
      localId: _randomHex32(),
      arrivedAt: _clock(),
      fingerprint: fingerprint,
      id: request.transfer,
      via: call.via.id,
      name: request.name,
      peerName: sanitizeDisplayName(device.name),
      size: request.size,
      sha256: request.sha256,
      isProgram: isProgram(request.name),
    );
    _active = session;
    return (refusal: null, session: session);
  }

  bool _gone(_InSession session) => _closed || session.phase == _InPhase.ended;

  Future<ApiReply> _admit(_InSession session) async {
    final arrival = session.arrivedAt;
    final checkUntil = arrival + Limits.transferFolderCheckTimeout;
    final type = isProgramHere(session.name, _fs);
    if (!await _cleanupSettled(arrival)) {
      _end(session, TransferOutcome.cancelledByPeer, register: false);
      return _unavailable;
    }
    if (_gone(session)) return _cancelled;
    final loaded = await _race(_rememberedFolder(), checkUntil);
    if (_gone(session)) return _cancelled;
    final remembered = loaded.value;
    ReceiveTarget? target;
    if (remembered != null) {
      final inspection = await _inspectBounded(
        remembered.path,
        expectedVolume: remembered.volumeId,
        until: checkUntil,
        afterUsable: (usable) => _sweepFolder(usable.path),
      );
      if (inspection is FolderUsable) target = inspection.target;
      if (_gone(session)) return _cancelled;
    }
    var proposal = remembered?.path;
    var proposalLost = false;
    if (proposal == null) {
      final proposed = await _race(_firstTimeProposal(), checkUntil);
      proposalLost = proposed.expired;
      proposal = proposed.value ?? '';
    }
    session.isProgram = await type;
    if (_gone(session)) return _cancelled;
    if (target != null) {
      final refusal = _limitReply(session, target);
      if (refusal != null) return refusal;
    }
    session
      ..remembered = remembered
      ..rememberedLost = loaded.expired
      ..proposalLost = proposalLost
      ..target = target
      ..proposedPath = proposal;
    return _offerReply(session, _advance(session, defer: true));
  }

  Future<bool> _cleanupSettled(Duration arrival) async {
    final done = _cleanupDone;
    if (done == null || done.isCompleted) return true;
    final deadline = _Deadline(
      at: arrival + Limits.transferCleanupWait,
      abort: AbortSignal(),
    );
    _deadlines.add(deadline);
    try {
      await Future.any<Object?>([done.future, deadline.expired.future]);
    } finally {
      _deadlines.remove(deadline);
    }
    return done.isCompleted;
  }

  ApiReply _offerReply(_InSession session, RemoteState state) {
    final json = state.toJson();
    void lost() => _undelivered(session);
    void delivered() => _exposeAfterDelivery(session);
    return switch (state.status) {
      RemoteStatus.accepted => ApiReply(
        200,
        json,
        afterResponse: delivered,
        onUndelivered: lost,
      ),
      RemoteStatus.waiting => ApiReply(
        202,
        json,
        afterResponse: delivered,
        onUndelivered: lost,
      ),
      _ => _unauthorized,
    };
  }

  void _undelivered(_InSession session) {
    if (session.exposed) {
      _withdrawIfPending(session);
      return;
    }
    session.undelivered = true;
    _end(session, TransferOutcome.cancelledByPeer, register: false);
  }

  void _exposeAfterDelivery(_InSession session) {
    if (session.undelivered ||
        session.exposed ||
        session.phase == _InPhase.ended) {
      return;
    }
    _expose(session);
  }

  void _expose(_InSession session) {
    final stale = _panel;
    if (stale != null && !identical(stale, session)) _dropPanel(stale);
    final now = _clock();
    session
      ..exposed = true
      ..shown = true;
    switch (session.phase) {
      case _InPhase.warning || _InPhase.folderQuestion:
        session
          ..shownAt = now
          ..frozen = Duration.zero
          ..lastPollAt = now;
      case _InPhase.accepted:
        session.acceptedAt = now;
      case _InPhase.checking ||
          _InPhase.uploading ||
          _InPhase.finishing ||
          _InPhase.ended:
        break;
    }
    _signal(session);
    _onChanged();
  }

  RemoteState _advance(_InSession session, {bool defer = false}) {
    final device = _paired.deviceOf(session.fingerprint);
    if (device == null) {
      _end(session, TransferOutcome.unpaired);
      return _stateOf(session);
    }
    final step = nextReceiveStep(
      warned: session.warned,
      folderReady: session.target != null,
      relation: device.relation,
    );
    switch (step) {
      case ReceiveStep.warn:
        final target = session.target;
        session
          ..ask = null
          ..phase = _InPhase.warning
          ..withoutMark = target != null && !target.supportsMark;
      case ReceiveStep.askFolder:
        final known = session.remembered != null || session.rememberedLost;
        session
          ..ask = _FolderAsk(
            kind: known
                ? FolderQuestionKind.thisTime
                : FolderQuestionKind.firstTime,
            proposedPath: session.proposedPath,
            problem: session.proposalLost
                ? FolderProblem.cannotUse
                : known
                ? FolderProblem.rememberedUnavailable
                : null,
          )
          ..phase = _InPhase.folderQuestion;
      case ReceiveStep.accept:
        session
          ..ask = null
          ..permit = _randomHex32()
          ..phase = _InPhase.accepted;
    }
    if (defer) {
      session.decidedAt = _clock();
    } else {
      _expose(session);
    }
    return _stateOf(session);
  }

  Future<ApiReply> _handleUpload(ApiUpload upload) async {
    _InSession? session;
    try {
      session = _claimUpload(upload);
      if (session == null) return _uploadForbidden;
      return await _runUpload(session, upload);
    } catch (e) {
      _log('transfer upload failed: ${e.runtimeType}');
      if (session == null) return _internal;
      return _stopUpload(session, TransferOutcome.writeFailed);
    }
  }

  _InSession? _claimUpload(ApiUpload upload) {
    final session = _active;
    final permitOk = _permitMatches(
      upload.headers[TransferHeaders.permit],
      session?.permit,
    );
    if (_closed || session == null) return null;
    final idOk = upload.headers[TransferHeaders.transfer] == session.id;
    final fingerprintOk = upload.clientFingerprint == session.fingerprint;
    final viaOk = upload.via.id == session.via;
    final phaseOk = session.phase == _InPhase.accepted && !session.permitUsed;
    if (!(permitOk & idOk & fingerprintOk & viaOk & phaseOk)) return null;
    session
      ..permitUsed = true
      ..permit = null
      ..phase = _InPhase.uploading
      ..lastDataAt = _clock()
      ..upload = upload;
    if (session.exposed) {
      _signal(session);
      _onChanged();
    } else {
      _expose(session);
    }
    return session;
  }

  ApiReply _uploadReply(_InSession session) =>
      ApiReply(200, _stateOf(session).toJson());

  ApiReply _stopUpload(_InSession session, TransferOutcome outcome) {
    _end(session, outcome, cut: false);
    return _uploadReply(session);
  }

  Future<ApiReply> _runUpload(_InSession session, ApiUpload upload) async {
    if (upload.contentLength > session.size) {
      return _stopUpload(session, TransferOutcome.tooManyBytes);
    }
    if (upload.contentLength < session.size || !upload.keepAlive()) {
      return _stopUpload(session, TransferOutcome.connectionLost);
    }
    final target = session.target;
    if (target == null) {
      return _stopUpload(session, TransferOutcome.writeFailed);
    }
    final writer = await _openWriter(session, target);
    if (writer == null) return _uploadReply(session);
    session
      ..writer = writer
      ..tempPath = writer.tempPath;
    if (session.size > 0) {
      final ended = session.bodyEnded = Completer<void>();
      upload.body.listen(
        onData: (chunk) =>
            unawaited(_receiveChunk(session, writer, upload, chunk)),
        onDone: () {
          if (!ended.isCompleted) ended.complete();
        },
        onError: (Object e) {
          _log('upload body failed: ${e.runtimeType}');
          session.bodyFailed = true;
          if (!ended.isCompleted) ended.complete();
        },
      );
      await ended.future;
    }
    if (session.phase != _InPhase.uploading) return _uploadReply(session);
    if (session.bodyFailed || session.received < session.size) {
      return _stopUpload(session, TransferOutcome.connectionLost);
    }
    return _finishUpload(session, writer, target);
  }

  Future<IncomingFileWriter?> _openWriter(
    _InSession session,
    ReceiveTarget target,
  ) async {
    final guard = Completer<void>();
    _track(() => guard.future);
    try {
      try {
        await _journal.add(
          ReceiveFolder(path: target.path, volumeId: target.volumeId),
        );
      } catch (e) {
        _log('temp journal add failed: ${e.runtimeType}');
        _end(session, TransferOutcome.writeFailed, cut: false);
        return null;
      }
      if (session.phase != _InPhase.uploading) {
        await _forgetJournal(target);
        return null;
      }
      final IncomingFileWriter writer;
      try {
        writer = await IncomingFileWriter.open(
          target: target,
          size: session.size,
          fs: _fs,
          writeBytes: _writeBytes,
        );
      } catch (e) {
        _log('incoming file open failed: ${e.runtimeType}');
        await _forgetJournal(target);
        _end(session, TransferOutcome.writeFailed, cut: false);
        return null;
      }
      if (session.phase != _InPhase.uploading) {
        await writer.discard();
        await _forgetJournal(target);
        return null;
      }
      return writer;
    } finally {
      guard.complete();
    }
  }

  Future<void> _receiveChunk(
    _InSession session,
    IncomingFileWriter writer,
    ApiUpload upload,
    Uint8List chunk,
  ) async {
    upload.body.pause();
    session.writing = true;
    try {
      if (session.phase != _InPhase.uploading) return;
      await writer.add(chunk);
      if (session.phase != _InPhase.uploading) return;
      final now = _clock();
      session
        ..received += chunk.length
        ..lastDataAt = now;
      final reportedAt = session.progressAt;
      if (reportedAt == null ||
          now - reportedAt >= Limits.transferProgressInterval) {
        session.progressAt = now;
        _onChanged();
      }
    } on TooManyBytesException {
      _end(session, TransferOutcome.tooManyBytes);
    } on DiskFullException {
      _end(session, TransferOutcome.diskFull);
    } catch (e) {
      _log('incoming file write failed: ${e.runtimeType}');
      _end(session, TransferOutcome.writeFailed);
    } finally {
      session.writing = false;
      upload.body.resume();
    }
  }

  Future<ApiReply> _finishUpload(
    _InSession session,
    IncomingFileWriter writer,
    ReceiveTarget target,
  ) async {
    session.phase = _InPhase.finishing;
    _signal(session);
    _onChanged();
    WriteResult result;
    try {
      result = await writer.finish(
        name: session.name,
        expectedSha256: session.sha256,
      );
    } catch (e) {
      _log('incoming file finish failed: ${e.runtimeType}');
      result = const WriteFailed(TransferOutcome.writeFailed);
    }
    await _forgetJournal(target);
    switch (result) {
      case WriteSaved(:final finalName, :final finalPath, :final marked):
        _end(
          session,
          marked ? TransferOutcome.saved : TransferOutcome.savedWithoutMark,
          cut: false,
          finalName: finalName,
          finalPath: finalPath,
        );
      case WriteFailed(:final outcome):
        _end(session, outcome, cut: false);
    }
    return _uploadReply(session);
  }

  void _releaseUpload(
    _InSession session,
    _InPhase previous, {
    required bool cut,
  }) {
    final upload = session.upload;
    final writer = session.writer;
    session
      ..upload = null
      ..writer = null;
    final ended = session.bodyEnded;
    if (ended != null && !ended.isCompleted) ended.complete();
    if (previous != _InPhase.uploading) return;
    if (cut && upload != null) {
      try {
        upload.cut();
      } catch (e) {
        _log('upload cut failed: ${e.runtimeType}');
      }
    }
    final target = session.target;
    if (writer != null && target != null) {
      _track(() async {
        await writer.discard();
        await _forgetJournal(target);
      });
    }
  }

  Future<void> _forgetJournal(ReceiveTarget target) async {
    try {
      final sub = _joinPath(target.path, tempFolderName);
      final kind = await FileSystemEntity.type(sub, followLinks: false);
      if (kind == FileSystemEntityType.notFound) {
        await _journal.remove(target.path);
      }
    } catch (e) {
      _log('temp journal update failed: ${e.runtimeType}');
    }
  }

  Future<ApiReply> _handleWait(ApiCall call) async {
    if (_closed) return _notFound;
    try {
      return await _wait(call);
    } catch (e) {
      _log('transfer wait failed: ${e.runtimeType}');
      return _internal;
    }
  }

  Future<ApiReply> _wait(ApiCall call) async {
    final request = WaitRequest.tryParse(call.json);
    if (request == null) return _incompatible;
    final fingerprint = call.clientFingerprint;
    if (fingerprint == null) return _unauthorized;
    final session = _activeFor(fingerprint, request.transfer);
    if (session == null) {
      final record = _recordOf(fingerprint, request.transfer);
      return record == null ? _notFound : ApiReply(200, record.state.toJson());
    }
    session.lastPollAt = _clock();
    if (_holdsWait(session)) {
      session.held++;
      _held++;
      try {
        await _hold(session);
      } finally {
        session.held--;
        _held--;
        if (_held == 0) {
          final drained = _drained;
          if (drained != null && !drained.isCompleted) drained.complete();
        }
      }
    }
    return ApiReply(
      200,
      _stateOf(session).toJson(),
      onUndelivered: () => _withdrawIfPending(session),
    );
  }

  Future<ApiReply> _handleCancel(ApiCall call) async {
    if (_closed) return _notFound;
    try {
      return await _cancel(call);
    } catch (e) {
      _log('transfer cancel failed: ${e.runtimeType}');
      return _internal;
    }
  }

  Future<ApiReply> _cancel(ApiCall call) async {
    final request = CancelRequest.tryParse(call.json);
    if (request == null) return _incompatible;
    final fingerprint = call.clientFingerprint;
    if (fingerprint == null) return _unauthorized;
    final session = _activeFor(fingerprint, request.transfer);
    if (session == null) {
      final record = _recordOf(fingerprint, request.transfer);
      if (record != null) return ApiReply(200, record.state.toJson());
      const state = RemoteState.cancelled();
      _addRecord(
        _Record(
          fingerprint: fingerprint,
          id: request.transfer,
          state: state,
          tombstone: true,
          at: _clock(),
        ),
      );
      return ApiReply(200, state.toJson());
    }
    switch (session.phase) {
      case _InPhase.checking || _InPhase.warning || _InPhase.folderQuestion:
        _withdrawByPeer(session);
      case _InPhase.accepted:
        if (request.reason == CancelReason.noContact) {
          _withdrawByPeer(session);
        } else {
          _end(
            session,
            request.reason == CancelReason.unreadable
                ? TransferOutcome.unreadable
                : TransferOutcome.cancelledByPeer,
          );
        }
      case _InPhase.uploading:
        _end(
          session,
          request.reason == CancelReason.unreadable
              ? TransferOutcome.unreadable
              : TransferOutcome.cancelledByPeer,
        );
      case _InPhase.finishing:
        await session.finished.future;
      case _InPhase.ended:
        break;
    }
    return ApiReply(200, _stateOf(session).toJson());
  }

  void _withdrawIfPending(_InSession session) {
    switch (session.phase) {
      case _InPhase.checking || _InPhase.warning || _InPhase.folderQuestion:
        _withdrawByPeer(session);
      case _InPhase.accepted ||
          _InPhase.uploading ||
          _InPhase.finishing ||
          _InPhase.ended:
        break;
    }
  }

  void _withdrawByPeer(_InSession session) {
    switch (session.phase) {
      case _InPhase.checking:
        _end(session, TransferOutcome.cancelledByPeer, register: false);
      case _InPhase.warning || _InPhase.folderQuestion || _InPhase.accepted:
        final wasExposed = session.exposed;
        final wasWarning = session.phase == _InPhase.warning;
        _end(session, TransferOutcome.cancelledByPeer, register: false);
        if (wasExposed && wasWarning) {
          _noteForeignRejection(session.fingerprint);
        }
        if (wasExposed) {
          _emit(
            PeerCancelledTransfer(
              peerFingerprint: session.fingerprint,
              peerName: session.peerName,
            ),
          );
        }
      case _InPhase.uploading || _InPhase.finishing || _InPhase.ended:
        break;
    }
  }

  void _tickSession(_InSession session, Duration now) {
    if (!session.exposed) {
      final since = session.decidedAt ?? session.arrivedAt;
      if (now - since >= Limits.transferMessageTimeout) {
        _end(session, TransferOutcome.cancelledByPeer, register: false);
      }
      return;
    }
    switch (session.phase) {
      case _InPhase.warning || _InPhase.folderQuestion:
        final shownAt = session.shownAt;
        if (!_pickers.isOpen &&
            shownAt != null &&
            now - shownAt - session.frozen >= Limits.transferPromptTimeout) {
          _end(session, TransferOutcome.unanswered);
          return;
        }
        final lastPollAt = session.lastPollAt;
        if (session.held == 0 &&
            lastPollAt != null &&
            now - lastPollAt >= Limits.transferPollGap) {
          _withdrawByPeer(session);
        }
      case _InPhase.accepted:
        final acceptedAt = session.acceptedAt;
        if (acceptedAt != null &&
            now - acceptedAt >= Limits.transferUploadStartTimeout) {
          _end(session, TransferOutcome.uploadNotStarted);
        }
      case _InPhase.uploading:
        final lastDataAt = session.lastDataAt;
        if (!session.writing &&
            lastDataAt != null &&
            now - lastDataAt >= _idleTimeout) {
          _end(session, TransferOutcome.idle);
        }
      case _InPhase.checking || _InPhase.finishing || _InPhase.ended:
        break;
    }
  }

  void _end(
    _InSession session,
    TransferOutcome outcome, {
    bool register = true,
    bool cut = true,
    String? finalName,
    String? finalPath,
  }) {
    if (session.phase == _InPhase.ended) return;
    final previous = session.phase;
    session
      ..phase = _InPhase.ended
      ..outcome = outcome
      ..permit = null
      ..tempPath = null;
    if (identical(_active, session)) _active = null;
    _releaseUpload(session, previous, cut: cut);
    final ask = session.ask;
    if (ask != null) {
      final created = ask.takeCreatedPending();
      if (created != null) _track(() => _removeIfEmpty(created));
      if (ask.pickerOpen) _panel = session;
    }
    if (register && session.shown) {
      _lastReceived = TransferResultView(
        direction: TransferDirection.incoming,
        peerFingerprint: session.fingerprint,
        peerName: session.peerName,
        fileName: visibleFileName(finalName ?? session.name),
        isProgram: session.isProgram,
        outcome: outcome,
        canReveal: finalPath != null,
      );
      _lastReceivedPath = finalPath;
    }
    _addRecord(
      _Record(
        fingerprint: session.fingerprint,
        id: session.id,
        state: remoteOf(outcome) ?? const RemoteState.cancelled(),
        tombstone: false,
        at: _clock(),
      ),
    );
    _signal(session);
    if (!session.finished.isCompleted) session.finished.complete();
    _onChanged();
  }

  RemoteState _stateOf(_InSession session) {
    switch (session.phase) {
      case _InPhase.checking || _InPhase.warning || _InPhase.folderQuestion:
        return RemoteState.waiting(picker: _pickers.isOpen);
      case _InPhase.accepted:
        final permit = session.permit;
        return permit == null
            ? const RemoteState.cancelled()
            : RemoteState.accepted(permit: permit);
      case _InPhase.uploading:
        return const RemoteState.uploading();
      case _InPhase.finishing:
        return const RemoteState.saving();
      case _InPhase.ended:
        final outcome = session.outcome;
        return (outcome == null ? null : remoteOf(outcome)) ??
            const RemoteState.cancelled();
    }
  }

  bool _holdsWait(_InSession session) => switch (session.phase) {
    _InPhase.checking ||
    _InPhase.warning ||
    _InPhase.folderQuestion ||
    _InPhase.uploading ||
    _InPhase.finishing => true,
    _InPhase.accepted || _InPhase.ended => false,
  };

  _InSession? _activeFor(String fingerprint, String id) {
    final session = _active;
    if (session != null &&
        session.fingerprint == fingerprint &&
        session.id == id) {
      return session;
    }
    return null;
  }

  _Record? _recordOf(String fingerprint, String id) {
    _pruneRecords(_clock());
    return _records[(fingerprint, id)];
  }

  void _addRecord(_Record record) {
    _pruneRecords(record.at);
    final key = (record.fingerprint, record.id);
    _records
      ..remove(key)
      ..[key] = record;
    final own = [
      for (final entry in _records.entries)
        if (entry.value.fingerprint == record.fingerprint) entry.key,
    ];
    if (own.length > Limits.transferMaxRecordsPerPeer) {
      for (final stale in own.take(
        own.length - Limits.transferMaxRecordsPerPeer,
      )) {
        _records.remove(stale);
      }
    }
    while (_records.length > Limits.transferMaxRecordsTotal) {
      _records.remove(_records.keys.first);
    }
  }

  void _pruneRecords(Duration now) {
    _records.removeWhere(
      (_, record) => now - record.at >= Limits.transferRecordTtl,
    );
  }

  void _signal(_InSession session) {
    final previous = session.changed;
    session.changed = Completer<void>();
    previous.complete();
  }

  Future<void> _hold(_InSession session) {
    if (_closed) return Future<void>.value();
    final released = Completer<void>();
    late final Timer timer;
    void release() {
      timer.cancel();
      if (!released.isCompleted) released.complete();
    }

    timer = Timer(_pollHold, release);
    unawaited(session.changed.future.then((_) => release()));
    return released.future;
  }

  Future<ReceiveFolder?> _rememberedFolder() =>
      _rememberedLoad ??= _loadRemembered();

  Future<ReceiveFolder?> _loadRemembered() async {
    try {
      return await _folders.load();
    } catch (e) {
      _log('receive folder load failed: ${e.runtimeType}');
      return null;
    }
  }

  Future<SystemFolders> _readSystemFolders() {
    final cached = _systemFolders;
    if (cached != null) return Future<SystemFolders>.value(cached);
    return _systemFoldersInFlight ??= _fetchSystemFolders().whenComplete(
      () => _systemFoldersInFlight = null,
    );
  }

  Future<SystemFolders> _fetchSystemFolders() async {
    final read = await _fs.systemFolders();
    _systemFolders = read;
    return read;
  }

  Future<ForbiddenFolders?> _forbiddenFolders() {
    final ready = _forbidden;
    if (ready != null) return Future<ForbiddenFolders?>.value(ready);
    return _forbiddenInFlight ??= _computeForbidden().whenComplete(
      () => _forbiddenInFlight = null,
    );
  }

  Future<ForbiddenFolders?> _computeForbidden() async {
    try {
      final folders = await _readSystemFolders();
      final result = await loadForbiddenFolders(
        _fs,
        folders,
        dataDirs: [_dataDirPath],
      );
      _forbidden = result;
      if (result == null) _systemFolders = null;
      return result;
    } catch (e) {
      _log('forbidden folders failed: ${e.runtimeType}');
      _systemFolders = null;
      return null;
    }
  }

  Future<String> _firstTimeProposal() async {
    try {
      final downloads = (await _readSystemFolders()).downloads;
      if (downloads != null && downloads.isNotEmpty) {
        return '$downloads\\NexusBridges';
      }
    } catch (e) {
      _log('downloads folder failed: ${e.runtimeType}');
    }
    final profile = Platform.environment['USERPROFILE'];
    return profile == null || profile.isEmpty
        ? ''
        : '$profile\\Downloads\\NexusBridges';
  }
}
