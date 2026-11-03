import 'dart:async';

import '../protocol/protocol.dart' show Limits;
import '../transfer/transfer.dart'
    show
        AbortSignal,
        ReceiveFolderDestination,
        SendDestination,
        SendTarget,
        TransferOutcome,
        TransferResultView,
        visibleFileName;
import 'path_key.dart';
import 'policy.dart';
import 'selection.dart';

void _noLog(String message) {}

enum _Mode { none, single, queues }

final class _Item {
  _Item({
    required this.id,
    required this.path,
    required this.name,
    required this.isFolder,
    required this.isArchive,
    required this.isMeasurable,
    required this.isBundle,
    required this.probeSize,
    required this.destination,
  }) : key = pathKey(path);

  final String id;
  final String path;
  final String key;
  final String name;
  final bool isFolder;
  final bool isArchive;
  final bool isMeasurable;
  final bool isBundle;
  final int? probeSize;
  final SendDestination destination;

  QueueItemState state = QueueItemState.pending;
  TransferOutcome? outcome;
  String? problemPath;
  int resultSize = 0;
  int? measuredSize;
  bool measureTried = false;
  bool cancelEndsQueue = false;
  AbortSignal? measureAbort;

  bool get isFinished =>
      state == QueueItemState.done || state == QueueItemState.notSent;

  int get finishedBytes => resultSize > 0 ? resultSize : (probeSize ?? 0);

  int get pendingBytes => isFolder
      ? (measuredSize ?? Limits.queueFolderPlaceholderBytes)
      : (probeSize ?? 0);

  QueueItemView toView() => QueueItemView(
    id: id,
    name: name,
    isFolder: isFolder,
    isArchive: isArchive,
    state: state,
    outcome: outcome,
    problemPath: problemPath,
  );

  void stopMeasuring() {
    measureAbort?.abort();
    measureAbort = null;
  }
}

int _compareItems(_Item a, _Item b) {
  final byUpper = a.name.toUpperCase().compareTo(b.name.toUpperCase());
  if (byUpper != 0) return byUpper;
  final byName = a.name.compareTo(b.name);
  if (byName != 0) return byName;
  return a.path.compareTo(b.path);
}

final class SendQueues {
  SendQueues({
    required this._sender,
    required this._probe,
    required this._measureFolder,
    this._gap = Limits.queueElementGap,
    this._log = _noLog,
  });

  final ElementSender _sender;
  final Future<ElementProbe> Function(String path) _probe;
  final Future<int?> Function(String path, AbortSignal abort) _measureFolder;
  final Duration _gap;
  final void Function(String) _log;

  final StreamController<void> _changes = StreamController<void>.broadcast();
  final List<_Item> _loose = [];
  final List<_Item> _bundles = [];

  _Mode _mode = _Mode.none;
  String? _fingerprint;
  String? _peerName;
  SendTarget? Function() _refresh = _noTarget;
  int _selectionCounter = 0;
  int _itemCounter = 0;
  bool _pumpRunning = false;
  Future<void>? _pumpFuture;
  _Item? _current;
  bool _closed = false;
  Completer<void>? _gapWaiter;
  Future<void> _lock = Future<void>.value();
  bool _measuring = false;
  SendQueuesView? _previous;

  static SendTarget? _noTarget() => null;

  Stream<void> get changes => _changes.stream;

  bool get active => _pumpRunning;

  String? get target => _pumpRunning ? _fingerprint : null;

  int get selectionId => _selectionCounter;

  SendQueuesView? get previous => _pumpRunning ? _previous : null;

  SendQueuesView? get view {
    if (_mode != _Mode.queues) return null;
    final fingerprint = _fingerprint;
    if (fingerprint == null) return null;
    final all = [..._loose, ..._bundles];
    var delivered = 0;
    var completed = 0;
    var pendingKnown = 0;
    int? currentProbe;
    for (final item in all) {
      if (item.isFinished) {
        completed += item.finishedBytes;
        final outcome = item.outcome;
        if (item.state == QueueItemState.done &&
            (outcome == TransferOutcome.saved ||
                outcome == TransferOutcome.savedWithoutMark)) {
          delivered++;
        }
      } else if (item.state == QueueItemState.pending) {
        pendingKnown += item.pendingBytes;
      } else {
        currentProbe = item.isFolder ? item.measuredSize : item.probeSize;
      }
    }
    return SendQueuesView(
      selectionId: _selectionCounter,
      peerFingerprint: fingerprint,
      peerName: _peerName,
      loose: List.unmodifiable(_loose.map((item) => item.toView())),
      bundles: List.unmodifiable(_bundles.map((item) => item.toView())),
      finished: all.every((item) => item.isFinished),
      delivered: delivered,
      total: all.length,
      completedBytes: completed,
      pendingKnownBytes: pendingKnown,
      currentProbeSize: currentProbe,
    );
  }

  Future<SelectionResult> submit(
    String fingerprint,
    List<String> paths, {
    required SendTarget? Function() refresh,
    String? peerName,
    SendDestination destination = const ReceiveFolderDestination(),
  }) {
    if (paths.isEmpty) return Future.value(SelectionResult.empty);
    if (paths.length > Limits.maxSelectionItems) {
      return Future.value(SelectionResult.tooMany);
    }
    if (_closed) return Future.value(SelectionResult.closed);
    final copy = List<String>.of(paths);
    final run = _lock.then(
      (_) => _submit(fingerprint, copy, refresh, peerName, destination),
    );
    _lock = run.then((_) {}, onError: (Object _) {});
    return run;
  }

  Future<SelectionResult> _submit(
    String fingerprint,
    List<String> paths,
    SendTarget? Function() refresh,
    String? peerName,
    SendDestination destination,
  ) async {
    try {
      if (_closed) return SelectionResult.closed;
      if (_pumpRunning && _fingerprint != fingerprint) {
        return SelectionResult.otherTargetBusy;
      }
      final fresh = <_Item>[];
      final seen = <String>{};
      for (final path in paths) {
        if (!seen.add(pathKey(path))) continue;
        fresh.add(await _describe(path, destination));
        if (_closed) return SelectionResult.closed;
      }
      if (_pumpRunning) {
        final waiting = {
          for (final item in [..._loose, ..._bundles])
            if (item.state == QueueItemState.pending) item.key,
        };
        fresh.removeWhere((item) => waiting.contains(item.key));
      }
      final newLoose = fresh.where((item) => !item.isBundle).toList()
        ..sort(_compareItems);
      final newBundles = fresh.where((item) => item.isBundle).toList()
        ..sort(_compareItems);
      if (_pumpRunning) {
        if (fresh.isEmpty) return SelectionResult.queued;
        if (_mode == _Mode.single) _mode = _Mode.queues;
        _refresh = refresh;
        _peerName = peerName ?? _peerName;
        _loose.addAll(newLoose);
        _bundles.addAll(newBundles);
        _log(
          'queues: added ${newLoose.length} loose and '
          '${newBundles.length} bundles',
        );
        _emit();
        _kickMeasure();
        return SelectionResult.queued;
      }
      _previous = view;
      _clearAll();
      _fingerprint = fingerprint;
      _peerName = peerName;
      _refresh = refresh;
      _selectionCounter++;
      _loose.addAll(newLoose);
      _bundles.addAll(newBundles);
      _mode = fresh.length == 1 ? _Mode.single : _Mode.queues;
      _log(
        'queues: started ${newLoose.length} loose and '
        '${newBundles.length} bundles',
      );
      _startPump();
      _kickMeasure();
      return SelectionResult.started;
    } catch (_) {
      _log('queues: submit failed');
      return _closed ? SelectionResult.closed : SelectionResult.empty;
    }
  }

  Future<_Item> _describe(String path, SendDestination destination) async {
    ElementProbe probe;
    try {
      probe = await _probe(path);
    } catch (_) {
      probe = const ElementProbe(kind: ElementKind.other);
    }
    final rawName = baseNameOfPath(path);
    final isRoot = isDriveRootPath(path);
    final isFolder = probe.kind == ElementKind.folder || isRoot;
    final isArchive = isArchiveName(rawName);
    return _Item(
      id: 'q${++_itemCounter}',
      path: path,
      name: visibleFileName(rawName),
      isFolder: isFolder,
      isArchive: isArchive,
      isMeasurable: probe.kind == ElementKind.folder && !isRoot,
      isBundle: isFolder || isArchive,
      probeSize: probe.size,
      destination: destination,
    );
  }

  void cancelItem(String id) {
    final item = _find(id);
    if (item == null || item.state != QueueItemState.inProgress) return;
    item.cancelEndsQueue = item.cancelEndsQueue || _sender.cancelEndsQueue;
    _cancelCurrent();
  }

  void removeItem(String id) {
    final item = _find(id);
    if (item == null || item.state != QueueItemState.pending) return;
    item.stopMeasuring();
    _loose.remove(item);
    _bundles.remove(item);
    _emit();
  }

  void cancelAll() {
    if (_mode == _Mode.none) return;
    _stopPending(TransferOutcome.cancelledHere);
    if (_current != null) _cancelCurrent();
    _emit();
  }

  void stopFor(String fingerprint, TransferOutcome reason) {
    if (_mode == _Mode.none || _fingerprint != fingerprint) return;
    _stopPending(reason);
    _emit();
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    for (final list in [_loose, _bundles]) {
      list.removeWhere((item) {
        if (item.state != QueueItemState.pending) return false;
        item.stopMeasuring();
        return true;
      });
    }
    final waiter = _gapWaiter;
    if (waiter != null && !waiter.isCompleted) waiter.complete();
    _emit();
    final pump = _pumpFuture;
    if (pump != null && _current == null) await pump;
    await _changes.close();
  }

  _Item? _find(String id) {
    for (final item in _loose) {
      if (item.id == id) return item;
    }
    for (final item in _bundles) {
      if (item.id == id) return item;
    }
    return null;
  }

  _Item? _nextPending() {
    for (final item in _loose) {
      if (item.state == QueueItemState.pending) return item;
    }
    for (final item in _bundles) {
      if (item.state == QueueItemState.pending) return item;
    }
    return null;
  }

  void _cancelCurrent() {
    try {
      _sender.cancelCurrent();
    } catch (_) {
      _log('queues: cancel failed');
    }
  }

  void _stopPending(TransferOutcome reason) {
    for (final item in [..._loose, ..._bundles]) {
      if (item.state != QueueItemState.pending) continue;
      item.stopMeasuring();
      item.state = QueueItemState.notSent;
      item.outcome = reason;
    }
  }

  void _clearAll() {
    for (final item in [..._loose, ..._bundles]) {
      item.stopMeasuring();
    }
    _loose.clear();
    _bundles.clear();
    _mode = _Mode.none;
    _fingerprint = null;
    _peerName = null;
  }

  void _emit() {
    if (_changes.isClosed) return;
    _changes.add(null);
  }

  void _startPump() {
    _pumpRunning = true;
    _pumpFuture = _run();
  }

  Future<void> _run() async {
    try {
      while (!_closed) {
        final item = _nextPending();
        if (item == null) break;
        item.stopMeasuring();
        item.state = QueueItemState.inProgress;
        _current = item;
        _emit();
        final result = await _sendItem(item);
        _current = null;
        final outcome = result?.outcome ?? TransferOutcome.noContact;
        item.state = QueueItemState.done;
        item.outcome = outcome;
        item.problemPath = result?.problemPath;
        item.resultSize = result?.size ?? 0;
        _log('queues: element ended with ${outcome.name}');
        final stops =
            !continuesAfter(outcome) ||
            (item.cancelEndsQueue && outcome == TransferOutcome.cancelledHere);
        if (stops) _stopPending(outcome);
        _emit();
        if (_closed) break;
        if (!stops && _nextPending() != null) await _sleepGap();
      }
    } catch (_) {
      _log('queues: pump failed');
    }
    _current = null;
    _pumpRunning = false;
    if (_mode == _Mode.single) _clearAll();
    _emit();
  }

  Future<TransferResultView?> _sendItem(_Item item) async {
    try {
      final target = _refresh();
      if (target == null) return null;
      return await _sender.send(target, item.path, item.destination);
    } catch (_) {
      _log('queues: send failed');
      return null;
    }
  }

  Future<void> _sleepGap() async {
    final waiter = Completer<void>();
    _gapWaiter = waiter;
    final timer = Timer(_gap, () {
      if (!waiter.isCompleted) waiter.complete();
    });
    await waiter.future;
    timer.cancel();
    _gapWaiter = null;
  }

  _Item? _nextToMeasure() {
    for (final item in _bundles) {
      if (item.state == QueueItemState.pending &&
          item.isMeasurable &&
          !item.measureTried) {
        return item;
      }
    }
    return null;
  }

  void _kickMeasure() {
    if (_measuring || _closed || _nextToMeasure() == null) return;
    _measuring = true;
    unawaited(_measureLoop());
  }

  Future<void> _measureLoop() async {
    try {
      while (!_closed) {
        final item = _nextToMeasure();
        if (item == null) break;
        item.measureTried = true;
        final abort = AbortSignal();
        item.measureAbort = abort;
        int? size;
        try {
          size = await _measureFolder(item.path, abort);
        } catch (_) {
          size = null;
        }
        if (identical(item.measureAbort, abort)) item.measureAbort = null;
        if (_closed || abort.aborted) continue;
        if (size != null && item.state == QueueItemState.pending) {
          item.measuredSize = size;
          _emit();
        }
      }
    } finally {
      _measuring = false;
    }
  }
}
