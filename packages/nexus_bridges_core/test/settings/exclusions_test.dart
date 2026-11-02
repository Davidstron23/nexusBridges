import 'dart:convert';
import 'dart:io';

import 'package:nexus_bridges_core/src/settings/settings.dart';
import 'package:nexus_bridges_core/src/storage/storage.dart';
import 'package:test/test.dart';

void main() {
  late Directory dataDir;
  late File settingsFile;

  setUp(() async {
    dataDir = await Directory.systemTemp.createTemp('nexus_t8_exclusions_');
    addTearDown(() => dataDir.delete(recursive: true));
    settingsFile = File(
      '${dataDir.path}${Platform.pathSeparator}settings.json',
    );
  });

  Future<List<String>?> exclusionsIn(String? content) async {
    if (content != null) await settingsFile.writeAsString(content);
    return SettingsStore(JsonFileStore(settingsFile)).readExclusions();
  }

  String withList(Object? list) =>
      jsonEncode({'version': 1, 'language': 'es', 'exclusions': list});

  List<String> namesInData() =>
      dataDir
          .listSync()
          .map((e) => e.path.substring(e.path.lastIndexOf(r'\') + 1))
          .toList()
        ..sort();

  group('E403, RF-254: SettingsStore.readExclusions', () {
    test('a saved list of names is given back as it is', () async {
      expect(await exclusionsIn(withList(['vendor', 'dist', '.cache'])), [
        'vendor',
        'dist',
        '.cache',
      ]);
    });

    test('an empty saved list is a choice of the user and is given back '
        'empty', () async {
      expect(await exclusionsIn(withList(<String>[])), isEmpty);
      expect(await exclusionsIn(withList(<String>[])), isNotNull);
    });

    test('64 names of 255 units are still read', () async {
      final names = [for (var i = 0; i < 64; i++) '$i'.padLeft(255, 'n')];

      expect(await exclusionsIn(withList(names)), names);
    });

    test('without a file it gives null and creates nothing', () async {
      expect(await exclusionsIn(null), isNull);
      expect(namesInData(), isEmpty);
    });

    final unreadable = <String, String>{
      'no exclusions key': '{"version": 1, "language": "es"}',
      'a string instead of a list': withList('node_modules'),
      'a map instead of a list': withList({'a': 'b'}),
      'a null list': withList(null),
      'a number in the list': withList(['vendor', 5]),
      'a null in the list': withList(['vendor', null]),
      'an empty name': withList(['vendor', '']),
      'a name of 256 units': withList(['x' * 256]),
      '65 names': withList([for (var i = 0; i < 65; i++) 'n$i']),
      'version 2': jsonEncode({
        'version': 2,
        'exclusions': ['vendor'],
      }),
      'no version': jsonEncode({
        'exclusions': ['vendor'],
      }),
      'broken JSON': '{"version": 1, "exclusions": ["vendor"]',
      'a JSON array': '["vendor"]',
      'an empty file': '',
    };

    for (final MapEntry(key: label, value: content) in unreadable.entries) {
      test('$label gives null and the file stays as it was', () async {
        expect(await exclusionsIn(content), isNull);
        expect(await settingsFile.readAsString(), content);
        expect(namesInData(), ['settings.json']);
      });
    }

    test('a folder named settings.json gives null without throwing', () async {
      Directory(settingsFile.path).createSync();

      expect(await exclusionsIn(null), isNull);
    });
  });
}
