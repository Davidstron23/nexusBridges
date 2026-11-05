import 'dart:async';
import 'dart:ui' show AppExitResponse;

import 'package:flutter/widgets.dart';

import '../app_controller.dart';
import '../l10n/app_strings.dart';
import '../ui/attention.dart';
import '../ui/exit_flow.dart';
import 'window_host.dart';

final class WindowCoordinator {
  WindowCoordinator({
    required this._host,
    required this._controller,
    required this._attention,
    required this._context,
    required this._neutralFocus,
    this._shutdownBudget = const Duration(seconds: 5),
  });

  final WindowHost _host;
  final AppController _controller;
  final AttentionWatcher _attention;
  final BuildContext? Function() _context;
  final FocusNode _neutralFocus;
  final Duration _shutdownBudget;

  StreamSubscription<WindowEvent>? _events;
  Future<AppExitResponse>? _closing;
  String? _appliedLanguage;
  bool? _appliedCloseToTray;
  bool _attached = false;
  bool _trayVisible = false;
  bool _started = false;
  bool _disposed = false;
  bool _exiting = false;

  Future<void> start() async {
    if (_started || _disposed) return;
    _started = true;
    _events = _host.events.listen(_onEvent);
    _controller.addListener(_onController);
    _attention.addListener(_onAttention);
    try {
      _attached = await _host.attach();
    } catch (_) {
      _attached = false;
    }
    await _applyTray();
  }

  void _onEvent(WindowEvent event) {
    switch (event) {
      case CloseRequested():
        unawaited(handleClose());
      case ExitRequested():
        unawaited(handleExit());
      case TrayVisibilityChanged(:final visible):
        _trayVisible = visible;
    }
  }

  void _onController() {
    if (_disposed || !_started) return;
    if (_controller.languageCode == _appliedLanguage &&
        _controller.closeToTray == _appliedCloseToTray) {
      return;
    }
    unawaited(_applyTray());
  }

  Future<void> _applyTray() async {
    final language = _controller.languageCode;
    final enabled = _controller.closeToTray;
    _appliedLanguage = language;
    _appliedCloseToTray = enabled;
    final strings = stringsFor(language);
    try {
      _trayVisible = await _host.setTray(
        enabled: enabled,
        texts: TrayTexts(
          tooltip: strings.appTitle,
          open: strings.systemTrayOpen,
          exit: strings.systemTrayExit,
        ),
      );
    } catch (_) {
      _trayVisible = false;
    }
  }

  Future<AppExitResponse> handleClose() {
    return _closing ??= _close().whenComplete(() => _closing = null);
  }

  Future<void> handleExit() async {
    if (_exiting) return;
    _exiting = true;
    try {
      await _closing;
      await (_closing = _exit().whenComplete(() => _closing = null));
    } finally {
      _exiting = false;
    }
  }

  Future<AppExitResponse> _close() async {
    try {
      await waitForPickerToClose(_controller);
      if (_attached && _controller.closeToTray) {
        if (_trayVisible) {
          await _host.hide();
          await _announceTray();
        } else {
          await _host.minimize();
        }
        return AppExitResponse.cancel;
      }
      final response = await handleExitRequest(
        _controller,
        context: _context,
        shutdownBudget: _shutdownBudget,
      );
      if (response == AppExitResponse.exit && _attached) {
        await _host.quit();
      }
      return response;
    } catch (_) {
      return AppExitResponse.cancel;
    }
  }

  Future<AppExitResponse> _exit() async {
    try {
      await waitForPickerToClose(_controller);
      if (_controller.state?.transferInProgress == true) {
        await _host.show();
        final context = _context();
        if (context != null && context.mounted) {
          final confirmed = await confirmCloseDuringTransfer(
            context,
            _controller,
          );
          if (!confirmed) return AppExitResponse.cancel;
        }
      }
      try {
        await _controller.shutdown().timeout(_shutdownBudget);
      } catch (_) {}
      await _host.quit();
      return AppExitResponse.exit;
    } catch (_) {
      return AppExitResponse.cancel;
    }
  }

  Future<void> _announceTray() async {
    if (_controller.trayHintShown) return;
    final strings = stringsFor(_controller.languageCode);
    try {
      await _host.showTrayHint(
        title: strings.systemTrayHintTitle,
        body: strings.systemTrayHintBody,
      );
    } catch (_) {}
    await _controller.markTrayHintShown();
  }

  void _onAttention() {
    if (_disposed) return;
    if (!_modalOpen) _neutralFocus.requestFocus();
    if (_controller.state?.pickerOpen == true) return;
    final lifecycle = WidgetsBinding.instance.lifecycleState;
    if (lifecycle == AppLifecycleState.resumed) return;
    unawaited(_bringForward());
  }

  bool get _modalOpen {
    final context = _context();
    if (context == null || !context.mounted) return false;
    return Navigator.maybeOf(context)?.canPop() ?? false;
  }

  Future<void> _bringForward() async {
    try {
      await _host.attention();
    } catch (_) {}
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    unawaited(_events?.cancel());
    _events = null;
    _controller.removeListener(_onController);
    _attention.removeListener(_onAttention);
  }
}
