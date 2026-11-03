import 'package:flutter_test/flutter_test.dart';
import 'package:nexus_bridges/src/drop/drop_events.dart';

import 'fake_drop_events.dart';

Future<void> _call(String method, [Object? arguments]) =>
    sendDropCall(method, arguments);

Future<List<DropEvent>> _collect(
  MethodChannelDropEvents events,
  Future<void> Function() act,
) async {
  final received = <DropEvent>[];
  final subscription = events.events.listen(received.add);
  await act();
  await Future<void>.delayed(Duration.zero);
  await subscription.cancel();
  return received;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('MethodChannelDropEvents', () {
    test('enter, over and leave arrive as events with the position', () async {
      final events = MethodChannelDropEvents(devicePixelRatio: () => 1);
      final received = await _collect(events, () async {
        await _call('enter', {'x': 10, 'y': 20});
        await _call('over', {'x': 11.5, 'y': 22.5});
        await _call('leave');
      });

      expect(received, hasLength(3));
      expect((received[0] as DropEnter).position, const Offset(10, 20));
      expect((received[1] as DropOver).position, const Offset(11.5, 22.5));
      expect(received[2], isA<DropLeave>());
    });

    test('the physical pixels of the client become logical pixels', () async {
      final events = MethodChannelDropEvents(devicePixelRatio: () => 1.5);
      final received = await _collect(events, () async {
        await _call('enter', {'x': 300, 'y': 150});
        await _call('drop', {
          'x': 600,
          'y': 300,
          'count': 1,
          'paths': ['C:\\a.txt'],
        });
      });

      expect((received[0] as DropEnter).position, const Offset(200, 100));
      expect((received[1] as DropDone).position, const Offset(400, 200));
    });

    test('a drop carries the paths and the real count', () async {
      final events = MethodChannelDropEvents(devicePixelRatio: () => 1);
      final received = await _collect(events, () async {
        await _call('drop', {
          'x': 5,
          'y': 6,
          'count': 2500,
          'paths': [for (var i = 0; i < 1001; i++) 'C:\\f$i'],
        });
      });

      final done = received.single as DropDone;
      expect(done.paths, hasLength(1001));
      expect(done.paths.first, 'C:\\f0');
      expect(done.count, 2500);
    });

    test('more paths than the cap are cut to 1001', () async {
      final events = MethodChannelDropEvents(devicePixelRatio: () => 1);
      final received = await _collect(events, () async {
        await _call('drop', {
          'x': 5,
          'y': 6,
          'count': 1500,
          'paths': [for (var i = 0; i < 1500; i++) 'C:\\f$i'],
        });
      });

      expect((received.single as DropDone).paths, hasLength(1001));
    });

    test('malformed events are ignored', () async {
      final events = MethodChannelDropEvents(devicePixelRatio: () => 1);
      final received = await _collect(events, () async {
        await _call('enter');
        await _call('enter', {'x': 'a', 'y': 2});
        await _call('over', {'x': 1});
        await _call('over', {'x': double.nan, 'y': 1});
        await _call('over', 'text');
        await _call('drop', {'x': 1, 'y': 2});
        await _call('drop', {'x': 1, 'y': 2, 'count': 1, 'paths': 'C:\\a'});
        await _call('drop', {
          'x': 1,
          'y': 2,
          'count': 1,
          'paths': ['C:\\a', 3],
        });
        await _call('drop', {
          'x': 1,
          'y': 2,
          'count': 1,
          'paths': ['C:\\a', ''],
        });
        await _call('drop', {'x': 1, 'y': 2, 'count': 1, 'paths': <String>[]});
        await _call('drop', {
          'x': 1,
          'y': 2,
          'count': 1,
          'paths': ['C:\\a', 'C:\\b'],
        });
        await _call('drop', {
          'x': 1,
          'y': 2,
          'count': 'two',
          'paths': ['C:\\a'],
        });
        await _call('unknown', {'x': 1, 'y': 2});
      });

      expect(received, isEmpty);
    });

    test('a broken pixel ratio falls back to 1', () async {
      final events = MethodChannelDropEvents(devicePixelRatio: () => 0);
      final received = await _collect(events, () async {
        await _call('enter', {'x': 30, 'y': 40});
      });

      expect((received.single as DropEnter).position, const Offset(30, 40));
    });
  });
}
