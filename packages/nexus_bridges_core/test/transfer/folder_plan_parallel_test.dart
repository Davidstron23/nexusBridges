@TestOn('windows')
library;

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:ffi/ffi.dart';
import 'package:nexus_bridges_core/src/protocol/protocol.dart';
import 'package:nexus_bridges_core/src/transfer/folder_plan.dart';
import 'package:nexus_bridges_core/src/transfer/manifest.dart';
import 'package:nexus_bridges_core/src/transfer/transfer.dart';
import 'package:nexus_bridges_core/src/transfer/windows_folder_io.dart';
import 'package:test/test.dart';
import 'package:win32/win32.dart';

import 'folder_plan_test.dart'
    show
        PlanRun,
        dataFolder,
        hardLink,
        hexOf,
        long,
        markerContent,
        runPlan,
        scratchRoot,
        startPlan,
        write;

const int mebibyte = 1024 * 1024;

Uint8List patterned(int seed, int length) {
  final bytes = Uint8List(length);
  for (var i = 0; i < length; i++) {
    bytes[i] = (i * 31 + seed * 7 + (i >> 8)) & 0xff;
  }
  return bytes;
}

void writeFiles(String root, int count) {
  for (var n = 0; n < count; n++) {
    write('$root\\${n.isEven ? 'a' : 'b'}\\file$n.txt', 'content of file $n');
  }
}

void writeBlank(String path, int bytes) {
  File(path).createSync(recursive: true);
  File(path).openSync(mode: FileMode.write)
    ..truncateSync(bytes)
    ..closeSync();
}

int expectPlanMatchesDisk(PlanRun run, String root) {
  final manifest = run.manifest;
  final buffer = allocateReadBuffer();
  var files = 0;
  var total = 0;
  try {
    for (var i = 1; i <= manifest.length; i++) {
      if (manifest.isFolder(i)) continue;
      final path = '$root\\${manifest.relativePath(i)}';
      final bytes = File(path).readAsBytesSync();
      final id = hashFileSync(
        path,
        buffer: buffer,
        isCancelled: () => false,
      ) as FileHashed;
      expect(manifest.sizeOf(i), bytes.length, reason: path);
      expect(hexOf(manifest.hashOf(i)), sha256.convert(bytes).toString());
      expect(run.plan.fileVolumes[files], id.volume, reason: path);
      expect(run.plan.fileIndexes[files], id.index, reason: path);
      files++;
      total += bytes.length;
    }
  } finally {
    freeReadBuffer(buffer);
  }
  expect(run.plan.fileVolumes.length, files);
  expect(run.plan.fileIndexes.length, files);
  expect(run.plan.summary.files, files);
  expect(run.plan.summary.totalBytes, total);
  return files;
}

List<String> filesInOrder(PlanRun run) => [
  for (var i = 1; i <= run.manifest.length; i++)
    if (!run.manifest.isFolder(i)) run.manifest.relativePath(i),
];

Win32Result<HANDLE> holdExclusive(String path) => using((arena) {
  return CreateFile(
    arena.pcwstr(path),
    0x80000000,
    FILE_SHARE_MODE(0),
    null,
    OPEN_EXISTING,
    FILE_FLAGS_AND_ATTRIBUTES(0x80),
    null,
  );
});

Future<void> expectDeletable(String root) async {
  final waited = Stopwatch()..start();
  while (!deleteTreeNoFollowSync(root)) {
    expect(
      waited.elapsed,
      lessThan(const Duration(seconds: 4)),
      reason: 'a reader still holds a file',
    );
    await Future<void>.delayed(const Duration(milliseconds: 100));
  }
}

Future<void> expectHealthyPlan() async {
  final root = await scratchRoot();
  writeFiles(root, 20);
  final run = await runPlan(root);
  expect(run.result, isA<PlanReady>());
  expect(expectPlanMatchesDisk(run, root), 20);
}

void main() {
  group('Cambio 1, RF-258: the summaries of many files are exact', () {
    test('a mixed folder gives the manifest, sizes, SHA-256, identities and '
        'summary that the disk dictates, twice the same', () async {
      final base = await scratchRoot();
      final root = '$base\\root';
      for (var d = 0; d < 4; d++) {
        for (var f = 0; f < 8; f++) {
          write('$root\\d$d\\f$f.txt', 'file $d $f');
        }
      }
      write('$root\\d1\\nested\\deep.txt', 'deep');
      write('$root\\d1\\nested\\deeper\\deepest.txt', 'deepest');
      write('$root\\empty0.txt', '');
      write('$root\\d2\\empty1.txt', '');
      write('$root\\big.bin', patterned(3, 3 * mebibyte + 17));
      write('$root\\tool.exe', 'MZ');
      Directory('$root\\empty folder').createSync();
      hardLink('$root\\d1\\twin.txt', '$root\\d0\\f0.txt');
      final data = await dataFolder(root);
      hardLink('$root\\d0\\key-link.bin', '$data\\identity\\private-key.dpapi');
      hardLink('$root\\d3\\cert-link.bin', '$data\\identity\\certificate.pem');

      final first = await runPlan(root, dataDir: data);
      final second = await runPlan(root, dataDir: data);

      expect(first.result, isA<PlanReady>());
      expect(expectPlanMatchesDisk(first, root), 39);
      expect(first.plan.summary.protectedOmitted, 3);
      expect(first.plan.summary.containsPrograms, isTrue);
      expect(first.plan.summary.linksOmitted, 0);
      expect(first.plan.summary.blockedOmitted, 0);
      expect(first.plan.summary.folders, first.manifest.folders);
      expect(first.files, isNot(contains('d0\\key-link.bin')));
      expect(first.files, isNot(contains('d3\\cert-link.bin')));
      expect(first.files, contains('big.bin'));
      expect(first.files, contains('empty0.txt'));
      expect(first.folders, contains('empty folder'));
      expect(first.paths, isNot(contains('NexusBridges')));
      expect([
        for (var i = 1; i <= first.manifest.length; i++)
          if (!first.manifest.isFolder(i)) hexOf(first.manifest.hashOf(i)),
      ], isNot(contains(sha256.convert(markerContent.codeUnits).toString())));
      expect(encodeManifest(second.manifest), encodeManifest(first.manifest));
      expect(second.plan.fileVolumes, first.plan.fileVolumes);
      expect(second.plan.fileIndexes, first.plan.fileIndexes);
      expect(second.plan.summary.protectedOmitted, 3);
    }, timeout: long);

    test('a folder of only text files does not report programs on the '
        'parallel path', () async {
      final root = await scratchRoot();
      writeFiles(root, 24);

      final run = await runPlan(root);

      expect(expectPlanMatchesDisk(run, root), 24);
      expect(run.plan.summary.containsPrograms, isFalse);
      expect(run.plan.summary.protectedOmitted, 0);
    }, timeout: long);

    for (final count in [15, 16, 17]) {
      test('$count files give the exact manifest and identities', () async {
        final root = await scratchRoot();
        for (var n = 0; n < count; n++) {
          write('$root\\${n % 3}\\file$n.bin', patterned(n, 100 + n * 977));
        }

        final run = await runPlan(root);

        expect(run.result, isA<PlanReady>());
        expect(expectPlanMatchesDisk(run, root), count);
      }, timeout: long);
    }
  });

  group('Cambio 1, RF-257: protected files are never read by any reader', () {
    test('sixteen hard links to the data folder are all dropped and the '
        'summary stays empty', () async {
      final base = await scratchRoot();
      final data = await dataFolder(base);
      final root = '$base\\root';
      Directory(root).createSync();
      for (var n = 0; n < 16; n++) {
        hardLink('$root\\link$n.bin', '$data\\identity\\private-key.dpapi');
      }

      final run = await runPlan(root, dataDir: data);

      expect(run.result, isA<PlanReady>());
      expect(run.plan.summary.protectedOmitted, 16);
      expect(run.plan.summary.files, 0);
      expect(run.plan.fileIndexes, isEmpty);
      expect(run.plan.fileVolumes, isEmpty);
      expect(run.files, isEmpty);
    }, timeout: long);
  });

  group('Cambio 1, RF-262: the first failure in manifest order wins', () {
    final cases = <Set<int>>[
      {6, 9},
      {5, 10},
      {0, 41},
      {41},
    ];
    for (final locked in cases) {
      test('files at positions $locked held in exclusive stop the plan with '
          'the earliest of them', () async {
        final root = await scratchRoot();
        for (var n = 0; n < 42; n++) {
          write('$root\\${n % 3}\\file$n.txt', 'content $n');
        }
        final order = filesInOrder(await runPlan(root));
        final handles = [
          for (final position in locked)
            holdExclusive('$root\\${order[position]}'),
        ];
        try {
          for (final handle in handles) {
            expect(handle.value.isValid, isTrue);
          }

          final run = await runPlan(root);

          expect(run.result, isA<PlanStopped>());
          final stopped = run.result as PlanStopped;
          expect(stopped.outcome, TransferOutcome.unreadable);
          expect(
            stopped.problemPath,
            order[locked.reduce((a, b) => a < b ? a : b)],
          );
        } finally {
          for (final handle in handles) {
            if (handle.value.isValid) handle.value.close();
          }
        }
      }, timeout: long);
    }
  });

  group('Cambio 1, RF-258: cancelling with several readers', () {
    test('cancel() in the middle of sixteen big files ends cancelled in '
        'time, frees every file and leaves the process healthy', () async {
      final root = await scratchRoot();
      for (var n = 0; n < 16; n++) {
        writeBlank('$root\\big$n.bin', 128 * mebibyte);
      }
      final job = startPlan(root);
      await Future<void>.delayed(const Duration(milliseconds: 250));
      final clock = Stopwatch()..start();

      job.cancel();
      final result = await job.result.timeout(const Duration(seconds: 5));

      expect(result, isA<PlanCancelled>());
      expect(clock.elapsed, lessThan(Limits.workerStopGrace));
      await expectDeletable(root);
      await Future<void>.delayed(const Duration(milliseconds: 1500));
      await expectHealthyPlan();
    }, timeout: long);

    test('cancel() at any moment while the readers start never hangs or '
        'breaks the next plan', () async {
      final root = await scratchRoot();
      writeFiles(root, 64);
      for (final delay in [0, 2, 5, 10, 20, 40, 80, 120]) {
        final job = startPlan(root);
        await Future<void>.delayed(Duration(milliseconds: delay));

        job.cancel();
        final result = await job.result.timeout(const Duration(seconds: 5));

        expect(result, anyOf(isA<PlanCancelled>(), isA<PlanReady>()));
      }
      await Future<void>.delayed(const Duration(milliseconds: 1500));
      await expectDeletable(root);
      await expectHealthyPlan();
    }, timeout: long);
  });

  group('Cambio 1, RF-258: progress with several readers', () {
    test(
      'progress never goes back and ends at the number of summaries',
      () async {
        final root = await scratchRoot();
        writeFiles(root, 20);
        for (var n = 0; n < 4; n++) {
          writeBlank('$root\\big$n.bin', 96 * mebibyte);
        }
        final reports = <(int, int)>[];
        final job = startPlan(
          root,
          onProgress: (entries, hashed) => reports.add((entries, hashed)),
        );

        final result = await job.result.timeout(const Duration(seconds: 90));
        await Future<void>.delayed(const Duration(milliseconds: 500));

        expect(result, isA<PlanReady>());
        expect(reports, isNotEmpty);
        for (var i = 1; i < reports.length; i++) {
          expect(reports[i].$1, greaterThanOrEqualTo(reports[i - 1].$1));
          expect(reports[i].$2, greaterThanOrEqualTo(reports[i - 1].$2));
        }
        expect(reports.last.$2, 24);
        expect(reports.every((report) => report.$2 <= 24), isTrue);
      },
      timeout: long,
    );
  });
}
