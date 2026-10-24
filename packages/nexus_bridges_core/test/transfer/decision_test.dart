import 'package:nexus_bridges_core/src/pairing/pairing.dart';
import 'package:nexus_bridges_core/src/protocol/protocol.dart';
import 'package:nexus_bridges_core/src/transfer/decision.dart';
import 'package:test/test.dart';

const int gib = 1073741824;

void main() {
  group('E10, RF-142, RF-150, RF-151, RF-152, RF-220, RF-241: next step', () {
    ReceiveStep expected({
      required bool warned,
      required bool folderReady,
      required PeerRelation relation,
    }) {
      if (!warned && relation == PeerRelation.foreign) return ReceiveStep.warn;
      if (!folderReady) return ReceiveStep.askFolder;
      return ReceiveStep.accept;
    }

    for (final relation in PeerRelation.values) {
      for (final warned in [false, true]) {
        for (final folderReady in [false, true]) {
          final step = expected(
            warned: warned,
            folderReady: folderReady,
            relation: relation,
          );
          test('${relation.name}, warned $warned, folder ready $folderReady '
              'gives ${step.name}', () {
            expect(
              nextReceiveStep(
                warned: warned,
                folderReady: folderReady,
                relation: relation,
              ),
              step,
            );
          });
        }
      }
    }

    test('a "mine" with the folder ready is accepted without a warning '
        '(RF-150)', () {
      expect(
        nextReceiveStep(
          warned: false,
          folderReady: true,
          relation: PeerRelation.mine,
        ),
        ReceiveStep.accept,
      );
    });

    test('a "mine" without a folder is asked for the folder and never '
        'warned (RF-152)', () {
      expect(
        nextReceiveStep(
          warned: false,
          folderReady: false,
          relation: PeerRelation.mine,
        ),
        ReceiveStep.askFolder,
      );
    });

    test('a "foreign" without a folder sees the warning first and the '
        'folder question after it (RF-241)', () {
      expect(
        nextReceiveStep(
          warned: false,
          folderReady: false,
          relation: PeerRelation.foreign,
        ),
        ReceiveStep.warn,
      );
      expect(
        nextReceiveStep(
          warned: true,
          folderReady: false,
          relation: PeerRelation.foreign,
        ),
        ReceiveStep.askFolder,
      );
    });

    test('a "mine" that becomes "foreign" after choosing the folder is warned '
        'then (RF-220, RF-221)', () {
      expect(
        nextReceiveStep(
          warned: false,
          folderReady: false,
          relation: PeerRelation.mine,
        ),
        ReceiveStep.askFolder,
      );
      expect(
        nextReceiveStep(
          warned: false,
          folderReady: true,
          relation: PeerRelation.foreign,
        ),
        ReceiveStep.warn,
      );
    });

    test('a "foreign" never reaches accept without being warned', () {
      for (final folderReady in [false, true]) {
        expect(
          nextReceiveStep(
            warned: false,
            folderReady: folderReady,
            relation: PeerRelation.foreign,
          ),
          isNot(ReceiveStep.accept),
        );
      }
    });
  });

  group('E12, RF-149: room for the file (D-9)', () {
    test('the margin is 1 GiB', () {
      expect(Limits.transferSpaceMargin, gib);
    });

    test('free space of size plus 1 GiB fits and one byte less does not', () {
      const size = 123456;
      expect(hasRoomFor(size + gib, size), isTrue);
      expect(hasRoomFor(size + gib - 1, size), isFalse);
    });

    test('a 0 byte file still needs the margin', () {
      expect(hasRoomFor(gib, 0), isTrue);
      expect(hasRoomFor(gib - 1, 0), isFalse);
      expect(hasRoomFor(0, 0), isFalse);
    });

    test('an unknown free space fits (D-9)', () {
      expect(hasRoomFor(null, 0), isTrue);
      expect(hasRoomFor(null, Limits.maxTransferSize), isTrue);
    });

    test('a size of 2^53 - 1 does not overflow', () {
      const size = 9007199254740991;
      expect(Limits.maxTransferSize, size);
      expect(hasRoomFor(size + gib, size), isTrue);
      expect(hasRoomFor(size + gib - 1, size), isFalse);
      expect(hasRoomFor(9223372036854775807, size), isTrue);
      expect(hasRoomFor(size, size), isFalse);
    });
  });
}
