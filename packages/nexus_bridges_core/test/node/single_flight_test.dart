import 'dart:async';

import 'package:nexus_bridges_core/src/network/network.dart';
import 'package:nexus_bridges_core/src/node/reconcile.dart';
import 'package:test/test.dart';

final class _Reads {
  final List<Completer<List<AdapterInfo>>> pending = [];

  int get calls => pending.length;

  Future<List<AdapterInfo>> read() {
    final completer = Completer<List<AdapterInfo>>();
    pending.add(completer);
    return completer.future;
  }
}

void main() {
  group('singleFlight (plan v2.8 point 14, v2.9 point 7)', () {
    test('two calls while the first read is running get the same future and '
        'the function runs once', () async {
      final reads = _Reads();
      final read = singleFlight(reads.read);

      final first = read();
      final second = read();

      expect(second, same(first));
      expect(reads.calls, 1);

      final result = <AdapterInfo>[];
      reads.pending.single.complete(result);
      expect(await first, same(result));
      expect(await second, same(result));
    });

    test('once the read is over, the next call runs the function again and '
        'gets a new future', () async {
      final reads = _Reads();
      final read = singleFlight(reads.read);

      final first = read();
      reads.pending.single.complete(const []);
      await first;
      final second = read();

      expect(reads.calls, 2);
      expect(second, isNot(same(first)));

      final fresh = <AdapterInfo>[];
      reads.pending.last.complete(fresh);
      expect(await second, same(fresh));
    });

    test('a call during the second read joins the second one, not the '
        'first', () async {
      final reads = _Reads();
      final read = singleFlight(reads.read);

      final first = read();
      reads.pending.first.complete(const []);
      await first;
      final second = read();
      final third = read();

      expect(third, same(second));
      expect(reads.calls, 2);
      reads.pending.last.complete(const []);
      await third;
    });

    test('a read that fails gives the same error to everyone waiting and the '
        'next call reads again', () async {
      final reads = _Reads();
      final read = singleFlight(reads.read);

      final first = read();
      final second = read();
      reads.pending.single.completeError(const FormatException('broken'));

      await expectLater(first, throwsA(isA<FormatException>()));
      await expectLater(second, throwsA(isA<FormatException>()));

      final third = read();
      expect(reads.calls, 2);
      expect(third, isNot(same(first)));
      reads.pending.last.complete(const []);
      await third;
    });

    test('a function that throws at once gives a failed future instead of '
        'throwing, and the next call reads again', () async {
      var calls = 0;
      final read = singleFlight(() {
        calls++;
        if (calls == 1) throw StateError('no snapshot');
        return Future.value(const <AdapterInfo>[]);
      });

      late Future<List<AdapterInfo>> first;
      expect(() => first = read(), returnsNormally);
      await expectLater(first, throwsA(isA<StateError>()));

      expect(await read(), isEmpty);
      expect(calls, 2);
    });

    test('each wrapper keeps its own read in flight', () async {
      final a = _Reads();
      final b = _Reads();
      final readA = singleFlight(a.read);
      final readB = singleFlight(b.read);

      final fromA = readA();
      final fromB = readB();

      expect(fromB, isNot(same(fromA)));
      expect(a.calls, 1);
      expect(b.calls, 1);
      a.pending.single.complete(const []);
      b.pending.single.complete(const []);
      await Future.wait([fromA, fromB]);
    });
  });
}
