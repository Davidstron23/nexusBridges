import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import '../protocol/protocol.dart';

const int _addressInUseErrorCode = 10048;

const int _recordHeaderBytes = 5;

const int _maxRecordPayload = 16384 + 256;

const int _handshakeRecordType = 0x16;

const int _tlsMajorVersion = 0x03;

const int _tlsMinorVersionMin = 0x01;

const int _tlsMinorVersionMax = 0x04;

final class _Connection {
  _Connection(this.socket, this.ip);

  final String ip;

  Socket socket;

  Timer? timer;

  StreamSubscription<Uint8List>? subscription;

  final BytesBuilder buffer = BytesBuilder(copy: false);

  final Uint8List header = Uint8List(_recordHeaderBytes);

  int headerFilled = 0;

  int received = 0;

  int expected = 0;

  bool counted = true;

  bool detached = false;
}

final class FilteredSecureServerSocket extends StreamView<Socket>
    implements ServerSocket {
  FilteredSecureServerSocket._(
    this._server,
    this._context,
    this._allowOrigin,
    this._deadline,
    this._controller,
  ) : super(_controller.stream) {
    _controller
      ..onListen = _startAccepting
      ..onPause = (() => _subscription?.pause())
      ..onResume = (() => _subscription?.resume())
      ..onCancel = _stopAccepting;
  }

  static Future<FilteredSecureServerSocket> bind({
    required InternetAddress address,
    required int port,
    required SecurityContext context,
    required bool Function(InternetAddress remote) allowOrigin,
    required Duration deadline,
  }) async {
    final ServerSocket server;
    try {
      server = await ServerSocket.bind(address, port);
    } on SocketException catch (e) {
      if (e.osError?.errorCode == _addressInUseErrorCode) {
        throw PortInUseException(port);
      }
      rethrow;
    }
    return FilteredSecureServerSocket._(
      server,
      context,
      allowOrigin,
      deadline,
      StreamController<Socket>(),
    );
  }

  final ServerSocket _server;

  SecurityContext _context;

  final bool Function(InternetAddress remote) _allowOrigin;

  final Duration _deadline;

  final StreamController<Socket> _controller;

  final Map<String, _Connection> _connections = {};

  final Map<String, int> _pendingByIp = {};

  int _pendingTotal = 0;

  StreamSubscription<Socket>? _subscription;

  bool _closed = false;

  @override
  InternetAddress get address => _server.address;

  @override
  int get port => _server.port;

  set context(SecurityContext value) {
    _context = value;
  }

  int dropConnections(bool Function(X509Certificate peer) shouldDrop) {
    final candidates = [
      for (final entry in _connections.entries)
        if (entry.value.socket is SecureSocket) (entry.key, entry.value),
    ];
    var dropped = 0;
    for (final (key, connection) in candidates) {
      final X509Certificate? peer;
      try {
        peer = (connection.socket as SecureSocket).peerCertificate;
      } catch (_) {
        _discard(key, connection);
        dropped++;
        continue;
      }
      if (peer == null) continue;
      bool drop;
      try {
        drop = shouldDrop(peer);
      } catch (_) {
        drop = true;
      }
      if (!drop) continue;
      _discard(key, connection);
      dropped++;
    }
    return dropped;
  }

  void requestFinished(String connectionKey) {
    _connections.remove(connectionKey)?.timer?.cancel();
  }

  @override
  Future<ServerSocket> close() async {
    if (_closed) return this;
    _closed = true;
    final subscription = _subscription;
    _subscription = null;
    await subscription?.cancel();
    final pending = _connections.values.toList();
    _connections.clear();
    _pendingByIp.clear();
    _pendingTotal = 0;
    for (final connection in pending) {
      connection.counted = false;
      _release(connection);
    }
    await _server.close();
    unawaited(_controller.close());
    return this;
  }

  void _startAccepting() {
    if (_closed || _subscription != null) return;
    _subscription = _server.listen(_accept, onError: (Object _) {});
  }

  Future<void> _stopAccepting() async {
    final subscription = _subscription;
    _subscription = null;
    await subscription?.cancel();
  }

  void _accept(Socket socket) {
    final String key;
    final String ip;
    try {
      final remote = socket.remoteAddress;
      if (_closed || !_allowOrigin(remote)) {
        socket.destroy();
        return;
      }
      ip = remote.address;
      key = '$ip:${socket.remotePort}';
    } catch (_) {
      socket.destroy();
      return;
    }
    if (_pendingTotal >= Limits.maxPendingHandshakes ||
        (_pendingByIp[ip] ?? 0) >= Limits.maxPendingHandshakesPerIp) {
      socket.destroy();
      return;
    }
    final connection = _Connection(socket, ip);
    _pendingTotal++;
    _pendingByIp[ip] = (_pendingByIp[ip] ?? 0) + 1;
    final previous = _connections.remove(key);
    if (previous != null) _release(previous);
    _connections[key] = connection;
    connection.timer = Timer(_deadline, () => _discard(key, connection));
    connection.subscription = socket.listen(
      (block) => _onData(key, connection, block),
      onError: (Object _) => _discard(key, connection),
      onDone: () => _discard(key, connection),
      cancelOnError: true,
    );
  }

  void _onData(String key, _Connection connection, Uint8List block) {
    if (_closed || !identical(_connections[key], connection)) {
      _release(connection);
      return;
    }
    if (!_acceptHeaderBytes(connection, block)) {
      _discard(key, connection);
      return;
    }
    connection.buffer.add(block);
    connection.received += block.length;
    if (connection.headerFilled < _recordHeaderBytes ||
        connection.received < connection.expected) {
      return;
    }
    _beginHandshake(key, connection);
  }

  bool _acceptHeaderBytes(_Connection connection, Uint8List block) {
    var index = 0;
    while (connection.headerFilled < _recordHeaderBytes &&
        index < block.length) {
      connection.header[connection.headerFilled++] = block[index++];
      if (!_headerPrefixIsValid(connection)) return false;
    }
    if (connection.headerFilled == _recordHeaderBytes &&
        connection.expected == 0) {
      connection.expected =
          _recordHeaderBytes +
          ((connection.header[3] << 8) | connection.header[4]);
    }
    return true;
  }

  bool _headerPrefixIsValid(_Connection connection) {
    final header = connection.header;
    switch (connection.headerFilled) {
      case 1:
        return header[0] == _handshakeRecordType;
      case 2:
        return header[1] == _tlsMajorVersion;
      case 3:
        return header[2] >= _tlsMinorVersionMin &&
            header[2] <= _tlsMinorVersionMax;
      case 4:
        return header[3] <= (_maxRecordPayload >> 8);
      case 5:
        final length = (header[3] << 8) | header[4];
        return length > 0 && length <= _maxRecordPayload;
      default:
        return true;
    }
  }

  void _beginHandshake(String key, _Connection connection) {
    connection.subscription?.pause();
    connection.subscription = null;
    connection.detached = true;
    final buffered = connection.buffer.takeBytes();
    SecureSocket.secureServer(
      connection.socket,
      _context,
      bufferedData: buffered,
      requestClientCertificate: true,
    ).then(
      (secure) {
        _uncount(connection);
        _handshakeDone(key, connection, secure);
      },
      onError: (Object _) {
        _uncount(connection);
        _discard(key, connection);
      },
    );
  }

  void _handshakeDone(String key, _Connection connection, SecureSocket secure) {
    if (_closed ||
        !identical(_connections[key], connection) ||
        !_controller.hasListener) {
      secure.destroy();
      return;
    }
    connection.socket = secure;
    _controller.add(secure);
  }

  void _uncount(_Connection connection) {
    if (!connection.counted) return;
    connection.counted = false;
    if (_closed) return;
    _pendingTotal--;
    final remaining = (_pendingByIp[connection.ip] ?? 0) - 1;
    if (remaining <= 0) {
      _pendingByIp.remove(connection.ip);
    } else {
      _pendingByIp[connection.ip] = remaining;
    }
  }

  void _discard(String key, _Connection connection) {
    if (identical(_connections[key], connection)) _connections.remove(key);
    _release(connection);
  }

  void _release(_Connection connection) {
    connection.timer?.cancel();
    final subscription = connection.subscription;
    connection.subscription = null;
    if (!connection.detached) _uncount(connection);
    connection.socket.destroy();
    if (subscription != null) unawaited(subscription.cancel());
  }
}
