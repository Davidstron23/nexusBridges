import 'dart:io';
import 'dart:isolate';

import 'package:nexus_bridges_core/src/network/network.dart';
import 'package:test/test.dart';

final RegExp _guid = RegExp(r'^\{[0-9A-F]{8}(-[0-9A-F]{4}){3}-[0-9A-F]{12}\}$');

const int _loopbackIfType = 24;

const String _leakProbeScript = '''
import 'dart:io';

import 'package:nexus_bridges_core/src/network/network.dart';

void main() {
  final reader = WindowsNetworkSnapshotReader();
  for (var i = 0; i < 20; i++) {
    reader.read();
  }
  final before = ProcessInfo.currentRss;
  for (var i = 0; i < 300; i++) {
    reader.read();
  }
  stdout.writeln(ProcessInfo.currentRss - before);
}
''';

void _expectWellFormed(List<AdapterInfo> adapters) {
  for (var i = 0; i < adapters.length; i++) {
    final a = adapters[i];
    expect(a.id.isNotEmpty, isTrue, reason: 'adapter #$i has an empty id');
    expect(_guid.hasMatch(a.id), isTrue, reason: 'adapter #$i id not a GUID');
    final networkId = a.networkId;
    if (networkId != null) {
      expect(
        _guid.hasMatch(networkId),
        isTrue,
        reason: 'adapter #$i networkId not a GUID',
      );
    }
    for (var j = 0; j < a.ipv4.length; j++) {
      final subnet = a.ipv4[j];
      expect(
        subnet.address.type == InternetAddressType.IPv4,
        isTrue,
        reason: 'adapter #$i address #$j is not IPv4',
      );
      expect(
        subnet.prefixLength >= 0 && subnet.prefixLength <= 32,
        isTrue,
        reason: 'adapter #$i address #$j prefix out of 0..32',
      );
    }
    if (a.ifType == _loopbackIfType) {
      expect(
        a.networkId == null,
        isTrue,
        reason: 'loopback adapter #$i has a networkId',
      );
      expect(
        isUsableAdapter(a),
        isFalse,
        reason: 'loopback adapter #$i is usable',
      );
    }
    if (a.ipv4.any((s) => s.address.isLoopback)) {
      expect(
        a.ifType == _loopbackIfType,
        isTrue,
        reason: 'adapter #$i has a loopback address but ifType is not 24',
      );
    }
  }
}

Set<String> _idsOf(List<AdapterInfo> adapters) => {
  for (final a in adapters) a.id,
};

void main() {
  final skip = Platform.isWindows ? false : 'the reader only exists on Windows';

  group('WindowsNetworkSnapshotReader (W)', () {
    test('read returns well formed adapters without throwing', () {
      final adapters = WindowsNetworkSnapshotReader().read();

      _expectWellFormed(adapters);
      expect(
        _idsOf(adapters).length,
        adapters.length,
        reason: 'adapter ids are not unique',
      );
    });

    test('inside Isolate.run it gives the same adapters', () async {
      final before = WindowsNetworkSnapshotReader().read();
      final inIsolate = await Isolate.run(
        () => WindowsNetworkSnapshotReader().read(),
      );
      final after = WindowsNetworkSnapshotReader().read();

      _expectWellFormed(inIsolate);
      final isolateIds = _idsOf(inIsolate);
      final matchesBefore =
          inIsolate.length == before.length &&
          isolateIds.containsAll(_idsOf(before));
      final matchesAfter =
          inIsolate.length == after.length &&
          isolateIds.containsAll(_idsOf(after));
      expect(
        matchesBefore || matchesAfter,
        isTrue,
        reason: 'the isolate reading differs from the direct readings',
      );
    });

    test('the adapter list is sendable back from an isolate', () async {
      final fromIsolate = await Isolate.run(
        () => WindowsNetworkSnapshotReader().read(),
      );

      for (final a in fromIsolate) {
        expect(a.id, isA<String>());
        expect(a.ipv4, isA<List<Ipv4Subnet>>());
      }
    });

    test('twenty readings in a row keep a stable shape', () {
      final reader = WindowsNetworkSnapshotReader();
      final counts = <int>{};

      for (var i = 0; i < 20; i++) {
        final adapters = reader.read();
        _expectWellFormed(adapters);
        counts.add(adapters.length);
      }

      expect(
        counts.length <= 2,
        isTrue,
        reason: 'the adapter count changed more than once in 20 readings',
      );
    });

    test('three hundred readings do not leak native memory', () async {
      final dir = await Directory.systemTemp.createTemp('nexus_leak_');
      addTearDown(() => dir.delete(recursive: true));
      final script = File(
        '${dir.path}${Platform.pathSeparator}leak_probe.dart',
      );
      await script.writeAsString(_leakProbeScript);
      final packages = await Isolate.packageConfig;

      final result = await Process.run(Platform.resolvedExecutable, [
        '--packages=${packages!.toFilePath()}',
        script.path,
      ]);

      expect(result.exitCode, 0, reason: '${result.stderr}');
      final growth = int.parse((result.stdout as String).trim());
      expect(
        growth < 8 * 1024 * 1024,
        isTrue,
        reason: 'resident memory grew by ${growth ~/ 1024} KiB',
      );
    }, timeout: const Timeout(Duration(minutes: 6)));

    test('the pure functions accept the real reading', () {
      final adapters = WindowsNetworkSnapshotReader().read();

      final usable = adapters.where(isUsableAdapter).toList();
      final trustedAll = evaluateInterfaces(
        adapters,
        (_) => NetworkDecision.trusted,
      );
      final undecided = evaluateInterfaces(adapters, (_) => null);
      final active = activeInterfaces(trustedAll);

      expect(trustedAll.length, usable.length);
      expect(
        trustedAll.every((s) => s.status == InterfaceStatus.active),
        isTrue,
      );
      expect(
        undecided.every((s) => s.status == InterfaceStatus.undecided),
        isTrue,
      );
      expect(
        trustedAll.every(
          (s) =>
              s.adapter.networkId != null &&
              s.adapter.isUp &&
              s.adapter.ifType != _loopbackIfType,
        ),
        isTrue,
      );
      expect(
        active.every((i) => usable.any((a) => a.id == i.adapterId)),
        isTrue,
      );
      expect(active.every((i) => i.id.startsWith('${i.adapterId}#')), isTrue);
    });
  }, skip: skip);
}
