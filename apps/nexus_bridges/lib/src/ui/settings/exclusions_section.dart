import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:nexus_bridges_core/nexus_bridges_core.dart';

import '../../app_controller.dart';
import '../../l10n/app_strings.dart';
import '../icons/folder_icon.dart';
import '../icons/glyphs.dart';
import '../modal/timeline.dart';
import '../theme/app_theme.dart';
import '../theme/tokens.dart';
import 'inline_confirm.dart';
import 'settings_field.dart';
import 'settings_section.dart';

const int maxExclusions = 64;

const Duration _chipIn = Duration(milliseconds: 500);
const Duration _chipOut = Duration(milliseconds: 400);
const Cubic _pop = Cubic(0.2, 0.8, 0.2, 1);

final class _Item {
  _Item(this.name, {required this.fresh});

  final String name;
  final bool fresh;
  final Key key = UniqueKey();
  bool leaving = false;
}

class ExclusionsSection extends StatefulWidget {
  const ExclusionsSection({required this.controller, super.key});

  final AppController controller;

  @override
  State<ExclusionsSection> createState() => _ExclusionsSectionState();
}

class _ExclusionsSectionState extends State<ExclusionsSection>
    with ConfirmCancelMixin<ExclusionsSection> {
  final TextEditingController _text = TextEditingController();
  final FocusNode _focus = FocusNode();
  final List<Timer> _timers = [];
  late List<_Item> _items;
  ExclusionProblem? _problem;
  bool _adding = false;
  bool _confirming = false;
  bool _reduceMotion = false;

  List<String> get _names =>
      widget.controller.state?.settings.exclusions ?? const [];

  @override
  void initState() {
    super.initState();
    _items = [for (final name in _names) _Item(name, fresh: false)];
    widget.controller.addListener(_onController);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _reduceMotion = MediaQuery.disableAnimationsOf(context);
  }

  @override
  void didUpdateWidget(ExclusionsSection oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller == widget.controller) return;
    oldWidget.controller.removeListener(_onController);
    widget.controller.addListener(_onController);
  }

  @override
  void dispose() {
    widget.controller.removeListener(_onController);
    for (final timer in _timers) {
      timer.cancel();
    }
    _text.dispose();
    _focus.dispose();
    super.dispose();
  }

  void _onController() {
    final names = _names;
    setState(() {
      if (!_sameNames(names)) _problem = null;
      _sync(names);
    });
  }

  bool _sameNames(List<String> names) {
    final shown = [
      for (final item in _items)
        if (!item.leaving) item.name,
    ];
    if (shown.length != names.length) return false;
    for (var i = 0; i < shown.length; i++) {
      if (shown[i] != names[i]) return false;
    }
    return true;
  }

  void _sync(List<String> names) {
    final current = {
      for (final item in _items)
        if (!item.leaving) item.name: item,
    };
    final next = <_Item>[
      for (final name in names)
        current.remove(name) ?? _Item(name, fresh: true),
    ];
    final removed = <_Item>[
      for (final item in _items)
        if (item.leaving || current.containsKey(item.name)) item,
    ];
    for (final item in removed) {
      if (_reduceMotion) continue;
      final at = math.min(_items.indexOf(item), next.length);
      if (!item.leaving) {
        item.leaving = true;
        _timers.add(
          Timer(_chipOut, () {
            if (!mounted) return;
            setState(() => _items.remove(item));
          }),
        );
      }
      next.insert(at, item);
    }
    _items = next;
  }

  Future<void> _add() async {
    if (_adding) return;
    setState(() => _adding = true);
    final outcome = await widget.controller.addExclusion(_text.text);
    if (!mounted) return;
    setState(() {
      _adding = false;
      _problem = outcome.problem;
      if (outcome.problem == null) _text.clear();
    });
    _focus.requestFocus();
  }

  void _toggleConfirm() {
    setState(() => _confirming = !_confirming);
    if (_confirming) {
      registerConfirm(_cancelConfirm);
    } else {
      unregisterConfirm();
    }
  }

  void _cancelConfirm() {
    unregisterConfirm();
    if (!mounted) return;
    setState(() => _confirming = false);
  }

  void _restore() {
    unregisterConfirm();
    setState(() => _confirming = false);
    unawaited(widget.controller.restoreExclusions());
  }

  String? _message(AppStrings strings) {
    final problem = _problem;
    if (problem == null) return null;
    return switch (problem) {
      ExclusionProblem.empty => strings.exclusionEmpty,
      ExclusionProblem.invalid => strings.exclusionInvalid,
      ExclusionProblem.duplicate => strings.exclusionDuplicate,
      ExclusionProblem.full => strings.exclusionFull,
    };
  }

  @override
  Widget build(BuildContext context) {
    final strings = AppStringsDelegate.of(context);
    final colors = NbColors.of(context);
    final names = _names;
    final message = _message(strings);
    final bold = NbText.caption.copyWith(
      color: colors.text,
      fontSize: 12.5,
      fontWeight: FontWeight.w600,
    );
    return SettingsSection(
      icon: Glyphs.folderX,
      title: strings.sectionExclusions,
      count: strings.ofMax(names.length, maxExclusions),
      description: strings.exclusionsDesc,
      info: strings.exclusionsInfo,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _items.isEmpty
              ? Text(
                  strings.exclusionsEmpty,
                  style: NbText.caption.copyWith(color: colors.textWeak),
                )
              : Wrap(
                  runSpacing: 8,
                  children: [
                    for (final item in _items)
                      _ChipView(
                        key: item.key,
                        name: item.name,
                        fresh: item.fresh,
                        leaving: item.leaving,
                        removeLabel: strings.removeExclusion(item.name),
                        onRemove: () =>
                            widget.controller.removeExclusion(item.name),
                      ),
                  ],
                ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: SettingsTextField(
                  controller: _text,
                  focusNode: _focus,
                  label: strings.exclusionPlaceholder,
                  hint: strings.exclusionPlaceholder,
                  invalid: _problem != null,
                  onChanged: (_) {
                    if (_problem != null) setState(() => _problem = null);
                  },
                  onSubmit: _add,
                ),
              ),
              const SizedBox(width: 8),
              OutlinedButton.icon(
                onPressed: _adding ? null : _add,
                style: OutlinedButton.styleFrom(
                  minimumSize: const Size(0, settingsFieldHeight),
                ),
                icon: const GlyphIcon(Glyphs.plus, size: 14),
                label: Text(strings.addButton),
              ),
            ],
          ),
          SettingsMessage(text: message, tone: SettingsMessageTone.error),
          const SizedBox(height: 6),
          SettingsLink(
            glyph: Glyphs.restore,
            label: strings.restoreDefaults,
            onPressed: isDefaultExclusionList(names) ? null : _toggleConfirm,
          ),
          InlineConfirm(
            open: _confirming,
            message: Text.rich(
              TextSpan(
                children: leadSentenceBold(strings.restoreConfirm, bold),
              ),
            ),
            confirmLabel: strings.restoreButton,
            cancelLabel: strings.cancelButton,
            onConfirm: _restore,
            onCancel: _cancelConfirm,
          ),
        ],
      ),
    );
  }
}

class _ChipView extends StatefulWidget {
  const _ChipView({
    required this.name,
    required this.fresh,
    required this.leaving,
    required this.removeLabel,
    required this.onRemove,
    super.key,
  });

  final String name;
  final bool fresh;
  final bool leaving;
  final String removeLabel;
  final VoidCallback onRemove;

  @override
  State<_ChipView> createState() => _ChipViewState();
}

class _ChipViewState extends State<_ChipView>
    with SingleTickerProviderStateMixin {
  late final AnimationController _motion = AnimationController(
    vsync: this,
    duration: _chipIn,
    reverseDuration: _chipOut,
    value: 1,
  );
  bool _started = false;

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
  void didUpdateWidget(_ChipView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.leaving && !oldWidget.leaving) _motion.reverse();
  }

  @override
  void dispose() {
    _motion.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = NbColors.of(context);
    final chip = DecoratedBox(
      decoration: BoxDecoration(
        color: colors.surfaceWeak,
        borderRadius: BorderRadius.circular(15),
        border: Border.all(
          color: colors.border,
          strokeAlign: BorderSide.strokeAlignInside,
        ),
      ),
      child: SizedBox(
        height: 30,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(11, 0, 4, 0),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const FolderIcon(height: 14),
              const SizedBox(width: 6),
              ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 220),
                child: Text(
                  widget.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: NbText.bodySm.copyWith(
                    color: colors.text,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              const SizedBox(width: 6),
              RoundIconButton(
                glyph: Glyphs.close,
                label: widget.removeLabel,
                onPressed: widget.onRemove,
              ),
            ],
          ),
        ),
      ),
    );
    return IgnorePointer(
      ignoring: widget.leaving,
      child: AnimatedBuilder(
        animation: _motion,
        child: Padding(padding: const EdgeInsets.only(right: 8), child: chip),
        builder: (context, child) {
          final leaving = _motion.status == AnimationStatus.reverse;
          final t = leaving
              ? labEaseOut.transform(_motion.value)
              : _pop.transform(_motion.value);
          final scale = leaving ? 0.7 + 0.3 * t : 0.6 + 0.4 * t;
          return Opacity(
            opacity: _motion.value.clamp(0.0, 1.0),
            child: ClipRect(
              child: Align(
                alignment: Alignment.centerLeft,
                widthFactor: leaving ? t : 1,
                child: Transform.scale(
                  scale: scale,
                  alignment: Alignment.centerLeft,
                  child: child,
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}
