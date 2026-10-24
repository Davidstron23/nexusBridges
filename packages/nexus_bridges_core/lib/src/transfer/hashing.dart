import 'dart:io';

import 'package:crypto/crypto.dart';

import '../transport/transport.dart' show AbortSignal;
import 'windows_sha256.dart' show startWindowsSha256;

const int hashChunkBytes = 1048576;

final class FileDigest {
  const FileDigest({required this.size, required this.sha256});

  final int size;
  final String sha256;
}

final class DigestCollector implements Sink<Digest> {
  Digest? _value;

  Digest get value {
    final digest = _value;
    if (digest == null) throw StateError('The digest is not ready');
    return digest;
  }

  @override
  void add(Digest data) {
    _value = data;
  }

  @override
  void close() {}
}

abstract interface class Sha256Stream {
  void add(List<int> bytes);

  String? close();

  void dispose();
}

final class _DartSha256 implements Sha256Stream {
  _DartSha256() {
    _input = sha256.startChunkedConversion(_collector);
  }

  final DigestCollector _collector = DigestCollector();
  late final Sink<List<int>> _input;
  bool _done = false;

  @override
  void add(List<int> bytes) {
    if (_done) return;
    _input.add(bytes);
  }

  @override
  String? close() {
    if (_done) return null;
    _done = true;
    _input.close();
    return _collector.value.toString();
  }

  @override
  void dispose() {
    _done = true;
  }
}

Sha256Stream startDartSha256() => _DartSha256();

Sha256Stream startSha256() => startWindowsSha256() ?? startDartSha256();

Future<FileDigest?> hashFile(
  String path, {
  required AbortSignal abort,
  int chunkBytes = hashChunkBytes,
  Sha256Stream Function() startDigest = startSha256,
}) async {
  final digest = startDigest();
  try {
    final file = await File(path).open();
    var size = 0;
    try {
      while (true) {
        if (abort.aborted) return null;
        final chunk = await file.read(chunkBytes);
        if (chunk.isEmpty) break;
        digest.add(chunk);
        size += chunk.length;
      }
    } finally {
      try {
        await file.close();
      } catch (_) {}
    }
    final hex = digest.close();
    if (hex == null) throw const FileSystemException('The file digest failed');
    return FileDigest(size: size, sha256: hex);
  } finally {
    digest.dispose();
  }
}
