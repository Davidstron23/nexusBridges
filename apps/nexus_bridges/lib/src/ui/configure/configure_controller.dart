import 'package:flutter/widgets.dart';

final class ConfigureController extends ChangeNotifier {
  String? _fingerprint;
  bool _open = false;
  bool _closing = false;
  bool _instant = false;

  String? get fingerprint => _fingerprint;

  bool get isOpen => _open;

  bool get closing => _closing;

  bool get instant => _instant;

  void open(String fingerprint) {
    if (_open && _fingerprint == fingerprint) return;
    _fingerprint = fingerprint;
    _open = true;
    _closing = false;
    _instant = false;
    notifyListeners();
  }

  void close({bool instant = false}) {
    if (!_open) return;
    _open = false;
    _closing = !instant;
    _instant = instant;
    notifyListeners();
  }

  void exitFinished() {
    if (!_closing && _fingerprint == null) return;
    _closing = false;
    if (!_open) _fingerprint = null;
    notifyListeners();
  }
}

class ConfigureScope extends InheritedNotifier<ConfigureController> {
  const ConfigureScope({
    required ConfigureController controller,
    required super.child,
    super.key,
  }) : super(notifier: controller);

  static ConfigureController? maybeOf(BuildContext context) {
    return context
        .dependOnInheritedWidgetOfExactType<ConfigureScope>()
        ?.notifier;
  }

  static ConfigureController? read(BuildContext context) {
    return context.getInheritedWidgetOfExactType<ConfigureScope>()?.notifier;
  }

  static String? shownFingerprint(BuildContext context) {
    final controller = maybeOf(context);
    if (controller == null || !controller.isOpen) return null;
    return controller.fingerprint;
  }
}
