import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:nexus_bridges_core/src/discovery/discovery.dart';
import 'package:nexus_bridges_core/src/identity/identity.dart';
import 'package:nexus_bridges_core/src/network/network.dart';
import 'package:nexus_bridges_core/src/pairing/pairing.dart';
import 'package:nexus_bridges_core/src/protocol/protocol.dart';
import 'package:nexus_bridges_core/src/server/server.dart';
import 'package:nexus_bridges_core/src/storage/storage.dart';
import 'package:test/test.dart';

import '../support/infra.dart';
import '../server/api_server_harness.dart'
    show jsonContentType, pairedDeviceOf, presenting;

const Duration _limit = Duration(seconds: 5);
const Duration _never = Duration(hours: 1);
const Duration _fast = Duration(milliseconds: 50);
const Duration _justUnder = Duration(milliseconds: 1);

late String _loopbackName;

InternetAddress _host(int last) => InternetAddress('127.0.0.$last');

ActiveInterface _iface(String address) => ActiveInterface(
  id: 'loopback#$address/8',
  adapterId: 'loopback',
  friendlyName: _loopbackName,
  subnet: Ipv4Subnet(InternetAddress(address), 8),
);

Announcement _hello(DeviceInfo info) =>
    Announcement(AnnouncementKind.hello, info);

Future<void> _until(
  bool Function() condition, {
  Duration? limit,
  String reason = 'condition',
}) async {
  final span = limit ?? scaled(_limit);
  final watch = Stopwatch()..start();
  while (!condition()) {
    if (watch.elapsed > span) fail('$reason not met within $span');
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}

Future<void> _settle(
  int Function() value, {
  Duration quiet = const Duration(milliseconds: 300),
}) async {
  final watch = Stopwatch()..start();
  var last = value();
  var since = Stopwatch()..start();
  while (since.elapsed < quiet) {
    if (watch.elapsed > scaled(_limit)) fail('value did not settle');
    await Future<void>.delayed(const Duration(milliseconds: 10));
    final current = value();
    if (current != last) {
      last = current;
      since = Stopwatch()..start();
    }
  }
}

Future<void> _pause([Duration span = const Duration(milliseconds: 300)]) =>
    Future<void>.delayed(span);

Future<int> _freeUdpPort() =>
    pickPort(tcp: [InternetAddress.anyIPv4], udp: [InternetAddress.anyIPv4]);

Future<PairedDevicesStore> _pairedStore(String owner) async {
  final dir = await Directory.systemTemp.createTemp('nexus_rescan_presence_');
  addTearDown(() => dir.delete(recursive: true));
  final store = PairedDevicesStore(
    JsonFileStore(File('${dir.path}${Platform.pathSeparator}paired.json')),
    ownerFingerprint: owner,
  );
  await store.load();
  return store;
}

final RegExp _contentLength = RegExp(
  r'content-length:\s*(\d+)',
  caseSensitive: false,
);

int _requestEnd(List<int> bytes) {
  final text = latin1.decode(bytes);
  final end = text.indexOf('\r\n\r\n');
  if (end < 0) return -1;
  final match = _contentLength.firstMatch(text.substring(0, end));
  final length = match == null ? 0 : int.parse(match.group(1)!);
  return bytes.length >= end + 4 + length ? end + 4 : -1;
}

final class _Clocks {
  DateTime wall = DateTime.utc(2026, 10, 24, 12);
  Duration elapsed = Duration.zero;

  DateTime now() => wall;

  Duration monotonic() => elapsed;
}

final class _Channel {
  _Channel._(this.channel, this.port);

  final MulticastChannel channel;
  final int port;
  final List<(Announcement, InternetAddress, ActiveInterface)> received = [];
  final Map<String, RawDatagramSocket> _senders = {};

  static Future<_Channel> open(List<ActiveInterface> active) async {
    final port = await _freeUdpPort();
    final channel = MulticastChannel(port: port);
    addTearDown(channel.close);
    final fixture = _Channel._(channel, port);
    final subscription = channel.incoming.listen(fixture.received.add);
    addTearDown(subscription.cancel);
    await channel.open();
    await channel.syncInterfaces(active);
    return fixture;
  }

  int countFrom(Set<String> sources) =>
      received.where((e) => sources.contains(e.$2.address)).length;

  Future<void> inject(InternetAddress source, Announcement announcement) async {
    var socket = _senders[source.address];
    if (socket == null) {
      socket = await RawDatagramSocket.bind(source, 0, reuseAddress: false);
      addTearDown(socket.close);
      _senders[source.address] = socket;
    }
    final bytes = announcement.encode();
    final watch = Stopwatch()..start();
    while (socket.send(bytes, InternetAddress.loopbackIPv4, port) !=
        bytes.length) {
      if (watch.elapsed > scaled(_limit)) fail('datagram not sent');
      await Future<void>.delayed(const Duration(milliseconds: 1));
    }
  }

  Future<void> deliver(
    InternetAddress source,
    Announcement announcement,
  ) async {
    final before = received.length;
    await inject(source, announcement);
    await _until(
      () => received
          .skip(before)
          .any(
            (e) =>
                e.$2.address == source.address &&
                e.$1.info.fingerprint == announcement.info.fingerprint,
          ),
      reason: 'announcement delivered',
    );
  }
}

enum _Mode { honest, held, refuse }

final class _Link {
  _Link(this.raw);

  final Socket raw;
  SecureSocket? secure;
  bool requested = false;
  final Completer<void> closed = Completer();

  bool get isClosed => closed.isCompleted;

  void finish() {
    if (!closed.isCompleted) closed.complete();
  }
}

final class _Responder {
  _Responder._(this._server, this.address, this.identity);

  final ServerSocket _server;
  final InternetAddress address;
  DeviceIdentity identity;
  _Mode mode = _Mode.honest;
  Completer<void> _released = Completer();
  final List<_Link> links = [];
  final List<(String, Map<String, Object?>)> requests = [];
  int connections = 0;
  int maxOpen = 0;

  int get port => _server.port;

  int get open => links.where((l) => !l.isClosed).length;

  int get heldWithRequest =>
      links.where((l) => !l.isClosed && l.requested).length;

  int requestsTo(DeviceIdentity target) =>
      requests.where((r) => r.$1 == target.fingerprint).length;

  DeviceInfo infoOf(DeviceIdentity presented) => DeviceInfo(
    name: 'Responder',
    fingerprint: presented.fingerprint,
    port: port,
    protocol: protocolVersion,
    deviceType: DeviceType.desktop,
  );

  static Future<_Responder> start(
    DeviceIdentity identity,
    InternetAddress address,
  ) async {
    final server = await ServerSocket.bind(address, 0);
    final responder = _Responder._(server, address, identity);
    addTearDown(responder.close);
    server.listen(responder._accept, onError: (Object _) {});
    return responder;
  }

  void hold() {
    mode = _Mode.held;
    _released = Completer();
  }

  void release() {
    mode = _Mode.honest;
    if (!_released.isCompleted) _released.complete();
  }

  void resetMax() => maxOpen = open;

  void _accept(Socket raw) {
    connections++;
    raw.done.ignore();
    if (mode == _Mode.refuse) {
      raw.destroy();
      return;
    }
    final link = _Link(raw);
    links.add(link);
    maxOpen = max(maxOpen, open);
    final presented = identity;
    final held = mode == _Mode.held;
    final released = _released.future;
    SecureSocket.secureServer(raw, presenting(presented)).then(
      (secure) {
        link.secure = secure;
        secure.done.ignore();
        final received = <int>[];
        secure.listen(
          (chunk) {
            received.addAll(chunk);
            if (link.requested) return;
            final end = _requestEnd(received);
            if (end < 0) return;
            link.requested = true;
            final body = jsonDecode(utf8.decode(received.sublist(end)));
            requests.add((
              presented.fingerprint,
              (body as Map).cast<String, Object?>(),
            ));
            final reply = _replyOf(infoOf(presented));
            if (held) {
              released.then((_) => _write(link, reply));
            } else {
              _write(link, reply);
            }
          },
          onError: (Object _) => link.finish(),
          onDone: link.finish,
          cancelOnError: true,
        );
      },
      onError: (Object _) {
        raw.destroy();
        link.finish();
      },
    );
  }

  static List<int> _replyOf(DeviceInfo info) {
    final body = utf8.encode(jsonEncode(info.toJson()));
    return [
      ...utf8.encode(
        'HTTP/1.1 200 OK\r\n'
        'content-type: $jsonContentType\r\n'
        'content-length: ${body.length}\r\n'
        'connection: close\r\n\r\n',
      ),
      ...body,
    ];
  }

  static void _write(_Link link, List<int> reply) {
    final secure = link.secure;
    if (link.isClosed || secure == null) return;
    try {
      secure.add(reply);
    } on Object {
      return;
    }
  }

  Future<void> close() async {
    release();
    for (final link in links) {
      link.secure?.destroy();
      link.raw.destroy();
      link.finish();
    }
    await _server.close();
  }
}

final class _Subject {
  _Subject._(this.identity, this.paired, this.clocks);

  final DeviceIdentity identity;
  final PairedDevicesStore paired;
  final _Clocks clocks;
  final List<String> logs = [];
  final List<List<DiscoveredDevice>> emitted = [];
  late final DiscoveryService service;

  static Future<_Subject> create(
    _Channel channel, {
    required DeviceIdentity identity,
    required int port,
    required List<InternetAddress> Function(ActiveInterface iface) hostsOf,
    _Clocks? clocks,
    Duration presentInterval = _fast,
    Duration announceInterval = _never,
    List<DeviceIdentity> pairedWith = const [],
  }) async {
    final subject = _Subject._(
      identity,
      await _pairedStore(identity.fingerprint),
      clocks ?? _Clocks(),
    );
    if (pairedWith.isNotEmpty) {
      await subject.paired.replaceAll([
        for (final peer in pairedWith) pairedDeviceOf(peer),
      ]);
    }
    final verifier = DeviceVerifier(identity: identity);
    subject.service = DiscoveryService(
      identity: identity,
      selfInfo: subject.selfInfo,
      paired: subject.paired,
      channel: channel.channel,
      verifier: verifier,
      scanner: SubnetScanner(verifier: verifier, port: port, hostsOf: hostsOf),
      now: subject.clocks.now,
      monotonic: subject.clocks.monotonic,
      announceInterval: announceInterval,
      presentInterval: presentInterval,
      expireInterval: _fast,
      log: subject.logs.add,
    );
    addTearDown(() => subject.service.stop(sayGoodbye: false));
    final subscription = subject.service.devices.listen(subject.emitted.add);
    addTearDown(subscription.cancel);
    await subject.service.start();
    return subject;
  }

  DeviceInfo selfInfo() => DeviceInfo(
    name: 'Subject',
    fingerprint: identity.fingerprint,
    port: 40000,
    protocol: protocolVersion,
    deviceType: DeviceType.desktop,
  );

  DiscoveredDevice? find(String fingerprint) {
    for (final device in service.current) {
      if (device.info.fingerprint == fingerprint) return device;
    }
    return null;
  }

  bool lists(String fingerprint) => find(fingerprint) != null;

  void tick(Duration span) => clocks.elapsed += span;
}

final class _Peer {
  _Peer._(this.identity);

  final DeviceIdentity identity;
  late final ApiServer server;
  final List<(DeviceInfo, InternetAddress)> registrations = [];

  int get port => server.boundPort!;

  DeviceInfo get info => DeviceInfo(
    name: 'Peer',
    fingerprint: identity.fingerprint,
    port: port,
    protocol: protocolVersion,
    deviceType: DeviceType.desktop,
  );

  static Future<_Peer> start(DeviceIdentity identity, String address) async {
    final paired = await _pairedStore(identity.fingerprint);
    final peer = _Peer._(identity);
    peer.server = ApiServer(
      identity: identity,
      paired: paired,
      selfInfo: () => peer.info,
      onRegistered: (caller, from, _) => peer.registrations.add((caller, from)),
      port: 0,
    );
    addTearDown(peer.server.close);
    await peer.server.syncInterfaces([_iface(address)]);
    expect(peer.server.boundPort, isNotNull);
    return peer;
  }
}

void main() {
  late DeviceIdentity self;
  late DeviceIdentity bob;
  late DeviceIdentity carol;
  late ActiveInterface first;
  late ActiveInterface second;

  setUpAll(() async {
    final all = await NetworkInterface.list(includeLoopback: true);
    _loopbackName = all
        .firstWhere((i) => i.addresses.any((a) => a.address == '127.0.0.1'))
        .name;
    self = DeviceIdentity.generate();
    bob = DeviceIdentity.generate();
    carol = DeviceIdentity.generate();
    first = _iface('127.0.0.1');
    second = _iface('127.0.0.2');
  });

  Future<(_Subject, _Responder)> foundByScan({
    _Clocks? clocks,
    Duration announceInterval = _never,
    List<DeviceIdentity> pairedWith = const [],
    ActiveInterface? through,
    List<ActiveInterface>? active,
  }) async {
    final responder = await _Responder.start(bob, _host(3));
    final interfaces = active ?? [first];
    final via = through ?? first;
    final channel = await _Channel.open(interfaces);
    final s = await _Subject.create(
      channel,
      identity: self,
      port: responder.port,
      hostsOf: (iface) => iface.id == via.id ? [_host(3)] : const [],
      clocks: clocks,
      announceInterval: announceInterval,
      pairedWith: pairedWith,
    );
    await s.service.syncInterfaces(interfaces);
    await s.service.rescan().timeout(scaled(_limit));
    expect(s.lists(bob.fingerprint), isTrue);
    expect(s.find(bob.fingerprint)!.interfaceId, via.id);
    return (s, responder);
  }

  group('presenting again to a device found by a search (E132, RF-192)', () {
    test('a device found only by a search, on another multicast port, stays '
        'listed past 35 s while it answers, and its register counter rises '
        'at every interval', () async {
      final peer = await _Peer.start(bob, '127.0.0.4');
      final channel = await _Channel.open([first]);
      final s = await _Subject.create(
        channel,
        identity: self,
        port: peer.port,
        hostsOf: (_) => [_host(4)],
        presentInterval: const Duration(milliseconds: 250),
      );
      await s.service.syncInterfaces([first]);

      await s.service.rescan().timeout(scaled(_limit));
      expect(s.lists(bob.fingerprint), isTrue);
      expect(peer.registrations, hasLength(1));

      for (var step = 0; step < 7; step++) {
        final before = peer.registrations.length;
        s.tick(const Duration(seconds: 5));
        await _until(
          () => peer.registrations.length > before,
          reason: 'presentation at step $step',
        );
      }
      expect(s.clocks.elapsed, const Duration(seconds: 35));
      await _pause();

      expect(s.lists(bob.fingerprint), isTrue);
      expect(s.find(bob.fingerprint)!.address, _host(4));
      expect(peer.registrations.length, greaterThanOrEqualTo(8));
      for (final (caller, _) in peer.registrations) {
        expect(caller.toJson(), s.selfInfo().toJson());
      }
      expect(s.logs.join('\n'), isNot(contains('PRIVATE KEY')));
    });

    test('each presentation goes to the address and port of the device and '
        'carries the own DeviceInfo', () async {
      final (s, responder) = await foundByScan();

      await _until(() => responder.requestsTo(bob) >= 3);

      for (final (fingerprint, body) in responder.requests) {
        expect(fingerprint, bob.fingerprint);
        expect(body, s.selfInfo().toJson());
      }
      expect(s.find(bob.fingerprint)!.address, _host(3));
      expect(s.find(bob.fingerprint)!.info.port, responder.port);
    });

    test('a device that starts being heard through announcements stops '
        'getting presentations, and gets them again 10 s after its last '
        'hello', () async {
      final clocks = _Clocks();
      final responder = await _Responder.start(bob, _host(3));
      final channel = await _Channel.open([first]);
      final s = await _Subject.create(
        channel,
        identity: self,
        port: responder.port,
        hostsOf: (_) => [_host(3)],
        clocks: clocks,
        announceInterval: Limits.announceInterval,
      );
      await s.service.syncInterfaces([first]);
      await s.service.rescan().timeout(scaled(_limit));
      await _until(() => responder.connections >= 3);

      await channel.deliver(_host(3), _hello(responder.infoOf(bob)));
      await _settle(() => responder.connections);
      final quiet = responder.connections;

      await _pause(const Duration(milliseconds: 500));
      expect(responder.connections, quiet);

      s.tick(Limits.announceInterval - _justUnder);
      await _pause();
      expect(responder.connections, quiet);
      expect(s.lists(bob.fingerprint), isTrue);

      s.tick(_justUnder);
      await _until(
        () => responder.connections > quiet,
        reason: 'presentations again',
      );
    });

    test('only one presentation at a time per device: while one waits for '
        'its answer, the intervals that pass start no other', () async {
      final (s, responder) = await foundByScan();
      responder.hold();
      await _until(() => responder.heldWithRequest == 1);
      await _pause(const Duration(milliseconds: 100));
      responder.resetMax();
      final opened = responder.connections;
      final requested = responder.requestsTo(bob);

      await _pause(const Duration(milliseconds: 600));

      expect(responder.connections, opened);
      expect(responder.open, 1);
      expect(responder.maxOpen, 1);

      responder.release();
      await _until(() => responder.requestsTo(bob) >= requested + 2);
      expect(responder.maxOpen, 1);
      expect(s.lists(bob.fingerprint), isTrue);
    });

    test('after stop no presentation goes out', () async {
      final (s, responder) = await foundByScan();
      await _until(() => responder.connections >= 3);

      await s.service.stop(sayGoodbye: false);
      await _settle(() => responder.connections);
      final tried = responder.connections;
      await _pause(const Duration(milliseconds: 500));

      expect(responder.connections, tried);
    });
  });

  group('pinned fingerprint when presenting again (E133, SEC-05)', () {
    test('when another identity answers at the address of the device, the '
        'greeting is aborted before sending the DeviceInfo, and the device '
        'leaves at 30 s and gets no more presentations', () async {
      final (s, responder) = await foundByScan();
      await _until(() => responder.requestsTo(bob) >= 2);

      responder.identity = carol;
      final switched = responder.connections;
      await _until(
        () => responder.connections >= switched + 3,
        reason: 'attempts against the other identity',
      );
      expect(responder.requestsTo(carol), 0);
      expect(s.find(bob.fingerprint)!.address, _host(3));
      expect(s.lists(carol.fingerprint), isFalse);

      s.tick(Limits.expireAfter);
      await _until(() => !s.lists(bob.fingerprint), reason: 'expired');
      await _settle(() => responder.connections);
      final tried = responder.connections;
      await _pause(const Duration(milliseconds: 500));

      expect(responder.connections, tried);
      expect(responder.requestsTo(carol), 0);
      expect(s.emitted.last, isEmpty);
    });
  });

  group('hellos that must not stop the presentation (RF-192, SEC-05)', () {
    Future<(_Subject, _Responder, _Channel)> heardRig() async {
      final responder = await _Responder.start(bob, _host(3));
      final channel = await _Channel.open([first]);
      final s = await _Subject.create(
        channel,
        identity: self,
        port: responder.port,
        hostsOf: (_) => [_host(3)],
        announceInterval: Limits.announceInterval,
      );
      await s.service.syncInterfaces([first]);
      await s.service.rescan().timeout(scaled(_limit));
      expect(s.lists(bob.fingerprint), isTrue);
      return (s, responder, channel);
    }

    Future<void> stillPresentedPast30s(
      _Subject s,
      _Responder responder, {
      Future<void> Function()? before,
    }) async {
      for (var step = 0; step < 7; step++) {
        await before?.call();
        final requested = responder.requestsTo(bob);
        await _until(
          () => responder.requestsTo(bob) > requested + 1,
          reason: 'presentation at step $step',
        );
        s.tick(const Duration(seconds: 5));
      }
      expect(s.clocks.elapsed, const Duration(seconds: 35));
      await _pause();
      expect(s.lists(bob.fingerprint), isTrue);
      expect(s.find(bob.fingerprint)!.address, _host(3));
    }

    test('a hello with the fingerprint of B from another IP does not stop '
        'the presentation, and B stays listed past 30 s at its own '
        'address', () async {
      final (s, responder, channel) = await heardRig();
      final forged = DeviceInfo(
        name: 'Forged',
        fingerprint: bob.fingerprint,
        port: responder.port,
        protocol: protocolVersion,
        deviceType: DeviceType.desktop,
      );

      await stillPresentedPast30s(
        s,
        responder,
        before: () => channel.deliver(_host(5), _hello(forged)),
      );
      expect(s.service.current, hasLength(1));
    });

    test('1000 hellos with invented fingerprints leave no trace: B keeps '
        'getting its presentations past 30 s and nothing else is '
        'listed', () async {
      final (s, responder, channel) = await heardRig();
      final sources = [for (var n = 20; n < 30; n++) n];
      final names = {for (final n in sources) '127.0.0.$n'};
      for (var batch = 0; batch < 20; batch++) {
        final sent = channel.countFrom(names);
        for (var i = 0; i < 50; i++) {
          final seed = 50000 + batch * 50 + i;
          await channel.inject(
            _host(sources[i % sources.length]),
            _hello(
              DeviceInfo(
                name: 'Invented $seed',
                fingerprint: seed
                    .toRadixString(16)
                    .toUpperCase()
                    .padLeft(64, 'E'),
                port: responder.port,
                protocol: protocolVersion,
                deviceType: DeviceType.desktop,
              ),
            ),
          );
        }
        await _until(
          () => channel.countFrom(names) >= sent + 50,
          reason: 'batch $batch delivered',
        );
      }
      expect(channel.countFrom(names), 1000);

      await stillPresentedPast30s(s, responder);
      expect(s.service.current.map((d) => d.info.fingerprint), [
        bob.fingerprint,
      ]);
    });

    test('a hello from the registered IP of B does stop it for 10 s', () async {
      final (s, responder, channel) = await heardRig();
      await _until(() => responder.requestsTo(bob) >= 3);

      await channel.deliver(_host(3), _hello(responder.infoOf(bob)));
      await _settle(() => responder.connections);
      final quiet = responder.connections;

      s.tick(Limits.announceInterval - _justUnder);
      await _pause(const Duration(milliseconds: 500));
      expect(responder.connections, quiet);

      s.tick(_justUnder);
      await _until(() => responder.connections > quiet);
    });
  });

  group('a device that stops answering (E134, RF-239)', () {
    test('an unpaired device stays at 29.999 s, leaves the list at 30 s of '
        'the monotonic clock, and gets no more presentations', () async {
      final (s, responder) = await foundByScan();
      responder.mode = _Mode.refuse;
      final refusedFrom = responder.connections;
      await _until(() => responder.connections >= refusedFrom + 2);

      s.tick(Limits.expireAfter - _justUnder);
      await _pause();
      expect(s.lists(bob.fingerprint), isTrue);

      s.tick(_justUnder);
      await _until(
        () => !s.lists(bob.fingerprint),
        limit: const Duration(seconds: 1),
        reason: 'expired',
      );
      expect(s.emitted.last, isEmpty);

      await _settle(() => responder.connections);
      final tried = responder.connections;
      await _pause(const Duration(milliseconds: 500));
      expect(responder.connections, tried);
    });

    test('a paired device found by a search also leaves the list at 30 s '
        'and gets no more presentations', () async {
      final (s, responder) = await foundByScan(pairedWith: [bob]);
      expect(s.find(bob.fingerprint)!.paired, isTrue);
      responder.mode = _Mode.refuse;
      final refusedFrom = responder.connections;
      await _until(() => responder.connections >= refusedFrom + 2);

      s.tick(Limits.expireAfter);
      await _until(() => !s.lists(bob.fingerprint), reason: 'expired');

      await _settle(() => responder.connections);
      final tried = responder.connections;
      await _pause(const Duration(milliseconds: 500));
      expect(responder.connections, tried);
    });

    test('changing the system time does not move the 30 s: one hour forward '
        'keeps the device, one hour back does not keep it past 30 s of the '
        'monotonic clock', () async {
      final clocks = _Clocks();
      final (s, responder) = await foundByScan(clocks: clocks);
      responder.mode = _Mode.refuse;

      clocks.wall = clocks.wall.add(const Duration(hours: 1));
      await _pause();
      expect(s.lists(bob.fingerprint), isTrue);

      clocks.wall = clocks.wall.subtract(const Duration(hours: 2));
      s.tick(Limits.expireAfter);
      await _until(() => !s.lists(bob.fingerprint), reason: 'expired');
    });
  });

  group('presentations only through active interfaces (A23)', () {
    test('a presentation in flight is cut within 1 s when its interface '
        'leaves, its answer is not applied, and nothing more goes out to '
        'the device', () async {
      final (s, responder) = await foundByScan(
        active: [first, second],
        through: second,
      );
      responder.hold();
      await _until(() => responder.heldWithRequest == 1);
      final link = responder.links.lastWhere((l) => l.requested);

      await s.service.syncInterfaces([first]);
      await link.closed.future.timeout(const Duration(seconds: 1));
      responder.release();
      await _pause(const Duration(milliseconds: 500));

      expect(s.lists(bob.fingerprint), isFalse);
      final tried = responder.connections;
      await _pause(const Duration(milliseconds: 500));
      expect(responder.connections, tried);
    });

    test('a device found through one interface is presented again through '
        'that interface while the other one leaves', () async {
      final (s, responder) = await foundByScan(
        active: [first, second],
        through: first,
      );

      await s.service.syncInterfaces([first]);
      final before = responder.requestsTo(bob);

      await _until(() => responder.requestsTo(bob) >= before + 2);
      expect(s.find(bob.fingerprint)!.interfaceId, first.id);
    });
  });
}
