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
    show jsonContentType, loopback, pairedDeviceOf, presenting;

typedef _Event = (Announcement, InternetAddress, ActiveInterface);

const Duration _limit = Duration(seconds: 5);
const Duration _oneSecond = Duration(seconds: 1);
const Duration _silence = Duration(milliseconds: 300);
const Duration _never = Duration(hours: 1);
const Duration _fast = Duration(milliseconds: 50);
const Duration _cooldown = Duration(seconds: 9);

late String _loopbackName;

InternetAddress _host(int last) => InternetAddress('127.0.0.$last');

ActiveInterface _iface(String address, {int prefixLength = 8}) =>
    ActiveInterface(
      id: 'loopback#$address/$prefixLength',
      adapterId: 'loopback',
      friendlyName: _loopbackName,
      subnet: Ipv4Subnet(InternetAddress(address), prefixLength),
    );

String _fingerprint(int seed) =>
    seed.toRadixString(16).toUpperCase().padLeft(64, 'E');

DeviceInfo _claim(String fingerprint, int port, {String name = 'Claimed'}) =>
    DeviceInfo(
      name: name,
      fingerprint: fingerprint,
      port: port,
      protocol: protocolVersion,
      deviceType: DeviceType.desktop,
    );

DeviceInfo _invented(int seed, int port) =>
    _claim(_fingerprint(seed), port, name: 'Invented $seed');

Announcement _hello(DeviceInfo info) =>
    Announcement(AnnouncementKind.hello, info);

Announcement _bye(DeviceInfo info) => Announcement(AnnouncementKind.bye, info);

final RegExp _contentLength = RegExp(
  r'content-length:\s*(\d+)',
  caseSensitive: false,
);

bool _isCompleteRequest(List<int> bytes) {
  final text = latin1.decode(bytes);
  final end = text.indexOf('\r\n\r\n');
  if (end < 0) return false;
  final match = _contentLength.firstMatch(text.substring(0, end));
  final length = match == null ? 0 : int.parse(match.group(1)!);
  return bytes.length >= end + 4 + length;
}

List<int> _replyOf(DeviceInfo info) {
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

Future<void> _until(bool Function() condition, {Duration? limit}) async {
  final span = limit ?? scaled(_limit);
  final deadline = DateTime.now().add(span);
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) {
      fail('condition not met within $span');
    }
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}

Future<void> _settle(
  int Function() value, {
  Duration quiet = const Duration(milliseconds: 200),
}) async {
  final deadline = DateTime.now().add(scaled(_limit));
  var last = value();
  var since = DateTime.now();
  while (DateTime.now().difference(since) < quiet) {
    if (DateTime.now().isAfter(deadline)) fail('value did not settle');
    await Future<void>.delayed(const Duration(milliseconds: 10));
    final current = value();
    if (current != last) {
      last = current;
      since = DateTime.now();
    }
  }
}

Future<void> _quiet([Duration wait = _silence]) => Future<void>.delayed(wait);

Future<int> _freeTcpPort() => pickPort(tcp: [loopback]);

Future<int> _freePort() =>
    pickPort(tcp: [InternetAddress.anyIPv4], udp: [InternetAddress.anyIPv4]);

Future<PairedDevicesStore> _pairedStore() async {
  final dir = await Directory.systemTemp.createTemp('nexus_discovery_');
  addTearDown(() => dir.delete(recursive: true));
  final store = PairedDevicesStore(
    JsonFileStore(File('${dir.path}${Platform.pathSeparator}paired.json')),
    ownerFingerprint: 'A' * 64,
  );
  await store.load();
  return store;
}

Future<List<Object>> _uncaughtErrorsOf(Future<void> Function() body) async {
  final errors = <Object>[];
  final outcome = Completer<(Object, StackTrace)?>();
  runZonedGuarded(
    () => body().then(
      (_) => outcome.complete(null),
      onError: (Object e, StackTrace s) => outcome.complete((e, s)),
    ),
    (error, _) => errors.add(error),
  );
  final failure = await outcome.future;
  if (failure != null) Error.throwWithStackTrace(failure.$1, failure.$2);
  return errors;
}

final class _Clock {
  DateTime value = DateTime.utc(2026, 10, 22, 12);

  DateTime now() => value;

  void advance(Duration by) => value = value.add(by);
}

final class _Channel {
  _Channel._(this.channel, this.port);

  final MulticastChannel channel;
  final int port;
  final List<_Event> received = [];
  final Map<String, RawDatagramSocket> _senders = {};

  static Future<_Channel> open(List<ActiveInterface> active) async {
    final port = await _freePort();
    final channel = MulticastChannel(port: port);
    addTearDown(channel.close);
    final fixture = _Channel._(channel, port);
    final subscription = channel.incoming.listen(fixture.received.add);
    addTearDown(subscription.cancel);
    await channel.open();
    await channel.syncInterfaces(active);
    return fixture;
  }

  List<_Event> of(String fingerprint, {AnnouncementKind? kind, int skip = 0}) =>
      [
        for (final event in received.skip(skip))
          if (event.$1.info.fingerprint == fingerprint &&
              (kind == null || event.$1.kind == kind))
            event,
      ];

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
    final deadline = DateTime.now().add(scaled(_limit));
    while (socket.send(bytes, InternetAddress.loopbackIPv4, port) !=
        bytes.length) {
      if (DateTime.now().isAfter(deadline)) fail('datagram not sent');
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
                e.$1.kind == announcement.kind &&
                e.$1.info.fingerprint == announcement.info.fingerprint,
          ),
    );
  }
}

final class _Peer {
  _Peer._(this.identity, this.name);

  final DeviceIdentity identity;
  final String name;
  late final ApiServer server;
  final List<(DeviceInfo, InternetAddress)> registrations = [];

  int get port => server.boundPort!;

  DeviceInfo get info => DeviceInfo(
    name: name,
    fingerprint: identity.fingerprint,
    port: port,
    protocol: protocolVersion,
    deviceType: DeviceType.desktop,
  );

  static Future<_Peer> start(
    DeviceIdentity identity, {
    String address = '127.0.0.1',
    String name = 'Peer',
    int port = 0,
  }) async {
    final paired = await _pairedStore();
    final peer = _Peer._(identity, name);
    peer.server = ApiServer(
      identity: identity,
      paired: paired,
      selfInfo: () => peer.info,
      onRegistered: (caller, from, _) => peer.registrations.add((caller, from)),
      port: port,
    );
    addTearDown(peer.server.close);
    await peer.server.syncInterfaces([_iface(address)]);
    expect(peer.server.boundPort, isNotNull);
    return peer;
  }
}

final class _Subject {
  _Subject._(this.identity, this.paired, this.clock);

  final DeviceIdentity identity;
  final PairedDevicesStore paired;
  final _Clock clock;
  final List<String> logs = [];
  final List<List<DiscoveredDevice>> emitted = [];
  late final DiscoveryService service;
  ApiServer? server;
  int registered = 0;
  bool done = false;

  static Future<_Subject> create(
    _Channel channel, {
    required DeviceIdentity identity,
    _Clock? clock,
    Duration announceInterval = _never,
    Duration expireInterval = _oneSecond,
    SubnetScanner Function(DeviceVerifier verifier)? scanner,
    ActiveInterface? serverOn,
  }) async {
    final subject = _Subject._(
      identity,
      await _pairedStore(),
      clock ?? _Clock(),
    );
    final verifier = DeviceVerifier(identity: identity);
    if (serverOn != null) {
      final server = ApiServer(
        identity: identity,
        paired: subject.paired,
        selfInfo: subject.selfInfo,
        onRegistered: (caller, from, via) {
          subject.registered++;
          subject.service.handleRegistration(caller, from, via);
        },
        port: 0,
      );
      addTearDown(server.close);
      await server.syncInterfaces([serverOn]);
      subject.server = server;
    }
    subject.service = DiscoveryService(
      identity: identity,
      selfInfo: subject.selfInfo,
      paired: subject.paired,
      channel: channel.channel,
      verifier: verifier,
      scanner:
          scanner?.call(verifier) ??
          SubnetScanner(verifier: verifier, hostsOf: (_) => const []),
      now: subject.clock.now,
      announceInterval: announceInterval,
      expireInterval: expireInterval,
      log: subject.logs.add,
    );
    addTearDown(() => subject.service.stop(sayGoodbye: false));
    final subscription = subject.service.devices.listen(
      subject.emitted.add,
      onDone: () => subject.done = true,
    );
    addTearDown(subscription.cancel);
    await subject.service.start();
    return subject;
  }

  DeviceInfo selfInfo() => DeviceInfo(
    name: 'Subject',
    fingerprint: identity.fingerprint,
    port: server?.boundPort ?? 40000,
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

  int get unpaired => service.current.where((d) => !d.paired).length;
}

enum _Mode { silent, honest, held }

final class _Endpoint {
  _Endpoint.silent(int last)
    : address = _host(last),
      mode = _Mode.silent,
      identity = null;

  _Endpoint.honest(int last, DeviceIdentity this.identity)
    : address = _host(last),
      mode = _Mode.honest;

  _Endpoint.held(int last, DeviceIdentity this.identity)
    : address = _host(last),
      mode = _Mode.held;

  final InternetAddress address;
  final _Mode mode;
  final DeviceIdentity? identity;
  final Completer<void> _released = Completer();

  void release() {
    if (!_released.isCompleted) _released.complete();
  }
}

final class _Link {
  _Link(this.socket, this.address);

  final Socket socket;
  final String address;
  final List<int> received = [];
  final Completer<void> requested = Completer();
  final Completer<void> closed = Completer();

  bool get isClosed => closed.isCompleted;

  void finish() {
    if (!closed.isCompleted) closed.complete();
  }
}

final class _Farm {
  _Farm._(this.port, this.endpoints);

  final int port;
  final List<_Endpoint> endpoints;
  final List<Future<void> Function()> _closers = [];
  final List<_Link> links = [];
  final Map<String, int> maxOpenAt = {};
  int maxOpen = 0;

  int get open => links.where((l) => !l.isClosed).length;

  int get total => links.length;

  int openAt(int last) =>
      links.where((l) => !l.isClosed && l.address == '127.0.0.$last').length;

  int totalAt(int last) =>
      links.where((l) => l.address == '127.0.0.$last').length;

  int openIn(Iterable<int> lasts) =>
      lasts.fold(0, (sum, last) => sum + openAt(last));

  Future<void> get allClosed =>
      Future.wait([for (final link in links) link.closed.future]);

  _Endpoint endpointAt(int last) =>
      endpoints.firstWhere((e) => e.address.address == '127.0.0.$last');

  DeviceInfo infoAt(int last) => DeviceInfo(
    name: 'Endpoint $last',
    fingerprint: endpointAt(last).identity!.fingerprint,
    port: port,
    protocol: protocolVersion,
    deviceType: DeviceType.desktop,
  );

  Future<_Link> linkTo(int last) async {
    bool matches(_Link l) => l.address == '127.0.0.$last';
    await _until(() => links.any(matches));
    return links.firstWhere(matches);
  }

  Future<void> requestAt(int last) async {
    final link = await linkTo(last);
    await link.requested.future.timeout(scaled(_limit));
  }

  static Future<_Farm> start(List<_Endpoint> endpoints) async {
    for (var attempt = 0; attempt < 10; attempt++) {
      final farm = _Farm._(await _freeTcpPort(), endpoints);
      if (await farm._bindAll()) {
        addTearDown(farm.close);
        return farm;
      }
      await farm.close();
    }
    throw StateError('no common free port for the farm');
  }

  Future<bool> _bindAll() async {
    try {
      for (final endpoint in endpoints) {
        if (endpoint.mode == _Mode.silent) {
          final server = await ServerSocket.bind(endpoint.address, port);
          _closers.add(server.close);
          server.listen((s) => _accept(s, endpoint), onError: (Object _) {});
        } else {
          final server = await SecureServerSocket.bind(
            endpoint.address,
            port,
            presenting(endpoint.identity!),
          );
          _closers.add(server.close);
          server.listen((s) => _accept(s, endpoint), onError: (Object _) {});
        }
      }
      return true;
    } on SocketException {
      return false;
    }
  }

  void _accept(Socket socket, _Endpoint endpoint) {
    final link = _Link(socket, endpoint.address.address);
    links.add(link);
    maxOpen = max(maxOpen, open);
    final openHere = links
        .where((l) => !l.isClosed && l.address == link.address)
        .length;
    maxOpenAt[link.address] = max(maxOpenAt[link.address] ?? 0, openHere);
    socket.done.ignore();
    socket.listen(
      (chunk) {
        link.received.addAll(chunk);
        if (link.requested.isCompleted || !_isCompleteRequest(link.received)) {
          return;
        }
        link.requested.complete();
        if (endpoint.mode == _Mode.silent) return;
        final reply = _replyOf(infoAt(int.parse(link.address.split('.').last)));
        if (endpoint.mode == _Mode.honest) {
          _write(link, reply);
        } else {
          endpoint._released.future.then((_) => _write(link, reply));
        }
      },
      onError: (Object _) => link.finish(),
      onDone: link.finish,
      cancelOnError: true,
    );
  }

  static void _write(_Link link, List<int> reply) {
    if (link.isClosed) return;
    try {
      link.socket.add(reply);
      link.socket.close().ignore();
    } on Object {
      return;
    }
  }

  void dropAll() {
    for (final link in links) {
      if (link.isClosed) continue;
      link.socket.destroy();
      link.finish();
    }
  }

  Future<void> drain() async {
    final deadline = DateTime.now().add(const Duration(seconds: 20));
    var last = -1;
    var since = DateTime.now();
    while (true) {
      dropAll();
      if (total != last) {
        last = total;
        since = DateTime.now();
      } else if (DateTime.now().difference(since) >= _silence) {
        return;
      }
      if (DateTime.now().isAfter(deadline)) fail('the farm never went quiet');
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
  }

  Future<void> close() async {
    for (final link in links) {
      link.socket.destroy();
      link.finish();
    }
    await Future.wait([for (final close in _closers) close()]);
  }
}

final class _Neighbour {
  _Neighbour._(this.socket, this.channel);

  final RawDatagramSocket socket;
  final _Channel channel;
  final List<(Announcement, InternetAddress)> heard = [];

  static Future<_Neighbour> bind(
    _Channel channel,
    InternetAddress address,
  ) async {
    final socket = await RawDatagramSocket.bind(
      address,
      channel.port,
      reuseAddress: false,
    );
    addTearDown(socket.close);
    final neighbour = _Neighbour._(socket, channel);
    socket.listen((event) {
      if (event != RawSocketEvent.read) return;
      Datagram? datagram;
      while ((datagram = socket.receive()) != null) {
        final announcement = Announcement.tryDecode(datagram!.data);
        if (announcement != null) {
          neighbour.heard.add((announcement, datagram.address));
        }
      }
    });
    return neighbour;
  }

  List<Announcement> answersFrom(String fingerprint) => [
    for (final (announcement, _) in heard)
      if (announcement.info.fingerprint == fingerprint) announcement,
  ];

  Future<void> say(Announcement announcement) async {
    final before = channel.received.length;
    final bytes = announcement.encode();
    final deadline = DateTime.now().add(scaled(_limit));
    while (socket.send(bytes, InternetAddress.loopbackIPv4, channel.port) !=
        bytes.length) {
      if (DateTime.now().isAfter(deadline)) fail('datagram not sent');
      await Future<void>.delayed(const Duration(milliseconds: 1));
    }
    await _until(
      () => channel.received
          .skip(before)
          .any(
            (e) =>
                e.$2.address == socket.address.address &&
                e.$1.kind == announcement.kind &&
                e.$1.info.fingerprint == announcement.info.fingerprint,
          ),
    );
  }
}

final class _Knocks {
  _Knocks._(this.port);

  final int port;
  final Map<String, int> hits = {};
  final List<ServerSocket> _servers = [];

  static Future<_Knocks> start(List<InternetAddress> addresses) async {
    for (var attempt = 0; attempt < 10; attempt++) {
      final knocks = _Knocks._(await _freeTcpPort());
      if (await knocks._bindAll(addresses)) {
        addTearDown(knocks.close);
        return knocks;
      }
      await knocks.close();
    }
    throw StateError('no common free port for the knocks');
  }

  Future<bool> _bindAll(List<InternetAddress> addresses) async {
    try {
      for (final address in addresses) {
        final server = await ServerSocket.bind(address, port);
        _servers.add(server);
        server.listen(_accept, onError: (Object _) {});
      }
      return true;
    } on SocketException {
      return false;
    }
  }

  void _accept(Socket socket) {
    final key = socket.address.address;
    hits[key] = (hits[key] ?? 0) + 1;
    socket.destroy();
  }

  Future<void> close() async {
    await Future.wait([for (final server in _servers) server.close()]);
  }
}

final class _RenamablePeer {
  _RenamablePeer._(this.identity, this.name);

  final DeviceIdentity identity;
  String name;
  late final ApiServer server;
  final List<(DeviceInfo, InternetAddress)> registrations = [];

  int get port => server.boundPort!;

  DeviceInfo get info => DeviceInfo(
    name: name,
    fingerprint: identity.fingerprint,
    port: port,
    protocol: protocolVersion,
    deviceType: DeviceType.desktop,
  );

  static Future<_RenamablePeer> start(
    DeviceIdentity identity, {
    required String address,
    required String name,
  }) async {
    final paired = await _pairedStore();
    final peer = _RenamablePeer._(identity, name);
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
  late DeviceIdentity alice;
  late DeviceIdentity bob;
  late DeviceIdentity carol;
  late DeviceIdentity dave;
  late DeviceIdentity erin;
  late ActiveInterface first;
  late ActiveInterface second;

  setUpAll(() async {
    final all = await NetworkInterface.list(includeLoopback: true);
    _loopbackName = all
        .firstWhere((i) => i.addresses.any((a) => a.address == '127.0.0.1'))
        .name;
    self = DeviceIdentity.generate();
    alice = DeviceIdentity.generate();
    bob = DeviceIdentity.generate();
    carol = DeviceIdentity.generate();
    dave = DeviceIdentity.generate();
    erin = DeviceIdentity.generate();
    first = _iface('127.0.0.1');
    second = _iface('127.0.0.2');
  });

  group('own announcements (RF-39, RF-20, RF-16, RF-22)', () {
    test('with an interval of 50 ms the own hello goes out again and again '
        'through the active interface, carries selfInfo, and the service '
        'never lists itself (RF-46)', () async {
      final channel = await _Channel.open([first]);
      final s = await _Subject.create(
        channel,
        identity: self,
        announceInterval: _fast,
      );

      await s.service.syncInterfaces([first]);
      await _until(() => channel.of(self.fingerprint).length >= 5);
      await _quiet();

      final own = channel.of(self.fingerprint);
      expect(own.length, greaterThanOrEqualTo(5));
      for (final (announcement, from, via) in own) {
        expect(announcement.kind, AnnouncementKind.hello);
        expect(announcement.encode(), _hello(s.selfInfo()).encode());
        expect(from, loopback);
        expect(via, same(first));
      }
      expect(s.service.current, isEmpty);
      expect(s.emitted, isEmpty);
    });

    test('activating an interface sends one hello at once, without waiting '
        'for the interval, and activating it again sends nothing '
        '(RF-20)', () async {
      final channel = await _Channel.open([first]);
      final s = await _Subject.create(channel, identity: self);

      await s.service.syncInterfaces([first]);
      await _until(
        () => channel.of(self.fingerprint).isNotEmpty,
        limit: _oneSecond,
      );
      await s.service.syncInterfaces([first]);
      await _quiet();

      expect(channel.of(self.fingerprint), hasLength(1));
    });

    test('without active interfaces neither the timer nor announceNow send '
        'anything, and the timer starts once one is active', () async {
      final channel = await _Channel.open([first]);
      final s = await _Subject.create(
        channel,
        identity: self,
        announceInterval: _fast,
      );

      s.service.announceNow();
      await _quiet();
      expect(channel.of(self.fingerprint), isEmpty);

      await s.service.syncInterfaces([first]);
      await _until(() => channel.of(self.fingerprint).length >= 3);
    });

    test('an interface that leaves is no longer announced (RF-16)', () async {
      final channel = await _Channel.open([first]);
      final s = await _Subject.create(
        channel,
        identity: self,
        announceInterval: _fast,
      );
      await s.service.syncInterfaces([first]);
      await _until(() => channel.of(self.fingerprint).length >= 2);

      await s.service.syncInterfaces([]);
      await _quiet(const Duration(milliseconds: 150));
      final sent = channel.of(self.fingerprint).length;
      await _quiet();

      expect(channel.of(self.fingerprint), hasLength(sent));
    });

    test('announceNow sends one hello per active interface right away, all '
        'with origin 127.0.0.1 (RF-22)', () async {
      final channel = await _Channel.open([first, second]);
      final s = await _Subject.create(channel, identity: self);
      await s.service.syncInterfaces([first, second]);
      await _until(() => channel.of(self.fingerprint).length == 2);
      await _quiet();
      expect(channel.of(self.fingerprint), hasLength(2));

      s.service.announceNow();
      await _until(() => channel.of(self.fingerprint).length >= 4);
      await _quiet();

      final own = channel.of(self.fingerprint);
      expect(own, hasLength(4));
      expect(own.map((e) => e.$1.kind), everyElement(AnnouncementKind.hello));
      expect(own.map((e) => e.$2), everyElement(loopback));
    });
  });

  group('two services on one real channel (RF-45)', () {
    test('each one sees the other within 5 s and never itself', () async {
      final channel = await _Channel.open([first]);
      final a = await _Subject.create(
        channel,
        identity: alice,
        announceInterval: Limits.announceInterval,
        serverOn: first,
      );
      final b = await _Subject.create(
        channel,
        identity: bob,
        announceInterval: Limits.announceInterval,
        serverOn: first,
      );
      final watch = Stopwatch()..start();

      await a.service.syncInterfaces([first]);
      await b.service.syncInterfaces([first]);
      await _until(
        () => a.lists(bob.fingerprint) && b.lists(alice.fingerprint),
      );

      expect(watch.elapsed, lessThan(_limit));
      expect(a.service.current.map((d) => d.info.fingerprint), [
        bob.fingerprint,
      ]);
      expect(b.service.current.map((d) => d.info.fingerprint), [
        alice.fingerprint,
      ]);
      expect(a.find(bob.fingerprint)!.info.toJson(), b.selfInfo().toJson());
      expect(b.find(alice.fingerprint)!.info.toJson(), a.selfInfo().toJson());
      expect(a.find(bob.fingerprint)!.address, loopback);
      expect(a.find(bob.fingerprint)!.interfaceId, first.id);
      expect(a.emitted.last.single.info.fingerprint, bob.fingerprint);
      expect(b.emitted.last.single.info.fingerprint, alice.fingerprint);
    });
  });

  group('presenting to an announced device (RF-41, RF-42, RF-43)', () {
    test('a hello from another device makes the service present itself to '
        'it and list it once its fingerprint is confirmed', () async {
      final peer = await _Peer.start(bob);
      final channel = await _Channel.open([first]);
      final s = await _Subject.create(channel, identity: self);
      await s.service.syncInterfaces([first]);

      await channel.deliver(loopback, _hello(peer.info));
      await _until(() => s.lists(bob.fingerprint));

      final device = s.find(bob.fingerprint)!;
      expect(device.info.toJson(), peer.info.toJson());
      expect(device.address, loopback);
      expect(device.interfaceId, first.id);
      expect(device.paired, isFalse);
      expect(peer.registrations, hasLength(1));
      expect(peer.registrations.single.$1.toJson(), s.selfInfo().toJson());
      expect(s.emitted.last.single.info.fingerprint, bob.fingerprint);
    });

    test('a hello with the fingerprint of one device that points to a '
        'server with another identity never enters, and that server never '
        'receives the presentation (SEC-05)', () async {
      final peer = await _Peer.start(alice);
      final channel = await _Channel.open([first]);
      final s = await _Subject.create(channel, identity: self);
      await s.service.syncInterfaces([first]);

      await channel.deliver(
        loopback,
        _hello(_claim(bob.fingerprint, peer.port)),
      );
      await channel.deliver(loopback, _hello(peer.info));
      await _until(() => s.lists(alice.fingerprint));
      await _quiet();

      expect(s.lists(bob.fingerprint), isFalse);
      expect(s.service.current.map((d) => d.info.fingerprint), [
        alice.fingerprint,
      ]);
      expect(peer.registrations, hasLength(1));
    });

    test('a hello that arrives through an interface that is not active in '
        'the service is ignored (RF-18)', () async {
      final peer = await _Peer.start(bob);
      final channel = await _Channel.open([first]);
      final s = await _Subject.create(channel, identity: self);

      await channel.deliver(loopback, _hello(peer.info));
      await _quiet();
      expect(peer.registrations, isEmpty);
      expect(s.lists(bob.fingerprint), isFalse);

      await s.service.syncInterfaces([first]);
      await channel.deliver(loopback, _hello(peer.info));
      await _until(() => s.lists(bob.fingerprint));
    });
  });

  group('failed presentations (RF-44)', () {
    test('a hello for a port without a server does not enter; once the '
        'server is up, a hello within the 9 s wait is not even tried and one '
        'after it enters', () async {
      final clock = _Clock();
      final channel = await _Channel.open([first]);
      final s = await _Subject.create(channel, identity: self, clock: clock);
      await s.service.syncInterfaces([first]);
      final port = await _freeTcpPort();

      await channel.deliver(loopback, _hello(_claim(bob.fingerprint, port)));
      await _quiet(const Duration(seconds: 4));
      expect(s.lists(bob.fingerprint), isFalse);
      expect(s.emitted, isEmpty);

      final peer = await _Peer.start(bob, port: port);
      clock.advance(const Duration(seconds: 8));
      await channel.deliver(loopback, _hello(peer.info));
      await _quiet(_oneSecond);
      expect(peer.registrations, isEmpty);
      expect(s.lists(bob.fingerprint), isFalse);

      clock.advance(const Duration(seconds: 1, milliseconds: 1));
      await channel.deliver(loopback, _hello(peer.info));
      await _until(() => s.lists(bob.fingerprint));
      expect(s.find(bob.fingerprint)!.info.port, port);
      expect(peer.registrations, hasLength(1));
    });
  });

  group('a known device at another address (RF-48)', () {
    test('a hello from 127.0.0.2 moves the device only when a server there '
        'proves its fingerprint', () async {
      final clock = _Clock();
      final channel = await _Channel.open([first]);
      final s = await _Subject.create(channel, identity: self, clock: clock);
      await s.service.syncInterfaces([first]);
      final original = await _Peer.start(bob);
      await channel.deliver(loopback, _hello(original.info));
      await _until(() => s.lists(bob.fingerprint));

      final impostor = await _Peer.start(carol, address: '127.0.0.2');
      final emissions = s.emitted.length;
      await channel.deliver(
        _host(2),
        _hello(_claim(bob.fingerprint, impostor.port, name: 'Moved')),
      );
      await _quiet(_oneSecond);

      expect(s.find(bob.fingerprint)!.address, loopback);
      expect(s.find(bob.fingerprint)!.info.toJson(), original.info.toJson());
      expect(s.emitted, hasLength(emissions));
      expect(impostor.registrations, isEmpty);

      final moved = await _Peer.start(
        bob,
        address: '127.0.0.2',
        name: 'Bob moved',
      );
      clock.advance(_cooldown + _oneSecond);
      await channel.deliver(_host(2), _hello(moved.info));
      await _until(
        () => s.find(bob.fingerprint)?.address.address == '127.0.0.2',
      );

      final device = s.find(bob.fingerprint)!;
      expect(device.info.toJson(), moved.info.toJson());
      expect(device.interfaceId, first.id);
      expect(s.service.current, hasLength(1));
      expect(moved.registrations.single.$1.toJson(), s.selfInfo().toJson());
      expect(s.emitted.last.single.address, _host(2));
    });
  });

  group('goodbyes (RF-51, RF-52)', () {
    test('stop(sayGoodbye: true) with two active interfaces of the loopback '
        'adapter sends 2 byes from 127.0.0.1, the other service drops the '
        'device within 1 s, and the channel keeps working', () async {
      final channel = await _Channel.open([first, second]);
      final a = await _Subject.create(
        channel,
        identity: alice,
        serverOn: first,
      );
      final b = await _Subject.create(channel, identity: bob, serverOn: first);
      await a.service.syncInterfaces([first, second]);
      await b.service.syncInterfaces([first, second]);
      await _until(
        () => b.lists(alice.fingerprint) && a.lists(bob.fingerprint),
      );
      await _settle(() => a.registered + b.registered, quiet: _silence);
      final before = channel.received.length;

      await a.service.stop(sayGoodbye: true);
      await a.server!.close();
      await _until(() => !b.lists(alice.fingerprint), limit: _oneSecond);
      await _until(
        () =>
            channel
                .of(alice.fingerprint, kind: AnnouncementKind.bye, skip: before)
                .length >=
            2,
      );
      await _quiet();

      final byes = channel.of(
        alice.fingerprint,
        kind: AnnouncementKind.bye,
        skip: before,
      );
      expect(byes, hasLength(2));
      expect(byes.map((e) => e.$2), everyElement(loopback));
      expect(b.emitted.last, isEmpty);
      expect(b.service.current, isEmpty);

      b.service.announceNow();
      await _until(
        () => channel
            .of(bob.fingerprint, kind: AnnouncementKind.hello, skip: before)
            .isNotEmpty,
      );
    });

    test('a false bye from 127.0.0.2 for a device that is at 127.0.0.1 '
        'leaves it listed, and a real bye from 127.0.0.1 removes it within '
        '1 s (R17)', () async {
      final peer = await _Peer.start(bob);
      final channel = await _Channel.open([first]);
      final s = await _Subject.create(channel, identity: self);
      await s.service.syncInterfaces([first]);
      await channel.deliver(loopback, _hello(peer.info));
      await _until(() => s.lists(bob.fingerprint));
      final emissions = s.emitted.length;

      await channel.deliver(_host(2), _bye(peer.info));
      await _quiet();
      expect(s.lists(bob.fingerprint), isTrue);
      expect(s.emitted, hasLength(emissions));

      await channel.deliver(loopback, _bye(peer.info));
      await _until(() => !s.lists(bob.fingerprint), limit: _oneSecond);
      expect(s.emitted.last, isEmpty);
    });
  });

  group('C130: the goodbye of a paired device is verified first (RF-52 of '
      'the 002, RF-111, N2)', () {
    test('two forged byes from the address of a live paired device leave it '
        'listed and cost it one presentation; its real bye after closing its '
        'server removes it as soon as the connection is refused (about 2 s '
        'on Windows)', () async {
      final clock = _Clock();
      final peer = await _Peer.start(bob, address: '127.0.0.2');
      final channel = await _Channel.open([first]);
      final s = await _Subject.create(channel, identity: self, clock: clock);
      await s.paired.replaceAll([pairedDeviceOf(bob)]);
      await s.service.syncInterfaces([first]);
      await channel.deliver(_host(2), _hello(peer.info));
      await _until(() => s.lists(bob.fingerprint));
      expect(peer.registrations, hasLength(1));
      final emissions = s.emitted.length;

      await channel.deliver(_host(2), _bye(peer.info));
      await _until(() => peer.registrations.length == 2);
      clock.advance(_oneSecond);
      await channel.deliver(_host(2), _bye(peer.info));
      await _settle(() => peer.registrations.length, quiet: _oneSecond);

      expect(peer.registrations, hasLength(2));
      expect(s.lists(bob.fingerprint), isTrue);
      expect(s.find(bob.fingerprint)!.address, _host(2));
      expect(s.emitted, hasLength(emissions));

      clock.advance(const Duration(seconds: 5));
      final info = peer.info;
      await peer.server.close();
      final watch = Stopwatch()..start();
      await channel.deliver(_host(2), _bye(info));
      await _until(
        () => !s.lists(bob.fingerprint),
        limit: const Duration(seconds: 4),
      );
      expect(watch.elapsed, lessThan(Limits.requestTimeout));
      expect(s.emitted.last, isEmpty);
    });

    test('the real bye of a paired device whose port drops the connection '
        'removes it within 1 s', () async {
      final peer = await _Peer.start(bob, address: '127.0.0.2');
      final channel = await _Channel.open([first]);
      final s = await _Subject.create(channel, identity: self);
      await s.paired.replaceAll([pairedDeviceOf(bob)]);
      await s.service.syncInterfaces([first]);
      await channel.deliver(_host(2), _hello(peer.info));
      await _until(() => s.lists(bob.fingerprint));
      final info = peer.info;
      await peer.server.close();
      final dropping = await ServerSocket.bind(_host(2), info.port);
      addTearDown(dropping.close);
      var dropped = 0;
      dropping.listen((socket) {
        dropped++;
        socket.destroy();
      });

      await channel.deliver(_host(2), _bye(info));
      await _until(() => !s.lists(bob.fingerprint), limit: _oneSecond);
      expect(dropped, 1);
      expect(s.emitted.last, isEmpty);
    });

    test('a forged bye whose own port points elsewhere is checked against the '
        'stored port, never the one in the datagram', () async {
      final clock = _Clock();
      final peer = await _Peer.start(bob, address: '127.0.0.2');
      final knocks = await _Knocks.start([_host(2)]);
      final channel = await _Channel.open([first]);
      final s = await _Subject.create(channel, identity: self, clock: clock);
      await s.paired.replaceAll([pairedDeviceOf(bob)]);
      await s.service.syncInterfaces([first]);
      await channel.deliver(_host(2), _hello(peer.info));
      await _until(() => s.lists(bob.fingerprint));

      await channel.deliver(
        _host(2),
        _bye(_claim(bob.fingerprint, knocks.port, name: 'Forged')),
      );
      await _until(() => peer.registrations.length == 2);
      await _quiet();

      expect(knocks.hits, isEmpty);
      expect(s.lists(bob.fingerprint), isTrue);
      expect(s.find(bob.fingerprint)!.info.toJson(), peer.info.toJson());
    });

    test('B-5: a bye that arrives while a name check of the same device is '
        'in flight is not written down as checked, so the next bye is '
        'verified and removes the device', () async {
      final clock = _Clock();
      final peer = await _Peer.start(bob, address: '127.0.0.2', name: 'Laptop');
      final channel = await _Channel.open([first]);
      final s = await _Subject.create(channel, identity: self, clock: clock);
      await s.paired.replaceAll([pairedDeviceOf(bob)]);
      await s.service.syncInterfaces([first]);
      await channel.deliver(_host(2), _hello(peer.info));
      await _until(() => s.lists(bob.fingerprint));
      final info = peer.info;
      await peer.server.close();
      final holding = await ServerSocket.bind(_host(2), info.port);
      addTearDown(holding.close);
      final held = <Socket>[];
      var accepted = 0;
      holding.listen((socket) {
        accepted++;
        held.add(socket);
      });

      await channel.deliver(
        _host(2),
        _hello(_claim(bob.fingerprint, info.port, name: 'Renamed')),
      );
      await _until(() => accepted == 1);
      await channel.deliver(_host(2), _bye(info));
      await _quiet();
      expect(accepted, 1);
      expect(s.lists(bob.fingerprint), isTrue);

      for (final socket in held) {
        socket.destroy();
      }
      await _quiet();
      await channel.deliver(_host(2), _bye(info));
      await _until(() => accepted == 2, limit: _oneSecond);
      for (final socket in held) {
        socket.destroy();
      }
      await _until(() => !s.lists(bob.fingerprint), limit: _oneSecond);
    });

    test('the bye of a device that is not paired removes it at once without '
        'a check, as before', () async {
      final peer = await _Peer.start(carol, address: '127.0.0.2');
      final channel = await _Channel.open([first]);
      final s = await _Subject.create(channel, identity: self);
      await s.paired.replaceAll([pairedDeviceOf(bob)]);
      await s.service.syncInterfaces([first]);
      await channel.deliver(_host(2), _hello(peer.info));
      await _until(() => s.lists(carol.fingerprint));

      await channel.deliver(_host(2), _bye(peer.info));
      await _until(() => !s.lists(carol.fingerprint), limit: _oneSecond);
      await _quiet();
      expect(peer.registrations, hasLength(1));
    });
  });

  group('C131: a poisoned cooldown does not hide a paired device (RF-44 of '
      'the 002, SEC-05, N2)', () {
    test('a forged hello with the fingerprint of P and a port that does not '
        'answer fails, and the real hello of P one second later gets P listed '
        'within 2 s', () async {
      final clock = _Clock();
      final peer = await _Peer.start(bob, address: '127.0.0.2');
      final dead = await _Knocks.start([_host(2)]);
      final channel = await _Channel.open([first]);
      final s = await _Subject.create(channel, identity: self, clock: clock);
      await s.paired.replaceAll([pairedDeviceOf(bob)]);
      await s.service.syncInterfaces([first]);

      await channel.deliver(
        _host(2),
        _hello(_claim(bob.fingerprint, dead.port, name: 'Forged')),
      );
      await _until(() => dead.hits['127.0.0.2'] == 1);
      await _quiet();
      expect(s.lists(bob.fingerprint), isFalse);
      expect(peer.registrations, isEmpty);

      clock.advance(_oneSecond);
      await channel.deliver(_host(2), _hello(peer.info));
      await _until(
        () => s.lists(bob.fingerprint),
        limit: const Duration(seconds: 2),
      );
      expect(s.find(bob.fingerprint)!.info.port, peer.port);
      expect(peer.registrations, hasLength(1));
    });

    test('the same forged hello still cools down an unpaired device for 9 s '
        '(R14 is not relaxed)', () async {
      final clock = _Clock();
      final dead = await _Knocks.start([_host(2)]);
      final peer = await _Peer.start(carol, address: '127.0.0.2');
      final channel = await _Channel.open([first]);
      final s = await _Subject.create(channel, identity: self, clock: clock);
      await s.service.syncInterfaces([first]);

      await channel.deliver(
        _host(2),
        _hello(_claim(carol.fingerprint, dead.port)),
      );
      await _until(() => dead.hits['127.0.0.2'] == 1);
      await _quiet();
      clock.advance(_oneSecond);
      await channel.deliver(_host(2), _hello(peer.info));
      await _quiet(_oneSecond);

      expect(s.lists(carol.fingerprint), isFalse);
      expect(peer.registrations, isEmpty);
    });
  });

  group('expiry (RF-53)', () {
    test('a device without news for 29 s stays, and past 30 s it is gone '
        'at the next tick', () async {
      final clock = _Clock();
      final peer = await _Peer.start(bob);
      final channel = await _Channel.open([first]);
      final s = await _Subject.create(
        channel,
        identity: self,
        clock: clock,
        expireInterval: _fast,
      );
      await s.service.syncInterfaces([first]);
      await channel.deliver(loopback, _hello(peer.info));
      await _until(() => s.lists(bob.fingerprint));

      clock.advance(const Duration(seconds: 29));
      await _quiet();
      expect(s.lists(bob.fingerprint), isTrue);

      clock.advance(const Duration(seconds: 2));
      await _until(() => !s.lists(bob.fingerprint), limit: _oneSecond);
      expect(s.emitted.last, isEmpty);
    });

    test('a hello from the current address refreshes the device without '
        'verifying it again and without emitting', () async {
      final clock = _Clock();
      final peer = await _Peer.start(bob);
      final channel = await _Channel.open([first]);
      final s = await _Subject.create(
        channel,
        identity: self,
        clock: clock,
        expireInterval: _fast,
      );
      await s.service.syncInterfaces([first]);
      await channel.deliver(loopback, _hello(peer.info));
      await _until(() => s.lists(bob.fingerprint));
      final emissions = s.emitted.length;

      clock.advance(const Duration(seconds: 20));
      await channel.deliver(loopback, _hello(peer.info));
      await _quiet();
      expect(s.emitted, hasLength(emissions));
      expect(peer.registrations, hasLength(1));

      clock.advance(const Duration(seconds: 20));
      await _quiet();
      expect(s.lists(bob.fingerprint), isTrue);

      clock.advance(const Duration(seconds: 11));
      await _until(() => !s.lists(bob.fingerprint), limit: _oneSecond);
    });
  });

  group('manual search (RF-54)', () {
    test('rescan with hosts at 127.0.0.1 adds the device it finds and only '
        'asks for the active interfaces', () async {
      final peer = await _Peer.start(bob);
      final channel = await _Channel.open([first, second]);
      final asked = <String>[];
      final s = await _Subject.create(
        channel,
        identity: self,
        scanner: (verifier) => SubnetScanner(
          verifier: verifier,
          port: peer.port,
          hostsOf: (iface) {
            asked.add(iface.id);
            return [loopback];
          },
        ),
      );
      await s.service.syncInterfaces([first]);

      await s.service.rescan().timeout(scaled(_limit));

      expect(asked, [first.id]);
      final device = s.find(bob.fingerprint)!;
      expect(device.info.toJson(), peer.info.toJson());
      expect(device.address, loopback);
      expect(device.interfaceId, first.id);
      expect(peer.registrations.single.$1.toJson(), s.selfInfo().toJson());
      expect(s.emitted.last.single.info.fingerprint, bob.fingerprint);
    });

    test('a host with the own fingerprint is not listed', () async {
      final farm = await _Farm.start([
        _Endpoint.honest(30, self),
        _Endpoint.honest(31, bob),
      ]);
      final channel = await _Channel.open([first]);
      final s = await _Subject.create(
        channel,
        identity: self,
        scanner: (verifier) => SubnetScanner(
          verifier: verifier,
          port: farm.port,
          hostsOf: (_) => [_host(30), _host(31)],
        ),
      );
      await s.service.syncInterfaces([first]);

      await s.service.rescan().timeout(scaled(_limit));

      expect(farm.totalAt(30), 1);
      expect(s.service.current.map((d) => d.info.fingerprint), [
        bob.fingerprint,
      ]);
    });

    test('rescan without active interfaces tries nothing and ends', () async {
      final farm = await _Farm.start([_Endpoint.honest(31, bob)]);
      final channel = await _Channel.open([first]);
      final asked = <String>[];
      final s = await _Subject.create(
        channel,
        identity: self,
        scanner: (verifier) => SubnetScanner(
          verifier: verifier,
          port: farm.port,
          hostsOf: (iface) {
            asked.add(iface.id);
            return [_host(31)];
          },
        ),
      );

      await s.service.rescan().timeout(_oneSecond);
      await _quiet();

      expect(asked, isEmpty);
      expect(farm.total, 0);
      expect(s.service.current, isEmpty);
    });
  });

  group('presentations received (v2.7 point 3)', () {
    test('a correct presentation enters once the service has checked the '
        'fingerprint at the caller', () async {
      final peer = await _Peer.start(bob);
      final channel = await _Channel.open([first]);
      final s = await _Subject.create(channel, identity: self);
      await s.service.syncInterfaces([first]);

      s.service.handleRegistration(peer.info, loopback, first);
      await _until(() => s.lists(bob.fingerprint));

      final device = s.find(bob.fingerprint)!;
      expect(device.address, loopback);
      expect(device.interfaceId, first.id);
      expect(device.info.toJson(), peer.info.toJson());
      expect(peer.registrations.single.$1.toJson(), s.selfInfo().toJson());
    });

    test('a caller that declares the fingerprint of another device never '
        'enters', () async {
      final peer = await _Peer.start(alice);
      final channel = await _Channel.open([first]);
      final s = await _Subject.create(channel, identity: self);
      await s.service.syncInterfaces([first]);

      s.service.handleRegistration(
        _claim(bob.fingerprint, peer.port),
        loopback,
        first,
      );
      s.service.handleRegistration(peer.info, loopback, first);
      await _until(() => s.lists(alice.fingerprint));
      await _quiet();

      expect(s.lists(bob.fingerprint), isFalse);
      expect(peer.registrations, hasLength(1));
    });

    test('a caller with the own fingerprint is ignored without connecting '
        'to it', () async {
      final farm = await _Farm.start([_Endpoint.silent(3)]);
      final channel = await _Channel.open([first]);
      final s = await _Subject.create(channel, identity: self);
      await s.service.syncInterfaces([first]);

      s.service.handleRegistration(
        _claim(self.fingerprint, farm.port),
        _host(3),
        first,
      );
      await _quiet();
      expect(farm.total, 0);

      s.service.handleRegistration(_invented(1, farm.port), _host(3), first);
      await _until(() => farm.total == 1);
      expect(s.service.current, isEmpty);
    });

    test('a presentation through an interface that is not active is '
        'ignored', () async {
      final farm = await _Farm.start([_Endpoint.silent(3)]);
      final channel = await _Channel.open([first]);
      final s = await _Subject.create(channel, identity: self);
      await s.service.syncInterfaces([first]);

      s.service.handleRegistration(_invented(1, farm.port), _host(3), second);
      await _quiet();
      expect(farm.total, 0);

      s.service.handleRegistration(_invented(1, farm.port), _host(3), first);
      await _until(() => farm.total == 1);
    });

    test('end to end: a device that presents itself to the real server of '
        'the service is listed after the service checks it back', () async {
      final peer = await _Peer.start(carol);
      final channel = await _Channel.open([first]);
      final s = await _Subject.create(channel, identity: self, serverOn: first);
      await s.service.syncInterfaces([first]);

      final answer = await DeviceVerifier(identity: carol).register(
        address: loopback,
        port: s.server!.boundPort!,
        expectedFingerprint: self.fingerprint,
        self: peer.info,
      );
      await _until(() => s.lists(carol.fingerprint));

      expect(answer?.toJson(), s.selfInfo().toJson());
      expect(s.find(carol.fingerprint)!.info.toJson(), peer.info.toJson());
      expect(peer.registrations.single.$1.toJson(), s.selfInfo().toJson());
    });
  });

  group('flood of invented announcements (RF-57, RF-58, R14, R17)', () {
    test('100 invented hellos from 10 IP never run more than 8 checks at '
        'once nor 2 per IP, nor queue more than 64, and a paired device '
        'already listed stays visible', () async {
      final sources = [for (var n = 2; n <= 11; n++) n];
      final farm = await _Farm.start([
        for (final n in sources) _Endpoint.silent(n),
      ]);
      final peer = await _Peer.start(carol);
      final channel = await _Channel.open([first]);
      final s = await _Subject.create(channel, identity: self);
      await s.paired.replaceAll([pairedDeviceOf(carol)]);
      await s.service.syncInterfaces([first]);
      await channel.deliver(loopback, _hello(peer.info));
      await _until(() => s.lists(carol.fingerprint));

      for (var i = 0; i < 100; i++) {
        await channel.inject(
          _host(sources[i % sources.length]),
          _hello(_invented(1000 + i, farm.port)),
        );
      }
      await _until(
        () => channel.countFrom({for (final n in sources) '127.0.0.$n'}) >= 100,
      );
      await _settle(() => farm.total);

      expect(farm.open, greaterThan(0));
      expect(farm.maxOpen, lessThanOrEqualTo(8));
      expect(farm.maxOpenAt.values, everyElement(lessThanOrEqualTo(2)));

      await farm.drain();

      expect(farm.total, lessThanOrEqualTo(8 + 64));
      expect(farm.maxOpen, lessThanOrEqualTo(8));
      expect(farm.maxOpenAt.values, everyElement(lessThanOrEqualTo(2)));
      expect(s.find(carol.fingerprint)?.paired, isTrue);
      expect(s.unpaired, 0);
      expect(s.logs.join('\n'), isNot(contains('PRIVATE KEY')));
    });

    test('with the normal lane full, including a false hello with the '
        'fingerprint and the IP of the real device, the presentation of that '
        'device is still checked and listed', () async {
      final sources = [for (var n = 2; n <= 11; n++) n];
      final farm = await _Farm.start([
        _Endpoint.silent(1),
        for (final n in sources) _Endpoint.silent(n),
      ]);
      final peer = await _Peer.start(carol);
      final channel = await _Channel.open([first]);
      final s = await _Subject.create(channel, identity: self, serverOn: first);
      await s.service.syncInterfaces([first]);

      await channel.deliver(
        loopback,
        _hello(_claim(carol.fingerprint, farm.port)),
      );
      await _until(() => farm.openAt(1) == 1);
      for (var i = 0; i < 100; i++) {
        await channel.inject(
          _host(sources[i % sources.length]),
          _hello(_invented(1000 + i, farm.port)),
        );
      }
      await _until(
        () => channel.countFrom({for (final n in sources) '127.0.0.$n'}) >= 100,
      );
      await _settle(() => farm.total);
      final busy = farm.open;
      expect(busy, greaterThan(1));

      final answer = await DeviceVerifier(identity: carol).register(
        address: loopback,
        port: s.server!.boundPort!,
        expectedFingerprint: self.fingerprint,
        self: peer.info,
      );
      expect(answer?.fingerprint, self.fingerprint);
      await _until(() => s.lists(carol.fingerprint));

      final device = s.find(carol.fingerprint)!;
      expect(device.address, loopback);
      expect(device.info.port, peer.port);
      expect(farm.openAt(1), 1);
      expect(farm.open, busy);
      expect(farm.maxOpen, lessThanOrEqualTo(8));
    });

    test('one device that sends many presentations with invented '
        'fingerprints holds at most 1 check in flight and 2 queued, and '
        'another device can still present itself', () async {
      final farm = await _Farm.start([_Endpoint.silent(3)]);
      final peer = await _Peer.start(carol);
      final channel = await _Channel.open([first]);
      final s = await _Subject.create(channel, identity: self);
      await s.service.syncInterfaces([first]);

      for (var i = 0; i < 20; i++) {
        s.service.handleRegistration(
          _invented(2000 + i, farm.port),
          _host(3),
          first,
        );
      }
      await _settle(() => farm.total);
      expect(farm.openAt(3), 1);

      s.service.handleRegistration(peer.info, loopback, first);
      await _until(() => s.lists(carol.fingerprint));

      await farm.drain();
      expect(farm.totalAt(3), lessThanOrEqualTo(3));
      expect(farm.maxOpenAt['127.0.0.3'], 1);
    });

    group('list limit', () {
      late List<DeviceIdentity> crowd;
      late DeviceIdentity newcomer;

      setUpAll(() {
        crowd = [for (var i = 0; i < 65; i++) DeviceIdentity.generate()];
        newcomer = DeviceIdentity.generate();
      });

      test('the list stops at 64 unpaired devices, ignores new ones without '
          'trying them, still admits a paired one, and admits a new one again '
          'once another leaves', () async {
        final farm = await _Farm.start([
          for (var i = 0; i < crowd.length; i++)
            _Endpoint.honest(100 + i, crowd[i]),
          _Endpoint.honest(200, newcomer),
        ]);
        final channel = await _Channel.open([first]);
        var wave = <InternetAddress>[];
        final s = await _Subject.create(
          channel,
          identity: self,
          scanner: (verifier) => SubnetScanner(
            verifier: verifier,
            port: farm.port,
            hostsOf: (_) => wave,
          ),
        );
        await s.paired.replaceAll([pairedDeviceOf(newcomer)]);
        await s.service.syncInterfaces([first]);

        for (var start = 0; start < crowd.length; start += 4) {
          wave = [
            for (var i = start; i < min(start + 4, crowd.length); i++)
              _host(100 + i),
          ];
          await s.service.rescan().timeout(const Duration(seconds: 20));
        }

        expect(farm.total, crowd.length);
        expect(s.service.current, hasLength(Limits.maxListedUnpaired));
        expect(s.unpaired, Limits.maxListedUnpaired);

        final leftOut = [
          for (var i = 0; i < crowd.length; i++)
            if (!s.lists(crowd[i].fingerprint)) 100 + i,
        ].single;
        final tried = farm.total;
        await channel.deliver(_host(leftOut), _hello(farm.infoAt(leftOut)));
        await _quiet();
        expect(farm.total, tried);
        expect(s.service.current, hasLength(Limits.maxListedUnpaired));

        await channel.deliver(_host(200), _hello(farm.infoAt(200)));
        await _until(() => s.lists(newcomer.fingerprint));
        expect(s.find(newcomer.fingerprint)!.paired, isTrue);
        expect(s.service.current, hasLength(Limits.maxListedUnpaired + 1));
        expect(s.unpaired, Limits.maxListedUnpaired);

        final gone = s.service.current.firstWhere((d) => !d.paired);
        await channel.deliver(gone.address, _bye(gone.info));
        await _until(() => !s.lists(gone.info.fingerprint));
        await channel.deliver(_host(leftOut), _hello(farm.infoAt(leftOut)));
        await _until(() => s.lists(farm.infoAt(leftOut).fingerprint));

        expect(s.unpaired, Limits.maxListedUnpaired);
        expect(farm.totalAt(leftOut), 2);
      });
    });
  });

  group('leaving a trusted interface (SEC-06, RF-18)', () {
    test('syncInterfaces([]) cuts the checks in flight within 1 s, empties '
        'the queue, lets no device in afterwards, and a later hello is tried '
        'at once because a cut is not a failure', () async {
      final sources = [for (var n = 2; n <= 11; n++) n];
      final farm = await _Farm.start([
        for (final n in sources) _Endpoint.silent(n),
        _Endpoint.held(12, dave),
      ]);
      final channel = await _Channel.open([first]);
      final s = await _Subject.create(channel, identity: self);
      await s.service.syncInterfaces([first]);

      await channel.deliver(_host(12), _hello(farm.infoAt(12)));
      await farm.requestAt(12);
      for (var i = 0; i < 20; i++) {
        await channel.inject(
          _host(sources[i % sources.length]),
          _hello(_invented(1000 + i, farm.port)),
        );
      }
      await _until(
        () => channel.countFrom({for (final n in sources) '127.0.0.$n'}) >= 20,
      );
      await _settle(() => farm.total);
      final before = farm.total;
      expect(farm.open, greaterThan(1));
      expect(before, lessThan(21));

      await s.service.syncInterfaces([]);
      await farm.allClosed.timeout(_oneSecond);
      farm.endpointAt(12).release();
      await _quiet(const Duration(milliseconds: 500));

      expect(farm.total, before);
      expect(s.service.current, isEmpty);

      await s.service.syncInterfaces([first]);
      await _quiet();
      expect(farm.total, before);

      await channel.deliver(_host(12), _hello(farm.infoAt(12)));
      await _until(() => s.lists(dave.fingerprint));
      expect(farm.totalAt(12), 2);
    });

    test('the devices of an interface that leaves are dropped and its '
        'hellos are ignored afterwards', () async {
      final peer = await _Peer.start(bob);
      final channel = await _Channel.open([first]);
      final s = await _Subject.create(channel, identity: self);
      await s.service.syncInterfaces([first]);
      await channel.deliver(loopback, _hello(peer.info));
      await _until(() => s.lists(bob.fingerprint));

      await s.service.syncInterfaces([]);
      expect(s.service.current, isEmpty);
      expect(s.emitted.last, isEmpty);

      await channel.deliver(loopback, _hello(peer.info));
      await _quiet();
      expect(s.service.current, isEmpty);
      expect(peer.registrations, hasLength(1));
    });

    test('only the checks of the interface that leaves are cut', () async {
      final farm = await _Farm.start([
        _Endpoint.held(12, dave),
        _Endpoint.held(13, erin),
      ]);
      final channel = await _Channel.open([first, second]);
      final s = await _Subject.create(channel, identity: self);
      await s.service.syncInterfaces([first, second]);

      s.service.handleRegistration(farm.infoAt(12), _host(12), first);
      s.service.handleRegistration(farm.infoAt(13), _host(13), second);
      await farm.requestAt(12);
      await farm.requestAt(13);

      await s.service.syncInterfaces([second]);
      await (await farm.linkTo(12)).closed.future.timeout(_oneSecond);
      await _quiet();
      expect((await farm.linkTo(13)).isClosed, isFalse);

      farm.endpointAt(12).release();
      farm.endpointAt(13).release();
      await _until(() => s.lists(erin.fingerprint));
      await _quiet();

      expect(s.find(erin.fingerprint)!.interfaceId, second.id);
      expect(s.lists(dave.fingerprint), isFalse);
    });

    test('a rescan in flight is cut within 1 s when the interface leaves, '
        'ends, and lets nothing in', () async {
      final scanned = [for (var n = 20; n < 60; n++) n];
      final farm = await _Farm.start([
        _Endpoint.held(12, dave),
        for (final n in scanned) _Endpoint.silent(n),
      ]);
      final channel = await _Channel.open([first]);
      final s = await _Subject.create(
        channel,
        identity: self,
        scanner: (verifier) => SubnetScanner(
          verifier: verifier,
          port: farm.port,
          hostsOf: (_) => [_host(12), for (final n in scanned) _host(n)],
        ),
      );
      await s.service.syncInterfaces([first]);

      final scan = s.service.rescan();
      await farm.requestAt(12);
      await _until(() => farm.openIn(scanned) > 0);
      await _settle(() => farm.total);
      final before = farm.total;

      await s.service.syncInterfaces([]);
      await farm.allClosed.timeout(_oneSecond);
      await scan.timeout(_oneSecond);
      farm.endpointAt(12).release();
      await _quiet(const Duration(milliseconds: 500));

      expect(farm.total, before);
      expect(s.service.current, isEmpty);
    });

    test('a rescan in flight is cut when one of two interfaces leaves, so '
        'nothing found through it gets in (v2.10 point 4)', () async {
      final scanned = [for (var n = 20; n < 40; n++) n];
      final farm = await _Farm.start([
        _Endpoint.held(12, dave),
        for (final n in scanned) _Endpoint.silent(n),
      ]);
      final channel = await _Channel.open([first, second]);
      final s = await _Subject.create(
        channel,
        identity: self,
        scanner: (verifier) => SubnetScanner(
          verifier: verifier,
          port: farm.port,
          hostsOf: (iface) => iface.id == second.id
              ? [_host(12), for (final n in scanned) _host(n)]
              : const [],
        ),
      );
      await s.service.syncInterfaces([first, second]);

      final scan = s.service.rescan();
      await farm.requestAt(12);
      await _settle(() => farm.total);

      await s.service.syncInterfaces([first]);
      await farm.allClosed.timeout(_oneSecond);
      await scan.timeout(_oneSecond);
      farm.endpointAt(12).release();
      await _quiet(const Duration(milliseconds: 500));

      expect(s.lists(dave.fingerprint), isFalse);
      expect(s.service.current, isEmpty);
    });
  });

  group('stop (RF-51)', () {
    test('stop in the middle of checks and of a rescan leaves no uncaught '
        'error, cuts every connection within 1 s, ends the rescan, closes '
        'devices and makes later events do nothing', () async {
      final errors = await _uncaughtErrorsOf(() async {
        final sources = [for (var n = 2; n <= 11; n++) n];
        final scanned = [for (var n = 20; n < 60; n++) n];
        final farm = await _Farm.start([
          _Endpoint.held(12, dave),
          for (final n in sources) _Endpoint.silent(n),
          for (final n in scanned) _Endpoint.silent(n),
        ]);
        final peer = await _Peer.start(bob);
        final channel = await _Channel.open([first]);
        final s = await _Subject.create(
          channel,
          identity: self,
          announceInterval: _fast,
          scanner: (verifier) => SubnetScanner(
            verifier: verifier,
            port: farm.port,
            hostsOf: (_) => [for (final n in scanned) _host(n)],
          ),
        );
        await s.service.syncInterfaces([first]);
        await channel.deliver(_host(12), _hello(farm.infoAt(12)));
        await farm.requestAt(12);
        for (var i = 0; i < 20; i++) {
          await channel.inject(
            _host(sources[i % sources.length]),
            _hello(_invented(3000 + i, farm.port)),
          );
        }
        final scan = s.service.rescan();
        await _until(() => farm.openIn(scanned) > 0);
        await _settle(() => farm.total);
        final emissions = s.emitted.length;

        await s.service.stop(sayGoodbye: false);
        await farm.allClosed.timeout(_oneSecond);
        await scan.timeout(_oneSecond);
        farm.endpointAt(12).release();
        await _quiet(const Duration(milliseconds: 100));
        final tried = farm.total;
        final announced = channel.of(self.fingerprint).length;

        s.service.handleRegistration(peer.info, loopback, first);
        s.service.announceNow();
        await channel.deliver(_host(2), _hello(_invented(4000, farm.port)));
        await _quiet(const Duration(milliseconds: 500));

        expect(farm.total, tried);
        expect(peer.registrations, isEmpty);
        expect(channel.of(self.fingerprint), hasLength(announced));
        expect(s.emitted, hasLength(emissions));
        expect(s.done, isTrue);
        expect(s.lists(dave.fingerprint), isFalse);
      });

      expect(errors, isEmpty);
    });

    test('stop is idempotent: called three times it sends one bye per '
        'active interface once, and afterwards neither announceNow nor '
        'syncInterfaces send anything, while the channel stays open', () async {
      final channel = await _Channel.open([first, second]);
      final s = await _Subject.create(channel, identity: self);
      await s.service.syncInterfaces([first, second]);
      await _until(() => channel.of(self.fingerprint).length == 2);
      final before = channel.received.length;

      await Future.wait([
        s.service.stop(sayGoodbye: true),
        s.service.stop(sayGoodbye: true),
      ]);
      await s.service.stop(sayGoodbye: true);
      await _until(
        () =>
            channel
                .of(self.fingerprint, kind: AnnouncementKind.bye, skip: before)
                .length >=
            2,
      );
      s.service.announceNow();
      await s.service.syncInterfaces([first]);
      await _quiet();

      expect(
        channel.of(self.fingerprint, kind: AnnouncementKind.bye, skip: before),
        hasLength(2),
      );
      expect(
        channel.of(
          self.fingerprint,
          kind: AnnouncementKind.hello,
          skip: before,
        ),
        isEmpty,
      );
      expect(s.done, isTrue);
      await channel.deliver(_host(2), _hello(_invented(1, 40000)));
    });

    test('stop(sayGoodbye: false) sends no bye', () async {
      final channel = await _Channel.open([first]);
      final s = await _Subject.create(channel, identity: self);
      await s.service.syncInterfaces([first]);
      await _until(() => channel.of(self.fingerprint).length == 1);

      await s.service.stop(sayGoodbye: false);
      await _quiet();

      expect(channel.of(self.fingerprint, kind: AnnouncementKind.bye), isEmpty);
      expect(s.done, isTrue);
    });
  });

  group('paired label', () {
    test('paired.changes makes devices emit again with the new label, both '
        'ways', () async {
      final peer = await _Peer.start(bob);
      final channel = await _Channel.open([first]);
      final s = await _Subject.create(channel, identity: self);
      await s.service.syncInterfaces([first]);
      await channel.deliver(loopback, _hello(peer.info));
      await _until(() => s.lists(bob.fingerprint));
      expect(s.emitted.last.single.paired, isFalse);
      final emissions = s.emitted.length;

      await s.paired.replaceAll([pairedDeviceOf(bob)]);
      await _until(() => s.emitted.length > emissions);
      expect(s.emitted.last.single.paired, isTrue);
      expect(s.find(bob.fingerprint)!.paired, isTrue);

      await s.paired.replaceAll([]);
      await _until(() => s.emitted.length > emissions + 1);
      expect(s.emitted.last.single.paired, isFalse);
      await _quiet();
      expect(s.emitted, hasLength(emissions + 2));
    });
  });

  group('answering the hello of a listed device (v2.11 point 1, RF-45)', () {
    Future<(_Subject, _Peer, _Neighbour)> listedAt2({_Clock? clock}) async {
      final peer = await _Peer.start(bob, address: '127.0.0.2');
      final channel = await _Channel.open([first]);
      final s = await _Subject.create(channel, identity: self, clock: clock);
      await s.service.syncInterfaces([first]);
      await _until(() => channel.of(self.fingerprint).length == 1);
      final neighbour = await _Neighbour.bind(channel, _host(2));
      await neighbour.say(_hello(peer.info));
      await _until(() => s.lists(bob.fingerprint));
      await _quiet();
      return (s, peer, neighbour);
    }

    test('the answer interval is half the announce interval, 5 s', () {
      expect(Limits.announceInterval ~/ 2, const Duration(seconds: 5));
    });

    test('with the real 10 s interval, a service that pauses its interface '
        'and brings it back sees the other again within 1 s, because the '
        'other answers its hello at once', () async {
      final clock = _Clock();
      final channel = await _Channel.open([first]);
      final a = await _Subject.create(
        channel,
        identity: alice,
        clock: clock,
        announceInterval: Limits.announceInterval,
        serverOn: first,
      );
      final b = await _Subject.create(
        channel,
        identity: bob,
        clock: clock,
        announceInterval: Limits.announceInterval,
        serverOn: first,
      );
      await a.service.syncInterfaces([first]);
      await b.service.syncInterfaces([first]);
      await _until(
        () => a.lists(bob.fingerprint) && b.lists(alice.fingerprint),
      );
      await _settle(() => a.registered + b.registered, quiet: _silence);

      await a.service.syncInterfaces([]);
      expect(a.service.current, isEmpty);
      expect(b.lists(alice.fingerprint), isTrue);
      final before = channel.received.length;
      final watch = Stopwatch()..start();

      await a.service.syncInterfaces([first]);
      await _until(() => a.lists(bob.fingerprint), limit: _oneSecond);

      expect(watch.elapsed, lessThan(_oneSecond));
      await _quiet();
      expect(
        channel.of(bob.fingerprint, kind: AnnouncementKind.hello, skip: before),
        hasLength(1),
      );
      expect(a.find(bob.fingerprint)!.address, loopback);
      expect(a.find(bob.fingerprint)!.info.toJson(), b.selfInfo().toJson());
      expect(b.lists(alice.fingerprint), isTrue);
    });

    test('the answer is one hello with selfInfo sent only to the IP that '
        'announced, not to the group, and the first hello of a device that '
        'was not listed gets a check instead of an answer', () async {
      final (s, peer, neighbour) = await listedAt2();
      expect(neighbour.answersFrom(self.fingerprint), isEmpty);
      expect(peer.registrations, hasLength(1));
      final own = neighbour.channel.of(self.fingerprint).length;

      await neighbour.say(_hello(peer.info));
      await _until(
        () => neighbour.answersFrom(self.fingerprint).isNotEmpty,
        limit: _oneSecond,
      );
      await _quiet();

      final answers = neighbour.answersFrom(self.fingerprint);
      expect(answers, hasLength(1));
      expect(answers.single.kind, AnnouncementKind.hello);
      expect(answers.single.encode(), _hello(s.selfInfo()).encode());
      expect(neighbour.channel.of(self.fingerprint), hasLength(own));
      expect(peer.registrations, hasLength(1));
      expect(s.find(bob.fingerprint)!.address, _host(2));
    });

    test('with the injected clock, two hellos 1 s apart get one answer, a '
        'third at 4.999 s gets none, and one at 5 s gets another', () async {
      final clock = _Clock();
      final (s, peer, neighbour) = await listedAt2(clock: clock);

      await neighbour.say(_hello(peer.info));
      await _until(
        () => neighbour.answersFrom(self.fingerprint).length == 1,
        limit: _oneSecond,
      );

      clock.advance(_oneSecond);
      await neighbour.say(_hello(peer.info));
      await _quiet();
      expect(neighbour.answersFrom(self.fingerprint), hasLength(1));

      clock.advance(const Duration(seconds: 3, milliseconds: 999));
      await neighbour.say(_hello(peer.info));
      await _quiet();
      expect(neighbour.answersFrom(self.fingerprint), hasLength(1));

      clock.advance(const Duration(milliseconds: 1));
      await neighbour.say(_hello(peer.info));
      await _until(
        () => neighbour.answersFrom(self.fingerprint).length == 2,
        limit: _oneSecond,
      );
      await _quiet();
      expect(neighbour.answersFrom(self.fingerprint), hasLength(2));
      expect(s.lists(bob.fingerprint), isTrue);
      expect(peer.registrations, hasLength(1));
    });

    test('the limit counts per fingerprint: another listed device at another '
        'IP gets its own answer right after', () async {
      final clock = _Clock();
      final (s, peer, neighbour) = await listedAt2(clock: clock);
      final other = await _Peer.start(carol, address: '127.0.0.3');
      final third = await _Neighbour.bind(neighbour.channel, _host(3));
      await third.say(_hello(other.info));
      await _until(() => s.lists(carol.fingerprint));
      await _quiet();
      expect(third.answersFrom(self.fingerprint), isEmpty);

      await neighbour.say(_hello(peer.info));
      await _until(
        () => neighbour.answersFrom(self.fingerprint).length == 1,
        limit: _oneSecond,
      );
      await third.say(_hello(other.info));
      await _until(
        () => third.answersFrom(self.fingerprint).length == 1,
        limit: _oneSecond,
      );
      await _quiet();

      expect(neighbour.answersFrom(self.fingerprint), hasLength(1));
      expect(third.answersFrom(self.fingerprint), hasLength(1));
    });

    test('a bye from the listed device gets no answer', () async {
      final (s, peer, neighbour) = await listedAt2();

      await neighbour.say(_bye(peer.info));
      await _until(() => !s.lists(bob.fingerprint), limit: _oneSecond);
      await _quiet();

      expect(neighbour.answersFrom(self.fingerprint), isEmpty);
    });

    test('a presentation of the listed device through handleRegistration '
        'gets no answer and no new check', () async {
      final (s, peer, neighbour) = await listedAt2();

      s.service.handleRegistration(peer.info, _host(2), first);
      await _quiet();

      expect(neighbour.answersFrom(self.fingerprint), isEmpty);
      expect(peer.registrations, hasLength(1));
      expect(s.lists(bob.fingerprint), isTrue);
    });

    test('after stop a hello of the listed device gets no answer', () async {
      final (s, peer, neighbour) = await listedAt2();

      await s.service.stop(sayGoodbye: false);
      await neighbour.say(_hello(peer.info));
      await _quiet();

      expect(neighbour.answersFrom(self.fingerprint), isEmpty);
      expect(peer.registrations, hasLength(1));
    });

    test('a hello through an interface that is no longer active gets no '
        'answer and no check', () async {
      final (s, peer, neighbour) = await listedAt2();

      await s.service.syncInterfaces([]);
      await neighbour.say(_hello(peer.info));
      await _quiet();

      expect(neighbour.answersFrom(self.fingerprint), isEmpty);
      expect(peer.registrations, hasLength(1));
      expect(s.service.current, isEmpty);
    });
  });

  group('an interface that changes its mask (v2.11 point 7)', () {
    ActiveInterface masked(int prefixLength) => ActiveInterface(
      id: 'loopback#mask',
      adapterId: 'loopback',
      friendlyName: _loopbackName,
      subnet: Ipv4Subnet(_host(21), prefixLength),
    );

    test('the same interface id with another mask sends no new hello, keeps '
        'its devices, and the next rescan tries the hosts of the new '
        'subnet', () async {
      final wide = masked(24);
      final narrow = masked(29);
      final knocks = await _Knocks.start([
        for (var n = 1; n <= 254; n++) _host(n),
      ]);
      final peer = await _Peer.start(bob, address: '127.0.0.18');
      final channel = await _Channel.open([wide]);
      final s = await _Subject.create(
        channel,
        identity: self,
        scanner: (verifier) =>
            SubnetScanner(verifier: verifier, port: knocks.port),
      );
      await s.service.syncInterfaces([wide]);
      await _until(() => channel.of(self.fingerprint).length == 1);
      await channel.deliver(_host(18), _hello(peer.info));
      await _until(() => s.lists(bob.fingerprint));

      await s.service.rescan().timeout(const Duration(seconds: 20));
      expect(knocks.hits, hasLength(253));
      expect(knocks.hits.keys, isNot(contains('127.0.0.21')));
      knocks.hits.clear();
      final emissions = s.emitted.length;

      await s.service.syncInterfaces([narrow]);
      await _quiet();

      expect(channel.of(self.fingerprint), hasLength(1));
      expect(s.find(bob.fingerprint)?.interfaceId, wide.id);
      expect(s.emitted, hasLength(emissions));

      await s.service.rescan().timeout(scaled(_limit));

      expect(
        knocks.hits.keys,
        unorderedEquals([
          for (var n = 16; n <= 23; n++)
            if (n != 21) '127.0.0.$n',
        ]),
      );
      expect(knocks.hits.values, everyElement(1));
      expect(s.lists(bob.fingerprint), isTrue);
    });
  });
  group('E805: a forged hello cannot rename a known device (RF-507, S11, '
      'clarify point 5)', () {
    test('a forged hello with the fingerprint and address of a known device '
        'and another name makes one check against the real device, which '
        'answers with its own name, and the name does not change', () async {
      final peer = await _Peer.start(bob, address: '127.0.0.2', name: 'Laptop');
      final channel = await _Channel.open([first]);
      final s = await _Subject.create(channel, identity: self);
      await s.service.syncInterfaces([first]);
      await channel.deliver(_host(2), _hello(peer.info));
      await _until(() => s.lists(bob.fingerprint));
      expect(peer.registrations, hasLength(1));
      final emissions = s.emitted.length;

      await channel.deliver(
        _host(2),
        _hello(_claim(bob.fingerprint, peer.port, name: 'Forged')),
      );
      await _until(() => peer.registrations.length == 2);
      await _quiet();

      expect(peer.registrations, hasLength(2));
      expect(s.find(bob.fingerprint)!.info.name, 'Laptop');
      expect(s.find(bob.fingerprint)!.info.toJson(), peer.info.toJson());
      expect([
        for (final list in s.emitted.skip(emissions))
          for (final device in list) device.info.name,
      ], isNot(contains('Forged')));
    });

    test('a forged hello with another name and a false port is checked '
        'against the known port: the false port gets no connection', () async {
      final peer = await _Peer.start(bob, address: '127.0.0.2', name: 'Laptop');
      final knocks = await _Knocks.start([_host(2)]);
      final channel = await _Channel.open([first]);
      final s = await _Subject.create(channel, identity: self);
      await s.service.syncInterfaces([first]);
      await channel.deliver(_host(2), _hello(peer.info));
      await _until(() => s.lists(bob.fingerprint));

      await channel.deliver(
        _host(2),
        _hello(_claim(bob.fingerprint, knocks.port, name: 'Forged')),
      );
      await _until(() => peer.registrations.length == 2);
      await _quiet();

      expect(knocks.hits, isEmpty);
      expect(s.find(bob.fingerprint)!.info.toJson(), peer.info.toJson());
    });

    test('20 forged hellos with other names in less than 5 s make a single '
        'check', () async {
      final peer = await _Peer.start(bob, address: '127.0.0.2', name: 'Laptop');
      final channel = await _Channel.open([first]);
      final s = await _Subject.create(channel, identity: self);
      await s.service.syncInterfaces([first]);
      await channel.deliver(_host(2), _hello(peer.info));
      await _until(() => s.lists(bob.fingerprint));
      final watch = Stopwatch()..start();

      for (var i = 0; i < 20; i++) {
        await channel.deliver(
          _host(2),
          _hello(_claim(bob.fingerprint, peer.port, name: 'Forged $i')),
        );
        await Future<void>.delayed(const Duration(milliseconds: 150));
      }
      await _quiet();

      expect(watch.elapsed, lessThan(Limits.renameCheckInterval));
      expect(peer.registrations, hasLength(2));
      expect(s.find(bob.fingerprint)!.info.name, 'Laptop');
    });

    test('forged registers with another name from a known device also make a '
        'single check and keep the name', () async {
      final peer = await _Peer.start(bob, address: '127.0.0.2', name: 'Laptop');
      final channel = await _Channel.open([first]);
      final s = await _Subject.create(channel, identity: self);
      await s.service.syncInterfaces([first]);
      await channel.deliver(_host(2), _hello(peer.info));
      await _until(() => s.lists(bob.fingerprint));

      for (var i = 0; i < 5; i++) {
        s.service.handleRegistration(
          _claim(bob.fingerprint, peer.port, name: 'Forged $i'),
          _host(2),
          first,
        );
      }
      await _until(() => peer.registrations.length == 2);
      await _quiet();

      expect(peer.registrations, hasLength(2));
      expect(s.find(bob.fingerprint)!.info.name, 'Laptop');
    });

    test('a real new name arrives after its check, and a second one 5 s later '
        'also through a register', () async {
      final peer = await _RenamablePeer.start(
        bob,
        address: '127.0.0.2',
        name: 'Laptop',
      );
      final channel = await _Channel.open([first]);
      final s = await _Subject.create(channel, identity: self);
      await s.service.syncInterfaces([first]);
      await channel.deliver(_host(2), _hello(peer.info));
      await _until(() => s.lists(bob.fingerprint));

      peer.name = 'Laptop Renamed';
      final watch = Stopwatch()..start();
      await channel.deliver(_host(2), _hello(peer.info));
      await _until(
        () => s.find(bob.fingerprint)?.info.name == 'Laptop Renamed',
      );
      expect(watch.elapsed, lessThan(const Duration(seconds: 5)));

      await Future<void>.delayed(Limits.renameCheckInterval);
      peer.name = 'Laptop Again';
      s.service.handleRegistration(peer.info, _host(2), first);
      await _until(() => s.find(bob.fingerprint)?.info.name == 'Laptop Again');
      expect(peer.registrations, hasLength(3));
    });

    test('a rename check that fails leaves the entry as it was and does not '
        'cool a paired device down: its goodbye is checked at once without '
        'waiting 9 s', () async {
      final clock = _Clock();
      final peer = await _Peer.start(bob, address: '127.0.0.2', name: 'Laptop');
      final channel = await _Channel.open([first]);
      final s = await _Subject.create(channel, identity: self, clock: clock);
      await s.paired.replaceAll([pairedDeviceOf(bob)]);
      await s.service.syncInterfaces([first]);
      await channel.deliver(_host(2), _hello(peer.info));
      await _until(() => s.lists(bob.fingerprint));
      final info = peer.info;
      final before = s.find(bob.fingerprint)!;
      final emissions = s.emitted.length;
      await peer.server.close();
      final dropping = await ServerSocket.bind(_host(2), info.port);
      addTearDown(dropping.close);
      var dropped = 0;
      dropping.listen((socket) {
        dropped++;
        socket.destroy();
      });

      await channel.deliver(
        _host(2),
        _hello(_claim(bob.fingerprint, info.port, name: 'Forged')),
      );
      await _until(() => dropped == 1);
      await _quiet();

      final after = s.find(bob.fingerprint)!;
      expect(after.info.toJson(), before.info.toJson());
      expect(after.address, before.address);
      expect(after.interfaceId, before.interfaceId);
      expect(s.emitted, hasLength(emissions));

      await channel.deliver(_host(2), _bye(info));
      await _until(() => dropped == 2, limit: _oneSecond);
      await _until(() => !s.lists(bob.fingerprint), limit: _oneSecond);
    });

    test(
      'a rename check that fails does not cool an unpaired device down '
      'either: after its bye, its hello from a new port is listed at once',
      () async {
        final clock = _Clock();
        final peer = await _Peer.start(
          carol,
          address: '127.0.0.2',
          name: 'Desk',
        );
        final channel = await _Channel.open([first]);
        final s = await _Subject.create(channel, identity: self, clock: clock);
        await s.service.syncInterfaces([first]);
        await channel.deliver(_host(2), _hello(peer.info));
        await _until(() => s.lists(carol.fingerprint));
        final info = peer.info;
        await peer.server.close();
        final dropping = await ServerSocket.bind(_host(2), info.port);
        addTearDown(dropping.close);
        var dropped = 0;
        dropping.listen((socket) {
          dropped++;
          socket.destroy();
        });

        await channel.deliver(
          _host(2),
          _hello(_claim(carol.fingerprint, info.port, name: 'Forged')),
        );
        await _until(() => dropped == 1);
        await _quiet();
        expect(s.find(carol.fingerprint)!.info.name, 'Desk');
        await channel.deliver(_host(2), _bye(info));
        await _until(() => !s.lists(carol.fingerprint), limit: _oneSecond);

        final back = await _Peer.start(
          carol,
          address: '127.0.0.2',
          name: 'Desk',
        );
        await channel.deliver(_host(2), _hello(back.info));

        await _until(
          () => s.find(carol.fingerprint)?.info.port == back.port,
          limit: const Duration(seconds: 2),
        );
        expect(back.registrations, hasLength(1));
      },
    );
  });

  group('presentNow (S11 point 6, RF-507)', () {
    test(
      'presents itself at once to every listed device, also one that only '
      'presented itself and never sent a hello, with the current selfInfo',
      () async {
        final peer = await _Peer.start(
          bob,
          address: '127.0.0.2',
          name: 'Laptop',
        );
        final other = await _Peer.start(
          carol,
          address: '127.0.0.3',
          name: 'Desk',
        );
        final channel = await _Channel.open([first]);
        final s = await _Subject.create(channel, identity: self);
        await s.service.syncInterfaces([first]);
        await channel.deliver(_host(2), _hello(peer.info));
        s.service.handleRegistration(other.info, _host(3), first);
        await _until(
          () => s.lists(bob.fingerprint) && s.lists(carol.fingerprint),
        );
        expect(peer.registrations, hasLength(1));
        expect(other.registrations, hasLength(1));

        s.service.presentNow();
        await _until(
          () =>
              peer.registrations.length == 2 && other.registrations.length == 2,
        );

        expect(peer.registrations.last.$1.toJson(), s.selfInfo().toJson());
        expect(other.registrations.last.$1.toJson(), s.selfInfo().toJson());
        expect(s.lists(bob.fingerprint), isTrue);
        expect(s.lists(carol.fingerprint), isTrue);
      },
    );

    test('does nothing without devices, nor after stop', () async {
      final peer = await _Peer.start(bob, address: '127.0.0.2', name: 'Laptop');
      final channel = await _Channel.open([first]);
      final s = await _Subject.create(channel, identity: self);
      await s.service.syncInterfaces([first]);

      s.service.presentNow();
      await _quiet();
      expect(peer.registrations, isEmpty);

      await channel.deliver(_host(2), _hello(peer.info));
      await _until(() => s.lists(bob.fingerprint));
      await s.service.stop(sayGoodbye: false);
      s.service.presentNow();
      await _quiet();
      expect(peer.registrations, hasLength(1));
    });
  });

  group('E840: leaving one interface cuts only its part of a rescan (RF-534, '
      'S5) [SEG]', () {
    test('with two interfaces and many slow hosts, leaving one mid-scan '
        'probes nothing more through it, cuts its probe in flight and the '
        'search goes on and finds the device of the other', () async {
      final leaving = [for (var n = 20; n < 70; n++) n];
      final staying = [for (var n = 70; n < 80; n++) n];
      final farm = await _Farm.start([
        _Endpoint.held(12, dave),
        for (final n in leaving) _Endpoint.silent(n),
        for (final n in staying) _Endpoint.silent(n),
        _Endpoint.honest(80, bob),
      ]);
      final channel = await _Channel.open([first, second]);
      final asked = <String>[];
      final s = await _Subject.create(
        channel,
        identity: self,
        scanner: (verifier) => SubnetScanner(
          verifier: verifier,
          port: farm.port,
          hostsOf: (iface) {
            asked.add(iface.id);
            return iface.id == second.id
                ? [_host(12), for (final n in leaving) _host(n)]
                : [for (final n in staying) _host(n), _host(80)];
          },
        ),
      );
      await s.service.syncInterfaces([second, first]);

      final scan = s.service.rescan();
      await farm.requestAt(12);
      final probedBefore =
          farm.totalAt(12) + leaving.fold(0, (sum, n) => sum + farm.totalAt(n));
      expect(probedBefore, lessThan(leaving.length + 1));

      await s.service.syncInterfaces([first]);
      await (farm.linkTo(12).then((l) => l.closed.future)).timeout(_oneSecond);
      await scan.timeout(scaled(const Duration(seconds: 10)));
      farm.endpointAt(12).release();
      await _quiet(const Duration(milliseconds: 500));

      final probedAfter =
          farm.totalAt(12) + leaving.fold(0, (sum, n) => sum + farm.totalAt(n));
      expect(probedAfter, probedBefore, reason: 'no new probe through it');
      expect(farm.openIn([12, ...leaving]), 0);
      expect(s.lists(dave.fingerprint), isFalse);
      expect(s.lists(bob.fingerprint), isTrue);
      expect(s.find(bob.fingerprint)!.interfaceId, first.id);
      expect(farm.totalAt(80), 1);
      expect(asked.toSet(), {first.id, second.id});
    });

    test('control: stopping the whole service still ends the scan at once '
        'and finds nothing', () async {
      final farm = await _Farm.start([
        _Endpoint.held(12, dave),
        for (var n = 20; n < 40; n++) _Endpoint.silent(n),
        _Endpoint.honest(80, bob),
      ]);
      final channel = await _Channel.open([first, second]);
      final s = await _Subject.create(
        channel,
        identity: self,
        scanner: (verifier) => SubnetScanner(
          verifier: verifier,
          port: farm.port,
          hostsOf: (iface) => iface.id == second.id
              ? [_host(12), for (var n = 20; n < 40; n++) _host(n)]
              : [_host(80)],
        ),
      );
      await s.service.syncInterfaces([second, first]);

      final scan = s.service.rescan();
      await farm.requestAt(12);
      await s.service.stop(sayGoodbye: false);

      await scan.timeout(_oneSecond);
      await farm.allClosed.timeout(_oneSecond);
      farm.endpointAt(12).release();
      expect(s.lists(dave.fingerprint), isFalse);
    });
  });

  group('sayGoodbye (S5, RF-534)', () {
    test('one bye goes out through each named interface that is still '
        'active, carrying selfInfo; an unknown id sends nothing', () async {
      final channel = await _Channel.open([first, second]);
      final s = await _Subject.create(channel, identity: self);
      await s.service.syncInterfaces([first, second]);
      await _quiet();
      final before = channel.received.length;

      s.service.sayGoodbye({second.id, 'unknown#127.0.0.9'});
      await _until(
        () => channel
            .of(self.fingerprint, kind: AnnouncementKind.bye, skip: before)
            .isNotEmpty,
      );
      await _quiet();

      final byes = channel.of(
        self.fingerprint,
        kind: AnnouncementKind.bye,
        skip: before,
      );
      expect(byes, hasLength(1));
      expect(byes.single.$1.info.toJson(), s.selfInfo().toJson());

      final again = channel.received.length;
      s.service.sayGoodbye({first.id, second.id});
      await _until(
        () =>
            channel
                .of(self.fingerprint, kind: AnnouncementKind.bye, skip: again)
                .length >=
            2,
      );
      await _quiet();
      expect(
        channel.of(self.fingerprint, kind: AnnouncementKind.bye, skip: again),
        hasLength(2),
      );
      expect(s.service.current, isEmpty);
    });

    test('after stop it sends nothing', () async {
      final channel = await _Channel.open([first]);
      final s = await _Subject.create(channel, identity: self);
      await s.service.syncInterfaces([first]);
      await s.service.stop(sayGoodbye: false);
      await _quiet();
      final before = channel.received.length;

      s.service.sayGoodbye({first.id});
      await _quiet();

      expect(
        channel.of(self.fingerprint, kind: AnnouncementKind.bye, skip: before),
        isEmpty,
      );
    });
  });
}
