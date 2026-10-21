import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:nexus_bridges_core/src/network/network.dart';
import 'package:test/test.dart';

InternetAddress ip(String address) => InternetAddress(address);

Ipv4Subnet subnet(String address, int prefixLength) =>
    Ipv4Subnet(InternetAddress(address), prefixLength);

AdapterInfo adapter({
  String id = '{11111111-AAAA-BBBB-CCCC-000000000001}',
  String friendlyName = 'Wi-Fi',
  String description = 'Intel(R) Wi-Fi 6 AX201 160MHz',
  int ifType = 71,
  bool isUp = true,
  List<Ipv4Subnet>? ipv4,
  bool hasGateway = true,
  String? networkId = '{NETWORK-HOME}',
  String? networkName = 'Casa',
}) => AdapterInfo(
  id: id,
  friendlyName: friendlyName,
  description: description,
  ifType: ifType,
  isUp: isUp,
  ipv4: ipv4 ?? [subnet('192.168.50.21', 24)],
  hasGateway: hasGateway,
  networkId: networkId,
  networkName: networkName,
);

NetworkDecision? Function(String) decisions(
  Map<String, NetworkDecision> byId,
) =>
    (networkId) => byId[networkId];

List<InterfaceStatus> statusesOf(List<InterfaceState> states) => [
  for (final state in states) state.status,
];

InternetAddress randomIpv4(Random random) {
  final raw = Uint8List.fromList([
    for (var i = 0; i < 4; i++) random.nextInt(256),
  ]);
  switch (random.nextInt(6)) {
    case 0:
      raw[0] = 169;
      raw[1] = 254;
    case 1:
      raw[0] = 192;
      raw[1] = 168;
    case 2:
      raw[3] = [0, 1, 254, 255][random.nextInt(4)];
    default:
      break;
  }
  return InternetAddress.fromRawAddress(raw, type: InternetAddressType.IPv4);
}

InternetAddress randomIpv6(Random random) => InternetAddress.fromRawAddress(
  Uint8List.fromList([for (var i = 0; i < 16; i++) random.nextInt(256)]),
  type: InternetAddressType.IPv6,
);

InternetAddress randomAddress(Random random) =>
    random.nextInt(8) == 0 ? randomIpv6(random) : randomIpv4(random);

int randomPrefix(Random random) => switch (random.nextInt(10)) {
  0 => random.nextInt(200) - 100,
  1 => 33 + random.nextInt(100),
  2 => -1 - random.nextInt(100),
  3 => [0, 1, 30, 31, 32][random.nextInt(5)],
  _ => random.nextInt(33),
};

Ipv4Subnet randomSubnet(Random random) =>
    Ipv4Subnet(randomAddress(random), randomPrefix(random));

String randomCase(Random random, String text) => String.fromCharCodes([
  for (final unit in text.codeUnits)
    random.nextBool()
        ? String.fromCharCode(unit).toUpperCase().codeUnitAt(0)
        : String.fromCharCode(unit).toLowerCase().codeUnitAt(0),
]);

String randomLabel(Random random) {
  const pool = [
    'Wi-Fi',
    'Ethernet',
    'Hyper-V Virtual Ethernet Adapter',
    'VirtualBox Host-Only Ethernet Adapter',
    'VMware Virtual Ethernet Adapter for VMnet8',
    'vEthernet (WSL (Hyper-V firewall))',
    'vEthernet (Default Switch)',
    'WireGuard Tunnel',
    'Loopback Pseudo-Interface 1',
    '',
    'ñ 💻 \u0000',
  ];
  return randomCase(random, pool[random.nextInt(pool.length)]);
}

AdapterInfo randomAdapter(Random random, int index) => AdapterInfo(
  id: '{ADAPTER-$index}',
  friendlyName: randomLabel(random),
  description: randomLabel(random),
  ifType: [6, 24, 53, 71, 131, random.nextInt(300) - 10][random.nextInt(6)],
  isUp: random.nextInt(4) != 0,
  ipv4: [
    for (var i = 0, n = random.nextInt(4); i < n; i++) randomSubnet(random),
  ],
  hasGateway: random.nextBool(),
  networkId: random.nextInt(5) == 0
      ? null
      : ['{N1}', '{N2}', '{N3}', ''][random.nextInt(4)],
  networkName: random.nextBool() ? 'Casa' : null,
);

bool isLinkLocal(InternetAddress address) =>
    address.type == InternetAddressType.IPv4 &&
    address.rawAddress[0] == 169 &&
    address.rawAddress[1] == 254;

void main() {
  group('evaluateInterfaces (RF-15)', () {
    test('same network name with another networkId is another network', () {
      final home = adapter(
        id: '{ADAPTER-WIFI}',
        networkId: '{NETWORK-HOME}',
        networkName: 'Casa',
      );
      final lookalike = adapter(
        id: '{ADAPTER-ETHERNET}',
        friendlyName: 'Ethernet',
        networkId: '{NETWORK-OTHER-ROUTER}',
        networkName: 'Casa',
        ipv4: [subnet('192.168.1.40', 24)],
      );
      final states = evaluateInterfaces([
        home,
        lookalike,
      ], decisions({'{NETWORK-HOME}': NetworkDecision.trusted}));
      expect(states, hasLength(2));
      expect(states[0].adapter, same(home));
      expect(states[0].status, InterfaceStatus.active);
      expect(states[1].adapter, same(lookalike));
      expect(states[1].status, InterfaceStatus.undecided);
    });

    test('an untrusted decision does not leak to a namesake network', () {
      final states = evaluateInterfaces([
        adapter(id: '{A}', networkId: '{N1}', networkName: 'Casa'),
        adapter(id: '{B}', networkId: '{N2}', networkName: 'Casa'),
      ], decisions({'{N2}': NetworkDecision.untrusted}));
      expect(statusesOf(states), [
        InterfaceStatus.undecided,
        InterfaceStatus.paused,
      ]);
    });

    test('asks for the decision by networkId, never by name', () {
      final asked = <String>[];
      evaluateInterfaces(
        [
          adapter(id: '{A}', networkId: '{N1}', networkName: 'Casa'),
          adapter(id: '{B}', networkId: '{N2}', networkName: 'Casa'),
        ],
        (networkId) {
          asked.add(networkId);
          return null;
        },
      );
      expect(asked, ['{N1}', '{N2}']);
    });

    test(
      'trusted gives active, untrusted gives paused, none gives undecided',
      () {
        final states = evaluateInterfaces(
          [
            adapter(id: '{A}', networkId: '{TRUSTED}'),
            adapter(id: '{B}', networkId: '{UNTRUSTED}'),
            adapter(id: '{C}', networkId: '{UNKNOWN}'),
          ],
          decisions({
            '{TRUSTED}': NetworkDecision.trusted,
            '{UNTRUSTED}': NetworkDecision.untrusted,
          }),
        );
        expect(statusesOf(states), [
          InterfaceStatus.active,
          InterfaceStatus.paused,
          InterfaceStatus.undecided,
        ]);
      },
    );

    test('keeps the order of the adapters and drops the unusable ones', () {
      final usableA = adapter(id: '{A}', networkId: '{N1}');
      final down = adapter(id: '{B}', networkId: '{N1}', isUp: false);
      final usableC = adapter(id: '{C}', networkId: '{N2}');
      final noNetwork = adapter(id: '{D}', networkId: null);
      final states = evaluateInterfaces([
        usableA,
        down,
        usableC,
        noNetwork,
      ], decisions({'{N1}': NetworkDecision.trusted}));
      expect(states.map((s) => s.adapter.id), ['{A}', '{C}']);
      expect(statusesOf(states), [
        InterfaceStatus.active,
        InterfaceStatus.undecided,
      ]);
    });

    test('no adapters give no states', () {
      expect(evaluateInterfaces(const [], decisions(const {})), isEmpty);
    });

    test('the enums have exactly the plan values', () {
      expect(NetworkDecision.values.map((d) => d.name), [
        'trusted',
        'untrusted',
      ]);
      expect(InterfaceStatus.values.map((s) => s.name), [
        'active',
        'paused',
        'undecided',
      ]);
    });
  });

  group('VPN is a network like any other (RF-23)', () {
    AdapterInfo vpn({bool hasGateway = true}) => adapter(
      id: '{ADAPTER-VPN}',
      friendlyName: 'ProtonVPN',
      description: 'WireGuard Tunnel',
      ifType: 53,
      ipv4: [subnet('10.2.0.2', 32)],
      hasGateway: hasGateway,
      networkId: '{NETWORK-VPN}',
      networkName: 'ProtonVPN',
    );

    test('a WireGuard tunnel with networkId is usable and not virtual', () {
      expect(isUsableAdapter(vpn()), isTrue);
      expect(isVirtualInternal(vpn()), isFalse);
      expect(isUsableAdapter(vpn(hasGateway: false)), isTrue);
    });

    test('without a decision it is undecided, so the user is asked', () {
      final states = evaluateInterfaces([vpn()], decisions(const {}));
      expect(statusesOf(states), [InterfaceStatus.undecided]);
    });

    test('the decision of the user is respected', () {
      expect(
        statusesOf(
          evaluateInterfaces([
            vpn(),
          ], decisions({'{NETWORK-VPN}': NetworkDecision.trusted})),
        ),
        [InterfaceStatus.active],
      );
      expect(
        statusesOf(
          evaluateInterfaces([
            vpn(),
          ], decisions({'{NETWORK-VPN}': NetworkDecision.untrusted})),
        ),
        [InterfaceStatus.paused],
      );
    });

    test('a trusted VPN gives an active interface on its /32', () {
      final active = activeInterfaces(
        evaluateInterfaces([
          vpn(),
        ], decisions({'{NETWORK-VPN}': NetworkDecision.trusted})),
      );
      expect(active, hasLength(1));
      expect(active.single.id, '{ADAPTER-VPN}#10.2.0.2');
      expect(active.single.subnet, subnet('10.2.0.2', 32));
    });
  });

  group('virtual internal adapters are ignored (RF-24)', () {
    const patterns = [
      'Hyper-V Virtual Ethernet',
      'VirtualBox Host-Only',
      'VMware Virtual Ethernet',
      'vEthernet (WSL',
    ];
    const realDescriptions = [
      'Hyper-V Virtual Ethernet Adapter',
      'VirtualBox Host-Only Ethernet Adapter',
      'VMware Virtual Ethernet Adapter for VMnet8',
      'vEthernet (WSL (Hyper-V firewall))',
    ];

    for (final text in [...patterns, ...realDescriptions]) {
      for (final variant in [text, text.toUpperCase(), text.toLowerCase()]) {
        test('"$variant" in description without gateway is ignored', () {
          final a = adapter(
            friendlyName: 'Ethernet 3',
            description: variant,
            hasGateway: false,
          );
          expect(isVirtualInternal(a), isTrue);
          expect(isUsableAdapter(a), isFalse);
          expect(evaluateInterfaces([a], decisions(const {})), isEmpty);
        });

        test('"$variant" in friendlyName without gateway is ignored', () {
          final a = adapter(
            friendlyName: variant,
            description: 'Generic adapter',
            hasGateway: false,
          );
          expect(isVirtualInternal(a), isTrue);
          expect(isUsableAdapter(a), isFalse);
        });
      }

      test('"$text" with a gateway is not ignored', () {
        final inDescription = adapter(description: text, hasGateway: true);
        final inName = adapter(friendlyName: text, hasGateway: true);
        expect(isVirtualInternal(inDescription), isFalse);
        expect(isUsableAdapter(inDescription), isTrue);
        expect(isVirtualInternal(inName), isFalse);
        expect(isUsableAdapter(inName), isTrue);
      });
    }

    test('ignored even if the user had trusted its network', () {
      final hyperV = adapter(
        description: 'Hyper-V Virtual Ethernet Adapter',
        hasGateway: false,
        networkId: '{NETWORK-HOME}',
      );
      expect(
        evaluateInterfaces([
          hyperV,
        ], decisions({'{NETWORK-HOME}': NetworkDecision.trusted})),
        isEmpty,
      );
    });

    test('the plan table: three ignored and the external switch usable', () {
      final virtualBox = adapter(
        id: '{VBOX}',
        friendlyName: 'Ethernet 2',
        description: 'VirtualBox Host-Only Ethernet Adapter',
        hasGateway: false,
        networkId: null,
        ipv4: [subnet('192.168.56.1', 24)],
      );
      final hyperV = adapter(
        id: '{HYPERV}',
        friendlyName: 'vEthernet (Default Switch)',
        description: 'Hyper-V Virtual Ethernet Adapter',
        hasGateway: false,
        networkId: '{NETWORK-DEFAULT-SWITCH}',
        ipv4: [subnet('172.20.112.1', 20)],
      );
      final wsl = adapter(
        id: '{WSL}',
        friendlyName: 'vEthernet (WSL)',
        description: 'Generic adapter',
        hasGateway: false,
        networkId: '{NETWORK-WSL}',
        ipv4: [subnet('172.28.0.1', 20)],
      );
      final external = adapter(
        id: '{EXTERNAL}',
        friendlyName: 'vEthernet (External Switch)',
        description: 'Hyper-V Virtual Ethernet Adapter #2',
        hasGateway: true,
        networkId: '{NETWORK-HOME}',
      );
      expect(isUsableAdapter(virtualBox), isFalse);
      expect(isUsableAdapter(hyperV), isFalse);
      expect(isUsableAdapter(wsl), isFalse);
      expect(isUsableAdapter(external), isTrue);
      final states = evaluateInterfaces([
        virtualBox,
        hyperV,
        wsl,
        external,
      ], decisions(const {}));
      expect(states.map((s) => s.adapter.id), ['{EXTERNAL}']);
    });

    test('a name outside the four patterns is not virtual', () {
      for (final name in [
        'Wi-Fi',
        'Ethernet',
        'vEthernet (Default Switch)',
        'Hyper-V Virtual Switch',
        'VMware Network Adapter VMnet1',
        'VirtualBox Bridged',
      ]) {
        final a = adapter(
          friendlyName: name,
          description: name,
          hasGateway: false,
        );
        expect(isVirtualInternal(a), isFalse, reason: name);
        expect(isUsableAdapter(a), isTrue, reason: name);
      }
    });
  });

  group('isUsableAdapter (RF-24)', () {
    test('a normal adapter is usable', () {
      expect(isUsableAdapter(adapter()), isTrue);
    });

    test('an adapter that is down is not usable', () {
      expect(isUsableAdapter(adapter(isUp: false)), isFalse);
    });

    test('a loopback adapter (ifType 24) is not usable', () {
      expect(
        isUsableAdapter(
          adapter(
            friendlyName: 'Loopback Pseudo-Interface 1',
            ifType: 24,
            ipv4: [subnet('127.0.0.1', 8)],
          ),
        ),
        isFalse,
      );
    });

    test('other ifTypes are usable', () {
      for (final ifType in [6, 23, 25, 53, 71, 131]) {
        expect(
          isUsableAdapter(adapter(ifType: ifType)),
          isTrue,
          reason: '$ifType',
        );
      }
    });

    test('an adapter without IPv4 is not usable', () {
      expect(isUsableAdapter(adapter(ipv4: const [])), isFalse);
    });

    test('an adapter with only link-local 169.254.x.x is not usable', () {
      expect(
        isUsableAdapter(adapter(ipv4: [subnet('169.254.12.34', 16)])),
        isFalse,
      );
      expect(
        isUsableAdapter(
          adapter(
            ipv4: [subnet('169.254.0.1', 16), subnet('169.254.255.254', 16)],
          ),
        ),
        isFalse,
      );
    });

    test('a link-local address next to a routable one is usable', () {
      expect(
        isUsableAdapter(
          adapter(
            ipv4: [subnet('169.254.12.34', 16), subnet('192.168.1.5', 24)],
          ),
        ),
        isTrue,
      );
    });

    test('the neighbours of 169.254.0.0/16 are not link-local', () {
      for (final address in ['169.253.255.255', '169.255.0.1', '168.254.1.1']) {
        expect(
          isUsableAdapter(adapter(ipv4: [subnet(address, 16)])),
          isTrue,
          reason: address,
        );
      }
    });

    test('an adapter whose subnets are all IPv6 is not usable', () {
      expect(
        isUsableAdapter(
          adapter(ipv4: [Ipv4Subnet(InternetAddress('fe80::1'), 64)]),
        ),
        isFalse,
      );
    });

    test('an adapter without networkId is not usable', () {
      expect(isUsableAdapter(adapter(networkId: null)), isFalse);
    });
  });

  group('originAllowed (RF-25)', () {
    final lan = subnet('192.168.50.21', 24);

    test('the plan table for a /24', () {
      expect(originAllowed(ip('192.168.50.7'), lan), isTrue);
      expect(originAllowed(ip('10.2.0.5'), lan), isFalse);
      expect(originAllowed(ip('192.168.50.255'), lan), isFalse);
      expect(originAllowed(ip('192.168.50.0'), lan), isFalse);
    });

    test('accepts the first and last host and the own address', () {
      expect(originAllowed(ip('192.168.50.1'), lan), isTrue);
      expect(originAllowed(ip('192.168.50.254'), lan), isTrue);
      expect(originAllowed(ip('192.168.50.21'), lan), isTrue);
    });

    test('rejects the neighbouring blocks', () {
      expect(originAllowed(ip('192.168.49.255'), lan), isFalse);
      expect(originAllowed(ip('192.168.51.0'), lan), isFalse);
      expect(originAllowed(ip('192.168.51.7'), lan), isFalse);
    });

    test('the plan table for /32 and /31', () {
      expect(originAllowed(ip('10.2.0.2'), subnet('10.2.0.2', 32)), isTrue);
      expect(originAllowed(ip('10.0.0.0'), subnet('10.0.0.0', 31)), isTrue);
      expect(originAllowed(ip('10.0.0.1'), subnet('10.0.0.0', 31)), isTrue);
      expect(originAllowed(ip('10.2.0.3'), subnet('10.2.0.2', 32)), isFalse);
    });

    test('a /32 only accepts itself', () {
      final vpn = subnet('10.2.0.2', 32);
      expect(originAllowed(ip('10.2.0.1'), vpn), isFalse);
      expect(originAllowed(ip('10.2.0.0'), vpn), isFalse);
      expect(originAllowed(ip('10.2.0.255'), vpn), isFalse);
      expect(originAllowed(ip('127.0.0.2'), subnet('127.0.0.1', 32)), isFalse);
      expect(originAllowed(ip('127.0.0.1'), subnet('127.0.0.1', 32)), isTrue);
    });

    test('a /31 accepts both addresses whatever the own one is', () {
      final link = subnet('10.0.0.1', 31);
      expect(originAllowed(ip('10.0.0.0'), link), isTrue);
      expect(originAllowed(ip('10.0.0.1'), link), isTrue);
      expect(originAllowed(ip('10.0.0.2'), link), isFalse);
      expect(originAllowed(ip('9.255.255.255'), link), isFalse);
    });

    test('a /30 still excludes network and broadcast', () {
      final block = subnet('10.0.0.5', 30);
      expect(originAllowed(ip('10.0.0.4'), block), isFalse);
      expect(originAllowed(ip('10.0.0.5'), block), isTrue);
      expect(originAllowed(ip('10.0.0.6'), block), isTrue);
      expect(originAllowed(ip('10.0.0.7'), block), isFalse);
      expect(originAllowed(ip('10.0.0.8'), block), isFalse);
    });

    test('a /16 excludes only its own network and broadcast', () {
      final block = subnet('10.0.5.9', 16);
      expect(originAllowed(ip('10.0.0.0'), block), isFalse);
      expect(originAllowed(ip('10.0.255.255'), block), isFalse);
      expect(originAllowed(ip('10.0.5.0'), block), isTrue);
      expect(originAllowed(ip('10.0.5.255'), block), isTrue);
      expect(originAllowed(ip('10.1.0.1'), block), isFalse);
    });

    test('IPv6 origins are rejected', () {
      expect(originAllowed(ip('::1'), subnet('127.0.0.1', 32)), isFalse);
      expect(originAllowed(ip('fe80::1'), lan), isFalse);
      expect(originAllowed(ip('::ffff:192.168.50.7'), lan), isFalse);
      expect(originAllowed(ip('::'), subnet('0.0.0.0', 0)), isFalse);
    });

    test('a subnet whose address is IPv6 rejects everything', () {
      final v6 = Ipv4Subnet(ip('fe80::1'), 64);
      expect(originAllowed(ip('fe80::2'), v6), isFalse);
      expect(originAllowed(ip('192.168.50.7'), v6), isFalse);
    });

    test('an out-of-range prefix does not throw', () {
      for (final prefix in [-1, 33, 64, 1 << 40, -(1 << 40)]) {
        final block = subnet('192.168.50.21', prefix);
        expect(
          () => originAllowed(ip('192.168.50.7'), block),
          returnsNormally,
          reason: '$prefix',
        );
        expect(
          () => originAllowed(ip('192.168.50.21'), block),
          returnsNormally,
          reason: '$prefix',
        );
      }
    });
  });

  group('Ipv4Subnet.contains (RF-25)', () {
    test('prefix 0 contains every IPv4 address', () {
      final all = subnet('0.0.0.0', 0);
      for (final address in [
        '0.0.0.0',
        '8.8.8.8',
        '192.168.50.7',
        '255.255.255.255',
      ]) {
        expect(all.contains(ip(address)), isTrue, reason: address);
      }
      expect(subnet('192.168.50.21', 0).contains(ip('1.2.3.4')), isTrue);
    });

    test('prefix 8', () {
      final block = subnet('10.1.2.3', 8);
      expect(block.contains(ip('10.0.0.0')), isTrue);
      expect(block.contains(ip('10.255.255.255')), isTrue);
      expect(block.contains(ip('9.255.255.255')), isFalse);
      expect(block.contains(ip('11.0.0.0')), isFalse);
    });

    test('prefix 16', () {
      final block = subnet('10.0.5.9', 16);
      expect(block.contains(ip('10.0.200.1')), isTrue);
      expect(block.contains(ip('10.0.0.0')), isTrue);
      expect(block.contains(ip('10.1.0.0')), isFalse);
      expect(block.contains(ip('9.0.255.255')), isFalse);
    });

    test('prefix 24 includes network and broadcast', () {
      final block = subnet('192.168.50.21', 24);
      expect(block.contains(ip('192.168.50.0')), isTrue);
      expect(block.contains(ip('192.168.50.255')), isTrue);
      expect(block.contains(ip('192.168.50.7')), isTrue);
      expect(block.contains(ip('192.168.51.0')), isFalse);
      expect(block.contains(ip('192.168.49.255')), isFalse);
    });

    test('prefix 30', () {
      final block = subnet('10.0.0.5', 30);
      for (final last in [4, 5, 6, 7]) {
        expect(block.contains(ip('10.0.0.$last')), isTrue, reason: '$last');
      }
      expect(block.contains(ip('10.0.0.3')), isFalse);
      expect(block.contains(ip('10.0.0.8')), isFalse);
    });

    test('prefix 31', () {
      final block = subnet('10.0.0.1', 31);
      expect(block.contains(ip('10.0.0.0')), isTrue);
      expect(block.contains(ip('10.0.0.1')), isTrue);
      expect(block.contains(ip('10.0.0.2')), isFalse);
    });

    test('prefix 32', () {
      final block = subnet('10.2.0.2', 32);
      expect(block.contains(ip('10.2.0.2')), isTrue);
      expect(block.contains(ip('10.2.0.3')), isFalse);
      expect(block.contains(ip('10.2.0.1')), isFalse);
    });

    test('works with the highest bit set', () {
      expect(
        subnet('255.255.255.254', 31).contains(ip('255.255.255.255')),
        isTrue,
      );
      expect(subnet('128.0.0.1', 1).contains(ip('255.0.0.0')), isTrue);
      expect(subnet('128.0.0.1', 1).contains(ip('127.255.255.255')), isFalse);
      expect(subnet('200.1.2.3', 8).contains(ip('200.255.0.0')), isTrue);
      expect(subnet('200.1.2.3', 8).contains(ip('72.1.2.3')), isFalse);
    });

    test('IPv6 is never contained and an IPv6 subnet contains nothing', () {
      expect(subnet('0.0.0.0', 0).contains(ip('::1')), isFalse);
      expect(subnet('127.0.0.1', 8).contains(ip('::ffff:127.0.0.1')), isFalse);
      expect(Ipv4Subnet(ip('::1'), 128).contains(ip('::1')), isFalse);
      expect(Ipv4Subnet(ip('::1'), 0).contains(ip('10.0.0.1')), isFalse);
    });

    test('an out-of-range prefix does not throw', () {
      for (final prefix in [-1, 33, 64, 1 << 40, -(1 << 40)]) {
        final block = subnet('192.168.50.21', prefix);
        expect(
          () => block.contains(ip('192.168.50.21')),
          returnsNormally,
          reason: '$prefix',
        );
        expect(
          () => block.contains(ip('10.0.0.1')),
          returnsNormally,
          reason: '$prefix',
        );
      }
    });
  });

  group('Ipv4Subnet equality', () {
    test('same address and prefix are equal with the same hashCode', () {
      final a = subnet('192.168.50.21', 24);
      final b = subnet('192.168.50.21', 24);
      expect(a, b);
      expect(a.hashCode, b.hashCode);
      expect({a, b}, hasLength(1));
    });

    test('another prefix or another address is different', () {
      final base = subnet('192.168.50.21', 24);
      expect(base, isNot(subnet('192.168.50.21', 16)));
      expect(base, isNot(subnet('192.168.50.22', 24)));
      expect(base == Object(), isFalse);
      expect({
        base,
        subnet('192.168.50.21', 16),
        subnet('192.168.50.22', 24),
      }, hasLength(3));
    });

    test('equal whether built from text or from raw bytes', () {
      final fromText = subnet('10.0.5.9', 16);
      final fromRaw = Ipv4Subnet(
        InternetAddress.fromRawAddress(
          Uint8List.fromList([10, 0, 5, 9]),
          type: InternetAddressType.IPv4,
        ),
        16,
      );
      expect(fromRaw, fromText);
      expect(fromRaw.hashCode, fromText.hashCode);
    });
  });

  group('Ipv4Subnet.slash24Hosts', () {
    void expectHosts(Ipv4Subnet source, String block, int count) {
      final hosts = source.slash24Hosts();
      final own = source.address.address;
      final slash24 = subnet(block, 24);
      expect(hosts, hasLength(count));
      expect(hosts.map((h) => h.address), isNot(contains(own)));
      expect(hosts.map((h) => h.address).toSet(), hasLength(count));
      for (final host in hosts) {
        expect(host.type, InternetAddressType.IPv4);
        expect(slash24.contains(host), isTrue, reason: host.address);
        expect(host.rawAddress[3], inInclusiveRange(1, 254));
      }
    }

    test('192.168.50.21/24 gives 253 hosts without itself', () {
      expectHosts(subnet('192.168.50.21', 24), '192.168.50.0', 253);
      final hosts = subnet('192.168.50.21', 24).slash24Hosts();
      final addresses = hosts.map((h) => h.address).toSet();
      expect(addresses, containsAll(['192.168.50.1', '192.168.50.254']));
      expect(addresses, isNot(contains('192.168.50.0')));
      expect(addresses, isNot(contains('192.168.50.255')));
    });

    test('10.0.5.9/16 gives 253 hosts of its own /24 only', () {
      expectHosts(subnet('10.0.5.9', 16), '10.0.5.0', 253);
      final addresses = subnet(
        '10.0.5.9',
        16,
      ).slash24Hosts().map((h) => h.address).toSet();
      expect(addresses, containsAll(['10.0.5.1', '10.0.5.254']));
      expect(addresses, isNot(contains('10.0.4.1')));
      expect(addresses, isNot(contains('10.0.6.1')));
    });

    test('a /32 still scans the /24 that contains it', () {
      expectHosts(subnet('10.2.0.2', 32), '10.2.0.0', 253);
    });

    test('an own address outside .1 to .254 leaves the 254 hosts', () {
      expectHosts(subnet('10.0.5.0', 16), '10.0.5.0', 254);
      expectHosts(subnet('10.0.5.255', 16), '10.0.5.0', 254);
    });

    test('an IPv6 address gives an empty list', () {
      expect(Ipv4Subnet(ip('fe80::1'), 64).slash24Hosts(), isEmpty);
      expect(Ipv4Subnet(ip('::1'), 128).slash24Hosts(), isEmpty);
    });
  });

  group('activeInterfaces', () {
    test('an adapter with two IPv4 gives two interfaces', () {
      final first = subnet('192.168.50.21', 24);
      final second = subnet('10.0.5.9', 16);
      final a = adapter(
        id: '{ADAPTER-1}',
        friendlyName: 'Ethernet',
        ipv4: [first, second],
      );
      final active = activeInterfaces([
        InterfaceState(a, InterfaceStatus.active),
      ]);
      expect(active, hasLength(2));
      expect(active[0].id, '{ADAPTER-1}#192.168.50.21');
      expect(active[0].adapterId, '{ADAPTER-1}');
      expect(active[0].friendlyName, 'Ethernet');
      expect(active[0].subnet, first);
      expect(active[1].id, '{ADAPTER-1}#10.0.5.9');
      expect(active[1].adapterId, '{ADAPTER-1}');
      expect(active[1].friendlyName, 'Ethernet');
      expect(active[1].subnet, second);
    });

    test('only active states give interfaces', () {
      final active = activeInterfaces([
        InterfaceState(adapter(id: '{A}'), InterfaceStatus.paused),
        InterfaceState(adapter(id: '{B}'), InterfaceStatus.active),
        InterfaceState(adapter(id: '{C}'), InterfaceStatus.undecided),
      ]);
      expect(active.map((i) => i.adapterId), ['{B}']);
      expect(active.single.id, '{B}#192.168.50.21');
    });

    test('does not emit link-local addresses', () {
      final active = activeInterfaces([
        InterfaceState(
          adapter(
            id: '{A}',
            ipv4: [
              subnet('169.254.10.20', 16),
              subnet('192.168.1.5', 24),
              subnet('169.254.0.1', 16),
            ],
          ),
          InterfaceStatus.active,
        ),
      ]);
      expect(active.map((i) => i.id), ['{A}#192.168.1.5']);
    });

    test('does not emit IPv6 addresses', () {
      final active = activeInterfaces([
        InterfaceState(
          adapter(
            id: '{A}',
            ipv4: [Ipv4Subnet(ip('fe80::1'), 64), subnet('192.168.1.5', 24)],
          ),
          InterfaceStatus.active,
        ),
      ]);
      expect(active.map((i) => i.id), ['{A}#192.168.1.5']);
    });

    test('no states give no interfaces', () {
      expect(activeInterfaces(const []), isEmpty);
    });

    test(
      'from evaluateInterfaces, only trusted usable networks are active',
      () {
        final adapters = [
          adapter(id: '{WIFI}', networkId: '{HOME}'),
          adapter(
            id: '{ETH}',
            networkId: '{OFFICE}',
            ipv4: [subnet('10.10.0.4', 16)],
          ),
          adapter(
            id: '{HYPERV}',
            description: 'Hyper-V Virtual Ethernet Adapter',
            hasGateway: false,
            networkId: '{HOME}',
            ipv4: [subnet('172.20.112.1', 20)],
          ),
          adapter(id: '{CAFE}', networkId: '{CAFE}'),
        ];
        final active = activeInterfaces(
          evaluateInterfaces(
            adapters,
            decisions({
              '{HOME}': NetworkDecision.trusted,
              '{OFFICE}': NetworkDecision.trusted,
              '{CAFE}': NetworkDecision.untrusted,
            }),
          ),
        );
        expect(active.map((i) => i.id), [
          '{WIFI}#192.168.50.21',
          '{ETH}#10.10.0.4',
        ]);
      },
    );
  });

  group('detectResume', () {
    final previous = DateTime.utc(2026, 10, 21, 12);
    const interval = Duration(seconds: 2);

    test('a gap of 7 s with an interval of 2 s is a resume', () {
      expect(
        detectResume(
          previous,
          previous.add(const Duration(seconds: 7)),
          interval,
        ),
        isTrue,
      );
    });

    test('exactly three intervals (6 s) is not a resume', () {
      expect(
        detectResume(
          previous,
          previous.add(const Duration(seconds: 6)),
          interval,
        ),
        isFalse,
      );
    });

    test('just above three intervals is a resume', () {
      expect(
        detectResume(
          previous,
          previous.add(const Duration(seconds: 6, microseconds: 1)),
          interval,
        ),
        isTrue,
      );
    });

    test('a normal tick is not a resume', () {
      expect(detectResume(previous, previous.add(interval), interval), isFalse);
      expect(detectResume(previous, previous, interval), isFalse);
    });

    test('time going backwards is not a resume', () {
      expect(
        detectResume(
          previous,
          previous.subtract(const Duration(hours: 1)),
          interval,
        ),
        isFalse,
      );
    });

    test('scales with the interval', () {
      const tenSeconds = Duration(seconds: 10);
      expect(
        detectResume(
          previous,
          previous.add(const Duration(seconds: 30)),
          tenSeconds,
        ),
        isFalse,
      );
      expect(
        detectResume(
          previous,
          previous.add(const Duration(seconds: 31)),
          tenSeconds,
        ),
        isTrue,
      );
    });
  });

  group('robustness: the pure functions never throw', () {
    const iterations = 3000;

    test('random adapters through the whole pipeline', () {
      final random = Random(20261021);
      var activeSeen = 0;
      for (var i = 0; i < iterations; i++) {
        final adapters = [
          for (var j = 0, n = random.nextInt(5); j < n; j++)
            randomAdapter(random, j),
        ];
        final byId = <String, NetworkDecision>{
          for (final id in ['{N1}', '{N2}', '{N3}', ''])
            if (random.nextBool())
              id: NetworkDecision.values[random.nextInt(2)],
        };
        try {
          for (final a in adapters) {
            final usable = isUsableAdapter(a);
            final virtual = isVirtualInternal(a);
            if (virtual) expect(a.hasGateway, isFalse);
            if (usable) {
              expect(a.isUp, isTrue);
              expect(a.ifType, isNot(24));
              expect(a.networkId, isNotNull);
              expect(virtual, isFalse);
            }
          }
          final states = evaluateInterfaces(adapters, decisions(byId));
          for (final state in states) {
            expect(isUsableAdapter(state.adapter), isTrue);
          }
          for (final iface in activeInterfaces(states)) {
            activeSeen++;
            expect(iface.subnet.address.type, InternetAddressType.IPv4);
            expect(isLinkLocal(iface.subnet.address), isFalse);
            expect(
              iface.id,
              '${iface.adapterId}#${iface.subnet.address.address}',
            );
          }
        } on TestFailure {
          rethrow;
        } catch (error) {
          fail('pipeline threw $error at iteration $i');
        }
      }
      expect(activeSeen, greaterThan(0));
    });

    test('random subnets and origins', () {
      final random = Random(53530);
      for (var i = 0; i < iterations; i++) {
        final block = randomSubnet(random);
        final remote = randomAddress(random);
        try {
          final contained = block.contains(remote);
          final allowed = originAllowed(remote, block);
          if (allowed) expect(contained, isTrue);
          if (remote.type == InternetAddressType.IPv6) {
            expect(contained, isFalse);
            expect(allowed, isFalse);
          }
          final hosts = block.slash24Hosts();
          if (block.address.type == InternetAddressType.IPv6) {
            expect(hosts, isEmpty);
          } else {
            final last = block.address.rawAddress[3];
            expect(hosts, hasLength(last >= 1 && last <= 254 ? 253 : 254));
            final slash24 = Ipv4Subnet(block.address, 24);
            expect(hosts.every(slash24.contains), isTrue);
          }
          expect(
            block == Ipv4Subnet(block.address, block.prefixLength),
            isTrue,
          );
        } on TestFailure {
          rethrow;
        } catch (error) {
          fail(
            'threw $error for ${remote.address} on '
            '${block.address.address}/${block.prefixLength}',
          );
        }
      }
    });

    test('random times for detectResume', () {
      final random = Random(169);
      for (var i = 0; i < iterations; i++) {
        final previous = DateTime.fromMicrosecondsSinceEpoch(
          random.nextInt(1 << 32) * 1000,
          isUtc: true,
        );
        final now = previous.add(
          Duration(microseconds: random.nextInt(1 << 32) - (1 << 31)),
        );
        final interval = Duration(milliseconds: random.nextInt(60000));
        try {
          final resumed = detectResume(previous, now, interval);
          if (now.isBefore(previous)) expect(resumed, isFalse);
        } on TestFailure {
          rethrow;
        } catch (error) {
          fail('detectResume threw $error for $previous, $now, $interval');
        }
      }
    });
  });
}
