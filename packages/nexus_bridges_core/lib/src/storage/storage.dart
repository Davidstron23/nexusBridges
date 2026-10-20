import 'dart:convert';
import 'dart:io';

Future<void> writeFileAtomic(File file, List<int> bytes) async {
  await file.parent.create(recursive: true);
  final temp = File('${file.path}.tmp');
  await temp.writeAsBytes(bytes, flush: true);
  await temp.rename(file.path);
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
