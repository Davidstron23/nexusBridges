import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:nexus_bridges_core/src/discovery/discovery.dart'
    show MulticastChannel;
import 'package:nexus_bridges_core/src/identity/identity.dart';
import 'package:nexus_bridges_core/src/network/network.dart';
import 'package:nexus_bridges_core/src/node/node.dart';
import 'package:nexus_bridges_core/src/pairing/pairing.dart';
import 'package:nexus_bridges_core/src/protocol/protocol.dart';
import 'package:nexus_bridges_core/src/settings/settings.dart';
import 'package:nexus_bridges_core/src/storage/storage.dart';
import 'package:nexus_bridges_core/src/transfer/folders.dart'
    show tempFolderName, tempPrefix;
import 'package:nexus_bridges_core/src/transfer/messages.dart';
import 'package:nexus_bridges_core/src/transfer/platform.dart';
import 'package:nexus_bridges_core/src/transfer/transfer.dart'
    show FolderRevealer, ReceiveFolder, TempJournal;
import 'package:nexus_bridges_core/src/transport/transport.dart';
import 'package:test/test.dart';

import '../support/infra.dart';
import '../node/pairing_nodes_harness.dart'
    show XorProtector, eventually, homeNetwork, wifiAdapter;
import 'receiver_harness.dart'
    show FakeClock, RawReply, TransferPlatform, realFs;
import 'transfer_stacks_harness.dart' show ScriptedPicker, transferFolder;

export '../node/pairing_nodes_harness.dart' show eventually;
export 'receiver_harness.dart' show FakeClock, RawReply, TransferPlatform;
export 'transfer_stacks_harness.dart' show WriteThrottle;

const int kib = 1024;

const int mib = 1048576;

const int gib = 1073741824;

const Duration nodeLimit = Duration(seconds: 15);

const String wifiId = '{WIFI-ADAPTER}';

const String ethernetId = '{ETHERNET-ADAPTER}';

const String zoneMark = '[ZoneTransfer]\r\nZoneId=3\r\n';

String? _loopbackName;

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

Future<int> freePortOnAll(List<String> hosts) =>
    pickPort(tcp: [for (final host in hosts) InternetAddress(host)]);

Future<int> _freeUdpPort() => pickPort(udp: [InternetAddress.anyIPv4]);

Uint8List patternBytes(int length, int seed) {
  final random = Random(seed);
  final bytes = Uint8List(length);
  for (var i = 0; i < length; i++) {
    bytes[i] = random.nextInt(256);
  }
  return bytes;
}

String digestOf(List<int> bytes) => sha256.convert(bytes).toString();

final Random _secure = Random.secure();

String newTransferId() {
  final buffer = StringBuffer();
  for (var i = 0; i < 16; i++) {
    buffer.write(_secure.nextInt(256).toRadixString(16).padLeft(2, '0'));
  }
  return buffer.toString();
}

Stream<List<int>> chunksOf(List<int> bytes, {int size = 64 * kib}) async* {
  for (var start = 0; start < bytes.length; start += size) {
    yield bytes.sublist(start, min(start + size, bytes.length));
  }
}

Map<String, int> treeOf(String root) {
  final dir = Directory(root);
  if (!dir.existsSync()) return const {};
  return {
    for (final entity in dir.listSync(recursive: true, followLinks: false))
      entity.path.substring(root.length + 1).toLowerCase(): entity is File
          ? entity.lengthSync()
          : -1,
  };
}

bool anyTempIn(String root) => treeOf(root).keys.any(
  (path) =>
      path.contains(tempFolderName.toLowerCase()) ||
      path.split(r'\').last.startsWith(tempPrefix.toLowerCase()),
);

final class _NoReveal implements FolderRevealer {
  @override
  Future<RevealResult> reveal(String filePath) async =>
      RevealResult.unavailable;
}

typedef NodeInterface = ({String adapterId, String address});

AdapterInfo _adapterFor(String id) => id == wifiId
    ? wifiAdapter()
    : AdapterInfo(
        id: id,
        friendlyName: 'Ethernet',
        description: 'Test wired adapter',
        ifType: 6,
        isUp: true,
        ipv4: [Ipv4Subnet(InternetAddress('192.168.50.22'), 24)],
        hasGateway: true,
        networkId: homeNetwork,
        networkName: 'Home',
      );

final class TransferNode {
  TransferNode._({
    required this.name,
    required this.address,
    required this.port,
    required this.base,
    required this.channelPort,
    required this.platform,
  }) : interfaces = [(adapterId: wifiId, address: address)];

  final String name;
  final String address;
  int port;
  final String base;
  int channelPort;
  final TransferPlatform platform;
  final ScriptedPicker picker = ScriptedPicker();
  final FakeClock clock = FakeClock()..followRealTime();
  final List<String> logs = [];
  final List<NodeState> states = [];
  final Stopwatch _wall = Stopwatch()..start();
  List<NodeInterface> interfaces;
  Future<void> Function(RandomAccessFile file, List<int> bytes)? writeBytes;
  late final DeviceIdentity identity;
  NexusNode? _node;

  static Future<TransferNode> create(
    String name,
    String address, {
    required int port,
  }) async {
    final root = await transferFolder('nexus_t15_');
    final base = (await realFs.realPath(root.path))!;
    String folder(String child) {
      final path = '$base\\$child';
      Directory(path).createSync(recursive: true);
      return path;
    }

    for (final child in const ['data', 'recv', 'source']) {
      folder(child);
    }
    final platform = TransferPlatform(
      SystemFolders(
        downloads: folder('downloads'),
        startup: folder('sys\\startup'),
        startMenu: folder('sys\\startmenu'),
        windows: folder('sys\\windows'),
        programFiles: folder('sys\\programfiles'),
        systemDriveRoot: folder('sys\\root'),
      ),
    );
    final node = TransferNode._(
      name: name,
      address: address,
      port: port,
      base: base,
      channelPort: await _freeUdpPort(),
      platform: platform,
    );
    node.identity = (await IdentityStore(
      dataDir: Directory(node.dataDir),
      protector: XorProtector(),
      now: node.now,
    ).loadOrCreate()).identity;
    return node;
  }

  NexusNode get node => _node!;

  NodeState get state => node.state;

  String get fingerprint => identity.fingerprint;

  InternetAddress get internetAddress => InternetAddress(address);

  String get dataDir => '$base\\data';

  String get receiveDir => '$base\\recv';

  String get sourceDir => '$base\\source';

  String get downloadsDir => '$base\\downloads';

  String get proposedDir => '$downloadsDir\\NexusBridges';

  String get tempSub => '$receiveDir\\$tempFolderName';

  DateTime now() => DateTime.utc(2026, 10, 25, 12).add(_wall.elapsed);

  Future<List<ReceiveFolder>> journalFolders() async {
    final journal = TempJournal(JsonFileStore(File('$dataDir\\cleanup.json')));
    await journal.load();
    return journal.folders;
  }

  Future<void> trust(List<(TransferNode, PeerRelation)> peers) async {
    final store = PairedDevicesStore(
      JsonFileStore(File('$dataDir\\paired.json')),
      ownerFingerprint: fingerprint,
      now: now,
    );
    await store.replaceAll([
      for (final (peer, relation) in peers)
        PairedDevice(
          fingerprint: peer.fingerprint,
          name: peer.name,
          certificatePem: peer.identity.certificatePem,
          relation: relation,
          pairedAt: DateTime.utc(2026, 10, 1),
        ),
    ]);
  }

  Future<void> rememberReceiveFolder() async {
    final facts = await realFs.volumeFacts(receiveDir);
    expect(facts, isNotNull);
    final saved =
        await SettingsStore(JsonFileStore(File('$dataDir\\settings.json')))
            .writeReceiveFolder(
              SavedReceiveFolder(path: receiveDir, volumeId: facts!.volumeId),
            );
    expect(saved, isTrue);
  }

  Future<ReceiveFolderRead> savedReceiveFolder() async {
    final saved = await SettingsStore(
      JsonFileStore(File('$dataDir\\settings.json')),
    ).readReceiveFolder();
    return (path: saved?.path, volumeId: saved?.volumeId);
  }

  Future<NexusNode> start() async {
    final loopback = await _systemLoopbackName();
    final before = logs.length;
    final channel = MulticastChannel(port: channelPort, log: logs.add);
    addTearDown(channel.close);
    final adapterIds = {for (final i in interfaces) i.adapterId};
    final started = await NexusNode.start(
      dataDir: Directory(dataDir),
      protector: XorProtector(),
      readNetworks: () async => [for (final id in adapterIds) _adapterFor(id)],
      port: port,
      deviceName: name,
      now: now,
      log: logs.add,
      activeOf: (states) => [
        for (final state in states)
          if (state.status == InterfaceStatus.active)
            for (final iface in interfaces)
              if (iface.adapterId == state.adapter.id)
                ActiveInterface(
                  id: '${state.adapter.id}#${iface.address}',
                  adapterId: state.adapter.id,
                  friendlyName: loopback,
                  subnet: Ipv4Subnet(InternetAddress(iface.address), 29),
                ),
      ],
      pollInterval: const Duration(minutes: 1),
      channel: channel,
      pairingTickInterval: const Duration(milliseconds: 50),
      pairingPollHold: const Duration(milliseconds: 300),
      fileSystem: platform,
      picker: picker,
      revealer: _NoReveal(),
      clock: clock.call,
      transferTickInterval: const Duration(milliseconds: 20),
      transferPollHold: const Duration(milliseconds: 200),
      transferWriteBytes: writeBytes,
    );
    _node = started;
    addTearDown(started.shutdown);
    final subscription = started.states.listen(states.add);
    addTearDown(subscription.cancel);
    await eventually(
      () => started.state.prompts.isNotEmpty || !started.state.paused,
      limit: scaled(nodeLimit),
      reason: '$name network read',
    );
    if (started.state.prompts.isNotEmpty) {
      await started.decideNetwork(homeNetwork, NetworkDecision.trusted);
    }
    await eventually(
      () => !started.state.paused,
      limit: scaled(nodeLimit),
      reason: '$name active',
    );
    await awaitListening(
      name: name,
      logs: logs,
      since: before,
      portInUse: () => started.state.portInUse,
      limit: scaled(nodeLimit),
    );
    return started;
  }

  Future<NodeState> until(
    bool Function(NodeState s) condition, {
    Duration? limit,
    String? reason,
  }) async {
    await eventually(
      () => condition(node.state),
      limit: limit ?? scaled(nodeLimit),
      reason: reason ?? '$name state',
    );
    return node.state;
  }

  DeviceEntry? entryOf(TransferNode other) {
    for (final entry in state.entries) {
      if (entry.fingerprint == other.fingerprint) return entry;
    }
    return null;
  }

  Future<String> sourceFile(String fileName, List<int> bytes) async {
    final path = '$sourceDir\\$fileName';
    await File(path).writeAsBytes(bytes, flush: true);
    return path;
  }

  Future<SendResult> sendTo(TransferNode to, String path) {
    picker.nextMany = [path];
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
          s.outgoing == null,
      limit: limit,
      reason: '$name last sent',
    );
    return s.lastSent!;
  }

  Future<TransferResultView> receivedResult({
    TransferResultView? after,
    Duration? limit,
  }) async {
    final s = await until(
      (s) =>
          s.lastReceived != null &&
          !identical(s.lastReceived, after) &&
          s.incoming?.stage != IncomingStage.receiving &&
          s.incoming?.stage != IncomingStage.verifying,
      limit: limit,
      reason: '$name last received',
    );
    return s.lastReceived!;
  }

  ForgedPeer forgedAs(TransferNode who, {InternetAddress? from}) =>
      ForgedPeer(who.identity, from: from ?? who.internetAddress, target: this);
}

typedef ReceiveFolderRead = ({String? path, String? volumeId});

Future<List<TransferNode>> transferNodes(
  List<String> names, {
  List<String> extraHosts = const [],
}) async {
  final addresses = [for (var i = 0; i < names.length; i++) '127.0.0.${i + 1}'];
  final port = await freePortOnAll([...addresses, ...extraHosts]);
  return [
    for (var i = 0; i < names.length; i++)
      await TransferNode.create(names[i], addresses[i], port: port),
  ];
}

Future<void> startAll(
  List<TransferNode> nodes, {
  List<TransferNode> later = const [],
}) => onFreshPorts(
  () async {
    for (final node in nodes) {
      await node.start();
    }
  },
  reset: () async {
    for (final node in nodes) {
      await node._node?.shutdown();
    }
    final group = [...nodes, ...later];
    final port = await freePortOnAll([
      for (final node in group)
        for (final iface in node.interfaces) iface.address,
    ]);
    for (final node in group) {
      node
        ..port = port
        ..channelPort = await _freeUdpPort();
    }
  },
);

Future<void> meetAll(
  List<TransferNode> nodes, {
  bool Function(TransferNode from, TransferNode to)? expectVisible,
}) async {
  for (final node in nodes) {
    await node.node.rescan();
  }
  for (final from in nodes) {
    for (final to in nodes) {
      if (identical(from, to)) continue;
      if (expectVisible != null && !expectVisible(from, to)) continue;
      await eventually(
        () => from.entryOf(to)?.visible == true,
        limit: scaled(nodeLimit),
        reason: '${from.name} sees ${to.name}',
      );
    }
  }
}

Future<void> canSend(TransferNode from, TransferNode to) => eventually(
  () => from.entryOf(to)?.canSendFile == true,
  limit: scaled(nodeLimit),
  reason: '${from.name} can send to ${to.name}',
);

final class ForgedPeer {
  ForgedPeer(this.identity, {required this.from, required this.target});

  final DeviceIdentity identity;
  final InternetAddress from;
  final TransferNode target;

  late final SecurityContext _context = identity.clientContext(
    presentCertificate: true,
  );

  bool _acceptServer(X509Certificate certificate) =>
      certificateMatches(certificate, target.fingerprint);

  Future<RawReply?> post(
    String path,
    Map<String, Object?> json, {
    InternetAddress? at,
  }) async {
    final reply = await postJson(
      address: at ?? target.internetAddress,
      port: target.port,
      path: path,
      json: json,
      context: _context,
      acceptServer: _acceptServer,
      sourceAddress: from,
      maxResponseBytes: Limits.maxTransferBodyBytes,
    );
    return reply == null
        ? null
        : RawReply(reply.status, Uint8List.fromList(reply.body));
  }

  Future<RawReply?> offer({
    required String transfer,
    required String name,
    required int size,
    required String sha256,
    InternetAddress? at,
  }) => post(
    ApiPaths.transferOffer,
    OfferRequest(
      transfer: transfer,
      name: name,
      size: size,
      sha256: sha256,
    ).toJson(),
    at: at,
  );

  Future<RawReply?> offerFolder(
    FolderOfferRequest request, {
    InternetAddress? at,
  }) => post(ApiPaths.transferOffer, request.toJson(), at: at);

  Future<StreamPostResult> manifest({
    required String transfer,
    required String permit,
    required Uint8List bytes,
    InternetAddress? at,
  }) => postStream(
    address: at ?? target.internetAddress,
    port: target.port,
    path: ApiPaths.transferManifest,
    headers: {
      TransferHeaders.transfer: transfer,
      TransferHeaders.permit: permit,
    },
    contentLength: bytes.length,
    body: chunksOf(bytes),
    context: _context,
    acceptServer: _acceptServer,
    sourceAddress: from,
    idleTimeout: const Duration(seconds: 30),
    answerTimeout: const Duration(seconds: 30),
    maxResponseBytes: Limits.maxTransferBodyBytes,
  );

  Future<RawReply?> wait(String transfer) =>
      post(ApiPaths.transferWait, WaitRequest(transfer: transfer).toJson());

  Future<RawReply?> cancel(String transfer) => post(
    ApiPaths.transferCancel,
    CancelRequest(transfer: transfer, reason: CancelReason.cancelled).toJson(),
  );

  Future<Grant> grant(List<int> content, {String name = 'informe.bin'}) async {
    final transfer = newTransferId();
    final reply = await offer(
      transfer: transfer,
      name: name,
      size: content.length,
      sha256: digestOf(content),
    );
    expect(reply?.status, 200, reason: reply?.text);
    expect(reply!.state, 'accepted');
    final permit = reply.json['permit'] as String;
    return (transfer: transfer, permit: permit, content: content);
  }

  Future<StreamPostResult> upload({
    required String transfer,
    required String permit,
    required int contentLength,
    required Stream<List<int>> body,
    InternetAddress? at,
  }) => postStream(
    address: at ?? target.internetAddress,
    port: target.port,
    path: ApiPaths.transferUpload,
    headers: {
      TransferHeaders.transfer: transfer,
      TransferHeaders.permit: permit,
    },
    contentLength: contentLength,
    body: body,
    context: _context,
    acceptServer: _acceptServer,
    sourceAddress: from,
    idleTimeout: const Duration(seconds: 30),
    answerTimeout: const Duration(seconds: 30),
    maxResponseBytes: Limits.maxTransferBodyBytes,
  );

  Future<StreamPostResult> send(Grant grant, {InternetAddress? at}) => upload(
    transfer: grant.transfer,
    permit: grant.permit,
    contentLength: grant.content.length,
    body: chunksOf(grant.content),
    at: at,
  );

  Future<int?> rawUpload(List<String> headerLines, List<int> body) async {
    SecureSocket? secure;
    try {
      final raw = await Socket.connect(
        target.internetAddress,
        target.port,
        sourceAddress: from,
        timeout: const Duration(seconds: 5),
      );
      secure = await SecureSocket.secure(
        raw,
        context: _context,
        onBadCertificate: _acceptServer,
      ).timeout(const Duration(seconds: 5));
      final received = <int>[];
      final done = secure.listen(received.addAll).asFuture<void>();
      final head = StringBuffer()
        ..write('POST ${ApiPaths.transferUpload} HTTP/1.1\r\n')
        ..write('Host: ${target.address}\r\n');
      for (final line in headerLines) {
        head.write('$line\r\n');
      }
      head
        ..write('Content-Length: ${body.length}\r\n')
        ..write('Connection: close\r\n\r\n');
      secure
        ..add(utf8.encode(head.toString()))
        ..add(body);
      await done.timeout(const Duration(seconds: 10));
      final match = RegExp(r'^HTTP/1\.1 (\d{3})')
          .firstMatch(latin1.decode(received));
      return match == null ? null : int.parse(match.group(1)!);
    } on Object {
      return null;
    } finally {
      secure?.destroy();
    }
  }

  Future<bool> cutInHandshake({InternetAddress? at}) async {
    Socket? raw;
    SecureSocket? secure;
    final received = <int>[];
    try {
      raw = await Socket.connect(
        at ?? target.internetAddress,
        target.port,
        sourceAddress: from,
        timeout: const Duration(seconds: 5),
      );
      secure = await SecureSocket.secure(
        raw,
        context: _context,
        onBadCertificate: _acceptServer,
      ).timeout(const Duration(seconds: 5));
      final body = utf8.encode(
        jsonEncode(WaitRequest(transfer: newTransferId()).toJson()),
      );
      secure.add(
        utf8.encode(
          'POST ${ApiPaths.transferWait} HTTP/1.1\r\n'
          'Host: ${target.address}\r\n'
          'Content-Type: application/json\r\n'
          'Content-Length: ${body.length}\r\n'
          'Connection: close\r\n\r\n',
        ),
      );
      secure.add(body);
      await secure
          .listen(received.addAll)
          .asFuture<void>()
          .timeout(const Duration(seconds: 5));
    } on Object {
      return received.isEmpty;
    } finally {
      secure?.destroy();
      raw?.destroy();
    }
    return received.isEmpty;
  }
}

typedef Grant = ({String transfer, String permit, List<int> content});

RawReply? answeredOf(StreamPostResult result) => switch (result) {
  StreamPostAnswered(:final response) => RawReply(
    response.status,
    Uint8List.fromList(response.body),
  ),
  StreamPostFailed() => null,
};

TransferOutcome? outcomeOfReply(RawReply? reply) {
  if (reply == null || reply.status != 200) return null;
  final state = RemoteState.tryParse(reply.json);
  return state == null ? null : outcomeOfRemote(state);
}

final class HostileReceiver {
  HostileReceiver._(this.identity, this._server, this.address);

  final DeviceIdentity identity;
  final HttpServer _server;
  final InternetAddress address;
  final List<String> paths = [];
  Future<void> Function(HttpRequest request)? onOffer;
  bool _stopped = false;

  int get port => _server.port;

  String get fingerprint => identity.fingerprint;

  int count(String path) => paths.where((p) => p == path).length;

  static Future<HostileReceiver> start(InternetAddress address) async {
    final identity = DeviceIdentity.generate();
    final server = await HttpServer.bindSecure(
      address,
      0,
      identity.serverContext(trustedCertificatesPem: const []),
    );
    final hostile = HostileReceiver._(identity, server, address);
    server.listen((request) => unawaited(hostile._serve(request)));
    addTearDown(hostile.close);
    return hostile;
  }

  Future<void> _serve(HttpRequest request) async {
    final path = request.uri.path;
    paths.add(path);
    try {
      final handler = onOffer;
      if (path == ApiPaths.transferOffer && handler != null) {
        await request.drain<void>();
        await handler(request);
        return;
      }
      await request.drain<void>();
      final answer = path == ApiPaths.transferCancel
          ? (200, {'state': 'cancelled'})
          : (404, {'error': 'not_found'});
      await answerJson(request, answer.$1, answer.$2);
    } catch (_) {
      try {
        await request.response.close();
      } catch (_) {}
    }
  }

  Future<void> trickle(HttpRequest request, {bool declared = true}) async {
    final response = request.response
      ..bufferOutput = false
      ..statusCode = 200
      ..contentLength = declared ? 4 * kib : -1;
    response.headers.contentType = ContentType.json;
    while (!_stopped) {
      response.add(const [32]);
      await response.flush();
      await Future<void>.delayed(const Duration(milliseconds: 200));
    }
  }

  Future<void> answerJson(
    HttpRequest request,
    int status,
    Map<String, Object?> json, {
    bool declared = true,
  }) async {
    final bytes = utf8.encode(jsonEncode(json));
    final response = request.response
      ..persistentConnection = false
      ..statusCode = status
      ..contentLength = declared ? bytes.length : -1
      ..add(bytes);
    response.headers.contentType = ContentType.json;
    await response.close();
  }

  Future<void> close() async {
    _stopped = true;
    await _server.close(force: true);
  }
}
