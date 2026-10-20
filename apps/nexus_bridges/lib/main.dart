import 'package:flutter/material.dart';
import 'package:nexus_bridges_core/nexus_bridges_core.dart';

void main() {
  runApp(const NexusBridgesApp());
}

class NexusBridgesApp extends StatelessWidget {
  const NexusBridgesApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'NexusBridges',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.indigo),
      ),
      home: const Scaffold(
        body: Center(child: Text('NexusBridges · protocol $protocolVersion')),
      ),
    );
  }
}
