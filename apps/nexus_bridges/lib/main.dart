import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:nexus_bridges_core/nexus_bridges_core.dart';

import 'src/app_controller.dart';
import 'src/l10n/app_strings.dart';
import 'src/ui/exit_flow.dart';
import 'src/ui/home_screen.dart';
import 'src/ui/network_prompt_dialog.dart';
import 'src/ui/pairing_dialogs.dart';
import 'src/ui/theme/app_theme.dart';

const String windowClassName = 'FLUTTER_RUNNER_WIN32_WINDOW';
const String windowTitle = 'NexusBridges';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final controller = AppController(
    startNode: () => NexusNode.start(
      ownerWindowClass: windowClassName,
      ownerWindowTitle: windowTitle,
    ),
    loadLanguage: () => loadLanguage(
      platformLanguageCode: PlatformDispatcher.instance.locale.languageCode,
    ),
  );
  await controller.init();
  runApp(NexusBridgesApp(controller));
}

class NexusBridgesApp extends StatefulWidget {
  const NexusBridgesApp(this.controller, {super.key});

  final AppController controller;

  @override
  State<NexusBridgesApp> createState() => _NexusBridgesAppState();
}

class _NexusBridgesAppState extends State<NexusBridgesApp> {
  late final AppLifecycleListener _lifecycle;
  final _navigatorKey = GlobalKey<NavigatorState>();
  Future<AppExitResponse>? _exiting;

  @override
  void initState() {
    super.initState();
    _lifecycle = AppLifecycleListener(
      onExitRequested: () => _exiting ??= handleExitRequest(
        widget.controller,
        context: () => _navigatorKey.currentContext,
      ).whenComplete(() => _exiting = null),
    );
  }

  @override
  void dispose() {
    _lifecycle.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      navigatorKey: _navigatorKey,
      onGenerateTitle: (context) => AppStringsDelegate.of(context).appTitle,
      locale: Locale(widget.controller.languageCode),
      supportedLocales: const [Locale('en'), Locale('es')],
      localizationsDelegates: const [
        AppStringsDelegate(),
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      theme: buildTheme(Brightness.light),
      darkTheme: buildTheme(Brightness.dark),
      themeMode: ThemeMode.dark,
      themeAnimationDuration: Duration.zero,
      home: NetworkPromptHost(
        controller: widget.controller,
        child: PairingHost(
          controller: widget.controller,
          child: HomeScreen(widget.controller),
        ),
      ),
    );
  }
}
