import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nexus_bridges/src/drop/drop_events.dart';

class FakeDropEvents implements DropEvents {
  final StreamController<DropEvent> _controller =
      StreamController<DropEvent>.broadcast(sync: true);

  @override
  Stream<DropEvent> get events => _controller.stream;

  void add(DropEvent event) => _controller.add(event);

  Future<void> close() => _controller.close();
}

Future<void> sendDropCall(String method, [Object? arguments]) async {
  final data = const StandardMethodCodec().encodeMethodCall(
    MethodCall(method, arguments),
  );
  await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .handlePlatformMessage(dropChannelName, data, (_) {});
}
