import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

const String _mainPath = 'windows/runner/main.cpp';
const String _windowPath = 'windows/runner/win32_window.cpp';
const String _flutterWindowPath = 'windows/runner/flutter_window.cpp';
const String _trayIconPath = 'windows/runner/tray_icon.cpp';
const String _trayIconHeaderPath = 'windows/runner/tray_icon.h';
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

String _functionBody(String source, String signature) {
  final open = _indexOf(source, '{', _indexOf(source, signature));
  var depth = 0;
  for (var i = open; i < source.length; i++) {
    if (source[i] == '{') depth++;
    if (source[i] == '}') depth--;
    if (depth == 0) return source.substring(open + 1, i);
  }
  fail('unbalanced braces after $signature');
}

String _taskbarBlock(String source) {
  final start = _indexOf(source, 'message == taskbar_created_');
  return source.substring(start, _indexOf(source, 'switch (message)', start));
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
      expect(_count(source, 'ShowWindow('), 2);
      expect(_count(source, 'IsIconic('), 1);
      expect(_count(source, 'SetForegroundWindow('), 1);
      expect(_count(source, 'SW_RESTORE'), 1);
      expect(_count(source, 'SW_SHOW'), 1);
      expect(
        source.contains(RegExp(r'SW_(SHOWNORMAL|NORMAL|MAXIMIZE)\b')),
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

  group('E254 and E280: minimum client area and the title bar theme', () {
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

    test('UpdateTheme sets dark_title_bar_ in DWMWA_USE_IMMERSIVE_DARK_MODE '
        'without reading the registry', () {
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
        'BOOL enable_dark_mode = dark_title_bar_ ? TRUE : FALSE; '
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

  group('Q-13: the count of a drop and the extraction folder', () {
    late String dropTarget;

    setUpAll(() {
      dropTarget = _withoutLineComments(
        File(_dropTargetPath).readAsStringSync(),
      );
    });

    String body(String signature) {
      final start = _indexOf(dropTarget, signature);
      final open = _indexOf(dropTarget, '{', start);
      var depth = 0;
      for (var i = open; i < dropTarget.length; i++) {
        if (dropTarget[i] == '{') depth++;
        if (dropTarget[i] == '}') depth--;
        if (depth == 0) return dropTarget.substring(open, i + 1);
      }
      fail('unbalanced braces in $signature');
    }

    test('Q-13 up to 1001 paths the count sent is the number of paths that '
        'were converted; above it, the real count', () {
      final drop = body('DropTarget::Drop(');
      final rule = RegExp(
        r'const\s+int\s+reported_count\s*=\s*count\s*<=\s*kMaxPaths\s*\?\s*'
        r'static_cast<int>\(\s*encoded\.size\(\)\s*\)\s*:\s*'
        r'static_cast<int>\(\s*count\s*\)\s*;',
      );
      expect(rule.allMatches(drop), hasLength(1));
      expect(dropTarget, contains('constexpr UINT kMaxPaths = 1001;'));
      final converted = _indexOf(drop, 'encoded.emplace_back(');
      final counted = _indexOf(drop, 'reported_count =');
      expect(counted, greaterThan(converted));
      final key = _indexOf(drop, 'flutter::EncodableValue("count")');
      final value = _indexOf(drop, 'flutter::EncodableValue(', key + 1);
      expect(
        drop
            .substring(value)
            .startsWith('flutter::EncodableValue(reported_count)'),
        isTrue,
      );
      expect(drop.contains('EncodableValue(static_cast<int>(count))'), isFalse);
    });

    test('Q-13 a path that cannot be converted to UTF-8 is left out and does '
        'not count', () {
      final drop = body('DropTarget::Drop(');
      final convert = _indexOf(drop, 'Utf8FromUtf16(');
      final guard = _indexOf(drop, 'if (!utf8.empty())', convert);
      final add = _indexOf(drop, 'encoded.emplace_back(utf8)', guard);
      expect(add, greaterThan(guard));
    });

    test('Q-13 Temp<n> counts as the extraction folder only when it is a '
        'folder followed by more path', () {
      final rule = body('bool InsideExtractionFolder(');
      final digit = _indexOf(rule, 'std::iswdigit(rest[4])');
      final separator = _indexOf(rule, r"std::wcschr(rest, L'\\')");
      expect(separator, greaterThan(digit));
      expect(
        rule,
        contains(r"return separator != nullptr && separator[1] != L'\0';"),
      );
      expect(_count(rule, 'return true'), 0);
    });
  });

  group('B-2: the drop target lets go of the channel before it is '
      'destroyed', () {
    late String dropTarget;
    late String dropHeader;
    late String flutterWindow;

    setUpAll(() {
      dropTarget = _withoutLineComments(
        File(_dropTargetPath).readAsStringSync(),
      );
      dropHeader = _withoutLineComments(
        File(_dropTargetHeaderPath).readAsStringSync(),
      );
      flutterWindow = _withoutLineComments(
        File(_flutterWindowPath).readAsStringSync(),
      );
    });

    test('B-2 Detach is public and clears the channel', () {
      final public = _indexOf(dropHeader, 'public:');
      final private = _indexOf(dropHeader, 'private:');
      final detach = _indexOf(dropHeader, 'void Detach();');
      expect(detach, inExclusiveRange(public, private));
      final start = _indexOf(dropTarget, 'void DropTarget::Detach()');
      final end = _indexOf(dropTarget, '}', start);
      expect(dropTarget.substring(start, end), contains('channel_ = nullptr;'));
    });

    test('B-2 Notify does nothing without a channel, and it is the only '
        'place that uses it', () {
      final start = _indexOf(dropTarget, 'void DropTarget::Notify(');
      final guard = _indexOf(dropTarget, 'if (channel_ == nullptr) {', start);
      final early = _indexOf(dropTarget, 'return;', guard);
      final invoke = _indexOf(dropTarget, 'channel_->InvokeMethod(', start);
      expect(early, lessThan(invoke));
      expect(_count(dropTarget, 'channel_->'), 1);
    });

    test('B-2 OnDestroy detaches the target before releasing it and before '
        'the channel goes away', () {
      final destroy = _indexOf(flutterWindow, 'FlutterWindow::OnDestroy()');
      final detach = _indexOf(
        flutterWindow,
        'drop_target_->Detach();',
        destroy,
      );
      final release = _indexOf(
        flutterWindow,
        'drop_target_->Release();',
        destroy,
      );
      final channel = _indexOf(
        flutterWindow,
        'drop_channel_ = nullptr;',
        destroy,
      );
      expect(detach, lessThan(release));
      expect(detach, lessThan(channel));
      expect(_count(flutterWindow, 'drop_target_->Detach();'), 1);
    });
  });

  group('E859: the title bar follows the theme through the window channel '
      '(RF-511)', () {
    late String flutterWindow;
    late String flutterWindowHeader;
    late String window;
    late String windowHeader;

    setUpAll(() {
      flutterWindow = File(_flutterWindowPath).readAsStringSync();
      flutterWindowHeader = File('windows/runner/flutter_window.h')
          .readAsStringSync();
      window = File(_windowPath).readAsStringSync();
      windowHeader = File('windows/runner/win32_window.h').readAsStringSync();
    });

    String body(String source, String signature) {
      final start = _indexOf(source, signature);
      final open = _indexOf(source, '{', start);
      var depth = 0;
      for (var i = open; i < source.length; i++) {
        if (source[i] == '{') depth++;
        if (source[i] == '}') depth--;
        if (depth == 0) return source.substring(open + 1, i);
      }
      fail('unbalanced braces after $signature');
    }

    test('the window channel exists next to the drop channel, with the '
        'standard codec', () {
      expect(_count(flutterWindow, '"nexus_bridges/window"'), 1);
      expect(_count(flutterWindow, '"nexus_bridges/drop"'), 1);
      final create = body(flutterWindow, 'bool FlutterWindow::OnCreate()');
      final channel = _indexOf(create, '"nexus_bridges/window"');
      expect(
        create.indexOf('&flutter::StandardMethodCodec::GetInstance()', channel),
        isNonNegative,
      );
      expect(create, contains('window_channel_->SetMethodCallHandler('));
      expect(create, contains('HandleWindowCall(call, std::move(result))'));
      expect(flutterWindowHeader, contains('window_channel_;'));
    });

    test('setDarkTitleBar reads the "dark" bool, calls SetDarkTitleBar and '
        'anything else is not implemented', () {
      final handler = body(
        flutterWindow,
        'void FlutterWindow::HandleWindowCall(',
      );
      expect(handler, contains('call.method_name() == "setDarkTitleBar"'));
      expect(handler, contains('flutter::EncodableValue("dark")'));
      expect(handler, contains('std::get_if<bool>(&dark->second) == nullptr'));
      expect(
        handler,
        contains('SetDarkTitleBar(std::get<bool>(dark->second));'),
      );
      expect(handler, contains('result->Success();'));
      expect(_count(handler, 'result->Error("bad_arguments");'), 2);
      expect(handler.trim(), endsWith('result->NotImplemented();'));
      expect(handler, isNot(contains('//')));
    });

    test('OnDestroy lets go of the window channel before the controller', () {
      final destroy = body(flutterWindow, 'void FlutterWindow::OnDestroy()');
      final release = _indexOf(destroy, 'window_channel_ = nullptr;');
      final controller = _indexOf(destroy, 'flutter_controller_ = nullptr;');
      expect(release, lessThan(controller));
    });

    test('SetDarkTitleBar keeps the value, repaints the frame without '
        'activating the window, and the bar starts dark', () {
      final setter = body(
        window,
        'void Win32Window::SetDarkTitleBar(bool dark)',
      );
      expect(setter, contains('dark_title_bar_ = dark;'));
      expect(setter, contains('UpdateTheme(window_handle_);'));
      expect(setter, contains('SWP_FRAMECHANGED'));
      expect(setter, contains('SWP_NOACTIVATE'));
      expect(setter, contains('SWP_NOZORDER'));
      expect(setter, isNot(contains('SetForegroundWindow')));
      expect(setter, isNot(contains('//')));
      final guard = _indexOf(setter, 'if (!window_handle_)');
      expect(guard, lessThan(_indexOf(setter, 'UpdateTheme(')));
      expect(windowHeader, contains('void SetDarkTitleBar(bool dark);'));
      expect(windowHeader, contains('bool dark_title_bar_ = true;'));
      expect(windowHeader, isNot(contains('static void UpdateTheme(')));
    });

    test('UpdateTheme only uses dark_title_bar_ and nothing in the runner '
        'reads the Windows theme from the registry', () {
      final update = body(
        window,
        'void Win32Window::UpdateTheme(HWND const window)',
      );
      expect(update, contains('dark_title_bar_ ? TRUE : FALSE'));
      for (final file in Directory('windows/runner').listSync()) {
        if (file is! File) continue;
        final text = file.readAsStringSync();
        for (final banned in [
          'RegGetValue',
          'RegOpenKey',
          'RegQueryValue',
          'AppsUseLightTheme',
        ]) {
          expect(text, isNot(contains(banned)), reason: '${file.path} $banned');
        }
      }
    });
  });

  group('T8 and T9: the system tray in the runner', () {
    late String shell;
    late String shellRaw;
    late String tray;
    late String trayRaw;
    late String trayHeaderRaw;

    setUpAll(() {
      shellRaw = File(_flutterWindowPath).readAsStringSync();
      shell = _withoutLineComments(shellRaw);
      trayRaw = File(_trayIconPath).readAsStringSync();
      tray = _withoutLineComments(trayRaw);
      trayHeaderRaw = File(_trayIconHeaderPath).readAsStringSync();
    });

    group('E885 the window channel and the icon (RF-521 to RF-527)', () {
      test('the channel is nexus_bridges/window', () {
        expect(shell, contains('"nexus_bridges/window"'));
      });

      test('WM_CLOSE is handled before Flutter and only when attached', () {
        final close = _indexOf(shell, 'case WM_CLOSE:');
        expect(close, lessThan(_indexOf(shell, 'HandleTopLevelWindowProc(')));
        final block = _caseBlock(shell, 'WM_CLOSE');
        expect(block, contains('attached_'));
        expect(block, contains('SendEvent("closeRequested")'));
        expect(block, contains('return 0;'));
        expect(block, isNot(contains('DestroyWindow')));
        expect(block, isNot(contains('SW_HIDE')));
        expect(
          block.indexOf('attached_'),
          lessThan(block.indexOf('SendEvent')),
        );
      });

      test('TaskbarCreated is registered and handled with its own if', () {
        expect(
          shell,
          contains(
            'taskbar_created_ = ::RegisterWindowMessageW('
            'L"TaskbarCreated");',
          ),
        );
        final block = _taskbarBlock(shell);
        expect(block, contains('AddTrayIcon()'));
        expect(block, contains('StartTrayRetry()'));
        expect(block, contains('ReportTrayVisibility()'));
        expect(block, contains('tray_enabled_'));
        expect(
          block.indexOf('tray_enabled_'),
          lessThan(block.indexOf('AddTrayIcon()')),
        );
        expect(
          _indexOf(shell, 'message == taskbar_created_'),
          lessThan(_indexOf(shell, 'case WM_CLOSE:')),
        );
      });

      test('the icon is added, versioned and deleted', () {
        expect(tray, contains('NIM_ADD'));
        expect(tray, contains('NIM_SETVERSION'));
        expect(tray, contains('NOTIFYICON_VERSION_4'));
        expect(tray, contains('NIM_DELETE'));
        expect(
          _indexOf(tray, 'NIM_ADD'),
          lessThan(_indexOf(tray, 'NIM_SETVERSION')),
        );
      });

      test('the icon carries the tooltip and follows the system scale', () {
        final add = _functionBody(tray, 'bool TrayIcon::Add(');
        expect(add, contains('NIF_TIP'));
        expect(add, contains('NIF_SHOWTIP'));
        expect(add, contains('NIF_MESSAGE'));
        expect(tray, contains('GetDpiForSystem()'));
        expect(_caseBlock(shell, 'WM_SETTINGCHANGE'), contains('RefreshIcon'));
        expect(shell, contains('case WM_DPICHANGED:'));
      });

      test('a click, a double click and the keyboard open the window and '
          'that path never hides it', () {
        final block = _caseBlock(shell, 'WM_LBUTTONDBLCLK');
        expect(shell, contains('case NIN_SELECT:'));
        expect(shell, contains('case NIN_KEYSELECT:'));
        expect(block, contains('ShowAndActivate();'));
        final fallThrough = shell.substring(
          _indexOf(shell, 'case NIN_SELECT:'),
          _indexOf(shell, 'case WM_LBUTTONDBLCLK:'),
        );
        expect(fallThrough, isNot(contains('break')));
        final body = _functionBody(
          shell,
          'void FlutterWindow::ShowAndActivate(',
        );
        expect(body, isNot(contains('SW_HIDE')));
        expect(body, contains('IsWindowVisible'));
        expect(body, contains('SW_SHOW'));
        expect(body, contains('SW_RESTORE'));
        expect(_count(body, 'SetForegroundWindow('), 1);
        expect(block, isNot(contains('SW_HIDE')));
      });

      test('SW_HIDE only exists in the hide method', () {
        expect(_count(shell, 'SW_HIDE'), 1);
        final hide = _indexOf(shell, 'method == "hide"');
        final show = _indexOf(shell, 'method == "show"');
        final at = _indexOf(shell, 'SW_HIDE');
        expect(at, greaterThan(hide));
        expect(at, lessThan(show));
      });

      test('the context menu goes to the foreground, tracks and posts '
          'WM_NULL', () {
        expect(_caseBlock(shell, 'WM_CONTEXTMENU'), contains('ShowTrayMenu('));
        final body = _functionBody(shell, 'void FlutterWindow::ShowTrayMenu(');
        final front = _indexOf(body, 'SetForegroundWindow(hwnd)');
        final track = _indexOf(body, 'TrackPopupMenuEx(');
        final post = _indexOf(body, 'PostMessage(hwnd, WM_NULL, 0, 0)');
        expect(front, lessThan(track));
        expect(track, lessThan(post));
      });

      test('a session end removes the icon', () {
        expect(_caseBlock(shell, 'WM_ENDSESSION'), contains('tray_.Remove()'));
      });

      test('main.cpp shows a hidden window before bringing it forward', () {
        final block = _earlyExit(source);
        final visible = _indexOf(block, 'if (!::IsWindowVisible(w))');
        final show = _indexOf(block, '::ShowWindow(w, SW_SHOW);', visible);
        final front = _indexOf(block, '::SetForegroundWindow(w);', show);
        expect(front, greaterThan(show));
      });

      test('the new C++ has no comments', () {
        expect(trayRaw, isNot(contains('//')));
        expect(trayRaw, isNot(contains('/*')));
        expect(trayHeaderRaw, isNot(contains('//')));
        expect(trayHeaderRaw, isNot(contains('/*')));
        for (final name in const [
          'void FlutterWindow::ShowTrayMenu(',
          'void FlutterWindow::ShowAndActivate(',
          'bool FlutterWindow::BringForAttention(',
          'bool FlutterWindow::HandleShellCall(',
          'void FlutterWindow::ReportTrayVisibility(',
        ]) {
          expect(_functionBody(shellRaw, name), isNot(contains('//')));
        }
      });

      test('the C++ has no texts of its own', () {
        final wide = RegExp(r'L"[^"]*"');
        expect(wide.hasMatch(tray), isFalse);
        expect(wide.hasMatch(trayHeaderRaw), isFalse);
        expect(wide.allMatches(shell).map((match) => match.group(0)), [
          'L"TaskbarCreated"',
        ]);
      });

      test('the build knows the new file and its library', () {
        final cmake = File(_cmakePath).readAsStringSync();
        expect(cmake, contains('"tray_icon.cpp"'));
        expect(cmake, contains('"shell32.lib"'));
      });
    });

    group('E887 the retries of the icon (RF-522)', () {
      test('every 2 s up to 5 times', () {
        expect(shell, contains('kTrayRetryInterval = 2000;'));
        expect(shell, contains('kTrayMaxRetries = 5;'));
        final start = _functionBody(
          shell,
          'void FlutterWindow::StartTrayRetry(',
        );
        expect(start, contains('tray_retries_ = 0;'));
        expect(start, contains('SetTimer('));
        expect(start, contains('kTrayRetryInterval'));
      });

      test('the timer retries, stops and reports the change', () {
        final block = _caseBlock(shell, 'WM_TIMER');
        expect(block, contains('kTrayRetryTimer'));
        expect(block, contains('++tray_retries_'));
        expect(block, contains('AddTrayIcon()'));
        expect(block, contains('tray_retries_ >= kTrayMaxRetries'));
        expect(block, contains('StopTrayRetry()'));
        expect(block, contains('ReportTrayVisibility()'));
      });

      test('setTray starts them when the icon does not go in, and answers '
          'with what is visible', () {
        final call = shell.substring(
          _indexOf(shell, 'method == "setTray"'),
          _indexOf(shell, 'method == "showTrayHint"'),
        );
        expect(call, contains('if (!AddTrayIcon())'));
        expect(call, contains('StartTrayRetry();'));
        expect(call, contains('tray_.Remove();'));
        expect(
          call,
          contains('result->Success(flutter::EncodableValue(tray_.visible()))'),
        );
      });

      test('a failed NIM_ADD tries NIM_MODIFY before giving up', () {
        final add = _functionBody(tray, 'bool TrayIcon::Add(');
        expect(_indexOf(add, 'NIM_ADD'), lessThan(_indexOf(add, 'NIM_MODIFY')));
      });

      test('a change is reported once, with the event of the plan', () {
        final body = _functionBody(
          shell,
          'void FlutterWindow::ReportTrayVisibility(',
        );
        expect(body, contains('visible == tray_visible_reported_'));
        expect(body, contains('"trayVisibility"'));
        expect(body, contains('"visible"'));
      });

      test('minimize minimizes', () {
        final call = shell.substring(
          _indexOf(shell, 'method == "minimize"'),
          _indexOf(shell, 'method == "attention"'),
        );
        expect(call, contains('SW_MINIMIZE'));
      });
    });

    group('E889 menu, session end, quit and second instance (RF-525 to '
        'RF-527)', () {
      test('the menu uses the texts of Dart', () {
        final body = _functionBody(shell, 'void FlutterWindow::ShowTrayMenu(');
        expect(body, contains('tray_open_.c_str()'));
        expect(body, contains('tray_exit_.c_str()'));
        expect(body, contains('ShowAndActivate();'));
        expect(body, contains('SendEvent("exitRequested");'));
        expect(body, contains('DestroyMenu(menu)'));
      });

      test('WM_QUERYENDSESSION accepts the Restart Manager', () {
        final block = _caseBlock(shell, 'WM_QUERYENDSESSION');
        expect(block, contains('ENDSESSION_CLOSEAPP'));
        expect(block, contains('return TRUE;'));
      });

      test('WM_ENDSESSION from the Restart Manager goes through the ordered '
          'exit and keeps the icon', () {
        final block = _caseBlock(shell, 'WM_ENDSESSION');
        final closeApp = _indexOf(block, 'ENDSESSION_CLOSEAPP');
        final event = _indexOf(block, 'SendEvent("exitRequested");');
        final leave = _indexOf(block, 'return 0;', event);
        final remove = _indexOf(block, 'tray_.Remove()');
        expect(closeApp, lessThan(event));
        expect(leave, lessThan(remove));
      });

      test('WM_ENDSESSION looks at wparam first', () {
        final block = _caseBlock(shell, 'WM_ENDSESSION');
        expect(
          _indexOf(block, 'wparam != 0'),
          lessThan(_indexOf(block, 'ENDSESSION_CLOSEAPP')),
        );
      });

      test('quit posts kQuitMessage, which removes the icon first', () {
        final call = shell.substring(_indexOf(shell, 'method == "quit"'));
        expect(call, contains('attached_ = false;'));
        expect(call, contains('PostMessage(hwnd, kQuitMessage, 0, 0)'));
        final block = _caseBlock(shell, 'kQuitMessage');
        expect(
          _indexOf(block, 'tray_.Remove()'),
          lessThan(_indexOf(block, 'DestroyWindow(hwnd)')),
        );
      });

      test('the window destruction removes the icon and stops the timer', () {
        final body = _functionBody(shell, 'void FlutterWindow::OnDestroy(');
        expect(body, contains('StopTrayRetry();'));
        expect(body, contains('tray_.Remove();'));
        expect(body, contains('attached_ = false;'));
      });

      test('main.cpp uses two ifs, no else if', () {
        final block = _earlyExit(source);
        final visible = _indexOf(block, 'IsWindowVisible');
        final iconic = _indexOf(block, 'IsIconic', visible);
        expect(block.substring(visible, iconic), isNot(contains('else')));
      });
    });

    group('E892 attention respects the foreground lock (RF-529)', () {
      late String attention;

      setUpAll(() {
        attention = _functionBody(
          shell,
          'bool FlutterWindow::BringForAttention(',
        );
      });

      test('it shows without activating', () {
        expect(attention, contains('::ShowWindow(hwnd, SW_SHOWNA);'));
        expect(attention, contains('::ShowWindow(hwnd, SW_SHOWNOACTIVATE);'));
        expect(attention, isNot(contains('SW_RESTORE')));
        expect(attention, isNot(contains(RegExp(r'SW_SHOW\b'))));
      });

      test('it asks once and uses the answer of Windows', () {
        expect(_count(attention, 'SetForegroundWindow('), 1);
        expect(
          attention,
          contains('foreground = ::SetForegroundWindow(hwnd) != FALSE;'),
        );
        expect(_count(shell, 'GetForegroundWindow'), 1);
        expect(attention, contains('::GetForegroundWindow() == hwnd) {'));
      });

      test('if refused, the taskbar button flashes until activated', () {
        expect(attention, contains('if (!foreground)'));
        expect(attention, contains('FLASHW_TRAY | FLASHW_TIMERNOFG'));
        expect(attention, contains('::FlashWindowEx(&flash);'));
      });

      test('the method answers with foreground', () {
        final call = shell.substring(
          _indexOf(shell, 'method == "attention"'),
          _indexOf(shell, 'method == "quit"'),
        );
        expect(call, contains('"foreground"'));
        expect(call, contains('BringForAttention()'));
      });

      test('only attention and the two user actions touch the foreground', () {
        expect(_count(shell, 'SetForegroundWindow('), 3);
      });

      test('no runner file contains a trick against the lock', () {
        const banned = [
          'AttachThreadInput',
          'keybd_event',
          'SendInput',
          'SwitchToThisWindow',
          'LockSetForegroundWindow',
          'AllowSetForegroundWindow',
          'SPI_SETFOREGROUNDLOCKTIMEOUT',
          'HWND_TOPMOST',
          'BringWindowToTop',
        ];
        final files = Directory('windows/runner')
            .listSync()
            .whereType<File>()
            .where((file) => RegExp(r'\.(cpp|h)$').hasMatch(file.path));
        expect(files, isNotEmpty);
        for (final file in files) {
          final text = file.readAsStringSync();
          for (final word in banned) {
            expect(text, isNot(contains(word)), reason: file.path);
          }
        }
      });
    });
  });
}
