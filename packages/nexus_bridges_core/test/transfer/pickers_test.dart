import 'package:nexus_bridges_core/src/transfer/pickers.dart';
import 'package:test/test.dart';

void main() {
  group('PickerTracker (D-10)', () {
    late Duration now;
    late List<(bool, Duration)> changes;
    late PickerTracker tracker;

    setUp(() {
      now = const Duration(minutes: 7);
      changes = [];
      tracker = PickerTracker(
        clock: () => now,
        onChanged: (open, since) => changes.add((open, since)),
      );
    });

    test('starts closed and closing it then does nothing', () {
      expect(tracker.isOpen, isFalse);
      tracker.close();
      expect(tracker.isOpen, isFalse);
      expect(changes, isEmpty);
    });

    test('opening notes the time once and closing reports it', () {
      tracker.open();
      expect(tracker.isOpen, isTrue);
      expect(changes, [(true, const Duration(minutes: 7))]);
      now += const Duration(seconds: 30);
      tracker.close();
      expect(tracker.isOpen, isFalse);
      expect(changes, [
        (true, const Duration(minutes: 7)),
        (false, const Duration(minutes: 7)),
      ]);
    });

    test('two pickers stay frozen until the last one closes and keep the '
        'first opening time', () {
      tracker.open();
      now += const Duration(seconds: 10);
      tracker.open();
      now += const Duration(seconds: 10);
      tracker.close();
      expect(tracker.isOpen, isTrue);
      expect(changes, hasLength(1));
      now += const Duration(seconds: 10);
      tracker.close();
      expect(tracker.isOpen, isFalse);
      expect(changes.last, (false, const Duration(minutes: 7)));
      tracker.close();
      expect(changes, hasLength(2));
    });

    test('a new opening after closing notes the new time', () {
      tracker.open();
      tracker.close();
      now += const Duration(seconds: 42);
      tracker.open();
      expect(changes.last, (true, const Duration(minutes: 7, seconds: 42)));
    });
  });
}
