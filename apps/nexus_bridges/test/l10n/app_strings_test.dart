import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nexus_bridges/src/l10n/app_strings.dart';
import 'package:nexus_bridges/src/l10n/app_strings_en.dart';
import 'package:nexus_bridges/src/l10n/app_strings_es.dart';

typedef _Text = String Function(AppStrings strings);

const String _sampleName = 'Casa de Ana';
const int _samplePort = 53530;

final Map<String, _Text> _texts = {
  'appTitle': (s) => s.appTitle,
  'devicesTitle': (s) => s.devicesTitle,
  'noDevicesYet': (s) => s.noDevicesYet,
  'rescanHint': (s) => s.rescanHint,
  'rescanButton': (s) => s.rescanButton,
  'pausedBanner': (s) => s.pausedBanner,
  'trustNetworkButton': (s) => s.trustNetworkButton(_sampleName),
  'networkPromptTitle': (s) => s.networkPromptTitle,
  'networkPromptBody': (s) => s.networkPromptBody(_sampleName),
  'yes': (s) => s.yes,
  'no': (s) => s.no,
  'pairedLabel': (s) => s.pairedLabel,
  'notPairedLabel': (s) => s.notPairedLabel,
  'deviceTypeDesktop': (s) => s.deviceTypeDesktop,
  'deviceTypeMobile': (s) => s.deviceTypeMobile,
  'identityResetWarning': (s) => s.identityResetWarning,
  'identityFailed': (s) => s.identityFailed,
  'portInUse': (s) => s.portInUse(_samplePort),
  'retryButton': (s) => s.retryButton,
  'decisionNotSaved': (s) => s.decisionNotSaved,
  'closeButton': (s) => s.closeButton,
  'pairButton': (s) => s.pairButton,
  'unpairButton': (s) => s.unpairButton,
  'moreOptions': (s) => s.moreOptions,
  'notVisibleLabel': (s) => s.notVisibleLabel,
  'pairedMineLabel': (s) => s.pairedMineLabel,
  'pairedForeignLabel': (s) => s.pairedForeignLabel,
  'markAsMine': (s) => s.markAsMine,
  'markAsForeign': (s) => s.markAsForeign,
  'ignoredLabel': (s) => s.ignoredLabel,
  'unignoreButton': (s) => s.unignoreButton,
  'mismatchWarning': (s) => s.mismatchWarning,
  'removeButton': (s) => s.removeButton,
  'pairAgainButton': (s) => s.pairAgainButton,
  'possibleReinstall': (s) => s.possibleReinstall(_sampleName),
  'pairingAlreadyInProgress': (s) => s.pairingAlreadyInProgress,
  'tooManyPaired': (s) => s.tooManyPaired,
  'pairUnavailable': (s) => s.pairUnavailable,
  'pairingWithTitle': (s) => s.pairingWithTitle(_sampleName),
  'connectingTo': (s) => s.connectingTo(_sampleName),
  'compareCode': (s) => s.compareCode(_sampleName),
  'matchesButton': (s) => s.matchesButton,
  'doesNotMatchButton': (s) => s.doesNotMatchButton,
  'cancelButton': (s) => s.cancelButton,
  'waitingForPeer': (s) => s.waitingForPeer(_sampleName),
  'pairingRequestTitle': (s) => s.pairingRequestTitle(_sampleName),
  'fingerprintLine': (s) => s.fingerprintLine(_sampleShort),
  'alreadyPairedNote': (s) => s.alreadyPairedNote,
  'ignoreDeviceButton': (s) => s.ignoreDeviceButton,
  'receiverWaiting': (s) => s.receiverWaiting(_sampleName),
  'pairingResultTitle': (s) => s.pairingResultTitle,
  'outcomePaired': (s) => s.outcomePaired(_sampleName),
  'outcomeRejected': (s) => s.outcomeRejected(_sampleName),
  'outcomeBusy': (s) => s.outcomeBusy(_sampleName),
  'outcomePaused': (s) => s.outcomePaused(_sampleName),
  'outcomeCancelledByPeer': (s) => s.outcomeCancelledByPeer(_sampleName),
  'outcomeExpired': (s) => s.outcomeExpired,
  'outcomeLost': (s) => s.outcomeLost(_sampleName),
  'outcomeNetworkChanged': (s) => s.outcomeNetworkChanged,
  'outcomeFailed': (s) => s.outcomeFailed(_sampleName),
  'outcomeNotSaved': (s) => s.outcomeNotSaved,
  'replaceTitle': (s) => s.replaceTitle(_sampleOldName),
  'replaceBody': (s) => s.replaceBody(_sampleName, _sampleOldName),
  'replaceButton': (s) => s.replaceButton,
  'keepBothButton': (s) => s.keepBothButton,
  'mineTitle': (s) => s.mineTitle(_sampleName),
  'mineBody': (s) => s.mineBody,
  'mineYesButton': (s) => s.mineYesButton,
  'mineNoButton': (s) => s.mineNoButton,
  'unpairTitle': (s) => s.unpairTitle(_sampleName),
  'unpairBody': (s) => s.unpairBody(_sampleName),
  'noticeAttemptCancelled': (s) => s.noticeAttemptCancelled(_sampleShort),
  'noticeAttemptPeerCancelled': (s) =>
      s.noticeAttemptPeerCancelled(_sampleShort),
  'noticeAttemptsCancelled': (s) => s.noticeAttemptsCancelled(_sampleCount),
  'noticePairingPaused': (s) => s.noticePairingPaused,
  'noticeUnpairedByPeer': (s) => s.noticeUnpairedByPeer(_sampleName),
  'noticeUnpairNotSaved': (s) => s.noticeUnpairNotSaved(_sampleName),
  'noticeChangeNotSaved': (s) => s.noticeChangeNotSaved,
  'noticeIgnoreNotSaved': (s) => s.noticeIgnoreNotSaved(_sampleName),
  'noticePairingNotSaved': (s) => s.noticePairingNotSaved(_sampleName),
  'noticePairingFailed': (s) => s.noticePairingFailed(_sampleName),
};

const String _sampleShort = 'ABCD1234';
const String _sampleOldName = 'Portátil · 9999AAAA';
const int _sampleCount = 4;

const Set<String> _withName = {
  'possibleReinstall',
  'pairingWithTitle',
  'connectingTo',
  'compareCode',
  'waitingForPeer',
  'pairingRequestTitle',
  'receiverWaiting',
  'outcomePaired',
  'outcomeRejected',
  'outcomeBusy',
  'outcomePaused',
  'outcomeCancelledByPeer',
  'outcomeLost',
  'outcomeFailed',
  'replaceBody',
  'mineTitle',
  'unpairTitle',
  'unpairBody',
  'noticeUnpairedByPeer',
  'noticeUnpairNotSaved',
  'noticeIgnoreNotSaved',
  'noticePairingNotSaved',
  'noticePairingFailed',
};

const Set<String> _withShort = {
  'fingerprintLine',
  'noticeAttemptCancelled',
  'noticeAttemptPeerCancelled',
};

const Set<String> _withOldName = {'replaceTitle', 'replaceBody'};

const Set<String> _meaningOnly = {
  'noticeAttemptCancelled',
  'noticePairingNotSaved',
  'noticePairingFailed',
};

final Map<String, (String, String)> _expectedPairing = {
  'pairButton': ('Pair', 'Vincular'),
  'unpairButton': ('Unpair', 'Desvincular'),
  'moreOptions': ('More options', 'Más opciones'),
  'notVisibleLabel': ('Not visible', 'No visible'),
  'pairedMineLabel': ('Paired · Mine', 'Vinculado · Mío'),
  'pairedForeignLabel': ("Paired · Someone else's", 'Vinculado · Ajeno'),
  'markAsMine': ('Mark as mine', 'Marcar como mío'),
  'markAsForeign': ("Mark as someone else's", 'Marcar como ajeno'),
  'ignoredLabel': ('Ignored', 'Ignorado'),
  'unignoreButton': ('Stop ignoring', 'Dejar de ignorar'),
  'mismatchWarning': (
    'This device no longer has you paired.',
    'Ya no te tiene vinculado.',
  ),
  'removeButton': ('Remove', 'Quitar'),
  'pairAgainButton': ('Pair again', 'Volver a vincular'),
  'possibleReinstall': (
    'It has the same name as $_sampleName, which is paired and not visible. '
        'It may be that device after a reinstall, or someone pretending to '
        'be it.',
    'Tiene el mismo nombre que $_sampleName, que está vinculado y no está a '
        'la vista. Puede ser ese equipo reinstalado o alguien haciéndose '
        'pasar por él.',
  ),
  'pairingAlreadyInProgress': (
    'There is already a pairing in progress.',
    'Ya hay una vinculación en curso.',
  ),
  'tooManyPaired': (
    'You already have 32 paired devices. Unpair one to pair a new one.',
    'Ya tienes 32 equipos vinculados. Desvincula alguno para vincular otro.',
  ),
  'pairUnavailable': (
    "This device can't be paired right now.",
    'Ahora no se puede vincular este equipo.',
  ),
  'pairingWithTitle': (
    'Pairing with $_sampleName',
    'Vinculando con $_sampleName',
  ),
  'connectingTo': (
    'Connecting to $_sampleName…',
    'Conectando con $_sampleName…',
  ),
  'compareCode': (
    'Check that $_sampleName shows this code:',
    'Comprueba que $_sampleName muestra este código:',
  ),
  'matchesButton': ('It matches', 'Coincide'),
  'doesNotMatchButton': ("It doesn't match", 'No coincide'),
  'cancelButton': ('Cancel', 'Cancelar'),
  'waitingForPeer': (
    'Waiting for the code to be confirmed on $_sampleName…',
    'Esperando a que se confirme el código en $_sampleName…',
  ),
  'pairingRequestTitle': (
    '$_sampleName wants to pair',
    '$_sampleName quiere vincularse',
  ),
  'fingerprintLine': ('Fingerprint: $_sampleShort', 'Huella: $_sampleShort'),
  'alreadyPairedNote': (
    'This device is already paired. If you confirm, it stays as it is.',
    'Este equipo ya está vinculado. Si confirmas, se queda como está.',
  ),
  'ignoreDeviceButton': ('Ignore this device', 'Ignorar este dispositivo'),
  'receiverWaiting': (
    'You have confirmed the code. Waiting for $_sampleName to confirm it '
        'too…',
    'Has confirmado el código. Esperando a que $_sampleName también lo '
        'confirme…',
  ),
  'pairingResultTitle': ('Pairing', 'Vinculación'),
  'outcomePaired': (
    '$_sampleName is now paired.',
    '$_sampleName ya está vinculado.',
  ),
  'outcomeRejected': (
    '$_sampleName has not accepted the pairing.',
    '$_sampleName no ha aceptado la vinculación.',
  ),
  'outcomeBusy': (
    '$_sampleName is busy with another pairing. Try again in a minute.',
    '$_sampleName está ocupado con otra vinculación. '
        'Inténtalo dentro de un minuto.',
  ),
  'outcomePaused': (
    '$_sampleName is not accepting pairings for a few minutes.',
    '$_sampleName no admite vinculaciones durante unos minutos.',
  ),
  'noticeAttemptPeerCancelled': (
    'The device with fingerprint $_sampleShort has cancelled the pairing.',
    'El equipo con huella $_sampleShort ha cancelado la vinculación.',
  ),
  'noticeAttemptsCancelled': (
    '$_sampleCount pairing attempts were cancelled in the last few minutes. '
        "If it wasn't you, check your network.",
    'Se han cancelado $_sampleCount intentos de vinculación en los últimos '
        'minutos. Si no has sido tú, revisa tu red.',
  ),
  'noticePairingPaused': (
    'Pairing is paused for a few minutes after 3 failed attempts: this '
        'device will not accept new requests until then.',
    'Vinculaciones en pausa durante unos minutos tras 3 intentos fallidos: '
        'este equipo no acepta peticiones nuevas hasta entonces.',
  ),
  'outcomeCancelledByPeer': (
    '$_sampleName has cancelled the pairing. Nothing has been saved.',
    '$_sampleName ha cancelado la vinculación. No se ha guardado nada.',
  ),
  'outcomeExpired': (
    'The pairing has expired. Nothing has been saved.',
    'La vinculación ha caducado. No se ha guardado nada.',
  ),
  'outcomeLost': (
    '$_sampleName has stopped responding. Nothing has been saved.',
    '$_sampleName ha dejado de responder. No se ha guardado nada.',
  ),
  'outcomeNetworkChanged': (
    'The pairing was cancelled because the network changed.',
    'La vinculación se ha cancelado porque ha cambiado la red.',
  ),
  'outcomeFailed': (
    'Could not pair with $_sampleName.',
    'No se ha podido vincular con $_sampleName.',
  ),
  'outcomeNotSaved': (
    'The pairing could not be saved, so it has not been completed.',
    'No se ha podido guardar la vinculación, así que no se ha completado.',
  ),
  'replaceTitle': ('Replace $_sampleOldName?', '¿Sustituir a $_sampleOldName?'),
  'replaceBody': (
    '$_sampleName has the same name as $_sampleOldName, which is paired but '
        'not visible. If it is the same device after a reinstall, replace it '
        'to remove the old pairing.',
    '$_sampleName tiene el mismo nombre que $_sampleOldName, que está '
        'vinculado pero no está a la vista. Si es el mismo equipo '
        'reinstalado, sustitúyelo para quitar la vinculación antigua.',
  ),
  'replaceButton': ('Replace', 'Sustituir'),
  'keepBothButton': ('Keep both', 'Conservar los dos'),
  'mineTitle': ('Paired with $_sampleName', 'Vinculado con $_sampleName'),
  'mineBody': (
    'Is this device yours? If it is, what it sends will come in without '
        'asking and it will be able to browse the folders you share. If it '
        'belongs to someone else, it will always ask for your permission.',
    '¿Este equipo es tuyo? Si es tuyo, lo que envíe entrará sin preguntar y '
        'podrá explorar las carpetas que compartas. Si es de otra persona, '
        'siempre te pedirá permiso.',
  ),
  'mineYesButton': ("It's mine", 'Es mío'),
  'mineNoButton': ("It's someone else's", 'Es de otra persona'),
  'unpairTitle': ('Unpair $_sampleName?', '¿Desvincular $_sampleName?'),
  'unpairBody': (
    '$_sampleName will no longer be able to connect to this device, starting '
        'now. To use it again you will have to pair them again.',
    '$_sampleName dejará de poder conectarse con este equipo desde ahora. '
        'Para volver a usarlo tendréis que vincularlos otra vez.',
  ),
  'noticeUnpairedByPeer': (
    '$_sampleName has unpaired this device.',
    '$_sampleName ha desvinculado este equipo.',
  ),
  'noticeUnpairNotSaved': (
    '$_sampleName is unpaired until you close the app, but it could not be '
        'saved: if you restart, it would be paired again.',
    '$_sampleName está desvinculado hasta que cierres la app, pero no se ha '
        'podido guardar: si la reinicias, volvería a estar vinculado.',
  ),
  'noticeChangeNotSaved': (
    'Your change applies until you close the app, but it could not be saved '
        'and will not be remembered.',
    'Tu cambio se aplica hasta que cierres la app, pero no se ha podido '
        'guardar y no se recordará.',
  ),
  'noticeIgnoreNotSaved': (
    '$_sampleName is ignored until you close the app, but it could not be '
        'saved and will not be remembered.',
    '$_sampleName queda ignorado hasta que cierres la app, pero no se ha '
        'podido guardar y no se recordará.',
  ),
};

final Map<String, (String, String)> _expected = {
  'appTitle': ('NexusBridges', 'NexusBridges'),
  'devicesTitle': ('Devices nearby', 'Equipos cerca'),
  'noDevicesYet': ('No devices found yet', 'Todavía no hay equipos'),
  'rescanHint': (
    'No devices found. Some networks block devices from seeing each other.',
    'No se encuentran equipos. '
        'Algunas redes impiden que los equipos se vean entre sí.',
  ),
  'rescanButton': ('Search again', 'Buscar de nuevo'),
  'pausedBanner': (
    'NexusBridges is paused on this network',
    'NexusBridges está en pausa en esta red',
  ),
  'trustNetworkButton': ('Use on "$_sampleName"', 'Usar en "$_sampleName"'),
  'networkPromptTitle': (
    'Use NexusBridges on this network?',
    '¿Usar NexusBridges en esta red?',
  ),
  'networkPromptBody': (
    'Other devices on "$_sampleName" will be able to see this device. '
        'Only say yes on networks you trust, like your home.',
    'Los demás equipos de "$_sampleName" podrán ver este equipo. '
        'Di que sí solo en redes en las que confíes, como la de tu casa.',
  ),
  'yes': ('Use it here', 'Usar aquí'),
  'no': ('Not on this network', 'En esta red no'),
  'pairedLabel': ('Paired', 'Vinculado'),
  'notPairedLabel': ('Not paired', 'No vinculado'),
  'deviceTypeDesktop': ('Computer', 'Ordenador'),
  'deviceTypeMobile': ('Phone', 'Teléfono'),
  'identityResetWarning': (
    'This device has a new identity. '
        'You will need to pair it again with your other devices.',
    'Este equipo tiene una identidad nueva. '
        'Tendrás que volver a vincularlo con tus otros equipos.',
  ),
  'identityFailed': (
    "NexusBridges could not create this device's identity.",
    'NexusBridges no ha podido crear la identidad de este equipo.',
  ),
  'portInUse': (
    'Port $_samplePort is being used by another program.',
    'El puerto $_samplePort lo está usando otro programa.',
  ),
  'retryButton': ('Retry', 'Reintentar'),
  'decisionNotSaved': (
    'Your choice will apply until you close the app, '
        'but it could not be saved.',
    'Tu elección se aplicará hasta que cierres la app, '
        'pero no se ha podido guardar.',
  ),
  'closeButton': ('Close', 'Cerrar'),
};

void main() {
  final english = AppStringsEn();
  final spanish = AppStringsEs();

  group('RF-62: every text exists in both languages', () {
    test('the table covers the 81 texts of the plans of 001, 002 and 003', () {
      expect(_texts.length, 81);
      expect(
        _expected.keys.toSet().intersection(_expectedPairing.keys.toSet()),
        isEmpty,
      );
      expect({
        ..._expected.keys,
        ..._expectedPairing.keys,
        ..._meaningOnly,
      }, _texts.keys.toSet());
    });

    for (final entry in _expectedPairing.entries) {
      test('${entry.key} matches the exact text of the plan of 003', () {
        final text = _texts[entry.key]!;
        expect(text(english), entry.value.$1);
        expect(text(spanish), entry.value.$2);
      });
    }

    test('no text uses long dashes', () {
      for (final strings in [english, spanish]) {
        for (final entry in _texts.entries) {
          final text = entry.value(strings);
          expect(text, isNot(contains('\u2014')), reason: entry.key);
          expect(text, isNot(contains('\u2013')), reason: entry.key);
        }
      }
    });

    for (final entry in _texts.entries) {
      test('${entry.key} is not empty in English nor in Spanish', () {
        expect(entry.value(english).trim(), isNotEmpty);
        expect(entry.value(spanish).trim(), isNotEmpty);
      });
    }

    for (final entry in _texts.entries) {
      if (entry.key == 'appTitle') continue;
      test('${entry.key} differs between English and Spanish', () {
        expect(entry.value(english), isNot(entry.value(spanish)));
      });
    }

    test('appTitle is the same brand in both languages', () {
      expect(english.appTitle, 'NexusBridges');
      expect(spanish.appTitle, 'NexusBridges');
    });

    for (final entry in _expected.entries) {
      test('${entry.key} matches the exact text of the plan', () {
        final text = _texts[entry.key]!;
        expect(text(english), entry.value.$1);
        expect(text(spanish), entry.value.$2);
      });
    }

    test('no text leaves an unresolved placeholder', () {
      for (final strings in [english, spanish]) {
        for (final text in _texts.values) {
          expect(text(strings), isNot(contains(r'$')));
          expect(text(strings), isNot(contains('{')));
        }
      }
    });
  });

  group('RF-62: texts with an argument include it', () {
    const odd = 'Red «rara» 5G';

    for (final strings in [english, spanish]) {
      final language = strings is AppStringsEs ? 'es' : 'en';

      test('trustNetworkButton includes the network name ($language)', () {
        expect(strings.trustNetworkButton(odd), contains(odd));
        expect(
          strings.trustNetworkButton('A'),
          isNot(strings.trustNetworkButton('B')),
        );
      });

      test('networkPromptBody includes the network name ($language)', () {
        expect(strings.networkPromptBody(odd), contains(odd));
        expect(
          strings.networkPromptBody('A'),
          isNot(strings.networkPromptBody('B')),
        );
      });

      test('portInUse includes the port ($language)', () {
        expect(strings.portInUse(53530), contains('53530'));
        expect(strings.portInUse(1), contains('1'));
        expect(strings.portInUse(1), isNot(strings.portInUse(2)));
      });

      for (final key in _withName) {
        test('$key includes the device name ($language)', () {
          expect(_texts[key]!(strings), contains(_sampleName));
        });
      }

      for (final key in _withShort) {
        test('$key includes the short fingerprint ($language)', () {
          expect(_texts[key]!(strings), contains(_sampleShort));
        });
      }

      for (final key in _withOldName) {
        test('$key includes the old name ($language)', () {
          expect(_texts[key]!(strings), contains(_sampleOldName));
        });
      }

      test('the device name of a text with a name changes the text '
          '($language)', () {
        expect(strings.pairingWithTitle(odd), contains(odd));
        expect(strings.outcomeFailed('A'), isNot(strings.outcomeFailed('B')));
        expect(
          strings.replaceBody('A', 'B'),
          isNot(strings.replaceBody('B', 'A')),
        );
        expect(strings.unpairBody('A'), isNot(strings.unpairBody('B')));
      });

      test('C115: noticeAttemptsCancelled includes the count, changes with '
          'it and carries no fingerprint ($language)', () {
        final text = strings.noticeAttemptsCancelled(4);
        expect(text, contains('4'));
        expect(text, isNot(contains(_sampleShort)));
        expect(strings.noticeAttemptsCancelled(17), contains('17'));
        expect(
          strings.noticeAttemptsCancelled(2),
          isNot(strings.noticeAttemptsCancelled(3)),
        );
        expect(
          strings.noticeAttemptsCancelled(2),
          isNot(strings.noticeAttemptCancelled(_sampleShort)),
        );
      });

      test('C115: noticeAttemptPeerCancelled includes the short fingerprint '
          'and is neutral, not the data mismatch text ($language)', () {
        final neutral = strings.noticeAttemptPeerCancelled(_sampleShort);
        expect(neutral, contains(_sampleShort));
        expect(
          strings.noticeAttemptPeerCancelled('X1'),
          isNot(strings.noticeAttemptPeerCancelled('X2')),
        );
        expect(neutral, isNot(strings.noticeAttemptCancelled(_sampleShort)));
        expect(
          neutral,
          isNot(contains(strings.noticeAttemptCancelled(_sampleShort))),
        );
      });

      test('C115: outcomePaused includes the name and differs from the other '
          'outcomes ($language)', () {
        expect(strings.outcomePaused(odd), contains(odd));
        expect(strings.outcomePaused('A'), isNot(strings.outcomePaused('B')));
        for (final other in [
          strings.outcomeRejected(_sampleName),
          strings.outcomeBusy(_sampleName),
          strings.outcomeFailed(_sampleName),
        ]) {
          expect(strings.outcomePaused(_sampleName), isNot(other));
        }
      });

      test('C115: noticePairingPaused is a fixed text without arguments that '
          'differs from the other notices ($language)', () {
        expect(strings.noticePairingPaused.trim(), isNotEmpty);
        expect(strings.noticePairingPaused, contains('3'));
        expect(
          strings.noticePairingPaused,
          isNot(strings.noticeAttemptsCancelled(3)),
        );
      });

      test('the pairing notices of Q-9 include who and differ ($language)', () {
        expect(strings.noticePairingNotSaved('X1'), contains('X1'));
        expect(strings.noticePairingFailed('X1'), contains('X1'));
        expect(
          strings.noticePairingNotSaved('X1'),
          isNot(strings.noticePairingFailed('X1')),
        );
      });
    }
  });

  group('RF-63/64: stringsFor', () {
    test('es gives the Spanish texts', () {
      expect(stringsFor('es'), isA<AppStringsEs>());
    });

    for (final code in ['en', 'fr', '', 'de', 'pt']) {
      test('"$code" gives the English texts', () {
        expect(stringsFor(code), isA<AppStringsEn>());
      });
    }
  });

  group('RF-63/64: AppStringsDelegate', () {
    const delegate = AppStringsDelegate();

    test('supports es and en', () {
      expect(delegate.isSupported(const Locale('es')), isTrue);
      expect(delegate.isSupported(const Locale('en')), isTrue);
    });

    test('supports regional variants of es and en', () {
      expect(delegate.isSupported(const Locale('es', 'ES')), isTrue);
      expect(delegate.isSupported(const Locale('es', 'MX')), isTrue);
      expect(delegate.isSupported(const Locale('en', 'US')), isTrue);
    });

    test('rejects fr and other languages', () {
      expect(delegate.isSupported(const Locale('fr')), isFalse);
      expect(delegate.isSupported(const Locale('de')), isFalse);
      expect(delegate.isSupported(const Locale('pt', 'BR')), isFalse);
    });

    test('load gives the strings of the locale synchronously', () async {
      final es = delegate.load(const Locale('es'));
      final en = delegate.load(const Locale('en'));
      expect(es, isA<SynchronousFuture<AppStrings>>());
      expect(en, isA<SynchronousFuture<AppStrings>>());
      expect(await es, isA<AppStringsEs>());
      expect(await en, isA<AppStringsEn>());
    });

    test('load of a regional Spanish locale gives Spanish', () async {
      expect(
        await delegate.load(const Locale('es', 'MX')),
        isA<AppStringsEs>(),
      );
    });

    test('never asks to reload', () {
      expect(delegate.shouldReload(const AppStringsDelegate()), isFalse);
    });

    testWidgets('of(context) gives the strings of the active locale', (
      tester,
    ) async {
      AppStrings? found;
      await tester.pumpWidget(
        Localizations(
          locale: const Locale('es'),
          delegates: const [
            AppStringsDelegate(),
            DefaultWidgetsLocalizations.delegate,
          ],
          child: Builder(
            builder: (context) {
              found = AppStringsDelegate.of(context);
              return const SizedBox.shrink();
            },
          ),
        ),
      );
      expect(found, isA<AppStringsEs>());

      await tester.pumpWidget(
        Localizations(
          locale: const Locale('en'),
          delegates: const [
            AppStringsDelegate(),
            DefaultWidgetsLocalizations.delegate,
          ],
          child: Builder(
            builder: (context) {
              found = AppStringsDelegate.of(context);
              return const SizedBox.shrink();
            },
          ),
        ),
      );
      expect(found, isA<AppStringsEn>());
    });
  });
}
