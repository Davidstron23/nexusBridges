import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'dart:math';

import '../identity/identity.dart' show DeviceIdentity;
import '../pairing/pairing.dart' show PairedDevicesStore;
import '../protocol/protocol.dart' show ApiPaths, Limits, sanitizeDisplayName;
import '../transport/transport.dart'
    show
        AbortSignal,
        HttpsResponse,
        StreamPostAnswered,
        StreamPostFailed,
        StreamPostFailure;
import 'folder_plan.dart';
import 'folder_send.dart';
import 'folder_stream.dart';
import 'folders.dart' show isInsideTempFolder, isSameOrInside;
import 'link.dart';
import 'loose_file.dart';
import 'manifest.dart' show encodeManifestChunks;
import 'messages.dart';
import 'names.dart'
    show
        baseName,
        isBlockedType,
        isDriveRoot,
        isProgram,
        isSenderAdministrativeShare,
        isShortcutName,
        isValidFileName,
        visibleFileName;
import 'platform.dart';
import 'transfer.dart';
import 'windows_folder_io.dart'
    show
        DataCheck,
        FileHashCancelled,
        FileHashResult,
        FileHashed,
        FileHashFailed,
        FileHashSkipped,
        checkAgainstData;

const int _maxSourcePathChars = 259;

const Duration _pollMargin = Duration(seconds: 3);

const Duration _retryDelay = Duration(seconds: 1);

Future<DataCheck> _checkData(String path, String dataPath) =>
    Isolate.run(() => checkAgainstData(path, dataPath));

String _randomHex32() {
  final random = Random.secure();
  final buffer = StringBuffer();
  for (var i = 0; i < 16; i++) {
    buffer.write(random.nextInt(256).toRadixString(16).padLeft(2, '0'));
  }
  return buffer.toString();
}

final class _OutSession {
  _OutSession({
    required this.target,
    required this.link,
    required this.path,
    required this.name,
    required this.peerName,
    required this.isProgram,
    required this.typeCheck,
    this.isFolder = false,
    this.realPath,
  });

  final bool isFolder;

  final String? realPath;

  String? sourcePath;

  int sourceVolume = 0;

  int sourceIndex = 0;

  final Completer<TransferResultView?> completion =
      Completer<TransferResultView?>();

  final Set<Future<Object?>> cancels = {};

  FolderPlanJob? planJob;

  FolderPlan? plan;

  FrameLayout? layout;

  FolderSummaryView? summary;

  int sentFiles = 0;

  int preparedEntries = 0;

  int preparedFiles = 0;

  String? problemPath;

  String? finalName;

  final SendTarget target;

  final TransferLink link;

  final String path;

  final String name;

  final String? peerName;

  final Future<bool> typeCheck;

  final AbortSignal abort = AbortSignal();

  bool isProgram;

  OutgoingPhase phase = OutgoingPhase.preparing;

  int size = 0;

  int sentBytes = 0;

  bool cancelling = false;

  bool stopping = false;

  bool consulting = false;

  bool done = false;

  String? id;

  String? permit;

  Duration? waitingSince;

  Duration? lastAnswerAt;

  Duration counted = Duration.zero;

  bool lastPicker = false;

  Duration? lastByteAt;

  Duration? lastRenewAt;

  Duration? lastProgressAt;
}

final class TransferSender {
  TransferSender({
    required this._identity,
    required this._paired,
    required this._picker,
    required this._fs,
    required this._clock,
    required this._pollHold,
    required this._idleTimeout,
    required this._confirmTimeout,
    required this._onChanged,
    required this._log,
    this._onFilePicker,
    this._dataDirPath = '',
    this._exclusions = const NoExclusionSource(),
    this._beforeStreamEntry,
  });

  final String _dataDirPath;

  final ExclusionSource _exclusions;

  final Future<void> Function(int entry)? _beforeStreamEntry;

  final DeviceIdentity _identity;

  final PairedDevicesStore _paired;

  final FilePicker _picker;

  final FileSystemPlatform _fs;

  final Duration Function() _clock;

  final Duration _pollHold;

  final Duration _idleTimeout;

  final Duration _confirmTimeout;

  final void Function() _onChanged;

  final void Function(String) _log;

  final void Function(bool open)? _onFilePicker;

  final Set<Future<Object?>> _cancels = {};

  _OutSession? _active;

  TransferResultView? _lastSent;

  bool _filePickerOpen = false;

  bool _closed = false;

  bool _starting = false;

  bool _cancelWhileStarting = false;

  bool get sending => _active != null || _filePickerOpen || _starting;

  TransferResultView? get lastSent => _lastSent;

  OutgoingTransferView? get outgoing {
    final session = _active;
    if (session == null) return null;
    return OutgoingTransferView(
      peerFingerprint: session.target.fingerprint,
      peerName: session.peerName,
      fileName: visibleFileName(session.name),
      size: session.size,
      isProgram: session.isProgram,
      phase: session.phase,
      sentBytes: session.sentBytes,
      cancelling: session.cancelling,
      isFolder: session.isFolder,
      fileCount: session.plan?.manifest.files ?? 0,
      sentFiles: session.sentFiles,
      preparedEntries: session.preparedEntries,
      preparedFiles: session.preparedFiles,
      summary: session.summary,
    );
  }

  Future<TransferResultView?> sendElement(
    SendTarget target,
    String path, {
    required SendTarget? Function() refresh,
    SendDestination destination = const ReceiveFolderDestination(),
  }) async {
    if (_closed || _active != null || _starting) return null;
    _starting = true;
    _cancelWhileStarting = false;
    _OutSession? session;
    try {
      session = await _beginElement(target, path, refresh);
    } catch (e) {
      _log('send element failed: ${e.runtimeType}');
      _record(
        target.fingerprint,
        null,
        baseName(path),
        TransferOutcome.noContact,
      );
    } finally {
      _starting = false;
      _cancelWhileStarting = false;
    }
    if (session == null) return _closed ? null : _lastSent;
    return session.completion.future;
  }

  Future<SendStart> sendFile(
    SendTarget target, {
    required SendTarget? Function() refresh,
  }) async {
    if (_closed) return SendStart.nothingChosen;
    if (sending) return SendStart.alreadySending;
    _filePickerOpen = true;
    _onFilePicker?.call(true);
    _onChanged();
    String? path;
    try {
      path = await _picker.pickFile();
    } catch (e) {
      _log('file picker failed: ${e.runtimeType}');
    } finally {
      _filePickerOpen = false;
      _onFilePicker?.call(false);
    }
    if (path == null || path.isEmpty || _closed) {
      _onChanged();
      return SendStart.nothingChosen;
    }
    _begin(target, path, refresh);
    return SendStart.started;
  }

  void cancelOutgoing() {
    final session = _active;
    if (session == null) {
      if (_starting) _cancelWhileStarting = true;
      return;
    }
    if (session.done || session.stopping) return;
    switch (session.phase) {
      case OutgoingPhase.preparing:
        _finish(session, TransferOutcome.cancelledHere);
      case OutgoingPhase.requesting || OutgoingPhase.waiting:
        unawaited(
          _sendCancel(
            session,
            CancelReason.cancelled,
            Limits.transferCancelTimeout,
          ),
        );
        _finish(session, TransferOutcome.cancelledHere);
      case OutgoingPhase.uploading || OutgoingPhase.verifying:
        unawaited(_cancelUpload(session));
    }
  }

  int sessionsVia(Set<String> interfaceIds) {
    final session = _active;
    if (session == null ||
        session.done ||
        !interfaceIds.contains(session.target.interfaceId)) {
      return 0;
    }
    return 1;
  }

  void interfacesChanged(Set<String> activeInterfaceIds) {
    final session = _active;
    if (session == null ||
        session.done ||
        activeInterfaceIds.contains(session.target.interfaceId)) {
      return;
    }
    unawaited(
      _sendCancel(
        session,
        CancelReason.cancelled,
        Limits.transferCloseCancelTimeout,
      ),
    );
    _finish(session, TransferOutcome.interfaceDown);
  }

  void pairedChanged() {
    final session = _active;
    if (session == null ||
        session.done ||
        _paired.deviceOf(session.target.fingerprint) != null) {
      return;
    }
    unawaited(
      _sendCancel(
        session,
        CancelReason.cancelled,
        Limits.transferCloseCancelTimeout,
      ),
    );
    _finish(session, TransferOutcome.unpaired);
  }

  Future<void> peerUnpaired(String fingerprint) async {
    final session = _active;
    if (session == null ||
        session.done ||
        session.target.fingerprint != fingerprint) {
      return;
    }
    switch (session.phase) {
      case OutgoingPhase.preparing:
        _finish(session, TransferOutcome.unpaired);
      case OutgoingPhase.requesting ||
          OutgoingPhase.waiting ||
          OutgoingPhase.uploading ||
          OutgoingPhase.verifying:
        final pending = _sendCancel(
          session,
          CancelReason.cancelled,
          Limits.transferCancelTimeout,
        );
        _finish(session, TransferOutcome.unpaired);
        await pending;
    }
  }

  void tick() {
    try {
      _tickSession();
    } catch (e) {
      _log('send tick failed: ${e.runtimeType}');
    }
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    final session = _active;
    if (session != null && !session.done) {
      switch (session.phase) {
        case OutgoingPhase.uploading || OutgoingPhase.verifying:
          session.stopping = true;
          await _sendCancel(
            session,
            CancelReason.cancelled,
            Limits.transferCloseCancelTimeout,
          );
        default:
          unawaited(
            _sendCancel(
              session,
              CancelReason.cancelled,
              Limits.transferCloseCancelTimeout,
            ),
          );
      }
      _finish(session, TransferOutcome.cancelledHere);
    }
    if (_cancels.isEmpty) return;
    await Future.wait(
      _cancels.toList(),
    ).timeout(Limits.transferCancelTimeout, onTimeout: () => const <Object?>[]);
  }

  void _begin(SendTarget target, String path, SendTarget? Function() refresh) {
    final name = baseName(path);
    final device = _paired.deviceOf(target.fingerprint);
    final peerName = device == null ? null : sanitizeDisplayName(device.name);
    SendTarget? current;
    try {
      current = refresh();
    } catch (e) {
      _log('send target refresh failed: ${e.runtimeType}');
    }
    if (device == null) {
      _record(target.fingerprint, peerName, name, TransferOutcome.unpaired);
      return;
    }
    if (current == null || current.fingerprint != target.fingerprint) {
      _record(target.fingerprint, peerName, name, TransferOutcome.noContact);
      return;
    }
    if (!isValidFileName(name)) {
      _record(target.fingerprint, peerName, name, TransferOutcome.invalidName);
      return;
    }
    if (isBlockedType(name)) {
      _record(target.fingerprint, peerName, name, TransferOutcome.blockedType);
      return;
    }
    final session = _OutSession(
      target: current,
      link: TransferLink(identity: _identity, target: current),
      path: path,
      name: name,
      peerName: peerName,
      isProgram: isProgram(name),
      typeCheck: isProgramHere(name, _fs),
    );
    _active = session;
    _onChanged();
    unawaited(_run(session, path));
  }

  Future<_OutSession?> _beginElement(
    SendTarget target,
    String path,
    SendTarget? Function() refresh,
  ) async {
    final name = baseName(path);
    final device = _paired.deviceOf(target.fingerprint);
    final peerName = device == null ? null : sanitizeDisplayName(device.name);
    SendTarget? currentTarget() {
      try {
        return refresh();
      } catch (e) {
        _log('send target refresh failed: ${e.runtimeType}');
        return null;
      }
    }

    final current = currentTarget();
    void record(TransferOutcome outcome, {String? problemPath}) {
      _record(
        target.fingerprint,
        peerName,
        name,
        outcome,
        problemPath: problemPath,
      );
    }

    if (device == null) {
      record(TransferOutcome.unpaired);
      return null;
    }
    if (current == null || current.fingerprint != target.fingerprint) {
      record(TransferOutcome.noContact);
      return null;
    }
    if (isDriveRoot(path)) {
      record(TransferOutcome.wholeDrive);
      return null;
    }
    if (isShortcutName(name)) {
      record(TransferOutcome.shortcut);
      return null;
    }
    if (path.length > _maxSourcePathChars) {
      record(TransferOutcome.pathTooLong);
      return null;
    }
    final FileSystemEntityType kind;
    try {
      kind = await FileSystemEntity.type(path, followLinks: true);
    } catch (_) {
      record(TransferOutcome.unreadable);
      return null;
    }
    if (kind == FileSystemEntityType.notFound) {
      record(TransferOutcome.notFound);
      return null;
    }
    if (kind != FileSystemEntityType.file &&
        kind != FileSystemEntityType.directory) {
      record(TransferOutcome.unreadable);
      return null;
    }
    final real = await _fs.realPath(path);
    if (real == null) {
      record(TransferOutcome.unreadable);
      return null;
    }
    if (isDriveRoot(real)) {
      record(TransferOutcome.wholeDrive);
      return null;
    }
    final dataReal = _dataDirPath.isEmpty
        ? null
        : await _fs.realPath(_dataDirPath) ?? _dataDirPath;
    if (isInsideTempFolder(real) ||
        (dataReal != null && isSameOrInside(real, dataReal))) {
      record(TransferOutcome.protectedData);
      return null;
    }
    if (isSenderAdministrativeShare(path) ||
        isSenderAdministrativeShare(real)) {
      record(TransferOutcome.protectedData);
      return null;
    }
    final isFolder = kind == FileSystemEntityType.directory;
    if (dataReal != null) {
      switch (await _checkData(real, dataReal)) {
        case DataCheck.clear:
          break;
        case DataCheck.inData:
          record(TransferOutcome.protectedData);
          return null;
        case DataCheck.unreadable:
          record(TransferOutcome.unreadable);
          return null;
      }
    }
    if (_closed) return null;
    if (_cancelWhileStarting) {
      record(TransferOutcome.cancelledHere);
      return null;
    }
    if (_paired.deviceOf(target.fingerprint) == null) {
      record(TransferOutcome.unpaired);
      return null;
    }
    final latest = currentTarget();
    if (latest == null || latest.fingerprint != target.fingerprint) {
      record(TransferOutcome.noContact);
      return null;
    }
    if (!isValidFileName(name)) {
      record(TransferOutcome.invalidName, problemPath: isFolder ? name : null);
      return null;
    }
    if (isBlockedType(name)) {
      record(TransferOutcome.blockedType, problemPath: isFolder ? name : null);
      return null;
    }
    final session = _OutSession(
      target: latest,
      link: TransferLink(identity: _identity, target: latest),
      path: path,
      name: name,
      peerName: peerName,
      isProgram: isFolder ? false : isProgram(name),
      typeCheck: isFolder
          ? Future<bool>.value(false)
          : isProgramHere(name, _fs),
      isFolder: isFolder,
      realPath: real,
    );
    _active = session;
    _onChanged();
    unawaited(_run(session, path));
    return session;
  }

  void _record(
    String fingerprint,
    String? peerName,
    String name,
    TransferOutcome outcome, {
    String? problemPath,
  }) {
    _lastSent = TransferResultView(
      direction: TransferDirection.outgoing,
      peerFingerprint: fingerprint,
      peerName: peerName,
      fileName: visibleFileName(name),
      isProgram: isProgram(name),
      outcome: outcome,
      canReveal: false,
      problemPath: problemPath == null ? null : visibleFileName(problemPath),
    );
    _onChanged();
  }

  Future<void> _run(_OutSession session, String path) async {
    try {
      await _prepareAndRequest(session, path);
    } catch (e) {
      _log('send failed: ${e.runtimeType}');
      await _conclude(session, TransferOutcome.noContact);
    }
  }

  Future<List<String>> _loadExclusions() async {
    try {
      final loaded = await _exclusions.load();
      if (loaded != null &&
          loaded.length <= 64 &&
          loaded.every(isValidFileName)) {
        return loaded;
      }
    } catch (e) {
      _log('exclusions load failed: ${e.runtimeType}');
    }
    return defaultExclusions;
  }

  Future<void> _prepareFolder(_OutSession session) async {
    final root = session.realPath;
    if (root == null) {
      await _conclude(session, TransferOutcome.unreadable);
      return;
    }
    final exclusions = await _loadExclusions();
    if (session.done) return;
    final dataReal = _dataDirPath.isEmpty
        ? ''
        : await _fs.realPath(_dataDirPath) ?? _dataDirPath;
    if (session.done) return;
    final job = FolderPlanJob.start(
      rootRealPath: root,
      name: session.name,
      exclusions: exclusions,
      dataDirPath: _dataDirPath,
      dataDirRealPath: dataReal,
      onProgress: (entries, hashed) {
        if (session.done) return;
        session.preparedEntries = entries;
        session.preparedFiles = hashed;
        _onChanged();
      },
    );
    session.planJob = job;
    final result = await job.result;
    if (session.done) return;
    switch (result) {
      case PlanCancelled():
        _finish(session, TransferOutcome.cancelledHere);
      case PlanStopped(:final outcome, :final problemPath):
        session.problemPath = problemPath;
        _finish(session, outcome);
      case PlanReady(:final plan):
        unawaited(_trackExcludedBytes(session, job));
        await _requestFolder(session, plan);
    }
  }

  Future<void> _trackExcludedBytes(
    _OutSession session,
    FolderPlanJob job,
  ) async {
    try {
      final measured = await job.excluded;
      final summary = session.summary;
      if (session.done || summary == null) return;
      session.summary = FolderSummaryView(
        files: summary.files,
        folders: summary.folders,
        totalBytes: summary.totalBytes,
        excludedFolders: summary.excludedFolders,
        excludedBytes: measured.bytes,
        excludedBytesPartial: measured.partial,
        linksOmitted: summary.linksOmitted,
        protectedOmitted: summary.protectedOmitted,
        blockedOmitted: summary.blockedOmitted,
        containsPrograms: summary.containsPrograms,
      );
      _onChanged();
    } catch (e) {
      _log('excluded size failed: ${e.runtimeType}');
    }
  }

  Future<void> _requestFolder(_OutSession session, FolderPlan plan) async {
    final manifest = plan.manifest;
    final id = _randomHex32();
    session
      ..id = id
      ..plan = plan
      ..summary = plan.summary
      ..layout = FrameLayout(manifest)
      ..size = manifest.totalBytes
      ..isProgram = plan.summary.containsPrograms
      ..phase = OutgoingPhase.requesting;
    _onChanged();
    final offer = FolderOfferRequest(
      transfer: id,
      name: session.name,
      entries: manifest.length,
      files: manifest.files,
      bytes: manifest.totalBytes,
      depth: manifest.depth,
      longest: manifest.longest,
      manifestBytes: plan.encodedLength,
    );
    final reply = await session.link.post(
      ApiPaths.transferOffer,
      offer.toJson(),
      abort: session.abort,
    );
    if (session.done) return;
    if (reply == null) {
      unawaited(
        _sendCancel(
          session,
          CancelReason.noContact,
          Limits.transferCloseCancelTimeout,
        ),
      );
      _finish(session, TransferOutcome.noContact);
      return;
    }
    final (status, json) = reply;
    final state = status == 202 ? RemoteState.tryParse(json) : null;
    final permit = state?.permit;
    if (state != null &&
        state.status == RemoteStatus.manifest &&
        permit != null) {
      await _sendManifest(session, permit);
      return;
    }
    _finish(
      session,
      status == 200 || status == 202
          ? TransferOutcome.noContact
          : offerOutcome(status, json),
    );
  }

  Future<void> _sendManifest(_OutSession session, String permit) async {
    final id = session.id;
    final plan = session.plan;
    if (id == null || plan == null) {
      _finish(session, TransferOutcome.noContact);
      return;
    }
    final result = await session.link.uploadManifest(
      transfer: id,
      permit: permit,
      body: Stream<List<int>>.fromIterable(encodeManifestChunks(plan.manifest)),
      contentLength: plan.encodedLength,
      onProgress: (_) {},
      onBodySent: () {},
      idleTimeout: _idleTimeout,
      answerTimeout: Limits.transferMessageTimeout,
      abort: session.abort,
    );
    if (session.done) return;
    switch (result) {
      case StreamPostAnswered(:final response):
        final json = decodeJsonObject(response.body);
        final status = response.status;
        final state = (status == 200 || status == 202) && json != null
            ? RemoteState.tryParse(json)
            : null;
        final accepted = state?.permit;
        if (status == 200 &&
            state != null &&
            state.status == RemoteStatus.accepted &&
            accepted != null) {
          await _accept(session, accepted);
          return;
        }
        if (status == 202 &&
            state != null &&
            state.status == RemoteStatus.waiting) {
          await _awaitDecision(session, id, picker: state.picker ?? false);
          return;
        }
        _finish(
          session,
          status == 200 || status == 202
              ? TransferOutcome.noContact
              : offerOutcome(status, json ?? const <String, Object?>{}),
        );
      case StreamPostFailed():
        unawaited(
          _sendCancel(
            session,
            CancelReason.noContact,
            Limits.transferCloseCancelTimeout,
          ),
        );
        _finish(session, TransferOutcome.noContact);
    }
  }

  Future<void> _entryProblem(_OutSession session, int entry) async {
    final plan = session.plan;
    if (plan == null) return;
    session
      ..problemPath = plan.manifest.relativePath(entry)
      ..stopping = true;
    await _sendCancel(
      session,
      CancelReason.unreadable,
      Limits.transferCancelTimeout,
      entry: entry,
    );
  }

  Future<void> _prepareAndRequest(_OutSession session, String path) async {
    if (session.isFolder) {
      await _prepareFolder(session);
      return;
    }
    unawaited(
      session.typeCheck.then((value) {
        if (session.done || value == session.isProgram) return;
        session.isProgram = value;
        _onChanged();
      }),
    );
    final source = session.realPath ?? await _fs.realPath(path);
    if (session.done) return;
    if (source == null) {
      await _conclude(session, TransferOutcome.unreadable);
      return;
    }
    final dataReal = _dataDirPath.isEmpty
        ? ''
        : await _fs.realPath(_dataDirPath) ?? _dataDirPath;
    if (session.done) return;
    final FileHashResult hashed;
    try {
      hashed = await hashLooseFile(
        path: source,
        dataPath: dataReal,
        abort: session.abort,
      );
    } catch (e) {
      _log('send source unreadable: ${e.runtimeType}');
      await _conclude(session, TransferOutcome.unreadable);
      return;
    }
    if (session.done) return;
    switch (hashed) {
      case FileHashCancelled():
        await _conclude(session, TransferOutcome.cancelledHere);
        return;
      case FileHashSkipped():
        await _conclude(session, TransferOutcome.protectedData);
        return;
      case FileHashFailed():
        _log('send source unreadable: FileSystemException');
        await _conclude(session, TransferOutcome.unreadable);
        return;
      case FileHashed():
        break;
    }
    session
      ..sourcePath = source
      ..sourceVolume = hashed.volume
      ..sourceIndex = hashed.index;
    session.isProgram = await session.typeCheck;
    if (session.done) return;
    final id = _randomHex32();
    session
      ..id = id
      ..size = hashed.size
      ..phase = OutgoingPhase.requesting;
    _onChanged();
    final offer = OfferRequest(
      transfer: id,
      name: session.name,
      size: hashed.size,
      sha256: hexOfDigest(hashed.sha256),
    );
    final reply = await session.link.post(
      ApiPaths.transferOffer,
      offer.toJson(),
      abort: session.abort,
    );
    if (session.done) return;
    if (reply == null) {
      unawaited(
        _sendCancel(
          session,
          CancelReason.noContact,
          Limits.transferCloseCancelTimeout,
        ),
      );
      _finish(session, TransferOutcome.noContact);
      return;
    }
    final (status, json) = reply;
    final state = status == 200 || status == 202
        ? RemoteState.tryParse(json)
        : null;
    if (status == 200 && state != null) {
      final permit = state.permit;
      if (state.status == RemoteStatus.accepted && permit != null) {
        await _accept(session, permit);
        return;
      }
    }
    if (status == 202 &&
        state != null &&
        state.status == RemoteStatus.waiting) {
      await _awaitDecision(session, id, picker: state.picker ?? false);
      return;
    }
    _finish(
      session,
      status == 200 || status == 202
          ? TransferOutcome.noContact
          : offerOutcome(status, json),
    );
  }

  Future<void> _awaitDecision(
    _OutSession session,
    String id, {
    required bool picker,
  }) async {
    final now = _clock();
    session
      ..phase = OutgoingPhase.waiting
      ..waitingSince = now
      ..lastAnswerAt = now
      ..counted = Duration.zero
      ..lastPicker = picker;
    _onChanged();
    final poll = WaitRequest(transfer: id).toJson();
    while (!session.done) {
      final sentAt = _clock();
      final reply = await session.link.post(
        ApiPaths.transferWait,
        poll,
        timeout: _pollHold + _pollMargin,
        abort: session.abort,
      );
      if (session.done) return;
      if (reply == null || reply.$1 == 429) {
        await _pause(session, _retryDelay);
        continue;
      }
      final (status, json) = reply;
      final state = status == 200 ? RemoteState.tryParse(json) : null;
      if (state == null) {
        _finish(session, TransferOutcome.noContact);
        return;
      }
      switch (state.status) {
        case RemoteStatus.waiting:
          final answeredAt = _clock();
          final previous = session.lastAnswerAt;
          if (!session.lastPicker && previous != null) {
            session.counted += answeredAt - previous;
          }
          session
            ..lastAnswerAt = answeredAt
            ..lastPicker = state.picker ?? false;
          await _keepGap(session, sentAt);
        case RemoteStatus.accepted:
          final permit = state.permit;
          if (permit == null) {
            _finish(session, TransferOutcome.noContact);
          } else {
            await _accept(session, permit);
          }
          return;
        default:
          _finish(
            session,
            _resolve(session, state) ?? TransferOutcome.noContact,
          );
          return;
      }
    }
  }

  Future<void> _accept(_OutSession session, String permit) async {
    session
      ..permit = permit
      ..phase = OutgoingPhase.uploading;
    _onChanged();
    await _upload(session);
  }

  Future<void> _upload(_OutSession session) async {
    final id = session.id;
    final permit = session.permit;
    if (id == null || permit == null) {
      _finish(session, TransferOutcome.noContact);
      return;
    }
    final plan = session.plan;
    final layout = session.layout;
    final source = session.sourcePath;
    final folderBody = session.isFolder && plan != null && layout != null;
    if (!folderBody && source == null) {
      _finish(session, TransferOutcome.unreadable);
      return;
    }
    final result = folderBody
        ? await session.link.uploadFolder(
            transfer: id,
            permit: permit,
            body: folderStream(
              plan,
              abort: session.abort,
              onEntryProblem: (entry) => _entryProblem(session, entry),
              beforeEntry: (entry) async {
                await _beforeStreamEntry?.call(entry);
              },
            ),
            contentLength: layout.totalBytes,
            onProgress: (sent) => _progress(session, sent),
            onBodySent: () => _bodySent(session),
            idleTimeout: _idleTimeout,
            answerTimeout: Limits.transferConfirmCap,
            abort: session.abort,
          )
        : await session.link.uploadFolder(
            transfer: id,
            permit: permit,
            body: looseFileStream(
              path: source!,
              volume: session.sourceVolume,
              index: session.sourceIndex,
              size: session.size,
              abort: session.abort,
            ),
            contentLength: session.size,
            onProgress: (sent) => _progress(session, sent),
            onBodySent: () => _bodySent(session),
            idleTimeout: _idleTimeout,
            answerTimeout: Limits.transferConfirmCap,
            abort: session.abort,
          );
    if (session.done) return;
    if (session.problemPath != null) {
      _finish(session, TransferOutcome.unreadable);
      return;
    }
    if (session.stopping) {
      final outcome = result is StreamPostAnswered
          ? _outcomeOfUpload(session, result.response)
          : null;
      if (outcome != null && outcome.kind == TransferResultKind.saved) {
        _finish(session, outcome);
      }
      return;
    }
    switch (result) {
      case StreamPostAnswered(:final response):
        final outcome = _outcomeOfUpload(session, response);
        if (outcome != null) {
          _finish(session, outcome);
          return;
        }
        await _finishAfterConsult(session, TransferOutcome.uploadNotStarted);
      case StreamPostFailed(:final failure):
        switch (failure) {
          case StreamPostFailure.notConnected:
            unawaited(
              _sendCancel(
                session,
                CancelReason.cancelled,
                Limits.transferCloseCancelTimeout,
              ),
            );
            _finish(session, TransferOutcome.uploadNotStarted);
          case StreamPostFailure.sourceError:
            session.stopping = true;
            if (session.problemPath == null) {
              await _sendCancel(
                session,
                CancelReason.unreadable,
                Limits.transferCancelTimeout,
              );
            }
            _finish(session, TransferOutcome.unreadable);
          case StreamPostFailure.stalled:
            await _finishAfterConsult(session, TransferOutcome.idle);
          case StreamPostFailure.connectionLost:
            await _finishAfterConsult(
              session,
              session.lastByteAt != null
                  ? TransferOutcome.unconfirmed
                  : TransferOutcome.connectionLost,
            );
          case StreamPostFailure.noAnswer:
            _finish(session, TransferOutcome.unconfirmed);
          case StreamPostFailure.aborted:
            break;
        }
    }
  }

  TransferOutcome? _outcomeOfUpload(
    _OutSession session,
    HttpsResponse response,
  ) {
    if (response.status != 200) return null;
    final json = decodeJsonObject(response.body);
    final state = json == null ? null : RemoteState.tryParse(json);
    return state == null ? null : _resolve(session, state);
  }

  TransferOutcome? _resolve(_OutSession session, RemoteState state) {
    final outcome = outcomeOfRemote(state);
    if (state.status != RemoteStatus.saved) return outcome;
    final name = state.name;
    if (session.isFolder) {
      if (name == null || !isValidFileName(name) || isBlockedType(name)) {
        return TransferOutcome.noContact;
      }
      session.finalName = name;
    } else if (name != null) {
      return TransferOutcome.noContact;
    }
    return outcome;
  }

  Future<void> _finishAfterConsult(
    _OutSession session,
    TransferOutcome fallback,
  ) async {
    final queried = await _consult(session);
    if (session.done || session.stopping) return;
    _finish(session, queried ?? fallback);
  }

  Future<TransferOutcome?> _consult(_OutSession session) async {
    session.consulting = true;
    final id = session.id;
    if (id == null) return null;
    final start = session.lastByteAt ?? _clock();
    final poll = WaitRequest(transfer: id).toJson();
    while (!session.done &&
        !session.stopping &&
        _clock() - start < _confirmTimeout) {
      final sentAt = _clock();
      final reply = await session.link.post(
        ApiPaths.transferWait,
        poll,
        timeout: _pollHold + _pollMargin,
        abort: session.abort,
      );
      if (session.done || session.stopping) return null;
      if (reply == null || reply.$1 == 429) {
        await _pause(session, _retryDelay);
        continue;
      }
      final state = reply.$1 == 200 ? RemoteState.tryParse(reply.$2) : null;
      if (state == null) return null;
      if (state.status == RemoteStatus.uploading ||
          state.status == RemoteStatus.saving) {
        await _keepGap(session, sentAt);
        continue;
      }
      return _resolve(session, state);
    }
    return null;
  }

  void _progress(_OutSession session, int sent) {
    if (session.done) return;
    final layout = session.layout;
    if (session.isFolder && layout != null) {
      final progress = layout.progressAt(sent);
      session
        ..sentBytes = min(progress.payload, session.size)
        ..sentFiles = progress.files;
    } else {
      session.sentBytes = min(sent, session.size);
    }
    final now = _clock();
    final lastAt = session.lastProgressAt;
    if (session.sentBytes >= session.size ||
        lastAt == null ||
        now - lastAt >= Limits.transferProgressInterval) {
      session.lastProgressAt = now;
      _onChanged();
    }
  }

  void _bodySent(_OutSession session) {
    if (session.done) return;
    final now = _clock();
    session
      ..sentBytes = session.size
      ..sentFiles = session.plan?.manifest.files ?? 0
      ..phase = OutgoingPhase.verifying
      ..lastByteAt = now
      ..lastRenewAt = now;
    _onChanged();
    if (!session.stopping) unawaited(_renew(session));
  }

  Future<void> _renew(_OutSession session) async {
    final id = session.id;
    if (id == null) return;
    final poll = WaitRequest(transfer: id).toJson();
    try {
      while (!session.done &&
          !session.stopping &&
          !session.consulting &&
          session.phase == OutgoingPhase.verifying) {
        final sentAt = _clock();
        final reply = await session.link.post(
          ApiPaths.transferWait,
          poll,
          timeout: _pollHold + _pollMargin,
          abort: session.abort,
        );
        if (session.done || session.stopping || session.consulting) return;
        final state = reply != null && reply.$1 == 200
            ? RemoteState.tryParse(reply.$2)
            : null;
        if (state != null &&
            (state.status == RemoteStatus.uploading ||
                state.status == RemoteStatus.saving)) {
          session.lastRenewAt = _clock();
          await _keepGap(session, sentAt);
          continue;
        }
        await _pause(session, _retryDelay);
      }
    } catch (e) {
      _log('send renewal failed: ${e.runtimeType}');
    }
  }

  Future<void> _cancelUpload(_OutSession session) async {
    session.stopping = true;
    session.cancelling = true;
    TransferOutcome? outcome;
    try {
      _onChanged();
      final reply = await _sendCancel(
        session,
        CancelReason.cancelled,
        Limits.transferCancelTimeout,
      );
      final state = reply != null && reply.$1 == 200
          ? RemoteState.tryParse(reply.$2)
          : null;
      if (state != null && state.status == RemoteStatus.saved) {
        outcome = _resolve(session, state);
      }
    } catch (e) {
      _log('send cancel failed: ${e.runtimeType}');
    }
    _finish(session, outcome ?? TransferOutcome.cancelledHere);
  }

  void _tickSession() {
    final session = _active;
    if (session == null || session.done || session.stopping) return;
    if (session.phase == OutgoingPhase.verifying) {
      _tickVerifying(session);
      return;
    }
    if (session.phase != OutgoingPhase.waiting) return;
    final since = session.waitingSince;
    final lastAnswerAt = session.lastAnswerAt;
    if (since == null || lastAnswerAt == null) return;
    final now = _clock();
    final counted =
        session.counted +
        (session.lastPicker ? Duration.zero : now - lastAnswerAt);
    if (counted >= Limits.transferDecisionTimeout ||
        now - since >= Limits.transferDecisionCap) {
      unawaited(
        _sendCancel(
          session,
          CancelReason.cancelled,
          Limits.transferCancelTimeout,
        ),
      );
      _finish(session, TransferOutcome.unanswered);
    }
  }

  void _tickVerifying(_OutSession session) {
    final lastByteAt = session.lastByteAt;
    final lastRenewAt = session.lastRenewAt;
    if (lastByteAt == null || lastRenewAt == null) return;
    final now = _clock();
    if (now - lastRenewAt >= _confirmTimeout ||
        now - lastByteAt >= Limits.transferConfirmCap) {
      _finish(session, TransferOutcome.unconfirmed);
    }
  }

  Future<(int, Map<String, Object?>)?> _sendCancel(
    _OutSession session,
    CancelReason reason,
    Duration timeout, {
    int? entry,
  }) {
    final transfer = session.id;
    if (transfer == null) return Future.value();
    final pending = session.link.post(
      ApiPaths.transferCancel,
      CancelRequest(transfer: transfer, reason: reason, entry: entry).toJson(),
      timeout: timeout,
    );
    _cancels.add(pending);
    session.cancels.add(pending);
    unawaited(
      pending.whenComplete(() {
        _cancels.remove(pending);
        session.cancels.remove(pending);
      }),
    );
    return pending;
  }

  Future<void> _conclude(_OutSession session, TransferOutcome outcome) async {
    if (session.done) return;
    session.isProgram = await session.typeCheck;
    _finish(session, outcome);
  }

  void _finish(_OutSession session, TransferOutcome outcome) {
    if (session.done) return;
    session.done = true;
    session.abort.abort();
    session.planJob?.cancel();
    if (identical(_active, session)) _active = null;
    final result = TransferResultView(
      direction: TransferDirection.outgoing,
      peerFingerprint: session.target.fingerprint,
      peerName: session.peerName,
      fileName: visibleFileName(
        session.isFolder ? session.finalName ?? session.name : session.name,
      ),
      isProgram: session.isProgram,
      outcome: outcome,
      canReveal: false,
      isFolder: session.isFolder,
      fileCount: session.plan?.manifest.files ?? 0,
      problemPath: session.problemPath == null
          ? null
          : visibleFileName(session.problemPath!),
      size: session.size,
    );
    _lastSent = result;
    _onChanged();
    _completeAfterCancels(session, result);
  }

  void _completeAfterCancels(_OutSession session, TransferResultView result) {
    void complete() {
      if (!session.completion.isCompleted) session.completion.complete(result);
    }

    if (session.cancels.isEmpty) {
      complete();
      return;
    }
    unawaited(
      Future.wait<Object?>(session.cancels.toList())
          .then<void>((_) {}, onError: (Object _) {})
          .timeout(Limits.transferCancelTimeout, onTimeout: () {})
          .whenComplete(complete),
    );
  }

  Future<void> _keepGap(_OutSession session, Duration sentAt) {
    final elapsed = _clock() - sentAt;
    if (elapsed >= _retryDelay) return Future.value();
    return _pause(session, _retryDelay - elapsed);
  }

  Future<void> _pause(_OutSession session, Duration span) {
    final elapsed = Completer<void>();
    final timer = Timer(span, () {
      if (!elapsed.isCompleted) elapsed.complete();
    });
    final remove = session.abort.onAbort(() {
      timer.cancel();
      if (!elapsed.isCompleted) elapsed.complete();
    });
    return elapsed.future.whenComplete(remove);
  }
}
