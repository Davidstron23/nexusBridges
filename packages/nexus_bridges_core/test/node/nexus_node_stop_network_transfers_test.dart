@TestOn('windows')
library;

import 'dart:async';
import 'dart:io';

import 'package:nexus_bridges_core/src/network/network.dart';
import 'package:nexus_bridges_core/src/node/node.dart';
import 'package:nexus_bridges_core/src/pairing/pairing.dart' show PeerRelation;
import 'package:nexus_bridges_core/src/protocol/protocol.dart'
    show Announcement, AnnouncementKind, multicastGroup;
import 'package:test/test.dart';

import '../support/infra.dart' show onFreshPorts, scaled;
import 'pairing_nodes_harness.dart'
    show freeTcpPort, homeNetwork, pairedEntryFor, wifiAdapter;
import 'transfer_nodes_harness.dart';

const int _big = 4 * 1024 * 1024;
const String _otherNetwork = '{NETWORK-OTHER}';
const String _wired = '{WIRED-ADAPTER}';
const Duration _lateEnd = Duration(seconds: 60);
const List<TransferOutcome> _cutReasons = [
  TransferOutcome.interfaceDown,
  TransferOutcome.cancelledByPeer,
  TransferOutcome.connectionLost,
  TransferOutcome.noContact,
];

List<int> _bytes(int length, [int seed = 0]) =>
    List<int>.generate(length, (i) => (i + seed) % 251);

AdapterInfo _wiredOn(String networkId) => AdapterInfo(
  id: _wired,
  friendlyName: 'Ethernet',
  description: 'Test wired adapter',
  ifType: 6,
  isUp: true,
  ipv4: [Ipv4Subnet(InternetAddress('192.168.88.10'), 24)],
  hasGateway: true,
  networkId: networkId,
  networkName: networkId == homeNetwork ? 'Home' : 'Other',
);

Future<void> _stop(TransferNode node, String networkId) =>
    node.node.stopUsingNetwork(networkId);

TrustedNetworkView? _viewOf(TransferNode node, String networkId) {
  for (final view in node.state.trustedNetworks) {
    if (view.networkId == networkId) return view;
  }
  return null;
}

Future<bool> _accepts(
  InternetAddress address,
  int port,
  InternetAddress from,
) async {
  try {
    final socket = await Socket.connect(
      address,
      port,
      sourceAddress: from,
      timeout: const Duration(seconds: 2),
    );
    socket.destroy();
    return true;
  } on SocketException {
    return false;
  }
}

final class _Byes {
  final List<Announcement> heard = [];

  static Future<_Byes> of(TransferNode node, InternetAddress bindTo) async {
    final socket = await RawDatagramSocket.bind(
      bindTo,
      node.channelPort,
      reuseAddress: false,
    );
    addTearDown(socket.close);
    final all = await NetworkInterface.list(includeLoopback: true);
    final loopback = all.firstWhere(
      (i) => i.addresses.any((a) => a.address == '127.0.0.1'),
    );
    socket.joinMulticast(multicastGroup, loopback);
    final byes = _Byes();
    socket.listen((event) {
      if (event != RawSocketEvent.read) return;
      Datagram? datagram;
      while ((datagram = socket.receive()) != null) {
        final a = Announcement.tryDecode(datagram!.data);
        if (a != null && a.kind == AnnouncementKind.bye) byes.heard.add(a);
      }
    });
    return byes;
  }

  int from(String fingerprint) =>
      heard.where((a) => a.info.fingerprint == fingerprint).length;
}

List<ActiveInterface> Function(List<InterfaceState>, String) _splitA() =>
    (states, loopback) => [
      for (final state in states)
        if (state.status == InterfaceStatus.active)
          if (state.adapter.id == _wired)
            ActiveInterface(
              id: '$_wired#127.0.0.5',
              adapterId: _wired,
              friendlyName: loopback,
              subnet: Ipv4Subnet(InternetAddress('127.0.0.5'), 29),
            )
          else
            ActiveInterface(
              id: '${state.adapter.id}#127.0.0.1',
              adapterId: state.adapter.id,
              friendlyName: loopback,
              subnet: Ipv4Subnet(InternetAddress('127.0.0.1'), 30),
            ),
    ];

Future<(TransferNode, TransferNode)> _twoInterfaces({
  required String wiredNetwork,
}) async {
  const hosts = ['127.0.0.1', '127.0.0.5', '127.0.0.6'];
  final port = await freeTcpPort(hosts: hosts);
  final a = await TransferNode.create('Desk PC', hosts[0], port: port);
  final c = await TransferNode.create('Tablet', hosts[2], port: port);
  a
    ..adapters = [wifiAdapter(), _wiredOn(wiredNetwork)]
    ..activeOfOverride = _splitA();
  c.prefixLength = 29;
  final idA = await a.loadIdentity();
  final idC = await c.loadIdentity();
  await a.writePaired(idA, [
    pairedEntryFor(idC, name: c.name, relation: PeerRelation.mine),
  ]);
  await c.writePaired(idC, [
    pairedEntryFor(idA, name: a.name, relation: PeerRelation.mine),
  ]);
  await a.rememberFolder();
  await c.rememberFolder();
  final duo = [a, c];
  await onFreshPorts(
    () async {
      for (final node in duo) {
        await node.start();
      }
    },
    reset: () async {
      for (final node in duo) {
        try {
          await node.stop();
        } catch (_) {}
      }
      final fresh = await freeTcpPort(hosts: hosts);
      for (final node in duo) {
        node.port = fresh;
      }
    },
  );
  if (wiredNetwork != homeNetwork) {
    await a.node.decideNetwork(wiredNetwork, NetworkDecision.trusted);
  }
  await eventually(
    () => a.logs.contains('listening on $_wired#127.0.0.5'),
    reason: 'A listening on its second interface',
  );
  await meet(a, c);
  return (a, c);
}

void main() {
  group('E835: leaving the network cuts the transfers on it (RF-534, '
      'RF-188) [SEG]', () {
    test('A receiving a large file from B: the temporary file of A is gone '
        'and both end with their reason', () async {
      final (a, b) = await transferNodes();
      final big = await b.sourceFile('grande.bin', _bytes(_big));
      a.writes.delay = const Duration(milliseconds: 40);
      expect(await b.send(a, big), SendResult.started);
      await eventually(() => a.writes.written > 0, reason: 'A writing');
      expect(a.tempLeftIn(a.recvDir), isTrue);
      b.clock.followRealTime();

      await _stop(a, homeNetwork);

      final here = await a.receivedResult();
      expect(here.outcome, TransferOutcome.interfaceDown);
      final there = await b.sentResult(limit: scaled(_lateEnd));
      expect(there.outcome, isIn(_cutReasons));
      await eventually(
        () => !a.tempLeftIn(a.recvDir),
        reason: 'the temporary folder of A is removed',
      );
      expect(File('${a.recvDir}\\grande.bin').existsSync(), isFalse);
    }, timeout: transferTimeout);

    test('A sending a large file to B: the temporary file of B is gone and '
        'both see the reason', () async {
      final (a, b) = await transferNodes();
      final big = await a.sourceFile('grande.bin', _bytes(_big));
      b.writes.delay = const Duration(milliseconds: 40);
      expect(await a.send(b, big), SendResult.started);
      await eventually(() => b.writes.written > 0, reason: 'B writing');
      expect(b.tempLeftIn(b.recvDir), isTrue);
      b.clock.followRealTime();

      await _stop(a, homeNetwork);

      final here = await a.sentResult(
        limit: scaled(const Duration(seconds: 30)),
      );
      expect(here.outcome, TransferOutcome.interfaceDown);
      final there = await b.receivedResult();
      expect(there.outcome, isIn(_cutReasons));
      await eventually(
        () => !b.tempLeftIn(b.recvDir),
        limit: scaled(const Duration(seconds: 30)),
        reason: 'the temporary folder of B is removed',
      );
      expect(File('${b.recvDir}\\grande.bin').existsSync(), isFalse);
    }, timeout: transferTimeout);
  });

  group('E836: an open foreign notice is closed (RF-534) [SEG]', () {
    test('the notice of a foreign device that came through the network is '
        'closed and B cannot complete the send', () async {
      final (a, b) = await transferNodes(bAtA: PeerRelation.foreign);
      final file = await b.sourceFile('doc.txt', _bytes(1000));
      expect(await b.send(a, file), SendResult.started);
      final warning = await a.incomingAt(IncomingStage.warning);
      b.clock.followRealTime();

      await _stop(a, homeNetwork);

      await a.until(
        (s) => s.incoming == null || s.incoming!.stage == IncomingStage.ended,
        reason: 'the warning is closed',
      );
      a.node.answerIncoming(warning.sessionId, accept: true);
      await Future<void>.delayed(const Duration(seconds: 3));
      expect(b.state.lastSent?.outcome, isNot(TransferOutcome.saved));
      expect(b.state.outgoing?.phase, isNot(OutgoingPhase.uploading));
      b.clock.advance(const Duration(minutes: 3));
      final there = await b.sentResult(limit: scaled(_lateEnd));
      expect(there.outcome, isNot(TransferOutcome.saved));
      expect(File('${a.recvDir}\\doc.txt').existsSync(), isFalse);
      expect(a.tempLeftIn(a.recvDir), isFalse);
    }, timeout: transferTimeout);
  });

  group('E832: what goes through each trusted network (RF-533)', () {
    test('an outgoing transfer gives 1, with a foreign notice that came '
        'through it 2; another trusted network gives 0 and false', () async {
      final (a, b, c) = await transferTrio(
        aAtB: PeerRelation.mine,
        cAtB: PeerRelation.foreign,
      );
      await b.node.decideNetwork(_otherNetwork, NetworkDecision.trusted);
      await b.until(
        (s) => s.trustedNetworks.length == 2,
        reason: 'two trusted networks at B',
      );
      expect(_viewOf(b, homeNetwork)!.transfers, 0);

      final big = await b.sourceFile('grande.bin', _bytes(_big));
      a.writes.hold();
      expect(await b.send(a, big), SendResult.started);
      await a.until(
        (s) => s.incoming?.stage == IncomingStage.receiving,
        reason: 'A receiving',
      );
      await b.until(
        (s) => _viewOf(b, homeNetwork)?.transfers == 1,
        reason: 'one transfer on the network',
      );

      final note = await c.sourceFile('nota.txt', _bytes(10));
      expect(await c.send(b, note), SendResult.started);
      await b.incomingAt(IncomingStage.warning);
      await b.until(
        (s) => _viewOf(b, homeNetwork)?.transfers == 2,
        reason: 'two transfers on the network',
      );
      final home = _viewOf(b, homeNetwork)!;
      expect(home.connected, isTrue);
      expect(home.pairing, isFalse);
      final other = _viewOf(b, _otherNetwork)!;
      expect(other.connected, isFalse);
      expect(other.transfers, 0);
      expect(other.pairing, isFalse);
      expect(b.state.trustedNetworks.first.networkId, homeNetwork);

      a.writes.release();
      b.node.answerIncoming(b.state.incoming!.sessionId, accept: false);
      await b.until(
        (s) => _viewOf(b, homeNetwork)?.transfers == 0,
        limit: scaled(const Duration(seconds: 30)),
        reason: 'nothing left on the network',
      );
    }, timeout: transferTimeout);
  });

  group('E839: two interfaces of the node (RF-534, edge case)', () {
    final first = InternetAddress('127.0.0.1');
    final second = InternetAddress('127.0.0.5');
    final peer = InternetAddress('127.0.0.6');

    test('both on the same network: both are left with one bye each, and '
        'neither answers any more', () async {
      final (a, _) = await _twoInterfaces(wiredNetwork: homeNetwork);
      final byes = await _Byes.of(a, InternetAddress('127.0.0.3'));
      expect(
        await _accepts(first, a.port, InternetAddress('127.0.0.2')),
        isTrue,
      );
      expect(await _accepts(second, a.port, peer), isTrue);

      await _stop(a, homeNetwork);

      await eventually(() => byes.from(a.fingerprint) >= 2, reason: 'two byes');
      await Future<void>.delayed(const Duration(milliseconds: 500));
      expect(byes.from(a.fingerprint), 2);
      expect(a.state.paused, isTrue);
      expect(
        await _accepts(first, a.port, InternetAddress('127.0.0.2')),
        isFalse,
      );
      expect(await _accepts(second, a.port, peer), isFalse);
      expect(a.state.trustedNetworks, isEmpty);
    }, timeout: transferTimeout);

    test('on different networks: only the chosen one is left, with one bye, '
        'and a transfer through the other goes on to the end', () async {
      final (a, c) = await _twoInterfaces(wiredNetwork: _otherNetwork);
      final byes = await _Byes.of(a, InternetAddress('127.0.0.3'));
      final big = await a.sourceFile('grande.bin', _bytes(_big));
      c.writes.delay = const Duration(milliseconds: 40);
      expect(await a.send(c, big), SendResult.started);
      await eventually(() => c.writes.written > 0, reason: 'C writing');

      await _stop(a, homeNetwork);

      await eventually(() => byes.from(a.fingerprint) >= 1, reason: 'one bye');
      expect(a.state.paused, isFalse);
      expect(
        await _accepts(first, a.port, InternetAddress('127.0.0.2')),
        isFalse,
      );
      expect(await _accepts(second, a.port, peer), isTrue);
      expect(a.state.trustedNetworks.map((v) => v.networkId), [_otherNetwork]);

      final received = await c.receivedResult();
      expect(received.outcome, TransferOutcome.saved);
      final sent = await a.sentResult(
        limit: scaled(const Duration(seconds: 30)),
      );
      expect(sent.outcome, TransferOutcome.saved);
      expect(File('${c.recvDir}\\grande.bin').lengthSync(), _big);
      expect(byes.from(a.fingerprint), 1);
    }, timeout: transferTimeout);
  });
}
