import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:nexus_bridges_core/src/pairing/pairing.dart';
import 'package:nexus_bridges_core/src/storage/storage.dart';
import 'package:test/test.dart';

const String _smile = '\u{1F600}';

String _fp(int index) => index.toRadixString(16).toUpperCase().padLeft(64, '0');

Set<String> _fingerprints(Iterable<IgnoredDevice> devices) => {
  for (final d in devices) d.fingerprint,
};

Matcher _sameMoment(DateTime expected) => predicate<DateTime>(
  (t) => t.isAtSameMomentAs(expected),
  'the same moment as $expected',
);

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
  final start = DateTime.utc(2026, 10, 23, 18, 4, 5);
  const stamp = '20261023-180405';

  late Directory dataDir;
  late File ignoredFile;
  late Set<String> paired;
  late DateTime current;

  setUp(() async {
    dataDir = await Directory.systemTemp.createTemp('nexus_ignored_test_');
    addTearDown(() => dataDir.delete(recursive: true));
    ignoredFile = File('${dataDir.path}${sep}ignored.json');
    paired = <String>{};
    current = start;
  });

  void tick([Duration step = const Duration(minutes: 1)]) {
    current = current.add(step);
  }

  IgnoredDevicesStore storeOn(File file) => IgnoredDevicesStore(
    JsonFileStore(file),
    isPaired: paired.contains,
    now: () => current,
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

  List<String> fingerprintsIn(File file) => [
    for (final entry in entriesOf(file)) entry['fingerprint']! as String,
  ];

  Map<String, Object?> entry(int index, {String? name, DateTime? at}) => {
    'fingerprint': _fp(index),
    'name': name ?? 'PC-$index',
    'ignoredAt': (at ?? start).toUtc().toIso8601String(),
  };

  Future<void> seed(List<Object?> devices, {Object? version = 1}) {
    return ignoredFile.writeAsString(
      jsonEncode({'version': version, 'devices': devices}),
    );
  }

  _ExclusiveLock lock(File file) {
    final held = _ExclusiveLock(file);
    addTearDown(held.release);
    return held;
  }

  Future<void> blockFolder(Directory folder) async {
    await folder.delete(recursive: true);
    await File(folder.path).writeAsString('i am a file, not a folder');
  }

  List<Set<String>> recordChanges(IgnoredDevicesStore store) {
    final seen = <Set<String>>[];
    final subscription = store.changes.listen(
      (_) => seen.add(_fingerprints(store.devices)),
    );
    addTearDown(subscription.cancel);
    return seen;
  }

  List<bool> recordSaveStatus(IgnoredDevicesStore store) {
    final seen = <bool>[];
    final subscription = store.saveStatusChanges.listen(
      (_) => seen.add(store.hasUnsavedChanges),
    );
    addTearDown(subscription.cancel);
    return seen;
  }

  Future<IgnoredDevicesStore> storeWith(List<int> indexes) async {
    final store = storeOn(ignoredFile);
    for (final i in indexes) {
      tick();
      expect(await store.ignore(_fp(i), name: 'PC-$i'), IgnoreResult.ignored);
    }
    return store;
  }

  group('the format of ignored.json', () {
    test('version 1 with fingerprint, name and ignoredAt in UTC', () async {
      final store = storeOn(ignoredFile);

      expect(await store.ignore(_fp(1), name: 'PC-RARO'), IgnoreResult.ignored);

      expect(rawOf(ignoredFile), {
        'version': 1,
        'devices': [
          {
            'fingerprint': _fp(1),
            'name': 'PC-RARO',
            'ignoredAt': '2026-10-23T18:04:05.000Z',
          },
        ],
      });
    });

    test('a local clock is stored as the same moment in UTC', () async {
      current = DateTime(2026, 10, 23, 20, 30);
      final store = storeOn(ignoredFile);

      await store.ignore(_fp(1), name: 'X');

      final stored = entriesOf(ignoredFile).single['ignoredAt']! as String;
      expect(stored, endsWith('Z'));
      expect(DateTime.parse(stored), _sameMoment(current));
      expect(store.devices.single.ignoredAt, _sameMoment(current));
    });

    test('maxDevices is 256', () {
      expect(IgnoredDevicesStore.maxDevices, 256);
    });
  });

  group('ignore (RF-108, C19)', () {
    test('memory and changes at once, then saved to the file', () async {
      final store = storeOn(ignoredFile);
      final status = recordSaveStatus(store);
      var ignoreDone = false;
      final doneWhenNotified = <bool>[];
      final changes = <Set<String>>[];
      final subscription = store.changes.listen((_) {
        doneWhenNotified.add(ignoreDone);
        changes.add(_fingerprints(store.devices));
      });
      addTearDown(subscription.cancel);

      final ignoring = store.ignore(_fp(1), name: 'PC-RARO').whenComplete(() {
        ignoreDone = true;
      });
      final ignoredRightAfterTheCall = store.isIgnored(_fp(1));
      final result = await ignoring;
      await pumpEventQueue();

      expect(ignoredRightAfterTheCall, isTrue);
      expect(result, IgnoreResult.ignored);
      expect(doneWhenNotified, [false]);
      expect(changes, [
        {_fp(1)},
      ]);
      final device = store.devices.single;
      expect(device.fingerprint, _fp(1));
      expect(device.name, 'PC-RARO');
      expect(device.ignoredAt, _sameMoment(start));
      expect(fingerprintsIn(ignoredFile), [_fp(1)]);
      expect(store.hasUnsavedChanges, isFalse);
      expect(status, isEmpty);
      expect(await namesIn(dataDir), ['ignored.json']);
    });

    test('isIgnored is false for any other fingerprint', () async {
      final store = await storeWith([0xABC]);

      expect(store.isIgnored(_fp(0xABC)), isTrue);
      expect(store.isIgnored(_fp(2)), isFalse);
      expect(_fp(0xABC).toLowerCase(), isNot(_fp(0xABC)));
      expect(store.isIgnored(_fp(0xABC).toLowerCase()), isFalse);
    });

    test('survives a restart: a new store loads it', () async {
      await storeWith([1, 2]);
      final reloaded = storeOn(ignoredFile);

      await reloaded.load();

      expect(reloaded.isIgnored(_fp(1)), isTrue);
      expect(reloaded.isIgnored(_fp(2)), isTrue);
      expect(reloaded.isIgnored(_fp(3)), isFalse);
      expect([for (final d in reloaded.devices) d.name], ['PC-1', 'PC-2']);
      expect(
        reloaded.devices.first.ignoredAt,
        _sameMoment(start.add(const Duration(minutes: 1))),
      );
      expect(
        reloaded.devices.last.ignoredAt,
        _sameMoment(start.add(const Duration(minutes: 2))),
      );
    });

    test('ignoring again updates ignoredAt and keeps one entry in its '
        'place', () async {
      final store = await storeWith([1, 2, 3]);
      final changes = recordChanges(store);
      current = start.add(const Duration(days: 3));

      final result = await store.ignore(_fp(1), name: 'PC-1-NEW');
      await pumpEventQueue();

      expect(result, IgnoreResult.ignored);
      expect(store.devices.map((d) => d.fingerprint), [_fp(1), _fp(2), _fp(3)]);
      expect(store.devices.first.ignoredAt, _sameMoment(current));
      expect(store.devices.first.name, 'PC-1-NEW');
      expect(changes, hasLength(1));
      expect(fingerprintsIn(ignoredFile), [_fp(1), _fp(2), _fp(3)]);
      expect(
        DateTime.parse(entriesOf(ignoredFile).first['ignoredAt']! as String),
        _sameMoment(current),
      );
      final reloaded = storeOn(ignoredFile);
      await reloaded.load();
      expect(reloaded.devices, hasLength(3));
      expect(reloaded.devices.first.ignoredAt, _sameMoment(current));
    });

    test('an empty name is accepted and reloaded', () async {
      final store = storeOn(ignoredFile);

      expect(await store.ignore(_fp(1), name: ''), IgnoreResult.ignored);

      final reloaded = storeOn(ignoredFile);
      await reloaded.load();
      expect(reloaded.devices.single.name, '');
    });
  });

  group('a paired fingerprint is never ignored (RF-84, C96)', () {
    test('refused and nothing changes: memory, changes, status or '
        'file', () async {
      final store = storeOn(ignoredFile);
      final changes = recordChanges(store);
      final status = recordSaveStatus(store);
      paired.add(_fp(1));

      final result = await store.ignore(_fp(1), name: 'PAIRED');
      await pumpEventQueue();

      expect(result, IgnoreResult.refused);
      expect(store.isIgnored(_fp(1)), isFalse);
      expect(store.devices, isEmpty);
      expect(changes, isEmpty);
      expect(status, isEmpty);
      expect(store.hasUnsavedChanges, isFalse);
      expect(await namesIn(dataDir), isEmpty);
    });

    test('refused with other ignored devices leaves the file as it '
        'was', () async {
      final store = await storeWith([2, 3]);
      final before = ignoredFile.readAsStringSync();
      final changes = recordChanges(store);
      paired.add(_fp(1));

      expect(await store.ignore(_fp(1), name: 'PAIRED'), IgnoreResult.refused);
      await pumpEventQueue();

      expect(_fingerprints(store.devices), {_fp(2), _fp(3)});
      expect(changes, isEmpty);
      expect(ignoredFile.readAsStringSync(), before);
    });

    test('isPaired is asked at the moment of each call', () async {
      final store = storeOn(ignoredFile);

      expect(await store.ignore(_fp(1), name: 'A'), IgnoreResult.ignored);
      paired.add(_fp(2));
      expect(await store.ignore(_fp(2), name: 'B'), IgnoreResult.refused);
      paired.remove(_fp(2));
      expect(await store.ignore(_fp(2), name: 'B'), IgnoreResult.ignored);

      expect(_fingerprints(store.devices), {_fp(1), _fp(2)});
    });

    test('a paired fingerprint is refused even with 256 ignored and nobody '
        'is pushed out', () async {
      await seed([
        for (var i = 0; i < 256; i++)
          entry(i, at: start.add(Duration(minutes: i))),
      ]);
      final store = storeOn(ignoredFile);
      await store.load();
      paired.add(_fp(999));

      expect(
        await store.ignore(_fp(999), name: 'PAIRED'),
        IgnoreResult.refused,
      );

      expect(store.devices, hasLength(256));
      expect(store.isIgnored(_fp(0)), isTrue);
    });
  });

  group('a fingerprint with a bad format is a programming error', () {
    final bad = <String, String>{
      'in lowercase': _fp(1).toLowerCase().replaceAll('0', 'a'),
      'of 63 characters': _fp(1).substring(1),
      'of 65 characters': '0${_fp(1)}',
      'empty': '',
      'with a G': 'G${_fp(1).substring(1)}',
      'with spaces around': ' ${_fp(1)} ',
      'with a line break at the end': '${_fp(1)}\n',
    };

    for (final MapEntry(key: label, value: fingerprint) in bad.entries) {
      test('$label: ArgumentError and nothing changes', () async {
        final asked = <String>[];
        final store = IgnoredDevicesStore(
          JsonFileStore(ignoredFile),
          isPaired: (fp) {
            asked.add(fp);
            return true;
          },
          now: () => current,
        );
        final changes = recordChanges(store);
        final status = recordSaveStatus(store);

        await expectLater(
          store.ignore(fingerprint, name: 'X'),
          throwsArgumentError,
        );
        await pumpEventQueue();

        expect(asked, isEmpty);
        expect(store.devices, isEmpty);
        expect(changes, isEmpty);
        expect(status, isEmpty);
        expect(await namesIn(dataDir), isEmpty);
      });
    }

    test('the fixtures of the bad fingerprints are really bad', () {
      final pattern = RegExp(r'^[0-9A-F]{64}$');
      expect(pattern.hasMatch(_fp(1)), isTrue);
      for (final fingerprint in bad.values) {
        expect(pattern.hasMatch(fingerprint), isFalse, reason: fingerprint);
      }
    });
  });

  group('ignore clips the name to 64 runes', () {
    final clipped = <String, (String, String)>{
      '65 runes with an emoji in the middle': (
        '${'a' * 30}$_smile${'b' * 34}',
        '${'a' * 30}$_smile${'b' * 33}',
      ),
      '65 runes ending in an emoji': ('${'é' * 64}$_smile', 'é' * 64),
      '64 emojis and a letter': ('${_smile * 64}z', _smile * 64),
      '65 emojis': (_smile * 65, _smile * 64),
      'exactly 64 runes, untouched': (
        '${'a' * 63}$_smile',
        '${'a' * 63}$_smile',
      ),
    };

    for (final MapEntry(key: label, value: (given, expected))
        in clipped.entries) {
      test('$label: in memory, in the file and after a reload', () async {
        final store = storeOn(ignoredFile);

        expect(await store.ignore(_fp(1), name: given), IgnoreResult.ignored);

        final name = store.devices.single.name;
        expect(name, expected);
        expect(name.runes.length, lessThanOrEqualTo(64));
        expect(utf8.decode(utf8.encode(name)), name);
        expect(entriesOf(ignoredFile).single['name'], expected);
        final reloaded = storeOn(ignoredFile);
        await reloaded.load();
        expect(reloaded.devices.single.name, expected);
        expect(await namesIn(dataDir), ['ignored.json']);
      });
    }
  });

  group('the limit of 256 (RF-110, C19)', () {
    Future<IgnoredDevicesStore> loadedWith(List<Map<String, Object?>> list) {
      return seed(list).then((_) async {
        final store = storeOn(ignoredFile);
        await store.load();
        expect(store.devices, hasLength(list.length));
        return store;
      });
    }

    test('257 ignored one after another: the oldest is forgotten', () async {
      final store = storeOn(ignoredFile);
      final results = <Future<IgnoreResult>>[];

      for (var i = 0; i < 257; i++) {
        current = start.add(Duration(minutes: i));
        results.add(store.ignore(_fp(i), name: 'PC-$i'));
        expect(store.devices.length, lessThanOrEqualTo(256));
      }
      final all = await Future.wait(results);

      expect(all, everyElement(IgnoreResult.ignored));
      expect(store.devices, hasLength(256));
      expect(store.isIgnored(_fp(0)), isFalse);
      expect(store.isIgnored(_fp(1)), isTrue);
      expect(store.isIgnored(_fp(256)), isTrue);
      expect(fingerprintsIn(ignoredFile), hasLength(256));
      expect(fingerprintsIn(ignoredFile), isNot(contains(_fp(0))));
      final reloaded = storeOn(ignoredFile);
      await reloaded.load();
      expect(_fingerprints(reloaded.devices), _fingerprints(store.devices));
    });

    test('the one with the oldest ignoredAt leaves, not the first in the '
        'list', () async {
      final store = await loadedWith([
        for (var i = 0; i < 256; i++)
          entry(i, at: start.add(Duration(minutes: i == 100 ? -60 : i))),
      ]);
      final changes = recordChanges(store);
      current = start.add(const Duration(days: 1));

      expect(await store.ignore(_fp(500), name: 'NEW'), IgnoreResult.ignored);
      await pumpEventQueue();

      expect(store.devices, hasLength(256));
      expect(store.isIgnored(_fp(100)), isFalse);
      expect(store.isIgnored(_fp(0)), isTrue);
      expect(store.isIgnored(_fp(500)), isTrue);
      expect(changes, hasLength(1));
      expect(fingerprintsIn(ignoredFile), isNot(contains(_fp(100))));
      expect(fingerprintsIn(ignoredFile), contains(_fp(500)));
    });

    test('ignoring the oldest again makes it the newest, and the next one '
        'leaves', () async {
      final store = await loadedWith([
        for (var i = 0; i < 256; i++)
          entry(i, at: start.add(Duration(minutes: i))),
      ]);
      current = start.add(const Duration(days: 1));
      expect(await store.ignore(_fp(0), name: 'PC-0'), IgnoreResult.ignored);
      expect(store.devices, hasLength(256));
      tick();

      expect(await store.ignore(_fp(500), name: 'NEW'), IgnoreResult.ignored);

      expect(store.devices, hasLength(256));
      expect(store.isIgnored(_fp(0)), isTrue);
      expect(store.isIgnored(_fp(1)), isFalse);
      expect(store.isIgnored(_fp(500)), isTrue);
    });

    test('ignoring again one of 256 pushes nobody out', () async {
      final store = await loadedWith([
        for (var i = 0; i < 256; i++)
          entry(i, at: start.add(Duration(minutes: i))),
      ]);
      current = start.add(const Duration(days: 1));

      expect(await store.ignore(_fp(200), name: 'X'), IgnoreResult.ignored);

      expect(store.devices, hasLength(256));
      for (var i = 0; i < 256; i++) {
        expect(store.isIgnored(_fp(i)), isTrue);
      }
    });

    test('with 255 the 256th enters and nobody leaves', () async {
      final store = await loadedWith([
        for (var i = 0; i < 255; i++)
          entry(i, at: start.add(Duration(minutes: i))),
      ]);
      current = start.add(const Duration(days: 1));

      expect(await store.ignore(_fp(500), name: 'X'), IgnoreResult.ignored);

      expect(store.devices, hasLength(256));
      expect(store.isIgnored(_fp(0)), isTrue);
      expect(entriesOf(ignoredFile), hasLength(256));
    });

    test('a tie on the oldest ignoredAt: the first of them in the list '
        'leaves', () async {
      final store = await loadedWith([
        for (var i = 0; i < 256; i++)
          entry(i, at: start.add(Duration(minutes: i == 7 || i == 9 ? -5 : i))),
      ]);
      current = start.add(const Duration(days: 1));

      expect(await store.ignore(_fp(500), name: 'X'), IgnoreResult.ignored);

      expect(store.isIgnored(_fp(7)), isFalse);
      expect(store.isIgnored(_fp(9)), isTrue);
    });
  });

  group('unignore (RF-109, RF-120, C19)', () {
    test('memory and changes at once, then saved; a restart keeps it '
        'unignored', () async {
      final store = await storeWith([1, 2]);
      var unignoreDone = false;
      final doneWhenNotified = <bool>[];
      final subscription = store.changes.listen(
        (_) => doneWhenNotified.add(unignoreDone),
      );
      addTearDown(subscription.cancel);

      final unignoring = store.unignore(_fp(1)).whenComplete(() {
        unignoreDone = true;
      });
      final ignoredRightAfterTheCall = store.isIgnored(_fp(1));
      final saved = await unignoring;
      await pumpEventQueue();

      expect(ignoredRightAfterTheCall, isFalse);
      expect(saved, isTrue);
      expect(doneWhenNotified, [false]);
      expect(_fingerprints(store.devices), {_fp(2)});
      expect(fingerprintsIn(ignoredFile), [_fp(2)]);
      expect(store.hasUnsavedChanges, isFalse);
      final reloaded = storeOn(ignoredFile);
      await reloaded.load();
      expect(reloaded.isIgnored(_fp(1)), isFalse);
      expect(reloaded.isIgnored(_fp(2)), isTrue);
    });

    test('a fingerprint that is not ignored gives true and does '
        'nothing', () async {
      final store = storeOn(ignoredFile);
      final changes = recordChanges(store);
      final status = recordSaveStatus(store);

      expect(await store.unignore(_fp(1)), isTrue);
      await pumpEventQueue();

      expect(changes, isEmpty);
      expect(status, isEmpty);
      expect(await namesIn(dataDir), isEmpty);
    });

    test('a fingerprint that is not ignored leaves the file as it '
        'was', () async {
      final store = await storeWith([1]);
      final before = ignoredFile.readAsStringSync();
      final changes = recordChanges(store);

      expect(await store.unignore(_fp(2)), isTrue);
      await pumpEventQueue();

      expect(changes, isEmpty);
      expect(ignoredFile.readAsStringSync(), before);
    });

    test('RF-120: without disk it is unignored for the session, returns '
        'false and the file still has it', () async {
      final store = await storeWith([1, 2]);
      final held = lock(ignoredFile);
      final status = recordSaveStatus(store);
      final changes = recordChanges(store);

      final saved = await store.unignore(_fp(1));
      await pumpEventQueue();
      held.release();

      expect(saved, isFalse);
      expect(store.isIgnored(_fp(1)), isFalse);
      expect(changes, [
        {_fp(2)},
      ]);
      expect(store.hasUnsavedChanges, isTrue);
      expect(status, [true]);
      expect(fingerprintsIn(ignoredFile), [_fp(1), _fp(2)]);
    });

    test('RF-120: retrySave once the disk works writes it', () async {
      final store = await storeWith([1, 2]);
      final held = lock(ignoredFile);
      final status = recordSaveStatus(store);
      expect(await store.unignore(_fp(1)), isFalse);
      held.release();

      expect(await store.retrySave(), isTrue);
      await pumpEventQueue();

      expect(fingerprintsIn(ignoredFile), [_fp(2)]);
      expect(store.hasUnsavedChanges, isFalse);
      expect(status, [true, false]);
      final reloaded = storeOn(ignoredFile);
      await reloaded.load();
      expect(reloaded.isIgnored(_fp(1)), isFalse);
    });

    test('it can be ignored again after unignoring it', () async {
      final store = await storeWith([1]);
      expect(await store.unignore(_fp(1)), isTrue);
      tick();

      expect(await store.ignore(_fp(1), name: 'PC-1'), IgnoreResult.ignored);

      expect(store.isIgnored(_fp(1)), isTrue);
      expect(fingerprintsIn(ignoredFile), [_fp(1)]);
    });
  });

  group('ignore without disk (RF-121, C19)', () {
    test('locked file: notSaved, ignored for the session, the file keeps '
        'its content', () async {
      final store = await storeWith([2]);
      final before = ignoredFile.readAsStringSync();
      final held = lock(ignoredFile);
      final changes = recordChanges(store);
      final status = recordSaveStatus(store);

      final ignoring = store.ignore(_fp(1), name: 'PC-RARO');
      final ignoredRightAfterTheCall = store.isIgnored(_fp(1));
      final result = await ignoring;
      await pumpEventQueue();
      held.release();

      expect(ignoredRightAfterTheCall, isTrue);
      expect(result, IgnoreResult.notSaved);
      expect(store.isIgnored(_fp(1)), isTrue);
      expect(changes, [
        {_fp(1), _fp(2)},
      ]);
      expect(store.hasUnsavedChanges, isTrue);
      expect(status, [true]);
      expect(ignoredFile.readAsStringSync(), before);
      expect(await namesIn(dataDir), ['ignored.json']);
    });

    test('impossible path: notSaved and ignored for the session', () async {
      final folder = Directory('${dataDir.path}${sep}data');
      final file = File('${folder.path}${sep}ignored.json');
      final store = storeOn(file);
      expect(await store.ignore(_fp(2), name: 'B'), IgnoreResult.ignored);
      await blockFolder(folder);
      final status = recordSaveStatus(store);

      expect(await store.ignore(_fp(1), name: 'A'), IgnoreResult.notSaved);
      await pumpEventQueue();

      expect(store.isIgnored(_fp(1)), isTrue);
      expect(store.isIgnored(_fp(2)), isTrue);
      expect(store.hasUnsavedChanges, isTrue);
      expect(status, [true]);

      await File(folder.path).delete();
      expect(await store.retrySave(), isTrue);
      expect(fingerprintsIn(file), [_fp(2), _fp(1)]);
      expect(store.hasUnsavedChanges, isFalse);
    });

    test('it is not remembered: after a restart it is not ignored', () async {
      final store = await storeWith([2]);
      final held = lock(ignoredFile);
      expect(await store.ignore(_fp(1), name: 'A'), IgnoreResult.notSaved);
      held.release();

      final reloaded = storeOn(ignoredFile);
      await reloaded.load();

      expect(store.isIgnored(_fp(1)), isTrue);
      expect(reloaded.isIgnored(_fp(1)), isFalse);
      expect(reloaded.isIgnored(_fp(2)), isTrue);
    });

    test('retrySave once the disk works saves it', () async {
      final store = await storeWith([2]);
      final held = lock(ignoredFile);
      final status = recordSaveStatus(store);
      expect(await store.ignore(_fp(1), name: 'A'), IgnoreResult.notSaved);
      held.release();

      expect(await store.retrySave(), isTrue);
      await pumpEventQueue();

      expect(fingerprintsIn(ignoredFile), [_fp(2), _fp(1)]);
      expect(store.hasUnsavedChanges, isFalse);
      expect(status, [true, false]);
      final reloaded = storeOn(ignoredFile);
      await reloaded.load();
      expect(reloaded.isIgnored(_fp(1)), isTrue);
    });

    test('the next write that works also saves the one that failed', () async {
      final store = storeOn(ignoredFile);
      await ignoredFile.writeAsString('{"version":1,"devices":[]}');
      final held = lock(ignoredFile);
      final status = recordSaveStatus(store);
      expect(await store.ignore(_fp(1), name: 'A'), IgnoreResult.notSaved);
      held.release();
      tick();

      expect(await store.ignore(_fp(2), name: 'B'), IgnoreResult.ignored);
      await pumpEventQueue();

      expect(fingerprintsIn(ignoredFile), [_fp(1), _fp(2)]);
      expect(store.hasUnsavedChanges, isFalse);
      expect(status, [true, false]);
    });
  });

  group('hasUnsavedChanges and saveStatusChanges', () {
    test('false at the start', () {
      expect(storeOn(ignoredFile).hasUnsavedChanges, isFalse);
    });

    test('retrySave with nothing pending writes the memory', () async {
      final store = await storeWith([1]);
      await ignoredFile.delete();

      expect(await store.retrySave(), isTrue);

      expect(fingerprintsIn(ignoredFile), [_fp(1)]);
      expect(store.hasUnsavedChanges, isFalse);
    });

    test('emits only when the value changes', () async {
      final store = await storeWith([1, 2]);
      final status = recordSaveStatus(store);
      final held = lock(ignoredFile);

      expect(await store.retrySave(), isFalse);
      expect(await store.unignore(_fp(1)), isFalse);
      held.release();
      expect(await store.retrySave(), isTrue);
      tick();
      expect(await store.ignore(_fp(3), name: 'C'), IgnoreResult.ignored);
      await pumpEventQueue();

      expect(status, [true, false]);
    });

    test('both streams are broadcast', () async {
      final store = await storeWith([1]);
      final first = recordSaveStatus(store);
      final second = recordSaveStatus(store);
      final changesOne = recordChanges(store);
      final changesTwo = recordChanges(store);
      final held = lock(ignoredFile);

      await store.unignore(_fp(1));
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

  group('the queue writes the memory of its turn', () {
    test('ignore A, ignore B and unignore A without waiting', () async {
      final store = storeOn(ignoredFile);
      final changes = recordChanges(store);
      final snapshots = <Set<String>>[];

      final ignoreA = store.ignore(_fp(1), name: 'A');
      snapshots.add(_fingerprints(store.devices));
      final ignoreB = store.ignore(_fp(2), name: 'B');
      snapshots.add(_fingerprints(store.devices));
      final unignoreA = store.unignore(_fp(1));
      snapshots.add(_fingerprints(store.devices));
      final results = await Future.wait<Object>([ignoreA, ignoreB, unignoreA]);
      await pumpEventQueue();

      expect(results, [IgnoreResult.ignored, IgnoreResult.ignored, true]);
      expect(snapshots, [
        {_fp(1)},
        {_fp(1), _fp(2)},
        {_fp(2)},
      ]);
      expect(changes, hasLength(3));
      expect(_fingerprints(store.devices), {_fp(2)});
      expect(fingerprintsIn(ignoredFile), [_fp(2)]);
      final reloaded = storeOn(ignoredFile);
      await reloaded.load();
      expect(_fingerprints(reloaded.devices), {_fp(2)});
    });

    test('a queued retrySave writes what memory has when its turn '
        'comes', () async {
      final store = await storeWith([1]);

      final ignoring = store.ignore(_fp(2), name: 'B');
      final retrying = store.retrySave();
      final unignoring = store.unignore(_fp(1));

      expect(await ignoring, IgnoreResult.ignored);
      final writtenByTheIgnore = fingerprintsIn(ignoredFile);
      expect(await retrying, isTrue);
      expect(await unignoring, isTrue);

      expect(writtenByTheIgnore, [_fp(2)]);
      expect(fingerprintsIn(ignoredFile), [_fp(2)]);
    });

    test('twenty ignores and ten unignores interleaved', () async {
      final store = storeOn(ignoredFile);
      final calls = <Future<Object>>[];

      for (var i = 0; i < 20; i++) {
        tick();
        calls.add(store.ignore(_fp(i), name: 'PC-$i'));
        if (i.isEven) calls.add(store.unignore(_fp(i)));
      }
      final results = await Future.wait(calls);

      expect(
        results.whereType<IgnoreResult>(),
        everyElement(IgnoreResult.ignored),
      );
      expect(results.whereType<bool>(), everyElement(isTrue));
      final odd = {for (var i = 1; i < 20; i += 2) _fp(i)};
      expect(_fingerprints(store.devices), odd);
      expect(fingerprintsIn(ignoredFile).toSet(), odd);
      final reloaded = storeOn(ignoredFile);
      await reloaded.load();
      expect(_fingerprints(reloaded.devices), odd);
    });
  });

  group('load (C19)', () {
    test('without a file: empty and creates nothing', () async {
      final store = storeOn(ignoredFile);

      await store.load();

      expect(store.devices, isEmpty);
      expect(await namesIn(dataDir), isEmpty);
    });

    test('a valid file is loaded in its order with its fields', () async {
      await seed([
        entry(3, name: 'C', at: start.add(const Duration(hours: 3))),
        entry(1, name: 'A', at: start.add(const Duration(hours: 1))),
        entry(2, name: '', at: start),
      ]);
      final store = storeOn(ignoredFile);
      final changes = recordChanges(store);

      await store.load();
      await pumpEventQueue();

      expect(store.devices.map((d) => d.fingerprint), [_fp(3), _fp(1), _fp(2)]);
      expect(store.devices.map((d) => d.name), ['C', 'A', '']);
      expect(
        store.devices.first.ignoredAt,
        _sameMoment(start.add(const Duration(hours: 3))),
      );
      expect(await namesIn(dataDir), ['ignored.json']);
      expect(changes, isEmpty);
    });

    test('a name of 64 runes is loaded', () async {
      await seed([entry(1, name: _smile * 64)]);
      final store = storeOn(ignoredFile);

      await store.load();

      expect(store.devices.single.name, _smile * 64);
    });

    test('an ignoredAt with an offset is read as the same moment', () async {
      await seed([
        {
          'fingerprint': _fp(1),
          'name': 'A',
          'ignoredAt': '2026-10-23T20:04:05.000+02:00',
        },
      ]);
      final store = storeOn(ignoredFile);

      await store.load();

      expect(store.devices.single.ignoredAt, _sameMoment(start));
    });

    test('an empty list is loaded', () async {
      await seed([]);
      final store = storeOn(ignoredFile);

      await store.load();

      expect(store.devices, isEmpty);
      expect(await namesIn(dataDir), ['ignored.json']);
    });

    test('a later load replaces what was in memory', () async {
      final store = await storeWith([1]);
      await seed([entry(2)]);

      await store.load();

      expect(_fingerprints(store.devices), {_fp(2)});
    });

    test('a paired.json next to it is not touched', () async {
      final pairedFile = File('${dataDir.path}${sep}paired.json');
      await pairedFile.writeAsString('not json at all');
      await ignoredFile.writeAsString('not json either');

      await storeOn(ignoredFile).load();

      expect(await namesIn(dataDir), [
        'ignored.json.broken-$stamp',
        'paired.json',
      ]);
      expect(pairedFile.readAsStringSync(), 'not json at all');
    });
  });

  group('a bad ignored.json goes to quarantine (C19)', () {
    final good = entry(1);
    final cases = <String, String Function()>{
      'version 2': () => jsonEncode({
        'version': 2,
        'devices': [good],
      }),
      'no version': () => jsonEncode({
        'devices': [good],
      }),
      'version "1" as text': () => jsonEncode({
        'version': '1',
        'devices': [good],
      }),
      'version 1.0': () => '{"version": 1.0, "devices": []}',
      'version 0': () => jsonEncode({
        'version': 0,
        'devices': [good],
      }),
      'broken JSON': () => '{"version": 1, "devices": [',
      'not JSON at all': () => 'hello',
      'an empty file': () => '',
      'a JSON list instead of an object': () => jsonEncode([good]),
      'devices missing': () => jsonEncode({'version': 1}),
      'devices that is not a list': () =>
          jsonEncode({'version': 1, 'devices': good}),
      'an entry that is not an object': () => jsonEncode({
        'version': 1,
        'devices': [good, 'PC-2'],
      }),
      'an entry without name': () => jsonEncode({
        'version': 1,
        'devices': [
          {...good}..remove('name'),
        ],
      }),
      'an entry without ignoredAt': () => jsonEncode({
        'version': 1,
        'devices': [
          {...good}..remove('ignoredAt'),
        ],
      }),
      'an entry without fingerprint': () => jsonEncode({
        'version': 1,
        'devices': [
          {...good}..remove('fingerprint'),
        ],
      }),
      'a fingerprint in lowercase': () => jsonEncode({
        'version': 1,
        'devices': [
          {...good, 'fingerprint': _fp(0xAB).toLowerCase()},
        ],
      }),
      'a fingerprint of 63 characters': () => jsonEncode({
        'version': 1,
        'devices': [
          {...good, 'fingerprint': _fp(1).substring(1)},
        ],
      }),
      'a fingerprint that is a number': () => jsonEncode({
        'version': 1,
        'devices': [
          {...good, 'fingerprint': 1},
        ],
      }),
      'a name of 65 runes': () => jsonEncode({
        'version': 1,
        'devices': [
          {...good, 'name': '${_smile * 64}z'},
        ],
      }),
      'a name that is not text': () => jsonEncode({
        'version': 1,
        'devices': [
          {...good, 'name': 7},
        ],
      }),
      'an ignoredAt that is not a date': () => jsonEncode({
        'version': 1,
        'devices': [
          {...good, 'ignoredAt': 'yesterday'},
        ],
      }),
      'an ignoredAt that is a number': () => jsonEncode({
        'version': 1,
        'devices': [
          {...good, 'ignoredAt': 1761242645000},
        ],
      }),
      'the same fingerprint twice': () => jsonEncode({
        'version': 1,
        'devices': [
          entry(1, name: 'A'),
          entry(2),
          entry(1, name: 'B', at: start.add(const Duration(hours: 1))),
        ],
      }),
    };

    for (final MapEntry(key: label, value: build) in cases.entries) {
      test('$label: quarantined as broken and empty', () async {
        final content = build();
        await ignoredFile.writeAsString(content);
        final store = storeOn(ignoredFile);
        final changes = recordChanges(store);
        final status = recordSaveStatus(store);

        await store.load();
        await pumpEventQueue();

        expect(store.devices, isEmpty);
        expect(store.isIgnored(_fp(1)), isFalse);
        expect(await namesIn(dataDir), ['ignored.json.broken-$stamp']);
        expect(
          File('${dataDir.path}${sep}ignored.json.broken-$stamp')
              .readAsStringSync(),
          content,
        );
        expect(changes, isEmpty);
        expect(status, isEmpty);
      });
    }

    test('a bad file empties a list that was already loaded', () async {
      final store = await storeWith([1, 2]);
      await ignoredFile.writeAsString('{"version": 2, "devices": []}');

      await store.load();

      expect(store.devices, isEmpty);
      expect(store.isIgnored(_fp(1)), isFalse);
    });

    test('after a quarantine the next ignore writes a new version 1 file and '
        'the broken copy stays', () async {
      await ignoredFile.writeAsString('{"version": 1, "devices": [');
      final store = storeOn(ignoredFile);
      await store.load();

      expect(await store.ignore(_fp(1), name: 'A'), IgnoreResult.ignored);

      expect(rawOf(ignoredFile)['version'], 1);
      expect(fingerprintsIn(ignoredFile), [_fp(1)]);
      expect(
        File('${dataDir.path}${sep}ignored.json.broken-$stamp')
            .readAsStringSync(),
        '{"version": 1, "devices": [',
      );
    });

    test('a second quarantine in the same second gets -2', () async {
      await ignoredFile.writeAsString('broken one');
      await storeOn(ignoredFile).load();
      await ignoredFile.writeAsString('broken two');

      await storeOn(ignoredFile).load();

      expect(await namesIn(dataDir), [
        'ignored.json.broken-$stamp',
        'ignored.json.broken-$stamp-2',
      ]);
      expect(
        File('${dataDir.path}${sep}ignored.json.broken-$stamp-2')
            .readAsStringSync(),
        'broken two',
      );
    });
  });

  group('a file with more than 256 (RF-110, C19)', () {
    test('keeps the 256 most recent in the order of the file', () async {
      final minutes = [for (var i = 0; i < 300; i++) (i * 7919) % 300];
      await seed([
        for (var i = 0; i < 300; i++)
          entry(i, at: start.add(Duration(minutes: minutes[i]))),
      ]);
      final store = storeOn(ignoredFile);

      await store.load();

      final kept = [
        for (var i = 0; i < 300; i++)
          if (minutes[i] >= 300 - 256) _fp(i),
      ];
      expect(minutes.toSet(), hasLength(300));
      expect(kept, hasLength(256));
      expect(store.devices.map((d) => d.fingerprint), kept);
      expect(await namesIn(dataDir), ['ignored.json']);
    });

    test('257 with the same ignoredAt: the first in the file is the one '
        'left out', () async {
      await seed([for (var i = 0; i < 257; i++) entry(i)]);
      final store = storeOn(ignoredFile);

      await store.load();

      expect(store.devices, hasLength(256));
      expect(store.isIgnored(_fp(0)), isFalse);
      expect(store.devices.first.fingerprint, _fp(1));
      expect(store.devices.last.fingerprint, _fp(256));
    });

    test('a newer one at the start of the file stays and the oldest at the '
        'end leaves', () async {
      await seed([
        entry(0, at: start.add(const Duration(days: 1))),
        for (var i = 1; i < 256; i++)
          entry(i, at: start.add(Duration(minutes: i))),
        entry(256, at: start.subtract(const Duration(days: 1))),
      ]);
      final store = storeOn(ignoredFile);

      await store.load();

      expect(store.devices, hasLength(256));
      expect(store.isIgnored(_fp(0)), isTrue);
      expect(store.isIgnored(_fp(256)), isFalse);
    });

    test('after loading more than 256, a new ignore still keeps 256', () async {
      await seed([
        for (var i = 0; i < 260; i++)
          entry(i, at: start.add(Duration(minutes: i))),
      ]);
      final store = storeOn(ignoredFile);
      await store.load();
      current = start.add(const Duration(days: 1));

      expect(await store.ignore(_fp(999), name: 'X'), IgnoreResult.ignored);

      expect(store.devices, hasLength(256));
      expect(store.isIgnored(_fp(4)), isFalse);
      expect(store.isIgnored(_fp(5)), isTrue);
      expect(store.isIgnored(_fp(999)), isTrue);
      expect(entriesOf(ignoredFile), hasLength(256));
    });
  });
}
