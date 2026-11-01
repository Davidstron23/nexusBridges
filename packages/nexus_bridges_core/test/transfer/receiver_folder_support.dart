import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:nexus_bridges_core/src/identity/identity.dart';
import 'package:nexus_bridges_core/src/protocol/protocol.dart';
import 'package:nexus_bridges_core/src/transfer/manifest.dart';
import 'package:nexus_bridges_core/src/transfer/messages.dart';
import 'package:nexus_bridges_core/src/transport/transport.dart';
import 'package:test/test.dart';

import 'folder_writer_support.dart';
import 'receiver_harness.dart';

export 'folder_writer_support.dart' show TreeEntry, WriterTree, buildTree;

const int kib = 1024;

final Uint8List smallFile = Uint8List.fromList(utf8.encode('hello folder'));

final class FolderJob {
  FolderJob(this.tree, this.encoded, this.declared);

  final WriterTree tree;
  final Uint8List encoded;
  final FolderOfferRequest declared;

  FolderManifest get manifest => tree.manifest;

  String get transfer => declared.transfer;

  Uint8List get stream => tree.stream;
}

String newId() => newTransferId();

FolderJob folderJob(
  List<TreeEntry> entries, {
  String name = 'proyecto',
  String? transfer,
}) {
  final tree = buildTree(entries);
  final encoded = encodeManifest(tree.manifest);
  final manifest = tree.manifest;
  return FolderJob(
    tree,
    encoded,
    FolderOfferRequest(
      transfer: transfer ?? newId(),
      name: name,
      entries: manifest.length,
      files: manifest.files,
      bytes: manifest.totalBytes,
      depth: manifest.depth,
      longest: manifest.longest,
      manifestBytes: encoded.length,
    ),
  );
}

FolderJob flatFolders(int count, {String name = 'proyecto'}) {
  final builder = ManifestBuilder();
  for (var i = 0; i < count; i++) {
    builder.addFolder(0, 'f${i.toString().padLeft(6, '0')}');
  }
  final manifest = builder.build();
  final encoded = encodeManifest(manifest);
  return FolderJob(
    WriterTree(manifest, const [], const {}),
    encoded,
    FolderOfferRequest(
      transfer: newId(),
      name: name,
      entries: manifest.length,
      files: 0,
      bytes: 0,
      depth: manifest.depth,
      longest: manifest.longest,
      manifestBytes: encoded.length,
    ),
  );
}

({FolderOfferRequest declared, Uint8List bytes}) trapManifest(
  List<String> lines, {
  String name = 'proyecto',
  Uint8List? raw,
}) {
  final bytes =
      raw ??
      Uint8List.fromList(utf8.encode(lines.map((line) => '$line\n').join()));
  final entries = max(1, bytes.where((byte) => byte == 10).length);
  if (bytes.length < entries * 6) {
    throw StateError('trap too short for the offer: ${bytes.length}');
  }
  return (
    declared: FolderOfferRequest(
      transfer: newId(),
      name: name,
      entries: entries,
      files: 0,
      bytes: 0,
      depth: 1,
      longest: 0,
      manifestBytes: bytes.length,
    ),
    bytes: bytes,
  );
}

Stream<List<int>> chunked(Uint8List bytes, [int size = 64 * kib]) async* {
  for (var i = 0; i < bytes.length; i += size) {
    yield Uint8List.sublistView(bytes, i, min(i + size, bytes.length));
  }
}

RawReply answered(StreamPostResult result) {
  if (result is StreamPostFailed) {
    fail('post failed with ${result.failure.name} after ${result.sent}');
  }
  final response = (result as StreamPostAnswered).response;
  return RawReply(response.status, Uint8List.fromList(response.body));
}

Map<String, String> headersFor(String transfer, String? permit) => {
  TransferHeaders.transfer: transfer,
  TransferHeaders.permit: ?permit,
};

final class HeldBody {
  HeldBody() {
    addTearDown(() {
      if (!_controller.isClosed) unawaited(_controller.close());
    });
  }

  final StreamController<List<int>> _controller = StreamController<List<int>>();

  Stream<List<int>> get stream => _controller.stream;

  void send(List<int> bytes) => _controller.add(bytes);

  void finish() => unawaited(_controller.close());

  void breakOff() => _controller.addError(StateError('source closed'));
}

extension FolderClient on ReceiverStack {
  Future<RawReply?> offerFolder(
    Peer peer,
    FolderOfferRequest declared, {
    Map<String, Object?> extra = const {},
  }) => post(peer.identity, ApiPaths.transferOffer, {
    ...declared.toJson(),
    ...extra,
  });

  Future<String> askManifest(Peer peer, FolderOfferRequest declared) async {
    final reply = await offerFolder(peer, declared);
    expect(reply, isNotNull);
    expect(reply!.status, 202, reason: reply.text);
    expect(reply.json.keys.toSet(), {'state', 'permit'});
    expect(reply.state, 'manifest');
    final permit = reply.json['permit'] as String;
    expect(permit, matches(hex32));
    return permit;
  }

  Future<StreamPostResult> postManifest(
    Peer peer, {
    required String transfer,
    required String? permit,
    required Uint8List bytes,
    Stream<List<int>>? body,
    int? contentLength,
    DeviceIdentity? as,
    int slice = 64 * kib,
  }) => postUpload(
    as ?? peer.identity,
    path: ApiPaths.transferManifest,
    headers: headersFor(transfer, permit),
    contentLength: contentLength ?? bytes.length,
    body: body ?? chunked(bytes, slice),
  );

  Future<RawReply> sendManifest(
    Peer peer,
    FolderJob job,
    String permit, {
    Uint8List? bytes,
  }) async => answered(
    await postManifest(
      peer,
      transfer: job.transfer,
      permit: permit,
      bytes: bytes ?? job.encoded,
    ),
  );

  Future<RawReply> sendFolder(Peer peer, FolderJob job, String permit) async =>
      answered(
        await postUpload(
          peer.identity,
          headers: headersFor(job.transfer, permit),
          contentLength: job.stream.length,
          body: chunked(job.stream),
        ),
      );

  Future<String> acceptedPermit(Peer peer, FolderJob job) async {
    final permit = await askManifest(peer, job.declared);
    final reply = await sendManifest(peer, job, permit);
    expect(reply.status, 200, reason: reply.text);
    expect(reply.state, 'accepted', reason: reply.text);
    return reply.json['permit'] as String;
  }
}

Set<String> everythingUnder(String root) => {
  for (final entity in Directory(
    root,
  ).listSync(recursive: true, followLinks: false))
    entity.path.substring(root.length + 1).toLowerCase(),
};

Future<void> endedQuietly(ReceiverStack s) =>
    eventually(() => !s.coordinator.busy, reason: 'the session ended');

void expectNothingShown(ReceiverStack s) {
  expect(s.incoming, isNull);
  expect(s.seen, isEmpty);
  expect(s.coordinator.lastReceived, isNull);
  expect(s.events, isEmpty);
}
