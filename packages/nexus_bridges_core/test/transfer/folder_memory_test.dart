@TestOn('windows')
@Tags(['large'])
library;

import 'dart:io';

import 'package:nexus_bridges_core/src/protocol/protocol.dart';
import 'package:nexus_bridges_core/src/transfer/folders.dart';
import 'package:test/test.dart';

import 'folder_large_test.dart'
    show FolderChild, largeFolder, sendFolder, trustEachOther, useCompiledChild;

const int memoryBudget = 100 * 1000 * 1000;

const int folders = 10;

String bigFolder(String base) {
  final root = '$base\\source\\Grande';
  final perFolder = (Limits.maxFolderEntries ~/ folders) - 1;
  for (var folder = 0; folder < folders; folder++) {
    final dir = '$root\\carpeta-$folder';
    Directory(dir).createSync(recursive: true);
    for (var i = 0; i < perFolder; i++) {
      File('$dir\\archivo-$i.txt').writeAsStringSync('$folder/$i');
    }
  }
  return root;
}

int countEntries(String root) =>
    Directory(root).listSync(recursive: true, followLinks: false).length;

void main() {
  useCompiledChild();

  test('E481, R112: sending a folder of a hundred thousand entries between '
      'two child processes grows less than 100 MB on each side and the '
      'whole folder arrives', () async {
    final base = await largeFolder('nexus_e481_');
    final setup = Stopwatch()..start();
    final source = bigFolder(base);
    setup.stop();
    expect(countEntries(source), Limits.maxFolderEntries);

    final receiver = await FolderChild.start(
      'receive',
      '127.0.0.52',
      '$base\\r',
    );
    final sender = await FolderChild.start('send', '127.0.0.51', '$base\\s');
    await trustEachOther(receiver, sender);
    final ready = receiver.events.firstWhere((e) => e['event'] == 'ready');
    receiver.send({'cmd': 'baseline'});
    sender.send({'cmd': 'baseline'});
    final receiverRest = (await receiver.next('baseline'))['rss']! as int;
    final senderRest = (await sender.next('baseline'))['rss']! as int;

    final watch = Stopwatch()..start();
    sendFolder(sender, ready, source, '127.0.0.52');
    await sender.next('started');
    final sent = await sender.next('sent', limit: const Duration(minutes: 40));
    final received = await receiver.next(
      'received',
      limit: const Duration(minutes: 2),
    );
    watch.stop();
    receiver.send({'cmd': 'report'});
    sender.send({'cmd': 'report'});
    final receiverReport = await receiver.next('report');
    final senderReport = await sender.next('report');

    final receiverGrowth = (receiverReport['peak']! as int) - receiverRest;
    final senderGrowth = (senderReport['peak']! as int) - senderRest;
    print(
      'E481 setup ${setup.elapsed.inSeconds} s; '
      '${Limits.maxFolderEntries} entries in ${watch.elapsed.inSeconds} s; '
      'receiver rest ${receiverRest ~/ 1000000} MB, '
      'growth ${receiverGrowth ~/ 1000000} MB, '
      'max ${(receiverReport['maxRss']! as int) ~/ 1000000} MB, '
      '${receiverReport['samples']} samples, '
      'peak in ${receiverReport['peakPhase']}; '
      'sender rest ${senderRest ~/ 1000000} MB, '
      'growth ${senderGrowth ~/ 1000000} MB, '
      'max ${(senderReport['maxRss']! as int) ~/ 1000000} MB, '
      '${senderReport['samples']} samples, '
      'peak in ${senderReport['peakPhase']}',
    );
    print('E481 receiver every 30 s: ${receiverReport['timeline']}');
    print('E481 sender every 30 s: ${senderReport['timeline']}');
    expect(sent['outcome'], 'saved');
    expect(received['outcome'], 'saved');
    expect(sent['files'], Limits.maxFolderEntries - folders);
    expect(receiverGrowth, lessThan(memoryBudget));
    expect(senderGrowth, lessThan(memoryBudget));

    final recv = '$base\\r\\recv';
    final arrived = '$recv\\Grande';
    expect(countEntries(arrived), Limits.maxFolderEntries);
    expect(
      File('$arrived\\carpeta-0\\archivo-0.txt').readAsStringSync(),
      '0/0',
    );
    expect(
      File('$arrived\\carpeta-9\\archivo-9998.txt').readAsStringSync(),
      '9/9998',
    );
    expect(
      Directory(recv)
          .listSync(followLinks: false)
          .map((e) => e.path.split('\\').last)
          .where((name) => name != tempFolderName),
      ['Grande'],
    );
    expect(Directory('$recv\\$tempFolderName').existsSync(), isFalse);
  }, timeout: const Timeout(Duration(minutes: 60)));
}
