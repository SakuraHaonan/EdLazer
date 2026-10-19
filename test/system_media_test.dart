import 'dart:async';
import 'package:audio_service/audio_service.dart';
import 'package:audio_service_platform_interface/audio_service_platform_interface.dart'
    as platform;
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:lazer_nextgen/audio/audio_engine.dart';
import 'package:lazer_nextgen/audio/system_media_handler.dart';
import 'package:lazer_nextgen/audio/windows_media_platform.dart';
import 'package:lazer_nextgen/data/catalog.dart';
import 'package:lazer_nextgen/data/models.dart';
import 'package:lazer_nextgen/gateway/gateway.dart';
import 'package:lazer_nextgen/state/app_state.dart';

const _tracks = [
  Track(
    id: '1',
    title: 'First',
    artist: 'One',
    album: 'Album',
    duration: Duration(seconds: 4),
    coverSeed: 1,
  ),
  Track(
    id: '2',
    title: 'Second',
    artist: 'Two',
    album: 'Album',
    duration: Duration(seconds: 4),
    coverSeed: 2,
  ),
  Track(
    id: '3',
    title: 'Third',
    artist: 'Three',
    album: 'Album',
    duration: Duration(seconds: 4),
    coverSeed: 3,
  ),
];

class _Gateway extends NeteaseGateway {
  @override
  Future<List<GatewaySong>> songDetails(List<int> ids) async => [];
}

class _Catalog extends Catalog {
  _Catalog() : super(gateway: _Gateway());
  @override
  Future<String?> audioUrlFor(Track track) async => track.id;
  @override
  Future<GatewayLyrics?> lyricsFor(Track track) async => const GatewayLyrics();
}

class _Engine implements AudioEngine {
  @override
  Future<void> setVolume(double volume) async {}
  final completion = StreamController<void>.broadcast();
  final plays = <Completer<void>>[];
  bool holdPlay = false;
  final loaded = <String>[];
  @override
  bool active = false;
  @override
  Duration position = Duration.zero;
  @override
  Duration? duration = const Duration(seconds: 4);
  @override
  Stream<void> get completed => completion.stream;
  @override
  Future<void> setUrl(String url) async {
    for (final old in plays) {
      if (!old.isCompleted) old.completeError(StateError('source replaced'));
    }
    loaded.add(url);
    position = Duration.zero;
    active = true;
  }

  @override
  Future<void> play() {
    if (!holdPlay) return Future.value();
    final play = Completer<void>();
    plays.add(play);
    return play.future;
  }

  @override
  Future<void> pause() async {}
  @override
  Future<void> seek(Duration value) async {
    position = value;
  }

  @override
  Future<void> stop() async {
    active = false;
  }

  @override
  void dispose() {
    for (final play in plays) {
      if (!play.isCompleted) play.complete();
    }
    completion.close();
  }
}

class _Callbacks extends platform.AudioHandlerCallbacks {
  final calls = <Invocation>[];
  @override
  dynamic noSuchMethod(Invocation invocation) {
    calls.add(invocation);
    return Future<void>.value();
  }
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets(
    'independent mode keeps playback and ignores every remote command',
    (tester) async {
      final engine = _Engine();
      final state = AppState(catalog: _Catalog(), audioEngine: engine);
      state.playQueue(_tracks);
      await tester.pump();
      final artwork = Completer<Uri?>();
      final handler = LazerMediaHandler(state, artwork: (_) => artwork.future);
      engine.position = const Duration(seconds: 2);
      state.seek(0.5);
      state.toggleShuffle();
      state.cycleRepeat();
      await state.setIndependentPlayback(true);
      expect(
        handler.playbackState.value.processingState,
        AudioProcessingState.idle,
      );
      expect(handler.playbackState.value.playing, false);
      expect(handler.mediaItem.value, isNull);
      expect(state.playing, true);
      expect(state.audioReady, true);
      expect(state.precisePosition, const Duration(seconds: 2));
      await handler.pause();
      await handler.stop();
      await handler.skipToNext();
      await handler.skipToPrevious();
      await handler.skipToQueueItem(2);
      await handler.seek(Duration.zero);
      await handler.setRepeatMode(AudioServiceRepeatMode.one);
      await handler.setShuffleMode(AudioServiceShuffleMode.none);
      await handler.onTaskRemoved();
      expect(state.current?.id, '1');
      expect(state.playing, true);
      expect(state.precisePosition, const Duration(seconds: 2));
      expect(state.shuffle, true);
      expect(state.repeat, LoopMode.all);
      artwork.complete(Uri.file('late-cover.jpg'));
      await tester.pump(const Duration(milliseconds: 300));
      expect(handler.mediaItem.value, isNull);
      state.pause();
      await handler.play();
      expect(state.playing, false);
      state.toggleShuffle();
      state.next();
      await state.setIndependentPlayback(false);
      handler.setEnabled(true);
      expect(handler.mediaItem.value?.id, '2');
      expect(handler.queue.value, hasLength(3));
      expect(handler.playbackState.value.playing, false);
      expect(engine.loaded, ['1']);
      handler.close();
      state.dispose();
      engine.dispose();
      await tester.pump();
    },
  );

  testWidgets(
    'cold independent startup skips media initialization and initializes once on demand',
    (tester) async {
      final state = AppState(catalog: _Catalog(), independentPlayback: true);
      var initializations = 0;
      final toggles = <bool>[];
      final controller = SystemMediaController(
        state,
        initialize: () async {
          initializations++;
          return LazerMediaHandler(
            state,
            enabled: false,
            artwork: (_) async => null,
          );
        },
        togglePlatform: (enabled) async => toggles.add(enabled),
      );
      await controller.settled;
      expect(initializations, 0);
      expect(toggles, isEmpty);
      await state.setIndependentPlayback(false);
      await controller.settled;
      expect(initializations, 1);
      expect(toggles, [true]);
      await state.setIndependentPlayback(true);
      await controller.settled;
      await state.setIndependentPlayback(false);
      await controller.settled;
      expect(initializations, 1);
      expect(toggles, [true, false, true]);
      expect(
        (await SharedPreferences.getInstance()).getBool(
          'lazer_independent_playback',
        ),
        false,
      );
      controller.close();
      await controller.settled;
      state.dispose();
      await tester.pump();
    },
  );

  testWidgets(
    'pending initialization cannot publish after switching to independent playback',
    (tester) async {
      final state = AppState(catalog: _Catalog());
      final pending = Completer<LazerMediaHandler>();
      final toggles = <bool>[];
      final controller = SystemMediaController(
        state,
        initialize: () => pending.future,
        togglePlatform: (enabled) async => toggles.add(enabled),
      );
      await tester.pump();
      await state.setIndependentPlayback(true);
      final handler = LazerMediaHandler(
        state,
        enabled: false,
        artwork: (_) async => null,
      );
      pending.complete(handler);
      await controller.settled;
      expect(toggles, isNot(contains(true)));
      await handler.play();
      expect(state.playing, false);
      controller.close();
      await controller.settled;
      state.dispose();
      await tester.pump();
    },
  );

  testWidgets(
    'native completion advances, interrupted old play cannot fail the new song, loop one restarts',
    (tester) async {
      final engine = _Engine()..holdPlay = true;
      final state = AppState(catalog: _Catalog(), audioEngine: engine);
      state.playQueue(_tracks);
      await tester.pump();
      expect(state.audioReady, true);
      expect(engine.loaded, ['1']);
      engine.completion.add(null);
      await tester.pump();
      expect(state.current?.id, '2');
      expect(state.playing, true);
      expect(state.playbackError, isNull);
      expect(engine.loaded, ['1', '2']);
      state.cycleRepeat();
      state.cycleRepeat();
      engine.position = const Duration(seconds: 4);
      engine.completion.add(null);
      await tester.pump();
      expect(state.current?.id, '2');
      expect(engine.position, Duration.zero);
      expect(state.playing, true);
      state.dispose();
      engine.dispose();
      await tester.pump();
    },
  );
  testWidgets(
    '100ms duration watchdog handles missing completion without advancing a paused or unknown-duration stream',
    (tester) async {
      final engine = _Engine();
      final state = AppState(catalog: _Catalog(), audioEngine: engine);
      state.playQueue(_tracks);
      await tester.pump();
      engine.position = const Duration(seconds: 4);
      await tester.pump(const Duration(milliseconds: 99));
      expect(state.current?.id, '1');
      await tester.pump(const Duration(milliseconds: 1));
      expect(state.current?.id, '2');
      engine.duration = null;
      engine.position = const Duration(seconds: 40);
      await tester.pump(const Duration(milliseconds: 100));
      expect(state.current?.id, '2');
      state.pause();
      engine.duration = const Duration(seconds: 4);
      await tester.pump(const Duration(milliseconds: 200));
      expect(state.current?.id, '2');
      state.dispose();
      engine.dispose();
      await tester.pump();
    },
  );
  test(
    'system controls publish every 100ms and share next, previous, seek, queue and stop state',
    () async {
      final engine = _Engine();
      final state = AppState(catalog: _Catalog(), audioEngine: engine);
      state.playQueue(_tracks);
      await Future<void>.delayed(Duration.zero);
      final handler = LazerMediaHandler(state, artwork: (_) async => null);
      final updates = <PlaybackState>[];
      final subscription = handler.playbackState.listen(updates.add);
      await Future<void>.delayed(Duration.zero);
      updates.clear();
      engine.position = const Duration(milliseconds: 1234);
      await handler.playbackState
          .firstWhere(
            (value) =>
                value.updatePosition == const Duration(milliseconds: 1234),
          )
          .timeout(const Duration(seconds: 2));
      expect(AppState.playbackInterval, const Duration(milliseconds: 100));
      expect(updates, hasLength(1));
      expect(updates.last.updatePosition, const Duration(milliseconds: 1234));
      expect(updates.last.controls.map((c) => c.action), [
        MediaAction.skipToPrevious,
        MediaAction.pause,
        MediaAction.skipToNext,
      ]);
      expect(updates.last.systemActions, contains(MediaAction.seek));
      expect(
        updates.last.systemActions,
        isNot(contains(MediaAction.seekForward)),
      );
      await handler.skipToNext();
      await Future<void>.delayed(Duration.zero);
      expect(state.current?.id, '2');
      expect(handler.mediaItem.value?.title, 'Second');
      expect(handler.queue.value, hasLength(3));
      await handler.skipToPrevious();
      await Future<void>.delayed(Duration.zero);
      expect(state.current?.id, '1');
      await handler.seek(const Duration(milliseconds: 2500));
      await Future<void>.delayed(Duration.zero);
      expect(engine.position, const Duration(milliseconds: 2500));
      await handler.skipToQueueItem(2);
      await Future<void>.delayed(Duration.zero);
      expect(state.current?.id, '3');
      await handler.stop();
      await Future<void>.delayed(const Duration(milliseconds: 220));
      expect(
        handler.playbackState.value.processingState,
        AudioProcessingState.idle,
      );
      expect(state.playing, false);
      expect(engine.active, false);
      await handler.play();
      await Future<void>.delayed(Duration.zero);
      expect(state.playing, true);
      expect(
        handler.playbackState.value.processingState,
        AudioProcessingState.ready,
      );
      handler.close();
      await subscription.cancel();
      state.dispose();
      engine.dispose();
      await Future<void>.delayed(Duration.zero);
    },
  );
  test('late artwork cannot replace the new song metadata', () async {
    final engine = _Engine();
    final state = AppState(catalog: _Catalog(), audioEngine: engine);
    state.playQueue(_tracks);
    await Future<void>.delayed(Duration.zero);
    final artwork = <Completer<Uri?>>[];
    final handler = LazerMediaHandler(
      state,
      artwork: (_) {
        final result = Completer<Uri?>();
        artwork.add(result);
        return result.future;
      },
    );
    await handler.skipToNext();
    await Future<void>.delayed(Duration.zero);
    artwork.first.complete(Uri.file('old-cover.jpg'));
    await Future<void>.delayed(Duration.zero);
    expect(handler.mediaItem.value?.id, '2');
    expect(handler.mediaItem.value?.artUri, isNull);
    artwork.last.complete(Uri.file('new-cover.jpg'));
    await Future<void>.delayed(Duration.zero);
    expect(handler.mediaItem.value?.artUri, Uri.file('new-cover.jpg'));
    handler.close();
    state.dispose();
    engine.dispose();
    await Future<void>.delayed(Duration.zero);
  });
  testWidgets(
    'Windows bridge sends actual timeline and cached artwork, receives seek on the same handler',
    (tester) async {
      final calls = <MethodCall>[];
      final callbacks = _Callbacks();
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        WindowsMediaPlatform.channel,
        (call) async {
          calls.add(call);
          return null;
        },
      );
      final bridge = WindowsMediaPlatform()..setHandlerCallbacks(callbacks);
      await bridge.configure(
        platform.ConfigureRequest(config: platform.AudioServiceConfigMessage()),
      );
      await bridge.setMediaItem(
        const platform.SetMediaItemRequest(
          mediaItem: platform.MediaItemMessage(
            id: '1',
            title: 'Title',
            duration: Duration(seconds: 4),
            extras: {'artCacheFile': r'C:\cover.jpg'},
          ),
        ),
      );
      await bridge.setState(
        platform.SetStateRequest(
          state: platform.PlaybackStateMessage(
            processingState: platform.AudioProcessingStateMessage.ready,
            playing: true,
            controls: const [
              platform.MediaControlMessage(
                androidIcon: '',
                label: 'Next',
                action: platform.MediaActionMessage.skipToNext,
              ),
            ],
            updatePosition: const Duration(milliseconds: 1200),
          ),
        ),
      );
      expect((calls.last.arguments as Map)['positionMs'], 1200);
      expect((calls.last.arguments as Map)['durationMs'], 4000);
      expect((calls[1].arguments as Map)['artPath'], r'C:\cover.jpg');
      await tester.binding.defaultBinaryMessenger.handlePlatformMessage(
        WindowsMediaPlatform.channel.name,
        const StandardMethodCodec().encodeMethodCall(
          const MethodCall('seek', 2500),
        ),
        (_) {},
      );
      expect(callbacks.calls.last.memberName, #seek);
      expect(
        (callbacks.calls.last.positionalArguments.single
                as platform.SeekRequest)
            .position,
        const Duration(milliseconds: 2500),
      );
      await bridge.stopService(const platform.StopServiceRequest());
      expect(calls.last.method, 'clear');
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        WindowsMediaPlatform.channel,
        null,
      );
      WindowsMediaPlatform.channel.setMethodCallHandler(null);
    },
  );
}
