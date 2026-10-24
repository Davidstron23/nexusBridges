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
  String compareCode(String name) => 'Check that $name shows this code:';

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
}
