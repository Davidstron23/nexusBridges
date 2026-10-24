import 'dart:convert';
import 'dart:typed_data';

import 'package:nexus_bridges_core/src/pairing_flow/messages.dart';
import 'package:nexus_bridges_core/src/protocol/protocol.dart';
import 'package:test/test.dart';

const String pem =
    '-----BEGIN CERTIFICATE-----\nAAAA\n-----END CERTIFICATE-----\n';

Uint8List seq(int start, int length) =>
    Uint8List.fromList([for (var i = 0; i < length; i++) (start + i) & 0xFF]);

String hexOf(List<int> bytes) =>
    bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

Map<String, Object?> startJson() => {
  'protocol': '1.0',
  'certificate': pem,
  'name': 'PC-DAVID',
  'deviceType': 'desktop',
  'commitment': hexOf(seq(0, 32)),
  'proof': hexOf(seq(100, 64)),
};

Map<String, Object?> startReplyJson() => {
  'session': hexOf(seq(10, 16)),
  'commitment': hexOf(seq(40, 32)),
};

Map<String, Object?> revealJson() => {
  'session': hexOf(seq(10, 16)),
  'nonce': hexOf(seq(70, 32)),
  'signature': hexOf(seq(150, 64)),
};

Map<String, Object?> revealReplyJson() => {'nonce': hexOf(seq(200, 32))};

Map<String, Object?> sessionJson() => {'session': hexOf(seq(10, 16))};

Map<String, Object?> cancelJson() => {
  'session': hexOf(seq(10, 16)),
  'reason': 'cancelled',
};

Map<String, Object?> stateJson() => {'state': 'pending'};

Map<String, Object?> statusJson() => {
  'certificate': pem,
  'challenge': hexOf(seq(90, 32)),
  'proof': hexOf(seq(5, 64)),
};

Map<String, Object?> statusReplyJson() => {'paired': true};

final class MessageCase {
  const MessageCase(this.name, this.valid, this.parse, this.hexBytes);

  final String name;
  final Map<String, Object?> Function() valid;
  final Object? Function(Object? json) parse;
  final Map<String, int> hexBytes;
}

final List<MessageCase> cases = [
  MessageCase('StartRequest', startJson, StartRequest.tryParse, {
    'commitment': 32,
    'proof': 64,
  }),
  MessageCase('StartReply', startReplyJson, StartReply.tryParse, {
    'session': 16,
    'commitment': 32,
  }),
  MessageCase('RevealRequest', revealJson, RevealRequest.tryParse, {
    'session': 16,
    'nonce': 32,
    'signature': 64,
  }),
  MessageCase('RevealReply', revealReplyJson, RevealReply.tryParse, {
    'nonce': 32,
  }),
  MessageCase('SessionRequest', sessionJson, SessionRequest.tryParse, {
    'session': 16,
  }),
  MessageCase('CancelRequest', cancelJson, CancelRequest.tryParse, {
    'session': 16,
  }),
  MessageCase('StateReply', stateJson, StateReply.tryParse, {}),
  MessageCase('StatusRequest', statusJson, StatusRequest.tryParse, {
    'challenge': 32,
    'proof': 64,
  }),
  MessageCase('StatusReply', statusReplyJson, StatusReply.tryParse, {}),
];

Map<String, Object?> withField(
  Map<String, Object?> json,
  String key,
  Object? value,
) => {...json, key: value};

Map<String, Object?> without(Map<String, Object?> json, String key) =>
    {...json}..remove(key);

String upperFirstLetter(String hex) {
  final index = hex.indexOf(RegExp('[a-f]'));
  if (index < 0) throw StateError('no letter in the sample');
  return hex.replaceRange(index, index + 1, hex[index].toUpperCase());
}

Object? throughJson(Map<String, Object?> json) => jsonDecode(jsonEncode(json));

Map<String, Object?> deviceInfoJson(Object? protocol) => {
  'name': 'PC-DAVID',
  'fingerprint': '0123456789ABCDEF' * 4,
  'port': 53530,
  'protocol': protocol,
  'deviceType': 'desktop',
};

void main() {
  group('the paused reply (RF-106b, D16)', () {
    test('the code is "paused" and only the exact body is a paused reply', () {
      expect(pausedErrorCode, 'paused');
      expect(isPausedReply({'error': 'paused'}), isTrue);
      expect(
        isPausedReply(jsonDecode('{"error":"paused"}') as Map<String, Object?>),
        isTrue,
      );
      for (final body in <Map<String, Object?>>[
        {},
        {'error': 'rate_limited'},
        {'error': 'rejected'},
        {'error': 'Paused'},
        {'error': 'paused', 'x': 1},
        {'error': 'paused', 'retryAfter': 600},
        {'state': 'paused'},
        {'error': null},
        {'error': 1},
      ]) {
        expect(isPausedReply(body), isFalse, reason: '$body');
      }
    });
  });

  group('every message (C39, RF-74, RF-75)', () {
    for (final c in cases) {
      group(c.name, () {
        test('the valid body parses, also after a JSON round trip', () {
          expect(c.parse(c.valid()), isNotNull);
          expect(c.parse(throughJson(c.valid())), isNotNull);
        });

        test('one key less gives null, for each key', () {
          for (final key in c.valid().keys) {
            expect(c.parse(without(c.valid(), key)), isNull, reason: key);
          }
        });

        test('one key more gives null', () {
          for (final (key, value) in [
            ('extra', 1),
            ('extra', null),
            ('Extra', 'x'),
            ('', ''),
          ]) {
            expect(
              c.parse(withField(c.valid(), key, value)),
              isNull,
              reason: key,
            );
          }
        });

        test('a renamed key with the same number of keys gives null', () {
          for (final key in c.valid().keys) {
            final json = without(c.valid(), key)
              ..[key.toUpperCase()] = c.valid()[key];
            expect(c.parse(json), isNull, reason: key);
            final spaced = without(c.valid(), key)..[' $key'] = c.valid()[key];
            expect(c.parse(spaced), isNull, reason: key);
          }
        });

        test('a key that is not a string gives null', () {
          final key = c.valid().keys.first;
          final json = <Object?, Object?>{...without(c.valid(), key), 1: 0};
          expect(c.parse(json), isNull);
        });

        test('anything that is not an object gives null', () {
          for (final value in <Object?>[
            null,
            <Object?>[],
            [c.valid()],
            'text',
            jsonEncode(c.valid()),
            42,
            1.5,
            true,
            <Object?, Object?>{},
          ]) {
            expect(c.parse(value), isNull, reason: '$value');
          }
        });

        test('each field with a value of the wrong type gives null', () {
          for (final key in c.valid().keys) {
            final original = c.valid()[key];
            final wrong = <Object?>[
              if (original is! bool) true,
              if (original is! num) 7,
              <Object?>[],
              <String, Object?>{},
              if (original is String) original.codeUnits,
              if (key != 'name') null,
            ];
            for (final value in wrong) {
              expect(
                c.parse(withField(c.valid(), key, value)),
                isNull,
                reason: '$key = $value',
              );
            }
          }
        });

        for (final MapEntry(key: field, value: bytes) in c.hexBytes.entries) {
          test('$field: lowercase hex of exactly $bytes bytes, nothing '
              'else', () {
            final good = c.valid()[field]! as String;
            final bad = <String>[
              good.toUpperCase(),
              '${good.substring(0, good.length - 1)}A',
              upperFirstLetter(good),
              good.substring(1),
              '${good}0',
              good.substring(2),
              '${good}00',
              '$good$good',
              '',
              '${good.substring(0, good.length - 1)}g',
              ' ${good.substring(1)}',
              '0x${good.substring(2)}',
              '${good.substring(0, good.length - 1)}\uFF10',
            ];

            expect(good, hasLength(bytes * 2));
            for (final value in bad) {
              expect(
                c.parse(withField(c.valid(), field, value)),
                isNull,
                reason: value,
              );
            }
          });
        }
      });
    }
  });

  group('StartRequest (C39)', () {
    test('reads every field, binaries as Uint8List', () {
      final m = StartRequest.tryParse(startJson())!;

      expect(m.certificate, pem);
      expect(m.name, 'PC-DAVID');
      expect(m.deviceType, DeviceType.desktop);
      expect(m.commitment, isA<Uint8List>());
      expect(m.commitment, seq(0, 32));
      expect(m.proof, isA<Uint8List>());
      expect(m.proof, seq(100, 64));
    });

    test('toJson has exactly the keys of the format, protocolVersion and '
        'lowercase hex, and parses back', () {
      final m = StartRequest(
        certificate: pem,
        name: null,
        deviceType: DeviceType.mobile,
        commitment: seq(0xF0, 32),
        proof: seq(0xA0, 64),
      );
      final json = m.toJson();

      expect(json.keys.toSet(), {
        'protocol',
        'certificate',
        'name',
        'deviceType',
        'commitment',
        'proof',
      });
      expect(json['protocol'], protocolVersion);
      expect(json['name'], isNull);
      expect(json['deviceType'], 'mobile');
      expect(json['commitment'], hexOf(seq(0xF0, 32)));
      expect(json['proof'], hexOf(seq(0xA0, 64)));
      expect(json['commitment'], (json['commitment']! as String).toLowerCase());

      final back = StartRequest.tryParse(throughJson(json))!;
      expect(back.name, isNull);
      expect(back.deviceType, DeviceType.mobile);
      expect(back.commitment, seq(0xF0, 32));
      expect(back.proof, seq(0xA0, 64));
    });

    test('name may be null, empty, or up to 256 UTF-16 units', () {
      for (final name in [
        null,
        '',
        'a',
        'a' * 256,
        '\u{1F600}' * 128,
        '${'a' * 254}\u{1F600}',
      ]) {
        final m = StartRequest.tryParse(withField(startJson(), 'name', name));
        expect(m, isNotNull, reason: '${name?.length}');
        expect(m!.name, name);
      }
    });

    test('a name of 257 UTF-16 units or more gives null', () {
      for (final name in [
        'a' * 257,
        'a' * 1000,
        '\u{1F600}' * 129,
        '${'a' * 255}\u{1F600}',
      ]) {
        expect(
          StartRequest.tryParse(withField(startJson(), 'name', name)),
          isNull,
          reason: '${name.length}',
        );
      }
    });

    test('the name is kept as sent, without sanitizing, because the proof '
        'signs it as is', () {
      const raw = '  \u202EPC\u200B-DAVID\u0000 ';
      final m = StartRequest.tryParse(withField(startJson(), 'name', raw))!;

      expect(m.name, raw);
    });

    test('deviceType must be the exact name of a value', () {
      for (final type in ['desktop', 'mobile']) {
        expect(
          StartRequest.tryParse(withField(startJson(), 'deviceType', type))
              ?.deviceType
              .name,
          type,
        );
      }
      for (final type in ['Desktop', 'MOBILE', 'tablet', '', ' desktop', '0']) {
        expect(
          StartRequest.tryParse(withField(startJson(), 'deviceType', type)),
          isNull,
          reason: type,
        );
      }
    });

    test('a certificate of up to 4096 characters is accepted as text and a '
        'longer one gives null', () {
      expect(
        StartRequest.tryParse(withField(startJson(), 'certificate', 'c' * 4096))
            ?.certificate,
        'c' * 4096,
      );
      expect(
        StartRequest.tryParse(
          withField(startJson(), 'certificate', 'c' * 4097),
        ),
        isNull,
      );
    });

    test('protocol 1.x is accepted and other major versions give null', () {
      for (final protocol in ['1.0', '1.1', '1.99']) {
        expect(
          StartRequest.tryParse(withField(startJson(), 'protocol', protocol)),
          isNotNull,
          reason: protocol,
        );
      }
      for (final protocol in ['2.0', '0.9', '10.0', '11.0']) {
        expect(
          StartRequest.tryParse(withField(startJson(), 'protocol', protocol)),
          isNull,
          reason: protocol,
        );
      }
    });

    test('protocol follows exactly the same rules as DeviceInfo', () {
      final values = <Object?>[
        '1.0',
        '1.5',
        '01.0',
        '1.00000000000000',
        '1.000000000000000',
        '2.0',
        '0.1',
        '1',
        '1.',
        '.1',
        '1.0.0',
        'v1.0',
        ' 1.0',
        '1.0 ',
        '1.0\n',
        '1,0',
        '-1.0',
        '+1.0',
        '\uFF11.0',
        '\u0661.0',
        '',
        1.0,
        1,
        null,
        true,
        ['1.0'],
      ];
      for (final value in values) {
        final asDevice = DeviceInfo.tryParse(deviceInfoJson(value)) != null;
        final asStart =
            StartRequest.tryParse(withField(startJson(), 'protocol', value)) !=
            null;
        expect(asStart, asDevice, reason: '$value');
      }
    });
  });

  group('StartReply (C39)', () {
    test('reads and writes session and commitment', () {
      final m = StartReply.tryParse(startReplyJson())!;
      expect(m.session, seq(10, 16));
      expect(m.commitment, seq(40, 32));
      expect(m.toJson(), startReplyJson());
    });
  });

  group('RevealRequest (C39)', () {
    test('reads and writes session, nonce and signature', () {
      final m = RevealRequest.tryParse(revealJson())!;
      expect(m.session, seq(10, 16));
      expect(m.nonce, seq(70, 32));
      expect(m.signature, seq(150, 64));
      expect(m.toJson(), revealJson());
    });
  });

  group('RevealReply (C39)', () {
    test('reads and writes the nonce', () {
      final m = RevealReply.tryParse(revealReplyJson())!;
      expect(m.nonce, seq(200, 32));
      expect(m.toJson(), revealReplyJson());
    });
  });

  group('SessionRequest (C39)', () {
    test('reads and writes the session', () {
      final m = SessionRequest.tryParse(sessionJson())!;
      expect(m.session, isA<Uint8List>());
      expect(m.session, seq(10, 16));
      expect(m.toJson(), sessionJson());
    });
  });

  group('CancelRequest (C39)', () {
    test('requires a reason and reads both values', () {
      for (final reason in CancelReason.values) {
        final json = withField(cancelJson(), 'reason', reason.name);
        final m = CancelRequest.tryParse(json)!;
        expect(m.reason, reason);
        expect(m.session, seq(10, 16));
        expect(m.toJson(), json);
      }
      expect(CancelRequest.tryParse(sessionJson()), isNull);
    });

    test('an unknown reason gives null', () {
      for (final reason in ['Cancelled', 'EXPIRED', 'other', '', 'lost']) {
        expect(
          CancelRequest.tryParse(withField(cancelJson(), 'reason', reason)),
          isNull,
          reason: reason,
        );
      }
    });

    test('the reasons are exactly cancelled and expired', () {
      expect(CancelReason.values.map((r) => r.name), ['cancelled', 'expired']);
    });
  });

  group('StateReply (C39)', () {
    test('reads and writes the four states', () {
      expect(RemoteState.values.map((s) => s.name), [
        'pending',
        'paired',
        'cancelled',
        'expired',
      ]);
      for (final state in RemoteState.values) {
        final json = {'state': state.name};
        expect(StateReply.tryParse(json)?.state, state);
        expect(StateReply(state: state).toJson(), json);
      }
    });

    test('an unknown state gives null', () {
      for (final state in ['Pending', 'unknown', 'busy', '', 'paired ']) {
        expect(StateReply.tryParse({'state': state}), isNull, reason: state);
      }
    });
  });

  group('StatusRequest (C39)', () {
    test('reads and writes certificate, challenge and proof', () {
      final m = StatusRequest.tryParse(statusJson())!;
      expect(m.certificate, pem);
      expect(m.challenge, seq(90, 32));
      expect(m.proof, seq(5, 64));
      expect(m.toJson(), statusJson());
    });

    test('a certificate of more than 4096 characters gives null', () {
      expect(
        StatusRequest.tryParse(
          withField(statusJson(), 'certificate', 'c' * 4096),
        ),
        isNotNull,
      );
      expect(
        StatusRequest.tryParse(
          withField(statusJson(), 'certificate', 'c' * 4097),
        ),
        isNull,
      );
    });
  });

  group('StatusReply (C39)', () {
    test('reads and writes true and false', () {
      for (final paired in [true, false]) {
        expect(StatusReply.tryParse({'paired': paired})?.paired, paired);
        expect(StatusReply(paired: paired).toJson(), {'paired': paired});
      }
    });

    test('anything that is not a bool gives null', () {
      for (final value in <Object?>['true', 'false', 1, 0, null, 'yes']) {
        expect(
          StatusReply.tryParse({'paired': value}),
          isNull,
          reason: '$value',
        );
      }
    });
  });

  group('toJson keys follow the format of the plan', () {
    test('each message writes exactly its keys', () {
      expect(
        StartReply(session: seq(0, 16), commitment: seq(0, 32)).toJson().keys,
        {'session', 'commitment'},
      );
      expect(
        RevealRequest(
          session: seq(0, 16),
          nonce: seq(0, 32),
          signature: seq(0, 64),
        ).toJson().keys,
        {'session', 'nonce', 'signature'},
      );
      expect(RevealReply(nonce: seq(0, 32)).toJson().keys, {'nonce'});
      expect(SessionRequest(session: seq(0, 16)).toJson().keys, {'session'});
      expect(
        CancelRequest(
          session: seq(0, 16),
          reason: CancelReason.expired,
        ).toJson(),
        {'session': hexOf(seq(0, 16)), 'reason': 'expired'},
      );
      expect(
        StatusRequest(
          certificate: pem,
          challenge: seq(0, 32),
          proof: seq(0, 64),
        ).toJson().keys,
        {'certificate', 'challenge', 'proof'},
      );
    });
  });
}
