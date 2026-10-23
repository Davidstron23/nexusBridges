import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:nexus_bridges_core/src/storage/storage.dart';
import 'package:test/test.dart';

void _pokeForever((String, String, SendPort) args) {
  final (folder, file, reports) = args;
  var misses = 0;
  reports.send((0, misses));
  for (var round = 1; ; round++) {
    try {
      File(file).statSync();
    } on FileSystemException {
      misses++;
    }
    try {
      Directory(folder).listSync();
    } on FileSystemException {
      misses++;
    }
    if (round % 50 == 0) reports.send((round, misses));
  }
}

final class _Poker {
  _Poker._(this._isolate, this._reports, this._exit);

  final Isolate _isolate;
  final ReceivePort _reports;
  final ReceivePort _exit;
  int rounds = 0;

  static Future<_Poker> start(Directory folder, File file) async {
    final reports = ReceivePort();
    final exit = ReceivePort();
    final started = Completer<void>();
    final isolate = await Isolate.spawn(_pokeForever, (
      folder.path,
      file.path,
      reports.sendPort,
    ), onExit: exit.sendPort);
    final poker = _Poker._(isolate, reports, exit);
    reports.listen((message) {
      final (rounds, _) = message as (int, int);
      poker.rounds = rounds;
      if (!started.isCompleted) started.complete();
    });
    await started.future;
    return poker;
  }

  Future<void> stop() async {
    final exited = _exit.first;
    _isolate.kill(priority: Isolate.immediate);
    await exited;
    _reports.close();
  }
}

final class _ExclusiveLock {
  _ExclusiveLock._(this._handle);

  final RandomAccessFile _handle;
  bool _held = true;

  static Future<_ExclusiveLock> take(File file) async {
    final handle = await file.open(mode: FileMode.append);
    await handle.lock(FileLock.exclusive);
    return _ExclusiveLock._(handle);
  }

  Future<void> release() async {
    if (!_held) return;
    _held = false;
    await _handle.unlock();
    await _handle.close();
  }
}

void main() {
  late Directory temp;
  late File pairedFile;

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('nexus_rename_retry_test_');
    addTearDown(() => temp.delete(recursive: true));
    pairedFile = File('${temp.path}${Platform.pathSeparator}paired.json');
  });

  Future<List<String>> namesIn(Directory dir) async {
    final names = await dir
        .list()
        .map((e) => e.uri.pathSegments.lastWhere((s) => s.isNotEmpty))
        .toList();
    return names..sort();
  }

  List<int> contentOf(int write) =>
      utf8.encode('{"version": 2, "write": $write, "pad": "${'x' * 512}"}');

  Future<_ExclusiveLock> lock(File file) async {
    final held = await _ExclusiveLock.take(file);
    addTearDown(held.release);
    return held;
  }

  group('C107: writeFileAtomic retries the rename (plan v4)', () {
    test('200 writes in a row while another isolate stats the file and lists '
        'the folder: all succeed and the last one stays', () async {
      await pairedFile.writeAsBytes(contentOf(-1));
      final poker = await _Poker.start(temp, pairedFile);
      final roundsBefore = poker.rounds;
      final failures = <Object>[];

      for (var i = 0; i < 200; i++) {
        try {
          await writeFileAtomic(pairedFile, contentOf(i));
        } on FileSystemException catch (e) {
          failures.add(e);
        }
      }
      final roundsDuring = poker.rounds - roundsBefore;
      await poker.stop();

      expect(failures, isEmpty);
      expect(roundsDuring, greaterThan(0));
      expect(await pairedFile.readAsBytes(), contentOf(199));
      expect(await namesIn(temp), ['paired.json']);
    }, timeout: const Timeout(Duration(minutes: 2)));

    test('a file locked for longer than the retries: the write fails after '
        'them and no .tmp is left', () async {
      await pairedFile.writeAsBytes(contentOf(-1));
      final held = await lock(pairedFile);
      final lockedAt = Stopwatch()..start();

      final writing = Stopwatch()..start();
      await expectLater(
        writeFileAtomic(pairedFile, contentOf(1)),
        throwsA(isA<FileSystemException>()),
      );
      writing.stop();
      final rest = const Duration(seconds: 1) - lockedAt.elapsed;
      if (rest > Duration.zero) await Future<void>.delayed(rest);
      await held.release();

      expect(
        lockedAt.elapsed,
        greaterThanOrEqualTo(const Duration(seconds: 1)),
      );
      expect(
        writing.elapsed,
        greaterThanOrEqualTo(const Duration(milliseconds: 580)),
      );
      expect(await pairedFile.readAsBytes(), contentOf(-1));
      expect(await namesIn(temp), ['paired.json']);
    });

    test('after that failure the next write works normally', () async {
      await pairedFile.writeAsBytes(contentOf(-1));
      final held = await lock(pairedFile);
      await expectLater(
        writeFileAtomic(pairedFile, contentOf(1)),
        throwsA(isA<FileSystemException>()),
      );
      await held.release();

      await writeFileAtomic(pairedFile, contentOf(2));

      expect(await pairedFile.readAsBytes(), contentOf(2));
      expect(await namesIn(temp), ['paired.json']);
    });

    test('a lock released during the retries: the write ends well', () async {
      await pairedFile.writeAsBytes(contentOf(-1));
      final held = await lock(pairedFile);
      final releasing = Future<void>.delayed(
        const Duration(milliseconds: 150),
        held.release,
      );

      final writing = Stopwatch()..start();
      await writeFileAtomic(pairedFile, contentOf(1));
      writing.stop();
      await releasing;

      expect(
        writing.elapsed,
        greaterThanOrEqualTo(const Duration(milliseconds: 140)),
      );
      expect(await pairedFile.readAsBytes(), contentOf(1));
      expect(await namesIn(temp), ['paired.json']);
    });

    test('JsonFileStore.write gets the same retries', () async {
      final store = JsonFileStore(pairedFile);
      await store.write({'version': 1, 'step': 'before'});
      final held = await lock(pairedFile);
      final releasing = Future<void>.delayed(
        const Duration(milliseconds: 100),
        held.release,
      );

      await store.write({'version': 1, 'step': 'after'});
      await releasing;

      expect(await store.read(), {'version': 1, 'step': 'after'});
      expect(await namesIn(temp), ['paired.json']);
    });
  });
}
