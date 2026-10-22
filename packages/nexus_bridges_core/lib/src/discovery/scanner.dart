import 'dart:async';
import 'dart:io';

import '../network/network.dart';
import '../protocol/protocol.dart';
import 'verifier.dart';

const int _maxHostsPerInterface = 254;

typedef _ScanResult = (DeviceInfo, InternetAddress, ActiveInterface);

final class SubnetScanner {
  SubnetScanner({
    required this._verifier,
    this._port = defaultPort,
    this._hostsOf,
  });

  final DeviceVerifier _verifier;

  final int _port;

  final List<InternetAddress> Function(ActiveInterface)? _hostsOf;

  Stream<(DeviceInfo, InternetAddress, ActiveInterface)> scan({
    required List<ActiveInterface> active,
    required DeviceInfo self,
    AbortSignal? abort,
  }) {
    var cancelled = false;
    final controller = StreamController<_ScanResult>(
      onCancel: () => cancelled = true,
    );
    controller.onListen = () {
      unawaited(
        _run(
          controller,
          () => cancelled || (abort?.aborted ?? false),
          active,
          self,
          abort,
        ),
      );
    };
    return controller.stream;
  }

  Future<void> _run(
    StreamController<_ScanResult> sink,
    bool Function() stopped,
    List<ActiveInterface> active,
    DeviceInfo self,
    AbortSignal? abort,
  ) async {
    try {
      final targets = <(ActiveInterface, InternetAddress)>[];
      for (final iface in active) {
        final hosts =
            _hostsOf?.call(iface) ??
            iface.subnet.slash24Hosts().where(iface.subnet.contains);
        for (final host in hosts.take(_maxHostsPerInterface)) {
          targets.add((iface, host));
        }
      }

      var next = 0;
      Future<void> worker() async {
        while (!stopped() && next < targets.length) {
          final (iface, host) = targets[next++];
          final info = await _verifier.register(
            address: host,
            port: _port,
            expectedFingerprint: null,
            self: self,
            timeout: Limits.scanConnectTimeout,
            abort: abort,
          );
          if (info != null && !stopped()) sink.add((info, host, iface));
        }
      }

      await Future.wait([
        for (var i = 0; i < Limits.scanConcurrency; i++) worker(),
      ]);
    } catch (_) {
      return;
    } finally {
      unawaited(sink.close());
    }
  }
}
