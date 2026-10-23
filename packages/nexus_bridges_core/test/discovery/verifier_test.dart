import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:nexus_bridges_core/src/discovery/discovery.dart';
import 'package:nexus_bridges_core/src/identity/identity.dart';
import 'package:nexus_bridges_core/src/protocol/protocol.dart';
import 'package:test/test.dart';

import '../server/api_server_harness.dart';

const Duration _oneSecond = Duration(seconds: 1);
const Duration _twoSeconds = Duration(seconds: 2);

final RegExp _contentLength = RegExp(
  r'content-length:\s*(\d+)',
  caseSensitive: false,
);

bool _isCompleteRequest(List<int> bytes) {
  final text = latin1.decode(bytes);
  final end = text.indexOf('\r\n\r\n');
  if (end < 0) return false;
  final match = _contentLength.firstMatch(text.substring(0, end));
  final length = match == null ? 0 : int.parse(match.group(1)!);
  return bytes.length >= end + 4 + length;
}

List<int> _httpReply(
  int status,
  List<int> body, {
  int? contentLength,
  List<String>? lengthValues,
  Map<String, String> headers = const {},
}) {
  final head = StringBuffer('HTTP/1.1 $status Reply\r\n')
    ..write('content-type: $jsonContentType\r\n');
  for (final value in lengthValues ?? ['${contentLength ?? body.length}']) {
    head.write('content-length: $value\r\n');
  }
  head.write('connection: close\r\n');
  headers.forEach((name, value) => head.write('$name: $value\r\n'));
  head.write('\r\n');
  return [...utf8.encode(head.toString()), ...body];
}

List<int> _chunkedReply(List<int> body, {int chunkSize = 8192}) {
  final out = <int>[
    ...utf8.encode(
      'HTTP/1.1 200 OK\r\n'
      'content-type: $jsonContentType\r\n'
      'transfer-encoding: chunked\r\n'
      'connection: close\r\n\r\n',
    ),
  ];
  for (var start = 0; start < body.length; start += chunkSize) {
    final end = start + chunkSize > body.length
        ? body.length
        : start + chunkSize;
    out
      ..addAll(utf8.encode('${(end - start).toRadixString(16)}\r\n'))
      ..addAll(body.sublist(start, end))
      ..addAll(utf8.encode('\r\n'));
  }
  out.addAll(utf8.encode('0\r\n\r\n'));
  return out;
}

List<int> _paddedJson(Object? json, int size) {
  final text = jsonEncode(json);
  expect(text.length, lessThanOrEqualTo(size));
  return utf8.encode(text.padRight(size));
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

  bool get isClosed => _closed.isCompleted;

  void _finish() {
    if (!_closed.isCompleted) _closed.complete();
  }
}

List<List<int>> _slices(List<int> bytes, int size) => [
  for (var start = 0; start < bytes.length; start += size)
    bytes.sublist(
      start,
      start + size > bytes.length ? bytes.length : start + size,
    ),
];

List<List<int>> _cutAt(List<int> bytes, List<int> offsets) {
  final bounds = [0, ...offsets, bytes.length];
  return [
    for (var i = 0; i + 1 < bounds.length; i++)
      bytes.sublist(bounds[i], bounds[i + 1]),
  ];
}

int _headerEndOf(List<int> reply) => latin1.decode(reply).indexOf('\r\n\r\n');

List<int> _replyWithHeaderOf(int headerBytes, List<int> body) {
  final base = _httpReply(200, body, headers: {'x-filler': ''});
  final reply = _httpReply(
    200,
    body,
    headers: {'x-filler': 'a' * (headerBytes - _headerEndOf(base))},
  );
  expect(_headerEndOf(reply), headerBytes);
  return reply;
}

const String _connectAccountingScript = r'''
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:nexus_bridges_core/src/discovery/discovery.dart';
import 'package:nexus_bridges_core/src/identity/identity.dart';
import 'package:nexus_bridges_core/src/protocol/protocol.dart';

Future<void> main(List<String> args) async {
  final commands = StreamIterator(
    stdin.transform(utf8.decoder).transform(const LineSplitter()),
  );
  const long = Duration(seconds: 10);
  const settle = Duration(milliseconds: 300);
  final identity = DeviceIdentity.generate(
    commonName: randomCommonName(),
  );
  final verifier = DeviceVerifier(identity: identity);
  final self = DeviceInfo(
    name: 'Child',
    fingerprint: identity.fingerprint,
    port: 40000,
    protocol: protocolVersion,
    deviceType: DeviceType.desktop,
  );
  Future<DeviceInfo?> register(
    int port,
    Duration timeout, [
    AbortSignal? abort,
  ]) => verifier.register(
    address: InternetAddress.loopbackIPv4,
    port: port,
    expectedFingerprint: null,
    self: self,
    timeout: timeout,
    abort: abort,
  );

  final controls = <Future<DeviceInfo?>>[];
  stdout.writeln(pid);
  while (await commands.moveNext()) {
    final words = commands.current.split(' ');
    if (words.first == 'end') break;
    final target = int.parse(words[1]);
    controls.add(register(int.parse(words[2]), long));
    if (words.first == 'abort') {
      final signal = AbortSignal();
      final pending = register(target, long, signal);
      await Future<void>.delayed(const Duration(milliseconds: 100));
      signal.abort();
      final result = await pending;
      await Future<void>.delayed(settle);
      stdout.writeln('settled $result ${signal.listenerCount}');
    } else {
      final result = await register(target, settle);
      await Future<void>.delayed(settle);
      stdout.writeln('settled $result');
    }
  }
  await commands.cancel();
  final results = await Future.wait(controls);
  stdout.writeln('controls ${results.every((r) => r == null)}');
}
''';

Future<int> _synSent(int owner, int remotePort) async {
  final result = await Process.run('netstat', ['-ano', '-p', 'TCP']);
  return '${result.stdout}'
      .split('\n')
      .map((line) => line.trim().split(RegExp(r'\s+')))
      .where(
        (cells) =>
            cells.length == 5 &&
            cells[0] == 'TCP' &&
            cells[2].endsWith(':$remotePort') &&
            cells[3] == 'SYN_SENT' &&
            cells[4] == '$owner',
      )
      .length;
}

Future<List<int>> _closedPorts(int count) async {
  final ports = <int>{};
  while (ports.length < count) {
    ports.add(await freePort());
  }
  return ports.toList();
}

final class _Peer {
  _Peer._(
    this.port,
    this._stop,
    this._reply,
    this._closeAfterReply, [
    this._pieces,
    this._pause = Duration.zero,
  ]);

  static Future<_Peer> tls(
    DeviceIdentity identity, {
    List<int>? reply,
    bool closeAfterReply = true,
    List<List<int>>? pieces,
    Duration pause = Duration.zero,
  }) async {
    final server = await SecureServerSocket.bind(
      loopback,
      0,
      presenting(identity),
    );
    final peer = _Peer._(
      server.port,
      server.close,
      reply,
      closeAfterReply,
      pieces,
      pause,
    );
    server.listen(peer._accept, onError: (Object _) {});
    addTearDown(peer.close);
    return peer;
  }

  static Future<_Peer> silentTcp() async {
    final server = await ServerSocket.bind(loopback, 0);
    final peer = _Peer._(server.port, server.close, null, false);
    server.listen(peer._accept, onError: (Object _) {});
    addTearDown(peer.close);
    return peer;
  }

  static Future<_Peer> resetting() async {
    final server = await ServerSocket.bind(loopback, 0);
    final peer = _Peer._(server.port, server.close, null, false);
    server.listen((socket) {
      peer.accepted++;
      socket.destroy();
    }, onError: (Object _) {});
    addTearDown(peer.close);
    return peer;
  }

  final int port;
  final Future<void> Function() _stop;
  final List<int>? _reply;
  final bool _closeAfterReply;
  final List<List<int>>? _pieces;
  final Duration _pause;
  final List<_Connection> connections = [];
  final Completer<_Connection> _first = Completer();
  int accepted = 0;

  Future<_Connection> get firstConnection => _first.future;

  void _accept(Socket socket) {
    accepted++;
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
        final pieces = _pieces;
        if (pieces != null) {
          _writePieces(socket, pieces).ignore();
          return;
        }
        final reply = _reply;
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

  Future<void> _writePieces(Socket socket, List<List<int>> pieces) async {
    try {
      for (final piece in pieces) {
        socket.add(piece);
        await socket.flush();
        if (_pause > Duration.zero) await Future<void>.delayed(_pause);
      }
      if (_closeAfterReply) await socket.close();
    } on Object {
      return;
    }
  }

  Future<void> close() async {
    for (final connection in connections) {
      connection.socket.destroy();
    }
    await _stop();
  }
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

  Future<DeviceInfo?> register(
    int port, {
    String? expectedFingerprint,
    Duration timeout = const Duration(seconds: 5),
    AbortSignal? abort,
  }) => verifier.register(
    address: loopback,
    port: port,
    expectedFingerprint: expectedFingerprint,
    self: self,
    timeout: timeout,
    abort: abort,
  );

  group('AbortSignal', () {
    test('a new signal is not aborted and holds no listeners', () {
      final signal = AbortSignal();

      expect(signal.aborted, isFalse);
      expect(signal.listenerCount, 0);
    });

    test('abort marks the signal and calls every listener exactly once', () {
      final signal = AbortSignal();
      final calls = <String>[];
      signal
        ..onAbort(() => calls.add('a'))
        ..onAbort(() => calls.add('b'));
      expect(signal.listenerCount, 2);

      signal.abort();

      expect(signal.aborted, isTrue);
      expect(calls, unorderedEquals(<String>['a', 'b']));
      expect(signal.listenerCount, 0);
    });

    test('abort is idempotent: a second abort calls nobody again', () {
      final signal = AbortSignal();
      var calls = 0;
      signal.onAbort(() => calls++);

      signal
        ..abort()
        ..abort();

      expect(calls, 1);
      expect(signal.aborted, isTrue);
    });

    test('onAbort on an aborted signal calls the callback before returning '
        'and keeps no listener', () {
      final signal = AbortSignal()..abort();
      var calls = 0;

      final remove = signal.onAbort(() => calls++);

      expect(calls, 1);
      expect(signal.listenerCount, 0);
      remove();
      signal.abort();
      expect(calls, 1);
    });

    test('the returned function removes only its own listener', () {
      final signal = AbortSignal();
      final calls = <String>[];
      final removeA = signal.onAbort(() => calls.add('a'));
      signal.onAbort(() => calls.add('b'));

      removeA();
      expect(signal.listenerCount, 1);
      signal.abort();

      expect(calls, ['b']);
    });

    test('removing a listener twice or after the abort is harmless', () {
      final signal = AbortSignal();
      var calls = 0;
      final remove = signal.onAbort(() => calls++);

      remove();
      remove();
      signal.abort();
      remove();

      expect(calls, 0);
      expect(signal.listenerCount, 0);
    });

    test(
      'a listener that throws does not stop the others nor abort itself',
      () {
        final signal = AbortSignal();
        final calls = <String>[];
        signal
          ..onAbort(() => calls.add('before'))
          ..onAbort(() => throw StateError('listener failed'))
          ..onAbort(() => calls.add('after'));

        expect(signal.abort, returnsNormally);

        expect(calls, unorderedEquals(<String>['before', 'after']));
        expect(signal.aborted, isTrue);
      },
    );

    test('a throwing callback on an already aborted signal does not escape '
        'onAbort', () {
      final signal = AbortSignal()..abort();

      expect(
        () => signal.onAbort(() => throw StateError('listener failed')),
        returnsNormally,
      );
    });
  });

  group('presentation against the real server (RF-42, RF-43, SEC-05)', () {
    test('with the expected fingerprint of the server it returns the '
        'server DeviceInfo and presents self exactly', () async {
      final harness = await ServerHarness.start(identity: alice);

      final info = await register(
        harness.port,
        expectedFingerprint: alice.fingerprint,
      );

      expect(info, isNotNull);
      expect(info!.toJson(), selfInfoOf(alice).toJson());
      expect(harness.registrations, hasLength(1));
      expect(harness.registrations.single.caller.toJson(), self.toJson());
      expect(harness.registrations.single.from, loopback);
    });

    test('with the fingerprint of another device it returns null and the '
        'server never receives the presentation', () async {
      final harness = await ServerHarness.start(identity: alice);

      final info = await register(
        harness.port,
        expectedFingerprint: carol.fingerprint,
      );

      expect(info, isNull);
      expect(harness.registrations, isEmpty);
    });

    test('without an expected fingerprint it accepts the server whose body '
        'matches its certificate', () async {
      final harness = await ServerHarness.start(identity: alice);

      final info = await register(harness.port);

      expect(info?.fingerprint, alice.fingerprint);
      expect(harness.registrations.single.caller.fingerprint, bob.fingerprint);
    });

    test('a 429 from the real server once its register limit is spent '
        'gives null', () async {
      final harness = await ServerHarness.start(identity: alice);

      for (var i = 0; i < Limits.registerPerMinute; i++) {
        final info = await register(
          harness.port,
          expectedFingerprint: alice.fingerprint,
        );
        expect(info?.fingerprint, alice.fingerprint, reason: 'call $i');
      }
      final limited = await register(
        harness.port,
        expectedFingerprint: alice.fingerprint,
      );

      expect(limited, isNull);
      expect(harness.registrations, hasLength(Limits.registerPerMinute));
    });
  });

  group('replies a real server never gives (SEC-05, RF-43)', () {
    test('control: a fake peer that answers 200 with its own info is '
        'accepted', () async {
      final peer = await _Peer.tls(
        alice,
        reply: _httpReply(200, jsonBody(selfInfoOf(alice).toJson())),
      );

      final info = await register(
        peer.port,
        expectedFingerprint: alice.fingerprint,
      );

      expect(info?.toJson(), selfInfoOf(alice).toJson());
      expect(
        peer.connections.single.received,
        isNotEmpty,
        reason: 'the presentation reached the peer',
      );
    });

    test('200 with a valid DeviceInfo of another fingerprint than the '
        'certificate gives null without an expected fingerprint', () async {
      final peer = await _Peer.tls(
        alice,
        reply: _httpReply(200, jsonBody(selfInfoOf(carol).toJson())),
      );

      expect(await register(peer.port), isNull);
      expect(peer.accepted, 1);
    });

    test('200 with a body of another fingerprint gives null also when the '
        'certificate is the expected one', () async {
      final peer = await _Peer.tls(
        alice,
        reply: _httpReply(200, jsonBody(selfInfoOf(carol).toJson())),
      );

      expect(
        await register(peer.port, expectedFingerprint: alice.fingerprint),
        isNull,
      );
    });

    test('a certificate of another device with the expected body gives '
        'null and sends no presentation', () async {
      final peer = await _Peer.tls(
        carol,
        reply: _httpReply(200, jsonBody(selfInfoOf(alice).toJson())),
      );

      final info = await register(
        peer.port,
        expectedFingerprint: alice.fingerprint,
      );

      expect(info, isNull);
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(
        peer.connections.every(
          (c) => !utf8.decode(c.received, allowMalformed: true).contains('{'),
        ),
        isTrue,
      );
    });

    for (final status in [401, 429, 201, 204, 500]) {
      test('status $status with a valid body gives null', () async {
        final peer = await _Peer.tls(
          alice,
          reply: _httpReply(status, jsonBody(selfInfoOf(alice).toJson())),
        );

        expect(
          await register(peer.port, expectedFingerprint: alice.fingerprint),
          isNull,
        );
      });
    }

    test('a redirect is not followed and gives null', () async {
      final harness = await ServerHarness.start(identity: alice);
      final peer = await _Peer.tls(
        alice,
        reply: _httpReply(
          302,
          const [],
          headers: {
            'location': 'https://127.0.0.1:${harness.port}$registerPath',
          },
        ),
      );

      final info = await register(
        peer.port,
        expectedFingerprint: alice.fingerprint,
      );

      expect(info, isNull);
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(harness.registrations, isEmpty);
    });

    final validJson = <String, Object?>{
      'name': 'Server PC',
      'port': defaultPort,
      'protocol': protocolVersion,
      'deviceType': 'desktop',
    };

    final malformedBodies = <String, List<int> Function(String fingerprint)>{
      'a body that is not JSON': (_) => utf8.encode('not json at all'),
      'an empty body': (_) => const [],
      'a JSON array': (fp) => jsonBody([
        {...validJson, 'fingerprint': fp},
      ]),
      'a DeviceInfo with an extra key': (fp) =>
          jsonBody({...validJson, 'fingerprint': fp, 'extra': true}),
      'a DeviceInfo without deviceType': (fp) =>
          jsonBody({...validJson, 'fingerprint': fp}..remove('deviceType')),
      'a DeviceInfo with another protocol major': (fp) =>
          jsonBody({...validJson, 'fingerprint': fp, 'protocol': '2.0'}),
      'a body that is not UTF-8': (_) => [0xC3, 0x28, 0xFF, 0xFE],
    };

    malformedBodies.forEach((name, body) {
      test('200 with $name gives null', () async {
        final peer = await _Peer.tls(
          alice,
          reply: _httpReply(200, body(alice.fingerprint)),
        );

        expect(
          await register(peer.port, expectedFingerprint: alice.fingerprint),
          isNull,
        );
      });
    });
  });

  group('body limit of 64 KiB (Limits.maxBodyBytes)', () {
    test('a body of exactly 64 KiB is still read', () async {
      final peer = await _Peer.tls(
        alice,
        reply: _httpReply(
          200,
          _paddedJson(selfInfoOf(alice).toJson(), Limits.maxBodyBytes),
        ),
      );

      final info = await register(
        peer.port,
        expectedFingerprint: alice.fingerprint,
      );

      expect(info?.fingerprint, alice.fingerprint);
    });

    test('a body of 64 KiB plus one byte gives null', () async {
      final peer = await _Peer.tls(
        alice,
        reply: _httpReply(
          200,
          _paddedJson(selfInfoOf(alice).toJson(), Limits.maxBodyBytes + 1),
        ),
      );

      expect(
        await register(peer.port, expectedFingerprint: alice.fingerprint),
        isNull,
      );
    });

    test('a chunked body larger than 64 KiB gives null', () async {
      final peer = await _Peer.tls(
        alice,
        reply: _chunkedReply(
          _paddedJson(selfInfoOf(alice).toJson(), Limits.maxBodyBytes * 2),
        ),
      );

      expect(
        await register(peer.port, expectedFingerprint: alice.fingerprint),
        isNull,
      );
    });

    test('a chunked response is rejected even when small', () async {
      final peer = await _Peer.tls(
        alice,
        reply: _chunkedReply(
          jsonBody(selfInfoOf(alice).toJson()),
          chunkSize: 16,
        ),
      );

      expect(
        await register(peer.port, expectedFingerprint: alice.fingerprint),
        isNull,
      );
    });
  });

  group('response framing (plan v2.10 point 2)', () {
    Future<DeviceInfo?> registerAgainst(List<int> reply) async {
      final peer = await _Peer.tls(alice, reply: reply);
      return register(peer.port, expectedFingerprint: alice.fingerprint);
    }

    List<int> aliceBody() => jsonBody(selfInfoOf(alice).toJson());

    test('a response without Content-Length gives null', () async {
      expect(
        await registerAgainst(
          _httpReply(200, aliceBody(), lengthValues: const []),
        ),
        isNull,
      );
    });

    for (final values in [
      ['abc'],
      ['-1'],
      ['1e3'],
      ['0x40'],
    ]) {
      test(
        'a non numeric Content-Length ${values.single} gives null',
        () async {
          expect(
            await registerAgainst(
              _httpReply(200, aliceBody(), lengthValues: values),
            ),
            isNull,
          );
        },
      );
    }

    test(
      'a repeated Content-Length gives null even with equal values',
      () async {
        final body = aliceBody();

        expect(
          await registerAgainst(
            _httpReply(
              200,
              body,
              lengthValues: ['${body.length}', '${body.length}'],
            ),
          ),
          isNull,
        );
      },
    );

    test('a Content-Length larger than what is sent before the connection '
        'closes gives null', () async {
      final body = aliceBody();

      expect(
        await registerAgainst(
          _httpReply(200, body, contentLength: body.length + 100),
        ),
        isNull,
      );
    });

    test('a Content-Length announcing more than 64 KiB gives null', () async {
      expect(
        await registerAgainst(
          _httpReply(200, aliceBody(), contentLength: Limits.maxBodyBytes + 1),
        ),
        isNull,
      );
    });

    for (final value in ['chunked', 'identity', 'gzip']) {
      test('any Transfer-Encoding header ($value) gives null', () async {
        expect(
          await registerAgainst(
            _httpReply(200, aliceBody(), headers: {'transfer-encoding': value}),
          ),
          isNull,
        );
      });
    }

    test('headers of more than 8 KiB give null', () async {
      expect(
        await registerAgainst(
          _httpReply(
            200,
            aliceBody(),
            headers: {'x-filler': 'a' * (Limits.maxHeaderBytes + 100)},
          ),
        ),
        isNull,
      );
    });

    test('control: headers of almost 8 KiB are still read', () async {
      final info = await registerAgainst(
        _httpReply(
          200,
          aliceBody(),
          headers: {'x-filler': 'a' * (Limits.maxHeaderBytes - 500)},
        ),
      );

      expect(info?.fingerprint, alice.fingerprint);
    });

    test('bytes beyond the Content-Length are ignored and the body is '
        'read', () async {
      final body = aliceBody();

      final info = await registerAgainst(
        _httpReply(200, [
          ...body,
          ...utf8.encode('{"extra": true} trailing'),
        ], contentLength: body.length),
      );

      expect(info?.toJson(), selfInfoOf(alice).toJson());
    });

    test('the presentation is a POST to the register path with '
        'Connection: close and an exact Content-Length', () async {
      final peer = await _Peer.tls(alice, reply: _httpReply(200, aliceBody()));

      await register(peer.port, expectedFingerprint: alice.fingerprint);

      final request = peer.connections.single.received;
      final text = utf8.decode(request);
      final end = text.indexOf('\r\n\r\n');
      final head = text.substring(0, end).toLowerCase();
      final body = text.substring(end + 4);
      expect(text, startsWith('POST $registerPath HTTP/1.1\r\n'));
      expect(head, contains('\r\nconnection: close'));
      expect(head, contains('\r\ncontent-length: ${utf8.encode(body).length}'));
      expect(jsonDecode(body), self.toJson());
    });
  });

  group('incremental header reading (plan v2.11 point 5)', () {
    const generous = Duration(seconds: 10);
    const gap = Duration(milliseconds: 30);

    List<int> aliceBody() => jsonBody(selfInfoOf(alice).toJson());

    List<int> aliceReply({Map<String, String> headers = const {}}) =>
        _httpReply(200, aliceBody(), headers: headers);

    Future<DeviceInfo?> registerAgainstPieces(
      List<List<int>> pieces, {
      Duration pause = Duration.zero,
    }) async {
      final peer = await _Peer.tls(
        alice,
        pieces: pieces,
        pause: pause,
        closeAfterReply: false,
      );
      return register(
        peer.port,
        expectedFingerprint: alice.fingerprint,
        timeout: generous,
      );
    }

    for (final size in [1, 2, 3, 5]) {
      test('a reply written in pieces of $size bytes with a flush between '
          'them is read without waiting for the connection to close', () async {
        final info = await registerAgainstPieces(_slices(aliceReply(), size));

        expect(info?.toJson(), selfInfoOf(alice).toJson());
      });
    }

    for (var offset = -3; offset <= 5; offset++) {
      test('a reply cut in two pieces at offset $offset from the start of '
          'the blank line is read', () async {
        final reply = aliceReply();

        final info = await registerAgainstPieces(
          _cutAt(reply, [_headerEndOf(reply) + offset]),
          pause: gap,
        );

        expect(info?.toJson(), selfInfoOf(alice).toJson());
      });
    }

    test(
      'a reply whose blank line arrives one byte per piece is read',
      () async {
        final reply = aliceReply();
        final end = _headerEndOf(reply);

        final info = await registerAgainstPieces(
          _cutAt(reply, [end, end + 1, end + 2, end + 3, end + 4]),
          pause: gap,
        );

        expect(info?.toJson(), selfInfoOf(alice).toJson());
      },
    );

    test('a header longer than the first read buffer arriving in pieces of '
        '7 bytes is read', () async {
      final reply = aliceReply(headers: {'x-filler': 'a' * 3000});

      final info = await registerAgainstPieces(_slices(reply, 7));

      expect(info?.toJson(), selfInfoOf(alice).toJson());
    });

    test('a header of almost 8 KiB arriving in pieces of 64 bytes is '
        'read', () async {
      final reply = aliceReply(
        headers: {'x-filler': 'a' * (Limits.maxHeaderBytes - 500)},
      );

      final info = await registerAgainstPieces(_slices(reply, 64));

      expect(info?.toJson(), selfInfoOf(alice).toJson());
    });

    test('a header of exactly Limits.maxHeaderBytes bytes in one write is '
        'still read', () async {
      final peer = await _Peer.tls(
        alice,
        reply: _replyWithHeaderOf(Limits.maxHeaderBytes, aliceBody()),
        closeAfterReply: false,
      );

      final info = await register(
        peer.port,
        expectedFingerprint: alice.fingerprint,
        timeout: generous,
      );

      expect(info?.toJson(), selfInfoOf(alice).toJson());
    });

    test('a header of exactly Limits.maxHeaderBytes bytes cut right before '
        'the blank line is still read', () async {
      final reply = _replyWithHeaderOf(Limits.maxHeaderBytes, aliceBody());

      final info = await registerAgainstPieces(
        _cutAt(reply, [Limits.maxHeaderBytes]),
        pause: gap,
      );

      expect(info?.toJson(), selfInfoOf(alice).toJson());
    });

    test('a header of Limits.maxHeaderBytes plus one byte in one write gives '
        'null long before the deadline', () async {
      final peer = await _Peer.tls(
        alice,
        reply: _replyWithHeaderOf(Limits.maxHeaderBytes + 1, aliceBody()),
        closeAfterReply: false,
      );
      final watch = Stopwatch()..start();

      final info = await register(
        peer.port,
        expectedFingerprint: alice.fingerprint,
        timeout: generous,
      );

      expect(info, isNull);
      expect(watch.elapsed, lessThan(waitLimit));
      await (await peer.firstConnection).closed.timeout(_oneSecond);
    });

    test('a header of Limits.maxHeaderBytes plus one byte in pieces of 64 '
        'bytes gives null long before the deadline', () async {
      final peer = await _Peer.tls(
        alice,
        pieces: _slices(
          _replyWithHeaderOf(Limits.maxHeaderBytes + 1, aliceBody()),
          64,
        ),
        closeAfterReply: false,
      );
      final watch = Stopwatch()..start();

      final info = await register(
        peer.port,
        expectedFingerprint: alice.fingerprint,
        timeout: generous,
      );

      expect(info, isNull);
      expect(watch.elapsed, lessThan(waitLimit));
      await (await peer.firstConnection).closed.timeout(_oneSecond);
    });

    test('200 with Content-Length 0 ends the read at once with an empty '
        'body, which is no DeviceInfo, so it gives null long before the '
        'deadline', () async {
      final peer = await _Peer.tls(
        alice,
        reply: _httpReply(200, const []),
        closeAfterReply: false,
      );
      final watch = Stopwatch()..start();

      final info = await register(
        peer.port,
        expectedFingerprint: alice.fingerprint,
        timeout: generous,
      );

      expect(info, isNull);
      expect(watch.elapsed, lessThan(waitLimit));
      final connection = await peer.firstConnection;
      expect(connection._request.isCompleted, isTrue);
      await connection.closed.timeout(_oneSecond);
    });

    test('200 with Content-Length 0 whose headers end exactly at the end '
        'of a piece also gives null long before the deadline', () async {
      final reply = _httpReply(200, const []);
      final watch = Stopwatch()..start();

      final info = await registerAgainstPieces(
        _cutAt(reply, [_headerEndOf(reply) + 2]),
        pause: gap,
      );

      expect(info, isNull);
      expect(watch.elapsed, lessThan(waitLimit));
    });

    final excess = utf8.encode(
      '{"extra": true} trailing\r\n\r\nHTTP/1.1 200 OK\r\n\r\n',
    );

    test('bytes beyond the Content-Length in the same write as the headers '
        'are ignored without waiting for the connection to close', () async {
      final body = aliceBody();
      final peer = await _Peer.tls(
        alice,
        reply: _httpReply(200, [
          ...body,
          ...excess,
        ], contentLength: body.length),
        closeAfterReply: false,
      );

      final info = await register(
        peer.port,
        expectedFingerprint: alice.fingerprint,
        timeout: generous,
      );

      expect(info?.toJson(), selfInfoOf(alice).toJson());
    });

    test('bytes beyond the Content-Length arriving in pieces of 3 bytes are '
        'ignored', () async {
      final body = aliceBody();

      final info = await registerAgainstPieces(
        _slices(
          _httpReply(200, [...body, ...excess], contentLength: body.length),
          3,
        ),
      );

      expect(info?.toJson(), selfInfoOf(alice).toJson());
    });

    test('a body that ends in the same piece as its excess, after headers '
        'cut inside the blank line, is read', () async {
      final body = aliceBody();
      final reply = _httpReply(200, [
        ...body,
        ...excess,
      ], contentLength: body.length);

      final info = await registerAgainstPieces(
        _cutAt(reply, [_headerEndOf(reply) + 2]),
        pause: gap,
      );

      expect(info?.toJson(), selfInfoOf(alice).toJson());
    });
  });

  group('deadlines and sockets (RF-44)', () {
    test('a port without a server with a 1 s timeout gives null within '
        '2 s', () async {
      final port = await freePort();
      final watch = Stopwatch()..start();

      final info = await register(port, timeout: _oneSecond);

      expect(info, isNull);
      expect(watch.elapsed, lessThan(_twoSeconds));
    });

    test('aborting during the TCP connect gives null within 1 s', () async {
      final port = await freePort();
      final signal = AbortSignal();
      final watch = Stopwatch()..start();

      final pending = register(
        port,
        timeout: const Duration(seconds: 10),
        abort: signal,
      );
      await Future<void>.delayed(const Duration(milliseconds: 200));
      final abortedAt = watch.elapsed;
      signal.abort();

      expect(await pending, isNull);
      expect(watch.elapsed - abortedAt, lessThan(_oneSecond));
      expect(watch.elapsed, lessThan(const Duration(milliseconds: 1500)));
      expect(signal.listenerCount, 0);
    });

    test('a server that accepts TLS, reads the presentation and stays '
        'silent gives null at the deadline and sees its socket closed '
        'within 1 s', () async {
      final peer = await _Peer.tls(alice);
      final watch = Stopwatch()..start();

      final info = await register(
        peer.port,
        expectedFingerprint: alice.fingerprint,
        timeout: _oneSecond,
      );

      expect(info, isNull);
      expect(
        watch.elapsed,
        greaterThanOrEqualTo(const Duration(milliseconds: 900)),
      );
      expect(watch.elapsed, lessThan(_twoSeconds));
      final connection = await peer.firstConnection;
      expect(connection._request.isCompleted, isTrue);
      await connection.closed.timeout(_oneSecond);
    });

    test('a server that accepts TCP and never answers the TLS handshake '
        'gives null at the deadline and sees its socket closed within '
        '1 s', () async {
      final peer = await _Peer.silentTcp();
      final watch = Stopwatch()..start();

      final info = await register(peer.port, timeout: _oneSecond);

      expect(info, isNull);
      expect(watch.elapsed, lessThan(_twoSeconds));
      final connection = await peer.firstConnection;
      await connection.closed.timeout(_oneSecond);
    });

    test('the deadline covers the body: headers sent and a body that never '
        'ends give null and the socket is closed within 1 s', () async {
      final peer = await _Peer.tls(
        alice,
        reply: _httpReply(200, utf8.encode('{"name"'), contentLength: 1000),
        closeAfterReply: false,
      );
      final watch = Stopwatch()..start();

      final info = await register(
        peer.port,
        expectedFingerprint: alice.fingerprint,
        timeout: _oneSecond,
      );

      expect(info, isNull);
      expect(watch.elapsed, lessThan(_twoSeconds));
      await (await peer.firstConnection).closed.timeout(_oneSecond);
    });

    test('aborting the signal cuts a request waiting for its reply and '
        'closes the socket', () async {
      final peer = await _Peer.tls(alice);
      final signal = AbortSignal();

      final pending = register(
        peer.port,
        expectedFingerprint: alice.fingerprint,
        timeout: const Duration(seconds: 10),
        abort: signal,
      );
      final connection = await peer.firstConnection.timeout(waitLimit);
      await connection.request.timeout(waitLimit);
      expect(signal.listenerCount, 1);
      final watch = Stopwatch()..start();
      signal.abort();

      expect(await pending, isNull);
      expect(watch.elapsed, lessThan(_oneSecond));
      await connection.closed.timeout(_oneSecond);
      expect(signal.listenerCount, 0);
    });

    test('aborting the signal during the TLS handshake cuts it and closes '
        'the socket', () async {
      final peer = await _Peer.silentTcp();
      final signal = AbortSignal();

      final pending = register(
        peer.port,
        timeout: const Duration(seconds: 10),
        abort: signal,
      );
      final connection = await peer.firstConnection.timeout(waitLimit);
      await connection.firstBytes.timeout(waitLimit);
      final watch = Stopwatch()..start();
      signal.abort();

      expect(await pending, isNull);
      expect(watch.elapsed, lessThan(_oneSecond));
      await connection.closed.timeout(_oneSecond);
    });

    test('an already aborted signal gives null without presenting to a '
        'peer that would answer well', () async {
      final peer = await _Peer.tls(
        alice,
        reply: _httpReply(200, jsonBody(selfInfoOf(alice).toJson())),
      );
      final signal = AbortSignal()..abort();

      final info = await register(
        peer.port,
        expectedFingerprint: alice.fingerprint,
        abort: signal,
      );

      expect(info, isNull);
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(peer.connections.every((c) => !c._request.isCompleted), isTrue);
      expect(signal.listenerCount, 0);
    });
  });

  group('the TCP connect is cut too (plan v2.11 point 4, SEC-06)', () {
    Future<void> expectNoSynSentLeft(String mode, String settled) async {
      final packageConfig = await Isolate.packageConfig;
      expect(packageConfig, isNotNull);
      final dir = await Directory.systemTemp.createTemp('nexus_verifier_');
      addTearDown(() => dir.delete(recursive: true));
      final script = File(
        '${dir.path}${Platform.pathSeparator}connect_accounting.dart',
      );
      await script.writeAsString(_connectAccountingScript);
      final process = await Process.start(Platform.resolvedExecutable, [
        '--packages=${packageConfig!.toFilePath()}',
        script.path,
      ]);
      addTearDown(process.kill);
      final stderr = process.stderr.transform(utf8.decoder).join();
      final lines = StreamIterator(
        process.stdout.transform(utf8.decoder).transform(const LineSplitter()),
      );
      Future<String> next() async {
        final more = await lines.moveNext().timeout(
          const Duration(seconds: 60),
        );
        if (!more) fail('the child ended early: ${await stderr}');
        return lines.current;
      }

      final childPid = int.parse(await next());
      var conclusive = false;
      for (var attempt = 0; attempt < 3 && !conclusive; attempt++) {
        final [target, reference] = await _closedPorts(2);
        process.stdin.writeln('$mode $target $reference');

        expect(await next(), settled);
        expect(await _synSent(childPid, target), 0, reason: 'attempt $attempt');
        conclusive = await _synSent(childPid, reference) == 1;
      }
      process.stdin.writeln('end');

      expect(
        conclusive,
        isTrue,
        reason: 'the check ran while Windows still retried a closed port',
      );
      expect(await next(), 'controls true');
      expect(
        await process.exitCode.timeout(const Duration(seconds: 30)),
        0,
        reason: await stderr,
      );
    }

    test(
      'aborting a register while Windows still retries the connect to a '
      'closed port leaves no SYN_SENT of the process 300 ms later, and the '
      'process ends on its own',
      () => expectNoSynSentLeft('abort', 'settled null 0'),
      timeout: const Timeout(Duration(minutes: 2)),
      testOn: 'windows',
    );

    test(
      'a register whose 300 ms deadline expires during the connect to a '
      'closed port leaves no SYN_SENT of the process 300 ms later, and the '
      'process ends on its own',
      () => expectNoSynSentLeft('deadline', 'settled null'),
      timeout: const Timeout(Duration(minutes: 2)),
      testOn: 'windows',
    );
  });

  group('a long-lived signal keeps no listeners (v2.9 point 6)', () {
    test('1000 failed register calls with the same live signal leave it '
        'without listeners', () async {
      final peer = await _Peer.resetting();
      final signal = AbortSignal();

      for (var round = 0; round < 20; round++) {
        final results = await Future.wait([
          for (var i = 0; i < 50; i++) register(peer.port, abort: signal),
        ]);
        expect(results, everyElement(isNull));
      }

      expect(peer.accepted, 1000);
      expect(signal.aborted, isFalse);
      expect(signal.listenerCount, 0);
      expect(signal.abort, returnsNormally);
    });

    test(
      'register calls that end by deadline also remove their listener',
      () async {
        final peer = await _Peer.tls(alice);
        final signal = AbortSignal();

        final results = await Future.wait([
          for (var i = 0; i < 20; i++)
            register(
              peer.port,
              timeout: const Duration(milliseconds: 500),
              abort: signal,
            ),
        ]);

        expect(results, everyElement(isNull));
        expect(signal.listenerCount, 0);
        await Future.wait(peer.connections.map((c) => c.closed))
            .timeout(_oneSecond);
      },
    );

    test('successful register calls also remove their listener', () async {
      final harness = await ServerHarness.start(identity: alice);
      final signal = AbortSignal();

      for (var i = 0; i < 5; i++) {
        final info = await register(
          harness.port,
          expectedFingerprint: alice.fingerprint,
          abort: signal,
        );
        expect(info?.fingerprint, alice.fingerprint);
      }

      expect(signal.listenerCount, 0);
    });
  });

  group('proxy settings are ignored', () {
    test('with a hostile proxy for every URL the verification still goes '
        'direct', () async {
      final harness = await ServerHarness.start(identity: alice);
      final proxy = await _Peer.resetting();

      final info = await HttpOverrides.runZoned(() async {
        final control = HttpClient()
          ..badCertificateCallback = (_, _, _) => true;
        try {
          final request = await control.getUrl(
            Uri.parse('https://127.0.0.1:${harness.port}$registerPath'),
          );
          await request.close();
        } on Object {
          control.close(force: true);
        }
        control.close(force: true);
        expect(proxy.accepted, 1, reason: 'the hostile proxy is in force');

        return register(harness.port, expectedFingerprint: alice.fingerprint);
      }, findProxyFromEnvironment: (_, _) => 'PROXY 127.0.0.1:${proxy.port}');

      expect(info?.fingerprint, alice.fingerprint);
      expect(proxy.accepted, 1);
      expect(harness.registrations, hasLength(1));
    });
  });
}
