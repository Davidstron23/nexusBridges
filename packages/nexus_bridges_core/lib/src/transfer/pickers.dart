final class PickerTracker {
  PickerTracker({required this._clock, required this._onChanged});

  final Duration Function() _clock;

  final void Function(bool open, Duration since) _onChanged;

  int _open = 0;

  Duration _since = Duration.zero;

  bool get isOpen => _open > 0;

  void open() {
    _open++;
    if (_open != 1) return;
    _since = _clock();
    _onChanged(true, _since);
  }

  void close() {
    if (_open == 0) return;
    _open--;
    if (_open != 0) return;
    _onChanged(false, _since);
  }
}
