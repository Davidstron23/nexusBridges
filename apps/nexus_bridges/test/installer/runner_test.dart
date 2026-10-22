import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

const String _mainPath = 'windows/runner/main.cpp';
const String _windowPath = 'windows/runner/win32_window.cpp';

const String _createMutex =
    r'::CreateMutexW(nullptr, TRUE, L"Local\\NexusBridges.SingleInstance")';
const String _mutexError = 'const DWORD mutex_error = ::GetLastError();';
const String _findWindow =
    r'::FindWindowW(L"FLUTTER_RUNNER_WIN32_WINDOW", L"NexusBridges")';
const String _restoreIfMinimized =
    'if (::IsIconic(w)) ::ShowWindow(w, SW_RESTORE);';
final RegExp _secondInstance = RegExp(
  r'if\s*\(\s*mutex_error\s*==\s*(ERROR_ALREADY_EXISTS|ERROR_ACCESS_DENIED)'
  r'\s*\|\|\s*mutex_error\s*==\s*(ERROR_ALREADY_EXISTS|ERROR_ACCESS_DENIED)'
  r'\s*\)\s*\{',
);

String _withoutLineComments(String source) =>
    source.replaceAll(RegExp(r'//[^\n]*'), '');

int _indexOf(String source, String needle, [int start = 0]) {
  final index = source.indexOf(needle, start);
  expect(index, isNonNegative, reason: 'missing "$needle"');
  return index;
}

int _count(String source, String needle) => source.split(needle).length - 1;

RegExpMatch _condition(String source) {
  final matches = _secondInstance.allMatches(source).toList();
  expect(matches, hasLength(1), reason: 'missing the second-instance check');
  return matches.single;
}

String _earlyExit(String source) {
  final open = _condition(source).end - 1;
  expect(source[open], '{');
  var depth = 0;
  for (var i = open; i < source.length; i++) {
    if (source[i] == '{') depth++;
    if (source[i] == '}') depth--;
    if (depth == 0) return source.substring(open + 1, i).trim();
  }
  fail('unbalanced braces after the second-instance check');
}

void main() {
  late String source;

  setUpAll(() {
    source = _withoutLineComments(File(_mainPath).readAsStringSync());
  });

  group('RF-37: a second instance brings the first one to the front', () {
    test('creates the session-local single-instance mutex', () {
      expect(source, contains('HANDLE mutex = $_createMutex;'));
      expect(_count(source, 'CreateMutexW('), 1);
    });

    test('the mutex is the first thing wWinMain does', () {
      final entry = _indexOf(source, 'wWinMain(');
      final body = _indexOf(source, '{', entry);
      final mutex = _indexOf(source, 'CreateMutexW(');
      expect(mutex, greaterThan(body));
      final before = source.substring(body + 1, mutex);
      expect(before.trim(), 'HANDLE mutex = ::');
    });

    test('the mutex is created before COM, the console and the window', () {
      final mutex = _indexOf(source, 'CreateMutexW(');
      for (final later in [
        'CoInitializeEx(',
        'AttachConsole(',
        'DartProject project(',
        'window.Create(',
      ]) {
        expect(mutex, lessThan(_indexOf(source, later)), reason: later);
      }
    });

    test('saves GetLastError right after creating the mutex', () {
      final mutex = _indexOf(source, 'HANDLE mutex = $_createMutex;');
      final statementEnd = mutex + 'HANDLE mutex = $_createMutex;'.length;
      final saved = _indexOf(source, _mutexError, statementEnd);
      expect(source.substring(statementEnd, saved).trim(), isEmpty);
      expect(_count(source, 'GetLastError('), 1);
      expect(_count(source, _mutexError), 1);
    });

    test('checks the saved error right after saving it', () {
      final saved = _indexOf(source, _mutexError);
      final check = _condition(source).start;
      expect(check, greaterThan(saved));
      expect(
        source.substring(saved + _mutexError.length, check).trim(),
        isEmpty,
      );
    });

    test('the second-instance check covers both errors with ||', () {
      final match = _condition(source);
      expect(
        {match.group(1), match.group(2)},
        {'ERROR_ALREADY_EXISTS', 'ERROR_ACCESS_DENIED'},
      );
      expect(_count(source, 'mutex_error'), 3);
    });

    test('ERROR_ACCESS_DENIED takes the early exit', () {
      final match = _condition(source);
      expect(_count(source, 'ERROR_ACCESS_DENIED'), 1);
      final denied = source.indexOf('ERROR_ACCESS_DENIED');
      expect(denied, inInclusiveRange(match.start, match.end));
      expect(source.substring(0, match.start).contains('return'), isFalse);
      final block = _earlyExit(source);
      expect(block, startsWith('HWND w = '));
      expect(block.endsWith('return EXIT_SUCCESS;'), isTrue);
      expect(_count(block, 'return'), 1);
    });

    test('finds the existing window by its class and title', () {
      expect(_earlyExit(source), contains('HWND w = $_findWindow;'));
    });

    test('restores the window and brings it to the foreground', () {
      final block = _earlyExit(source);
      final find = _indexOf(block, 'FindWindowW(');
      final guard = _indexOf(block, 'if (w)', find);
      final restore = _indexOf(block, '::ShowWindow(w, SW_RESTORE);', guard);
      final front = _indexOf(block, '::SetForegroundWindow(w);', restore);
      expect(front, greaterThan(restore));
    });

    test('restores only a minimized window, before bringing it forward', () {
      final block = _earlyExit(source);
      final guard = _indexOf(block, 'if (w)');
      final iconic = _indexOf(block, _restoreIfMinimized, guard);
      final restoreEnd = iconic + _restoreIfMinimized.length;
      final front = _indexOf(block, '::SetForegroundWindow(w);', restoreEnd);
      expect(block.substring(restoreEnd, front).trim(), isEmpty);
      expect(_count(source, 'ShowWindow('), 1);
      expect(_count(source, 'IsIconic('), 1);
      expect(_count(source, 'SetForegroundWindow('), 1);
      expect(_count(source, 'SW_RESTORE'), 1);
      expect(
        source.contains(RegExp(r'SW_(SHOW|SHOWNORMAL|NORMAL|MAXIMIZE)\b')),
        isFalse,
      );
    });

    test('the second instance releases its handle and exits successfully', () {
      final block = _earlyExit(source);
      final front = _indexOf(block, 'SetForegroundWindow(');
      final close = _indexOf(block, '::CloseHandle(mutex);', front);
      final exit = _indexOf(block, 'return EXIT_SUCCESS;', close);
      expect(
        block.substring(close + '::CloseHandle(mutex);'.length, exit).trim(),
        isEmpty,
      );
      expect(block.endsWith('return EXIT_SUCCESS;'), isTrue);
    });

    test('the first instance closes the mutex on its normal exit', () {
      final loop = _indexOf(source, '::GetMessage(');
      final close = _indexOf(source, '::CloseHandle(mutex);', loop);
      final exit = _indexOf(source, 'return EXIT_SUCCESS;', close);
      expect(exit, greaterThan(close));
      expect(_count(source, '::CloseHandle(mutex);'), greaterThan(1));
    });

    test('the app still starts if the mutex cannot be created', () {
      expect(source.contains(RegExp(r'if\s*\(\s*!\s*mutex\s*\)')), isFalse);
      expect(
        source.contains(RegExp(r'mutex\s*==\s*(nullptr|NULL|0)\b')),
        isFalse,
      );
      expect(
        source.contains(RegExp(r'mutex\s*==\s*INVALID_HANDLE_VALUE')),
        isFalse,
      );
    });

    test('the window is titled NexusBridges', () {
      expect(source, contains('window.Create(L"NexusBridges", origin, size)'));
      expect(source.contains('L"nexus_bridges"'), isFalse);
    });

    test('the Flutter window class is the one FindWindowW looks for', () {
      final window = _withoutLineComments(File(_windowPath).readAsStringSync());
      expect(
        window,
        contains(
          'constexpr const wchar_t kWindowClassName[] = '
          'L"FLUTTER_RUNNER_WIN32_WINDOW";',
        ),
      );
      expect(
        window,
        contains('window_class.lpszClassName = kWindowClassName;'),
      );
      expect(
        window.contains(
          RegExp(r'CreateWindow\(\s*window_class,\s*title\.c_str\(\)'),
        ),
        isTrue,
      );
    });
  });
}
