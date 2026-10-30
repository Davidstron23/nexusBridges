import 'package:nexus_bridges_core/src/protocol/protocol.dart';
import 'package:nexus_bridges_core/src/transfer/folders.dart'
    show tempFolderName;
import 'package:nexus_bridges_core/src/transfer/manifest.dart';
import 'package:test/test.dart';

const String slash = r'\';

String target(int length) => 'C:$slash${'t' * (length - 3)}';

bool fits(int targetLength, int nameLength, int longest) => folderFitsIn(
  targetPath: target(targetLength),
  folderName: 'n' * nameLength,
  longest: longest,
);

void main() {
  group('E436, RF-270: folderFitsIn', () {
    test('the temporary name used by the budget is 22 units long', () {
      expect(tempFolderName.length, 22);
      expect(Limits.folderDirPathReserve, 12);
      expect(Limits.folderNameMargin, 4);
    });

    test('final destination with entries: 259 fits and 260 does not', () {
      expect(fits(20, 100, 133), isTrue);
      expect(fits(20, 100, 134), isFalse);
      expect(fits(20, 101, 132), isTrue);
      expect(fits(20, 101, 133), isFalse);
      expect(fits(21, 100, 132), isTrue);
      expect(fits(21, 100, 133), isFalse);
    });

    test('temporary folder with entries: 259 fits and 260 does not', () {
      expect(fits(100, 10, 108), isTrue);
      expect(fits(100, 10, 109), isFalse);
      expect(fits(101, 10, 107), isTrue);
      expect(fits(101, 10, 108), isFalse);
    });

    test('the temporary budget binds before the final one for short names', () {
      expect(fits(20, 10, 188), isTrue);
      expect(fits(20, 10, 189), isFalse);
    });

    test('without entries the folder itself must fit in the final path', () {
      expect(fits(20, 222, 0), isTrue);
      expect(fits(20, 223, 0), isFalse);
    });

    test('without entries the temporary folder must fit too', () {
      expect(fits(197, 1, 0), isTrue);
      expect(fits(198, 1, 0), isFalse);
    });

    test('a folder deep in the tree is counted with the reserve', () {
      ManifestBuilder folderOf(int units) =>
          ManifestBuilder()..addFolder(0, 'f' * units);

      final fitting = folderOf(121).build();
      final tooLong = folderOf(122).build();

      expect(fitting.longest, 121 + Limits.folderDirPathReserve);
      expect(tooLong.longest, 122 + Limits.folderDirPathReserve);
      expect(fits(20, 100, fitting.longest), isTrue);
      expect(fits(20, 100, tooLong.longest), isFalse);
    });

    test('a trailing backslash on the target does not count', () {
      final plain = folderFitsIn(
        targetPath: target(20),
        folderName: 'n' * 100,
        longest: 133,
      );
      final slashed = folderFitsIn(
        targetPath: '${target(20)}$slash',
        folderName: 'n' * 100,
        longest: 133,
      );

      expect(plain, isTrue);
      expect(slashed, isTrue);
      expect(
        folderFitsIn(
          targetPath: '${target(20)}$slash',
          folderName: 'n' * 100,
          longest: 134,
        ),
        isFalse,
      );
    });

    test('a drive root with its backslash counts as without it', () {
      for (final longest in [0, 5, 100, 200]) {
        expect(
          folderFitsIn(targetPath: r'C:\', folderName: 'abc', longest: longest),
          folderFitsIn(targetPath: 'C:', folderName: 'abc', longest: longest),
        );
      }
    });
  });

  group('E436, RF-270: maxFolderNameUnits', () {
    test('with entries it is 259 - T - 2 - longest', () {
      expect(
        maxFolderNameUnits(targetPath: target(20), longest: 100),
        259 - 20 - 2 - 100,
      );
      expect(
        maxFolderNameUnits(targetPath: target(50), longest: 150),
        259 - 50 - 2 - 150,
      );
    });

    test('with no entries it is 259 - T - 1 - reserve', () {
      expect(
        maxFolderNameUnits(targetPath: target(20), longest: 0),
        259 - 20 - 1 - Limits.folderDirPathReserve,
      );
    });

    test('it never passes 255 units', () {
      expect(maxFolderNameUnits(targetPath: 'C', longest: 1), 255);
      expect(maxFolderNameUnits(targetPath: '', longest: 1), 255);
      expect(maxFolderNameUnits(targetPath: 'C:', longest: 1), 254);
    });

    test('it never goes below zero', () {
      expect(maxFolderNameUnits(targetPath: target(250), longest: 100), 0);
      expect(maxFolderNameUnits(targetPath: target(255), longest: 0), 0);
    });

    test('a name of that many units ends exactly at 259 once placed', () {
      for (final longest in [1, 20, 80, 150]) {
        for (final length in [4, 25, 60, 90]) {
          final units = maxFolderNameUnits(
            targetPath: target(length),
            longest: longest,
          );
          expect(length + 1 + units + 1 + longest, 259);
        }
      }
    });

    test('the trailing backslash of the target is ignored', () {
      expect(
        maxFolderNameUnits(targetPath: '${target(20)}$slash', longest: 100),
        maxFolderNameUnits(targetPath: target(20), longest: 100),
      );
    });
  });
}
