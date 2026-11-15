import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

final ValueNotifier<bool> keyboardNavigation = ValueNotifier<bool>(false);

final Set<LogicalKeyboardKey> _navigationKeys = {
  LogicalKeyboardKey.arrowDown,
  LogicalKeyboardKey.arrowUp,
  LogicalKeyboardKey.arrowLeft,
  LogicalKeyboardKey.arrowRight,
  LogicalKeyboardKey.tab,
};

bool _installed = false;

void ensureKeyboardNavigation() {
  if (_installed) return;
  _installed = true;
  HardwareKeyboard.instance.addHandler((event) {
    if (event is KeyDownEvent && _navigationKeys.contains(event.logicalKey)) {
      keyboardNavigation.value = true;
    }
    return false;
  });
  GestureBinding.instance.pointerRouter.addGlobalRoute((event) {
    if (event is PointerHoverEvent || event is PointerDownEvent) {
      keyboardNavigation.value = false;
    }
  });
}
