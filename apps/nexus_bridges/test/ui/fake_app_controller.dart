import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nexus_bridges/src/app_controller.dart';
import 'package:nexus_bridges/src/drop/drop_events.dart';
import 'package:nexus_bridges/src/l10n/app_strings.dart';
import 'package:nexus_bridges/src/ui/attention.dart';
import 'package:nexus_bridges/src/ui/home_screen.dart';
import 'package:nexus_bridges/src/ui/network_prompt_dialog.dart';
import 'package:nexus_bridges/src/ui/pairing_dialogs.dart';
import 'package:nexus_bridges/src/ui/settings/settings_controller.dart';
import 'package:nexus_bridges/src/ui/theme/app_theme.dart';
import 'package:nexus_bridges_core/nexus_bridges_core.dart';

const List<String> languageCodes = ['es', 'en'];

class FakeAppController extends AppController {
  FakeAppController({
    NodeState? state,
    bool startFailed = false,
    String languageCode = 'en',
    ThemeChoice theme = ThemeChoice.dark,
    bool closeToTray = true,
  }) : _fakeState = state,
       _fakeStartFailed = startFailed,
       _fakeLanguage = languageCode,
       _fakeTheme = theme,
       _fakeCloseToTray = closeToTray,
       super(
         startNode: () async => throw StateError('not used by widget tests'),
         loadStartup: () async => const StartupSettings(language: 'en'),
       );

  NodeState? _fakeState;
  bool _fakeStartFailed;
  String _fakeLanguage;
  ThemeChoice _fakeTheme;
  bool _fakeCloseToTray;
  final List<String> calls = [];

  @override
  String get languageCode => _fakeLanguage;

  @override
  ThemeChoice get theme => _fakeTheme;

  @override
  bool get closeToTray => _fakeCloseToTray;

  @override
  Future<void> setLanguage(String code) async {
    calls.add('setLanguage $code');
    if (code == _fakeLanguage) return;
    _fakeLanguage = code;
    notifyListeners();
  }

  @override
  Future<void> setTheme(ThemeChoice theme) async {
    calls.add('setTheme ${theme.name}');
    if (theme == _fakeTheme) return;
    _fakeTheme = theme;
    notifyListeners();
  }

  @override
  Future<void> setCloseToTray(bool enabled) async {
    calls.add('setCloseToTray $enabled');
    if (enabled == _fakeCloseToTray) return;
    _fakeCloseToTray = enabled;
    notifyListeners();
  }

  Future<DeviceNameResult> Function(String? name) deviceNameResult = (
    _,
  ) async => const DeviceNameResult();
  final Map<String, String> namesakes = {};

  @override
  Future<DeviceNameResult> setDeviceName(String? name) {
    calls.add('setDeviceName $name');
    return deviceNameResult(name);
  }

  @override
  String? namesakeOf(String candidate) => namesakes[candidate];

  Future<ExclusionOutcome> Function(String raw) exclusionResult = (_) async =>
      const ExclusionOutcome();

  @override
  Future<ExclusionOutcome> addExclusion(String raw) {
    calls.add('addExclusion $raw');
    return exclusionResult(raw);
  }

  @override
  Future<void> removeExclusion(String name) async {
    calls.add('removeExclusion $name');
  }

  @override
  Future<void> restoreExclusions() async {
    calls.add('restoreExclusions');
  }

  Future<FolderChangeResult> Function() changeFolderResult = () async =>
      const FolderUnchanged();
  Future<FolderChangeResult> Function(String changeId) confirmFolderResult = (
    _,
  ) async => const FolderChanged(r'C:\Recibidos');

  @override
  Future<FolderChangeResult> changeReceiveFolder() {
    calls.add('changeReceiveFolder');
    return changeFolderResult();
  }

  @override
  Future<FolderChangeResult> confirmReceiveFolder(String changeId) {
    calls.add('confirmReceiveFolder $changeId');
    return confirmFolderResult(changeId);
  }

  @override
  void cancelReceiveFolderChange(String changeId) {
    calls.add('cancelReceiveFolderChange $changeId');
  }

  @override
  Future<void> stopUsingNetwork(String networkId) async {
    calls.add('stopUsingNetwork $networkId');
  }

  @override
  NodeState? get state => _fakeState;

  @override
  bool get startFailed => _fakeStartFailed;

  void emit(NodeState? state, {bool? startFailed}) {
    _fakeState = state;
    if (startFailed != null) _fakeStartFailed = startFailed;
    notifyListeners();
  }

  @override
  void dismissIdentityWarning() {
    calls.add('dismissIdentityWarning');
    super.dismissIdentityWarning();
  }

  @override
  Future<void> decideNetwork(String networkId, NetworkDecision decision) async {
    calls.add('decideNetwork $networkId ${decision.name}');
  }

  @override
  void dismissPrompt(String networkId) {
    calls.add('dismissPrompt $networkId');
  }

  @override
  void askAgain(String networkId) {
    calls.add('askAgain $networkId');
  }

  @override
  Future<void> rescan() async {
    calls.add('rescan');
  }

  @override
  Future<void> retry() async {
    calls.add('retry');
  }

  PairRequestResult pairResult = PairRequestResult.started;

  @override
  Future<PairRequestResult> pair(String fingerprint) async {
    calls.add('pair $fingerprint');
    return pairResult;
  }

  @override
  void answerCode({required bool matches}) {
    calls.add('answerCode $matches');
  }

  @override
  void cancelPairing() {
    calls.add('cancelPairing');
  }

  @override
  void cancelRequest() {
    calls.add('cancelRequest');
  }

  @override
  void answerRequest(ReceiverAnswer answer) {
    calls.add('answerRequest ${answer.name}');
  }

  @override
  void dismissPairing() {
    calls.add('dismissPairing');
  }

  @override
  Future<void> answerReplace(
    String fingerprint, {
    required bool replace,
  }) async {
    calls.add('answerReplace $fingerprint $replace');
  }

  @override
  Future<void> answerMine(String fingerprint, {required bool mine}) async {
    calls.add('answerMine $fingerprint $mine');
  }

  @override
  Future<void> setMine(String fingerprint, {required bool mine}) async {
    calls.add('setMine $fingerprint $mine');
  }

  @override
  Future<void> unpair(String fingerprint) async {
    calls.add('unpair $fingerprint');
  }

  @override
  Future<void> unignore(String fingerprint) async {
    calls.add('unignore $fingerprint');
  }

  @override
  Future<void> retrySave() async {
    calls.add('retrySave');
  }

  @override
  void dismissNotice(int id) {
    calls.add('dismissNotice $id');
  }

  RevealResult revealResult = RevealResult.shown;
  Future<void> Function() shutdownResult = () async {};

  SendResult sendFilesResult = SendResult.started;
  SendResult sendFoldersResult = SendResult.started;
  SendResult sendPathsResult = SendResult.started;
  SendResult sendTrayResult = SendResult.started;
  TrayResult addToTrayResult = TrayResult.added;
  final List<List<String>> sendPathsCalls = [];
  final List<List<String>> addToTrayCalls = [];
  final List<int?> addToTrayTotals = [];

  @override
  Future<SendResult> sendFiles(String fingerprint) async {
    calls.add('sendFiles $fingerprint');
    return sendFilesResult;
  }

  @override
  Future<SendResult> sendFolders(String fingerprint) async {
    calls.add('sendFolders $fingerprint');
    return sendFoldersResult;
  }

  @override
  Future<SendResult> sendPaths(String fingerprint, List<String> paths) async {
    calls.add('sendPaths $fingerprint ${paths.join('|')}');
    sendPathsCalls.add(List.of(paths));
    return sendPathsResult;
  }

  @override
  void cancelQueueItem(String itemId) {
    calls.add('cancelQueueItem $itemId');
  }

  @override
  void removeQueueItem(String itemId) {
    calls.add('removeQueueItem $itemId');
  }

  @override
  void cancelAllQueued() {
    calls.add('cancelAllQueued');
  }

  @override
  Future<TrayResult> addToTray(List<String> paths, {int? totalCount}) async {
    calls.add('addToTray ${paths.join('|')} $totalCount');
    addToTrayCalls.add(List.of(paths));
    addToTrayTotals.add(totalCount);
    return addToTrayResult;
  }

  @override
  void removeFromTray(String itemId) {
    calls.add('removeFromTray $itemId');
  }

  @override
  void clearTray() {
    calls.add('clearTray');
  }

  @override
  Future<SendResult> sendTray(String fingerprint) async {
    calls.add('sendTray $fingerprint');
    return sendTrayResult;
  }

  @override
  Future<void> requestPortal(String fingerprint) async {
    calls.add('requestPortal $fingerprint');
  }

  @override
  void cancelSending() {
    calls.add('cancelSending');
  }

  @override
  void cancelReceiving(String sessionId) {
    calls.add('cancelReceiving $sessionId');
  }

  @override
  void answerIncoming(String sessionId, {required bool accept}) {
    calls.add('answerIncoming $sessionId $accept');
  }

  @override
  Future<void> useProposedFolder(String sessionId) async {
    calls.add('useProposedFolder $sessionId');
  }

  @override
  Future<void> chooseOtherFolder(String sessionId) async {
    calls.add('chooseOtherFolder $sessionId');
  }

  @override
  void useFolderAnyway(String sessionId) {
    calls.add('useFolderAnyway $sessionId');
  }

  @override
  void cancelFolderQuestion(String sessionId) {
    calls.add('cancelFolderQuestion $sessionId');
  }

  @override
  Future<void> rememberFolderAfterEnd(
    String sessionId, {
    required bool remember,
  }) async {
    calls.add('rememberFolderAfterEnd $sessionId $remember');
  }

  @override
  void dismissFolderPanel(String sessionId) {
    calls.add('dismissFolderPanel $sessionId');
  }

  @override
  Future<RevealResult> revealLastReceived() async {
    calls.add('revealLastReceived');
    return revealResult;
  }

  @override
  Future<void> shutdown() {
    calls.add('shutdown');
    return shutdownResult();
  }
}

Widget homeApp(
  AppController controller,
  String languageCode, {
  bool reduceMotion = false,
  DropEvents? dropEvents,
  SettingsController? settings,
  AttentionWatcher? attention,
  FocusNode? neutralFocus,
}) {
  return MaterialApp(
    locale: Locale(languageCode),
    supportedLocales: const [Locale('en'), Locale('es')],
    localizationsDelegates: const [
      AppStringsDelegate(),
      GlobalMaterialLocalizations.delegate,
      GlobalWidgetsLocalizations.delegate,
      GlobalCupertinoLocalizations.delegate,
    ],
    theme: buildTheme(Brightness.light),
    darkTheme: buildTheme(Brightness.dark),
    themeMode: ThemeMode.system,
    themeAnimationDuration: Duration.zero,
    builder: reduceMotion
        ? (context, child) => MediaQuery(
            data: MediaQuery.of(context).copyWith(disableAnimations: true),
            child: child!,
          )
        : null,
    home: NetworkPromptHost(
      controller: controller,
      child: PairingHost(
        controller: controller,
        child: HomeScreen(
          controller,
          dropEvents: dropEvents,
          settings: settings,
          attention: attention,
          neutralFocus: neutralFocus,
        ),
      ),
    ),
  );
}

Future<void> pumpHome(
  WidgetTester tester,
  AppController controller,
  String languageCode, {
  bool settle = true,
  bool reduceMotion = false,
  DropEvents? dropEvents,
  SettingsController? settings,
  AttentionWatcher? attention,
}) async {
  await tester.pumpWidget(
    homeApp(
      controller,
      languageCode,
      reduceMotion: reduceMotion,
      dropEvents: dropEvents,
      settings: settings,
      attention: attention,
    ),
  );
  if (settle) {
    await tester.pumpAndSettle();
  } else {
    await pumpFrames(tester);
  }
}

Future<void> pumpFrames(WidgetTester tester) async {
  await tester.pump();
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
}

String fingerprintOf(String prefix) => (prefix * 64).substring(0, 64);

DiscoveredDevice deviceWith({
  required String fingerprint,
  String? name,
  DeviceType type = DeviceType.desktop,
  bool paired = false,
}) {
  return DiscoveredDevice(
    info: DeviceInfo(
      name: name,
      fingerprint: fingerprint,
      port: 53530,
      protocol: '1.0',
      deviceType: type,
    ),
    address: InternetAddress('192.168.1.20'),
    interfaceId: 'adapter-1|192.168.1.10',
    paired: paired,
    lastSeen: DateTime(2026, 10, 22),
  );
}

const String brandName = 'NexusBridges';

final RegExp _digitsOnly = RegExp(r'^\d+$');

List<String> visibleTexts(WidgetTester tester) {
  return [
    for (final text in tester.widgetList<Text>(find.byType(Text)))
      text.data ?? text.textSpan?.toPlainText() ?? '',
  ].where((text) => text != brandName && !_digitsOnly.hasMatch(text)).toList();
}
