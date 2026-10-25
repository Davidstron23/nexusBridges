const int _maxExtensionRunes = 16;

const int _ellipsis = 0x2026;

const int _dot = 0x2E;

const List<String> _units = ['KB', 'MB', 'GB', 'TB'];

String formatSize(int bytes, String languageCode) {
  if (bytes < 1024) return bytes == 1 ? '1 byte' : '$bytes bytes';
  var value = bytes / 1024;
  var unit = 0;
  while (value >= 1024 && unit < _units.length - 1) {
    value /= 1024;
    unit++;
  }
  final digits = value < 10 ? 1 : 0;
  final text = '${value.toStringAsFixed(digits)} ${_units[unit]}';
  return languageCode == 'es' ? text.replaceFirst('.', ',') : text;
}

String shortenFileName(String name, {int maxRunes = 60}) {
  final runes = name.runes.toList();
  if (runes.length <= maxRunes) return name;
  final dot = runes.lastIndexOf(_dot);
  final extensionLength = dot > 0 ? runes.length - dot : 0;
  if (dot > 0 && extensionLength <= _maxExtensionRunes) {
    final head = maxRunes - 1 - extensionLength;
    return String.fromCharCodes([
      ...runes.take(head < 0 ? 0 : head),
      _ellipsis,
      ...runes.skip(dot),
    ]);
  }
  final head = maxRunes - 1;
  return String.fromCharCodes([...runes.take(head < 0 ? 0 : head), _ellipsis]);
}

int percentOf(int done, int total) {
  if (total == 0) return 100;
  return done * 100 ~/ total;
}
