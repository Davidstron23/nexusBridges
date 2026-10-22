import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:nexus_bridges_core/src/identity/identity.dart';
import 'package:nexus_bridges_core/src/protocol/protocol.dart';
import 'package:nexus_bridges_core/src/server/filtered_secure_server_socket.dart';
import 'package:test/test.dart';

final InternetAddress _loopback = InternetAddress.loopbackIPv4;
final InternetAddress _otherLoopback = InternetAddress('127.0.0.2');
const Duration _longDeadline = Duration(seconds: 30);
const Duration _shortDeadline = Duration(seconds: 1);
const Duration _waitLimit = Duration(seconds: 5);
const Duration _earlyMargin = Duration(milliseconds: 100);
const Duration _lateMargin = Duration(seconds: 2);

bool _onlyFirstLoopback(InternetAddress remote) =>
    remote.address == '127.0.0.1';

typedef _Respond = Future<String> Function(
  HttpRequest request,
  String key,
  FilteredSecureServerSocket socket,
);

final class _HttpHarness {
  _HttpHarness._(this.socket, this.http, this.origins);

  final FilteredSecureServerSocket socket;
  final HttpServer http;
  final List<InternetAddress> origins;
  final List<String> handled = [];
  final List<Object> failures = [];

  int get port => socket.port;

  static Future<_HttpHarness> start({
    required SecurityContext context,
    bool Function(InternetAddress remote)? allowOrigin,
    Duration deadline = _longDeadline,
    _Respond? respond,
  }) async {
    final origins = <InternetAddress>[];
    final socket = await FilteredSecureServerSocket.bind(
      address: _loopback,
      port: 0,
      context: context,
      allowOrigin: (remote) {
        origins.add(remote);
        return allowOrigin?.call(remote) ?? true;
      },
      deadline: deadline,
    );
    final harness = _HttpHarness._(
      socket,
      HttpServer.listenOn(socket),
      origins,
    );
    harness.http.listen((request) => harness._serve(request, respond));
    addTearDown(harness.close);
    return harness;
  }

  Future<void> _serve(HttpRequest request, _Respond? respond) async {
    final info = request.connectionInfo!;
    final key = '${info.remoteAddress.address}:${info.remotePort}';
    final certificate = request.certificate;
    final seen = certificate == null ? 'none' : fingerprintOf(certificate.der);
    handled.add(seen);
    try {
      final body = respond == null ? seen : await respond(request, key, socket);
      request.response
        ..persistentConnection = false
        ..write(body);
      await request.response.close();
    } on Object catch (error) {
      failures.add(error);
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

  Future<Duration> get closed =>
      _closed.future.timeout(_longDeadline - const Duration(seconds: 5));

  Future<void> get dataArrived => _data.future.timeout(_waitLimit);

  Future<bool> closedWithin(Duration limit) =>
      _closed.future.then((_) => true).timeout(limit, onTimeout: () => false);

  void _finish() {
    if (!_closed.isCompleted) _closed.complete(_stopwatch.elapsed);
  }
}

Future<String> _get(
  int port, {
  required SecurityContext context,
  required String serverFingerprint,
}) async {
  final client = HttpClient(context: context)
    ..badCertificateCallback = (certificate, host, port) =>
        fingerprintOf(certificate.der) == serverFingerprint;
  try {
    final request = await client.getUrl(Uri.parse('https://127.0.0.1:$port/'));
    final response = await request.close();
    return await response.transform(utf8.decoder).join();
  } finally {
    client.close(force: true);
  }
}

Future<void> _tlsUntilClosed(
  int port, {
  required SecurityContext context,
  required String serverFingerprint,
}) async {
  try {
    final socket = await SecureSocket.connect(
      _loopback,
      port,
      context: context,
      onBadCertificate: (certificate) =>
          fingerprintOf(certificate.der) == serverFingerprint,
    );
    socket.done.ignore();
    try {
      await socket.drain<void>().timeout(_waitLimit);
    } on IOException {
      return;
    } finally {
      socket.destroy();
    }
  } on IOException {
    return;
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

Future<int> _startSplittingProxy(
  int targetPort, {
  required int splitAt,
  required Duration pause,
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
          if (chunk.length > splitAt) {
            upstream.add(chunk.sublist(0, splitAt));
            await upstream.flush();
            await Future<void>.delayed(pause);
            upstream.add(chunk.sublist(splitAt));
            continue;
          }
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

const String _holdPortScript = '''
import 'dart:io';

Future<void> main() async {
  final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
  server.listen((socket) => socket.destroy());
  stdout.writeln(server.port);
  await stdin.drain<void>();
  await server.close();
}
''';

Future<int> _holdPortInChildProcess() async {
  final dir = await Directory.systemTemp.createTemp('nexus_port_');
  addTearDown(() => dir.delete(recursive: true));
  final script = File('${dir.path}${Platform.pathSeparator}hold_port.dart');
  await script.writeAsString(_holdPortScript);
  final process = await Process.start(Platform.resolvedExecutable, [
    script.path,
  ]);
  addTearDown(() async {
    process.kill();
    await process.exitCode;
  });
  process.stderr.drain<void>().ignore();
  final line = await process.stdout
      .transform(utf8.decoder)
      .transform(const LineSplitter())
      .first
      .timeout(const Duration(seconds: 30));
  return int.parse(line.trim());
}

void main() {
  late DeviceIdentity alice;
  late DeviceIdentity bob;
  late DeviceIdentity carol;

  setUpAll(() {
    alice = DeviceIdentity.generate(commonName: 'NexusBridges-alice');
    bob = DeviceIdentity.generate(commonName: 'NexusBridges-bob');
    carol = DeviceIdentity.generate(commonName: 'NexusBridges-carol');
  });

  SecurityContext serverTrustingBob() =>
      alice.serverContext(trustedCertificatesPem: [bob.certificatePem]);

  SecurityContext presenting(DeviceIdentity identity) =>
      identity.serverContext(trustedCertificatesPem: const []);

  Future<FilteredSecureServerSocket> bindRaw({
    bool Function(InternetAddress remote)? allowOrigin,
    List<InternetAddress>? origins,
    Duration deadline = _longDeadline,
  }) async {
    final socket = await FilteredSecureServerSocket.bind(
      address: _loopback,
      port: 0,
      context: serverTrustingBob(),
      allowOrigin: (remote) {
        origins?.add(remote);
        return allowOrigin?.call(remote) ?? true;
      },
      deadline: deadline,
    );
    addTearDown(socket.close);
    return socket;
  }

  group('origin filter before TLS (RF-25)', () {
    test('this machine can connect from 127.0.0.2 to 127.0.0.1', () async {
      final seen = <String>[];
      final listener = await ServerSocket.bind(_loopback, 0);
      addTearDown(listener.close);
      final accepted = Completer<void>();
      listener.listen((socket) {
        seen.add(socket.remoteAddress.address);
        socket.destroy();
        accepted.complete();
      });

      final client = await Socket.connect(
        _loopback,
        listener.port,
        sourceAddress: _otherLoopback,
      );
      addTearDown(client.destroy);
      await accepted.future.timeout(_waitLimit);

      expect(seen, ['127.0.0.2']);
    });

    test('a silent client from a rejected origin is closed at once, '
        'long before the deadline, without receiving any byte', () async {
      final origins = <InternetAddress>[];
      final socket = await bindRaw(
        allowOrigin: _onlyFirstLoopback,
        origins: origins,
      );
      final delivered = <Socket>[];
      socket.listen(delivered.add);

      final probe = await _Probe.connect(socket.port, from: _otherLoopback);
      final elapsed = await probe.closed;

      expect(elapsed, lessThan(_lateMargin));
      expect(probe.received, isEmpty);
      expect(origins.map((o) => o.address), ['127.0.0.2']);
      expect(delivered, isEmpty);
    });

    test('control: a silent client from 127.0.0.1 is kept open', () async {
      final socket = await bindRaw(allowOrigin: _onlyFirstLoopback);
      socket.listen((s) => s.destroy());

      final probe = await _Probe.connect(socket.port);

      expect(
        await probe.closedWithin(const Duration(milliseconds: 500)),
        isFalse,
      );
    });

    test(
      'a real ClientHello from a rejected origin gets no TLS byte back',
      () async {
        final hello = await _captureClientHello();
        final harness = await _HttpHarness.start(
          context: serverTrustingBob(),
          allowOrigin: _onlyFirstLoopback,
        );

        final probe = await _Probe.connect(harness.port, from: _otherLoopback);
        probe.socket.add(hello);
        await probe.closed;

        expect(probe.received, isEmpty);
        expect(harness.handled, isEmpty);
      },
    );

    test(
      'control: the same ClientHello from 127.0.0.1 gets a TLS reply',
      () async {
        final hello = await _captureClientHello();
        final harness = await _HttpHarness.start(
          context: serverTrustingBob(),
          allowOrigin: _onlyFirstLoopback,
        );

        final probe = await _Probe.connect(harness.port);
        probe.socket.add(hello);
        await probe.dataArrived;

        expect(probe.received.first, 0x16);
      },
    );

    test('a TLS client from a rejected origin fails and no socket is handed '
        'over, while one from 127.0.0.1 is handed over', () async {
      final origins = <InternetAddress>[];
      final socket = await bindRaw(
        allowOrigin: _onlyFirstLoopback,
        origins: origins,
      );
      final delivered = <Socket>[];
      socket.listen((s) {
        delivered.add(s);
        s.destroy();
      });

      final raw = await Socket.connect(
        _loopback,
        socket.port,
        sourceAddress: _otherLoopback,
      );
      addTearDown(raw.destroy);
      await expectLater(
        SecureSocket.secure(
          raw,
          onBadCertificate: (c) => fingerprintOf(c.der) == alice.fingerprint,
        ).timeout(_waitLimit),
        throwsA(isA<IOException>()),
      );
      expect(delivered, isEmpty);

      await _tlsUntilClosed(
        socket.port,
        context: bob.clientContext(),
        serverFingerprint: alice.fingerprint,
      );

      expect(origins.map((o) => o.address), ['127.0.0.2', '127.0.0.1']);
      expect(delivered, hasLength(1));
    });

    test('an HTTPS client from 127.0.0.1 is served', () async {
      final harness = await _HttpHarness.start(
        context: serverTrustingBob(),
        allowOrigin: _onlyFirstLoopback,
      );

      final body = await _get(
        harness.port,
        context: bob.clientContext(),
        serverFingerprint: alice.fingerprint,
      );

      expect(body, 'none');
      expect(harness.handled, ['none']);
      expect(harness.origins.map((o) => o.address), ['127.0.0.1']);
    });
  });

  group('client certificate (RF-29)', () {
    test('an identity that is not trusted is cut in the handshake and the '
        'handler never runs', () async {
      final harness = await _HttpHarness.start(context: serverTrustingBob());

      await expectLater(
        _get(
          harness.port,
          context: presenting(carol),
          serverFingerprint: alice.fingerprint,
        ).timeout(_waitLimit),
        throwsA(isA<IOException>()),
      );

      final body = await _get(
        harness.port,
        context: presenting(bob),
        serverFingerprint: alice.fingerprint,
      );
      expect(body, bob.fingerprint);
      expect(harness.handled, [bob.fingerprint]);
    });

    test(
      'an identity that is not trusted is never handed over as a socket',
      () async {
        final socket = await bindRaw();
        final delivered = <String?>[];
        socket.listen((s) {
          final certificate = (s as SecureSocket).peerCertificate;
          delivered.add(
            certificate == null ? null : fingerprintOf(certificate.der),
          );
          s.destroy();
        });

        await _tlsUntilClosed(
          socket.port,
          context: presenting(carol),
          serverFingerprint: alice.fingerprint,
        );
        await _tlsUntilClosed(
          socket.port,
          context: presenting(bob),
          serverFingerprint: alice.fingerprint,
        );

        expect(delivered, [bob.fingerprint]);
      },
    );

    test(
      'a client without certificate is served with no certificate',
      () async {
        final harness = await _HttpHarness.start(context: serverTrustingBob());

        final body = await _get(
          harness.port,
          context: carol.clientContext(),
          serverFingerprint: alice.fingerprint,
        );

        expect(body, 'none');
        expect(harness.handled, ['none']);
      },
    );

    test(
      'a trusted client is served and the handler sees its fingerprint',
      () async {
        final harness = await _HttpHarness.start(context: serverTrustingBob());

        final body = await _get(
          harness.port,
          context: presenting(bob),
          serverFingerprint: alice.fingerprint,
        );

        expect(body, bob.fingerprint);
        expect(harness.handled, [bob.fingerprint]);
      },
    );
  });

  group('absolute deadline (RF-35)', () {
    test(
      'a client that opens TCP and sends nothing is closed at the deadline',
      () async {
        final harness = await _HttpHarness.start(
          context: serverTrustingBob(),
          deadline: _shortDeadline,
        );

        final probe = await _Probe.connect(harness.port);
        final elapsed = await probe.closed;

        expect(elapsed, greaterThanOrEqualTo(_shortDeadline - _earlyMargin));
        expect(elapsed, lessThan(_shortDeadline + _lateMargin));
        expect(probe.received, isEmpty);
        expect(harness.handled, isEmpty);
      },
    );

    test(
      'with Limits.requestTimeout a silent client is closed at 10 s',
      () async {
        final harness = await _HttpHarness.start(
          context: serverTrustingBob(),
          deadline: Limits.requestTimeout,
        );

        final probe = await _Probe.connect(harness.port);
        final elapsed = await probe.closed;

        expect(
          elapsed,
          greaterThanOrEqualTo(Limits.requestTimeout - _earlyMargin),
        );
        expect(elapsed, lessThan(Limits.requestTimeout + _earlyMargin * 10));
      },
      tags: 'slow',
      timeout: const Timeout(Duration(seconds: 12)),
    );

    test('a slow HTTP header after TLS is closed at the deadline', () async {
      final harness = await _HttpHarness.start(
        context: serverTrustingBob(),
        deadline: _shortDeadline,
      );
      final stopwatch = Stopwatch()..start();
      final secure = await SecureSocket.connect(
        _loopback,
        harness.port,
        context: bob.clientContext(),
        onBadCertificate: (c) => fingerprintOf(c.der) == alice.fingerprint,
      );
      addTearDown(secure.destroy);
      secure.done.ignore();

      secure.add(utf8.encode('GET / HTTP/1.1\r\nHost: 127.0.0.1\r\n'));
      await secure.drain<void>().timeout(_waitLimit).catchError((Object _) {});
      final elapsed = stopwatch.elapsed;

      expect(elapsed, greaterThanOrEqualTo(_shortDeadline - _earlyMargin));
      expect(elapsed, lessThan(_shortDeadline + _lateMargin));
      expect(harness.handled, isEmpty);
    });

    test('a client that keeps trickling header bytes is still closed at the deadline', () async {
      final harness = await _HttpHarness.start(
        context: serverTrustingBob(),
        deadline: _shortDeadline,
      );
      final stopwatch = Stopwatch()..start();
      final secure = await SecureSocket.connect(
        _loopback,
        harness.port,
        context: bob.clientContext(),
        onBadCertificate: (c) => fingerprintOf(c.der) == alice.fingerprint,
      );
      addTearDown(secure.destroy);
      secure.done.ignore();
      secure.add(utf8.encode('GET / HTTP/1.1\r\n'));
      var header = 0;
      final trickle = Timer.periodic(const Duration(milliseconds: 100), (_) {
        try {
          secure.add(utf8.encode('X-Slow-${header++}: 1\r\n'));
        } on Object {
          return;
        }
      });
      addTearDown(trickle.cancel);

      await secure.drain<void>().timeout(_waitLimit).catchError((Object _) {});
      trickle.cancel();
      final elapsed = stopwatch.elapsed;

      expect(header, greaterThan(3));
      expect(elapsed, greaterThanOrEqualTo(_shortDeadline - _earlyMargin));
      expect(elapsed, lessThan(_shortDeadline + _lateMargin));
      expect(harness.handled, isEmpty);
    });

    test(
      'a request marked with requestFinished is not cut by the deadline',
      () async {
        final harness = await _HttpHarness.start(
          context: serverTrustingBob(),
          deadline: const Duration(milliseconds: 500),
          respond: (request, key, socket) async {
            socket.requestFinished(key);
            await Future<void>.delayed(const Duration(milliseconds: 1200));
            return 'answered late';
          },
        );

        final body = await _get(
          harness.port,
          context: bob.clientContext(),
          serverFingerprint: alice.fingerprint,
        );

        expect(body, 'answered late');
        expect(harness.failures, isEmpty);
      },
    );

    test(
      'control: the same late request without requestFinished is cut',
      () async {
        final harness = await _HttpHarness.start(
          context: serverTrustingBob(),
          deadline: const Duration(milliseconds: 500),
          respond: (request, key, socket) async {
            await Future<void>.delayed(const Duration(milliseconds: 1200));
            return 'answered late';
          },
        );

        await expectLater(
          _get(
            harness.port,
            context: bob.clientContext(),
            serverFingerprint: alice.fingerprint,
          ).timeout(_waitLimit),
          throwsA(isA<IOException>()),
        );
        expect(harness.handled, ['none']);
      },
    );

    test('a request answered in time is served', () async {
      final harness = await _HttpHarness.start(
        context: serverTrustingBob(),
        deadline: _shortDeadline,
      );

      final first = await _get(
        harness.port,
        context: bob.clientContext(),
        serverFingerprint: alice.fingerprint,
      );
      final second = await _get(
        harness.port,
        context: presenting(bob),
        serverFingerprint: alice.fingerprint,
      );

      expect([first, second], ['none', bob.fingerprint]);
      expect(harness.failures, isEmpty);
    });

    for (final splitAt in [3, 100]) {
      test('a ClientHello split in two writes at byte $splitAt with a pause '
          'completes the handshake', () async {
        final harness = await _HttpHarness.start(
          context: serverTrustingBob(),
          deadline: const Duration(seconds: 3),
        );
        final firstChunkSizes = <int>[];
        final proxyPort = await _startSplittingProxy(
          harness.port,
          splitAt: splitAt,
          pause: const Duration(milliseconds: 300),
          firstChunkSizes: firstChunkSizes,
        );

        final body = await _get(
          proxyPort,
          context: presenting(bob),
          serverFingerprint: alice.fingerprint,
        ).timeout(_waitLimit);

        expect(firstChunkSizes, [greaterThan(splitAt)]);
        expect(body, bob.fingerprint);
      });
    }

    test('several silent clients at once are all closed at the deadline and '
        'do not stop another client from being served', () async {
      final harness = await _HttpHarness.start(
        context: serverTrustingBob(),
        deadline: _shortDeadline,
      );

      final probes = await Future.wait([
        for (var i = 0; i < 5; i++) _Probe.connect(harness.port),
      ]);
      final body = await _get(
        harness.port,
        context: bob.clientContext(),
        serverFingerprint: alice.fingerprint,
      );
      final elapsed = await Future.wait([for (final p in probes) p.closed]);

      expect(body, 'none');
      expect(elapsed, hasLength(5));
      for (final e in elapsed) {
        expect(e, greaterThanOrEqualTo(_shortDeadline - _earlyMargin));
        expect(e, lessThan(_shortDeadline + _lateMargin));
      }
      expect(harness.handled, ['none']);
    });

    test('close during the wait cancels every deadline timer and releases '
        'the waiting clients at once', () async {
      const deadline = Duration(seconds: 7);
      final timers = <Timer>[];
      final origins = <InternetAddress>[];
      final allAccepted = Completer<void>();

      await runZoned(
        () async {
          final socket = await FilteredSecureServerSocket.bind(
            address: _loopback,
            port: 0,
            context: serverTrustingBob(),
            allowOrigin: (remote) {
              origins.add(remote);
              if (origins.length == 3) allAccepted.complete();
              return true;
            },
            deadline: deadline,
          );
          addTearDown(socket.close);
          socket.listen((s) => s.destroy());

          final probes = [
            for (var i = 0; i < 3; i++) await _Probe.connect(socket.port),
          ];
          await allAccepted.future.timeout(_waitLimit);

          expect(timers, hasLength(3));
          expect(timers.where((t) => t.isActive), hasLength(3));

          await socket.close();

          expect(timers.where((t) => t.isActive), isEmpty);
          for (final probe in probes) {
            expect(await probe.closed, lessThan(_lateMargin));
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

  group('bind and the ServerSocket surface', () {
    test(
      'binds port 0 and exposes the address and port of the inner socket',
      () async {
        final accepted = Completer<String>();
        final socket = await bindRaw(
          allowOrigin: (remote) {
            if (!accepted.isCompleted) accepted.complete(remote.address);
            return true;
          },
        );
        socket.listen((s) => s.destroy());

        expect(socket.address, _loopback);
        expect(socket.port, inInclusiveRange(1, 65535));

        await _Probe.connect(socket.port);

        expect(await accepted.future.timeout(_waitLimit), '127.0.0.1');
      },
    );

    test(
      'close releases the port, returns itself and can be called twice',
      () async {
        final socket = await bindRaw();
        socket.listen((s) => s.destroy());
        final port = socket.port;

        expect(await socket.close(), same(socket));
        expect(await socket.close(), same(socket));

        final again = await ServerSocket.bind(_loopback, port);
        await again.close();
      },
    );

    test('close before anyone listens also releases the port', () async {
      final socket = await bindRaw();
      final port = socket.port;

      await socket.close();

      final again = await ServerSocket.bind(_loopback, port);
      await again.close();
    });

    test('requestFinished with an unknown key does nothing', () async {
      final socket = await bindRaw();

      expect(() => socket.requestFinished('10.0.0.9:1234'), returnsNormally);
      expect(() => socket.requestFinished(''), returnsNormally);
    });

    test(
      'a port held by another process throws PortInUseException(port)',
      () async {
        final port = await _holdPortInChildProcess();

        await expectLater(
          FilteredSecureServerSocket.bind(
            address: _loopback,
            port: port,
            context: serverTrustingBob(),
            allowOrigin: (_) => true,
            deadline: _longDeadline,
          ),
          throwsA(
            isA<PortInUseException>().having((e) => e.port, 'port', port),
          ),
        );
      },
      timeout: const Timeout(Duration(seconds: 60)),
    );

    test('a port held in the same process gives a plain SocketException, '
        'not PortInUseException', () async {
      final first = await bindRaw();

      await expectLater(
        FilteredSecureServerSocket.bind(
          address: _loopback,
          port: first.port,
          context: serverTrustingBob(),
          allowOrigin: (_) => true,
          deadline: _longDeadline,
        ),
        throwsA(
          allOf(isA<SocketException>(), isNot(isA<PortInUseException>())),
        ),
      );
    });
  });
}
