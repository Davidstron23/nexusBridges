import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:nexus_bridges_core/src/discovery/discovery.dart';
import 'package:nexus_bridges_core/src/identity/identity.dart';
import 'package:nexus_bridges_core/src/network/network.dart';
import 'package:nexus_bridges_core/src/node/node.dart';
import 'package:nexus_bridges_core/src/pairing/pairing.dart';
import 'package:nexus_bridges_core/src/protocol/protocol.dart';
import 'package:nexus_bridges_core/src/server/server.dart';
import 'package:nexus_bridges_core/src/storage/storage.dart';
import 'package:test/test.dart';

import '../server/api_server_harness.dart'
    show
        callerInfoOf,
        canBind,
        loopback,
        otherLoopback,
        registerRequest,
        sendOrCut;

typedef _Received = (Announcement, InternetAddress, ActiveInterface);
typedef _ActiveOf = List<ActiveInterface> Function(List<InterfaceState>);

const Duration _waitLimit = Duration(seconds: 5);
const Duration _helloLimit = Duration(seconds: 1);
const Duration _silence = Duration(milliseconds: 300);
const Duration _fastPoll = Duration(milliseconds: 50);
const Duration _slowPoll = Duration(minutes: 1);
const Duration _suggestTick = Duration(milliseconds: 1300);
const Duration _noEmission = Duration(milliseconds: 500);
const Duration _awayForAWhile = Duration(seconds: 6);
const Timeout _childTimeout = Timeout(Duration(minutes: 2));

const String _wifiId = '{WIFI-ADAPTER}';
const String _home = '{NETWORK-HOME}';
const String _cafe = '{NETWORK-CAFE}';
const NetworkPrompt _homePrompt = NetworkPrompt(_home, 'Home');
const NetworkPrompt _cafePrompt = NetworkPrompt(_cafe, 'Cafe');

final String _sep = Platform.pathSeparator;
final InternetAddress _first = InternetAddress('127.0.0.1');

late String _loopbackName;

final class _XorProtector implements SecretProtector {
  static Uint8List _xor(Uint8List data) =>
      Uint8List.fromList([for (final b in data) b ^ 0x5A]);

  @override
  Uint8List protect(Uint8List data) => _xor(data);

  @override
  Uint8List? unprotect(Uint8List data) => _xor(data);
}

AdapterInfo _wifi(
  String networkId,
  String networkName, {
  List<String> addresses = const ['192.168.50.21'],
}) => AdapterInfo(
  id: _wifiId,
  friendlyName: 'Wi-Fi',
  description: 'Test wireless adapter',
  ifType: 71,
  isUp: true,
  ipv4: [for (final a in addresses) Ipv4Subnet(InternetAddress(a), 24)],
  hasGateway: true,
  networkId: networkId,
  networkName: networkName,
);

ActiveInterface _iface(String adapterId, String address, int prefixLength) =>
    ActiveInterface(
      id: '$adapterId#$address',
      adapterId: adapterId,
      friendlyName: _loopbackName,
      subnet: Ipv4Subnet(InternetAddress(address), prefixLength),
    );

_ActiveOf _onLoopback(List<(String, int)> addresses) =>
    (states) => [
      for (final state in states)
        if (state.status == InterfaceStatus.active)
          for (final (address, prefix) in addresses)
            _iface(state.adapter.id, address, prefix),
    ];

final _ActiveOf _loopbackOnly = _onLoopback(const [('127.0.0.1', 8)]);

Future<String> _systemLoopbackName() async {
  final all = await NetworkInterface.list(includeLoopback: true);
  return all
      .firstWhere((i) => i.addresses.any((a) => a.address == '127.0.0.1'))
      .name;
}

Future<int> _freePort() async {
  while (true) {
    final tcp = await ServerSocket.bind(InternetAddress.anyIPv4, 0);
    final port = tcp.port;
    RawDatagramSocket? udp;
    try {
      udp = await RawDatagramSocket.bind(
        InternetAddress.anyIPv4,
        port,
        reuseAddress: false,
      );
    } on SocketException {
      udp = null;
    }
    udp?.close();
    await tcp.close();
    if (udp != null) return port;
  }
}

Future<void> _quiet() => Future<void>.delayed(_silence);

Future<void> _eventually(
  FutureOr<bool> Function() condition, {
  Duration limit = _waitLimit,
}) async {
  final deadline = DateTime.now().add(limit);
  while (!await condition()) {
    if (DateTime.now().isAfter(deadline)) {
      fail('condition not met within $limit');
    }
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}

Future<bool> _ownSocketOn(String protocol, int port) async {
  final result = await Process.run('netstat', ['-ano', '-p', protocol]);
  return '${result.stdout}'
      .split('\n')
      .map((line) => line.trim().split(RegExp(r'\s+')))
      .any(
        (cells) =>
            cells.length >= 3 &&
            cells.first == protocol &&
            cells[1].endsWith(':$port') &&
            cells.last == '$pid',
      );
}

Future<RawDatagramSocket> _socketOn(InternetAddress address) async {
  final socket = await RawDatagramSocket.bind(address, 0, reuseAddress: false);
  addTearDown(socket.close);
  return socket;
}

List<int> _foreignHello(String letter) => Announcement(
  AnnouncementKind.hello,
  DeviceInfo(
    name: 'Stranger $letter',
    fingerprint: letter * 64,
    port: 1,
    protocol: protocolVersion,
    deviceType: DeviceType.desktop,
  ),
).encode();

List<Object?> _shape(NodeState s) => [
  s.identityStatus,
  s.identityError,
  s.prompts,
  s.paused,
  s.pausedNetworks,
  [
    for (final d in s.devices)
      (d.info.fingerprint, d.address.address, d.info.name, d.paired),
  ],
  s.displayNames,
  s.suggestRescan,
  s.portInUse,
  s.decisionNotSaved,
  s.deviceName,
  s.fingerprint,
];

const List<String> _queuedFailures = [
  'decide network failed',
  'dismiss prompt failed',
  'ask again failed',
  'network change failed',
  'reconcile failed',
];

List<String> _failuresIn(List<String> logs) => [
  for (final line in logs)
    if (_queuedFailures.any(line.startsWith)) line,
];

Future<void> _crossed(
  Future<void> Function() calls,
  List<Object> uncaught,
) async {
  final finished = runZonedGuarded(calls, (error, _) => uncaught.add(error));
  await finished!.timeout(
    _waitLimit,
    onTimeout: () => fail('the crossed calls did not finish: $uncaught'),
  );
}

const String _holdTcpScript = '''
import 'dart:io';

Future<void> main() async {
  final server = await ServerSocket.bind(InternetAddress('127.0.0.1'), 0);
  server.listen((socket) => socket.destroy());
  stdout.writeln(server.port);
  await stdin.drain<void>();
  await server.close();
}
''';

const String _holdUdpScript = '''
import 'dart:io';

Future<void> main() async {
  final socket = await RawDatagramSocket.bind(
    InternetAddress.anyIPv4,
    0,
    reuseAddress: false,
  );
  stdout.writeln(socket.port);
  await stdin.drain<void>();
  socket.close();
}
''';

const String _lockScript = '''
import 'dart:io';

Future<void> main(List<String> args) async {
  final file = await File(args.first).open(mode: FileMode.append);
  await file.lock(FileLock.exclusive);
  stdout.writeln('locked');
  await stdin.drain<void>();
  await file.unlock();
  await file.close();
}
''';

Future<(String, Future<void> Function())> _child(
  String source, [
  List<String> args = const [],
]) async {
  final dir = await Directory.systemTemp.createTemp('nexus_node_child_');
  addTearDown(() => dir.delete(recursive: true));
  final script = File('${dir.path}${_sep}child.dart');
  await script.writeAsString(source);
  final process = await Process.start(Platform.resolvedExecutable, [
    script.path,
    ...args,
  ]);
  addTearDown(() async {
    process.kill();
    await process.exitCode;
  });
  process.stderr.drain<void>().ignore();
  final line = await process.stdout
      .transform(utf8.decoder)
      .transform(const LineSplitter())
      .first
      .timeout(const Duration(seconds: 60));
  return (
    line.trim(),
    () async {
      await process.stdin.close();
      expect(await process.exitCode.timeout(const Duration(seconds: 30)), 0);
    },
  );
}

final class _Fixture {
  _Fixture._(this.root, this.port, this.channel, this.logs);

  final Directory root;
  final int port;
  final MulticastChannel channel;
  final List<String> logs;
  final List<_Received> received = [];
  final List<NodeState> states = [];
  List<AdapterInfo> adapters = [_wifi(_home, 'Home')];
  DateTime clock = DateTime(2026, 10, 22, 12);
  int reads = 0;
  int plans = 0;
  Completer<void>? gate;
  late NexusNode node;
  late String _deviceName;
  late Duration _pollInterval;
  late _ActiveOf _activeOf;

  static Future<_Fixture> create({int? port}) async {
    final root = await Directory.systemTemp.createTemp('nexus_node_networks_');
    addTearDown(() => root.delete(recursive: true));
    final logs = <String>[];
    final chosen = port ?? await _freePort();
    final channel = MulticastChannel(port: chosen, log: logs.add);
    addTearDown(channel.close);
    final fixture = _Fixture._(root, chosen, channel, logs);
    final subscription = channel.incoming.listen(fixture.received.add);
    addTearDown(subscription.cancel);
    return fixture;
  }

  Directory get dataDir => Directory('${root.path}${_sep}data');

  File get networksFile => File('${dataDir.path}${_sep}networks.json');

  DateTime now() => clock;

  NodeState get state => node.state;

  List<Announcement> get ownHellos => [
    for (final (announcement, _, _) in received)
      if (announcement.kind == AnnouncementKind.hello &&
          announcement.info.fingerprint == node.state.fingerprint)
        announcement,
  ];

  List<String> get receivedFingerprints => [
    for (final (announcement, _, _) in received) announcement.info.fingerprint,
  ];

  Future<NexusNode> start({
    String deviceName = 'Test PC',
    Duration pollInterval = _slowPoll,
    _ActiveOf? activeOf,
  }) async {
    _deviceName = deviceName;
    _pollInterval = pollInterval;
    _activeOf = activeOf ?? _loopbackOnly;
    return _launch();
  }

  Future<NexusNode> restart() async {
    await node.shutdown();
    return _launch();
  }

  Future<NexusNode> _launch() async {
    final started = await NexusNode.start(
      dataDir: dataDir,
      protector: _XorProtector(),
      readNetworks: () async {
        reads++;
        final pending = gate;
        if (pending != null) await pending.future;
        return adapters;
      },
      port: port,
      deviceName: _deviceName,
      now: now,
      log: logs.add,
      activeOf: (states) {
        plans++;
        return _activeOf(states);
      },
      pollInterval: _pollInterval,
      channel: channel,
    );
    node = started;
    addTearDown(started.shutdown);
    final subscription = started.states.listen(states.add);
    addTearDown(subscription.cancel);
    return started;
  }

  Future<NodeState> until(
    bool Function(NodeState s) condition, {
    Duration limit = _waitLimit,
  }) async {
    await _eventually(() => condition(node.state), limit: limit);
    return node.state;
  }

  Future<void> startTrusted({
    Duration pollInterval = _slowPoll,
    _ActiveOf? activeOf,
  }) async {
    await start(pollInterval: pollInterval, activeOf: activeOf);
    await until((s) => s.prompts.isNotEmpty);
    await node.decideNetwork(_home, NetworkDecision.trusted);
    await _eventually(() => ownHellos.isNotEmpty);
  }

  Future<void> inject(RawDatagramSocket from, List<int> bytes) async {
    final deadline = DateTime.now().add(_waitLimit);
    while (from.send(bytes, InternetAddress.loopbackIPv4, port) !=
        bytes.length) {
      if (DateTime.now().isAfter(deadline)) fail('datagram not sent');
      await Future<void>.delayed(const Duration(milliseconds: 1));
    }
  }
}

final class _Peer {
  _Peer._(this.identity, this.discovery);

  final DeviceIdentity identity;
  final DiscoveryService discovery;

  static Future<_Peer> join(
    _Fixture f, {
    Duration announceInterval = _slowPoll,
  }) async {
    final identity = DeviceIdentity.generate(commonName: randomCommonName());
    final dir = await Directory.systemTemp.createTemp('nexus_node_peer_');
    addTearDown(() => dir.delete(recursive: true));
    final paired = PairedDevicesStore(
      JsonFileStore(File('${dir.path}${_sep}paired.json')),
      ownerFingerprint: identity.fingerprint,
    );
    await paired.load();
    final verifier = DeviceVerifier(identity: identity);
    late final ApiServer server;
    DeviceInfo selfInfo() => DeviceInfo(
      name: 'Peer PC',
      fingerprint: identity.fingerprint,
      port: server.boundPort ?? 0,
      protocol: protocolVersion,
      deviceType: DeviceType.desktop,
    );
    final discovery = DiscoveryService(
      identity: identity,
      selfInfo: selfInfo,
      paired: paired,
      channel: f.channel,
      verifier: verifier,
      scanner: SubnetScanner(verifier: verifier, hostsOf: (_) => const []),
      now: f.now,
      announceInterval: announceInterval,
    );
    server = ApiServer(
      identity: identity,
      paired: paired,
      selfInfo: selfInfo,
      onRegistered: discovery.handleRegistration,
      port: 0,
      now: f.now,
    );
    addTearDown(server.close);
    addTearDown(() => discovery.stop(sayGoodbye: false));
    final iface = _iface(_wifiId, '127.0.0.1', 8);
    await server.syncInterfaces([iface]);
    await discovery.start();
    await discovery.syncInterfaces([iface]);
    return _Peer._(identity, discovery);
  }
}

void main() {
  late DeviceIdentity caller;

  setUpAll(() async {
    _loopbackName = await _systemLoopbackName();
    caller = DeviceIdentity.generate(commonName: randomCommonName());
  });

  group('asking about a network (RF-11, RF-13, RF-19)', () {
    test('a network without a decision is asked about, the node is paused and '
        'nothing listens on its port', () async {
      final f = await _Fixture.create();
      await f.start();

      final state = await f.until((s) => s.prompts.isNotEmpty);

      expect(state.prompts, [_homePrompt]);
      expect(state.pausedNetworks, isEmpty);
      expect(state.paused, isTrue);
      expect(await canBind(loopback, f.port), isTrue);
    });

    test('dismissPrompt moves the network to pausedNetworks with paused true, '
        'and askAgain brings it back without saving any decision', () async {
      final f = await _Fixture.create();
      await f.start();
      await f.until((s) => s.prompts.isNotEmpty);

      f.node.dismissPrompt(_home);
      final dismissed = await f.until((s) => s.prompts.isEmpty);

      expect(dismissed.pausedNetworks, [_homePrompt]);
      expect(dismissed.paused, isTrue);

      f.node.askAgain(_home);
      final asked = await f.until((s) => s.prompts.isNotEmpty);

      expect(asked.prompts, [_homePrompt]);
      expect(asked.pausedNetworks, isEmpty);
      expect(asked.paused, isTrue);
      expect(await f.networksFile.exists(), isFalse);
    });

    test('a dismissed network is not asked about again when the networks are '
        'read again, and it is asked about after a new start', () async {
      final f = await _Fixture.create();
      await f.start(pollInterval: _fastPoll);
      await f.until((s) => s.prompts.isNotEmpty);
      f.node.dismissPrompt(_home);
      await f.until((s) => s.pausedNetworks.isNotEmpty);
      final readsBefore = f.reads;

      f.adapters = [
        _wifi(_home, 'Home', addresses: ['192.168.50.21', '192.168.50.22']),
      ];
      await _eventually(() => f.reads > readsBefore + 3);
      await _quiet();

      expect(f.state.prompts, isEmpty);
      expect(f.state.pausedNetworks, [_homePrompt]);

      await f.restart();
      final again = await f.until((s) => s.prompts.isNotEmpty);

      expect(again.prompts, [_homePrompt]);
      expect(again.pausedNetworks, isEmpty);
    });

    test('askAgain on an untrusted network asks again, keeps it closed and '
        'keeps the saved decision', () async {
      final f = await _Fixture.create();
      await f.start();
      await f.until((s) => s.prompts.isNotEmpty);
      await f.node.decideNetwork(_home, NetworkDecision.untrusted);

      expect(f.state.prompts, isEmpty);
      expect(f.state.pausedNetworks, [_homePrompt]);

      f.node.askAgain(_home);
      final asked = await f.until((s) => s.prompts.isNotEmpty);

      expect(asked.prompts, [_homePrompt]);
      expect(asked.pausedNetworks, isEmpty);
      expect(asked.paused, isTrue);
      expect(await canBind(loopback, f.port), isTrue);

      await f.restart();
      final restarted = await f.until((s) => s.pausedNetworks.isNotEmpty);

      expect(restarted.pausedNetworks, [_homePrompt]);
      expect(restarted.prompts, isEmpty);
    });
  });

  group('trusting a network (RF-20, RF-10)', () {
    test('decideNetwork(trusted) activates the interface in the very next '
        'state, opens the listener and says hello within 1 s without waiting '
        'for the next read', () async {
      final f = await _Fixture.create();
      await f.start();
      await f.until((s) => s.prompts.isNotEmpty);
      final readsBefore = f.reads;
      final watch = Stopwatch()..start();

      await f.node.decideNetwork(_home, NetworkDecision.trusted);
      final state = f.state;
      await _eventually(() => f.ownHellos.isNotEmpty, limit: _helloLimit);
      watch.stop();

      expect(state.paused, isFalse);
      expect(state.prompts, isEmpty);
      expect(state.pausedNetworks, isEmpty);
      expect(state.decisionNotSaved, isFalse);
      expect(f.reads, readsBefore);
      expect(watch.elapsed, lessThan(_helloLimit));
      expect(await canBind(loopback, f.port), isFalse);
      final reply = await sendOrCut(
        f.port,
        registerRequest(callerInfoOf(caller)),
        serverFingerprint: f.state.fingerprint,
      );
      expect(reply!.status, 200);
    });

    test('the hello carries the device name cleaned and cut to 64 '
        'characters', () async {
      final f = await _Fixture.create();
      await f.start(deviceName: '${'x' * 40}\u202E${'y' * 40}');
      await f.until((s) => s.prompts.isNotEmpty);

      await f.node.decideNetwork(_home, NetworkDecision.trusted);
      await _eventually(() => f.ownHellos.isNotEmpty, limit: _helloLimit);

      final name = f.ownHellos.first.info.name;
      expect(name, '${'x' * 40}${'y' * 24}');
      expect(name!.runes, hasLength(64));
      expect(name, f.state.deviceName);
    });

    test('the decision is saved with the network name and a new start on the '
        'same folder applies it without asking', () async {
      final f = await _Fixture.create();
      await f.startTrusted();

      final saved = jsonDecode(await f.networksFile.readAsString()) as Map;
      final entry = (saved['networks'] as Map)[_home] as Map;
      expect(entry['decision'], 'trusted');
      expect(entry['name'], 'Home');

      final hellosBefore = f.ownHellos.length;
      await f.restart();
      final state = await f.until((s) => !s.paused);

      expect(state.prompts, isEmpty);
      expect(state.pausedNetworks, isEmpty);
      await _eventually(() => f.ownHellos.length > hellosBefore);
    });
  });

  group('untrusted network (RF-16, RF-17, RF-18)', () {
    test('with untrusted there is no TCP listener, the channel takes nothing '
        'and no hello goes out; trusting it later opens all three', () async {
      final f = await _Fixture.create();
      await f.start();
      await f.until((s) => s.prompts.isNotEmpty);
      final own = await _socketOn(_first);

      await f.node.decideNetwork(_home, NetworkDecision.untrusted);
      await f.inject(own, _foreignHello('B'));
      await _quiet();

      expect(f.state.paused, isTrue);
      expect(f.state.pausedNetworks, [_homePrompt]);
      expect(await canBind(loopback, f.port), isTrue);
      await expectLater(
        Socket.connect(loopback, f.port),
        throwsA(isA<SocketException>()),
      );
      expect(f.received, isEmpty);

      await f.node.decideNetwork(_home, NetworkDecision.trusted);
      await _eventually(() => f.ownHellos.isNotEmpty);
      await f.inject(own, _foreignHello('C'));
      await _eventually(() => f.receivedFingerprints.contains('C' * 64));

      expect(await canBind(loopback, f.port), isFalse);
      expect(f.receivedFingerprints, isNot(contains('B' * 64)));
    });

    test('with untrusted, rescan probes no address; once trusted, it '
        'does', () async {
      final f = await _Fixture.create();
      final probed = await ServerSocket.bind(otherLoopback, f.port);
      addTearDown(probed.close);
      var connections = 0;
      probed.listen((socket) {
        connections++;
        socket.destroy();
      });
      await f.start();
      await f.until((s) => s.prompts.isNotEmpty);
      await f.node.decideNetwork(_home, NetworkDecision.untrusted);

      await f.node.rescan().timeout(_waitLimit);
      await _quiet();

      expect(connections, 0);

      await f.node.decideNetwork(_home, NetworkDecision.trusted);
      unawaited(f.node.rescan());
      await _eventually(() => connections > 0);
    });
  });

  group('network changes (RF-21)', () {
    test('another networkId in the next NetworkChange applies its own '
        'decision in that same emission, within 5 s', () async {
      final f = await _Fixture.create();
      await f.startTrusted(pollInterval: _fastPoll);
      final seen = f.states.length;
      final watch = Stopwatch()..start();

      f.adapters = [_wifi(_cafe, 'Cafe')];
      await f.until((s) => s.prompts.contains(_cafePrompt));
      watch.stop();

      final first = f.states
          .skip(seen)
          .firstWhere((s) => s.prompts.contains(_cafePrompt));
      expect(first.prompts, [_cafePrompt]);
      expect(first.pausedNetworks, isEmpty);
      expect(first.paused, isTrue);
      expect(watch.elapsed, lessThan(_waitLimit));
      expect(await canBind(loopback, f.port), isTrue);

      final hellosBefore = f.ownHellos.length;
      f.adapters = [_wifi(_home, 'Home')];
      final back = await f.until((s) => !s.paused);

      expect(back.prompts, isEmpty);
      await _eventually(() => f.ownHellos.length > hellosBefore);
      expect(await canBind(loopback, f.port), isFalse);
    });

    test('same adapter and same IP on another trusted network: a hello goes '
        'out at once and the devices of that interface are dropped', () async {
      final f = await _Fixture.create();
      await f.startTrusted(pollInterval: _fastPoll);
      await f.node.decideNetwork(_cafe, NetworkDecision.trusted);
      final peer = await _Peer.join(f);
      await f.until((s) => s.devices.isNotEmpty);
      expect(
        f.state.devices.single.info.fingerprint,
        peer.identity.fingerprint,
      );
      await _quiet();
      final hellosBefore = f.ownHellos.length;
      final watch = Stopwatch()..start();

      f.adapters = [_wifi(_cafe, 'Cafe')];
      await f.until((s) => s.devices.isEmpty);
      await _eventually(() => f.ownHellos.length > hellosBefore);
      watch.stop();

      expect(watch.elapsed, lessThan(_waitLimit));
      expect(f.state.paused, isFalse);
      expect(f.state.prompts, isEmpty);
      expect(await canBind(loopback, f.port), isFalse);
    });

    test('control: the same network read again with another address does not '
        'drop the devices nor say hello again', () async {
      final f = await _Fixture.create();
      await f.startTrusted(pollInterval: _fastPoll);
      await _Peer.join(f);
      await f.until((s) => s.devices.isNotEmpty);
      await _quiet();
      final hellosBefore = f.ownHellos.length;
      final readsBefore = f.reads;

      f.adapters = [
        _wifi(_home, 'Home', addresses: ['192.168.50.21', '192.168.50.22']),
      ];
      await _eventually(() => f.reads > readsBefore + 3);
      await _quiet();

      expect(f.state.devices, hasLength(1));
      expect(f.ownHellos, hasLength(hellosBefore));
    });
  });

  group('resume after suspend (RF-22)', () {
    test('a clock jump of more than three intervals between two reads marks '
        'resumed and a hello goes out at once', () async {
      final f = await _Fixture.create();
      await f.startTrusted(pollInterval: _fastPoll);
      await _quiet();
      final hellosBefore = f.ownHellos.length;
      final readsBefore = f.reads;

      await _quiet();

      expect(f.reads, greaterThan(readsBefore + 2));
      expect(f.ownHellos, hasLength(hellosBefore));

      final watch = Stopwatch()..start();
      f.clock = f.clock.add(_fastPoll * 3 + const Duration(seconds: 1));
      await _eventually(
        () => f.ownHellos.length > hellosBefore,
        limit: _helloLimit,
      );
      watch.stop();

      expect(watch.elapsed, lessThan(_helloLimit));
      expect(f.state.paused, isFalse);
    });
  });

  group('a decision that cannot be saved (RF-14)', () {
    test('with networks.json locked, decideNetwork applies the decision in '
        'memory and sets decisionNotSaved; the next saved decision clears '
        'it', () async {
      final f = await _Fixture.create();
      await f.start();
      await f.until((s) => s.prompts.isNotEmpty);
      await f.dataDir.create(recursive: true);
      final (line, release) = await _child(_lockScript, [f.networksFile.path]);
      expect(line, 'locked');

      await f.node.decideNetwork(_home, NetworkDecision.trusted);

      expect(f.state.decisionNotSaved, isTrue);
      expect(f.state.paused, isFalse);
      expect(f.state.prompts, isEmpty);
      await _eventually(() => f.ownHellos.isNotEmpty);

      await release();
      await f.node.decideNetwork(_home, NetworkDecision.trusted);

      expect(f.state.decisionNotSaved, isFalse);
      expect(f.state.paused, isFalse);
      final saved = jsonDecode(await f.networksFile.readAsString()) as Map;
      expect(((saved['networks'] as Map)[_home] as Map)['decision'], 'trusted');
    }, timeout: _childTimeout);
  });

  group('port in use (RF-38)', () {
    test(
      'a TCP port held by another process: portInUse is the port, no socket '
      'of the node stays open, retry while held changes nothing, and once '
      'freed retry clears it and the same subscription hears the hello',
      () async {
        final (line, release) = await _child(_holdTcpScript);
        final f = await _Fixture.create(port: int.parse(line));
        await f.start();
        await f.until((s) => s.prompts.isNotEmpty);

        await f.node.decideNetwork(_home, NetworkDecision.trusted);

        expect(f.state.portInUse, f.port);
        await _eventually(() async => !await _ownSocketOn('UDP', f.port));
        expect(await _ownSocketOn('TCP', f.port), isFalse);

        await f.node.retry();
        await _quiet();

        expect(f.state.portInUse, f.port);
        await _eventually(() async => !await _ownSocketOn('UDP', f.port));
        expect(await _ownSocketOn('TCP', f.port), isFalse);
        expect(f.ownHellos, isEmpty);

        await release();
        await f.node.retry();

        expect(f.state.portInUse, isNull);
        await _eventually(() => f.ownHellos.isNotEmpty);
        expect(await _ownSocketOn('TCP', f.port), isTrue);
        expect(await _ownSocketOn('UDP', f.port), isTrue);
      },
      timeout: _childTimeout,
      testOn: 'windows',
    );

    test(
      'a UDP port held by another process: portInUse from the start, a '
      'trusted network opens nothing, retry while held keeps it, and once '
      'freed retry clears it and the same subscription hears the hello',
      () async {
        final (line, release) = await _child(_holdUdpScript);
        final f = await _Fixture.create(port: int.parse(line));
        await f.start();

        expect(f.state.portInUse, f.port);

        await f.until((s) => s.prompts.isNotEmpty);
        await f.node.decideNetwork(_home, NetworkDecision.trusted);
        await _quiet();

        expect(f.state.portInUse, f.port);
        expect(await _ownSocketOn('TCP', f.port), isFalse);
        expect(await _ownSocketOn('UDP', f.port), isFalse);
        expect(await canBind(loopback, f.port), isTrue);

        await f.node.retry();

        expect(f.state.portInUse, f.port);
        expect(await _ownSocketOn('TCP', f.port), isFalse);
        expect(f.ownHellos, isEmpty);

        await release();
        await f.node.retry();

        expect(f.state.portInUse, isNull);
        await _eventually(() => f.ownHellos.isNotEmpty);
        expect(await _ownSocketOn('TCP', f.port), isTrue);
        expect(await _ownSocketOn('UDP', f.port), isTrue);
      },
      timeout: _childTimeout,
      testOn: 'windows',
    );
  });

  group('two devices on the same trusted network (RF-45)', () {
    test('a second device sharing the channel shows up in state.devices '
        'within 5 s, and the node shows up in its list', () async {
      final f = await _Fixture.create();
      await f.startTrusted();
      final watch = Stopwatch()..start();

      final peer = await _Peer.join(f);
      final state = await f.until((s) => s.devices.isNotEmpty);
      await _eventually(
        () => peer.discovery.current.any(
          (d) => d.info.fingerprint == f.state.fingerprint,
        ),
      );
      watch.stop();

      expect(watch.elapsed, lessThan(_waitLimit));
      final device = state.devices.single;
      expect(device.info.fingerprint, peer.identity.fingerprint);
      expect(device.info.name, 'Peer PC');
      expect(device.paired, isFalse);
      expect(state.displayNames, {peer.identity.fingerprint: 'Peer PC'});
      final seen = peer.discovery.current.single;
      expect(seen.info.name, 'Test PC');
      expect(seen.info.port, f.port);
    });
  });

  group('rescan suggestion (RF-55)', () {
    test('with an active interface and an empty list for 15 s the suggestion '
        'appears, and a device arriving takes it away', () async {
      final f = await _Fixture.create();
      await f.startTrusted();

      f.clock = f.clock.add(const Duration(seconds: 14));
      await Future<void>.delayed(_suggestTick);

      expect(f.state.suggestRescan, isFalse);

      f.clock = f.clock.add(const Duration(seconds: 1));
      await f.until((s) => s.suggestRescan);

      await _Peer.join(f);
      final state = await f.until((s) => s.devices.isNotEmpty);

      expect(state.suggestRescan, isFalse);
    });

    test('paused for 20 s and then trusted, the suggestion waits 15 s from '
        'the moment the interface became active', () async {
      final f = await _Fixture.create();
      await f.start();
      await f.until((s) => s.prompts.isNotEmpty);

      f.clock = f.clock.add(const Duration(seconds: 20));
      await Future<void>.delayed(_suggestTick);

      expect(f.state.suggestRescan, isFalse);

      await f.node.decideNetwork(_home, NetworkDecision.trusted);

      expect(f.state.suggestRescan, isFalse);

      f.clock = f.clock.add(const Duration(seconds: 14));
      await Future<void>.delayed(_suggestTick);

      expect(f.state.suggestRescan, isFalse);

      f.clock = f.clock.add(const Duration(seconds: 1));
      await f.until((s) => s.suggestRescan);
    });
  });

  group('only interfaces with a listener are announced (v2.8 point 15)', () {
    test('an interface where the server cannot open is neither joined nor '
        'announced, and it is once the server opens it', () async {
      final f = await _Fixture.create();
      final squatter = await ServerSocket.bind(otherLoopback, f.port);
      var squatterOpen = true;
      addTearDown(() async {
        if (squatterOpen) await squatter.close();
      });
      final own = await _socketOn(_first);
      final other = await _socketOn(otherLoopback);

      await f.startTrusted(
        pollInterval: _fastPoll,
        activeOf: _onLoopback(const [('127.0.0.1', 32), ('127.0.0.2', 32)]),
      );
      await _quiet();
      await f.inject(other, _foreignHello('B'));
      await f.inject(own, _foreignHello('C'));
      await _eventually(() => f.receivedFingerprints.contains('C' * 64));
      await _quiet();

      expect(f.ownHellos, hasLength(1));
      expect(f.receivedFingerprints, isNot(contains('B' * 64)));
      expect(f.logs, contains('interface bind failed: SocketException'));

      await squatter.close();
      squatterOpen = false;
      f.adapters = [
        _wifi(_home, 'Home', addresses: ['192.168.50.21', '192.168.50.22']),
      ];
      await _eventually(() => f.ownHellos.length == 2);
      await f.inject(other, _foreignHello('D'));
      await _eventually(() => f.receivedFingerprints.contains('D' * 64));

      final (_, from, via) = f.received.firstWhere(
        (r) => r.$1.info.fingerprint == 'D' * 64,
      );
      expect(from, otherLoopback);
      expect(via.id, '$_wifiId#127.0.0.2');
      expect(await canBind(otherLoopback, f.port), isFalse);
    });
  });

  group('coming back to a device that still lists the node (RF-45, v2.11 '
      'point 1)', () {
    test('untrusted and trusted again: the node drops the peer and gets it '
        'back within 5 s although the peer only announces every 10 s, '
        'because the peer answers the known hello at once', () async {
      final f = await _Fixture.create();
      await f.startTrusted();
      final peer = await _Peer.join(
        f,
        announceInterval: Limits.announceInterval,
      );
      await f.until((s) => s.devices.isNotEmpty);
      await _eventually(
        () => peer.discovery.current.any(
          (d) => d.info.fingerprint == f.state.fingerprint,
        ),
      );

      await f.node.decideNetwork(_home, NetworkDecision.untrusted);

      expect(f.state.devices, isEmpty);
      expect(f.state.paused, isTrue);
      expect(
        peer.discovery.current.map((d) => d.info.fingerprint),
        contains(f.state.fingerprint),
      );

      f.clock = f.clock.add(_awayForAWhile);
      final watch = Stopwatch()..start();
      await f.node.decideNetwork(_home, NetworkDecision.trusted);
      final back = await f.until((s) => s.devices.isNotEmpty);
      watch.stop();

      expect(watch.elapsed, lessThan(_waitLimit));
      expect(back.paused, isFalse);
      expect(back.devices.single.info.fingerprint, peer.identity.fingerprint);
    });

    test('the adapter disappears and comes back: the node drops the peer and '
        'gets it back within 5 s although the peer only announces every '
        '10 s', () async {
      final f = await _Fixture.create();
      await f.startTrusted(pollInterval: _fastPoll);
      final peer = await _Peer.join(
        f,
        announceInterval: Limits.announceInterval,
      );
      await f.until((s) => s.devices.isNotEmpty);
      await _eventually(
        () => peer.discovery.current.any(
          (d) => d.info.fingerprint == f.state.fingerprint,
        ),
      );

      f.adapters = [];
      final gone = await f.until((s) => s.devices.isEmpty && s.paused);

      expect(gone.prompts, isEmpty);
      expect(
        peer.discovery.current.map((d) => d.info.fingerprint),
        contains(f.state.fingerprint),
      );

      f.clock = f.clock.add(_awayForAWhile);
      final readsAfterJump = f.reads;
      await _eventually(() => f.reads > readsAfterJump + 2);
      final watch = Stopwatch()..start();
      f.adapters = [_wifi(_home, 'Home')];
      final back = await f.until((s) => s.devices.isNotEmpty);
      watch.stop();

      expect(watch.elapsed, lessThan(_waitLimit));
      expect(back.paused, isFalse);
      expect(back.devices.single.info.fingerprint, peer.identity.fingerprint);
    });
  });

  group('the node only emits when its state changes (v2.11 point 8)', () {
    test('dismissPrompt of a network that is not asked about emits nothing '
        'and keeps the state; a real dismiss emits exactly once', () async {
      final f = await _Fixture.create();
      await f.start();
      await f.until((s) => s.prompts.isNotEmpty);
      await _quiet();
      final emitted = f.states.length;
      final last = f.states.last;
      final plansBefore = f.plans;

      f.node.dismissPrompt(_cafe);
      await _eventually(() => f.plans > plansBefore);
      await Future<void>.delayed(_noEmission);

      expect(f.states, hasLength(emitted));
      expect(_shape(f.state), _shape(last));
      expect(f.state.prompts, [_homePrompt]);

      f.node.dismissPrompt(_home);
      await f.until((s) => s.prompts.isEmpty);
      await Future<void>.delayed(_noEmission);

      expect(f.states, hasLength(emitted + 1));
      expect(f.states.last.pausedNetworks, [_homePrompt]);
      expect(f.states.last.paused, isTrue);
      expect(_shape(f.state), _shape(f.states.last));
    });

    test('network reads that change nothing for the node (a resume with the '
        'same adapters, another address on the same network) emit nothing; '
        'a real change emits exactly once', () async {
      final f = await _Fixture.create();
      await f.startTrusted(pollInterval: _fastPoll);
      await _quiet();
      final emitted = f.states.length;
      final last = f.states.last;
      final hellosBefore = f.ownHellos.length;
      final plansBefore = f.plans;

      f.clock = f.clock.add(_fastPoll * 3 + const Duration(seconds: 1));
      await _eventually(() => f.ownHellos.length > hellosBefore);
      await _eventually(() => f.plans > plansBefore);
      await Future<void>.delayed(_noEmission);

      expect(f.states, hasLength(emitted));
      expect(_shape(f.state), _shape(last));

      final plansAfterResume = f.plans;
      f.adapters = [
        _wifi(_home, 'Home', addresses: ['192.168.50.21', '192.168.50.22']),
      ];
      await _eventually(() => f.plans > plansAfterResume);
      await Future<void>.delayed(_noEmission);

      expect(f.states, hasLength(emitted));
      expect(_shape(f.state), _shape(last));
      expect(f.state.paused, isFalse);

      f.adapters = [_wifi(_cafe, 'Cafe')];
      await f.until((s) => s.prompts.isNotEmpty);
      await Future<void>.delayed(_noEmission);

      expect(f.states, hasLength(emitted + 1));
      expect(f.states.last.prompts, [_cafePrompt]);
      expect(f.states.last.paused, isTrue);
      expect(_shape(f.state), _shape(f.states.last));
    });
  });

  group('crossed calls (T8, v2.11 point 9)', () {
    test('dismissPrompt, askAgain, a network change and decideNetwork(trusted) '
        'launched together all finish, raise nothing and leave the network '
        'trusted and active', () async {
      final f = await _Fixture.create();
      await f.start(pollInterval: _fastPoll);
      await f.until((s) => s.prompts.isNotEmpty);
      final gate = f.gate = Completer<void>();
      final readsBefore = f.reads;
      await _eventually(() => f.reads > readsBefore);
      f.adapters = [
        _wifi(_home, 'Home', addresses: ['192.168.50.21', '192.168.50.22']),
      ];
      final plansBefore = f.plans;
      final uncaught = <Object>[];

      await _crossed(() async {
        f.node.dismissPrompt(_home);
        f.node.askAgain(_home);
        gate.complete();
        await Future<void>.delayed(Duration.zero);
        await f.node.decideNetwork(_home, NetworkDecision.trusted);
      }, uncaught);
      await f.node.retry().timeout(_waitLimit);
      await _quiet();

      expect(uncaught, isEmpty);
      expect(_failuresIn(f.logs), isEmpty);
      expect(f.plans, plansBefore + 4);
      expect(f.state.paused, isFalse);
      expect(f.state.prompts, isEmpty);
      expect(f.state.pausedNetworks, isEmpty);
      expect(f.state.decisionNotSaved, isFalse);
      await _eventually(() => f.ownHellos.isNotEmpty);
      expect(await canBind(loopback, f.port), isFalse);
      final saved = jsonDecode(await f.networksFile.readAsString()) as Map;
      expect(((saved['networks'] as Map)[_home] as Map)['decision'], 'trusted');
    });

    test('decideNetwork(untrusted), a network change, dismissPrompt and '
        'askAgain launched together all finish, raise nothing and leave the '
        'network asked about and closed', () async {
      final f = await _Fixture.create();
      await f.start(pollInterval: _fastPoll);
      await f.until((s) => s.prompts.isNotEmpty);
      final gate = f.gate = Completer<void>();
      final readsBefore = f.reads;
      await _eventually(() => f.reads > readsBefore);
      f.adapters = [
        _wifi(_home, 'Home', addresses: ['192.168.50.21', '192.168.50.22']),
      ];
      final plansBefore = f.plans;
      final uncaught = <Object>[];

      await _crossed(() async {
        final decided = f.node.decideNetwork(_home, NetworkDecision.untrusted);
        gate.complete();
        await Future<void>.delayed(Duration.zero);
        f.node.dismissPrompt(_home);
        f.node.askAgain(_home);
        await decided;
      }, uncaught);
      await f.node.retry().timeout(_waitLimit);
      await _quiet();

      expect(uncaught, isEmpty);
      expect(_failuresIn(f.logs), isEmpty);
      expect(f.plans, plansBefore + 4);
      expect(f.state.prompts, [_homePrompt]);
      expect(f.state.pausedNetworks, isEmpty);
      expect(f.state.paused, isTrue);
      expect(f.ownHellos, isEmpty);
      expect(await canBind(loopback, f.port), isTrue);
      final saved = jsonDecode(await f.networksFile.readAsString()) as Map;
      expect(
        ((saved['networks'] as Map)[_home] as Map)['decision'],
        'untrusted',
      );
    });
  });
}
