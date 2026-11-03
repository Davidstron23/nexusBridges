import 'dart:async';
import 'dart:ffi';
import 'dart:isolate';

import 'package:ffi/ffi.dart';

import '../protocol/protocol.dart' show Limits;
import '../transport/transport.dart' show AbortSignal;
import 'folder_walk.dart' show measureFolders;
import 'names.dart' show isAppReservedName, isDriveRoot, isValidFileName;
import 'transfer.dart' show defaultExclusions;
import 'windows_file_system.dart' show WindowsFileSystemPlatform;
import 'windows_folder_io.dart' show WindowsFolderLister;

const int _failed = -1;

final class _SizeRequest {
  const _SizeRequest({
    required this.path,
    required this.exclusions,
    required this.port,
    required this.flagAddress,
  });

  final String path;
  final List<String> exclusions;
  final SendPort port;
  final int flagAddress;
}

void _sizeMain(_SizeRequest request) {
  final flag = Pointer<Uint8>.fromAddress(request.flagAddress);
  final clock = Stopwatch()..start();
  final skipped = request.exclusions.map((name) => name.toUpperCase()).toSet();
  int bytes;
  try {
    bytes = measureFolders(
      lister: const WindowsFolderLister(),
      roots: [request.path],
      elapsed: () => clock.elapsed,
      isCancelled: () => flag.value != 0,
      skipFolder: (name) =>
          isAppReservedName(name) || skipped.contains(name.toUpperCase()),
    ).bytes;
  } catch (_) {
    bytes = _failed;
  }
  Isolate.exit(request.port, bytes);
}

List<String> _effectiveExclusions(List<String>? loaded) {
  if (loaded != null && loaded.length <= 64 && loaded.every(isValidFileName)) {
    return List<String>.of(loaded);
  }
  return defaultExclusions;
}

final class _SizeJob {
  _SizeJob(this._abort) : _port = ReceivePort(), _flag = calloc<Uint8>();

  final AbortSignal _abort;
  final ReceivePort _port;
  final Pointer<Uint8> _flag;
  final Completer<int?> _result = Completer<int?>();
  Isolate? _isolate;
  Timer? _killTimer;
  void Function()? _unsubscribe;
  bool _released = false;

  Future<int?> run(String path, List<String> exclusions) {
    _port.listen(_onMessage);
    _unsubscribe = _abort.onAbort(_onAbort);
    Isolate.spawn(
      _sizeMain,
      _SizeRequest(
        path: path,
        exclusions: exclusions,
        port: _port.sendPort,
        flagAddress: _flag.address,
      ),
      onExit: _port.sendPort,
    ).then(
      (isolate) {
        _isolate = isolate;
        if (_abort.aborted) _scheduleKill();
      },
      onError: (Object _) {
        _finish(null);
        _release();
      },
    );
    return _result.future;
  }

  void _onMessage(Object? message) {
    if (message is int) {
      _finish(message == _failed ? null : message);
    } else if (message == null) {
      _finish(null);
      _release();
    }
  }

  void _onAbort() {
    if (_released) return;
    _flag.value = 1;
    _finish(null);
    if (_isolate != null) _scheduleKill();
  }

  void _scheduleKill() {
    _killTimer ??= Timer(Limits.workerStopGrace, () {
      _isolate?.kill(priority: Isolate.immediate);
    });
  }

  void _finish(int? value) {
    if (!_result.isCompleted) _result.complete(value);
  }

  void _release() {
    if (_released) return;
    _released = true;
    _unsubscribe?.call();
    _killTimer?.cancel();
    _port.close();
    calloc.free(_flag);
  }
}

Future<int?> measureFolderSize(
  String path, {
  required List<String>? exclusions,
  required AbortSignal abort,
}) async {
  if (abort.aborted) return null;
  final real = await const WindowsFileSystemPlatform().realPath(path);
  if (real == null || isDriveRoot(real) || abort.aborted) return null;
  return _SizeJob(abort).run(real, _effectiveExclusions(exclusions));
}
