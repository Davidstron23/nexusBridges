@TestOn('windows')
library;

import 'dart:io';
import 'dart:math';

import 'package:nexus_bridges_core/src/pairing/pairing.dart';
import 'package:nexus_bridges_core/src/transfer/transfer.dart';
import 'package:test/test.dart';

import 'transfer_stacks_harness.dart';

const Timeout long = Timeout(Duration(seconds: 90));

Future<(TransferStack, TransferStack)> stacks({
  PeerRelation senderAtReceiver = PeerRelation.mine,
}) async {
  final a = await TransferStack.start(name: 'A', address: hostA);
  final b = await TransferStack.start(name: 'B', address: hostB);
  await link(a, b, senderAtReceiver: senderAtReceiver, senderName: 'PORTATIL');
  return (a, b);
}

Future<void> acceptWarning(TransferStack b) async {
  await eventually(
    () => b.incoming?.stage == IncomingStage.warning,
    reason: 'warning on screen',
  );
  b.coordinator.answerWarning(b.incoming!.sessionId, accept: true);
}

Future<(TransferResultView?, TransferResultView, TransferResultView)> sendOne(
  TransferStack a,
  TransferStack b,
  String path, {
  bool acceptAtB = false,
}) async {
  final returned = a.coordinator.sendElement(
    a.targetOf(b),
    path,
    refresh: () => a.targetOf(b),
  );
  if (acceptAtB) await acceptWarning(b);
  final result = await returned.timeout(const Duration(seconds: 40));
  final sent = await a.sentResult();
  final received = await b.receivedResult();
  return (result, sent, received);
}

List<String> relativePartsOfLength(int total, {int fileLength = 20}) {
  final names = <String>[];
  var left = total - fileLength;
  while (left > 0) {
    var length = min(40, left - 1);
    if (left - (length + 1) == 1) length -= 1;
    names.add('d' * length);
    left -= length + 1;
  }
  names.add('f' * fileLength);
  return names;
}

Future<String> deepFolder(
  TransferStack a,
  String name,
  int relativeLength,
) async {
  final root = '${a.sourceDir}\\$name';
  final parts = relativePartsOfLength(relativeLength);
  var current = root;
  for (final part in parts.take(parts.length - 1)) {
    current = '$current\\$part';
  }
  Directory(current).createSync(recursive: true);
  File('$current\\${parts.last}').writeAsStringSync('deep');
  return root;
}

void main() {
  group('E457, RF-270: the longest path decides in both computers', () {
    int limit(TransferStack b, String name) => min(
      259 - b.receiveDir.length - 51,
      259 - b.receiveDir.length - name.length - 6,
    );

    test('one character over: pathTooLong for the sender, nothing shown or '
        'written at the receiver', () async {
      final (a, b) = await stacks();
      final bound = limit(b, 'deep');
      final source = await deepFolder(a, 'deep', bound + 1);

      final (_, sent, _) = await sendOnlySender(a, b, source);

      expect(sent.outcome, TransferOutcome.pathTooLong);
      expect(sent.fileName, 'deep');
      expect(b.lastReceived, isNull);
      expect(b.incoming, isNull);
      expect(Directory(b.receiveDir).listSync(), isEmpty);
    }, timeout: long);

    test(
      'exactly at the limit: saved with the file at its deep path',
      () async {
        final (a, b) = await stacks();
        final bound = limit(b, 'deep');
        final source = await deepFolder(a, 'deep', bound);

        final (_, sent, received) = await sendOne(a, b, source);

        expect(sent.outcome, TransferOutcome.saved);
        expect(received.outcome, TransferOutcome.saved);
        final files = Directory('${b.receiveDir}\\deep')
            .listSync(recursive: true, followLinks: false)
            .whereType<File>()
            .toList();
        expect(files, hasLength(1));
        expect(
          files.single.path.length,
          b.receiveDir.length + 1 + 4 + 1 + bound,
        );
        expect(files.single.readAsStringSync(), 'deep');
      },
      timeout: long,
    );
  });

  group('E459, RF-305: "contains programs" in both results', () {
    test('a folder with src\\index.js: both results say so', () async {
      final (a, b) = await stacks();
      final root = '${a.sourceDir}\\web';
      Directory('$root\\src').createSync(recursive: true);
      File('$root\\src\\index.js').writeAsStringSync('console.log(1)');
      File('$root\\readme.txt').writeAsStringSync('hi');

      final (_, sent, received) = await sendOne(a, b, root);

      expect(sent.outcome, TransferOutcome.saved);
      expect(sent.isProgram, isTrue);
      expect(received.outcome, TransferOutcome.saved);
      expect(received.isProgram, isTrue);
      expect(received.isFolder, isTrue);
    }, timeout: long);

    test('a folder with only .txt files: neither says so', () async {
      final (a, b) = await stacks();
      final root = '${a.sourceDir}\\notes';
      Directory(root).createSync(recursive: true);
      File('$root\\a.txt').writeAsStringSync('a');
      File('$root\\b.txt').writeAsStringSync('b');

      final (_, sent, received) = await sendOne(a, b, root);

      expect(sent.isProgram, isFalse);
      expect(received.isProgram, isFalse);
    }, timeout: long);
  });

  group('E458 and E460: a "foreign" through the whole protocol', () {
    test('the warning shows the folder, accepting saves it in the receive '
        'folder and the result is saved on both sides', () async {
      final (a, b) = await stacks(senderAtReceiver: PeerRelation.foreign);
      final root = '${a.sourceDir}\\proy';
      Directory('$root\\carpeta').createSync(recursive: true);
      File('$root\\carpeta\\dentro.txt').writeAsStringSync('inside');
      File('$root\\suelto.txt').writeAsStringSync('loose');

      final returned = a.coordinator.sendElement(
        a.targetOf(b),
        root,
        refresh: () => a.targetOf(b),
      );
      await eventually(
        () => b.incoming?.stage == IncomingStage.warning,
        reason: 'warning on screen',
      );
      final view = b.incoming!;
      expect(view.peerName, 'PORTATIL');
      expect(view.fileName, 'proy');
      expect(view.isFolder, isTrue);
      expect(view.fileCount, 2);
      expect(view.size, 'inside'.length + 'loose'.length);
      expect(view.firstLevel, const [
        FirstLevelItem(name: 'carpeta', isFolder: true),
        FirstLevelItem(name: 'suelto.txt', isFolder: false),
      ]);
      expect(view.moreFirstLevel, 0);
      expect(Directory(b.receiveDir).listSync(), isEmpty);

      b.coordinator.answerWarning(view.sessionId, accept: true);
      final result = await returned.timeout(const Duration(seconds: 40));

      expect(result?.outcome, TransferOutcome.saved);
      expect(
        File('${b.receiveDir}\\proy\\carpeta\\dentro.txt').readAsStringSync(),
        'inside',
      );
      expect((await b.receivedResult()).outcome, TransferOutcome.saved);
    }, timeout: long);

    test('declining the warning writes nothing and the sender sees '
        'declined', () async {
      final (a, b) = await stacks(senderAtReceiver: PeerRelation.foreign);
      final root = '${a.sourceDir}\\proy';
      Directory(root).createSync(recursive: true);
      File('$root\\a.txt').writeAsStringSync('a');

      final returned = a.coordinator.sendElement(
        a.targetOf(b),
        root,
        refresh: () => a.targetOf(b),
      );
      await eventually(
        () => b.incoming?.stage == IncomingStage.warning,
        reason: 'warning on screen',
      );
      b.coordinator.answerWarning(b.incoming!.sessionId, accept: false);
      final result = await returned.timeout(const Duration(seconds: 40));

      expect(result?.outcome, TransferOutcome.declined);
      expect(Directory(b.receiveDir).listSync(), isEmpty);
    }, timeout: long);
  });
}

Future<(TransferResultView?, TransferResultView, TransferResultView?)>
sendOnlySender(TransferStack a, TransferStack b, String path) async {
  final returned = await a.coordinator
      .sendElement(a.targetOf(b), path, refresh: () => a.targetOf(b))
      .timeout(const Duration(seconds: 40));
  final sent = await a.sentResult();
  return (returned, sent, b.lastReceived);
}
