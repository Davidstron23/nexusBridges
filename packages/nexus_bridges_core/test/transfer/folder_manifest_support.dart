import 'dart:convert';
import 'dart:typed_data';

import 'package:nexus_bridges_core/src/protocol/protocol.dart';
import 'package:nexus_bridges_core/src/transfer/manifest.dart';
import 'package:nexus_bridges_core/src/transfer/messages.dart';

final String hashA = 'a' * 64;

String folderLine(int parent, String name) => '[$parent,${jsonEncode(name)}]';

String fileLine(int parent, String name, int size, [String? sha256]) =>
    '[$parent,${jsonEncode(name)},$size,"${sha256 ?? hashA}"]';

Uint8List linesToBytes(List<String> lines) =>
    Uint8List.fromList(utf8.encode(lines.map((line) => '$line\n').join()));

FolderOfferRequest declare({
  required int entries,
  required int manifestBytes,
  int? files,
  int bytes = Limits.maxTransferSize,
  int depth = Limits.maxFolderDepth,
  int longest = 0,
  String name = 'root',
}) => FolderOfferRequest(
  transfer: 'a' * 32,
  name: name,
  entries: entries,
  files: files ?? entries,
  bytes: bytes,
  depth: depth,
  longest: longest,
  manifestBytes: manifestBytes,
);

FolderOfferRequest declareFor(FolderManifest manifest, Uint8List encoded) =>
    declare(
      entries: manifest.length,
      manifestBytes: encoded.length,
      files: manifest.files,
      bytes: manifest.totalBytes,
      depth: manifest.depth,
      longest: manifest.longest,
    );

typedef ReadResult = ({FolderManifest? manifest, ManifestRefusal? refusal});

ManifestRefusal? feedWhole(ManifestReader reader, Uint8List bytes) =>
    reader.add(bytes);

ManifestRefusal? feedByByte(ManifestReader reader, Uint8List bytes) {
  for (var i = 0; i < bytes.length; i++) {
    final refusal = reader.add(Uint8List.sublistView(bytes, i, i + 1));
    if (refusal != null) return refusal;
  }
  return null;
}

ManifestRefusal? feedChunks(
  ManifestReader reader,
  Uint8List bytes,
  Iterable<int> sizes,
) {
  var position = 0;
  final iterator = sizes.iterator;
  while (position < bytes.length) {
    final size = iterator.moveNext() ? iterator.current : bytes.length;
    final end = position + size > bytes.length ? bytes.length : position + size;
    final refusal = reader.add(Uint8List.sublistView(bytes, position, end));
    if (refusal != null) return refusal;
    position = end;
  }
  return null;
}

ReadResult readAll(
  Uint8List bytes,
  FolderOfferRequest declared, {
  Iterable<int>? chunkSizes,
}) {
  final reader = ManifestReader(declared);
  final refusal = chunkSizes == null
      ? feedWhole(reader, bytes)
      : feedChunks(reader, bytes, chunkSizes);
  if (refusal != null) return (manifest: null, refusal: refusal);
  return reader.close();
}

ManifestRefusal? addRefusal(List<String> lines) {
  final bytes = linesToBytes(lines);
  final declared = declare(entries: lines.length, manifestBytes: bytes.length);
  final whole = feedWhole(ManifestReader(declared), bytes);
  final single = feedByByte(ManifestReader(declared), bytes);
  if (whole != single) {
    throw StateError('whole $whole differs from byte by byte $single');
  }
  return whole;
}

({FolderManifest manifest, Uint8List encoded}) sampleTree() {
  final builder = ManifestBuilder();
  final src = builder.addFolder(0, 'src');
  final deep = builder.addFolder(src, 'b');
  builder.addFolder(0, 'docs');
  final a = builder.addFile(src, 'a.txt', 5);
  builder.setFile(a, 5, Uint8List.fromList(List.filled(32, 0xAB)));
  final c = builder.addFile(deep, 'c.txt', 7);
  builder.setFile(c, 7, Uint8List.fromList(List.filled(32, 0xCD)));
  final manifest = builder.build();
  return (manifest: manifest, encoded: encodeManifest(manifest));
}
