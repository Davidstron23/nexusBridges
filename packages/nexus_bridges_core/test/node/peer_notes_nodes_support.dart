import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:nexus_bridges_core/src/identity/identity.dart';
import 'package:nexus_bridges_core/src/network/network.dart';
import 'package:nexus_bridges_core/src/node/node.dart';
import 'package:nexus_bridges_core/src/pairing/pairing.dart';
import 'package:nexus_bridges_core/src/protocol/protocol.dart';
import 'package:nexus_bridges_core/src/server/server.dart';
import 'package:nexus_bridges_core/src/storage/storage.dart';
import 'package:test/test.dart';

import 'pairing_nodes_harness.dart' show freeTcpPort, pairedEntryFor;
import 'transfer_nodes_harness.dart';

File peersFileOf(TransferNode node) => File('${node.dataPath}\\peers.json');

String peersText(TransferNode node) {
  final file = peersFileOf(node);
  for (var attempt = 0; ; attempt++) {
    try {
      return file.existsSync() ? file.readAsStringSync() : '';
    } on FileSystemException {
      if (attempt == 200) rethrow;
      sleep(const Duration(milliseconds: 5));
    }
  }
}

List<String> peersFilesAside(TransferNode node) => [
  for (final entity in Directory(node.dataPath).listSync())
    if (entity.path.split(r'\').last.startsWith('peers.json.'))
      entity.path.split(r'\').last,
];

PeerSettingsView? viewOf(TransferNode viewer, TransferNode other) =>
    viewer.state.peers[other.fingerprint];

Future<PeerSettingsView> untilView(
  TransferNode viewer,
  TransferNode other,
  bool Function(PeerSettingsView view) condition, {
  String? reason,
  Duration? limit,
}) async {
  final state = await viewer.until(
    (s) {
      final view = s.peers[other.fingerprint];
      return view != null && condition(view);
    },
    reason: reason,
    limit: limit,
  );
  return state.peers[other.fingerprint]!;
}

Future<PeerSettingsView> historyOf(
  TransferNode viewer,
  TransferNode other,
  int count, {
  Duration? limit,
}) => untilView(
  viewer,
  other,
  (view) => view.history.length >= count,
  reason: '${viewer.name} with $count history entries',
  limit: limit,
);

Future<void> peersFileShows(
  TransferNode node,
  bool Function(String text) condition, {
  String reason = 'peers.json',
  Duration? limit,
}) =>
    eventually(() => condition(peersText(node)), reason: reason, limit: limit);

bool containsBytes(List<int> haystack, List<int> needle) {
  if (needle.isEmpty) return true;
  for (var i = 0; i + needle.length <= haystack.length; i++) {
    var match = true;
    for (var j = 0; j < needle.length; j++) {
      if (haystack[i + j] != needle[j]) {
        match = false;
        break;
      }
    }
    if (match) return true;
  }
  return false;
}

Uint8List? bytesWhenFree(File file) {
  for (var attempt = 0; ; attempt++) {
    try {
      return file.readAsBytesSync();
    } on PathNotFoundException {
      return null;
    } on FileSystemException {
      if (attempt == 200) rethrow;
      sleep(const Duration(milliseconds: 5));
    }
  }
}

List<FileSystemEntity> _listWhenFree(Directory folder) {
  for (var attempt = 0; ; attempt++) {
    try {
      return folder.listSync(recursive: true);
    } on FileSystemException {
      if (attempt == 200) rethrow;
      sleep(const Duration(milliseconds: 5));
    }
  }
}

String textWhenFree(File file) {
  final bytes = bytesWhenFree(file);
  return bytes == null ? '' : utf8.decode(bytes);
}

void expectNoAliasOnDisk(Directory folder, String alias) {
  final raw = utf8.encode(alias);
  for (final entity in _listWhenFree(folder)) {
    if (entity is! File) continue;
    final bytes = bytesWhenFree(entity);
    if (bytes == null) continue;
    expect(
      containsBytes(bytes, raw),
      isFalse,
      reason: '${entity.path} holds the alias',
    );
  }
}

Future<void> pairAgain(TransferNode initiator, TransferNode receiver) async {
  await meet(initiator, receiver);
  expect(
    await initiator.node.pair(receiver.fingerprint),
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
  initiator.node.answerCode(matches: true);
  receiver.node.answerRequest(ReceiverAnswer.matches);
  await initiator.until(
    (s) => s.peers.containsKey(receiver.fingerprint),
    reason: 'initiator paired',
  );
  await receiver.until(
    (s) => s.peers.containsKey(initiator.fingerprint),
    reason: 'receiver paired',
  );
}

final class AnnouncementCapture {
  AnnouncementCapture._();

  final List<Uint8List> datagrams = [];

  static Future<AnnouncementCapture> of(TransferNode node) async {
    final socket = await RawDatagramSocket.bind(
      InternetAddress('127.0.0.9'),
      node.channelPort,
      reuseAddress: false,
    );
    addTearDown(socket.close);
    final all = await NetworkInterface.list(includeLoopback: true);
    final loopback = all.firstWhere(
      (i) => i.addresses.any((a) => a.address == '127.0.0.1'),
    );
    socket.joinMulticast(multicastGroup, loopback);
    final capture = AnnouncementCapture._();
    socket.listen((event) {
      if (event != RawSocketEvent.read) return;
      Datagram? datagram;
      while ((datagram = socket.receive()) != null) {
        capture.datagrams.add(datagram!.data);
      }
    });
    return capture;
  }

  List<String?> namesFrom(String fingerprint) => [
    for (final bytes in datagrams)
      if (Announcement.tryDecode(bytes) case final a?
          when a.info.fingerprint == fingerprint)
        a.info.name,
  ];

  bool anyContains(List<int> needle) =>
      datagrams.any((bytes) => containsBytes(bytes, needle));
}

final class RecordingPeer {
  RecordingPeer._(this.identity, this.address, this.port, this.name);

  final DeviceIdentity identity;
  final InternetAddress address;
  final int port;
  final String name;
  final List<(String, String)> calls = [];
  late final ApiServer server;

  String get fingerprint => identity.fingerprint;

  Iterable<String> get paths => calls.map((call) => call.$1);

  static Future<RecordingPeer?> start({
    required InternetAddress address,
    required int port,
    required DeviceIdentity owner,
    required String ownerName,
    String name = 'Recorder PC',
  }) async {
    final dir = await Directory.systemTemp.createTemp('nexus_recording_peer_');
    addTearDown(() async {
      for (var attempt = 0; attempt < 40; attempt++) {
        try {
          if (dir.existsSync()) await dir.delete(recursive: true);
          return;
        } on FileSystemException {
          await Future<void>.delayed(const Duration(milliseconds: 25));
        }
      }
    });
    final peer = RecordingPeer._(
      DeviceIdentity.generate(),
      address,
      port,
      name,
    );
    final paired = PairedDevicesStore(
      JsonFileStore(File('${dir.path}\\paired.json')),
      ownerFingerprint: peer.fingerprint,
    );
    await paired.load();
    await paired.replaceAll([
      pairedEntryFor(owner, name: ownerName, relation: PeerRelation.mine),
    ]);
    ApiRoute record(String path, RouteAccess access) => ApiRoute(
      path: path,
      access: access,
      handle: (call) async {
        peer.calls.add((path, jsonEncode(call.json)));
        return const ApiReply(403, {'error': 'forbidden'});
      },
    );
    final all = await NetworkInterface.list(includeLoopback: true);
    final loopback = all.firstWhere(
      (i) => i.addresses.any((a) => a.address == '127.0.0.1'),
    );
    peer.server = ApiServer(
      identity: peer.identity,
      paired: paired,
      selfInfo: () => DeviceInfo(
        name: name,
        fingerprint: peer.fingerprint,
        port: port,
        protocol: protocolVersion,
        deviceType: DeviceType.desktop,
      ),
      onRegistered: (caller, _, _) {
        peer.calls.add((ApiPaths.register, jsonEncode(caller.toJson())));
      },
      routes: [
        for (final path in const [
          ApiPaths.transferOffer,
          ApiPaths.transferWait,
          ApiPaths.transferCancel,
          ApiPaths.transferManifest,
          ApiPaths.browse,
          ApiPaths.unpair,
        ])
          record(path, RouteAccess.paired),
        record(ApiPaths.pairStatus, RouteAccess.anonymous),
      ],
      port: port,
    );
    addTearDown(peer.server.close);
    await peer.server.syncInterfaces([
      ActiveInterface(
        id: 'recording#${address.address}',
        adapterId: 'recording',
        friendlyName: loopback.name,
        subnet: Ipv4Subnet(address, 30),
      ),
    ]);
    if (peer.server.openInterfaceIds.length != 1) return null;
    return peer;
  }
}

Future<(TransferNode, RecordingPeer)> nodeWithRecorder() async {
  for (var attempt = 0; attempt < 5; attempt++) {
    final port = await freeTcpPort(hosts: const ['127.0.0.1', '127.0.0.2']);
    final a = await TransferNode.create('Desk PC', '127.0.0.1', port: port);
    final idA = await a.loadIdentity();
    final peer = await RecordingPeer.start(
      address: InternetAddress('127.0.0.2'),
      port: port,
      owner: idA,
      ownerName: a.name,
    );
    if (peer == null) continue;
    await a.writePaired(idA, [
      pairedEntryFor(
        peer.identity,
        name: peer.name,
        relation: PeerRelation.mine,
      ),
    ]);
    await a.rememberFolder();
    await a.start();
    return (a, peer);
  }
  fail('no free port for the recording peer');
}

List<String> looseHex32(String text, Set<String> allowed) =>
    RegExp(r'(?<![0-9a-fA-F])[0-9a-f]{32}(?![0-9a-fA-F])')
        .allMatches(text)
        .map((m) => m.group(0)!)
        .where((v) => !allowed.contains(v))
        .toList();
