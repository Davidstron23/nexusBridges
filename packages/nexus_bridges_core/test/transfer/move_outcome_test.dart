@TestOn('windows')
library;

import 'dart:io';

import 'package:nexus_bridges_core/src/transfer/platform.dart';
import 'package:nexus_bridges_core/src/transfer/windows_folder_io.dart';
import 'package:test/test.dart';

import 'folders_fakes.dart' hide join;

String j(String a, [String? b, String? c, String? d]) =>
    [a, ?b, ?c, ?d].join(r'\');

void main() {
  late String root;

  setUp(() async {
    root = await tempFolder('nexus_t6_move_');
  });

  group('Q-7: what the user sees does not depend on an error code', () {
    test(
      'a file moved to a free name is moved and the source is gone',
      () async {
        File(j(root, 'from.txt')).writeAsStringSync('data');

        final outcome = await windowsFs.moveNoReplace(
          j(root, 'from.txt'),
          j(root, 'to.txt'),
        );

        expect(outcome, MoveOutcome.moved);
        expect(File(j(root, 'to.txt')).readAsStringSync(), 'data');
        expect(File(j(root, 'from.txt')).existsSync(), isFalse);
      },
    );

    test('an existing file or folder at the target is a taken name and '
        'nothing is replaced', () async {
      File(j(root, 'from.txt')).writeAsStringSync('new');
      File(j(root, 'taken.txt')).writeAsStringSync('old');
      Directory(j(root, 'dir')).createSync();
      Directory(j(root, 'src')).createSync();
      File(j(root, 'src', 'in.txt')).writeAsStringSync('in');

      final onFile = await windowsFs.moveNoReplace(
        j(root, 'from.txt'),
        j(root, 'taken.txt'),
      );
      final onFolder = await windowsFs.moveNoReplace(
        j(root, 'src'),
        j(root, 'dir'),
      );
      final upper = await windowsFs.moveNoReplace(
        j(root, 'from.txt'),
        j(root, 'TAKEN.TXT'),
      );

      expect(onFile, MoveOutcome.nameTaken);
      expect(onFolder, MoveOutcome.nameTaken);
      expect(upper, MoveOutcome.nameTaken);
      expect(File(j(root, 'taken.txt')).readAsStringSync(), 'old');
      expect(File(j(root, 'from.txt')).readAsStringSync(), 'new');
      expect(File(j(root, 'src', 'in.txt')).existsSync(), isTrue);
    });

    test('a source that does not exist fails and creates nothing', () async {
      final outcome = await windowsFs.moveNoReplace(
        j(root, 'ghost.txt'),
        j(root, 'to.txt'),
      );

      expect(outcome, MoveOutcome.failed);
      expect(File(j(root, 'to.txt')).existsSync(), isFalse);
    });

    test('a target in a folder that does not exist fails and creates '
        'nothing', () async {
      File(j(root, 'from.txt')).writeAsStringSync('data');

      final outcome = await windowsFs.moveNoReplace(
        j(root, 'from.txt'),
        j(root, 'nowhere', 'to.txt'),
      );

      expect(outcome, MoveOutcome.failed);
      expect(File(j(root, 'from.txt')).readAsStringSync(), 'data');
      expect(Directory(j(root, 'nowhere')).existsSync(), isFalse);
    });

    test(
      'a folder that is busy for a moment is moved once it is free',
      () async {
        final source = j(root, 'busy');
        Directory(source).createSync();
        final held = openRootSync(source);
        expect(held, isA<NodeCreated>());
        final handle = (held as NodeCreated).handle;
        addTearDown(handle.close);

        final pending = windowsFs.moveNoReplace(source, j(root, 'free'));
        await Future<void>.delayed(const Duration(milliseconds: 150));
        handle.close();
        final outcome = await pending;

        expect(outcome, MoveOutcome.moved);
        expect(Directory(j(root, 'free')).existsSync(), isTrue);
        expect(Directory(source).existsSync(), isFalse);
      },
    );

    test('a folder that stays busy fails and stays where it was', () async {
      final source = j(root, 'busy');
      Directory(source).createSync();
      final held = openRootSync(source);
      final handle = (held as NodeCreated).handle;
      addTearDown(handle.close);

      final outcome = await windowsFs.moveNoReplace(source, j(root, 'free'));

      expect(outcome, MoveOutcome.failed);
      expect(Directory(source).existsSync(), isTrue);
      expect(Directory(j(root, 'free')).existsSync(), isFalse);
    });

    test('moving a folder to a free name skips the taken ones whatever '
        'their case and keeps the others intact', () async {
      final source = j(root, 'src');
      Directory(source).createSync();
      File(j(source, 'in.txt')).writeAsStringSync('in');
      Directory(j(root, 'proj')).createSync();
      File(j(root, 'PROJ (1)')).writeAsStringSync('file');

      final moved = await windowsFs.moveFolderToFreeName(
        source,
        root,
        'Proj',
        maxNameUnits: 255,
      );

      expect(moved, isA<MovedTo>());
      expect((moved as MovedTo).finalName, 'Proj (2)');
      expect(File(j(root, 'Proj (2)', 'in.txt')).readAsStringSync(), 'in');
      expect(File(j(root, 'PROJ (1)')).readAsStringSync(), 'file');
    });
  });
}
