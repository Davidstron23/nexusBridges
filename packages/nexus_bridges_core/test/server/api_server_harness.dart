import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:basic_utils/basic_utils.dart';
import 'package:nexus_bridges_core/src/identity/identity.dart';
import 'package:nexus_bridges_core/src/network/network.dart';
import 'package:nexus_bridges_core/src/pairing/pairing.dart';
import 'package:nexus_bridges_core/src/protocol/protocol.dart';
import 'package:nexus_bridges_core/src/server/server.dart';
import 'package:nexus_bridges_core/src/storage/storage.dart';
import 'package:test/test.dart';

final InternetAddress loopback = InternetAddress.loopbackIPv4;
final InternetAddress otherLoopback = InternetAddress('127.0.0.2');
const String registerPath = '$apiPrefix/register';
const Duration waitLimit = Duration(seconds: 5);
const String jsonContentType = 'application/json; charset=utf-8';

ActiveInterface loopbackInterface({
  String adapterId = 'loopback',
  String address = '127.0.0.1',
  int prefixLength = 8,
}) => ActiveInterface(
  id: '$adapterId#$address',
  adapterId: adapterId,
  friendlyName: 'Loopback Pseudo-Interface 1',
  subnet: Ipv4Subnet(InternetAddress(address), prefixLength),
);

PairedDevice pairedDeviceOf(DeviceIdentity identity, {DateTime? pairedAt}) =>
    PairedDevice(
      fingerprint: identity.fingerprint,
      name: 'peer',
      certificatePem: identity.certificatePem,
      relation: PeerRelation.mine,
      pairedAt: pairedAt ?? DateTime.utc(2026, 10, 21),
    );

DeviceInfo selfInfoOf(DeviceIdentity identity) => DeviceInfo(
  name: 'Server PC',
  fingerprint: identity.fingerprint,
  port: defaultPort,
  protocol: protocolVersion,
  deviceType: DeviceType.desktop,
);

DeviceInfo callerInfoOf(DeviceIdentity identity, {String name = 'Caller'}) =>
    DeviceInfo(
      name: name,
      fingerprint: identity.fingerprint,
      port: 40000,
      protocol: protocolVersion,
      deviceType: DeviceType.mobile,
    );

final Expando<SecurityContext> _presentingContexts = Expando();

SecurityContext presenting(DeviceIdentity identity) =>
    _presentingContexts[identity] ??= identity.serverContext(
      trustedCertificatesPem: const [],
    );

final SecurityContext anonymousContext = SecurityContext(
  withTrustedRoots: false,
);

DeviceIdentity expiredIdentity(String commonName) {
  final pair = CryptoUtils.generateEcKeyPair();
  final privateKey = pair.privateKey as ECPrivateKey;
  final publicKey = pair.publicKey as ECPublicKey;
  final csr = X509Utils.generateEccCsrPem(
    {'CN': commonName},
    privateKey,
    publicKey,
  );
  return DeviceIdentity.fromPem(
    certificatePem: X509Utils.generateSelfSignedCertificate(
      privateKey,
      csr,
      3,
      notBefore: DateTime.utc(2000),
    ),
    privateKeyPem: CryptoUtils.encodeEcPrivateKeyToPem(privateKey),
  )!;
}

final class _ReversingProtector implements SecretProtector {
  @override
  Uint8List protect(Uint8List data) =>
      Uint8List.fromList(data.reversed.toList());

  @override
  Uint8List? unprotect(Uint8List data) =>
      Uint8List.fromList(data.reversed.toList());
}

String privateKeyPemOf(DeviceIdentity identity) {
  final protector = _ReversingProtector();
  return utf8.decode(
    protector.unprotect(identity.protectPrivateKey(protector))!,
  );
}

Iterable<String> pemFragments(String pem, {int size = 16}) sync* {
  final body = LineSplitter.split(pem)
      .map((l) => l.trim())
      .where((l) => !l.startsWith('-----'))
      .join();
  for (var i = 0; i + size <= body.length; i += size ~/ 2) {
    yield body.substring(i, i + size);
  }
}

List<int> httpRequest(
  String method,
  String path, {
  List<int>? body,
  Map<String, String> headers = const {},
}) {
  final head = StringBuffer('$method $path HTTP/1.1\r\nhost: 127.0.0.1\r\n');
  headers.forEach((name, value) => head.write('$name: $value\r\n'));
  if (body != null) head.write('content-length: ${body.length}\r\n');
  head.write('\r\n');
  return [...utf8.encode(head.toString()), ...?body];
}

List<int> jsonBody(Object? json) => utf8.encode(jsonEncode(json));

List<int> registerRequest(DeviceInfo caller) =>
    httpRequest('POST', registerPath, body: jsonBody(caller.toJson()));

final class Reply {
  const Reply(this.status, this.headers, this.body);

  final int status;
  final Map<String, List<String>> headers;
  final String body;

  Object? get json => jsonDecode(body);

  String? header(String name) => headers[name]?.single;

  static Reply? parseFinal(List<int> bytes) {
    var start = 0;
    final text = latin1.decode(bytes);
    while (text.startsWith('HTTP/1.1 100 ', start)) {
      final end = text.indexOf('\r\n\r\n', start);
      if (end < 0) return null;
      start = end + 4;
    }
    return parse(bytes.sublist(start));
  }

  static Reply? parse(List<int> bytes) {
    final text = latin1.decode(bytes);
    final end = text.indexOf('\r\n\r\n');
    if (!text.startsWith('HTTP/1.1 ') || end < 0) return null;
    final lines = text.substring(0, end).split('\r\n');
    final headers = <String, List<String>>{};
    for (final line in lines.skip(1)) {
      final colon = line.indexOf(':');
      headers
          .putIfAbsent(line.substring(0, colon).trim().toLowerCase(), () => [])
          .add(line.substring(colon + 1).trim());
    }
    return Reply(
      int.parse(lines.first.split(' ')[1]),
      headers,
      utf8.decode(bytes.sublist(end + 4)),
    );
  }
}

final class TlsClient {
  TlsClient._(this.socket) {
    socket.done.ignore();
    socket.listen(
      (chunk) {
        received.addAll(chunk);
        if (!_data.isCompleted) _data.complete();
      },
      onError: (Object _) => _finish(),
      onDone: _finish,
      cancelOnError: true,
    );
  }

  static Future<TlsClient> connect(
    int port, {
    required String serverFingerprint,
    SecurityContext? context,
    InternetAddress? from,
    InternetAddress? to,
  }) async {
    final raw = await Socket.connect(to ?? loopback, port, sourceAddress: from);
    addTearDown(raw.destroy);
    final secure = await SecureSocket.secure(
      raw,
      context: context ?? anonymousContext,
      onBadCertificate: (c) =>
          fingerprintOfCertificate(c.der) == serverFingerprint,
    );
    addTearDown(secure.destroy);
    return TlsClient._(secure);
  }

  final SecureSocket socket;
  final List<int> received = [];
  final Completer<void> _closed = Completer();
  final Completer<void> _data = Completer();

  bool get isClosed => _closed.isCompleted;

  Future<void> get closed => _closed.future;

  Future<void> get dataArrived => _data.future;

  void write(List<int> bytes) {
    if (isClosed) return;
    try {
      socket.add(bytes);
    } on Object {
      return;
    }
  }

  Future<Reply?> reply({Duration limit = waitLimit}) async {
    await _closed.future.timeout(limit);
    return Reply.parse(received);
  }

  void _finish() {
    if (!_closed.isCompleted) _closed.complete();
  }
}

Future<Reply?> send(
  int port,
  List<int> request, {
  required String serverFingerprint,
  SecurityContext? context,
  InternetAddress? from,
  InternetAddress? to,
}) async {
  final client = await TlsClient.connect(
    port,
    serverFingerprint: serverFingerprint,
    context: context,
    from: from,
    to: to,
  );
  client.write(request);
  return client.reply();
}

Future<Reply?> sendOrCut(
  int port,
  List<int> request, {
  required String serverFingerprint,
  SecurityContext? context,
  InternetAddress? from,
  InternetAddress? to,
}) async {
  try {
    return await send(
      port,
      request,
      serverFingerprint: serverFingerprint,
      context: context,
      from: from,
      to: to,
    );
  } on IOException {
    return null;
  }
}

typedef Registration = ({
  DeviceInfo caller,
  InternetAddress from,
  ActiveInterface via,
});

final class RouteProbe {
  RouteProbe(
    this.path, {
    this.access = RouteAccess.anonymous,
    this.maxBodyBytes = Limits.maxPairingBodyBytes,
    this.limit,
    this.answer,
  });

  final String path;
  final RouteAccess access;
  final int maxBodyBytes;
  final RouteLimit? limit;
  FutureOr<ApiReply> Function(ApiCall call)? answer;
  Completer<void>? gate;
  final List<ApiCall> calls = [];
  int answered = 0;

  int get count => calls.length;

  ApiRoute get route => ApiRoute(
    path: path,
    access: access,
    handle: _handle,
    maxBodyBytes: maxBodyBytes,
    limit: limit,
  );

  Future<void> arrived(int expected, {Duration limit = waitLimit}) async {
    final stopwatch = Stopwatch()..start();
    while (calls.length < expected) {
      if (stopwatch.elapsed > limit) {
        throw TimeoutException('$path got ${calls.length} of $expected');
      }
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
  }

  Future<ApiReply> _handle(ApiCall call) async {
    calls.add(call);
    final held = gate;
    if (held != null) await held.future;
    final reply = answer;
    final result = reply == null
        ? ApiReply(200, {'path': call.path, 'call': calls.length})
        : await reply(call);
    answered++;
    return result;
  }
}

final class ServerHarness {
  ServerHarness._(this.identity, this.paired, this.pairedFile);

  final DeviceIdentity identity;
  final PairedDevicesStore paired;
  final File pairedFile;
  final List<String> logs = [];
  final List<Registration> registrations = [];
  late final ApiServer server;
  DateTime now = DateTime.utc(2026, 10, 21, 12);
  void Function(Registration registration)? onRegistered;

  int get port => server.boundPort!;

  static Future<ServerHarness> start({
    required DeviceIdentity identity,
    Iterable<DeviceIdentity> pairedWith = const [],
    List<ActiveInterface>? active,
    int port = 0,
    List<ApiRoute> routes = const [],
  }) async {
    final dir = await Directory.systemTemp.createTemp('nexus_api_');
    addTearDown(() => dir.delete(recursive: true));
    final file = File('${dir.path}${Platform.pathSeparator}paired.json');
    final store = PairedDevicesStore(
      JsonFileStore(file),
      ownerFingerprint: identity.fingerprint,
    );
    await store.load();
    if (pairedWith.isNotEmpty) {
      await store.replaceAll([for (final p in pairedWith) pairedDeviceOf(p)]);
    }
    final harness = ServerHarness._(identity, store, file);
    harness.server = ApiServer(
      identity: identity,
      paired: store,
      routes: routes,
      selfInfo: () => selfInfoOf(identity),
      onRegistered: (caller, from, via) {
        final registration = (caller: caller, from: from, via: via);
        harness.registrations.add(registration);
        harness.onRegistered?.call(registration);
      },
      port: port,
      now: () => harness.now,
      log: harness.logs.add,
    );
    addTearDown(harness.server.close);
    await harness.server.syncInterfaces(active ?? [loopbackInterface()]);
    return harness;
  }

  Future<void> pair(Iterable<DeviceIdentity> identities) =>
      paired.replaceAll([for (final p in identities) pairedDeviceOf(p)]);

  Future<Reply?> send(
    List<int> request, {
    SecurityContext? context,
    InternetAddress? from,
  }) => sendOrCut(
    port,
    request,
    serverFingerprint: identity.fingerprint,
    context: context,
    from: from,
  );
}

Future<int> freePort({InternetAddress? address}) async {
  final probe = await ServerSocket.bind(address ?? loopback, 0);
  final port = probe.port;
  await probe.close();
  return port;
}

Future<int> freePortOn(List<InternetAddress> addresses) async {
  for (var attempt = 0; attempt < 50; attempt++) {
    final port = await freePort(address: addresses.first);
    var free = true;
    for (final address in addresses) {
      if (!await canBind(address, port) || !await _canBindUdp(address, port)) {
        free = false;
        break;
      }
    }
    if (free) return port;
  }
  throw StateError('no port free on every address');
}

Future<bool> _canBindUdp(InternetAddress address, int port) async {
  try {
    final socket = await RawDatagramSocket.bind(address, port);
    socket.close();
    return true;
  } on SocketException {
    return false;
  }
}

Future<bool> canBind(InternetAddress address, int port) async {
  try {
    final socket = await ServerSocket.bind(address, port);
    await socket.close();
    return true;
  } on SocketException {
    return false;
  }
}

const String _holdPortScript = '''
import 'dart:io';

Future<void> main(List<String> args) async {
  final server = await ServerSocket.bind(InternetAddress(args.first), 0);
  server.listen((socket) => socket.destroy());
  stdout.writeln(server.port);
  await stdin.drain<void>();
  await server.close();
}
''';

Future<int> holdPortInChildProcess(InternetAddress address) async {
  final dir = await Directory.systemTemp.createTemp('nexus_api_port_');
  addTearDown(() => dir.delete(recursive: true));
  final script = File('${dir.path}${Platform.pathSeparator}hold_port.dart');
  await script.writeAsString(_holdPortScript);
  final process = await Process.start(Platform.resolvedExecutable, [
    script.path,
    address.address,
  ]);
  addTearDown(() async {
    process.kill();
    await process.exitCode;
  });
  process.stderr.drain<void>().ignore();
  final line = await process.stdout
      .transform(utf8.decoder)
      .transform(const LineSplitter())
      .first
      .timeout(const Duration(seconds: 30));
  return int.parse(line.trim());
}
