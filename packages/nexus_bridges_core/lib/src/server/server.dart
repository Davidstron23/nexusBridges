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

enum RouteAccess { anonymous, paired }

final class RouteLimit {
  const RouteLimit({
    required this.maxPerWindow,
    required this.window,
    required this.block,
  });

  final int maxPerWindow;

  final Duration window;

  final Duration block;
}

final class ApiCall {
  const ApiCall({
    required this.path,
    required this.clientFingerprint,
    required this.remoteAddress,
    required this.via,
    required this.json,
  });

  final String path;

  final String? clientFingerprint;

  final InternetAddress remoteAddress;

  final ActiveInterface via;

  final Object? json;
}

final class ApiReply {
  const ApiReply(this.status, this.json, {this.afterResponse});

  final int status;

  final Map<String, Object?> json;

  final FutureOr<void> Function()? afterResponse;
}

final class ApiRoute {
  const ApiRoute({
    required this.path,
    required this.access,
    required this.handle,
    this.maxBodyBytes = Limits.maxPairingBodyBytes,
    this.limit,
  });

  final String path;

  final RouteAccess access;

  final Future<ApiReply> Function(ApiCall call) handle;

  final int maxBodyBytes;

  final RouteLimit? limit;
}

enum RouteDecision { register, route, unauthorized, notFound, methodNotAllowed }

RouteDecision decideRoute({
  required String method,
  required String path,
  required String? clientFingerprint,
  required bool Function(String) isPaired,
  Map<String, RouteAccess> routes = const {},
}) {
  if (clientFingerprint != null && !isPaired(clientFingerprint)) {
    return RouteDecision.unauthorized;
  }
  if (path == ApiPaths.register) {
    return method == 'POST'
        ? RouteDecision.register
        : RouteDecision.methodNotAllowed;
  }
  final access = routes[path];
  if (access == RouteAccess.anonymous) {
    return method == 'POST'
        ? RouteDecision.route
        : RouteDecision.methodNotAllowed;
  }
  if (clientFingerprint == null) return RouteDecision.unauthorized;
  if (access == RouteAccess.paired) {
    return method == 'POST'
        ? RouteDecision.route
        : RouteDecision.methodNotAllowed;
  }
  return RouteDecision.notFound;
}

enum _Failure {
  badRequest(HttpStatus.badRequest, 'bad_request'),
  unauthorized(HttpStatus.unauthorized, 'unauthorized'),
  notFound(HttpStatus.notFound, 'not_found'),
  methodNotAllowed(HttpStatus.methodNotAllowed, 'method_not_allowed'),
  payloadTooLarge(HttpStatus.requestEntityTooLarge, 'payload_too_large'),
  rateLimited(429, 'rate_limited'),
  headersTooLarge(431, 'headers_too_large'),
  internal(HttpStatus.internalServerError, 'internal');

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

  Future<Uint8List?> read({required int max}) {
    final builder = BytesBuilder(copy: false);
    final result = Completer<Uint8List?>();
    _subscription
      ..onData((chunk) {
        if (result.isCompleted) return;
        if (builder.length + chunk.length > max) {
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
    List<ApiRoute> routes = const [],
    this._port = defaultPort,
    this._now = DateTime.now,
    this._log = _noLog,
  }) : routes = _checkedRoutes(routes);

  final DeviceIdentity identity;

  final List<ApiRoute> routes;

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

  late final Map<String, ApiRoute> _routesByPath = {
    for (final route in routes) route.path: route,
  };

  late final Map<String, RouteAccess> _routeAccess = {
    for (final route in routes) route.path: route.access,
  };

  late final Map<String, RateLimiter> _routeLimiters = {
    for (final route in routes)
      if (route.limit case final limit?)
        route.path: RateLimiter(
          maxPerWindow: limit.maxPerWindow,
          window: limit.window,
          block: limit.block,
          now: _now,
        ),
  };

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
      final SecurityContext context;
      try {
        context = _buildContext();
      } catch (e) {
        _log('trust context failed: ${e.runtimeType}');
        await _closeAll();
        _context = null;
        rethrow;
      }
      _context = context;
      for (final listener in _listeners.values) {
        listener.socket.context = context;
        listener.socket.dropConnections(_isUntrusted);
      }
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

  bool _isUntrusted(X509Certificate peer) {
    try {
      return !paired.isPaired(fingerprintOfCertificate(peer.der));
    } catch (_) {
      return true;
    }
  }

  static List<ApiRoute> _checkedRoutes(List<ApiRoute> routes) {
    final seen = <String>{};
    for (final route in routes) {
      final path = route.path;
      if (!path.startsWith('$apiPrefix/')) {
        throw ArgumentError.value(path, 'routes', 'outside the API prefix');
      }
      if (path == ApiPaths.register) {
        throw ArgumentError.value(path, 'routes', 'reserved path');
      }
      if (!seen.add(path)) {
        throw ArgumentError.value(path, 'routes', 'duplicate path');
      }
      if (route.access == RouteAccess.anonymous &&
          !ApiPaths.anonymous.contains(path)) {
        throw ArgumentError.value(path, 'routes', 'not an anonymous path');
      }
    }
    return List.unmodifiable(routes);
  }

  SecurityContext _buildContext() {
    return identity.serverContext(
      trustedCertificatesPem:
          ([...paired.devices]
                ..sort((a, b) => a.pairedAt.compareTo(b.pairedAt)))
              .map((d) => d.certificatePem),
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
      final key = '${info.remoteAddress.address}:${info.remotePort}';
      var released = false;
      void release() {
        if (released) return;
        released = true;
        listener.socket.requestFinished(key);
      }

      await _serve(request, body, listener, info, release);
      release();
    } catch (e) {
      _log('request failed: ${e.runtimeType}');
    }
  }

  Future<void> _serve(
    HttpRequest request,
    _RequestBody body,
    _Listener listener,
    HttpConnectionInfo info,
    void Function() release,
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
      routes: _routeAccess,
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
      case RouteDecision.route:
        await _route(request, body, listener, info, fingerprint, release);
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
    final bytes = await body.read(max: Limits.maxBodyBytes);
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

  Future<void> _route(
    HttpRequest request,
    _RequestBody body,
    _Listener listener,
    HttpConnectionInfo info,
    String? fingerprint,
    void Function() release,
  ) async {
    final route = _routesByPath[request.uri.path]!;
    final remote = info.remoteAddress;
    final limiter = _routeLimiters[route.path];
    if (limiter != null && !limiter.allow(remote.address)) {
      await _fail(request, body, _Failure.rateLimited);
      return;
    }
    if (request.contentLength > route.maxBodyBytes) {
      await _fail(request, body, _Failure.payloadTooLarge);
      return;
    }
    final bytes = await body.read(max: route.maxBodyBytes);
    if (bytes == null) {
      await _fail(request, body, _Failure.payloadTooLarge);
      return;
    }
    final Object? json;
    try {
      json = bytes.isEmpty ? null : jsonDecode(utf8.decode(bytes));
    } on FormatException {
      await _fail(request, body, _Failure.badRequest);
      return;
    }
    final ApiReply reply;
    try {
      reply = await route.handle(
        ApiCall(
          path: route.path,
          clientFingerprint: fingerprint,
          remoteAddress: remote,
          via: listener.iface,
          json: json,
        ),
      );
    } catch (e) {
      _log('route failed: ${e.runtimeType}');
      await _fail(request, body, _Failure.internal);
      return;
    }
    await _respond(request, body, reply.status, reply.json);
    release();
    try {
      await reply.afterResponse?.call();
    } catch (e) {
      _log('after response failed: ${e.runtimeType}');
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
