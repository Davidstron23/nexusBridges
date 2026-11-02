import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

const String _mainPath = 'windows/runner/main.cpp';
const String _windowPath = 'windows/runner/win32_window.cpp';
const String _flutterWindowPath = 'windows/runner/flutter_window.cpp';
const String _dropTargetPath = 'windows/runner/drop_target.cpp';
const String _dropTargetHeaderPath = 'windows/runner/drop_target.h';
const String _cmakePath = 'windows/runner/CMakeLists.txt';

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

final RegExp _nextCase = RegExp(r'\n\s*(case\s+\w+\s*:|default\s*:)');

String _caseBlock(String source, String message) {
  final start = _indexOf(source, 'case $message:');
  final end = source.indexOf(_nextCase, start + 1);
  expect(end, isNonNegative, reason: 'no case after $message');
  return source.substring(start, end);
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
        'OleInitialize(',
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

  group('E254 and E280: minimum client area and an always dark title bar', () {
    late String rawWindow;
    late String window;

    setUpAll(() {
      rawWindow = File(_windowPath).readAsStringSync();
      window = _withoutLineComments(rawWindow);
    });

    test('the minimum client area is 760 by 520', () {
      expect(window, contains('constexpr int kMinWindowWidth = 760;'));
      expect(window, contains('constexpr int kMinWindowHeight = 520;'));
      expect(_count(window, 'kMinWindowWidth = '), 1);
      expect(_count(window, 'kMinWindowHeight = '), 1);
    });

    test('WM_GETMINMAXINFO is handled once in Win32Window::MessageHandler', () {
      final handler = _indexOf(window, 'Win32Window::MessageHandler(');
      expect(_count(window, 'case WM_GETMINMAXINFO:'), 1);
      expect(_indexOf(window, 'case WM_GETMINMAXINFO:'), greaterThan(handler));
    });

    test('there is no WM_SETTINGCHANGE handler any more', () {
      expect(rawWindow.contains('WM_SETTINGCHANGE'), isFalse);
      expect(rawWindow.contains('ImmersiveColorSet'), isFalse);
      expect(rawWindow.contains('wcscmp'), isFalse);
      expect(rawWindow.contains('#include <cwchar>'), isFalse);
    });

    test('UpdateTheme sets TRUE in DWMWA_USE_IMMERSIVE_DARK_MODE without '
        'reading the registry', () {
      final start = _indexOf(
        window,
        'void Win32Window::UpdateTheme(HWND const window) {',
      );
      final open = window.indexOf('{', start);
      final close = window.indexOf('\n}', open);
      expect(close, isNonNegative);
      final body = window
          .substring(open + 1, close)
          .replaceAll(RegExp(r'\s+'), ' ')
          .trim();
      expect(
        body,
        'BOOL enable_dark_mode = TRUE; '
        'DwmSetWindowAttribute(window, DWMWA_USE_IMMERSIVE_DARK_MODE, '
        '&enable_dark_mode, sizeof(enable_dark_mode));',
      );
      expect(_count(window, 'void Win32Window::UpdateTheme('), 1);
    });

    test('nothing reads the Windows theme from the registry', () {
      for (final gone in [
        'RegGetValue',
        'AppsUseLightTheme',
        'kGetPreferredBrightnessRegKey',
        'kGetPreferredBrightnessRegValue',
        r'Themes\\Personalize',
        'Registry key for app theme preference',
        'light_mode',
      ]) {
        expect(rawWindow.contains(gone), isFalse, reason: gone);
      }
    });

    test('the window still applies the theme when it is created', () {
      final create = _indexOf(window, 'Win32Window::Create(');
      expect(_indexOf(window, 'UpdateTheme(window);', create), greaterThan(0));
    });

    test('WM_GETMINMAXINFO sets ptMinTrackSize from the client area scaled '
        'to the monitor', () {
      final block = _caseBlock(window, 'WM_GETMINMAXINFO');
      expect(block, contains('reinterpret_cast<MINMAXINFO*>(lparam)'));
      expect(block, contains('FlutterDesktopGetDpiForMonitor('));
      expect(
        block,
        contains('MonitorFromWindow(hwnd, MONITOR_DEFAULTTONEAREST)'),
      );
      expect(block, contains('dpi / 96.0'));
      expect(block, contains('Scale(kMinWindowWidth, scale)'));
      expect(block, contains('Scale(kMinWindowHeight, scale)'));
      expect(block, contains('ptMinTrackSize.x'));
      expect(block, contains('ptMinTrackSize.y'));
    });

    test('WM_GETMINMAXINFO turns the client area into a window size with '
        'AdjustWindowRectExForDpi before using it', () {
      final block = _caseBlock(window, 'WM_GETMINMAXINFO');
      final adjust = _indexOf(block, 'AdjustWindowRectExForDpi(');
      final style = _indexOf(block, 'GWL_STYLE', adjust);
      final extended = _indexOf(block, 'GWL_EXSTYLE', style);
      final width = _indexOf(block, 'ptMinTrackSize.x', extended);
      final height = _indexOf(block, 'ptMinTrackSize.y', extended);
      expect(width, greaterThan(adjust));
      expect(height, greaterThan(adjust));
      expect(
        block.contains(
          RegExp(r'ptMinTrackSize\.x\s*=\s*frame\.right\s*-\s*frame\.left;'),
        ),
        isTrue,
      );
      expect(
        block.contains(
          RegExp(r'ptMinTrackSize\.y\s*=\s*frame\.bottom\s*-\s*frame\.top;'),
        ),
        isTrue,
      );
    });

    test('WM_GETMINMAXINFO ends the message with return 0', () {
      final block = _caseBlock(window, 'WM_GETMINMAXINFO');
      expect(_count(block, 'return 0;'), 1);
      expect(_count(block, 'return'), 1);
      final assigned = block.lastIndexOf('ptMinTrackSize.y');
      expect(block.indexOf('return 0;'), greaterThan(assigned));
    });

    test('the colorization message still updates the theme', () {
      expect(
        window.contains(
          RegExp(
            r'case WM_DWMCOLORIZATIONCOLORCHANGED:\s*UpdateTheme\(hwnd\);',
          ),
        ),
        isTrue,
      );
    });

    test('the new C++ has no comments', () {
      final block = _caseBlock(rawWindow, 'WM_GETMINMAXINFO');
      expect(block.contains('//'), isFalse);
      expect(block.contains('/*'), isFalse);
      final start = _indexOf(rawWindow, 'void Win32Window::UpdateTheme(');
      final end = rawWindow.indexOf('\n}', start);
      final updateTheme = rawWindow.substring(start, end);
      expect(updateTheme.contains('//'), isFalse);
      expect(updateTheme.contains('/*'), isFalse);
      for (final line in rawWindow.split('\n')) {
        if (line.contains('kMinWindow')) {
          expect(line.contains('//'), isFalse, reason: line);
        }
      }
    });

    test('the initial window size is still 1280 by 720', () {
      expect(source, contains('Win32Window::Size size(1280, 720);'));
    });
  });

  group('E603: the runner receives files dropped from the Explorer', () {
    late String mainSource;
    late String flutterWindow;
    late String dropTarget;
    late String rawDropTarget;
    late String rawDropHeader;
    late String cmake;

    setUpAll(() {
      mainSource = _withoutLineComments(File(_mainPath).readAsStringSync());
      flutterWindow = _withoutLineComments(
        File(_flutterWindowPath).readAsStringSync(),
      );
      rawDropTarget = File(_dropTargetPath).readAsStringSync();
      rawDropHeader = File(_dropTargetHeaderPath).readAsStringSync();
      dropTarget = _withoutLineComments(rawDropTarget);
      cmake = File(_cmakePath).readAsStringSync();
    });

    test('main.cpp starts and stops OLE once, in place of plain COM', () {
      expect(_count(mainSource, '::OleInitialize(nullptr);'), 1);
      expect(_count(mainSource, '::OleUninitialize();'), 1);
      expect(mainSource.contains('CoInitializeEx('), isFalse);
      expect(mainSource.contains('CoUninitialize('), isFalse);
    });

    test('OLE starts before the window exists and stops after the loop', () {
      final init = _indexOf(mainSource, '::OleInitialize(');
      expect(init, lessThan(_indexOf(mainSource, 'DartProject project(')));
      expect(init, lessThan(_indexOf(mainSource, 'window.Create(')));
      final loop = _indexOf(mainSource, '::GetMessage(');
      expect(_indexOf(mainSource, '::OleUninitialize();'), greaterThan(loop));
    });

    test('the drop target is registered in OnCreate and revoked in '
        'OnDestroy, once each', () {
      expect(_count(flutterWindow, '::RegisterDragDrop('), 1);
      expect(_count(flutterWindow, '::RevokeDragDrop('), 1);
      final create = _indexOf(flutterWindow, 'FlutterWindow::OnCreate()');
      final destroy = _indexOf(flutterWindow, 'FlutterWindow::OnDestroy()');
      final register = _indexOf(flutterWindow, '::RegisterDragDrop(');
      final revoke = _indexOf(flutterWindow, '::RevokeDragDrop(');
      expect(register, inExclusiveRange(create, destroy));
      expect(revoke, greaterThan(destroy));
    });

    test('the view is registered after it is created and revoked before '
        'the controller is released', () {
      final view = _indexOf(flutterWindow, 'SetChildContent(');
      expect(_indexOf(flutterWindow, '::RegisterDragDrop('), greaterThan(view));
      final destroy = _indexOf(flutterWindow, 'FlutterWindow::OnDestroy()');
      final revoke = _indexOf(flutterWindow, '::RevokeDragDrop(', destroy);
      final release = _indexOf(
        flutterWindow,
        'flutter_controller_ = nullptr;',
        destroy,
      );
      expect(revoke, lessThan(release));
    });

    test('a failed registration is logged and the window keeps going', () {
      final register = _indexOf(flutterWindow, '::RegisterDragDrop(');
      final end = _indexOf(flutterWindow, 'return true;', register);
      final block = flutterWindow.substring(register, end);
      expect(block, contains('SUCCEEDED('));
      expect(block, contains('stderr'));
      expect(block.contains('return false'), isFalse);
    });

    test('the events travel on the nexus_bridges/drop channel', () {
      expect(flutterWindow, contains('"nexus_bridges/drop"'));
      expect(flutterWindow, contains('StandardMethodCodec::GetInstance()'));
      for (final method in ['enter', 'over', 'leave', 'drop']) {
        expect(dropTarget, contains('"$method"'), reason: method);
      }
    });

    test('only lists of disk paths (CF_HDROP) are accepted', () {
      expect(dropTarget, contains('CF_HDROP'));
      expect(dropTarget, contains('QueryGetData('));
      expect(dropTarget, contains('DROPEFFECT_NONE'));
      expect(dropTarget, contains('DROPEFFECT_COPY'));
      final enter = _indexOf(dropTarget, 'DropTarget::DragEnter(');
      final query = _indexOf(dropTarget, 'OffersDiskPaths(data)', enter);
      final notify = _indexOf(dropTarget, 'NotifyPoint("enter"', enter);
      expect(query, lessThan(notify));
    });

    test('files extracted by the Explorer into a temporary folder are '
        'ignored', () {
      expect(dropTarget, contains('GetTempPathW('));
      expect(dropTarget, contains('L"Temp"'));
      expect(dropTarget, contains('iswdigit('));
      expect(dropTarget, contains('InsideExtractionFolder('));
    });

    test('the real count and the length of every path come from '
        'DragQueryFileW', () {
      expect(
        dropTarget,
        contains('DragQueryFileW(hdrop, 0xFFFFFFFF, nullptr, 0)'),
      );
      expect(dropTarget, contains('DragQueryFileW(hdrop, i, nullptr, 0)'));
      expect(dropTarget, contains('DragQueryFileW(hdrop, i, path.data()'));
      expect(dropTarget, contains('constexpr UINT kMaxPaths = 1001;'));
      expect(dropTarget, contains('std::min(count, kMaxPaths)'));
      expect(dropTarget, contains('flutter::EncodableValue("count")'));
      expect(dropTarget, contains('ReleaseStgMedium('));
    });

    test('the dropped items are never opened, run or logged', () {
      for (final forbidden in [
        'CreateFile',
        'fopen',
        'ifstream',
        'ShellExecute',
        'CreateProcess',
        'GetFileAttributes',
        'FindFirstFile',
        'printf',
        'cout',
        'cerr',
        'OutputDebugString',
        'MoveFile',
        'DeleteFile',
      ]) {
        expect(dropTarget.contains(forbidden), isFalse, reason: forbidden);
      }
    });

    test('the target counts references and answers IDropTarget', () {
      expect(dropTarget, contains('IID_IDropTarget'));
      expect(dropTarget, contains('InterlockedIncrement('));
      expect(dropTarget, contains('InterlockedDecrement('));
      expect(dropTarget, contains('delete this;'));
    });

    test('CMake builds the target and links the system libraries', () {
      expect(cmake, contains('"drop_target.cpp"'));
      expect(cmake, contains('"ole32.lib"'));
      expect(cmake, contains('"shell32.lib"'));
    });

    test('the new C++ files have no comments', () {
      for (final source in [rawDropTarget, rawDropHeader]) {
        expect(source.contains('//'), isFalse);
        expect(source.contains('/*'), isFalse);
      }
    });
  });
}
