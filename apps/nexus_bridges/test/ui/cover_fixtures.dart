import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nexus_bridges/src/ui/modal/modal_button.dart';
import 'package:nexus_bridges/src/ui/modal/modal_frame.dart';

const String coverLabel = 'cover';
const String coverResult = 'cover closed';

final class Cover {
  Cover._(this.route);

  final NbModalRoute<String> route;
  int taps = 0;
  String? result;
  bool finished = false;
}

Cover pushCover(BuildContext context) {
  late final Cover cover;
  final route = NbModalRoute<String>(
    context: context,
    builder: (context) => SizedBox.expand(
      child: TextButton(
        onPressed: () {
          cover.taps++;
          closeOwnRoute(context, coverResult);
        },
        child: const Text(coverLabel),
      ),
    ),
  );
  cover = Cover._(route);
  Navigator.of(context).push(route).then((value) {
    cover.result = value;
    cover.finished = true;
  });
  return cover;
}

Finder get coverButton => find.widgetWithText(TextButton, coverLabel);

Finder modalWith(String text) =>
    find.ancestor(of: find.text(text), matching: find.byType(NbModal));

Finder modalButtonIn(Finder modal, String label) => find.descendant(
  of: modal,
  matching: find.widgetWithText(ModalButton, label),
);

List<bool> modalButtonStates(
  WidgetTester tester,
  Finder modal,
  List<String> labels,
) => [
  for (final label in labels)
    tester.widget<ModalButton>(modalButtonIn(modal, label)).onPressed != null,
];

VoidCallback modalButtonAction(
  WidgetTester tester,
  Finder modal,
  String label,
) => tester.widget<ModalButton>(modalButtonIn(modal, label)).onPressed!;

Offset overlapCenter(WidgetTester tester, Finder below, Finder above) {
  final shared = tester.getRect(below).intersect(tester.getRect(above));
  expect(shared.isEmpty, isFalse, reason: 'the two buttons do not overlap');
  return shared.center;
}

ModalRoute<Object?> routeOf(WidgetTester tester, Finder finder) =>
    ModalRoute.of(tester.element(finder))!;
