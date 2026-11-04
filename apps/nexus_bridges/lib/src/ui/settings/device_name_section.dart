import 'package:flutter/material.dart';
import 'package:nexus_bridges_core/nexus_bridges_core.dart';

import '../../app_controller.dart';
import '../../l10n/app_strings.dart';
import '../icons/glyphs.dart';
import '../modal/timeline.dart';
import '../theme/app_theme.dart';
import '../theme/tokens.dart';
import 'settings_field.dart';
import 'settings_section.dart';

const Duration _linkGrow = Duration(milliseconds: 420);

class DeviceNameSection extends StatefulWidget {
  const DeviceNameSection({required this.controller, super.key});

  final AppController controller;

  @override
  State<DeviceNameSection> createState() => _DeviceNameSectionState();
}

class _DeviceNameSectionState extends State<DeviceNameSection> {
  final TextEditingController _text = TextEditingController();
  String _saved = '';
  bool _edited = false;
  bool _busy = false;
  DeviceNameProblem? _rejected;

  @override
  void initState() {
    super.initState();
    _saved = widget.controller.state?.deviceName ?? '';
    _text.text = _saved;
    widget.controller.addListener(_onController);
  }

  @override
  void didUpdateWidget(DeviceNameSection oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller == widget.controller) return;
    oldWidget.controller.removeListener(_onController);
    widget.controller.addListener(_onController);
  }

  @override
  void dispose() {
    widget.controller.removeListener(_onController);
    _text.dispose();
    super.dispose();
  }

  void _onController() {
    final current = widget.controller.state?.deviceName ?? '';
    setState(() {
      if (current == _saved) return;
      final untouched = !_edited || _text.text.trim() == _saved;
      _saved = current;
      if (untouched) {
        _edited = false;
        _text.text = current;
      }
    });
  }

  void _onChanged(String _) {
    setState(() {
      _edited = true;
      _rejected = null;
    });
  }

  DeviceNameProblem? get _problem {
    if (!_edited) return null;
    return deviceNameProblem(_text.text.trim()) ?? _rejected;
  }

  bool get _canSave {
    final trimmed = _text.text.trim();
    return !_busy &&
        _edited &&
        trimmed != _saved &&
        deviceNameProblem(trimmed) == null;
  }

  Future<void> _submit() async {
    if (!_canSave) return;
    final trimmed = _text.text.trim();
    setState(() => _busy = true);
    final result = await widget.controller.setDeviceName(trimmed);
    if (!mounted) return;
    setState(() {
      _busy = false;
      _rejected = result.problem;
      if (result.problem == null) {
        _edited = false;
        if (_text.text != trimmed) _text.text = trimmed;
      }
    });
  }

  Future<void> _useWindowsName(String windowsName) async {
    setState(() => _busy = true);
    await widget.controller.setDeviceName(null);
    if (!mounted) return;
    setState(() {
      _busy = false;
      _edited = false;
      _rejected = null;
      _text.text = windowsName;
    });
  }

  String? _message(AppStrings strings, DeviceNameProblem? problem) {
    if (problem != null) {
      return switch (problem) {
        DeviceNameProblem.empty => strings.nameEmpty,
        DeviceNameProblem.tooLong => strings.nameTooLong,
        DeviceNameProblem.invalidCharacters => strings.nameInvalid,
      };
    }
    if (!_edited) return null;
    final trimmed = _text.text.trim();
    if (trimmed == _saved) return null;
    return widget.controller.namesakeOf(trimmed) == null
        ? null
        : strings.nameNamesake;
  }

  @override
  Widget build(BuildContext context) {
    final strings = AppStringsDelegate.of(context);
    final colors = NbColors.of(context);
    final animate = !MediaQuery.disableAnimationsOf(context);
    final settings = widget.controller.state?.settings;
    final problem = _problem;
    final message = _message(strings, problem);
    final windowsName = settings?.customName == null
        ? null
        : settings!.windowsName;
    return SettingsSection(
      icon: Glyphs.monitor,
      title: strings.sectionDevice,
      info: strings.deviceNameInfo,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: SettingsTextField(
                  controller: _text,
                  label: strings.deviceNameLabel,
                  invalid: problem != null,
                  maxLength: 256,
                  onChanged: _onChanged,
                  onSubmit: _submit,
                ),
              ),
              const SizedBox(width: 8),
              FilledButton(
                onPressed: _canSave ? _submit : null,
                style: FilledButton.styleFrom(
                  minimumSize: const Size(0, settingsFieldHeight),
                ),
                child: Text(strings.saveButton),
              ),
            ],
          ),
          SettingsMessage(
            text: message,
            tone: problem != null
                ? SettingsMessageTone.error
                : SettingsMessageTone.neutral,
          ),
          const SizedBox(height: 8),
          Text(
            strings.deviceNameDesc,
            style: NbText.caption.copyWith(
              color: colors.textWeak,
              fontSize: 12.5,
              height: 18 / 12.5,
            ),
          ),
          AnimatedSize(
            duration: animate ? _linkGrow : Duration.zero,
            curve: labEaseOut,
            alignment: Alignment.topCenter,
            child: windowsName == null
                ? const SizedBox(width: double.infinity)
                : Padding(
                    padding: const EdgeInsets.only(top: 6),
                    child: SettingsLink(
                      glyph: Glyphs.restore,
                      label: strings.useWindowsName(windowsName),
                      onPressed: _busy
                          ? null
                          : () => _useWindowsName(windowsName),
                    ),
                  ),
          ),
        ],
      ),
    );
  }
}
