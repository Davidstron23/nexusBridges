import 'dart:async';

import 'package:nexus_bridges_core/src/outbox/outbox.dart';
import 'package:test/test.dart';

const String docA = r'C:\in\Informe.pdf';
const String docB = r'C:\in\notas.txt';
const String docC = r'C:\in\otro.txt';

Future<ElementProbe> _probe(String path) async =>
    const ElementProbe(kind: ElementKind.file, size: 1);

void main() {
  late SendTray tray;
  late int changes;
  late StreamSubscription<void> subscription;

  setUp(() async {
    tray = SendTray(probe: _probe);
    await tray.add([docA, docB]);
    changes = 0;
    subscription = tray.changes.listen((_) => changes++);
  });

  tearDown(() async {
    await subscription.cancel();
    await tray.close();
  });

  Future<void> flush() => pumpEventQueue(times: 20);

  group('Q-2: take empties the tray at once', () {
    test(
      'take returns every path, empties the tray and announces it once',
      () async {
        final batch = tray.take();
        await flush();

        expect(batch.paths, [docA, docB]);
        expect(batch.isEmpty, isFalse);
        expect(tray.paths, isEmpty);
        expect(tray.items, isEmpty);
        expect(changes, 1);
      },
    );

    test('a second take finds nothing and announces nothing', () async {
      tray.take();
      await flush();
      changes = 0;

      final again = tray.take();
      await flush();

      expect(again.isEmpty, isTrue);
      expect(again.paths, isEmpty);
      expect(changes, 0);
    });

    test('a path taken can be added again like a new one', () async {
      tray.take();

      expect(await tray.add([docA]), TrayAddResult.added);
      expect(tray.paths, [docA]);
    });
  });

  group('Q-2: restore puts a batch back', () {
    test(
      'restore returns the same items, with the same ids, to the front',
      () async {
        final before = tray.items;
        final batch = tray.take();
        await tray.add([docC]);

        tray.restore(batch);
        await flush();

        expect(tray.paths, [docA, docB, docC]);
        expect(tray.items.take(2).toList(), before);
      },
    );

    test('restore skips what was added again in the meantime', () async {
      final batch = tray.take();
      await tray.add([docB.toUpperCase()]);

      tray.restore(batch);

      expect(tray.paths, [docA, docB.toUpperCase()]);
    });

    test(
      'restoring an empty batch or one already back announces nothing',
      () async {
        final empty = SendTray(probe: _probe).take();
        final batch = tray.take();
        tray.restore(batch);
        await flush();
        changes = 0;

        tray.restore(empty);
        tray.restore(batch);
        await flush();

        expect(tray.paths, [docA, docB]);
        expect(changes, 0);
      },
    );
  });
}
