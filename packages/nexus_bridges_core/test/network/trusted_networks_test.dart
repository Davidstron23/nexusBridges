import 'dart:convert';
import 'dart:io';

import 'package:nexus_bridges_core/src/network/network.dart';
import 'package:nexus_bridges_core/src/storage/storage.dart';
import 'package:test/test.dart';

const String _home = '{0A1B2C3D-4E5F-4A6B-8C7D-9E0F1A2B3C4D}';
const String _cafe = '{11223344-5566-4778-899A-ABBCCDDEEFF0}';
const String _work = '{FEDCBA98-7654-4321-8FED-CBA987654321}';

void main() {
  final sep = Platform.pathSeparator;
  late Directory dataDir;
  late File networksFile;
  var clock = DateTime.utc(2026, 11, 1, 10);

  setUp(() async {
    dataDir = await Directory.systemTemp.createTemp('nexus_008_trusted_');
    addTearDown(() => dataDir.delete(recursive: true));
    networksFile = File('${dataDir.path}${sep}networks.json');
    clock = DateTime.utc(2026, 11, 1, 10);
  });

  NetworkTrustStore store() =>
      NetworkTrustStore(JsonFileStore(networksFile), now: () => clock);

  void breakFile() {
    if (networksFile.existsSync()) networksFile.deleteSync();
    Directory(networksFile.path).createSync(recursive: true);
  }

  void repairFile() {
    final dir = Directory(networksFile.path);
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  }

  group(
    'NetworkTrustStore.trusted and trustedEntry (RF-531, base of E830)',
    () {
      test(
        'only the trusted networks are listed, with their saved name and the '
        'time of the decision; the untrusted ones are left out',
        () async {
          final trust = store();
          await trust.setDecision(_home, NetworkDecision.trusted, name: 'Home');
          clock = clock.add(const Duration(days: 1));
          await trust.setDecision(
            _cafe,
            NetworkDecision.untrusted,
            name: 'Cafe',
          );
          clock = clock.add(const Duration(days: 1));
          await trust.setDecision(_work, NetworkDecision.trusted, name: 'Work');

          final listed = {
            for (final n in trust.trusted) n.networkId: (n.name, n.trustedAt),
          };
          expect(listed, {
            _home: ('Home', DateTime.utc(2026, 11, 1, 10)),
            _work: ('Work', DateTime.utc(2026, 11, 3, 10)),
          });
          expect(trust.trustedEntry(_home)!.name, 'Home');
          expect(trust.trustedEntry(_cafe), isNull);
          expect(trust.trustedEntry('{UNKNOWN}'), isNull);
        },
      );

      test('the list survives a new store and load', () async {
        await store().setDecision(_home, NetworkDecision.trusted, name: 'Home');

        final reloaded = store();
        await reloaded.load();

        expect(reloaded.trusted.map((n) => n.networkId), [_home]);
        expect(reloaded.trustedEntry(_home)!.trustedAt, clock);
      });

      test('a network that stops being trusted leaves the list at once, before '
          'the write finishes', () async {
        final trust = store();
        await trust.setDecision(_home, NetworkDecision.trusted, name: 'Home');

        final saving = trust.setDecision(
          _home,
          NetworkDecision.untrusted,
          name: 'Home',
        );

        expect(trust.trusted, isEmpty);
        expect(trust.trustedEntry(_home), isNull);
        expect(trust.decisionFor(_home), NetworkDecision.untrusted);
        expect(await saving, isTrue);
      });
    },
  );

  group('hasUnsavedChanges and retrySave (RF-535, base of E838)', () {
    test(
      'a failed write marks unsaved changes; retrySave with the file still '
      'broken keeps the mark, and once writable it saves and clears it',
      () async {
        final trust = store();
        await trust.setDecision(_home, NetworkDecision.trusted, name: 'Home');
        expect(trust.hasUnsavedChanges, isFalse);
        breakFile();

        expect(
          await trust.setDecision(
            _home,
            NetworkDecision.untrusted,
            name: 'Home',
          ),
          isFalse,
        );
        expect(trust.hasUnsavedChanges, isTrue);
        expect(trust.decisionFor(_home), NetworkDecision.untrusted);

        expect(await trust.retrySave(), isFalse);
        expect(trust.hasUnsavedChanges, isTrue);

        repairFile();
        expect(await trust.retrySave(), isTrue);
        expect(trust.hasUnsavedChanges, isFalse);

        final json = jsonDecode(
          await networksFile.readAsString(),
        ) as Map<String, Object?>;
        final networks = json['networks'] as Map<String, Object?>;
        expect((networks[_home] as Map)['decision'], 'untrusted');

        final reloaded = store();
        await reloaded.load();
        expect(reloaded.decisionFor(_home), NetworkDecision.untrusted);
      },
    );

    test('a later good write clears the mark too', () async {
      final trust = store();
      breakFile();
      expect(
        await trust.setDecision(_home, NetworkDecision.trusted, name: 'Home'),
        isFalse,
      );
      expect(trust.hasUnsavedChanges, isTrue);
      repairFile();

      expect(
        await trust.setDecision(_cafe, NetworkDecision.trusted, name: 'Cafe'),
        isTrue,
      );

      expect(trust.hasUnsavedChanges, isFalse);
      final reloaded = store();
      await reloaded.load();
      expect(reloaded.trusted.map((n) => n.networkId).toSet(), {_home, _cafe});
    });
  });
}
