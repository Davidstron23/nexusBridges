import '../pairing/pairing.dart' show PeerRelation;
import '../protocol/protocol.dart' show Limits;

enum ReceiveStep { warn, askFolder, accept }

ReceiveStep nextReceiveStep({
  required bool warned,
  required bool folderReady,
  required PeerRelation relation,
}) {
  if (!warned && relation == PeerRelation.foreign) return ReceiveStep.warn;
  if (!folderReady) return ReceiveStep.askFolder;
  return ReceiveStep.accept;
}

bool hasRoomFor(int? freeBytes, int size) =>
    freeBytes == null || freeBytes >= size + Limits.transferSpaceMargin;
