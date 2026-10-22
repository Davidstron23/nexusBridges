import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

const String _mainPath = 'windows/runner/main.cpp';
const String _windowPath = 'windows/runner/win32_window.cpp';

const String _createMutex =
    r'::CreateMutexW(nullptr, TRUE, L"Local\\NexusBridges.SingleInstance")';
const String _alreadyExists = r'::GetLastError() == ERROR_ALREADY_EXISTS';
const String _findWindow =
    r'::FindWindowW(L"FLUTTER_RUNNER_WIN32_WINDOW", L"NexusBridges")';

String _withoutLineComments(String source) =>
    source.replaceAll(RegExp(r'//[^\n]*'), '');

int _indexOf(String source, String needle, [int start = 0]) {
  final index = source.indexOf(needle, start);
  expect(index, isNonNegative, reason: 'missing "$needle"');
  return index;
}

String _earlyExit(String source) {
  final start = _indexOf(source, _alreadyExists);
  final end = _indexOf(source, 'return EXIT_SUCCESS;', start);
  return source.substring(start, end + 'return EXIT_SUCCESS;'.length);
}

void main() {
  late String source;

  setUpAll(() {
    source = _withoutLineComments(File(_mainPath).readAsStringSync());
  });

  group('RF-37: a second instance brings the first one to the front', () {
    test('creates the session-local single-instance mutex', () {
      expect(source, contains('HANDLE mutex = $_createMutex;'));
      expect(source.split('CreateMutexW(').length - 1, 1);
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

    test('checks ERROR_ALREADY_EXISTS right after creating the mutex', () {
      final mutex = _indexOf(source, 'CreateMutexW(');
      final check = _indexOf(source, 'if ($_alreadyExists)');
      expect(check, greaterThan(mutex));
      expect(source.substring(mutex, check).split(';').length - 1, 1);
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

    test('the second instance releases its handle and exits successfully', () {
      final block = _earlyExit(source);
      final front = _indexOf(block, 'SetForegroundWindow(');
      final close = _indexOf(block, '::CloseHandle(mutex);', front);
      expect(block.endsWith('return EXIT_SUCCESS;'), isTrue);
      expect(close, lessThan(block.length - 'return EXIT_SUCCESS;'.length));
    });

    test('the first instance closes the mutex on its normal exit', () {
      final loop = _indexOf(source, '::GetMessage(');
      final close = _indexOf(source, '::CloseHandle(mutex);', loop);
      final exit = _indexOf(source, 'return EXIT_SUCCESS;', close);
      expect(exit, greaterThan(close));
      expect(source.split('::CloseHandle(mutex);').length - 1, greaterThan(1));
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
