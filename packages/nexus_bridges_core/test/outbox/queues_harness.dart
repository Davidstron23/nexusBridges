import 'dart:async';
import 'dart:io';

import 'package:nexus_bridges_core/src/outbox/outbox.dart';
import 'package:nexus_bridges_core/src/transfer/transfer.dart'
    show
        SendDestination,
        SendTarget,
        TransferDirection,
        TransferOutcome,
        TransferResultView;
import 'package:nexus_bridges_core/src/transport/transport.dart'
    show AbortSignal;
import 'package:test/test.dart';

const String peerB = 'fp-b';
const String peerC = 'fp-c';

SendTarget targetFor(String fingerprint, {int port = 53530}) => SendTarget(
  fingerprint: fingerprint,
  address: InternetAddress.loopbackIPv4,
  port: port,
  interfaceId: 'eth0',
  localAddress: InternetAddress.loopbackIPv4,
);

ElementProbe file([int size = 0]) =>
    ElementProbe(kind: ElementKind.file, size: size);

const ElementProbe folder = ElementProbe(kind: ElementKind.folder);

const ElementProbe missing = ElementProbe(kind: ElementKind.missing);

const ElementProbe other = ElementProbe(kind: ElementKind.other);

TransferResultView resultOf(
  TransferOutcome outcome, {
  int size = 0,
  String? problemPath,
}) => TransferResultView(
  direction: TransferDirection.outgoing,
  peerFingerprint: peerB,
  peerName: 'B',
  fileName: 'x',
  isProgram: false,
  outcome: outcome,
  canReveal: false,
  problemPath: problemPath,
  size: size,
);

final class FakeSender implements ElementSender {
  final List<String> paths = [];
  final List<SendTarget> targets = [];
  final List<SendDestination> destinations = [];
  Completer<TransferResultView?>? _current;
  int cancels = 0;
  int inFlight = 0;
  int maxInFlight = 0;
  bool throwSynchronously = false;
  bool throwOnCancel = false;

  bool get busy => _current != null;

  @override
  Future<TransferResultView?> send(
    SendTarget target,
    String path,
    SendDestination destination,
  ) {
    paths.add(path);
    targets.add(target);
    destinations.add(destination);
    if (throwSynchronously) {
      throw StateError(r'send exploded on C:\in\secret');
    }
    final completer = Completer<TransferResultView?>();
    _current = completer;
    inFlight++;
    if (inFlight > maxInFlight) maxInFlight = inFlight;
    return completer.future.whenComplete(() => inFlight--);
  }

  @override
  void cancelCurrent() {
    cancels++;
    if (throwOnCancel) throw StateError('cancel exploded');
  }

  Completer<TransferResultView?> _take() {
    final completer = _current;
    if (completer == null) fail('no send in progress');
    _current = null;
    return completer;
  }

  void finish(TransferOutcome outcome, {int size = 0, String? problemPath}) {
    _take().complete(resultOf(outcome, size: size, problemPath: problemPath));
  }

  void finishWithNull() => _take().complete(null);

  void finishWithError() =>
      _take().completeError(StateError(r'failed on C:\in\secret'));
}

final class MeasureCall {
  MeasureCall(this.path, this.abort, this.completer);

  final String path;
  final AbortSignal abort;
  final Completer<int?> completer;

  void complete(int? size) {
    if (!completer.isCompleted) completer.complete(size);
  }

  void fail() {
    if (!completer.isCompleted) {
      completer.completeError(StateError(r'measure failed on C:\in\secret'));
    }
  }
}

final class FakeMeasure {
  final List<MeasureCall> calls = [];

  List<String> get paths => [for (final call in calls) call.path];

  Future<int?> call(String path, AbortSignal abort) {
    final completer = Completer<int?>();
    final call = MeasureCall(path, abort, completer);
    calls.add(call);
    abort.onAbort(() => call.complete(null));
    return completer.future;
  }
}

final class Harness {
  Harness({
    Map<String, ElementProbe>? probes,
    Duration gap = Duration.zero,
    this.throwingProbes = const {},
  }) : probes = probes ?? {} {
    queues = SendQueues(
      sender: sender,
      probe: _probe,
      measureFolder: measure.call,
      gap: gap,
      log: logs.add,
    );
    _subscription = queues.changes.listen((_) => changes++);
  }

  final Map<String, ElementProbe> probes;
  final Set<String> throwingProbes;
  final FakeSender sender = FakeSender();
  final FakeMeasure measure = FakeMeasure();
  final List<String> logs = [];
  late final SendQueues queues;
  late final StreamSubscription<void> _subscription;
  final Map<String, SendTarget?> targets = {};
  int refreshes = 0;
  int changes = 0;
  bool throwOnRefresh = false;
  Completer<void>? probeGate;
  int probesStarted = 0;

  Future<ElementProbe> _probe(String path) async {
    probesStarted++;
    final gate = probeGate;
    if (gate != null) await gate.future;
    if (throwingProbes.contains(path)) {
      throw StateError('probe exploded on $path');
    }
    return probes[path] ?? missing;
  }

  SendTarget? Function() refreshFor(String fingerprint) => () {
    refreshes++;
    if (throwOnRefresh) throw StateError('refresh exploded');
    return targets.containsKey(fingerprint)
        ? targets[fingerprint]
        : targetFor(fingerprint);
  };

  Future<SelectionResult> submit(
    List<String> paths, {
    String fingerprint = peerB,
    String? peerName = 'B',
  }) => queues.submit(
    fingerprint,
    paths,
    refresh: refreshFor(fingerprint),
    peerName: peerName,
  );

  SendQueuesView get view {
    final current = queues.view;
    if (current == null) fail('there is no queues view');
    return current;
  }

  List<String> get looseNames => [for (final item in view.loose) item.name];

  List<String> get bundleNames => [for (final item in view.bundles) item.name];

  QueueItemView item(String name) {
    for (final item in [...view.loose, ...view.bundles]) {
      if (item.name == name) return item;
    }
    fail('no item named $name');
  }

  Future<void> dispose() async {
    await _subscription.cancel();
  }
}

Future<void> until(bool Function() condition, {String? reason}) async {
  for (var i = 0; i < 2000; i++) {
    if (condition()) return;
    await Future<void>.delayed(Duration.zero);
  }
  fail('condition not reached${reason == null ? '' : ': $reason'}');
}

Future<void> settle() => pumpEventQueue(times: 50);
