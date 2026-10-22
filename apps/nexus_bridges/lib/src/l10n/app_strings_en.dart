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
}
