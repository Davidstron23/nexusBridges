import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:nexus_bridges_core/src/discovery/discovery.dart';
import 'package:nexus_bridges_core/src/identity/identity.dart';
import 'package:nexus_bridges_core/src/network/network.dart';
import 'package:nexus_bridges_core/src/protocol/protocol.dart';
import 'package:test/test.dart';

import '../server/api_server_harness.dart';

const Duration _oneSecond = Duration(seconds: 1);

InternetAddress _ip(String address) => InternetAddress(address);

List<InternetAddress> _range(String prefix, int from, int to) => [
  for (var host = from; host <= to; host++) _ip('$prefix.$host'),
];

enum _Mode { reset, silentTcp, silentTls }

final class _Farm {
  _Farm._(this.port, this._mode, this._context);

  static Future<_Farm> start(
    List<InternetAddress> addresses, {
    _Mode mode = _Mode.reset,
    SecurityContext? context,
  }) async {
    for (var attempt = 0; attempt < 5; attempt++) {
      final farm = _Farm._(await freePort(), mode, context);
      if (await farm._bindAll(addresses)) {
        addTearDown(farm.close);
        return farm;
      }
      await farm.close();
    }
    throw StateError('no common free port for the farm');
  }

  final int port;
  final _Mode _mode;
  final SecurityContext? _context;
  final List<Future<void> Function()> _closers = [];
  final List<Socket> _sockets = [];
  final List<Future<void>> _closings = [];
  final Map<String, int> hits = {};
  final StreamController<void> _arrivals = StreamController.broadcast();
  int open = 0;
  int maxOpen = 0;

  int get total => hits.values.fold(0, (sum, count) => sum + count);

  Future<void> get allClosed => Future.wait(_closings);

  Future<void> waitForOpen(int count) async {
    final deadline = DateTime.now().add(waitLimit);
    while (open < count) {
      if (DateTime.now().isAfter(deadline)) {
        throw TimeoutException('only $open connections open');
      }
      await _arrivals.stream.first.timeout(waitLimit);
    }
  }

  Future<bool> _bindAll(List<InternetAddress> addresses) async {
    try {
      for (final address in addresses) {
        if (_mode == _Mode.silentTls) {
          final server = await SecureServerSocket.bind(
            address,
            port,
            _context!,
          );
          _closers.add(server.close);
          server.listen(_accept, onError: (Object _) {});
        } else {
          final server = await ServerSocket.bind(address, port);
          _closers.add(server.close);
          server.listen(_accept, onError: (Object _) {});
        }
      }
      return true;
    } on SocketException {
      return false;
    }
  }

  void _accept(Socket socket) {
    final key = socket.address.address;
    hits[key] = (hits[key] ?? 0) + 1;
    if (_mode == _Mode.reset) {
      socket.destroy();
      return;
    }
    _sockets.add(socket);
    open++;
    maxOpen = max(maxOpen, open);
    final closed = Completer<void>();
    _closings.add(closed.future);
    void finish() {
      if (closed.isCompleted) return;
      open--;
      closed.complete();
    }

    socket.done.ignore();
    socket.listen(
      (_) {},
      onError: (Object _) => finish(),
      onDone: finish,
      cancelOnError: true,
    );
    _arrivals.add(null);
  }

  Future<void> close() async {
    for (final socket in _sockets) {
      socket.destroy();
    }
    await Future.wait([for (final close in _closers) close()]);
    await _arrivals.close();
  }
}

Future<int> _lyingPeer(DeviceIdentity certificate, DeviceInfo body) async {
  final server = await SecureServerSocket.bind(
    loopback,
    0,
    presenting(certificate),
  );
  addTearDown(server.close);
  final payload = utf8.encode(jsonEncode(body.toJson()));
  server.listen((socket) {
    socket.done.ignore();
    var replied = false;
    socket.listen(
      (_) {
        if (replied) return;
        replied = true;
        socket
          ..add(
            utf8.encode(
              'HTTP/1.1 200 OK\r\n'
              'content-type: $jsonContentType\r\n'
              'content-length: ${payload.length}\r\n'
              'connection: close\r\n\r\n',
            ),
          )
          ..add(payload);
        socket.close().ignore();
      },
      onError: (Object _) {},
      cancelOnError: true,
    );
  }, onError: (Object _) {});
  return server.port;
}

void main() {
  late DeviceIdentity alice;
  late DeviceIdentity bob;
  late DeviceIdentity carol;
  late DeviceVerifier verifier;
  late DeviceInfo self;

  setUpAll(() {
    alice = DeviceIdentity.generate(commonName: randomCommonName());
    bob = DeviceIdentity.generate(commonName: randomCommonName());
    carol = DeviceIdentity.generate(commonName: randomCommonName());
    verifier = DeviceVerifier(identity: bob);
    self = callerInfoOf(bob);
  });

  ActiveInterface iface(String address, int prefixLength, {String? id}) =>
      ActiveInterface(
        id: id ?? 'test#$address/$prefixLength',
        adapterId: 'test',
        friendlyName: 'Loopback Pseudo-Interface 1',
        subnet: Ipv4Subnet(_ip(address), prefixLength),
      );

  group('scan with injected hosts (RF-54)', () {
    test('it finds the real server among hosts without a server, emits only '
        'that hit with its interface and ends', () async {
      final harness = await ServerHarness.start(identity: alice);
      final first = iface('127.0.0.1', 8, id: 'first');
      final second = iface('127.0.0.1', 8, id: 'second');
      final scanner = SubnetScanner(
        verifier: verifier,
        port: harness.port,
        hostsOf: (i) => i.id == 'first'
            ? [loopback, _ip('127.0.0.2'), _ip('127.0.0.3')]
            : const [],
      );

      final results = await scanner
          .scan(active: [first, second], self: self)
          .toList()
          .timeout(const Duration(seconds: 10));

      expect(results, hasLength(1));
      final (info, address, via) = results.single;
      expect(info.toJson(), selfInfoOf(alice).toJson());
      expect(address, loopback);
      expect(via, same(first));
      expect(harness.registrations.single.caller.toJson(), self.toJson());
    });

    test('a host whose body does not match its certificate is not '
        'emitted', () async {
      final port = await _lyingPeer(alice, selfInfoOf(carol));
      final scanner = SubnetScanner(
        verifier: verifier,
        port: port,
        hostsOf: (_) => [loopback],
      );

      final results = await scanner
          .scan(active: [iface('127.0.0.1', 8)], self: self)
          .toList()
          .timeout(const Duration(seconds: 5));

      expect(results, isEmpty);
    });

    test('with 300 hosts it tries only the first 254, each once', () async {
      final first = _range('127.0.0', 1, 254);
      final extra = _range('127.0.1', 1, 46);
      final farm = await _Farm.start([...first, ...extra]);
      final scanner = SubnetScanner(
        verifier: verifier,
        port: farm.port,
        hostsOf: (_) => [...first, ...extra],
      );

      final results = await scanner
          .scan(active: [iface('127.0.0.1', 8)], self: self)
          .toList()
          .timeout(const Duration(seconds: 20));

      expect(results, isEmpty);
      expect(farm.total, 254);
      expect(farm.hits.keys, unorderedEquals(first.map((a) => a.address)));
      expect(farm.hits.values, everyElement(1));
    });

    test('the cap of 254 applies to each interface on its own', () async {
      final many = [..._range('127.0.0', 1, 254), ..._range('127.0.1', 1, 46)];
      final few = _range('127.0.2', 1, 10);
      final farm = await _Farm.start([...many, ...few]);
      final scanner = SubnetScanner(
        verifier: verifier,
        port: farm.port,
        hostsOf: (i) => i.id == 'many' ? many : few,
      );

      await scanner
          .scan(
            active: [
              iface('127.0.0.1', 8, id: 'many'),
              iface('127.0.0.1', 8, id: 'few'),
            ],
            self: self,
          )
          .toList()
          .timeout(const Duration(seconds: 20));

      expect(farm.total, 264);
      expect(farm.hits.keys.where((k) => k.startsWith('127.0.1.')), isEmpty);
      expect(
        farm.hits.keys.where((k) => k.startsWith('127.0.2.')),
        hasLength(10),
      );
    });
  });

  group('default hosts: the /24 block inside the real subnet (RF-54, '
      'v2.8 point 12)', () {
    test('for 192.168.50.21/24 the rule gives the 253 other hosts of the '
        'block', () {
      final subnet = Ipv4Subnet(_ip('192.168.50.21'), 24);

      final hosts = subnet.slash24Hosts().where(subnet.contains).toList();

      expect(hosts, hasLength(253));
      expect(hosts.map((a) => a.address), isNot(contains('192.168.50.21')));
      expect(
        hosts.map((a) => a.address),
        everyElement(startsWith('192.168.50.')),
      );
      expect(hosts.first.address, '192.168.50.1');
      expect(hosts.last.address, '192.168.50.254');
    });

    test('for a VPN 10.2.0.2/32 the rule gives no host', () {
      final subnet = Ipv4Subnet(_ip('10.2.0.2'), 32);

      expect(subnet.slash24Hosts().where(subnet.contains), isEmpty);
    });

    test('a real scan of a VPN 10.2.0.2/32 tries nothing and ends at '
        'once', () async {
      final scanner = SubnetScanner(verifier: verifier);
      final watch = Stopwatch()..start();

      final results = await scanner
          .scan(active: [iface('10.2.0.2', 32)], self: self)
          .toList()
          .timeout(const Duration(seconds: 5));

      expect(results, isEmpty);
      expect(watch.elapsed, lessThan(const Duration(milliseconds: 500)));
    });

    test('a real scan of 127.0.0.21/24 tries the other 253 hosts of the '
        'block once each', () async {
      final farm = await _Farm.start(_range('127.0.0', 1, 254));
      final scanner = SubnetScanner(verifier: verifier, port: farm.port);

      await scanner
          .scan(active: [iface('127.0.0.21', 24)], self: self)
          .toList()
          .timeout(const Duration(seconds: 20));

      expect(farm.total, 253);
      expect(farm.hits.keys, isNot(contains('127.0.0.21')));
      expect(farm.hits.values, everyElement(1));
    });

    test('a real scan of 127.0.0.21/16 still stays in its /24 block', () async {
      final farm = await _Farm.start([
        ..._range('127.0.0', 1, 254),
        ..._range('127.0.1', 1, 5),
      ]);
      final scanner = SubnetScanner(verifier: verifier, port: farm.port);

      await scanner
          .scan(active: [iface('127.0.0.21', 16)], self: self)
          .toList()
          .timeout(const Duration(seconds: 20));

      expect(farm.total, 253);
      expect(farm.hits.keys.where((k) => k.startsWith('127.0.1.')), isEmpty);
    });

    test('a real scan of 127.0.0.21/25 tries only the hosts of its '
        'subnet', () async {
      final farm = await _Farm.start(_range('127.0.0', 1, 254));
      final scanner = SubnetScanner(verifier: verifier, port: farm.port);

      await scanner
          .scan(active: [iface('127.0.0.21', 25)], self: self)
          .toList()
          .timeout(const Duration(seconds: 20));

      expect(farm.total, 126);
      expect(
        farm.hits.keys,
        unorderedEquals([
          for (var host = 1; host <= 127; host++)
            if (host != 21) '127.0.0.$host',
        ]),
      );
    });

    test('a real scan of 127.0.0.21/32 tries nothing and ends', () async {
      final farm = await _Farm.start(_range('127.0.0', 1, 254));
      final scanner = SubnetScanner(verifier: verifier, port: farm.port);

      final results = await scanner
          .scan(active: [iface('127.0.0.21', 32)], self: self)
          .toList()
          .timeout(const Duration(seconds: 5));

      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(results, isEmpty);
      expect(farm.total, 0);
    });
  });

  group('parallelism and abort', () {
    test('an already aborted signal tries nothing and ends', () async {
      final farm = await _Farm.start(_range('127.0.0', 1, 20));
      final scanner = SubnetScanner(
        verifier: verifier,
        port: farm.port,
        hostsOf: (_) => _range('127.0.0', 1, 20),
      );

      final results = await scanner
          .scan(
            active: [iface('127.0.0.1', 8)],
            self: self,
            abort: AbortSignal()..abort(),
          )
          .toList()
          .timeout(const Duration(seconds: 5));

      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(results, isEmpty);
      expect(farm.total, 0);
    });

    test('with silent TLS hosts it keeps exactly ${Limits.scanConcurrency} '
        'at once, and aborting ends the scan, closes them and launches no '
        'more', () async {
      final hosts = _range('127.0.0', 1, 254);
      final farm = await _Farm.start(
        hosts,
        mode: _Mode.silentTls,
        context: presenting(alice),
      );
      final scanner = SubnetScanner(
        verifier: verifier,
        port: farm.port,
        hostsOf: (_) => hosts,
      );
      final signal = AbortSignal();

      final done = scanner
          .scan(active: [iface('127.0.0.1', 8)], self: self, abort: signal)
          .toList();
      await farm.waitForOpen(Limits.scanConcurrency);
      await Future<void>.delayed(const Duration(milliseconds: 200));
      expect(farm.maxOpen, Limits.scanConcurrency);
      expect(farm.total, Limits.scanConcurrency);

      final watch = Stopwatch()..start();
      signal.abort();
      final results = await done.timeout(_oneSecond);
      expect(watch.elapsed, lessThan(_oneSecond));
      await farm.allClosed.timeout(_oneSecond);
      await Future<void>.delayed(const Duration(milliseconds: 300));

      expect(results, isEmpty);
      expect(farm.total, Limits.scanConcurrency);
      expect(signal.listenerCount, 0);
    });

    test('with hosts that accept TCP and never answer TLS, aborting ends the '
        'scan within 1 s and closes their sockets', () async {
      final hosts = _range('127.0.0', 1, 254);
      final farm = await _Farm.start(hosts, mode: _Mode.silentTcp);
      final scanner = SubnetScanner(
        verifier: verifier,
        port: farm.port,
        hostsOf: (_) => hosts,
      );
      final signal = AbortSignal();

      final done = scanner
          .scan(active: [iface('127.0.0.1', 8)], self: self, abort: signal)
          .toList();
      await farm.waitForOpen(Limits.scanConcurrency);
      await Future<void>.delayed(const Duration(milliseconds: 200));

      final watch = Stopwatch()..start();
      signal.abort();
      await done.timeout(const Duration(seconds: 5));
      expect(watch.elapsed, lessThan(_oneSecond));
      await farm.allClosed.timeout(_oneSecond);
    });
  });
}
