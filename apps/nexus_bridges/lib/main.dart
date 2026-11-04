import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:nexus_bridges_core/nexus_bridges_core.dart';

import 'src/app_controller.dart';
import 'src/l10n/app_strings.dart';
import 'src/ui/attention.dart';
import 'src/ui/exit_flow.dart';
import 'src/ui/home_screen.dart';
import 'src/ui/network_prompt_dialog.dart';
import 'src/ui/pairing_dialogs.dart';
import 'src/ui/settings/settings_controller.dart';
import 'src/ui/theme/app_theme.dart';
import 'src/window/method_channel_window_host.dart';
import 'src/window/title_bar_sync.dart';
import 'src/window/window_host.dart';

const String windowClassName = 'FLUTTER_RUNNER_WIN32_WINDOW';
const String windowTitle = 'NexusBridges';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final startup = await loadStartupSettings(
    platformLanguageCode: PlatformDispatcher.instance.locale.languageCode,
  );
  final windowHost = MethodChannelWindowHost();
  await windowHost.setDarkTitleBar(
    effectiveDarkOf(
      startup.theme,
      PlatformDispatcher.instance.platformBrightness,
    ),
  );
  final controller = AppController(
    startNode: () => NexusNode.start(
      ownerWindowClass: windowClassName,
      ownerWindowTitle: windowTitle,
    ),
    loadStartup: () async => startup,
  );
  await controller.init();
  runApp(NexusBridgesApp(controller, windowHost: windowHost));
}

ThemeMode themeModeOf(ThemeChoice theme) {
  return switch (theme) {
    ThemeChoice.dark => ThemeMode.dark,
    ThemeChoice.light => ThemeMode.light,
    ThemeChoice.system => ThemeMode.system,
  };
}

class NexusBridgesApp extends StatefulWidget {
  const NexusBridgesApp(this.controller, {this.windowHost, super.key});

  final AppController controller;
  final WindowHost? windowHost;

  @override
  State<NexusBridgesApp> createState() => _NexusBridgesAppState();
}

class _NexusBridgesAppState extends State<NexusBridgesApp>
    with WidgetsBindingObserver {
  late final AppLifecycleListener _lifecycle;
  late TitleBarSync _titleBar;
  final SettingsController _settings = SettingsController();
  final FocusNode _neutralFocus = FocusNode(
    debugLabel: 'neutral',
    skipTraversal: true,
  );
  late AttentionWatcher _attention = AttentionWatcher(widget.controller);
  final ThemeData _lightTheme = buildTheme(Brightness.light);
  final ThemeData _darkTheme = buildTheme(Brightness.dark);
  late String _languageCode = widget.controller.languageCode;
  late ThemeChoice _theme = widget.controller.theme;
  late final WindowHost _host = widget.windowHost ?? MethodChannelWindowHost();
  bool _reduceMotion = false;
  final _navigatorKey = GlobalKey<NavigatorState>();
  Future<AppExitResponse>? _exiting;

  @override
  void initState() {
    super.initState();
    _reduceMotion = WidgetsBinding
        .instance
        .platformDispatcher
        .accessibilityFeatures
        .disableAnimations;
    WidgetsBinding.instance.addObserver(this);
    widget.controller.addListener(_onController);
    widget.controller.settingsOpen = _isSettingsOpen;
    _titleBar = _newTitleBar()..start();
    _lifecycle = AppLifecycleListener(
      onExitRequested: () => _exiting ??= handleExitRequest(
        widget.controller,
        context: () => _navigatorKey.currentContext,
      ).whenComplete(() => _exiting = null),
    );
  }

  bool _isSettingsOpen() => _settings.isOpen;

  TitleBarSync _newTitleBar() =>
      TitleBarSync(host: _host, controller: widget.controller);

  @override
  void didUpdateWidget(NexusBridgesApp oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller == widget.controller) return;
    oldWidget.controller.removeListener(_onController);
    widget.controller.addListener(_onController);
    widget.controller.settingsOpen = _isSettingsOpen;
    _titleBar.dispose();
    _titleBar = _newTitleBar()..start();
    _attention.dispose();
    _attention = AttentionWatcher(widget.controller);
    _languageCode = widget.controller.languageCode;
    _theme = widget.controller.theme;
  }

  void _onController() {
    final language = widget.controller.languageCode;
    final theme = widget.controller.theme;
    if (language == _languageCode && theme == _theme) return;
    setState(() {
      _languageCode = language;
      _theme = theme;
    });
  }

  @override
  void didChangeAccessibilityFeatures() {
    final reduce = WidgetsBinding
        .instance
        .platformDispatcher
        .accessibilityFeatures
        .disableAnimations;
    if (reduce == _reduceMotion) return;
    setState(() => _reduceMotion = reduce);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    widget.controller.removeListener(_onController);
    _titleBar.dispose();
    _attention.dispose();
    _neutralFocus.dispose();
    _settings.dispose();
    _lifecycle.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      navigatorKey: _navigatorKey,
      onGenerateTitle: (context) => AppStringsDelegate.of(context).appTitle,
      locale: Locale(_languageCode),
      supportedLocales: const [Locale('en'), Locale('es')],
      localizationsDelegates: const [
        AppStringsDelegate(),
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      theme: _lightTheme,
      darkTheme: _darkTheme,
      themeMode: themeModeOf(_theme),
      themeAnimationDuration: _reduceMotion ? Duration.zero : themeFade,
      themeAnimationCurve: Curves.easeInOut,
      home: NetworkPromptHost(
        controller: widget.controller,
        child: PairingHost(
          controller: widget.controller,
          child: HomeScreen(
            widget.controller,
            settings: _settings,
            attention: _attention,
            neutralFocus: _neutralFocus,
          ),
        ),
      ),
    );
  }
}
