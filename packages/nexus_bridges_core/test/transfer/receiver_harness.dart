import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:nexus_bridges_core/src/identity/identity.dart';
import 'package:nexus_bridges_core/src/pairing/pairing.dart';
import 'package:nexus_bridges_core/src/protocol/protocol.dart';
import 'package:nexus_bridges_core/src/server/server.dart';
import 'package:nexus_bridges_core/src/settings/settings.dart';
import 'package:nexus_bridges_core/src/storage/storage.dart';
import 'package:nexus_bridges_core/src/transfer/platform.dart';
import 'package:nexus_bridges_core/src/transfer/transfer.dart';
import 'package:nexus_bridges_core/src/transport/transport.dart';
import 'package:test/test.dart';

import '../support/infra.dart';
import '../server/api_server_harness.dart';

const WindowsFileSystemPlatform realFs = WindowsFileSystemPlatform();

const String sampleDigest =
    '0000000000000000000000000000000000000000000000000000000000000000';

final Random _random = Random.secure();

String newTransferId() {
  final buffer = StringBuffer();
  for (var i = 0; i < 16; i++) {
    buffer.write(_random.nextInt(256).toRadixString(16).padLeft(2, '0'));
  }
  return buffer.toString();
}

final RegExp hex32 = RegExp(r'^[0-9a-f]{32}$');

final class RawReply {
  RawReply(this.status, this.body);

  final int status;
  final Uint8List body;

  String get text => utf8.decode(body);

  Map<String, Object?> get json => jsonDecode(text) as Map<String, Object?>;

  String? get state => json['state'] as String?;

  String? get error => json['error'] as String?;
}

final class FakeClock {
  Duration now = const Duration(hours: 3);
  Stopwatch? _follow;

  Duration call() => now + (_follow?.elapsed ?? Duration.zero);

  void advance(Duration span) => now += span;

  void followRealTime() => _follow ??= Stopwatch()..start();
}

final class TransferPlatform implements FileSystemPlatform {
  TransferPlatform(this.system);

  SystemFolders system;
  Completer<void>? volumeGate;
  Completer<void>? freeGate;
  Completer<void>? systemGate;
  Object? systemError;
  Future<bool> Function(String extension) dangerous = (_) async => false;
  int? freeBytesOverride;
  bool freeBytesUnknown = false;
  bool noMarkSupport = false;
  VolumeFacts? Function(String path, VolumeFacts? facts)? adjustFacts;
  bool Function(String path)? cloudFor;
  Future<void> Function(String method, String path)? hold;
  Future<bool> Function(String filePath)? mark;
  Future<FreeNameMove> Function(String from, String folder, String name)? move;
  Future<Set<String>> Function(Set<String> extensions)? dangerousBatch;
  final List<String> dangerousAsked = [];
  final List<Set<String>> dangerousBatches = [];
  final List<String> calls = [];
  int volumeCalls = 0;
  int freeCalls = 0;
  int systemCalls = 0;

  Future<void> _enter(String method, String path) async {
    calls.add('$method $path');
    final wait = hold;
    if (wait != null) await wait(method, path);
  }

  @override
  Future<String?> realPath(String path) async {
    await _enter('realPath', path);
    return realFs.realPath(path);
  }

  @override
  Future<VolumeFacts?> volumeFacts(String path) async {
    volumeCalls++;
    await _enter('volumeFacts', path);
    final gate = volumeGate;
    if (gate != null) await gate.future;
    var facts = await realFs.volumeFacts(path);
    if (facts != null && noMarkSupport) {
      facts = VolumeFacts(
        volumeId: facts.volumeId,
        supportsNamedStreams: false,
        isRemote: facts.isRemote,
      );
    }
    final adjust = adjustFacts;
    return adjust == null ? facts : adjust(path, facts);
  }

  @override
  Future<int?> freeBytes(String path) async {
    freeCalls++;
    await _enter('freeBytes', path);
    final gate = freeGate;
    if (gate != null) await gate.future;
    if (freeBytesUnknown) return null;
    return freeBytesOverride ?? await realFs.freeBytes(path);
  }

  @override
  Future<bool> isCloudSynced(String path) async =>
      cloudFor?.call(path) ?? false;

  @override
  Future<SystemFolders> systemFolders() async {
    systemCalls++;
    final gate = systemGate;
    if (gate != null) await gate.future;
    final error = systemError;
    if (error != null) throw error;
    return system;
  }

  @override
  Future<bool> setHidden(String path) => realFs.setHidden(path);

  @override
  Future<MoveOutcome> moveNoReplace(String from, String to) =>
      realFs.moveNoReplace(from, to);

  @override
  Future<FreeNameMove> moveToFreeName(String from, String folder, String name) {
    final fake = move;
    return fake == null
        ? realFs.moveToFreeName(from, folder, name)
        : fake(from, folder, name);
  }

  @override
  Future<FreeNameMove> moveFolderToFreeName(
    String from,
    String folder,
    String name, {
    required int maxNameUnits,
  }) => realFs.moveFolderToFreeName(
    from,
    folder,
    name,
    maxNameUnits: maxNameUnits,
  );

  @override
  Future<bool> markFromInternet(String filePath) {
    final fake = mark;
    return fake == null ? realFs.markFromInternet(filePath) : fake(filePath);
  }

  @override
  Future<bool> deleteTree(String path) => realFs.deleteTree(path);

  @override
  Future<bool> isDangerousType(String extension) {
    dangerousAsked.add(extension);
    return dangerous(extension);
  }

  @override
  Future<Set<String>> dangerousExtensions(Set<String> extensions) async {
    dangerousBatches.add(Set<String>.of(extensions));
    final batch = dangerousBatch;
    if (batch != null) return batch(extensions);
    return {
      for (final extension in extensions)
        if (await dangerous(extension)) extension,
    };
  }
}

final class FakeFolderStore implements ReceiveFolderStore {
  FakeFolderStore(this.folder);

  ReceiveFolder? folder;
  Completer<void>? loadGate;
  Completer<void>? saveGate;
  int loads = 0;
  final List<ReceiveFolder> saved = [];

  @override
  Future<ReceiveFolder?> load() async {
    loads++;
    final gate = loadGate;
    if (gate != null) await gate.future;
    return folder;
  }

  @override
  Future<bool> save(ReceiveFolder folder) async {
    saved.add(folder);
    if (saveGate != null) await saveGate!.future;
    return true;
  }
}

final class SettingsFolderStore implements ReceiveFolderStore {
  SettingsFolderStore(this.file);

  final File file;

  SettingsStore get _settings => SettingsStore(JsonFileStore(file));

  @override
  Future<ReceiveFolder?> load() async {
    final saved = await _settings.readReceiveFolder();
    return saved == null
        ? null
        : ReceiveFolder(path: saved.path, volumeId: saved.volumeId);
  }

  @override
  Future<bool> save(ReceiveFolder folder) => _settings.writeReceiveFolder(
    SavedReceiveFolder(path: folder.path, volumeId: folder.volumeId),
  );
}

final class HeldPicker implements FilePicker {
  HeldPicker() {
    addTearDown(() {
      while (_pending.isNotEmpty) {
        _pending.removeAt(0).complete(null);
      }
    });
  }

  final List<String?> startIns = [];
  final List<Completer<String?>> _pending = [];
  int fileCalls = 0;

  int get folderCalls => startIns.length;

  bool get open => _pending.isNotEmpty;

  @override
  Future<String?> pickFile() async {
    fileCalls++;
    return null;
  }

  @override
  Future<String?> pickFolder({String? startIn}) {
    startIns.add(startIn);
    final pending = Completer<String?>();
    _pending.add(pending);
    return pending.future;
  }

  void answer(String? path) {
    expect(_pending, isNotEmpty, reason: 'no folder picker is open');
    _pending.removeAt(0).complete(path);
  }
}

final class NoPicker implements FilePicker {
  int calls = 0;

  @override
  Future<String?> pickFile() async {
    calls++;
    return null;
  }

  @override
  Future<String?> pickFolder({String? startIn}) async {
    calls++;
    return null;
  }
}

final class Peer {
  Peer(
    this.identity, {
    this.name = 'Laptop',
    this.relation = PeerRelation.mine,
  });

  final DeviceIdentity identity;
  final String name;
  final PeerRelation relation;

  String get fingerprint => identity.fingerprint;

  PairedDevice get device => PairedDevice(
    fingerprint: identity.fingerprint,
    name: name,
    certificatePem: identity.certificatePem,
    relation: relation,
    pairedAt: DateTime.utc(2026, 10, 24),
  );
}

Future<Directory> _temporaryDirectory() async {
  final dir = await Directory.systemTemp.createTemp('nexus_t6_');
  addTearDown(() async {
    for (var attempt = 0; attempt < 20; attempt++) {
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

Future<void> eventually(
  bool Function() condition, {
  Duration? limit,
  String reason = 'condition',
}) async {
  final span = limit ?? scaled(const Duration(seconds: 5));
  final stopwatch = Stopwatch()..start();
  while (true) {
    try {
      if (condition()) return;
    } on FileSystemException {
      if (stopwatch.elapsed > span) rethrow;
    }
    if (stopwatch.elapsed > span) fail('$reason not met within $span');
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}

Future<void> settle([Duration span = const Duration(milliseconds: 80)]) =>
    Future<void>.delayed(span);

final class ReceiverStack {
  ReceiverStack._({
    required this.identity,
    required this.base,
    required this.receiveDir,
    required this.dataDir,
    required this.downloadsDir,
    required this.platform,
    required this.store,
    required this.paired,
  });

  final DeviceIdentity identity;
  final String base;
  final String receiveDir;
  final String dataDir;
  final String downloadsDir;
  final TransferPlatform platform;
  final FakeFolderStore store;
  final PairedDevicesStore paired;
  final FakeClock clock = FakeClock();
  final NoPicker picker = NoPicker();
  final Map<String, int> handled = {};
  final List<IncomingTransferView?> views = [];
  final List<IncomingTransferView> seen = [];
  final List<bool> busyOnChange = [];
  final List<TransferEvent> events = [];
  final List<String> logs = [];
  late final TempJournal journal;
  late final TransferCoordinator coordinator;
  late final ApiServer server;
  DateTime _serverNow = DateTime.utc(2026, 10, 24, 9);
  bool freeRates = true;
  Timer? _sampler;
  bool _closed = false;

  int get port => server.boundPort!;

  int handledOn(String path) => handled[path] ?? 0;

  int get handledTotal => handled.values.fold(0, (a, b) => a + b);

  IncomingTransferView? get incoming => coordinator.incoming;

  String get sid => incoming?.sessionId ?? '';

  static Future<ReceiverStack> start({
    required DeviceIdentity identity,
    Iterable<Peer> peers = const [],
    bool remembered = true,
    String Function(String base)? rememberedPath,
    ReceiveFolderStore? storeOverride,
    Duration pollHold = const Duration(milliseconds: 200),
    Duration tickInterval = const Duration(milliseconds: 10),
    void Function(TransferPlatform platform)? configure,
    FilePicker? picker,
    ReceiveFolderStore Function(String dataDir)? storeIn,
    List<ApiRoute> Function(ReceiverStack stack)? routesOverride,
    Completer<void>? holdLoad,
    Duration idleTimeout = Limits.transferIdleTimeout,
    Future<void> Function(RandomAccessFile file, List<int> bytes)? writeBytes,
  }) async {
    final root = await _temporaryDirectory();
    final base = (await realFs.realPath(root.path))!;
    String folder(String name) {
      final path = '$base\\$name';
      Directory(path).createSync(recursive: true);
      return path;
    }

    final receiveDir = folder('recv');
    final dataDir = folder('data');
    final downloadsDir = folder('downloads');
    final system = SystemFolders(
      downloads: downloadsDir,
      startup: folder('sys\\startup'),
      startMenu: folder('sys\\startmenu'),
      windows: folder('sys\\windows'),
      programFiles: folder('sys\\programfiles'),
      systemDriveRoot: folder('sys\\root'),
    );
    final platform = TransferPlatform(system);
    configure?.call(platform);
    ReceiveFolder? rememberedFolder;
    if (remembered) {
      final facts = await realFs.volumeFacts(receiveDir);
      expect(facts, isNotNull);
      rememberedFolder = ReceiveFolder(
        path: rememberedPath?.call(base) ?? receiveDir,
        volumeId: facts!.volumeId,
      );
    }
    final paired = PairedDevicesStore(
      JsonFileStore(File('$dataDir\\paired.json')),
      ownerFingerprint: identity.fingerprint,
    );
    await paired.load();
    await paired.replaceAll([for (final peer in peers) peer.device]);
    final stack = ReceiverStack._(
      identity: identity,
      base: base,
      receiveDir: receiveDir,
      dataDir: dataDir,
      downloadsDir: downloadsDir,
      platform: platform,
      store: FakeFolderStore(rememberedFolder)..loadGate = holdLoad,
      paired: paired,
    );
    final journal = TempJournal(JsonFileStore(File('$dataDir\\cleanup.json')));
    stack.journal = journal;
    stack.coordinator = TransferCoordinator(
      identity: identity,
      paired: paired,
      folders: storeOverride ?? storeIn?.call(dataDir) ?? stack.store,
      journal: journal,
      dataDirPath: dataDir,
      picker: picker ?? stack.picker,
      fileSystem: platform,
      clock: stack.clock.call,
      tickInterval: tickInterval,
      pollHold: pollHold,
      idleTimeout: idleTimeout,
      writeBytes: writeBytes ?? writeAllBytes,
      log: stack.logs.add,
    );
    stack.coordinator.changes.listen((_) {
      final view = stack.coordinator.incoming;
      stack.views.add(view);
      stack.busyOnChange.add(stack.coordinator.busy);
      if (view != null) stack.seen.add(view);
    });
    stack.coordinator.events.listen(stack.events.add);
    stack.server = ApiServer(
      identity: identity,
      paired: paired,
      routes: [
        for (final route
            in routesOverride?.call(stack) ?? stack.coordinator.routes)
          stack._wrap(route),
      ],
      uploadRoutes: [
        for (final route in stack.coordinator.uploadRoutes)
          stack._wrapUpload(route),
      ],
      selfInfo: () => selfInfoOf(identity),
      onRegistered: (_, _, _) {},
      port: 0,
      now: stack._rateNow,
      log: stack.logs.add,
    );
    addTearDown(stack.close);
    await stack.server.syncInterfaces([loopbackInterface()]);
    expect(stack.server.openInterfaceIds, hasLength(1));
    stack.coordinator.start();
    return stack;
  }

  DateTime _rateNow() {
    if (freeRates) _serverNow = _serverNow.add(const Duration(minutes: 3));
    return _serverNow;
  }

  ApiRoute _wrap(ApiRoute route) => ApiRoute(
    path: route.path,
    access: route.access,
    maxBodyBytes: route.maxBodyBytes,
    limit: route.limit,
    handle: (call) {
      handled.update(route.path, (n) => n + 1, ifAbsent: () => 1);
      return route.handle(call);
    },
  );

  ApiUploadRoute _wrapUpload(ApiUploadRoute route) => ApiUploadRoute(
    path: route.path,
    limit: route.limit,
    handle: (upload) {
      handled.update(route.path, (n) => n + 1, ifAbsent: () => 1);
      return route.handle(upload);
    },
  );

  Future<StreamPostResult> postUpload(
    DeviceIdentity from, {
    required Map<String, String> headers,
    required int contentLength,
    required Stream<List<int>> body,
    SecurityContext? context,
    Duration timeout = const Duration(seconds: 20),
    String path = ApiPaths.transferUpload,
  }) => postStream(
    address: loopback,
    port: port,
    path: path,
    headers: headers,
    contentLength: contentLength,
    body: body,
    context: context ?? from.clientContext(presentCertificate: true),
    acceptServer: (certificate) =>
        certificateMatches(certificate, identity.fingerprint),
    sourceAddress: loopback,
    idleTimeout: timeout,
    answerTimeout: timeout,
  );

  void sampleViews() {
    _sampler ??= Timer.periodic(const Duration(milliseconds: 1), (_) {
      final view = coordinator.incoming;
      if (view != null) seen.add(view);
    });
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    _sampler?.cancel();
    await coordinator.close();
    await server.close();
  }

  Future<void> pairWith(Iterable<Peer> peers) async {
    await paired.replaceAll([
      ...paired.devices,
      for (final p in peers) p.device,
    ]);
    await server.rebuildTrust();
  }

  Future<RawReply?> post(
    DeviceIdentity from,
    String path,
    Object? json, {
    Duration timeout = const Duration(seconds: 15),
  }) => postWith(
    from.clientContext(presentCertificate: true),
    path,
    json,
    timeout: timeout,
  );

  Future<RawReply?> postWith(
    SecurityContext context,
    String path,
    Object? json, {
    Duration timeout = const Duration(seconds: 15),
  }) async {
    final response = await postJson(
      address: loopback,
      port: port,
      path: path,
      json: json,
      context: context,
      acceptServer: (certificate) =>
          certificateMatches(certificate, identity.fingerprint),
      sourceAddress: loopback,
      timeout: timeout,
      maxResponseBytes: Limits.maxTransferBodyBytes,
    );
    return response == null ? null : RawReply(response.status, response.body);
  }

  Map<String, Object?> offerBody({
    required String transfer,
    String name = 'informe.pdf',
    int size = 1536,
    String sha256 = sampleDigest,
  }) => {
    'protocol': protocolVersion,
    'transfer': transfer,
    'name': name,
    'size': size,
    'sha256': sha256,
  };

  Future<RawReply?> offer(
    Peer peer, {
    String? transfer,
    String name = 'informe.pdf',
    int size = 1536,
  }) => post(
    peer.identity,
    ApiPaths.transferOffer,
    offerBody(transfer: transfer ?? newTransferId(), name: name, size: size),
  );

  Future<RawReply?> wait(Peer peer, String transfer) =>
      post(peer.identity, ApiPaths.transferWait, {'transfer': transfer});

  Future<RawReply?> cancel(
    Peer peer,
    String transfer, {
    String reason = 'cancelled',
  }) => post(peer.identity, ApiPaths.transferCancel, {
    'transfer': transfer,
    'reason': reason,
  });

  Future<Reply?> sendRaw(DeviceIdentity from, String path, List<int> body) =>
      sendOrCut(
        port,
        httpRequest(
          'POST',
          path,
          body: body,
          headers: const {'content-type': 'application/json; charset=utf-8'},
        ),
        serverFingerprint: identity.fingerprint,
        context: from.clientContext(presentCertificate: true),
      );

  Future<void> advanceWithPolls(
    Peer peer,
    String transfer,
    Duration total, {
    Duration step = const Duration(seconds: 10),
  }) async {
    var left = total;
    while (left > Duration.zero) {
      final span = left < step ? left : step;
      clock.advance(span);
      left -= span;
      await wait(peer, transfer);
    }
  }
}
