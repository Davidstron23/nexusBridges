@TestOn('windows')
library;

import 'dart:async';
import 'dart:ffi';
import 'dart:isolate';

import 'package:ffi/ffi.dart';
import 'package:nexus_bridges_core/src/transfer/windows_folder_io.dart';
import 'package:test/test.dart';
import 'package:win32/win32.dart';

import 'transfer_stacks_harness.dart' show randomHex;

const int operationAborted = 995;

const Duration blockedFor = Duration(milliseconds: 400);

const Duration bound = Duration(seconds: 2);

final class BlockedRead {
  const BlockedRead(this.pipe, this.slot, this.mutex, this.port);

  final String pipe;
  final int slot;
  final int mutex;
  final SendPort port;
}

void readForever(BlockedRead request) {
  final cancel = ReadCancelPort(request.slot, request.mutex);
  final handle = using(
    (Arena arena) => CreateFile(
      arena.pcwstr(request.pipe),
      0x80000000,
      FILE_SHARE_MODE(0),
      null,
      OPEN_EXISTING,
      FILE_FLAGS_AND_ATTRIBUTES(0),
      null,
    ).value,
  );
  if (!handle.isValid) {
    request.port.send(const <Object>['open failed']);
    return;
  }
  final buffer = calloc<Uint8>(16);
  final count = calloc<Uint32>();
  cancel.publish(handle);
  try {
    request.port.send(const <Object>['reading']);
    final Win32Result(value: ok, error: error) = ReadFile(
      handle,
      buffer,
      16,
      count,
      null,
    );
    request.port.send(<Object>['returned', ok, error]);
  } finally {
    cancel.retract();
    handle.close();
    calloc.free(buffer);
    calloc.free(count);
  }
}

final class BlockedReader {
  BlockedReader._(this.gate, this.isolate);

  final ReadCancelGate gate;
  final Isolate isolate;
  final Completer<void> reading = Completer<void>();
  final Completer<List<Object?>> returned = Completer<List<Object?>>();
  final Completer<void> exited = Completer<void>();

  static Future<BlockedReader> start() async {
    final gate = ReadCancelGate.create();
    addTearDown(gate.dispose);
    final name = r'\\.\pipe\nexus-b4-' + randomHex(8);
    final server = using(
      (Arena arena) => CreateNamedPipe(
        arena.pcwstr(name),
        PIPE_ACCESS_DUPLEX,
        NAMED_PIPE_MODE(0),
        1,
        512,
        512,
        0,
        null,
      ),
    );
    expect(server.isValid, isTrue, reason: 'pipe $name');
    final messages = ReceivePort();
    final exit = ReceivePort();
    final isolate = await Isolate.spawn(
      readForever,
      BlockedRead(name, gate.slotAddress, gate.mutexAddress, messages.sendPort),
      onExit: exit.sendPort,
    );
    final reader = BlockedReader._(gate, isolate);
    addTearDown(() async {
      server.close();
      await reader.exited.future.timeout(bound, onTimeout: () {});
      messages.close();
      exit.close();
    });
    messages.listen((message) {
      final list = message as List<Object?>;
      switch (list[0]) {
        case 'reading':
          reader.reading.complete();
        case 'returned':
          reader.returned.complete(list);
        default:
          fail('the reader could not open the pipe');
      }
    });
    exit.listen((_) {
      if (!reader.exited.isCompleted) reader.exited.complete();
    });
    await reader.reading.future.timeout(const Duration(seconds: 10));
    await Future<void>.delayed(blockedFor);
    expect(reader.returned.isCompleted, isFalse, reason: 'the read blocks');
    expect(reader.exited.isCompleted, isFalse, reason: 'the reader is alive');
    return reader;
  }
}

void main() {
  group('B-4: a read blocked in ReadFile is cancelled before the kill', () {
    test('cancelPending makes the blocked ReadFile return aborted at once, '
        'and the reader isolate ends on its own', () async {
      final reader = await BlockedReader.start();
      final watch = Stopwatch()..start();

      reader.gate.cancelPending();

      final result = await reader.returned.future.timeout(bound);
      await reader.exited.future.timeout(bound);
      expect(watch.elapsed, lessThan(bound));
      expect(result[1], isFalse);
      expect(result[2], operationAborted);
    });

    test('Isolate.kill alone does not free a blocked reader; the cancel '
        'does, within a bounded time', () async {
      final reader = await BlockedReader.start();

      reader.isolate.kill(priority: Isolate.immediate);
      await Future<void>.delayed(blockedFor);
      expect(reader.exited.isCompleted, isFalse, reason: 'kill waits on I/O');
      final watch = Stopwatch()..start();
      reader.gate.cancelPending();

      await reader.exited.future.timeout(bound);
      expect(watch.elapsed, lessThan(bound));
    });

    test('a second cancel after the reader retracted its handle does '
        'nothing and does not throw', () async {
      final reader = await BlockedReader.start();
      reader.gate.cancelPending();
      await reader.exited.future.timeout(bound);

      expect(reader.gate.cancelPending, returnsNormally);
    });

    test('a gate with nothing published cancels nothing and does not '
        'throw', () {
      final gate = ReadCancelGate.create();
      addTearDown(gate.dispose);

      expect(gate.cancelPending, returnsNormally);
    });
  });
}
