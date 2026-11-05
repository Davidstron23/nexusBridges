import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nexus_bridges/src/window/method_channel_window_host.dart';
import 'package:nexus_bridges/src/window/window_host.dart';

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

  group('E885 the rest of the window channel (RF-521 to RF-528)', () {
    void reply(Map<String, Object?> answers, List<MethodCall> calls) {
      messenger.setMockMethodCallHandler(channel, (call) async {
        calls.add(call);
        return answers[call.method];
      });
    }

    Future<void> nativeSends(String method, [Object? arguments]) async {
      await messenger.handlePlatformMessage(
        windowChannelName,
        const StandardMethodCodec().encodeMethodCall(
          MethodCall(method, arguments),
        ),
        (_) {},
      );
    }

    test('attach answers what the runner answers', () async {
      reply({'attach': true}, []);
      expect(await MethodChannelWindowHost().attach(), isTrue);
    });

    test('without the native side everything is false and nothing '
        'throws', () async {
      final host = MethodChannelWindowHost();
      expect(await host.attach(), isFalse);
      expect(
        await host.setTray(
          enabled: true,
          texts: const TrayTexts(tooltip: 't', open: 'o', exit: 'e'),
        ),
        isFalse,
      );
      expect(await host.showTrayHint(title: 't', body: 'b'), isFalse);
      expect(await host.attention(), isFalse);
      await expectLater(host.hide(), completes);
      await expectLater(host.show(), completes);
      await expectLater(host.minimize(), completes);
      await expectLater(host.quit(), completes);
    });

    test('a native error counts as false too', () async {
      messenger.setMockMethodCallHandler(channel, (call) async {
        throw PlatformException(code: 'bad_arguments');
      });
      final host = MethodChannelWindowHost();
      expect(await host.attach(), isFalse);
      expect(await host.attention(), isFalse);
      await expectLater(host.hide(), completes);
    });

    test('setTray sends its four arguments and answers the '
        'visibility', () async {
      final calls = <MethodCall>[];
      reply({'setTray': true}, calls);
      final visible = await MethodChannelWindowHost().setTray(
        enabled: true,
        texts: const TrayTexts(tooltip: 'NB', open: 'Abrir', exit: 'Salir'),
      );
      expect(visible, isTrue);
      expect(calls.single.method, 'setTray');
      expect(calls.single.arguments, {
        'enabled': true,
        'tooltip': 'NB',
        'open': 'Abrir',
        'exit': 'Salir',
      });
    });

    test('showTrayHint sends the title and the body', () async {
      final calls = <MethodCall>[];
      reply({'showTrayHint': true}, calls);
      final shown = await MethodChannelWindowHost().showTrayHint(
        title: 'title',
        body: 'body',
      );
      expect(shown, isTrue);
      expect(calls.single.arguments, {'title': 'title', 'body': 'body'});
    });

    test('hide, show, minimize and quit go by their name', () async {
      final calls = <MethodCall>[];
      reply({}, calls);
      final host = MethodChannelWindowHost();
      await host.hide();
      await host.show();
      await host.minimize();
      await host.quit();
      expect(calls.map((call) => call.method), [
        'hide',
        'show',
        'minimize',
        'quit',
      ]);
    });

    test('attention reads foreground from the reply', () async {
      reply({
        'attention': {'foreground': true},
      }, []);
      expect(await MethodChannelWindowHost().attention(), isTrue);
      reply({
        'attention': {'foreground': false},
      }, []);
      expect(await MethodChannelWindowHost().attention(), isFalse);
    });

    test('the events of the runner reach the stream', () async {
      final host = MethodChannelWindowHost();
      final events = <WindowEvent>[];
      final subscription = host.events.listen(events.add);
      addTearDown(subscription.cancel);
      await nativeSends('closeRequested');
      await nativeSends('exitRequested');
      await nativeSends('trayVisibility', {'visible': true});
      await nativeSends('trayVisibility', {'visible': false});
      await Future<void>.delayed(Duration.zero);
      expect(events, hasLength(4));
      expect(events[0], isA<CloseRequested>());
      expect(events[1], isA<ExitRequested>());
      expect((events[2] as TrayVisibilityChanged).visible, isTrue);
      expect((events[3] as TrayVisibilityChanged).visible, isFalse);
    });

    test('a malformed trayVisibility is ignored', () async {
      final host = MethodChannelWindowHost();
      final events = <WindowEvent>[];
      final subscription = host.events.listen(events.add);
      addTearDown(subscription.cancel);
      await nativeSends('trayVisibility');
      await nativeSends('trayVisibility', {'visible': 'yes'});
      await Future<void>.delayed(Duration.zero);
      expect(events, isEmpty);
    });
  });
}
