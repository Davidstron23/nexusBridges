import 'package:nexus_bridges_core/src/peers/peers.dart';
import 'package:test/test.dart';

import 'peer_notes_support.dart';

String runesOf(int count, [int rune = 0x61]) =>
    String.fromCharCodes(List.filled(count, rune));

void main() {
  group('E760 withRecent (RF-426)', () {
    test('the new destination goes first', () {
      final list = withRecent([place('b')], place('a', root: rootTwo));

      expect(list.map((d) => d.rootName), ['a', 'b']);
    });

    test('a repeated destination moves to the front without repeating', () {
      final one = place('one', path: const ['x']);
      final two = place('two', path: const ['y']);
      final three = place('three', path: const ['z']);

      final list = withRecent([one, two, three], two);

      expect(list, [two, one, three]);
    });

    test('keeps the five most recent', () {
      var list = const <SavedDestination>[];
      for (var i = 0; i < 7; i++) {
        list = withRecent(list, place('r$i', path: ['p$i']));
      }

      expect(list.map((d) => d.rootName), ['r6', 'r5', 'r4', 'r3', 'r2']);
    });

    test('a full list that repeats one keeps five and drops nothing else', () {
      var list = const <SavedDestination>[];
      for (var i = 0; i < 5; i++) {
        list = withRecent(list, place('r$i', path: ['p$i']));
      }

      final repeated = withRecent(list, place('r0', path: const ['p0']));

      expect(repeated, hasLength(5));
      expect(repeated.map((d) => d.rootName), ['r0', 'r4', 'r3', 'r2', 'r1']);
    });

    test('the same path in another case is the same destination and the '
        'newest spelling stays', () {
      final old = place('docs', path: const ['Mods', 'Viejo']);
      final fresh = place('docs', path: const ['MODS', 'viejo']);

      final list = withRecent([old], fresh);

      expect(list, [fresh]);
    });

    test('another root or another depth is another destination', () {
      final base = place('docs', path: const ['a']);

      expect(
        withRecent([base], place('docs', root: rootTwo, path: const ['a'])),
        hasLength(2),
      );
      expect(
        withRecent([base], place('docs', path: const ['a', 'b'])),
        hasLength(2),
      );
      expect(withRecent([base], place('docs')), hasLength(2));
    });
  });

  group(
    'sameDestination compares roots and paths with folderKey (punto 19)',
    () {
      test('ignores the case of the components and the root name', () {
        expect(
          sameDestination(
            place('uno', path: const ['Fotos']),
            place('dos', path: const ['FOTOS']),
          ),
          isTrue,
        );
      });

      test('different root ids are different even with the same name', () {
        expect(
          sameDestination(place('uno'), place('uno', root: rootTwo)),
          isFalse,
        );
      });

      test('different components are different destinations', () {
        expect(
          sameDestination(
            place('a', path: const ['x']),
            place('a', path: const ['y']),
          ),
          isFalse,
        );
      });
    },
  );

  group('E760 withHistory (RF-430)', () {
    test('the newest goes first', () {
      final list = withHistory([historyEntry('old')], historyEntry('new'));

      expect(list.map((e) => e.name), ['new', 'old']);
    });

    test('keeps the 50 newest', () {
      var list = const <HistoryEntry>[];
      for (var i = 0; i < 53; i++) {
        list = withHistory(list, historyEntry('h$i'));
      }

      expect(list, hasLength(50));
      expect(list.first.name, 'h52');
      expect(list.last.name, 'h3');
    });

    test('two equal entries are both kept', () {
      final list = withHistory([historyEntry('same')], historyEntry('same'));

      expect(list, hasLength(2));
    });
  });

  group('E760 cleanAlias (RF-429)', () {
    test('keeps a plain alias', () {
      expect(cleanAlias('Casa'), 'Casa');
    });

    test('trims the spaces around it', () {
      expect(cleanAlias('  Casa  '), 'Casa');
    });

    test('an empty alias or one of only spaces is null', () {
      expect(cleanAlias(''), isNull);
      expect(cleanAlias('    '), isNull);
    });

    test('invisible, control and bidi characters go away', () {
      expect(cleanAlias('Ca\u{202E}sa\u{200B}\u{0007}'), 'Casa');
      expect(cleanAlias('\u{202E}\u{200B}\u{FEFF}'), isNull);
    });

    test('stops at 64 characters', () {
      expect(cleanAlias(runesOf(64)), runesOf(64));
      expect(cleanAlias(runesOf(65)), runesOf(64));
    });

    test('counts runes, not code units, and does not split an emoji', () {
      final alias = cleanAlias(runesOf(70, 0x1F600))!;

      expect(alias.runes.length, 64);
      expect(alias, runesOf(64, 0x1F600));
    });

    test('limits the combining marks as the device names do', () {
      final alias = cleanAlias('a${runesOf(10, 0x0301)}')!;

      expect(alias.runes.length, lessThan(11));
      expect(alias, startsWith('a'));
    });

    test('is idempotent', () {
      for (final raw in ['  Casa ', runesOf(80), 'Ca\u{202E}sa']) {
        final once = cleanAlias(raw);
        expect(cleanAlias(once!), once);
      }
    });
  });
}
