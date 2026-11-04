@TestOn('windows')
library;

import 'dart:async';
import 'dart:io';

import 'package:nexus_bridges_core/src/browse/browse.dart';
import 'package:nexus_bridges_core/src/pairing/pairing.dart' show PeerRelation;
import 'package:nexus_bridges_core/src/protocol/protocol.dart';
import 'package:nexus_bridges_core/src/server/server.dart';
import 'package:nexus_bridges_core/src/transfer/platform.dart' show VolumeFacts;
import 'package:nexus_bridges_core/src/transfer/transfer.dart'
    show ForbiddenFolders, isValidFileName, samePath, tempFolderName;
import 'package:test/test.dart';

import '../server/api_server_harness.dart' show loopbackInterface;
import '../node/pairing_nodes_harness.dart' show pairedEntryFor;
import 'share_admission_support.dart';
import 'share_fs_support.dart' show junction;

final RegExp hex32 = RegExp(r'^[0-9a-f]{32}$');

Matcher refusedWith(ShareRefusal reason) =>
    isA<ShareRefused>().having((r) => r.reason, 'reason', reason);

Matcher addedSaved(bool saved) =>
    isA<ShareAdded>().having((a) => a.saved, 'saved', saved);

String? powershell(String command) {
  final ran = Process.runSync('powershell', [
    '-NoProfile',
    '-NonInteractive',
    '-Command',
    command,
  ], workingDirectory: Directory.systemTemp.path);
  if (ran.exitCode != 0) return null;
  final text = (ran.stdout as String).trim();
  return text.isEmpty ? null : text;
}

final class ReadOnlyShareFileSystem implements ShareBrowseFileSystem {
  final List<String> calls = [];

  @override
  Future<ForbiddenFolders?> forbiddenFolders() async {
    calls.add('forbiddenFolders');
    return const ForbiddenFolders(trees: [], exact: []);
  }

  @override
  Future<String?> profilePath() async {
    calls.add('profilePath');
    return null;
  }

  @override
  Future<LevelZeroFacts> levelZero(
    List<ShareRecord> roots,
    List<(ShareRecord, List<String>)> checks, {
    required Duration budget,
  }) async {
    calls.add('levelZero');
    return LevelZeroFacts(
      available: List.filled(roots.length, true),
      checks: List.filled(checks.length, true),
    );
  }

  @override
  Future<FolderListing> listFolders(
    ShareRecord root,
    List<String> path, {
    required Duration cap,
    required int max,
  }) async {
    calls.add('listFolders');
    return const FolderListed(['sub'], more: false, partial: false);
  }
}

void main() {
  group('E710 folders that may not be added (RF-402) [SEG]', () {
    test('E710 system, data, admin, network, temp, too long and deleted '
        'folders each give their reason and nothing is added', () async {
      final place = await admissionPlace(realSystemFolders: true);
      final system = await place.platform.systemFolders();
      final docs = place.folder('docs');
      final temp = place.folder('docs\\$tempFolderName\\dentro');
      junction('${place.base}\\ventanas', r'C:\Windows');
      final deleted = place.folder('borrada');
      Directory(deleted).deleteSync();
      final tooLong = longFolder(place.base, 237);
      place.fs.simulated[r'Z:\fotos'] = probeOf(
        r'Z:\fotos',
        drive: null,
        remote: true,
      );
      place.fs.simulated[r'R:\ram'] = probeOf(r'R:\ram', drive: null);

      final cases = <(String, ShareRefusal)>[
        (r'C:\', ShareRefusal.forbidden),
        (r'C:\Windows', ShareRefusal.forbidden),
        (r'C:\Windows\System32', ShareRefusal.forbidden),
        (place.dataDir, ShareRefusal.appData),
        (r'\\localhost\C$\Users', ShareRefusal.adminShare),
        (r'\\localhost\ADMIN$', ShareRefusal.adminShare),
        (r'\\localhost\recurso', ShareRefusal.networkDrive),
        (r'Z:\fotos', ShareRefusal.networkDrive),
        (r'R:\ram', ShareRefusal.unknownDrive),
        ('${place.base}\\ventanas', ShareRefusal.forbidden),
        ('$docs\\$tempFolderName', ShareRefusal.tempFolder),
        (temp, ShareRefusal.tempFolder),
        (tooLong, ShareRefusal.tooLong),
        (deleted, ShareRefusal.missing),
      ];
      for (final known in [system.programFiles, system.startup]) {
        if (known != null && Directory(known).existsSync()) {
          cases.add((known, ShareRefusal.forbidden));
        }
      }
      final inData = place.folder('data\\dentro');
      cases.add((inData, ShareRefusal.appData));
      for (final (path, reason) in cases) {
        expect(
          await place.service.addPath(mine.fingerprint, path),
          refusedWith(reason),
          reason: path,
        );
      }
      expect(place.service.viewsFor(mine.fingerprint), isEmpty);
      expect(place.service.knownPeers, isEmpty);
      expect(place.sharesFile.existsSync(), isFalse);
      for (final (path, _) in cases) {
        expect(place.logText, isNot(contains(path)));
      }
      expect(place.logs, contains('shares add refused forbidden'));
    });

    test('E710 a removable drive is added, a folder of exactly 236 units is '
        'added and an unreadable system list fails closed', () async {
      final place = await admissionPlace();
      place.fs.simulated[r'E:\juegos\mods'] = probeOf(
        r'E:\juegos\mods',
        volumeId: 'exFAT-1a2b3c4d',
        drive: DriveKind.removable,
      );
      expect(
        await place.service.addPath(mine.fingerprint, r'E:\juegos\mods'),
        addedSaved(true),
      );
      final exact = longFolder(place.base, 236);
      expect(
        await place.service.addPath(mine.fingerprint, exact),
        addedSaved(true),
      );
      final views = place.service.viewsFor(mine.fingerprint);
      expect(views.map((v) => v.path), [r'E:\juegos\mods', exact]);
      expect(views.first.drive, DriveKind.removable);
      expect(views.first.label, 'mods');
      expect(views.last.drive, DriveKind.fixed);

      place.fs.forbiddenFails = true;
      expect(
        await place.service.addPath(mine.fingerprint, place.folder('otra')),
        refusedWith(ShareRefusal.unknownDrive),
      );
      place.fs.forbiddenFails = false;
      place.fs.probeThrows = true;
      expect(
        await place.service.addPath(mine.fingerprint, place.folder('otra')),
        refusedWith(ShareRefusal.unknownDrive),
      );
      place.fs.probeThrows = false;
      expect(place.service.viewsFor(mine.fingerprint), hasLength(2));
    });

    test('E710 a mapped drive reported remote by the volume is refused '
        'as a network drive', () async {
      final place = await admissionPlace();
      final folder = place.folder('mapeada');
      place.platform.adjustFacts = (path, facts) => facts == null
          ? null
          : VolumeFacts(
              volumeId: facts.volumeId,
              supportsNamedStreams: facts.supportsNamedStreams,
              isRemote: true,
            );
      expect(
        await place.service.addPath(mine.fingerprint, folder),
        refusedWith(ShareRefusal.networkDrive),
      );
      expect(place.service.viewsFor(mine.fingerprint), isEmpty);
    });
  });

  group('E711 cloud and unmarked folders ask first (RF-403)', () {
    test('E711 a cloud folder asks, confirm adds it once', () async {
      final place = await admissionPlace();
      final cloud = place.folder('OneDrive\\docs');
      place.platform.cloudFor = (path) => samePath(path, cloud);
      final asked = await place.service.addPath(mine.fingerprint, cloud);
      expect(asked, isA<ShareNeedsConfirmation>());
      final pending = asked as ShareNeedsConfirmation;
      expect(pending.pendingId, matches(hex32));
      expect(pending.cloud, isTrue);
      expect(pending.withoutMark, isFalse);
      expect(pending.path, cloud);
      expect(place.service.viewsFor(mine.fingerprint), isEmpty);
      expect(
        await place.service.confirm(mine.fingerprint, pending.pendingId),
        addedSaved(true),
      );
      expect(place.service.viewsFor(mine.fingerprint).single.path, cloud);
      expect(
        await place.service.confirm(mine.fingerprint, pending.pendingId),
        refusedWith(ShareRefusal.missing),
      );
      expect(place.service.viewsFor(mine.fingerprint), hasLength(1));
    });

    test(
      'E711 a drive without the mark asks and dropPending forgets it',
      () async {
        final place = await admissionPlace();
        place.platform.noMarkSupport = true;
        final folder = place.folder('fat');
        final asked = await place.service.addPath(
          mine.fingerprint,
          folder,
        ) as ShareNeedsConfirmation;
        expect(asked.withoutMark, isTrue);
        expect(asked.cloud, isFalse);
        place.service.dropPending(asked.pendingId);
        expect(
          await place.service.confirm(mine.fingerprint, asked.pendingId),
          refusedWith(ShareRefusal.missing),
        );
        expect(place.service.viewsFor(mine.fingerprint), isEmpty);
        expect(place.sharesFile.existsSync(), isFalse);
      },
    );

    test('E711 a pending confirmation expires at 60 s on the injected '
        'clock', () async {
      final place = await admissionPlace();
      place.platform.noMarkSupport = true;
      final late = place.folder('tarde');
      final inTime = place.folder('atiempo');
      final first = await place.service.addPath(
        mine.fingerprint,
        late,
      ) as ShareNeedsConfirmation;
      place.now += Limits.pendingShareTimeout;
      expect(
        await place.service.confirm(mine.fingerprint, first.pendingId),
        refusedWith(ShareRefusal.missing),
      );
      final second = await place.service.addPath(
        mine.fingerprint,
        inTime,
      ) as ShareNeedsConfirmation;
      place.now += Limits.pendingShareTimeout - const Duration(milliseconds: 1);
      expect(
        await place.service.confirm(mine.fingerprint, second.pendingId),
        addedSaved(true),
      );
      expect(place.service.viewsFor(mine.fingerprint).single.path, inTime);
      expect(Limits.pendingShareTimeout, const Duration(seconds: 60));
    });

    test('E711 a pending of another fingerprint does not count and stays '
        'for its owner', () async {
      final place = await admissionPlace();
      place.platform.noMarkSupport = true;
      final folder = place.folder('suya');
      final asked = await place.service.addPath(
        mine.fingerprint,
        folder,
      ) as ShareNeedsConfirmation;
      expect(
        await place.service.confirm(other.fingerprint, asked.pendingId),
        refusedWith(ShareRefusal.missing),
      );
      expect(place.service.viewsFor(other.fingerprint), isEmpty);
      expect(
        await place.service.confirm(mine.fingerprint, asked.pendingId),
        addedSaved(true),
      );
    });

    test('E711 confirm repeats the admission: a folder deleted meanwhile '
        'gives missing', () async {
      final place = await admissionPlace();
      place.platform.noMarkSupport = true;
      final folder = place.folder('fugaz');
      final asked = await place.service.addPath(
        mine.fingerprint,
        folder,
      ) as ShareNeedsConfirmation;
      Directory(folder).deleteSync();
      expect(
        await place.service.confirm(mine.fingerprint, asked.pendingId),
        refusedWith(ShareRefusal.missing),
      );
      expect(place.service.viewsFor(mine.fingerprint), isEmpty);
    });

    test('E711 at most 32 pendings: the oldest is dropped', () async {
      final place = await admissionPlace();
      place.platform.noMarkSupport = true;
      final folder = place.folder('muchas');
      final ids = <String>[];
      for (var i = 0; i < 33; i++) {
        final asked = await place.service.addPath(
          mine.fingerprint,
          folder,
        ) as ShareNeedsConfirmation;
        ids.add(asked.pendingId);
      }
      expect(ids.toSet(), hasLength(33));
      expect(
        await place.service.confirm(mine.fingerprint, ids.first),
        refusedWith(ShareRefusal.missing),
      );
      expect(
        await place.service.confirm(mine.fingerprint, ids[1]),
        addedSaved(true),
      );
      expect(
        await place.service.confirm(mine.fingerprint, ids.last),
        refusedWith(ShareRefusal.alreadyAdded),
      );
    });

    test('E711 forget drops the pendings of that peer', () async {
      final place = await admissionPlace();
      final kept = place.folder('kept');
      expect(
        await place.service.addPath(mine.fingerprint, kept),
        addedSaved(true),
      );
      place.platform.noMarkSupport = true;
      final asked = await place.service.addPath(
        mine.fingerprint,
        place.folder('p'),
      ) as ShareNeedsConfirmation;
      expect(await place.service.forget(mine.fingerprint), isTrue);
      expect(
        await place.service.confirm(mine.fingerprint, asked.pendingId),
        refusedWith(ShareRefusal.missing),
      );
      expect(place.service.viewsFor(mine.fingerprint), isEmpty);
    });
  });

  group('Review fixes on the share service', () {
    test('B-menor addedAt comes from the injected clock', () async {
      final place = await admissionPlace();
      expect(
        await place.service.addPath(mine.fingerprint, place.folder('uno')),
        addedSaved(true),
      );
      place.wall = DateTime.utc(2027, 1, 2, 3, 4, 5);
      expect(
        await place.service.addPath(mine.fingerprint, place.folder('dos')),
        addedSaved(true),
      );
      expect(place.service.rootsFor(mine.fingerprint).map((r) => r.addedAt), [
        DateTime.utc(2026, 11, 3, 10),
        DateTime.utc(2027, 1, 2, 3, 4, 5),
      ]);
      expect(await place.reopen(), SharesLoadResult.loaded);
      expect(place.service.rootsFor(mine.fingerprint).map((r) => r.addedAt), [
        DateTime.utc(2026, 11, 3, 10),
        DateTime.utc(2027, 1, 2, 3, 4, 5),
      ]);
    });

    test('B-menor forget drops the pendings of a peer that has no roots '
        'yet', () async {
      final place = await admissionPlace();
      place.platform.noMarkSupport = true;
      final asked = await place.service.addPath(
        mine.fingerprint,
        place.folder('p'),
      ) as ShareNeedsConfirmation;
      expect(place.service.rootsFor(mine.fingerprint), isEmpty);
      expect(await place.service.forget(mine.fingerprint), isTrue);
      expect(
        await place.service.confirm(mine.fingerprint, asked.pendingId),
        refusedWith(ShareRefusal.missing),
      );
      expect(place.service.viewsFor(mine.fingerprint), isEmpty);
      expect(place.sharesFile.existsSync(), isFalse);
    });
  });

  group('E716 limits and labels (RF-400, RF-402)', () {
    test('E716 the 17th root is full', () async {
      final place = await admissionPlace();
      for (var i = 0; i < Limits.maxSharesPerPeer; i++) {
        expect(
          await place.service.addPath(mine.fingerprint, place.folder('f$i')),
          addedSaved(true),
          reason: 'f$i',
        );
      }
      expect(
        await place.service.addPath(mine.fingerprint, place.folder('f16')),
        refusedWith(ShareRefusal.full),
      );
      expect(place.service.viewsFor(mine.fingerprint), hasLength(16));
      expect(
        await place.service.addPath(other.fingerprint, place.folder('f16')),
        addedSaved(true),
      );
      expect(Limits.maxSharesPerPeer, 16);
    });

    test('E716 the same folder twice, by another case or through a '
        'junction, is alreadyAdded', () async {
      final place = await admissionPlace();
      final docs = place.folder('Docs');
      junction('${place.base}\\atajo', docs);
      expect(
        await place.service.addPath(mine.fingerprint, docs),
        addedSaved(true),
      );
      for (final again in [docs, docs.toUpperCase(), '${place.base}\\atajo']) {
        expect(
          await place.service.addPath(mine.fingerprint, again),
          refusedWith(ShareRefusal.alreadyAdded),
          reason: again,
        );
      }
      expect(
        await place.service.addPath(other.fingerprint, docs),
        addedSaved(true),
      );
    });

    test('E716 an Explorer name is the label, a drive root is X: and a '
        'folder name that is no label is refused', () async {
      final place = await admissionPlace();
      final known = place.folder('Documents');
      place.fs.adjust = (probe) => samePath(probe.realPath, known)
          ? probeOf(
              probe.realPath,
              volumeId: probe.volumeId,
              explorerName: 'Documentos',
            )
          : probe;
      expect(
        await place.service.addPath(mine.fingerprint, known),
        addedSaved(true),
      );
      final view = place.service.viewsFor(mine.fingerprint).single;
      expect(view.label, 'Documentos');
      expect(view.path, known);
      expect(view.home, isFalse);
      expect(
        place.service.grantFor(mine.fingerprint, view.rootId)!.label,
        'Documentos',
      );
      place.fs.simulated[r'E:\'] = probeOf(r'E:\', drive: DriveKind.removable);
      expect(
        await place.service.addPath(mine.fingerprint, r'E:\'),
        addedSaved(true),
      );
      expect(place.service.viewsFor(mine.fingerprint).last.label, 'E:');
      final odd = place.folder('a (b');
      expect(
        await place.service.addPath(mine.fingerprint, odd),
        refusedWith(ShareRefusal.forbidden),
      );
    });

    test(
      'E716 a record keeps the real path, the volume and a random id',
      () async {
        final place = await admissionPlace();
        final docs = place.folder('docs');
        junction('${place.base}\\via', docs);
        expect(
          await place.service.addPath(mine.fingerprint, '${place.base}\\via'),
          addedSaved(true),
        );
        final view = place.service.viewsFor(mine.fingerprint).single;
        expect(view.path, docs);
        expect(view.rootId, matches(hex32));
        expect(await place.reopen(), SharesLoadResult.loaded);
        final again = place.service.viewsFor(mine.fingerprint).single;
        expect(again.rootId, view.rootId);
        expect(again.path, docs);
        expect(
          place.service.rootsFor(mine.fingerprint).single.volumeId,
          (await place.platform.volumeFacts(docs))!.volumeId,
        );
      },
    );

    test('E716 a peer that is not paired cannot get a root', () async {
      final place = await admissionPlace();
      final stranger = 'F' * 64;
      expect(
        await place.service.addPath(stranger, place.folder('x')),
        refusedWith(ShareRefusal.missing),
      );
      expect(place.service.knownPeers, isEmpty);
    });
  });

  group('G2 saving, removing and forgetting (RF-401, RF-406)', () {
    test('E714 remove is applied in memory first, warns when not saved and '
        'retrySave fixes it', () async {
      final place = await admissionPlace();
      for (final name in ['a', 'b']) {
        expect(
          await place.service.addPath(mine.fingerprint, place.folder(name)),
          addedSaved(true),
        );
      }
      final [first, second] = place.service.viewsFor(mine.fingerprint);
      final statuses = <bool>[];
      final status = place.service.saveStatusChanges.listen(
        (_) => statuses.add(place.service.hasUnsavedRemoval),
      );
      addTearDown(status.cancel);
      var changes = 0;
      final changed = place.service.changes.listen((_) => changes++);
      addTearDown(changed.cancel);

      place.breakStore();
      final removing = place.service.remove(mine.fingerprint, first.rootId);
      expect(place.service.rootFor(mine.fingerprint, first.rootId), isNull);
      expect(place.service.grantFor(mine.fingerprint, first.rootId), isNull);
      expect(await removing, isFalse);
      await pumpEventQueue();
      expect(changes, 1);
      expect(place.service.hasUnsavedRemoval, isTrue);
      expect(statuses, [true]);
      expect(await place.service.retrySave(), isFalse);
      expect(place.service.hasUnsavedRemoval, isTrue);

      place.mendStore();
      expect(await place.service.retrySave(), isTrue);
      expect(place.service.hasUnsavedRemoval, isFalse);
      await pumpEventQueue();
      expect(statuses, [true, false]);
      expect(await place.reopen(), SharesLoadResult.loaded);
      expect(place.service.viewsFor(mine.fingerprint).map((v) => v.rootId), [
        second.rootId,
      ]);
    });

    test('E714 an add that is not saved stays for the session and is no '
        'unsaved removal', () async {
      final place = await admissionPlace();
      place.breakStore();
      final folder = place.folder('nueva');
      expect(
        await place.service.addPath(mine.fingerprint, folder),
        addedSaved(false),
      );
      expect(place.service.viewsFor(mine.fingerprint).single.path, folder);
      expect(place.service.hasUnsavedRemoval, isFalse);
    });

    test('E714 a later save that works clears an unsaved removal', () async {
      final place = await admissionPlace();
      final a = place.folder('a');
      expect(
        await place.service.addPath(mine.fingerprint, a),
        addedSaved(true),
      );
      final root = place.service.viewsFor(mine.fingerprint).single.rootId;
      place.breakStore();
      expect(await place.service.remove(mine.fingerprint, root), isFalse);
      expect(place.service.hasUnsavedRemoval, isTrue);
      place.mendStore();
      expect(
        await place.service.addPath(mine.fingerprint, place.folder('b')),
        addedSaved(true),
      );
      expect(place.service.hasUnsavedRemoval, isFalse);
    });

    test('E714 generation counter: a save that started before a second '
        'removal does not clear the risk of that removal', () async {
      final place = await admissionPlace();
      for (final name in ['a', 'b', 'c']) {
        expect(
          await place.service.addPath(mine.fingerprint, place.folder(name)),
          addedSaved(true),
        );
      }
      final [a, b, _] = place.service.viewsFor(mine.fingerprint);
      place.breakStore();
      expect(await place.service.remove(mine.fingerprint, a.rootId), isFalse);
      expect(place.service.hasUnsavedRemoval, isTrue);

      place.mendStore();
      final firstSave = place.service.retrySave();
      await Future<void>.delayed(Duration.zero);
      final secondSave = place.service.remove(mine.fingerprint, b.rootId);
      expect(await firstSave, isTrue);
      final written = place.sharesFile.readAsStringSync();
      place.breakStore();
      expect(written, contains(b.rootId));
      expect(written, isNot(contains(a.rootId)));
      expect(await secondSave, isFalse);
      expect(place.service.hasUnsavedRemoval, isTrue);

      place.mendStore();
      expect(await place.service.retrySave(), isTrue);
      expect(place.service.hasUnsavedRemoval, isFalse);
      expect(await place.reopen(), SharesLoadResult.loaded);
      expect(place.service.viewsFor(mine.fingerprint), hasLength(1));
    });

    test(
      'G2 remove of an unknown root changes nothing and answers true',
      () async {
        final place = await admissionPlace();
        var changes = 0;
        final sub = place.service.changes.listen((_) => changes++);
        addTearDown(sub.cancel);
        expect(await place.service.remove(mine.fingerprint, 'f' * 32), isTrue);
        await pumpEventQueue();
        expect(changes, 0);
        expect(place.sharesFile.existsSync(), isFalse);
      },
    );

    test('RF-418 forget empties one peer in memory first and keeps the '
        'others', () async {
      final place = await admissionPlace();
      expect(
        await place.service.addPath(mine.fingerprint, place.folder('m')),
        addedSaved(true),
      );
      expect(
        await place.service.addPath(other.fingerprint, place.folder('o')),
        addedSaved(true),
      );
      expect(place.service.knownPeers, {mine.fingerprint, other.fingerprint});
      place.breakStore();
      final forgetting = place.service.forget(mine.fingerprint);
      expect(place.service.viewsFor(mine.fingerprint), isEmpty);
      expect(place.service.rootsFor(mine.fingerprint), isEmpty);
      expect(await forgetting, isFalse);
      expect(place.service.hasUnsavedRemoval, isTrue);
      expect(place.service.knownPeers, {other.fingerprint});
      place.mendStore();
      expect(await place.service.retrySave(), isTrue);
      expect(await place.reopen(), SharesLoadResult.loaded);
      expect(place.service.knownPeers, {other.fingerprint});
      expect(place.logText, contains('shares forget 1'));
      expect(place.logText, isNot(contains(place.base)));
    });

    test('G3 refreshAvailability fills available and a root removed while '
        'it runs stays out', () async {
      final place = await admissionPlace();
      final keep = place.folder('keep');
      final gone = place.folder('gone');
      for (final path in [keep, gone]) {
        expect(
          await place.service.addPath(mine.fingerprint, path),
          addedSaved(true),
        );
      }
      expect(place.service.viewsFor(mine.fingerprint).map((v) => v.available), [
        null,
        null,
      ]);
      Directory(gone).deleteSync();
      final watch = Stopwatch()..start();
      await place.service.refreshAvailability(mine.fingerprint);
      expect(watch.elapsed, lessThan(const Duration(seconds: 3)));
      expect(place.service.viewsFor(mine.fingerprint).map((v) => v.available), [
        true,
        false,
      ]);

      final third = place.folder('third');
      expect(
        await place.service.addPath(mine.fingerprint, third),
        addedSaved(true),
      );
      final thirdId = place.service.viewsFor(mine.fingerprint).last.rootId;
      place.fs.levelZeroGate = Completer<void>();
      final refreshing = place.service.refreshAvailability(mine.fingerprint);
      await pumpEventQueue();
      expect(await place.service.remove(mine.fingerprint, thirdId), isTrue);
      place.fs.levelZeroGate!.complete();
      await refreshing;
      expect(place.service.viewsFor(mine.fingerprint).map((v) => v.available), [
        true,
        false,
      ]);
      await place.service.refreshAvailability(foreign.fingerprint);
    });

    test('G3 a failing check leaves the views as they were', () async {
      final place = await admissionPlace();
      expect(
        await place.service.addPath(mine.fingerprint, place.folder('a')),
        addedSaved(true),
      );
      place.fs.levelZeroAnswer = (_) => throw StateError('disk');
      await place.service.refreshAvailability(mine.fingerprint);
      expect(place.service.viewsFor(mine.fingerprint).single.available, isNull);
      expect(place.logText, contains('shares refresh failed: StateError'));
    });
  });

  group('E712 nothing over the network creates or changes roots (RF-401) '
      '[SEG]', () {
    test('E712 a new store has no roots for anybody', () async {
      final place = await admissionPlace(open: false);
      expect(await place.open(), SharesLoadResult.missing);
      for (final peer in [mine, other, foreign]) {
        expect(place.service.rootsFor(peer.fingerprint), isEmpty);
        expect(place.service.viewsFor(peer.fingerprint), isEmpty);
      }
      expect(place.service.knownPeers, isEmpty);
      expect(place.service.mayBrowse(mine.fingerprint), isTrue);
      expect(place.service.mayBrowse(foreign.fingerprint), isFalse);
      expect(place.sharesFile.existsSync(), isFalse);
    });

    test('E712 the browse server only reads: a read-only file system and the '
        'reader serve every request and the roots file stays the same '
        'byte for byte', () async {
      final place = await admissionPlace();
      expect(
        await place.service.addPath(mine.fingerprint, place.folder('docs')),
        addedSaved(true),
      );
      final before = place.sharesFile.readAsBytesSync();
      final views = place.service.viewsFor(mine.fingerprint);
      final rootId = views.single.rootId;
      final fs = ReadOnlyShareFileSystem();
      final server = BrowseServer(shares: place.service, fileSystem: fs);
      expect(server.routes.map((r) => r.path), [ApiPaths.browse]);
      Future<ApiReply> ask(Object? json) => server.routes.single.handle(
        ApiCall(
          path: ApiPaths.browse,
          clientFingerprint: mine.fingerprint,
          remoteAddress: InternetAddress.loopbackIPv4,
          via: loopbackInterface(),
          json: json,
        ),
      );
      final bodies = <Object?>[
        {'protocol': protocolVersion},
        {
          'protocol': protocolVersion,
          'check': [
            {
              'root': rootId,
              'path': ['sub'],
            },
          ],
        },
        {'protocol': protocolVersion, 'root': rootId, 'path': <Object?>[]},
        {
          'protocol': protocolVersion,
          'root': rootId,
          'path': <Object?>[],
          'add': r'C:\Windows',
        },
        {'protocol': protocolVersion, 'absolutePath': r'C:\Windows'},
        {'protocol': protocolVersion, 'remove': rootId},
      ];
      final statuses = <int>[];
      for (final body in bodies) {
        statuses.add((await ask(body)).status);
      }
      expect(statuses, [200, 200, 200, 400, 400, 400]);
      expect(
        fs.calls.toSet().difference({
          'profilePath',
          'levelZero',
          'listFolders',
          'forbiddenFolders',
        }),
        isEmpty,
      );
      expect(place.service.viewsFor(mine.fingerprint), views);
      expect(place.sharesFile.readAsBytesSync(), before);
    });
  });

  group('WindowsShareFileSystem.probe on real folders', () {
    test('explorerName: Documents and Desktop take the Explorer name through '
        'COM, any other folder has none', () async {
      final fs = WindowsShareFileSystem(dataDirs: const []);
      var checked = 0;
      for (final known in ['MyDocuments', 'Desktop']) {
        final path = powershell("[Environment]::GetFolderPath('$known')");
        if (path == null || !Directory(path).existsSync()) continue;
        final shell = powershell(
          "(New-Object -ComObject Shell.Application).Namespace('$path')"
          '.Self.Name',
        );
        final probe = await fs.probe(path);
        expect(probe, isNotNull, reason: known);
        expect(probe!.home, isFalse);
        if (shell != null && isValidFileName(shell)) {
          expect(probe.explorerName, shell, reason: known);
          checked++;
        }
      }
      if (checked == 0) {
        markTestSkipped(
          'this account has neither Documents nor Desktop as a local folder',
        );
        return;
      }
      final plain = await Directory.systemTemp.createTemp('nexus_t007_com_');
      addTearDown(() => plain.delete(recursive: true));
      final probe = await fs.probe(plain.path);
      expect(probe, isNotNull);
      expect(probe!.explorerName, isNull);
      expect(probe.drive, DriveKind.fixed);
      expect(probe.remote, isFalse);
    });

    test(
      'home: the real profile folder is home with no Explorer name',
      () async {
        final profile = Platform.environment['USERPROFILE'];
        if (profile == null || !Directory(profile).existsSync()) {
          markTestSkipped('USERPROFILE is not set');
          return;
        }
        final fs = WindowsShareFileSystem(dataDirs: const []);
        final real = await fs.profilePath();
        expect(real, isNotNull);
        final probe = await fs.probe(profile);
        expect(probe, isNotNull);
        expect(probe!.home, isTrue);
        expect(probe.explorerName, isNull);
        final below = await Directory.systemTemp.createTemp(
          'nexus_t007_below_',
        );
        addTearDown(() => below.delete(recursive: true));
        expect((await fs.probe(below.path))!.home, isFalse);
      },
    );

    test('a UNC path is remote without a drive kind', () async {
      final fs = WindowsShareFileSystem(dataDirs: const []);
      final probe = await fs.probe(r'\\localhost\C$');
      if (probe == null) {
        markTestSkipped(r'\\localhost\C$ is not reachable on this machine');
        return;
      }
      expect(probe.remote, isTrue);
      expect(probe.drive, isNull);
    });
  });

  group('B-4 forgetting at the paired change, not on the node queue [SEG]', () {
    const settle = Duration(milliseconds: 60);

    test('B-4 a removal forgets the roots and the pendings at once, also of '
        'a peer with no roots', () async {
      final place = await admissionPlace();
      expect(
        await place.service.addPath(mine.fingerprint, place.folder('kept')),
        addedSaved(true),
      );
      place.platform.noMarkSupport = true;
      final askedMine = await place.service.addPath(
        mine.fingerprint,
        place.folder('p'),
      ) as ShareNeedsConfirmation;
      final askedOther = await place.service.addPath(
        other.fingerprint,
        place.folder('q'),
      ) as ShareNeedsConfirmation;
      expect(place.service.knownPeers, {mine.fingerprint});

      await place.paired.remove(mine.fingerprint);
      await place.paired.remove(other.fingerprint);
      await Future<void>.delayed(settle);

      expect(place.service.knownPeers, isEmpty);
      expect(place.service.viewsFor(mine.fingerprint), isEmpty);
      await place.paired.replaceAll([
        pairedEntryFor(mine, name: 'Mine', relation: PeerRelation.mine),
        pairedEntryFor(other, name: 'Other', relation: PeerRelation.mine),
      ]);
      expect(
        await place.service.confirm(mine.fingerprint, askedMine.pendingId),
        refusedWith(ShareRefusal.missing),
      );
      expect(
        await place.service.confirm(other.fingerprint, askedOther.pendingId),
        refusedWith(ShareRefusal.missing),
      );
      expect(place.service.viewsFor(mine.fingerprint), isEmpty);
    });

    test('B-4 the same fingerprint paired again before the listener runs '
        'still loses its roots', () async {
      final place = await admissionPlace();
      expect(
        await place.service.addPath(mine.fingerprint, place.folder('kept')),
        addedSaved(true),
      );
      await place.paired.replaceAll([
        pairedEntryFor(
          mine,
          name: 'Mine',
          relation: PeerRelation.mine,
          pairedAt: DateTime.utc(2026, 11, 4),
        ),
        pairedEntryFor(other, name: 'Other', relation: PeerRelation.mine),
        pairedEntryFor(
          foreign,
          name: 'Foreign',
          relation: PeerRelation.foreign,
        ),
      ]);
      await Future<void>.delayed(settle);
      expect(place.service.rootsFor(mine.fingerprint), isEmpty);
      expect(place.service.viewsFor(mine.fingerprint), isEmpty);
    });

    test('B-4 a rename or a relation change is not a new pairing: the roots '
        'stay', () async {
      final place = await admissionPlace();
      expect(
        await place.service.addPath(mine.fingerprint, place.folder('kept')),
        addedSaved(true),
      );
      expect(await place.paired.rename(mine.fingerprint, 'Renamed'), isTrue);
      expect(
        await place.paired.setRelation(mine.fingerprint, PeerRelation.foreign),
        isTrue,
      );
      await Future<void>.delayed(settle);
      expect(place.service.rootsFor(mine.fingerprint), isEmpty);
      expect(place.service.viewsFor(mine.fingerprint), hasLength(1));
      expect(
        await place.paired.setRelation(mine.fingerprint, PeerRelation.mine),
        isTrue,
      );
      await Future<void>.delayed(settle);
      expect(place.service.rootsFor(mine.fingerprint), hasLength(1));
    });

    test('B-4 two removals together lose none of the two', () async {
      final place = await admissionPlace();
      for (final peer in [mine, other]) {
        expect(
          await place.service.addPath(
            peer.fingerprint,
            place.folder('d${peer == mine ? 1 : 2}'),
          ),
          addedSaved(true),
        );
      }
      unawaited(place.paired.remove(mine.fingerprint));
      unawaited(place.paired.remove(other.fingerprint));
      await Future<void>.delayed(settle);
      expect(place.service.knownPeers, isEmpty);
    });
  });
}
