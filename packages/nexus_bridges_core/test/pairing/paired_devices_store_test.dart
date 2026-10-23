import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:nexus_bridges_core/src/identity/identity.dart';
import 'package:nexus_bridges_core/src/pairing/pairing.dart';
import 'package:nexus_bridges_core/src/storage/storage.dart';
import 'package:test/test.dart';

const String _owner =
    'C0FFEE00C0FFEE00C0FFEE00C0FFEE00C0FFEE00C0FFEE00C0FFEE00C0FFEE00';
const String _otherOwner =
    'BADA5500BADA5500BADA5500BADA5500BADA5500BADA5500BADA5500BADA55AA';
const String _sharedCommonName = 'NexusBridges-0123456789abcdef';
const String _smile = '\u{1F600}';

final List<DeviceIdentity> _identities = [
  for (var i = 0; i < 34; i++)
    DeviceIdentity.generate(commonName: randomCommonName()),
];

final DeviceIdentity _twinOne = DeviceIdentity.generate(
  commonName: _sharedCommonName,
);
final DeviceIdentity _twinTwo = DeviceIdentity.generate(
  commonName: _sharedCommonName,
);

PairedDevice _deviceOf(
  DeviceIdentity identity, {
  String? name,
  PeerRelation relation = PeerRelation.foreign,
}) => PairedDevice(
  fingerprint: identity.fingerprint,
  name: name ?? 'PC-${identity.fingerprint.substring(0, 8)}',
  certificatePem: identity.certificatePem,
  relation: relation,
  pairedAt: DateTime.utc(2026, 10, 23, 18),
);

PairedDevice _device(int index) => _deviceOf(_identities[index]);

String _fp(int index) => _identities[index].fingerprint;

Set<String> _fingerprints(Iterable<PairedDevice> devices) => {
  for (final d in devices) d.fingerprint,
};

Map<String, Object?> _fieldsOf(PairedDevice d) => {
  'fingerprint': d.fingerprint,
  'name': d.name,
  'certificatePem': d.certificatePem,
  'relation': d.relation,
  'pairedAt': d.pairedAt,
};

String _bodyOf(String pem) =>
    LineSplitter.split(pem)
        .map((l) => l.trim())
        .where((l) => !l.startsWith('-----'))
        .join();

final class _ExclusiveLock {
  _ExclusiveLock(File file) : _handle = file.openSync(mode: FileMode.append) {
    _handle.lockSync(FileLock.exclusive);
  }

  final RandomAccessFile _handle;
  bool _held = true;

  void release() {
    if (!_held) return;
    _held = false;
    _handle.unlockSync();
    _handle.closeSync();
  }
}

void main() {
  final sep = Platform.pathSeparator;
  final clock = DateTime(2026, 10, 23, 18, 4, 5);
  const stamp = '20261023-180405';

  late Directory dataDir;
  late File pairedFile;

  setUp(() async {
    dataDir = await Directory.systemTemp.createTemp('nexus_paired_v2_test_');
    addTearDown(() => dataDir.delete(recursive: true));
    pairedFile = File('${dataDir.path}${sep}paired.json');
  });

  PairedDevicesStore storeOn(File file, {String owner = _owner}) =>
      PairedDevicesStore(
        JsonFileStore(file),
        ownerFingerprint: owner,
        now: () => clock,
      );

  Future<List<String>> namesIn(Directory dir) async {
    final names = await dir
        .list()
        .map((e) => e.uri.pathSegments.lastWhere((s) => s.isNotEmpty))
        .toList();
    return names..sort();
  }

  Map<String, Object?> rawOf(File file) =>
      jsonDecode(file.readAsStringSync()) as Map<String, Object?>;

  List<Map<String, Object?>> entriesOf(File file) => [
    for (final entry in rawOf(file)['devices'] as List<Object?>)
      entry! as Map<String, Object?>,
  ];

  Set<String> fingerprintsIn(File file) => {
    for (final entry in entriesOf(file)) entry['fingerprint']! as String,
  };

  _ExclusiveLock lock(File file) {
    final held = _ExclusiveLock(file);
    addTearDown(held.release);
    return held;
  }

  List<Set<String>> recordChanges(PairedDevicesStore store) {
    final seen = <Set<String>>[];
    final subscription = store.changes.listen(
      (_) => seen.add(_fingerprints(store.devices)),
    );
    addTearDown(subscription.cancel);
    return seen;
  }

  List<bool> recordSaveStatus(PairedDevicesStore store) {
    final seen = <bool>[];
    final subscription = store.saveStatusChanges.listen(
      (_) => seen.add(store.hasUnsavedChanges),
    );
    addTearDown(subscription.cancel);
    return seen;
  }

  Future<PairedDevicesStore> storeWith(List<PairedDevice> devices) async {
    final store = storeOn(pairedFile);
    await store.replaceAll(devices);
    return store;
  }

  Future<void> makeUnsaved(PairedDevicesStore store) async {
    final held = lock(pairedFile);
    expect(await store.retrySave(), isFalse);
    held.release();
    expect(store.hasUnsavedChanges, isTrue);
  }

  Future<void> blockFolder(Directory folder) async {
    await folder.delete(recursive: true);
    await File(folder.path).writeAsString('i am a file, not a folder');
  }

  group('PeerRelation and PairedDevice (RF-102)', () {
    test('mine gives send, receive and browse; foreign only receive', () {
      expect(permissionsFor(PeerRelation.mine), {
        Permission.send,
        Permission.receive,
        Permission.browse,
      });
      expect(permissionsFor(PeerRelation.foreign), {Permission.receive});
    });

    test('permissions are derived from the relation', () {
      final foreign = _deviceOf(_identities[0]);
      final mine = foreign.copyWith(relation: PeerRelation.mine);

      expect(foreign.permissions, {Permission.receive});
      expect(mine.permissions, {
        Permission.send,
        Permission.receive,
        Permission.browse,
      });
    });

    test('copyWith changes only the name or the relation', () {
      final original = _deviceOf(_identities[0], name: 'Old');

      final renamed = original.copyWith(name: 'New');
      final related = original.copyWith(relation: PeerRelation.mine);
      final same = original.copyWith();

      expect(_fieldsOf(renamed), {..._fieldsOf(original), 'name': 'New'});
      expect(_fieldsOf(related), {
        ..._fieldsOf(original),
        'relation': PeerRelation.mine,
      });
      expect(_fieldsOf(same), _fieldsOf(original));
    });

    test('toJson has the five fields and fromJson reads them back', () {
      final device = _deviceOf(
        _identities[0],
        name: 'Portátil',
        relation: PeerRelation.mine,
      );

      final json = device.toJson();
      final back = PairedDevice.fromJson(jsonDecode(jsonEncode(json)));

      expect(json, {
        'fingerprint': device.fingerprint,
        'name': 'Portátil',
        'certificatePem': device.certificatePem,
        'relation': 'mine',
        'pairedAt': '2026-10-23T18:00:00.000Z',
      });
      expect(_fieldsOf(back), _fieldsOf(device));
    });

    test('fromJson accepts an empty name and 64 runes, rejects 65', () {
      Map<String, Object?> withName(String name) =>
          _deviceOf(_identities[0]).copyWith(name: name).toJson();

      expect(PairedDevice.fromJson(withName('')).name, '');
      expect(
        PairedDevice.fromJson(withName(_smile * 64)).name.runes.length,
        64,
      );
      expect(
        () => PairedDevice.fromJson(withName('${_smile * 64}z')),
        throwsFormatException,
      );
    });

    test('fromJson rejects a relation that is not mine or foreign', () {
      for (final relation in ['Mine', 'FOREIGN', '', 'browse']) {
        final json = {..._deviceOf(_identities[0]).toJson()};
        json['relation'] = relation;

        expect(() => PairedDevice.fromJson(json), throwsFormatException);
      }
    });
  });

  group('load and the owner of the file (RF-66, C11)', () {
    test('without a file gives missing and creates nothing', () async {
      final store = storeOn(pairedFile);

      expect(await store.load(), PairedLoadResult.missing);
      expect(store.devices, isEmpty);
      expect(await namesIn(dataDir), isEmpty);
    });

    test('a file of the same owner gives loaded', () async {
      await (await storeWith([_device(0), _device(1)])).retrySave();
      final store = storeOn(pairedFile);

      expect(await store.load(), PairedLoadResult.loaded);
      expect(_fingerprints(store.devices), {_fp(0), _fp(1)});
      expect(await namesIn(dataDir), ['paired.json']);
    });

    test('another owner: previousIdentity, kept aside, empty list', () async {
      await storeOn(
        pairedFile,
        owner: _otherOwner,
      ).replaceAll([_device(0), _device(1)]);
      final content = pairedFile.readAsStringSync();
      final store = storeOn(pairedFile);
      final changes = recordChanges(store);

      expect(await store.load(), PairedLoadResult.previousIdentity);
      await pumpEventQueue();

      expect(store.devices, isEmpty);
      expect(store.isPaired(_fp(0)), isFalse);
      expect(store.isPaired(_fp(1)), isFalse);
      expect(await namesIn(dataDir), ['paired.json.previous-identity-$stamp']);
      expect(
        File('${dataDir.path}${sep}paired.json.previous-identity-$stamp')
            .readAsStringSync(),
        content,
      );
      expect(changes, isEmpty);
    });

    test('the same file read by its own owner gives loaded', () async {
      await storeOn(
        pairedFile,
        owner: _otherOwner,
      ).replaceAll([_device(0), _device(1)]);
      final store = storeOn(pairedFile, owner: _otherOwner);

      expect(await store.load(), PairedLoadResult.loaded);
      expect(_fingerprints(store.devices), {_fp(0), _fp(1)});
    });

    test('a new list after previousIdentity is written for the new owner '
        'and the old file stays', () async {
      await storeOn(pairedFile, owner: _otherOwner).replaceAll([_device(0)]);
      final old = pairedFile.readAsStringSync();
      final store = storeOn(pairedFile);
      await store.load();

      expect(await store.add(_device(1)), AddResult.added);

      expect(rawOf(pairedFile)['owner'], _owner);
      expect(fingerprintsIn(pairedFile), {_fp(1)});
      expect(
        File('${dataDir.path}${sep}paired.json.previous-identity-$stamp')
            .readAsStringSync(),
        old,
      );
    });

    test('previousIdentity empties a list that was already loaded', () async {
      final store = await storeWith([_device(0)]);
      await storeOn(pairedFile, owner: _otherOwner).replaceAll([_device(1)]);

      expect(await store.load(), PairedLoadResult.previousIdentity);
      expect(store.devices, isEmpty);
    });

    test('the owner is checked before the entries: another owner with an '
        'invalid entry is previousIdentity, not broken', () async {
      await pairedFile.writeAsString(
        jsonEncode({
          'version': 2,
          'owner': _otherOwner,
          'devices': [
            {..._device(0).toJson(), 'fingerprint': _fp(1)},
          ],
        }),
      );
      final store = storeOn(pairedFile);

      expect(await store.load(), PairedLoadResult.previousIdentity);
      expect(await namesIn(dataDir), ['paired.json.previous-identity-$stamp']);
    });

    final badOwners = <String, Object?>{
      'missing': null,
      'in lowercase': _owner.toLowerCase(),
      'of 63 characters': _owner.substring(0, 63),
      'of 65 characters': '${_owner}0',
      'a number': 42,
      'with spaces': ' $_owner ',
    };

    for (final MapEntry(key: label, value: owner) in badOwners.entries) {
      test('an owner $label goes to quarantine as broken', () async {
        final json = <String, Object?>{
          'version': 2,
          'devices': [_device(0).toJson()],
        };
        if (owner != null) json['owner'] = owner;
        final content = jsonEncode(json);
        await pairedFile.writeAsString(content);
        final store = storeOn(pairedFile);

        expect(await store.load(), PairedLoadResult.quarantined);
        expect(store.devices, isEmpty);
        expect(await namesIn(dataDir), ['paired.json.broken-$stamp']);
        expect(
          File('${dataDir.path}${sep}paired.json.broken-$stamp')
              .readAsStringSync(),
          content,
        );
      });
    }
  });

  group('a bad paired.json goes to quarantine (C13)', () {
    Map<String, Object?> v2(List<Object?> devices) => {
      'version': 2,
      'owner': _owner,
      'devices': devices,
    };

    final der = base64.decode(_bodyOf(_identities[0].certificatePem));
    final wholeDerFingerprint = sha256.convert(der).toString().toUpperCase();

    final cases = <String, Map<String, Object?> Function()>{
      'version 1 with the format of spec 001': () => {
        'version': 1,
        'devices': [
          {
            'fingerprint': _fp(0),
            'name': 'Laptop',
            'certificatePem': _identities[0].certificatePem,
            'permissions': ['send'],
            'pairedAt': '2026-10-20T12:00:00.000Z',
          },
        ],
      },
      'version 1 with a valid version 2 body': () => {
        ...v2([_device(0).toJson()]),
        'version': 1,
      },
      'no version': () => {
        ...v2([_device(0).toJson()]),
      }..remove('version'),
      'version 3': () => {
        ...v2([_device(0).toJson()]),
        'version': 3,
      },
      'version "2" as text': () => {
        ...v2([_device(0).toJson()]),
        'version': '2',
      },
      'version 2.5': () => {
        ...v2([_device(0).toJson()]),
        'version': 2.5,
      },
      'a fingerprint that is the SHA-256 of the whole DER (spec 001)': () =>
          v2([
            {..._device(0).toJson(), 'fingerprint': wholeDerFingerprint},
          ]),
      'a fingerprint of another key': () => v2([
        _device(1).toJson(),
        {..._device(0).toJson(), 'fingerprint': _fp(1)},
      ]),
      'two entries with the same canonicalName and different keys': () =>
          v2([_deviceOf(_twinOne).toJson(), _deviceOf(_twinTwo).toJson()]),
      'the same entry twice': () =>
          v2([_device(0).toJson(), _device(0).toJson()]),
      'a name of 65 runes': () => v2([
        {..._device(0).toJson(), 'name': '${_smile * 64}z'},
      ]),
      'a name that is not text': () => v2([
        {..._device(0).toJson(), 'name': 7},
      ]),
    };

    test('the fixtures are what the cases say', () {
      expect(wholeDerFingerprint, isNot(_fp(0)));
      expect(_twinOne.fingerprint, isNot(_twinTwo.fingerprint));
      final one = PeerCertificate.tryParse(_twinOne.certificatePem)!;
      final two = PeerCertificate.tryParse(_twinTwo.certificatePem)!;
      expect(one.canonicalName, two.canonicalName);
    });

    for (final MapEntry(key: label, value: build) in cases.entries) {
      test('$label: quarantined as broken and empty', () async {
        final content = jsonEncode(build());
        await pairedFile.writeAsString(content);
        final store = storeOn(pairedFile);
        final changes = recordChanges(store);

        expect(await store.load(), PairedLoadResult.quarantined);
        await pumpEventQueue();

        expect(store.devices, isEmpty);
        expect(store.isPaired(_fp(0)), isFalse);
        expect(await namesIn(dataDir), ['paired.json.broken-$stamp']);
        expect(
          File('${dataDir.path}${sep}paired.json.broken-$stamp')
              .readAsStringSync(),
          content,
        );
        expect(changes, isEmpty);
      });
    }

    test('an empty name and a name of 64 runes are loaded', () async {
      await pairedFile.writeAsString(
        jsonEncode(
          v2([
            {..._device(0).toJson(), 'name': ''},
            {..._device(1).toJson(), 'name': _smile * 64},
          ]),
        ),
      );
      final store = storeOn(pairedFile);

      expect(await store.load(), PairedLoadResult.loaded);
      expect(store.deviceOf(_fp(0))!.name, '');
      expect(store.deviceOf(_fp(1))!.name, _smile * 64);
    });

    test(
      'more than 32 entries are loaded; the limit is only for add',
      () async {
        await pairedFile.writeAsString(
          jsonEncode(v2([for (var i = 0; i < 33; i++) _device(i).toJson()])),
        );
        final store = storeOn(pairedFile);

        expect(await store.load(), PairedLoadResult.loaded);
        expect(store.devices, hasLength(33));
        expect(await store.add(_device(33)), AddResult.full);
        expect(store.devices, hasLength(33));
      },
    );
  });

  group('add writes first (RF-94)', () {
    test('added: memory, file and one change after the write', () async {
      final store = await storeWith([_device(0)]);
      final status = recordSaveStatus(store);
      final inFileWhenNotified = <Set<String>>[];
      final changes = <Set<String>>[];
      final subscription = store.changes.listen((_) {
        changes.add(_fingerprints(store.devices));
        inFileWhenNotified.add(fingerprintsIn(pairedFile));
      });
      addTearDown(subscription.cancel);

      final adding = store.add(_device(1));
      final pairedBeforeTheWrite = store.isPaired(_fp(1));
      final result = await adding;
      await pumpEventQueue();

      expect(pairedBeforeTheWrite, isFalse);
      expect(result, AddResult.added);
      expect(_fingerprints(store.devices), {_fp(0), _fp(1)});
      expect(store.deviceOf(_fp(1))!.relation, PeerRelation.foreign);
      expect(changes, [
        {_fp(0), _fp(1)},
      ]);
      expect(inFileWhenNotified, [
        {_fp(0), _fp(1)},
      ]);
      expect(fingerprintsIn(pairedFile), {_fp(0), _fp(1)});
      expect(store.hasUnsavedChanges, isFalse);
      expect(status, isEmpty);
    });

    test('C14: on an impossible path gives notSaved and changes nothing '
        'in memory', () async {
      final folder = Directory('${dataDir.path}${sep}data');
      final file = File('${folder.path}${sep}paired.json');
      final store = storeOn(file);
      await store.replaceAll([_device(0)]);
      await blockFolder(folder);
      final changes = recordChanges(store);
      final status = recordSaveStatus(store);

      final result = await store.add(_device(1));
      await pumpEventQueue();

      expect(result, AddResult.notSaved);
      expect(_fingerprints(store.devices), {_fp(0)});
      expect(store.isPaired(_fp(1)), isFalse);
      expect(changes, isEmpty);
      expect(store.hasUnsavedChanges, isTrue);
      expect(status, [true]);
    });

    test('C14: with the file locked gives notSaved and the file keeps its '
        'content', () async {
      final store = await storeWith([_device(0)]);
      final before = pairedFile.readAsStringSync();
      final held = lock(pairedFile);
      final changes = recordChanges(store);

      final result = await store.add(_device(1));
      held.release();
      await pumpEventQueue();

      expect(result, AddResult.notSaved);
      expect(store.isPaired(_fp(1)), isFalse);
      expect(changes, isEmpty);
      expect(pairedFile.readAsStringSync(), before);
    });

    test('C14: once the disk works again the same add succeeds', () async {
      final folder = Directory('${dataDir.path}${sep}data');
      final file = File('${folder.path}${sep}paired.json');
      final store = storeOn(file);
      await store.replaceAll([_device(0)]);
      await blockFolder(folder);
      final status = recordSaveStatus(store);
      expect(await store.add(_device(1)), AddResult.notSaved);

      await File(folder.path).delete();

      expect(await store.add(_device(1)), AddResult.added);
      await pumpEventQueue();
      expect(store.isPaired(_fp(1)), isTrue);
      expect(fingerprintsIn(file), {_fp(0), _fp(1)});
      expect(store.hasUnsavedChanges, isFalse);
      expect(status, [true, false]);
    });

    test('alreadyPaired keeps the stored device as it was', () async {
      final store = await storeWith([_device(0)]);
      final before = pairedFile.readAsStringSync();
      final changes = recordChanges(store);

      final result = await store.add(
        _deviceOf(_identities[0], name: 'Other', relation: PeerRelation.mine),
      );
      await pumpEventQueue();

      expect(result, AddResult.alreadyPaired);
      expect(_fieldsOf(store.devices.single), _fieldsOf(_device(0)));
      expect(changes, isEmpty);
      expect(pairedFile.readAsStringSync(), before);
    });

    test('duplicateSubject: another key with the same canonical name is '
        'refused and the paired one stays (RF-93)', () async {
      final store = await storeWith([_deviceOf(_twinOne)]);
      final before = pairedFile.readAsStringSync();
      final changes = recordChanges(store);

      final result = await store.add(_deviceOf(_twinTwo));
      await pumpEventQueue();

      expect(result, AddResult.duplicateSubject);
      expect(_fingerprints(store.devices), {_twinOne.fingerprint});
      expect(store.isPaired(_twinTwo.fingerprint), isFalse);
      expect(changes, isEmpty);
      expect(pairedFile.readAsStringSync(), before);
    });

    final invalid = <String, PairedDevice Function()>{
      'the fingerprint of another certificate': () => PairedDevice(
        fingerprint: _fp(1),
        name: 'X',
        certificatePem: _identities[0].certificatePem,
        relation: PeerRelation.foreign,
        pairedAt: DateTime.utc(2026),
      ),
      'a lowercase fingerprint': () => PairedDevice(
        fingerprint: _fp(0).toLowerCase(),
        name: 'X',
        certificatePem: _identities[0].certificatePem,
        relation: PeerRelation.foreign,
        pairedAt: DateTime.utc(2026),
      ),
      'a garbage certificate': () => PairedDevice(
        fingerprint: _fp(0),
        name: 'X',
        certificatePem: 'garbage',
        relation: PeerRelation.foreign,
        pairedAt: DateTime.utc(2026),
      ),
    };

    for (final MapEntry(key: label, value: build) in invalid.entries) {
      test('$label throws ArgumentError and writes nothing', () async {
        final store = storeOn(pairedFile);
        final changes = recordChanges(store);

        await expectLater(store.add(build()), throwsArgumentError);
        await pumpEventQueue();

        expect(store.devices, isEmpty);
        expect(changes, isEmpty);
        expect(await namesIn(dataDir), isEmpty);
      });
    }
  });

  group('the limit of 32 (RF-71, C20)', () {
    test('with 32 paired, add gives full and nothing is written', () async {
      final store = await storeWith([for (var i = 0; i < 32; i++) _device(i)]);
      final before = pairedFile.readAsStringSync();
      final changes = recordChanges(store);

      final result = await store.add(_device(32));
      await pumpEventQueue();

      expect(PairedDevicesStore.maxDevices, 32);
      expect(result, AddResult.full);
      expect(store.devices, hasLength(32));
      expect(store.isPaired(_fp(32)), isFalse);
      expect(changes, isEmpty);
      expect(pairedFile.readAsStringSync(), before);
    });

    test('with 31 paired, the 32nd is added', () async {
      final store = await storeWith([for (var i = 0; i < 31; i++) _device(i)]);

      expect(await store.add(_device(31)), AddResult.added);
      expect(store.devices, hasLength(32));
      expect(entriesOf(pairedFile), hasLength(32));
    });

    test('with 32 paired, one of them gives alreadyPaired', () async {
      final store = await storeWith([for (var i = 0; i < 32; i++) _device(i)]);

      expect(await store.add(_device(5)), AddResult.alreadyPaired);
    });
  });

  group('add checks again when its turn comes', () {
    test('the same device twice at once: added and alreadyPaired', () async {
      final store = storeOn(pairedFile);

      final results = await Future.wait([
        store.add(_device(0)),
        store.add(_device(0)),
      ]);

      expect(results, [AddResult.added, AddResult.alreadyPaired]);
      expect(store.devices, hasLength(1));
      expect(entriesOf(pairedFile), hasLength(1));
    });

    test('two keys with the same subject at once: added and '
        'duplicateSubject', () async {
      final store = storeOn(pairedFile);

      final results = await Future.wait([
        store.add(_deviceOf(_twinOne)),
        store.add(_deviceOf(_twinTwo)),
      ]);

      expect(results, [AddResult.added, AddResult.duplicateSubject]);
      expect(_fingerprints(store.devices), {_twinOne.fingerprint});
      expect(fingerprintsIn(pairedFile), {_twinOne.fingerprint});
    });

    test('two new devices at once with 31 paired: added and full', () async {
      final store = await storeWith([for (var i = 0; i < 31; i++) _device(i)]);

      final results = await Future.wait([
        store.add(_device(31)),
        store.add(_device(32)),
      ]);

      expect(results, [AddResult.added, AddResult.full]);
      expect(store.devices, hasLength(32));
      expect(store.isPaired(_fp(32)), isFalse);
      expect(entriesOf(pairedFile), hasLength(32));
    });
  });

  group('remove applies in memory first (RF-113, RF-114, C15)', () {
    test('memory and changes before the write ends; then saved', () async {
      final store = await storeWith([_device(0), _device(1)]);
      var removeDone = false;
      final doneWhenNotified = <bool>[];
      final subscription = store.changes.listen(
        (_) => doneWhenNotified.add(removeDone),
      );
      addTearDown(subscription.cancel);

      final removing = store.remove(_fp(1)).whenComplete(() {
        removeDone = true;
      });
      final pairedRightAfterTheCall = store.isPaired(_fp(1));
      final devicesRightAfterTheCall = _fingerprints(store.devices);

      expect(await removing, isTrue);
      await pumpEventQueue();

      expect(pairedRightAfterTheCall, isFalse);
      expect(devicesRightAfterTheCall, {_fp(0)});
      expect(doneWhenNotified, [false]);
      expect(fingerprintsIn(pairedFile), {_fp(0)});
      expect(store.hasUnsavedChanges, isFalse);
    });

    test('C15: without disk it is unpaired for the session, returns false '
        'and the file still has it', () async {
      final store = await storeWith([_device(0), _device(1)]);
      final held = lock(pairedFile);
      final status = recordSaveStatus(store);
      var removeDone = false;
      final doneWhenNotified = <bool>[];
      final subscription = store.changes.listen(
        (_) => doneWhenNotified.add(removeDone),
      );
      addTearDown(subscription.cancel);

      final removing = store.remove(_fp(1)).whenComplete(() {
        removeDone = true;
      });
      final pairedRightAfterTheCall = store.isPaired(_fp(1));
      final saved = await removing;
      await pumpEventQueue();
      held.release();

      expect(pairedRightAfterTheCall, isFalse);
      expect(saved, isFalse);
      expect(doneWhenNotified, [false]);
      expect(store.isPaired(_fp(1)), isFalse);
      expect(store.hasUnsavedChanges, isTrue);
      expect(status, [true]);
      expect(fingerprintsIn(pairedFile), {_fp(0), _fp(1)});
    });

    test('C15: retrySave once the disk works writes the unpairing', () async {
      final store = await storeWith([_device(0), _device(1)]);
      final held = lock(pairedFile);
      final status = recordSaveStatus(store);
      expect(await store.remove(_fp(1)), isFalse);
      held.release();

      expect(await store.retrySave(), isTrue);
      await pumpEventQueue();

      expect(fingerprintsIn(pairedFile), {_fp(0)});
      expect(store.hasUnsavedChanges, isFalse);
      expect(status, [true, false]);
      final reloaded = storeOn(pairedFile);
      await reloaded.load();
      expect(reloaded.isPaired(_fp(1)), isFalse);
      expect(reloaded.isPaired(_fp(0)), isTrue);
    });

    test('C15: on an impossible path the unpairing still rules', () async {
      final folder = Directory('${dataDir.path}${sep}data');
      final file = File('${folder.path}${sep}paired.json');
      final store = storeOn(file);
      await store.replaceAll([_device(0), _device(1)]);
      await blockFolder(folder);

      expect(await store.remove(_fp(0)), isFalse);
      expect(store.isPaired(_fp(0)), isFalse);
      expect(store.hasUnsavedChanges, isTrue);

      await File(folder.path).delete();
      expect(await store.retrySave(), isTrue);
      expect(fingerprintsIn(file), {_fp(1)});
    });

    test(
      'a fingerprint that is not paired gives true and does nothing',
      () async {
        final store = storeOn(pairedFile);
        final changes = recordChanges(store);
        final status = recordSaveStatus(store);

        expect(await store.remove(_fp(0)), isTrue);
        await pumpEventQueue();

        expect(changes, isEmpty);
        expect(status, isEmpty);
        expect(await namesIn(dataDir), isEmpty);
      },
    );
  });

  group('setRelation (RF-102, RF-120, C17)', () {
    test('changes memory at once, saves and survives a reload', () async {
      final store = await storeWith([_device(0), _device(1)]);
      final changes = recordChanges(store);

      final changing = store.setRelation(_fp(0), PeerRelation.mine);
      final relationRightAfterTheCall = store.deviceOf(_fp(0))!.relation;

      expect(await changing, isTrue);
      await pumpEventQueue();

      expect(relationRightAfterTheCall, PeerRelation.mine);
      expect(changes, hasLength(1));
      expect(store.deviceOf(_fp(0))!.permissions, {
        Permission.send,
        Permission.receive,
        Permission.browse,
      });
      final reloaded = storeOn(pairedFile);
      await reloaded.load();
      expect(reloaded.deviceOf(_fp(0))!.relation, PeerRelation.mine);
      expect(reloaded.deviceOf(_fp(1))!.relation, PeerRelation.foreign);
      expect(
        _fieldsOf(reloaded.deviceOf(_fp(0))!),
        _fieldsOf(_device(0).copyWith(relation: PeerRelation.mine)),
      );
    });

    test('back to foreign without pairing again', () async {
      final store = await storeWith([
        _device(0).copyWith(relation: PeerRelation.mine),
      ]);

      expect(await store.setRelation(_fp(0), PeerRelation.foreign), isTrue);

      expect(store.deviceOf(_fp(0))!.relation, PeerRelation.foreign);
      expect(entriesOf(pairedFile).single['relation'], 'foreign');
    });

    test(
      'C17: without disk the change rules in memory and returns false',
      () async {
        final store = await storeWith([_device(0)]);
        final held = lock(pairedFile);
        final changes = recordChanges(store);
        final status = recordSaveStatus(store);

        final saved = await store.setRelation(_fp(0), PeerRelation.mine);
        await pumpEventQueue();
        held.release();

        expect(saved, isFalse);
        expect(store.deviceOf(_fp(0))!.relation, PeerRelation.mine);
        expect(changes, hasLength(1));
        expect(store.hasUnsavedChanges, isTrue);
        expect(status, [true]);
        expect(entriesOf(pairedFile).single['relation'], 'foreign');

        expect(await store.retrySave(), isTrue);
        expect(entriesOf(pairedFile).single['relation'], 'mine');
        expect(store.hasUnsavedChanges, isFalse);
      },
    );
  });

  group('rename (RF-128, C18)', () {
    test('saves the new name and a new store loads it', () async {
      final store = await storeWith([_device(0)]);
      final changes = recordChanges(store);

      expect(await store.rename(_fp(0), 'PORTATIL-NUEVO'), isTrue);
      await pumpEventQueue();

      expect(store.deviceOf(_fp(0))!.name, 'PORTATIL-NUEVO');
      expect(changes, hasLength(1));
      final reloaded = storeOn(pairedFile);
      expect(await reloaded.load(), PairedLoadResult.loaded);
      expect(reloaded.deviceOf(_fp(0))!.name, 'PORTATIL-NUEVO');
    });

    final clipped = <String, (String, String)>{
      '65 runes ending in an emoji cut after it': (
        '${'é' * 63}${_smile}z',
        '${'é' * 63}$_smile',
      ),
      '64 emojis and one more letter': ('${_smile * 64}z', _smile * 64),
      '65 emojis': (_smile * 65, _smile * 64),
      'exactly 64 runes, untouched': (
        '${'a' * 63}$_smile',
        '${'a' * 63}$_smile',
      ),
    };

    for (final MapEntry(key: label, value: (given, expected))
        in clipped.entries) {
      test('rename: $label', () async {
        final store = await storeWith([_device(0)]);

        expect(await store.rename(_fp(0), given), isTrue);

        final name = store.deviceOf(_fp(0))!.name;
        expect(name, expected);
        expect(name.runes.length, lessThanOrEqualTo(64));
        expect(utf8.decode(utf8.encode(name)), name);
        final reloaded = storeOn(pairedFile);
        expect(await reloaded.load(), PairedLoadResult.loaded);
        expect(reloaded.deviceOf(_fp(0))!.name, expected);
      });
    }

    test('without disk the new name rules and returns false', () async {
      final store = await storeWith([_device(0)]);
      final held = lock(pairedFile);

      final saved = await store.rename(_fp(0), 'NEW');
      held.release();

      expect(saved, isFalse);
      expect(store.deviceOf(_fp(0))!.name, 'NEW');
      expect(store.hasUnsavedChanges, isTrue);
    });
  });

  group('add clips the name to 64 runes', () {
    final clipped = <String, (String, String)>{
      '65 runes with an emoji in the middle': (
        '${'a' * 30}$_smile${'b' * 34}',
        '${'a' * 30}$_smile${'b' * 33}',
      ),
      '65 runes ending in an emoji': ('${'é' * 64}$_smile', 'é' * 64),
      '64 emojis and a letter': ('${_smile * 64}z', _smile * 64),
    };

    for (final MapEntry(key: label, value: (given, expected))
        in clipped.entries) {
      test('$label: in memory, in the file and after a reload', () async {
        final store = storeOn(pairedFile);

        final result = await store.add(_deviceOf(_identities[0], name: given));

        expect(given.runes.length, 65);
        expect(result, AddResult.added);
        expect(store.deviceOf(_fp(0))!.name, expected);
        expect(entriesOf(pairedFile).single['name'], expected);
        final reloaded = storeOn(pairedFile);
        expect(await reloaded.load(), PairedLoadResult.loaded);
        expect(reloaded.deviceOf(_fp(0))!.name, expected);
      });
    }
  });

  group('an unknown fingerprint (C97)', () {
    test('setRelation and rename give false without any change', () async {
      final store = await storeWith([_device(0)]);
      final before = pairedFile.readAsStringSync();
      final changes = recordChanges(store);
      final status = recordSaveStatus(store);

      expect(await store.setRelation(_fp(1), PeerRelation.mine), isFalse);
      expect(await store.rename(_fp(1), 'Ghost'), isFalse);
      await pumpEventQueue();

      expect(_fieldsOf(store.devices.single), _fieldsOf(_device(0)));
      expect(store.deviceOf(_fp(1)), isNull);
      expect(changes, isEmpty);
      expect(status, isEmpty);
      expect(pairedFile.readAsStringSync(), before);
    });

    test('on an empty store they create no file', () async {
      final store = storeOn(pairedFile);

      expect(await store.setRelation(_fp(0), PeerRelation.mine), isFalse);
      expect(await store.rename(_fp(0), 'Ghost'), isFalse);

      expect(await namesIn(dataDir), isEmpty);
    });
  });

  group('hasUnsavedChanges and saveStatusChanges', () {
    test('false at the start', () {
      expect(storeOn(pairedFile).hasUnsavedChanges, isFalse);
    });

    test('emits only when the value changes', () async {
      final store = await storeWith([_device(0)]);
      final status = recordSaveStatus(store);
      final held = lock(pairedFile);

      expect(await store.retrySave(), isFalse);
      expect(await store.setRelation(_fp(0), PeerRelation.mine), isFalse);
      held.release();
      expect(await store.retrySave(), isTrue);
      expect(await store.rename(_fp(0), 'Again'), isTrue);
      await pumpEventQueue();

      expect(status, [true, false]);
    });

    test('both streams are broadcast', () async {
      final store = await storeWith([_device(0)]);
      final first = recordSaveStatus(store);
      final second = recordSaveStatus(store);
      final changesOne = recordChanges(store);
      final changesTwo = recordChanges(store);
      final held = lock(pairedFile);

      await store.remove(_fp(0));
      held.release();
      await pumpEventQueue();

      expect(store.saveStatusChanges.isBroadcast, isTrue);
      expect(store.changes.isBroadcast, isTrue);
      expect(first, [true]);
      expect(second, [true]);
      expect(changesOne, hasLength(1));
      expect(changesTwo, hasLength(1));
    });
  });

  group('concurrent changes never resurrect an unpaired device (C16)', () {
    test('add(A), remove(B), remove(C), add(D) without waiting', () async {
      final store = await storeWith([_device(1), _device(2)]);
      final changes = recordChanges(store);
      final snapshots = <Set<String>>[];

      final addA = store.add(_device(0));
      final removeB = store.remove(_fp(1));
      snapshots.add(_fingerprints(store.devices));
      final removeC = store.remove(_fp(2));
      snapshots.add(_fingerprints(store.devices));
      final addD = store.add(_device(3));
      snapshots.add(_fingerprints(store.devices));

      final results = await Future.wait<Object>([addA, removeB, removeC, addD]);
      await pumpEventQueue();

      expect(results, [AddResult.added, true, true, AddResult.added]);
      expect(snapshots[0], {_fp(2)});
      expect(snapshots[1], isEmpty);
      expect(snapshots[2], isEmpty);
      for (final seen in [...snapshots, ...changes]) {
        expect(seen, isNot(contains(_fp(1))));
      }
      for (final seen in [...snapshots.skip(1), ...changes]) {
        expect(seen, isNot(contains(_fp(2))));
      }
      expect(changes.last, {_fp(0), _fp(3)});
      expect(_fingerprints(store.devices), {_fp(0), _fp(3)});
      expect(fingerprintsIn(pairedFile), {_fp(0), _fp(3)});
      final reloaded = storeOn(pairedFile);
      await reloaded.load();
      expect(_fingerprints(reloaded.devices), {_fp(0), _fp(3)});
      expect(store.hasUnsavedChanges, isFalse);
    });

    test('a remove while an add is writing: the add does not bring it '
        'back', () async {
      final store = await storeWith([_device(1), _device(2)]);
      var addDone = false;

      final adding = store.add(_device(0)).whenComplete(() => addDone = true);
      await Future<void>.delayed(Duration.zero);
      final addFinishedBeforeTheRemove = addDone;
      final removing = store.remove(_fp(1));

      expect(await adding, AddResult.added);
      expect(await removing, isTrue);

      expect(addFinishedBeforeTheRemove, isFalse);
      expect(_fingerprints(store.devices), {_fp(2), _fp(0)});
      expect(fingerprintsIn(pairedFile), {_fp(2), _fp(0)});
    });

    test('a queued write saves the memory of its turn, not of the moment '
        'it was queued', () async {
      final store = await storeWith([_device(1), _device(2)]);
      var addDone = false;

      final adding = store.add(_device(0)).whenComplete(() => addDone = true);
      final retrying = store.retrySave();
      await Future<void>.delayed(Duration.zero);
      final addFinishedBeforeTheRemove = addDone;
      final removing = store.remove(_fp(1));

      expect(await retrying, isTrue);
      final writtenByTheRetry = fingerprintsIn(pairedFile);
      expect(await adding, AddResult.added);
      expect(await removing, isTrue);

      expect(addFinishedBeforeTheRemove, isFalse);
      expect(writtenByTheRetry, {_fp(2), _fp(0)});
      expect(fingerprintsIn(pairedFile), {_fp(2), _fp(0)});
    });

    test('ten removes and ten adds interleaved', () async {
      final old = [for (var i = 0; i < 10; i++) _device(i)];
      final fresh = [for (var i = 10; i < 20; i++) _device(i)];
      final oldFingerprints = _fingerprints(old);
      final store = await storeWith(old);
      final changes = recordChanges(store);
      final removed = <String>{};
      final calls = <Future<Object>>[];

      for (var i = 0; i < 10; i++) {
        calls.add(store.add(fresh[i]));
        calls.add(store.remove(old[i].fingerprint));
        removed.add(old[i].fingerprint);
        expect(_fingerprints(store.devices).intersection(removed), isEmpty);
      }
      final results = await Future.wait(calls);
      await pumpEventQueue();

      expect(results, [
        for (var i = 0; i < 10; i++) ...[AddResult.added, true],
      ]);
      for (final seen in changes) {
        expect(seen.intersection(oldFingerprints), isEmpty);
      }
      expect(_fingerprints(store.devices), _fingerprints(fresh));
      expect(fingerprintsIn(pairedFile), _fingerprints(fresh));
      final reloaded = storeOn(pairedFile);
      await reloaded.load();
      expect(_fingerprints(reloaded.devices), _fingerprints(fresh));
    });

    test('a setRelation and a remove of two devices at once keep both '
        'changes', () async {
      final store = await storeWith([_device(0), _device(1)]);

      final results = await Future.wait([
        store.setRelation(_fp(0), PeerRelation.mine),
        store.remove(_fp(1)),
      ]);

      expect(results, [true, true]);
      final entries = entriesOf(pairedFile);
      expect(entries.single['fingerprint'], _fp(0));
      expect(entries.single['relation'], 'mine');
    });
  });

  group('an add that misses its deadline (RF-94, C94, C106)', () {
    test('C94: notSaved; the late write lands and the corrective write '
        'takes it out of the file', () async {
      final store = await storeWith([_device(1)]);
      await makeUnsaved(store);
      final changes = recordChanges(store);
      final status = <bool>[];
      Set<String>? afterTheLateWrite;
      _ExclusiveLock? held;
      final corrected = Completer<void>();
      final subscription = store.saveStatusChanges.listen((_) {
        status.add(store.hasUnsavedChanges);
        switch (status.length) {
          case 1:
            afterTheLateWrite = fingerprintsIn(pairedFile);
            held = lock(pairedFile);
          case 2:
            held!.release();
          case 3:
            corrected.complete();
        }
      });
      addTearDown(subscription.cancel);

      final result = await store.add(_device(0), timeout: Duration.zero);
      final lateWriteDoneBeforeTheBarrier = status.isNotEmpty;
      final barrier = store.retrySave();
      final pairedRightAfter = store.isPaired(_fp(0));
      await corrected.future.timeout(const Duration(seconds: 10));
      await pumpEventQueue();

      expect(result, AddResult.notSaved);
      expect(pairedRightAfter, isFalse);
      expect(lateWriteDoneBeforeTheBarrier, isFalse);
      expect(afterTheLateWrite, {_fp(1), _fp(0)});
      expect(await barrier, isFalse);
      expect(status, [false, true, false]);
      expect(fingerprintsIn(pairedFile), {_fp(1)});
      expect(_fingerprints(store.devices), {_fp(1)});
      expect(store.isPaired(_fp(0)), isFalse);
      expect(changes, isEmpty);
      expect(store.hasUnsavedChanges, isFalse);
    });

    test('C106: the late write lands and the corrective write fails: '
        'hasUnsavedChanges and retrySave', () async {
      final store = await storeWith([_device(1)]);
      await makeUnsaved(store);
      final changes = recordChanges(store);
      final status = <bool>[];
      Set<String>? afterTheLateWrite;
      _ExclusiveLock? held;
      final correctiveFailed = Completer<void>();
      final subscription = store.saveStatusChanges.listen((_) {
        status.add(store.hasUnsavedChanges);
        switch (status.length) {
          case 1:
            afterTheLateWrite = fingerprintsIn(pairedFile);
            held = lock(pairedFile);
          case 2:
            correctiveFailed.complete();
        }
      });
      addTearDown(subscription.cancel);

      final result = await store.add(_device(0), timeout: Duration.zero);
      await correctiveFailed.future.timeout(const Duration(seconds: 10));
      await pumpEventQueue();

      expect(result, AddResult.notSaved);
      expect(afterTheLateWrite, {_fp(1), _fp(0)});
      expect(status, [false, true]);
      expect(store.hasUnsavedChanges, isTrue);
      expect(store.isPaired(_fp(0)), isFalse);
      expect(_fingerprints(store.devices), {_fp(1)});
      expect(changes, isEmpty);

      held!.release();
      expect(await store.retrySave(), isTrue);
      await pumpEventQueue();

      expect(fingerprintsIn(pairedFile), {_fp(1)});
      expect(store.hasUnsavedChanges, isFalse);
      expect(status, [false, true, false]);
      final reloaded = storeOn(pairedFile);
      await reloaded.load();
      expect(reloaded.isPaired(_fp(0)), isFalse);
    });

    test('C106: the late write and the corrective write both fail', () async {
      final store = await storeWith([_device(1)]);
      final before = pairedFile.readAsStringSync();
      final changes = recordChanges(store);
      final status = recordSaveStatus(store);
      final held = lock(pairedFile);
      final failed = Completer<void>();
      final subscription = store.saveStatusChanges.listen((_) {
        if (!failed.isCompleted) failed.complete();
      });
      addTearDown(subscription.cancel);

      final result = await store.add(_device(0), timeout: Duration.zero);
      await failed.future.timeout(const Duration(seconds: 10));
      await Future<void>.delayed(Duration.zero);
      expect(await store.retrySave(), isFalse);
      await pumpEventQueue();

      expect(result, AddResult.notSaved);
      expect(status, [true]);
      expect(store.hasUnsavedChanges, isTrue);
      expect(store.isPaired(_fp(0)), isFalse);
      expect(changes, isEmpty);

      held.release();
      expect(pairedFile.readAsStringSync(), before);
      expect(await store.retrySave(), isTrue);
      expect(fingerprintsIn(pairedFile), {_fp(1)});
      expect(store.hasUnsavedChanges, isFalse);
    });

    test('an add abandoned before its turn leaves memory and file without '
        'the device', () async {
      final store = await storeWith([_device(1)]);
      final changes = recordChanges(store);
      final status = recordSaveStatus(store);

      final ahead = store.retrySave();
      final result = await store.add(_device(0), timeout: Duration.zero);
      expect(await ahead, isTrue);
      expect(await store.retrySave(), isTrue);
      await pumpEventQueue();

      expect(result, AddResult.notSaved);
      expect(store.isPaired(_fp(0)), isFalse);
      expect(fingerprintsIn(pairedFile), {_fp(1)});
      expect(changes, isEmpty);
      expect(status, isEmpty);
    });

    test('a later add of the same device works normally', () async {
      final store = await storeWith([_device(1)]);

      expect(
        await store.add(_device(0), timeout: Duration.zero),
        AddResult.notSaved,
      );
      await store.retrySave();

      expect(await store.add(_device(0)), AddResult.added);
      expect(fingerprintsIn(pairedFile), {_fp(1), _fp(0)});
    });
  });
}
