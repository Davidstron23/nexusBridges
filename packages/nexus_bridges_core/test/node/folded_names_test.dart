import 'dart:io';

import 'package:nexus_bridges_core/src/discovery/discovery.dart';
import 'package:nexus_bridges_core/src/identity/identity.dart'
    show shortFingerprint;
import 'package:nexus_bridges_core/src/node/entries.dart';
import 'package:nexus_bridges_core/src/pairing/pairing.dart';
import 'package:nexus_bridges_core/src/protocol/protocol.dart';
import 'package:test/test.dart';

String _c(int code) => String.fromCharCode(code);

String _fp(String prefix) => prefix.padRight(64, '0');

final String _dot = _c(0x00B7);

String _label(String name, String fingerprint) =>
    '$name $_dot ${shortFingerprint(fingerprint)}';

final String _nfc = 'Port${_c(0x00E1)}til de David';

final String _nfd = 'Porta${_c(0x0301)}til de David';

PairedDevice _paired(String prefix, String name, {DateTime? pairedAt}) =>
    PairedDevice(
      fingerprint: _fp(prefix),
      name: name,
      certificatePem: 'not read here',
      relation: PeerRelation.mine,
      pairedAt: pairedAt ?? DateTime.utc(2026, 10, 1),
    );

DiscoveredDevice _visible(String prefix, String name) => DiscoveredDevice(
  info: DeviceInfo(
    name: name,
    fingerprint: _fp(prefix),
    port: defaultPort,
    protocol: protocolVersion,
    deviceType: DeviceType.desktop,
  ),
  address: InternetAddress('192.168.1.20'),
  interfaceId: 'eth#192.168.1.20',
  paired: false,
  lastSeen: DateTime.utc(2026, 10, 25, 12),
);

const String _upperLatin1 = 'aaaaaa.ceeeeiiii.nooooo.ouuuuy..';

const String _lowerLatin1 = 'aaaaaa.ceeeeiiii.nooooo.ouuuuy.y';

const String _extendedA =
    'aaaaaacccccccc'
    'dddd'
    'eeeeeeeeee'
    'gggggggg'
    'hhhh'
    'iiiiiiiiii'
    '..'
    'jj'
    'kk'
    '.'
    'llllllllll'
    'nnnnnn'
    '.'
    '..'
    'oooooo'
    '..'
    'rrrrrr'
    'ssssssss'
    'tttttt'
    'uuuuuuuuuuuu'
    'ww'
    'yyy'
    'zzzzzz'
    's';

Map<int, String> _expectedBases() {
  final bases = <int, String>{};
  void add(int first, String table) {
    for (var i = 0; i < table.length; i++) {
      bases[first + i] = table[i];
    }
  }

  add(0xC0, _upperLatin1);
  add(0xE0, _lowerLatin1);
  add(0x100, _extendedA);
  return bases;
}

void main() {
  group('E240 [SEG], PR4-1: composed and decomposed accents are one name', () {
    test('the two forms are different strings but the same name for '
        'sameName and foldedName', () {
      expect(_nfc, isNot(_nfd));
      expect(_nfc.length, _nfd.length - 1);

      expect(sameName(_nfc, _nfd), isTrue);
      expect(sameName(_nfd, _nfc), isTrue);
      expect(foldedName(_nfc), foldedName(_nfd));
      expect(foldedName(_nfc), 'portatil de david');
    });

    test('case does not matter either: upper NFD against lower NFC', () {
      final upperNfd = 'PORTA${_c(0x0301)}TIL DE DAVID';
      final lowerNfc = 'port${_c(0x00E1)}til de david';

      expect(sameName(upperNfd, lowerNfc), isTrue);
      expect(sameName('PORT${_c(0x00C1)}TIL DE DAVID', _nfd), isTrue);
    });

    test('several decomposed letters in one name fold as well', () {
      final composed = 'Jos${_c(0x00E9)} Mu${_c(0x00F1)}oz';
      final decomposed = 'Jose${_c(0x0301)} Mun${_c(0x0303)}oz';

      expect(sameName(composed, decomposed), isTrue);
      expect(foldedName(decomposed), 'jose munoz');
    });

    test('namesakeOf with a paired device in NFC and an incoming name in NFD '
        'returns the stored name', () {
      final stored = _paired('AAAA1111', _nfc);

      expect(
        namesakeOf(name: _nfd, excluding: _fp('BBBB2222'), paired: [stored]),
        _nfc,
      );
    });

    test('namesakeOf with a paired device in NFD and an incoming name in NFC '
        'returns the stored name', () {
      final stored = _paired('AAAA1111', _nfd);

      expect(
        namesakeOf(name: _nfc, excluding: _fp('BBBB2222'), paired: [stored]),
        sanitizeDisplayName(_nfd),
      );
    });

    test('namesakeOf still skips the device itself', () {
      final stored = _paired('AAAA1111', _nfc);

      expect(
        namesakeOf(name: _nfd, excluding: _fp('AAAA1111'), paired: [stored]),
        isNull,
      );
    });

    test('displayNamesFor gives both the short fingerprint', () {
      final first = _fp('AAAA1111');
      final second = _fp('BBBB2222');

      final names = displayNamesFor([(first, _nfc), (second, _nfd)]);

      expect(names[first], _label(_nfc, first));
      expect(names[second], _label(_nfd, second));
    });

    test('displayNamesFor still unifies spaces on top of the folding', () {
      final first = _fp('AAAA1111');
      final second = _fp('BBBB2222');
      final spaced = 'Porta${_c(0x0301)}til  de${_c(0x00A0)}David';

      final names = displayNamesFor([(first, _nfc), (second, spaced)]);

      expect(names[first], _label(_nfc, first));
      expect(names[second], _label(spaced, second));
    });

    test('buildEntries with a paired device in NFC and a visible stranger in '
        'NFD adds the short fingerprint to each row', () {
      final stored = _paired('AAAA1111', _nfc);
      final stranger = _visible('BBBB2222', _nfd);

      final entries = buildEntries(
        visible: [stranger],
        paired: [stored],
        isIgnored: (_) => false,
        mismatched: const {},
        isReplaceable: (_) => false,
      );

      final byFingerprint = {for (final e in entries) e.fingerprint: e};
      expect(
        byFingerprint[stored.fingerprint]!.displayName,
        _label(_nfc, stored.fingerprint),
      );
      expect(
        byFingerprint[stranger.info.fingerprint]!.displayName,
        _label(_nfd, stranger.info.fingerprint),
      );
    });

    test('control: two different names keep their plain names', () {
      final first = _fp('AAAA1111');
      final second = _fp('BBBB2222');

      final names = displayNamesFor([(first, _nfc), (second, 'Desk PC')]);

      expect(names[first], _nfc);
      expect(names[second], 'Desk PC');
    });
  });

  group('E241, PR4-1: what folds and what does not', () {
    test('Latin-1 and Latin Extended-A pairs, upper case included', () {
      expect(sameName('Espa${_c(0x00F1)}a', 'Espana'), isTrue);
      expect(sameName('ESPA${_c(0x00D1)}A', 'espana'), isTrue);
      expect(sameName('${_c(0x0161)}koda', 'skoda'), isTrue);
      expect(sameName('${_c(0x0160)}KODA', 'skoda'), isTrue);
      expect(
        sameName('${_c(0x0141)}${_c(0x00F3)}d${_c(0x017A)}', 'lodz'),
        isTrue,
      );
      expect(sameName('${_c(0x0130)}stanbul', 'istanbul'), isTrue);
      expect(sameName('Jos${_c(0x00E9)}', 'Jose'), isTrue);
    });

    test('every letter of U+00C0 to U+017F folds to its base letter, and '
        'the ligatures, the letters without a clear base and the two '
        'signs stay as they are in lower case', () {
      final bases = _expectedBases();
      expect(bases, hasLength(0x180 - 0xC0));
      for (var code = 0xC0; code <= 0x17F; code++) {
        final letter = _c(code);
        final base = bases[code]!;
        final expected = base == '.' ? letter.toLowerCase() : base;
        expect(
          foldedName(letter),
          expected,
          reason: 'U+${code.toRadixString(16).toUpperCase()}',
        );
      }
    });

    test('the AE and OE ligatures, sharp s, eth, thorn, IJ, eng, kra and '
        'apostrophe n are not folded to look-alike letters', () {
      final kept = {
        0x00C6: 'ae',
        0x00E6: 'ae',
        0x0152: 'oe',
        0x0153: 'oe',
        0x00DF: 'ss',
        0x00D0: 'd',
        0x00F0: 'd',
        0x00DE: 'th',
        0x00FE: 'th',
        0x0132: 'ij',
        0x0133: 'ij',
        0x014A: 'n',
        0x014B: 'n',
        0x0138: 'k',
        0x0149: 'n',
      };
      for (final MapEntry(key: code, value: lookalike) in kept.entries) {
        final letter = _c(code);
        expect(
          foldedName(letter),
          letter.toLowerCase(),
          reason: 'U+${code.toRadixString(16).toUpperCase()}',
        );
        expect(
          sameName('X$letter', 'X$lookalike'),
          isFalse,
          reason: 'U+${code.toRadixString(16).toUpperCase()}',
        );
      }
      expect(sameName(_c(0x00C6), _c(0x00E6)), isTrue);
      expect(sameName(_c(0x0152), _c(0x0153)), isTrue);
    });

    test('Cyrillic and Greek homographs are still different names (R20)', () {
      final cyrillic = '${_c(0x0420)}${_c(0x0421)}';
      final greek = '${_c(0x03A1)}C';
      final cyrillicO = 'P${_c(0x043E)}rt${_c(0x00E1)}til';

      expect(sameName('PC', cyrillic), isFalse);
      expect(sameName('PC', greek), isFalse);
      expect(sameName('Portatil', cyrillicO), isFalse);
      expect(foldedName(cyrillic), cyrillic.toLowerCase());
      expect(foldedName(greek), greek.toLowerCase());
      expect(
        namesakeOf(
          name: cyrillic,
          excluding: _fp('BBBB2222'),
          paired: [_paired('AAAA1111', 'PC')],
        ),
        isNull,
      );
    });

    test('sameName still does not unify spaces', () {
      expect(sameName('My  PC', 'My PC'), isFalse);
      expect(sameName('My${_c(0x00A0)}PC', 'My PC'), isFalse);
      expect(sameName('My P${_c(0x00C7)}', 'my pc'), isTrue);
    });

    test('names that clean to nothing are never the same name', () {
      expect(sameName('   ', '   '), isFalse);
      expect(sameName(null, 'PC'), isFalse);
    });

    test('digits, signs and the two Latin-1 signs pass through', () {
      expect(
        foldedName('PC-2026_${_c(0x00D7)}${_c(0x00F7)}'),
        'pc-2026_${_c(0x00D7)}${_c(0x00F7)}',
      );
    });
  });
}
