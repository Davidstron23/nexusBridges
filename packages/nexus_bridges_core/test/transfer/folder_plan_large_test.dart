@TestOn('windows')
@Tags(['large'])
library;

import 'dart:io';

import 'package:nexus_bridges_core/src/protocol/protocol.dart';
import 'package:nexus_bridges_core/src/transfer/folder_plan.dart';
import 'package:nexus_bridges_core/src/transfer/folder_walk.dart';
import 'package:nexus_bridges_core/src/transfer/transfer.dart';
import 'package:nexus_bridges_core/src/transfer/windows_folder_io.dart';
import 'package:test/test.dart';

import 'receiver_harness.dart' show realFs;

const Duration walkBudget = Duration(seconds: 10);

Future<String> bigTree() async {
  final dir = await Directory.systemTemp.createTemp('nexus_plan_large_');
  addTearDown(() async {
    for (var attempt = 0; attempt < 20; attempt++) {
      if (deleteTreeNoFollowSync(dir.path)) return;
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
  });
  final root = (await realFs.realPath(dir.path))!;
  final perFolder = (Limits.maxFolderEntries ~/ 10) - 1;
  for (var folder = 0; folder < 10; folder++) {
    Directory('$root\\d$folder').createSync();
    for (var i = 0; i < perFolder; i++) {
      File('$root\\d$folder\\f$i.dat').createSync();
    }
  }
  return root;
}

void main() {
  test('E480 and E414: a hundred thousand entries are walked within the '
      'budget and one more is refused before anything is hashed', () async {
    final root = await bigTree();

    final clock = Stopwatch()..start();
    final walk = walkFolder(
      lister: const WindowsFolderLister(),
      rootPath: root,
      exclusions: const {},
      dataDirRealPath: '',
    );
    clock.stop();
    stdout.writeln(
      'walk of ${walk.builder.length} entries: ${clock.elapsedMilliseconds} ms',
    );

    expect(walk.stopped, isNull);
    expect(walk.builder.length, Limits.maxFolderEntries);
    expect(clock.elapsed, lessThan(walkBudget));

    File('$root\\one-more.dat').createSync();
    final reports = <(int, int)>[];
    final job = FolderPlanJob.start(
      rootRealPath: root,
      name: 'big',
      exclusions: const [],
      dataDirPath: '',
      dataDirRealPath: '',
      onProgress: (entries, hashed) => reports.add((entries, hashed)),
    );
    final result = await job.result.timeout(const Duration(minutes: 2));

    expect(result, isA<PlanStopped>());
    expect((result as PlanStopped).outcome, TransferOutcome.tooManyEntries);
    expect(reports.where((p) => p.$2 > 0), isEmpty);
  }, timeout: const Timeout(Duration(minutes: 10)));
}
