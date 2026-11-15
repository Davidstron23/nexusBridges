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
const int _hashWorkers = 4;
const int _parallelHashMinFiles = 16;

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
    required this.workerSlots,
    required this.workerMutexes,
  });

  final int cancelSlot;
  final int cancelMutex;
  final List<int> workerSlots;
  final List<int> workerMutexes;
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

final class _HashedMore {
  const _HashedMore(this.count);

  final int count;
}

const String _workerExited = 'hash-worker-exited';

final class _WorkerStarted {
  const _WorkerStarted(this.isolate);

  final Isolate isolate;
}

final class _HashWorkerRequest {
  const _HashWorkerRequest({
    required this.indexes,
    required this.paths,
    required this.protectedIds,
    required this.flagAddress,
    required this.cancelSlot,
    required this.cancelMutex,
    required this.progressPort,
    required this.resultPort,
  });

  final List<int> indexes;
  final List<String> paths;
  final Set<(int, int)> protectedIds;
  final int flagAddress;
  final int cancelSlot;
  final int cancelMutex;
  final SendPort progressPort;
  final SendPort resultPort;
}

final class _HashWorkerResult {
  const _HashWorkerResult(this.indexes, this.results);

  final List<int> indexes;
  final List<FileHashResult> results;
}

void _hashWorkerMain(_HashWorkerRequest request) {
  final flag = Pointer<Uint8>.fromAddress(request.flagAddress);
  final results = <FileHashResult>[];
  final clock = Stopwatch()..start();
  var lastReport = Duration.zero;
  var pending = 0;
  final buffer = allocateReadBuffer();
  try {
    final cancelPort = ReadCancelPort(request.cancelSlot, request.cancelMutex);
    for (var k = 0; k < request.paths.length; k++) {
      if (flag.value != 0) {
        results.add(const FileHashCancelled());
        break;
      }
      final result = hashFileSync(
        request.paths[k],
        buffer: buffer,
        isCancelled: () => flag.value != 0,
        isProtected: (volume, index) =>
            request.protectedIds.contains((volume, index)),
        cancelPort: cancelPort,
      );
      results.add(result);
      if (result is FileHashed) {
        pending++;
        if (clock.elapsed - lastReport >= Limits.transferProgressInterval) {
          lastReport = clock.elapsed;
          request.progressPort.send(_HashedMore(pending));
          pending = 0;
        }
      } else if (result is! FileHashSkipped) {
        break;
      }
    }
  } catch (_) {
    results.add(const FileHashFailed());
  } finally {
    freeReadBuffer(buffer);
  }
  if (pending > 0) request.progressPort.send(_HashedMore(pending));
  Isolate.exit(request.resultPort, _HashWorkerResult(request.indexes, results));
}

Future<Map<int, FileHashResult>> _hashInParallel(
  _PlanRequest request,
  Pointer<Uint8> flag,
  List<int> fileIndexes,
  List<String> paths,
  Set<(int, int)> protectedIds,
) async {
  final workers = fileIndexes.length < _hashWorkers
      ? fileIndexes.length
      : _hashWorkers;
  final port = ReceivePort();
  final isolates = <Isolate>[];
  final byIndex = <int, FileHashResult>{};
  var received = 0;
  var exited = 0;
  try {
    for (var w = 0; w < workers; w++) {
      final indexes = <int>[];
      final workerPaths = <String>[];
      for (var k = w; k < fileIndexes.length; k += workers) {
        indexes.add(fileIndexes[k]);
        workerPaths.add(paths[k]);
      }
      final isolate = await Isolate.spawn(
        _hashWorkerMain,
        _HashWorkerRequest(
          indexes: indexes,
          paths: workerPaths,
          protectedIds: protectedIds,
          flagAddress: request.flagAddress,
          cancelSlot: request.workerSlots[w],
          cancelMutex: request.workerMutexes[w],
          progressPort: request.port,
          resultPort: port.sendPort,
        ),
        onExit: port.sendPort,
        paused: true,
      );
      isolates.add(isolate);
      request.port.send(_WorkerStarted(isolate));
      isolate.addOnExitListener(request.port, response: _workerExited);
      isolate.resume(isolate.pauseCapability!);
    }
    final done = Completer<void>();
    port.listen((message) {
      if (message is _HashWorkerResult) {
        received++;
        for (var k = 0; k < message.results.length; k++) {
          byIndex[message.indexes[k]] = message.results[k];
        }
      } else if (message == null) {
        exited++;
      }
      if ((received == workers || exited == workers) && !done.isCompleted) {
        done.complete();
      }
    });
    await done.future;
    return byIndex;
  } finally {
    port.close();
    for (final isolate in isolates) {
      isolate.kill(priority: Isolate.immediate);
    }
  }
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

Future<void> _planMain(_PlanRequest request) async {
  final flag = Pointer<Uint8>.fromAddress(request.flagAddress);
  PlanResult result;
  try {
    result = await _runPlan(request, flag);
  } catch (_) {
    result = const PlanStopped(TransferOutcome.unreadable);
  }
  Isolate.exit(request.port, result);
}

Future<PlanResult> _runPlan(_PlanRequest request, Pointer<Uint8> flag) async {
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
    classifyFolder: protectedIds.isEmpty
        ? null
        : (path) => folderKindAmong(path, protectedIds),
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
  final fileIndexes = <int>[
    for (var i = 1; i <= builder.length; i++)
      if (builder.isFile(i)) i,
  ];
  final parallel = fileIndexes.length >= _parallelHashMinFiles;
  final parallelResults = parallel
      ? await _hashInParallel(request, flag, fileIndexes, [
          for (final i in fileIndexes)
            _join(request.rootRealPath, builder.relativePath(i)),
        ], protectedIds)
      : null;
  final buffer = parallel ? nullptr : allocateReadBuffer();
  try {
    for (final i in fileIndexes) {
      if (cancelled()) return const PlanCancelled();
      final relative = builder.relativePath(i);
      final FileHashResult result;
      if (parallelResults == null) {
        result = hashFileSync(
          _join(request.rootRealPath, relative),
          buffer: buffer,
          isCancelled: cancelled,
          isProtected: isProtected,
          cancelPort: ReadCancelPort(request.cancelSlot, request.cancelMutex),
        );
      } else {
        result = parallelResults[i] ?? const FileHashFailed();
      }
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
          if (!parallel) hashed++;
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
    if (!parallel) freeReadBuffer(buffer);
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
      _workerGates = List<ReadCancelGate>.generate(
        _hashWorkers,
        (_) => ReadCancelGate.create(),
      ),
      _port = ReceivePort() {
    _port.listen(_onMessage);
  }

  final void Function(int entries, int hashed)? _onProgress;
  final Pointer<Uint8> _flag;
  final ReadCancelGate _gate;
  final List<ReadCancelGate> _workerGates;
  final ReceivePort _port;
  final List<Isolate> _workers = <Isolate>[];
  int _entries = 0;
  int _hashed = 0;
  int _workersStarted = 0;
  int _workersExited = 0;
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
      workerSlots: [for (final gate in job._workerGates) gate.slotAddress],
      workerMutexes: [for (final gate in job._workerGates) gate.mutexAddress],
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
      _cancelPending();
      _finish(const PlanCancelled());
      _hardKillTimer ??= Timer(_cancelGrace, () {
        _isolate?.kill(priority: Isolate.immediate);
        _killWorkers();
      });
    });
  }

  void _cancelPending() {
    _gate.cancelPending();
    for (final gate in _workerGates) {
      gate.cancelPending();
    }
  }

  void _killWorkers() {
    for (final worker in _workers) {
      worker.kill(priority: Isolate.immediate);
    }
  }

  void _scheduleMeasureKill() {
    _measureKillTimer ??= Timer(Limits.workerStopGrace, () {
      _measureIsolate?.kill(priority: Isolate.immediate);
    });
  }

  void _onMessage(Object? message) {
    if (message is List<int>) {
      _entries = message[0];
      if (message[1] > _hashed) _hashed = message[1];
      _onProgress?.call(_entries, _hashed);
    } else if (message is _HashedMore) {
      _hashed += message.count;
      _onProgress?.call(_entries, _hashed);
    } else if (message == _workerExited) {
      _workersExited++;
      _maybeRelease();
    } else if (message is _WorkerStarted) {
      _workers.add(message.isolate);
      _workersStarted++;
      if (_cancelRequested && _result.isCompleted) {
        message.isolate.kill(priority: Isolate.immediate);
      }
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
    if (_workersExited < _workersStarted) return;
    _released = true;
    _killTimer?.cancel();
    _hardKillTimer?.cancel();
    _measureKillTimer?.cancel();
    _port.close();
    _killWorkers();
    calloc.free(_flag);
    _gate.dispose();
    for (final gate in _workerGates) {
      gate.dispose();
    }
  }
}
