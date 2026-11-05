import 'dart:convert';
import 'dart:io';

import 'package:nexus_bridges_core/src/peers/peers.dart';
import 'package:nexus_bridges_core/src/storage/storage.dart';
import 'package:test/test.dart';

const String ownerPrint =
    'AB12AB12AB12AB12AB12AB12AB12AB12AB12AB12AB12AB12AB12AB12AB12AB12';
final String peerA = 'A' * 64;
final String peerB = 'B' * 64;
final String peerC = 'C' * 64;
final String rootOne = '1' * 32;
final String rootTwo = '2' * 32;
final DateTime sampleAt = DateTime.utc(2026, 11, 1, 10);

SavedDestination place(
  String name, {
  String? root,
  List<String> path = const [],
  bool home = false,
}) => SavedDestination(
  rootId: root ?? rootOne,
  rootName: name,
  path: path,
  home: home,
);

HistoryEntry historyEntry(
  String name, {
  HistoryDirection direction = HistoryDirection.sent,
  bool isFolder = false,
  int fileCount = 0,
  int itemCount = 1,
  int delivered = 1,
  int size = 10,
  String? destinationRoot,
  bool destinationHome = false,
  List<String> destinationPath = const [],
  String outcome = 'saved',
  DateTime? at,
}) => HistoryEntry(
  at: at ?? sampleAt,
  direction: direction,
  name: name,
  isFolder: isFolder,
  fileCount: fileCount,
  itemCount: itemCount,
  delivered: delivered,
  size: size,
  destinationRoot: destinationRoot,
  destinationHome: destinationHome,
  destinationPath: destinationPath,
  outcome: outcome,
);

final class NotesBench {
  NotesBench(this.dir);

  final Directory dir;

  File get file => File('${dir.path}\\peers.json');

  JsonFileStore get store => JsonFileStore(file);

  static Future<NotesBench> create() async {
    final dir = await Directory.systemTemp.createTemp('nexus_peer_notes_');
    addTearDown(() async {
      for (var attempt = 0; attempt < 40; attempt++) {
        try {
          if (dir.existsSync()) await dir.delete(recursive: true);
          return;
        } on FileSystemException {
          await Future<void>.delayed(const Duration(milliseconds: 25));
        }
      }
    });
    return NotesBench(dir);
  }

  PeerNotes notes({Duration writeDelay = const Duration(hours: 1)}) =>
      PeerNotes(
        store,
        ownerFingerprint: ownerPrint,
        writeDelay: writeDelay,
        now: () => DateTime.utc(2026, 11, 2, 9),
      );

  Future<PeerNotes> reopen({
    bool Function(String)? isPaired,
    void Function(bool loaded)? onLoad,
  }) async {
    final fresh = notes();
    final loaded = await fresh.load(isPaired: isPaired ?? (_) => true);
    onLoad?.call(loaded);
    return fresh;
  }

  List<String> get names =>
      [for (final entity in dir.listSync()) entity.path.split(r'\').last]
        ..sort();

  List<String> get quarantined => [
    for (final name in names)
      if (name.startsWith('peers.json.')) name,
  ];

  void writeRaw(Object? json) =>
      file.writeAsStringSync(json is String ? json : jsonEncode(json));

  Map<String, Object?> readJson() =>
      jsonDecode(file.readAsStringSync()) as Map<String, Object?>;

  void blockWrites() => Directory(file.path).createSync();

  void unblockWrites() => Directory(file.path).deleteSync();
}

Map<String, Object?> validDestination({
  String? root,
  String rootName = 'Documentos',
  bool home = false,
  List<Object?> path = const ['prueba-007'],
}) => {
  'root': root ?? rootOne,
  'rootName': rootName,
  'home': home,
  'path': path,
};

Map<String, Object?> validHistory() => {
  'at': '2026-11-01T10:00:00.000Z',
  'dir': 'sent',
  'name': 'mod.zip',
  'folder': false,
  'files': 0,
  'items': 3,
  'delivered': 3,
  'size': 123,
  'destRoot': 'Documentos',
  'destHome': false,
  'destPath': ['mods'],
  'outcome': 'saved',
};

Map<String, Object?> validPeer({String? fingerprint}) => {
  'fingerprint': fingerprint ?? peerA,
  'alias': 'Casa',
  'favorites': [validDestination()],
  'recent': [validDestination(root: rootTwo)],
  'history': [validHistory()],
};

Map<String, Object?> validFile({List<Object?>? peers, String? owner}) => {
  'version': 1,
  'owner': owner ?? ownerPrint,
  'peers': peers ?? [validPeer()],
};
