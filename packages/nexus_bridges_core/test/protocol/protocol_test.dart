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
  const pieces = ['a', 'Z', ' ', '\t', '\u0000', '\x7F', 'é', '😀', '💻'];
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
    final controlCharacters = RegExp(r'[\x00-\x1F\x7F]');

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
