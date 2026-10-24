import 'dart:io';

import 'package:nexus_bridges_core/src/pairing_flow/pairing_flow.dart';
import 'package:test/test.dart';

final String fp = 'A' * 64;

PairingTarget target({
  String? fingerprint,
  String? name = 'PC-DAVID',
  String address = '192.168.1.30',
  int port = 53530,
  String interfaceId = 'eth0',
  String localAddress = '192.168.1.10',
}) => PairingTarget(
  fingerprint: fingerprint ?? fp,
  name: name,
  address: InternetAddress(address),
  port: port,
  interfaceId: interfaceId,
  localAddress: InternetAddress(localAddress),
);

PairingView view({
  PairingRole role = PairingRole.receiver,
  PairingPhase phase = PairingPhase.comparing,
  String? peerFingerprint,
  String? peerName = 'PC-DAVID',
  String? code = '012345',
  bool alreadyPaired = false,
  PairingOutcome? outcome,
}) => PairingView(
  role: role,
  phase: phase,
  peerFingerprint: peerFingerprint ?? fp,
  peerName: peerName,
  code: code,
  alreadyPaired: alreadyPaired,
  outcome: outcome,
);

String describe(PairingEvent event) => switch (event) {
  PairingCompleted() => 'completed',
  UnpairedByPeer() => 'unpaired',
  PairingAttemptRejected() => 'rejected',
  PairingPaused() => 'paused',
  PairingNotSaved() => 'notSaved',
  PairingFailed() => 'failed',
  IgnoreNotSaved() => 'ignore',
};

void main() {
  test('the enums have exactly the values of the plan', () {
    expect(PairingRole.values.map((v) => v.name), ['initiator', 'receiver']);
    expect(PairingPhase.values.map((v) => v.name), [
      'connecting',
      'comparing',
      'waitingPeer',
      'finished',
    ]);
    expect(PairingOutcome.values.map((v) => v.name), [
      'paired',
      'rejected',
      'busy',
      'paused',
      'cancelledByPeer',
      'expired',
      'lost',
      'networkChanged',
      'failed',
      'notSaved',
    ]);
    expect(ReceiverAnswer.values.map((v) => v.name), [
      'matches',
      'mismatch',
      'ignore',
    ]);
    expect(PeerStatus.values.map((v) => v.name), [
      'paired',
      'notPaired',
      'unknown',
    ]);
    expect(PairStart.values.map((v) => v.name), ['started', 'busy']);
    expect(AttemptCause.values.map((v) => v.name), [
      'commitmentMismatch',
      'cancelledAfterReveal',
      'lostAfterReveal',
    ]);
  });

  test('PairingTarget compares by value', () {
    expect(target(), target());
    expect(target().hashCode, target().hashCode);
    for (final other in [
      target(fingerprint: 'B' * 64),
      target(name: null),
      target(name: 'otro'),
      target(address: '192.168.1.31'),
      target(port: 53531),
      target(interfaceId: 'wlan0'),
      target(localAddress: '192.168.1.11'),
    ]) {
      expect(other, isNot(target()));
    }
  });

  test('PairingView compares by value and alreadyPaired defaults to false', () {
    expect(view(), view());
    expect(view().hashCode, view().hashCode);
    expect(
      const PairingView(
        role: PairingRole.initiator,
        phase: PairingPhase.connecting,
        peerFingerprint: 'x',
        peerName: null,
      ).alreadyPaired,
      isFalse,
    );
    for (final other in [
      view(role: PairingRole.initiator),
      view(phase: PairingPhase.waitingPeer),
      view(peerFingerprint: 'B' * 64),
      view(peerName: null),
      view(code: null),
      view(code: '012346'),
      view(alreadyPaired: true),
      view(phase: PairingPhase.finished, outcome: PairingOutcome.paired),
    ]) {
      expect(other, isNot(view()));
    }
    expect(
      view(phase: PairingPhase.finished, outcome: PairingOutcome.expired),
      isNot(view(phase: PairingPhase.finished, outcome: PairingOutcome.lost)),
    );
  });

  test('the events are a closed family of seven', () {
    expect(
      [
        PairingCompleted(fingerprint: fp, name: null, isNew: true),
        UnpairedByPeer(fingerprint: fp, name: 'PC', saved: false),
        PairingAttemptRejected(
          fingerprint: fp,
          cause: AttemptCause.commitmentMismatch,
        ),
        PairingPaused(until: DateTime.utc(2026, 10, 24, 9, 10)),
        PairingNotSaved(fingerprint: fp),
        PairingFailed(fingerprint: fp),
        IgnoreNotSaved(fingerprint: fp, name: null),
      ].map(describe),
      [
        'completed',
        'unpaired',
        'rejected',
        'paused',
        'notSaved',
        'failed',
        'ignore',
      ],
    );
  });

  test('a rejected attempt carries its cause and the pause only its end '
      '(RF-79, RF-106b)', () {
    for (final cause in AttemptCause.values) {
      expect(
        PairingAttemptRejected(fingerprint: fp, cause: cause).cause,
        cause,
      );
    }
    final until = DateTime.utc(2026, 10, 24, 9, 10);
    final paused = PairingPaused(until: until);
    expect(paused.until, until);
    expect(() => (paused as dynamic).fingerprint, throwsNoSuchMethodError);
  });

  test('a rejected attempt, a save that failed and one that was not written '
      'carry only the fingerprint (V5, Q-9)', () {
    final rejected = PairingAttemptRejected(
      fingerprint: fp,
      cause: AttemptCause.commitmentMismatch,
    );
    final notSaved = PairingNotSaved(fingerprint: fp);
    final failed = PairingFailed(fingerprint: fp);

    expect(rejected.fingerprint, fp);
    expect(notSaved.fingerprint, fp);
    expect(failed.fingerprint, fp);
    for (final event in <Object>[rejected, notSaved, failed]) {
      expect(() => (event as dynamic).name, throwsNoSuchMethodError);
    }
  });
}
