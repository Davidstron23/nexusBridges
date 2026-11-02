import 'dart:math' as math;
import 'dart:ui' show Size;

import 'package:nexus_bridges_core/nexus_bridges_core.dart';

import '../../l10n/app_strings.dart';
import '../format.dart';
import '../icons/file_icon.dart' show FileKind, fileKindOf;
import '../theme/components.dart' show ChipTone;
import 'flow_layout.dart';

const int _shortFingerprintLength = 8;

enum LinkState { idle, waiting, asking, active, done }

final class TravelIcon {
  const TravelIcon.folder() : kind = null;

  const TravelIcon.file(FileKind this.kind);

  final FileKind? kind;

  bool get isFolder => kind == null;

  @override
  bool operator ==(Object other) => other is TravelIcon && other.kind == kind;

  @override
  int get hashCode => kind.hashCode;
}

final class LinkView {
  const LinkView({
    this.state = LinkState.idle,
    this.towardsHub = false,
    this.progress = 0,
    this.fileName,
    this.isProgram = false,
    this.isFolder = false,
    this.tracked = false,
  });

  final LinkState state;
  final bool towardsHub;
  final double progress;
  final String? fileName;
  final bool isProgram;
  final bool isFolder;
  final bool tracked;

  TravelIcon get travelIcon => isFolder
      ? const TravelIcon.folder()
      : TravelIcon.file(fileKindOf(fileName ?? '', isProgram: isProgram));

  @override
  bool operator ==(Object other) =>
      other is LinkView &&
      other.state == state &&
      other.towardsHub == towardsHub &&
      other.progress == progress &&
      other.fileName == fileName &&
      other.isProgram == isProgram &&
      other.isFolder == isFolder &&
      other.tracked == tracked;

  @override
  int get hashCode => Object.hash(
    state,
    towardsHub,
    progress,
    fileName,
    isProgram,
    isFolder,
    tracked,
  );
}

double _fraction(int done, int total) {
  if (total <= 0) return 1;
  return (done / total).clamp(0.0, 1.0);
}

LinkView linkFor(
  NodeState state,
  String fingerprint, {
  String? doneFingerprint,
}) {
  final incoming = state.incoming;
  final incomingHere =
      incoming != null && incoming.peerFingerprint == fingerprint;
  if (incomingHere &&
      (incoming.stage == IncomingStage.warning ||
          incoming.stage == IncomingStage.folderQuestion)) {
    return LinkView(
      state: LinkState.asking,
      towardsHub: true,
      fileName: incoming.fileName,
      isProgram: incoming.isProgram,
    );
  }

  final outgoing = state.outgoing;
  final selection = state.selectionProgress;
  final queues = state.queues;
  final carried =
      queues != null &&
      !queues.finished &&
      queues.peerFingerprint == fingerprint &&
      selection != null &&
      selection.selectionId == queues.selectionId &&
      selection.doneBytes > 0;
  final selectionFraction = selection == null
      ? 0.0
      : _fraction(selection.doneBytes, selection.totalBytes);

  if (outgoing != null && outgoing.peerFingerprint == fingerprint) {
    switch (outgoing.phase) {
      case OutgoingPhase.preparing:
      case OutgoingPhase.requesting:
      case OutgoingPhase.waiting:
        if (carried) {
          return LinkView(
            state: LinkState.active,
            progress: selectionFraction,
            fileName: outgoing.fileName,
            isProgram: outgoing.isProgram,
            isFolder: outgoing.isFolder,
            tracked: true,
          );
        }
        return LinkView(
          state: LinkState.waiting,
          fileName: outgoing.fileName,
          isProgram: outgoing.isProgram,
          isFolder: outgoing.isFolder,
        );
      case OutgoingPhase.uploading:
        return LinkView(
          state: LinkState.active,
          progress: selection != null
              ? selectionFraction
              : _fraction(outgoing.sentBytes, outgoing.size),
          fileName: outgoing.fileName,
          isProgram: outgoing.isProgram,
          isFolder: outgoing.isFolder,
          tracked: selection != null,
        );
      case OutgoingPhase.verifying:
        return LinkView(
          state: LinkState.active,
          progress: selection != null ? selectionFraction : 1,
          fileName: outgoing.fileName,
          isProgram: outgoing.isProgram,
          isFolder: outgoing.isFolder,
          tracked: selection != null,
        );
    }
  }

  if (carried) {
    return LinkView(
      state: LinkState.active,
      progress: selectionFraction,
      fileName: selection.currentName,
      isFolder: selection.currentIsFolder,
      tracked: true,
    );
  }

  if (incomingHere) {
    switch (incoming.stage) {
      case IncomingStage.waitingData:
        return LinkView(
          state: LinkState.waiting,
          towardsHub: true,
          fileName: incoming.fileName,
          isProgram: incoming.isProgram,
        );
      case IncomingStage.receiving:
        return LinkView(
          state: LinkState.active,
          towardsHub: true,
          progress: _fraction(incoming.receivedBytes, incoming.size),
          fileName: incoming.fileName,
          isProgram: incoming.isProgram,
          isFolder: incoming.isFolder,
          tracked: true,
        );
      case IncomingStage.verifying:
        return LinkView(
          state: LinkState.active,
          towardsHub: true,
          progress: 1,
          fileName: incoming.fileName,
          isProgram: incoming.isProgram,
          isFolder: incoming.isFolder,
          tracked: true,
        );
      case IncomingStage.warning:
      case IncomingStage.folderQuestion:
      case IncomingStage.ended:
        break;
    }
  }

  if (doneFingerprint == fingerprint) {
    return const LinkView(state: LinkState.done);
  }
  return const LinkView();
}

bool _isReceiving(IncomingTransferView? view) =>
    view != null &&
    (view.stage == IncomingStage.waitingData ||
        view.stage == IncomingStage.receiving ||
        view.stage == IncomingStage.verifying);

String? newlyDone(NodeState? before, NodeState after) {
  if (before == null) return null;
  final sent = after.lastSent;
  if (before.outgoing != null &&
      after.outgoing == null &&
      sent != null &&
      sent.outcome.kind == TransferResultKind.saved) {
    return sent.peerFingerprint;
  }
  final received = after.lastReceived;
  if (_isReceiving(before.incoming) &&
      !_isReceiving(after.incoming) &&
      received != null &&
      received.outcome.kind == TransferResultKind.saved) {
    return received.peerFingerprint;
  }
  return null;
}

final class FlowPeer {
  const FlowPeer({
    required this.fingerprint,
    required this.name,
    required this.deviceType,
    required this.visible,
    required this.chipText,
    required this.chipTone,
    required this.link,
  });

  final String fingerprint;
  final String name;
  final DeviceType? deviceType;
  final bool visible;
  final String chipText;
  final ChipTone chipTone;
  final LinkView link;
}

final class FlowScene {
  const FlowScene({
    required this.layout,
    required this.title,
    required this.count,
    required this.hubName,
    required this.hubCaption,
    required this.peers,
    required this.overflowLabel,
    required this.hovered,
    required this.animates,
  });

  final FlowLayout layout;
  final String title;
  final String count;
  final String hubName;
  final String hubCaption;
  final List<FlowPeer> peers;
  final String? overflowLabel;
  final String? hovered;
  final bool animates;
}

FlowPeer _peerOf(
  DeviceEntry entry,
  NodeState state,
  AppStrings strings,
  String? doneFingerprint,
) {
  final String chipText;
  final ChipTone chipTone;
  if (!entry.visible) {
    chipText = strings.notVisibleLabel;
    chipTone = ChipTone.notVisible;
  } else if (entry.mine) {
    chipText = strings.chipMine;
    chipTone = ChipTone.run;
  } else {
    chipText = strings.chipForeign;
    chipTone = ChipTone.foreign;
  }
  return FlowPeer(
    fingerprint: entry.fingerprint,
    name: entry.displayName,
    deviceType: entry.deviceType,
    visible: entry.visible,
    chipText: chipText,
    chipTone: chipTone,
    link: linkFor(state, entry.fingerprint, doneFingerprint: doneFingerprint),
  );
}

List<FlowPeer> _stableOrder(List<FlowPeer> peers) {
  final busy = [
    for (final p in peers)
      if (p.link.state != LinkState.idle) p,
  ];
  final seen = [
    for (final p in peers)
      if (p.link.state == LinkState.idle && p.visible) p,
  ];
  final rest = [
    for (final p in peers)
      if (p.link.state == LinkState.idle && !p.visible) p,
  ];
  return [...busy, ...seen, ...rest];
}

bool _animatesFor(LinkState state) =>
    state == LinkState.waiting ||
    state == LinkState.asking ||
    state == LinkState.active;

FlowScene buildFlowScene({
  required NodeState state,
  required AppStrings strings,
  required Size size,
  String? doneFingerprint,
  String? hovered,
}) {
  final all = [
    for (final entry in state.entries)
      if (entry.paired) _peerOf(entry, state, strings, doneFingerprint),
  ];
  final layout = layoutFlow(size, all.length);
  final ordered = layout.hidden > 0 ? _stableOrder(all) : all;
  final shown = layout.slots.where((slot) => !slot.overflow).length;
  final peers = ordered.take(shown).toList(growable: false);
  final visibleCount = all.where((peer) => peer.visible).length;
  final shortLength = math.min(
    _shortFingerprintLength,
    state.fingerprint.length,
  );

  return FlowScene(
    layout: layout,
    title: strings.diagramTitle,
    count: strings.diagramCount(all.length, visibleCount),
    hubName: state.deviceName,
    hubCaption: strings.thisDeviceCaption(
      state.fingerprint.substring(0, shortLength),
    ),
    peers: peers,
    overflowLabel: layout.hidden > 0 ? formatOverflow(layout.hidden) : null,
    hovered: hovered,
    animates: peers.any((peer) => _animatesFor(peer.link.state)),
  );
}
