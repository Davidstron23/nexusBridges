import 'package:flutter_test/flutter_test.dart';
import 'package:nexus_bridges/src/l10n/app_strings.dart';
import 'package:nexus_bridges/src/l10n/app_strings_en.dart';
import 'package:nexus_bridges/src/l10n/app_strings_es.dart';
import 'package:nexus_bridges/src/ui/format.dart';
import 'package:nexus_bridges_core/nexus_bridges_core.dart'
    show TransferOutcome;

typedef _Text = String Function(AppStrings strings);

const String _name = 'Casa de Ana';
const String _peer = 'Portátil de Luis';
const String _path = r'src\docs\informe.pdf';

final Map<String, _Text> _texts = {
  'sendEllipsis': (s) => s.sendEllipsis,
  'sendFilesOption': (s) => s.sendFilesOption,
  'sendFoldersOption': (s) => s.sendFoldersOption,
  'preparingItems': (s) => s.preparingItems(1234),
  'folderSummary': (s) => s.folderSummary(12, '1,5 MB'),
  'foldersLeftOut': (s) => s.foldersLeftOut(3, '2,0 GB'),
  'linksNotFollowed': (s) => s.linksNotFollowed(2),
  'appDataLeftOut': (s) => s.appDataLeftOut,
  'blockedLeftOut': (s) => s.blockedLeftOut(4),
  'containsPrograms': (s) => s.containsPrograms,
  'filesProgress': (s) => s.filesProgress(12, 14),
  'firstLevelMore': (s) => s.firstLevelMore(7),
  'outcomeUnreadableEntry': (s) => s.outcomeUnreadableEntry(_path),
  'outcomeInvalidNameEntry': (s) => s.outcomeInvalidNameEntry(_path),
  'outcomeFolderIncompatible': (s) => s.outcomeFolderIncompatible,
  'queueTitle': (s) => s.queueTitle(_name),
  'looseQueue': (s) => s.looseQueue,
  'bundleQueue': (s) => s.bundleQueue,
  'queuePending': (s) => s.queuePending,
  'queueNotSent': (s) => s.queueNotSent('motivo'),
  'queueRemove': (s) => s.queueRemove,
  'queueCancelAll': (s) => s.queueCancelAll,
  'queueRemaining': (s) => s.queueRemaining(3),
  'queueLastItem': (s) => s.queueLastItem,
  'deliveredSummary': (s) => s.deliveredSummary(12, 14),
  'waitForQueues': (s) => s.waitForQueues(_name),
  'tooManySelected': (s) => s.tooManySelected,
  'trayTitle': (s) => s.trayTitle(5),
  'trayRemoveAll': (s) => s.trayRemoveAll,
  'traySendTo': (s) => s.traySendTo(_name),
  'trayFull': (s) => s.trayFull,
  'trayNothingNew': (s) => s.trayNothingNew,
  'dragHint': (s) => s.dragHint,
  'dragTipTitle': (s) => s.dragTipTitle,
  'dragTipBody': (s) => s.dragTipBody,
  'folderSavedNotice': (s) => s.folderSavedNotice(_name, _peer),
};

final Map<String, (String, String)> _expected = {
  'sendEllipsis': ('Send…', 'Enviar…'),
  'sendFilesOption': ('Files…', 'Archivos…'),
  'sendFoldersOption': ('Folders…', 'Carpetas…'),
  'preparingItems': (
    'Preparing… 1,234 items found',
    'Preparando… 1 234 elementos encontrados',
  ),
  'folderSummary': ('12 files · 1,5 MB', '12 archivos · 1,5 MB'),
  'foldersLeftOut': (
    '3 folders left out (2,0 GB)',
    '3 carpetas quedan fuera (2,0 GB)',
  ),
  'linksNotFollowed': ('2 links not followed', '2 enlaces no se siguen'),
  'appDataLeftOut': (
    "NexusBridges' own data is never sent",
    'Los datos de NexusBridges nunca se envían',
  ),
  'blockedLeftOut': (
    '4 files are not sent: shortcuts and Explorer system files',
    '4 archivos no se envían: accesos directos y archivos de sistema del '
        'Explorador',
  ),
  'containsPrograms': ('contains programs', 'contiene programas'),
  'filesProgress': ('12 of 14 files', '12 de 14 archivos'),
  'firstLevelMore': ('and 7 more', 'y 7 más'),
  'outcomeUnreadableEntry': (
    "Couldn't be read or changed while sending: $_path",
    'No se pudo leer o cambió mientras se enviaba: $_path',
  ),
  'outcomeInvalidNameEntry': (
    "This name can't be used on the other device: $_path",
    'Este nombre no se puede usar en el otro equipo: $_path',
  ),
  'outcomeFolderIncompatible': (
    "The other device can't receive folders; it may need to update "
        'NexusBridges',
    'El otro equipo no puede recibir carpetas; puede que tenga que '
        'actualizar NexusBridges',
  ),
  'queueTitle': ('Sending to $_name', 'Enviando a $_name'),
  'looseQueue': ('Files', 'Archivos'),
  'bundleQueue': ('Folders and archives', 'Carpetas y comprimidos'),
  'queuePending': ('Waiting', 'Pendiente'),
  'queueNotSent': ('Not sent: motivo', 'No enviado: motivo'),
  'queueRemove': ('Remove', 'Quitar'),
  'queueCancelAll': ('Cancel all', 'Cancelar todo'),
  'queueRemaining': ('3 left in the queue', 'Quedan 3 en cola'),
  'queueLastItem': ('Last item', 'Último elemento'),
  'deliveredSummary': ('12 of 14 delivered', '12 de 14 entregados'),
  'waitForQueues': (
    'Wait for the sends to $_name to finish',
    'Espera a que terminen los envíos a $_name',
  ),
  'tooManySelected': (
    'You can send up to 1,000 items at a time',
    'Se pueden enviar como mucho 1 000 elementos a la vez',
  ),
  'trayTitle': ('To send (5)', 'Para enviar (5)'),
  'trayRemoveAll': ('Remove all', 'Quitar todo'),
  'traySendTo': ('Send to $_name', 'Enviar a $_name'),
  'trayFull': (
    'The To send tray holds up to 1,000 items',
    'La bandeja Para enviar admite como mucho 1 000 elementos',
  ),
  'trayNothingNew': ('Already in To send', 'Ya estaban en Para enviar'),
  'dragHint': (
    'Drop on a device · anywhere else goes to To send',
    'Suelta sobre un equipo · fuera de ellos, a Para enviar',
  ),
  'dragTipTitle': ('Drag and drop', 'Arrastra y suelta'),
  'dragTipBody': (
    'On a device to send it; anywhere else to To send',
    'Sobre un equipo para enviárselo; fuera de ellos, a Para enviar',
  ),
  'folderSavedNotice': (
    'Folder $_name received from $_peer',
    'Carpeta $_name recibida de $_peer',
  ),
};

void main() {
  final english = AppStringsEn();
  final spanish = AppStringsEs();

  group('E548: the texts of the 006', () {
    test('the table covers the 36 new keys', () {
      expect(_texts.length, 36);
      expect(_expected.keys.toSet(), _texts.keys.toSet());
    });

    for (final entry in _expected.entries) {
      test('${entry.key} matches the exact text in both languages', () {
        expect(_texts[entry.key]!(english), entry.value.$1);
        expect(_texts[entry.key]!(spanish), entry.value.$2);
      });

      test('${entry.key} differs between languages and is clean', () {
        for (final strings in [english, spanish]) {
          final text = _texts[entry.key]!(strings);
          expect(text.trim(), isNotEmpty);
          expect(text, isNot(contains('—')));
          expect(text, isNot(contains('–')));
          expect(text, isNot(contains(r'$')));
          expect(text, isNot(contains('{')));
        }
        expect(_texts[entry.key]!(english), isNot(_texts[entry.key]!(spanish)));
      });
    }

    test('the 006 texts differ from each other in each language', () {
      for (final strings in [english, spanish]) {
        final seen = <String, String>{};
        for (final key in _texts.keys) {
          final text = _texts[key]!(strings);
          expect(seen[text], isNull, reason: '$key repeats ${seen[text]}');
          seen[text] = key;
        }
      }
    });

    test('sentOutcome and receivedOutcome cover every value of '
        'TransferOutcome with its own text in each language', () {
      for (final strings in [english, spanish]) {
        final sent = {
          for (final o in TransferOutcome.values) o: strings.sentOutcome(o),
        };
        final received = {
          for (final o in TransferOutcome.values) o: strings.receivedOutcome(o),
        };
        expect(sent.values.toSet(), hasLength(TransferOutcome.values.length));
        expect(
          received.values.toSet(),
          hasLength(TransferOutcome.values.length),
        );
        for (final text in [...sent.values, ...received.values]) {
          expect(text.trim(), isNotEmpty);
        }
      }
    });

    test('the 100,000 figure is gone from the outcome texts (Q-5)', () {
      for (final strings in [english, spanish]) {
        for (final o in TransferOutcome.values) {
          expect(strings.sentOutcome(o), isNot(contains('100,000')));
          expect(strings.sentOutcome(o), isNot(contains('100 000')));
          expect(strings.receivedOutcome(o), isNot(contains('100,000')));
          expect(strings.receivedOutcome(o), isNot(contains('100 000')));
        }
      }
    });
  });

  group('E548: texts with arguments', () {
    test('filesProgress reads "12 of 14" and "12 de 14", in order', () {
      expect(english.filesProgress(12, 14), '12 of 14 files');
      expect(spanish.filesProgress(12, 14), '12 de 14 archivos');
      expect(english.filesProgress(0, 1), '0 of 1 file');
      expect(spanish.filesProgress(0, 1), '0 de 1 archivo');
      expect(english.filesProgress(1000, 2500), '1,000 of 2,500 files');
      expect(spanish.filesProgress(1000, 2500), '1 000 de 2 500 archivos');
    });

    test('deliveredSummary reads "12 of 14" and "12 de 14"', () {
      expect(english.deliveredSummary(12, 14), '12 of 14 delivered');
      expect(spanish.deliveredSummary(12, 14), '12 de 14 entregados');
      expect(spanish.deliveredSummary(1, 1), '1 de 1 entregado');
    });

    test('the sizes in folderSummary and foldersLeftOut are kept whole', () {
      for (final bytes in [0, 1, 1023, 1024, 1536, 5 * 1024 * 1024]) {
        for (final language in ['en', 'es']) {
          final strings = stringsFor(language);
          final size = formatSize(bytes, language);
          expect(strings.folderSummary(3, size), contains(size));
          expect(strings.foldersLeftOut(2, size), contains(size));
        }
      }
    });

    test('foldersLeftOut leaves the size out when it is not known', () {
      expect(english.foldersLeftOut(1, null), '1 folder left out');
      expect(spanish.foldersLeftOut(1, null), '1 carpeta queda fuera');
      expect(english.foldersLeftOut(2, null), '2 folders left out');
      expect(spanish.foldersLeftOut(2, null), '2 carpetas quedan fuera');
    });

    test('the counts are singular with one and plural with more', () {
      expect(english.preparingItems(1), 'Preparing… 1 item found');
      expect(spanish.preparingItems(1), 'Preparando… 1 elemento encontrado');
      expect(english.folderSummary(1, '3 bytes'), '1 file · 3 bytes');
      expect(spanish.folderSummary(1, '3 bytes'), '1 archivo · 3 bytes');
      expect(english.linksNotFollowed(1), '1 link not followed');
      expect(spanish.linksNotFollowed(1), '1 enlace no se sigue');
      expect(
        english.blockedLeftOut(1),
        '1 file is not sent: shortcuts and Explorer system files',
      );
      expect(
        spanish.blockedLeftOut(1),
        '1 archivo no se envía: accesos directos y archivos de sistema del '
        'Explorador',
      );
      expect(spanish.queueRemaining(1), 'Queda 1 en cola');
      expect(english.queueRemaining(1), '1 left in the queue');
    });

    for (final strings in [english, spanish]) {
      final language = strings is AppStringsEs ? 'es' : 'en';

      test('the names and paths are kept whole ($language)', () {
        const odd = 'Equipo «raro» 5G';
        expect(strings.queueTitle(odd), contains(odd));
        expect(strings.waitForQueues(odd), contains(odd));
        expect(strings.traySendTo(odd), contains(odd));
        expect(strings.folderSavedNotice(odd, 'Otro'), contains(odd));
        expect(strings.folderSavedNotice('Otra', odd), contains(odd));
        expect(strings.queueNotSent(odd), contains(odd));
        expect(strings.outcomeUnreadableEntry(odd), contains(odd));
        expect(strings.outcomeInvalidNameEntry(odd), contains(odd));
      });

      test('the numbers change the text ($language)', () {
        expect(strings.trayTitle(1), isNot(strings.trayTitle(2)));
        expect(strings.firstLevelMore(2), isNot(strings.firstLevelMore(3)));
        expect(strings.filesProgress(1, 5), isNot(strings.filesProgress(2, 5)));
        expect(strings.queueRemaining(2), isNot(strings.queueRemaining(3)));
      });
    }
  });
}
