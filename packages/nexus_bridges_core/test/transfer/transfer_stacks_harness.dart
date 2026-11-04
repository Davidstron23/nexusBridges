import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:nexus_bridges_core/src/identity/identity.dart';
import 'package:nexus_bridges_core/src/network/network.dart';
import 'package:nexus_bridges_core/src/pairing/pairing.dart';
import 'package:nexus_bridges_core/src/protocol/protocol.dart';
import 'package:nexus_bridges_core/src/server/server.dart';
import 'package:nexus_bridges_core/src/storage/storage.dart';
import 'package:nexus_bridges_core/src/transfer/folder_writer.dart'
    show ClearHidden, MarkFile;
import 'package:nexus_bridges_core/src/transfer/platform.dart';
import 'package:nexus_bridges_core/src/transfer/transfer.dart';
import 'package:test/test.dart';

import '../server/api_server_harness.dart';
import 'receiver_harness.dart'
    show FakeClock, FakeFolderStore, TransferPlatform, eventually, realFs;

export 'receiver_harness.dart' show FakeClock, eventually, realFs, settle;

final InternetAddress hostA = InternetAddress('127.0.0.11');
final InternetAddress hostB = InternetAddress('127.0.0.12');
final InternetAddress hostC = InternetAddress('127.0.0.13');
final InternetAddress hostF = InternetAddress('127.0.0.14');

final Random _random = Random.secure();

String randomHex(int bytes) {
  final buffer = StringBuffer();
  for (var i = 0; i < bytes; i++) {
    buffer.write(_random.nextInt(256).toRadixString(16).padLeft(2, '0'));
  }
  return buffer.toString();
}

typedef StackWrapper = Future<ApiReply> Function(
  ApiCall call,
  Future<ApiReply> Function(ApiCall call) inner,
);

typedef UploadWrapper = Future<ApiReply> Function(
  ApiUpload upload,
  Future<ApiReply> Function(ApiUpload upload) inner,
);

typedef WriteBytes = Future<void> Function(
  RandomAccessFile file,
  List<int> bytes,
);

final class WriteThrottle {
  WriteThrottle({this.delay = Duration.zero}) {
    addTearDown(open);
  }

  Duration delay;
  int calls = 0;
  int written = 0;
  Completer<void>? _gate;

  void hold() => _gate ??= Completer<void>();

  void open() {
    final gate = _gate;
    _gate = null;
    if (gate != null && !gate.isCompleted) gate.complete();
  }

  Future<void> call(RandomAccessFile file, List<int> bytes) async {
    calls++;
    final gate = _gate;
    if (gate != null) await gate.future;
    if (delay > Duration.zero) await Future<void>.delayed(delay);
    await writeAllBytes(file, bytes);
    written += bytes.length;
  }
}

final class Gate<T> {
  Gate(this.fallback) {
    addTearDown(() => open(fallback));
  }

  final T fallback;
  final Completer<T> _gate = Completer<T>();
  final Completer<void> reached = Completer<void>();
  int calls = 0;

  bool get isOpen => _gate.isCompleted;

  void open(T value) {
    if (!_gate.isCompleted) _gate.complete(value);
  }

  Future<T> wait() {
    calls++;
    if (!reached.isCompleted) reached.complete();
    return _gate.future;
  }
}

final class SeenCall {
  SeenCall(this.path, this.json);

  final String path;
  final Map<String, Object?> json;
}

final class ScriptedPicker implements FilePicker {
  String? next;
  Object? failure;
  Completer<void>? gate;
  int fileCalls = 0;
  int folderCalls = 0;

  @override
  Future<String?> pickFile() async {
    fileCalls++;
    final hold = gate;
    if (hold != null) await hold.future;
    final error = failure;
    if (error != null) throw error;
    return next;
  }

  @override
  Future<String?> pickFolder({String? startIn}) async {
    folderCalls++;
    return null;
  }

  List<String> nextMany = const [];
  Object? manyFailure;
  Completer<void>? manyGate;
  int filesCalls = 0;
  int foldersCalls = 0;

  @override
  Future<List<String>> pickFiles() {
    filesCalls++;
    return _pickMany();
  }

  @override
  Future<List<String>> pickFolders() {
    foldersCalls++;
    return _pickMany();
  }

  Future<List<String>> _pickMany() async {
    final hold = manyGate;
    if (hold != null) await hold.future;
    final error = manyFailure;
    if (error != null) throw error;
    return nextMany;
  }
}

Future<Directory> transferFolder(String prefix) async {
  final dir = await Directory.systemTemp.createTemp(prefix);
  addTearDown(() async {
    for (var attempt = 0; attempt < 40; attempt++) {
      try {
        if (dir.existsSync()) await dir.delete(recursive: true);
        return;
      } on FileSystemException {
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
    }
  });
  return dir;
}

Future<RandomAccessFile> lockExclusively(String path) async {
  final file = await File(path).open(mode: FileMode.append);
  await file.lock(FileLock.exclusive);
  addTearDown(() async {
    try {
      await file.unlock();
    } catch (_) {}
    try {
      await file.close();
    } catch (_) {}
  });
  return file;
}

final class TransferStack {
  TransferStack._({
    required this.name,
    required this.identity,
    required this.address,
    required this.base,
    required this.sourceDir,
    required this.receiveDir,
    required this.dataDir,
    required this.platform,
    required this.store,
    required this.paired,
    required this.iface,
  });

  final String name;
  final DeviceIdentity identity;
  final InternetAddress address;
  final String base;
  final String sourceDir;
  final String receiveDir;
  final String dataDir;
  final TransferPlatform platform;
  final FakeFolderStore store;
  final PairedDevicesStore paired;
  final ActiveInterface iface;
  final FakeClock clock = FakeClock();
  final ScriptedPicker picker = ScriptedPicker();
  final Map<String, int> handled = {};
  final List<SeenCall> calls = [];
  final Map<String, StackWrapper> wrappers = {};
  final List<String> logs = [];
  final List<TransferEvent> events = [];
  final List<OutgoingTransferView> outgoingSeen = [];
  final List<IncomingTransferView> incomingSeen = [];
  final List<TransferResultView?> sentResults = [];
  UploadWrapper? uploadWrapper;
  late final TempJournal journal;
  late final TransferCoordinator coordinator;
  late final ApiServer server;
  DateTime _rateClock = DateTime.utc(2026, 10, 24, 9);
  Timer? _sampler;
  bool _closed = false;

  String get tempSub => '$receiveDir\\$tempFolderName';

  Future<void> reached(
    OutgoingPhase phase, {
    Duration limit = const Duration(seconds: 8),
  }) => eventually(
    () => phasesSeen.contains(phase),
    limit: limit,
    reason: '$name reached $phase',
  );

  void followRealTime() => clock.followRealTime();

  Future<TransferResultView> receivedResult({
    TransferResultView? after,
    Duration limit = const Duration(seconds: 8),
  }) async {
    await eventually(
      () {
        final current = coordinator.lastReceived;
        return current != null &&
            !identical(current, after) &&
            coordinator.incoming?.stage != IncomingStage.receiving &&
            coordinator.incoming?.stage != IncomingStage.verifying;
      },
      limit: limit,
      reason: '$name last received',
    );
    return coordinator.lastReceived!;
  }

  String get fingerprint => identity.fingerprint;

  int get port => server.boundPort!;

  int handledOn(String path) => handled[path] ?? 0;

  int get handledTotal => handled.values.fold(0, (a, b) => a + b);

  int get offersReceived => handledOn(ApiPaths.transferOffer);

  OutgoingTransferView? get outgoing => coordinator.outgoing;

  TransferResultView? get lastSent => coordinator.lastSent;

  IncomingTransferView? get incoming => coordinator.incoming;

  TransferResultView? get lastReceived => coordinator.lastReceived;

  List<Map<String, Object?>> bodiesOn(String path) => [
    for (final call in calls)
      if (call.path == path) call.json,
  ];

  Iterable<OutgoingPhase> get phasesSeen => outgoingSeen.map((v) => v.phase);

  static Future<TransferStack> start({
    required String name,
    required InternetAddress address,
    bool remembered = true,
    Duration pollHold = const Duration(milliseconds: 200),
    Duration tickInterval = const Duration(milliseconds: 10),
    Duration idleTimeout = Limits.transferIdleTimeout,
    Duration confirmTimeout = Limits.transferConfirmTimeout,
    WriteBytes? writeBytes,
    String Function(String base)? receiveChild,
    List<ActiveInterface> extraInterfaces = const [],
    Future<void> Function(int entry)? beforeStreamEntry,
    FolderRevealer? revealer,
    MarkFile? markFile,
    ClearHidden? clearHidden,
    ExclusionSource exclusions = const NoExclusionSource(),
  }) async {
    final root = await transferFolder('nexus_t11_');
    final base = (await realFs.realPath(root.path))!;
    String folder(String child) {
      final path = '$base\\$child';
      Directory(path).createSync(recursive: true);
      return path;
    }

    final sourceDir = folder('source');
    final receiveDir = folder(receiveChild?.call(base) ?? 'recv');
    final dataDir = folder('data');
    final system = SystemFolders(
      downloads: folder('downloads'),
      startup: folder('sys\\startup'),
      startMenu: folder('sys\\startmenu'),
      windows: folder('sys\\windows'),
      programFiles: folder('sys\\programfiles'),
      systemDriveRoot: folder('sys\\root'),
    );
    ReceiveFolder? rememberedFolder;
    if (remembered) {
      final facts = await realFs.volumeFacts(receiveDir);
      expect(facts, isNotNull);
      rememberedFolder = ReceiveFolder(
        path: receiveDir,
        volumeId: facts!.volumeId,
      );
    }
    final identity = DeviceIdentity.generate();
    final paired = PairedDevicesStore(
      JsonFileStore(File('$dataDir\\paired.json')),
      ownerFingerprint: identity.fingerprint,
    );
    await paired.load();
    final stack = TransferStack._(
      name: name,
      identity: identity,
      address: address,
      base: base,
      sourceDir: sourceDir,
      receiveDir: receiveDir,
      dataDir: dataDir,
      platform: TransferPlatform(system),
      store: FakeFolderStore(rememberedFolder),
      paired: paired,
      iface: loopbackInterface(
        adapterId: 'transfer-${address.address}',
        address: address.address,
      ),
    );
    stack.coordinator = TransferCoordinator(
      identity: identity,
      paired: paired,
      folders: stack.store,
      journal: stack.journal = TempJournal(
        JsonFileStore(File('$dataDir\\cleanup.json')),
      ),
      dataDirPath: dataDir,
      picker: stack.picker,
      fileSystem: stack.platform,
      clock: stack.clock.call,
      tickInterval: tickInterval,
      pollHold: pollHold,
      idleTimeout: idleTimeout,
      confirmTimeout: confirmTimeout,
      writeBytes: writeBytes ?? writeAllBytes,
      exclusions: exclusions,
      beforeStreamEntry: beforeStreamEntry,
      revealer: revealer,
      markFile: markFile,
      clearHidden: clearHidden,
      log: stack.logs.add,
    );
    stack.coordinator.changes.listen((_) {
      final out = stack.coordinator.outgoing;
      if (out != null) stack.outgoingSeen.add(out);
      final inc = stack.coordinator.incoming;
      if (inc != null) stack.incomingSeen.add(inc);
      final sent = stack.coordinator.lastSent;
      if (stack.sentResults.isEmpty || stack.sentResults.last != sent) {
        stack.sentResults.add(sent);
      }
    });
    stack.coordinator.events.listen(stack.events.add);
    addTearDown(stack.close);
    for (var attempt = 0; ; attempt++) {
      final server = ApiServer(
        identity: identity,
        paired: paired,
        routes: [
          for (final route in stack.coordinator.routes) stack._wrap(route),
        ],
        uploadRoutes: [
          for (final route in stack.coordinator.uploadRoutes)
            stack._wrapUpload(route),
        ],
        selfInfo: () => selfInfoOf(identity),
        onRegistered: (_, _, _) {},
        port: extraInterfaces.isEmpty
            ? 0
            : await freePortOn([
                address,
                for (final extra in extraInterfaces) extra.subnet.address,
              ]),
        now: stack._rateNow,
        log: stack.logs.add,
      );
      await server.syncInterfaces([stack.iface, ...extraInterfaces]);
      if (server.openInterfaceIds.length == 1 + extraInterfaces.length) {
        stack.server = server;
        break;
      }
      await server.close();
      if (attempt == 10) fail('could not open the listener of $name');
    }
    stack.coordinator.start();
    stack._sampler = Timer.periodic(const Duration(milliseconds: 1), (_) {
      final out = stack.coordinator.outgoing;
      if (out != null &&
          (stack.outgoingSeen.isEmpty || stack.outgoingSeen.last != out)) {
        stack.outgoingSeen.add(out);
      }
    });
    return stack;
  }

  DateTime _rateNow() {
    _rateClock = _rateClock.add(const Duration(minutes: 3));
    return _rateClock;
  }

  ApiRoute _wrap(ApiRoute route) => ApiRoute(
    path: route.path,
    access: route.access,
    maxBodyBytes: route.maxBodyBytes,
    limit: route.limit,
    handle: (call) {
      handled.update(route.path, (n) => n + 1, ifAbsent: () => 1);
      final json = call.json;
      calls.add(
        SeenCall(
          route.path,
          json is Map<String, Object?> ? json : const <String, Object?>{},
        ),
      );
      final wrapper = wrappers[route.path];
      return wrapper == null ? route.handle(call) : wrapper(call, route.handle);
    },
  );

  ApiUploadRoute _wrapUpload(ApiUploadRoute route) => ApiUploadRoute(
    path: route.path,
    limit: route.limit,
    handle: (upload) {
      handled.update(route.path, (n) => n + 1, ifAbsent: () => 1);
      final wrapper = uploadWrapper;
      return wrapper == null
          ? route.handle(upload)
          : wrapper(upload, route.handle);
    },
  );

  SendTarget targetOf(TransferStack other) =>
      targetAt(other.address, other.port, fingerprint: other.fingerprint);

  SendTarget targetAt(
    InternetAddress remote,
    int remotePort, {
    required String fingerprint,
  }) => SendTarget(
    fingerprint: fingerprint,
    address: remote,
    port: remotePort,
    interfaceId: iface.id,
    localAddress: address,
  );

  Future<void> trust(
    DeviceIdentity other, {
    String name = 'Peer',
    PeerRelation relation = PeerRelation.mine,
  }) async {
    await paired.replaceAll([
      for (final d in paired.devices)
        if (d.fingerprint != other.fingerprint) d,
      PairedDevice(
        fingerprint: other.fingerprint,
        name: name,
        certificatePem: other.certificatePem,
        relation: relation,
        pairedAt: DateTime.utc(2026, 10, 24),
      ),
    ]);
    await server.rebuildTrust();
  }

  Future<void> forget(String otherFingerprint) async {
    await paired.remove(otherFingerprint);
    await server.rebuildTrust();
  }

  Future<String> sourceFile(String fileName, List<int> bytes) async {
    final path = '$sourceDir\\$fileName';
    await File(path).writeAsBytes(bytes, flush: true);
    return path;
  }

  Future<SendStart> sendTo(
    SendTarget target,
    String path, {
    SendTarget? Function()? refresh,
  }) {
    picker.next = path;
    return coordinator.sendFile(target, refresh: refresh ?? () => target);
  }

  Future<SendStart> send(TransferStack to, String path) =>
      sendTo(targetOf(to), path);

  Future<TransferResultView> sentResult({
    TransferResultView? after,
    Duration limit = const Duration(seconds: 8),
  }) async {
    await eventually(
      () {
        final current = coordinator.lastSent;
        return current != null &&
            !identical(current, after) &&
            coordinator.outgoing == null;
      },
      limit: limit,
      reason: '$name last sent',
    );
    return coordinator.lastSent!;
  }

  Future<void> phase(
    OutgoingPhase phase, {
    Duration limit = const Duration(seconds: 8),
  }) => eventually(
    () => coordinator.outgoing?.phase == phase,
    limit: limit,
    reason: '$name outgoing phase $phase',
  );

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    _sampler?.cancel();
    await coordinator.close();
    await server.close();
  }
}

Future<void> link(
  TransferStack sender,
  TransferStack receiver, {
  PeerRelation senderAtReceiver = PeerRelation.mine,
  String senderName = 'Laptop',
  String receiverName = 'Sobremesa',
}) async {
  await sender.trust(receiver.identity, name: receiverName);
  await receiver.trust(
    sender.identity,
    name: senderName,
    relation: senderAtReceiver,
  );
}

typedef FaceAnswer = (int, Map<String, Object?>);

typedef FaceHandler = FutureOr<FaceAnswer?> Function(Map<String, Object?> body);

typedef FaceUploadHandler = FutureOr<FaceAnswer?> Function(
  HttpRequest request,
  FaceUpload upload,
);

const FaceAnswer savedAnswer = (200, {'state': 'saved', 'marked': true});

final class FaceUpload {
  FaceUpload(this.transfer, this.permit, this.contentLength);

  final String? transfer;
  final String? permit;
  final int contentLength;
  final BytesBuilder received = BytesBuilder(copy: false);
  bool complete = false;

  Future<Uint8List> readAll(HttpRequest request) async {
    await for (final chunk in request) {
      received.add(chunk);
    }
    complete = true;
    return received.toBytes();
  }

  Future<void> readSome(HttpRequest request) {
    final first = Completer<void>();
    late final StreamSubscription<List<int>> subscription;
    subscription = request.listen(
      (chunk) {
        received.add(chunk);
        subscription.pause();
        if (!first.isCompleted) first.complete();
      },
      onError: (Object _) {
        if (!first.isCompleted) first.complete();
      },
      onDone: () {
        if (!first.isCompleted) first.complete();
      },
    );
    return first.future;
  }
}

final class TransferFace {
  TransferFace._(this.identity, this.server, this.address);

  final DeviceIdentity identity;
  final HttpServer server;
  final InternetAddress address;
  final Map<String, FaceHandler> handlers = {};
  final List<SeenCall> calls = [];
  final List<FaceUpload> uploads = [];
  final List<Completer<void>> _holds = [];
  FaceUploadHandler? onUpload;
  bool picker = false;
  Duration waitDelay = const Duration(milliseconds: 20);

  int get port => server.port;

  String get fingerprint => identity.fingerprint;

  int count(String path) => calls.where((c) => c.path == path).length;

  List<Map<String, Object?>> bodiesOn(String path) => [
    for (final call in calls)
      if (call.path == path) call.json,
  ];

  static Future<TransferFace> start({InternetAddress? address}) async {
    final identity = DeviceIdentity.generate();
    final bound = address ?? hostF;
    final server = await HttpServer.bindSecure(
      bound,
      0,
      identity.serverContext(trustedCertificatesPem: const []),
    );
    final face = TransferFace._(identity, server, bound);
    server.listen((request) => unawaited(face._serve(request)));
    addTearDown(face.close);
    return face;
  }

  Future<FaceAnswer?> hold() {
    final gate = Completer<void>();
    _holds.add(gate);
    return gate.future.then((_) => null);
  }

  Future<void> moreWaits(int n, {Duration limit = const Duration(seconds: 8)}) {
    final target = count(ApiPaths.transferWait) + n;
    return eventually(
      () => count(ApiPaths.transferWait) >= target,
      limit: limit,
      reason: '$n more waits',
    );
  }

  FaceAnswer _default(String path) => switch (path) {
    ApiPaths.transferOffer => (202, {'state': 'waiting', 'picker': picker}),
    ApiPaths.transferWait => (200, {'state': 'waiting', 'picker': picker}),
    ApiPaths.transferCancel => (200, {'state': 'cancelled'}),
    _ => (404, {'error': 'not_found'}),
  };

  Future<void> _serve(HttpRequest request) async {
    try {
      final path = request.uri.path;
      if (path == ApiPaths.transferUpload) {
        final upload = FaceUpload(
          request.headers.value(TransferHeaders.transfer),
          request.headers.value(TransferHeaders.permit),
          request.contentLength,
        );
        uploads.add(upload);
        calls.add(SeenCall(path, const {}));
        final handler = onUpload;
        final answer = handler == null
            ? await upload.readAll(request).then((_) => savedAnswer)
            : await handler(request, upload);
        await _answer(request, answer);
        return;
      }
      final text = await utf8.decoder.bind(request).join();
      Object? decoded;
      try {
        decoded = jsonDecode(text);
      } on FormatException {
        decoded = null;
      }
      final body = decoded is Map<String, Object?>
          ? decoded
          : <String, Object?>{};
      calls.add(SeenCall(path, body));
      if (path == ApiPaths.transferWait) await Future<void>.delayed(waitDelay);
      final handler = handlers[path];
      final answer = handler == null ? _default(path) : await handler(body);
      await _answer(request, answer);
    } catch (_) {
      try {
        await request.response.close();
      } catch (_) {}
    }
  }

  Future<void> _answer(HttpRequest request, FaceAnswer? answer) async {
    if (answer == null) {
      final socket = await request.response.detachSocket(writeHeaders: false);
      socket.destroy();
      return;
    }
    final (status, json) = answer;
    final bytes = utf8.encode(jsonEncode(json));
    final response = request.response
      ..persistentConnection = false
      ..statusCode = status
      ..headers.contentType = ContentType.json
      ..contentLength = bytes.length
      ..add(bytes);
    await response.close();
  }

  Future<void> close() async {
    for (final gate in _holds) {
      if (!gate.isCompleted) gate.complete();
    }
    await server.close(force: true);
  }
}

Future<ServerSocket> silentServer(InternetAddress address) async {
  final server = await ServerSocket.bind(address, 0);
  final sockets = <Socket>[];
  server.listen(sockets.add);
  addTearDown(() async {
    for (final socket in sockets) {
      socket.destroy();
    }
    await server.close();
  });
  return server;
}
