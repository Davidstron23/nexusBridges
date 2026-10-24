import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import '../protocol/protocol.dart';
import 'transport.dart';

final class _Link {
  ConnectionTask<RawSocket>? task;
  RawSocket? raw;
  RawSecureSocket? secure;
  bool closed = false;
  final Completer<void> _cancelled = Completer<void>();

  Future<void> get cancelled => _cancelled.future;

  void close() {
    closed = true;
    if (!_cancelled.isCompleted) _cancelled.complete();
    _stop(task);
    _shut(secure);
    _shut(raw);
  }

  static void _stop(ConnectionTask<RawSocket>? task) {
    try {
      task?.cancel();
    } catch (_) {
      return;
    }
  }

  static void _shut(RawSocket? socket) {
    try {
      socket?.close().ignore();
    } catch (_) {
      return;
    }
  }
}

Future<HttpsResponse?> postJson({
  required InternetAddress address,
  required int port,
  required String path,
  required Object? json,
  required SecurityContext context,
  required bool Function(X509Certificate certificate) acceptServer,
  InternetAddress? sourceAddress,
  Duration timeout = Limits.requestTimeout,
  int maxResponseBytes = Limits.maxBodyBytes,
  AbortSignal? abort,
}) async {
  if (abort != null && abort.aborted) return null;
  final link = _Link();
  final remove = abort?.onAbort(link.close);
  try {
    return await Future.any<HttpsResponse?>([
      _attempt(
        link,
        address: address,
        port: port,
        path: path,
        json: json,
        context: context,
        acceptServer: acceptServer,
        sourceAddress: sourceAddress,
        maxResponseBytes: maxResponseBytes,
      ),
      link.cancelled.then<HttpsResponse?>((_) => null),
    ]).timeout(timeout);
  } catch (_) {
    return null;
  } finally {
    remove?.call();
    link.close();
  }
}

Future<StreamPostResult> postStream({
  required InternetAddress address,
  required int port,
  required String path,
  required Map<String, String> headers,
  required int contentLength,
  required Stream<List<int>> body,
  required SecurityContext context,
  required bool Function(X509Certificate certificate) acceptServer,
  InternetAddress? sourceAddress,
  Duration connectTimeout = Limits.requestTimeout,
  Duration idleTimeout = Limits.transferIdleTimeout,
  Duration answerTimeout = Limits.transferConfirmTimeout,
  int maxResponseBytes = Limits.maxTransferBodyBytes,
  void Function(int sent)? onProgress,
  void Function()? onBodySent,
  AbortSignal? abort,
}) async {
  final poster = _StreamPoster(
    head: _streamHeadFor(address, port, path, headers, contentLength),
    contentLength: contentLength,
    body: body,
    idleTimeout: idleTimeout,
    answerTimeout: answerTimeout,
    reader: _ResponseReader(maxResponseBytes),
    onProgress: onProgress,
    onBodySent: onBodySent,
  );
  final remove = abort?.onAbort(() => poster.fail(StreamPostFailure.aborted));
  try {
    if (poster.result.isCompleted) return await poster.result.future;
    final RawSecureSocket? secure;
    try {
      secure = await Future.any<RawSecureSocket?>([
        _open(
          poster.link,
          address: address,
          port: port,
          context: context,
          acceptServer: acceptServer,
          sourceAddress: sourceAddress,
        ),
        poster.link.cancelled.then<RawSecureSocket?>((_) => null),
      ]).timeout(connectTimeout);
    } catch (_) {
      poster.fail(StreamPostFailure.notConnected);
      return await poster.result.future;
    }
    if (secure == null) {
      poster.fail(StreamPostFailure.notConnected);
    } else {
      poster.begin(secure);
    }
    return await poster.result.future;
  } finally {
    remove?.call();
    poster.link.close();
  }
}

final RegExp _headerName = RegExp(r'^[!-9;-~]+$');
final RegExp _headerValue = RegExp(r'^[ -~]*$');

Uint8List _streamHeadFor(
  InternetAddress address,
  int port,
  String path,
  Map<String, String> headers,
  int contentLength,
) {
  if (contentLength < 0) {
    throw ArgumentError.value(contentLength, 'contentLength', 'negative');
  }
  final extra = StringBuffer();
  for (final entry in headers.entries) {
    if (!_headerName.hasMatch(entry.key) ||
        !_headerValue.hasMatch(entry.value)) {
      throw ArgumentError.value(entry.key, 'headers', 'invalid header');
    }
    extra.write('${entry.key}: ${entry.value}\r\n');
  }
  final head =
      'POST $path HTTP/1.1\r\n'
      'Host: ${_hostOf(address)}:$port\r\n'
      'Content-Type: application/octet-stream\r\n'
      'Content-Length: $contentLength\r\n'
      'Connection: close\r\n'
      '$extra'
      '\r\n';
  return Uint8List.fromList(latin1.encode(head));
}

final class _StreamPoster {
  _StreamPoster({
    required this.head,
    required this.contentLength,
    required this.body,
    required this.idleTimeout,
    required this.answerTimeout,
    required this.reader,
    required this.onProgress,
    required this.onBodySent,
  });

  final Uint8List head;

  final int contentLength;

  final Stream<List<int>> body;

  final Duration idleTimeout;

  final Duration answerTimeout;

  final _ResponseReader reader;

  final void Function(int sent)? onProgress;

  final void Function()? onBodySent;

  final _Link link = _Link();

  final Completer<StreamPostResult> result = Completer<StreamPostResult>();

  RawSecureSocket? _socket;

  StreamSubscription<List<int>>? _source;

  Timer? _idleTimer;

  Timer? _answerTimer;

  Uint8List? _out;

  int _outOffset = 0;

  bool _outIsBody = false;

  bool _bodyListening = false;

  bool _bodyDone = false;

  int _sent = 0;

  void begin(RawSecureSocket socket) {
    if (result.isCompleted) return;
    _socket = socket;
    _out = head;
    socket.listen(
      (event) => _guarded(() {
        switch (event) {
          case RawSocketEvent.read:
            _pumpRead();
          case RawSocketEvent.write:
            _writeOut();
          case RawSocketEvent.readClosed:
            _pumpRead();
            fail(StreamPostFailure.connectionLost);
          case RawSocketEvent.closed:
            fail(StreamPostFailure.connectionLost);
        }
      }),
      onError: (Object _) => fail(StreamPostFailure.connectionLost),
      onDone: () => fail(StreamPostFailure.connectionLost),
      cancelOnError: true,
    );
    _resetIdle();
    _guarded(_writeOut);
  }

  void fail(StreamPostFailure failure) =>
      _finish(StreamPostFailed(failure, sent: _sent));

  void _finish(StreamPostResult value) {
    if (result.isCompleted) return;
    result.complete(value);
    _idleTimer?.cancel();
    _answerTimer?.cancel();
    final subscription = _source;
    _source = null;
    if (subscription != null) {
      unawaited(subscription.cancel().catchError((Object _) {}));
    }
    link.close();
  }

  void _guarded(void Function() action) {
    try {
      action();
    } catch (_) {
      fail(StreamPostFailure.connectionLost);
    }
  }

  void _resetIdle() {
    if (_bodyDone || result.isCompleted) return;
    _idleTimer?.cancel();
    _idleTimer = Timer(idleTimeout, () => fail(StreamPostFailure.stalled));
  }

  void _writeOut() {
    final socket = _socket;
    final buffer = _out;
    if (socket == null || buffer == null || result.isCompleted) return;
    while (_outOffset < buffer.length) {
      final written = socket.write(
        buffer,
        _outOffset,
        buffer.length - _outOffset,
      );
      if (written <= 0) {
        socket.writeEventsEnabled = true;
        return;
      }
      _outOffset += written;
      if (_outIsBody) {
        _sent += written;
        _report();
        _resetIdle();
      }
    }
    _out = null;
    socket.writeEventsEnabled = false;
    if (_bodyListening) {
      _source?.resume();
    } else {
      _listenToBody();
    }
  }

  void _report() {
    try {
      onProgress?.call(_sent);
    } catch (_) {
      return;
    }
  }

  void _listenToBody() {
    _bodyListening = true;
    _source = body.listen(
      _onChunk,
      onError: (Object _) => fail(StreamPostFailure.sourceError),
      onDone: _onSourceDone,
      cancelOnError: true,
    );
  }

  void _onChunk(List<int> chunk) {
    if (result.isCompleted || chunk.isEmpty) return;
    if (_sent + chunk.length > contentLength) {
      fail(StreamPostFailure.sourceError);
      return;
    }
    _source?.pause();
    _out = chunk is Uint8List ? chunk : Uint8List.fromList(chunk);
    _outOffset = 0;
    _outIsBody = true;
    _guarded(_writeOut);
  }

  void _onSourceDone() {
    if (result.isCompleted) return;
    if (_sent != contentLength) {
      fail(StreamPostFailure.sourceError);
      return;
    }
    _bodyDone = true;
    _idleTimer?.cancel();
    _announceBodySent();
    if (result.isCompleted) return;
    _answerTimer = Timer(answerTimeout, () => fail(StreamPostFailure.noAnswer));
  }

  void _announceBodySent() {
    try {
      onBodySent?.call();
    } catch (_) {
      return;
    }
  }

  void _pumpRead() {
    final socket = _socket!;
    while (!result.isCompleted) {
      final chunk = socket.read();
      if (chunk == null) return;
      reader.add(chunk);
      if (!reader.done) continue;
      final response = reader.response;
      if (response == null) {
        fail(StreamPostFailure.connectionLost);
      } else {
        _finish(
          StreamPostAnswered(response, bodyComplete: _sent == contentLength),
        );
      }
    }
  }
}

Future<HttpsResponse?> _attempt(
  _Link link, {
  required InternetAddress address,
  required int port,
  required String path,
  required Object? json,
  required SecurityContext context,
  required bool Function(X509Certificate certificate) acceptServer,
  required InternetAddress? sourceAddress,
  required int maxResponseBytes,
}) async {
  final request = _requestFor(address, port, path, jsonEncode(json));
  final secure = await _open(
    link,
    address: address,
    port: port,
    context: context,
    acceptServer: acceptServer,
    sourceAddress: sourceAddress,
  );
  if (secure == null) return null;
  return _converse(secure, request, maxResponseBytes);
}

Future<RawSecureSocket?> _open(
  _Link link, {
  required InternetAddress address,
  required int port,
  required SecurityContext context,
  required bool Function(X509Certificate certificate) acceptServer,
  required InternetAddress? sourceAddress,
}) async {
  final task = await RawSocket.startConnect(
    address,
    port,
    sourceAddress: sourceAddress,
  );
  final connecting = task.socket;
  connecting.ignore();
  link.task = task;
  if (link.closed) {
    link.close();
    return null;
  }
  final raw = await connecting;
  link.raw = raw;
  if (link.closed) {
    link.close();
    return null;
  }

  final pending = RawSecureSocket.secure(
    raw,
    context: context,
    onBadCertificate: acceptServer,
  );
  pending.ignore();
  final secure = await pending;
  link.secure = secure;
  if (link.closed || !_pinnedPeer(secure, acceptServer)) {
    link.close();
    return null;
  }
  return secure;
}

bool _pinnedPeer(
  RawSecureSocket secure,
  bool Function(X509Certificate certificate) acceptServer,
) {
  try {
    final peer = secure.peerCertificate;
    return peer != null && acceptServer(peer);
  } catch (_) {
    return false;
  }
}

String _hostOf(InternetAddress address) =>
    address.type == InternetAddressType.IPv6
    ? '[${address.address}]'
    : address.address;

Uint8List _requestFor(
  InternetAddress address,
  int port,
  String path,
  String json,
) {
  final payload = utf8.encode(json);
  final head =
      'POST $path HTTP/1.1\r\n'
      'Host: ${_hostOf(address)}:$port\r\n'
      'Content-Type: application/json; charset=utf-8\r\n'
      'Content-Length: ${payload.length}\r\n'
      'Connection: close\r\n'
      '\r\n';
  return (BytesBuilder(copy: false)
        ..add(utf8.encode(head))
        ..add(payload))
      .takeBytes();
}

Future<HttpsResponse?> _converse(
  RawSecureSocket socket,
  Uint8List request,
  int maxResponseBytes,
) {
  final result = Completer<HttpsResponse?>();
  final reader = _ResponseReader(maxResponseBytes);
  var written = 0;

  void finish(HttpsResponse? value) {
    if (!result.isCompleted) result.complete(value);
  }

  void pump() {
    for (
      var chunk = socket.read();
      chunk != null && !result.isCompleted;
      chunk = socket.read()
    ) {
      reader.add(chunk);
      if (reader.done) finish(reader.response);
    }
  }

  void send() {
    if (written < request.length) {
      written += socket.write(request, written, request.length - written);
    }
    socket.writeEventsEnabled = written < request.length;
  }

  void guarded(void Function() action) {
    try {
      action();
    } catch (_) {
      finish(null);
    }
  }

  socket.listen(
    (event) => guarded(() {
      switch (event) {
        case RawSocketEvent.read:
          pump();
        case RawSocketEvent.write:
          send();
        case RawSocketEvent.readClosed:
          guarded(pump);
          finish(null);
        case RawSocketEvent.closed:
          finish(null);
      }
    }),
    onError: (Object _) => finish(null),
    onDone: () => finish(null),
    cancelOnError: true,
  );
  guarded(send);
  return result.future;
}

final class _ResponseReader {
  _ResponseReader(this._maxResponseBytes);

  final int _maxResponseBytes;

  Uint8List _head = Uint8List(1024);
  int _headFilled = 0;
  int _headScanned = 0;
  Uint8List? _body;
  int _status = 0;
  int _bodyFilled = 0;
  bool _done = false;
  HttpsResponse? _response;

  bool get done => _done;

  HttpsResponse? get response => _response;

  void add(Uint8List chunk) {
    if (_done) return;
    if (_body == null) {
      _takeHead(chunk);
    } else {
      _takeBody(chunk, 0, chunk.length);
    }
  }

  void _complete(HttpsResponse? value) {
    if (_done) return;
    _done = true;
    _response = value;
  }

  void _takeBody(Uint8List source, int from, int to) {
    final target = _body!;
    final room = target.length - _bodyFilled;
    final take = to - from < room ? to - from : room;
    if (take > 0) {
      target.setRange(_bodyFilled, _bodyFilled + take, source, from);
      _bodyFilled += take;
    }
    if (_bodyFilled == target.length) _complete(HttpsResponse(_status, target));
  }

  void _takeHead(Uint8List chunk) {
    final needed = _headFilled + chunk.length;
    if (needed > _head.length) {
      final size = _head.length * 2 > needed ? _head.length * 2 : needed;
      _head = Uint8List(size)..setRange(0, _headFilled, _head);
    }
    _head.setRange(_headFilled, needed, chunk);
    _headFilled = needed;
    final end = _headerEnd(_head, _headScanned, _headFilled);
    if (end < 0) {
      _headScanned = _headFilled > 3 ? _headFilled - 3 : 0;
      if (_headFilled > Limits.maxHeaderBytes) _complete(null);
      return;
    }
    if (end > Limits.maxHeaderBytes) {
      _complete(null);
      return;
    }
    final parsed = _bodyLengthOf(
      latin1.decode(Uint8List.sublistView(_head, 0, end)),
      _maxResponseBytes,
    );
    if (parsed == null) {
      _complete(null);
      return;
    }
    _status = parsed.$1;
    _body = Uint8List(parsed.$2);
    _takeBody(_head, end + 4, _headFilled);
  }
}

int _headerEnd(Uint8List bytes, int from, int to) {
  for (var i = from; i + 3 < to; i++) {
    if (bytes[i] == 13 &&
        bytes[i + 1] == 10 &&
        bytes[i + 2] == 13 &&
        bytes[i + 3] == 10) {
      return i;
    }
  }
  return -1;
}

final RegExp _statusLine = RegExp(r'^HTTP/1\.[01] (\d{3})(?: |$)');
final RegExp _digits = RegExp(r'^\d{1,9}$');

(int, int)? _bodyLengthOf(String head, int maxBytes) {
  final lines = head.split('\r\n');
  final match = _statusLine.firstMatch(lines.first);
  if (match == null) return null;
  final status = int.parse(match.group(1)!);
  if (status < 200 || status > 599) return null;
  String? announced;
  for (final line in lines.skip(1)) {
    final colon = line.indexOf(':');
    if (colon <= 0) return null;
    final name = line.substring(0, colon).trim().toLowerCase();
    final value = line.substring(colon + 1).trim();
    if (name == 'transfer-encoding') return null;
    if (name == 'content-length') {
      if (announced != null) return null;
      announced = value;
    }
  }
  if (announced == null || !_digits.hasMatch(announced)) return null;
  final length = int.parse(announced);
  return length > maxBytes ? null : (status, length);
}
