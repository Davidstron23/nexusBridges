@TestOn('windows')
library;

import 'dart:convert';
import 'dart:io';

import 'package:nexus_bridges_core/src/browse/browse.dart' show RemoteFolders;
import 'package:nexus_bridges_core/src/node/node.dart' show SendResult;
import 'package:nexus_bridges_core/src/pairing/pairing.dart' show PeerRelation;
import 'package:nexus_bridges_core/src/protocol/protocol.dart';
import 'package:nexus_bridges_core/src/transfer/platform.dart'
    show DestinationChanged, MoveFailed;
import 'package:nexus_bridges_core/src/transfer/transfer.dart'
    show
        IncomingStage,
        SharedFolderDestination,
        TransferOutcome,
        tempFolderName;
import 'package:test/test.dart';

import '../browse/junction_support.dart';
import 'guard_nodes_support.dart' hide junction;
import 'guard_nodes_support.dart' as support show junction;
import 'transfer_nodes_harness.dart';

const Duration offerWindow = Duration(seconds: 61);

final List<int> unavailableOffer = utf8.encode(
  '{"error":"destination_unavailable"}',
);

Map<String, Object?> dest(String rootId, List<String> path, {String? fresh}) =>
    {'root': rootId, 'path': path, 'newFolder': ?fresh};

Future<void> expectOfferRefused(
  Guarded g,
  Map<String, Object?> destination, {
  String? reason,
  int status = 403,
  List<int>? body,
}) async {
  g.b.clock.advance(offerWindow);
  final reply = await rawPost(
    g.a,
    g.b,
    ApiPaths.transferOffer,
    rawFileOffer('trampa.txt', [1, 2, 3], destination: destination),
  );
  expect(reply, isNotNull, reason: reason);
  expect(reply!.status, status, reason: reason);
  expect(reply.body, body ?? unavailableOffer, reason: reason);
}

void main() {
  group('E740 step 1 of the offer (RF-413) [SEG]', () {
    late Guarded g;
    late bool symlinked;

    setUp(() async {
      symlinked = false;
      g = await guardedNodes(tree: (b) => symlinked = buildTrapTree(b));
    });

    test('E740 every trap of E700 is refused with no question, no resolve '
        'and no temp folder anywhere', () async {
      final shot = folderShot(g.docs);
      final tooLong = 'a' * (237 - g.docs.length);
      final traps = <List<String>>[
        ['..'],
        ['.'],
        ['sub', '..', '..'],
        ['a', '..', '..', 'Windows'],
        [r'a\..\..\Windows'],
        [r'C:\Windows'],
        [r'\\host\share'],
        [r'\\?\C:\'],
        [r'\\.\C:'],
        ['a\u{1}b'],
        ['a*'],
        ['a?'],
        ['a"'],
        ['a<'],
        ['a>'],
        ['a|'],
        ['a/b'],
        ['a:b'],
        ['CON'],
        ['con.txt'],
        ['COM\u{B9}'],
        ['x.'],
        ['x '],
        ['a\u{202E}b'],
        [tempFolderName],
        ['~nexusbridges-abc'],
        List.filled(33, 'a'),
        ['sub', tooLong],
      ];
      for (final trap in traps) {
        await expectOfferRefused(g, dest(g.rootId, trap), reason: '$trap');
      }
      for (final fresh in ['CON', 'x.', 'desktop.ini', 'a\u{202E}b', '..']) {
        await expectOfferRefused(
          g,
          dest(g.rootId, const ['sub'], fresh: fresh),
          reason: fresh,
        );
      }
      await expectOfferRefused(g, dest('f' * 32, const []));
      expect(g.fs.opened, 0);
      expect(g.fs.touches, 0);
      expect(folderShot(g.docs), shot);
      expect(g.b.state.incoming, isNull);
      expect(g.b.state.lastReceived, isNull);
      expect(g.b.state.notices, isEmpty);
      expect(g.b.state.prompts, isEmpty);
      expect(g.b.states.where((s) => s.incoming != null), isEmpty);
      expectCleanLogs([g.a, g.b], [g.docs, g.rootId]);
    }, timeout: transferTimeout);

    test('E740 an absolute path is never a destination: any extra key or '
        'shape is a 400 and the disk is not touched', () async {
      final badRequest = <Map<String, Object?>>[
        rawFileOffer(
          'a.txt',
          [1],
          destination: dest(g.rootId, const []),
          extra: {'absolutePath': r'C:\Windows'},
        ),
        rawFileOffer('a.txt', [1], extra: {'absolutePath': r'C:\Windows'}),
        rawFileOffer(
          'a.txt',
          [1],
          destination: {
            'root': g.rootId,
            'path': const <String>[],
            'absolutePath': r'C:\Windows',
          },
        ),
        rawFileOffer('a.txt', [1], destination: {'path': r'C:\Windows'}),
        rawFileOffer(
          'a.txt',
          [1],
          destination: {'root': r'C:\Windows', 'path': const <String>[]},
        ),
        rawFileOffer('a.txt', [1], extra: {'destination': r'C:\Windows'}),
        rawFileOffer(
          'a.txt',
          [1],
          destination: {'root': g.rootId, 'path': r'C:\Windows'},
        ),
        rawFileOffer(
          'a.txt',
          [1],
          destination: {
            'root': g.rootId,
            'path': const [''],
          },
        ),
      ];
      for (final offer in badRequest) {
        g.b.clock.advance(offerWindow);
        final reply = await rawPost(g.a, g.b, ApiPaths.transferOffer, offer);
        expect(reply!.status, 400, reason: '$offer');
      }
      expect(g.fs.touches, 0);
      expect(g.b.state.incoming, isNull);
    }, timeout: transferTimeout);

    test('E740 traps that need the disk are refused with the chain released '
        'and nothing written, also by 8.3 name', () async {
      final shot = folderShot(g.docs);
      final outside = namesIn(g.outside);
      final refused = <(List<String>, TransferOutcome)>[
        for (final name in [
          'union',
          'interna',
          'ventanas',
          if (symlinked) 'enlace',
          'Oculta',
          'Sistema',
          '.git',
          'Inicio',
        ])
          ([name], TransferOutcome.destinationUnavailable),
        (['union', 'centinela'], TransferOutcome.destinationUnavailable),
        (['f'], TransferOutcome.destinationMissing),
        (['no-existe'], TransferOutcome.destinationMissing),
      ];
      for (final name in [
        shortNameOf('${g.docs}\\x.'),
        shortNameOf('${g.docs}\\$tempFolderName'),
        shortNameOf('${g.docs}\\MiProyectoLargo'),
      ]) {
        if (name.isNotEmpty) {
          refused.add(([name], TransferOutcome.destinationUnavailable));
        }
      }
      var n = 0;
      for (final (path, outcome) in refused) {
        final sent = await g.sendFile('t$n.txt', [n], g.to(path));
        expect(sent.outcome, outcome, reason: '$path');
        n++;
        g.b.clock.advance(offerWindow);
      }
      await g.settled();
      expect(folderShot(g.docs), shot);
      expect(namesIn(g.outside), outside);
      expect(g.b.state.lastReceived, isNull);
      expect(g.b.states.where((s) => s.incoming != null), isEmpty);
      expect(g.fs.prepared, 0);
      expectCleanLogs(
        [g.a, g.b],
        [g.docs, g.rootId],
        words: const ['union', 'interna', 'Oculta', 'Sistema', 'Inicio'],
      );
    }, timeout: transferTimeout);

    test('E740 a file name with a path inside a valid destination is refused '
        'and nothing lands outside', () async {
      final shot = folderShot(g.docs);
      for (final name in [r'..\fuera.txt', r'sub\x.txt', 'C:x.txt', 'CON']) {
        g.b.clock.advance(offerWindow);
        final reply = await rawPost(
          g.a,
          g.b,
          ApiPaths.transferOffer,
          rawFileOffer(name, [1], destination: dest(g.rootId, const ['sub'])),
        );
        expect(reply!.status, isNot(200), reason: name);
      }
      expect(folderShot(g.docs), shot);
      expect(namesIn(g.b.base), isNot(contains('fuera.txt')));
    }, timeout: transferTimeout);
  });

  group('E740 another peer and a foreign peer [SEG]', () {
    test('E740 the root of another peer is destination_unavailable and a '
        'foreign peer gets default_only, neither resolves', () async {
      late CountingShareFileSystem fs;
      final (a, b, c) = await transferTrio(
        cAtB: PeerRelation.foreign,
        before: (a, b, c) async {
          Directory('${docsOf(b)}\\sub').createSync(recursive: true);
          fs = countingFor(b);
        },
      );
      final rootA = await addRoot(b, a, docsOf(b));
      fs.reset();
      final reply = await rawPost(
        c,
        b,
        ApiPaths.transferOffer,
        rawFileOffer('t.txt', [1], destination: dest(rootA, const [])),
      );
      expect(reply!.status, 403);
      expect(reply.body, utf8.encode('{"error":"default_only"}'));
      await b.node.setMine(c.fingerprint, mine: true);
      await b.until(
        (s) => s.peers[c.fingerprint]?.mine == true,
        reason: 'C is mine at B',
      );
      b.clock.advance(offerWindow);
      final other = await rawPost(
        c,
        b,
        ApiPaths.transferOffer,
        rawFileOffer('t.txt', [1], destination: dest(rootA, const [])),
      );
      expect(other!.status, 403);
      expect(other.body, unavailableOffer);
      expect(fs.touches, 0);
      expect(namesIn(docsOf(b)), ['sub']);
    }, timeout: transferTimeout);
  });

  group('E741 a new folder (RF-414) [SEG]', () {
    test('E741 invalid names and a folder that does not exist yet create '
        'nothing', () async {
      final g = await guardedNodes();
      for (final fresh in [
        'CON',
        'x.{3050f4d8-98B5-11CF-BB82-00AA00BDCE0B}',
        'x.',
        'desktop.ini',
        'a\u{202E}b',
      ]) {
        final sent = await g.sendFile('a.txt', [
          1,
        ], g.to(const ['sub'], newFolder: fresh));
        expect(
          sent.outcome,
          TransferOutcome.destinationUnavailable,
          reason: fresh,
        );
        g.b.clock.advance(offerWindow);
      }
      final deep = await g.sendFile('a.txt', [
        1,
      ], g.to(const ['falta'], newFolder: 'nueva'));
      expect(deep.outcome, TransferOutcome.destinationMissing);
      expect(namesIn(g.docs), ['otra', 'sub']);
      expect(namesIn('${g.docs}\\sub'), ['deep']);
    }, timeout: transferTimeout);

    test('E741 a destination deleted between exploring and sending is not '
        'recreated', () async {
      final g = await guardedNodes();
      final listed = await g.a.node.listRemoteFolders(
        g.b.fingerprint,
        g.rootId,
        const ['sub'],
      );
      expect(listed, isNotNull);
      Directory('${g.docs}\\sub\\deep').deleteSync();
      final sent = await g.sendFile('a.txt', [1], g.to(const ['sub', 'deep']));
      expect(sent.outcome, TransferOutcome.destinationMissing);
      expect(exists('${g.docs}\\sub\\deep'), isFalse);
    }, timeout: transferTimeout);

    test('E741 a new folder named like a file is refused and the file stays; '
        'a file in the middle of the path is a missing folder', () async {
      final g = await guardedNodes();
      File('${g.docs}\\archivo').writeAsStringSync('intacto');
      final named = await g.sendFile('a.txt', [
        1,
      ], g.to(const [], newFolder: 'archivo'));
      expect(named.outcome, TransferOutcome.destinationUnavailable);
      final middle = await g.sendFile('b.txt', [
        1,
      ], g.to(const ['archivo'], newFolder: 'nueva'));
      expect(middle.outcome, TransferOutcome.destinationMissing);
      expect(File('${g.docs}\\archivo').readAsStringSync(), 'intacto');
      expect(namesIn(g.docs), ['archivo', 'otra', 'sub']);
    }, timeout: transferTimeout);

    test('E741 a new folder named like a hidden folder, a junction or a '
        'forbidden folder that exists is refused and nothing is written in '
        'them', () async {
      final g = await guardedNodes(tree: buildTrapTree);
      for (final fresh in ['Oculta', 'union', 'ventanas', 'Inicio', '.git']) {
        final sent = await g.sendFile('a.txt', [
          1,
        ], g.to(const [], newFolder: fresh));
        expect(
          sent.outcome,
          TransferOutcome.destinationUnavailable,
          reason: fresh,
        );
        g.b.clock.advance(offerWindow);
      }
      await g.settled();
      expect(namesIn(g.outside), ['centinela']);
      expect(namesIn('${g.docs}\\Oculta'), isEmpty);
      expect(namesIn('${g.docs}\\Inicio'), isEmpty);
    }, timeout: transferTimeout);

    test('E741 a new folder named mods when Mods exists uses Mods, the '
        'result carries the real name (punto 22) and a failed send does not '
        'remove it', () async {
      final g = await guardedNodes();
      Directory('${g.docs}\\Mods').createSync();
      final receivedBefore = g.b.state.lastReceived;
      final sent = await g.sendFile('a.txt', [
        1,
        2,
      ], g.to(const [], newFolder: 'mods'));
      final received = await g.b.receivedResult(after: receivedBefore);
      expect(sent.outcome, TransferOutcome.saved);
      expect(namesIn(g.docs), ['Mods', 'otra', 'sub']);
      expect(File('${g.docs}\\Mods\\a.txt').readAsBytesSync(), [1, 2]);
      expect(
        received.destination?.display(homeName: 'Home').toLowerCase(),
        r'docs\mods',
      );

      await g.settled();
      g.fs.forcedMove = const MoveFailed();
      final failed = await g.sendFile('b.txt', [
        3,
      ], g.to(const [], newFolder: 'mods'));
      expect(failed.outcome, isNot(TransferOutcome.saved));
      await g.settled();
      expect(namesIn(g.docs), ['Mods', 'otra', 'sub']);
      expect(namesIn('${g.docs}\\Mods'), ['a.txt']);
    }, timeout: transferTimeout);

    test('E741 a new folder named like the 8.3 name of another folder is '
        'refused and nothing is written there', () async {
      final g = await guardedNodes(
        tree: (b) {
          Directory('${docsOf(b)}\\MiProyectoLargo')
              .createSync(recursive: true);
          return true;
        },
      );
      final short = shortNameOf('${g.docs}\\MiProyectoLargo');
      if (short.isEmpty) {
        markTestSkipped('this volume has no 8.3 names');
        return;
      }
      final sent = await g.sendFile('a.txt', [
        1,
      ], g.to(const [], newFolder: short));
      expect(sent.outcome, TransferOutcome.destinationUnavailable);
      await g.settled();
      expect(namesIn(g.docs), ['MiProyectoLargo']);
      expect(namesIn('${g.docs}\\MiProyectoLargo'), isEmpty);
    }, timeout: transferTimeout);

    test('E741 a send to a new folder cancelled half way leaves no folder, '
        'no temp and no lock', () async {
      final g = await guardedNodes();
      g.b.writes.hold();
      addTearDown(g.b.writes.release);
      await g.start(
        await g.a.sourceFile('grande.bin', List.filled(4 * 1024 * 1024, 7)),
        g.to(const ['sub'], newFolder: 'nueva'),
      );
      await g.b.incomingAt(IncomingStage.receiving);
      expect(exists('${g.docs}\\sub\\nueva'), isTrue);
      final before = g.a.state.lastSent;
      g.a.node.cancelSending();
      final sent = await g.a.sentResult(after: before);
      expect(sent.outcome, isNot(TransferOutcome.saved));
      g.b.writes.release();
      await g.settled();
      await eventually(
        () => !exists('${g.docs}\\sub\\nueva'),
        limit: transferWait,
        reason: 'new folder removed',
      );
      expect(namesIn('${g.docs}\\sub'), ['deep']);
      g.expectNothingLocked(['${g.docs}\\sub', g.docs]);
    }, timeout: transferTimeout);

    test('E741 a folder another program creates between resolve and prepare '
        'is used and, if the send fails, not removed', () async {
      final g = await guardedNodes();
      final made = '${g.docs}\\sub\\nueva';
      g.fs.beforePrepare = () async {
        g.fs.beforePrepare = null;
        Directory(made).createSync();
      };
      g.fs.forcedMove = const DestinationChanged();
      final sent = await g.sendFile('a.txt', [
        1,
      ], g.to(const ['sub'], newFolder: 'nueva'));
      expect(sent.outcome, TransferOutcome.destinationLost);
      await g.settled();
      expect(Directory(made).existsSync(), isTrue);
      expect(namesIn(made), isEmpty);
    }, timeout: transferTimeout);

    test('E741 a junction planted at the new name between resolve and prepare '
        'is refused and nothing goes through it', () async {
      final g = await guardedNodes();
      final made = '${g.docs}\\sub\\nueva';
      addTearDown(() {
        if (exists(made)) Directory(made).deleteSync();
      });
      g.fs.beforePrepare = () async {
        g.fs.beforePrepare = null;
        support.junction(made, g.outside);
      };
      final sent = await g.sendFile('a.txt', [
        1,
      ], g.to(const ['sub'], newFolder: 'nueva'));
      expect(sent.outcome, TransferOutcome.destinationUnavailable);
      await g.settled();
      expect(namesIn(g.outside), ['centinela']);
      expect(exists(made), isTrue);
    }, timeout: transferTimeout);

    test('E741 a file planted at the new name between resolve and prepare is '
        'refused and stays', () async {
      final g = await guardedNodes();
      final made = '${g.docs}\\sub\\nueva';
      g.fs.beforePrepare = () async {
        g.fs.beforePrepare = null;
        File(made).writeAsStringSync('de otro programa');
      };
      final sent = await g.sendFile('a.txt', [
        1,
      ], g.to(const ['sub'], newFolder: 'nueva'));
      expect(sent.outcome, TransferOutcome.destinationUnavailable);
      await g.settled();
      expect(File(made).readAsStringSync(), 'de otro programa');
    }, timeout: transferTimeout);

    test('E741 a temp folder that already is a junction or a file makes the '
        'send fail and nothing goes through it', () async {
      final g = await guardedNodes();
      final temp = '${g.docs}\\sub\\$tempFolderName';
      support.junction(temp, g.outside);
      addTearDown(() {
        if (exists(temp)) Directory(temp).deleteSync();
      });
      final sent = await g.sendFile('a.txt', [1], g.to(const ['sub']));
      expect(sent.outcome, TransferOutcome.destinationUnavailable);
      await g.settled();
      expect(namesIn(g.outside), ['centinela']);
      Directory(temp).deleteSync();

      File(temp).writeAsStringSync('no es carpeta');
      final other = await g.sendFile('b.txt', [1], g.to(const ['sub']));
      expect(other.outcome, TransferOutcome.destinationUnavailable);
      await g.settled();
      expect(File(temp).readAsStringSync(), 'no es carpeta');
      File(temp).deleteSync();
    }, timeout: transferTimeout);
  });

  group('E742 the rules of the 004 and the 006 hold (RF-415)', () {
    test('E742 a file lands in docs\\sub without a question, with the mark '
        'and no temp; the same name never overwrites', () async {
      final g = await guardedNodes();
      final sub = '${g.docs}\\sub';
      File('$sub\\informe.txt').writeAsStringSync('viejo');
      final sent = await g.sendFile(
        'informe.txt',
        utf8.encode('nuevo'),
        g.to(const ['sub']),
      );
      expect(sent.outcome, TransferOutcome.saved);
      await g.settled();
      expect(File('$sub\\informe.txt').readAsStringSync(), 'viejo');
      final fresh = namesIn(sub).where((n) => n.startsWith('informe (')).single;
      expect(File('$sub\\$fresh').readAsStringSync(), 'nuevo');
      expect(File('$sub\\$fresh:Zone.Identifier').readAsStringSync(), zoneMark);
      expect(hasTempLeft(sub), isFalse);
      expect(
        g.b.states.where(
          (s) =>
              s.incoming?.stage == IncomingStage.folderQuestion ||
              s.incoming?.stage == IncomingStage.warning,
        ),
        isEmpty,
      );
      expect(g.b.state.prompts, isEmpty);
    }, timeout: transferTimeout);

    test('E742 a folder of the 006 reaches docs\\sub with the mark and '
        'Proyecto (1) beside it the second time', () async {
      final g = await guardedNodes();
      final sub = '${g.docs}\\sub';
      final folder = await smallFolder(g.a, 'Proyecto');
      final first = await g.sendFolder(folder, g.to(const ['sub']));
      expect(first.outcome, TransferOutcome.saved);
      await g.settled();
      expect(File('$sub\\Proyecto\\uno.txt').readAsBytesSync(), [1, 2, 3]);
      expect(File('$sub\\Proyecto\\dos\\dos.txt').readAsBytesSync(), [4, 5]);
      expect(
        File('$sub\\Proyecto\\uno.txt:Zone.Identifier').readAsStringSync(),
        zoneMark,
      );
      final second = await g.sendFolder(folder, g.to(const ['sub']));
      expect(second.outcome, TransferOutcome.saved);
      await g.settled();
      expect(namesIn(sub), ['Proyecto', 'Proyecto (1)', 'deep']);
      expect(hasTempLeft(sub), isFalse);
      expect(
        g.b.states.where(
          (s) => s.incoming?.stage == IncomingStage.folderQuestion,
        ),
        isEmpty,
      );
    }, timeout: transferTimeout);

    test('E742 a folder of the 006 reaches a new folder and a failed one '
        'leaves nothing', () async {
      final g = await guardedNodes();
      final folder = await smallFolder(g.a, 'Proyecto');
      final made = await g.sendFolder(
        folder,
        g.to(const ['sub'], newFolder: 'nueva'),
      );
      expect(made.outcome, TransferOutcome.saved);
      await g.settled();
      expect(namesIn('${g.docs}\\sub\\nueva'), ['Proyecto']);

      g.fs.forcedMove = const DestinationChanged();
      final failed = await g.sendFolder(
        folder,
        g.to(const ['sub'], newFolder: 'otra-nueva'),
      );
      expect(failed.outcome, TransferOutcome.destinationLost);
      await g.settled();
      expect(namesIn('${g.docs}\\sub'), ['deep', 'nueva']);
    }, timeout: transferTimeout);

    test('E742 a folder to a trap or to a missing place is refused before '
        'the manifest writes anything', () async {
      final g = await guardedNodes(tree: buildTrapTree);
      final folder = await smallFolder(g.a, 'Proyecto');
      final shot = folderShot(g.docs);
      final trap = await g.sendFolder(folder, g.to(const ['union']));
      expect(trap.outcome, TransferOutcome.destinationUnavailable);
      final gone = await g.sendFolder(folder, g.to(const ['falta']));
      expect(gone.outcome, TransferOutcome.destinationMissing);
      await g.settled();
      expect(folderShot(g.docs), shot);
      expect(namesIn(g.outside), ['centinela']);
    }, timeout: transferTimeout);

    test(
      'E742 without room the send gives noSpace and nothing stays',
      () async {
        final g = await guardedNodes();
        g.fs.freeBytes = 1;
        final sent = await g.sendFile(
          'grande.bin',
          List.filled(64 * 1024, 1),
          g.to(const ['sub']),
        );
        expect(sent.outcome, TransferOutcome.noSpace);
        final folder = await g.sendFolder(
          await smallFolder(
            g.a,
            'Proyecto',
            files: {'grande.bin': List.filled(64 * 1024, 2)},
          ),
          g.to(const ['sub']),
        );
        expect(folder.outcome, TransferOutcome.noSpace);
        await g.settled();
        expect(namesIn('${g.docs}\\sub'), ['deep']);
      },
      timeout: transferTimeout,
    );

    test('E742 a path that does not fit gives pathTooLong and no new folder '
        'stays', () async {
      late String deep;
      final g = await guardedNodes(
        tree: (b) {
          final docs = docsOf(b);
          deep = 'd' * (230 - docs.length);
          Directory('$docs\\$deep').createSync(recursive: true);
          return true;
        },
      );
      final sent = await g.sendFile('${'n' * 40}.txt', [1], g.to([deep]));
      expect(sent.outcome, TransferOutcome.pathTooLong);
      await g.settled();
      expect(namesIn('${g.docs}\\$deep'), isEmpty);
    }, timeout: transferTimeout);

    test('E742 a blocked type with a good destination is refused and creates '
        'no new folder', () async {
      final g = await guardedNodes();
      final sent = await g.sendFile('acceso.lnk', [
        1,
      ], g.to(const ['sub'], newFolder: 'nueva'));
      expect(sent.outcome, isNot(TransferOutcome.saved));
      await g.settled();
      expect(namesIn('${g.docs}\\sub'), ['deep']);
    }, timeout: transferTimeout);
  });

  group('E743 the recheck says no (RF-416) [SEG]', () {
    test('E743 a file: temp deleted, nothing in the destination and both see '
        'destinationLost', () async {
      final g = await guardedNodes();
      g.fs.forcedMove = const DestinationChanged();
      final receivedBefore = g.b.state.lastReceived;
      final sent = await g.sendFile('a.txt', [1, 2], g.to(const ['sub']));
      final received = await g.b.receivedResult(after: receivedBefore);
      expect(sent.outcome, TransferOutcome.destinationLost);
      expect(received.outcome, TransferOutcome.destinationLost);
      await g.settled();
      expect(namesIn('${g.docs}\\sub'), ['deep']);
      g.expectNothingLocked(['${g.docs}\\sub', g.docs]);
    }, timeout: transferTimeout);

    test('E743 a folder: temp deleted, nothing in the destination and both '
        'see destinationLost', () async {
      final g = await guardedNodes();
      g.fs.forcedMove = const DestinationChanged();
      final receivedBefore = g.b.state.lastReceived;
      final sent = await g.sendFolder(
        await smallFolder(g.a, 'Proyecto'),
        g.to(const ['sub']),
      );
      final received = await g.b.receivedResult(after: receivedBefore);
      expect(sent.outcome, TransferOutcome.destinationLost);
      expect(received.outcome, TransferOutcome.destinationLost);
      await g.settled();
      expect(namesIn('${g.docs}\\sub'), ['deep']);
      g.expectNothingLocked(['${g.docs}\\sub', g.docs]);
    }, timeout: transferTimeout);
  });

  group('E744 the chain cannot be swapped on NTFS (RF-416) [SEG]', () {
    test('E744 during the upload every folder of the path refuses to be '
        'renamed, deleted or turned into a junction; nothing shows outside '
        'and the file lands inside', () async {
      final g = await guardedNodes();
      final sub = '${g.docs}\\sub';
      final deep = '$sub\\deep';
      g.b.writes.hold();
      addTearDown(g.b.writes.release);
      final before = g.a.state.lastSent;
      await g.start(
        await g.a.sourceFile('a.bin', List.filled(4 * 1024 * 1024, 3)),
        g.to(const ['sub', 'deep']),
      );
      await g.b.incomingAt(IncomingStage.receiving);

      for (final folder in [deep, sub, g.docs, '$deep\\$tempFolderName']) {
        expect(
          renames(folder, '$folder.aparte'),
          isFalse,
          reason: 'rename of $folder',
        );
      }
      expect(() => Directory(deep).deleteSync(), throwsA(anything));
      for (final folder in [deep, sub, g.docs]) {
        expect(
          turnIntoJunction(folder, g.outside, access: writeAttributesOnly),
          isNot('ok'),
          reason: 'junction at $folder',
        );
      }
      expect(Directory(deep).existsSync(), isTrue);
      g.b.writes.release();
      final sent = await g.a.sentResult(after: before);
      expect(sent.outcome, TransferOutcome.saved);
      await g.settled();
      expect(File('$deep\\a.bin').lengthSync(), 4 * 1024 * 1024);
      expect(namesIn(g.outside), ['centinela']);
      g.expectNothingLocked([deep, sub, g.docs]);
    }, timeout: transferTimeout);
  });

  group('E748 an ACL that denies creating in the root (punto 4)', () {
    test('E748 a send to root\\sub lands with two real nodes', () async {
      final g = await guardedNodes();
      final user = Platform.environment['USERNAME'];
      if (user == null || user.isEmpty) {
        markTestSkipped('USERNAME is not set');
        return;
      }
      void icacls(List<String> arguments) => run('icacls', arguments);
      icacls([g.docs, '/deny', '$user:(WD,AD)']);
      addTearDown(() => icacls([g.docs, '/remove:d', user]));
      expect(
        () => File('${g.docs}\\prueba.txt').writeAsStringSync('x'),
        throwsA(isA<FileSystemException>()),
      );
      final sent = await g.sendFile('a.txt', [7], g.to(const ['sub']));
      expect(sent.outcome, TransferOutcome.saved);
      await g.settled();
      expect(File('${g.docs}\\sub\\a.txt').readAsBytesSync(), [7]);
    }, timeout: transferTimeout);
  });

  group(
    'E749 a folder of the chain hidden during the upload (RF-416) [SEG]',
    () {
      test('E749 a file: real recheck gives destinationLost on both sides, the '
          'temp goes and nothing lands anywhere', () async {
        final g = await guardedNodes();
        final sub = '${g.docs}\\sub';
        g.b.writes.hold();
        addTearDown(g.b.writes.release);
        final before = g.a.state.lastSent;
        final receivedBefore = g.b.state.lastReceived;
        await g.start(
          await g.a.sourceFile('a.bin', List.filled(4 * 1024 * 1024, 3)),
          g.to(const ['sub', 'deep']),
        );
        await g.b.incomingAt(IncomingStage.receiving);
        attrib('+h', sub);
        g.b.writes.release();
        final sent = await g.a.sentResult(after: before);
        final received = await g.b.receivedResult(after: receivedBefore);
        expect(sent.outcome, TransferOutcome.destinationLost);
        expect(received.outcome, TransferOutcome.destinationLost);
        await g.settled();
        expect(namesIn('$sub\\deep'), isEmpty);
        expect(namesIn(g.outside), ['centinela']);
        g.expectNothingLocked(['$sub\\deep', sub, g.docs]);
      }, timeout: transferTimeout);

      test(
        'E749 a folder of the 006: same result with the real recheck',
        () async {
          final g = await guardedNodes();
          final sub = '${g.docs}\\sub';
          g.fs.beforeMove = () async {
            g.fs.beforeMove = null;
            attrib('+h', sub);
          };
          final receivedBefore = g.b.state.lastReceived;
          final sent = await g.sendFolder(
            await smallFolder(g.a, 'Proyecto'),
            g.to(const ['sub', 'deep']),
          );
          final received = await g.b.receivedResult(after: receivedBefore);
          expect(sent.outcome, TransferOutcome.destinationLost);
          expect(received.outcome, TransferOutcome.destinationLost);
          await g.settled();
          expect(namesIn('$sub\\deep'), isEmpty);
          expect(namesIn(g.outside), ['centinela']);
        },
        timeout: transferTimeout,
      );
    },
  );

  group('T5 the destination survives a second element', () {
    test('two files in a row to the same destination both land and the temp '
        'folder goes away', () async {
      final g = await guardedNodes();
      final first = await g.sendFile('a.txt', [1], g.to(const ['sub']));
      final second = await g.sendFile('b.txt', [2], g.to(const ['sub']));
      expect(first.outcome, TransferOutcome.saved);
      expect(second.outcome, TransferOutcome.saved);
      await g.settled();
      expect(namesIn('${g.docs}\\sub'), ['a.txt', 'b.txt', 'deep']);
    }, timeout: transferTimeout);

    test('a send to the root itself lands there', () async {
      final g = await guardedNodes();
      final sent = await g.sendFile('a.txt', [
        1,
      ], const SharedFolderDestination(rootId: '', rootName: 'docs', path: []));
      expect(sent.outcome, isNot(TransferOutcome.saved));
      final good = await g.sendFile('b.txt', [1], g.to(const []));
      expect(good.outcome, TransferOutcome.saved);
      await g.settled();
      expect(namesIn(g.docs), ['b.txt', 'otra', 'sub']);
    }, timeout: transferTimeout);
  });

  group('M-1 the .git folder by name (RF-409, RF-413, RF-414) [SEG]', () {
    Future<Guarded> repoNodes() => guardedNodes(
      tree: (b) {
        buildSimpleTree(b);
        Directory('${docsOf(b)}\\sub\\.git\\hooks').createSync(recursive: true);
        return true;
      },
    );

    test('M-1 a visible .git is no destination: it is not listed, not '
        'explored and an offer by path or by new folder is refused', () async {
      final g = await repoNodes();
      final hooks = '${g.docs}\\sub\\.git\\hooks';
      final listed = await g.a.node.listRemoteFolders(
        g.b.fingerprint,
        g.rootId,
        const ['sub'],
      );
      expect((listed as RemoteFolders).names, ['deep']);
      for (final name in ['.git', '.GIT', '.Git']) {
        g.b.clock.advance(const Duration(seconds: 1));
        await expectBrowse(
          g.a,
          g.b,
          foldersAsk(g.rootId, ['sub', name]),
          404,
          unavailableBody,
          reason: name,
        );
        await expectOfferRefused(
          g,
          dest(g.rootId, ['sub', name, 'hooks']),
          reason: name,
        );
        await expectOfferRefused(
          g,
          dest(g.rootId, const ['otra'], fresh: name),
          reason: name,
        );
      }
      final hook = await g.sendFile('pre-commit', [
        35,
        33,
      ], g.to(const ['sub', '.git', 'hooks']));
      expect(hook.outcome, TransferOutcome.destinationUnavailable);
      final fresh = await g.sendFile('a.txt', [
        1,
      ], g.to(const ['otra'], newFolder: '.git'));
      expect(fresh.outcome, TransferOutcome.destinationUnavailable);
      await g.settled();
      expect(namesIn(hooks), isEmpty);
      expect(namesIn('${g.docs}\\otra'), isEmpty);
      expect(g.b.state.lastReceived, isNull);
      g.expectNothingLocked(['${g.docs}\\sub\\.git']);
    }, timeout: transferTimeout);

    test('M-1 a file or a folder named .git sent to a shared folder is '
        'refused with invalid_name and nothing is written', () async {
      final g = await repoNodes();
      final sub = '${g.docs}\\sub';
      final file = await g.sendFile('.GIT', [1, 2], g.to(const ['sub']));
      expect(file.outcome, TransferOutcome.invalidName);
      File('${g.a.sourceDir}\\.GIT').deleteSync();
      final folder = await g.sendFolder(
        await smallFolder(g.a, '.git'),
        g.to(const ['sub']),
      );
      expect(folder.outcome, TransferOutcome.invalidName);
      for (final name in ['.git', '.GIT']) {
        g.b.clock.advance(offerWindow);
        final reply = await rawPost(
          g.a,
          g.b,
          ApiPaths.transferOffer,
          rawFileOffer(name, [1], destination: dest(g.rootId, const ['otra'])),
        );
        expect(reply!.status, 422, reason: name);
        expect(
          reply.body,
          utf8.encode('{"error":"invalid_name"}'),
          reason: name,
        );
      }
      await g.settled();
      expect(namesIn(sub), ['.git', 'deep']);
      expect(namesIn('${g.docs}\\otra'), isEmpty);
      expect(hasTempLeft(sub), isFalse);
      expect(g.b.state.lastReceived, isNull);
    }, timeout: transferTimeout);

    test('M-1 a file named .git without a destination and a repository with '
        'its .git inside to a shared folder still travel', () async {
      final g = await repoNodes();
      final plain = await g.a.sourceFile('.git', [1, 2, 3]);
      expect(await g.a.send(g.b, plain), SendResult.started);
      expect((await g.a.sentResult()).outcome, TransferOutcome.saved);
      final repo = await smallFolder(
        g.a,
        'Repo',
        files: const {
          'uno.txt': [1],
          '.git\\config': [2, 3],
        },
      );
      final sent = await g.sendFolder(repo, g.to(const ['otra']));
      expect(sent.outcome, TransferOutcome.saved);
      await g.settled();
      expect(File('${g.docs}\\otra\\Repo\\.git\\config').readAsBytesSync(), [
        2,
        3,
      ]);
    }, timeout: transferTimeout);
  });
}
