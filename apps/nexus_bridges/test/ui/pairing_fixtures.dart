import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nexus_bridges/src/l10n/app_strings.dart';
import 'package:nexus_bridges/src/ui/device_list.dart';
import 'package:nexus_bridges/src/ui/modal/code_boxes.dart';
import 'package:nexus_bridges/src/ui/modal/modal_frame.dart';
import 'package:nexus_bridges_core/nexus_bridges_core.dart';

import 'fake_app_controller.dart';

const String peerShort = 'ABCD1234';
final String peerFingerprint = fingerprintOf(peerShort);
const String peerName = 'Port\u00E1til de Ana';
const String rawCode = '482913';
const String formattedCode = '482 913';
const String namesakeName = 'PC';

NodeState pairingState({
  PairingView? pairing,
  List<PairingQuestion> questions = const [],
  String? namesake,
  List<Notice> notices = const [],
}) {
  return NodeState(
    pairing: pairing,
    pairingNamesake: namesake,
    questions: questions,
    notices: notices,
  );
}

DeviceEntry entry({
  required String fingerprint,
  required String name,
  DeviceType? type = DeviceType.desktop,
  bool visible = true,
  bool paired = false,
  bool mine = false,
  bool ignored = false,
  bool mismatch = false,
  String? possiblyReplaces,
}) {
  return DeviceEntry(
    fingerprint: fingerprint,
    displayName: name,
    deviceType: visible ? type : null,
    visible: visible,
    paired: paired,
    mine: mine,
    ignored: ignored,
    mismatch: mismatch,
    possiblyReplaces: possiblyReplaces,
  );
}

PairingView view({
  required PairingRole role,
  required PairingPhase phase,
  String? name = peerName,
  String? fingerprint,
  String? pairingCode = rawCode,
  bool alreadyPaired = false,
  PairingOutcome? outcome,
  bool isNew = false,
}) {
  return PairingView(
    role: role,
    phase: phase,
    peerFingerprint: fingerprint ?? peerFingerprint,
    peerName: name,
    code: phase == PairingPhase.connecting ? null : pairingCode,
    alreadyPaired: alreadyPaired,
    outcome: outcome,
    isNew: isNew,
  );
}

Finder get dialog => find.byType(NbModal);

List<String> buttonLabelsIn(WidgetTester tester, Finder scope) {
  final buttons = find.descendant(
    of: scope,
    matching: find.byWidgetPredicate((widget) => widget is ButtonStyleButton),
  );
  return [
    for (final button in buttons.evaluate())
      [
        for (final text in tester.widgetList<Text>(
          find.descendant(
            of: find.byElementPredicate((element) => element == button),
            matching: find.byType(Text),
          ),
        ))
          text.data ?? '',
      ].join(' '),
  ].where((label) => label.isNotEmpty).toList();
}

List<String> dialogButtons(WidgetTester tester) =>
    buttonLabelsIn(tester, dialog);

Finder cardOf(String name) =>
    find.ancestor(of: find.text(name), matching: find.byType(DeviceRow)).first;

List<String> rowButtons(WidgetTester tester, String name) =>
    buttonLabelsIn(tester, cardOf(name));

String? _codeLabelOf(Element boxes) {
  String? label;
  void visit(Element element) {
    if (label != null) return;
    final widget = element.widget;
    if (widget is Semantics && widget.properties.label != null) {
      label = widget.properties.label;
      return;
    }
    element.visitChildElements(visit);
  }

  boxes.visitChildElements(visit);
  return label;
}

Element? _codeBoxesAbove(Element element) {
  Element? found;
  element.visitAncestorElements((ancestor) {
    if (ancestor.widget is CodeBoxes) {
      found = ancestor;
      return false;
    }
    return true;
  });
  return found;
}

String? codeIn(WidgetTester tester, Finder scope) {
  final boxes = find.descendant(of: scope, matching: find.byType(CodeBoxes));
  final elements = boxes.evaluate().toList();
  if (elements.isEmpty) return null;
  expect(elements, hasLength(1), reason: 'more than one code on screen');
  return _codeLabelOf(elements.single);
}

List<String> textsIn(WidgetTester tester, Finder scope) {
  final texts = <String>[];
  final seen = <Element>{};
  for (final element
      in find.descendant(of: scope, matching: find.byType(Text)).evaluate()) {
    final boxes = _codeBoxesAbove(element);
    if (boxes != null) {
      if (seen.add(boxes)) texts.add(_codeLabelOf(boxes) ?? '');
      continue;
    }
    final text = element.widget as Text;
    texts.add(text.data ?? text.textSpan?.toPlainText() ?? '');
  }
  return texts;
}

Future<void> tapInDialog(WidgetTester tester, String label) async {
  await tester.tap(find.descendant(of: dialog, matching: find.text(label)));
}

Set<String> allowedTexts(
  AppStrings s, {
  List<String> names = const [],
  List<int> counts = const [],
}) {
  return {
    s.devicesTitle,
    s.activityTab,
    s.devicesTab,
    s.trustedNetworkLabel,
    s.onlyPairedCanSend,
    s.noDevicesYet,
    s.rescanHint,
    s.rescanButton,
    s.pausedBanner,
    s.sectionUnpaired,
    s.chipMine,
    s.chipForeign,
    s.visibleLabel,
    s.sendEllipsis,
    s.dragTipTitle,
    s.dragTipBody,
    s.sendNeedsVisible,
    s.sendNeedsPairAgain,
    s.networkPromptTitle,
    s.yes,
    s.no,
    s.pairedLabel,
    s.notPairedLabel,
    s.deviceTypeDesktop,
    s.deviceTypeMobile,
    s.identityResetWarning,
    s.identityFailed,
    s.retryButton,
    s.decisionNotSaved,
    s.closeButton,
    s.pairButton,
    s.unpairButton,
    s.moreOptions,
    s.notVisibleLabel,
    s.pairedMineLabel,
    s.pairedForeignLabel,
    s.markAsMine,
    s.markAsForeign,
    s.ignoredLabel,
    s.unignoreButton,
    s.mismatchWarning,
    s.removeButton,
    s.pairAgainButton,
    s.pairingAlreadyInProgress,
    s.tooManyPaired,
    s.pairUnavailable,
    s.matchesButton,
    s.doesNotMatchButton,
    s.cancelButton,
    s.alreadyPairedNote,
    s.ignoreDeviceButton,
    s.pairingResultTitle,
    s.outcomeExpired,
    s.outcomeNetworkChanged,
    s.outcomeNotSaved,
    s.replaceButton,
    s.keepBothButton,
    s.mineBody,
    s.mineYesButton,
    s.mineNoButton,
    s.noticeChangeNotSaved,
    s.noticePairingPaused,
    s.mineQuestion,
    s.mineYesDetail,
    s.mineNoDetail,
    for (final outcome in [...PairingOutcome.values, null])
      s.pairingEyebrow(outcome).toUpperCase(),
    ...rawCode.split(''),
    for (final c in counts) s.noticeAttemptsCancelled(c),
    for (final n in names) ...[
      s.trustNetworkButton(n),
      s.networkPromptBody(n),
      s.possibleReinstall(n),
      s.pairingWithTitle(n),
      s.connectingTo(n),
      s.compareCode(n),
      s.waitingForPeer(n),
      s.pairingRequestTitle(n),
      s.fingerprintLine(n),
      s.receiverWaiting(n),
      s.outcomePaired(n),
      s.outcomeRejected(n),
      s.outcomeBusy(n),
      s.outcomePaused(n),
      s.outcomeCancelledByPeer(n),
      s.outcomeLost(n),
      s.outcomeFailed(n),
      s.replaceTitle(n),
      for (final m in names) s.replaceBody(n, m),
      s.replaceShortBody(n),
      s.mineTitle(n),
      s.unpairTitle(n),
      s.unpairBody(n),
      s.noticeAttemptCancelled(n),
      s.noticeAttemptPeerCancelled(n),
      s.noticeUnpairedByPeer(n),
      s.noticeUnpairNotSaved(n),
      s.noticeIgnoreNotSaved(n),
      s.noticePairingNotSaved(n),
      s.noticePairingFailed(n),
      s.noticeAttemptLost(n),
      s.noticeReplaceWithdrawn(n),
      s.noticeReceiveFolderNotSaved(n),
      s.noticePeerCancelledTransfer(n),
      s.noticeSharesNotSaved,
      s.noticeShareAddNotSaved,
      s.noticeSharesReset,
      s.noticeSharesPartlyReset,
      s.namesakeWarning(n),
    ],
  };
}
