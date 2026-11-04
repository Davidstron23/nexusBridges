import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nexus_bridges/src/l10n/app_strings.dart';
import 'package:nexus_bridges/src/ui/attention.dart';
import 'package:nexus_bridges/src/ui/settings/inline_confirm.dart';
import 'package:nexus_bridges/src/ui/settings/settings_controller.dart';
import 'package:nexus_bridges/src/ui/settings/settings_screen.dart';
import 'package:nexus_bridges/src/ui/settings/settings_section.dart';
import 'package:nexus_bridges_core/nexus_bridges_core.dart';

import '../fake_app_controller.dart';

const Size tallWindow = Size(1200, 2600);
const String ownName = 'PC de David';
const String windowsName = 'DESKTOP-7Q2';
const List<String> defaultNames = ['node_modules', 'build', '.dart_tool'];
const String homeNetwork = '{NETWORK-HOME}';
const String officeNetwork = '{NETWORK-OFFICE}';
const String receivePath = r'C:\Users\David\Recibidos';

final DateTime homeTrusted = DateTime.utc(2026, 10, 30, 12);
final DateTime officeTrusted = DateTime.utc(2026, 9, 4, 12);

TrustedNetworkView networkView({
  String id = homeNetwork,
  String? name = 'Casa',
  DateTime? trustedAt,
  bool connected = true,
  int transfers = 0,
  bool pairing = false,
}) {
  return TrustedNetworkView(
    networkId: id,
    name: name,
    trustedAt: trustedAt ?? homeTrusted,
    connected: connected,
    transfers: transfers,
    pairing: pairing,
  );
}

IgnoredDeviceView ignoredView({
  required String fingerprint,
  required String name,
  required DateTime at,
}) {
  return IgnoredDeviceView(
    fingerprint: fingerprint,
    name: name,
    shortFingerprint: fingerprint.substring(0, 8),
    ignoredAt: at,
  );
}

NodeState settingsState({
  String deviceName = ownName,
  String? customName = ownName,
  List<String> exclusions = defaultNames,
  String? receiveFolder = receivePath,
  bool locked = false,
  List<TrustedNetworkView>? networks,
  List<IgnoredDeviceView> ignored = const [],
  List<DeviceEntry> entries = const [],
  IncomingTransferView? incoming,
  PairingView? pairing,
  List<Notice> notices = const [],
  bool paused = false,
  bool pickerOpen = false,
  bool unsavedChanges = false,
}) {
  return NodeState(
    deviceName: deviceName,
    settings: SettingsView(
      customName: customName,
      windowsName: windowsName,
      exclusions: exclusions,
      receiveFolder: receiveFolder,
      receiveFolderLocked: locked,
    ),
    trustedNetworks: networks ?? [networkView()],
    ignoredDevices: ignored,
    entries: entries,
    incoming: incoming,
    pairing: pairing,
    notices: notices,
    paused: paused,
    pickerOpen: pickerOpen,
    unsavedChanges: unsavedChanges,
  );
}

void setSize(WidgetTester tester, Size size) {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
}

Future<(FakeAppController, SettingsController)> pumpSettings(
  WidgetTester tester,
  String code, {
  NodeState? state,
  Size size = tallWindow,
  bool reduceMotion = false,
  bool open = true,
  ThemeChoice theme = ThemeChoice.dark,
  bool closeToTray = true,
  bool systemTray = true,
}) async {
  setSize(tester, size);
  final controller = FakeAppController(
    state: state ?? settingsState(),
    languageCode: code,
    theme: theme,
    closeToTray: closeToTray,
    systemTray: systemTray,
  );
  final settings = SettingsController();
  await pumpHome(
    tester,
    controller,
    code,
    settings: settings,
    reduceMotion: reduceMotion,
  );
  if (open) await openSettings(tester, stringsFor(code));
  return (controller, settings);
}

Future<void> openSettings(WidgetTester tester, AppStrings strings) async {
  await tester.tap(find.byTooltip(strings.settingsButton));
  await tester.pumpAndSettle();
}

Finder get settingsScreen => find.byType(SettingsScreen);

Finder sectionOf(String title) =>
    find.ancestor(of: find.text(title), matching: find.byType(SettingsSection));

Finder inSection(String title, Finder matching) =>
    find.descendant(of: sectionOf(title), matching: matching);

Finder textField(String section) => inSection(section, find.byType(TextField));

Finder sectionButton(String section, String label) => inSection(
  section,
  find.ancestor(
    of: find.text(label),
    matching: find.byWidgetPredicate((widget) => widget is ButtonStyleButton),
  ),
);

bool buttonEnabled(WidgetTester tester, Finder button) =>
    tester.widget<ButtonStyleButton>(button).onPressed != null;

Finder confirmOf(String section) =>
    inSection(section, find.byType(InlineConfirm));

bool confirmOpen(WidgetTester tester, String section) {
  final boxes = tester.widgetList<InlineConfirm>(confirmOf(section));
  return boxes.any((box) => box.open);
}

Finder confirmButton(String section, String label) => find.descendant(
  of: confirmOf(section),
  matching: find.ancestor(
    of: find.text(label),
    matching: find.byWidgetPredicate((widget) => widget is ButtonStyleButton),
  ),
);

Future<void> pressEscape(WidgetTester tester) async {
  await tester.sendKeyEvent(LogicalKeyboardKey.escape);
  await tester.pumpAndSettle();
}

Future<void> typeIn(WidgetTester tester, Finder field, String text) async {
  await tester.enterText(field, text);
  await tester.pump();
}

Future<void> submit(WidgetTester tester) async {
  await tester.testTextInput.receiveAction(TextInputAction.done);
  await tester.pumpAndSettle();
}

bool navSelected(WidgetTester tester, String title) {
  final matches = tester.widgetList<Semantics>(
    find.descendant(
      of: settingsScreen,
      matching: find.byWidgetPredicate(
        (widget) =>
            widget is Semantics &&
            widget.properties.label == title &&
            widget.properties.selected != null,
      ),
    ),
  );
  return matches.single.properties.selected!;
}

AttentionWatcher watcherOf(FakeAppController controller) {
  final watcher = AttentionWatcher(controller);
  addTearDown(watcher.dispose);
  return watcher;
}

ConfirmRegistry confirmScopeOf(WidgetTester tester) => tester
    .widget<ConfirmScope>(
      find.descendant(of: settingsScreen, matching: find.byType(ConfirmScope)),
    )
    .cancel;

Finder infoButton(String section) =>
    inSection(section, find.byType(InfoButton));

Future<void> hoverOver(WidgetTester tester, Finder target) async {
  final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
  await gesture.addPointer(location: Offset.zero);
  addTearDown(gesture.removePointer);
  await gesture.moveTo(tester.getCenter(target));
  await tester.pump(const Duration(milliseconds: 300));
  await tester.pump(const Duration(milliseconds: 300));
}

Future<void> tooltipCases(
  WidgetTester tester,
  String section,
  String text,
) async {
  expect(find.text(text), findsNothing);
  await tester.tap(infoButton(section));
  await tester.pump(const Duration(milliseconds: 300));
  expect(find.text(text), findsOneWidget);
  Tooltip.dismissAllToolTips();
  await tester.pumpAndSettle();
  expect(find.text(text), findsNothing);

  await hoverOver(tester, infoButton(section));
  expect(find.text(text), findsOneWidget);
  Tooltip.dismissAllToolTips();
  await tester.pumpAndSettle();
  expect(find.text(text), findsNothing);

  final focus = Focus.of(
    tester.element(
      find.descendant(
        of: infoButton(section),
        matching: find.byType(GestureDetector),
      ),
    ),
  );
  focus.requestFocus();
  await tester.pump();
  expect(focus.hasPrimaryFocus, isTrue);
  await tester.sendKeyEvent(LogicalKeyboardKey.enter);
  await tester.pump(const Duration(milliseconds: 300));
  expect(find.text(text), findsOneWidget);
}
