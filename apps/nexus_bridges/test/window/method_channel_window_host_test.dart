import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nexus_bridges/src/window/method_channel_window_host.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel(windowChannelName);
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  tearDown(() => messenger.setMockMethodCallHandler(channel, null));

  group('E859 MethodChannelWindowHost.setDarkTitleBar (RF-511)', () {
    test('the channel is nexus_bridges/window', () {
      expect(windowChannelName, 'nexus_bridges/window');
    });

    test('it sends setDarkTitleBar with {"dark": value}', () async {
      final calls = <MethodCall>[];
      messenger.setMockMethodCallHandler(channel, (call) async {
        calls.add(call);
        return null;
      });
      final host = MethodChannelWindowHost();
      await host.setDarkTitleBar(false);
      await host.setDarkTitleBar(true);
      expect(calls.map((call) => call.method), [
        'setDarkTitleBar',
        'setDarkTitleBar',
      ]);
      expect(calls.map((call) => call.arguments), [
        {'dark': false},
        {'dark': true},
      ]);
    });

    test('without the native side it does not throw', () async {
      final host = MethodChannelWindowHost();
      await expectLater(host.setDarkTitleBar(true), completes);
    });

    test('a native error does not throw either', () async {
      messenger.setMockMethodCallHandler(channel, (call) async {
        throw PlatformException(code: 'bad_arguments');
      });
      final host = MethodChannelWindowHost();
      await expectLater(host.setDarkTitleBar(false), completes);
    });
  });
}
