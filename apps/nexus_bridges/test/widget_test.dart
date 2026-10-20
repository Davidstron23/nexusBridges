import 'package:flutter_test/flutter_test.dart';
import 'package:nexus_bridges/main.dart';
import 'package:nexus_bridges_core/nexus_bridges_core.dart';

void main() {
  testWidgets('shows the app name and the protocol version', (tester) async {
    await tester.pumpWidget(const NexusBridgesApp());

    expect(
      find.text('NexusBridges · protocol $protocolVersion'),
      findsOneWidget,
    );
  });
}
