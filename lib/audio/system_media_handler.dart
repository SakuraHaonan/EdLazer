import 'dart:async';
import 'dart:io';
import 'package:audio_service/audio_service.dart';
import 'package:audio_service_platform_interface/audio_service_platform_interface.dart';
import 'package:flutter/foundation.dart';
import '../data/models.dart';
import '../state/app_state.dart';
import 'media_artwork_cache.dart';
import 'windows_media_platform.dart';

typedef MediaArtworkResolver = Future<Uri?> Function(String? url);

Future<LazerMediaHandler> initializeSystemMedia(AppState state) async {
  if (Platform.isWindows) {
    AudioServicePlatform.instance = WindowsMediaPlatform();
  }
  return AudioService.init<LazerMediaHandler>(
    builder: () => LazerMediaHandler(state),
    config: const AudioServiceConfig(
      androidNotificationChannelId: 'dev.naominet.lazer.audio',
      androidNotificationChannelName: 'Lazer',
      androidNotificationIcon: 'drawable/ic_stat_music',
      androidStopForegroundOnPause: false,
      artDownscaleWidth: 512,
      artDownscaleHeight: 512,
    ),
  );
}

/// The OS controls command the existing AppState, so UI and remote commands
/// share queue, repeat/shuffle, lyric loading and playback error behavior.
class LazerMediaHandler extends BaseAudioHandler {
  LazerMediaHandler(this.state, {MediaArtworkResolver? artwork})
    : _artwork = artwork ?? MediaArtworkCache().resolve {
    state.addListener(_stateChanged);
    _stateChanged();
    _clock = Timer.periodic(
      AppState.playbackInterval,
      (_) => _publishPlayback(),
    );
  }
  final AppState state;
  final MediaArtworkResolver _artwork;
  late final Timer _clock;
  List<Track> _lastQueue = const [];
  Track? _track;
  int _artGeneration = 0;
  bool _closed = false;
  bool _stopped = false;
  static MediaItem _item(Track track) => MediaItem(
    id: track.id,
    title: track.title,
    artist: track.artist,
    album: track.album,
    duration: track.duration,
  );

  void _stateChanged() {
    if (_closed) return;
    if (state.playing) _stopped = false;
    final tracks = state.queue;
    if (!listEquals(_lastQueue, tracks)) {
      _lastQueue = tracks;
      queue.add(tracks.map(_item).toList());
    }
    final current = state.current;
    if (!identical(current, _track)) {
      _track = current;
      final generation = ++_artGeneration;
      final item = current == null ? null : _item(current);
      mediaItem.add(item);
      if (current != null) {
        unawaited(
          _artwork(current.coverUrl).then((uri) {
            if (!_closed && generation == _artGeneration && uri != null) {
              mediaItem.add(item!.copyWith(artUri: uri));
            }
          }),
        );
      }
    }
    _publishPlayback();
  }

  void _publishPlayback() {
    if (_closed) return;
    final track = state.current;
    final active = track != null && !_stopped;
    playbackState.add(
      PlaybackState(
        // These are track commands on iOS: never expose the podcast +/-30s pair.
        controls: active
            ? [
                MediaControl.skipToPrevious,
                state.playing ? MediaControl.pause : MediaControl.play,
                MediaControl.skipToNext,
              ]
            : const [],
        androidCompactActionIndices: active ? const [0, 1, 2] : const [],
        systemActions: active
            ? const {MediaAction.seek, MediaAction.playPause}
            : const {},
        processingState: !active
            ? AudioProcessingState.idle
            : state.playbackError != null
            ? AudioProcessingState.error
            : state.playing && !state.audioReady
            ? AudioProcessingState.loading
            : AudioProcessingState.ready,
        playing: state.playing,
        updatePosition: state.precisePosition,
        bufferedPosition: state.precisePosition,
        queueIndex: active ? state.queueIndex : null,
        repeatMode: switch (state.repeat) {
          LoopMode.off => AudioServiceRepeatMode.none,
          LoopMode.one => AudioServiceRepeatMode.one,
          LoopMode.all => AudioServiceRepeatMode.all,
        },
        shuffleMode: state.shuffle
            ? AudioServiceShuffleMode.all
            : AudioServiceShuffleMode.none,
        errorCode: state.playbackError == null ? null : 1,
        errorMessage: state.playbackError,
      ),
    );
  }

  @override
  Future<void> play() async => state.play();
  @override
  Future<void> pause() async => state.pause();
  @override
  Future<void> skipToNext() async => state.next();
  @override
  Future<void> skipToPrevious() async => state.previous();
  @override
  Future<void> skipToQueueItem(int index) async => state.playTrackAt(index);
  @override
  Future<void> seek(Duration position) async {
    final duration = state.current?.duration.inMicroseconds ?? 0;
    if (duration > 0) state.seek(position.inMicroseconds / duration);
    _publishPlayback();
  }

  @override
  Future<void> stop() async {
    _stopped = true;
    state.stop();
  }

  @override
  Future<void> setShuffleMode(AudioServiceShuffleMode shuffleMode) async {
    if ((shuffleMode != AudioServiceShuffleMode.none) != state.shuffle) {
      state.toggleShuffle();
    }
  }

  @override
  Future<void> setRepeatMode(AudioServiceRepeatMode repeatMode) async {
    final target = switch (repeatMode) {
      AudioServiceRepeatMode.none => LoopMode.off,
      AudioServiceRepeatMode.one => LoopMode.one,
      _ => LoopMode.all,
    };
    while (state.repeat != target) {
      state.cycleRepeat();
    }
  }

  @override
  Future<void> onTaskRemoved() => stop();
  void close() {
    _closed = true;
    ++_artGeneration;
    _clock.cancel();
    state.removeListener(_stateChanged);
  }
}
