import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'folders.dart'
    show ReceiveTarget, samePath, tempFolderName, tempPrefix, tempSuffix;
import 'hashing.dart' show Sha256Stream, startSha256;
import 'names.dart' show isBlockedType, isValidFileName;
import 'platform.dart';
import 'transfer.dart' show TransferOutcome;

const int _bufferBytes = 1048576;
const int _errorDiskFull = 112;
const int _errorHandleDiskFull = 39;

sealed class WriteResult {
  const WriteResult();
}

final class WriteSaved extends WriteResult {
  const WriteSaved({
    required this.finalName,
    required this.finalPath,
    required this.marked,
  });

  final String finalName;
  final String finalPath;
  final bool marked;
}

final class WriteFailed extends WriteResult {
  const WriteFailed(this.outcome);

  final TransferOutcome outcome;
}

final class TooManyBytesException implements Exception {
  const TooManyBytesException();
}

final class DiskFullException implements Exception {
  const DiskFullException();
}

Future<void> writeAllBytes(RandomAccessFile file, List<int> bytes) async {
  await file.writeFrom(bytes);
}

String _join(String folder, String name) =>
    folder.endsWith(r'\') ? '$folder$name' : '$folder\\$name';

String _randomHex32() {
  final random = Random.secure();
  final buffer = StringBuffer();
  for (var i = 0; i < 16; i++) {
    buffer.write(random.nextInt(256).toRadixString(16).padLeft(2, '0'));
  }
  return buffer.toString();
}

Future<void> _deleteIfEmpty(String path) async {
  try {
    await Directory(path).delete();
  } catch (_) {}
}

bool _isDiskFull(FileSystemException error) {
  final code = error.osError?.errorCode;
  return code == _errorDiskFull || code == _errorHandleDiskFull;
}

final class IncomingFileWriter {
  IncomingFileWriter._(
    this._target,
    this._size,
    this._fs,
    this._writeBytes,
    this._folder,
    this._tempPath,
    this._file,
    this._digest,
  );

  final ReceiveTarget _target;
  final int _size;
  final FileSystemPlatform _fs;
  final Future<void> Function(RandomAccessFile file, List<int> bytes)
  _writeBytes;
  final String _folder;
  final String _tempPath;
  final RandomAccessFile _file;
  final Sha256Stream _digest;
  final BytesBuilder _buffer = BytesBuilder();

  Future<void> _pending = Future<void>.value();
  Future<void>? _discarding;
  Future<WriteResult>? _finishing;
  Future<void>? _cleanup;
  bool _stopRequested = false;
  int _written = 0;
  bool _closed = false;
  bool _fileClosed = false;
  bool _saved = false;

  static Future<IncomingFileWriter> open({
    required ReceiveTarget target,
    required int size,
    required FileSystemPlatform fs,
    Future<void> Function(RandomAccessFile file, List<int> bytes) writeBytes =
        writeAllBytes,
    Sha256Stream Function() startDigest = startSha256,
  }) async {
    final folder = _join(target.path, tempFolderName);
    var createdFolder = false;
    try {
      final kind = await FileSystemEntity.type(folder, followLinks: false);
      if (kind == FileSystemEntityType.notFound) {
        await Directory(folder).create();
        createdFolder = true;
      } else if (kind != FileSystemEntityType.directory) {
        throw const FileSystemException('The temporary folder is not a folder');
      }
      final realFolder = await fs.realPath(folder);
      if (realFolder == null || !samePath(realFolder, folder)) {
        throw const FileSystemException(
          'The temporary folder is not inside the receive folder',
        );
      }
      try {
        await fs.setHidden(folder);
      } catch (_) {}
      final tempPath = _join(folder, '$tempPrefix${_randomHex32()}$tempSuffix');
      final file = await File(tempPath).open(mode: FileMode.writeOnly);
      return IncomingFileWriter._(
        target,
        size,
        fs,
        writeBytes,
        folder,
        tempPath,
        file,
        startDigest(),
      );
    } catch (_) {
      if (createdFolder) await _deleteIfEmpty(folder);
      rethrow;
    }
  }

  int get written => _written;

  String get tempPath => _tempPath;

  Future<void> _enqueue(Future<void> Function() operation) {
    final next = _pending.then((_) => operation());
    _pending = next;
    return next;
  }

  Future<void> _write(Uint8List bytes) {
    return _enqueue(() async {
      try {
        await _writeBytes(_file, bytes);
      } on FileSystemException catch (error) {
        if (_isDiskFull(error)) throw const DiskFullException();
        rethrow;
      }
    });
  }

  Future<void> add(Uint8List chunk) async {
    if (_closed) {
      throw const FileSystemException('The incoming file is already closed');
    }
    if (_written + chunk.length > _size) throw const TooManyBytesException();
    _written += chunk.length;
    _digest.add(chunk);
    _buffer.add(chunk);
    if (_buffer.length >= _bufferBytes) {
      await _write(_buffer.takeBytes());
    } else {
      await _pending;
    }
  }

  Future<WriteResult> finish({
    required String name,
    required String expectedSha256,
  }) {
    if (_closed) {
      return Future<WriteResult>.value(
        const WriteFailed(TransferOutcome.writeFailed),
      );
    }
    _closed = true;
    return _finishing = _finish(name, expectedSha256);
  }

  Future<WriteResult> _fail(TransferOutcome outcome) async {
    await _cleanupOnce();
    return WriteFailed(outcome);
  }

  Future<WriteResult> _finish(String name, String expectedSha256) async {
    try {
      if (!isValidFileName(name)) {
        return await _fail(TransferOutcome.invalidName);
      }
      if (isBlockedType(name)) return await _fail(TransferOutcome.blockedType);
      if (_written != _size) {
        return await _fail(TransferOutcome.connectionLost);
      }
      try {
        if (_buffer.length > 0) await _write(_buffer.takeBytes());
        await _enqueue(() async {
          await _file.flush();
        });
        await _enqueue(() async {
          _fileClosed = true;
          await _file.close();
        });
      } on DiskFullException {
        return await _fail(TransferOutcome.diskFull);
      } catch (_) {
        return await _fail(TransferOutcome.writeFailed);
      }
      if (_stopRequested) return await _fail(TransferOutcome.writeFailed);

      final hex = _digest.close();
      if (hex == null) return await _fail(TransferOutcome.writeFailed);
      if (hex != expectedSha256) return await _fail(TransferOutcome.damaged);
      if (_stopRequested) return await _fail(TransferOutcome.writeFailed);

      final marked = _target.supportsMark;
      if (marked) {
        var done = false;
        try {
          done = await _fs.markFromInternet(_tempPath);
        } catch (_) {}
        if (!done) return await _fail(TransferOutcome.markFailed);
      }
      if (_stopRequested) return await _fail(TransferOutcome.writeFailed);

      int? length;
      try {
        length = await File(_tempPath).length();
      } catch (_) {}
      if (length != _size) return await _fail(TransferOutcome.damaged);

      FreeNameMove moved;
      try {
        moved = await _fs.moveToFreeName(_tempPath, _target.path, name);
      } catch (_) {
        moved = const MoveFailed();
      }
      switch (moved) {
        case MovedTo(:final finalName):
          _saved = true;
          await _deleteIfEmpty(_folder);
          return WriteSaved(
            finalName: finalName,
            finalPath: _join(_target.path, finalName),
            marked: marked,
          );
        case MoveFailed():
          return await _fail(TransferOutcome.moveFailed);
        case NoFreeName():
          return await _fail(TransferOutcome.noFreeName);
      }
    } catch (_) {
      await _cleanupOnce();
      return const WriteFailed(TransferOutcome.writeFailed);
    }
  }

  Future<void> discard() => _discarding ??= _discardRequested();

  Future<void> _discardRequested() async {
    final finishing = _finishing;
    if (finishing != null) {
      _stopRequested = true;
      try {
        await finishing;
      } catch (_) {}
      return;
    }
    await _cleanupOnce();
  }

  Future<void> _cleanupOnce() => _cleanup ??= _discard();

  Future<void> _discard() async {
    _closed = true;
    try {
      try {
        await _pending;
      } catch (_) {}
      if (!_fileClosed) {
        _fileClosed = true;
        try {
          await _file.close();
        } catch (_) {}
      }
      try {
        _digest.dispose();
      } catch (_) {}
      if (!_saved) {
        try {
          await File(_tempPath).delete();
        } catch (_) {}
        await _deleteIfEmpty(_folder);
      }
    } catch (_) {}
  }
}
