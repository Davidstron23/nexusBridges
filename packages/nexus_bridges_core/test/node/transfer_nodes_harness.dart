import 'dart:async';
import 'dart:io';

import 'package:nexus_bridges_core/src/discovery/discovery.dart'
    show MulticastChannel;
import 'package:nexus_bridges_core/src/identity/identity.dart';
import 'package:nexus_bridges_core/src/network/network.dart';
import 'package:nexus_bridges_core/src/node/node.dart';
import 'package:nexus_bridges_core/src/pairing/pairing.dart';
import 'package:nexus_bridges_core/src/protocol/protocol.dart'
    show Announcement, AnnouncementKind, protocolVersion;
import 'package:nexus_bridges_core/src/settings/settings.dart';
import 'package:nexus_bridges_core/src/storage/storage.dart';
import 'package:nexus_bridges_core/src/transfer/folders.dart'
    show tempFolderName;
import 'package:nexus_bridges_core/src/transfer/platform.dart';
import 'package:nexus_bridges_core/src/transfer/transfer.dart'
    show writeAllBytes;
import 'package:test/test.dart';

import '../support/infra.dart';
import '../transfer/receiver_harness.dart'
    show FakeClock, TransferPlatform, realFs;
import 'pairing_nodes_harness.dart'
    show
        XorProtector,
        eventually,
        freeTcpPort,
        homeNetwork,
        pairedEntryFor,
        wifiAdapter;

export '../transfer/receiver_harness.dart'
    show FakeClock, TransferPlatform, realFs;
export 'pairing_nodes_harness.dart' show eventually;

const Duration transferWait = Duration(seconds: 10);
const Timeout transferTimeout = Timeout(Duration(minutes: 2));

String? _loopbackName;

Future<String> _systemLoopbackName() async {
  final cached = _loopbackName;
  if (cached != null) return cached;
  final all = await NetworkInterface.list(includeLoopback: true);
  return _loopbackName = all
      .firstWhere((i) => i.addresses.any((a) => a.address == '127.0.0.1'))
      .name;
}

Future<int> _freeUdpPort() => pickPort(udp: [InternetAddress.anyIPv4]);

final class NodePicker implements FilePicker {
  String? nextFile;
  String? nextFolder;
  List<String>? nextFiles;
  List<String> nextFolders = const [];
  Completer<void>? fileGate;
  int fileCalls = 0;
  int folderCalls = 0;
  int multiFolderCalls = 0;

  void hold() => fileGate = Completer<void>();

  void release() {
    final gate = fileGate;
    fileGate = null;
    if (gate != null && !gate.isCompleted) gate.complete();
  }

  @override
  Future<String?> pickFile() async {
    fileCalls++;
    final gate = fileGate;
    if (gate != null) await gate.future;
    return nextFile;
  }

  Completer<void>? folderGate;
  final List<String?> folderStartIns = [];

  @override
  Future<String?> pickFolder({String? startIn}) async {
    folderCalls++;
    folderStartIns.add(startIn);
    final gate = folderGate;
    if (gate != null) await gate.future;
    return nextFolder;
  }

  @override
  Future<List<String>> pickFiles() async {
    fileCalls++;
    final gate = fileGate;
    if (gate != null) await gate.future;
    final files = nextFiles;
    if (files != null) return List.of(files);
    final file = nextFile;
    return file == null ? const [] : [file];
  }

  @override
  Future<List<String>> pickFolders() async {
    multiFolderCalls++;
    final gate = fileGate;
    if (gate != null) await gate.future;
    return List.of(nextFolders);
  }
}

final class FakeRevealer implements FolderRevealer {
  RevealResult answer = RevealResult.shown;
  final List<String> paths = [];

  @override
  Future<RevealResult> reveal(String filePath) async {
    paths.add(filePath);
    return answer;
  }
}

final class SlowWrites {
  SlowWrites({this.delay = Duration.zero});

  Duration delay;
  int written = 0;
  Completer<void>? gate;

  void hold() => gate ??= Completer<void>();

  void release() {
    final current = gate;
    gate = null;
    if (current != null && !current.isCompleted) current.complete();
  }

  Future<void> call(RandomAccessFile file, List<int> bytes) async {
    final current = gate;
    if (current != null) await current.future;
    if (delay > Duration.zero) await Future<void>.delayed(delay);
    await writeAllBytes(file, bytes);
    written += bytes.length;
  }
}

final class TimerLog {
  final List<(Timer, String)> _timers = [];

  ZoneSpecification specification(void Function(String) mark) =>
      ZoneSpecification(
        createTimer: (self, parent, zone, duration, callback) {
          final timer = parent.createTimer(zone, duration, callback);
          _timers.add((timer, StackTrace.current.toString()));
          return timer;
        },
        createPeriodicTimer: (self, parent, zone, period, callback) {
          final timer = parent.createPeriodicTimer(zone, period, callback);
          final trace = StackTrace.current.toString();
          _timers.add((timer, trace));
          if (trace.contains('src/transfer/transfer.dart')) {
            mark('timer: transfer tick');
          }
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

final class TransferNode {
  TransferNode._(this.name, this.address, this.base, this.port, this.platform);

  final String name;
  final InternetAddress address;
  final String base;
  int port;
  final TransferPlatform platform;
  final List<String> logs = [];
  final List<NodeState> states = [];
  final NodePicker picker = NodePicker();
  final FakeRevealer revealer = FakeRevealer();
  final FakeClock clock = FakeClock();
  final SlowWrites writes = SlowWrites();
  final TimerLog timers = TimerLog();
  DateTime wallClock = DateTime.utc(2026, 10, 25, 12);
  List<AdapterInfo> adapters = [wifiAdapter()];
  Duration pollInterval = const Duration(minutes: 1);
  Duration elapsed = Duration.zero;
  Duration transferPollHold = const Duration(milliseconds: 200);
  int prefixLength = 30;
  List<ActiveInterface> Function(List<InterfaceState> states, String loopback)?
  activeOfOverride;
  int channelPort = 0;
  NexusNode? _node;
  Future<void>? _stopped;

  static Future<TransferNode> create(
    String name,
    String address, {
    required int port,
  }) async {
    final root = await Directory.systemTemp.createTemp('nexus_node_t14_');
    addTearDown(() async {
      for (var attempt = 0; attempt < 60; attempt++) {
        try {
          if (root.existsSync()) await root.delete(recursive: true);
          return;
        } on FileSystemException {
          await Future<void>.delayed(const Duration(milliseconds: 50));
        }
      }
    });
    final base = (await realFs.realPath(root.path))!;
    String folder(String child) {
      final path = '$base\\$child';
      Directory(path).createSync(recursive: true);
      return path;
    }

    for (final child in ['data', 'source', 'recv']) {
      folder(child);
    }
    final system = SystemFolders(
      downloads: folder('downloads'),
      startup: folder('sys\\startup'),
      startMenu: folder('sys\\startmenu'),
      windows: folder('sys\\windows'),
      programFiles: folder('sys\\programfiles'),
      systemDriveRoot: folder('sys\\root'),
    );
    return TransferNode._(
      name,
      InternetAddress(address),
      base,
      port,
      TransferPlatform(system),
    );
  }

  NexusNode get node => _node!;

  NodeState get state => node.state;

  String get fingerprint => state.fingerprint;

  String get dataPath => '$base\\data';

  Directory get dataDir => Directory(dataPath);

  String get sourceDir => '$base\\source';

  String get recvDir => '$base\\recv';

  String get downloadsDir => '$base\\downloads';

  String get proposedDir => '$downloadsDir\\NexusBridges';

  String tempSubOf(String folder) => '$folder\\$tempFolderName';

  File get settingsFile => File('$dataPath\\settings.json');

  File get cleanupFile => File('$dataPath\\cleanup.json');

  File get pairedFile => File('$dataPath\\paired.json');

  DateTime now() => wallClock;

  Duration monotonic() => elapsed;

  Future<DeviceIdentity> loadIdentity() async {
    final loaded = await IdentityStore(
      dataDir: dataDir,
      protector: XorProtector(),
      now: now,
    ).loadOrCreate();
    return loaded.identity;
  }

  Future<void> writePaired(
    DeviceIdentity self,
    List<PairedDevice> devices,
  ) async {
    final store = PairedDevicesStore(
      JsonFileStore(pairedFile),
      ownerFingerprint: self.fingerprint,
      now: now,
    );
    await store.replaceAll(devices);
  }

  Future<String> rememberFolder([String? path]) async {
    final folder = path ?? recvDir;
    final facts = await realFs.volumeFacts(folder);
    expect(facts, isNotNull);
    final saved = await SettingsStore(JsonFileStore(settingsFile))
        .writeReceiveFolder(
          SavedReceiveFolder(path: folder, volumeId: facts!.volumeId),
        );
    expect(saved, isTrue);
    return folder;
  }

  Future<String> sourceFile(String fileName, List<int> bytes) async {
    final path = '$sourceDir\\$fileName';
    await File(path).writeAsBytes(bytes, flush: true);
    return path;
  }

  void _mark(String line) => logs.add(line);

  Future<NexusNode> start() async {
    final loopback = await _systemLoopbackName();
    final before = logs.length;
    channelPort = await _freeUdpPort();
    final zone = Zone.current.fork(specification: timers.specification(_mark));
    final started = await zone.run(() async {
      final channel = MulticastChannel(port: channelPort, log: logs.add);
      addTearDown(channel.close);
      return NexusNode.start(
        dataDir: dataDir,
        protector: XorProtector(),
        readNetworks: () async => adapters,
        port: port,
        deviceName: name,
        now: now,
        monotonic: monotonic,
        presentInterval: const Duration(hours: 1),
        log: logs.add,
        activeOf: (states) =>
            activeOfOverride?.call(states, loopback) ??
            [
              for (final state in states)
                if (state.status == InterfaceStatus.active)
                  ActiveInterface(
                    id: '${state.adapter.id}#${address.address}',
                    adapterId: state.adapter.id,
                    friendlyName: loopback,
                    subnet: Ipv4Subnet(address, prefixLength),
                  ),
            ],
        pollInterval: pollInterval,
        channel: channel,
        pairingTickInterval: const Duration(milliseconds: 50),
        pairingPollHold: const Duration(milliseconds: 300),
        fileSystem: platform,
        picker: picker,
        revealer: revealer,
        clock: clock.call,
        transferTickInterval: const Duration(milliseconds: 20),
        transferPollHold: transferPollHold,
        transferWriteBytes: writes.call,
      );
    });
    _node = started;
    _stopped = null;
    addTearDown(started.shutdown);
    final subscription = started.states.listen(states.add);
    addTearDown(subscription.cancel);
    await eventually(
      () => started.state.prompts.isNotEmpty || !started.state.paused,
      limit: scaled(transferWait),
      reason: '$name network read',
    );
    if (started.state.prompts.isNotEmpty) {
      await started.decideNetwork(homeNetwork, NetworkDecision.trusted);
    }
    await eventually(
      () => !started.state.paused,
      limit: scaled(transferWait),
      reason: '$name active',
    );
    await awaitListening(
      name: name,
      logs: logs,
      since: before,
      portInUse: () => started.state.portInUse,
      limit: scaled(transferWait),
    );
    return started;
  }

  Future<void> stop() => _stopped ??= node.shutdown();

  Future<void> restart() async {
    await stop();
    await start();
  }

  Future<NodeState> until(
    bool Function(NodeState s) condition, {
    Duration? limit,
    String? reason,
  }) async {
    await eventually(
      () => condition(node.state),
      limit: limit ?? scaled(transferWait),
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

  Future<SendResult> send(TransferNode to, String path) {
    picker.nextFile = path;
    return node.sendFiles(to.fingerprint);
  }

  Future<TransferResultView> sentResult({
    TransferResultView? after,
    Duration? limit,
  }) async {
    final s = await until(
      (s) =>
          s.lastSent != null &&
          !identical(s.lastSent, after) &&
          s.outgoing == null &&
          s.sendingTo == null,
      limit: limit,
      reason: '$name last sent',
    );
    return s.lastSent!;
  }

  Future<TransferResultView> receivedResult({TransferResultView? after}) async {
    final s = await until(
      (s) =>
          s.lastReceived != null &&
          !identical(s.lastReceived, after) &&
          (s.incoming == null || s.incoming!.stage == IncomingStage.ended),
      reason: '$name last received',
    );
    return s.lastReceived!;
  }

  Future<IncomingTransferView> incomingAt(IncomingStage stage) async {
    final s = await until(
      (s) => s.incoming?.stage == stage,
      reason: '$name incoming $stage',
    );
    return s.incoming!;
  }

  List<Notice> noticesOf(NoticeKind kind) => [
    for (final notice in state.notices)
      if (notice.kind == kind) notice,
  ];

  bool tempLeftIn(String folder) =>
      FileSystemEntity.typeSync(tempSubOf(folder)) !=
      FileSystemEntityType.notFound;

  List<String> filesIn(String folder) {
    final names = [
      for (final entity in Directory(folder).listSync())
        if (entity is File) entity.uri.pathSegments.last,
    ]..sort();
    return names;
  }
}

Future<(TransferNode, TransferNode)> transferNodes({
  PeerRelation aAtB = PeerRelation.mine,
  PeerRelation bAtA = PeerRelation.mine,
  bool rememberA = true,
  bool rememberB = true,
  String nameA = 'Desk PC',
  String nameB = 'Laptop',
  Future<void> Function(TransferNode a, TransferNode b)? before,
}) async {
  final port = await freeTcpPort(hosts: const ['127.0.0.1', '127.0.0.2']);
  final a = await TransferNode.create(nameA, '127.0.0.1', port: port);
  final b = await TransferNode.create(nameB, '127.0.0.2', port: port);
  final idA = await a.loadIdentity();
  final idB = await b.loadIdentity();
  await a.writePaired(idA, [pairedEntryFor(idB, name: nameB, relation: bAtA)]);
  await b.writePaired(idB, [pairedEntryFor(idA, name: nameA, relation: aAtB)]);
  if (rememberA) await a.rememberFolder();
  if (rememberB) await b.rememberFolder();
  if (before != null) await before(a, b);
  await onFreshPorts(
    () async {
      await a.start();
      await b.start();
    },
    reset: () async {
      for (final node in [a, b]) {
        if (node._node != null) await node.stop();
      }
      final fresh = await freeTcpPort(hosts: const ['127.0.0.1', '127.0.0.2']);
      a.port = fresh;
      b.port = fresh;
    },
  );
  await meet(a, b);
  return (a, b);
}

Future<void> meet(TransferNode a, TransferNode b) async {
  for (var attempt = 0; attempt < 5; attempt++) {
    await a.node.rescan();
    await b.node.rescan();
    final watch = Stopwatch()..start();
    while (watch.elapsed < scaled(const Duration(seconds: 3))) {
      if (a.entryOf(b.fingerprint)?.visible == true &&
          b.entryOf(a.fingerprint)?.visible == true) {
        return;
      }
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
  }
  fail('the two nodes did not see each other');
}

Future<void> loseSight(TransferNode viewer, TransferNode gone) async {
  viewer.elapsed += const Duration(seconds: 31);
  await viewer.until(
    (s) =>
        s.entries.any((e) => e.fingerprint == gone.fingerprint && !e.visible),
    reason: '${gone.name} out of sight in ${viewer.name}',
  );
}

Future<void> sayBye(TransferNode from, TransferNode to) async {
  final socket = await RawDatagramSocket.bind(
    from.address,
    0,
    reuseAddress: false,
  );
  addTearDown(socket.close);
  final bytes = Announcement(
    AnnouncementKind.bye,
    DeviceInfo(
      name: from.name,
      fingerprint: from.fingerprint,
      port: from.port,
      protocol: protocolVersion,
      deviceType: DeviceType.desktop,
    ),
  ).encode();
  final watch = Stopwatch()..start();
  while (socket.send(bytes, to.address, to.channelPort) != bytes.length) {
    if (watch.elapsed > scaled(transferWait)) fail('bye not sent');
    await Future<void>.delayed(const Duration(milliseconds: 1));
  }
}

Future<bool> tcpPortFree(InternetAddress address, int port) async {
  try {
    final socket = await ServerSocket.bind(address, port);
    await socket.close();
    return true;
  } on SocketException {
    return false;
  }
}

Future<(TransferNode, TransferNode, TransferNode)> transferTrio({
  PeerRelation aAtB = PeerRelation.mine,
  PeerRelation cAtB = PeerRelation.foreign,
}) async {
  const hosts = ['127.0.0.1', '127.0.0.2', '127.0.0.3'];
  final port = await freeTcpPort(hosts: hosts);
  final a = await TransferNode.create('Desk PC', hosts[0], port: port);
  final b = await TransferNode.create('Laptop', hosts[1], port: port);
  final c = await TransferNode.create('Tablet', hosts[2], port: port);
  final trio = [a, b, c];
  for (final node in trio) {
    node.prefixLength = 29;
  }
  final idA = await a.loadIdentity();
  final idB = await b.loadIdentity();
  final idC = await c.loadIdentity();
  await a.writePaired(idA, [
    pairedEntryFor(idB, name: b.name, relation: PeerRelation.mine),
    pairedEntryFor(idC, name: c.name, relation: PeerRelation.mine),
  ]);
  await b.writePaired(idB, [
    pairedEntryFor(idA, name: a.name, relation: aAtB),
    pairedEntryFor(idC, name: c.name, relation: cAtB),
  ]);
  await c.writePaired(idC, [
    pairedEntryFor(idA, name: a.name, relation: PeerRelation.mine),
    pairedEntryFor(idB, name: b.name, relation: PeerRelation.mine),
  ]);
  for (final node in trio) {
    await node.rememberFolder();
  }
  await onFreshPorts(
    () async {
      for (final node in trio) {
        await node.start();
      }
    },
    reset: () async {
      for (final node in trio) {
        if (node._node != null) await node.stop();
      }
      final fresh = await freeTcpPort(hosts: hosts);
      for (final node in trio) {
        node.port = fresh;
      }
    },
  );
  await meet(a, b);
  await meet(a, c);
  await meet(b, c);
  return (a, b, c);
}
