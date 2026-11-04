import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:nexus_bridges_core/src/transfer/folder_stream.dart';
import 'package:nexus_bridges_core/src/transfer/folder_writer.dart';
import 'package:nexus_bridges_core/src/transfer/manifest.dart';
import 'package:nexus_bridges_core/src/transfer/windows_folder_io.dart';
import 'package:nexus_bridges_core/src/winio/winio.dart';
import 'package:test/test.dart';
import 'package:win32/win32.dart' show HANDLE;

import 'folders_fakes.dart' show windowsFs;

bool failEveryMark(HANDLE parent, String name) => false;

bool failMarkOfTwo(HANDLE parent, String name) =>
    name == 'two.txt' ? false : markFromInternetSync(parent, name);

bool failClearHidden(HANDLE handle) => false;

const String zoneText = '[ZoneTransfer]\r\nZoneId=3\r\n';

typedef TreeEntry = (String path, Uint8List? data);

final class WriterTree {
  WriterTree(this.manifest, this.frames, this.paths);

  final FolderManifest manifest;
  final List<Uint8List> frames;
  final Map<String, Uint8List?> paths;

  Uint8List get stream {
    final builder = BytesBuilder(copy: false);
    for (final frame in frames) {
      builder.add(frame);
    }
    return builder.takeBytes();
  }
}

Uint8List content(int seed, int length) {
  final bytes = Uint8List(length);
  var state = (seed * 2654435761 + 12345) & 0xFFFFFFFF;
  for (var i = 0; i < length; i++) {
    state = (state * 1664525 + 1013904223) & 0xFFFFFFFF;
    bytes[i] = state >> 24;
  }
  return bytes;
}

WriterTree buildTree(List<TreeEntry> entries) {
  final builder = ManifestBuilder();
  final indexes = <String, int>{'': 0};
  final datas = <int, Uint8List>{};
  final paths = <String, Uint8List?>{};
  for (final (path, data) in entries) {
    final cut = path.lastIndexOf(r'\');
    final parent = cut < 0 ? '' : path.substring(0, cut);
    final name = cut < 0 ? path : path.substring(cut + 1);
    final parentIndex = indexes[parent]!;
    if (data == null) {
      indexes[path] = builder.addFolder(parentIndex, name);
    } else {
      final index = builder.addFile(parentIndex, name, data.length);
      builder.setFile(
        index,
        data.length,
        Uint8List.fromList(sha256.convert(data).bytes),
      );
      indexes[path] = index;
      datas[index] = data;
    }
    paths[path] = data;
  }
  final manifest = builder.build();
  final frames = <Uint8List>[];
  for (final index in manifest.fileIndexes) {
    final data = datas[index]!;
    final frame = BytesBuilder(copy: false)
      ..add(encodeFrameHeader(index, data.length))
      ..add(data)
      ..addByte(0);
    frames.add(frame.takeBytes());
  }
  return WriterTree(manifest, frames, paths);
}

final class WriterRun {
  WriterRun(this.tempFolder);

  final String tempFolder;
  final List<FolderWriteFailed> failures = [];
  final List<(int, int)> progress = [];
  int activity = 0;
  late final FolderWriterHost host;

  Future<void> feed(Uint8List bytes, {int slice = 262144}) async {
    for (var offset = 0; offset < bytes.length; offset += slice) {
      final end = offset + slice < bytes.length ? offset + slice : bytes.length;
      if (host.add(Uint8List.sublistView(bytes, offset, end))) {
        final drained = Completer<void>();
        host.onDrained(drained.complete);
        await drained.future;
      }
    }
  }

  Future<void> waitFor(
    bool Function() condition, {
    Duration limit = const Duration(seconds: 20),
  }) async {
    final clock = Stopwatch()..start();
    while (!condition()) {
      if (clock.elapsed > limit) fail('timed out waiting for the writer');
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
  }
}

Future<WriterRun> startRun(
  String tempFolder,
  WriterTree tree, {
  bool supportsMark = true,
  MarkFile? markFile,
  ClearHidden? clearHidden,
}) async {
  final run = WriterRun(tempFolder);
  run.host = await FolderWriterHost.start(
    tempFolder: tempFolder,
    manifest: tree.manifest,
    supportsMark: supportsMark,
    markFile: markFile,
    clearHidden: clearHidden,
    onProgress: (files, bytes) => run.progress.add((files, bytes)),
    onActivity: () => run.activity++,
    onFailure: run.failures.add,
  );
  return run;
}

Future<String> realTempFolder([String prefix = 'nexus_t6_']) async {
  final dir = await Directory.systemTemp.createTemp(prefix);
  addTearDown(() async {
    for (var attempt = 0; attempt < 20; attempt++) {
      if (deleteTreeNoFollowSync(dir.path)) return;
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
  });
  final real = await windowsFs.realPath(dir.path);
  expect(real, isNotNull);
  return real!;
}

String readMark(String filePath) {
  try {
    return File('${extendedPath(filePath)}:Zone.Identifier').readAsStringSync();
  } on FileSystemException {
    return '';
  }
}

List<String> namesOf(String folder) =>
    Directory(folder)
        .listSync(followLinks: false)
        .map((e) => e.path.substring(e.path.lastIndexOf(r'\') + 1))
        .toList()
      ..sort();
