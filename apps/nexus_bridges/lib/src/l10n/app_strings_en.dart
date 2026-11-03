import 'package:nexus_bridges_core/nexus_bridges_core.dart'
    show PairingOutcome, TransferOutcome;

import '../ui/format.dart';
import 'app_strings.dart';

final class AppStringsEn implements AppStrings {
  @override
  String get appTitle => 'NexusBridges';

  @override
  String get devicesTitle => 'Devices nearby';

  @override
  String get noDevicesYet => 'No devices found yet';

  @override
  String get rescanHint =>
      'No devices found. Some networks block devices from seeing each other.';

  @override
  String get rescanButton => 'Search again';

  @override
  String get pausedBanner => 'NexusBridges is paused on this network';

  @override
  String trustNetworkButton(String name) => 'Use on "$name"';

  @override
  String get networkPromptTitle => 'Use NexusBridges on this network?';

  @override
  String networkPromptBody(String name) =>
      'Other devices on "$name" will be able to see this device. '
      'Only say yes on networks you trust, like your home.';

  @override
  String get yes => 'Use it here';

  @override
  String get no => 'Not on this network';

  @override
  String get pairedLabel => 'Paired';

  @override
  String get notPairedLabel => 'Not paired';

  @override
  String get deviceTypeDesktop => 'Computer';

  @override
  String get deviceTypeMobile => 'Phone';

  @override
  String get identityResetWarning =>
      'This device has a new identity. '
      'You will need to pair it again with your other devices.';

  @override
  String get identityFailed =>
      "NexusBridges could not create this device's identity.";

  @override
  String portInUse(int port) => 'Port $port is being used by another program.';

  @override
  String get retryButton => 'Retry';

  @override
  String get decisionNotSaved =>
      'Your choice will apply until you close the app, '
      'but it could not be saved.';

  @override
  String get closeButton => 'Close';

  @override
  String get pairButton => 'Pair';

  @override
  String get unpairButton => 'Unpair';

  @override
  String get moreOptions => 'More options';

  @override
  String get notVisibleLabel => 'Not visible';

  @override
  String get pairedMineLabel => 'Paired · Mine';

  @override
  String get pairedForeignLabel => "Paired · Someone else's";

  @override
  String get markAsMine => 'Mark as mine';

  @override
  String get markAsForeign => "Mark as someone else's";

  @override
  String get ignoredLabel => 'Ignored';

  @override
  String get unignoreButton => 'Stop ignoring';

  @override
  String get mismatchWarning => 'This device no longer has you paired.';

  @override
  String get removeButton => 'Remove';

  @override
  String get pairAgainButton => 'Pair again';

  @override
  String possibleReinstall(String oldName) =>
      'It has the same name as $oldName, which is paired and not visible. '
      'It may be that device after a reinstall, or someone pretending to be it.';

  @override
  String get pairingAlreadyInProgress =>
      'There is already a pairing in progress.';

  @override
  String get tooManyPaired =>
      'You already have 32 paired devices. Unpair one to pair a new one.';

  @override
  String get pairUnavailable => "This device can't be paired right now.";

  @override
  String pairingWithTitle(String name) => 'Pairing with $name';

  @override
  String connectingTo(String name) => 'Connecting to $name…';

  @override
  String compareCode(String name) => 'Check that $name shows the same code.';

  @override
  String get matchesButton => 'It matches';

  @override
  String get doesNotMatchButton => "It doesn't match";

  @override
  String get cancelButton => 'Cancel';

  @override
  String waitingForPeer(String name) =>
      'Waiting for the code to be confirmed on $name…';

  @override
  String pairingRequestTitle(String name) => '$name wants to pair';

  @override
  String fingerprintLine(String short) => 'Fingerprint: $short';

  @override
  String get alreadyPairedNote =>
      'This device is already paired. If you confirm, it stays as it is.';

  @override
  String namesakeWarning(String name) =>
      'You already have a paired device called $name with a different '
      'fingerprint.';

  @override
  String get ignoreDeviceButton => 'Ignore this device';

  @override
  String receiverWaiting(String name) =>
      'You have confirmed the code. Waiting for $name to confirm it too…';

  @override
  String get pairingResultTitle => 'Pairing';

  @override
  String outcomePaired(String name) => '$name is now paired.';

  @override
  String outcomeRejected(String name) => '$name has not accepted the pairing.';

  @override
  String outcomeBusy(String name) =>
      '$name is busy with another pairing. Try again in a minute.';

  @override
  String outcomePaused(String name) =>
      '$name is not accepting pairings for a few minutes.';

  @override
  String outcomeCancelledByPeer(String name) =>
      '$name has cancelled the pairing. Nothing has been saved.';

  @override
  String get outcomeExpired =>
      'The pairing has expired. Nothing has been saved.';

  @override
  String outcomeLost(String name) =>
      '$name has stopped responding. Nothing has been saved.';

  @override
  String get outcomeNetworkChanged =>
      'The pairing was cancelled because the network changed.';

  @override
  String outcomeFailed(String name) => 'Could not pair with $name.';

  @override
  String get outcomeNotSaved =>
      'The pairing could not be saved, so it has not been completed.';

  @override
  String replaceTitle(String oldName) => 'Replace $oldName?';

  @override
  String replaceBody(String newName, String oldName) =>
      '$newName has the same name as $oldName, which is paired but not '
      'visible. If it is the same device after a reinstall, replace it to '
      'remove the old pairing.';

  @override
  String get replaceButton => 'Replace';

  @override
  String get keepBothButton => 'Keep both';

  @override
  String mineTitle(String name) => 'Paired with $name';

  @override
  String get mineBody =>
      'Is this device yours? If it is, what it sends will come in without '
      'asking and it will be able to browse the folders you share. If it '
      'belongs to someone else, it will always ask for your permission.';

  @override
  String get mineQuestion => 'Is this device yours?';

  @override
  String get mineYesDetail =>
      'What it sends comes in without asking and it can browse the folders '
      'you share.';

  @override
  String get mineNoDetail =>
      'It will always ask for your permission before sending you anything.';

  @override
  String replaceShortBody(String newName) =>
      '$newName has the same name as a paired device that is not visible. If '
      'it is the same one reinstalled, replace it.';

  @override
  String pairingEyebrow(PairingOutcome? outcome) => switch (outcome) {
    PairingOutcome.paired => 'Nexus bridge established',
    PairingOutcome.rejected => 'Connection rejected',
    PairingOutcome.busy => 'Device busy',
    PairingOutcome.paused => 'Connection frozen',
    PairingOutcome.cancelledByPeer => 'Connection cancelled',
    PairingOutcome.expired => 'Time is up',
    PairingOutcome.lost => 'Device vanished',
    PairingOutcome.networkChanged => 'Network changed',
    PairingOutcome.failed || null => 'Unexpected error',
    PairingOutcome.notSaved => 'Could not save',
  };

  @override
  String get mineYesButton => "It's mine";

  @override
  String get mineNoButton => "It's someone else's";

  @override
  String unpairTitle(String name) => 'Unpair $name?';

  @override
  String unpairBody(String name) =>
      '$name will no longer be able to connect to this device, starting now. '
      'To use it again you will have to pair them again.';

  @override
  String noticeAttemptCancelled(String short) =>
      'A pairing attempt from the device with fingerprint $short was '
      'cancelled because its data did not match.';

  @override
  String noticeAttemptPeerCancelled(String short) =>
      'The device with fingerprint $short has cancelled the pairing.';

  @override
  String noticeAttemptsCancelled(int count) =>
      "$count pairing attempts were cancelled in the last few minutes. If it "
      "wasn't you, check your network.";

  @override
  String noticeAttemptLost(String short) =>
      'The device with fingerprint $short stopped responding after seeing the '
      'pairing code.';

  @override
  String noticeReplaceWithdrawn(String name) =>
      '$name showed up again, so it was not replaced.';

  @override
  String get noticePairingPaused =>
      'Pairing is paused for a few minutes after 3 failed attempts: this '
      'device will not accept new requests until then.';

  @override
  String noticeUnpairedByPeer(String name) => '$name has unpaired this device.';

  @override
  String noticeUnpairNotSaved(String name) =>
      '$name is unpaired until you close the app, but it could not be saved: '
      'if you restart, it would be paired again.';

  @override
  String get noticeChangeNotSaved =>
      'Your change applies until you close the app, but it could not be '
      'saved and will not be remembered.';

  @override
  String noticeIgnoreNotSaved(String name) =>
      '$name is ignored until you close the app, but it could not be saved '
      'and will not be remembered.';

  @override
  String noticePairingNotSaved(String who) =>
      'The pairing with $who could not be saved. Try again.';

  @override
  String noticePairingFailed(String who) =>
      'The pairing with $who could not be completed.';

  @override
  String noticeReceiveFolderNotSaved(String path) =>
      'Files will be saved in $path until you close the app, but it '
      "couldn't be remembered.";

  @override
  String noticePeerCancelledTransfer(String name) =>
      '$name cancelled the send.';

  @override
  String get noticeSharesNotSaved =>
      'The folder change could not be saved; after restarting it would be '
      'open again.';

  @override
  String get noticeShareAddNotSaved =>
      'The folder was added but will not be remembered after restarting.';

  @override
  String get noticeSharesReset =>
      'The shared folders file was damaged; no folder is open now.';

  @override
  String get noticeSharesPartlyReset =>
      'Folders of devices that are no longer paired were removed.';

  @override
  String get sendNeedsVisible => 'It has to be visible to send it files.';

  @override
  String get sendNeedsPairAgain => 'Pair it again before sending it files.';

  @override
  String get alreadySending => 'Wait for the current send to finish.';

  @override
  String get sendUnavailable =>
      "You can't send files to this device right now.";

  @override
  String get searchingDevices => 'Searching for devices…';

  @override
  String sendingToTitle(String name) => 'Sending to $name';

  @override
  String fileLine(String file, String size) => 'File: $file ($size)';

  @override
  String get programLabel => "It's a program";

  @override
  String get containsGitRepository =>
      'contains a Git repository, which can run code when opened';

  @override
  String preparingFile(String file) => 'Preparing $file…';

  @override
  String contactingPeer(String name) => 'Contacting $name…';

  @override
  String waitingAcceptance(String name) => 'Waiting for $name to accept…';

  @override
  String progressLine(int percent, String done, String total) =>
      '$percent% · $done of $total';

  @override
  String peerCheckingFile(String name) => '$name is checking the file…';

  @override
  String get cancellingTransfer => 'Cancelling…';

  @override
  String incomingRequestTitle(String name) => '$name wants to send you a file';

  @override
  String incomingFolderRequestTitle(String name) =>
      '$name wants to send you a folder';

  @override
  String get withoutMarkNote =>
      'It will be saved without the mark that tells Windows it comes from '
      "another device, because that drive doesn't support it.";

  @override
  String get acceptButton => 'Accept';

  @override
  String get rejectButton => 'Reject';

  @override
  String folderQuestionTitle(String name) => '$name is sending you a file';

  @override
  String get folderFirstTimeBody =>
      'Choose where to save the files you receive. '
      'It will be remembered for next time.';

  @override
  String get folderThisTimeBody =>
      "The usual folder isn't available right now. Choose where to save this "
      'file; next time the usual one will be used again.';

  @override
  String proposedFolderLine(String path) => 'Folder: $path';

  @override
  String get useThisFolderButton => 'Use this one';

  @override
  String get chooseOtherFolderButton => 'Choose another';

  @override
  String get pickerOpenNote => 'Choose a folder in the Windows window…';

  @override
  String folderForbidden(String path) =>
      "Received files can't be saved in $path. Choose another folder.";

  @override
  String folderCannotUse(String path) =>
      "$path can't be created or written to. Choose another folder.";

  @override
  String folderStillUnavailable(String path) =>
      '$path is still not available. Choose another folder.';

  @override
  String folderUnknownVolume(String path) =>
      "Windows doesn't identify the drive of $path, so it can't be used to "
      'receive files. Choose another folder.';

  @override
  String folderAdminShare(String path) =>
      "$path is in an administrative share of Windows, so it can't be used "
      'to receive files. Choose another folder.';

  @override
  String get checkingFolder => 'Checking the folder…';

  @override
  String cautionNoMark(String path) =>
      "Files saved in $path won't carry the mark that tells Windows they come "
      "from another device, so Windows won't warn you before opening a "
      'received program.';

  @override
  String cautionRemote(String path) =>
      '$path is on a network drive or in a folder synced with the cloud: what '
      'you receive may be uploaded to the cloud or depend on the network.';

  @override
  String get useAnywayButton => 'Use it anyway';

  @override
  String get transferAlreadyEnded => 'That send has already ended.';

  @override
  String folderRememberedNote(String path) =>
      'Files you receive will be saved in $path.';

  @override
  String folderNotUsable(String path) =>
      "$path can't be used, so it hasn't been remembered.";

  @override
  String get rememberAnywayButton => 'Remember it anyway';

  @override
  String get dontRememberButton => "Don't remember it";

  @override
  String receivingFromTitle(String name) => 'Receiving from $name';

  @override
  String get waitingForData => 'Waiting for the data…';

  @override
  String get checkingFile => 'Checking the file…';

  @override
  String get lastSentTitle => 'Last send';

  @override
  String get lastReceivedTitle => 'Last received';

  @override
  String toPeer(String name) => 'To $name';

  @override
  String fromPeer(String name) => 'From $name';

  @override
  String get showInFolderButton => 'Show in folder';

  @override
  String get revealFolderOnly =>
      "The folder was opened, but the file couldn't be selected. It may have "
      'been moved, renamed or deleted.';

  @override
  String get folderUnavailable => "That folder isn't available.";

  @override
  String sentOutcome(TransferOutcome outcome) => switch (outcome) {
    TransferOutcome.saved => 'It arrived intact.',
    TransferOutcome.savedWithoutMark =>
      'It arrived intact, but it was saved without the mark that tells '
          'Windows it comes from another device.',
    TransferOutcome.declined =>
      "The other device didn't accept it. You can try again in a minute.",
    TransferOutcome.busy =>
      'The other device is busy with another send. Try again in a moment.',
    TransferOutcome.unanswered => "The other device didn't respond.",
    TransferOutcome.invalidName =>
      "The other device doesn't accept that file name.",
    TransferOutcome.blockedType =>
      "The other device doesn't accept that type of file.",
    TransferOutcome.incompatible =>
      "Your request isn't compatible with the other device.",
    TransferOutcome.noSpace => "There isn't enough space on the other device.",
    TransferOutcome.noFolder =>
      "The other device hasn't chosen where to save the files.",
    TransferOutcome.pathTooLong =>
      'The path where the other device would save it is too long for Windows.',
    TransferOutcome.cancelledHere => 'You cancelled it.',
    TransferOutcome.cancelledByPeer => 'The other device cancelled it.',
    TransferOutcome.unpaired =>
      "It was cancelled because you're no longer paired.",
    TransferOutcome.unreadable => "The file couldn't be read.",
    TransferOutcome.noContact => "Couldn't contact the other device.",
    TransferOutcome.uploadNotStarted =>
      "It didn't complete: the transfer didn't start in time.",
    TransferOutcome.connectionLost =>
      'The connection was cut before it finished.',
    TransferOutcome.idle => 'It was cut because no data moved for 30 seconds.',
    TransferOutcome.tooManyBytes =>
      'It was cut because more data arrived than announced.',
    TransferOutcome.writeFailed =>
      "The other device couldn't write it (for example, because its disk is "
          'full).',
    TransferOutcome.diskFull =>
      "The other device's disk filled up while receiving it, so it was "
          'deleted.',
    TransferOutcome.damaged =>
      'It arrived damaged, so it was deleted. If the file changed while it '
          'was being sent, send it again.',
    TransferOutcome.markFailed =>
      "It couldn't be marked as coming from another device, so it was "
          'deleted.',
    TransferOutcome.moveFailed =>
      "It couldn't be moved to the folder, so it was deleted.",
    TransferOutcome.noFreeName =>
      "There was no free name for it in the folder, so it wasn't saved.",
    TransferOutcome.interfaceDown =>
      'It was cut because the network connection changed.',
    TransferOutcome.unconfirmed =>
      "Everything was sent, but the other device didn't confirm it: it's not "
          'known whether it arrived.',
    TransferOutcome.shortcut => 'Shortcuts are not sent.',
    TransferOutcome.wholeDrive =>
      "Whole drives can't be sent, only folders inside them.",
    TransferOutcome.protectedData =>
      "It can't be sent: it's NexusBridges' own data or an administrative "
          'resource.',
    TransferOutcome.notFound => 'It no longer exists.',
    TransferOutcome.tooManyEntries => 'The folder has too many items to send.',
    TransferOutcome.tooDeep => 'The folder has more than 64 levels.',
    TransferOutcome.tooLargeForPeer =>
      'The folder is too big for the other device.',
    TransferOutcome.unexpectedData =>
      "The other device sent data it hadn't announced.",
    TransferOutcome.defaultFolderOnly =>
      'The other device only accepts transfers to its default folder.',
    TransferOutcome.destinationUnavailable =>
      'That folder is no longer available on the other device.',
    TransferOutcome.destinationMissing =>
      'That folder no longer exists on the other device.',
    TransferOutcome.destinationLost =>
      'That folder stopped being available on the other device.',
    TransferOutcome.shareRemoved =>
      'You removed that folder from the ones the other device can use.',
    TransferOutcome.peerMarkedForeign =>
      "You marked the other device as someone else's.",
  };

  @override
  String receivedOutcome(TransferOutcome outcome) => switch (outcome) {
    TransferOutcome.saved => 'Saved.',
    TransferOutcome.savedWithoutMark =>
      'Saved without the mark that tells Windows it comes from another '
          'device.',
    TransferOutcome.declined => 'You rejected it.',
    TransferOutcome.busy =>
      'It was rejected because another send was in progress.',
    TransferOutcome.unanswered => 'It expired without an answer.',
    TransferOutcome.invalidName =>
      "It was rejected because its name isn't valid.",
    TransferOutcome.blockedType =>
      "It was rejected because that type of file isn't accepted.",
    TransferOutcome.incompatible =>
      "It was rejected because the request wasn't compatible.",
    TransferOutcome.noSpace =>
      "It was rejected because there isn't enough space: the file size plus "
          '1 GB must be free.',
    TransferOutcome.noFolder =>
      "It was rejected because you didn't choose where to save it.",
    TransferOutcome.pathTooLong =>
      'It was rejected because the path where it would be saved is too long '
          'for Windows.',
    TransferOutcome.cancelledHere => 'You cancelled it.',
    TransferOutcome.cancelledByPeer => 'The other device cancelled it.',
    TransferOutcome.unpaired =>
      "It was cancelled because you're no longer paired.",
    TransferOutcome.unreadable =>
      'The other device could no longer read the file.',
    TransferOutcome.noContact => "Couldn't contact the other device.",
    TransferOutcome.uploadNotStarted =>
      "It didn't complete: the transfer didn't start in time.",
    TransferOutcome.connectionLost =>
      'The connection was cut before it finished.',
    TransferOutcome.idle => 'It was cut because no data moved for 30 seconds.',
    TransferOutcome.tooManyBytes =>
      'It was cut because more data arrived than announced.',
    TransferOutcome.writeFailed =>
      "It couldn't be written (for example, because the disk is full), so it "
          'was deleted.',
    TransferOutcome.diskFull =>
      'The disk filled up while receiving it, so it was deleted.',
    TransferOutcome.damaged => 'It arrived damaged, so it was deleted.',
    TransferOutcome.markFailed =>
      "It couldn't be marked as coming from another device, so it was "
          'deleted.',
    TransferOutcome.moveFailed =>
      "It couldn't be moved to the folder, so it was deleted.",
    TransferOutcome.noFreeName =>
      "There was no free name for it in the folder, so it wasn't saved.",
    TransferOutcome.interfaceDown =>
      'It was cut because the network connection changed.',
    TransferOutcome.unconfirmed =>
      "Everything was sent, but it wasn't confirmed.",
    TransferOutcome.shortcut =>
      "It was rejected because shortcuts aren't accepted.",
    TransferOutcome.wholeDrive =>
      "It was rejected because whole drives aren't accepted.",
    TransferOutcome.protectedData =>
      "It was rejected because NexusBridges' own data is never sent.",
    TransferOutcome.notFound => 'It no longer existed on the other device.',
    TransferOutcome.tooManyEntries =>
      'It was rejected because the folder has too many items.',
    TransferOutcome.tooDeep =>
      'It was rejected because the folder has more than 64 levels.',
    TransferOutcome.tooLargeForPeer =>
      'It was rejected because the folder is too big.',
    TransferOutcome.unexpectedData =>
      "It was cut because data arrived that hadn't been announced.",
    TransferOutcome.defaultFolderOnly =>
      'The other device only accepts transfers to its default folder.',
    TransferOutcome.destinationUnavailable =>
      'That folder is no longer available on the other device.',
    TransferOutcome.destinationMissing =>
      'That folder no longer exists on the other device.',
    TransferOutcome.destinationLost =>
      'That folder stopped being available on the other device.',
    TransferOutcome.shareRemoved =>
      'You removed that folder from the ones the other device can use.',
    TransferOutcome.peerMarkedForeign =>
      "You marked the other device as someone else's.",
  };

  @override
  String get closeDuringTransferTitle => 'A send is in progress';

  @override
  String get closeDuringTransferBody =>
      'If you close the app now, the send will be cancelled.';

  @override
  String get closeWithQueuesBody =>
      'If you close the app now, the send will be cancelled and what is '
      'still waiting will not be sent.';

  @override
  String get keepOpenButton => 'Keep open';

  @override
  String get closeAndCancelButton => 'Close and cancel';

  @override
  String get trustedNetworkLabel => 'Trusted network';

  @override
  String get onlyPairedCanSend => 'Only your paired devices can send you files';

  @override
  String get activityTab => 'Activity';

  @override
  String get devicesTab => 'Devices';

  @override
  String get activityEmpty =>
      "Here you'll see the send in progress and the last file you sent or "
      'received.';

  @override
  String get sectionUnpaired => 'Unpaired';

  @override
  String get chipMine => 'Mine';

  @override
  String get chipForeign => "Someone else's";

  @override
  String get visibleLabel => 'Visible';

  @override
  String get diagramTitle => 'My network';

  @override
  String diagramCount(int total, int visible) =>
      "${total == 1 ? '1 device' : '$total devices'} · $visible visible";

  @override
  String thisDeviceCaption(String short) =>
      short.isEmpty ? 'this device' : '$short · this device';

  @override
  String get chipPreparing => 'Preparing';

  @override
  String get chipWaiting => 'Waiting';

  @override
  String get chipInProgress => 'In progress';

  @override
  String get chipChecking => 'Checking';

  @override
  String get chipDelivered => 'Delivered';

  @override
  String get chipSaved => 'Saved';

  @override
  String get chipRejected => 'Rejected';

  @override
  String get chipCancelled => 'Cancelled';

  @override
  String get chipFailed => 'Failed';

  @override
  String get chipUnconfirmed => 'Unconfirmed';

  @override
  String foreignSenderNote(String short) =>
      "It's someone else's device (fingerprint $short). Accept only if you "
      'were expecting it.';

  @override
  String get incomingExpiresNote =>
      "If you don't answer, this request expires after a minute.";

  @override
  String get sendEllipsis => 'Send…';

  @override
  String get sendFilesOption => 'Files…';

  @override
  String get sendFoldersOption => 'Folders…';

  @override
  String preparingItems(int count) =>
      'Preparing… ${formatCount(count, 'en')} '
      "${count == 1 ? 'item' : 'items'} found";

  @override
  String folderSummary(int files, String size) =>
      "${formatCount(files, 'en')} ${files == 1 ? 'file' : 'files'} · $size";

  @override
  String foldersLeftOut(int count, String? size) =>
      "${formatCount(count, 'en')} ${count == 1 ? 'folder' : 'folders'} left "
      "out${size == null ? '' : ' ($size)'}";

  @override
  String linksNotFollowed(int count) =>
      "${formatCount(count, 'en')} ${count == 1 ? 'link' : 'links'} not "
      'followed';

  @override
  String get appDataLeftOut => "NexusBridges' own data is never sent";

  @override
  String blockedLeftOut(int count) => count == 1
      ? '1 file is not sent: shortcuts and Explorer system files'
      : "${formatCount(count, 'en')} files are not sent: shortcuts and "
            'Explorer system files';

  @override
  String get containsPrograms => 'contains programs';

  @override
  String filesProgress(int done, int total) =>
      "${formatCount(done, 'en')} of ${formatCount(total, 'en')} "
      "${total == 1 ? 'file' : 'files'}";

  @override
  String firstLevelMore(int count) => "and ${formatCount(count, 'en')} more";

  @override
  String outcomeUnreadableEntry(String path) =>
      "Couldn't be read or changed while sending: $path";

  @override
  String outcomeInvalidNameEntry(String path) =>
      "This name can't be used on the other device: $path";

  @override
  String get outcomeFolderIncompatible =>
      "The other device can't receive folders; it may need to update "
      'NexusBridges';

  @override
  String queueTitle(String name) => 'Sending to $name';

  @override
  String get looseQueue => 'Files';

  @override
  String get bundleQueue => 'Folders and archives';

  @override
  String get queuePending => 'Waiting';

  @override
  String queueNotSent(String reason) => 'Not sent: $reason';

  @override
  String get queueRemove => 'Remove';

  @override
  String get queueCancelAll => 'Cancel all';

  @override
  String queueRemaining(int count) =>
      "${formatCount(count, 'en')} left in the queue";

  @override
  String get queueLastItem => 'Last item';

  @override
  String deliveredSummary(int delivered, int total) =>
      "${formatCount(delivered, 'en')} of ${formatCount(total, 'en')} "
      'delivered';

  @override
  String waitForQueues(String name) => 'Wait for the sends to $name to finish';

  @override
  String get tooManySelected => 'You can send up to 1,000 items at a time';

  @override
  String trayTitle(int count) => "To send (${formatCount(count, 'en')})";

  @override
  String get trayRemoveAll => 'Remove all';

  @override
  String traySendTo(String name) => 'Send to $name';

  @override
  String get trayFull => 'The To send tray holds up to 1,000 items';

  @override
  String get trayNothingNew => 'Already in To send';

  @override
  String get dragHint => 'Drop on a device · anywhere else goes to To send';

  @override
  String get dragTipTitle => 'Drag and drop';

  @override
  String get dragTipBody => 'On a device to send it; anywhere else to To send';
}
