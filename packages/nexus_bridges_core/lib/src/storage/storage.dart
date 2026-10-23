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

const List<Duration> _defaultRenameRetryDelays = [
  Duration(milliseconds: 20),
  Duration(milliseconds: 40),
  Duration(milliseconds: 80),
  Duration(milliseconds: 160),
  Duration(milliseconds: 320),
];

Future<void> _renameWithRetry(
  File temp,
  String target,
  List<Duration> delays,
) async {
  for (var attempt = 0; ; attempt++) {
    try {
      await temp.rename(target);
      return;
    } on FileSystemException {
      if (attempt >= delays.length) rethrow;
      await Future<void>.delayed(delays[attempt]);
    }
  }
}

Future<void> _writeFileOnce(
  File file,
  List<int> bytes, {
  List<Duration> renameRetryDelays = _defaultRenameRetryDelays,
}) async {
  await file.parent.create(recursive: true);
  final unique = '${DateTime.now().microsecondsSinceEpoch}.${_tempCounter++}';
  final temp = File('${file.path}.$unique.tmp');
  try {
    await temp.writeAsBytes(bytes, flush: true);
    await _renameWithRetry(temp, file.path, renameRetryDelays);
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

  Future<Map<String, Object?>?> readVersioned(int version) async {
    final json = await read();
    if (json == null) return null;
    final found = json['version'];
    if (found is! int || found != version) {
      throw const FormatException('unsupported version');
    }
    return json;
  }

  Future<void> write(Map<String, Object?> json) {
    return writeFileAtomic(
      file,
      utf8.encode(const JsonEncoder.withIndent('  ').convert(json)),
    );
  }

  Future<File> quarantine(DateTime now, {String reason = 'broken'}) async {
    final base = '${file.path}.$reason-${_timestamp(now)}';
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
