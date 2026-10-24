import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:nexus_bridges_core/src/identity/identity.dart';
import 'package:nexus_bridges_core/src/pairing/pairing.dart';
import 'package:nexus_bridges_core/src/protocol/protocol.dart';
import 'package:nexus_bridges_core/src/server/server.dart';
import 'package:nexus_bridges_core/src/storage/storage.dart';
import 'package:nexus_bridges_core/src/transport/transport.dart';
import 'package:test/test.dart';

import 'api_server_harness.dart';

const String _uploadPath = ApiPaths.transferUpload;
const String _jsonPath = ApiPaths.transferOffer;
const String _transferValue = '0123456789abcdef0123456789abcdef';
const String _presentedValue = 'fedcba9876543210fedcba9876543210';
const String _relaxedValue = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
const int _kib = 1024;
const int _mib = 1024 * 1024;
const Duration _settle = Duration(milliseconds: 300);
const Duration _short = Duration(seconds: 2);
const Map<String, Object?> _forbidden = {'error': 'forbidden'};

const Map<String, String> _uploadHeaders = {
  TransferHeaders.transfer: _transferValue,
  TransferHeaders.permit: _presentedValue,
};

Uint8List _pattern(int length, {int seed = 0}) {
  final out = Uint8List(length);
  for (var i = 0; i < length; i++) {
    out[i] = (i * 31 + seed) % 251;
  }
  return out;
}

Stream<List<int>> _chunked(Uint8List data, {int size = 64 * _kib}) async* {
  for (var i = 0; i < data.length; i += size) {
    yield Uint8List.sublistView(data, i, min(i + size, data.length));
  }
}

Stream<List<int>> _slow(int chunks, Duration every, {int size = 10}) async* {
  for (var i = 0; i < chunks; i++) {
    await Future<void>.delayed(every);
    yield _pattern(size, seed: i);
  }
}

String _describe(StreamPostResult result) => switch (result) {
  StreamPostAnswered(:final response, :final bodyComplete) =>
    'answered ${response.status} ${bodyComplete ? 'complete' : 'partial'}',
  StreamPostFailed(:final failure) => 'failed ${failure.name}',
};

Future<void> _until(
  bool Function() condition, {
  Duration limit = waitLimit,
}) async {
  final stopwatch = Stopwatch()..start();
  while (!condition()) {
    if (stopwatch.elapsed > limit) throw TimeoutException('condition');
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}

final class _Sink {
  final BytesBuilder bytes = BytesBuilder();
  int dones = 0;
  int errors = 0;
  final Completer<void> _ended = Completer<void>();

  Future<void> get ended => _ended.future;

  int get terminals => dones + errors;

  void attach(UploadBody body) {
    body.listen(
      onData: bytes.add,
      onDone: () {
        dones++;
        _end();
      },
      onError: (Object _) {
        errors++;
        _end();
      },
    );
  }

  void _end() {
    if (!_ended.isCompleted) _ended.complete();
  }
}

typedef _Handle = Future<ApiReply> Function(ApiUpload upload);

final class _Bench {
  _Bench._(this.identity, this.paired, this.dir);

  final DeviceIdentity identity;
  final PairedDevicesStore paired;
  final Directory dir;
  final List<String> logs = [];
  final List<ApiUpload> uploads = [];
  late final ApiServer server;
  late _Handle handle;

  int get port => server.boundPort!;

  static Future<_Bench> start({
    required Iterable<DeviceIdentity> pairedWith,
    _Handle? handle,
    List<ApiRoute> routes = const [],
    RouteLimit? limit,
  }) async {
    final identity = DeviceIdentity.generate();
    final dir = await Directory.systemTemp.createTemp('nexus_upload_');
    addTearDown(() => dir.delete(recursive: true));
    final store = PairedDevicesStore(
      JsonFileStore(File('${dir.path}${Platform.pathSeparator}paired.json')),
      ownerFingerprint: identity.fingerprint,
    );
    await store.load();
    await store.replaceAll([for (final p in pairedWith) pairedDeviceOf(p)]);
    final bench = _Bench._(identity, store, dir);
    bench.handle =
        handle ?? (_) async => const ApiReply(200, {'state': 'saved'});
    bench.server = ApiServer(
      identity: identity,
      paired: store,
      routes: routes,
      uploadRoutes: [
        ApiUploadRoute(path: _uploadPath, handle: bench._route, limit: limit),
      ],
      selfInfo: () => selfInfoOf(identity),
      onRegistered: (_, _, _) {},
      port: 0,
      log: bench.logs.add,
    );
    addTearDown(bench.server.close);
    await bench.server.syncInterfaces([loopbackInterface()]);
    return bench;
  }

  Future<ApiReply> _route(ApiUpload upload) {
    uploads.add(upload);
    return handle(upload);
  }

  Future<StreamPostResult> post(
    SecurityContext context,
    Stream<List<int>> body,
    int length, {
    Map<String, String> headers = _uploadHeaders,
    Duration idle = waitLimit,
    Duration answer = waitLimit,
    void Function(int sent)? onProgress,
    void Function()? onBodySent,
  }) => postStream(
    address: loopback,
    port: port,
    path: _uploadPath,
    headers: headers,
    contentLength: length,
    body: body,
    context: context,
    acceptServer: (certificate) =>
        certificateMatches(certificate, identity.fingerprint),
    idleTimeout: idle,
    answerTimeout: answer,
    onProgress: onProgress,
    onBodySent: onBodySent,
  );

  Future<TlsClient> raw(SecurityContext context) => TlsClient.connect(
    port,
    serverFingerprint: identity.fingerprint,
    context: context,
  );

  List<String> files() => [
    for (final entity in dir.listSync(recursive: true))
      entity.path.substring(dir.path.length + 1),
  ];
}

SecurityContext _as(DeviceIdentity identity) =>
    identity.clientContext(presentCertificate: true);

List<int> _uploadHead({
  required int contentLength,
  Map<String, String> headers = _uploadHeaders,
}) => httpRequest(
  'POST',
  _uploadPath,
  headers: {...headers, 'content-length': '$contentLength'},
);

void main() {
  late DeviceIdentity client;
  late DeviceIdentity stranger;

  setUpAll(() {
    client = DeviceIdentity.generate();
    stranger = DeviceIdentity.generate();
  });

  group('E45 (RF-139, RF-165): postStream against a real upload route', () {
    test(
      '3 MiB arrive byte for byte, onProgress grows to 3 MiB, onBodySent '
      'fires once and the answer is Answered(200, bodyComplete: true)',
      () async {
        final sink = _Sink();
        final relaxed = <bool>[];
        final bench = await _Bench.start(
          pairedWith: [client],
          handle: (upload) async {
            relaxed.add(upload.keepAlive());
            sink.attach(upload.body);
            await sink.ended;
            return const ApiReply(200, {'state': 'saved', 'marked': true});
          },
        );
        final data = _pattern(3 * _mib);
        final progress = <int>[];
        var bodySent = 0;

        final result = await bench.post(
          _as(client),
          _chunked(data),
          data.length,
          onProgress: progress.add,
          onBodySent: () => bodySent++,
        );

        expect(_describe(result), 'answered 200 complete');
        final response = (result as StreamPostAnswered).response;
        expect(jsonDecode(utf8.decode(response.body)), {
          'state': 'saved',
          'marked': true,
        });
        final received = sink.bytes.toBytes();
        expect(received.length, data.length);
        expect(received, orderedEquals(data));
        expect(sink.dones, 1);
        expect(sink.errors, 0);
        expect(relaxed, [true]);
        expect(progress, isNotEmpty);
        for (var i = 1; i < progress.length; i++) {
          expect(progress[i], greaterThan(progress[i - 1]));
        }
        expect(progress.last, data.length);
        expect(bodySent, 1);
      },
    );

    test('the handler sees the path, the client fingerprint, the origin, the '
        'interface, the announced length and the transfer headers', () async {
      final sink = _Sink();
      final bench = await _Bench.start(
        pairedWith: [client],
        handle: (upload) async {
          sink.attach(upload.body);
          await sink.ended;
          return const ApiReply(200, {});
        },
      );

      final result = await bench.post(
        _as(client),
        _chunked(_pattern(1000)),
        1000,
      );

      expect(_describe(result), 'answered 200 complete');
      final upload = bench.uploads.single;
      expect(upload.path, _uploadPath);
      expect(upload.clientFingerprint, client.fingerprint);
      expect(upload.remoteAddress, loopback);
      expect(upload.via.id, loopbackInterface().id);
      expect(upload.contentLength, 1000);
      expect(upload.headers, _uploadHeaders);
    });

    test('an empty body (0 bytes) reaches the handler with contentLength 0 '
        'and a single onDone', () async {
      final sink = _Sink();
      final bench = await _Bench.start(
        pairedWith: [client],
        handle: (upload) async {
          sink.attach(upload.body);
          await sink.ended;
          return const ApiReply(200, {});
        },
      );
      var bodySent = 0;

      final result = await bench.post(
        _as(client),
        const Stream<List<int>>.empty(),
        0,
        onBodySent: () => bodySent++,
      );

      expect(_describe(result), 'answered 200 complete');
      expect(bench.uploads.single.contentLength, 0);
      expect(sink.bytes.length, 0);
      expect(sink.dones, 1);
      expect(sink.errors, 0);
      expect(bodySent, 1);
    });

    test('afterResponse of an upload reply runs once, after the answer has '
        'reached the client', () async {
      final sink = _Sink();
      var after = 0;
      final bench = await _Bench.start(
        pairedWith: [client],
        handle: (upload) async {
          sink.attach(upload.body);
          await sink.ended;
          return ApiReply(200, const {}, afterResponse: () => after++);
        },
      );

      final result = await bench.post(_as(client), _chunked(_pattern(10)), 10);

      expect(_describe(result), 'answered 200 complete');
      await _until(() => after > 0);
      await Future<void>.delayed(_settle);
      expect(after, 1);
    });
  });

  group('upload headers (plan, server: "headers")', () {
    test('only x-nexusbridges-* headers with a single value reach the '
        'handler, with lower case names', () async {
      final sink = _Sink();
      final bench = await _Bench.start(
        pairedWith: [client],
        handle: (upload) async {
          sink.attach(upload.body);
          await sink.ended;
          return const ApiReply(200, {});
        },
      );
      final raw = await bench.raw(_as(client));
      final head = StringBuffer(
        'POST $_uploadPath HTTP/1.1\r\n'
        'host: 127.0.0.1\r\n'
        'content-length: 4\r\n'
        'X-NexusBridges-Transfer: $_transferValue\r\n'
        'x-nexusbridges-permit: one\r\n'
        'x-nexusbridges-permit: two\r\n'
        'X-NEXUSBRIDGES-EXTRA: e\r\n'
        'x-other: z\r\n'
        'authorization: none\r\n'
        '\r\n',
      );

      raw.write([...utf8.encode(head.toString()), 1, 2, 3, 4]);
      final reply = await raw.reply();

      expect(reply?.status, 200);
      expect(bench.uploads.single.headers, {
        TransferHeaders.transfer: _transferValue,
        'x-nexusbridges-extra': 'e',
      });
      expect(sink.bytes.toBytes(), [1, 2, 3, 4]);
    });

    test('without Content-Length the handler sees contentLength -1', () async {
      final bench = await _Bench.start(
        pairedWith: [client],
        handle: (_) async => const ApiReply(403, _forbidden),
      );
      final raw = await bench.raw(_as(client));

      raw.write(httpRequest('POST', _uploadPath, headers: _uploadHeaders));
      final reply = await raw.reply();

      expect(reply?.status, 403);
      expect(bench.uploads.single.contentLength, -1);
    });
  });

  group('E42: the upload body waits paused until the route listens', () {
    test('a route that waits 200 ms before listening receives every byte, in '
        'order', () async {
      final sink = _Sink();
      final bench = await _Bench.start(
        pairedWith: [client],
        handle: (upload) async {
          await Future<void>.delayed(const Duration(milliseconds: 200));
          sink.attach(upload.body);
          await sink.ended;
          return const ApiReply(200, {});
        },
      );
      final data = _pattern(2 * _mib, seed: 7);

      final result = await bench.post(_as(client), _chunked(data), data.length);

      expect(_describe(result), 'answered 200 complete');
      expect(sink.bytes.toBytes(), orderedEquals(data));
      expect(sink.dones, 1);
    });

    test(
      'resume before listen does not start the body: nothing is lost',
      () async {
        final sink = _Sink();
        final bench = await _Bench.start(
          pairedWith: [client],
          handle: (upload) async {
            upload.body.resume();
            upload.body.resume();
            await Future<void>.delayed(const Duration(milliseconds: 200));
            sink.attach(upload.body);
            await sink.ended;
            return const ApiReply(200, {});
          },
        );
        final data = _pattern(300000, seed: 3);

        final result = await bench.post(
          _as(client),
          _chunked(data),
          data.length,
        );

        expect(_describe(result), 'answered 200 complete');
        expect(sink.bytes.toBytes(), orderedEquals(data));
      },
    );

    test('pause and resume while streaming keep every byte in order', () async {
      final received = BytesBuilder();
      final ended = Completer<void>();
      var pauses = 0;
      final bench = await _Bench.start(
        pairedWith: [client],
        handle: (upload) async {
          upload.body.listen(
            onData: (chunk) {
              received.add(chunk);
              if (pauses < 3) {
                pauses++;
                upload.body.pause();
                Timer(const Duration(milliseconds: 100), upload.body.resume);
              }
            },
            onDone: ended.complete,
            onError: (Object _) => ended.complete(),
          );
          await ended.future;
          return const ApiReply(200, {});
        },
      );
      final data = _pattern(1 * _mib, seed: 11);

      final result = await bench.post(_as(client), _chunked(data), data.length);

      expect(_describe(result), 'answered 200 complete');
      expect(pauses, 3);
      expect(received.toBytes(), orderedEquals(data));
    });
  });

  group('UploadBody.listen gives a single terminal notice', () {
    test('a complete body gives onDone once and onError never', () async {
      final sink = _Sink();
      final bench = await _Bench.start(
        pairedWith: [client],
        handle: (upload) async {
          sink.attach(upload.body);
          await sink.ended;
          return const ApiReply(200, {});
        },
      );

      await bench.post(_as(client), _chunked(_pattern(5000)), 5000);
      await Future<void>.delayed(_settle);

      expect(sink.dones, 1);
      expect(sink.errors, 0);
    });

    test(
      'a client that vanishes mid body gives exactly one terminal notice',
      () async {
        final sink = _Sink();
        final bench = await _Bench.start(
          pairedWith: [client],
          handle: (upload) async {
            upload.keepAlive();
            sink.attach(upload.body);
            await sink.ended;
            return const ApiReply(200, {});
          },
        );
        final raw = await bench.raw(_as(client));

        raw.write([..._uploadHead(contentLength: 1000), ..._pattern(100)]);
        await _until(() => sink.bytes.length >= 100);
        await raw.socket.close();
        raw.socket.destroy();
        await sink.ended.timeout(waitLimit);
        await Future<void>.delayed(_settle);

        expect(sink.terminals, 1);
        expect(sink.bytes.length, 100);
      },
    );
  });

  group('E41 / RF-216 [SEG]: upload routes are only for paired devices', () {
    test('without a client certificate the answer is 401 and the route is '
        'never called', () async {
      final bench = await _Bench.start(pairedWith: [client]);

      final result = await bench.post(
        client.clientContext(),
        _chunked(_pattern(100)),
        100,
      );

      expect(result, isA<StreamPostAnswered>());
      final response = (result as StreamPostAnswered).response;
      expect(response.status, 401);
      expect(jsonDecode(utf8.decode(response.body)), {'error': 'unauthorized'});
      await Future<void>.delayed(_settle);
      expect(bench.uploads, isEmpty);
    });

    test('a certificate that is not paired is cut in the handshake and the '
        'route is never called', () async {
      final bench = await _Bench.start(pairedWith: [client]);

      final result = await bench.post(
        _as(stranger),
        _chunked(_pattern(100)),
        100,
      );

      expect(result, isA<StreamPostFailed>());
      expect(
        (result as StreamPostFailed).failure,
        isIn([
          StreamPostFailure.notConnected,
          StreamPostFailure.connectionLost,
        ]),
      );
      await Future<void>.delayed(_settle);
      expect(bench.uploads, isEmpty);
    });

    test(
      'control: the paired client with its certificate reaches the route',
      () async {
        final sink = _Sink();
        final bench = await _Bench.start(
          pairedWith: [client],
          handle: (upload) async {
            sink.attach(upload.body);
            await sink.ended;
            return const ApiReply(200, {});
          },
        );

        final result = await bench.post(
          _as(client),
          _chunked(_pattern(100)),
          100,
        );

        expect(_describe(result), 'answered 200 complete');
        expect(bench.uploads, hasLength(1));
      },
    );

    test(
      'a GET on the upload path is 405 and never reaches the route',
      () async {
        final bench = await _Bench.start(pairedWith: [client]);
        final raw = await bench.raw(_as(client));

        raw.write(httpRequest('GET', _uploadPath, headers: _uploadHeaders));
        final reply = await raw.reply();

        expect(reply?.status, 405);
        expect(bench.uploads, isEmpty);
      },
    );

    test('the route limit answers 429 without calling the route', () async {
      final sink = _Sink();
      final bench = await _Bench.start(
        pairedWith: [client],
        limit: const RouteLimit(
          maxPerWindow: 1,
          window: Duration(minutes: 1),
          block: Duration(minutes: 1),
        ),
        handle: (upload) async {
          sink.attach(upload.body);
          await sink.ended;
          return const ApiReply(200, {});
        },
      );

      final first = await bench.post(_as(client), _chunked(_pattern(10)), 10);
      final second = await bench.post(_as(client), _chunked(_pattern(10)), 10);

      expect(_describe(first), 'answered 200 complete');
      expect(_describe(second), 'answered 429 complete');
      expect(bench.uploads, hasLength(1));
    });

    test('the presented permit never appears in an answer or a log, whatever '
        'the failure', () async {
      final bench = await _Bench.start(
        pairedWith: [client],
        limit: const RouteLimit(
          maxPerWindow: 1,
          window: Duration(minutes: 1),
          block: Duration(minutes: 1),
        ),
        handle: (upload) async =>
            throw StateError(upload.headers[TransferHeaders.permit]!),
      );
      final texts = <String>[];

      Future<void> rawExchange(SecurityContext context, List<int> bytes) async {
        final raw = await bench.raw(context);
        raw.write(bytes);
        try {
          await raw.closed.timeout(waitLimit);
        } on TimeoutException {
          return;
        }
        texts.add(latin1.decode(raw.received));
      }

      final body = _pattern(64);
      await rawExchange(client.clientContext(), [
        ..._uploadHead(contentLength: body.length),
        ...body,
      ]);
      await rawExchange(
        _as(client),
        httpRequest('GET', _uploadPath, headers: _uploadHeaders),
      );
      await rawExchange(_as(client), [
        ..._uploadHead(contentLength: body.length),
        ...body,
      ]);
      await rawExchange(_as(client), [
        ..._uploadHead(contentLength: body.length),
        ...body,
      ]);
      await Future<void>.delayed(_settle);

      expect(texts.where((t) => t.contains(' 401 ')), isNotEmpty);
      expect(texts.where((t) => t.contains(' 405 ')), isNotEmpty);
      expect(texts.where((t) => t.contains(' 429 ')), isNotEmpty);
      expect(bench.uploads, hasLength(1));
      expect(bench.logs, contains('upload route failed: StateError'));
      for (final text in [...texts, ...bench.logs]) {
        expect(text, isNot(contains(_presentedValue)));
      }
      expect(bench.uploads.single.toString(), isNot(contains(_presentedValue)));
    });
  });

  group('[SEG] RF-165: bytes beyond the announced length are cut', () {
    test(
      'a raw client that sends more than its Content-Length: the route '
      'gets exactly the announced bytes and one onDone, and only one call',
      () async {
        final sink = _Sink();
        final bench = await _Bench.start(
          pairedWith: [client],
          handle: (upload) async {
            sink.attach(upload.body);
            await sink.ended;
            return const ApiReply(200, {});
          },
        );
        final raw = await bench.raw(_as(client));
        final announced = _pattern(100, seed: 1);
        final extra = _pattern(5000, seed: 2);

        raw.write([..._uploadHead(contentLength: 100), ...announced, ...extra]);
        await sink.ended.timeout(waitLimit);
        await raw.closed.timeout(waitLimit);
        await Future<void>.delayed(_settle);

        expect(sink.bytes.toBytes(), announced);
        expect(sink.dones, 1);
        expect(sink.errors, 0);
        expect(bench.uploads, hasLength(1));
      },
    );
  });

  group('E40: the relaxed deadline of an upload', () {
    test(
      'keepAlive with a chunk every 2 s for 16 s completes; the same upload '
      'without keepAlive and a slow JSON body are both cut at 10 s',
      () async {
        final sinks = <String, _Sink>{};
        final bench = await _Bench.start(
          pairedWith: [client],
          routes: [
            ApiRoute(
              path: _jsonPath,
              access: RouteAccess.paired,
              handle: (_) async => const ApiReply(200, {}),
            ),
          ],
          handle: (upload) async {
            final name = upload.headers[TransferHeaders.transfer]!;
            if (name == _relaxedValue) upload.keepAlive();
            final sink = sinks[name] = _Sink();
            sink.attach(upload.body);
            await sink.ended;
            return const ApiReply(200, {'state': 'saved'});
          },
        );
        const every = Duration(seconds: 2);

        Future<(StreamPostResult, Duration)> timed(String transfer) async {
          final stopwatch = Stopwatch()..start();
          final result = await bench.post(
            _as(client),
            _slow(8, every),
            80,
            headers: {TransferHeaders.transfer: transfer},
            idle: const Duration(seconds: 20),
          );
          return (result, stopwatch.elapsed);
        }

        Future<(bool, Duration)> slowJson() async {
          final stopwatch = Stopwatch()..start();
          final raw = await bench.raw(_as(client));
          raw.write(
            httpRequest('POST', _jsonPath, headers: {'content-length': '80'}),
          );
          for (var i = 0; i < 8 && !raw.isClosed; i++) {
            await Future<void>.delayed(every);
            raw.write(utf8.encode('          '));
          }
          await raw.closed.timeout(const Duration(seconds: 30));
          final reply = Reply.parse(raw.received);
          return (reply?.status == 200, stopwatch.elapsed);
        }

        final relaxed = timed(_relaxedValue);
        final strict = timed(_transferValue);
        final json = slowJson();

        final (relaxedResult, relaxedTime) = await relaxed;
        final (strictResult, strictTime) = await strict;
        final (jsonAnswered, jsonTime) = await json;

        expect(_describe(relaxedResult), 'answered 200 complete');
        expect(relaxedTime, greaterThan(const Duration(seconds: 15)));
        expect(sinks[_relaxedValue]!.bytes.length, 80);
        expect(_describe(strictResult), 'failed connectionLost');
        expect(strictTime, greaterThan(const Duration(milliseconds: 9500)));
        expect(strictTime, lessThan(const Duration(seconds: 13)));
        expect(jsonAnswered, isFalse);
        expect(jsonTime, greaterThan(const Duration(milliseconds: 9500)));
        expect(jsonTime, lessThan(const Duration(seconds: 13)));
      },
      timeout: const Timeout(Duration(seconds: 60)),
    );

    test('three keepAlive at once: two give true and the third false; once '
        'they end, the slots are free again', () async {
      final gate = Completer<void>();
      final answers = <bool>[];
      final bench = await _Bench.start(
        pairedWith: [client],
        handle: (upload) async {
          answers.add(upload.keepAlive());
          await gate.future;
          final sink = _Sink()..attach(upload.body);
          await sink.ended;
          return const ApiReply(200, {});
        },
      );

      final pending = [
        for (var i = 0; i < 3; i++)
          bench.post(_as(client), _chunked(_pattern(5)), 5),
      ];
      await _until(() => answers.length == 3);

      expect(answers.where((a) => a), hasLength(2));
      expect(answers.where((a) => !a), hasLength(1));
      gate.complete();
      final results = await Future.wait(pending);
      expect(results.map(_describe), everyElement('answered 200 complete'));

      answers.clear();
      final again = await Future.wait([
        for (var i = 0; i < 2; i++)
          bench.post(_as(client), _chunked(_pattern(5)), 5),
      ]);
      expect(again.map(_describe), everyElement('answered 200 complete'));
      expect(answers, [true, true]);
    });

    test('a second keepAlive on the same connection gives false and does not '
        'take another slot', () async {
      final gate = Completer<void>();
      final answers = <List<bool>>[];
      final bench = await _Bench.start(
        pairedWith: [client],
        handle: (upload) async {
          answers.add([upload.keepAlive(), upload.keepAlive()]);
          await gate.future;
          final sink = _Sink()..attach(upload.body);
          await sink.ended;
          return const ApiReply(200, {});
        },
      );

      final pending = [
        for (var i = 0; i < 2; i++)
          bench.post(_as(client), _chunked(_pattern(5)), 5),
      ];
      await _until(() => answers.length == 2);
      gate.complete();
      await Future.wait(pending);

      expect(answers, [
        [true, false],
        [true, false],
      ]);
    });

    Future<void> cutWhileStreaming(
      Future<void> Function(_Bench bench, ApiUpload upload) cut,
    ) async {
      final sink = _Sink();
      var undelivered = 0;
      late final _Bench bench;
      bench = await _Bench.start(
        pairedWith: [client],
        handle: (upload) async {
          upload.keepAlive();
          sink.attach(upload.body);
          await _until(() => sink.bytes.length > 0);
          await cut(bench, upload);
          await sink.ended.timeout(waitLimit);
          return ApiReply(200, const {}, onUndelivered: () => undelivered++);
        },
      );
      final stopwatch = Stopwatch()..start();

      final result = await bench.post(
        _as(client),
        _slow(50, const Duration(milliseconds: 100)),
        500,
      );

      expect(_describe(result), 'failed connectionLost');
      expect(stopwatch.elapsed, lessThan(const Duration(seconds: 3)));
      await Future<void>.delayed(_settle);
      expect(sink.terminals, 1);
      expect(sink.bytes.length, lessThan(500));
    }

    test('cut() closes a relaxed connection at once', () async {
      await cutWhileStreaming((_, upload) async => upload.cut());
    });

    test('unpairing the client drops its relaxed upload at once '
        '(dropConnections)', () async {
      await cutWhileStreaming((bench, _) async {
        await bench.paired.replaceAll([]);
        await bench.server.rebuildTrust();
      });
    });

    test('losing the interface drops a relaxed upload at once', () async {
      await cutWhileStreaming((bench, _) => bench.server.syncInterfaces([]));
    });

    test('closing the server drops a relaxed upload at once', () async {
      await cutWhileStreaming((bench, _) => bench.server.close());
    });

    test('a relaxed upload of another paired device survives the unpairing '
        'of a third one', () async {
      final other = DeviceIdentity.generate();
      final sink = _Sink();
      final started = Completer<void>();
      late final _Bench bench;
      bench = await _Bench.start(
        pairedWith: [client, other],
        handle: (upload) async {
          upload.keepAlive();
          sink.attach(upload.body);
          if (!started.isCompleted) started.complete();
          await sink.ended;
          return const ApiReply(200, {});
        },
      );

      final pending = bench.post(
        _as(client),
        _slow(10, const Duration(milliseconds: 100)),
        100,
      );
      await started.future.timeout(waitLimit);
      await bench.paired.replaceAll([pairedDeviceOf(client)]);
      await bench.server.rebuildTrust();

      expect(_describe(await pending), 'answered 200 complete');
      expect(sink.bytes.length, 100);
    });
  });

  group('E44: upload route definitions', () {
    ApiServer build({
      List<ApiRoute> routes = const [],
      required List<ApiUploadRoute> uploadRoutes,
    }) {
      final identity = DeviceIdentity.generate();
      return ApiServer(
        identity: identity,
        paired: PairedDevicesStore(
          JsonFileStore(File('never-written.json')),
          ownerFingerprint: identity.fingerprint,
        ),
        routes: routes,
        uploadRoutes: uploadRoutes,
        selfInfo: () => selfInfoOf(identity),
        onRegistered: (_, _, _) {},
      );
    }

    ApiUploadRoute upload(String path) => ApiUploadRoute(
      path: path,
      handle: (_) async => const ApiReply(200, {}),
    );

    test('an upload route that repeats a JSON route is an ArgumentError', () {
      expect(
        () => build(
          routes: [
            ApiRoute(
              path: _uploadPath,
              access: RouteAccess.paired,
              handle: (_) async => const ApiReply(200, {}),
            ),
          ],
          uploadRoutes: [upload(_uploadPath)],
        ),
        throwsArgumentError,
      );
    });

    test('two upload routes with the same path are an ArgumentError', () {
      expect(
        () => build(uploadRoutes: [upload(_uploadPath), upload(_uploadPath)]),
        throwsArgumentError,
      );
    });

    for (final path in ApiPaths.anonymous) {
      test(
        'an upload route on the anonymous path $path is an ArgumentError',
        () {
          expect(
            () => build(uploadRoutes: [upload(path)]),
            throwsArgumentError,
          );
        },
      );
    }

    for (final path in ['/upload', '/api/other/v1/upload', apiPrefix]) {
      test('an upload route outside the API prefix ($path) is an '
          'ArgumentError', () {
        expect(() => build(uploadRoutes: [upload(path)]), throwsArgumentError);
      });
    }

    test('control: one upload route next to the JSON transfer routes is '
        'accepted', () {
      final server = build(
        routes: [
          ApiRoute(
            path: _jsonPath,
            access: RouteAccess.paired,
            handle: (_) async => const ApiReply(200, {}),
          ),
        ],
        uploadRoutes: [upload(_uploadPath)],
      );

      expect(server.uploadRoutes.map((r) => r.path), [_uploadPath]);
      expect(
        () => server.uploadRoutes.add(upload('$apiPrefix/x')),
        throwsUnsupportedError,
      );
    });
  });

  group('E46: early answer with the body still pending (plan, point 28)', () {
    Future<_Bench> refusing(void Function() onUndelivered) => _Bench.start(
      pairedWith: [client],
      handle: (_) async =>
          ApiReply(403, _forbidden, onUndelivered: onUndelivered),
    );

    test('10 KiB, 50 times in a row: always Answered(403, bodyComplete: true), '
        'nothing written to disk', () async {
      var undelivered = 0;
      final bench = await refusing(() => undelivered++);
      final outcomes = <String>[];

      for (var i = 0; i < 50; i++) {
        final result = await bench.post(
          _as(client),
          _chunked(_pattern(10 * _kib, seed: i)),
          10 * _kib,
        );
        outcomes.add(_describe(result));
        if (result is StreamPostAnswered) {
          expect(jsonDecode(utf8.decode(result.response.body)), _forbidden);
        }
      }
      await Future<void>.delayed(_settle);

      expect(outcomes, everyElement('answered 403 complete'));
      expect(bench.uploads, hasLength(50));
      expect(undelivered, 0);
      expect(bench.files(), ['paired.json']);
    }, timeout: const Timeout(Duration(minutes: 2)));

    test('5 MiB, 50 times in a row: always Answered(403, bodyComplete: '
        'false), never connectionLost, nothing written to disk', () async {
      var undelivered = 0;
      final bench = await refusing(() => undelivered++);
      final outcomes = <String>[];

      for (var i = 0; i < 50; i++) {
        final result = await bench.post(
          _as(client),
          _chunked(_pattern(5 * _mib, seed: i)),
          5 * _mib,
        );
        outcomes.add(_describe(result));
        if (result is StreamPostAnswered) {
          expect(jsonDecode(utf8.decode(result.response.body)), _forbidden);
        }
      }
      await Future<void>.delayed(_settle);

      expect(outcomes, everyElement('answered 403 partial'));
      expect(bench.uploads, hasLength(50));
      expect(undelivered, 0);
      expect(bench.files(), ['paired.json']);
    }, timeout: const Timeout(Duration(minutes: 3)));

    test('exactly 64 KiB announced: the server drains it all before '
        'answering, so the body is complete', () async {
      final bench = await refusing(() {});

      final result = await bench.post(
        _as(client),
        _chunked(_pattern(Limits.maxDiscardedUploadBytes)),
        Limits.maxDiscardedUploadBytes,
      );

      expect(_describe(result), 'answered 403 complete');
    });

    test('64 KiB + 1 announced: the client still gets the 403', () async {
      final bench = await refusing(() {});

      final result = await bench.post(
        _as(client),
        _chunked(_pattern(Limits.maxDiscardedUploadBytes + 1)),
        Limits.maxDiscardedUploadBytes + 1,
      );

      expect(result, isA<StreamPostAnswered>());
      expect((result as StreamPostAnswered).response.status, 403);
    });

    for (final (name, announced, sent) in [
      ('10 KiB sent whole', 10 * _kib, 10 * _kib),
      ('5 MiB announced, 64 KiB sent and held', 5 * _mib, 64 * _kib),
      ('1000 bytes announced, 10 sent and held', 1000, 10),
    ]) {
      test('raw client, $name: 403 with Connection: close and the socket is '
          'closed by the server within 2 s', () async {
        final bench = await refusing(() {});
        final raw = await bench.raw(_as(client));
        final stopwatch = Stopwatch()..start();

        raw.write([
          ..._uploadHead(contentLength: announced),
          ..._pattern(sent),
        ]);
        final reply = await raw.reply(limit: const Duration(seconds: 3));

        expect(reply?.status, 403);
        expect(reply!.header('connection'), 'close');
        expect(reply.json, _forbidden);
        expect(stopwatch.elapsed, lessThan(_short));
      });
    }
  });

  group('ApiReply.onUndelivered (plan, v2 point 8)', () {
    test('a JSON answer that reaches the client never calls it', () async {
      var undelivered = 0;
      final bench = await _Bench.start(
        pairedWith: [client],
        routes: [
          ApiRoute(
            path: _jsonPath,
            access: RouteAccess.paired,
            handle: (_) async => ApiReply(200, const {
              'ok': true,
            }, onUndelivered: () => undelivered++),
          ),
        ],
      );
      final raw = await bench.raw(_as(client));

      raw.write(httpRequest('POST', _jsonPath, body: jsonBody({})));
      final reply = await raw.reply();
      await Future<void>.delayed(_settle);

      expect(reply?.status, 200);
      expect(undelivered, 0);
    });

    final departures = <String, Future<void> Function(_Bench, TlsClient)>{
      'destroys its socket': (_, raw) async => raw.socket.destroy(),
      'closes only its writing side': (_, raw) => raw.socket.close(),
      'is unpaired and dropped by the server': (bench, _) async {
        await bench.paired.replaceAll([]);
        await bench.server.rebuildTrust();
      },
    };

    departures.forEach((name, depart) {
      test('RF-233: a JSON answer for a client that $name before the answer '
          'calls it exactly once', () async {
        var undelivered = 0;
        var called = 0;
        final gate = Completer<void>();
        final bench = await _Bench.start(
          pairedWith: [client],
          routes: [
            ApiRoute(
              path: _jsonPath,
              access: RouteAccess.paired,
              handle: (_) async {
                called++;
                await gate.future;
                return ApiReply(200, const {
                  'ok': true,
                }, onUndelivered: () => undelivered++);
              },
            ),
          ],
        );
        final raw = await bench.raw(_as(client));

        raw.write(httpRequest('POST', _jsonPath, body: jsonBody({})));
        await _until(() => called == 1);
        await depart(bench, raw);
        await Future<void>.delayed(_settle);
        gate.complete();
        await _until(
          () => undelivered > 0,
          limit: const Duration(seconds: 3),
        ).catchError((Object _) {});
        await Future<void>.delayed(_settle);

        expect(undelivered, 1);
      });
    });

    test('an upload answer after cut() calls it exactly once', () async {
      var undelivered = 0;
      final bench = await _Bench.start(
        pairedWith: [client],
        handle: (upload) async {
          upload.cut();
          await Future<void>.delayed(const Duration(milliseconds: 100));
          return ApiReply(403, _forbidden, onUndelivered: () => undelivered++);
        },
      );

      final result = await bench.post(_as(client), _chunked(_pattern(10)), 10);
      await _until(
        () => undelivered > 0,
        limit: const Duration(seconds: 3),
      ).catchError((Object _) {});
      await Future<void>.delayed(_settle);

      expect(_describe(result), 'failed connectionLost');
      expect(undelivered, 1);
    });
  });

  group('back pressure of a paused upload (plan, point 58)', () {
    Stream<List<int>> endless() async* {
      final block = _pattern(64 * _kib);
      while (true) {
        yield block;
      }
    }

    for (final listens in [false, true]) {
      test(
        listens
            ? 'a route that listens and then pauses: the client stalls '
                  'after a bounded amount, far below what it offers'
            : 'a route that never listens: the client stalls after a '
                  'bounded amount, far below what it offers',
        () async {
          final gate = Completer<void>();
          var received = 0;
          final bench = await _Bench.start(
            pairedWith: [client],
            handle: (upload) async {
              upload.keepAlive();
              if (listens) {
                upload.body.listen(
                  onData: (chunk) {
                    received += chunk.length;
                    upload.body.pause();
                  },
                  onDone: () {},
                  onError: (Object _) {},
                );
              }
              await gate.future;
              return const ApiReply(200, {});
            },
          );
          addTearDown(() {
            if (!gate.isCompleted) gate.complete();
          });

          final result = await bench.post(
            _as(client),
            endless(),
            1 << 40,
            idle: const Duration(milliseconds: 800),
          );

          expect(_describe(result), 'failed stalled');
          expect((result as StreamPostFailed).sent, lessThan(4 * _mib));
          expect(received, lessThanOrEqualTo(64 * _kib));
          if (listens) expect(received, greaterThan(0));
        },
      );
    }
  });

  group('a failing upload route', () {
    test('an exception cuts the connection without an answer and only its '
        'type is logged', () async {
      final bench = await _Bench.start(
        pairedWith: [client],
        handle: (_) async => throw StateError('route detail $_presentedValue'),
      );

      final result = await bench.post(
        _as(client),
        _chunked(_pattern(100)),
        100,
      );
      await Future<void>.delayed(_settle);

      expect(_describe(result), 'failed connectionLost');
      expect(bench.logs, contains('upload route failed: StateError'));
      expect(bench.logs.join('\n'), isNot(contains('route detail')));
      expect(bench.logs.join('\n'), isNot(contains(_presentedValue)));
    });

    test('the server keeps serving uploads after a route exception', () async {
      var fail = true;
      final bench = await _Bench.start(
        pairedWith: [client],
        handle: (upload) async {
          if (fail) {
            fail = false;
            throw StateError('once');
          }
          final sink = _Sink()..attach(upload.body);
          await sink.ended;
          return const ApiReply(200, {});
        },
      );

      final first = await bench.post(_as(client), _chunked(_pattern(10)), 10);
      final second = await bench.post(_as(client), _chunked(_pattern(10)), 10);

      expect(_describe(first), 'failed connectionLost');
      expect(_describe(second), 'answered 200 complete');
    });
  });
}
