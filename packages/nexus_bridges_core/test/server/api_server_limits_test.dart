import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:nexus_bridges_core/src/identity/identity.dart';
import 'package:nexus_bridges_core/src/protocol/protocol.dart';
import 'package:test/test.dart';

import 'api_server_harness.dart';

List<int> _paddedRegisterBody(DeviceIdentity caller, int size) {
  final json = jsonBody(callerInfoOf(caller).toJson());
  return [...json, ...List.filled(size - json.length, 0x20)];
}

List<int> _chunk(List<int> data) => [
  ...ascii.encode('${data.length.toRadixString(16)}\r\n'),
  ...data,
  ...ascii.encode('\r\n'),
];

List<int> _chunkedRegisterHead() => ascii.encode(
  'POST $registerPath HTTP/1.1\r\n'
  'host: 127.0.0.1\r\n'
  'transfer-encoding: chunked\r\n'
  '\r\n',
);

int _headerBytes(Map<String, String> headers) =>
    headers.entries.fold(0, (sum, e) => sum + e.key.length + e.value.length);

int _requestLineBytes(String method, String target) =>
    method.length + target.length;

String _head(String method, String target, Map<String, String> headers) {
  final head = StringBuffer('$method $target HTTP/1.1\r\nhost: 127.0.0.1\r\n');
  headers.forEach((name, value) => head.write('$name: $value\r\n'));
  head.write('\r\n');
  return head.toString();
}

typedef _HeadOnly = ({Reply? reply, Duration firstByte, Duration closed});

void main() {
  late DeviceIdentity alice;
  late DeviceIdentity bob;

  setUpAll(() {
    alice = DeviceIdentity.generate(commonName: randomCommonName());
    bob = DeviceIdentity.generate(commonName: randomCommonName());
  });

  Future<ServerHarness> start() => ServerHarness.start(identity: alice);

  void expectError(Reply? reply, int status, String code) {
    expect(reply, isNotNull);
    expect(reply!.status, status);
    expect(reply.json, {'error': code});
    expect(reply.header('content-type'), jsonContentType);
    expect(reply.header('connection'), 'close');
  }

  group('body size (RF-34)', () {
    test('a body of 70000 bytes with Content-Length gets 413 and its content '
        'is never parsed', () async {
      final harness = await start();

      final reply = await harness.send(
        httpRequest('POST', registerPath, body: List.filled(70000, 0x7B)),
      );

      expectError(reply, 413, 'payload_too_large');
      expect(harness.registrations, isEmpty);
    });

    test(
      'a valid presentation padded to 65537 bytes gets 413, not 200',
      () async {
        final harness = await start();

        final reply = await harness.send(
          httpRequest(
            'POST',
            registerPath,
            body: _paddedRegisterBody(bob, Limits.maxBodyBytes + 1),
          ),
        );

        expectError(reply, 413, 'payload_too_large');
        expect(harness.registrations, isEmpty);
      },
    );

    test('a valid body of exactly 65536 bytes is accepted', () async {
      final harness = await start();
      final body = _paddedRegisterBody(bob, Limits.maxBodyBytes);

      final reply = await harness.send(
        httpRequest('POST', registerPath, body: body),
      );

      expect(body, hasLength(65536));
      expect(reply!.status, 200);
      expect(harness.registrations.single.caller.fingerprint, bob.fingerprint);
    });

    test('70000 bytes in chunks without Content-Length get 413', () async {
      final harness = await start();
      final client = await TlsClient.connect(
        harness.port,
        serverFingerprint: alice.fingerprint,
      );

      client.write(_chunkedRegisterHead());
      for (var i = 0; i < 7; i++) {
        client.write(_chunk(List.filled(10000, 0x20)));
      }
      final reply = await client.reply();

      expectError(reply, 413, 'payload_too_large');
      expect(harness.registrations, isEmpty);
    });

    test(
      'control: a valid body in chunks without Content-Length is accepted',
      () async {
        final harness = await start();
        final client = await TlsClient.connect(
          harness.port,
          serverFingerprint: alice.fingerprint,
        );
        final json = jsonBody(callerInfoOf(bob).toJson());

        client.write(_chunkedRegisterHead());
        client.write(_chunk(json.sublist(0, 20)));
        client.write(_chunk(json.sublist(20)));
        client.write(ascii.encode('0\r\n\r\n'));

        expect((await client.reply())!.status, 200);
      },
    );

    test('a chunked body of exactly 65536 bytes is accepted and 65537 gets '
        '413', () async {
      final harness = await start();
      final exact = _paddedRegisterBody(bob, Limits.maxBodyBytes);
      final over = _paddedRegisterBody(bob, Limits.maxBodyBytes + 1);

      Future<Reply?> sendChunked(List<int> body) async {
        final client = await TlsClient.connect(
          harness.port,
          serverFingerprint: alice.fingerprint,
        );
        client.write(_chunkedRegisterHead());
        for (var i = 0; i < body.length; i += 16384) {
          client.write(
            _chunk(body.sublist(i, (i + 16384).clamp(0, body.length))),
          );
        }
        client.write(ascii.encode('0\r\n\r\n'));
        return client.reply();
      }

      expect((await sendChunked(exact))!.status, 200);
      expectError(await sendChunked(over), 413, 'payload_too_large');
      expect(harness.registrations, hasLength(1));
    });
  });

  group('header size (RF-34)', () {
    test('one header of 9000 bytes gets 431', () async {
      final harness = await start();

      final reply = await harness.send(
        httpRequest(
          'POST',
          registerPath,
          body: jsonBody(callerInfoOf(bob).toJson()),
          headers: {'x-big': 'a' * 9000},
        ),
      );

      expectError(reply, 431, 'headers_too_large');
      expect(harness.registrations, isEmpty);
    });

    test('a header of 9000 bytes gets 431 on any route, before access '
        'control', () async {
      final harness = await start();

      final reply = await harness.send(
        httpRequest(
          'GET',
          '$apiPrefix/anything',
          headers: {'x-big': 'a' * 9000},
        ),
      );

      expectError(reply, 431, 'headers_too_large');
    });

    test('the method, the URI and the headers adding up to exactly 8192 bytes '
        'are accepted and one byte more gets 431', () async {
      final harness = await start();
      final body = jsonBody(callerInfoOf(bob).toJson());
      final fixed = {
        'host': '127.0.0.1',
        'content-length': '${body.length}',
        'x-pad': '',
      };
      final padding =
          Limits.maxHeaderBytes -
          _requestLineBytes('POST', registerPath) -
          _headerBytes(fixed);

      final exact = await harness.send(
        httpRequest(
          'POST',
          registerPath,
          body: body,
          headers: {'x-pad': 'a' * padding},
        ),
      );
      final over = await harness.send(
        httpRequest(
          'POST',
          registerPath,
          body: body,
          headers: {'x-pad': 'a' * (padding + 1)},
        ),
      );

      expect(exact!.status, 200);
      expectError(over, 431, 'headers_too_large');
      expect(harness.registrations, hasLength(1));
    });

    test(
      'many small headers adding up to more than 8192 bytes get 431',
      () async {
        final harness = await start();

        final reply = await harness.send(
          httpRequest(
            'POST',
            registerPath,
            body: jsonBody(callerInfoOf(bob).toJson()),
            headers: {for (var i = 0; i < 100; i++) 'x-h$i': 'b' * 90},
          ),
        );

        expectError(reply, 431, 'headers_too_large');
      },
    );

    test('a URI of about 9000 bytes with small headers gets 431 and the '
        'presentation is never registered', () async {
      final harness = await start();

      final reply = await harness.send(
        httpRequest(
          'POST',
          '$registerPath?q=${'a' * 9000}',
          body: jsonBody(callerInfoOf(bob).toJson()),
        ),
      );

      expectError(reply, 431, 'headers_too_large');
      expect(harness.registrations, isEmpty);
    });

    test('a query that brings method, URI and headers to exactly 8192 bytes '
        'is accepted and one byte more gets 431', () async {
      final harness = await start();
      final body = jsonBody(callerInfoOf(bob).toJson());
      final prefix = '$registerPath?q=';
      final padding =
          Limits.maxHeaderBytes -
          _requestLineBytes('POST', prefix) -
          _headerBytes({
            'host': '127.0.0.1',
            'content-length': '${body.length}',
          });

      final exact = await harness.send(
        httpRequest('POST', '$prefix${'a' * padding}', body: body),
      );
      final over = await harness.send(
        httpRequest('POST', '$prefix${'a' * (padding + 1)}', body: body),
      );

      expect(exact!.status, 200);
      expectError(over, 431, 'headers_too_large');
      expect(harness.registrations, hasLength(1));
    });
  });

  group('pending body (QA-M1, RF-34)', () {
    Future<_HeadOnly> sendHeadOnly(
      ServerHarness harness,
      String head, {
      SecurityContext? context,
      List<int> Function()? after,
    }) async {
      final client = await TlsClient.connect(
        harness.port,
        serverFingerprint: alice.fingerprint,
        context: context,
      );
      final watch = Stopwatch()..start();
      client.write(ascii.encode(head));
      await client.dataArrived.timeout(waitLimit);
      final firstByte = watch.elapsed;
      final extra = after?.call();
      if (extra != null) {
        await _wholeReply(client);
        for (var i = 0; i < extra.length; i += 8192) {
          client.write(extra.sublist(i, (i + 8192).clamp(0, extra.length)));
        }
      }
      await client.closed.timeout(waitLimit);
      return (
        reply: Reply.parseFinal(client.received),
        firstByte: firstByte,
        closed: watch.elapsed,
      );
    }

    void expectAtOnce(_HeadOnly result, int status, String code) {
      expectError(result.reply, status, code);
      expect(result.firstByte, lessThan(const Duration(seconds: 2)));
      expect(result.closed, lessThan(const Duration(seconds: 2)));
    }

    test('POST to pair announcing 10 bytes that never come gets 401 at once '
        'and the connection is closed long before 10 s', () async {
      final harness = await start();

      final result = await sendHeadOnly(
        harness,
        _head('POST', '$apiPrefix/pair', {'content-length': '10'}),
      );

      expectAtOnce(result, 401, 'unauthorized');
    });

    test('POST to register announcing 70000 bytes that never come gets 413 '
        'at once', () async {
      final harness = await start();

      final result = await sendHeadOnly(
        harness,
        _head('POST', registerPath, {'content-length': '70000'}),
      );

      expectAtOnce(result, 413, 'payload_too_large');
      expect(harness.registrations, isEmpty);
    });

    test('a header of 9000 bytes with an announced body that never comes '
        'gets 431 at once', () async {
      final harness = await start();

      final result = await sendHeadOnly(
        harness,
        _head('POST', registerPath, {
          'content-length': '10',
          'x-big': 'a' * 9000,
        }),
      );

      expectAtOnce(result, 431, 'headers_too_large');
    });

    test('GET on register with an announced body that never comes gets 405 '
        'at once', () async {
      final harness = await start();

      final result = await sendHeadOnly(
        harness,
        _head('GET', registerPath, {'content-length': '10'}),
      );

      expectAtOnce(result, 405, 'method_not_allowed');
    });

    test('a paired client on an unknown route with an announced body that '
        'never comes gets 404 at once', () async {
      final harness = await ServerHarness.start(
        identity: alice,
        pairedWith: [bob],
      );

      final result = await sendHeadOnly(
        harness,
        _head('POST', '$apiPrefix/anything', {'content-length': '10'}),
        context: presenting(bob),
      );

      expectAtOnce(result, 404, 'not_found');
    });

    test('a blocked IP announcing a body that never comes gets 429 at '
        'once', () async {
      final harness = await start();
      for (var i = 0; i < Limits.registerPerMinute + 1; i++) {
        await harness.send(registerRequest(callerInfoOf(bob)));
      }

      final result = await sendHeadOnly(
        harness,
        _head('POST', registerPath, {'content-length': '10'}),
      );

      expectAtOnce(result, 429, 'rate_limited');
    });

    for (final (target, status, code, length) in [
      (registerPath, 413, 'payload_too_large', '70000'),
      ('$apiPrefix/pair', 401, 'unauthorized', '10'),
    ]) {
      test('with Expect: 100-continue and $length announced bytes that never '
          'come, POST $target gets $status at once', () async {
        final harness = await start();

        final result = await sendHeadOnly(
          harness,
          _head('POST', target, {
            'content-length': length,
            'expect': '100-continue',
          }),
        );

        expectAtOnce(result, status, code);
      });
    }

    test('control: a valid presentation with Expect: 100-continue whose body '
        'is sent after the head gets 200', () async {
      final harness = await start();
      final body = jsonBody(callerInfoOf(bob).toJson());
      final client = await TlsClient.connect(
        harness.port,
        serverFingerprint: alice.fingerprint,
      );

      client.write(
        ascii.encode(
          _head('POST', registerPath, {
            'content-length': '${body.length}',
            'expect': '100-continue',
          }),
        ),
      );
      await Future<void>.delayed(const Duration(milliseconds: 200));
      client.write(body);
      await client.reply();

      expect(Reply.parseFinal(client.received)!.status, 200);
      expect(harness.registrations, hasLength(1));
    });

    test('a body of 1 MB sent after the 401 is thrown away, the connection '
        'still closes at once and the server keeps serving', () async {
      final harness = await start();

      final result = await sendHeadOnly(
        harness,
        _head('POST', '$apiPrefix/pair', {'content-length': '1048576'}),
        after: () => List.filled(1048576, 0x41),
      );
      final next = await harness.send(registerRequest(callerInfoOf(bob)));

      expectAtOnce(result, 401, 'unauthorized');
      expect(next!.status, 200);
    });

    test('the 70000 announced bytes sent after the 413 do not change the '
        'reply and the server keeps serving', () async {
      final harness = await start();

      final result = await sendHeadOnly(
        harness,
        _head('POST', registerPath, {'content-length': '70000'}),
        after: () => List.filled(70000, 0x7B),
      );
      final next = await harness.send(registerRequest(callerInfoOf(bob)));

      expectAtOnce(result, 413, 'payload_too_large');
      expect(next!.status, 200);
      expect(harness.registrations, hasLength(1));
    });

    test('the 413 reaches a client that keeps sending its 70000 bytes in '
        'pieces after the server has answered', () async {
      final harness = await start();
      final client = await TlsClient.connect(
        harness.port,
        serverFingerprint: alice.fingerprint,
      );

      client.write(
        ascii.encode(_head('POST', registerPath, {'content-length': '70000'})),
      );
      for (var i = 0; i < 4; i++) {
        client.write(List.filled(17500, 0x7B));
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
      final reply = await client.reply();

      expectError(reply, 413, 'payload_too_large');
      expect(harness.registrations, isEmpty);
    });
  });

  group('deadline (RF-35)', () {
    test(
      'a request that arrives in pieces within the deadline is served',
      () async {
        final harness = await start();
        final client = await TlsClient.connect(
          harness.port,
          serverFingerprint: alice.fingerprint,
        );
        final request = registerRequest(callerInfoOf(bob));

        client.write(request.sublist(0, 30));
        await Future<void>.delayed(const Duration(milliseconds: 300));
        client.write(request.sublist(30, request.length - 10));
        await Future<void>.delayed(const Duration(milliseconds: 300));
        client.write(request.sublist(request.length - 10));

        expect((await client.reply())!.status, 200);
      },
    );

    test(
      'a body sent one byte per second and a client that sends nothing are '
      'closed at 10 s from the accept, not at 20 s',
      () async {
        final harness = await start();

        final silentWatch = Stopwatch()..start();
        final silent = await Socket.connect(loopback, harness.port);
        addTearDown(silent.destroy);
        silent.done.ignore();
        final silentReceived = <int>[];
        final silentClosed = silent
            .listen(silentReceived.addAll, cancelOnError: true)
            .asFuture<void>()
            .then((_) {}, onError: (Object _) {})
            .then((_) => silentWatch.elapsed);

        final slowWatch = Stopwatch()..start();
        final slow = await TlsClient.connect(
          harness.port,
          serverFingerprint: alice.fingerprint,
        );
        slow.write(
          ascii.encode(
            'POST $registerPath HTTP/1.1\r\n'
            'host: 127.0.0.1\r\n'
            'content-length: 1000\r\n'
            '\r\n',
          ),
        );
        var sent = 0;
        final trickle = Timer.periodic(const Duration(seconds: 1), (_) {
          slow.write(const [0x20]);
          sent++;
        });
        addTearDown(trickle.cancel);
        final slowClosed = slow.closed.then((_) => slowWatch.elapsed);

        final elapsed = await Future.wait([slowClosed, silentClosed])
            .timeout(const Duration(seconds: 15));
        trickle.cancel();

        expect(elapsed, hasLength(2));
        for (final e in elapsed) {
          expect(e, greaterThanOrEqualTo(const Duration(seconds: 9)));
          expect(e, lessThanOrEqualTo(const Duration(seconds: 11)));
        }
        expect(sent, greaterThanOrEqualTo(8));
        expect(Reply.parse(slow.received), isNull);
        expect(silentReceived, isEmpty);
        expect(harness.registrations, isEmpty);
      },
      tags: 'slow',
      timeout: const Timeout(Duration(seconds: 25)),
    );
  });

  group('presentation rate (RF-36)', () {
    test(
      'the 31st presentation from the same IP gets 429, the next one too, '
      'another IP is still served and 61 s later it is accepted again',
      () async {
        final harness = await start();
        final request = registerRequest(callerInfoOf(bob));
        final replies = <Reply?>[];

        for (var i = 0; i < 31; i++) {
          replies.add(await harness.send(request));
        }
        final thirtySecond = await harness.send(request);
        final otherIp = await harness.send(request, from: otherLoopback);
        harness.now = harness.now.add(const Duration(seconds: 59));
        final stillBlocked = await harness.send(request);
        harness.now = harness.now.add(const Duration(seconds: 2));
        final again = await harness.send(request);

        expect(replies.take(30).map((r) => r?.status), everyElement(200));
        expectError(replies[30], 429, 'rate_limited');
        expectError(thirtySecond, 429, 'rate_limited');
        expect(otherIp!.status, 200);
        expectError(stillBlocked, 429, 'rate_limited');
        expect(again!.status, 200);
        expect(harness.registrations, hasLength(32));
      },
    );

    test('a blocked IP gets 429 even with a broken body, which is never '
        'parsed', () async {
      final harness = await start();
      for (var i = 0; i < 31; i++) {
        await harness.send(registerRequest(callerInfoOf(bob)));
      }

      final reply = await harness.send(
        httpRequest('POST', registerPath, body: utf8.encode('{broken')),
      );

      expectError(reply, 429, 'rate_limited');
    });

    test(
      'the limit only counts presentations: other routes are not limited',
      () async {
        final harness = await start();
        final statuses = <int?>[];

        for (var i = 0; i < 35; i++) {
          statuses.add(
            (await harness.send(httpRequest('GET', '$apiPrefix/anything')))
                ?.status,
          );
        }
        final register = await harness.send(registerRequest(callerInfoOf(bob)));

        expect(statuses, everyElement(401));
        expect(register!.status, 200);
      },
    );
  });
}

Future<void> _wholeReply(TlsClient client) async {
  final deadline = DateTime.now().add(waitLimit);
  while (DateTime.now().isBefore(deadline)) {
    final bytes = client.received;
    final text = latin1.decode(bytes);
    final end = text.indexOf('\r\n\r\n');
    if (end >= 0) {
      final match = RegExp(
        r'content-length:\s*(\d+)',
        caseSensitive: false,
      ).firstMatch(text.substring(0, end));
      final length = match == null ? 0 : int.parse(match.group(1)!);
      if (bytes.length - (end + 4) >= length) return;
    }
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}
