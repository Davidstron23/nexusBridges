import 'dart:convert';
import 'dart:io';

int _tempCounter = 0;

Directory defaultDataDir({Map<String, String>? environment}) {
  final localAppData = (environment ?? Platform.environment)['LOCALAPPDATA'];
  if (localAppData == null || localAppData.isEmpty) {
    throw StateError('LOCALAPPDATA is not set');
  }
  return Directory('$localAppData${Platform.pathSeparator}NexusBridges');
}

final Map<String, Future<void>> _pendingWrites = {};

String _writeKey(File file) {
  final path = file.absolute.path;
  return Platform.isWindows ? path.toLowerCase() : path;
}

Future<void> writeFileAtomic(File file, List<int> bytes) {
  final key = _writeKey(file);
  final previous = _pendingWrites[key] ?? Future<void>.value();
  final result = previous.then((_) => _writeFileOnce(file, bytes));
  final tail = result.then<void>((_) {}, onError: (Object _) {});
  _pendingWrites[key] = tail;
  tail.whenComplete(() {
    if (identical(_pendingWrites[key], tail)) _pendingWrites.remove(key);
  });
  return result;
}

Future<void> _writeFileOnce(File file, List<int> bytes) async {
  await file.parent.create(recursive: true);
  final unique = '${DateTime.now().microsecondsSinceEpoch}.${_tempCounter++}';
  final temp = File('${file.path}.$unique.tmp');
  try {
    await temp.writeAsBytes(bytes, flush: true);
    await temp.rename(file.path);
  } catch (_) {
    try {
      if (await temp.exists()) await temp.delete();
    } catch (_) {}
    rethrow;
  }
}

final class JsonFileStore {
  JsonFileStore(this.file);

  final File file;

  Future<Map<String, Object?>?> read() async {
    if (!await file.exists()) return null;
    final decoded = jsonDecode(utf8.decode(await file.readAsBytes()));
    if (decoded is! Map<String, Object?>) {
      throw const FormatException('not a JSON object');
    }
    return decoded;
  }

  Future<void> write(Map<String, Object?> json) {
    return writeFileAtomic(
      file,
      utf8.encode(const JsonEncoder.withIndent('  ').convert(json)),
    );
  }

  Future<File> quarantine(DateTime now) async {
    final base = '${file.path}.broken-${_timestamp(now)}';
    var candidate = base;
    for (var n = 2; await _exists(candidate); n++) {
      candidate = '$base-$n';
    }
    return file.rename(candidate);
  }
}

Future<bool> _exists(String path) async {
  return await File(path).exists() ||
      await Directory(path).exists() ||
      await Link(path).exists();
}

String _timestamp(DateTime t) {
  String two(int v) => v.toString().padLeft(2, '0');
  return '${t.year.toString().padLeft(4, '0')}${two(t.month)}${two(t.day)}'
      '-${two(t.hour)}${two(t.minute)}${two(t.second)}';
}
