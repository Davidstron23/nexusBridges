import 'dart:convert';
import 'dart:io';

import 'package:nexus_bridges_core/src/node/node.dart';
import 'package:nexus_bridges_core/src/settings/settings.dart'
    show loadStartupSettings;
import 'package:test/test.dart';

import 'two_nodes_harness.dart';

const List<String> _defaults = ['node_modules', 'build', '.dart_tool'];

File _settingsOf(TestNode node) =>
    File('${node.dataDir.path}${sep}settings.json');

Future<Map<String, Object?>?> _saved(TestNode node) async {
  final file = _settingsOf(node);
  if (!await file.exists()) return null;
  return jsonDecode(await file.readAsString()) as Map<String, Object?>;
}

void _break(File file) {
  if (file.existsSync()) file.deleteSync();
  Directory(file.path).createSync(recursive: true);
}

Future<TestNode> _single() async {
  for (var attempt = 0; attempt < 5; attempt++) {
    final node = await TestNode.create('Desk PC', hostA);
    node.port = await freePort();
    if (await node.launch()) return node;
    await node.node.shutdown();
  }
  fail('could not start a node');
}

Future<ExclusionOutcome> _add(TestNode node, String raw) =>
    node.inZone(() => node.node.addExclusion(raw));

Future<void> _remove(TestNode node, String name) =>
    node.inZone(() => node.node.removeExclusion(name));

Future<void> _restore(TestNode node) =>
    node.inZone(() => node.node.restoreExclusions());

void main() {
  group('E811: the exclusion list is edited and survives a restart (RF-518, '
      'RF-520)', () {
    test('a new node shows the default list and has not written it', () async {
      final a = await _single();

      expect(a.state.settings.exclusions, _defaults);
      expect((await _saved(a))?['exclusions'], isNull);
    }, timeout: twoNodesTimeout);

    test('add dist and remove build: the state changes at once, the list is '
        'saved and it is the same after a restart', () async {
      final a = await _single();

      expect(await _add(a, 'dist'), const ExclusionOutcome());
      expect(a.state.settings.exclusions, [..._defaults, 'dist']);
      await _remove(a, 'build');
      expect(a.state.settings.exclusions, [
        'node_modules',
        '.dart_tool',
        'dist',
      ]);
      expect((await _saved(a))!['exclusions'], [
        'node_modules',
        '.dart_tool',
        'dist',
      ]);

      await a.restart();

      expect(a.state.settings.exclusions, [
        'node_modules',
        '.dart_tool',
        'dist',
      ]);
    }, timeout: twoNodesTimeout);

    test('the name is trimmed before it is added and removing does not mind '
        'the case', () async {
      final a = await _single();

      expect(await _add(a, '  dist  '), const ExclusionOutcome());
      expect(a.state.settings.exclusions.last, 'dist');
      await _remove(a, 'NODE_MODULES');
      expect(a.state.settings.exclusions, ['build', '.dart_tool', 'dist']);
    }, timeout: twoNodesTimeout);

    test('removing the three gives an empty list that is saved and stays '
        'empty after a restart', () async {
      final a = await _single();

      for (final name in _defaults) {
        await _remove(a, name);
      }

      expect(a.state.settings.exclusions, isEmpty);
      expect((await _saved(a))!['exclusions'], isEmpty);
      await a.restart();
      expect(a.state.settings.exclusions, isEmpty);
    }, timeout: twoNodesTimeout);

    test('restoreExclusions brings back the default list and saves it; with '
        'the default list already in place it writes nothing', () async {
      final a = await _single();
      await _add(a, 'dist');
      await _remove(a, 'build');

      await _restore(a);

      expect(a.state.settings.exclusions, _defaults);
      expect((await _saved(a))!['exclusions'], _defaults);
      await a.restart();
      expect(a.state.settings.exclusions, _defaults);

      await _settingsOf(a).delete();
      final before = a.states.length;
      await _restore(a);

      expect(_settingsOf(a).existsSync(), isFalse);
      expect(a.state.settings.exclusions, _defaults);
      expect(a.states.skip(before), isEmpty);
      expect(a.state.notices, isEmpty);
    }, timeout: twoNodesTimeout);

    test('restoreExclusions with the default names in another order writes '
        'nothing either', () async {
      final a = await _single();
      for (final name in _defaults) {
        await _remove(a, name);
      }
      for (final name in ['.dart_tool', 'node_modules', 'build']) {
        await _add(a, name);
      }
      await _settingsOf(a).delete();

      await _restore(a);

      expect(_settingsOf(a).existsSync(), isFalse);
      expect(a.state.settings.exclusions, [
        '.dart_tool',
        'node_modules',
        'build',
      ]);
    }, timeout: twoNodesTimeout);

    test('an invalid, empty, repeated or extra name is refused with its '
        'problem and nothing changes or is written', () async {
      final a = await _single();
      await _add(a, 'dist');
      final saved = await _saved(a);
      final before = a.states.length;

      expect(
        await _add(a, '   '),
        const ExclusionOutcome(problem: ExclusionProblem.empty),
      );
      expect(
        await _add(a, 'a:b'),
        const ExclusionOutcome(problem: ExclusionProblem.invalid),
      );
      expect(
        await _add(a, 'CON'),
        const ExclusionOutcome(problem: ExclusionProblem.invalid),
      );
      expect(
        await _add(a, 'Node_Modules'),
        const ExclusionOutcome(problem: ExclusionProblem.duplicate),
      );

      expect(a.state.settings.exclusions, [..._defaults, 'dist']);
      expect(await _saved(a), saved);
      expect(a.states.skip(before), isEmpty);
    }, timeout: twoNodesTimeout);

    test('with 64 names the next one is full', () async {
      final a = await _single();
      for (var i = a.state.settings.exclusions.length; i < 64; i++) {
        expect(await _add(a, 'n$i'), const ExclusionOutcome());
      }
      expect(a.state.settings.exclusions, hasLength(64));

      expect(
        await _add(a, 'one-more'),
        const ExclusionOutcome(problem: ExclusionProblem.full),
      );
      expect(a.state.settings.exclusions, hasLength(64));
      await a.restart();
      expect(a.state.settings.exclusions, hasLength(64));
    }, timeout: twoNodesTimeout);

    test('a list in settings.json with repeated names falls back to the '
        'default list in the node', () async {
      final a = await TestNode.create('Desk PC', hostA);
      a.port = await freePort();
      await a.dataDir.create(recursive: true);
      await _settingsOf(a).writeAsString(
        jsonEncode({
          'version': 1,
          'exclusions': ['dist', 'DIST'],
        }),
      );

      expect(await a.launch(), isTrue);

      expect(a.state.settings.exclusions, _defaults);
    }, timeout: twoNodesTimeout);
  });

  group('E814: the node saves the settings the app applies (RF-502, RF-510, '
      'RF-511, RF-503, DA-19)', () {
    test('saveLanguage, saveTheme, saveCloseToTray and saveTrayHintShown are '
        'what loadStartupSettings gives back, without notices', () async {
      final a = await _single();

      await a.inZone(() => a.node.saveLanguage('en'));
      await a.inZone(() => a.node.saveTheme(ThemeChoice.light));
      await a.inZone(() => a.node.saveCloseToTray(false));
      await a.inZone(() => a.node.saveTrayHintShown());

      final loaded = await loadStartupSettings(
        platformLanguageCode: 'es',
        dataDir: a.dataDir,
      );
      expect(loaded.language, 'en');
      expect(loaded.theme, ThemeChoice.light);
      expect(loaded.closeToTray, isFalse);
      expect(loaded.trayHintShown, isTrue);
      expect(a.state.notices, isEmpty);

      await a.inZone(() => a.node.setDeviceName('PC David'));
      await a.inZone(() => a.node.addExclusion('dist'));
      expect(await _saved(a), {
        'version': 1,
        'language': 'en',
        'theme': 'light',
        'closeToTray': false,
        'trayHintShown': true,
        'deviceName': 'PC David',
        'exclusions': [..._defaults, 'dist'],
      });
    }, timeout: twoNodesTimeout);

    test(
      'with settings.json not writable each save gives the settingNotSaved '
      'notice without retry, except the tray hint, which gives none',
      () async {
        final a = await _single();
        _break(_settingsOf(a));

        await a.inZone(() => a.node.saveTrayHintShown());
        expect(a.noticesOf(NoticeKind.settingNotSaved), isEmpty);

        await a.inZone(() => a.node.saveLanguage('en'));
        final notices = a.noticesOf(NoticeKind.settingNotSaved);
        expect(notices, isNotEmpty);
        expect(notices.every((n) => !n.canRetry), isTrue);

        for (final save in [
          () => a.node.saveTheme(ThemeChoice.system),
          () => a.node.saveCloseToTray(false),
        ]) {
          final count = a.state.notices.length;
          await a.inZone(save);
          expect(
            a.noticesOf(NoticeKind.settingNotSaved),
            isNotEmpty,
            reason: 'notice count before: $count',
          );
        }
        expect(a.state.unsavedChanges, isFalse);
      },
      timeout: twoNodesTimeout,
    );

    test('an exclusion that cannot be saved stays in the list for the session '
        'with the settingNotSaved notice', () async {
      final a = await _single();
      _break(_settingsOf(a));

      final outcome = await _add(a, 'dist');

      expect(outcome, const ExclusionOutcome(saved: false));
      expect(a.state.settings.exclusions, [..._defaults, 'dist']);
      final notices = a.noticesOf(NoticeKind.settingNotSaved);
      expect(notices, isNotEmpty);
      expect(notices.every((n) => !n.canRetry), isTrue);

      await _remove(a, 'build');
      expect(a.state.settings.exclusions, [
        'node_modules',
        '.dart_tool',
        'dist',
      ]);
      expect(
        a.logs.where((l) => l.contains('dist') || l.contains('node_modules')),
        isEmpty,
        reason: 'logs never carry the names',
      );
    }, timeout: twoNodesTimeout);
  });
}
