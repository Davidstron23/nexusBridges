import 'dart:io';
import 'dart:typed_data';

import '../transport/transport.dart' show AbortSignal;
import 'folder_plan.dart' show FolderPlan;
import 'folder_stream.dart' show encodeFrameHeader;
import 'hashing.dart' show startSha256;

const int _flushBytes = 65536;
const int _readBytes = 262144;

final class FolderEntryProblem implements Exception {
  const FolderEntryProblem(this.entry);

  final int entry;
}

String _join(String folder, String name) =>
    folder.endsWith(r'\') ? '$folder$name' : '$folder\\$name';

Stream<List<int>> folderStream(
  FolderPlan plan, {
  required AbortSignal abort,
  required Future<void> Function(int entry) onEntryProblem,
  required Future<void> Function(int entry) beforeEntry,
}) async* {
  final manifest = plan.manifest;
  final output = BytesBuilder(copy: false);
  for (final index in manifest.fileIndexes) {
    if (abort.aborted) return;
    await beforeEntry(index);
    if (abort.aborted) return;
    final path = _join(plan.rootPath, manifest.relativePath(index));
    final expected = manifest.sizeOf(index);
    final digest = startSha256();
    RandomAccessFile? file;
    var problem = false;
    try {
      file = await File(path).open();
      final length = await file.length();
      if (length != expected) {
        problem = true;
      } else {
        output.add(encodeFrameHeader(index, expected));
        var remaining = expected;
        while (remaining > 0) {
          if (abort.aborted) return;
          final want = remaining < _readBytes ? remaining : _readBytes;
          final Uint8List chunk = await file.read(want);
          if (chunk.isEmpty) {
            problem = true;
            break;
          }
          digest.add(chunk);
          output.add(chunk);
          remaining -= chunk.length;
          if (output.length >= _flushBytes) yield output.takeBytes();
        }
        if (!problem) {
          final extra = await file.read(1);
          if (extra.isNotEmpty) {
            problem = true;
          } else {
            final hex = digest.close();
            if (hex == null || hex != manifest.hashHexOf(index)) {
              problem = true;
            }
          }
        }
      }
    } on FileSystemException {
      problem = true;
    } finally {
      digest.dispose();
      if (file != null) {
        try {
          await file.close();
        } catch (_) {}
      }
    }
    if (problem) {
      if (output.length > 0) yield output.takeBytes();
      await onEntryProblem(index);
      throw FolderEntryProblem(index);
    }
    output.addByte(0);
  }
  if (output.length > 0) yield output.takeBytes();
}
