import 'dart:io';

import 'package:test/test.dart';

const String transferFolder = 'lib/src/transfer';

const String shellFile = 'windows_shell.dart';

Map<String, String> transferSources() {
  final sources = <String, String>{};
  for (final entity in Directory(transferFolder).listSync(recursive: true)) {
    if (entity is File && entity.path.endsWith('.dart')) {
      final name = entity.uri.pathSegments.last;
      sources[name] = entity.readAsStringSync();
    }
  }
  return sources;
}

List<String> topLevelArguments(String call) {
  final open = call.indexOf('(');
  final args = <String>[];
  var depth = 0;
  var start = open + 1;
  for (var i = open + 1; i < call.length; i++) {
    final char = call[i];
    if (char == '(') depth++;
    if (char == ')') {
      if (depth == 0) {
        args.add(call.substring(start, i).trim());
        break;
      }
      depth--;
    }
    if (char == ',' && depth == 0) {
      args.add(call.substring(start, i).trim());
      start = i + 1;
    }
  }
  return args.where((arg) => arg.isNotEmpty).toList();
}

List<String> shellExecuteCalls(String source) {
  final calls = <String>[];
  for (final match in RegExp(r'\bShellExecute\s*\(').allMatches(source)) {
    calls.add(source.substring(match.start));
  }
  return calls;
}

void main() {
  late Map<String, String> sources;

  setUpAll(() {
    sources = transferSources();
  });

  test('the scan reads every transfer file, the shell one included', () {
    expect(sources.length, greaterThanOrEqualTo(10));
    expect(sources.keys, contains(shellFile));
  });

  test('E102 no transfer file starts processes', () {
    final pattern = RegExp(r'\bProcess\b');
    final offenders = [
      for (final entry in sources.entries)
        if (pattern.hasMatch(entry.value)) entry.key,
    ];
    expect(offenders, isEmpty);
  });

  test('E102 no transfer file uses other ways to open or run a file', () {
    final pattern = RegExp(
      r'\b(ShellExecuteEx|ShellExecuteExW|CreateProcess|CreateProcessW|'
      r'WinExec|ShellExecuteW|ShellExecuteA|OpenFile|IShellExecuteHook)\b',
    );
    final offenders = [
      for (final entry in sources.entries)
        for (final match in pattern.allMatches(entry.value))
          '${entry.key}: ${match.group(0)}',
    ];
    expect(offenders, isEmpty);
  });

  test('E102 no transfer file names an opening verb', () {
    final pattern = RegExp(
      r'''['"](open|runas|edit|print|openas|opennew|properties)['"]''',
      caseSensitive: false,
    );
    final offenders = [
      for (final entry in sources.entries)
        for (final match in pattern.allMatches(entry.value))
          '${entry.key}: ${match.group(0)}',
    ];
    expect(offenders, isEmpty);
  });

  test('E102 ShellExecute appears only in the shell file', () {
    final users = [
      for (final entry in sources.entries)
        if (RegExp(r'\bShellExecute\b').hasMatch(entry.value)) entry.key,
    ];
    expect(users, anyOf(isEmpty, equals([shellFile])));
  });

  test('E102 every ShellExecute call explores a folder, never the file', () {
    final calls = shellExecuteCalls(sources[shellFile]!);
    expect(calls, isNotEmpty);
    for (final call in calls) {
      final args = topLevelArguments(call);
      expect(args.length, 6, reason: call);
      expect(args[1], contains("'explore'"));
      expect(args[2], isNot(contains('filePath')));
      expect(args[2].toLowerCase(), contains('folder'));
    }
  });

  test('E102 the revealer selects the file through the shell item API', () {
    final source = sources[shellFile]!;
    expect(source, contains("'ILCreateFromPathW'"));
    expect(source, contains("'SHOpenFolderAndSelectItems'"));
    expect(source, contains("'ILFree'"));
  });

  test('the argument splitter handles nested calls', () {
    expect(topLevelArguments("f(a, g(b, c), 'x')"), ['a', 'g(b, c)', "'x'"]);
  });
}
