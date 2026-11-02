import 'dart:async';
import 'dart:collection';
import 'dart:ffi';
import 'dart:isolate';
import 'dart:math';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

import '../protocol/protocol.dart' show Limits;
import '../transport/transport.dart' show AbortSignal;
import 'folder_plan.dart' show FolderPlan;
import 'folder_stream.dart' show encodeFrameHeader;
import 'hashing.dart' show startSha256;
import 'windows_folder_io.dart'
    show ReadCancelGate, ReadCancelPort, openFileForSend;

const Duration _cancelGrace = Duration(milliseconds: 500);

const int _flushBytes = 65536;
const int _readBytes = 262144;
const int _creditChunks = 8;

const int _openCommand = 0;
const int _creditCommand = 1;
const int _stopCommand = 2;

const int _chunkMessage = 0;
const int _doneMessage = 1;

final class FolderEntryProblem implements Exception {
  const FolderEntryProblem(this.entry);

  final int entry;
}

String _join(String folder, String name) =>
    folder.endsWith(r'\') ? '$folder$name' : '$folder\\$name';

sealed class FolderReadEvent {
  const FolderReadEvent();
}

final class FolderReadChunk extends FolderReadEvent {
  const FolderReadChunk(this.bytes);

  final Uint8List bytes;
}

final class FolderReadDone extends FolderReadEvent {
  const FolderReadDone({required this.ok});

  final bool ok;
}

final class _ReadRequest {
  const _ReadRequest({
    required this.port,
    required this.strict,
    required this.cancelSlot,
    required this.cancelMutex,
  });

  final int cancelSlot;
  final int cancelMutex;
  final SendPort port;
  final bool strict;
}

Future<bool> _readEntry({
  required _ReadRequest request,
  required Pointer<Uint8> buffer,
  required String path,
  required int expected,
  required String? hashHex,
  required int volume,
  required int index,
  required bool Function() stopped,
  required Future<void> Function() creditAvailable,
  required void Function() spendCredit,
}) async {
  final reader = openFileForSend(
    path: path,
    volume: volume,
    index: index,
    size: request.strict ? expected : null,
    cancelPort: ReadCancelPort(request.cancelSlot, request.cancelMutex),
  );
  if (reader == null) return false;
  final digest = startSha256();
  try {
    var remaining = expected;
    while (remaining > 0) {
      await creditAvailable();
      if (stopped()) return false;
      final count = reader.read(buffer, min(remaining, _readBytes));
      if (count <= 0) return false;
      final view = buffer.asTypedList(count);
      digest.add(view);
      spendCredit();
      request.port.send(<Object>[
        _chunkMessage,
        TransferableTypedData.fromList([view]),
      ]);
      remaining -= count;
    }
    if (!request.strict) return true;
    if (reader.read(buffer, 1) != 0) return false;
    final hex = digest.close();
    return hex != null && hex == hashHex;
  } finally {
    digest.dispose();
    reader.close();
  }
}

Future<void> _readerMain(_ReadRequest request) async {
  final commands = ReceivePort();
  final pending = Queue<List<Object?>>();
  var credits = _creditChunks;
  var stopped = false;
  Completer<void>? wake;
  void notify() {
    final waiting = wake;
    wake = null;
    if (waiting != null && !waiting.isCompleted) waiting.complete();
  }

  Future<void> sleep() {
    final waiting = wake ??= Completer<void>();
    return waiting.future;
  }

  commands.listen((message) {
    final list = message as List<Object?>;
    switch (list[0] as int) {
      case _openCommand:
        pending.add(list);
      case _creditCommand:
        if (credits < _creditChunks) credits++;
      default:
        stopped = true;
    }
    notify();
  });
  request.port.send(commands.sendPort);
  final buffer = calloc<Uint8>(_readBytes);
  try {
    while (!stopped) {
      if (pending.isEmpty) {
        await sleep();
        continue;
      }
      final command = pending.removeFirst();
      var ok = false;
      try {
        ok = await _readEntry(
          request: request,
          buffer: buffer,
          path: command[1] as String,
          expected: command[2] as int,
          hashHex: command[3] as String?,
          volume: command[4] as int,
          index: command[5] as int,
          stopped: () => stopped,
          creditAvailable: () async {
            while (credits == 0 && !stopped) {
              await sleep();
            }
            await Future<void>.delayed(Duration.zero);
          },
          spendCredit: () => credits--,
        );
      } catch (_) {
        ok = false;
      }
      request.port.send(<Object>[_doneMessage, ok]);
    }
  } finally {
    calloc.free(buffer);
    commands.close();
  }
}

final class FolderReadJob {
  FolderReadJob._()
    : _port = ReceivePort(),
      _exit = ReceivePort(),
      _gate = ReadCancelGate.create() {
    _port.listen(_onMessage);
    _exit.listen((_) {
      _markDead();
      _releaseGate();
    });
  }

  final ReceivePort _port;
  final ReceivePort _exit;
  final ReadCancelGate _gate;
  bool _gateReleased = false;
  final Queue<FolderReadEvent> _events = Queue<FolderReadEvent>();
  final List<List<Object?>> _early = [];
  SendPort? _commands;
  Completer<void>? _waiter;
  Isolate? _isolate;
  Timer? _killTimer;
  bool _dead = false;
  bool _closed = false;
  bool _portClosed = false;

  static FolderReadJob start({required bool strict}) {
    final job = FolderReadJob._();
    final request = _ReadRequest(
      port: job._port.sendPort,
      strict: strict,
      cancelSlot: job._gate.slotAddress,
      cancelMutex: job._gate.mutexAddress,
    );
    Isolate.spawn(_readerMain, request, onExit: job._exit.sendPort).then(
      (isolate) {
        job._isolate = isolate;
        if (job._closed) job._scheduleKill();
      },
      onError: (Object _) {
        job._markDead();
        job._releaseGate();
      },
    );
    return job;
  }

  void _releaseGate() {
    if (_gateReleased) return;
    _gateReleased = true;
    _exit.close();
    _gate.dispose();
  }

  void open({
    required String path,
    required int size,
    required String? hashHex,
    required int volume,
    required int index,
  }) {
    if (_closed || _dead) return;
    final command = <Object?>[_openCommand, path, size, hashHex, volume, index];
    final commands = _commands;
    if (commands == null) {
      _early.add(command);
    } else {
      commands.send(command);
    }
  }

  void acknowledge() {
    _commands?.send(const <Object>[_creditCommand]);
  }

  Future<FolderReadEvent?> next() async {
    while (true) {
      if (_events.isNotEmpty) return _events.removeFirst();
      if (_dead || _closed) return null;
      final waiter = _waiter ??= Completer<void>();
      await waiter.future;
    }
  }

  void interrupt() {
    _closed = true;
    _wake();
  }

  void close() {
    if (_closed && _killTimer != null) return;
    _closed = true;
    _commands?.send(const <Object>[_stopCommand]);
    _wake();
    if (!_dead) _scheduleKill();
  }

  void _scheduleKill() {
    _killTimer ??= Timer(Limits.workerStopGrace, () {
      _gate.cancelPending();
      _killTimer = Timer(_cancelGrace, () {
        _isolate?.kill(priority: Isolate.immediate);
        _markDead();
      });
    });
  }

  void _onMessage(Object? message) {
    if (message is SendPort) {
      _commands = message;
      for (final command in _early) {
        message.send(command);
      }
      _early.clear();
      if (_closed) message.send(const <Object>[_stopCommand]);
    } else if (message is List<Object?>) {
      if (message[0] == _chunkMessage) {
        _events.add(
          FolderReadChunk(
            (message[1] as TransferableTypedData).materialize().asUint8List(),
          ),
        );
      } else {
        _events.add(FolderReadDone(ok: message[1] as bool));
      }
      _wake();
    } else if (message == null) {
      _markDead();
    }
  }

  void _markDead() {
    _dead = true;
    _killTimer?.cancel();
    _killTimer = null;
    if (!_portClosed) {
      _portClosed = true;
      _port.close();
    }
    _wake();
  }

  void _wake() {
    final waiting = _waiter;
    _waiter = null;
    if (waiting != null && !waiting.isCompleted) waiting.complete();
  }
}

Stream<List<int>> folderStream(
  FolderPlan plan, {
  required AbortSignal abort,
  required Future<void> Function(int entry) onEntryProblem,
  required Future<void> Function(int entry) beforeEntry,
}) async* {
  final manifest = plan.manifest;
  final committed = BytesBuilder(copy: false);
  final pending = BytesBuilder(copy: false);
  final job = FolderReadJob.start(strict: true);
  final remove = abort.onAbort(job.interrupt);
  try {
    var ordinal = 0;
    for (final index in manifest.fileIndexes) {
      if (abort.aborted) return;
      await beforeEntry(index);
      if (abort.aborted) return;
      pending.add(encodeFrameHeader(index, manifest.sizeOf(index)));
      job.open(
        path: _join(plan.rootPath, manifest.relativePath(index)),
        size: manifest.sizeOf(index),
        hashHex: manifest.hashHexOf(index),
        volume: plan.fileVolumes[ordinal],
        index: plan.fileIndexes[ordinal],
      );
      ordinal++;
      var ok = false;
      while (true) {
        final event = await job.next();
        if (abort.aborted) return;
        if (event is FolderReadChunk) {
          pending.add(event.bytes);
          job.acknowledge();
          if (pending.length >= _flushBytes) {
            committed.add(pending.takeBytes());
            yield committed.takeBytes();
          }
          continue;
        }
        ok = event is FolderReadDone && event.ok;
        break;
      }
      if (!ok) {
        pending.clear();
        if (committed.length > 0) yield committed.takeBytes();
        await onEntryProblem(index);
        throw FolderEntryProblem(index);
      }
      committed
        ..add(pending.takeBytes())
        ..addByte(0);
      if (committed.length >= _flushBytes) yield committed.takeBytes();
    }
    if (committed.length > 0) yield committed.takeBytes();
  } finally {
    remove();
    job.close();
  }
}
