import 'package:nexus_bridges_core/src/outbox/outbox.dart';
import 'package:nexus_bridges_core/src/transfer/transfer.dart'
    show TransferOutcome;
import 'package:test/test.dart';

const Set<TransferOutcome> continuing = {
  TransferOutcome.saved,
  TransferOutcome.savedWithoutMark,
  TransferOutcome.invalidName,
  TransferOutcome.blockedType,
  TransferOutcome.shortcut,
  TransferOutcome.wholeDrive,
  TransferOutcome.protectedData,
  TransferOutcome.notFound,
  TransferOutcome.unreadable,
  TransferOutcome.damaged,
  TransferOutcome.pathTooLong,
  TransferOutcome.tooManyEntries,
  TransferOutcome.tooDeep,
  TransferOutcome.tooLargeForPeer,
  TransferOutcome.cancelledHere,
  TransferOutcome.noFreeName,
  TransferOutcome.tooManyBytes,
  TransferOutcome.incompatible,
};

const Set<TransferOutcome> stopping = {
  TransferOutcome.declined,
  TransferOutcome.unanswered,
  TransferOutcome.noFolder,
  TransferOutcome.busy,
  TransferOutcome.noSpace,
  TransferOutcome.noContact,
  TransferOutcome.unpaired,
  TransferOutcome.cancelledByPeer,
  TransferOutcome.uploadNotStarted,
  TransferOutcome.connectionLost,
  TransferOutcome.idle,
  TransferOutcome.writeFailed,
  TransferOutcome.diskFull,
  TransferOutcome.markFailed,
  TransferOutcome.moveFailed,
  TransferOutcome.interfaceDown,
  TransferOutcome.unconfirmed,
  TransferOutcome.unexpectedData,
  TransferOutcome.defaultFolderOnly,
  TransferOutcome.destinationUnavailable,
  TransferOutcome.destinationMissing,
  TransferOutcome.destinationLost,
  TransferOutcome.shareRemoved,
  TransferOutcome.peerMarkedForeign,
};

void main() {
  group('E507: continuesAfter follows the DP-15 table (RF-298)', () {
    test('the table covers every outcome exactly once', () {
      expect(continuing.intersection(stopping), isEmpty);
      expect(
        continuing.union(stopping),
        TransferOutcome.values.toSet(),
        reason: 'a new TransferOutcome needs its row in the DP-15 table',
      );
    });

    for (final outcome in continuing) {
      test('the queue goes on after ${outcome.name}', () {
        expect(continuesAfter(outcome), isTrue);
      });
    }

    for (final outcome in stopping) {
      test('the queue stops after ${outcome.name}', () {
        expect(continuesAfter(outcome), isFalse);
      });
    }
  });

  group('isArchiveName (RF-292, D-15)', () {
    const archives = [
      'a.zip',
      'a.rar',
      'a.7z',
      'a.tar',
      'a.gz',
      'a.tgz',
      'a.bz2',
      'a.xz',
      'a.zst',
      'a.cab',
    ];

    for (final name in archives) {
      test('$name is an archive', () {
        expect(isArchiveName(name), isTrue);
      });
    }

    test('the suffix is compared without case', () {
      expect(isArchiveName('PROJECT.ZIP'), isTrue);
      expect(isArchiveName('Backup.7Z'), isTrue);
      expect(isArchiveName('logs.Tar.Gz'), isTrue);
    });

    test('a double suffix ending in an archive one is an archive', () {
      expect(isArchiveName('source.tar.gz'), isTrue);
      expect(isArchiveName('data.tar.zst'), isTrue);
    });

    test('other names are not archives', () {
      expect(isArchiveName('notes.txt'), isFalse);
      expect(isArchiveName('zip'), isFalse);
      expect(isArchiveName('archive.zipx'), isFalse);
      expect(isArchiveName('a.zip.txt'), isFalse);
      expect(isArchiveName('song.mp3'), isFalse);
      expect(isArchiveName('app.exe'), isFalse);
      expect(isArchiveName('Carpeta'), isFalse);
      expect(isArchiveName(''), isFalse);
    });
  });
}
