import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nexus_bridges/src/l10n/app_strings.dart';
import 'package:nexus_bridges/src/ui/activity_cards.dart';
import 'package:nexus_bridges/src/ui/pairing_dialogs.dart';
import 'package:nexus_bridges/src/ui/theme/app_theme.dart';
import 'package:nexus_bridges/src/ui/theme/components.dart';
import 'package:nexus_bridges_core/nexus_bridges_core.dart';

import 'fake_app_controller.dart';

const double columnWidth = 280;

const String senderShort = 'ABCD1234';
final String senderFingerprint = fingerprintOf(senderShort);
const String senderName = 'Port\u00E1til de Ana';

const String downloadsPath = r'C:\Users\Ana\Downloads\NexusBridges';
const String otherPath = r'D:\Recibidos';
const String cautionPath = r'E:\Pendrive';

const Duration justBeforeArmed = Duration(milliseconds: 499);
const Duration lastMillisecond = Duration(milliseconds: 1);

void setWindow(WidgetTester tester, Size size) {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
}

String longName(String tail) => '${'n' * (300 - tail.length)}$tail';

OutgoingTransferView outgoingView({
  OutgoingPhase phase = OutgoingPhase.uploading,
  String? name = senderName,
  String? fingerprint,
  String fileName = 'informe.pdf',
  int size = 2048,
  int sent = 512,
  bool isProgram = false,
  bool cancelling = false,
}) {
  return OutgoingTransferView(
    peerFingerprint: fingerprint ?? senderFingerprint,
    peerName: name,
    fileName: fileName,
    size: size,
    isProgram: isProgram,
    phase: phase,
    sentBytes: sent,
    cancelling: cancelling,
  );
}

IncomingTransferView incomingView({
  String id = 's1',
  IncomingStage stage = IncomingStage.warning,
  String? name = senderName,
  String? fingerprint,
  String fileName = 'factura.pdf',
  int size = 1536,
  bool isProgram = false,
  bool withoutMark = false,
  FolderQuestionView? folder,
  int received = 0,
}) {
  return IncomingTransferView(
    sessionId: id,
    peerFingerprint: fingerprint ?? senderFingerprint,
    peerName: name,
    fileName: fileName,
    size: size,
    isProgram: isProgram,
    stage: stage,
    withoutMark: withoutMark,
    folder: folder,
    receivedBytes: received,
  );
}

TransferResultView resultView({
  TransferDirection direction = TransferDirection.incoming,
  TransferOutcome outcome = TransferOutcome.saved,
  String? name = senderName,
  String fileName = 'foto.jpg',
  bool isProgram = false,
  bool canReveal = false,
}) {
  return TransferResultView(
    direction: direction,
    peerFingerprint: senderFingerprint,
    peerName: name,
    fileName: fileName,
    isProgram: isProgram,
    outcome: outcome,
    canReveal: canReveal,
  );
}

Widget columnApp(
  FakeAppController controller,
  String languageCode,
  Widget Function(NodeState state) build, {
  double width = columnWidth,
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
    home: Scaffold(
      body: Align(
        alignment: Alignment.topLeft,
        child: SizedBox(
          width: width,
          child: SingleChildScrollView(
            child: ListenableBuilder(
              listenable: controller,
              builder: (context, _) =>
                  build(controller.state ?? const NodeState()),
            ),
          ),
        ),
      ),
    ),
  );
}

Future<FakeAppController> pumpColumn(
  WidgetTester tester,
  String languageCode,
  NodeState state,
  Widget Function(FakeAppController controller, NodeState state) build, {
  double width = columnWidth,
}) async {
  setWindow(tester, const Size(800, 600));
  final controller = FakeAppController(state: state);
  await tester.pumpWidget(
    columnApp(
      controller,
      languageCode,
      (current) => build(controller, current),
      width: width,
    ),
  );
  await tester.pump();
  return controller;
}

Future<void> arm(WidgetTester tester) => tester.pump(dialogActivationDelay);

Finder inside(Finder scope, Finder finder) =>
    find.descendant(of: scope, matching: finder);

Finder textIn(Finder scope, String text) => inside(scope, find.text(text));

Finder buttonIn(Finder scope, String label) => find.ancestor(
  of: textIn(scope, label),
  matching: find.byWidgetPredicate((widget) => widget is ButtonStyleButton),
);

bool isEnabled(WidgetTester tester, Finder button) =>
    tester.widget<ButtonStyleButton>(button).onPressed != null;

List<String> buttonLabels(WidgetTester tester, Finder scope) {
  return [
    for (final button in tester.widgetList<ButtonStyleButton>(
      inside(
        scope,
        find.byWidgetPredicate((widget) => widget is ButtonStyleButton),
      ),
    ))
      for (final text in tester.widgetList<Text>(
        find.descendant(of: find.byWidget(button), matching: find.byType(Text)),
      ))
        text.data ?? '',
  ];
}

List<bool> buttonStates(WidgetTester tester, Finder scope) {
  return [
    for (final button in tester.widgetList<ButtonStyleButton>(
      inside(
        scope,
        find.byWidgetPredicate((widget) => widget is ButtonStyleButton),
      ),
    ))
      button.onPressed != null,
  ];
}

Finder fileNameIn(Finder scope) =>
    inside(inside(scope, find.byType(FileRow)), find.byType(Text)).first;

String shownFileName(WidgetTester tester, Finder scope) =>
    tester.widget<Text>(fileNameIn(scope)).data!;

RenderParagraph fileNameParagraph(WidgetTester tester, Finder scope) =>
    tester.renderObject<RenderParagraph>(
      inside(fileNameIn(scope), find.byType(RichText)),
    );

void expectNameFits(WidgetTester tester, Finder scope) {
  final paragraph = fileNameParagraph(tester, scope);
  expect(paragraph.didExceedMaxLines, isFalse);
  expect(
    paragraph.getMaxIntrinsicWidth(double.infinity),
    lessThanOrEqualTo(paragraph.size.width + 0.01),
  );
}

StatusChip chipIn(WidgetTester tester, Finder scope) =>
    tester.widget<StatusChip>(inside(scope, find.byType(StatusChip)));
