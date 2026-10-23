import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import '../identity/identity.dart';
import '../network/network.dart';
import '../pairing/pairing.dart';
import '../protocol/protocol.dart';
import 'filtered_secure_server_socket.dart';
import 'rate_limiter.dart';

void _noLog(String message) {}

const Duration _registerWindow = Duration(minutes: 1);

const Duration _bodyGrace = Duration(milliseconds: 500);

enum RouteDecision { register, unauthorized, notFound, methodNotAllowed }

RouteDecision decideRoute({
  required String method,
  required String path,
  required String? clientFingerprint,
  required bool Function(String) isPaired,
}) {
  if (clientFingerprint != null && !isPaired(clientFingerprint)) {
    return RouteDecision.unauthorized;
  }
  if (path == '$apiPrefix/register') {
    return method == 'POST'
        ? RouteDecision.register
        : RouteDecision.methodNotAllowed;
  }
  if (clientFingerprint == null) return RouteDecision.unauthorized;
  return RouteDecision.notFound;
}

enum _Failure {
  badRequest(HttpStatus.badRequest, 'bad_request'),
  unauthorized(HttpStatus.unauthorized, 'unauthorized'),
  notFound(HttpStatus.notFound, 'not_found'),
  methodNotAllowed(HttpStatus.methodNotAllowed, 'method_not_allowed'),
  payloadTooLarge(HttpStatus.requestEntityTooLarge, 'payload_too_large'),
  rateLimited(429, 'rate_limited'),
  headersTooLarge(431, 'headers_too_large');

  const _Failure(this.status, this.code);

  final int status;

  final String code;
}

final class _RequestBody {
  _RequestBody(HttpRequest request) {
    _subscription = request.listen(
      (_) {},
      onError: (Object _) => _finish(),
      onDone: _finish,
    );
  }

  late final StreamSubscription<Uint8List> _subscription;

  final Completer<void> _finished = Completer<void>();

  Future<void> get finished => _finished.future;

  void _finish() {
    if (!_finished.isCompleted) _finished.complete();
  }

  Future<Uint8List?> read() {
    final builder = BytesBuilder(copy: false);
    final result = Completer<Uint8List?>();
    _subscription
      ..onData((chunk) {
        if (result.isCompleted) return;
        if (builder.length + chunk.length > Limits.maxBodyBytes) {
          result.complete(null);
          return;
        }
        builder.add(chunk);
      })
      ..onDone(() {
        _finish();
        if (!result.isCompleted) result.complete(builder.takeBytes());
      })
      ..onError((Object e) {
        _finish();
        if (!result.isCompleted) result.completeError(e);
      });
    return result.future;
  }
}

final class _Listener {
  _Listener(this.iface, this.socket, this.server);

  ActiveInterface iface;

  final FilteredSecureServerSocket socket;

  final HttpServer server;

  Future<void> close() async {
    await server.close(force: true);
    await socket.close();
  }
}

final class ApiServer {
  ApiServer({
    required this.identity,
    required this.paired,
    required this._selfInfo,
    required this._onRegistered,
    this._port = defaultPort,
    this._now = DateTime.now,
    this._log = _noLog,
  });

  final DeviceIdentity identity;

  final PairedDevicesStore paired;

  final DeviceInfo Function() _selfInfo;

  final void Function(
    DeviceInfo caller,
    InternetAddress from,
    ActiveInterface via,
  )
  _onRegistered;

  final int _port;

  final DateTime Function() _now;

  final void Function(String) _log;

  late final RateLimiter _limiter = RateLimiter(
    maxPerWindow: Limits.registerPerMinute,
    window: _registerWindow,
    block: Limits.registerBlock,
    now: _now,
  );

  final Map<String, _Listener> _listeners = {};

  SecurityContext? _context;

  Future<void> _tail = Future<void>.value();

  bool _closed = false;

  int? get boundPort =>
      _listeners.values.isEmpty ? null : _listeners.values.first.socket.port;

  Set<String> get openInterfaceIds => Set.unmodifiable(_listeners.keys);

  Future<void> syncInterfaces(List<ActiveInterface> active) {
    return _exclusive(() async {
      if (_closed) return;
      final wanted = {for (final iface in active) iface.id: iface};
      final stale = [
        for (final entry in _listeners.entries)
          if (wanted[entry.key]?.subnet != entry.value.iface.subnet) entry.key,
      ];
      for (final id in stale) {
        await _listeners.remove(id)!.close();
      }
      for (final entry in _listeners.entries) {
        final current = wanted[entry.key]!;
        if (current.friendlyName != entry.value.iface.friendlyName) {
          entry.value.iface = current;
        }
      }
      final missing = [
        for (final iface in wanted.values)
          if (!_listeners.containsKey(iface.id)) (iface, _port),
      ];
      if (missing.isEmpty) return;
      final context = await _contextOrCloseAll();
      await _openAll(missing, context);
    });
  }

  Future<void> rebuildTrust() {
    return _exclusive(() async {
      if (_closed) return;
      final targets = [
        for (final listener in _listeners.values)
          (listener.iface, listener.socket.port),
      ];
      final SecurityContext context;
      try {
        context = _buildContext();
      } catch (e) {
        _log('trust context failed: ${e.runtimeType}');
        await _closeAll();
        _context = null;
        rethrow;
      }
      await _closeAll();
      _context = context;
      await _openAll(targets, context);
    });
  }

  Future<void> close() {
    _closed = true;
    return _exclusive(_closeAll);
  }

  Future<void> _closeAll() async {
    final previous = _listeners.values.toList();
    _listeners.clear();
    for (final listener in previous) {
      await listener.close();
    }
  }

  Future<SecurityContext> _contextOrCloseAll() async {
    final existing = _context;
    if (existing != null) return existing;
    try {
      return _context = _buildContext();
    } catch (e) {
      _log('trust context failed: ${e.runtimeType}');
      await _closeAll();
      rethrow;
    }
  }

  Future<void> _exclusive(Future<void> Function() action) {
    final run = _tail.then((_) => action());
    _tail = run.then((_) {}, onError: (Object _) {});
    return run;
  }

  SecurityContext _buildContext() {
    return identity.serverContext(
      trustedCertificatesPem: paired.devices.map((d) => d.certificatePem),
    );
  }

  Future<void> _openAll(
    List<(ActiveInterface, int)> targets,
    SecurityContext context,
  ) async {
    final opened = <String>[];
    for (final (iface, port) in targets) {
      try {
        _listeners[iface.id] = await _open(iface, port, context);
        opened.add(iface.id);
      } on PortInUseException {
        for (final id in opened) {
          await _listeners.remove(id)!.close();
        }
        rethrow;
      } catch (e) {
        _log('interface bind failed: ${e.runtimeType}');
      }
    }
  }

  Future<_Listener> _open(
    ActiveInterface iface,
    int port,
    SecurityContext context,
  ) async {
    final socket = await FilteredSecureServerSocket.bind(
      address: iface.subnet.address,
      port: port,
      context: context,
      allowOrigin: (remote) => originAllowed(remote, iface.subnet),
      deadline: Limits.requestTimeout,
    );
    final server = HttpServer.listenOn(socket);
    final listener = _Listener(iface, socket, server);
    server.listen(
      (request) => unawaited(_handle(request, listener)),
      onError: (Object e) => _log('listener error: ${e.runtimeType}'),
    );
    _log('listening on ${iface.id}');
    return listener;
  }

  Future<void> _handle(HttpRequest request, _Listener listener) async {
    final info = request.connectionInfo;
    final body = _RequestBody(request);
    try {
      if (info == null) {
        await _fail(request, body, _Failure.badRequest);
        return;
      }
      await _serve(request, body, listener, info);
      listener.socket.requestFinished(
        '${info.remoteAddress.address}:${info.remotePort}',
      );
    } catch (e) {
      _log('request failed: ${e.runtimeType}');
    }
  }

  Future<void> _serve(
    HttpRequest request,
    _RequestBody body,
    _Listener listener,
    HttpConnectionInfo info,
  ) async {
    if (_headerBytes(request) > Limits.maxHeaderBytes) {
      await _fail(request, body, _Failure.headersTooLarge);
      return;
    }
    final certificate = request.certificate;
    final String? fingerprint;
    try {
      fingerprint = certificate == null
          ? null
          : fingerprintOfCertificate(certificate.der);
    } catch (_) {
      await _fail(request, body, _Failure.unauthorized);
      return;
    }
    final decision = decideRoute(
      method: request.method,
      path: request.uri.path,
      clientFingerprint: fingerprint,
      isPaired: paired.isPaired,
    );
    switch (decision) {
      case RouteDecision.unauthorized:
        await _fail(request, body, _Failure.unauthorized);
      case RouteDecision.notFound:
        await _fail(request, body, _Failure.notFound);
      case RouteDecision.methodNotAllowed:
        await _fail(request, body, _Failure.methodNotAllowed);
      case RouteDecision.register:
        await _register(request, body, listener, info.remoteAddress);
    }
  }

  Future<void> _register(
    HttpRequest request,
    _RequestBody body,
    _Listener listener,
    InternetAddress remote,
  ) async {
    if (!_limiter.allow(remote.address)) {
      await _fail(request, body, _Failure.rateLimited);
      return;
    }
    if (request.contentLength > Limits.maxBodyBytes) {
      await _fail(request, body, _Failure.payloadTooLarge);
      return;
    }
    final bytes = await body.read();
    if (bytes == null) {
      await _fail(request, body, _Failure.payloadTooLarge);
      return;
    }
    final DeviceInfo? caller;
    try {
      caller = DeviceInfo.tryParse(jsonDecode(utf8.decode(bytes)));
    } on FormatException {
      await _fail(request, body, _Failure.badRequest);
      return;
    }
    if (caller == null) {
      await _fail(request, body, _Failure.badRequest);
      return;
    }
    await _respond(request, body, HttpStatus.ok, _selfInfo().toJson());
    try {
      _onRegistered(caller, remote, listener.iface);
    } catch (e) {
      _log('registration callback failed: ${e.runtimeType}');
    }
  }

  int _headerBytes(HttpRequest request) {
    var total = request.method.length + request.uri.toString().length;
    request.headers.forEach((name, values) {
      for (final value in values) {
        total += name.length + value.length;
      }
    });
    return total;
  }

  Future<void> _fail(HttpRequest request, _RequestBody body, _Failure failure) {
    return _respond(request, body, failure.status, {'error': failure.code});
  }

  Future<void> _respond(
    HttpRequest request,
    _RequestBody body,
    int status,
    Map<String, Object?> payload,
  ) async {
    final bytes = utf8.encode(jsonEncode(payload));
    final response = request.response
      ..persistentConnection = false
      ..statusCode = status
      ..headers.set(
        HttpHeaders.contentTypeHeader,
        'application/json; charset=utf-8',
      )
      ..contentLength = bytes.length
      ..add(bytes);
    try {
      await response.flush();
      await body.finished.timeout(_bodyGrace, onTimeout: () {});
      await response.close();
    } catch (e) {
      _log('response failed: ${e.runtimeType}');
    }
  }
}
