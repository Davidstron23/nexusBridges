import 'dart:io';

import 'package:nexus_bridges_core/nexus_bridges_core.dart';
import 'package:test/test.dart';

void main() {
  test('the root library exposes SettingsStore and resolveLanguage', () {
    final Function constructor = SettingsStore.new;
    Future<String?> Function() readerOf(SettingsStore store) =>
        store.readLanguage;

    const Type type = SettingsStore;
    expect('$type', 'SettingsStore');
    expect(constructor, isA<Function>());
    expect(readerOf, isA<Function>());
    expect(resolveLanguage(saved: null, platformLanguageCode: 'es'), 'es');
    expect(resolveLanguage(saved: 'en', platformLanguageCode: 'es'), 'en');
  });

  test('the root library does not export pairing', () async {
    final source = await File('lib/nexus_bridges_core.dart').readAsString();

    expect(source.toLowerCase(), isNot(contains('pairing')));
    expect(source, contains("export 'src/settings/settings.dart';"));
  });
}
