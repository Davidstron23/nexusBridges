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

  final task = await RawSocket.startConnect(
    address,
    port,
    sourceAddress: sourceAddress,
  );
  link.task = task;
  if (link.closed) {
    link.close();
    return null;
  }
  final connecting = task.socket;
  connecting.ignore();
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
  if (link.closed) {
    link.close();
    return null;
  }

  return _converse(secure, request, maxResponseBytes);
}

Uint8List _requestFor(
  InternetAddress address,
  int port,
  String path,
  String json,
) {
  final payload = utf8.encode(json);
  final host = address.type == InternetAddressType.IPv6
      ? '[${address.address}]'
      : address.address;
  final head =
      'POST $path HTTP/1.1\r\n'
      'Host: $host:$port\r\n'
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
  var head = Uint8List(1024);
  var headFilled = 0;
  var headScanned = 0;
  Uint8List? body;
  var status = 0;
  var bodyFilled = 0;
  var written = 0;

  void finish(HttpsResponse? value) {
    if (!result.isCompleted) result.complete(value);
  }

  void takeBody(Uint8List source, int from, int to) {
    final target = body!;
    final room = target.length - bodyFilled;
    final take = to - from < room ? to - from : room;
    if (take > 0) {
      target.setRange(bodyFilled, bodyFilled + take, source, from);
      bodyFilled += take;
    }
    if (bodyFilled == target.length) finish(HttpsResponse(status, target));
  }

  void takeHead(Uint8List chunk) {
    final needed = headFilled + chunk.length;
    if (needed > head.length) {
      final size = head.length * 2 > needed ? head.length * 2 : needed;
      head = Uint8List(size)..setRange(0, headFilled, head);
    }
    head.setRange(headFilled, needed, chunk);
    headFilled = needed;
    final end = _headerEnd(head, headScanned, headFilled);
    if (end < 0) {
      headScanned = headFilled > 3 ? headFilled - 3 : 0;
      if (headFilled > Limits.maxHeaderBytes) finish(null);
      return;
    }
    if (end > Limits.maxHeaderBytes) {
      finish(null);
      return;
    }
    final parsed = _bodyLengthOf(
      latin1.decode(Uint8List.sublistView(head, 0, end)),
      maxResponseBytes,
    );
    if (parsed == null) {
      finish(null);
      return;
    }
    status = parsed.$1;
    body = Uint8List(parsed.$2);
    takeBody(head, end + 4, headFilled);
  }

  void pump() {
    for (
      var chunk = socket.read();
      chunk != null && !result.isCompleted;
      chunk = socket.read()
    ) {
      if (body == null) {
        takeHead(chunk);
      } else {
        takeBody(chunk, 0, chunk.length);
      }
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
