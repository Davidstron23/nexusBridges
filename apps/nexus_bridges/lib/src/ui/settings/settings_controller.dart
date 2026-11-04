import 'package:flutter/foundation.dart';

final class SettingsController extends ChangeNotifier {
  bool _open = false;
  bool _closing = false;
  bool _instant = false;

  bool get isOpen => _open;

  bool get closing => _closing;

  bool get instant => _instant;

  void open() {
    if (_open) return;
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
    if (!_closing) return;
    _closing = false;
    notifyListeners();
  }
}
