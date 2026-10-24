import 'dart:io';

import 'package:nexus_bridges_core/src/discovery/registry.dart';
import 'package:nexus_bridges_core/src/protocol/protocol.dart';
import 'package:test/test.dart';

final DateTime _start = DateTime.utc(2026, 10, 24, 12);

const Duration _quiet = Limits.announceInterval;
const Duration _forever = Duration(hours: 1);
const Duration _justUnder = Duration(milliseconds: 1);

String _fingerprint(int seed) =>
    seed.toRadixString(16).toUpperCase().padLeft(64, '0');

DeviceInfo _info(int seed, {int port = defaultPort}) => DeviceInfo(
  name: 'device $seed',
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
  late Duration elapsed;
  late Set<String> paired;
  late DiscoveryRegistry registry;

  setUp(() {
    now = _start;
    elapsed = Duration.zero;
    paired = {};
    registry = DiscoveryRegistry(
      selfFingerprint: _fingerprint(self),
      isPaired: paired.contains,
      now: () => now,
      clock: () => elapsed,
    );
  });

  void tick(Duration span) => elapsed += span;

  void scanned(
    DeviceInfo info, [
    String address = '192.168.1.10',
    String interfaceId = 'eth',
  ]) {
    expect(
      registry.onVerified(info, _ip(address), interfaceId, fromScan: true),
      isTrue,
    );
  }

  void announcedAndVerified(
    DeviceInfo info, [
    String address = '192.168.1.10',
    String interfaceId = 'eth',
  ]) {
    registry.onAnnouncement(_hello(info), _ip(address), interfaceId);
    expect(registry.onVerified(info, _ip(address), interfaceId), isTrue);
  }

  RegistryAction hello(DeviceInfo info, [String address = '192.168.1.10']) =>
      registry.onAnnouncement(_hello(info), _ip(address), 'eth');

  List<String> due([Duration quiet = _quiet]) => [
    for (final device in registry.dueForPresentation(quiet))
      device.info.fingerprint,
  ];

  List<String> listed() => [
    for (final device in registry.devices) device.info.fingerprint,
  ];

  group('devices pending a presentation (E131, RF-192)', () {
    test('a device found by a search and never announced is due, with its '
        'address, interface and port', () {
      scanned(_info(1, port: 40123), '192.168.1.10', 'wifi');

      final pending = registry.dueForPresentation(_quiet);

      expect(pending, hasLength(1));
      expect(pending.single.info.fingerprint, _fingerprint(1));
      expect(pending.single.info.port, 40123);
      expect(pending.single.address.address, '192.168.1.10');
      expect(pending.single.interfaceId, 'wifi');
    });

    test('a device that only came through announcements is never due', () {
      announcedAndVerified(_info(1));

      expect(due(), isEmpty);
      tick(_forever);
      expect(due(), isEmpty);
    });

    test('after a hello it leaves the list of due devices, and it is due '
        'again 10 s after the last hello', () {
      scanned(_info(1));
      tick(const Duration(seconds: 3));

      expect(hello(_info(1)), isA<Refreshed>());
      expect(due(), isEmpty);

      tick(_quiet - _justUnder);
      expect(due(), isEmpty);

      tick(_justUnder);
      expect(due(), [_fingerprint(1)]);
    });

    test('every new hello moves the 10 s again', () {
      scanned(_info(1));
      hello(_info(1));
      tick(const Duration(seconds: 8));
      hello(_info(1));

      tick(const Duration(seconds: 8));
      expect(due(), isEmpty);

      tick(const Duration(seconds: 2));
      expect(due(), [_fingerprint(1)]);
    });

    test('a device announced first and found later by a search becomes '
        'due', () {
      announcedAndVerified(_info(1));
      expect(due(), isEmpty);

      scanned(_info(1));
      tick(_quiet);

      expect(due(), [_fingerprint(1)]);
    });

    test('a later verification without the search mark keeps the mark', () {
      scanned(_info(1));

      expect(registry.onVerified(_info(1), _ip('192.168.1.10'), 'eth'), isTrue);

      expect(due(), [_fingerprint(1)]);
      tick(Limits.expireAfter);
      expect(registry.expire(), [_fingerprint(1)]);
    });

    test('only the devices found by a search are due', () {
      scanned(_info(1), '192.168.1.10');
      announcedAndVerified(_info(2), '192.168.1.20');
      scanned(_info(3), '192.168.1.30');

      expect(due(), unorderedEquals([_fingerprint(1), _fingerprint(3)]));
    });
  });

  group('expiry of devices found by a search (E131, RF-239)', () {
    test('without news it stays at 29.999 s and leaves at 30 s of the '
        'monotonic clock, also from the list of due devices', () {
      scanned(_info(1));

      tick(Limits.expireAfter - _justUnder);
      expect(registry.expire(), isEmpty);
      expect(listed(), [_fingerprint(1)]);

      tick(_justUnder);
      expect(registry.expire(), [_fingerprint(1)]);
      expect(registry.devices, isEmpty);
      expect(due(), isEmpty);
    });

    test('moving the system time one hour forward without moving the '
        'monotonic clock keeps it listed and due', () {
      scanned(_info(1));

      now = _start.add(const Duration(hours: 1));

      expect(registry.expire(), isEmpty);
      expect(listed(), [_fingerprint(1)]);
      expect(due(), [_fingerprint(1)]);
    });

    test('moving the system time one hour back does not keep it past 30 s '
        'of the monotonic clock', () {
      scanned(_info(1));

      now = _start.subtract(const Duration(hours: 1));
      tick(Limits.expireAfter);

      expect(registry.expire(), [_fingerprint(1)]);
    });

    test('a new verification refreshes it: it stays until 30 s after the '
        'last one', () {
      scanned(_info(1));
      tick(const Duration(seconds: 20));
      scanned(_info(1));

      tick(Limits.expireAfter - _justUnder);
      expect(registry.expire(), isEmpty);

      tick(_justUnder);
      expect(registry.expire(), [_fingerprint(1)]);
    });

    test('a hello from its current address refreshes it', () {
      scanned(_info(1));
      tick(const Duration(seconds: 20));
      expect(hello(_info(1)), isA<Refreshed>());

      tick(Limits.expireAfter - _justUnder);
      expect(registry.expire(), isEmpty);

      tick(_justUnder);
      expect(registry.expire(), [_fingerprint(1)]);
    });

    test('a hello from another address does not refresh it', () {
      scanned(_info(1), '192.168.1.10');
      tick(const Duration(seconds: 20));
      expect(hello(_info(1), '192.168.1.66'), isA<Verify>());

      tick(const Duration(seconds: 10));

      expect(registry.expire(), [_fingerprint(1)]);
    });

    test('the devices that came through announcements keep expiring by the '
        'system time and ignore the monotonic clock (RF-53)', () {
      announcedAndVerified(_info(1), '192.168.1.10');
      scanned(_info(2), '192.168.1.20');

      tick(_forever);
      expect(registry.expire(), [_fingerprint(2)]);
      expect(listed(), [_fingerprint(1)]);

      now = _start.add(const Duration(seconds: 31));
      expect(registry.expire(), [_fingerprint(1)]);
    });

    test('a paired device found by a search also leaves the registry at '
        '30 s', () {
      paired.add(_fingerprint(1));
      scanned(_info(1));

      tick(Limits.expireAfter);

      expect(registry.expire(), [_fingerprint(1)]);
    });
  });

  group('which hellos stop the presentation (RF-192, SEC-05)', () {
    test('a hello with the fingerprint of the device from another address '
        'does not stop the presentation, and the device stays listed past '
        '30 s while it is verified', () {
      scanned(_info(1), '192.168.1.10');

      for (var second = 0; second <= 35; second += 5) {
        expect(hello(_info(1), '192.168.1.66'), isA<Verify>());
        expect(due(), [_fingerprint(1)]);
        expect(due(_forever), [_fingerprint(1)]);
        scanned(_info(1), '192.168.1.10');
        tick(const Duration(seconds: 5));
        expect(registry.expire(), isEmpty);
      }

      expect(elapsed, const Duration(seconds: 40));
      expect(listed(), [_fingerprint(1)]);
      expect(registry.devices.single.address.address, '192.168.1.10');
    });

    test('a hello from the registered address through another interface '
        'does not stop the presentation', () {
      scanned(_info(1), '192.168.1.10', 'eth');

      registry.onAnnouncement(_hello(_info(1)), _ip('192.168.1.10'), 'wifi');

      expect(due(_forever), [_fingerprint(1)]);
    });

    test('a hello from the registered address and interface stops it for '
        '10 s', () {
      scanned(_info(1), '192.168.1.10', 'eth');

      expect(hello(_info(1), '192.168.1.10'), isA<Refreshed>());
      expect(due(), isEmpty);

      tick(_quiet - _justUnder);
      expect(due(), isEmpty);
      tick(_justUnder);
      expect(due(), [_fingerprint(1)]);
    });

    test('a hello for a device that only came through announcements leaves '
        'no trace once a search finds it', () {
      announcedAndVerified(_info(1));
      hello(_info(1));

      scanned(_info(1));

      expect(due(_forever), [_fingerprint(1)]);
    });

    test('1000 hellos with invented fingerprints leave no trace: none of '
        'them is ever due, and the device found by a search behaves the '
        'same', () {
      const invented = 20000;
      scanned(_info(1), '192.168.1.10');
      for (var i = 0; i < 1000; i++) {
        final action = registry.onAnnouncement(
          _hello(_info(invented + i)),
          _ip('10.0.${i ~/ 250}.${i % 250 + 1}'),
          'eth',
        );
        expect(action, isNot(isA<Refreshed>()));
      }

      expect(listed(), [_fingerprint(1)]);
      expect(due(), [_fingerprint(1)]);
      expect(due(_forever), [_fingerprint(1)]);

      for (final seed in [invented, invented + 499, invented + 999]) {
        paired.add(_fingerprint(seed));
        scanned(_info(seed), '192.168.9.${seed % 200 + 1}');
      }
      expect(
        due(_forever),
        unorderedEquals([
          _fingerprint(1),
          _fingerprint(invented),
          _fingerprint(invented + 499),
          _fingerprint(invented + 999),
        ]),
      );

      tick(Limits.expireAfter - _justUnder);
      expect(registry.expire(), isEmpty);
      tick(_justUnder);
      expect(registry.expire(), hasLength(4));
    });
  });

  group('memory of the hellos heard (RF-192, SEC)', () {
    test('a hello is forgotten 30 s after it was heard', () {
      scanned(_info(1), '192.168.1.10');
      scanned(_info(2), '192.168.1.20');
      hello(_info(1), '192.168.1.10');
      tick(const Duration(seconds: 15));
      hello(_info(2), '192.168.1.20');
      scanned(_info(1), '192.168.1.10');

      tick(const Duration(seconds: 15));
      expect(registry.expire(), isEmpty);

      expect(due(_forever), [_fingerprint(1)]);
    });

    test('a hello heard 29.999 s ago is still remembered after expire', () {
      scanned(_info(1));
      hello(_info(1));
      tick(Limits.expireAfter - _justUnder);
      expect(registry.expire(), isEmpty);

      expect(due(_forever), isEmpty);
    });

    test('a bye from the current address forgets its hello', () {
      scanned(_info(1));
      hello(_info(1));
      expect(due(_forever), isEmpty);

      registry.onAnnouncement(_bye(_info(1)), _ip('192.168.1.10'), 'eth');
      scanned(_info(1));

      expect(due(_forever), [_fingerprint(1)]);
    });

    test('dropping the interface forgets the hellos of its devices', () {
      scanned(_info(1));
      hello(_info(1));
      expect(due(_forever), isEmpty);

      registry.dropInterface('eth');
      scanned(_info(1));

      expect(due(_forever), [_fingerprint(1)]);
    });

    test('an expired device forgets its hello', () {
      scanned(_info(1));
      hello(_info(1));
      tick(Limits.expireAfter);
      expect(registry.expire(), [_fingerprint(1)]);

      scanned(_info(1));

      expect(due(_forever), [_fingerprint(1)]);
    });

    test('a bye from an unknown device is never taken as a hello', () {
      for (var i = 0; i < 3; i++) {
        registry.onAnnouncement(_bye(_info(1)), _ip('10.0.0.2'), 'eth');
      }
      paired.add(_fingerprint(1));
      scanned(_info(1));

      expect(due(_forever), [_fingerprint(1)]);
    });
  });
}
