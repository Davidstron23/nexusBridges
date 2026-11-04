import 'dart:convert';
import 'dart:math';

import 'package:nexus_bridges_core/src/browse/browse.dart';
import 'package:nexus_bridges_core/src/transfer/transfer.dart'
    show RelativePathProblem, checkRelativePath;
import 'package:test/test.dart';

const int iterations = 10000;

final List<String> tokens = [
  'a',
  'b',
  'Z',
  '0',
  '9',
  'mods',
  'docs',
  '_',
  '-',
  '.',
  ' ',
  '..',
  r'\',
  '/',
  ':',
  '*',
  '?',
  '"',
  '<',
  '>',
  '|',
  '(',
  ')',
  ' (',
  'C:',
  r'\\?\',
  r'\\.\',
  r'\\host\share',
  'CON',
  'con',
  'NUL',
  'Aux',
  'COM',
  'LPT',
  '1',
  '\u{B9}',
  '\u{B2}',
  '.txt',
  '.lnk',
  'desktop.ini',
  '.nexusbridges-incoming',
  '~nexusbridges-',
  '.{3050f4d8-98B5-11CF-BB82-00AA00BDCE0B}',
  '\u{F1}',
  '\u{DF}',
  '\u{FB01}',
  '\u{1F600}',
  String.fromCharCode(0),
  String.fromCharCode(0x1F),
  String.fromCharCode(0x7F),
  String.fromCharCode(0x9F),
  String.fromCharCode(0x202E),
  String.fromCharCode(0x2066),
  String.fromCharCode(0x200B),
  String.fromCharCode(0xFEFF),
  String.fromCharCode(0xD800),
  String.fromCharCode(0xDC00),
  'a' * 120,
];

const String jsonAlphabet = '{}[]",:01 truefalsnul\\roots folders more partial';

const String safeAlphabet = 'abcdefghijklmnopqrstuvwxyz0123456789_-';

const Set<String> reservedStems = {
  'CON',
  'PRN',
  'AUX',
  'NUL',
  'COM0',
  'COM1',
  'COM2',
  'COM3',
  'COM4',
  'COM5',
  'COM6',
  'COM7',
  'COM8',
  'COM9',
  'COM\u{B9}',
  'COM\u{B2}',
  'COM\u{B3}',
  'LPT0',
  'LPT1',
  'LPT2',
  'LPT3',
  'LPT4',
  'LPT5',
  'LPT6',
  'LPT7',
  'LPT8',
  'LPT9',
  'LPT\u{B9}',
  'LPT\u{B2}',
  'LPT\u{B3}',
};

bool hasLoneSurrogate(String text) {
  final units = text.codeUnits;
  for (var i = 0; i < units.length; i++) {
    final unit = units[i];
    if (unit >= 0xD800 && unit <= 0xDBFF) {
      if (i + 1 < units.length &&
          units[i + 1] >= 0xDC00 &&
          units[i + 1] <= 0xDFFF) {
        i++;
        continue;
      }
      return true;
    }
    if (unit >= 0xDC00 && unit <= 0xDFFF) return true;
  }
  return false;
}

bool hasBadUnit(String text, {required bool allowColon}) {
  for (final unit in text.codeUnits) {
    if (unit < 0x20 || (unit >= 0x7F && unit <= 0x9F)) return true;
    if (unit >= 0x202A && unit <= 0x202E) return true;
    if (unit >= 0x2066 && unit <= 0x2069) return true;
    if (unit == 0x200B || unit == 0xFEFF) return true;
    if (r'\/*?"<>|'.codeUnits.contains(unit)) return true;
    if (!allowColon && unit == 0x3A) return true;
  }
  return hasLoneSurrogate(text);
}

bool surelyBadFolderName(String name) {
  if (name.isEmpty || name.length > 255) return true;
  if (name == '.' || name == '..') return true;
  if (hasBadUnit(name, allowColon: false)) return true;
  if (name.endsWith('.') || name.endsWith(' ')) return true;
  final dot = name.indexOf('.');
  final stem = (dot < 0 ? name : name.substring(0, dot)).replaceFirst(
    RegExp(r' +$'),
    '',
  );
  if (reservedStems.contains(stem.toUpperCase())) return true;
  final lower = name.toLowerCase();
  if (lower == 'desktop.ini' || lower.endsWith('.lnk')) return true;
  final upper = name.toUpperCase();
  return upper == '.NEXUSBRIDGES-INCOMING' ||
      upper.startsWith('~NEXUSBRIDGES-');
}

bool surelyGoodFolderName(String name) {
  if (name.isEmpty || name.length > 255) return false;
  for (final unit in name.codeUnits) {
    if (!safeAlphabet.codeUnits.contains(unit)) return false;
  }
  return !reservedStems.contains(name.toUpperCase());
}

bool surelyBadRootLabel(String name) {
  if (name.isEmpty || name.length > 520) return true;
  if (name == '.' || name == '..') return true;
  return hasBadUnit(name, allowColon: true);
}

String asciiLower(String text) => String.fromCharCodes(
  text.codeUnits.map((u) => u >= 0x41 && u <= 0x5A ? u + 0x20 : u),
);

bool hasAsciiCaseRepeat(Iterable<String> names) {
  final seen = <String>{};
  for (final name in names) {
    if (!seen.add(asciiLower(name))) return true;
  }
  return false;
}

final class Gen {
  Gen(int seed) : random = Random(seed);

  final Random random;

  T pick<T>(List<T> from) => from[random.nextInt(from.length)];

  bool chance(int percent) => random.nextInt(100) < percent;

  String noisyName() {
    final buffer = StringBuffer();
    final count = random.nextInt(5);
    for (var i = 0; i < count; i++) {
      buffer.write(pick(tokens));
    }
    return buffer.toString();
  }

  String safeName({int max = 12}) {
    final length = 1 + random.nextInt(max);
    return String.fromCharCodes([
      for (var i = 0; i < length; i++)
        safeAlphabet.codeUnitAt(random.nextInt(safeAlphabet.length)),
    ]);
  }

  String hex32() => String.fromCharCodes([
    for (var i = 0; i < 32; i++)
      '0123456789abcdef'.codeUnitAt(random.nextInt(16)),
  ]);

  Object? anyJson(int depth) {
    final kind = random.nextInt(depth <= 0 ? 6 : 8);
    return switch (kind) {
      0 => null,
      1 => random.nextBool(),
      2 => random.nextInt(2000) - 1000,
      3 => random.nextDouble(),
      4 => noisyName(),
      5 => pick(['roots', 'folders', 'more', 'partial', 'checks', 'id']),
      6 => [for (var i = 0; i < random.nextInt(5); i++) anyJson(depth - 1)],
      _ => {
        for (var i = 0; i < random.nextInt(5); i++)
          pick([
            'roots',
            'folders',
            'more',
            'partial',
            'checks',
            'id',
            'name',
            'home',
            'available',
            'path',
            noisyName(),
          ]): anyJson(
            depth - 1,
          ),
      },
    };
  }

  Object? oddValue() => pick<Object? Function()>([
    () => null,
    () => 1,
    () => 'x',
    () => true,
    () => <Object?>[],
    () => <String, Object?>{},
    () => noisyName(),
  ])();
}

String describe(Object? value) {
  try {
    return jsonEncode(value).codeUnits.take(400).toString();
  } on Object {
    return value.runtimeType.toString();
  }
}

void main() {
  group('E701 random relative paths (RF-411) [SEG]', () {
    test('E701 $iterations random and mutated paths: checkRelativePath never '
        'throws and never accepts what an independent check rejects', () {
      final gen = Gen(70107);
      var accepted = 0;
      var refused = 0;
      for (var n = 0; n < iterations; n++) {
        final List<String> path;
        String? newFolder;
        final shape = gen.random.nextInt(4);
        if (shape == 0) {
          path = [
            for (var i = 0; i < gen.random.nextInt(40); i++) gen.noisyName(),
          ];
        } else {
          path = [
            for (var i = 0; i < gen.random.nextInt(36); i++) gen.safeName(),
          ];
          if (shape >= 2 && path.isNotEmpty) {
            final at = gen.random.nextInt(path.length);
            path[at] = switch (gen.random.nextInt(5)) {
              0 => gen.noisyName(),
              1 => '${path[at]}${gen.pick(['.', ' ', '. ', ' .'])}',
              2 => '${gen.pick(tokens)}${path[at]}',
              3 => '${path[at]}${gen.pick(tokens)}${gen.safeName()}',
              _ => gen.pick(tokens),
            };
          }
        }
        if (gen.chance(30)) {
          newFolder = gen.chance(50) ? gen.safeName() : gen.noisyName();
        }
        final rootUnits = gen.random.nextInt(241);
        final RelativePathProblem? result;
        try {
          result = checkRelativePath(
            path,
            newFolder: newFolder,
            rootPathUnits: rootUnits,
          );
        } catch (e) {
          fail('threw $e on ${describe(path)} + ${describe(newFolder)}');
        }
        final names = [...path, ?newFolder];
        final depth = names.length;
        final total =
            rootUnits + names.fold<int>(0, (s, x) => s + 1 + x.length);
        final reason = '${describe(names)} root $rootUnits';
        if (depth > 32) {
          expect(result, RelativePathProblem.tooDeep, reason: reason);
        } else if (names.any(surelyBadFolderName)) {
          expect(result, RelativePathProblem.invalidName, reason: reason);
        } else if (total > 236) {
          expect(
            result,
            anyOf(RelativePathProblem.tooLong, RelativePathProblem.invalidName),
            reason: reason,
          );
        }
        if (depth <= 32 && names.every(surelyGoodFolderName)) {
          expect(
            result,
            total > 236 ? RelativePathProblem.tooLong : isNull,
            reason: reason,
          );
        }
        if (result == null) {
          accepted++;
        } else {
          refused++;
        }
      }
      expect(accepted, greaterThan(iterations ~/ 20));
      expect(refused, greaterThan(iterations ~/ 4));
    });
  });

  group('E705 random answers to browse (RF-425) [SEG]', () {
    Map<String, Object?> validRoots(Gen gen, int checks) {
      final count = gen.random.nextInt(17);
      final names = <String>{};
      var homeUsed = false;
      final roots = <Object?>[];
      for (var i = 0; i < count; i++) {
        final home = !homeUsed && gen.chance(15);
        homeUsed |= home;
        String name = '';
        if (!home) {
          do {
            name = gen.safeName();
          } while (!names.add(name) || !surelyGoodFolderName(name));
        }
        roots.add({
          'id': gen.hex32(),
          'name': name,
          'home': home,
          'available': gen.random.nextBool(),
        });
      }
      return {
        'roots': roots,
        if (checks > 0)
          'checks': [for (var i = 0; i < checks; i++) gen.random.nextBool()],
      };
    }

    Map<String, Object?> validFolders(Gen gen) {
      final names = <String>{};
      final count = gen.chance(5)
          ? 990 + gen.random.nextInt(11)
          : gen.random.nextInt(30);
      while (names.length < count) {
        final name = gen.safeName(max: 16);
        if (surelyGoodFolderName(name)) names.add(name);
      }
      return {
        'folders': names.toList(),
        'more': gen.random.nextBool(),
        'partial': gen.random.nextBool(),
      };
    }

    Object? mutateRoots(Gen gen, Map<String, Object?> body) {
      final top = Map<String, Object?>.of(body);
      final roots = [
        for (final r in (top['roots']! as List))
          Map<String, Object?>.of(r as Map<String, Object?>),
      ];
      top['roots'] = roots;
      final steps = 1 + gen.random.nextInt(3);
      for (var s = 0; s < steps; s++) {
        final op = gen.random.nextInt(14);
        if (roots.isEmpty && op >= 3 && op <= 11) {
          roots.add({
            'id': gen.hex32(),
            'name': gen.safeName(),
            'home': false,
            'available': true,
          });
        }
        switch (op) {
          case 0:
            top[gen.pick(['path', 'absolutePath', 'x', 'checks'])] = gen
                .oddValue();
          case 1:
            top.remove(gen.pick(['roots', 'checks']));
          case 2:
            top['roots'] = gen.oddValue();
          case 3:
            final r = gen.pick(roots);
            r.remove(gen.pick(['id', 'name', 'home', 'available']));
          case 4:
            gen.pick(roots)[gen.pick(['path', 'size', 'x'])] = gen.oddValue();
          case 5:
            gen.pick(roots)[gen.pick(['id', 'name', 'home', 'available'])] = gen
                .oddValue();
          case 6:
            gen.pick(roots)['name'] = gen.noisyName();
          case 7:
            final r = gen.pick(roots);
            r['id'] = gen.pick([
              r['id'].toString().toUpperCase(),
              'abc',
              '${r['id']}0',
              gen.noisyName(),
            ]);
          case 8:
            roots.add(Map<String, Object?>.of(gen.pick(roots)));
          case 9:
            final r = gen.pick(roots);
            final copy = Map<String, Object?>.of(r)..['id'] = gen.hex32();
            final name = r['name'];
            if (name is String) copy['name'] = name.toUpperCase();
            roots.add(copy);
          case 10:
            final r = gen.pick(roots);
            r['home'] = !(r['home'] == true);
          case 11:
            gen.pick(roots)['name'] = gen.pick(['', 'x', '..', 'a (b']);
          case 12:
            final checks = top['checks'];
            top['checks'] = checks is List
                ? [...checks, gen.oddValue()]
                : [true];
          default:
            while (roots.length <= 16) {
              roots.add({
                'id': gen.hex32(),
                'name': 'r${roots.length}${gen.safeName()}',
                'home': false,
                'available': true,
              });
            }
        }
      }
      return top;
    }

    Object? mutateFolders(Gen gen, Map<String, Object?> body) {
      final top = Map<String, Object?>.of(body);
      final names = <Object?>[...(top['folders']! as List)];
      top['folders'] = names;
      final steps = 1 + gen.random.nextInt(3);
      for (var s = 0; s < steps; s++) {
        switch (gen.random.nextInt(9)) {
          case 0:
            top[gen.pick(['path', 'size', 'x'])] = gen.oddValue();
          case 1:
            top.remove(gen.pick(['folders', 'more', 'partial']));
          case 2:
            top[gen.pick(['folders', 'more', 'partial'])] = gen.oddValue();
          case 3:
            names.add(gen.noisyName());
          case 4:
            if (names.isNotEmpty) {
              names[gen.random.nextInt(names.length)] = gen.oddValue();
            }
          case 5:
            if (names.isNotEmpty) {
              final name = names[gen.random.nextInt(names.length)];
              if (name is String) names.add(name.toUpperCase());
            }
          case 6:
            names.add(gen.pick(tokens));
          case 7:
            while (names.length <= 1000) {
              names.add('f${names.length}');
            }
          default:
            if (names.isNotEmpty) {
              final at = gen.random.nextInt(names.length);
              names[at] = '${names[at]}${gen.pick(['.', ' ', '\u{202E}'])}';
            }
        }
      }
      return top;
    }

    bool surelyBadRoots(Object? json, int checks) {
      if (json is! Map) return true;
      final keys = json.keys.toSet();
      final expected = checks > 0 ? {'roots', 'checks'} : {'roots'};
      if (keys.length != expected.length || !keys.containsAll(expected)) {
        return true;
      }
      if (checks > 0) {
        final list = json['checks'];
        if (list is! List || list.length != checks) return true;
        if (list.any((v) => v is! bool)) return true;
      }
      final roots = json['roots'];
      if (roots is! List || roots.length > 16) return true;
      final ids = <String>{};
      final names = <String>[];
      var homes = 0;
      for (final root in roots) {
        if (root is! Map) return true;
        final rk = root.keys.toSet();
        if (rk.length != 4 ||
            !rk.containsAll(['id', 'name', 'home', 'available'])) {
          return true;
        }
        final id = root['id'];
        final name = root['name'];
        final home = root['home'];
        if (id is! String || !RegExp(r'^[0-9a-f]{32}$').hasMatch(id)) {
          return true;
        }
        if (!ids.add(id)) return true;
        if (home is! bool || root['available'] is! bool) return true;
        if (name is! String) return true;
        if (home) {
          homes++;
          if (name.isNotEmpty) return true;
        } else {
          if (surelyBadRootLabel(name)) return true;
          names.add(name);
        }
      }
      return homes > 1 || hasAsciiCaseRepeat(names);
    }

    bool surelyBadFolders(Object? json) {
      if (json is! Map) return true;
      final keys = json.keys.toSet();
      if (keys.length != 3 ||
          !keys.containsAll(['folders', 'more', 'partial'])) {
        return true;
      }
      if (json['more'] is! bool || json['partial'] is! bool) return true;
      final folders = json['folders'];
      if (folders is! List || folders.length > 1000) return true;
      if (folders.any((n) => n is! String || surelyBadFolderName(n))) {
        return true;
      }
      return hasAsciiCaseRepeat(folders.cast<String>());
    }

    Object? fromBytes(Gen gen) {
      final bytes = [
        for (var i = 0; i < gen.random.nextInt(80); i++)
          gen.chance(70)
              ? jsonAlphabet.codeUnitAt(gen.random.nextInt(jsonAlphabet.length))
              : gen.random.nextInt(256),
      ];
      final text = utf8.decode(bytes, allowMalformed: true);
      try {
        return jsonDecode(text);
      } on FormatException {
        return gen.chance(50) ? text : bytes;
      }
    }

    test('E705 $iterations random answers: parseRootsResponse never throws '
        'and never accepts what an independent check rejects', () {
      final gen = Gen(70507);
      var accepted = 0;
      for (var n = 0; n < iterations; n++) {
        final checks = gen.chance(70) ? 0 : 1 + gen.random.nextInt(16);
        final source = gen.random.nextInt(4);
        final valid = validRoots(gen, checks);
        final Object? json = switch (source) {
          0 => fromBytes(gen),
          1 => gen.anyJson(4),
          2 => valid,
          _ => mutateRoots(gen, valid),
        };
        final wired = source == 0 ? json : jsonDecode(jsonEncode(json));
        final RemoteRoots? parsed;
        try {
          parsed = parseRootsResponse(wired, checks: checks);
        } catch (e) {
          fail('threw $e on ${describe(wired)}');
        }
        final reason = '${describe(wired)} checks $checks';
        if (parsed != null) {
          accepted++;
          expect(surelyBadRoots(wired, checks), isFalse, reason: reason);
          final roots = (wired! as Map)['roots']! as List;
          expect(parsed.roots, hasLength(roots.length), reason: reason);
          for (var i = 0; i < roots.length; i++) {
            expect(parsed.roots[i].id, (roots[i] as Map)['id']);
          }
          expect(parsed.checks, hasLength(checks), reason: reason);
        }
        if (source == 2) expect(parsed, isNotNull, reason: reason);
      }
      expect(accepted, greaterThan(iterations ~/ 5));
    });

    test('E705 $iterations random answers: parseFoldersResponse never '
        'throws and never accepts what an independent check rejects', () {
      final gen = Gen(70508);
      var accepted = 0;
      for (var n = 0; n < iterations; n++) {
        final source = gen.random.nextInt(4);
        final valid = source >= 2
            ? validFolders(gen)
            : const <String, Object?>{};
        final Object? json = switch (source) {
          0 => fromBytes(gen),
          1 => gen.anyJson(4),
          2 => valid,
          _ => mutateFolders(gen, valid),
        };
        final wired = source == 0 ? json : jsonDecode(jsonEncode(json));
        final RemoteFolders? parsed;
        try {
          parsed = parseFoldersResponse(wired);
        } catch (e) {
          fail('threw $e on ${describe(wired)}');
        }
        final reason = describe(wired);
        if (parsed != null) {
          accepted++;
          expect(surelyBadFolders(wired), isFalse, reason: reason);
          final map = wired! as Map;
          expect(parsed.names, map['folders'], reason: reason);
          expect(parsed.more, map['more']);
          expect(parsed.partial, map['partial']);
        }
        if (source == 2) expect(parsed, isNotNull, reason: reason);
      }
      expect(accepted, greaterThan(iterations ~/ 5));
    });
  });
}
