import '../transfer/transfer.dart'
    show
        DestinationLabel,
        SendDestination,
        SendTarget,
        TransferOutcome,
        TransferResultView;

enum ElementKind { file, folder, missing, other }

final class ElementProbe {
  const ElementProbe({required this.kind, this.size});

  final ElementKind kind;
  final int? size;
}

abstract interface class ElementSender {
  Future<TransferResultView?> send(
    SendTarget target,
    String path,
    SendDestination destination,
  );

  bool get cancelEndsQueue;

  void cancelCurrent();
}

enum SelectionResult {
  started,
  queued,
  otherTargetBusy,
  tooMany,
  empty,
  closed,
}

enum QueueItemState { pending, inProgress, done, notSent }

final class SelectionFinished {
  const SelectionFinished({
    required this.fingerprint,
    required this.selectionId,
    required this.results,
    required this.itemCount,
    required this.delivered,
    required this.bytes,
    required this.destination,
  });

  final String fingerprint;
  final int selectionId;
  final List<TransferResultView> results;
  final int itemCount;
  final int delivered;
  final int bytes;
  final SendDestination destination;
}

final class QueueItemView {
  const QueueItemView({
    required this.id,
    required this.name,
    required this.isFolder,
    required this.isArchive,
    required this.state,
    this.outcome,
    this.problemPath,
    this.destination,
  });

  final String id;
  final String name;
  final bool isFolder;
  final bool isArchive;
  final QueueItemState state;
  final TransferOutcome? outcome;
  final String? problemPath;
  final DestinationLabel? destination;

  @override
  bool operator ==(Object other) =>
      other is QueueItemView &&
      other.id == id &&
      other.name == name &&
      other.isFolder == isFolder &&
      other.isArchive == isArchive &&
      other.state == state &&
      other.outcome == outcome &&
      other.problemPath == problemPath &&
      other.destination == destination;

  @override
  int get hashCode => Object.hash(
    id,
    name,
    isFolder,
    isArchive,
    state,
    outcome,
    problemPath,
    destination,
  );
}

bool _sameItems(List<QueueItemView> a, List<QueueItemView> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

final class SendQueuesView {
  const SendQueuesView({
    required this.selectionId,
    required this.peerFingerprint,
    required this.peerName,
    required this.loose,
    required this.bundles,
    required this.finished,
    required this.delivered,
    required this.total,
    required this.completedBytes,
    required this.pendingKnownBytes,
    required this.currentProbeSize,
  });

  final int selectionId;
  final String peerFingerprint;
  final String? peerName;
  final List<QueueItemView> loose;
  final List<QueueItemView> bundles;
  final bool finished;
  final int delivered;
  final int total;
  final int completedBytes;
  final int pendingKnownBytes;
  final int? currentProbeSize;

  @override
  bool operator ==(Object other) =>
      other is SendQueuesView &&
      other.selectionId == selectionId &&
      other.peerFingerprint == peerFingerprint &&
      other.peerName == peerName &&
      _sameItems(other.loose, loose) &&
      _sameItems(other.bundles, bundles) &&
      other.finished == finished &&
      other.delivered == delivered &&
      other.total == total &&
      other.completedBytes == completedBytes &&
      other.pendingKnownBytes == pendingKnownBytes &&
      other.currentProbeSize == currentProbeSize;

  @override
  int get hashCode => Object.hash(
    selectionId,
    peerFingerprint,
    peerName,
    Object.hashAll(loose),
    Object.hashAll(bundles),
    finished,
    delivered,
    total,
    completedBytes,
    pendingKnownBytes,
    currentProbeSize,
  );
}
