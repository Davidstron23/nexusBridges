import 'dart:convert';
import 'dart:math' show min;
import 'dart:typed_data';

import '../protocol/protocol.dart' show Limits;
import 'folders.dart' show tempFolderName;
import 'messages.dart' show FolderOfferRequest;
import 'names.dart'
    show
        isAppReservedName,
        isBlockedType,
        isValidFileName,
        isValidFolderName,
        visibleFileName;
import 'transfer.dart' show FirstLevelItem;

const int _hashBytes = 32;
const int _tempFolderUnits = 26;
const int _maxPathUnits = 259;
const int _frameOverhead = 13;
const int _headSize = 5;
const int _manifestChunkBytes = 65536;
const String _gitName = '.git';

final RegExp _sha256Hex = RegExp(r'^[0-9a-f]{64}$');

enum ManifestRefusal { incompatible, invalidName, blockedType, tooLarge }

final class _Columns {
  _Columns(int capacity) {
    _allocate(capacity < 1 ? 1 : capacity);
    names.add('');
  }

  int count = 1;
  late int _capacity;
  late Int32List parent;
  late Uint8List isFile;
  late Uint8List depth;
  late Uint16List prefix;
  late Int64List size;
  late Uint8List hash;
  final List<String> names = [];

  void _allocate(int capacity) {
    _capacity = capacity;
    parent = Int32List(capacity);
    isFile = Uint8List(capacity);
    depth = Uint8List(capacity);
    prefix = Uint16List(capacity);
    size = Int64List(capacity);
    hash = Uint8List(capacity * _hashBytes);
  }

  void _grow() {
    final bigger = _capacity * 2;
    final oldParent = parent;
    final oldIsFile = isFile;
    final oldDepth = depth;
    final oldPrefix = prefix;
    final oldSize = size;
    final oldHash = hash;
    _allocate(bigger);
    parent.setRange(0, count, oldParent);
    isFile.setRange(0, count, oldIsFile);
    depth.setRange(0, count, oldDepth);
    prefix.setRange(0, count, oldPrefix);
    size.setRange(0, count, oldSize);
    hash.setRange(0, count * _hashBytes, oldHash);
  }

  int add(int parentIndex, String name, bool file, int fileSize) {
    if (count >= _capacity) _grow();
    final index = count++;
    parent[index] = parentIndex;
    isFile[index] = file ? 1 : 0;
    depth[index] = depth[parentIndex] + 1;
    prefix[index] = prefix[parentIndex] + name.length + 1;
    size[index] = fileSize;
    names.add(name);
    return index;
  }

  void setHashHex(int index, String hex) {
    final offset = index * _hashBytes;
    for (var i = 0; i < _hashBytes; i++) {
      hash[offset + i] = int.parse(hex.substring(i * 2, i * 2 + 2), radix: 16);
    }
  }

  _Columns trimmed() {
    final copy = _Columns(count);
    copy.count = count;
    copy.parent.setRange(0, count, parent);
    copy.isFile.setRange(0, count, isFile);
    copy.depth.setRange(0, count, depth);
    copy.prefix.setRange(0, count, prefix);
    copy.size.setRange(0, count, size);
    copy.hash.setRange(0, count * _hashBytes, hash);
    copy.names
      ..clear()
      ..addAll(names);
    return copy;
  }
}

final class FolderManifest {
  FolderManifest._(this._c) {
    var fileTotal = 0;
    var folderTotal = 0;
    var sum = 0;
    var deepest = 0;
    var longestPath = 0;
    var topLevel = 0;
    var git = false;
    final indexes = <int>[];
    for (var i = 1; i < _c.count; i++) {
      final relative = _c.prefix[i] - 1;
      if (_c.parent[i] == 0) {
        topLevel++;
        _offerToHead(i);
      }
      if (_c.names[i].length == _gitName.length &&
          _c.names[i].toLowerCase() == _gitName) {
        git = true;
      }
      if (_c.isFile[i] == 1) {
        fileTotal++;
        sum += _c.size[i];
        indexes.add(i);
        if (relative > longestPath) longestPath = relative;
      } else {
        folderTotal++;
        final reserved = relative + Limits.folderDirPathReserve;
        if (reserved > longestPath) longestPath = reserved;
      }
      if (_c.depth[i] > deepest) deepest = _c.depth[i];
    }
    files = fileTotal;
    folders = folderTotal;
    totalBytes = sum;
    depth = deepest;
    longest = longestPath;
    fileIndexes = Int32List.fromList(indexes);
    firstLevelCount = topLevel;
    containsGitEntry = git;
  }

  final _Columns _c;

  final List<int> _headIndexes = [];

  final List<String> _headKeys = [];

  late final List<FirstLevelItem> _head = List.unmodifiable([
    for (final i in _headIndexes) _itemOf(i),
  ]);

  late final int firstLevelCount;
  late final bool containsGitEntry;

  late final int files;
  late final int folders;
  late final int totalBytes;
  late final int depth;
  late final int longest;
  late final Int32List fileIndexes;

  int get length => _c.count - 1;

  bool isFolder(int index) => _c.isFile[index] == 0;

  int parentOf(int index) => _c.parent[index];

  String nameOf(int index) => _c.names[index];

  int sizeOf(int index) => _c.size[index];

  Uint8List hashOf(int index) => Uint8List.sublistView(
    _c.hash,
    index * _hashBytes,
    index * _hashBytes + _hashBytes,
  );

  String hashHexOf(int index) {
    final buffer = StringBuffer();
    for (final byte in hashOf(index)) {
      buffer.write(byte.toRadixString(16).padLeft(2, '0'));
    }
    return buffer.toString();
  }

  int depthOf(int index) => _c.depth[index];

  String relativePath(int index) {
    final parts = <String>[];
    var current = index;
    while (current > 0) {
      parts.add(_c.names[current]);
      current = _c.parent[current];
    }
    return parts.reversed.join(r'\');
  }

  bool _precedes(String name, String key, int other, String otherKey) {
    final byUpper = key.compareTo(otherKey);
    return byUpper != 0 ? byUpper < 0 : name.compareTo(_c.names[other]) < 0;
  }

  void _offerToHead(int index) {
    final name = _c.names[index];
    final key = name.toUpperCase();
    var at = _headIndexes.length;
    while (at > 0 &&
        _precedes(name, key, _headIndexes[at - 1], _headKeys[at - 1])) {
      at--;
    }
    if (at >= _headSize) return;
    _headIndexes.insert(at, index);
    _headKeys.insert(at, key);
    if (_headIndexes.length > _headSize) {
      _headIndexes.removeLast();
      _headKeys.removeLast();
    }
  }

  FirstLevelItem _itemOf(int index) => FirstLevelItem(
    name: visibleFileName(_c.names[index]),
    isFolder: isFolder(index),
  );

  List<int> _firstLevelIndexes() {
    final children = <int>[
      for (var i = 1; i < _c.count; i++)
        if (_c.parent[i] == 0) i,
    ];
    children.sort((a, b) {
      final left = _c.names[a];
      final right = _c.names[b];
      final byUpper = left.toUpperCase().compareTo(right.toUpperCase());
      return byUpper != 0 ? byUpper : left.compareTo(right);
    });
    return children;
  }

  List<FirstLevelItem> firstLevel({int max = _headSize}) {
    if (max <= _headSize) {
      return max >= _head.length ? _head : _head.sublist(0, max < 0 ? 0 : max);
    }
    return [for (final i in _firstLevelIndexes().take(max)) _itemOf(i)];
  }
}

final class ManifestBuilder {
  _Columns _c = _Columns(64);

  final Set<int> _dropped = {};

  int get length => _c.count - 1;

  bool isFile(int index) => _c.isFile[index] == 1;

  String nameOf(int index) => _c.names[index];

  String relativePath(int index) {
    final parts = <String>[];
    var current = index;
    while (current > 0) {
      parts.add(_c.names[current]);
      current = _c.parent[current];
    }
    return parts.reversed.join(r'\');
  }

  int addFolder(int parent, String name) => _c.add(parent, name, false, 0);

  int addFile(int parent, String name, int size) =>
      _c.add(parent, name, true, size);

  void setFile(int index, int size, Uint8List sha256) {
    _c.size[index] = size;
    _c.hash.setRange(index * _hashBytes, (index + 1) * _hashBytes, sha256);
  }

  void dropFile(int index) {
    _dropped.add(index);
  }

  FolderManifest build() {
    if (_dropped.isEmpty) return FolderManifest._(_c.trimmed());
    final kept = _Columns(_c.count - _dropped.length);
    final mapped = Int32List(_c.count);
    for (var i = 1; i < _c.count; i++) {
      if (_dropped.contains(i)) continue;
      final index = kept.add(
        mapped[_c.parent[i]],
        _c.names[i],
        _c.isFile[i] == 1,
        _c.size[i],
      );
      mapped[i] = index;
      kept.hash.setRange(
        index * _hashBytes,
        (index + 1) * _hashBytes,
        _c.hash,
        i * _hashBytes,
      );
    }
    _c = kept;
    _dropped.clear();
    return FolderManifest._(_c.trimmed());
  }
}

Uint8List _encodeLine(FolderManifest manifest, int index) {
  final buffer = StringBuffer()
    ..write('[')
    ..write(manifest.parentOf(index))
    ..write(',')
    ..write(jsonEncode(manifest.nameOf(index)));
  if (!manifest.isFolder(index)) {
    buffer
      ..write(',')
      ..write(manifest.sizeOf(index))
      ..write(',"')
      ..write(manifest.hashHexOf(index))
      ..write('"');
  }
  buffer.write(']\n');
  return utf8.encode(buffer.toString());
}

Iterable<Uint8List> encodeManifestChunks(
  FolderManifest manifest, {
  int chunkBytes = _manifestChunkBytes,
}) sync* {
  var chunk = Uint8List(chunkBytes);
  var filled = 0;
  for (var i = 1; i <= manifest.length; i++) {
    final line = _encodeLine(manifest, i);
    var copied = 0;
    while (copied < line.length) {
      final count = min(chunkBytes - filled, line.length - copied);
      chunk.setRange(filled, filled + count, line, copied);
      filled += count;
      copied += count;
      if (filled == chunkBytes) {
        yield chunk;
        chunk = Uint8List(chunkBytes);
        filled = 0;
      }
    }
  }
  if (filled > 0) yield Uint8List.sublistView(chunk, 0, filled);
}

int encodedManifestLength(FolderManifest manifest) {
  var total = 0;
  for (var i = 1; i <= manifest.length; i++) {
    total += _encodeLine(manifest, i).length;
  }
  return total;
}

Uint8List encodeManifest(FolderManifest manifest) {
  final builder = BytesBuilder(copy: false);
  for (final chunk in encodeManifestChunks(manifest)) {
    builder.add(chunk);
  }
  return builder.takeBytes();
}

final class ManifestReader {
  ManifestReader(this._declared)
    : _c = _Columns(
        (_declared.entries > Limits.maxFolderEntries
                ? Limits.maxFolderEntries
                : _declared.entries) +
            1,
      );

  final FolderOfferRequest _declared;
  final _Columns _c;
  final BytesBuilder _line = BytesBuilder(copy: true);
  final Set<String> _keys = {};
  ManifestRefusal? _refusal;
  int _read = 0;
  int _entries = 0;
  int _sum = 0;

  ManifestRefusal? _fail(ManifestRefusal refusal) => _refusal = refusal;

  ManifestRefusal? add(Uint8List chunk) {
    final failed = _refusal;
    if (failed != null) return failed;
    final room = _declared.manifestBytes - _read;
    if (chunk.length > room) {
      final refusal = _consume(Uint8List.sublistView(chunk, 0, room));
      return _fail(refusal ?? ManifestRefusal.incompatible);
    }
    return _consume(chunk);
  }

  ManifestRefusal? _consume(Uint8List chunk) {
    _read += chunk.length;
    var start = 0;
    while (start < chunk.length) {
      final newline = chunk.indexOf(10, start);
      if (newline < 0) {
        if (_line.length + (chunk.length - start) >=
            Limits.maxManifestLineBytes) {
          return _fail(ManifestRefusal.incompatible);
        }
        _line.add(Uint8List.sublistView(chunk, start));
        return null;
      }
      final segment = newline - start;
      if (_line.length + segment + 1 > Limits.maxManifestLineBytes) {
        return _fail(ManifestRefusal.incompatible);
      }
      final Uint8List bytes;
      if (_line.length == 0) {
        bytes = Uint8List.sublistView(chunk, start, newline);
      } else {
        _line.add(Uint8List.sublistView(chunk, start, newline));
        bytes = _line.takeBytes();
      }
      final refusal = _processLine(bytes);
      if (refusal != null) return _fail(refusal);
      start = newline + 1;
    }
    return null;
  }

  ManifestRefusal? _processLine(Uint8List bytes) {
    if (_entries >= _declared.entries) return ManifestRefusal.incompatible;
    if (_entries >= Limits.maxFolderEntries) return ManifestRefusal.tooLarge;
    if (bytes.isEmpty ||
        bytes.contains(13) ||
        _startsWithByteOrderMark(bytes)) {
      return ManifestRefusal.incompatible;
    }
    final Object? decoded;
    try {
      decoded = jsonDecode(utf8.decode(bytes));
    } on FormatException {
      return ManifestRefusal.incompatible;
    }
    if (decoded is! List<Object?>) return ManifestRefusal.incompatible;
    if (decoded.length != 2 && decoded.length != 4) {
      return ManifestRefusal.incompatible;
    }
    final index = _entries + 1;
    final parent = decoded[0];
    if (parent is! int || parent < 0 || parent >= index) {
      return ManifestRefusal.incompatible;
    }
    if (parent != 0 && _c.isFile[parent] == 1) {
      return ManifestRefusal.incompatible;
    }
    final name = decoded[1];
    if (name is! String) return ManifestRefusal.incompatible;
    final isFile = decoded.length == 4;
    if (isFile) {
      if (!isValidFileName(name) || isAppReservedName(name)) {
        return ManifestRefusal.invalidName;
      }
      if (isBlockedType(name)) return ManifestRefusal.blockedType;
    } else if (!isValidFolderName(name)) {
      return isValidFileName(name) && !isAppReservedName(name)
          ? ManifestRefusal.blockedType
          : ManifestRefusal.invalidName;
    }
    var size = 0;
    String? hex;
    if (isFile) {
      final rawSize = decoded[2];
      final rawHash = decoded[3];
      if (rawSize is! int ||
          rawSize < 0 ||
          rawSize > Limits.maxTransferSize ||
          rawHash is! String ||
          !_sha256Hex.hasMatch(rawHash)) {
        return ManifestRefusal.incompatible;
      }
      if (_sum + rawSize > Limits.maxTransferSize) {
        return ManifestRefusal.incompatible;
      }
      size = rawSize;
      hex = rawHash;
    }
    if (_c.depth[parent] + 1 > Limits.maxFolderDepth) {
      return ManifestRefusal.tooLarge;
    }
    if (!_keys.add('$parent:${name.toUpperCase()}')) {
      return ManifestRefusal.invalidName;
    }
    final added = _c.add(parent, name, isFile, size);
    if (hex != null) _c.setHashHex(added, hex);
    _entries++;
    _sum += size;
    return null;
  }

  ({FolderManifest? manifest, ManifestRefusal? refusal}) close() {
    final failed = _refusal;
    if (failed != null) return (manifest: null, refusal: failed);
    if (_read != _declared.manifestBytes ||
        _line.length != 0 ||
        _entries != _declared.entries) {
      return (manifest: null, refusal: _fail(ManifestRefusal.incompatible));
    }
    final manifest = FolderManifest._(_c);
    if (manifest.files != _declared.files ||
        manifest.totalBytes != _declared.bytes ||
        manifest.depth != _declared.depth ||
        manifest.longest != _declared.longest) {
      return (manifest: null, refusal: _fail(ManifestRefusal.incompatible));
    }
    return (manifest: manifest, refusal: null);
  }
}

bool _startsWithByteOrderMark(Uint8List bytes) =>
    bytes.length >= 3 &&
    bytes[0] == 0xEF &&
    bytes[1] == 0xBB &&
    bytes[2] == 0xBF;

int _trimmedLength(String targetPath) =>
    targetPath.endsWith(r'\') ? targetPath.length - 1 : targetPath.length;

bool folderFitsIn({
  required String targetPath,
  required String folderName,
  required int longest,
}) {
  final target = _trimmedLength(targetPath);
  final finalBase = target + 1 + folderName.length + Limits.folderNameMargin;
  final finalFits =
      finalBase + Limits.folderDirPathReserve <= _maxPathUnits &&
      (longest == 0 || finalBase + 1 + longest <= _maxPathUnits);
  final tempBase = target + 1 + tempFolderName.length + 1 + _tempFolderUnits;
  final tempFits =
      tempBase + Limits.folderDirPathReserve <= _maxPathUnits &&
      (longest == 0 || tempBase + 1 + longest <= _maxPathUnits);
  return finalFits && tempFits;
}

int maxFolderNameUnits({required String targetPath, required int longest}) {
  final target = _trimmedLength(targetPath);
  final room = longest == 0
      ? _maxPathUnits - target - 1 - Limits.folderDirPathReserve
      : _maxPathUnits - target - 2 - longest;
  if (room < 0) return 0;
  return room > Limits.maxFileNameUnits ? Limits.maxFileNameUnits : room;
}

int folderStreamLength(FolderManifest manifest) =>
    manifest.totalBytes + manifest.files * _frameOverhead;
