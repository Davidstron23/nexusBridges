import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:nexus_bridges_core/nexus_bridges_core.dart'
    show PairingOutcome, TransferOutcome;

import 'app_strings_en.dart';
import 'app_strings_es.dart';

abstract class AppStrings {
  String get appTitle;
  String get devicesTitle;
  String get noDevicesYet;
  String get rescanHint;
  String get rescanButton;
  String get pausedBanner;
  String trustNetworkButton(String name);
  String get networkPromptTitle;
  String networkPromptBody(String name);
  String get yes;
  String get no;
  String get pairedLabel;
  String get notPairedLabel;
  String get deviceTypeDesktop;
  String get deviceTypeMobile;
  String get identityResetWarning;
  String get identityFailed;
  String portInUse(int port);
  String get retryButton;
  String get decisionNotSaved;
  String get closeButton;

  String get pairButton;
  String get unpairButton;
  String get moreOptions;
  String get notVisibleLabel;
  String get pairedMineLabel;
  String get pairedForeignLabel;
  String get markAsMine;
  String get markAsForeign;
  String get ignoredLabel;
  String get unignoreButton;
  String get mismatchWarning;
  String get removeButton;
  String get pairAgainButton;
  String possibleReinstall(String oldName);
  String get pairingAlreadyInProgress;
  String get tooManyPaired;
  String get pairUnavailable;

  String pairingWithTitle(String name);
  String connectingTo(String name);
  String compareCode(String name);
  String get matchesButton;
  String get doesNotMatchButton;
  String get cancelButton;
  String waitingForPeer(String name);
  String pairingRequestTitle(String name);
  String fingerprintLine(String short);
  String get alreadyPairedNote;
  String namesakeWarning(String name);
  String get ignoreDeviceButton;
  String receiverWaiting(String name);
  String get pairingResultTitle;

  String outcomePaired(String name);
  String outcomeRejected(String name);
  String outcomeBusy(String name);
  String outcomePaused(String name);
  String outcomeCancelledByPeer(String name);
  String get outcomeExpired;
  String outcomeLost(String name);
  String get outcomeNetworkChanged;
  String outcomeFailed(String name);
  String get outcomeNotSaved;

  String replaceTitle(String oldName);
  String replaceBody(String newName, String oldName);
  String get replaceButton;
  String get keepBothButton;
  String mineTitle(String name);
  String get mineBody;
  String get mineQuestion;
  String get mineYesDetail;
  String get mineNoDetail;
  String replaceShortBody(String newName);
  String pairingEyebrow(PairingOutcome? outcome);
  String get mineYesButton;
  String get mineNoButton;
  String unpairTitle(String name);
  String unpairBody(String name);

  String noticeAttemptCancelled(String short);
  String noticeAttemptPeerCancelled(String short);
  String noticeAttemptsCancelled(int count);
  String noticeAttemptLost(String short);
  String noticeReplaceWithdrawn(String name);
  String get noticePairingPaused;
  String noticeUnpairedByPeer(String name);
  String noticeUnpairNotSaved(String name);
  String get noticeChangeNotSaved;
  String noticeIgnoreNotSaved(String name);
  String noticePairingNotSaved(String who);
  String noticePairingFailed(String who);
  String noticeReceiveFolderNotSaved(String path);
  String noticePeerCancelledTransfer(String name);

  String get sendFileButton;
  String get sendNeedsVisible;
  String get sendNeedsPairAgain;
  String get alreadySending;
  String get sendUnavailable;
  String get searchingDevices;

  String sendingToTitle(String name);
  String fileLine(String file, String size);
  String get programLabel;
  String get containsGitRepository;
  String preparingFile(String file);
  String contactingPeer(String name);
  String waitingAcceptance(String name);
  String progressLine(int percent, String done, String total);
  String peerCheckingFile(String name);
  String get cancellingTransfer;

  String incomingRequestTitle(String name);
  String get withoutMarkNote;
  String get acceptButton;
  String get rejectButton;

  String folderQuestionTitle(String name);
  String get folderFirstTimeBody;
  String get folderThisTimeBody;
  String proposedFolderLine(String path);
  String get useThisFolderButton;
  String get chooseOtherFolderButton;
  String get pickerOpenNote;
  String folderForbidden(String path);
  String folderCannotUse(String path);
  String folderStillUnavailable(String path);
  String folderUnknownVolume(String path);
  String folderAdminShare(String path);
  String get checkingFolder;
  String cautionNoMark(String path);
  String cautionRemote(String path);
  String get useAnywayButton;
  String get transferAlreadyEnded;
  String folderRememberedNote(String path);
  String folderNotUsable(String path);
  String get rememberAnywayButton;
  String get dontRememberButton;

  String receivingFromTitle(String name);
  String get waitingForData;
  String get checkingFile;

  String get lastSentTitle;
  String get lastReceivedTitle;
  String toPeer(String name);
  String fromPeer(String name);
  String get showInFolderButton;
  String get revealFolderOnly;
  String get folderUnavailable;
  String sentOutcome(TransferOutcome outcome);
  String receivedOutcome(TransferOutcome outcome);

  String get closeDuringTransferTitle;
  String get closeDuringTransferBody;
  String get keepOpenButton;
  String get closeAndCancelButton;

  String get trustedNetworkLabel;
  String get onlyPairedCanSend;
  String get activityTab;
  String get devicesTab;
  String get activityEmpty;
  String get sectionUnpaired;
  String get chipMine;
  String get chipForeign;
  String get visibleLabel;
  String get diagramTitle;
  String diagramCount(int total, int visible);
  String thisDeviceCaption(String short);
  String get chipPreparing;
  String get chipWaiting;
  String get chipInProgress;
  String get chipChecking;
  String get chipDelivered;
  String get chipSaved;
  String get chipRejected;
  String get chipCancelled;
  String get chipFailed;
  String get chipUnconfirmed;
  String foreignSenderNote(String short);
  String get incomingExpiresNote;
}

AppStrings stringsFor(String languageCode) {
  return languageCode == 'es' ? AppStringsEs() : AppStringsEn();
}

final class AppStringsDelegate extends LocalizationsDelegate<AppStrings> {
  const AppStringsDelegate();

  @override
  bool isSupported(Locale locale) {
    return locale.languageCode == 'es' || locale.languageCode == 'en';
  }

  @override
  Future<AppStrings> load(Locale locale) {
    return SynchronousFuture<AppStrings>(stringsFor(locale.languageCode));
  }

  @override
  bool shouldReload(AppStringsDelegate old) => false;

  static AppStrings of(BuildContext context) {
    return Localizations.of<AppStrings>(context, AppStrings)!;
  }
}
