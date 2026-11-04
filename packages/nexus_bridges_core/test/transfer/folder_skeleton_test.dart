@TestOn('windows')
library;

import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:nexus_bridges_core/src/protocol/protocol.dart';
import 'package:nexus_bridges_core/src/transfer/transfer.dart';
import 'package:test/test.dart';
import 'package:win32/win32.dart';

import 'transfer_stacks_harness.dart';

const String zoneMark = '[ZoneTransfer]\r\nZoneId=3\r\n';

const Timeout long = Timeout(Duration(seconds: 60));

int attributesOf(String path) => using((arena) {
  final Win32Result(:value) = GetFileAttributes(arena.pcwstr(path));
  return value;
});

Future<(TransferStack, TransferStack)> mineStacks() async {
  final a = await TransferStack.start(name: 'A', address: hostA);
  final b = await TransferStack.start(name: 'B', address: hostB);
  await link(a, b);
  return (a, b);
}

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

Future<String> projectFolder(TransferStack a, String name) async {
  final root = '${a.sourceDir}\\$name';
  Directory('$root\\src\\b').createSync(recursive: true);
  Directory('$root\\docs').createSync(recursive: true);
  File('$root\\src\\a.txt').writeAsStringSync('alpha contents');
  File('$root\\src\\b\\c.txt').writeAsStringSync('gamma contents');
  return root;
}

Future<(TransferResultView?, TransferResultView, TransferResultView)> sendOne(
  TransferStack a,
  TransferStack b,
  String path, {
  TransferResultView? afterSent,
  TransferResultView? afterReceived,
}) async {
  final returned = await a.coordinator
      .sendElement(a.targetOf(b), path, refresh: () => a.targetOf(b))
      .timeout(const Duration(seconds: 30));
  final sent = await a.sentResult(after: afterSent);
  final received = await b.receivedResult(after: afterReceived);
  return (returned, sent, received);
}

Future<void> incomingGone(TransferStack b) => eventually(
  () => !Directory(b.tempSub).existsSync(),
  reason: '${b.name} .nexusbridges-incoming removed',
);

void main() {
  group('E600, RF-272 and RF-304: the walking skeleton', () {
    test('a small folder from a "mine" arrives whole and visible in the '
        'remembered folder and both sides see saved with the final '
        'name', () async {
      final (a, b) = await mineStacks();
      final source = await projectFolder(a, 'proj');

      final (returned, sent, received) = await sendOne(a, b, source);

      expect(sent.outcome, TransferOutcome.saved);
      expect(sent.fileName, 'proj');
      expect(sent.direction, TransferDirection.outgoing);
      expect(returned, sent);
      expect(received.outcome, TransferOutcome.saved);
      expect(received.fileName, 'proj');
      expect(received.direction, TransferDirection.incoming);

      final saved = '${b.receiveDir}\\proj';
      expect(treeOf(saved), {
        'docs': null,
        'src': null,
        'src\\a.txt': 'alpha contents',
        'src\\b': null,
        'src\\b\\c.txt': 'gamma contents',
      });
      expect(Directory('$saved\\docs').listSync(), isEmpty);
      expect(attributesOf(saved) & FILE_ATTRIBUTE_HIDDEN, 0);
      expect(attributesOf(saved) & FILE_ATTRIBUTE_SYSTEM, 0);
      for (final file in ['src\\a.txt', 'src\\b\\c.txt']) {
        expect(
          File('$saved\\$file:Zone.Identifier').readAsStringSync(),
          zoneMark,
          reason: file,
        );
      }
      await incomingGone(b);
      expect(namesIn(b.receiveDir), ['proj']);
      expect(treeOf(source).length, 5);
    }, timeout: long);

    test('the same folder sent twice takes a free name, "proj (1)", and both '
        'sides report that final name', () async {
      final (a, b) = await mineStacks();
      final source = await projectFolder(a, 'proj');
      final (_, firstSent, firstReceived) = await sendOne(a, b, source);
      expect(firstSent.outcome, TransferOutcome.saved);

      final (_, sent, received) = await sendOne(
        a,
        b,
        source,
        afterSent: firstSent,
        afterReceived: firstReceived,
      );

      expect(sent.outcome, TransferOutcome.saved);
      expect(sent.fileName, 'proj (1)');
      expect(received.outcome, TransferOutcome.saved);
      expect(received.fileName, 'proj (1)');
      expect(treeOf('${b.receiveDir}\\proj (1)'), {
        'docs': null,
        'src': null,
        'src\\a.txt': 'alpha contents',
        'src\\b': null,
        'src\\b\\c.txt': 'gamma contents',
      });
      expect(
        attributesOf('${b.receiveDir}\\proj (1)') & FILE_ATTRIBUTE_HIDDEN,
        0,
      );
      await incomingGone(b);
      expect(namesIn(b.receiveDir), ['proj', 'proj (1)']);
    }, timeout: long);

    test('a file named PROJ already in the remembered folder takes the name '
        'without caring about case and is left untouched', () async {
      final (a, b) = await mineStacks();
      final source = await projectFolder(a, 'proj');
      File('${b.receiveDir}\\PROJ').writeAsStringSync('already here');

      final (_, sent, received) = await sendOne(a, b, source);

      expect(sent.outcome, TransferOutcome.saved);
      expect(sent.fileName, 'proj (1)');
      expect(received.fileName, 'proj (1)');
      expect(File('${b.receiveDir}\\PROJ').readAsStringSync(), 'already here');
      expect(treeOf('${b.receiveDir}\\proj (1)').length, 5);
      await incomingGone(b);
      expect(namesIn(b.receiveDir), ['PROJ', 'proj (1)']);
    }, timeout: long);

    test('a single file through sendElement still takes the path of the '
        '004', () async {
      final (a, b) = await mineStacks();
      final path = await a.sourceFile('nota.txt', 'plain file'.codeUnits);

      final (returned, sent, received) = await sendOne(a, b, path);

      expect(sent.outcome, TransferOutcome.saved);
      expect(sent.fileName, 'nota.txt');
      expect(returned, sent);
      expect(received.outcome, TransferOutcome.saved);
      expect(
        File('${b.receiveDir}\\nota.txt').readAsStringSync(),
        'plain file',
      );
      expect(b.bodiesOn(ApiPaths.transferOffer).single['kind'], isNull);
    }, timeout: long);
  });

  group('E411, RF-304: empty folders travel', () {
    test('an empty folder inside another arrives as an empty folder with a '
        'saved result', () async {
      final (a, b) = await mineStacks();
      final root = '${a.sourceDir}\\outer';
      Directory('$root\\a\\b').createSync(recursive: true);

      final (_, sent, received) = await sendOne(a, b, root);

      expect(sent.outcome, TransferOutcome.saved);
      expect(received.outcome, TransferOutcome.saved);
      expect(received.fileName, 'outer');
      expect(treeOf('${b.receiveDir}\\outer'), {'a': null, 'a\\b': null});
      expect(Directory('${b.receiveDir}\\outer\\a\\b').listSync(), isEmpty);
      await incomingGone(b);
      expect(namesIn(b.receiveDir), ['outer']);
    }, timeout: long);

    test('an empty chosen folder (manifest of 0 bytes) arrives as an empty '
        'folder with a saved result', () async {
      final (a, b) = await mineStacks();
      final root = '${a.sourceDir}\\vacia';
      Directory(root).createSync();

      final (_, sent, received) = await sendOne(a, b, root);

      expect(sent.outcome, TransferOutcome.saved);
      expect(sent.fileName, 'vacia');
      expect(received.outcome, TransferOutcome.saved);
      expect(received.fileName, 'vacia');
      final offer = b.bodiesOn(ApiPaths.transferOffer).single;
      expect(offer['kind'], 'folder');
      expect(offer['entries'], 0);
      expect(offer['files'], 0);
      expect(offer['manifestBytes'], 0);
      expect(Directory('${b.receiveDir}\\vacia').existsSync(), isTrue);
      expect(Directory('${b.receiveDir}\\vacia').listSync(), isEmpty);
      expect(attributesOf('${b.receiveDir}\\vacia') & FILE_ATTRIBUTE_HIDDEN, 0);
      await incomingGone(b);
      expect(namesIn(b.receiveDir), ['vacia']);
    }, timeout: long);
  });

  group('RF-272: the folder offer carries no destination', () {
    test('the offer a sender builds has exactly the keys of the plan, '
        'without destination', () async {
      final (a, b) = await mineStacks();
      final source = await projectFolder(a, 'proj');

      await sendOne(a, b, source);

      final offer = b.bodiesOn(ApiPaths.transferOffer).single;
      expect(offer.keys.toSet(), {
        'protocol',
        'transfer',
        'kind',
        'name',
        'entries',
        'files',
        'bytes',
        'depth',
        'longest',
        'manifestBytes',
      });
      expect(offer['protocol'], protocolVersion);
      expect(offer['name'], 'proj');
      expect(offer['entries'], 5);
      expect(offer['files'], 2);
      expect(offer['bytes'], 'alpha contents'.length * 2);
    }, timeout: long);
  });
}
