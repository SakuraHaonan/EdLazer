import 'dart:async';

import 'package:audio_session/audio_session.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:just_audio/just_audio.dart' as audio;
import 'package:lazer_nextgen/audio/audio_engine.dart';
import 'package:lazer_nextgen/audio/playback_session.dart';
import 'package:lazer_nextgen/data/catalog.dart';
import 'package:lazer_nextgen/data/models.dart';
import 'package:lazer_nextgen/gateway/gateway.dart';
import 'package:lazer_nextgen/state/app_state.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _Session implements AudioSession {
  final interruptions = StreamController<AudioInterruptionEvent>.broadcast();
  final noisy = StreamController<void>.broadcast();
  final activations = <bool>[];
  int configurations = 0;
  Completer<bool>? pendingActivation;

  @override
  Stream<AudioInterruptionEvent> get interruptionEventStream =>
      interruptions.stream;
  @override
  Stream<void> get becomingNoisyEventStream => noisy.stream;
  @override
  AndroidAudioAttributes? get androidAudioAttributes => null;
  @override
  Future<void> configure(AudioSessionConfiguration configuration) async {
    configurations++;
  }

  @override
  Future<bool> setActive(
    bool active, {
    AVAudioSessionSetActiveOptions? avAudioSessionSetActiveOptions,
    AndroidAudioFocusGainType? androidAudioFocusGainType,
    AndroidAudioAttributes? androidAudioAttributes,
    bool? androidWillPauseWhenDucked,
    AudioSessionConfiguration fallbackConfiguration = const AudioSessionConfiguration.music(),
  }) async {
    activations.add(active);
    if (active && pendingActivation != null) return pendingActivation!.future;
    return true;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);

  Future<void> close() async {
    await interruptions.close();
    await noisy.close();
  }
}

class _Player implements audio.AudioPlayer {
  final states = StreamController<audio.ProcessingState>.broadcast();
  int plays = 0;
  int pauses = 0;
  @override
  Stream<audio.ProcessingState> get processingStateStream => states.stream;
  @override
  audio.ProcessingState get processingState => audio.ProcessingState.ready;
  @override
  Duration position = Duration.zero;
  @override
  Duration? get duration => const Duration(seconds: 30);
  @override
  Future<Duration?> setUrl(
    String url, {
    Map<String, String>? headers,
    Duration? initialPosition,
    bool preload = true,
    dynamic tag,
  }) async => duration;
  @override
  Future<void> play() async {
    plays++;
  }

  @override
  Future<void> pause() async {
    pauses++;
  }

  @override
  Future<void> setVolume(double volume) async {}
  @override
  Future<void> stop() async {}
  @override
  Future<void> dispose() => states.close();
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Gateway extends NeteaseGateway {
  @override
  Future<List<GatewaySong>> songDetails(List<int> ids) async => [];
}

class _Catalog extends Catalog {
  _Catalog() : super(gateway: _Gateway());
  @override
  Future<String?> audioUrlFor(Track track) async => 'https://audio.test/track';
  @override
  Future<GatewayLyrics?> lyricsFor(Track track) async => const GatewayLyrics();
}

const _track = Track(
  id: '1',
  title: 'Track',
  artist: 'Artist',
  album: 'Album',
  duration: Duration(seconds: 30),
  coverSeed: 1,
);

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets(
    'independent playback never opens an OS session and normal mode honors interruptions',
    (tester) async {
      final player = _Player();
      final engine = JustAudioEngine(player: player);
      final state = AppState(
        catalog: _Catalog(),
        audioEngine: engine,
        independentPlayback: true,
      );
      final session = _Session();
      var requests = 0;
      final policy = PlaybackSession(
        state,
        engine,
        sessionFactory: () async {
          requests++;
          return session;
        },
      );
      state.playQueue([_track]);
      await tester.pump();
      expect(player.plays, 1);
      expect(requests, 0);
      expect(session.activations, isEmpty);
      await state.setIndependentPlayback(false);
      await policy.settled;
      expect(requests, 1);
      expect(session.configurations, 1);
      expect(session.activations, [true]);
      session.interruptions.add(
        AudioInterruptionEvent(true, AudioInterruptionType.pause),
      );
      await tester.pump();
      expect(state.playing, false);
      session.interruptions.add(
        AudioInterruptionEvent(false, AudioInterruptionType.pause),
      );
      await tester.pump();
      expect(state.playing, true);
      await state.setIndependentPlayback(true);
      await policy.settled;
      expect(session.activations.last, false);
      final activations = session.activations.length;
      session.noisy.add(null);
      session.interruptions.add(
        AudioInterruptionEvent(true, AudioInterruptionType.pause),
      );
      await tester.pump();
      expect(state.playing, true);
      state.pause();
      state.play();
      await tester.pump();
      expect(session.activations, hasLength(activations));
      policy.close();
      await policy.settled;
      state.dispose();
      engine.dispose();
      await session.close();
      await tester.pump();
    },
  );

  testWidgets('pause cancels an engine play waiting for focus', (tester) async {
    final player = _Player();
    final pending = Completer<bool>();
    final engine = JustAudioEngine(
      player: player,
      activateSession: () => pending.future,
    );
    await engine.setUrl('https://audio.test/track');
    final playing = engine.play();
    await engine.pause();
    pending.complete(true);
    await playing;
    expect(player.plays, 0);
    engine.dispose();
    await tester.pump();
  });

  testWidgets('rapid mode changes release stale focus before reacquiring', (
    tester,
  ) async {
    final player = _Player();
    final engine = JustAudioEngine(player: player);
    final state = AppState(catalog: _Catalog(), audioEngine: engine);
    final session = _Session()..pendingActivation = Completer<bool>();
    final policy = PlaybackSession(
      state,
      engine,
      sessionFactory: () async => session,
    );
    state.playQueue([_track]);
    await tester.pump();
    expect(session.activations, [true]);
    await state.setIndependentPlayback(true);
    await state.setIndependentPlayback(false);
    session.pendingActivation!.complete(true);
    session.pendingActivation = null;
    await policy.settled;
    await tester.pump();
    expect(session.activations.last, true);
    expect(session.activations.where((active) => !active), isNotEmpty);
    expect(state.playing, true);
    policy.close();
    await policy.settled;
    state.dispose();
    engine.dispose();
    await session.close();
    await tester.pump();
  });
}
