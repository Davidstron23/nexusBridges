import '../protocol/protocol.dart' show Limits, folderKey;
import '../transfer/transfer.dart'
    show
        ForbiddenFolders,
        isForbiddenFolder,
        isInsideTempFolder,
        isValidFolderName;
import '../winio/winio.dart' show DirectoryBatches, RawEntry, isLinkTag;
import 'share_fs.dart' show FolderListed;

const int _attributeHidden = 0x02;
const int _attributeSystem = 0x04;
const int _collectFactor = 2;

int _compareNames(String a, String b) {
  final byKey = folderKey(a).compareTo(folderKey(b));
  return byKey != 0 ? byKey : a.compareTo(b);
}

final class FolderCollector {
  FolderCollector({
    required this._max,
    required String parentFinalPath,
    required this._forbidden,
  }) : _parent = parentFinalPath.endsWith(r'\')
           ? parentFinalPath
           : '$parentFinalPath\\';

  final int _max;
  final String _parent;
  final ForbiddenFolders _forbidden;
  final List<String> _names = [];
  bool _more = false;

  void add(List<RawEntry> batch) {
    for (final entry in batch) {
      if (!_accepts(entry)) continue;
      _names.add(entry.name);
      if (_names.length >= _max * _collectFactor) _trim();
    }
  }

  ({List<String> names, bool more}) finish() {
    _trim();
    return (names: List.unmodifiable(_names), more: _more);
  }

  bool _accepts(RawEntry entry) {
    if (!entry.isDirectory) return false;
    if ((entry.attributes & (_attributeHidden | _attributeSystem)) != 0) {
      return false;
    }
    final tag = entry.reparseTag;
    if (tag != null && isLinkTag(tag)) return false;
    if (!isValidFolderName(entry.name)) return false;
    final full = '$_parent${entry.name}';
    return !isForbiddenFolder(full, _forbidden) && !isInsideTempFolder(full);
  }

  void _trim() {
    _names.sort(_compareNames);
    final unique = <String>[];
    String? lastKey;
    for (final name in _names) {
      final key = folderKey(name);
      if (key == lastKey) continue;
      lastKey = key;
      unique.add(name);
    }
    _names
      ..clear()
      ..addAll(unique);
    if (_names.length > _max) {
      _names.removeRange(_max, _names.length);
      _more = true;
    }
  }
}

FolderListed enumerateFolders({
  required DirectoryBatches batches,
  required FolderCollector collector,
  required Duration Function() clock,
  required Duration cap,
  int maxScan = Limits.maxBrowseScanEntries,
}) {
  final start = clock();
  var scanned = 0;
  var partial = false;
  while (true) {
    final batch = batches.next();
    if (batch == null) break;
    collector.add(batch);
    scanned += batch.length;
    if (clock() - start >= cap || scanned >= maxScan) {
      partial = true;
      break;
    }
  }
  final result = collector.finish();
  return FolderListed(result.names, more: result.more, partial: partial);
}
