import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:nexus_bridges_core/src/discovery/multicast.dart';
import 'package:nexus_bridges_core/src/network/network.dart';
import 'package:nexus_bridges_core/src/protocol/protocol.dart';
import 'package:test/test.dart';

import '../support/infra.dart';

typedef _Received = (Announcement, InternetAddress, ActiveInterface);

const Duration _arrivalLimit = Duration(seconds: 5);
const Duration _silence = Duration(milliseconds: 300);
const Timeout _childTimeout = Timeout(Duration(minutes: 6));

final InternetAddress _first = InternetAddress('127.0.0.1');
final InternetAddress _second = InternetAddress('127.0.0.2');
final InternetAddress _third = InternetAddress('127.0.0.3');

late String _loopbackName;

String _fingerprint(int seed) =>
    seed.toRadixString(16).toUpperCase().padLeft(64, 'F');

DeviceInfo _info(int seed, {String? name}) => DeviceInfo(
  name: name ?? 'Device $seed',
  fingerprint: _fingerprint(seed),
  port: 40000 + seed,
  protocol: protocolVersion,
  deviceType: seed.isEven ? DeviceType.desktop : DeviceType.mobile,
);

Announcement _hello(int seed) =>
    Announcement(AnnouncementKind.hello, _info(seed));

Map<String, Object?> _wire(int seed) => {
  'kind': 'hello',
  ..._info(seed).toJson(),
};

List<int> _bytes(Object? json) => utf8.encode(jsonEncode(json));

ActiveInterface _loopback(
  String address, {
  int prefixLength = 8,
  String adapterId = 'loopback',
  String? friendlyName,
}) => ActiveInterface(
  id: '$adapterId#$address',
  adapterId: adapterId,
  friendlyName: friendlyName ?? _loopbackName,
  subnet: Ipv4Subnet(InternetAddress(address), prefixLength),
);

Future<String> _systemLoopbackName() async {
  final all = await NetworkInterface.list(includeLoopback: true);
  return all
      .firstWhere((i) => i.addresses.any((a) => a.address == '127.0.0.1'))
      .name;
}

Future<int> _freePort() =>
    pickPort(tcp: [InternetAddress.anyIPv4], udp: [InternetAddress.anyIPv4]);

Future<RawDatagramSocket> _socketOn(InternetAddress address) async {
  final socket = await RawDatagramSocket.bind(address, 0, reuseAddress: false);
  addTearDown(socket.close);
  return socket;
}

Future<void> _quiet() => Future<void>.delayed(_silence);

final class _Fixture {
  _Fixture._(this.channel, this.port, this.logs);

  final MulticastChannel channel;
  final int port;
  final List<String> logs;
  final List<_Received> received = [];
  final List<(int, Completer<void>)> _waiters = [];

  static Future<_Fixture> create({bool open = true}) async {
    final port = await _freePort();
    final logs = <String>[];
    final channel = MulticastChannel(port: port, log: logs.add);
    addTearDown(channel.close);
    final fixture = _Fixture._(channel, port, logs);
    final subscription = channel.incoming.listen(fixture._add);
    addTearDown(subscription.cancel);
    if (open) await channel.open();
    return fixture;
  }

  List<String> get fingerprints => [
    for (final (announcement, _, _) in received) announcement.info.fingerprint,
  ];

  Future<void> waitFor(int count) {
    if (received.length >= count) return Future<void>.value();
    final completer = Completer<void>();
    _waiters.add((count, completer));
    return completer.future.timeout(scaled(_arrivalLimit));
  }

  Future<void> inject(RawDatagramSocket from, List<int> bytes) async {
    final deadline = DateTime.now().add(scaled(_arrivalLimit));
    while (from.send(bytes, InternetAddress.loopbackIPv4, port) !=
        bytes.length) {
      if (DateTime.now().isAfter(deadline)) fail('datagram not sent');
      await Future<void>.delayed(const Duration(milliseconds: 1));
    }
  }

  void _add(_Received event) {
    received.add(event);
    for (final (count, completer) in _waiters) {
      if (received.length >= count && !completer.isCompleted) {
        completer.complete();
      }
    }
  }
}

final class _Probe {
  _Probe._(this.socket);

  final RawDatagramSocket socket;
  final List<Uint8List> datagrams = [];

  static Future<_Probe> bind(InternetAddress address, int port) async {
    final socket = await RawDatagramSocket.bind(
      address,
      port,
      reuseAddress: false,
    );
    final probe = _Probe._(socket);
    final subscription = socket.listen((event) {
      if (event != RawSocketEvent.read) return;
      Datagram? datagram;
      while ((datagram = socket.receive()) != null) {
        probe.datagrams.add(datagram!.data);
      }
    });
    addTearDown(() async {
      await subscription.cancel();
      socket.close();
    });
    return probe;
  }

  List<String?> get fingerprints => [
    for (final bytes in datagrams)
      Announcement.tryDecode(bytes)?.info.fingerprint,
  ];
}

const String _holdUdpPortScript = '''
import 'dart:io';

Future<void> main() async {
  final socket = await RawDatagramSocket.bind(
    InternetAddress.anyIPv4,
    0,
    reuseAddress: false,
  );
  stdout.writeln(socket.port);
  await stdin.drain<void>();
  socket.close();
}
''';

const String _socketAccountingScript = r'''
import 'dart:async';
import 'dart:io';

import 'package:nexus_bridges_core/src/discovery/multicast.dart';
import 'package:nexus_bridges_core/src/network/network.dart';
import 'package:nexus_bridges_core/src/protocol/protocol.dart';

Future<int> udpSockets() async {
  final result = await Process.run('netstat', ['-ano', '-p', 'UDP']);
  final own = '$pid';
  return '${result.stdout}'
      .split('\n')
      .map((line) => line.trim().split(RegExp(r'\s+')))
      .where((cells) => cells.first == 'UDP' && cells.last == own)
      .length;
}

Future<void> main() async {
  final probe = await ServerSocket.bind(InternetAddress.anyIPv4, 0);
  final port = probe.port;
  await probe.close();
  final all = await NetworkInterface.list(includeLoopback: true);
  final name = all
      .firstWhere((i) => i.addresses.any((a) => a.address == '127.0.0.1'))
      .name;
  ActiveInterface iface(String address) => ActiveInterface(
    id: 'loopback#$address',
    adapterId: 'loopback',
    friendlyName: name,
    subnet: Ipv4Subnet(InternetAddress(address), 8),
  );
  final a = iface('127.0.0.1');
  final b = iface('127.0.0.2');
  final hello = Announcement(
    AnnouncementKind.hello,
    DeviceInfo(
      name: 'child',
      fingerprint: 'A' * 64,
      port: port,
      protocol: protocolVersion,
      deviceType: DeviceType.desktop,
    ),
  );
  final channel = MulticastChannel(port: port);
  final arrived = Completer<void>();
  channel.incoming.listen((_) {
    if (!arrived.isCompleted) arrived.complete();
  });
  final base = await udpSockets();
  Future<void> report(String step) async {
    print('$step ${await udpSockets() - base}');
  }

  await channel.syncInterfaces([a]);
  channel.send(hello, a);
  await report('closed');
  await channel.open();
  await report('open');
  await channel.open();
  await report('open-again');
  await channel.syncInterfaces([a]);
  await report('one');
  await channel.syncInterfaces([a]);
  await report('one-again');
  await channel.syncInterfaces([a, b]);
  await report('two');
  await channel.syncInterfaces([b]);
  await report('removed');
  await channel.syncInterfaces([]);
  await report('empty');
  await channel.syncInterfaces([a]);
  channel.send(hello, a);
  await arrived.future.timeout(const Duration(seconds: 5));
  print('received');
  await channel.close();
  await report('closed-again');
  await channel.syncInterfaces([a]);
  channel.send(hello, a);
  await report('after-close');
  await channel.open();
  await channel.syncInterfaces([a, b]);
  await channel.close();
  await report('reopened-and-closed');
}
''';

Future<Directory> _scriptDir() async {
  final dir = await Directory.systemTemp.createTemp('nexus_multicast_');
  addTearDown(() => dir.delete(recursive: true));
  return dir;
}

void main() {
  setUpAll(() async {
    _loopbackName = await _systemLoopbackName();
  });

  group('send and receive over loopback (RF-39, RF-40)', () {
    test('a hello sent through the loopback interface comes back on incoming '
        'with that via, origin 127.0.0.1 and exactly the six fields', () async {
      final f = await _Fixture.create();
      final iface = _loopback('127.0.0.1');
      await f.channel.syncInterfaces([iface]);
      final sent = _hello(1);

      f.channel.send(sent, iface);
      await f.waitFor(1);

      final (announcement, from, via) = f.received.single;
      expect(from, _first);
      expect(via, same(iface));
      expect(jsonDecode(utf8.decode(announcement.encode())), {
        'kind': 'hello',
        'name': 'Device 1',
        'fingerprint': _fingerprint(1),
        'port': 40001,
        'protocol': protocolVersion,
        'deviceType': 'mobile',
      });
      expect(announcement.encode(), sent.encode());
      expect(f.logs, isEmpty);
    });

    test('a bye arrives as a bye with its own fields', () async {
      final f = await _Fixture.create();
      final iface = _loopback('127.0.0.1');
      await f.channel.syncInterfaces([iface]);

      f.channel.send(Announcement(AnnouncementKind.bye, _info(2)), iface);
      await f.waitFor(1);

      final (announcement, _, _) = f.received.single;
      expect(announcement.kind, AnnouncementKind.bye);
      expect(jsonDecode(utf8.decode(announcement.encode())), {
        'kind': 'bye',
        'name': 'Device 2',
        'fingerprint': _fingerprint(2),
        'port': 40002,
        'protocol': protocolVersion,
        'deviceType': 'desktop',
      });
    });

    test('a device without a name still travels with the six keys and a '
        'null name', () async {
      final f = await _Fixture.create();
      final iface = _loopback('127.0.0.1');
      await f.channel.syncInterfaces([iface]);
      final nameless = Announcement(
        AnnouncementKind.hello,
        DeviceInfo(
          name: null,
          fingerprint: _fingerprint(3),
          port: 40003,
          protocol: protocolVersion,
          deviceType: DeviceType.desktop,
        ),
      );

      f.channel.send(nameless, iface);
      await f.waitFor(1);

      final (announcement, _, _) = f.received.single;
      final fields = jsonDecode(utf8.decode(announcement.encode())) as Map;
      expect(fields.keys, unorderedEquals(_wire(3).keys));
      expect(fields['name'], isNull);
      expect(announcement.info.name, isNull);
    });

    test('three sends one after another through the same interface each '
        'arrive once', () async {
      final f = await _Fixture.create();
      final iface = _loopback('127.0.0.1');
      await f.channel.syncInterfaces([iface]);

      for (final seed in [4, 5, 6]) {
        f.channel.send(_hello(seed), iface);
        await f.waitFor(f.received.length + 1);
      }
      await _quiet();

      expect(f.fingerprints, [
        _fingerprint(4),
        _fingerprint(5),
        _fingerprint(6),
      ]);
    });
  });

  group('bursts through one interface', () {
    test('8 sends in a row without waiting, as many as the queue holds, all '
        'arrive in order and nothing is logged', () async {
      final f = await _Fixture.create();
      final iface = _loopback('127.0.0.1');
      await f.channel.syncInterfaces([iface]);
      final seeds = [for (var seed = 10; seed < 18; seed++) seed];

      for (final seed in seeds) {
        f.channel.send(_hello(seed), iface);
      }
      await f.waitFor(seeds.length);
      await _quiet();

      expect(f.fingerprints, [for (final seed in seeds) _fingerprint(seed)]);
      expect(f.logs, isEmpty);
    });

    test('20 sends in a row without waiting arrive in order, every one that '
        'does not arrive is logged as a full queue, and the newest 8 always '
        'arrive', () async {
      final f = await _Fixture.create();
      final iface = _loopback('127.0.0.1');
      await f.channel.syncInterfaces([iface]);
      final seeds = [for (var seed = 10; seed < 30; seed++) seed];
      int dropped() =>
          f.logs.where((l) => l == 'multicast send queue full').length;

      for (final seed in seeds) {
        f.channel.send(_hello(seed), iface);
      }
      await _until(() => f.received.length + dropped() >= seeds.length);
      await _quiet();

      final sent = [for (final seed in seeds) _fingerprint(seed)];
      expect(f.received.length + dropped(), seeds.length);
      expect(f.fingerprints, [
        for (final fingerprint in sent)
          if (f.fingerprints.contains(fingerprint)) fingerprint,
      ]);
      expect(f.fingerprints, containsAll(sent.skip(seeds.length - 8)));
      expect(f.logs, everyElement('multicast send queue full'));
    });

    test('a hello followed at once by a bye through the same interface both '
        'arrive, in that order', () async {
      final f = await _Fixture.create();
      final iface = _loopback('127.0.0.1');
      await f.channel.syncInterfaces([iface]);

      f.channel.send(_hello(1), iface);
      f.channel.send(Announcement(AnnouncementKind.bye, _info(1)), iface);
      await f.waitFor(2);
      await _quiet();

      expect(
        [for (final (a, _, _) in f.received) a.kind],
        [AnnouncementKind.hello, AnnouncementKind.bye],
      );
      expect(f.fingerprints, [_fingerprint(1), _fingerprint(1)]);
      expect(f.logs, isEmpty);
    });
  });

  group('origin of the datagram (RF-18)', () {
    test('with the interface covering 127.0.0.0/8, a unicast datagram from '
        '127.0.0.2 arrives with from == 127.0.0.2', () async {
      final f = await _Fixture.create();
      final iface = _loopback('127.0.0.1');
      await f.channel.syncInterfaces([iface]);
      final other = await _socketOn(_second);

      await f.inject(other, _bytes(_wire(1)));
      await f.waitFor(1);

      final (announcement, from, via) = f.received.single;
      expect(from, _second);
      expect(via, same(iface));
      expect(announcement.info.fingerprint, _fingerprint(1));
    });

    test('with 127.0.0.1/32 as the only interface, the datagram from '
        '127.0.0.2 is dropped and one from 127.0.0.1 still arrives', () async {
      final f = await _Fixture.create();
      await f.channel.syncInterfaces([
        _loopback('127.0.0.1', prefixLength: 32),
      ]);
      final other = await _socketOn(_second);
      final own = await _socketOn(_first);

      await f.inject(other, _bytes(_wire(1)));
      await f.inject(own, _bytes(_wire(2)));
      await f.waitFor(1);
      await _quiet();

      expect(f.fingerprints, [_fingerprint(2)]);
      expect(f.received.single.$2, _first);
    });

    test('via is the first active interface that admits the origin', () async {
      final f = await _Fixture.create();
      final a = _loopback('127.0.0.1');
      final b = _loopback('127.0.0.2');
      final other = await _socketOn(_second);

      await f.channel.syncInterfaces([a, b]);
      await f.inject(other, _bytes(_wire(1)));
      await f.waitFor(1);
      await f.channel.syncInterfaces([b, a]);
      await f.inject(other, _bytes(_wire(2)));
      await f.waitFor(2);

      expect(f.received[0].$3, same(a));
      expect(f.received[1].$3, same(b));
    });
  });

  group('B-2: the origin is checked before the datagram is decoded', () {
    test('B-2: a valid hello and garbage from an origin that no interface '
        'admits are dropped without a trace, and the origin that is admitted '
        'keeps working, also after a malformed datagram of its own', () async {
      final f = await _Fixture.create();
      await f.channel.syncInterfaces([
        _loopback('127.0.0.1', prefixLength: 32),
      ]);
      final outside = await _socketOn(_second);
      final own = await _socketOn(_first);

      await f.inject(outside, _bytes(_wire(1)));
      await f.inject(outside, utf8.encode('{"kind":'));
      await f.inject(outside, Uint8List.fromList([0xFF, 0xFE, 0x00]));
      await f.inject(own, utf8.encode('{"kind":'));
      await f.inject(own, _bytes(_wire(2)));
      await f.waitFor(1);
      await _quiet();

      expect(f.fingerprints, [_fingerprint(2)]);
      expect(f.logs, isEmpty);
    });

    test('B-2: after the last interface is removed, a valid hello is not '
        'emitted and nothing is logged', () async {
      final f = await _Fixture.create();
      await f.channel.syncInterfaces([_loopback('127.0.0.1')]);
      await f.channel.syncInterfaces([]);
      final own = await _socketOn(_first);

      await f.inject(own, _bytes(_wire(1)));
      await _quiet();

      expect(f.received, isEmpty);
      expect(f.logs, isEmpty);
    });
  });

  group('no active interfaces (RF-18)', () {
    test('an open channel without interfaces emits nothing, also after '
        'syncInterfaces([])', () async {
      final f = await _Fixture.create();
      final own = await _socketOn(_first);
      final other = await _socketOn(_second);

      await f.inject(own, _bytes(_wire(1)));
      await f.inject(other, _bytes(_wire(2)));
      await _quiet();
      expect(f.received, isEmpty);

      await f.channel.syncInterfaces([]);
      await f.inject(own, _bytes(_wire(3)));
      await f.inject(other, _bytes(_wire(4)));
      await _quiet();
      expect(f.received, isEmpty);

      await f.channel.syncInterfaces([_loopback('127.0.0.1')]);
      await f.inject(own, _bytes(_wire(5)));
      await f.waitFor(1);
      expect(f.fingerprints, [_fingerprint(5)]);
    });

    test('send without active interfaces does nothing and does not '
        'throw', () async {
      final f = await _Fixture.create();

      f.channel.send(_hello(1), _loopback('127.0.0.1'));
      await f.channel.syncInterfaces([]);
      f.channel.send(_hello(2), _loopback('127.0.0.1'));
      await _quiet();

      expect(f.received, isEmpty);
      expect(f.logs, isEmpty);
    });

    test('send through an interface that is not active does not reach the '
        'group', () async {
      final f = await _Fixture.create();
      final active = _loopback('127.0.0.1');
      await f.channel.syncInterfaces([active]);

      f.channel.send(_hello(1), _loopback('127.0.0.2'));
      f.channel.send(_hello(2), active);
      await f.waitFor(1);
      await _quiet();

      expect(f.fingerprints, [_fingerprint(2)]);
    });
  });

  group('broken datagrams (RF-56)', () {
    final lowercase = _wire(1)..['fingerprint'] = _fingerprint(1).toLowerCase();
    final oversizedBase = _bytes(_wire(1)..['name'] = '').length;
    final oversized = _bytes(_wire(1)..['name'] = 'x' * (2000 - oversizedBase));
    final broken = <String, List<int>>{
      'invalid JSON': utf8.encode('{"kind":"hello","fingerprint":'),
      'no fingerprint': _bytes(_wire(1)..remove('fingerprint')),
      'lowercase fingerprint': _bytes(lowercase),
      'protocol "2.0"': _bytes(_wire(1)..['protocol'] = '2.0'),
      '2000 bytes': oversized,
      'kind "x"': _bytes(_wire(1)..['kind'] = 'x'),
      'one extra key': _bytes(_wire(1)..['extra'] = 1),
    };

    test('the test data is what the case names say, and the size limit is '
        'the only thing wrong with the 2000-byte one', () {
      final atLimit = _bytes(
        _wire(1)..['name'] = 'x' * (maxDatagramBytes - oversizedBase),
      );
      expect(oversized, hasLength(2000));
      expect(atLimit, hasLength(maxDatagramBytes));
      expect(lowercase['fingerprint'], isNot(_fingerprint(1)));
      expect(
        Announcement.tryDecode(Uint8List.fromList(_bytes(_wire(1)))),
        isNotNull,
      );
      expect(Announcement.tryDecode(Uint8List.fromList(atLimit)), isNotNull);
    });

    for (final MapEntry(key: name, value: bytes) in broken.entries) {
      test('$name is dropped and the channel keeps receiving', () async {
        final f = await _Fixture.create();
        final iface = _loopback('127.0.0.1');
        await f.channel.syncInterfaces([iface]);
        final own = await _socketOn(_first);

        await f.inject(own, bytes);
        await f.inject(own, _bytes(_wire(2)));
        f.channel.send(_hello(3), iface);
        await f.waitFor(2);
        await _quiet();

        expect(
          f.fingerprints,
          unorderedEquals([_fingerprint(2), _fingerprint(3)]),
        );
      });
    }

    test('all seven in a row, plus an empty datagram and bytes that are not '
        'UTF-8, are dropped and the channel keeps working', () async {
      final f = await _Fixture.create();
      final iface = _loopback('127.0.0.1');
      await f.channel.syncInterfaces([iface]);
      final own = await _socketOn(_first);
      final other = await _socketOn(_second);

      for (final bytes in broken.values) {
        await f.inject(own, bytes);
        await f.inject(other, bytes);
      }
      await f.inject(own, const []);
      await f.inject(own, const [0xFF, 0xFE, 0xFD]);
      await f.inject(other, _bytes(_wire(2)));
      f.channel.send(_hello(3), iface);
      await f.waitFor(2);
      await _quiet();

      expect(
        f.fingerprints,
        unorderedEquals([_fingerprint(2), _fingerprint(3)]),
      );
    });
  });

  group('one adapter, two interfaces', () {
    test('joining for both does not fail and one send through each arrives '
        'twice', () async {
      final f = await _Fixture.create();
      final a = _loopback('127.0.0.1');
      final b = _loopback('127.0.0.2');

      await f.channel.syncInterfaces([a, b]);
      f.channel.send(_hello(1), a);
      f.channel.send(_hello(2), b);
      await f.waitFor(2);
      await _quiet();

      expect(f.logs, isEmpty);
      expect(
        f.fingerprints,
        unorderedEquals([_fingerprint(1), _fingerprint(2)]),
      );
    });

    test('removing one keeps receiving through the other, and the removed '
        'one no longer sends', () async {
      final f = await _Fixture.create();
      final a = _loopback('127.0.0.1');
      final b = _loopback('127.0.0.2');
      await f.channel.syncInterfaces([a, b]);

      await f.channel.syncInterfaces([b]);
      f.channel.send(_hello(1), a);
      f.channel.send(_hello(2), b);
      await f.waitFor(1);
      await _quiet();

      expect(f.logs, isEmpty);
      expect(f.fingerprints, [_fingerprint(2)]);
      expect(f.received.single.$3, same(b));
    });

    test('syncInterfaces twice with the same list joins once and sends '
        'once', () async {
      final f = await _Fixture.create();
      final a = _loopback('127.0.0.1');
      final b = _loopback('127.0.0.2');

      await f.channel.syncInterfaces([a, b]);
      await f.channel.syncInterfaces([a, b]);
      f.channel.send(_hello(1), a);
      await f.waitFor(1);
      await _quiet();

      expect(f.logs, isEmpty);
      expect(f.fingerprints, [_fingerprint(1)]);
    });

    test('a repeated sync does not inflate the adapter count: replacing the '
        'interface with one of another adapter on the same system interface '
        'leaves and joins again cleanly', () async {
      final f = await _Fixture.create();
      final a = _loopback('127.0.0.1');
      final c = _loopback('127.0.0.3', adapterId: 'other');

      await f.channel.syncInterfaces([a]);
      await f.channel.syncInterfaces([a]);
      await f.channel.syncInterfaces([c]);
      f.channel.send(_hello(1), c);
      await f.waitFor(1);

      expect(f.logs, isEmpty);
      expect(f.received.single.$3, same(c));
    });

    test('an empty list stops receiving and sending, and the next sync joins '
        'again cleanly', () async {
      final f = await _Fixture.create();
      final a = _loopback('127.0.0.1');
      final b = _loopback('127.0.0.2');
      final own = await _socketOn(_first);
      await f.channel.syncInterfaces([a, b]);

      await f.channel.syncInterfaces([]);
      await f.inject(own, _bytes(_wire(1)));
      f.channel.send(_hello(2), a);
      f.channel.send(_hello(3), b);
      await _quiet();
      expect(f.received, isEmpty);

      await f.channel.syncInterfaces([a]);
      f.channel.send(_hello(4), a);
      await f.waitFor(1);
      await _quiet();

      expect(f.logs, isEmpty);
      expect(f.fingerprints, [_fingerprint(4)]);
    });

    test('an interface whose system interface is not found still sends, is '
        'logged, and the channel keeps working', () async {
      final f = await _Fixture.create();
      final ghost = _loopback(
        '127.0.0.2',
        adapterId: 'ghost',
        friendlyName: 'No Such Interface',
      );
      final a = _loopback('127.0.0.1');

      await f.channel.syncInterfaces([ghost, a]);
      f.channel.send(_hello(1), ghost);
      await f.waitFor(1);

      expect(f.logs, hasLength(1));
      expect(f.received.single.$3, same(ghost));
    });
  });

  group('unicast with sendTo (RF-45, plan v2.11 point 1)', () {
    test('sendTo through the loopback interface to 127.0.0.1 at the channel '
        'port arrives on incoming with exactly that announcement, that via '
        'and origin 127.0.0.1', () async {
      final f = await _Fixture.create();
      final iface = _loopback('127.0.0.1');
      await f.channel.syncInterfaces([iface]);
      final sent = _hello(1);

      f.channel.sendTo(sent, iface, _first);
      await f.waitFor(1);
      await _quiet();

      final (announcement, from, via) = f.received.single;
      expect(from, _first);
      expect(via, same(iface));
      expect(announcement.kind, AnnouncementKind.hello);
      expect(announcement.encode(), sent.encode());
      expect(jsonDecode(utf8.decode(announcement.encode())), _wire(1));
      expect(f.logs, isEmpty);
    });

    test('a bye sent with sendTo arrives as a bye', () async {
      final f = await _Fixture.create();
      final iface = _loopback('127.0.0.1');
      await f.channel.syncInterfaces([iface]);
      final sent = Announcement(AnnouncementKind.bye, _info(2));

      f.channel.sendTo(sent, iface, _first);
      await f.waitFor(1);

      expect(f.received.single.$1.encode(), sent.encode());
    });

    test('sendTo to another address goes only there: a socket on 127.0.0.3 '
        'and the channel port gets the exact bytes and incoming gets '
        'nothing', () async {
      final f = await _Fixture.create();
      final iface = _loopback('127.0.0.1');
      await f.channel.syncInterfaces([iface]);
      final probe = await _Probe.bind(_third, f.port);
      final sent = _hello(3);

      f.channel.sendTo(sent, iface, _third);
      await _until(() => probe.datagrams.isNotEmpty);
      await _quiet();

      expect(probe.datagrams.single, sent.encode());
      expect(f.received, isEmpty);
      expect(f.logs, isEmpty);
    });

    test('a burst that is still queued when the channel closes is sent '
        'before the sockets close', () async {
      final f = await _Fixture.create();
      final iface = _loopback('127.0.0.1');
      await f.channel.syncInterfaces([iface]);
      final probe = await _Probe.bind(_third, f.port);
      final sent = [for (var i = 1; i <= 8; i++) _hello(i)];

      for (final announcement in sent) {
        f.channel.sendTo(announcement, iface, _third);
      }
      await f.channel.close();
      await _until(() => probe.datagrams.length == sent.length);
      await _quiet();

      expect(probe.datagrams, [for (final a in sent) a.encode()]);
      expect(f.logs, isEmpty);
    });

    test('sendTo on a channel that was never opened does nothing, does not '
        'throw and keeps nothing for later', () async {
      final f = await _Fixture.create(open: false);
      final iface = _loopback('127.0.0.1');

      await f.channel.syncInterfaces([iface]);
      f.channel.sendTo(_hello(1), iface, _first);
      await f.channel.open();
      await f.channel.syncInterfaces([iface]);
      await _quiet();
      expect(f.received, isEmpty);

      f.channel.sendTo(_hello(2), iface, _first);
      await f.waitFor(1);
      expect(f.fingerprints, [_fingerprint(2)]);
      expect(f.logs, isEmpty);
    });

    test('sendTo after close sends nothing to the destination and keeps '
        'nothing for the next open', () async {
      final f = await _Fixture.create();
      final iface = _loopback('127.0.0.1');
      await f.channel.syncInterfaces([iface]);
      await f.channel.close();
      final probe = await _Probe.bind(_third, f.port);

      f.channel.sendTo(_hello(1), iface, _third);
      f.channel.sendTo(_hello(2), iface, _first);
      await _quiet();
      expect(probe.datagrams, isEmpty);

      await f.channel.open();
      await f.channel.syncInterfaces([iface]);
      await _quiet();
      expect(f.received, isEmpty);
      expect(probe.datagrams, isEmpty);

      f.channel.sendTo(_hello(3), iface, _first);
      await f.waitFor(1);
      expect(f.fingerprints, [_fingerprint(3)]);
      expect(f.logs, isEmpty);
    });

    test('sendTo through an interface that is not active sends nothing to any '
        'destination', () async {
      final f = await _Fixture.create();
      final active = _loopback('127.0.0.1');
      final inactive = _loopback('127.0.0.2');
      await f.channel.syncInterfaces([active]);
      final probe = await _Probe.bind(_third, f.port);

      f.channel.sendTo(_hello(1), inactive, _third);
      f.channel.sendTo(_hello(2), inactive, _first);
      f.channel.sendTo(_hello(3), active, _first);
      await f.waitFor(1);
      await _quiet();

      expect(f.fingerprints, [_fingerprint(3)]);
      expect(probe.datagrams, isEmpty);
      expect(f.logs, isEmpty);
    });

    test('a burst mixing send and sendTo keeps the order and each one '
        'reaches its own destination', () async {
      final f = await _Fixture.create();
      final iface = _loopback('127.0.0.1');
      await f.channel.syncInterfaces([iface]);
      final probe = await _Probe.bind(_third, f.port);

      f.channel.send(_hello(1), iface);
      f.channel.sendTo(_hello(2), iface, _first);
      f.channel.sendTo(_hello(3), iface, _third);
      f.channel.send(_hello(4), iface);
      f.channel.sendTo(_hello(5), iface, _first);
      f.channel.sendTo(_hello(6), iface, _third);
      f.channel.send(_hello(7), iface);
      f.channel.sendTo(_hello(8), iface, _first);
      await f.waitFor(6);
      await _until(() => probe.datagrams.length >= 2);
      await _quiet();

      expect(f.fingerprints, [
        _fingerprint(1),
        _fingerprint(2),
        _fingerprint(4),
        _fingerprint(5),
        _fingerprint(7),
        _fingerprint(8),
      ]);
      expect(probe.fingerprints, [_fingerprint(3), _fingerprint(6)]);
      expect(f.logs, isEmpty);
    });
  });

  group('joining the group again (plan v2.11 point 6)', () {
    test('an interface whose system interface is not found does not join and '
        'logs it, and a later syncInterfaces with the same adapter and its '
        'real name joins and receives', () async {
      final f = await _Fixture.create();
      final ghost = _loopback('127.0.0.1', friendlyName: 'No Such Interface');
      final real = _loopback('127.0.0.1');

      await f.channel.syncInterfaces([ghost]);
      expect(f.logs, hasLength(1));

      await f.channel.syncInterfaces([real]);
      expect(f.logs, hasLength(1));

      f.channel.send(_hello(2), real);
      await _until(() => f.fingerprints.contains(_fingerprint(2)));
      expect(f.received.last.$3, same(real));
    });

    test('a failed join is tried again when the adapter comes back as another '
        'interface with its real name, and it then receives', () async {
      final f = await _Fixture.create();
      final ghost = _loopback('127.0.0.1', friendlyName: 'No Such Interface');
      final real = _loopback('127.0.0.2');

      await f.channel.syncInterfaces([ghost]);
      expect(f.logs, hasLength(1));

      await f.channel.syncInterfaces([real]);
      expect(f.logs, hasLength(1));

      f.channel.send(_hello(2), real);
      await _until(() => f.fingerprints.contains(_fingerprint(2)));
      expect(f.received.last.$3, same(real));
    });

    test('a failed join is tried again on every syncInterfaces until it '
        'works, and logged each time', () async {
      final f = await _Fixture.create();
      final ghost = _loopback('127.0.0.1', friendlyName: 'No Such Interface');

      await f.channel.syncInterfaces([ghost]);
      await f.channel.syncInterfaces([ghost]);
      await f.channel.syncInterfaces([ghost]);

      expect(f.logs, hasLength(3));
    });

    test(
      'with everything joined, repeated syncInterfaces log nothing',
      () async {
        final f = await _Fixture.create();
        final a = _loopback('127.0.0.1');
        final b = _loopback('127.0.0.2');

        for (var i = 0; i < 4; i++) {
          await f.channel.syncInterfaces([a, b]);
        }
        f.channel.send(_hello(1), a);
        await f.waitFor(1);
        await _quiet();

        expect(f.logs, isEmpty);
        expect(f.fingerprints, [_fingerprint(1)]);
      },
    );

    test(
      'after the retry joins, more syncInterfaces log nothing more',
      () async {
        final f = await _Fixture.create();
        final ghost = _loopback('127.0.0.1', friendlyName: 'No Such Interface');
        final real = _loopback('127.0.0.1');

        await f.channel.syncInterfaces([ghost]);
        await f.channel.syncInterfaces([real]);
        await f.channel.syncInterfaces([real]);
        await f.channel.syncInterfaces([real]);

        expect(f.logs, hasLength(1));
      },
    );
  });

  group('lifecycle', () {
    test('a subscription made before close receives again after close, open '
        'and syncInterfaces, and incoming is never closed', () async {
      final port = await _freePort();
      final channel = MulticastChannel(port: port);
      addTearDown(channel.close);
      final iface = _loopback('127.0.0.1');
      final received = <String>[];
      var done = false;
      final subscription = channel.incoming.listen(
        (event) => received.add(event.$1.info.fingerprint),
        onDone: () => done = true,
      );
      addTearDown(subscription.cancel);

      await channel.open();
      await channel.syncInterfaces([iface]);
      channel.send(_hello(1), iface);
      await _until(() => received.length == 1);
      await channel.close();
      await _quiet();
      expect(done, isFalse);

      await channel.open();
      await channel.syncInterfaces([iface]);
      channel.send(_hello(2), iface);
      await _until(() => received.length == 2);

      expect(received, [_fingerprint(1), _fingerprint(2)]);
      expect(done, isFalse);
    });

    test('open on an open channel does nothing', () async {
      final f = await _Fixture.create();
      final iface = _loopback('127.0.0.1');

      await f.channel.open();
      await f.channel.syncInterfaces([iface]);
      f.channel.send(_hello(1), iface);
      await f.waitFor(1);

      expect(f.logs, isEmpty);
    });

    test('syncInterfaces and send before open do nothing and keep nothing '
        'for later', () async {
      final f = await _Fixture.create(open: false);
      final iface = _loopback('127.0.0.1');
      final own = await _socketOn(_first);

      await f.channel.syncInterfaces([iface]);
      f.channel.send(_hello(1), iface);
      await f.channel.open();
      await f.inject(own, _bytes(_wire(2)));
      f.channel.send(_hello(3), iface);
      await _quiet();
      expect(f.received, isEmpty);

      await f.channel.syncInterfaces([iface]);
      await f.inject(own, _bytes(_wire(4)));
      await f.waitFor(1);
      expect(f.fingerprints, [_fingerprint(4)]);
    });

    test('after close, syncInterfaces and send do nothing and keep nothing '
        'for the next open', () async {
      final f = await _Fixture.create();
      final iface = _loopback('127.0.0.1');
      final own = await _socketOn(_first);
      await f.channel.syncInterfaces([iface]);
      await f.channel.close();

      await f.channel.syncInterfaces([iface]);
      f.channel.send(_hello(1), iface);
      await f.channel.open();
      await f.inject(own, _bytes(_wire(2)));
      f.channel.send(_hello(3), iface);
      await _quiet();
      expect(f.received, isEmpty);

      await f.channel.syncInterfaces([iface]);
      f.channel.send(_hello(4), iface);
      await f.waitFor(1);
      expect(f.fingerprints, [_fingerprint(4)]);
      expect(f.logs, isEmpty);
    });

    test('close before open and close twice do not throw', () async {
      final f = await _Fixture.create(open: false);

      await f.channel.close();
      await f.channel.open();
      await f.channel.close();
      await f.channel.close();

      expect(f.logs, isEmpty);
    });
  });

  group('port in use (RF-38)', () {
    test('a UDP port held by another process makes open() throw '
        'PortInUseException(port), and open() works once it is '
        'released', () async {
      final dir = await _scriptDir();
      final script = File('${dir.path}${Platform.pathSeparator}hold_udp.dart');
      await script.writeAsString(_holdUdpPortScript);
      final process = await Process.start(Platform.resolvedExecutable, [
        script.path,
      ]);
      addTearDown(() async {
        process.kill();
        await process.exitCode;
      });
      process.stderr.drain<void>().ignore();
      final port = int.parse(
        (await process.stdout
                .transform(utf8.decoder)
                .transform(const LineSplitter())
                .first
                .timeout(const Duration(seconds: 60)))
            .trim(),
      );
      final channel = MulticastChannel(port: port);
      addTearDown(channel.close);
      final iface = _loopback('127.0.0.1');
      final received = <String>[];
      final subscription = channel.incoming.listen(
        (event) => received.add(event.$1.info.fingerprint),
      );
      addTearDown(subscription.cancel);

      await expectLater(
        channel.open(),
        throwsA(isA<PortInUseException>().having((e) => e.port, 'port', port)),
      );
      await channel.syncInterfaces([iface]);
      channel.send(_hello(1), iface);

      await process.stdin.close();
      expect(await process.exitCode.timeout(const Duration(seconds: 30)), 0);
      await channel.open();
      await channel.syncInterfaces([iface]);
      channel.send(_hello(2), iface);
      await _until(() => received.isNotEmpty);
      await _quiet();

      expect(received, [_fingerprint(2)]);
    }, timeout: _childTimeout);
  });

  group('sockets', () {
    test(
      'a process that uses the channel holds exactly one receiving socket '
      'plus one per active interface, nothing while closed, and ends on '
      'its own after close()',
      () async {
        final packageConfig = await Isolate.packageConfig;
        expect(packageConfig, isNotNull);
        final dir = await _scriptDir();
        final script = File(
          '${dir.path}${Platform.pathSeparator}socket_accounting.dart',
        );
        await script.writeAsString(_socketAccountingScript);
        final process = await Process.start(Platform.resolvedExecutable, [
          '--packages=${packageConfig!.toFilePath()}',
          script.path,
        ]);
        addTearDown(process.kill);
        final stdoutLines = process.stdout
            .transform(utf8.decoder)
            .transform(const LineSplitter())
            .toList();
        final stderrText = process.stderr.transform(utf8.decoder).join();

        final exitCode = await process.exitCode.timeout(
          const Duration(minutes: 4),
        );

        expect(exitCode, 0, reason: await stderrText);
        expect(await stdoutLines, [
          'closed 0',
          'open 1',
          'open-again 1',
          'one 2',
          'one-again 2',
          'two 3',
          'removed 2',
          'empty 1',
          'received',
          'closed-again 0',
          'after-close 0',
          'reopened-and-closed 0',
        ]);
      },
      timeout: _childTimeout,
      testOn: 'windows',
    );
  });
}

Future<void> _until(bool Function() condition) async {
  final deadline = DateTime.now().add(scaled(_arrivalLimit));
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) {
      fail('condition not met within ${scaled(_arrivalLimit)}');
    }
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}
