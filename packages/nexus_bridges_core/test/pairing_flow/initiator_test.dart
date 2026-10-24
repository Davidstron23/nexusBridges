import 'dart:async';
import 'dart:io';

import 'package:nexus_bridges_core/src/identity/certificate_parser.dart';
import 'package:nexus_bridges_core/src/identity/identity.dart';
import 'package:nexus_bridges_core/src/pairing/pairing.dart';
import 'package:nexus_bridges_core/src/pairing_flow/crypto.dart';
import 'package:nexus_bridges_core/src/pairing_flow/pairing_flow.dart';
import 'package:nexus_bridges_core/src/protocol/protocol.dart';
import 'package:nexus_bridges_core/src/server/server.dart';
import 'package:test/test.dart';

import '../server/api_server_harness.dart';
import 'initiator_harness.dart';

void main() {
  late DeviceIdentity ia;
  late DeviceIdentity ib;
  late DeviceIdentity ic;
  late DeviceIdentity ix;

  setUpAll(() {
    ia = DeviceIdentity.generate();
    ib = DeviceIdentity.generate();
    ic = DeviceIdentity.generate();
    ix = DeviceIdentity.generate();
  });

  Future<PairingStack> stackA({
    StackClock? clock,
    Duration pollHold = const Duration(milliseconds: 200),
    Duration saveTimeout = Limits.pairingMessageTimeout,
  }) => PairingStack.start(
    identity: ia,
    address: loopback,
    name: 'Stack A',
    clock: clock,
    pollHold: pollHold,
    saveTimeout: saveTimeout,
  );

  Future<PairingStack> stackB({
    StackClock? clock,
    Duration pollHold = const Duration(milliseconds: 200),
    Duration saveTimeout = Limits.pairingMessageTimeout,
  }) => PairingStack.start(
    identity: ib,
    address: otherLoopback,
    name: 'Stack B',
    clock: clock,
    pollHold: pollHold,
    saveTimeout: saveTimeout,
  );

  Future<PairingStack> stackC() => PairingStack.start(
    identity: ic,
    address: stackLoopbackC,
    name: 'Stack C',
  );

  Future<(PairingStack, PairingStack)> twoStacks({
    StackClock? clockA,
    StackClock? clockB,
    Duration pollHoldB = const Duration(milliseconds: 200),
    Duration saveTimeoutB = Limits.pairingMessageTimeout,
  }) async {
    final a = await stackA(clock: clockA);
    final b = await stackB(
      clock: clockB,
      pollHold: pollHoldB,
      saveTimeout: saveTimeoutB,
    );
    return (a, b);
  }

  Future<void> bothComparing(PairingStack a, PairingStack b) => waitUntil(
    () =>
        a.view?.phase == PairingPhase.comparing &&
        b.view?.phase == PairingPhase.comparing,
    reason: 'both comparing',
  );

  Future<void> begin(PairingStack a, PairingStack b) async {
    expect(a.coordinator.tryPair(a.targetOf(b)), PairStart.started);
    await bothComparing(a, b);
  }

  Future<void> outcomeOf(PairingStack stack, PairingOutcome outcome) =>
      waitUntil(
        () => stack.view?.outcome == outcome,
        reason: '${stack.name} $outcome (now ${stack.view?.outcome})',
      );

  Future<FakeReceiver> fakeB() => FakeReceiver.of(ib);

  PairingTarget fakeTarget(PairingStack a, FakeReceiver fake) =>
      a.targetAt(fake.address, fake.port, fingerprint: fake.fingerprint);

  Future<void> fakeComparing(PairingStack a, FakeReceiver fake) async {
    expect(a.coordinator.tryPair(fakeTarget(a, fake)), PairStart.started);
    await waitUntil(
      () => a.view?.phase == PairingPhase.comparing,
      reason: 'initiator comparing',
    );
  }

  group('full pairing between two stacks (C45, C52, RF-72, RF-73, RF-87, RF-88, RF-97)', () {
    test('connecting at once, then the same code on both sides', () async {
      final (a, b) = await twoStacks();
      expect(a.coordinator.tryPair(a.targetOf(b)), PairStart.started);
      expect(
        a.view,
        PairingView(
          role: PairingRole.initiator,
          phase: PairingPhase.connecting,
          peerFingerprint: b.fingerprint,
          peerName: 'Stack B',
        ),
      );
      expect(a.coordinator.busy, isTrue);
      await bothComparing(a, b);
      final code = a.view!.code;
      expect(code, matches(RegExp(r'^[0-9]{6}$')));
      expect(b.view!.code, code);
      expect(a.view!.role, PairingRole.initiator);
      expect(a.view!.peerFingerprint, b.fingerprint);
      expect(a.view!.peerName, 'Stack B');
      expect(a.view!.outcome, isNull);
      expect(b.view!.role, PairingRole.receiver);
      expect(b.view!.peerFingerprint, a.fingerprint);
      expect(b.view!.peerName, 'Stack A');
    });

    test('a target name with control characters is shown sanitized', () async {
      final (a, b) = await twoStacks();
      const raw = 'Stack\u202EB';
      a.coordinator.tryPair(a.targetOf(b, name: raw));
      expect(a.view!.peerName, sanitizeDisplayName(raw));
      expect(a.view!.peerName, isNot(contains('\u202E')));
      await bothComparing(a, b);
      expect(a.view!.peerName, sanitizeDisplayName(raw));
    });

    test(
      'receiver confirms first: nothing is saved until the initiator confirms',
      () async {
        final (a, b) = await twoStacks();
        await begin(a, b);
        b.coordinator.answerAsReceiver(ReceiverAnswer.matches);
        await waitUntil(() => b.view?.phase == PairingPhase.waitingPeer);
        await pause(const Duration(milliseconds: 500));
        expect(b.paired.isPaired(a.fingerprint), isFalse);
        expect(a.paired.isPaired(b.fingerprint), isFalse);
        expect(a.view!.phase, PairingPhase.comparing);
        a.coordinator.answerAsInitiator(matches: true);
        await waitUntil(
          () =>
              a.paired.isPaired(b.fingerprint) &&
              b.paired.isPaired(a.fingerprint) &&
              a.view == null &&
              b.view == null,
          reason: 'both paired',
        );
        expect(a.coordinator.busy, isFalse);
        expect(b.coordinator.busy, isFalse);
      },
    );

    test(
      'initiator confirms first: nothing is saved until the receiver confirms',
      () async {
        final (a, b) = await twoStacks();
        await begin(a, b);
        final code = a.view!.code;
        a.coordinator.answerAsInitiator(matches: true);
        expect(a.view!.phase, PairingPhase.waitingPeer);
        expect(a.view!.code, code);
        await waitUntil(() => b.handledOn(ApiPaths.pairConfirm) >= 1);
        await pause(const Duration(milliseconds: 500));
        expect(a.paired.isPaired(b.fingerprint), isFalse);
        expect(b.paired.isPaired(a.fingerprint), isFalse);
        expect(b.view!.phase, PairingPhase.comparing);
        expect(a.view!.phase, PairingPhase.waitingPeer);
        b.coordinator.answerAsReceiver(ReceiverAnswer.matches);
        await waitUntil(
          () =>
              a.paired.isPaired(b.fingerprint) &&
              b.paired.isPaired(a.fingerprint) &&
              a.view == null &&
              b.view == null,
          reason: 'both paired',
        );
      },
    );

    test(
      'a new pairing is stored as foreign on both sides, on disk, with isNew',
      () async {
        final (a, b) = await twoStacks();
        await begin(a, b);
        b.coordinator.answerAsReceiver(ReceiverAnswer.matches);
        a.coordinator.answerAsInitiator(matches: true);
        await waitUntil(
          () => a.completions.isNotEmpty && b.completions.isNotEmpty,
          reason: 'completions',
        );
        final onA = a.paired.deviceOf(b.fingerprint)!;
        expect(onA.relation, PeerRelation.foreign);
        expect(onA.name, 'Stack B');
        expect(onA.certificatePem, ib.certificate.pem);
        final onB = b.paired.deviceOf(a.fingerprint)!;
        expect(onB.relation, PeerRelation.foreign);
        expect(onB.name, 'Stack A');
        expect(a.completions.single.fingerprint, b.fingerprint);
        expect(a.completions.single.name, 'Stack B');
        expect(a.completions.single.isNew, isTrue);
        expect(b.completions.single.fingerprint, a.fingerprint);
        expect(b.completions.single.isNew, isTrue);
        final stored = await a.reloadPaired();
        expect(stored.map((d) => d.fingerprint), [b.fingerprint]);
        expect(stored.single.relation, PeerRelation.foreign);
        expect(a.views.last, isNull);
      },
    );

    test('pairing again with an already paired device keeps it (isNew: false, RF-85)', () async {
      final (a, b) = await twoStacks();
      await a.pairWith([ib]);
      await b.pairWith([ia]);
      await begin(a, b);
      expect(b.view!.alreadyPaired, isTrue);
      b.coordinator.answerAsReceiver(ReceiverAnswer.matches);
      a.coordinator.answerAsInitiator(matches: true);
      await outcomeOf(a, PairingOutcome.paired);
      expect(a.view!.phase, PairingPhase.finished);
      expect(a.coordinator.busy, isFalse);
      expect(a.completions.single.isNew, isFalse);
      expect(a.completions.single.fingerprint, b.fingerprint);
      expect(a.paired.deviceOf(b.fingerprint)!.relation, PeerRelation.mine);
      expect(a.paired.devices, hasLength(1));
      await waitUntil(() => b.completions.isNotEmpty);
      expect(b.completions.single.isNew, isFalse);
      expect(b.paired.deviceOf(a.fingerprint)!.relation, PeerRelation.mine);
      a.coordinator.dismissOutcome();
      expect(a.view, isNull);
    });
  });

  group('mismatch and cancel (C46, RF-89, RF-108)', () {
    test('initiator says it does not match: its view closes, the receiver sees cancelledByPeer', () async {
      final (a, b) = await twoStacks();
      await begin(a, b);
      a.coordinator.answerAsInitiator(matches: false);
      expect(a.view, isNull);
      expect(a.coordinator.busy, isFalse);
      await outcomeOf(b, PairingOutcome.cancelledByPeer);
      expect(b.handledOn(ApiPaths.pairCancel), 1);
      expect(
        b.calls[ApiPaths.pairCancel]!.single.json,
        containsPair('reason', 'cancelled'),
      );
      expect(a.paired.devices, isEmpty);
      expect(b.paired.devices, isEmpty);
      expect(a.events, isEmpty);
    });

    test('initiator cancels while comparing: same as no match', () async {
      final (a, b) = await twoStacks();
      await begin(a, b);
      a.coordinator.cancelAsInitiator();
      expect(a.view, isNull);
      expect(a.coordinator.busy, isFalse);
      await outcomeOf(b, PairingOutcome.cancelledByPeer);
      await pause();
      expect(b.handledOn(ApiPaths.pairCancel), 1);
      expect(a.paired.devices, isEmpty);
      expect(b.paired.devices, isEmpty);
    });

    test(
      'initiator cancels while connecting: no session, no cancel, no reveal',
      () async {
        final a = await stackA();
        final fake = await fakeB();
        fake.handlers[ApiPaths.pairStart] = (_) => fake.hang();
        a.coordinator.tryPair(fakeTarget(a, fake));
        await waitUntil(() => fake.count(ApiPaths.pairStart) == 1);
        a.coordinator.cancelAsInitiator();
        expect(a.view, isNull);
        expect(a.coordinator.busy, isFalse);
        await pause();
        expect(fake.count(ApiPaths.pairCancel), 0);
        expect(fake.count(ApiPaths.pairReveal), 0);
      },
    );

    test('cancel in the same turn as tryPair: closed view at once, and the '
        'start already on its way is followed by one cancel with its session '
        'and nothing else (Q-6)', () async {
      final a = await stackA();
      final fake = await fakeB();
      expect(a.coordinator.tryPair(fakeTarget(a, fake)), PairStart.started);
      a.coordinator.cancelAsInitiator();
      expect(a.view, isNull);
      expect(a.coordinator.busy, isFalse);
      await waitUntil(() => fake.count(ApiPaths.pairCancel) == 1);
      await pause();
      expect(fake.calls.map((c) => c.path), [
        ApiPaths.pairStart,
        ApiPaths.pairCancel,
      ]);
      final cancel = fake.callsTo(ApiPaths.pairCancel).single.body;
      expect(cancel['session'], toHex(fake.session));
      expect(cancel['reason'], 'cancelled');
      expect(a.view, isNull);
      expect(a.events, isEmpty);
    });

    test(
      'receiver says it does not match: initiator ends in cancelledByPeer',
      () async {
        final (a, b) = await twoStacks();
        await begin(a, b);
        b.coordinator.answerAsReceiver(ReceiverAnswer.mismatch);
        await outcomeOf(a, PairingOutcome.cancelledByPeer);
        expect(a.view!.phase, PairingPhase.finished);
        expect(a.coordinator.busy, isFalse);
        expect(a.paired.devices, isEmpty);
        expect(b.paired.devices, isEmpty);
      },
    );

    test('receiver ignores: initiator cancelledByPeer and a new attempt is rejected', () async {
      final (a, b) = await twoStacks();
      await begin(a, b);
      b.coordinator.answerAsReceiver(ReceiverAnswer.ignore);
      await outcomeOf(a, PairingOutcome.cancelledByPeer);
      await waitUntil(() => b.ignored.isIgnored(a.fingerprint));
      a.coordinator.dismissOutcome();
      expect(a.view, isNull);
      expect(a.coordinator.tryPair(a.targetOf(b)), PairStart.started);
      await outcomeOf(a, PairingOutcome.rejected);
      expect(a.paired.devices, isEmpty);
      expect(b.paired.devices, isEmpty);
    });

    test('after "matches" the initiator can no longer cancel (D3)', () async {
      final (a, b) = await twoStacks();
      await begin(a, b);
      a.coordinator.answerAsInitiator(matches: true);
      a.coordinator.cancelAsInitiator();
      a.coordinator.answerAsInitiator(matches: false);
      expect(a.view!.phase, PairingPhase.waitingPeer);
      await pause();
      expect(b.handledOn(ApiPaths.pairCancel), 0);
      b.coordinator.answerAsReceiver(ReceiverAnswer.matches);
      await waitUntil(
        () =>
            a.paired.isPaired(b.fingerprint) &&
            b.paired.isPaired(a.fingerprint),
      );
    });

    test('answers without a pairing in course do nothing', () async {
      final a = await stackA();
      a.coordinator.answerAsInitiator(matches: true);
      a.coordinator.answerAsInitiator(matches: false);
      a.coordinator.cancelAsInitiator();
      expect(a.view, isNull);
      expect(a.coordinator.busy, isFalse);
      expect(a.views, isEmpty);
    });
  });

  group('expiry (C47, C100, RF-90)', () {
    test('shared clock, nobody confirmed: both end in expired', () async {
      final clock = StackClock();
      final (a, b) = await twoStacks(clockA: clock, clockB: clock);
      await begin(a, b);
      clock.advance(const Duration(seconds: 61));
      await outcomeOf(a, PairingOutcome.expired);
      await outcomeOf(b, PairingOutcome.expired);
      expect(a.paired.devices, isEmpty);
      expect(b.paired.devices, isEmpty);
      expect(a.coordinator.busy, isFalse);
      expect(b.coordinator.busy, isFalse);
    });

    test(
      'shared clock, only the initiator confirmed: both end in expired',
      () async {
        final clock = StackClock();
        final (a, b) = await twoStacks(clockA: clock, clockB: clock);
        await begin(a, b);
        a.coordinator.answerAsInitiator(matches: true);
        await waitUntil(() => b.handledOn(ApiPaths.pairConfirm) >= 1);
        clock.advance(const Duration(seconds: 61));
        await outcomeOf(a, PairingOutcome.expired);
        await outcomeOf(b, PairingOutcome.expired);
        expect(a.paired.devices, isEmpty);
        expect(b.paired.devices, isEmpty);
      },
    );

    test('only the initiator clock moves: the receiver gets cancel with reason expired', () async {
      final (a, b) = await twoStacks(
        clockA: StackClock(),
        clockB: StackClock(),
      );
      await begin(a, b);
      a.clock.advance(const Duration(seconds: 61));
      await outcomeOf(a, PairingOutcome.expired);
      await outcomeOf(b, PairingOutcome.expired);
      expect(b.handledOn(ApiPaths.pairCancel), 1);
      expect(
        b.calls[ApiPaths.pairCancel]!.single.json,
        containsPair('reason', 'expired'),
      );
      expect(b.paired.devices, isEmpty);
    });

    test('59 s are not enough to expire', () async {
      final (a, b) = await twoStacks(
        clockA: StackClock(),
        clockB: StackClock(),
      );
      await begin(a, b);
      a.clock.advance(const Duration(seconds: 59));
      await pause();
      expect(a.view!.phase, PairingPhase.comparing);
      expect(b.handledOn(ApiPaths.pairCancel), 0);
    });

    test(
      'cancel goes out on its own signal while a held wait is in flight (C100)',
      () async {
        final (a, b) = await twoStacks(pollHoldB: const Duration(seconds: 6));
        await begin(a, b);
        await waitUntil(() => b.handledOn(ApiPaths.pairWait) >= 1);
        await pause();
        final stopwatch = Stopwatch()..start();
        a.coordinator.cancelAsInitiator();
        await outcomeOf(b, PairingOutcome.cancelledByPeer);
        expect(stopwatch.elapsed, lessThan(const Duration(seconds: 3)));
        expect(b.handledOn(ApiPaths.pairCancel), 1);
      },
    );

    test('expiry while connecting sends no cancel (no session yet)', () async {
      final a = await stackA();
      final fake = await fakeB();
      fake.handlers[ApiPaths.pairStart] = (_) => fake.hang();
      a.coordinator.tryPair(fakeTarget(a, fake));
      await waitUntil(() => fake.count(ApiPaths.pairStart) == 1);
      a.clock.advance(const Duration(seconds: 60));
      await outcomeOf(a, PairingOutcome.expired);
      await pause();
      expect(fake.count(ApiPaths.pairCancel), 0);
    });

    test(
      'expiry while comparing sends one cancel with reason expired',
      () async {
        final a = await stackA();
        final fake = await fakeB();
        await fakeComparing(a, fake);
        a.clock.advance(const Duration(seconds: 60));
        await outcomeOf(a, PairingOutcome.expired);
        await waitUntil(() => fake.count(ApiPaths.pairCancel) == 1);
        await pause();
        expect(fake.count(ApiPaths.pairCancel), 1);
        expect(
          fake.callsTo(ApiPaths.pairCancel).single.body['reason'],
          'expired',
        );
        expect(
          fake.callsTo(ApiPaths.pairCancel).single.body['session'],
          isA<String>(),
        );
      },
    );
  });

  group('lost receiver (C48, RF-91)', () {
    test(
      'receiver server closes with the code on screen: initiator lost',
      () async {
        final (a, b) = await twoStacks();
        var heldWaits = 0;
        b.wrappers[ApiPaths.pairWait] = (call, inner) async {
          heldWaits++;
          try {
            return await inner(call);
          } finally {
            heldWaits--;
          }
        };
        await begin(a, b);
        final stopwatch = Stopwatch()..start();
        await b.server.close();
        await waitUntil(
          () => a.view?.outcome == PairingOutcome.lost,
          limit: const Duration(seconds: 11),
          reason: 'initiator lost',
        );
        expect(stopwatch.elapsed, lessThan(const Duration(seconds: 11)));
        expect(a.coordinator.busy, isFalse);
        await waitUntil(() => heldWaits == 0, reason: 'no wait held by B');
        b.clock.advance(const Duration(seconds: 11));
        await outcomeOf(b, PairingOutcome.lost);
        expect(a.paired.devices, isEmpty);
      },
    );

    test(
      'receiver that never answers a wait: lost after 10 s, not before',
      () async {
        final a = await stackA();
        final fake = await fakeB();
        fake.handlers[ApiPaths.pairWait] = (_) => fake.hang();
        await fakeComparing(a, fake);
        final stopwatch = Stopwatch()..start();
        await waitUntil(
          () => a.view?.outcome == PairingOutcome.lost,
          limit: const Duration(seconds: 13),
          reason: 'initiator lost',
        );
        expect(stopwatch.elapsed, greaterThan(const Duration(seconds: 9)));
        expect(
          stopwatch.elapsed,
          lessThan(const Duration(milliseconds: 11500)),
        );
        expect(fake.count(ApiPaths.pairWait), 1);
      },
      timeout: const Timeout(Duration(seconds: 40)),
    );
  });

  group('interface down (C49, RF-92)', () {
    test('interfacesChanged without the interface while comparing: '
        'networkChanged at once and one best-effort cancel (Q-3)', () async {
      final (a, b) = await twoStacks();
      await begin(a, b);
      a.coordinator.interfacesChanged({'some-other#10.0.0.1'});
      expect(a.view!.outcome, PairingOutcome.networkChanged);
      expect(a.coordinator.busy, isFalse);
      await outcomeOf(b, PairingOutcome.cancelledByPeer);
      await pause();
      expect(b.handledOn(ApiPaths.pairCancel), 1);
      expect(
        b.calls[ApiPaths.pairCancel]!.single.json,
        containsPair('reason', 'cancelled'),
      );
      expect(b.coordinator.busy, isFalse);
    });

    test(
      'interfacesChanged that keeps the interface changes nothing',
      () async {
        final (a, b) = await twoStacks();
        await begin(a, b);
        a.coordinator.interfacesChanged({a.iface.id, 'other#10.0.0.1'});
        expect(a.view!.phase, PairingPhase.comparing);
        expect(a.coordinator.busy, isTrue);
      },
    );

    test('interfacesChanged while connecting: networkChanged', () async {
      final a = await stackA();
      final fake = await fakeB();
      fake.handlers[ApiPaths.pairStart] = (_) => fake.hang();
      a.coordinator.tryPair(fakeTarget(a, fake));
      a.coordinator.interfacesChanged(const {});
      expect(a.view!.outcome, PairingOutcome.networkChanged);
      await pause();
      expect(fake.count(ApiPaths.pairReveal), 0);
    });

    test(
      'the network does not cancel a save in progress (correction 16)',
      () async {
        final (a, b) = await twoStacks();
        lockExclusively(a.pairedFile);
        await begin(a, b);
        b.coordinator.answerAsReceiver(ReceiverAnswer.matches);
        a.coordinator.answerAsInitiator(matches: true);
        await waitUntil(() => a.storeHasTemporaryFile, reason: 'save started');
        a.coordinator.interfacesChanged(const {});
        expect(a.view!.outcome, isNull);
        await outcomeOf(a, PairingOutcome.notSaved);
        expect(a.paired.isPaired(b.fingerprint), isFalse);
        expect(a.completions, isEmpty);
        expect(b.paired.isPaired(a.fingerprint), isTrue);
      },
    );
  });

  group('saving fails (C51, C94, RF-94)', () {
    test('receiver cannot save: receiver notSaved, initiator cancelledByPeer, nothing saved', () async {
      final (a, b) = await twoStacks();
      await b.breakStore();
      await begin(a, b);
      b.coordinator.answerAsReceiver(ReceiverAnswer.matches);
      a.coordinator.answerAsInitiator(matches: true);
      await outcomeOf(b, PairingOutcome.notSaved);
      await outcomeOf(a, PairingOutcome.cancelledByPeer);
      expect(a.paired.devices, isEmpty);
      expect(b.paired.devices, isEmpty);
      expect(a.completions, isEmpty);
    });

    test('initiator cannot save: initiator notSaved, receiver saved (asymmetry R23)', () async {
      final (a, b) = await twoStacks();
      await a.breakStore();
      await begin(a, b);
      b.coordinator.answerAsReceiver(ReceiverAnswer.matches);
      a.coordinator.answerAsInitiator(matches: true);
      await outcomeOf(a, PairingOutcome.notSaved);
      expect(a.paired.devices, isEmpty);
      expect(a.completions, isEmpty);
      expect(a.coordinator.busy, isFalse);
      await waitUntil(() => a.events.isNotEmpty);
      expect((a.events.single as PairingNotSaved).fingerprint, b.fingerprint);
      await waitUntil(() => b.paired.isPaired(a.fingerprint));
      expectCleanLogs(a);
    });

    test('initiator save refused because the receiver was ignored meanwhile: '
        'failed and a PairingFailed event (Q-9)', () async {
      final (a, b) = await twoStacks();
      await begin(a, b);
      await a.ignored.ignore(b.fingerprint, name: 'Stack B');
      b.coordinator.answerAsReceiver(ReceiverAnswer.matches);
      a.coordinator.answerAsInitiator(matches: true);
      await outcomeOf(a, PairingOutcome.failed);
      expect(a.paired.isPaired(b.fingerprint), isFalse);
      expect(a.coordinator.busy, isFalse);
      await waitUntil(() => a.events.isNotEmpty);
      expect((a.events.single as PairingFailed).fingerprint, b.fingerprint);
    });

    test(
      'a not saved result of the initiator survives a new notice from '
      'another device: the view is replaced, the event stays (Q-9)',
      () async {
        final (a, b) = await twoStacks();
        await a.breakStore();
        await begin(a, b);
        b.coordinator.answerAsReceiver(ReceiverAnswer.matches);
        a.coordinator.answerAsInitiator(matches: true);
        await outcomeOf(a, PairingOutcome.notSaved);
        final c = await stackC();
        expect(c.coordinator.tryPair(c.targetOf(a)), PairStart.started);
        await waitUntil(
          () =>
              a.view?.phase == PairingPhase.comparing &&
              a.view?.role == PairingRole.receiver,
          reason: 'new notice on A',
        );
        expect(a.view!.peerFingerprint, c.fingerprint);
        expect(
          a.events.whereType<PairingNotSaved>().single.fingerprint,
          b.fingerprint,
        );
        c.coordinator.cancelAsInitiator();
      },
    );

    test('receiver save that does not finish in time: notSaved and free, initiator cancelledByPeer', () async {
      final (a, b) = await twoStacks(saveTimeoutB: Duration.zero);
      await begin(a, b);
      b.coordinator.answerAsReceiver(ReceiverAnswer.matches);
      a.coordinator.answerAsInitiator(matches: true);
      await outcomeOf(b, PairingOutcome.notSaved);
      expect(b.coordinator.busy, isFalse);
      await outcomeOf(a, PairingOutcome.cancelledByPeer);
      expect(a.paired.devices, isEmpty);
    });
  });

  group('confirm retries (C101, RF-87)', () {
    Future<void> retriedAfterFirst(ApiReply Function() first) async {
      final (a, b) = await twoStacks();
      b.wrappers[ApiPaths.pairConfirm] = (call, inner) async {
        if (b.handledOn(ApiPaths.pairConfirm) == 1) return first();
        return inner(call);
      };
      await begin(a, b);
      b.coordinator.answerAsReceiver(ReceiverAnswer.matches);
      await waitUntil(() => b.view?.phase == PairingPhase.waitingPeer);
      a.coordinator.answerAsInitiator(matches: true);
      await waitUntil(
        () =>
            a.paired.isPaired(b.fingerprint) &&
            b.paired.isPaired(a.fingerprint),
        reason: 'both paired',
      );
      final confirms = b.calls[ApiPaths.pairConfirm]!;
      expect(confirms, hasLength(2));
      expect(
        confirms[1].at.difference(confirms[0].at),
        greaterThanOrEqualTo(const Duration(milliseconds: 900)),
      );
    }

    test('a 500 is resent after 1 s and both end paired', () async {
      await retriedAfterFirst(() => throw StateError('boom'));
    });

    test('a 429 is resent after 1 s and both end paired', () async {
      await retriedAfterFirst(
        () => ApiReply(429, const {'error': 'too_many_requests'}),
      );
    });

    test('no answer and 503 are resent each second until paired', () async {
      final a = await stackA();
      final fake = await fakeB();
      fake.handlers[ApiPaths.pairConfirm] = (call) => switch (call.index) {
        1 => const FakeAnswer.drop(),
        2 => const FakeAnswer(503, {'error': 'unavailable'}),
        _ => FakeAnswer.state('paired'),
      };
      await fakeComparing(a, fake);
      a.coordinator.answerAsInitiator(matches: true);
      await waitUntil(
        () => a.paired.isPaired(fake.fingerprint),
        reason: 'initiator paired',
      );
      final confirms = fake.callsTo(ApiPaths.pairConfirm);
      expect(confirms, hasLength(3));
      for (var i = 1; i < confirms.length; i++) {
        expect(
          confirms[i].at.difference(confirms[i - 1].at),
          greaterThanOrEqualTo(const Duration(milliseconds: 900)),
        );
      }
      expect(a.completions.single.isNew, isTrue);
      expect(a.view, isNull);
      expect(fake.count(ApiPaths.pairCancel), 0);
    });

    test('retries stop when the session ends', () async {
      final a = await stackA();
      final fake = await fakeB();
      fake.handlers[ApiPaths.pairConfirm] = (_) =>
          const FakeAnswer(500, {'error': 'internal'});
      var ended = false;
      fake.handlers[ApiPaths.pairWait] = (_) async {
        await Future<void>.delayed(const Duration(milliseconds: 100));
        return ended
            ? FakeAnswer.state('cancelled')
            : FakeAnswer.state('pending');
      };
      await fakeComparing(a, fake);
      a.coordinator.answerAsInitiator(matches: true);
      await waitUntil(
        () => fake.count(ApiPaths.pairConfirm) >= 2,
        reason: 'confirm resent',
      );
      ended = true;
      await outcomeOf(a, PairingOutcome.cancelledByPeer);
      final confirms = fake.count(ApiPaths.pairConfirm);
      expect(confirms, greaterThanOrEqualTo(2));
      await pause(const Duration(milliseconds: 1500));
      expect(fake.count(ApiPaths.pairConfirm), confirms);
    });

    Future<void> failsWithOneCancel(int status) async {
      final (a, b) = await twoStacks();
      b.wrappers[ApiPaths.pairConfirm] = (call, inner) async =>
          ApiReply(status, const {'error': 'bad_request'});
      await begin(a, b);
      b.coordinator.answerAsReceiver(ReceiverAnswer.matches);
      await waitUntil(() => b.view?.phase == PairingPhase.waitingPeer);
      a.coordinator.answerAsInitiator(matches: true);
      await outcomeOf(a, PairingOutcome.failed);
      await outcomeOf(b, PairingOutcome.cancelledByPeer);
      await pause(const Duration(milliseconds: 1500));
      expect(b.handledOn(ApiPaths.pairConfirm), 1);
      expect(b.handledOn(ApiPaths.pairCancel), 1);
      expect(a.paired.devices, isEmpty);
      expect(b.paired.devices, isEmpty);
    }

    test(
      'a 400 ends in failed with a single cancel and nothing saved',
      () async {
        await failsWithOneCancel(400);
      },
    );

    test('another 4xx (403) ends in failed with a single cancel', () async {
      await failsWithOneCancel(403);
    });

    test('a 404 ends in cancelledByPeer', () async {
      final (a, b) = await twoStacks();
      b.wrappers[ApiPaths.pairConfirm] = (call, inner) async =>
          ApiReply(404, const {'error': 'not_found'});
      await begin(a, b);
      a.coordinator.answerAsInitiator(matches: true);
      await outcomeOf(a, PairingOutcome.cancelledByPeer);
      expect(a.paired.devices, isEmpty);
    });

    Future<void> fakeConfirmFails(FakeAnswer answer) async {
      final a = await stackA();
      final fake = await fakeB();
      fake.handlers[ApiPaths.pairConfirm] = (_) => answer;
      await fakeComparing(a, fake);
      a.coordinator.answerAsInitiator(matches: true);
      await outcomeOf(a, PairingOutcome.failed);
      await pause();
      expect(fake.count(ApiPaths.pairConfirm), 1);
      expect(fake.count(ApiPaths.pairCancel), 1);
      expect(a.paired.devices, isEmpty);
      expect(a.completions, isEmpty);
    }

    test(
      'a 200 with an unreadable state is treated as cancel and failed',
      () async {
        await fakeConfirmFails(const FakeAnswer(200, {'state': 'weird'}));
      },
    );

    test('a 2xx other than 200 is treated as cancel and failed', () async {
      await fakeConfirmFails(const FakeAnswer(201, {'state': 'paired'}));
    });

    test('confirm answered cancelled or expired ends the pairing', () async {
      final a = await stackA();
      final fake = await fakeB();
      fake.handlers[ApiPaths.pairConfirm] = (_) => FakeAnswer.state('expired');
      await fakeComparing(a, fake);
      a.coordinator.answerAsInitiator(matches: true);
      await outcomeOf(a, PairingOutcome.expired);
      expect(a.paired.devices, isEmpty);
    });
  });

  group('the initiator only saves after its own confirmation (RF-88)', () {
    test('a receiver that says paired before the user confirmed: cancel and failed', () async {
      final a = await stackA();
      final fake = await fakeB();
      fake.handlers[ApiPaths.pairWait] = (_) => FakeAnswer.state('paired');
      a.coordinator.tryPair(fakeTarget(a, fake));
      await outcomeOf(a, PairingOutcome.failed);
      await waitUntil(() => fake.count(ApiPaths.pairCancel) == 1);
      await pause();
      expect(fake.count(ApiPaths.pairCancel), 1);
      expect(fake.count(ApiPaths.pairConfirm), 0);
      expect(a.paired.devices, isEmpty);
      expect(a.completions, isEmpty);
    });
  });

  group('answers to start, reveal and wait', () {
    Future<void> startEndsIn(FakeAnswer answer, PairingOutcome outcome) async {
      final a = await stackA();
      final fake = await fakeB();
      fake.handlers[ApiPaths.pairStart] = (_) => answer;
      expect(a.coordinator.tryPair(fakeTarget(a, fake)), PairStart.started);
      await outcomeOf(a, outcome);
      expect(a.view!.phase, PairingPhase.finished);
      expect(a.view!.code, isNull);
      expect(a.coordinator.busy, isFalse);
      await pause();
      expect(fake.count(ApiPaths.pairReveal), 0);
      expect(fake.count(ApiPaths.pairCancel), 0);
      expect(a.events, isEmpty);
      expectCleanLogs(a);
    }

    test('start without answer: failed', () async {
      await startEndsIn(const FakeAnswer.drop(), PairingOutcome.failed);
    });

    test('start 403: rejected (RF-75)', () async {
      await startEndsIn(
        const FakeAnswer(403, {'error': 'rejected'}),
        PairingOutcome.rejected,
      );
    });

    test('start 409: busy (RF-76)', () async {
      await startEndsIn(
        const FakeAnswer(409, {'error': 'busy'}),
        PairingOutcome.busy,
      );
    });

    test('start 500: failed', () async {
      await startEndsIn(
        const FakeAnswer(500, {'error': 'internal'}),
        PairingOutcome.failed,
      );
    });

    test('start 200 with an unreadable body: failed', () async {
      await startEndsIn(
        const FakeAnswer(200, {'session': 'nope'}),
        PairingOutcome.failed,
      );
    });

    test('start 200 that is not JSON: failed', () async {
      await startEndsIn(
        const FakeAnswer.raw(200, 'not json'),
        PairingOutcome.failed,
      );
    });

    test(
      'start sends a correct presentation signed for this receiver',
      () async {
        final a = await stackA();
        final fake = await fakeB();
        fake.handlers[ApiPaths.pairStart] = (_) =>
            const FakeAnswer(403, {'error': 'rejected'});
        a.coordinator.tryPair(fakeTarget(a, fake));
        await outcomeOf(a, PairingOutcome.rejected);
        final body = fake.callsTo(ApiPaths.pairStart).single.body;
        expect(body.keys.toSet(), {
          'protocol',
          'certificate',
          'name',
          'deviceType',
          'commitment',
          'proof',
        });
        expect(body['certificate'], ia.certificate.pem);
        expect(body['name'], 'Stack A');
        expect(body['deviceType'], 'desktop');
        expect(
          fake.callsTo(ApiPaths.pairStart).single.clientFingerprint,
          isNull,
        );
      },
    );

    Future<void> revealEndsIn(
      FakeAnswer answer,
      PairingOutcome outcome, {
      required int cancels,
    }) async {
      final a = await stackA();
      final fake = await fakeB();
      fake.handlers[ApiPaths.pairReveal] = (_) => answer;
      a.coordinator.tryPair(fakeTarget(a, fake));
      await outcomeOf(a, outcome);
      expect(a.view!.code, isNull);
      if (cancels > 0) {
        await waitUntil(() => fake.count(ApiPaths.pairCancel) == cancels);
      }
      await pause();
      expect(fake.count(ApiPaths.pairCancel), cancels);
      for (final cancel in fake.callsTo(ApiPaths.pairCancel)) {
        expect(cancel.body['session'], toHex(fake.session));
      }
      expect(fake.count(ApiPaths.pairWait), 0);
      expect(a.paired.devices, isEmpty);
      expect(a.events, isEmpty);
    }

    test('reveal without answer: lost and one best-effort cancel with the '
        'session (Q-3)', () async {
      await revealEndsIn(
        const FakeAnswer.drop(),
        PairingOutcome.lost,
        cancels: 1,
      );
    });

    test('reveal 403: rejected', () async {
      await revealEndsIn(
        const FakeAnswer(403, {'error': 'rejected'}),
        PairingOutcome.rejected,
        cancels: 0,
      );
    });

    test('reveal 404: rejected', () async {
      await revealEndsIn(
        const FakeAnswer(404, {'error': 'not_found'}),
        PairingOutcome.rejected,
        cancels: 0,
      );
    });

    test('reveal 200 with an unreadable body: one cancel and failed', () async {
      await revealEndsIn(
        const FakeAnswer(200, {'nonce': 'short'}),
        PairingOutcome.failed,
        cancels: 1,
      );
    });

    test('reveal with a number that does not match the commitment: one cancel and failed (SEC-13)', () async {
      final other = List<int>.filled(32, 7);
      await revealEndsIn(
        FakeAnswer(200, {
          'nonce': other.map((b) => b.toRadixString(16).padLeft(2, '0')).join(),
        }),
        PairingOutcome.failed,
        cancels: 1,
      );
    });

    Future<void> waitEndsIn(
      FakeAnswer answer,
      PairingOutcome outcome, {
      int cancels = 0,
    }) async {
      final a = await stackA();
      final fake = await fakeB();
      fake.handlers[ApiPaths.pairWait] = (_) async {
        await Future<void>.delayed(const Duration(milliseconds: 300));
        return answer;
      };
      await fakeComparing(a, fake);
      await outcomeOf(a, outcome);
      expect(a.coordinator.busy, isFalse);
      expect(a.paired.devices, isEmpty);
      if (cancels > 0) {
        await waitUntil(() => fake.count(ApiPaths.pairCancel) == cancels);
      }
      await pause();
      expect(fake.count(ApiPaths.pairCancel), cancels);
      for (final cancel in fake.callsTo(ApiPaths.pairCancel)) {
        expect(cancel.body['session'], toHex(fake.session));
        expect(cancel.body['reason'], 'cancelled');
      }
      expect(a.events, isEmpty);
    }

    test('wait 404: cancelledByPeer', () async {
      await waitEndsIn(
        const FakeAnswer(404, {'error': 'not_found'}),
        PairingOutcome.cancelledByPeer,
      );
    });

    test('wait cancelled: cancelledByPeer', () async {
      await waitEndsIn(
        FakeAnswer.state('cancelled'),
        PairingOutcome.cancelledByPeer,
      );
    });

    test('wait expired: expired', () async {
      await waitEndsIn(FakeAnswer.state('expired'), PairingOutcome.expired);
    });

    test('wait 500: lost and one best-effort cancel (Q-3)', () async {
      await waitEndsIn(
        const FakeAnswer(500, {'error': 'internal'}),
        PairingOutcome.lost,
        cancels: 1,
      );
    });

    test(
      'wait without answer: lost and one best-effort cancel (Q-3)',
      () async {
        await waitEndsIn(
          const FakeAnswer.drop(),
          PairingOutcome.lost,
          cancels: 1,
        );
      },
    );

    test('wait with an unreadable state: lost and one best-effort cancel '
        '(Q-3)', () async {
      await waitEndsIn(
        const FakeAnswer(200, {'state': 'maybe'}),
        PairingOutcome.lost,
        cancels: 1,
      );
    });

    test('wait pending keeps polling', () async {
      final a = await stackA();
      final fake = await fakeB();
      await fakeComparing(a, fake);
      await waitUntil(() => fake.count(ApiPaths.pairWait) >= 4);
      expect(a.view!.phase, PairingPhase.comparing);
    });
  });

  group('receiver identity (RF-82, RF-122, C50, RF-93)', () {
    test(
      'a server with another fingerprint: failed and nothing reaches it',
      () async {
        final (a, b) = await twoStacks();
        a.coordinator.tryPair(a.targetOf(b, fingerprint: ix.fingerprint));
        await outcomeOf(a, PairingOutcome.failed);
        await pause();
        expect(b.handledTotal, 0);
        expect(b.view, isNull);
        expect(b.coordinator.busy, isFalse);
        expectCleanLogs(a);
      },
    );

    test('a receiver certificate with the right fingerprint that the parser rejects: failed, nothing sent', () async {
      final oversized = OversizedCertificate();
      expect(oversized.pem.length, greaterThan(4096));
      expect(parseCertificate(oversized.der).commonName, isNotEmpty);
      expect(PeerCertificate.tryParse(oversized.pem), isNull);
      expect(PeerCertificate.fromDer(oversized.der), isNull);
      final a = await stackA();
      final fake = await FakeReceiver.start(
        fingerprint: oversized.fingerprint,
        context: oversized.serverContext,
      );
      a.coordinator.tryPair(fakeTarget(a, fake));
      await outcomeOf(a, PairingOutcome.failed);
      await pause();
      expect(fake.calls, isEmpty);
    });

    test('a paired device with the subject of the receiver and another key '
        'cannot be stored, so the pairing with the real receiver goes on '
        '(RF-93)', () async {
      final (a, b) = await twoStacks();
      final impostor = impostorWithNameOf(ib, DateTime.utc(2026, 10, 20));
      expect(PeerCertificate.tryParse(impostor.certificatePem), isNull);
      await expectLater(a.paired.replaceAll([impostor]), throwsArgumentError);
      expect(a.paired.devices, isEmpty);

      await begin(a, b);

      expect(a.view!.peerFingerprint, b.fingerprint);
      a.coordinator.cancelAsInitiator();
      await outcomeOf(b, PairingOutcome.cancelledByPeer);
    });
  });

  group('one pairing at a time (C55, C98, C99, RF-70)', () {
    test(
      'tryPair while the initiator is busy: busy and the view does not change',
      () async {
        final (a, b) = await twoStacks();
        final c = await stackC();
        await begin(a, b);
        final before = a.view;
        final emitted = a.views.length;
        expect(a.coordinator.tryPair(a.targetOf(c)), PairStart.busy);
        expect(a.view, before);
        await pause();
        expect(a.views.length, emitted);
        expect(c.handledTotal, 0);
      },
    );

    test(
      'tryPair while this device is a receiver: busy and nothing sent',
      () async {
        final (a, b) = await twoStacks();
        final c = await stackC();
        await begin(c, a);
        final before = a.view;
        expect(before!.role, PairingRole.receiver);
        expect(a.coordinator.tryPair(a.targetOf(b)), PairStart.busy);
        expect(a.view, before);
        await pause();
        expect(b.handledTotal, 0);
      },
    );

    test('two tryPair in the same turn: started then busy', () async {
      final (a, b) = await twoStacks();
      final c = await stackC();
      expect(a.coordinator.tryPair(a.targetOf(b)), PairStart.started);
      expect(a.coordinator.tryPair(a.targetOf(c)), PairStart.busy);
      expect(a.view!.peerFingerprint, b.fingerprint);
      await bothComparing(a, b);
      expect(c.handledTotal, 0);
    });

    test('a reserved initiator answers 409 to an incoming start', () async {
      final a = await stackA();
      final c = await stackC();
      final fake = await fakeB();
      fake.handlers[ApiPaths.pairStart] = (_) => fake.hang();
      expect(a.coordinator.tryPair(fakeTarget(a, fake)), PairStart.started);
      expect(c.coordinator.tryPair(c.targetOf(a)), PairStart.started);
      await outcomeOf(c, PairingOutcome.busy);
      expect(a.handledOn(ApiPaths.pairStart), 1);
      expect(a.view!.role, PairingRole.initiator);
      expect(a.view!.phase, PairingPhase.connecting);
    });

    test(
      'pressing at the same time on both sides: both busy, nothing saved',
      () async {
        final (a, b) = await twoStacks();
        expect(a.coordinator.tryPair(a.targetOf(b)), PairStart.started);
        expect(b.coordinator.tryPair(b.targetOf(a)), PairStart.started);
        await outcomeOf(a, PairingOutcome.busy);
        await outcomeOf(b, PairingOutcome.busy);
        expect(a.paired.devices, isEmpty);
        expect(b.paired.devices, isEmpty);
      },
    );

    test('an open finished view is replaced by tryPair', () async {
      final a = await stackA();
      final fake = await fakeB();
      fake.handlers[ApiPaths.pairStart] = (call) => call.index == 1
          ? const FakeAnswer(403, {'error': 'rejected'})
          : fake.hang();
      a.coordinator.tryPair(fakeTarget(a, fake));
      await outcomeOf(a, PairingOutcome.rejected);
      expect(a.coordinator.busy, isFalse);
      expect(a.coordinator.tryPair(fakeTarget(a, fake)), PairStart.started);
      expect(a.view!.phase, PairingPhase.connecting);
      expect(a.view!.outcome, isNull);
    });

    test('an open receiver result is replaced by tryPair', () async {
      final (a, b) = await twoStacks();
      final c = await stackC();
      await begin(c, a);
      c.coordinator.cancelAsInitiator();
      await outcomeOf(a, PairingOutcome.cancelledByPeer);
      expect(a.view!.role, PairingRole.receiver);
      expect(a.coordinator.tryPair(a.targetOf(b)), PairStart.started);
      expect(a.view!.role, PairingRole.initiator);
      expect(a.view!.phase, PairingPhase.connecting);
      await bothComparing(a, b);
    });

    test(
      'a receiver pairing in course takes the view over an initiator result',
      () async {
        final a = await stackA();
        final c = await stackC();
        final fake = await fakeB();
        fake.handlers[ApiPaths.pairStart] = (_) =>
            const FakeAnswer(403, {'error': 'rejected'});
        a.coordinator.tryPair(fakeTarget(a, fake));
        await outcomeOf(a, PairingOutcome.rejected);
        await begin(c, a);
        expect(a.view!.role, PairingRole.receiver);
        expect(a.view!.phase, PairingPhase.comparing);
        c.coordinator.cancelAsInitiator();
        await outcomeOf(a, PairingOutcome.cancelledByPeer);
        expect(a.view!.role, PairingRole.receiver);
        a.coordinator.dismissOutcome();
        expect(a.view, isNull);
      },
    );
  });

  group('close (no timers, no requests left)', () {
    test('close while comparing sends the cancel within 1 s', () async {
      final (a, b) = await twoStacks(pollHoldB: const Duration(seconds: 6));
      await begin(a, b);
      final stopwatch = Stopwatch()..start();
      await a.coordinator.close();
      expect(stopwatch.elapsed, lessThan(const Duration(milliseconds: 1500)));
      expect(b.handledOn(ApiPaths.pairCancel), 1);
      await outcomeOf(b, PairingOutcome.cancelledByPeer);
      expect(a.view, isNull);
      expect(a.coordinator.busy, isFalse);
    });

    test('close waits for a hanging cancel at most about 1 s', () async {
      final a = await stackA();
      final fake = await fakeB();
      fake.handlers[ApiPaths.pairCancel] = (_) => fake.hang();
      await fakeComparing(a, fake);
      final stopwatch = Stopwatch()..start();
      await a.coordinator.close();
      expect(stopwatch.elapsed, lessThan(const Duration(seconds: 2)));
      expect(fake.count(ApiPaths.pairCancel), 1);
    });

    test(
      'close leaves no timers from the initiator, the link or the transport',
      () async {
        final timers = ZoneTimers();
        await runZoned(() async {
          final a = await stackA();
          final fake = await fakeB();
          final silent = await SilentListener.start(otherLoopback);
          fake.handlers[ApiPaths.pairConfirm] = (_) =>
              const FakeAnswer(500, {'error': 'internal'});
          fake.handlers[ApiPaths.pairWait] = (_) => const FakeAnswer.hold();
          await fakeComparing(a, fake);
          a.coordinator.answerAsInitiator(matches: true);
          await waitUntil(() => fake.count(ApiPaths.pairConfirm) >= 1);
          await pause(const Duration(milliseconds: 200));
          final check = a.coordinator.checkPeer(
            a.targetAt(otherLoopback, silent.port, fingerprint: ib.fingerprint),
          );
          await waitUntil(() => silent.accepted.isNotEmpty);
          expect(timers.activeBy('raw_https.dart'), greaterThan(0));
          expect(timers.activeBy('initiator.dart'), greaterThan(0));
          final stopwatch = Stopwatch()..start();
          await a.coordinator.close();
          expect(await check, PeerStatus.unknown);
          expect(
            stopwatch.elapsed,
            lessThan(const Duration(milliseconds: 1500)),
          );
          await pause(const Duration(milliseconds: 100));
          expect(timers.activeBy('initiator.dart'), 0);
          expect(timers.activeBy('peer_link.dart'), 0);
          expect(timers.activeBy('raw_https.dart'), 0);
          expect(timers.activeBy('pairing_flow.dart'), 0);
          expect(fake.heldOpened, greaterThan(0));
          await waitUntil(
            () =>
                fake.heldClosed == fake.heldOpened &&
                silent.closedByPeer == silent.accepted.length,
            reason: 'no open requests',
          );
        }, zoneSpecification: timers.specification);
        expect(timers.createdBy('pairing_flow.dart'), greaterThan(0));
      },
    );

    test('after close nothing starts and close can be called again', () async {
      final (a, b) = await twoStacks();
      await a.coordinator.close();
      await a.coordinator.close();
      expect(a.coordinator.tryPair(a.targetOf(b)), PairStart.busy);
      expect(await a.coordinator.checkPeer(a.targetOf(b)), PeerStatus.unknown);
      expect(await a.coordinator.notifyUnpaired(a.targetOf(b)), isFalse);
      await pause();
      expect(b.handledTotal, 0);
    });
  });

  group('hard deadline and pace of the waits (Q-2, V2, RF-90)', () {
    test(
      'a receiver that says pending forever: still waiting at 69.999 s, '
      'expired at 70 s with one cancel, and then nothing more is sent',
      () async {
        final a = await stackA();
        final fake = await fakeB();
        fake.handlers[ApiPaths.pairConfirm] = (_) =>
            const FakeAnswer(503, {'error': 'unavailable'});
        fake.handlers[ApiPaths.pairWait] = (_) => FakeAnswer.state('pending');
        await fakeComparing(a, fake);
        a.coordinator.answerAsInitiator(matches: true);
        expect(a.view!.phase, PairingPhase.waitingPeer);
        await waitUntil(() => fake.count(ApiPaths.pairConfirm) >= 1);

        a.clock.advance(const Duration(seconds: 69, milliseconds: 999));
        await pause();
        expect(a.view!.phase, PairingPhase.waitingPeer);
        expect(a.coordinator.busy, isTrue);
        a.coordinator.cancelAsInitiator();
        expect(a.view!.phase, PairingPhase.waitingPeer);
        expect(fake.count(ApiPaths.pairCancel), 0);

        a.clock.advance(const Duration(milliseconds: 1));
        await outcomeOf(a, PairingOutcome.expired);
        expect(a.coordinator.busy, isFalse);
        await waitUntil(() => fake.count(ApiPaths.pairCancel) == 1);
        final cancel = fake.callsTo(ApiPaths.pairCancel).single.body;
        expect(cancel['reason'], 'expired');
        expect(cancel['session'], toHex(fake.session));
        final confirms = fake.count(ApiPaths.pairConfirm);
        final waits = fake.count(ApiPaths.pairWait);
        await pause(const Duration(milliseconds: 1500));
        expect(fake.count(ApiPaths.pairConfirm), confirms);
        expect(fake.count(ApiPaths.pairWait), waits);
        expect(fake.count(ApiPaths.pairCancel), 1);
        expect(a.paired.devices, isEmpty);
        expect(a.events, isEmpty);
      },
    );

    test('once expired the device is free again: another one can pair with '
        'it as receiver', () async {
      final a = await stackA();
      final fake = await fakeB();
      fake.handlers[ApiPaths.pairConfirm] = (_) =>
          const FakeAnswer(503, {'error': 'unavailable'});
      fake.handlers[ApiPaths.pairWait] = (_) => FakeAnswer.state('pending');
      await fakeComparing(a, fake);
      a.coordinator.answerAsInitiator(matches: true);
      a.clock.advance(const Duration(seconds: 70));
      await outcomeOf(a, PairingOutcome.expired);
      final c = await stackC();

      expect(c.coordinator.tryPair(c.targetOf(a)), PairStart.started);

      await waitUntil(
        () =>
            c.view?.phase == PairingPhase.comparing &&
            a.view?.role == PairingRole.receiver &&
            a.view?.phase == PairingPhase.comparing,
        reason: 'C and A comparing',
      );
      c.coordinator.cancelAsInitiator();
    });

    test('control: in comparing the deadline is still 60 s', () async {
      final a = await stackA();
      final fake = await fakeB();
      await fakeComparing(a, fake);
      a.clock.advance(const Duration(seconds: 59, milliseconds: 999));
      await pause();
      expect(a.view!.phase, PairingPhase.comparing);
      a.clock.advance(const Duration(milliseconds: 1));
      await outcomeOf(a, PairingOutcome.expired);
    });

    test('a pending that comes back at once is followed by the next wait only '
        'after the retry interval', () async {
      const retry = Duration(milliseconds: 400);
      final a = await PairingStack.start(
        identity: ia,
        address: loopback,
        name: 'Stack A',
        confirmRetry: retry,
      );
      final fake = await fakeB();
      fake.handlers[ApiPaths.pairWait] = (_) => FakeAnswer.state('pending');
      await fakeComparing(a, fake);

      await waitUntil(
        () => fake.count(ApiPaths.pairWait) >= 4,
        reason: 'four waits',
      );

      final waits = fake.callsTo(ApiPaths.pairWait);
      for (var i = 1; i < waits.length; i++) {
        expect(
          waits[i].at.difference(waits[i - 1].at),
          greaterThanOrEqualTo(retry - const Duration(milliseconds: 30)),
          reason: 'gap before wait ${i + 1}',
        );
      }
      expect(a.view!.phase, PairingPhase.comparing);
    });

    test('the pause is measured with the injected clock: a pending that took '
        'the whole interval is followed by the next wait at once', () async {
      const retry = Duration(seconds: 5);
      final a = await PairingStack.start(
        identity: ia,
        address: loopback,
        name: 'Stack A',
        confirmRetry: retry,
      );
      final fake = await fakeB();
      fake.handlers[ApiPaths.pairWait] = (_) {
        a.clock.advance(retry);
        return FakeAnswer.state('pending');
      };
      await fakeComparing(a, fake);

      await waitUntil(
        () => fake.count(ApiPaths.pairWait) >= 3,
        reason: 'three waits',
      );

      final waits = fake.callsTo(ApiPaths.pairWait);
      for (var i = 1; i < 3; i++) {
        expect(
          waits[i].at.difference(waits[i - 1].at),
          lessThan(const Duration(seconds: 4)),
        );
      }
    });

    test('control: with a clock that does not move, the same interval holds '
        'the second wait back', () async {
      const retry = Duration(seconds: 5);
      final a = await PairingStack.start(
        identity: ia,
        address: loopback,
        name: 'Stack A',
        confirmRetry: retry,
      );
      final fake = await fakeB();
      fake.handlers[ApiPaths.pairWait] = (_) => FakeAnswer.state('pending');
      await fakeComparing(a, fake);
      await waitUntil(() => fake.count(ApiPaths.pairWait) >= 1);

      await pause(const Duration(seconds: 1));

      expect(fake.count(ApiPaths.pairWait), 1);
    });
  });

  group('the initiator tells the receiver when it gives up (Q-3)', () {
    for (final trigger in ['networkChanged', 'lost']) {
      test('after "matches", $trigger sends one cancel and the receiver does '
          'not save even if its user confirms later', () async {
        final (a, b) = await twoStacks();
        await begin(a, b);
        a.coordinator.answerAsInitiator(matches: true);
        await waitUntil(
          () => b.handledOn(ApiPaths.pairConfirm) >= 1,
          reason: 'confirm reached B',
        );
        if (trigger == 'networkChanged') {
          a.coordinator.interfacesChanged(const {});
          expect(a.view!.outcome, PairingOutcome.networkChanged);
        } else {
          b.wrappers[ApiPaths.pairWait] = (call, inner) async =>
              const ApiReply(200, {'state': 'maybe'});
          await outcomeOf(a, PairingOutcome.lost);
        }
        expect(a.coordinator.busy, isFalse);

        await waitUntil(
          () => b.handledOn(ApiPaths.pairCancel) == 1,
          reason: 'cancel reached B',
        );
        await outcomeOf(b, PairingOutcome.cancelledByPeer);
        b.coordinator.answerAsReceiver(ReceiverAnswer.matches);
        await pause();

        expect(b.view!.outcome, PairingOutcome.cancelledByPeer);
        expect(b.paired.isPaired(a.fingerprint), isFalse);
        expect(a.paired.isPaired(b.fingerprint), isFalse);
        expect(await b.reloadPaired(), isEmpty);
        expect(b.completions, isEmpty);
        expect(a.completions, isEmpty);
        expect(b.handledOn(ApiPaths.pairCancel), 1);
      });
    }

    test('the view changes at once and the cancel gives up after about '
        '1 s when the receiver keeps it hanging', () async {
      final a = await stackA();
      final fake = await fakeB();
      fake.handlers[ApiPaths.pairWait] = (_) => const FakeAnswer.drop();
      fake.handlers[ApiPaths.pairCancel] = (_) => const FakeAnswer.hold();
      expect(a.coordinator.tryPair(fakeTarget(a, fake)), PairStart.started);
      await outcomeOf(a, PairingOutcome.lost);
      expect(a.coordinator.busy, isFalse);

      await waitUntil(() => fake.heldOpened == 1, reason: 'cancel held');
      expect(a.view!.outcome, PairingOutcome.lost);
      await waitUntil(
        () => fake.heldClosed == 1,
        limit: const Duration(seconds: 6),
        reason: 'cancel given up by the initiator',
      );
      expect(fake.count(ApiPaths.pairCancel), 1);
    });
  });

  group('cancel while pair/start is on its way (Q-6)', () {
    test('the receiver gets the cancel as soon as the start returns and is '
        'free for a third device without waiting for its 10 s', () async {
      final (a, b) = await twoStacks();
      final gate = Completer<void>();
      b.wrappers[ApiPaths.pairStart] = (call, inner) async {
        final reply = await inner(call);
        await gate.future;
        return reply;
      };
      expect(a.coordinator.tryPair(a.targetOf(b)), PairStart.started);
      await waitUntil(() => b.coordinator.busy, reason: 'B reserved');

      a.coordinator.cancelAsInitiator();
      expect(a.view, isNull);
      expect(a.coordinator.busy, isFalse);
      gate.complete();

      await waitUntil(
        () => b.handledOn(ApiPaths.pairCancel) == 1,
        reason: 'cancel reached B',
      );
      await waitUntil(() => !b.coordinator.busy, reason: 'B free');
      expect(b.view, isNull);
      expect(b.handledOn(ApiPaths.pairReveal), 0);
      expect(
        b.calls[ApiPaths.pairCancel]!.single.json,
        containsPair('reason', 'cancelled'),
      );
      final c = await stackC();
      expect(c.coordinator.tryPair(c.targetOf(b)), PairStart.started);
      await waitUntil(
        () =>
            c.view?.phase == PairingPhase.comparing &&
            b.view?.phase == PairingPhase.comparing,
        reason: 'C and B comparing',
      );
      expect(b.view!.peerFingerprint, c.fingerprint);
      c.coordinator.cancelAsInitiator();
    });

    test('a start that comes back without a session after the cancel sends '
        'nothing more', () async {
      final a = await stackA();
      final fake = await fakeB();
      final gate = Completer<void>();
      fake.handlers[ApiPaths.pairStart] = (_) async {
        await gate.future;
        return const FakeAnswer(409, {'error': 'busy'});
      };
      a.coordinator.tryPair(fakeTarget(a, fake));
      await waitUntil(() => fake.count(ApiPaths.pairStart) == 1);
      a.coordinator.cancelAsInitiator();
      gate.complete();
      await pause(const Duration(milliseconds: 500));
      expect(fake.calls.map((c) => c.path), [ApiPaths.pairStart]);
      expect(a.view, isNull);
    });

    test('the expiry while the start is on its way also sends the deferred '
        'cancel, with reason expired', () async {
      final a = await stackA();
      final fake = await fakeB();
      final gate = Completer<void>();
      fake.handlers[ApiPaths.pairStart] = (_) async {
        await gate.future;
        return FakeAnswer(200, {
          'session': toHex(fake.session),
          'commitment': toHex(fake.cr),
        });
      };
      a.coordinator.tryPair(fakeTarget(a, fake));
      await waitUntil(() => fake.count(ApiPaths.pairStart) == 1);
      a.clock.advance(const Duration(seconds: 60));
      await outcomeOf(a, PairingOutcome.expired);
      gate.complete();
      await waitUntil(() => fake.count(ApiPaths.pairCancel) == 1);
      final cancel = fake.callsTo(ApiPaths.pairCancel).single.body;
      expect(cancel['reason'], 'expired');
      expect(cancel['session'], toHex(fake.session));
      expect(fake.count(ApiPaths.pairReveal), 0);
    });

    test('close with the start still on its way aborts it and sends no '
        'cancel', () async {
      final a = await stackA();
      final fake = await fakeB();
      fake.handlers[ApiPaths.pairStart] = (_) => const FakeAnswer.hold();
      a.coordinator.tryPair(fakeTarget(a, fake));
      await waitUntil(() => fake.heldOpened == 1, reason: 'start held');
      a.coordinator.cancelAsInitiator();
      await pause();
      expect(fake.heldClosed, 0);

      await a.coordinator.close().timeout(const Duration(seconds: 5));

      await waitUntil(
        () => fake.heldClosed == 1,
        limit: const Duration(seconds: 5),
        reason: 'start aborted by close',
      );
      await pause();
      expect(fake.count(ApiPaths.pairCancel), 0);
      expect(fake.count(ApiPaths.pairReveal), 0);
    });
  });

  group('only on request (RF-69)', () {
    test('ticks and network changes never send a start', () async {
      final (a, b) = await twoStacks();
      a.coordinator.interfacesChanged({a.iface.id});
      a.coordinator.interfacesChanged(const {});
      a.clock.advance(const Duration(minutes: 5));
      await pause(const Duration(milliseconds: 500));
      expect(b.handledTotal, 0);
      expect(a.view, isNull);
    });
  });

  test('stacks really use 127.0.0.1 and 127.0.0.2', () async {
    final (a, b) = await twoStacks();
    expect(a.address, InternetAddress.loopbackIPv4);
    expect(b.address.address, '127.0.0.2');
  });
}
