import 'dart:async';
import 'dart:typed_data';

import '../identity/identity.dart';
import '../pairing/pairing.dart';
import '../protocol/protocol.dart';
import '../server/server.dart';
import 'crypto.dart';
import 'guard.dart';
import 'messages.dart';
import 'pairing_flow.dart';

const int _maxFinishedSessions = 16;

const ApiReply _rejected = ApiReply(403, {'error': 'rejected'});

const ApiReply _busy = ApiReply(409, {'error': 'busy'});

const ApiReply _paused = ApiReply(429, {'error': pausedErrorCode});

const ApiReply _notFound = ApiReply(404, {'error': 'not_found'});

const ApiReply _unauthorized = ApiReply(401, {'error': 'unauthorized'});

const RouteLimit _sessionLimit = RouteLimit(
  maxPerWindow: Limits.pairSessionRequestsPerMinute,
  window: Duration(minutes: 1),
  block: Limits.routeBlock,
);

const RouteLimit _statusLimit = RouteLimit(
  maxPerWindow: Limits.pairStatusPerMinute,
  window: Duration(minutes: 1),
  block: Limits.routeBlock,
);

const RouteLimit _unpairLimit = RouteLimit(
  maxPerWindow: Limits.unpairPerMinute,
  window: Duration(minutes: 1),
  block: Limits.routeBlock,
);

enum _ReceiverStatus {
  awaitingReveal,
  comparing,
  waitingPeer,
  saving,
  paired,
  cancelledLocal,
  cancelledByPeer,
  expired,
  lost,
  networkChanged,
  failed,
  notSaved,
}

final class _ReceiverSession {
  _ReceiverSession({
    required this.idBytes,
    required this.origin,
    required this.viaId,
    required this.peer,
    required this.name,
    required this.startTranscript,
    required this.ci,
    required this.nr,
    required this.cr,
    required this.startedAt,
  }) : id = toHex(idBytes),
       lastContact = startedAt;

  final Uint8List idBytes;

  final String id;

  final String origin;

  final String viaId;

  final PeerCertificate peer;

  final String? name;

  final Uint8List startTranscript;

  final Uint8List ci;

  final Uint8List nr;

  final Uint8List cr;

  final DateTime startedAt;

  String? code;

  DateTime lastContact;

  int held = 0;

  bool localConfirmed = false;

  bool peerConfirmed = false;

  bool alreadyPaired = false;

  bool reachedComparing = false;

  bool isNew = false;

  _ReceiverStatus status = _ReceiverStatus.awaitingReveal;

  DateTime? finishedAt;

  Completer<void> changed = Completer<void>();

  bool get inProgress => switch (status) {
    _ReceiverStatus.awaitingReveal ||
    _ReceiverStatus.comparing ||
    _ReceiverStatus.waitingPeer ||
    _ReceiverStatus.saving => true,
    _ => false,
  };
}

final class PairingReceiver {
  PairingReceiver({
    required this._identity,
    required this._paired,
    required this._ignored,
    required this._guard,
    required this._now,
    required this._pollHold,
    required this._saveTimeout,
    required this._initiatorBusy,
    required this._onViewClaimed,
    required this._onChanged,
    required this._emit,
    required this._log,
  });

  final DeviceIdentity _identity;

  final PairedDevicesStore _paired;

  final IgnoredDevicesStore _ignored;

  final PairingGuard _guard;

  final DateTime Function() _now;

  final Duration _pollHold;

  final Duration _saveTimeout;

  final bool Function() _initiatorBusy;

  final void Function() _onViewClaimed;

  final void Function() _onChanged;

  final void Function(PairingEvent event) _emit;

  final void Function(String) _log;

  final Map<String, _ReceiverSession> _sessions = {};

  final Set<Timer> _holdTimers = {};

  _ReceiverSession? _active;

  PairingView? _finishedView;

  bool _closed = false;

  late final List<ApiRoute> routes = List.unmodifiable([
    ApiRoute(
      path: ApiPaths.pairStart,
      access: RouteAccess.anonymous,
      handle: _handleStart,
      maxBodyBytes: Limits.maxPairingBodyBytes,
    ),
    ApiRoute(
      path: ApiPaths.pairReveal,
      access: RouteAccess.anonymous,
      handle: _handleReveal,
      maxBodyBytes: Limits.maxPairingBodyBytes,
      limit: _sessionLimit,
    ),
    ApiRoute(
      path: ApiPaths.pairWait,
      access: RouteAccess.anonymous,
      handle: _handleWait,
      maxBodyBytes: Limits.maxPairingBodyBytes,
      limit: _sessionLimit,
    ),
    ApiRoute(
      path: ApiPaths.pairConfirm,
      access: RouteAccess.anonymous,
      handle: _handleConfirm,
      maxBodyBytes: Limits.maxPairingBodyBytes,
      limit: _sessionLimit,
    ),
    ApiRoute(
      path: ApiPaths.pairCancel,
      access: RouteAccess.anonymous,
      handle: _handleCancel,
      maxBodyBytes: Limits.maxPairingBodyBytes,
      limit: _sessionLimit,
    ),
    ApiRoute(
      path: ApiPaths.pairStatus,
      access: RouteAccess.anonymous,
      handle: _handleStatus,
      maxBodyBytes: Limits.maxPairingBodyBytes,
      limit: _statusLimit,
    ),
    ApiRoute(
      path: ApiPaths.unpair,
      access: RouteAccess.paired,
      handle: _handleUnpair,
      maxBodyBytes: Limits.maxPairingBodyBytes,
      limit: _unpairLimit,
    ),
  ]);

  bool get busy => _active != null;

  PairingView? get view {
    final session = _active;
    if (session != null &&
        (session.status == _ReceiverStatus.comparing ||
            session.status == _ReceiverStatus.waitingPeer ||
            session.status == _ReceiverStatus.saving)) {
      return _runningViewOf(session);
    }
    return _finishedView;
  }

  void answer(ReceiverAnswer answer) {
    final session = _active;
    if (_closed || session == null) return;
    if (session.status != _ReceiverStatus.comparing) return;
    switch (answer) {
      case ReceiverAnswer.matches:
        session.localConfirmed = true;
        if (session.peerConfirmed) {
          unawaited(_save(session));
        } else {
          session.status = _ReceiverStatus.waitingPeer;
          _onChanged();
        }
      case ReceiverAnswer.mismatch:
        final until = _countFailureAfterReveal(session.origin);
        _finish(session, _ReceiverStatus.cancelledLocal);
        if (until != null) _emit(PairingPaused(until: until));
      case ReceiverAnswer.ignore:
        if (session.alreadyPaired) return;
        _finish(session, _ReceiverStatus.cancelledLocal);
        unawaited(_ignore(session));
    }
  }

  void cancel() {
    final session = _active;
    if (_closed ||
        session == null ||
        session.status != _ReceiverStatus.waitingPeer) {
      return;
    }
    final until = _countFailureAfterReveal(session.origin);
    _finish(session, _ReceiverStatus.cancelledLocal);
    if (until != null) _emit(PairingPaused(until: until));
  }

  void dismissOutcome() {
    if (_finishedView == null) return;
    _finishedView = null;
    _onChanged();
  }

  void discardFinished() {
    _finishedView = null;
  }

  bool isPairingVia(Set<String> interfaceIds) {
    final session = _active;
    return !_closed &&
        session != null &&
        session.inProgress &&
        interfaceIds.contains(session.viaId);
  }

  void interfacesChanged(Set<String> activeInterfaceIds) {
    final session = _active;
    if (_closed || session == null) return;
    if (session.status == _ReceiverStatus.saving) return;
    if (activeInterfaceIds.contains(session.viaId)) return;
    _finish(session, _ReceiverStatus.networkChanged);
  }

  void tick() {
    if (_closed) return;
    final now = _now();
    for (final session in _sessions.values.toList()) {
      if (session.inProgress) {
        if (session.status != _ReceiverStatus.saving &&
            now.difference(session.startedAt) >= Limits.pairingTimeout) {
          _finish(session, _ReceiverStatus.expired);
        } else if (session.status != _ReceiverStatus.saving &&
            session.held == 0 &&
            now.difference(session.lastContact) >
                Limits.pairingMessageTimeout) {
          final revealed =
              session.status == _ReceiverStatus.comparing ||
              session.status == _ReceiverStatus.waitingPeer;
          final until = revealed
              ? _countFailureAfterReveal(session.origin)
              : null;
          _finish(session, _ReceiverStatus.lost);
          if (revealed) {
            _emit(
              PairingAttemptRejected(
                fingerprint: session.peer.fingerprint,
                cause: AttemptCause.lostAfterReveal,
              ),
            );
            if (until != null) _emit(PairingPaused(until: until));
          }
        }
        continue;
      }
      final finishedAt = session.finishedAt;
      if (finishedAt != null &&
          now.difference(finishedAt) >= Limits.pairingRecordTtl) {
        _sessions.remove(session.id);
      }
    }
  }

  void close() {
    if (_closed) return;
    _closed = true;
    for (final timer in _holdTimers.toList()) {
      timer.cancel();
    }
    _holdTimers.clear();
    final now = _now();
    for (final session in _sessions.values.toList()) {
      if (session.inProgress && session.status != _ReceiverStatus.saving) {
        session.status = _ReceiverStatus.cancelledLocal;
        session.finishedAt = now;
        if (identical(_active, session)) _active = null;
      }
      _signal(session);
    }
    _finishedView = null;
    _onChanged();
  }

  Future<ApiReply> _handleStart(ApiCall call) async {
    if (_closed) return _rejected;
    try {
      return _start(call);
    } catch (e) {
      _log('pair start failed: ${e.runtimeType}');
      return _rejected;
    }
  }

  ApiReply _start(ApiCall call) {
    final origin = call.remoteAddress.address;
    if (_guard.globalBlocked(_now())) return _paused;
    if (!_guard.admit(origin)) return _rejected;
    final request = StartRequest.tryParse(call.json);
    if (request == null) return _rejected;
    final peer = PeerCertificate.tryParse(request.certificate);
    if (peer == null) return _rejected;
    final initiator = peer.fingerprint;
    if (initiator == _identity.fingerprint) return _rejected;
    if (_ignored.isIgnored(initiator)) return _rejected;
    if (_subjectClashes(peer)) return _rejected;
    if (!_paired.isPaired(initiator) &&
        _paired.devices.length >= PairedDevicesStore.maxDevices) {
      return _rejected;
    }
    final transcript = startTranscript(
      initiatorFingerprint: initiator,
      receiverFingerprint: _identity.fingerprint,
      name: request.name,
      deviceType: request.deviceType,
      initiatorCommitment: request.commitment,
    );
    if (!_guard.allowSignatureCheck(_now())) return _rejected;
    if (!peer.verify(transcript, request.proof)) return _rejected;
    if (_active != null || _initiatorBusy()) return _busy;
    final id = randomBytes(sessionIdLength);
    final nonce = randomBytes(nonceLength);
    final commitment = commitmentOf(
      role: PairingRole.receiver,
      fingerprint: _identity.fingerprint,
      nonce: nonce,
    );
    final rawName = request.name;
    final session = _ReceiverSession(
      idBytes: id,
      origin: origin,
      viaId: call.via.id,
      peer: peer,
      name: rawName == null ? null : sanitizeDisplayName(rawName),
      startTranscript: transcript,
      ci: request.commitment,
      nr: nonce,
      cr: commitment,
      startedAt: _now(),
    );
    _sessions[session.id] = session;
    _active = session;
    _onChanged();
    return ApiReply(
      200,
      StartReply(session: id, commitment: commitment).toJson(),
    );
  }

  Future<ApiReply> _handleReveal(ApiCall call) async {
    final request = RevealRequest.tryParse(call.json);
    if (request == null) return _notFound;
    final session = _find(request.session, call);
    if (session == null || session.status != _ReceiverStatus.awaitingReveal) {
      return _notFound;
    }
    session.lastContact = _now();
    final initiator = session.peer.fingerprint;
    if (!commitmentMatches(
      session.ci,
      role: PairingRole.initiator,
      fingerprint: initiator,
      nonce: request.nonce,
    )) {
      _discard(session);
      final until = _countFailureAfterReveal(session.origin);
      _emit(
        PairingAttemptRejected(
          fingerprint: initiator,
          cause: AttemptCause.commitmentMismatch,
        ),
      );
      if (until != null) _emit(PairingPaused(until: until));
      return _rejected;
    }
    final transcript = revealTranscript(
      startTranscript: session.startTranscript,
      sessionId: session.idBytes,
      receiverCommitment: session.cr,
      initiatorNonce: request.nonce,
    );
    if (!session.peer.verify(transcript, request.signature)) {
      _discard(session);
      return _rejected;
    }
    session.code = pairingCode(
      initiatorFingerprint: initiator,
      receiverFingerprint: _identity.fingerprint,
      initiatorNonce: request.nonce,
      receiverNonce: session.nr,
    );
    session.alreadyPaired = _paired.isPaired(initiator);
    session.reachedComparing = true;
    session.status = _ReceiverStatus.comparing;
    _finishedView = null;
    _onViewClaimed();
    _onChanged();
    return ApiReply(200, RevealReply(nonce: session.nr).toJson());
  }

  Future<ApiReply> _handleWait(ApiCall call) async {
    final request = SessionRequest.tryParse(call.json);
    if (request == null) return _notFound;
    final session = _find(request.session, call);
    if (session == null || session.status == _ReceiverStatus.awaitingReveal) {
      return _notFound;
    }
    session.held++;
    session.lastContact = _now();
    try {
      if (_remoteOf(session.status) == RemoteState.pending) {
        await _hold(session);
      }
    } finally {
      session.held--;
      session.lastContact = _now();
    }
    return _stateReply(session);
  }

  Future<ApiReply> _handleConfirm(ApiCall call) async {
    final request = SessionRequest.tryParse(call.json);
    if (request == null) return _notFound;
    final session = _find(request.session, call);
    if (session == null || session.status == _ReceiverStatus.awaitingReveal) {
      return _notFound;
    }
    session.lastContact = _now();
    switch (session.status) {
      case _ReceiverStatus.comparing || _ReceiverStatus.waitingPeer:
        session.peerConfirmed = true;
        if (session.localConfirmed) await _save(session);
      case _ReceiverStatus.saving:
        await _settled(session);
      default:
        break;
    }
    return _stateReply(session);
  }

  Future<ApiReply> _handleCancel(ApiCall call) async {
    final request = CancelRequest.tryParse(call.json);
    if (request == null) return _notFound;
    final session = _find(request.session, call);
    if (session == null) return _notFound;
    if (session.inProgress && session.status != _ReceiverStatus.saving) {
      final revealed =
          session.status == _ReceiverStatus.comparing ||
          session.status == _ReceiverStatus.waitingPeer;
      final genuineExpiry =
          request.reason == CancelReason.expired &&
          _now().difference(session.startedAt) >= Limits.pairingPeerExpiryAfter;
      final cancelledAfterReveal = revealed && !genuineExpiry;
      final until = cancelledAfterReveal
          ? _countFailureAfterReveal(session.origin)
          : null;
      _finish(
        session,
        genuineExpiry
            ? _ReceiverStatus.expired
            : _ReceiverStatus.cancelledByPeer,
      );
      if (cancelledAfterReveal) {
        _emit(
          PairingAttemptRejected(
            fingerprint: session.peer.fingerprint,
            cause: AttemptCause.cancelledAfterReveal,
          ),
        );
        if (until != null) _emit(PairingPaused(until: until));
      }
    }
    return _stateReply(session);
  }

  Future<ApiReply> _handleStatus(ApiCall call) async {
    final request = StatusRequest.tryParse(call.json);
    if (request == null) return _rejected;
    final peer = PeerCertificate.tryParse(request.certificate);
    if (peer == null) return _rejected;
    if (!_guard.allowSignatureCheck(_now())) return _rejected;
    final transcript = statusTranscript(
      callerFingerprint: peer.fingerprint,
      serverFingerprint: _identity.fingerprint,
      challenge: request.challenge,
    );
    if (!peer.verify(transcript, request.proof)) return _rejected;
    return ApiReply(
      200,
      StatusReply(paired: _paired.isPaired(peer.fingerprint)).toJson(),
    );
  }

  Future<ApiReply> _handleUnpair(ApiCall call) async {
    final fingerprint = call.clientFingerprint;
    final device = fingerprint == null ? null : _paired.deviceOf(fingerprint);
    if (fingerprint == null || device == null) return _unauthorized;
    return ApiReply(
      200,
      const {},
      afterResponse: () async {
        final saved = await _paired.remove(fingerprint);
        if (_closed) return;
        _emit(
          UnpairedByPeer(
            fingerprint: fingerprint,
            name: device.name,
            saved: saved,
          ),
        );
      },
    );
  }

  _ReceiverSession? _find(Uint8List idBytes, ApiCall call) {
    final session = _sessions[toHex(idBytes)];
    if (session == null) return null;
    if (call.remoteAddress.address != session.origin) return null;
    if (call.via.id != session.viaId) return null;
    return session;
  }

  DateTime? _countFailureAfterReveal(String origin) {
    _guard.countMismatch(origin);
    return _guard.countGlobalFailure(_now());
  }

  bool _subjectClashes(PeerCertificate peer) {
    for (final device in _paired.devices) {
      if (device.fingerprint == peer.fingerprint) continue;
      final other = PeerCertificate.tryParse(device.certificatePem);
      if (other != null && other.canonicalName == peer.canonicalName) {
        return true;
      }
    }
    return false;
  }

  Future<void> _save(_ReceiverSession session) async {
    session.status = _ReceiverStatus.saving;
    _onChanged();
    final fingerprint = session.peer.fingerprint;
    var result = _ReceiverStatus.failed;
    var isNew = false;
    try {
      if (_paired.isPaired(fingerprint)) {
        result = _ReceiverStatus.paired;
      } else if (session.alreadyPaired || _ignored.isIgnored(fingerprint)) {
        result = _ReceiverStatus.failed;
      } else {
        final added = await _paired.add(
          PairedDevice(
            fingerprint: fingerprint,
            name: session.name ?? '',
            certificatePem: session.peer.pem,
            relation: PeerRelation.foreign,
            pairedAt: _now(),
          ),
          timeout: _saveTimeout,
        );
        switch (added) {
          case AddResult.added:
            result = _ReceiverStatus.paired;
            isNew = true;
          case AddResult.alreadyPaired:
            result = _ReceiverStatus.paired;
          case AddResult.notSaved:
            result = _ReceiverStatus.notSaved;
          case AddResult.duplicateSubject || AddResult.full:
            result = _ReceiverStatus.failed;
        }
      }
    } catch (e) {
      _log('pair save failed: ${e.runtimeType}');
      result = _ReceiverStatus.failed;
    }
    if (result == _ReceiverStatus.paired) _guard.reset(session.origin);
    _finish(session, result, isNew: isNew);
    if (_closed) return;
    switch (result) {
      case _ReceiverStatus.paired:
        _emit(
          PairingCompleted(
            fingerprint: fingerprint,
            name: session.name,
            isNew: isNew,
          ),
        );
      case _ReceiverStatus.notSaved:
        _emit(PairingNotSaved(fingerprint: fingerprint));
      case _ReceiverStatus.failed:
        _emit(PairingFailed(fingerprint: fingerprint));
      default:
        break;
    }
  }

  Future<void> _ignore(_ReceiverSession session) async {
    try {
      final result = await _ignored.ignore(
        session.peer.fingerprint,
        name: session.name ?? '',
      );
      if (result == IgnoreResult.notSaved && !_closed) {
        _emit(
          IgnoreNotSaved(
            fingerprint: session.peer.fingerprint,
            name: session.name,
          ),
        );
      }
    } catch (e) {
      _log('ignore failed: ${e.runtimeType}');
    }
  }

  void _discard(_ReceiverSession session) {
    _sessions.remove(session.id);
    if (identical(_active, session)) _active = null;
    _signal(session);
    _onChanged();
  }

  void _finish(
    _ReceiverSession session,
    _ReceiverStatus status, {
    bool isNew = false,
  }) {
    session.status = status;
    session.finishedAt = _now();
    session.isNew = isNew;
    if (identical(_active, session)) _active = null;
    if (session.reachedComparing && !_closed) {
      _finishedView = status == _ReceiverStatus.cancelledLocal
          ? null
          : _finishedViewOf(session);
    }
    _trimFinished();
    _signal(session);
    _onChanged();
  }

  void _trimFinished() {
    final finished = [
      for (final session in _sessions.values)
        if (session.finishedAt != null) session,
    ]..sort((a, b) => a.finishedAt!.compareTo(b.finishedAt!));
    var excess = finished.length - _maxFinishedSessions;
    for (final session in finished) {
      if (excess-- <= 0) break;
      _sessions.remove(session.id);
    }
  }

  void _signal(_ReceiverSession session) {
    final previous = session.changed;
    session.changed = Completer<void>();
    previous.complete();
  }

  Future<void> _hold(_ReceiverSession session) {
    if (_closed) return Future<void>.value();
    final released = Completer<void>();
    late final Timer timer;
    void release() {
      timer.cancel();
      _holdTimers.remove(timer);
      if (!released.isCompleted) released.complete();
    }

    timer = Timer(_pollHold, release);
    _holdTimers.add(timer);
    unawaited(session.changed.future.then((_) => release()));
    return released.future;
  }

  Future<void> _settled(_ReceiverSession session) async {
    while (session.status == _ReceiverStatus.saving && !_closed) {
      await session.changed.future;
    }
  }

  ApiReply _stateReply(_ReceiverSession session) =>
      ApiReply(200, StateReply(state: _remoteOf(session.status)).toJson());

  RemoteState _remoteOf(_ReceiverStatus status) => switch (status) {
    _ReceiverStatus.awaitingReveal ||
    _ReceiverStatus.comparing ||
    _ReceiverStatus.waitingPeer ||
    _ReceiverStatus.saving => RemoteState.pending,
    _ReceiverStatus.paired => RemoteState.paired,
    _ReceiverStatus.expired => RemoteState.expired,
    _ReceiverStatus.cancelledLocal ||
    _ReceiverStatus.cancelledByPeer ||
    _ReceiverStatus.lost ||
    _ReceiverStatus.networkChanged ||
    _ReceiverStatus.failed ||
    _ReceiverStatus.notSaved => RemoteState.cancelled,
  };

  PairingView _runningViewOf(_ReceiverSession session) => PairingView(
    role: PairingRole.receiver,
    phase: session.status == _ReceiverStatus.comparing
        ? PairingPhase.comparing
        : PairingPhase.waitingPeer,
    peerFingerprint: session.peer.fingerprint,
    peerName: session.name,
    code: session.code,
    alreadyPaired: session.alreadyPaired,
  );

  PairingView _finishedViewOf(_ReceiverSession session) => PairingView(
    role: PairingRole.receiver,
    phase: PairingPhase.finished,
    peerFingerprint: session.peer.fingerprint,
    peerName: session.name,
    alreadyPaired: session.alreadyPaired,
    outcome: _outcomeOf(session.status),
    isNew: session.isNew,
  );

  PairingOutcome _outcomeOf(_ReceiverStatus status) => switch (status) {
    _ReceiverStatus.paired => PairingOutcome.paired,
    _ReceiverStatus.cancelledByPeer => PairingOutcome.cancelledByPeer,
    _ReceiverStatus.expired => PairingOutcome.expired,
    _ReceiverStatus.lost => PairingOutcome.lost,
    _ReceiverStatus.networkChanged => PairingOutcome.networkChanged,
    _ReceiverStatus.notSaved => PairingOutcome.notSaved,
    _ => PairingOutcome.failed,
  };
}
