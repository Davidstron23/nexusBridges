import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

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
