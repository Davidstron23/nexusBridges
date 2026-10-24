import 'package:nexus_bridges_core/src/identity/identity.dart';
import 'package:test/test.dart';

void main() {
  group('shortFingerprint', () {
    test('the first 8 characters, and a shorter text as it is', () {
      expect(shortFingerprint('1A2B3C4D'.padRight(64, '0')), '1A2B3C4D');
      expect(shortFingerprint('ABC'), 'ABC');
      expect(shortFingerprint('12345678'), '12345678');
    });
  });
}
