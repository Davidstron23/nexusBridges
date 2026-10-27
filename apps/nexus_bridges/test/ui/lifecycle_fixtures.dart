import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

const List<AppLifecycleState> _chain = [
  AppLifecycleState.resumed,
  AppLifecycleState.inactive,
  AppLifecycleState.hidden,
  AppLifecycleState.paused,
];

List<AppLifecycleState> lifecyclePath(
  AppLifecycleState? from,
  AppLifecycleState to,
) {
  var index = _chain.indexOf(from ?? AppLifecycleState.resumed);
  final target = _chain.indexOf(to);
  final path = <AppLifecycleState>[];
  while (index != target) {
    index += index < target ? 1 : -1;
    path.add(_chain[index]);
  }
  return path;
}

Future<void> stepLifecycle(WidgetTester tester, AppLifecycleState state) async {
  tester.binding.handleAppLifecycleStateChanged(state);
  await tester.pump();
}

Future<void> goToLifecycle(
  WidgetTester tester,
  AppLifecycleState target,
) async {
  for (final state in lifecyclePath(tester.binding.lifecycleState, target)) {
    await stepLifecycle(tester, state);
  }
}

void resumeOnTearDown(WidgetTester tester) {
  addTearDown(() {
    for (final state in lifecyclePath(
      tester.binding.lifecycleState,
      AppLifecycleState.resumed,
    )) {
      tester.binding.handleAppLifecycleStateChanged(state);
    }
  });
}
