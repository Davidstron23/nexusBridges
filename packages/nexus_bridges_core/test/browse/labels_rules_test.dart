@TestOn('windows')
library;

import 'dart:convert';
import 'dart:io';

import 'package:nexus_bridges_core/src/browse/browse.dart';
import 'package:nexus_bridges_core/src/protocol/protocol.dart';
import 'package:nexus_bridges_core/src/server/server.dart';
import 'package:nexus_bridges_core/src/transfer/transfer.dart'
    show isValidFolderName;
import 'package:test/test.dart';

import '../server/api_server_harness.dart' show loopbackInterface;
import 'share_admission_support.dart';

Future<ApiReply> askRoots(BrowseServer server, String fingerprint) =>
    server.routes.single.handle(
      ApiCall(
        path: ApiPaths.browse,
        clientFingerprint: fingerprint,
        remoteAddress: InternetAddress.loopbackIPv4,
        via: loopbackInterface(),
        json: {'protocol': protocolVersion},
      ),
    );

void main() {
  group('E702 isValidFolderName (RF-410, RF-414, RF-424)', () {
    test('E702 the traps are not folder names', () {
      for (final bad in [
        'CON',
        'x.',
        'x ',
        'COM\u{B9}',
        'a\u{202E}gpj',
        'desktop.ini',
        'Desktop.INI',
        'x.{3050f4d8-98B5-11CF-BB82-00AA00BDCE0B}',
        '.nexusbridges-incoming',
        '.NexusBridges-Incoming',
        '~nexusbridges-abc',
        'acceso.lnk',
        'a' * 256,
        '',
        '.',
        '..',
      ]) {
        expect(
          isValidFolderName(bad),
          isFalse,
          reason: bad.codeUnits.toString(),
        );
      }
    });

    test('E702 plain, numbered, accented and emoji names are folder names', () {
      for (final good in [
        'mods',
        'Proyecto (1)',
        'canci\u{F3}n',
        'A\u{F1}o 2024',
        'familia \u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467}',
        '.git',
        'a' * 255,
      ]) {
        expect(isValidFolderName(good), isTrue, reason: good);
      }
    });
  });

  group('E706 root labels with the balanced parentheses rule (RF-409)', () {
    test('E706 unbalanced parentheses, bidi and 521 units are refused', () {
      for (final bad in [
        'a (b',
        'a b)',
        ')(',
        'dev (x))',
        'dev ((x)',
        'a\u{202E}b',
        'dev (a\u{202E}b)',
        'a' * 521,
        '',
      ]) {
        expect(
          isValidRootLabel(bad),
          isFalse,
          reason: bad.codeUnits.take(12).toString(),
        );
      }
    });

    test('E706 balanced labels and the longest built form are accepted', () {
      for (final good in [
        'Fotos (2020) viaje',
        'dev (personal)',
        'dev (D:)',
        'dev (D: 2)',
        'dev (x 3)',
        'E:',
        '${'a' * 255} (${'b' * 255})',
      ]) {
        expect(isValidRootLabel(good), isTrue, reason: good);
      }
    });

    test('E706 a parent that is not a valid label falls back to the drive '
        'letter', () {
      expect(parentLabelOf(r'C:\a (b\dev', profilePath: null), 'C:');
      expect(
        parentLabelOf(r'C:\Fotos (2020)\dev', profilePath: null),
        'Fotos (2020)',
      );
      expect(parentLabelOf(r'e:\personal\dev', profilePath: null), 'personal');
    });

    test(
      'E706 dev in D: is dev (D:) and an Explorer name is kept as it is',
      () {
        final names = visibleRootNames([
          (label: 'dev', home: false, parentLabel: 'personal'),
          (label: 'dev', home: false, parentLabel: 'D:'),
          (label: 'Documentos', home: false, parentLabel: 'C:'),
        ]);
        expect(names, ['dev (personal)', 'dev (D:)', 'Documentos']);
      },
    );

    test('E706 every built name passes isValidRootLabel and no two share a '
        'folderKey, also when a unique label looks like a built one', () {
      final cases = [
        [
          (label: 'dev', home: false, parentLabel: 'x'),
          (label: 'dev', home: false, parentLabel: 'x'),
          (label: 'dev (x)', home: false, parentLabel: 'y'),
        ],
        [
          (label: 'Dev', home: false, parentLabel: 'D:'),
          (label: 'dev', home: false, parentLabel: 'D:'),
          (label: 'DEV', home: false, parentLabel: 'D:'),
          (label: '', home: true, parentLabel: 'C:'),
        ],
        [
          (label: 'Fotos (2020)', home: false, parentLabel: 'a'),
          (label: 'Fotos (2020)', home: false, parentLabel: 'b'),
        ],
      ];
      for (final roots in cases) {
        final names = visibleRootNames(roots);
        expect(names, hasLength(roots.length));
        final keys = <String>{};
        for (var i = 0; i < roots.length; i++) {
          if (roots[i].home) {
            expect(names[i], '');
            continue;
          }
          expect(isValidRootLabel(names[i]), isTrue, reason: names[i]);
          expect(keys.add(folderKey(names[i])), isTrue, reason: '$names');
        }
      }
    });
  });

  group('E709 the profile folder never names a root (punto 8) [SEG]', () {
    final user = Platform.environment['USERNAME'] ?? 'Usuario';

    test('E709 with the profile at <tmp>\\$user the home root has no name, '
        'roots under it take the drive letter and the answer never carries '
        'the user name', () async {
      final scratch = await admissionPlace(open: false);
      final profile = scratch.folder(user);
      final place = scratch;
      place.fs.profile = profile;
      await place.open();
      final drive = '${profile[0].toUpperCase()}:';
      final dev = place.folder('$user\\dev');
      place.fs.simulated[r'D:\dev'] = probeOf(r'D:\dev');

      for (final path in [profile, dev, r'D:\dev']) {
        expect(
          await place.service.addPath(mine.fingerprint, path),
          isA<ShareAdded>(),
          reason: path,
        );
      }
      final views = place.service.viewsFor(mine.fingerprint);
      expect(views.map((v) => v.home), [true, false, false]);
      expect(views.map((v) => v.label), ['', 'dev', 'dev']);

      final server = BrowseServer(shares: place.service, fileSystem: place.fs);
      final reply = await askRoots(server, mine.fingerprint);
      expect(reply.status, 200);
      final roots = (reply.json['roots']! as List).cast<Map<String, Object?>>();
      expect(roots.map((r) => r['name']), ['', 'dev ($drive)', 'dev (D:)']);
      expect(roots.map((r) => r['home']), [true, false, false]);
      expect(roots.first['available'], isTrue);
      expect(roots[1]['available'], isTrue);
      final text = jsonEncode(reply.json);
      expect(text.toUpperCase(), isNot(contains(user.toUpperCase())));
      expect(text, isNot(contains(r'\\')));
      expect(parseRootsResponse(reply.json, checks: 0), isNotNull);
      expect(
        place.service
            .grantFor(mine.fingerprint, roots[1]['id']! as String)!
            .label,
        'dev ($drive)',
      );
    });

    test('E709 a folder named like the user that is not the profile keeps '
        'its own name and takes the drive letter when repeated', () async {
      final scratch = await admissionPlace(open: false);
      final profile = scratch.folder(user);
      scratch.fs.profile = profile;
      final place = scratch;
      await place.open();
      final drive = '${profile[0].toUpperCase()}:';
      final inner = place.folder('$user\\$user');
      expect(
        await place.service.addPath(mine.fingerprint, inner),
        isA<ShareAdded>(),
      );
      final server = BrowseServer(shares: place.service, fileSystem: place.fs);
      var roots =
          ((await askRoots(server, mine.fingerprint)).json['roots']! as List)
              .cast<Map<String, Object?>>();
      expect(roots.single['name'], user);
      expect(roots.single['home'], isFalse);

      final elsewhere = place.folder('otra\\$user');
      expect(
        await place.service.addPath(mine.fingerprint, elsewhere),
        isA<ShareAdded>(),
      );
      roots =
          ((await askRoots(server, mine.fingerprint)).json['roots']! as List)
              .cast<Map<String, Object?>>();
      expect(roots.map((r) => r['name']), ['$user ($drive)', '$user (otra)']);
    });
  });
}
