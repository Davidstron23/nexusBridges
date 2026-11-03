import 'dart:io';

import 'package:nexus_bridges_core/src/discovery/discovery.dart';
import 'package:nexus_bridges_core/src/node/entries.dart';
import 'package:nexus_bridges_core/src/node/node_state.dart';
import 'package:nexus_bridges_core/src/pairing/pairing.dart';
import 'package:nexus_bridges_core/src/pairing_flow/pairing_flow.dart'
    show PairingPhase, PairingRole, PairingView;
import 'package:nexus_bridges_core/src/protocol/protocol.dart';
import 'package:test/test.dart';

const String _dot = '\u00B7';

final DateTime _seen = DateTime.utc(2026, 10, 24, 12);

String _fp(String prefix) => prefix.padRight(64, '0');

DiscoveredDevice _visible(
  String prefix, {
  String? name,
  DeviceType deviceType = DeviceType.desktop,
  String address = '192.168.1.10',
  bool paired = false,
}) => DiscoveredDevice(
  info: DeviceInfo(
    name: name,
    fingerprint: _fp(prefix),
    port: defaultPort,
    protocol: protocolVersion,
    deviceType: deviceType,
  ),
  address: InternetAddress(address),
  interfaceId: 'eth#$address',
  paired: paired,
  lastSeen: _seen,
);

PairedDevice _paired(
  String prefix, {
  String name = '',
  PeerRelation relation = PeerRelation.foreign,
  DateTime? pairedAt,
}) => PairedDevice(
  fingerprint: _fp(prefix),
  name: name,
  certificatePem: 'not read by buildEntries',
  relation: relation,
  pairedAt: pairedAt ?? DateTime.utc(2026, 10, 1),
);

List<DeviceEntry> _entries({
  List<DiscoveredDevice> visible = const [],
  List<PairedDevice> paired = const [],
  Set<String> ignored = const {},
  Set<String> mismatched = const {},
  bool Function(String) isReplaceable = _always,
}) => buildEntries(
  visible: visible,
  paired: paired,
  isIgnored: ignored.contains,
  mismatched: mismatched,
  isReplaceable: isReplaceable,
);

bool _always(String _) => true;

String _mark(int code) => String.fromCharCode(code);

DeviceEntry _entryOf(List<DeviceEntry> entries, String prefix) =>
    entries.singleWhere((e) => e.fingerprint == _fp(prefix));

DeviceEntry _entry({
  String fingerprint = 'F',
  String displayName = 'PC',
  DeviceType? deviceType = DeviceType.desktop,
  bool visible = true,
  bool paired = false,
  bool mine = false,
  bool ignored = false,
  bool mismatch = false,
  String? possiblyReplaces,
}) => DeviceEntry(
  fingerprint: fingerprint,
  displayName: displayName,
  deviceType: deviceType,
  visible: visible,
  paired: paired,
  mine: mine,
  ignored: ignored,
  mismatch: mismatch,
  possiblyReplaces: possiblyReplaces,
);

void main() {
  group('C64, RF-67: canPair in the rows', () {
    test('a visible device that is neither paired nor ignored can be '
        'paired', () {
      final entries = _entries(visible: [_visible('1A2B3C4D', name: 'PC')]);

      expect(entries.single.canPair, isTrue);
    });

    test('an ignored visible device cannot be paired', () {
      final entries = _entries(
        visible: [_visible('1A2B3C4D', name: 'PC')],
        ignored: {_fp('1A2B3C4D')},
      );

      expect(entries.single.ignored, isTrue);
      expect(entries.single.canPair, isFalse);
    });

    test('a paired visible device without a mismatch cannot be paired', () {
      final entries = _entries(
        visible: [_visible('1A2B3C4D', name: 'PC')],
        paired: [_paired('1A2B3C4D', name: 'PC')],
      );

      expect(entries.single.paired, isTrue);
      expect(entries.single.canPair, isFalse);
    });

    test('a paired visible device with a mismatch can be paired again', () {
      final entries = _entries(
        visible: [_visible('1A2B3C4D', name: 'PC')],
        paired: [_paired('1A2B3C4D', name: 'PC')],
        mismatched: {_fp('1A2B3C4D')},
      );

      expect(entries.single.mismatch, isTrue);
      expect(entries.single.canPair, isTrue);
    });

    test('a paired device that is not visible cannot be paired, even if it '
        'is marked', () {
      final entries = _entries(
        paired: [_paired('1A2B3C4D', name: 'PC')],
        mismatched: {_fp('1A2B3C4D')},
      );

      expect(entries.single.visible, isFalse);
      expect(entries.single.canPair, isFalse);
    });

    test('the getter follows the rule for every combination', () {
      for (final visible in [true, false]) {
        for (final paired in [true, false]) {
          for (final ignored in [true, false]) {
            for (final mismatch in [true, false]) {
              final entry = _entry(
                visible: visible,
                paired: paired,
                ignored: ignored,
                mismatch: mismatch,
              );
              final expected = visible && (paired ? mismatch : !ignored);
              expect(
                entry.canPair,
                expected,
                reason:
                    'visible $visible paired $paired ignored $ignored '
                    'mismatch $mismatch',
              );
            }
          }
        }
      }
    });
  });

  group('C65, RF-111, RF-129: paired devices that are not visible', () {
    test('a paired device out of sight has a row with its saved name, '
        'visible false and no device type', () {
      final entries = _entries(
        paired: [_paired('1A2B3C4D', name: 'Old laptop')],
      );

      final entry = entries.single;
      expect(entry.fingerprint, _fp('1A2B3C4D'));
      expect(entry.displayName, 'Old laptop');
      expect(entry.visible, isFalse);
      expect(entry.paired, isTrue);
      expect(entry.deviceType, isNull);
      expect(entry.ignored, isFalse);
      expect(entry.mismatch, isFalse);
      expect(entry.possiblyReplaces, isNull);
    });

    test('a paired device in sight shows the announced name and its type, '
        'not the saved one', () {
      final entries = _entries(
        visible: [
          _visible('1A2B3C4D', name: 'New name', deviceType: DeviceType.mobile),
        ],
        paired: [_paired('1A2B3C4D', name: 'Old name')],
      );

      final entry = entries.single;
      expect(entry.displayName, 'New name');
      expect(entry.visible, isTrue);
      expect(entry.paired, isTrue);
      expect(entry.deviceType, DeviceType.mobile);
    });

    test('a paired device in sight appears once, and a device seen through '
        'two interfaces appears once', () {
      final entries = _entries(
        visible: [
          _visible('1A2B3C4D', name: 'PC'),
          _visible('1A2B3C4D', name: 'PC', address: '10.0.0.5'),
        ],
        paired: [_paired('1A2B3C4D', name: 'PC')],
      );

      expect(entries, hasLength(1));
      expect(entries.single.paired, isTrue);
    });

    test('the saved name is cleaned again: invisible characters and outer '
        'spaces go away', () {
      final entries = _entries(
        paired: [_paired('1A2B3C4D', name: '  Old\u202E PC  ')],
      );

      expect(entries.single.displayName, 'Old PC');
    });

    test('an empty saved name or one made only of invisible characters '
        'shows the short fingerprint', () {
      final entries = _entries(
        paired: [
          _paired('1A2B3C4D'),
          _paired('9F8E7D6C', name: ' \u200B\u202E '),
        ],
      );

      expect(_entryOf(entries, '1A2B3C4D').displayName, '1A2B3C4D');
      expect(_entryOf(entries, '9F8E7D6C').displayName, '9F8E7D6C');
    });

    test('a visible device without a name shows its short fingerprint', () {
      final entries = _entries(visible: [_visible('ABCDEF12')]);

      expect(entries.single.displayName, 'ABCDEF12');
      expect(entries.single.possiblyReplaces, isNull);
    });

    test('with the 32 paired devices out of sight there are 32 rows, all '
        'paired and none can be paired', () {
      final paired = [
        for (var i = 0; i < PairedDevicesStore.maxDevices; i++)
          _paired(
            i.toRadixString(16).toUpperCase().padLeft(2, '0') * 4,
            name: 'Device $i',
          ),
      ];

      final entries = _entries(
        paired: paired,
        visible: [_visible('FFFFFFFF', name: 'Newcomer')],
      );

      expect(entries, hasLength(PairedDevicesStore.maxDevices + 1));
      expect(entries.where((e) => e.paired), hasLength(32));
      expect(entries.where((e) => e.paired && e.canPair), isEmpty);
      expect(_entryOf(entries, 'FFFFFFFF').canPair, isTrue);
    });
  });

  group('C66, RF-50: repeated names across visible and paired rows', () {
    test('a "PC" in sight and a paired "PC" out of sight both get the short '
        'fingerprint', () {
      final entries = _entries(
        visible: [_visible('1A2B3C4D', name: 'PC')],
        paired: [_paired('9F8E7D6C', name: 'PC')],
      );

      expect(_entryOf(entries, '1A2B3C4D').displayName, 'PC $_dot 1A2B3C4D');
      expect(_entryOf(entries, '9F8E7D6C').displayName, 'PC $_dot 9F8E7D6C');
    });

    test('two paired devices out of sight with the same name are told apart '
        'too', () {
      final entries = _entries(
        paired: [
          _paired('11111111', name: 'PC'),
          _paired('22222222', name: 'pc'),
        ],
      );

      expect(_entryOf(entries, '11111111').displayName, 'PC $_dot 11111111');
      expect(_entryOf(entries, '22222222').displayName, 'pc $_dot 22222222');
    });
  });

  group('C67, C62 (L), RF-124, RF-123: possible reinstall', () {
    test('an unpaired "PC" in sight and a paired "pc" out of sight: the row '
        'warns with the display name of the paired one, and stays '
        'unpaired', () {
      final entries = _entries(
        visible: [_visible('1A2B3C4D', name: 'PC')],
        paired: [_paired('9F8E7D6C', name: 'pc')],
      );

      final newcomer = _entryOf(entries, '1A2B3C4D');
      expect(newcomer.possiblyReplaces, 'pc $_dot 9F8E7D6C');
      expect(newcomer.paired, isFalse);
      expect(newcomer.mine, isFalse);
      expect(newcomer.canPair, isTrue);
      expect(_entryOf(entries, '9F8E7D6C').possiblyReplaces, isNull);
    });

    test('if the paired one is in sight too, there is no warning', () {
      final entries = _entries(
        visible: [
          _visible('1A2B3C4D', name: 'PC'),
          _visible('9F8E7D6C', name: 'PC', address: '192.168.1.20'),
        ],
        paired: [_paired('9F8E7D6C', name: 'PC')],
      );

      expect(_entryOf(entries, '1A2B3C4D').possiblyReplaces, isNull);
      expect(_entryOf(entries, '9F8E7D6C').possiblyReplaces, isNull);
    });

    test('"PC " in sight against a paired "PC" out of sight warns, and so '
        'does a name with invisible characters', () {
      final spaced = _entries(
        visible: [_visible('1A2B3C4D', name: 'PC ')],
        paired: [_paired('9F8E7D6C', name: 'PC')],
      );
      final hidden = _entries(
        visible: [_visible('1A2B3C4D', name: '\u202EPC')],
        paired: [_paired('9F8E7D6C', name: 'pc')],
      );

      expect(_entryOf(spaced, '1A2B3C4D').possiblyReplaces, isNotNull);
      expect(_entryOf(hidden, '1A2B3C4D').possiblyReplaces, isNotNull);
    });

    test('"PC" written with Cyrillic letters does not warn (R20)', () {
      final entries = _entries(
        visible: [_visible('1A2B3C4D', name: '\u0420\u0421')],
        paired: [_paired('9F8E7D6C', name: 'PC')],
      );

      expect(_entryOf(entries, '1A2B3C4D').possiblyReplaces, isNull);
    });

    test('a different name, a device without a name and a paired device '
        'without a name do not warn', () {
      final entries = _entries(
        visible: [
          _visible('1A2B3C4D', name: 'Laptop'),
          _visible('2B3C4D5E', address: '192.168.1.20'),
        ],
        paired: [
          _paired('9F8E7D6C', name: 'PC'),
          _paired('8E7D6C5B'),
        ],
      );

      expect(_entryOf(entries, '1A2B3C4D').possiblyReplaces, isNull);
      expect(_entryOf(entries, '2B3C4D5E').possiblyReplaces, isNull);
    });

    test('with two paired "PC" out of sight, the warning names the most '
        'recently paired one', () {
      final entries = _entries(
        visible: [_visible('1A2B3C4D', name: 'PC')],
        paired: [
          _paired('9F8E7D6C', name: 'PC', pairedAt: DateTime.utc(2026, 10, 20)),
          _paired('8E7D6C5B', name: 'PC', pairedAt: DateTime.utc(2026, 10, 23)),
          _paired('7D6C5B4A', name: 'PC', pairedAt: DateTime.utc(2026, 10, 21)),
        ],
      );

      expect(
        _entryOf(entries, '1A2B3C4D').possiblyReplaces,
        'PC $_dot 8E7D6C5B',
      );
    });

    test('an ignored device with the same name still carries the warning', () {
      final entries = _entries(
        visible: [_visible('1A2B3C4D', name: 'PC')],
        paired: [_paired('9F8E7D6C', name: 'PC')],
        ignored: {_fp('1A2B3C4D')},
      );

      final row = _entryOf(entries, '1A2B3C4D');
      expect(row.ignored, isTrue);
      expect(row.possiblyReplaces, 'PC $_dot 9F8E7D6C');
    });

    test('a device called like a paired one is a separate row, never '
        'paired, never mine and never mismatched', () {
      final entries = _entries(
        visible: [_visible('1A2B3C4D', name: 'PC')],
        paired: [_paired('9F8E7D6C', name: 'PC', relation: PeerRelation.mine)],
        mismatched: {_fp('1A2B3C4D'), _fp('9F8E7D6C')},
      );

      expect(entries, hasLength(2));
      final impostor = _entryOf(entries, '1A2B3C4D');
      expect(impostor.paired, isFalse);
      expect(impostor.mine, isFalse);
      expect(impostor.mismatch, isFalse);
      final real = _entryOf(entries, '9F8E7D6C');
      expect(real.paired, isTrue);
      expect(real.mine, isTrue);
    });
  });

  group('C68, RF-101: mine or foreign', () {
    test('mine follows the saved relation, in sight and out of sight', () {
      final entries = _entries(
        visible: [
          _visible('11111111', name: 'A'),
          _visible('22222222', name: 'B', address: '192.168.1.20'),
        ],
        paired: [
          _paired('11111111', name: 'A', relation: PeerRelation.mine),
          _paired('22222222', name: 'B'),
          _paired('33333333', name: 'C', relation: PeerRelation.mine),
          _paired('44444444', name: 'D'),
        ],
      );

      expect(_entryOf(entries, '11111111').mine, isTrue);
      expect(_entryOf(entries, '22222222').mine, isFalse);
      expect(_entryOf(entries, '33333333').mine, isTrue);
      expect(_entryOf(entries, '44444444').mine, isFalse);
    });

    test('an unpaired device is never mine', () {
      final entries = _entries(visible: [_visible('11111111', name: 'A')]);

      expect(entries.single.mine, isFalse);
    });
  });

  group('C69, RF-109: ignored devices', () {
    test('an ignored device in sight is marked; one out of sight has no '
        'row', () {
      final entries = _entries(
        visible: [_visible('11111111', name: 'A')],
        ignored: {_fp('11111111'), _fp('22222222')},
      );

      expect(entries, hasLength(1));
      expect(entries.single.ignored, isTrue);
    });

    test('a paired device is never shown as ignored', () {
      final entries = _entries(
        visible: [_visible('11111111', name: 'A')],
        paired: [
          _paired('11111111', name: 'A'),
          _paired('22222222'),
        ],
        ignored: {_fp('11111111'), _fp('22222222')},
      );

      expect(_entryOf(entries, '11111111').ignored, isFalse);
      expect(_entryOf(entries, '22222222').ignored, isFalse);
    });
  });

  group('C70, RF-118: the mismatch mark only in sight', () {
    test('a marked paired device is mismatched in sight and not out of '
        'sight', () {
      final entries = _entries(
        visible: [_visible('11111111', name: 'A')],
        paired: [
          _paired('11111111', name: 'A'),
          _paired('22222222', name: 'B'),
        ],
        mismatched: {_fp('11111111'), _fp('22222222')},
      );

      expect(_entryOf(entries, '11111111').mismatch, isTrue);
      expect(_entryOf(entries, '22222222').mismatch, isFalse);
    });

    test('a mark on an unpaired device has no effect', () {
      final entries = _entries(
        visible: [_visible('11111111', name: 'A')],
        mismatched: {_fp('11111111')},
      );

      expect(entries.single.mismatch, isFalse);
      expect(entries.single.canPair, isTrue);
    });
  });

  group('order of the rows', () {
    test('by display name without case, then by fingerprint', () {
      final entries = _entries(
        visible: [
          _visible('33333333', name: 'beta'),
          _visible('22222222', name: 'Alpha', address: '192.168.1.20'),
          _visible('99999999', name: 'PC', address: '192.168.1.30'),
        ],
        paired: [
          _paired('11111111', name: 'Gamma'),
          _paired('44444444', name: 'PC'),
        ],
      );

      expect(
        [for (final e in entries) e.displayName],
        ['Alpha', 'beta', 'Gamma', 'PC $_dot 44444444', 'PC $_dot 99999999'],
      );
    });

    test('equal display names are ordered by fingerprint', () {
      final entries = _entries(
        visible: [
          _visible('BBBBBBBB'),
          _visible('AAAAAAAA', address: '192.168.1.20'),
        ],
      );

      expect(
        [for (final e in entries) e.fingerprint],
        [_fp('AAAAAAAA'), _fp('BBBBBBBB')],
      );
    });

    test('an empty input gives no rows', () {
      expect(_entries(), isEmpty);
    });
  });

  group('sameName (definition of "same name")', () {
    test('equal after cleaning and ignoring case', () {
      expect(sameName('PC', 'pc'), isTrue);
      expect(sameName('PC ', 'PC'), isTrue);
      expect(sameName('  My PC', 'my pc  '), isTrue);
      expect(sameName('\u202EPC\u200B', 'Pc'), isTrue);
    });

    test('different names, other alphabets and inner spaces that differ are '
        'not the same', () {
      expect(sameName('PC', 'Laptop'), isFalse);
      expect(sameName('PC', '\u0420\u0421'), isFalse);
      expect(sameName('My PC', 'MyPC'), isFalse);
      expect(sameName('My  PC', 'My PC'), isFalse);
    });

    test('a missing or empty name is never the same as anything', () {
      expect(sameName(null, 'PC'), isFalse);
      expect(sameName('PC', null), isFalse);
      expect(sameName(null, null), isFalse);
      expect(sameName('', ''), isFalse);
      expect(sameName('  ', ' '), isFalse);
      expect(sameName('\u202E', '\u200B'), isFalse);
    });
  });

  group('findReplaced (RF-124, RF-125)', () {
    final paired = [
      _paired('11111111', name: 'PC', pairedAt: DateTime.utc(2026, 10, 1)),
      _paired('22222222', name: 'pc ', pairedAt: DateTime.utc(2026, 10, 5)),
      _paired('33333333', name: 'Laptop', pairedAt: DateTime.utc(2026, 10, 9)),
    ];

    test('the most recent paired device with the same name and out of '
        'sight', () {
      final old = findReplaced(
        name: 'PC',
        excluding: _fp('99999999'),
        paired: paired,
        isReplaceable: (_) => true,
      );

      expect(old?.fingerprint, _fp('22222222'));
    });

    test('a visible one is skipped', () {
      final old = findReplaced(
        name: 'PC',
        excluding: _fp('99999999'),
        paired: paired,
        isReplaceable: (fp) => fp != _fp('22222222'),
      );

      expect(old?.fingerprint, _fp('11111111'));
    });

    test('the excluded fingerprint is never its own replacement', () {
      final old = findReplaced(
        name: 'PC',
        excluding: _fp('22222222'),
        paired: paired,
        isReplaceable: (_) => true,
      );

      expect(old?.fingerprint, _fp('11111111'));
    });

    test('nothing with no name, another name or nobody out of sight', () {
      expect(
        findReplaced(
          name: null,
          excluding: _fp('99999999'),
          paired: paired,
          isReplaceable: (_) => true,
        ),
        isNull,
      );
      expect(
        findReplaced(
          name: 'Tablet',
          excluding: _fp('99999999'),
          paired: paired,
          isReplaceable: (_) => true,
        ),
        isNull,
      );
      expect(
        findReplaced(
          name: 'PC',
          excluding: _fp('99999999'),
          paired: paired,
          isReplaceable: (_) => false,
        ),
        isNull,
      );
      expect(
        findReplaced(
          name: 'PC',
          excluding: _fp('99999999'),
          paired: const [],
          isReplaceable: (_) => true,
        ),
        isNull,
      );
    });
  });

  group('C125, RF-124: rows and findReplaced with isReplaceable (v8)', () {
    test('an unpaired "PC" in sight and a paired "pc" out of sight warn only '
        'when the paired one is replaceable', () {
      final visible = [_visible('1A2B3C4D', name: 'PC')];
      final paired = [_paired('9F8E7D6C', name: 'pc')];

      final notYet = _entries(
        visible: visible,
        paired: paired,
        isReplaceable: (_) => false,
      );
      final absent = _entries(
        visible: visible,
        paired: paired,
        isReplaceable: (fp) => fp == _fp('9F8E7D6C'),
      );

      expect(_entryOf(notYet, '1A2B3C4D').possiblyReplaces, isNull);
      expect(
        _entryOf(absent, '1A2B3C4D').possiblyReplaces,
        'pc $_dot 9F8E7D6C',
      );
    });

    test('a paired one in sight never warns, even if it is replaceable', () {
      final entries = _entries(
        visible: [
          _visible('1A2B3C4D', name: 'PC'),
          _visible('9F8E7D6C', name: 'PC', address: '192.168.1.20'),
        ],
        paired: [_paired('9F8E7D6C', name: 'PC')],
        isReplaceable: _always,
      );

      expect(_entryOf(entries, '1A2B3C4D').possiblyReplaces, isNull);
    });

    test('findReplaced returns the replaceable candidate even when it is the '
        'oldest', () {
      final paired = [
        _paired('11111111', name: 'PC', pairedAt: DateTime.utc(2026, 9, 1)),
        _paired('22222222', name: 'PC', pairedAt: DateTime.utc(2026, 10, 20)),
      ];

      final old = findReplaced(
        name: 'pc',
        excluding: _fp('99999999'),
        paired: paired,
        isReplaceable: (fp) => fp == _fp('11111111'),
      );

      expect(old?.fingerprint, _fp('11111111'));
    });
  });

  group('C132, RF-83, RF-73: namesakeOf (v8)', () {
    final paired = [
      _paired('11111111', name: 'pc', pairedAt: DateTime.utc(2026, 9, 1)),
      _paired('33333333', name: 'Portatil', pairedAt: DateTime.utc(2026, 9, 3)),
    ];

    test('"PC" against a paired "pc" with another fingerprint gives the '
        'cleaned paired name', () {
      expect(
        namesakeOf(name: 'PC', excluding: _fp('99999999'), paired: paired),
        'pc',
      );
    });

    test('the same fingerprint, another name or no name give nothing', () {
      expect(
        namesakeOf(name: 'PC', excluding: _fp('11111111'), paired: paired),
        isNull,
      );
      expect(
        namesakeOf(name: 'Laptop', excluding: _fp('99999999'), paired: paired),
        isNull,
      );
      expect(
        namesakeOf(name: null, excluding: _fp('99999999'), paired: paired),
        isNull,
      );
      expect(
        namesakeOf(name: 'PC', excluding: _fp('99999999'), paired: const []),
        isNull,
      );
    });

    test('with two paired "PC", the most recently paired one, whatever its '
        'visibility', () {
      final two = [
        ...paired,
        _paired('22222222', name: ' PC ', pairedAt: DateTime.utc(2026, 10, 2)),
      ];

      expect(
        namesakeOf(name: 'Pc', excluding: _fp('99999999'), paired: two),
        'PC',
      );
    });

    test('the paired name is returned cleaned of invisible characters', () {
      final hidden = [
        _paired(
          '44444444',
          name: '${_mark(0x202E)}PC${_mark(0x200B)}',
          pairedAt: DateTime.utc(2026, 10, 9),
        ),
      ];

      expect(
        namesakeOf(name: 'pc', excluding: _fp('99999999'), paired: hidden),
        'PC',
      );
    });
  });

  group('C135, PR4-1: composed and decomposed accents are the same name', () {
    test('"Portátil" composed and decomposed are sameName', () {
      final composed = 'Port${_mark(0x00E1)}til';
      final decomposed = 'Porta${_mark(0x0301)}til';

      expect(sameName(composed, decomposed), isTrue);
      expect(sameName(decomposed, decomposed), isTrue);
    });
  });

  group('the new state types', () {
    test('PairRequestResult and NoticeKind have exactly their values', () {
      expect(PairRequestResult.values, [
        PairRequestResult.started,
        PairRequestResult.alreadyInProgress,
        PairRequestResult.tooManyPaired,
        PairRequestResult.unavailable,
      ]);
      expect(NoticeKind.values, [
        NoticeKind.attemptCancelled,
        NoticeKind.attemptDataMismatch,
        NoticeKind.attemptLost,
        NoticeKind.unpairedByPeer,
        NoticeKind.unpairNotSaved,
        NoticeKind.changeNotSaved,
        NoticeKind.ignoreNotSaved,
        NoticeKind.pairingNotSaved,
        NoticeKind.pairingFailed,
        NoticeKind.pairingPaused,
        NoticeKind.replaceWithdrawn,
        NoticeKind.receiveFolderNotSaved,
        NoticeKind.peerCancelledTransfer,
        NoticeKind.settingNotSaved,
        NoticeKind.networkStopNotSaved,
        NoticeKind.sharesNotSaved,
        NoticeKind.shareAddNotSaved,
        NoticeKind.sharesReset,
        NoticeKind.sharesPartlyReset,
      ]);
    });

    test('only unpairNotSaved, changeNotSaved, networkStopNotSaved and '
        'sharesNotSaved can be retried', () {
      for (final kind in NoticeKind.values) {
        expect(
          Notice(id: 1, kind: kind).canRetry,
          kind == NoticeKind.unpairNotSaved ||
              kind == NoticeKind.changeNotSaved ||
              kind == NoticeKind.networkStopNotSaved ||
              kind == NoticeKind.sharesNotSaved,
          reason: kind.name,
        );
      }
    });

    test('DeviceEntry compares by value, field by field', () {
      final base = _entry(possiblyReplaces: 'PC $_dot 9F8E7D6C');

      expect(_entry(possiblyReplaces: 'PC $_dot 9F8E7D6C'), base);
      expect(
        _entry(possiblyReplaces: 'PC $_dot 9F8E7D6C').hashCode,
        base.hashCode,
      );
      final changed = [
        _entry(fingerprint: 'G', possiblyReplaces: 'PC $_dot 9F8E7D6C'),
        _entry(displayName: 'Other', possiblyReplaces: 'PC $_dot 9F8E7D6C'),
        _entry(deviceType: null, possiblyReplaces: 'PC $_dot 9F8E7D6C'),
        _entry(visible: false, possiblyReplaces: 'PC $_dot 9F8E7D6C'),
        _entry(paired: true, possiblyReplaces: 'PC $_dot 9F8E7D6C'),
        _entry(mine: true, possiblyReplaces: 'PC $_dot 9F8E7D6C'),
        _entry(ignored: true, possiblyReplaces: 'PC $_dot 9F8E7D6C'),
        _entry(mismatch: true, possiblyReplaces: 'PC $_dot 9F8E7D6C'),
        _entry(),
      ];
      for (final other in changed) {
        expect(other, isNot(base));
      }
    });

    test('Notice compares id, kind and name', () {
      const base = Notice(
        id: 3,
        kind: NoticeKind.unpairedByPeer,
        deviceName: 'PC',
      );

      expect(
        Notice(id: 3, kind: NoticeKind.unpairedByPeer, deviceName: 'P${'C'}'),
        base,
      );
      expect(
        const Notice(
          id: 3,
          kind: NoticeKind.unpairedByPeer,
          deviceName: 'PC',
        ).hashCode,
        base.hashCode,
      );
      expect(
        const Notice(id: 4, kind: NoticeKind.unpairedByPeer, deviceName: 'PC'),
        isNot(base),
      );
      expect(
        const Notice(id: 3, kind: NoticeKind.changeNotSaved, deviceName: 'PC'),
        isNot(base),
      );
      expect(const Notice(id: 3, kind: NoticeKind.unpairedByPeer), isNot(base));
    });

    test('the questions compare by value and a MineQuestion is never equal '
        'to a ReplaceQuestion', () {
      const mine = MineQuestion(fingerprint: 'F', deviceName: 'PC');
      const replace = ReplaceQuestion(
        fingerprint: 'F',
        deviceName: 'PC',
        oldFingerprint: 'O',
        oldName: 'Old',
      );

      expect(MineQuestion(fingerprint: 'F', deviceName: 'P${'C'}'), mine);
      expect(
        MineQuestion(fingerprint: 'F', deviceName: 'P${'C'}').hashCode,
        mine.hashCode,
      );
      expect(
        const MineQuestion(fingerprint: 'G', deviceName: 'PC'),
        isNot(mine),
      );
      expect(
        ReplaceQuestion(
          fingerprint: 'F',
          deviceName: 'PC',
          oldFingerprint: 'O',
          oldName: 'O${'ld'}',
        ),
        replace,
      );
      expect(
        const ReplaceQuestion(
          fingerprint: 'F',
          deviceName: 'PC',
          oldFingerprint: 'P',
          oldName: 'Old',
        ),
        isNot(replace),
      );
      expect(mine == replace, isFalse);
      expect(replace == mine, isFalse);
      final PairingQuestion asQuestion = replace;
      expect(asQuestion.fingerprint, 'F');
      expect(asQuestion.deviceName, 'PC');
    });

    test('NodeState has empty defaults for the new fields and keeps what it '
        'is given', () {
      const empty = NodeState();

      expect(empty.entries, isEmpty);
      expect(empty.pairing, isNull);
      expect(empty.pairingNamesake, isNull);
      expect(empty.questions, isEmpty);
      expect(empty.notices, isEmpty);
      expect(empty.unsavedChanges, isFalse);

      const view = PairingView(
        role: PairingRole.receiver,
        phase: PairingPhase.comparing,
        peerFingerprint: 'F',
        peerName: 'PC',
        code: '123456',
      );
      final full = NodeState(
        entries: [_entry()],
        pairing: view,
        pairingNamesake: 'pc',
        questions: const [MineQuestion(fingerprint: 'F', deviceName: 'PC')],
        notices: const [Notice(id: 1, kind: NoticeKind.attemptCancelled)],
        unsavedChanges: true,
      );

      expect(full.entries, [_entry()]);
      expect(full.pairing, view);
      expect(full.pairingNamesake, 'pc');
      expect(full.questions.single, isA<MineQuestion>());
      expect(full.notices.single.kind, NoticeKind.attemptCancelled);
      expect(full.unsavedChanges, isTrue);
    });
  });
}
