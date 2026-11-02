import 'package:flutter/foundation.dart';
import 'package:nexus_bridges_core/nexus_bridges_core.dart';

enum ColumnTab { activity, devices }

const double _columnShare = 0.30;
const double _columnMin = 280;
const double _columnMax = 350;
const double _bodyGap = 16;
const double _diagramMin = 420;

double columnWidthFor(double bodyWidth) =>
    clampDouble(bodyWidth * _columnShare, _columnMin, _columnMax);

bool showsDiagram(double bodyWidth) =>
    bodyWidth - _bodyGap - columnWidthFor(bodyWidth) >= _diagramMin;

bool _isActive(IncomingStage stage) =>
    stage == IncomingStage.waitingData ||
    stage == IncomingStage.receiving ||
    stage == IncomingStage.verifying;

bool hasActivity(NodeState state) {
  final incoming = state.incoming;
  return state.outgoing != null ||
      state.queues != null ||
      (incoming != null && _isActive(incoming.stage)) ||
      state.lastSent != null ||
      state.lastReceived != null;
}

bool shouldShowActivity(NodeState? before, NodeState after) {
  final outgoing = after.outgoing;
  final previousOutgoing = before?.outgoing;
  if (outgoing != null &&
      (previousOutgoing == null ||
          previousOutgoing.peerFingerprint != outgoing.peerFingerprint ||
          previousOutgoing.fileName != outgoing.fileName)) {
    return true;
  }
  final queues = after.queues;
  if (queues != null &&
      (before?.queues == null ||
          before?.queues?.selectionId != queues.selectionId)) {
    return true;
  }
  final incoming = after.incoming;
  if (incoming != null &&
      _isActive(incoming.stage) &&
      before?.incoming?.stage != incoming.stage) {
    return true;
  }
  final sent = after.lastSent;
  if (sent != null && sent != before?.lastSent) return true;
  final received = after.lastReceived;
  return received != null && received != before?.lastReceived;
}
