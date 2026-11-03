import 'dart:async';
import 'dart:io';

import '../identity/identity.dart';
import '../pairing/pairing.dart';
import '../protocol/protocol.dart';
import '../server/server.dart';
import 'guard.dart';
import 'initiator.dart';
import 'receiver.dart';

export 'peer_check.dart' show PeerCheckScheduler;

void _noLog(String message) {}

enum PairingRole { initiator, receiver }

enum PairingPhase { connecting, comparing, waitingPeer, finished }

enum PairingOutcome {
  paired,
  rejected,
  busy,
  paused,
  cancelledByPeer,
  expired,
  lost,
  networkChanged,
  failed,
  notSaved,
}

enum ReceiverAnswer { matches, mismatch, ignore }

enum PeerStatus { paired, notPaired, unknown }

enum PairStart { started, busy }

final class PairingTarget {
  const PairingTarget({
    required this.fingerprint,
    required this.name,
    required this.address,
    required this.port,
    required this.interfaceId,
    required this.localAddress,
  });

  final String fingerprint;

  final String? name;

  final InternetAddress address;

  final int port;

  final String interfaceId;

  final InternetAddress localAddress;

  @override
  bool operator ==(Object other) =>
      other is PairingTarget &&
      other.fingerprint == fingerprint &&
      other.name == name &&
      other.address == address &&
      other.port == port &&
      other.interfaceId == interfaceId &&
      other.localAddress == localAddress;

  @override
  int get hashCode =>
      Object.hash(fingerprint, name, address, port, interfaceId, localAddress);
}

final class PairingView {
  const PairingView({
    required this.role,
    required this.phase,
    required this.peerFingerprint,
    required this.peerName,
    this.code,
    this.alreadyPaired = false,
    this.outcome,
    this.isNew = false,
  });

  final PairingRole role;

  final PairingPhase phase;

  final String peerFingerprint;

  final String? peerName;

  final String? code;

  final bool alreadyPaired;

  final PairingOutcome? outcome;

  final bool isNew;

  @override
  bool operator ==(Object other) =>
      other is PairingView &&
      other.role == role &&
      other.phase == phase &&
      other.peerFingerprint == peerFingerprint &&
      other.peerName == peerName &&
      other.code == code &&
      other.alreadyPaired == alreadyPaired &&
      other.outcome == outcome &&
      other.isNew == isNew;

  @override
  int get hashCode => Object.hash(
    role,
    phase,
    peerFingerprint,
    peerName,
    code,
    alreadyPaired,
    outcome,
    isNew,
  );
}

sealed class PairingEvent {
  const PairingEvent();
}

final class PairingCompleted extends PairingEvent {
  const PairingCompleted({
    required this.fingerprint,
    required this.name,
    required this.isNew,
  });

  final String fingerprint;

  final String? name;

  final bool isNew;
}

final class UnpairedByPeer extends PairingEvent {
  const UnpairedByPeer({
    required this.fingerprint,
    required this.name,
    required this.saved,
  });

  final String fingerprint;

  final String name;

  final bool saved;
}

enum AttemptCause { commitmentMismatch, cancelledAfterReveal, lostAfterReveal }

final class PairingAttemptRejected extends PairingEvent {
  const PairingAttemptRejected({
    required this.fingerprint,
    required this.cause,
  });

  final String fingerprint;

  final AttemptCause cause;
}

final class PairingPaused extends PairingEvent {
  const PairingPaused({required this.until});

  final DateTime until;
}

final class PairingNotSaved extends PairingEvent {
  const PairingNotSaved({required this.fingerprint});

  final String fingerprint;
}

final class PairingFailed extends PairingEvent {
  const PairingFailed({required this.fingerprint});

  final String fingerprint;
}

final class IgnoreNotSaved extends PairingEvent {
  const IgnoreNotSaved({required this.fingerprint, required this.name});

  final String fingerprint;

  final String? name;
}

final class PairingCoordinator {
  PairingCoordinator({
    required this._identity,
    required this._paired,
    required this._ignored,
    required this._selfInfo,
    this._now = DateTime.now,
    this._tickInterval = const Duration(seconds: 1),
    Duration pollHold = Limits.pairingPollHold,
    this._confirmRetry = Limits.pairingConfirmRetry,
    this._saveTimeout = Limits.pairingMessageTimeout,
    this._log = _noLog,
  }) {
    _receiver = PairingReceiver(
      identity: _identity,
      paired: _paired,
      ignored: _ignored,
      guard: PairingGuard(now: _now),
      now: _now,
      pollHold: pollHold,
      saveTimeout: _saveTimeout,
      initiatorBusy: () => _initiator.busy,
      onViewClaimed: () => _initiator.discardFinished(),
      onChanged: _notify,
      emit: _emit,
      log: _log,
    );
    _initiator = PairingInitiator(
      identity: _identity,
      paired: _paired,
      ignored: _ignored,
      selfInfo: _selfInfo,
      now: _now,
      confirmRetry: _confirmRetry,
      saveTimeout: _saveTimeout,
      onChanged: _notify,
      emit: _emit,
      log: _log,
    );
  }

  final DeviceIdentity _identity;

  final PairedDevicesStore _paired;

  final IgnoredDevicesStore _ignored;

  final DeviceInfo Function() _selfInfo;

  final DateTime Function() _now;

  final Duration _tickInterval;

  final Duration _confirmRetry;

  final Duration _saveTimeout;

  final void Function(String) _log;

  late final PairingReceiver _receiver;

  late final PairingInitiator _initiator;

  final StreamController<void> _changes = StreamController<void>.broadcast();

  final StreamController<PairingEvent> _events =
      StreamController<PairingEvent>.broadcast();

  Timer? _timer;

  Future<void>? _closing;

  bool _closed = false;

  (PairingView?, bool)? _lastNotified;

  List<ApiRoute> get routes => _receiver.routes;

  PairingView? get view =>
      _initiator.busy ? _initiator.view : (_receiver.view ?? _initiator.view);

  bool get busy => _receiver.busy || _initiator.busy;

  Stream<void> get changes => _changes.stream;

  Stream<PairingEvent> get events => _events.stream;

  void start() {
    if (_closed || _timer != null) return;
    _timer = Timer.periodic(_tickInterval, (_) => _tick());
  }

  PairStart tryPair(PairingTarget target) {
    if (_closed || busy) return PairStart.busy;
    _receiver.discardFinished();
    return _initiator.start(target);
  }

  void answerAsInitiator({required bool matches}) {
    _initiator.answer(matches: matches);
  }

  void cancelAsInitiator() => _initiator.cancel();

  void answerAsReceiver(ReceiverAnswer answer) => _receiver.answer(answer);

  void cancelAsReceiver() => _receiver.cancel();

  void dismissOutcome() {
    _receiver.dismissOutcome();
    _initiator.dismissOutcome();
  }

  void interfacesChanged(Set<String> activeInterfaceIds) {
    _receiver.interfacesChanged(activeInterfaceIds);
    _initiator.interfacesChanged(activeInterfaceIds);
  }

  bool isPairingVia(Set<String> interfaceIds) =>
      _receiver.isPairingVia(interfaceIds) ||
      _initiator.isPairingVia(interfaceIds);

  Future<PeerStatus> checkPeer(PairingTarget target) =>
      _initiator.checkPeer(target);

  Future<bool> notifyUnpaired(PairingTarget target) =>
      _initiator.notifyUnpaired(target);

  Future<void> close() => _closing ??= _close();

  Future<void> _close() async {
    _timer?.cancel();
    _timer = null;
    await _initiator.close();
    _receiver.close();
    _closed = true;
    await _changes.close();
    await _events.close();
  }

  void _tick() {
    try {
      _receiver.tick();
      _initiator.tick();
    } catch (e) {
      _log('pairing tick failed: ${e.runtimeType}');
    }
  }

  void _notify() {
    if (_closed) return;
    final current = (view, busy);
    if (current == _lastNotified) return;
    _lastNotified = current;
    _changes.add(null);
  }

  void _emit(PairingEvent event) {
    if (_closed) return;
    _events.add(event);
  }
}
