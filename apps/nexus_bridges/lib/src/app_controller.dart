import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:nexus_bridges_core/nexus_bridges_core.dart';

bool _alwaysOpen() => true;

class AppController extends ChangeNotifier {
  AppController({
    required this._startNode,
    required this._loadStartup,
    this.settingsOpen = _alwaysOpen,
  });

  final Future<NexusNode> Function() _startNode;
  final Future<StartupSettings> Function() _loadStartup;

  bool Function() settingsOpen;

  NexusNode? _node;
  StreamSubscription<NodeState>? _subscription;
  NodeState? _state;
  String _languageCode = 'en';
  ThemeChoice _theme = ThemeChoice.dark;
  bool _closeToTray = true;
  bool _trayHintShown = false;
  bool _startFailed = false;
  bool _identityWarningDismissed = false;
  bool _closed = false;
  Future<void>? _initializing;
  Future<void>? _shutdown;

  NodeState? get state => _state;

  String get languageCode => _languageCode;

  ThemeChoice get theme => _theme;

  bool get closeToTray => _closeToTray;

  bool get trayHintShown => _trayHintShown;

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
      final startup = await _loadStartup();
      _languageCode = startup.language;
      _theme = startup.theme;
      _closeToTray = startup.closeToTray;
      _trayHintShown = startup.trayHintShown;
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

  Future<void> setLanguage(String code) {
    if (code == _languageCode) return Future<void>.value();
    _languageCode = code;
    notifyListeners();
    return _node?.saveLanguage(code) ?? Future<void>.value();
  }

  Future<void> setTheme(ThemeChoice theme) {
    if (theme == _theme) return Future<void>.value();
    _theme = theme;
    notifyListeners();
    return _node?.saveTheme(theme) ?? Future<void>.value();
  }

  Future<void> setCloseToTray(bool enabled) {
    if (enabled == _closeToTray) return Future<void>.value();
    _closeToTray = enabled;
    notifyListeners();
    return _node?.saveCloseToTray(enabled) ?? Future<void>.value();
  }

  Future<DeviceNameResult> setDeviceName(String? name) async {
    final node = _node;
    if (node == null) return const DeviceNameResult(saved: false);
    return node.setDeviceName(name);
  }

  String? namesakeOf(String candidate) => _node?.namesakeOf(candidate);

  Future<ExclusionOutcome> addExclusion(String raw) async {
    final node = _node;
    if (node == null) return const ExclusionOutcome(saved: false);
    return node.addExclusion(raw);
  }

  Future<void> removeExclusion(String name) {
    return _node?.removeExclusion(name) ?? Future<void>.value();
  }

  Future<void> restoreExclusions() {
    return _node?.restoreExclusions() ?? Future<void>.value();
  }

  Future<FolderChangeResult> changeReceiveFolder() async {
    final node = _node;
    if (node == null) return const FolderChangeBlocked();
    final result = await node.changeReceiveFolder();
    if (result is FolderChangeNeedsConfirmation && !settingsOpen()) {
      node.cancelReceiveFolderChange(result.changeId);
    }
    return result;
  }

  Future<FolderChangeResult> confirmReceiveFolder(String changeId) async {
    final node = _node;
    if (node == null) return const FolderChangeBlocked();
    return node.confirmReceiveFolder(changeId);
  }

  void cancelReceiveFolderChange(String changeId) {
    _node?.cancelReceiveFolderChange(changeId);
  }

  Future<void> stopUsingNetwork(String networkId) {
    return _node?.stopUsingNetwork(networkId) ?? Future<void>.value();
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

  Future<PairRequestResult> pair(String fingerprint) async {
    final node = _node;
    if (node == null) return PairRequestResult.unavailable;
    return node.pair(fingerprint);
  }

  void answerCode({required bool matches}) {
    _node?.answerCode(matches: matches);
  }

  void cancelPairing() {
    _node?.cancelPairing();
  }

  void cancelRequest() {
    _node?.cancelRequest();
  }

  void answerRequest(ReceiverAnswer answer) {
    _node?.answerRequest(answer);
  }

  void dismissPairing() {
    _node?.dismissPairing();
  }

  Future<void> answerReplace(String fingerprint, {required bool replace}) {
    return _node?.answerReplace(fingerprint, replace: replace) ??
        Future<void>.value();
  }

  Future<void> answerMine(String fingerprint, {required bool mine}) {
    return _node?.answerMine(fingerprint, mine: mine) ?? Future<void>.value();
  }

  Future<void> setMine(String fingerprint, {required bool mine}) {
    return _node?.setMine(fingerprint, mine: mine) ?? Future<void>.value();
  }

  Future<SendResult> sendFiles(String fingerprint) async {
    final node = _node;
    if (node == null) return SendResult.unavailable;
    return node.sendFiles(fingerprint);
  }

  Future<SendResult> sendFolders(String fingerprint) async {
    final node = _node;
    if (node == null) return SendResult.unavailable;
    return node.sendFolders(fingerprint);
  }

  Future<SendResult> sendPaths(String fingerprint, List<String> paths) async {
    final node = _node;
    if (node == null) return SendResult.unavailable;
    return node.sendPaths(fingerprint, paths);
  }

  void cancelQueueItem(String itemId) {
    _node?.cancelQueueItem(itemId);
  }

  void removeQueueItem(String itemId) {
    _node?.removeQueueItem(itemId);
  }

  void cancelAllQueued() {
    _node?.cancelAllQueued();
  }

  Future<TrayResult> addToTray(List<String> paths, {int? totalCount}) async {
    final node = _node;
    if (node == null) return TrayResult.unavailable;
    return node.addToTray(paths, totalCount: totalCount);
  }

  void removeFromTray(String itemId) {
    _node?.removeFromTray(itemId);
  }

  void clearTray() {
    _node?.clearTray();
  }

  Future<SendResult> sendTray(String fingerprint) async {
    final node = _node;
    if (node == null) return SendResult.unavailable;
    return node.sendTray(fingerprint);
  }

  Future<void> requestPortal(String fingerprint) async {}

  void cancelSending() {
    _node?.cancelSending();
  }

  void cancelReceiving(String sessionId) {
    _node?.cancelReceiving(sessionId);
  }

  void answerIncoming(String sessionId, {required bool accept}) {
    _node?.answerIncoming(sessionId, accept: accept);
  }

  Future<void> useProposedFolder(String sessionId) {
    return _node?.useProposedFolder(sessionId) ?? Future<void>.value();
  }

  Future<void> chooseOtherFolder(String sessionId) {
    return _node?.chooseOtherFolder(sessionId) ?? Future<void>.value();
  }

  void useFolderAnyway(String sessionId) {
    _node?.useFolderAnyway(sessionId);
  }

  void cancelFolderQuestion(String sessionId) {
    _node?.cancelFolderQuestion(sessionId);
  }

  Future<void> rememberFolderAfterEnd(
    String sessionId, {
    required bool remember,
  }) {
    return _node?.rememberFolderAfterEnd(sessionId, remember: remember) ??
        Future<void>.value();
  }

  void dismissFolderPanel(String sessionId) {
    _node?.dismissFolderPanel(sessionId);
  }

  Future<RevealResult> revealLastReceived() async {
    final node = _node;
    if (node == null) return RevealResult.unavailable;
    return node.revealLastReceived();
  }

  Future<void> unpair(String fingerprint) {
    return _node?.unpair(fingerprint) ?? Future<void>.value();
  }

  Future<void> unignore(String fingerprint) {
    return _node?.unignore(fingerprint) ?? Future<void>.value();
  }

  Future<void> retrySave() => _node?.retrySave() ?? Future<void>.value();

  void dismissNotice(int id) {
    _node?.dismissNotice(id);
  }

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
