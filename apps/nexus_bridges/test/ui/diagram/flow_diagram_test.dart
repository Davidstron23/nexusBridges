import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nexus_bridges/src/l10n/app_strings.dart';
import 'package:nexus_bridges/src/ui/diagram/flow_diagram.dart';
import 'package:nexus_bridges/src/ui/diagram/flow_layout.dart';
import 'package:nexus_bridges/src/ui/diagram/flow_painter.dart';
import 'package:nexus_bridges/src/ui/diagram/flow_scene.dart';
import 'package:nexus_bridges/src/ui/icons/device_disc.dart';
import 'package:nexus_bridges/src/ui/theme/app_theme.dart';
import 'package:nexus_bridges/src/ui/theme/components.dart';
import 'package:nexus_bridges/src/ui/theme/tokens.dart';
import 'package:nexus_bridges_core/nexus_bridges_core.dart';

import '../fake_app_controller.dart' show languageCodes;

const Size _area = Size(788, 588);
const Size _small = Size(572, 468);
const Size _view = Size(1700, 1100);
const Duration _hover = Duration(milliseconds: 200);
const Duration _popoverIn = Duration(milliseconds: 240);
const Timeout _sweep = Timeout(Duration(minutes: 4));
const Cubic _motion = Cubic(0.2, 0.8, 0.2, 1);
final List<String> _letters = [
  for (var i = 0; i < 32; i++) String.fromCharCode(i < 26 ? 65 + i : 71 + i),
];

String _fp(String letter) => '${letter}1234567${'0' * 56}';

String _nameOf(String letter) => 'Device $letter';

DeviceEntry _entry(
  String letter, {
  bool visible = true,
  bool mine = true,
  bool mismatch = false,
  bool paired = true,
  DeviceType? type = DeviceType.desktop,
}) => DeviceEntry(
  fingerprint: _fp(letter),
  displayName: _nameOf(letter),
  deviceType: type,
  visible: visible,
  paired: paired,
  mine: mine,
  ignored: false,
  mismatch: mismatch,
  possiblyReplaces: null,
);

OutgoingTransferView _out(String letter, OutgoingPhase phase, {int sent = 0}) =>
    OutgoingTransferView(
      peerFingerprint: _fp(letter),
      peerName: _nameOf(letter),
      fileName: 'report.pdf',
      size: 1000,
      isProgram: false,
      phase: phase,
      sentBytes: sent,
      cancelling: false,
    );

IncomingTransferView _in(
  String letter,
  IncomingStage stage, {
  int received = 0,
}) => IncomingTransferView(
  sessionId: 's-$letter',
  peerFingerprint: _fp(letter),
  peerName: _nameOf(letter),
  fileName: 'photo.jpg',
  size: 1000,
  isProgram: false,
  stage: stage,
  receivedBytes: received,
);

TransferResultView _result(
  String letter,
  TransferOutcome outcome, {
  TransferDirection direction = TransferDirection.outgoing,
}) => TransferResultView(
  direction: direction,
  peerFingerprint: _fp(letter),
  peerName: _nameOf(letter),
  fileName: 'report.pdf',
  isProgram: false,
  outcome: outcome,
  canReveal: false,
);

NodeState _state(
  List<DeviceEntry> entries, {
  OutgoingTransferView? outgoing,
  IncomingTransferView? incoming,
  TransferResultView? lastSent,
  TransferResultView? lastReceived,
}) => NodeState(
  entries: entries,
  outgoing: outgoing,
  incoming: incoming,
  lastSent: lastSent,
  lastReceived: lastReceived,
  deviceName: 'Main PC',
  fingerprint: 'ABCDEF0123456789',
);

List<DeviceEntry> _devices(int count) => [
  for (var i = 0; i < count; i++)
    _entry(_letters[i], visible: count < 3 || i != count - 1, mine: i.isEven),
];

final class _Host {
  _Host(NodeState state) : state = ValueNotifier<NodeState>(state);

  final ValueNotifier<NodeState> state;
  final ValueNotifier<String?> hovered = ValueNotifier<String?>(null);
  final List<String> sent = [];
  int showDevices = 0;
}

Widget _app(
  _Host host, {
  required String code,
  Brightness brightness = Brightness.light,
  bool reduceMotion = false,
  Size size = _area,
}) => MaterialApp(
  debugShowCheckedModeBanner: false,
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
  themeMode: brightness == Brightness.dark ? ThemeMode.dark : ThemeMode.light,
  themeAnimationDuration: Duration.zero,
  builder: (context, child) => MediaQuery(
    data: MediaQuery.of(context).copyWith(disableAnimations: reduceMotion),
    child: child!,
  ),
  home: Scaffold(
    body: Align(
      alignment: Alignment.topLeft,
      child: SizedBox.fromSize(
        size: size,
        child: ValueListenableBuilder<NodeState>(
          valueListenable: host.state,
          builder: (context, state, _) => FlowDiagram(
            state: state,
            hovered: host.hovered,
            onSendFiles: (fp) => host.sent.add('files $fp'),
            onSendFolders: (fp) => host.sent.add('folders $fp'),
            onShowDevices: () => host.showDevices++,
          ),
        ),
      ),
    ),
  ),
);

Future<void> _mount(
  WidgetTester tester,
  _Host host, {
  String code = 'en',
  Brightness brightness = Brightness.light,
  bool reduceMotion = false,
  Size size = _area,
}) async {
  tester.view.physicalSize = _view;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    _app(
      host,
      code: code,
      brightness: brightness,
      reduceMotion: reduceMotion,
      size: size,
    ),
  );
  await tester.pump();
}

FlowPainter _painter(WidgetTester tester) => tester
    .widgetList<CustomPaint>(
      find.descendant(
        of: find.byType(FlowDiagram),
        matching: find.byType(CustomPaint),
      ),
    )
    .map((paint) => paint.foregroundPainter)
    .whereType<FlowPainter>()
    .single;

FlowScene _scene(WidgetTester tester) => _painter(tester).scene;

LinkState _link(WidgetTester tester, String letter) =>
    _scene(tester).peers
        .firstWhere((peer) => peer.fingerprint == _fp(letter))
        .link
        .state;

int _live(WidgetTester tester) => tester.binding.transientCallbackCount;

Finder _zone(String letter) => find.byKey(ValueKey('flow-peer-${_fp(letter)}'));

Finder _inDiagram(Finder matching) =>
    find.descendant(of: find.byType(FlowDiagram), matching: matching);

Finder _popover() => _inDiagram(find.byType(Card));

Finder _sendButton(AppStrings strings) => find.ancestor(
  of: find.text(strings.sendEllipsis),
  matching: find.byWidgetPredicate((widget) => widget is ButtonStyleButton),
);

Future<void> _open(WidgetTester tester, String letter) async {
  await tester.tap(_zone(letter));
  await tester.pump();
  await tester.pump(_popoverIn);
}

final class _Case {
  const _Case(
    this.name,
    this.after,
    this.expected, {
    this.before,
    required this.animates,
  });

  final String name;
  final NodeState? before;
  final NodeState after;
  final Map<String, LinkState> expected;
  final bool animates;
}

List<_Case> _cases(int count) {
  final entries = _devices(count);
  final rest = _Case('rest', _state(entries), {
    for (var i = 0; i < count; i++) _letters[i]: LinkState.idle,
  }, animates: false);
  if (count == 0) return [rest];
  final two = count >= 2;
  return [
    rest,
    _Case(
      'sending and asking',
      _state(
        entries,
        outgoing: _out('A', OutgoingPhase.uploading, sent: 400),
        incoming: two ? _in('B', IncomingStage.warning) : null,
      ),
      {'A': LinkState.active, if (two) 'B': LinkState.asking},
      animates: true,
    ),
    _Case(
      'waiting and receiving',
      _state(
        entries,
        outgoing: _out('A', OutgoingPhase.requesting),
        incoming: two ? _in('B', IncomingStage.receiving, received: 300) : null,
      ),
      {'A': LinkState.waiting, if (two) 'B': LinkState.active},
      animates: true,
    ),
    _Case(
      'waiting for data and verifying',
      _state(
        entries,
        incoming: _in('A', IncomingStage.waitingData),
        outgoing: two ? _out('B', OutgoingPhase.verifying) : null,
      ),
      {'A': LinkState.waiting, if (two) 'B': LinkState.active},
      animates: true,
    ),
    _Case(
      'folder question',
      _state(entries, incoming: _in('A', IncomingStage.folderQuestion)),
      {'A': LinkState.asking},
      animates: true,
    ),
    _Case(
      'done sending',
      _state(entries, lastSent: _result('A', TransferOutcome.saved)),
      {'A': LinkState.done},
      before: _state(entries, outgoing: _out('A', OutgoingPhase.verifying)),
      animates: false,
    ),
    _Case(
      'done receiving',
      _state(
        entries,
        lastReceived: _result(
          'A',
          TransferOutcome.saved,
          direction: TransferDirection.incoming,
        ),
      ),
      {'A': LinkState.done},
      before: _state(entries, incoming: _in('A', IncomingStage.verifying)),
      animates: false,
    ),
  ];
}

void main() {
  group('E263: every state in every language, theme and motion setting', () {
    for (final code in languageCodes) {
      for (final brightness in Brightness.values) {
        for (final reduceMotion in [false, true]) {
          final label =
              '$code ${brightness.name}'
              '${reduceMotion ? ' with reduced motion' : ''}';
          testWidgets('$label: 0, 1, 3, 6 and 8 devices paint without '
              'exceptions', (tester) async {
            final strings = stringsFor(code);
            final colors = brightness == Brightness.dark
                ? NbColors.dark
                : NbColors.light;
            for (final count in [0, 1, 3, 6, 8]) {
              for (final item in _cases(count)) {
                final reason = '$count ${item.name}';
                final host = _Host(item.before ?? item.after);
                await _mount(
                  tester,
                  host,
                  code: code,
                  brightness: brightness,
                  reduceMotion: reduceMotion,
                );
                if (item.before != null) {
                  host.state.value = item.after;
                  await tester.pump();
                }
                await tester.pump(const Duration(milliseconds: 50));
                expect(tester.takeException(), isNull, reason: reason);
                final scene = _scene(tester);
                expect(scene.peers, hasLength(count), reason: reason);
                expect(scene.title, strings.diagramTitle, reason: reason);
                final visible = item.after.entries.where((e) => e.visible);
                expect(
                  scene.count,
                  strings.diagramCount(count, visible.length),
                  reason: reason,
                );
                expect(_painter(tester).colors.card, colors.card);
                expect(_painter(tester).reduceMotion, reduceMotion);
                for (final MapEntry(:key, :value) in item.expected.entries) {
                  expect(_link(tester, key), value, reason: '$reason $key');
                }
                if (item.animates && !reduceMotion) {
                  expect(_live(tester), greaterThan(0), reason: reason);
                } else {
                  expect(_live(tester), 0, reason: reason);
                }
                for (final step in const [700, 1100, 900]) {
                  await tester.pump(Duration(milliseconds: step));
                  expect(tester.takeException(), isNull, reason: reason);
                }
                await tester.pumpWidget(const SizedBox());
              }
            }
          }, timeout: _sweep);
        }
      }
    }
  });

  group('E263: no animation stays alive at rest', () {
    for (final code in languageCodes) {
      testWidgets('$code: at rest there is no live animation after two pumps '
          'and pumpAndSettle ends', (tester) async {
        for (final count in [0, 1, 3, 8]) {
          final host = _Host(_state(_devices(count)));
          await _mount(tester, host, code: code);
          await tester.pump();
          expect(_live(tester), 0, reason: '$count');
          await tester.pumpAndSettle();
          expect(_painter(tester).clock.isAnimating, isFalse);
          await tester.pumpWidget(const SizedBox());
        }
      });

      testWidgets('$code: a send keeps the clock alive and its end stops '
          'it', (tester) async {
        final entries = _devices(3);
        final host = _Host(
          _state(entries, outgoing: _out('A', OutgoingPhase.uploading)),
        );
        await _mount(tester, host, code: code);
        await tester.pump();
        expect(_live(tester), greaterThan(0));
        final before = _painter(tester).clock.value;
        await tester.pump(const Duration(milliseconds: 500));
        expect(_painter(tester).clock.value, isNot(before));
        host.state.value = _state(entries);
        await tester.pump();
        await tester.pump();
        expect(_live(tester), 0);
        await tester.pumpAndSettle();
      });

      testWidgets('$code: with reduced motion a send keeps no animation '
          'alive and the clock does not move', (tester) async {
        final host = _Host(
          _state(
            _devices(3),
            outgoing: _out('A', OutgoingPhase.uploading),
            incoming: _in('B', IncomingStage.warning),
          ),
        );
        await _mount(tester, host, code: code, reduceMotion: true);
        await tester.pump();
        expect(_live(tester), 0);
        expect(_painter(tester).clock.value, 0);
        await tester.pump(const Duration(seconds: 2));
        expect(_painter(tester).clock.value, 0);
        await tester.pumpAndSettle();
      });
    }
  });

  group('E263: "done" lasts 3.2 s (point 146)', () {
    for (final code in languageCodes) {
      testWidgets('$code: a saved send marks the device done for 3.2 s and '
          'then idle', (tester) async {
        final entries = _devices(3);
        final host = _Host(
          _state(entries, outgoing: _out('A', OutgoingPhase.uploading)),
        );
        await _mount(tester, host, code: code);
        host.state.value = _state(
          entries,
          lastSent: _result('A', TransferOutcome.saved),
        );
        await tester.pump();
        expect(_link(tester, 'A'), LinkState.done);
        expect(_link(tester, 'B'), LinkState.idle);
        expect(_live(tester), 0);
        await tester.pump(const Duration(milliseconds: 3100));
        expect(_link(tester, 'A'), LinkState.done);
        await tester.pump(const Duration(milliseconds: 150));
        expect(_link(tester, 'A'), LinkState.idle);
        await tester.pumpAndSettle();
      });

      testWidgets('$code: repeating the same send marks it again, and a new '
          'end restarts the 3.2 s', (tester) async {
        final entries = _devices(3);
        final sending = _state(
          entries,
          outgoing: _out('A', OutgoingPhase.verifying),
        );
        final ended = _state(
          entries,
          lastSent: _result('A', TransferOutcome.saved),
        );
        final host = _Host(sending);
        await _mount(tester, host, code: code);
        host.state.value = ended;
        await tester.pump();
        expect(_link(tester, 'A'), LinkState.done);
        await tester.pump(const Duration(milliseconds: 2000));
        host.state.value = _state(
          entries,
          outgoing: _out('A', OutgoingPhase.verifying),
          lastSent: _result('A', TransferOutcome.saved),
        );
        await tester.pump();
        expect(_link(tester, 'A'), LinkState.active);
        host.state.value = _state(
          entries,
          lastSent: _result('A', TransferOutcome.saved),
        );
        await tester.pump();
        expect(_link(tester, 'A'), LinkState.done);
        await tester.pump(const Duration(milliseconds: 3100));
        expect(_link(tester, 'A'), LinkState.done);
        await tester.pump(const Duration(milliseconds: 150));
        expect(_link(tester, 'A'), LinkState.idle);
        host.state.value = sending;
        await tester.pump();
        host.state.value = ended;
        await tester.pump();
        expect(_link(tester, 'A'), LinkState.done);
        await tester.pump(const Duration(milliseconds: 3300));
        expect(_link(tester, 'A'), LinkState.idle);
      });

      testWidgets('$code: a saved receive marks the sender done', (
        tester,
      ) async {
        final entries = _devices(3);
        final host = _Host(
          _state(
            entries,
            incoming: _in('B', IncomingStage.receiving, received: 900),
          ),
        );
        await _mount(tester, host, code: code);
        host.state.value = _state(
          entries,
          lastReceived: _result(
            'B',
            TransferOutcome.saved,
            direction: TransferDirection.incoming,
          ),
        );
        await tester.pump();
        expect(_link(tester, 'B'), LinkState.done);
        await tester.pump(const Duration(milliseconds: 3300));
        expect(_link(tester, 'B'), LinkState.idle);
      });

      testWidgets('$code: a result present from the start, a failed send or '
          'a result without a send before are not done', (tester) async {
        final entries = _devices(3);
        final host = _Host(
          _state(entries, lastSent: _result('A', TransferOutcome.saved)),
        );
        await _mount(tester, host, code: code);
        expect(_link(tester, 'A'), LinkState.idle);
        host.state.value = _state(
          entries,
          outgoing: _out('A', OutgoingPhase.uploading),
        );
        await tester.pump();
        host.state.value = _state(
          entries,
          lastSent: _result('A', TransferOutcome.connectionLost),
        );
        await tester.pump();
        expect(_link(tester, 'A'), LinkState.idle);
        host.state.value = _state(
          entries,
          lastSent: _result('B', TransferOutcome.saved),
        );
        await tester.pump();
        expect(_link(tester, 'B'), LinkState.idle);
        await tester.pumpAndSettle();
      });
    }

    testWidgets('unmounting while done is shown cancels its timer', (
      tester,
    ) async {
      final entries = _devices(2);
      final host = _Host(
        _state(entries, outgoing: _out('A', OutgoingPhase.verifying)),
      );
      await _mount(tester, host);
      host.state.value = _state(
        entries,
        lastSent: _result('A', TransferOutcome.saved),
      );
      await tester.pump();
      expect(_link(tester, 'A'), LinkState.done);
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(seconds: 4));
      expect(tester.takeException(), isNull);
    });
  });

  group('E263: hover', () {
    for (final code in languageCodes) {
      testWidgets('$code: the mouse over a device puts its fingerprint in '
          'hovered with a hand cursor, and leaving clears it', (tester) async {
        final host = _Host(_state(_devices(3)));
        await _mount(tester, host, code: code);
        final gesture = await tester.createGesture(
          kind: PointerDeviceKind.mouse,
          pointer: 1,
        );
        await gesture.addPointer(location: const Offset(6, 580));
        addTearDown(gesture.removePointer);
        await tester.pump();
        expect(host.hovered.value, isNull);
        await gesture.moveTo(tester.getCenter(_zone('B')));
        await tester.pump();
        expect(host.hovered.value, _fp('B'));
        expect(
          RendererBinding.instance.mouseTracker.debugDeviceActiveCursor(1),
          SystemMouseCursors.click,
        );
        await gesture.moveTo(tester.getCenter(_zone('A')));
        await tester.pump();
        expect(host.hovered.value, _fp('A'));
        await gesture.moveTo(const Offset(6, 580));
        await tester.pump();
        expect(host.hovered.value, isNull);
        await tester.pump(_hover);
        await tester.pumpAndSettle();
      });

      testWidgets('$code: the hovered device grows to 1.14 in 0.2 s with the '
          'curve and shrinks back the same way', (tester) async {
        final host = _Host(_state(_devices(3)));
        await _mount(tester, host, code: code);
        host.hovered.value = _fp('C');
        await tester.pump();
        expect(_scene(tester).hovered, _fp('C'));
        await tester.pump(const Duration(milliseconds: 100));
        expect(
          _painter(tester).hover.value,
          closeTo(_motion.transform(0.5), 0.03),
        );
        await tester.pump(const Duration(milliseconds: 120));
        expect(_painter(tester).hover.value, 1);
        expect(_live(tester), 0);
        host.hovered.value = null;
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 100));
        expect(_scene(tester).hovered, _fp('C'));
        final shrinking = _painter(tester).hover.value;
        expect(shrinking, greaterThan(0));
        expect(shrinking, lessThan(1));
        await tester.pump(const Duration(milliseconds: 120));
        await tester.pump();
        expect(_painter(tester).hover.value, 0);
        expect(_scene(tester).hovered, isNull);
        expect(_live(tester), 0);
        await tester.pumpAndSettle();
      });

      testWidgets('$code: with reduced motion the hover jumps without '
          'animating', (tester) async {
        final host = _Host(_state(_devices(3)));
        await _mount(tester, host, code: code, reduceMotion: true);
        host.hovered.value = _fp('A');
        await tester.pump();
        expect(_painter(tester).hover.value, 1);
        expect(_scene(tester).hovered, _fp('A'));
        expect(_live(tester), 0);
        host.hovered.value = null;
        await tester.pump();
        expect(_painter(tester).hover.value, 0);
        expect(_scene(tester).hovered, isNull);
        expect(_live(tester), 0);
      });
    }

    testWidgets('a fingerprint already hovered when the diagram mounts is '
        'shown grown', (tester) async {
      final host = _Host(_state(_devices(3)))..hovered.value = _fp('B');
      await _mount(tester, host);
      expect(_scene(tester).hovered, _fp('B'));
      expect(_painter(tester).hover.value, 1);
    });

    testWidgets('moving from one device to another moves the growth', (
      tester,
    ) async {
      final host = _Host(_state(_devices(3)));
      await _mount(tester, host);
      host.hovered.value = _fp('A');
      await tester.pump();
      await tester.pump(_hover);
      host.hovered.value = _fp('B');
      await tester.pump();
      expect(_scene(tester).hovered, _fp('B'));
      await tester.pump(_hover);
      expect(_painter(tester).hover.value, 1);
    });

    testWidgets('unmounting in the middle of a hover leaves no error', (
      tester,
    ) async {
      final host = _Host(_state(_devices(3)));
      await _mount(tester, host);
      host.hovered.value = _fp('A');
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));
      await tester.pumpWidget(const SizedBox());
      host.hovered.value = null;
      await tester.pump(_hover);
      expect(tester.takeException(), isNull);
    });
  });

  group('E263: touch zones', () {
    testWidgets('each shown device has a zone of radius pr + 6 on its slot, '
        'with a button semantics named after it', (tester) async {
      final semantics = tester.ensureSemantics();
      final host = _Host(_state(_devices(8)));
      await _mount(tester, host);
      final scene = _scene(tester);
      final radius = scene.layout.peerRadius + 6;
      for (var i = 0; i < scene.peers.length; i++) {
        final zone = find.byKey(
          ValueKey('flow-peer-${scene.peers[i].fingerprint}'),
        );
        final rect = tester.getRect(zone);
        expect(
          (rect.center - scene.layout.slots[i].center).distance,
          lessThan(0.01),
        );
        expect(rect.width, closeTo(2 * radius, 0.01));
        expect(rect.height, closeTo(2 * radius, 0.01));
        expect(find.bySemanticsLabel(scene.peers[i].name), findsOneWidget);
      }
      expect(find.byKey(const ValueKey('flow-more')), findsNothing);
      semantics.dispose();
    });
  });

  group('E263: the popover', () {
    for (final code in languageCodes) {
      testWidgets('$code: with a nickname, the popover shows it with the '
          'real name (RF-429)', (tester) async {
        final strings = stringsFor(code);
        final host = _Host(
          _state([
            DeviceEntry(
              fingerprint: _fp('A'),
              displayName: 'Curro',
              alias: 'Curro',
              realName: _nameOf('A'),
              deviceType: DeviceType.desktop,
              visible: true,
              paired: true,
              mine: true,
              ignored: false,
              mismatch: false,
              possiblyReplaces: null,
            ),
            _entry('B'),
          ]),
        );
        await _mount(tester, host, code: code);
        await _open(tester, 'A');

        expect(_popover(), findsOneWidget);
        expect(
          find.descendant(
            of: _popover(),
            matching: find.text(strings.nameWithReal('Curro', _nameOf('A'))),
          ),
          findsOneWidget,
        );
        expect(tester.takeException(), isNull);
      });

      testWidgets('$code: without a nickname, the popover shows only the '
          'name', (tester) async {
        final host = _Host(_state(_devices(2)));
        await _mount(tester, host, code: code);
        await _open(tester, 'A');

        expect(
          find.descendant(of: _popover(), matching: find.text(_nameOf('A'))),
          findsOneWidget,
        );
      });

      testWidgets('$code: a visible device of mine shows its name, chip, '
          'visibility and fingerprint, and "Send file" calls onSend and '
          'closes', (tester) async {
        final strings = stringsFor(code);
        final host = _Host(_state(_devices(3)));
        await _mount(tester, host, code: code);
        expect(_popover(), findsNothing);
        await _open(tester, 'A');
        expect(_popover(), findsOneWidget);
        expect(_inDiagram(find.text(_nameOf('A'))), findsOneWidget);
        final chip = tester.widget<StatusChip>(
          _inDiagram(find.byType(StatusChip)),
        );
        expect(chip.label, strings.chipMine);
        expect(chip.tone, ChipTone.run);
        expect(find.text(strings.visibleLabel), findsOneWidget);
        expect(find.text(strings.notVisibleLabel), findsNothing);
        expect(find.text(strings.fingerprintLine('A1234567')), findsOneWidget);
        expect(find.text(strings.sendNeedsVisible), findsNothing);
        expect(find.text(strings.sendNeedsPairAgain), findsNothing);
        final disc = tester.widget<DeviceDisc>(
          _inDiagram(find.byType(DeviceDisc)),
        );
        expect(disc.tone, DiscTone.idle);
        expect(disc.size, 32);
        expect(
          tester.widget<ButtonStyleButton>(_sendButton(strings)).enabled,
          isTrue,
        );
        await tester.tap(_sendButton(strings));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 240));
        expect(find.text(strings.sendFilesOption), findsOneWidget);
        expect(find.text(strings.sendFoldersOption), findsOneWidget);
        await tester.tap(find.text(strings.sendFoldersOption));
        await tester.pump();
        expect(host.sent, ['folders ${_fp('A')}']);
        expect(_popover(), findsNothing);
        expect(tester.takeException(), isNull);
      });

      testWidgets('$code: a device that is not visible keeps the Mine or '
          'Someone else\'s chip, shows Not visible on its line and cannot '
          'be sent to (point 148)', (tester) async {
        final strings = stringsFor(code);
        final host = _Host(
          _state([
            _entry('A'),
            _entry('B', visible: false, mine: false),
            _entry('C', visible: false),
          ]),
        );
        await _mount(tester, host, code: code);
        await _open(tester, 'B');
        final chip = tester.widget<StatusChip>(
          _inDiagram(find.byType(StatusChip)),
        );
        expect(chip.label, strings.chipForeign);
        expect(chip.tone, ChipTone.foreign);
        expect(find.text(strings.notVisibleLabel), findsOneWidget);
        expect(find.text(strings.visibleLabel), findsNothing);
        expect(find.text(strings.sendNeedsVisible), findsOneWidget);
        expect(find.text(strings.fingerprintLine('B1234567')), findsOneWidget);
        expect(
          tester.widget<DeviceDisc>(_inDiagram(find.byType(DeviceDisc))).tone,
          DiscTone.notVisible,
        );
        expect(
          tester.widget<ButtonStyleButton>(_sendButton(strings)).enabled,
          isFalse,
        );
        await tester.tap(_sendButton(strings), warnIfMissed: false);
        await tester.pump();
        expect(host.sent, isEmpty);
        expect(_popover(), findsOneWidget);
        await tester.tapAt(const Offset(6, 580));
        await tester.pump();
        await _open(tester, 'C');
        final mine = tester.widget<StatusChip>(
          _inDiagram(find.byType(StatusChip)),
        );
        expect(mine.label, strings.chipMine);
        expect(find.text(strings.notVisibleLabel), findsOneWidget);
      });

      testWidgets('$code: a device with a mismatch asks to pair again, '
          'visible or not', (tester) async {
        final strings = stringsFor(code);
        final host = _Host(
          _state([
            _entry('A', mismatch: true),
            _entry('B', mismatch: true, visible: false),
          ]),
        );
        await _mount(tester, host, code: code);
        for (final letter in ['A', 'B']) {
          await _open(tester, letter);
          expect(find.text(strings.sendNeedsPairAgain), findsOneWidget);
          expect(find.text(strings.sendNeedsVisible), findsNothing);
          expect(
            tester.widget<ButtonStyleButton>(_sendButton(strings)).enabled,
            isFalse,
          );
          await tester.sendKeyEvent(LogicalKeyboardKey.escape);
          await tester.pump();
          expect(_popover(), findsNothing);
        }
        expect(host.sent, isEmpty);
      });

      testWidgets('$code: a tap outside closes it without sending', (
        tester,
      ) async {
        final strings = stringsFor(code);
        final host = _Host(_state(_devices(3)));
        await _mount(tester, host, code: code);
        await _open(tester, 'B');
        expect(find.text(strings.sendEllipsis), findsOneWidget);
        await tester.tapAt(const Offset(6, 580));
        await tester.pump();
        expect(_popover(), findsNothing);
        expect(host.sent, isEmpty);
        expect(host.showDevices, 0);
        await tester.pumpAndSettle();
      });

      testWidgets('$code: Esc closes it', (tester) async {
        final host = _Host(_state(_devices(3)));
        await _mount(tester, host, code: code);
        await _open(tester, 'A');
        await tester.sendKeyEvent(LogicalKeyboardKey.escape);
        await tester.pump();
        expect(_popover(), findsNothing);
        expect(host.sent, isEmpty);
      });
    }

    testWidgets('the disc of the popover takes the tone of the device: '
        'asking wins over sending', (tester) async {
      final entries = _devices(3);
      for (final (state, tone) in [
        (
          _state(entries, outgoing: _out('A', OutgoingPhase.uploading)),
          DiscTone.sending,
        ),
        (
          _state(entries, incoming: _in('A', IncomingStage.warning)),
          DiscTone.asking,
        ),
        (
          _state(entries, incoming: _in('A', IncomingStage.folderQuestion)),
          DiscTone.asking,
        ),
        (
          _state(
            entries,
            outgoing: _out('A', OutgoingPhase.uploading),
            incoming: _in('A', IncomingStage.warning),
          ),
          DiscTone.asking,
        ),
        (
          _state(entries, incoming: _in('A', IncomingStage.receiving)),
          DiscTone.idle,
        ),
      ]) {
        final host = _Host(state);
        await _mount(tester, host);
        await _open(tester, 'A');
        expect(
          tester.widget<DeviceDisc>(_inDiagram(find.byType(DeviceDisc))).tone,
          tone,
        );
        await tester.pumpWidget(const SizedBox());
      }
    });

    testWidgets('it is placed with placePopover inside the diagram, above '
        'a device in the lower half', (tester) async {
      final host = _Host(_state(_devices(5)));
      await _mount(tester, host);
      final scene = _scene(tester);
      for (final index in [0, 2, 4]) {
        final peer = scene.peers[index];
        final center = scene.layout.slots[index].center;
        await tester.tap(find.byKey(ValueKey('flow-peer-${peer.fingerprint}')));
        await tester.pump();
        await tester.pump(_popoverIn);
        final rect = tester.getRect(_popover());
        expect(rect.width, closeTo(264, 0.01));
        final expected = placePopover(
          area: _area,
          center: center,
          radius: scene.layout.peerRadius,
          popover: rect.size,
        );
        expect(rect.topLeft.dx, closeTo(expected.dx, 0.5));
        expect(rect.topLeft.dy, closeTo(expected.dy, 0.5));
        expect(rect.left, greaterThanOrEqualTo(10 - 0.5));
        expect(rect.right, lessThanOrEqualTo(_area.width - 10 + 0.5));
        expect(rect.top, greaterThanOrEqualTo(8 - 0.5));
        expect(rect.bottom, lessThanOrEqualTo(_area.height - 8 + 0.5));
        if (center.dy > _area.height / 2) {
          expect(
            rect.bottom,
            lessThanOrEqualTo(center.dy - scene.layout.peerRadius - 14 + 0.5),
          );
        }
        await tester.sendKeyEvent(LogicalKeyboardKey.escape);
        await tester.pump();
      }
    });

    testWidgets('it enters with a fade and a scale in 240 ms, and with '
        'reduced motion it is there at once', (tester) async {
      final host = _Host(_state(_devices(3)));
      await _mount(tester, host);
      await tester.tap(_zone('A'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 60));
      FadeTransition fade() => tester.widget<FadeTransition>(
        _inDiagram(find.byType(FadeTransition)).first,
      );
      ScaleTransition scale() => tester.widget<ScaleTransition>(
        _inDiagram(find.byType(ScaleTransition)).first,
      );
      expect(fade().opacity.value, greaterThan(0));
      expect(fade().opacity.value, lessThan(1));
      expect(scale().scale.value, greaterThan(0.5));
      expect(scale().scale.value, lessThan(1));
      await tester.pump(const Duration(milliseconds: 200));
      expect(fade().opacity.value, 1);
      expect(scale().scale.value, 1);
      expect(_live(tester), 0);
      await tester.pumpWidget(const SizedBox());

      await _mount(tester, host, reduceMotion: true);
      await tester.tap(_zone('A'));
      await tester.pump();
      expect(fade().opacity.value, 1);
      expect(scale().scale.value, 1);
      await tester.pump();
      expect(_live(tester), 0);
    });

    testWidgets('it closes by itself when its device is unpaired or '
        'leaves the list', (tester) async {
      final strings = stringsFor('en');
      final host = _Host(_state(_devices(3)));
      await _mount(tester, host);
      await _open(tester, 'B');
      host.state.value = _state([
        _entry('A'),
        _entry('B', paired: false),
        _entry('C'),
      ]);
      await tester.pump();
      expect(_popover(), findsNothing);
      expect(find.text(strings.sendEllipsis), findsNothing);
      host.state.value = _state(_devices(3));
      await tester.pump();
      expect(_popover(), findsNothing);
      await _open(tester, 'C');
      host.state.value = _state([_entry('A'), _entry('B')]);
      await tester.pump();
      await tester.pump();
      expect(_popover(), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('it closes by itself when the diagram shrinks and its '
        'device goes into "+k"', (tester) async {
      final entries = [
        for (final letter in ['A', 'B', 'C', 'D', 'E', 'F', 'G'])
          _entry(letter),
        _entry('H', visible: false),
      ];
      final host = _Host(_state(entries));
      await _mount(tester, host);
      expect(_scene(tester).peers, hasLength(8));
      await _open(tester, 'H');
      expect(_popover(), findsOneWidget);
      await tester.pumpWidget(_app(host, code: 'en', size: _small));
      await tester.pump();
      await tester.pump();
      expect(
        _scene(tester).peers.any((peer) => peer.fingerprint == _fp('H')),
        isFalse,
      );
      expect(_popover(), findsNothing);
      await tester.pumpWidget(_app(host, code: 'en'));
      await tester.pump();
      expect(_popover(), findsNothing);
      expect(tester.takeException(), isNull);
    });
  });

  group('E263: the "+k" disc', () {
    for (final code in languageCodes) {
      testWidgets('$code: a tap on "+k" calls onShowDevices and opens no '
          'popover', (tester) async {
        final host = _Host(_state(_devices(8)));
        await _mount(tester, host, code: code, size: _small);
        final scene = _scene(tester);
        expect(scene.peers, hasLength(6));
        final more = find.byKey(const ValueKey('flow-more'));
        expect(more, findsOneWidget);
        final slot = scene.layout.slots.firstWhere((slot) => slot.overflow);
        expect((tester.getCenter(more) - slot.center).distance, lessThan(0.01));
        await tester.tap(more);
        await tester.pump();
        expect(host.showDevices, 1);
        expect(_popover(), findsNothing);
        expect(host.sent, isEmpty);
      });
    }
  });

  group('E263: structure', () {
    testWidgets('the background and the animated painter live in two '
        'different RepaintBoundary layers', (tester) async {
      final host = _Host(_state(_devices(3)));
      await _mount(tester, host);
      final paints = _inDiagram(find.byType(CustomPaint));
      final background = find.byWidgetPredicate(
        (widget) =>
            widget is CustomPaint &&
            widget.painter is FlowBackgroundPainter &&
            widget.foregroundPainter == null,
      );
      final foreground = find.byWidgetPredicate(
        (widget) =>
            widget is CustomPaint &&
            widget.foregroundPainter is FlowPainter &&
            widget.painter == null,
      );
      expect(
        find.descendant(of: find.byType(FlowDiagram), matching: background),
        findsOneWidget,
      );
      expect(
        find.descendant(of: find.byType(FlowDiagram), matching: foreground),
        findsOneWidget,
      );
      expect(paints, findsAtLeastNWidgets(2));
      Element boundaryOf(Finder finder) => tester.element(
        find.ancestor(of: finder, matching: find.byType(RepaintBoundary)).first,
      );
      final backBoundary = boundaryOf(background);
      final frontBoundary = boundaryOf(foreground);
      expect(identical(backBoundary, frontBoundary), isFalse);
      expect(
        find.descendant(
          of: find.byType(FlowDiagram),
          matching: find.byElementPredicate(
            (element) => identical(element, backBoundary),
          ),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: find.byType(FlowDiagram),
          matching: find.byElementPredicate(
            (element) => identical(element, frontBoundary),
          ),
        ),
        findsOneWidget,
      );
    });
  });

  group('E263: sizes from 0 x 0 to 1600 x 1000 with 0 to 32 devices', () {
    const sizes = [
      Size.zero,
      Size(1, 1),
      Size(30, 20),
      Size(100, 60),
      Size(300, 200),
      Size(419, 239),
      Size(420, 240),
      Size(432, 416),
      _small,
      Size(760, 520),
      _area,
      Size(1000, 700),
      Size(1180, 720),
      Size(1600, 1000),
      Size(1600, 240),
      Size(420, 1000),
    ];
    const counts = [0, 1, 2, 5, 6, 7, 8, 13, 20, 32];

    for (final busy in [false, true]) {
      testWidgets('${busy ? 'with transfers' : 'at rest'}: no exceptions '
          'while the diagram is resized', (tester) async {
        for (final count in counts) {
          final entries = _devices(count);
          final host = _Host(
            _state(
              entries,
              outgoing: busy && count > 0
                  ? _out(_letters[0], OutgoingPhase.uploading, sent: 300)
                  : null,
              incoming: busy && count > 1
                  ? _in(_letters[1], IncomingStage.warning)
                  : null,
            ),
          );
          host.hovered.value = count > 2 ? _fp(_letters[2]) : null;
          for (final size in sizes) {
            await _mount(tester, host, size: size);
            await tester.pump(const Duration(milliseconds: 300));
            expect(tester.takeException(), isNull, reason: '$count $size');
            final scene = _scene(tester);
            expect(scene.layout.size, size, reason: '$count $size');
            if (size.width >= 420 && size.height >= 240) {
              expect(
                scene.peers.length + scene.layout.hidden,
                count,
                reason: '$count $size',
              );
            }
          }
          await tester.pumpWidget(const SizedBox());
        }
      }, timeout: _sweep);
    }
  });
}
