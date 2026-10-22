import 'dart:io';

import 'package:nexus_bridges_core/src/discovery/registry.dart';
import 'package:nexus_bridges_core/src/protocol/protocol.dart';
import 'package:test/test.dart';

final DateTime _start = DateTime.utc(2026, 10, 22, 12);

String _fingerprint(int seed) =>
    seed.toRadixString(16).toUpperCase().padLeft(64, '0');

DeviceInfo _info(int seed, {String? name, int port = defaultPort}) =>
    DeviceInfo(
      name: name ?? 'device $seed',
      fingerprint: _fingerprint(seed),
      port: port,
      protocol: protocolVersion,
      deviceType: DeviceType.desktop,
    );

Announcement _hello(DeviceInfo info) =>
    Announcement(AnnouncementKind.hello, info);

Announcement _bye(DeviceInfo info) => Announcement(AnnouncementKind.bye, info);

InternetAddress _ip(String address) => InternetAddress(address);

void main() {
  const self = 0xABC;
  late DateTime now;
  late Set<String> paired;
  late DiscoveryRegistry registry;

  setUp(() {
    now = _start;
    paired = {};
    registry = DiscoveryRegistry(
      selfFingerprint: _fingerprint(self),
      isPaired: paired.contains,
      now: () => now,
    );
  });

  void at(Duration offset) => now = _start.add(offset);

  void verified(
    DeviceInfo info, [
    String address = '192.168.1.10',
    String interfaceId = 'eth',
  ]) {
    expect(registry.onVerified(info, _ip(address), interfaceId), isTrue);
  }

  DiscoveredDevice deviceOf(int seed) => registry.devices.singleWhere(
    (device) => device.info.fingerprint == _fingerprint(seed),
  );

  List<String> listed() => [
    for (final device in registry.devices) device.info.fingerprint,
  ];

  group('new announcements (RF-41)', () {
    test('a hello from a new fingerprint asks to verify it with its origin '
        'and interface', () {
      final info = _info(1);

      final action = registry.onAnnouncement(
        _hello(info),
        _ip('192.168.1.10'),
        'eth',
      );

      expect(
        action,
        isA<Verify>()
            .having((v) => v.info.fingerprint, 'fingerprint', info.fingerprint)
            .having((v) => v.address.address, 'address', '192.168.1.10')
            .having((v) => v.interfaceId, 'interfaceId', 'eth'),
      );
    });

    test('an announcement alone never adds the device to the list', () {
      registry.onAnnouncement(_hello(_info(1)), _ip('192.168.1.10'), 'eth');

      expect(registry.devices, isEmpty);
    });

    test('onVerified adds the device with its address, interface and the '
        'current time', () {
      final info = _info(1, name: 'Laptop');

      expect(registry.onVerified(info, _ip('192.168.1.10'), 'wifi'), isTrue);

      final device = deviceOf(1);
      expect(device.info.name, 'Laptop');
      expect(device.address.address, '192.168.1.10');
      expect(device.interfaceId, 'wifi');
      expect(device.paired, isFalse);
      expect(device.lastSeen, _start);
    });

    test('a hello from the current address of a known device refreshes it '
        'without asking to verify', () {
      verified(_info(1));
      at(const Duration(seconds: 20));

      final action = registry.onAnnouncement(
        _hello(_info(1)),
        _ip('192.168.1.10'),
        'eth',
      );

      expect(action, isA<Refreshed>());
      expect(deviceOf(1).lastSeen, _start.add(const Duration(seconds: 20)));
    });

    test('a bye from an unknown device is ignored', () {
      final action = registry.onAnnouncement(
        _bye(_info(1)),
        _ip('192.168.1.10'),
        'eth',
      );

      expect(action, isA<Ignore>());
      expect(registry.devices, isEmpty);
    });
  });

  group('itself (RF-46)', () {
    test('a hello with its own fingerprint is ignored', () {
      final action = registry.onAnnouncement(
        _hello(_info(self)),
        _ip('192.168.1.20'),
        'eth',
      );

      expect(action, isA<Ignore>());
    });

    test('a bye with its own fingerprint is ignored', () {
      final action = registry.onAnnouncement(
        _bye(_info(self)),
        _ip('192.168.1.20'),
        'eth',
      );

      expect(action, isA<Ignore>());
    });

    test('onVerified with its own fingerprint returns false and leaves the '
        'list empty', () {
      expect(
        registry.onVerified(_info(self), _ip('192.168.1.20'), 'eth'),
        isFalse,
      );

      expect(registry.devices, isEmpty);
    });

    test('its own fingerprint is refused even if it is marked as paired', () {
      paired.add(_fingerprint(self));

      expect(
        registry.onAnnouncement(
          _hello(_info(self)),
          _ip('192.168.1.20'),
          'eth',
        ),
        isA<Ignore>(),
      );
      expect(
        registry.onVerified(_info(self), _ip('192.168.1.20'), 'eth'),
        isFalse,
      );
      expect(registry.devices, isEmpty);
    });
  });

  group('one entry per fingerprint (RF-47)', () {
    test('the same fingerprint verified through two interfaces is listed '
        'once', () {
      verified(_info(1), '192.168.1.10', 'eth');
      verified(_info(1), '10.0.0.10', 'wifi');

      expect(registry.devices, hasLength(1));
    });

    test('verifying the same device twice from the same address keeps one '
        'entry', () {
      verified(_info(1));
      verified(_info(1));

      expect(registry.devices, hasLength(1));
    });
  });

  group('address change (RF-48)', () {
    test('a hello from another address of a known device asks to verify it '
        'from the new address', () {
      verified(_info(1), '192.168.1.10', 'eth');

      final action = registry.onAnnouncement(
        _hello(_info(1)),
        _ip('192.168.1.11'),
        'wifi',
      );

      expect(
        action,
        isA<Verify>()
            .having((v) => v.address.address, 'address', '192.168.1.11')
            .having((v) => v.interfaceId, 'interfaceId', 'wifi'),
      );
    });

    test('after onVerified the device moves to the new address and '
        'interface with the new data', () {
      verified(_info(1, name: 'Old'), '192.168.1.10', 'eth');
      at(const Duration(seconds: 5));

      verified(_info(1, name: 'New', port: 40000), '192.168.1.11', 'wifi');

      final device = deviceOf(1);
      expect(device.address.address, '192.168.1.11');
      expect(device.interfaceId, 'wifi');
      expect(device.info.name, 'New');
      expect(device.info.port, 40000);
      expect(device.lastSeen, _start.add(const Duration(seconds: 5)));
    });

    test('without onVerified the device keeps the old address and is still '
        'refreshed from it', () {
      verified(_info(1), '192.168.1.10', 'eth');

      registry.onAnnouncement(_hello(_info(1)), _ip('192.168.1.11'), 'eth');

      expect(deviceOf(1).address.address, '192.168.1.10');
      expect(
        registry.onAnnouncement(_hello(_info(1)), _ip('192.168.1.10'), 'eth'),
        isA<Refreshed>(),
      );
    });

    test('a hello from another address does not refresh the device, so it '
        'still expires', () {
      verified(_info(1), '192.168.1.10', 'eth');
      at(const Duration(seconds: 20));
      registry.onAnnouncement(_hello(_info(1)), _ip('192.168.1.11'), 'eth');

      at(const Duration(seconds: 31));

      expect(registry.expire(), [_fingerprint(1)]);
    });
  });

  group('goodbye (RF-52)', () {
    test('a bye from the current address removes the device', () {
      verified(_info(1), '192.168.1.10');

      final action = registry.onAnnouncement(
        _bye(_info(1)),
        _ip('192.168.1.10'),
        'eth',
      );

      expect(action, isA<Refreshed>());
      expect(registry.devices, isEmpty);
    });

    test('a bye from another address is ignored and the device stays', () {
      verified(_info(1), '192.168.1.10');

      final action = registry.onAnnouncement(
        _bye(_info(1)),
        _ip('192.168.1.66'),
        'eth',
      );

      expect(action, isA<Ignore>());
      expect(listed(), [_fingerprint(1)]);
    });

    test('a bye only removes its own device', () {
      verified(_info(1), '192.168.1.10');
      verified(_info(2), '192.168.1.20');

      registry.onAnnouncement(_bye(_info(1)), _ip('192.168.1.10'), 'eth');

      expect(listed(), [_fingerprint(2)]);
    });
  });

  group('expiry (RF-53)', () {
    test('a device last heard 29 s ago stays', () {
      verified(_info(1));

      at(const Duration(seconds: 29));

      expect(registry.expire(), isEmpty);
      expect(listed(), [_fingerprint(1)]);
    });

    test('a device last heard 31 s ago is removed and its fingerprint '
        'returned', () {
      verified(_info(1));

      at(const Duration(seconds: 31));

      expect(registry.expire(), [_fingerprint(1)]);
      expect(registry.devices, isEmpty);
    });

    test('a hello from the current address keeps the device alive', () {
      verified(_info(1));
      at(const Duration(seconds: 20));
      registry.onAnnouncement(_hello(_info(1)), _ip('192.168.1.10'), 'eth');

      at(const Duration(seconds: 45));
      expect(registry.expire(), isEmpty);

      at(const Duration(seconds: 51));
      expect(registry.expire(), [_fingerprint(1)]);
    });

    test('only the devices that are too old are removed', () {
      verified(_info(1), '192.168.1.10');
      at(const Duration(seconds: 10));
      verified(_info(2), '192.168.1.20');
      verified(_info(3), '192.168.1.30');

      at(const Duration(seconds: 35));

      expect(registry.expire(), [_fingerprint(1)]);
      expect(listed(), unorderedEquals([_fingerprint(2), _fingerprint(3)]));
    });

    test('a second expire right after the first one returns nothing', () {
      verified(_info(1));
      at(const Duration(seconds: 31));
      registry.expire();

      expect(registry.expire(), isEmpty);
    });
  });

  group('list limit (RF-57, RF-58)', () {
    void fillUnpaired([int count = Limits.maxListedUnpaired]) {
      for (var i = 0; i < count; i++) {
        verified(_info(100 + i), '192.168.2.${i + 1}');
      }
    }

    test('64 unpaired devices fit in the list', () {
      fillUnpaired();

      expect(registry.devices, hasLength(Limits.maxListedUnpaired));
    });

    test('with 64 unpaired devices a hello from a new unpaired one is '
        'ignored', () {
      fillUnpaired();

      final action = registry.onAnnouncement(
        _hello(_info(500)),
        _ip('192.168.3.1'),
        'eth',
      );

      expect(action, isA<Ignore>());
    });

    test('with 64 unpaired devices a hello from a new paired one is still '
        'verified', () {
      fillUnpaired();
      paired.add(_fingerprint(500));

      final action = registry.onAnnouncement(
        _hello(_info(500)),
        _ip('192.168.3.1'),
        'eth',
      );

      expect(action, isA<Verify>());
    });

    test('with 64 unpaired devices onVerified of a new unpaired one returns '
        'false and the list stays at 64', () {
      fillUnpaired();

      expect(
        registry.onVerified(_info(500), _ip('192.168.3.1'), 'eth'),
        isFalse,
      );

      expect(registry.devices, hasLength(Limits.maxListedUnpaired));
      expect(listed(), isNot(contains(_fingerprint(500))));
    });

    test('with 64 unpaired devices a paired one is still added', () {
      fillUnpaired();
      paired.add(_fingerprint(500));

      expect(
        registry.onVerified(_info(500), _ip('192.168.3.1'), 'eth'),
        isTrue,
      );

      expect(registry.devices, hasLength(Limits.maxListedUnpaired + 1));
      expect(deviceOf(500).paired, isTrue);
    });

    test('paired devices do not count for the limit', () {
      for (var i = 0; i < 10; i++) {
        paired.add(_fingerprint(900 + i));
        verified(_info(900 + i), '192.168.4.${i + 1}');
      }

      fillUnpaired();

      expect(registry.devices, hasLength(Limits.maxListedUnpaired + 10));
      expect(
        registry.onVerified(_info(500), _ip('192.168.3.1'), 'eth'),
        isFalse,
      );
    });

    test('with 64 unpaired devices a listed one can still change address', () {
      fillUnpaired();

      expect(
        registry.onAnnouncement(
          _hello(_info(100)),
          _ip('192.168.3.50'),
          'wifi',
        ),
        isA<Verify>(),
      );
      verified(_info(100), '192.168.3.50', 'wifi');

      expect(deviceOf(100).address.address, '192.168.3.50');
      expect(registry.devices, hasLength(Limits.maxListedUnpaired));
    });

    test('with 64 unpaired devices a listed one is still refreshed', () {
      fillUnpaired();

      expect(
        registry.onAnnouncement(_hello(_info(100)), _ip('192.168.2.1'), 'eth'),
        isA<Refreshed>(),
      );
    });

    test('a new unpaired device is accepted again after one leaves', () {
      fillUnpaired();

      registry.onAnnouncement(_bye(_info(100)), _ip('192.168.2.1'), 'eth');

      expect(
        registry.onAnnouncement(_hello(_info(500)), _ip('192.168.3.1'), 'eth'),
        isA<Verify>(),
      );
      verified(_info(500), '192.168.3.1');
      expect(registry.devices, hasLength(Limits.maxListedUnpaired));
    });

    test('a new unpaired device is accepted again after one expires', () {
      fillUnpaired(Limits.maxListedUnpaired - 1);
      at(const Duration(seconds: 10));
      verified(_info(999), '192.168.2.250');

      at(const Duration(seconds: 35));
      expect(registry.expire(), hasLength(Limits.maxListedUnpaired - 1));

      verified(_info(500), '192.168.3.1');
      expect(registry.devices, hasLength(2));
    });

    test('a device that stops being paired starts counting', () {
      paired.add(_fingerprint(900));
      verified(_info(900), '192.168.4.1');
      fillUnpaired(Limits.maxListedUnpaired - 1);

      expect(
        registry.onVerified(_info(500), _ip('192.168.3.1'), 'eth'),
        isTrue,
      );
      paired.remove(_fingerprint(900));
      expect(
        registry.onVerified(_info(501), _ip('192.168.3.2'), 'eth'),
        isFalse,
      );
    });

    test('a flood of fake announcements never lists more than 64 unpaired '
        'devices and the paired ones stay visible', () {
      paired.add(_fingerprint(900));
      verified(_info(900), '192.168.4.1');

      var verifies = 0;
      for (var i = 0; i < 1000; i++) {
        final info = _info(10000 + i);
        final from = _ip('192.168.${5 + i ~/ 250}.${i % 250 + 1}');
        final action = registry.onAnnouncement(_hello(info), from, 'eth');
        if (action is Verify) {
          verifies++;
          registry.onVerified(action.info, action.address, action.interfaceId);
        }
      }

      expect(verifies, Limits.maxListedUnpaired);
      final unpaired = registry.devices.where((device) => !device.paired);
      expect(unpaired, hasLength(Limits.maxListedUnpaired));
      expect(deviceOf(900).paired, isTrue);
    });
  });

  group('unpaired devices per address (RF-57, plan v2.11 point 2)', () {
    const crowded = '127.0.0.5';

    void fillAddress([String address = crowded, int firstSeed = 200]) {
      for (var i = 0; i < 4; i++) {
        verified(_info(firstSeed + i), address);
      }
    }

    test('4 unpaired devices with the same address fit', () {
      fillAddress();

      expect(registry.devices, hasLength(4));
      expect(
        registry.devices.map((device) => device.address.address),
        everyElement(crowded),
      );
    });

    test('a hello from a 5th unpaired device at that address is ignored', () {
      fillAddress();

      expect(
        registry.onAnnouncement(_hello(_info(300)), _ip(crowded), 'eth'),
        isA<Ignore>(),
      );
    });

    test('onVerified of a 5th unpaired device at that address returns false '
        'and the list stays at 4', () {
      fillAddress();

      expect(registry.onVerified(_info(300), _ip(crowded), 'eth'), isFalse);

      expect(registry.devices, hasLength(4));
      expect(listed(), isNot(contains(_fingerprint(300))));
    });

    test('an unpaired device at another address still gets in', () {
      fillAddress();

      expect(
        registry.onAnnouncement(_hello(_info(300)), _ip('127.0.0.6'), 'eth'),
        isA<Verify>(),
      );
      verified(_info(300), '127.0.0.6');

      expect(registry.devices, hasLength(5));
      expect(deviceOf(300).address.address, '127.0.0.6');
    });

    test('a paired device at that address is still verified and added', () {
      fillAddress();
      paired.add(_fingerprint(300));

      expect(
        registry.onAnnouncement(_hello(_info(300)), _ip(crowded), 'eth'),
        isA<Verify>(),
      );
      verified(_info(300), crowded);

      expect(registry.devices, hasLength(5));
      expect(deviceOf(300).paired, isTrue);
    });

    test('paired devices at that address do not count for it', () {
      for (var i = 0; i < 4; i++) {
        paired.add(_fingerprint(400 + i));
        verified(_info(400 + i), crowded);
      }

      fillAddress();

      expect(registry.devices, hasLength(8));
      expect(registry.onVerified(_info(300), _ip(crowded), 'eth'), isFalse);
    });

    test('the 4 listed ones are still refreshed and verified again from that '
        'address', () {
      fillAddress();
      at(const Duration(seconds: 5));

      for (var i = 0; i < 4; i++) {
        expect(
          registry.onAnnouncement(_hello(_info(200 + i)), _ip(crowded), 'eth'),
          isA<Refreshed>(),
        );
        verified(_info(200 + i, name: 'renamed'), crowded);
      }

      expect(registry.devices, hasLength(4));
      expect(
        registry.devices.map((device) => device.info.name),
        everyElement('renamed'),
      );
    });

    test('a listed device does not move to an address that already has 4 '
        'other unpaired devices and stays where it was', () {
      verified(_info(300), '127.0.0.9', 'wifi');
      fillAddress();
      at(const Duration(seconds: 5));

      expect(
        registry.onVerified(_info(300, name: 'Moved'), _ip(crowded), 'eth'),
        isFalse,
      );

      final device = deviceOf(300);
      expect(device.address.address, '127.0.0.9');
      expect(device.interfaceId, 'wifi');
      expect(device.info.name, 'device 300');
      expect(device.lastSeen, _start);
      expect(registry.devices, hasLength(5));
      expect(
        registry.onAnnouncement(_hello(_info(300)), _ip('127.0.0.9'), 'wifi'),
        isA<Refreshed>(),
      );
    });

    test('a listed device moves to an address with 3 other unpaired '
        'devices', () {
      verified(_info(300), '127.0.0.9', 'wifi');
      for (var i = 0; i < 3; i++) {
        verified(_info(200 + i), crowded);
      }

      expect(registry.onVerified(_info(300), _ip(crowded), 'eth'), isTrue);

      expect(deviceOf(300).address.address, crowded);
      expect(registry.onVerified(_info(301), _ip(crowded), 'eth'), isFalse);
    });

    test('a paired listed device moves to an address with 4 unpaired '
        'devices', () {
      paired.add(_fingerprint(300));
      verified(_info(300), '127.0.0.9', 'wifi');
      fillAddress();

      expect(registry.onVerified(_info(300), _ip(crowded), 'eth'), isTrue);

      expect(deviceOf(300).address.address, crowded);
    });

    test('after one of them says goodbye a new one fits again at that '
        'address, and only one', () {
      fillAddress();

      registry.onAnnouncement(_bye(_info(200)), _ip(crowded), 'eth');

      expect(
        registry.onAnnouncement(_hello(_info(300)), _ip(crowded), 'eth'),
        isA<Verify>(),
      );
      verified(_info(300), crowded);
      expect(registry.devices, hasLength(4));
      expect(
        registry.onAnnouncement(_hello(_info(301)), _ip(crowded), 'eth'),
        isA<Ignore>(),
      );
    });

    test('after one of them expires a new one fits again at that address', () {
      verified(_info(200), crowded);
      at(const Duration(seconds: 10));
      for (var i = 1; i < 4; i++) {
        verified(_info(200 + i), crowded);
      }
      expect(registry.onVerified(_info(300), _ip(crowded), 'eth'), isFalse);

      at(const Duration(seconds: 35));
      expect(registry.expire(), [_fingerprint(200)]);

      expect(
        registry.onAnnouncement(_hello(_info(300)), _ip(crowded), 'eth'),
        isA<Verify>(),
      );
      verified(_info(300), crowded);
      expect(registry.devices, hasLength(4));
    });

    test('a device that stops being paired counts again at its address', () {
      paired.add(_fingerprint(400));
      verified(_info(400), crowded);
      for (var i = 0; i < 3; i++) {
        verified(_info(200 + i), crowded);
      }
      verified(_info(300), crowded);

      paired.remove(_fingerprint(400));

      expect(registry.onVerified(_info(301), _ip(crowded), 'eth'), isFalse);
      expect(
        registry.onAnnouncement(_hello(_info(301)), _ip(crowded), 'eth'),
        isA<Ignore>(),
      );
    });

    test('one address with 70 certificates lists only 4 of them and leaves '
        'room for the others', () {
      var verifies = 0;
      for (var i = 0; i < 70; i++) {
        final action = registry.onAnnouncement(
          _hello(_info(10000 + i)),
          _ip(crowded),
          'eth',
        );
        if (action is Verify) {
          verifies++;
          registry.onVerified(action.info, action.address, action.interfaceId);
        }
      }

      expect(verifies, 4);
      expect(registry.devices, hasLength(4));
      for (var i = 0; i < 10; i++) {
        final action = registry.onAnnouncement(
          _hello(_info(500 + i)),
          _ip('127.0.1.${i + 1}'),
          'eth',
        );
        expect(action, isA<Verify>());
        verified(_info(500 + i), '127.0.1.${i + 1}');
      }
      expect(registry.devices, hasLength(14));
    });

    test('the global limit of 64 stays: 16 addresses with 4 each fill it and '
        'a new unpaired device from a fresh address is ignored', () {
      for (var a = 0; a < 16; a++) {
        fillAddress('127.0.1.${a + 1}', 1000 + a * 4);
      }
      expect(registry.devices, hasLength(Limits.maxListedUnpaired));

      expect(
        registry.onAnnouncement(_hello(_info(5000)), _ip('127.0.2.1'), 'eth'),
        isA<Ignore>(),
      );
      expect(
        registry.onVerified(_info(5000), _ip('127.0.2.1'), 'eth'),
        isFalse,
      );

      paired.add(_fingerprint(5001));
      verified(_info(5001), '127.0.2.2');
      expect(registry.devices, hasLength(Limits.maxListedUnpaired + 1));
    });
  });

  group('devices', () {
    test('paired is computed when the list is read', () {
      verified(_info(1));
      expect(deviceOf(1).paired, isFalse);

      paired.add(_fingerprint(1));
      expect(deviceOf(1).paired, isTrue);

      paired.remove(_fingerprint(1));
      expect(deviceOf(1).paired, isFalse);
    });

    test('are sorted by name ignoring case and then by fingerprint', () {
      verified(_info(5, name: 'beta'), '192.168.1.5');
      verified(_info(4, name: 'Alpha'), '192.168.1.4');
      verified(_info(3, name: 'alpha'), '192.168.1.3');
      verified(_info(2, name: 'Gamma'), '192.168.1.2');
      verified(_info(6, name: 'ALPHA'), '192.168.1.6');

      expect(listed(), [
        _fingerprint(3),
        _fingerprint(4),
        _fingerprint(6),
        _fingerprint(5),
        _fingerprint(2),
      ]);
    });

    test('a device without a name sorts as an empty name', () {
      final unnamed = DeviceInfo(
        name: null,
        fingerprint: _fingerprint(9),
        port: defaultPort,
        protocol: protocolVersion,
        deviceType: DeviceType.desktop,
      );
      verified(_info(1, name: 'Alpha'), '192.168.1.1');
      verified(unnamed, '192.168.1.9');

      expect(listed(), [_fingerprint(9), _fingerprint(1)]);
      expect(deviceOf(9).info.name, isNull);
    });
  });

  group('dropInterface', () {
    test('removes only the devices of that interface', () {
      verified(_info(1), '192.168.1.10', 'eth');
      verified(_info(2), '10.0.0.20', 'wifi');
      verified(_info(3), '192.168.1.30', 'eth');

      registry.dropInterface('eth');

      expect(listed(), [_fingerprint(2)]);
    });

    test('an unknown interface removes nothing', () {
      verified(_info(1), '192.168.1.10', 'eth');

      registry.dropInterface('vpn');

      expect(listed(), [_fingerprint(1)]);
    });

    test('a device that moved to another interface is kept', () {
      verified(_info(1), '192.168.1.10', 'eth');
      verified(_info(1), '10.0.0.10', 'wifi');

      registry.dropInterface('eth');

      expect(deviceOf(1).interfaceId, 'wifi');
    });

    test('a dropped device needs a new verification to come back', () {
      verified(_info(1), '192.168.1.10', 'eth');
      registry.dropInterface('eth');

      expect(
        registry.onAnnouncement(_hello(_info(1)), _ip('192.168.1.10'), 'eth'),
        isA<Verify>(),
      );
      expect(registry.devices, isEmpty);
    });
  });
}
