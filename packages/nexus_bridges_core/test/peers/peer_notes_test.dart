import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:nexus_bridges_core/src/peers/peers.dart';
import 'package:nexus_bridges_core/src/protocol/protocol.dart' show Limits;
import 'package:nexus_bridges_core/src/transfer/transfer.dart'
    show TransferOutcome;
import 'package:test/test.dart';

import 'peer_notes_support.dart';

Future<void> waitFor(
  bool Function() condition, {
  Duration limit = const Duration(seconds: 5),
}) async {
  final watch = Stopwatch()..start();
  while (!condition()) {
    if (watch.elapsed > limit) fail('condition not met within $limit');
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}

String readText(File file) {
  for (var attempt = 0; ; attempt++) {
    try {
      return file.readAsStringSync();
    } on FileSystemException {
      if (attempt == 200) rethrow;
      sleep(const Duration(milliseconds: 5));
    }
  }
}

Future<int> failuresDuring(
  PeerNotes notes,
  FutureOr<void> Function() action,
) async {
  var failures = 0;
  final subscription = notes.saveFailures.listen((_) => failures++);
  await action();
  await waitFor(() => failures > 0);
  await Future<void>.delayed(const Duration(milliseconds: 900));
  await subscription.cancel();
  return failures;
}

void main() {
  late NotesBench bench;

  setUp(() async => bench = await NotesBench.create());

  group('addFavorite through PeerNotes (E760, RF-428)', () {
    test('keeps the order of addition', () {
      final notes = bench.notes();

      for (final name in ['z', 'a', 'm']) {
        expect(
          notes.addFavorite(peerA, place(name, path: [name])),
          FavoriteResult.added,
        );
      }

      expect(notes.noteOf(peerA).favorites.map((d) => d.rootName), [
        'z',
        'a',
        'm',
      ]);
    });

    test('the same destination gives alreadyThere and changes nothing', () {
      final notes = bench.notes();
      notes.addFavorite(peerA, place('docs', path: const ['Sub']));

      final result = notes.addFavorite(
        peerA,
        place('otro nombre', path: const ['SUB']),
      );

      expect(result, FavoriteResult.alreadyThere);
      expect(notes.noteOf(peerA).favorites.single.rootName, 'docs');
    });

    test('the ninth gives full and is not stored', () {
      final notes = bench.notes();
      for (var i = 0; i < Limits.maxFavoritesPerPeer; i++) {
        expect(
          notes.addFavorite(peerA, place('f$i', path: ['f$i'])),
          FavoriteResult.added,
        );
      }

      expect(
        notes.addFavorite(peerA, place('nueve', path: const ['nueve'])),
        FavoriteResult.full,
      );
      expect(notes.noteOf(peerA).favorites, hasLength(8));
    });

    test('with the list full, a repeated one is still alreadyThere', () {
      final notes = bench.notes();
      for (var i = 0; i < 8; i++) {
        notes.addFavorite(peerA, place('f$i', path: ['f$i']));
      }

      expect(
        notes.addFavorite(peerA, place('f3', path: const ['f3'])),
        FavoriteResult.alreadyThere,
      );
    });

    test('the limit is per peer', () {
      final notes = bench.notes();
      for (var i = 0; i < 8; i++) {
        notes.addFavorite(peerA, place('f$i', path: ['f$i']));
      }

      expect(
        notes.addFavorite(peerB, place('f0', path: const ['f0'])),
        FavoriteResult.added,
      );
    });

    test('removeFavorite takes out the one at that index', () {
      final notes = bench.notes();
      for (final name in ['a', 'b', 'c']) {
        notes.addFavorite(peerA, place(name, path: [name]));
      }

      notes.removeFavorite(peerA, 1);

      expect(notes.noteOf(peerA).favorites.map((d) => d.rootName), ['a', 'c']);
    });

    test('removeFavorite out of range does nothing', () {
      final notes = bench.notes();
      notes.addFavorite(peerA, place('a'));

      notes.removeFavorite(peerA, -1);
      notes.removeFavorite(peerA, 1);
      notes.removeFavorite(peerB, 0);

      expect(notes.noteOf(peerA).favorites, hasLength(1));
      expect(notes.knownPeers, {peerA});
    });
  });

  group('the alias in PeerNotes (RF-429)', () {
    test('is cleaned before it is stored', () {
      final notes = bench.notes();

      notes.setAlias(peerA, '  Casa\u{202E}  ');

      expect(notes.noteOf(peerA).alias, 'Casa');
    });

    test('left empty, it is removed and the peer has no note', () {
      final notes = bench.notes();
      notes.setAlias(peerA, 'Casa');

      notes.setAlias(peerA, '   ');

      expect(notes.noteOf(peerA).alias, isNull);
      expect(notes.knownPeers, isEmpty);
    });

    test('left empty, the rest of the note stays', () {
      final notes = bench.notes();
      notes.setAlias(peerA, 'Casa');
      notes.addFavorite(peerA, place('docs'));

      notes.setAlias(peerA, '');

      expect(notes.noteOf(peerA).alias, isNull);
      expect(notes.noteOf(peerA).favorites, hasLength(1));
    });

    test('the same alias emits no change', () async {
      final notes = bench.notes();
      notes.setAlias(peerA, 'Casa');
      await Future<void>.delayed(Duration.zero);
      var changes = 0;
      final subscription = notes.changes.listen((_) => changes++);

      notes.setAlias(peerA, ' Casa ');
      await Future<void>.delayed(Duration.zero);

      await subscription.cancel();
      expect(changes, 0);
    });

    test(
      'every real change is applied in memory and emitted at once',
      () async {
        final notes = bench.notes();
        var changes = 0;
        final subscription = notes.changes.listen((_) => changes++);

        notes.setAlias(peerA, 'Casa');
        expect(notes.noteOf(peerA).alias, 'Casa');
        notes.addRecent(peerA, place('docs'));
        notes.appendHistory(peerA, historyEntry('a.txt'));
        await Future<void>.delayed(Duration.zero);

        await subscription.cancel();
        expect(changes, 3);
      },
    );
  });

  group('appendHistory keeps the file loadable (T7, decision 3)', () {
    test(
      'control characters in the name become U+FFFD and it loads back',
      () async {
        final notes = bench.notes();
        notes.setAlias(peerB, 'Sigue');
        notes.appendHistory(peerA, historyEntry('a\u{0007}b\u{000A}c.txt'));
        await notes.flush();

        final back = await bench.reopen();

        expect(
          back.noteOf(peerA).history.single.name,
          'a\u{FFFD}b\u{FFFD}c.txt',
        );
        expect(back.noteOf(peerB).alias, 'Sigue');
        expect(bench.quarantined, isEmpty);
      },
    );

    test(
      'a very long name is cut to 255 characters and it loads back',
      () async {
        final notes = bench.notes();
        notes.appendHistory(peerA, historyEntry('n' * 900));
        await notes.flush();

        final back = await bench.reopen();

        expect(back.noteOf(peerA).history.single.name, 'n' * 255);
        expect(bench.quarantined, isEmpty);
      },
    );

    test('a long name of emoji still loads back', () async {
      final emoji = String.fromCharCodes(List.filled(400, 0x1F4C1));
      final notes = bench.notes();
      notes.appendHistory(peerA, historyEntry(emoji));
      await notes.flush();

      final back = await bench.reopen();

      expect(back.noteOf(peerA).history, hasLength(1));
      expect(bench.quarantined, isEmpty);
    });

    test('an empty name is stored as U+FFFD', () async {
      final notes = bench.notes();
      notes.appendHistory(peerA, historyEntry(''));
      await notes.flush();

      final back = await bench.reopen();

      expect(back.noteOf(peerA).history.single.name, '\u{FFFD}');
    });

    test('impossible counts are brought back to valid ones', () async {
      final notes = bench.notes();
      notes.appendHistory(
        peerA,
        historyEntry('x', fileCount: -1, itemCount: 0, delivered: 5, size: -10),
      );
      await notes.flush();

      final back = (await bench.reopen()).noteOf(peerA).history.single;

      expect(back.fileCount, 0);
      expect(back.itemCount, 1);
      expect(back.delivered, 1);
      expect(back.size, 0);
    });

    test(
      'a destination root name with control characters still loads',
      () async {
        final notes = bench.notes();
        notes.appendHistory(
          peerA,
          historyEntry('x', destinationRoot: 'do\u{0007}cs'),
        );
        await notes.flush();

        final back = await bench.reopen();

        expect(
          back.noteOf(peerA).history.single.destinationRoot,
          'do\u{FFFD}cs',
        );
      },
    );

    test(
      'a destination root name of 200 emoji does not lose the file',
      () async {
        final notes = bench.notes();
        notes.setAlias(peerB, 'Sigue');
        notes.appendHistory(
          peerA,
          historyEntry(
            'x',
            destinationRoot: String.fromCharCodes(List.filled(200, 0x1F4C1)),
          ),
        );
        await notes.flush();

        final back = await bench.reopen();

        expect(bench.quarantined, isEmpty);
        expect(back.noteOf(peerB).alias, 'Sigue');
      },
    );

    test('a history destination with an invalid component does not lose the '
        'file', () async {
      final notes = bench.notes();
      notes.setAlias(peerB, 'Sigue');
      notes.appendHistory(
        peerA,
        historyEntry(
          'x',
          destinationRoot: 'docs',
          destinationPath: const ['a:b'],
        ),
      );
      await notes.flush();

      final back = await bench.reopen();

      expect(bench.quarantined, isEmpty);
      expect(back.noteOf(peerB).alias, 'Sigue');
    });

    test('a history destination deeper than the limit does not lose the '
        'file', () async {
      final notes = bench.notes();
      notes.setAlias(peerB, 'Sigue');
      notes.appendHistory(
        peerA,
        historyEntry(
          'x',
          destinationRoot: 'docs',
          destinationPath: List.filled(Limits.maxRelativeDepth + 1, 'p'),
        ),
      );
      await notes.flush();

      final back = await bench.reopen();

      expect(bench.quarantined, isEmpty);
      expect(back.noteOf(peerB).alias, 'Sigue');
    });

    test(
      'every TransferOutcome survives a round trip through the file',
      () async {
        final notes = bench.notes();
        for (final outcome in TransferOutcome.values.take(50)) {
          notes.appendHistory(peerA, historyEntry('x', outcome: outcome.name));
        }
        await notes.flush();

        final back = await bench.reopen();

        expect(bench.quarantined, isEmpty);
        expect(
          back.noteOf(peerA).history.map((e) => e.outcome).toSet(),
          TransferOutcome.values.take(50).map((o) => o.name).toSet(),
        );
        for (final outcome in TransferOutcome.values) {
          expect(outcome.name, matches(RegExp(r'^[a-zA-Z]{1,40}$')));
        }
      },
    );
  });

  group('persistence and format of peers.json (RF-426, RF-428, RF-429, '
      'RF-430)', () {
    test('everything comes back the same after a reload', () async {
      final notes = bench.notes();
      final favorite = place('Documentos', path: const ['prueba-007']);
      final recent = place('', root: rootTwo, home: true);
      final entry = historyEntry(
        'mod.zip',
        itemCount: 3,
        delivered: 2,
        size: 123,
        destinationRoot: 'Documentos',
        destinationPath: const ['mods'],
        outcome: 'noSpace',
      );
      notes.setAlias(peerA, 'Portátil de casa');
      notes.addFavorite(peerA, favorite);
      notes.addRecent(peerA, recent);
      notes.appendHistory(peerA, entry);
      await notes.flush();

      final back = (await bench.reopen()).noteOf(peerA);

      expect(back.alias, 'Portátil de casa');
      expect(back.favorites, [favorite]);
      expect(back.recent, [recent]);
      expect(back.history, [entry]);
    });

    test('notes are kept by fingerprint', () async {
      final notes = bench.notes();
      notes.setAlias(peerA, 'Uno');
      notes.setAlias(peerB, 'Dos');
      await notes.flush();

      final back = await bench.reopen();

      expect(back.noteOf(peerA).alias, 'Uno');
      expect(back.noteOf(peerB).alias, 'Dos');
      expect(back.noteOf(peerC).alias, isNull);
      expect(back.knownPeers, {peerA, peerB});
    });

    test('the file has the shape of the plan', () async {
      final notes = bench.notes();
      notes.setAlias(peerA, 'Casa');
      notes.addFavorite(peerA, place('Documentos', path: const ['prueba-007']));
      notes.appendHistory(
        peerA,
        historyEntry(
          'mod.zip',
          itemCount: 3,
          delivered: 3,
          size: 123,
          destinationRoot: 'Documentos',
          destinationPath: const ['mods'],
        ),
      );
      await notes.flush();

      final json = bench.readJson();
      final peer =
          (json['peers'] as List<Object?>).single as Map<String, Object?>;

      expect(json.keys.toSet(), {'version', 'owner', 'peers'});
      expect(json['version'], 1);
      expect(json['owner'], ownerPrint);
      expect(peer.keys.toSet(), {
        'fingerprint',
        'alias',
        'favorites',
        'recent',
        'history',
      });
      expect(peer['fingerprint'], peerA);
      expect(peer['alias'], 'Casa');
      expect(peer['favorites'], [
        {
          'root': rootOne,
          'rootName': 'Documentos',
          'home': false,
          'path': ['prueba-007'],
        },
      ]);
      expect(peer['history'], [
        {
          'at': '2026-11-01T10:00:00.000Z',
          'dir': 'sent',
          'name': 'mod.zip',
          'folder': false,
          'files': 0,
          'items': 3,
          'delivered': 3,
          'size': 123,
          'destRoot': 'Documentos',
          'destHome': false,
          'destPath': ['mods'],
          'outcome': 'saved',
        },
      ]);
    });

    test('a peer without alias and with destRoot null loads back', () async {
      final notes = bench.notes();
      notes.appendHistory(peerA, historyEntry('a.txt'));
      await notes.flush();
      final peer =
          (bench.readJson()['peers'] as List<Object?>).single
              as Map<String, Object?>;

      expect(peer['alias'], isNull);
      expect(
        (peer['history'] as List<Object?>).single,
        containsPair('destRoot', null),
      );

      final back = (await bench.reopen()).noteOf(peerA);

      expect(back.alias, isNull);
      expect(back.history.single.destinationRoot, isNull);
      expect(bench.quarantined, isEmpty);
    });

    test('a note left empty is not written', () async {
      final notes = bench.notes();
      notes.setAlias(peerA, 'Casa');
      await notes.flush();
      notes.setAlias(peerA, '');
      await notes.flush();

      expect(bench.readJson()['peers'], isEmpty);
    });
  });

  group('the file peers.json at load (G12, RF-407)', () {
    test(
      'a missing file gives empty notes, loads true and no quarantine',
      () async {
        var loaded = false;

        final back = await bench.reopen(onLoad: (ok) => loaded = ok);

        expect(loaded, isTrue);
        expect(back.knownPeers, isEmpty);
        expect(bench.names, isEmpty);
      },
    );

    test('the valid sample of the plan loads', () async {
      bench.writeRaw(validFile());
      var loaded = false;

      final back = await bench.reopen(onLoad: (ok) => loaded = ok);

      expect(loaded, isTrue);
      expect(bench.quarantined, isEmpty);
      final note = back.noteOf(peerA);
      expect(note.alias, 'Casa');
      expect(note.favorites.single.path, ['prueba-007']);
      expect(note.recent.single.rootId, rootTwo);
      expect(note.history.single.itemCount, 3);
      expect(note.history.single.direction, HistoryDirection.sent);
    });

    test('at the limits it still loads: 8 favorites, 5 recent, 50 history, 32 '
        'peers and path of 32 components', () async {
      final prints = [
        for (var i = 0; i < 32; i++)
          i.toRadixString(16).toUpperCase().padLeft(64, 'A'),
      ];
      final peer = validPeer(fingerprint: prints.first)
        ..['favorites'] = [
          for (var i = 0; i < 8; i++)
            validDestination(path: List.filled(32, 'p$i')),
        ]
        ..['recent'] = List.filled(5, validDestination())
        ..['history'] = List.filled(50, validHistory());
      bench.writeRaw(
        validFile(
          peers: [
            peer,
            for (final fingerprint in prints.skip(1))
              validPeer(fingerprint: fingerprint),
          ],
        ),
      );

      final back = await bench.reopen();

      expect(bench.quarantined, isEmpty);
      expect(back.knownPeers, hasLength(32));
      expect(back.noteOf(prints.first).history, hasLength(50));
    });

    final peerWith = <String, Map<String, Object?> Function()>{
      'an extra key in a peer': () => validPeer()..['extra'] = 1,
      'a peer without alias key': () => validPeer()..remove('alias'),
      'a lowercase fingerprint': () => validPeer(fingerprint: 'a' * 64),
      'a short fingerprint': () => validPeer(fingerprint: 'A' * 63),
      'an alias that is a number': () => validPeer()..['alias'] = 5,
      'an alias that cleanAlias changes': () => validPeer()..['alias'] = ' x ',
      'an empty alias': () => validPeer()..['alias'] = '',
      'an alias of 65 characters': () => validPeer()..['alias'] = 'a' * 65,
      'nine favorites': () =>
          validPeer()..['favorites'] = List.filled(9, validDestination()),
      'six recent': () =>
          validPeer()..['recent'] = List.filled(6, validDestination()),
      '51 history entries': () =>
          validPeer()..['history'] = List.filled(51, validHistory()),
      'favorites that are not a list': () => validPeer()..['favorites'] = {},
      'an extra key in a destination': () =>
          validPeer()..['favorites'] = [validDestination()..['x'] = 1],
      'a destination without home': () =>
          validPeer()..['favorites'] = [validDestination()..remove('home')],
      'a root of 31 hex': () =>
          validPeer()..['favorites'] = [validDestination(root: '1' * 31)],
      'a root in uppercase hex': () =>
          validPeer()..['favorites'] = [validDestination(root: 'A' * 32)],
      'home that is not a boolean': () =>
          validPeer()..['recent'] = [validDestination()..['home'] = 'no'],
      'an empty root name without home': () =>
          validPeer()..['recent'] = [validDestination(rootName: '')],
      'a root name with a control character': () =>
          validPeer()..['recent'] = [validDestination(rootName: 'a\u{0007}')],
      'a path that is not a list': () =>
          validPeer()..['recent'] = [validDestination()..['path'] = 'a'],
      'an empty path component': () => validPeer()
        ..['recent'] = [
          validDestination(path: const ['']),
        ],
      'a path component with a backslash': () => validPeer()
        ..['recent'] = [
          validDestination(path: const [r'a\b']),
        ],
      'a path component with a slash': () => validPeer()
        ..['recent'] = [
          validDestination(path: const ['a/b']),
        ],
      'a path component with a colon': () => validPeer()
        ..['recent'] = [
          validDestination(path: const ['C:']),
        ],
      'a path component that is not text': () => validPeer()
        ..['recent'] = [
          validDestination(path: const [1]),
        ],
      'a path of 33 components': () =>
          validPeer()
            ..['recent'] = [validDestination(path: List.filled(33, 'p'))],
      'an extra key in the history': () =>
          validPeer()..['history'] = [validHistory()..['x'] = 1],
      'a history entry without outcome': () =>
          validPeer()..['history'] = [validHistory()..remove('outcome')],
      'a history direction it does not know': () =>
          validPeer()..['history'] = [validHistory()..['dir'] = 'up'],
      'a date that does not parse': () =>
          validPeer()..['history'] = [validHistory()..['at'] = 'ayer'],
      'a date that is a number': () =>
          validPeer()..['history'] = [validHistory()..['at'] = 5],
      'an empty name': () =>
          validPeer()..['history'] = [validHistory()..['name'] = ''],
      'a name with a control character': () =>
          validPeer()..['history'] = [validHistory()..['name'] = 'a\u{0001}'],
      'negative files': () =>
          validPeer()..['history'] = [validHistory()..['files'] = -1],
      'zero items': () =>
          validPeer()..['history'] = [validHistory()..['items'] = 0],
      'negative delivered': () =>
          validPeer()..['history'] = [validHistory()..['delivered'] = -1],
      'more delivered than items': () =>
          validPeer()..['history'] = [validHistory()..['delivered'] = 4],
      'negative size': () =>
          validPeer()..['history'] = [validHistory()..['size'] = -1],
      'a size that is not an integer': () =>
          validPeer()..['history'] = [validHistory()..['size'] = 1.5],
      'a folder flag that is not a boolean': () =>
          validPeer()..['history'] = [validHistory()..['folder'] = 1],
      'a destination root that is a number': () =>
          validPeer()..['history'] = [validHistory()..['destRoot'] = 1],
      'a destination path with a colon': () => validPeer()
        ..['history'] = [
          validHistory()..['destPath'] = ['a:b'],
        ],
      'an outcome with a space': () =>
          validPeer()..['history'] = [validHistory()..['outcome'] = 'no way'],
      'an outcome of 41 letters': () =>
          validPeer()..['history'] = [validHistory()..['outcome'] = 'a' * 41],
    };

    for (final MapEntry(key: label, value: build) in peerWith.entries) {
      test('$label sets the file apart and starts empty', () async {
        bench.writeRaw(validFile(peers: [build()]));
        var loaded = true;

        final back = await bench.reopen(onLoad: (ok) => loaded = ok);

        expect(loaded, isFalse);
        expect(back.knownPeers, isEmpty);
        expect(bench.file.existsSync(), isFalse);
        expect(bench.quarantined, hasLength(1));
      });
    }

    final fileWith = <String, Object? Function()>{
      'broken JSON': () => '{"version":1,',
      'an empty file': () => '',
      'a JSON that is a list': () => '[1,2]',
      'version 2': () => validFile()..['version'] = 2,
      'a version that is text': () => validFile()..['version'] = '1',
      'no version': () => validFile()..remove('version'),
      'no owner': () => validFile()..remove('owner'),
      'an owner that is not a fingerprint': () =>
          validFile()..['owner'] = 'nadie',
      'an extra key': () => validFile()..['extra'] = true,
      'peers that is not a list': () => validFile()..['peers'] = {},
      '33 peers': () => validFile(
        peers: [
          for (var i = 0; i < 33; i++)
            validPeer(
              fingerprint: i.toRadixString(16).toUpperCase().padLeft(64, 'A'),
            ),
        ],
      ),
      'a repeated fingerprint': () =>
          validFile(peers: [validPeer(), validPeer()]),
    };

    for (final MapEntry(key: label, value: build) in fileWith.entries) {
      test('$label sets the file apart and starts empty', () async {
        bench.writeRaw(build());
        var loaded = true;

        final back = await bench.reopen(onLoad: (ok) => loaded = ok);

        expect(loaded, isFalse);
        expect(back.knownPeers, isEmpty);
        expect(bench.file.existsSync(), isFalse);
        expect(bench.quarantined, hasLength(1));
      });
    }

    test('binary garbage does not make load throw', () async {
      bench.file.writeAsBytesSync([0xFF, 0xFE, 0x00, 0x80, 0x81]);
      var loaded = true;

      final back = await bench.reopen(onLoad: (ok) => loaded = ok);

      expect(loaded, isFalse);
      expect(back.knownPeers, isEmpty);
      expect(bench.quarantined, hasLength(1));
    });

    test('a load that cannot even quarantine never throws', () async {
      bench.writeRaw('roto');
      final handle = bench.file.openSync(mode: FileMode.append);
      handle.lockSync(FileLock.exclusive);
      addTearDown(handle.closeSync);
      final notes = bench.notes();

      final loaded = await notes.load(isPaired: (_) => true);

      expect(loaded, isFalse);
      expect(notes.knownPeers, isEmpty);
    });

    test('an isPaired that throws never makes load throw', () async {
      bench.writeRaw(validFile());
      final notes = bench.notes();

      final loaded = await notes.load(
        isPaired: (_) => throw StateError('boom'),
      );

      expect(loaded, isFalse);
      expect(notes.knownPeers, isEmpty);
    });

    test(
      'another owner is set apart as previous-identity, with empty notes',
      () async {
        bench.writeRaw(validFile(owner: 'F' * 64));

        final back = await bench.reopen();

        expect(back.knownPeers, isEmpty);
        expect(bench.file.existsSync(), isFalse);
        expect(bench.quarantined.single, contains('previous-identity'));
      },
    );

    test('a broken file is set apart with its own reason', () async {
      bench.writeRaw('roto');

      await bench.reopen();

      expect(bench.quarantined.single, contains('broken'));
    });

    test('the file set apart keeps the original bytes', () async {
      bench.writeRaw('{"version":1,"roto":');

      await bench.reopen();

      final kept = File('${bench.dir.path}\\${bench.quarantined.single}');
      expect(kept.readAsStringSync(), '{"version":1,"roto":');
    });

    test('fingerprints no longer paired are dropped and the file rewritten, '
        'keeping the rest', () async {
      bench.writeRaw(
        validFile(
          peers: [
            validPeer(),
            validPeer(fingerprint: peerB),
          ],
        ),
      );
      var loaded = false;

      final back = await bench.reopen(
        isPaired: (fingerprint) => fingerprint == peerA,
        onLoad: (ok) => loaded = ok,
      );

      expect(loaded, isTrue);
      expect(back.knownPeers, {peerA});
      expect(back.noteOf(peerB).isEmpty, isTrue);
      expect(bench.file.readAsStringSync(), isNot(contains(peerB)));
      expect(bench.file.readAsStringSync(), contains(peerA));
    });

    test('with no paired fingerprint at all, nothing stays', () async {
      bench.writeRaw(validFile());

      final back = await bench.reopen(isPaired: (_) => false);

      expect(back.knownPeers, isEmpty);
      expect(bench.file.readAsStringSync(), isNot(contains(peerA)));
    });

    test('an empty peer list is valid', () async {
      bench.writeRaw(validFile(peers: []));
      var loaded = false;

      final back = await bench.reopen(onLoad: (ok) => loaded = ok);

      expect(loaded, isTrue);
      expect(back.knownPeers, isEmpty);
      expect(bench.quarantined, isEmpty);
    });

    test('a home destination may have an empty root name', () async {
      bench.writeRaw(
        validFile(
          peers: [
            validPeer()
              ..['recent'] = [validDestination(rootName: '', home: true)],
          ],
        ),
      );

      final back = await bench.reopen();

      expect(bench.quarantined, isEmpty);
      expect(back.noteOf(peerA).recent.single.home, isTrue);
    });

    test(
      'an unknown outcome with a valid shape is not a broken file',
      () async {
        bench.writeRaw(
          validFile(
            peers: [
              validPeer()
                ..['history'] = [validHistory()..['outcome'] = 'fromTheFuture'],
            ],
          ),
        );

        final back = await bench.reopen();

        expect(bench.quarantined, isEmpty);
        expect(back.noteOf(peerA).history.single.outcome, 'fromTheFuture');
      },
    );
  });

  group('the grouped write (plan, 500 ms)', () {
    test('the default delay is 500 ms', () {
      expect(Limits.peerNotesWriteDelay, const Duration(milliseconds: 500));
    });

    test('a change is not written at once but after the delay', () async {
      final notes = bench.notes(writeDelay: const Duration(milliseconds: 200));

      notes.setAlias(peerA, 'Casa');
      await Future<void>.delayed(const Duration(milliseconds: 60));

      expect(bench.file.existsSync(), isFalse);
      await waitFor(() => bench.file.existsSync());
      expect(bench.file.readAsStringSync(), contains('Casa'));
    });

    test('a burst of changes is one single write', () async {
      final notes = bench.notes(writeDelay: const Duration(milliseconds: 80));
      bench.blockWrites();

      final failures = await failuresDuring(notes, () async {
        notes.setAlias(peerA, 'Uno');
        notes.addRecent(peerA, place('docs'));
        notes.appendHistory(peerA, historyEntry('a'));
        notes.setAlias(peerA, 'Dos');
      });

      expect(failures, 1);
    });

    test('changes that keep coming do not postpone the write', () async {
      final notes = bench.notes(writeDelay: const Duration(milliseconds: 150));
      final watch = Stopwatch()..start();

      while (!bench.file.existsSync()) {
        notes.setAlias(peerA, 'v${watch.elapsedMilliseconds}');
        await Future<void>.delayed(const Duration(milliseconds: 20));
        if (watch.elapsed > const Duration(seconds: 3)) {
          fail('the write was postponed for ever');
        }
      }

      expect(watch.elapsed, lessThan(const Duration(seconds: 2)));
    });

    test(
      'flush writes what is pending, without waiting for the delay',
      () async {
        final notes = bench.notes();
        notes.setAlias(peerA, 'Casa');

        await notes.flush();

        expect(bench.file.readAsStringSync(), contains('Casa'));
      },
    );

    test(
      'flush cancels the pending timer: nothing is written after it',
      () async {
        final notes = bench.notes(writeDelay: const Duration(milliseconds: 80));
        notes.setAlias(peerA, 'Casa');
        await notes.flush();
        bench.file.deleteSync();

        await Future<void>.delayed(const Duration(milliseconds: 200));

        expect(bench.file.existsSync(), isFalse);
      },
    );

    test('flush with nothing pending writes nothing', () async {
      final notes = bench.notes();

      await notes.flush();

      expect(bench.file.existsSync(), isFalse);
    });

    test('flush waits for a write that is already running', () async {
      final notes = bench.notes(writeDelay: Duration.zero);
      notes.setAlias(peerA, 'Casa');
      await Future<void>.delayed(Duration.zero);
      await notes.flush();

      expect(bench.file.readAsStringSync(), contains('Casa'));
    });

    test('a change made after a flush is written later on its own', () async {
      final notes = bench.notes(writeDelay: const Duration(milliseconds: 50));
      notes.setAlias(peerA, 'Uno');
      await notes.flush();

      notes.setAlias(peerA, 'Dos');
      await waitFor(() => readText(bench.file).contains('Dos'));
    });

    test('forget writes at once even with a delay of one hour', () async {
      final notes = bench.notes();
      notes.setAlias(peerA, 'Casa');
      notes.setAlias(peerB, 'Sigue');
      await notes.flush();

      notes.forget(peerA);

      expect(notes.noteOf(peerA).isEmpty, isTrue);
      await waitFor(() => !readText(bench.file).contains(peerA));
      expect(bench.file.readAsStringSync(), contains(peerB));
    });

    test(
      'forget in the middle of a pending write does not wait for it',
      () async {
        final notes = bench.notes();
        notes.setAlias(peerA, 'Casa');
        await notes.flush();
        notes.setAlias(peerB, 'Pendiente');

        notes.forget(peerA);

        await waitFor(() => !readText(bench.file).contains(peerA));
        expect(bench.file.readAsStringSync(), contains('Pendiente'));
      },
    );

    test('forget of a peer that was only in memory leaves no trace', () async {
      final notes = bench.notes(writeDelay: const Duration(milliseconds: 30));
      notes.setAlias(peerA, 'Casa');

      notes.forget(peerA);
      await Future<void>.delayed(const Duration(milliseconds: 120));

      if (bench.file.existsSync()) {
        expect(bench.file.readAsStringSync(), isNot(contains(peerA)));
      }
    });

    test('forget of a peer without notes neither writes nor emits', () async {
      final notes = bench.notes();
      var changes = 0;
      final subscription = notes.changes.listen((_) => changes++);

      notes.forget(peerA);
      await Future<void>.delayed(const Duration(milliseconds: 40));

      await subscription.cancel();
      expect(changes, 0);
      expect(bench.file.existsSync(), isFalse);
    });

    test(
      'forget is applied in memory and emits before it is written',
      () async {
        final notes = bench.notes();
        notes.setAlias(peerA, 'Casa');
        await notes.flush();
        var changes = 0;
        final subscription = notes.changes.listen((_) => changes++);

        notes.forget(peerA);

        expect(notes.knownPeers, isEmpty);
        await Future<void>.delayed(Duration.zero);
        await subscription.cancel();
        expect(changes, 1);
      },
    );

    test('a forgotten peer is empty after the reload too', () async {
      final notes = bench.notes();
      notes.setAlias(peerA, 'Casa');
      notes.addFavorite(peerA, place('docs'));
      notes.addRecent(peerA, place('docs'));
      notes.appendHistory(peerA, historyEntry('a'));
      await notes.flush();
      notes.forget(peerA);
      await notes.flush();

      final back = await bench.reopen();

      expect(back.noteOf(peerA).isEmpty, isTrue);
    });

    test(
      'order is respected: two quick writes end with the latest data',
      () async {
        final notes = bench.notes(writeDelay: Duration.zero);
        for (var i = 0; i < 20; i++) {
          notes.setAlias(peerA, 'v$i');
          await Future<void>.delayed(Duration.zero);
        }
        await notes.flush();

        expect(
          (jsonDecode(bench.file.readAsStringSync())
              as Map<String, Object?>)['peers'],
          [containsPair('alias', 'v19')],
        );
      },
    );
  });

  group('a write that fails (RF-406)', () {
    test('emits saveFailures and keeps the data in memory', () async {
      final notes = bench.notes();
      bench.blockWrites();

      final failures = await failuresDuring(notes, () async {
        notes.setAlias(peerA, 'Casa');
        await notes.flush();
      });

      expect(failures, 1);
      expect(notes.noteOf(peerA).alias, 'Casa');
    });

    test('flush does not throw when the write fails', () async {
      final notes = bench.notes();
      bench.blockWrites();
      notes.setAlias(peerA, 'Casa');

      await expectLater(notes.flush(), completes);
    });

    test('forget that cannot be written stays forgotten in memory', () async {
      final notes = bench.notes();
      notes.setAlias(peerA, 'Casa');
      bench.blockWrites();

      notes.forget(peerA);
      await notes.flush();

      expect(notes.noteOf(peerA).isEmpty, isTrue);
    });

    test(
      'once the file is writable, the next change saves everything',
      () async {
        final notes = bench.notes();
        bench.blockWrites();
        notes.setAlias(peerA, 'Uno');
        await notes.flush();
        bench.unblockWrites();

        notes.setAlias(peerB, 'Dos');
        await notes.flush();

        final back = await bench.reopen();
        expect(back.noteOf(peerA).alias, 'Uno');
        expect(back.noteOf(peerB).alias, 'Dos');
      },
    );

    test('a failed write does not retry by itself', () async {
      final notes = bench.notes(writeDelay: const Duration(milliseconds: 20));
      bench.blockWrites();

      final failures = await failuresDuring(notes, () async {
        notes.setAlias(peerA, 'Casa');
        await Future<void>.delayed(const Duration(milliseconds: 200));
      });

      expect(failures, 1);
    });
  });
}
