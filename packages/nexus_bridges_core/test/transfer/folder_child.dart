import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:nexus_bridges_core/src/identity/identity.dart';
import 'package:nexus_bridges_core/src/network/network.dart';
import 'package:nexus_bridges_core/src/pairing/pairing.dart';
import 'package:nexus_bridges_core/src/protocol/protocol.dart';
import 'package:nexus_bridges_core/src/server/server.dart';
import 'package:nexus_bridges_core/src/storage/storage.dart';
import 'package:nexus_bridges_core/src/transfer/platform.dart';
import 'package:nexus_bridges_core/src/transfer/transfer.dart';

const WindowsFileSystemPlatform _real = WindowsFileSystemPlatform();

final class _Platform implements FileSystemPlatform {
  _Platform(this._system);

  final SystemFolders _system;

  @override
  Future<String?> realPath(String path) => _real.realPath(path);

  @override
  Future<VolumeFacts?> volumeFacts(String path) => _real.volumeFacts(path);

  @override
  Future<int?> freeBytes(String path) => _real.freeBytes(path);

  @override
  Future<bool> isCloudSynced(String path) => _real.isCloudSynced(path);

  @override
  Future<SystemFolders> systemFolders() async => _system;

  @override
  Future<bool> setHidden(String path) => _real.setHidden(path);

  @override
  Future<MoveOutcome> moveNoReplace(String from, String to) =>
      _real.moveNoReplace(from, to);

  @override
  Future<FreeNameMove> moveToFreeName(
    String from,
    String folder,
    String name,
  ) => _real.moveToFreeName(from, folder, name);

  @override
  Future<FreeNameMove> moveFolderToFreeName(
    String from,
    String folder,
    String name, {
    required int maxNameUnits,
  }) => _real.moveFolderToFreeName(
    from,
    folder,
    name,
    maxNameUnits: maxNameUnits,
  );

  @override
  Future<bool> markFromInternet(String filePath) =>
      _real.markFromInternet(filePath);

  @override
  Future<bool> deleteTree(String path) => _real.deleteTree(path);

  @override
  Future<bool> isDangerousType(String extension) =>
      _real.isDangerousType(extension);

  @override
  Future<Set<String>> dangerousExtensions(Set<String> extensions) =>
      _real.dangerousExtensions(extensions);
}

final class _Folders implements ReceiveFolderStore {
  _Folders(this._folder);

  ReceiveFolder? _folder;

  @override
  Future<ReceiveFolder?> load() async => _folder;

  @override
  Future<bool> save(ReceiveFolder folder) async {
    _folder = folder;
    return true;
  }
}

final class _NoPicker implements FilePicker {
  @override
  Future<String?> pickFile() async => null;

  @override
  Future<String?> pickFolder({String? startIn}) async => null;

  @override
  Future<List<String>> pickFiles() async => const [];

  @override
  Future<List<String>> pickFolders() async => const [];
}

final class _NoReveal implements FolderRevealer {
  @override
  Future<RevealResult> reveal(String filePath) async =>
      RevealResult.unavailable;
}

void _emit(Map<String, Object?> event) => stdout.writeln(jsonEncode(event));

String _folder(String path) {
  Directory(path).createSync(recursive: true);
  return path;
}

int? _option(List<String> args, String name) {
  for (final arg in args) {
    if (arg.startsWith('--$name=')) {
      return int.parse(arg.substring(name.length + 3));
    }
  }
  return null;
}

Future<void> main(List<String> args) async {
  final role = args[0];
  final address = InternetAddress(args[1]);
  final work = _folder(args[2]);
  final holdAt = _option(args, 'hold-at');
  final notifyAt = _option(args, 'notify-at');
  final data = _folder('$work\\data');
  final recv = _folder('$work\\recv');
  final system = SystemFolders(
    downloads: _folder('$work\\downloads'),
    startup: _folder('$work\\sys\\startup'),
    startMenu: _folder('$work\\sys\\startmenu'),
    windows: _folder('$work\\sys\\windows'),
    programFiles: _folder('$work\\sys\\programfiles'),
    systemDriveRoot: _folder('$work\\sys\\root'),
  );
  final facts = await _real.volumeFacts(recv);
  final identity = DeviceIdentity.generate();
  final paired = PairedDevicesStore(
    JsonFileStore(File('$data\\paired.json')),
    ownerFingerprint: identity.fingerprint,
  );
  await paired.load();
  final journal = TempJournal(JsonFileStore(File('$data\\cleanup.json')));
  await journal.load();

  var held = false;
  var streamed = 0;
  final release = Completer<void>();
  Future<void> beforeEntry(int entry) async {
    if (holdAt == null || held || streamed++ < holdAt) return;
    held = true;
    _emit({'event': 'holding', 'streamed': streamed - 1});
    await release.future;
  }

  final coordinator = TransferCoordinator(
    identity: identity,
    paired: paired,
    folders: _Folders(ReceiveFolder(path: recv, volumeId: facts!.volumeId)),
    journal: journal,
    dataDirPath: data,
    picker: _NoPicker(),
    fileSystem: _Platform(system),
    revealer: _NoReveal(),
    beforeStreamEntry: beforeEntry,
  );
  final iface = ActiveInterface(
    id: 'folder#${address.address}',
    adapterId: 'folder',
    friendlyName: 'Loopback Pseudo-Interface 1',
    subnet: Ipv4Subnet(address, 8),
  );
  late final ApiServer server;
  server = ApiServer(
    identity: identity,
    paired: paired,
    selfInfo: () => DeviceInfo(
      name: role,
      fingerprint: identity.fingerprint,
      port: server.boundPort ?? defaultPort,
      protocol: protocolVersion,
      deviceType: DeviceType.desktop,
    ),
    onRegistered: (_, _, _) {},
    routes: coordinator.routes,
    uploadRoutes: coordinator.uploadRoutes,
    port: 0,
  );
  await server.syncInterfaces([iface]);
  coordinator.start();

  var baseline = 0;
  var maxAtBaseline = 0;
  var peak = 0;
  String? peakPhase;
  var sampling = false;
  final samples = <int>[];
  var reached = false;
  var receivedFiles = 0;
  void sample() {
    final rss = ProcessInfo.currentRss;
    if (sampling && rss > peak) {
      peak = rss;
      peakPhase =
          coordinator.outgoing?.phase.name ?? coordinator.incoming?.stage.name;
    }
    final incoming = coordinator.incoming;
    if (incoming != null && incoming.receivedFiles > receivedFiles) {
      receivedFiles = incoming.receivedFiles;
    }
    if (notifyAt != null && !reached && receivedFiles >= notifyAt) {
      reached = true;
      _emit({'event': 'reached', 'files': receivedFiles});
    }
  }

  final timeline = <String>[];
  final sampler = Timer.periodic(const Duration(milliseconds: 250), (_) {
    final rss = ProcessInfo.currentRss;
    samples.add(rss);
    if (sampling && samples.length % 120 == 0) {
      final outgoing = coordinator.outgoing;
      final incoming = coordinator.incoming;
      final phase = outgoing?.phase.name ?? incoming?.stage.name ?? 'idle';
      final files = outgoing?.sentFiles ?? incoming?.receivedFiles ?? 0;
      timeline.add('$phase:$files:${(rss - baseline) ~/ 1000000}');
    }
    sample();
  });

  TransferResultView? lastReceived;
  coordinator.changes.listen((_) {
    sample();
    final incoming = coordinator.incoming;
    final received = coordinator.lastReceived;
    final stage = incoming?.stage;
    if (received != null &&
        !identical(received, lastReceived) &&
        stage != IncomingStage.receiving &&
        stage != IncomingStage.verifying) {
      lastReceived = received;
      _emit({
        'event': 'received',
        'outcome': received.outcome.name,
        'files': receivedFiles,
      });
    }
  });

  _emit({
    'event': 'ready',
    'fingerprint': identity.fingerprint,
    'pem': identity.certificatePem,
    'port': server.boundPort,
  });

  await for (final line
      in stdin.transform(utf8.decoder).transform(const LineSplitter())) {
    final command = jsonDecode(line) as Map<String, Object?>;
    switch (command['cmd']) {
      case 'trust':
        await paired.replaceAll([
          PairedDevice(
            fingerprint: command['fingerprint']! as String,
            name: 'Peer',
            certificatePem: command['pem']! as String,
            relation: PeerRelation.mine,
            pairedAt: DateTime.utc(2026, 11, 1),
          ),
        ]);
        await server.rebuildTrust();
        _emit({'event': 'trusted'});
      case 'cleanup':
        await coordinator.cleanupAtStart();
        _emit({'event': 'cleaned'});
      case 'baseline':
        final start = samples.length;
        while (samples.length < start + 5) {
          await Future<void>.delayed(const Duration(milliseconds: 100));
        }
        final rest = samples.sublist(start)..sort();
        baseline = rest[2];
        maxAtBaseline = ProcessInfo.maxRss;
        peak = baseline;
        sampling = true;
        _emit({'event': 'baseline', 'rss': baseline});
      case 'send':
        final target = SendTarget(
          fingerprint: command['fingerprint']! as String,
          address: InternetAddress(command['address']! as String),
          port: command['port']! as int,
          interfaceId: iface.id,
          localAddress: address,
        );
        _emit({'event': 'started'});
        unawaited(
          coordinator
              .sendElement(
                target,
                command['path']! as String,
                refresh: () => target,
              )
              .then((result) {
                sample();
                _emit({
                  'event': 'sent',
                  'outcome': result?.outcome.name,
                  'files': result?.fileCount,
                });
              }),
        );
      case 'release':
        if (!release.isCompleted) release.complete();
      case 'report':
        sample();
        final max = ProcessInfo.maxRss;
        if (sampling && max > maxAtBaseline && max > peak) peak = max;
        _emit({
          'event': 'report',
          'baseline': baseline,
          'peak': peak,
          'peakPhase': peakPhase,
          'timeline': timeline,
          'maxRss': max,
          'samples': samples.length,
        });
      case 'exit':
        sampler.cancel();
        if (!release.isCompleted) release.complete();
        await coordinator.close();
        await server.close();
        _emit({'event': 'bye'});
        exit(0);
    }
  }
}
