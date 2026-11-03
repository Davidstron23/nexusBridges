import '../protocol/protocol.dart' show folderKey;
import '../transfer/transfer.dart' show isValidFileName, samePath;

const int _maxRootLabelUnits = 520;

final RegExp _driveLabel = RegExp(r'^[A-Za-z]:$');
final RegExp _numberedDriveLabel = RegExp(r'^[A-Za-z]: [0-9]+$');
final RegExp _driveRootPath = RegExp(r'^[A-Za-z]:\\?$');

bool _isLabelPart(String text) =>
    isValidFileName(text) || _driveLabel.hasMatch(text);

bool _balancedParentheses(String text) {
  var depth = 0;
  for (var i = 0; i < text.length; i++) {
    final unit = text.codeUnitAt(i);
    if (unit == 0x28) {
      depth++;
    } else if (unit == 0x29) {
      depth--;
      if (depth < 0) return false;
    }
  }
  return depth == 0;
}

bool isValidRootLabel(String name) {
  if (name.isEmpty || name.length > _maxRootLabelUnits) return false;
  if (!_balancedParentheses(name)) return false;
  if (_isLabelPart(name)) return true;
  if (!name.endsWith(')')) return false;
  var cut = name.indexOf(' (');
  while (cut > 0) {
    final base = name.substring(0, cut);
    final qualifier = name.substring(cut + 2, name.length - 1);
    if (_isLabelPart(base) &&
        (_isLabelPart(qualifier) || _numberedDriveLabel.hasMatch(qualifier))) {
      return true;
    }
    cut = name.indexOf(' (', cut + 1);
  }
  return false;
}

String parentLabelOf(String realPath, {required String? profilePath}) {
  var path = realPath.replaceAll('/', r'\');
  while (path.length > 3 && path.endsWith(r'\')) {
    path = path.substring(0, path.length - 1);
  }
  final drive = path.length >= 2 && path[1] == ':'
      ? '${path[0].toUpperCase()}:'
      : '';
  if (_driveRootPath.hasMatch(path)) return drive;
  final cut = path.lastIndexOf(r'\');
  if (cut <= 0) return drive;
  final parent = path.substring(0, cut);
  if (_driveRootPath.hasMatch(parent)) return drive;
  if (profilePath != null && samePath(parent, profilePath)) return drive;
  final name = parent.substring(parent.lastIndexOf(r'\') + 1);
  return _isLabelPart(name) && _balancedParentheses(name) ? name : drive;
}

List<String> visibleRootNames(
  List<({String label, bool home, String parentLabel})> roots,
) {
  final counts = <String, int>{};
  for (final root in roots) {
    if (root.home) continue;
    counts.update(folderKey(root.label), (n) => n + 1, ifAbsent: () => 1);
  }
  final names = List<String>.filled(roots.length, '');
  final used = <String>{};
  for (var i = 0; i < roots.length; i++) {
    final root = roots[i];
    if (root.home) continue;
    final repeated = counts[folderKey(root.label)]! > 1;
    var candidate = repeated
        ? '${root.label} (${root.parentLabel})'
        : root.label;
    var number = 2;
    while (!used.add(folderKey(candidate))) {
      candidate = '${root.label} (${root.parentLabel} $number)';
      number++;
    }
    names[i] = candidate;
  }
  return names;
}
