import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import '../identity/identity.dart';
import '../protocol/protocol.dart';

void _noop() {}

final class AbortSignal {
  final List<void Function()> _listeners = [];

  bool _aborted = false;

  bool get aborted => _aborted;

  int get listenerCount => _listeners.length;

  void abort() {
    if (_aborted) return;
    _aborted = true;
    final pending = List<void Function()>.of(_listeners);
    _listeners.clear();
    for (final callback in pending) {
      _run(callback);
    }
  }

  void Function() onAbort(void Function() callback) {
    if (_aborted) {
      _run(callback);
      return _noop;
    }
    _listeners.add(callback);
    return () => _listeners.remove(callback);
  }

  void _run(void Function() callback) {
    try {
      callback();
    } catch (_) {
      return;
    }
  }
}

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

final class DeviceVerifier {
  DeviceVerifier({required this._identity});

  final DeviceIdentity _identity;

  Future<DeviceInfo?> register({
    required InternetAddress address,
    required int port,
    required String? expectedFingerprint,
    required DeviceInfo self,
    Duration timeout = const Duration(seconds: 10),
    AbortSignal? abort,
  }) async {
    if (abort != null && abort.aborted) return null;
    final link = _Link();
    final remove = abort?.onAbort(link.close);
    try {
      return await Future.any<DeviceInfo?>([
        _attempt(
          link,
          address: address,
          port: port,
          expectedFingerprint: expectedFingerprint,
          self: self,
        ),
        link.cancelled.then<DeviceInfo?>((_) => null),
      ]).timeout(timeout);
    } catch (_) {
      return null;
    } finally {
      remove?.call();
      link.close();
    }
  }

  Future<DeviceInfo?> _attempt(
    _Link link, {
    required InternetAddress address,
    required int port,
    required String? expectedFingerprint,
    required DeviceInfo self,
  }) async {
    String? seen;

    final task = await RawSocket.startConnect(address, port);
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
      context: _identity.clientContext(),
      onBadCertificate: (cert) {
        seen = fingerprintOf(cert.der);
        return expectedFingerprint == null || seen == expectedFingerprint;
      },
    );
    pending.ignore();
    final secure = await pending;
    link.secure = secure;
    if (link.closed) {
      link.close();
      return null;
    }

    final body = await _converse(
      secure,
      _requestFor(address, port, jsonEncode(self.toJson())),
    );
    final observed = seen;
    if (body == null || observed == null) return null;
    final info = DeviceInfo.tryParse(jsonDecode(utf8.decode(body)));
    if (info == null || info.fingerprint != observed) return null;
    if (expectedFingerprint != null &&
        info.fingerprint != expectedFingerprint) {
      return null;
    }
    return info;
  }

  Uint8List _requestFor(InternetAddress address, int port, String json) {
    final payload = utf8.encode(json);
    final host = address.type == InternetAddressType.IPv6
        ? '[${address.address}]'
        : address.address;
    final head =
        'POST $apiPrefix/register HTTP/1.1\r\n'
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

  Future<Uint8List?> _converse(RawSecureSocket socket, Uint8List request) {
    final result = Completer<Uint8List?>();
    var head = Uint8List(1024);
    var headFilled = 0;
    var headScanned = 0;
    Uint8List? body;
    var bodyFilled = 0;
    var written = 0;

    void finish(Uint8List? value) {
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
      if (bodyFilled == target.length) finish(target);
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
      final length = _bodyLengthOf(
        latin1.decode(Uint8List.sublistView(head, 0, end)),
      );
      if (length == null) {
        finish(null);
        return;
      }
      body = Uint8List(length);
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

int? _bodyLengthOf(String head) {
  final lines = head.split('\r\n');
  final status = _statusLine.firstMatch(lines.first);
  if (status == null || status.group(1) != '200') return null;
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
  return length > Limits.maxBodyBytes ? null : length;
}
