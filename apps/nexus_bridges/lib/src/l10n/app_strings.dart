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
  String get noticeSharesNotSaved;
  String get noticeShareAddNotSaved;
  String get noticeSharesReset;
  String get noticeSharesPartlyReset;

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
  String arrivesIn(String time);
  String get arrivesInFewSeconds;
  String get calculatingTime;

  String incomingRequestTitle(String name);
  String incomingFolderRequestTitle(String name);
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
  String get closeWithQueuesBody;
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

  String get sendEllipsis;
  String get sendFilesOption;
  String get sendFoldersOption;
  String preparingItems(int count);
  String folderSummary(int files, String size);
  String foldersLeftOut(int count, String? size);
  String linksNotFollowed(int count);
  String get appDataLeftOut;
  String blockedLeftOut(int count);
  String get containsPrograms;
  String filesProgress(int done, int total);
  String firstLevelMore(int count);
  String outcomeUnreadableEntry(String path);
  String outcomeInvalidNameEntry(String path);
  String get outcomeFolderIncompatible;

  String queueTitle(String name);
  String get looseQueue;
  String get bundleQueue;
  String get queuePending;
  String queueNotSent(String reason);
  String get queueRemove;
  String get queueCancelAll;
  String queueRemaining(int count);
  String get queueLastItem;
  String deliveredSummary(int delivered, int total);
  String waitForQueues(String name);
  String get tooManySelected;

  String trayTitle(int count);
  String get trayRemoveAll;
  String traySendTo(String name);
  String get trayFull;
  String get trayNothingNew;
  String get dragHint;
  String get dragTipTitle;
  String get dragTipBody;

  String get settingsButton;
  String get settingsTitle;
  String settingsSubtitle(String name);
  String get settingsBack;
  String get settingsNavFoot;
  String get settingsFooter;
  String moreInfo(String text);
  String get sectionAppearance;
  String get appearanceInfo;
  String get themeDark;
  String get themeLight;
  String get themeWindows;
  String get sectionLanguage;
  String get languageSpanish;
  String get languageEnglish;
  String get sectionDevice;
  String get deviceNameLabel;
  String get deviceNameDesc;
  String get deviceNameInfo;
  String get saveButton;
  String useWindowsName(String name);
  String get nameEmpty;
  String get nameTooLong;
  String get nameInvalid;
  String get nameNamesake;
  String get sectionReceive;
  String get receiveDesc;
  String get receiveInfo;
  String get receiveNotSet;
  String get changeFolderButton;
  String get changeFolderLocked;
  String get sectionExclusions;
  String ofMax(int n, int max);
  String get exclusionsDesc;
  String get exclusionsInfo;
  String get exclusionsEmpty;
  String get exclusionPlaceholder;
  String get addButton;
  String removeExclusion(String name);
  String get exclusionEmpty;
  String get exclusionInvalid;
  String get exclusionDuplicate;
  String get exclusionFull;
  String get restoreDefaults;
  String get restoreConfirm;
  String get restoreButton;
  String get sectionSystemTray;
  String get systemTrayInfo;
  String get systemTraySwitch;
  String get systemTraySwitchHelp;
  String get systemTrayOffHelp;
  String get systemTrayOpen;
  String get systemTrayExit;
  String get systemTrayHintTitle;
  String get systemTrayHintBody;
  String get sectionNetworks;
  String get networksInfo;
  String get connectedNow;
  String get unnamedNetwork;
  String get networksEmpty;
  String trustedOn(String date);
  String get stopUsingButton;
  String stopUsingConfirm(String network);
  String transfersStopped(int count);
  String get pairingCancelled;
  String get stopUsingConfirmButton;
  String noticeNetworkStopNotSaved(String network);
  String get sectionIgnored;
  String get ignoredInfo;
  String get ignoredEmpty;
  String ignoredOn(String date);
  String get noticeSettingNotSaved;
  String monthShort(int month);
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
