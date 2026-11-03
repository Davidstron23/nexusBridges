import 'dart:convert';
import 'dart:io';

import 'package:nexus_bridges_core/src/browse/browse.dart';
import 'package:nexus_bridges_core/src/storage/storage.dart';
import 'package:test/test.dart';

final String owner = 'A' * 64;
final String peerB = 'B' * 64;
final String peerC = 'C' * 64;
final DateTime when = DateTime.utc(2026, 11, 3, 10);

String hexId(int n) => n.toRadixString(16).padLeft(32, '0');

Map<String, Object?> rootJson(
  int n, {
  String? path,
  String volume = 'NTFS-2692abcd',
  String label = 'docs',
  bool home = false,
  String drive = 'fixed',
  String addedAt = '2026-11-01T10:00:00.000Z',
}) => {
  'id': hexId(n),
  'path': path ?? 'C:\\datos\\r$n',
  'volume': volume,
  'label': label,
  'home': home,
  'drive': drive,
  'addedAt': addedAt,
};

Map<String, Object?> fileJson(
  List<Map<String, Object?>> peers, {
  Object? ownerValue,
}) => {'version': 1, 'owner': ownerValue ?? owner, 'peers': peers};

Map<String, Object?> peerJson(String fp, List<Map<String, Object?>> roots) => {
  'fingerprint': fp,
  'roots': roots,
};

Future<Directory> tempDir() async {
  final dir = await Directory.systemTemp.createTemp('nexus_t007_shares_');
  addTearDown(() async {
    if (dir.existsSync()) await dir.delete(recursive: true);
  });
  return dir;
}

final class Place {
  Place(this.dir);

  final Directory dir;

  File get file => File('${dir.path}\\shares.json');

  SharesStore store() => SharesStore(
    JsonFileStore(file),
    ownerFingerprint: owner,
    now: () => when,
  );

  void writeRaw(String text) => file.writeAsStringSync(text);

  void writeJson(Object? json) => writeRaw(jsonEncode(json));

  List<String> quarantined() => [
    for (final entity in dir.listSync())
      if (entity.path.contains('shares.json.')) entity.uri.pathSegments.last,
  ];

  Future<(SharesLoadResult, Map<String, List<ShareRecord>>)> load({
    Set<String>? paired,
  }) => store().load(isPaired: (fp) => (paired ?? {peerB, peerC}).contains(fp));
}

Future<Place> place() async => Place(await tempDir());

void main() {
  group('G12 shares.json (RF-407) [SEG]', () {
    test('G12 a missing file loads empty', () async {
      final p = await place();
      final (result, shares) = await p.load();
      expect(result, SharesLoadResult.missing);
      expect(shares, isEmpty);
    });

    test('G12 a valid file is read and written back the same', () async {
      final p = await place();
      p.writeJson(
        fileJson([
          peerJson(peerB, [
            rootJson(1),
            rootJson(2, label: '', home: true, path: r'C:\Users\Bob'),
            rootJson(3, label: 'D:', path: r'D:\', drive: 'removable'),
          ]),
        ]),
      );
      final (result, shares) = await p.load();
      expect(result, SharesLoadResult.loaded);
      final roots = shares[peerB]!;
      expect(roots.map((r) => r.id), [hexId(1), hexId(2), hexId(3)]);
      expect(roots[1].home, isTrue);
      expect(roots[1].label, '');
      expect(roots[2].drive, DriveKind.removable);
      expect(roots[0].addedAt, DateTime.utc(2026, 11, 1, 10));
      expect(await p.store().write(shares), isTrue);
      final again = await p.load();
      expect(again.$1, SharesLoadResult.loaded);
      expect(again.$2[peerB]!.map((r) => r.toJson()).toList(), [
        for (final r in roots) r.toJson(),
      ]);
      final written = jsonDecode(p.file.readAsStringSync()) as Map;
      expect(written.keys.toSet(), {'version', 'owner', 'peers'});
      expect(written['owner'], owner);
    });

    test('G12 broken JSON and another version are quarantined and load '
        'empty', () async {
      for (final text in [
        '{"version": 1, "owner": ',
        jsonEncode({...fileJson([]), 'version': 2}),
        '[]',
      ]) {
        final p = await place();
        p.writeRaw(text);
        final (result, shares) = await p.load();
        expect(result, SharesLoadResult.quarantined, reason: text);
        expect(shares, isEmpty);
        expect(p.file.existsSync(), isFalse);
        expect(p.quarantined().single, startsWith('shares.json.broken-'));
      }
    });

    test('G12 another identity is set apart as previous-identity', () async {
      final p = await place();
      p.writeJson(
        fileJson([
          peerJson(peerB, [rootJson(1)]),
        ], ownerValue: 'D' * 64),
      );
      final (result, shares) = await p.load();
      expect(result, SharesLoadResult.previousIdentity);
      expect(shares, isEmpty);
      expect(
        p.quarantined().single,
        startsWith('shares.json.previous-identity-'),
      );
    });

    test('G12 every structural fault quarantines the whole file', () async {
      final faults = <String, Object?>{
        'owner missing': {'version': 1, 'peers': <Object?>[]},
        'owner lowercase': fileJson([], ownerValue: 'a' * 64),
        'top extra key': {...fileJson([]), 'extra': 1},
        'peers not a list': {...fileJson([]), 'peers': 'x'},
        'peer extra key': fileJson([
          {
            ...peerJson(peerB, [rootJson(1)]),
            'name': 'x',
          },
        ]),
        'peer bad fingerprint': fileJson([
          peerJson('b' * 64, [rootJson(1)]),
        ]),
        'peer repeated': fileJson([
          peerJson(peerB, [rootJson(1)]),
          peerJson(peerB, [rootJson(2)]),
        ]),
        '33 peers': fileJson([
          for (var i = 0; i < 33; i++)
            peerJson(i.toRadixString(16).toUpperCase().padLeft(64, '0'), [
              rootJson(i),
            ]),
        ]),
        'no roots': fileJson([peerJson(peerB, [])]),
        '17 roots': fileJson([
          peerJson(peerB, [for (var i = 0; i < 17; i++) rootJson(i)]),
        ]),
        'root extra key': fileJson([
          peerJson(peerB, [
            {...rootJson(1), 'absolutePath': r'C:\'},
          ]),
        ]),
        'root key missing': fileJson([
          peerJson(peerB, [
            {...rootJson(1)}..remove('home'),
          ]),
        ]),
        'id uppercase': fileJson([
          peerJson(peerB, [
            {...rootJson(1), 'id': 'ABCDEF0123456789ABCDEF0123456789'},
          ]),
        ]),
        'id repeated across peers': fileJson([
          peerJson(peerB, [rootJson(1)]),
          peerJson(peerC, [rootJson(1, path: r'C:\otra')]),
        ]),
        'relative path': fileJson([
          peerJson(peerB, [rootJson(1, path: r'datos\docs')]),
        ]),
        'UNC path': fileJson([
          peerJson(peerB, [rootJson(1, path: r'\\host\share\docs')]),
        ]),
        'device path': fileJson([
          peerJson(peerB, [rootJson(1, path: r'\\?\C:\docs')]),
        ]),
        'drive-relative path': fileJson([
          peerJson(peerB, [rootJson(1, path: 'C:docs')]),
        ]),
        'wildcard in path': fileJson([
          peerJson(peerB, [rootJson(1, path: r'C:\do*cs')]),
        ]),
        'control in path': fileJson([
          peerJson(peerB, [rootJson(1, path: 'C:\\do\u{1}cs')]),
        ]),
        'path of 237': fileJson([
          peerJson(peerB, [rootJson(1, path: 'C:\\${'a' * 234}')]),
        ]),
        'same path twice': fileJson([
          peerJson(peerB, [
            rootJson(1, path: r'C:\Docs'),
            rootJson(2, path: r'c:\docs\'),
          ]),
        ]),
        'bad volume': fileJson([
          peerJson(peerB, [rootJson(1, volume: 'NTFS 2692abcd')]),
        ]),
        'home with a label': fileJson([
          peerJson(peerB, [rootJson(1, home: true, label: 'Bob')]),
        ]),
        'empty label without home': fileJson([
          peerJson(peerB, [rootJson(1, label: '')]),
        ]),
        'invalid label': fileJson([
          peerJson(peerB, [rootJson(1, label: 'a\u{202E}b')]),
        ]),
        'home not a bool': fileJson([
          peerJson(peerB, [
            {...rootJson(1), 'home': 'false'},
          ]),
        ]),
        'network drive': fileJson([
          peerJson(peerB, [rootJson(1, drive: 'remote')]),
        ]),
        'bad date': fileJson([
          peerJson(peerB, [rootJson(1, addedAt: 'ayer')]),
        ]),
      };
      for (final MapEntry(key: name, value: json) in faults.entries) {
        final p = await place();
        p.writeJson(json);
        final (result, shares) = await p.load();
        expect(result, SharesLoadResult.quarantined, reason: name);
        expect(shares, isEmpty, reason: name);
        expect(p.file.existsSync(), isFalse, reason: name);
        expect(p.quarantined(), hasLength(1), reason: name);
      }
    });

    test('G12 a path of exactly 236 units is accepted', () async {
      final p = await place();
      p.writeJson(
        fileJson([
          peerJson(peerB, [rootJson(1, path: 'C:\\${'a' * 233}')]),
        ]),
      );
      final (result, shares) = await p.load();
      expect(result, SharesLoadResult.loaded);
      expect(shares[peerB]!.single.path.length, 236);
    });

    test('G12 roots of unpaired peers are dropped, the original set apart '
        'and the rest rewritten (partlyDropped)', () async {
      final p = await place();
      p.writeJson(
        fileJson([
          peerJson(peerB, [rootJson(1)]),
          peerJson(peerC, [rootJson(2)]),
        ]),
      );
      final (result, shares) = await p.load(paired: {peerB});
      expect(result, SharesLoadResult.partlyDropped);
      expect(shares.keys, [peerB]);
      expect(p.quarantined().single, startsWith('shares.json.unpaired-'));
      final rewritten = jsonDecode(p.file.readAsStringSync()) as Map;
      final peers = rewritten['peers'] as List;
      expect(peers, hasLength(1));
      expect((peers.single as Map)['fingerprint'], peerB);
      final again = await p.load(paired: {peerB});
      expect(again.$1, SharesLoadResult.loaded);
    });

    test('G12 a write failure answers false and never throws', () async {
      final p = await place();
      Directory(p.file.path).createSync();
      expect(await p.store().write({peerB: const []}), isFalse);
    });
  });
}
