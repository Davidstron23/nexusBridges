import 'dart:io';
import 'dart:math';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nexus_bridges/src/app_controller.dart';
import 'package:nexus_bridges/src/l10n/app_strings.dart';
import 'package:nexus_bridges/src/ui/format.dart';
import 'package:nexus_bridges/src/ui/settings/settings_controller.dart';
import 'package:nexus_bridges/src/ui/settings/settings_field.dart'
    show SettingsLink;
import 'package:nexus_bridges_core/nexus_bridges_core.dart';
import 'package:nexus_bridges_core/src/discovery/discovery.dart'
    show MulticastChannel;
import 'package:nexus_bridges_core/src/network/network.dart'
    show ActiveInterface, InterfaceStatus;
import 'package:nexus_bridges_core/src/protocol/protocol.dart'
    show multicastGroup;
import 'package:nexus_bridges_core/src/transfer/transfer.dart'
    show FilePicker, FileSystemPlatform, WindowsFileSystemPlatform;
import 'package:nexus_bridges_core/src/transfer/platform.dart'
    show FreeNameMove, MoveOutcome, SystemFolders, VolumeFacts;

import '../fake_app_controller.dart';
import '../segoe_font.dart';
import 'settings_fixtures.dart';

const String _network = '{NETWORK-HOME}';
const String _adapterId = '{WIFI-ADAPTER}';
const Duration _limit = Duration(seconds: 30);
const Duration _listenLimit = Duration(seconds: 10);
const int _startAttempts = 4;
const Duration _renameBudget = Duration(milliseconds: 5750);
const Duration _leaveBudget = Duration(seconds: 5);

final Random _random = Random();
int _pointer = 7000;

final class _XorProtector implements SecretProtector {
  static Uint8List _xor(Uint8List data) =>
      Uint8List.fromList([for (final b in data) b ^ 0x5A]);

  @override
  Uint8List protect(Uint8List data) => _xor(data);

  @override
  Uint8List? unprotect(Uint8List data) => _xor(data);
}

AdapterInfo _adapter() => AdapterInfo(
  id: _adapterId,
  friendlyName: 'Wi-Fi',
  description: 'Test wireless adapter',
  ifType: 71,
  isUp: true,
  ipv4: [Ipv4Subnet(InternetAddress('192.168.50.21'), 24)],
  hasGateway: true,
  networkId: _network,
  networkName: 'Home',
);

Future<bool> _tcpFree(String host, int port) async {
  try {
    final socket = await ServerSocket.bind(InternetAddress(host), port);
    await socket.close();
    return true;
  } on SocketException {
    return false;
  }
}

Future<bool> _udpFree(int port) async {
  try {
    final socket = await RawDatagramSocket.bind(
      InternetAddress.anyIPv4,
      port,
      reuseAddress: false,
    );
    socket.close();
    return true;
  } on SocketException {
    return false;
  }
}

Future<int> _pickPort({List<String> tcp = const [], bool udp = false}) async {
  final slice = 20000 + (pid % 280) * 100;
  for (var attempt = 0; attempt < 2000; attempt++) {
    final port = attempt < 200
        ? slice + _random.nextInt(100)
        : 20000 + _random.nextInt(29000);
    var free = true;
    for (final host in tcp) {
      if (!await _tcpFree(host, port)) free = false;
    }
    if (free && udp && !await _udpFree(port)) free = false;
    if (free) return port;
  }
  throw StateError('no free port');
}

Future<String> _loopbackName() async {
  final all = await NetworkInterface.list(includeLoopback: true);
  return all
      .firstWhere((i) => i.addresses.any((a) => a.address == '127.0.0.1'))
      .name;
}

Future<void> _until(
  bool Function() condition,
  String reason, {
  Duration limit = _limit,
}) async {
  final watch = Stopwatch()..start();
  while (!condition()) {
    if (watch.elapsed > limit) fail('$reason not met within $limit');
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}

final class _Picker implements FilePicker {
  final List<String?> folders = [];
  int folderCalls = 0;

  @override
  Future<String?> pickFolder({String? startIn}) async {
    folderCalls++;
    return folders.isEmpty ? null : folders.removeAt(0);
  }

  @override
  Future<String?> pickFile() async => null;

  @override
  Future<List<String>> pickFiles() async => const [];

  @override
  Future<List<String>> pickFolders() async => const [];
}

final class _CloudPlatform implements FileSystemPlatform {
  const _CloudPlatform();

  static const FileSystemPlatform _inner = WindowsFileSystemPlatform();

  @override
  Future<bool> isCloudSynced(String path) async =>
      path.toLowerCase().contains('nube');

  @override
  Future<String?> realPath(String path) => _inner.realPath(path);

  @override
  Future<VolumeFacts?> volumeFacts(String path) => _inner.volumeFacts(path);

  @override
  Future<int?> freeBytes(String path) => _inner.freeBytes(path);

  @override
  Future<SystemFolders> systemFolders() => _inner.systemFolders();

  @override
  Future<bool> setHidden(String path) => _inner.setHidden(path);

  @override
  Future<MoveOutcome> moveNoReplace(String from, String to) =>
      _inner.moveNoReplace(from, to);

  @override
  Future<FreeNameMove> moveToFreeName(
    String from,
    String folder,
    String name,
  ) => _inner.moveToFreeName(from, folder, name);

  @override
  Future<FreeNameMove> moveFolderToFreeName(
    String from,
    String folder,
    String name, {
    required int maxNameUnits,
  }) => _inner.moveFolderToFreeName(
    from,
    folder,
    name,
    maxNameUnits: maxNameUnits,
  );

  @override
  Future<bool> markFromInternet(String filePath) =>
      _inner.markFromInternet(filePath);

  @override
  Future<bool> deleteTree(String path) => _inner.deleteTree(path);

  @override
  Future<bool> isDangerousType(String extension) =>
      _inner.isDangerousType(extension);

  @override
  Future<Set<String>> dangerousExtensions(Set<String> extensions) =>
      _inner.dangerousExtensions(extensions);
}

final class _Side {
  _Side(this.name, this.address);

  final String name;
  final String address;
  final List<String> logs = [];
  final _Picker picker = _Picker();
  List<AdapterInfo> adapters = [_adapter()];
  late Directory root;
  late MulticastChannel channel;
  late int channelPort;
  late NexusNode node;
  late AppController controller;
  final SettingsController settings = SettingsController();
  bool _hasRoot = false;
  bool _hasChannel = false;
  bool _hasNode = false;
  bool _hasController = false;

  String get fingerprint => node.state.fingerprint;

  NodeState get state => node.state;

  String get base => root.path;

  DeviceEntry? entryOf(_Side other) {
    for (final entry in state.entries) {
      if (entry.fingerprint == other.fingerprint) return entry;
    }
    return null;
  }

  bool sees(_Side other) => entryOf(other)?.visible ?? false;

  Future<void> start({
    required int port,
    required int channelPort,
    required String loopback,
    required String code,
    bool listening = true,
  }) async {
    root = await Directory.systemTemp.createTemp('nexus_app_settings_');
    _hasRoot = true;
    this.channelPort = channelPort;
    channel = MulticastChannel(port: channelPort, log: logs.add);
    _hasChannel = true;
    final started = await NexusNode.start(
      dataDir: Directory('${root.path}${Platform.pathSeparator}data'),
      protector: _XorProtector(),
      readNetworks: () async => adapters,
      port: port,
      deviceName: name,
      log: logs.add,
      activeOf: (states) => [
        for (final state in states)
          if (state.status == InterfaceStatus.active)
            ActiveInterface(
              id: '${state.adapter.id}#$address',
              adapterId: state.adapter.id,
              friendlyName: loopback,
              subnet: Ipv4Subnet(InternetAddress(address), 30),
            ),
      ],
      pollInterval: const Duration(milliseconds: 200),
      channel: channel,
      picker: picker,
      fileSystem: const _CloudPlatform(),
    );
    node = started;
    _hasNode = true;
    await _until(
      () => started.state.prompts.isNotEmpty || !started.state.paused,
      '$name network read',
    );
    if (started.state.prompts.isNotEmpty) {
      await started.decideNetwork(_network, NetworkDecision.trusted);
    }
    await _until(() => !started.state.paused, '$name active');
    if (listening) {
      await _until(
        () => logs.any((line) => line.startsWith('listening on ')),
        '$name listening',
        limit: _listenLimit,
      );
    }
    controller = AppController(
      startNode: () async => started,
      loadStartup: () async => StartupSettings(language: code),
      settingsOpen: () => settings.isOpen,
    );
    await controller.init();
    _hasController = true;
  }

  Future<void> stop() async {
    if (_hasController) {
      await controller.shutdown();
    } else if (_hasNode) {
      await node.shutdown();
    }
    if (_hasChannel) await channel.close();
    if (!_hasRoot) return;
    for (var attempt = 0; attempt < 40; attempt++) {
      try {
        if (root.existsSync()) await root.delete(recursive: true);
        return;
      } on FileSystemException {
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
    }
  }
}

Future<_Side> _oneSide(String code) async {
  final loopback = await _loopbackName();
  for (var attempt = 1; ; attempt++) {
    final a = _Side('Node A', '127.0.0.1');
    try {
      await a.start(
        port: await _pickPort(tcp: [a.address]),
        channelPort: await _pickPort(udp: true),
        loopback: loopback,
        code: code,
        listening: false,
      );
      return a;
    } on TestFailure {
      await a.stop();
      if (attempt >= _startAttempts) rethrow;
    }
  }
}

Future<(_Side, _Side)> _twoSides(String code) async {
  final loopback = await _loopbackName();
  for (var attempt = 1; ; attempt++) {
    final a = _Side('Node A', '127.0.0.1');
    final b = _Side('Node B', '127.0.0.2');
    try {
      final port = await _pickPort(tcp: [a.address, b.address]);
      await a.start(
        port: port,
        channelPort: await _pickPort(udp: true),
        loopback: loopback,
        code: code,
      );
      await b.start(
        port: port,
        channelPort: await _pickPort(udp: true),
        loopback: loopback,
        code: code,
      );
      for (var round = 0; round < 5 && !(a.sees(b) && b.sees(a)); round++) {
        await a.node.rescan();
        await b.node.rescan();
        final watch = Stopwatch()..start();
        while (watch.elapsed < const Duration(seconds: 3) &&
            !(a.sees(b) && b.sees(a))) {
          await Future<void>.delayed(const Duration(milliseconds: 10));
        }
      }
      await _until(() => a.sees(b) && b.sees(a), 'nodes see each other');
      return (a, b);
    } on TestFailure {
      await a.stop();
      await b.stop();
      if (attempt >= _startAttempts) rethrow;
    }
  }
}

Future<void> _real(WidgetTester tester, bool Function() condition, String why) {
  return tester.runAsync(() => _until(condition, why));
}

Future<void> _untilUi(
  WidgetTester tester,
  bool Function() condition,
  String why,
) async {
  final watch = Stopwatch()..start();
  while (!condition()) {
    if (watch.elapsed > _limit) fail('$why not met within $_limit');
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 20)),
    );
    await tester.pump(const Duration(milliseconds: 20));
  }
}

final class _Relay {
  _Relay._(this._listen, this._send);

  final RawDatagramSocket _listen;
  final RawDatagramSocket _send;

  static Future<_Relay> between(_Side from, _Side to) async {
    final listen = await RawDatagramSocket.bind(
      to.address,
      from.channelPort,
      reuseAddress: false,
    );
    final send = await RawDatagramSocket.bind(
      from.address,
      0,
      reuseAddress: false,
    );
    final all = await NetworkInterface.list(includeLoopback: true);
    final loopback = all.firstWhere(
      (i) => i.addresses.any((a) => a.address == '127.0.0.1'),
    );
    listen.joinMulticast(multicastGroup, loopback);
    listen.listen((event) {
      if (event != RawSocketEvent.read) return;
      Datagram? datagram;
      while ((datagram = listen.receive()) != null) {
        send.send(datagram!.data, InternetAddress.loopbackIPv4, to.channelPort);
      }
    });
    return _Relay._(listen, send);
  }

  void close() {
    _listen.close();
    _send.close();
  }
}

Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 6; i++) {
    await tester.pump(const Duration(milliseconds: 150));
  }
}

bool _pressable(Finder target) {
  var enabled = true;
  target.evaluate().single.visitAncestorElements((ancestor) {
    final widget = ancestor.widget;
    if (widget is ButtonStyleButton) {
      enabled = widget.onPressed != null;
      return false;
    }
    if (widget is SettingsLink) {
      enabled = widget.onPressed != null;
      return false;
    }
    return true;
  });
  return enabled;
}

Future<void> _click(WidgetTester tester, Finder target) async {
  expect(target, findsOneWidget);
  await _untilUi(tester, () => _pressable(target), 'the button is enabled');
  final center = tester.getCenter(target);
  final pointer = _pointer++;
  await tester.runAsync(() async {
    final binding = GestureBinding.instance;
    binding.handlePointerEvent(
      PointerDownEvent(pointer: pointer, position: center),
    );
    binding.handlePointerEvent(
      PointerUpEvent(pointer: pointer, position: center),
    );
  });
  await _settle(tester);
}

Future<void> _mount(WidgetTester tester, _Side side, String code) async {
  setSize(tester, const Size(1200, 2600));
  await tester.pumpWidget(
    homeApp(side.controller, code, settings: side.settings),
  );
  await _settle(tester);
  await _click(tester, find.byTooltip(stringsFor(code).settingsButton));
  expect(side.settings.isOpen, isTrue);
}

Finder _rowButton(String label) => find.descendant(
  of: find.byKey(const ValueKey('network-$_network')),
  matching: find.ancestor(
    of: find.text(label),
    matching: find.byWidgetPredicate((widget) => widget is ButtonStyleButton),
  ),
);

void main() {
  setUpAll(loadSegoe);
  const code = 'es';
  final strings = stringsFor(code);

  testWidgets(
    'RF-507 with two real nodes: "PC David" with Enter in Settings reaches '
    'the other node in 5 s (750 ms of margin) and the subtitle changes',
    (tester) async {
      final sides = await tester.runAsync(() => _twoSides(code));
      final (a, b) = sides!;
      try {
        await _mount(tester, a, code);
        final field = textField(strings.sectionDevice);
        await tester.enterText(field, 'PC David');
        await tester.pump();

        final watch = Stopwatch();
        await tester.runAsync(() async {
          watch.start();
          await tester.testTextInput.receiveAction(TextInputAction.done);
        });
        await _real(
          tester,
          () => b.entryOf(a)?.displayName == 'PC David',
          'B sees the new name',
        );
        watch.stop();
        expect(watch.elapsed, lessThanOrEqualTo(_renameBudget));
        expect(a.state.deviceName, 'PC David');
        expect(a.state.settings.customName, 'PC David');

        await _settle(tester);
        expect(find.text(strings.settingsSubtitle('PC David')), findsOneWidget);
        expect(
          find.text(strings.useWindowsName(a.state.settings.windowsName)),
          findsOneWidget,
        );

        await _click(
          tester,
          find.text(strings.useWindowsName(a.state.settings.windowsName)),
        );
        await _real(
          tester,
          () => b.entryOf(a)?.displayName == a.state.settings.windowsName,
          'B sees the Windows name again',
        );
        expect(a.state.settings.customName, isNull);
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.runAsync(() async {
          await a.stop();
          await b.stop();
        });
      }
    },
    timeout: const Timeout(Duration(minutes: 3)),
  );

  testWidgets(
    'E875 with two real nodes: stopping the connected network asks with its '
    'danger confirmation, the app pauses and the other node stops seeing '
    'this one in 5 s',
    (tester) async {
      final sides = await tester.runAsync(() => _twoSides(code));
      final (a, b) = sides!;
      try {
        await _mount(tester, a, code);
        await _real(
          tester,
          () => a.state.trustedNetworks.any((n) => n.connected),
          'A shows the network connected',
        );
        await _settle(tester);
        final view = a.state.trustedNetworks.single;
        expect(find.text(strings.connectedNow), findsOneWidget);
        expect(
          find.text(
            strings.trustedOn(formatShortDate(view.trustedAt, code, strings)),
          ),
          findsOneWidget,
        );
        final name = view.name ?? strings.unnamedNetwork;

        final relay = await tester.runAsync(() => _Relay.between(a, b));
        addTearDown(() => relay?.close());
        await _click(tester, _rowButton(strings.stopUsingButton));
        expect(confirmOpen(tester, strings.sectionNetworks), isTrue);
        expect(
          find.textContaining(strings.stopUsingConfirm(name).split('?').first),
          findsWidgets,
        );
        expect(a.state.paused, isFalse);

        final watch = Stopwatch();
        await tester.runAsync(() async => watch.start());
        await _click(
          tester,
          find.descendant(
            of: confirmOf(strings.sectionNetworks),
            matching: find.text(strings.stopUsingConfirmButton),
          ),
        );
        await _real(tester, () => !b.sees(a), 'B stops seeing A');
        watch.stop();
        expect(watch.elapsed, lessThanOrEqualTo(_leaveBudget));
        await _real(tester, () => a.state.paused, 'A paused');
        expect(a.state.trustedNetworks, isEmpty);

        await _settle(tester);
        expect(
          inSection(strings.sectionNetworks, find.text(strings.networksEmpty)),
          findsOneWidget,
        );
        await tester.sendKeyEvent(LogicalKeyboardKey.escape);
        await _settle(tester);
        expect(a.settings.isOpen, isFalse);
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.runAsync(() async {
          await a.stop();
          await b.stop();
        });
      }
    },
    timeout: const Timeout(Duration(minutes: 3)),
  );

  testWidgets(
    'E875 with a real node: the confirmation closes by itself without '
    'stopping when the network goes away, and the network stays trusted',
    (tester) async {
      final a = (await tester.runAsync(() => _oneSide(code)))!;
      try {
        await _mount(tester, a, code);
        await _real(
          tester,
          () => a.state.trustedNetworks.any((n) => n.connected),
          'A shows the network connected',
        );
        await _settle(tester);
        await _click(tester, _rowButton(strings.stopUsingButton));
        expect(confirmOpen(tester, strings.sectionNetworks), isTrue);

        a.adapters = [];
        await _real(
          tester,
          () => a.state.trustedNetworks.every((n) => !n.connected),
          'the network is no longer connected',
        );
        await _settle(tester);
        expect(confirmOpen(tester, strings.sectionNetworks), isFalse);
        expect(a.state.trustedNetworks.single.networkId, _network);
        expect(find.text(strings.connectedNow), findsNothing);

        a.adapters = [_adapter()];
        await _real(
          tester,
          () => a.state.trustedNetworks.any((n) => n.connected),
          'connected again',
        );
        await _settle(tester);
        expect(confirmOpen(tester, strings.sectionNetworks), isFalse);
        expect(a.state.paused, isFalse);
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.runAsync(a.stop);
      }
    },
    timeout: const Timeout(Duration(minutes: 3)),
  );

  testWidgets(
    'RF-513 with a real node: a cloud folder asks; "Choose another" opens '
    'the picker again and "Use anyway" remembers the cloud one',
    (tester) async {
      final a = (await tester.runAsync(() => _oneSide(code)))!;
      try {
        final cloud = '${a.base}\\nube';
        final other = '${a.base}\\otra';
        await tester.runAsync(() async {
          await Directory(cloud).create(recursive: true);
          await Directory(other).create(recursive: true);
        });
        await _mount(tester, a, code);
        final change = sectionButton(
          strings.sectionReceive,
          strings.changeFolderButton,
        );

        a.picker.folders.addAll([cloud, cloud]);
        await _click(tester, change);
        await _untilUi(
          tester,
          () =>
              confirmOpen(tester, strings.sectionReceive) ||
              a.state.settings.receiveFolder != null &&
                  a.state.settings.receiveFolder!.toLowerCase().contains(
                    'nube',
                  ),
          'first pick answered',
        );
        await _settle(tester);
        expect(a.picker.folderCalls, 1);
        expect(
          a.state.settings.receiveFolder?.toLowerCase(),
          isNot(contains('nube')),
        );
        expect(confirmOpen(tester, strings.sectionReceive), isTrue);

        await _click(
          tester,
          confirmButton(
            strings.sectionReceive,
            strings.chooseOtherFolderButton,
          ),
        );
        await _untilUi(
          tester,
          () =>
              a.picker.folderCalls == 2 &&
              confirmOpen(tester, strings.sectionReceive),
          'second pick answered',
        );
        await _settle(tester);

        await _click(
          tester,
          confirmButton(strings.sectionReceive, strings.useAnywayButton),
        );
        await _real(
          tester,
          () =>
              a.state.settings.receiveFolder?.toLowerCase().endsWith('nube') ??
              false,
          'the cloud folder is remembered',
        );
        await _settle(tester);
        expect(confirmOpen(tester, strings.sectionReceive), isFalse);
        expect(
          inSection(strings.sectionReceive, find.text('nube')),
          findsOneWidget,
        );

        a.picker.folders.add(other);
        await _untilUi(
          tester,
          () => buttonEnabled(tester, change),
          'the change button is back',
        );
        await _click(tester, change);
        await _real(
          tester,
          () =>
              a.state.settings.receiveFolder?.toLowerCase().endsWith('otra') ??
              false,
          'a normal folder is remembered without asking',
        );
        await _settle(tester);
        expect(confirmOpen(tester, strings.sectionReceive), isFalse);
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.runAsync(a.stop);
      }
    },
    timeout: const Timeout(Duration(minutes: 3)),
  );

  testWidgets(
    'E876 with a real node: a confirmation that arrives with Settings '
    'closed is cancelled by the AppController and the folder is kept',
    (tester) async {
      final a = (await tester.runAsync(() => _oneSide(code)))!;
      try {
        final cloud = '${a.base}\\nube';
        await tester.runAsync(() => Directory(cloud).create(recursive: true));
        final before = a.state.settings.receiveFolder;
        a.picker.folders.add(cloud);
        expect(a.settings.isOpen, isFalse);

        final result = await tester.runAsync(
          () => a.controller.changeReceiveFolder(),
        );
        expect(result, isA<FolderChangeNeedsConfirmation>());
        final confirmed = await tester.runAsync(
          () => a.controller.confirmReceiveFolder(
            (result! as FolderChangeNeedsConfirmation).changeId,
          ),
        );
        expect(confirmed, isNot(isA<FolderChanged>()));
        expect(a.state.settings.receiveFolder, before);
      } finally {
        await tester.runAsync(a.stop);
      }
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );
}
