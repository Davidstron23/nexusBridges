import 'package:flutter_test/flutter_test.dart';
import 'package:nexus_bridges/src/l10n/app_strings.dart';

typedef _Text = String Function(AppStrings strings);

const String _net = 'Casa';
const String _date = '30/10/2026';

final Map<String, _Text> _texts = {
  'settingsButton': (s) => s.settingsButton,
  'settingsTitle': (s) => s.settingsTitle,
  'settingsSubtitle': (s) => s.settingsSubtitle('PC'),
  'settingsBack': (s) => s.settingsBack,
  'settingsNavFoot': (s) => s.settingsNavFoot,
  'settingsFooter': (s) => s.settingsFooter,
  'moreInfo': (s) => s.moreInfo('x'),
  'sectionAppearance': (s) => s.sectionAppearance,
  'appearanceInfo': (s) => s.appearanceInfo,
  'themeDark': (s) => s.themeDark,
  'themeLight': (s) => s.themeLight,
  'themeWindows': (s) => s.themeWindows,
  'sectionLanguage': (s) => s.sectionLanguage,
  'languageSpanish': (s) => s.languageSpanish,
  'languageEnglish': (s) => s.languageEnglish,
  'sectionDevice': (s) => s.sectionDevice,
  'deviceNameLabel': (s) => s.deviceNameLabel,
  'deviceNameDesc': (s) => s.deviceNameDesc,
  'deviceNameInfo': (s) => s.deviceNameInfo,
  'saveButton': (s) => s.saveButton,
  'useWindowsName': (s) => s.useWindowsName('W'),
  'nameEmpty': (s) => s.nameEmpty,
  'nameTooLong': (s) => s.nameTooLong,
  'nameInvalid': (s) => s.nameInvalid,
  'nameNamesake': (s) => s.nameNamesake,
  'sectionReceive': (s) => s.sectionReceive,
  'receiveDesc': (s) => s.receiveDesc,
  'receiveInfo': (s) => s.receiveInfo,
  'receiveNotSet': (s) => s.receiveNotSet,
  'changeFolderButton': (s) => s.changeFolderButton,
  'changeFolderLocked': (s) => s.changeFolderLocked,
  'sectionExclusions': (s) => s.sectionExclusions,
  'ofMax': (s) => s.ofMax(3, 64),
  'exclusionsDesc': (s) => s.exclusionsDesc,
  'exclusionsInfo': (s) => s.exclusionsInfo,
  'exclusionsEmpty': (s) => s.exclusionsEmpty,
  'exclusionPlaceholder': (s) => s.exclusionPlaceholder,
  'addButton': (s) => s.addButton,
  'removeExclusion': (s) => s.removeExclusion('dist'),
  'exclusionEmpty': (s) => s.exclusionEmpty,
  'exclusionInvalid': (s) => s.exclusionInvalid,
  'exclusionDuplicate': (s) => s.exclusionDuplicate,
  'exclusionFull': (s) => s.exclusionFull,
  'restoreDefaults': (s) => s.restoreDefaults,
  'restoreConfirm': (s) => s.restoreConfirm,
  'restoreButton': (s) => s.restoreButton,
  'sectionSystemTray': (s) => s.sectionSystemTray,
  'systemTrayInfo': (s) => s.systemTrayInfo,
  'systemTraySwitch': (s) => s.systemTraySwitch,
  'systemTraySwitchHelp': (s) => s.systemTraySwitchHelp,
  'sendFilesOrFolders': (s) => s.sendFilesOrFolders,
  'systemTrayOffHelp': (s) => s.systemTrayOffHelp,
  'sectionNetworks': (s) => s.sectionNetworks,
  'networksInfo': (s) => s.networksInfo,
  'connectedNow': (s) => s.connectedNow,
  'unnamedNetwork': (s) => s.unnamedNetwork,
  'networksEmpty': (s) => s.networksEmpty,
  'trustedOn': (s) => s.trustedOn(_date),
  'stopUsingButton': (s) => s.stopUsingButton,
  'stopUsingConfirm': (s) => s.stopUsingConfirm(_net),
  'transfersStopped1': (s) => s.transfersStopped(1),
  'transfersStoppedN': (s) => s.transfersStopped(3),
  'pairingCancelled': (s) => s.pairingCancelled,
  'stopUsingConfirmButton': (s) => s.stopUsingConfirmButton,
  'noticeNetworkStopNotSaved': (s) => s.noticeNetworkStopNotSaved(_net),
  'sectionIgnored': (s) => s.sectionIgnored,
  'ignoredInfo': (s) => s.ignoredInfo,
  'ignoredEmpty': (s) => s.ignoredEmpty,
  'ignoredOn': (s) => s.ignoredOn(_date),
  'noticeSettingNotSaved': (s) => s.noticeSettingNotSaved,
};

const Set<String> _sameInBoth = {
  'themeWindows',
  'languageSpanish',
  'languageEnglish',
};

final Map<String, (String, String)> _specTable = {
  'connectedNow': ('Connected now', 'Conectada ahora'),
  'trustedOn': ('Trusted on $_date', 'Aceptada el $_date'),
  'unnamedNetwork': ('Unnamed network', 'Red sin nombre'),
  'networksEmpty': (
    'You are not using NexusBridges on any network yet',
    'A\u{FA}n no usas NexusBridges en ninguna red',
  ),
  'stopUsingButton': (
    'Stop using on this network',
    'Dejar de usar en esta red',
  ),
  'stopUsingConfirm': (
    'Stop using NexusBridges on $_net? You are connected to it: the app will '
        'pause here and your other devices will stop seeing this one.',
    '\u{BF}Dejar de usar NexusBridges en $_net? Est\u{E1}s conectado a ella: '
        'la app se pondr\u{E1} en pausa aqu\u{ED} y tus otros equipos '
        'dejar\u{E1}n de ver este.',
  ),
  'transfersStopped1': (
    '1 transfer in progress will be stopped.',
    'Se cortar\u{E1} 1 env\u{ED}o en curso.',
  ),
  'transfersStoppedN': (
    '3 transfers in progress will be stopped.',
    'Se cortar\u{E1}n 3 env\u{ED}os en curso.',
  ),
  'pairingCancelled': (
    'The pairing in progress will be cancelled.',
    'Se cancelar\u{E1} la vinculaci\u{F3}n en curso.',
  ),
  'stopUsingConfirmButton': ('Stop using', 'Dejar de usar'),
  'noticeNetworkStopNotSaved': (
    'You stopped using $_net until you close the app, but this could not be '
        'saved: it would be used again next time.',
    'Has dejado de usar $_net hasta que cierres la app, pero no se ha podido '
        'guardar: al volver a abrirla se usar\u{ED}a otra vez.',
  ),
  'sectionNetworks': ('Trusted networks', 'Redes de confianza'),
  'sectionIgnored': ('Ignored devices', 'Equipos ignorados'),
  'ignoredInfo': (
    'These devices cannot ask to pair with you.',
    'Estos equipos no pueden pedirte vincularse.',
  ),
  'ignoredOn': ('Ignored on $_date', 'Ignorado el $_date'),
  'ignoredEmpty': (
    'You have not ignored any device',
    'No has ignorado ning\u{FA}n equipo',
  ),
  'nameInvalid': (
    "It has characters others wouldn't see the same way: invisible or control "
        'characters, or parts of some combined emojis. Remove them or type the '
        'name by hand.',
    'Tiene caracteres que los dem\u{E1}s no ver\u{ED}an igual: invisibles, de '
        'control o partes de algunos emojis compuestos. Qu\u{ED}talos o '
        'escribe el nombre a mano.',
  ),
  'themeDark': ('Dark', 'Oscuro'),
  'themeLight': ('Light', 'Claro'),
  'themeWindows': ('Windows', 'Windows'),
  'receiveNotSet': (
    "You'll be asked the first time you receive something",
    'Se preguntar\u{E1} la primera vez que recibas algo',
  ),
  'settingsFooter': (
    'Everything is saved at once, except the name: Enter or Save.',
    'Todo se guarda al momento, salvo el nombre: Intro o Guardar.',
  ),
};

void main() {
  final en = stringsFor('en');
  final es = stringsFor('es');

  group('E858 the texts of spec 008 exist in both languages (RNF)', () {
    test('every text is filled in, without placeholders or long dashes', () {
      for (final entry in _texts.entries) {
        for (final strings in [en, es]) {
          final text = entry.value(strings);
          expect(text.trim(), isNotEmpty, reason: entry.key);
          expect(text, isNot(contains(r'$')), reason: entry.key);
          expect(text, isNot(contains('{')), reason: entry.key);
          expect(text, isNot(contains('\u{2014}')), reason: entry.key);
        }
      }
    });

    test('each text differs between the languages, except the brand-like '
        'ones', () {
      for (final entry in _texts.entries) {
        if (_sameInBoth.contains(entry.key)) continue;
        expect(entry.value(en), isNot(entry.value(es)), reason: entry.key);
      }
    });

    test('the texts of the spec tables and of D-c say what they must', () {
      for (final entry in _specTable.entries) {
        final read = _texts[entry.key]!;
        expect(read(en), entry.value.$1, reason: '${entry.key} en');
        expect(read(es), entry.value.$2, reason: '${entry.key} es');
      }
    });

    test('the network explanation keeps its meaning (pause on the other '
        'networks)', () {
      expect(es.networksInfo.toLowerCase(), contains('pausa'));
      expect(en.networksInfo.toLowerCase(), contains('paused'));
    });

    test('the send button of a row says what it sends', () {
      expect(
        stringsFor('es').sendFilesOrFolders,
        'Enviar archivos o carpetas…',
      );
      expect(stringsFor('en').sendFilesOrFolders, 'Send files or folders…');
    });

    test('the tray switch explains closing the window', () {
      expect(
        stringsFor('es').systemTraySwitchHelp,
        'Al cerrar la ventana se sigue recibiendo con la app en segundo plano',
      );
      expect(
        stringsFor('en').systemTraySwitchHelp,
        'Closing the window keeps receiving with the app in the background',
      );
    });

    test('the arguments end up in the text', () {
      for (final strings in [en, es]) {
        expect(strings.settingsSubtitle('Torre'), contains('Torre'));
        expect(strings.useWindowsName('DESKTOP-1'), contains('DESKTOP-1'));
        expect(strings.removeExclusion('dist'), contains('dist'));
        expect(strings.ofMax(7, 64), allOf(contains('7'), contains('64')));
        expect(strings.moreInfo('abc'), contains('abc'));
      }
    });

    test('the setting notice is not the old generic one', () {
      for (final strings in [en, es]) {
        expect(
          strings.noticeSettingNotSaved,
          isNot(strings.noticeChangeNotSaved),
        );
      }
    });
  });
}
