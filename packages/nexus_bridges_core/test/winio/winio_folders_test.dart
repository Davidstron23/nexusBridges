@TestOn('windows')
library;

import 'dart:convert';
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:nexus_bridges_core/src/protocol/protocol.dart' show folderKey;
import 'package:nexus_bridges_core/src/transfer/transfer.dart'
    show tempFolderName;
import 'package:nexus_bridges_core/src/winio/winio.dart';
import 'package:test/test.dart';
import 'package:win32/win32.dart';

import 'short_names.dart';

final List<int> openHandles = [];

int track(FolderOpen opened) {
  expect(opened, isA<FolderOpened>());
  final handle = (opened as FolderOpened).handle;
  openHandles.add(handle);
  return handle;
}

void closeTracked(int handle) {
  if (openHandles.remove(handle)) closeHandleSync(handle);
}

void closeAllTracked() {
  for (final handle in openHandles.reversed.toList()) {
    closeHandleSync(handle);
  }
  openHandles.clear();
}

Future<String> tempRoot() async {
  final dir = await Directory.systemTemp.createTemp('nexus_t007_winio_');
  addTearDown(() async {
    closeAllTracked();
    for (var attempt = 0; attempt < 40; attempt++) {
      try {
        final made = Process.runSync('cmd', [
          '/c',
          'rmdir',
          '/s',
          '/q',
          r'\\?\' + dir.path,
        ], workingDirectory: Directory.systemTemp.path);
        if (made.exitCode == 0 && !dir.existsSync()) return;
      } on ProcessException {
        return;
      }
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
  });
  return dir.resolveSymbolicLinksSync();
}

void junction(String link, String target) {
  final made = Process.runSync('cmd', [
    '/c',
    'mklink',
    '/J',
    link,
    target,
  ], workingDirectory: Directory.systemTemp.path);
  expect(made.exitCode, 0, reason: '${made.stdout}${made.stderr}');
}

bool isHiddenPath(String path) => using((arena) {
  final Win32Result(value: attributes) = GetFileAttributes(
    arena.pcwstr(extendedPath(path)),
  );
  return attributes != 0xFFFFFFFF && (attributes & 0x02) != 0;
});

bool renamesFromOutside(String from, String to) {
  try {
    Directory(from).renameSync(to);
    Directory(to).renameSync(from);
    return true;
  } on FileSystemException {
    return false;
  }
}

({int r, int a, int b}) lockChain(String r) {
  final root = track(openFolderByPathSync(r, lock: true));
  final a = track(openFolderRelativeSync(root, 'a', lock: true));
  final b = track(openFolderRelativeSync(a, 'b', lock: true));
  return (r: root, a: a, b: b);
}

Future<({String base, String outer, String r, String a, String b})>
layout() async {
  final base = await tempRoot();
  final outer = '$base\\outer';
  final r = '$outer\\r';
  final a = '$r\\a';
  final b = '$a\\b';
  Directory(b).createSync(recursive: true);
  return (base: base, outer: outer, r: r, a: a, b: b);
}

void main() {
  tearDown(closeAllTracked);

  group('E745 winio primitives on NTFS (R131, R132)', () {
    test('E745 a locked chain r\\a\\b stops renaming a, b and the folder '
        'that holds r; it renames again once released', () async {
      final place = await layout();
      expect(renamesFromOutside(place.a, '${place.r}\\a2'), isTrue);
      final chain = lockChain(place.r);
      expect(renamesFromOutside(place.a, '${place.r}\\a2'), isFalse);
      expect(renamesFromOutside(place.b, '${place.a}\\b2'), isFalse);
      expect(renamesFromOutside(place.r, '${place.outer}\\r2'), isFalse);
      expect(renamesFromOutside(place.outer, '${place.base}\\outer2'), isFalse);
      expect(() => Directory(place.b).deleteSync(), throwsA(anything));
      expect(Directory(place.b).existsSync(), isTrue);
      closeTracked(chain.b);
      closeTracked(chain.a);
      closeTracked(chain.r);
      expect(renamesFromOutside(place.a, '${place.r}\\a2'), isTrue);
      expect(renamesFromOutside(place.outer, '${place.base}\\outer2'), isTrue);
    });

    test('E745 the lock asks for no DELETE and no write: files can still be '
        'created inside b by path', () async {
      final place = await layout();
      lockChain(place.r);
      File('${place.b}\\nuevo.txt').writeAsStringSync('dentro');
      expect(File('${place.b}\\nuevo.txt').readAsStringSync(), 'dentro');
    });

    test('E745 a file and a folder move from .nexusbridges-incoming to b '
        'by handle', () async {
      final place = await layout();
      final chain = lockChain(place.r);
      final incomingOpen = openFolderRelativeSync(
        chain.b,
        tempFolderName,
        lock: true,
        create: true,
        hideIfCreated: true,
      );
      expect((incomingOpen as FolderOpened).created, isTrue);
      final incoming = track(incomingOpen);
      final incomingPath = '${place.b}\\$tempFolderName';
      expect(isHiddenPath(incomingPath), isTrue);
      File('$incomingPath\\t1.tmp').writeAsStringSync('uno');
      Directory('$incomingPath\\t2\\dentro').createSync(recursive: true);
      File('$incomingPath\\t2\\dentro\\f.txt').writeAsStringSync('dos');

      final fileSource = openForRenameRelativeSync(
        incoming,
        't1.tmp',
        directory: false,
      );
      expect(fileSource, isA<RenameSourceOpened>());
      final fileHandle = (fileSource as RenameSourceOpened).handle;
      try {
        expect(
          renameRelativeSync(fileHandle, chain.b, 'final.txt'),
          RenameStatus.renamed,
        );
      } finally {
        closeHandleSync(fileHandle);
      }
      final folderSource = openForRenameRelativeSync(
        incoming,
        't2',
        directory: true,
      );
      expect(folderSource, isA<RenameSourceOpened>());
      final folderHandle = (folderSource as RenameSourceOpened).handle;
      try {
        expect(
          renameRelativeSync(folderHandle, chain.b, 'Proyecto'),
          RenameStatus.renamed,
        );
      } finally {
        closeHandleSync(folderHandle);
      }
      expect(File('${place.b}\\final.txt').readAsStringSync(), 'uno');
      expect(
        File('${place.b}\\Proyecto\\dentro\\f.txt').readAsStringSync(),
        'dos',
      );
      expect(Directory(incomingPath).listSync(), isEmpty);
    });

    test('E745 a move lands in a new folder b\\nueva created and locked in '
        'the same session (punto 3)', () async {
      final place = await layout();
      final chain = lockChain(place.r);
      final created = openFolderRelativeSync(
        chain.b,
        'nueva',
        lock: true,
        create: true,
      );
      expect((created as FolderOpened).created, isTrue);
      final nueva = track(created);
      final incoming = track(
        openFolderRelativeSync(
          nueva,
          tempFolderName,
          lock: true,
          create: true,
          hideIfCreated: true,
        ),
      );
      final incomingPath = '${place.b}\\nueva\\$tempFolderName';
      File('$incomingPath\\t.tmp').writeAsStringSync('nuevo');
      final source = openForRenameRelativeSync(
        incoming,
        't.tmp',
        directory: false,
      );
      final handle = (source as RenameSourceOpened).handle;
      try {
        expect(
          renameRelativeSync(handle, nueva, 'llega.txt'),
          RenameStatus.renamed,
        );
      } finally {
        closeHandleSync(handle);
      }
      expect(File('${place.b}\\nueva\\llega.txt').readAsStringSync(), 'nuevo');
      expect(
        renamesFromOutside('${place.b}\\nueva', '${place.b}\\n2'),
        isFalse,
      );
      final reopened = openFolderRelativeSync(
        chain.b,
        'nueva',
        lock: true,
        create: true,
      );
      expect((reopened as FolderOpened).created, isFalse);
      track(reopened);
    });

    test('E745 a move onto an existing name answers nameTaken and leaves '
        'both in place', () async {
      final place = await layout();
      final chain = lockChain(place.r);
      File('${place.b}\\ocupado.txt').writeAsStringSync('antes');
      final incoming = track(
        openFolderRelativeSync(
          chain.b,
          tempFolderName,
          lock: true,
          create: true,
          hideIfCreated: true,
        ),
      );
      File('${place.b}\\$tempFolderName\\t.tmp').writeAsStringSync('nuevo');
      final source = openForRenameRelativeSync(
        incoming,
        't.tmp',
        directory: false,
      );
      final handle = (source as RenameSourceOpened).handle;
      try {
        expect(
          renameRelativeSync(handle, chain.b, 'ocupado.txt'),
          RenameStatus.nameTaken,
        );
        expect(
          renameRelativeSync(handle, chain.b, 'OCUPADO.TXT'),
          RenameStatus.nameTaken,
        );
        expect(
          renameRelativeSync(handle, chain.b, r'..\fuera.txt'),
          RenameStatus.failed,
        );
      } finally {
        closeHandleSync(handle);
      }
      expect(File('${place.b}\\ocupado.txt').readAsStringSync(), 'antes');
      expect(
        File('${place.b}\\$tempFolderName\\t.tmp').readAsStringSync(),
        'nuevo',
      );
      expect(File('${place.a}\\fuera.txt').existsSync(), isFalse);
    });

    test(
      'E745 a source held open by another program gives RenameSourceBusy',
      () async {
        final place = await layout();
        final chain = lockChain(place.r);
        final incoming = track(
          openFolderRelativeSync(
            chain.b,
            tempFolderName,
            lock: true,
            create: true,
            hideIfCreated: true,
          ),
        );
        final path = '${place.b}\\$tempFolderName\\t.tmp';
        File(path).writeAsStringSync('x');
        final holder = File(path).openSync(mode: FileMode.append);
        try {
          expect(
            openForRenameRelativeSync(incoming, 't.tmp', directory: false),
            isA<RenameSourceBusy>(),
          );
        } finally {
          holder.closeSync();
        }
        final source = openForRenameRelativeSync(
          incoming,
          't.tmp',
          directory: false,
        );
        expect(source, isA<RenameSourceOpened>());
        closeHandleSync((source as RenameSourceOpened).handle);
      },
    );

    test(
      'E745 two locked chains over the same folders live together',
      () async {
        final place = await layout();
        final first = lockChain(place.r);
        final second = lockChain(place.r);
        expect(first.b, isNot(second.b));
        expect(
          folderFactsSync(second.b)!.finalPath.toUpperCase(),
          place.b.toUpperCase(),
        );
        expect(renamesFromOutside(place.a, '${place.r}\\a2'), isFalse);
      },
    );

    test('E745 a console with its working directory in b does not stop '
        'locking or moving', () async {
      final place = await layout();
      final console = await Process.start('cmd', const [
        '/q',
      ], workingDirectory: place.b);
      addTearDown(() async {
        console.kill();
        await console.exitCode.timeout(
          const Duration(seconds: 10),
          onTimeout: () => -1,
        );
      });
      final drained = console.stdout.transform(utf8.decoder).drain<void>();
      unawaitedDrain(drained);
      unawaitedDrain(console.stderr.drain<void>());
      final chain = lockChain(place.r);
      final incoming = track(
        openFolderRelativeSync(
          chain.b,
          tempFolderName,
          lock: true,
          create: true,
          hideIfCreated: true,
        ),
      );
      File('${place.b}\\$tempFolderName\\t.tmp').writeAsStringSync('ok');
      final source = openForRenameRelativeSync(
        incoming,
        't.tmp',
        directory: false,
      );
      final handle = (source as RenameSourceOpened).handle;
      try {
        expect(
          renameRelativeSync(handle, chain.b, 'ok.txt'),
          RenameStatus.renamed,
        );
      } finally {
        closeHandleSync(handle);
      }
      expect(File('${place.b}\\ok.txt').existsSync(), isTrue);
      console.stdin.writeln('exit');
      await console.stdin.close();
      expect(
        await console.exitCode.timeout(
          const Duration(seconds: 10),
          onTimeout: () => -1,
        ),
        isNot(-1),
      );
    });

    test('E745 deleteEmptyFolderRelativeSync: deleted, notEmpty, busy and '
        'mismatch', () async {
      final place = await layout();
      final parent = track(openFolderByPathSync(place.b, lock: false));
      Directory('${place.b}\\vacia').createSync();
      Directory('${place.b}\\llena').createSync();
      File('${place.b}\\llena\\f.txt').writeAsStringSync('x');
      Directory('${place.b}\\abierta').createSync();
      Directory('${place.b}\\otra').createSync();

      expect(
        deleteEmptyFolderRelativeSync(
          parent,
          'vacia',
          expectedFinalPath: '${place.b}\\vacia',
        ),
        DeleteStatus.deleted,
      );
      expect(Directory('${place.b}\\vacia').existsSync(), isFalse);
      expect(
        deleteEmptyFolderRelativeSync(
          parent,
          'llena',
          expectedFinalPath: '${place.b}\\llena',
        ),
        DeleteStatus.notEmpty,
      );
      expect(File('${place.b}\\llena\\f.txt').existsSync(), isTrue);
      final held = track(openFolderRelativeSync(parent, 'abierta', lock: true));
      expect(
        deleteEmptyFolderRelativeSync(
          parent,
          'abierta',
          expectedFinalPath: '${place.b}\\abierta',
        ),
        DeleteStatus.busy,
      );
      closeTracked(held);
      expect(Directory('${place.b}\\abierta').existsSync(), isTrue);
      expect(
        deleteEmptyFolderRelativeSync(
          parent,
          'otra',
          expectedFinalPath: '${place.b}\\distinta',
        ),
        DeleteStatus.mismatch,
      );
      expect(Directory('${place.b}\\otra').existsSync(), isTrue);
      expect(
        deleteEmptyFolderRelativeSync(
          parent,
          'falta',
          expectedFinalPath: '${place.b}\\falta',
        ),
        DeleteStatus.failed,
      );
    });

    test(
      'E745 a junction opened by handle is a link and is never entered',
      () async {
        final place = await layout();
        final outside = '${place.base}\\fuera';
        Directory('$outside\\centinela').createSync(recursive: true);
        junction('${place.b}\\union', outside);
        final b = track(openFolderByPathSync(place.b, lock: false));
        final link = track(openFolderRelativeSync(b, 'union', lock: false));
        final facts = folderFactsSync(link)!;
        expect(facts.isLink, isTrue);
        expect(facts.realName, 'union');
        expect(
          facts.finalPath.toUpperCase(),
          '${place.b}\\union'.toUpperCase(),
        );
        expect(
          openFolderRelativeSync(link, 'centinela', lock: false),
          isA<FolderOpenFailed>(),
        );
        expect(
          deleteEmptyFolderRelativeSync(
            b,
            'union',
            expectedFinalPath: '${place.b}\\union',
          ),
          DeleteStatus.mismatch,
        );
        expect(Directory('$outside\\centinela').existsSync(), isTrue);
        final byPath = track(
          openFolderByPathSync('${place.b}\\union', lock: false),
        );
        expect(folderFactsSync(byPath)!.isLink, isTrue);
      },
    );

    test('E745 opening the 8.3 short name of x. gives realName x. '
        '(punto 1)', () async {
      final place = await layout();
      expect(makeRawFolder('${place.b}\\x.'), isTrue);
      Directory('${place.b}\\MiProyectoLargo').createSync();
      final short = shortNameOf('${place.b}\\x.');
      if (short.isEmpty) {
        markTestSkipped('the test volume does not make 8.3 names');
        return;
      }
      final b = track(openFolderByPathSync(place.b, lock: false));
      final opened = track(openFolderRelativeSync(b, short, lock: false));
      expect(folderFactsSync(opened)!.realName, 'x.');
      final longShort = shortNameOf('${place.b}\\MiProyectoLargo');
      expect(longShort, isNot('MiProyectoLargo'));
      final other = track(openFolderRelativeSync(b, longShort, lock: false));
      expect(folderFactsSync(other)!.realName, 'MiProyectoLargo');
      expect(
        folderKey(folderFactsSync(other)!.realName),
        isNot(folderKey(longShort)),
      );
      Directory('${place.b}\\$tempFolderName').createSync();
      final incomingShort = shortNameOf('${place.b}\\$tempFolderName');
      expect(incomingShort, isNotEmpty);
      final incoming = track(
        openFolderRelativeSync(b, incomingShort, lock: false),
      );
      expect(folderFactsSync(incoming)!.realName, tempFolderName);
    });

    test('E745 openFolderRelativeSync refuses anything that is not one '
        'name and tells missing from file', () async {
      final place = await layout();
      File('${place.b}\\f').writeAsStringSync('x');
      final a = track(openFolderByPathSync(place.a, lock: false));
      for (final name in ['', r'b\..\..', 'b/x', 'C:', 'b:stream', 'b\u{0}']) {
        expect(
          openFolderRelativeSync(a, name, lock: false),
          isA<FolderOpenFailed>().having(
            (f) => f.reason,
            'reason',
            FolderOpenFailure.other,
          ),
          reason: name.codeUnits.toString(),
        );
      }
      final up = openFolderRelativeSync(a, '..', lock: false);
      if (up is FolderOpened) {
        track(up);
        fail('.. opened ${folderFactsSync(up.handle)?.finalPath}');
      }
      final b = track(openFolderRelativeSync(a, 'b', lock: false));
      expect(
        openFolderRelativeSync(b, 'f', lock: false),
        isA<FolderOpenFailed>().having(
          (f) => f.reason,
          'reason',
          FolderOpenFailure.notAFolder,
        ),
      );
      expect(
        openFolderRelativeSync(b, 'falta', lock: false),
        isA<FolderOpenFailed>().having(
          (f) => f.reason,
          'reason',
          FolderOpenFailure.notFound,
        ),
      );
      expect(
        openFolderByPathSync('${place.b}\\f', lock: false),
        isA<FolderOpenFailed>().having(
          (f) => f.reason,
          'reason',
          FolderOpenFailure.notAFolder,
        ),
      );
      expect(
        openFolderByPathSync('${place.b}\\falta', lock: false),
        isA<FolderOpenFailed>().having(
          (f) => f.reason,
          'reason',
          FolderOpenFailure.notFound,
        ),
      );
    });

    test(
      'E745 folder facts: hidden, system, volume and child name keys',
      () async {
        final place = await layout();
        Directory('${place.b}\\Oculta').createSync();
        Directory('${place.b}\\Sistema').createSync();
        Process.runSync('attrib', ['+h', '${place.b}\\Oculta']);
        Process.runSync('attrib', ['+s', '${place.b}\\Sistema']);
        File('${place.b}\\nota.txt').writeAsStringSync('x');
        final b = track(openFolderByPathSync(place.b, lock: false));
        final hidden = track(openFolderRelativeSync(b, 'oculta', lock: false));
        final system = track(openFolderRelativeSync(b, 'Sistema', lock: false));
        expect(folderFactsSync(hidden)!.hidden, isTrue);
        expect(folderFactsSync(hidden)!.realName, 'Oculta');
        expect(folderFactsSync(system)!.system, isTrue);
        final facts = folderFactsSync(b)!;
        expect(
          facts.volumeId,
          matches(RegExp(r'^[A-Za-z0-9]{1,16}-[0-9a-f]{8}$')),
        );
        expect(facts.isLink, isFalse);
        expect(childNameKeysSync(b, key: folderKey)..sort(), [
          'NOTA.TXT',
          'OCULTA',
          'SISTEMA',
        ]);
        expect(childNameKeysSync(b)..sort(), ['Oculta', 'Sistema', 'nota.txt']);
      },
    );
  });
}

void unawaitedDrain(Future<void> future) {
  future.then<void>((_) {}, onError: (Object _) {});
}
