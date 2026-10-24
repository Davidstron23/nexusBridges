import 'dart:async';
import 'dart:math';

import 'package:nexus_bridges_core/src/discovery/verification_gate.dart';
import 'package:test/test.dart';

final DateTime _start = DateTime.utc(2026, 10, 22, 12);

final class _Jobs {
  final Map<String, Completer<void>> _pending = {};

  final Map<String, int> _runningPerIp = {};

  final List<String> started = [];

  int running = 0;

  int maxRunning = 0;

  int maxPerIp = 0;

  Set<String> get runningIds => _pending.keys.toSet();

  Future<void> Function() job(String id, String ip) => () async {
    final completer = Completer<void>();
    _pending[id] = completer;
    started.add(id);
    running++;
    final perIp = (_runningPerIp[ip] ?? 0) + 1;
    _runningPerIp[ip] = perIp;
    maxRunning = max(maxRunning, running);
    maxPerIp = max(maxPerIp, perIp);
    try {
      await completer.future;
    } finally {
      running--;
      _runningPerIp[ip] = _runningPerIp[ip]! - 1;
    }
  };

  Future<void> finish(String id) async {
    _pending.remove(id)!.complete();
    await pumpEventQueue();
  }

  Future<void> fail(String id) async {
    _pending.remove(id)!.completeError(StateError('verification failed'));
    await pumpEventQueue();
  }

  Future<void> finishAll() async {
    while (_pending.isNotEmpty) {
      final batch = [..._pending.values];
      _pending.clear();
      for (final completer in batch) {
        completer.complete();
      }
      await pumpEventQueue();
    }
  }
}

String _id(String fingerprint, String ip, bool reverse) =>
    '${reverse ? 'reverse' : 'normal'}:$fingerprint@$ip';

String _ipOf(int index) => '10.0.0.${index + 1}';

void main() {
  late DateTime now;
  late _Jobs jobs;
  late VerificationGate gate;

  setUp(() {
    now = _start;
    jobs = _Jobs();
    gate = VerificationGate(now: () => now);
  });

  void at(Duration offset) => now = _start.add(offset);

  bool submit(
    String fingerprint,
    String ip, {
    String interfaceId = 'eth',
    bool reverse = false,
  }) => gate.submit(
    fingerprint: fingerprint,
    ip: ip,
    interfaceId: interfaceId,
    reverse: reverse,
    job: jobs.job(_id(fingerprint, ip, reverse), ip),
  );

  bool submitPort(
    String fingerprint,
    String ip,
    int? port, {
    bool reverse = false,
  }) => gate.submit(
    fingerprint: fingerprint,
    ip: ip,
    interfaceId: 'eth',
    reverse: reverse,
    port: port,
    job: jobs.job('${_id(fingerprint, ip, reverse)}:$port', ip),
  );

  List<bool> flood({int count = 100, int ips = 10}) => [
    for (var i = 0; i < count; i++) submit('fp$i', _ipOf(i % ips)),
  ];

  String normal(String fingerprint, String ip) => _id(fingerprint, ip, false);

  String reverse(String fingerprint, String ip) => _id(fingerprint, ip, true);

  group('normal lane limits (RF-44)', () {
    test('100 different fingerprints from 10 IPs: 6 running, 56 queued and '
        'the rest rejected', () {
      final results = flood();

      expect(results.take(62), everyElement(isTrue));
      expect(results.skip(62), everyElement(isFalse));
      expect(gate.active, 6);
      expect(gate.queued, 56);
      expect(jobs.started, hasLength(6));
      expect(jobs.maxPerIp, 1);
    });

    test('the first six running jobs come from six different IPs', () {
      flood();

      expect(jobs.started, [
        for (var i = 0; i < 6; i++) normal('fp$i', _ipOf(i)),
      ]);
    });

    test('a second job from a busy IP waits in the queue even with free '
        'slots', () {
      expect(submit('fpA', '10.0.0.1'), isTrue);
      expect(submit('fpB', '10.0.0.1'), isTrue);

      expect(gate.active, 1);
      expect(gate.queued, 1);
      expect(jobs.runningIds, {normal('fpA', '10.0.0.1')});
    });

    test('draining the flood runs every accepted job, never more than 6 at '
        'once nor more than 1 per IP', () async {
      flood();

      await jobs.finishAll();

      expect(jobs.started, hasLength(62));
      expect(jobs.started.toSet(), hasLength(62));
      expect(jobs.maxRunning, 6);
      expect(jobs.maxPerIp, 1);
      expect(gate.active, 0);
      expect(gate.queued, 0);
    });

    test(
      'a finished job frees its slot and the queue keeps its order',
      () async {
        for (var i = 0; i < 6; i++) {
          submit('fp$i', _ipOf(i));
        }
        submit('fp6', _ipOf(6));
        submit('fp7', _ipOf(7));

        await jobs.finish(normal('fp3', _ipOf(3)));

        expect(jobs.started.last, normal('fp6', _ipOf(6)));
        expect(gate.active, 6);
        expect(gate.queued, 1);
      },
    );

    test('the pump skips a queued job whose IP is busy and starts the next '
        'one', () async {
      for (var i = 0; i < 6; i++) {
        submit('fp$i', _ipOf(i));
      }
      submit('fpX', _ipOf(0));
      submit('fpY', _ipOf(7));

      await jobs.finish(normal('fp2', _ipOf(2)));

      expect(jobs.runningIds, contains(normal('fpY', _ipOf(7))));
      expect(jobs.runningIds, isNot(contains(normal('fpX', _ipOf(0)))));
      expect(gate.queued, 1);

      await jobs.finish(normal('fp0', _ipOf(0)));

      expect(jobs.runningIds, contains(normal('fpX', _ipOf(0))));
      expect(gate.queued, 0);
    });

    test(
      'a slot freed after the queue was full lets one more job in',
      () async {
        flood();
        expect(submit('late', _ipOf(3)), isFalse);

        await jobs.finish(normal('fp0', _ipOf(0)));

        expect(gate.queued, 55);
        expect(submit('late', _ipOf(3)), isTrue);
        expect(gate.queued, 56);
      },
    );
  });

  group('one per pair of fingerprint and IP (RF-44, R17)', () {
    test('the same pair twice while it runs is rejected the second time', () {
      expect(submit('fpA', '10.0.0.1'), isTrue);

      expect(submit('fpA', '10.0.0.1'), isFalse);
      expect(gate.active, 1);
      expect(gate.queued, 0);
    });

    test('the same pair twice while it is queued is rejected the second '
        'time', () {
      for (var i = 0; i < 6; i++) {
        submit('fp$i', _ipOf(i));
      }
      expect(submit('fpA', _ipOf(7)), isTrue);

      expect(submit('fpA', _ipOf(7)), isFalse);
      expect(gate.queued, 1);
    });

    test('the same fingerprint from another IP is accepted', () {
      expect(submit('fpA', '10.0.0.1'), isTrue);

      expect(submit('fpA', '10.0.0.2'), isTrue);
      expect(gate.active, 2);
    });

    test('a fake hello with the fingerprint of a real device from another IP '
        'does not block the real device', () {
      for (var i = 0; i < 6; i++) {
        submit('fp$i', _ipOf(i));
      }
      expect(submit('real', '10.0.0.66'), isTrue);

      expect(submit('real', '10.0.0.77'), isTrue);
      expect(gate.queued, 2);
    });

    test('the same pair is accepted again once its job has finished', () async {
      submit('fpA', '10.0.0.1');

      await jobs.finish(normal('fpA', '10.0.0.1'));

      expect(submit('fpA', '10.0.0.1'), isTrue);
      expect(gate.active, 1);
    });
  });

  group('C129: key by port for paired devices and clearFailures (RF-44 of '
      'the 002, N2)', () {
    test('a failure on port 1 does not block the same fingerprint and IP on '
        'port 53530, and port 1 stays blocked', () {
      gate.markFailed('fpP', '10.0.0.2', port: 1);
      at(const Duration(seconds: 5));

      expect(submitPort('fpP', '10.0.0.2', 53530), isTrue);
      expect(submitPort('fpP', '10.0.0.2', 1), isFalse);
    });

    test('clearFailures lets the blocked port in again at once', () {
      gate.markFailed('fpP', '10.0.0.2', port: 1);
      at(const Duration(seconds: 5));
      expect(submitPort('fpP', '10.0.0.2', 1), isFalse);

      gate.clearFailures('fpP');

      expect(submitPort('fpP', '10.0.0.2', 1), isTrue);
    });

    test('without a port the key is fingerprint and IP as before: rejected '
        'until 9 s, and clearFailures also clears it', () {
      gate.markFailed('fpU', '10.0.0.3');
      at(const Duration(seconds: 8, milliseconds: 999));
      expect(submitPort('fpU', '10.0.0.3', null), isFalse);
      at(const Duration(seconds: 9, milliseconds: 1));
      expect(submitPort('fpU', '10.0.0.3', null), isTrue);

      gate.markFailed('fpV', '10.0.0.4');
      gate.clearFailures('fpV');
      expect(submitPort('fpV', '10.0.0.4', null), isTrue);
    });

    test('a failure with a port does not touch the key without a port, nor '
        'the other way round', () {
      gate.markFailed('fpP', '10.0.0.2', port: 1);
      gate.markFailed('fpQ', '10.0.0.2');

      expect(submitPort('fpP', '10.0.0.2', null), isTrue);
      expect(submitPort('fpQ', '10.0.0.2', 53530), isTrue);
      expect(submitPort('fpQ', '10.0.0.2', null), isFalse);
    });

    test('the same job with two ports in flight is accepted twice: the keys '
        'are different', () {
      expect(submitPort('fpP', '10.0.0.2', 1), isTrue);
      expect(submitPort('fpP', '10.0.0.2', 53530), isTrue);
      expect(submitPort('fpP', '10.0.0.2', 53530), isFalse);
      expect(gate.active + gate.queued, 2);
    });

    test('clearFailures empties both lanes for that fingerprint only, and '
        'only for the exact fingerprint', () {
      gate.markFailed('fpA', '10.0.0.1', port: 7);
      gate.markFailed('fpA', '10.0.0.5', reverse: true, port: 7);
      gate.markFailed('fpAB', '10.0.0.1', port: 7);
      gate.markFailed('fpB', '10.0.0.1');

      gate.clearFailures('fpA');

      expect(submitPort('fpA', '10.0.0.1', 7), isTrue);
      expect(submitPort('fpA', '10.0.0.5', 7, reverse: true), isTrue);
      expect(submitPort('fpAB', '10.0.0.1', 7), isFalse);
      expect(submitPort('fpB', '10.0.0.1', null), isFalse);
    });
  });

  group('wait after a failure (RF-44)', () {
    test(
      'a pair marked as failed is rejected for 9 s and accepted after',
      () async {
        submit('fpA', '10.0.0.1');
        await jobs.finish(normal('fpA', '10.0.0.1'));
        gate.markFailed('fpA', '10.0.0.1');

        expect(submit('fpA', '10.0.0.1'), isFalse);
        at(const Duration(seconds: 5));
        expect(submit('fpA', '10.0.0.1'), isFalse);
        at(const Duration(seconds: 8, milliseconds: 999));
        expect(submit('fpA', '10.0.0.1'), isFalse);

        at(const Duration(seconds: 9, milliseconds: 1));
        expect(submit('fpA', '10.0.0.1'), isTrue);
        expect(gate.active, 1);
      },
    );

    test('marking the failure while the job still runs also makes the pair '
        'wait after the job ends', () async {
      submit('fpA', '10.0.0.1');
      at(const Duration(seconds: 2));
      gate.markFailed('fpA', '10.0.0.1');
      await jobs.finish(normal('fpA', '10.0.0.1'));

      at(const Duration(seconds: 10));
      expect(submit('fpA', '10.0.0.1'), isFalse);

      at(const Duration(seconds: 11, milliseconds: 1));
      expect(submit('fpA', '10.0.0.1'), isTrue);
    });

    test('a failed pair does not block the same fingerprint from another IP '
        'nor another fingerprint from the same IP', () {
      gate.markFailed('fpA', '10.0.0.1');

      expect(submit('fpA', '10.0.0.2'), isTrue);
      expect(submit('fpB', '10.0.0.1'), isTrue);
      expect(submit('fpA', '10.0.0.1'), isFalse);
    });

    test('a later failure restarts the wait', () async {
      gate.markFailed('fpA', '10.0.0.1');
      at(const Duration(seconds: 9, milliseconds: 1));
      expect(submit('fpA', '10.0.0.1'), isTrue);
      await jobs.finish(normal('fpA', '10.0.0.1'));

      gate.markFailed('fpA', '10.0.0.1');
      at(const Duration(seconds: 18));
      expect(submit('fpA', '10.0.0.1'), isFalse);

      at(const Duration(seconds: 18, milliseconds: 2));
      expect(submit('fpA', '10.0.0.1'), isTrue);
    });

    test('a failure in the normal lane does not block the reverse lane', () {
      gate.markFailed('fpA', '10.0.0.1');

      expect(submit('fpA', '10.0.0.1', reverse: true), isTrue);
      expect(submit('fpA', '10.0.0.1'), isFalse);
    });

    test('a failure in the reverse lane does not block the normal lane', () {
      gate.markFailed('fpA', '10.0.0.1', reverse: true);

      expect(submit('fpA', '10.0.0.1'), isTrue);
      expect(submit('fpA', '10.0.0.1', reverse: true), isFalse);

      at(const Duration(seconds: 9, milliseconds: 1));
      expect(submit('fpA', '10.0.0.1', reverse: true), isTrue);
    });

    test('a custom cooldown is honoured', () {
      gate = VerificationGate(
        failureCooldown: const Duration(seconds: 2),
        now: () => now,
      );
      gate.markFailed('fpA', '10.0.0.1');

      at(const Duration(seconds: 1));
      expect(submit('fpA', '10.0.0.1'), isFalse);
      at(const Duration(seconds: 2, milliseconds: 1));
      expect(submit('fpA', '10.0.0.1'), isTrue);
    });

    test('with more than 256 failed pairs the pruning keeps the pairs still '
        'waiting', () {
      for (var i = 0; i < 300; i++) {
        gate.markFailed('old$i', _ipOf(i % 200));
      }
      at(const Duration(seconds: 6));
      gate.markFailed('recent', '10.0.1.1');
      at(const Duration(seconds: 10));
      gate.markFailed('newest', '10.0.1.2');

      at(const Duration(seconds: 12));
      expect(submit('recent', '10.0.1.1'), isFalse);
      expect(submit('newest', '10.0.1.2'), isFalse);
      expect(submit('old0', _ipOf(0)), isTrue);

      at(const Duration(seconds: 15, milliseconds: 1));
      expect(submit('recent', '10.0.1.1'), isTrue);
      at(const Duration(seconds: 19, milliseconds: 1));
      expect(submit('newest', '10.0.1.2'), isTrue);
    });

    test('with more than 256 failed pairs that are all still waiting, none '
        'is released early', () {
      final ips = [for (var i = 0; i < 300; i++) '10.1.${i ~/ 250}.${i % 250}'];
      for (final ip in ips) {
        gate.markFailed('fp', ip);
      }
      at(const Duration(seconds: 5));
      gate.markFailed('trigger', '10.2.0.1');

      at(const Duration(seconds: 8, milliseconds: 999));
      for (final ip in ips) {
        expect(submit('fp', ip), isFalse, reason: ip);
      }
    });

    test('failures in the reverse lane are also pruned without releasing '
        'pairs that are still waiting', () {
      for (var i = 0; i < 300; i++) {
        gate.markFailed('old$i', _ipOf(i % 200), reverse: true);
      }
      at(const Duration(seconds: 6));
      gate.markFailed('recent', '10.0.1.1', reverse: true);
      at(const Duration(seconds: 10));
      gate.markFailed('newest', '10.0.1.2', reverse: true);

      at(const Duration(seconds: 12));
      expect(submit('recent', '10.0.1.1', reverse: true), isFalse);
      expect(submit('newest', '10.0.1.2', reverse: true), isFalse);
    });
  });

  group('reverse lane (RF-44, R14, R17)', () {
    test('with the normal lane full a reverse job starts at once', () {
      flood();
      expect(submit('late', _ipOf(3)), isFalse);

      expect(submit('reverse1', _ipOf(3), reverse: true), isTrue);

      expect(jobs.runningIds, contains(reverse('reverse1', _ipOf(3))));
      expect(gate.active, 7);
      expect(gate.queued, 56);
    });

    test('with the normal lane full a reverse job starts at once even if its '
        'pair is waiting in the normal queue', () {
      flood();
      expect(jobs.runningIds, isNot(contains(normal('fp40', _ipOf(0)))));

      expect(submit('fp40', _ipOf(0), reverse: true), isTrue);

      expect(jobs.runningIds, contains(reverse('fp40', _ipOf(0))));
      expect(gate.active, 7);
    });

    test('a reverse job is accepted even if its pair is running in the '
        'normal lane', () {
      submit('fpA', '10.0.0.1');

      expect(submit('fpA', '10.0.0.1', reverse: true), isTrue);
      expect(gate.active, 2);
    });

    test('the same pair twice in the reverse lane is rejected the second '
        'time', () {
      expect(submit('fpA', '10.0.0.1', reverse: true), isTrue);

      expect(submit('fpA', '10.0.0.1', reverse: true), isFalse);
    });

    test('runs at most 2 at once and 1 per IP', () {
      expect(submit('a', '10.0.0.1', reverse: true), isTrue);
      expect(submit('b', '10.0.0.1', reverse: true), isTrue);
      expect(submit('c', '10.0.0.2', reverse: true), isTrue);
      expect(submit('d', '10.0.0.3', reverse: true), isTrue);

      expect(gate.active, 2);
      expect(gate.queued, 2);
      expect(jobs.runningIds, {
        reverse('a', '10.0.0.1'),
        reverse('c', '10.0.0.2'),
      });
    });

    test('queues at most 8 and rejects the rest', () {
      submit('run1', '10.0.0.1', reverse: true);
      submit('run2', '10.0.0.2', reverse: true);
      for (var i = 0; i < 8; i++) {
        expect(
          submit('q$i', '10.0.1.${i ~/ 2}', reverse: true),
          isTrue,
          reason: 'queued $i',
        );
      }

      expect(submit('extra', '10.0.2.1', reverse: true), isFalse);
      expect(gate.active, 2);
      expect(gate.queued, 8);
    });

    test('queues at most 2 per IP', () {
      submit('run1', '10.0.0.1', reverse: true);
      submit('run2', '10.0.0.2', reverse: true);

      expect(submit('a', '10.0.0.1', reverse: true), isTrue);
      expect(submit('b', '10.0.0.1', reverse: true), isTrue);
      expect(submit('c', '10.0.0.1', reverse: true), isFalse);
      expect(submit('d', '10.0.0.3', reverse: true), isTrue);
      expect(gate.queued, 3);
    });

    test('the reverse queue limits do not depend on the normal queue', () {
      flood();

      for (var i = 0; i < 10; i++) {
        expect(
          submit('r$i', '10.0.3.${i ~/ 2}', reverse: true),
          isTrue,
          reason: 'reverse $i',
        );
      }
      expect(submit('extra', '10.0.4.1', reverse: true), isFalse);
      expect(gate.active, 8);
      expect(gate.queued, 64);
    });

    test('a finished reverse job lets the next reverse job start', () async {
      submit('a', '10.0.0.1', reverse: true);
      submit('b', '10.0.0.2', reverse: true);
      submit('c', '10.0.0.3', reverse: true);

      await jobs.finish(reverse('a', '10.0.0.1'));

      expect(jobs.runningIds, contains(reverse('c', '10.0.0.3')));
      expect(gate.active, 2);
      expect(gate.queued, 0);
    });

    test(
      'a finished normal job does not start more than 2 reverse jobs',
      () async {
        submit('n', '10.0.0.9');
        submit('a', '10.0.0.1', reverse: true);
        submit('b', '10.0.0.2', reverse: true);
        submit('c', '10.0.0.3', reverse: true);

        await jobs.finish(normal('n', '10.0.0.9'));

        expect(jobs.runningIds, {
          reverse('a', '10.0.0.1'),
          reverse('b', '10.0.0.2'),
        });
        expect(gate.queued, 1);
      },
    );
  });

  group('totals (RF-44)', () {
    test('never more than 8 running nor more than 2 per IP in total', () async {
      flood();
      for (var i = 0; i < 20; i++) {
        submit('r$i', _ipOf(i % 10), reverse: true);
      }
      expect(gate.active, 8);
      expect(jobs.maxPerIp, 2);

      await jobs.finishAll();

      expect(jobs.maxRunning, 8);
      expect(jobs.maxPerIp, 2);
      expect(gate.active, 0);
      expect(gate.queued, 0);
    });

    test('the 8 running jobs come from both lanes', () {
      flood();
      submit('r1', _ipOf(0), reverse: true);
      submit('r2', _ipOf(1), reverse: true);
      submit('r3', _ipOf(2), reverse: true);

      expect(gate.active, 8);
      expect(jobs.running, 8);
      expect(gate.queued, 57);
    });
  });

  group('dropInterface', () {
    test('removes the queued jobs of that interface from both lanes', () {
      for (var i = 0; i < 6; i++) {
        submit('fp$i', _ipOf(i), interfaceId: 'eth');
      }
      submit('wq1', '10.0.5.1', interfaceId: 'wifi');
      submit('eq1', '10.0.5.2', interfaceId: 'eth');
      submit('wq2', '10.0.5.3', interfaceId: 'wifi');
      submit('wr1', '10.0.6.1', interfaceId: 'wifi', reverse: true);
      submit('wr2', '10.0.6.2', interfaceId: 'wifi', reverse: true);
      submit('wr3', '10.0.6.3', interfaceId: 'wifi', reverse: true);
      submit('er1', '10.0.6.4', interfaceId: 'eth', reverse: true);
      expect(gate.queued, 5);

      gate.dropInterface('wifi');

      expect(gate.queued, 2);
      expect(gate.active, 8);
    });

    test('the dropped jobs never start and the others still run', () async {
      for (var i = 0; i < 6; i++) {
        submit('fp$i', _ipOf(i), interfaceId: 'eth');
      }
      submit('wq1', '10.0.5.1', interfaceId: 'wifi');
      submit('eq1', '10.0.5.2', interfaceId: 'eth');
      submit('wr1', '10.0.6.1', interfaceId: 'wifi', reverse: true);
      submit('wr2', '10.0.6.2', interfaceId: 'wifi', reverse: true);
      submit('wr3', '10.0.6.3', interfaceId: 'wifi', reverse: true);

      gate.dropInterface('wifi');
      await jobs.finishAll();

      expect(jobs.started, isNot(contains(normal('wq1', '10.0.5.1'))));
      expect(jobs.started, isNot(contains(reverse('wr3', '10.0.6.3'))));
      expect(jobs.started, contains(normal('eq1', '10.0.5.2')));
      expect(jobs.started, contains(reverse('wr1', '10.0.6.1')));
      expect(jobs.started, contains(reverse('wr2', '10.0.6.2')));
    });

    test('running jobs of that interface are left to finish', () async {
      submit('w', '10.0.5.1', interfaceId: 'wifi');

      gate.dropInterface('wifi');

      expect(gate.active, 1);
      await jobs.finish(normal('w', '10.0.5.1'));
      expect(gate.active, 0);
    });

    test('a dropped pair can be submitted again', () {
      for (var i = 0; i < 6; i++) {
        submit('fp$i', _ipOf(i));
      }
      submit('w', '10.0.5.1', interfaceId: 'wifi');
      gate.dropInterface('wifi');

      expect(submit('w', '10.0.5.1', interfaceId: 'wifi'), isTrue);
      expect(gate.queued, 1);
    });
  });

  group('clear', () {
    test('empties both queues and rejects new jobs in both lanes', () {
      flood();
      for (var i = 0; i < 5; i++) {
        submit('r$i', '10.0.3.$i', reverse: true);
      }

      gate.clear();

      expect(gate.queued, 0);
      expect(gate.active, 8);
      expect(submit('new', '10.0.9.1'), isFalse);
      expect(submit('new', '10.0.9.1', reverse: true), isFalse);
    });

    test('running jobs end on their own and no other job starts', () async {
      flood();
      submit('r0', '10.0.3.0', reverse: true);
      submit('r1', '10.0.3.1', reverse: true);
      submit('r2', '10.0.3.2', reverse: true);
      final startedBefore = [...jobs.started];

      gate.clear();
      await jobs.finishAll();

      expect(jobs.started, startedBefore);
      expect(gate.active, 0);
      expect(gate.queued, 0);
    });
  });

  group('failing jobs', () {
    test('a job that throws frees its slot and the next one starts', () async {
      flood();

      await jobs.fail(normal('fp0', _ipOf(0)));

      expect(gate.active, 6);
      expect(gate.queued, 55);
      expect(jobs.started, hasLength(7));
    });

    test('a job that throws synchronously frees its slot', () async {
      expect(
        gate.submit(
          fingerprint: 'boom',
          ip: '10.0.0.1',
          interfaceId: 'eth',
          job: () => throw StateError('verification failed'),
        ),
        isTrue,
      );
      await pumpEventQueue();

      expect(gate.active, 0);
      expect(submit('fpA', '10.0.0.1'), isTrue);
      expect(gate.active, 1);
    });

    test('a failing reverse job frees its slot', () async {
      submit('a', '10.0.0.1', reverse: true);
      submit('b', '10.0.0.2', reverse: true);
      submit('c', '10.0.0.3', reverse: true);

      await jobs.fail(reverse('a', '10.0.0.1'));

      expect(jobs.runningIds, contains(reverse('c', '10.0.0.3')));
      expect(gate.active, 2);
    });

    test('the gate keeps working after many failing jobs', () async {
      flood();
      while (jobs.runningIds.isNotEmpty) {
        await jobs.fail(jobs.runningIds.first);
      }

      expect(jobs.started, hasLength(62));
      expect(gate.active, 0);
      expect(gate.queued, 0);
      expect(submit('fp0', _ipOf(0)), isTrue);
    });

    test('the pair of a failing job is accepted again unless it is marked '
        'as failed', () async {
      submit('fpA', '10.0.0.1');
      submit('fpB', '10.0.0.2');

      await jobs.fail(normal('fpA', '10.0.0.1'));
      gate.markFailed('fpB', '10.0.0.2');
      await jobs.fail(normal('fpB', '10.0.0.2'));

      expect(submit('fpA', '10.0.0.1'), isTrue);
      expect(submit('fpB', '10.0.0.2'), isFalse);
    });
  });
}
