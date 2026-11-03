import 'dart:async';
import 'dart:io';

import 'package:nexus_bridges_core/src/browse/browse.dart';
import 'package:nexus_bridges_core/src/identity/identity.dart';
import 'package:nexus_bridges_core/src/pairing/pairing.dart';
import 'package:nexus_bridges_core/src/storage/storage.dart';
import 'package:nexus_bridges_core/src/transfer/platform.dart'
    show SystemFolders;
import 'package:nexus_bridges_core/src/transfer/transfer.dart'
    show ForbiddenFolders, FreeNameMove, samePath;
import 'package:test/test.dart';

import '../node/pairing_nodes_harness.dart' show pairedEntryFor;
import '../transfer/receiver_harness.dart' show TransferPlatform, realFs;
import 'share_fs_support.dart' show realTemp;

final DeviceIdentity owner = DeviceIdentity.generate();
final DeviceIdentity mine = DeviceIdentity.generate();
final DeviceIdentity other = DeviceIdentity.generate();
final DeviceIdentity foreign = DeviceIdentity.generate();

ShareProbe probeOf(
  String realPath, {
  String volumeId = 'NTFS-0d0d0d0d',
  DriveKind? drive = DriveKind.fixed,
  bool remote = false,
  bool supportsMark = true,
  bool cloud = false,
  String? explorerName,
  bool home = false,
}) => ShareProbe(
  realPath: realPath,
  volumeId: volumeId,
  drive: drive,
  remote: remote,
  supportsMark: supportsMark,
  cloud: cloud,
  explorerName: explorerName,
  home: home,
);

final class TweakedShareFileSystem implements ShareWriteFileSystem {
  TweakedShareFileSystem(this.real, {this.profile});

  final ShareWriteFileSystem real;
  String? profile;
  final Map<String, ShareProbe> simulated = {};
  final Set<String> gone = {};
  final List<String> probed = [];
  final List<List<String>> levelZeroAsked = [];
  ShareProbe Function(ShareProbe probe)? adjust;
  bool forbiddenFails = false;
  bool probeThrows = false;
  LevelZeroFacts Function(List<ShareRecord> roots)? levelZeroAnswer;
  Completer<void>? levelZeroGate;

  @override
  Future<ForbiddenFolders?> forbiddenFolders() async =>
      forbiddenFails ? null : await real.forbiddenFolders();

  @override
  Future<String?> profilePath() async => profile ?? await real.profilePath();

  @override
  Future<LevelZeroFacts> levelZero(
    List<ShareRecord> roots,
    List<(ShareRecord, List<String>)> checks, {
    required Duration budget,
  }) async {
    levelZeroAsked.add([for (final root in roots) root.id]);
    final gate = levelZeroGate;
    if (gate != null) await gate.future;
    final answer = levelZeroAnswer;
    if (answer != null) return answer(roots);
    return real.levelZero(roots, checks, budget: budget);
  }

  @override
  Future<FolderListing> listFolders(
    ShareRecord root,
    List<String> path, {
    required Duration cap,
    required int max,
  }) => real.listFolders(root, path, cap: cap, max: max);

  @override
  Future<bool> exists(String path) async {
    if (gone.contains(path)) return false;
    if (simulated.containsKey(path)) return true;
    return real.exists(path);
  }

  @override
  Future<ShareProbe?> probe(String path) async {
    probed.add(path);
    if (probeThrows) throw StateError('probe failed');
    var found = simulated[path] ?? await real.probe(path);
    if (found == null) return null;
    final fakeProfile = profile;
    if (fakeProfile != null && !simulated.containsKey(path)) {
      final home = samePath(found.realPath, fakeProfile);
      found = probeOf(
        found.realPath,
        volumeId: found.volumeId,
        drive: found.drive,
        remote: found.remote,
        supportsMark: found.supportsMark,
        cloud: found.cloud,
        explorerName: home ? null : found.explorerName,
        home: home,
      );
    }
    final change = adjust;
    return change == null ? found : change(found);
  }

  @override
  Future<ChainResult> openChain(
    ShareRecord root,
    List<String> path, {
    String? newFolder,
  }) => real.openChain(root, path, newFolder: newFolder);

  @override
  Future<bool> prepareChain(ChainHandles chain) => real.prepareChain(chain);

  @override
  Future<FreeNameMove> recheckAndMove(
    ChainHandles chain, {
    required String tempName,
    required bool isFolder,
    required String name,
    int? maxNameUnits,
  }) => real.recheckAndMove(
    chain,
    tempName: tempName,
    isFolder: isFolder,
    name: name,
    maxNameUnits: maxNameUnits,
  );

  @override
  Future<void> releaseChain(ChainHandles chain, {required bool saved}) =>
      real.releaseChain(chain, saved: saved);
}

final class AdmissionPlace {
  AdmissionPlace._(
    this.base,
    this.platform,
    this.fs,
    this.paired,
    this.sharesFile,
  );

  final String base;
  final TransferPlatform platform;
  final TweakedShareFileSystem fs;
  final PairedDevicesStore paired;
  final File sharesFile;
  final List<String> logs = [];
  Duration now = const Duration(hours: 5);
  late ShareService service;

  String get dataDir => '$base\\data';

  String folder(String relative) {
    final path = '$base\\$relative';
    Directory(path).createSync(recursive: true);
    return path;
  }

  Future<SharesLoadResult> open() async {
    service = ShareService(
      store: SharesStore(
        JsonFileStore(sharesFile),
        ownerFingerprint: owner.fingerprint,
      ),
      paired: paired,
      fileSystem: fs,
      dataDirPath: dataDir,
      clock: () => now,
      log: logs.add,
    );
    addTearDown(service.close);
    return service.load();
  }

  Future<SharesLoadResult> reopen() async {
    await service.close();
    return open();
  }

  void breakStore() {
    if (sharesFile.existsSync()) sharesFile.deleteSync();
    Directory(sharesFile.path).createSync();
  }

  void mendStore() {
    final dir = Directory(sharesFile.path);
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  }

  String get logText => logs.join('\n');
}

Future<AdmissionPlace> admissionPlace({
  bool realSystemFolders = false,
  String? profile,
  bool open = true,
}) async {
  final base = await realTemp('nexus_t007_admit_');
  Directory('$base\\data').createSync();
  final SystemFolders system;
  if (realSystemFolders) {
    system = await realFs.systemFolders();
  } else {
    final sys = '$base\\sys';
    for (final name in [
      'downloads',
      'startup',
      'startmenu',
      'windows',
      'pf',
      'root',
    ]) {
      Directory('$sys\\$name').createSync(recursive: true);
    }
    system = SystemFolders(
      downloads: '$sys\\downloads',
      startup: '$sys\\startup',
      startMenu: '$sys\\startmenu',
      windows: '$sys\\windows',
      programFiles: '$sys\\pf',
      systemDriveRoot: '$sys\\root',
    );
  }
  final platform = TransferPlatform(system);
  final real = WindowsShareFileSystem(
    platform: platform,
    dataDirs: ['$base\\data'],
  );
  final fs = TweakedShareFileSystem(real, profile: profile);
  final paired = PairedDevicesStore(
    JsonFileStore(File('$base\\data\\paired.json')),
    ownerFingerprint: owner.fingerprint,
  );
  await paired.replaceAll([
    pairedEntryFor(mine, name: 'Mine', relation: PeerRelation.mine),
    pairedEntryFor(other, name: 'Other', relation: PeerRelation.mine),
    pairedEntryFor(foreign, name: 'Foreign', relation: PeerRelation.foreign),
  ]);
  final place = AdmissionPlace._(
    base,
    platform,
    fs,
    paired,
    File('$base\\data\\shares.json'),
  );
  if (open) await place.open();
  return place;
}

String longFolder(String base, int units) {
  final need = units - base.length - 1;
  expect(need, inInclusiveRange(1, 255));
  final path = '$base\\${'l' * need}';
  expect(path.length, units);
  Directory(path).createSync(recursive: true);
  return path;
}
