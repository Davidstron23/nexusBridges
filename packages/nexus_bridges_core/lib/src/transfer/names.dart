import '../protocol/protocol.dart' show Limits;

const String _replacement = '\uFFFD';

final RegExp _forbiddenCharacters = RegExp(r'[\\/:*?"<>|]');

final RegExp _invisibleCharacters = RegExp(
  r'[\u0000-\u001F\u007F-\u009F\u180E\u200B\u2060-\u2064'
  r'\u2066-\u206F\u202A-\u202E\uFEFF\uFFF9-\uFFFB\u115F'
  r'\u1160\u3164\uFFA0\u00AD\u2028\u2029]',
);

final RegExp _clsidSegment = RegExp(
  r'\.\{[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}'
  r'-[0-9A-Fa-f]{12}\}',
);

final RegExp _trailingDotsAndSpaces = RegExp(r'[. ]+$');

final RegExp _trailingSpaces = RegExp(r' +$');

const Set<String> _reservedNames = {
  'CON',
  'PRN',
  'AUX',
  'NUL',
  'CONIN\$',
  'CONOUT\$',
  'COM0',
  'COM1',
  'COM2',
  'COM3',
  'COM4',
  'COM5',
  'COM6',
  'COM7',
  'COM8',
  'COM9',
  'COM\u00B9',
  'COM\u00B2',
  'COM\u00B3',
  'LPT0',
  'LPT1',
  'LPT2',
  'LPT3',
  'LPT4',
  'LPT5',
  'LPT6',
  'LPT7',
  'LPT8',
  'LPT9',
  'LPT\u00B9',
  'LPT\u00B2',
  'LPT\u00B3',
};

const List<String> _blockedSuffixes = [
  '.lnk',
  '.url',
  '.scf',
  '.library-ms',
  '.searchconnector-ms',
  '.pif',
  '.settingcontent-ms',
  '.search-ms',
  '.theme',
  '.themepack',
  '.deskthemepack',
];

const List<String> _programSuffixes = [
  '.exe',
  '.msi',
  '.msix',
  '.bat',
  '.cmd',
  '.com',
  '.scr',
  '.ps1',
  '.vbs',
  '.js',
  '.jse',
  '.wsf',
  '.hta',
  '.cpl',
  '.jar',
  '.reg',
  '.appx',
  '.dll',
  '.sys',
  '.application',
];

bool _isHighSurrogate(int unit) => unit >= 0xD800 && unit <= 0xDBFF;

bool _isLowSurrogate(int unit) => unit >= 0xDC00 && unit <= 0xDFFF;

const int _tagBase = 0xE0000;
const int _tagEnd = 0xE007F;
const int _maxFlagTags = 6;

bool _isTagUnitPair(List<int> units, int i) =>
    i + 1 < units.length &&
    units[i] == 0xDB40 &&
    units[i + 1] >= 0xDC00 &&
    units[i + 1] <= 0xDC7F;

bool _isFlagTag(int codePoint) =>
    (codePoint >= 0xE0030 && codePoint <= 0xE0039) ||
    (codePoint >= 0xE0061 && codePoint <= 0xE007A);

int _flagUnits(List<int> units, int start) {
  if (start + 1 >= units.length ||
      units[start] != 0xD83C ||
      units[start + 1] != 0xDFF4) {
    return 0;
  }
  var i = start + 2;
  var tags = 0;
  while (_isTagUnitPair(units, i)) {
    final codePoint = _tagBase + (units[i + 1] - 0xDC00);
    i += 2;
    if (codePoint == _tagEnd) {
      return tags >= 1 && tags <= _maxFlagTags ? i - start : 0;
    }
    if (!_isFlagTag(codePoint)) return 0;
    tags++;
    if (tags > _maxFlagTags) return 0;
  }
  return 0;
}

bool _hasStrayTagCharacter(String text) {
  final units = text.codeUnits;
  var i = 0;
  while (i < units.length) {
    final flag = _flagUnits(units, i);
    if (flag > 0) {
      i += flag;
    } else if (_isTagUnitPair(units, i)) {
      return true;
    } else {
      i++;
    }
  }
  return false;
}

bool _hasLoneSurrogate(String text) {
  final units = text.codeUnits;
  for (var i = 0; i < units.length; i++) {
    final unit = units[i];
    if (_isHighSurrogate(unit)) {
      if (i + 1 < units.length && _isLowSurrogate(units[i + 1])) {
        i++;
      } else {
        return true;
      }
    } else if (_isLowSurrogate(unit)) {
      return true;
    }
  }
  return false;
}

bool isValidFileName(String name) {
  if (name.isEmpty || name.length > Limits.maxFileNameUnits) return false;
  if (_hasLoneSurrogate(name)) return false;
  if (_forbiddenCharacters.hasMatch(name)) return false;
  if (_invisibleCharacters.hasMatch(name)) return false;
  if (_hasStrayTagCharacter(name)) return false;
  if (name == '.' || name == '..') return false;
  if (name.endsWith('.') || name.endsWith(' ')) return false;
  final firstDot = name.indexOf('.');
  final stem = firstDot < 0 ? name : name.substring(0, firstDot);
  final reserved = stem.replaceFirst(_trailingSpaces, '').toUpperCase();
  return !_reservedNames.contains(reserved);
}

bool isBlockedType(String name) {
  final lower = name.toLowerCase();
  return lower == 'desktop.ini' ||
      _blockedSuffixes.any((suffix) => lower.endsWith(suffix)) ||
      _clsidSegment.hasMatch(name);
}

String? windowsExtension(String name) {
  final dot = name.lastIndexOf('.');
  if (dot < 0) return null;
  final extension = name.substring(dot);
  if (extension.contains(' ')) return null;
  return extension;
}

bool isProgram(String name) {
  final lower = name.toLowerCase();
  return _programSuffixes.any((suffix) => lower.endsWith(suffix));
}

bool _isDirectionMark(int unit) =>
    unit == 0x200E || unit == 0x200F || unit == 0x061C;

String visibleFileName(String name) {
  final units = name.codeUnits;
  final result = StringBuffer();
  for (var i = 0; i < units.length; i++) {
    final unit = units[i];
    final flag = _flagUnits(units, i);
    if (flag > 0) {
      for (var k = 0; k < flag; k++) {
        result.writeCharCode(units[i + k]);
      }
      i += flag - 1;
    } else if (_isTagUnitPair(units, i)) {
      result.write(_replacement);
      i++;
    } else if (_isHighSurrogate(unit) &&
        i + 1 < units.length &&
        _isLowSurrogate(units[i + 1])) {
      result
        ..writeCharCode(unit)
        ..writeCharCode(units[i + 1]);
      i++;
    } else if (_isHighSurrogate(unit) || _isLowSurrogate(unit)) {
      result.write(_replacement);
    } else if (_isDirectionMark(unit)) {
      continue;
    } else {
      final character = String.fromCharCode(unit);
      result.write(
        _invisibleCharacters.hasMatch(character) ? _replacement : character,
      );
    }
  }
  return result.toString();
}

String? candidateName(String name, int n) {
  if (n == 0) return name;
  final lastDot = name.lastIndexOf('.');
  final extension = lastDot > 0 ? name.substring(lastDot) : '';
  final base = lastDot > 0 ? name.substring(0, lastDot) : name;
  final suffix = ' ($n)';
  final room = Limits.maxFileNameUnits - suffix.length - extension.length;
  if (room < 1) return null;
  if (base.length <= room) return '$base$suffix$extension';
  final kept = StringBuffer();
  var units = 0;
  for (final rune in base.runes) {
    final width = rune > 0xFFFF ? 2 : 1;
    if (units + width > room) break;
    kept.writeCharCode(rune);
    units += width;
  }
  final trimmed = kept.toString().replaceFirst(_trailingDotsAndSpaces, '');
  if (trimmed.isEmpty) return null;
  return '$trimmed$suffix$extension';
}

String baseName(String windowsPath) {
  final cut = windowsPath.lastIndexOf(RegExp(r'[\\/]'));
  return cut < 0 ? windowsPath : windowsPath.substring(cut + 1);
}

String? candidateFolderName(String name, int n) {
  if (n == 0) return name;
  final suffix = ' ($n)';
  final room = Limits.maxFileNameUnits - suffix.length;
  if (room < 1) return null;
  if (name.length <= room) return '$name$suffix';
  final kept = StringBuffer();
  var units = 0;
  for (final rune in name.runes) {
    final width = rune > 0xFFFF ? 2 : 1;
    if (units + width > room) break;
    kept.writeCharCode(rune);
    units += width;
  }
  final trimmed = kept.toString().replaceFirst(_trailingDotsAndSpaces, '');
  if (trimmed.isEmpty) return null;
  return '$trimmed$suffix';
}

final RegExp _driveRootPattern = RegExp(
  r'^(?:[A-Za-z]:\\?|\\\\\?\\[A-Za-z]:\\?|\\\\\?\\Volume\{[0-9A-Fa-f-]+\}\\?)$',
);

final RegExp _shareRootPattern = RegExp(
  r'^(?:\\\\\?\\UNC\\|\\\\\.\\UNC\\|\\\\)[^\\]+\\[A-Za-z]\$\\?$',
  caseSensitive: false,
);

final RegExp _administrativeSharePattern = RegExp(
  r'^(?:\\\\\?\\UNC\\|\\\\\.\\UNC\\|\\\\)[^\\]+\\(?:[A-Za-z]|ADMIN|IPC|PRINT)\$(?:\\|$)',
  caseSensitive: false,
);

bool isDriveRoot(String path) {
  final normalized = path.replaceAll('/', r'\');
  return _driveRootPattern.hasMatch(normalized) ||
      _shareRootPattern.hasMatch(normalized);
}

bool isSenderAdministrativeShare(String path) =>
    _administrativeSharePattern.hasMatch(path.replaceAll('/', r'\'));

bool isShortcutName(String name) => name.toLowerCase().endsWith('.lnk');

bool isAppReservedName(String name) {
  final upper = name.toUpperCase();
  return upper == '.NEXUSBRIDGES-INCOMING' ||
      upper.startsWith('~NEXUSBRIDGES-');
}

bool isValidFolderName(String name) =>
    name.isNotEmpty &&
    isValidFileName(name) &&
    !isBlockedType(name) &&
    !isAppReservedName(name);

enum RelativePathProblem { tooDeep, invalidName, tooLong }

RelativePathProblem? checkRelativePath(
  List<String> components, {
  String? newFolder,
  required int rootPathUnits,
}) {
  final depth = components.length + (newFolder != null ? 1 : 0);
  if (depth > Limits.maxRelativeDepth) return RelativePathProblem.tooDeep;
  var total = rootPathUnits;
  for (final name in [...components, ?newFolder]) {
    if (!isValidFolderName(name)) return RelativePathProblem.invalidName;
    total += 1 + name.length;
  }
  if (total > Limits.maxShareFolderChars) return RelativePathProblem.tooLong;
  return null;
}
