import 'dart:io';

import 'package:test/test.dart';

import 'infra.dart';

void main() {
  group('time scale for infrastructure waits', () {
    test('is 1 on a developer machine', () {
      expect(timeScaleFrom(const {}), 1);
      expect(timeScaleFrom(const {'CI': 'false'}), 1);
      expect(timeScaleFrom(const {'CI': '0'}), 1);
    });

    test('grows on a CI runner', () {
      expect(timeScaleFrom(const {'CI': 'true'}), ciTimeScale);
      expect(timeScaleFrom(const {'CI': '1'}), ciTimeScale);
    });

    test('the explicit variable wins over CI', () {
      expect(timeScaleFrom(const {timeScaleVariable: '5', 'CI': 'true'}), 5);
      expect(timeScaleFrom(const {timeScaleVariable: '1.5'}), 1.5);
    });

    test('an unusable explicit value falls back', () {
      expect(timeScaleFrom(const {timeScaleVariable: 'fast'}), 1);
      expect(timeScaleFrom(const {timeScaleVariable: '0.5'}), 1);
      expect(
        timeScaleFrom(const {timeScaleVariable: '-2', 'CI': 'true'}),
        ciTimeScale,
      );
    });

    test('scaled multiplies by the current scale', () {
      expect(
        scaled(const Duration(seconds: 10)),
        const Duration(seconds: 10) * timeScale,
      );
    });
  });

  group('starting on fresh ports', () {
    test('awaitListening returns once a listener is logged', () async {
      final logs = ['older line', 'listening on old'];
      final waiting = awaitListening(
        name: 'Node',
        logs: logs,
        since: 2,
        portInUse: () => null,
        limit: const Duration(seconds: 5),
      );
      await Future<void>.delayed(const Duration(milliseconds: 50));
      logs.add('listening on {WIFI}#127.0.0.1');
      await waiting;
    });

    test('awaitListening reports a taken port at once', () async {
      final watch = Stopwatch()..start();
      await expectLater(
        awaitListening(
          name: 'Node',
          logs: const ['listening on old'],
          since: 1,
          portInUse: () => 40000,
          limit: const Duration(seconds: 5),
        ),
        throwsA(isA<PortTaken>()),
      );
      expect(watch.elapsed, lessThan(const Duration(seconds: 1)));
    });

    test('onFreshPorts resets and retries while the port is taken', () async {
      var attempts = 0;
      var resets = 0;
      final result = await onFreshPorts(() async {
        attempts++;
        if (attempts < 3) throw PortTaken('busy');
        return 'up';
      }, reset: () async => resets++);
      expect(result, 'up');
      expect(attempts, 3);
      expect(resets, 2);
    });

    test('onFreshPorts gives up after the last attempt', () async {
      var attempts = 0;
      await expectLater(
        onFreshPorts<void>(() async {
          attempts++;
          throw PortTaken('busy');
        }, reset: () async {}),
        throwsA(isA<PortTaken>()),
      );
      expect(attempts, 5);
    });
  });

  group('pickPort', () {
    final first = InternetAddress('127.0.0.1');
    final second = InternetAddress('127.0.0.2');

    test('returns a port outside the dynamic range, free on every '
        'address asked', () async {
      final port = await pickPort(
        tcp: [first, second],
        udp: [InternetAddress.anyIPv4],
      );
      expect(port, inInclusiveRange(firstPickedPort, lastPickedPort));
      expect(await tcpFree(first, port), isTrue);
      expect(await tcpFree(second, port), isTrue);
      expect(await udpFree(InternetAddress.anyIPv4, port), isTrue);
    });

    test('never returns a port that is held', () async {
      final held = <ServerSocket>[];
      addTearDown(() async {
        for (final socket in held) {
          await socket.close();
        }
      });
      final taken = <int>{};
      for (var i = 0; i < 20; i++) {
        final port = await pickPort(tcp: [first]);
        expect(taken, isNot(contains(port)));
        taken.add(port);
        held.add(await ServerSocket.bind(first, port));
      }
    });
  });
}
