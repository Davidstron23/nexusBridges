import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:nexus_bridges_core/src/identity/identity.dart';
import 'package:nexus_bridges_core/src/network/network.dart';
import 'package:nexus_bridges_core/src/pairing/pairing.dart';
import 'package:nexus_bridges_core/src/pairing_flow/crypto.dart';
import 'package:nexus_bridges_core/src/pairing_flow/messages.dart';
import 'package:nexus_bridges_core/src/pairing_flow/pairing_flow.dart';
import 'package:nexus_bridges_core/src/protocol/protocol.dart';
import 'package:nexus_bridges_core/src/server/server.dart';
import 'package:nexus_bridges_core/src/storage/storage.dart';
import 'package:nexus_bridges_core/src/transport/transport.dart';
import 'package:test/test.dart';

import '../support/infra.dart';
import '../server/api_server_harness.dart';

final InternetAddress hostA = InternetAddress('127.0.0.1');
final InternetAddress hostB = InternetAddress('127.0.0.2');
final InternetAddress hostM = InternetAddress('127.0.0.3');

final String _sep = Platform.pathSeparator;

typedef StackWrapper = Future<ApiReply> Function(
  ApiCall call,
  Future<ApiReply> Function(ApiCall call) inner,
);

typedef Answer = (int, Map<String, Object?>);

typedef FaceHandler = FutureOr<Answer> Function(Map<String, Object?> body);

final class TestClock {
  DateTime now = DateTime.utc(2026, 10, 24, 9);

  void advance(Duration span) => now = now.add(span);
}

Future<void> until(
  bool Function() condition, {
  Duration? limit,
  String reason = 'condition',
}) async {
  final span = limit ?? scaled(const Duration(seconds: 8));
  final stopwatch = Stopwatch()..start();
  while (!condition()) {
    if (stopwatch.elapsed > span) fail('$reason not met within $span');
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}

Future<void> idleFor([Duration span = const Duration(milliseconds: 150)]) =>
    Future<void>.delayed(span);

Future<Directory> attackFolder() async {
  final dir = await Directory.systemTemp.createTemp('nexus_attacks_');
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

bool acceptsOnly(String fingerprint, X509Certificate certificate) {
  try {
    return fingerprintOfCertificate(certificate.der) == fingerprint;
  } catch (_) {
    return false;
  }
}

final class Stack {
  Stack._(
    this.identity,
    this.name,
    this.address,
    this.pairedFile,
    this.ignoredFile,
  ) : paired = PairedDevicesStore(
        JsonFileStore(pairedFile),
        ownerFingerprint: identity.fingerprint,
      ) {
    ignored = IgnoredDevicesStore(
      JsonFileStore(ignoredFile),
      isPaired: paired.isPaired,
    );
  }

  final DeviceIdentity identity;
  final String name;
  final InternetAddress address;
  final File pairedFile;
  final File ignoredFile;
  final PairedDevicesStore paired;
  late final IgnoredDevicesStore ignored;
  late final PairingCoordinator coordinator;
  late final ApiServer server;
  late final ActiveInterface iface;
  final TestClock clock = TestClock();
  final Map<String, int> handled = {};
  final Map<String, StackWrapper> wrappers = {};
  final List<PairingEvent> events = [];
  final List<PairingView?> views = [];
  final List<String> logs = [];
  Future<void> _trust = Future<void>.value();
  int trustRebuilds = 0;

  String get fingerprint => identity.fingerprint;

  int get port => server.boundPort!;

  PairingView? get view => coordinator.view;

  bool get idle => !coordinator.busy;

  int handledOn(String path) => handled[path] ?? 0;

  int get handledTotal => handled.values.fold(0, (sum, n) => sum + n);

  Iterable<String?> get shownCodes => views
      .where(
        (v) =>
            v != null &&
            (v.phase == PairingPhase.comparing ||
                v.phase == PairingPhase.waitingPeer),
      )
      .map((v) => v!.code);

  List<PairingCompleted> get completions =>
      events.whereType<PairingCompleted>().toList();

  List<PairingAttemptRejected> get rejectedAttempts =>
      events.whereType<PairingAttemptRejected>().toList();

  static Future<Stack> start({
    required String name,
    required InternetAddress address,
    DeviceIdentity? identity,
    bool autoTrust = true,
    Duration pollHold = const Duration(milliseconds: 200),
    Duration tickInterval = const Duration(milliseconds: 10),
  }) async {
    final dir = await attackFolder();
    final stack = Stack._(
      identity ?? DeviceIdentity.generate(),
      name,
      address,
      File('${dir.path}${_sep}paired.json'),
      File('${dir.path}${_sep}ignored.json'),
    );
    await stack.paired.load();
    await stack.ignored.load();
    stack.coordinator = PairingCoordinator(
      identity: stack.identity,
      paired: stack.paired,
      ignored: stack.ignored,
      selfInfo: () => DeviceInfo(
        name: name,
        fingerprint: stack.identity.fingerprint,
        port: defaultPort,
        protocol: protocolVersion,
        deviceType: DeviceType.desktop,
      ),
      now: () => stack.clock.now,
      tickInterval: tickInterval,
      pollHold: pollHold,
      log: stack.logs.add,
    );
    stack.coordinator.changes.listen(
      (_) => stack.views.add(stack.coordinator.view),
    );
    stack.coordinator.events.listen(stack.events.add);
    stack.iface = loopbackInterface(
      adapterId: 'attack-${address.address}',
      address: address.address,
    );
    addTearDown(stack.close);
    for (var attempt = 0; ; attempt++) {
      final server = ApiServer(
        identity: stack.identity,
        paired: stack.paired,
        routes: [
          for (final route in stack.coordinator.routes) stack._wrap(route),
        ],
        selfInfo: () => selfInfoOf(stack.identity),
        onRegistered: (_, _, _) {},
        port: 0,
        now: () => stack.clock.now,
        log: stack.logs.add,
      );
      await server.syncInterfaces([stack.iface]);
      if (server.openInterfaceIds.length == 1) {
        stack.server = server;
        break;
      }
      await server.close();
      if (attempt == 10) fail('could not open the listener of $name');
    }
    if (autoTrust) {
      stack.paired.changes.listen((_) {
        stack.trustRebuilds++;
        stack._trust = stack._trust.then((_) => stack.server.rebuildTrust());
      });
    }
    stack.coordinator.start();
    return stack;
  }

  Future<void> trustSettled() async {
    await idleFor(const Duration(milliseconds: 20));
    await _trust;
  }

  PairingTarget targetOf(Stack other) => targetAt(
    other.address,
    other.port,
    fingerprint: other.fingerprint,
    name: other.name,
  );

  PairingTarget targetAt(
    InternetAddress remote,
    int remotePort, {
    required String fingerprint,
    String? name,
  }) => PairingTarget(
    fingerprint: fingerprint,
    name: name,
    address: remote,
    port: remotePort,
    interfaceId: iface.id,
    localAddress: address,
  );

  void probeUnpair() {
    wrappers[ApiPaths.unpair] = (call, inner) async =>
        const ApiReply(200, {'probe': true});
  }

  Future<List<PairedDevice>> reloadPaired() async {
    final store = PairedDevicesStore(
      JsonFileStore(pairedFile),
      ownerFingerprint: identity.fingerprint,
    );
    await store.load();
    return store.devices;
  }

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
      handled.update(route.path, (n) => n + 1, ifAbsent: () => 1);
      final wrapper = wrappers[route.path];
      return wrapper == null ? route.handle(call) : wrapper(call, route.handle);
    },
  );
}

Future<HttpsResponse?> postTo(
  Stack target,
  String path, {
  required InternetAddress from,
  Object? json = const <String, Object?>{},
  SecurityContext? context,
  Duration timeout = const Duration(seconds: 5),
}) => postJson(
  address: target.address,
  port: target.port,
  path: path,
  json: json,
  context: context ?? anonymousContext,
  acceptServer: (certificate) => acceptsOnly(target.fingerprint, certificate),
  sourceAddress: from,
  timeout: timeout,
  maxResponseBytes: Limits.maxPairingBodyBytes,
);

Map<String, Object?> bodyOf(HttpsResponse response) =>
    jsonDecode(utf8.decode(response.body)) as Map<String, Object?>;

Uint8List chosenAfter(List<List<int>> seen) {
  final builder = BytesBuilder(copy: false);
  for (final part in seen) {
    builder.add(part);
  }
  return Uint8List.fromList(sha256.convert(builder.toBytes()).bytes);
}

final class ForgedInitiator {
  ForgedInitiator(this.identity, this.receiver, {InternetAddress? from})
    : from = from ?? hostM;

  final DeviceIdentity identity;
  final Stack receiver;
  final InternetAddress from;
  Uint8List nonce = randomBytes(nonceLength);
  Uint8List? commitment;
  Uint8List? startT;
  Uint8List? session;
  Uint8List? cr;
  Uint8List? nr;

  Future<HttpsResponse?> start({String? name, Uint8List? commitWith}) async {
    final ci =
        commitWith ??
        commitmentOf(
          role: PairingRole.initiator,
          fingerprint: identity.fingerprint,
          nonce: nonce,
        );
    commitment = ci;
    final transcript = startTranscript(
      initiatorFingerprint: identity.fingerprint,
      receiverFingerprint: receiver.fingerprint,
      name: name,
      deviceType: DeviceType.desktop,
      initiatorCommitment: ci,
    );
    startT = transcript;
    final response = await post(
      ApiPaths.pairStart,
      StartRequest(
        certificate: identity.certificatePem,
        name: name,
        deviceType: DeviceType.desktop,
        commitment: ci,
        proof: identity.sign(transcript),
      ).toJson(),
    );
    if (response != null && response.status == 200) {
      final parsed = StartReply.tryParse(bodyOf(response));
      session = parsed?.session;
      cr = parsed?.commitment;
    }
    return response;
  }

  Future<HttpsResponse?> reveal({Uint8List? revealed}) async {
    final shown = revealed ?? nonce;
    final response = await post(
      ApiPaths.pairReveal,
      RevealRequest(
        session: session!,
        nonce: shown,
        signature: identity.sign(
          revealTranscript(
            startTranscript: startT!,
            sessionId: session!,
            receiverCommitment: cr!,
            initiatorNonce: shown,
          ),
        ),
      ).toJson(),
    );
    if (response != null && response.status == 200) {
      nr = RevealReply.tryParse(bodyOf(response))?.nonce;
    }
    return response;
  }

  Future<HttpsResponse?> confirm() =>
      post(ApiPaths.pairConfirm, SessionRequest(session: session!).toJson());

  Future<HttpsResponse?> wait() =>
      post(ApiPaths.pairWait, SessionRequest(session: session!).toJson());

  Future<HttpsResponse?> cancel(CancelReason reason) => post(
    ApiPaths.pairCancel,
    CancelRequest(session: session!, reason: reason).toJson(),
  );

  String get code => pairingCode(
    initiatorFingerprint: identity.fingerprint,
    receiverFingerprint: receiver.fingerprint,
    initiatorNonce: nonce,
    receiverNonce: nr!,
  );

  Future<HttpsResponse?> post(String path, Object? json) =>
      postTo(receiver, path, from: from, json: json);
}

final class FaceCall {
  FaceCall(this.path, this.body);

  final String path;
  final Map<String, Object?> body;
}

final class FakeFace {
  FakeFace._(this.identity, this.server);

  final DeviceIdentity identity;
  final HttpServer server;
  final Uint8List session = randomBytes(sessionIdLength);
  Uint8List nonce = randomBytes(nonceLength);
  final Map<String, FaceHandler> handlers = {};
  final List<FaceCall> calls = [];
  String waitState = 'pending';

  int get port => server.port;

  String get fingerprint => identity.fingerprint;

  Uint8List get commitment => commitmentOf(
    role: PairingRole.receiver,
    fingerprint: identity.fingerprint,
    nonce: nonce,
  );

  int count(String path) => calls.where((c) => c.path == path).length;

  List<FaceCall> callsTo(String path) =>
      calls.where((c) => c.path == path).toList();

  static Future<FakeFace> start({InternetAddress? address}) async {
    final identity = DeviceIdentity.generate();
    final server = await HttpServer.bindSecure(
      address ?? hostM,
      0,
      identity.serverContext(trustedCertificatesPem: const []),
    );
    final face = FakeFace._(identity, server);
    server.listen((request) => unawaited(face._serve(request)));
    addTearDown(() => server.close(force: true));
    return face;
  }

  Answer _default(String path, Map<String, Object?> body) => switch (path) {
    ApiPaths.pairStart => (
      200,
      StartReply(session: session, commitment: commitment).toJson(),
    ),
    ApiPaths.pairReveal => (200, RevealReply(nonce: nonce).toJson()),
    ApiPaths.pairWait => (200, {'state': waitState}),
    ApiPaths.pairConfirm => (200, {'state': 'pending'}),
    ApiPaths.pairCancel => (
      200,
      {'state': body['reason'] == 'expired' ? 'expired' : 'cancelled'},
    ),
    _ => (404, {'error': 'not_found'}),
  };

  Future<void> _serve(HttpRequest request) async {
    try {
      final path = request.uri.path;
      final text = await utf8.decoder.bind(request).join();
      Object? decoded;
      try {
        decoded = jsonDecode(text);
      } on FormatException {
        decoded = null;
      }
      final body = decoded is Map<String, Object?>
          ? decoded
          : <String, Object?>{};
      calls.add(FaceCall(path, body));
      if (path == ApiPaths.pairWait) {
        await Future<void>.delayed(const Duration(milliseconds: 40));
      }
      final handler = handlers[path];
      final (status, json) = handler == null
          ? _default(path, body)
          : await handler(body);
      final bytes = utf8.encode(jsonEncode(json));
      final response = request.response
        ..persistentConnection = false
        ..statusCode = status
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

Uint8List hexField(Map<String, Object?> body, String field, int length) =>
    fromHex(body[field]! as String, length)!;

Future<void> pairThroughFlow(Stack initiator, Stack receiver) async {
  final before = (initiator.completions.length, receiver.completions.length);
  expect(
    initiator.coordinator.tryPair(initiator.targetOf(receiver)),
    PairStart.started,
  );
  await until(
    () =>
        initiator.view?.phase == PairingPhase.comparing &&
        receiver.view?.phase == PairingPhase.comparing,
    reason: 'both comparing',
  );
  expect(initiator.view!.code, receiver.view!.code);
  receiver.coordinator.answerAsReceiver(ReceiverAnswer.matches);
  initiator.coordinator.answerAsInitiator(matches: true);
  await until(
    () =>
        initiator.completions.length > before.$1 &&
        receiver.completions.length > before.$2 &&
        initiator.idle &&
        receiver.idle,
    reason: 'pairing completed on both',
  );
  await initiator.trustSettled();
  await receiver.trustSettled();
}
