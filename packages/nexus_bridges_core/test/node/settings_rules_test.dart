import 'package:nexus_bridges_core/src/network/network.dart'
    show TrustedNetwork;
import 'package:nexus_bridges_core/src/node/node_state.dart';
import 'package:nexus_bridges_core/src/node/settings_rules.dart';
import 'package:nexus_bridges_core/src/pairing/pairing.dart' show IgnoredDevice;
import 'package:nexus_bridges_core/src/transfer/transfer.dart'
    show defaultExclusions;
import 'package:test/test.dart';

const String _rlo = '\u{202E}';

List<String> _names(int count) => [for (var i = 0; i < count; i++) 'n$i'];

String _fingerprint(int seed) => seed.toRadixString(16).padLeft(4, '0') * 16;

TrustedNetwork _trusted(String id, String name, DateTime at) =>
    TrustedNetwork(networkId: id, name: name, trustedAt: at);

List<TrustedNetworkView> _views(
  List<TrustedNetwork> trusted, {
  Set<String> connected = const {},
  Map<String, int> transfers = const {},
  Set<String> pairing = const {},
}) => trustedNetworkViews(
  trusted: trusted,
  connected: connected,
  transfersOn: (id) => transfers[id] ?? 0,
  pairingOn: pairing.contains,
);

void main() {
  group('E810: exclusionProblem (RF-519, S2)', () {
    test('an empty name is empty', () {
      expect(exclusionProblem('', const []), ExclusionProblem.empty);
    });

    test('names Windows would not accept as a file name are invalid', () {
      final invalid = [
        'a:b',
        'a*',
        'a"b',
        'a<b',
        'a|b',
        r'a\b',
        'a/b',
        'CON',
        'con.txt',
        'x.',
        'x ',
        '.',
        '..',
        'a' * 256,
        'a\u{0001}b',
        'a${_rlo}b',
      ];
      for (final name in invalid) {
        expect(
          exclusionProblem(name, const []),
          ExclusionProblem.invalid,
          reason: name.length > 20 ? '${name.length} units' : name,
        );
      }
    });

    test('a name of 255 units is still valid', () {
      expect(exclusionProblem('a' * 255, const []), isNull);
    });

    test('the same name in another case is a duplicate', () {
      expect(
        exclusionProblem('Node_Modules', const ['node_modules']),
        ExclusionProblem.duplicate,
      );
      expect(
        exclusionProblem('BUILD', const ['node_modules', 'build']),
        ExclusionProblem.duplicate,
      );
    });

    test('with 64 names the list is full, with 63 a new one fits', () {
      expect(exclusionProblem('dist', _names(64)), ExclusionProblem.full);
      expect(exclusionProblem('dist', _names(63)), isNull);
    });

    test('a duplicate in a full list is reported as duplicate', () {
      expect(exclusionProblem('N0', _names(64)), ExclusionProblem.duplicate);
    });

    test('a valid new name gives null', () {
      expect(exclusionProblem('dist', defaultExclusions), isNull);
      expect(exclusionProblem('.git', const []), isNull);
    });
  });

  group('effectiveExclusions and isDefaultExclusionList (S2, DA-11)', () {
    test('null, more than 64, an invalid name or a repeated one in another '
        'case give the default list', () {
      for (final saved in <List<String>?>[
        null,
        _names(65),
        ['dist', 'a:b'],
        ['dist', 'DIST'],
      ]) {
        expect(effectiveExclusions(saved), defaultExclusions, reason: '$saved');
      }
    });

    test('a valid list is kept as it is, also an empty one and one of 64', () {
      expect(effectiveExclusions(const ['dist', '.git']), ['dist', '.git']);
      expect(effectiveExclusions(const []), isEmpty);
      expect(effectiveExclusions(_names(64)), _names(64));
    });

    test('the list given back is a copy that can be changed', () {
      final saved = ['dist'];
      final effective = effectiveExclusions(saved)..add('more');
      expect(saved, ['dist']);
      expect(effective, ['dist', 'more']);
      final defaults = effectiveExclusions(null)..add('more');
      expect(defaultExclusions, hasLength(3));
      expect(defaults, hasLength(4));
    });

    test('the default list in any order or case is the default list', () {
      expect(isDefaultExclusionList(defaultExclusions), isTrue);
      expect(
        isDefaultExclusionList(const ['.dart_tool', 'BUILD', 'node_modules']),
        isTrue,
      );
      expect(isDefaultExclusionList(const ['node_modules', 'build']), isFalse);
      expect(
        isDefaultExclusionList(const [
          'node_modules',
          'build',
          '.dart_tool',
          'dist',
        ]),
        isFalse,
      );
      expect(isDefaultExclusionList(const []), isFalse);
    });
  });

  group('E815: ignoredDeviceViews (RF-536, S6)', () {
    test('newest first, then by fingerprint at the same time', () {
      final day = DateTime.utc(2026, 11, 1);
      final views = ignoredDeviceViews([
        IgnoredDevice(
          fingerprint: _fingerprint(1),
          name: 'Old',
          ignoredAt: day,
        ),
        IgnoredDevice(
          fingerprint: _fingerprint(3),
          name: 'Newest',
          ignoredAt: day.add(const Duration(days: 2)),
        ),
        IgnoredDevice(
          fingerprint: _fingerprint(9),
          name: 'Tie B',
          ignoredAt: day.add(const Duration(days: 1)),
        ),
        IgnoredDevice(
          fingerprint: _fingerprint(2),
          name: 'Tie A',
          ignoredAt: day.add(const Duration(days: 1)),
        ),
      ]);

      expect(views.map((v) => v.name), ['Newest', 'Tie A', 'Tie B', 'Old']);
    });

    test('the name is sanitized, the short fingerprint has 8 characters and '
        'the full one and the date are kept', () {
      final at = DateTime.utc(2026, 10, 30, 8);
      final fingerprint = 'ABCDEF01' * 8;
      final view = ignoredDeviceViews([
        IgnoredDevice(
          fingerprint: fingerprint,
          name: 'Evil${_rlo}gpj.exe',
          ignoredAt: at,
        ),
      ]).single;

      expect(view.name, isNot(contains(_rlo)));
      expect(view.name, 'Evilgpj.exe');
      expect(view.shortFingerprint, 'ABCDEF01');
      expect(view.fingerprint, fingerprint);
      expect(view.ignoredAt, at);
    });

    test('a name that is only invisible characters gives an empty name', () {
      final view = ignoredDeviceViews([
        IgnoredDevice(
          fingerprint: _fingerprint(5),
          name: '$_rlo\u{200B}',
          ignoredAt: DateTime.utc(2026),
        ),
      ]).single;

      expect(view.name, '');
    });

    test('a list of 256 gives 256 views', () {
      final start = DateTime.utc(2026, 1, 1);
      final views = ignoredDeviceViews([
        for (var i = 0; i < 256; i++)
          IgnoredDevice(
            fingerprint: _fingerprint(i),
            name: 'Device $i',
            ignoredAt: start.add(Duration(minutes: i)),
          ),
      ]);

      expect(views, hasLength(256));
      expect(views.first.name, 'Device 255');
      expect(views.last.name, 'Device 0');
    });

    test('an empty list gives an empty list', () {
      expect(ignoredDeviceViews(const []), isEmpty);
    });
  });

  group('E830: trustedNetworkViews (RF-531, S6)', () {
    final early = DateTime.utc(2026, 9, 1);
    final middle = DateTime.utc(2026, 10, 1);
    final late = DateTime.utc(2026, 11, 1);

    test('connected networks first, then the newest trusted first', () {
      final views = _views(
        [
          _trusted('{OLD}', 'Old', early),
          _trusted('{NEW}', 'New', late),
          _trusted('{HOME}', 'Home', middle),
          _trusted('{WORK}', 'Work', early),
        ],
        connected: {'{HOME}', '{WORK}'},
      );

      expect(views.map((v) => v.networkId), [
        '{HOME}',
        '{WORK}',
        '{NEW}',
        '{OLD}',
      ]);
      expect(views.map((v) => v.connected), [true, true, false, false]);
    });

    test('at the same date the order is by networkId', () {
      final views = _views([
        _trusted('{B}', 'B', middle),
        _trusted('{A}', 'A', middle),
      ]);

      expect(views.map((v) => v.networkId), ['{A}', '{B}']);
    });

    test('only what it is given is listed: untrusted networks never reach '
        'the function and are not added', () {
      expect(_views(const []), isEmpty);
      expect(_views(const [], connected: {'{HOME}'}), isEmpty);
    });

    test('an empty name or one equal to the id gives null, a name with U+202E '
        'is sanitized', () {
      final views = _views([
        _trusted('{EMPTY}', '', late),
        _trusted('{SAME}', '{SAME}', middle),
        _trusted('{RLO}', 'Casa${_rlo}gpj', early),
      ]);

      expect(views[0].name, isNull);
      expect(views[1].name, isNull);
      expect(views[2].name, 'Casagpj');
      expect(views[2].name, isNot(contains(_rlo)));
      expect(networkDisplayName('{X}', ''), isNull);
      expect(networkDisplayName('{X}', '{X}'), isNull);
      expect(networkDisplayName('{X}', '$_rlo\u{200B}'), isNull);
      expect(networkDisplayName('{X}', 'Home'), 'Home');
    });

    test('two networks with the same name are both listed', () {
      final views = _views([
        _trusted('{ONE}', 'Home', late),
        _trusted('{TWO}', 'Home', middle),
      ]);

      expect(views.map((v) => (v.networkId, v.name)), [
        ('{ONE}', 'Home'),
        ('{TWO}', 'Home'),
      ]);
    });

    test('transfers and pairing come from the callbacks for a connected '
        'network and are 0 and false for one that is not', () {
      final views = _views(
        [_trusted('{HOME}', 'Home', middle), _trusted('{CAFE}', 'Cafe', late)],
        connected: {'{HOME}'},
        transfers: {'{HOME}': 2, '{CAFE}': 1},
        pairing: {'{HOME}', '{CAFE}'},
      );

      expect(
        views[0],
        TrustedNetworkView(
          networkId: '{HOME}',
          name: 'Home',
          trustedAt: middle,
          connected: true,
          transfers: 2,
          pairing: true,
        ),
      );
      expect(
        views[1],
        TrustedNetworkView(
          networkId: '{CAFE}',
          name: 'Cafe',
          trustedAt: late,
          connected: false,
        ),
      );
    });
  });
}
