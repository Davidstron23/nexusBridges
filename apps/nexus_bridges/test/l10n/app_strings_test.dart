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
    test('the table covers the 21 texts of the plan', () {
      expect(_texts.length, 21);
      expect(_expected.keys.toSet(), _texts.keys.toSet());
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
