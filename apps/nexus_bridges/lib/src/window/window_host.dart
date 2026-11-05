sealed class WindowEvent {
  const WindowEvent();
}

final class CloseRequested extends WindowEvent {
  const CloseRequested();
}

final class ExitRequested extends WindowEvent {
  const ExitRequested();
}

final class TrayVisibilityChanged extends WindowEvent {
  const TrayVisibilityChanged(this.visible);

  final bool visible;
}

final class TrayTexts {
  const TrayTexts({
    required this.tooltip,
    required this.open,
    required this.exit,
  });

  final String tooltip;
  final String open;
  final String exit;
}

abstract interface class WindowHost {
  Stream<WindowEvent> get events;

  Future<bool> attach();

  Future<bool> setTray({required bool enabled, required TrayTexts texts});

  Future<bool> showTrayHint({required String title, required String body});

  Future<void> hide();

  Future<void> show();

  Future<void> minimize();

  Future<bool> attention();

  Future<void> setDarkTitleBar(bool dark);

  Future<void> quit();
}
