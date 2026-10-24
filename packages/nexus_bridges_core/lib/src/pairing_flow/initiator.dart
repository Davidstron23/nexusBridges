import 'dart:async';
import 'dart:typed_data';

import '../identity/identity.dart';
import '../pairing/pairing.dart';
import '../protocol/protocol.dart';
import '../transport/transport.dart';
import 'crypto.dart';
import 'messages.dart';
import 'pairing_flow.dart';
import 'peer_link.dart';

const Duration _shortCancelTimeout = Duration(seconds: 1);

final Duration _hardDeadline =
    Limits.pairingTimeout + Limits.pairingMessageTimeout;

final class _InitiatorRun {
  _InitiatorRun({
    required this.target,
    required this.link,
    required this.linkAbort,
    required this.startedAt,
  });

  final PairingTarget target;

  final PeerLink link;

  final AbortSignal linkAbort;

  final DateTime startedAt;

  Uint8List? sessionBytes;

  PeerCertificate? serverCertificate;

  String? code;

  PairingPhase phase = PairingPhase.connecting;

  PairingOutcome? outcome;

  bool localConfirmed = false;

  bool saving = false;

  bool cancelSent = false;

  bool startInFlight = false;

  CancelReason? deferredCancel;

  bool get finished => phase == PairingPhase.finished;

  bool get waiting =>
      !saving &&
      (phase == PairingPhase.comparing || phase == PairingPhase.waitingPeer);
}

final class PairingInitiator {
  PairingInitiator({
    required this._identity,
    required this._paired,
    required this._ignored,
    required this._selfInfo,
    required this._now,
    required this._confirmRetry,
    required this._saveTimeout,
    required this._onChanged,
    required this._emit,
    required this._log,
  });

  final DeviceIdentity _identity;

  final PairedDevicesStore _paired;

  final IgnoredDevicesStore _ignored;

  final DeviceInfo Function() _selfInfo;

  final DateTime Function() _now;

  final Duration _confirmRetry;

  final Duration _saveTimeout;

  final void Function() _onChanged;

  final void Function(PairingEvent event) _emit;

  final void Function(String) _log;

  final Map<AbortSignal, Future<void>> _cancels = {};

  final Set<AbortSignal> _probes = {};

  final Set<Timer> _pauses = {};

  _InitiatorRun? _run;

  bool _closed = false;

  bool get busy {
    final run = _run;
    return run != null && !run.finished;
  }

  PairingView? get view {
    final run = _run;
    if (run == null) return null;
    if (run.finished && run.outcome == null) return null;
    return PairingView(
      role: PairingRole.initiator,
      phase: run.phase,
      peerFingerprint: run.target.fingerprint,
      peerName: sanitizeDisplayName(run.target.name ?? ''),
      code:
          run.phase == PairingPhase.comparing ||
              run.phase == PairingPhase.waitingPeer
          ? run.code
          : null,
      outcome: run.outcome,
    );
  }

  PairStart start(PairingTarget target) {
    if (_closed || busy) return PairStart.busy;
    final abort = AbortSignal();
    final run = _InitiatorRun(
      target: target,
      link: PeerLink(identity: _identity, target: target, abort: abort),
      linkAbort: abort,
      startedAt: _now(),
    );
    _run = run;
    _onChanged();
    unawaited(_guarded(run, () => _connect(run)));
    return PairStart.started;
  }

  void answer({required bool matches}) {
    final run = _run;
    if (_closed || run == null || run.finished || run.saving) return;
    if (!matches) {
      cancel();
      return;
    }
    if (run.phase != PairingPhase.comparing) return;
    run.localConfirmed = true;
    run.phase = PairingPhase.waitingPeer;
    _onChanged();
    unawaited(_guarded(run, () => _confirm(run)));
  }

  void cancel() {
    final run = _run;
    if (_closed || run == null || run.saving) return;
    if (run.phase != PairingPhase.connecting &&
        run.phase != PairingPhase.comparing) {
      return;
    }
    unawaited(_sendCancel(run, CancelReason.cancelled));
    _finish(run, null);
  }

  void dismissOutcome() {
    final run = _run;
    if (run == null || !run.finished) return;
    _run = null;
    _onChanged();
  }

  void discardFinished() {
    final run = _run;
    if (run != null && run.finished) _run = null;
  }

  void interfacesChanged(Set<String> activeInterfaceIds) {
    final run = _run;
    if (_closed || run == null || run.finished || run.saving) return;
    if (activeInterfaceIds.contains(run.target.interfaceId)) return;
    _cancelAndFinish(
      run,
      PairingOutcome.networkChanged,
      timeout: _shortCancelTimeout,
    );
  }

  void tick() {
    final run = _run;
    if (_closed || run == null || run.finished || run.saving) return;
    final elapsed = _now().difference(run.startedAt);
    final comparingStage =
        run.phase == PairingPhase.connecting ||
        run.phase == PairingPhase.comparing;
    if (elapsed < (comparingStage ? Limits.pairingTimeout : _hardDeadline)) {
      return;
    }
    unawaited(_sendCancel(run, CancelReason.expired));
    _finish(run, PairingOutcome.expired);
  }

  Future<PeerStatus> checkPeer(PairingTarget target) async {
    if (_closed) return PeerStatus.unknown;
    final abort = AbortSignal();
    _probes.add(abort);
    try {
      final link = PeerLink(identity: _identity, target: target, abort: abort);
      final challenge = randomBytes(challengeLength);
      final proof = _identity.sign(
        statusTranscript(
          callerFingerprint: _identity.fingerprint,
          serverFingerprint: target.fingerprint,
          challenge: challenge,
        ),
      );
      final reply = await link.post(
        ApiPaths.pairStatus,
        StatusRequest(
          certificate: _identity.certificate.pem,
          challenge: challenge,
          proof: proof,
        ).toJson(),
      );
      if (reply == null || reply.$1 != 200) return PeerStatus.unknown;
      final status = StatusReply.tryParse(reply.$2);
      if (status == null) return PeerStatus.unknown;
      return status.paired ? PeerStatus.paired : PeerStatus.notPaired;
    } catch (e) {
      _log('peer check failed: ${e.runtimeType}');
      return PeerStatus.unknown;
    } finally {
      _probes.remove(abort);
    }
  }

  Future<bool> notifyUnpaired(PairingTarget target) async {
    if (_closed) return false;
    final abort = AbortSignal();
    _probes.add(abort);
    try {
      final link = PeerLink(identity: _identity, target: target, abort: abort);
      final reply = await link.post(
        ApiPaths.unpair,
        const {},
        timeout: Limits.unpairNoticeTimeout,
        presentCertificate: true,
      );
      return reply != null && reply.$1 == 200;
    } catch (e) {
      _log('unpair notice failed: ${e.runtimeType}');
      return false;
    } finally {
      _probes.remove(abort);
    }
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    final run = _run;
    if (run != null && !run.finished && !run.saving) {
      unawaited(
        _sendCancel(run, CancelReason.cancelled, timeout: _shortCancelTimeout),
      );
      run.phase = PairingPhase.finished;
      run.outcome = null;
    }
    if (run != null) run.linkAbort.abort();
    for (final signal in _probes.toList()) {
      signal.abort();
    }
    for (final timer in _pauses.toList()) {
      timer.cancel();
    }
    _pauses.clear();
    final pending = _cancels.values.toList();
    if (pending.isEmpty) return;
    final deadline = Timer(_shortCancelTimeout, () {
      for (final signal in _cancels.keys.toList()) {
        signal.abort();
      }
    });
    await Future.wait(pending);
    deadline.cancel();
  }

  Future<void> _guarded(_InitiatorRun run, Future<void> Function() body) async {
    try {
      await body();
    } catch (e) {
      _log('pairing failed: ${e.runtimeType}');
      _finish(run, PairingOutcome.failed);
    }
  }

  Future<void> _connect(_InitiatorRun run) async {
    final target = run.target;
    final ownFingerprint = _identity.fingerprint;
    final ni = randomBytes(nonceLength);
    final ci = commitmentOf(
      role: PairingRole.initiator,
      fingerprint: ownFingerprint,
      nonce: ni,
    );
    final info = _selfInfo();
    final startT = startTranscript(
      initiatorFingerprint: ownFingerprint,
      receiverFingerprint: target.fingerprint,
      name: info.name,
      deviceType: info.deviceType,
      initiatorCommitment: ci,
    );
    run.startInFlight = true;
    final started = await run.link.post(
      ApiPaths.pairStart,
      StartRequest(
        certificate: _identity.certificate.pem,
        name: info.name,
        deviceType: info.deviceType,
        commitment: ci,
        proof: _identity.sign(startT),
      ).toJson(),
    );
    run.startInFlight = false;
    final deferred = run.deferredCancel;
    if (deferred != null) {
      _settleDeferredCancel(run, started, deferred);
      return;
    }
    if (run.finished) return;
    if (started == null) {
      _finish(run, PairingOutcome.failed);
      return;
    }
    if (started.$1 == 403) {
      _finish(run, PairingOutcome.rejected);
      return;
    }
    if (started.$1 == 409) {
      _finish(run, PairingOutcome.busy);
      return;
    }
    final startReply = started.$1 == 200
        ? StartReply.tryParse(started.$2)
        : null;
    final server = run.link.serverCertificate;
    if (startReply == null || server == null) {
      _finish(run, PairingOutcome.failed);
      return;
    }
    run.sessionBytes = startReply.session;
    run.serverCertificate = server;
    if (_subjectClashes(server, target.fingerprint)) {
      _cancelAndFinish(run, PairingOutcome.failed);
      return;
    }
    final revealT = revealTranscript(
      startTranscript: startT,
      sessionId: startReply.session,
      receiverCommitment: startReply.commitment,
      initiatorNonce: ni,
    );
    final revealed = await run.link.post(
      ApiPaths.pairReveal,
      RevealRequest(
        session: startReply.session,
        nonce: ni,
        signature: _identity.sign(revealT),
      ).toJson(),
    );
    if (run.finished) return;
    if (revealed == null) {
      _cancelAndFinish(run, PairingOutcome.lost, timeout: _shortCancelTimeout);
      return;
    }
    if (revealed.$1 == 403 || revealed.$1 == 404) {
      _finish(run, PairingOutcome.rejected);
      return;
    }
    final revealReply = revealed.$1 == 200
        ? RevealReply.tryParse(revealed.$2)
        : null;
    if (revealReply == null ||
        !commitmentMatches(
          startReply.commitment,
          role: PairingRole.receiver,
          fingerprint: target.fingerprint,
          nonce: revealReply.nonce,
        )) {
      _cancelAndFinish(run, PairingOutcome.failed);
      return;
    }
    run.code = pairingCode(
      initiatorFingerprint: ownFingerprint,
      receiverFingerprint: target.fingerprint,
      initiatorNonce: ni,
      receiverNonce: revealReply.nonce,
    );
    run.phase = PairingPhase.comparing;
    _onChanged();
    unawaited(_guarded(run, () => _poll(run)));
  }

  Future<void> _poll(_InitiatorRun run) async {
    final session = run.sessionBytes!;
    while (run.waiting) {
      final began = _now();
      final reply = await run.link.post(
        ApiPaths.pairWait,
        SessionRequest(session: session).toJson(),
      );
      if (!run.waiting) return;
      if (reply == null) {
        _cancelAndFinish(
          run,
          PairingOutcome.lost,
          timeout: _shortCancelTimeout,
        );
        return;
      }
      if (reply.$1 == 404) {
        _finish(run, PairingOutcome.cancelledByPeer);
        return;
      }
      final state = reply.$1 == 200 ? StateReply.tryParse(reply.$2) : null;
      if (state == null) {
        _cancelAndFinish(
          run,
          PairingOutcome.lost,
          timeout: _shortCancelTimeout,
        );
        return;
      }
      if (await _apply(run, state.state)) return;
      final elapsed = _now().difference(began);
      if (elapsed < _confirmRetry) {
        await _pause(run, _confirmRetry - elapsed);
      }
    }
  }

  Future<void> _confirm(_InitiatorRun run) async {
    final session = run.sessionBytes!;
    while (run.waiting) {
      final reply = await run.link.post(
        ApiPaths.pairConfirm,
        SessionRequest(session: session).toJson(),
      );
      if (!run.waiting) return;
      if (reply == null || reply.$1 >= 500 || reply.$1 == 429) {
        await _pause(run, _confirmRetry);
        continue;
      }
      if (reply.$1 == 404) {
        _finish(run, PairingOutcome.cancelledByPeer);
        return;
      }
      final state = reply.$1 == 200 ? StateReply.tryParse(reply.$2) : null;
      if (state == null) {
        _cancelAndFinish(run, PairingOutcome.failed);
        return;
      }
      await _apply(run, state.state);
      return;
    }
  }

  Future<bool> _apply(_InitiatorRun run, RemoteState state) async {
    switch (state) {
      case RemoteState.pending:
        return false;
      case RemoteState.paired:
        if (!run.localConfirmed) {
          _cancelAndFinish(run, PairingOutcome.failed);
          return true;
        }
        await _save(run);
        return true;
      case RemoteState.cancelled:
        _finish(run, PairingOutcome.cancelledByPeer);
        return true;
      case RemoteState.expired:
        _finish(run, PairingOutcome.expired);
        return true;
    }
  }

  Future<void> _save(_InitiatorRun run) async {
    if (run.saving || run.finished) return;
    run.saving = true;
    run.linkAbort.abort();
    final target = run.target;
    final name = sanitizeDisplayName(target.name ?? '');
    var result = PairingOutcome.failed;
    var isNew = false;
    final certificate = run.serverCertificate;
    if (_paired.isPaired(target.fingerprint)) {
      result = PairingOutcome.paired;
    } else if (_ignored.isIgnored(target.fingerprint) || certificate == null) {
      result = PairingOutcome.failed;
    } else {
      final added = await _paired.add(
        PairedDevice(
          fingerprint: target.fingerprint,
          name: name ?? '',
          certificatePem: certificate.pem,
          relation: PeerRelation.foreign,
          pairedAt: _now(),
        ),
        timeout: _saveTimeout,
      );
      switch (added) {
        case AddResult.added:
          result = PairingOutcome.paired;
          isNew = true;
        case AddResult.alreadyPaired:
          result = PairingOutcome.paired;
        case AddResult.notSaved:
          result = PairingOutcome.notSaved;
        case AddResult.duplicateSubject || AddResult.full:
          result = PairingOutcome.failed;
      }
    }
    _finish(run, isNew ? null : result);
    if (_closed) return;
    switch (result) {
      case PairingOutcome.paired:
        _emit(
          PairingCompleted(
            fingerprint: target.fingerprint,
            name: name,
            isNew: isNew,
          ),
        );
      case PairingOutcome.notSaved:
        _emit(PairingNotSaved(fingerprint: target.fingerprint));
      case PairingOutcome.failed:
        _emit(PairingFailed(fingerprint: target.fingerprint));
      default:
        break;
    }
  }

  Future<void> _sendCancel(
    _InitiatorRun run,
    CancelReason reason, {
    Duration timeout = Limits.pairingMessageTimeout,
  }) {
    if (run.cancelSent) return Future<void>.value();
    final session = run.sessionBytes;
    if (session == null && run.startInFlight) {
      run.deferredCancel ??= reason;
      _probes.add(run.linkAbort);
      return Future<void>.value();
    }
    run.cancelSent = true;
    Future<void> sent = Future<void>.value();
    if (session != null) {
      final signal = AbortSignal();
      sent = run.link
          .post(
            ApiPaths.pairCancel,
            CancelRequest(session: session, reason: reason).toJson(),
            timeout: timeout,
            abort: signal,
          )
          .then<void>((_) {}, onError: (Object _) {});
      _cancels[signal] = sent;
      unawaited(sent.whenComplete(() => _cancels.remove(signal)));
    }
    run.linkAbort.abort();
    return sent;
  }

  void _settleDeferredCancel(
    _InitiatorRun run,
    (int, Map<String, Object?>)? started,
    CancelReason reason,
  ) {
    run.deferredCancel = null;
    _probes.remove(run.linkAbort);
    final reply = started != null && started.$1 == 200
        ? StartReply.tryParse(started.$2)
        : null;
    if (reply == null || _closed) {
      run.linkAbort.abort();
      return;
    }
    run.sessionBytes = reply.session;
    unawaited(_sendCancel(run, reason));
  }

  void _cancelAndFinish(
    _InitiatorRun run,
    PairingOutcome outcome, {
    Duration timeout = Limits.pairingMessageTimeout,
  }) {
    unawaited(_sendCancel(run, CancelReason.cancelled, timeout: timeout));
    _finish(run, outcome);
  }

  void _finish(_InitiatorRun run, PairingOutcome? outcome) {
    if (run.finished) return;
    if (run.deferredCancel == null) run.linkAbort.abort();
    run.phase = PairingPhase.finished;
    run.outcome = outcome;
    _onChanged();
  }

  Future<void> _pause(_InitiatorRun run, Duration duration) {
    final done = Completer<void>();
    late final Timer timer;
    void release() {
      timer.cancel();
      _pauses.remove(timer);
      if (!done.isCompleted) done.complete();
    }

    timer = Timer(duration, release);
    _pauses.add(timer);
    final remove = run.linkAbort.onAbort(release);
    return done.future.whenComplete(remove);
  }

  bool _subjectClashes(PeerCertificate server, String fingerprint) {
    for (final device in _paired.devices) {
      if (device.fingerprint == fingerprint) continue;
      final other = PeerCertificate.tryParse(device.certificatePem);
      if (other != null && other.canonicalName == server.canonicalName) {
        return true;
      }
    }
    return false;
  }
}
