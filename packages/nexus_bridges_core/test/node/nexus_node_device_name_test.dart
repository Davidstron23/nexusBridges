import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:nexus_bridges_core/src/identity/identity.dart';
import 'package:nexus_bridges_core/src/node/node.dart';
import 'package:nexus_bridges_core/src/protocol/protocol.dart'
    show
        Announcement,
        AnnouncementKind,
        ApiPaths,
        DeviceInfo,
        DeviceNameProblem,
        DeviceType,
        Limits,
        multicastGroup,
        protocolVersion;
import 'package:nexus_bridges_core/src/transport/transport.dart';
import 'package:test/test.dart';

import 'two_nodes_harness.dart';

const Duration _fiveSeconds = Duration(seconds: 5);
const Duration _evidenceLimit = Duration(seconds: 15);
const String _rlo = '\u{202E}';
final List<int> _rloBytes = utf8.encode(_rlo);

File _settingsOf(TestNode node) =>
    File('${node.dataDir.path}${sep}settings.json');

Future<Map<String, Object?>?> _savedSettings(TestNode node) async {
  final file = _settingsOf(node);
  if (!await file.exists()) return null;
  return jsonDecode(await file.readAsString()) as Map<String, Object?>;
}

String? _nameIn(TestNode viewer, TestNode other) =>
    viewer.entryOf(other.fingerprint)?.displayName;

String? _discoveredName(TestNode viewer, TestNode other) {
  for (final device in viewer.state.devices) {
    if (device.info.fingerprint == other.fingerprint) return device.info.name;
  }
  return null;
}

bool _showsName(TestNode viewer, TestNode other, String name) =>
    _nameIn(viewer, other) == name && _discoveredName(viewer, other) == name;

Future<Duration> _timeUntil(
  bool Function() condition, {
  required Stopwatch since,
  Duration limit = _evidenceLimit,
  required String reason,
}) async {
  while (!condition()) {
    if (since.elapsed > limit) {
      fail('$reason: not seen within ${since.elapsed}');
    }
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  return since.elapsed;
}

Future<String?> _savedPairedName(TestNode node, TestNode other) async {
  for (final device in await node.savedPaired()) {
    if (device['fingerprint'] == other.fingerprint) {
      return device['name'] as String?;
    }
  }
  return null;
}

void _followRealTime(TestNode node) {
  final base = node.elapsed;
  final watch = Stopwatch()..start();
  final timer = Timer.periodic(const Duration(milliseconds: 10), (_) {
    node.elapsed = base + watch.elapsed;
  });
  addTearDown(timer.cancel);
}

Future<void> _relayHellos(TestNode from, TestNode to) async {
  final socket = await RawDatagramSocket.bind(
    from.address,
    0,
    reuseAddress: false,
  );
  addTearDown(socket.close);
  final subscription = from.channel!.incoming.listen((event) {
    final (announcement, _, _) = event;
    if (announcement.info.fingerprint != from.fingerprint ||
        announcement.kind != AnnouncementKind.hello) {
      return;
    }
    socket.send(announcement.encode(), to.address, to.udpPort);
  });
  addTearDown(subscription.cancel);
}

final class _Capture {
  _Capture._();

  final List<Uint8List> datagrams = [];

  static Future<_Capture> of(TestNode node) async {
    final socket = await RawDatagramSocket.bind(
      node.address == hostA ? hostB : hostA,
      node.udpPort,
      reuseAddress: false,
    );
    addTearDown(socket.close);
    final all = await NetworkInterface.list(includeLoopback: true);
    final loopback = all.firstWhere(
      (i) => i.addresses.any((a) => a.address == '127.0.0.1'),
    );
    socket.joinMulticast(multicastGroup, loopback);
    final capture = _Capture._();
    socket.listen((event) {
      if (event != RawSocketEvent.read) return;
      Datagram? datagram;
      while ((datagram = socket.receive()) != null) {
        capture.datagrams.add(datagram!.data);
      }
    });
    return capture;
  }

  List<String?> namesFrom(String fingerprint) => [
    for (final bytes in datagrams)
      if (Announcement.tryDecode(bytes) case final a?
          when a.info.fingerprint == fingerprint)
        a.info.name,
  ];

  bool anyContains(List<int> needle) =>
      datagrams.any((bytes) => _contains(bytes, needle));
}

bool _contains(List<int> haystack, List<int> needle) {
  if (needle.isEmpty) return true;
  for (var i = 0; i + needle.length <= haystack.length; i++) {
    var match = true;
    for (var j = 0; j < needle.length; j++) {
      if (haystack[i + j] != needle[j]) {
        match = false;
        break;
      }
    }
    if (match) return true;
  }
  return false;
}

bool _fingerprintIs(X509Certificate certificate, String fingerprint) {
  try {
    return fingerprintOfCertificate(certificate.der) == fingerprint;
  } catch (_) {
    return false;
  }
}

Future<Uint8List> _registerBody(TestNode target) async {
  final caller = DeviceIdentity.generate();
  final response = await postJson(
    address: target.address,
    port: target.port,
    path: ApiPaths.register,
    json: DeviceInfo(
      name: 'Probe',
      fingerprint: caller.fingerprint,
      port: 1,
      protocol: protocolVersion,
      deviceType: DeviceType.desktop,
    ).toJson(),
    context: caller.clientContext(presentCertificate: false),
    acceptServer: (certificate) =>
        _fingerprintIs(certificate, target.fingerprint),
    sourceAddress: target.address == hostA ? hostB : hostA,
    timeout: const Duration(seconds: 5),
  );
  expect(response?.status, 200, reason: 'register answered');
  return response!.body;
}

String? _registeredName(Uint8List body) {
  final json = jsonDecode(utf8.decode(body)) as Map<String, Object?>;
  return json['name'] as String?;
}

Future<void> _scannedBy(TestNode scanner, TestNode other) async {
  for (var attempt = 0; attempt < 5; attempt++) {
    await scanner.inZone(() => scanner.node.rescan());
    final watch = Stopwatch()..start();
    while (watch.elapsed < const Duration(seconds: 3)) {
      if (scanner.sees(other) && other.sees(scanner)) return;
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
  }
  fail('${scanner.deviceName} could not find ${other.deviceName}');
}

Future<DeviceNameResult> _rename(TestNode node, String? name) =>
    node.inZone(() => node.node.setDeviceName(name));

void main() {
  group('E803: the new name reaches the other device in 5 s (RF-507, '
      'RF-128)', () {
    test('not paired: B shows the new name of A within 5 s, with the hellos '
        'of A reaching B as on a real network', () async {
      final (a, b) = await twoNodes(nameA: 'Desk PC', nameB: 'Laptop');
      await meet(a, b);
      await _relayHellos(a, b);
      final fingerprint = a.fingerprint;

      final watch = Stopwatch()..start();
      final result = await _rename(a, 'PC David');
      final took = await _timeUntil(
        () => _showsName(b, a, 'PC David'),
        since: watch,
        reason: 'B shows PC David',
      );

      expect(result, const DeviceNameResult());
      expect(took, lessThanOrEqualTo(_fiveSeconds));
      expect(a.state.deviceName, 'PC David');
      expect(a.state.settings.customName, 'PC David');
      expect(a.state.settings.windowsName, 'Desk PC');
      expect(a.fingerprint, fingerprint);
      expect(b.entryOf(a.fingerprint)!.paired, isFalse);
      expect(await _savedSettings(a), {'version': 1, 'deviceName': 'PC David'});
    }, timeout: twoNodesTimeout);

    test(
      'paired: B shows the new name within 5 s and saves it in its '
      'paired.json; the fingerprint does not change and they stay paired',
      () async {
        final (a, b) = await twoNodes(nameA: 'Desk PC', nameB: 'Laptop');
        await meet(a, b);
        await pairNodes(a, b);
        final fingerprint = a.fingerprint;
        expect(await _savedPairedName(b, a), 'Desk PC');

        final watch = Stopwatch()..start();
        await _rename(a, 'PC David');
        final took = await _timeUntil(
          () => _showsName(b, a, 'PC David'),
          since: watch,
          reason: 'B shows PC David',
        );
        await eventually(
          () async => await _savedPairedName(b, a) == 'PC David',
          reason: 'B saves PC David in paired.json',
        );

        expect(took, lessThanOrEqualTo(_fiveSeconds));
        expect(a.fingerprint, fingerprint);
        expect(b.hasPaired(a), isTrue);
        expect(a.hasPaired(b), isTrue);
        expect(
          [for (final d in await b.savedPaired()) d['fingerprint']],
          [fingerprint],
        );
      },
      timeout: twoNodesTimeout,
    );

    test('the name is trimmed before it is applied and saved', () async {
      final (a, b) = await twoNodes(nameA: 'Desk PC', nameB: 'Laptop');
      await meet(a, b);

      final result = await _rename(a, '   PC David  ');

      expect(result.problem, isNull);
      expect(a.state.deviceName, 'PC David');
      expect((await _savedSettings(a))!['deviceName'], 'PC David');
      await b.until(
        (_) => _showsName(b, a, 'PC David'),
        limit: _fiveSeconds,
        reason: 'B shows the trimmed name',
      );
    }, timeout: twoNodesTimeout);

    test('every state emitted after the change carries the new name and the '
        'settings view', () async {
      final (a, _) = await twoNodes(nameA: 'Desk PC', nameB: 'Laptop');
      final before = a.states.length;

      await _rename(a, 'PC David');

      final after = a.states.skip(before).toList();
      expect(after, isNotEmpty);
      expect(after.first.deviceName, 'PC David');
      expect(
        after.first.settings,
        const SettingsView(customName: 'PC David', windowsName: 'Desk PC'),
      );
      expect(a.state.settings.customName, 'PC David');
    }, timeout: twoNodesTimeout);
  });

  group('E804: an invalid name never goes out (RF-508, S1, clarify point '
      '12b)', () {
    test('65 characters, only spaces and a name with U+202E are refused with '
        'their reason, the name does not change and for 3 s no datagram '
        'and no register answer carries them', () async {
      final (a, b) = await twoNodes(nameA: 'Desk PC', nameB: 'Laptop');
      await meet(a, b);
      final capture = await _Capture.of(a);
      final saved = await _savedSettings(a);
      final before = a.states.length;

      final long = await _rename(a, 'x' * 65);
      final blank = await _rename(a, '   ');
      final tricky = await _rename(a, 'PC${_rlo}David');

      expect(long.problem, DeviceNameProblem.tooLong);
      expect(blank.problem, DeviceNameProblem.empty);
      expect(tricky.problem, DeviceNameProblem.invalidCharacters);
      expect(a.state.deviceName, 'Desk PC');
      expect(a.state.settings.customName, isNull);
      expect(await _savedSettings(a), saved);
      expect(a.timers.createdBy('presentNow'), 0);
      expect(
        a.states.skip(before).map((s) => s.deviceName).toSet(),
        anyOf(isEmpty, {'Desk PC'}),
      );

      final watch = Stopwatch()..start();
      final bodies = <Uint8List>[];
      while (watch.elapsed < const Duration(seconds: 3)) {
        bodies.add(await _registerBody(a));
        await b.inZone(() => b.node.rescan());
        await pause();
      }

      expect(capture.namesFrom(a.fingerprint), everyElement('Desk PC'));
      expect(capture.anyContains(_rloBytes), isFalse);
      expect(capture.anyContains(utf8.encode('x' * 65)), isFalse);
      for (final body in bodies) {
        expect(_contains(body, _rloBytes), isFalse);
        expect(_contains(body, utf8.encode('x' * 65)), isFalse);
        expect(_registeredName(body), 'Desk PC');
      }
      expect(_nameIn(b, a), 'Desk PC');

      await _rename(a, 'Desk Renamed');
      await eventually(
        () => capture.namesFrom(a.fingerprint).contains('Desk Renamed'),
        reason: 'control: the capture does hear the hellos of A',
      );
      expect(capture.anyContains(_rloBytes), isFalse);
    }, timeout: twoNodesTimeout);

    test('a refused name keeps the previous custom name', () async {
      final (a, _) = await twoNodes(nameA: 'Desk PC', nameB: 'Laptop');
      await _rename(a, 'PC David');

      final result = await _rename(a, 'PC${_rlo}David');

      expect(result.problem, DeviceNameProblem.invalidCharacters);
      expect(a.state.deviceName, 'PC David');
      expect(a.state.settings.customName, 'PC David');
      expect((await _savedSettings(a))!['deviceName'], 'PC David');
    }, timeout: twoNodesTimeout);

    test('a settings.json written by hand with a 20-character name that has '
        'a U+202E is ignored at start: the Windows name is announced and no '
        'datagram nor register answer carries U+202E', () async {
      final a = await TestNode.create('Desk PC', hostA);
      final b = await TestNode.create('Laptop', hostB);
      final port = await freePort();
      a.port = port;
      b.port = port;
      final tricky = 'PC David ${_rlo}gpj.exe.ab';
      expect(tricky.runes.length, 20);
      await a.dataDir.create(recursive: true);
      await _settingsOf(a)
          .writeAsString(jsonEncode({'version': 1, 'deviceName': tricky}));

      final before = a.logs.length;
      await a.boot();
      final capture = await _Capture.of(a);
      expect(await a.listenSince(before), isTrue);
      expect(await b.launch(), isTrue);
      await meet(a, b);
      final body = await _registerBody(a);
      await eventually(
        () => capture.namesFrom(a.fingerprint).isNotEmpty,
        reason: 'the start hello of A',
      );

      expect(a.state.deviceName, 'Desk PC');
      expect(a.state.settings.customName, isNull);
      expect(a.state.settings.windowsName, 'Desk PC');
      expect(capture.namesFrom(a.fingerprint), everyElement('Desk PC'));
      expect(capture.anyContains(_rloBytes), isFalse);
      expect(_contains(body, _rloBytes), isFalse);
      expect(_registeredName(body), 'Desk PC');
      expect(_nameIn(b, a), 'Desk PC');
      expect(await _settingsOf(a).readAsString(), contains(_rlo));
    }, timeout: twoNodesTimeout);

    test('a saved name that only fails the fine rule (5 combining marks) is '
        'ignored too, and a valid saved name is used', () async {
      final a = await TestNode.create('Desk PC', hostA);
      a.port = await freePort();
      await a.dataDir.create(recursive: true);
      await _settingsOf(a).writeAsString(
        jsonEncode({'version': 1, 'deviceName': 'PC e${'\u{301}' * 5}'}),
      );
      expect(await a.launch(), isTrue);
      expect(a.state.deviceName, 'Desk PC');
      expect(a.state.settings.customName, isNull);

      await a.node.shutdown();
      await _settingsOf(a)
          .writeAsString(jsonEncode({'version': 1, 'deviceName': 'PC David'}));
      await a.restart();
      expect(a.state.deviceName, 'PC David');
      expect(a.state.settings.customName, 'PC David');
    }, timeout: twoNodesTimeout);
  });

  group('E806: back to the Windows name and restarts (RF-507, RF-504, '
      'DA-8)', () {
    test('setDeviceName(null) brings back the Windows name, B sees it within '
        '5 s and the key leaves settings.json', () async {
      final (a, b) = await twoNodes(nameA: 'Desk PC', nameB: 'Laptop');
      await meet(a, b);
      _followRealTime(b);
      await _rename(a, 'PC David');
      await b.until(
        (_) => _showsName(b, a, 'PC David'),
        reason: 'B shows PC David',
      );
      await pause(_fiveSeconds);

      final watch = Stopwatch()..start();
      final result = await _rename(a, null);
      final took = await _timeUntil(
        () => _showsName(b, a, 'Desk PC'),
        since: watch,
        reason: 'B shows Desk PC again',
      );

      expect(result, const DeviceNameResult());
      expect(took, lessThanOrEqualTo(_fiveSeconds));
      expect(a.state.deviceName, 'Desk PC');
      expect(a.state.settings.customName, isNull);
      expect(await _savedSettings(a), {'version': 1});
    }, timeout: twoNodesTimeout);

    test('a restart keeps the custom name; with another Windows name it is '
        'still the custom one; without a custom name it is the new Windows '
        'name', () async {
      final (a, b) = await twoNodes(nameA: 'Desk PC', nameB: 'Laptop');
      await _rename(a, 'PC David');

      await a.restart();
      expect(a.state.deviceName, 'PC David');
      expect(a.state.settings.customName, 'PC David');
      expect(a.state.settings.windowsName, 'Desk PC');
      await meet(a, b);
      expect(_nameIn(b, a), 'PC David');

      await a.restart(deviceName: 'DESKTOP-NEW');
      expect(a.state.deviceName, 'PC David');
      expect(a.state.settings.windowsName, 'DESKTOP-NEW');

      await _rename(a, null);
      await a.restart(deviceName: 'DESKTOP-OTHER');
      expect(a.state.deviceName, 'DESKTOP-OTHER');
      expect(a.state.settings.customName, isNull);
      expect(a.state.settings.windowsName, 'DESKTOP-OTHER');
    }, timeout: twoNodesTimeout);

    test('writing exactly the Windows name saves it as custom, so another '
        'Windows name later does not replace it', () async {
      final (a, _) = await twoNodes(nameA: 'Desk PC', nameB: 'Laptop');

      final result = await _rename(a, 'Desk PC');

      expect(result, const DeviceNameResult());
      expect(a.state.settings.customName, 'Desk PC');
      expect((await _savedSettings(a))!['deviceName'], 'Desk PC');

      await a.restart(deviceName: 'DESKTOP-NEW');
      expect(a.state.deviceName, 'Desk PC');
      expect(a.state.settings.customName, 'Desk PC');
      expect(a.state.settings.windowsName, 'DESKTOP-NEW');
    }, timeout: twoNodesTimeout);

    test('the same name again, or null without a custom name, changes '
        'nothing and writes nothing', () async {
      final (a, _) = await twoNodes(nameA: 'Desk PC', nameB: 'Laptop');

      expect(await _rename(a, null), const DeviceNameResult());
      expect(await _settingsOf(a).exists(), isFalse);
      expect(a.timers.createdBy('setDeviceName'), 0);

      await _rename(a, 'PC David');
      await _settingsOf(a).delete();
      final presented = a.timers.createdBy('setDeviceName');

      expect(await _rename(a, ' PC David '), const DeviceNameResult());
      expect(await _settingsOf(a).exists(), isFalse);
      expect(a.timers.createdBy('setDeviceName'), presented);
      expect(a.state.deviceName, 'PC David');
    }, timeout: twoNodesTimeout);
  });

  group('E807: namesakeOf (RF-509)', () {
    test(
      'finds a listed device with the same name without minding case or '
      'accents, gives null without a match, and that name can be saved',
      () async {
        final (a, b) = await twoNodes(nameA: 'Desk PC', nameB: 'ROG Ally');
        await meet(a, b);

        expect(a.node.namesakeOf('rog ally'), 'ROG Ally');
        expect(a.node.namesakeOf('Rog All\u{FD}'), 'ROG Ally');
        expect(a.node.namesakeOf('Laptop'), isNull);
        expect(a.node.namesakeOf('Desk PC'), isNull);

        final result = await _rename(a, 'rog ally');
        expect(result, const DeviceNameResult());
        expect(a.state.deviceName, 'rog ally');
      },
      timeout: twoNodesTimeout,
    );

    test('a paired device that is not in sight is also a namesake', () async {
      final (a, b) = await twoNodes(nameA: 'Desk PC', nameB: 'ROG Ally');
      await meet(a, b);
      await pairNodes(a, b);
      await b.node.shutdown();
      a.advance(const Duration(seconds: 31));
      await a.until((_) => !a.sees(b), reason: 'B out of sight');

      expect(a.node.namesakeOf('rog ally'), 'ROG Ally');
      expect(a.node.namesakeOf('Laptop'), isNull);
    }, timeout: twoNodesTimeout);

    test('without devices it gives null', () async {
      final (a, _) = await twoNodes(nameA: 'Desk PC', nameB: 'ROG Ally');

      expect(a.node.namesakeOf('ROG Ally'), isNull);
    }, timeout: twoNodesTimeout);
  });

  group('E808: the name cannot be saved (RF-503)', () {
    test('with settings.json turned into a folder the new name is announced '
        'anyway, B sees it, and the result says not saved with the '
        'settingNotSaved notice', () async {
      final (a, b) = await twoNodes(nameA: 'Desk PC', nameB: 'Laptop');
      await meet(a, b);
      final file = _settingsOf(a);
      if (await file.exists()) await file.delete();
      await Directory(file.path).create();

      final watch = Stopwatch()..start();
      final result = await _rename(a, 'PC David');
      final took = await _timeUntil(
        () => _showsName(b, a, 'PC David'),
        since: watch,
        reason: 'B shows PC David',
      );

      expect(result, const DeviceNameResult(saved: false));
      expect(result.problem, isNull);
      expect(took, lessThanOrEqualTo(_fiveSeconds));
      expect(a.state.deviceName, 'PC David');
      expect(a.state.settings.customName, 'PC David');
      final notices = a.noticesOf(NoticeKind.settingNotSaved);
      expect(notices, hasLength(1));
      expect(notices.single.canRetry, isFalse);
      expect(await Directory(file.path).exists(), isTrue);
      expect(
        a.logs.where((line) => line.contains('PC David')),
        isEmpty,
        reason: 'logs never carry the device name',
      );
    }, timeout: twoNodesTimeout);
  });

  group('E809: two changes in a row and manual search (RF-507, clarify '
      'point 6)', () {
    test('two changes 2 s apart: B shows the second one about 5 s after it '
        '(the second hello of A at 5 s plus the HTTPS check)', () async {
      final (a, b) = await twoNodes(nameA: 'Desk PC', nameB: 'Laptop');
      await meet(a, b);
      await _relayHellos(a, b);
      _followRealTime(b);

      final first = Stopwatch()..start();
      await _rename(a, 'Name One');
      await _timeUntil(
        () => _showsName(b, a, 'Name One'),
        since: first,
        reason: 'B shows Name One',
      );
      while (first.elapsed < const Duration(seconds: 2)) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      final second = Stopwatch()..start();
      await _rename(a, 'Name Two');
      final took = await _timeUntil(
        () => _showsName(b, a, 'Name Two'),
        since: second,
        reason: 'B shows Name Two',
      );

      printOnFailure('second name seen after $took');
      expect(
        took,
        lessThanOrEqualTo(_fiveSeconds + const Duration(milliseconds: 750)),
      );
    }, timeout: twoNodesTimeout);

    test(
      'B knows A only through the manual search of A (no multicast, the '
      'subnet hosts of the harness): B shows the new name of A within 5 s',
      () async {
        final (a, b) = await twoNodes(nameA: 'Desk PC', nameB: 'Laptop');
        await _scannedBy(a, b);

        final watch = Stopwatch()..start();
        await _rename(a, 'PC David');
        final took = await _timeUntil(
          () => _showsName(b, a, 'PC David'),
          since: watch,
          reason: 'B shows PC David',
        );

        expect(took, lessThanOrEqualTo(_fiveSeconds));
        expect(a.timers.createdBy('presentNow'), greaterThan(0));
      },
      timeout: twoNodesTimeout,
    );

    test('two changes 2 s apart with no multicast (B knows A only through the '
        'manual search of A): B shows the second one within 5 s', () async {
      final (a, b) = await twoNodes(nameA: 'Desk PC', nameB: 'Laptop');
      await _scannedBy(a, b);
      _followRealTime(b);

      final first = Stopwatch()..start();
      await _rename(a, 'Name One');
      await _timeUntil(
        () => _showsName(b, a, 'Name One'),
        since: first,
        reason: 'B shows Name One',
      );
      while (first.elapsed < const Duration(seconds: 2)) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      final second = Stopwatch()..start();
      await _rename(a, 'Name Two');
      final took = await _timeUntil(
        () => _showsName(b, a, 'Name Two'),
        since: second,
        reason: 'B shows Name Two (it still shows ${_nameIn(b, a)})',
      );

      expect(took, lessThanOrEqualTo(_fiveSeconds));
    }, timeout: twoNodesTimeout);
    test(
      'a change while a periodic presentation of A to B is in flight (A '
      'knows B only through its manual search, no multicast, presentations '
      'every 10 s as in production): B shows the new name within 5 s',
      () async {
        final (a, b) = await twoNodes(
          nameA: 'Desk PC',
          nameB: 'Laptop',
          present: Limits.announceInterval,
        );
        await _scannedBy(a, b);
        _followRealTime(b);

        for (var attempt = 0; attempt < 3; attempt++) {
          final name = 'Renamed $attempt';
          final inFlight = Stopwatch()..start();
          while (!a.timers.active.any((t) => t.contains('_presentToScanned'))) {
            if (inFlight.elapsed > const Duration(seconds: 25)) {
              fail('no periodic presentation of A to B started');
            }
            await Future<void>.delayed(const Duration(milliseconds: 1));
          }
          final presentedBefore = a.timers.createdBy('presentNow');
          final watch = Stopwatch()..start();
          final renamed = _rename(a, name);
          await renamed;
          final skipped = a.timers.createdBy('presentNow') == presentedBefore;
          if (!skipped) {
            await _timeUntil(
              () => _showsName(b, a, name),
              since: watch,
              reason: 'B shows $name',
            );
            await pause(const Duration(seconds: 1));
            continue;
          }
          final took = await _timeUntil(
            () => _showsName(b, a, name),
            since: watch,
            reason: 'B shows $name after a skipped presentNow',
          );
          expect(
            took,
            lessThanOrEqualTo(_fiveSeconds),
            reason:
                'presentNow skipped B because a register was in flight; B '
                'showed the new name only after $took',
          );
          return;
        }
        markTestSkipped('the in-flight window was not hit in 3 attempts');
      },
      timeout: const Timeout(Duration(minutes: 3)),
    );
  });
}
