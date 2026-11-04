import 'dart:math';

import '../transfer/transfer.dart' show TransferOutcome;

const List<String> _archiveSuffixes = [
  '.zip',
  '.rar',
  '.7z',
  '.tar',
  '.gz',
  '.tgz',
  '.bz2',
  '.xz',
  '.zst',
  '.cab',
];

bool isArchiveName(String name) {
  final lower = name.toLowerCase();
  return _archiveSuffixes.any(lower.endsWith);
}

bool continuesAfter(TransferOutcome outcome) => switch (outcome) {
  TransferOutcome.saved ||
  TransferOutcome.savedWithoutMark ||
  TransferOutcome.invalidName ||
  TransferOutcome.blockedType ||
  TransferOutcome.shortcut ||
  TransferOutcome.wholeDrive ||
  TransferOutcome.protectedData ||
  TransferOutcome.notFound ||
  TransferOutcome.unreadable ||
  TransferOutcome.damaged ||
  TransferOutcome.pathTooLong ||
  TransferOutcome.tooManyEntries ||
  TransferOutcome.tooDeep ||
  TransferOutcome.tooLargeForPeer ||
  TransferOutcome.cancelledHere ||
  TransferOutcome.noFreeName ||
  TransferOutcome.tooManyBytes ||
  TransferOutcome.incompatible => true,
  TransferOutcome.declined ||
  TransferOutcome.unanswered ||
  TransferOutcome.noFolder ||
  TransferOutcome.busy ||
  TransferOutcome.noSpace ||
  TransferOutcome.noContact ||
  TransferOutcome.unpaired ||
  TransferOutcome.cancelledByPeer ||
  TransferOutcome.uploadNotStarted ||
  TransferOutcome.connectionLost ||
  TransferOutcome.idle ||
  TransferOutcome.writeFailed ||
  TransferOutcome.diskFull ||
  TransferOutcome.markFailed ||
  TransferOutcome.moveFailed ||
  TransferOutcome.interfaceDown ||
  TransferOutcome.unconfirmed ||
  TransferOutcome.unexpectedData ||
  TransferOutcome.defaultFolderOnly ||
  TransferOutcome.destinationUnavailable ||
  TransferOutcome.destinationMissing ||
  TransferOutcome.destinationLost ||
  TransferOutcome.shareRemoved ||
  TransferOutcome.peerMarkedForeign => false,
};

final RegExp _driveRoot = RegExp(r'^[A-Za-z]:[\\/]*$');

bool isDriveRootPath(String path) => _driveRoot.hasMatch(path);

String baseNameOfPath(String path) {
  var end = path.length;
  while (end > 0 && (path[end - 1] == r'\' || path[end - 1] == '/')) {
    end--;
  }
  if (end == 0) return path;
  final trimmed = path.substring(0, end);
  final cut = max(trimmed.lastIndexOf(r'\'), trimmed.lastIndexOf('/'));
  return trimmed.substring(cut + 1);
}
