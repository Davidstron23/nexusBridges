import 'dart:io';

import 'package:nexus_bridges_core/nexus_bridges_core.dart';
import 'package:test/test.dart';

final class _NoProtector implements SecretProtector {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

Map<String, Set<String>?> _exportsOf(String source) {
  final directive = RegExp(
    r'''^\s*export\s+['"]([^'"]+)['"]([^;]*);''',
    multiLine: true,
  );
  return {
    for (final match in directive.allMatches(source))
      match.group(1)!: _shownNames(match.group(2)!),
  };
}

Set<String>? _shownNames(String combinators) {
  final show = RegExp(r'\bshow\b([^;]*)').firstMatch(combinators);
  if (show == null) return null;
  return {
    for (final name in show.group(1)!.split(','))
      if (name.trim().isNotEmpty) name.trim(),
  };
}

String _read(String path) =>
    File(path.replaceAll('/', Platform.pathSeparator)).readAsStringSync();

void main() {
  group('the root library exposes the types of NodeState', () {
    test('NodeState, NetworkPrompt and IdentityStatus', () {
      const state = NodeState(
        identityStatus: IdentityStatus.reset,
        prompts: [NetworkPrompt('{NETWORK-HOME}', 'Casa')],
      );

      expect(state.identityStatus, IdentityStatus.reset);
      expect(state.prompts.single.networkName, 'Casa');
      expect(IdentityStatus.values, hasLength(3));
    });

    test('DiscoveredDevice, DeviceInfo and DeviceType', () {
      final device = DiscoveredDevice(
        info: DeviceInfo(
          name: 'PC',
          fingerprint: 'A' * 64,
          port: 53530,
          protocol: protocolVersion,
          deviceType: DeviceType.desktop,
        ),
        address: InternetAddress('192.168.1.10'),
        interfaceId: 'eth#192.168.1.10',
        paired: false,
        lastSeen: DateTime.utc(2026, 10, 22),
      );
      final state = NodeState(devices: [device]);

      expect(state.devices.single.info.deviceType, DeviceType.desktop);
      expect(DeviceType.values, contains(DeviceType.mobile));
    });

    test('NetworkDecision, AdapterInfo and SecretProtector', () {
      final adapter = AdapterInfo(
        id: 'loopback',
        friendlyName: 'Loopback',
        description: 'Software Loopback Interface 1',
        ifType: 24,
        isUp: true,
        ipv4: const [],
        hasGateway: false,
      );
      final SecretProtector protector = _NoProtector();
      const Type protectorType = SecretProtector;

      expect(adapter.networkId, isNull);
      expect(NetworkDecision.values, [
        NetworkDecision.trusted,
        NetworkDecision.untrusted,
      ]);
      expect(protector, isA<SecretProtector>());
      expect('$protectorType', 'SecretProtector');
    });
  });

  group('the root library exposes the pairing types the app needs (T11)', () {
    test('the rows, notices, questions and the pairing view', () {
      const entry = DeviceEntry(
        fingerprint: 'F',
        displayName: 'PC',
        deviceType: DeviceType.desktop,
        visible: true,
        paired: false,
        mine: false,
        ignored: false,
        mismatch: false,
        possiblyReplaces: null,
      );
      const view = PairingView(
        role: PairingRole.receiver,
        phase: PairingPhase.comparing,
        peerFingerprint: 'F',
        peerName: 'PC',
        code: '482913',
      );
      const state = NodeState(
        entries: [entry],
        pairing: view,
        questions: [
          ReplaceQuestion(
            fingerprint: 'F',
            deviceName: 'PC',
            oldFingerprint: 'O',
            oldName: 'Old',
          ),
          MineQuestion(fingerprint: 'F', deviceName: 'PC'),
        ],
        notices: [Notice(id: 1, kind: NoticeKind.changeNotSaved)],
        unsavedChanges: true,
      );

      expect(state.entries.single.canPair, isTrue);
      expect(state.pairing!.phase, PairingPhase.comparing);
      expect(state.questions.first, isA<PairingQuestion>());
      expect(state.notices.single.canRetry, isTrue);
      expect(PairRequestResult.values, hasLength(4));
      expect(ReceiverAnswer.values, hasLength(3));
      expect(PairingOutcome.values, contains(PairingOutcome.notSaved));
    });
  });

  group('E514: the root library exposes the queues, the tray and the send '
      'results', () {
    test('SendResult, TrayResult, SelectionProgress and the outbox views fit '
        'in a NodeState', () {
      const item = QueueItemView(
        id: 'q1',
        name: 'a.txt',
        isFolder: false,
        isArchive: false,
        state: QueueItemState.done,
        outcome: TransferOutcome.saved,
      );
      const queues = SendQueuesView(
        selectionId: 1,
        peerFingerprint: 'F',
        peerName: 'PC',
        loose: [item],
        bundles: [],
        finished: true,
        delivered: 1,
        total: 1,
        completedBytes: 5,
        pendingKnownBytes: 0,
        currentProbeSize: null,
      );
      const progress = SelectionProgress(
        selectionId: 1,
        doneBytes: 5,
        totalBytes: 5,
        currentName: 'a.txt',
        currentIsFolder: false,
        finished: true,
      );
      const state = NodeState(
        queues: queues,
        tray: [TrayItemView(id: 't1', name: 'b', isFolder: true)],
        sendingTo: 'F',
        selectionProgress: progress,
      );

      expect(state.queues!.loose.single.state, QueueItemState.done);
      expect(state.tray.single.isFolder, isTrue);
      expect(state.selectionProgress!.doneBytes, 5);
      expect(state.canSendTo('F'), isFalse);
      expect(SendResult.values, [
        SendResult.started,
        SendResult.queued,
        SendResult.nothingChosen,
        SendResult.otherTargetBusy,
        SendResult.tooMany,
        SendResult.unavailable,
      ]);
      expect(TrayResult.values, [
        TrayResult.added,
        TrayResult.nothingNew,
        TrayResult.tooMany,
        TrayResult.unavailable,
      ]);
      expect(QueueItemState.values, [
        QueueItemState.pending,
        QueueItemState.inProgress,
        QueueItemState.done,
        QueueItemState.notSent,
      ]);
    });

    test('from outbox it only shows the view types', () {
      final exports = _exportsOf(_read('lib/src/node/node.dart'));

      expect(exports['../outbox/outbox.dart'], {
        'QueueItemState',
        'QueueItemView',
        'SendQueuesView',
        'TrayItemView',
      });
    });

    test('sendFile and SendFileResult are gone from the node', () {
      final node = _read('lib/src/node/node.dart');
      final state = _read('lib/src/node/node_state.dart');

      expect(node, isNot(contains('sendFile(')));
      expect(node, isNot(contains('SendFileResult')));
      expect(state, isNot(contains('SendFileResult')));
    });
  });

  group('the export list of the node module', () {
    late Map<String, Set<String>?> exports;

    setUpAll(() => exports = _exportsOf(_read('lib/src/node/node.dart')));

    test('the root library exports node.dart', () {
      final root = _exportsOf(_read('lib/nexus_bridges_core.dart'));

      expect(root.keys, contains('src/node/node.dart'));
      expect(root['src/node/node.dart'], isNull);
    });

    test('the root library shows only the startup helpers of settings', () {
      final root = _exportsOf(_read('lib/nexus_bridges_core.dart'));

      expect(root['src/settings/settings.dart'], {
        'resolveLanguage',
        'loadLanguage',
        'loadStartupSettings',
        'StartupSettings',
        'ThemeChoice',
      });
    });

    test('from discovery it only shows DiscoveredDevice', () {
      expect(exports['../discovery/discovery.dart'], {'DiscoveredDevice'});
    });

    test('from protocol it only shows DeviceInfo, DeviceType and the device '
        'name rule (spec 008, T1)', () {
      expect(exports['../protocol/protocol.dart'], {
        'DeviceInfo',
        'DeviceType',
        'DeviceNameProblem',
        'deviceNameProblem',
        'folderKey',
      });
    });

    test('the root library gives the app the device name rule and the '
        'settings view types (spec 008, T1)', () {
      const view = SettingsView(customName: 'PC David', windowsName: 'DESK');
      const result = DeviceNameResult(problem: DeviceNameProblem.tooLong);
      const state = NodeState(settings: view);

      expect(deviceNameProblem(''), DeviceNameProblem.empty);
      expect(deviceNameProblem('PC David'), isNull);
      expect(result.saved, isTrue);
      expect(state.settings.customName, 'PC David');
      expect(DeviceNameProblem.values, [
        DeviceNameProblem.empty,
        DeviceNameProblem.tooLong,
        DeviceNameProblem.invalidCharacters,
      ]);
      expect(NoticeKind.values, contains(NoticeKind.settingNotSaved));
    });

    test('from network it only shows NetworkDecision, AdapterInfo and '
        'Ipv4Subnet', () {
      expect(exports['../network/network.dart'], {
        'NetworkDecision',
        'AdapterInfo',
        'Ipv4Subnet',
      });
    });

    test('from identity it only shows SecretProtector', () {
      expect(exports['../identity/identity.dart'], {'SecretProtector'});
    });

    test('E790 from peers it only shows what the views need, never the '
        'store', () {
      expect(exports['../peers/peers.dart'], {
        'FavoriteResult',
        'HistoryDirection',
        'SavedDestination',
      });
    });

    test('E790 from browse it only shows the listing and share types', () {
      expect(exports['../browse/browse.dart'], {
        'BrowseFailure',
        'DriveKind',
        'RemoteFolders',
        'RemoteListing',
        'RemoteListingFailed',
        'RemoteRoot',
        'RemoteRoots',
        'ShareAddOutcome',
        'ShareAdded',
        'ShareNeedsConfirmation',
        'SharePickCancelled',
        'ShareRefusal',
        'ShareRefused',
        'ShareView',
      });
    });

    test('E790 the root library gives the app the types of the notes', () {
      const destination = SavedDestination(
        rootId: 'r',
        rootName: 'docs',
        path: ['sub'],
      );
      final view = PeerSettingsView(
        fingerprint: 'F',
        realName: 'PC',
        alias: 'Casa',
        mine: true,
        visible: true,
        favorites: const [destination],
        history: [
          HistoryEntryView(
            at: DateTime.utc(2026, 11, 5),
            direction: HistoryDirection.sent,
            name: 'a.txt',
            isFolder: false,
            fileCount: 0,
            itemCount: 3,
            delivered: 2,
            size: 7,
            destination: const DestinationLabel(rootName: 'docs', path: []),
            outcome: TransferOutcome.noSpace,
          ),
        ],
      );

      expect(view.favorites.single, destination);
      expect(view.history.single.delivered, 2);
      expect(FavoriteResult.values, [
        FavoriteResult.added,
        FavoriteResult.alreadyThere,
        FavoriteResult.full,
      ]);
      expect(isValidFolderName('sub'), isTrue);
      expect(folderKey('Sub'), folderKey('SUB'));
      expect(NoticeKind.values, contains(NoticeKind.peerNotesNotSaved));
      expect(
        const SharedFolderDestination(
          rootId: 'r',
          rootName: 'docs',
          path: [],
          newFolder: 'n',
        ).label.path,
        ['n'],
      );
    });

    test('exports node_state.dart and nothing else without a show list', () {
      final unrestricted = [
        for (final MapEntry(:key, :value) in exports.entries)
          if (value == null) key,
      ];

      expect(unrestricted, ['node_state.dart']);
    });

    test('does not export reconcile.dart or any other module', () {
      expect(exports.keys, isNot(contains('reconcile.dart')));
      expect(exports.keys.where((uri) => uri.startsWith('../')).toSet(), {
        '../browse/browse.dart',
        '../discovery/discovery.dart',
        '../peers/peers.dart',
        '../protocol/protocol.dart',
        '../settings/settings.dart',
        '../network/network.dart',
        '../identity/identity.dart',
        '../outbox/outbox.dart',
        '../pairing_flow/pairing_flow.dart',
        '../transfer/transfer.dart',
      });
    });

    test('from transfer it only shows the view types of the app', () {
      expect(exports['../transfer/transfer.dart'], {
        'FolderChangeResult',
        'FolderChanged',
        'FolderUnchanged',
        'FolderChangeBlocked',
        'FolderChangeRefused',
        'FolderChangeNeedsConfirmation',
        'FirstLevelItem',
        'FolderSummaryView',
        'OutgoingTransferView',
        'OutgoingPhase',
        'IncomingTransferView',
        'IncomingStage',
        'FolderQuestionView',
        'FolderQuestionKind',
        'FolderProblem',
        'AfterEndResult',
        'TransferResultView',
        'TransferDirection',
        'TransferOutcome',
        'TransferResultKind',
        'RevealResult',
        'DestinationLabel',
        'SharedFolderDestination',
        'isValidFolderName',
      });
    });

    test(
      'from pairing_flow it only shows the view types and ReceiverAnswer',
      () {
        expect(exports['../pairing_flow/pairing_flow.dart'], {
          'PairingView',
          'PairingRole',
          'PairingPhase',
          'PairingOutcome',
          'ReceiverAnswer',
        });
      },
    );

    test('node_state.dart exports nothing of its own imports', () {
      expect(_exportsOf(_read('lib/src/node/node_state.dart')), isEmpty);
    });
  });

  group(
    'E174: exports and boundaries of the spec 004 (v2, points 24 and 34)',
    () {
      final definesShortFingerprint = RegExp(
        r'^\s*String\s+shortFingerprint\s*\(',
        multiLine: true,
      );

      test('the root library does not expose SettingsStore nor the receive '
          'folder', () {
        final root = _exportsOf(_read('lib/nexus_bridges_core.dart'));
        final shown = root['src/settings/settings.dart'];

        expect(shown, isNotNull);
        expect(shown, isNot(contains('SettingsStore')));
        expect(
          shown!.where((name) => name.toLowerCase().contains('receive')),
          isEmpty,
        );
        expect(root.keys.where((uri) => uri.contains('transfer')), isEmpty);
      });

      test('shortFingerprint is defined in identity', () {
        expect(
          definesShortFingerprint.hasMatch(
            _read('lib/src/identity/identity.dart'),
          ),
          isTrue,
        );
      });

      test('discovery no longer defines nor exports shortFingerprint', () {
        final folder = Directory(
          'lib/src/discovery'.replaceAll('/', Platform.pathSeparator),
        );
        for (final file in folder.listSync().whereType<File>()) {
          expect(
            definesShortFingerprint.hasMatch(file.readAsStringSync()),
            isFalse,
            reason: file.path,
          );
        }
        final discovery = _exportsOf(_read('lib/src/discovery/discovery.dart'));
        for (final MapEntry(:key, :value) in discovery.entries) {
          expect(value, isNotNull, reason: key);
          expect(value, isNot(contains('shortFingerprint')), reason: key);
        }
      });

      test('presentation.dart takes shortFingerprint from identity', () {
        expect(
          _read('lib/src/discovery/presentation.dart'),
          contains("import '../identity/identity.dart'"),
        );
      });
    },
  );
}
