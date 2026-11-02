import 'dart:async';
import 'dart:io';

import 'package:nexus_bridges_core/src/outbox/outbox.dart';
import 'package:nexus_bridges_core/src/protocol/protocol.dart' show Limits;
import 'package:test/test.dart';

const String docA = r'C:\in\Informe.pdf';
const String docB = r'C:\in\notas.txt';
const String project = r'C:\in\Proyecto';
const String gone = r'C:\in\ya-no-esta.txt';
const String odd = r'C:\in\raro';

final class FakeProbe {
  FakeProbe([Map<String, ElementProbe>? kinds]) : kinds = kinds ?? {};

  final Map<String, ElementProbe> kinds;
  final List<String> calls = [];
  final Set<String> failing = {};
  Completer<void>? gate;

  Future<ElementProbe> call(String path) async {
    calls.add(path);
    final hold = gate;
    if (hold != null) await hold.future;
    if (failing.contains(path)) {
      throw FileSystemException('probe failed', path);
    }
    return kinds[path] ?? const ElementProbe(kind: ElementKind.file, size: 1);
  }
}

final class DiskWatch {
  final List<String> touched = [];

  Never _hit(String what, String path) {
    touched.add('$what $path');
    throw StateError('disk touched: $what');
  }

  Future<T> run<T>(Future<T> Function() body) => IOOverrides.runZoned(
    body,
    createDirectory: (path) => _hit('directory', path),
    createFile: (path) => _hit('file', path),
    createLink: (path) => _hit('link', path),
    stat: (path) => _hit('stat', path),
    statSync: (path) => _hit('statSync', path),
    fseIdentical: (a, b) => _hit('identical', a),
    fseIdenticalSync: (a, b) => _hit('identicalSync', a),
    fseGetType: (path, follow) => _hit('type', path),
    fseGetTypeSync: (path, follow) => _hit('typeSync', path),
    fsWatch: (path, events, recursive) => _hit('watch', path),
    fsWatchIsSupported: () => _hit('watchSupported', ''),
  );
}

List<String> manyPaths(int count, {String prefix = r'C:\lote\f'}) => [
  for (var i = 0; i < count; i++) '$prefix$i.bin',
];

void main() {
  late FakeProbe probe;
  late SendTray tray;
  late int changes;

  SendTray makeTray() {
    final created = SendTray(probe: probe.call);
    created.changes.listen((_) => changes++);
    addTearDown(created.close);
    return created;
  }

  Future<void> flush() => Future<void>.delayed(Duration.zero);

  setUp(() {
    changes = 0;
    probe = FakeProbe({
      docA: const ElementProbe(kind: ElementKind.file, size: 10),
      docB: const ElementProbe(kind: ElementKind.file, size: 20),
      project: const ElementProbe(kind: ElementKind.folder),
      gone: const ElementProbe(kind: ElementKind.missing),
      odd: const ElementProbe(kind: ElementKind.other),
    });
    tray = makeTray();
  });

  group('E510: the tray adds, removes and empties without touching the disk '
      '(RF-310, RF-311)', () {
    test('E510 a fresh tray is empty and announces nothing', () async {
      await flush();
      expect(tray.items, isEmpty);
      expect(tray.paths, isEmpty);
      expect(changes, 0);
    });

    test('E510 adding files and a folder keeps them in order with their '
        'name, kind and ids t1, t2, t3', () async {
      expect(await tray.add([docA, project, docB]), TrayAddResult.added);
      await flush();
      expect(tray.items, const [
        TrayItemView(id: 't1', name: 'Informe.pdf', isFolder: false),
        TrayItemView(id: 't2', name: 'Proyecto', isFolder: true),
        TrayItemView(id: 't3', name: 'notas.txt', isFolder: false),
      ]);
      expect(tray.paths, [docA, project, docB]);
      expect(tray.items, hasLength(3));
      expect(changes, 1);
    });

    test(
      'E510 a second add goes to the end and the ids keep counting',
      () async {
        await tray.add([docA]);
        await tray.add([project, docB]);
        await flush();
        expect(tray.items.map((i) => i.id), ['t1', 't2', 't3']);
        expect(tray.paths, [docA, project, docB]);
        expect(changes, 2);
      },
    );

    test('E510 an item that no longer exists or is something else is shown as '
        'a file', () async {
      expect(await tray.add([gone, odd]), TrayAddResult.added);
      expect(tray.items, const [
        TrayItemView(id: 't1', name: 'ya-no-esta.txt', isFolder: false),
        TrayItemView(id: 't2', name: 'raro', isFolder: false),
      ]);
      expect(tray.paths, [gone, odd]);
    });

    test(
      'E510 a probe that throws still adds the item, shown as a file',
      () async {
        probe.failing.add(project);
        expect(await tray.add([project, docA]), TrayAddResult.added);
        expect(tray.items, const [
          TrayItemView(id: 't1', name: 'Proyecto', isFolder: false),
          TrayItemView(id: 't2', name: 'Informe.pdf', isFolder: false),
        ]);
      },
    );

    test('E510 a drive root is shown as a folder even if the probe says '
        'otherwise', () async {
      probe.kinds[r'D:\'] = const ElementProbe(kind: ElementKind.other);
      expect(await tray.add([r'D:\']), TrayAddResult.added);
      expect(tray.items.single.isFolder, isTrue);
      expect(tray.paths, [r'D:\']);
    });

    test('E510 the shown name goes through visibleFileName', () async {
      const marked = 'C:\\in\\Informe\u200E.pdf';
      const markedFolder = 'C:\\in\\Proyecto\u200F';
      await tray.add([marked, markedFolder]);
      expect(tray.items.map((i) => i.name), ['Informe.pdf', 'Proyecto']);
      expect(tray.paths, [marked, markedFolder]);
    });

    test('E510 removing one item leaves the rest in order', () async {
      await tray.add([docA, project, docB]);
      await flush();
      changes = 0;
      tray.remove('t2');
      await flush();
      expect(tray.items.map((i) => i.id), ['t1', 't3']);
      expect(tray.paths, [docA, docB]);
      expect(changes, 1);
    });

    test(
      'E510 removing an unknown id changes nothing and announces nothing',
      () async {
        await tray.add([docA]);
        await flush();
        changes = 0;
        tray.remove('t9');
        tray.remove('q1');
        tray.remove('');
        await flush();
        expect(tray.paths, [docA]);
        expect(changes, 0);
      },
    );

    test('E510 a removed path can be added again with a new id', () async {
      await tray.add([docA, docB]);
      tray.remove('t1');
      expect(await tray.add([docA]), TrayAddResult.added);
      expect(tray.paths, [docB, docA]);
      final ids = tray.items.map((i) => i.id).toList();
      expect(ids.toSet(), hasLength(2));
      expect(ids.last, isNot('t1'));
      expect(ids.last, isNot('t2'));
    });

    test('E510 clear empties the tray and announces it once', () async {
      await tray.add([docA, project, docB]);
      await flush();
      changes = 0;
      tray.clear();
      await flush();
      expect(tray.items, isEmpty);
      expect(tray.paths, isEmpty);
      expect(changes, 1);
    });

    test('E510 clearing an empty tray announces nothing', () async {
      tray.clear();
      await flush();
      expect(changes, 0);
    });

    test('E510 after clear the same paths can be added again', () async {
      await tray.add([docA, project]);
      tray.clear();
      expect(await tray.add([docA, project]), TrayAddResult.added);
      expect(tray.paths, [docA, project]);
      final ids = tray.items.map((i) => i.id).toSet();
      expect(ids, hasLength(2));
    });

    test('E510 the lists it hands out cannot change the tray', () async {
      await tray.add([docA]);
      expect(() => tray.items.add(tray.items.first), throwsUnsupportedError);
      expect(() => tray.paths.add(docB), throwsUnsupportedError);
      expect(() => tray.paths.clear(), throwsUnsupportedError);
      expect(tray.paths, [docA]);
    });

    test('E510 changing the list passed to add afterwards does not change the '
        'tray', () async {
      final given = [docA, docB];
      final pending = tray.add(given);
      given
        ..clear()
        ..add(project);
      expect(await pending, TrayAddResult.added);
      expect(tray.paths, [docA, docB]);
    });

    test('E510 add, remove and clear never touch the disk: the probe is the '
        'only thing called', () async {
      final watch = DiskWatch();
      final paths = [
        r'Q:\no-existe\uno.txt',
        r'Q:\no-existe\carpeta',
        r'Q:\no-existe\dos.txt',
      ];
      probe.kinds[paths[1]] = const ElementProbe(kind: ElementKind.folder);
      final results = await watch.run(() async {
        final local = SendTray(probe: probe.call);
        final first = await local.add(paths);
        final again = await local.add([paths[0].toUpperCase()]);
        local.remove('t2');
        final seen = local.items.map((i) => (i.name, i.isFolder)).toList();
        final left = local.paths;
        local.clear();
        final empty = local.items;
        await local.close();
        return (first, again, seen, left, empty);
      });
      expect(watch.touched, isEmpty);
      expect(results.$1, TrayAddResult.added);
      expect(results.$2, TrayAddResult.nothingNew);
      expect(results.$3, [('uno.txt', false), ('dos.txt', false)]);
      expect(results.$4, [paths[0], paths[2]]);
      expect(results.$5, isEmpty);
      expect(probe.calls, paths);
    });

    test(
      'E510 close ends the change stream and later calls do not throw',
      () async {
        final local = SendTray(probe: probe.call);
        var done = false;
        local.changes.listen((_) {}, onDone: () => done = true);
        await local.add([docA]);
        await local.close();
        await flush();
        expect(done, isTrue);
        expect(() => local.remove('t1'), returnsNormally);
        expect(() => local.clear(), returnsNormally);
        await local.close();
      },
    );
  });

  group('E511: no repeated paths and at most 1 000 items (RF-314)', () {
    test('E511 the same folder twice stays once and the second add is '
        'nothingNew', () async {
      expect(await tray.add([project]), TrayAddResult.added);
      await flush();
      changes = 0;
      expect(await tray.add([project]), TrayAddResult.nothingNew);
      await flush();
      expect(tray.paths, [project]);
      expect(changes, 0);
      expect(probe.calls, [project]);
    });

    test('E511 the same folder with other letter case, with / and with a final '
        r'\ stays once', () async {
      expect(await tray.add([project]), TrayAddResult.added);
      for (final variant in [
        r'c:\IN\proyecto',
        'C:/in/Proyecto',
        r'C:\in\Proyecto\',
        'c:/in/PROYECTO/',
        r'C:\in\Proyecto\\',
      ]) {
        expect(
          await tray.add([variant]),
          TrayAddResult.nothingNew,
          reason: variant,
        );
      }
      expect(tray.paths, [project]);
      expect(tray.items, hasLength(1));
      expect(probe.calls, [project]);
    });

    test('E511 the tray keeps the path normalized: / turned into \\ and '
        r'without a final \ ', () async {
      expect(await tray.add(['C:/in/Proyecto/']), TrayAddResult.added);
      expect(tray.paths, [project]);
      expect(probe.calls, [project]);
      expect(tray.items.single.name, 'Proyecto');
    });

    test(
      r'E511 a drive root keeps its \ and is not repeated as D: or d:/',
      () async {
        expect(await tray.add(['D:/']), TrayAddResult.added);
        expect(tray.paths, [r'D:\']);
        expect(await tray.add([r'd:\']), TrayAddResult.nothingNew);
        expect(await tray.add([r'D:\\']), TrayAddResult.nothingNew);
        expect(tray.paths, [r'D:\']);
      },
    );

    test(
      'E511 repeats inside one call are kept once, the first spelling wins',
      () async {
        expect(
          await tray.add([
            docA,
            r'c:\in\informe.PDF',
            'C:/in/Informe.pdf',
            docB,
          ]),
          TrayAddResult.added,
        );
        expect(tray.paths, [docA, docB]);
        expect(tray.items.map((i) => i.id), ['t1', 't2']);
        expect(probe.calls, [docA, docB]);
      },
    );

    test('E511 a call with old and new paths adds only the new ones', () async {
      await tray.add([docA]);
      expect(
        await tray.add([docA.toUpperCase(), project]),
        TrayAddResult.added,
      );
      expect(tray.paths, [docA, project]);
      expect(probe.calls, [docA, project]);
    });

    test('E511 an empty call is nothingNew and announces nothing', () async {
      expect(await tray.add(const []), TrayAddResult.nothingNew);
      await flush();
      expect(changes, 0);
      expect(probe.calls, isEmpty);
    });

    test(
      'E511 with 999 items, adding 2 new ones is tooMany and adds nothing',
      () async {
        expect(await tray.add(manyPaths(999)), TrayAddResult.added);
        await flush();
        probe.calls.clear();
        changes = 0;
        expect(
          await tray.add([r'C:\extra\uno.txt', r'C:\extra\dos.txt']),
          TrayAddResult.tooMany,
        );
        await flush();
        expect(tray.items, hasLength(999));
        expect(tray.paths, isNot(contains(r'C:\extra\uno.txt')));
        expect(probe.calls, isEmpty);
        expect(changes, 0);
        expect(Limits.maxSelectionItems, 1000);
      },
    );

    test(
      'E511 with 999 items, one new and one repeated fill it up to 1 000',
      () async {
        await tray.add(manyPaths(999));
        expect(
          await tray.add([r'C:\lote\F0.BIN', r'C:\extra\uno.txt']),
          TrayAddResult.added,
        );
        expect(tray.items, hasLength(1000));
        expect(tray.paths.last, r'C:\extra\uno.txt');
        expect(tray.items.last.id, 't1000');
      },
    );

    test('E511 a full tray refuses one more with tooMany and a repeat with '
        'nothingNew', () async {
      expect(await tray.add(manyPaths(1000)), TrayAddResult.added);
      expect(await tray.add([r'C:\extra\uno.txt']), TrayAddResult.tooMany);
      expect(await tray.add([r'C:\lote\f5.bin']), TrayAddResult.nothingNew);
      expect(tray.items, hasLength(1000));
    });

    test('E511 1 001 paths at once on an empty tray are tooMany and nothing '
        'is probed', () async {
      expect(await tray.add(manyPaths(1001)), TrayAddResult.tooMany);
      expect(tray.items, isEmpty);
      expect(probe.calls, isEmpty);
    });

    test(
      'E511 1 001 paths with one repeat inside are exactly 1 000 and fit',
      () async {
        final paths = [...manyPaths(1000), r'C:\LOTE\F7.BIN'];
        expect(await tray.add(paths), TrayAddResult.added);
        expect(tray.items, hasLength(1000));
      },
    );

    test('E511 after removing one from a full tray a new one fits', () async {
      await tray.add(manyPaths(1000));
      tray.remove('t1');
      expect(await tray.add([r'C:\extra\uno.txt']), TrayAddResult.added);
      expect(tray.items, hasLength(1000));
    });

    test(
      'E511 two adds of the same path at the same time keep it once',
      () async {
        probe.gate = Completer<void>();
        final first = tray.add([project]);
        final second = tray.add([r'c:/IN/proyecto/']);
        await flush();
        probe.gate!.complete();
        expect(await first, TrayAddResult.added);
        expect(await second, TrayAddResult.nothingNew);
        expect(tray.paths, [project]);
        expect(probe.calls, [project]);
      },
    );

    test(
      'E511 two adds at the same time cannot get past 1 000 together',
      () async {
        await tray.add(manyPaths(998));
        probe.gate = Completer<void>();
        final first = tray.add([r'C:\extra\a.txt', r'C:\extra\b.txt']);
        final second = tray.add([r'C:\extra\c.txt']);
        await flush();
        probe.gate!.complete();
        expect(await first, TrayAddResult.added);
        expect(await second, TrayAddResult.tooMany);
        expect(tray.items, hasLength(1000));
        expect(tray.paths, isNot(contains(r'C:\extra\c.txt')));
      },
    );

    test('E511 a probe that fails does not block the next add', () async {
      probe.failing.add(docA);
      expect(await tray.add([docA]), TrayAddResult.added);
      expect(await tray.add([docB]), TrayAddResult.added);
      expect(tray.paths, [docA, docB]);
    });
  });

  group('E515: the tray only keeps paths (RF-313)', () {
    test('E515 after add, the probe is the only thing called, once per new '
        'path and never again', () async {
      final watch = DiskWatch();
      final seen = await watch.run(() async {
        await tray.add([docA, project, gone]);
        await tray.add([docA, project]);
        final before = tray.paths;
        tray.remove('t1');
        return (before, tray.paths, tray.items.length);
      });
      expect(watch.touched, isEmpty);
      expect(probe.calls, [docA, project, gone]);
      expect(seen.$1, [docA, project, gone]);
      expect(seen.$2, [project, gone]);
      expect(seen.$3, 2);
    });

    test('E515 what it hands back are the paths themselves, not their '
        'contents', () async {
      final folder = await Directory.systemTemp.createTemp('nexus_tray_');
      addTearDown(() => folder.delete(recursive: true));
      final file = File('${folder.path}\\secreto.txt');
      await file.writeAsString('contenido que no debe leerse');
      final path = file.path;
      expect(await tray.add([path]), TrayAddResult.added);
      expect(tray.paths, [path]);
      expect(tray.items.single.name, 'secreto.txt');
      await file.delete();
      expect(tray.paths, [path]);
      expect(tray.items.single.name, 'secreto.txt');
      expect(probe.calls, [path]);
    });
  });
}
