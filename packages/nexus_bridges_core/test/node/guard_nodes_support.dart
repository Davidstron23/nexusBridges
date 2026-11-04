import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart' as crypto;
import 'package:nexus_bridges_core/src/browse/browse.dart';
import 'package:nexus_bridges_core/src/identity/identity.dart';
import 'package:nexus_bridges_core/src/node/node.dart';
import 'package:nexus_bridges_core/src/pairing/pairing.dart' show PeerRelation;
import 'package:nexus_bridges_core/src/protocol/protocol.dart';
import 'package:nexus_bridges_core/src/storage/storage.dart';
import 'package:nexus_bridges_core/src/transfer/platform.dart'
    show SystemFolders;
import 'package:nexus_bridges_core/src/transfer/transfer.dart'
    show SharedFolderDestination, tempFolderName;
import 'package:nexus_bridges_core/src/transport/transport.dart';
import 'package:test/test.dart';

import '../browse/share_fs_fakes.dart';
import '../support/infra.dart';
import '../winio/short_names.dart';
import 'transfer_nodes_harness.dart';

export '../browse/share_fs_fakes.dart';
export '../winio/short_names.dart';

const String zoneMark = '[ZoneTransfer]\r\nZoneId=3\r\n';

const List<String> plainFolders = ['destino', 'MiProyectoLargo', 'otra', 'sub'];

const List<String> plainNames = [
  '.nexusbridges-incoming',
  'Inicio',
  'Oculta',
  'Sistema',
  '.git',
  ...plainFolders,
];

final List<int> forbiddenBody = utf8.encode('{"error":"forbidden"}');

final List<int> unavailableBody = utf8.encode('{"error":"unavailable"}');

void run(String command, List<String> arguments) {
  final made = Process.runSync(
    command,
    arguments,
    workingDirectory: Directory.systemTemp.path,
  );
  expect(made.exitCode, 0, reason: '${made.stdout}${made.stderr}');
}

void junction(String link, String target) =>
    run('cmd', ['/c', 'mklink', '/J', link, target]);

void attrib(String flags, String path) => run('attrib', [flags, path]);

bool exists(String path) =>
    FileSystemEntity.typeSync(path, followLinks: false) !=
    FileSystemEntityType.notFound;

bool renames(String from, String to) {
  try {
    Directory(from).renameSync(to);
    Directory(to).renameSync(from);
    return true;
  } on FileSystemException {
    return false;
  }
}

void wipeRaw(String path) {
  Process.runSync('cmd', [
    '/c',
    'rmdir',
    '/s',
    '/q',
    '\\\\?\\$path',
  ], workingDirectory: Directory.systemTemp.path);
}

String docsOf(TransferNode node) => '${node.base}\\docs';

String outsideOf(TransferNode node) => '${node.base}\\fuera';

List<String> namesIn(String folder) => [
  for (final entity in Directory(folder).listSync())
    entity.path.split(r'\').last,
]..sort();

List<String> folderShot(String docs) => [
  for (final name in namesIn(docs)) name,
  for (final folder in plainNames)
    if (exists('$docs\\$folder'))
      for (final name in namesIn('$docs\\$folder')) '$folder\\$name',
]..sort();

CountingShareFileSystem countingFor(TransferNode node) {
  final fs = CountingShareFileSystem(
    WindowsShareFileSystem(platform: node.platform, dataDirs: [node.dataPath]),
  );
  node.shareFileSystem = fs;
  return fs;
}

bool buildTrapTree(TransferNode node) {
  final docs = docsOf(node);
  final outside = outsideOf(node);
  addTearDown(() => wipeRaw(docs));
  for (final name in plainNames) {
    Directory('$docs\\$name').createSync(recursive: true);
  }
  attrib('+h', '$docs\\Oculta');
  attrib('+s', '$docs\\Sistema');
  attrib('+h', '$docs\\.git');
  for (final name in ['suelto.txt', 'acceso.lnk', 'desktop.ini', 'f']) {
    File('$docs\\$name').writeAsStringSync('archivo');
  }
  expect(makeRawFolder('$docs\\CON'), isTrue);
  expect(makeRawFolder('$docs\\x.'), isTrue);
  Directory('$outside\\centinela').createSync(recursive: true);
  junction('$docs\\union', outside);
  junction('$docs\\interna', '$docs\\destino');
  junction('$docs\\ventanas', r'C:\Windows');
  var symlinked = false;
  try {
    Link('$docs\\enlace').createSync(outside);
    symlinked = true;
  } on FileSystemException {
    symlinked = false;
  }
  final system = node.platform.system;
  node.platform.system = SystemFolders(
    downloads: system.downloads,
    startup: '$docs\\Inicio',
    startMenu: system.startMenu,
    windows: system.windows,
    programFiles: system.programFiles,
    systemDriveRoot: system.systemDriveRoot,
  );
  return symlinked;
}

void buildSimpleTree(TransferNode node) {
  final docs = docsOf(node);
  Directory('$docs\\sub\\deep').createSync(recursive: true);
  Directory('$docs\\otra').createSync();
  Directory('${outsideOf(node)}\\centinela').createSync(recursive: true);
}

Future<String> addRoot(
  TransferNode receiver,
  TransferNode sender,
  String path,
) async {
  receiver.picker.nextFolder = path;
  final added = await receiver.node.addShare(sender.fingerprint);
  expect(added, isA<ShareAdded>(), reason: path);
  final shares = receiver.state.peers[sender.fingerprint]!.shares;
  final view = shares.firstWhere((s) => s.path == path);
  return view.rootId;
}

final class Guarded {
  Guarded(this.a, this.b, this.fs, this.rootId);

  final TransferNode a;
  final TransferNode b;
  final CountingShareFileSystem fs;
  final String rootId;

  String get docs => docsOf(b);

  String get outside => outsideOf(b);

  SharedFolderDestination to(List<String> path, {String? newFolder}) =>
      SharedFolderDestination(
        rootId: rootId,
        rootName: 'docs',
        path: path,
        newFolder: newFolder,
      );

  Future<SendResult> start(
    String path,
    SharedFolderDestination destination,
  ) async {
    final result = await a.node.sendPaths(b.fingerprint, [
      path,
    ], destination: destination);
    expect(result, anyOf(SendResult.started, SendResult.queued));
    return result;
  }

  Future<TransferResultView> sendFile(
    String name,
    List<int> bytes,
    SharedFolderDestination destination,
  ) async {
    final before = a.state.lastSent;
    await start(await a.sourceFile(name, bytes), destination);
    return a.sentResult(after: before);
  }

  Future<TransferResultView> sendFolder(
    String path,
    SharedFolderDestination destination,
  ) async {
    final before = a.state.lastSent;
    await start(path, destination);
    return a.sentResult(after: before);
  }

  Future<void> settled() => eventually(
    () => fs.unreleased == 0,
    limit: scaled(transferWait),
    reason: 'every chain released',
  );

  void expectNothingLocked(List<String> folders) {
    for (final folder in folders) {
      expect(renames(folder, '$folder.moved'), isTrue, reason: folder);
    }
  }
}

Future<Guarded> guardedNodes({
  bool Function(TransferNode b)? tree,
  PeerRelation aAtB = PeerRelation.mine,
  Future<void> Function(TransferNode b, CountingShareFileSystem fs)? ready,
}) async {
  late CountingShareFileSystem fs;
  final (a, b) = await transferNodes(
    aAtB: aAtB,
    before: (a, b) async {
      (tree ?? _simple)(b);
      fs = countingFor(b);
      if (ready != null) await ready(b, fs);
    },
  );
  final rootId = await addRoot(b, a, docsOf(b));
  fs.reset();
  return Guarded(a, b, fs, rootId);
}

bool _simple(TransferNode b) {
  buildSimpleTree(b);
  return true;
}

Future<HttpsResponse?> rawPost(
  TransferNode from,
  TransferNode to,
  String path,
  Object? json,
) async {
  final caller = await from.loadIdentity();
  return postJson(
    address: to.address,
    port: to.port,
    path: path,
    json: json,
    context: caller.clientContext(presentCertificate: true),
    acceptServer: (certificate) {
      try {
        return fingerprintOfCertificate(certificate.der) == to.fingerprint;
      } on FormatException {
        return false;
      }
    },
    sourceAddress: from.address,
  );
}

Object? bodyOf(HttpsResponse response) {
  try {
    return jsonDecode(utf8.decode(response.body));
  } on FormatException {
    return null;
  }
}

String randomTransfer() {
  final random = Random.secure();
  return List.generate(
    16,
    (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0'),
  ).join();
}

Map<String, Object?> rawFileOffer(
  String name,
  List<int> bytes, {
  Map<String, Object?>? destination,
  Map<String, Object?> extra = const {},
}) => {
  'protocol': protocolVersion,
  'transfer': randomTransfer(),
  'name': name,
  'size': bytes.length,
  'sha256': crypto.sha256.convert(bytes).toString(),
  'destination': ?destination,
  ...extra,
};

Future<void> expectBrowse(
  TransferNode from,
  TransferNode to,
  Object? json,
  int status,
  List<int> body, {
  String? reason,
}) async {
  final reply = await rawPost(from, to, ApiPaths.browse, json);
  expect(reply, isNotNull, reason: reason);
  expect(reply!.status, status, reason: reason);
  expect(reply.body, body, reason: reason);
}

Map<String, Object?> rootsAsk({List<Object?>? check}) => {
  'protocol': protocolVersion,
  'check': ?check,
};

Map<String, Object?> foldersAsk(String rootId, List<String> path) => {
  'protocol': protocolVersion,
  'root': rootId,
  'path': path,
};

void expectCleanLogs(
  List<TransferNode> nodes,
  List<String> hidden, {
  List<String> words = const ['sub', 'otra', 'deep', 'nueva'],
}) {
  for (final node in nodes) {
    final text = node.logs.join('\n');
    for (final item in hidden) {
      expect(
        text.toUpperCase(),
        isNot(contains(item.toUpperCase())),
        reason: '${node.name} logged $item',
      );
    }
    for (final word in words) {
      expect(
        text,
        isNot(matches(RegExp('\\b$word\\b'))),
        reason: '${node.name} logged $word',
      );
    }
  }
}

Future<ShareRecord> recordOf(
  String path, {
  int id = 1,
  String? volumeId,
}) async {
  final facts = await realFs.volumeFacts(path);
  return ShareRecord(
    id: id.toRadixString(16).padLeft(32, '0'),
    path: path,
    volumeId: volumeId ?? facts!.volumeId,
    label: path.split(r'\').last,
    home: false,
    drive: DriveKind.fixed,
    addedAt: DateTime.utc(2026, 11, 1),
  );
}

Future<void> writeSharesFile(
  TransferNode node,
  DeviceIdentity owner,
  Map<String, List<ShareRecord>> shares,
) async {
  expect(
    await SharesStore(
      JsonFileStore(File('${node.dataPath}\\shares.json')),
      ownerFingerprint: owner.fingerprint,
    ).write(shares),
    isTrue,
  );
}

Future<String> bigFolder(
  TransferNode node,
  String name, {
  int files = 3,
  int size = 100 * 1024 * 1024,
}) async {
  final root = '${node.sourceDir}\\$name';
  Directory(root).createSync(recursive: true);
  for (var i = 0; i < files; i++) {
    final file = await File('$root\\parte$i.bin').open(mode: FileMode.write);
    await file.truncate(size);
    await file.close();
  }
  return root;
}

Future<String> smallFolder(
  TransferNode node,
  String name, {
  Map<String, List<int>> files = const {
    'uno.txt': [1, 2, 3],
    'dos\\dos.txt': [4, 5],
  },
}) async {
  final root = '${node.sourceDir}\\$name';
  for (final MapEntry(:key, :value) in files.entries) {
    final file = File('$root\\$key');
    file.parent.createSync(recursive: true);
    await file.writeAsBytes(value, flush: true);
  }
  return root;
}

Future<void> receivingBytes(TransferNode node) => node.until(
  (s) =>
      s.incoming?.stage == IncomingStage.receiving &&
      (s.incoming?.receivedBytes ?? 0) > 0,
  limit: scaled(const Duration(seconds: 40)),
  reason: '${node.name} receiving bytes',
);

bool hasTempLeft(String folder) => namesIn(folder).any(
  (name) =>
      name == tempFolderName || name.toLowerCase().contains('nexusbridges'),
);
