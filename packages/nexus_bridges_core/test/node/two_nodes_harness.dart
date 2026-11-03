import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:nexus_bridges_core/src/discovery/discovery.dart';
import 'package:nexus_bridges_core/src/identity/identity.dart';
import 'package:nexus_bridges_core/src/network/network.dart';
import 'package:nexus_bridges_core/src/node/node.dart';
import 'package:nexus_bridges_core/src/pairing/pairing.dart';
import 'package:nexus_bridges_core/src/pairing_flow/pairing_flow.dart';
import 'package:nexus_bridges_core/src/protocol/protocol.dart';
import 'package:nexus_bridges_core/src/server/server.dart';
import 'package:nexus_bridges_core/src/storage/storage.dart';
import 'package:nexus_bridges_core/src/transport/transport.dart';
import 'package:test/test.dart';

import '../support/infra.dart';

final InternetAddress hostA = InternetAddress('127.0.0.1');
final InternetAddress hostB = InternetAddress('127.0.0.2');

const String homeNetwork = '{NETWORK-HOME}';
const String otherNetwork = '{NETWORK-OTHER}';
const String testAdapter = '{TEST-ADAPTER}';

const Duration waitLimit = Duration(seconds: 10);
const Duration slowPoll = Duration(minutes: 1);
const Duration fastPoll = Duration(milliseconds: 50);
const Duration rarePresent = Duration(hours: 1);
const Timeout twoNodesTimeout = Timeout(Duration(minutes: 2));

final String sep = Platform.pathSeparator;

String? _loopbackName;

Future<String> loopbackName() async {
  final known = _loopbackName;
  if (known != null) return known;
  final all = await NetworkInterface.list(includeLoopback: true);
  return _loopbackName = all
      .firstWhere((i) => i.addresses.any((a) => a.address == '127.0.0.1'))
      .name;
}

final class XorProtector implements SecretProtector {
  static Uint8List _xor(Uint8List data) =>
      Uint8List.fromList([for (final b in data) b ^ 0x5A]);

  @override
  Uint8List protect(Uint8List data) => _xor(data);

  @override
  Uint8List? unprotect(Uint8List data) => _xor(data);
}

AdapterInfo adapterOn(String networkId) => AdapterInfo(
  id: testAdapter,
  friendlyName: 'Wi-Fi',
  description: 'Test adapter',
  ifType: 71,
  isUp: true,
  ipv4: [Ipv4Subnet(InternetAddress('192.168.77.10'), 24)],
  hasGateway: true,
  networkId: networkId,
  networkName: networkId == homeNetwork ? 'Home' : 'Other',
);

Future<int> freePort() =>
    pickPort(tcp: [hostA, hostB], udp: [InternetAddress.anyIPv4]);

Future<void> eventually(
  FutureOr<bool> Function() condition, {
  Duration? limit,
  String reason = 'condition',
}) async {
  final span = limit ?? scaled(waitLimit);
  final stopwatch = Stopwatch()..start();
  while (!await condition()) {
    if (stopwatch.elapsed > span) fail('$reason not met within $span');
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}

Future<void> pause([Duration span = const Duration(milliseconds: 300)]) =>
    Future<void>.delayed(span);

Future<void> _deleteQuietly(Directory dir) async {
  for (var attempt = 0; attempt < 40; attempt++) {
    try {
      if (dir.existsSync()) await dir.delete(recursive: true);
      return;
    } on FileSystemException {
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
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

  int get created => _timers.length;

  int createdBy(String frame) =>
      _timers.where((entry) => entry.$2.contains(frame)).length;

  List<String> get active => [
    for (final (timer, trace) in _timers)
      if (timer.isActive) trace,
  ];

  int activeBy(String file) =>
      active.where((trace) => trace.contains(file)).length;
}

final class HeldLock {
  HeldLock._(this._handle);

  final RandomAccessFile _handle;
  bool _held = true;

  static HeldLock on(File file) {
    file.parent.createSync(recursive: true);
    final handle = file.openSync(mode: FileMode.append);
    handle.lockSync(FileLock.exclusive);
    final lock = HeldLock._(handle);
    addTearDown(lock.release);
    return lock;
  }

  String read() {
    _handle.setPositionSync(0);
    return utf8.decode(_handle.readSync(_handle.lengthSync()));
  }

  void release() {
    if (!_held) return;
    _held = false;
    try {
      _handle.unlockSync();
    } catch (_) {}
    _handle.closeSync();
  }
}

final class TestNode {
  TestNode._(this.address, this.root, this.deviceName);

  final InternetAddress address;
  final Directory root;
  String deviceName;
  int port = 0;
  int udpPort = 0;
  final List<String> logs = [];
  final List<NodeState> states = [];
  final ZoneTimers timers = ZoneTimers();
  late final Zone zone = Zone.current.fork(specification: timers.specification);
  List<AdapterInfo> adapters = [adapterOn(homeNetwork)];
  DateTime clock = DateTime(2026, 10, 24, 12);
  Duration elapsed = Duration.zero;
  Duration presentInterval = rarePresent;
  Duration pollInterval = slowPoll;
  Duration pollHold = const Duration(milliseconds: 300);
  SecretProtector protector = XorProtector();
  Directory? dataDirOverride;
  MulticastChannel? channel;
  NexusNode? _node;

  static Future<TestNode> create(
    String deviceName,
    InternetAddress address,
  ) async {
    final root = await Directory.systemTemp.createTemp('nexus_two_nodes_');
    addTearDown(() => _deleteQuietly(root));
    return TestNode._(address, root, deviceName);
  }

  NexusNode get node => _node!;

  NodeState get state => node.state;

  String get fingerprint => state.fingerprint;

  Directory get dataDir =>
      dataDirOverride ?? Directory('${root.path}${sep}data');

  File get pairedFile => File('${dataDir.path}${sep}paired.json');

  String get ifaceId => '$testAdapter#${address.address}';

  String get shortFingerprint => fingerprint.substring(0, 8);

  String get label => '$deviceName \u00B7 $shortFingerprint';

  DateTime now() => clock;

  Duration monotonic() => elapsed;

  void advance(Duration span) {
    clock = clock.add(span);
    elapsed += span;
  }

  Future<T> inZone<T>(Future<T> Function() action) => zone.run(action);

  Future<NexusNode> boot() async {
    final loopback = await loopbackName();
    final udp = udpPort = await freePort();
    final channel = this.channel = MulticastChannel(port: udp, log: logs.add);
    final node = await zone.run(
      () => NexusNode.start(
        dataDir: dataDir,
        protector: protector,
        readNetworks: () async => adapters,
        port: port,
        deviceName: deviceName,
        now: now,
        monotonic: monotonic,
        presentInterval: presentInterval,
        log: logs.add,
        activeOf: (states) => [
          for (final state in states)
            if (state.status == InterfaceStatus.active)
              ActiveInterface(
                id: ifaceId,
                adapterId: state.adapter.id,
                friendlyName: loopback,
                subnet: Ipv4Subnet(address, 30),
              ),
        ],
        pollInterval: pollInterval,
        channel: channel,
        pairingTickInterval: const Duration(milliseconds: 20),
        pairingPollHold: pollHold,
      ),
    );
    _node = node;
    addTearDown(node.shutdown);
    final subscription = node.states.listen(states.add);
    addTearDown(subscription.cancel);
    return node;
  }

  Future<bool> launch() async {
    final before = logs.length;
    final node = await boot();
    if (node.state.identityStatus == IdentityStatus.failed) return false;
    return listenSince(before);
  }

  Future<bool> listenSince(int before) async {
    await zone.run(
      () => node.decideNetwork(homeNetwork, NetworkDecision.trusted),
    );
    final stopwatch = Stopwatch()..start();
    while (stopwatch.elapsed < scaled(waitLimit)) {
      if (state.portInUse != null) return false;
      final recent = logs.skip(before);
      if (recent.contains('listening on $ifaceId')) return true;
      if (recent.any((line) => line.startsWith('interface bind failed'))) {
        return false;
      }
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    return false;
  }

  Future<void> restart({String? deviceName}) async {
    await node.shutdown();
    if (deviceName != null) this.deviceName = deviceName;
    for (var attempt = 0; attempt < 10; attempt++) {
      if (await launch()) return;
      await node.shutdown();
      await pause(const Duration(milliseconds: 200));
    }
    fail('restart of ${this.deviceName} on port $port');
  }

  int get checksStarted => timers.createdBy('NexusNode._checkPeer');

  Future<NodeState> until(
    bool Function(NodeState s) condition, {
    Duration? limit,
    String reason = 'state',
  }) async {
    await eventually(() => condition(node.state), limit: limit, reason: reason);
    return node.state;
  }

  DeviceEntry? entryOf(String fingerprint) {
    for (final entry in state.entries) {
      if (entry.fingerprint == fingerprint) return entry;
    }
    return null;
  }

  bool sees(TestNode other) =>
      state.devices.any((d) => d.info.fingerprint == other.fingerprint);

  bool hasPaired(TestNode other) => entryOf(other.fingerprint)?.paired == true;

  Future<List<Map<String, Object?>>> savedPaired() async {
    if (!await pairedFile.exists()) return const [];
    final json = jsonDecode(await pairedFile.readAsString()) as Map;
    return [
      for (final device in json['devices'] as List)
        (device as Map).cast<String, Object?>(),
    ];
  }

  Future<List<String>> savedPairedFingerprints() async => [
    for (final device in await savedPaired()) device['fingerprint']! as String,
  ];

  Future<DeviceIdentity> loadIdentity() async {
    final loaded = await IdentityStore(
      dataDir: dataDir,
      protector: XorProtector(),
    ).loadOrCreate();
    return loaded.identity;
  }

  DeviceInfo get info => DeviceInfo(
    name: deviceName,
    fingerprint: fingerprint,
    port: port,
    protocol: protocolVersion,
    deviceType: DeviceType.desktop,
  );

  List<Notice> noticesOf(NoticeKind kind) => [
    for (final notice in state.notices)
      if (notice.kind == kind) notice,
  ];
}

Future<(TestNode, TestNode)> twoNodes({
  String nameA = 'Desk PC',
  String nameB = 'Laptop',
  Duration pollA = slowPoll,
  Duration pollB = slowPoll,
  Duration holdB = const Duration(milliseconds: 300),
  Duration present = rarePresent,
}) async {
  for (var attempt = 0; attempt < 5; attempt++) {
    final port = await freePort();
    final a = await TestNode.create(nameA, hostA);
    final b = await TestNode.create(nameB, hostB);
    a
      ..port = port
      ..pollInterval = pollA
      ..presentInterval = present;
    b
      ..port = port
      ..pollInterval = pollB
      ..presentInterval = present
      ..pollHold = holdB;
    final aUp = await a.launch();
    final bUp = aUp && await b.launch();
    if (aUp && bUp) return (a, b);
    if (a._node != null) await a.node.shutdown();
    if (b._node != null) await b.node.shutdown();
  }
  fail('could not start two nodes on a shared port');
}

Future<void> meet(TestNode a, TestNode b) async {
  for (var attempt = 0; attempt < 5; attempt++) {
    await a.inZone(() => a.node.rescan());
    if (!b.sees(a)) await b.inZone(() => b.node.rescan());
    final stopwatch = Stopwatch()..start();
    while (stopwatch.elapsed < scaled(const Duration(seconds: 3))) {
      if (a.sees(b) && b.sees(a)) return;
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
  }
  fail('the two nodes did not see each other');
}

Future<void> pairNodes(TestNode initiator, TestNode receiver) async {
  expect(
    await initiator.inZone(() => initiator.node.pair(receiver.fingerprint)),
    PairRequestResult.started,
  );
  await receiver.until(
    (s) => s.pairing?.phase == PairingPhase.comparing,
    reason: 'receiver comparing',
  );
  await initiator.until(
    (s) => s.pairing?.phase == PairingPhase.comparing,
    reason: 'initiator comparing',
  );
  expect(initiator.state.pairing!.code, receiver.state.pairing!.code);
  initiator.zone.run(() => initiator.node.answerCode(matches: true));
  receiver.zone.run(() => receiver.node.answerRequest(ReceiverAnswer.matches));
  await initiator.until(
    (s) => _settled(s.pairing) && initiator.hasPaired(receiver),
    reason: 'initiator paired',
  );
  await receiver.until(
    (s) => _settled(s.pairing) && receiver.hasPaired(initiator),
    reason: 'receiver paired',
  );
}

bool _settled(PairingView? view) =>
    view == null || view.outcome == PairingOutcome.paired;

Future<void> bothComparing(TestNode initiator, TestNode receiver) async {
  expect(
    await initiator.inZone(() => initiator.node.pair(receiver.fingerprint)),
    PairRequestResult.started,
  );
  await receiver.until(
    (s) => s.pairing?.phase == PairingPhase.comparing,
    reason: 'receiver comparing',
  );
  await initiator.until(
    (s) => s.pairing?.phase == PairingPhase.comparing,
    reason: 'initiator comparing',
  );
}

Future<int?> registerWith(
  DeviceIdentity caller,
  TestNode target, {
  required InternetAddress from,
  required String callerName,
  required int callerPort,
  bool presentCertificate = true,
}) async {
  final response = await postJson(
    address: target.address,
    port: target.port,
    path: ApiPaths.register,
    json: DeviceInfo(
      name: callerName,
      fingerprint: caller.fingerprint,
      port: callerPort,
      protocol: protocolVersion,
      deviceType: DeviceType.desktop,
    ).toJson(),
    context: caller.clientContext(presentCertificate: presentCertificate),
    acceptServer: (certificate) =>
        _fingerprintIs(certificate, target.fingerprint),
    sourceAddress: from,
    timeout: const Duration(seconds: 5),
  );
  return response?.status;
}

bool _fingerprintIs(X509Certificate certificate, String fingerprint) {
  try {
    return fingerprintOfCertificate(certificate.der) == fingerprint;
  } catch (_) {
    return false;
  }
}

final class OpenConnection {
  OpenConnection(this.closed);

  final Future<void> closed;
}

Future<OpenConnection> openTlsConnection(
  DeviceIdentity caller,
  TestNode target, {
  required InternetAddress from,
}) async {
  final raw = await Socket.connect(
    target.address,
    target.port,
    sourceAddress: from,
  );
  final secure = await SecureSocket.secure(
    raw,
    context: caller.clientContext(presentCertificate: true),
    onBadCertificate: (certificate) =>
        _fingerprintIs(certificate, target.fingerprint),
  );
  addTearDown(secure.destroy);
  final closed = Completer<void>();
  secure.listen(
    (_) {},
    onError: (Object _) {
      if (!closed.isCompleted) closed.complete();
    },
    onDone: () {
      if (!closed.isCompleted) closed.complete();
    },
    cancelOnError: true,
  );
  return OpenConnection(closed.future);
}

final class SilentListener {
  SilentListener._(this._server);

  final ServerSocket _server;
  final List<Socket> sockets = [];
  final List<Stopwatch> openFor = [];
  int closedByClient = 0;

  static Future<SilentListener> bind(InternetAddress address, int port) async {
    final server = await ServerSocket.bind(address, port);
    final listener = SilentListener._(server);
    addTearDown(listener.close);
    server.listen((socket) {
      listener.sockets.add(socket);
      final watch = Stopwatch()..start();
      listener.openFor.add(watch);
      socket.listen(
        (_) {},
        onError: (Object _) {
          watch.stop();
          listener.closedByClient++;
        },
        onDone: () {
          watch.stop();
          listener.closedByClient++;
        },
        cancelOnError: true,
      );
    });
    return listener;
  }

  int get accepted => sockets.length;

  Future<void> close() async {
    for (final socket in sockets) {
      socket.destroy();
    }
    await _server.close();
  }
}

final class CountingPeer {
  CountingPeer._(this.identity, this.address, this.port, this.dir);

  final DeviceIdentity identity;
  final InternetAddress address;
  final int port;
  final Directory dir;
  final Map<String, int> handled = {};
  final List<PairingEvent> events = [];
  late final PairedDevicesStore paired;
  late final IgnoredDevicesStore ignored;
  late final PairingCoordinator coordinator;
  late final ApiServer server;
  late final ActiveInterface iface;
  Future<void> _trust = Future<void>.value();

  String get fingerprint => identity.fingerprint;

  int handledOn(String path) => handled[path] ?? 0;

  static Future<CountingPeer?> start({
    required InternetAddress address,
    required int port,
    String name = 'Counting PC',
  }) async {
    final dir = await Directory.systemTemp.createTemp('nexus_counting_peer_');
    addTearDown(() => _deleteQuietly(dir));
    final peer = CountingPeer._(DeviceIdentity.generate(), address, port, dir);
    peer.paired = PairedDevicesStore(
      JsonFileStore(File('${dir.path}${sep}paired.json')),
      ownerFingerprint: peer.identity.fingerprint,
    );
    peer.ignored = IgnoredDevicesStore(
      JsonFileStore(File('${dir.path}${sep}ignored.json')),
      isPaired: peer.paired.isPaired,
    );
    await peer.paired.load();
    await peer.ignored.load();
    DeviceInfo selfInfo() => DeviceInfo(
      name: name,
      fingerprint: peer.identity.fingerprint,
      port: port,
      protocol: protocolVersion,
      deviceType: DeviceType.desktop,
    );
    peer.coordinator = PairingCoordinator(
      identity: peer.identity,
      paired: peer.paired,
      ignored: peer.ignored,
      selfInfo: selfInfo,
      tickInterval: const Duration(milliseconds: 20),
      pollHold: const Duration(milliseconds: 300),
    );
    peer.coordinator.events.listen(peer.events.add);
    peer.iface = ActiveInterface(
      id: 'counting#${address.address}',
      adapterId: 'counting',
      friendlyName: await loopbackName(),
      subnet: Ipv4Subnet(address, 30),
    );
    peer.server = ApiServer(
      identity: peer.identity,
      paired: peer.paired,
      selfInfo: selfInfo,
      onRegistered: (_, _, _) {},
      routes: [for (final route in peer.coordinator.routes) peer._count(route)],
      port: port,
    );
    addTearDown(peer.close);
    await peer.server.syncInterfaces([peer.iface]);
    if (peer.server.openInterfaceIds.length != 1) return null;
    peer.paired.changes.listen((_) {
      peer._trust = peer._trust.then((_) => peer.server.rebuildTrust());
    });
    peer.coordinator.start();
    return peer;
  }

  PairingTarget targetOf(TestNode node) => PairingTarget(
    fingerprint: node.fingerprint,
    name: node.deviceName,
    address: node.address,
    port: node.port,
    interfaceId: iface.id,
    localAddress: address,
  );

  Future<void> trustSettled() async {
    await pause(const Duration(milliseconds: 50));
    await _trust;
  }

  Future<void> close() async {
    await coordinator.close();
    await server.close();
  }

  ApiRoute _count(ApiRoute route) => ApiRoute(
    path: route.path,
    access: route.access,
    maxBodyBytes: route.maxBodyBytes,
    limit: route.limit,
    handle: (call) {
      handled.update(route.path, (n) => n + 1, ifAbsent: () => 1);
      return route.handle(call);
    },
  );
}
