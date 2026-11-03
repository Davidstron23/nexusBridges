@TestOn('windows')
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:nexus_bridges_core/src/identity/identity.dart';
import 'package:nexus_bridges_core/src/pairing/pairing.dart';
import 'package:nexus_bridges_core/src/transfer/folders.dart'
    show samePath, tempFolderName;
import 'package:nexus_bridges_core/src/transfer/platform.dart';
import 'package:nexus_bridges_core/src/transfer/transfer.dart';
import 'package:test/test.dart';

import 'receiver_harness.dart';

const Duration _tenth = Duration(milliseconds: 100);

final class _Fixture {
  _Fixture(this.s, this.picker, this.settings);

  final ReceiverStack s;
  final HeldPicker picker;
  final File settings;

  TransferCoordinator get coordinator => s.coordinator;

  String get recv => s.receiveDir;

  String folder(String name) {
    final path = '${s.base}\\$name';
    Directory(path).createSync(recursive: true);
    return path;
  }

  String? savedText() =>
      settings.existsSync() ? settings.readAsStringSync() : null;

  Map<String, Object?>? savedFolder() {
    final text = savedText();
    if (text == null) return null;
    final json = jsonDecode(text) as Map<String, Object?>;
    return (json['receiveFolder'] as Map?)?.cast<String, Object?>();
  }

  Future<FolderChangeResult> change(String? answer) async {
    final run = coordinator.changeReceiveFolder();
    await eventually(() => picker.open, reason: 'the settings picker opens');
    expect(coordinator.pickerOpen, isTrue);
    picker.answer(answer);
    final result = await run;
    expect(coordinator.pickerOpen, isFalse);
    return result;
  }
}

void main() {
  late DeviceIdentity receiver;
  late Peer laptop;
  late Peer portatil;
  late String volumeId;

  setUpAll(() async {
    receiver = DeviceIdentity.generate();
    laptop = Peer(DeviceIdentity.generate(), name: 'Laptop');
    portatil = Peer(
      DeviceIdentity.generate(),
      name: 'PORTATIL',
      relation: PeerRelation.foreign,
    );
    final facts = await realFs.volumeFacts(Directory.systemTemp.path);
    volumeId = facts!.volumeId;
  });

  Future<_Fixture> remembered({
    void Function(TransferPlatform platform)? configure,
  }) async {
    final picker = HeldPicker();
    late File settings;
    final s = await ReceiverStack.start(
      identity: receiver,
      peers: [laptop, portatil],
      picker: picker,
      configure: configure,
      pollHold: const Duration(milliseconds: 50),
      storeIn: (dataDir) {
        settings = File('$dataDir\\settings.json');
        final base = dataDir.substring(0, dataDir.lastIndexOf('\\'));
        settings.writeAsStringSync(
          jsonEncode({
            'version': 1,
            'receiveFolder': {'path': '$base\\recv', 'volume': volumeId},
          }),
        );
        return SettingsFolderStore(settings);
      },
    );
    final fixture = _Fixture(s, picker, settings);
    await eventually(
      () => s.coordinator.receiveFolderPath == s.receiveDir,
      reason: 'the remembered folder is loaded',
    );
    return fixture;
  }

  Future<_Fixture> notRemembered({
    void Function(TransferPlatform platform)? configure,
  }) async {
    final picker = HeldPicker();
    final s = await ReceiverStack.start(
      identity: receiver,
      peers: [laptop, portatil],
      picker: picker,
      remembered: false,
      configure: configure,
      pollHold: const Duration(milliseconds: 50),
    );
    return _Fixture(s, picker, File('${s.dataDir}\\settings.json'));
  }

  Future<String> openQuestion(_Fixture f) async {
    final id = newTransferId();
    final reply = await f.s.offer(laptop, transfer: id);
    expect(reply?.status, 202, reason: reply?.text);
    await eventually(
      () => f.s.incoming?.stage == IncomingStage.folderQuestion,
      reason: 'the folder question is shown',
    );
    return id;
  }

  group('E820: a folder the 004 checks refuse is refused with its reason '
      '(RF-512, RF-514) [SEG]', () {
    test('C:\\Windows, \\\\localhost\\C\$\\Users, the data folder, a drive '
        'that cannot be identified and a path of 237 characters: each with '
        'its reason, the remembered folder does not change and settings.json '
        'is not written', () async {
      final f = await remembered(
        configure: (p) => p.system = SystemFolders(
          downloads: p.system.downloads,
          startup: p.system.startup,
          startMenu: p.system.startMenu,
          windows: r'C:\Windows',
          programFiles: p.system.programFiles,
          systemDriveRoot: p.system.systemDriveRoot,
        ),
      );
      final blind = f.folder('blind');
      f.s.platform.adjustFacts = (path, facts) =>
          samePath(path, blind) ? null : facts;
      final long = '${f.s.base}\\${'x' * (237 - f.s.base.length - 1)}';
      expect(long.length, 237);
      final before = f.savedText();
      final views = f.s.views.length;

      final cases = <String, FolderProblem>{
        r'C:\Windows': FolderProblem.forbidden,
        r'C:\Windows\nb-e820': FolderProblem.forbidden,
        r'\\localhost\C$\Users': FolderProblem.adminShare,
        f.s.dataDir: FolderProblem.forbidden,
        '${f.s.dataDir}\\recibidos': FolderProblem.forbidden,
        blind: FolderProblem.unknownVolume,
        long: FolderProblem.cannotUse,
      };
      for (final MapEntry(key: path, value: problem) in cases.entries) {
        final result = await f.change(path);
        expect(result, isA<FolderChangeRefused>(), reason: path);
        result as FolderChangeRefused;
        expect(result.problem, problem, reason: path);
        expect(result.path, path);
        expect(f.coordinator.receiveFolderPath, f.recv, reason: path);
        expect(f.savedText(), before, reason: path);
      }
      expect(Directory(long).existsSync(), isFalse);
      expect(Directory(r'C:\Windows\nb-e820').existsSync(), isFalse);
      expect(Directory('${f.s.dataDir}\\recibidos').existsSync(), isFalse);
      expect(Directory(r'C:\Users\nb-e820').existsSync(), isFalse);
      expect(f.s.store.saved, isEmpty);
      expect(f.s.events, isEmpty);
      expect(f.picker.startIns, everyElement(f.recv));
      expect(
        f.s.views.skip(views).every((v) => v == null),
        isTrue,
        reason: 'no incoming view appears',
      );
    });

    test(
      'a path of 236 characters is still usable (limit of the 004)',
      () async {
        final f = await remembered();
        final fits = '${f.s.base}\\${'y' * (236 - f.s.base.length - 1)}';
        expect(fits.length, 236);

        final result = await f.change(fits);

        expect(result, isA<FolderChanged>());
        expect(Directory(fits).existsSync(), isTrue);
        expect(f.coordinator.receiveFolderPath, fits);
      },
    );

    test(
      'a cancelled picker gives FolderUnchanged and writes nothing',
      () async {
        final f = await remembered();
        final before = f.savedText();

        expect(await f.change(null), isA<FolderUnchanged>());

        expect(f.coordinator.receiveFolderPath, f.recv);
        expect(f.savedText(), before);
      },
    );

    test('a picker that throws gives FolderUnchanged and closes the picker '
        'state', () async {
      final s = await ReceiverStack.start(
        identity: receiver,
        peers: [laptop],
        picker: _ThrowingPicker(),
      );

      expect(await s.coordinator.changeReceiveFolder(), isA<FolderUnchanged>());
      expect(s.coordinator.pickerOpen, isFalse);
      expect(s.store.saved, isEmpty);
    });
  });

  group('E821: a new folder is remembered (RF-513)', () {
    test('an empty folder: FolderChanged, settings.json keeps the path and the '
        'volume, receiveFolderPath gives it and the old folder is left '
        'intact', () async {
      final f = await remembered();
      final old = File('${f.recv}\\kept.txt')..writeAsStringSync('keep me');
      final next = f.folder('nueva');
      final changes = f.s.views.length;

      final result = await f.change(next);

      expect(result, isA<FolderChanged>());
      expect((result as FolderChanged).path, next);
      expect(f.coordinator.receiveFolderPath, next);
      expect(f.savedFolder(), {'path': next, 'volume': volumeId});
      expect(old.readAsStringSync(), 'keep me');
      expect(Directory(f.recv).existsSync(), isTrue);
      expect(f.s.views.length, greaterThan(changes), reason: 'it emits');
      expect(f.s.events, isEmpty);
      expect(Directory('$next\\$tempFolderName').existsSync(), isFalse);
    });

    test(
      'a folder that does not exist yet is created and remembered',
      () async {
        final f = await remembered();
        final next = '${f.s.base}\\creada';

        final result = await f.change(next);

        expect(result, isA<FolderChanged>());
        expect(Directory(next).existsSync(), isTrue);
        expect(f.savedFolder()?['path'], next);
      },
    );

    test('the next change starts the picker in the new folder and a new '
        'coordinator on the same settings.json uses it', () async {
      final f = await remembered();
      final next = f.folder('nueva');
      await f.change(next);

      await f.change(null);
      expect(f.picker.startIns, [f.recv, next]);

      final again = await ReceiverStack.start(
        identity: receiver,
        peers: [laptop],
        storeOverride: SettingsFolderStore(f.settings),
      );
      await eventually(
        () => again.coordinator.receiveFolderPath == next,
        reason: 'the new folder is loaded at start',
      );
    });

    test('without a remembered folder the first change is remembered and no '
        'question is asked afterwards', () async {
      final f = await notRemembered();
      expect(f.coordinator.receiveFolderPath, isNull);
      final next = f.folder('primera');

      expect(await f.change(next), isA<FolderChanged>());

      expect(f.s.store.saved.single.path, next);
      expect(f.coordinator.receiveFolderPath, next);
      final reply = await f.s.offer(laptop);
      expect(reply?.state, 'accepted', reason: reply?.text);
    });
  });

  group('E822: a folder without the web mark or remote asks to confirm '
      '(RF-513, RF-514)', () {
    test('without the web mark: needs confirmation with noMark and nothing is '
        'written; confirm with its id remembers it', () async {
      final f = await remembered(configure: (p) => p.noMarkSupport = true);
      final next = f.folder('sinmarca');
      final before = f.savedText();

      final result = await f.change(next);

      expect(result, isA<FolderChangeNeedsConfirmation>());
      final ask = result as FolderChangeNeedsConfirmation;
      expect(ask.noMark, isTrue);
      expect(ask.remote, isFalse);
      expect(ask.path, next);
      expect(ask.changeId, matches(hex32));
      expect(f.coordinator.receiveFolderPath, f.recv);
      expect(f.savedText(), before);

      final confirmed = await f.coordinator.confirmReceiveFolder(ask.changeId);

      expect(confirmed, isA<FolderChanged>());
      expect((confirmed as FolderChanged).path, next);
      expect(f.coordinator.receiveFolderPath, next);
      expect(f.savedFolder()?['path'], next);
      expect(
        await f.coordinator.confirmReceiveFolder(ask.changeId),
        isA<FolderUnchanged>(),
        reason: 'an id already used',
      );
    });

    test('cancel keeps the previous folder and removes the folder the check '
        'created if it is still empty', () async {
      final f = await remembered(configure: (p) => p.noMarkSupport = true);
      final created = '${f.s.base}\\nuevasinmarca';
      final before = f.savedText();

      final ask = await f.change(created) as FolderChangeNeedsConfirmation;
      expect(Directory(created).existsSync(), isTrue);

      f.coordinator.cancelReceiveFolderChange(ask.changeId);

      expect(f.coordinator.receiveFolderPath, f.recv);
      expect(f.savedText(), before);
      await eventually(
        () => !Directory(created).existsSync(),
        reason: 'the created folder is removed',
      );
      expect(
        await f.coordinator.confirmReceiveFolder(ask.changeId),
        isA<FolderUnchanged>(),
      );
    });

    test('cancel never removes a folder that existed before', () async {
      final f = await remembered(configure: (p) => p.noMarkSupport = true);
      final existing = f.folder('existente');
      File('$existing\\mine.txt').writeAsStringSync('x');

      final ask = await f.change(existing) as FolderChangeNeedsConfirmation;
      f.coordinator.cancelReceiveFolderChange(ask.changeId);
      await settle(const Duration(milliseconds: 300));

      expect(File('$existing\\mine.txt').existsSync(), isTrue);
    });

    test('a cloud folder and a network drive are remote', () async {
      for (final kind in ['cloud', 'network']) {
        final f = await remembered(
          configure: (p) {
            if (kind == 'cloud') {
              p.cloudFor = (_) => true;
            } else {
              p.adjustFacts = (path, facts) => facts == null
                  ? null
                  : VolumeFacts(
                      volumeId: facts.volumeId,
                      supportsNamedStreams: true,
                      isRemote: true,
                    );
            }
          },
        );
        final next = f.folder('remota');

        final ask = await f.change(next);

        expect(ask, isA<FolderChangeNeedsConfirmation>(), reason: kind);
        expect((ask as FolderChangeNeedsConfirmation).remote, isTrue);
        expect(ask.noMark, isFalse, reason: kind);
        expect(f.coordinator.receiveFolderPath, f.recv, reason: kind);
        expect(
          await f.coordinator.confirmReceiveFolder(ask.changeId),
          isA<FolderChanged>(),
          reason: kind,
        );
        await f.s.close();
      }
    });

    test('an old or invented changeId gives FolderUnchanged and a new change '
        'drops the pending one', () async {
      final f = await remembered(configure: (p) => p.noMarkSupport = true);
      final one = f.folder('uno');
      final two = f.folder('dos');

      expect(
        await f.coordinator.confirmReceiveFolder('0' * 32),
        isA<FolderUnchanged>(),
      );
      final first = await f.change(one) as FolderChangeNeedsConfirmation;
      final second = await f.change(two) as FolderChangeNeedsConfirmation;
      expect(second.changeId, isNot(first.changeId));

      expect(
        await f.coordinator.confirmReceiveFolder(first.changeId),
        isA<FolderUnchanged>(),
      );
      expect(
        await f.coordinator.confirmReceiveFolder('f' * 32),
        isA<FolderUnchanged>(),
      );
      f.coordinator.cancelReceiveFolderChange('invented');
      expect(f.coordinator.receiveFolderPath, f.recv);

      final confirmed = await f.coordinator.confirmReceiveFolder(
        second.changeId,
      );
      expect((confirmed as FolderChanged).path, two);
    });
  });

  group('E823: the settings picker freezes the deadlines like any picker '
      '(RF-512, D-10)', () {
    test('with the picker open pickerOpen is true, the 60 s of an open '
        'foreign warning do not run, receiveFolderLocked stays false and the '
        'incoming view does not change', () async {
      final f = await remembered();
      final id = newTransferId();
      expect((await f.s.offer(portatil, transfer: id))?.status, 202);
      await eventually(() => f.s.incoming?.stage == IncomingStage.warning);
      await f.s.advanceWithPolls(portatil, id, const Duration(seconds: 50));
      final warning = f.s.incoming;
      final busy = f.coordinator.busy;

      final run = f.coordinator.changeReceiveFolder();
      await eventually(() => f.picker.open);
      expect(f.coordinator.pickerOpen, isTrue);
      expect(f.coordinator.receiveFolderLocked, isFalse);

      await f.s.advanceWithPolls(portatil, id, const Duration(seconds: 120));
      await settle();

      expect(f.s.incoming?.stage, IncomingStage.warning);
      expect(f.s.incoming, warning);
      expect(f.coordinator.busy, busy);
      expect(f.coordinator.receiveFolderLocked, isFalse);
      final poll = await f.s.wait(portatil, id);
      expect(poll?.json, {'state': 'waiting', 'picker': true});

      f.picker.answer(null);
      expect(await run, isA<FolderUnchanged>());
      expect(f.coordinator.pickerOpen, isFalse);

      await f.s.advanceWithPolls(
        portatil,
        id,
        const Duration(milliseconds: 9900),
      );
      await settle();
      expect(f.s.incoming?.stage, IncomingStage.warning);
      f.s.clock.advance(_tenth);
      await eventually(() => f.s.incoming == null, reason: 'warning expired');
    });

    test('a second change while the settings picker is open is blocked '
        'without a second picker', () async {
      final f = await remembered();
      final run = f.coordinator.changeReceiveFolder();
      await eventually(() => f.picker.open);

      expect(
        await f.coordinator.changeReceiveFolder(),
        isA<FolderChangeBlocked>(),
      );
      expect(f.picker.folderCalls, 1);

      f.picker.answer(null);
      await run;
    });
  });

  group('E825: the folder cannot change while the folder question is open '
      '(RF-516, clarify point 16)', () {
    test('with the question exposed, receiveFolderLocked is true and the '
        'change is blocked without opening the picker', () async {
      final f = await notRemembered();
      await openQuestion(f);

      expect(f.coordinator.receiveFolderLocked, isTrue);
      expect(
        await f.coordinator.changeReceiveFolder(),
        isA<FolderChangeBlocked>(),
      );
      expect(f.picker.folderCalls, 0);
    });

    test('with the picker of that question open it is blocked too', () async {
      final f = await notRemembered();
      await openQuestion(f);
      final choosing = f.coordinator.chooseOtherFolder(f.s.sid);
      await eventually(() => f.picker.open);

      expect(
        await f.coordinator.changeReceiveFolder(),
        isA<FolderChangeBlocked>(),
      );
      expect(f.picker.folderCalls, 1);

      f.picker.answer(null);
      await choosing;
    });

    test('the question shows up while the settings picker is open: on '
        'return the change is blocked and nothing changes', () async {
      final f = await notRemembered();
      final next = f.folder('elegida');
      final run = f.coordinator.changeReceiveFolder();
      await eventually(() => f.picker.open);

      await openQuestion(f);
      expect(f.coordinator.receiveFolderLocked, isTrue);
      f.picker.answer(next);

      expect(await run, isA<FolderChangeBlocked>());
      expect(f.coordinator.receiveFolderPath, isNull);
      expect(f.s.store.saved, isEmpty);
      expect(f.s.incoming?.stage, IncomingStage.folderQuestion);
    });

    test('the question shows up while the chosen folder is being checked: '
        'blocked, nothing remembered and the folder the check created is '
        'removed', () async {
      final gate = Completer<void>();
      final f = await notRemembered();
      final next = '${f.s.base}\\durante';
      f.s.platform.hold = (method, path) async {
        if (method == 'volumeFacts' && !gate.isCompleted) await gate.future;
      };
      final run = f.coordinator.changeReceiveFolder();
      await eventually(() => f.picker.open);
      f.picker.answer(next);
      await eventually(
        () => f.s.platform.calls.contains('volumeFacts ${f.s.base}'),
        reason: 'the check is waiting',
      );

      final id = newTransferId();
      expect((await f.s.offer(laptop, transfer: id))?.status, 202);
      await eventually(
        () => f.s.incoming?.stage == IncomingStage.folderQuestion,
        reason: 'question shown during the check',
      );
      gate.complete();

      expect(await run, isA<FolderChangeBlocked>());
      expect(f.coordinator.receiveFolderPath, isNull);
      expect(f.s.store.saved, isEmpty);
      await eventually(
        () => !Directory(next).existsSync(),
        reason: 'the created folder is removed',
      );
    });

    test('a pending confirmation is blocked if the question shows up before '
        'it is confirmed', () async {
      final f = await notRemembered(configure: (p) => p.noMarkSupport = true);
      final created = '${f.s.base}\\pendiente';
      final ask = await f.change(created) as FolderChangeNeedsConfirmation;

      await openQuestion(f);

      expect(
        await f.coordinator.confirmReceiveFolder(ask.changeId),
        isA<FolderChangeBlocked>(),
      );
      expect(f.coordinator.receiveFolderPath, isNull);
      expect(f.s.store.saved, isEmpty);
    });

    test('once the question is answered the change works again', () async {
      final f = await notRemembered();
      await openQuestion(f);
      await f.coordinator.useProposedFolder(f.s.sid);
      await eventually(
        () => f.s.incoming?.stage == IncomingStage.waitingData,
        reason: 'accepted',
      );
      expect(f.coordinator.receiveFolderLocked, isFalse);
      final next = f.folder('despues');

      expect(await f.change(next), isA<FolderChanged>());
    });
  });

  group('E826: choosing the same folder (edge case)', () {
    test('the remembered folder, also in another case, gives FolderUnchanged '
        'without writing', () async {
      final f = await remembered();
      final before = f.savedText();
      final stamp = f.settings.lastModifiedSync();

      expect(await f.change(f.recv), isA<FolderUnchanged>());
      expect(await f.change(f.recv.toUpperCase()), isA<FolderUnchanged>());

      expect(f.savedText(), before);
      expect(f.settings.lastModifiedSync(), stamp);
      expect(f.coordinator.receiveFolderPath, f.recv);
      expect(f.s.store.saved, isEmpty);
    });
  });
}

final class _ThrowingPicker implements FilePicker {
  @override
  Future<String?> pickFile() async => null;

  @override
  Future<String?> pickFolder({String? startIn}) async =>
      throw const FileSystemException('picker failed');

  @override
  Future<List<String>> pickFiles() async => const [];

  @override
  Future<List<String>> pickFolders() async => const [];
}
