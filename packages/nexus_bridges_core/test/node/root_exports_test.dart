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

  group('the export list of the node module', () {
    late Map<String, Set<String>?> exports;

    setUpAll(() => exports = _exportsOf(_read('lib/src/node/node.dart')));

    test('the root library exports node.dart', () {
      final root = _exportsOf(_read('lib/nexus_bridges_core.dart'));

      expect(root.keys, contains('src/node/node.dart'));
      expect(root['src/node/node.dart'], isNull);
    });

    test('from discovery it only shows DiscoveredDevice', () {
      expect(exports['../discovery/discovery.dart'], {'DiscoveredDevice'});
    });

    test('from protocol it only shows DeviceInfo and DeviceType', () {
      expect(exports['../protocol/protocol.dart'], {
        'DeviceInfo',
        'DeviceType',
      });
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
        '../discovery/discovery.dart',
        '../protocol/protocol.dart',
        '../network/network.dart',
        '../identity/identity.dart',
        '../pairing_flow/pairing_flow.dart',
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
}
