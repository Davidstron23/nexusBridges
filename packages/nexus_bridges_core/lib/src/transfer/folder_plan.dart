import 'dart:async';
import 'dart:ffi';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

import '../protocol/protocol.dart' show Limits;
import 'folder_walk.dart' show FolderMeasure, measureFolders, walkFolder;
import 'manifest.dart' show FolderManifest, encodedManifestLength;
import 'names.dart' show isProgram, windowsExtension;
import 'transfer.dart' show FolderSummaryView, TransferOutcome;
import 'windows_folder_io.dart';

const Duration _cancelGrace = Duration(milliseconds: 500);

final class FolderPlan {
  const FolderPlan({
    required this.rootPath,
    required this.name,
    required this.manifest,
    required this.encodedLength,
    required this.summary,
    required this.fileVolumes,
    required this.fileIndexes,
  });

  final String rootPath;
  final String name;
  final FolderManifest manifest;
  final int encodedLength;
  final FolderSummaryView summary;
  final Uint32List fileVolumes;
  final Uint64List fileIndexes;
}

sealed class PlanResult {
  const PlanResult();
}

final class PlanReady extends PlanResult {
  const PlanReady(this.plan);

  final FolderPlan plan;
}

final class PlanStopped extends PlanResult {
  const PlanStopped(this.outcome, [this.problemPath]);

  final TransferOutcome outcome;
  final String? problemPath;
}

final class PlanCancelled extends PlanResult {
  const PlanCancelled();
}

final class _PlanRequest {
  const _PlanRequest({
    required this.rootRealPath,
    required this.name,
    required this.exclusions,
    required this.dataDirPath,
    required this.dataDirRealPath,
    required this.port,
    required this.flagAddress,
    required this.cancelSlot,
    required this.cancelMutex,
  });

  final int cancelSlot;
  final int cancelMutex;
  final String rootRealPath;
  final String name;
  final List<String> exclusions;
  final String dataDirPath;
  final String dataDirRealPath;
  final SendPort port;
  final int flagAddress;
}

final class _ExcludedFound {
  const _ExcludedFound(this.paths);

  final List<String> paths;
}

final class _MeasureRequest {
  const _MeasureRequest({
    required this.paths,
    required this.port,
    required this.flagAddress,
  });

  final List<String> paths;
  final SendPort port;
  final int flagAddress;
}

void _measureMain(_MeasureRequest request) {
  final flag = Pointer<Uint8>.fromAddress(request.flagAddress);
  final clock = Stopwatch()..start();
  FolderMeasure result;
  try {
    result = measureFolders(
      lister: const WindowsFolderLister(),
      roots: request.paths,
      elapsed: () => clock.elapsed,
      isCancelled: () => flag.value != 0,
    );
  } catch (_) {
    result = const FolderMeasure(bytes: 0, partial: true);
  }
  Isolate.exit(request.port, result);
}

String _join(String folder, String name) =>
    folder.endsWith(r'\') ? '$folder$name' : '$folder\\$name';

void _planMain(_PlanRequest request) {
  final flag = Pointer<Uint8>.fromAddress(request.flagAddress);
  PlanResult result;
  try {
    result = _runPlan(request, flag);
  } catch (_) {
    result = const PlanStopped(TransferOutcome.unreadable);
  }
  Isolate.exit(request.port, result);
}

PlanResult _runPlan(_PlanRequest request, Pointer<Uint8> flag) {
  bool cancelled() => flag.value != 0;
  final clock = Stopwatch()..start();
  var lastReport = Duration.zero;
  var hashed = 0;
  void report(int entries) {
    if (clock.elapsed - lastReport < Limits.transferProgressInterval) return;
    lastReport = clock.elapsed;
    request.port.send(<int>[entries, hashed]);
  }

  final dataScanPath = request.dataDirRealPath.isEmpty
      ? request.dataDirPath
      : request.dataDirRealPath;
  final protectedIds = dataScanPath.isEmpty
      ? const <(int, int)>{}
      : fileIdsUnder(dataScanPath, includeFolders: true);
  if (protectedIds == null) {
    return const PlanStopped(TransferOutcome.protectedData);
  }
  bool isProtected(int volume, int index) =>
      protectedIds.contains((volume, index));

  final walk = walkFolder(
    lister: const WindowsFolderLister(),
    rootPath: request.rootRealPath,
    exclusions: request.exclusions.map((name) => name.toUpperCase()).toSet(),
    dataDirRealPath: request.dataDirRealPath,
    isDataFolder: protectedIds.isEmpty
        ? null
        : (path) => pathHasIdentityIn(path, protectedIds),
    isCancelled: cancelled,
    onProgress: report,
  );
  if (walk.cancelled) return const PlanCancelled();
  final stopped = walk.stopped;
  if (stopped != null) return PlanStopped(stopped, walk.problemPath);
  if (walk.excludedPaths.isNotEmpty) {
    request.port.send(_ExcludedFound(List<String>.of(walk.excludedPaths)));
  }

  final builder = walk.builder;
  final volumes = <int>[];
  final indexes = <int>[];
  final dangerous = <String, bool>{};
  var programs = false;
  final buffer = allocateReadBuffer();
  try {
    for (var i = 1; i <= builder.length; i++) {
      if (!builder.isFile(i)) continue;
      if (cancelled()) return const PlanCancelled();
      final relative = builder.relativePath(i);
      final result = hashFileSync(
        _join(request.rootRealPath, relative),
        buffer: buffer,
        isCancelled: cancelled,
        isProtected: isProtected,
        cancelPort: ReadCancelPort(request.cancelSlot, request.cancelMutex),
      );
      switch (result) {
        case FileHashCancelled():
          return const PlanCancelled();
        case FileHashSkipped():
          builder.dropFile(i);
          walk.protectedOmitted++;
          continue;
        case FileHashFailed():
          return PlanStopped(TransferOutcome.unreadable, relative);
        case FileHashed(
          :final size,
          :final sha256,
          :final volume,
          :final index,
        ):
          builder.setFile(i, size, sha256);
          volumes.add(volume);
          indexes.add(index);
          hashed++;
      }
      if (!programs) {
        final name = builder.nameOf(i);
        if (isProgram(name)) {
          programs = true;
        } else {
          final extension = windowsExtension(name);
          if (extension != null) {
            final key = extension.toLowerCase();
            final known = dangerous[key];
            if (known != null) {
              programs = known;
            } else if (dangerous.length >= Limits.maxDangerousExtensions) {
              programs = true;
            } else {
              programs = dangerous[key] = isDangerousTypeSync(extension);
            }
          }
        }
      }
      report(builder.length);
    }
  } finally {
    freeReadBuffer(buffer);
  }
  final manifest = builder.build();
  final encodedLength = encodedManifestLength(manifest);
  if (encodedLength > Limits.maxManifestBytes) {
    return const PlanStopped(TransferOutcome.tooManyEntries);
  }
  return PlanReady(
    FolderPlan(
      rootPath: request.rootRealPath,
      name: request.name,
      manifest: manifest,
      encodedLength: encodedLength,
      summary: FolderSummaryView(
        files: manifest.files,
        folders: manifest.folders,
        totalBytes: manifest.totalBytes,
        excludedFolders: walk.excludedFolders,
        excludedBytes: 0,
        excludedBytesPartial: walk.excludedFolders > 0,
        linksOmitted: walk.linksOmitted,
        protectedOmitted: walk.protectedOmitted,
        blockedOmitted: walk.blockedOmitted,
        containsPrograms: programs,
      ),
      fileVolumes: Uint32List.fromList(volumes),
      fileIndexes: Uint64List.fromList(indexes),
    ),
  );
}

final class FolderPlanJob {
  FolderPlanJob._(this._onProgress)
    : _flag = calloc<Uint8>(),
      _gate = ReadCancelGate.create(),
      _port = ReceivePort() {
    _port.listen(_onMessage);
  }

  final void Function(int entries, int hashed)? _onProgress;
  final Pointer<Uint8> _flag;
  final ReadCancelGate _gate;
  final ReceivePort _port;
  Timer? _hardKillTimer;
  final Completer<PlanResult> _result = Completer<PlanResult>();
  final Completer<FolderMeasure> _excluded = Completer<FolderMeasure>();
  Isolate? _isolate;
  Timer? _killTimer;
  ReceivePort? _measurePort;
  Isolate? _measureIsolate;
  Timer? _measureKillTimer;
  bool _cancelRequested = false;
  bool _planExited = false;
  bool _measureActive = false;
  bool _released = false;

  static FolderPlanJob start({
    required String rootRealPath,
    required String name,
    required List<String> exclusions,
    required String dataDirPath,
    required String dataDirRealPath,
    required void Function(int entries, int hashed) onProgress,
  }) {
    final job = FolderPlanJob._(onProgress);
    final request = _PlanRequest(
      rootRealPath: rootRealPath,
      name: name,
      exclusions: List<String>.of(exclusions),
      dataDirPath: dataDirPath,
      dataDirRealPath: dataDirRealPath,
      port: job._port.sendPort,
      flagAddress: job._flag.address,
      cancelSlot: job._gate.slotAddress,
      cancelMutex: job._gate.mutexAddress,
    );
    job._launch(request);
    return job;
  }

  Future<PlanResult> get result => _result.future;

  Future<FolderMeasure> get excluded => _excluded.future;

  void _launch(_PlanRequest request) {
    Isolate.spawn(_planMain, request, onExit: _port.sendPort).then(
      (isolate) {
        _isolate = isolate;
        if (_cancelRequested) _scheduleKill();
      },
      onError: (Object _) {
        _planExited = true;
        _finish(const PlanStopped(TransferOutcome.unreadable));
        _maybeRelease();
      },
    );
  }

  void cancel() {
    if (_released) return;
    _cancelRequested = true;
    _flag.value = 1;
    if (!_result.isCompleted && _isolate != null) _scheduleKill();
    if (_measureActive && _measureIsolate != null) _scheduleMeasureKill();
  }

  void _scheduleKill() {
    _killTimer ??= Timer(Limits.workerStopGrace, () {
      _gate.cancelPending();
      _finish(const PlanCancelled());
      _hardKillTimer ??= Timer(_cancelGrace, () {
        _isolate?.kill(priority: Isolate.immediate);
      });
    });
  }

  void _scheduleMeasureKill() {
    _measureKillTimer ??= Timer(Limits.workerStopGrace, () {
      _measureIsolate?.kill(priority: Isolate.immediate);
    });
  }

  void _onMessage(Object? message) {
    if (message is List<int>) {
      _onProgress?.call(message[0], message[1]);
    } else if (message is _ExcludedFound) {
      _startMeasure(message.paths);
    } else if (message is PlanResult) {
      _finish(message);
    } else if (message == null) {
      _planExited = true;
      _finish(const PlanStopped(TransferOutcome.unreadable));
      _maybeRelease();
    }
  }

  void _startMeasure(List<String> paths) {
    if (_released || _measureActive) return;
    _measureActive = true;
    final port = ReceivePort();
    _measurePort = port;
    port.listen(_onMeasureMessage);
    Isolate.spawn(
      _measureMain,
      _MeasureRequest(
        paths: paths,
        port: port.sendPort,
        flagAddress: _flag.address,
      ),
      onExit: port.sendPort,
    ).then((isolate) {
      _measureIsolate = isolate;
      if (_cancelRequested || _flag.value != 0) _scheduleMeasureKill();
    }, onError: (Object _) => _onMeasureMessage(null));
  }

  void _onMeasureMessage(Object? message) {
    if (message is FolderMeasure) {
      if (!_excluded.isCompleted) _excluded.complete(message);
    } else if (message == null) {
      if (!_excluded.isCompleted) {
        _excluded.complete(const FolderMeasure(bytes: 0, partial: true));
      }
      _measureActive = false;
      _measureKillTimer?.cancel();
      _measureKillTimer = null;
      _measurePort?.close();
      _measurePort = null;
      _maybeRelease();
    }
  }

  void _finish(PlanResult result) {
    _killTimer?.cancel();
    _killTimer = null;
    if (!_result.isCompleted) {
      _result.complete(result);
      if (result is PlanReady) {
        if (result.plan.summary.excludedFolders == 0 &&
            !_excluded.isCompleted) {
          _excluded.complete(const FolderMeasure(bytes: 0, partial: false));
        }
      } else if (_measureActive) {
        _flag.value = 1;
        if (_measureIsolate != null) _scheduleMeasureKill();
      } else if (!_excluded.isCompleted) {
        _excluded.complete(const FolderMeasure(bytes: 0, partial: true));
      }
    }
  }

  void _maybeRelease() {
    if (_released || !_planExited || _measureActive) return;
    _released = true;
    _killTimer?.cancel();
    _hardKillTimer?.cancel();
    _measureKillTimer?.cancel();
    _port.close();
    calloc.free(_flag);
    _gate.dispose();
  }
}
