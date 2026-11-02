@TestOn('windows')
@Tags(['large'])
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:nexus_bridges_core/src/transfer/folders.dart';
import 'package:nexus_bridges_core/src/transfer/windows_folder_io.dart';
import 'package:test/test.dart';

import 'receiver_harness.dart' show realFs;

Future<String> largeFolder(String prefix) async {
  final dir = await Directory.systemTemp.createTemp(prefix);
  addTearDown(() async {
    for (var attempt = 0; attempt < 50; attempt++) {
      if (deleteTreeNoFollowSync(dir.path)) return;
      await Future<void>.delayed(const Duration(milliseconds: 200));
    }
  });
  return (await realFs.realPath(dir.path))!;
}

Future<void> waitFor(
  bool Function() condition, {
  required String reason,
  Duration limit = const Duration(seconds: 30),
}) async {
  final watch = Stopwatch()..start();
  while (!condition()) {
    if (watch.elapsed > limit) fail('$reason not reached within $limit');
    await Future<void>.delayed(const Duration(milliseconds: 100));
  }
}

Set<String> listingOf(String root) {
  final dir = Directory(root);
  if (!dir.existsSync()) return {};
  return {
    for (final entity in dir.listSync(recursive: true, followLinks: false))
      entity.path.substring(root.length),
  };
}

String? _compiledChild;

void useCompiledChild() {
  Directory? dir;
  setUpAll(() async {
    final created = await Directory.systemTemp.createTemp('nexus_child_');
    dir = created;
    final out = '${created.path}\\folder_child.exe';
    final result = await Process.run(Platform.resolvedExecutable, [
      'compile',
      'exe',
      'test/transfer/folder_child.dart',
      '-o',
      out,
    ], workingDirectory: Directory.current.path);
    if (result.exitCode != 0) {
      fail('folder_child.dart did not compile: ${result.stdout}');
    }
    _compiledChild = out;
  });
  tearDownAll(() async {
    _compiledChild = null;
    try {
      await dir?.delete(recursive: true);
    } on FileSystemException {
      return;
    }
  });
}

final class FolderChild {
  FolderChild._(this.role, this._process) {
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
    unawaited(_process.stdin.done.catchError((_) {}));
    unawaited(_process.exitCode.then((code) => exitCode = code));
  }

  final String role;
  final Process _process;
  final List<Map<String, Object?>> events = [];
  final List<String> output = [];
  int? exitCode;
  int _read = 0;

  static Future<FolderChild> start(
    String role,
    String address,
    String work, [
    List<String> options = const [],
  ]) async {
    final compiled = _compiledChild;
    final process = await Process.start(
      compiled ?? Platform.resolvedExecutable,
      [
        if (compiled == null) 'test/transfer/folder_child.dart',
        role,
        address,
        work,
        ...options,
      ],
      workingDirectory: Directory.current.path,
    );
    final child = FolderChild._(role, process);
    addTearDown(child.stop);
    return child;
  }

  void send(Map<String, Object?> command) {
    if (exitCode != null) return;
    try {
      _process.stdin.writeln(jsonEncode(command));
    } catch (_) {}
  }

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
      if (exitCode != null) {
        fail('$role ended with $exitCode before $event: $events $output');
      }
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
  }

  Future<int> kill() async {
    _process.kill(ProcessSignal.sigkill);
    return _process.exitCode.timeout(const Duration(seconds: 20));
  }

  Future<void> stop() async {
    send({'cmd': 'exit'});
    final code = await _process.exitCode.timeout(
      const Duration(seconds: 30),
      onTimeout: () {
        _process.kill();
        return -1;
      },
    );
    if (code != 0) printOnFailure('$role exit $code: $output');
  }
}

Future<void> trustEachOther(FolderChild a, FolderChild b) async {
  final ra = await a.next('ready');
  final rb = await b.next('ready');
  a.send({'cmd': 'trust', 'fingerprint': rb['fingerprint'], 'pem': rb['pem']});
  b.send({'cmd': 'trust', 'fingerprint': ra['fingerprint'], 'pem': ra['pem']});
  await a.next('trusted');
  await b.next('trusted');
}

void sendFolder(
  FolderChild sender,
  Map<String, Object?> receiver,
  String path,
  String address,
) {
  sender.send({
    'cmd': 'send',
    'path': path,
    'address': address,
    'port': receiver['port'],
    'fingerprint': receiver['fingerprint'],
  });
}

Future<String> projectFolder(String base) async {
  final root = '$base\\source\\Proyecto';
  Directory('$root\\src').createSync(recursive: true);
  final random = Random(471);
  final block = Uint8List(256 * 1024);
  for (var i = 0; i < 24; i++) {
    for (var b = 0; b < block.length; b += 64) {
      block[b] = random.nextInt(256);
    }
    block[0] = i;
    final folder = i.isEven ? root : '$root\\src';
    File('$folder\\part$i.bin').writeAsBytesSync(block);
  }
  return root;
}

final class KilledReceiver {
  KilledReceiver(this.base, this.receiveWork, this.receiveDir, this.temp);

  final String base;
  final String receiveWork;
  final String receiveDir;
  final String temp;

  String get incoming => '$receiveDir\\$tempFolderName';
}

Future<KilledReceiver> killReceiverMidFolder(String prefix) async {
  final base = await largeFolder(prefix);
  final source = await projectFolder(base);
  final receiveWork = '$base\\r';
  final receiver = await FolderChild.start(
    'receive',
    '127.0.0.42',
    receiveWork,
    ['--notify-at=3'],
  );
  final sender = await FolderChild.start('send', '127.0.0.41', '$base\\s', [
    '--hold-at=12',
  ]);
  await trustEachOther(receiver, sender);
  final ready = receiver.events.firstWhere((e) => e['event'] == 'ready');
  final receiveDir = '$receiveWork\\recv';
  expect(listingOf(receiveDir), isEmpty);

  sendFolder(sender, ready, source, '127.0.0.42');
  await sender.next('started');
  await sender.next('holding', limit: const Duration(minutes: 1));
  await receiver.next('reached', limit: const Duration(minutes: 1));

  final incoming = '$receiveDir\\$tempFolderName';
  final temps = Directory(incoming)
      .listSync(followLinks: false)
      .where((e) => isOwnFolderTempName(e.path.split('\\').last))
      .toList();
  expect(temps, hasLength(1));
  final temp = temps.single.path;
  expect(
    Directory(temp)
        .listSync(recursive: true, followLinks: false)
        .whereType<File>(),
    isNotEmpty,
  );

  final code = await receiver.kill();
  expect(code, isNot(0));
  expect(Directory(temp).existsSync(), isTrue);
  expect(
    Directory(receiveDir)
        .listSync(followLinks: false)
        .map((e) => e.path.split('\\').last),
    [tempFolderName],
  );

  sender.send({'cmd': 'release'});
  final sent = await sender.next('sent', limit: const Duration(minutes: 2));
  expect(sent['outcome'], isNot('saved'));
  printOnFailure('sender after the kill: ${sent['outcome']}');
  return KilledReceiver(base, receiveWork, receiveDir, temp);
}

Future<void> restartAndClean(KilledReceiver killed) async {
  final restarted = await FolderChild.start(
    'receive',
    '127.0.0.42',
    killed.receiveWork,
  );
  await restarted.next('ready');
  restarted.send({'cmd': 'cleanup'});
  await restarted.next('cleaned');
  await waitFor(
    () =>
        FileSystemEntity.typeSync(killed.temp, followLinks: false) ==
        FileSystemEntityType.notFound,
    reason: 'temp folder ${killed.temp} deleted',
  );
  await restarted.stop();
}

void main() {
  useCompiledChild();

  test('NFR folders: ten thousand small files (about 100 MB) between two '
      'child processes are timed and should arrive within 60 s', () async {
    final base = await largeFolder('nexus_nfr_small_');
    final source = '$base\\source\\Pequenos';
    final block = Uint8List(10 * 1024);
    for (var folder = 0; folder < 100; folder++) {
      final dir = '$source\\d$folder';
      Directory(dir).createSync(recursive: true);
      for (var i = 0; i < 100; i++) {
        block[0] = folder;
        block[1] = i;
        File('$dir\\f$i.bin').writeAsBytesSync(block);
      }
    }
    final receiver = await FolderChild.start(
      'receive',
      '127.0.0.62',
      '$base\\r',
    );
    final sender = await FolderChild.start('send', '127.0.0.61', '$base\\s');
    await trustEachOther(receiver, sender);
    final ready = receiver.events.firstWhere((e) => e['event'] == 'ready');

    final watch = Stopwatch()..start();
    sendFolder(sender, ready, source, '127.0.0.62');
    await sender.next('started');
    final sent = await sender.next('sent', limit: const Duration(minutes: 10));
    final received = await receiver.next('received');
    watch.stop();

    print('NFR 10 000 small files end to end: ${watch.elapsed.inSeconds} s');
    if (watch.elapsed > const Duration(seconds: 60)) {
      print(
        'AVISO NFR: 10 000 archivos pequenos tardan '
        '${watch.elapsed.inSeconds} s (mas de 60 s); repetir en el UAT',
      );
    }
    expect(sent['outcome'], 'saved');
    expect(received['outcome'], 'saved');
    expect(sent['files'], 10000);
    final arrived = '$base\\r\\recv\\Pequenos';
    expect(
      Directory(arrived)
          .listSync(recursive: true, followLinks: false)
          .whereType<File>()
          .length,
      10000,
    );
    expect(File('$arrived\\d99\\f99.bin').readAsBytesSync(), [
      99,
      99,
      ...List<int>.filled(10 * 1024 - 2, 0),
    ]);
  }, timeout: const Timeout(Duration(minutes: 15)));

  test('E471, RF-281: a receiver killed in the middle of a folder leaves a '
      'temp folder that the next start deletes, leaving the receive folder '
      'as it was before', () async {
    final killed = await killReceiverMidFolder('nexus_e471_a_');

    final watch = Stopwatch()..start();
    await restartAndClean(killed);
    print('E471 cleanup after restart: ${watch.elapsedMilliseconds} ms');

    await waitFor(
      () => listingOf(killed.receiveDir).isEmpty,
      reason: 'receive folder empty again',
      limit: const Duration(seconds: 10),
    );
    expect(Directory(killed.receiveDir).existsSync(), isTrue);
  }, timeout: const Timeout(Duration(minutes: 6)));

  test('E471 [SEG], RF-281, RF-235: the cleanup after the kill deletes only '
      'its temp folder; a user folder with the prefix outside the temp '
      'subfolder, user folders inside it without the pattern and the target '
      'of a junction with the pattern stay untouched', () async {
    final killed = await killReceiverMidFolder('nexus_e471_b_');
    final incoming = killed.incoming;

    final outside = '${killed.receiveDir}\\~nexusbridges-0123456789ab';
    Directory(outside).createSync();
    File('$outside\\mine.txt').writeAsStringSync('outside');
    final plain = '$incoming\\mis-cosas';
    Directory('$plain\\sub').createSync(recursive: true);
    File('$plain\\sub\\mine.txt').writeAsStringSync('plain');
    final almost = '$incoming\\~nexusbridges-mine';
    Directory(almost).createSync();
    File('$almost\\mine.txt').writeAsStringSync('almost');
    final precious = '${killed.base}\\precious';
    Directory('$precious\\deep').createSync(recursive: true);
    File('$precious\\marker.txt').writeAsStringSync('marker');
    File('$precious\\deep\\inner.txt').writeAsStringSync('inner');
    final junction = '$incoming\\~nexusbridges-fedcba987654';
    Link(junction).createSync(precious);
    expect(
      FileSystemEntity.typeSync(junction, followLinks: false),
      FileSystemEntityType.link,
    );
    final preciousBefore = listingOf(precious);
    final outsideBefore = listingOf(outside);
    final plainBefore = listingOf(plain);
    final almostBefore = listingOf(almost);

    await restartAndClean(killed);

    await waitFor(
      () =>
          FileSystemEntity.typeSync(junction, followLinks: false) ==
          FileSystemEntityType.notFound,
      reason: 'junction unlinked',
      limit: const Duration(seconds: 10),
    );
    expect(listingOf(precious), preciousBefore);
    expect(File('$precious\\marker.txt').readAsStringSync(), 'marker');
    expect(File('$precious\\deep\\inner.txt').readAsStringSync(), 'inner');
    expect(listingOf(outside), outsideBefore);
    expect(File('$outside\\mine.txt').readAsStringSync(), 'outside');
    expect(listingOf(plain), plainBefore);
    expect(File('$plain\\sub\\mine.txt').readAsStringSync(), 'plain');
    expect(listingOf(almost), almostBefore);
    expect(File('$almost\\mine.txt').readAsStringSync(), 'almost');
    expect(
      Directory(incoming)
          .listSync(followLinks: false)
          .map((e) => e.path.split('\\').last)
          .toSet(),
      {'mis-cosas', '~nexusbridges-mine'},
    );
    expect(
      Directory(killed.receiveDir)
          .listSync(followLinks: false)
          .map((e) => e.path.split('\\').last)
          .toSet(),
      {tempFolderName, '~nexusbridges-0123456789ab'},
    );
  }, timeout: const Timeout(Duration(minutes: 6)));
}
