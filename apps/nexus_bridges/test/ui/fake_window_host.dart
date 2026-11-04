import 'package:nexus_bridges/src/window/window_host.dart';

class FakeWindowHost implements WindowHost {
  final List<bool> darkTitleBar = [];

  @override
  Future<void> setDarkTitleBar(bool dark) async {
    darkTitleBar.add(dark);
  }
}
