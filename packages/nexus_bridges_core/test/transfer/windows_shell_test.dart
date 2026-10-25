@TestOn('windows')
library;

import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';
import 'dart:math';

import 'package:ffi/ffi.dart';
import 'package:nexus_bridges_core/src/transfer/transfer.dart'
    show RevealResult;
import 'package:nexus_bridges_core/src/transfer/windows_shell.dart';
import 'package:test/test.dart';
import 'package:win32/win32.dart';

const Duration dialogAppearBudget = Duration(seconds: 10);

const Duration dialogCloseBudget = Duration(seconds: 10);

const Duration ownerLifetimeCap = Duration(seconds: 25);

final Random random = Random();

Future<Directory> tempFolder() async {
  final dir = await Directory.systemTemp.createTemp('nexus_t13_');
  addTearDown(() async {
    if (await dir.exists()) await dir.delete(recursive: true);
  });
  return dir;
}

HWND handleAt(int address) => HWND(Pointer.fromAddress(address));

String runOwnerWindow(String className, String title, SendPort ready) {
  return using((arena) {
    final instance = HINSTANCE(GetModuleHandle(null).value);
    final wndProc = DynamicLibrary.open('user32.dll')
        .lookup<NativeFunction<WNDPROC>>('DefWindowProcW');
    final windowClass = arena<WNDCLASS>();
    windowClass.ref
      ..lpfnWndProc = wndProc
      ..hInstance = instance
      ..lpszClassName = arena.pwstr(className);
    if (RegisterClass(windowClass).value == 0) {
      ready.send(<int>[0, 0]);
      return 'class not registered';
    }
    try {
      final hwnd = CreateWindowEx(
        WINDOW_EX_STYLE(0),
        arena.pcwstr(className),
        arena.pcwstr(title),
        WS_OVERLAPPEDWINDOW,
        0,
        0,
        320,
        240,
        null,
        null,
        instance,
        null,
      ).value;
      if (hwnd.address == 0) {
        ready.send(<int>[0, 0]);
        return 'window not created';
      }
      final timer = SetTimer(
        null,
        0,
        ownerLifetimeCap.inMilliseconds,
        null,
      ).value;
      try {
        ready.send(<int>[hwnd.address, GetCurrentThreadId()]);
        final msg = arena<MSG>();
        while (GetMessage(msg, null, 0, 0).value) {
          final message = msg.ref.message;
          if (message == WM_TIMER &&
              msg.ref.hwnd.address == 0 &&
              msg.ref.wParam == timer) {
            return 'lifetime cap reached';
          }
          if (!IsWindow(hwnd)) return 'window destroyed by message $message';
          TranslateMessage(msg);
          DispatchMessage(msg);
        }
        return 'quit';
      } finally {
        KillTimer(null, timer);
        if (IsWindow(hwnd)) DestroyWindow(hwnd);
      }
    } finally {
      UnregisterClass(arena.pcwstr(className), instance);
    }
  });
}

final class OwnerWindow {
  OwnerWindow._(
    this.className,
    this.title,
    this.hwnd,
    this.threadId,
    this._done,
  );

  final String className;
  final String title;
  final HWND hwnd;
  final int threadId;
  final Future<String> _done;
  String? exitReason;

  String describe() =>
      'owner alive: ${IsWindow(hwnd)}, enabled: ${IsWindowEnabled(hwnd)}, '
      'loop ended: ${exitReason ?? 'no'}';

  static Future<OwnerWindow> open() async {
    final tag = '${pid}_${random.nextInt(1 << 32).toRadixString(16)}';
    final className = 'NexusBridgesTestOwner_$tag';
    final title = 'NexusBridges test owner $tag';
    final ready = ReceivePort();
    final port = ready.sendPort;
    final done = Isolate.run(() => runOwnerWindow(className, title, port));
    final List<int> info;
    try {
      info =
          (await ready.first.timeout(const Duration(seconds: 10))) as List<int>;
    } finally {
      ready.close();
    }
    if (info[0] == 0) {
      await done;
      throw StateError('could not create the owner window');
    }
    final window = OwnerWindow._(
      className,
      title,
      handleAt(info[0]),
      info[1],
      done,
    );
    unawaited(done.then((reason) => window.exitReason = reason));
    return window;
  }

  Future<void> dispose() async {
    await closeOwnedDialogs(hwnd);
    PostThreadMessage(threadId, WM_QUIT, WPARAM(0), LPARAM(0));
    await _done.timeout(const Duration(seconds: 5), onTimeout: () => '');
  }
}

HWND? ownedDialog(HWND owner) {
  return using((arena) {
    final dialogClass = arena.pcwstr('#32770');
    HWND? after;
    for (var i = 0; i < 4096; i++) {
      final candidate = FindWindowEx(null, after, dialogClass, null).value;
      if (candidate.address == 0) break;
      if (GetWindow(candidate, GW_OWNER).value.address == owner.address) {
        return candidate;
      }
      after = candidate;
    }
    final popup = GetWindow(owner, GW_ENABLEDPOPUP).value;
    if (popup.address != 0 && popup.address != owner.address) return popup;
    return null;
  });
}

Future<void> closeOwnedDialogs(HWND owner) async {
  for (var i = 0; i < 40; i++) {
    final dialog = ownedDialog(owner);
    if (dialog == null) return;
    if (i.isEven) {
      PostMessage(dialog, WM_CLOSE, WPARAM(0), LPARAM(0));
    } else {
      PostMessage(dialog, WM_COMMAND, WPARAM(IDCANCEL), LPARAM(0));
    }
    await Future<void>.delayed(const Duration(milliseconds: 100));
  }
}

Future<HWND> waitForDialog(HWND owner, Future<String?> picking) async {
  var finished = false;
  unawaited(picking.whenComplete(() => finished = true));
  final clock = Stopwatch()..start();
  while (clock.elapsed < dialogAppearBudget) {
    final dialog = ownedDialog(owner);
    if (dialog != null) return dialog;
    if (finished) {
      fail('the picker returned before showing a dialog owned by the window');
    }
    await Future<void>.delayed(const Duration(milliseconds: 50));
  }
  fail('no dialog owned by the window appeared');
}

Future<String?> closeAndWait(HWND dialog, Future<String?> picking) async {
  PostMessage(dialog, WM_CLOSE, WPARAM(0), LPARAM(0));
  try {
    return await picking.timeout(const Duration(seconds: 2));
  } on TimeoutException {
    PostMessage(dialog, WM_COMMAND, WPARAM(IDCANCEL), LPARAM(0));
    return picking.timeout(dialogCloseBudget);
  }
}

Future<String> askLoopback(HttpClient client, int port) async {
  final request = await client.getUrl(Uri.parse('http://127.0.0.1:$port/ping'));
  final response = await request.close();
  return response.transform(utf8.decoder).join();
}

Set<int> explorerWindows() {
  return using((arena) {
    final explorerClass = arena.pcwstr('CabinetWClass');
    final found = <int>{};
    HWND? after;
    for (var i = 0; i < 4096; i++) {
      final window = FindWindowEx(null, after, explorerClass, null).value;
      if (window.address == 0) break;
      found.add(window.address);
      after = window;
    }
    return found;
  });
}

String? freeDriveLetter() {
  final used = GetLogicalDrives().value;
  for (final letter in 'ZYXWVUTSRQPONMLKJIHG'.split('')) {
    final bit = 1 << (letter.codeUnitAt(0) - 'A'.codeUnitAt(0));
    if (used & bit == 0) return letter;
  }
  return null;
}

void main() {
  group('revealPlanFor', () {
    test('an existing file is shown selected', () {
      expect(revealPlanFor(true, true), RevealResult.shown);
    });

    test('a missing file in an existing folder opens only the folder', () {
      expect(revealPlanFor(false, true), RevealResult.folderOnly);
    });

    test('nothing left gives unavailable', () {
      expect(revealPlanFor(false, false), RevealResult.unavailable);
    });

    test('the file decides even if the folder check failed', () {
      expect(revealPlanFor(true, false), RevealResult.shown);
    });
  });

  group('E171 real revealer with paths that do not exist', () {
    test(
      'a file inside a missing folder gives unavailable and opens nothing',
      () async {
        final dir = await tempFolder();
        final path = '${dir.path}\\absent_folder\\nested\\received.bin';
        final before = explorerWindows();
        final result = await const WindowsFolderRevealer().reveal(path);
        await Future<void>.delayed(const Duration(milliseconds: 700));
        expect(result, RevealResult.unavailable);
        expect(explorerWindows().difference(before), isEmpty);
        expect(Directory('${dir.path}\\absent_folder').existsSync(), isFalse);
      },
    );

    test('a drive that does not exist gives unavailable', () async {
      final letter = freeDriveLetter();
      if (letter == null) {
        markTestSkipped('every drive letter is in use');
        return;
      }
      final before = explorerWindows();
      final result = await const WindowsFolderRevealer().reveal(
        '$letter:\\nexus_missing\\received.bin',
      );
      await Future<void>.delayed(const Duration(milliseconds: 700));
      expect(result, RevealResult.unavailable);
      expect(explorerWindows().difference(before), isEmpty);
    });

    test('a path whose parent is a file gives unavailable', () async {
      final dir = await tempFolder();
      final blocker = File('${dir.path}\\blocker.txt');
      await blocker.writeAsString('not a folder');
      final before = explorerWindows();
      final result = await const WindowsFolderRevealer().reveal(
        '${blocker.path}\\received.bin',
      );
      await Future<void>.delayed(const Duration(milliseconds: 700));
      expect(result, RevealResult.unavailable);
      expect(explorerWindows().difference(before), isEmpty);
      expect(await blocker.readAsString(), 'not a folder');
    });

    test('several reveals in a row never throw', () async {
      final dir = await tempFolder();
      final results = await Future.wait([
        for (var i = 0; i < 4; i++)
          const WindowsFolderRevealer().reveal(
            '${dir.path}\\missing_$i\\file_$i.bin',
          ),
      ]);
      expect(results, everyElement(RevealResult.unavailable));
    });
  });

  group('revealer only accepts absolute Windows paths', () {
    const rejected = <String>[
      '',
      'x.txt',
      '..\\x.txt',
      '.\\x.txt',
      'C:/a/b.txt',
      'C:x.txt',
      'C:',
      '\\x.txt',
      '/x/y.txt',
      '\\\\?\\C:\\Windows\\win.ini',
      '\\\\?\\UNC\\server\\share\\file.txt',
      '\\\\.\\C:\\Windows\\win.ini',
      '\\\\srv',
      '\\\\srv\\',
      ' C:\\Windows\\win.ini',
    ];

    for (final path in rejected) {
      test('"$path" gives unavailable and opens nothing', () async {
        final before = explorerWindows();
        final result = await const WindowsFolderRevealer().reveal(path);
        await Future<void>.delayed(const Duration(milliseconds: 300));
        expect(result, RevealResult.unavailable);
        expect(explorerWindows().difference(before), isEmpty);
      });
    }

    test('all of them together never throw', () async {
      final before = explorerWindows();
      final results = await Future.wait([
        for (final path in rejected) const WindowsFolderRevealer().reveal(path),
      ]);
      await Future<void>.delayed(const Duration(milliseconds: 500));
      expect(results, everyElement(RevealResult.unavailable));
      expect(explorerWindows().difference(before), isEmpty);
    });
  });

  group('E153 modal pickers owned by a window of another thread', () {
    late OwnerWindow owner;
    late HttpServer server;
    late HttpClient client;

    setUp(() async {
      owner = await OwnerWindow.open();
      addTearDown(owner.dispose);
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      server.listen((request) {
        request.response.write('pong');
        request.response.close();
      });
      client = HttpClient();
      addTearDown(() => client.close(force: true));
    });

    test('pickFolder disables the owner, the main isolate keeps serving, '
        'and closing gives null and enables the owner again', () async {
      final dir = await tempFolder();
      addTearDown(() => closeOwnedDialogs(owner.hwnd));
      var ticks = 0;
      final timer = Timer.periodic(
        const Duration(milliseconds: 100),
        (_) => ticks++,
      );
      addTearDown(timer.cancel);
      expect(IsWindowEnabled(owner.hwnd), isTrue, reason: owner.describe());
      final picker = WindowsFilePicker(
        ownerWindowClass: owner.className,
        ownerWindowTitle: owner.title,
      );
      final picking = picker.pickFolder(startIn: dir.path);
      final dialog = await waitForDialog(owner.hwnd, picking);
      expect(IsWindow(owner.hwnd), isTrue, reason: owner.describe());
      expect(IsWindowEnabled(owner.hwnd), isFalse);
      final ticksAtOpen = ticks;
      final reply = await askLoopback(
        client,
        server.port,
      ).timeout(const Duration(seconds: 3));
      await Future<void>.delayed(const Duration(milliseconds: 500));
      expect(reply, 'pong');
      expect(ticks - ticksAtOpen, greaterThanOrEqualTo(3));
      expect(IsWindow(dialog), isTrue);
      expect(IsWindow(owner.hwnd), isTrue, reason: owner.describe());
      expect(IsWindowEnabled(owner.hwnd), isFalse);
      final chosen = await closeAndWait(dialog, picking);
      expect(chosen, isNull);
      expect(IsWindowEnabled(owner.hwnd), isTrue, reason: owner.describe());
      expect(ownedDialog(owner.hwnd), isNull);
    }, timeout: const Timeout(Duration(seconds: 40)));

    test(
      'pickFile finds its owner by class alone and cancelling gives null',
      () async {
        addTearDown(() => closeOwnedDialogs(owner.hwnd));
        expect(IsWindowEnabled(owner.hwnd), isTrue, reason: owner.describe());
        final picker = WindowsFilePicker(
          ownerWindowClass: owner.className,
          ownerWindowTitle: '',
        );
        final picking = picker.pickFile();
        final dialog = await waitForDialog(owner.hwnd, picking);
        expect(IsWindow(owner.hwnd), isTrue, reason: owner.describe());
        expect(IsWindowEnabled(owner.hwnd), isFalse);
        final reply = await askLoopback(
          client,
          server.port,
        ).timeout(const Duration(seconds: 3));
        expect(reply, 'pong');
        expect(IsWindow(dialog), isTrue);
        final chosen = await closeAndWait(dialog, picking);
        expect(chosen, isNull);
        expect(IsWindowEnabled(owner.hwnd), isTrue, reason: owner.describe());
        expect(ownedDialog(owner.hwnd), isNull);
      },
      timeout: const Timeout(Duration(seconds: 40)),
    );
  });

  group('revealer that opens Explorer (manual)', () {
    test('an existing file is shown selected in its folder', () async {
      final dir = await tempFolder();
      final file = File('${dir.path}\\received.txt');
      await file.writeAsString('hello');
      final result = await const WindowsFolderRevealer().reveal(file.path);
      expect(result, RevealResult.shown);
      expect(await file.readAsString(), 'hello');
      await Future<void>.delayed(const Duration(seconds: 5));
    }, tags: ['manual']);

    test(
      'a missing file in an existing folder opens only the folder',
      () async {
        final dir = await tempFolder();
        final result = await const WindowsFolderRevealer().reveal(
          '${dir.path}\\gone.txt',
        );
        expect(result, RevealResult.folderOnly);
        await Future<void>.delayed(const Duration(seconds: 5));
      },
      tags: ['manual'],
    );
  });
}
