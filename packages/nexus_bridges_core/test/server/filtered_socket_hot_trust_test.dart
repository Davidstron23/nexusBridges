import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:nexus_bridges_core/src/identity/identity.dart';
import 'package:nexus_bridges_core/src/server/filtered_secure_server_socket.dart';
import 'package:test/test.dart';

import 'api_server_harness.dart';

const Duration _cutLimit = Duration(seconds: 1);
const Duration _settle = Duration(milliseconds: 300);

final class _SocketHarness {
  _SocketHarness._(this.socket);

  final FilteredSecureServerSocket socket;
  final List<SecureSocket> established = [];

  int get port => socket.port;

  static Future<_SocketHarness> start(SecurityContext context) async {
    final socket = await FilteredSecureServerSocket.bind(
      address: loopback,
      port: 0,
      context: context,
      allowOrigin: (_) => true,
      deadline: const Duration(seconds: 30),
    );
    final harness = _SocketHarness._(socket);
    socket.listen((s) => harness.established.add(s as SecureSocket));
    addTearDown(() async {
      for (final s in harness.established) {
        s.destroy();
      }
      await socket.close();
    });
    return harness;
  }

  Future<void> waitEstablished(int expected) async {
    final stopwatch = Stopwatch()..start();
    while (established.length < expected) {
      if (stopwatch.elapsed > waitLimit) {
        throw TimeoutException('established ${established.length}');
      }
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
  }
}

void main() {
  late DeviceIdentity alice;
  late DeviceIdentity bob;
  late DeviceIdentity carol;

  setUpAll(() {
    alice = DeviceIdentity.generate(commonName: randomCommonName());
    bob = DeviceIdentity.generate(commonName: randomCommonName());
    carol = DeviceIdentity.generate(commonName: randomCommonName());
  });

  SecurityContext trusting(List<DeviceIdentity> peers) => alice.serverContext(
    trustedCertificatesPem: [for (final p in peers) p.certificatePem],
  );

  Future<TlsClient> connect(
    _SocketHarness harness, {
    DeviceIdentity? as,
    InternetAddress? from,
  }) => TlsClient.connect(
    harness.port,
    serverFingerprint: alice.fingerprint,
    context: as == null ? null : presenting(as),
    from: from,
  );

  Future<bool> cutInHandshake(
    _SocketHarness harness,
    DeviceIdentity who,
  ) async {
    final before = harness.established.length;
    try {
      final client = await connect(harness, as: who);
      await client.closed.timeout(waitLimit);
    } on IOException {
      return harness.established.length == before;
    }
    await Future<void>.delayed(_settle);
    return harness.established.length == before;
  }

  Future<bool> alive(TlsClient client, SecureSocket server) async {
    if (client.isClosed) return false;
    final before = client.received.length;
    server.add(utf8.encode('ping'));
    await server.flush();
    final stopwatch = Stopwatch()..start();
    while (client.received.length < before + 4) {
      if (client.isClosed || stopwatch.elapsed > waitLimit) return false;
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    return true;
  }

  SecureSocket serverSideOf(_SocketHarness harness, TlsClient client) {
    final port = client.socket.port;
    return harness.established.singleWhere((s) {
      try {
        return s.remotePort == port;
      } on SocketException {
        return false;
      }
    });
  }

  group('dropConnections (RF-113)', () {
    test('cuts only the connections for which shouldDrop is true and returns '
        'how many; the others stay alive', () async {
      final harness = await _SocketHarness.start(trusting([bob, carol]));
      final fromBob = await connect(harness, as: bob);
      final fromCarol = await connect(harness, as: carol);
      await harness.waitEstablished(2);

      final stopwatch = Stopwatch()..start();
      final dropped = harness.socket.dropConnections(
        (peer) => fingerprintOfCertificate(peer.der) == bob.fingerprint,
      );
      await fromBob.closed.timeout(waitLimit);

      expect(dropped, 1);
      expect(stopwatch.elapsed, lessThan(_cutLimit));
      expect(await alive(fromCarol, serverSideOf(harness, fromCarol)), isTrue);
    });

    test('shouldDrop is asked once per connection with a certificate, with '
        'that certificate, and never for an anonymous one', () async {
      final harness = await _SocketHarness.start(trusting([bob, carol]));
      final fromBob = await connect(harness, as: bob);
      await connect(harness, as: carol);
      final anonymous = await connect(harness);
      await harness.waitEstablished(3);

      final asked = <String>[];
      final dropped = harness.socket.dropConnections((peer) {
        asked.add(fingerprintOfCertificate(peer.der));
        return true;
      });
      await fromBob.closed.timeout(waitLimit);

      expect(dropped, 2);
      expect(asked, unorderedEquals([bob.fingerprint, carol.fingerprint]));
      expect(await alive(anonymous, serverSideOf(harness, anonymous)), isTrue);
    });

    test('a shouldDrop that throws cuts the connection', () async {
      final harness = await _SocketHarness.start(trusting([bob]));
      final fromBob = await connect(harness, as: bob);
      await harness.waitEstablished(1);

      final dropped = harness.socket.dropConnections(
        (_) => throw StateError('broken'),
      );
      await fromBob.closed.timeout(waitLimit);

      expect(dropped, 1);
    });

    test(
      'a shouldDrop that is always false cuts nothing and returns 0',
      () async {
        final harness = await _SocketHarness.start(trusting([bob]));
        final fromBob = await connect(harness, as: bob);
        await harness.waitEstablished(1);

        final dropped = harness.socket.dropConnections((_) => false);
        await Future<void>.delayed(_settle);

        expect(dropped, 0);
        expect(await alive(fromBob, serverSideOf(harness, fromBob)), isTrue);
      },
    );

    test('a connection still before its handshake is neither asked nor '
        'cut', () async {
      final harness = await _SocketHarness.start(trusting([bob]));
      final raw = await Socket.connect(loopback, harness.port);
      addTearDown(raw.destroy);
      var rawClosed = false;
      raw.listen((_) {}, onDone: () => rawClosed = true, onError: (_) {});
      raw.add([0x16, 0x03]);
      await raw.flush();
      await Future<void>.delayed(_settle);

      var asked = 0;
      final dropped = harness.socket.dropConnections((_) {
        asked++;
        return true;
      });
      await Future<void>.delayed(_settle);

      expect(dropped, 0);
      expect(asked, 0);
      expect(rawClosed, isFalse);
    });

    test('a connection whose request already finished is no longer '
        'considered', () async {
      final harness = await _SocketHarness.start(trusting([bob]));
      final fromBob = await connect(harness, as: bob);
      await harness.waitEstablished(1);

      harness.socket.requestFinished('127.0.0.1:${fromBob.socket.port}');
      var asked = 0;
      final dropped = harness.socket.dropConnections((_) {
        asked++;
        return true;
      });

      expect(dropped, 0);
      expect(asked, 0);
    });

    test('after close it returns 0', () async {
      final harness = await _SocketHarness.start(trusting([bob]));
      await connect(harness, as: bob);
      await harness.waitEstablished(1);
      await harness.socket.close();

      expect(harness.socket.dropConnections((_) => true), 0);
    });
  });

  group('set context (RF-95)', () {
    test('new handshakes use the new context; a connection made with the old '
        'one is not touched', () async {
      final harness = await _SocketHarness.start(trusting([bob]));
      final fromBob = await connect(harness, as: bob);
      await harness.waitEstablished(1);
      expect(await cutInHandshake(harness, carol), isTrue);

      harness.socket.context = trusting([carol]);
      final fromCarol = await connect(harness, as: carol);
      await harness.waitEstablished(2);

      expect(await alive(fromCarol, serverSideOf(harness, fromCarol)), isTrue);
      expect(await alive(fromBob, serverSideOf(harness, fromBob)), isTrue);
      expect(await cutInHandshake(harness, bob), isTrue);
    });

    test(
      'the port stays the same and anonymous handshakes keep working',
      () async {
        final harness = await _SocketHarness.start(trusting([bob]));
        final port = harness.port;

        harness.socket.context = trusting(const []);
        final anonymous = await connect(harness);
        await harness.waitEstablished(1);

        expect(harness.port, port);
        expect(
          await alive(anonymous, serverSideOf(harness, anonymous)),
          isTrue,
        );
        expect(await cutInHandshake(harness, bob), isTrue);
      },
    );
  });
}
