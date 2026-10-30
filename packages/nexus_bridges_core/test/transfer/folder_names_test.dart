import 'package:nexus_bridges_core/src/protocol/protocol.dart';
import 'package:nexus_bridges_core/src/transfer/names.dart';
import 'package:test/test.dart';

final String emoji = String.fromCharCode(0x1F600);

bool hasLoneSurrogate(String text) {
  final units = text.codeUnits;
  for (var i = 0; i < units.length; i++) {
    final unit = units[i];
    if (unit >= 0xD800 && unit <= 0xDBFF) {
      final next = i + 1 < units.length ? units[i + 1] : 0;
      if (next < 0xDC00 || next > 0xDFFF) return true;
      i++;
    } else if (unit >= 0xDC00 && unit <= 0xDFFF) {
      return true;
    }
  }
  return false;
}

void main() {
  group('E439, RF-279: candidateFolderName', () {
    test('n = 0 keeps the name as it is', () {
      expect(candidateFolderName('Proyecto', 0), 'Proyecto');
      expect(candidateFolderName('mi.proyecto', 0), 'mi.proyecto');
    });

    test('the suffix goes at the end, without splitting an extension', () {
      expect(candidateFolderName('Proyecto', 1), 'Proyecto (1)');
      expect(candidateFolderName('mi.proyecto', 2), 'mi.proyecto (2)');
      expect(candidateFolderName('a.tar.gz', 3), 'a.tar.gz (3)');
      expect(candidateFolderName('.git', 1), '.git (1)');
      expect(candidateFolderName('Proyecto', 9999), 'Proyecto (9999)');
    });

    test('a name that fits exactly is not cut', () {
      final name = 'a' * (Limits.maxFileNameUnits - 4);
      final candidate = candidateFolderName(name, 1)!;
      expect(candidate, '$name (1)');
      expect(candidate.length, Limits.maxFileNameUnits);
    });

    test('a long name is cut to 255 units, suffix included', () {
      final candidate = candidateFolderName('a' * 300, 1)!;
      expect(candidate, '${'a' * 251} (1)');
      expect(candidate.length, Limits.maxFileNameUnits);
      final wide = candidateFolderName('b' * 300, 1234)!;
      expect(wide, '${'b' * 248} (1234)');
      expect(wide.length, Limits.maxFileNameUnits);
    });

    test('the cut never splits a surrogate pair', () {
      final name = '${'a' * 250}$emoji${'b' * 10}';
      final candidate = candidateFolderName(name, 1)!;
      expect(candidate, '${'a' * 250} (1)');
      expect(hasLoneSurrogate(candidate), isFalse);
      final fits = candidateFolderName('${'a' * 249}$emoji${'b' * 10}', 1)!;
      expect(fits, '${'a' * 249}$emoji (1)');
      expect(fits.length, Limits.maxFileNameUnits);
      expect(hasLoneSurrogate(fits), isFalse);
      for (var pad = 240; pad < 256; pad++) {
        final mixed = '${'x' * pad}${emoji * 20}';
        final cut = candidateFolderName(mixed, 7)!;
        expect(cut.length, lessThanOrEqualTo(Limits.maxFileNameUnits));
        expect(hasLoneSurrogate(cut), isFalse, reason: 'pad $pad');
        expect(cut.endsWith(' (7)'), isTrue);
      }
    });

    test('the cut leaves no trailing dot or space before the suffix', () {
      final dot = candidateFolderName('${'a' * 250}.${'b' * 20}', 1)!;
      expect(dot, '${'a' * 250} (1)');
      final spaces = candidateFolderName('${'a' * 249}  ${'c' * 20}', 1)!;
      expect(spaces, '${'a' * 249} (1)');
      final mixed = candidateFolderName('${'a' * 248}. .${'d' * 20}', 1)!;
      expect(mixed, '${'a' * 248} (1)');
      for (final candidate in [dot, spaces, mixed]) {
        final kept = candidate.substring(0, candidate.length - 4);
        expect(kept.endsWith('.'), isFalse);
        expect(kept.endsWith(' '), isFalse);
      }
    });

    test('nothing left after the cut gives null', () {
      expect(candidateFolderName('.' * 300, 1), isNull);
      expect(candidateFolderName(' ' * 300, 1), isNull);
    });
  });
}
