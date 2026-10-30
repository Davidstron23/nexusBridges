import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nexus_bridges/src/app_controller.dart';
import 'package:nexus_bridges/src/l10n/app_strings.dart';
import 'package:nexus_bridges/src/ui/modal/modal_button.dart';
import 'package:nexus_bridges/src/ui/modal/modal_frame.dart';
import 'package:nexus_bridges/src/ui/modal/stage.dart';
import 'package:nexus_bridges/src/ui/modal/stage_kit.dart';
import 'package:nexus_bridges/src/ui/pairing_dialogs.dart';
import 'package:nexus_bridges/src/ui/pairing_questions.dart';
import 'package:nexus_bridges/src/ui/theme/app_theme.dart';
import 'package:nexus_bridges_core/nexus_bridges_core.dart';
import 'package:nexus_bridges_core/src/discovery/discovery.dart'
    show MulticastChannel;
import 'package:nexus_bridges_core/src/network/network.dart'
    show ActiveInterface, InterfaceStatus;

const String _network = '{NETWORK-HOME}';
const String _adapterId = '{WIFI-ADAPTER}';
const Duration _limit = Duration(seconds: 30);
const double _sideWidth = 590;

final Random _random = Random();
int _pointer = 9000;

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
  for (var attempt = 0; attempt < 2000; attempt++) {
    final port = 20000 + _random.nextInt(29000);
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

Future<void> _until(bool Function() condition, String reason) async {
  final watch = Stopwatch()..start();
  while (!condition()) {
    if (watch.elapsed > _limit) fail('$reason not met within $_limit');
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}

final class _Side {
  _Side(this.name, this.address);

  final String name;
  final String address;
  final List<String> logs = [];
  late Directory root;
  late MulticastChannel channel;
  late NexusNode node;
  late AppController controller;

  String get fingerprint => node.state.fingerprint;

  NodeState get state => node.state;

  Key get key => ValueKey<String>(name);

  bool sees(_Side other) => state.entries.any(
    (entry) =>
        entry.fingerprint == other.fingerprint &&
        entry.visible &&
        entry.canPair,
  );

  Future<void> start({
    required int port,
    required int channelPort,
    required String loopback,
    required String code,
  }) async {
    root = await Directory.systemTemp.createTemp('nexus_app_pairing_');
    channel = MulticastChannel(port: channelPort, log: logs.add);
    final started = await NexusNode.start(
      dataDir: Directory('${root.path}${Platform.pathSeparator}data'),
      protector: _XorProtector(),
      readNetworks: () async => [_adapter()],
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
      pollInterval: const Duration(minutes: 1),
      channel: channel,
      pairingTickInterval: const Duration(milliseconds: 50),
      pairingPollHold: const Duration(milliseconds: 300),
    );
    node = started;
    await _until(
      () => started.state.prompts.isNotEmpty || !started.state.paused,
      '$name network read',
    );
    if (started.state.prompts.isNotEmpty) {
      await started.decideNetwork(_network, NetworkDecision.trusted);
    }
    await _until(() => !started.state.paused, '$name active');
    await _until(
      () => logs.any((line) => line.startsWith('listening on ')),
      '$name listening',
    );
    controller = AppController(
      startNode: () async => started,
      loadLanguage: () async => code,
    );
    await controller.init();
  }

  Future<void> stop() async {
    await controller.shutdown();
    await channel.close();
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
  final a = _Side('Node A', '127.0.0.1');
  final b = _Side('Node B', '127.0.0.2');
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
  for (var attempt = 0; attempt < 5 && !(a.sees(b) && b.sees(a)); attempt++) {
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
}

Widget _app(_Side side, String code) {
  return SizedBox(
    width: _sideWidth,
    child: MaterialApp(
      key: side.key,
      locale: Locale(code),
      supportedLocales: const [Locale('en'), Locale('es')],
      localizationsDelegates: const [
        AppStringsDelegate(),
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      theme: buildTheme(Brightness.light),
      darkTheme: buildTheme(Brightness.dark),
      themeMode: ThemeMode.dark,
      themeAnimationDuration: Duration.zero,
      home: PairingHost(
        controller: side.controller,
        child: const Scaffold(body: SizedBox.expand()),
      ),
    ),
  );
}

bool _isLeaving(Element element) {
  var leaving = false;
  element.visitAncestorElements((ancestor) {
    final widget = ancestor.widget;
    if (widget is ModalViewSwitcher) return false;
    if (widget is IgnorePointer && widget.ignoring) {
      leaving = true;
      return false;
    }
    return true;
  });
  return leaving;
}

Finder _inSide(_Side side, Finder matching) => find.descendant(
  of: find.byKey(side.key),
  matching: find.descendant(of: find.byType(NbModal), matching: matching),
);

List<Element> _live(_Side side, Finder matching) => _inSide(
  side,
  matching,
).evaluate().where((element) => !_isLeaving(element)).toList();

T _liveOne<T extends Widget>(_Side side) {
  final elements = _live(side, find.byType(T));
  expect(elements, hasLength(1), reason: '${side.name} live $T');
  return elements.single.widget as T;
}

ModalRoute<dynamic> _routeOf(WidgetTester tester, _Side side) => ModalRoute.of(
  tester.element(
    find.descendant(of: find.byKey(side.key), matching: find.byType(NbModal)),
  ),
)!;

Future<void> _click(WidgetTester tester, _Side side, String label) async {
  final elements = _live(side, find.text(label));
  expect(elements, hasLength(1), reason: '${side.name} live "$label"');
  final center = tester.getCenter(
    find.byElementPredicate((candidate) => candidate == elements.single),
  );
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
}

Future<void> _real(WidgetTester tester, bool Function() condition, String why) {
  return tester.runAsync(() => _until(condition, why));
}

bool _showsPaired(NodeState state) =>
    state.pairing?.phase == PairingPhase.finished &&
    state.pairing?.outcome == PairingOutcome.paired;

Duration get _sceneLength {
  final spec = stageSpecOf(StageScene.paired, const StageInput());
  return Duration(
        microseconds: (spec.introEnd * Duration.microsecondsPerSecond).round(),
      ) +
      pairedSceneHold;
}

void main() {
  const code = 'es';
  final strings = stringsFor(code);

  testWidgets(
    'E287 with two real nodes on 127.0.0.1 behind two real apps: request, '
    'compare, both confirm, each side shows the paired bridge scene with no '
    'button and, when the scene ends, the same modal moves on by itself to '
    '"is it yours?" without answering it (point 247, RF-98)',
    (tester) async {
      tester.view.physicalSize = const Size(_sideWidth * 2, 720);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);

      final sides = await tester.runAsync(() => _twoSides(code));
      final (a, b) = sides!;
      try {
        await tester.pumpWidget(
          Directionality(
            textDirection: TextDirection.ltr,
            child: Row(children: [_app(a, code), _app(b, code)]),
          ),
        );
        await tester.pump();

        final started = await tester.runAsync(
          () => a.controller.pair(b.fingerprint),
        );
        expect(started, PairRequestResult.started);
        await _real(
          tester,
          () =>
              a.state.pairing?.phase == PairingPhase.comparing &&
              b.state.pairing?.phase == PairingPhase.comparing,
          'both comparing',
        );
        await tester.pump();
        await tester.pump(dialogActivationDelay);
        await tester.pump(const Duration(milliseconds: 600));
        final routeA = _routeOf(tester, a);
        final routeB = _routeOf(tester, b);

        await _click(tester, a, strings.matchesButton);
        await _click(tester, b, strings.matchesButton);
        await _real(
          tester,
          () =>
              _showsPaired(a.state) &&
              _showsPaired(b.state) &&
              a.state.questions.isNotEmpty &&
              b.state.questions.isNotEmpty,
          'both paired with their question',
        );

        for (final (side, other) in [(a, b), (b, a)]) {
          final pairing = side.state.pairing!;
          expect(pairing.peerFingerprint, other.fingerprint);
          expect(pairing.isNew, isTrue);
          expect(side.state.questions, hasLength(1));
          final question = side.state.questions.single;
          expect(question, isA<MineQuestion>());
          expect(question.fingerprint, other.fingerprint);
        }
        expect(a.state.pairing!.role, PairingRole.initiator);
        expect(b.state.pairing!.role, PairingRole.receiver);

        await tester.pump();
        var shown = Duration.zero;
        for (final (side, other) in [(a, b), (b, a)]) {
          final view = _liveOne<ModalView>(side);
          expect(view.title, strings.outcomePaired(other.name));
          expect(view.layout, ModalViewLayout.result);
          expect(view.actions, isEmpty);
          expect(_liveOne<ModalStage>(side).scene, StageScene.paired);
          expect(_live(side, find.byType(ModalButton)), isEmpty);
          expect(_live(side, find.text(strings.closeButton)), isEmpty);
        }
        expect(identical(_routeOf(tester, a), routeA), isTrue);
        expect(identical(_routeOf(tester, b), routeB), isTrue);

        const step = Duration(milliseconds: 100);
        while (shown + step < _sceneLength) {
          await tester.pump(step);
          shown += step;
          for (final (side, other) in [(a, b), (b, a)]) {
            expect(
              _liveOne<ModalView>(side).title,
              strings.outcomePaired(other.name),
              reason: '${side.name} at $shown',
            );
            expect(_live(side, find.byType(ModalButton)), isEmpty);
          }
        }
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 100)),
        );
        expect(_showsPaired(a.state), isTrue, reason: 'A before the end');
        expect(_showsPaired(b.state), isTrue, reason: 'B before the end');

        await tester.pump(_sceneLength - shown);
        await tester.pump();
        await _real(
          tester,
          () => a.state.pairing == null && b.state.pairing == null,
          'both dismissed after the scene',
        );
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 600));

        for (final (side, other) in [(a, b), (b, a)]) {
          final question = _liveOne<PairingQuestionView>(side).question;
          expect(question, isA<MineQuestion>());
          expect(question.fingerprint, other.fingerprint);
          expect(_live(side, find.byType(PairingQuestionView)), hasLength(1));
          expect(side.state.questions, [question]);
          final row = side.state.entries.singleWhere(
            (entry) => entry.fingerprint == other.fingerprint,
          );
          expect(row.paired, isTrue);
          expect(row.mine, isFalse);
        }
        expect(identical(_routeOf(tester, a), routeA), isTrue);
        expect(identical(_routeOf(tester, b), routeB), isTrue);
        expect(tester.takeException(), isNull);
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
}
