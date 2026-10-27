import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:nexus_bridges/src/app_controller.dart';
import 'package:nexus_bridges_core/nexus_bridges_core.dart';

final class _XorProtector implements SecretProtector {
  static Uint8List _xor(Uint8List data) =>
      Uint8List.fromList([for (final b in data) b ^ 0x5A]);

  @override
  Uint8List protect(Uint8List data) => _xor(data);

  @override
  Uint8List? unprotect(Uint8List data) => _xor(data);
}

Future<int> _freePort() async {
  for (var attempt = 0; attempt < 600; attempt++) {
    try {
      final udp = await RawDatagramSocket.bind(
        InternetAddress.anyIPv4,
        0,
        reuseAddress: false,
      );
      final port = udp.port;
      udp.close();
      if (await _tcpPortFree(port)) return port;
    } on SocketException {
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
  }
  throw StateError('no free port');
}

Future<bool> _udpPortFree(int port) async {
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

Future<bool> _tcpPortFree(int port) async {
  try {
    final socket = await ServerSocket.bind(InternetAddress.anyIPv4, port);
    await socket.close();
    return true;
  } on SocketException {
    return false;
  }
}

Future<void> _deleteWithRetry(FileSystemEntity entity) async {
  for (var attempt = 0; attempt < 20; attempt++) {
    try {
      if (await entity.exists()) await entity.delete(recursive: true);
      return;
    } on FileSystemException {
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
  }
}

const String _homeId = '{network-a}';

final AdapterInfo _homeWifi = AdapterInfo(
  id: '{WIFI-ADAPTER}',
  friendlyName: 'Wi-Fi',
  description: 'Test wireless adapter',
  ifType: 71,
  isUp: true,
  ipv4: [Ipv4Subnet(InternetAddress('192.168.50.21'), 24)],
  hasGateway: true,
  networkId: _homeId,
  networkName: 'Home',
);

bool _prompting(NodeState state) =>
    state.prompts.any((prompt) => prompt.networkId == _homeId);

bool _pausing(NodeState state) =>
    state.pausedNetworks.any((prompt) => prompt.networkId == _homeId);

Future<void> _waitFor(
  AppController controller,
  bool Function(NodeState) condition,
) {
  final current = controller.state;
  if (current != null && condition(current)) return Future<void>.value();
  final reached = Completer<void>();
  void check() {
    final state = controller.state;
    if (state != null && condition(state) && !reached.isCompleted) {
      reached.complete();
    }
  }

  controller.addListener(check);
  return reached.future
      .timeout(const Duration(seconds: 5))
      .whenComplete(() => controller.removeListener(check));
}

final class _Harness {
  _Harness({required this.dataDir, required this.port});

  final Directory dataDir;
  final int port;
  final List<NexusNode> nodes = [];
  List<AdapterInfo> adapters = const [];
  int startCalls = 0;
  int failuresLeft = 0;
  Completer<void>? gate;

  Future<NexusNode> startNode() async {
    startCalls++;
    final pending = gate;
    if (pending != null) await pending.future;
    if (failuresLeft > 0) {
      failuresLeft--;
      throw StateError('start failed');
    }
    final node = await NexusNode.start(
      dataDir: dataDir,
      protector: _XorProtector(),
      readNetworks: () async => adapters,
      pollInterval: const Duration(milliseconds: 50),
      port: port,
      deviceName: 'Test PC',
    );
    nodes.add(node);
    return node;
  }

  Future<void> close() async {
    for (final node in nodes) {
      await node.shutdown();
    }
  }
}

final class _Counter {
  _Counter(this.controller) {
    controller.addListener(_onChange);
  }

  final AppController controller;
  int count = 0;
  final List<Completer<void>> _waiters = [];

  void _onChange() {
    count++;
    for (final waiter in _waiters) {
      if (!waiter.isCompleted) waiter.complete();
    }
    _waiters.clear();
  }

  Future<void> next() {
    final waiter = Completer<void>();
    _waiters.add(waiter);
    return waiter.future.timeout(const Duration(seconds: 5));
  }
}

Future<bool> _isDone(Stream<NodeState> states) {
  final done = Completer<bool>();
  states.listen(
    (_) {},
    onDone: () {
      if (!done.isCompleted) done.complete(true);
    },
  );
  return done.future.timeout(
    const Duration(seconds: 2),
    onTimeout: () => false,
  );
}

void main() {
  late Directory root;
  late _Harness harness;
  late List<AppController> controllers;

  AppController controllerFor({
    Future<String> Function()? loadLanguage,
    _Harness? using,
  }) {
    final source = using ?? harness;
    final controller = AppController(
      startNode: source.startNode,
      loadLanguage: loadLanguage ?? () async => 'es',
    );
    controllers.add(controller);
    return controller;
  }

  setUp(() async {
    root = await Directory.systemTemp.createTemp('nexus_app_controller_');
    harness = _Harness(
      dataDir: Directory('${root.path}${Platform.pathSeparator}data'),
      port: await _freePort(),
    );
    controllers = [];
  });

  tearDown(() async {
    for (final controller in controllers) {
      await controller.shutdown();
    }
    await harness.close();
    await _deleteWithRetry(root);
  });

  group('init', () {
    test('starts with no state, English and no failure', () {
      final controller = controllerFor();

      expect(controller.state, isNull);
      expect(controller.languageCode, 'en');
      expect(controller.startFailed, isFalse);
      expect(controller.identityWarningDismissed, isFalse);
    });

    test('leaves the node state and the language of loadLanguage', () async {
      final controller = controllerFor(loadLanguage: () async => 'es');
      final counter = _Counter(controller);

      await controller.init();

      final node = harness.nodes.single;
      final state = controller.state;
      expect(state, isNotNull);
      expect(state!.identityStatus, IdentityStatus.ok);
      expect(state.deviceName, 'Test PC');
      expect(state.fingerprint, matches(RegExp(r'^[0-9A-F]{64}$')));
      expect(state.fingerprint, node.state.fingerprint);
      expect(controller.languageCode, 'es');
      expect(controller.startFailed, isFalse);
      expect(counter.count, greaterThanOrEqualTo(1));
    });

    test('takes English from loadLanguage when it says so', () async {
      final controller = controllerFor(loadLanguage: () async => 'en');

      await controller.init();

      expect(controller.languageCode, 'en');
      expect(controller.state, isNotNull);
    });

    test('a loadLanguage that throws leaves English and still starts the '
        'node', () async {
      final controller = controllerFor(
        loadLanguage: () async => throw StateError('settings unreadable'),
      );

      await controller.init();

      expect(controller.languageCode, 'en');
      expect(controller.state, isNotNull);
      expect(controller.startFailed, isFalse);
      expect(harness.nodes, hasLength(1));
    });

    test('a loadLanguage that throws synchronously also leaves English', () {
      final controller = controllerFor(
        loadLanguage: () => throw StateError('settings unreadable'),
      );

      return controller.init().then((_) {
        expect(controller.languageCode, 'en');
        expect(controller.state, isNotNull);
      });
    });

    test('a startNode that throws leaves startFailed, no state and '
        'notifies', () async {
      harness.failuresLeft = 1;
      final controller = controllerFor();
      final counter = _Counter(controller);

      await controller.init();

      expect(controller.startFailed, isTrue);
      expect(controller.state, isNull);
      expect(counter.count, 1);
      expect(harness.nodes, isEmpty);
    });

    test('two init calls at the same time start a single node', () async {
      harness.gate = Completer<void>();
      final controller = controllerFor();

      final first = controller.init();
      final second = controller.init();
      harness.gate!.complete();
      await Future.wait([first, second]);

      expect(harness.startCalls, 1);
      expect(harness.nodes, hasLength(1));
      expect(controller.state, isNotNull);
    });

    test('init after a successful start does not start another node', () async {
      final controller = controllerFor();

      await controller.init();
      await controller.init();

      expect(harness.startCalls, 1);
      expect(harness.nodes, hasLength(1));
    });
  });

  group('retry', () {
    test('after a failed start, retry starts the node', () async {
      harness.failuresLeft = 1;
      final controller = controllerFor();
      await controller.init();
      expect(controller.startFailed, isTrue);
      final counter = _Counter(controller);

      await controller.retry();

      expect(harness.startCalls, 2);
      expect(controller.startFailed, isFalse);
      expect(controller.state, isNotNull);
      expect(controller.state!.identityStatus, IdentityStatus.ok);
      expect(counter.count, greaterThanOrEqualTo(1));
    });

    test('two retry calls at the same time start a single node', () async {
      harness.failuresLeft = 1;
      final controller = controllerFor();
      await controller.init();
      expect(controller.startFailed, isTrue);
      harness.gate = Completer<void>();

      final first = controller.retry();
      final second = controller.retry();
      harness.gate!.complete();
      await Future.wait([first, second]);

      expect(harness.startCalls, 2);
      expect(harness.nodes, hasLength(1));
      expect(controller.startFailed, isFalse);
      expect(controller.state, isNotNull);
    });

    test('retry while init is still running does nothing', () async {
      harness.gate = Completer<void>();
      final controller = controllerFor();

      final starting = controller.init();
      await controller.retry();
      harness.gate!.complete();
      await starting;

      expect(harness.startCalls, 1);
      expect(harness.nodes, hasLength(1));
    });

    test('a retry that fails again keeps startFailed and allows another '
        'retry', () async {
      harness.failuresLeft = 2;
      final controller = controllerFor();
      await controller.init();

      await controller.retry();
      expect(controller.startFailed, isTrue);
      expect(controller.state, isNull);

      await controller.retry();
      expect(controller.startFailed, isFalse);
      expect(controller.state, isNotNull);
      expect(harness.startCalls, 3);
    });

    test('with a node whose identity failed, retry goes to the node and '
        'recovers it (RF-8)', () async {
      await root.create(recursive: true);
      final blocker = File('${root.path}${Platform.pathSeparator}blocked');
      await blocker.writeAsString('not a directory');
      final failing = _Harness(
        dataDir: Directory(blocker.path),
        port: harness.port,
      );
      addTearDown(failing.close);
      final controller = controllerFor(using: failing);
      await controller.init();
      expect(controller.startFailed, isFalse);
      expect(controller.state!.identityStatus, IdentityStatus.failed);

      await blocker.delete();
      final counter = _Counter(controller);
      await controller.retry();
      if (controller.state!.identityStatus != IdentityStatus.ok) {
        await counter.next();
      }

      expect(failing.startCalls, 1);
      expect(controller.state!.identityStatus, IdentityStatus.ok);
      expect(controller.state!.fingerprint, isNotEmpty);
    });
  });

  group('node states', () {
    test('each state of the node updates state and notifies', () async {
      harness.adapters = [_homeWifi];
      final controller = controllerFor();
      await controller.init();
      await _waitFor(controller, _prompting);
      final counter = _Counter(controller);
      final before = controller.state;

      final notified = counter.next();
      controller.dismissPrompt(_homeId);
      await notified;

      expect(counter.count, greaterThanOrEqualTo(1));
      expect(controller.state, isNot(same(before)));
      expect(controller.state, same(harness.nodes.single.state));
      expect(_prompting(controller.state!), isFalse);
      expect(_pausing(controller.state!), isTrue);
    });

    test('decideNetwork goes to the node and saves the decision', () async {
      harness.adapters = [_homeWifi];
      final controller = controllerFor();
      await controller.init();
      await _waitFor(controller, _prompting);
      final counter = _Counter(controller);

      final notified = counter.next();
      await controller.decideNetwork(_homeId, NetworkDecision.untrusted);
      await notified;

      final saved = await File(
        '${harness.dataDir.path}${Platform.pathSeparator}networks.json',
      ).readAsString();
      expect(saved, contains(_homeId));
      expect(saved, contains('untrusted'));
      expect(controller.state, same(harness.nodes.single.state));
      expect(controller.state!.decisionNotSaved, isFalse);
      expect(_prompting(controller.state!), isFalse);
      expect(_pausing(controller.state!), isTrue);
    });

    test('askAgain goes to the node', () async {
      harness.adapters = [_homeWifi];
      final controller = controllerFor();
      await controller.init();
      await _waitFor(controller, _prompting);
      controller.dismissPrompt(_homeId);
      await _waitFor(controller, _pausing);
      final counter = _Counter(controller);

      final notified = counter.next();
      controller.askAgain(_homeId);
      await notified;

      expect(counter.count, greaterThanOrEqualTo(1));
      expect(controller.state, same(harness.nodes.single.state));
      expect(_prompting(controller.state!), isTrue);
      expect(_pausing(controller.state!), isFalse);
    });

    test(
      'an action that changes nothing in the node does not notify',
      () async {
        harness.adapters = [_homeWifi];
        final controller = controllerFor();
        await controller.init();
        await _waitFor(controller, _prompting);
        await Future<void>.delayed(const Duration(milliseconds: 200));
        final counter = _Counter(controller);
        final before = controller.state;

        controller.dismissPrompt('{unknown-network}');
        controller.askAgain('{unknown-network}');
        await Future<void>.delayed(const Duration(milliseconds: 500));

        expect(counter.count, 0);
        expect(controller.state, same(before));
        expect(_prompting(controller.state!), isTrue);
      },
    );

    test('rescan goes to the node and completes', () async {
      final controller = controllerFor();
      await controller.init();

      await controller.rescan().timeout(const Duration(seconds: 5));

      expect(controller.state, isNotNull);
    });

    test('without a node, the delegating methods do nothing and do not '
        'throw', () async {
      final controller = controllerFor();

      await controller.decideNetwork('{network-d}', NetworkDecision.trusted);
      controller.dismissPrompt('{network-d}');
      controller.askAgain('{network-d}');
      await controller.rescan();
      await controller.retry();

      expect(harness.startCalls, 0);
      expect(controller.state, isNull);
      expect(
        File('${harness.dataDir.path}${Platform.pathSeparator}networks.json')
            .existsSync(),
        isFalse,
      );
    });
  });

  group('pairing methods (T13)', () {
    final unknown = 'AB' * 32;

    test(
      'without a node, pair is unavailable and the rest do nothing',
      () async {
        final controller = controllerFor();

        expect(await controller.pair(unknown), PairRequestResult.unavailable);
        controller.answerCode(matches: true);
        controller.cancelPairing();
        controller.cancelRequest();
        controller.answerRequest(ReceiverAnswer.matches);
        controller.dismissPairing();
        await controller.answerReplace(unknown, replace: true);
        await controller.answerMine(unknown, mine: true);
        await controller.setMine(unknown, mine: true);
        await controller.unpair(unknown);
        await controller.unignore(unknown);
        await controller.retrySave();
        controller.dismissNotice(1);

        expect(harness.startCalls, 0);
        expect(controller.state, isNull);
      },
    );

    test('with a node, pair of a device that is not in the list is '
        'unavailable (RF-67)', () async {
      final controller = controllerFor();
      await controller.init();

      expect(await controller.pair(unknown), PairRequestResult.unavailable);
      expect(controller.state!.pairing, isNull);
    });

    test('with a node, the methods on an unknown device go to the node and '
        'change nothing', () async {
      final controller = controllerFor();
      await controller.init();
      final before = controller.state!;

      controller.answerCode(matches: false);
      controller.cancelPairing();
      controller.cancelRequest();
      controller.answerRequest(ReceiverAnswer.mismatch);
      controller.dismissPairing();
      await controller.answerReplace(unknown, replace: false);
      await controller.answerMine(unknown, mine: true);
      await controller.setMine(unknown, mine: true);
      await controller.unpair(unknown);
      await controller.unignore(unknown);
      await controller.retrySave();
      controller.dismissNotice(42);
      await Future<void>.delayed(const Duration(milliseconds: 200));

      final after = controller.state!;
      expect(after.entries, before.entries);
      expect(after.pairing, isNull);
      expect(after.questions, isEmpty);
      expect(after.unsavedChanges, isFalse);
      expect(
        after.notices.where(
          (notice) => notice.kind != NoticeKind.changeNotSaved,
        ),
        isEmpty,
      );
    });
  });

  group('E279 cancelRequest (RF-248)', () {
    test('without a node it does nothing and does not start one', () {
      final controller = controllerFor();

      controller.cancelRequest();
      controller.cancelRequest();

      expect(harness.startCalls, 0);
      expect(controller.state, isNull);
    });

    test('with a node and no request it goes to the node and changes '
        'nothing', () async {
      final controller = controllerFor();
      await controller.init();
      final before = controller.state!;

      controller.cancelRequest();
      await Future<void>.delayed(const Duration(milliseconds: 200));

      final after = controller.state!;
      expect(after.pairing, isNull);
      expect(after.entries, before.entries);
      expect(after.notices, before.notices);
    });

    test('after shutdown it does not throw', () async {
      final controller = controllerFor();
      await controller.init();
      await controller.shutdown();

      expect(controller.cancelRequest, returnsNormally);
    });
  });

  group('transfer methods (T2 of 005, point 92)', () {
    final unknown = 'CD' * 32;
    const session = 'no-such-session';

    test('without a node, sendFile and revealLastReceived are unavailable '
        'and the rest do nothing nor throw', () async {
      final controller = controllerFor();

      expect(await controller.sendFile(unknown), SendFileResult.unavailable);
      expect(await controller.revealLastReceived(), RevealResult.unavailable);
      controller.cancelSending();
      controller.cancelReceiving(session);
      controller.answerIncoming(session, accept: true);
      controller.answerIncoming(session, accept: false);
      await controller.useProposedFolder(session);
      await controller.chooseOtherFolder(session);
      controller.useFolderAnyway(session);
      controller.cancelFolderQuestion(session);
      await controller.rememberFolderAfterEnd(session, remember: true);
      await controller.rememberFolderAfterEnd(session, remember: false);
      controller.dismissFolderPanel(session);

      expect(harness.startCalls, 0);
      expect(controller.state, isNull);
    });

    test(
      'after a failed start, the transfer methods still have no node',
      () async {
        harness.failuresLeft = 1;
        final controller = controllerFor();
        await controller.init();
        expect(controller.startFailed, isTrue);

        expect(await controller.sendFile(unknown), SendFileResult.unavailable);
        expect(await controller.revealLastReceived(), RevealResult.unavailable);
        await controller.useProposedFolder(session);
        await controller.chooseOtherFolder(session);
        await controller.rememberFolderAfterEnd(session, remember: true);
        expect(controller.state, isNull);
      },
    );

    test('with a node, sendFile of a device that is not in the list goes to '
        'the node and is unavailable, without a send', () async {
      final controller = controllerFor();
      await controller.init();

      expect(
        await controller.sendFile(unknown).timeout(const Duration(seconds: 5)),
        SendFileResult.unavailable,
      );
      await Future<void>.delayed(const Duration(milliseconds: 200));

      final state = controller.state!;
      expect(state.outgoing, isNull);
      expect(state.lastSent, isNull);
      expect(state.transferInProgress, isFalse);
      expect(state.pickerOpen, isFalse);
    });

    test('with a node and nothing received, revealLastReceived goes to the '
        'node and is unavailable', () async {
      final controller = controllerFor();
      await controller.init();

      expect(
        await controller.revealLastReceived().timeout(
          const Duration(seconds: 5),
        ),
        RevealResult.unavailable,
      );
      expect(controller.state!.lastReceived, isNull);
    });

    test('with a node, the methods on a session that does not exist go to '
        'the node, complete and change nothing', () async {
      final controller = controllerFor();
      await controller.init();
      final before = controller.state!;
      final budget = const Duration(seconds: 5);

      controller.cancelSending();
      controller.cancelReceiving(session);
      controller.answerIncoming(session, accept: true);
      controller.answerIncoming(session, accept: false);
      await controller.useProposedFolder(session).timeout(budget);
      await controller.chooseOtherFolder(session).timeout(budget);
      controller.useFolderAnyway(session);
      controller.cancelFolderQuestion(session);
      await controller
          .rememberFolderAfterEnd(session, remember: true)
          .timeout(budget);
      await controller
          .rememberFolderAfterEnd(session, remember: false)
          .timeout(budget);
      controller.dismissFolderPanel(session);
      await controller.rescan().timeout(budget);

      final after = controller.state!;
      expect(after.entries, before.entries);
      expect(after.outgoing, isNull);
      expect(after.incoming, isNull);
      expect(after.lastSent, isNull);
      expect(after.lastReceived, isNull);
      expect(after.transferInProgress, isFalse);
      expect(after.pickerOpen, isFalse);
      expect(after.incomingNamesake, isNull);
      expect(
        after.notices.where(
          (notice) => notice.kind != NoticeKind.changeNotSaved,
        ),
        isEmpty,
      );
    });

    test('after shutdown, sendFile and revealLastReceived are unavailable and '
        'the rest do nothing', () async {
      final controller = controllerFor();
      await controller.init();
      await controller.shutdown();

      expect(await controller.sendFile(unknown), SendFileResult.unavailable);
      expect(await controller.revealLastReceived(), RevealResult.unavailable);
      controller.cancelSending();
      controller.cancelReceiving(session);
      controller.answerIncoming(session, accept: true);
      await controller.useProposedFolder(session);
      await controller.chooseOtherFolder(session);
      controller.useFolderAnyway(session);
      controller.cancelFolderQuestion(session);
      await controller.rememberFolderAfterEnd(session, remember: true);
      controller.dismissFolderPanel(session);
    });
  });

  group('dismissIdentityWarning', () {
    test('sets the flag and notifies', () {
      final controller = controllerFor();
      final counter = _Counter(controller);

      controller.dismissIdentityWarning();

      expect(controller.identityWarningDismissed, isTrue);
      expect(counter.count, 1);
    });

    test('a second call keeps the flag and does not notify again', () {
      final controller = controllerFor();
      final counter = _Counter(controller);

      controller.dismissIdentityWarning();
      controller.dismissIdentityWarning();

      expect(controller.identityWarningDismissed, isTrue);
      expect(counter.count, 1);
    });

    test('a new node state does not bring the warning back', () async {
      harness.adapters = [_homeWifi];
      final controller = controllerFor();
      await controller.init();
      await _waitFor(controller, _prompting);
      controller.dismissIdentityWarning();
      final counter = _Counter(controller);
      final before = controller.state;

      final notified = counter.next();
      controller.dismissPrompt(_homeId);
      await notified;

      expect(controller.state, isNot(same(before)));
      expect(_pausing(controller.state!), isTrue);
      expect(controller.identityWarningDismissed, isTrue);
    });
  });

  group('shutdown', () {
    test('closes the node and frees its port', () async {
      final controller = controllerFor();
      await controller.init();
      final node = harness.nodes.single;
      expect(await _udpPortFree(harness.port), isFalse);

      await controller.shutdown().timeout(const Duration(seconds: 3));

      expect(await _isDone(node.states), isTrue);
      expect(await _udpPortFree(harness.port), isTrue);
    });

    test('twice in a row does not fail', () async {
      final controller = controllerFor();
      await controller.init();

      await controller.shutdown();
      await controller.shutdown();

      expect(await _udpPortFree(harness.port), isTrue);
    });

    test('twice at the same time does not fail', () async {
      final controller = controllerFor();
      await controller.init();

      await Future.wait([controller.shutdown(), controller.shutdown()]);

      expect(await _udpPortFree(harness.port), isTrue);
    });

    test('without a node does not fail', () async {
      final controller = controllerFor();

      await controller.shutdown();
      await controller.shutdown();

      expect(harness.startCalls, 0);
    });

    test('after a failed start does not fail', () async {
      harness.failuresLeft = 1;
      final controller = controllerFor();
      await controller.init();

      await controller.shutdown();
      await controller.shutdown();

      expect(controller.startFailed, isTrue);
    });

    test('stops listening to the node: no more notifications', () async {
      final controller = controllerFor();
      await controller.init();
      final node = harness.nodes.single;
      await controller.shutdown();
      final counter = _Counter(controller);

      node.dismissPrompt('{network-f}');
      await Future<void>.delayed(const Duration(milliseconds: 300));

      expect(counter.count, 0);
    });

    test('during an init closes the node that was being started', () async {
      harness.gate = Completer<void>();
      final controller = controllerFor();

      final starting = controller.init();
      final closing = controller.shutdown();
      harness.gate!.complete();
      await starting;
      await closing.timeout(const Duration(seconds: 3));

      expect(harness.nodes, hasLength(1));
      expect(await _isDone(harness.nodes.single.states), isTrue);
      expect(await _udpPortFree(harness.port), isTrue);
    });
  });
}
