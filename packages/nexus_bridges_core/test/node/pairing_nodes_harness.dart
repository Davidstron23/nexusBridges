import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:nexus_bridges_core/src/discovery/discovery.dart'
    show MulticastChannel;
import 'package:nexus_bridges_core/src/identity/identity.dart';
import 'package:nexus_bridges_core/src/network/network.dart';
import 'package:nexus_bridges_core/src/node/node.dart';
import 'package:nexus_bridges_core/src/pairing/pairing.dart';
import 'package:nexus_bridges_core/src/protocol/protocol.dart'
    show Announcement, AnnouncementKind, ApiPaths, protocolVersion;
import 'package:nexus_bridges_core/src/storage/storage.dart';
import 'package:nexus_bridges_core/src/transport/transport.dart';
import 'package:test/test.dart';

import '../support/infra.dart';

const String dot = '\u00B7';
const String homeNetwork = '{NETWORK-HOME}';
const String _adapterId = '{WIFI-ADAPTER}';
const Duration waitLimit = Duration(seconds: 5);
const Duration shortHold = Duration(milliseconds: 300);
const int _prefixLength = 30;

final String _sep = Platform.pathSeparator;

String? _loopbackName;

final class XorProtector implements SecretProtector {
  static Uint8List _xor(Uint8List data) =>
      Uint8List.fromList([for (final b in data) b ^ 0x5A]);

  @override
  Uint8List protect(Uint8List data) => _xor(data);

  @override
  Uint8List? unprotect(Uint8List data) => _xor(data);
}

Future<String> _systemLoopbackName() async {
  final cached = _loopbackName;
  if (cached != null) return cached;
  final all = await NetworkInterface.list(includeLoopback: true);
  final name = all
      .firstWhere((i) => i.addresses.any((a) => a.address == '127.0.0.1'))
      .name;
  _loopbackName = name;
  return name;
}

Future<int> freeTcpPort({
  List<String> hosts = const ['127.0.0.1', '127.0.0.2'],
}) => pickPort(tcp: [for (final host in hosts) InternetAddress(host)]);

Future<int> _freeUdpPort() => pickPort(udp: [InternetAddress.anyIPv4]);

Future<void> eventually(
  FutureOr<bool> Function() condition, {
  Duration? limit,
  String reason = 'condition',
}) async {
  final span = limit ?? scaled(waitLimit);
  final watch = Stopwatch()..start();
  while (!await condition()) {
    if (watch.elapsed > span) {
      fail('$reason not met within $span');
    }
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}

String shortOf(String fingerprint) => fingerprint.substring(0, 8);

String labelOf(String name, String fingerprint) =>
    '$name $dot ${shortOf(fingerprint)}';

AdapterInfo wifiAdapter() => AdapterInfo(
  id: _adapterId,
  friendlyName: 'Wi-Fi',
  description: 'Test wireless adapter',
  ifType: 71,
  isUp: true,
  ipv4: [Ipv4Subnet(InternetAddress('192.168.50.21'), 24)],
  hasGateway: true,
  networkId: homeNetwork,
  networkName: 'Home',
);

PairedDevice pairedEntryFor(
  DeviceIdentity identity, {
  required String name,
  PeerRelation relation = PeerRelation.foreign,
  DateTime? pairedAt,
}) => PairedDevice(
  fingerprint: identity.fingerprint,
  name: name,
  certificatePem: identity.certificate.pem,
  relation: relation,
  pairedAt: pairedAt ?? DateTime.utc(2026, 10, 1),
);

void breakFile(File file) {
  if (file.existsSync()) file.deleteSync();
  Directory(file.path).createSync(recursive: true);
}

void repairFile(File file) {
  final dir = Directory(file.path);
  if (dir.existsSync()) dir.deleteSync(recursive: true);
}

final class PairingNode {
  PairingNode._(
    this.name,
    this.address,
    this.root,
    this.port,
    this.channelPort,
  );

  final String name;
  final String address;
  final Directory root;
  int port;
  int channelPort;
  final List<String> logs = [];
  final List<NodeState> states = [];
  DateTime clock = DateTime.utc(2026, 10, 24, 12);
  List<AdapterInfo> adapters = [wifiAdapter()];
  int prefixLength = _prefixLength;
  NexusNode? _node;

  static Future<PairingNode> create(
    String name,
    String address, {
    required int port,
  }) async {
    final root = await Directory.systemTemp.createTemp('nexus_node_pairing_');
    addTearDown(() async {
      for (var attempt = 0; attempt < 40; attempt++) {
        try {
          if (root.existsSync()) await root.delete(recursive: true);
          return;
        } on FileSystemException {
          await Future<void>.delayed(const Duration(milliseconds: 50));
        }
      }
    });
    return PairingNode._(name, address, root, port, await _freeUdpPort());
  }

  NexusNode get node => _node!;

  NodeState get state => node.state;

  String get fingerprint => node.state.fingerprint;

  DateTime now() => clock;

  Directory get dataDir => Directory('${root.path}${_sep}data');

  Directory get identityDir => Directory('${dataDir.path}${_sep}identity');

  File get pairedFile => File('${dataDir.path}${_sep}paired.json');

  File get ignoredFile => File('${dataDir.path}${_sep}ignored.json');

  InternetAddress get internetAddress => InternetAddress(address);

  Future<DeviceIdentity> loadIdentity() async {
    final loaded = await IdentityStore(
      dataDir: dataDir,
      protector: XorProtector(),
      now: now,
    ).loadOrCreate();
    return loaded.identity;
  }

  Future<void> writePaired(String owner, List<PairedDevice> devices) async {
    final store = PairedDevicesStore(
      JsonFileStore(pairedFile),
      ownerFingerprint: owner,
      now: now,
    );
    await store.replaceAll(devices);
  }

  Future<NexusNode> start({
    Duration pollHold = shortHold,
    Duration tick = const Duration(milliseconds: 50),
    Duration pollInterval = const Duration(minutes: 1),
  }) async {
    final loopback = await _systemLoopbackName();
    final before = logs.length;
    final channel = MulticastChannel(port: channelPort, log: logs.add);
    addTearDown(channel.close);
    final started = await NexusNode.start(
      dataDir: dataDir,
      protector: XorProtector(),
      readNetworks: () async => adapters,
      port: port,
      deviceName: name,
      now: now,
      log: logs.add,
      activeOf: (states) => [
        for (final state in states)
          if (state.status == InterfaceStatus.active)
            ActiveInterface(
              id: '${state.adapter.id}#$address',
              adapterId: state.adapter.id,
              friendlyName: loopback,
              subnet: Ipv4Subnet(InternetAddress(address), prefixLength),
            ),
      ],
      pollInterval: pollInterval,
      channel: channel,
      pairingTickInterval: tick,
      pairingPollHold: pollHold,
    );
    _node = started;
    addTearDown(started.shutdown);
    final subscription = started.states.listen(states.add);
    addTearDown(subscription.cancel);
    await eventually(
      () => started.state.prompts.isNotEmpty || !started.state.paused,
      reason: '$name network read',
    );
    if (started.state.prompts.isNotEmpty) {
      await started.decideNetwork(homeNetwork, NetworkDecision.trusted);
    }
    await eventually(() => !started.state.paused, reason: '$name active');
    await awaitListening(
      name: name,
      logs: logs,
      since: before,
      portInUse: () => started.state.portInUse,
      limit: scaled(waitLimit),
    );
    return started;
  }

  Future<NexusNode> restart() async {
    await node.shutdown();
    return start();
  }

  Future<NodeState> until(
    bool Function(NodeState s) condition, {
    Duration? limit,
    String? reason,
  }) async {
    await eventually(
      () => condition(node.state),
      limit: limit,
      reason: reason ?? '$name state',
    );
    return node.state;
  }

  DeviceEntry? entryOf(String fingerprint) {
    for (final entry in state.entries) {
      if (entry.fingerprint == fingerprint) return entry;
    }
    return null;
  }

  bool sees(PairingNode other) =>
      state.devices.any((d) => d.info.fingerprint == other.fingerprint);

  bool hasPaired(PairingNode other) =>
      entryOf(other.fingerprint)?.paired ?? false;
}

Future<(PairingNode, PairingNode)> twoPairingNodes({
  Duration pollHoldA = shortHold,
  Duration pollHoldB = shortHold,
  Future<void> Function(PairingNode a, PairingNode b)? before,
}) async {
  final port = await freeTcpPort();
  final a = await PairingNode.create('Node A', '127.0.0.1', port: port);
  final b = await PairingNode.create('Node B', '127.0.0.2', port: port);
  if (before != null) await before(a, b);
  await startTogether(
    [a, b],
    start: (node) =>
        node.start(pollHold: identical(node, a) ? pollHoldA : pollHoldB),
  );
  await meet(a, b);
  return (a, b);
}

Future<void> startTogether(
  List<PairingNode> nodes, {
  Future<void> Function(PairingNode node)? start,
  List<PairingNode> later = const [],
}) => onFreshPorts(
  () async {
    for (final node in nodes) {
      if (start != null) {
        await start(node);
      } else {
        await node.start();
      }
    }
  },
  reset: () async {
    for (final node in nodes) {
      await node._node?.shutdown();
    }
    final port = await freeTcpPort(
      hosts: [
        for (final node in [...nodes, ...later]) node.address,
      ],
    );
    for (final node in [...nodes, ...later]) {
      node
        ..port = port
        ..channelPort = await _freeUdpPort();
    }
  },
);

Future<void> meet(PairingNode a, PairingNode b) async {
  for (var attempt = 0; attempt < 5; attempt++) {
    if (attempt > 0 && a.sees(b) && b.sees(a)) break;
    await a.node.rescan();
    await b.node.rescan();
    final watch = Stopwatch()..start();
    while (watch.elapsed < scaled(const Duration(seconds: 3)) &&
        !(a.sees(b) && b.sees(a))) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
  }
  await eventually(
    () => a.sees(b) && b.sees(a),
    reason: 'nodes see each other',
  );
  await eventually(
    () =>
        a.entryOf(b.fingerprint)?.visible == true &&
        b.entryOf(a.fingerprint)?.visible == true,
    reason: 'rows of each other',
  );
}

Future<void> bothComparing(PairingNode initiator, PairingNode receiver) async {
  await receiver.until(
    (s) => s.pairing?.phase == PairingPhase.comparing,
    reason: '${receiver.name} comparing',
  );
  await initiator.until(
    (s) => s.pairing?.phase == PairingPhase.comparing,
    reason: '${initiator.name} comparing',
  );
}

Future<void> pairUp(PairingNode initiator, PairingNode receiver) async {
  expect(
    await initiator.node.pair(receiver.fingerprint),
    PairRequestResult.started,
  );
  await bothComparing(initiator, receiver);
  initiator.node.answerCode(matches: true);
  receiver.node.answerRequest(ReceiverAnswer.matches);
  await eventually(
    () => initiator.hasPaired(receiver) && receiver.hasPaired(initiator),
    reason: 'both paired',
  );
  await dismissPaired(initiator, receiver);
}

bool showsPaired(NodeState state) =>
    state.pairing?.phase == PairingPhase.finished &&
    state.pairing?.outcome == PairingOutcome.paired;

Future<void> dismissPaired(PairingNode initiator, PairingNode receiver) async {
  await eventually(
    () => showsPaired(initiator.state) && showsPaired(receiver.state),
    reason: 'paired views',
  );
  initiator.node.dismissPairing();
  receiver.node.dismissPairing();
  await eventually(
    () => initiator.state.pairing == null && receiver.state.pairing == null,
    reason: 'views closed',
  );
}

Future<void> sayBye(PairingNode from, PairingNode to) =>
    sayByeAs(from, to, fingerprint: from.fingerprint);

Future<void> sayByeAs(
  PairingNode from,
  PairingNode to, {
  required String fingerprint,
}) async {
  final socket = await RawDatagramSocket.bind(
    from.internetAddress,
    0,
    reuseAddress: false,
  );
  addTearDown(socket.close);
  final bytes = Announcement(
    AnnouncementKind.bye,
    DeviceInfo(
      name: from.name,
      fingerprint: fingerprint,
      port: from.port,
      protocol: protocolVersion,
      deviceType: DeviceType.desktop,
    ),
  ).encode();
  final watch = Stopwatch()..start();
  while (socket.send(bytes, to.internetAddress, to.channelPort) !=
      bytes.length) {
    if (watch.elapsed > scaled(waitLimit)) fail('bye not sent');
    await Future<void>.delayed(const Duration(milliseconds: 1));
  }
}

Future<int?> unpairAs(
  DeviceIdentity caller, {
  required InternetAddress from,
  required PairingNode target,
}) async {
  final reply = await postJson(
    address: target.internetAddress,
    port: target.port,
    path: ApiPaths.unpair,
    json: const <String, Object?>{},
    context: caller.clientContext(presentCertificate: true),
    acceptServer: (certificate) {
      try {
        return fingerprintOfCertificate(certificate.der) == target.fingerprint;
      } on FormatException {
        return false;
      }
    },
    sourceAddress: from,
  );
  return reply?.status;
}

final class CoreTimers {
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

  int createdBy(String path) =>
      _timers.where((entry) => entry.$2.contains(path)).length;

  List<String> activeBy(String path) => [
    for (final (timer, trace) in _timers)
      if (timer.isActive && trace.contains(path)) trace,
  ];
}
