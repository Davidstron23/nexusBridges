import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:basic_utils/basic_utils.dart';
import 'package:crypto/crypto.dart';
import 'package:nexus_bridges_core/src/identity/certificate_builder.dart';
import 'package:nexus_bridges_core/src/identity/certificate_parser.dart';
import 'package:nexus_bridges_core/src/identity/der.dart';
import 'package:nexus_bridges_core/src/identity/identity.dart';
import 'package:nexus_bridges_core/src/network/network.dart';
import 'package:nexus_bridges_core/src/pairing/pairing.dart';
import 'package:nexus_bridges_core/src/pairing_flow/crypto.dart';
import 'package:nexus_bridges_core/src/pairing_flow/messages.dart';
import 'package:nexus_bridges_core/src/pairing_flow/pairing_flow.dart';
import 'package:nexus_bridges_core/src/protocol/protocol.dart';
import 'package:nexus_bridges_core/src/server/server.dart';
import 'package:nexus_bridges_core/src/storage/storage.dart';
import 'package:test/test.dart';

import '../server/api_server_harness.dart';

final InternetAddress stackLoopbackC = InternetAddress('127.0.0.3');

final String _sep = Platform.pathSeparator;

final class StackClock {
  DateTime now = DateTime.utc(2026, 10, 24, 9);

  void advance(Duration span) => now = now.add(span);
}

Future<void> waitUntil(
  bool Function() condition, {
  Duration limit = const Duration(seconds: 8),
  String reason = 'condition',
}) async {
  final stopwatch = Stopwatch()..start();
  while (!condition()) {
    if (stopwatch.elapsed > limit) fail('$reason not met within $limit');
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}

Future<void> pause([Duration span = const Duration(milliseconds: 300)]) =>
    Future<void>.delayed(span);

Future<Directory> stackDirectory() async {
  final dir = await Directory.systemTemp.createTemp('nexus_initiator_');
  addTearDown(() async {
    for (var attempt = 0; attempt < 40; attempt++) {
      try {
        if (dir.existsSync()) await dir.delete(recursive: true);
        return;
      } on FileSystemException {
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
    }
  });
  return dir;
}

typedef StackRouteWrapper = Future<ApiReply> Function(
  ApiCall call,
  Future<ApiReply> Function(ApiCall call) inner,
);

final class RecordedCall {
  RecordedCall(this.json, this.at);

  final Object? json;
  final DateTime at;
}

final class PairingStack {
  PairingStack._(
    this.identity,
    this.name,
    this.address,
    this.clock,
    this.storeDir,
    this.pairedFile,
    this.ignoredFile,
  ) : paired = PairedDevicesStore(
        JsonFileStore(pairedFile),
        ownerFingerprint: identity.fingerprint,
        now: () => clock.now,
      ) {
    ignored = IgnoredDevicesStore(
      JsonFileStore(ignoredFile),
      isPaired: paired.isPaired,
      now: () => clock.now,
    );
  }

  final DeviceIdentity identity;
  final String name;
  final InternetAddress address;
  final StackClock clock;
  final Directory storeDir;
  final File pairedFile;
  final File ignoredFile;
  final PairedDevicesStore paired;
  late final IgnoredDevicesStore ignored;
  late final PairingCoordinator coordinator;
  late final ApiServer server;
  late final ActiveInterface iface;
  final Map<String, List<RecordedCall>> calls = {};
  final Map<String, StackRouteWrapper> wrappers = {};
  final List<PairingEvent> events = [];
  final List<PairingView?> views = [];
  final List<String> logs = [];

  int get port => server.boundPort!;

  String get fingerprint => identity.fingerprint;

  PairingView? get view => coordinator.view;

  int handledOn(String path) => calls[path]?.length ?? 0;

  int get handledTotal =>
      calls.values.fold(0, (total, list) => total + list.length);

  List<PairingCompleted> get completions =>
      events.whereType<PairingCompleted>().toList();

  static Future<PairingStack> start({
    required DeviceIdentity identity,
    required InternetAddress address,
    required String name,
    StackClock? clock,
    Duration pollHold = const Duration(milliseconds: 200),
    Duration confirmRetry = Limits.pairingConfirmRetry,
    Duration saveTimeout = Limits.pairingMessageTimeout,
    Duration tickInterval = const Duration(milliseconds: 10),
    bool ticking = true,
  }) async {
    final dir = await stackDirectory();
    final storeDir = Directory('${dir.path}${_sep}store');
    final stack = PairingStack._(
      identity,
      name,
      address,
      clock ?? StackClock(),
      storeDir,
      File('${storeDir.path}${_sep}paired.json'),
      File('${storeDir.path}${_sep}ignored.json'),
    );
    await stack.paired.load();
    await stack.ignored.load();
    stack.coordinator = PairingCoordinator(
      identity: identity,
      paired: stack.paired,
      ignored: stack.ignored,
      selfInfo: () => DeviceInfo(
        name: name,
        fingerprint: identity.fingerprint,
        port: defaultPort,
        protocol: protocolVersion,
        deviceType: DeviceType.desktop,
      ),
      now: () => stack.clock.now,
      tickInterval: tickInterval,
      pollHold: pollHold,
      confirmRetry: confirmRetry,
      saveTimeout: saveTimeout,
      log: stack.logs.add,
    );
    stack.coordinator.changes.listen(
      (_) => stack.views.add(stack.coordinator.view),
    );
    stack.coordinator.events.listen(stack.events.add);
    stack.iface = loopbackInterface(
      adapterId: 'stack-${address.address}',
      address: address.address,
    );
    stack.server = ApiServer(
      identity: identity,
      paired: stack.paired,
      routes: [
        for (final route in stack.coordinator.routes) stack._wrap(route),
      ],
      selfInfo: () => selfInfoOf(identity),
      onRegistered: (_, _, _) {},
      port: 0,
      now: () => stack.clock.now,
      log: stack.logs.add,
    );
    addTearDown(stack.close);
    await stack.server.syncInterfaces([stack.iface]);
    if (ticking) stack.coordinator.start();
    return stack;
  }

  PairingTarget targetOf(
    PairingStack other, {
    String? fingerprint,
    String? name,
    int? port,
  }) => PairingTarget(
    fingerprint: fingerprint ?? other.fingerprint,
    name: name ?? other.name,
    address: other.address,
    port: port ?? other.port,
    interfaceId: iface.id,
    localAddress: address,
  );

  PairingTarget targetAt(
    InternetAddress remote,
    int remotePort, {
    required String fingerprint,
    String? name = 'Remote',
  }) => PairingTarget(
    fingerprint: fingerprint,
    name: name,
    address: remote,
    port: remotePort,
    interfaceId: iface.id,
    localAddress: address,
  );

  Future<void> pairWith(Iterable<DeviceIdentity> peers) async {
    await paired.replaceAll([
      ...paired.devices,
      for (final peer in peers) pairedDeviceOf(peer),
    ]);
    await server.rebuildTrust();
  }

  Future<void> breakStore() async {
    if (storeDir.existsSync()) await storeDir.delete(recursive: true);
    await File(storeDir.path).writeAsString('not a directory');
  }

  Future<List<PairedDevice>> reloadPaired() async {
    final store = PairedDevicesStore(
      JsonFileStore(pairedFile),
      ownerFingerprint: identity.fingerprint,
    );
    await store.load();
    return store.devices;
  }

  bool get storeHasTemporaryFile =>
      storeDir.existsSync() &&
      storeDir.listSync().any((entry) => entry.path.endsWith('.tmp'));

  Future<void> close() async {
    await coordinator.close();
    await server.close();
  }

  ApiRoute _wrap(ApiRoute route) => ApiRoute(
    path: route.path,
    access: route.access,
    maxBodyBytes: route.maxBodyBytes,
    limit: route.limit,
    handle: (call) {
      calls
          .putIfAbsent(route.path, () => [])
          .add(RecordedCall(call.json, DateTime.now()));
      final wrapper = wrappers[route.path];
      return wrapper == null ? route.handle(call) : wrapper(call, route.handle);
    },
  );
}

final class FakeCall {
  FakeCall(this.path, this.json, this.index, this.at, this.clientFingerprint);

  final String path;
  final Object? json;
  final int index;
  final DateTime at;
  final String? clientFingerprint;

  Map<String, Object?> get body =>
      json is Map<String, Object?> ? json as Map<String, Object?> : const {};
}

final class FakeAnswer {
  const FakeAnswer(this.status, this.json)
    : raw = null,
      drop = false,
      hold = false;

  const FakeAnswer.hold()
    : status = 0,
      json = null,
      raw = null,
      drop = false,
      hold = true;

  const FakeAnswer.raw(this.status, String this.raw)
    : json = null,
      drop = false,
      hold = false;

  const FakeAnswer.drop()
    : status = 0,
      json = null,
      raw = null,
      drop = true,
      hold = false;

  final int status;
  final Object? json;
  final String? raw;
  final bool drop;
  final bool hold;

  static FakeAnswer state(String state) => FakeAnswer(200, {'state': state});
}

typedef FakeHandler = FutureOr<FakeAnswer> Function(FakeCall call);

final class FakeReceiver {
  FakeReceiver._(this.fingerprint, this.server, this.address);

  final String fingerprint;
  final HttpServer server;
  final InternetAddress address;
  final Uint8List session = randomBytes(sessionIdLength);
  final Uint8List nr = randomBytes(nonceLength);
  late final Uint8List cr = commitmentOf(
    role: PairingRole.receiver,
    fingerprint: fingerprint,
    nonce: nr,
  );
  final Map<String, FakeHandler> handlers = {};
  final List<FakeCall> calls = [];
  final Completer<void> _closing = Completer<void>();

  int get port => server.port;

  Future<void> get closing => _closing.future;

  int count(String path) => calls.where((c) => c.path == path).length;

  List<FakeCall> callsTo(String path) =>
      calls.where((c) => c.path == path).toList();

  static Future<FakeReceiver> start({
    required String fingerprint,
    required SecurityContext context,
    InternetAddress? address,
    bool requestClientCertificate = false,
  }) async {
    final where = address ?? otherLoopback;
    final server = await HttpServer.bindSecure(
      where,
      0,
      context,
      requestClientCertificate: requestClientCertificate,
    );
    final fake = FakeReceiver._(fingerprint, server, where);
    fake.handlers.addAll(fake._defaults());
    server.listen((request) => unawaited(fake._serve(request)));
    addTearDown(fake.close);
    return fake;
  }

  static Future<FakeReceiver> of(DeviceIdentity identity) => start(
    fingerprint: identity.fingerprint,
    context: identity.serverContext(trustedCertificatesPem: const []),
  );

  Future<FakeAnswer> hang() async {
    await closing;
    return const FakeAnswer(503, {'error': 'closing'});
  }

  final List<Socket> _held = [];

  int heldOpened = 0;

  int heldClosed = 0;

  Future<void> close() async {
    if (!_closing.isCompleted) _closing.complete();
    for (final socket in _held) {
      socket.destroy();
    }
    await server.close(force: true);
  }

  Future<void> _keep(HttpRequest request) async {
    final socket = await request.response.detachSocket(writeHeaders: false);
    heldOpened++;
    _held.add(socket);
    var seen = false;
    void gone() {
      if (seen) return;
      seen = true;
      heldClosed++;
      socket.destroy();
    }

    socket.listen((_) {}, onDone: gone, onError: (Object _) => gone());
  }

  Map<String, FakeHandler> _defaults() => {
    ApiPaths.pairStart: (_) =>
        FakeAnswer(200, StartReply(session: session, commitment: cr).toJson()),
    ApiPaths.pairReveal: (_) =>
        FakeAnswer(200, RevealReply(nonce: nr).toJson()),
    ApiPaths.pairWait: (_) async {
      await Future<void>.delayed(const Duration(milliseconds: 100));
      return FakeAnswer.state('pending');
    },
    ApiPaths.pairConfirm: (_) => FakeAnswer.state('pending'),
    ApiPaths.pairCancel: (call) => FakeAnswer.state(
      call.body['reason'] == 'expired' ? 'expired' : 'cancelled',
    ),
    ApiPaths.pairStatus: (_) => const FakeAnswer(200, {'paired': true}),
    ApiPaths.unpair: (_) => const FakeAnswer(200, {}),
  };

  Future<void> _serve(HttpRequest request) async {
    try {
      final path = request.uri.path;
      final text = await utf8.decoder.bind(request).join();
      Object? json;
      try {
        json = jsonDecode(text);
      } on FormatException {
        json = null;
      }
      final index = count(path) + 1;
      String? client;
      try {
        final certificate = request.certificate;
        client = certificate == null
            ? null
            : fingerprintOfCertificate(certificate.der);
      } catch (_) {
        client = 'unreadable';
      }
      final call = FakeCall(path, json, index, DateTime.now(), client);
      calls.add(call);
      final handler = handlers[path];
      final answer = handler == null
          ? const FakeAnswer(404, {'error': 'not_found'})
          : await handler(call);
      if (answer.hold) {
        await _keep(request);
        return;
      }
      if (answer.drop) {
        final socket = await request.response.detachSocket(writeHeaders: false);
        socket.destroy();
        return;
      }
      final bytes = utf8.encode(answer.raw ?? jsonEncode(answer.json));
      final response = request.response
        ..persistentConnection = false
        ..statusCode = answer.status
        ..headers.contentType = ContentType.json
        ..contentLength = bytes.length
        ..add(bytes);
      await response.close();
    } catch (_) {
      try {
        await request.response.close();
      } catch (_) {}
    }
  }
}

final class OversizedCertificate {
  OversizedCertificate._(
    this.pem,
    this.der,
    this.privateKeyPem,
    this.fingerprint,
  );

  factory OversizedCertificate() {
    final pair = CryptoUtils.generateEcKeyPair();
    final privateKey = pair.privateKey as ECPrivateKey;
    final publicKey = pair.publicKey as ECPublicKey;
    final commonName = commonNameForSpki(spkiOf(publicKey));
    final name = derSequence([
      derSet([
        derSequence([
          derOid(const [0x55, 0x04, 0x03]),
          derPrintable(commonName),
        ]),
      ]),
    ]);
    final algorithm = derSequence([
      derOid(const [0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x04, 0x03, 0x02]),
    ]);
    final spki = derSequence([
      derSequence([
        derOid(const [0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x02, 0x01]),
        derOid(const [0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x03, 0x01, 0x07]),
      ]),
      derBitString(publicKey.Q!.getEncoded(false)),
    ]);
    final serial = randomBytes(3000)..[0] = 0x42;
    final tbs = derSequence([
      derExplicit(0, derInteger(Uint8List.fromList([2]))),
      derInteger(serial),
      algorithm,
      name,
      derSequence([
        derUtcTime('000101000000Z'),
        derGeneralizedTime('99991231235959Z'),
      ]),
      name,
      spki,
    ]);
    final signature = CryptoUtils.ecSign(
      privateKey,
      tbs,
      algorithmName: 'SHA-256/ECDSA',
    );
    final der = derSequence([
      tbs,
      algorithm,
      derBitString(
        derSequence([
          derIntegerFromBigInt(signature.r),
          derIntegerFromBigInt(signature.s),
        ]),
      ),
    ]);
    return OversizedCertificate._(
      normalizedPemOf(der),
      der,
      CryptoUtils.encodeEcPrivateKeyToPem(privateKey),
      fingerprintOfCertificate(der),
    );
  }

  final String pem;
  final Uint8List der;
  final String privateKeyPem;
  final String fingerprint;

  SecurityContext get serverContext => SecurityContext(withTrustedRoots: false)
    ..minimumTlsProtocolVersion = TlsProtocolVersion.tls1_3
    ..useCertificateChainBytes(utf8.encode(pem))
    ..usePrivateKeyBytes(utf8.encode(privateKeyPem));
}

PairedDevice impostorWithNameOf(DeviceIdentity original, DateTime pairedAt) {
  final pair = CryptoUtils.generateEcKeyPair();
  final privateKey = pair.privateKey as ECPrivateKey;
  final publicKey = pair.publicKey as ECPublicKey;
  final serial = randomBytes(16)..[0] = 0x42;
  final pem = buildSelfSignedCertificatePem(
    privateKey: privateKey,
    publicKey: publicKey,
    commonName: original.certificate.commonName,
    serialNumber: serial,
  );
  return PairedDevice(
    fingerprint: toHex(sha256.convert(spkiOf(publicKey)).bytes).toUpperCase(),
    name: 'Old device',
    certificatePem: pem,
    relation: PeerRelation.mine,
    pairedAt: pairedAt,
  );
}

final class SilentListener {
  SilentListener._(this.server);

  final ServerSocket server;
  final List<Socket> accepted = [];
  int closedByPeer = 0;

  int get port => server.port;

  static Future<SilentListener> start(InternetAddress address) async {
    final server = await ServerSocket.bind(address, 0);
    final listener = SilentListener._(server);
    server.listen((socket) {
      listener.accepted.add(socket);
      var seen = false;
      void gone() {
        if (seen) return;
        seen = true;
        listener.closedByPeer++;
      }

      socket.listen((_) {}, onDone: gone, onError: (Object _) => gone());
    });
    addTearDown(listener.close);
    return listener;
  }

  Future<void> close() async {
    for (final socket in accepted) {
      socket.destroy();
    }
    await server.close();
  }
}

final class ZoneTimers {
  final List<(Timer, String)> _timers = [];

  ZoneSpecification get specification => ZoneSpecification(
    createTimer: (self, parent, zone, duration, callback) {
      final timer = parent.createTimer(zone, duration, callback);
      _timers.add((timer, StackTrace.current.toString()));
      return timer;
    },
    createPeriodicTimer: (self, parent, zone, period, callback) {
      final timer = parent.createPeriodicTimer(zone, period, callback);
      _timers.add((timer, StackTrace.current.toString()));
      return timer;
    },
  );

  int createdBy(String file) =>
      _timers.where((entry) => entry.$2.contains(file)).length;

  int activeBy(String file) => _timers
      .where((entry) => entry.$2.contains(file) && entry.$1.isActive)
      .length;
}

void lockExclusively(File file) {
  file.parent.createSync(recursive: true);
  final handle = file.openSync(mode: FileMode.append);
  handle.lockSync(FileLock.exclusive);
  addTearDown(() {
    try {
      handle.unlockSync();
    } catch (_) {}
    handle.closeSync();
  });
}

final RegExp longHex = RegExp(r'[0-9a-fA-F]{32,}');

void expectCleanLogs(PairingStack stack) {
  for (final line in stack.logs) {
    expect(line, isNot(contains('BEGIN')), reason: line);
    expect(longHex.hasMatch(line), isFalse, reason: line);
  }
}

Future<void> settleConfirm(PairingStack stack) =>
    waitUntil(() => !stack.coordinator.busy, reason: '${stack.name} idle');
