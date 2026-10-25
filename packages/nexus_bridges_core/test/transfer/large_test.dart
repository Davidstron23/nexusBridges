@TestOn('windows')
@Tags(['large'])
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:nexus_bridges_core/src/node/node.dart';
import 'package:nexus_bridges_core/src/pairing/pairing.dart';
import 'package:nexus_bridges_core/src/transfer/hashing.dart';
import 'package:nexus_bridges_core/src/transfer/windows_file_system.dart';
import 'package:nexus_bridges_core/src/transport/transport.dart'
    show AbortSignal;
import 'package:test/test.dart';

import 'attacks_harness.dart';
import 'transfer_stacks_harness.dart' show transferFolder;

const int memoryBudget = 100 * 1000 * 1000;

const Duration hashBudget = Duration(seconds: 15);

Future<void> writeBigFile(String path, int size, int seed) async {
  final random = Random(seed);
  final block = Uint8List(mib);
  for (var i = 0; i < mib; i++) {
    block[i] = random.nextInt(256);
  }
  final sink = await File(path).open(mode: FileMode.writeOnly);
  try {
    var written = 0;
    var n = 0;
    while (written < size) {
      block[0] = n & 0xFF;
      block[1] = (n >> 8) & 0xFF;
      block[2] = (n >> 16) & 0xFF;
      final take = min(mib, size - written);
      await sink.writeFrom(block, 0, take);
      written += take;
      n++;
    }
  } finally {
    await sink.close();
  }
  expect(await File(path).length(), size);
}

Future<String> digestFile(String path) async =>
    (await hashFile(path, abort: AbortSignal()))!.sha256;

final class Child {
  Child._(this.role, this._process) {
    _process.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen((line) {
          try {
            events.add(jsonDecode(line) as Map<String, Object?>);
          } on FormatException {
            output.add(line);
          }
        });
    _process.stderr
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen(output.add);
  }

  final String role;
  final Process _process;
  final List<Map<String, Object?>> events = [];
  final List<String> output = [];
  int _read = 0;

  static Future<Child> start(String role, String address, String work) async {
    final process = await Process.start(Platform.resolvedExecutable, [
      'test/transfer/large_child.dart',
      role,
      address,
      work,
    ], workingDirectory: Directory.current.path);
    final child = Child._(role, process);
    addTearDown(child.stop);
    return child;
  }

  void send(Map<String, Object?> command) =>
      _process.stdin.writeln(jsonEncode(command));

  Future<Map<String, Object?>> next(
    String event, {
    Duration limit = const Duration(minutes: 2),
  }) async {
    final watch = Stopwatch()..start();
    while (true) {
      for (var i = _read; i < events.length; i++) {
        if (events[i]['event'] == event) {
          _read = i + 1;
          return events[i];
        }
      }
      if (watch.elapsed > limit) {
        fail('$role did not send $event within $limit: $events $output');
      }
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
  }

  Future<void> stop() async {
    try {
      send({'cmd': 'exit'});
    } catch (_) {}
    final code = await _process.exitCode.timeout(
      const Duration(seconds: 10),
      onTimeout: () {
        _process.kill();
        return -1;
      },
    );
    if (code != 0) printOnFailure('$role exit $code: $output');
  }
}

void main() {
  test('E53 NFR memory, R48: 5 GiB between two stacks in child processes '
      'grow less than 100 MB on each side and arrive whole', () async {
    final root = await transferFolder('nexus_t15_e53_');
    final base = (await const WindowsFileSystemPlatform().realPath(root.path))!;
    final source = '$base\\source';
    Directory(source).createSync();
    final path = '$source\\cinco.bin';
    const size = 5 * gib;
    await writeBigFile(path, size, 53);

    final receiver = await Child.start('receive', '127.0.0.32', '$base\\r');
    final sender = await Child.start('send', '127.0.0.31', '$base\\s');
    final r = await receiver.next('ready');
    final s = await sender.next('ready');
    receiver.send({
      'cmd': 'trust',
      'fingerprint': s['fingerprint'],
      'pem': s['pem'],
    });
    sender.send({
      'cmd': 'trust',
      'fingerprint': r['fingerprint'],
      'pem': r['pem'],
    });
    await receiver.next('trusted');
    await sender.next('trusted');
    receiver.send({'cmd': 'baseline'});
    sender.send({'cmd': 'baseline'});
    final receiverRest = (await receiver.next('baseline'))['rss']! as int;
    final senderRest = (await sender.next('baseline'))['rss']! as int;

    final watch = Stopwatch()..start();
    sender.send({
      'cmd': 'send',
      'path': path,
      'address': '127.0.0.32',
      'port': r['port'],
      'fingerprint': r['fingerprint'],
    });
    expect((await sender.next('started'))['result'], 'started');
    final sent = await sender.next('sent', limit: const Duration(minutes: 25));
    final received = await receiver.next(
      'received',
      limit: const Duration(minutes: 2),
    );
    watch.stop();
    receiver.send({'cmd': 'report'});
    sender.send({'cmd': 'report'});
    final receiverReport = await receiver.next('report');
    final senderReport = await sender.next('report');

    final receiverGrowth = (receiverReport['peak']! as int) - receiverRest;
    final senderGrowth = (senderReport['peak']! as int) - senderRest;
    print(
      'E53 5 GiB in ${watch.elapsed.inSeconds} s; '
      'receiver rest ${receiverRest ~/ 1000000} MB, '
      'growth ${receiverGrowth ~/ 1000000} MB, '
      '${receiverReport['samples']} samples; '
      'sender rest ${senderRest ~/ 1000000} MB, '
      'growth ${senderGrowth ~/ 1000000} MB, '
      '${senderReport['samples']} samples',
    );
    expect(sent['outcome'], 'saved');
    expect(sent['bytes'], size);
    expect(received['outcome'], 'saved');
    expect(receiverGrowth, lessThan(memoryBudget));
    expect(senderGrowth, lessThan(memoryBudget));

    final arrived = '$base\\r\\recv\\cinco.bin';
    expect(await File(arrived).length(), size);
    expect(await digestFile(arrived), await digestFile(path));
    expect(Directory('$base\\r\\recv').listSync().length, 1);
  }, timeout: const Timeout(Duration(minutes: 40)));

  group('E130 NFR R37 R48: speed and a huge file', () {
    test('hashFile of 1 GiB is timed and should take less than 15 s on the '
        'main PC', () async {
      final root = await transferFolder('nexus_t15_e130_');
      final path = '${root.path}\\uno.bin';
      await writeBigFile(path, gib, 130);

      final watch = Stopwatch()..start();
      final digest = await hashFile(path, abort: AbortSignal());
      watch.stop();

      print('E130 hashFile of 1 GiB: ${watch.elapsedMilliseconds} ms');
      if (watch.elapsed >= hashBudget) {
        print(
          'AVISO E130: hashFile de 1 GiB tarda ${watch.elapsed.inSeconds} s '
          '(mas de 15 s); repetir en el PC principal (R37)',
        );
      }
      expect(digest!.size, gib);
      expect(digest.sha256, matches(RegExp(r'^[0-9a-f]{64}$')));
    }, timeout: const Timeout(Duration(minutes: 10)));

    test('4 GiB plus 1 byte from node to node arrives whole', () async {
      final [a, b] = await transferNodes(['Laptop', 'Sobremesa']);
      await a.trust([(b, PeerRelation.mine)]);
      await b.trust([(a, PeerRelation.mine)]);
      await b.rememberReceiveFolder();
      await startAll([a, b]);
      await meetAll([a, b]);
      await canSend(a, b);
      const size = 4 * gib + 1;
      final path = '${a.sourceDir}\\enorme.bin';
      await writeBigFile(path, size, 4);

      final watch = Stopwatch()..start();
      expect(await a.sendTo(b, path), SendFileResult.started);
      final sent = await a.sentResult(limit: const Duration(minutes: 25));
      final received = await b.receivedResult(
        limit: const Duration(minutes: 2),
      );
      watch.stop();
      print('E130 4 GiB + 1 byte node to node: ${watch.elapsed.inSeconds} s');

      expect(sent.outcome, TransferOutcome.saved);
      expect(received.outcome, TransferOutcome.saved);
      final arrived = '${b.receiveDir}\\enorme.bin';
      expect(await File(arrived).length(), size);
      expect(await digestFile(arrived), await digestFile(path));
      expect(anyTempIn(b.receiveDir), isFalse);
    }, timeout: const Timeout(Duration(minutes: 40)));
  });
}
