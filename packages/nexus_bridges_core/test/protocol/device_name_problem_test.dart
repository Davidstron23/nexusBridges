import 'package:nexus_bridges_core/src/protocol/protocol.dart';
import 'package:test/test.dart';

const String _grin = '\u{1F600}';
const String _family = '\u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467}';
const String _redHeart = '\u{2764}\u{FE0F}';
const String _plainHeart = '\u{2764}';
const String _acute = '\u{301}';

void main() {
  group('E800: deviceNameProblem (S1, RF-508)', () {
    test('an empty name is empty', () {
      expect(deviceNameProblem(''), DeviceNameProblem.empty);
    });

    test('64 characters pass and 65 are too long', () {
      expect(deviceNameProblem('a' * 64), isNull);
      expect(deviceNameProblem('a' * 65), DeviceNameProblem.tooLong);
    });

    test('64 emojis with surrogate pairs pass, because characters are counted '
        'and not UTF-16 units, and 65 are too long (DA-8)', () {
      final sixtyFour = _grin * 64;
      expect(sixtyFour.length, 128);
      expect(deviceNameProblem(sixtyFour), isNull);
      expect(deviceNameProblem(_grin * 65), DeviceNameProblem.tooLong);
    });

    for (final MapEntry(key: label, value: character) in {
      'U+202E (right-to-left override)': '\u{202E}',
      'U+200B (zero width space)': '\u{200B}',
      'U+0007 (bell)': '\u0007',
      'U+00AD (soft hyphen)': '\u{AD}',
      'U+2800 (braille blank)': '\u{2800}',
      'U+200D (zero width joiner)': '\u{200D}',
      'U+FE0F (variation selector)': '\u{FE0F}',
      'U+0009 (tab)': '\u0009',
      'U+FEFF (byte order mark)': '\u{FEFF}',
    }.entries) {
      test('a name with $label has invalid characters', () {
        expect(
          deviceNameProblem('PC${character}David'),
          DeviceNameProblem.invalidCharacters,
        );
        expect(
          deviceNameProblem('PC David$character'),
          DeviceNameProblem.invalidCharacters,
        );
      });
    }

    test('a name made only of an invisible character has invalid characters, '
        'it is not empty (the caller only trims spaces)', () {
      expect(
        deviceNameProblem('\u{200B}'),
        DeviceNameProblem.invalidCharacters,
      );
      expect(
        deviceNameProblem('\u{2800}'),
        DeviceNameProblem.invalidCharacters,
      );
    });

    test('a letter with 5 combining marks has invalid characters and with 4 '
        'it passes', () {
      expect(
        deviceNameProblem('PC e${_acute * 5}'),
        DeviceNameProblem.invalidCharacters,
      );
      expect(deviceNameProblem('PC e${_acute * 4}'), isNull);
    });

    test('combined emojis are rejected and a plain emoji passes (D-c)', () {
      expect(deviceNameProblem(_family), DeviceNameProblem.invalidCharacters);
      expect(
        deviceNameProblem('PC $_family'),
        DeviceNameProblem.invalidCharacters,
      );
      expect(deviceNameProblem(_redHeart), DeviceNameProblem.invalidCharacters);
      expect(deviceNameProblem(_plainHeart), isNull);
      expect(deviceNameProblem('PC $_grin'), isNull);
    });

    for (final MapEntry(key: label, value: character) in {
      'a lone high surrogate U+D800': '\u{D800}',
      'a lone low surrogate U+DC00': '\u{DC00}',
      'U+FFF9 (interlinear annotation anchor)': '\u{FFF9}',
      'U+FFFB (interlinear annotation terminator)': '\u{FFFB}',
      'U+0600 (Arabic number sign)': '\u{600}',
      'U+110BD (Kaithi number sign)': '\u{110BD}',
    }.entries) {
      test('B-1: a name with $label has invalid characters', () {
        expect(
          deviceNameProblem('Desk${character}PC'),
          DeviceNameProblem.invalidCharacters,
        );
        expect(
          deviceNameProblem('Desk PC$character'),
          DeviceNameProblem.invalidCharacters,
        );
      });
    }

    test('B-1: a well formed surrogate pair still passes and the input '
        'sanitizer is untouched', () {
      expect(deviceNameProblem('Desk${_grin}PC'), isNull);
      expect(sanitizeDisplayName('Desk\u{FFF9}PC'), 'Desk\u{FFF9}PC');
    });

    test('ordinary names pass', () {
      for (final name in [
        'PC David',
        'Port\u{E1}til de David',
        'ROG Ally',
        'a',
        'PC  con  dos espacios',
        '\u{D1}and\u{FA} 2',
      ]) {
        expect(deviceNameProblem(name), isNull, reason: name);
      }
    });

    test('the length is checked before the characters: 65 characters with a '
        'U+202E are too long', () {
      expect(
        deviceNameProblem('\u{202E}${'a' * 64}'),
        DeviceNameProblem.tooLong,
      );
    });

    test('whatever passes is exactly what the sanitizer of the 002 keeps, so '
        'what is announced is what was written', () {
      for (final name in [
        'PC David',
        _grin * 64,
        'PC e${_acute * 4}',
        _plainHeart,
        'a' * 64,
      ]) {
        expect(deviceNameProblem(name), isNull, reason: name);
        expect(sanitizeDisplayName(name), name, reason: name);
      }
    });

    test('Limits.renameCheckInterval is 5 seconds', () {
      expect(Limits.renameCheckInterval, const Duration(seconds: 5));
    });
  });
}
