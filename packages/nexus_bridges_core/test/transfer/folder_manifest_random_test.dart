import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:nexus_bridges_core/src/protocol/protocol.dart';
import 'package:nexus_bridges_core/src/transfer/manifest.dart';
import 'package:nexus_bridges_core/src/transfer/messages.dart';
import 'package:nexus_bridges_core/src/transfer/names.dart';
import 'package:test/test.dart';

import 'folder_manifest_support.dart';

const int iterations = 10000;
const int seed = 20261030;

const List<String> namePool = [
  'a',
  'b',
  'src',
  'Doc',
  'docs',
  'x y',
  'a.txt',
  'B.TXT',
  'z',
  'readme.md',
  'é',
  'データ',
  '..',
  'CON',
  'desktop.ini',
  'x.lnk',
  'a:b',
  '.nexusbridges-incoming',
  '~nexusbridges-1',
];

final RegExp hashPattern = RegExp(r'^[0-9a-f]{64}$');

bool referenceAccepts(Uint8List data, FolderOfferRequest declared) {
  if (data.length != declared.manifestBytes) return false;
  if (data.isEmpty) {
    return declared.entries == 0 &&
        declared.files == 0 &&
        declared.bytes == 0 &&
        declared.depth == 0 &&
        declared.longest == 0;
  }
  if (data.last != 10) return false;
  final lines = <Uint8List>[];
  var start = 0;
  for (var i = 0; i < data.length; i++) {
    if (data[i] == 10) {
      lines.add(Uint8List.sublistView(data, start, i));
      start = i + 1;
    }
  }
  if (lines.length != declared.entries) return false;
  if (lines.length > Limits.maxFolderEntries) return false;

  final isFolder = <bool>[true];
  final paths = <String>[''];
  final depths = <int>[0];
  final seen = <(int, String)>{};
  var files = 0;
  var bytes = 0;
  var deepest = 0;
  var longest = 0;

  for (var n = 0; n < lines.length; n++) {
    final raw = lines[n];
    final index = n + 1;
    if (raw.length + 1 > Limits.maxManifestLineBytes) return false;
    if (raw.isEmpty || raw.contains(13)) return false;
    if (raw.length >= 3 && raw[0] == 0xEF && raw[1] == 0xBB && raw[2] == 0xBF) {
      return false;
    }
    final Object? value;
    try {
      value = jsonDecode(utf8.decode(raw));
    } on FormatException {
      return false;
    }
    if (value is! List) return false;
    if (value.length != 2 && value.length != 4) return false;
    final parent = value[0];
    final name = value[1];
    if (parent is! int || name is! String) return false;
    if (parent < 0 || parent >= index) return false;
    if (!isFolder[parent]) return false;
    if (!isValidFileName(name)) return false;
    if (isAppReservedName(name)) return false;
    if (isBlockedType(name)) return false;
    final file = value.length == 4;
    if (file) {
      final size = value[2];
      final sha = value[3];
      if (size is! int || size < 0 || size > Limits.maxTransferSize) {
        return false;
      }
      if (sha is! String || !hashPattern.hasMatch(sha)) return false;
      if (bytes + size > Limits.maxTransferSize) return false;
      bytes += size;
      files++;
    }
    final depth = depths[parent] + 1;
    if (depth > Limits.maxFolderDepth) return false;
    if (!seen.add((parent, name.toUpperCase()))) return false;
    final path = parent == 0 ? name : '${paths[parent]}\\$name';
    isFolder.add(!file);
    paths.add(path);
    depths.add(depth);
    if (depth > deepest) deepest = depth;
    final reach = file
        ? path.length
        : path.length + Limits.folderDirPathReserve;
    if (reach > longest) longest = reach;
  }
  return files == declared.files &&
      bytes == declared.bytes &&
      deepest == declared.depth &&
      longest == declared.longest;
}

({Uint8List bytes, FolderOfferRequest declared}) randomValid(Random random) {
  final builder = ManifestBuilder();
  final folders = <int>[0];
  final used = <String>{};
  final count = random.nextInt(14);
  for (var i = 0; i < count; i++) {
    final parent = folders[random.nextInt(folders.length)];
    final name = namePool[random.nextInt(namePool.length)];
    if (!isValidFileName(name) ||
        isAppReservedName(name) ||
        isBlockedType(name)) {
      continue;
    }
    if (!used.add('$parent:${name.toUpperCase()}')) continue;
    if (random.nextInt(3) == 0 || parent != 0 && folders.length > 8) {
      final size = random.nextInt(2000);
      final file = builder.addFile(parent, name, size);
      builder.setFile(
        file,
        size,
        Uint8List.fromList(List.generate(32, (_) => random.nextInt(256))),
      );
    } else {
      folders.add(builder.addFolder(parent, name));
    }
  }
  final manifest = builder.build();
  final encoded = encodeManifest(manifest);
  return (bytes: encoded, declared: declareFor(manifest, encoded));
}

Uint8List mutate(Uint8List original, Random random) {
  final data = List<int>.of(original);
  final rounds = 1 + random.nextInt(3);
  for (var r = 0; r < rounds; r++) {
    if (data.isEmpty) {
      data.add(random.nextInt(256));
      continue;
    }
    switch (random.nextInt(8)) {
      case 0:
        data[random.nextInt(data.length)] = random.nextInt(256);
      case 1:
        data.removeAt(random.nextInt(data.length));
      case 2:
        data.insert(random.nextInt(data.length + 1), random.nextInt(256));
      case 3:
        data.length = random.nextInt(data.length + 1);
      case 4:
        data.insert(random.nextInt(data.length + 1), 10);
      case 5:
        final position = random.nextInt(data.length);
        data[position] = 0x30 + random.nextInt(10);
      case 6:
        final lines = utf8.decode(data, allowMalformed: true).split('\n');
        if (lines.length > 1) {
          final from = random.nextInt(lines.length);
          final to = random.nextInt(lines.length);
          final moved = lines[from];
          lines[from] = lines[to];
          lines[to] = moved;
          data
            ..clear()
            ..addAll(utf8.encode(lines.join('\n')));
        }
      case 7:
        final lines = utf8.decode(data, allowMalformed: true).split('\n');
        final pick = random.nextInt(lines.length);
        lines.insert(random.nextInt(lines.length + 1), lines[pick]);
        data
          ..clear()
          ..addAll(utf8.encode(lines.join('\n')));
    }
  }
  return Uint8List.fromList(data);
}

Object? randomJsonValue(Random random) {
  switch (random.nextInt(10)) {
    case 0:
      return random.nextInt(8) - 2;
    case 1:
      return random.nextInt(4);
    case 2:
      return namePool[random.nextInt(namePool.length)];
    case 3:
      return random.nextDouble();
    case 4:
      return null;
    case 5:
      return random.nextBool();
    case 6:
      return 'a' * random.nextInt(300);
    case 7:
      return List.generate(
        32,
        (_) => random.nextInt(16).toRadixString(16),
      ).join();
    case 8:
      return [random.nextInt(3)];
    default:
      return random.nextInt(100000);
  }
}

Uint8List randomLists(Random random) {
  final buffer = StringBuffer();
  final lines = random.nextInt(8);
  for (var i = 0; i < lines; i++) {
    final shape = random.nextInt(6);
    if (shape == 0) {
      buffer.write(jsonEncode(randomJsonValue(random)));
    } else {
      final parent = random.nextInt(i + 1);
      final name = namePool[random.nextInt(namePool.length)];
      final items = <Object?>[parent, name];
      if (shape >= 4) {
        items
          ..add(random.nextInt(5000))
          ..add(
            List.generate(
              64,
              (_) => random.nextInt(16).toRadixString(16),
            ).join(),
          );
      }
      if (shape == 1) {
        items[random.nextInt(items.length)] = randomJsonValue(random);
      }
      buffer.write(jsonEncode(items));
    }
    buffer.write('\n');
  }
  return Uint8List.fromList(utf8.encode(buffer.toString()));
}

Uint8List randomBytes(Random random) {
  final alphabet = '[],"0123456789abcdef \n\r\\{}:.'.codeUnits;
  final length = random.nextInt(200);
  return Uint8List.fromList([
    for (var i = 0; i < length; i++)
      random.nextInt(4) == 0
          ? random.nextInt(256)
          : alphabet[random.nextInt(alphabet.length)],
  ]);
}

List<int> chunkSizes(Random random) => [
  for (var i = 0; i < 64; i++) 1 + random.nextInt(40),
];

void main() {
  group('E431, RF-264: random inputs against an independent validation', () {
    test('$iterations iterations with a fixed seed', () {
      final random = Random(seed);
      var accepted = 0;
      var refused = 0;

      for (var i = 0; i < iterations; i++) {
        final Uint8List data;
        final FolderOfferRequest declared;
        switch (i % 3) {
          case 0:
            final base = randomValid(random);
            data = i % 9 == 0 ? base.bytes : mutate(base.bytes, random);
            declared = random.nextBool()
                ? declare(
                    entries: base.declared.entries,
                    manifestBytes: data.length,
                    files: base.declared.files,
                    bytes: base.declared.bytes,
                    depth: base.declared.depth,
                    longest: base.declared.longest,
                  )
                : base.declared;
          case 1:
            data = randomLists(random);
            declared = declare(
              entries: data.where((byte) => byte == 10).length,
              manifestBytes: data.length,
              files: random.nextInt(3),
              bytes: random.nextInt(10000),
              depth: random.nextInt(5),
              longest: random.nextInt(40),
            );
          default:
            data = randomBytes(random);
            declared = declare(
              entries: random.nextInt(6),
              manifestBytes: random.nextBool()
                  ? data.length
                  : random.nextInt(300),
              files: random.nextInt(3),
              bytes: random.nextInt(100),
              depth: random.nextInt(3),
              longest: random.nextInt(30),
            );
        }

        final ReadResult whole;
        final ReadResult chunked;
        try {
          whole = readAll(data, declared);
          chunked = readAll(data, declared, chunkSizes: chunkSizes(random));
        } catch (error, stack) {
          fail('iteration $i threw $error\n$stack\n${base64Encode(data)}');
        }

        final expected = referenceAccepts(data, declared);
        expect(
          whole.manifest != null,
          expected,
          reason:
              'iteration $i: reader ${whole.refusal ?? 'accepted'} but '
              'reference accepts=$expected for ${base64Encode(data)}',
        );
        expect(chunked.refusal, whole.refusal, reason: 'iteration $i chunks');
        expect(
          chunked.manifest == null,
          whole.manifest == null,
          reason: 'iteration $i chunks',
        );
        if (whole.manifest != null) {
          accepted++;
          expect(encodeManifest(whole.manifest!), data, reason: '$i');
          expect(encodeManifest(chunked.manifest!), data, reason: '$i');
        } else {
          refused++;
        }
      }

      expect(accepted, greaterThan(200));
      expect(refused, greaterThan(5000));
    });

    test('a refusal never reads more than it needs', () {
      final random = Random(seed + 1);
      for (var i = 0; i < 200; i++) {
        final base = randomValid(random);
        final data = Uint8List.fromList([
          ...utf8.encode('[0,".."]\n'),
          ...base.bytes,
        ]);
        final reader = ManifestReader(
          declare(
            entries: base.declared.entries + 1,
            manifestBytes: data.length,
          ),
        );

        expect(reader.add(data), ManifestRefusal.invalidName);
        expect(reader.add(base.bytes), ManifestRefusal.invalidName);
      }
    });

    test('input far beyond the declaration is cut at the declared size', () {
      final reader = ManifestReader(declare(entries: 3, manifestBytes: 64));
      final big = Uint8List(8 * 1024 * 1024);

      expect(reader.add(big), ManifestRefusal.incompatible);
      expect(reader.close().refusal, ManifestRefusal.incompatible);
    });
  });
}
