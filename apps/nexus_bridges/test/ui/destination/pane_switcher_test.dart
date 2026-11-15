import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nexus_bridges/src/ui/destination/pane_switcher.dart';

Widget _host({
  required Object paneKey,
  required String label,
  bool forward = true,
  bool disableAnimations = false,
  List<bool>? leavingSeen,
}) => MaterialApp(
  home: MediaQuery(
    data: MediaQueryData(disableAnimations: disableAnimations),
    child: Center(
      child: SizedBox(
        width: 300,
        height: 100,
        child: PaneSwitcher(
          paneKey: paneKey,
          forward: forward,
          child: Builder(
            builder: (context) {
              leavingSeen?.add(PaneLeaving.of(context));
              return Text(label);
            },
          ),
        ),
      ),
    ),
  ),
);

double _opacityOf(WidgetTester tester, String label) => tester
    .widget<Opacity>(
      find.ancestor(of: find.text(label), matching: find.byType(Opacity)).first,
    )
    .opacity;

double _shiftOf(WidgetTester tester, String label) => tester
    .widget<FractionalTranslation>(
      find
          .ancestor(
            of: find.text(label),
            matching: find.byType(FractionalTranslation),
          )
          .first,
    )
    .translation
    .dx;

void main() {
  group('E783 PaneSwitcher: the change of folder (RF-433, cambio 1)', () {
    testWidgets('the new pane takes 0.7 s, the old one 0.6 s, and the old '
        'one is never opaque on top of the new one', (tester) async {
      await tester.pumpWidget(_host(paneKey: 1, label: 'one'));
      expect(find.text('one'), findsOneWidget);

      await tester.pumpWidget(_host(paneKey: 2, label: 'two'));
      await tester.pump();
      expect(find.text('one'), findsOneWidget);
      expect(find.text('two'), findsOneWidget);
      expect(_opacityOf(tester, 'two'), 0);
      expect(_shiftOf(tester, 'two'), closeTo(0.36, 0.001));
      expect(_opacityOf(tester, 'one'), 1);

      for (var elapsed = 100; elapsed <= 500; elapsed += 100) {
        await tester.pump(const Duration(milliseconds: 100));
        expect(
          _opacityOf(tester, 'one') + _opacityOf(tester, 'two'),
          lessThanOrEqualTo(1.0001),
          reason: 'at $elapsed ms',
        );
      }

      await tester.pump(const Duration(milliseconds: 100));
      expect(_opacityOf(tester, 'one'), closeTo(0, 0.001));
      expect(_opacityOf(tester, 'two'), lessThan(1));
      expect(_opacityOf(tester, 'two'), greaterThan(0.9));

      await tester.pump(const Duration(milliseconds: 99));
      expect(find.text('one'), findsOneWidget);
      await tester.pump(const Duration(milliseconds: 2));
      await tester.pump();
      expect(find.text('one'), findsNothing);
      expect(_opacityOf(tester, 'two'), 1);
      expect(_shiftOf(tester, 'two'), 0);
    });

    testWidgets('going back mirrors the direction', (tester) async {
      await tester.pumpWidget(_host(paneKey: 2, label: 'two'));
      await tester.pumpWidget(_host(paneKey: 1, label: 'one', forward: false));
      await tester.pump();

      expect(_shiftOf(tester, 'one'), closeTo(-0.36, 0.001));
      await tester.pump(const Duration(milliseconds: 300));
      expect(_shiftOf(tester, 'two'), greaterThan(0));
      await tester.pumpAndSettle();
    });

    testWidgets('the pane that leaves is marked, ignores the pointer and '
        'cannot take focus; the one that comes in is not marked', (
      tester,
    ) async {
      final seen = <bool>[];
      await tester.pumpWidget(_host(paneKey: 1, label: 'one'));
      await tester.pumpWidget(
        _host(paneKey: 2, label: 'two', leavingSeen: seen),
      );
      await tester.pump(const Duration(milliseconds: 100));

      final leaving = find.ancestor(
        of: find.text('one'),
        matching: find.byType(PaneLeaving),
      );
      expect(leaving, findsOneWidget);
      expect(
        find.ancestor(of: find.text('two'), matching: find.byType(PaneLeaving)),
        findsNothing,
      );
      final ignore = tester.widget<IgnorePointer>(
        find
            .ancestor(
              of: find.text('one'),
              matching: find.byType(IgnorePointer),
            )
            .first,
      );
      expect(ignore.ignoring, isTrue);
      expect(
        tester
            .widget<ExcludeFocus>(
              find
                  .ancestor(
                    of: find.text('one'),
                    matching: find.byType(ExcludeFocus),
                  )
                  .first,
            )
            .excluding,
        isTrue,
      );
      expect(seen, isNotEmpty);
      expect(seen, everyElement(isFalse));
      await tester.pumpAndSettle();
      expect(find.byType(PaneLeaving), findsNothing);
    });

    testWidgets('with animations off it swaps at once with nothing left '
        'behind', (tester) async {
      await tester.pumpWidget(
        _host(paneKey: 1, label: 'one', disableAnimations: true),
      );
      await tester.pumpWidget(
        _host(paneKey: 2, label: 'two', disableAnimations: true),
      );
      await tester.pump();

      expect(find.text('one'), findsNothing);
      expect(find.text('two'), findsOneWidget);
      expect(find.byType(PaneLeaving), findsNothing);
      expect(_opacityOf(tester, 'two'), 1);
    });

    testWidgets('the same key does not start a transition', (tester) async {
      await tester.pumpWidget(_host(paneKey: 1, label: 'one'));
      await tester.pumpWidget(_host(paneKey: 1, label: 'changed'));
      await tester.pump(const Duration(milliseconds: 100));

      expect(find.text('changed'), findsOneWidget);
      expect(find.text('one'), findsNothing);
      expect(find.byType(PaneLeaving), findsNothing);
    });
  });
}
