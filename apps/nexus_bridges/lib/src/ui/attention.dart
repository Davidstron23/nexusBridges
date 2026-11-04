import 'package:flutter/foundation.dart';
import 'package:nexus_bridges_core/nexus_bridges_core.dart';

import '../app_controller.dart';

Set<String> attentionItemsOf(NodeState? state) {
  if (state == null) return const {};
  final items = <String>{};
  final incoming = state.incoming;
  if (incoming != null) {
    switch (incoming.stage) {
      case IncomingStage.warning:
        items.add('warning:${incoming.sessionId}');
      case IncomingStage.folderQuestion:
        final folder = incoming.folder;
        if (folder != null) {
          items.add('folder:${incoming.sessionId}:${folder.kind.name}');
        }
      case IncomingStage.waitingData ||
          IncomingStage.receiving ||
          IncomingStage.verifying ||
          IncomingStage.ended:
        break;
    }
  }
  final pairing = state.pairing;
  if (pairing != null &&
      pairing.role == PairingRole.receiver &&
      pairing.phase == PairingPhase.comparing &&
      pairing.outcome == null) {
    items.add('pairing:${pairing.peerFingerprint}');
  }
  return items;
}

final class AttentionWatcher extends ChangeNotifier {
  AttentionWatcher(AppController controller) : _controller = controller {
    _known = attentionItemsOf(controller.state);
    controller.addListener(_onChanged);
  }

  final AppController _controller;
  late Set<String> _known;
  int _tick = 0;
  bool _disposed = false;

  int get tick => _tick;

  void _onChanged() {
    final current = attentionItemsOf(_controller.state);
    final fresh = current.any((item) => !_known.contains(item));
    _known = current;
    if (!fresh) return;
    _tick++;
    notifyListeners();
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _controller.removeListener(_onChanged);
    super.dispose();
  }
}
