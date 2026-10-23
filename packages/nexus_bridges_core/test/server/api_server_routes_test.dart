import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:nexus_bridges_core/src/identity/identity.dart';
import 'package:nexus_bridges_core/src/pairing/pairing.dart';
import 'package:nexus_bridges_core/src/protocol/protocol.dart';
import 'package:nexus_bridges_core/src/server/server.dart';
import 'package:nexus_bridges_core/src/storage/storage.dart';
import 'package:test/test.dart';

import 'api_server_harness.dart';

const String _marker = 'handler-detail-marker';

const RouteLimit _twelvePerMinute = RouteLimit(
  maxPerWindow: 12,
  window: Duration(minutes: 1),
  block: Duration(minutes: 1),
);

List<int> _paddedJson(Map<String, Object?> json, int size) {
  final bytes = jsonBody(json);
  return [...bytes, ...List.filled(size - bytes.length, 0x20)];
}

List<int> _chunk(List<int> data) => [
  ...ascii.encode('${data.length.toRadixString(16)}\r\n'),
  ...data,
  ...ascii.encode('\r\n'),
];

List<int> _chunkedRequest(String path, List<int> body, {int pieces = 4}) {
  final head = ascii.encode(
    'POST $path HTTP/1.1\r\n'
    'host: 127.0.0.1\r\n'
    'transfer-encoding: chunked\r\n'
    '\r\n',
  );
  final size = (body.length / pieces).ceil();
  return [
    ...head,
    for (var i = 0; i < body.length; i += size)
      ..._chunk(
        body.sublist(i, i + size > body.length ? body.length : i + size),
      ),
    ...ascii.encode('0\r\n\r\n'),
  ];
}

Future<void> _until(bool Function() condition) async {
  final stopwatch = Stopwatch()..start();
  while (!condition()) {
    if (stopwatch.elapsed > waitLimit) throw TimeoutException('condition');
    await Future<void>.delayed(const Duration(milliseconds: 5));
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

  Future<ServerHarness> start(
    List<RouteProbe> probes, {
    Iterable<DeviceIdentity> pairedWith = const [],
  }) => ServerHarness.start(
    identity: alice,
    pairedWith: pairedWith,
    routes: [for (final p in probes) p.route],
  );

  void expectError(Reply? reply, int status, String code) {
    expect(reply, isNotNull);
    expect(reply!.status, status);
    expect(reply.json, {'error': code});
    expect(reply.header('content-type'), jsonContentType);
    expect(reply.header('connection'), 'close');
  }

  Future<ApiServer Function(List<ApiRoute>)> builder() async {
    final dir = await Directory.systemTemp.createTemp('nexus_routes_');
    addTearDown(() => dir.delete(recursive: true));
    final store = PairedDevicesStore(
      JsonFileStore(File('${dir.path}${Platform.pathSeparator}paired.json')),
      ownerFingerprint: alice.fingerprint,
    );
    return (routes) => ApiServer(
      identity: alice,
      paired: store,
      selfInfo: () => selfInfoOf(alice),
      onRegistered: (_, _, _) {},
      routes: routes,
    );
  }

  Future<ApiReply> ok(ApiCall call) async => const ApiReply(200, {});

  ApiRoute anonymous(String path) =>
      ApiRoute(path: path, access: RouteAccess.anonymous, handle: ok);

  ApiRoute pairedOnly(String path) =>
      ApiRoute(path: path, access: RouteAccess.paired, handle: ok);

  group('C25: only the listed anonymous routes (SEC-03)', () {
    test('an anonymous route outside ApiPaths.anonymous throws '
        'ArgumentError', () async {
      final build = await builder();

      for (final path in [
        '$apiPrefix/files',
        ApiPaths.unpair,
        '$apiPrefix/pair/other',
        '$apiPrefix/pair/start/',
        '$apiPrefix/PAIR/START',
      ]) {
        expect(
          () => build([anonymous(path)]),
          throwsArgumentError,
          reason: path,
        );
      }
    });

    test('a repeated route throws ArgumentError, also with another '
        'access', () async {
      final build = await builder();

      expect(
        () => build([
          anonymous(ApiPaths.pairStart),
          anonymous(ApiPaths.pairStart),
        ]),
        throwsArgumentError,
      );
      expect(
        () => build([pairedOnly(ApiPaths.unpair), pairedOnly(ApiPaths.unpair)]),
        throwsArgumentError,
      );
      expect(
        () => build([
          anonymous(ApiPaths.pairWait),
          pairedOnly(ApiPaths.pairWait),
        ]),
        throwsArgumentError,
      );
    });

    test('a route equal to register throws ArgumentError with either '
        'access', () async {
      final build = await builder();

      expect(() => build([anonymous(ApiPaths.register)]), throwsArgumentError);
      expect(() => build([pairedOnly(ApiPaths.register)]), throwsArgumentError);
    });

    test('a route outside the API prefix throws ArgumentError, also for '
        'paired routes', () async {
      final build = await builder();

      for (final path in [
        '',
        '/',
        apiPrefix,
        '/files',
        '/api/nexusbridges/v2/files',
        '/api/nexusbridges/files',
        ApiPaths.unpair.substring(1),
        ' ${ApiPaths.unpair}',
        '/API/NEXUSBRIDGES/V1/files',
      ]) {
        expect(
          () => build([pairedOnly(path)]),
          throwsArgumentError,
          reason: '"$path"',
        );
      }
    });

    test('one bad route among good ones throws', () async {
      final build = await builder();

      expect(
        () => build([
          anonymous(ApiPaths.pairStart),
          pairedOnly(ApiPaths.unpair),
          anonymous('$apiPrefix/files'),
        ]),
        throwsArgumentError,
      );
    });

    test('the six pair/ routes anonymous, unpair and any other path under '
        'the prefix as paired are accepted in order', () async {
      final build = await builder();
      final routes = [
        anonymous(ApiPaths.pairStart),
        anonymous(ApiPaths.pairReveal),
        anonymous(ApiPaths.pairWait),
        anonymous(ApiPaths.pairConfirm),
        anonymous(ApiPaths.pairCancel),
        anonymous(ApiPaths.pairStatus),
        pairedOnly(ApiPaths.unpair),
        pairedOnly('$apiPrefix/files'),
      ];

      final server = build(routes);

      expect(
        [for (final r in server.routes) r.path],
        [for (final r in routes) r.path],
      );
      expect(
        () => server.routes.add(anonymous(ApiPaths.pairStart)),
        throwsUnsupportedError,
      );
    });

    test('no routes is the default and is accepted', () async {
      final build = await builder();

      expect(build(const []).routes, isEmpty);
    });

    test('the anonymous set is exactly register and the six pair/ '
        'routes', () {
      expect(ApiPaths.anonymous, {
        ApiPaths.register,
        ApiPaths.pairStart,
        ApiPaths.pairReveal,
        ApiPaths.pairWait,
        ApiPaths.pairConfirm,
        ApiPaths.pairCancel,
        ApiPaths.pairStatus,
      });
      expect(ApiPaths.anonymous, isNot(contains(ApiPaths.unpair)));
    });
  });

  group('routes on the wire follow decideRoute (SEC-03)', () {
    test('an anonymous route answers without a certificate and the call has '
        'no fingerprint, the path, the source IP and the interface', () async {
      final probe = RouteProbe(ApiPaths.pairStart);
      final harness = await start([probe]);

      final reply = await harness.send(
        httpRequest('POST', ApiPaths.pairStart, body: jsonBody({'a': 1})),
        from: otherLoopback,
      );

      expect(reply!.status, 200);
      expect(reply.json, {'path': ApiPaths.pairStart, 'call': 1});
      final call = probe.calls.single;
      expect(call.path, ApiPaths.pairStart);
      expect(call.clientFingerprint, isNull);
      expect(call.remoteAddress.address, '127.0.0.2');
      expect(call.via.id, loopbackInterface().id);
      expect(call.via.subnet, loopbackInterface().subnet);
      expect(call.json, {'a': 1});
    });

    test('an anonymous route called by a paired device carries its '
        'fingerprint', () async {
      final probe = RouteProbe(ApiPaths.pairStatus);
      final harness = await start([probe], pairedWith: [bob]);

      final reply = await harness.send(
        httpRequest('POST', ApiPaths.pairStatus, body: jsonBody({})),
        context: presenting(bob),
      );

      expect(reply!.status, 200);
      expect(probe.calls.single.clientFingerprint, bob.fingerprint);
    });

    test('a paired route without a certificate gets 401 and the handler is '
        'not called', () async {
      final probe = RouteProbe(ApiPaths.unpair, access: RouteAccess.paired);
      final harness = await start([probe], pairedWith: [bob]);

      final reply = await harness.send(
        httpRequest('POST', ApiPaths.unpair, body: jsonBody({})),
      );

      expectError(reply, 401, 'unauthorized');
      expect(probe.count, 0);
    });

    test('a paired route with a paired certificate reaches the handler with '
        'its fingerprint', () async {
      final probe = RouteProbe(ApiPaths.unpair, access: RouteAccess.paired);
      final harness = await start([probe], pairedWith: [bob, carol]);

      final reply = await harness.send(
        httpRequest('POST', ApiPaths.unpair, body: jsonBody({})),
        context: presenting(carol),
      );

      expect(reply!.status, 200);
      expect(probe.calls.single.clientFingerprint, carol.fingerprint);
    });

    test('a paired device that is removed from memory gets 401 on a route '
        'at once, before any rebuildTrust (RF-32)', () async {
      final probe = RouteProbe(ApiPaths.pairStart);
      final harness = await start([probe], pairedWith: [bob]);

      final removing = harness.paired.remove(bob.fingerprint);
      addTearDown(() => removing);
      final reply = await harness.send(
        httpRequest('POST', ApiPaths.pairStart, body: jsonBody({})),
        context: presenting(bob),
      );

      expectError(reply, 401, 'unauthorized');
      expect(probe.count, 0);
    });

    test('another method on a route gets 405 and the handler is not '
        'called', () async {
      final anonymousProbe = RouteProbe(ApiPaths.pairWait);
      final pairedProbe = RouteProbe(
        ApiPaths.unpair,
        access: RouteAccess.paired,
      );
      final harness = await start(
        [anonymousProbe, pairedProbe],
        pairedWith: [bob],
      );

      for (final method in ['GET', 'PUT', 'DELETE']) {
        expectError(
          await harness.send(httpRequest(method, ApiPaths.pairWait)),
          405,
          'method_not_allowed',
        );
        expectError(
          await harness.send(
            httpRequest(method, ApiPaths.unpair),
            context: presenting(bob),
          ),
          405,
          'method_not_allowed',
        );
      }
      expect(anonymousProbe.count, 0);
      expect(pairedProbe.count, 0);
    });

    test('an unknown route gets 404 with a paired certificate and 401 '
        'without one', () async {
      final probe = RouteProbe(ApiPaths.pairStart);
      final harness = await start([probe], pairedWith: [bob]);

      expectError(
        await harness.send(
          httpRequest('POST', ApiPaths.pairReveal, body: jsonBody({})),
          context: presenting(bob),
        ),
        404,
        'not_found',
      );
      expectError(
        await harness.send(
          httpRequest('POST', ApiPaths.pairReveal, body: jsonBody({})),
        ),
        401,
        'unauthorized',
      );
      expect(probe.count, 0);
    });

    test('register keeps working next to the routes', () async {
      final probe = RouteProbe(ApiPaths.pairStart);
      final harness = await start([probe]);

      final reply = await harness.send(registerRequest(callerInfoOf(carol)));

      expect(reply!.status, 200);
      expect(
        harness.registrations.single.caller.fingerprint,
        carol.fingerprint,
      );
      expect(probe.count, 0);
    });

    test('the reply has the status and JSON of the handler, in UTF-8 with an '
        'exact length, and closes the connection', () async {
      final probe = RouteProbe(
        ApiPaths.pairConfirm,
        answer: (_) => const ApiReply(202, {'name': 'Portátil €'}),
      );
      final harness = await start([probe]);

      final reply = await harness.send(
        httpRequest('POST', ApiPaths.pairConfirm, body: jsonBody({})),
      );

      expect(reply!.status, 202);
      expect(reply.json, {'name': 'Portátil €'});
      expect(reply.header('content-type'), jsonContentType);
      expect(reply.header('connection'), 'close');
      expect(
        int.parse(reply.header('content-length')!),
        utf8.encode(reply.body).length,
      );
    });

    test('an error status chosen by the handler is sent as is', () async {
      final probe = RouteProbe(
        ApiPaths.pairReveal,
        answer: (_) => const ApiReply(403, {'error': 'forbidden'}),
      );
      final harness = await start([probe]);

      final reply = await harness.send(
        httpRequest('POST', ApiPaths.pairReveal, body: jsonBody({})),
      );

      expectError(reply, 403, 'forbidden');
    });
  });

  group('C26: limit per route and per IP (SEC-07)', () {
    test('13 pair/status in one minute from one IP: the 13th gets 429 and '
        'never reaches the handler', () async {
      final probe = RouteProbe(ApiPaths.pairStatus, limit: _twelvePerMinute);
      final harness = await start([probe]);

      final statuses = <int>[];
      for (var i = 0; i < 12; i++) {
        final reply = await harness.send(
          httpRequest('POST', ApiPaths.pairStatus, body: jsonBody({})),
        );
        statuses.add(reply!.status);
      }
      final thirteenth = await harness.send(
        httpRequest('POST', ApiPaths.pairStatus, body: jsonBody({})),
      );

      expect(statuses, List.filled(12, 200));
      expectError(thirteenth, 429, 'rate_limited');
      expect(probe.count, 12);
    });

    test('a blocked IP gets 429 before its body is looked at: oversized, '
        'broken or empty', () async {
      final probe = RouteProbe(ApiPaths.pairStatus, limit: _twelvePerMinute);
      final harness = await start([probe]);
      for (var i = 0; i < 13; i++) {
        await harness.send(
          httpRequest('POST', ApiPaths.pairStatus, body: jsonBody({})),
        );
      }

      for (final body in [List.filled(9000, 0x20), utf8.encode('{'), <int>[]]) {
        expectError(
          await harness.send(
            httpRequest('POST', ApiPaths.pairStatus, body: body),
          ),
          429,
          'rate_limited',
        );
      }
      expect(probe.count, 12);
    });

    test('another IP is not limited by the first one', () async {
      final probe = RouteProbe(ApiPaths.pairStatus, limit: _twelvePerMinute);
      final harness = await start([probe]);
      for (var i = 0; i < 13; i++) {
        await harness.send(
          httpRequest('POST', ApiPaths.pairStatus, body: jsonBody({})),
        );
      }

      final fromOther = await harness.send(
        httpRequest('POST', ApiPaths.pairStatus, body: jsonBody({})),
        from: otherLoopback,
      );
      final fromThird = await harness.send(
        httpRequest('POST', ApiPaths.pairStatus, body: jsonBody({})),
        from: InternetAddress('127.0.0.3'),
      );

      expect(fromOther!.status, 200);
      expect(fromThird!.status, 200);
      expect(probe.count, 14);
    });

    test('the limit counts the IP, not the certificate: two paired devices '
        'from the same IP share it', () async {
      final probe = RouteProbe(
        ApiPaths.unpair,
        access: RouteAccess.paired,
        limit: _twelvePerMinute,
      );
      final harness = await start([probe], pairedWith: [bob, carol]);

      for (var i = 0; i < 6; i++) {
        for (final who in [bob, carol]) {
          final reply = await harness.send(
            httpRequest('POST', ApiPaths.unpair, body: jsonBody({})),
            context: presenting(who),
          );
          expect(reply!.status, 200);
        }
      }
      final thirteenth = await harness.send(
        httpRequest('POST', ApiPaths.unpair, body: jsonBody({})),
        context: presenting(bob),
      );

      expectError(thirteenth, 429, 'rate_limited');
      expect(probe.count, 12);
    });

    test(
      'each route has its own limiter, and register keeps its own',
      () async {
        final status = RouteProbe(ApiPaths.pairStatus, limit: _twelvePerMinute);
        final wait = RouteProbe(ApiPaths.pairWait, limit: _twelvePerMinute);
        final free = RouteProbe(ApiPaths.pairStart);
        final harness = await start([status, wait, free]);
        for (var i = 0; i < 13; i++) {
          await harness.send(
            httpRequest('POST', ApiPaths.pairStatus, body: jsonBody({})),
          );
        }

        final onWait = await harness.send(
          httpRequest('POST', ApiPaths.pairWait, body: jsonBody({})),
        );
        final onFree = await harness.send(
          httpRequest('POST', ApiPaths.pairStart, body: jsonBody({})),
        );
        final onRegister = await harness.send(
          registerRequest(callerInfoOf(carol)),
        );

        expect(onWait!.status, 200);
        expect(onFree!.status, 200);
        expect(onRegister!.status, 200);
      },
    );

    test('a route without a limit is never limited by the server', () async {
      final probe = RouteProbe(ApiPaths.pairStart);
      final harness = await start([probe]);

      final statuses = <int>{};
      for (var i = 0; i < 35; i++) {
        final reply = await harness.send(
          httpRequest('POST', ApiPaths.pairStart, body: jsonBody({})),
        );
        statuses.add(reply!.status);
      }

      expect(statuses, {200});
      expect(probe.count, 35);
    });

    test('the block lasts the configured time and the route is served '
        'again after it', () async {
      final probe = RouteProbe(ApiPaths.pairStatus, limit: _twelvePerMinute);
      final harness = await start([probe]);
      final start0 = harness.now;
      for (var i = 0; i < 13; i++) {
        await harness.send(
          httpRequest('POST', ApiPaths.pairStatus, body: jsonBody({})),
        );
      }

      harness.now = start0.add(const Duration(seconds: 59));
      final stillBlocked = await harness.send(
        httpRequest('POST', ApiPaths.pairStatus, body: jsonBody({})),
      );
      harness.now = start0.add(const Duration(seconds: 61));
      final served = await harness.send(
        httpRequest('POST', ApiPaths.pairStatus, body: jsonBody({})),
      );

      expectError(stillBlocked, 429, 'rate_limited');
      expect(served!.status, 200);
      expect(probe.count, 13);
    });

    test('12 per minute is per window: 12 more after the window are all '
        'served', () async {
      final probe = RouteProbe(ApiPaths.pairStatus, limit: _twelvePerMinute);
      final harness = await start([probe]);
      final start0 = harness.now;

      final statuses = <int>[];
      for (var i = 0; i < 12; i++) {
        statuses.add(
          (await harness.send(
            httpRequest('POST', ApiPaths.pairStatus, body: jsonBody({})),
          ))!.status,
        );
      }
      harness.now = start0.add(const Duration(seconds: 61));
      for (var i = 0; i < 12; i++) {
        statuses.add(
          (await harness.send(
            httpRequest('POST', ApiPaths.pairStatus, body: jsonBody({})),
          ))!.status,
        );
      }

      expect(statuses, List.filled(24, 200));
    });
  });

  group('C27: bodies (SEC-07)', () {
    test('9000 bytes announced to a pair/ route get 413 and the handler is '
        'not called', () async {
      final probe = RouteProbe(ApiPaths.pairStart);
      final harness = await start([probe]);

      final reply = await harness.send(
        httpRequest(
          'POST',
          ApiPaths.pairStart,
          body: _paddedJson({'a': 1}, 9000),
        ),
      );

      expectError(reply, 413, 'payload_too_large');
      expect(probe.count, 0);
    });

    test('exactly 8192 bytes are accepted and 8193 get 413', () async {
      final probe = RouteProbe(ApiPaths.pairStart);
      final harness = await start([probe]);

      final atLimit = await harness.send(
        httpRequest(
          'POST',
          ApiPaths.pairStart,
          body: _paddedJson({'a': 1}, Limits.maxPairingBodyBytes),
        ),
      );
      final over = await harness.send(
        httpRequest(
          'POST',
          ApiPaths.pairStart,
          body: _paddedJson({'a': 1}, Limits.maxPairingBodyBytes + 1),
        ),
      );

      expect(Limits.maxPairingBodyBytes, 8192);
      expect(atLimit!.status, 200);
      expect(probe.calls.single.json, {'a': 1});
      expectError(over, 413, 'payload_too_large');
      expect(probe.count, 1);
    });

    test('a chunked body without Content-Length is cut at the limit while '
        'reading: 9000 get 413, 8192 are accepted', () async {
      final probe = RouteProbe(ApiPaths.pairStart);
      final harness = await start([probe]);

      final over = await harness.send(
        _chunkedRequest(ApiPaths.pairStart, _paddedJson({'a': 1}, 9000)),
      );
      final atLimit = await harness.send(
        _chunkedRequest(
          ApiPaths.pairStart,
          _paddedJson({'a': 2}, Limits.maxPairingBodyBytes),
        ),
      );

      expectError(over, 413, 'payload_too_large');
      expect(atLimit!.status, 200);
      expect(probe.calls.single.json, {'a': 2});
    });

    test('a route with its own maxBodyBytes uses it, smaller or larger than '
        'the default', () async {
      final small = RouteProbe(ApiPaths.pairCancel, maxBodyBytes: 100);
      final large = RouteProbe(ApiPaths.pairConfirm, maxBodyBytes: 20000);
      final harness = await start([small, large]);

      final smallAt = await harness.send(
        httpRequest(
          'POST',
          ApiPaths.pairCancel,
          body: _paddedJson({'a': 1}, 100),
        ),
      );
      final smallOver = await harness.send(
        httpRequest(
          'POST',
          ApiPaths.pairCancel,
          body: _paddedJson({'a': 1}, 101),
        ),
      );
      final largeOk = await harness.send(
        httpRequest(
          'POST',
          ApiPaths.pairConfirm,
          body: _paddedJson({'a': 1}, 9000),
        ),
      );
      final largeOver = await harness.send(
        httpRequest(
          'POST',
          ApiPaths.pairConfirm,
          body: _paddedJson({'a': 1}, 20001),
        ),
      );

      expect(smallAt!.status, 200);
      expectError(smallOver, 413, 'payload_too_large');
      expect(largeOk!.status, 200);
      expectError(largeOver, 413, 'payload_too_large');
      expect(small.count, 1);
      expect(large.count, 1);
    });

    test('an empty body reaches the handler as json null, with '
        'Content-Length 0 and with no body at all', () async {
      final probe = RouteProbe(ApiPaths.pairWait);
      final harness = await start([probe]);

      final withZero = await harness.send(
        httpRequest('POST', ApiPaths.pairWait, body: const []),
      );
      final withNothing = await harness.send(
        httpRequest('POST', ApiPaths.pairWait),
      );

      expect(withZero!.status, 200);
      expect(withNothing!.status, 200);
      expect(probe.count, 2);
      expect(probe.calls[0].json, isNull);
      expect(probe.calls[1].json, isNull);
    });

    test('broken JSON gets 400 and the handler is not called', () async {
      final probe = RouteProbe(ApiPaths.pairStart);
      final harness = await start([probe]);

      for (final body in [
        utf8.encode('{'),
        utf8.encode('not json'),
        utf8.encode('{"a": 1}x'),
        utf8.encode('{"a": 1,}'),
        [0xff, 0xfe, 0x7b, 0x7d],
        utf8.encode(' '),
      ]) {
        expectError(
          await harness.send(
            httpRequest('POST', ApiPaths.pairStart, body: body),
          ),
          400,
          'bad_request',
        );
      }
      expect(probe.count, 0);
    });

    test(
      'valid JSON that is not an object reaches the handler as is',
      () async {
        final probe = RouteProbe(ApiPaths.pairStart);
        final harness = await start([probe]);

        for (final json in <Object?>[
          [1, 2],
          'text',
          42,
          true,
        ]) {
          final reply = await harness.send(
            httpRequest('POST', ApiPaths.pairStart, body: jsonBody(json)),
          );
          expect(reply!.status, 200, reason: '$json');
        }

        expect(
          [for (final c in probe.calls) c.json],
          [
            [1, 2],
            'text',
            42,
            true,
          ],
        );
      },
    );

    test('a handler that throws gets 500 internal, the log has only the '
        'type and the server goes on', () async {
      final probe = RouteProbe(
        ApiPaths.pairStart,
        answer: (_) => throw StateError(_marker),
      );
      final next = RouteProbe(ApiPaths.pairWait);
      final harness = await start([probe, next]);

      final reply = await harness.send(
        httpRequest('POST', ApiPaths.pairStart, body: jsonBody({})),
      );
      final after = await harness.send(
        httpRequest('POST', ApiPaths.pairWait, body: jsonBody({})),
      );

      expectError(reply, 500, 'internal');
      expect(reply!.body, isNot(contains(_marker)));
      expect(harness.logs.where((l) => l.contains('StateError')), isNotEmpty);
      expect(harness.logs.where((l) => l.contains(_marker)), isEmpty);
      expect(after!.status, 200);
    });

    test('an async failure of the handler, also a FormatException, an Error '
        'or a thrown string, gets 500 and not 400', () async {
      final failures = <Object>[
        const FormatException(_marker),
        ArgumentError(_marker),
        _marker,
      ];
      var index = 0;
      final probe = RouteProbe(
        ApiPaths.pairStart,
        answer: (_) async {
          await Future<void>.delayed(const Duration(milliseconds: 5));
          throw failures[index++];
        },
      );
      final harness = await start([probe]);

      for (var i = 0; i < failures.length; i++) {
        final reply = await harness.send(
          httpRequest('POST', ApiPaths.pairStart, body: jsonBody({})),
        );
        expectError(reply, 500, 'internal');
      }

      expect(harness.logs.where((l) => l.contains(_marker)), isEmpty);
      expect(
        harness.logs.where((l) => l.contains('FormatException')),
        isNotEmpty,
      );
      expect(
        harness.logs.where((l) => l.contains('ArgumentError')),
        isNotEmpty,
      );
      expect(harness.logs.where((l) => l.contains('String')), isNotEmpty);
    });
  });

  group('afterResponse', () {
    test('a synchronous afterResponse runs once, after the reply', () async {
      var runs = 0;
      final probe = RouteProbe(
        ApiPaths.pairCancel,
        answer: (_) => ApiReply(200, {'ok': true}, afterResponse: () => runs++),
      );
      final harness = await start([probe]);

      final reply = await harness.send(
        httpRequest('POST', ApiPaths.pairCancel, body: jsonBody({})),
      );
      await _until(() => runs > 0);
      await Future<void>.delayed(const Duration(milliseconds: 50));

      expect(reply!.status, 200);
      expect(reply.json, {'ok': true});
      expect(runs, 1);
    });

    test('the client has the whole reply and the connection is closed while '
        'an async afterResponse is still running', () async {
      final gate = Completer<void>();
      var started = false;
      var finished = false;
      final probe = RouteProbe(
        ApiPaths.pairCancel,
        answer: (_) => ApiReply(
          200,
          {'ok': true},
          afterResponse: () async {
            started = true;
            await gate.future;
            finished = true;
          },
        ),
      );
      final harness = await start([probe]);

      final reply = await harness.send(
        httpRequest('POST', ApiPaths.pairCancel, body: jsonBody({})),
      );
      await _until(() => started);

      expect(reply!.status, 200);
      expect(reply.json, {'ok': true});
      expect(finished, isFalse);
      gate.complete();
      await _until(() => finished);
      expect(harness.logs.where((l) => l.contains('after response')), isEmpty);
    });

    test('an afterResponse that throws synchronously does not change the '
        'reply, is logged by type and the server goes on', () async {
      final probe = RouteProbe(
        ApiPaths.pairCancel,
        answer: (_) => ApiReply(200, {
          'ok': true,
        }, afterResponse: () => throw StateError(_marker)),
      );
      final next = RouteProbe(ApiPaths.pairWait);
      final harness = await start([probe, next]);

      final reply = await harness.send(
        httpRequest('POST', ApiPaths.pairCancel, body: jsonBody({})),
      );
      await _until(() => harness.logs.any((l) => l.contains('StateError')));
      final after = await harness.send(
        httpRequest('POST', ApiPaths.pairWait, body: jsonBody({})),
      );

      expect(reply!.status, 200);
      expect(reply.json, {'ok': true});
      expect(harness.logs.where((l) => l.contains(_marker)), isEmpty);
      expect(after!.status, 200);
    });

    test('an async afterResponse that throws is caught: logged by type, no '
        'uncaught error, the server goes on', () async {
      final uncaught = <Object>[];
      late ServerHarness harness;
      late Reply? reply;
      late Reply? after;
      await runZonedGuarded(() async {
        final probe = RouteProbe(
          ApiPaths.pairCancel,
          answer: (_) => ApiReply(
            200,
            {'ok': true},
            afterResponse: () async {
              await Future<void>.delayed(const Duration(milliseconds: 20));
              throw StateError(_marker);
            },
          ),
        );
        final next = RouteProbe(ApiPaths.pairWait);
        harness = await start([probe, next]);

        reply = await harness.send(
          httpRequest('POST', ApiPaths.pairCancel, body: jsonBody({})),
        );
        await _until(() => harness.logs.any((l) => l.contains('StateError')));
        after = await harness.send(
          httpRequest('POST', ApiPaths.pairWait, body: jsonBody({})),
        );
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }, (error, _) => uncaught.add(error));

      expect(uncaught, isEmpty);
      expect(reply!.status, 200);
      expect(after!.status, 200);
      expect(harness.logs.where((l) => l.contains(_marker)), isEmpty);
    });

    test('an afterResponse that returns a failed Future without async is '
        'caught too', () async {
      final uncaught = <Object>[];
      late ServerHarness harness;
      late Reply? reply;
      await runZonedGuarded(() async {
        final probe = RouteProbe(
          ApiPaths.pairCancel,
          answer: (_) => ApiReply(
            200,
            {},
            afterResponse: () => Future<void>.error(StateError(_marker)),
          ),
        );
        harness = await start([probe]);

        reply = await harness.send(
          httpRequest('POST', ApiPaths.pairCancel, body: jsonBody({})),
        );
        await _until(() => harness.logs.any((l) => l.contains('StateError')));
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }, (error, _) => uncaught.add(error));

      expect(uncaught, isEmpty);
      expect(reply!.status, 200);
    });

    test('an unpair-like afterResponse that removes the caller and rebuilds '
        'the trust: the caller gets its whole reply, and its next '
        'connection is cut in the handshake (RF-113)', () async {
      late ServerHarness harness;
      var done = false;
      final probe = RouteProbe(
        ApiPaths.unpair,
        access: RouteAccess.paired,
        answer: (call) => ApiReply(
          200,
          {'bye': call.clientFingerprint},
          afterResponse: call.clientFingerprint != bob.fingerprint
              ? null
              : () async {
                  await harness.paired.remove(bob.fingerprint);
                  await harness.server.rebuildTrust();
                  done = true;
                },
        ),
      );
      harness = await start([probe], pairedWith: [bob, carol]);

      final reply = await harness.send(
        httpRequest('POST', ApiPaths.unpair, body: jsonBody({})),
        context: presenting(bob),
      );
      await _until(() => done);
      final again = await harness.send(
        httpRequest('POST', ApiPaths.unpair, body: jsonBody({})),
        context: presenting(bob),
      );
      final carolStill = await harness.send(
        httpRequest('POST', ApiPaths.unpair, body: jsonBody({})),
        context: presenting(carol),
      );

      expect(reply!.status, 200);
      expect(reply.json, {'bye': bob.fingerprint});
      expect(again, isNull);
      expect(carolStill!.status, 200);
      expect(probe.count, 2);
      expect(harness.paired.isPaired(bob.fingerprint), isFalse);
      expect(harness.logs.where((l) => l.contains('failed')), isEmpty);
    });
  });
}
