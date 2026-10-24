import 'dart:io';

import 'package:nexus_bridges_core/src/identity/identity.dart';
import 'package:nexus_bridges_core/src/network/network.dart';
import 'package:nexus_bridges_core/src/protocol/protocol.dart';
import 'package:test/test.dart';

import 'api_server_harness.dart';

final InternetAddress _thirdLoopback = InternetAddress('127.0.0.3');
final InternetAddress _unassignable = InternetAddress('203.0.113.9');
const Duration _patient = Duration(seconds: 40);

void main() {
  late DeviceIdentity alice;
  late DeviceIdentity bob;

  setUpAll(() {
    alice = DeviceIdentity.generate();
    bob = DeviceIdentity.generate();
  });

  Future<Reply?> present(
    int port, {
    InternetAddress? from,
    InternetAddress? to,
    Duration limit = waitLimit,
  }) => sendOrCut(
    port,
    registerRequest(callerInfoOf(bob)),
    serverFingerprint: alice.fingerprint,
    from: from,
    to: to,
    limit: limit,
  );

  group('listeners follow the active interfaces (RF-17, RF-26)', () {
    test('with no active interface there is no listener and nobody holds the '
        'port', () async {
      final port = await freePort();
      final harness = await ServerHarness.start(
        identity: alice,
        active: const [],
        port: port,
      );

      expect(harness.server.boundPort, isNull);
      expect(await canBind(loopback, port), isTrue);
      await expectLater(
        Socket.connect(loopback, port),
        throwsA(isA<SocketException>()),
      );
    });

    test('with port 0 an active interface gets a real port that serves the '
        'presentation', () async {
      final harness = await ServerHarness.start(identity: alice);

      expect(harness.server.boundPort, inInclusiveRange(1, 65535));
      expect((await present(harness.port))!.status, 200);
    });

    test('the listener is bound to the interface address, not to every '
        'address', () async {
      final port = await freePort();
      final harness = await ServerHarness.start(
        identity: alice,
        port: port,
        active: [loopbackInterface(address: '127.0.0.2')],
      );

      expect(harness.server.boundPort, port);
      expect((await present(port, to: otherLoopback))!.status, 200);
      expect(await canBind(loopback, port), isTrue);
    });

    test('an interface that stops being active is closed and its port is '
        'released', () async {
      final harness = await ServerHarness.start(identity: alice);
      final port = harness.port;

      await harness.server.syncInterfaces(const []);

      expect(harness.server.boundPort, isNull);
      expect(await canBind(loopback, port), isTrue);
    });

    test('a new active interface is opened and serves, and it is the one '
        'given to onRegistered', () async {
      final harness = await ServerHarness.start(identity: alice);
      await harness.server.syncInterfaces(const []);
      final replacement = loopbackInterface(adapterId: 'replacement');

      await harness.server.syncInterfaces([replacement]);
      final reply = await present(harness.port);

      expect(reply!.status, 200);
      expect(harness.registrations.single.via, same(replacement));
    });

    test('syncInterfaces is idempotent: the same interface keeps its '
        'listener, port and ActiveInterface', () async {
      final original = loopbackInterface();
      final harness = await ServerHarness.start(
        identity: alice,
        active: [original],
      );
      final port = harness.port;

      await harness.server.syncInterfaces([original]);
      await harness.server.syncInterfaces([loopbackInterface()]);
      final reply = await present(harness.port);

      expect(harness.server.boundPort, port);
      expect(reply!.status, 200);
      expect(harness.registrations.single.via, same(original));
    });

    test('a subnet change with the same id reopens the listener with the new '
        'origin filter', () async {
      final wide = loopbackInterface(prefixLength: 8);
      final narrow = loopbackInterface(prefixLength: 32);
      final harness = await ServerHarness.start(
        identity: alice,
        active: [wide],
      );
      final before = await present(harness.port, from: otherLoopback);

      await harness.server.syncInterfaces([narrow]);
      final cut = await present(harness.port, from: otherLoopback);
      final local = await present(harness.port);

      expect(wide.id, narrow.id);
      expect(before!.status, 200);
      expect(cut, isNull);
      expect(local!.status, 200);
      expect(harness.registrations.map((r) => r.via), [
        same(wide),
        same(narrow),
      ]);
    });

    test(
      'an origin outside the subnet of the interface is not served',
      () async {
        final harness = await ServerHarness.start(
          identity: alice,
          active: [loopbackInterface(prefixLength: 32)],
        );

        final reply = await present(harness.port, from: otherLoopback);

        expect(reply, isNull);
        expect(harness.registrations, isEmpty);
      },
    );

    test(
      'two active interfaces get one listener each on the same port',
      () async {
        final port = await freePort();
        final first = loopbackInterface(adapterId: 'first');
        final second = loopbackInterface(
          adapterId: 'second',
          address: '127.0.0.2',
        );
        final harness = await ServerHarness.start(
          identity: alice,
          port: port,
          active: [first, second],
        );

        final viaFirst = await present(port);
        final viaSecond = await present(
          port,
          to: otherLoopback,
          from: otherLoopback,
        );

        expect(viaFirst!.status, 200);
        expect(viaSecond!.status, 200);
        expect(harness.registrations.map((r) => r.via), [
          same(first),
          same(second),
        ]);
      },
    );
  });

  group('port in use (RF-38 support)', () {
    test('a port held by another process throws PortInUseException(port) and '
        'leaves no listener', () async {
      final port = await holdPortInChildProcess(loopback);
      final harness = await ServerHarness.start(
        identity: alice,
        active: const [],
        port: port,
      );

      await expectLater(
        harness.server.syncInterfaces([loopbackInterface()]),
        throwsA(isA<PortInUseException>().having((e) => e.port, 'port', port)),
      );

      expect(harness.server.boundPort, isNull);
    }, timeout: const Timeout(Duration(seconds: 60)));

    test('the listeners opened in the failing call are closed, and the ones '
        'from an earlier call stay open', () async {
      final port = await holdPortInChildProcess(loopback);
      final earlier = loopbackInterface(
        adapterId: 'earlier',
        address: '127.0.0.3',
      );
      final opened = loopbackInterface(
        adapterId: 'opened',
        address: '127.0.0.2',
      );
      final blocked = loopbackInterface(adapterId: 'blocked');
      final harness = await ServerHarness.start(
        identity: alice,
        port: port,
        active: [earlier],
      );

      await expectLater(
        harness.server.syncInterfaces([earlier, opened, blocked]),
        throwsA(isA<PortInUseException>().having((e) => e.port, 'port', port)),
      );

      expect(await canBind(otherLoopback, port), isTrue);
      expect(await canBind(_thirdLoopback, port), isFalse);
      expect(harness.server.boundPort, port);
      final reply = await present(
        port,
        to: _thirdLoopback,
        from: _thirdLoopback,
        limit: _patient,
      );
      expect(reply!.status, 200);
      expect(harness.registrations.single.via, same(earlier));
    }, timeout: const Timeout(Duration(seconds: 60)));

    test('a bind failure that is not PortInUseException is logged by type, '
        'does not throw, and after the port is freed the same server opens '
        'the interface', () async {
      final port = await freePort();
      final squatter = await ServerSocket.bind(loopback, port);
      final harness = await ServerHarness.start(
        identity: alice,
        active: const [],
        port: port,
      );

      await harness.server.syncInterfaces([loopbackInterface()]);

      expect(harness.server.boundPort, isNull);
      expect(harness.logs.where((l) => l.startsWith('interface bind failed')), [
        'interface bind failed: SocketException',
      ]);

      await squatter.close();
      await harness.server.syncInterfaces([loopbackInterface()]);

      expect(harness.server.boundPort, port);
      expect((await present(port))!.status, 200);
    });

    test('a PortInUseException still aborts the call and closes what it '
        'opened even when another interface already failed for another '
        'reason', () async {
      final port = await holdPortInChildProcess(loopback);
      final foreign = loopbackInterface(
        adapterId: 'foreign',
        address: _unassignable.address,
        prefixLength: 24,
      );
      final opened = loopbackInterface(
        adapterId: 'opened',
        address: '127.0.0.2',
      );
      final blocked = loopbackInterface(adapterId: 'blocked');
      final harness = await ServerHarness.start(
        identity: alice,
        active: const [],
        port: port,
      );

      await expectLater(
        harness.server.syncInterfaces([foreign, opened, blocked]),
        throwsA(isA<PortInUseException>().having((e) => e.port, 'port', port)),
      );

      expect(harness.server.boundPort, isNull);
      expect(await canBind(otherLoopback, port), isTrue);
      expect(harness.logs.where((l) => l.startsWith('interface bind failed')), [
        'interface bind failed: SocketException',
      ]);
    }, timeout: const Timeout(Duration(seconds: 60)));
  });

  group('one interface failing does not stop the others (M5)', () {
    test('an address that is not assigned to this machine is logged by type '
        'only and the other interfaces are opened and serve', () async {
      final port = await freePort();
      final first = loopbackInterface(adapterId: 'first');
      final foreign = loopbackInterface(
        adapterId: 'foreign',
        address: _unassignable.address,
        prefixLength: 24,
      );
      final second = loopbackInterface(
        adapterId: 'second',
        address: '127.0.0.2',
      );
      final harness = await ServerHarness.start(
        identity: alice,
        port: port,
        active: [first, foreign, second],
      );

      final viaFirst = await present(port);
      final viaSecond = await present(
        port,
        to: otherLoopback,
        from: otherLoopback,
      );

      expect(harness.server.boundPort, port);
      expect(viaFirst!.status, 200);
      expect(viaSecond!.status, 200);
      expect(harness.registrations.map((r) => r.via), [
        same(first),
        same(second),
      ]);
      expect(harness.logs.where((l) => l.startsWith('interface bind failed')), [
        'interface bind failed: SocketException',
      ]);
      expect(harness.logs.join('\n'), isNot(contains('203.0.113')));
      expect(harness.logs.join('\n'), isNot(contains('foreign')));
    });

    test('with only the unassignable interface nothing is opened, nothing is '
        'thrown and a later valid interface is opened', () async {
      final foreign = loopbackInterface(
        adapterId: 'foreign',
        address: _unassignable.address,
        prefixLength: 24,
      );
      final harness = await ServerHarness.start(
        identity: alice,
        active: [foreign],
      );

      expect(harness.server.boundPort, isNull);

      await harness.server.syncInterfaces([foreign, loopbackInterface()]);

      expect(harness.server.boundPort, isNotNull);
      expect((await present(harness.port))!.status, 200);
      expect(
        harness.logs.where((l) => l.startsWith('interface bind failed')),
        hasLength(2),
      );
    });
  });

  group('a friendlyName change (B4)', () {
    test('same id and subnet with another friendlyName keeps the listener, '
        'its port and its open connections, and onRegistered gets the new '
        'ActiveInterface', () async {
      final original = loopbackInterface();
      final harness = await ServerHarness.start(
        identity: alice,
        active: [original],
      );
      final port = harness.port;
      final openBefore = await TlsClient.connect(
        port,
        serverFingerprint: alice.fingerprint,
      );
      final renamed = ActiveInterface(
        id: original.id,
        adapterId: original.adapterId,
        friendlyName: 'Ethernet (renamed)',
        subnet: Ipv4Subnet(InternetAddress('127.0.0.1'), 8),
      );

      await harness.server.syncInterfaces([renamed]);
      openBefore.write(registerRequest(callerInfoOf(bob)));
      final survivor = await openBefore.reply();
      final fresh = await present(port);

      expect(renamed.id, original.id);
      expect(renamed.subnet, original.subnet);
      expect(harness.server.boundPort, port);
      expect(survivor!.status, 200);
      expect(fresh!.status, 200);
      expect(harness.registrations.map((r) => r.via.friendlyName), [
        'Ethernet (renamed)',
        'Ethernet (renamed)',
      ]);
      expect(harness.registrations.map((r) => r.via), [
        same(renamed),
        same(renamed),
      ]);
    });

    test('control: a subnet change with the same id does reopen the listener '
        'and cuts the connections opened before', () async {
      final harness = await ServerHarness.start(
        identity: alice,
        active: [loopbackInterface(prefixLength: 8)],
      );
      final openBefore = await TlsClient.connect(
        harness.port,
        serverFingerprint: alice.fingerprint,
      );

      await harness.server.syncInterfaces([
        loopbackInterface(prefixLength: 16),
      ]);
      openBefore.write(registerRequest(callerInfoOf(bob)));
      await openBefore.closed.timeout(waitLimit);

      expect(Reply.parse(openBefore.received), isNull);
      expect(harness.registrations, isEmpty);
    });
  });

  group('openInterfaceIds (v2.8 point 15)', () {
    test('it is empty with no interface and follows the listeners that '
        'syncInterfaces opens and closes', () async {
      final first = loopbackInterface(adapterId: 'first');
      final second = loopbackInterface(
        adapterId: 'second',
        address: '127.0.0.2',
      );
      final harness = await ServerHarness.start(
        identity: alice,
        active: const [],
      );

      expect(harness.server.openInterfaceIds, isEmpty);

      await harness.server.syncInterfaces([first, second]);
      expect(harness.server.openInterfaceIds, {first.id, second.id});

      await harness.server.syncInterfaces([second]);
      expect(harness.server.openInterfaceIds, {second.id});

      await harness.server.syncInterfaces(const []);
      expect(harness.server.openInterfaceIds, isEmpty);
    });

    test('an interface whose listener could not be opened is not in it, and '
        'it is once the listener opens', () async {
      final port = await freePort();
      final squatter = await ServerSocket.bind(otherLoopback, port);
      var squatterOpen = true;
      addTearDown(() async {
        if (squatterOpen) await squatter.close();
      });
      final first = loopbackInterface(adapterId: 'first');
      final blocked = loopbackInterface(
        adapterId: 'blocked',
        address: '127.0.0.2',
      );
      final foreign = loopbackInterface(
        adapterId: 'foreign',
        address: _unassignable.address,
        prefixLength: 24,
      );
      final harness = await ServerHarness.start(
        identity: alice,
        port: port,
        active: [first, blocked, foreign],
      );

      expect(harness.server.openInterfaceIds, {first.id});

      await squatter.close();
      squatterOpen = false;
      await harness.server.syncInterfaces([first, blocked, foreign]);

      expect(harness.server.openInterfaceIds, {first.id, blocked.id});
    });

    test('rebuildTrust keeps the same ids on the same port', () async {
      final first = loopbackInterface(adapterId: 'first');
      final second = loopbackInterface(
        adapterId: 'second',
        address: '127.0.0.2',
      );
      final harness = await ServerHarness.start(
        identity: alice,
        active: [first, second],
      );
      final port = harness.port;

      await harness.pair([bob]);
      await harness.server.rebuildTrust();

      expect(harness.server.openInterfaceIds, {first.id, second.id});
      expect(harness.server.boundPort, port);
    });

    test('a PortInUseException leaves only the listeners from earlier '
        'calls', () async {
      final port = await holdPortInChildProcess(loopback);
      final earlier = loopbackInterface(
        adapterId: 'earlier',
        address: '127.0.0.3',
      );
      final opened = loopbackInterface(
        adapterId: 'opened',
        address: '127.0.0.2',
      );
      final blocked = loopbackInterface(adapterId: 'blocked');
      final harness = await ServerHarness.start(
        identity: alice,
        port: port,
        active: [earlier],
      );

      await expectLater(
        harness.server.syncInterfaces([earlier, opened, blocked]),
        throwsA(isA<PortInUseException>()),
      );

      expect(harness.server.openInterfaceIds, {earlier.id});
    }, timeout: const Timeout(Duration(seconds: 60)));

    test('close empties it and a later syncInterfaces keeps it '
        'empty', () async {
      final harness = await ServerHarness.start(identity: alice);
      expect(harness.server.openInterfaceIds, {loopbackInterface().id});

      await harness.server.close();
      expect(harness.server.openInterfaceIds, isEmpty);

      await harness.server.syncInterfaces([loopbackInterface()]);
      expect(harness.server.openInterfaceIds, isEmpty);
    });

    test('the set cannot be modified from outside', () async {
      final harness = await ServerHarness.start(identity: alice);
      final ids = harness.server.openInterfaceIds;

      expect(() => ids.add('intruder#127.0.0.9'), throwsUnsupportedError);
      expect(() => ids.clear(), throwsUnsupportedError);
      expect(harness.server.openInterfaceIds, {loopbackInterface().id});
    });
  });

  group('close', () {
    test('close releases the port, leaves boundPort null and can be called '
        'twice', () async {
      final harness = await ServerHarness.start(identity: alice);
      final port = harness.port;

      await harness.server.close();
      await harness.server.close();

      expect(harness.server.boundPort, isNull);
      expect(await canBind(loopback, port), isTrue);
    });

    test('after close, syncInterfaces and rebuildTrust do nothing', () async {
      final port = await freePort();
      final harness = await ServerHarness.start(
        identity: alice,
        port: port,
        pairedWith: [bob],
      );

      await harness.server.close();
      await harness.server.syncInterfaces([loopbackInterface()]);
      await harness.server.rebuildTrust();

      expect(harness.server.boundPort, isNull);
      expect(await canBind(loopback, port), isTrue);
    });

    test('close with no interfaces completes', () async {
      final harness = await ServerHarness.start(
        identity: alice,
        active: const [],
      );

      await harness.server.close();

      expect(harness.server.boundPort, isNull);
    });
  });
}
