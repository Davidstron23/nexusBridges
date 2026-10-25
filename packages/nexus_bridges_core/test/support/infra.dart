import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:test/test.dart';

const String timeScaleVariable = 'NEXUS_TEST_TIME_SCALE';

const double ciTimeScale = 3;

final double timeScale = timeScaleFrom(Platform.environment);

double timeScaleFrom(Map<String, String> environment) {
  final explicit = double.tryParse(environment[timeScaleVariable] ?? '');
  if (explicit != null && explicit.isFinite && explicit >= 1) return explicit;
  final ci = environment['CI']?.trim().toLowerCase();
  if (ci != null && ci.isNotEmpty && ci != 'false' && ci != '0') {
    return ciTimeScale;
  }
  return 1;
}

Duration scaled(Duration span) => span * timeScale;

const int firstPickedPort = 20000;

const int lastPickedPort = 48999;

final Random _ports = Random();

Future<int> pickPort({
  List<InternetAddress> tcp = const [],
  List<InternetAddress> udp = const [],
}) async {
  for (var attempt = 0; attempt < 2000; attempt++) {
    final port =
        firstPickedPort + _ports.nextInt(lastPickedPort - firstPickedPort + 1);
    if (await _free(port, tcp, udp)) return port;
    if (attempt % 50 == 49) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
  }
  throw StateError('no port free on tcp $tcp and udp $udp');
}

Future<bool> _free(
  int port,
  List<InternetAddress> tcp,
  List<InternetAddress> udp,
) async {
  for (final address in tcp) {
    if (!await tcpFree(address, port)) return false;
  }
  for (final address in udp) {
    if (!await udpFree(address, port)) return false;
  }
  return true;
}

Future<bool> tcpFree(InternetAddress address, int port) async {
  try {
    final socket = await ServerSocket.bind(address, port);
    await socket.close();
    return true;
  } on SocketException {
    return false;
  }
}

Future<bool> udpFree(InternetAddress address, int port) async {
  final RawDatagramSocket socket;
  try {
    socket = await RawDatagramSocket.bind(address, port, reuseAddress: false);
  } on SocketException {
    return false;
  }
  await closeUdp(socket);
  return true;
}

Future<void> closeUdp(RawDatagramSocket socket) async {
  final closed = Completer<void>();
  socket.listen(
    (_) {},
    onDone: () {
      if (!closed.isCompleted) closed.complete();
    },
    onError: (Object _) {},
  );
  socket.close();
  await closed.future.timeout(scaled(const Duration(seconds: 5)));
}

final class PortTaken implements Exception {
  PortTaken(this.message);

  final String message;

  @override
  String toString() => 'PortTaken: $message';
}

Future<void> awaitListening({
  required String name,
  required List<String> logs,
  required int since,
  required int? Function() portInUse,
  required Duration limit,
}) async {
  final watch = Stopwatch()..start();
  while (true) {
    final taken = portInUse();
    if (taken != null) {
      throw PortTaken('$name found port $taken in use: ${_tail(logs, since)}');
    }
    if (logs.skip(since).any((line) => line.startsWith('listening on '))) {
      return;
    }
    if (watch.elapsed > limit) {
      fail('$name listening not met within $limit: ${_tail(logs, since)}');
    }
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}

String _tail(List<String> logs, int since) {
  final recent = logs.skip(since).toList();
  final shown = recent.length > 20
      ? recent.sublist(recent.length - 20)
      : recent;
  return shown.join(' | ');
}

Future<T> onFreshPorts<T>(
  Future<T> Function() attempt, {
  required Future<void> Function() reset,
  int attempts = 5,
}) async {
  for (var round = 1; ; round++) {
    try {
      return await attempt();
    } on PortTaken {
      if (round >= attempts) rethrow;
      await reset();
    }
  }
}
