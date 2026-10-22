import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:nexus_bridges_core/src/discovery/discovery.dart';
import 'package:nexus_bridges_core/src/node/node.dart';
import 'package:nexus_bridges_core/src/protocol/protocol.dart';
import 'package:test/test.dart';

const Duration _shutdownLimit = Duration(seconds: 2);
const Duration _waitLimit = Duration(seconds: 5);
const Timeout _childTimeout = Timeout(Duration(minutes: 2));

final String _sep = Platform.pathSeparator;

final class _FakeProtector implements SecretProtector {
  _FakeProtector({this.leakOnProtect = false, this.throwOnUnprotect = false});

  static const int _key = 0x5A;

  final bool leakOnProtect;
  final bool throwOnUnprotect;
  int protectCalls = 0;
  int unprotectCalls = 0;
  String? leakedPem;
  void Function()? onProtect;

  static Uint8List _xor(Uint8List data) =>
      Uint8List.fromList([for (final b in data) b ^ _key]);

  @override
  Uint8List protect(Uint8List data) {
    protectCalls++;
    onProtect?.call();
    if (leakOnProtect) {
      leakedPem = utf8.decode(data);
      throw StateError('protect failed: $leakedPem');
    }
    return _xor(data);
  }

  @override
  Uint8List? unprotect(Uint8List data) {
    unprotectCalls++;
    if (throwOnUnprotect) {
      throw StateError('unprotect failed: -----BEGIN PRIVATE KEY----- $data');
    }
    return _xor(data);
  }
}

String _describe(NodeState s) => [
  s.identityStatus.name,
  s.identityError ?? '',
  s.deviceName,
  s.fingerprint,
  '${s.portInUse}',
  for (final p in [...s.prompts, ...s.pausedNetworks])
    '${p.networkId} ${p.networkName}',
  for (final MapEntry(:key, :value) in s.displayNames.entries) '$key $value',
  for (final d in s.devices) '${d.info.name} ${d.info.fingerprint}',
].join('\n');

Iterable<String> _pemFragments(String pem, {int size = 16}) sync* {
  final body = LineSplitter.split(pem)
      .map((l) => l.trim())
      .where((l) => !l.startsWith('-----'))
      .join();
  for (var i = 0; i + size <= body.length; i += size ~/ 2) {
    yield body.substring(i, i + size);
  }
}

Future<int> _freePort() async {
  final probe = await ServerSocket.bind(InternetAddress.anyIPv4, 0);
  final port = probe.port;
  await probe.close();
  return port;
}

Future<bool> _udpPortFree(int port) async {
  final probe = MulticastChannel(port: port);
  try {
    await probe.open();
    return true;
  } on PortInUseException {
    return false;
  } finally {
    await probe.close();
  }
}

Future<void> _until(bool Function() condition) async {
  final deadline = DateTime.now().add(_waitLimit);
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) {
      fail('condition not met within $_waitLimit');
    }
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}

Future<List<String>> _namesIn(Directory dir) async {
  final names = await dir
      .list()
      .map((e) => e.uri.pathSegments.lastWhere((s) => s.isNotEmpty))
      .toList();
  return names..sort();
}

const String _lockScript = '''
import 'dart:io';

Future<void> main(List<String> args) async {
  final file = await File(args.first).open(mode: FileMode.append);
  await file.lock(FileLock.exclusive);
  stdout.writeln('locked');
  await stdin.drain<void>();
  await file.unlock();
  await file.close();
}
''';

const String _protectorSource = r'''
final class _Protector implements SecretProtector {
  @override
  Uint8List protect(Uint8List data) =>
      Uint8List.fromList([for (final b in data) b ^ 0x5A]);

  @override
  Uint8List? unprotect(Uint8List data) =>
      Uint8List.fromList([for (final b in data) b ^ 0x5A]);
}
''';

const String _socketsScript =
    r'''
import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:nexus_bridges_core/src/discovery/discovery.dart';
import 'package:nexus_bridges_core/src/node/node.dart';

Future<int> sockets(String protocol) async {
  final result = await Process.run('netstat', ['-ano', '-p', protocol]);
  final own = '$pid';
  return '${result.stdout}'
      .split('\n')
      .map((line) => line.trim().split(RegExp(r'\s+')))
      .where((cells) => cells.first == protocol && cells.last == own)
      .length;
}

Future<void> main(List<String> args) async {
  final dir = Directory(args[0]);
  final port = int.parse(args[1]);
  final udp = await sockets('UDP');
  final tcp = await sockets('TCP');
  final node = await NexusNode.start(
    dataDir: dir,
    protector: _Protector(),
    readNetworks: () async => const <AdapterInfo>[],
    port: port,
    deviceName: 'Child PC',
    pollInterval: const Duration(milliseconds: 100),
    channel: MulticastChannel(port: port),
  );
  print('started ${node.state.identityStatus.name}');
  print('open udp ${await sockets('UDP') - udp} tcp ${await sockets('TCP') - tcp}');
  await node.rescan();
  await Future<void>.delayed(const Duration(milliseconds: 1500));
  final watch = Stopwatch()..start();
  await node.shutdown();
  watch.stop();
  print(watch.elapsed < const Duration(seconds: 2) ? 'shutdown in time' : 'shutdown late ${watch.elapsed}');
  print('closed udp ${await sockets('UDP') - udp} tcp ${await sockets('TCP') - tcp}');
}
''' +
    _protectorSource;

const String _noLocalAppDataScript =
    r'''
import 'dart:io';
import 'dart:typed_data';

import 'package:nexus_bridges_core/src/discovery/discovery.dart';
import 'package:nexus_bridges_core/src/node/node.dart';
import 'package:nexus_bridges_core/src/protocol/protocol.dart';

Future<void> main(List<String> args) async {
  final port = int.parse(args.first);
  var reads = 0;
  final node = await NexusNode.start(
    protector: _Protector(),
    readNetworks: () async {
      reads++;
      return const <AdapterInfo>[];
    },
    port: port,
    deviceName: 'Child PC',
    channel: MulticastChannel(port: port),
  );
  print('${node.state.identityStatus.name}|${node.state.identityError}');
  final probe = MulticastChannel(port: port);
  try {
    await probe.open();
    print('port free');
  } on PortInUseException {
    print('port taken');
  } finally {
    await probe.close();
  }
  await Future<void>.delayed(const Duration(milliseconds: 300));
  print('reads $reads');
  await node.shutdown();
}
''' +
    _protectorSource;

void main() {
  late Directory root;
  late int port;
  late List<String> logs;
  late DateTime clock;
  late int reads;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('nexus_node_boot_');
    addTearDown(() => root.delete(recursive: true));
    port = await _freePort();
    logs = [];
    clock = DateTime(2026, 10, 22, 12);
    reads = 0;
  });

  Directory dataDir() => Directory('${root.path}${_sep}data');

  Future<List<AdapterInfo>> countedRead() async {
    reads++;
    return const <AdapterInfo>[];
  }

  Future<NexusNode> startNode({
    Directory? dir,
    SecretProtector? protector,
    String deviceName = 'Test PC',
    Future<List<AdapterInfo>> Function()? readNetworks,
  }) async {
    final node = await NexusNode.start(
      dataDir: dir ?? dataDir(),
      protector: protector ?? _FakeProtector(),
      readNetworks: readNetworks ?? countedRead,
      port: port,
      deviceName: deviceName,
      now: () => clock,
      log: logs.add,
      pollInterval: const Duration(minutes: 1),
      channel: MulticastChannel(port: port, log: logs.add),
    );
    addTearDown(node.shutdown);
    return node;
  }

  Future<Directory> blockedDataDir() async {
    final file = File('${root.path}${_sep}data');
    await file.writeAsString('x');
    return Directory(file.path);
  }

  Future<Directory> scriptDir() async {
    final dir = await Directory.systemTemp.createTemp('nexus_node_script_');
    addTearDown(() => dir.delete(recursive: true));
    return dir;
  }

  Future<Future<void> Function()> lockInChild(File file) async {
    final dir = await scriptDir();
    final script = File('${dir.path}${_sep}lock_file.dart');
    await script.writeAsString(_lockScript);
    final process = await Process.start(Platform.resolvedExecutable, [
      script.path,
      file.path,
    ]);
    addTearDown(() async {
      process.kill();
      await process.exitCode;
    });
    process.stderr.drain<void>().ignore();
    final line = await process.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .first
        .timeout(const Duration(seconds: 60));
    expect(line.trim(), 'locked');
    return () async {
      await process.stdin.close();
      expect(await process.exitCode.timeout(const Duration(seconds: 30)), 0);
    };
  }

  Future<(int, List<String>, String)> runChild(
    String source,
    List<String> args, {
    Map<String, String>? environment,
  }) async {
    final packageConfig = await Isolate.packageConfig;
    expect(packageConfig, isNotNull);
    final dir = await scriptDir();
    final script = File('${dir.path}${_sep}child.dart');
    await script.writeAsString(source);
    final process = await Process.start(Platform.resolvedExecutable, [
      '--packages=${packageConfig!.toFilePath()}',
      script.path,
      ...args,
    ], environment: environment);
    addTearDown(process.kill);
    final lines = process.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .toList();
    final errors = process.stderr.transform(utf8.decoder).join();
    final code = await process.exitCode.timeout(const Duration(seconds: 90));
    return (code, await lines, await errors);
  }

  group('identity at start (RF-7)', () {
    test('the first start creates the identity and reports ok', () async {
      final protector = _FakeProtector();

      final node = await startNode(protector: protector);

      expect(node.state.identityStatus, IdentityStatus.ok);
      expect(node.state.identityError, isNull);
      expect(node.state.fingerprint, matches(RegExp(r'^[0-9A-F]{64}$')));
      expect(node.state.deviceName, 'Test PC');
      expect(protector.protectCalls, 1);
    });

    test('a second start on the same folder loads the same identity and '
        'reports ok', () async {
      final first = await startNode();
      final fingerprint = first.state.fingerprint;
      await first.shutdown();

      final second = await startNode();

      expect(second.state.identityStatus, IdentityStatus.ok);
      expect(second.state.fingerprint, fingerprint);
    });

    test('an unreadable identity is replaced and reports reset with the new '
        'fingerprint', () async {
      final first = await startNode();
      final old = first.state.fingerprint;
      await first.shutdown();
      await File('${dataDir().path}${_sep}identity${_sep}private-key.dpapi')
          .writeAsBytes(List<int>.generate(300, (i) => i * 7 % 256));

      final node = await startNode();

      expect(node.state.identityStatus, IdentityStatus.reset);
      expect(node.state.identityError, isNull);
      expect(node.state.fingerprint, matches(RegExp(r'^[0-9A-F]{64}$')));
      expect(node.state.fingerprint, isNot(old));
      expect(
        (await _namesIn(dataDir())).where((n) => n.startsWith('identity.')),
        hasLength(1),
      );
    });

    test('a reset node keeps working: its channel is open and it reads the '
        'networks', () async {
      final first = await startNode();
      await first.shutdown();
      await File('${dataDir().path}${_sep}identity${_sep}certificate.pem')
          .delete();

      final node = await startNode();

      expect(node.state.identityStatus, IdentityStatus.reset);
      expect(await _udpPortFree(port), isFalse);
      await _until(() => reads > 1);
    });
  });

  group('identity that cannot be created (RF-8)', () {
    test('a data folder that is a file gives failed with a reason, opens no '
        'socket and never reads the networks', () async {
      final node = await startNode(dir: await blockedDataDir());

      expect(node.state.identityStatus, IdentityStatus.failed);
      expect(
        node.state.identityError,
        matches(RegExp(r'^could not create identity: [A-Za-z_]+$')),
      );
      expect(node.state.fingerprint, isEmpty);
      expect(node.state.devices, isEmpty);
      await Future<void>.delayed(const Duration(milliseconds: 300));
      expect(reads, 0);
      expect(await _udpPortFree(port), isTrue);
      expect(await File(dataDir().path).readAsString(), 'x');
    });

    test('a protector that throws while reading the key gives failed with '
        '"identity unavailable"', () async {
      final first = await startNode();
      await first.shutdown();

      final node = await startNode(
        protector: _FakeProtector(throwOnUnprotect: true),
      );

      expect(node.state.identityStatus, IdentityStatus.failed);
      expect(node.state.identityError, 'identity unavailable');
      expect(node.state.fingerprint, isEmpty);
      expect(await _udpPortFree(port), isTrue);
      expect(logs, contains(contains('StateError')));
    });

    test(
      'without LOCALAPPDATA and no data folder given, the node fails with '
      '"data directory unavailable" and opens nothing',
      () async {
        final (code, lines, errors) = await runChild(
          _noLocalAppDataScript,
          ['$port'],
          environment: {'LOCALAPPDATA': ''},
        );

        expect(code, 0, reason: errors);
        expect(lines, [
          'failed|data directory unavailable',
          'port free',
          'reads 0',
        ]);
      },
      timeout: _childTimeout,
      testOn: 'windows',
    );

    test('retry with the problem fixed gives ok and starts the network '
        'functions', () async {
      final blocked = await blockedDataDir();
      final node = await startNode(dir: blocked);
      expect(node.state.identityStatus, IdentityStatus.failed);
      final states = <NodeState>[];
      final subscription = node.states.listen(states.add);
      addTearDown(subscription.cancel);

      await File(blocked.path).delete();
      await node.retry();

      expect(node.state.identityStatus, IdentityStatus.ok);
      expect(node.state.identityError, isNull);
      expect(node.state.fingerprint, matches(RegExp(r'^[0-9A-F]{64}$')));
      await _until(
        () => states.any((s) => s.identityStatus == IdentityStatus.ok),
      );
      expect(await _udpPortFree(port), isFalse);
      await _until(() => reads > 0);
    });

    test('retry while the problem is still there stays failed and opens '
        'nothing', () async {
      final node = await startNode(dir: await blockedDataDir());

      await node.retry();

      expect(node.state.identityStatus, IdentityStatus.failed);
      expect(node.state.identityError, isNotNull);
      expect(await _udpPortFree(port), isTrue);
      expect(reads, 0);
    });

    test('two retries in a row boot only once', () async {
      final protector = _FakeProtector();
      final blocked = await blockedDataDir();
      final node = await startNode(dir: blocked, protector: protector);
      await File(blocked.path).delete();

      await Future.wait([node.retry(), node.retry()]);

      expect(node.state.identityStatus, IdentityStatus.ok);
      expect(protector.protectCalls, 1);
      expect(protector.unprotectCalls, 0);
      expect(await _udpPortFree(port), isFalse);
    });

    test('retry on a node that is ok does nothing', () async {
      final protector = _FakeProtector();
      final node = await startNode(protector: protector);
      final fingerprint = node.state.fingerprint;

      await node.retry();

      expect(node.state.identityStatus, IdentityStatus.ok);
      expect(node.state.fingerprint, fingerprint);
      expect(protector.protectCalls, 1);
      expect(protector.unprotectCalls, 0);
    });

    test('retry and shutdown sent together after fixing the problem end in '
        'time and leave nothing open', () async {
      final blocked = await blockedDataDir();
      final node = await startNode(dir: blocked);
      var done = false;
      final subscription = node.states.listen(null, onDone: () => done = true);
      addTearDown(subscription.cancel);
      await File(blocked.path).delete();

      final watch = Stopwatch()..start();
      final retried = node.retry();
      final closed = node.shutdown();
      await Future.wait([retried, closed]).timeout(_shutdownLimit);
      watch.stop();

      expect(watch.elapsed, lessThan(_shutdownLimit));
      expect(done, isTrue);
      expect(await _udpPortFree(port), isTrue);
      await Future<void>.delayed(const Duration(milliseconds: 300));
      expect(reads, 0);
    });

    test('a shutdown that arrives in the middle of the retry boot waits for '
        'it and leaves nothing open', () async {
      final protector = _FakeProtector();
      final blocked = await blockedDataDir();
      final node = await startNode(dir: blocked, protector: protector);
      var done = false;
      final subscription = node.states.listen(null, onDone: () => done = true);
      addTearDown(subscription.cancel);
      await File(blocked.path).delete();
      Future<void>? closed;
      protector.onProtect = () => closed ??= node.shutdown();

      await node.retry().timeout(_waitLimit);

      expect(protector.protectCalls, 1);
      expect(closed, isNotNull);
      await closed!.timeout(_shutdownLimit);
      expect(done, isTrue);
      expect(await _udpPortFree(port), isTrue);
      await Future<void>.delayed(const Duration(milliseconds: 300));
      expect(reads, 0);
    });
  });

  group('disk errors at start (plan v2.8 point 7)', () {
    for (final (name, content) in [
      (
        'networks.json',
        '{"version":1,"networks":{"{NETWORK-HOME}":{"decision":"trusted",'
            '"name":"Casa","decidedAt":"2026-10-21T10:00:00.000Z"}}}',
      ),
      ('paired.json', '{"version":1,"devices":[]}'),
    ]) {
      test(
        '$name locked by another process: the node starts ok, logs it and '
        'leaves the file as it was',
        () async {
          final first = await startNode();
          await first.shutdown();
          final file = File('${dataDir().path}$_sep$name');
          await file.writeAsString(content);
          final release = await lockInChild(file);
          final readError = await file.readAsBytes().then<Object?>(
            (_) => null,
            onError: (Object e) => e,
          );
          expect(readError, isA<FileSystemException>());
          logs.clear();

          final node = await startNode();

          expect(node.state.identityStatus, IdentityStatus.ok);
          expect(node.state.fingerprint, matches(RegExp(r'^[0-9A-F]{64}$')));
          expect(logs, contains(contains('${readError.runtimeType}')));
          expect(logs.join('\n'), isNot(contains(content)));
          expect(await _udpPortFree(port), isFalse);
          await _until(() => reads > 1);

          await release();
          expect(await file.readAsString(), content);
          expect(
            (await _namesIn(dataDir())).where((n) => n.contains('.broken-')),
            isEmpty,
          );
        },
        timeout: _childTimeout,
        testOn: 'windows',
      );
    }
  });

  group('device name (RF-10, plan v2.8 point 11)', () {
    test('80 characters with a U+202E come out clean and cut to 64', () async {
      final raw = '${'A' * 39}\u202E${'B' * 40}';
      expect(raw.length, 80);

      final node = await startNode(deviceName: raw);

      expect(node.state.deviceName, '${'A' * 39}${'B' * 25}');
      expect(node.state.deviceName.runes, hasLength(64));
      expect(node.state.deviceName, isNot(contains('\u202E')));
    });

    test('a name made only of invisible characters and spaces falls back to '
        'NexusBridges', () async {
      final node = await startNode(deviceName: ' \u200B\u202E\uFEFF ');

      expect(node.state.deviceName, 'NexusBridges');
    });

    test('without a name, the node uses the Windows computer name, '
        'cleaned', () async {
      final node = await NexusNode.start(
        dataDir: dataDir(),
        protector: _FakeProtector(),
        readNetworks: countedRead,
        port: port,
        now: () => clock,
        log: logs.add,
        channel: MulticastChannel(port: port),
      );
      addTearDown(node.shutdown);

      expect(
        node.state.deviceName,
        sanitizeDisplayName(Platform.localHostname) ?? 'NexusBridges',
      );
      expect(node.state.deviceName, isNotEmpty);
    });

    test('the clean name is in the state also when the identity '
        'failed', () async {
      final node = await startNode(
        dir: await blockedDataDir(),
        deviceName: 'Portátil\u202E de David',
      );

      expect(node.state.identityStatus, IdentityStatus.failed);
      expect(node.state.deviceName, 'Portátil de David');
    });
  });

  group('shutdown (RF-51)', () {
    test('ends within 2 s, closes the states stream and frees the channel '
        'port', () async {
      final node = await startNode();
      var done = false;
      final subscription = node.states.listen(null, onDone: () => done = true);
      addTearDown(subscription.cancel);
      expect(await _udpPortFree(port), isFalse);

      final watch = Stopwatch()..start();
      await node.shutdown().timeout(_shutdownLimit);
      watch.stop();

      expect(watch.elapsed, lessThan(_shutdownLimit));
      expect(done, isTrue);
      expect(await _udpPortFree(port), isTrue);
    });

    test('two calls, together or one after the other, do not fail', () async {
      final node = await startNode();

      await Future.wait([node.shutdown(), node.shutdown()]);
      await node.shutdown();

      expect(await _udpPortFree(port), isTrue);
    });

    test('ends within 2 s even with a network read that never '
        'finishes', () async {
      final stuck = Completer<List<AdapterInfo>>();
      var started = 0;
      final node = await startNode(
        readNetworks: () {
          started++;
          return stuck.future;
        },
      );
      await _until(() => started > 0);

      await node.shutdown().timeout(_shutdownLimit);

      expect(await _udpPortFree(port), isTrue);
    });

    test('a failed node shuts down too', () async {
      final node = await startNode(dir: await blockedDataDir());

      await node.shutdown().timeout(_shutdownLimit);

      expect(await _udpPortFree(port), isTrue);
    });

    test('rescan and retry after shutdown do not throw and open '
        'nothing', () async {
      final node = await startNode(dir: await blockedDataDir());
      await node.shutdown();
      await File(dataDir().path).delete();

      await node.rescan().timeout(_waitLimit);
      await node.retry().timeout(_waitLimit);

      expect(node.state.identityStatus, IdentityStatus.failed);
      expect(await _udpPortFree(port), isTrue);
      expect(reads, 0);
    });

    test(
      'a process that runs a node holds only the channel socket, has none '
      'left after shutdown and ends on its own',
      () async {
        final dir = await scriptDir();

        final (code, lines, errors) = await runChild(_socketsScript, [
          dir.path,
          '$port',
        ]);

        expect(code, 0, reason: errors);
        expect(lines, [
          'started ok',
          'open udp 1 tcp 0',
          'shutdown in time',
          'closed udp 0 tcp 0',
        ]);
      },
      timeout: _childTimeout,
      testOn: 'windows',
    );
  });

  group('rescan suggestion (RF-55)', () {
    test('without active interfaces, suggestRescan stays false although 15 s '
        'and more pass', () async {
      final node = await startNode();
      final seen = <bool>[];
      final subscription = node.states.listen((s) => seen.add(s.suggestRescan));
      addTearDown(subscription.cancel);

      expect(node.state.paused, isTrue);
      expect(node.state.suggestRescan, isFalse);
      clock = clock.add(const Duration(seconds: 16));
      await Future<void>.delayed(const Duration(milliseconds: 1300));
      clock = clock.add(const Duration(minutes: 10));
      await Future<void>.delayed(const Duration(milliseconds: 1300));

      expect(node.state.paused, isTrue);
      expect(node.state.suggestRescan, isFalse);
      expect(seen, everyElement(isFalse));
    });
  });

  group('rescan from the node (RF-54)', () {
    test('two calls in a row get the same future, and once over the next '
        'call starts another', () async {
      final node = await startNode();

      final first = node.rescan();
      final second = node.rescan();

      expect(second, same(first));
      await first.timeout(_waitLimit);
      final third = node.rescan();
      expect(third, isNot(same(first)));
      await third.timeout(_waitLimit);
    });

    test('rescan on a failed node ends without error', () async {
      final node = await startNode(dir: await blockedDataDir());

      await node.rescan().timeout(_waitLimit);

      expect(await _udpPortFree(port), isTrue);
    });
  });

  group('no key material in state or logs (SEC)', () {
    test('ok, reset and both kinds of failure never put PRIVATE KEY in the '
        'state or the log', () async {
      final texts = <String>[];
      Future<NexusNode> observed(Future<NexusNode> starting) async {
        final node = await starting;
        texts.add(_describe(node.state));
        final subscription = node.states.listen((s) => texts.add(_describe(s)));
        addTearDown(subscription.cancel);
        return node;
      }

      final created = await observed(startNode());
      await created.rescan();
      await created.shutdown();

      await File('${dataDir().path}${_sep}identity${_sep}private-key.dpapi')
          .writeAsBytes(const [1, 2, 3]);
      final reset = await observed(startNode());
      expect(reset.state.identityStatus, IdentityStatus.reset);
      await reset.shutdown();

      final unreadable = await observed(
        startNode(protector: _FakeProtector(throwOnUnprotect: true)),
      );
      expect(unreadable.state.identityStatus, IdentityStatus.failed);
      await unreadable.shutdown();

      final leaky = _FakeProtector(leakOnProtect: true);
      final other = Directory('${root.path}${_sep}other');
      final failed = await observed(startNode(dir: other, protector: leaky));
      expect(failed.state.identityStatus, IdentityStatus.failed);
      await failed.retry();
      await failed.shutdown();

      expect(leaky.leakedPem, contains('PRIVATE KEY'));
      final all = [...texts, ...logs].join('\n');
      expect(all, isNot(contains('PRIVATE KEY')));
      for (final fragment in _pemFragments(leaky.leakedPem!)) {
        expect(all, isNot(contains(fragment)));
      }
      expect(
        failed.state.identityError,
        'could not create identity: '
        'StateError',
      );
    });
  });
}
