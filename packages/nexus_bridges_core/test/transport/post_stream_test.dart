import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:nexus_bridges_core/src/identity/identity.dart';
import 'package:nexus_bridges_core/src/protocol/protocol.dart';
import 'package:nexus_bridges_core/src/transport/transport.dart';
import 'package:test/test.dart';

final InternetAddress _loopback = InternetAddress.loopbackIPv4;
final InternetAddress _second = InternetAddress('127.0.0.2');
const Duration _wait = Duration(seconds: 5);
const Duration _settle = Duration(milliseconds: 200);
const Duration _oneSecond = Duration(seconds: 1);
const String _path = ApiPaths.transferUpload;
const String _jsonType = 'application/json; charset=utf-8';
const int _kib = 1024;
const int _mib = 1024 * 1024;

Uint8List _pattern(int length, {int seed = 0}) {
  final out = Uint8List(length);
  for (var i = 0; i < length; i++) {
    out[i] = (i * 13 + seed) % 241;
  }
  return out;
}

Stream<List<int>> _chunked(Uint8List data, {int size = 64 * _kib}) async* {
  for (var i = 0; i < data.length; i += size) {
    yield Uint8List.sublistView(data, i, min(i + size, data.length));
  }
}

Stream<List<int>> _endless({int size = 64 * _kib}) async* {
  final block = _pattern(size);
  while (true) {
    yield block;
  }
}

Stream<List<int>> _slow(int chunks, Duration every, {int size = 10}) async* {
  for (var i = 0; i < chunks; i++) {
    await Future<void>.delayed(every);
    yield _pattern(size, seed: i);
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

String _describe(StreamPostResult result) => switch (result) {
  StreamPostAnswered(:final response, :final bodyComplete) =>
    'answered ${response.status} ${bodyComplete ? 'complete' : 'partial'}',
  StreamPostFailed(:final failure) => 'failed ${failure.name}',
};

bool _calledByTls() =>
    StackTrace.current.toString().contains('_onBadCertificateWrapper');

enum _Mode { answerAtEnd, answerAtHead, silent, stall, closeAtHead }

final RegExp _lengthHeader = RegExp(
  r'content-length:\s*(\d+)',
  caseSensitive: false,
);

final class _PeerConnection {
  _PeerConnection(this.socket);

  final Socket socket;
  final BytesBuilder received = BytesBuilder();
  final Completer<void> _closed = Completer<void>();
  final Completer<void> _head = Completer<void>();
  int? _headEnd;
  int? _announced;
  StreamSubscription<Uint8List>? subscription;
  bool answered = false;

  Future<void> get closed => _closed.future;

  Future<void> get headArrived => _head.future;

  InternetAddress get from => socket.remoteAddress;

  String get head {
    final bytes = received.toBytes();
    return latin1.decode(bytes.sublist(0, _headEnd));
  }

  Uint8List get body {
    final bytes = received.toBytes();
    return Uint8List.sublistView(bytes, _headEnd! + 4);
  }

  int get bodyLength => _headEnd == null ? 0 : received.length - _headEnd! - 4;

  bool get complete => _headEnd != null && bodyLength >= (_announced ?? 0);

  void _scanHead() {
    if (_headEnd != null) return;
    final text = latin1.decode(received.toBytes());
    final end = text.indexOf('\r\n\r\n');
    if (end < 0) return;
    _headEnd = end;
    final match = _lengthHeader.firstMatch(text.substring(0, end));
    _announced = match == null ? 0 : int.parse(match.group(1)!);
    if (!_head.isCompleted) _head.complete();
  }

  void _finish() {
    if (!_closed.isCompleted) _closed.complete();
  }
}

final class _Peer {
  _Peer._(this._server, this.mode, this.answer);

  static Future<_Peer> start(
    DeviceIdentity identity, {
    _Mode mode = _Mode.answerAtEnd,
    List<int>? answer,
  }) async {
    final server = await SecureServerSocket.bind(
      _loopback,
      0,
      identity.serverContext(trustedCertificatesPem: const []),
    );
    final peer = _Peer._(
      server,
      mode,
      answer ?? _reply(200, utf8.encode('{"state":"saved","marked":true}')),
    );
    server.listen(peer._accept, onError: (Object _) {});
    addTearDown(peer.close);
    return peer;
  }

  final SecureServerSocket _server;
  final _Mode mode;
  final List<int> answer;
  final List<_PeerConnection> connections = [];
  final Completer<_PeerConnection> _first = Completer<_PeerConnection>();

  int get port => _server.port;

  Future<_PeerConnection> get firstConnection => _first.future;

  void _accept(SecureSocket socket) {
    final connection = _PeerConnection(socket);
    connections.add(connection);
    if (!_first.isCompleted) _first.complete(connection);
    socket.done.ignore();
    connection.subscription = socket.listen(
      (chunk) => _onData(connection, chunk),
      onError: (Object _) => connection._finish(),
      onDone: connection._finish,
      cancelOnError: true,
    );
    if (mode == _Mode.stall) connection.subscription!.pause();
  }

  void _onData(_PeerConnection connection, Uint8List chunk) {
    connection.received.add(chunk);
    connection._scanHead();
    if (connection._headEnd == null || connection.answered) return;
    switch (mode) {
      case _Mode.answerAtEnd:
        if (!connection.complete) return;
        connection.answered = true;
        _send(connection, close: true);
      case _Mode.answerAtHead:
        connection.answered = true;
        _send(connection, close: false);
        connection.subscription?.pause();
      case _Mode.closeAtHead:
        connection.answered = true;
        connection.socket.destroy();
        connection._finish();
      case _Mode.silent:
      case _Mode.stall:
        return;
    }
  }

  void _send(_PeerConnection connection, {required bool close}) {
    try {
      connection.socket.add(answer);
      if (close) connection.socket.close().ignore();
    } on Object {
      return;
    }
  }

  Future<void> close() async {
    for (final connection in connections) {
      connection.socket.destroy();
    }
    await _server.close();
  }
}

final class _TcpPeer {
  _TcpPeer._(this._server);

  static Future<_TcpPeer> start() async {
    final server = await ServerSocket.bind(_loopback, 0);
    final peer = _TcpPeer._(server);
    server.listen((socket) {
      peer.sockets.add(socket);
      socket.listen((_) {}, onError: (Object _) {});
    }, onError: (Object _) {});
    addTearDown(peer.close);
    return peer;
  }

  final ServerSocket _server;
  final List<Socket> sockets = [];

  int get port => _server.port;

  int get accepted => sockets.length;

  Future<void> close() async {
    for (final socket in sockets) {
      socket.destroy();
    }
    await _server.close();
  }
}

void main() {
  late DeviceIdentity alice;
  late DeviceIdentity bob;
  late DeviceIdentity carol;

  setUpAll(() {
    alice = DeviceIdentity.generate();
    bob = DeviceIdentity.generate();
    carol = DeviceIdentity.generate();
  });

  Future<StreamPostResult> send(
    int port, {
    Stream<List<int>>? body,
    required int length,
    Map<String, String> headers = const {},
    String? expected,
    bool Function(X509Certificate certificate)? acceptServer,
    InternetAddress? sourceAddress,
    Duration connectTimeout = _wait,
    Duration idle = _wait,
    Duration answer = _wait,
    int maxResponseBytes = Limits.maxTransferBodyBytes,
    void Function(int sent)? onProgress,
    void Function()? onBodySent,
    AbortSignal? abort,
  }) => postStream(
    address: _loopback,
    port: port,
    path: _path,
    headers: headers,
    contentLength: length,
    body: body ?? const Stream<List<int>>.empty(),
    context: bob.clientContext(presentCertificate: true),
    acceptServer:
        acceptServer ??
        (certificate) =>
            certificateMatches(certificate, expected ?? alice.fingerprint),
    sourceAddress: sourceAddress,
    connectTimeout: connectTimeout,
    idleTimeout: idle,
    answerTimeout: answer,
    maxResponseBytes: maxResponseBytes,
    onProgress: onProgress,
    onBodySent: onBodySent,
    abort: abort,
  );

  group('the request on the wire', () {
    test('POST to the path with Host, octet-stream, the exact Content-Length, '
        'Connection: close and the extra headers; the body arrives byte for '
        'byte', () async {
      final peer = await _Peer.start(alice);
      final data = _pattern(300 * _kib, seed: 5);

      final result = await send(
        peer.port,
        body: _chunked(data),
        length: data.length,
        headers: {
          TransferHeaders.transfer: '0123456789abcdef0123456789abcdef',
          'x-nexusbridges-extra': 'value with spaces',
        },
      );

      expect(_describe(result), 'answered 200 complete');
      expect(
        jsonDecode(utf8.decode((result as StreamPostAnswered).response.body)),
        {'state': 'saved', 'marked': true},
      );
      final connection = peer.connections.single;
      final lines = connection.head.split('\r\n');
      expect(lines.first, 'POST $_path HTTP/1.1');
      expect(
        lines.skip(1).map((l) => l.toLowerCase()),
        unorderedEquals([
          'host: 127.0.0.1:${peer.port}',
          'content-type: application/octet-stream',
          'content-length: ${data.length}',
          'connection: close',
          '${TransferHeaders.transfer}: 0123456789abcdef0123456789abcdef',
          'x-nexusbridges-extra: value with spaces',
        ]),
      );
      expect(connection.body, orderedEquals(data));
    });

    test('a body of 0 bytes sends Content-Length 0, calls onBodySent once '
        'and never onProgress', () async {
      final peer = await _Peer.start(alice);
      final progress = <int>[];
      var bodySent = 0;

      final result = await send(
        peer.port,
        length: 0,
        onProgress: progress.add,
        onBodySent: () => bodySent++,
      );

      expect(_describe(result), 'answered 200 complete');
      expect(peer.connections.single.head, contains('Content-Length: 0'));
      expect(peer.connections.single.bodyLength, 0);
      expect(bodySent, 1);
      expect(progress, isEmpty);
    });

    test('onProgress only grows, ends at the total, and onBodySent fires '
        'once after the last byte', () async {
      final peer = await _Peer.start(alice);
      final data = _pattern(2 * _mib);
      final events = <String>[];

      final result = await send(
        peer.port,
        body: _chunked(data),
        length: data.length,
        onProgress: (sent) => events.add('$sent'),
        onBodySent: () => events.add('sent'),
      );

      expect(_describe(result), 'answered 200 complete');
      expect(events.last, 'sent');
      expect(events.where((e) => e == 'sent'), hasLength(1));
      final progress = events.where((e) => e != 'sent').map(int.parse).toList();
      for (var i = 1; i < progress.length; i++) {
        expect(progress[i], greaterThan(progress[i - 1]));
      }
      expect(progress.last, data.length);
    });

    test('with sourceAddress 127.0.0.2 the peer sees 127.0.0.2', () async {
      final peer = await _Peer.start(alice);

      final result = await send(
        peer.port,
        body: _chunked(_pattern(10)),
        length: 10,
        sourceAddress: _second,
      );

      expect(_describe(result), 'answered 200 complete');
      expect(peer.connections.single.from, _second);
    });
  });

  group('invalid arguments throw ArgumentError before connecting', () {
    final cases = <String, (Map<String, String>, int)>{
      'a header name with a space': ({'x-nexus bridges': 'v'}, 10),
      'a header name with a colon': ({'x-nexusbridges:a': 'v'}, 10),
      'an empty header name': ({'': 'v'}, 10),
      'a header name with CR LF': ({'x-a\r\nx-b': 'v'}, 10),
      'a header value with CR LF': ({'x-a': 'v\r\nx-injected: 1'}, 10),
      'a header value with a bare LF': ({'x-a': 'v\nx'}, 10),
      'a header value that is not ASCII': ({'x-a': 'informé'}, 10),
      'a header value with a tab': ({'x-a': 'a\tb'}, 10),
      'a header value with DEL': ({'x-a': 'a\x7fb'}, 10),
      'a negative contentLength': (const {}, -1),
    };

    cases.forEach((name, input) {
      test(name, () async {
        final peer = await _TcpPeer.start();
        final signal = AbortSignal();
        var read = false;

        await expectLater(
          postStream(
            address: _loopback,
            port: peer.port,
            path: _path,
            headers: input.$1,
            contentLength: input.$2,
            body: Stream<List<int>>.multi((controller) {
              read = true;
              controller.close();
            }),
            context: bob.clientContext(presentCertificate: true),
            acceptServer: (_) => true,
            abort: signal,
          ),
          throwsArgumentError,
        );
        await Future<void>.delayed(_settle);
        expect(peer.accepted, 0);
        expect(read, isFalse);
        expect(signal.listenerCount, 0);
      });
    });
  });

  group('E47 / RF-169: a broken source', () {
    test('a source that fails after some bytes gives sourceError with the '
        'bytes already sent', () async {
      final peer = await _Peer.start(alice, mode: _Mode.silent);
      var bodySent = 0;

      Stream<List<int>> broken() async* {
        yield _pattern(10);
        await Future<void>.delayed(const Duration(milliseconds: 50));
        throw const FileSystemException('unreadable');
      }

      final result = await send(
        peer.port,
        body: broken(),
        length: 100,
        onBodySent: () => bodySent++,
      );

      expect(_describe(result), 'failed sourceError');
      expect((result as StreamPostFailed).sent, 10);
      expect(bodySent, 0);
      await (await peer.firstConnection.timeout(_wait)).closed
          .timeout(_oneSecond);
    });

    test(
      'a source that fails before any byte gives sourceError with 0 sent',
      () async {
        final peer = await _Peer.start(alice, mode: _Mode.silent);

        final result = await send(
          peer.port,
          body: Stream<List<int>>.error(const FileSystemException('gone')),
          length: 100,
        );

        expect(_describe(result), 'failed sourceError');
        expect((result as StreamPostFailed).sent, 0);
      },
    );

    test('a source shorter than contentLength gives sourceError and never '
        'onBodySent', () async {
      final peer = await _Peer.start(alice, mode: _Mode.silent);
      var bodySent = 0;

      final result = await send(
        peer.port,
        body: _chunked(_pattern(50)),
        length: 100,
        onBodySent: () => bodySent++,
      );

      expect(_describe(result), 'failed sourceError');
      expect((result as StreamPostFailed).sent, 50);
      expect(bodySent, 0);
    });

    test('[SEG] RF-165: a chunk that would pass contentLength gives '
        'sourceError and is never written', () async {
      final peer = await _Peer.start(alice, mode: _Mode.silent);

      Stream<List<int>> growing() async* {
        yield _pattern(600, seed: 1);
        await Future<void>.delayed(const Duration(milliseconds: 300));
        yield _pattern(600, seed: 2);
      }

      final result = await send(peer.port, body: growing(), length: 1000);

      expect(_describe(result), 'failed sourceError');
      expect((result as StreamPostFailed).sent, 600);
      final connection = await peer.firstConnection.timeout(_wait);
      await connection.closed.timeout(_oneSecond);
      expect(connection.bodyLength, 600);
      expect(connection.body, orderedEquals(_pattern(600, seed: 1)));
    });

    test('[SEG] RF-165: a first chunk already larger than contentLength '
        'gives sourceError with nothing sent', () async {
      final peer = await _Peer.start(alice, mode: _Mode.silent);

      final result = await send(
        peer.port,
        body: Stream<List<int>>.value(_pattern(1001)),
        length: 1000,
      );

      expect(_describe(result), 'failed sourceError');
      expect((result as StreamPostFailed).sent, 0);
      await Future<void>.delayed(_settle);
      expect(peer.connections.every((c) => c.bodyLength == 0), isTrue);
    });
  });

  group('E48 / RF-167: a stalled upload', () {
    test(
      'a server that does not read gives stalled after idleTimeout',
      () async {
        final peer = await _Peer.start(alice, mode: _Mode.stall);
        var bodySent = 0;
        final stopwatch = Stopwatch()..start();

        final result = await send(
          peer.port,
          body: _endless(),
          length: 1 << 40,
          idle: const Duration(milliseconds: 300),
          onBodySent: () => bodySent++,
        );

        expect(_describe(result), 'failed stalled');
        expect((result as StreamPostFailed).sent, lessThan(1 << 40));
        expect(bodySent, 0);
        expect(stopwatch.elapsed, lessThan(_wait));
      },
    );

    test('control: a slow source that keeps writing before idleTimeout is '
        'not stalled', () async {
      final peer = await _Peer.start(alice);

      final result = await send(
        peer.port,
        body: _slow(10, const Duration(milliseconds: 100)),
        length: 100,
        idle: const Duration(milliseconds: 600),
      );

      expect(_describe(result), 'answered 200 complete');
    });
  });

  group('E210: only body bytes sent keep the upload alive (plan point 74)', () {
    test('a server that drips answer bytes while not reading does not keep a '
        'stalled upload alive', () async {
      const idle = Duration(milliseconds: 400);
      final peer = await _Peer.start(alice, mode: _Mode.stall);
      final clock = Stopwatch()..start();
      var lastProgress = Duration.zero;
      final pending = send(
        peer.port,
        body: _endless(),
        length: 1 << 40,
        idle: idle,
        answer: const Duration(seconds: 30),
        onProgress: (_) => lastProgress = clock.elapsed,
      );
      final connection = await peer.firstConnection.timeout(_wait);
      final drip = utf8.encode('HTTP/1.1 200 Reply\r\nx-drip: ${'a' * 400}');
      final dripped = <Duration>[];
      final timer = Timer.periodic(idle ~/ 2, (_) {
        if (dripped.length >= drip.length) return;
        try {
          connection.socket.add([drip[dripped.length]]);
          dripped.add(clock.elapsed);
        } on Object {
          return;
        }
      });
      addTearDown(timer.cancel);

      final result = await pending.timeout(const Duration(seconds: 15));
      final at = clock.elapsed;
      timer.cancel();

      expect(_describe(result), 'failed stalled');
      expect((result as StreamPostFailed).sent, greaterThan(0));
      expect(
        at - lastProgress,
        greaterThanOrEqualTo(idle - const Duration(milliseconds: 50)),
      );
      expect(at - lastProgress, lessThan(idle + const Duration(seconds: 1)));
      expect(
        dripped.where((t) => t > lastProgress && t < at),
        isNotEmpty,
        reason: 'answer bytes arrived after the last body byte',
      );
    });

    test('body bytes that keep coming still reset the timer', () async {
      const idle = Duration(milliseconds: 400);
      final peer = await _Peer.start(alice);
      final stopwatch = Stopwatch()..start();

      final result = await send(
        peer.port,
        body: _slow(8, idle ~/ 2),
        length: 80,
        idle: idle,
      );

      expect(_describe(result), 'answered 200 complete');
      expect(stopwatch.elapsed, greaterThan(idle * 2));
    });
  });

  group('E49 / RF-225: no answer after the last byte', () {
    test('a server that reads everything and stays silent gives noAnswer '
        'after answerTimeout, with onBodySent called once', () async {
      final peer = await _Peer.start(alice, mode: _Mode.silent);
      var bodySent = 0;
      final stopwatch = Stopwatch()..start();

      final result = await send(
        peer.port,
        body: _chunked(_pattern(1000)),
        length: 1000,
        answer: const Duration(milliseconds: 300),
        onBodySent: () => bodySent++,
      );

      expect(_describe(result), 'failed noAnswer');
      expect((result as StreamPostFailed).sent, 1000);
      expect(bodySent, 1);
      expect(
        stopwatch.elapsed,
        greaterThanOrEqualTo(const Duration(milliseconds: 280)),
      );
      expect(stopwatch.elapsed, lessThan(_wait));
      await (await peer.firstConnection.timeout(_wait)).closed
          .timeout(_oneSecond);
    });

    test(
      'the idle timer does not run after the last byte: a short '
      'idleTimeout with a longer answerTimeout still gets the answer',
      () async {
        final peer = await _Peer.start(alice, mode: _Mode.silent);
        final pending = send(
          peer.port,
          body: _chunked(_pattern(10)),
          length: 10,
          idle: const Duration(milliseconds: 100),
          answer: const Duration(seconds: 3),
        );
        final connection = await peer.firstConnection.timeout(_wait);
        while (!connection.complete) {
          await Future<void>.delayed(const Duration(milliseconds: 10));
        }
        await Future<void>.delayed(const Duration(milliseconds: 400));
        connection.socket.add(_reply(200, utf8.encode('{}')));

        expect(_describe(await pending), 'answered 200 complete');
      },
    );
  });

  group('E50 / RF-139 [SEG]: the server fingerprint is pinned', () {
    test('a server with another fingerprint gives notConnected and receives '
        'no HTTP byte', () async {
      final peer = await _Peer.start(carol);

      final result = await send(
        peer.port,
        body: _chunked(_pattern(100)),
        length: 100,
      );

      expect(_describe(result), 'failed notConnected');
      expect((result as StreamPostFailed).sent, 0);
      await Future<void>.delayed(_settle);
      expect(peer.connections.every((c) => c.received.isEmpty), isTrue);
    });

    test('an acceptServer that throws gives notConnected', () async {
      final peer = await _Peer.start(alice);

      final result = await send(
        peer.port,
        body: _chunked(_pattern(100)),
        length: 100,
        acceptServer: (_) => throw StateError('check failed'),
      );

      expect(_describe(result), 'failed notConnected');
      await Future<void>.delayed(_settle);
      expect(peer.connections.every((c) => c.received.isEmpty), isTrue);
    });

    test('the pin is checked again after the handshake: accepting only '
        'inside the handshake gives notConnected', () async {
      final peer = await _Peer.start(alice);

      final result = await send(
        peer.port,
        body: _chunked(_pattern(100)),
        length: 100,
        acceptServer: (_) => _calledByTls(),
      );

      expect(_describe(result), 'failed notConnected');
      await Future<void>.delayed(_settle);
      expect(peer.connections.every((c) => c.received.isEmpty), isTrue);
    });

    test('a closed port gives notConnected quickly', () async {
      final probe = await ServerSocket.bind(_loopback, 0);
      final port = probe.port;
      await probe.close();
      final stopwatch = Stopwatch()..start();

      final result = await send(port, body: _chunked(_pattern(1)), length: 1);

      expect(_describe(result), 'failed notConnected');
      expect(stopwatch.elapsed, lessThan(const Duration(seconds: 3)));
    });

    test('a TCP server that never completes TLS gives notConnected at '
        'connectTimeout', () async {
      final peer = await _TcpPeer.start();
      final stopwatch = Stopwatch()..start();

      final result = await send(
        peer.port,
        body: _chunked(_pattern(1)),
        length: 1,
        connectTimeout: const Duration(milliseconds: 300),
      );

      expect(_describe(result), 'failed notConnected');
      expect(stopwatch.elapsed, lessThan(const Duration(seconds: 2)));
      expect(peer.accepted, 1);
    });
  });

  group('E51 / RF-183: abort', () {
    test(
      'aborting in the middle gives aborted and closes the socket',
      () async {
        final peer = await _Peer.start(alice, mode: _Mode.silent);
        final signal = AbortSignal();

        final pending = send(
          peer.port,
          body: _slow(100, const Duration(milliseconds: 20)),
          length: 1000,
          abort: signal,
        );
        final connection = await peer.firstConnection.timeout(_wait);
        while (connection.bodyLength < 50) {
          await Future<void>.delayed(const Duration(milliseconds: 10));
        }
        signal.abort();
        final result = await pending;

        expect(_describe(result), 'failed aborted');
        expect((result as StreamPostFailed).sent, lessThan(1000));
        await connection.closed.timeout(_oneSecond);
        expect(signal.listenerCount, 0);
      },
    );

    test('an already aborted signal gives aborted without opening the TCP '
        'connection', () async {
      final peer = await _TcpPeer.start();
      final signal = AbortSignal()..abort();

      final result = await send(
        peer.port,
        body: _chunked(_pattern(10)),
        length: 10,
        abort: signal,
      );

      expect(_describe(result), 'failed aborted');
      await Future<void>.delayed(_settle);
      expect(peer.accepted, 0);
      expect(signal.listenerCount, 0);
    });

    test('aborting during a hung handshake gives aborted within 1 s', () async {
      final peer = await _TcpPeer.start();
      final signal = AbortSignal();
      final pending = send(
        peer.port,
        body: _chunked(_pattern(10)),
        length: 10,
        connectTimeout: const Duration(seconds: 10),
        abort: signal,
      );
      while (peer.accepted == 0) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      final stopwatch = Stopwatch()..start();
      signal.abort();

      expect(_describe(await pending), 'failed aborted');
      expect(stopwatch.elapsed, lessThan(_oneSecond));
      expect(signal.listenerCount, 0);
    });

    test(
      'a finished upload leaves no listener and a later abort is harmless',
      () async {
        final peer = await _Peer.start(alice);
        final signal = AbortSignal();

        final result = await send(
          peer.port,
          body: _chunked(_pattern(10)),
          length: 10,
          abort: signal,
        );

        expect(_describe(result), 'answered 200 complete');
        expect(signal.listenerCount, 0);
        expect(signal.abort, returnsNormally);
      },
    );
  });

  group('answers and broken answers', () {
    test('an answer that arrives before the whole body gives Answered with '
        'bodyComplete false and stops sending', () async {
      final peer = await _Peer.start(
        alice,
        mode: _Mode.answerAtHead,
        answer: _reply(409, utf8.encode('{"error":"busy"}')),
      );
      var bodySent = 0;

      final result = await send(
        peer.port,
        body: _endless(),
        length: 1 << 40,
        onBodySent: () => bodySent++,
      );

      expect(_describe(result), 'answered 409 partial');
      expect(
        utf8.decode((result as StreamPostAnswered).response.body),
        '{"error":"busy"}',
      );
      expect(bodySent, 0);
    });

    test(
      'a server that closes without answering gives connectionLost',
      () async {
        final peer = await _Peer.start(alice, mode: _Mode.closeAtHead);

        final result = await send(
          peer.port,
          body: _chunked(_pattern(4 * _mib)),
          length: 4 * _mib,
        );

        expect(_describe(result), 'failed connectionLost');
      },
    );

    final broken = <String, List<int>>{
      'a garbage status line': _reply(
        200,
        utf8.encode('{}'),
        statusLine: 'garbage',
      ),
      'a 100 Continue': _reply(100, utf8.encode('{}')),
      'a status of 600': _reply(600, utf8.encode('{}')),
      'Transfer-Encoding chunked': _reply(
        200,
        utf8.encode('{}'),
        headers: {'transfer-encoding': 'chunked'},
      ),
      'no Content-Length': _reply(
        200,
        utf8.encode('{}'),
        lengthValues: const [],
      ),
      'two Content-Length': _reply(
        200,
        utf8.encode('{}'),
        lengthValues: const ['2', '2'],
      ),
      'a body over maxResponseBytes': _reply(
        200,
        List<int>.filled(Limits.maxTransferBodyBytes + 1, 0x61),
      ),
      'a Content-Length larger than what arrives': _reply(
        200,
        utf8.encode('{}'),
        lengthValues: const ['50'],
      ),
      'headers over 8 KiB': _reply(
        200,
        utf8.encode('{}'),
        headers: {'x-filler': 'a' * (Limits.maxHeaderBytes + 10)},
      ),
    };

    broken.forEach((name, answer) {
      test('$name gives connectionLost', () async {
        final peer = await _Peer.start(alice, answer: answer);

        final result = await send(
          peer.port,
          body: _chunked(_pattern(100)),
          length: 100,
        );

        expect(_describe(result), 'failed connectionLost');
      });
    });

    test('control: a body of exactly maxResponseBytes is read', () async {
      final peer = await _Peer.start(
        alice,
        answer: _reply(
          200,
          List<int>.filled(Limits.maxTransferBodyBytes, 0x61),
        ),
      );

      final result = await send(
        peer.port,
        body: _chunked(_pattern(100)),
        length: 100,
      );

      expect(_describe(result), 'answered 200 complete');
      expect(
        (result as StreamPostAnswered).response.body,
        hasLength(Limits.maxTransferBodyBytes),
      );
    });

    for (final status in [200, 403, 413, 507, 599]) {
      test('status $status comes back with its body', () async {
        final peer = await _Peer.start(
          alice,
          answer: _reply(status, utf8.encode('{"s":$status}')),
        );

        final result = await send(
          peer.port,
          body: _chunked(_pattern(100)),
          length: 100,
        );

        expect(_describe(result), 'answered $status complete');
        expect(
          utf8.decode((result as StreamPostAnswered).response.body),
          '{"s":$status}',
        );
      });
    }
  });

  group('callbacks', () {
    test(
      'onProgress and onBodySent that throw do not break the upload',
      () async {
        final peer = await _Peer.start(alice);

        final result = await send(
          peer.port,
          body: _chunked(_pattern(1000)),
          length: 1000,
          onProgress: (_) => throw StateError('progress'),
          onBodySent: () => throw StateError('sent'),
        );

        expect(_describe(result), 'answered 200 complete');
      },
    );
  });
}
