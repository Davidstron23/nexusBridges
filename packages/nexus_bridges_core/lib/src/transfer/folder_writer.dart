import 'dart:async';
import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';
import 'dart:math';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:win32/win32.dart' show HANDLE;

import '../protocol/protocol.dart' show Limits;
import 'folder_stream.dart';
import 'folders.dart' show samePath, tempPrefix;
import 'hashing.dart' show Sha256Stream, startSha256;
import 'manifest.dart' show FolderManifest;
import 'transfer.dart' show TransferOutcome;
import 'windows_folder_io.dart';

const int _bufferBytes = 1048576;

sealed class FolderWriteResult {
  const FolderWriteResult();
}

final class FolderWritten extends FolderWriteResult {
  const FolderWritten();
}

final class FolderWriteFailed extends FolderWriteResult {
  const FolderWriteFailed(this.outcome, [this.entry]);

  final TransferOutcome outcome;
  final int? entry;
}

final class _WriterStart {
  const _WriterStart({
    required this.events,
    required this.tempFolder,
    required this.manifest,
    required this.supportsMark,
    required this.flagAddress,
  });

  final SendPort events;
  final String tempFolder;
  final FolderManifest manifest;
  final bool supportsMark;
  final int flagAddress;
}

final class _OpenFolder {
  const _OpenFolder(this.index, this.handle);

  final int index;
  final HANDLE handle;
}

String _randomHex12() {
  final random = Random.secure();
  final buffer = StringBuffer();
  for (var i = 0; i < 6; i++) {
    buffer.write(random.nextInt(256).toRadixString(16).padLeft(2, '0'));
  }
  return buffer.toString();
}

final class _TreeWriter {
  _TreeWriter(this._start)
    : _manifest = _start.manifest,
      _flag = Pointer<Uint8>.fromAddress(_start.flagAddress) {
    _parser = FrameParser(
      manifest: _manifest,
      onStart: _startFile,
      onData: _data,
      onEnd: _endFile,
    );
  }

  final _WriterStart _start;
  final FolderManifest _manifest;
  final Pointer<Uint8> _flag;
  late final FrameParser _parser;
  final Pointer<Uint8> _buffer = calloc<Uint8>(_bufferBytes);
  final List<_OpenFolder> _chain = [];
  final Set<int> _created = {};
  String? rootPath;
  String _rootFinal = '';
  HANDLE? _root;
  HANDLE? _file;
  HANDLE? _fileParent;
  Sha256Stream? _digest;
  int _used = 0;
  int _files = 0;
  int _dataBytes = 0;
  TransferOutcome? _failure;
  bool _finished = false;

  bool get failed => _failure != null;

  bool open() {
    String? path;
    for (var attempt = 0; attempt < 3 && path == null; attempt++) {
      final candidate = _join(
        _start.tempFolder,
        '$tempPrefix${_randomHex12()}',
      );
      if (createFolderByPathSync(candidate)) path = candidate;
    }
    if (path == null) return false;
    rootPath = path;
    setHiddenByPathSync(path);
    final opened = openRootSync(path);
    if (opened is! NodeCreated) {
      deleteTreeNoFollowSync(path);
      return false;
    }
    final resolved = finalPathOfHandle(opened.handle);
    if (resolved == null || !samePath(resolved, path)) {
      opened.handle.close();
      deleteTreeNoFollowSync(path);
      return false;
    }
    _root = opened.handle;
    _rootFinal = resolved;
    return true;
  }

  String _join(String folder, String name) =>
      folder.endsWith(r'\') ? '$folder$name' : '$folder\\$name';

  void _fail(TransferOutcome outcome, [int? entry]) {
    if (_failure != null) return;
    _failure = outcome;
    _start.events.send(<int>[1, outcome.index, entry ?? -1]);
  }

  HANDLE? _ensureFolder(int folderIndex, int entry) {
    final path = <int>[];
    for (var c = folderIndex; c != 0; c = _manifest.parentOf(c)) {
      path.add(c);
    }
    final ordered = path.reversed.toList();
    var common = 0;
    while (common < _chain.length &&
        common < ordered.length &&
        _chain[common].index == ordered[common]) {
      common++;
    }
    while (_chain.length > common) {
      _chain.removeLast().handle.close();
    }
    for (var depth = common; depth < ordered.length; depth++) {
      final parent = depth == 0 ? _root! : _chain[depth - 1].handle;
      final index = ordered[depth];
      final result = createFolderExclusive(
        parent,
        _manifest.nameOf(index),
        rootFinal: _rootFinal,
        existing: _created.contains(index),
      );
      switch (result) {
        case NodeCreated(:final handle):
          _created.add(index);
          _chain.add(_OpenFolder(index, handle));
        case NodeFailed(:final diskFull):
          _fail(
            diskFull ? TransferOutcome.diskFull : TransferOutcome.writeFailed,
            entry,
          );
          return null;
      }
    }
    return ordered.isEmpty ? _root : _chain.last.handle;
  }

  void _startFile(int index, int length) {
    if (failed) return;
    final parent = _ensureFolder(_manifest.parentOf(index), index);
    if (parent == null) return;
    final result = createFileExclusive(
      parent,
      _manifest.nameOf(index),
      rootFinal: _rootFinal,
    );
    switch (result) {
      case NodeCreated(:final handle):
        _file = handle;
        _fileParent = parent;
        _digest = startSha256();
        _used = 0;
        _currentEntry = index;
      case NodeFailed(:final diskFull):
        _fail(
          diskFull ? TransferOutcome.diskFull : TransferOutcome.writeFailed,
          index,
        );
    }
  }

  bool _flush(int entry) {
    final file = _file;
    if (file == null) return false;
    if (_used == 0) return true;
    final code = writeAllSync(file, _buffer, _used);
    _used = 0;
    if (code == 0) return true;
    _fail(
      isDiskFullError(code)
          ? TransferOutcome.diskFull
          : TransferOutcome.writeFailed,
      entry,
    );
    return false;
  }

  void _data(Uint8List bytes) {
    final file = _file;
    final digest = _digest;
    if (failed || file == null || digest == null) return;
    digest.add(bytes);
    var offset = 0;
    final view = _buffer.asTypedList(_bufferBytes);
    while (offset < bytes.length) {
      final room = _bufferBytes - _used;
      final take = room < bytes.length - offset ? room : bytes.length - offset;
      view.setRange(_used, _used + take, bytes, offset);
      _used += take;
      offset += take;
      if (_used == _bufferBytes && !_flush(_currentEntry)) return;
    }
    _dataBytes += bytes.length;
  }

  int _currentEntry = 0;

  void _endFile(int index) {
    _currentEntry = index;
    final file = _file;
    final digest = _digest;
    final parent = _fileParent;
    if (failed || file == null || digest == null || parent == null) return;
    if (!_flush(index)) return;
    final hex = digest.close();
    digest.dispose();
    _digest = null;
    file.close();
    _file = null;
    if (hex == null || hex != _manifest.hashHexOf(index)) {
      _fail(TransferOutcome.damaged, index);
      return;
    }
    if (_start.supportsMark &&
        !markFromInternetSync(parent, _manifest.nameOf(index))) {
      _fail(TransferOutcome.markFailed, index);
      return;
    }
    _files++;
  }

  void chunk(Uint8List bytes) {
    if (failed || _finished || _flag.value != 0) return;
    final length = bytes.length;
    final fault = _parser.add(bytes);
    if (fault != null) {
      _fail(
        fault == FrameFault.tooManyBytes
            ? TransferOutcome.tooManyBytes
            : TransferOutcome.unexpectedData,
      );
    }
    if (!failed) {
      _start.events.send(<int>[2, length, _files, _dataBytes]);
    }
  }

  bool finish() {
    if (failed || _flag.value != 0) return false;
    if (!_parser.complete || _file != null) {
      _fail(TransferOutcome.unexpectedData);
      return false;
    }
    for (var i = 1; i <= _manifest.length; i++) {
      if (_manifest.isFolder(i) && !_created.contains(i)) {
        if (_ensureFolder(i, i) == null) return false;
      }
    }
    _closeFolders();
    if (!verifyTree(rootPath!, _manifest.length)) {
      _fail(TransferOutcome.writeFailed);
      return false;
    }
    final root = _root;
    if (root != null) clearHiddenByHandleSync(root);
    root?.close();
    _root = null;
    _finished = true;
    return true;
  }

  void _closeFolders() {
    while (_chain.isNotEmpty) {
      _chain.removeLast().handle.close();
    }
  }

  void closeAll() {
    final file = _file;
    if (file != null) {
      file.close();
      _file = null;
    }
    _digest?.dispose();
    _digest = null;
    _closeFolders();
    final root = _root;
    if (root != null) {
      root.close();
      _root = null;
    }
  }

  void deleteAll() {
    closeAll();
    final path = rootPath;
    if (path != null) deleteTreeNoFollowSync(path);
  }

  void dispose() {
    calloc.free(_buffer);
  }

  void abort() => _fail(TransferOutcome.writeFailed);
}

void _writerMain(_WriterStart start) {
  final events = start.events;
  final commands = ReceivePort();
  _TreeWriter? writer;
  try {
    writer = _TreeWriter(start);
    if (!writer.open()) {
      writer.dispose();
      events.send(<Object>[0]);
      commands.close();
      return;
    }
  } catch (_) {
    events.send(<Object>[0]);
    commands.close();
    return;
  }
  final active = writer;
  events.send(<Object>[3, commands.sendPort, active.rootPath!]);
  commands.listen((Object? message) {
    if (message is TransferableTypedData) {
      try {
        active.chunk(message.materialize().asUint8List());
      } catch (_) {
        active.abort();
      }
      return;
    }
    switch (message) {
      case 'finish':
        var ok = false;
        try {
          ok = active.finish();
        } catch (_) {
          ok = false;
        }
        if (ok) {
          events.send(<Object>[4]);
        } else if (!active.failed) {
          events.send(<int>[1, TransferOutcome.writeFailed.index, -1]);
        }
      case 'discard':
        try {
          active.deleteAll();
        } catch (_) {}
        active.dispose();
        events.send(<Object>[5]);
        commands.close();
      case 'close':
        try {
          active.closeAll();
        } catch (_) {}
        active.dispose();
        commands.close();
    }
  });
}

final class FolderWriterHost {
  FolderWriterHost._({
    required this.tempRoot,
    required this.onProgress,
    required this.onActivity,
    required this.onFailure,
    required this._isolate,
    required this._events,
    required this._flag,
    required this._commands,
  });

  final String tempRoot;
  final void Function(int files, int bytes) onProgress;
  final void Function() onActivity;
  final void Function(FolderWriteFailed failure) onFailure;
  final Isolate _isolate;
  final ReceivePort _events;
  final Pointer<Uint8> _flag;
  final SendPort _commands;
  final Completer<FolderWriteResult> _finishing =
      Completer<FolderWriteResult>();
  final Completer<void> _stopped = Completer<void>();
  FolderWriteFailed? _failure;
  void Function()? _resume;
  int _pending = 0;
  bool _finishRequested = false;
  bool _closing = false;
  bool _exited = false;

  static Future<FolderWriterHost> start({
    required String tempFolder,
    required FolderManifest manifest,
    required bool supportsMark,
    required void Function(int files, int bytes) onProgress,
    required void Function() onActivity,
    required void Function(FolderWriteFailed failure) onFailure,
  }) async {
    final events = ReceivePort();
    final flag = calloc<Uint8>();
    final first = Completer<List<Object?>>();
    late final StreamSubscription<Object?> subscription;
    final isolate = await Isolate.spawn(
      _writerMain,
      _WriterStart(
        events: events.sendPort,
        tempFolder: tempFolder,
        manifest: manifest,
        supportsMark: supportsMark,
        flagAddress: flag.address,
      ),
      onExit: events.sendPort,
    );
    FolderWriterHost? host;
    subscription = events.listen((Object? message) {
      if (host == null) {
        if (message is List<Object?> && !first.isCompleted) {
          first.complete(message);
        } else if (message == null && !first.isCompleted) {
          first.complete(const <Object?>[0]);
        }
        return;
      }
      host._onEvent(message);
    });
    List<Object?> hello;
    try {
      hello = await first.future.timeout(Limits.requestTimeout);
    } catch (_) {
      hello = const <Object?>[0];
    }
    if (hello.isEmpty || hello[0] != 3) {
      isolate.kill(priority: Isolate.immediate);
      await subscription.cancel();
      events.close();
      calloc.free(flag);
      throw const FileSystemException('The folder writer did not start');
    }
    host = FolderWriterHost._(
      tempRoot: hello[2] as String,
      onProgress: onProgress,
      onActivity: onActivity,
      onFailure: onFailure,
      isolate: isolate,
      events: events,
      flag: flag,
      commands: hello[1] as SendPort,
    );
    return host;
  }

  void _onEvent(Object? message) {
    if (message == null) {
      _exited = true;
      final failure =
          _failure ?? const FolderWriteFailed(TransferOutcome.writeFailed);
      if (!_finishing.isCompleted) {
        _finishing.complete(failure);
        if (!_finishRequested && !_closing) onFailure(failure);
      }
      if (!_stopped.isCompleted) _stopped.complete();
      _events.close();
      calloc.free(_flag);
      return;
    }
    if (message is! List<Object?> || message.isEmpty) return;
    switch (message[0]) {
      case 1:
        final entry = message[2] as int;
        final failure = FolderWriteFailed(
          TransferOutcome.values[message[1] as int],
          entry < 0 ? null : entry,
        );
        _failure ??= failure;
        if (_finishRequested) {
          if (!_finishing.isCompleted) _finishing.complete(failure);
        } else {
          onFailure(failure);
        }
      case 2:
        _pending -= message[1] as int;
        onProgress(message[2] as int, message[3] as int);
        onActivity();
        final resume = _resume;
        if (resume != null && _pending <= Limits.folderWriterLowWater) {
          _resume = null;
          resume();
        }
      case 4:
        if (!_finishing.isCompleted) _finishing.complete(const FolderWritten());
      case 5:
        if (!_stopped.isCompleted) _stopped.complete();
    }
  }

  bool add(Uint8List chunk) {
    if (_exited || _failure != null) return false;
    try {
      _pending += chunk.length;
      _commands.send(TransferableTypedData.fromList([chunk]));
    } catch (_) {
      return false;
    }
    return _pending > Limits.folderWriterHighWater;
  }

  void onDrained(void Function() resume) {
    if (_exited || _pending <= Limits.folderWriterLowWater) {
      scheduleMicrotask(resume);
      return;
    }
    _resume = resume;
  }

  Future<FolderWriteResult> finish() {
    final failure = _failure;
    if (failure != null) return Future<FolderWriteResult>.value(failure);
    if (_exited) {
      return Future<FolderWriteResult>.value(
        const FolderWriteFailed(TransferOutcome.writeFailed),
      );
    }
    _finishRequested = true;
    try {
      _commands.send('finish');
    } catch (_) {
      if (!_finishing.isCompleted) {
        _finishing.complete(
          const FolderWriteFailed(TransferOutcome.writeFailed),
        );
      }
    }
    return _finishing.future;
  }

  Future<void> discard() async {
    _resume = null;
    _closing = true;
    if (_exited) return;
    _flag.value = 1;
    try {
      _commands.send('discard');
    } catch (_) {}
    try {
      await _stopped.future.timeout(Limits.workerStopGrace);
    } on TimeoutException {
      _isolate.kill(priority: Isolate.immediate);
    }
  }

  void close() {
    _closing = true;
    if (_exited) return;
    try {
      _commands.send('close');
    } catch (_) {}
  }
}
