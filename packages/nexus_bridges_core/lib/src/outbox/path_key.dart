import 'policy.dart';

const Set<int> _separateInNtfs = {
  0xb5,
  0x131,
  0x17f,
  0x1c5,
  0x1c8,
  0x1cb,
  0x1f2,
  0x345,
  0x3c2,
  0x3d0,
  0x3d1,
  0x3d5,
  0x3d6,
  0x3f0,
  0x3f1,
  0x3f5,
  0x1e9b,
  0x1fbe,
};

const int _lastBmp = 0xFFFF;

String normalizeElementPath(String path) {
  final slashed = path.replaceAll('/', r'\');
  if (isDriveRootPath(slashed)) {
    return '${slashed.substring(0, 2)}\\';
  }
  var end = slashed.length;
  while (end > 0 && slashed[end - 1] == r'\') {
    end--;
  }
  return end == 0 ? slashed : slashed.substring(0, end);
}

String _foldRune(int rune) {
  final same = String.fromCharCode(rune);
  if (rune > _lastBmp || _separateInNtfs.contains(rune)) return same;
  final upper = same.toUpperCase();
  if (upper.runes.length == 1) return upper;
  final lower = same.toLowerCase();
  return lower.runes.length == 1 ? lower : same;
}

const String _separator = r'\';

final RegExp _driveLetter = RegExp(r'^[A-Za-z]:$');

int _rootParts(List<String> parts) {
  int clamp(int count) => count > parts.length ? parts.length : count;
  if (parts.length > 1 && parts[0].isEmpty && parts[1].isEmpty) {
    if (parts.length > 2 && (parts[2] == '?' || parts[2] == '.')) {
      final isUnc = parts.length > 3 && parts[3].toUpperCase() == 'UNC';
      return clamp(isUnc ? 6 : 4);
    }
    return clamp(4);
  }
  if (parts[0].isEmpty) return 1;
  if (_driveLetter.hasMatch(parts[0])) return 1;
  return 0;
}

String _withoutDotSegments(String path) {
  final parts = path.split(_separator);
  final root = _rootParts(parts);
  final kept = parts.sublist(0, root);
  for (var i = root; i < parts.length; i++) {
    final part = parts[i];
    if (part == '.') continue;
    if (part == '..') {
      if (kept.length > root && kept.last != '..') {
        kept.removeLast();
      } else if (root == 0) {
        kept.add(part);
      }
      continue;
    }
    kept.add(part);
  }
  if (kept.length == 1 && _driveLetter.hasMatch(kept[0])) kept.add('');
  return kept.join(_separator);
}

String pathKey(String path) {
  final buffer = StringBuffer();
  for (final rune in _withoutDotSegments(normalizeElementPath(path)).runes) {
    buffer.write(_foldRune(rune));
  }
  return buffer.toString();
}
