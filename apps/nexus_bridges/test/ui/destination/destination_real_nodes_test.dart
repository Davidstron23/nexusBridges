import 'dart:io';
import 'dart:math';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nexus_bridges/src/app_controller.dart';
import 'package:nexus_bridges/src/l10n/app_strings.dart';
import 'package:nexus_bridges/src/ui/destination/destination_menu.dart';
import 'package:nexus_bridges/src/ui/settings/settings_controller.dart';
import 'package:nexus_bridges/src/ui/settings/settings_field.dart'
    show SettingsLink;
import 'package:nexus_bridges_core/nexus_bridges_core.dart';
import 'package:nexus_bridges_core/src/discovery/discovery.dart'
    show MulticastChannel;
import 'package:nexus_bridges_core/src/network/network.dart'
    show ActiveInterface, InterfaceStatus;
import 'package:nexus_bridges_core/src/transfer/transfer.dart'
    show FilePicker, FileSystemPlatform, WindowsFileSystemPlatform;
import 'package:nexus_bridges_core/src/transfer/platform.dart'
    show FreeNameMove, MoveOutcome, SystemFolders, VolumeFacts;

import '../../drop/fake_drop_events.dart';
import '../fake_app_controller.dart';
import '../segoe_font.dart';
import '../settings/settings_fixtures.dart';

const String _network = '{NETWORK-HOME}';
const String _adapterId = '{WIFI-ADAPTER}';
const Duration _limit = Duration(seconds: 30);
const Duration _listenLimit = Duration(seconds: 10);
const int _startAttempts = 4;

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
  List<String> files = const [];
  int folderCalls = 0;

  @override
  Future<String?> pickFolder({String? startIn}) async {
    folderCalls++;
    return folders.isEmpty ? null : folders.removeAt(0);
  }

  @override
  Future<String?> pickFile() async => null;

  @override
  Future<List<String>> pickFiles() async => files;

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
    root = await Directory.systemTemp.createTemp('nexus_app_destination_');
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

Future<void> _pairMine(_Side a, _Side b) async {
  await a.controller.pair(b.fingerprint);
  await _until(
    () =>
        a.state.pairing?.phase == PairingPhase.comparing &&
        b.state.pairing?.phase == PairingPhase.comparing,
    'both comparing',
  );
  a.controller.answerCode(matches: true);
  b.controller.answerRequest(ReceiverAnswer.matches);
  await _until(
    () => a.state.questions.isNotEmpty && b.state.questions.isNotEmpty,
    'both asked if it is theirs',
  );
  a.controller.dismissPairing();
  b.controller.dismissPairing();
  await a.controller.answerMine(b.fingerprint, mine: true);
  await b.controller.answerMine(a.fingerprint, mine: true);
  await _until(
    () =>
        (a.entryOf(b)?.mine ?? false) &&
        (b.entryOf(a)?.mine ?? false) &&
        a.state.questions.isEmpty &&
        b.state.questions.isEmpty,
    'both mine',
  );
}

Finder _rowSend(_Side peer, AppStrings strings) => find.descendant(
  of: find.byKey(ValueKey(peer.fingerprint)),
  matching: find.text(strings.sendFilesEllipsis),
);

final Finder _menu = find.byType(DestinationMenu);

Future<void> _openMenu(
  WidgetTester tester,
  _Side peer,
  AppStrings strings,
) async {
  await _untilUi(
    tester,
    () => _rowSend(peer, strings).evaluate().isNotEmpty,
    'the row offers Send',
  );
  await _click(tester, _rowSend(peer, strings));
  await _click(tester, find.text(strings.sendFilesOption));
}

void main() {
  setUpAll(loadSegoe);

  for (final code in languageCodes) {
    final strings = stringsFor(code);

    testWidgets(
      '[$code] E776 with two real nodes: Files… opens the menu, Esc sends '
      'nothing and the chosen folder receives it',
      (tester) async {
        final sides = await tester.runAsync(() => _twoSides(code));
        final (a, b) = sides!;
        final events = FakeDropEvents();
        try {
          await tester.runAsync(() => _pairMine(a, b));
          final docs = Directory('${b.base}\\docs')..createSync();
          final source = File('${a.base}\\informe.txt')
            ..writeAsStringSync('hola');
          b.picker.folders.add(docs.path);
          final added = await tester.runAsync(
            () => b.controller.addShare(a.fingerprint),
          );
          expect(added, isA<ShareAdded>());
          a.picker.files = [source.path];

          setSize(tester, const Size(1200, 800));
          await tester.pumpWidget(
            homeApp(a.controller, code, dropEvents: events),
          );
          await _settle(tester);

          await _openMenu(tester, b, strings);
          await _untilUi(
            tester,
            () => _menu.evaluate().isNotEmpty,
            'the menu opens',
          );
          final root = find.descendant(of: _menu, matching: find.text('docs'));
          await _untilUi(
            tester,
            () => root.evaluate().isNotEmpty,
            'the shared folder is listed',
          );
          expect(
            find.descendant(
              of: _menu,
              matching: find.text(strings.destDefaultFolder),
            ),
            findsOneWidget,
          );
          expect(
            visibleTexts(tester).where((text) => text.contains(b.base)),
            isEmpty,
          );

          await tester.sendKeyEvent(LogicalKeyboardKey.escape);
          await _settle(tester);
          expect(_menu, findsNothing);
          expect(docs.listSync(), isEmpty);

          await _openMenu(tester, b, strings);
          await _untilUi(
            tester,
            () => root.evaluate().isNotEmpty,
            'the shared folder is listed again',
          );
          await _settle(tester);
          await _click(tester, root);
          await _real(
            tester,
            () => File('${docs.path}\\informe.txt').existsSync(),
            'the file arrives in the chosen folder',
          );
          await _real(
            tester,
            () => a.state.lastSent != null,
            'the sender sees the result',
          );
        } finally {
          await tester.pumpWidget(const SizedBox.shrink());
          await events.close();
          await tester.runAsync(() async {
            await a.stop();
            await b.stop();
          });
        }
      },
      timeout: const Timeout(Duration(minutes: 3)),
    );
  }
}
