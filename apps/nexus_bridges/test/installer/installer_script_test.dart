import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

const String _scriptPath = '../../installer/nexus_bridges.iss';
const String _ruleName = 'NexusBridges';
const String _netsh = r'{sys}\netsh.exe';

typedef _Netsh = ({List<String> command, Map<String, String> options});

String _readScript() => File(_scriptPath).readAsStringSync();

Map<String, List<String>> _sections(String text) {
  final sections = <String, List<String>>{};
  List<String>? current;
  for (final raw in const LineSplitter().convert(text)) {
    final line = raw.trim();
    if (line.isEmpty) continue;
    final header = RegExp(r'^\[(\w+)\]$').firstMatch(line);
    if (header != null) {
      current = sections.putIfAbsent(header.group(1)!, () => <String>[]);
      continue;
    }
    current?.add(line);
  }
  return sections;
}

List<String> _section(String text, String name) {
  final lines = _sections(text)[name];
  expect(lines, isNotNull, reason: 'missing section [$name]');
  return lines!;
}

bool _isComment(String line) => line.startsWith(';');

Map<String, String> _directives(List<String> lines) {
  final result = <String, String>{};
  for (final line in lines.where((l) => !_isComment(l))) {
    final equals = line.indexOf('=');
    if (equals < 0) continue;
    final key = line.substring(0, equals).trim();
    expect(result.containsKey(key), isFalse, reason: 'duplicated $key');
    result[key] = line.substring(equals + 1).trim();
  }
  return result;
}

Map<String, String> _entry(String line) {
  final parts = <String>[];
  final buffer = StringBuffer();
  var quoted = false;
  for (var i = 0; i < line.length; i++) {
    final char = line[i];
    if (char == '"') quoted = !quoted;
    if (char == ';' && !quoted) {
      parts.add(buffer.toString());
      buffer.clear();
      continue;
    }
    buffer.write(char);
  }
  parts.add(buffer.toString());
  expect(quoted, isFalse, reason: 'unbalanced quotes in: $line');
  final fields = <String, String>{};
  for (final part in parts.map((p) => p.trim()).where((p) => p.isNotEmpty)) {
    final colon = part.indexOf(':');
    expect(colon, greaterThan(0), reason: 'not a "Key: value" field: $part');
    final key = part.substring(0, colon).trim();
    var value = part.substring(colon + 1).trim();
    if (value.length >= 2 && value.startsWith('"') && value.endsWith('"')) {
      value = value.substring(1, value.length - 1).replaceAll('""', '"');
    }
    expect(fields.containsKey(key), isFalse, reason: 'duplicated $key');
    fields[key] = value;
  }
  return fields;
}

List<Map<String, String>> _entries(String text, String section) => [
  for (final line in _section(text, section).where((l) => !_isComment(l)))
    _entry(line),
];

Set<String> _flags(Map<String, String> entry) => (entry['Flags'] ?? '')
    .split(RegExp(r'\s+'))
    .where((f) => f.isNotEmpty)
    .toSet();

_Netsh _parseNetsh(String parameters) {
  final tokens = <String>[];
  final buffer = StringBuffer();
  var quoted = false;
  for (var i = 0; i < parameters.length; i++) {
    final char = parameters[i];
    if (char == '"') {
      quoted = !quoted;
      continue;
    }
    if (char == ' ' && !quoted) {
      if (buffer.isNotEmpty) tokens.add(buffer.toString());
      buffer.clear();
      continue;
    }
    buffer.write(char);
  }
  if (buffer.isNotEmpty) tokens.add(buffer.toString());
  expect(quoted, isFalse, reason: 'unbalanced quotes in: $parameters');
  final command = <String>[];
  final options = <String, String>{};
  for (final token in tokens) {
    final equals = token.indexOf('=');
    if (equals < 0) {
      command.add(token);
      continue;
    }
    final key = token.substring(0, equals);
    expect(options.containsKey(key), isFalse, reason: 'duplicated $key');
    options[key] = token.substring(equals + 1);
  }
  return (command: command, options: options);
}

bool _isNetsh(Map<String, String> entry) => entry['Filename'] == _netsh;

_Netsh _netshOf(Map<String, String> entry) =>
    _parseNetsh(entry['Parameters'] ?? '');

bool _isAddRule(Map<String, String> entry) =>
    _isNetsh(entry) &&
    _netshOf(entry).command.join(' ') == 'advfirewall firewall add rule';

bool _isDeleteRule(Map<String, String> entry) =>
    _isNetsh(entry) &&
    _netshOf(entry).command.join(' ') == 'advfirewall firewall delete rule';

String _define(String text, String name) {
  final match = RegExp(
    '^#define\\s+$name\\s+"([^"]*)"\\s*\$',
    multiLine: true,
  ).firstMatch(text);
  expect(match, isNotNull, reason: 'missing #define $name');
  return match!.group(1)!;
}

Map<String, String> _expectedRule(String text, String protocol) => {
  'name': _ruleName,
  'dir': 'in',
  'action': 'allow',
  'program': '{app}\\${_define(text, 'AppExeName')}',
  'enable': 'yes',
  'profile': 'any',
  'remoteip': 'localsubnet',
  'protocol': protocol,
  'localport': '53530',
};

void main() {
  late String text;

  setUpAll(() {
    text = _readScript();
  });

  group('RF-59: the installer asks for administrator rights once', () {
    test('[Setup] requires admin exactly once', () {
      final setup = _section(text, 'Setup');
      final lines = setup
          .where((l) => !_isComment(l))
          .where((l) => RegExp(r'^PrivilegesRequired\s*=').hasMatch(l))
          .toList();
      expect(lines, hasLength(1));
      expect(_directives(setup)['PrivilegesRequired'], 'admin');
    });

    test('the user cannot lower the privileges', () {
      expect(
        text.contains(
          RegExp('PrivilegesRequiredOverridesAllowed', caseSensitive: false),
        ),
        isFalse,
      );
      expect(
        text.contains(
          RegExp(r'PrivilegesRequired\s*=\s*lowest', caseSensitive: false),
        ),
        isFalse,
      );
    });

    test('the old "No administrator rights needed" comment is gone', () {
      expect(
        text.toLowerCase().contains('no administrator rights needed'),
        isFalse,
      );
    });

    test('installs under Program Files in the NexusBridges folder', () {
      final setup = _directives(_section(text, 'Setup'));
      expect(setup['DefaultDirName'], r'{autopf}\{#AppName}');
      expect(_define(text, 'AppName'), 'NexusBridges');
    });
  });

  group('RF-60: the installer adds the firewall rules', () {
    test(
      '[Run] has one delete and exactly two add rules, all through netsh',
      () {
        final run = _entries(text, 'Run');
        expect(run.where(_isNetsh), hasLength(3));
        expect(run.where(_isDeleteRule), hasLength(1));
        expect(run.where(_isAddRule), hasLength(2));
      },
    );

    test('the TCP rule allows inbound 53530 only from the local subnet', () {
      final rules = _entries(
        text,
        'Run',
      ).where(_isAddRule).map(_netshOf).toList();
      final tcp = rules.where((r) => r.options['protocol'] == 'TCP').toList();
      expect(tcp, hasLength(1));
      expect(tcp.single.options, equals(_expectedRule(text, 'TCP')));
    });

    test('the UDP rule allows inbound 53530 only from the local subnet', () {
      final rules = _entries(
        text,
        'Run',
      ).where(_isAddRule).map(_netshOf).toList();
      final udp = rules.where((r) => r.options['protocol'] == 'UDP').toList();
      expect(udp, hasLength(1));
      expect(udp.single.options, equals(_expectedRule(text, 'UDP')));
    });

    test('the raw add lines keep the doubled quotes Inno Setup expects', () {
      final lines = _section(
        text,
        'Run',
      ).where((l) => l.contains('add rule')).toList();
      expect(lines, hasLength(2));
      for (final line in lines) {
        expect(line, contains('add rule name=""NexusBridges""'));
        expect(line, contains('dir=in action=allow'));
        expect(line, contains(r'program=""{app}\nexus_bridges.exe""'));
        expect(line, contains('enable=yes'));
        expect(line, contains('profile=any'));
        expect(line, contains('remoteip=localsubnet'));
        expect(line, contains('localport=53530'));
        expect(line, contains('Flags: runhidden waituntilterminated'));
      }
    });

    test('every netsh line runs hidden and waits for it to finish', () {
      for (final entry in _entries(text, 'Run').where(_isNetsh)) {
        expect(_flags(entry), {'runhidden', 'waituntilterminated'});
      }
    });

    test('the previous rule is deleted by name before adding the new ones', () {
      final run = _entries(text, 'Run');
      final delete = run.indexWhere(_isDeleteRule);
      final adds = [
        for (var i = 0; i < run.length; i++)
          if (_isAddRule(run[i])) i,
      ];
      expect(delete, isNonNegative);
      expect(adds, hasLength(2));
      expect(delete, lessThan(adds.first));
      expect(_netshOf(run[delete]).options, {'name': _ruleName});
    });

    test('the firewall lines run before the line that opens the app', () {
      final run = _entries(text, 'Run');
      final launch = run.indexWhere((e) => _flags(e).contains('postinstall'));
      expect(launch, isNonNegative);
      for (var i = 0; i < run.length; i++) {
        if (_isNetsh(run[i])) expect(i, lessThan(launch));
      }
    });

    test('[Run] and [UninstallRun] carry no comments', () {
      expect(_section(text, 'Run').where(_isComment), isEmpty);
      expect(_section(text, 'UninstallRun').where(_isComment), isEmpty);
    });
  });

  group('opening the app after installing (plan v2.10 point 5)', () {
    test('runs as the user who installed, as an optional last step', () {
      final run = _entries(text, 'Run');
      final launch = run.where((e) => _flags(e).contains('postinstall'));
      expect(launch, hasLength(1));
      final entry = launch.single;
      expect(entry['Filename'], r'{app}\{#AppExeName}');
      expect(
        _flags(entry),
        containsAll(<String>['postinstall', 'runasoriginaluser', 'nowait']),
      );
      expect(_flags(entry).contains('runascurrentuser'), isFalse);
      expect(_flags(entry).contains('shellexec'), isFalse);
    });

    test('it is the last entry of [Run]', () {
      final run = _entries(text, 'Run');
      expect(_flags(run.last), contains('postinstall'));
    });
  });

  group('RF-61: uninstalling removes the firewall rules', () {
    test('[UninstallRun] deletes the rule by name, hidden, once', () {
      final uninstall = _entries(text, 'UninstallRun');
      expect(uninstall, hasLength(1));
      final entry = uninstall.single;
      expect(_isDeleteRule(entry), isTrue);
      expect(_netshOf(entry).options, {'name': _ruleName});
      expect(_flags(entry), {'runhidden'});
      expect(entry['RunOnceId'], 'DelFirewall');
    });

    test('the raw uninstall line matches the expected text', () {
      final lines = _section(
        text,
        'UninstallRun',
      ).where((l) => !_isComment(l)).toList();
      expect(lines, hasLength(1));
      expect(lines.single, contains('delete rule name=""NexusBridges""'));
      expect(lines.single, contains('Flags: runhidden;'));
      expect(lines.single, contains('RunOnceId: "DelFirewall"'));
    });

    test('it removes the same rule name that the install adds', () {
      final added = _entries(
        text,
        'Run',
      ).where(_isAddRule).map((e) => _netshOf(e).options['name']).toSet();
      final removed = _entries(
        text,
        'UninstallRun',
      ).where(_isDeleteRule).map((e) => _netshOf(e).options['name']).toSet();
      expect(added, {_ruleName});
      expect(removed, added);
    });
  });
}
