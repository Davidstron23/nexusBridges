import 'dart:io';

import 'package:test/test.dart';

const Map<String, Set<String>> allowedImports = {
  'storage': {},
  'identity': {'storage'},
  'network': {'storage'},
  'pairing': {'storage', 'identity'},
  'settings': {'storage'},
  'protocol': {},
  'transport': {'protocol'},
  'server': {'identity', 'network', 'pairing', 'protocol'},
  'discovery': {'identity', 'network', 'pairing', 'protocol', 'transport'},
  'transfer': {
    'identity',
    'network',
    'pairing',
    'protocol',
    'server',
    'transport',
  },
  'browse': {
    'identity',
    'network',
    'pairing',
    'protocol',
    'server',
    'transport',
  },
  'node': {
    'storage',
    'identity',
    'network',
    'pairing',
    'settings',
    'protocol',
    'server',
    'discovery',
    'transport',
    'transfer',
    'browse',
  },
};

const Set<String> allowedRootExports = {
  'src/node/node.dart',
  'src/settings/settings.dart',
  'src/protocol/protocol_version.dart',
};

const String packageName = 'nexus_bridges_core';
const String rootLibrary = 'nexus_bridges_core.dart';

List<String> findViolations(Map<String, String> files) {
  final violations = <String>[];
  for (final MapEntry(key: path, value: source) in files.entries) {
    if (path != rootLibrary && _moduleOf(path) == null) {
      violations.add('$path: files under lib/src must live in a module');
    }
    for (final uri in _directiveUris(source)) {
      final where = '$path -> $uri';
      if (uri.startsWith('package:flutter/') || uri == 'dart:ui') {
        violations.add('$where: Flutter is not allowed in the core');
        continue;
      }
      final target = _resolve(path, uri);
      if (target == null) continue;
      if (path == rootLibrary) {
        if (!allowedRootExports.contains(target)) {
          violations.add('$where: the root library may not expose $target');
        }
        continue;
      }
      final from = _moduleOf(path);
      if (from == null) continue;
      if (target == rootLibrary) {
        violations.add('$where: modules may not import the root library');
        continue;
      }
      final to = _moduleOf(target);
      if (to == null) {
        violations.add('$where: $target is not inside a module');
        continue;
      }
      if (to == from) continue;
      if (target != 'src/$to/$to.dart') {
        violations.add('$where: only src/$to/$to.dart is public in "$to"');
      }
      final allowed = allowedImports[from];
      if (allowed == null) {
        violations.add('$where: "$from" is not in the module table');
      } else if (!allowed.contains(to)) {
        violations.add('$where: "$from" may not import "$to"');
      }
    }
  }
  return violations;
}

Iterable<String> _directiveUris(String source) sync* {
  final directive = RegExp(
    r'^\s*(?:import|export|part)\b(?!\s+of\b)([^;]*);',
    multiLine: true,
  );
  final literal = RegExp(r'''['"]([^'"]+)['"]''');
  for (final match in directive.allMatches(source)) {
    for (final uri in literal.allMatches(match.group(1)!)) {
      yield uri.group(1)!;
    }
  }
}

String? _resolve(String fromPath, String uri) {
  if (uri.startsWith('dart:')) return null;
  if (uri.startsWith('package:')) {
    const own = 'package:$packageName/';
    return uri.startsWith(own) ? uri.substring(own.length) : null;
  }
  const base = '/package/lib/';
  final resolved = Uri.parse('file://$base$fromPath').resolve(uri).path;
  return resolved.startsWith(base) ? resolved.substring(base.length) : null;
}

String? _moduleOf(String path) {
  final segments = path.split('/');
  if (segments.length < 3 || segments.first != 'src') return null;
  return segments[1];
}

Map<String, String> _readLib() {
  final lib = Directory('lib');
  final files = <String, String>{};
  for (final entity in lib.listSync(recursive: true)) {
    if (entity is! File || !entity.path.endsWith('.dart')) continue;
    final relative = entity.path
        .substring(lib.path.length + 1)
        .replaceAll(Platform.pathSeparator, '/');
    files[relative] = entity.readAsStringSync();
  }
  return files;
}

void main() {
  group('the real lib/ folder', () {
    late Map<String, String> files;

    setUpAll(() => files = _readLib());

    test('is found and contains the existing modules', () {
      final modules = files.keys.map(_moduleOf).whereType<String>().toSet();
      expect(files, contains(rootLibrary));
      expect(modules, containsAll(['storage', 'protocol']));
    });

    test('every module folder is in the module table', () {
      final modules = files.keys.map(_moduleOf).whereType<String>().toSet();
      expect(modules.difference(allowedImports.keys.toSet()), isEmpty);
    });

    test('respects the module boundaries', () {
      expect(findViolations(files), isEmpty);
    });
  });

  test('the module table has no cycles', () {
    final visiting = <String>{};
    final done = <String>{};
    void visit(String module, List<String> trail) {
      if (done.contains(module)) return;
      if (!visiting.add(module)) {
        fail('cycle: ${[...trail, module].join(' -> ')}');
      }
      for (final next in allowedImports[module] ?? const <String>{}) {
        visit(next, [...trail, module]);
      }
      visiting.remove(module);
      done.add(module);
    }

    for (final module in allowedImports.keys) {
      visit(module, const []);
    }
  });

  group('findViolations', () {
    test('accepts allowed relative and package imports of public faces', () {
      expect(
        findViolations({
          'src/identity/identity.dart': '''
import 'dart:io';
import 'package:test/test.dart';
import '../storage/storage.dart';
import 'dpapi.dart';
export 'fingerprint.dart';
''',
          'src/identity/dpapi.dart': "import 'identity.dart';",
          'src/server/server.dart': '''
import 'package:nexus_bridges_core/src/identity/identity.dart';
import '../protocol/protocol.dart' show defaultPort;
import "../network/network.dart" as net;
''',
          'src/node/node.dart': '''
import '../settings/settings.dart';
import '../discovery/discovery.dart';
''',
          rootLibrary: '''
library;
export 'src/protocol/protocol_version.dart';
export 'src/node/node.dart' show NexusNode;
''',
        }),
        isEmpty,
      );
    });

    test('ignores commented-out directives and part of', () {
      expect(
        findViolations({
          'src/storage/storage.dart': '''
/// import '../identity/identity.dart';
// import 'package:flutter/material.dart';
part of 'whatever.dart';
''',
        }),
        isEmpty,
      );
    });

    test('rejects importing the internals of another module', () {
      final violations = findViolations({
        'src/server/server.dart': "import '../identity/dpapi.dart';",
      });
      expect(violations.single, contains('only src/identity/identity.dart'));
    });

    test('rejects internals reached through a package: import', () {
      final violations = findViolations({
        'src/server/server.dart':
            "import 'package:nexus_bridges_core/src/network/adapters.dart';",
      });
      expect(violations.single, contains('only src/network/network.dart'));
    });

    test('rejects a module that the table does not allow', () {
      final violations = findViolations({
        'src/storage/storage.dart': "import '../protocol/protocol.dart';",
      });
      expect(violations.single, contains('"storage" may not import'));
    });

    test('rejects a disallowed export as well as an import', () {
      final violations = findViolations({
        'src/protocol/protocol.dart': "export '../storage/storage.dart';",
      });
      expect(violations.single, contains('"protocol" may not import'));
    });

    test('rejects the alternative of a conditional import', () {
      final violations = findViolations({
        'src/pairing/pairing.dart': '''
import '../storage/storage.dart'
    if (dart.library.io) '../network/network.dart';
''',
      });
      expect(violations.single, contains('"pairing" may not import'));
    });

    test('reports both problems for a disallowed internal import', () {
      final violations = findViolations({
        'src/settings/settings.dart': "import '../identity/dpapi.dart';",
      });
      expect(violations, hasLength(2));
    });

    test('rejects a module that is not in the table', () {
      final violations = findViolations({
        'src/sync/sync.dart': "import '../storage/storage.dart';",
      });
      expect(violations.single, contains('not in the module table'));
    });

    test('rejects modules importing the root library', () {
      expect(
        findViolations({
          'src/storage/storage.dart':
              "import 'package:nexus_bridges_core/nexus_bridges_core.dart';",
          'src/protocol/protocol.dart':
              "import '../../nexus_bridges_core.dart';",
        }),
        hasLength(2),
      );
    });

    test('rejects files under lib/src that are outside a module', () {
      final violations = findViolations({
        'src/protocol_version.dart': 'const String protocolVersion = "1.0";',
      });
      expect(violations.single, contains('must live in a module'));
    });

    test('rejects package:flutter anywhere in lib/', () {
      final violations = findViolations({
        'src/node/node.dart': "import 'package:flutter/foundation.dart';",
        rootLibrary: "export 'package:flutter/widgets.dart';",
        'src/settings/settings.dart': "import 'dart:ui';",
      });
      expect(violations, hasLength(3));
      expect(violations, everyElement(contains('Flutter is not allowed')));
    });

    test('rejects root exports that the plan does not list', () {
      final violations = findViolations({
        rootLibrary: "export 'src/storage/storage.dart';",
      });
      expect(violations.single, contains('may not expose src/storage'));
    });
  });
}
