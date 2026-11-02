@TestOn('windows')
@Tags(['large'])
library;

import 'dart:io';

import 'package:nexus_bridges_core/src/protocol/protocol.dart' show Limits;
import 'package:nexus_bridges_core/src/transfer/folder_size.dart';
import 'package:nexus_bridges_core/src/transfer/transfer.dart' show AbortSignal;
import 'package:test/test.dart';

import 'receiver_harness.dart' show realFs;

void main() {
  test(
    'Q-4 the walk stops at the entry limit and returns what it had added',
    () async {
      final dir = await Directory.systemTemp.createTemp('nexus_size_large_');
      final root = (await realFs.realPath(dir.path))!;
      addTearDown(() async {
        try {
          await Directory(root).delete(recursive: true);
        } catch (_) {}
      });
      final count = Limits.folderMeasureMaxEntries + 1;
      for (var i = 0; i < count; i++) {
        File('$root\\f$i').writeAsBytesSync(const [1]);
      }

      final bytes = await measureFolderSize(
        root,
        exclusions: null,
        abort: AbortSignal(),
      );

      expect(bytes, Limits.folderMeasureMaxEntries);
    },
    timeout: const Timeout(Duration(minutes: 10)),
  );
}
