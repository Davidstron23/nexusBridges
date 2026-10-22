import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:nexus_bridges_core/nexus_bridges_core.dart';

import 'src/app_controller.dart';
import 'src/l10n/app_strings.dart';
import 'src/ui/home_screen.dart';
import 'src/ui/network_prompt_dialog.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final controller = AppController(
    startNode: () => NexusNode.start(),
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

  @override
  void initState() {
    super.initState();
    _lifecycle = AppLifecycleListener(
      onExitRequested: () async {
        try {
          await widget.controller.shutdown().timeout(
            const Duration(seconds: 3),
          );
        } catch (_) {}
        return AppExitResponse.exit;
      },
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
      onGenerateTitle: (context) => AppStringsDelegate.of(context).appTitle,
      locale: Locale(widget.controller.languageCode),
      supportedLocales: const [Locale('en'), Locale('es')],
      localizationsDelegates: const [
        AppStringsDelegate(),
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.indigo),
      ),
      home: NetworkPromptHost(
        controller: widget.controller,
        child: HomeScreen(widget.controller),
      ),
    );
  }
}
