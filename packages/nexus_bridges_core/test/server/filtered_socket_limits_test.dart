import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:nexus_bridges_core/src/identity/identity.dart';
import 'package:nexus_bridges_core/src/protocol/protocol.dart';
import 'package:nexus_bridges_core/src/server/filtered_secure_server_socket.dart';
import 'package:test/test.dart';

final InternetAddress _loopback = InternetAddress.loopbackIPv4;
final InternetAddress _otherLoopback = InternetAddress('127.0.0.2');
const Duration _longDeadline = Duration(seconds: 60);
const Duration _shortDeadline = Duration(seconds: 1);
const Duration _waitLimit = Duration(seconds: 5);
const Duration _earlyMargin = Duration(milliseconds: 100);
const Duration _lateMargin = Duration(seconds: 2);
const Duration _atOnce = Duration(seconds: 1);

InternetAddress _loopbackNumber(int last) => InternetAddress('127.0.0.$last');

Future<void> _until(
  bool Function() condition, {
  Duration limit = _waitLimit,
  String reason = 'condition',
}) async {
  final watch = Stopwatch()..start();
  while (!condition()) {
    if (watch.elapsed > limit) fail('$reason not met within $limit');
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}

final class _Server {
  _Server._(this.socket, this.http, this.origins);

  final FilteredSecureServerSocket socket;
  final HttpServer http;
  final List<String> origins;
  final List<String> handled = [];

  int get port => socket.port;

  static Future<_Server> start({
    required SecurityContext context,
    Duration deadline = _longDeadline,
  }) async {
    final origins = <String>[];
    final socket = await FilteredSecureServerSocket.bind(
      address: _loopback,
      port: 0,
      context: context,
      allowOrigin: (remote) {
        origins.add(remote.address);
        return true;
      },
      deadline: deadline,
    );
    final server = _Server._(socket, HttpServer.listenOn(socket), origins);
    server.http.listen(server._serve);
    addTearDown(server.close);
    return server;
  }

  Future<void> waitForAccepts(int count) =>
      _until(() => origins.length >= count, reason: '$count accepts');

  Future<void> _serve(HttpRequest request) async {
    final info = request.connectionInfo!;
    final key = '${info.remoteAddress.address}:${info.remotePort}';
    final certificate = request.certificate;
    final seen = certificate == null
        ? 'none'
        : fingerprintOfCertificate(certificate.der);
    handled.add(seen);
    final body = utf8.encode(seen);
    try {
      request.response
        ..persistentConnection = false
        ..contentLength = body.length
        ..add(body);
      await request.response.close();
    } on Object {
      return;
    } finally {
      socket.requestFinished(key);
    }
  }

  Future<void> close() async {
    await http.close(force: true);
    await socket.close();
  }
}

final class _Probe {
  _Probe._(this.socket, this._stopwatch) {
    socket.done.ignore();
    socket.listen(
      (chunk) {
        received.addAll(chunk);
        if (!_data.isCompleted) _data.complete();
      },
      onError: (Object _) => _finish(),
      onDone: _finish,
      cancelOnError: true,
    );
  }

  static Future<_Probe> connect(int port, {InternetAddress? from}) async {
    final stopwatch = Stopwatch()..start();
    final socket = await Socket.connect(_loopback, port, sourceAddress: from);
    addTearDown(socket.destroy);
    return _Probe._(socket, stopwatch);
  }

  final Socket socket;
  final Stopwatch _stopwatch;
  final List<int> received = [];
  final Completer<Duration> _closed = Completer();
  final Completer<void> _data = Completer();

  bool get isClosed => _closed.isCompleted;

  Future<Duration> get closed =>
      _closed.future.timeout(_longDeadline - const Duration(seconds: 5));

  Future<void> get dataArrived => _data.future.timeout(_waitLimit);

  Future<bool> closedWithin(Duration limit) =>
      _closed.future.then((_) => true).timeout(limit, onTimeout: () => false);

  void send(List<int> bytes) {
    try {
      socket.add(bytes);
    } on Object {
      return;
    }
  }

  void _finish() {
    if (!_closed.isCompleted) _closed.complete(_stopwatch.elapsed);
  }
}

Future<String?> _tlsGet(
  int port, {
  required SecurityContext context,
  required String serverFingerprint,
  InternetAddress? from,
}) async {
  try {
    final raw = await Socket.connect(_loopback, port, sourceAddress: from);
    addTearDown(raw.destroy);
    final secure = await SecureSocket.secure(
      raw,
      context: context,
      onBadCertificate: (c) =>
          fingerprintOfCertificate(c.der) == serverFingerprint,
    ).timeout(_waitLimit);
    addTearDown(secure.destroy);
    secure.done.ignore();
    secure.add(utf8.encode('GET / HTTP/1.1\r\nhost: 127.0.0.1\r\n\r\n'));
    final bytes = await secure
        .fold<List<int>>([], (all, chunk) => all..addAll(chunk))
        .timeout(_waitLimit);
    final text = utf8.decode(bytes);
    final end = text.indexOf('\r\n\r\n');
    if (!text.startsWith('HTTP/1.1 200') || end < 0) return null;
    return text.substring(end + 4);
  } on IOException {
    return null;
  } on TimeoutException {
    return null;
  }
}

Future<String?> _servedWithin(
  Duration limit,
  Future<String?> Function() attempt,
) async {
  final watch = Stopwatch()..start();
  while (watch.elapsed < limit) {
    final body = await attempt();
    if (body != null) return body;
    await Future<void>.delayed(const Duration(milliseconds: 50));
  }
  return null;
}

Future<String> _httpsGet(
  int port, {
  required SecurityContext context,
  required String serverFingerprint,
}) async {
  final client = HttpClient(context: context)
    ..badCertificateCallback = (certificate, host, port) =>
        fingerprintOfCertificate(certificate.der) == serverFingerprint;
  try {
    final request = await client.getUrl(Uri.parse('https://127.0.0.1:$port/'));
    final response = await request.close();
    return await response.transform(utf8.decoder).join();
  } finally {
    client.close(force: true);
  }
}

Future<Uint8List> _captureClientHello() async {
  final listener = await ServerSocket.bind(_loopback, 0);
  final hello = Completer<Uint8List>();
  final bytes = BytesBuilder();
  listener.listen((socket) {
    socket.listen(
      (chunk) {
        bytes.add(chunk);
        final data = bytes.toBytes();
        if (data.length >= 5 &&
            data.length >= 5 + (data[3] << 8 | data[4]) &&
            !hello.isCompleted) {
          hello.complete(data);
          socket.destroy();
        }
      },
      onError: (Object _) => socket.destroy(),
      cancelOnError: true,
    );
  });
  unawaited(
    SecureSocket.connect(
      _loopback,
      listener.port,
      onBadCertificate: (_) => true,
    ).then<void>((socket) => socket.destroy(), onError: (Object _) {}),
  );
  try {
    return await hello.future.timeout(_waitLimit);
  } finally {
    await listener.close();
  }
}

Future<int> _startRechunkingProxy(
  int targetPort, {
  required int size,
  required List<int> firstChunkSizes,
}) async {
  final proxy = await ServerSocket.bind(_loopback, 0);
  final open = <Socket>[];
  addTearDown(() async {
    for (final socket in open) {
      socket.destroy();
    }
    await proxy.close();
  });
  proxy.listen((client) async {
    open.add(client);
    client.done.ignore();
    final upstream = await Socket.connect(_loopback, targetPort);
    open.add(upstream);
    upstream.done.ignore();
    upstream.setOption(SocketOption.tcpNoDelay, true);
    upstream.listen(
      client.add,
      onError: (Object _) => client.destroy(),
      onDone: client.destroy,
    );
    var first = true;
    try {
      await for (final chunk in client) {
        if (first) {
          first = false;
          firstChunkSizes.add(chunk.length);
          for (var i = 0; i < chunk.length; i += size) {
            upstream.add(chunk.sublist(i, min(i + size, chunk.length)));
            await upstream.flush();
          }
          continue;
        }
        upstream.add(chunk);
      }
    } on Object {
      client.destroy();
    } finally {
      upstream.destroy();
    }
  });
  return proxy.port;
}

void main() {
  late DeviceIdentity alice;
  late DeviceIdentity bob;
  late Uint8List clientHello;

  setUpAll(() async {
    alice = DeviceIdentity.generate(commonName: randomCommonName());
    bob = DeviceIdentity.generate(commonName: randomCommonName());
    clientHello = await _captureClientHello();
  });

  SecurityContext serverTrustingBob() =>
      alice.serverContext(trustedCertificatesPem: [bob.certificatePem]);

  SecurityContext presenting(DeviceIdentity identity) =>
      identity.serverContext(trustedCertificatesPem: const []);

  Future<String?> legitimate(int port, {InternetAddress? from}) => _tlsGet(
    port,
    context: bob.clientContext(),
    serverFingerprint: alice.fingerprint,
    from: from,
  );

  group('first TLS record before the handshake (A1)', () {
    test('the captured ClientHello used by these tests is one complete TLS '
        'handshake record', () {
      expect(clientHello[0], 0x16);
      expect(clientHello[1], 0x03);
      expect(clientHello.length, 5 + (clientHello[3] << 8 | clientHello[4]));
    });

    test('one byte 0x16 is held until the deadline and then closed, with no '
        'TLS byte back and nothing handed over', () async {
      final server = await _Server.start(
        context: serverTrustingBob(),
        deadline: _shortDeadline,
      );

      final probe = await _Probe.connect(server.port);
      probe.send(const [0x16]);
      final elapsed = await probe.closed;

      expect(elapsed, greaterThanOrEqualTo(_shortDeadline - _earlyMargin));
      expect(elapsed, lessThan(_shortDeadline + _lateMargin));
      expect(probe.received, isEmpty);
      expect(server.handled, isEmpty);
    });

    for (final (label, bytes) in <(String, List<int>)>[
      ("one byte 'A'", ascii.encode('A')),
      ('a plain HTTP request line', ascii.encode('GET / HTTP/1.1\r\n')),
      ('record type 0x17', const [0x17, 0x03, 0x03, 0x00, 0x10]),
      ('record type 0x15', const [0x15, 0x03, 0x03, 0x00, 0x02]),
      ('an SSLv2-style first byte 0x80', const [0x80, 0x2E, 0x01, 0x03, 0x01]),
      ('major version 0x02', const [0x16, 0x02]),
      ('major version 0x04', const [0x16, 0x04]),
      ('minor version 0x00', const [0x16, 0x03, 0x00]),
      ('minor version 0x05', const [0x16, 0x03, 0x05]),
      ('declared length 0', const [0x16, 0x03, 0x01, 0x00, 0x00]),
      ('declared length 16641', const [0x16, 0x03, 0x01, 0x41, 0x01]),
      ('declared length 65535', const [0x16, 0x03, 0x01, 0xFF, 0xFF]),
      ('a high length byte above 0x41', const [0x16, 0x03, 0x03, 0x42]),
    ]) {
      test('$label is destroyed at once, without waiting for the deadline and '
          'without any byte back', () async {
        final server = await _Server.start(context: serverTrustingBob());

        final probe = await _Probe.connect(server.port);
        probe.send(bytes);

        expect(await probe.closedWithin(_lateMargin), isTrue);
        expect(await probe.closed, lessThan(_lateMargin));
        expect(probe.received, isEmpty);
        expect(server.handled, isEmpty);
      });
    }

    for (final (label, bytes) in <(String, List<int>)>[
      ('the prefix 0x16', const [0x16]),
      ('the prefix 0x16 0x03', const [0x16, 0x03]),
      ('the prefix 0x16 0x03 0x01', const [0x16, 0x03, 0x01]),
      ('the prefix 0x16 0x03 0x04', const [0x16, 0x03, 0x04]),
      ('a header declaring 1 byte', const [0x16, 0x03, 0x01, 0x00, 0x01]),
      ('a header declaring 16640 bytes', const [0x16, 0x03, 0x03, 0x41, 0x00]),
    ]) {
      test('control: $label is valid so far and is kept waiting', () async {
        final server = await _Server.start(context: serverTrustingBob());

        final probe = await _Probe.connect(server.port);
        probe.send(bytes);

        expect(
          await probe.closedWithin(const Duration(milliseconds: 700)),
          isFalse,
        );
        expect(probe.received, isEmpty);
      });
    }

    test('a valid record header whose declared length never fully arrives is '
        'closed at the deadline', () async {
      final server = await _Server.start(
        context: serverTrustingBob(),
        deadline: _shortDeadline,
      );

      final probe = await _Probe.connect(server.port);
      probe.send([0x16, 0x03, 0x01, 0x00, 0x40, ...List.filled(0x3F, 0x01)]);
      final elapsed = await probe.closed;

      expect(elapsed, greaterThanOrEqualTo(_shortDeadline - _earlyMargin));
      expect(elapsed, lessThan(_shortDeadline + _lateMargin));
      expect(probe.received, isEmpty);
      expect(server.handled, isEmpty);
    });

    test('a complete record with garbage inside is handed to TLS, which '
        'rejects it long before the deadline', () async {
      final server = await _Server.start(context: serverTrustingBob());

      final probe = await _Probe.connect(server.port);
      probe.send(const [0x16, 0x03, 0x01, 0x00, 0x04, 0xDE, 0xAD, 0xBE, 0xEF]);

      expect(await probe.closedWithin(_lateMargin), isTrue);
      expect(server.handled, isEmpty);
    });

    for (final size in [1, 3, 7]) {
      for (final withCertificate in [true, false]) {
        final label = withCertificate ? 'with' : 'without';
        test('a ClientHello split into pieces of $size bytes completes the '
            'handshake $label a client certificate', () async {
          final server = await _Server.start(context: serverTrustingBob());
          final firstChunkSizes = <int>[];
          final proxyPort = await _startRechunkingProxy(
            server.port,
            size: size,
            firstChunkSizes: firstChunkSizes,
          );

          final body = await _httpsGet(
            proxyPort,
            context: withCertificate ? presenting(bob) : bob.clientContext(),
            serverFingerprint: alice.fingerprint,
          ).timeout(const Duration(seconds: 20));

          expect(firstChunkSizes, [greaterThan(size * 10)]);
          expect(body, withCertificate ? bob.fingerprint : 'none');
        }, timeout: const Timeout(Duration(seconds: 40)));
      }
    }
  });

  group('pending handshake caps (A1)', () {
    test('per IP: with 8 silent clients from 127.0.0.1 the 9th is destroyed '
        'at once, another IP is still served, and the 8 are closed at the '
        'deadline, after which 127.0.0.1 is served again', () async {
      const deadline = Duration(seconds: 2);
      final server = await _Server.start(
        context: serverTrustingBob(),
        deadline: deadline,
      );

      final silent = [
        for (var i = 0; i < Limits.maxPendingHandshakesPerIp; i++)
          await _Probe.connect(server.port),
      ];
      await server.waitForAccepts(Limits.maxPendingHandshakesPerIp);
      final ninth = await _Probe.connect(server.port);
      final ninthClosed = await ninth.closedWithin(_atOnce);
      final refused = await legitimate(server.port);
      final otherIp = await legitimate(server.port, from: _otherLoopback);
      final elapsed = await Future.wait([for (final p in silent) p.closed]);
      final again = await legitimate(server.port);

      expect(ninthClosed, isTrue);
      expect(ninth.received, isEmpty);
      expect(refused, isNull);
      expect(otherIp, 'none');
      for (final e in elapsed) {
        expect(e, greaterThanOrEqualTo(deadline - _earlyMargin));
        expect(e, lessThan(deadline + _lateMargin));
      }
      expect(again, 'none');
      expect(server.handled, ['none', 'none']);
    });

    test('per IP: 8 clients holding a valid but incomplete first record count '
        'like silent ones', () async {
      final server = await _Server.start(context: serverTrustingBob());

      final partial = [
        for (var i = 0; i < Limits.maxPendingHandshakesPerIp; i++)
          await _Probe.connect(server.port),
      ];
      for (final probe in partial) {
        probe.send(const [0x16, 0x03, 0x01, 0x02, 0x00]);
      }
      await server.waitForAccepts(Limits.maxPendingHandshakesPerIp);
      final ninth = await _Probe.connect(server.port);

      expect(await ninth.closedWithin(_atOnce), isTrue);
      expect(partial.where((p) => p.isClosed), isEmpty);
    });

    test('global: 128 silent clients spread over 16 IPs fill the global cap, '
        'a client from a 17th IP is destroyed at once, and after the deadline '
        'that IP is served', () async {
      const deadline = Duration(seconds: 4);
      final server = await _Server.start(
        context: serverTrustingBob(),
        deadline: deadline,
      );
      const ips = 16;
      expect(
        ips * Limits.maxPendingHandshakesPerIp,
        Limits.maxPendingHandshakes,
      );

      final silent = <_Probe>[];
      for (var ip = 0; ip < ips; ip++) {
        for (var i = 0; i < Limits.maxPendingHandshakesPerIp; i++) {
          silent.add(
            await _Probe.connect(server.port, from: _loopbackNumber(10 + ip)),
          );
        }
      }
      await server.waitForAccepts(Limits.maxPendingHandshakes);
      final extra = await _Probe.connect(
        server.port,
        from: _loopbackNumber(40),
      );
      final extraClosed = await extra.closedWithin(_atOnce);
      final refused = await legitimate(server.port, from: _loopbackNumber(41));
      final stillOpen = silent.where((p) => !p.isClosed).length;
      final elapsed = await Future.wait([for (final p in silent) p.closed]);
      final served = await legitimate(server.port, from: _loopbackNumber(41));

      expect(extraClosed, isTrue);
      expect(refused, isNull);
      expect(stillOpen, Limits.maxPendingHandshakes);
      for (final e in elapsed) {
        expect(e, lessThan(deadline + _lateMargin));
      }
      expect(served, 'none');
    }, timeout: const Timeout(Duration(seconds: 40)));

    test('a slot is released when the handshake fails: three rounds of 8 '
        'failing handshakes from one IP do not lock that IP out', () async {
      final server = await _Server.start(context: serverTrustingBob());

      for (var round = 0; round < 3; round++) {
        final failing = [
          for (var i = 0; i < Limits.maxPendingHandshakesPerIp; i++)
            await _Probe.connect(server.port),
        ];
        for (final probe in failing) {
          probe.send(const [0x16, 0x03, 0x01, 0x00, 0x04, 1, 2, 3, 4]);
        }
        for (final probe in failing) {
          expect(await probe.closedWithin(_lateMargin), isTrue);
        }
      }
      final served = await _servedWithin(
        _waitLimit,
        () => legitimate(server.port),
      );

      expect(served, 'none');
    });

    test(
      'a slot is released when a client that was destroyed at once by an '
      'invalid header goes away: 30 of them do not lock the IP out',
      () async {
        final server = await _Server.start(context: serverTrustingBob());

        for (var i = 0; i < 30; i++) {
          final probe = await _Probe.connect(server.port);
          probe.send(ascii.encode('A'));
          expect(await probe.closedWithin(_lateMargin), isTrue);
        }

        expect(await legitimate(server.port), 'none');
      },
    );

    test('8 handshakes left half-way after a full ClientHello keep their slots '
        'while the clients stay, and the slots are free again once the '
        'clients go away', () async {
      final server = await _Server.start(context: serverTrustingBob());

      final stalled = [
        for (var i = 0; i < Limits.maxPendingHandshakesPerIp; i++)
          await _Probe.connect(server.port),
      ];
      for (final probe in stalled) {
        probe.send(clientHello);
      }
      for (final probe in stalled) {
        await probe.dataArrived;
      }
      final ninth = await _Probe.connect(server.port);
      final ninthClosed = await ninth.closedWithin(_atOnce);
      final otherIp = await legitimate(server.port, from: _otherLoopback);
      for (final probe in stalled) {
        probe.socket.destroy();
      }
      final served = await _servedWithin(
        _waitLimit,
        () => legitimate(server.port),
      );

      expect(stalled.map((p) => p.received.first), everyElement(0x16));
      expect(ninthClosed, isTrue);
      expect(otherIp, 'none');
      expect(served, 'none');
    });

    test(
      '2000 connections from one IP sending one byte each leave at most the '
      'per-IP cap open, another IP is still served, and close releases the '
      'rest at once',
      () async {
        final server = await _Server.start(context: serverTrustingBob());
        var open = 0;
        var refusedAtConnect = 0;

        Future<void> flood() async {
          final Socket socket;
          try {
            socket = await Socket.connect(_loopback, server.port);
          } on SocketException {
            refusedAtConnect++;
            return;
          }
          addTearDown(socket.destroy);
          open++;
          var finished = false;
          void finish() {
            if (finished) return;
            finished = true;
            open--;
          }

          socket.done.ignore();
          socket.listen(
            (_) {},
            onError: (Object _) => finish(),
            onDone: finish,
            cancelOnError: true,
          );
          try {
            socket.add(const [0x16]);
          } on Object {
            return;
          }
        }

        for (var batch = 0; batch < 40; batch++) {
          await Future.wait([for (var i = 0; i < 50; i++) flood()]);
        }
        await _until(
          () => open <= Limits.maxPendingHandshakesPerIp,
          limit: const Duration(seconds: 20),
          reason: 'flood drained',
        );
        await Future<void>.delayed(const Duration(milliseconds: 300));
        final openAfterFlood = open;
        final otherIp = await legitimate(server.port, from: _otherLoopback);
        await server.socket.close();
        await _until(
          () => open == 0,
          limit: _lateMargin,
          reason: 'all released by close',
        );

        expect(openAfterFlood, Limits.maxPendingHandshakesPerIp);
        expect(refusedAtConnect, lessThan(2000));
        expect(otherIp, 'none');
        expect(server.handled, ['none']);
      },
      tags: 'slow',
      timeout: const Timeout(Duration(seconds: 120)),
    );

    test('close destroys every connection still before the handshake, in '
        'every state, and leaves no deadline timer active', () async {
      const deadline = Duration(seconds: 7);
      final timers = <Timer>[];

      await runZoned(
        () async {
          final origins = <String>[];
          final socket = await FilteredSecureServerSocket.bind(
            address: _loopback,
            port: 0,
            context: serverTrustingBob(),
            allowOrigin: (remote) {
              origins.add(remote.address);
              return true;
            },
            deadline: deadline,
          );
          addTearDown(socket.close);
          socket.listen((s) => s.destroy());

          final silent = await _Probe.connect(socket.port);
          final oneByte = await _Probe.connect(socket.port);
          oneByte.send(const [0x16]);
          final header = await _Probe.connect(socket.port);
          header.send(const [0x16, 0x03, 0x01, 0x00, 0x40]);
          final partial = await _Probe.connect(socket.port);
          partial.send([0x16, 0x03, 0x01, 0x00, 0x40, ...List.filled(20, 1)]);
          final probes = [silent, oneByte, header, partial];
          await _until(() => origins.length == probes.length);
          await Future<void>.delayed(const Duration(milliseconds: 100));

          expect(timers.where((t) => t.isActive), hasLength(probes.length));

          await socket.close();

          expect(timers.where((t) => t.isActive), isEmpty);
          for (final probe in probes) {
            expect(await probe.closedWithin(_lateMargin), isTrue);
            expect(probe.received, isEmpty);
          }
        },
        zoneSpecification: ZoneSpecification(
          createTimer: (self, parent, zone, duration, callback) {
            final timer = parent.createTimer(zone, duration, callback);
            if (duration == deadline) timers.add(timer);
            return timer;
          },
        ),
      );
    });
  });
}
