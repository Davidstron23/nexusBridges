import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:nexus_bridges_core/src/identity/identity.dart';
import 'package:nexus_bridges_core/src/pairing/pairing.dart';
import 'package:nexus_bridges_core/src/storage/storage.dart';
import 'package:test/test.dart';

final class _PassThroughProtector implements SecretProtector {
  @override
  Uint8List protect(Uint8List data) => Uint8List.fromList(data);

  @override
  Uint8List? unprotect(Uint8List data) => Uint8List.fromList(data);
}

final DeviceIdentity _identityA = DeviceIdentity.generate(
  commonName: randomCommonName(),
);
final DeviceIdentity _identityB = DeviceIdentity.generate(
  commonName: randomCommonName(),
);

final String _fingerprintA = _identityA.fingerprint;
final String _fingerprintB = _identityB.fingerprint;
final String _pemA = _identityA.certificatePem;
final String _pemB = _identityB.certificatePem;
final String _owner = 'C' * 64;
final String _privateKeyPemA = utf8.decode(
  _identityA.protectPrivateKey(_PassThroughProtector()),
);

String _bodyOf(String pem) =>
    LineSplitter.split(pem)
        .map((l) => l.trim())
        .where((l) => !l.startsWith('-----'))
        .join();

final PairedDevice _laptop = PairedDevice(
  fingerprint: _fingerprintA,
  name: 'Laptop',
  certificatePem: _pemA,
  relation: PeerRelation.mine,
  pairedAt: DateTime.utc(2026, 10, 20, 12, 0, 0),
);

final PairedDevice _desktop = PairedDevice(
  fingerprint: _fingerprintB,
  name: 'Desktop',
  certificatePem: _pemB,
  relation: PeerRelation.foreign,
  pairedAt: DateTime.utc(2026, 10, 21, 8, 30, 15, 250),
);

PairedDevice _laptopWith({String? fingerprint, String? certificatePem}) =>
    PairedDevice(
      fingerprint: fingerprint ?? _fingerprintA,
      name: 'Laptop',
      certificatePem: certificatePem ?? _pemA,
      relation: PeerRelation.mine,
      pairedAt: DateTime.utc(2026, 10, 20, 12),
    );

Map<String, Object?> _fieldsOf(PairedDevice d) => {
  'fingerprint': d.fingerprint,
  'name': d.name,
  'certificatePem': d.certificatePem,
  'relation': d.relation,
  'pairedAt': d.pairedAt,
};

Map<String, Object?> _rawDevice({
  String? fingerprint,
  String? certificatePem,
  String pairedAt = '2026-10-20T12:00:00.000Z',
  String relation = 'mine',
}) => {
  'fingerprint': fingerprint ?? _fingerprintA,
  'name': 'Laptop',
  'certificatePem': certificatePem ?? _pemA,
  'relation': relation,
  'pairedAt': pairedAt,
};

Map<String, ({String fingerprint, String certificatePem})>
_invalidIdentities() {
  final body = _bodyOf(_pemA);
  return {
    'a garbage PEM': (fingerprint: _fingerprintA, certificatePem: 'garbage'),
    'an empty PEM': (fingerprint: _fingerprintA, certificatePem: ''),
    'two CERTIFICATE blocks': (
      fingerprint: _fingerprintA,
      certificatePem: '$_pemA\n$_pemB',
    ),
    'the same block twice': (
      fingerprint: _fingerprintA,
      certificatePem: '$_pemA$_pemA',
    ),
    'a private key pasted after the certificate': (
      fingerprint: _fingerprintA,
      certificatePem: '$_pemA\n$_privateKeyPemA',
    ),
    'a private key pasted before the certificate': (
      fingerprint: _fingerprintA,
      certificatePem: '$_privateKeyPemA\n$_pemA',
    ),
    'only a private key': (
      fingerprint: _fingerprintA,
      certificatePem: _privateKeyPemA,
    ),
    'text before the block': (
      fingerprint: _fingerprintA,
      certificatePem: 'subject=NexusBridges\n$_pemA',
    ),
    'a body that is not base64': (
      fingerprint: _fingerprintA,
      certificatePem:
          '-----BEGIN CERTIFICATE-----\n@@@@!!!!\n-----END CERTIFICATE-----\n',
    ),
    'a truncated base64 body': (
      fingerprint: _fingerprintA,
      certificatePem:
          '-----BEGIN CERTIFICATE-----\n'
          '${body.substring(0, body.length - 3)}\n'
          '-----END CERTIFICATE-----\n',
    ),
    'an empty body': (
      fingerprint: 'A' * 64,
      certificatePem:
          '-----BEGIN CERTIFICATE-----\n\n-----END CERTIFICATE-----\n',
    ),
    'a BEGIN without END': (
      fingerprint: _fingerprintA,
      certificatePem: '-----BEGIN CERTIFICATE-----\n$body\n',
    ),
    'a lowercase fingerprint': (
      fingerprint: _fingerprintA.toLowerCase(),
      certificatePem: _pemA,
    ),
    'the fingerprint of another certificate': (
      fingerprint: _fingerprintB,
      certificatePem: _pemA,
    ),
    'a fingerprint of 63 characters': (
      fingerprint: _fingerprintA.substring(0, 63),
      certificatePem: _pemA,
    ),
    'a fingerprint of 65 characters': (
      fingerprint: '${_fingerprintA}0',
      certificatePem: _pemA,
    ),
    'an empty fingerprint': (fingerprint: '', certificatePem: _pemA),
    'a fingerprint with colons': (
      fingerprint: [
        for (var i = 0; i < 64; i += 2) _fingerprintA.substring(i, i + 2),
      ].join(':'),
      certificatePem: _pemA,
    ),
    'a fingerprint with surrounding spaces': (
      fingerprint: ' $_fingerprintA ',
      certificatePem: _pemA,
    ),
  };
}

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

  PairedDevicesStore storeOn(File file) => PairedDevicesStore(
    JsonFileStore(file),
    ownerFingerprint: _owner,
    now: () => clock,
  );

  Future<List<String>> namesIn(Directory dir) async {
    final names = await dir
        .list()
        .map((e) => e.uri.pathSegments.lastWhere((s) => s.isNotEmpty))
        .toList();
    return names..sort();
  }

  Future<Map<String, Object?>> rawFile() async =>
      jsonDecode(await pairedFile.readAsString()) as Map<String, Object?>;

  test('the fixtures are real certificates with their own fingerprint', () {
    expect(_fingerprintA, matches(RegExp(r'^[0-9A-F]{64}$')));
    expect(
      _fingerprintA,
      fingerprintOfCertificate(base64.decode(_bodyOf(_pemA))),
    );
    expect(
      _fingerprintB,
      fingerprintOfCertificate(base64.decode(_bodyOf(_pemB))),
    );
    expect(_fingerprintA, isNot(_fingerprintB));
    expect(_privateKeyPemA, contains('PRIVATE KEY'));
  });

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

    test('the file has version 2, the owner and every field by name', () async {
      await storeOn(pairedFile).replaceAll([_laptop, _desktop]);

      final json = await rawFile();

      expect(json.keys.toSet(), {'version', 'owner', 'devices'});
      expect(json['version'], 2);
      expect(json['owner'], _owner);
      final devices = json['devices'] as List<Object?>;
      expect(devices, hasLength(2));
      final first = devices[0] as Map<String, Object?>;
      final second = devices[1] as Map<String, Object?>;
      expect(first.keys.toSet(), {
        'fingerprint',
        'name',
        'certificatePem',
        'relation',
        'pairedAt',
      });
      expect(first['fingerprint'], _fingerprintA);
      expect(first['name'], 'Laptop');
      expect(first['certificatePem'], _pemA);
      expect(first['relation'], 'mine');
      expect(first['pairedAt'], '2026-10-20T12:00:00.000Z');
      expect(second['fingerprint'], _fingerprintB);
      expect(second['relation'], 'foreign');
      expect(second['pairedAt'], '2026-10-21T08:30:15.250Z');
    });

    test('a local pairedAt is written as the same instant in UTC', () async {
      final local = DateTime(2026, 10, 20, 14, 45, 30);
      final device = PairedDevice(
        fingerprint: _fingerprintA,
        name: 'Laptop',
        certificatePem: _pemA,
        relation: PeerRelation.foreign,
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
      expect(written['relation'], 'foreign');
      expect(reloaded.devices.single.pairedAt.isUtc, isTrue);
      expect(reloaded.devices.single.pairedAt.isAtSameMomentAs(local), isTrue);
      expect(reloaded.devices.single.relation, PeerRelation.foreign);
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
        'version': 2,
        'owner': _owner,
        'devices': {'fingerprint': _fingerprintA},
      }),
      'an entry without fingerprint': jsonEncode({
        'version': 2,
        'owner': _owner,
        'devices': [
          _rawDevice(),
          {..._rawDevice(fingerprint: _fingerprintB, certificatePem: _pemB)}
            ..remove('fingerprint'),
        ],
      }),
      'an unknown relation': jsonEncode({
        'version': 2,
        'owner': _owner,
        'devices': [_rawDevice(relation: 'teleport')],
      }),
      'an invalid pairedAt': jsonEncode({
        'version': 2,
        'owner': _owner,
        'devices': [
          _rawDevice(),
          _rawDevice(
            fingerprint: _fingerprintB,
            certificatePem: _pemB,
            pairedAt: 'yesterday',
          ),
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

  group('an entry whose identity is invalid quarantines paired.json (M2)', () {
    for (final MapEntry(key: label, value: bad)
        in _invalidIdentities().entries) {
      test('$label: renamed with the clock, nobody paired', () async {
        final content = jsonEncode({
          'version': 2,
          'owner': _owner,
          'devices': [
            _rawDevice(fingerprint: _fingerprintB, certificatePem: _pemB),
            _rawDevice(
              fingerprint: bad.fingerprint,
              certificatePem: bad.certificatePem,
            ),
          ],
        });
        await pairedFile.writeAsString(content);
        final store = storeOn(pairedFile);
        var events = 0;
        final subscription = store.changes.listen((_) => events++);
        addTearDown(subscription.cancel);

        await store.load();
        await pumpEventQueue();

        expect(store.devices, isEmpty);
        expect(store.isPaired(_fingerprintA), isFalse);
        expect(store.isPaired(_fingerprintB), isFalse);
        expect(store.isPaired(bad.fingerprint), isFalse);
        expect(await namesIn(dataDir), [brokenName]);
        expect(
          await File('${dataDir.path}$sep$brokenName').readAsString(),
          content,
        );
        expect(events, 0);
      });
    }

    test('a truncated DER no longer matches its old fingerprint', () async {
      final der = base64.decode(_bodyOf(_pemA));
      final truncated = der.sublist(0, der.length - 3);
      final pem =
          '-----BEGIN CERTIFICATE-----\n'
          '${base64.encode(truncated)}\n'
          '-----END CERTIFICATE-----\n';
      await pairedFile.writeAsString(
        jsonEncode({
          'version': 2,
          'owner': _owner,
          'devices': [
            _rawDevice(fingerprint: _fingerprintA, certificatePem: pem),
          ],
        }),
      );
      final store = storeOn(pairedFile);

      await store.load();

      expect(store.devices, isEmpty);
      expect(await namesIn(dataDir), [brokenName]);
    });
  });

  group('replaceAll rejects an invalid identity (M2)', () {
    for (final MapEntry(key: label, value: bad)
        in _invalidIdentities().entries) {
      test('$label: ArgumentError without secrets, nothing written', () async {
        final store = storeOn(pairedFile);
        await store.replaceAll([_desktop]);
        final before = await pairedFile.readAsString();
        var events = 0;
        final subscription = store.changes.listen((_) => events++);
        addTearDown(subscription.cancel);
        final invalid = _laptopWith(
          fingerprint: bad.fingerprint,
          certificatePem: bad.certificatePem,
        );

        Object? caught;
        try {
          await store.replaceAll([_desktop, invalid]);
        } catch (e) {
          caught = e;
        }
        await pumpEventQueue();

        expect(caught, isA<ArgumentError>());
        final error = caught! as ArgumentError;
        final texts = [
          '$error',
          '${error.message}',
          '${error.invalidValue}',
          '${error.name}',
        ];
        for (final text in texts) {
          expect(text, isNot(contains('BEGIN')));
          expect(text, isNot(contains('PRIVATE')));
          expect(text, isNot(contains(_fingerprintA)));
          expect(text, isNot(contains(_fingerprintA.toLowerCase())));
          expect(text, isNot(contains(_fingerprintB)));
          expect(text, isNot(contains(_fingerprintA.substring(0, 16))));
          expect(text, isNot(contains(_bodyOf(_pemA).substring(20, 52))));
          expect(text, isNot(contains(_bodyOf(_pemB).substring(20, 52))));
          if (bad.certificatePem.length >= 7) {
            expect(text, isNot(contains(bad.certificatePem)));
          }
        }
        expect(await pairedFile.readAsString(), before);
        expect(await namesIn(dataDir), ['paired.json']);
        expect(store.devices.map(_fieldsOf).toList(), [_fieldsOf(_desktop)]);
        expect(store.isPaired(_fingerprintB), isTrue);
        expect(store.isPaired(_fingerprintA), isFalse);
        expect(events, 0);
      });
    }

    test('a first call with an invalid entry creates no file', () async {
      final store = storeOn(pairedFile);
      var events = 0;
      final subscription = store.changes.listen((_) => events++);
      addTearDown(subscription.cancel);

      await expectLater(
        store.replaceAll([
          _laptopWith(fingerprint: _fingerprintB, certificatePem: _pemA),
        ]),
        throwsA(isA<ArgumentError>()),
      );
      await pumpEventQueue();

      expect(await pairedFile.exists(), isFalse);
      expect(await namesIn(dataDir), isEmpty);
      expect(store.devices, isEmpty);
      expect(events, 0);
    });

    test('the store keeps working after a rejected call', () async {
      final store = storeOn(pairedFile);
      await expectLater(
        store.replaceAll([_laptopWith(certificatePem: 'garbage')]),
        throwsA(isA<ArgumentError>()),
      );

      await store.replaceAll([_laptop]);

      expect(store.isPaired(_fingerprintA), isTrue);
      final reloaded = storeOn(pairedFile);
      await reloaded.load();
      expect(reloaded.devices.map(_fieldsOf).toList(), [_fieldsOf(_laptop)]);
    });
  });

  group('whitespace around a valid block (M2)', () {
    final variants = <String, String>{
      'blank lines and spaces around': '\n\n  $_pemA  \n\n',
      'CRLF line endings': _pemA.replaceAll('\n', '\r\n'),
      'no trailing newline': _pemA.trimRight(),
      'tabs before the block': '\t\t$_pemA',
      'the body re-wrapped at 76 columns': [
        '-----BEGIN CERTIFICATE-----',
        for (var i = 0; i < _bodyOf(_pemA).length; i += 76)
          _bodyOf(_pemA).substring(
            i,
            i + 76 > _bodyOf(_pemA).length ? _bodyOf(_pemA).length : i + 76,
          ),
        '-----END CERTIFICATE-----',
      ].join('\n'),
    };

    for (final MapEntry(key: label, value: pem) in variants.entries) {
      test('$label is accepted by load and kept as written', () async {
        await pairedFile.writeAsString(
          jsonEncode({
            'version': 2,
            'owner': _owner,
            'devices': [_rawDevice(certificatePem: pem)],
          }),
        );
        final store = storeOn(pairedFile);

        await store.load();

        expect(store.isPaired(_fingerprintA), isTrue);
        expect(store.devices.single.certificatePem, pem);
        expect(await namesIn(dataDir), ['paired.json']);
      });

      test('$label is accepted by replaceAll and written as given', () async {
        final store = storeOn(pairedFile);

        await store.replaceAll([_laptopWith(certificatePem: pem)]);

        expect(store.isPaired(_fingerprintA), isTrue);
        final written =
            ((await rawFile())['devices'] as List<Object?>).single
                as Map<String, Object?>;
        expect(written['certificatePem'], pem);
      });
    }
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
