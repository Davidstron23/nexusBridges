import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:nexus_bridges_core/src/browse/browse.dart';
import 'package:nexus_bridges_core/src/protocol/protocol.dart';
import 'package:nexus_bridges_core/src/server/server.dart';
import 'package:nexus_bridges_core/src/transfer/transfer.dart'
    show ForbiddenFolders;
import 'package:test/test.dart';

import '../server/api_server_harness.dart' show loopbackInterface;

final String peerA = 'A' * 64;
final String peerB = 'B' * 64;
final String peerC = 'C' * 64;
final String stranger = 'E' * 64;

String hexId(int n) => n.toRadixString(16).padLeft(32, '0');

ShareRecord record(int id, String path, {String? label, bool home = false}) =>
    ShareRecord(
      id: hexId(id),
      path: path,
      volumeId: 'NTFS-2692abcd',
      label: home ? '' : label ?? path.substring(path.lastIndexOf(r'\') + 1),
      home: home,
      drive: DriveKind.fixed,
      addedAt: DateTime.utc(2026, 11, 1),
    );

final class FakeReader implements ShareReader {
  final Map<String, List<ShareRecord>> roots = {};
  final Set<String> allowed = {};

  @override
  bool mayBrowse(String fingerprint) => allowed.contains(fingerprint);

  @override
  List<ShareRecord> rootsFor(String fingerprint) =>
      mayBrowse(fingerprint) ? roots[fingerprint] ?? const [] : const [];

  @override
  ShareRecord? rootFor(String fingerprint, String rootId) {
    for (final root in rootsFor(fingerprint)) {
      if (root.id == rootId) return root;
    }
    return null;
  }
}

final class CountingBrowseFileSystem implements ShareBrowseFileSystem {
  int calls = 0;
  final List<(List<String>, List<List<String>>)> levelZeroAsked = [];
  final List<List<String>> listAsked = [];
  List<bool> Function(int roots)? available;
  List<bool> Function(int checks)? checked;
  Completer<void>? listGate;
  Completer<void>? levelZeroGate;
  Completer<void>? exited;
  FolderListing listing = const FolderListed(
    ['otra', 'sub'],
    more: false,
    partial: false,
  );
  bool throwOnList = false;
  bool throwOnLevelZero = false;

  @override
  Future<ForbiddenFolders?> forbiddenFolders() async {
    calls++;
    return const ForbiddenFolders(trees: [], exact: []);
  }

  @override
  Future<String?> profilePath() async {
    calls++;
    return r'C:\Users\Bob';
  }

  @override
  Future<LevelZeroFacts> levelZero(
    List<ShareRecord> roots,
    List<(ShareRecord, List<String>)> checks, {
    required Duration budget,
  }) async {
    calls++;
    levelZeroAsked.add((
      [for (final root in roots) root.id],
      [for (final (_, path) in checks) path],
    ));
    if (throwOnLevelZero) throw StateError(r'C:\Users\Bob\docs failed');
    final gate = levelZeroGate;
    if (gate != null) await gate.future;
    return LevelZeroFacts(
      available:
          available?.call(roots.length) ?? List.filled(roots.length, true),
      checks: checked?.call(checks.length) ?? List.filled(checks.length, true),
      exited: exited?.future,
    );
  }

  @override
  Future<FolderListing> listFolders(
    ShareRecord root,
    List<String> path, {
    required Duration cap,
    required int max,
  }) async {
    calls++;
    listAsked.add(path);
    expect(cap, Limits.browseEnumerationCap);
    expect(max, Limits.maxBrowseEntries);
    if (throwOnList) throw StateError(r'C:\Users\Bob\docs failed');
    final gate = listGate;
    if (gate != null) await gate.future;
    return listing;
  }
}

final class Bench {
  Bench() {
    server = BrowseServer(
      shares: reader,
      fileSystem: fs,
      clock: () => now,
      log: logs.add,
    );
  }

  final FakeReader reader = FakeReader();
  final CountingBrowseFileSystem fs = CountingBrowseFileSystem();
  final List<String> logs = [];
  Duration now = const Duration(hours: 1);
  late final BrowseServer server;

  ApiRoute get route => server.routes.single;

  Future<ApiReply> ask(String? fingerprint, Object? json) => route.handle(
    ApiCall(
      path: ApiPaths.browse,
      clientFingerprint: fingerprint,
      remoteAddress: InternetAddress.loopbackIPv4,
      via: loopbackInterface(),
      json: json,
    ),
  );

  Future<ApiReply> roots(String fingerprint, {List<Object?>? check}) =>
      ask(fingerprint, {'protocol': protocolVersion, 'check': ?check});

  Future<ApiReply> folders(
    String fingerprint,
    String rootId,
    List<String> path,
  ) => ask(fingerprint, {
    'protocol': protocolVersion,
    'root': rootId,
    'path': path,
  });
}

List<int> bytesOf(ApiReply reply) => utf8.encode(jsonEncode(reply.json));

Bench bench() {
  final b = Bench();
  b.reader.allowed.addAll([peerA, peerB, peerC]);
  b.reader.roots[peerA] = [
    record(1, r'C:\datos\docs'),
    record(2, r'C:\Users\Bob', home: true),
    record(3, r'C:\personal\dev'),
    record(4, r'D:\dev'),
  ];
  b.reader.roots[peerB] = [record(5, r'C:\datos\otra')];
  b.reader.roots[peerC] = [record(6, r'C:\datos\tercera')];
  return b;
}

void main() {
  group('G9 browse route (RF-408, RF-412) [SEG]', () {
    test(
      'G9 the route is paired-only with its body cap and the IP ceiling',
      () {
        final route = bench().route;
        expect(route.path, ApiPaths.browse);
        expect(route.path, '/api/nexusbridges/v1/browse');
        expect(route.access, RouteAccess.paired);
        expect(route.maxBodyBytes, Limits.maxBrowseBodyBytes);
        expect(route.maxBodyBytes, 8192);
        expect(route.limit, isNotNull);
        expect(route.limit!.maxPerWindow, Limits.browseRequestsPerMinutePerIp);
        expect(route.limit!.maxPerWindow, 240);
        expect(route.limit!.window, const Duration(minutes: 1));
        expect(route.limit!.block, Limits.routeBlock);
        expect(ApiPaths.anonymous, isNot(contains(ApiPaths.browse)));
      },
    );

    test(
      'E721 foreign, another peer root, an invented root and a removed '
      'root all get the same 403 byte for byte without touching the disk',
      () async {
        final b = bench();
        b.reader.roots[stranger] = [record(9, r'C:\datos\ajena')];
        final replies = <ApiReply>[
          await b.roots(stranger),
          await b.folders(stranger, hexId(9), const []),
          await b.folders(peerA, hexId(5), const []),
          await b.folders(peerA, hexId(77), ['sub']),
          await b.ask(null, {'protocol': protocolVersion}),
        ];
        expect(b.fs.calls, 0);
        expect(await b.folders(peerA, hexId(1), const []), isA<ApiReply>());
        final before = b.fs.calls;
        b.reader.roots[peerA] = [
          for (final root in b.reader.roots[peerA]!)
            if (root.id != hexId(1)) root,
        ];
        replies.add(await b.folders(peerA, hexId(1), const []));
        expect(b.fs.calls, before);
        for (final reply in replies) {
          expect(reply.status, 403);
          expect(bytesOf(reply), utf8.encode('{"error":"forbidden"}'));
        }
      },
    );

    test('E725 the E700 paths over the route give the same 404 and never '
        'reach the disk', () async {
      final b = bench();
      final traps = <List<String>>[
        ['..'],
        ['.'],
        ['a', '..'],
        [r'a\..\..\Windows'],
        [r'C:\Windows'],
        ['C:'],
        [r'\\host\share'],
        ['a/b'],
        ['a:b'],
        ['a\u{1}b'],
        ['a*'],
        ['CON'],
        ['con.txt'],
        ['COM\u{B9}'],
        ['x.'],
        ['x '],
        ['a\u{202E}b'],
        ['.nexusbridges-incoming'],
        ['~nexusbridges-abc'],
        List.filled(33, 'a'),
        ['a' * 230],
      ];
      for (final trap in traps) {
        b.now += const Duration(seconds: 1);
        final reply = await b.folders(peerA, hexId(1), trap);
        expect(reply.status, 404, reason: '$trap');
        expect(bytesOf(reply), utf8.encode('{"error":"unavailable"}'));
      }
      expect(b.fs.calls, 0);
    });

    test(
      'G9 malformed bodies get 400 bad_request without touching the disk',
      () async {
        final b = bench();
        for (final json in <Object?>[
          null,
          'x',
          <String, Object?>{},
          {'protocol': '2.0'},
          {'protocol': protocolVersion, 'root': 'C:', 'path': <Object?>[]},
          {'protocol': protocolVersion, 'root': hexId(1), 'path': 'sub'},
          {'protocol': protocolVersion, 'absolutePath': r'C:\'},
        ]) {
          final reply = await b.ask(peerA, json);
          expect(reply.status, 400, reason: '$json');
          expect(bytesOf(reply), utf8.encode('{"error":"bad_request"}'));
        }
        expect(b.fs.calls, 0);
      },
    );

    test('G5 E709 level zero answers exact keys, visible names, home without '
        'a name and no paths', () async {
      final b = bench();
      b.fs.available = (n) => [true, true, false, true];
      final reply = await b.roots(peerA);
      expect(reply.status, 200);
      expect(reply.json.keys, ['roots']);
      final roots = (reply.json['roots']! as List).cast<Map<String, Object?>>();
      for (final root in roots) {
        expect(root.keys.toSet(), {'id', 'name', 'home', 'available'});
      }
      expect(roots.map((r) => r['id']), [
        hexId(1),
        hexId(2),
        hexId(3),
        hexId(4),
      ]);
      expect(roots.map((r) => r['name']), [
        'docs',
        '',
        'dev (personal)',
        'dev (D:)',
      ]);
      expect(roots.map((r) => r['home']), [false, true, false, false]);
      expect(roots.map((r) => r['available']), [true, true, false, true]);
      final text = jsonEncode(reply.json);
      expect(text, isNot(contains('Bob')));
      expect(text, isNot(contains(r'C:\\')));
      expect(text, isNot(contains('datos')));
      expect(parseRootsResponse(reply.json, checks: 0), isNotNull);
    });

    test('G9 checks: the ones that fail G1 or are not granted are false and '
        'never reach the disk', () async {
      final b = bench();
      b.fs.checked = (n) => List.filled(n, true);
      final reply = await b.roots(
        peerA,
        check: [
          {
            'root': hexId(1),
            'path': ['sub'],
          },
          {
            'root': hexId(1),
            'path': ['..'],
          },
          {'root': hexId(5), 'path': <Object?>[]},
          {'root': hexId(77), 'path': <Object?>[]},
          {
            'root': hexId(3),
            'path': ['a', 'b'],
          },
        ],
      );
      expect(reply.status, 200);
      expect(reply.json.keys.toSet(), {'roots', 'checks'});
      expect(reply.json['checks'], [true, false, false, false, true]);
      expect(b.fs.levelZeroAsked.single.$2, [
        ['sub'],
        ['a', 'b'],
      ]);
      expect(parseRootsResponse(reply.json, checks: 5), isNotNull);
    });

    test('G9 with no roots and no valid checks the answer is empty and the '
        'disk is not touched', () async {
      final b = bench();
      b.reader.roots[peerA] = [];
      expect((await b.roots(peerA)).json, {'roots': <Object?>[]});
      final checked = await b.roots(
        peerA,
        check: [
          {'root': hexId(1), 'path': <Object?>[]},
        ],
      );
      expect(checked.json, {
        'roots': <Object?>[],
        'checks': [false],
      });
      expect(b.fs.calls, 0);
    });

    test('G5 subfolders answer folders, more and partial only', () async {
      final b = bench();
      b.fs.listing = const FolderListed(
        ['otra', 'sub'],
        more: true,
        partial: true,
      );
      final reply = await b.folders(peerA, hexId(1), ['a']);
      expect(reply.status, 200);
      expect(reply.json, {
        'folders': ['otra', 'sub'],
        'more': true,
        'partial': true,
      });
      expect(b.fs.listAsked.single, ['a']);
      b.fs.listing = const FolderUnavailable();
      final gone = await b.folders(peerA, hexId(1), ['a']);
      expect(gone.status, 404);
      expect(bytesOf(gone), utf8.encode('{"error":"unavailable"}'));
    });

    test(
      'E728 the 21st request in 10 s gets 429 and one more passes at 10 s',
      () async {
        final b = bench();
        for (var i = 0; i < 20; i++) {
          final reply = i.isEven
              ? await b.roots(peerA)
              : await b.ask(peerA, {'protocol': 'x'});
          expect(reply.status, isNot(429), reason: 'request $i');
          b.now += const Duration(milliseconds: 100);
        }
        final limited = await b.folders(peerA, hexId(1), const []);
        expect(limited.status, 429);
        expect(bytesOf(limited), utf8.encode('{"error":"rate_limited"}'));
        expect((await b.roots(peerB)).status, 200);
        b.now = const Duration(hours: 1, seconds: 10);
        expect((await b.roots(peerA)).status, 200);
        expect((await b.roots(peerA)).status, 429);
        b.server.forget(peerA);
        expect((await b.roots(peerA)).status, 200);
      },
    );

    test('E728 a third request of the same peer and a fifth in total get '
        '429 while the others run', () async {
      final b = bench();
      final gate = b.fs.listGate = Completer<void>();
      final running = [
        b.folders(peerA, hexId(1), const []),
        b.folders(peerA, hexId(1), ['a']),
        b.folders(peerB, hexId(5), const []),
        b.folders(peerB, hexId(5), ['b']),
      ];
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect((await b.folders(peerA, hexId(1), ['c'])).status, 429);
      expect((await b.folders(peerC, hexId(6), const [])).status, 429);
      expect((await b.roots(peerC)).status, 429);
      gate.complete();
      for (final reply in await Future.wait(running)) {
        expect(reply.status, 200);
      }
      expect((await b.folders(peerC, hexId(6), const [])).status, 200);
    });

    test('E728 a level zero slot is held until the worker exits, not until '
        'the answer (punto 10)', () async {
      final b = bench();
      final exited = b.fs.exited = Completer<void>();
      expect((await b.roots(peerA)).status, 200);
      expect((await b.roots(peerA)).status, 200);
      expect((await b.roots(peerA)).status, 429);
      expect((await b.folders(peerA, hexId(1), const [])).status, 429);
      b.fs.exited = null;
      exited.complete();
      await Future<void>.delayed(Duration.zero);
      expect((await b.folders(peerA, hexId(1), const [])).status, 200);
    });

    test('G9 a grant removed while the disk works gives 403 (step 8, '
        'RF-417)', () async {
      final b = bench();
      final gate = b.fs.listGate = Completer<void>();
      final pending = b.folders(peerA, hexId(1), const []);
      await Future<void>.delayed(const Duration(milliseconds: 10));
      b.reader.roots[peerA] = [record(3, r'C:\personal\dev')];
      gate.complete();
      final reply = await pending;
      expect(reply.status, 403);
      expect(bytesOf(reply), utf8.encode('{"error":"forbidden"}'));

      final zeroGate = b.fs.levelZeroGate = Completer<void>();
      final zero = b.roots(peerA);
      await Future<void>.delayed(const Duration(milliseconds: 10));
      b.reader.allowed.remove(peerA);
      zeroGate.complete();
      expect((await zero).status, 403);

      b.reader.allowed.add(peerA);
      final zeroGate2 = b.fs.levelZeroGate = Completer<void>();
      final zero2 = b.roots(peerA);
      await Future<void>.delayed(const Duration(milliseconds: 10));
      b.reader.roots[peerA] = [];
      zeroGate2.complete();
      expect((await zero2).status, 403);
    });

    test(
      'E731 a level zero that ran out of budget answers what arrived, the '
      'rest as unavailable or false, and keeps the slot (punto 10)',
      () async {
        final b = bench();
        b.reader.roots[peerA] = [
          record(1, r'C:\datos\docs'),
          record(3, r'C:\personal\dev'),
        ];
        final exited = b.fs.exited = Completer<void>();
        b.fs.available = (_) => [true, false];
        b.fs.checked = (_) => [false, true];
        final reply = await b.roots(
          peerA,
          check: [
            {'root': hexId(1), 'path': <String>[]},
            {'root': hexId(3), 'path': <String>[]},
          ],
        );
        expect(reply.status, 200);
        final body = reply.json;
        final roots = (body['roots']! as List<Object?>)
            .cast<Map<String, Object?>>();
        expect([for (final root in roots) root['available']], [true, false]);
        expect(body['checks'], [false, true]);
        expect((await b.roots(peerA)).status, 200);
        expect((await b.roots(peerA)).status, 429);
        exited.complete();
      },
    );

    test('G9 an exception while listing answers 404 unavailable and logs no '
        'path', () async {
      final b = bench();
      b.fs.throwOnList = true;
      final reply = await b.folders(peerA, hexId(1), ['sub']);
      expect(reply.status, 404);
      expect(bytesOf(reply), utf8.encode('{"error":"unavailable"}'));
      b.fs.throwOnLevelZero = true;
      final zero = await b.roots(peerA);
      expect(zero.status, 404);
      expect(bytesOf(zero), utf8.encode('{"error":"unavailable"}'));
      final logs = b.logs.join('\n');
      expect(logs, isNot(contains('Bob')));
      expect(logs, isNot(contains('docs')));
      expect(logs, isNot(contains('sub')));
      expect(logs, isNot(contains(hexId(1))));
      expect((await b.folders(peerA, hexId(1), const [])).status, 404);
      b.fs.throwOnList = false;
      expect((await b.folders(peerA, hexId(1), const [])).status, 200);
    });
  });
}
