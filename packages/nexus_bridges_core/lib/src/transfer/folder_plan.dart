import 'dart:async';
import 'dart:ffi';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

import '../protocol/protocol.dart' show Limits;
import 'folder_walk.dart' show walkFolder;
import 'manifest.dart' show FolderManifest, encodeManifest;
import 'names.dart' show isProgram, windowsExtension;
import 'transfer.dart' show FolderSummaryView, TransferOutcome;
import 'windows_folder_io.dart';

final class FolderPlan {
  const FolderPlan({
    required this.rootPath,
    required this.name,
    required this.manifest,
    required this.encoded,
    required this.summary,
    required this.fileVolumes,
    required this.fileIndexes,
  });

  final String rootPath;
  final String name;
  final FolderManifest manifest;
  final Uint8List encoded;
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
    required this.dataDirRealPath,
    required this.port,
    required this.flagAddress,
  });

  final String rootRealPath;
  final String name;
  final List<String> exclusions;
  final String dataDirRealPath;
  final SendPort port;
  final int flagAddress;
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

  final walk = walkFolder(
    lister: const WindowsFolderLister(),
    rootPath: request.rootRealPath,
    exclusions: request.exclusions.map((name) => name.toUpperCase()).toSet(),
    dataDirRealPath: request.dataDirRealPath,
    isCancelled: cancelled,
    onProgress: report,
  );
  if (walk.cancelled) return const PlanCancelled();
  final stopped = walk.stopped;
  if (stopped != null) return PlanStopped(stopped, walk.problemPath);

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
      );
      switch (result) {
        case FileHashCancelled():
          return const PlanCancelled();
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
  final encoded = encodeManifest(manifest);
  if (encoded.length > Limits.maxManifestBytes) {
    return const PlanStopped(TransferOutcome.tooManyEntries);
  }
  return PlanReady(
    FolderPlan(
      rootPath: request.rootRealPath,
      name: request.name,
      manifest: manifest,
      encoded: encoded,
      summary: FolderSummaryView(
        files: manifest.files,
        folders: manifest.folders,
        totalBytes: manifest.totalBytes,
        excludedFolders: walk.excludedFolders,
        excludedBytes: 0,
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
      _port = ReceivePort() {
    _port.listen(_onMessage);
  }

  final void Function(int entries, int hashed)? _onProgress;
  final Pointer<Uint8> _flag;
  final ReceivePort _port;
  final Completer<PlanResult> _result = Completer<PlanResult>();
  Isolate? _isolate;
  Timer? _killTimer;
  bool _cancelRequested = false;
  bool _released = false;

  static FolderPlanJob start({
    required String rootRealPath,
    required String name,
    List<String> exclusions = const [],
    String dataDirPath = '',
    String dataDirRealPath = '',
    void Function(int entries, int hashed)? onProgress,
  }) {
    final job = FolderPlanJob._(onProgress);
    final request = _PlanRequest(
      rootRealPath: rootRealPath,
      name: name,
      exclusions: List<String>.of(exclusions),
      dataDirRealPath: dataDirRealPath.isEmpty ? dataDirPath : dataDirRealPath,
      port: job._port.sendPort,
      flagAddress: job._flag.address,
    );
    job._launch(request);
    return job;
  }

  Future<PlanResult> get result => _result.future;

  void _launch(_PlanRequest request) {
    Isolate.spawn(_planMain, request, onExit: _port.sendPort).then(
      (isolate) {
        _isolate = isolate;
        if (_cancelRequested) _scheduleKill();
      },
      onError: (Object _) {
        _finish(const PlanStopped(TransferOutcome.unreadable));
        _release();
      },
    );
  }

  void cancel() {
    if (_released || _result.isCompleted) return;
    _cancelRequested = true;
    _flag.value = 1;
    if (_isolate != null) _scheduleKill();
  }

  void _scheduleKill() {
    _killTimer ??= Timer(Limits.workerStopGrace, () {
      _isolate?.kill(priority: Isolate.immediate);
      _finish(const PlanCancelled());
    });
  }

  void _onMessage(Object? message) {
    if (message is List<int>) {
      _onProgress?.call(message[0], message[1]);
    } else if (message is PlanResult) {
      _finish(message);
    } else if (message == null) {
      _finish(const PlanStopped(TransferOutcome.unreadable));
      _release();
    }
  }

  void _finish(PlanResult result) {
    _killTimer?.cancel();
    _killTimer = null;
    if (!_result.isCompleted) _result.complete(result);
  }

  void _release() {
    if (_released) return;
    _released = true;
    _killTimer?.cancel();
    _port.close();
    calloc.free(_flag);
  }
}
