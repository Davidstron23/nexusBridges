@TestOn('windows')
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:ffi/ffi.dart';
import 'package:nexus_bridges_core/src/pairing/pairing.dart';
import 'package:nexus_bridges_core/src/protocol/protocol.dart';
import 'package:nexus_bridges_core/src/transfer/folder_plan.dart';
import 'package:nexus_bridges_core/src/transfer/folder_send.dart';
import 'package:nexus_bridges_core/src/transfer/folder_stream.dart'
    show encodeFrameHeader;
import 'package:nexus_bridges_core/src/transfer/manifest.dart'
    show FolderManifest;
import 'package:nexus_bridges_core/src/transfer/transfer.dart';
import 'package:nexus_bridges_core/src/transport/transport.dart'
    show AbortSignal;
import 'package:test/test.dart';
import 'package:win32/win32.dart';

import 'folder_writer_support.dart' show content;
import 'transfer_stacks_harness.dart';

const Timeout long = Timeout(Duration(seconds: 90));

const int kib = 1024;

const String zoneMark = '[ZoneTransfer]\r\nZoneId=3\r\n';

const String keyContent = 'private key bytes that must never leave';

void write(String path, [Object text = 'x']) {
  File(path).parent.createSync(recursive: true);
  if (text is List<int>) {
    File(path).writeAsBytesSync(text, flush: true);
  } else {
    File(path).writeAsStringSync('$text', flush: true);
  }
}

void junction(String link, String target) {
  final made = Process.runSync('cmd', ['/c', 'mklink', '/J', link, target]);
  expect(made.exitCode, 0, reason: '${made.stdout}${made.stderr}');
  addTearDown(() {
    if (FileSystemEntity.typeSync(link, followLinks: false) !=
        FileSystemEntityType.notFound) {
      Process.runSync('cmd', ['/c', 'rmdir', link]);
    }
  });
}

void hardLink(String link, String target) {
  final made = Process.runSync('cmd', ['/c', 'mklink', '/H', link, target]);
  expect(made.exitCode, 0, reason: '${made.stdout}${made.stderr}');
}

bool trySymlink(String link, String target) {
  try {
    Link(link).createSync(target);
  } on FileSystemException {
    return false;
  }
  addTearDown(() {
    try {
      Link(link).deleteSync();
    } on FileSystemException {
      return;
    }
  });
  return true;
}

HANDLE holdWithoutSharing(String path) {
  final handle = using((arena) {
    final Win32Result(value: handle) = CreateFile(
      arena.pcwstr(path),
      0x80000000,
      FILE_SHARE_MODE(0),
      null,
      OPEN_EXISTING,
      FILE_FLAGS_AND_ATTRIBUTES(0x80),
      null,
    );
    return handle;
  });
  expect(handle.isValid, isTrue, reason: 'could not hold $path');
  addTearDown(() {
    if (handle.isValid) handle.close();
  });
  return handle;
}

String latin(List<int> bytes) => latin1.decode(bytes);

bool containsBytes(List<int> haystack, List<int> needle) =>
    latin(haystack).contains(latin(needle));

Map<String, String?> treeOf(String root) {
  final tree = <String, String?>{};
  for (final entity in Directory(
    root,
  ).listSync(recursive: true, followLinks: false)) {
    final relative = entity.path.substring(root.length + 1);
    tree[relative] = entity is File ? entity.readAsStringSync() : null;
  }
  return tree;
}

List<String> namesIn(String folder) => [
  for (final entity in Directory(folder).listSync(followLinks: false))
    entity.path.substring(folder.length + 1),
]..sort();

bool anyFileContains(String root, List<int> needle) {
  for (final entity in Directory(
    root,
  ).listSync(recursive: true, followLinks: false)) {
    if (entity is File && containsBytes(entity.readAsBytesSync(), needle)) {
      return true;
    }
  }
  return false;
}

Future<FolderManifest> manifestOf(String root) async {
  final plan = await planOf(root);
  return plan.manifest;
}

Future<FolderPlan> planOf(String root, {String dataDir = ''}) async {
  final job = FolderPlanJob.start(
    rootRealPath: root,
    name: root.substring(root.lastIndexOf('\\') + 1),
    exclusions: defaultExclusions,
    dataDirPath: dataDir,
    dataDirRealPath: dataDir,
    onProgress: (entries, hashed) {},
  );
  final result = await job.result.timeout(const Duration(seconds: 60));
  expect(result, isA<PlanReady>());
  return (result as PlanReady).plan;
}

final class EntryHook {
  FolderManifest? manifest;
  final List<String> seen = [];
  FutureOr<void> Function(String path)? action;

  Future<void> call(int entry) async {
    final known = manifest;
    final path = known == null ? '#$entry' : known.relativePath(entry);
    seen.add(path);
    final run = action;
    if (run != null) await run(path);
  }
}

final class ScriptedExclusions implements ExclusionSource {
  ScriptedExclusions(this.next);

  List<String>? next;
  Object? failure;
  int loads = 0;

  @override
  Future<List<String>?> load() async {
    loads++;
    final error = failure;
    if (error != null) throw error;
    final names = next;
    return names == null ? null : List<String>.of(names);
  }
}

Future<(TransferStack, TransferStack)> stacks({
  EntryHook? hook,
  ExclusionSource exclusions = const NoExclusionSource(),
  PeerRelation senderAtReceiver = PeerRelation.mine,
}) async {
  final a = await TransferStack.start(
    name: 'A',
    address: hostA,
    beforeStreamEntry: hook?.call,
    exclusions: exclusions,
  );
  final b = await TransferStack.start(name: 'B', address: hostB);
  await link(
    a,
    b,
    senderAtReceiver: senderAtReceiver,
    senderName: 'PORTATIL',
    receiverName: 'SOBREMESA',
  );
  return (a, b);
}

Future<TransferResultView?> startSend(
  TransferStack a,
  TransferStack b,
  String path,
) => a.coordinator.sendElement(
  a.targetOf(b),
  path,
  refresh: () => a.targetOf(b),
);

Future<(TransferResultView?, TransferResultView, TransferResultView)> sendOne(
  TransferStack a,
  TransferStack b,
  String path, {
  TransferResultView? afterSent,
  TransferResultView? afterReceived,
}) async {
  final returned = await startSend(
    a,
    b,
    path,
  ).timeout(const Duration(seconds: 40));
  final sent = await a.sentResult(after: afterSent);
  final received = await b.receivedResult(after: afterReceived);
  return (returned, sent, received);
}

Future<TransferResultView?> refusedHere(
  TransferStack a,
  TransferStack b,
  String path, {
  TransferResultView? after,
}) async {
  final returned = await startSend(
    a,
    b,
    path,
  ).timeout(const Duration(seconds: 20));
  await settle(const Duration(milliseconds: 200));
  expect(b.offersReceived, 0, reason: 'no offer for $path');
  expect(b.lastReceived, isNull, reason: 'nothing at the receiver for $path');
  expect(a.outgoingSeen, isEmpty, reason: 'no session for $path');
  expect(identical(returned, after), isFalse);
  return returned;
}

Future<void> receiverUntouched(TransferStack b) async {
  await eventually(
    () =>
        !Directory(b.tempSub).existsSync() &&
        b.journal.folders.isEmpty &&
        b.incoming == null,
    reason: '${b.name} left as it was',
  );
  expect(namesIn(b.receiveDir), isEmpty);
}

List<int> frameOf(int index, List<int> bytes) => [
  ...encodeFrameHeader(index, bytes.length),
  ...bytes,
  0,
];

final class StreamRun {
  StreamRun(this.bytes, this.problems, this.error);

  final Uint8List bytes;
  final List<int> problems;
  final Object? error;
}

Future<StreamRun> drain(
  FolderPlan plan, {
  Future<void> Function(int entry)? beforeEntry,
}) async {
  final out = BytesBuilder(copy: false);
  final problems = <int>[];
  Object? error;
  try {
    await for (final chunk in folderStream(
      plan,
      abort: AbortSignal(),
      onEntryProblem: (entry) async => problems.add(entry),
      beforeEntry: beforeEntry ?? (entry) async {},
    )) {
      out.add(chunk);
    }
  } catch (e) {
    error = e;
  }
  return StreamRun(out.takeBytes(), problems, error);
}

int indexOfPath(FolderManifest manifest, String path) {
  for (var i = 1; i <= manifest.length; i++) {
    if (manifest.relativePath(i) == path) return i;
  }
  fail('$path is not in the manifest');
}

Future<void> expectSameProblem(
  TransferStack a,
  TransferStack b,
  Future<TransferResultView?> returned,
  String problemPath,
) async {
  final result = await returned.timeout(const Duration(seconds: 40));
  final sent = await a.sentResult();
  final received = await b.receivedResult();
  expect(result, sent);
  expect(sent.outcome, TransferOutcome.unreadable);
  expect(sent.problemPath, problemPath);
  expect(sent.isFolder, isTrue);
  expect(received.outcome, TransferOutcome.unreadable);
  expect(received.problemPath, problemPath);
  final cancels = b.bodiesOn(ApiPaths.transferCancel);
  expect(cancels, isNotEmpty);
  expect(cancels.first['reason'], 'unreadable');
  expect(cancels.first['entry'], isA<int>());
  await receiverUntouched(b);
}

String? freeDriveLetter() {
  for (final letter in 'QRSTUVWXYZPONMLKJ'.split('')) {
    if (!Directory('$letter:\\').existsSync()) return letter;
  }
  return null;
}

void main() {
  group('E403, RF-254: the exclusion list in force when the send starts', () {
    Future<String> projectWithExcludable(TransferStack a) async {
      final root = '${a.sourceDir}\\proj';
      write('$root\\keep.txt', 'keep');
      write('$root\\node_modules\\pkg\\index.js', 'module');
      write('$root\\build\\out.bin', 'built');
      write('$root\\.dart_tool\\cache', 'tool');
      write('$root\\vendor\\lib.txt', 'vendored');
      return root;
    }

    test('a valid list is used, and null, an invalid name, too many names or '
        'a failing source fall back to the default list', () async {
      final source = ScriptedExclusions(null);
      final (a, b) = await stacks(exclusions: source);
      final root = await projectWithExcludable(a);
      const withDefaults = {
        'keep.txt': 'keep',
        'vendor': null,
        'vendor\\lib.txt': 'vendored',
      };
      final cases = <String, (void Function(), Map<String, String?>)>{
        'a valid list': (
          () => source.next = ['vendor'],
          {
            'keep.txt': 'keep',
            'node_modules': null,
            'node_modules\\pkg': null,
            'node_modules\\pkg\\index.js': 'module',
            'build': null,
            'build\\out.bin': 'built',
            '.dart_tool': null,
            '.dart_tool\\cache': 'tool',
          },
        ),
        'null': (() => source.next = null, withDefaults),
        'an invalid name': (
          () => source.next = ['vendor', 'bad:name'],
          withDefaults,
        ),
        'more than 64 names': (
          () => source.next = ['vendor', for (var i = 0; i < 64; i++) 'n$i'],
          withDefaults,
        ),
        'a source that throws': (
          () => source
            ..next = ['vendor']
            ..failure = const FileSystemException('unreadable'),
          withDefaults,
        ),
      };

      TransferResultView? lastSent;
      TransferResultView? lastReceived;
      var loads = 0;
      for (final MapEntry(key: label, value: (arrange, expected))
          in cases.entries) {
        source.failure = null;
        arrange();
        final (_, sent, received) = await sendOne(
          a,
          b,
          root,
          afterSent: lastSent,
          afterReceived: lastReceived,
        );
        lastSent = sent;
        lastReceived = received;
        loads++;

        expect(sent.outcome, TransferOutcome.saved, reason: label);
        expect(received.fileName, sent.fileName, reason: label);
        expect(
          treeOf('${b.receiveDir}\\${received.fileName}'),
          expected,
          reason: label,
        );
        expect(source.loads, loads, reason: '$label reads the list once');
      }
    }, timeout: long);

    test('an empty saved list leaves nothing out', () async {
      final source = ScriptedExclusions(const []);
      final (a, b) = await stacks(exclusions: source);
      final root = await projectWithExcludable(a);

      final (_, sent, received) = await sendOne(a, b, root);

      expect(sent.outcome, TransferOutcome.saved);
      expect(
        treeOf('${b.receiveDir}\\${received.fileName}').keys.toSet(),
        containsAll(<String>[
          'keep.txt',
          'node_modules\\pkg\\index.js',
          'build\\out.bin',
          '.dart_tool\\cache',
          'vendor\\lib.txt',
        ]),
      );
    }, timeout: long);

    test('changing the list once the send started does not change the '
        'manifest in progress; the next send reads the new one', () async {
      final source = ScriptedExclusions(['vendor']);
      final hook = EntryHook();
      final (a, b) = await stacks(exclusions: source, hook: hook);
      final root = await projectWithExcludable(a);
      hook.action = (path) {
        source.next = ['vendor', 'node_modules', 'build', '.dart_tool'];
      };

      final (_, sent, received) = await sendOne(a, b, root);

      expect(sent.outcome, TransferOutcome.saved);
      expect(source.loads, 1);
      final first = treeOf('${b.receiveDir}\\${received.fileName}');
      expect(first.keys, containsAll(<String>['keep.txt', 'build\\out.bin']));
      expect(first.keys, isNot(contains('vendor')));

      hook.action = null;
      final (_, nextSent, nextReceived) = await sendOne(
        a,
        b,
        root,
        afterSent: sent,
        afterReceived: received,
      );

      expect(nextSent.outcome, TransferOutcome.saved);
      expect(source.loads, 2);
      expect(treeOf('${b.receiveDir}\\${nextReceived.fileName}'), {
        'keep.txt': 'keep',
      });
    }, timeout: long);
  });

  group('E406, RF-256: a chosen folder that is a junction', () {
    test('its content is sent under the name of the junction', () async {
      final (a, b) = await stacks();
      final real = '${a.sourceDir}\\real-project';
      write('$real\\src\\main.txt', 'main');
      write('$real\\readme.txt', 'readme');
      final alias = '${a.sourceDir}\\alias';
      junction(alias, real);

      final (returned, sent, received) = await sendOne(a, b, alias);

      expect(sent.outcome, TransferOutcome.saved);
      expect(sent.fileName, 'alias');
      expect(returned, sent);
      expect(received.outcome, TransferOutcome.saved);
      expect(received.fileName, 'alias');
      expect(b.bodiesOn(ApiPaths.transferOffer).single['name'], 'alias');
      expect(treeOf('${b.receiveDir}\\alias'), {
        'readme.txt': 'readme',
        'src': null,
        'src\\main.txt': 'main',
      });
      expect(namesIn(b.receiveDir), ['alias']);
    }, timeout: long);
  });

  group('E413 and E589, RF-259: the summary of the sender', () {
    test('once prepared the outgoing view carries files, total, excluded '
        'folders and their size, links, protected and blocked, and the '
        'offer leaves without any confirmation', () async {
      final gate = Gate<void>(null);
      final hook = EntryHook()..action = (path) => gate.wait();
      final (a, b) = await stacks(hook: hook);
      final root = '${a.sourceDir}\\proj';
      write('$root\\src\\main.txt', 'main text');
      write('$root\\.env', 'API=1');
      write('$root\\node_modules\\pkg\\index.js', content(1, 1000));
      write('$root\\build\\out.bin', content(2, 2500));
      write('$root\\desktop.ini', '[.ShellClassInfo]');
      write('${a.base}\\outside\\o.txt', 'outside');
      junction('$root\\to-outside', '${a.base}\\outside');
      write('${a.dataDir}\\identity\\private-key.dpapi', keyContent);
      hardLink('$root\\copy.bin', '${a.dataDir}\\identity\\private-key.dpapi');

      final returned = startSend(a, b, root);
      await gate.reached.future.timeout(const Duration(seconds: 30));

      expect(b.offersReceived, 1);
      await eventually(
        () => a.outgoing?.summary?.excludedBytesPartial == false,
        reason: 'the size of the excluded folders measured',
      );
      final view = a.outgoing!;
      expect(view.isFolder, isTrue);
      expect(view.fileName, 'proj');
      expect(view.fileCount, 2);
      expect(view.size, 'main text'.length + 'API=1'.length);
      expect(
        view.summary,
        FolderSummaryView(
          files: 2,
          folders: 1,
          totalBytes: 'main text'.length + 'API=1'.length,
          excludedFolders: 2,
          excludedBytes: 3500,
          linksOmitted: 1,
          protectedOmitted: 1,
          blockedOmitted: 1,
          containsPrograms: view.summary!.containsPrograms,
        ),
      );
      gate.open(null);
      final result = await returned.timeout(const Duration(seconds: 40));
      final received = await b.receivedResult();

      expect(result?.outcome, TransferOutcome.saved);
      expect(result?.size, 'main text'.length + 'API=1'.length);
      expect(result?.fileCount, 2);
      expect(received.outcome, TransferOutcome.saved);
      expect(treeOf('${b.receiveDir}\\proj'), {
        '.env': 'API=1',
        'src': null,
        'src\\main.txt': 'main text',
      });
    }, timeout: long);

    test('a folder without excluded folders reports the size as known at '
        'once', () async {
      final gate = Gate<void>(null);
      final hook = EntryHook()..action = (path) => gate.wait();
      final (a, b) = await stacks(hook: hook);
      final root = '${a.sourceDir}\\plain';
      write('$root\\a.txt', 'a');

      final returned = startSend(a, b, root);
      await gate.reached.future.timeout(const Duration(seconds: 30));

      final summary = a.outgoing!.summary!;
      expect(summary.excludedFolders, 0);
      expect(summary.excludedBytes, 0);
      expect(summary.excludedBytesPartial, isFalse);
      gate.open(null);
      expect(
        (await returned.timeout(const Duration(seconds: 40)))?.outcome,
        TransferOutcome.saved,
      );
    }, timeout: long);
  });

  group('E416 [SEG], RF-262: a file held in exclusive halfway', () {
    test('opened without sharing just before the sender opens it: both see '
        'unreadable with its path and the receive folder stays as it '
        'was', () async {
      final hook = EntryHook();
      final (a, b) = await stacks(hook: hook);
      final root = '${a.sourceDir}\\proj';
      for (final name in ['a.txt', 'b.txt', 'c.txt', 'd.txt']) {
        write('$root\\$name', 'contents of $name');
      }
      final manifest = await manifestOf(root);
      hook.manifest = manifest;
      final order = [
        for (final i in manifest.fileIndexes) manifest.relativePath(i),
      ];
      final second = order[1];
      hook.action = (path) {
        if (path == second) holdWithoutSharing('$root\\$path');
      };

      final returned = startSend(a, b, root);

      await expectSameProblem(a, b, returned, second);
      expect(hook.seen, order.sublist(0, 2));
      expect(
        b.bodiesOn(ApiPaths.transferCancel).first['entry'],
        indexOfPath(manifest, second),
      );
    }, timeout: long);

    test('a byte range lock on a large second file: the same result with its '
        'path and none of it saved', () async {
      final hook = EntryHook();
      final (a, b) = await stacks(hook: hook);
      final root = '${a.sourceDir}\\proj';
      write('$root\\a.bin', content(1, 100 * kib));
      write('$root\\b.bin', content(2, 600 * kib));
      write('$root\\c.bin', content(3, 100 * kib));
      final manifest = await manifestOf(root);
      hook.manifest = manifest;
      final order = [
        for (final i in manifest.fileIndexes) manifest.relativePath(i),
      ];
      final second = order[1];
      hook.action = (path) async {
        if (path == second) await lockExclusively('$root\\$path');
      };

      final returned = startSend(a, b, root);

      await expectSameProblem(a, b, returned, second);
    }, timeout: long);
  });

  group('E417 [SEG], RF-262: a file that changes halfway', () {
    test('bytes appended to the third file: both see unreadable with its '
        'path', () async {
      final hook = EntryHook();
      final (a, b) = await stacks(hook: hook);
      final root = '${a.sourceDir}\\proj';
      for (final name in ['a.txt', 'b.txt', 'c.txt', 'd.txt']) {
        write('$root\\$name', 'contents of $name');
      }
      final manifest = await manifestOf(root);
      hook.manifest = manifest;
      final order = [
        for (final i in manifest.fileIndexes) manifest.relativePath(i),
      ];
      final third = order[2];
      hook.action = (path) {
        if (path == third) {
          File(
            '$root\\$path',
          ).writeAsStringSync(' and more', mode: FileMode.append, flush: true);
        }
      };

      final returned = startSend(a, b, root);

      await expectSameProblem(a, b, returned, third);
      expect(hook.seen, order.sublist(0, 3));
    }, timeout: long);

    test('a large third file that grows: the same result', () async {
      final hook = EntryHook();
      final (a, b) = await stacks(hook: hook);
      final root = '${a.sourceDir}\\proj';
      write('$root\\a.bin', content(1, 100 * kib));
      write('$root\\b.bin', content(2, 100 * kib));
      write('$root\\c.bin', content(3, 400 * kib));
      final manifest = await manifestOf(root);
      hook.manifest = manifest;
      final order = [
        for (final i in manifest.fileIndexes) manifest.relativePath(i),
      ];
      final third = order[2];
      hook.action = (path) {
        if (path == third) {
          File('$root\\$path').writeAsBytesSync(
            content(4, kib),
            mode: FileMode.append,
            flush: true,
          );
        }
      };

      final returned = startSend(a, b, root);

      await expectSameProblem(a, b, returned, third);
    }, timeout: long);

    test('a small file rewritten in place with the same size: the summary '
        'does not match, unreadable on both sides and none of its new '
        'bytes saved', () async {
      final hook = EntryHook();
      final (a, b) = await stacks(hook: hook);
      final root = '${a.sourceDir}\\proj';
      write('$root\\a.txt', 'first file');
      write('$root\\b.txt', 'ORIGINAL-CONTENT');
      write('$root\\c.txt', 'last file');
      final manifest = await manifestOf(root);
      hook.manifest = manifest;
      hook.action = (path) {
        if (path == 'b.txt') {
          File('$root\\b.txt')
              .writeAsStringSync('REWRITTEN-BYTES!', flush: true);
        }
      };

      final returned = startSend(a, b, root);

      await expectSameProblem(a, b, returned, 'b.txt');
      expect(anyFileContains(b.base, utf8.encode('REWRITTEN-BYTES!')), isFalse);
    }, timeout: long);
  });

  group('E602 [SEG], punto 8: a file swapped for a link after the plan', () {
    test('a symbolic link to an outside file of the same size: no byte of it '
        'leaves and both see unreadable with its path', () async {
      final hook = EntryHook();
      final (a, b) = await stacks(hook: hook);
      final root = '${a.sourceDir}\\proj';
      final secret = content(9, 200 * kib);
      write('$root\\a.txt', 'first');
      write('$root\\f.bin', content(1, 200 * kib));
      write('$root\\z.txt', 'last');
      write('${a.base}\\outside\\secret.bin', secret);
      final probe = '${a.base}\\outside\\probe';
      if (!trySymlink(probe, '${a.base}\\outside\\secret.bin')) {
        markTestSkipped('symbolic links need a privilege or developer mode');
        return;
      }
      final manifest = await manifestOf(root);
      hook.manifest = manifest;
      hook.action = (path) {
        if (path != 'f.bin') return;
        File('$root\\f.bin').deleteSync();
        expect(
          trySymlink('$root\\f.bin', '${a.base}\\outside\\secret.bin'),
          isTrue,
        );
      };

      final returned = startSend(a, b, root);

      await expectSameProblem(a, b, returned, 'f.bin');
      expect(anyFileContains(b.base, secret.sublist(5000, 5064)), isFalse);
    }, timeout: long);

    test('a folder swapped for a junction to an outside folder whose file '
        'has the same bytes: refused by identity, unreadable on both '
        'sides', () async {
      final hook = EntryHook();
      final (a, b) = await stacks(hook: hook);
      final root = '${a.sourceDir}\\proj';
      final same = content(5, 150 * kib);
      write('$root\\a.txt', 'first');
      write('$root\\m\\f.bin', same);
      write('$root\\z.txt', 'last');
      write('${a.base}\\outside\\f.bin', same);
      final manifest = await manifestOf(root);
      hook.manifest = manifest;
      hook.action = (path) {
        if (path != 'm\\f.bin') return;
        Directory('$root\\m').renameSync('$root\\moved');
        junction('$root\\m', '${a.base}\\outside');
      };

      final returned = startSend(a, b, root);

      await expectSameProblem(a, b, returned, 'm\\f.bin');
      expect(File('${a.base}\\outside\\f.bin').readAsBytesSync(), same);
    }, timeout: long);

    test('a file swapped for a hard link to an outside file of the same size '
        'is refused too', () async {
      final hook = EntryHook();
      final (a, b) = await stacks(hook: hook);
      final root = '${a.sourceDir}\\proj';
      final secret = content(11, 120 * kib);
      write('$root\\a.txt', 'first');
      write('$root\\f.bin', content(12, 120 * kib));
      write('${a.base}\\outside\\secret.bin', secret);
      final manifest = await manifestOf(root);
      hook.manifest = manifest;
      hook.action = (path) {
        if (path != 'f.bin') return;
        File('$root\\f.bin').deleteSync();
        hardLink('$root\\f.bin', '${a.base}\\outside\\secret.bin');
      };

      final returned = startSend(a, b, root);

      await expectSameProblem(a, b, returned, 'f.bin');
      expect(anyFileContains(b.base, secret.sublist(7000, 7064)), isFalse);
    }, timeout: long);

    group('the flow itself', () {
      test('without changes it carries every file, empty ones and those of '
          'several chunks, framed in manifest order', () async {
        final root = (await realFs.realPath(
          (await transferFolder('nexus_t8_flow_')).path,
        ))!;
        final files = <String, List<int>>{
          'a.txt': utf8.encode('alpha'),
          'empty.txt': const [],
          'big.bin': content(3, 700 * kib),
          'sub\\c.txt': utf8.encode('gamma'),
        };
        files.forEach((name, bytes) => write('$root\\$name', bytes));
        final plan = await planOf(root);

        final run = await drain(plan);

        expect(run.error, isNull);
        expect(run.problems, isEmpty);
        final expected = <int>[];
        for (final index in plan.manifest.fileIndexes) {
          expected.addAll(
            frameOf(index, files[plan.manifest.relativePath(index)]!),
          );
        }
        expect(run.bytes.length, expected.length);
        expect(run.bytes, expected);
      }, timeout: long);

      Future<void> swappedFlow(
        void Function(String root, String outsideFile) swap, {
        bool needsSymlink = false,
      }) async {
        final base = (await realFs.realPath(
          (await transferFolder('nexus_t8_swap_')).path,
        ))!;
        final root = '$base\\proj';
        final secret = content(21, 300 * kib);
        write('$root\\a.txt', 'first file');
        write('$root\\f.bin', content(22, 300 * kib));
        write('$root\\z.txt', 'last file');
        write('$base\\outside\\secret.bin', secret);
        if (needsSymlink &&
            !trySymlink(
              '$base\\outside\\probe',
              '$base\\outside\\secret.bin',
            )) {
          markTestSkipped('symbolic links need a privilege or developer mode');
          return;
        }
        final plan = await planOf(root);
        final target = indexOfPath(plan.manifest, 'f.bin');
        final before = <int>[];
        for (final index in plan.manifest.fileIndexes) {
          if (index == target) break;
          before.addAll(
            frameOf(
              index,
              File('$root\\${plan.manifest.relativePath(index)}')
                  .readAsBytesSync(),
            ),
          );
        }

        final run = await drain(
          plan,
          beforeEntry: (entry) async {
            if (entry == target) swap(root, '$base\\outside\\secret.bin');
          },
        );

        expect(run.error, isA<FolderEntryProblem>());
        expect((run.error as FolderEntryProblem).entry, target);
        expect(run.problems, [target]);
        expect(
          run.bytes.length,
          lessThanOrEqualTo(before.length + encodeFrameHeader(1, 1).length),
        );
        final shared = run.bytes.length < before.length
            ? run.bytes.length
            : before.length;
        expect(run.bytes.sublist(0, shared), before.sublist(0, shared));
        for (var at = 0; at + 64 <= secret.length; at += 4096) {
          expect(
            containsBytes(run.bytes, secret.sublist(at, at + 64)),
            isFalse,
            reason: 'outside bytes at $at',
          );
        }
      }

      test('a symbolic link put in place of a file sends nothing of the '
          'outside file, not even its first chunk', () async {
        await swappedFlow((root, outside) {
          File('$root\\f.bin').deleteSync();
          expect(trySymlink('$root\\f.bin', outside), isTrue);
        }, needsSymlink: true);
      }, timeout: long);

      test('a hard link put in place of a file sends nothing of it', () async {
        await swappedFlow((root, outside) {
          File('$root\\f.bin').deleteSync();
          hardLink('$root\\f.bin', outside);
        });
      }, timeout: long);

      test('a file held without sharing ends the flow at that file with '
          'nothing of it', () async {
        await swappedFlow((root, outside) {
          holdWithoutSharing('$root\\f.bin');
        });
      }, timeout: long);
    });
  });

  group('E419, RF-306: whole drives are never sent', () {
    test('a subst drive over the test folder, written in several ways, ends '
        'as wholeDrive without asking anything', () async {
      final (a, b) = await stacks();
      final letter = freeDriveLetter();
      if (letter == null) {
        markTestSkipped('no free drive letter for subst');
        return;
      }
      write('${a.sourceDir}\\drive\\file.txt', 'on the drive');
      final made = Process.runSync('subst', [
        '$letter:',
        '${a.sourceDir}\\drive',
      ]);
      expect(made.exitCode, 0, reason: '${made.stdout}${made.stderr}');
      addTearDown(() => Process.runSync('subst', ['$letter:', '/D']));
      expect(File('$letter:\\file.txt').existsSync(), isTrue);

      TransferResultView? last;
      for (final path in ['$letter:\\', '$letter:', '\\\\?\\$letter:\\']) {
        final result = await refusedHere(a, b, path, after: last);
        expect(result?.outcome, TransferOutcome.wholeDrive, reason: path);
        expect(result?.outcome.kind, TransferResultKind.rejected, reason: path);
        last = result;
      }
    }, timeout: long);

    test('a junction to C:\\ is resolved and ends as wholeDrive', () async {
      final (a, b) = await stacks();
      final door = '${a.sourceDir}\\whole';
      junction(door, 'C:\\');

      final result = await refusedHere(a, b, door);

      expect(result?.outcome, TransferOutcome.wholeDrive);
    }, timeout: long);
  });

  group('E420, RF-307: a shortcut as an element', () {
    test('a .lnk in any case is a shortcut and no offer leaves', () async {
      final (a, b) = await stacks();
      TransferResultView? last;
      for (final name in ['acceso.lnk', 'OTRO.LNK']) {
        final path = await a.sourceFile(name, utf8.encode('L shortcut'));
        final result = await refusedHere(a, b, path, after: last);
        expect(result?.outcome, TransferOutcome.shortcut, reason: name);
        expect(result?.fileName, name);
        last = result;
      }
    }, timeout: long);
  });

  group('E421, RF-302: a compressed file travels as a file', () {
    test('a .zip is offered as a file and arrives byte for byte, marked and '
        'not unpacked', () async {
      final (a, b) = await stacks();
      write('${a.sourceDir}\\inside\\note.txt', 'packed note');
      final zip = '${a.sourceDir}\\paquete.zip';
      final made = Process.runSync('powershell', [
        '-NoProfile',
        '-NonInteractive',
        '-Command',
        "Compress-Archive -Path '${a.sourceDir}\\inside\\note.txt' "
            "-DestinationPath '$zip'",
      ]);
      expect(made.exitCode, 0, reason: '${made.stdout}${made.stderr}');
      final bytes = File(zip).readAsBytesSync();
      expect(bytes.sublist(0, 2), utf8.encode('PK'));

      final (returned, sent, received) = await sendOne(a, b, zip);

      expect(sent.outcome, TransferOutcome.saved);
      expect(sent.fileName, 'paquete.zip');
      expect(sent.isFolder, isFalse);
      expect(sent.size, bytes.length);
      expect(returned, sent);
      expect(received.outcome, TransferOutcome.saved);
      expect(received.fileName, 'paquete.zip');
      expect(received.isProgram, sent.isProgram);
      final offer = b.bodiesOn(ApiPaths.transferOffer).single;
      expect(offer['kind'], isNull);
      expect(offer['name'], 'paquete.zip');
      expect(offer['size'], bytes.length);
      expect(offer['sha256'], sha256.convert(bytes).toString());
      expect(File('${b.receiveDir}\\paquete.zip').readAsBytesSync(), bytes);
      expect(
        File('${b.receiveDir}\\paquete.zip:Zone.Identifier').readAsStringSync(),
        zoneMark,
      );
      expect(namesIn(b.receiveDir), ['paquete.zip']);
    }, timeout: long);
  });

  group('E422, RF-313: an element that does not exist', () {
    test('a missing file and a path under a missing folder end as notFound '
        'without asking anything', () async {
      final (a, b) = await stacks();
      TransferResultView? last;
      for (final path in [
        '${a.sourceDir}\\gone.txt',
        '${a.sourceDir}\\missing\\deeper\\proj',
      ]) {
        final result = await refusedHere(a, b, path, after: last);
        expect(result?.outcome, TransferOutcome.notFound, reason: path);
        expect(result?.outcome.kind, TransferResultKind.failed, reason: path);
        last = result;
      }
    }, timeout: long);
  });

  group('E423 [SEG], RF-257: the data folder as a loose element', () {
    test('the key by its path, through a junction to identity and through a '
        'hard link, the identity folder and the data folder itself are all '
        'protectedData', () async {
      final (a, b) = await stacks();
      final key = '${a.dataDir}\\identity\\private-key.dpapi';
      write(key, keyContent);
      junction('${a.sourceDir}\\door', '${a.dataDir}\\identity');
      hardLink('${a.sourceDir}\\copia.bin', key);
      write('${a.receiveDir}\\.nexusbridges-incoming\\half.partial', 'half');

      TransferResultView? last;
      for (final path in [
        key,
        '${a.sourceDir}\\door\\private-key.dpapi',
        '${a.sourceDir}\\copia.bin',
        '${a.dataDir}\\identity',
        a.dataDir,
        '${a.receiveDir}\\.nexusbridges-incoming\\half.partial',
      ]) {
        final result = await refusedHere(a, b, path, after: last);
        expect(result?.outcome, TransferOutcome.protectedData, reason: path);
        last = result;
      }
      expect(anyFileContains(b.base, utf8.encode(keyContent)), isFalse);
    }, timeout: long);

    test(
      'a hard link to a file outside the data folder is still sent',
      () async {
        final (a, b) = await stacks();
        write('${a.base}\\other\\shared.txt', 'shared bytes');
        hardLink('${a.sourceDir}\\twin.txt', '${a.base}\\other\\shared.txt');

        final (_, sent, received) = await sendOne(
          a,
          b,
          '${a.sourceDir}\\twin.txt',
        );

        expect(sent.outcome, TransferOutcome.saved);
        expect(received.outcome, TransferOutcome.saved);
        expect(
          File('${b.receiveDir}\\twin.txt').readAsStringSync(),
          'shared bytes',
        );
      },
      timeout: long,
    );
  });

  group('E593, punto 11: the name of the chosen folder itself', () {
    test('an invalid or blocked folder name ends before planning, with that '
        'name as the problem and nothing asked', () async {
      final (a, b) = await stacks();
      final cases = <String, TransferOutcome>{
        'evil\u202Etxt.exe': TransferOutcome.invalidName,
        'zero\u200Bwidth': TransferOutcome.invalidName,
        'x.{645FF040-5081-101B-9F08-00AA002F954E}': TransferOutcome.blockedType,
        'desktop.ini': TransferOutcome.blockedType,
      };
      TransferResultView? last;
      for (final MapEntry(key: name, value: outcome) in cases.entries) {
        final root = '${a.sourceDir}\\$name';
        write('$root\\inside.txt', 'inside');
        final result = await refusedHere(a, b, root, after: last);
        expect(result?.outcome, outcome, reason: name);
        expect(result?.problemPath, name, reason: name);
        last = result;
      }
    }, timeout: long);
  });

  group('E605, RF-256 end to end: links never reach the receiver', () {
    test('junctions and symbolic links to outside and to an own subfolder are '
        'not created and nothing of their targets arrives', () async {
      final (a, b) = await stacks();
      final outside = '${a.base}\\outside';
      write('$outside\\marker-outside.txt', 'outside bytes');
      final root = '${a.sourceDir}\\proj';
      write('$root\\own.txt', 'own');
      write('$root\\sub\\inner.txt', 'inner');
      junction('$root\\to-outside', outside);
      junction('$root\\to-own', '$root\\sub');
      final folderLinked = trySymlink('$root\\sym-folder', outside);
      final fileLinked = trySymlink(
        '$root\\sym-file.txt',
        '$outside\\marker-outside.txt',
      );

      final (_, sent, received) = await sendOne(a, b, root);

      expect(sent.outcome, TransferOutcome.saved);
      expect(received.outcome, TransferOutcome.saved);
      expect(a.lastSent?.fileCount, 2);
      expect(treeOf('${b.receiveDir}\\proj'), {
        'own.txt': 'own',
        'sub': null,
        'sub\\inner.txt': 'inner',
      });
      expect(anyFileContains(b.base, utf8.encode('outside bytes')), isFalse);
      final linkSummary = a.outgoingSeen
          .map((v) => v.summary)
          .whereType<FolderSummaryView>()
          .last;
      expect(
        linkSummary.linksOmitted,
        2 + (folderLinked ? 1 : 0) + (fileLinked ? 1 : 0),
      );
    }, timeout: long);
  });

  group('E606, RF-303 end to end: blocked types stay out', () {
    test('desktop.ini and a .LNK are left out, the receiver accepts the '
        'folder and saves it without them', () async {
      final (a, b) = await stacks();
      final root = '${a.sourceDir}\\proj';
      write('$root\\desktop.ini', '[.ShellClassInfo]');
      write('$root\\sub\\enlace.LNK', 'link');
      write('$root\\sub\\real.txt', 'real');
      write('$root\\top.txt', 'top');

      final (_, sent, received) = await sendOne(a, b, root);

      expect(sent.outcome, TransferOutcome.saved);
      expect(received.outcome, TransferOutcome.saved);
      expect(b.bodiesOn(ApiPaths.transferOffer).single['files'], 2);
      expect(treeOf('${b.receiveDir}\\proj'), {
        'sub': null,
        'sub\\real.txt': 'real',
        'top.txt': 'top',
      });
      final summary = a.outgoingSeen
          .map((v) => v.summary)
          .whereType<FolderSummaryView>()
          .last;
      expect(summary.blockedOmitted, 2);
    }, timeout: long);
  });

  group('E607 [SEG], RF-257 end to end: the data folder never reaches the '
      'receiver', () {
    test('a folder with a hard link to the key and a junction to the data '
        'folder arrives without either and without the key bytes', () async {
      final (a, b) = await stacks();
      final key = '${a.dataDir}\\identity\\private-key.dpapi';
      write(key, keyContent);
      final root = '${a.sourceDir}\\proj';
      write('$root\\keep.txt', 'keep');
      hardLink('$root\\copy.bin', key);
      junction('$root\\door', a.dataDir);

      final (_, sent, received) = await sendOne(a, b, root);

      expect(sent.outcome, TransferOutcome.saved);
      expect(received.outcome, TransferOutcome.saved);
      expect(treeOf('${b.receiveDir}\\proj'), {'keep.txt': 'keep'});
      expect(anyFileContains(b.base, utf8.encode(keyContent)), isFalse);
      final summary = a.outgoingSeen
          .map((v) => v.summary)
          .whereType<FolderSummaryView>()
          .last;
      expect(summary.protectedOmitted, 1);
      expect(summary.linksOmitted, 1);
    }, timeout: long);
  });

  group('T8 done: a repository folder between two real stacks', () {
    test('.git, .env, empty folders, a junction and desktop.ini: both see '
        'saved with the final name and the tree arrives without the link '
        'or the blocked file', () async {
      final (a, b) = await stacks();
      final root = '${a.sourceDir}\\repo';
      write('$root\\.git\\HEAD', 'ref: refs/heads/main');
      write('$root\\.git\\objects\\pack\\p.pack', 'pack bytes');
      write('$root\\.env', 'API_URL=local');
      write('$root\\lib\\main.txt', 'main');
      Directory('$root\\empty\\deeper').createSync(recursive: true);
      write('$root\\desktop.ini', '[.ShellClassInfo]');
      write('${a.base}\\outside\\o.txt', 'outside bytes');
      junction('$root\\door', '${a.base}\\outside');
      Process.runSync('attrib', ['+r', '$root\\.git\\objects\\pack\\p.pack']);
      Process.runSync('attrib', ['+h', '$root\\.git']);
      write('${b.receiveDir}\\repo\\old.txt', 'already here');

      final (returned, sent, received) = await sendOne(a, b, root);

      expect(sent.outcome, TransferOutcome.saved);
      expect(sent.fileName, 'repo (1)');
      expect(returned, sent);
      expect(received.outcome, TransferOutcome.saved);
      expect(received.fileName, 'repo (1)');
      expect(treeOf('${b.receiveDir}\\repo (1)'), {
        '.env': 'API_URL=local',
        '.git': null,
        '.git\\HEAD': 'ref: refs/heads/main',
        '.git\\objects': null,
        '.git\\objects\\pack': null,
        '.git\\objects\\pack\\p.pack': 'pack bytes',
        'empty': null,
        'empty\\deeper': null,
        'lib': null,
        'lib\\main.txt': 'main',
      });
      expect(anyFileContains(b.base, utf8.encode('outside bytes')), isFalse);
      expect(treeOf('${b.receiveDir}\\repo'), {'old.txt': 'already here'});
    }, timeout: long);
  });

  group('punto 2: an open file picker is not an active send', () {
    test(
      'while the picker of "Send…" is open, sendElement still sends',
      () async {
        final (a, b) = await stacks();
        final root = '${a.sourceDir}\\proj';
        write('$root\\a.txt', 'a');
        final held = Completer<void>();
        a.picker.gate = held;
        addTearDown(() {
          if (!held.isCompleted) held.complete();
        });
        final picking = a.coordinator.sendFile(
          a.targetOf(b),
          refresh: () => a.targetOf(b),
        );
        await eventually(() => a.picker.fileCalls == 1, reason: 'picker open');

        final result = await startSend(
          a,
          b,
          root,
        ).timeout(const Duration(seconds: 40));

        expect(result, isNotNull);
        expect(result?.outcome, TransferOutcome.saved);
        expect(File('${b.receiveDir}\\proj\\a.txt').readAsStringSync(), 'a');
        a.picker.next = null;
        held.complete();
        await picking.timeout(const Duration(seconds: 10));
      },
      timeout: long,
    );
  });

  group('punto 3: sendElement ends only after its pending cancels', () {
    Future<(TransferStack, TransferStack, Future<TransferResultView?>)>
    waitingForWarning() async {
      final (a, b) = await stacks(senderAtReceiver: PeerRelation.foreign);
      final root = '${a.sourceDir}\\proj';
      write('$root\\a.txt', 'a');
      final returned = startSend(a, b, root);
      await eventually(
        () => b.incoming?.stage == IncomingStage.warning,
        reason: 'warning on screen',
      );
      await a.phase(OutgoingPhase.waiting);
      return (a, b, returned);
    }

    test('cancelled while waiting: the result is set at once, but the future '
        'completes after the receiver answered the cancel', () async {
      final (a, b, returned) = await waitingForWarning();
      final hold = Gate<void>(null);
      b.wrappers[ApiPaths.transferCancel] = (call, inner) async {
        await hold.wait();
        return inner(call);
      };
      var completed = false;
      unawaited(returned.then((_) => completed = true));

      a.coordinator.cancelOutgoing();
      final sent = await a.sentResult();
      await hold.reached.future.timeout(const Duration(seconds: 5));
      await settle(const Duration(milliseconds: 300));

      expect(sent.outcome, TransferOutcome.cancelledHere);
      expect(completed, isFalse);
      hold.open(null);
      final result = await returned.timeout(const Duration(seconds: 5));
      expect(result, sent);
      expect(b.handledOn(ApiPaths.transferCancel), 1);
      await eventually(
        () => b.incoming == null,
        reason: 'the warning withdrawn at the receiver',
      );
    }, timeout: long);

    test('a cancel that never gets an answer holds the future at most about '
        'the cancel timeout', () async {
      final (a, b, returned) = await waitingForWarning();
      final hold = Gate<void>(null);
      b.wrappers[ApiPaths.transferCancel] = (call, inner) async {
        await hold.wait();
        return inner(call);
      };

      a.coordinator.cancelOutgoing();
      final clock = Stopwatch()..start();
      final result = await returned.timeout(
        Limits.transferCancelTimeout + const Duration(seconds: 3),
      );

      expect(result?.outcome, TransferOutcome.cancelledHere);
      expect(hold.isOpen, isFalse);
      expect(
        clock.elapsed,
        lessThan(Limits.transferCancelTimeout + const Duration(seconds: 2)),
      );
    }, timeout: long);
  });
}
