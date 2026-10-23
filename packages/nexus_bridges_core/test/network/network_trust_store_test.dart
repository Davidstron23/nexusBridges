import 'dart:convert';
import 'dart:io';

import 'package:nexus_bridges_core/src/network/network.dart';
import 'package:nexus_bridges_core/src/storage/storage.dart';
import 'package:test/test.dart';

const String _homeId = '{0A1B2C3D-4E5F-4A6B-8C7D-9E0F1A2B3C4D}';
const String _cafeId = '{11223344-5566-4778-899A-ABBCCDDEEFF0}';
const String _twinId = '{FEDCBA98-7654-4321-8FED-CBA987654321}';
const String _unknownId = '{00000000-0000-0000-0000-000000000000}';

void main() {
  final sep = Platform.pathSeparator;
  final quarantineClock = DateTime(2026, 10, 21, 9, 5, 3);
  const brokenName = 'networks.json.broken-20261021-090503';

  late Directory dataDir;
  late File networksFile;

  setUp(() async {
    dataDir = await Directory.systemTemp.createTemp('nexus_trust_test_');
    addTearDown(() => dataDir.delete(recursive: true));
    networksFile = File('${dataDir.path}${sep}networks.json');
  });

  NetworkTrustStore storeOn(File file, {DateTime Function()? now}) =>
      NetworkTrustStore(JsonFileStore(file), now: now ?? () => quarantineClock);

  Future<List<String>> namesIn(Directory dir) async {
    final names = await dir
        .list()
        .map((e) => e.uri.pathSegments.lastWhere((s) => s.isNotEmpty))
        .toList();
    return names..sort();
  }

  Future<Map<String, Object?>> rawFile() async =>
      jsonDecode(await networksFile.readAsString()) as Map<String, Object?>;

  Map<String, Object?> networksOf(Map<String, Object?> json) =>
      json['networks'] as Map<String, Object?>;

  group('decisions are remembered across restarts (RF-12)', () {
    test('trusted and untrusted survive a new store and load', () async {
      final first = storeOn(networksFile);
      expect(
        await first.setDecision(_homeId, NetworkDecision.trusted, name: 'Home'),
        isTrue,
      );
      expect(
        await first.setDecision(
          _cafeId,
          NetworkDecision.untrusted,
          name: 'Cafe',
        ),
        isTrue,
      );

      final reloaded = storeOn(networksFile);
      await reloaded.load();

      expect(reloaded.decisionFor(_homeId), NetworkDecision.trusted);
      expect(reloaded.decisionFor(_cafeId), NetworkDecision.untrusted);
      expect(reloaded.decisionFor(_unknownId), isNull);
    });

    test('a new store does not know anything before load', () async {
      await storeOn(networksFile)
          .setDecision(_homeId, NetworkDecision.trusted, name: 'Home');

      final store = storeOn(networksFile);

      expect(store.decisionFor(_homeId), isNull);
      await store.load();
      expect(store.decisionFor(_homeId), NetworkDecision.trusted);
    });

    test('an unknown network gives null, with or without a file', () async {
      final empty = storeOn(networksFile);
      await empty.load();
      expect(empty.decisionFor(_homeId), isNull);
      expect(await networksFile.exists(), isFalse);
      expect(await namesIn(dataDir), isEmpty);

      await empty.setDecision(_homeId, NetworkDecision.trusted, name: 'Home');
      expect(empty.decisionFor(_cafeId), isNull);
      expect(empty.decisionFor(''), isNull);
      expect(empty.decisionFor(_homeId.toLowerCase()), isNull);
    });

    test('changing the decision of a network overwrites it', () async {
      var now = DateTime.utc(2026, 10, 20, 12);
      final store = storeOn(networksFile, now: () => now);
      await store.setDecision(_homeId, NetworkDecision.trusted, name: 'Home');

      now = DateTime.utc(2026, 10, 21, 18, 30, 15, 250);
      await store.setDecision(
        _homeId,
        NetworkDecision.untrusted,
        name: 'Home 2',
      );

      expect(store.decisionFor(_homeId), NetworkDecision.untrusted);
      final networks = networksOf(await rawFile());
      expect(networks.keys, [_homeId]);
      expect(networks[_homeId], {
        'decision': 'untrusted',
        'name': 'Home 2',
        'decidedAt': '2026-10-21T18:30:15.250Z',
      });
      final reloaded = storeOn(networksFile);
      await reloaded.load();
      expect(reloaded.decisionFor(_homeId), NetworkDecision.untrusted);
    });

    test(
      'the same network name with another id is a different network',
      () async {
        final store = storeOn(networksFile);
        await store.setDecision(_homeId, NetworkDecision.trusted, name: 'Home');
        await store.setDecision(
          _twinId,
          NetworkDecision.untrusted,
          name: 'Home',
        );

        final reloaded = storeOn(networksFile);
        await reloaded.load();

        expect(reloaded.decisionFor(_homeId), NetworkDecision.trusted);
        expect(reloaded.decisionFor(_twinId), NetworkDecision.untrusted);
        final networks = networksOf(await rawFile());
        expect(networks.keys.toSet(), {_homeId, _twinId});
        expect((networks[_homeId] as Map)['decision'], 'trusted');
        expect((networks[_twinId] as Map)['decision'], 'untrusted');
      },
    );

    test(
      'a decision written by an earlier store is kept by a later one',
      () async {
        await storeOn(networksFile)
            .setDecision(_homeId, NetworkDecision.trusted, name: 'Home');
        final second = storeOn(networksFile);
        await second.load();

        await second.setDecision(
          _cafeId,
          NetworkDecision.untrusted,
          name: 'Cafe',
        );

        final third = storeOn(networksFile);
        await third.load();
        expect(third.decisionFor(_homeId), NetworkDecision.trusted);
        expect(third.decisionFor(_cafeId), NetworkDecision.untrusted);
      },
    );
  });

  group('networks.json format', () {
    test(
      'version 1 and networks by id with decision, name, decidedAt',
      () async {
        final store = storeOn(
          networksFile,
          now: () => DateTime.utc(2026, 10, 20, 12),
        );
        await store.setDecision(_homeId, NetworkDecision.trusted, name: 'Home');
        await store.setDecision(
          _cafeId,
          NetworkDecision.untrusted,
          name: 'Café Ñ',
        );

        final json = await rawFile();

        expect(json.keys.toSet(), {'version', 'networks'});
        expect(json['version'], 1);
        expect(networksOf(json), {
          _homeId: {
            'decision': 'trusted',
            'name': 'Home',
            'decidedAt': '2026-10-20T12:00:00.000Z',
          },
          _cafeId: {
            'decision': 'untrusted',
            'name': 'Café Ñ',
            'decidedAt': '2026-10-20T12:00:00.000Z',
          },
        });
      },
    );

    test('a local clock is written as the same instant in UTC', () async {
      final local = DateTime(2026, 10, 20, 14, 45, 30);
      final store = storeOn(networksFile, now: () => local);

      await store.setDecision(_homeId, NetworkDecision.trusted, name: 'Home');

      final entry = networksOf(await rawFile())[_homeId] as Map;
      final decidedAt = entry['decidedAt'] as String;
      expect(decidedAt, local.toUtc().toIso8601String());
      expect(decidedAt, endsWith('Z'));
      expect(DateTime.parse(decidedAt).isAtSameMomentAs(local), isTrue);
    });

    test(
      'the write leaves only networks.json, without temporary files',
      () async {
        final store = storeOn(networksFile);

        await store.setDecision(_homeId, NetworkDecision.trusted, name: 'Home');
        await store.setDecision(_cafeId, NetworkDecision.trusted, name: 'Cafe');

        expect(await namesIn(dataDir), ['networks.json']);
      },
    );

    test('a missing data folder is created on the first decision', () async {
      final file = File('${dataDir.path}${sep}nested${sep}networks.json');
      final store = storeOn(file);

      expect(
        await store.setDecision(_homeId, NetworkDecision.trusted, name: 'H'),
        isTrue,
      );

      expect(await file.exists(), isTrue);
    });
  });

  group('a failed write still rules in memory (prepares RF-14)', () {
    test('first decision on an unwritable path returns false', () async {
      await File('${dataDir.path}${sep}blocker').writeAsString('x');
      final file = File('${dataDir.path}${sep}blocker${sep}networks.json');
      final store = storeOn(file);

      final saved = await store.setDecision(
        _homeId,
        NetworkDecision.trusted,
        name: 'Home',
      );

      expect(saved, isFalse);
      expect(store.decisionFor(_homeId), NetworkDecision.trusted);
      expect(await File('${dataDir.path}${sep}blocker').readAsString(), 'x');
    });

    test(
      'a later failed write keeps the old file and the new memory',
      () async {
        final folder = Directory('${dataDir.path}${sep}data');
        final file = File('${folder.path}${sep}networks.json');
        final store = storeOn(file);
        expect(
          await store.setDecision(_homeId, NetworkDecision.trusted, name: 'H'),
          isTrue,
        );
        await folder.delete(recursive: true);
        await File(folder.path).writeAsString('i am a file');

        final saved = await store.setDecision(
          _homeId,
          NetworkDecision.untrusted,
          name: 'H',
        );
        final savedOther = await store.setDecision(
          _cafeId,
          NetworkDecision.trusted,
          name: 'C',
        );

        expect(saved, isFalse);
        expect(savedOther, isFalse);
        expect(store.decisionFor(_homeId), NetworkDecision.untrusted);
        expect(store.decisionFor(_cafeId), NetworkDecision.trusted);
        expect(await File(folder.path).readAsString(), 'i am a file');
      },
    );

    test('a decision that could not be saved is not remembered', () async {
      await File('${dataDir.path}${sep}blocker').writeAsString('x');
      final file = File('${dataDir.path}${sep}blocker${sep}networks.json');
      await storeOn(file)
          .setDecision(_homeId, NetworkDecision.trusted, name: 'Home');

      final reloaded = storeOn(file);
      await reloaded.load();

      expect(reloaded.decisionFor(_homeId), isNull);
    });
  });

  group('corrupt networks.json goes to quarantine and starts empty', () {
    final corruptions = <String, String>{
      'broken JSON': '{"version": 1, "networks": {',
      'not JSON at all': 'not json',
      'a JSON array': '[]',
      'networks that is a list': jsonEncode({
        'version': 1,
        'networks': [
          {'decision': 'trusted', 'name': 'Home'},
        ],
      }),
      'networks that is a string': jsonEncode({
        'version': 1,
        'networks': _homeId,
      }),
    };

    for (final MapEntry(key: label, value: content) in corruptions.entries) {
      test('$label: renamed with the clock, nothing trusted', () async {
        await networksFile.writeAsString(content);
        final store = storeOn(networksFile);

        await store.load();

        expect(store.decisionFor(_homeId), isNull);
        expect(await namesIn(dataDir), [brokenName]);
        expect(
          await File('${dataDir.path}$sep$brokenName').readAsString(),
          content,
        );
      });
    }

    test('a corrupt file replaces previously loaded decisions', () async {
      final store = storeOn(networksFile);
      await store.setDecision(_homeId, NetworkDecision.trusted, name: 'Home');
      await networksFile.writeAsString('not json');

      await store.load();

      expect(store.decisionFor(_homeId), isNull);
      expect(await namesIn(dataDir), [brokenName]);
    });

    test('after quarantine a new decision writes a fresh file', () async {
      await networksFile.writeAsString('[]');
      final store = storeOn(networksFile, now: () => quarantineClock);
      await store.load();

      expect(
        await store.setDecision(_cafeId, NetworkDecision.trusted, name: 'C'),
        isTrue,
      );

      expect(await namesIn(dataDir), ['networks.json', brokenName]);
      expect(networksOf(await rawFile()).keys, [_cafeId]);
      expect(await File('${dataDir.path}$sep$brokenName').readAsString(), '[]');
    });
  });

  group('an entry with an unknown decision is ignored', () {
    test('the rest of the file is loaded and nothing is quarantined', () async {
      final content = jsonEncode({
        'version': 1,
        'networks': {
          _homeId: {
            'decision': 'trusted',
            'name': 'Home',
            'decidedAt': '2026-10-20T12:00:00.000Z',
          },
          _cafeId: {
            'decision': 'maybe',
            'name': 'Cafe',
            'decidedAt': '2026-10-20T12:00:00.000Z',
          },
          _twinId: {
            'decision': 'untrusted',
            'name': 'Twin',
            'decidedAt': '2026-10-20T12:00:00.000Z',
          },
        },
      });
      await networksFile.writeAsString(content);
      final store = storeOn(networksFile);

      await store.load();

      expect(store.decisionFor(_homeId), NetworkDecision.trusted);
      expect(store.decisionFor(_cafeId), isNull);
      expect(store.decisionFor(_twinId), NetworkDecision.untrusted);
      expect(await namesIn(dataDir), ['networks.json']);
      expect(await networksFile.readAsString(), content);
    });

    test('a decision in another case or type is unknown too', () async {
      await networksFile.writeAsString(
        jsonEncode({
          'version': 1,
          'networks': {
            _homeId: {'decision': 'TRUSTED', 'name': 'Home'},
            _cafeId: {'decision': 1, 'name': 'Cafe'},
            _twinId: {'name': 'Twin'},
          },
        }),
      );
      final store = storeOn(networksFile);

      await store.load();

      expect(store.decisionFor(_homeId), isNull);
      expect(store.decisionFor(_cafeId), isNull);
      expect(store.decisionFor(_twinId), isNull);
      expect(await namesIn(dataDir), ['networks.json']);
    });
  });

  group('the version of networks.json is checked on load (C10)', () {
    Map<String, Object?> validBody() => {
      'networks': {
        _homeId: {
          'decision': 'trusted',
          'name': 'Home',
          'decidedAt': '2026-10-20T12:00:00.000Z',
        },
      },
    };

    final versions = <String, Map<String, Object?> Function()>{
      'version 2': () => {'version': 2, ...validBody()},
      'no version': validBody,
      'version "1" as text': () => {'version': '1', ...validBody()},
      'version 1.0': () => {'version': 1.0, ...validBody()},
      'version 0': () => {'version': 0, ...validBody()},
    };

    for (final MapEntry(key: label, value: build) in versions.entries) {
      test('$label: quarantined and nothing trusted', () async {
        final content = jsonEncode(build());
        await networksFile.writeAsString(content);
        final store = storeOn(networksFile);

        await store.load();

        expect(store.decisionFor(_homeId), isNull);
        expect(await namesIn(dataDir), [brokenName]);
        expect(
          await File('${dataDir.path}$sep$brokenName').readAsString(),
          content,
        );
      });
    }

    test('version 1 with the same body is loaded', () async {
      await networksFile.writeAsString(
        jsonEncode({'version': 1, ...validBody()}),
      );
      final store = storeOn(networksFile);

      await store.load();

      expect(store.decisionFor(_homeId), NetworkDecision.trusted);
      expect(await namesIn(dataDir), ['networks.json']);
    });

    test('after a quarantine for the version, a new decision writes '
        'version 1', () async {
      await networksFile.writeAsString(
        jsonEncode({'version': 2, ...validBody()}),
      );
      final store = storeOn(networksFile);
      await store.load();

      expect(
        await store.setDecision(_cafeId, NetworkDecision.trusted, name: 'C'),
        isTrue,
      );

      expect((await rawFile())['version'], 1);
      expect(networksOf(await rawFile()).keys, [_cafeId]);
      expect(await namesIn(dataDir), ['networks.json', brokenName]);
    });
  });
}
