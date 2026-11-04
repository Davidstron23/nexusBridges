import 'dart:io';

import 'package:nexus_bridges_core/src/browse/browse.dart';
import 'package:nexus_bridges_core/src/transfer/platform.dart'
    show SystemFolders;
import 'package:nexus_bridges_core/src/winio/winio.dart';
import 'package:test/test.dart';

import '../transfer/receiver_harness.dart' show TransferPlatform;
import '../winio/short_names.dart';

export '../winio/short_names.dart';

Future<String> realTemp(String prefix) async {
  final dir = await Directory.systemTemp.createTemp(prefix);
  addTearDown(() async {
    for (var attempt = 0; attempt < 60; attempt++) {
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

bool trySymlink(String link, String target) {
  try {
    Link(link).createSync(target);
    return true;
  } on FileSystemException {
    return false;
  }
}

void attrib(String flags, String path) {
  final made = Process.runSync('attrib', [
    ...flags.split(' '),
    path,
  ], workingDirectory: Directory.systemTemp.path);
  expect(made.exitCode, 0, reason: '${made.stdout}${made.stderr}');
}

String volumeOf(String path) {
  final opened = openFolderByPathSync(path, lock: false);
  expect(opened, isA<FolderOpened>());
  final handle = (opened as FolderOpened).handle;
  try {
    return folderFactsSync(handle)!.volumeId;
  } finally {
    closeHandleSync(handle);
  }
}

String hexId(int n) => n.toRadixString(16).padLeft(32, '0');

ShareRecord recordFor(
  String path, {
  int id = 1,
  String? label,
  String? volumeId,
  bool home = false,
}) => ShareRecord(
  id: hexId(id),
  path: path,
  volumeId: volumeId ?? volumeOf(path),
  label: label ?? (home ? '' : path.substring(path.lastIndexOf(r'\') + 1)),
  home: home,
  drive: DriveKind.fixed,
  addedAt: DateTime.utc(2026, 11, 1),
);

final class ShareTree {
  ShareTree._(this.base, this.docs, this.fs, this.symlinked);

  final String base;
  final String docs;
  final WindowsShareFileSystem fs;
  final bool symlinked;

  String get outside => '$base\\fuera';

  String get sentinel => '$outside\\centinela';

  ShareRecord get root => recordFor(docs);

  String child(String name) => '$docs\\$name';

  List<String> outsideNames() => [
    for (final entity in Directory(outside).listSync())
      entity.uri.pathSegments.where((s) => s.isNotEmpty).last,
  ]..sort();
}

Future<ShareTree> shareTree() async {
  final base = await realTemp('nexus_t007_share_');
  final docs = '$base\\docs';
  for (final name in [
    'sub',
    'otra',
    'destino',
    'Oculta',
    'Sistema',
    '.git',
    'Inicio',
    'MiProyectoLargo',
    '.nexusbridges-incoming',
  ]) {
    Directory('$docs\\$name').createSync(recursive: true);
  }
  attrib('+h', '$docs\\Oculta');
  attrib('+s', '$docs\\Sistema');
  attrib('+h', '$docs\\.git');
  for (final name in ['suelto.txt', 'acceso.lnk', 'desktop.ini', 'f']) {
    File('$docs\\$name').writeAsStringSync('archivo');
  }
  expect(makeRawFolder('$docs\\CON'), isTrue);
  expect(makeRawFolder('$docs\\x.'), isTrue);
  Directory('$base\\fuera\\centinela').createSync(recursive: true);
  junction('$docs\\union', '$base\\fuera');
  junction('$docs\\interna', '$docs\\destino');
  junction('$docs\\ventanas', r'C:\Windows');
  final symlinked = trySymlink('$docs\\enlace', '$base\\fuera');
  final sys = '$base\\sys';
  for (final name in ['downloads', 'startmenu', 'windows', 'pf', 'root']) {
    Directory('$sys\\$name').createSync(recursive: true);
  }
  final platform = TransferPlatform(
    SystemFolders(
      downloads: '$sys\\downloads',
      startup: '$docs\\Inicio',
      startMenu: '$sys\\startmenu',
      windows: '$sys\\windows',
      programFiles: '$sys\\pf',
      systemDriveRoot: '$sys\\root',
    ),
  );
  Directory('$base\\data').createSync();
  final fs = WindowsShareFileSystem(
    platform: platform,
    dataDirs: ['$base\\data'],
  );
  return ShareTree._(base, docs, fs, symlinked);
}

bool renames(String from, String to) {
  try {
    Directory(from).renameSync(to);
    Directory(to).renameSync(from);
    return true;
  } on FileSystemException {
    return false;
  }
}
