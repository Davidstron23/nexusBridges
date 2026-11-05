import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nexus_bridges/src/drop/drop_events.dart';
import 'package:nexus_bridges_core/nexus_bridges_core.dart';

import '../../drop/fake_drop_events.dart';
import '../fake_app_controller.dart';
import '../pairing_fixtures.dart';

final String mineFp = fingerprintOf('AAAA1111');
final String foreignFp = fingerprintOf('BBBB2222');
final String otherMineFp = fingerprintOf('CCCC3333');
const String mineName = 'PC principal';
const String foreignName = 'Torre de Luis';
const String otherMineName = 'Portatil';

const RemoteRoot rootDocs = RemoteRoot(
  id: 'root-docs',
  name: 'Documentos',
  home: false,
  available: true,
);
const RemoteRoot rootHome = RemoteRoot(
  id: 'root-home',
  name: 'david',
  home: true,
  available: true,
);
const RemoteRoot rootUsb = RemoteRoot(
  id: 'root-usb',
  name: 'Pendrive',
  home: false,
  available: false,
);

const SavedDestination favPhotos = SavedDestination(
  rootId: 'root-docs',
  rootName: 'Documentos',
  path: ['fotos'],
);
const SavedDestination recentWork = SavedDestination(
  rootId: 'root-docs',
  rootName: 'Documentos',
  path: ['obra'],
);

const List<String> sentPaths = [r'C:\work\a.txt', r'C:\work\b.txt'];

NodeState destinationState({
  List<SavedDestination> favorites = const [],
  List<SavedDestination> recent = const [],
  bool mine = true,
  bool visible = true,
  bool withOther = false,
  List<TrayItemView> tray = const [],
  List<Notice> notices = const [],
}) {
  return NodeState(
    entries: [
      entry(
        fingerprint: mineFp,
        name: mineName,
        paired: true,
        mine: mine,
        visible: visible,
      ),
      entry(fingerprint: foreignFp, name: foreignName, paired: true),
      if (withOther)
        entry(
          fingerprint: otherMineFp,
          name: otherMineName,
          paired: true,
          mine: true,
        ),
    ],
    peers: {
      mineFp: PeerSettingsView(
        fingerprint: mineFp,
        realName: mineName,
        mine: mine,
        visible: visible,
        favorites: favorites,
        recent: recent,
      ),
    },
    tray: tray,
    notices: notices,
  );
}

class DelegatingController extends FakeAppController {
  DelegatingController({super.state, super.languageCode});

  final Map<String, Completer<RemoteListing>> gates = {};
  int rootRequests = 0;

  @override
  Future<RemoteListing> listRemoteRoots(
    String fingerprint, {
    List<SavedDestination> check = const [],
  }) {
    rootRequests++;
    return super.listRemoteRoots(fingerprint, check: check);
  }

  @override
  void prefetchPortal(String fingerprint) {
    super.prefetchPortal(fingerprint);
    portalPrefetch?.call(fingerprint);
  }

  @override
  Future<void> requestPortal(String fingerprint) async {
    await super.requestPortal(fingerprint);
    portalRequest?.call(fingerprint);
  }
}

Future<(DelegatingController, FakeDropEvents)> pumpDestinationHome(
  WidgetTester tester,
  String code,
  NodeState state, {
  Size size = const Size(1200, 800),
  bool reduceMotion = false,
  double textScale = 1,
  bool materialAround = false,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  if (textScale != 1) {
    tester.platformDispatcher.textScaleFactorTestValue = textScale;
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
  }
  final controller = DelegatingController(state: state, languageCode: code);
  final events = FakeDropEvents();
  addTearDown(events.close);
  await pumpHome(
    tester,
    controller,
    code,
    dropEvents: events,
    reduceMotion: reduceMotion,
    materialAround: materialAround,
  );
  return (controller, events);
}

Offset rowOf(WidgetTester tester, String fingerprint) =>
    tester.getCenter(find.byKey(ValueKey(fingerprint)));

Offset discOf(WidgetTester tester, String fingerprint) =>
    tester.getCenter(find.byKey(ValueKey('flow-peer-$fingerprint')));

Future<void> dropOn(
  WidgetTester tester,
  FakeDropEvents events,
  Offset at, {
  List<String> paths = sentPaths,
  int? count,
}) async {
  events.add(DropEnter(at));
  await tester.pump();
  events.add(DropDone(at, paths, count ?? paths.length));
  await tester.pump();
  await tester.pump();
}

Future<void> settleMenu(WidgetTester tester) async {
  await tester.pump();
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 50));
}

Future<void> settleNav(WidgetTester tester) async {
  await tester.pump();
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 600));
  await tester.pump();
}

double topOf(WidgetTester tester, String text) =>
    tester.getTopLeft(find.text(text)).dy;
