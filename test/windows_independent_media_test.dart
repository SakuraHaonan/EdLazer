import 'package:audio_service_platform_interface/audio_service_platform_interface.dart'
    as platform;
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lazer_nextgen/audio/windows_media_platform.dart';

class _Callbacks extends platform.AudioHandlerCallbacks {
  final calls = <Invocation>[];

  @override
  dynamic noSuchMethod(Invocation invocation) {
    calls.add(invocation);
    return Future<void>.value();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late List<MethodCall> nativeCalls;
  late _Callbacks callbacks;

  setUp(() {
    nativeCalls = <MethodCall>[];
    callbacks = _Callbacks();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(WindowsMediaPlatform.channel, (call) async {
          nativeCalls.add(call);
          return null;
        });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(WindowsMediaPlatform.channel, null);
    WindowsMediaPlatform.channel.setMethodCallHandler(null);
  });

  test(
    'disable tears down once and blocks queued outbound and inbound calls',
    () async {
      final bridge = WindowsMediaPlatform()..setHandlerCallbacks(callbacks);
      await bridge.configure(
        platform.ConfigureRequest(config: platform.AudioServiceConfigMessage()),
      );
      expect(nativeCalls.map((call) => call.method), ['initialize']);

      await bridge.setEnabled(false);
      await bridge.setEnabled(false);
      expect(nativeCalls.map((call) => call.method), [
        'initialize',
        'deinitialize',
      ]);

      await bridge.setMediaItem(
        const platform.SetMediaItemRequest(
          mediaItem: platform.MediaItemMessage(id: '1', title: 'Blocked'),
        ),
      );
      await bridge.setState(
        platform.SetStateRequest(
          state: platform.PlaybackStateMessage(
            processingState: platform.AudioProcessingStateMessage.ready,
          ),
        ),
      );
      await bridge.stopService(const platform.StopServiceRequest());
      expect(nativeCalls.map((call) => call.method), [
        'initialize',
        'deinitialize',
      ]);

      await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .handlePlatformMessage(
            WindowsMediaPlatform.channel.name,
            const StandardMethodCodec().encodeMethodCall(MethodCall('play')),
            (_) {},
          );
      expect(callbacks.calls, isEmpty);
    },
  );

  test(
    'configure while disabled skips initialize and reenable initializes',
    () async {
      final bridge = WindowsMediaPlatform()..setHandlerCallbacks(callbacks);
      await bridge.setEnabled(false);
      await bridge.configure(
        platform.ConfigureRequest(config: platform.AudioServiceConfigMessage()),
      );
      expect(nativeCalls.map((call) => call.method), ['deinitialize']);

      await bridge.setEnabled(true);
      expect(nativeCalls.map((call) => call.method), [
        'deinitialize',
        'initialize',
      ]);

      await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .handlePlatformMessage(
            WindowsMediaPlatform.channel.name,
            const StandardMethodCodec().encodeMethodCall(MethodCall('play')),
            (_) {},
          );
      expect(callbacks.calls, hasLength(1));
      expect(callbacks.calls.single.memberName, #play);
    },
  );

  test('enabled remains the default for existing configure behavior', () async {
    final bridge = WindowsMediaPlatform()..setHandlerCallbacks(callbacks);
    await bridge.configure(
      platform.ConfigureRequest(config: platform.AudioServiceConfigMessage()),
    );
    expect(nativeCalls.map((call) => call.method), ['initialize']);
  });
}
