@TestOn('windows')
library;

import 'dart:io';

import 'package:nexus_bridges_core/src/node/node.dart';
import 'package:nexus_bridges_core/src/pairing/pairing.dart' show PeerRelation;
import 'package:test/test.dart';

import 'transfer_nodes_harness.dart';

Future<String> _folder(
  TransferNode node,
  String name,
  Map<String, String> files,
) async {
  final root = '${node.sourceDir}\\$name';
  Directory(root).createSync(recursive: true);
  for (final MapEntry(:key, :value) in files.entries) {
    final file = File('$root\\$key');
    file.parent.createSync(recursive: true);
    await file.writeAsString(value, flush: true);
  }
  return root;
}

Future<TransferResultView> _received(TransferNode node, String name) async {
  final s = await node.until(
    (s) =>
        s.lastReceived?.fileName == name &&
        (s.incoming == null || s.incoming!.stage == IncomingStage.ended),
    reason: '${node.name} received $name',
  );
  return s.lastReceived!;
}

Future<void> _idle(TransferNode node) => node.until(
  (s) => s.sendingTo == null && s.outgoing == null && !s.transferInProgress,
  reason: '${node.name} idle',
);

Set<String> _tree(String root) => {
  for (final entity in Directory(root).listSync(recursive: true))
    entity.path.substring(root.length + 1).toLowerCase(),
};

void _break(File file) {
  if (file.existsSync()) file.deleteSync();
  Directory(file.path).createSync(recursive: true);
}

void main() {
  group('E812: the edited list is the one the sender applies (RF-518, '
      'DA-11)', () {
    test('without build in the list, build arrives and node_modules does not; '
        'with dist added, dist does not arrive', () async {
      final (a, b) = await transferNodes();

      await a.node.removeExclusion('build');
      final first = await _folder(a, 'proj', {
        'build\\out.txt': 'built',
        'node_modules\\dep\\index.js': 'dep',
        'src\\main.dart': 'main',
      });
      expect(
        await a.node.sendPaths(b.fingerprint, [first]),
        SendResult.started,
      );
      expect((await _received(b, 'proj')).outcome, TransferOutcome.saved);
      await _idle(a);

      expect(_tree('${b.recvDir}\\proj'), {
        'build',
        'build\\out.txt',
        'src',
        'src\\main.dart',
      });

      expect(await a.node.addExclusion('dist'), const ExclusionOutcome());
      final second = await _folder(a, 'web', {
        'dist\\bundle.js': 'bundle',
        'src\\app.ts': 'app',
        'Build\\keep.txt': 'kept',
      });
      expect(
        await a.node.sendPaths(b.fingerprint, [second]),
        SendResult.started,
      );
      expect((await _received(b, 'web')).outcome, TransferOutcome.saved);

      expect(_tree('${b.recvDir}\\web'), {
        'build',
        'build\\keep.txt',
        'src',
        'src\\app.ts',
      });
    }, timeout: transferTimeout);

    test(
      'an exclusion in another case than the folder is applied too',
      () async {
        final (a, b) = await transferNodes();
        await a.node.addExclusion('DIST');
        final folder = await _folder(a, 'site', {
          'dist\\index.html': 'x',
          'page.html': 'y',
        });

        expect(
          await a.node.sendPaths(b.fingerprint, [folder]),
          SendResult.started,
        );
        await _received(b, 'site');

        expect(_tree('${b.recvDir}\\site'), {'page.html'});
      },
      timeout: transferTimeout,
    );

    test('changing the list once the folder has been planned and offered does '
        'not change the manifest on its way', () async {
      final (a, b) = await transferNodes(aAtB: PeerRelation.foreign);
      final folder = await _folder(a, 'app', {
        'dist\\bundle.js': 'bundle',
        'node_modules\\dep.js': 'dep',
        'src\\main.ts': 'main',
      });

      expect(
        await a.node.sendPaths(b.fingerprint, [folder]),
        SendResult.started,
      );
      final warning = await b.incomingAt(IncomingStage.warning);
      expect(await a.node.addExclusion('dist'), const ExclusionOutcome());
      await a.node.removeExclusion('node_modules');
      b.node.answerIncoming(warning.sessionId, accept: true);
      expect((await _received(b, 'app')).outcome, TransferOutcome.saved);

      expect(_tree('${b.recvDir}\\app'), {
        'dist',
        'dist\\bundle.js',
        'src',
        'src\\main.ts',
      });
    }, timeout: transferTimeout);
  });

  group('E813: an exclusion that cannot be saved is used anyway (RF-503, '
      'RF-518)', () {
    test('with settings.json not writable, addExclusion(dist) gives saved '
        'false and the notice, and the next folder already leaves dist '
        'out', () async {
      final (a, b) = await transferNodes();
      _break(a.settingsFile);

      final outcome = await a.node.addExclusion('dist');

      expect(outcome, const ExclusionOutcome(saved: false));
      expect(a.noticesOf(NoticeKind.settingNotSaved), isNotEmpty);
      expect(a.state.settings.exclusions, contains('dist'));

      final folder = await _folder(a, 'proj', {
        'dist\\bundle.js': 'bundle',
        'src\\main.ts': 'main',
      });
      expect(
        await a.node.sendPaths(b.fingerprint, [folder]),
        SendResult.started,
      );
      expect((await _received(b, 'proj')).outcome, TransferOutcome.saved);

      expect(_tree('${b.recvDir}\\proj'), {'src', 'src\\main.ts'});
      expect(Directory(a.settingsFile.path).existsSync(), isTrue);
    }, timeout: transferTimeout);
  });
}
