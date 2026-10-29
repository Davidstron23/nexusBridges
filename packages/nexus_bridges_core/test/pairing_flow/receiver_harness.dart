import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:basic_utils/basic_utils.dart';
import 'package:nexus_bridges_core/src/identity/certificate_builder.dart';
import 'package:nexus_bridges_core/src/identity/certificate_parser.dart';
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

final InternetAddress thirdLoopback = InternetAddress('127.0.0.3');

final String _sep = Platform.pathSeparator;

final class RawReply {
  RawReply(this.status, this.body);

  final int status;
  final Uint8List body;

  String get text => utf8.decode(body);

  Map<String, Object?> get json => jsonDecode(text) as Map<String, Object?>;

  String? get state => json['state'] as String?;
}

typedef RouteWrapper = Future<ApiReply> Function(
  ApiCall call,
  Future<ApiReply> Function(ApiCall call) inner,
);

final class ExclusiveLock {
  ExclusiveLock(File file) : _handle = file.openSync(mode: FileMode.append) {
    _handle.lockSync(FileLock.exclusive);
  }

  final RandomAccessFile _handle;
  bool _held = true;

  void release() {
    if (!_held) return;
    _held = false;
    _handle.unlockSync();
    _handle.closeSync();
  }
}

ExclusiveLock lockFile(File file) {
  final held = ExclusiveLock(file);
  addTearDown(held.release);
  return held;
}

final class TimerTracker {
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

Future<Directory> temporaryDirectory() async {
  final dir = await Directory.systemTemp.createTemp('nexus_receiver_');
  addTearDown(() async {
    for (var attempt = 0; attempt < 20; attempt++) {
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

Future<void> eventually(
  bool Function() condition, {
  Duration? limit,
  String reason = 'condition',
}) async {
  final span = limit ?? scaled(waitLimit);
  final stopwatch = Stopwatch()..start();
  while (!condition()) {
    if (stopwatch.elapsed > span) fail('$reason not met within $span');
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}

bool fileLacks(File file, String text) {
  try {
    return file.existsSync() && !file.readAsStringSync().contains(text);
  } on FileSystemException {
    return false;
  }
}

Future<void> settle([Duration span = const Duration(milliseconds: 80)]) =>
    Future<void>.delayed(span);

bool showsNewPairing(PairingView? view, {required String peer}) =>
    view != null &&
    view.phase == PairingPhase.finished &&
    view.outcome == PairingOutcome.paired &&
    view.isNew &&
    view.peerFingerprint == peer;

final class ReceiverFixture {
  ReceiverFixture._(
    this.identity,
    this.dataDir,
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
  final Directory dataDir;
  final File pairedFile;
  final File ignoredFile;
  final PairedDevicesStore paired;
  late final IgnoredDevicesStore ignored;
  late final PairingCoordinator coordinator;
  ApiServer? _server;
  late final ActiveInterface primary;
  ActiveInterface? secondary;
  DateTime now = DateTime.utc(2026, 10, 24, 9);
  final Map<String, int> handled = {};
  final Map<String, RouteWrapper> wrappers = {};
  final List<PairingEvent> events = [];
  final List<PairingView?> views = [];
  final List<bool> busyStates = [];
  final List<String> logs = [];
  bool changesClosed = false;
  bool eventsClosed = false;

  ApiServer get server => _server!;

  int get port => server.boundPort!;

  PairingView? get view => coordinator.view;

  int handledOn(String path) => handled[path] ?? 0;

  static Future<ReceiverFixture> start({
    required DeviceIdentity identity,
    Iterable<DeviceIdentity> pairedWith = const [],
    Directory? dataDir,
    Duration pollHold = const Duration(milliseconds: 200),
    Duration saveTimeout = Limits.pairingMessageTimeout,
    Duration tickInterval = const Duration(milliseconds: 10),
    bool twoInterfaces = false,
    bool ticking = true,
  }) async {
    final dir = dataDir ?? await temporaryDirectory();
    final fixture = ReceiverFixture._(
      identity,
      dir,
      File('${dir.path}${_sep}paired.json'),
      File('${dir.path}${_sep}ignored.json'),
    );
    await fixture.paired.load();
    await fixture.ignored.load();
    if (pairedWith.isNotEmpty) {
      await fixture.paired.replaceAll([
        for (final peer in pairedWith) pairedDeviceOf(peer),
      ]);
    }
    fixture.coordinator = PairingCoordinator(
      identity: identity,
      paired: fixture.paired,
      ignored: fixture.ignored,
      selfInfo: () => selfInfoOf(identity),
      now: () => fixture.now,
      tickInterval: tickInterval,
      pollHold: pollHold,
      saveTimeout: saveTimeout,
      log: fixture.logs.add,
    );
    fixture.coordinator.changes.listen((_) {
      fixture.views.add(fixture.coordinator.view);
      fixture.busyStates.add(fixture.coordinator.busy);
    }, onDone: () => fixture.changesClosed = true);
    fixture.coordinator.events.listen(
      fixture.events.add,
      onDone: () => fixture.eventsClosed = true,
    );
    fixture.primary = loopbackInterface();
    final interfaces = [fixture.primary];
    if (twoInterfaces) {
      final second = loopbackInterface(
        adapterId: 'second',
        address: '127.0.0.2',
      );
      fixture.secondary = second;
      interfaces.add(second);
    }
    addTearDown(fixture.close);
    for (var attempt = 0; ; attempt++) {
      final port = twoInterfaces
          ? await freePortOn([loopback, otherLoopback])
          : 0;
      final server = ApiServer(
        identity: identity,
        paired: fixture.paired,
        routes: [
          for (final route in fixture.coordinator.routes) fixture._wrap(route),
        ],
        selfInfo: () => selfInfoOf(identity),
        onRegistered: (_, _, _) {},
        port: port,
        now: () => fixture.now,
        log: fixture.logs.add,
      );
      await server.syncInterfaces(interfaces);
      if (server.openInterfaceIds.length == interfaces.length) {
        fixture._server = server;
        break;
      }
      await server.close();
      if (attempt == 10) fail('could not open every listener');
    }
    if (ticking) fixture.coordinator.start();
    return fixture;
  }

  Future<void> close() async {
    await coordinator.close();
    await _server?.close();
  }

  void advance(Duration span) {
    now = now.add(span);
  }

  Future<void> pairWith(Iterable<DeviceIdentity> peers) async {
    await paired.replaceAll([
      ...paired.devices,
      for (final peer in peers) pairedDeviceOf(peer),
    ]);
    await server.rebuildTrust();
  }

  RawInitiator initiator(
    DeviceIdentity identity, {
    InternetAddress? from,
    InternetAddress? to,
  }) => RawInitiator(identity, this, from: from, to: to);

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

Future<RawReply?> rawPost(
  ReceiverFixture fixture,
  String path,
  Object? json, {
  InternetAddress? from,
  InternetAddress? to,
  SecurityContext? context,
  Duration timeout = const Duration(seconds: 15),
}) async {
  final response = await postJson(
    address: to ?? loopback,
    port: fixture.port,
    path: path,
    json: json,
    context: context ?? anonymousContext,
    acceptServer: (certificate) {
      try {
        return fingerprintOfCertificate(certificate.der) ==
            fixture.identity.fingerprint;
      } catch (_) {
        return false;
      }
    },
    sourceAddress: from ?? loopback,
    timeout: timeout,
    maxResponseBytes: Limits.maxPairingBodyBytes,
  );
  return response == null ? null : RawReply(response.status, response.body);
}

final class RawInitiator {
  RawInitiator(
    this.identity,
    this.fixture, {
    InternetAddress? from,
    InternetAddress? to,
  }) : from = from ?? loopback,
       to = to ?? loopback;

  final DeviceIdentity identity;
  final ReceiverFixture fixture;
  final InternetAddress from;
  final InternetAddress to;
  final Uint8List ni = randomBytes(nonceLength);
  late final Uint8List ci = commitmentOf(
    role: PairingRole.initiator,
    fingerprint: identity.fingerprint,
    nonce: ni,
  );
  Uint8List? startT;
  Uint8List? session;
  Uint8List? cr;
  Uint8List? nr;

  String get fingerprint => identity.fingerprint;

  Map<String, Object?> startBody({
    String? name = 'Laptop',
    DeviceType deviceType = DeviceType.desktop,
    String? receiverFingerprint,
    String? certificatePem,
    String? signerFingerprint,
    Uint8List Function(List<int> data)? sign,
  }) {
    final transcript = startTranscript(
      initiatorFingerprint: signerFingerprint ?? identity.fingerprint,
      receiverFingerprint: receiverFingerprint ?? fixture.identity.fingerprint,
      name: name,
      deviceType: deviceType,
      initiatorCommitment: ci,
    );
    startT = transcript;
    return StartRequest(
      certificate: certificatePem ?? identity.certificatePem,
      name: name,
      deviceType: deviceType,
      commitment: ci,
      proof: (sign ?? identity.sign)(transcript),
    ).toJson();
  }

  Future<RawReply?> start({
    String? name = 'Laptop',
    DeviceType deviceType = DeviceType.desktop,
    String? receiverFingerprint,
    String? certificatePem,
    String? signerFingerprint,
    Uint8List Function(List<int> data)? sign,
    Map<String, Object?> Function(Map<String, Object?> body)? edit,
    InternetAddress? from,
  }) async {
    var body = startBody(
      name: name,
      deviceType: deviceType,
      receiverFingerprint: receiverFingerprint,
      certificatePem: certificatePem,
      signerFingerprint: signerFingerprint,
      sign: sign,
    );
    if (edit != null) body = edit(body);
    final reply = await post(ApiPaths.pairStart, body, from: from);
    if (reply != null && reply.status == 200) {
      final parsed = StartReply.tryParse(reply.json);
      if (parsed != null) {
        session = parsed.session;
        cr = parsed.commitment;
      }
    }
    return reply;
  }

  Uint8List revealSignature({Uint8List? sessionId, Uint8List? nonce}) =>
      identity.sign(
        revealTranscript(
          startTranscript: startT!,
          sessionId: sessionId ?? session!,
          receiverCommitment: cr!,
          initiatorNonce: nonce ?? ni,
        ),
      );

  Future<RawReply?> reveal({
    Uint8List? nonce,
    Uint8List? signature,
    InternetAddress? from,
    InternetAddress? to,
  }) async {
    final reply = await post(
      ApiPaths.pairReveal,
      RevealRequest(
        session: session!,
        nonce: nonce ?? ni,
        signature: signature ?? revealSignature(nonce: nonce),
      ).toJson(),
      from: from,
      to: to,
    );
    if (reply != null && reply.status == 200) {
      nr = RevealReply.tryParse(reply.json)?.nonce;
    }
    return reply;
  }

  Future<void> begin({String? name = 'Laptop'}) async {
    final started = await start(name: name);
    expect(started?.status, 200, reason: 'pair/start');
    final revealed = await reveal();
    expect(revealed?.status, 200, reason: 'pair/reveal');
  }

  Future<RawReply?> wait({InternetAddress? from, InternetAddress? to}) => post(
    ApiPaths.pairWait,
    SessionRequest(session: session!).toJson(),
    from: from,
    to: to,
  );

  Future<RawReply?> confirm({InternetAddress? from, InternetAddress? to}) =>
      post(
        ApiPaths.pairConfirm,
        SessionRequest(session: session!).toJson(),
        from: from,
        to: to,
      );

  Future<RawReply?> cancel(
    CancelReason reason, {
    InternetAddress? from,
    InternetAddress? to,
  }) => post(
    ApiPaths.pairCancel,
    CancelRequest(session: session!, reason: reason).toJson(),
    from: from,
    to: to,
  );

  String get code => pairingCode(
    initiatorFingerprint: identity.fingerprint,
    receiverFingerprint: fixture.identity.fingerprint,
    initiatorNonce: ni,
    receiverNonce: nr!,
  );

  Future<RawReply?> post(
    String path,
    Object? json, {
    InternetAddress? from,
    InternetAddress? to,
  }) =>
      rawPost(fixture, path, json, from: from ?? this.from, to: to ?? this.to);
}

Uint8List _fixedBytes(BigInt value) =>
    fromHex(value.toRadixString(16).padLeft(64, '0'), 32)!;

Uint8List signWithKey(ECPrivateKey privateKey, List<int> data) {
  final signature = CryptoUtils.ecSign(
    privateKey,
    Uint8List.fromList(data),
    algorithmName: 'SHA-256/ECDSA',
  );
  return Uint8List.fromList([
    ..._fixedBytes(signature.r),
    ..._fixedBytes(signature.s),
  ]);
}

Uint8List randomSerial() {
  final serial = randomBytes(16);
  serial[0] = 0x42;
  return serial;
}

final class HandMadeCertificate {
  HandMadeCertificate._(this.pem, this.privateKey, this.fingerprint);

  factory HandMadeCertificate(
    String commonName, {
    bool utf8CommonName = false,
  }) {
    final pair = CryptoUtils.generateEcKeyPair();
    final privateKey = pair.privateKey as ECPrivateKey;
    final publicKey = pair.publicKey as ECPublicKey;
    final pem = buildSelfSignedCertificatePem(
      privateKey: privateKey,
      publicKey: publicKey,
      commonName: commonName,
      serialNumber: randomSerial(),
      utf8CommonName: utf8CommonName,
    );
    final valid = buildSelfSignedCertificatePem(
      privateKey: privateKey,
      publicKey: publicKey,
      commonName: commonNameForSpki(spkiOf(publicKey)),
      serialNumber: randomSerial(),
    );
    final fingerprint = fingerprintOfCertificate(
      CryptoUtils.getBytesFromPEMString(valid),
    );
    return HandMadeCertificate._(pem, privateKey, fingerprint);
  }

  final String pem;
  final ECPrivateKey privateKey;
  final String fingerprint;

  Uint8List sign(List<int> data) => signWithKey(privateKey, data);

  DeviceIdentity? get identity => DeviceIdentity.fromPem(
    certificatePem: pem,
    privateKeyPem: CryptoUtils.encodeEcPrivateKeyToPem(privateKey),
  );
}
