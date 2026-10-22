import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:nexus_bridges_core/nexus_bridges_core.dart';

class AppController extends ChangeNotifier {
  AppController({required this._startNode, required this._loadLanguage});

  final Future<NexusNode> Function() _startNode;
  final Future<String> Function() _loadLanguage;

  NexusNode? _node;
  StreamSubscription<NodeState>? _subscription;
  NodeState? _state;
  String _languageCode = 'en';
  bool _startFailed = false;
  bool _identityWarningDismissed = false;
  bool _closed = false;
  Future<void>? _initializing;
  Future<void>? _shutdown;

  NodeState? get state => _state;

  String get languageCode => _languageCode;

  bool get startFailed => _startFailed;

  bool get identityWarningDismissed => _identityWarningDismissed;

  Future<void> init() {
    final running = _initializing;
    if (running != null) return running;
    return _initializing = _init().whenComplete(() => _initializing = null);
  }

  Future<void> _init() async {
    if (_node != null || _closed) return;
    try {
      _languageCode = await _loadLanguage();
    } catch (_) {
      _languageCode = 'en';
    }
    final NexusNode node;
    try {
      node = await _startNode();
    } catch (_) {
      _startFailed = true;
      notifyListeners();
      return;
    }
    if (_closed) {
      await node.shutdown();
      return;
    }
    _startFailed = false;
    _node = node;
    _state = node.state;
    _subscription = node.states.listen((event) {
      _state = event;
      notifyListeners();
    });
    notifyListeners();
  }

  void dismissIdentityWarning() {
    if (_identityWarningDismissed) return;
    _identityWarningDismissed = true;
    notifyListeners();
  }

  Future<void> decideNetwork(String networkId, NetworkDecision decision) {
    return _node?.decideNetwork(networkId, decision) ?? Future<void>.value();
  }

  void dismissPrompt(String networkId) {
    _node?.dismissPrompt(networkId);
  }

  void askAgain(String networkId) {
    _node?.askAgain(networkId);
  }

  Future<void> rescan() => _node?.rescan() ?? Future<void>.value();

  Future<void> retry() {
    if (_initializing != null) return Future<void>.value();
    if (_startFailed) return init();
    return _node?.retry() ?? Future<void>.value();
  }

  Future<void> shutdown() => _shutdown ??= _shutdownNow();

  Future<void> _shutdownNow() async {
    _closed = true;
    await _initializing;
    await _subscription?.cancel();
    _subscription = null;
    final node = _node;
    _node = null;
    await node?.shutdown();
  }
}
