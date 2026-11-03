import 'dart:async';
import 'dart:io';

import 'package:nexus_bridges_core/src/browse/browse.dart';
import 'package:nexus_bridges_core/src/identity/identity.dart';
import 'package:nexus_bridges_core/src/pairing/pairing.dart';
import 'package:nexus_bridges_core/src/protocol/protocol.dart' show Limits;
import 'package:nexus_bridges_core/src/storage/storage.dart';
import 'package:nexus_bridges_core/src/transfer/transfer.dart'
    show
        DestinationChanged,
        DestinationLabel,
        DestinationRequest,
        ForbiddenFolders,
        FreeNameMove,
        MoveFailed,
        MovedTo,
        SharedRefusal,
        SharedRefused,
        SharedResolved;
import 'package:test/test.dart';

import '../node/pairing_nodes_harness.dart' show pairedEntryFor;

String hexId(int n) => n.toRadixString(16).padLeft(32, '0');

final DeviceIdentity self = DeviceIdentity.generate();
final DeviceIdentity mine = DeviceIdentity.generate();
final DeviceIdentity other = DeviceIdentity.generate();
final DeviceIdentity foreign = DeviceIdentity.generate();

ShareRecord record(
  int id,
  String path, {
  String label = 'docs',
  bool home = false,
}) => ShareRecord(
  id: hexId(id),
  path: path,
  volumeId: 'NTFS-2692abcd',
  label: home ? '' : label,
  home: home,
  drive: DriveKind.fixed,
  addedAt: DateTime.utc(2026, 11, 1),
);

final class FakeShareFileSystem implements ShareWriteFileSystem {
  final List<String> events = [];
  final Set<ChainHandles> released = {};
  final List<ChainHandles> opened = [];
  final List<String> misuse = [];
  Duration openDelay = Duration.zero;
  Completer<void>? prepareGate;
  ChainResult Function()? nextOpen;
  Object? throwOn;
  bool prepareResult = true;
  FreeNameMove moveResult = const MovedTo('informe.txt');

  void _use(String what, ChainHandles chain) {
    if (released.contains(chain)) misuse.add(what);
    if (throwOn == what) throw StateError('fake failure in $what');
  }

  @override
  Future<ForbiddenFolders?> forbiddenFolders() async =>
      const ForbiddenFolders(trees: [], exact: []);

  @override
  Future<String?> profilePath() async => r'C:\Users\Bob';

  @override
  Future<LevelZeroFacts> levelZero(
    List<ShareRecord> roots,
    List<(ShareRecord, List<String>)> checks, {
    required Duration budget,
  }) async => LevelZeroFacts(
    available: List.filled(roots.length, true),
    checks: List.filled(checks.length, true),
  );

  @override
  Future<FolderListing> listFolders(
    ShareRecord root,
    List<String> path, {
    required Duration cap,
    required int max,
  }) async => const FolderListed([], more: false, partial: false);

  @override
  Future<bool> exists(String path) async => true;

  @override
  Future<ShareProbe?> probe(String path) async => null;

  @override
  Future<ChainResult> openChain(
    ShareRecord root,
    List<String> path, {
    String? newFolder,
  }) async {
    events.add(
      'open ${path.join('/')}${newFolder == null ? '' : '+$newFolder'}',
    );
    if (throwOn == 'open') throw StateError('fake failure in open');
    if (openDelay > Duration.zero) await Future<void>.delayed(openDelay);
    final next = nextOpen;
    if (next != null) return next();
    final chain = ChainHandles(
      folderPath: [root.path, ...path, ?newFolder].join(r'\'),
      volumeId: root.volumeId,
      handles: [11, 12],
    );
    opened.add(chain);
    return ChainOpened(chain);
  }

  @override
  Future<bool> prepareChain(ChainHandles chain) async {
    _use('prepare', chain);
    events.add('prepare start');
    final gate = prepareGate;
    if (gate != null) await gate.future;
    events.add('prepare end');
    return prepareResult;
  }

  @override
  Future<FreeNameMove> recheckAndMove(
    ChainHandles chain, {
    required String tempName,
    required bool isFolder,
    required String name,
    int? maxNameUnits,
  }) async {
    _use('move', chain);
    events.add('move');
    return moveResult;
  }

  @override
  Future<void> releaseChain(ChainHandles chain, {required bool saved}) async {
    _use('release', chain);
    events.add('release $saved');
    released.add(chain);
  }
}

final class ServicePlace {
  ServicePlace(this.service, this.fs, this.logs, this.paired);

  final ShareService service;
  final FakeShareFileSystem fs;
  final List<String> logs;
  final PairedDevicesStore paired;
}

Future<ServicePlace> servicePlace({
  Map<String, List<ShareRecord>>? shares,
}) async {
  final dir = await Directory.systemTemp.createTemp('nexus_t007_service_');
  addTearDown(() async {
    if (dir.existsSync()) await dir.delete(recursive: true);
  });
  final paired = PairedDevicesStore(
    JsonFileStore(File('${dir.path}\\paired.json')),
    ownerFingerprint: self.fingerprint,
  );
  await paired.replaceAll([
    pairedEntryFor(mine, name: 'Mine', relation: PeerRelation.mine),
    pairedEntryFor(other, name: 'Other', relation: PeerRelation.mine),
    pairedEntryFor(foreign, name: 'Foreign', relation: PeerRelation.foreign),
  ]);
  final store = SharesStore(
    JsonFileStore(File('${dir.path}\\shares.json')),
    ownerFingerprint: self.fingerprint,
  );
  expect(
    await store.write(
      shares ??
          {
            mine.fingerprint: [
              record(1, r'C:\datos\docs'),
              record(2, r'C:\Users\Bob', home: true),
              record(3, r'C:\datos\dev', label: 'dev'),
              record(4, r'D:\dev', label: 'dev'),
            ],
            other.fingerprint: [record(5, r'C:\datos\otra', label: 'otra')],
            foreign.fingerprint: [record(6, r'C:\datos\ajena', label: 'ajena')],
          },
    ),
    isTrue,
  );
  final fs = FakeShareFileSystem();
  final logs = <String>[];
  final service = ShareService(
    store: store,
    paired: paired,
    fileSystem: fs,
    dataDirPath: '${dir.path}\\data',
    log: logs.add,
  );
  addTearDown(service.close);
  expect(await service.load(), SharesLoadResult.loaded);
  return ServicePlace(service, fs, logs, paired);
}

DestinationRequest to(int id, List<String> path, {String? newFolder}) =>
    DestinationRequest(rootId: hexId(id), path: path, newFolder: newFolder);

void main() {
  group('G6 grants and reads (RF-401, RF-405, RF-408)', () {
    test('G6 grantFor gives the visible name, home and path units only to '
        'the owner of the root', () async {
      final p = await servicePlace();
      final docs = p.service.grantFor(mine.fingerprint, hexId(1))!;
      expect(docs.rootId, hexId(1));
      expect(docs.label, 'docs');
      expect(docs.home, isFalse);
      expect(docs.pathUnits, r'C:\datos\docs'.length);
      final home = p.service.grantFor(mine.fingerprint, hexId(2))!;
      expect(home.label, '');
      expect(home.home, isTrue);
      expect(
        p.service.grantFor(mine.fingerprint, hexId(3))!.label,
        'dev (datos)',
      );
      expect(p.service.grantFor(mine.fingerprint, hexId(4))!.label, 'dev (D:)');
      expect(p.service.grantFor(mine.fingerprint, hexId(5)), isNull);
      expect(p.service.grantFor(other.fingerprint, hexId(1)), isNull);
      expect(p.service.grantFor(mine.fingerprint, hexId(99)), isNull);
    });

    test('G6 a foreign peer may not browse and has no grant, its roots '
        'stay saved', () async {
      final p = await servicePlace();
      expect(p.service.mayBrowse(foreign.fingerprint), isFalse);
      expect(p.service.rootsFor(foreign.fingerprint), isEmpty);
      expect(p.service.grantFor(foreign.fingerprint, hexId(6)), isNull);
      expect(p.service.viewsFor(foreign.fingerprint).single.rootId, hexId(6));
      expect(p.service.mayBrowse(mine.fingerprint), isTrue);
      expect(p.service.rootsFor(mine.fingerprint), hasLength(4));
    });

    test('G6 marking a peer foreign removes its grants at once', () async {
      final p = await servicePlace();
      expect(
        await p.paired.setRelation(mine.fingerprint, PeerRelation.foreign),
        isTrue,
      );
      expect(p.service.grantFor(mine.fingerprint, hexId(1)), isNull);
      expect(p.service.mayBrowse(mine.fingerprint), isFalse);
    });
  });

  group('G7 resolve (RF-413, RF-414) [SEG]', () {
    test(
      'G6 a root that is not granted or a bad path never reaches the disk',
      () async {
        final p = await servicePlace();
        for (final (fp, request) in [
          (mine.fingerprint, to(5, const [])),
          (mine.fingerprint, to(99, const [])),
          (foreign.fingerprint, to(6, const [])),
          (mine.fingerprint, to(1, ['..'])),
          (mine.fingerprint, to(1, ['a', r'..\..'])),
          (mine.fingerprint, to(1, ['CON'])),
          (mine.fingerprint, to(1, ['ok'], newFolder: 'x.')),
          (mine.fingerprint, to(1, List.filled(33, 'a'))),
        ]) {
          final resolution = await p.service.resolve(
            fp,
            request,
            timeout: Limits.shareCheckTimeout,
          );
          expect(
            resolution,
            isA<SharedRefused>().having(
              (r) => r.reason,
              'reason',
              SharedRefusal.unavailable,
            ),
          );
        }
        expect(p.fs.events, isEmpty);
      },
    );

    test('G7 missing and unavailable chains map to their refusals', () async {
      final p = await servicePlace();
      p.fs.nextOpen = () => const ChainMissing();
      final missing = await p.service.resolve(
        mine.fingerprint,
        to(1, ['falta']),
        timeout: Limits.shareCheckTimeout,
      );
      expect((missing as SharedRefused).reason, SharedRefusal.missing);
      p.fs.nextOpen = () => const ChainUnavailable();
      final unavailable = await p.service.resolve(
        mine.fingerprint,
        to(1, ['union']),
        timeout: Limits.shareCheckTimeout,
      );
      expect((unavailable as SharedRefused).reason, SharedRefusal.unavailable);
      p.fs.nextOpen = null;
      p.fs.throwOn = 'open';
      final thrown = await p.service.resolve(
        mine.fingerprint,
        to(1, ['sub']),
        timeout: Limits.shareCheckTimeout,
      );
      expect((thrown as SharedRefused).reason, SharedRefusal.unavailable);
      expect(p.logs.join('\n'), isNot(contains(r'C:\datos')));
      expect(p.logs.join('\n'), isNot(contains(hexId(1))));
    });

    test('G7 a resolved lease carries the label and the chain facts', () async {
      final p = await servicePlace();
      final resolution = await p.service.resolve(
        mine.fingerprint,
        to(1, ['sub'], newFolder: 'nueva'),
        timeout: Limits.shareCheckTimeout,
      );
      final lease = (resolution as SharedResolved).lease;
      expect(
        lease.label,
        const DestinationLabel(rootName: 'docs', path: ['sub', 'nueva']),
      );
      expect(lease.label.display(homeName: 'Home'), r'docs\sub\nueva');
      expect(lease.folderPath, r'C:\datos\docs\sub\nueva');
      expect(p.fs.events, ['open sub+nueva']);
      await lease.release(saved: false);
      final home = await p.service.resolve(
        mine.fingerprint,
        to(2, ['Escritorio']),
        timeout: Limits.shareCheckTimeout,
      );
      final homeLabel = (home as SharedResolved).lease.label;
      expect(homeLabel.home, isTrue);
      expect(homeLabel.rootName, '');
      expect(
        homeLabel.display(homeName: 'Carpeta personal'),
        r'Carpeta personal\Escritorio',
      );
      await home.lease.release(saved: false);
    });

    test('E746 a slow resolve gives up at 1.5 s and the late chain is '
        'closed when it comes back (punto 2a)', () async {
      final p = await servicePlace();
      p.fs.openDelay = const Duration(seconds: 3);
      final watch = Stopwatch()..start();
      final resolution = await p.service.resolve(
        mine.fingerprint,
        to(1, ['sub']),
        timeout: Limits.shareCheckTimeout,
      );
      final took = watch.elapsed;
      expect((resolution as SharedRefused).reason, SharedRefusal.unavailable);
      expect(took, greaterThanOrEqualTo(const Duration(milliseconds: 1400)));
      expect(took, lessThan(const Duration(milliseconds: 2800)));
      expect(p.fs.released, isEmpty);
      final deadline = DateTime.now().add(const Duration(seconds: 6));
      while (p.fs.released.isEmpty && DateTime.now().isBefore(deadline)) {
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
      expect(p.fs.opened, hasLength(1));
      expect(p.fs.released, {p.fs.opened.single});
      expect(p.fs.events.last, 'release false');
      expect(p.fs.misuse, isEmpty);
    });
  });

  group('G7 lease life (punto 2b) [SEG]', () {
    test('E747 release waits for a slow prepare and closes after it', () async {
      final p = await servicePlace();
      final lease = (await p.service.resolve(
        mine.fingerprint,
        to(1, ['sub']),
        timeout: Limits.shareCheckTimeout,
      ) as SharedResolved).lease;
      final gate = p.fs.prepareGate = Completer<void>();
      final preparing = lease.prepare();
      await Future<void>.delayed(const Duration(milliseconds: 20));
      final releasing = lease.release(saved: false);
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(p.fs.events, ['open sub', 'prepare start']);
      gate.complete();
      expect(await preparing, isTrue);
      await releasing;
      expect(p.fs.events, [
        'open sub',
        'prepare start',
        'prepare end',
        'release false',
      ]);
      final moved = await lease.recheckAndMove(
        tempName: 't.tmp',
        isFolder: false,
        name: 'informe.txt',
      );
      expect(moved, isA<DestinationChanged>());
      expect(await lease.prepare(), isFalse);
      await lease.release(saved: true);
      expect(p.fs.events.where((e) => e.startsWith('release')), hasLength(1));
      expect(p.fs.events.where((e) => e == 'move'), isEmpty);
      expect(p.fs.misuse, isEmpty);
    });

    test('G7 operations run one after another in order', () async {
      final p = await servicePlace();
      final lease = (await p.service.resolve(
        mine.fingerprint,
        to(1, const []),
        timeout: Limits.shareCheckTimeout,
      ) as SharedResolved).lease;
      final gate = p.fs.prepareGate = Completer<void>();
      final preparing = lease.prepare();
      final moving = lease.recheckAndMove(
        tempName: 't.tmp',
        isFolder: false,
        name: 'informe.txt',
      );
      await Future<void>.delayed(const Duration(milliseconds: 30));
      expect(p.fs.events, isNot(contains('move')));
      gate.complete();
      await preparing;
      expect(await moving, isA<MovedTo>());
      await lease.release(saved: true);
      expect(p.fs.events, [
        'open ',
        'prepare start',
        'prepare end',
        'move',
        'release true',
      ]);
    });

    test('G7 failures inside the lease are typed and never thrown', () async {
      final p = await servicePlace();
      final lease = (await p.service.resolve(
        mine.fingerprint,
        to(1, ['sub']),
        timeout: Limits.shareCheckTimeout,
      ) as SharedResolved).lease;
      p.fs.throwOn = 'prepare';
      expect(await lease.prepare(), isFalse);
      p.fs.throwOn = 'move';
      expect(
        await lease.recheckAndMove(
          tempName: 't.tmp',
          isFolder: false,
          name: 'informe.txt',
        ),
        isA<MoveFailed>(),
      );
      p.fs.throwOn = 'release';
      await lease.release(saved: false);
      expect(p.logs.join('\n'), isNot(contains(r'C:\datos')));
      expect(p.logs.join('\n'), isNot(contains('sub')));
    });
  });
}
