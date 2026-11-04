import 'package:flutter_test/flutter_test.dart';
import 'package:nexus_bridges/src/l10n/app_strings.dart';
import 'package:nexus_bridges/src/ui/settings/system_tray_section.dart';

import 'settings_fixtures.dart';

void main() {
  for (final code in const ['es', 'en']) {
    final strings = stringsFor(code);

    testWidgets('$code without a system tray its section is not offered', (
      tester,
    ) async {
      await pumpSettings(tester, code, systemTray: false);
      expect(find.text(strings.sectionSystemTray), findsNothing);
      expect(find.byType(SettingsSwitch), findsNothing);
      expect(find.text(strings.sectionNetworks), findsWidgets);
      expect(tester.takeException(), isNull);
    });

    testWidgets('$code without a system tray the last section is reached', (
      tester,
    ) async {
      await pumpSettings(tester, code, systemTray: false);
      await tester.tap(find.text(strings.sectionIgnored).first);
      await tester.pumpAndSettle();
      expect(find.text(strings.sectionIgnored), findsWidgets);
      expect(tester.takeException(), isNull);
    });
  }
}
