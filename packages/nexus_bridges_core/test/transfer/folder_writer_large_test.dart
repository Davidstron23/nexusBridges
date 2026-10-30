@TestOn('windows')
@Tags(['large'])
library;

import 'dart:io';

import 'package:nexus_bridges_core/src/transfer/folder_writer.dart';
import 'package:test/test.dart';

import 'folder_writer_support.dart';

const Duration writeBudget = Duration(seconds: 30);
const int folderCount = 100;
const int filesPerFolder = 100;
const int fileBytes = 10240;

void main() {
  test('E595: ten thousand small files are written inside the budget with the '
      'real-time scanner on', () async {
    final temp = await realTempFolder('nexus_t6_perf_');
    final entries = <TreeEntry>[];
    for (var d = 0; d < folderCount; d++) {
      entries.add(('d$d', null));
      for (var f = 0; f < filesPerFolder; f++) {
        entries.add((
          'd$d\\f$f.dat',
          content(d * filesPerFolder + f, fileBytes),
        ));
      }
    }
    final tree = buildTree(entries);
    final stream = tree.stream;
    final clock = Stopwatch()..start();
    final run = await startRun(temp, tree);
    final started = clock.elapsedMilliseconds;
    await run.feed(stream, slice: 1048576);
    final fed = clock.elapsedMilliseconds;
    final result = await run.host.finish();
    clock.stop();
    stdout.writeln(
      'E595: ${tree.manifest.files} files of $fileBytes bytes, '
      'start $started ms, fed $fed ms, total ${clock.elapsedMilliseconds} ms',
    );

    expect(result, isA<FolderWritten>());
    expect(run.failures, isEmpty);
    expect(clock.elapsed, lessThan(writeBudget));
    final root = run.host.tempRoot;
    expect(
      File('$root\\d0\\f0.dat').readAsBytesSync(),
      tree.paths['d0\\f0.dat'],
    );
    expect(
      File('$root\\d99\\f99.dat').readAsBytesSync(),
      tree.paths['d99\\f99.dat'],
    );
    expect(readMark('$root\\d50\\f50.dat'), zoneText);
    run.host.close();
    await Future<void>.delayed(const Duration(milliseconds: 100));
    await run.host.discard();
    expect(Directory(root).existsSync(), isFalse);
  }, timeout: const Timeout(Duration(minutes: 5)));
}
