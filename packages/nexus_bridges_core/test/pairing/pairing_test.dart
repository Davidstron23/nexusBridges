import 'dart:convert';
import 'dart:io';

import 'package:nexus_bridges_core/src/pairing/pairing.dart';
import 'package:nexus_bridges_core/src/storage/storage.dart';
import 'package:test/test.dart';

const String _fingerprintA =
    'A1B2C3D4E5F60718293A4B5C6D7E8F90A1B2C3D4E5F60718293A4B5C6D7E8F90';
const String _fingerprintB =
    '0F1E2D3C4B5A69788796A5B4C3D2E1F00F1E2D3C4B5A69788796A5B4C3D2E1F0';
const String _pemA =
    '-----BEGIN CERTIFICATE-----\nAAAA\n-----END CERTIFICATE-----\n';
const String _pemB =
    '-----BEGIN CERTIFICATE-----\nBBBB\n-----END CERTIFICATE-----\n';

final PairedDevice _laptop = PairedDevice(
  fingerprint: _fingerprintA,
  name: 'Laptop',
  certificatePem: _pemA,
  permissions: {Permission.send, Permission.receive},
  pairedAt: DateTime.utc(2026, 10, 20, 12, 0, 0),
);

final PairedDevice _desktop = PairedDevice(
  fingerprint: _fingerprintB,
  name: 'Desktop',
  certificatePem: _pemB,
  permissions: {Permission.browse},
  pairedAt: DateTime.utc(2026, 10, 21, 8, 30, 15, 250),
);

Map<String, Object?> _fieldsOf(PairedDevice d) => {
  'fingerprint': d.fingerprint,
  'name': d.name,
  'certificatePem': d.certificatePem,
  'permissions': d.permissions.toSet(),
  'pairedAt': d.pairedAt,
};

Map<String, Object?> _rawDevice({
  String fingerprint = _fingerprintA,
  String pairedAt = '2026-10-20T12:00:00.000Z',
  List<String> permissions = const ['send'],
}) => {
  'fingerprint': fingerprint,
  'name': 'Laptop',
  'certificatePem': _pemA,
  'permissions': permissions,
  'pairedAt': pairedAt,
};

void main() {
  final sep = Platform.pathSeparator;
  final clock = DateTime(2026, 10, 21, 9, 5, 3);
  const brokenName = 'paired.json.broken-20261021-090503';

  late Directory dataDir;
  late File pairedFile;

  setUp(() async {
    dataDir = await Directory.systemTemp.createTemp('nexus_pairing_test_');
    addTearDown(() => dataDir.delete(recursive: true));
    pairedFile = File('${dataDir.path}${sep}paired.json');
  });

  PairedDevicesStore storeOn(File file) =>
      PairedDevicesStore(JsonFileStore(file), now: () => clock);

  Future<List<String>> namesIn(Directory dir) async {
    final names = await dir
        .list()
        .map((e) => e.uri.pathSegments.lastWhere((s) => s.isNotEmpty))
        .toList();
    return names..sort();
  }

  Future<Map<String, Object?>> rawFile() async =>
      jsonDecode(await pairedFile.readAsString()) as Map<String, Object?>;

  group('persistent list (RF-27)', () {
    test('a new store on the same file loads the same devices', () async {
      await storeOn(pairedFile).replaceAll([_laptop, _desktop]);

      final reloaded = storeOn(pairedFile);
      await reloaded.load();

      expect(reloaded.devices.map(_fieldsOf).toList(), [
        _fieldsOf(_laptop),
        _fieldsOf(_desktop),
      ]);
      expect(reloaded.devices.every((d) => d.pairedAt.isUtc), isTrue);
      expect(reloaded.isPaired(_fingerprintA), isTrue);
      expect(reloaded.isPaired(_fingerprintB), isTrue);
    });

    test('the file has version 1 and every field by name', () async {
      await storeOn(pairedFile).replaceAll([_laptop, _desktop]);

      final json = await rawFile();

      expect(json.keys.toSet(), {'version', 'devices'});
      expect(json['version'], 1);
      final devices = json['devices'] as List<Object?>;
      expect(devices, hasLength(2));
      final first = devices[0] as Map<String, Object?>;
      final second = devices[1] as Map<String, Object?>;
      expect(first.keys.toSet(), {
        'fingerprint',
        'name',
        'certificatePem',
        'permissions',
        'pairedAt',
      });
      expect(first['fingerprint'], _fingerprintA);
      expect(first['name'], 'Laptop');
      expect(first['certificatePem'], _pemA);
      expect(first['permissions'], unorderedEquals(['send', 'receive']));
      expect(first['pairedAt'], '2026-10-20T12:00:00.000Z');
      expect(second['fingerprint'], _fingerprintB);
      expect(second['permissions'], ['browse']);
      expect(second['pairedAt'], '2026-10-21T08:30:15.250Z');
    });

    test('a local pairedAt is written as the same instant in UTC', () async {
      final local = DateTime(2026, 10, 20, 14, 45, 30);
      final device = PairedDevice(
        fingerprint: _fingerprintA,
        name: 'Laptop',
        certificatePem: _pemA,
        permissions: const {},
        pairedAt: local,
      );

      await storeOn(pairedFile).replaceAll([device]);
      final reloaded = storeOn(pairedFile);
      await reloaded.load();

      final written =
          ((await rawFile())['devices'] as List<Object?>).single
              as Map<String, Object?>;
      expect(written['pairedAt'], local.toUtc().toIso8601String());
      expect(written['pairedAt'] as String, endsWith('Z'));
      expect(written['permissions'], isEmpty);
      expect(reloaded.devices.single.pairedAt.isUtc, isTrue);
      expect(reloaded.devices.single.pairedAt.isAtSameMomentAs(local), isTrue);
      expect(reloaded.devices.single.permissions, isEmpty);
    });

    test(
      'load without a file gives an empty list and creates nothing',
      () async {
        final store = storeOn(pairedFile);

        await store.load();

        expect(store.devices, isEmpty);
        expect(store.isPaired(_fingerprintA), isFalse);
        expect(await pairedFile.exists(), isFalse);
        expect(await namesIn(dataDir), isEmpty);
      },
    );

    test('an unknown permission in the file is ignored', () async {
      await pairedFile.writeAsString(
        jsonEncode({
          'version': 1,
          'devices': [
            _rawDevice(permissions: ['send', 'teleport', 'browse']),
          ],
        }),
      );
      final store = storeOn(pairedFile);

      await store.load();

      expect(store.devices, hasLength(1));
      expect(store.devices.single.permissions, {
        Permission.send,
        Permission.browse,
      });
      expect(store.isPaired(_fingerprintA), isTrue);
      expect(await namesIn(dataDir), ['paired.json']);
    });
  });

  group('isPaired', () {
    test('is false before load even if the file lists the device', () async {
      await storeOn(pairedFile).replaceAll([_laptop]);
      final store = storeOn(pairedFile);

      expect(store.isPaired(_fingerprintA), isFalse);
      expect(store.devices, isEmpty);

      await store.load();
      expect(store.isPaired(_fingerprintA), isTrue);
    });

    test('matches the exact fingerprint only', () async {
      final store = storeOn(pairedFile);
      await store.replaceAll([_laptop]);

      expect(store.isPaired(_fingerprintA), isTrue);
      expect(store.isPaired(_fingerprintA.toLowerCase()), isFalse);
      expect(store.isPaired(_fingerprintB), isFalse);
      expect(store.isPaired(_fingerprintA.substring(0, 63)), isFalse);
      expect(store.isPaired('$_fingerprintA '), isFalse);
      expect(store.isPaired(''), isFalse);
    });
  });

  group('corrupt paired.json goes to quarantine', () {
    final corruptions = <String, String>{
      'broken JSON': '{"version": 1, "devices": [',
      'a JSON array': '[]',
      'devices that is not a list': jsonEncode({
        'version': 1,
        'devices': {'fingerprint': _fingerprintA},
      }),
      'an entry without fingerprint': jsonEncode({
        'version': 1,
        'devices': [
          _rawDevice(),
          {..._rawDevice(fingerprint: _fingerprintB)}..remove('fingerprint'),
        ],
      }),
      'an invalid pairedAt': jsonEncode({
        'version': 1,
        'devices': [
          _rawDevice(),
          _rawDevice(fingerprint: _fingerprintB, pairedAt: 'yesterday'),
        ],
      }),
    };

    for (final MapEntry(key: label, value: content) in corruptions.entries) {
      test('$label: renamed with the clock, nobody paired', () async {
        await pairedFile.writeAsString(content);
        final store = storeOn(pairedFile);

        await store.load();

        expect(store.devices, isEmpty);
        expect(store.isPaired(_fingerprintA), isFalse);
        expect(store.isPaired(_fingerprintB), isFalse);
        expect(await namesIn(dataDir), [brokenName]);
        expect(
          await File('${dataDir.path}$sep$brokenName').readAsString(),
          content,
        );
      });
    }

    test('a corrupt file replaces a previously loaded list', () async {
      final store = storeOn(pairedFile);
      await store.replaceAll([_laptop]);
      await pairedFile.writeAsString('not json');

      await store.load();

      expect(store.devices, isEmpty);
      expect(store.isPaired(_fingerprintA), isFalse);
      expect(await namesIn(dataDir), [brokenName]);
    });
  });

  group('replaceAll', () {
    test('a failed write throws, keeps the list and emits nothing', () async {
      final folder = Directory('${dataDir.path}${sep}data');
      final file = File('${folder.path}${sep}paired.json');
      final store = storeOn(file);
      await store.replaceAll([_laptop]);
      await folder.delete(recursive: true);
      await File(folder.path).writeAsString('i am a file');
      var events = 0;
      final subscription = store.changes.listen((_) => events++);
      addTearDown(subscription.cancel);

      await expectLater(
        store.replaceAll([_desktop]),
        throwsA(isA<FileSystemException>()),
      );
      await pumpEventQueue();

      expect(events, 0);
      expect(store.devices.map(_fieldsOf).toList(), [_fieldsOf(_laptop)]);
      expect(store.isPaired(_fingerprintA), isTrue);
      expect(store.isPaired(_fingerprintB), isFalse);
      expect(await File(folder.path).readAsString(), 'i am a file');
    });

    test('a failed first write leaves the store empty', () async {
      await File('${dataDir.path}${sep}blocker').writeAsString('x');
      final store = storeOn(File('${dataDir.path}${sep}blocker${sep}p.json'));
      var events = 0;
      final subscription = store.changes.listen((_) => events++);
      addTearDown(subscription.cancel);

      await expectLater(
        store.replaceAll([_laptop]),
        throwsA(isA<FileSystemException>()),
      );
      await pumpEventQueue();

      expect(events, 0);
      expect(store.devices, isEmpty);
      expect(store.isPaired(_fingerprintA), isFalse);
    });

    test('emits exactly one event, after the list is updated', () async {
      final store = storeOn(pairedFile);
      await store.replaceAll([_laptop]);
      final seen = <List<String>>[];
      final subscription = store.changes.listen(
        (_) => seen.add([for (final d in store.devices) d.fingerprint]),
      );
      addTearDown(subscription.cancel);

      await store.replaceAll([_desktop]);
      await pumpEventQueue();

      expect(seen, [
        [_fingerprintB],
      ]);
      expect(store.isPaired(_fingerprintA), isFalse);
      expect(store.isPaired(_fingerprintB), isTrue);
    });

    test('each successful call emits one event', () async {
      final store = storeOn(pairedFile);
      var events = 0;
      final subscription = store.changes.listen((_) => events++);
      addTearDown(subscription.cancel);

      await store.replaceAll([_laptop]);
      await store.replaceAll([_laptop, _desktop]);
      await pumpEventQueue();

      expect(events, 2);
    });

    test('load does not emit', () async {
      await storeOn(pairedFile).replaceAll([_laptop]);
      final store = storeOn(pairedFile);
      var events = 0;
      final subscription = store.changes.listen((_) => events++);
      addTearDown(subscription.cancel);

      await store.load();
      await pumpEventQueue();

      expect(events, 0);
    });

    test('an empty list unpairs everyone, also after reload', () async {
      final store = storeOn(pairedFile);
      await store.replaceAll([_laptop, _desktop]);

      await store.replaceAll([]);

      expect(store.devices, isEmpty);
      expect(store.isPaired(_fingerprintA), isFalse);
      expect(store.isPaired(_fingerprintB), isFalse);
      expect((await rawFile())['devices'], isEmpty);
      final reloaded = storeOn(pairedFile);
      await reloaded.load();
      expect(reloaded.devices, isEmpty);
      expect(reloaded.isPaired(_fingerprintA), isFalse);
    });
  });

  group('devices cannot be changed from outside', () {
    test('before load', () {
      final store = storeOn(pairedFile);

      expect(() => store.devices.add(_laptop), throwsUnsupportedError);
      expect(store.isPaired(_fingerprintA), isFalse);
    });

    test('after load', () async {
      await storeOn(pairedFile).replaceAll([_laptop]);
      final store = storeOn(pairedFile);
      await store.load();

      expect(() => store.devices.add(_desktop), throwsUnsupportedError);
      expect(() => store.devices.clear(), throwsUnsupportedError);
      expect(() => store.devices[0] = _desktop, throwsUnsupportedError);
      expect(store.isPaired(_fingerprintA), isTrue);
      expect(store.isPaired(_fingerprintB), isFalse);
    });

    test('after replaceAll, also through the list that was passed', () async {
      final store = storeOn(pairedFile);
      final input = [_laptop];
      await store.replaceAll(input);

      input
        ..clear()
        ..add(_desktop);

      expect(() => store.devices.add(_desktop), throwsUnsupportedError);
      expect(() => store.devices.removeLast(), throwsUnsupportedError);
      expect(store.devices.map(_fieldsOf).toList(), [_fieldsOf(_laptop)]);
      expect(store.isPaired(_fingerprintA), isTrue);
      expect(store.isPaired(_fingerprintB), isFalse);
    });
  });
}
