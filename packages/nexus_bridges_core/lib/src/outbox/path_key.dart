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

String pathKey(String path) {
  final buffer = StringBuffer();
  for (final rune in normalizeElementPath(path).runes) {
    buffer.write(_foldRune(rune));
  }
  return buffer.toString();
}
