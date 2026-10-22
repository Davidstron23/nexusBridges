import 'dart:async';
import 'dart:collection';
import 'dart:io';
import 'dart:typed_data';

import '../network/network.dart';
import '../protocol/protocol.dart';

const int _addressInUseErrorCode = 10048;
const int _maxPendingDatagrams = 8;

const Duration _flushLimit = Duration(milliseconds: 200);

const Duration _flushRetry = Duration(milliseconds: 5);

void _noLog(String message) {}

final class _Sender {
  _Sender(this.iface, this.socket, this._group, this._port, this._log) {
    socket.readEventsEnabled = false;
    socket.writeEventsEnabled = false;
    _subscription = socket.listen(
      _onEvent,
      onError: (Object error) {
        _log('multicast sender failed: ${error.runtimeType}');
      },
    );
  }

  ActiveInterface iface;
  final RawDatagramSocket socket;
  final InternetAddress _group;
  final int _port;
  final void Function(String) _log;
  final Queue<(Uint8List, InternetAddress)> _pending =
      Queue<(Uint8List, InternetAddress)>();
  late final StreamSubscription<RawSocketEvent> _subscription;

  void send(Uint8List bytes, [InternetAddress? to]) {
    final destination = to ?? _group;
    if (_pending.isEmpty &&
        socket.send(bytes, destination, _port) >= bytes.length) {
      return;
    }
    if (_pending.length >= _maxPendingDatagrams) {
      _pending.removeFirst();
      _log('multicast send queue full');
    }
    _pending.addLast((bytes, destination));
    socket.writeEventsEnabled = true;
  }

  void _onEvent(RawSocketEvent event) {
    if (event != RawSocketEvent.write) return;
    try {
      while (_pending.isNotEmpty) {
        final (bytes, destination) = _pending.first;
        if (socket.send(bytes, destination, _port) < bytes.length) {
          socket.writeEventsEnabled = true;
          return;
        }
        _pending.removeFirst();
      }
      socket.writeEventsEnabled = false;
    } catch (e) {
      _pending.clear();
      _log('multicast send failed: ${e.runtimeType}');
    }
  }

  Future<void> dispose() async {
    final elapsed = Stopwatch()..start();
    while (_pending.isNotEmpty && elapsed.elapsed < _flushLimit) {
      final (bytes, destination) = _pending.first;
      try {
        if (socket.send(bytes, destination, _port) < bytes.length) {
          await Future<void>.delayed(_flushRetry);
          continue;
        }
      } catch (e) {
        _log('multicast send failed: ${e.runtimeType}');
        break;
      }
      _pending.removeFirst();
    }
    await _subscription.cancel();
    _pending.clear();
    socket.close();
  }
}

final class MulticastChannel {
  MulticastChannel({
    this._port = defaultPort,
    InternetAddress? group,
    this._log = _noLog,
  }) : _group = group ?? multicastGroup;

  final int _port;
  final InternetAddress _group;
  final void Function(String) _log;
  final StreamController<(Announcement, InternetAddress, ActiveInterface)>
  _controller =
      StreamController<
        (Announcement, InternetAddress, ActiveInterface)
      >.broadcast();
  final Map<String, _Sender> _senders = {};
  final Map<String, int> _adapterRefs = {};
  final Map<String, NetworkInterface> _joined = {};

  Future<void> _tail = Future<void>.value();
  RawDatagramSocket? _receiver;
  StreamSubscription<RawSocketEvent>? _subscription;
  List<ActiveInterface> _active = [];

  Stream<(Announcement, InternetAddress from, ActiveInterface via)>
  get incoming => _controller.stream;

  Future<void> open() {
    return _exclusive(() async {
      if (_receiver != null) return;
      final RawDatagramSocket socket;
      try {
        socket = await RawDatagramSocket.bind(
          InternetAddress.anyIPv4,
          _port,
          reuseAddress: false,
        );
      } on SocketException catch (e) {
        if (e.osError?.errorCode == _addressInUseErrorCode) {
          throw PortInUseException(_port);
        }
        rethrow;
      }
      _receiver = socket;
      _subscription = socket.listen(
        (event) => _onEvent(socket, event),
        onError: (Object error) {
          _log('multicast receive failed: ${error.runtimeType}');
        },
      );
    });
  }

  Future<void> syncInterfaces(List<ActiveInterface> active) {
    return _exclusive(() async {
      final receiver = _receiver;
      if (receiver == null) return;
      final wanted = {for (final iface in active) iface.id: iface};
      _active = List.of(active);

      for (final id in _senders.keys.toList()) {
        final current = wanted[id];
        if (current != null &&
            current.adapterId == _senders[id]!.iface.adapterId) {
          continue;
        }
        await _removeSender(receiver, _senders.remove(id)!);
      }

      for (final iface in wanted.values) {
        final existing = _senders[iface.id];
        if (existing != null) {
          existing.iface = iface;
          continue;
        }
        final socket = await _openSender(iface);
        if (socket == null) continue;
        _senders[iface.id] = _Sender(iface, socket, _group, _port, _log);
        _adapterRefs[iface.adapterId] =
            (_adapterRefs[iface.adapterId] ?? 0) + 1;
      }

      final pending = <String, ActiveInterface>{};
      for (final sender in _senders.values) {
        final adapterId = sender.iface.adapterId;
        if (_joined.containsKey(adapterId)) continue;
        pending.putIfAbsent(adapterId, () => sender.iface);
      }
      if (pending.isEmpty) return;
      final system = await _systemInterfaces();
      for (final iface in pending.values) {
        _join(receiver, iface, system);
      }
    });
  }

  void send(Announcement a, ActiveInterface via) {
    final sender = _senders[via.id];
    if (_receiver == null || sender == null) return;
    try {
      sender.send(a.encode());
    } catch (e) {
      _log('multicast send failed: ${e.runtimeType}');
    }
  }

  void sendTo(Announcement a, ActiveInterface via, InternetAddress to) {
    final sender = _senders[via.id];
    if (_receiver == null || sender == null) return;
    try {
      sender.send(a.encode(), to);
    } catch (e) {
      _log('multicast send failed: ${e.runtimeType}');
    }
  }

  Future<void> close() {
    return _exclusive(() async {
      final receiver = _receiver;
      final subscription = _subscription;
      final senders = _senders.values.toList();
      _receiver = null;
      _subscription = null;
      _senders.clear();
      _adapterRefs.clear();
      _joined.clear();
      _active = [];
      await subscription?.cancel();
      receiver?.close();
      for (final sender in senders) {
        await sender.dispose();
      }
    });
  }

  void _onEvent(RawDatagramSocket socket, RawSocketEvent event) {
    if (event != RawSocketEvent.read) return;
    try {
      Datagram? datagram;
      while ((datagram = socket.receive()) != null) {
        _handle(datagram!);
      }
    } catch (e) {
      _log('multicast receive failed: ${e.runtimeType}');
    }
  }

  void _handle(Datagram datagram) {
    final announcement = Announcement.tryDecode(datagram.data);
    if (announcement == null) return;
    for (final via in _active) {
      if (originAllowed(datagram.address, via.subnet)) {
        _controller.add((announcement, datagram.address, via));
        return;
      }
    }
  }

  Future<RawDatagramSocket?> _openSender(ActiveInterface iface) async {
    RawDatagramSocket? socket;
    try {
      socket = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
      socket.setRawOption(
        RawSocketOption(
          RawSocketOption.levelIPv4,
          RawSocketOption.IPv4MulticastInterface,
          Uint8List.fromList(iface.subnet.address.rawAddress),
        ),
      );
      socket.multicastHops = 1;
      return socket;
    } catch (e) {
      socket?.close();
      _log('multicast sender failed: ${e.runtimeType}');
      return null;
    }
  }

  Future<List<NetworkInterface>> _systemInterfaces() async {
    try {
      return await NetworkInterface.list(includeLoopback: true);
    } catch (e) {
      _log('network interface list failed: ${e.runtimeType}');
      return const [];
    }
  }

  void _join(
    RawDatagramSocket receiver,
    ActiveInterface iface,
    List<NetworkInterface> system,
  ) {
    final target = system
        .where((candidate) => candidate.name == iface.friendlyName)
        .firstOrNull;
    if (target == null) {
      _log('multicast join skipped: interface not found');
      return;
    }
    try {
      receiver.joinMulticast(_group, target);
      _joined[iface.adapterId] = target;
    } catch (e) {
      _log('multicast join failed: ${e.runtimeType}');
    }
  }

  Future<void> _removeSender(RawDatagramSocket receiver, _Sender sender) async {
    await sender.dispose();
    final adapterId = sender.iface.adapterId;
    final refs = (_adapterRefs[adapterId] ?? 1) - 1;
    if (refs > 0) {
      _adapterRefs[adapterId] = refs;
      return;
    }
    _adapterRefs.remove(adapterId);
    final target = _joined.remove(adapterId);
    if (target == null) return;
    try {
      receiver.leaveMulticast(_group, target);
    } catch (e) {
      _log('multicast leave failed: ${e.runtimeType}');
    }
  }

  Future<void> _exclusive(Future<void> Function() action) {
    final run = _tail.then((_) => action());
    _tail = run.then((_) {}, onError: (Object _) {});
    return run;
  }
}
