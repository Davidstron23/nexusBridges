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

final class _Picker implements FilePicker {
  String? next;

  @override
  Future<String?> pickFile() async => next;

  @override
  Future<String?> pickFolder({String? startIn}) async => null;
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

Future<void> main(List<String> args) async {
  final role = args[0];
  final address = InternetAddress(args[1]);
  final work = _folder(args[2]);
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
  final picker = _Picker();
  final coordinator = TransferCoordinator(
    identity: identity,
    paired: paired,
    folders: _Folders(ReceiveFolder(path: recv, volumeId: facts!.volumeId)),
    journal: TempJournal(JsonFileStore(File('$data\\cleanup.json'))),
    dataDirPath: data,
    picker: picker,
    fileSystem: _Platform(system),
    revealer: _NoReveal(),
  );
  final iface = ActiveInterface(
    id: 'large#${address.address}',
    adapterId: 'large',
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
  var peak = 0;
  var sampling = false;
  final samples = <int>[];
  final sampler = Timer.periodic(const Duration(seconds: 1), (_) {
    final rss = ProcessInfo.currentRss;
    samples.add(rss);
    if (sampling && rss > peak) peak = rss;
  });

  TransferResultView? lastSent;
  TransferResultView? lastReceived;
  var maxSent = 0;
  coordinator.changes.listen((_) {
    final out = coordinator.outgoing;
    if (out != null && out.sentBytes > maxSent) maxSent = out.sentBytes;
    final sent = coordinator.lastSent;
    if (sent != null && !identical(sent, lastSent) && out == null) {
      lastSent = sent;
      _emit({'event': 'sent', 'outcome': sent.outcome.name, 'bytes': maxSent});
    }
    final received = coordinator.lastReceived;
    final stage = coordinator.incoming?.stage;
    if (received != null &&
        !identical(received, lastReceived) &&
        stage != IncomingStage.receiving &&
        stage != IncomingStage.verifying) {
      lastReceived = received;
      _emit({'event': 'received', 'outcome': received.outcome.name});
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
            pairedAt: DateTime.utc(2026, 10, 25),
          ),
        ]);
        await server.rebuildTrust();
        _emit({'event': 'trusted'});
      case 'baseline':
        final start = samples.length;
        while (samples.length < start + 3) {
          await Future<void>.delayed(const Duration(milliseconds: 100));
        }
        final rest = samples.sublist(start)..sort();
        baseline = rest[1];
        peak = baseline;
        sampling = true;
        _emit({'event': 'baseline', 'rss': baseline});
      case 'send':
        picker.next = command['path']! as String;
        final target = SendTarget(
          fingerprint: command['fingerprint']! as String,
          address: InternetAddress(command['address']! as String),
          port: command['port']! as int,
          interfaceId: iface.id,
          localAddress: address,
        );
        final start = await coordinator.sendFile(target, refresh: () => target);
        _emit({'event': 'started', 'result': start.name});
      case 'report':
        final rss = ProcessInfo.currentRss;
        if (sampling && rss > peak) peak = rss;
        _emit({
          'event': 'report',
          'baseline': baseline,
          'peak': peak,
          'samples': samples.length,
        });
      case 'exit':
        sampler.cancel();
        await coordinator.close();
        await server.close();
        _emit({'event': 'bye'});
        exit(0);
    }
  }
}
