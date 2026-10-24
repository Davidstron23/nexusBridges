import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:nexus_bridges_core/src/pairing_flow/crypto.dart';
import 'package:nexus_bridges_core/src/pairing_flow/pairing_flow.dart';
import 'package:nexus_bridges_core/src/protocol/protocol.dart';
import 'package:test/test.dart';

final String printI = '0123456789ABCDEF' * 4;
final String printR = 'FEDCBA9876543210' * 4;

const String initiatorCommitmentVector =
    'd4f1ecf31ead8b69835a2758d172d36fcbcdaa3c9e85a483d555922d65c8a23c';
const String receiverCommitmentVector =
    '9f8a6514f0ebc921fdee9eb89a56be3462052847348c3749c011b8495c01299a';
const String codeVector = '269423';
const String leadingZeroCodeVector = '000648';
const String startDigestVector =
    '65d065c95268cb9820ee57b4cb46b45251ffde2997637833d39ba0b79273f340';
const String revealDigestVector =
    '694d8687b6ba531d7df7ab01cb5fdc013b0bb51ae17a9ab523e111eed9da1ea0';
const String statusDigestVector =
    'fe8ff77ba6853ed8906c5acc02e4ae7c8b6313ca0a95f673ae46b7ff16a15e71';

final Random rng = Random(20261024);

Uint8List seq(int start, int length) =>
    Uint8List.fromList([for (var i = 0; i < length; i++) (start + i) & 0xFF]);

Uint8List filled(int value, int length) =>
    Uint8List.fromList(List<int>.filled(length, value));

Uint8List randomData(int length) =>
    Uint8List.fromList([for (var i = 0; i < length; i++) rng.nextInt(256)]);

String randomPrint() =>
    [for (var i = 0; i < 64; i++) '0123456789ABCDEF'[rng.nextInt(16)]].join();

String hexOf(List<int> bytes) =>
    bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

Uint8List bytesOfPrint(String fp) => Uint8List.fromList([
  for (var i = 0; i < fp.length; i += 2)
    int.parse(fp.substring(i, i + 2), radix: 16),
]);

Uint8List label(String text) => Uint8List.fromList([...ascii.encode(text), 0]);

Uint8List joined(List<List<int>> parts) =>
    Uint8List.fromList([for (final part in parts) ...part]);

Uint8List digestOf(List<List<int>> parts) =>
    Uint8List.fromList(sha256.convert(joined(parts)).bytes);

Uint8List manualCommitment(int role, String fp, List<int> nonce) => digestOf([
  label('NexusBridges pair commit v1'),
  [role],
  bytesOfPrint(fp),
  nonce,
]);

String manualCode(String fpI, String fpR, List<int> ni, List<int> nr) {
  final h = digestOf([
    label('NexusBridges pair code v1'),
    bytesOfPrint(fpI),
    bytesOfPrint(fpR),
    ni,
    nr,
  ]);
  var value = BigInt.zero;
  for (var i = 0; i < 7; i++) {
    value = (value << 8) + BigInt.from(h[i]);
  }
  return (value % BigInt.from(1000000)).toString().padLeft(6, '0');
}

String flipChar(String fp, int index) {
  final current = fp[index];
  final replacement = current == '0' ? '1' : '0';
  return fp.replaceRange(index, index + 1, replacement);
}

Uint8List flipBit(Uint8List bytes, int index, [int bit = 0]) {
  final copy = Uint8List.fromList(bytes);
  copy[index] ^= 1 << bit;
  return copy;
}

Matcher argumentErrorWithout(String content) => throwsA(
  isA<ArgumentError>().having(
    (e) => e.toString(),
    'text',
    isNot(contains(content)),
  ),
);

void main() {
  group('commitment (C32, RF-77, SEC-13)', () {
    test('the initiator commitment equals the fixed vector of the plan '
        'formula', () {
      final c = commitmentOf(
        role: PairingRole.initiator,
        fingerprint: printI,
        nonce: seq(0, 32),
      );

      expect(c, isA<Uint8List>());
      expect(c.length, 32);
      expect(hexOf(c), initiatorCommitmentVector);
      expect(c, manualCommitment(1, printI, seq(0, 32)));
    });

    test(
      'the receiver commitment equals the fixed vector with role byte 2',
      () {
        final c = commitmentOf(
          role: PairingRole.receiver,
          fingerprint: printR,
          nonce: seq(32, 32),
        );

        expect(hexOf(c), receiverCommitmentVector);
        expect(c, manualCommitment(2, printR, seq(32, 32)));
      },
    );

    test('random inputs agree with the formula recomputed in the test', () {
      for (var i = 0; i < 200; i++) {
        final fp = randomPrint();
        final nonce = randomData(32);
        final role = i.isEven ? PairingRole.initiator : PairingRole.receiver;

        expect(
          commitmentOf(role: role, fingerprint: fp, nonce: nonce),
          manualCommitment(i.isEven ? 1 : 2, fp, nonce),
          reason: 'trial $i',
        );
      }
    });

    test('the same inputs always give the same commitment', () {
      final nonce = randomData(32);
      final first = commitmentOf(
        role: PairingRole.initiator,
        fingerprint: printI,
        nonce: nonce,
      );
      final second = commitmentOf(
        role: PairingRole.initiator,
        fingerprint: printI,
        nonce: Uint8List.fromList(nonce),
      );

      expect(second, first);
    });

    test('its own nonce matches, in both roles and with random inputs', () {
      for (var i = 0; i < 100; i++) {
        final fp = randomPrint();
        final nonce = randomData(32);
        for (final role in PairingRole.values) {
          final c = commitmentOf(role: role, fingerprint: fp, nonce: nonce);
          expect(
            commitmentMatches(c, role: role, fingerprint: fp, nonce: nonce),
            isTrue,
            reason: 'trial $i $role',
          );
        }
      }
    });

    test('another nonce does not match: one bit changed in any of the 32 '
        'bytes', () {
      final nonce = randomData(32);
      final c = commitmentOf(
        role: PairingRole.initiator,
        fingerprint: printI,
        nonce: nonce,
      );
      for (var index = 0; index < 32; index++) {
        for (final bit in [0, 7]) {
          expect(
            commitmentMatches(
              c,
              role: PairingRole.initiator,
              fingerprint: printI,
              nonce: flipBit(nonce, index, bit),
            ),
            isFalse,
            reason: 'byte $index bit $bit',
          );
        }
      }
      expect(
        commitmentMatches(
          c,
          role: PairingRole.initiator,
          fingerprint: printI,
          nonce: randomData(32),
        ),
        isFalse,
      );
    });

    test('another role does not match', () {
      final nonce = randomData(32);
      final ci = commitmentOf(
        role: PairingRole.initiator,
        fingerprint: printI,
        nonce: nonce,
      );
      final cr = commitmentOf(
        role: PairingRole.receiver,
        fingerprint: printI,
        nonce: nonce,
      );

      expect(
        commitmentMatches(
          ci,
          role: PairingRole.receiver,
          fingerprint: printI,
          nonce: nonce,
        ),
        isFalse,
      );
      expect(
        commitmentMatches(
          cr,
          role: PairingRole.initiator,
          fingerprint: printI,
          nonce: nonce,
        ),
        isFalse,
      );
    });

    test('another fingerprint does not match: any of the 64 hex digits '
        'changed', () {
      final nonce = randomData(32);
      final c = commitmentOf(
        role: PairingRole.receiver,
        fingerprint: printR,
        nonce: nonce,
      );
      for (var index = 0; index < 64; index++) {
        expect(
          commitmentMatches(
            c,
            role: PairingRole.receiver,
            fingerprint: flipChar(printR, index),
            nonce: nonce,
          ),
          isFalse,
          reason: 'digit $index',
        );
      }
      expect(
        commitmentMatches(
          c,
          role: PairingRole.receiver,
          fingerprint: printI,
          nonce: nonce,
        ),
        isFalse,
      );
    });

    test('domain separation: the same nonce with another role or another '
        'fingerprint gives another commitment', () {
      final nonce = seq(0, 32);
      final all = {
        hexOf(
          commitmentOf(
            role: PairingRole.initiator,
            fingerprint: printI,
            nonce: nonce,
          ),
        ),
        hexOf(
          commitmentOf(
            role: PairingRole.receiver,
            fingerprint: printI,
            nonce: nonce,
          ),
        ),
        hexOf(
          commitmentOf(
            role: PairingRole.initiator,
            fingerprint: printR,
            nonce: nonce,
          ),
        ),
        hexOf(
          commitmentOf(
            role: PairingRole.receiver,
            fingerprint: printR,
            nonce: nonce,
          ),
        ),
      };

      expect(all, hasLength(4));
    });

    test('the commitment is not a plain hash of the same bytes without the '
        'label or without its 0x00', () {
      final nonce = seq(0, 32);
      final c = commitmentOf(
        role: PairingRole.initiator,
        fingerprint: printI,
        nonce: nonce,
      );
      final tail = [
        [1],
        bytesOfPrint(printI),
        nonce,
      ];

      expect(c, isNot(digestOf(tail)));
      expect(
        c,
        isNot(digestOf([ascii.encode('NexusBridges pair commit v1'), ...tail])),
      );
      expect(c, isNot(digestOf([label('NexusBridges pair code v1'), ...tail])));
    });

    test('reflection: the receiver commitment sent back as if it were the '
        'initiator one is rejected', () {
      final nr = randomData(32);
      final cr = commitmentOf(
        role: PairingRole.receiver,
        fingerprint: printR,
        nonce: nr,
      );

      for (final fp in [printR, printI]) {
        expect(
          commitmentMatches(
            cr,
            role: PairingRole.initiator,
            fingerprint: fp,
            nonce: nr,
          ),
          isFalse,
        );
      }
    });

    test('the comparison checks all 32 bytes: one bit changed in any byte of '
        'the commitment is rejected', () {
      final nonce = randomData(32);
      final c = commitmentOf(
        role: PairingRole.initiator,
        fingerprint: printI,
        nonce: nonce,
      );
      for (var index = 0; index < 32; index++) {
        for (final bit in [0, 3, 7]) {
          expect(
            commitmentMatches(
              flipBit(c, index, bit),
              role: PairingRole.initiator,
              fingerprint: printI,
              nonce: nonce,
            ),
            isFalse,
            reason: 'byte $index bit $bit',
          );
        }
      }
    });

    test('a commitment of any length other than 32 is rejected without '
        'throwing, also prefixes and extensions of the right one', () {
      final nonce = randomData(32);
      final c = commitmentOf(
        role: PairingRole.initiator,
        fingerprint: printI,
        nonce: nonce,
      );
      for (var length = 0; length <= 96; length++) {
        final candidate = Uint8List(length)..setRange(0, min(length, 32), c);
        final matches = commitmentMatches(
          candidate,
          role: PairingRole.initiator,
          fingerprint: printI,
          nonce: nonce,
        );

        expect(matches, length == 32, reason: 'length $length');
      }
    });

    test(
      'a nonce of any length other than 32 is rejected without throwing',
      () {
        final nonce = randomData(32);
        final c = commitmentOf(
          role: PairingRole.initiator,
          fingerprint: printI,
          nonce: nonce,
        );
        for (final length in [0, 1, 16, 31, 33, 64]) {
          final candidate = Uint8List(length)
            ..setRange(0, min(length, 32), nonce);

          expect(
            commitmentMatches(
              c,
              role: PairingRole.initiator,
              fingerprint: printI,
              nonce: candidate,
            ),
            isFalse,
            reason: 'length $length',
          );
        }
      },
    );

    test('commitmentOf with a nonce of the wrong length throws an '
        'ArgumentError that does not carry the nonce', () {
      final nonce = filled(0xAB, 31);

      expect(
        () => commitmentOf(
          role: PairingRole.initiator,
          fingerprint: printI,
          nonce: nonce,
        ),
        argumentErrorWithout('abab'),
      );
      expect(
        () => commitmentOf(
          role: PairingRole.initiator,
          fingerprint: printI,
          nonce: filled(0xAB, 33),
        ),
        throwsArgumentError,
      );
    });

    test(
      'commitmentOf with a malformed fingerprint throws FormatException',
      () {
        expect(
          () => commitmentOf(
            role: PairingRole.initiator,
            fingerprint: printI.toLowerCase(),
            nonce: seq(0, 32),
          ),
          throwsFormatException,
        );
      },
    );
  });

  group('pairing code (C33, RF-77)', () {
    test('the same inputs twice give the same code', () {
      final ni = randomData(32);
      final nr = randomData(32);

      expect(
        pairingCode(
          initiatorFingerprint: printI,
          receiverFingerprint: printR,
          initiatorNonce: ni,
          receiverNonce: nr,
        ),
        pairingCode(
          initiatorFingerprint: printI,
          receiverFingerprint: printR,
          initiatorNonce: Uint8List.fromList(ni),
          receiverNonce: Uint8List.fromList(nr),
        ),
      );
    });

    test('equals the fixed vector of the plan formula', () {
      final code = pairingCode(
        initiatorFingerprint: printI,
        receiverFingerprint: printR,
        initiatorNonce: seq(0, 32),
        receiverNonce: seq(32, 32),
      );

      expect(code, codeVector);
      expect(code, manualCode(printI, printR, seq(0, 32), seq(32, 32)));
    });

    test('keeps the leading zeros: fixed vector 000648', () {
      final code = pairingCode(
        initiatorFingerprint: printI,
        receiverFingerprint: printR,
        initiatorNonce: filled(65, 32),
        receiverNonce: seq(32, 32),
      );

      expect(code, leadingZeroCodeVector);
      expect(code, hasLength(6));
    });

    test('256 vectors agree with the formula recomputed with BigInt', () {
      for (var i = 0; i < 256; i++) {
        final ni = filled(i, 32);
        expect(
          pairingCode(
            initiatorFingerprint: printI,
            receiverFingerprint: printR,
            initiatorNonce: ni,
            receiverNonce: seq(32, 32),
          ),
          manualCode(printI, printR, ni, seq(32, 32)),
          reason: 'nonce $i',
        );
      }
    });

    test('random inputs agree with the formula, with random fingerprints', () {
      for (var i = 0; i < 300; i++) {
        final fpI = randomPrint();
        final fpR = randomPrint();
        final ni = randomData(32);
        final nr = randomData(32);

        expect(
          pairingCode(
            initiatorFingerprint: fpI,
            receiverFingerprint: fpR,
            initiatorNonce: ni,
            receiverNonce: nr,
          ),
          manualCode(fpI, fpR, ni, nr),
          reason: 'trial $i',
        );
      }
    });

    test('the order of the inputs matters: swapped fingerprints or swapped '
        'nonces give another code', () {
      final straight = pairingCode(
        initiatorFingerprint: printI,
        receiverFingerprint: printR,
        initiatorNonce: seq(0, 32),
        receiverNonce: seq(32, 32),
      );

      expect(
        pairingCode(
          initiatorFingerprint: printR,
          receiverFingerprint: printI,
          initiatorNonce: seq(0, 32),
          receiverNonce: seq(32, 32),
        ),
        isNot(straight),
      );
      expect(
        pairingCode(
          initiatorFingerprint: printI,
          receiverFingerprint: printR,
          initiatorNonce: seq(32, 32),
          receiverNonce: seq(0, 32),
        ),
        isNot(straight),
      );
    });

    test('10000 trials changing one input change the code in more than '
        '99.9 %', () {
      var changed = 0;
      for (var trial = 0; trial < 10000; trial++) {
        final fpI = randomPrint();
        final fpR = randomPrint();
        final ni = randomData(32);
        final nr = randomData(32);
        final base = pairingCode(
          initiatorFingerprint: fpI,
          receiverFingerprint: fpR,
          initiatorNonce: ni,
          receiverNonce: nr,
        );
        final position = rng.nextInt(32);
        final other = switch (trial % 4) {
          0 => pairingCode(
            initiatorFingerprint: flipChar(fpI, rng.nextInt(64)),
            receiverFingerprint: fpR,
            initiatorNonce: ni,
            receiverNonce: nr,
          ),
          1 => pairingCode(
            initiatorFingerprint: fpI,
            receiverFingerprint: flipChar(fpR, rng.nextInt(64)),
            initiatorNonce: ni,
            receiverNonce: nr,
          ),
          2 => pairingCode(
            initiatorFingerprint: fpI,
            receiverFingerprint: fpR,
            initiatorNonce: flipBit(ni, position, rng.nextInt(8)),
            receiverNonce: nr,
          ),
          _ => pairingCode(
            initiatorFingerprint: fpI,
            receiverFingerprint: fpR,
            initiatorNonce: ni,
            receiverNonce: flipBit(nr, position, rng.nextInt(8)),
          ),
        };
        if (other != base) changed++;
      }

      expect(changed, greaterThan(9990));
    });

    test('200000 random codes have six digits, zeros on the left and the '
        'first digit between 9.5 % and 10.5 % for every digit', () {
      final firstDigits = List<int>.filled(10, 0);
      final pattern = RegExp(r'^[0-9]{6}$');
      var belowHundredThousand = 0;
      var malformed = 0;
      for (var i = 0; i < 200000; i++) {
        final code = pairingCode(
          initiatorFingerprint: printI,
          receiverFingerprint: printR,
          initiatorNonce: randomData(32),
          receiverNonce: randomData(32),
        );
        if (!pattern.hasMatch(code)) malformed++;
        firstDigits[code.codeUnitAt(0) - 0x30]++;
        if (code.startsWith('0')) belowHundredThousand++;
      }

      expect(malformed, 0);
      expect(belowHundredThousand, greaterThan(0));
      for (var digit = 0; digit < 10; digit++) {
        final share = firstDigits[digit] / 200000;
        expect(share, inInclusiveRange(0.095, 0.105), reason: 'digit $digit');
      }
    });

    test('nonces of the wrong length throw an ArgumentError that does not '
        'carry them', () {
      expect(
        () => pairingCode(
          initiatorFingerprint: printI,
          receiverFingerprint: printR,
          initiatorNonce: filled(0xCD, 31),
          receiverNonce: seq(32, 32),
        ),
        argumentErrorWithout('cdcd'),
      );
      expect(
        () => pairingCode(
          initiatorFingerprint: printI,
          receiverFingerprint: printR,
          initiatorNonce: seq(0, 32),
          receiverNonce: filled(0xCD, 33),
        ),
        argumentErrorWithout('cdcd'),
      );
    });

    test('a malformed fingerprint throws FormatException', () {
      expect(
        () => pairingCode(
          initiatorFingerprint: printI.substring(1),
          receiverFingerprint: printR,
          initiatorNonce: seq(0, 32),
          receiverNonce: seq(32, 32),
        ),
        throwsFormatException,
      );
      expect(
        () => pairingCode(
          initiatorFingerprint: printI,
          receiverFingerprint: printR.toLowerCase(),
          initiatorNonce: seq(0, 32),
          receiverNonce: seq(32, 32),
        ),
        throwsFormatException,
      );
    });
  });

  group('transcripts (RF-80, SEC-14)', () {
    final ci = bytesOfPrint(initiatorCommitmentVector.toUpperCase());
    final cr = bytesOfPrint(receiverCommitmentVector.toUpperCase());
    const name = 'PC-Ñandú €';

    Uint8List start({
      String? name = name,
      DeviceType type = DeviceType.mobile,
    }) => startTranscript(
      initiatorFingerprint: printI,
      receiverFingerprint: printR,
      name: name,
      deviceType: type,
      initiatorCommitment: ci,
    );

    test('the start transcript has the exact layout of the plan and the fixed '
        'digest', () {
      final nameBytes = utf8.encode(name);
      final expected = joined([
        label('NexusBridges pair start v1'),
        bytesOfPrint(printI),
        bytesOfPrint(printR),
        [0, nameBytes.length],
        nameBytes,
        [1],
        ci,
      ]);

      final t = start();

      expect(nameBytes.length, 14);
      expect(t, expected);
      expect(t.length, 140);
      expect(sha256.convert(t).toString(), startDigestVector);
    });

    test('the name length counts UTF-8 bytes, not UTF-16 units', () {
      final t = start(name: '€');
      final offset = label('NexusBridges pair start v1').length + 64;

      expect(t.sublist(offset, offset + 2), [0, 3]);
      expect(t.sublist(offset + 2, offset + 5), utf8.encode('€'));
    });

    test('a null name signs the same bytes as the empty name', () {
      final offset = label('NexusBridges pair start v1').length + 64;

      expect(start(name: null), start(name: ''));
      expect(start(name: null).sublist(offset, offset + 3), [0, 0, 1]);
    });

    test('desktop is byte 0 and mobile byte 1, just before the commitment', () {
      final desktop = start(type: DeviceType.desktop);
      final mobile = start(type: DeviceType.mobile);

      expect(desktop[desktop.length - 33], 0);
      expect(mobile[mobile.length - 33], 1);
      expect(desktop.sublist(desktop.length - 32), ci);
    });

    test('the name length is a big-endian u16', () {
      final offset = label('NexusBridges pair start v1').length + 64;

      expect(start(name: 'a' * 300).sublist(offset, offset + 2), [0x01, 0x2C]);
      expect(start(name: 'é' * 256).sublist(offset, offset + 2), [0x02, 0x00]);
      expect(start(name: 'a' * 255).sublist(offset, offset + 2), [0x00, 0xFF]);
    });

    test('the length prefix keeps apart names that would share bytes', () {
      expect(start(name: 'AB'), isNot(start(name: 'A')));
      expect(start(name: 'AB').length, start(name: 'A').length + 1);
    });

    test('a name of 65535 UTF-8 bytes fits and one of 65536 throws an '
        'ArgumentError that does not carry the name', () {
      final offset = label('NexusBridges pair start v1').length + 64;

      expect(start(name: 'x' * 65535).sublist(offset, offset + 2), [
        0xFF,
        0xFF,
      ]);
      expect(() => start(name: 'q' * 65536), argumentErrorWithout('qqqq'));
    });

    test('the receiver fingerprint is bound: a start meant for R1 differs from '
        'one meant for R2', () {
      final other = startTranscript(
        initiatorFingerprint: printI,
        receiverFingerprint: flipChar(printR, 63),
        name: name,
        deviceType: DeviceType.mobile,
        initiatorCommitment: ci,
      );

      expect(other, isNot(start()));
    });

    test('a commitment of the wrong length throws ArgumentError', () {
      for (final length in [0, 31, 33]) {
        expect(
          () => startTranscript(
            initiatorFingerprint: printI,
            receiverFingerprint: printR,
            name: name,
            deviceType: DeviceType.desktop,
            initiatorCommitment: Uint8List(length),
          ),
          throwsArgumentError,
          reason: 'length $length',
        );
      }
    });

    test('a malformed fingerprint throws FormatException', () {
      expect(
        () => startTranscript(
          initiatorFingerprint: printI.toLowerCase(),
          receiverFingerprint: printR,
          name: name,
          deviceType: DeviceType.desktop,
          initiatorCommitment: ci,
        ),
        throwsFormatException,
      );
    });

    test('the reveal transcript has the exact layout of the plan and the '
        'fixed digest', () {
      final s = start();
      final t = revealTranscript(
        startTranscript: s,
        sessionId: seq(0, 16),
        receiverCommitment: cr,
        initiatorNonce: seq(0, 32),
      );

      expect(
        t,
        joined([
          label('NexusBridges pair reveal v1'),
          sha256.convert(s).bytes,
          seq(0, 16),
          cr,
          seq(0, 32),
        ]),
      );
      expect(t.length, 140);
      expect(sha256.convert(t).toString(), revealDigestVector);
    });

    test('the reveal transcript is bound to the session and to the start', () {
      final s = start();
      Uint8List reveal(Uint8List startBytes, Uint8List session) =>
          revealTranscript(
            startTranscript: startBytes,
            sessionId: session,
            receiverCommitment: cr,
            initiatorNonce: seq(0, 32),
          );

      expect(reveal(s, seq(0, 16)), isNot(reveal(s, seq(1, 16))));
      expect(
        reveal(s, seq(0, 16)),
        isNot(reveal(start(name: 'otro'), seq(0, 16))),
      );
    });

    test('the reveal transcript rejects wrong lengths with ArgumentError', () {
      final s = start();
      for (final (session, commitment, nonce) in [
        (15, 32, 32),
        (17, 32, 32),
        (16, 31, 32),
        (16, 33, 32),
        (16, 32, 31),
        (16, 32, 33),
      ]) {
        expect(
          () => revealTranscript(
            startTranscript: s,
            sessionId: Uint8List(session),
            receiverCommitment: Uint8List(commitment),
            initiatorNonce: Uint8List(nonce),
          ),
          throwsArgumentError,
          reason: '$session $commitment $nonce',
        );
      }
    });

    test('the status transcript has the exact layout of the plan and the '
        'fixed digest', () {
      final t = statusTranscript(
        callerFingerprint: printI,
        serverFingerprint: printR,
        challenge: seq(64, 32),
      );

      expect(
        t,
        joined([
          label('NexusBridges pair status v1'),
          bytesOfPrint(printI),
          bytesOfPrint(printR),
          seq(64, 32),
        ]),
      );
      expect(t.length, 124);
      expect(sha256.convert(t).toString(), statusDigestVector);
    });

    test('the status transcript depends on who asks and who answers', () {
      final straight = statusTranscript(
        callerFingerprint: printI,
        serverFingerprint: printR,
        challenge: seq(64, 32),
      );
      final swapped = statusTranscript(
        callerFingerprint: printR,
        serverFingerprint: printI,
        challenge: seq(64, 32),
      );

      expect(swapped, isNot(straight));
    });

    test('the status transcript rejects a challenge of the wrong length with '
        'an ArgumentError that does not carry it', () {
      expect(
        () => statusTranscript(
          callerFingerprint: printI,
          serverFingerprint: printR,
          challenge: filled(0xEF, 31),
        ),
        argumentErrorWithout('efef'),
      );
      expect(
        () => statusTranscript(
          callerFingerprint: printI,
          serverFingerprint: printR,
          challenge: Uint8List(33),
        ),
        throwsArgumentError,
      );
    });

    test('every transcript starts with its own label and a 0x00, and no label '
        'is the start of another', () {
      final labels = [
        'NexusBridges pair commit v1',
        'NexusBridges pair code v1',
        'NexusBridges pair start v1',
        'NexusBridges pair reveal v1',
        'NexusBridges pair status v1',
      ].map(label).toList();
      final s = start();
      final transcripts = {
        2: s,
        3: revealTranscript(
          startTranscript: s,
          sessionId: seq(0, 16),
          receiverCommitment: cr,
          initiatorNonce: seq(0, 32),
        ),
        4: statusTranscript(
          callerFingerprint: printI,
          serverFingerprint: printR,
          challenge: seq(64, 32),
        ),
      };

      for (final MapEntry(key: index, value: t) in transcripts.entries) {
        expect(t.sublist(0, labels[index].length), labels[index]);
      }
      for (var a = 0; a < labels.length; a++) {
        for (var b = 0; b < labels.length; b++) {
          if (a == b) continue;
          final shorter = min(labels[a].length, labels[b].length);
          expect(
            labels[a].sublist(0, shorter),
            isNot(labels[b].sublist(0, shorter)),
            reason: '$a $b',
          );
        }
      }
    });
  });

  group('bytes and hex', () {
    test(
      'fingerprintBytes turns the 64 uppercase hex digits into 32 bytes',
      () {
        expect(fingerprintBytes(printI), bytesOfPrint(printI));
        expect(fingerprintBytes('0' * 64), Uint8List(32));
        expect(fingerprintBytes('F' * 64), filled(0xFF, 32));
        for (var i = 0; i < 50; i++) {
          final fp = randomPrint();
          expect(fingerprintBytes(fp), bytesOfPrint(fp));
        }
      },
    );

    test('fingerprintBytes throws FormatException with a malformed fingerprint '
        'and does not copy it into the message', () {
      final bad = [
        printI.toLowerCase(),
        '${printI.substring(0, 63)}a',
        printI.substring(1),
        '${printI}0',
        '',
        ' $printI'.substring(0, 64),
        '${printI.substring(0, 63)}G',
        '0x${printI.substring(2)}',
        '${printI.substring(0, 63)}\uFF10',
        '${printI.substring(0, 63)}\n',
        '$printI\n',
      ];
      for (final value in bad) {
        expect(
          () => fingerprintBytes(value),
          throwsA(
            isA<FormatException>().having(
              (e) => e.toString(),
              'text',
              isNot(contains('0123456789ABCDEF0123')),
            ),
          ),
          reason: value,
        );
      }
    });

    test('toHex writes two lowercase digits per byte', () {
      expect(toHex([0, 1, 15, 16, 171, 255]), '00010f10abff');
      expect(toHex(const []), '');
      final all = toHex(seq(0, 256));
      expect(all, hasLength(512));
      expect(RegExp(r'^[0-9a-f]+$').hasMatch(all), isTrue);
    });

    test('fromHex reads lowercase hex of exactly length bytes', () {
      expect(fromHex('00010f10abff', 6), [0, 1, 15, 16, 171, 255]);
      expect(fromHex('00010f10abff', 6), isA<Uint8List>());
      expect(fromHex('', 0), isEmpty);
      for (var value = 0; value < 256; value++) {
        final text = value.toRadixString(16).padLeft(2, '0');
        expect(fromHex(text, 1), [value], reason: text);
      }
    });

    test('fromHex and toHex round trip random data of many lengths', () {
      for (final length in [1, 2, 16, 32, 64, 100]) {
        final data = randomData(length);
        expect(fromHex(toHex(data), length), data, reason: 'length $length');
      }
    });

    test('fromHex rejects uppercase and mixed case', () {
      expect(fromHex('FF', 1), isNull);
      expect(fromHex('aB', 1), isNull);
      expect(fromHex('Ab', 1), isNull);
      expect(fromHex(toHex(seq(0, 32)).toUpperCase(), 32), isNull);
      for (final letter in 'ABCDEF'.split('')) {
        expect(fromHex('0$letter', 1), isNull, reason: letter);
        expect(fromHex('${letter}0', 1), isNull, reason: letter);
      }
    });

    test('fromHex rejects any length other than twice length', () {
      expect(fromHex('abcd', 1), isNull);
      expect(fromHex('abcd', 3), isNull);
      expect(fromHex('abc', 1), isNull);
      expect(fromHex('abc', 2), isNull);
      expect(fromHex('', 1), isNull);
      expect(fromHex('ab', 0), isNull);
      expect(fromHex('ab', -1), isNull);
      expect(fromHex(toHex(seq(0, 32)), 16), isNull);
      expect(fromHex(toHex(seq(0, 16)), 32), isNull);
    });

    test('fromHex rejects anything that is not a hex digit', () {
      for (final text in [
        'zz',
        'g0',
        '0g',
        ' 0',
        '0 ',
        '+f',
        '-1',
        '0x',
        '\uFF10\uFF10',
        '\u0660\u0660',
        '0\n',
        '\u00000',
        'é0',
      ]) {
        expect(fromHex(text, 1), isNull, reason: text);
      }
    });

    test('randomBytes gives the requested length and different values each '
        'time', () {
      expect(randomBytes(0), isEmpty);
      expect(randomBytes(16), hasLength(16));
      expect(randomBytes(32), hasLength(32));
      expect(randomBytes(32), isA<Uint8List>());
      final seen = {for (var i = 0; i < 2000; i++) toHex(randomBytes(32))};
      expect(seen, hasLength(2000));
    });

    test('randomBytes has no visible bias over 256000 bytes', () {
      final counts = List<int>.filled(256, 0);
      for (final byte in randomBytes(256000)) {
        counts[byte]++;
      }
      for (var value = 0; value < 256; value++) {
        expect(counts[value], inInclusiveRange(800, 1200), reason: '$value');
      }
    });
  });
}
