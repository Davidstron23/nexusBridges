import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nexus_bridges/src/app_controller.dart';
import 'package:nexus_bridges/src/l10n/app_strings.dart';
import 'package:nexus_bridges/src/ui/home_screen.dart';
import 'package:nexus_bridges/src/ui/network_prompt_dialog.dart';
import 'package:nexus_bridges_core/nexus_bridges_core.dart';

const List<String> languageCodes = ['es', 'en'];

class FakeAppController extends AppController {
  FakeAppController({NodeState? state, bool startFailed = false})
    : _fakeState = state,
      _fakeStartFailed = startFailed,
      super(
        startNode: () async => throw StateError('not used by widget tests'),
        loadLanguage: () async => 'en',
      );

  NodeState? _fakeState;
  bool _fakeStartFailed;
  final List<String> calls = [];

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
}

Future<void> pumpHome(
  WidgetTester tester,
  AppController controller,
  String languageCode,
) async {
  await tester.pumpWidget(
    MaterialApp(
      locale: Locale(languageCode),
      supportedLocales: const [Locale('en'), Locale('es')],
      localizationsDelegates: const [
        AppStringsDelegate(),
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      home: NetworkPromptHost(
        controller: controller,
        child: HomeScreen(controller),
      ),
    ),
  );
  await tester.pumpAndSettle();
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

List<String> visibleTexts(WidgetTester tester) {
  return [
    for (final text in tester.widgetList<Text>(find.byType(Text)))
      text.data ?? text.textSpan?.toPlainText() ?? '',
  ];
}
