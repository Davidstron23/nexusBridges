import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:nexus_bridges_core/src/identity/identity.dart';
import 'package:nexus_bridges_core/src/pairing/pairing.dart';
import 'package:nexus_bridges_core/src/protocol/protocol.dart';
import 'package:nexus_bridges_core/src/settings/settings.dart';
import 'package:nexus_bridges_core/src/storage/storage.dart';
import 'package:nexus_bridges_core/src/transfer/folders.dart';
import 'package:nexus_bridges_core/src/transfer/platform.dart';
import 'package:nexus_bridges_core/src/transfer/transfer.dart';
import 'package:test/test.dart';

import 'receiver_harness.dart';

void expectWaiting(RawReply? reply, {bool picker = false}) {
  expect(reply, isNotNull);
  expect(reply!.status, 202, reason: reply.text);
  expect(reply.json, {'state': 'waiting', 'picker': picker});
}

void expectStillWaiting(RawReply? reply, {bool picker = false}) {
  expect(reply, isNotNull);
  expect(reply!.status, 200, reason: reply.text);
  expect(reply.json, {'state': 'waiting', 'picker': picker});
}

String expectAccepted(RawReply? reply) {
  expect(reply, isNotNull);
  expect(reply!.status, 200, reason: reply.text);
  expect(reply.state, 'accepted', reason: reply.text);
  final permit = reply.json['permit'] as String;
  expect(permit, matches(hex32));
  return permit;
}

void expectRejected(RawReply? reply, String reason) {
  expect(reply, isNotNull);
  expect(reply!.status, 200, reason: reply.text);
  expect(reply.json, {'state': 'rejected', 'reason': reason});
}

void expectBusy(RawReply? reply) {
  expect(reply, isNotNull);
  expect(reply!.status, 409, reason: reply.text);
  expect(reply.json, {'error': 'busy'});
}

const String _lockScript = '''
import 'dart:io';

Future<void> main(List<String> args) async {
  final file = await File(args.first).open(mode: FileMode.append);
  await file.lock(FileLock.exclusive);
  stdout.writeln('locked');
  await stdin.drain<void>();
  await file.unlock();
  await file.close();
}
''';

Future<Future<void> Function()> lockInChild(File file) async {
  final dir = await Directory.systemTemp.createTemp('nexus_t7_lock_');
  addTearDown(() => dir.delete(recursive: true));
  final script = File('${dir.path}\\lock_file.dart');
  await script.writeAsString(_lockScript);
  final process = await Process.start(Platform.resolvedExecutable, [
    script.path,
    file.path,
  ]);
  var released = false;
  addTearDown(() async {
    if (released) return;
    process.kill();
    await process.exitCode;
  });
  process.stderr.drain<void>().ignore();
  final line = await process.stdout
      .transform(utf8.decoder)
      .transform(const LineSplitter())
      .first
      .timeout(const Duration(seconds: 60));
  expect(line.trim(), 'locked');
  return () async {
    released = true;
    await process.stdin.close();
    expect(await process.exitCode.timeout(const Duration(seconds: 30)), 0);
  };
}

VolumeFacts? otherVolume(String path, VolumeFacts? facts) => facts == null
    ? null
    : VolumeFacts(
        volumeId: 'NTFS-0badf00d',
        supportsNamedStreams: facts.supportsNamedStreams,
        isRemote: facts.isRemote,
      );

void main() {
  late DeviceIdentity receiver;
  late Peer laptop;
  late Peer portatil;

  setUpAll(() {
    receiver = DeviceIdentity.generate();
    laptop = Peer(DeviceIdentity.generate(), name: 'Laptop');
    portatil = Peer(
      DeviceIdentity.generate(),
      name: 'PORTATIL',
      relation: PeerRelation.foreign,
    );
  });

  Future<(ReceiverStack, HeldPicker)> stack({
    bool remembered = false,
    String Function(String base)? rememberedPath,
    Duration pollHold = const Duration(milliseconds: 50),
    void Function(TransferPlatform platform)? configure,
    ReceiveFolderStore Function(String dataDir)? storeIn,
    ReceiveFolderStore? storeOverride,
  }) async {
    final picker = HeldPicker();
    final s = await ReceiverStack.start(
      identity: receiver,
      peers: [laptop, portatil],
      remembered: remembered,
      rememberedPath: rememberedPath,
      pollHold: pollHold,
      configure: configure,
      picker: picker,
      storeIn: storeIn,
      storeOverride: storeOverride,
    );
    return (s, picker);
  }

  String folderIn(ReceiverStack s, String name) {
    final path = '${s.base}\\$name';
    Directory(path).createSync(recursive: true);
    return path;
  }

  String proposedOf(ReceiverStack s) => '${s.downloadsDir}\\NexusBridges';

  FolderQuestionView question(ReceiverStack s) {
    final view = s.incoming;
    expect(view?.stage, IncomingStage.folderQuestion);
    return view!.folder!;
  }

  Future<String> openQuestion(ReceiverStack s, Peer peer) async {
    final id = newTransferId();
    expectWaiting(await s.offer(peer, transfer: id));
    await eventually(
      () => s.incoming?.stage == IncomingStage.folderQuestion,
      reason: 'folder question shown',
    );
    return id;
  }

  Future<void> choose(ReceiverStack s, HeldPicker picker, String? path) async {
    final run = s.coordinator.chooseOtherFolder(s.sid);
    expect(picker.open, isTrue);
    expect(s.coordinator.pickerOpen, isTrue);
    picker.answer(path);
    await run;
    expect(s.coordinator.pickerOpen, isFalse);
  }

  Future<void> waitAccepted(ReceiverStack s) => eventually(
    () => s.incoming?.stage == IncomingStage.waitingData,
    reason: 'accepted',
  );

  group('E67 RF-146 RF-198 RF-199 RF-203 first time', () {
    test('an own device with no folder gets the question; "use this" creates '
        'Downloads\\NexusBridges, saves it with its volume and '
        'accepts', () async {
      final (s, _) = await stack(
        storeIn: (dataDir) =>
            SettingsFolderStore(File('$dataDir\\settings.json')),
      );
      final proposed = proposedOf(s);
      final id = await openQuestion(s, laptop);
      final view = s.incoming!;
      expect(view.peerName, 'Laptop');
      expect(view.fileName, 'informe.pdf');
      expect(
        view.folder,
        FolderQuestionView(
          kind: FolderQuestionKind.firstTime,
          proposedPath: proposed,
        ),
      );
      expect(Directory(proposed).existsSync(), isFalse);
      expectStillWaiting(await s.wait(laptop, id));

      await s.coordinator.useProposedFolder(s.sid);

      await waitAccepted(s);
      expect(Directory(proposed).existsSync(), isTrue);
      expect(Directory('$proposed\\$tempFolderName').existsSync(), isFalse);
      final saved = await SettingsStore(
        JsonFileStore(File('${s.dataDir}\\settings.json')),
      ).readReceiveFolder();
      expect(saved?.path, proposed);
      final facts = await realFs.volumeFacts(proposed);
      expect(saved?.volumeId, facts!.volumeId);
      expectAccepted(await s.wait(laptop, id));
      expect(s.events, isEmpty);
    });

    test(
      'only the last folder is created, never the rest of the path',
      () async {
        final (s, picker) = await stack();
        await openQuestion(s, laptop);
        final deep = '${s.base}\\nope\\deeper';
        await choose(s, picker, deep);
        expect(question(s).problem, FolderProblem.cannotUse);
        expect(question(s).problemPath, deep);
        expect(Directory('${s.base}\\nope').existsSync(), isFalse);
        expect(s.store.saved, isEmpty);
      },
    );
  });

  group('E71 RF-203 the folder is remembered across restarts', () {
    test(
      'a new coordinator with the same settings.json does not ask',
      () async {
        final (first, _) = await stack(
          storeIn: (dataDir) =>
              SettingsFolderStore(File('$dataDir\\settings.json')),
        );
        final settings = File('${first.dataDir}\\settings.json');
        await openQuestion(first, laptop);
        await first.coordinator.useProposedFolder(first.sid);
        await waitAccepted(first);
        await first.close();

        final (second, _) = await stack(
          storeOverride: SettingsFolderStore(settings),
        );
        second.sampleViews();
        final id = newTransferId();
        expectAccepted(await second.offer(laptop, transfer: id));
        await waitAccepted(second);
        expect(
          second.seen.where((v) => v.stage == IncomingStage.folderQuestion),
          isEmpty,
        );
      },
    );
  });

  group('E72 RF-244 the folder cannot be saved', () {
    test(
      'with settings.json locked, the folder is used for the session, the '
      'event is raised and the next request does not ask',
      () async {
        final root = await Directory.systemTemp.createTemp('nexus_t7_set_');
        addTearDown(() => root.delete(recursive: true));
        final settings = File('${root.path}\\settings.json');
        await settings.writeAsString('{"version":1}');
        final release = await lockInChild(settings);

        final (s, _) = await stack(
          storeOverride: SettingsFolderStore(settings),
        );
        final proposed = proposedOf(s);
        final id = await openQuestion(s, laptop);
        expect(question(s).kind, FolderQuestionKind.firstTime);

        await s.coordinator.useProposedFolder(s.sid);

        await waitAccepted(s);
        expectAccepted(await s.wait(laptop, id));
        await eventually(() => s.events.isNotEmpty, reason: 'event');
        final event = s.events.single as ReceiveFolderNotSaved;
        expect(event.path, proposed);

        s.coordinator.cancelIncoming(s.sid);
        await eventually(() => s.incoming == null);
        expectAccepted(await s.offer(laptop));

        await release();
        expect(await settings.readAsString(), '{"version":1}');
      },
      timeout: const Timeout(Duration(minutes: 2)),
      testOn: 'windows',
    );

    test('a store that answers false raises the event and keeps the folder in '
        'memory', () async {
      final (s, _) = await stack(storeOverride: _RefusingStore());
      await openQuestion(s, laptop);
      await s.coordinator.useProposedFolder(s.sid);
      await waitAccepted(s);
      await eventually(() => s.events.isNotEmpty, reason: 'event');
      expect(s.events.single, isA<ReceiveFolderNotSaved>());
      s.coordinator.cancelIncoming(s.sid);
      await eventually(() => s.incoming == null);
      expectAccepted(await s.offer(laptop));
    });
  });

  group('E68 RF-200 choosing another folder', () {
    test('a picker that gives nothing leaves the question with the same '
        'deadline, and the chosen folder is used afterwards', () async {
      final (s, picker) = await stack();
      final other = folderIn(s, 'otra');
      final id = await openQuestion(s, laptop);
      final before = question(s);
      await s.advanceWithPolls(laptop, id, const Duration(seconds: 30));

      final run = s.coordinator.chooseOtherFolder(s.sid);
      expect(picker.startIns.single, s.downloadsDir);
      expect(question(s).pickerOpen, isTrue);
      picker.answer(null);
      await run;
      expect(question(s), before);

      await s.advanceWithPolls(laptop, id, const Duration(milliseconds: 29900));
      await settle();
      expect(question(s), before);

      await choose(s, picker, other);
      await waitAccepted(s);
      expect(s.store.saved.single.path, other);
      expectAccepted(await s.wait(laptop, id));
    });
  });

  group('E69 RF-201 RF-242 a folder that cannot be used', () {
    test('a folder holding a file with the reserved name is cannot use and the '
        'file is not touched', () async {
      final (s, picker) = await stack();
      final odd = folderIn(s, 'withfile');
      final reserved = File('$odd\\$tempFolderName');
      reserved.writeAsStringSync('keep');
      final id = await openQuestion(s, laptop);

      await choose(s, picker, odd);

      final view = question(s);
      expect(view.problem, FolderProblem.cannotUse);
      expect(view.problemPath, odd);
      expect(view.inspecting, isFalse);
      expect(reserved.readAsStringSync(), 'keep');
      expect(s.store.saved, isEmpty);
      expectStillWaiting(await s.wait(laptop, id));
    });

    test('[SEG] the Startup folder, a folder inside it, the data folder, the '
        'system root and a junction to Startup are forbidden and nothing is '
        'created', () async {
      final (s, picker) = await stack();
      final startup = s.platform.system.startup!;
      final junction = '${s.base}\\atajo';
      await Link(junction).create(startup);
      addTearDown(() async {
        if (Link(junction).existsSync()) await Link(junction).delete();
      });
      await openQuestion(s, laptop);

      for (final path in [
        startup,
        '$startup\\nueva',
        '${s.dataDir}\\recibidos',
        s.platform.system.systemDriveRoot!,
        junction,
        '$junction\\nueva',
      ]) {
        await choose(s, picker, path);
        final view = question(s);
        expect(view.problem, FolderProblem.forbidden, reason: path);
        expect(view.problemPath, path);
      }
      expect(Directory('$startup\\nueva').existsSync(), isFalse);
      expect(Directory('${s.dataDir}\\recibidos').existsSync(), isFalse);
      expect(Directory('$startup\\$tempFolderName').existsSync(), isFalse);
      expect(s.store.saved, isEmpty);
      expect(s.incoming?.stage, IncomingStage.folderQuestion);
    });

    test('a valid folder after a problem is used', () async {
      final (s, picker) = await stack();
      final good = folderIn(s, 'buena');
      await openQuestion(s, laptop);
      await choose(s, picker, s.platform.system.startup);
      expect(question(s).problem, FolderProblem.forbidden);
      await choose(s, picker, good);
      await waitAccepted(s);
      expect(s.store.saved.single.path, good);
    });
  });

  group('E191 RF-201 RF-242 administrative share in the question', () {
    test('[SEG] \\\\localhost\\C\$ is refused with its own problem, the '
        'deadline holds, nothing is created, then a valid folder is '
        'used', () async {
      const share = r'\\localhost\C$\nb-e191';
      const local = r'C:\nb-e191';
      expect(Directory(local).existsSync(), isFalse);
      final (s, picker) = await stack();
      final good = folderIn(s, 'buena');
      final id = await openQuestion(s, laptop);
      await s.advanceWithPolls(laptop, id, const Duration(seconds: 20));

      await choose(s, picker, share);

      final view = question(s);
      expect(view.problem, FolderProblem.adminShare);
      expect(view.problemPath, share);
      expect(Directory(local).existsSync(), isFalse);
      expect(s.store.saved, isEmpty);

      await s.advanceWithPolls(laptop, id, const Duration(milliseconds: 39900));
      await settle();
      expect(question(s).problem, FolderProblem.adminShare);

      await choose(s, picker, good);
      await waitAccepted(s);
      expect(s.store.saved.single.path, good);
      expect(Directory(local).existsSync(), isFalse);
    });

    test('after the end, an administrative share is not usable', () async {
      final (s, picker) = await stack();
      final id = await openQuestion(s, laptop);
      final run = s.coordinator.chooseOtherFolder(s.sid);
      await s.cancel(laptop, id);
      picker.answer(r'\\localhost\C$\nb-e191');
      await run;
      expect(s.incoming?.stage, IncomingStage.ended);
      expect(s.incoming?.folder?.afterEnd, AfterEndResult.notUsable);
      expect(s.store.saved, isEmpty);
      expect(Directory(r'C:\nb-e191').existsSync(), isFalse);
    });
  });

  group('E70 RF-202 RF-243 use it anyway', () {
    test('a drive without the web mark asks to confirm; "use anyway" uses and '
        'remembers it', () async {
      final (s, _) = await stack(configure: (p) => p.noMarkSupport = true);
      final proposed = proposedOf(s);
      final id = await openQuestion(s, laptop);

      await s.coordinator.useProposedFolder(s.sid);

      final view = question(s);
      expect(view.cautionPath, proposed);
      expect(view.cautionNoMark, isTrue);
      expect(view.cautionRemote, isFalse);
      expect(view.problem, isNull);
      expect(s.store.saved, isEmpty);
      expectStillWaiting(await s.wait(laptop, id));

      s.coordinator.useFolderAnyway(s.sid);
      await waitAccepted(s);
      expect(s.store.saved.single.path, proposed);
      expect(Directory(proposed).existsSync(), isTrue);
      expectAccepted(await s.wait(laptop, id));
    });

    test('a network drive and a cloud folder are flagged as remote', () async {
      for (final kind in ['network', 'cloud']) {
        final (s, picker) = await stack(
          configure: (p) {
            if (kind == 'network') {
              p.adjustFacts = (path, facts) => facts == null
                  ? null
                  : VolumeFacts(
                      volumeId: facts.volumeId,
                      supportsNamedStreams: true,
                      isRemote: true,
                    );
            } else {
              p.cloudFor = (_) => true;
            }
          },
        );
        final folder = folderIn(s, 'nube');
        await openQuestion(s, laptop);
        await choose(s, picker, folder);
        final view = question(s);
        expect(view.cautionPath, folder, reason: kind);
        expect(view.cautionRemote, isTrue, reason: kind);
        expect(view.cautionNoMark, isFalse, reason: kind);
        s.coordinator.useFolderAnyway(s.sid);
        await waitAccepted(s);
        expect(s.store.saved.single.path, folder);
        await s.close();
      }
    });

    test('"choose another" with a caution opens the picker, clears the caution '
        'and removes the folder the check created', () async {
      final (s, picker) = await stack(configure: (p) => p.noMarkSupport = true);
      final proposed = proposedOf(s);
      await openQuestion(s, laptop);
      await s.coordinator.useProposedFolder(s.sid);
      expect(question(s).cautionPath, proposed);
      expect(Directory(proposed).existsSync(), isTrue);

      final run = s.coordinator.chooseOtherFolder(s.sid);
      expect(picker.folderCalls, 1);
      final open = question(s);
      expect(open.pickerOpen, isTrue);
      expect(open.cautionPath, isNull);
      expect(open.cautionNoMark, isFalse);
      await eventually(
        () => !Directory(proposed).existsSync(),
        reason: 'unused folder removed',
      );
      s.coordinator.useFolderAnyway(s.sid);
      picker.answer(null);
      await run;
      expect(question(s).cautionPath, isNull);
      expect(s.incoming?.stage, IncomingStage.folderQuestion);
      expect(s.store.saved, isEmpty);
    });

    test('a caution clears the previous problem', () async {
      final (s, picker) = await stack(configure: (p) => p.noMarkSupport = true);
      final folder = folderIn(s, 'pendrive');
      await openQuestion(s, laptop);
      await choose(s, picker, s.platform.system.startup);
      expect(question(s).problem, FolderProblem.forbidden);
      await choose(s, picker, folder);
      final view = question(s);
      expect(view.problem, isNull);
      expect(view.problemPath, isNull);
      expect(view.cautionPath, folder);
    });
  });

  group('E73 RF-204 cancelling the question', () {
    test('both sides see no folder, nothing is remembered and the next request '
        'asks again', () async {
      final (s, _) = await stack(configure: (p) => p.noMarkSupport = true);
      final proposed = proposedOf(s);
      final id = await openQuestion(s, laptop);
      await s.coordinator.useProposedFolder(s.sid);
      expect(Directory(proposed).existsSync(), isTrue);

      s.coordinator.cancelFolderQuestion(s.sid);

      expect(s.incoming, isNull);
      expect(s.coordinator.busy, isFalse);
      expect(s.coordinator.lastReceived?.outcome, TransferOutcome.noFolder);
      expect(s.coordinator.lastReceived?.peerName, 'Laptop');
      expectRejected(await s.wait(laptop, id), 'no_folder');
      expect(s.store.saved, isEmpty);
      await eventually(
        () => !Directory(proposed).existsSync(),
        reason: 'unused folder removed',
      );
      await openQuestion(s, laptop);
      expect(question(s).kind, FolderQuestionKind.firstTime);
    });

    test('close() waits for the unused folder to be removed', () async {
      final (s, _) = await stack(configure: (p) => p.noMarkSupport = true);
      final proposed = proposedOf(s);
      await openQuestion(s, laptop);
      await s.coordinator.useProposedFolder(s.sid);
      expect(Directory(proposed).existsSync(), isTrue);
      await s.coordinator.close();
      expect(Directory(proposed).existsSync(), isFalse);
      expect(s.coordinator.lastReceived?.outcome, TransferOutcome.noFolder);
    });
  });

  group('E65 RF-220 RF-221 RF-222 relation changes', () {
    test(
      'own device turned foreign while the question is open gets the warning '
      'after choosing',
      () async {
        final (s, _) = await stack();
        final id = await openQuestion(s, laptop);
        expect(
          await s.paired.setRelation(laptop.fingerprint, PeerRelation.foreign),
          isTrue,
        );
        await s.coordinator.useProposedFolder(s.sid);
        await eventually(() => s.incoming?.stage == IncomingStage.warning);
        expect(s.store.saved.single.path, proposedOf(s));
        expectStillWaiting(await s.wait(laptop, id));

        s.coordinator.answerWarning(s.sid, accept: true);
        await waitAccepted(s);
        expectAccepted(await s.wait(laptop, id));
      },
    );

    test(
      'foreign device turned own while the warning is open keeps the warning '
      'until accepted',
      () async {
        final (s, _) = await stack(remembered: true);
        final id = newTransferId();
        expectWaiting(await s.offer(portatil, transfer: id));
        await eventually(() => s.incoming?.stage == IncomingStage.warning);
        expect(
          await s.paired.setRelation(portatil.fingerprint, PeerRelation.mine),
          isTrue,
        );
        await s.advanceWithPolls(portatil, id, const Duration(seconds: 5));
        await settle();
        expect(s.incoming?.stage, IncomingStage.warning);
        expectStillWaiting(await s.wait(portatil, id));
        s.coordinator.answerWarning(s.sid, accept: true);
        await waitAccepted(s);
        expectAccepted(await s.wait(portatil, id));
      },
    );
  });

  group('E66 RF-241 foreign device without a folder', () {
    test('warning first, then the question, then accepted', () async {
      final (s, _) = await stack();
      final id = newTransferId();
      expectWaiting(await s.offer(portatil, transfer: id));
      await eventually(() => s.incoming?.stage == IncomingStage.warning);
      expect(s.incoming?.folder, isNull);
      s.coordinator.answerWarning(s.sid, accept: true);
      expect(question(s).kind, FolderQuestionKind.firstTime);
      expectStillWaiting(await s.wait(portatil, id));
      await s.coordinator.useProposedFolder(s.sid);
      await waitAccepted(s);
      expectAccepted(await s.wait(portatil, id));
    });
  });

  group('E75 RF-206 RF-245 remembered folder unavailable', () {
    test('asks for this time with the remembered folder first; the choice is '
        'used once and the remembered one comes back', () async {
      final (s, picker) = await stack(
        remembered: true,
        rememberedPath: (base) => '$base\\rem\\recv',
      );
      final remembered = folderIn(s, 'rem\\recv');
      final other = folderIn(s, 'otra');
      await Directory('${s.base}\\rem').rename('${s.base}\\rem2');

      final id = await openQuestion(s, laptop);
      expect(
        question(s),
        FolderQuestionView(
          kind: FolderQuestionKind.thisTime,
          proposedPath: remembered,
          problem: FolderProblem.rememberedUnavailable,
        ),
      );

      await s.coordinator.useProposedFolder(s.sid);
      expect(question(s).problem, FolderProblem.stillUnavailable);
      expect(question(s).problemPath, remembered);
      expect(Directory('${s.base}\\rem').existsSync(), isFalse);

      await choose(s, picker, other);
      await waitAccepted(s);
      expect(s.store.saved, isEmpty);
      expectAccepted(await s.wait(laptop, id));
      s.coordinator.cancelIncoming(s.sid);
      await eventually(() => s.incoming == null);

      await openQuestion(s, laptop);
      expect(question(s).kind, FolderQuestionKind.thisTime);
      expect(question(s).proposedPath, remembered);
      s.coordinator.cancelFolderQuestion(s.sid);

      await Directory('${s.base}\\rem2').rename('${s.base}\\rem');
      expectAccepted(await s.offer(laptop));
      expect(s.store.saved, isEmpty);
    });
  });

  group('E76 RF-246 remembered folder on another drive', () {
    test('asks for this time and creates nothing at that path, also when it is '
        'tried again or chosen in the picker', () async {
      final (s, picker) = await stack(
        remembered: true,
        rememberedPath: (base) => '$base\\recv\\NexusBridges',
        configure: (p) => p.adjustFacts = otherVolume,
      );
      final remembered = '${s.receiveDir}\\NexusBridges';
      final other = folderIn(s, 'otra');

      await openQuestion(s, laptop);
      expect(question(s).kind, FolderQuestionKind.thisTime);
      expect(question(s).problem, FolderProblem.rememberedUnavailable);
      expect(Directory(remembered).existsSync(), isFalse);

      await s.coordinator.useProposedFolder(s.sid);
      expect(question(s).problem, FolderProblem.stillUnavailable);
      expect(Directory(remembered).existsSync(), isFalse);

      await choose(s, picker, remembered.toUpperCase());
      expect(question(s).problem, FolderProblem.stillUnavailable);
      expect(Directory(remembered).existsSync(), isFalse);

      await choose(s, picker, other);
      await waitAccepted(s);
      expect(s.store.saved, isEmpty);
      expect(Directory(remembered).existsSync(), isFalse);
    });
  });

  group('E157 RF-201 unknown volume', () {
    test('the chosen folder gives unknown volume, the question stays, nothing '
        'is remembered or created', () async {
      final (s, picker) = await stack();
      final blind = folderIn(s, 'nv');
      s.platform.adjustFacts = (path, facts) =>
          samePath(path, blind) ? null : facts;
      await openQuestion(s, laptop);

      await choose(s, picker, blind);
      expect(question(s).problem, FolderProblem.unknownVolume);
      expect(question(s).problemPath, blind);

      await choose(s, picker, '$blind\\sub');
      expect(question(s).problem, FolderProblem.unknownVolume);
      expect(Directory('$blind\\sub').existsSync(), isFalse);
      expect(Directory('$blind\\$tempFolderName').existsSync(), isFalse);
      expect(s.store.saved, isEmpty);
      expect(s.incoming?.stage, IncomingStage.folderQuestion);
    });

    test('after the end it is not usable', () async {
      final (s, picker) = await stack();
      final blind = folderIn(s, 'nv');
      s.platform.adjustFacts = (path, facts) =>
          samePath(path, blind) ? null : facts;
      final id = await openQuestion(s, laptop);
      final run = s.coordinator.chooseOtherFolder(s.sid);
      await s.cancel(laptop, id);
      picker.answer(blind);
      await run;
      expect(s.incoming?.folder?.afterEnd, AfterEndResult.notUsable);
      expect(s.store.saved, isEmpty);
    });
  });

  group('E77 RF-209 picker open after the end', () {
    test(
      'the sender cancels with the first time picker open; a valid folder is '
      'remembered without accepting anything',
      () async {
        final (s, picker) = await stack();
        final good = '${s.base}\\nueva';
        final id = await openQuestion(s, laptop);
        final run = s.coordinator.chooseOtherFolder(s.sid);
        expect(await s.cancel(laptop, id), isNotNull);

        final ended = s.incoming!;
        expect(ended.stage, IncomingStage.ended);
        expect(ended.peerName, 'Laptop');
        expect(ended.folder?.kind, FolderQuestionKind.firstTime);
        expect(ended.folder?.pickerOpen, isTrue);
        expect(ended.folder?.afterEnd, isNull);
        expect(s.coordinator.lastReceived, isNull);
        expect(s.events.single, isA<PeerCancelledTransfer>());

        picker.answer(good);
        await run;

        final after = s.incoming!;
        expect(after.stage, IncomingStage.ended);
        expect(after.folder?.afterEnd, AfterEndResult.remembered);
        expect(after.folder?.pickerOpen, isFalse);
        expect(s.store.saved.single.path, good);
        expect(Directory(good).existsSync(), isTrue);
        expect(s.coordinator.lastReceived, isNull);
        expect(s.coordinator.busy, isFalse);
        expect(await s.wait(laptop, id), isNotNull);

        s.coordinator.dismissFolderPanel(s.sid);
        expect(s.incoming, isNull);
        expectAccepted(await s.offer(laptop));
      },
    );

    test('a folder with a caution needs confirmation; remembering it keeps '
        'it', () async {
      final (s, picker) = await stack();
      final good = '${s.base}\\pendrive';
      final id = await openQuestion(s, laptop);
      final run = s.coordinator.chooseOtherFolder(s.sid);
      await s.cancel(laptop, id);
      s.platform.noMarkSupport = true;
      picker.answer(good);
      await run;
      final view = s.incoming!.folder!;
      expect(view.afterEnd, AfterEndResult.needsConfirmation);
      expect(view.cautionPath, good);
      expect(view.cautionNoMark, isTrue);
      expect(s.store.saved, isEmpty);

      await s.coordinator.rememberFolderAfterEnd(s.sid, remember: true);
      expect(s.incoming?.folder?.afterEnd, AfterEndResult.remembered);
      expect(s.store.saved.single.path, good);
      expect(Directory(good).existsSync(), isTrue);
    });

    test('declining the caution after the end closes the panel and removes '
        'the folder the check created', () async {
      final (s, picker) = await stack();
      final good = '${s.base}\\pendrive';
      final id = await openQuestion(s, laptop);
      final run = s.coordinator.chooseOtherFolder(s.sid);
      await s.cancel(laptop, id);
      s.platform.noMarkSupport = true;
      picker.answer(good);
      await run;
      expect(Directory(good).existsSync(), isTrue);
      await s.coordinator.rememberFolderAfterEnd(s.sid, remember: false);
      expect(s.incoming, isNull);
      expect(s.store.saved, isEmpty);
      await eventually(() => !Directory(good).existsSync());
    });

    test('a forbidden folder after the end is not usable', () async {
      final (s, picker) = await stack();
      final id = await openQuestion(s, laptop);
      final run = s.coordinator.chooseOtherFolder(s.sid);
      await s.cancel(laptop, id);
      picker.answer('${s.platform.system.startup}\\nueva');
      await run;
      expect(s.incoming?.folder?.afterEnd, AfterEndResult.notUsable);
      expect(s.store.saved, isEmpty);
      expect(
        Directory('${s.platform.system.startup}\\nueva').existsSync(),
        isFalse,
      );
    });

    test('nothing chosen after the end closes the panel', () async {
      final (s, picker) = await stack();
      final id = await openQuestion(s, laptop);
      final run = s.coordinator.chooseOtherFolder(s.sid);
      await s.cancel(laptop, id);
      picker.answer(null);
      await run;
      expect(s.incoming, isNull);
      expect(s.store.saved, isEmpty);
    });

    test('in the "this time" question nothing is remembered after the '
        'end', () async {
      final (s, picker) = await stack(
        remembered: true,
        rememberedPath: (base) => '$base\\gone\\recv',
      );
      final fresh = '${s.base}\\nueva';
      final id = await openQuestion(s, laptop);
      expect(question(s).kind, FolderQuestionKind.thisTime);
      final run = s.coordinator.chooseOtherFolder(s.sid);
      await s.cancel(laptop, id);
      expect(s.incoming?.stage, IncomingStage.ended);
      picker.answer(fresh);
      await run;
      expect(s.incoming, isNull);
      expect(s.store.saved, isEmpty);
      expect(Directory(fresh).existsSync(), isFalse);
    });

    test('20 s of sender silence with the picker open also ends it and leaves '
        'the ended panel', () async {
      final (s, picker) = await stack();
      await openQuestion(s, laptop);
      final run = s.coordinator.chooseOtherFolder(s.sid);
      s.clock.advance(const Duration(seconds: 20));
      await eventually(() => s.incoming?.stage == IncomingStage.ended);
      expect(s.events.single, isA<PeerCancelledTransfer>());
      expect(s.coordinator.busy, isTrue);
      picker.answer(null);
      await run;
      expect(s.incoming, isNull);
      expect(s.coordinator.busy, isFalse);
    });

    test('a new request while the check after the end runs replaces the panel '
        'and nothing is remembered', () async {
      final gate = Completer<void>();
      final (s, picker) = await stack();
      final fresh = '${s.base}\\nueva';
      final id = await openQuestion(s, laptop);
      final run = s.coordinator.chooseOtherFolder(s.sid);
      await s.cancel(laptop, id);
      s.platform.freeGate = gate;
      picker.answer(fresh);
      await eventually(() => s.platform.freeCalls > 0, reason: 'checking');
      expect(s.incoming?.folder?.inspecting, isTrue);
      expect(s.coordinator.busy, isFalse);

      expectWaiting(await s.offer(laptop));
      await eventually(() => s.incoming?.stage == IncomingStage.folderQuestion);
      gate.complete();
      await run;
      expect(s.store.saved, isEmpty);
      expect(s.incoming?.stage, IncomingStage.folderQuestion);
      expect(s.incoming?.folder?.afterEnd, isNull);
      await eventually(
        () => !Directory(fresh).existsSync(),
        reason: 'created folder removed',
      );
    });
  });

  group('E78 RF-238 picker open and busy', () {
    test('another request gets 409 while the picker stays open after the end, '
        'and not after it closes', () async {
      final (s, picker) = await stack();
      final id = await openQuestion(s, laptop);
      final run = s.coordinator.chooseOtherFolder(s.sid);
      await s.cancel(laptop, id);
      expect(s.coordinator.busy, isTrue);
      expectBusy(await s.offer(portatil));
      expectBusy(await s.offer(laptop));
      expect(s.incoming?.stage, IncomingStage.ended);

      picker.answer(null);
      await run;
      expect(s.coordinator.busy, isFalse);
      expectWaiting(await s.offer(portatil));
    });

    test('the ended panel itself does not make the receiver busy', () async {
      final (s, picker) = await stack();
      final id = await openQuestion(s, laptop);
      final run = s.coordinator.chooseOtherFolder(s.sid);
      await s.cancel(laptop, id);
      picker.answer('${s.base}\\nueva');
      await run;
      expect(s.incoming?.stage, IncomingStage.ended);
      expect(s.coordinator.busy, isFalse);
      expectAccepted(await s.offer(laptop));
      await waitAccepted(s);
    });
  });

  group('E161 double click', () {
    test('[SEG] two "use this" with the check held run one check and give one '
        'permit; cancel is ignored while checking', () async {
      final gate = Completer<void>();
      final (s, _) = await stack();
      final id = await openQuestion(s, laptop);
      s.platform.volumeGate = gate;

      final first = s.coordinator.useProposedFolder(s.sid);
      expect(question(s).inspecting, isTrue);
      final second = s.coordinator.useProposedFolder(s.sid);
      await second;
      s.coordinator.cancelFolderQuestion(s.sid);
      expect(question(s).inspecting, isTrue);
      await eventually(() => s.platform.volumeCalls == 1);
      await settle();
      expect(s.platform.volumeCalls, 1);

      gate.complete();
      await first;
      await waitAccepted(s);
      expect(s.platform.volumeCalls, 1);
      expect(s.store.saved, hasLength(1));
      final permit = expectAccepted(await s.wait(laptop, id));
      expect(expectAccepted(await s.wait(laptop, id)), permit);
    });

    test('two "choose another" open one picker; actions with it open are '
        'ignored', () async {
      final (s, picker) = await stack();
      await openQuestion(s, laptop);
      final first = s.coordinator.chooseOtherFolder(s.sid);
      await s.coordinator.chooseOtherFolder(s.sid);
      expect(picker.folderCalls, 1);
      final calls = s.platform.volumeCalls;
      await s.coordinator.useProposedFolder(s.sid);
      s.coordinator.cancelFolderQuestion(s.sid);
      expect(s.platform.volumeCalls, calls);
      expect(question(s).pickerOpen, isTrue);
      picker.answer(null);
      await first;
      expect(question(s).pickerOpen, isFalse);
      expect(picker.folderCalls, 1);
    });

    test('[SEG] "use anyway" twice saves once and gives one permit', () async {
      final (s, _) = await stack(configure: (p) => p.noMarkSupport = true);
      final id = await openQuestion(s, laptop);
      await s.coordinator.useProposedFolder(s.sid);
      expect(question(s).cautionPath, isNotNull);
      s.coordinator.useFolderAnyway(s.sid);
      s.coordinator.useFolderAnyway(s.sid);
      await waitAccepted(s);
      await settle();
      expect(s.store.saved, hasLength(1));
      final permit = expectAccepted(await s.wait(laptop, id));
      expect(expectAccepted(await s.wait(laptop, id)), permit);
    });

    test('a "choose another" during the check is ignored', () async {
      final gate = Completer<void>();
      final (s, picker) = await stack();
      await openQuestion(s, laptop);
      s.platform.volumeGate = gate;
      final first = s.coordinator.useProposedFolder(s.sid);
      await s.coordinator.chooseOtherFolder(s.sid);
      expect(picker.folderCalls, 0);
      gate.complete();
      await first;
      await waitAccepted(s);
    });
  });

  group('[SEG] the 10 s limit of a folder check', () {
    test('an expired check gives cannot use at once and writes nothing '
        'afterwards', () async {
      final gate = Completer<void>();
      final (s, _) = await stack();
      final proposed = proposedOf(s);
      final id = await openQuestion(s, laptop);
      s.platform.volumeGate = gate;
      final run = s.coordinator.useProposedFolder(s.sid);
      await eventually(() => s.platform.volumeCalls == 1);
      expectStillWaiting(await s.wait(laptop, id));

      s.clock.advance(const Duration(milliseconds: 9900));
      await settle();
      expect(question(s).inspecting, isTrue);
      s.clock.advance(const Duration(milliseconds: 100));
      await run;
      expect(question(s).inspecting, isFalse);
      expect(question(s).problem, FolderProblem.cannotUse);
      expect(question(s).problemPath, proposed);

      gate.complete();
      await settle(const Duration(milliseconds: 300));
      expect(Directory(proposed).existsSync(), isFalse);
      expect(s.store.saved, isEmpty);
      expect(s.incoming?.stage, IncomingStage.folderQuestion);
    });

    test('a folder created before the limit is removed when the late check '
        'finishes', () async {
      final gate = Completer<void>();
      final (s, _) = await stack();
      final proposed = proposedOf(s);
      await openQuestion(s, laptop);
      s.platform.freeGate = gate;
      final run = s.coordinator.useProposedFolder(s.sid);
      await eventually(() => s.platform.freeCalls == 1);
      expect(Directory(proposed).existsSync(), isTrue);

      s.clock.advance(const Duration(seconds: 10));
      await run;
      expect(question(s).problem, FolderProblem.cannotUse);
      gate.complete();
      await eventually(
        () => !Directory(proposed).existsSync(),
        reason: 'late folder removed',
      );
      expect(s.store.saved, isEmpty);
      expect(s.incoming?.stage, IncomingStage.folderQuestion);
    });

    test('an expired check after the end is not usable and writes '
        'nothing', () async {
      final gate = Completer<void>();
      final (s, picker) = await stack();
      final fresh = '${s.base}\\nueva';
      final id = await openQuestion(s, laptop);
      final run = s.coordinator.chooseOtherFolder(s.sid);
      await s.cancel(laptop, id);
      s.platform.volumeGate = gate;
      picker.answer(fresh);
      await eventually(() => s.platform.volumeCalls == 1);
      s.clock.advance(const Duration(seconds: 10));
      await run;
      expect(s.incoming?.folder?.afterEnd, AfterEndResult.notUsable);
      gate.complete();
      await settle(const Duration(milliseconds: 300));
      expect(Directory(fresh).existsSync(), isFalse);
      expect(s.store.saved, isEmpty);
    });
  });

  group('E199 M1 folder actions are bound to the session they were shown '
      'for', () {
    test('with an old, empty or made up id no question action does anything, '
        'and with the current one each acts', () async {
      final (s, picker) = await stack(configure: (p) => p.noMarkSupport = true);
      final proposed = proposedOf(s);
      await openQuestion(s, laptop);
      final old = s.sid;
      s.coordinator.cancelFolderQuestion(old);
      expect(s.incoming, isNull);
      expect(s.coordinator.lastReceived?.outcome, TransferOutcome.noFolder);
      final last = s.coordinator.lastReceived;

      final id = await openQuestion(s, laptop);
      final current = s.sid;
      expect(current, isNot(old));
      final stale = [
        old,
        '',
        newTransferId(),
        id,
        current.toUpperCase(),
      ].where((fake) => fake != current).toList();

      Future<void> tryStale() async {
        final view = s.incoming;
        final calls = s.platform.calls.length;
        final opened = picker.folderCalls;
        for (final fake in stale) {
          await s.coordinator.useProposedFolder(fake);
          await s.coordinator.chooseOtherFolder(fake);
          s.coordinator.useFolderAnyway(fake);
          s.coordinator.cancelFolderQuestion(fake);
          s.coordinator.cancelIncoming(fake);
          s.coordinator.answerWarning(fake, accept: true);
          s.coordinator.answerWarning(fake, accept: false);
          await s.coordinator.rememberFolderAfterEnd(fake, remember: true);
          s.coordinator.dismissFolderPanel(fake);
          expect(s.incoming, view, reason: fake);
          expect(s.platform.calls.length, calls, reason: fake);
          expect(picker.folderCalls, opened, reason: fake);
          expect(s.coordinator.pickerOpen, isFalse, reason: fake);
        }
        expect(s.store.saved, isEmpty);
        expect(identical(s.coordinator.lastReceived, last), isTrue);
      }

      await tryStale();
      expect(question(s).inspecting, isFalse);
      expect(question(s).cautionPath, isNull);
      expect(Directory(proposed).existsSync(), isFalse);
      expectStillWaiting(await s.wait(laptop, id));

      final choosing = s.coordinator.chooseOtherFolder(current);
      expect(picker.folderCalls, 1);
      expect(question(s).pickerOpen, isTrue);
      picker.answer(null);
      await choosing;
      expect(question(s).pickerOpen, isFalse);

      await s.coordinator.useProposedFolder(current);
      expect(question(s).cautionPath, proposed);
      expect(question(s).cautionNoMark, isTrue);

      await tryStale();
      expect(question(s).cautionPath, proposed);
      expectStillWaiting(await s.wait(laptop, id));

      s.coordinator.useFolderAnyway(current);
      await waitAccepted(s);
      expect(s.sid, current);
      expect(s.store.saved.single.path, proposed);
      final permit = expectAccepted(await s.wait(laptop, id));

      final accepted = s.incoming;
      for (final fake in stale) {
        s.coordinator.cancelIncoming(fake);
        expect(s.incoming, accepted, reason: fake);
      }
      expect(expectAccepted(await s.wait(laptop, id)), permit);

      s.coordinator.cancelIncoming(current);
      expect(s.incoming, isNull);
      expect(
        s.coordinator.lastReceived?.outcome,
        TransferOutcome.cancelledHere,
      );
    });

    test('the panel after the end carries its session id and only answers to '
        'it', () async {
      final (s, picker) = await stack();
      await openQuestion(s, laptop);
      final earlier = s.sid;
      s.coordinator.cancelFolderQuestion(earlier);
      final good = '${s.base}\\pendrive';

      final id = await openQuestion(s, laptop);
      final panelId = s.sid;
      expect(panelId, isNot(earlier));
      final run = s.coordinator.chooseOtherFolder(panelId);
      expect((await s.cancel(laptop, id))?.status, 200);
      expect(s.incoming?.stage, IncomingStage.ended);
      expect(s.incoming?.sessionId, panelId);
      s.platform.noMarkSupport = true;
      picker.answer(good);
      await run;

      final panel = s.incoming!;
      expect(panel.stage, IncomingStage.ended);
      expect(panel.sessionId, panelId);
      expect(panel.folder?.afterEnd, AfterEndResult.needsConfirmation);

      for (final fake in [earlier, '', newTransferId(), id]) {
        await s.coordinator.rememberFolderAfterEnd(fake, remember: true);
        expect(s.incoming, panel, reason: fake);
        await s.coordinator.rememberFolderAfterEnd(fake, remember: false);
        expect(s.incoming, panel, reason: fake);
        s.coordinator.dismissFolderPanel(fake);
        expect(s.incoming, panel, reason: fake);
      }
      expect(s.store.saved, isEmpty);
      expect(Directory(good).existsSync(), isTrue);

      await s.coordinator.rememberFolderAfterEnd(panelId, remember: true);
      expect(s.incoming?.folder?.afterEnd, AfterEndResult.remembered);
      expect(s.incoming?.sessionId, panelId);
      expect(s.store.saved.single.path, good);

      s.coordinator.dismissFolderPanel(earlier);
      expect(s.incoming?.stage, IncomingStage.ended);
      s.coordinator.dismissFolderPanel(panelId);
      expect(s.incoming, isNull);
    });

    test('a check started for one session never acts on the next '
        'one', () async {
      final gate = Completer<void>();
      final (s, _) = await stack();
      final proposed = proposedOf(s);
      final first = await openQuestion(s, laptop);
      s.platform.volumeGate = gate;
      final run = s.coordinator.useProposedFolder(s.sid);
      await eventually(() => s.platform.volumeCalls == 1, reason: 'checking');
      expect(question(s).inspecting, isTrue);
      expect((await s.cancel(laptop, first))?.status, 200);
      expect(s.incoming, isNull);
      expect(s.coordinator.busy, isFalse);
      s.platform.volumeGate = null;

      final second = await openQuestion(s, laptop);
      final view = s.incoming!;
      expect(view.folder?.inspecting, isFalse);
      gate.complete();
      await run;
      await settle(const Duration(milliseconds: 200));

      expect(s.incoming, view);
      expect(s.store.saved, isEmpty);
      expectStillWaiting(await s.wait(laptop, second));
      await eventually(
        () => !Directory(proposed).existsSync(),
        reason: 'unused folder removed',
      );
    });
  });

  group('E211 busy goes back to false after a silent end (plan point '
      '75)', () {
    void expectError(RawReply? reply, int status, String code) {
      expect(reply, isNotNull, reason: 'no reply, expected $status $code');
      expect(reply!.status, status, reason: reply.text);
      expect(reply.json, {'error': code});
    }

    Future<String> endedPanel(
      ReceiverStack s,
      HeldPicker picker,
      String folder,
    ) async {
      final id = await openQuestion(s, laptop);
      final panelId = s.sid;
      final run = s.coordinator.chooseOtherFolder(panelId);
      expect((await s.cancel(laptop, id))?.status, 200);
      picker.answer(folder);
      await run;
      expect(s.incoming?.stage, IncomingStage.ended);
      return panelId;
    }

    Future<void> expectBusyPublished(ReceiverStack s) async {
      await settle();
      expect(s.coordinator.busy, isTrue);
      expect(s.busyOnChange.last, isTrue);
      expect(s.views.last, isNull);
    }

    Future<void> expectIdlePublished(ReceiverStack s, int before) async {
      await settle();
      expect(s.coordinator.busy, isFalse);
      expect(s.busyOnChange.length, greaterThan(before));
      expect(s.busyOnChange.last, isFalse);
      expect(s.views.last, isNull);
    }

    test('path_too_long after the old panel was dismissed while '
        'checking', () async {
      final gate = Completer<void>();
      final (s, picker) = await stack();
      final good = folderIn(s, 'buena');
      final panelId = await endedPanel(s, picker, good);
      expect(s.incoming?.folder?.afterEnd, AfterEndResult.remembered);
      s.platform.volumeGate = gate;
      final calls = s.platform.volumeCalls;
      final name = '${'a' * 251}.txt';
      final pending = s.offer(laptop, name: name);
      await eventually(
        () => s.platform.volumeCalls > calls,
        reason: 'checking',
      );
      s.coordinator.dismissFolderPanel(panelId);
      await expectBusyPublished(s);
      final before = s.busyOnChange.length;

      gate.complete();
      expectError(await pending, 422, 'path_too_long');
      await expectIdlePublished(s, before);
      expect(s.coordinator.lastReceived, isNull);
    });

    test('a 410 after the old panel was dismissed while checking', () async {
      final gate = Completer<void>();
      final (s, picker) = await stack();
      final good = folderIn(s, 'buena');
      final panelId = await endedPanel(s, picker, good);
      s.platform.volumeGate = gate;
      final calls = s.platform.volumeCalls;
      final id = newTransferId();
      final pending = s.offer(portatil, transfer: id);
      await eventually(
        () => s.platform.volumeCalls > calls,
        reason: 'checking',
      );
      s.coordinator.dismissFolderPanel(panelId);
      await expectBusyPublished(s);
      final before = s.busyOnChange.length;

      expect((await s.cancel(portatil, id))?.status, 200);
      gate.complete();
      expectError(await pending, 410, 'cancelled');
      await expectIdlePublished(s, before);
    });

    test('a 503 after the old panel was remembered while waiting for the '
        'startup cleanup', () async {
      final release = Completer<void>();
      addTearDown(() {
        if (!release.isCompleted) release.complete();
      });
      final (s, picker) = await stack();
      final old = folderIn(s, 'old');
      await s.journal.add(
        ReceiveFolder(
          path: old,
          volumeId: (await realFs.volumeFacts(old))!.volumeId,
        ),
      );
      s.platform.noMarkSupport = true;
      final panelId = await endedPanel(s, picker, folderIn(s, 'pendrive'));
      expect(s.incoming?.folder?.afterEnd, AfterEndResult.needsConfirmation);
      var held = 0;
      s.platform.hold = (method, path) async {
        if (method == 'volumeFacts' && samePath(path, old)) {
          held++;
          await release.future;
        }
      };
      final cleanup = s.coordinator.cleanupAtStart();
      await eventually(() => held == 1, reason: 'cleanup held');
      var done = false;
      final pending = s.offer(laptop).whenComplete(() => done = true);
      await eventually(() => s.coordinator.busy, reason: 'offer admitted');

      await s.coordinator.rememberFolderAfterEnd(panelId, remember: true);
      expect(s.incoming?.folder?.afterEnd, AfterEndResult.remembered);
      await settle();
      expect(done, isFalse);
      expect(s.busyOnChange.last, isTrue);
      final before = s.busyOnChange.length;

      s.clock.advance(Limits.transferCleanupWait);
      expectError(await pending, 503, 'busy');
      await settle();
      expect(s.coordinator.busy, isFalse);
      expect(s.busyOnChange.length, greaterThan(before));
      expect(s.busyOnChange.last, isFalse);
      expect(s.incoming?.stage, IncomingStage.ended);

      release.complete();
      await cleanup;
    });

    test('without any change in between a silent 503 publishes '
        'nothing', () async {
      final release = Completer<void>();
      addTearDown(() {
        if (!release.isCompleted) release.complete();
      });
      final (s, _) = await stack(remembered: true);
      final old = folderIn(s, 'old');
      await s.journal.add(
        ReceiveFolder(
          path: old,
          volumeId: (await realFs.volumeFacts(old))!.volumeId,
        ),
      );
      var held = 0;
      s.platform.hold = (method, path) async {
        if (method == 'volumeFacts' && samePath(path, old)) {
          held++;
          await release.future;
        }
      };
      final cleanup = s.coordinator.cleanupAtStart();
      await eventually(() => held == 1, reason: 'cleanup held');
      final pending = s.offer(laptop);
      await eventually(() => s.coordinator.busy, reason: 'offer admitted');
      s.clock.advance(Limits.transferCleanupWait);
      expectError(await pending, 503, 'busy');
      await settle();
      expect(s.busyOnChange, isEmpty);
      expect(s.views, isEmpty);

      release.complete();
      await cleanup;
    });
  });
}

final class _RefusingStore implements ReceiveFolderStore {
  @override
  Future<ReceiveFolder?> load() async => null;

  @override
  Future<bool> save(ReceiveFolder folder) async => false;
}
