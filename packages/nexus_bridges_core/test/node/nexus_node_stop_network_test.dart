import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:nexus_bridges_core/src/identity/identity.dart';
import 'package:nexus_bridges_core/src/network/network.dart';
import 'package:nexus_bridges_core/src/node/node.dart';
import 'package:nexus_bridges_core/src/protocol/protocol.dart'
    show
        Announcement,
        AnnouncementKind,
        ApiPaths,
        DeviceInfo,
        DeviceType,
        multicastGroup,
        protocolVersion;
import 'package:nexus_bridges_core/src/transport/transport.dart';
import 'package:test/test.dart';

import '../support/infra.dart' show pickPort;
import 'two_nodes_harness.dart';

const Duration _fiveSeconds = Duration(seconds: 5);
final Matcher _endedThere = isIn([
  PairingOutcome.cancelledByPeer,
  PairingOutcome.lost,
]);
const String _wired = '{WIRED-ADAPTER}';
final InternetAddress _secondA = InternetAddress('127.0.0.5');
final InternetAddress _secondPeer = InternetAddress('127.0.0.6');

AdapterInfo _adapter(String id, String networkId, String name, String ip) =>
    AdapterInfo(
      id: id,
      friendlyName: name,
      description: 'Test adapter $name',
      ifType: 6,
      isUp: true,
      ipv4: [Ipv4Subnet(InternetAddress(ip), 24)],
      hasGateway: true,
      networkId: networkId,
      networkName: name,
    );

File _networksOf(TestNode node) =>
    File('${node.dataDir.path}${sep}networks.json');

void _break(File file) {
  if (file.existsSync()) file.deleteSync();
  Directory(file.path).createSync(recursive: true);
}

void _repair(File file) {
  final dir = Directory(file.path);
  if (dir.existsSync()) dir.deleteSync(recursive: true);
}

Future<String?> _savedDecision(TestNode node, String networkId) async {
  final file = _networksOf(node);
  if (!file.existsSync()) return null;
  final json = jsonDecode(await file.readAsString()) as Map<String, Object?>;
  final networks = json['networks'] as Map<String, Object?>;
  return (networks[networkId] as Map?)?['decision'] as String?;
}

Future<void> _stop(TestNode node, String networkId) =>
    node.inZone(() => node.node.stopUsingNetwork(networkId));

Future<void> _trust(TestNode node, String networkId) => node.inZone(
  () => node.node.decideNetwork(networkId, NetworkDecision.trusted),
);

TrustedNetworkView? _viewOf(TestNode node, String networkId) {
  for (final view in node.state.trustedNetworks) {
    if (view.networkId == networkId) return view;
  }
  return null;
}

Future<bool> _accepts(InternetAddress address, int port) async {
  try {
    final socket = await Socket.connect(
      address,
      port,
      sourceAddress: address == hostA ? hostB : hostA,
      timeout: const Duration(seconds: 2),
    );
    socket.destroy();
    return true;
  } on SocketException {
    return false;
  }
}

Future<Duration> _within(
  bool Function() condition, {
  required String reason,
  Duration limit = const Duration(seconds: 15),
}) async {
  final watch = Stopwatch()..start();
  while (!condition()) {
    if (watch.elapsed > limit) fail('$reason: not within ${watch.elapsed}');
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  return watch.elapsed;
}

final class _Capture {
  _Capture._();

  final List<(Announcement, DateTime)> heard = [];
  RawDatagramSocket? _relay;
  int _relayPort = 0;
  String? _relayOf;

  Future<void> relayTo(TestNode from, TestNode to) async {
    final socket = await RawDatagramSocket.bind(
      from.address,
      0,
      reuseAddress: false,
    );
    addTearDown(socket.close);
    _relay = socket;
    _relayPort = to.udpPort;
    _relayOf = from.fingerprint;
  }

  static Future<_Capture> of(TestNode node) async {
    final socket = await RawDatagramSocket.bind(
      node.address == hostA ? hostB : hostA,
      node.udpPort,
      reuseAddress: false,
    );
    addTearDown(socket.close);
    final all = await NetworkInterface.list(includeLoopback: true);
    final loopback = all.firstWhere(
      (i) => i.addresses.any((a) => a.address == '127.0.0.1'),
    );
    socket.joinMulticast(multicastGroup, loopback);
    final capture = _Capture._();
    socket.listen((event) {
      if (event != RawSocketEvent.read) return;
      Datagram? datagram;
      while ((datagram = socket.receive()) != null) {
        final announcement = Announcement.tryDecode(datagram!.data);
        if (announcement != null) {
          capture.heard.add((announcement, DateTime.now()));
          final relay = capture._relay;
          if (relay != null &&
              announcement.info.fingerprint == capture._relayOf) {
            relay.send(
              datagram.data,
              InternetAddress.loopbackIPv4,
              capture._relayPort,
            );
          }
        }
      }
    });
    return capture;
  }

  List<Announcement> from(String fingerprint, {AnnouncementKind? kind}) => [
    for (final (a, _) in heard)
      if (a.info.fingerprint == fingerprint && (kind == null || a.kind == kind))
        a,
  ];
}

Future<int?> _post(
  DeviceIdentity caller, {
  required InternetAddress to,
  required int port,
  required InternetAddress from,
  required String path,
  required Object json,
  required String expectedFingerprint,
}) async {
  final response = await postJson(
    address: to,
    port: port,
    path: path,
    json: json,
    context: caller.clientContext(presentCertificate: false),
    acceptServer: (certificate) {
      try {
        return fingerprintOfCertificate(certificate.der) == expectedFingerprint;
      } catch (_) {
        return false;
      }
    },
    sourceAddress: from,
    timeout: const Duration(seconds: 3),
  );
  return response?.status;
}

Map<String, Object?> _infoJson(DeviceIdentity identity, int port) => DeviceInfo(
  name: 'Stranger',
  fingerprint: identity.fingerprint,
  port: port,
  protocol: protocolVersion,
  deviceType: DeviceType.desktop,
).toJson();

Future<void> _sendHello(
  InternetAddress from,
  int toPort,
  DeviceIdentity identity,
  int declaredPort,
) async {
  final socket = await RawDatagramSocket.bind(from, 0, reuseAddress: false);
  addTearDown(socket.close);
  final bytes = Uint8List.fromList(
    Announcement(
      AnnouncementKind.hello,
      DeviceInfo(
        name: 'Stranger',
        fingerprint: identity.fingerprint,
        port: declaredPort,
        protocol: protocolVersion,
        deviceType: DeviceType.desktop,
      ),
    ).encode(),
  );
  final watch = Stopwatch()..start();
  while (socket.send(bytes, InternetAddress.loopbackIPv4, toPort) !=
      bytes.length) {
    if (watch.elapsed > const Duration(seconds: 5)) fail('hello not sent');
    await Future<void>.delayed(const Duration(milliseconds: 1));
  }
}

List<ActiveInterface> _twoInterfaces(
  List<InterfaceState> states,
  String loopback,
) => [
  for (final state in states)
    if (state.status == InterfaceStatus.active)
      if (state.adapter.id == testAdapter)
        ActiveInterface(
          id: '$testAdapter#127.0.0.1',
          adapterId: testAdapter,
          friendlyName: loopback,
          subnet: Ipv4Subnet(hostA, 30),
        )
      else if (state.adapter.id == _wired)
        ActiveInterface(
          id: '$_wired#127.0.0.5',
          adapterId: _wired,
          friendlyName: loopback,
          subnet: Ipv4Subnet(_secondA, 30),
        ),
];

List<ActiveInterface> _onlyTestAdapter(
  List<InterfaceState> states,
  String loopback,
) => [
  for (final state in states)
    if (state.status == InterfaceStatus.active &&
        state.adapter.id == testAdapter)
      ActiveInterface(
        id: '$testAdapter#127.0.0.1',
        adapterId: testAdapter,
        friendlyName: loopback,
        subnet: Ipv4Subnet(hostA, 30),
      ),
];

void main() {
  group('E831: leaving a trusted network the node is not on (RF-532) '
      '[SEG]', () {
    test('it leaves the list at once and the listener, the hellos and what B '
        'sees through the real network stay as they were', () async {
      final (a, b) = await twoNodes();
      await meet(a, b);
      await _trust(a, otherNetwork);
      await a.until(
        (s) => s.trustedNetworks.length == 2,
        reason: 'two trusted networks listed',
      );
      final capture = await _Capture.of(a);
      final logs = a.logs.length;

      await _stop(a, otherNetwork);

      expect(a.state.trustedNetworks.map((v) => v.networkId), [homeNetwork]);
      expect(await _savedDecision(a, otherNetwork), 'untrusted');
      await pause(const Duration(seconds: 2));
      expect(a.state.paused, isFalse);
      expect(b.sees(a), isTrue);
      expect(b.entryOf(a.fingerprint)?.visible, isTrue);
      expect(await _accepts(hostA, a.port), isTrue);
      expect(capture.from(a.fingerprint, kind: AnnouncementKind.bye), isEmpty);
      expect(
        a.logs.skip(logs).where((l) => l.contains('listening')),
        isEmpty,
        reason: 'the listener is not touched',
      );
      await b.inZone(() => b.node.rescan());
      await pause();
      expect(b.sees(a), isTrue);
      expect(a.state.notices, isEmpty);
    }, timeout: twoNodesTimeout);

    test(
      'a network that is not trusted, or unknown, changes nothing',
      () async {
        final (a, _) = await twoNodes();
        final before = a.state.trustedNetworks;

        await _stop(a, '{NETWORK-UNKNOWN}');

        expect(a.state.trustedNetworks, before);
        expect(a.state.paused, isFalse);
      },
      timeout: twoNodesTimeout,
    );
  });

  group('E833: leaving the current network, not paired (RF-534) [SEG]', () {
    test('B stops listing A within 5 s; after the bye no datagram of A comes '
        'out for 3 s, a TCP connection to its port is refused and A is '
        'paused with the network to use again', () async {
      final (a, b) = await twoNodes();
      await meet(a, b);
      expect(await _accepts(hostA, a.port), isTrue);
      final capture = await _Capture.of(a);
      await capture.relayTo(a, b);

      final watch = Stopwatch()..start();
      await _stop(a, homeNetwork);
      final gone = await _within(
        () => !b.sees(a),
        reason: 'B drops A',
      ).then((_) => watch.elapsed);

      expect(gone, lessThanOrEqualTo(_fiveSeconds));
      await eventually(
        () =>
            capture.from(a.fingerprint, kind: AnnouncementKind.bye).isNotEmpty,
        reason: 'the bye of A is heard',
      );
      expect(
        capture.from(a.fingerprint, kind: AnnouncementKind.bye),
        hasLength(1),
      );
      final heard = capture.from(a.fingerprint).length;
      final silence = Stopwatch()..start();
      while (silence.elapsed < const Duration(seconds: 3)) {
        await a.inZone(() => a.node.rescan());
        await pause();
      }
      expect(capture.from(a.fingerprint), hasLength(heard));
      expect(await _accepts(hostA, a.port), isFalse);
      expect(a.state.paused, isTrue);
      expect(
        a.state.pausedNetworks.map((p) => p.networkId),
        contains(homeNetwork),
      );
      expect(a.state.prompts, isEmpty);
      expect(a.state.trustedNetworks, isEmpty);
      expect(await _savedDecision(a, homeNetwork), 'untrusted');
      expect(a.state.notices, isEmpty);
      expect(
        a.logs.where((l) => l.contains('Home')),
        isEmpty,
        reason: 'logs never carry network names',
      );
    }, timeout: twoNodesTimeout);
  });

  group('E834: leaving the current network, paired (RF-534)', () {
    test('B shows A as not visible within 5 s and they stay paired', () async {
      final (a, b) = await twoNodes();
      await meet(a, b);
      await pairNodes(a, b);
      expect(b.entryOf(a.fingerprint)?.visible, isTrue);
      final capture = await _Capture.of(a);
      await capture.relayTo(a, b);

      final watch = Stopwatch()..start();
      await _stop(a, homeNetwork);
      await _within(
        () => b.entryOf(a.fingerprint)?.visible == false,
        reason: 'B shows A as not visible',
      );

      expect(watch.elapsed, lessThanOrEqualTo(_fiveSeconds));
      expect(
        capture.from(a.fingerprint, kind: AnnouncementKind.bye),
        hasLength(1),
      );
      expect(b.hasPaired(a), isTrue);
      expect(b.entryOf(a.fingerprint)?.paired, isTrue);
      expect(a.state.paused, isTrue);
    }, timeout: twoNodesTimeout);
  });

  group('E836 and E832: a pairing on the network (RF-533, RF-534) [SEG]', () {
    test('while comparing, the network shows pairing true and another one '
        'false; leaving it ends the pairing with networkChanged here and cut by the peer there (RF-92)', () async {
      final (a, b) = await twoNodes();
      await meet(a, b);
      await _trust(a, otherNetwork);
      await bothComparing(a, b);

      await a.until(
        (s) => _viewOf(a, homeNetwork)?.pairing == true,
        reason: 'pairing shown on the network',
      );
      expect(_viewOf(a, homeNetwork)!.transfers, 0);
      expect(_viewOf(a, otherNetwork)!.pairing, isFalse);
      expect(_viewOf(a, otherNetwork)!.transfers, 0);

      await _stop(a, homeNetwork);

      final endA = await a.until(
        (s) => s.pairing?.phase == PairingPhase.finished,
        reason: 'A ends the pairing',
      );
      expect(endA.pairing!.outcome, PairingOutcome.networkChanged);
      final endB = await b.until(
        (s) => s.pairing == null || s.pairing!.phase == PairingPhase.finished,
        limit: const Duration(seconds: 15),
        reason: 'B ends the pairing',
      );
      expect(endB.pairing?.outcome, _endedThere);
      expect(b.hasPaired(a), isFalse);
      expect(a.hasPaired(b), isFalse);
    }, timeout: twoNodesTimeout);

    test(
      'the same when the node that leaves is the one that was asked',
      () async {
        final (a, b) = await twoNodes();
        await meet(a, b);
        await bothComparing(b, a);
        await a.until(
          (s) => _viewOf(a, homeNetwork)?.pairing == true,
          reason: 'pairing shown on the network',
        );

        await _stop(a, homeNetwork);

        final endA = await a.until(
          (s) => s.pairing?.phase == PairingPhase.finished,
          reason: 'A ends the pairing',
        );
        expect(endA.pairing!.outcome, PairingOutcome.networkChanged);
        final endB = await b.until(
          (s) => s.pairing == null || s.pairing!.phase == PairingPhase.finished,
          limit: const Duration(seconds: 15),
          reason: 'B ends the pairing',
        );
        expect(endB.pairing?.outcome, _endedThere);
      },
      timeout: twoNodesTimeout,
    );
  });

  group('E837: after a restart the network stays left (RF-534, RF-11)', () {
    test('a restart starts paused on it without asking; trusting it again '
        'from the pause brings both back', () async {
      final (a, b) = await twoNodes();
      await meet(a, b);
      await _stop(a, homeNetwork);
      await a.until((s) => s.paused, reason: 'A paused');

      await a.node.shutdown();
      final before = a.logs.length;
      await a.boot();
      await a.until(
        (s) => s.pausedNetworks.any((p) => p.networkId == homeNetwork),
        reason: 'A starts paused on the network',
      );
      expect(a.state.prompts, isEmpty);
      expect(a.state.paused, isTrue);
      expect(a.state.trustedNetworks, isEmpty);
      expect(await _accepts(hostA, a.port), isFalse);

      expect(await a.listenSince(before), isTrue);
      await meet(a, b);
      expect(a.state.paused, isFalse);
      expect(a.state.trustedNetworks.single.networkId, homeNetwork);
      expect(a.state.trustedNetworks.single.connected, isTrue);
    }, timeout: twoNodesTimeout);
  });

  group('E838: leaving a network that cannot be saved (RF-535, clarify '
      'point 21)', () {
    test('networks.json not writable: the network is left for the session '
        'with a retryable notice; retrySave saves it once writable and '
        'removes the notice', () async {
      final (a, b) = await twoNodes();
      await meet(a, b);
      await _trust(a, homeNetwork);
      expect(_viewOf(a, homeNetwork)?.name, 'Home');
      final file = _networksOf(a);
      _break(file);

      await _stop(a, homeNetwork);

      expect(a.state.paused, isTrue);
      expect(a.state.trustedNetworks, isEmpty);
      final notice = a.noticesOf(NoticeKind.networkStopNotSaved).single;
      expect(notice.canRetry, isTrue);
      expect(notice.detail, 'Home');
      expect(await _accepts(hostA, a.port), isFalse);

      await a.inZone(a.node.retrySave);
      expect(a.noticesOf(NoticeKind.networkStopNotSaved), hasLength(1));

      _repair(file);
      await a.inZone(a.node.retrySave);

      expect(a.noticesOf(NoticeKind.networkStopNotSaved), isEmpty);
      expect(await _savedDecision(a, homeNetwork), 'untrusted');
      expect(a.state.paused, isTrue);
    }, timeout: twoNodesTimeout);

    test('with the decision notice and the stop notice at once, a decision '
        'that is saved removes both', () async {
      final (a, _) = await twoNodes();
      final file = _networksOf(a);
      _break(file);
      await _trust(a, otherNetwork);
      await a.until((s) => s.decisionNotSaved, reason: 'decision not saved');

      await _stop(a, homeNetwork);
      expect(a.noticesOf(NoticeKind.networkStopNotSaved), hasLength(1));
      expect(a.state.decisionNotSaved, isTrue);

      _repair(file);
      await a.inZone(
        () => a.node.decideNetwork(otherNetwork, NetworkDecision.untrusted),
      );

      expect(a.noticesOf(NoticeKind.networkStopNotSaved), isEmpty);
      expect(a.state.decisionNotSaved, isFalse);
      expect(await _savedDecision(a, homeNetwork), 'untrusted');
      expect(await _savedDecision(a, otherNetwork), 'untrusted');
    }, timeout: twoNodesTimeout);
  });

  group('E841: nothing from the left subnet gets an answer (SEC-06, clarify '
      'point 12a) [SEG]', () {
    test(
      'after leaving the network of 127.0.0.1/30 while 127.0.0.5/30 stays '
      'trusted, a hello, a register and a pair/start from 127.0.0.2 get no '
      'answer and add nothing; the same from 127.0.0.6 is answered',
      () async {
        late TestNode a;
        for (var attempt = 0; attempt < 5; attempt++) {
          a = await TestNode.create('Desk PC', hostA);
          a
            ..port = await pickPort(
              tcp: [hostA, hostB, _secondA, _secondPeer],
              udp: [InternetAddress.anyIPv4],
            )
            ..adapters = [
              adapterOn(homeNetwork),
              _adapter(_wired, otherNetwork, 'Other', '192.168.88.10'),
            ]
            ..activeOfOverride = _twoInterfaces;
          if (await a.launch()) break;
          await a.node.shutdown();
        }
        final before = a.logs.length;
        await _trust(a, otherNetwork);
        await eventually(
          () => a.logs.skip(before).contains('listening on $_wired#127.0.0.5'),
          reason: 'listening on the second interface',
        );
        final stranger = DeviceIdentity.generate();
        final witnessPort = await pickPort(tcp: [hostB]);
        final witness = await SilentListener.bind(hostB, witnessPort);
        final controlPort = await pickPort(tcp: [_secondPeer]);
        final control = await SilentListener.bind(_secondPeer, controlPort);

        await _stop(a, homeNetwork);
        expect(a.state.paused, isFalse);

        await _sendHello(hostB, a.udpPort, stranger, witnessPort);
        expect(
          await _post(
            stranger,
            to: _secondA,
            port: a.port,
            from: hostB,
            path: ApiPaths.register,
            json: _infoJson(stranger, 1),
            expectedFingerprint: a.fingerprint,
          ),
          isNull,
        );
        expect(
          await _post(
            stranger,
            to: _secondA,
            port: a.port,
            from: hostB,
            path: ApiPaths.pairStart,
            json: const {'protocol': protocolVersion},
            expectedFingerprint: a.fingerprint,
          ),
          isNull,
        );
        expect(await _accepts(hostA, a.port), isFalse);

        await _sendHello(_secondPeer, a.udpPort, stranger, controlPort);
        await eventually(
          () => control.accepted > 0,
          reason: 'control: a hello from 127.0.0.6 is checked',
        );
        expect(
          await _post(
            stranger,
            to: _secondA,
            port: a.port,
            from: _secondPeer,
            path: ApiPaths.register,
            json: _infoJson(stranger, 1),
            expectedFingerprint: a.fingerprint,
          ),
          200,
          reason: 'control: a register from 127.0.0.6 is answered',
        );
        await pause(const Duration(seconds: 1));

        expect(witness.accepted, 0, reason: 'no check toward 127.0.0.2');
        expect(a.state.pairing, isNull);
        expect(
          a.state.devices.where((d) => d.address.address == '127.0.0.2'),
          isEmpty,
        );
      },
      timeout: twoNodesTimeout,
    );
  });

  group('E842: the list follows the networks in real time (RF-531)', () {
    test('connecting and disconnecting a trusted network changes connected '
        'and the order within one poll (3 s)', () async {
      final (a, _) = await twoNodes(pollA: const Duration(seconds: 2));
      a.activeOfOverride = _onlyTestAdapter;
      a.advance(const Duration(days: 1));
      await _trust(a, otherNetwork);
      await a.until(
        (s) => s.trustedNetworks.length == 2,
        reason: 'two trusted networks',
      );
      expect(a.state.trustedNetworks.map((v) => (v.networkId, v.connected)), [
        (homeNetwork, true),
        (otherNetwork, false),
      ]);

      a.adapters = [
        adapterOn(homeNetwork),
        _adapter(_wired, otherNetwork, 'Other', '192.168.88.10'),
      ];
      final connected = await _within(
        () => _viewOf(a, otherNetwork)?.connected == true,
        reason: 'the other network connected',
      );
      expect(connected, lessThanOrEqualTo(const Duration(seconds: 3)));
      expect(a.state.trustedNetworks.map((v) => (v.networkId, v.connected)), [
        (otherNetwork, true),
        (homeNetwork, true),
      ]);

      a.adapters = [adapterOn(homeNetwork)];
      final gone = await _within(
        () => _viewOf(a, otherNetwork)?.connected == false,
        reason: 'the other network disconnected',
      );
      expect(gone, lessThanOrEqualTo(const Duration(seconds: 3)));
      expect(a.state.trustedNetworks.map((v) => (v.networkId, v.connected)), [
        (homeNetwork, true),
        (otherNetwork, false),
      ]);
    }, timeout: twoNodesTimeout);
  });
}
