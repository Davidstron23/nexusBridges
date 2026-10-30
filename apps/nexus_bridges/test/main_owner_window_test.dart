import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:nexus_bridges/main.dart';
import 'package:nexus_bridges/src/l10n/app_strings.dart';

const String _appMainPath = 'lib/main.dart';
const String _runnerMainPath = 'windows/runner/main.cpp';
const String _runnerWindowPath = 'windows/runner/win32_window.cpp';

String _withoutLineComments(String source) =>
    source.replaceAll(RegExp(r'//[^\n]*'), '');

String _read(String path) =>
    _withoutLineComments(File(path).readAsStringSync());

int _indexOf(String source, String needle, [int start = 0]) {
  final index = source.indexOf(needle, start);
  expect(index, isNonNegative, reason: 'missing "$needle"');
  return index;
}

int _count(String source, String needle) => source.split(needle).length - 1;

String _arguments(String source, String call) {
  final open = _indexOf(source, call) + call.length - 1;
  expect(source[open], '(');
  var depth = 0;
  for (var i = open; i < source.length; i++) {
    if (source[i] == '(') depth++;
    if (source[i] == ')') depth--;
    if (depth == 0) return source.substring(open + 1, i);
  }
  fail('unbalanced parentheses after "$call"');
}

void main() {
  late String app;
  late String runnerMain;
  late String runnerWindow;

  setUpAll(() {
    app = _read(_appMainPath);
    runnerMain = _read(_runnerMainPath);
    runnerWindow = _read(_runnerWindowPath);
  });

  group('E250: the app window owns the Windows pickers (D-10)', () {
    test('the constants hold the class and title of the runner window', () {
      expect(windowClassName, 'FLUTTER_RUNNER_WIN32_WINDOW');
      expect(windowTitle, 'NexusBridges');
    });

    test('main.dart declares both as top-level constants', () {
      expect(
        app,
        contains(
          "const String windowClassName = 'FLUTTER_RUNNER_WIN32_WINDOW';",
        ),
      );
      expect(app, contains("const String windowTitle = 'NexusBridges';"));
      expect(_count(app, 'const String windowClassName'), 1);
      expect(_count(app, 'const String windowTitle'), 1);
    });

    test('the node is started with the owner window class and title', () {
      expect(_count(app, 'NexusNode.start('), 1);
      final arguments = _arguments(app, 'NexusNode.start(');
      expect(arguments, contains('ownerWindowClass: windowClassName'));
      expect(arguments, contains('ownerWindowTitle: windowTitle'));
      expect(_count(arguments, 'ownerWindowClass:'), 1);
      expect(_count(arguments, 'ownerWindowTitle:'), 1);
    });

    test('that start is the controller startNode', () {
      expect(
        app.contains(RegExp(r'startNode:\s*\(\)\s*=>\s*NexusNode\.start\(')),
        isTrue,
      );
      expect(_count(app, 'startNode:'), 1);
    });

    test('the runner registers its window class with the same name', () {
      expect(
        runnerWindow,
        contains(
          'constexpr const wchar_t kWindowClassName[] = L"$windowClassName";',
        ),
      );
      expect(
        runnerWindow,
        contains('window_class.lpszClassName = kWindowClassName;'),
      );
    });

    test('the runner creates its window with the same title', () {
      expect(
        runnerMain,
        contains('window.Create(L"$windowTitle", origin, size)'),
      );
      expect(_count(runnerMain, 'window.Create('), 1);
    });

    test('the single-instance lookup uses the same class and title', () {
      expect(
        runnerMain,
        contains('::FindWindowW(L"$windowClassName", L"$windowTitle")'),
      );
    });

    test('the app title in both languages matches the window title', () {
      expect(stringsFor('es').appTitle, windowTitle);
      expect(stringsFor('en').appTitle, windowTitle);
    });
  });
}
