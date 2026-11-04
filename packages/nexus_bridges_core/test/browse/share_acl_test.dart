@TestOn('windows')
library;

import 'dart:io';

import 'package:nexus_bridges_core/src/browse/browse.dart';
import 'package:nexus_bridges_core/src/transfer/transfer.dart'
    show MovedTo, tempFolderName;
import 'package:test/test.dart';

import 'share_fs_support.dart';

void icacls(List<String> args) {
  final made = Process.runSync(
    'icacls',
    args,
    workingDirectory: Directory.systemTemp.path,
  );
  expect(made.exitCode, 0, reason: '${made.stdout}${made.stderr}');
}

void main() {
  test('E748 a root whose ACL denies creating inside it still locks its '
      'chain and a send to root\\sub lands (punto 4)', () async {
    final tree = await shareTree();
    final user = Platform.environment['USERNAME'];
    if (user == null || user.isEmpty) {
      markTestSkipped('USERNAME is not set');
      return;
    }
    icacls([tree.docs, '/deny', '$user:(WD,AD)']);
    addTearDown(() => icacls([tree.docs, '/remove:d', user]));
    expect(
      () => Directory(tree.child('prueba')).createSync(),
      throwsA(isA<FileSystemException>()),
    );
    expect(
      () => File(tree.child('prueba.txt')).writeAsStringSync('x'),
      throwsA(isA<FileSystemException>()),
    );
    final opened = await tree.fs.openChain(tree.root, ['sub']);
    expect(opened, isA<ChainOpened>());
    final chain = (opened as ChainOpened).chain;
    try {
      expect(await tree.fs.prepareChain(chain), isTrue);
      File('${chain.incomingPath}\\t.tmp').writeAsStringSync('dentro de sub');
      final moved = await tree.fs.recheckAndMove(
        chain,
        tempName: 't.tmp',
        isFolder: false,
        name: 'llega.txt',
      );
      expect(moved, isA<MovedTo>());
    } finally {
      await tree.fs.releaseChain(chain, saved: true);
    }
    expect(
      File(tree.child('sub\\llega.txt')).readAsStringSync(),
      'dentro de sub',
    );
    expect(Directory(tree.child('sub\\$tempFolderName')).existsSync(), isFalse);
  });
}
