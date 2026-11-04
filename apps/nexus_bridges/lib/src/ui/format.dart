import '../l10n/app_strings.dart';

const int _maxExtensionRunes = 16;

const int _ellipsis = 0x2026;

const int _dot = 0x2E;

const List<String> _units = ['KB', 'MB', 'GB', 'TB'];

const String _zeroWidthSpace = '\u200B';

const String _nonBreakingSpace = '\u00A0';

const String _wordJoiner = '\u2060';

const String _backslash = r'\';

const String _driveColon = ':';

const String _separatorDot = '·';

String breakablePath(String path) => path
    .replaceAll(
      '$_driveColon$_backslash',
      '$_driveColon$_wordJoiner$_backslash',
    )
    .replaceAll(_backslash, '$_backslash$_zeroWidthSpace');

String glueFingerprint(String label, String short) {
  final tail = ' $_separatorDot $short';
  if (!label.endsWith(tail)) return label;
  return '${label.substring(0, label.length - tail.length)}'
      '$_nonBreakingSpace$_separatorDot$_nonBreakingSpace$short';
}

String withoutFingerprint(String label, String short) {
  final tail = ' $_separatorDot $short';
  if (!label.endsWith(tail)) return label;
  return label.substring(0, label.length - tail.length);
}

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

String formatOverflow(int hidden) => '+$hidden';

int percentOf(int done, int total) {
  if (total == 0) return 100;
  return done * 100 ~/ total;
}

String formatPercent(int percent, String languageCode) =>
    languageCode == 'es' ? '$percent %' : '$percent%';

String formatCount(int count, String languageCode) {
  final digits = count.abs().toString();
  if (digits.length < 4) return count.toString();
  final separator = languageCode == 'es' ? ' ' : ',';
  final buffer = StringBuffer(count < 0 ? '-' : '');
  for (var i = 0; i < digits.length; i++) {
    if (i > 0 && (digits.length - i) % 3 == 0) buffer.write(separator);
    buffer.write(digits[i]);
  }
  return buffer.toString();
}

String formatShortDate(DateTime utc, String languageCode, AppStrings strings) {
  final local = utc.toLocal();
  final year = local.year.toString().padLeft(4, '0');
  if (languageCode == 'es') {
    final day = local.day.toString().padLeft(2, '0');
    final month = local.month.toString().padLeft(2, '0');
    return '$day/$month/$year';
  }
  return '${strings.monthShort(local.month)} ${local.day}, $year';
}
