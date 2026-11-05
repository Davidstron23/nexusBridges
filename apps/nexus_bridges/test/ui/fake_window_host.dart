import 'dart:async';

import 'package:nexus_bridges/src/window/window_host.dart';

typedef TrayHint = ({String title, String body});

class FakeWindowHost implements WindowHost {
  final List<bool> darkTitleBar = [];
  final List<String> calls = [];
  final List<TrayTexts> trayTexts = [];
  final List<TrayHint> hints = [];
  final StreamController<WindowEvent> _events =
      StreamController<WindowEvent>.broadcast();
  bool attached = true;
  bool trayVisible = true;
  bool foreground = true;
  Object? attachError;
  Object? trayError;
  Object? hintError;
  Object? hideError;
  Object? showError;
  Object? minimizeError;
  Object? attentionError;
  Object? quitError;

  void emit(WindowEvent event) => _events.add(event);

  int countOf(String call) => calls.where((entry) => entry == call).length;

  void _fail(Object? error) {
    if (error != null) throw error;
  }

  @override
  Stream<WindowEvent> get events => _events.stream;

  @override
  Future<bool> attach() async {
    calls.add('attach');
    _fail(attachError);
    return attached;
  }

  @override
  Future<bool> setTray({
    required bool enabled,
    required TrayTexts texts,
  }) async {
    calls.add('setTray $enabled ${texts.tooltip}|${texts.open}|${texts.exit}');
    trayTexts.add(texts);
    _fail(trayError);
    return enabled && trayVisible;
  }

  @override
  Future<bool> showTrayHint({
    required String title,
    required String body,
  }) async {
    calls.add('showTrayHint');
    hints.add((title: title, body: body));
    _fail(hintError);
    return true;
  }

  @override
  Future<void> hide() async {
    calls.add('hide');
    _fail(hideError);
  }

  @override
  Future<void> show() async {
    calls.add('show');
    _fail(showError);
  }

  @override
  Future<void> minimize() async {
    calls.add('minimize');
    _fail(minimizeError);
  }

  @override
  Future<bool> attention() async {
    calls.add('attention');
    _fail(attentionError);
    return foreground;
  }

  @override
  Future<void> setDarkTitleBar(bool dark) async {
    darkTitleBar.add(dark);
  }

  @override
  Future<void> quit() async {
    calls.add('quit');
    _fail(quitError);
  }
}
