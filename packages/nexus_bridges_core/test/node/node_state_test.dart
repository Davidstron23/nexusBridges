import 'dart:io';

import 'package:nexus_bridges_core/src/discovery/discovery.dart';
import 'package:nexus_bridges_core/src/node/node_state.dart';
import 'package:nexus_bridges_core/src/outbox/outbox.dart'
    show QueueItemView, QueueItemState, SendQueuesView;
import 'package:nexus_bridges_core/src/protocol/protocol.dart';
import 'package:test/test.dart';

void main() {
  group('IdentityStatus', () {
    test('has exactly ok, reset and failed', () {
      expect(IdentityStatus.values, [
        IdentityStatus.ok,
        IdentityStatus.reset,
        IdentityStatus.failed,
      ]);
    });
  });

  group('NetworkPrompt', () {
    test('keeps the network id and name', () {
      const prompt = NetworkPrompt('{NETWORK-HOME}', 'Casa');

      expect(prompt.networkId, '{NETWORK-HOME}');
      expect(prompt.networkName, 'Casa');
    });

    test('two prompts with the same fields are equal and share a hash', () {
      final a = NetworkPrompt('{NETWORK-HOME}', 'Ca${'sa'}');
      final b = NetworkPrompt('{NETWORK-${'HOME'}}', 'Casa');

      expect(identical(a, b), isFalse);
      expect(a, b);
      expect(a.hashCode, b.hashCode);
    });

    test('a different id or name makes them different', () {
      const base = NetworkPrompt('{NETWORK-HOME}', 'Casa');

      expect(base, isNot(const NetworkPrompt('{NETWORK-WORK}', 'Casa')));
      expect(base, isNot(const NetworkPrompt('{NETWORK-HOME}', 'Oficina')));
      expect(base, isNot(const NetworkPrompt('Casa', '{NETWORK-HOME}')));
    });

    test('is not equal to other kinds of objects', () {
      const prompt = NetworkPrompt('{NETWORK-HOME}', 'Casa');
      const Object record = ('{NETWORK-HOME}', 'Casa');
      const Object text = '{NETWORK-HOME}';

      expect(prompt == record, isFalse);
      expect(prompt == text, isFalse);
    });

    test('works as a set and map key', () {
      final prompts = {
        const NetworkPrompt('{NETWORK-HOME}', 'Casa'),
        NetworkPrompt('{NETWORK-HOME}', 'Ca${'sa'}'),
        const NetworkPrompt('{NETWORK-WORK}', 'Oficina'),
      };

      expect(prompts, hasLength(2));
      expect(
        prompts.contains(NetworkPrompt('{NETWORK-${'WORK'}}', 'Oficina')),
        isTrue,
      );
    });
  });

  group('NodeState', () {
    test('every field has its default', () {
      const state = NodeState();

      expect(state.identityStatus, IdentityStatus.ok);
      expect(state.identityError, isNull);
      expect(state.prompts, isEmpty);
      expect(state.paused, isFalse);
      expect(state.pausedNetworks, isEmpty);
      expect(state.devices, isEmpty);
      expect(state.displayNames, isEmpty);
      expect(state.suggestRescan, isFalse);
      expect(state.portInUse, isNull);
      expect(state.decisionNotSaved, isFalse);
      expect(state.deviceName, '');
      expect(state.fingerprint, '');
    });

    test('the default collections are constant and cannot be changed', () {
      const state = NodeState();

      expect(
        () => state.prompts.add(const NetworkPrompt('a', 'b')),
        throwsUnsupportedError,
      );
      expect(
        () => state.pausedNetworks.add(const NetworkPrompt('a', 'b')),
        throwsUnsupportedError,
      );
      expect(() => state.displayNames['a'] = 'b', throwsUnsupportedError);
      expect(identical(state.prompts, const NodeState().prompts), isTrue);
    });

    test('keeps every field it is given', () {
      final device = DiscoveredDevice(
        info: DeviceInfo(
          name: 'PC',
          fingerprint: 'A' * 64,
          port: defaultPort,
          protocol: protocolVersion,
          deviceType: DeviceType.desktop,
        ),
        address: InternetAddress('192.168.1.10'),
        interfaceId: 'eth#192.168.1.10',
        paired: true,
        lastSeen: DateTime.utc(2026, 10, 22),
      );
      final state = NodeState(
        identityStatus: IdentityStatus.failed,
        identityError: 'identity unavailable',
        prompts: const [NetworkPrompt('{NETWORK-HOME}', 'Casa')],
        paused: true,
        pausedNetworks: const [NetworkPrompt('{NETWORK-CAFE}', 'Cafe')],
        devices: [device],
        displayNames: {'A' * 64: 'PC'},
        suggestRescan: true,
        portInUse: 53530,
        decisionNotSaved: true,
        deviceName: 'David PC',
        fingerprint: 'B' * 64,
      );

      expect(state.identityStatus, IdentityStatus.failed);
      expect(state.identityError, 'identity unavailable');
      expect(state.prompts, [const NetworkPrompt('{NETWORK-HOME}', 'Casa')]);
      expect(state.paused, isTrue);
      expect(state.pausedNetworks, [
        const NetworkPrompt('{NETWORK-CAFE}', 'Cafe'),
      ]);
      expect(state.devices.single, same(device));
      expect(state.displayNames, {'A' * 64: 'PC'});
      expect(state.suggestRescan, isTrue);
      expect(state.portInUse, 53530);
      expect(state.decisionNotSaved, isTrue);
      expect(state.deviceName, 'David PC');
      expect(state.fingerprint, 'B' * 64);
    });

    test('RF-14: decisionNotSaved is a field of the state', () {
      const saved = NodeState();
      const notSaved = NodeState(decisionNotSaved: true);

      expect(saved.decisionNotSaved, isFalse);
      expect(notSaved.decisionNotSaved, isTrue);
    });
  });

  group('E527, RF-249, RF-290: canSendTo', () {
    const b = 'BBBBBBBB';
    const c = 'CCCCCCCC';

    DeviceEntry entry(
      String fingerprint, {
      bool visible = true,
      bool paired = true,
      bool mismatch = false,
    }) => DeviceEntry(
      fingerprint: fingerprint,
      displayName: 'PC',
      deviceType: DeviceType.desktop,
      visible: visible,
      paired: paired,
      mine: true,
      ignored: false,
      mismatch: mismatch,
      possiblyReplaces: null,
    );

    bool canSend({
      bool visible = true,
      bool paired = true,
      bool mismatch = false,
      bool pickerOpen = false,
      String? sendingTo,
      String to = b,
    }) => NodeState(
      entries: [
        entry(b, visible: visible, paired: paired, mismatch: mismatch),
        entry(c),
      ],
      pickerOpen: pickerOpen,
      sendingTo: sendingTo,
    ).canSendTo(to);

    test('every combination of visible, paired, mismatch, picker and the '
        'current target', () {
      for (final visible in [true, false]) {
        for (final paired in [true, false]) {
          for (final mismatch in [true, false]) {
            for (final pickerOpen in [true, false]) {
              for (final sendingTo in <String?>[null, b, c]) {
                final expected =
                    visible &&
                    paired &&
                    !mismatch &&
                    !pickerOpen &&
                    (sendingTo == null || sendingTo == b);
                expect(
                  canSend(
                    visible: visible,
                    paired: paired,
                    mismatch: mismatch,
                    pickerOpen: pickerOpen,
                    sendingTo: sendingTo,
                  ),
                  expected,
                  reason:
                      'visible $visible, paired $paired, mismatch $mismatch, '
                      'picker $pickerOpen, sendingTo $sendingTo',
                );
              }
            }
          }
        }
      }
    });

    test('a device with queues running to it can still be sent to and the '
        'others cannot', () {
      expect(canSend(sendingTo: b), isTrue);
      expect(canSend(sendingTo: b, to: c), isFalse);
      expect(canSend(sendingTo: c, to: c), isTrue);
    });

    test('a fingerprint without a row is never available', () {
      expect(canSend(to: 'FFFFFFFF'), isFalse);
      expect(const NodeState().canSendTo(b), isFalse);
    });

    test('the default state has no queues, an empty tray, no target and no '
        'selection progress', () {
      const state = NodeState();

      expect(state.queues, isNull);
      expect(state.tray, isEmpty);
      expect(state.sendingTo, isNull);
      expect(state.selectionProgress, isNull);
    });
  });

  group('E577: SelectionProgress and the queue views compare by value', () {
    SelectionProgress progress({int done = 5, bool finished = false}) =>
        SelectionProgress(
          selectionId: 1,
          doneBytes: done,
          totalBytes: 10,
          currentName: 'a.txt',
          currentIsFolder: false,
          finished: finished,
        );

    SendQueuesView view(QueueItemState state) => SendQueuesView(
      selectionId: 1,
      peerFingerprint: 'BBBBBBBB',
      peerName: 'PC',
      loose: [
        QueueItemView(
          id: 'q1',
          name: 'a.txt',
          isFolder: false,
          isArchive: false,
          state: state,
        ),
      ],
      bundles: const [],
      finished: false,
      delivered: 0,
      total: 1,
      completedBytes: 0,
      pendingKnownBytes: 5,
      currentProbeSize: null,
    );

    test('equal fields are equal and share a hash; a changed field is not '
        'equal', () {
      expect(progress(), progress());
      expect(progress().hashCode, progress().hashCode);
      expect(progress(), isNot(progress(done: 6)));
      expect(progress(), isNot(progress(finished: true)));
      expect(view(QueueItemState.pending), view(QueueItemState.pending));
      expect(
        view(QueueItemState.pending),
        isNot(view(QueueItemState.inProgress)),
      );
    });
  });
}
