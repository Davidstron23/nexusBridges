import 'package:test/test.dart';

import '../support/infra.dart';
import 'two_nodes_harness.dart';

const Duration _present = Duration(milliseconds: 200);

int _presentations(TestNode node) =>
    node.timers.createdBy('DiscoveryService._present');

void main() {
  group('searching state (E135, RF-193, RF-194)', () {
    test('rescan sets scanning while it runs and clears it at the end, a '
        'second call meanwhile returns the same Future, and a later one '
        'starts a new search', () async {
      final (a, b) = await twoNodes();
      expect(a.state.scanning, isFalse);
      final emitted = a.states.length;

      late Future<void> firstCall;
      late Future<void> secondCall;
      a.zone.run(() {
        firstCall = a.node.rescan();
        secondCall = a.node.rescan();
      });

      expect(identical(firstCall, secondCall), isTrue);
      expect(a.state.scanning, isTrue);

      await firstCall;
      expect(a.state.scanning, isFalse);
      await eventually(
        () => a.states.skip(emitted).any((s) => !s.scanning),
        reason: 'scanning cleared in the stream',
      );
      final flags = [for (final s in a.states.skip(emitted)) s.scanning];
      expect(flags.first, isTrue);
      expect(flags.last, isFalse);
      expect(a.sees(b), isTrue);

      final thirdCall = a.zone.run(() => a.node.rescan());
      expect(identical(thirdCall, firstCall), isFalse);
      expect(a.state.scanning, isTrue);
      await thirdCall;
      expect(a.state.scanning, isFalse);
    }, timeout: twoNodesTimeout);

    test('a rescan without any trusted network also ends with scanning '
        'false', () async {
      final node = await TestNode.create('Lonely PC', hostA);
      node.port = await freePort();
      await node.boot();
      final emitted = node.states.length;

      final call = node.zone.run(() => node.node.rescan());
      expect(node.state.scanning, isTrue);
      await call.timeout(scaled(waitLimit));

      expect(node.state.scanning, isFalse);
      await eventually(
        () => node.states.skip(emitted).any((s) => !s.scanning),
        reason: 'scanning cleared in the stream',
      );
      expect(node.states.skip(emitted).first.scanning, isTrue);
    });
  });

  group('a device found by a search at node level (RF-192, RF-239)', () {
    test('a device found only by a search stays in the list past 35 s while '
        'it answers, and leaves it 30 s after it stops answering', () async {
      final (a, b) = await twoNodes(present: _present);
      await meet(a, b);

      a.advance(const Duration(seconds: 25));
      final before = _presentations(a);
      await eventually(
        () => _presentations(a) > before,
        reason: 'a presentation of A to B',
      );
      await pause(const Duration(seconds: 1));
      a.advance(const Duration(seconds: 10));
      await pause(const Duration(milliseconds: 1500));

      expect(a.sees(b), isTrue);
      expect(a.entryOf(b.fingerprint)?.visible, isTrue);

      await b.node.shutdown();
      await pause(const Duration(milliseconds: 500));
      a.advance(const Duration(seconds: 30));

      await a.until(
        (s) => !a.sees(b),
        limit: const Duration(seconds: 3),
        reason: 'B leaves the list of A',
      );
      expect(a.entryOf(b.fingerprint), isNull);
    }, timeout: twoNodesTimeout);

    test('a paired device found by a search that stops answering stays in '
        'the list as not visible after 30 s (RF-111)', () async {
      final (a, b) = await twoNodes();
      await meet(a, b);
      await pairNodes(a, b);
      expect(a.entryOf(b.fingerprint)?.visible, isTrue);

      await b.node.shutdown();
      await pause(const Duration(milliseconds: 500));
      a.advance(const Duration(seconds: 30));

      final state = await a.until(
        (s) => a.entryOf(b.fingerprint)?.visible == false,
        limit: const Duration(seconds: 3),
        reason: 'B not visible in A',
      );
      final entry = state.entries.singleWhere(
        (e) => e.fingerprint == b.fingerprint,
      );
      expect(entry.paired, isTrue);
      expect(entry.visible, isFalse);
      expect(a.sees(b), isFalse);
    }, timeout: twoNodesTimeout);
  });
}
