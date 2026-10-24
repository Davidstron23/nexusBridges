import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:nexus_bridges_core/src/protocol/protocol.dart';
import 'package:test/test.dart';

final String validFingerprint = '0123456789ABCDEF' * 4;

Map<String, Object?> validInfoJson() => {
  'name': 'David PC',
  'fingerprint': validFingerprint,
  'port': 53530,
  'protocol': '1.0',
  'deviceType': 'desktop',
};

Map<String, Object?> validAnnouncementJson() => {
  'kind': 'hello',
  ...validInfoJson(),
};

Uint8List bytesOf(Object? json) =>
    Uint8List.fromList(utf8.encode(jsonEncode(json)));

DeviceInfo sampleInfo({
  String? name = 'David PC',
  DeviceType deviceType = DeviceType.desktop,
}) => DeviceInfo(
  name: name,
  fingerprint: validFingerprint,
  port: 53530,
  protocol: '1.0',
  deviceType: deviceType,
);

void expectSameInfo(DeviceInfo actual, DeviceInfo expected) {
  expect(actual.name, expected.name);
  expect(actual.fingerprint, expected.fingerprint);
  expect(actual.port, expected.port);
  expect(actual.protocol, expected.protocol);
  expect(actual.deviceType, expected.deviceType);
}

Object? randomValue(Random random, int depth) {
  switch (random.nextInt(depth > 2 ? 9 : 11)) {
    case 0:
      return null;
    case 1:
      return random.nextBool();
    case 2:
      return random.nextInt(1 << 32) - (1 << 31);
    case 3:
      return random.nextDouble() * 100000;
    case 4:
      return random.nextBool() ? 53530 : random.nextInt(70000);
    case 5:
      return random.nextBool() ? '1.${random.nextInt(10)}' : '2.0';
    case 6:
      return random.nextBool()
          ? validFingerprint
          : validFingerprint.substring(random.nextInt(64));
    case 7:
      return ['desktop', 'mobile', 'Desktop', '', 'hello', 'bye'][random
          .nextInt(6)];
    case 8:
      return String.fromCharCodes([
        for (var i = 0, n = random.nextInt(90); i < n; i++)
          random.nextInt(0xD7FF),
      ]);
    case 9:
      return [
        for (var i = 0, n = random.nextInt(4); i < n; i++)
          randomValue(random, depth + 1),
      ];
    default:
      return randomMap(random, depth + 1);
  }
}

Map<String, Object?> randomMap(Random random, int depth) {
  final map = <String, Object?>{};
  void maybe(String key, int presentOutOf, Object? Function() plausible) {
    if (random.nextInt(presentOutOf) == 0) return;
    map[key] = random.nextInt(4) == 0
        ? randomValue(random, depth)
        : plausible();
  }

  maybe('kind', 8, () => ['hello', 'bye', 'x'][random.nextInt(3)]);
  maybe('name', 10, () => randomName(random));
  maybe('fingerprint', 10, () => validFingerprint);
  maybe('port', 10, () => random.nextInt(70000) - 1000);
  maybe('protocol', 10, () => '${random.nextInt(3)}.${random.nextInt(10)}');
  maybe('deviceType', 10, () => ['desktop', 'mobile', 'tv'][random.nextInt(3)]);
  if (random.nextInt(10) == 0) map['extra'] = randomValue(random, depth);
  return map;
}

String randomName(Random random) {
  const pieces = [
    'a',
    'Z',
    ' ',
    '\t',
    '\u0000',
    '\x7F',
    'é',
    '😀',
    '💻',
    '\u202E',
    '\u0085',
    '\u200B',
    '\uFEFF',
    '\u2028',
    '\u2066',
    '\u00A0',
  ];
  return [
    for (var i = 0, n = random.nextInt(100); i < n; i++)
      pieces[random.nextInt(pieces.length)],
  ].join();
}

void main() {
  group('constants', () {
    test('protocol defaults match the plan', () {
      expect(defaultPort, 53530);
      expect(apiPrefix, '/api/nexusbridges/v1');
      expect(maxDatagramBytes, 1024);
    });

    test('multicastGroup is the IPv4 multicast address 224.0.0.169', () {
      expect(multicastGroup.address, '224.0.0.169');
      expect(multicastGroup.type, InternetAddressType.IPv4);
      expect(multicastGroup.isMulticast, isTrue);
    });

    test('Limits has exactly the values of the plan', () {
      expect(Limits.maxBodyBytes, 65536);
      expect(Limits.maxHeaderBytes, 8192);
      expect(Limits.requestTimeout, const Duration(seconds: 10));
      expect(Limits.registerPerMinute, 30);
      expect(Limits.registerBlock, const Duration(minutes: 1));
      expect(Limits.maxListedUnpaired, 64);
      expect(Limits.maxNameLength, 64);
      expect(Limits.announceInterval, const Duration(seconds: 10));
      expect(Limits.expireAfter, const Duration(seconds: 30));
      expect(Limits.rescanHintAfter, const Duration(seconds: 15));
      expect(Limits.scanConcurrency, 32);
      expect(Limits.scanConnectTimeout, const Duration(milliseconds: 1500));
      expect(Limits.maxPendingHandshakesPerIp, 8);
      expect(Limits.maxPendingHandshakes, 128);
    });

    test('C122: the peer expiry threshold is the pairing timeout minus one '
        'message timeout, and the other v8 limits have the plan values', () {
      expect(
        Limits.pairingPeerExpiryAfter,
        Limits.pairingTimeout - Limits.pairingMessageTimeout,
      );
      expect(Limits.pairingPeerExpiryAfter, const Duration(seconds: 50));
      expect(Limits.replaceAfterAbsence, const Duration(minutes: 2));
      expect(Limits.goodbyeCheckInterval, const Duration(seconds: 5));
      expect(Limits.maxCombiningMarks, 4);
    });

    test('protocolVersion is re-exported by the protocol module', () {
      expect(protocolVersion, '1.0');
    });

    test('PortInUseException keeps the port and prints it', () {
      const exception = PortInUseException(53530);
      expect(exception, isA<Exception>());
      expect(exception.port, 53530);
      expect(exception.toString(), 'PortInUseException(53530)');
    });

    test('enums have exactly the plan values', () {
      expect(DeviceType.values.map((t) => t.name), ['desktop', 'mobile']);
      expect(AnnouncementKind.values.map((k) => k.name), ['hello', 'bye']);
    });
  });

  group('DeviceInfo.toJson (RF-30)', () {
    test('has exactly the five announcement fields', () {
      final json = sampleInfo().toJson();
      expect(json.keys.toSet(), {
        'name',
        'fingerprint',
        'port',
        'protocol',
        'deviceType',
      });
      expect(json, {
        'name': 'David PC',
        'fingerprint': validFingerprint,
        'port': 53530,
        'protocol': '1.0',
        'deviceType': 'desktop',
      });
    });

    test('always emits name, as null when there is none', () {
      final json = sampleInfo(name: null).toJson();
      expect(json.length, 5);
      expect(json.containsKey('name'), isTrue);
      expect(json['name'], isNull);
    });

    test('writes deviceType in lowercase', () {
      expect(
        sampleInfo(deviceType: DeviceType.mobile).toJson()['deviceType'],
        'mobile',
      );
    });

    for (final type in DeviceType.values) {
      for (final name in <String?>['David PC', null, 'Portátil 💻']) {
        test('round-trips through tryParse ($type, name: $name)', () {
          final original = sampleInfo(name: name, deviceType: type);
          final parsed = DeviceInfo.tryParse(original.toJson());
          expect(parsed, isNotNull);
          expectSameInfo(parsed!, original);
        });
      }
    }

    test('round-trips through a real JSON string', () {
      final original = sampleInfo();
      final parsed = DeviceInfo.tryParse(
        jsonDecode(jsonEncode(original.toJson())),
      );
      expect(parsed, isNotNull);
      expectSameInfo(parsed!, original);
    });
  });

  group('DeviceInfo.tryParse validation (RF-56)', () {
    void expectRejected(String reason, Object? json) {
      test('rejects $reason', () {
        expect(DeviceInfo.tryParse(json), isNull);
      });
    }

    Map<String, Object?> withValue(String key, Object? value) =>
        validInfoJson()..[key] = value;

    test('accepts the valid sample', () {
      expect(DeviceInfo.tryParse(validInfoJson()), isNotNull);
    });

    expectRejected('null', null);
    expectRejected('a list', [validInfoJson()]);
    expectRejected('a string', 'not a map');
    expectRejected('an empty map', <String, Object?>{});

    expectRejected(
      'a map without fingerprint',
      validInfoJson()..remove('fingerprint'),
    );
    expectRejected('a map without port', validInfoJson()..remove('port'));
    expectRejected(
      'a map without protocol',
      validInfoJson()..remove('protocol'),
    );
    expectRejected(
      'a map without deviceType',
      validInfoJson()..remove('deviceType'),
    );
    expectRejected('a map without name', validInfoJson()..remove('name'));
    expectRejected('one extra key', validInfoJson()..['extra'] = 1);
    expectRejected(
      'five keys where name is replaced by an unknown key',
      validInfoJson()
        ..remove('name')
        ..['extra'] = 'x',
    );
    expectRejected(
      'five keys where fingerprint is replaced by an unknown key',
      validInfoJson()
        ..remove('fingerprint')
        ..['Fingerprint'] = validFingerprint,
    );

    expectRejected(
      'a lowercase fingerprint',
      withValue('fingerprint', validFingerprint.toLowerCase()),
    );
    expectRejected(
      'a fingerprint of 63 characters',
      withValue('fingerprint', validFingerprint.substring(1)),
    );
    expectRejected(
      'a fingerprint of 65 characters',
      withValue('fingerprint', '${validFingerprint}A'),
    );
    expectRejected(
      'a fingerprint with a non-hex character',
      withValue('fingerprint', '${validFingerprint.substring(1)}G'),
    );
    expectRejected(
      'a fingerprint with a trailing newline',
      withValue('fingerprint', '$validFingerprint\n'),
    );
    expectRejected('a numeric fingerprint', withValue('fingerprint', 12345));
    expectRejected('a null fingerprint', withValue('fingerprint', null));

    expectRejected('port 0', withValue('port', 0));
    expectRejected('port -1', withValue('port', -1));
    expectRejected('port 65536', withValue('port', 65536));
    expectRejected('a double port', withValue('port', 53530.0));
    expectRejected('a bool port', withValue('port', true));
    expectRejected('a string port', withValue('port', '53530'));
    test('accepts the port bounds 1 and 65535', () {
      expect(DeviceInfo.tryParse(withValue('port', 1))?.port, 1);
      expect(DeviceInfo.tryParse(withValue('port', 65535))?.port, 65535);
    });

    expectRejected('protocol "2.0"', withValue('protocol', '2.0'));
    expectRejected('protocol "0.9"', withValue('protocol', '0.9'));
    expectRejected('protocol "1"', withValue('protocol', '1'));
    expectRejected('protocol "1.0.0"', withValue('protocol', '1.0.0'));
    expectRejected(
      'protocol "1.0" with a trailing newline',
      withValue('protocol', '1.0\n'),
    );
    expectRejected('protocol "v1.0"', withValue('protocol', 'v1.0'));
    expectRejected(
      'a huge major version',
      withValue('protocol', '99999999999999999999999.0'),
    );
    expectRejected('a numeric protocol', withValue('protocol', 1.0));
    test('accepts a protocol of exactly 16 characters and rejects one of '
        '17 (v2.6.10)', () {
      final sixteen = '1.${'0' * 14}';
      final seventeen = '1.${'0' * 15}';

      expect(sixteen, hasLength(16));
      expect(seventeen, hasLength(17));
      expect(
        DeviceInfo.tryParse(withValue('protocol', sixteen))?.protocol,
        sixteen,
      );
      expect(DeviceInfo.tryParse(withValue('protocol', seventeen)), isNull);
    });
    test('rejects a protocol of 5002 characters with the right major '
        '(v2.6.10)', () {
      final huge = '1.${'0' * 5000}';

      expect(huge, hasLength(5002));
      expect(DeviceInfo.tryParse(withValue('protocol', huge)), isNull);
    });
    test('accepts protocol "1.5" (same major, other minor)', () {
      expect(
        DeviceInfo.tryParse(withValue('protocol', '1.5'))?.protocol,
        '1.5',
      );
    });

    expectRejected('an unknown deviceType', withValue('deviceType', 'tv'));
    expectRejected(
      'an uppercase deviceType',
      withValue('deviceType', 'Desktop'),
    );
    expectRejected('a numeric deviceType', withValue('deviceType', 0));
    expectRejected('a null deviceType', withValue('deviceType', null));

    expectRejected('a numeric name', withValue('name', 42));
    expectRejected('a list name', withValue('name', ['David']));
    test('accepts a null name', () {
      final parsed = DeviceInfo.tryParse(withValue('name', null));
      expect(parsed, isNotNull);
      expect(parsed!.name, isNull);
    });
  });

  group('DeviceInfo.tryParse name cleaning', () {
    String? parsedName(Object? name) =>
        DeviceInfo.tryParse(validInfoJson()..['name'] = name)?.name;

    test('80 characters with a control character give 64 clean characters', () {
      final raw = '${'a' * 40}\u0007${'b' * 39}';
      expect(raw.length, 80);
      final name = parsedName(raw);
      expect(name, '${'a' * 40}${'b' * 24}');
      expect(name!.length, 64);
      expect(name, isNot(contains('\u0007')));
    });

    test('removes every character in \\x00-\\x1F and \\x7F', () {
      final controls = [
        for (var c = 0; c <= 0x1F; c++) String.fromCharCode(c),
        '\x7F',
      ].join();
      expect(parsedName('Da${controls}vid'), 'David');
    });

    test('trims surrounding spaces', () {
      expect(parsedName('   David PC   '), 'David PC');
    });

    test('a name of only spaces is null', () {
      final parsed = DeviceInfo.tryParse(validInfoJson()..['name'] = '     ');
      expect(parsed, isNotNull);
      expect(parsed!.name, isNull);
    });

    test('an empty name is null', () {
      expect(DeviceInfo.tryParse(validInfoJson()..['name'] = ''), isNotNull);
      expect(parsedName(''), isNull);
    });

    test('a name of only control characters and spaces is null', () {
      final parsed = DeviceInfo.tryParse(
        validInfoJson()..['name'] = ' \t\n\r\x00\x7F ',
      );
      expect(parsed, isNotNull);
      expect(parsed!.name, isNull);
    });

    test('keeps a name of exactly 64 characters', () {
      expect(parsedName('x' * 64), 'x' * 64);
    });

    test('truncates emojis to 64 runes without splitting a surrogate pair', () {
      final name = parsedName('😀' * 70)!;
      expect(name.runes.length, 64);
      expect(name.length, 128);
      expect(name, '😀' * 64);
    });

    test('never splits a pair that straddles the 64-rune boundary', () {
      final name = parsedName('${'a' * 63}😀bcd')!;
      expect(name, '${'a' * 63}😀');
      expect(name.runes.length, 64);
      expect(name.length, 65);
      final last = name.codeUnitAt(name.length - 1);
      expect(
        last >= 0xDC00 && last <= 0xDFFF,
        isTrue,
        reason: 'the result must end with the low surrogate of the emoji',
      );
    });
  });

  group('sanitizeDisplayName (RF-10, RF-56, plan v2.7 point 1)', () {
    const spoofing = <String, String>{
      'U+202E right-to-left override': '\u202E',
      'U+0085 next line': '\u0085',
      'U+200B zero width space': '\u200B',
      'U+FEFF byte order mark': '\uFEFF',
      'U+2028 line separator': '\u2028',
      'U+2066 left-to-right isolate': '\u2066',
    };

    for (final MapEntry(key: label, value: c) in spoofing.entries) {
      test('removes $label inside a name', () {
        expect(sanitizeDisplayName('Da${c}vid PC'), 'David PC');
      });

      test('removes $label at the edges of a name', () {
        expect(sanitizeDisplayName('${c}David PC$c'), 'David PC');
      });
    }

    test('the right-to-left override trick loses its override', () {
      final cleaned = sanitizeDisplayName('Invoice\u202Efdp.exe');
      expect(cleaned, 'Invoicefdp.exe');
      expect(cleaned!.runes, isNot(contains(0x202E)));
    });

    test('removes every code point of the ranges of the plan', () {
      const ranges = [
        (0x0000, 0x001F),
        (0x007F, 0x007F),
        (0x0080, 0x009F),
        (0x2028, 0x2029),
        (0x200B, 0x200F),
        (0x202A, 0x202E),
        (0x2060, 0x2060),
        (0x2066, 0x2069),
        (0xFEFF, 0xFEFF),
      ];
      for (final (first, last) in ranges) {
        for (var c = first; c <= last; c++) {
          final raw = 'Da${String.fromCharCode(c)}vid';
          expect(
            sanitizeDisplayName(raw),
            'David',
            reason: 'U+${c.toRadixString(16).padLeft(4, '0')}',
          );
        }
      }
    });

    test('removes all of them at once', () {
      final all = [
        for (var c = 0x0000; c <= 0x001F; c++) c,
        for (var c = 0x007F; c <= 0x009F; c++) c,
        0x2028,
        0x2029,
        for (var c = 0x200B; c <= 0x200F; c++) c,
        for (var c = 0x202A; c <= 0x202E; c++) c,
        0x2060,
        for (var c = 0x2066; c <= 0x2069; c++) c,
        0xFEFF,
      ];
      expect(
        sanitizeDisplayName('Port${String.fromCharCodes(all)}átil'),
        'Portátil',
      );
    });

    test('keeps visible characters right next to the ranges', () {
      const kept = [
        0x0020,
        0x007E,
        0x00A0,
        0x00A1,
        0x200A,
        0x2010,
        0x2027,
        0x202F,
        0x2030,
        0x205F,
        0xFF01,
      ];
      for (final c in kept) {
        final raw = 'Da${String.fromCharCode(c)}vid';
        expect(
          sanitizeDisplayName(raw),
          raw,
          reason: 'U+${c.toRadixString(16).padLeft(4, '0')}',
        );
      }
    });

    test('keeps a no-break space U+00A0 inside a name', () {
      expect(sanitizeDisplayName('David\u00A0PC'), 'David\u00A0PC');
    });

    test('a no-break space U+00A0 at the edges goes away with the trim', () {
      expect(sanitizeDisplayName('\u00A0David PC\u00A0'), 'David PC');
    });

    test('a name of only zero-width characters is null', () {
      expect(sanitizeDisplayName('\u200B'), isNull);
      expect(sanitizeDisplayName('\uFEFF'), isNull);
      expect(sanitizeDisplayName('\u200B\u200C\u200D\u2060\uFEFF'), isNull);
    });

    test('a name of only spaces is null', () {
      expect(sanitizeDisplayName(' '), isNull);
      expect(sanitizeDisplayName('     '), isNull);
      expect(sanitizeDisplayName('\u00A0\u3000\u2003'), isNull);
    });

    test('a name of invisible characters and spaces is null', () {
      expect(sanitizeDisplayName(' \u202E \u200B \u2066 \u0085 '), isNull);
    });

    test('an empty name is null', () {
      expect(sanitizeDisplayName(''), isNull);
    });

    test('removes before trimming', () {
      expect(sanitizeDisplayName('\u200B  David PC  \u200B'), 'David PC');
      expect(sanitizeDisplayName('\uFEFF\t David \u2066'), 'David');
    });

    test('truncates after removing, so invisible characters do not count', () {
      final raw = '${'a' * 40}${'\u200B' * 20}${'b' * 40}';
      expect(raw.runes.length, 100);
      final name = sanitizeDisplayName(raw);
      expect(name, '${'a' * 40}${'b' * 24}');
      expect(name!.runes.length, Limits.maxNameLength);
    });

    test('80 emojis outside the BMP become 64 without splitting one', () {
      final raw = '\u{1F600}' * 80;
      expect(raw.runes.length, 80);
      expect(raw.length, 160);

      final name = sanitizeDisplayName(raw)!;

      expect(name, '\u{1F600}' * 64);
      expect(name.runes.length, 64);
      expect(name.length, 128);
    });

    test('80 runes with an odd offset are cut on a whole emoji', () {
      final raw = 'x${'\u{1F4BB}' * 79}';
      expect(raw.runes.length, 80);

      final name = sanitizeDisplayName(raw)!;

      expect(name, 'x${'\u{1F4BB}' * 63}');
      expect(name.runes.length, 64);
      expect(name.length, 127);
      final last = name.codeUnitAt(name.length - 1);
      expect(last, inInclusiveRange(0xDC00, 0xDFFF));
      expect(name.runes.last, 0x1F4BB);
    });

    test('64 emojis are kept whole', () {
      final raw = '\u{1F600}\u{1F4BB}' * 32;
      expect(sanitizeDisplayName(raw), raw);
    });

    test('a 65-rune name loses only its last rune', () {
      expect(sanitizeDisplayName('${'n' * 64}z'), 'n' * 64);
    });

    test('a clean name comes back unchanged', () {
      expect(sanitizeDisplayName('Portátil de David'), 'Portátil de David');
      expect(sanitizeDisplayName('PC-1 \u{1F4BB}'), 'PC-1 \u{1F4BB}');
    });

    test('applying it twice gives the same as once', () {
      final samples = [
        'Da\u202Evid',
        '  \u200BPC\uFEFF  ',
        'x${'\u{1F4BB}' * 79}',
        '\u00A0Port\u00A0átil\u00A0',
        '${'a' * 63}\u0085${'b' * 10}',
      ];
      for (final raw in samples) {
        final once = sanitizeDisplayName(raw);
        expect(sanitizeDisplayName(once!), once, reason: raw);
      }
    });
  });

  group('sanitizeDisplayName with the ranges of plan v2.11 point 3 (RF-50, '
      'RF-56)', () {
    const added = [
      (0x00AD, 0x00AD),
      (0x034F, 0x034F),
      (0x061C, 0x061C),
      (0x115F, 0x1160),
      (0x17B4, 0x17B5),
      (0x180B, 0x180F),
      (0x2061, 0x2064),
      (0x206A, 0x206F),
      (0x3164, 0x3164),
      (0xFE00, 0xFE0F),
      (0xFFA0, 0xFFA0),
      (0xFFF0, 0xFFF8),
      (0x1BCA0, 0x1BCA3),
      (0x1D173, 0x1D17A),
      (0xE0000, 0xE0FFF),
    ];

    String hex(int c) =>
        'U+${c.toRadixString(16).toUpperCase().padLeft(4, '0')}';

    for (final (first, last) in added) {
      final label = first == last ? hex(first) : '${hex(first)}-${hex(last)}';
      test('removes every code point of $label inside and at the edges of a '
          'name', () {
        for (var c = first; c <= last; c++) {
          final invisible = String.fromCharCode(c);
          expect(
            sanitizeDisplayName('Da${invisible}vid'),
            'David',
            reason: hex(c),
          );
          expect(
            sanitizeDisplayName('${invisible}David PC$invisible'),
            'David PC',
            reason: hex(c),
          );
        }
      });
    }

    test('the edges outside the BMP of the plan go away, also '
        'next to each other', () {
      expect(sanitizeDisplayName('Da\u{1BCA0}vid'), 'David');
      expect(sanitizeDisplayName('Da\u{1D173}vid'), 'David');
      expect(sanitizeDisplayName('Da\u{E0001}vid'), 'David');
      expect(sanitizeDisplayName('Da\u{E0FFF}vid'), 'David');
      expect(
        sanitizeDisplayName('\u{E0001}\u{1D17A}PC\u{1BCA3}\u{E0FFF}'),
        'PC',
      );
    });

    test('removes all the new ranges at once', () {
      final all = [
        for (final (first, last) in added)
          for (var c = first; c <= last; c++) c,
      ];
      expect(sanitizeDisplayName('Da${String.fromCharCodes(all)}vid'), 'David');
    });

    test('keeps visible characters right next to the new ranges', () {
      const kept = [
        0x00AC,
        0x00AE,
        0x034E,
        0x0350,
        0x061B,
        0x115E,
        0x1161,
        0x17B3,
        0x17B6,
        0x180A,
        0x1810,
        0x2070,
        0x3163,
        0x3165,
        0xFE10,
        0xFF9F,
        0xFFA1,
        0xFFFC,
        0xFFFD,
        0x1BC9F,
        0x1D172,
        0x1D17B,
      ];
      for (final c in kept) {
        final raw = 'Da${String.fromCharCode(c)}vid';
        expect(sanitizeDisplayName(raw), raw, reason: hex(c));
      }
    });

    test('U+2065 is not on the list of the plan and stays', () {
      expect(sanitizeDisplayName('Da\u2065vid'), 'Da\u2065vid');
    });

    test('U+FFF9 is not on the list of the plan and stays', () {
      expect(sanitizeDisplayName('Da\uFFF9vid'), 'Da\uFFF9vid');
    });

    test('a name made only of the new invisible characters is null', () {
      expect(sanitizeDisplayName('\u3164'), isNull);
      expect(sanitizeDisplayName('\u3164\u3164\u3164'), isNull);
      expect(sanitizeDisplayName('\u115F\u1160\uFFA0'), isNull);
      expect(sanitizeDisplayName('\u00AD\u034F\u061C\u17B4\u180E'), isNull);
      expect(sanitizeDisplayName('\u{E0001}\u{E0FFF}\u{1BCA0}'), isNull);
      expect(
        sanitizeDisplayName(' \u3164 \u{1D173} \uFE0F \u2064 \u206F '),
        isNull,
      );
    });

    test('the new invisible characters do not count for the 64-rune '
        'limit', () {
      final raw = '${'a' * 40}${'\u{E0001}' * 30}${'\u3164' * 10}${'b' * 40}';
      expect(raw.runes.length, 120);

      final name = sanitizeDisplayName(raw)!;

      expect(name, '${'a' * 40}${'b' * 24}');
      expect(name.runes.length, Limits.maxNameLength);
    });

    test('emojis of one code point stay whole', () {
      expect(sanitizeDisplayName('PC \u{1F4BB}'), 'PC \u{1F4BB}');
      expect(
        sanitizeDisplayName('\u{1F600}\u{1F4BB}\u{1F680}'),
        '\u{1F600}\u{1F4BB}\u{1F680}',
      );
      final raw = '\u{1F4BB}' * 64;
      expect(sanitizeDisplayName(raw), raw);
    });

    test('an emoji with a variation selector keeps its base emoji and loses '
        'the selector, as the plan lists U+FE00-U+FE0F', () {
      expect(sanitizeDisplayName('PC \u2764\uFE0F'), 'PC \u2764');
    });

    test('a tag flag keeps its base emoji and loses the tags, as the plan '
        'lists U+E0000-U+E0FFF', () {
      const scotland =
          '\u{1F3F4}\u{E0067}\u{E0062}\u{E0073}\u{E0063}\u{E0074}\u{E007F}';
      expect(sanitizeDisplayName('PC $scotland'), 'PC \u{1F3F4}');
    });

    test('applying it twice gives the same as once', () {
      final samples = [
        'Da\u3164vid',
        '\u00ADPC\u{E0001}',
        'x${'\u{1F4BB}' * 70}\u{1D173}',
        '\u2065PC\uFFF9',
      ];
      for (final raw in samples) {
        final once = sanitizeDisplayName(raw);
        expect(sanitizeDisplayName(once!), once, reason: raw);
      }
    });

    test('tryParse and tryDecode clean the new ranges the same way', () {
      const raw = '\u3164Da\u00ADvid\u{E0001} PC\u{1D173}';
      final parsed = DeviceInfo.tryParse(validInfoJson()..['name'] = raw);
      expect(parsed?.name, 'David PC');

      final decoded = Announcement.tryDecode(
        bytesOf(validAnnouncementJson()..['name'] = '\u3164\u3164'),
      );
      expect(decoded, isNotNull);
      expect(decoded!.info.name, isNull);
    });
  });

  group('C135, N5: blank lookalikes and stacked combining marks (v8)', () {
    String char(int code) => String.fromCharCode(code);
    String repeat(int code, int times) => char(code) * times;
    const acute = 0x0301;
    const blankBraille = 0x2800;

    test('a name made only of blank braille is no name, and it is removed '
        'next to visible text', () {
      expect(sanitizeDisplayName(char(blankBraille)), isNull);
      expect(sanitizeDisplayName(repeat(blankBraille, 3)), isNull);
      expect(sanitizeDisplayName('PC${char(blankBraille)}'), 'PC');
      expect(sanitizeDisplayName('${char(blankBraille)} PC'), 'PC');
    });

    test('the Egyptian format controls U+13430 to U+1343F and the Khitan '
        'filler U+16FE4 are removed', () {
      for (var code = 0x13430; code <= 0x1343F; code++) {
        expect(
          sanitizeDisplayName('Da${char(code)}vid'),
          'David',
          reason: code.toRadixString(16),
        );
      }
      expect(sanitizeDisplayName('Da${char(0x16FE4)}vid'), 'David');
      expect(sanitizeDisplayName(char(0x16FE4) + char(0x13430)), isNull);
    });

    test('ten marks on one letter keep four', () {
      expect(
        sanitizeDisplayName('e${repeat(acute, 10)}'),
        'e${repeat(acute, 4)}',
      );
    });

    test('marks with no letter before them are dropped', () {
      expect(sanitizeDisplayName('${repeat(acute, 3)}PC'), 'PC');
      expect(sanitizeDisplayName(repeat(acute, 6)), isNull);
      expect(sanitizeDisplayName(' ${repeat(acute, 2)}'), isNull);
    });

    test('the count starts again at each letter', () {
      expect(
        sanitizeDisplayName('e${repeat(acute, 5)}a${repeat(acute, 5)}'),
        'e${repeat(acute, 4)}a${repeat(acute, 4)}',
      );
    });

    test('ordinary decomposed accents are kept as they are', () {
      final decomposed = 'Porta${char(acute)}til';
      final twoMarks = 'e${char(0x0323)}${char(0x0302)}';
      expect(sanitizeDisplayName(decomposed), decomposed);
      expect(sanitizeDisplayName(twoMarks), twoMarks);
      expect(sanitizeDisplayName('Port${char(0x00E1)}til'), 'Portátil');
    });

    test('70 letters with 4 marks each are cut to 64 runes', () {
      final raw = [for (var i = 0; i < 70; i++) 'x${repeat(acute, 4)}'].join();

      final name = sanitizeDisplayName(raw)!;

      expect(name.runes.length, Limits.maxNameLength);
      expect(name, raw.substring(0, Limits.maxNameLength));
    });

    test('invisible characters are removed before counting, so one between '
        'marks does not restart the count', () {
      final raw = 'PC${repeat(acute, 3)}${char(0x200B)}${repeat(acute, 3)}';

      expect(sanitizeDisplayName(raw), 'PC${repeat(acute, 4)}');
    });

    test('tryParse and tryDecode limit the marks the same way, and applying '
        'it twice gives the same as once', () {
      final raw = 'PC${repeat(acute, 9)}${char(blankBraille)}';
      final parsed = DeviceInfo.tryParse(validInfoJson()..['name'] = raw);
      expect(parsed?.name, 'PC${repeat(acute, 4)}');
      final decoded = Announcement.tryDecode(
        bytesOf(validAnnouncementJson()..['name'] = raw),
      );
      expect(decoded?.info.name, 'PC${repeat(acute, 4)}');
      final once = sanitizeDisplayName(raw)!;
      expect(sanitizeDisplayName(once), once);
    });
  });

  group('DeviceInfo.tryParse with names to sanitize (RF-56)', () {
    DeviceInfo? parsedWithName(String name) =>
        DeviceInfo.tryParse(validInfoJson()..['name'] = name);

    final cleaned = <String, String>{
      'Da\u202Evid PC': 'David PC',
      'Da\u0085vid PC': 'David PC',
      '\u200BDavid PC\u200B': 'David PC',
      '\uFEFFDavid PC': 'David PC',
      'David\u2028PC': 'DavidPC',
      '\u2066David PC\u2069': 'David PC',
      'David\u00A0PC': 'David\u00A0PC',
      '\u00A0David PC\u00A0': 'David PC',
    };

    var index = 0;
    for (final MapEntry(key: raw, value: expected) in cleaned.entries) {
      test('gives the clean name for sample ${index++}', () {
        final parsed = parsedWithName(raw);
        expect(parsed, isNotNull);
        expect(parsed!.name, expected);
        expect(parsed.fingerprint, validFingerprint);
        expect(parsed.port, 53530);
        expect(parsed.protocol, '1.0');
        expect(parsed.deviceType, DeviceType.desktop);
      });
    }

    final empty = <String>[
      '\u200B',
      '\u200B\u200C\u200D\uFEFF',
      '   ',
      ' \u202E \u0085 \u2066 ',
      '\u00A0\u00A0',
    ];

    for (final (i, raw) in empty.indexed) {
      test('keeps the device with name: null for invisible sample $i', () {
        final parsed = parsedWithName(raw);
        expect(parsed, isNotNull);
        expect(parsed!.name, isNull);
        expect(parsed.fingerprint, validFingerprint);
      });
    }

    test('80 emojis outside the BMP become 64 whole ones', () {
      final name = parsedWithName('\u{1F600}' * 80)!.name!;
      expect(name, '\u{1F600}' * 64);
      expect(name.runes.length, 64);
    });

    test('an announcement over JSON gets the same clean name', () {
      final decoded = Announcement.tryDecode(
        bytesOf(validAnnouncementJson()..['name'] = '\u2066Da\u202Evid\u200B'),
      );
      expect(decoded, isNotNull);
      expect(decoded!.info.name, 'David');
    });

    test('an announcement whose name is only invisible gives name: null', () {
      final decoded = Announcement.tryDecode(
        bytesOf(validAnnouncementJson()..['name'] = '\uFEFF\u200B'),
      );
      expect(decoded, isNotNull);
      expect(decoded!.info.name, isNull);
    });

    test('tryParse gives the same name as sanitizeDisplayName', () {
      final samples = [...cleaned.keys, ...empty, 'x${'\u{1F4BB}' * 79}'];
      for (final raw in samples) {
        expect(
          parsedWithName(raw)?.name,
          sanitizeDisplayName(raw),
          reason: raw,
        );
      }
    });
  });

  group('Announcement.encode (RF-40)', () {
    test('produces UTF-8 JSON with exactly the announcement keys', () {
      final bytes = Announcement(AnnouncementKind.hello, sampleInfo()).encode();
      final decoded = jsonDecode(utf8.decode(bytes)) as Map<String, Object?>;
      expect(decoded.keys.toSet(), {
        'kind',
        'name',
        'fingerprint',
        'port',
        'protocol',
        'deviceType',
      });
      expect(decoded, {
        'kind': 'hello',
        'name': 'David PC',
        'fingerprint': validFingerprint,
        'port': 53530,
        'protocol': '1.0',
        'deviceType': 'desktop',
      });
    });

    test('writes kind and deviceType in lowercase', () {
      final decoded = jsonDecode(
        utf8.decode(
          Announcement(
            AnnouncementKind.bye,
            sampleInfo(deviceType: DeviceType.mobile),
          ).encode(),
        ),
      ) as Map<String, Object?>;
      expect(decoded['kind'], 'bye');
      expect(decoded['deviceType'], 'mobile');
    });

    test('encodes non-ASCII names as UTF-8', () {
      final bytes = Announcement(
        AnnouncementKind.hello,
        sampleInfo(name: 'Portátil 💻'),
      ).encode();
      expect(utf8.decode(bytes), contains('Portátil 💻'));
    });

    test('the largest valid announcement fits in one datagram', () {
      final info = sampleInfo(name: '😀' * Limits.maxNameLength);
      final bytes = Announcement(AnnouncementKind.hello, info).encode();
      expect(bytes.length, lessThanOrEqualTo(maxDatagramBytes));
      expect(Announcement.tryDecode(bytes), isNotNull);
    });

    for (final kind in AnnouncementKind.values) {
      for (final type in DeviceType.values) {
        for (final name in <String?>['David PC', null]) {
          test('round-trips through tryDecode ($kind, $type, name: $name)', () {
            final original = Announcement(
              kind,
              sampleInfo(name: name, deviceType: type),
            );
            final decoded = Announcement.tryDecode(original.encode());
            expect(decoded, isNotNull);
            expect(decoded!.kind, kind);
            expectSameInfo(decoded.info, original.info);
          });
        }
      }
    }
  });

  group('Announcement.tryDecode rejections (RF-56)', () {
    void expectRejectedBytes(String reason, List<int> bytes) {
      test('rejects $reason', () {
        expect(Announcement.tryDecode(Uint8List.fromList(bytes)), isNull);
      });
    }

    void expectRejectedJson(String reason, Object? json) =>
        expectRejectedBytes(reason, bytesOf(json));

    Map<String, Object?> withValue(String key, Object? value) =>
        validAnnouncementJson()..[key] = value;

    test('accepts the valid sample', () {
      expect(
        Announcement.tryDecode(bytesOf(validAnnouncementJson())),
        isNotNull,
      );
    });

    expectRejectedBytes('invalid JSON', utf8.encode('{"kind": "hello",'));
    expectRejectedJson(
      'a map without fingerprint',
      validAnnouncementJson()..remove('fingerprint'),
    );
    expectRejectedJson(
      'a lowercase fingerprint',
      withValue('fingerprint', validFingerprint.toLowerCase()),
    );
    expectRejectedJson('protocol "2.0"', withValue('protocol', '2.0'));
    expectRejectedJson('kind "x"', withValue('kind', 'x'));
    expectRejectedJson('one extra key', validAnnouncementJson()..['extra'] = 1);
    test('rejects 2000 bytes even when the JSON is otherwise valid', () {
      final json = jsonEncode(validAnnouncementJson());
      final padded =
          '${json.substring(0, json.length - 1)}'
          '${' ' * (2000 - json.length)}}';
      final bytes = Uint8List.fromList(utf8.encode(padded));
      expect(bytes.length, 2000);
      expect(jsonDecode(padded), validAnnouncementJson());
      expect(Announcement.tryDecode(bytes), isNull);
    });

    Uint8List paddedTo(int length) {
      final json = jsonEncode(validAnnouncementJson());
      return Uint8List.fromList(
        utf8.encode(
          '${json.substring(0, json.length - 1)}'
          '${' ' * (length - json.length)}}',
        ),
      );
    }

    test('accepts exactly maxDatagramBytes bytes', () {
      final bytes = paddedTo(maxDatagramBytes);
      expect(bytes.length, maxDatagramBytes);
      expect(Announcement.tryDecode(bytes), isNotNull);
    });

    test('rejects maxDatagramBytes + 1 bytes', () {
      final bytes = paddedTo(maxDatagramBytes + 1);
      expect(bytes.length, maxDatagramBytes + 1);
      expect(Announcement.tryDecode(bytes), isNull);
    });

    expectRejectedBytes('no bytes at all', []);
    expectRejectedBytes('invalid UTF-8', [0x7B, 0xFF, 0xFE, 0x7D]);
    expectRejectedBytes(
      'a truncated UTF-8 sequence inside a valid-looking JSON',
      [
        ...utf8.encode('{"kind":"hello","name":"'),
        0xE2,
        0x82,
        ...'"}'.codeUnits,
      ],
    );
    expectRejectedJson('JSON null', null);
    expectRejectedJson('a JSON list', [validAnnouncementJson()]);
    expectRejectedJson('a JSON string', 'hello');
    expectRejectedJson('a JSON number', 53530);
    expectRejectedBytes('deeply nested lists', utf8.encode('[' * 1000));
    expectRejectedBytes(
      'deeply nested valid lists',
      utf8.encode('${'[' * 500}${']' * 500}'),
    );

    expectRejectedJson(
      'a map without kind',
      validAnnouncementJson()..remove('kind'),
    );
    expectRejectedJson('kind "HELLO"', withValue('kind', 'HELLO'));
    expectRejectedJson('a numeric kind', withValue('kind', 0));
    expectRejectedJson('a null kind', withValue('kind', null));
    expectRejectedJson(
      'six keys where name is replaced by an unknown key',
      validAnnouncementJson()
        ..remove('name')
        ..['extra'] = 'x',
    );

    expectRejectedJson(
      'a fingerprint of 63 characters',
      withValue('fingerprint', validFingerprint.substring(1)),
    );
    expectRejectedJson(
      'a fingerprint of 65 characters',
      withValue('fingerprint', '${validFingerprint}A'),
    );
    expectRejectedJson(
      'a fingerprint with a non-hex character',
      withValue('fingerprint', '${validFingerprint.substring(1)}Z'),
    );
    expectRejectedJson('port 0', withValue('port', 0));
    expectRejectedJson('port 65536', withValue('port', 65536));
    expectRejectedBytes(
      'a double port written as 53530.0',
      utf8.encode(
        jsonEncode(validAnnouncementJson()).replaceFirst('53530', '53530.0'),
      ),
    );
    expectRejectedJson('a bool port', withValue('port', false));
    expectRejectedJson('protocol "1"', withValue('protocol', '1'));
    expectRejectedJson('protocol "1.0.0"', withValue('protocol', '1.0.0'));
    expectRejectedJson(
      'a huge major version',
      withValue('protocol', '123456789012345678901234567890.0'),
    );
    expectRejectedJson(
      'an unknown deviceType',
      withValue('deviceType', 'fridge'),
    );
    expectRejectedJson('a numeric deviceType', withValue('deviceType', 1));
    expectRejectedJson('a numeric name', withValue('name', 7));

    test('accepts a protocol of exactly 16 characters and rejects one of '
        '17 that still fits in a datagram (v2.6.10)', () {
      final sixteen = bytesOf(withValue('protocol', '1.${'0' * 14}'));
      final seventeen = bytesOf(withValue('protocol', '1.${'0' * 15}'));

      expect(seventeen.length, lessThan(maxDatagramBytes));
      expect(Announcement.tryDecode(sixteen)?.info.protocol, '1.${'0' * 14}');
      expect(Announcement.tryDecode(seventeen), isNull);
    });

    test('rejects the 5002-character protocol of the QA (v2.6.10)', () {
      expect(
        Announcement.tryDecode(
          bytesOf(withValue('protocol', '1.${'0' * 5000}')),
        ),
        isNull,
      );
    });

    test('accepts protocol "1.5" (same major, other minor)', () {
      final decoded = Announcement.tryDecode(
        bytesOf(withValue('protocol', '1.5')),
      );
      expect(decoded?.info.protocol, '1.5');
    });

    test('cleans the name of a received announcement', () {
      final decoded = Announcement.tryDecode(
        bytesOf(withValue('name', '  ${'n' * 70}\u0000  ')),
      );
      expect(decoded?.info.name, 'n' * 64);
    });

    test('a received name of only spaces is null', () {
      final decoded = Announcement.tryDecode(bytesOf(withValue('name', '   ')));
      expect(decoded, isNotNull);
      expect(decoded!.info.name, isNull);
    });
  });

  group('robustness: tryParse and tryDecode never throw', () {
    const iterations = 5000;
    final controlCharacters = RegExp(
      r'[\u0000-\u001F\u007F-\u009F\u2028\u2029\u200B-\u200F\u202A-\u202E'
      r'\u2060\u2066-\u2069\uFEFF]',
    );

    void expectValidInfo(DeviceInfo info, Object input) {
      expect(
        info.fingerprint,
        matches(RegExp(r'^[0-9A-F]{64}$')),
        reason: '$input',
      );
      expect(info.port, inInclusiveRange(1, 65535), reason: '$input');
      expect(info.protocol, matches(RegExp(r'^1\.\d+$')), reason: '$input');
      final name = info.name;
      if (name != null) {
        expect(name, isNotEmpty, reason: '$input');
        expect(name.runes.length, lessThanOrEqualTo(64), reason: '$input');
        expect(controlCharacters.hasMatch(name), isFalse, reason: '$input');
        expect(name, name.trimLeft(), reason: '$input');
      }
    }

    test('tryParse with random maps of mixed types', () {
      final random = Random(20261020);
      var accepted = 0;
      for (var i = 0; i < iterations; i++) {
        final input = randomMap(random, 0);
        final DeviceInfo? info;
        try {
          info = DeviceInfo.tryParse(input);
        } catch (error) {
          fail('tryParse threw $error for $input');
        }
        if (info != null) {
          accepted++;
          expectValidInfo(info, input);
        }
      }
      expect(accepted, greaterThan(0));
    });

    test('tryParse with arbitrary non-JSON objects', () {
      final inputs = <Object?>[
        Object(),
        DateTime(2026),
        Uint8List(8),
        const Duration(seconds: 1),
        {1: 'a', 2: 'b', 3: 'c', 4: 'd', 5: 'e'},
        {null: null},
        {
          'name': Object(),
          'fingerprint': validFingerprint,
          'port': 53530,
          'protocol': '1.0',
          'deviceType': 'desktop',
        },
        {
          'name': 'x',
          'fingerprint': validFingerprint,
          'port': BigInt.from(53530),
          'protocol': '1.0',
          'deviceType': DeviceType.desktop,
        },
        <Object?>{'a set'},
        double.nan,
        double.infinity,
      ];
      for (final input in inputs) {
        expect(
          () => DeviceInfo.tryParse(input),
          returnsNormally,
          reason: '$input',
        );
        expect(DeviceInfo.tryParse(input), isNull, reason: '$input');
      }
    });

    test('tryDecode with random bytes', () {
      final random = Random(53530);
      for (var i = 0; i < iterations; i++) {
        final bytes = Uint8List.fromList([
          for (var j = 0, n = random.nextInt(1100); j < n; j++)
            random.nextInt(256),
        ]);
        try {
          Announcement.tryDecode(bytes);
        } catch (error) {
          fail('tryDecode threw $error for ${base64.encode(bytes)}');
        }
      }
    });

    test('tryDecode with random JSON maps of mixed types', () {
      final random = Random(169);
      for (var i = 0; i < iterations; i++) {
        final input = randomMap(random, 0);
        final bytes = bytesOf(input);
        final Announcement? decoded;
        try {
          decoded = Announcement.tryDecode(bytes);
        } catch (error) {
          fail('tryDecode threw $error for $input');
        }
        if (decoded != null) {
          expectValidInfo(decoded.info, input);
          final again = Announcement.tryDecode(decoded.encode());
          expect(again, isNotNull, reason: '$input');
          expect(again!.kind, decoded.kind);
          expectSameInfo(again.info, decoded.info);
        }
      }
    });

    test('tryDecode with mutations of a valid datagram', () {
      final random = Random(224);
      final valid = Announcement(
        AnnouncementKind.hello,
        sampleInfo(name: 'Portátil 💻'),
      ).encode();
      for (var i = 0; i < iterations; i++) {
        final bytes = Uint8List.fromList(valid);
        final mutations = 1 + random.nextInt(4);
        for (var m = 0; m < mutations; m++) {
          bytes[random.nextInt(bytes.length)] = random.nextInt(256);
        }
        final cut = random.nextInt(4) == 0
            ? Uint8List.sublistView(bytes, 0, random.nextInt(bytes.length))
            : bytes;
        final Announcement? decoded;
        try {
          decoded = Announcement.tryDecode(cut);
        } catch (error) {
          fail('tryDecode threw $error for ${base64.encode(cut)}');
        }
        if (decoded != null) expectValidInfo(decoded.info, base64.encode(cut));
      }
    });
  });
}
