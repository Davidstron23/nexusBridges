import 'dart:convert';
import 'dart:io';

import 'package:nexus_bridges_core/src/identity/identity.dart';
import 'package:nexus_bridges_core/src/protocol/protocol.dart';
import 'package:test/test.dart';

import 'api_server_harness.dart';

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

  Future<ServerHarness> start({
    Iterable<DeviceIdentity> pairedWith = const [],
  }) => ServerHarness.start(identity: alice, pairedWith: pairedWith);

  void expectError(Reply? reply, int status, String code) {
    expect(reply, isNotNull);
    expect(reply!.status, status);
    expect(reply.json, {'error': code});
    expect(reply.header('content-type'), jsonContentType);
    expect(reply.header('connection'), 'close');
  }

  group('presentation (RF-30)', () {
    test('an anonymous valid presentation gets 200 with exactly the five '
        'announcement fields of selfInfo', () async {
      final harness = await start();

      final reply = await harness.send(registerRequest(callerInfoOf(bob)));

      expect(reply, isNotNull);
      expect(reply!.status, 200);
      final json = reply.json as Map<String, Object?>;
      expect(
        json.keys,
        unorderedEquals(<String>[
          'name',
          'fingerprint',
          'port',
          'protocol',
          'deviceType',
        ]),
      );
      expect(json, selfInfoOf(alice).toJson());
      expect(DeviceInfo.tryParse(json)?.fingerprint, alice.fingerprint);
    });

    test('the reply is JSON in UTF-8 with an exact length and closes the '
        'connection', () async {
      final harness = await start();

      final reply = await harness.send(registerRequest(callerInfoOf(bob)));

      expect(reply!.header('content-type'), jsonContentType);
      expect(reply.header('connection'), 'close');
      expect(
        reply.header('content-length'),
        '${utf8.encode(reply.body).length}',
      );
    });

    test('onRegistered gets the caller DeviceInfo, the source IP and the '
        'ActiveInterface of the listener', () async {
      final iface = loopbackInterface();
      final harness = await ServerHarness.start(
        identity: alice,
        active: [iface],
      );

      await harness.send(registerRequest(callerInfoOf(bob, name: 'Bob')));

      expect(harness.registrations, hasLength(1));
      final registration = harness.registrations.single;
      expect(
        registration.caller.toJson(),
        callerInfoOf(bob, name: 'Bob').toJson(),
      );
      expect(registration.from.address, '127.0.0.1');
      expect(registration.via, same(iface));
    });

    test('the source IP is the real one when the caller comes from '
        '127.0.0.2', () async {
      final harness = await start();

      final reply = await harness.send(
        registerRequest(callerInfoOf(bob)),
        from: otherLoopback,
      );

      expect(reply!.status, 200);
      expect(harness.registrations.single.from.address, '127.0.0.2');
    });

    test(
      'a paired client with its certificate can also present itself',
      () async {
        final harness = await start(pairedWith: [bob]);

        final reply = await harness.send(
          registerRequest(callerInfoOf(bob)),
          context: presenting(bob),
        );

        expect(reply!.status, 200);
        expect(harness.registrations, hasLength(1));
      },
    );
  });

  group('access control (RF-28, RF-29, RF-31)', () {
    test(
      'a paired client with its certificate on an unknown route gets 404',
      () async {
        final harness = await start(pairedWith: [bob]);

        final reply = await harness.send(
          httpRequest('GET', '$apiPrefix/anything'),
          context: presenting(bob),
        );

        expectError(reply, 404, 'not_found');
        expect(harness.registrations, isEmpty);
      },
    );

    for (final (method, path) in [
      ('GET', '$apiPrefix/anything'),
      ('POST', '$apiPrefix/pair'),
      ('GET', '/'),
      ('GET', apiPrefix),
    ]) {
      test('an anonymous $method $path gets 401', () async {
        final harness = await start(pairedWith: [bob]);

        final reply = await harness.send(httpRequest(method, path));

        expectError(reply, 401, 'unauthorized');
        expect(harness.registrations, isEmpty);
      });
    }

    test('a client with a certificate that is not paired is cut on register '
        'and gets no HTTP reply', () async {
      final harness = await start(pairedWith: [bob]);

      final reply = await harness.send(
        registerRequest(callerInfoOf(carol)),
        context: presenting(carol),
      );

      expect(reply, isNull);
      expect(harness.registrations, isEmpty);
    });

    test('a client with a certificate that is not paired is cut on any other '
        'route', () async {
      final harness = await start(pairedWith: [bob]);

      final reply = await harness.send(
        httpRequest('GET', '$apiPrefix/anything'),
        context: presenting(carol),
      );

      expect(reply, isNull);
    });

    test('with no paired devices at all, a client certificate is cut and an '
        'anonymous presentation still works', () async {
      final harness = await start();

      final cut = await harness.send(
        registerRequest(callerInfoOf(bob)),
        context: presenting(bob),
      );
      final anonymous = await harness.send(registerRequest(callerInfoOf(bob)));

      expect(cut, isNull);
      expect(anonymous!.status, 200);
      expect(harness.registrations, hasLength(1));
    });
  });

  group('encryption (RF-26)', () {
    test('a plain-text HTTP client gets no HTTP reply and is closed', () async {
      final harness = await start();
      final socket = await Socket.connect(loopback, harness.port);
      addTearDown(socket.destroy);
      socket.done.ignore();
      final received = <int>[];

      socket.add(registerRequest(callerInfoOf(bob)));
      final closed = await socket
          .listen(received.addAll, cancelOnError: true)
          .asFuture<void>()
          .then((_) => true, onError: (Object _) => true)
          .timeout(waitLimit, onTimeout: () => false);

      expect(closed, isTrue);
      expect(latin1.decode(received), isNot(contains('HTTP/')));
      expect(harness.registrations, isEmpty);
    });

    test(
      'control: the same request over TLS on the same port is served',
      () async {
        final harness = await start();

        final reply = await harness.send(registerRequest(callerInfoOf(bob)));

        expect(reply!.status, 200);
      },
    );
  });

  group('paired list changes (RF-32, RF-33)', () {
    test('removing a paired device without restarting the server gives 401 '
        'on its next request at once', () async {
      final harness = await start(pairedWith: [bob]);
      final before = await harness.send(
        httpRequest('GET', '$apiPrefix/anything'),
        context: presenting(bob),
      );
      expectError(before, 404, 'not_found');

      await harness.paired.replaceAll(const []);
      final after = await harness.send(
        httpRequest('GET', '$apiPrefix/anything'),
        context: presenting(bob),
      );

      expectError(after, 401, 'unauthorized');
    });

    test('a removed paired device presenting itself with its certificate '
        'gets 401 and onRegistered is not called', () async {
      final harness = await start(pairedWith: [bob]);

      await harness.paired.replaceAll(const []);
      final reply = await harness.send(
        registerRequest(callerInfoOf(bob)),
        context: presenting(bob),
      );

      expectError(reply, 401, 'unauthorized');
      expect(harness.registrations, isEmpty);
    });

    test('after rebuildTrust the removed device is cut in the handshake and '
        'the port does not change', () async {
      final harness = await start(pairedWith: [bob]);
      final port = harness.port;

      await harness.paired.replaceAll(const []);
      await harness.server.rebuildTrust();
      final reply = await harness.send(
        httpRequest('GET', '$apiPrefix/anything'),
        context: presenting(bob),
      );

      expect(harness.server.boundPort, port);
      expect(reply, isNull);
    });

    test('a newly paired device is cut before rebuildTrust and enters after '
        'it', () async {
      final harness = await start(pairedWith: [bob]);

      await harness.pair([bob, dave]);
      final before = await harness.send(
        httpRequest('GET', '$apiPrefix/anything'),
        context: presenting(dave),
      );
      await harness.server.rebuildTrust();
      final after = await harness.send(
        httpRequest('GET', '$apiPrefix/anything'),
        context: presenting(dave),
      );
      final stillBob = await harness.send(
        httpRequest('GET', '$apiPrefix/anything'),
        context: presenting(bob),
      );

      expect(before, isNull);
      expectError(after, 404, 'not_found');
      expectError(stillBob, 404, 'not_found');
    });

    test(
      'the anonymous presentation keeps working after rebuildTrust',
      () async {
        final harness = await start(pairedWith: [bob]);

        await harness.paired.replaceAll(const []);
        await harness.server.rebuildTrust();
        final reply = await harness.send(registerRequest(callerInfoOf(carol)));

        expect(reply!.status, 200);
        expect(
          harness.registrations.single.caller.fingerprint,
          carol.fingerprint,
        );
      },
    );

    test(
      'rebuildTrust with no interfaces completes and opens nothing',
      () async {
        final harness = await ServerHarness.start(
          identity: alice,
          pairedWith: [bob],
          active: const [],
        );

        await harness.server.rebuildTrust();

        expect(harness.server.boundPort, isNull);
      },
    );
  });

  group('certificate dates (RF-9)', () {
    test('a server whose own certificate has expired is reached by a client '
        'that pins its fingerprint', () async {
      final expired = expiredIdentity();
      final harness = await ServerHarness.start(identity: expired);

      final reply = await harness.send(registerRequest(callerInfoOf(bob)));

      expect(reply!.status, 200);
      expect((reply.json as Map)['fingerprint'], expired.fingerprint);
    });

    test(
      'observed (risk R7): a paired client whose certificate has expired '
      'is cut in the handshake, while a paired one in its dates is served',
      () async {
        final expired = expiredIdentity();
        final harness = await start(pairedWith: [expired, bob]);

        final cut = await harness.send(
          httpRequest('GET', '$apiPrefix/anything'),
          context: presenting(expired),
        );
        final served = await harness.send(
          httpRequest('GET', '$apiPrefix/anything'),
          context: presenting(bob),
        );

        expect(cut, isNull);
        expectError(served, 404, 'not_found');
      },
    );
  });

  group('input validation', () {
    final valid = <String, Object?>{
      'name': 'Caller',
      'fingerprint': 'A' * 64,
      'port': 40000,
      'protocol': protocolVersion,
      'deviceType': 'mobile',
    };

    final cases = <String, List<int>>{
      'broken JSON': utf8.encode('{"name": "Caller", "fingerprint":'),
      'an empty body': const [],
      'a JSON array': jsonBody([valid]),
      'a JSON string': jsonBody('hello'),
      'bytes that are not UTF-8': const [0xFF, 0xFE, 0xFD],
      'a lowercase fingerprint': jsonBody({...valid, 'fingerprint': 'a' * 64}),
      'protocol 2.0': jsonBody({...valid, 'protocol': '2.0'}),
      'an extra key': jsonBody({...valid, 'extra': 1}),
      'a missing key': jsonBody({...valid}..remove('deviceType')),
      'port 0': jsonBody({...valid, 'port': 0}),
      'an unknown deviceType': jsonBody({...valid, 'deviceType': 'toaster'}),
    };

    for (final MapEntry(key: label, value: body) in cases.entries) {
      test('a presentation with $label gets 400', () async {
        final harness = await start();

        final reply = await harness.send(
          httpRequest('POST', registerPath, body: body),
        );

        expectError(reply, 400, 'bad_request');
        expect(harness.registrations, isEmpty);
      });
    }

    test('control: the valid body used by those cases gets 200', () async {
      final harness = await start();

      final reply = await harness.send(
        httpRequest('POST', registerPath, body: jsonBody(valid)),
      );

      expect(reply!.status, 200);
    });

    for (final method in ['GET', 'PUT', 'DELETE']) {
      test('$method on register gets 405', () async {
        final harness = await start();

        final reply = await harness.send(httpRequest(method, registerPath));

        expectError(reply, 405, 'method_not_allowed');
        expect(harness.registrations, isEmpty);
      });
    }

    for (final path in [
      '$apiPrefix/x/../register',
      '$apiPrefix/./register',
      '/../api/nexusbridges/v1/register',
    ]) {
      test('observed: dart:io resolves the dot segments of POST $path into '
          'the register route before decideRoute sees it', () async {
        final harness = await start();

        final reply = await harness.send(
          httpRequest('POST', path, body: jsonBody(valid)),
        );

        expect(reply!.status, 200);
        expect(harness.registrations, hasLength(1));
      });
    }

    for (final path in [
      '$apiPrefix/../register',
      '$apiPrefix/../../register',
      '$apiPrefix/register/..',
      '$apiPrefix//register',
      '/api/nexusbridges//v1/register',
      '$apiPrefix/register/',
      '$apiPrefix/REGISTER',
      '/API/NEXUSBRIDGES/V1/register',
      '$apiPrefix/register%2F',
    ]) {
      test('POST $path does not reach register', () async {
        final harness = await start();

        final reply = await harness.send(
          httpRequest('POST', path, body: jsonBody(valid)),
        );

        expectError(reply, 401, 'unauthorized');
        expect(harness.registrations, isEmpty);
      });
    }
  });

  group('robustness and secrets', () {
    test('an onRegistered that throws does not change the reply nor stop the '
        'server', () async {
      final harness = await start();
      harness.onRegistered = (_) => throw StateError('callback exploded');

      final first = await harness.send(registerRequest(callerInfoOf(bob)));
      final second = await harness.send(registerRequest(callerInfoOf(carol)));

      expect(first!.status, 200);
      expect(first.json, selfInfoOf(alice).toJson());
      expect(second!.status, 200);
      expect(harness.registrations, hasLength(2));
      expect(
        harness.logs,
        contains('registration callback failed: StateError'),
      );
      expect(harness.logs.join('\n'), isNot(contains('callback exploded')));
    });

    test(
      'the log never holds request bodies, PEM text or the private key',
      () async {
        const marker = 'MARKER-7f3a9c-do-not-log';
        final harness = await start(pairedWith: [bob]);
        harness.onRegistered = (_) => throw StateError(marker);
        final serverKey = privateKeyPemOf(alice);
        final clientKey = privateKeyPemOf(bob);

        await harness.send(
          registerRequest(
            callerInfoOf(carol, name: '$marker ${alice.certificatePem}'),
          ),
        );
        await harness.send(
          httpRequest(
            'POST',
            registerPath,
            body: utf8.encode('{"$marker": $serverKey'),
          ),
        );
        await harness.send(
          httpRequest(
            'POST',
            '$apiPrefix/$marker',
            body: utf8.encode(clientKey),
            headers: {'x-secret': marker},
          ),
          context: presenting(bob),
        );
        await harness.send(
          registerRequest(callerInfoOf(carol)),
          context: presenting(carol),
        );
        final log = harness.logs.join('\n');

        expect(harness.logs, isNotEmpty);
        expect(log, isNot(contains(marker)));
        expect(log, isNot(contains('BEGIN')));
        expect(log, isNot(contains('PRIVATE KEY')));
        for (final pem in [
          serverKey,
          clientKey,
          alice.certificatePem,
          bob.certificatePem,
        ]) {
          for (final fragment in pemFragments(pem)) {
            expect(log, isNot(contains(fragment)));
          }
        }
      },
    );
  });
}
