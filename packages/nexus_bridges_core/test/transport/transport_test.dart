import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:nexus_bridges_core/src/identity/identity.dart';
import 'package:nexus_bridges_core/src/protocol/protocol.dart';
import 'package:nexus_bridges_core/src/transport/transport.dart';
import 'package:test/test.dart';

final InternetAddress _loopback = InternetAddress.loopbackIPv4;
final InternetAddress _second = InternetAddress('127.0.0.2');
final InternetAddress _third = InternetAddress('127.0.0.3');
const Duration _oneSecond = Duration(seconds: 1);
const Duration _twoSeconds = Duration(seconds: 2);
const Duration _wait = Duration(seconds: 5);
const Duration _settle = Duration(milliseconds: 200);
const String _jsonType = 'application/json; charset=utf-8';

typedef _Handled = ({
  String method,
  String path,
  String? contentType,
  int contentLength,
  bool persistent,
  List<int> body,
  InternetAddress from,
  String? clientFingerprint,
  String? host,
  int? hostPort,
});

typedef _Answer = (int, List<int>);

final class _CountingServer {
  _CountingServer._(this._server, this._answer);

  static Future<_CountingServer> start(
    SecurityContext context, {
    InternetAddress? address,
    _Answer Function(_Handled request)? answer,
  }) async {
    final server = await HttpServer.bindSecure(
      address ?? _loopback,
      0,
      context,
      requestClientCertificate: true,
    );
    final counting = _CountingServer._(
      server,
      answer ?? (_) => (404, utf8.encode('{"error":"not_found"}')),
    );
    server.listen(counting._handle, onError: (Object _) {});
    addTearDown(() => server.close(force: true));
    return counting;
  }

  final HttpServer _server;
  final _Answer Function(_Handled request) _answer;
  final List<_Handled> requests = [];
  int handled = 0;

  int get port => _server.port;

  Future<void> _handle(HttpRequest request) async {
    handled++;
    final body = <int>[];
    try {
      await for (final chunk in request) {
        body.addAll(chunk);
      }
      final certificate = request.certificate;
      final seen = (
        method: request.method,
        path: request.uri.path,
        contentType: request.headers.value(HttpHeaders.contentTypeHeader),
        contentLength: request.contentLength,
        persistent: request.persistentConnection,
        body: body,
        from: request.connectionInfo!.remoteAddress,
        clientFingerprint: certificate == null
            ? null
            : fingerprintOfCertificate(certificate.der),
        host: request.headers.host,
        hostPort: request.headers.port,
      );
      requests.add(seen);
      final (status, reply) = _answer(seen);
      request.response
        ..statusCode = status
        ..contentLength = reply.length
        ..add(reply);
      await request.response.close();
    } on Object {
      return;
    }
  }
}

final class _Connection {
  _Connection(this.socket);

  final Socket socket;
  final List<int> received = [];
  final Completer<void> _request = Completer();
  final Completer<void> _firstBytes = Completer();
  final Completer<void> _closed = Completer();

  Future<void> get request => _request.future;

  Future<void> get firstBytes => _firstBytes.future;

  Future<void> get closed => _closed.future;

  bool get hasRequest => _request.isCompleted;

  String get head {
    final text = latin1.decode(received);
    return text.substring(0, text.indexOf('\r\n\r\n'));
  }

  List<int> get body {
    final end = latin1.decode(received).indexOf('\r\n\r\n');
    return received.sublist(end + 4);
  }

  void _finish() {
    if (!_closed.isCompleted) _closed.complete();
  }
}

final RegExp _lengthHeader = RegExp(
  r'content-length:\s*(\d+)',
  caseSensitive: false,
);

bool _isCompleteRequest(List<int> bytes) {
  final text = latin1.decode(bytes);
  final end = text.indexOf('\r\n\r\n');
  if (end < 0) return false;
  final match = _lengthHeader.firstMatch(text.substring(0, end));
  final length = match == null ? 0 : int.parse(match.group(1)!);
  return bytes.length >= end + 4 + length;
}

typedef _Reply = List<int>? Function(_Connection connection);

final class _RawPeer {
  _RawPeer._(this._stop, this.port, this._reply, this._closeAfterReply);

  static Future<_RawPeer> tls(
    DeviceIdentity identity, {
    _Reply? reply,
    bool closeAfterReply = true,
  }) async {
    final server = await SecureServerSocket.bind(
      _loopback,
      0,
      identity.serverContext(trustedCertificatesPem: const []),
    );
    final peer = _RawPeer._(server.close, server.port, reply, closeAfterReply);
    server.listen(peer._accept, onError: (Object _) {});
    addTearDown(peer.close);
    return peer;
  }

  static Future<_RawPeer> tcp({_Reply? reply}) async {
    final server = await ServerSocket.bind(_loopback, 0);
    final peer = _RawPeer._(server.close, server.port, reply, true);
    server.listen(peer._acceptRaw, onError: (Object _) {});
    addTearDown(peer.close);
    return peer;
  }

  final Future<void> Function() _stop;
  final int port;
  final _Reply? _reply;
  final bool _closeAfterReply;
  final List<_Connection> connections = [];
  final Completer<_Connection> _first = Completer();

  int get accepted => connections.length;

  Future<_Connection> get firstConnection => _first.future;

  void _acceptRaw(Socket socket) {
    final connection = _Connection(socket);
    connections.add(connection);
    if (!_first.isCompleted) _first.complete(connection);
    socket.done.ignore();
    socket.listen(
      (chunk) {
        connection.received.addAll(chunk);
        if (!connection._firstBytes.isCompleted) {
          connection._firstBytes.complete();
        }
        final reply = _reply?.call(connection);
        if (reply == null) return;
        try {
          socket.add(reply);
          socket.close().ignore();
        } on Object {
          return;
        }
      },
      onError: (Object _) => connection._finish(),
      onDone: connection._finish,
      cancelOnError: true,
    );
  }

  void _accept(Socket socket) {
    final connection = _Connection(socket);
    connections.add(connection);
    if (!_first.isCompleted) _first.complete(connection);
    socket.done.ignore();
    socket.listen(
      (chunk) {
        connection.received.addAll(chunk);
        if (!connection._firstBytes.isCompleted) {
          connection._firstBytes.complete();
        }
        if (connection._request.isCompleted ||
            !_isCompleteRequest(connection.received)) {
          return;
        }
        connection._request.complete();
        final reply = _reply?.call(connection);
        if (reply == null) return;
        try {
          socket.add(reply);
          if (_closeAfterReply) socket.close().ignore();
        } on Object {
          return;
        }
      },
      onError: (Object _) => connection._finish(),
      onDone: connection._finish,
      cancelOnError: true,
    );
  }

  Future<void> close() async {
    for (final connection in connections) {
      connection.socket.destroy();
    }
    await _stop();
  }
}

List<int> _reply(
  int status,
  List<int> body, {
  String? statusLine,
  List<String>? lengthValues,
  Map<String, String> headers = const {},
}) {
  final head = StringBuffer(statusLine ?? 'HTTP/1.1 $status Reply')
    ..write('\r\n')
    ..write('content-type: $_jsonType\r\n');
  for (final value in lengthValues ?? ['${body.length}']) {
    head.write('content-length: $value\r\n');
  }
  head.write('connection: close\r\n');
  headers.forEach((name, value) => head.write('$name: $value\r\n'));
  head.write('\r\n');
  return [...utf8.encode(head.toString()), ...body];
}

String _fingerprintOf(X509Certificate certificate) =>
    fingerprintOfCertificate(certificate.der);

void main() {
  late DeviceIdentity alice;
  late DeviceIdentity bob;
  late DeviceIdentity carol;
  late DeviceIdentity aliceReinstalled;

  setUpAll(() {
    alice = DeviceIdentity.generate(commonName: randomCommonName());
    bob = DeviceIdentity.generate(commonName: randomCommonName());
    carol = DeviceIdentity.generate(commonName: randomCommonName());
    aliceReinstalled = DeviceIdentity.generate(
      commonName: alice.certificate.commonName,
    );
  });

  bool Function(X509Certificate) pinnedTo(
    String fingerprint, [
    List<String>? seen,
  ]) => (certificate) {
    final observed = _fingerprintOf(certificate);
    seen?.add(observed);
    return observed == fingerprint;
  };

  Future<HttpsResponse?> post(
    int port, {
    required String expected,
    Object? json = const {'hello': 'world'},
    String path = ApiPaths.pairStart,
    InternetAddress? address,
    SecurityContext? context,
    InternetAddress? sourceAddress,
    Duration timeout = _wait,
    int maxResponseBytes = Limits.maxBodyBytes,
    AbortSignal? abort,
    List<String>? seen,
  }) => postJson(
    address: address ?? _loopback,
    port: port,
    path: path,
    json: json,
    context: context ?? bob.clientContext(),
    acceptServer: pinnedTo(expected, seen),
    sourceAddress: sourceAddress,
    timeout: timeout,
    maxResponseBytes: maxResponseBytes,
    abort: abort,
  );

  group('C21: the client pins the fingerprint of the server (RF-82, '
      'RF-122)', () {
    test('control: with the fingerprint of the server the request reaches '
        'the handler and the callback sees that server', () async {
      final server = await _CountingServer.start(
        alice.serverContext(trustedCertificatesPem: const []),
      );
      final seen = <String>[];

      final response = await post(
        server.port,
        expected: alice.fingerprint,
        seen: seen,
      );

      expect(response?.status, 404);
      expect(utf8.decode(response!.body), '{"error":"not_found"}');
      expect(server.handled, 1);
      expect(seen, isNotEmpty);
      expect(seen.toSet(), {alice.fingerprint});
    });

    test('a server with another fingerprint gives null and the handler never '
        'counts the request', () async {
      final server = await _CountingServer.start(
        carol.serverContext(trustedCertificatesPem: const []),
      );
      final seen = <String>[];

      final response = await post(
        server.port,
        expected: alice.fingerprint,
        seen: seen,
      );

      expect(response, isNull);
      await Future<void>.delayed(_settle);
      expect(server.handled, 0);
      expect(seen, [carol.fingerprint]);
    });

    test('twenty attempts against the wrong server never reach its handler, '
        'and the right fingerprint then does', () async {
      final server = await _CountingServer.start(
        carol.serverContext(trustedCertificatesPem: const []),
      );

      for (var i = 0; i < 20; i++) {
        expect(
          await post(server.port, expected: alice.fingerprint),
          isNull,
          reason: 'attempt $i',
        );
      }
      await Future<void>.delayed(_settle);
      expect(server.handled, 0);

      final response = await post(server.port, expected: carol.fingerprint);

      expect(response?.status, 404);
      expect(server.handled, 1);
    });

    test('a paired device reinstalled with the same name but another key '
        'gives null and nothing reaches its handler (RF-122)', () async {
      expect(
        aliceReinstalled.certificate.commonName,
        alice.certificate.commonName,
      );
      expect(aliceReinstalled.fingerprint, isNot(alice.fingerprint));
      final server = await _CountingServer.start(
        aliceReinstalled.serverContext(
          trustedCertificatesPem: [bob.certificatePem],
        ),
      );

      final response = await post(
        server.port,
        expected: alice.fingerprint,
        context: bob.clientContext(presentCertificate: true),
      );

      expect(response, isNull);
      await Future<void>.delayed(_settle);
      expect(server.handled, 0);
    });

    test('control: the same mutual TLS server reaches HTTP with its own '
        'fingerprint and reads the client certificate', () async {
      final server = await _CountingServer.start(
        aliceReinstalled.serverContext(
          trustedCertificatesPem: [bob.certificatePem],
        ),
      );

      final response = await post(
        server.port,
        expected: aliceReinstalled.fingerprint,
        context: bob.clientContext(presentCertificate: true),
      );

      expect(response?.status, 404);
      expect(server.handled, 1);
      expect(server.requests.single.clientFingerprint, bob.fingerprint);
    });

    test('a callback that always refuses gives null without reaching the '
        'handler', () async {
      final server = await _CountingServer.start(
        alice.serverContext(trustedCertificatesPem: const []),
      );

      final response = await postJson(
        address: _loopback,
        port: server.port,
        path: ApiPaths.register,
        json: const {'hello': 'world'},
        context: bob.clientContext(),
        acceptServer: (_) => false,
      );

      expect(response, isNull);
      await Future<void>.delayed(_settle);
      expect(server.handled, 0);
    });

    test('a callback that throws gives null without reaching the handler '
        'and without throwing', () async {
      final server = await _CountingServer.start(
        alice.serverContext(trustedCertificatesPem: const []),
      );

      final pending = postJson(
        address: _loopback,
        port: server.port,
        path: ApiPaths.pairStart,
        json: const {'hello': 'world'},
        context: bob.clientContext(),
        acceptServer: (_) => throw StateError('callback failed'),
      );

      await expectLater(pending, completion(isNull));
      await Future<void>.delayed(_settle);
      expect(server.handled, 0);
    });
  });

  group('C22: responses of a real HTTPS server', () {
    for (final status in [200, 403, 409]) {
      test('status $status comes back with its exact body', () async {
        final server = await _CountingServer.start(
          alice.serverContext(trustedCertificatesPem: const []),
          answer: (_) => (status, utf8.encode('{"status":$status}')),
        );

        final response = await post(server.port, expected: alice.fingerprint);

        expect(response, isNotNull);
        expect(response!.status, status);
        expect(utf8.decode(response.body), '{"status":$status}');
        expect(server.handled, 1);
      });
    }

    test('the request is a POST to the given path with the JSON body, its '
        'exact length, the JSON type and no keep-alive', () async {
      final server = await _CountingServer.start(
        alice.serverContext(trustedCertificatesPem: const []),
        answer: (_) => (200, utf8.encode('{}')),
      );
      final json = {
        'name': 'Portátil 💻',
        'list': [1, 2.5, null, true],
        'nested': {'a': 'b'},
      };

      final response = await post(
        server.port,
        expected: alice.fingerprint,
        path: ApiPaths.pairConfirm,
        json: json,
      );

      expect(response?.status, 200);
      final seen = server.requests.single;
      expect(seen.method, 'POST');
      expect(seen.path, ApiPaths.pairConfirm);
      expect(seen.contentType, _jsonType);
      expect(seen.contentLength, utf8.encode(jsonEncode(json)).length);
      expect(seen.contentLength, greaterThan(jsonEncode(json).length));
      expect(seen.body.length, seen.contentLength);
      expect(jsonDecode(utf8.decode(seen.body)), json);
      expect(seen.persistent, isFalse);
      expect(seen.host, '127.0.0.1');
      expect(seen.hostPort, server.port);
      expect(seen.from, _loopback);
    });

    test('a null JSON is sent as the literal null', () async {
      final server = await _CountingServer.start(
        alice.serverContext(trustedCertificatesPem: const []),
        answer: (_) => (200, const []),
      );

      final response = await post(
        server.port,
        expected: alice.fingerprint,
        json: null,
      );

      expect(response?.status, 200);
      expect(response!.body, isEmpty);
      expect(utf8.decode(server.requests.single.body), 'null');
    });

    test('a client context with a certificate shows it to the server, one '
        'without it shows nothing', () async {
      final server = await _CountingServer.start(
        alice.serverContext(trustedCertificatesPem: [bob.certificatePem]),
      );

      await post(
        server.port,
        expected: alice.fingerprint,
        context: bob.clientContext(presentCertificate: true),
      );
      await post(server.port, expected: alice.fingerprint);

      expect(server.requests.map((r) => r.clientFingerprint), [
        bob.fingerprint,
        null,
      ]);
    });

    test('twenty requests at once each get the answer to their own '
        'body', () async {
      final server = await _CountingServer.start(
        alice.serverContext(trustedCertificatesPem: const []),
        answer: (request) => (200, request.body),
      );

      final responses = await Future.wait([
        for (var i = 0; i < 20; i++)
          post(server.port, expected: alice.fingerprint, json: {'n': i}),
      ]);

      for (var i = 0; i < 20; i++) {
        expect(responses[i]?.status, 200, reason: 'request $i');
        expect(jsonDecode(utf8.decode(responses[i]!.body)), {'n': i});
      }
      expect(server.handled, 20);
    });
  });

  group('C22: response framing', () {
    Future<HttpsResponse?> against(
      List<int> reply, {
      int maxResponseBytes = Limits.maxBodyBytes,
      bool closeAfterReply = true,
    }) async {
      final peer = await _RawPeer.tls(
        alice,
        reply: (_) => reply,
        closeAfterReply: closeAfterReply,
      );
      return post(
        peer.port,
        expected: alice.fingerprint,
        maxResponseBytes: maxResponseBytes,
      );
    }

    test('every status from 200 to 599 comes back with its body', () async {
      final peer = await _RawPeer.tls(
        alice,
        reply: (connection) {
          final status = int.parse(connection.head.split(' ')[1].substring(1));
          return _reply(status, utf8.encode('body-$status'));
        },
      );

      for (var status = 200; status <= 599; status++) {
        final response = await post(
          peer.port,
          expected: alice.fingerprint,
          path: '/$status',
        );
        expect(response?.status, status, reason: 'status $status');
        expect(utf8.decode(response!.body), 'body-$status');
      }
      expect(peer.accepted, 400);
    }, timeout: const Timeout(Duration(minutes: 2)));

    for (final status in [100, 101, 102, 103, 150, 199]) {
      test('a 1xx status ($status) gives null', () async {
        expect(await against(_reply(status, utf8.encode('{}'))), isNull);
      });
    }

    test('a 100 Continue followed by the final 200 gives null', () async {
      final finalReply = _reply(200, utf8.encode('{}'));
      expect(
        await against([
          ...utf8.encode('HTTP/1.1 100 Continue\r\n\r\n'),
          ...finalReply,
        ]),
        isNull,
      );
    });

    for (final status in [600, 700, 999]) {
      test('status $status gives null', () async {
        expect(await against(_reply(status, utf8.encode('{}'))), isNull);
      });
    }

    for (final line in [
      'HTTP/2 200 OK',
      'HTTP/1.1 20 OK',
      'HTTP/1.1 2000 OK',
      'HTTP/1.1 abc OK',
      'http/1.1 200 OK',
      'garbage',
    ]) {
      test('the status line "$line" gives null', () async {
        expect(
          await against(_reply(200, utf8.encode('{}'), statusLine: line)),
          isNull,
        );
      });
    }

    test('a binary body comes back byte for byte', () async {
      final body = [0, 255, 13, 10, 13, 10, 0xC3, 0x28, 0x7B];

      final response = await against(_reply(409, body));

      expect(response?.status, 409);
      expect(response!.body, body);
      expect(response.body, isA<Uint8List>());
    });

    test('Content-Length 0 gives the status with an empty body', () async {
      final response = await against(
        _reply(204, const []),
        closeAfterReply: false,
      );

      expect(response?.status, 204);
      expect(response!.body, isEmpty);
    });

    test('a response without Content-Length gives null even when the '
        'connection closes after the body', () async {
      expect(
        await against(_reply(200, utf8.encode('{}'), lengthValues: const [])),
        isNull,
      );
    });

    for (final value in ['chunked', 'identity', 'gzip, chunked']) {
      test('Transfer-Encoding "$value" gives null', () async {
        expect(
          await against(
            _reply(
              200,
              utf8.encode('{}'),
              headers: {'transfer-encoding': value},
            ),
          ),
          isNull,
        );
      });
    }

    test('a repeated Content-Length gives null even with equal '
        'values', () async {
      expect(
        await against(
          _reply(200, utf8.encode('{}'), lengthValues: const ['2', '2']),
        ),
        isNull,
      );
    });

    for (final value in ['abc', '-1', '1e3', '0x10', '']) {
      test('Content-Length "$value" gives null', () async {
        expect(
          await against(_reply(200, utf8.encode('{}'), lengthValues: [value])),
          isNull,
        );
      });
    }

    test('a Content-Length larger than what arrives before the close gives '
        'null', () async {
      expect(
        await against(_reply(200, utf8.encode('{}'), lengthValues: ['50'])),
        isNull,
      );
    });

    test('bytes beyond the Content-Length are ignored', () async {
      final response = await against(
        _reply(
          200,
          utf8.encode('{"a":1}HTTP/1.1 200 OK\r\n\r\n'),
          lengthValues: ['7'],
        ),
        closeAfterReply: false,
      );

      expect(response?.status, 200);
      expect(utf8.decode(response!.body), '{"a":1}');
    });

    test('headers of more than 8 KiB give null', () async {
      expect(
        await against(
          _reply(
            200,
            utf8.encode('{}'),
            headers: {'x-filler': 'a' * (Limits.maxHeaderBytes + 10)},
          ),
        ),
        isNull,
      );
    });

    test('control: headers of almost 8 KiB are read', () async {
      final response = await against(
        _reply(
          200,
          utf8.encode('{}'),
          headers: {'x-filler': 'a' * (Limits.maxHeaderBytes - 300)},
        ),
      );

      expect(response?.status, 200);
    });
  });

  group('C22: the response cap (maxResponseBytes)', () {
    Future<HttpsResponse?> withBody(int size, {int? cap}) async {
      final peer = await _RawPeer.tls(
        alice,
        reply: (_) => _reply(200, List<int>.filled(size, 0x61)),
      );
      return cap == null
          ? post(peer.port, expected: alice.fingerprint)
          : post(peer.port, expected: alice.fingerprint, maxResponseBytes: cap);
    }

    test('by default a body of exactly Limits.maxBodyBytes is read', () async {
      final response = await withBody(Limits.maxBodyBytes);

      expect(response?.body, hasLength(Limits.maxBodyBytes));
    });

    test('by default one byte more gives null', () async {
      expect(await withBody(Limits.maxBodyBytes + 1), isNull);
    });

    test('with the pairing cap a body of exactly 8192 bytes is read', () async {
      final response = await withBody(
        Limits.maxPairingBodyBytes,
        cap: Limits.maxPairingBodyBytes,
      );

      expect(response?.body, hasLength(Limits.maxPairingBodyBytes));
      expect(response!.body, everyElement(0x61));
    });

    test('with the pairing cap 8193 bytes give null', () async {
      expect(
        await withBody(
          Limits.maxPairingBodyBytes + 1,
          cap: Limits.maxPairingBodyBytes,
        ),
        isNull,
      );
    });

    test('an announced length over the cap gives null even if the body '
        'that arrives is small', () async {
      final peer = await _RawPeer.tls(
        alice,
        reply: (_) => _reply(200, utf8.encode('{}'), lengthValues: ['9000']),
        closeAfterReply: false,
      );
      final watch = Stopwatch()..start();

      final response = await post(
        peer.port,
        expected: alice.fingerprint,
        maxResponseBytes: Limits.maxPairingBodyBytes,
      );

      expect(response, isNull);
      expect(watch.elapsed, lessThan(_twoSeconds));
    });

    test('a cap of 0 still reads an empty body', () async {
      final response = await withBody(0, cap: 0);

      expect(response?.status, 200);
      expect(response!.body, isEmpty);
    });

    test('a cap of 0 refuses a body of one byte', () async {
      expect(await withBody(1, cap: 0), isNull);
    });
  });

  group('C22: abort', () {
    test('an already aborted signal gives null without even opening the '
        'TCP connection', () async {
      final peer = await _RawPeer.tcp();
      final signal = AbortSignal()..abort();

      final response = await post(
        peer.port,
        expected: alice.fingerprint,
        abort: signal,
      );

      expect(response, isNull);
      await Future<void>.delayed(_settle);
      expect(peer.accepted, 0);
      expect(signal.listenerCount, 0);
    });

    test('control: with a live signal the same listener sees the TCP '
        'connection', () async {
      final peer = await _RawPeer.tcp();
      final signal = AbortSignal();

      final response = await post(
        peer.port,
        expected: alice.fingerprint,
        abort: signal,
        timeout: const Duration(milliseconds: 300),
      );

      expect(response, isNull);
      expect(peer.accepted, 1);
      expect(signal.listenerCount, 0);
    });

    test('aborting a hung TLS handshake gives null within 1 s and closes '
        'the socket', () async {
      final peer = await _RawPeer.tcp();
      final signal = AbortSignal();

      final pending = post(
        peer.port,
        expected: alice.fingerprint,
        timeout: const Duration(seconds: 10),
        abort: signal,
      );
      final connection = await peer.firstConnection.timeout(_wait);
      await connection.firstBytes.timeout(_wait);
      expect(signal.listenerCount, 1);
      final watch = Stopwatch()..start();
      signal.abort();

      expect(await pending, isNull);
      expect(watch.elapsed, lessThan(_oneSecond));
      await connection.closed.timeout(_oneSecond);
      expect(signal.listenerCount, 0);
    });

    test('aborting while the reply is awaited gives null within 1 s and '
        'closes the socket', () async {
      final peer = await _RawPeer.tls(alice);
      final signal = AbortSignal();

      final pending = post(
        peer.port,
        expected: alice.fingerprint,
        timeout: const Duration(seconds: 10),
        abort: signal,
      );
      final connection = await peer.firstConnection.timeout(_wait);
      await connection.request.timeout(_wait);
      final watch = Stopwatch()..start();
      signal.abort();

      expect(await pending, isNull);
      expect(watch.elapsed, lessThan(_oneSecond));
      await connection.closed.timeout(_oneSecond);
      expect(signal.listenerCount, 0);
    });

    test('aborting while the body arrives gives null and closes the '
        'socket', () async {
      final peer = await _RawPeer.tls(
        alice,
        reply: (_) => _reply(200, utf8.encode('{"a"'), lengthValues: ['500']),
        closeAfterReply: false,
      );
      final signal = AbortSignal();

      final pending = post(
        peer.port,
        expected: alice.fingerprint,
        timeout: const Duration(seconds: 10),
        abort: signal,
      );
      final connection = await peer.firstConnection.timeout(_wait);
      await connection.request.timeout(_wait);
      await Future<void>.delayed(const Duration(milliseconds: 100));
      signal.abort();

      expect(await pending, isNull);
      await connection.closed.timeout(_oneSecond);
      expect(signal.listenerCount, 0);
    });

    test('a successful request leaves no listener and a later abort is '
        'harmless', () async {
      final server = await _CountingServer.start(
        alice.serverContext(trustedCertificatesPem: const []),
      );
      final signal = AbortSignal();

      for (var i = 0; i < 5; i++) {
        final response = await post(
          server.port,
          expected: alice.fingerprint,
          abort: signal,
        );
        expect(response?.status, 404);
      }

      expect(signal.listenerCount, 0);
      expect(signal.abort, returnsNormally);
      expect(server.handled, 5);
    });

    test('one signal aborts several requests at once', () async {
      final peer = await _RawPeer.tls(alice);
      final signal = AbortSignal();

      final pending = [
        for (var i = 0; i < 5; i++)
          post(
            peer.port,
            expected: alice.fingerprint,
            timeout: const Duration(seconds: 10),
            abort: signal,
          ),
      ];
      while (peer.connections.where((c) => c.hasRequest).length < 5) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
      expect(signal.listenerCount, 5);
      signal.abort();

      expect(await Future.wait(pending), everyElement(isNull));
      await Future.wait(peer.connections.map((c) => c.closed))
          .timeout(_oneSecond);
      expect(signal.listenerCount, 0);
    });
  });

  group('C22: deadline', () {
    test('a server that reads the request and stays silent gives null at '
        'the deadline and sees its socket closed', () async {
      final peer = await _RawPeer.tls(alice);
      final watch = Stopwatch()..start();

      final response = await post(
        peer.port,
        expected: alice.fingerprint,
        timeout: const Duration(milliseconds: 500),
      );

      expect(response, isNull);
      expect(
        watch.elapsed,
        greaterThanOrEqualTo(const Duration(milliseconds: 450)),
      );
      expect(watch.elapsed, lessThan(_twoSeconds));
      final connection = await peer.firstConnection;
      expect(connection.hasRequest, isTrue);
      await connection.closed.timeout(_oneSecond);
    });

    test('a hung TLS handshake gives null at the deadline and the socket is '
        'closed', () async {
      final peer = await _RawPeer.tcp();
      final watch = Stopwatch()..start();

      final response = await post(
        peer.port,
        expected: alice.fingerprint,
        timeout: const Duration(milliseconds: 500),
      );

      expect(response, isNull);
      expect(watch.elapsed, lessThan(_twoSeconds));
      await (await peer.firstConnection).closed.timeout(_oneSecond);
    });

    test('the deadline covers a body that never ends', () async {
      final peer = await _RawPeer.tls(
        alice,
        reply: (_) => _reply(200, utf8.encode('{"a"'), lengthValues: ['500']),
        closeAfterReply: false,
      );
      final watch = Stopwatch()..start();

      final response = await post(
        peer.port,
        expected: alice.fingerprint,
        timeout: const Duration(milliseconds: 500),
      );

      expect(response, isNull);
      expect(watch.elapsed, lessThan(_twoSeconds));
      await (await peer.firstConnection).closed.timeout(_oneSecond);
    });

    test('a closed port gives null well before the deadline', () async {
      final probe = await ServerSocket.bind(_loopback, 0);
      final port = probe.port;
      await probe.close();
      final watch = Stopwatch()..start();

      final response = await post(
        port,
        expected: alice.fingerprint,
        timeout: const Duration(seconds: 1),
      );

      expect(response, isNull);
      expect(watch.elapsed, lessThan(_twoSeconds));
    });

    test('a plain TCP server that answers garbage instead of TLS gives '
        'null', () async {
      final peer = await _RawPeer.tcp(
        reply: (_) => utf8.encode('HTTP/1.1 200 OK\r\n\r\nnot tls'),
      );

      expect(await post(peer.port, expected: alice.fingerprint), isNull);
      expect(peer.accepted, 1);
    });
  });

  group('C22: source address (plan, "Por qué sourceAddress")', () {
    test('without sourceAddress the server sees 127.0.0.1', () async {
      final server = await _CountingServer.start(
        alice.serverContext(trustedCertificatesPem: const []),
      );

      await post(server.port, expected: alice.fingerprint);

      expect(server.requests.single.from, _loopback);
    });

    test('with sourceAddress 127.0.0.2 the server sees 127.0.0.2', () async {
      final server = await _CountingServer.start(
        alice.serverContext(trustedCertificatesPem: const []),
      );

      final response = await post(
        server.port,
        expected: alice.fingerprint,
        sourceAddress: _second,
      );

      expect(response?.status, 404);
      expect(server.requests.single.from, _second);
    });

    test('to a server on 127.0.0.2 from 127.0.0.3 the server sees 127.0.0.3 '
        'and the Host header names 127.0.0.2', () async {
      final server = await _CountingServer.start(
        alice.serverContext(trustedCertificatesPem: const []),
        address: _second,
      );

      final response = await post(
        server.port,
        expected: alice.fingerprint,
        address: _second,
        sourceAddress: _third,
      );

      expect(response?.status, 404);
      expect(server.requests.single.from, _third);
      expect(server.requests.single.host, '127.0.0.2');
      expect(server.requests.single.hostPort, server.port);
    });

    test('a source address that is not on this machine gives null without '
        'throwing and reaches nothing', () async {
      final server = await _CountingServer.start(
        alice.serverContext(trustedCertificatesPem: const []),
      );

      final pending = post(
        server.port,
        expected: alice.fingerprint,
        sourceAddress: InternetAddress('192.0.2.1'),
        timeout: _twoSeconds,
      );

      await expectLater(pending, completion(isNull));
      expect(server.handled, 0);
    });
  });

  group('C22: the request on the wire', () {
    test('the head has the method, path, Host with port, JSON type, exact '
        'Content-Length and Connection: close', () async {
      final peer = await _RawPeer.tls(
        alice,
        reply: (_) => _reply(200, utf8.encode('{}')),
      );
      const json = {'name': 'Portátil 💻'};

      await post(
        peer.port,
        expected: alice.fingerprint,
        path: ApiPaths.pairWait,
        json: json,
      );

      final connection = peer.connections.single;
      final lines = connection.head.split('\r\n');
      final payload = utf8.encode(jsonEncode(json));
      expect(lines.first, 'POST ${ApiPaths.pairWait} HTTP/1.1');
      expect(
        lines.skip(1).map((l) => l.toLowerCase()),
        unorderedEquals([
          'host: 127.0.0.1:${peer.port}',
          'content-type: $_jsonType',
          'content-length: ${payload.length}',
          'connection: close',
        ]),
      );
      expect(connection.body, payload);
    });
  });

  group('C22: a body that cannot be encoded', () {
    final cyclic = <Object?>[];
    cyclic.add(cyclic);
    final cases = <String, Object?>{
      'an Object': Object(),
      'a cyclic list': cyclic,
      'NaN': double.nan,
      'infinity': double.infinity,
      'a map with a non string key': {1: 'one'},
      'a DateTime inside a map': {'at': DateTime.utc(2026)},
    };

    cases.forEach((name, value) {
      test('$name gives null and opens no connection', () async {
        expect(() => jsonEncode(value), throwsA(anything));
        final peer = await _RawPeer.tcp();
        final signal = AbortSignal();

        final pending = post(
          peer.port,
          expected: alice.fingerprint,
          json: value,
          abort: signal,
        );

        await expectLater(pending, completion(isNull));
        await Future<void>.delayed(_settle);
        expect(peer.accepted, 0);
        expect(signal.listenerCount, 0);
      });
    });
  });

  group('HttpsResponse', () {
    test('keeps the status and body it is given', () {
      final body = Uint8List.fromList([1, 2, 3]);
      final response = HttpsResponse(418, body);

      expect(response.status, 418);
      expect(response.body, same(body));
    });
  });
}
