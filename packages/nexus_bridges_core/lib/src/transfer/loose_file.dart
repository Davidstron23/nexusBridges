import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

import '../transport/transport.dart' show AbortSignal;
import 'folder_send.dart' show FolderReadChunk, FolderReadDone, FolderReadJob;
import 'windows_folder_io.dart';

FileHashResult _hashInIsolate(String path, String dataPath, int flagAddress) {
  final flag = Pointer<Uint8>.fromAddress(flagAddress);
  Set<(int, int)>? dataIds;
  var scanned = false;
  bool isProtected(int volume, int index) {
    if (dataPath.isEmpty) return false;
    if (!scanned) {
      dataIds = fileIdsUnder(dataPath, includeFolders: true);
      scanned = true;
    }
    final ids = dataIds;
    return ids == null || ids.contains((volume, index));
  }

  final buffer = allocateReadBuffer();
  try {
    return hashFileSync(
      path,
      buffer: buffer,
      isCancelled: () => flag.value != 0,
      isProtected: isProtected,
    );
  } finally {
    freeReadBuffer(buffer);
  }
}

Future<FileHashResult> hashLooseFile({
  required String path,
  required String dataPath,
  required AbortSignal abort,
}) async {
  final flag = calloc<Uint8>();
  final address = flag.address;
  final remove = abort.onAbort(() => flag.value = 1);
  try {
    return await Isolate.run(() => _hashInIsolate(path, dataPath, address));
  } finally {
    remove();
    calloc.free(flag);
  }
}

String hexOfDigest(Uint8List bytes) {
  final buffer = StringBuffer();
  for (final byte in bytes) {
    buffer.write(byte.toRadixString(16).padLeft(2, '0'));
  }
  return buffer.toString();
}

Stream<List<int>> looseFileStream({
  required String path,
  required int volume,
  required int index,
  required int size,
  required AbortSignal abort,
}) async* {
  final job = FolderReadJob.startFile(
    path: path,
    volume: volume,
    index: index,
    size: size,
  );
  final remove = abort.onAbort(job.interrupt);
  try {
    job.open(1, 0);
    while (true) {
      final event = await job.next();
      if (abort.aborted) return;
      if (event is FolderReadChunk) {
        yield event.bytes;
        job.acknowledge();
        continue;
      }
      if (event is FolderReadDone && event.ok) return;
      throw const FileSystemException('The file could not be read');
    }
  } finally {
    remove();
    job.close();
  }
}
