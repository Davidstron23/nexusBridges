import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:basic_utils/basic_utils.dart';
import 'package:crypto/crypto.dart';
import 'package:nexus_bridges_core/src/identity/certificate_builder.dart';
import 'package:nexus_bridges_core/src/identity/identity.dart';
import 'package:nexus_bridges_core/src/network/network.dart';
import 'package:nexus_bridges_core/src/pairing/pairing.dart';
import 'package:nexus_bridges_core/src/protocol/protocol.dart';
import 'package:nexus_bridges_core/src/server/server.dart';
import 'package:test/test.dart';

import 'api_server_harness.dart';

const Duration _cutLimit = Duration(seconds: 1);
const Duration _settle = Duration(milliseconds: 300);

final class _ExclusiveLock {
  _ExclusiveLock(File file) : _handle = file.openSync(mode: FileMode.append) {
    _handle.lockSync(FileLock.exclusive);
  }

  final RandomAccessFile _handle;
  bool _held = true;

  void release() {
    if (!_held) return;
    _held = false;
    _handle.unlockSync();
    _handle.closeSync();
  }
}

int _listenings(ServerHarness harness) =>
    harness.logs.where((l) => l.startsWith('listening on')).length;

List<int> _post(String path) => httpRequest('POST', path, body: jsonBody({}));

void main() {
  late DeviceIdentity alice;
  late DeviceIdentity bob;
  late DeviceIdentity carol;
  late DeviceIdentity dave;

  setUpAll(() {
    alice = DeviceIdentity.generate();
    bob = DeviceIdentity.generate();
    carol = DeviceIdentity.generate();
    dave = DeviceIdentity.generate();
  });

  Future<ServerHarness> start(
    List<RouteProbe> probes, {
    Iterable<DeviceIdentity> pairedWith = const [],
    List<ActiveInterface>? active,
    int port = 0,
  }) => ServerHarness.start(
    identity: alice,
    pairedWith: pairedWith,
    active: active,
    port: port,
    routes: [for (final p in probes) p.route],
  );

  Future<TlsClient> open(
    ServerHarness harness, {
    DeviceIdentity? as,
    InternetAddress? to,
  }) => TlsClient.connect(
    harness.port,
    serverFingerprint: alice.fingerprint,
    context: as == null ? null : presenting(as),
    to: to,
  );

  Future<Duration> timeToClose(TlsClient client) async {
    final stopwatch = Stopwatch()..start();
    await client.closed.timeout(waitLimit);
    return stopwatch.elapsed;
  }

  RouteProbe unpairProbe() =>
      RouteProbe(ApiPaths.unpair, access: RouteAccess.paired);

  group('C28: a new paired device enters without a restart (RF-95)', () {
    test('after add and rebuildTrust its request reaches the handler, on the '
        'same port and without reopening the listener', () async {
      final probe = unpairProbe();
      final harness = await start([probe], pairedWith: [carol]);
      final port = harness.port;
      final ids = harness.server.openInterfaceIds;

      final before = await harness.send(
        _post(ApiPaths.unpair),
        context: presenting(bob),
      );
      final added = await harness.paired.add(pairedDeviceOf(bob));
      final beforeRebuild = await harness.send(
        _post(ApiPaths.unpair),
        context: presenting(bob),
      );
      await harness.server.rebuildTrust();
      final after = await harness.send(
        _post(ApiPaths.unpair),
        context: presenting(bob),
      );

      expect(before, isNull);
      expect(added, AddResult.added);
      expect(beforeRebuild, isNull);
      expect(after!.status, 200);
      expect(probe.count, 1);
      expect(probe.calls.single.clientFingerprint, bob.fingerprint);
      expect(harness.server.boundPort, port);
      expect(harness.server.openInterfaceIds, ids);
      expect(_listenings(harness), 1);
    });

    test('the devices already paired keep entering after it', () async {
      final probe = unpairProbe();
      final harness = await start([probe], pairedWith: [carol]);

      await harness.paired.add(pairedDeviceOf(bob));
      await harness.server.rebuildTrust();
      final fromCarol = await harness.send(
        _post(ApiPaths.unpair),
        context: presenting(carol),
      );

      expect(fromCarol!.status, 200);
      expect(probe.calls.single.clientFingerprint, carol.fingerprint);
    });

    test('with two listeners on the same port, the new context reaches both '
        'and neither is reopened', () async {
      final second = InternetAddress('127.0.0.2');
      final port = await freePortOn([loopback, second]);
      final probe = unpairProbe();
      final harness = await start(
        [probe],
        active: [
          loopbackInterface(),
          loopbackInterface(adapterId: 'second', address: '127.0.0.2'),
        ],
        port: port,
      );
      expect(harness.server.openInterfaceIds, hasLength(2));

      await harness.paired.add(pairedDeviceOf(bob));
      await harness.server.rebuildTrust();
      final replies = [
        for (final to in [loopback, second])
          await sendOrCut(
            port,
            _post(ApiPaths.unpair),
            serverFingerprint: alice.fingerprint,
            context: presenting(bob),
            to: to,
          ),
      ];

      expect([for (final r in replies) r?.status], [200, 200]);
      expect(
        {for (final c in probe.calls) c.via.subnet.address.address},
        {'127.0.0.1', '127.0.0.2'},
      );
      expect(_listenings(harness), 2);

      await harness.paired.remove(bob.fingerprint);
      await harness.server.rebuildTrust();
      final cut = [
        for (final to in [loopback, second])
          await sendOrCut(
            port,
            _post(ApiPaths.unpair),
            serverFingerprint: alice.fingerprint,
            context: presenting(bob),
            to: to,
          ),
      ];

      expect(cut, [null, null]);
      expect(probe.count, 2);
      expect(_listenings(harness), 2);
      expect(harness.server.boundPort, port);
    });

    test('a device with the subject of a paired one and another key cannot '
        'be stored, and it is cut in the handshake while the paired one '
        'reaches the route (RF-93)', () async {
      final earlier = DeviceIdentity.generate();
      final pair = CryptoUtils.generateEcKeyPair();
      final laterKey = pair.privateKey as ECPrivateKey;
      final laterPublic = pair.publicKey as ECPublicKey;
      final laterPem = buildSelfSignedCertificatePem(
        privateKey: laterKey,
        publicKey: laterPublic,
        commonName: earlier.certificate.commonName,
        serialNumber: Uint8List.fromList(List<int>.generate(16, (i) => i + 1)),
      );
      final later = PairedDevice(
        fingerprint: sha256
            .convert(spkiOf(laterPublic))
            .toString()
            .toUpperCase(),
        name: 'later',
        certificatePem: laterPem,
        relation: PeerRelation.mine,
        pairedAt: DateTime.utc(2026, 10, 23),
      );
      final probe = unpairProbe();
      final harness = await start([probe]);

      await expectLater(
        harness.paired.replaceAll([pairedDeviceOf(earlier), later]),
        throwsArgumentError,
      );
      await harness.paired.replaceAll([pairedDeviceOf(earlier)]);
      await harness.server.rebuildTrust();
      final fromEarlier = await harness.send(
        _post(ApiPaths.unpair),
        context: presenting(earlier),
      );
      final fromLater = await harness.send(
        _post(ApiPaths.unpair),
        context: SecurityContext(withTrustedRoots: false)
          ..useCertificateChainBytes(utf8.encode(laterPem))
          ..usePrivateKeyBytes(
            utf8.encode(CryptoUtils.encodeEcPrivateKeyToPem(laterKey)),
          ),
      );

      expect(fromEarlier?.status, 200);
      expect(fromLater, isNull);
      expect(
        {for (final c in probe.calls) c.clientFingerprint},
        {earlier.fingerprint},
      );
    });
  });

  group('C29: what is going on is not cut (RF-96)', () {
    test('a held pair/wait ends with its normal reply while others are '
        'added and removed', () async {
      final wait = RouteProbe(ApiPaths.pairWait)..gate = Completer<void>();
      final harness = await start([wait], pairedWith: [dave]);
      final client = await open(harness);
      client.write(_post(ApiPaths.pairWait));
      await wait.arrived(1);

      await harness.paired.add(pairedDeviceOf(carol));
      await harness.server.rebuildTrust();
      await harness.paired.remove(dave.fingerprint);
      await harness.server.rebuildTrust();
      await Future<void>.delayed(_settle);
      final closedWhileHeld = client.isClosed;
      wait.gate!.complete();
      final reply = await client.reply();

      expect(closedWhileHeld, isFalse);
      expect(reply!.status, 200);
      expect(reply.json, {'path': ApiPaths.pairWait, 'call': 1});
      expect(wait.answered, 1);
      expect(_listenings(harness), 1);
    });

    test('an anonymous connection with the handshake done and no request '
        'yet survives the changes and is served after them', () async {
      final start0 = RouteProbe(ApiPaths.pairStart);
      final harness = await start([start0], pairedWith: [dave]);
      final client = await open(harness);
      await Future<void>.delayed(_settle);

      await harness.paired.add(pairedDeviceOf(carol));
      await harness.server.rebuildTrust();
      await harness.paired.remove(dave.fingerprint);
      await harness.server.rebuildTrust();
      await Future<void>.delayed(_settle);
      final closedBeforeRequest = client.isClosed;
      client.write(_post(ApiPaths.pairStart));
      final reply = await client.reply();

      expect(closedBeforeRequest, isFalse);
      expect(reply!.status, 200);
      expect(start0.count, 1);
    });

    test('a held request of a device that stays paired is not cut when '
        'another one is removed', () async {
      final probe = unpairProbe()..gate = Completer<void>();
      final harness = await start([probe], pairedWith: [bob, dave]);
      final client = await open(harness, as: bob);
      client.write(_post(ApiPaths.unpair));
      await probe.arrived(1);

      await harness.paired.remove(dave.fingerprint);
      await harness.server.rebuildTrust();
      await Future<void>.delayed(_settle);
      final closedWhileHeld = client.isClosed;
      probe.gate!.complete();
      final reply = await client.reply();

      expect(closedWhileHeld, isFalse);
      expect(reply!.status, 200);
      expect(probe.calls.single.clientFingerprint, bob.fingerprint);
    });

    test('rebuildTrust with nothing changed cuts nothing', () async {
      final probe = unpairProbe();
      final harness = await start([probe], pairedWith: [bob]);
      final paired = await open(harness, as: bob);
      final anonymous = await open(harness);
      await Future<void>.delayed(_settle);

      await harness.server.rebuildTrust();
      await harness.server.rebuildTrust();
      await Future<void>.delayed(_settle);

      expect(paired.isClosed, isFalse);
      expect(anonymous.isClosed, isFalse);
      paired.write(_post(ApiPaths.unpair));
      expect((await paired.reply())!.status, 200);
    });
  });

  group('C30: selective cut (RF-113)', () {
    test('B and C with a full handshake and no request; remove(B): B is cut '
        'in less than 1 s, C stays open and is served, and a new connection '
        'of B is cut in the handshake', () async {
      final probe = unpairProbe();
      final harness = await start([probe], pairedWith: [bob, carol]);
      final fromBob = await open(harness, as: bob);
      final fromCarol = await open(harness, as: carol);
      final anonymous = await open(harness);
      await Future<void>.delayed(_settle);
      expect(fromBob.isClosed, isFalse);
      expect(fromCarol.isClosed, isFalse);

      final removing = harness.paired.remove(bob.fingerprint);
      addTearDown(() => removing);
      final cutting = timeToClose(fromBob);
      await harness.server.rebuildTrust();
      final elapsed = await cutting;
      await Future<void>.delayed(_settle);

      expect(elapsed, lessThan(_cutLimit));
      expect(Reply.parse(fromBob.received), isNull);
      expect(fromCarol.isClosed, isFalse);
      expect(anonymous.isClosed, isFalse);

      fromCarol.write(_post(ApiPaths.unpair));
      final carolReply = await fromCarol.reply();
      final again = await harness.send(
        _post(ApiPaths.unpair),
        context: presenting(bob),
      );

      expect(carolReply!.status, 200);
      expect(again, isNull);
      expect(
        [for (final c in probe.calls) c.clientFingerprint],
        [carol.fingerprint],
      );
      expect(_listenings(harness), 1);
    });

    test('a removed device with a held request is cut in less than 1 s, gets '
        'no reply, and the server goes on', () async {
      final probe = unpairProbe()..gate = Completer<void>();
      final harness = await start([probe], pairedWith: [bob, carol]);
      final fromBob = await open(harness, as: bob);
      fromBob.write(_post(ApiPaths.unpair));
      await probe.arrived(1);

      final removing = harness.paired.remove(bob.fingerprint);
      addTearDown(() => removing);
      final cutting = timeToClose(fromBob);
      await harness.server.rebuildTrust();
      final elapsed = await cutting;
      probe.gate!.complete();
      await Future<void>.delayed(_settle);
      probe.gate = null;
      final fromCarol = await harness.send(
        _post(ApiPaths.unpair),
        context: presenting(carol),
      );

      expect(elapsed, lessThan(_cutLimit));
      expect(Reply.parse(fromBob.received), isNull);
      expect(fromCarol!.status, 200);
      expect(probe.count, 2);
    });

    test('every connection of the removed device is cut, from several '
        'source addresses', () async {
      final probe = unpairProbe();
      final harness = await start([probe], pairedWith: [bob, carol]);
      final bobs = [
        for (final from in [
          loopback,
          otherLoopback,
          InternetAddress('127.0.0.3'),
        ])
          await TlsClient.connect(
            harness.port,
            serverFingerprint: alice.fingerprint,
            context: presenting(bob),
            from: from,
          ),
      ];
      final fromCarol = await open(harness, as: carol);
      await Future<void>.delayed(_settle);

      final removing = harness.paired.remove(bob.fingerprint);
      addTearDown(() => removing);
      await harness.server.rebuildTrust();
      final elapsed = await Future.wait([
        for (final client in bobs) timeToClose(client),
      ]);
      await Future<void>.delayed(_settle);

      for (final time in elapsed) {
        expect(time, lessThan(_cutLimit));
      }
      expect(fromCarol.isClosed, isFalse);
    });

    test('without rebuildTrust a removed device with an open connection gets '
        '401 on its request (RF-32 is the barrier in between)', () async {
      final probe = unpairProbe();
      final harness = await start([probe], pairedWith: [bob]);
      final fromBob = await open(harness, as: bob);

      final removing = harness.paired.remove(bob.fingerprint);
      addTearDown(() => removing);
      expect(harness.paired.isPaired(bob.fingerprint), isFalse);
      fromBob.write(_post(ApiPaths.unpair));
      final reply = await fromBob.reply(limit: const Duration(seconds: 25));

      expect(fromBob.received, isNotEmpty);
      expect(reply!.status, 401);
      expect(reply.json, {'error': 'unauthorized'});
      expect(probe.count, 0);
    });
  });

  group('C31: cut without disk (RF-113, RF-114)', () {
    test('remove(B) that cannot be written cuts B like C30, keeps C, and '
        'the save failure is reported', () async {
      final probe = unpairProbe();
      final harness = await start([probe], pairedWith: [bob, carol]);
      final fromBob = await open(harness, as: bob);
      final fromCarol = await open(harness, as: carol);
      await Future<void>.delayed(_settle);
      final lock = _ExclusiveLock(harness.pairedFile);
      addTearDown(lock.release);

      final removing = harness.paired.remove(bob.fingerprint);
      final cutting = timeToClose(fromBob);
      await harness.server.rebuildTrust();
      final elapsed = await cutting;
      final again = await harness.send(
        _post(ApiPaths.unpair),
        context: presenting(bob),
      );
      final saved = await removing;
      await Future<void>.delayed(_settle);
      lock.release();

      expect(elapsed, lessThan(_cutLimit));
      expect(again, isNull);
      expect(saved, isFalse);
      expect(harness.paired.hasUnsavedChanges, isTrue);
      expect(harness.paired.isPaired(bob.fingerprint), isFalse);
      expect(fromCarol.isClosed, isFalse);
      fromCarol.write(_post(ApiPaths.unpair));
      expect((await fromCarol.reply())!.status, 200);
      expect(
        [for (final c in probe.calls) c.clientFingerprint],
        [carol.fingerprint],
      );
    });
  });

  group('the trust context cannot be built (fail closed)', () {
    test('rebuildTrust rethrows, logs only the type and leaves nothing '
        'listening; syncInterfaces opens nothing either', () async {
      final broken = DeviceIdentity.fromPem(
        certificatePem: alice.certificatePem
            .replaceAll('BEGIN CERTIFICATE', 'BEGIN BROKEN')
            .replaceAll('END CERTIFICATE', 'END BROKEN'),
        privateKeyPem: privateKeyPemOf(alice),
      );
      expect(broken, isNotNull);
      final port = await freePortOn([loopback]);
      final harness = await ServerHarness.start(
        identity: broken!,
        pairedWith: [bob],
        active: const [],
        port: port,
      );

      await expectLater(
        harness.server.rebuildTrust(),
        throwsA(isA<TlsException>()),
      );
      await expectLater(
        harness.server.syncInterfaces([loopbackInterface()]),
        throwsA(isA<TlsException>()),
      );

      expect(harness.server.boundPort, isNull);
      expect(harness.server.openInterfaceIds, isEmpty);
      expect(await canBind(loopback, port), isTrue);
      expect(
        harness.logs.where((l) => l.startsWith('trust context failed')),
        hasLength(2),
      );
      expect(
        harness.logs.where((l) => l.contains(privateKeyPemOf(alice))),
        isEmpty,
      );
      for (final fragment in pemFragments(privateKeyPemOf(alice))) {
        expect(
          harness.logs.where((l) => l.contains(fragment)),
          isEmpty,
          reason: fragment,
        );
      }
    });
  });
}
