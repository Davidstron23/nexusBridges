@TestOn('windows')
library;

import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:nexus_bridges_core/src/transfer/folders.dart';
import 'package:nexus_bridges_core/src/transfer/platform.dart';
import 'package:nexus_bridges_core/src/transport/transport.dart'
    show AbortSignal;
import 'package:test/test.dart';
import 'package:win32/win32.dart';

import 'folders_fakes.dart';

const ForbiddenFolders noneForbidden = ForbiddenFolders(trees: [], exact: []);

final RegExp volumeIdFormat = RegExp(r'^[A-Za-z0-9]{1,16}-[0-9a-f]{8}$');

Matcher refused(FolderRefusal reason) =>
    isA<FolderRefused>().having((r) => r.reason, 'reason', reason);

FolderUsable usable(FolderInspection inspection) {
  expect(inspection, isA<FolderUsable>());
  return inspection as FolderUsable;
}

void main() {
  group('samePath (E173, RF-242, v2 point 22)', () {
    final equal = <(String, String)>[
      (r'C:\Users\David', r'c:\users\david'),
      (r'C:\Users\David', 'C:/Users/David'),
      (r'C:\Users\David\', r'C:\Users\David'),
      ('C:/Users/David/', r'c:\USERS\david'),
      (r'C:\', r'c:\'),
      (r'C:\', 'C:/'),
      (r'\\srv\share\', r'\\SRV\Share'),
      (r'D:\Recibidos', r'd:\RECIBIDOS\'),
    ];
    for (final (a, b) in equal) {
      test('"$a" and "$b" are the same', () {
        expect(samePath(a, b), isTrue);
        expect(samePath(b, a), isTrue);
      });
    }

    final different = <(String, String)>[
      (r'C:\Users\David', r'C:\Users\David2'),
      (r'C:\Users', r'C:\Users\David'),
      (r'C:\', r'D:\'),
      (r'C:\Windows', r'C:\Windows\System32'),
      (r'\\srv\share', r'\\srv\share2'),
      (r'C:\a b', r'C:\ab'),
    ];
    for (final (a, b) in different) {
      test('"$a" and "$b" are different', () {
        expect(samePath(a, b), isFalse);
        expect(samePath(b, a), isFalse);
      });
    }
  });

  group('isSameOrInside (RF-242)', () {
    final cases = <(String, String, bool)>[
      (r'C:\Windows', r'C:\Windows', true),
      (r'C:\Windows\System32', r'C:\Windows', true),
      (r'c:\windows\system32\drivers', r'C:\WINDOWS\', true),
      ('C:/Windows/Temp', r'C:\Windows', true),
      (r'C:\Windows2', r'C:\Windows', false),
      (r'C:\Windows2\x', r'C:\Windows', false),
      (r'C:\', r'C:\Windows', false),
      (r'C:\Users\David', r'C:\', true),
      (r'D:\Windows', r'C:\Windows', false),
      (r'\\srv\share\Windows', r'C:\Windows', false),
    ];
    for (final (path, ancestor, expected) in cases) {
      test('"$path" inside "$ancestor" is $expected', () {
        expect(isSameOrInside(path, ancestor), expected);
      });
    }
  });

  group('isForbiddenFolder (E13, RF-242)', () {
    const forbidden = ForbiddenFolders(
      trees: [r'C:\Windows', r'C:\Program Files'],
      exact: [r'C:\'],
    );
    final cases = <(String, bool)>[
      (r'C:\Windows\System32', true),
      (r'C:\Program Files', true),
      (r'C:\', true),
      (r'C:\Users', false),
      (r'C:\Windows2', false),
      (r'c:\WINDOWS\temp', true),
      (r'c:\program files\', true),
      (r'\\srv\share', false),
      (r'C:\Program Files (x86)', false),
      (r'D:\', false),
    ];
    for (final (path, expected) in cases) {
      test('"$path" is ${expected ? '' : 'not '}forbidden', () {
        expect(isForbiddenFolder(path, forbidden), expected);
      });
    }
  });

  group('isOwnTempName (RF-235)', () {
    test('accepts exactly the prefix, 32 lower-case hex and the suffix', () {
      expect(isOwnTempName(ownTemp(hexA)), isTrue);
      expect(isOwnTempName('$tempPrefix$hexB$tempSuffix'), isTrue);
    });

    final rejected = <String>[
      '~nexusbridges-foo.partial',
      '~nexusbridges-${hexA.toUpperCase()}.partial',
      '~nexusbridges-${hexA.substring(1)}.partial',
      '~nexusbridges-${hexA}0.partial',
      '~nexusbridges-$hexA.partial.txt',
      '~nexusbridges-$hexA.PARTIAL',
      'x~nexusbridges-$hexA.partial',
      '~NEXUSBRIDGES-$hexA.partial',
      'informe.pdf',
      '',
      '.nexusbridges-incoming',
    ];
    for (final name in rejected) {
      test('rejects "$name"', () {
        expect(isOwnTempName(name), isFalse);
      });
    }
  });

  group('loadForbiddenFolders (RF-242, D34)', () {
    late String root;
    late SystemFolders complete;

    setUp(() async {
      root = await tempFolder();
      complete = SystemFolders(
        downloads: await makeDir(join(root, 'Downloads')),
        startup: await makeDir(join(root, 'Startup')),
        commonStartup: await makeDir(join(root, 'CommonStartup')),
        startMenu: await makeDir(join(root, 'StartMenu')),
        commonStartMenu: await makeDir(join(root, 'CommonStartMenu')),
        windows: await makeDir(join(root, 'Windows')),
        programFiles: await makeDir(join(root, 'ProgramFiles')),
        programFilesX86: await makeDir(join(root, 'ProgramFilesX86')),
        systemDriveRoot: join(root, 'Drive'),
      );
    });

    SystemFolders without(String missing) => SystemFolders(
      downloads: complete.downloads,
      startup: missing == 'startup' ? null : complete.startup,
      commonStartup: complete.commonStartup,
      startMenu: missing == 'startMenu' ? null : complete.startMenu,
      commonStartMenu: complete.commonStartMenu,
      windows: missing == 'windows' ? null : complete.windows,
      programFiles: missing == 'programFiles' ? null : complete.programFiles,
      programFilesX86: complete.programFilesX86,
      systemDriveRoot: missing == 'systemDriveRoot'
          ? null
          : complete.systemDriveRoot,
    );

    for (final missing in [
      'windows',
      'programFiles',
      'startup',
      'startMenu',
      'systemDriveRoot',
    ]) {
      test('without $missing it gives null (fail closed)', () async {
        final forbidden = await loadForbiddenFolders(
          windowsFs,
          without(missing),
          dataDirs: [join(root, 'Data')],
        );

        expect(forbidden, isNull);
      });
    }

    test('trees hold the seven system folders and the data folder; exact '
        'holds the system drive root', () async {
      final data = await makeDir(join(root, 'Data'));

      final forbidden = await loadForbiddenFolders(
        windowsFs,
        complete,
        dataDirs: [data],
      );

      expect(forbidden, isNotNull);
      expect(forbidden!.trees.length, 8);
      for (final path in [
        complete.startup!,
        complete.commonStartup!,
        complete.startMenu!,
        complete.commonStartMenu!,
        complete.windows!,
        complete.programFiles!,
        complete.programFilesX86!,
        data,
      ]) {
        expect(forbidden.trees.any((t) => samePath(t, path)), isTrue);
      }
      expect(
        forbidden.trees.any((t) => samePath(t, complete.downloads!)),
        isFalse,
      );
      expect(forbidden.exact, [complete.systemDriveRoot]);
    });

    test('the common folders and Program Files (x86) are left out when '
        'missing', () async {
      final folders = SystemFolders(
        startup: complete.startup,
        startMenu: complete.startMenu,
        windows: complete.windows,
        programFiles: complete.programFiles,
        systemDriveRoot: complete.systemDriveRoot,
      );

      final forbidden = await loadForbiddenFolders(
        windowsFs,
        folders,
        dataDirs: const [],
      );

      expect(forbidden, isNotNull);
      expect(forbidden!.trees.length, 4);
    });

    test('system folders reached through a junction are stored by their '
        'real path', () async {
      final realStartup = complete.startup!;
      final alias = await makeJunction(join(root, 'StartupAlias'), realStartup);
      final folders = SystemFolders(
        startup: alias,
        startMenu: complete.startMenu,
        windows: complete.windows,
        programFiles: complete.programFiles,
        systemDriveRoot: complete.systemDriveRoot,
      );

      final forbidden = await loadForbiddenFolders(
        windowsFs,
        folders,
        dataDirs: const [],
      );

      expect(forbidden!.trees.any((t) => samePath(t, realStartup)), isTrue);
      expect(forbidden.trees.any((t) => samePath(t, alias)), isFalse);
    });

    test('a system folder whose real path cannot be read is kept as '
        'given', () async {
      final ghost = join(root, 'GhostWindows');
      final folders = SystemFolders(
        startup: complete.startup,
        startMenu: complete.startMenu,
        windows: ghost,
        programFiles: complete.programFiles,
        systemDriveRoot: complete.systemDriveRoot,
      );

      final forbidden = await loadForbiddenFolders(
        windowsFs,
        folders,
        dataDirs: const [],
      );

      expect(forbidden!.trees, contains(ghost));
    });

    test('a data folder that does not exist is used as given and a data '
        'folder behind a junction by its real path', () async {
      final missingData = join(root, 'MissingData');
      final realData = await makeDir(join(root, 'RealData'));
      final aliasData = await makeJunction(join(root, 'AliasData'), realData);

      final forbidden = await loadForbiddenFolders(
        windowsFs,
        complete,
        dataDirs: [missingData, aliasData],
      );

      expect(forbidden!.trees, contains(missingData));
      expect(forbidden.trees.any((t) => samePath(t, realData)), isTrue);
      expect(forbidden.trees.any((t) => samePath(t, aliasData)), isFalse);
      expect(await Directory(missingData).exists(), isFalse);
    });
  });

  group('inspectFolder on an existing folder', () {
    late String root;

    setUp(() async {
      root = await tempFolder();
    });

    test('a usable folder gives its real path, volume and space and leaves '
        'nothing behind', () async {
      final folder = await makeDir(join(root, 'Recibidos'));
      await File(join(folder, 'mine.txt')).writeAsString('hola');

      final result = usable(
        await inspectFolder(
          folder,
          fs: windowsFs,
          forbidden: noneForbidden,
          mayCreate: false,
        ),
      );

      expect(samePath(result.target.path, folder), isTrue);
      expect(result.target.volumeId, matches(volumeIdFormat));
      expect(result.target.supportsMark, isTrue);
      expect(result.target.remote, isFalse);
      expect(result.target.cloud, isFalse);
      expect(result.target.freeBytes, greaterThan(0));
      expect(result.createdNow, isFalse);
      expect(namesIn(folder), ['mine.txt']);
      expect(await File(join(folder, 'mine.txt')).readAsString(), 'hola');
    });

    test('the target path is the real path, not the junction that leads '
        'to it', () async {
      final folder = await makeDir(join(root, 'Real'));
      final alias = await makeJunction(join(root, 'Alias'), folder);

      final result = usable(
        await inspectFolder(
          alias,
          fs: windowsFs,
          forbidden: noneForbidden,
          mayCreate: false,
        ),
      );

      expect(samePath(result.target.path, folder), isTrue);
    });

    test('an existing temp subfolder is kept, hidden and left without '
        'probes', () async {
      final folder = await makeDir(join(root, 'Recibidos'));
      final sub = await makeDir(join(folder, tempFolderName));
      final fs = FakePlatform();

      usable(
        await inspectFolder(
          folder,
          fs: fs,
          forbidden: noneForbidden,
          mayCreate: false,
        ),
      );

      expect(await Directory(sub).exists(), isTrue);
      expect(namesIn(sub), isEmpty);
      expect(fs.callsOf('setHidden').any((p) => samePath(p, sub)), isTrue);
    });

    test('the same folder written with / and a final \\ is inspected as '
        'the same folder', () async {
      final folder = await makeDir(join(root, 'Recibidos'));

      final result = usable(
        await inspectFolder(
          '${folder.replaceAll(r'\', '/')}/',
          fs: windowsFs,
          forbidden: noneForbidden,
          mayCreate: false,
        ),
      );

      expect(samePath(result.target.path, folder), isTrue);
    });

    for (final path in [
      'Recibidos',
      r'Recibidos\sub',
      r'\Recibidos',
      '',
      r'C:Recibidos',
    ]) {
      test('a path that is not absolute ("$path") gives cannotUse', () async {
        final fs = FakePlatform();

        expect(
          await inspectFolder(
            path,
            fs: fs,
            forbidden: noneForbidden,
            mayCreate: true,
          ),
          refused(FolderRefusal.cannotUse),
        );
        expect(fs.calls, isEmpty);
      });
    }

    test('a path with characters Windows does not allow gives '
        'cannotUse', () async {
      for (final name in ['a*b', 'a?b', 'a"b', 'a<b', 'a>b', 'a|b', 'a:b']) {
        final fs = FakePlatform();
        expect(
          await inspectFolder(
            join(root, name),
            fs: fs,
            forbidden: noneForbidden,
            mayCreate: true,
          ),
          refused(FolderRefusal.cannotUse),
        );
        expect(fs.calls, isEmpty);
      }
      expect(namesIn(root), isEmpty);
    });
  });

  group('inspectFolder creates only the last folder (E21, RF-146)', () {
    late String root;

    setUp(() async {
      root = await tempFolder();
    });

    test('a missing folder whose parent exists is created alone and its '
        'temp subfolder does not stay', () async {
      final folder = join(root, 'NexusBridges');

      final result = usable(
        await inspectFolder(
          folder,
          fs: windowsFs,
          forbidden: noneForbidden,
          mayCreate: true,
        ),
      );

      expect(result.createdNow, isTrue);
      expect(samePath(result.target.path, folder), isTrue);
      expect(await Directory(folder).exists(), isTrue);
      expect(namesIn(root), ['NexusBridges']);
      expect(namesIn(folder), isEmpty);
    });

    test('a missing folder whose parent is also missing gives cannotUse and '
        'creates nothing', () async {
      final folder = join(join(root, 'Parent'), 'NexusBridges');
      final fs = FakePlatform();

      expect(
        await inspectFolder(
          folder,
          fs: fs,
          forbidden: noneForbidden,
          mayCreate: true,
        ),
        refused(FolderRefusal.cannotUse),
      );
      expect(namesIn(root), isEmpty);
      expect(fs.callsOf('setHidden'), isEmpty);
    });

    test('a missing folder with mayCreate false gives cannotUse and creates '
        'nothing', () async {
      final folder = join(root, 'NexusBridges');

      expect(
        await inspectFolder(
          folder,
          fs: windowsFs,
          forbidden: noneForbidden,
          mayCreate: false,
        ),
        refused(FolderRefusal.cannotUse),
      );
      expect(namesIn(root), isEmpty);
    });

    for (final name in ['CON', 'nul.txt', 'Recibidos.', 'Recibidos ', 'COM1']) {
      test('a missing last folder named "$name" is refused without creating '
          'anything', () async {
        final fs = FakePlatform();

        expect(
          await inspectFolder(
            join(root, name),
            fs: fs,
            forbidden: noneForbidden,
            mayCreate: true,
          ),
          refused(FolderRefusal.cannotUse),
        );
        expect(namesIn(root), isEmpty);
        expect(fs.callsOf('setHidden'), isEmpty);
      });
    }

    test('a new folder inside a parent reached through a junction is '
        'created in the real parent', () async {
      final realParent = await makeDir(join(root, 'RealParent'));
      final alias = await makeJunction(join(root, 'AliasParent'), realParent);

      final result = usable(
        await inspectFolder(
          join(alias, 'Nuevo'),
          fs: windowsFs,
          forbidden: noneForbidden,
          mayCreate: true,
        ),
      );

      expect(result.createdNow, isTrue);
      expect(samePath(result.target.path, join(realParent, 'Nuevo')), isTrue);
      expect(namesIn(realParent), ['Nuevo']);
    });

    test('a created folder whose real path is not the expected one is '
        'removed and refused', () async {
      final folder = join(root, 'Swapped');
      final fs = FakePlatform(
        adjustRealPath: (path, real) =>
            samePath(path, folder) ? join(root, 'Elsewhere') : real,
      );

      expect(
        await inspectFolder(
          folder,
          fs: fs,
          forbidden: noneForbidden,
          mayCreate: true,
        ),
        refused(FolderRefusal.cannotUse),
      );
      expect(namesIn(root), isEmpty);
      expect(fs.callsOf('setHidden'), isEmpty);
    });
  });

  group('inspectFolder with forbidden folders (E22, RF-242)', () {
    late String root;
    late String startup;
    late String dataDir;
    late String windowsDir;
    late ForbiddenFolders forbidden;

    setUp(() async {
      root = await tempFolder();
      startup = await makeDir(join(root, 'Startup'));
      dataDir = await makeDir(join(root, 'NexusBridgesData'));
      windowsDir = Platform.environment['WINDIR'] ?? r'C:\Windows';
      final folders = SystemFolders(
        downloads: await makeDir(join(root, 'Downloads')),
        startup: startup,
        startMenu: await makeDir(join(root, 'StartMenu')),
        windows: windowsDir,
        programFiles: await makeDir(join(root, 'ProgramFiles')),
        systemDriveRoot: '${windowsDir.substring(0, 2)}\\',
      );
      final loaded = await loadForbiddenFolders(
        windowsFs,
        folders,
        dataDirs: [dataDir],
      );
      expect(loaded, isNotNull);
      forbidden = loaded!;
    });

    test('the fake Startup folder is forbidden and nothing is created in '
        'it', () async {
      final fs = FakePlatform();

      expect(
        await inspectFolder(
          startup,
          fs: fs,
          forbidden: forbidden,
          mayCreate: true,
        ),
        refused(FolderRefusal.forbidden),
      );
      expect(namesIn(startup), isEmpty);
      expect(fs.callsOf('setHidden'), isEmpty);
      expect(fs.callsOf('volumeFacts'), isEmpty);
    });

    test('an existing subfolder of Startup is forbidden', () async {
      final sub = await makeDir(join(startup, 'Programs'));

      expect(
        await inspectFolder(
          sub,
          fs: windowsFs,
          forbidden: forbidden,
          mayCreate: true,
        ),
        refused(FolderRefusal.forbidden),
      );
      expect(namesIn(sub), isEmpty);
    });

    test('a missing subfolder of Startup is forbidden before it is '
        'created', () async {
      expect(
        await inspectFolder(
          join(startup, 'Nuevo'),
          fs: windowsFs,
          forbidden: forbidden,
          mayCreate: true,
        ),
        refused(FolderRefusal.forbidden),
      );
      expect(namesIn(startup), isEmpty);
    });

    test('a junction that leads to the data folder is forbidden', () async {
      final alias = await makeJunction(join(root, 'Innocent'), dataDir);

      expect(
        await inspectFolder(
          alias,
          fs: windowsFs,
          forbidden: forbidden,
          mayCreate: true,
        ),
        refused(FolderRefusal.forbidden),
      );
      expect(namesIn(dataDir), isEmpty);
    });

    test('a new folder under a junction that leads to Startup is forbidden '
        'and not created', () async {
      final alias = await makeJunction(join(root, 'Shortcut'), startup);

      expect(
        await inspectFolder(
          join(alias, 'Recibidos'),
          fs: windowsFs,
          forbidden: forbidden,
          mayCreate: true,
        ),
        refused(FolderRefusal.forbidden),
      );
      expect(namesIn(startup), isEmpty);
    });

    test('the real System32 is forbidden without trying to write', () async {
      final system32 = join(windowsDir, 'System32');
      final fs = FakePlatform();

      expect(
        await inspectFolder(
          system32,
          fs: fs,
          forbidden: forbidden,
          mayCreate: true,
        ),
        refused(FolderRefusal.forbidden),
      );
      expect(fs.calls.where((c) => !c.startsWith('realPath ')), isEmpty);
      expect(
        await FileSystemEntity.type(
          join(system32, tempFolderName),
          followLinks: false,
        ),
        FileSystemEntityType.notFound,
      );
    });

    test(
      'the system drive root is forbidden without trying to write',
      () async {
        final fs = FakePlatform();

        expect(
          await inspectFolder(
            '${windowsDir.substring(0, 2)}\\',
            fs: fs,
            forbidden: forbidden,
            mayCreate: true,
          ),
          refused(FolderRefusal.forbidden),
        );
        expect(fs.calls.where((c) => !c.startsWith('realPath ')), isEmpty);
      },
    );

    test('a normal temp folder next to them is still usable', () async {
      final folder = await makeDir(join(root, 'Recibidos'));

      usable(
        await inspectFolder(
          folder,
          fs: windowsFs,
          forbidden: forbidden,
          mayCreate: true,
        ),
      );
    });

    test('without forbidden folders (null) nothing is usable and nothing is '
        'touched (D34)', () async {
      final existing = await makeDir(join(root, 'Recibidos'));
      final missing = join(root, 'Nuevo');
      final fs = FakePlatform();

      for (final path in [existing, missing]) {
        expect(
          await inspectFolder(path, fs: fs, forbidden: null, mayCreate: true),
          refused(FolderRefusal.cannotUse),
        );
      }
      expect(fs.calls, isEmpty);
      expect(namesIn(existing), isEmpty);
      expect(await Directory(missing).exists(), isFalse);
    });
  });

  group('inspectFolder on a folder it cannot use (E23, RF-201)', () {
    late String root;

    setUp(() async {
      root = await tempFolder();
    });

    test('a file named like the temp subfolder makes it cannotUse and the '
        'file is not touched', () async {
      final folder = await makeDir(join(root, 'Recibidos'));
      final blocker = File(join(folder, tempFolderName));
      await blocker.writeAsString('datos del usuario');
      final fs = FakePlatform();

      expect(
        await inspectFolder(
          folder,
          fs: fs,
          forbidden: noneForbidden,
          mayCreate: false,
        ),
        refused(FolderRefusal.cannotUse),
      );
      expect(await blocker.readAsString(), 'datos del usuario');
      expect(namesIn(folder), [tempFolderName]);
      expect(fs.callsOf('setHidden'), isEmpty);
    });

    test('a temp subfolder that is a junction makes it cannotUse and nothing '
        'is written where it leads', () async {
      final folder = await makeDir(join(root, 'Recibidos'));
      final elsewhere = await makeDir(join(root, 'Elsewhere'));
      await makeJunction(join(folder, tempFolderName), elsewhere);
      final fs = FakePlatform();

      expect(
        await inspectFolder(
          folder,
          fs: fs,
          forbidden: noneForbidden,
          mayCreate: false,
        ),
        refused(FolderRefusal.cannotUse),
      );
      expect(namesIn(elsewhere), isEmpty);
      expect(fs.callsOf('setHidden'), isEmpty);
    });

    test('a temp subfolder whose real path is somewhere else makes it '
        'cannotUse and the created subfolder is removed', () async {
      final folder = await makeDir(join(root, 'Recibidos'));
      final sub = join(folder, tempFolderName);
      final fs = FakePlatform(
        adjustRealPath: (path, real) =>
            samePath(path, sub) ? join(root, 'Elsewhere') : real,
      );

      expect(
        await inspectFolder(
          folder,
          fs: fs,
          forbidden: noneForbidden,
          mayCreate: false,
        ),
        refused(FolderRefusal.cannotUse),
      );
      expect(namesIn(folder), isEmpty);
      expect(fs.callsOf('setHidden'), isEmpty);
    });

    test('a folder that is a file gives cannotUse and the file is '
        'intact', () async {
      final file = File(join(root, 'Recibidos'));
      await file.writeAsString('no soy carpeta');

      expect(
        await inspectFolder(
          file.path,
          fs: windowsFs,
          forbidden: noneForbidden,
          mayCreate: true,
        ),
        refused(FolderRefusal.cannotUse),
      );
      expect(await file.readAsString(), 'no soy carpeta');
      expect(namesIn(root), ['Recibidos']);
    });

    test('a parent whose real path cannot be read gives cannotUse and '
        'creates nothing', () async {
      final fs = FakePlatform(adjustRealPath: (path, real) => null);

      expect(
        await inspectFolder(
          join(root, 'Nuevo'),
          fs: fs,
          forbidden: noneForbidden,
          mayCreate: true,
        ),
        refused(FolderRefusal.cannotUse),
      );
      expect(namesIn(root), isEmpty);
    });
  });

  group('inspectFolder and the volume (E24, RF-246, v2 point 7)', () {
    late String root;
    late String realVolume;

    setUp(() async {
      root = await tempFolder();
      realVolume = (await windowsFs.volumeFacts(root))!.volumeId;
    });

    test('a remembered folder on another volume gives otherVolume, with '
        'the folder present', () async {
      final folder = await makeDir(join(root, 'Recibidos'));

      expect(
        await inspectFolder(
          folder,
          fs: windowsFs,
          forbidden: noneForbidden,
          mayCreate: false,
          expectedVolume: 'NTFS-00000000',
        ),
        refused(FolderRefusal.otherVolume),
      );
      expect(namesIn(folder), isEmpty);
    });

    test('a remembered folder on another volume gives otherVolume, with '
        'only the parent, and creates nothing', () async {
      final fs = FakePlatform();

      expect(
        await inspectFolder(
          join(root, 'Recibidos'),
          fs: fs,
          forbidden: noneForbidden,
          mayCreate: true,
          expectedVolume: 'exFAT-0f00ba11',
        ),
        refused(FolderRefusal.otherVolume),
      );
      expect(namesIn(root), isEmpty);
      expect(fs.callsOf('setHidden'), isEmpty);
    });

    test('a remembered folder on its own volume is usable', () async {
      final folder = await makeDir(join(root, 'Recibidos'));

      final result = usable(
        await inspectFolder(
          folder,
          fs: windowsFs,
          forbidden: noneForbidden,
          mayCreate: false,
          expectedVolume: realVolume,
        ),
      );

      expect(result.target.volumeId, realVolume);
    });

    test('a volume Windows does not identify gives unknownVolume without an '
        'expected volume and creates nothing', () async {
      final fs = FakePlatform(noVolume: true);

      expect(
        await inspectFolder(
          join(root, 'Nuevo'),
          fs: fs,
          forbidden: noneForbidden,
          mayCreate: true,
        ),
        refused(FolderRefusal.unknownVolume),
      );
      expect(namesIn(root), isEmpty);
    });

    test('a volume Windows does not identify gives otherVolume for a '
        'remembered folder and creates nothing', () async {
      final folder = await makeDir(join(root, 'Recibidos'));
      final fs = FakePlatform(noVolume: true);

      expect(
        await inspectFolder(
          folder,
          fs: fs,
          forbidden: noneForbidden,
          mayCreate: true,
          expectedVolume: realVolume,
        ),
        refused(FolderRefusal.otherVolume),
      );
      expect(namesIn(folder), isEmpty);
    });
  });

  group('inspectFolder reports the cautions (E25, RF-202, RF-243)', () {
    late String folder;

    setUp(() async {
      folder = await makeDir(join(await tempFolder(), 'Recibidos'));
    });

    test('a volume without named streams is usable with supportsMark '
        'false', () async {
      final fs = FakePlatform(
        volume: const VolumeFacts(
          volumeId: 'exFAT-0f00ba11',
          supportsNamedStreams: false,
          isRemote: false,
        ),
      );

      final result = usable(
        await inspectFolder(
          folder,
          fs: fs,
          forbidden: noneForbidden,
          mayCreate: false,
        ),
      );

      expect(result.target.supportsMark, isFalse);
      expect(result.target.volumeId, 'exFAT-0f00ba11');
      expect(result.target.remote, isFalse);
    });

    test('a remote volume is usable with remote true', () async {
      final fs = FakePlatform(
        volume: const VolumeFacts(
          volumeId: 'NTFS-1a2b3c4d',
          supportsNamedStreams: true,
          isRemote: true,
        ),
      );

      final result = usable(
        await inspectFolder(
          folder,
          fs: fs,
          forbidden: noneForbidden,
          mayCreate: false,
        ),
      );

      expect(result.target.remote, isTrue);
      expect(result.target.supportsMark, isTrue);
    });

    test('a cloud folder is usable with cloud true', () async {
      final fs = FakePlatform(cloud: true);

      final result = usable(
        await inspectFolder(
          folder,
          fs: fs,
          forbidden: noneForbidden,
          mayCreate: false,
        ),
      );

      expect(result.target.cloud, isTrue);
    });

    test('a volume without free space data is usable with freeBytes '
        'null', () async {
      final fs = FakePlatform(noFreeBytes: true);

      final result = usable(
        await inspectFolder(
          folder,
          fs: fs,
          forbidden: noneForbidden,
          mayCreate: false,
        ),
      );

      expect(result.target.freeBytes, isNull);
    });
  });

  group('inspectFolder with an abort signal [SEG] (v2 point 21)', () {
    late String root;

    setUp(() async {
      root = await tempFolder();
    });

    void expectNoTempFiles(String folder) {
      for (final path in treeOf(folder)) {
        expect(path.contains(tempPrefix.toUpperCase()), isFalse, reason: path);
      }
    }

    test('aborted before it starts it creates neither the folder nor the '
        'subfolder', () async {
      final abort = AbortSignal()..abort();
      final existing = await makeDir(join(root, 'Recibidos'));
      final missing = join(root, 'Nuevo');

      for (final path in [existing, missing]) {
        expect(
          await inspectFolder(
            path,
            fs: windowsFs,
            forbidden: noneForbidden,
            mayCreate: true,
            abort: abort,
          ),
          refused(FolderRefusal.cannotUse),
        );
      }
      expect(namesIn(root), ['Recibidos']);
      expect(namesIn(existing), isEmpty);
    });

    test('aborted while reading the volume it creates nothing', () async {
      final abort = AbortSignal();
      final fs = FakePlatform(
        onCall: (method, path) async {
          if (method == 'volumeFacts') abort.abort();
        },
      );

      expect(
        await inspectFolder(
          join(root, 'Nuevo'),
          fs: fs,
          forbidden: noneForbidden,
          mayCreate: true,
          abort: abort,
        ),
        refused(FolderRefusal.cannotUse),
      );
      expect(namesIn(root), isEmpty);
    });

    test('aborted right after creating the folder it only removes that empty '
        'folder', () async {
      final abort = AbortSignal();
      final folder = join(root, 'Nuevo');
      Set<String>? atAbort;
      final fs = FakePlatform(
        onCall: (method, path) async {
          if (method == 'realPath' &&
              samePath(path, folder) &&
              Directory(folder).existsSync()) {
            abort.abort();
            atAbort = treeOf(root);
          }
        },
      );

      expect(
        await inspectFolder(
          folder,
          fs: fs,
          forbidden: noneForbidden,
          mayCreate: true,
          abort: abort,
        ),
        refused(FolderRefusal.cannotUse),
      );
      expect(atAbort, isNotNull);
      expect(treeOf(root).difference(atAbort!), isEmpty);
      expect(namesIn(root), isEmpty);
      expect(fs.callsOf('setHidden'), isEmpty);
    });

    test('aborted after creating the folder, if someone put a file in it, '
        'the folder stays with only that file', () async {
      final abort = AbortSignal();
      final folder = join(root, 'Nuevo');
      Set<String>? atAbort;
      final fs = FakePlatform(
        onCall: (method, path) async {
          if (method == 'realPath' &&
              samePath(path, folder) &&
              Directory(folder).existsSync()) {
            File(join(folder, 'otro.txt')).writeAsStringSync('ajeno');
            abort.abort();
            atAbort = treeOf(root);
          }
        },
      );

      expect(
        await inspectFolder(
          folder,
          fs: fs,
          forbidden: noneForbidden,
          mayCreate: true,
          abort: abort,
        ),
        refused(FolderRefusal.cannotUse),
      );
      expect(treeOf(root).difference(atAbort!), isEmpty);
      expect(namesIn(folder), ['otro.txt']);
      expect(await File(join(folder, 'otro.txt')).readAsString(), 'ajeno');
    });

    test('aborted after creating the temp subfolder it writes no probe and '
        'removes what it created', () async {
      final abort = AbortSignal();
      final folder = join(root, 'Nuevo');
      final sub = join(folder, tempFolderName);
      Set<String>? atAbort;
      final fs = FakePlatform(
        onCall: (method, path) async {
          if (method == 'realPath' && samePath(path, sub)) {
            abort.abort();
            atAbort = treeOf(root);
          }
        },
      );

      expect(
        await inspectFolder(
          folder,
          fs: fs,
          forbidden: noneForbidden,
          mayCreate: true,
          abort: abort,
        ),
        refused(FolderRefusal.cannotUse),
      );
      expect(atAbort, isNotNull);
      expect(treeOf(root).difference(atAbort!), isEmpty);
      expect(namesIn(root), isEmpty);
    });

    test('aborted while hiding an existing temp subfolder it writes no '
        'probe and keeps the subfolder it did not create', () async {
      final abort = AbortSignal();
      final folder = await makeDir(join(root, 'Recibidos'));
      final sub = await makeDir(join(folder, tempFolderName));
      Set<String>? atAbort;
      final fs = FakePlatform(
        onCall: (method, path) async {
          if (method == 'setHidden') {
            abort.abort();
            atAbort = treeOf(root);
          }
        },
      );

      expect(
        await inspectFolder(
          folder,
          fs: fs,
          forbidden: noneForbidden,
          mayCreate: false,
          abort: abort,
        ),
        refused(FolderRefusal.cannotUse),
      );
      expect(treeOf(root).difference(atAbort!), isEmpty);
      expect(await Directory(sub).exists(), isTrue);
      expect(namesIn(sub), isEmpty);
      expectNoTempFiles(root);
    });

    test('a signal that is never fired does not change the result', () async {
      final folder = join(root, 'Nuevo');

      final result = usable(
        await inspectFolder(
          folder,
          fs: windowsFs,
          forbidden: noneForbidden,
          mayCreate: true,
          abort: AbortSignal(),
        ),
      );

      expect(result.createdNow, isTrue);
      expect(namesIn(folder), isEmpty);
    });
  });

  group('system folders retried after an incomplete read (E172, v2 point '
      '13)', () {
    test('the first incomplete read refuses, the retry works and the test '
        'data folder is forbidden', () async {
      final root = await tempFolder();
      final dataDir = await makeDir(join(root, 'NexusBridgesData'));
      final folder = await makeDir(join(root, 'Recibidos'));
      final complete = SystemFolders(
        downloads: await makeDir(join(root, 'Downloads')),
        startup: await makeDir(join(root, 'Startup')),
        startMenu: await makeDir(join(root, 'StartMenu')),
        windows: await makeDir(join(root, 'Windows')),
        programFiles: await makeDir(join(root, 'ProgramFiles')),
        systemDriveRoot: join(root, 'Drive'),
      );
      final incomplete = SystemFolders(
        downloads: complete.downloads,
        startMenu: complete.startMenu,
        windows: complete.windows,
        programFiles: complete.programFiles,
        systemDriveRoot: complete.systemDriveRoot,
      );
      final fs = FakePlatform(folderSequence: [incomplete, complete]);

      Future<ForbiddenFolders?> load() async => loadForbiddenFolders(
        fs,
        await fs.systemFolders(),
        dataDirs: [dataDir],
      );

      final first = await load();
      expect(first, isNull);
      fs.calls.clear();
      expect(
        await inspectFolder(folder, fs: fs, forbidden: first, mayCreate: true),
        refused(FolderRefusal.cannotUse),
      );
      expect(fs.calls, isEmpty);

      final retried = await load();
      expect(retried, isNotNull);
      usable(
        await inspectFolder(
          folder,
          fs: fs,
          forbidden: retried,
          mayCreate: true,
        ),
      );
      expect(
        await inspectFolder(
          dataDir,
          fs: fs,
          forbidden: retried,
          mayCreate: true,
        ),
        refused(FolderRefusal.forbidden),
      );
      expect(
        await inspectFolder(
          join(dataDir, 'identity'),
          fs: fs,
          forbidden: retried,
          mayCreate: true,
        ),
        refused(FolderRefusal.forbidden),
      );
      expect(namesIn(dataDir), isEmpty);
    });
  });

  group('E184, RF-242: isAdminShare', () {
    for (final path in [
      r'\\localhost\C$',
      r'\\localhost\C$\Users\x',
      r'\\127.0.0.1\c$\Windows',
      r'\\equipo\ADMIN$',
      r'\\srv\IPC$\x',
      r'\\srv\oculto$\x',
      r'//localhost/C$/x',
      r'\\.\UNC\localhost\C$\x',
    ]) {
      test('"$path" is an administrative share', () {
        expect(isAdminShare(path), isTrue);
      });
    }

    for (final path in [
      r'\\srv\datos\x',
      r'\\srv\datos\C$',
      r'C:\x$',
      r'C:\Users\a$b',
      r'\\srv\da$tos\x',
      r'\\srv',
    ]) {
      test('"$path" is not an administrative share', () {
        expect(isAdminShare(path), isFalse);
      });
    }

    test('the device prefix is read without case and with a final '
        'backslash', () {
      expect(isAdminShare(r'\\.\unc\localhost\c$'), isTrue);
      expect(isAdminShare(r'\\localhost\C$\'), isTrue);
      expect(isAdminShare(r'\\.\UNC\srv\datos\x'), isFalse);
    });
  });

  group('E185, RF-242: an administrative share is refused before touching '
      'the disk [SEG]', () {
    late String root;

    setUp(() async {
      root = await tempFolder();
    });

    for (final path in [
      r'\\localhost\C$\nb-e185',
      r'//localhost/C$/nb-e185',
      r'\\.\UNC\localhost\C$\nb-e185',
      r'\\127.0.0.1\c$\Windows',
    ]) {
      test('"$path" gives adminShare with no call to the platform', () async {
        final fs = FakePlatform();

        expect(
          await inspectFolder(
            path,
            fs: fs,
            forbidden: noneForbidden,
            mayCreate: true,
          ),
          refused(FolderRefusal.adminShare),
        );
        expect(fs.calls, isEmpty);
      });
    }

    test('the folder written as UNC is not created on C:', () async {
      await inspectFolder(
        r'\\localhost\C$\nb-e185',
        fs: FakePlatform(),
        forbidden: noneForbidden,
        mayCreate: true,
      );

      expect(await Directory(r'C:\nb-e185').exists(), isFalse);
    });

    test('an existing folder whose real path is in C\$ through a mapped '
        'drive gives adminShare and gets no new entries', () async {
      final folder = await makeDir(join(root, 'T'));
      final fs = FakePlatform(
        adjustRealPath: (path, real) =>
            samePath(path, folder) ? r'\\localhost\C$\Users\x\T' : real,
      );

      expect(
        await inspectFolder(
          folder,
          fs: fs,
          forbidden: noneForbidden,
          mayCreate: true,
        ),
        refused(FolderRefusal.adminShare),
      );
      expect(namesIn(folder), isEmpty);
      expect(fs.callsOf('setHidden'), isEmpty);
      expect(fs.callsOf('volumeFacts'), isEmpty);
    });

    test('a new folder under a parent whose real path is in C\$ gives '
        'adminShare and is not created', () async {
      final parent = await makeDir(join(root, 'T'));
      final fs = FakePlatform(
        adjustRealPath: (path, real) =>
            samePath(path, parent) ? r'\\localhost\C$\Users\x\T' : real,
      );

      expect(
        await inspectFolder(
          join(parent, 'nueva'),
          fs: fs,
          forbidden: noneForbidden,
          mayCreate: true,
        ),
        refused(FolderRefusal.adminShare),
      );
      expect(await Directory(join(parent, 'nueva')).exists(), isFalse);
      expect(namesIn(parent), isEmpty);
    });

    test(
      'a real path in the device form \\\\.\\UNC\\ is also refused',
      () async {
        final folder = await makeDir(join(root, 'T'));
        final fs = FakePlatform(
          adjustRealPath: (path, real) =>
              samePath(path, folder) ? r'\\.\UNC\localhost\C$\T' : real,
        );

        expect(
          await inspectFolder(
            folder,
            fs: fs,
            forbidden: noneForbidden,
            mayCreate: false,
          ),
          refused(FolderRefusal.adminShare),
        );
        expect(namesIn(folder), isEmpty);
      },
    );

    test(
      'a real path in a normal share is not refused as adminShare',
      () async {
        final folder = await makeDir(join(root, 'T'));
        final fs = FakePlatform(
          adjustRealPath: (path, real) =>
              samePath(path, folder) ? r'\\srv\datos\T' : real,
        );

        final result = await inspectFolder(
          folder,
          fs: fs,
          forbidden: noneForbidden,
          mayCreate: false,
        );

        expect(result, isNot(refused(FolderRefusal.adminShare)));
      },
    );
  });

  group('E186, RF-242: a mapped drive that leads to C\$ (real, by hand)', () {
    test('a folder seen through the drive gives adminShare and nothing is '
        'created', () async {
      final drive = await adminShareDrive();
      if (drive == null) {
        markTestSkipped(
          r'no drive letter leads to \\localhost\C$ or \\127.0.0.1\C$; map '
          'one with net use to run E186',
        );
        return;
      }
      final (:letter, :cBase) = drive;
      final root = await tempFolder();
      if (!isSameOrInside(root, cBase.isEmpty ? r'C:\' : cBase)) {
        markTestSkipped('the temp folder is not under the mapped share');
        return;
      }
      final offset = cBase.isEmpty ? 2 : cBase.length;
      final viewed = '$letter:${root.substring(offset)}';
      final before = treeOf(root);

      final real = await windowsFs.realPath(viewed);

      expect(real, isNotNull);
      expect(isAdminShare(real!), isTrue, reason: real);
      expect(
        await inspectFolder(
          viewed,
          fs: windowsFs,
          forbidden: noneForbidden,
          mayCreate: false,
        ),
        refused(FolderRefusal.adminShare),
      );
      expect(
        await inspectFolder(
          join(viewed, 'nueva'),
          fs: windowsFs,
          forbidden: noneForbidden,
          mayCreate: true,
        ),
        refused(FolderRefusal.adminShare),
      );
      expect(treeOf(root), before);
    });
  });

  group('E195, RF-201: long receive folders', () {
    late String root;

    setUp(() async {
      root = await tempFolder();
    });

    test('an existing folder of exactly 236 characters is usable', () async {
      final folder = pathOfLength(root, 236);
      await Directory(folder).create(recursive: true);

      final result = usable(
        await inspectFolder(
          folder,
          fs: windowsFs,
          forbidden: noneForbidden,
          mayCreate: false,
        ),
      );

      expect(result.target.path.length, 236);
      expect(namesIn(folder), isEmpty);
    });

    test('an existing folder of 237 characters gives cannotUse and nothing '
        'is created', () async {
      final folder = pathOfLength(root, 237);
      await Directory(folder).create(recursive: true);
      final fs = FakePlatform();

      expect(
        await inspectFolder(
          folder,
          fs: fs,
          forbidden: noneForbidden,
          mayCreate: true,
        ),
        refused(FolderRefusal.cannotUse),
      );
      expect(namesIn(folder), isEmpty);
      expect(fs.callsOf('setHidden'), isEmpty);
      expect(fs.callsOf('volumeFacts'), isEmpty);
    });

    test('a new folder of 237 characters under an existing parent gives '
        'cannotUse and is not created', () async {
      final folder = pathOfLength(root, 237);
      final parent = folder.substring(0, folder.lastIndexOf(r'\'));
      await Directory(parent).create(recursive: true);

      expect(
        await inspectFolder(
          folder,
          fs: windowsFs,
          forbidden: noneForbidden,
          mayCreate: true,
        ),
        refused(FolderRefusal.cannotUse),
      );
      expect(await Directory(folder).exists(), isFalse);
      expect(namesIn(parent), isEmpty);
    });

    test('a new folder of 236 characters under an existing parent is created '
        'and usable', () async {
      final folder = pathOfLength(root, 236);
      final parent = folder.substring(0, folder.lastIndexOf(r'\'));
      await Directory(parent).create(recursive: true);

      final result = usable(
        await inspectFolder(
          folder,
          fs: windowsFs,
          forbidden: noneForbidden,
          mayCreate: true,
        ),
      );

      expect(result.createdNow, isTrue);
      expect(result.target.path.length, 236);
      expect(namesIn(folder), isEmpty);
    });

    test('a short path whose real path is 237 characters gives '
        'cannotUse', () async {
      final folder = pathOfLength(root, 237);
      await Directory(folder).create(recursive: true);
      final alias = await makeJunction(join(root, 'j'), folder);

      expect(
        await inspectFolder(
          alias,
          fs: windowsFs,
          forbidden: noneForbidden,
          mayCreate: false,
        ),
        refused(FolderRefusal.cannotUse),
      );
      expect(namesIn(folder), isEmpty);
    });
  });

  group('E197, RF-235, RF-176: the temp subfolder is not a receive '
      'folder', () {
    late String root;

    setUp(() async {
      root = await tempFolder();
    });

    test('isInsideTempFolder', () {
      expect(isInsideTempFolder(r'C:\a\.nexusbridges-incoming'), isTrue);
      expect(isInsideTempFolder(r'C:\a\.NexusBridges-Incoming\b'), isTrue);
      expect(isInsideTempFolder(r'C:\a\x.nexusbridges-incoming'), isFalse);
      expect(isInsideTempFolder(r'C:\a\.nexusbridges-incoming-old'), isFalse);
    });

    test('isInsideTempFolder reads / and a final backslash', () {
      expect(isInsideTempFolder('C:/a/.nexusbridges-incoming/'), isTrue);
      expect(isInsideTempFolder(r'\\srv\datos\.nexusbridges-incoming'), isTrue);
      expect(isInsideTempFolder(r'C:\a\b'), isFalse);
    });

    test('a new temp subfolder as receive folder gives cannotUse and is not '
        'created', () async {
      final fs = FakePlatform();
      final folder = join(root, tempFolderName);

      expect(
        await inspectFolder(
          folder,
          fs: fs,
          forbidden: noneForbidden,
          mayCreate: true,
        ),
        refused(FolderRefusal.cannotUse),
      );
      expect(fs.calls, isEmpty);
      expect(namesIn(root), isEmpty);
    });

    test('an existing temp subfolder as receive folder gives cannotUse and '
        'nothing is created in it', () async {
      final folder = await makeDir(join(root, tempFolderName));
      final temp = File(join(folder, ownTemp(hexA)));
      await temp.writeAsString('partial');
      final before = treeOf(root);
      final fs = FakePlatform();

      expect(
        await inspectFolder(
          folder,
          fs: fs,
          forbidden: noneForbidden,
          mayCreate: true,
        ),
        refused(FolderRefusal.cannotUse),
      );
      expect(fs.calls, isEmpty);
      expect(treeOf(root), before);
      expect(await temp.readAsString(), 'partial');
    });

    test('a folder inside the temp subfolder written in another case gives '
        'cannotUse', () async {
      final fs = FakePlatform();

      expect(
        await inspectFolder(
          join(join(root, '.NEXUSBRIDGES-INCOMING'), 'b'),
          fs: fs,
          forbidden: noneForbidden,
          mayCreate: true,
        ),
        refused(FolderRefusal.cannotUse),
      );
      expect(fs.calls, isEmpty);
      expect(namesIn(root), isEmpty);
    });

    test('a junction that leads to the temp subfolder gives cannotUse and '
        'nothing is created', () async {
      final folder = await makeDir(join(root, tempFolderName));
      final alias = await makeJunction(join(root, 'j'), folder);
      final before = treeOf(root);

      expect(
        await inspectFolder(
          alias,
          fs: windowsFs,
          forbidden: noneForbidden,
          mayCreate: true,
        ),
        refused(FolderRefusal.cannotUse),
      );
      expect(treeOf(root), before);
      expect(namesIn(folder), isEmpty);
    });

    test('a new folder under a junction to the temp subfolder gives cannotUse '
        'and is not created', () async {
      final folder = await makeDir(join(root, tempFolderName));
      final alias = await makeJunction(join(root, 'j'), folder);

      expect(
        await inspectFolder(
          join(alias, 'nueva'),
          fs: windowsFs,
          forbidden: noneForbidden,
          mayCreate: true,
        ),
        refused(FolderRefusal.cannotUse),
      );
      expect(namesIn(folder), isEmpty);
    });
  });
}

String pathOfLength(String base, int length) {
  var path = base;
  while (path.length < length) {
    final room = length - path.length - 1;
    if (room < 1) throw StateError('no room for length $length');
    var take = room < 100 ? room : 100;
    if (room - take == 1) take--;
    path = '$path\\${'d' * take}';
  }
  expect(path.length, length);
  return path;
}

Future<({String letter, String cBase})?> adminShareDrive() async {
  for (var code = 0x41; code <= 0x5A; code++) {
    final letter = String.fromCharCode(code);
    final kind = using((arena) => GetDriveType(arena.pcwstr('$letter:\\')));
    if (kind != DRIVE_REMOTE) continue;
    final real = await windowsFs.realPath('$letter:\\');
    if (real == null) continue;
    var unc = real;
    if (unc.toUpperCase().startsWith(r'\\?\UNC\')) {
      unc = '\\\\${unc.substring(8)}';
    }
    final upper = unc.toUpperCase();
    for (final prefix in [r'\\LOCALHOST\C$', r'\\127.0.0.1\C$']) {
      if (upper == prefix || upper.startsWith('$prefix\\')) {
        var rest = unc.substring(prefix.length);
        while (rest.endsWith(r'\')) {
          rest = rest.substring(0, rest.length - 1);
        }
        return (letter: letter, cBase: rest.isEmpty ? '' : 'C:$rest');
      }
    }
  }
  return null;
}
