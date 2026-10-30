import 'dart:io';

import 'package:nexus_bridges_core/src/network/network.dart';
import 'package:nexus_bridges_core/src/node/node_state.dart';
import 'package:nexus_bridges_core/src/node/reconcile.dart';
import 'package:test/test.dart';

const String _home = '{NETWORK-HOME}';
const String _work = '{NETWORK-WORK}';
const String _cafe = '{NETWORK-CAFE}';

const String _wifiId = '{11111111-AAAA-BBBB-CCCC-000000000001}';
const String _ethernetId = '{11111111-AAAA-BBBB-CCCC-000000000002}';
const String _dockId = '{11111111-AAAA-BBBB-CCCC-000000000003}';

Ipv4Subnet _subnet(String address, int prefixLength) =>
    Ipv4Subnet(InternetAddress(address), prefixLength);

AdapterInfo _adapter({
  String id = _wifiId,
  String friendlyName = 'Wi-Fi',
  String description = 'Intel(R) Wi-Fi 6 AX201 160MHz',
  int ifType = 71,
  bool isUp = true,
  String address = '192.168.50.21',
  int prefixLength = 24,
  List<Ipv4Subnet>? ipv4,
  bool hasGateway = true,
  String? networkId = _home,
  String? networkName = 'Casa',
}) => AdapterInfo(
  id: id,
  friendlyName: friendlyName,
  description: description,
  ifType: ifType,
  isUp: isUp,
  ipv4: ipv4 ?? [_subnet(address, prefixLength)],
  hasGateway: hasGateway,
  networkId: networkId,
  networkName: networkName,
);

NetworkDecision? Function(String) _decisions(
  Map<String, NetworkDecision> byId,
) =>
    (networkId) => byId[networkId];

NetworkPlan _plan(
  List<AdapterInfo> adapters, {
  Map<String, NetworkDecision> decisions = const {},
  Set<String> dismissed = const {},
  Set<String> asking = const {},
  List<ActiveInterface> Function(List<InterfaceState>)? activeOf,
}) => activeOf == null
    ? reconcileNetworks(
        adapters: adapters,
        decisionOf: _decisions(decisions),
        dismissed: dismissed,
        asking: asking,
      )
    : reconcileNetworks(
        adapters: adapters,
        decisionOf: _decisions(decisions),
        dismissed: dismissed,
        asking: asking,
        activeOf: activeOf,
      );

List<String> _activeIds(NetworkPlan plan) => [
  for (final iface in plan.active) iface.id,
];

List<String> _ids(List<NetworkPrompt> prompts) => [
  for (final prompt in prompts) prompt.networkId,
];

void main() {
  group('RF-11: a usable network without a decision', () {
    test('is asked about and nothing is active', () {
      final plan = _plan([_adapter()]);

      expect(plan.prompts, [const NetworkPrompt(_home, 'Casa')]);
      expect(plan.active, isEmpty);
      expect(plan.pausedNetworks, isEmpty);
      expect(plan.paused, isTrue);
    });

    test('adapters that are not usable are never asked about', () {
      final plan = _plan([
        _adapter(id: _wifiId, isUp: false),
        _adapter(
          id: _ethernetId,
          ifType: 24,
          address: '127.0.0.1',
          prefixLength: 8,
        ),
        _adapter(id: _dockId, networkId: null, networkName: null),
        _adapter(id: '{VPN}', address: '169.254.10.20', prefixLength: 16),
        _adapter(
          id: '{HYPERV}',
          description: 'Hyper-V Virtual Ethernet Adapter',
          hasGateway: false,
          networkId: _work,
        ),
      ]);

      expect(plan.prompts, isEmpty);
      expect(plan.pausedNetworks, isEmpty);
      expect(plan.active, isEmpty);
      expect(plan.paused, isTrue);
    });
  });

  group('trusted networks', () {
    test('a trusted network is active and is not asked about', () {
      final plan = _plan(
        [_adapter()],
        decisions: {_home: NetworkDecision.trusted},
      );

      expect(_activeIds(plan), ['$_wifiId#192.168.50.21']);
      expect(plan.active.single.adapterId, _wifiId);
      expect(plan.active.single.friendlyName, 'Wi-Fi');
      expect(plan.active.single.subnet, _subnet('192.168.50.21', 24));
      expect(plan.prompts, isEmpty);
      expect(plan.pausedNetworks, isEmpty);
      expect(plan.paused, isFalse);
    });

    test('a trusted network in dismissed or asking stays active and '
        'silent', () {
      final plan = _plan(
        [_adapter()],
        decisions: {_home: NetworkDecision.trusted},
        dismissed: {_home},
        asking: {_home},
      );

      expect(_activeIds(plan), ['$_wifiId#192.168.50.21']);
      expect(plan.prompts, isEmpty);
      expect(plan.pausedNetworks, isEmpty);
      expect(plan.paused, isFalse);
    });
  });

  group('RF-15: networks are told apart by networkId, not by name', () {
    test('same name, different id, one trusted: one active and the other '
        'asked about', () {
      final plan = _plan(
        [
          _adapter(id: _wifiId, networkId: _home, networkName: 'Casa'),
          _adapter(
            id: _ethernetId,
            friendlyName: 'Ethernet',
            address: '10.0.0.5',
            networkId: _work,
            networkName: 'Casa',
          ),
        ],
        decisions: {_home: NetworkDecision.trusted},
      );

      expect(_activeIds(plan), ['$_wifiId#192.168.50.21']);
      expect(plan.prompts, [const NetworkPrompt(_work, 'Casa')]);
      expect(plan.pausedNetworks, isEmpty);
      expect(plan.paused, isFalse);
    });

    test('a decision about one id does not leak to another id with the '
        'same name', () {
      final plan = _plan(
        [
          _adapter(id: _wifiId, networkId: _home, networkName: 'Casa'),
          _adapter(
            id: _ethernetId,
            address: '10.0.0.5',
            networkId: _work,
            networkName: 'Casa',
          ),
        ],
        decisions: {_work: NetworkDecision.untrusted},
      );

      expect(plan.prompts, [const NetworkPrompt(_home, 'Casa')]);
      expect(plan.pausedNetworks, [const NetworkPrompt(_work, 'Casa')]);
      expect(plan.active, isEmpty);
    });
  });

  group('RF-16 and RF-18: an untrusted network', () {
    test('is not active, is not asked about and is listed as paused', () {
      final plan = _plan(
        [_adapter()],
        decisions: {_home: NetworkDecision.untrusted},
      );

      expect(plan.active, isEmpty);
      expect(plan.prompts, isEmpty);
      expect(plan.pausedNetworks, [const NetworkPrompt(_home, 'Casa')]);
      expect(plan.paused, isTrue);
    });

    test('never gives an active interface, whatever its sets say', () {
      for (final dismissed in [
        <String>{},
        {_home},
      ]) {
        for (final asking in [
          <String>{},
          {_home},
        ]) {
          final plan = _plan(
            [_adapter()],
            decisions: {_home: NetworkDecision.untrusted},
            dismissed: dismissed,
            asking: asking,
          );
          expect(plan.active, isEmpty, reason: '$dismissed $asking');
        }
      }
    });
  });

  group('RF-13: closing the question and asking again', () {
    test('a dismissed network leaves prompts and goes to pausedNetworks', () {
      final plan = _plan([_adapter()], dismissed: {_home});

      expect(plan.prompts, isEmpty);
      expect(plan.pausedNetworks, [const NetworkPrompt(_home, 'Casa')]);
      expect(plan.active, isEmpty);
      expect(plan.paused, isTrue);
    });

    test('a network in asking is asked about again and is not paused', () {
      final plan = _plan([_adapter()], asking: {_home});

      expect(plan.prompts, [const NetworkPrompt(_home, 'Casa')]);
      expect(plan.pausedNetworks, isEmpty);
    });

    test('asking wins over dismissed', () {
      final plan = _plan([_adapter()], dismissed: {_home}, asking: {_home});

      expect(plan.prompts, [const NetworkPrompt(_home, 'Casa')]);
      expect(plan.pausedNetworks, isEmpty);
    });

    test('an untrusted network in asking is asked about again', () {
      final plan = _plan(
        [_adapter()],
        decisions: {_home: NetworkDecision.untrusted},
        asking: {_home},
      );

      expect(plan.prompts, [const NetworkPrompt(_home, 'Casa')]);
      expect(plan.pausedNetworks, isEmpty);
      expect(plan.active, isEmpty);
      expect(plan.paused, isTrue);
    });

    test('dismissing one network does not touch the others', () {
      final plan = _plan(
        [
          _adapter(id: _wifiId, networkId: _home, networkName: 'Casa'),
          _adapter(
            id: _ethernetId,
            address: '10.0.0.5',
            networkId: _work,
            networkName: 'Oficina',
          ),
        ],
        dismissed: {_home},
      );

      expect(plan.prompts, [const NetworkPrompt(_work, 'Oficina')]);
      expect(plan.pausedNetworks, [const NetworkPrompt(_home, 'Casa')]);
    });

    test('ids in dismissed or asking that are not connected add nothing', () {
      final plan = _plan(
        [_adapter()],
        dismissed: {_cafe},
        asking: {_work, _cafe},
      );

      expect(plan.prompts, [const NetworkPrompt(_home, 'Casa')]);
      expect(plan.pausedNetworks, isEmpty);
    });
  });

  group('every combination of decision, dismissed and asking', () {
    const decisions = <NetworkDecision?>[
      null,
      NetworkDecision.trusted,
      NetworkDecision.untrusted,
    ];

    for (final decision in decisions) {
      for (final isDismissed in [false, true]) {
        for (final isAsking in [false, true]) {
          test('decision $decision, dismissed $isDismissed, asking '
              '$isAsking', () {
            final plan = _plan(
              [_adapter()],
              decisions: {_home: ?decision},
              dismissed: {if (isDismissed) _home},
              asking: {if (isAsking) _home},
            );

            final expectActive = decision == NetworkDecision.trusted;
            final expectPrompt =
                !expectActive &&
                (isAsking || (decision == null && !isDismissed));
            final expectPaused = !expectActive && !expectPrompt;

            expect(plan.active.isNotEmpty, expectActive);
            expect(_ids(plan.prompts), expectPrompt ? [_home] : isEmpty);
            expect(_ids(plan.pausedNetworks), expectPaused ? [_home] : isEmpty);
            expect(plan.paused, !expectActive);
            expect(
              _ids(plan.prompts)
                  .toSet()
                  .intersection(_ids(plan.pausedNetworks).toSet()),
              isEmpty,
            );
          });
        }
      }
    }
  });

  group('RF-19: paused when nothing is active', () {
    test('all untrusted or dismissed: paused with all of them listed', () {
      final plan = _plan(
        [
          _adapter(id: _wifiId, networkId: _home, networkName: 'Casa'),
          _adapter(
            id: _ethernetId,
            address: '10.0.0.5',
            networkId: _work,
            networkName: 'Oficina',
          ),
          _adapter(
            id: _dockId,
            address: '172.16.0.9',
            networkId: _cafe,
            networkName: 'Cafe',
          ),
        ],
        decisions: {
          _home: NetworkDecision.untrusted,
          _work: NetworkDecision.untrusted,
        },
        dismissed: {_cafe},
      );

      expect(plan.paused, isTrue);
      expect(plan.active, isEmpty);
      expect(plan.prompts, isEmpty);
      expect(
        plan.pausedNetworks,
        unorderedEquals([
          const NetworkPrompt(_home, 'Casa'),
          const NetworkPrompt(_work, 'Oficina'),
          const NetworkPrompt(_cafe, 'Cafe'),
        ]),
      );
    });

    test('with one active network it is not paused', () {
      final plan = _plan(
        [
          _adapter(id: _wifiId, networkId: _home, networkName: 'Casa'),
          _adapter(
            id: _ethernetId,
            address: '10.0.0.5',
            networkId: _work,
            networkName: 'Oficina',
          ),
        ],
        decisions: {
          _home: NetworkDecision.trusted,
          _work: NetworkDecision.untrusted,
        },
      );

      expect(plan.paused, isFalse);
      expect(_activeIds(plan), ['$_wifiId#192.168.50.21']);
      expect(plan.pausedNetworks, [const NetworkPrompt(_work, 'Oficina')]);
    });

    test('without any adapter it is paused with nothing to offer', () {
      final plan = _plan(const []);

      expect(plan.paused, isTrue);
      expect(plan.active, isEmpty);
      expect(plan.prompts, isEmpty);
      expect(plan.pausedNetworks, isEmpty);
    });
  });

  group('RF-21: the plan follows the inputs of each call', () {
    test('a new decision changes the plan in the same call', () {
      final adapters = [_adapter()];

      final before = _plan(adapters);
      final trusted = _plan(
        adapters,
        decisions: {_home: NetworkDecision.trusted},
      );
      final untrusted = _plan(
        adapters,
        decisions: {_home: NetworkDecision.untrusted},
      );

      expect(before.active, isEmpty);
      expect(_ids(before.prompts), [_home]);
      expect(_activeIds(trusted), ['$_wifiId#192.168.50.21']);
      expect(trusted.prompts, isEmpty);
      expect(untrusted.active, isEmpty);
      expect(_ids(untrusted.pausedNetworks), [_home]);
    });

    test('the same Wi-Fi joining another network uses that network\'s '
        'decision', () {
      final decisions = {_home: NetworkDecision.trusted};

      final atHome = _plan([_adapter()], decisions: decisions);
      final elsewhere = _plan([
        _adapter(networkId: _cafe, networkName: 'Cafe'),
      ], decisions: decisions);

      expect(_activeIds(atHome), ['$_wifiId#192.168.50.21']);
      expect(elsewhere.active, isEmpty);
      expect(elsewhere.paused, isTrue);
      expect(elsewhere.prompts, [const NetworkPrompt(_cafe, 'Cafe')]);
    });

    test('an adapter that disconnects disappears from the plan', () {
      final decisions = {_home: NetworkDecision.trusted};

      final connected = _plan([_adapter()], decisions: decisions);
      final disconnected = _plan([_adapter(isUp: false)], decisions: decisions);

      expect(connected.active, hasLength(1));
      expect(disconnected.active, isEmpty);
      expect(disconnected.prompts, isEmpty);
      expect(disconnected.pausedNetworks, isEmpty);
      expect(disconnected.paused, isTrue);
    });

    test('decisionOf is asked by networkId', () {
      final asked = <String>[];
      reconcileNetworks(
        adapters: [
          _adapter(id: _wifiId, networkId: _home),
          _adapter(id: _ethernetId, address: '10.0.0.5', networkId: _work),
        ],
        decisionOf: (networkId) {
          asked.add(networkId);
          return null;
        },
        dismissed: const {},
        asking: const {},
      );

      expect(asked.toSet(), {_home, _work});
    });
  });

  group('several adapters on the same network', () {
    List<AdapterInfo> twoOnHome({String? secondName = 'Casa'}) => [
      _adapter(id: _wifiId),
      _adapter(
        id: _ethernetId,
        friendlyName: 'Ethernet',
        address: '192.168.50.30',
        networkName: secondName,
      ),
    ];

    test('give a single prompt', () {
      final plan = _plan(twoOnHome());

      expect(plan.prompts, [const NetworkPrompt(_home, 'Casa')]);
    });

    test('give a single paused network', () {
      final plan = _plan(
        twoOnHome(),
        decisions: {_home: NetworkDecision.untrusted},
      );

      expect(plan.pausedNetworks, [const NetworkPrompt(_home, 'Casa')]);
    });

    test('are all active when the network is trusted', () {
      final plan = _plan(
        twoOnHome(),
        decisions: {_home: NetworkDecision.trusted},
      );

      expect(_activeIds(plan), [
        '$_wifiId#192.168.50.21',
        '$_ethernetId#192.168.50.30',
      ]);
      expect(plan.prompts, isEmpty);
    });

    test('the prompt takes its name from the first adapter', () {
      final plan = _plan(twoOnHome(secondName: 'Otra'));

      expect(plan.prompts, [const NetworkPrompt(_home, 'Casa')]);
    });
  });

  group('the network name shown in a prompt', () {
    test('a name with U+202E comes out without it', () {
      final plan = _plan([_adapter(networkName: 'Casa\u202Egnp.exe')]);

      expect(plan.prompts.single.networkName, 'Casagnp.exe');
      expect(plan.prompts.single.networkName.runes, isNot(contains(0x202E)));
    });

    test('invisible and control characters are removed from paused names '
        'too', () {
      final plan = _plan(
        [_adapter(networkName: '\u200BCasa\u0007\uFEFF')],
        decisions: {_home: NetworkDecision.untrusted},
      );

      expect(plan.pausedNetworks.single.networkName, 'Casa');
    });

    test('a very long name is cut to 64 characters', () {
      final plan = _plan([_adapter(networkName: 'R' * 80)]);

      expect(plan.prompts.single.networkName, 'R' * 64);
    });

    test('without networkName it uses the friendlyName', () {
      final plan = _plan([_adapter(networkName: null)]);

      expect(plan.prompts.single, const NetworkPrompt(_home, 'Wi-Fi'));
    });

    test('a networkName with only invisible characters uses the '
        'friendlyName', () {
      final plan = _plan([_adapter(networkName: '\u200B\u202E  \uFEFF')]);

      expect(plan.prompts.single.networkName, 'Wi-Fi');
    });

    test('the friendlyName is cleaned as well', () {
      final plan = _plan([
        _adapter(networkName: null, friendlyName: 'Wi-Fi\u202E 2'),
      ]);

      expect(plan.prompts.single.networkName, 'Wi-Fi 2');
    });

    test('with neither name usable it falls back to the networkId', () {
      final plan = _plan([
        _adapter(networkName: '\u200B', friendlyName: '\u202E\u0000 '),
      ]);

      expect(plan.prompts.single, const NetworkPrompt(_home, _home));
      expect(plan.prompts.single.networkName, isNotEmpty);
    });
  });

  group('activeOf', () {
    test('an injected activeOf replaces the default one', () {
      final injected = ActiveInterface(
        id: 'loopback#127.0.0.1',
        adapterId: 'loopback',
        friendlyName: 'Loopback Pseudo-Interface 1',
        subnet: _subnet('127.0.0.1', 8),
      );
      List<InterfaceState>? received;

      final plan = _plan(
        [_adapter()],
        activeOf: (states) {
          received = states;
          return [injected];
        },
      );

      expect(plan.active, [same(injected)]);
      expect(plan.paused, isFalse);
      expect(received, hasLength(1));
      expect(received!.single.status, InterfaceStatus.undecided);
      expect(received!.single.adapter.id, _wifiId);
      expect(plan.prompts, [const NetworkPrompt(_home, 'Casa')]);
    });

    test('an injected activeOf that returns nothing pauses even a trusted '
        'network', () {
      final plan = _plan(
        [_adapter()],
        decisions: {_home: NetworkDecision.trusted},
        activeOf: (_) => const [],
      );

      expect(plan.active, isEmpty);
      expect(plan.paused, isTrue);
    });

    test('by default it is activeInterfaces', () {
      final adapters = [
        _adapter(
          ipv4: [_subnet('192.168.50.21', 24), _subnet('169.254.3.4', 16)],
        ),
      ];
      final decisionOf = _decisions({_home: NetworkDecision.trusted});

      final plan = reconcileNetworks(
        adapters: adapters,
        decisionOf: decisionOf,
        dismissed: const {},
        asking: const {},
      );
      final expected = activeInterfaces(
        evaluateInterfaces(adapters, decisionOf),
      );

      expect(_activeIds(plan), [for (final iface in expected) iface.id]);
      expect(_activeIds(plan), ['$_wifiId#192.168.50.21']);
    });
  });

  group('E252: trusted networks in use (RF-247)', () {
    ActiveInterface activeOn(String adapterId, String address) =>
        ActiveInterface(
          id: '$adapterId#$address',
          adapterId: adapterId,
          friendlyName: 'Loopback',
          subnet: _subnet(address, 32),
        );

    test('a trusted network on two adapters, an undecided one, a paused one '
        'and an adapter without networkId give a single entry', () {
      final plan = _plan(
        [
          _adapter(id: _wifiId),
          _adapter(
            id: _ethernetId,
            friendlyName: 'Ethernet',
            address: '192.168.50.30',
          ),
          _adapter(
            id: _dockId,
            address: '10.0.0.5',
            networkId: _work,
            networkName: 'Oficina',
          ),
          _adapter(
            id: '{CAFE-ADAPTER}',
            address: '172.16.0.9',
            networkId: _cafe,
            networkName: 'Cafe',
          ),
          _adapter(
            id: '{NO-NETWORK}',
            address: '10.9.0.4',
            networkId: null,
            networkName: null,
          ),
        ],
        decisions: {
          _home: NetworkDecision.trusted,
          _cafe: NetworkDecision.untrusted,
        },
      );

      expect(plan.activeNetworks, [const NetworkPrompt(_home, 'Casa')]);
      expect(_activeIds(plan), [
        '$_wifiId#192.168.50.21',
        '$_ethernetId#192.168.50.30',
      ]);
      expect(plan.prompts, [const NetworkPrompt(_work, 'Oficina')]);
      expect(plan.pausedNetworks, [const NetworkPrompt(_cafe, 'Cafe')]);
      expect(plan.paused, isFalse);
    });

    test('one adapter with two addresses on a trusted network gives one '
        'entry', () {
      final plan = _plan(
        [
          _adapter(
            ipv4: [_subnet('192.168.50.21', 24), _subnet('192.168.50.22', 24)],
          ),
        ],
        decisions: {_home: NetworkDecision.trusted},
      );

      expect(plan.active, hasLength(2));
      expect(plan.activeNetworks, [const NetworkPrompt(_home, 'Casa')]);
    });

    test('two trusted networks give two entries in the order of the active '
        'interfaces', () {
      final adapters = [
        _adapter(id: _wifiId, networkId: _home, networkName: 'Casa'),
        _adapter(
          id: _ethernetId,
          address: '10.0.0.5',
          networkId: _work,
          networkName: 'Oficina',
        ),
      ];
      final decisions = {
        _home: NetworkDecision.trusted,
        _work: NetworkDecision.trusted,
      };

      final natural = _plan(adapters, decisions: decisions);
      final reversed = _plan(
        adapters,
        decisions: decisions,
        activeOf: (states) => activeInterfaces(states).reversed.toList(),
      );

      expect(natural.activeNetworks, [
        const NetworkPrompt(_home, 'Casa'),
        const NetworkPrompt(_work, 'Oficina'),
      ]);
      expect(reversed.activeNetworks, [
        const NetworkPrompt(_work, 'Oficina'),
        const NetworkPrompt(_home, 'Casa'),
      ]);
    });

    test('two adapters on the same trusted network take the name of the first '
        'active interface', () {
      final plan = _plan(
        [
          _adapter(id: _wifiId, networkName: 'Casa'),
          _adapter(
            id: _ethernetId,
            address: '192.168.50.30',
            networkName: 'Otra',
          ),
        ],
        decisions: {_home: NetworkDecision.trusted},
      );

      expect(plan.activeNetworks, [const NetworkPrompt(_home, 'Casa')]);
    });

    test('the name is cleaned like in the prompts', () {
      final decisions = {_home: NetworkDecision.trusted};

      final bidi = _plan([
        _adapter(networkName: 'Casa\u202Egnp.exe'),
      ], decisions: decisions);
      final invisible = _plan([
        _adapter(networkName: '\u200BCasa\u0007\uFEFF'),
      ], decisions: decisions);
      final long = _plan([
        _adapter(networkName: 'R' * 80),
      ], decisions: decisions);

      expect(bidi.activeNetworks, [const NetworkPrompt(_home, 'Casagnp.exe')]);
      expect(
        bidi.activeNetworks.single.networkName.runes,
        isNot(contains(0x202E)),
      );
      expect(invisible.activeNetworks, [const NetworkPrompt(_home, 'Casa')]);
      expect(long.activeNetworks, [NetworkPrompt(_home, 'R' * 64)]);
    });

    test('without a usable network name it falls back to the friendlyName and '
        'then to the networkId', () {
      final decisions = {_home: NetworkDecision.trusted};

      final friendly = _plan([
        _adapter(networkName: null, friendlyName: 'Wi-Fi\u202E 2'),
      ], decisions: decisions);
      final bare = _plan([
        _adapter(networkName: '\u200B', friendlyName: '\u202E\u0000 '),
      ], decisions: decisions);

      expect(friendly.activeNetworks, [const NetworkPrompt(_home, 'Wi-Fi 2')]);
      expect(bare.activeNetworks, [const NetworkPrompt(_home, _home)]);
    });

    test('active interfaces without a known adapter or whose adapter has no '
        'networkId are left out', () {
      final plan = _plan(
        [
          _adapter(id: _wifiId),
          _adapter(
            id: _dockId,
            address: '10.9.0.4',
            networkId: null,
            networkName: 'Sin red',
          ),
        ],
        decisions: {_home: NetworkDecision.trusted},
        activeOf: (states) => [
          activeOn('{GHOST-ADAPTER}', '127.0.0.3'),
          activeOn(_dockId, '127.0.0.4'),
          activeOn(_wifiId, '127.0.0.1'),
        ],
      );

      expect(plan.active, hasLength(3));
      expect(plan.activeNetworks, [const NetworkPrompt(_home, 'Casa')]);
    });

    test('only unknown interfaces give an empty list although nothing is '
        'paused', () {
      final plan = _plan(
        [_adapter()],
        decisions: {_home: NetworkDecision.trusted},
        activeOf: (_) => [activeOn('{GHOST-ADAPTER}', '127.0.0.3')],
      );

      expect(plan.paused, isFalse);
      expect(plan.activeNetworks, isEmpty);
    });

    test('paused, the list is empty', () {
      final undecided = _plan([_adapter()]);
      final untrusted = _plan(
        [_adapter()],
        decisions: {_home: NetworkDecision.untrusted},
      );
      final dismissed = _plan([_adapter()], dismissed: {_home});
      final none = _plan(const []);
      final blocked = _plan(
        [_adapter()],
        decisions: {_home: NetworkDecision.trusted},
        activeOf: (_) => const [],
      );

      for (final plan in [undecided, untrusted, dismissed, none, blocked]) {
        expect(plan.paused, isTrue);
        expect(plan.activeNetworks, isEmpty);
      }
    });

    test('an untrusted network in asking is not in use', () {
      final plan = _plan(
        [
          _adapter(id: _wifiId),
          _adapter(
            id: _ethernetId,
            address: '10.0.0.5',
            networkId: _work,
            networkName: 'Oficina',
          ),
        ],
        decisions: {
          _home: NetworkDecision.trusted,
          _work: NetworkDecision.untrusted,
        },
        asking: {_work},
      );

      expect(plan.activeNetworks, [const NetworkPrompt(_home, 'Casa')]);
      expect(plan.prompts, [const NetworkPrompt(_work, 'Oficina')]);
    });
  });
}
