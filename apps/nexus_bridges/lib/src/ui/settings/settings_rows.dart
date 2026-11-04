import 'package:flutter/material.dart';

import '../modal/timeline.dart';
import 'settings_section.dart';

const Duration _rowMotion = Duration(milliseconds: 420);

final class _Entry<T> {
  _Entry(this.item, {required this.fresh});

  T item;
  final bool fresh;
  final Key key = UniqueKey();
  bool leaving = false;
}

class SettingsRowList<T> extends StatefulWidget {
  const SettingsRowList({
    required this.items,
    required this.idOf,
    required this.rowBuilder,
    required this.emptyText,
    super.key,
  });

  final List<T> items;
  final String Function(T item) idOf;
  final Widget Function(BuildContext context, T item, int index) rowBuilder;
  final String emptyText;

  @override
  State<SettingsRowList<T>> createState() => _SettingsRowListState<T>();
}

class _SettingsRowListState<T> extends State<SettingsRowList<T>> {
  late List<_Entry<T>> _entries = [
    for (final item in widget.items) _Entry(item, fresh: false),
  ];
  bool _reduceMotion = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _reduceMotion = MediaQuery.disableAnimationsOf(context);
  }

  @override
  void didUpdateWidget(SettingsRowList<T> oldWidget) {
    super.didUpdateWidget(oldWidget);
    _sync();
  }

  void _sync() {
    final current = {
      for (final entry in _entries)
        if (!entry.leaving) widget.idOf(entry.item): entry,
    };
    final next = <_Entry<T>>[];
    for (final item in widget.items) {
      final entry = current.remove(widget.idOf(item));
      if (entry == null) {
        next.add(_Entry(item, fresh: true));
      } else {
        entry.item = item;
        next.add(entry);
      }
    }
    final removed = <_Entry<T>>[
      for (final entry in _entries)
        if (entry.leaving || current.containsValue(entry)) entry,
    ];
    for (final entry in removed) {
      if (_reduceMotion) continue;
      entry.leaving = true;
      final at = _entries.indexOf(entry);
      next.insert(at < next.length ? at : next.length, entry);
    }
    _entries = next;
  }

  void _gone(_Entry<T> entry) {
    if (!mounted) return;
    setState(() => _entries.remove(entry));
  }

  @override
  Widget build(BuildContext context) {
    if (_entries.isEmpty) return SettingsEmpty(text: widget.emptyText);
    return SettingsWell(
      child: Column(
        children: [
          for (var i = 0; i < _entries.length; i++)
            _RowShell(
              key: _entries[i].key,
              fresh: _entries[i].fresh,
              leaving: _entries[i].leaving,
              onGone: () => _gone(_entries[i]),
              child: widget.rowBuilder(context, _entries[i].item, i),
            ),
        ],
      ),
    );
  }
}

class _RowShell extends StatefulWidget {
  const _RowShell({
    required this.fresh,
    required this.leaving,
    required this.onGone,
    required this.child,
    super.key,
  });

  final bool fresh;
  final bool leaving;
  final VoidCallback onGone;
  final Widget child;

  @override
  State<_RowShell> createState() => _RowShellState();
}

class _RowShellState extends State<_RowShell>
    with SingleTickerProviderStateMixin {
  late final AnimationController _motion = AnimationController(
    vsync: this,
    duration: _rowMotion,
    value: 1,
  );
  bool _started = false;

  @override
  void initState() {
    super.initState();
    _motion.addStatusListener(_onStatus);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_started || !widget.fresh) return;
    _started = true;
    if (MediaQuery.disableAnimationsOf(context)) return;
    _motion.value = 0;
    _motion.forward();
  }

  @override
  void didUpdateWidget(_RowShell oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.leaving && !oldWidget.leaving) _motion.reverse();
  }

  void _onStatus(AnimationStatus status) {
    if (status == AnimationStatus.dismissed && widget.leaving) {
      widget.onGone();
    }
  }

  @override
  void dispose() {
    _motion.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      ignoring: widget.leaving,
      child: AnimatedBuilder(
        animation: _motion,
        child: widget.child,
        builder: (context, child) {
          final t = labEaseOut.transform(_motion.value);
          return ClipRect(
            child: Align(
              alignment: Alignment.topCenter,
              heightFactor: t,
              child: Opacity(opacity: t, child: child),
            ),
          );
        },
      ),
    );
  }
}
