import 'dart:io';

import 'package:nexus_bridges_core/src/discovery/discovery.dart';
import 'package:nexus_bridges_core/src/protocol/protocol.dart';
import 'package:test/test.dart';

const String _dot = '\u00B7';

final DateTime _start = DateTime.utc(2026, 10, 22, 12);

String _fingerprint(String prefix) => prefix.padRight(64, '0');

DiscoveredDevice _device(
  String fingerprintPrefix, {
  String? name,
  bool paired = false,
  String address = '192.168.1.10',
}) => DiscoveredDevice(
  info: DeviceInfo(
    name: name,
    fingerprint: _fingerprint(fingerprintPrefix),
    port: defaultPort,
    protocol: protocolVersion,
    deviceType: DeviceType.desktop,
  ),
  address: InternetAddress(address),
  interfaceId: 'eth#$address',
  paired: paired,
  lastSeen: _start,
);

void main() {
  group('displayNames (RF-50)', () {
    test('two devices called "PC" show the first 8 characters of their '
        'fingerprint', () {
      final names = displayNames([
        _device('1A2B3C4D', name: 'PC'),
        _device('9F8E7D6C', name: 'PC'),
      ]);

      expect(names, {
        _fingerprint('1A2B3C4D'): 'PC $_dot 1A2B3C4D',
        _fingerprint('9F8E7D6C'): 'PC $_dot 9F8E7D6C',
      });
    });

    test('the separator is a middle dot between single spaces', () {
      final names = displayNames([
        _device('1A2B3C4D', name: 'PC'),
        _device('9F8E7D6C', name: 'PC'),
      ]);

      expect(names[_fingerprint('1A2B3C4D')]!.codeUnits, [
        ...'PC'.codeUnits,
        0x20,
        0x00B7,
        0x20,
        ...'1A2B3C4D'.codeUnits,
      ]);
    });

    test('a unique name stays as it is', () {
      final names = displayNames([
        _device('1A2B3C4D', name: 'PC'),
        _device('9F8E7D6C', name: 'Laptop'),
      ]);

      expect(names, {
        _fingerprint('1A2B3C4D'): 'PC',
        _fingerprint('9F8E7D6C'): 'Laptop',
      });
    });

    test('a device without a name shows its short fingerprint', () {
      final names = displayNames([_device('ABCDEF12')]);

      expect(names, {_fingerprint('ABCDEF12'): 'ABCDEF12'});
    });

    test('only the repeated names get the suffix', () {
      final names = displayNames([
        _device('11111111', name: 'PC'),
        _device('22222222', name: 'Laptop'),
        _device('33333333', name: 'PC'),
        _device('44444444', name: 'PC'),
        _device('55555555'),
      ]);

      expect(names, {
        _fingerprint('11111111'): 'PC $_dot 11111111',
        _fingerprint('22222222'): 'Laptop',
        _fingerprint('33333333'): 'PC $_dot 33333333',
        _fingerprint('44444444'): 'PC $_dot 44444444',
        _fingerprint('55555555'): '55555555',
      });
    });

    test('two devices without a name are not treated as repeated', () {
      final names = displayNames([_device('AAAAAAAA'), _device('BBBBBBBB')]);

      expect(names, {
        _fingerprint('AAAAAAAA'): 'AAAAAAAA',
        _fingerprint('BBBBBBBB'): 'BBBBBBBB',
      });
    });

    test('names that differ only in case count as repeated and keep their '
        'own spelling', () {
      final names = displayNames([
        _device('1A2B3C4D', name: 'PC'),
        _device('9F8E7D6C', name: 'pc'),
      ]);

      expect(names, {
        _fingerprint('1A2B3C4D'): 'PC $_dot 1A2B3C4D',
        _fingerprint('9F8E7D6C'): 'pc $_dot 9F8E7D6C',
      });
    });

    test('a no-break space counts as a normal space and each device keeps '
        'its own spelling (v2.11 point 3)', () {
      final names = displayNames([
        _device('1A2B3C4D', name: 'My PC'),
        _device('9F8E7D6C', name: 'My\u00A0PC'),
      ]);

      expect(names, {
        _fingerprint('1A2B3C4D'): 'My PC $_dot 1A2B3C4D',
        _fingerprint('9F8E7D6C'): 'My\u00A0PC $_dot 9F8E7D6C',
      });
    });

    test('a run of spaces counts as one space (v2.11 point 3)', () {
      final names = displayNames([
        _device('1A2B3C4D', name: 'My  PC'),
        _device('9F8E7D6C', name: 'My PC'),
      ]);

      expect(names, {
        _fingerprint('1A2B3C4D'): 'My  PC $_dot 1A2B3C4D',
        _fingerprint('9F8E7D6C'): 'My PC $_dot 9F8E7D6C',
      });
    });

    test('spaces at the start or the end do not count (v2.11 point 3)', () {
      final names = displayNames([
        _device('1A2B3C4D', name: ' PC'),
        _device('9F8E7D6C', name: 'PC '),
      ]);

      expect(names, {
        _fingerprint('1A2B3C4D'): ' PC $_dot 1A2B3C4D',
        _fingerprint('9F8E7D6C'): 'PC  $_dot 9F8E7D6C',
      });
    });

    test('every Unicode space of the plan collapses to one space, mixed with '
        'case changes (v2.11 point 3)', () {
      const spaces = [
        '\u0009',
        '\u0020',
        '\u00A0',
        '\u1680',
        '\u2000',
        '\u2005',
        '\u200A',
        '\u202F',
        '\u205F',
        '\u3000',
      ];
      final devices = [
        _device('00000000', name: 'my pc'),
        for (var i = 0; i < spaces.length; i++)
          _device('${i + 1}' * 8, name: 'MY${spaces[i]}Pc'),
      ];

      final names = displayNames(devices);

      for (final device in devices) {
        final short = device.info.fingerprint.substring(0, 8);
        expect(
          names[device.info.fingerprint],
          '${device.info.name} $_dot $short',
        );
      }
    });

    test('names that only look alike after removing a space or adding a '
        'character are still different (v2.11 point 3)', () {
      final names = displayNames([
        _device('11111111', name: 'My PC'),
        _device('22222222', name: 'MyPC'),
        _device('33333333', name: 'My PC 2'),
        _device('44444444', name: 'My-PC'),
      ]);

      expect(names, {
        _fingerprint('11111111'): 'My PC',
        _fingerprint('22222222'): 'MyPC',
        _fingerprint('33333333'): 'My PC 2',
        _fingerprint('44444444'): 'My-PC',
      });
    });

    test('a paired and an unpaired device with the same name both get the '
        'suffix', () {
      final names = displayNames([
        _device('1A2B3C4D', name: 'PC', paired: true),
        _device('9F8E7D6C', name: 'PC', address: '192.168.1.20'),
      ]);

      expect(names.values, ['PC $_dot 1A2B3C4D', 'PC $_dot 9F8E7D6C']);
    });

    test('the key is the full fingerprint and there is one entry per '
        'device', () {
      final devices = [
        for (var i = 0; i < 10; i++)
          _device(i.toRadixString(16).toUpperCase() * 8, name: 'PC'),
      ];

      final names = displayNames(devices);

      expect(names, hasLength(10));
      expect(names.keys, [for (final d in devices) d.info.fingerprint]);
      for (final key in names.keys) {
        expect(key, hasLength(64));
        expect(names[key], 'PC $_dot ${key.substring(0, 8)}');
      }
    });

    test('an empty list gives an empty map', () {
      expect(displayNames(const []), isEmpty);
    });
  });

  group('displayNamesFor (RF-50, T11)', () {
    test('works on plain fingerprint and name pairs, also without a '
        'name', () {
      final names = displayNamesFor([
        (_fingerprint('1A2B3C4D'), 'PC'),
        (_fingerprint('9F8E7D6C'), 'pc'),
        (_fingerprint('ABCDEF12'), null),
        (_fingerprint('12345678'), 'Laptop'),
      ]);

      expect(names, {
        _fingerprint('1A2B3C4D'): 'PC $_dot 1A2B3C4D',
        _fingerprint('9F8E7D6C'): 'pc $_dot 9F8E7D6C',
        _fingerprint('ABCDEF12'): 'ABCDEF12',
        _fingerprint('12345678'): 'Laptop',
      });
    });

    test('gives the same result as displayNames for the same devices', () {
      final devices = [
        _device('11111111', name: 'My PC'),
        _device('22222222', name: 'my\u00A0pc'),
        _device('33333333'),
        _device('44444444', name: 'Laptop'),
      ];

      expect(
        displayNamesFor([
          for (final d in devices) (d.info.fingerprint, d.info.name),
        ]),
        displayNames(devices),
      );
    });

    test('an empty list gives an empty map', () {
      expect(displayNamesFor(const []), isEmpty);
    });
  });

  group('shouldSuggestRescan (RF-55)', () {
    bool suggest({
      bool anyActive = true,
      Duration? emptyFor = const Duration(seconds: 15),
    }) => shouldSuggestRescan(
      anyActive: anyActive,
      emptySince: emptyFor == null ? null : _start.subtract(emptyFor),
      now: _start,
    );

    test('active and empty for 14 s does not suggest', () {
      expect(suggest(emptyFor: const Duration(seconds: 14)), isFalse);
    });

    test('active and empty for 14.999 s does not suggest', () {
      expect(
        suggest(emptyFor: const Duration(seconds: 14, milliseconds: 999)),
        isFalse,
      );
    });

    test('active and empty for exactly 15 s suggests', () {
      expect(suggest(emptyFor: const Duration(seconds: 15)), isTrue);
    });

    test('active and empty for longer still suggests', () {
      expect(suggest(emptyFor: const Duration(seconds: 16)), isTrue);
      expect(suggest(emptyFor: const Duration(hours: 3)), isTrue);
    });

    test('without active interfaces it never suggests', () {
      expect(suggest(anyActive: false), isFalse);
      expect(
        suggest(anyActive: false, emptyFor: const Duration(hours: 3)),
        isFalse,
      );
    });

    test('without emptySince it does not suggest', () {
      expect(suggest(emptyFor: null), isFalse);
      expect(suggest(anyActive: false, emptyFor: null), isFalse);
    });

    test('an emptySince in the future does not suggest', () {
      expect(suggest(emptyFor: const Duration(seconds: -20)), isFalse);
    });

    test('the threshold is Limits.rescanHintAfter', () {
      expect(Limits.rescanHintAfter, const Duration(seconds: 15));
      expect(suggest(emptyFor: Limits.rescanHintAfter), isTrue);
      expect(
        suggest(
          emptyFor: Limits.rescanHintAfter - const Duration(microseconds: 1),
        ),
        isFalse,
      );
    });
  });
}
