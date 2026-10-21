import 'dart:async';
import 'dart:io';

import 'package:nexus_bridges_core/src/network/network.dart';
import 'package:test/test.dart';

const Duration _shortInterval = Duration(milliseconds: 20);
const Duration _neverInterval = Duration(hours: 1);
const Duration _waitLimit = Duration(seconds: 5);

Ipv4Subnet _subnet(String address, int prefixLength) =>
    Ipv4Subnet(InternetAddress(address), prefixLength);

AdapterInfo _adapter({
  String id = '{11111111-AAAA-BBBB-CCCC-000000000001}',
  String friendlyName = 'Wi-Fi',
  String description = 'Example wireless adapter',
  int ifType = 71,
  bool isUp = true,
  List<Ipv4Subnet>? ipv4,
  bool hasGateway = true,
  String? networkId = '{22222222-AAAA-BBBB-CCCC-000000000001}',
  String? networkName = 'Home',
}) => AdapterInfo(
  id: id,
  friendlyName: friendlyName,
  description: description,
  ifType: ifType,
  isUp: isUp,
  ipv4: ipv4 ?? [_subnet('192.168.50.21', 24)],
  hasGateway: hasGateway,
  networkId: networkId,
  networkName: networkName,
);

final class _SecretBearingError implements Exception {
  @override
  String toString() => 'secret 10.9.8.7 C:\\Users\\someone';
}

final class _ControlledReader {
  final List<Completer<List<AdapterInfo>>> _pending = [];
  Completer<void> _arrived = Completer<void>();
  int calls = 0;
  int active = 0;
  int maxActive = 0;

  Future<List<AdapterInfo>> call() {
    calls++;
    active++;
    if (active > maxActive) maxActive = active;
    final completer = Completer<List<AdapterInfo>>();
    _pending.add(completer);
    final arrived = _arrived;
    _arrived = Completer<void>();
    arrived.complete();
    return completer.future.whenComplete(() => active--);
  }

  Future<Completer<List<AdapterInfo>>> next() async {
    while (_pending.isEmpty) {
      await _arrived.future.timeout(_waitLimit);
    }
    return _pending.removeAt(0);
  }
}

final class _Harness {
  _Harness({required Duration interval}) : now = DateTime.utc(2026, 10, 21, 9) {
    monitor = NetworkMonitor(
      read: reader.call,
      interval: interval,
      now: () => now,
      log: logs.add,
    );
    subscription = monitor.changes.listen(
      events.add,
      onDone: () => done = true,
    );
  }

  final _ControlledReader reader = _ControlledReader();
  final List<NetworkChange> events = [];
  final List<String> logs = [];
  late final NetworkMonitor monitor;
  late final StreamSubscription<NetworkChange> subscription;
  DateTime now;
  bool done = false;

  Future<void> answerNext(
    List<AdapterInfo> adapters, {
    Duration advanceClock = Duration.zero,
  }) async {
    final pending = await reader.next();
    now = now.add(advanceClock);
    pending.complete(adapters);
    await pumpEventQueue();
  }

  Future<void> failNext(Object error) async {
    (await reader.next()).completeError(error);
    await pumpEventQueue();
  }

  Future<void> dispose() async {
    await monitor.stop();
    await subscription.cancel();
  }
}

void main() {
  _Harness harness({Duration interval = _shortInterval}) {
    final h = _Harness(interval: interval);
    addTearDown(h.dispose);
    return h;
  }

  group('first reading', () {
    test('start reads at once, without waiting for the interval', () async {
      final h = harness(interval: _neverInterval);

      h.monitor.start();

      expect(h.reader.calls, 1);
      final adapters = [_adapter()];
      await h.answerNext(adapters);
      expect(h.events, hasLength(1));
      expect(h.events.single.adapters, same(adapters));
      expect(h.events.single.resumed, isFalse);
    });

    test('an empty first reading is emitted too', () async {
      final h = harness(interval: _neverInterval);

      h.monitor.start();
      await h.answerNext(const []);

      expect(h.events, hasLength(1));
      expect(h.events.single.adapters, isEmpty);
    });

    test('nothing is read before start', () async {
      final h = harness();

      await Future<void>.delayed(_shortInterval * 4);

      expect(h.reader.calls, 0);
      expect(h.events, isEmpty);
    });

    test('calling start twice does not add a second reading', () async {
      final h = harness(interval: _neverInterval);

      h.monitor.start();
      h.monitor.start();

      expect(h.reader.calls, 1);
    });
  });

  group('emits only when a compared field changes', () {
    test('no emission while nothing changes', () async {
      final h = harness();
      h.monitor.start();

      await h.answerNext([_adapter()]);
      await h.answerNext([_adapter()]);
      await h.answerNext([_adapter()]);
      await h.reader.next();

      expect(h.reader.calls, greaterThanOrEqualTo(4));
      expect(h.events, hasLength(1));
    });

    final changes = <String, AdapterInfo>{
      'networkId': _adapter(
        networkId: '{22222222-AAAA-BBBB-CCCC-000000000002}',
      ),
      'networkId to null': _adapter(networkId: null),
      'isUp': _adapter(isUp: false),
      'hasGateway': _adapter(hasGateway: false),
      'ipv4 address': _adapter(ipv4: [_subnet('192.168.50.22', 24)]),
      'ipv4 prefix': _adapter(ipv4: [_subnet('192.168.50.21', 16)]),
      'an added ipv4': _adapter(
        ipv4: [_subnet('192.168.50.21', 24), _subnet('10.0.0.5', 8)],
      ),
      'no ipv4 left': _adapter(ipv4: const []),
      'adapter id': _adapter(id: '{11111111-AAAA-BBBB-CCCC-000000000002}'),
    };

    for (final MapEntry(key: label, value: changed) in changes.entries) {
      test('a change of $label emits', () async {
        final h = harness();
        h.monitor.start();

        await h.answerNext([_adapter()]);
        await h.answerNext([changed]);
        await h.reader.next();

        expect(h.events, hasLength(2));
        expect(h.events.last.adapters.single, same(changed));
        expect(h.events.last.resumed, isFalse);
      });
    }

    test('an adapter that appears or disappears emits', () async {
      final h = harness();
      h.monitor.start();
      final second = _adapter(
        id: '{11111111-AAAA-BBBB-CCCC-000000000002}',
        networkId: null,
      );

      await h.answerNext([_adapter()]);
      await h.answerNext([_adapter(), second]);
      await h.answerNext([_adapter()]);
      await h.reader.next();

      expect(h.events.map((e) => e.adapters.length), [1, 2, 1]);
    });

    final cosmetic = <String, AdapterInfo>{
      'friendlyName': _adapter(friendlyName: 'Renamed'),
      'description': _adapter(description: 'Other description'),
      'networkName': _adapter(networkName: 'Other name'),
    };

    for (final MapEntry(key: label, value: changed) in cosmetic.entries) {
      test('a change of only $label does not emit', () async {
        final h = harness();
        h.monitor.start();

        await h.answerNext([_adapter()]);
        await h.answerNext([changed]);
        await h.reader.next();

        expect(h.events, hasLength(1));
      });
    }

    test('after a change, the new list is the reference', () async {
      final h = harness();
      h.monitor.start();
      final offline = _adapter(isUp: false);

      await h.answerNext([_adapter()]);
      await h.answerNext([offline]);
      await h.answerNext([_adapter(isUp: false)]);
      await h.answerNext([_adapter()]);
      await h.reader.next();

      expect(h.events.map((e) => e.adapters.single.isUp), [true, false, true]);
    });
  });

  group('resumed after a large clock gap (prepares RF-22)', () {
    test('only a gap larger than three intervals marks resumed', () async {
      final h = harness();
      h.monitor.start();

      await h.answerNext([_adapter()]);
      await h.answerNext([_adapter()], advanceClock: _shortInterval * 3);
      await h.answerNext([
        _adapter(),
      ], advanceClock: _shortInterval * 3 + const Duration(microseconds: 1));
      await h.answerNext([_adapter()]);
      await h.answerNext([_adapter()]);
      await h.reader.next();

      expect(h.events.map((e) => e.resumed), [false, true]);
      expect(h.events.last.adapters.single.id, _adapter().id);
    });

    test('a resume after an hour emits even with the same adapters', () async {
      final h = harness();
      h.monitor.start();

      await h.answerNext([_adapter()]);
      await h.answerNext([_adapter()], advanceClock: const Duration(hours: 1));
      await h.answerNext([_adapter()]);
      await h.answerNext([_adapter()]);
      await h.reader.next();

      expect(h.events.map((e) => e.resumed), [false, true]);
    });

    test('a change without a gap is not marked resumed', () async {
      final h = harness();
      h.monitor.start();

      await h.answerNext([_adapter()], advanceClock: _shortInterval);
      await h.answerNext([_adapter()], advanceClock: _shortInterval * 2);
      await h.answerNext([_adapter(isUp: false)]);
      await h.reader.next();

      expect(h.events.map((e) => e.resumed), [false, false]);
    });
  });

  group('a failing read is logged without data and retried', () {
    test('logs only the runtime type and keeps working', () async {
      final h = harness();
      h.monitor.start();

      await h.answerNext([_adapter()]);
      await h.failNext(_SecretBearingError());
      await h.answerNext([_adapter(isUp: false)]);
      await h.reader.next();

      expect(h.logs, ['network read failed: _SecretBearingError']);
      expect(h.logs.join(), isNot(contains('secret')));
      expect(h.logs.join(), isNot(contains('10.9.8.7')));
      expect(h.events.map((e) => e.adapters.single.isUp), [true, false]);
    });

    test('a first read that fails is followed by a first emission', () async {
      final h = harness();
      h.monitor.start();

      await h.failNext(StateError('boom 192.168.1.1'));
      expect(h.events, isEmpty);
      await h.answerNext([_adapter()]);
      await h.reader.next();

      expect(h.logs, ['network read failed: StateError']);
      expect(h.events, hasLength(1));
      expect(h.events.single.resumed, isFalse);
    });

    test('a failure does not reset the reference list', () async {
      final h = harness();
      h.monitor.start();

      await h.answerNext([_adapter()]);
      await h.failNext(const FileSystemException('x'));
      await h.answerNext([_adapter()]);
      await h.reader.next();

      expect(h.logs, ['network read failed: FileSystemException']);
      expect(h.events, hasLength(1));
    });

    test('a read that throws synchronously is handled too', () async {
      var calls = 0;
      final logs = <String>[];
      final monitor = NetworkMonitor(
        read: () {
          calls++;
          if (calls == 1) throw ArgumentError('secret');
          return Future.value([_adapter()]);
        },
        interval: _shortInterval,
        now: () => DateTime.utc(2026),
        log: logs.add,
      );
      addTearDown(monitor.stop);
      final firstChange = monitor.changes.first;

      monitor.start();
      final change = await firstChange.timeout(_waitLimit);
      await monitor.stop();

      expect(logs, ['network read failed: ArgumentError']);
      expect(calls, greaterThanOrEqualTo(2));
      expect(change.adapters, hasLength(1));
      expect(change.resumed, isFalse);
    });
  });

  group('a tick is skipped while the previous read is running', () {
    test('there are never two reads at the same time', () async {
      final h = harness();
      h.monitor.start();
      final first = await h.reader.next();

      await Future<void>.delayed(_shortInterval * 6);

      expect(h.reader.calls, 1);
      expect(h.reader.active, 1);
      first.complete([_adapter()]);
      await pumpEventQueue();
      final second = await h.reader.next();
      expect(h.reader.calls, 2);
      await Future<void>.delayed(_shortInterval * 4);
      expect(h.reader.calls, 2);
      second.complete([_adapter()]);
      await h.answerNext([_adapter()]);
      await h.reader.next();
      expect(h.reader.maxActive, 1);
      expect(h.events, hasLength(1));
    });
  });

  group('stop', () {
    test('closes the stream', () async {
      final h = harness(interval: _neverInterval);
      h.monitor.start();
      await h.answerNext([_adapter()]);

      await h.monitor.stop();
      await pumpEventQueue();

      expect(h.done, isTrue);
      expect(h.events, hasLength(1));
    });

    test('a read that ends after stop emits nothing', () async {
      final h = harness();
      h.monitor.start();
      final inFlight = await h.reader.next();

      await h.monitor.stop();
      inFlight.complete([_adapter()]);
      await pumpEventQueue();

      expect(h.events, isEmpty);
      expect(h.done, isTrue);
      expect(h.logs, isEmpty);
    });

    test('a read that fails after stop emits nothing', () async {
      final h = harness();
      h.monitor.start();
      final inFlight = await h.reader.next();

      await h.monitor.stop();
      inFlight.completeError(StateError('late'));
      await pumpEventQueue();

      expect(h.events, isEmpty);
      expect(h.done, isTrue);
    });

    test('no timer keeps reading after stop', () async {
      final h = harness();
      h.monitor.start();
      await h.answerNext([_adapter()]);
      await h.answerNext([_adapter()]);

      await h.monitor.stop();
      final callsAtStop = h.reader.calls;
      for (final pending in [...h.reader._pending]) {
        pending.complete([_adapter()]);
      }
      await Future<void>.delayed(_shortInterval * 6);

      expect(h.reader.calls, callsAtStop);
      expect(h.events, hasLength(1));
    });

    test('stop twice does not throw', () async {
      final h = harness();
      h.monitor.start();
      await h.answerNext([_adapter()]);

      await h.monitor.stop();
      await expectLater(h.monitor.stop(), completes);
      expect(h.done, isTrue);
    });

    test('stop without start closes the stream and never reads', () async {
      final h = harness();

      await h.monitor.stop();
      await pumpEventQueue();
      await Future<void>.delayed(_shortInterval * 3);

      expect(h.done, isTrue);
      expect(h.reader.calls, 0);
    });
  });
}
